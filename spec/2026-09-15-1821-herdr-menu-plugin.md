---
status: draft
issue: 1821
intent: intent/2026-09-15-1821-herdr-menu-plugin.md
---

# Spec: herdr menu plugin for Omarchy

Base: `jankeesvw/omarchy-herdr` 1.1.0 (`fa545a4`), in this repository. Plugin ID
`nixarchy.herdr`.

## Decisions on the intent's open questions

These are proposed defaults. Approving this spec approves them.

| # | Question | Decision |
| --- | ---------- | ---------- |
| 1 | Several kinds in one manifest? | Yes. `omarchy.menu` ships `["menu","bar-widget"]`, and `omarchy plugin validate` accepted a stub `nixarchy.herdr` manifest declaring `menu`, `service` and `bar-widget` (exit 0). This plugin declares **`menu` and `bar-widget` only**. See "Alternatives rejected" for `service`. |
| 2 | Hosts | p620 and razer. p510 is left out: it has no herdr, and installing it needs approval. Hosts are configuration, so adding p510 later touches no code. |
| 3 | Remote transport | Plain `ssh -o BatchMode=yes`, not `herdr machine add`. Nothing on the remote host is changed or prepared. |
| 4 | Upstream PRs | Not part of this task. |
| 5 | Keybind | `SUPER + SHIFT + H`. Plain `SUPER + H` is Nixi. A spacing-insensitive search of all 14 Hyprland Lua files (user and `$OMARCHY_PATH/default`) found `SUPER + SHIFT/CTRL/ALT + H` unbound. |
| 6 | Prompting a busy agent | Allowed after a confirmation dialog when the agent is `working`, `blocked` or `unknown`. `idle` and `done` send straight away. |

## Design

### Files

```text
manifest.json        id nixarchy.herdr, kinds [menu, bar-widget], keepLoaded
Menu.qml             new: keyboard menu, overlay layer, exclusive keyboard focus
Panel.qml            existing bar widget + panel; now reads state from HerdrModel
Card.qml             existing session/agent list; unchanged interface (`panel`)
HerdrModel.qml       new: state + actions moved out of Panel.qml, shared by both
bin/herdr-sessions   existing data/actions script; gains host, new, prompt
README.md / LICENSE  rewritten README, both copyright lines kept in LICENSE
intent/ spec/ plan/  workflow artifacts
```

### Entry points

- **`Menu.qml`** follows the built-in menu contract in
  `$OMARCHY_PATH/shell/plugins/menu/Menu.qml`: a root `Item` exposing
  `open(payloadJson)`, `close()` and `opened`, which shows a `PanelWindow` on
  `WlrLayer.Overlay` with `WlrKeyboardFocus.Exclusive`. It hosts `Card.qml`
  and adds a host header, a new-session form and a prompt line.
- **`Panel.qml`** stays the bar widget. It keeps its badge, polling and pin
  behaviour, and moves session state and actions into `HerdrModel.qml`.
- **Keybind:** added by the user to `~/.config/hypr/bindings.lua`:
  `o.bind("SUPER + SHIFT + H", "Herdr", "omarchy-shell shell toggle nixarchy.herdr '{}'")`.

`HerdrModel.qml` is the one refactor of upstream code. `Card.qml` already takes
everything through its `panel` property, so both entry points hand it a model
with the same functions (`openSession`, `focusAgent`, `killSession`,
`deleteSession`, `refresh`). The two entry points must not each carry a copy
of that logic.

### Hosts

Configuration lives in `~/.config/omarchy/herdr.json`. A missing or broken file
means local only.

```json
{ "hosts": ["razer"] }
```

- The local machine is always first and is not listed.
- Host names must match `^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$`. Anything else is
  dropped before it reaches a command line. Names resolve through the user's
  `~/.ssh/config`.
- Reachability is shown per host as `●` (answered), `○` (reachable, no
  sessions running) or `–` (unreachable or timed out).

