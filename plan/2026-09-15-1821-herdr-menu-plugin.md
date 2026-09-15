---
status: approved
issue: 1821
spec: spec/2026-09-15-1821-herdr-menu-plugin.md
---

# Plan: herdr menu plugin for Omarchy

## Approved decisions (from the spec)

Everything needed to implement is here. The intent and spec do not need to be
opened.

- **Repository:** `olafkfreund/nixarchy-herdr`, checked out at
  `/mnt/data/Source-home/GitHub/nixarchy-herdr`.
  - Branch `feat/1821-herdr-menu-plugin`; PR into `master`.
  - Base is `jankeesvw/omarchy-herdr` 1.1.0 (`fa545a4`). `upstream` is
    fetch-only, and its MIT copyright line is kept.
- **Plugin ID** `nixarchy.herdr`. `kinds: ["menu","bar-widget"]`, with
  `keepLoaded: true`, `entryPoints.menu: Menu.qml` and
  `entryPoints.barWidget: Panel.qml`. No `service` kind.
- **Files:**
  - `Menu.qml` (new): root `Item` with `open(payloadJson)`, `close()` and
    `opened`. Shows a `PanelWindow` on `WlrLayer.Overlay` with
    `WlrKeyboardFocus.Exclusive`. Modelled on
    `$OMARCHY_PATH/shell/plugins/menu/Menu.qml`.
  - `HerdrModel.qml` (new): session state and actions moved out of
    `Panel.qml`. Both entry points hand it to `Card.qml` as `panel`, and
    neither keeps its own copy of the logic.
  - `Panel.qml`: the bar widget, keeping its badge, polling and pin.
  - `Card.qml`: its interface (`panel`) is unchanged.
  - `bin/herdr-sessions`: gains `--host`, `new` and `prompt`.
- **Hosts** come from `~/.config/omarchy/herdr.json` as `{ "hosts": [...] }`.
  - A missing or broken file means local only.
  - Names must match `^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$`; anything else is
    dropped.
  - p620 lists `razer` and razer lists `p620`. p510 is not touched.
- **Remote transport:** one `ssh_run` function applies
  `-o BatchMode=yes -o ConnectTimeout=4 -o ControlMaster=auto -o ControlPersist=60 -o ControlPath=$XDG_RUNTIME_DIR/nixarchy-herdr-%C`
  under `timeout 8`. Nothing is installed or prepared on remote hosts, and
  there is no `herdr machine add`.
- **Remote `list`:** the script pipes itself to
  `ssh H bash -s -- list --no-windows`. Each session carries `host`: `""` for
  local, `"H"` for remote. Windows are always matched locally.
- **Window matching** is keyed on `host/session`:
  - `--remote <target>` gives the host, taking the part after any `user@`.
  - With no `--remote`, the host is local.
  - A bare `herdr` with no `--session` means session `default`.
- **Actions:**
  - `open`: focus the paired window; otherwise run
    `foot -e herdr --session S`, or `foot -e herdr --remote H --session S`
    for a remote host.
  - `focus`: run `agent focus` first (over ssh when remote), then focus the
    local window.
  - `kill` and `delete`: unchanged locally, run over ssh when remote, and
    `kill` keeps its confirmation.
- **`new S [DIR]`:**
  - Refuses a name that does not match `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`.
  - Refuses a name that already exists on that host, according to
    `herdr session list --json`.
  - Local: `foot --working-directory DIR -e herdr --session S`.
  - Remote: `foot -e herdr --remote H --session S`. When DIR is given, it
    waits for the server socket, then runs
    `herdr --session S workspace create --cwd DIR` over ssh.
- **`prompt S PANE`:**
  - The text comes in on stdin, never argv. Remote arguments go through
    `printf %q`.
  - Runs `agent prompt PANE "$text" --wait --until idle --until done --until blocked`
    under `timeout 300`, then `agent read PANE --source recent --lines 60`.
  - Prints `{"ok":true,"status":…,"output":…}`, capped at the script's
    existing byte ceiling.
  - Nothing is written to disk.
