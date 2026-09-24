---
status: approved
issue: 8
intent: intent/2026-09-24-8-review-followups.md
---

# Spec: follow-ups from the September review

## Design

Each change is the smallest one that removes the cause. Files are grouped so
that each group has one owner on the team (see Ownership).

### F1. Window matching: one window per process, full command lines, exact words

All of this is in `window_map` (`bin/herdr-sessions`).

- **Single-process terminals (upstream #4).** The jq that reads
  `hyprctl clients -j` keeps only the PIDs that own exactly one window:
  ```
  [.[] | select(.pid > 0)] | group_by(.pid) | map(select(length == 1) | .[0])
  | .[] | "\(.pid)\t\(.address)\t\(.workspace.name // "")"
  ```
  - A process that owns several windows (ghostty, footclient) maps to none, so
    "open" starts a new window instead of focusing the wrong one.
  - foot, which the launcher uses, runs one process per window and is
    unaffected.
- **Full command lines.** `ps -eo pid=,args= | grep -E 'her[d]r'` becomes
  `pgrep -af herdr`. pgrep reads `/proc/<pid>/cmdline`, so `COLUMNS` can't cut
  the line. Checked: `COLUMNS=80 ps` gives 81 bytes where the full line is 182.
  This also removes shellcheck's SC2009.
- **Exact words.** In `session_in_args`, the test `[[ ${words[i]##*/} ==
  herdr ]]` becomes `[[ ${words[i]} == herdr || ${words[i]} == */bin/herdr
  ]]`.
  - A path such as `~/src/herdr` no longer counts.
  - Both launcher forms still match: `foot … -e herdr --session X`, and
    `/nix/store/…/bin/herdr server`, which the check that follows excludes.

### F2. Remote reads have size caps

- **`cmd_new`'s polled `ssh_run "herdr session list --json"`** (`:692`) gets
  `| head -c "$((SESSIONS_BYTE_CAP + 1))"` before its jq.
- **Both `agent get` reads in `cmd_prompt`** (`:761`, `:765`) get `| head -c
  "$((SNAPSHOT_BYTE_CAP + 1))"`. An oversized answer then fails jq and falls
  through to the existing "could not reach that agent" handling.

### F3. Demo mode touches only its own file

- `private_dir` loses its two `find` lines, the recursive delete and the chmod
  of every file.
- Its only caller, `cmd_demo on`, already sets mode 600 on `$DEMO_FILE` itself.
- The directory is still created 0700, its owner is checked and a symlink is
  refused.

### F4. A cancelled remote prompt stops on the remote host

The command sent over ssh in `cmd_prompt` changes from
`t=$(cat); timeout 300 "$@" "$t" <wait flags>` to:

```bash
t=$(cat); timeout 300 "$@" "$t" <wait flags> & p=$!
trap '' PIPE
while kill -0 "$p" 2>/dev/null; do
  printf '\n' 2>/dev/null || { kill -TERM "$p"; break; }
  sleep 1
done
wait "$p"
```

- **How it detects the end.** When the local ssh dies (Esc, or the menu
  closing), the channel closes and sshd closes the command's stdout. The next
  heartbeat write then fails with EPIPE, and the prompt is sent TERM.
  `timeout` passes TERM on to herdr.
- **The exit code is unchanged.** `wait "$p"` passes herdr's exit code back,
  so the #6 handling of refusals (D4) still applies.
- **Heartbeats never reach the menu.** The local side already sends ssh's
  stdout to `/dev/null`.

Rejected: `ssh -tt`, so the remote command gets a hangup. The prompt text
travels on stdin, and a remote terminal would echo it and line-edit it, which
is exactly what #6's control-character stripping protects against.

Rejected: watching the parent process. This script's ssh sessions share one
connection (ControlMaster), so the remote parent is the connection's sshd,
which outlives the channel.

### F5. The menu doesn't poll hosts while closed

In `HerdrModel.qml`:

- **`refresh()`** (`:152`): `if (!remote) return` becomes `if (!remote ||
  !opened) return`. That removes the one extra poll after `submitNew` closes
  the menu.
- **`onOpenedChanged`, closed branch** (`:775`): stop every host poll, with
  `poll.running = false` for each `hostPolls.objectAt(i)`. Quickshell's
  Process ends the child. The script's ssh is under `timeout`, and killing it
  closes the channel.
- **`applyHostPayload(host, text)`** (`:212`): return at once if `remote &&
  !opened`. A poll that finishes as the menu closes, or the non-zero exit from
  the stop above, changes no host state. Otherwise every host would show as
  down when the menu next opens.

### F6. A confirm dialog blocks clicks behind it

- **Where:** in `Card.qml`'s `confirmKeys` item (`:681`) and `Menu.qml`'s
  (`:409`), before the `ConfirmDialog`.
- **What:** add `MouseArea { anchors.fill: parent; acceptedButtons:
  Qt.AllButtons; hoverEnabled: true; onWheel: function (wheel) {
  wheel.accepted = true } }`.
- **Why it works:**
  - `confirmKeys` already fills its parent, sits at `z: 10` and is visible only
    while the dialog is open.
  - This area swallows every click, hover and wheel event under the dialog.
  - The dialog is declared after it, so its buttons stay on top.
- `ConfirmDialog` belongs to the shell, and whether it already blocks clicks
  couldn't be checked locally. This adds no cost if it does.

### F7. Accessibility labels on rows

In `Card.qml`:

- **Session row delegate** (`:243`, `Rectangle { id: row }`):
  - `Accessible.role: Accessible.ListItem`
  - `Accessible.name: panel.sessionLabel(modelData) + (modelData.host ? " on "
    + modelData.host : "") + ", " + panel.countLabel(modelData)`
- **Agent row** (`:390`, `Item { id: agentRow }`):
  - `Accessible.role: Accessible.ListItem`
  - `Accessible.name: panel.cleanTitle(agentRow.modelData.title) + ", " +
    (panel.agentNote(agentRow.modelData.status) ||
    agentRow.modelData.status)`

These are the same helpers the visible text uses, so what is read aloud
matches what is shown. The bar button (`Panel.qml`) is the shell's own
`BarIconButton` and is out of reach here.

### F8. CI

A new file, `.github/workflows/ci.yml`:

- **Triggers:** `on: [push, pull_request]`.
- **Runner:** one job on `ubuntu-latest`. It already has shellcheck, jq, node
  and coreutils, so nothing is installed.
- **Steps:**
  1. checkout
  2. `bash -n bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh`
  3. `shellcheck bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh`
  4. `node tests/session-actions.cjs`
  5. `bash tests/herdr-sessions.sh`
- **Warnings:** shellcheck runs at its default severity. The four existing
  warnings are fixed so the run starts clean:
  - **SC2174:** `mkdir -p -m 700` becomes `mkdir -p` then `chmod 700`.
    `private_dir` already does the chmod.
  - **SC2009:** removed by F1.
  - **SC2178 ×2:** `window_map` renames its `seen` array to `emitted`, so it no
    longer shares a name with `cmd_list`'s scalars.
- **qmllint is left out**, as the intent says.

### F9. Licence, manifest and README

- **`assets/LICENSE-herdr`:** the Apache-2.0 text, copied verbatim from
  herdrdev/herdr's `LICENSE` (`gh api repos/herdrdev/herdr/contents/LICENSE`).
- **`assets/herdr-mark.svg`:** an XML comment at the top: `Derived from
  herdrdev/herdr's logo (Apache-2.0, see LICENSE-herdr): background removed,
  fill set to #ffffff, viewBox cropped to 60 60 340 340.`
- **`assets/herdr-logo.svg`:** compare it with upstream's file. If it is
  byte-identical, add only the source and licence comment. If it isn't, list
  what changed.
- **README credit:** names `assets/LICENSE-herdr`.
- **`manifest.json`:**
  - `version` becomes `0.3.0`.
  - The top-level `description` becomes: "herdr sessions and the agents inside
    them, here and on other machines: a keyboard menu to land on an agent,
    start a session or prompt one, and a bar widget with attention colours".
  - `barWidget.description` stays, since it describes the bar widget, which
    hasn't changed.
- **README fixes:**
  - :298 lists `ss`, `/proc`, `grep` and `awk` for remote kill.
  - :132 puts the badge in the bottom-right corner (`Panel.qml:217`).
  - :224-225 adds the 5 s refresh while something is active
    (`HerdrModel.qml:871`).

### Ownership

| Teammate | Files | Designs |
| --- | --- | --- |
| script | `bin/herdr-sessions`, `tests/herdr-sessions.sh` | F1–F4, F8 warning fixes |
| model | `HerdrModel.qml`, `tests/session-actions.cjs` | F5 |
| ui | `Card.qml`, `Menu.qml` | F6, F7 |
| repo | `.github/workflows/ci.yml`, `manifest.json`, `assets/*`, `README.md` | F8 workflow, F9 |

The one coordination point: CI passes only once the script teammate's
shellcheck fixes are in. The repo teammate writes the workflow. The lead
checks the whole run at integration by running the workflow's commands
locally, and on GitHub through the PR.

## Alternatives rejected

- **`ps -ww` instead of pgrep.** It fixes the truncation but keeps SC2009 and
  the grep.
- **Matching `/proc/<pid>/exe` for herdr.** It costs a readlink for every
  candidate process, and the stricter word check is enough.
- **Picking the focused window of a multi-window process (upstream #4).**
  Hyprland doesn't say which of a process's windows holds which herdr client,
  so a guess would still be wrong half the time.
- **`ssh -tt` and parent-watching for F4:** see F4.
- **`--severity=error` in CI** to hide the baseline warnings. Fixing four
  small warnings is cheaper than keeping an exception.
- **qmllint in CI:** see the intent.

## Risks

- **F4 depends on sshd closing the command's stdout when the channel closes.**
  That is OpenSSH's behaviour, but the test here uses a fake ssh. Verify on
  p620: send a long prompt, press Esc, and check that `pgrep -af "agent
  prompt"` on p620 is empty within 2 s.
- **F1 changes behaviour for users of single-process terminals.** They get a
  new window instead of focus on an existing one. This is intended, but it
  is a change. Documented in the README.
- **F1 needs pgrep,** which is procps and is present wherever `ps` is. It only
  runs locally, never on remote hosts.
- **F5: stopping a poll mid-ssh.** Killing a poll while ssh runs exercises the
  `timeout` wrapper, which ends ssh. The shared control connection survives
  (ControlPersist), so the next open is fast.
- **F8: runner images change.** If `ubuntu-latest` drops a preinstalled tool,
  CI fails loudly, and adding an `apt-get` step fixes it.

## Verification

- **`tests/herdr-sessions.sh`, new cases, each failing before its fix:**
  6. A fake `hyprctl` lists two windows with one PID. That PID is a real
     background process whose command line has `herdr --session s1`, so `list`
     gives `s1` no `windowAddress`. With one window, it has one.
  7. `list` runs with `COLUMNS=40` and the same process has a command line of
     more than 200 bytes. `s1` still gets its `windowAddress`.
  8. A process whose command line is `… ~/src/herdr --session s1` gives `s1`
     no `windowAddress`.
  9. `demo on` leaves an existing subdirectory and a mode-644 file in the
     cache dir exactly as they were.
  10. With a fake `ssh` that runs the remote command locally, the test kills
      the reader of its stdout. The fake herdr prompt process is gone within
      3 s.
  11. A fake `ssh` answering `agent get` with 3 MB makes `prompt` return
      `ok:false`, with memory bounded by the cap. The assertion is that it
      exits, and doesn't hang or print megabytes.
- **`tests/session-actions.cjs`, new cases:**
  - `refresh()` with `remote: true` and `opened: false` starts no host poll.
  - `applyHostPayload` while closed leaves `hostState` unchanged.
- **Tools:** `shellcheck` shows zero warnings on all three scripts. `bash -n`
  passes on them. `omarchy plugin validate .` passes.
- **CI:** the workflow runs green on the PR.
- **By hand:**
  - A screen reader (orca) reads a session row and an agent row.
  - A click beside an open Kill confirm does nothing.
  - The F4 check on p620 from Risks.
