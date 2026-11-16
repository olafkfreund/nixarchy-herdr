---
status: draft
issue: 22
intent: intent/2026-11-16-22-herdr-core-app.md
---

# Spec: show herdr-core and herdr-app agents, one row per space

This implements the approved intent.

Revision 2 follows the Codex review of revision 1 (gpt-6.1-sol); all eleven
findings are taken. The agy review was not obtained: it hit its print timeout.

## Facts checked on p620 (hc 0.1.21, herdr-app 0.1.16)

- **`hc events --json`** starts with a full snapshot: `{"seq", "terminals":
  [Terminal…]}`. Finished terminals are included.
  - After the snapshot it sends events, a `heartbeat` every 15 s, and
    `missed` plus a fresh snapshot when a subscriber falls behind.
  - Errors go to stderr as `{error:{kind,message,hint}}`, with these exit
    codes: 3 not_found, 7 needs_target, 9 blocked, 10 status_mismatch,
    11 finished.
- **`Terminal.status`** is a **Status object or null**.
  - The word is in `.status.state`: idle, working, done, blocked or error.
  - `.status.kind` is permission, question or auth, set only when blocked.
  - It is null when the program never reported, or after it exited.
- **Other `Terminal` fields used here:**
  - `parent` is a bare ID for this machine, or `machine/tN` when hc can map
    it;
  - `die_with_parent` is a boolean;
  - `labels` includes `where` (`"<space> / <tab>"`), plus `herdr.space` and
    `herdr.tab` as ids local to that machine;
  - also `turn`, `title`, `argv`, `status_ms`.
- **Remote terminals:** the schema says the snapshot and the events include
  connected machines' terminals as `machine/tN`. No remote terminal was live
  when this was checked.
- **What counts as an agent:** herdr-app's guide says agents are terminals
  whose program reports an OSC 7501 status. Its `done` means finished while
  you weren't looking, and becomes `idle` once you look.
- **`~/.config/herdr-app/view.json`** has `attention`, a map from terminal
  address to `{word, seen}`.
  - It is herdr-app's own per-screen record of what you've looked at.
  - It is written by the app and stays on disk with the window closed.
  - The undocumented label `herdr.seen` is not used.
- **`herdr-app ls`** answers only while the window is open, and gives
  "connection refused" otherwise. Its other failures are different errors.
- **The `.desktop` file** declares no window class.
- **The `i` key** is passed on by the shell's key handler
  (`PanelKeyCatcher.qml:119`).

## Design

### A1. One subscription per model, used only as a change signal

`HerdrModel.qml` gains `appSubProc`, a `Process` running `hc events --json`.
Its stdout goes to a `SplitParser`, attached before the process starts, which
delivers one line at a time.

- **Coalesce, never postpone.**
  - The first non-heartbeat line after an idle period starts a one-shot
    250 ms timer. Later lines don't restart it.
  - When the timer fires, it runs `app-list` (A2).
  - A line that arrives while `app-list` runs sets `appDirty`, and exactly
    one more run follows.
  - So the badge updates at most about 250 ms plus one `app-list` after the
    first change, even under a constant stream of events.
- **Watchdog.**
  - Every line, heartbeat included, resets a 40 s timer: two heartbeats plus
    margin.
  - If the timer fires, the subscription is considered dead. It is killed
    and restarted with backoff (2, 4, 8 … up to 60 s), and the app data is
    marked stale (A6).
  - A malformed or truncated line is ignored, apart from resetting the
    watchdog.