- **Busy agents:** `working`, `blocked` and `unknown` get a confirmation
  dialog, with focus starting on Cancel. `idle` and `done` send straight away.
- **Polling:**
  - Bar: local host only, at upstream's 3s / 5s / 20s.
  - Menu: every host in parallel, one `Process` per host, every 3s while the
    menu is open and not at all while it is closed.
  - Host status: `●` answered, `○` reachable with no sessions running,
    `–` unreachable or timed out.
- **Menu keys:**
  - `↑` `↓` / `j` `k` move; `Tab` / `Shift+Tab` jump between host groups.
  - `Enter` / `o` open or focus; `n` new session; `a` prompt.
  - `K` kill (confirm); `x` delete; `p` pin; `r` refresh.
  - `Esc` closes the prompt or dialog first, then the menu.
- **Keybind:** `SUPER + SHIFT + H`, added to `~/.config/hypr/bindings.lua`
  on p620 and razer:
  `o.bind("SUPER + SHIFT + H", "Herdr", "omarchy-shell shell toggle nixarchy.herdr '{}'")`.
- **Carried over:** the badge shows the blocked count when non-zero,
  otherwise the running count. This is the local edit in the installed
  `jankeesvw.herdr`.

## Environment facts (checked 2026-09-15)

- p620 and razer have herdr 0.9.0, `bash`, `jq`, `foot`, `hyprctl` and
  `ssh`. No `nixos_config` change is needed.
- `qmllint` is not on PATH. Run it as
  `nix shell nixpkgs#kdePackages.qtdeclarative -c qmllint`.
- `omarchy plugin add` takes only a git URL. The dev install is a plain git
  clone in the plugin directory; other installed plugins already carry
  `.git`.
- Found in step 0: `herdr --remote H --session S` creates and starts a
  missing session on H, so the deviation rule was not needed. Any herdr the
  script launches must run without `HERDR_*` variables (`env -u` each one).
  Otherwise, when the script runs from inside a herdr pane (as in testing),
  herdr refuses with "nested herdr is disabled".
- Found in step 2: `omarchy-shell` gives IPC calls 2s
  (`OMARCHY_SHELL_IPC_TIMEOUT`), but `rescanPlugins` takes about 15s with 20
  plugins installed. Run shell commands with `OMARCHY_SHELL_IPC_TIMEOUT=20s`.
  A timed-out call may still have been applied, so re-check with
  `omarchy plugin list --json`. A fresh `git clone` into the plugin directory
  triggers several hot reloads in a row.
- Found in step 4b: "Local plugin changed, reloading" does not rebuild a bar
  widget that is already on screen, and disabling then re-enabling the plugin
  does not either. An on-screen check after a QML or asset change silently
  runs the old component, so every on-screen verification from here on is
  preceded by `omarchy restart shell` (announced on the agent bus). The
  on-screen checks of steps 3 and 4 had run the step 2 component and are
  repeated after the restart.
- qmllint baseline for upstream `Panel.qml` + `Card.qml`: 0 errors and 721
  warnings, mostly unqualified `panel`/`root` access from nested components.
  Per type at `fa545a4`: 98 `[import]`, 1 `[inheritance-cycle]`,
  32 `[missing-property]`, 512 `[unqualified]`, 78 `[unresolved-type]`. Most
  come from `qs.*` shell modules qmllint cannot fully resolve. Counts are
  taken with
  `qmllint … 2>&1 | grep -E '^(Error|Warning)' | grep -o '\[[a-z-]*\]$' | sort | uniq -c`.
  "No errors" means:
  - 0 `Error` lines.
  - For each type, compare against the previous step. `[unqualified]` may
    grow.
  - Any other type that grows is read line by line. Growth from a new file's
    `qs.*` imports or types is accepted and named in the commit message;
    anything else is fixed.

