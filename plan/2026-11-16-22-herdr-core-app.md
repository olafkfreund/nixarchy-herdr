---
status: approved
issue: 22
spec: spec/2026-11-16-22-herdr-core-app.md
coders:
  1: codex   # app-list: the fifo reader, the cleanup, and the jq graph walk (parents across machines, sub-agents that end with a kill); tricky bash and jq
  2: codex   # app-* actions: mapping hc results and exit codes, the cascade check, the window by PID; same author as step 1
  3: coder   # HerdrModel.qml: the subscription, coalescing, the watchdog, the sources, keys, staleness, the kill confirm logic
  4: coder   # Menu.qml and Card.qml: captured targets, the i key, rendering, the error line
  5: coder   # tests/app-subscription.qml: the QML wiring check (coalescing, watchdog, restart)
  6: coder   # README and manifest
reviewers:
  - codex  # reads steps 3-5 (QML and their test diffs), which it did not write
  - agy    # reads steps 1-2 (the bin/ diff plus the existing helper bodies it calls); narrow input, because it timed out on large ones
---

# Plan: show herdr-core and herdr-app agents, one row per space

Closes #22 on branch `feat/22-herdr-core-app`. It starts from master
`9c8a8fa` (#20 and #21 merged) plus this task's artifacts. Functions are named
rather than numbered, because line numbers move.

Revision 2 follows the reviews of revision 1:

- **Codex** (gpt-6.1-sol): seven findings, all taken.
- **agy** (model not reported): eight findings, all taken.

## CLI contracts

These come from hc 0.1.21's `hc schema` and help, and from herdr-app 0.1.16's
real output. Every fake must produce exactly these shapes, and no step may
call the real tools.

- **`hc events --json`** first prints one line, `{"seq":N,"terminals":[Terminal…]}`.
  After that come event lines, `{"…":"heartbeat"…}` lines every 15 s, and on
  overflow a `missed` line plus a new snapshot. The subscription treats any
  line other than a heartbeat as a trigger, and never reads its fields.
- **A `Terminal`** has these fields (paths are exact):
  - `.address`: `"t3"`, or `"razer/t4"` on a connected machine;
  - `.state`: `"live"` or `"finished"`;
  - `.status`: `null`, or `{"state":"idle|working|done|blocked|error", "kind":
    "permission|question|auth"|null, …}`;
  - `.parent`: `null`, a bare `"t3"` (the same machine), or `"razer/t3"`;
  - `.die_with_parent`: a boolean;
  - `.labels`: `{"where":"<space> / <tab>", "herdr.space":"sp…",
    "herdr.tab":"tb…", …}`, where the ids are local to the terminal's own
    machine;
  - `.title` (a string), `.argv` (an array), `.status_ms` (a number).
- **`hc machine ls --json`** gives `{"machines":[{"name":"razer",
  "state":"connected", …}]}`. The CLI's view adds `state`.
- **`hc send --json --wait [--force] -- ADDR TEXT`** gives `{started, status,
  turn, wait:{reason, ended, status, exit_code}}`.
  - `wait.reason` is one of `status`, `exit`, `output`, `timeout` or
    `not_started`.
  - `hc` defaults to JSON when piped, but the plan always passes `--json`.
- **`hc read --lines 60 ADDR`** always prints plain text.
- **`hc interrupt --json ADDR`** gives `{key, outcome}`, with `outcome` one of
  `stopped`, `exited`, `still_working` or `unknown`.
- **`hc kill --json ADDR`** exits 0 on success. Its body is not needed.
- **hc errors** go to stderr as `{"error":{"kind","message","hint"}}`, with
  exit codes 3 not_found, 7 needs_target, 9 blocked, 10 status_mismatch,
  11 finished.
- **`herdr-app ls`** gives `{"spaces":[{"id","name","machine":null|"razer",
  "tabs":[{"id","name","terminals":[{"terminal":"t3","pane":"p…",
  "status":"done"|null,…}]}]}]}`.
  - The address is `(machine ? machine + "/" : "") + terminal`.
  - Without a window it exits non-zero, with stderr containing "Connection
    refused".
- **`herdr-app do CMD --k v`** prints JSON ids on success, or
  `{"error":"…"}` on stdout with exit 1.
- **`~/.config/herdr-app/view.json`** holds
  `{"attention":{ADDR:{"word":"done"|"idle"|null,"seen":true|false}}, …}`.

## Approved decisions (summarised from the spec)

- **A1: subscription (`HerdrModel`).**
  - **Reading.** `appSubProc` runs `hc events --json` into a `SplitParser`,
    attached before the process starts.
  - **Coalescing.**
    - The first line that isn't a heartbeat starts a one-shot timer
      (`appCoalesceMs`, default 250). Later lines never restart it.
    - When it fires, `appListProc` runs `app-list`.
    - A line arriving while it runs sets `appDirty`, and exactly one more run
      follows.
  - **Watchdog.** Every line resets a watchdog (`appWatchdogMs`, default
    40000).
  - **Restart.** The watchdog firing, or the process exiting after it
    started, leads to:
    - a kill, if it is still running;
    - `appStale = true`;
    - a restart after a backoff of 2, 4, 8 … up to 60 s. The backoff goes
      back to 2 s after the next successful `app-list`.
  - **No hc at all.** A failed start (#20's `startFailed` path) sets
    `hcAvailable = false`, with no retry and no rows.
  - **Staleness** is cleared only by a successful `app-list`.
  - **Malformed lines** are ignored, apart from resetting the watchdog.
  - **Tunable timers.** `appCoalesceMs`, `appWatchdogMs` and `appBackoffMs`
    are properties, so step 5's test can shorten them.
  - **R4.** Each `HerdrModel` instance owns one subscription: about 4 idle
    processes with 3 monitors. Sharing them is #23's.
- **A2: `bin/herdr-sessions app-list [--remote]`.**
  - **Snapshot reader.**
    - `run_dir_init`, then `mkfifo "$RUN_DIR/hc-events"`.
    - `bounded 3 hc events --json 2>/dev/null > fifo &`, with its pid added
      to `JOB_PIDS`.
    - `head -c "$((TOTAL_BYTE_CAP + 1))" < fifo | head -n 1` reads the first
      line.
    - Then `kill_tree` the producer, `wait` for it, and remove the fifo.
    - The line must parse as JSON with a `.terminals` array, and must not be
      over the cap. Otherwise `die "could not read herdr-core"`.
  - **In parallel, both optional:**
    - `bounded 1 herdr-app ls`. Success gives `windowOpen: true`, and the
      app's statuses mapped by address as in the contract. An error
      containing "Connection refused" gives `false`. Anything else gives
      `null`.
    - `view.json` `.attention`, capped at `SESSION_FILE_CAP`. Missing or
      unreadable gives `{}`.
  - **One jq merge,** with every input on stdin or `--slurpfile`/`--rawfile`:
    1. **Enrich every terminal.**
       - `machine`: what precedes `/` in `.address`, or `""`.
       - `state`: `.status.state // null`.
       - `parentAddr`: `null`; `.parent` if it contains `/`; else a bare
         parent is prefixed with this terminal's machine (`machine/parent`).
    2. **Agent** means `.state == "live"` and `state != null`.
    3. **`spaceId`**: `.labels["herdr.space"]`; else the nearest ancestor's,
       walking `parentAddr` at most 16 hops (that also guards against
       cycles); else `"_background"`.
    4. **Names.**
       - The row name is the part of `.labels.where` before the last
         `" / "`, and the tab is the part after it.
       - With no `where`, the name is `"space"` and the tab `""`.
       - The background row is always named `"background"`.
    5. **Status.**
       - If `windowOpen == true`, use the app's status for the address when
         it isn't null.
       - Otherwise use `state`. But `done` with attention
         `{word:"done", seen:true}` becomes `idle`, and `error` stays
         `error`.
       - **R1, accepted limit:** a second finish while the window is closed
         may still read as seen, because the attention record has no turn.
    6. **`cascade`**, built from the full terminal list before any cap:
       - every live terminal reachable through `parentAddr` edges with
         `die_with_parent == true`, transitively;
       - each entry is `{address, title}`, sorted by address;
       - `cascadeKey` is those addresses joined with `","` (`""` when there
         are none).
    7. **Grouping** with `group_by([.machine, .spaceId])`. Each row is:

       ```text
       {kind:"app", name, host:machine, spaceId, running:true,
        readable:true, stale:false, agents, blocked, done, working,
        hiddenAgents,
        agentList:[{title, status, kind:.status.kind, pane:address, tab,
                    seq:status_ms, cascade, cascadeKey}],
        projects:[], windowAddress:""}
       ```

       - The row field is `host`, as on classic rows; QML never reads
         `machine`.
       - The title is `.title`, else `argv[0]`'s basename, else
         `"untitled agent"`.
       - #20's D9 applies: a cap of 500, with counts taken after it.
    8. **`--remote`.** Without it, keep only `machine == ""`.
  - **Output:** `{ok, error, sessions, windowOpen, machines}`.
    - `machines` is the `machines` from `bounded 2 hc machine ls --json`,
      with `--remote` only. Otherwise it is `[]`.
  - **Tool checks.** `require_tools` checks `jq` always, `herdr` only for the
    classic commands, and `hc` only for `app-*`. A missing `herdr` makes
    `list` return `{ok:true, error:"", sessions:[]}`.
- **A3: actions.**
  - **Shared rules.**
    - `valid_hc_address` is
      `^([A-Za-z0-9][A-Za-z0-9._-]{0,31}/)?t[0-9a-z]{1,9}$`.
    - No `--host`, no ssh.
    - hc's stderr JSON `.error.message` is passed through. Exit 124 or 137
      gives `timed out: <action>`. herdr-app's `{"error"}` is decoded.

  | Subcommand | Does | Limit |
  |---|---|---|
  | `app-focus ADDR` | `herdr-app do agent.focus --terminal ADDR`; if the window is closed, start it (A4) and retry until 5 s; then raise it (A4) | 6 s |
  | `app-prompt ADDR [--force]`, text on stdin | `hc send --json --wait [--force] -- ADDR "$text"`, then `hc read --lines 60 ADDR` | 300 s |
  | `app-interrupt ADDR` | `hc interrupt --json ADDR` | 12 s |
  | `app-kill ADDR CASCADE_KEY` | recompute ADDR's `cascadeKey` from a fresh snapshot (step 1's code); if it differs, `{ok:false, changed:true, cascade, cascadeKey}`; otherwise `hc kill --json ADDR` | 8 s |
  | `app-new NAME DIR MACHINE`, always three arguments, `""` allowed | `herdr-app do space.new --name NAME [--folder DIR] [--machine MACHINE]`, starting the window first if needed | 8 s |

  - **Arguments are validated.**
    - `CASCADE_KEY` is `""` or comma-separated `valid_hc_address` values, at
      most 4096 bytes.
    - `NAME` passes `valid_session_name`. `DIR` is `""` or an absolute path.
      `MACHINE` is `""` or passes `valid_host`.
  - **Prompt result**, from `.wait.reason`:
    - `status` or `exit`: `{ok:true, status:(.wait.status // "idle"),
      output: <read>}`.
    - `timeout`: `{ok:true, status:"timeout", output: <read>}`.
    - `output`: `{ok:true, status:"output", output: <read>}`.
    - `not_started`: `{ok:false, error:"the agent did not start the turn"}`.
  - **Interrupt result**, from `.outcome`:
    - `stopped` or `exited`: `{ok:true}`.
    - `still_working`: `{ok:true, note:"still working"}`.
    - `unknown`: `{ok:true, note:"it doesn't report status"}`.
  - **Demo mode:** every `app-*` write is a no-op, and `app-list` returns one
    fixed demo app row.
- **A4: the window.**
  - **Finding it.** Intersect the PIDs from `pgrep -x herdr-app` with the PIDs
    in `hyprctl clients -j`.
    - Exactly one match: focus it with #20's checked `hl.dsp.focus`.
    - None: start the window.
    - More than one: `die "more than one herdr-app window"`.
  - **Starting it.**
    - `setsid uwsm-app -- herdr-app` if `uwsm-app` exists, else
      `setsid herdr-app`.
    - It runs under the caller's umask (#21), with
      `</dev/null >/dev/null 2>&1 &` and `disown`.
    - It is **not** added to `JOB_PIDS`, so the script's cleanup never kills
      the window it opened.
    - Then wait until `herdr-app ls` answers.
- **A5: model and UI.**
  - **Sources.** `appSessions` and `appHostSessions`.
    - The menu's `HerdrModel` (`remote: true`) runs `app-list --remote` and
      splits rows by `host === ""` (local) or not (remote).
    - The bar's instance runs `app-list` only, and never gets remote rows.
    - `rebuild()` merges: classic local, app local, classic remote, app
      remote.
  - **Keys.** For an app row, `sessionKey = "app\u0000" + host + "\u0000" +
    spaceId`. Other rows are unchanged. `agentKey` uses the hc address.
  - **Validators.** App agents use `validHcAddress` (the same regex as the
    script) instead of `validPane`. App space names are display only, never
    passed to `validName`.
  - **Captured targets.**
    - `a` captures `{kind, host, session, pane}`.
    - `n` captures `{kind, host}`.
    - `Menu.targetStatus` reads the captured target, not the cursor.
  - **Dispatch by kind.**
    - Enter or a click on an app agent: `app-focus`.
    - Enter on an app row header: `app-focus` of its first agent.
    - `a`: `app-prompt`, with `--force` only after Menu's busy or blocked
      confirmation.
    - `i`: `app-interrupt`. A `note` in the result is shown in the error
      line.
    - `K`: confirm, then `app-kill` with `cascadeKey`. On a `changed` reply
      the confirmation reopens with the new cascade.
    - `n` on an app row: `app-new` with that row's host.
    - There is no destroy column on app rows.
  - **Labels.**
    - Subtitle: "desktop app", plus the host for remote rows, or "not live".
    - `agentNote(status, kind)`, where `kind` is optional: `error` shows as
      "error" in the urgent colour, and a blocked agent with a kind shows
      "needs you: <kind>".
- **A6: staleness.**
  - **A row is "not live"** when `appStale` is set (the subscription is down,
    or the last `app-list` failed), or when its host's machine state isn't
    `"connected"`.
  - **Refused on a "not live" row:** every app action (focus, prompt,
    interrupt, kill and new space), with the message "<host or desktop app>
    is not live".
  - **The tooltip** says "herdr-core not reachable" while `appStale` is set.
  - **The error line** shows, in this order: `actionError`, `errorText`,
    `appError`, then the hidden-sessions note.

## Repo traps (apply to every step)

- **The script is piped to remote hosts as `bash -s`.** It stays one
  self-contained file. App commands run locally only; hc does the remoting.
- **CI runs shellcheck.** New code passes it.
- **jq inputs** go on stdin or through `--slurpfile` or `--rawfile`, never as
  a large `--arg`.
- **#20's process discipline holds:** `bounded` for every call, `JOB_PIDS`
  for background children, and `kill_tree` on exit. Two exceptions:
  - the long-lived subscription, in QML;
  - the herdr-app window that A4 starts.
- **Tests use fakes only.** Shapes follow the CLI contracts above, with
  `status` as an object. The `hc events` fake keeps streaming until it is
  killed.
- **`tests/session-actions.cjs` extracts top-level functions with a regex.**
  New logic goes in top-level functions indented two spaces, with the closing
  brace on its own line.
- **QML `Text`** uses `textFormat: Text.PlainText`.
- **Keys.** Omarchy's key handler takes `k` and `x`; `i` reaches the panel.
- **Commits.** Implementers never stage, commit, push or switch branches. The
  lead commits after each step.

## Steps

1. **`bin/herdr-sessions`: tool checks, `app-list` and the cascade (A2).**
   - **Script changes.**
     - `require_tools` checks per command (see A2), and `list` copes with no
       `herdr`.
     - Add `valid_hc_address`, `app_snapshot` (the fifo reader and its
       cleanup), `app_window_status`, `app_attention`, and `app_merge_jq`
       (the jq program as a shell variable, so step 2 reuses it for the
       cascade).
     - Add `cmd_app_list`, and the `app-list` dispatch entry with demo mode.
   - **Fakes.**
     - `hc`: `events` prints `FAKE_HC_SNAPSHOT`, then a heartbeat line every
       0.2 s until killed. `machine ls` prints `FAKE_HC_MACHINES`.
     - `herdr-app`: `ls` prints `FAKE_APP_LS`, or fails with "Connection
       refused" (`FAKE_APP_LS_FAIL=refused`) or with another error (`=other`).
     - `$HOME/.config/herdr-app/view.json` comes from `FAKE_VIEW_JSON`.
   - **Cases.**
     - Agents: only live terminals with a status.
     - Grouping:
       - duplicate names stay apart;
       - the same space id on two machines stays apart;
       - a rename keeps the row;
       - `where` with two `" / "` splits on the last;
       - the background row is named "background".
     - Parents: through a non-agent, a grandchild, a missing parent, and a
       bare parent that never crosses machines.
     - Status rules, and `windowOpen` true, false and null.
     - Cascade:
       - grandchildren and shells are in, `die_with_parent: false` is out;
       - `cascadeKey` is sorted;
       - a descendant beyond the 500-agent cap is still in the cascade.
     - Counts with 501 agents equal the shown 500, and `hiddenAgents` is 1.
     - Snapshots: an oversized or malformed one gives the error, and no
       producer is left after `app-list`.
     - Remote: filtered without `--remote`, no address twice, and `machines`
       present only with `--remote`.
     - hc-only machine; no hc gives `could not read herdr-core`; demo mode.

   Verify:

   ```bash
   for f in bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh; do bash -n "$f"; done
   shellcheck bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh
   bash tests/herdr-sessions.sh
   ```

2. **`bin/herdr-sessions`: the `app-*` actions and the window (A3, A4).**
   - **Script changes.**
     - Add `hc_call`, which maps stderr JSON and exit codes.
     - Add `app_raise_window` (A4, reusing `show_session`'s checks and focus
       call) and `app_start_window` (the `uwsm-app` or plain `setsid`
       fallback, not in `JOB_PIDS`).
     - Add `cmd_app_focus`, `cmd_app_prompt`, `cmd_app_interrupt`,
       `cmd_app_kill` (which reuses step 1's snapshot and `app_merge_jq` to
       recompute `cascadeKey`) and `cmd_app_new`.
     - Add the dispatch entries, with demo no-ops.
   - **Fakes.**
     - `hc send`, `read`, `interrupt` and `kill` print
       `FAKE_HC_<CMD>_OUT`, or exit `FAKE_HC_<CMD>_RC` with stderr error JSON.
     - `herdr-app do` logs its arguments.
     - `pgrep` and `hyprctl clients` can be steered.
     - `uwsm-app` is present or absent.
   - **Cases.**
     - Prompts:
       - a leading `-` and multi-line text each arrive as one argument after
         `--`;
       - `--force` is passed only when given;
       - every `wait.reason`, including `output` and `not_started`, maps.
     - Interrupt: every `outcome` maps.
     - Exit codes 3, 9 and 11 give hc's message; a timeout gives
       `timed out`; herdr-app's error JSON is decoded.
     - Kill:
       - a stale `cascadeKey` gives `changed` and no kill;
       - a matching key does kill, and the fake logs `kill`.
     - `app-new` with:
       - all three arguments;
       - an empty `DIR` with a machine;
       - an empty machine;
       - an invalid name, directory or machine, each refused.
     - Window:
       - none: it starts, then focuses;
       - starts without `uwsm-app` too;
       - two windows give an error;
       - a CLI-only `herdr-app` process is not taken for the window;
       - the started window is not in `JOB_PIDS`.
     - Every address is validated. Demo mode makes every action a no-op.

   Verify: the same three commands as step 1.

3. **`HerdrModel.qml`: subscription, sources, keys, staleness and the kill
   confirm (A1, A5 model, A6).**
   - **Processes and timers.**
     - `appSubProc` (`SplitParser`; `onExited` restarts it with backoff).
     - `appCoalesce`, `appWatchdog` and `appBackoff`, with the tunable
       properties.
     - `appListProc`, a `Process` with its own `kind: "applist"` handled by
       `storeResult`/`complete`. It is **not** `launch()`, so it never
       touches `actionError` or dismisses anything.
   - **State.** `hcAvailable`, `appStale`, `appDirty`, `appError`,
     `appSessions`, `appHostSessions`, `appMachines`.
   - **`complete("applist")`** splits rows by host (menu instance only),
     clears `appStale`, and resets the backoff.
   - **`rebuild()`** merges the four sources. `sessionKey` and `agentKey`
     follow A5. Add `validHcAddress`.
   - **Kind-aware entry points.**
     - `activateCursor`, including an app row header, and `focusAgent`.
     - `requestInterrupt()`.
     - `askKill`, `confirmPending`, and the `changed` reply, which updates the
       confirm target's cascade and calls `activeCard.beginConfirm()` again.
     - `confirmMessage()` with the cascade line.
     - `requestNew` captures the host.
     - `appRowNotLive(session)`, and A6's refusal of every app action.
   - **Display helpers.**
     - `agentNote(status, kind)`, with `kind` optional.
     - `agentColor` for `error`.
     - `countLabel` and `subtitleFor` for app rows.
     - `tooltipText` when stale.
     - An interrupt `note` goes into `actionError`.
   - **`tests/session-actions.cjs`, model-level cases only.**
     - Coalescing under a stream; heartbeats reset the watchdog without
       triggering; `appDirty` gives exactly one more run.
     - A watchdog timeout, or an `onExited`, sets stale and schedules a
       restart; only a successful `app-list` clears stale and resets the
       backoff.
     - A start failure sets `hcAvailable = false`, with no retry.
     - The four-source merge with the menu split; the bar never gets remote
       rows; no key collision; the cursor follows a renamed space.
     - Kind dispatch to the right subcommands and arguments:
       - `app-new` always gets three arguments;
       - `app-kill` gets `cascadeKey`;
       - a `changed` reply reopens the confirm with the new cascade.
     - `confirmMessage()` names the cascade.
     - A "not live" row (stale, or its machine not connected) refuses focus,
       prompt, interrupt, kill and new.

   Verify: `node tests/session-actions.cjs`, then `omarchy plugin validate .`.

4. **`Menu.qml` and `Card.qml`: captured targets, keys, rendering and the
   error line (A5 UI, A6 UI).**
   - **Menu.**
     - `beginInput` captures A5's targets.
     - `targetStatus` reads the captured target.
     - `submitPrompt` routes by the captured kind (`app-prompt`, with
       `--force` only after the busy confirmation).
     - `submitNew` routes to `herd.newAppSpace(host, name, dir)`.
   - **Card.**
     - `i` in the key handler calls `herd.requestInterrupt()`.
     - App rows render no destroy button.
     - Labels follow A5.
     - The error line follows A6's order (`appError` after `errorText`).
   - **Tests:** extend the Menu block in `tests/session-actions.cjs`.
     - A captured app target survives a cursor move.
     - An app prompt routes to `app-prompt`, with `--force` only after the
       confirmation.
     - New on an app row goes to the app path.
     - Card's pure helpers, where they exist, cover no destroy on app rows and
       the error order.

   Verify: `node tests/session-actions.cjs`, then `omarchy plugin validate .`.

   **Deviation (implementation):** the error line is built by a new
   `errorLine()` in `HerdrModel.qml`, so its order is testable in node. Order:
   `actionError`, `errorText`, `appError`, "Could not reach herdr.", then the
   hidden-sessions note.

5. **`tests/app-subscription.qml` and `tests/app-subscription.sh`: the QML
   wiring (R5).**
   - **Setup.**
     - Instantiate `HerdrModel` with `appCoalesceMs: 100`,
       `appWatchdogMs: 1500` and `appBackoffMs: 200`.
     - `script` points at a stub that counts `app-list` runs into a file and
       prints valid JSON.
     - `hc` on `PATH` is a fake that prints a snapshot, then five event lines
       50 ms apart, then goes silent.
   - **Asserts.**
     1. The burst gives exactly one `app-list` run, within 500 ms.
     2. After the silence, the watchdog fires: `appStale` is true and the
        fake is started again (it logs its start).
     3. After the restart's snapshot and one `app-list`, `appStale` is false.
   - **Running it.** `QT_QPA_PLATFORM=offscreen qs -p
     tests/app-subscription.qml`, wrapped in a 20 s `timeout`. It exits 0 on
     success and 1 with the failing assert.
   - **If `qs` cannot load a single file headless here,** the step stops and
     reports to the lead. The lead asks the owner before replacing it. It is
     never skipped silently.

   Verify: `bash tests/app-subscription.sh` exits 0.

   **Deviations (implementation):** the fake prints the five event lines back
   to back, because lines 50 ms apart can legitimately start a second run
   inside a 100 ms coalesce window. A fourth assert was added: after the fake
   exits normally, `hcAvailable` stays true and the subscription restarts.
   The test copies the model with a stub `qs.Commons`
   (`tests/app-subscription-stubs/`) into a temp shell directory.

6. **`README.md` and `manifest.json`.**
   - **Manifest.** `"version": "1.1.0"`. The `description` adds "and the
     herdr desktop app's agents".
   - **README:** a short "Desktop app (herdr-core)" section.
     - Spaces show as rows.
     - Done and seen follow the window's attention.
     - Keys: `i` interrupts, `K` ends an agent, and the confirmation names
       what ends with it.
     - It never closes a space or stops the core.
     - Remote agents come from `hc machine ls`, in the menu only.
     - Machines with only hc work.
     - "not live" shows when herdr-core can't be reached.
   - **Keybinding tables** gain `i`.

   Verify: `jq -e '.version == "1.1.0"' manifest.json`, then
   `omarchy plugin validate .`.

7. **Lead: commit per step, review, push and PR.**
   - Commit each step after reviewing its diff. The reviews are listed below.
   - Fixes are committed, and the tree must be clean.
   - Push, then open the PR linking the intent, spec and plan. It is merged
     with `--merge`, with your OK.

   **Review fixes (deviations from A1-A6, after the Opus and Codex reviews):**
   - `app_snapshot` reads `head -n 1 | head -c CAP+1`; the planned order
     blocked until the next hc line (heartbeats every 15 s).
   - The cascade walks a children map down from each agent (depth 16), and the
     merge jq runs under `bounded 5`. `CASCADE_KEY` may be up to 65536 bytes.
   - The space walk stops at a machine boundary, and the row name and tab come
     from the terminal that supplied `herdr.space`.
   - A failed `hc read` after a sent prompt gives empty output; only a timeout
     fails. A failing `hyprctl` never launches a window.
   - Model: an `appGen` generation drops stale `app-list` results; a failed
     `app-list` retries on the shared backoff; app rows are not counted as
     servers; attention compares app agents (`status_ms`) only with each
     other, classic first.

8. **Lead, after merge and deploy: live checks.**
   - **Prerequisites:** a nixarchy pin bump, the p620 deploy with the owner's
     OK and a bus announcement, and razer reachable. Use throwaway labelled
     terminals and kill them afterwards.
   - **An agent in its space row.**
     - Blocked turns the badge red.
     - Done, then seen, follows the window's attention, with the window open
       and with it closed.
     - R1's sequence: finish twice with the window closed, and note what
       shows.
   - **Actions.**
     - Focus with the window closed opens it and lands on the agent.
     - Prompt, including `--force` on a blocked agent.
     - Interrupt.
     - Kill, with the confirmation naming the sub-agents.
   - **Remote.** A `razer/tN` agent (`hc run --on razer`) shows in the menu
     only. Disconnecting razer marks its rows "not live".
   - **The `i` key** works.
   - **On a host without hc,** the bar costs no more than before.

## Tests

```bash
for f in bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh; do bash -n "$f"; done
shellcheck bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh
bash tests/herdr-sessions.sh        # existing cases plus about 40 new, all ok
node tests/session-actions.cjs      # existing cases plus about 18 new, all PASS
bash tests/app-subscription.sh      # step 5
omarchy plugin validate .
```

## Review

- **Opus:** a fresh agent gets this plan and
  `git diff master...feat/22-herdr-core-app`.
- **codex:** this plan plus the diff of `HerdrModel.qml`, `Menu.qml`,
  `Card.qml`, `tests/session-actions.cjs` and `tests/app-subscription.*`. It
  may open those files in full.
- **agy:** this plan, the diff of `bin/herdr-sessions`, and the bodies of the
  existing helpers it calls: `bounded`, `kill_tree`, `run_dir_init`, `die`
  and `show_session`.

The lead weighs the findings. Agent output never approves anything.

## Rollback

- **Before merge:** delete the branch.
- **After merge:** `git revert -m 1 <merge commit>`.
- **No state migration.** The plugin only reads hc and herdr-app state.