- **No hc.** If `hc` cannot start (#20's `startFailed` path), `hcAvailable`
  becomes false. There are no app rows, no retries, and the bar costs nothing
  extra.
- **Stale until proven fresh.** A subscription that exits after starting
  restarts with backoff. A restart alone never clears staleness: only a
  successful `app-list` does.
- **Scope.**
  - Every `HerdrModel` instance has its own subscription. An idle one sends a
    heartbeat line every 15 s. Sharing one across instances is #23's.
  - The subscription is long-lived on purpose. Being watched and restarted
    replaces #20's per-call deadline; every other hc call is bounded.

### A2. `bin/herdr-sessions app-list [--remote]`

**Reading the snapshot** (the first line of a fresh `hc events --json`):

- **Start the reader.** `hc events --json` runs as a background child under
  `bounded 3`, writing into a fifo in #20's `RUN_DIR`, and its PID is added to
  `JOB_PIDS`.
- **Read one capped line.** The script reads the first line from the fifo with
  `head -c "$((TOTAL_BYTE_CAP + 1))" | head -n 1`. That caps the bytes, so a
  plain `read` never accumulates without limit.
- **Stop the producer.** Straight after reading, the producer gets
  `kill_tree` and `wait`. hc can hit a broken pipe only after the data was
  taken, and the script ignores its stderr; the `kill_tree` makes sure it
  never lingers.
- **Fail clearly.** An empty, oversized or non-JSON line, or one without a
  `.terminals` array, gives `die "could not read herdr-core"`. A successful
  read can never hide behind a producer that failed: the line has to validate
  on its own.

**Window and attention:**

- **Window status:** `bounded 1 herdr-app ls` is read **in parallel** with the
  snapshot, and its result is used only if it finishes inside its 1 s limit.
  - Success gives `windowOpen: true` and the app's statuses.
  - "connection refused" gives `windowOpen: false`.
  - Any other failure gives `windowOpen: null` (unknown). The rows still
    build; they just use hc's statuses.
  - So the window never delays the core state beyond 1 s.
- **Attention:** `~/.config/herdr-app/view.json` is read, capped at
  `SESSION_FILE_CAP`, and only `.attention` is kept. A missing or unreadable
  file means `{}`.

**One jq merge, in this order:**

1. **Enrich every terminal,** shells and finished ones included:
   - `machine` is the part before `/` in `address`, or `""`;
   - `state` is `.status.state // null`;
   - `parentAddr`: a bare `parent` becomes `machine + "/" + parent` for a
     remote terminal, so a local `t3` can never parent `razer/t4`.
2. **Find the agents:** `.state == "live"` and `state != null`. Plain shells
   (null) and finished terminals are never agents.
3. **Give each agent a space:**
   - its own `herdr.space`; else the space of the nearest ancestor that has
     one, walking `parentAddr` through non-agent ancestors as well, at most
     16 levels;
   - else `null`, which means the `background` row.
   - The row identity is `{kind:"app", machine, spaceId}`. The background row
     is `spaceId: "_background"`.
4. **Name the rows and tabs** from `labels.where`, split on the **last**
   `" / "`: the part before is the space name, the part after is the tab.
   - Without one, the name is `"space"` and the tab is `""`.
   - Names are display only; the identity never uses them, so renaming a space
     keeps its row.
5. **Status, as one word:**
   - with `windowOpen == true`, the app's status for that address wins when
     it isn't null;
   - otherwise `state`, except that `done` becomes `idle` when
     `attention[address]` is `{word:"done", seen:true}` (the address carries
     `machine/` for a remote one);
   - `error` stays `error`.
6. **Kill cascade, from the full terminal list** (before any cap or filter):
   for each agent, every live terminal reachable by `parentAddr` edges whose
   `die_with_parent` is true, transitively. Each entry is `{address, title}`,
   whether it is an agent or a shell.
7. **Group** with `group_by([.machine, .spaceId])`. Each group becomes a row
   shaped like a session:

   ```json
   {kind:"app", name, host: machine, spaceId, running: true, readable: true,
    stale: false, agents, blocked, done, working, hiddenAgents,
    agentList, projects: [], windowAddress: ""}
   ```

   - Each `agentList` entry is `{title, status, kind: .status.kind, pane:
     address, tab, seq: status_ms, cascade}`.
   - The title is `.title`, falling back to `argv[0]`'s basename, then
     "untitled agent".
   - #20's 500-agent cap and its counts-after-cap rule (D9) apply.
8. **Remote filter:** without `--remote`, only `machine == ""` is emitted.
9. **Output:**
   `{ok, error, sessions, windowOpen, machines: [{name, state}]}`. The
   machines list comes from `hc machine ls --json` (`bounded 2`, `--remote`
   only) and feeds A6.

**hc-only machines:**

- `require_tools` (`:233`) checks `jq` everywhere, `herdr` only for the classic
  commands, and `hc` only for `app-*`.
- `list` on a machine without `herdr` returns `{ok: true, sessions: []}`.

### A3. Actions

- **Address check:** `valid_hc_address` is
  `^([A-Za-z0-9][A-Za-z0-9._-]{0,31}/)?t[0-9a-z]{1,9}$`. That's the plugin's
  own restriction.
- **Routing:** hc routes `machine/tN` itself, so app actions never use our ssh
  or `--host`.
- **Errors:**
  - hc's stderr `{error:{kind,message}}` becomes
    `{ok:false,error:"<message>"}`.
  - Exit 124 or 137 is `timed out: <action>`.
  - herdr-app prints its own `{"error": "..."}` on stdout and exits 1, and is
    decoded separately.

| Subcommand | Command | Outer limit |
|---|---|---|
| `app-focus ADDR` | `herdr-app do agent.focus --terminal ADDR`. If the window is closed, start it (A4) and retry until 5 s, then raise it (A4). | 6 s |
| `app-prompt ADDR [--force]` (text on stdin) | `hc send --wait [--force] -- ADDR "$text"`, then `hc read --lines 60 ADDR` | 300 s |
| `app-interrupt ADDR` | `hc interrupt ADDR`, with its own watch shortened below the limit if the CLI takes one, else the limit covers its 10 s default | 12 s |
| `app-kill ADDR CASCADE_HASH` | Recompute the target's cascade. If its hash differs from the one confirmed, return `{ok:false, changed:true, cascade:[…]}`, and the panel asks again. Otherwise `hc kill ADDR`. | 8 s |
| `app-new NAME [DIR] [MACHINE]` | `herdr-app do space.new --name NAME [--folder DIR] [--machine MACHINE]`, starting the window first if needed | 8 s |

**What the panel sees for each action:**

- **Prompt.** `--` keeps text that starts with `-` positional. The text is in
  hc's argv, as with herdr (#20 D13).
  - `--force` is passed only after the Menu's existing busy or blocked
    confirmation. hc refuses a blocked program without it.
  - hc's `.wait` result maps to the prompt's existing JSON:
    - `reason: "ended"` with `.wait.status` gives `{ok:true, status, output}`;
    - `timeout` gives `{ok:true, status:"timeout"}`, plus the screen read;
    - `not_started` gives `{ok:false, error:"the agent did not start the
      turn"}`.
- **Interrupt** maps `outcome`:
  - `stopped` → ok, "interrupted";
  - `still_working` → `{ok:true, note:"still working"}`, shown in the error
    line as information.

### A4. Raising the herdr-app window

- **Find the window by PID.**
  - The PIDs come from `pgrep -x herdr-app`.
  - They are intersected with `hyprctl clients -j` client PIDs.
  - Exactly one matching client is focused, with #20's shape-checked
    `hl.dsp.focus`.
  - No match means the window is closed (start it). More than one match means
    `die "more than one herdr-app window"`. A short-lived `herdr-app` CLI
    process has no window, so it drops out at the intersection.
- **Start it.** `setsid uwsm-app -- herdr-app` (else `setsid herdr-app`) runs
  under the caller's umask (#21), with its output sent to `/dev/null`. The
  script then waits for `herdr-app ls` to answer, within the action's limit.
- **Code reuse.** The existing window validation and focus code is reused,
  with no new discovery layer.

### A5. `HerdrModel.qml` and the UI

- **Sources:** `appSessions` (local) and `appHostSessions` (remote, menu only)
  sit alongside `localSessions` and `hostSessions`. `rebuild()` concatenates
  them: classic local, app local, classic remote, app remote. Counts,
  attention and #20's D4 cursor identity treat them alike.
- **Identity:**
  - `sessionKey(s)` is `"app\u0000" + machine + "\u0000" + spaceId` for
    `kind == "app"`. For anything else it stays as today (host + name), so
    classic keys don't change.
  - `agentKey` uses the hc address.
- **Captured targets.**
  - When `a` opens, `Menu.promptTarget` captures `{kind, host, session, pane}`.
  - When `n` opens, it captures `{kind, machine}`.
  - Submission uses only what was captured, so moving the cursor can't change
    where the text goes.
- **Dispatch by `kind`:**
  - Enter or a click on an app agent → `app-focus`.
  - `a` → `app-prompt`.
  - `i` → `app-interrupt`; it does nothing on classic rows.
  - `K` on an app agent → confirm → `app-kill`.
    - The confirmation reads "End <title>?", plus "and with it: <titles>"
      when `cascade` isn't empty.
    - A `changed` reply reopens the confirmation with the new list.
  - `n` on an app row → `app-new` on that row's machine.
- **App rows have no row-level kill or delete,** so a space is never closed
  from here.
- **Labels:**
  - an app row's subtitle is "desktop app" (plus the machine for remote
    rows), or "not live" while stale;
  - the background row's name is "background";
  - `agentNote("error")` returns "error" with the urgent colour;
  - blocked agents with `.status.kind` show it: "needs you: permission".