Throughout: `R=/mnt/data/Source-home/GitHub/nixarchy-herdr`,
`P=~/.config/omarchy/plugins/nixarchy.herdr`, and
`LINT='nix shell nixpkgs#kdePackages.qtdeclarative -c qmllint -I "$OMARCHY_PATH/shell"'`.
Every step ends with one commit, `<type>(<scope>): … (#1821)`, then
`git -C $P pull` so the shell hot-reloads it.

## Steps

### 0. Probe the unverified `--remote` behaviour. No code.
- On p620, run `foot -e herdr --remote razer --session nhprobe-0915`
  against that session name, which does not exist on razer.
- Record whether razer's `herdr session list --json` now shows it running.
- Close the window, then run
  `ssh razer 'herdr session stop nhprobe-0915; herdr session delete nhprobe-0915'`.

→ **Verify** by razer's session list no longer containing `nhprobe-0915`.
**Deviation rule:** if `--remote` does not create or start the session,
remote `open` (stopped) and remote `new` switch to
`foot -e ssh -t H herdr --session S`. Window matching then also parses
`ssh … herdr --session S` command lines. Both changes go into this plan in
the step 5 commit.

### 1. `manifest.json`, `Panel.qml`, `LICENSE`, `README.md`: rebrand.
- Manifest: `id: nixarchy.herdr`, `name: Herdr`, `version: 0.1.0`,
  `author: olafkfreund`, homepage set to our repository. Kinds stay
  `["bar-widget"]` for now.
- `Panel.qml`: `moduleName` becomes `nixarchy.herdr`.
- `LICENSE`: add `Copyright (c) 2026 olafkfreund` below Jankees' line.
- `README.md`: a one-paragraph header with attribution.

→ **Verify** with `omarchy plugin validate $R` (exit 0) and
`$LINT $R/Panel.qml $R/Card.qml` (no errors). This also proves the
`nix shell` qmllint works.

### 2. Dev install on p620. No repo change.
- `git clone -b feat/1821-herdr-menu-plugin $R $P`
- `omarchy plugin disable jankeesvw.herdr`
- `omarchy-shell shell rescanPlugins`
- `omarchy plugin enable nixarchy.herdr`

→ **Verify** that `omarchy plugin list --json | jq '.[]|select(.id|test("herdr"))'`
shows `nixarchy.herdr` enabled and `jankeesvw.herdr` disabled, the bar
badge appears, and clicking an agent line still lands on it.

### 3. `Panel.qml`: carry over the blocked-count badge.

The badge text becomes
`root.blockedCount > 0 ? root.blockedCount : root.runningCount`.
→ **Verify** with `$LINT`, and by the badge reading the running-server
count while nothing is blocked.

### 4. `HerdrModel.qml` (new), `Panel.qml`: extract state and actions.
- Move every property and function that `Card.qml` reads through
  `panel.`, found with `grep -o 'panel\.[A-Za-z]*' Card.qml | sort -u`,
  plus the polling and `Process` objects, into `HerdrModel.qml`.
- `Panel.qml` creates one model and passes it to `Card` as `panel`.
  Pin state stays in `Panel.qml`.

→ **Verify:**
- `$LINT` on all QML files.
- Every name from that grep exists on the model:
  `grep -c "function <name>\|property .* <name>" HerdrModel.qml` is at
  least 1 for each.
- By hand, nothing changes: open, focus agent, kill (Cancel), pin, `r`.

### 4b. `assets/`, `Panel.qml`, `HerdrModel.qml`, `README.md`: herdr logo.
Added on request 2026-09-15, to promote herdr.
- `assets/herdr-logo.svg`: herdr's `assets/logo.svg`, unchanged
  (herdrdev/herdr, Apache-2.0).
