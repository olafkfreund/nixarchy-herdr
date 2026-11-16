---
status: draft
issue: 22
intent: intent/2026-11-16-22-herdr-core-app.md
---

# Spec: show herdr-core and herdr-app agents, one row per space

This implements the approved intent. The facts below were checked read-only on
p620, with hc 0.1.21 and herdr-app 0.1.16:

- **`hc events --json`** first prints a full snapshot:
  `{"seq", "terminals": [Terminal…]}`.
  - Each `Terminal` has `address`, `state`, `status`, `turn`, `title`,
    `labels`, `parent`, `die_with_parent`, `cwd`, `status_ms` and more.
  - Finished terminals are included.
  - Afterwards it sends events, a `heartbeat` every 15 s, and `missed` plus a
    fresh snapshot to a subscriber that fell behind.
- **The `hc ls --json` CLI** prints only a summary: `address`, `agent`,
  `state`, `turn`, `where`. There are no labels or parent, so it can't build
  rows on its own.
- **The hc schema** says both the listing and the events include connected
  machines' terminals as `machine/tN`. No remote terminal was running when
  checked.
- **`herdr-app ls`** gives spaces with names, tabs with names, and per terminal
  its pane and a `status`. With no window, it fails ("connection refused").
- **Labels:** `where` is `"<space> / <tab>"`. `herdr.space` and `herdr.tab` are
  ids local to the terminal's machine. `herdr.seen` is `"0"` or `"1"` and is
  not documented.
- **Window class:** `herdr-app.desktop` declares no `StartupWMClass`, and the
  window wasn't open to read one. Upstream matched class `herdr-app`.

## Design

### A1. One subscription per model, used only as a "something changed" signal

`HerdrModel.qml` gains `appSubProc`, a `Process` running `hc events --json`.
Its stdout is read with a `SplitParser`, one line at a time; `StdioCollector`
would wait for the stream to end.

- **Each line is a trigger, never applied as data.**
  - `heartbeat` lines are ignored.
  - Any other line, the first snapshot included, (re)starts a 250 ms debounce
    timer.
  - The timer runs `bin/herdr-sessions app-list` (A2), which takes a fresh
    snapshot and builds the rows.
  - So the plugin never interprets event payloads. A `missed` just triggers
    another refresh.
  - A trigger that arrives while `app-list` is running sets `appDirty`, so one
    more run follows.
- **Latency:** 250 ms of debounce, plus one `app-list` run (under 1 s on a
  healthy core), stays within the intent's 2 s.