### A6. Staleness and reachability

- **Stale data.** The app data is stale when the subscription is down, or when
  the last `app-list` failed. A successful `app-list` clears it.
  - Stale rows stay on screen, read "not live", and refuse kill and
    interrupt.
  - The tooltip says "herdr-core not reachable".
- **Per machine.** Reachability comes from A2's `machines` list.
  - A machine that is not `connected` gets its rows marked "not live", and
    actions there are refused, even while the local subscription is healthy.
  - This is separate from the classic `hostState`.
- **The error line** shows `appError` after `actionError` and `errorText`.

## Alternatives rejected

- **A full event reducer in QML:** not every event shape has been seen, hc
  changes weekly, and a missed event would leave silently wrong state. A
  trigger plus a snapshot is simpler and correct.
- **A debounce that restarts on every event:** a steady stream of events would
  postpone the refresh forever (Codex).
- **Polling `hc ls`:** its CLI summary has no labels, parents or status
  object.
- **The undocumented `herdr.seen` label:** it is replaced by the app's own
  attention record.
- **Focusing by window class:** none is declared, so the PID intersection is
  used.
- **Upstream's single row, and its kill of the whole core:** both were decided
  against.

## Risks

- **R1, attention edge case.** If an agent finishes twice with the window
  closed, the attention record may still say `{done, seen}` from the first
  time, so the second finish shows as seen. The record has no turn number.
  This is accepted, and checked live.