- `assets/herdr-mark.svg`: the same file with its background `<rect>`
  removed and the mark's fill changed from `#303438` to `#ffffff`.
  MultiEffect colorization keeps the source's luminance, so a dark mark
  tints to near-black and cannot be seen on a dark bar; a white one takes
  exactly `barForeground`. Its `viewBox` is cropped to `60 60 340 340`, the
  head and horn, because the full logo's body runs off the edge and reads as a
  blob at bar size.
- `Panel.qml`: the bar's server glyph becomes an `Image` of the mark
  plus `MultiEffect { colorization: 1.0; colorizationColor: root.barForeground }`,
  the pattern Omarchy's own `plugins/bar/widgets/Tray.qml` uses for
  symbolic icons. The badge keeps anchoring to `serverIcon` but moves to the
  bottom-right corner (on request), where it no longer covers the head and horn.
- `HerdrModel.qml`: `iconServer` removed (no longer used).
- `README.md`: the logo at the top, credited to herdrdev/herdr under
  Apache-2.0. Apache-2.0 §6 grants no trademark rights; the logo is
  used only to identify herdr.

→ **Verify:**
- `omarchy plugin validate` exits 0, and qmllint shows no new warning
  type.
- The shell log has no errors from `nixarchy.herdr`.
- A bar screenshot shows the sheep mark in the bar foreground colour,
  with the badge on its corner.

### 5. `bin/herdr-sessions`: hosts.

- Add `ssh_run`, a leading `--host H` (validated), a `--no-windows` switch
  for `list`, and `"host"` on every session.
- Change window matching to key on `host/session`.
- Make `open`, `focus`, `kill` and `delete` route over ssh when `--host`
  is given. Remote `kill` and `delete` run the script's own action on the
  host (script on stdin), because the socket-to-pid lookup reads that
  machine's `ss` and `/proc`.

Errors keep upstream's contract: `die` prints `{"ok":false,"error":…}` and
exits 0, because the panel parses JSON rather than exit codes. The checks
below test `ok`, not the exit status (changed from "exits non-zero" in the
step 5 commit).

→ **Verify:**

- `bin/herdr-sessions list | jq -e '.sessions|all(has("host"))'` passes.
- `bin/herdr-sessions --host razer list | jq -e '.sessions|all(.host=="razer")'`
  passes in under 8s.
- `--host` with `bad;name`, `-oProxyCommand=x`, an empty name or `a b`
  returns `ok:false` "not a host name", and a fake `ssh` placed first on
  `PATH` leaves no marker file. The same fake is reached by `--host razer`,
  which proves the harness.
- `bin/herdr-sessions --host nosuchhost list` returns `ok:false` within the
  8s `timeout`.
- On p620, a window running `herdr --remote razer --session Razer` pairs
  with razer's `Razer` and not with a local session. Checked with a fake
  `herdr` that only sleeps.

Found in step 5: resolving an unknown host name hangs for over 10s
(`getent hosts nosuchhost`), and `ConnectTimeout` does not cover DNS, so an
unreachable host costs the full 8s. Step 9 must not start a new poll for a
host while that host's previous one is still running.

### 6. `bin/herdr-sessions`: `new`.

- `new S [DIR]` refuses a bad name, `default`, a relative or (locally)
  missing DIR, and a name that already exists on that host.
- `show_session` takes the terminal's directory as an optional argument,
  so `new` reuses its launch code.
- Remote: after the `--remote` window starts, it waits (up to 10s) for the
  server to report running, then creates a `/DIR` workspace over ssh.

Found in step 6: `herdr --remote H --session S` leaves a local directory
`~/.config/herdr/sessions/S` holding only `herdr-client.log` (no
`session.json`, no server). Every remote attach does this, and the step 0
probe did too. Left alone, it shows as a phantom stopped session and blocks
`new S` locally. So `list` now hides stopped sessions that have no
`session.json`, and `new` checks existence through the script's own `list`
(locally, and on the remote host). Stopped sessions with a `session.json`
still show, as upstream intends.