### Data script: `bin/herdr-sessions`

The existing actions keep their output format. A leading `--host <name>` runs
an action against that host, and without it the script runs locally as today.

| Action | Local (today) | Remote (`--host H`) |
| --- | --- | --- |
| `list` | unchanged, plus `"host": ""` in each session | the script's own `list` runs on H via `ssh H bash -s -- list --no-windows` with the script piped on stdin, so nothing is installed remotely. Needs `bash`, `jq` and `herdr` on H (all present on razer). Sessions carry `"host": "H"`, and windows are matched locally. |
| `open S` | focus the paired window, else start `foot -e herdr --session S` | focus the window paired to `H/S`, else `foot -e herdr --remote H --session S` |
| `focus S PANE` | `herdr --session S agent focus PANE`, then the window | same `agent focus` over ssh first, then the local window |
| `kill S` / `delete S` | unchanged (TERM → KILL, keeps confirmation) | over ssh, same confirmation |
| `new S [DIR]` | **new** | **new** |
| `prompt S PANE` | **new** | **new** |

**Window matching fix.** `session_in_args()` only reads `--session`, so today a
`herdr --remote razer --session X` window is matched to a local session named
X. Matching becomes keyed on `host/session`: `--remote <target>` supplies the
host (the part after any `user@`), and without it the host is local. That
covers the case where razer has a session with the same name as one on p620.

**`new S [DIR]`**