- **R2, remote terminals are unverified live.** The schema says yes; step 7
  checks it with `hc run --on razer`.
- **R3, moving versions.** hc and herdr-app change under the #2978 session.
  The fakes use schema-shaped objects, and step 7 runs against what is
  deployed then.
- **R4, one subscription per model:** about four idle processes on three
  monitors. #23 shares the model.
- **R5, the QML wiring is untested by the node harness.** One focused check
  runs `qs` on a test file that feeds a fake `hc events` through `Process` +
  `SplitParser`. It asserts coalescing, the watchdog and the restart.

## Verification

**Fakes in `tests/herdr-sessions.sh`.** Schema-shaped objects only: `status`
as `{state, kind}`, never a bare string.

- **`hc events`** prints `FAKE_HC_SNAPSHOT`, then keeps streaming heartbeats
  until killed. That is a real streaming fake, so it catches producer-cleanup
  bugs.
- **The `send`, `interrupt`, `kill`, `read` and `machine ls` fakes:**
  - return `FAKE_HC_*` JSON;
  - exit with the given codes and print stderr error JSON;
  - log their argv.
- **`herdr-app ls`** prints `FAKE_APP_LS`, or exits like "connection refused",
  or like another error. `herdr-app do` logs; `FAKE_VIEW_JSON` supplies the
  attention record.