→ **Verify:**

- `new -x`, `new 'a b'`, `new Devlopment-Local`, `new default`, a relative
  DIR and a missing DIR each return `ok:false`, with the session list and
  window count unchanged.
- `new nhtest-local /tmp` opens one window, the session runs, pane `w1:p1`
  has cwd `/tmp`, and the window pairs with the session. A second
  `new nhtest-local` is refused without a new window.
- `--host razer new nhtest-razer /tmp` opens one window paired with
  `host: "razer"`, razer lists it running, and its workspace `w2` has cwd
  `/tmp`.
- A hand-made `sessions/nhtest-ghost` holding only `herdr-client.log` is
  hidden from `list`, and `new nhtest-ghost /tmp` succeeds.
- Clean up with `kill` then `delete`, locally and over `--host razer`.

### 7. `bin/herdr-sessions`: `prompt`.

- `prompt S PANE` reads the text from stdin (16 KB cap, refuses whitespace
  only), runs `agent prompt PANE "$text" --wait --until idle --until done
  --until blocked` under `timeout 300`, then `agent read PANE --source
  recent --lines 60`, and prints `{"ok":true,"status":…,"output":…}`.
- Remotely the text stays on ssh's stdin: the remote command is a fixed
  `bash -c 't=$(cat); "$@" "$t" …' _ herdr … agent prompt PANE`, every word
  quoted with `printf %q`, so the text is never part of a remote command
  line whatever shell the host logs into.
- `ssh_run` takes an optional timeout (default 8s; the prompt call uses 305).

Found in step 7:

- `herdr agent read` prints the pane's screen as plain text, not JSON, so
  the script JSON-encodes it.
- A prompt's answer carries the state in `.result.agent.agent_status`;
  `--wait` really waits (state_change_seq went idle → working → idle).
- Starting an agent can land in `blocked`, which is a dialog on screen and
  not a fault: Claude asks to trust an unfamiliar directory, and on razer it
  also asks whether to use the `ANTHROPIC_API_KEY` in the environment. Start
  test agents in a directory that is already trusted, and answer the API-key
  question with its highlighted default, "No (recommended)".
- An agent can exit on its own between tests, leaving the pane at a shell
  prompt; `agent_not_found` then means "no agent there", not a broken call.

→ **Verify:**

- Setup: `new nhtest-prompt ~/.config/nixos`, then
  `agent start nhpong --kind claude --pane w1:p1 -- --model haiku`, waited
  to `idle`.
- `printf 'Reply with only the word pong-two.' | bin/herdr-sessions prompt
  nhtest-prompt w1:p1` returns `ok:true`, `status:"idle"` in ~4s, and the
  output contains `pong-two`.
- The same against a razer agent through `--host razer` returns `ok:true`,
  `status:"done"` in ~5s, with `pong-razer` in the output.
- Whitespace-only text returns "nothing to send"; a malformed pane id
  returns "not a pane id".
- Two injection payloads (`"; touch /tmp/nh-injected; echo "` and
  `$(touch /tmp/nh-injected)`) aimed at a pane that does not exist create no
  marker on p620 or razer. Aimed at a missing pane on purpose, so no agent
  can act on the text and only broken quoting could create it.
- `grep -rln` over `~/.cache`, `~/.local/state` and `~/.config/omarchy`
  finds no prompt or reply text.
- Clean up both sessions with `kill` then `delete`, including the local
  leftover directory the remote attach left behind.

### 8. `Menu.qml` (new), `manifest.json`, `~/.config/hypr/bindings.lua`: the menu.

- Manifest: `kinds: ["menu","bar-widget"]`, `keepLoaded: true`,
  `entryPoints.menu: Menu.qml`, version 0.2.0.