- Refuses a name that does not match `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. That
  rules out the leading-dash case behind the stray `--help` session found on
  p620.
- Refuses a name that already exists on that host, according to
  `herdr session list --json`. It never attaches to or restarts an existing
  session.
- Local: `foot --working-directory DIR -e herdr --session S`.
- Remote: `foot -e herdr --remote H --session S`. When DIR is given, it waits
  for the server socket, then runs
  `ssh H herdr --session S workspace create --cwd DIR`.

**`prompt S PANE`**

- The prompt text comes in on **stdin**, never argv, so no shell quoting has
  to be trusted. For remote hosts, every argument is passed through
  `printf %q` into the fixed remote command, and the text still travels on
  stdin.
- Runs `herdr --session S agent prompt PANE "$text" --wait --until idle --until done --until blocked`
  under `timeout 300`, then `herdr --session S agent read PANE --source recent --lines 60`.
- Prints `{"ok":true,"status":…,"output":…}`. The output is capped at the
  same byte ceiling the script already applies to other herdr output.
- Nothing is written to disk. Closing the menu kills the process.

**SSH options for every remote call**, all in one function:
`-o BatchMode=yes -o ConnectTimeout=4 -o ControlMaster=auto -o ControlPersist=60 -o ControlPath=$XDG_RUNTIME_DIR/nixarchy-herdr-%C`,
wrapped in `timeout 8`. The shared connection means a 3-second poll is one
handshake per minute, not twenty.

### Polling

- Bar widget: local host only, at upstream's intervals (3s / 5s / 20s). A
  remote host that is down can therefore never slow the badge.
- Menu: every configured host, polled in parallel with one `Process` per host,
  every 3 seconds while the menu is open and not at all while it is closed.
  Results are merged, so a slow host shows `–` and the other hosts still
  render.

### Menu keys

| Key | Action |
| --- | --- |
| `↑` `↓`, `j` `k` | move |
| `Tab` / `Shift+Tab` | next / previous host group |
| `Enter`, `o` | open a session or focus an agent |
| `n` | new-session form on the current host (name, directory) |
| `a` | prompt line for the selected agent; `Enter` sends, `Esc` cancels |
| `K` | kill a running session (confirm, focus starts on Cancel). Upstream's `k` is taken by vim movement here. |
| `x` | delete a stopped session |
| `p` | pin, as upstream |
| `r` | refresh |
| `Esc` | close the prompt or dialog, otherwise close the menu |

## Alternatives rejected

- **A `service` kind holding shared polling state.** Nothing found shows how a
  plugin's `menu` and `bar-widget` would reach its own service instance. The
  shared `HerdrModel.qml` component gives code sharing without that unknown.
  Revisit if polling twice becomes a measured cost.
- **Forking omarchy-ask.** That means about 5.6k lines of ACP, npm and QML to
  reuse only the launcher shape. Herdr's agents are already running, and
  `herdr agent prompt/read/wait` reaches them with no bridge process.
- **An ACP bridge to herdr agents.** herdr does not speak ACP, and its CLI
  already provides submit, wait for a state, and read.
- **`herdr machine add` / `--machine`.** It prepares and saves remote servers,
  which changes the remote host. Plain ssh leaves remote hosts untouched and
  uses the existing keys.
- **Installing the data script on remote hosts.** Piping it over
  `ssh … bash -s` means no remote install and no version skew.
- **A Home Manager `home.file` plugin tree.** `omarchy plugin validate` rejects
  symlinks, and hot reload needs a writable checkout.
- **Refusing prompts to busy agents.** It blocks answering a `blocked` agent,
  which is the most useful case.

## Risks

- **`herdr --remote H --session S` against a stopped or missing session may not
  start the server** (unverified). If it does not, `open` on a stopped remote
  session and remote `new` fail. The plan verifies this first, with a
  throwaway session on razer, before writing any code that depends on it.
- **Focus on a session with two attached clients may move both** (unverified).
  The plugin keeps one window per session, as upstream does.
- **SSH latency** between the remote `agent focus` and the local window focus:
  the pane switches up to a second after the window appears. Cosmetic.
- **Prompting a working agent** interleaves with its own output. That is why
  the confirmation exists.
- **Shell-process stability.** Plugins run inside omarchy-shell. A QML error
  can break the menu, and on a hard fault the whole shell. Actions stay in
  `Process` children, never in blocking calls from QML.
- **Upstream sync.** The `HerdrModel.qml` split makes future `upstream` merges
  conflict in `Panel.qml`. Accepted, because this is our repository now.
- **Local edit loss.** The blocked-count badge edit in the installed
  `jankeesvw.herdr` is carried over as an explicit change, not copied as a file.
- **Hosts:** p620 and razer only. Nothing touches p510.

## Verification

1. `omarchy plugin validate .` exits 0.
2. `qmllint -I "$OMARCHY_PATH/shell" Menu.qml Panel.qml Card.qml HerdrModel.qml`
   reports no errors.
3. `bin/herdr-sessions list | jq -e '.sessions | all(has("host"))'` passes, and
   `bin/herdr-sessions --host razer list` returns razer's sessions tagged
   `"host":"razer"` within 8 seconds.
4. With `hosts` containing a name that does not resolve, the menu opens, shows
   that host as `–`, and lists p620 and razer normally.
5. `bin/herdr-sessions new -x`, `new 'a b'` and `new <existing>` each exit
   non-zero with an error, and `herdr session list` is unchanged.
6. On the dev checkout, installed as `nixarchy.herdr` with `jankeesvw.herdr`
   disabled:
   - `SUPER + SHIFT + H` opens the menu, and `Esc` closes it.
   - Focusing an agent in an attached local session changes the pane in the
     existing window, and `hyprctl clients` shows no new window.
   - Focusing an agent on razer opens exactly one `herdr --remote razer`
     window. A second focus reuses it.
   - `n` creates a throwaway session locally and on razer, and deleting it
     removes it.
   - `a` sends "reply with the word pong" to an idle test agent, and the
     reply is shown. A second send while the agent is `working` asks for
     confirmation first.
   - The bar badge still counts and colours as before, including the
     blocked-count-first change.
7. `grep -rn "herdr" ~/.cache ~/.local/state 2>/dev/null` shows no prompt or
   agent output written by the plugin.