**`tests/herdr-sessions.sh` cases:**

- **Agents:** only live terminals with a status are shown. A shell, a finished
  one and a killed one are absent.
- **Grouping:**
  - rows group by machine and space ID;
  - two spaces with the same name stay apart;
  - the same space ID on two machines stays apart;
  - a renamed space keeps its row;
  - a `where` containing `" / "` twice splits on the last one.
- **Parents:**
  - a sub-agent joins its parent's space, also through a non-agent parent and
    a grandparent;
  - a missing parent puts it in `background`;
  - a local `t3` never parents `razer/t4`.
- **Status:**
  - the window's status wins;
  - with the window closed, `done` plus attention `{done, seen}` shows `idle`,
    and `done` without it shows `done`;
  - `error` stays `error`;
  - `windowOpen` is true, false or null for the three `herdr-app ls`
    outcomes.
- **Kill cascade:** it includes grandchildren and shells, and excludes
  children with `die_with_parent: false`. `app-kill` with a stale hash returns
  `changed` and does not kill.
- **Snapshot reading:**
  - an oversized or malformed snapshot gives `could not read herdr-core`;
  - the streaming fake is gone after `app-list`, with no orphan.
- **Remote:** without `--remote`, `machine/` terminals are absent. With it,
  they are present, and no address appears twice.
- **Actions:**
  - prompt text starting with `-`, and text with several lines, arrives as one
    argument after `--`;
  - `--force` is passed only when the flag is given;
  - each `.wait.reason` maps correctly;
  - interrupt `still_working` maps to the note;
  - exit codes 3, 9 and 11 give hc's message;
  - a timeout gives `timed out: …`;
  - herdr-app's error JSON is decoded.
- **Window:**
  - focus with no window starts one and then focuses it;
  - two matching windows give an error;
  - a CLI-only `herdr-app` process is not taken for the window.
- **Other:** hc-only (no `herdr`): `list` is empty and `app-list` has rows.
  Demo mode makes `app-*` writes do nothing.

**`tests/session-actions.cjs` cases:**

- **Updates:** a stream of events refreshes within 250 ms plus one run. A
  heartbeat triggers nothing but resets the watchdog. A trigger during a run
  gives exactly one more run.
- **Merging:** `rebuild()` merges the four sources. App and classic rows with
  the same name and host stay apart. The cursor follows an app agent across a
  rename.
- **Captured targets:** a prompt or new-space target captured on an app row
  stays put when the cursor moves.
- **Dispatch:**
  - Enter, `a`, `i`, `K` and `n` call the right backend for each kind;
  - an app row has no destroy action;
  - the confirmation names the cascade;
  - a `changed` reply re-asks.
- **Staleness:**
  - with the subscription down or `app-list` failed, rows are "not live" and
    kill and interrupt are refused;
  - a restart doesn't clear staleness until an `app-list` succeeds;
  - a machine that isn't connected is marked as such.

**The R5 QML check:** `qs` on `tests/app-subscription.qml` with a fake
`hc events`.

**Live, after deploy (step 7, p620 plus razer).** Use throwaway labelled
terminals, killed afterwards.

- An agent shows in its space row, and its blocked and done states follow the
  window's attention as you look at it, with the window open and with it
  closed.
- focus works with the window closed;
- prompt works, including `--force` on a blocked agent;
- interrupt works;
- kill works, with the confirmation naming its sub-agents;
- an agent started with `hc run --on razer` shows in the menu only;
- the `i` key works;
- the bar's cost on a host without hc is unchanged.