- `Menu.qml`: root `Item` with `open(payloadJson)`, `close()`, `toggle()`
  and `opened`, drawing a `PanelWindow` on `WlrLayer.Overlay` with
  `WlrKeyboardFocus.Exclusive`, a scrim, click-away close, and a centred
  `BorderSurface` holding `Card` over its own `HerdrModel`. Local host only
  in this step.
- `Card.qml`: kill moves to the shifted `K` and delete to the
  `deleteRequested` signal; a surface may declare `pinnable: false`, which
  hides the pin button and the `p` key. `HerdrModel` forwards `pinnable`.
- Keybind appended to `~/.config/hypr/bindings.lua`, then `hyprctl reload`.

Found in step 8: `qs.Ui/PanelKeyCatcher` maps `k` to vim-up and turns `x`
into its own `deleteRequested` signal before a component's `textKey` handler
runs, so upstream's `k` (kill) and `x` (delete) never fired in the bar panel
either. That is why `k` did nothing during the step 4 check. The `K` and
`deleteRequested` handling repairs both surfaces.

Also: `Card.qml`'s binding-loop warning (a `Text` with
`height: visible ? implicitHeight : 0`) is upstream's, at its line 352; our
edits only shift the line number.

→ **Verify:**

- `omarchy plugin validate` exits 0; qmllint 0 errors, growth only in the
  usual unresolved `qs.*`/QtQuick types.
- `SUPER + SHIFT + H` opens the menu centred over a scrim, listing sessions
  and agents, with the cursor on the most urgent agent and no pin button.
- `Esc` closes it; pressing the chord twice toggles it.
- `K` opens the kill dialog with Cancel focused; `Esc` cancels, the servers
  keep running and the menu stays open.
- `Enter` focuses the agent under the cursor: `hyprctl clients` count
  unchanged, the agent reports `focused`, and the menu closes.
- The bar badge still draws and counts alongside the menu.

Added on request 2026-09-15 (menu text too small): `Card.qml` multiplies every
`font.pixelSize` and action-icon `fontSize` by `panel.textScale`, which
`HerdrModel` forwards from the surface. The bar leaves it at 1.0; the menu
asks for 1.3 and widens its card to `Style.space(460)`.

Also found: a plugin's own `PanelWindow` has no per-monitor instance, so the
menu opened on whichever output Quickshell picked rather than the one being
used. `Menu.qml` resolves `Hyprland.focusedMonitor` on open and sets
`screen`, the rule Omarchy's own bar states for a keyboard-summoned surface.

Note for on-screen testing: send one key per `input` call. Two chords in one
batch raced the menu's focus and the second key was lost.

### 9. `Menu.qml`, `HerdrModel.qml`, `Card.qml`: hosts in the menu.

- `HerdrModel` reads `~/.config/omarchy/herdr.json` through a watched
  `FileView` (shape-checked, missing or broken means none), and an
  `Instantiator` makes one `Process` per host.
- A host whose previous poll is still running is skipped, not queued (an
  unreachable host takes the full 8s).
- Local and remote sessions are merged, local first, then hosts in config
  order, with counts taken over the whole list.
- Only a surface with `remote: true` (the menu) polls hosts, and its timer
  runs only while it is open. The bar stays local and always on.
- `n` asks the surface for a new session. The menu shows one input line
  (`name` or `name /absolute/dir`) and creates the session on the host the
  cursor is on.

Deviations from the approved design, made in the step 9 commit:

- **No separate host header rows, and `Tab` does not jump between hosts.**
  A header row would have to live inside the session delegate the bar panel
  shares, and `Tab` already cycles a row's buttons there (upstream
  behaviour). Instead each remote row is labelled `host · name`, and the
  title line carries each host's state: `●` answered with something
  running, `○` answered with nothing running, `–` no answer. `j`/`k` walk
  every row across hosts.
- **One input line instead of a two-field form** for `n`. The script
  already validates both words.