- **When there's no hc:**
  - If `hc` cannot start (D3's `startFailed` path, from #20), `hcAvailable`
    becomes false. Nothing is retried until the next plugin reload.
  - The bar's cost is unchanged, and there are no app rows.
- **When the subscription drops:**
  - If it exits after starting, it is restarted with backoff (2, 4, 8 … up to
    60 s).
  - While it's down, the app rows stay but are marked stale (A6).
- **Scope:** every `HerdrModel` instance has its own subscription. An idle one
  costs a heartbeat line every 15 s. Sharing one across the bar and the menu
  is #23's "one shared data model" work.
- **#20's deadline rule:** the subscription is long-lived on purpose, and
  "watched and restarted" replaces the deadline (intent constraint). Every
  other hc call is bounded.

### A2. `bin/herdr-sessions app-list [--remote]` builds session-shaped rows

- **Snapshot.**
  - `IFS= read -r line < <(bounded 3 hc events --json 2>/dev/null)` takes the
    first line only. The `bounded` limit ends hc if it outlives the read.
    Reading directly, rather than through `head`, avoids the broken-pipe panic
    Codex saw.
  - The line is capped at `TOTAL_BYTE_CAP`.
  - An empty, failed or oversized line gives `die "could not read herdr-core"`.
- **Window status.** `bounded 2 herdr-app ls` is read if it succeeds; a failure
  just means the window is closed.
- **One jq merge,** following #20's pattern, with inputs on stdin or
  `--slurpfile`, never as arguments:
  - **Agents:** a terminal is an agent when `state == "live"` and `status` is
    not null. Plain shells and finished terminals are never shown or counted.
  - **Machine:** taken from the address. `machine/tN` belongs to `machine`, and
    a bare `tN` to this machine (`""`). Without `--remote`, only this
    machine's terminals are kept, so the bar stays local as classic remotes do.
  - **Row key:** `(machine, labels["herdr.space"])`.
    - The row name is the part of `labels.where` before `" / "`, and the tab
      is the part after it.
    - A sub-agent (`parent` set) joins its parent's space when it has no space
      label itself.
    - A status-reporting terminal with no space, directly or through its
      parent, goes into a `background` row for its machine.
  - **Status:**
    - With the window open and the terminal listed in `herdr-app ls` with a
      non-null status, the app's status wins. That is the app's own per-screen
      "seen" (as upstream did).
    - Otherwise hc's status is used, but `done` with
      `labels["herdr.seen"] == "1"` becomes `idle`.
    - This `herdr.seen` reading is inferred. Step 7's live check confirms it,
      and if it's wrong, done falls back to "done until the window shows it"
      (R1).
    - `error` passes through as itself.
  - **Each row** is shaped like a classic session:
    `{kind:"app", name, host: machine, spaceId, running: true, readable: true,
    agents, blocked, done, working, hiddenAgents, agentList, projects: [],
    windowAddress: ""}`.
  - **Each `agentList` entry** is
    `{title, status, pane: <address>, workspace: "", tab, seq: status_ms,
    children: [addresses whose parent is this one]}`.
    - The title is `title`, falling back to the agent name in `argv[0]`'s
      basename, then "untitled agent".
    - The 500-agent cap and the counts-after-cap rule from #20 D9 apply.
  - **Output:** `{ok: true, error: "", sessions: [...], windowOpen: bool}`,
    sorted by machine, then name.
- **hc-only machines:** `require_tools` (`:233`) checks `jq` for every command.
  It checks `herdr` only for the classic commands, and `hc` only for `app-*`.
  A missing `herdr` makes `list` return `{ok: true, sessions: []}`, so that
  machine shows only app rows.

### A3. Actions go through the script, bounded and validated

- **Addresses are validated** with `valid_hc_address`:
  `^([A-Za-z0-9][A-Za-z0-9._-]{0,31}/)?t[0-9a-z]{1,9}$`.
  - hc routes `machine/tN` itself, so app actions never use our ssh.
  - Remote app agents work the same as local ones, with no `--host`.

| Subcommand | Does | Limit |
|---|---|---|
| `app-focus ADDR` | `herdr-app do agent.focus --terminal ADDR`. If the window isn't running, start it (as A4) and retry until 5 s are up. Then raise the window (A4). | 6 s |
| `app-prompt ADDR` (text on stdin) | `hc send --wait ADDR "$text"`, then `hc read --lines 60 ADDR`. The result has the same shape as `prompt`. The text is in hc's argv, as with herdr (#20 D13). | 300 s |
| `app-interrupt ADDR` | `hc interrupt ADDR` | 4 s |
| `app-kill ADDR` | `hc kill ADDR`. Its `die_with_parent` children end with it; the confirmation has already named them. | 8 s |
| `app-new NAME [DIR] [MACHINE]` | `herdr-app do space.new --name NAME [--folder DIR] [--machine MACHINE]`, starting the window first if needed. | 8 s |

- **Timeouts and failures** are reported as in #20: `timed out: <action>`, or
  hc's own `error.message` from its stderr JSON.
- **Demo mode** makes every `app-*` write a no-op. `app-list` in demo mode
  returns one fixed demo app row.

### A4. Raising the herdr-app window by process, not by class

- **Find the window:**
  - `pgrep -x herdr-app` gives the app's PID.
  - `hyprctl clients -j` gives the client with that PID; its address is then
    focused with #20's shape-checked `hl.dsp.focus`.
  - This works whatever the window class turns out to be.
- **Start the window when it's missing:** `setsid uwsm-app -- herdr-app`
  (else `setsid herdr-app`), under the caller's umask (#21 U1). Then wait for
  `herdr-app ls` to answer, within the action's limit.

### A5. `HerdrModel.qml` and the UI

- **Data:**
  - `appSessions` (local) and `appHostSessions` (remote, menu only) sit
    alongside `localSessions` and `hostSessions`.
  - `rebuild()` concatenates them in this order: classic local, app local,
    classic remote, app remote.
  - Counts, attention and cursor identity (#20 D4) treat app rows the same as
    the others.
- **Keys:**
  - `sessionKey` gains a `kind` prefix, so a space and a classic session with
    the same name and host never collide.
  - `agentKey` uses the hc address.
- **Actions are dispatched by `kind`:**
  - Enter or a click on an app agent → `app-focus`.
  - `a` → `app-prompt`, through Menu's existing prompt flow (#20 D13).
  - The new key `i` → `app-interrupt`.
  - `K` on an app agent → confirm → `app-kill`. The confirmation reads "End
    <title>?", plus "and its sub-agents: <titles>" when `children` is
    non-empty.
  - `n` with the cursor on an app row → `app-new`, on that row's machine.
- **App rows have no row-level kill or delete.** The destroy column is empty
  there, so a space is never closed from here.
- **`i` is safe from Omarchy's shared key handler,** which takes `k` and `x`
  before the panel sees them. The live check confirms that.
- **Labels:**
  - an app row's subtitle is "desktop app" (and the machine for remote rows);
  - a `background` row's name is "background";
  - `agentNote("error")` returns "error" with the urgent colour.

### A6. Staleness and failures

- **The subscription is down:**
  - app rows keep their last state, the row subtitle says "not live";
  - kill and interrupt are refused, as #20 D11 does for unchecked hosts;
  - the tooltip says "herdr-core not reachable".
- **A failed `app-list`** sets `appError`, which shows in Card's error line,
  after `actionError` and `errorText`.
- **The window is closed:** rows show as normal, and "done" uses the
  `herdr.seen` fallback.

## Alternatives rejected

- **A full event reducer in QML:** that would apply each event's facts to an
  in-memory model. We haven't seen every event shape, the schema can still
  change (hc moves weekly), and a missed event would mean silently wrong
  state. Treating each event only as a trigger costs one snapshot per burst,
  which is cheap.
- **Polling `hc ls` every few seconds:** the CLI summary has no labels, so it
  can't build rows, and it costs work when nothing changes.
- **Upstream's single "Desktop app" row:** you chose one row per space
  (2026-11-16).
- **Focusing the window by class `herdr-app`:** that's unconfirmed, and the
  desktop file declares no class. The PID is exact.
- **`terminal.kill` through herdr-app:** it needs the window. `hc kill` works
  with the window closed, and the sub-agent cascade is the same.

## Risks

- **R1, the `herdr.seen` meaning is inferred.** If `"1"` doesn't mean "seen
  since it finished", a finished app agent could stay green with the window
  closed, or clear too early.
  - Step 7 runs a short throwaway agent to check it.
  - Fallback: with the window closed, show `done` as reported, and let the
    app's status clear it once the window is open.
- **R2, remote terminals are unverified live.** The schema says they appear.
  Step 7 checks with razer, using a throwaway `hc run --on razer`.
- **R3, versions keep moving.** The #2978 session is updating hc and herdr-app
  on p620. The tests use fakes, and step 7 runs against whatever is deployed
  then.
- **R4, one subscription per model.** With three monitors, that's four idle
  `hc events` processes. They're cheap, but #23 shares the model.
- **R5, key `i`.** If the shared key handler takes `i`, interrupt moves to
  `I` (Shift+i). That's checked live.

## Verification

**`tests/herdr-sessions.sh`** gains fakes for `hc` and `herdr-app`:

- `hc events` prints `FAKE_HC_SNAPSHOT`.
- `send`, `interrupt`, `kill` and `read` log what they were called with.
- `herdr-app ls` prints `FAKE_APP_LS` or fails; `herdr-app do` logs.

The new cases:

- `app-list` keeps only live, status-reporting terminals. A shell, a finished
  agent and a killed agent are absent.
- Rows are grouped by space, with names from `where`. A sub-agent with no space
  joins its parent's row. An unlabelled agent goes in `background`.
- Without `--remote`, `machine/tN` terminals are absent. With it, they're in a
  row for that machine, and no address appears twice.
- With the window open, the app status overrides hc's. With it closed, `done`
  plus `herdr.seen="1"` gives `idle`, and `error` stays `error`.
- A missing or failing `hc` gives `could not read herdr-core`. A host with no
  `herdr` and a working `hc` gets `list` → empty and `app-list` → rows.
- Each action:
  - validates the address;
  - logs the exact hc or herdr-app argv;
  - maps a timeout to `timed out: …`;
  - passes hc's error message through.
- `app-focus` with the window closed starts it, through the fake launcher, and
  then focuses it.
- Demo mode: `app-*` writes are no-ops.

**`tests/session-actions.cjs`:**

- A trigger line debounces into one `app-list` run. A heartbeat triggers
  nothing. A trigger during a run sets `appDirty`.
- `rebuild()` merges the four sources. App agents count towards the badge and
  attention. A space and a classic session with the same name don't collide.
- Kind dispatch:
  - Enter on an app agent → `app-focus`, and `K` → confirm → `app-kill`;
  - the confirmation names the children;
  - an app row has no destroy action;
  - `n` on an app row → `app-new`.
- A subscription that fails to start sets `hcAvailable = false`, with no
  retry. One that drops after starting retries with backoff, and the rows
  read "not live".

**Live checks after deploy** (step 7, p620 plus razer). All throwaway terminals
are labelled and killed afterwards.

- An app agent shows under its space row, then:
  - blocked turns the badge red;
  - focus lands in the window, with the window open and with it closed;
  - prompt, interrupt, and kill with the confirmation naming sub-agents.
- R1 (done and seen): run a short throwaway agent until it finishes, look at
  it, and watch the label with the window closed and open.
- R2: an agent started with `hc run --on razer` appears in the menu only.
- The `i` key (R5).
- The bar's cost on a host without hc: its poll timing is unchanged.
