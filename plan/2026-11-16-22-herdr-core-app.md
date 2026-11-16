---
status: draft
issue: 22
spec: spec/2026-11-16-22-herdr-core-app.md
coders:
  1: codex   # app-list: the fifo reader, cleanup, and the jq graph walk (cascades, parents across machines); tricky bash and jq
  2: codex   # the app-* actions: mapping hc results, exit codes, the cascade hash, window by PID; same author as step 1
  3: coder   # HerdrModel.qml: subscription, coalescing, watchdog, sources, keys, staleness
  4: coder   # Menu.qml and Card.qml: captured targets, kind dispatch, the cascade confirm, labels
  5: coder   # tests/app-subscription.qml: the QML wiring check
  6: coder   # README and manifest
reviewers:
  - codex  # reads the QML steps (3-5) it did not write
  - agy    # reads the bash steps (1-2); give it this plan plus the bin/ diff only (it timed out on larger inputs)
---

# Plan: show herdr-core and herdr-app agents, one row per space

Closes #22 on branch `feat/22-herdr-core-app`, which starts from master
`9c8a8fa` (#20 and #21 merged) plus this task's artifacts. Functions are
named, not numbered, because the line numbers move.

## Approved decisions (summarised from the spec, so the plan stands alone)

- **The data, as hc 0.1.21 gives it.**
  - `hc events --json` starts with a snapshot, `{seq, terminals:[Terminal]}`,
    then sends events, a `heartbeat` every 15 s, and `missed` plus a new
    snapshot.
  - `Terminal.status` is `{state, kind, …}` or null. Use `.status.state`
    (idle, working, done, blocked, error). `.status.kind` (permission,
    question, auth) is set only when blocked.
  - `parent` is a bare id, or `machine/tN`. `die_with_parent` is a boolean.
  - Labels:
    - `where` is `"<space> / <tab>"`;
    - `herdr.space` and `herdr.tab` are ids local to that machine.
  - Remote terminals are addressed `machine/tN`.
  - hc errors go to stderr as `{error:{kind,message,hint}}`, with exit codes
    3 not_found, 7 needs_target, 9 blocked, 10 status_mismatch, 11 finished.
  - The attention record is `.attention` in `~/.config/herdr-app/view.json`:
    a map from address to `{word, seen}`.
  - `herdr-app ls` answers only while the window is open. With no window it
    fails with "connection refused".
- **A1: the subscription, in `HerdrModel`.**
  - **Reading:** `appSubProc` runs `hc events --json` into a `SplitParser`,
    attached before the process starts.
  - **Coalescing:**
    - the first non-heartbeat line starts a one-shot 250 ms timer, which later
      lines never restart;
    - the timer runs `app-list`;
    - a line during a run sets `appDirty`, so exactly one more run follows.
  - **Watchdog:** every line resets a 40 s timer. When it fires, the
    subscription is killed and restarted with backoff (2, 4, … up to 60 s),
    and the data is marked stale.
  - **No hc:** failing to start sets `hcAvailable=false`, and nothing retries.
  - **Clearing staleness:** a restart alone never clears it. Only a successful
    `app-list` does.
  - **Malformed lines** are ignored, apart from resetting the watchdog.
- **A2: `bin/herdr-sessions app-list [--remote]`.**
  - **The snapshot reader:**
    - runs `hc events --json` under `bounded 3`, in the background, into a fifo
      in `RUN_DIR`, with its pid added to `JOB_PIDS`;
    - takes the first line with `head -c CAP+1 | head -n 1`;
    - then `kill_tree` and `wait` on the producer;
    - and validates that the line is JSON with a `.terminals` array, else
      `die "could not read herdr-core"`.
  - **In parallel:**
    - `bounded 1 herdr-app ls` sets `windowOpen`: true on success, false on
      connection refused, null on anything else;
    - `view.json` `.attention` is read, capped at `SESSION_FILE_CAP`; missing
      means `{}`.
  - **The jq merge,** in order:
    1. Enrich every terminal: `machine`, `state=.status.state//null`, and
       `parentAddr`. A bare parent on a remote terminal is prefixed with that
       machine.
    2. An agent is `.state=="live"` with `state!=null`.
    3. The space is its own `herdr.space`; else the nearest ancestor's,
       walking `parentAddr` at most 16 levels; else `"_background"`.
    4. Row identity is `{kind:"app", machine, spaceId}`. The name and tab come
       from splitting `where` on its last `" / "`, falling back to `"space"`
       and `""`.
    5. Status:
       - with `windowOpen==true`, the app's status, if it isn't null;
       - otherwise `state`, except that `done` with attention
         `{word:"done",seen:true}` becomes `idle`;
       - `error` stays `error`.
    6. Each agent's `cascade` comes from the full list, before any cap: every
       live terminal reachable through `parentAddr` edges where
       `die_with_parent` is true, transitively, as `{address,title}`.
    7. Rows come from `group_by([.machine,.spaceId])`, each one:

       ```text
       {kind:"app", name, host:machine, spaceId, running:true, readable:true,
        stale:false, agents, blocked, done, working, hiddenAgents,
        agentList:[{title, status, kind:.status.kind, pane:address, tab,
                    seq:status_ms, cascade}], projects:[], windowAddress:""}
       ```

       The title falls back to `argv[0]`'s basename, then "untitled agent".
       #20's D9 500-agent cap applies, and counts are taken after the cap.
    8. Without `--remote`, only `machine==""` is kept.
  - **Output:** `{ok, error, sessions, windowOpen, machines:[{name,state}]}`.
    `machines` comes from `bounded 2 hc machine ls --json`, and only with
    `--remote`.
  - **Tool checks:** `require_tools` checks `jq` always, `herdr` only for the
    classic commands, and `hc` only for `app-*`. On a machine without herdr,
    `list` gives `{ok:true,sessions:[]}`.
- **A3: the actions.**
  - **Shared rules:**
    - `valid_hc_address` is
      `^([A-Za-z0-9][A-Za-z0-9._-]{0,31}/)?t[0-9a-z]{1,9}$`;
    - there is no `--host` or ssh, because hc routes `machine/tN` itself;
    - hc's stderr JSON message is passed on, exit 124 or 137 gives
      `timed out: <action>`, and herdr-app's stdout `{"error":…}` with exit 1
      is decoded.

  | Subcommand | Does | Limit |
  |---|---|---|
  | `app-focus ADDR` | `herdr-app do agent.focus --terminal ADDR`; if the window is closed, start it (A4) and retry until 5 s; then raise it | 6 s |
  | `app-prompt ADDR [--force]` (text on stdin) | `hc send --wait [--force] -- ADDR "$text"`, then `hc read --lines 60 ADDR` | 300 s |
  | `app-interrupt ADDR` | `hc interrupt ADDR` | 12 s |
  | `app-kill ADDR HASH` | recompute the cascade and its hash (`sha256` of the sorted addresses); if it differs, `{ok:false, changed:true, cascade}`; otherwise `hc kill ADDR` | 8 s |
  | `app-new NAME [DIR] [MACHINE]` | `herdr-app do space.new --name NAME [--folder DIR] [--machine MACHINE]`, starting the window first if needed | 8 s |

  - **Prompt results** map `.wait.reason`:
    - `ended` → `{ok:true,status:.wait.status,output}`;
    - `timeout` → `{ok:true,status:"timeout",output}`;
    - `not_started` → `{ok:false,error:"the agent did not start the turn"}`.
  - **Interrupt results** map `outcome`: `stopped` → ok, `still_working` →
    `{ok:true,note:"still working"}`.
  - **Demo mode:** every `app-*` write does nothing, and `app-list` returns one
    fixed demo app row.
- **A4: the window.**
  - Intersect `pgrep -x herdr-app` with the PIDs in `hyprctl clients -j`.
  - Exactly one match: focus it with #20's checked `hl.dsp.focus`. None: start
    the window. Several: `die "more than one herdr-app window"`.
  - Start it with `setsid uwsm-app -- herdr-app`, under the caller's umask
    (#21), with output to `/dev/null`. Then wait until `herdr-app ls`
    answers.
- **A5: the model and the UI.**
  - **Sources:** `appSessions` and `appHostSessions` (menu only).
    `rebuild()` orders them classic local, app local, classic remote, app
    remote.
  - **Keys:** for an app row,
    `sessionKey = "app\u0000"+machine+"\u0000"+spaceId`; other rows are
    unchanged. `agentKey` uses the hc address.
  - **Captured targets:** `a` captures `{kind, host, session, pane}`, and `n`
    captures `{kind, machine}`. Submission uses only what was captured.
  - **Dispatch by kind:**
    - Enter or a click → `app-focus`, `a` → `app-prompt`, `i` →
      `app-interrupt`;
    - `K` → confirm, "End <title>?" plus "and with it: …" → `app-kill`. A
      `changed` reply asks again.
    - `n` on an app row → `app-new`.
  - **No destroy column on app rows.**
  - **Labels:**
    - the subtitle is "desktop app" (plus the machine for remote rows), or
      "not live" while stale;
    - the background row is named "background";
    - `error` shows as "error" in the urgent colour;
    - blocked agents with a `.status.kind` show "needs you: <kind>".
- **A6: staleness.**
  - Data is stale when the subscription is down or the last `app-list`
    failed. Stale rows read "not live", and kill and interrupt are refused.
  - A machine whose state isn't `connected` is marked "not live", with actions
    refused there.
  - The tooltip says "herdr-core not reachable" while stale.
  - `appError` shows in the error line after `actionError` and `errorText`.

## Repo traps (apply to every step)

- **The script is piped to remote hosts as `bash -s`.** It stays one
  self-contained file. App commands run only locally, since hc does the
  remoting.
- **CI runs shellcheck,** so new code must pass it.
- **jq inputs go on stdin or through `--slurpfile` or `--rawfile`,** never as
  `--arg` with large data.
- **#20's process discipline:**
  - every external call goes through `bounded`, except the long-lived
    subscription;
  - every background child is added to `JOB_PIDS`;
  - `kill_tree` runs on exit.
- **Tests use fakes only.** No test touches the real hc, herdr-app,
  Hyprland, ssh or a terminal. The `hc events` fake must keep streaming until
  it is killed.
- **Fakes use schema-shaped objects:** `status:{state,kind}`, never a bare
  string.
- **`tests/session-actions.cjs` extracts top-level functions with a regex.**
  New logic goes in top-level functions, indented two spaces, with the
  closing brace on its own line.
- **Every QML `Text` keeps `textFormat: Text.PlainText`.**
- **Omarchy's key handler takes lowercase `k` and `x`.** `i` reaches the panel
  (`PanelKeyCatcher.qml:119`).
- **Implementers never stage, commit, push or switch branches.** The lead
  commits after each step.

## Steps

1. **`bin/herdr-sessions`: the tool checks and `app-list` (A2).**
   - `require_tools` takes a list of tools, chosen per command in the dispatch
     `case`. `list` on a machine without herdr returns an empty, ok list.
   - Add `valid_hc_address`, `app_snapshot` (the fifo reader and cleanup),
     `app_window_status`, `app_attention` and `cmd_app_list`. Add the
     dispatch entry `app-list`, which also honours demo mode.
   - **Fakes in `tests/herdr-sessions.sh`:**
     - `hc` (`events` streams `FAKE_HC_SNAPSHOT` and then heartbeats;
       `machine ls` prints `FAKE_HC_MACHINES`);
     - `herdr-app` (`ls`: `FAKE_APP_LS`, or exit `FAKE_APP_LS_FAIL=refused`
       or `=other`);
     - `HOME`'s `.config/herdr-app/view.json` from `FAKE_VIEW_JSON`.
   - **The spec's `app-list` cases:**
     - agents only;
     - grouping (duplicate names, the same id on two machines, a rename,
       `where` split on its last `" / "`);
     - parents (through a non-agent, a grandchild, a missing parent, a local
       bare parent never matching a remote child);
     - the status rules and `windowOpen` true, false or null;
     - the cascade (grandchildren and shells in, `die_with_parent:false`
       out);
     - an oversized or malformed snapshot, and no orphaned producer;
     - remote filtering, with no address listed twice;
     - hc-only machines and demo mode.

   Verify:

   ```bash
   for f in bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh; do bash -n "$f"; done
   shellcheck bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh
   bash tests/herdr-sessions.sh
   ```

   Traps:
   - Use a fifo, not `read < <(…)` (it hides the producer's status) and not a
     bare `head` (it panics hc on a broken pipe that nothing cleans up).
   - The 16-level depth limit guards against parent cycles.

2. **`bin/herdr-sessions`: the `app-*` actions and the window (A3, A4).**
   - Add `cmd_app_focus`, `cmd_app_prompt`, `cmd_app_interrupt`,
     `cmd_app_kill` (with the hash check, reusing step 1's cascade jq) and
     `cmd_app_new`.
   - Add the helpers `hc_call` (maps stderr JSON and exit codes) and
     `app_raise_window`, which reuses the address and workspace shape checks
     in `show_session`. Add the dispatch entries, with demo no-ops.
   - **Fakes:**
     - `hc send`, `read`, `interrupt` and `kill` return `FAKE_HC_<CMD>_OUT`,
       or exit with `FAKE_HC_<CMD>_RC` and print stderr JSON;
     - `herdr-app do` logs its argv;
     - `pgrep` and `hyprctl clients` are steered for the window cases.
   - **The spec's action cases:**
     - prompt text starting with `-`, and text spanning several lines, arrives
       as one argument after `--`;
     - `--force` is passed only when the flag is given;
     - each `.wait.reason` maps correctly, and so does interrupt's
       `still_working`;
     - exit codes 3, 9 and 11 give hc's message, and a timeout gives
       `timed out`;
     - herdr-app's error JSON is decoded;
     - a kill with a stale hash returns `changed` and does not kill;
     - window: no window starts one and then focuses it, two windows are an
       error, and a CLI-only process is not taken for the window;
     - every address is validated, and demo mode makes every action do
       nothing.

   Verify: the same three commands as step 1.

3. **`HerdrModel.qml`: the subscription, the sources, the keys and staleness
   (A1, A5 model, A6).**
   - **Processes and timers:**
     - `appSubProc` with a `SplitParser`;
     - `appCoalesce` (one-shot, 250 ms), `appWatchdog` (40 s) and
       `appBackoff`;
     - `appListProc`, run through #20's `launch` and `complete` pattern.
   - **State:** `hcAvailable`, `appStale`, `appDirty`, `appError`,
     `appSessions`, `appHostSessions`, `appMachines`.
   - **`rebuild()`** merges the four sources. `sessionKey` gives app rows
     their own key, and `agentKey` uses the address for them.
   - **Kind-aware entry points,** each a top-level function:
     - `activateCursor` and `focusAgent` → `app-focus`;
     - `requestInterrupt`;
     - `askKill` and `confirmPending` → `app-kill`, with the hash, handling a
       `changed` reply;
     - `requestNew` captures the machine for app rows;
     - `appRowState`, which gives "not live" for stale data or an unconnected
       machine;
     - kill and interrupt are refused while not live.
   - **Display helpers:**
     - `agentNote` and `agentColor` handle `error` and the blocked kinds;
     - `countLabel` and `subtitleFor` handle app rows;
     - `tooltipText` handles staleness.
   - **`tests/session-actions.cjs`** gains the spec's model cases:
     - coalescing under a stream of events;
     - heartbeats reset the watchdog without triggering;
     - `appDirty` gives exactly one more run;
     - the four-source merge, with no key collision, and the cursor following
       a renamed space;
     - kind dispatch, and app rows having no destroy action;
     - the cascade confirm, and asking again on `changed`;
     - staleness rules, including that a restart alone doesn't clear it;
     - an unconnected machine.

   Verify:

   ```bash
   node tests/session-actions.cjs
   omarchy plugin validate .
   ```

4. **`Menu.qml` and `Card.qml`: captured targets, keys, the confirm and
   labels (A5 UI).**
   - **Menu:**
     - `beginInput` captures `{kind, host, session, pane}` for `a` and
       `{kind, machine}` for `n`;
     - `submitPrompt` and `submitNew` route by the captured kind
       (`app-prompt`, with `--force` only after the busy confirmation;
       `app-new`);
     - `promptDone` handles `note`.
   - **Card:**
     - `i` in the key handler calls `herd.requestInterrupt()`;
     - app rows show no destroy button;
     - the subtitle and labels follow A5;
     - the confirm message comes from `herd.confirmMessage()`, which now
       includes the cascade.
   - **Tests:** extend the Menu block in `tests/session-actions.cjs`:
     - a target captured on an app row survives a cursor move;
     - an app prompt routes to `app-prompt`, with `--force` only after the
       confirmation.

   Verify: `node tests/session-actions.cjs`, then `omarchy plugin validate .`.

5. **`tests/app-subscription.qml`: the QML wiring check (spec R5).**
   - A minimal QML file instantiates `HerdrModel` with `script` pointing at a
     stub, and `hc` on `PATH` pointing at a fake that prints a snapshot, then
     event lines in quick succession, then heartbeats.
   - It asserts that one `app-list` run happens (counted by the stub), then
     exits.
   - It runs headless with `QT_QPA_PLATFORM=offscreen qs -p
     tests/app-subscription.qml`, wrapped in `tests/app-subscription.sh`.
   - **If `qs` can't load a single file headless here,** the step stops and
     reports it. The check then becomes a step 8 live item, and is recorded as
     a deviation, not forced.

   Verify: `bash tests/app-subscription.sh` exits 0.

6. **`README.md` and `manifest.json`.**
   - `"version": "1.1.0"`. This is a feature; the `description` adds "and the
     herdr desktop app's agents".
   - In the README, a short "Desktop app (herdr-core)" section:
     - spaces as rows, done or seen following the window;
     - keys `i` and `K` on app agents, with the cascade confirm;
     - app rows never close a space or stop the core;
     - remote machines come from `hc machine ls`, menu only;
     - machines with only hc are supported.
   - The keybinding tables gain `i`.

   Verify: `jq -e '.version == "1.1.0"' manifest.json`, then
   `omarchy plugin validate .`.

7. **Lead: review fixes, push and PR.**
   - Commit each step after reviewing its diff.
   - Then the reviews below. Fixes are committed, then `git status
     --porcelain` must be clean.
   - Push, and open the PR linking the intent, spec and plan. It is merged
     with `--merge`, with your OK.

8. **Lead, after merge and deploy: the live checks.** The deploy is a
   nixarchy pin bump plus the p620 deploy, with your OK and announced on the
   bus. The checks use throwaway labelled terminals, killed afterwards.
   - **An agent in its space row:**
     - blocked turns the badge red;
     - done then seen follows the window's attention, with the window open and
       with it closed.
   - **Focus** with the window closed opens it and lands on the agent.
   - **Prompt,** including `--force` on a blocked agent.
   - **Interrupt.**
   - **Kill,** with the confirmation naming the sub-agents.
   - **A `razer/tN` agent** (`hc run --on razer`) appears in the menu only.
   - **The `i` key.**
   - **On a host without hc,** the bar's cost is unchanged.

## Tests

```bash
for f in bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh; do bash -n "$f"; done
shellcheck bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh
bash tests/herdr-sessions.sh        # existing cases plus about 30 new, all ok
node tests/session-actions.cjs      # existing cases plus about 15 new, all PASS
bash tests/app-subscription.sh      # step 5, or a recorded deviation
omarchy plugin validate .
```

## Review

- **Opus:** a fresh agent gets this plan plus
  `git diff master...feat/22-herdr-core-app`.
- **codex:** this plan plus the diff of `HerdrModel.qml`, `Menu.qml` and
  `Card.qml`; it may open those files in full.
- **agy:** this plan plus the diff of `bin/herdr-sessions` only.

The lead weighs the findings. Agent output never approves anything.

## Rollback

- **Before merge:** delete the branch.
- **After merge:** `git revert -m 1 <merge commit>`.
- **No state migration.** The plugin only reads hc and herdr-app state
  (`view.json` is read-only to it).