Found in step 9: the session restart left the local repository with five
empty object files (the step 9 commit, its tree and three blobs) and `HEAD`
unreadable. The plugin clone had pulled the commit before the crash, so the
objects were fetched back from it, the empty files kept aside, and `git fsck`
passed. Also fixed here: the menu's model had polled razer every 20s while
closed, because the timer ran unconditionally.
And the new-session line first drew over the title: `Card.qml` sets
`anchors.fill: parent` on itself, which a `Column` cannot override. `Menu.qml`
now clears that fill, anchors the card above the input, and grows the outer
card by the input's height while it is open.
And the title kept `–` after razer answered: `applyHostPayload` mutated
the existing `hostState` object and assigned it back, which QML does not
see as a change. It now builds new objects.

→ **Verify:**

- With `{"hosts":["razer"]}`, razer's sessions appear as `razer · …` rows and
  the title shows razer's state.
- With `{"hosts":["razer","nosuchhost"]}`, the menu opens at once,
  `nosuchhost` shows `–`, and razer still renders.
- With the file removed, the menu shows local sessions only and no host
  state.
- After closing the menu, no `herdr-sessions --host` process remains within
  10s, and the shared ssh connection (`ssh: …nixarchy-herdr-… [mux]`) exits
  within about 70s (`ControlPersist=60`).
- `n` on a razer row, typing `nhtest-menu /tmp`, creates the session on razer
  (clean up after).

### 10. `Menu.qml`, `HerdrModel.qml`, `Card.qml`: prompt line.

- `a` on an agent opens the menu's input line in prompt mode, targeted at
  that agent. The target is captured on the key press, so a refresh or a
  moving mouse cannot redirect it.
- `Enter` sends through `herdr-sessions prompt`. The text is written to the
  process's stdin in `onStarted`, then stdin is closed
  (`stdinEnabled = false`, re-enabled before each start).
- `Esc`, or closing the menu, abandons a running prompt.
- An agent that is `working`, `blocked` or `unknown` as of the latest poll
  gets `ConfirmDialog` first, opening on Cancel as the kill dialog does. The
  new-session line shares the same input row.

Deviation, made in the step 10 commit: the reply appears **below** the
input line instead of replacing it. A hidden `TextInput` cannot hold keyboard
focus, and a line that stays open lets a follow-up be sent at once.

Reply trimming, from what agents actually print:

- Drop everything from the last bare prompt marker (`❯`) down. That is the
  agent's own footer: status line, hints, warnings.
- Keep only what follows the echoed `❯ <sent text>` line, so earlier
  conversation does not show.
- Rejoin the terminal's wrapped lines into paragraphs, breaking only at
  lines that start with a marker (`●`, `✻`, `⎿`, `•`, `-`, `*`, a number).
- Show the last six paragraphs.

Changed on request during step 10: the menu card is `Style.space(760)` wide
(capped at 60% of the screen) with `textScale: 1.6`, and the card title
(`PanelSectionHeader.fontSize`) now scales too, which the step 8 change had
missed.

Found in step 10: `Esc` killed only the top-level script. The `herdr agent
prompt` it was waiting on sat inside a `$(...)` subshell, and survived with its
`timeout` for up to 300s. `cmd_prompt` now runs `timeout … agent prompt` as a
direct background child and traps `TERM`/`INT`/`HUP` to signal it (`timeout`
passes the signal on to herdr). Status then comes from `agent get`. The remote
command also runs under `timeout 300` on the host, so a dropped connection
cannot strand it there. Verified locally, both by `kill -TERM` and through the
menu's `Esc` (script, `timeout` and herdr all gone within 3s). The remote
abandon path is bounded by that remote timeout but was not exercised against
a live razer agent.

Correction to the record: during testing I twice reported the menu closing
on its own when a prompt finished. It had not. My screenshot crops missed
it, and a direct test (open the menu, prompt the agent from the command line,
watch the layer for 6s) kept it open throughout.

