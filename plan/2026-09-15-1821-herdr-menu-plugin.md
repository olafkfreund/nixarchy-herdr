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

0. **Probe the unverified `--remote` behaviour.** No code.
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

1. **`manifest.json`, `Panel.qml`, `LICENSE`, `README.md`: rebrand.**
   - Manifest: `id: nixarchy.herdr`, `name: Herdr`, `version: 0.1.0`,
     `author: olafkfreund`, homepage set to our repository. Kinds stay
     `["bar-widget"]` for now.
   - `Panel.qml`: `moduleName` becomes `nixarchy.herdr`.
   - `LICENSE`: add `Copyright (c) 2026 olafkfreund` below Jankees' line.
   - `README.md`: a one-paragraph header with attribution.

   → **Verify** with `omarchy plugin validate $R` (exit 0) and
   `$LINT $R/Panel.qml $R/Card.qml` (no errors). This also proves the
   `nix shell` qmllint works.

2. **Dev install on p620.** No repo change.
   - `git clone -b feat/1821-herdr-menu-plugin $R $P`
   - `omarchy plugin disable jankeesvw.herdr`
   - `omarchy-shell shell rescanPlugins`
   - `omarchy plugin enable nixarchy.herdr`

   → **Verify** that `omarchy plugin list --json | jq '.[]|select(.id|test("herdr"))'`
   shows `nixarchy.herdr` enabled and `jankeesvw.herdr` disabled, the bar
   badge appears, and clicking an agent line still lands on it.

3. **`Panel.qml`: carry over the blocked-count badge.** The badge text becomes
   `root.blockedCount > 0 ? root.blockedCount : root.runningCount`.
   → **Verify** with `$LINT`, and by the badge reading the running-server
   count while nothing is blocked.

4. **`HerdrModel.qml` (new), `Panel.qml`: extract state and actions.**
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

4b. **`assets/`, `Panel.qml`, `HerdrModel.qml`, `README.md`: herdr logo.**
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
      symbolic icons. The badge keeps anchoring to `serverIcon`.
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

5. **`bin/herdr-sessions`: hosts.**

- Add `ssh_run`, a leading `--host H` (validated), a `--no-windows` switch
     for `list`, and `"host"` on every session.
- Change window matching to key on `host/session`.
- Make `open`, `focus`, `kill` and `delete` route over ssh when `--host`
     is given.

   → **Verify:**

- `bin/herdr-sessions list | jq -e '.sessions|all(has("host"))'` passes.
- `time bin/herdr-sessions --host razer list | jq -e '.sessions|all(.host=="razer")'`
     passes in under 8s.
- `bin/herdr-sessions --host 'bad;name' list` exits non-zero without
     and prints its "invalid host" error before any ssh is started.
- `bin/herdr-sessions --host nosuchhost list` exits non-zero within 8s.
- On p620, a window running `herdr --remote razer --session Razer` is not
     paired to a local session named `Razer`.

1. **`bin/herdr-sessions`: `new`.**
   → **Verify:**
   - `new -x`, `new 'a b'` and `new Devlopment-Local` each exit non-zero, and
     `herdr session list --json` is unchanged.
   - `new nhtest-local /tmp` opens one foot window, and the session shows
     `running` with its cwd under `/tmp`.
   - `--host razer new nhtest-razer /tmp` opens one remote window, and razer
     lists `nhtest-razer` running.
   - Clean up both with `kill` then `delete`.

2. **`bin/herdr-sessions`: `prompt`.**
   - Set up: in a throwaway local session `nhtest-prompt`, start `claude` in
     one pane and wait for it to reach `idle`.

   → **Verify:**
   - `echo 'reply with only the word pong' | bin/herdr-sessions prompt nhtest-prompt <pane>`
     prints `{"ok":true,...}` whose `output` contains `pong`.
   - A prompt of `'"; touch /tmp/nh-injected; "'` creates no
     `/tmp/nh-injected`, both locally and with `--host razer` against a razer
     test agent.
   - Clean up the test sessions.

3. **`Menu.qml` (new), `manifest.json`, `~/.config/hypr/bindings.lua`: the
   menu.**
   - Manifest kinds become `["menu","bar-widget"]`, with `keepLoaded: true`
     and `entryPoints.menu`.
   - `Menu.qml` hosts `Card` over its own `HerdrModel` (local host only in
     this step), with the menu keys `↑↓ jk Enter o K x r Esc`.
   - Add the keybind line to p620's `bindings.lua`, then run
     `hyprctl reload`.

   → **Verify:**
   - `omarchy plugin validate $R` and `$LINT`.
   - `SUPER+SHIFT+H` opens the menu, and `Esc` closes it.
   - Pressing the keybind twice toggles the menu.
   - Focusing an agent in an attached session adds no window to
     `hyprctl clients -j | jq length`.
   - The bar badge still works alongside the menu.

4. **`Menu.qml`, `HerdrModel.qml`: hosts in the menu.**
   - Read `~/.config/omarchy/herdr.json`, poll one `Process` per host while
     the menu is open, and merge results with a host header and `●`/`○`/`–`.
   - `Tab` / `Shift+Tab` move between host groups.
   - `n` opens the new-session form (name, directory) for the current group's
     host.

   → **Verify:**
   - With `{"hosts":["razer"]}`, razer's sessions appear under a `razer`
     header.
   - With `{"hosts":["razer","nosuchhost"]}`, the menu opens straight away,
     `nosuchhost` shows `–`, and razer still renders.
   - With the file deleted, the menu shows local only.
   - After closing the menu,
     `pgrep -af 'ssh.*nixarchy-herdr' | grep -v ControlMaster` is empty
     within 10s, so there is no polling while closed.
   - `n` on razer creates a session (clean up after).

5. **`Menu.qml`: prompt line.**
    - `a` opens a prompt line for the selected agent. `Enter` sends through
      `prompt` with the text written to the process's stdin; the reply
      replaces the line; `Esc` cancels and kills a running prompt.
    - `working`, `blocked` or `unknown` agents get the confirmation dialog
      first (reuse `Card.qml`'s kill dialog pattern, focus on Cancel).

    → **Verify:**
    - A prompt to an idle test agent shows the reply in the menu.
    - A prompt to a `working` agent shows the dialog, and Cancel sends
      nothing (the agent's recent output is unchanged).
    - Closing the menu mid-prompt leaves no `herdr … agent prompt` process in
      `pgrep -af`.

6. **`README.md`: rewrite.**
    - Cover install (git clone plus enable), the `herdr.json` hosts file, the
      keybind, the menu keys, remote requirements (`bash`, `jq` and `herdr`
      on the host, BatchMode ssh), privacy (nothing written to disk) and
      attribution.
    - Run the full spec verification list: steps 1–10 re-checked, plus
      `grep -rn "nh-\|pong" ~/.cache ~/.local/state ~/.config/omarchy 2>/dev/null`
      returns nothing from the plugin.

    → **Verify** every item passes, with results recorded in the PR
    description.

7. **PR.**
    - `gh pr create --repo olafkfreund/nixarchy-herdr --base master`
    - The body links `intent/`, `spec/`, `plan/` and
      `olafkfreund/nixos_config#1821`, and lists the verification results.

    → **Verify** the PR exists and its diff contains only the files named in
    steps 1–11.

8. **razer install.** After merge; no repo change.
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
| `bin/herdr-sessions --host nosuchhost list` | non-zero exit, under 8s |
| `bin/herdr-sessions --host 'bad;name' list` | non-zero exit, no ssh spawned |
| `bin/herdr-sessions new -x` / `new 'a b'` / `new <existing>` | non-zero exit, session list unchanged |
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