→ **Verify:**

- A prompt to an idle agent shows its answer below the line, and only the
  answer (checked: `● menu-pong`, and a two-sentence answer as one
  paragraph).
- A prompt to a `working` agent opens the dialog with Cancel selected.
  Cancel sends nothing, and no `herdr-sessions` process starts.
- Abandoning a long prompt with `Esc` leaves no `herdr-sessions` and no
  `agent prompt` process within a few seconds.

### 11. `README.md`: rewrite.
- Cover install (git clone plus enable), the `herdr.json` hosts file, the
  keybind, the menu keys, remote requirements (`bash`, `jq` and `herdr`
  on the host, BatchMode ssh), privacy (nothing written to disk) and
  attribution.
- Run the full spec verification list: steps 1–10 re-checked, plus
  `grep -rn "nh-\|pong" ~/.cache ~/.local/state ~/.config/omarchy 2>/dev/null`
  returns nothing from the plugin.

→ **Verify** every item passes, with results recorded in the PR
description.

### 12. PR.
- `gh pr create --repo olafkfreund/nixarchy-herdr --base master`
- The body links `intent/`, `spec/`, `plan/` and
  `olafkfreund/nixos_config#1821`, and lists the verification results.

→ **Verify** the PR exists and its diff contains only the files named in
steps 1–11.

### 13. razer install. After merge; no repo change.
- `git clone https://github.com/olafkfreund/nixarchy-herdr $P`
- Write `{"hosts":["p620"]}` to `herdr.json`.
- Disable `jankeesvw.herdr` if it is present, then enable
  `nixarchy.herdr`.
- Add the keybind line and run `hyprctl reload`.
- Afterwards, comment on #1821 with the result.

→ **Verify** that `SUPER+SHIFT+H` on razer lists razer and p620 sessions
and focuses a p620 agent through a `--remote p620` window.

## Tests

| Command | Expected |
| --- | --- |
| `omarchy plugin validate $R` | exit 0 |
| `$LINT $R/*.qml` | no errors |
| `bin/herdr-sessions list \| jq -e '.sessions\|all(has("host"))'` | `true` |
| `bin/herdr-sessions --host razer list \| jq -e '.sessions\|all(.host=="razer")'` | `true`, under 8s |
| `bin/herdr-sessions --host nosuchhost list` | `ok:false`, within 8s |
| `bin/herdr-sessions --host 'bad;name' list` | `ok:false`, fake `ssh` never called |
| `bin/herdr-sessions new -x` / `new 'a b'` / `new <existing>` | `ok:false`, session list unchanged |
| stopped session dir with only `herdr-client.log` | hidden from `list`; `new` on that name succeeds |
| injection prompt `'"; touch /tmp/nh-injected; "'` (local and razer) | no `/tmp/nh-injected` on either host |
| `hyprctl clients -j \| jq length` before and after focusing an attached agent | equal |
| menu closed for 10s: `pgrep -af 'ssh.*nixarchy-herdr' \| grep -v ControlMaster` | empty |

## Rollback

- **p620 or razer:**
  - `omarchy plugin disable nixarchy.herdr`, then
    `rm -rf ~/.config/omarchy/plugins/nixarchy.herdr`.
  - `omarchy plugin enable jankeesvw.herdr`.
  - Remove the `SUPER + SHIFT + H` line from `~/.config/hypr/bindings.lua`,
    run `hyprctl reload`, and delete `~/.config/omarchy/herdr.json`.
  - If the shell is wedged by a QML error, run `omarchy restart shell` first.
- **Remote hosts:** nothing was installed. Test sessions (`nhprobe-*`,
  `nhtest-*`) are removed with `herdr session stop` and
  `herdr session delete`. The ssh control sockets live in `$XDG_RUNTIME_DIR`
  and disappear at logout.
- **Repository:** close the PR. `master` still equals upstream 1.1.0.
