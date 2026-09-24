---
status: approved
issue: 8
author: olafkfreund
---

# Intent: follow-ups from the September review

Closes #8. This follows #6 (PR #7) and covers the review findings that #6
left out on purpose: project hygiene, plus every remaining medium finding.
Findings rated low are listed under open questions.

## Problem

**Project hygiene**

- **No CI.** Nothing runs the two test suites, `bash -n` or `shellcheck` on a
  push or a PR. The #6 tests exist but only run by hand.
- **The logo's licence is incomplete.** `assets/herdr-logo.svg` and
  `assets/herdr-mark.svg` come from herdrdev/herdr (Apache-2.0).
  - The repo has no copy of the Apache-2.0 text (§4(a)).
  - `herdr-mark.svg` was changed and says nothing about it (§4(b)): the
    background is removed, the fill is white and the viewBox is cropped.
  - The MIT `LICENSE` and the README credit don't cover either point.
- **The manifest is stale.** `manifest.json` still says version 0.2.0 after
  the key sheet, #3, #5 and #7. Its description (`:7`, `:20`) covers only the
  bar widget. It doesn't mention the menu, remote hosts or prompting.
- **No accessibility.** No QML file sets `Accessible.*`. A screen reader gets
  nothing from a session or agent row, even though everything can be reached
  by keyboard.

**Remaining medium findings**

- **Single-process terminals get the wrong window (upstream #4).**
  `window_map` (`bin/herdr-sessions`) keys windows on the Hyprland client PID.
  ghostty, footclient and other single-process terminals give every window
  the same PID, so every session inside them maps to one window, and "open"
  focuses the wrong one.
- **Window matching reads `ps` loosely.**
  - `ps -eo pid=,args=` cuts `args` at `$COLUMNS` when that is set, even when
    piped. This was reproduced. A long command line loses its `--session`
    flag, so its window isn't found, and "open" starts a second one.
  - Any argv word ending in `/herdr` counts as a herdr client. That includes
    a path such as `vim ~/src/herdr`.
- **The menu keeps polling after it closes.**
  - `submitNew` closes the menu, then `settleTimer` calls `refresh()`, which
    polls every host once (`HerdrModel.qml:152-165`).
  - A host poll already running when the menu closes still applies its
    result.
  - The approved 1821 plan says remote hosts are polled "not at all while it
    is closed".
- **Cancelling a remote prompt leaves it running.** It kills only the local
  ssh (`cmd_prompt`). The remote `herdr agent prompt --wait` keeps running
  until its own `timeout 300`.
- **Clicks reach the list behind a confirm dialog.** The confirm catches keys
  (`confirmKeys`, `Card.qml:682`, `Menu.qml:409`), but the row mouse areas
  underneath still take clicks. With the Kill confirm open for one session, a
  click can open or act on another.
- **Two remote reads have no size cap.** `cmd_new`'s polled `herdr session
  list --json` over ssh (`bin/herdr-sessions:692`) and `cmd_prompt`'s `agent
  get` (`:761`, `:765`) are read with no `head -c`, unlike every other remote
  read. A broken or hostile host can make local memory grow without limit.
- **Demo mode touches more than its own files.** `private_dir` deletes every
  entry in the cache directory that isn't a regular file, and chmods every
  file in it. `demo on` calls it on `~/.cache/omarchy-herdr`.
- **The README understates what remote hosts need.** README :298 lists
  `bash`, `jq` and `herdr`, but remote kill also needs `ss`, `/proc`, `grep`
  and `awk`.

## Proposed outcome

- **CI:** every push and PR runs `bash -n`, `shellcheck`, `node
  tests/session-actions.cjs` and `bash tests/herdr-sessions.sh`, and fails on
  a new warning or a failing test.
- **Licence:** the repo ships the Apache-2.0 text for the logo, and
  `herdr-mark.svg` says what was changed.
- **Manifest:** version 0.3.0, with a description of what the plugin does now.
- **Accessibility:** a screen reader announces each session row (name, host,
  state, agent counts) and each agent row (name, status).
- **Wrong window:** in ghostty-style terminals, "open" opens a new window
  instead of focusing the wrong one.
- **Window matching:** a long command line still maps to its window, and only
  real herdr processes count.
- **Polling:** closing the menu stops all ssh polling, and no remote result
  arrives after it closes.
- **Remote prompt:** Esc on a remote prompt stops the command on the remote
  host too.
- **Confirm dialog:** while it is open, clicks outside it do nothing.
- **Remote reads:** every read from a remote host is size-capped.
- **Demo mode:** `demo on` touches only the demo flag file.
- **README:** it lists every tool a remote host needs.

## Affected users and systems

- **Users:** everyone running the widget. The remote-host items affect users
  with hosts in `~/.config/omarchy/herdr.json`, and the upstream #4 fix
  affects users of single-process terminals.
- **Files:**
  - `bin/herdr-sessions`
  - `HerdrModel.qml`
  - `Card.qml`
  - `Menu.qml`
  - `Panel.qml`, for accessibility only
  - `manifest.json`
  - `README.md`
  - `assets/`
  - `tests/`
  - a new `.github/workflows/` file
- **Remote hosts** run the same script over ssh and need nothing installed.

## Constraints

- **Same rules as #6:**
  - nothing about sessions or agents is written to disk
  - the script's JSON contract is unchanged
  - each fix with logic gets a test that fails first, in
    `tests/session-actions.cjs` or `tests/herdr-sessions.sh`
- **CI stays small:** one workflow, no `qmllint`. Its baseline is hundreds of
  warnings from the `qs.*` modules, which CI can't resolve, and `omarchy
  plugin validate` needs the Omarchy tree.
- **The upstream #4 fix only stops wrong focus.** It must not change
  behaviour for terminals with one process per window, like foot.
- **The work is split across an agent team with one owner per file,** as in
  #6.
- **Merge with a merge commit.**

## Open questions

Resolved at approval (2026-09-24), with the proposed defaults:

1. Of the low findings, only the README facts (badge corner, 5 s refresh)
   are added.
2. Upstream drift gets its own task later.
3. The spec chooses the remote-cancel approach.


1. **The low findings.** Should any of these join this task?
   - A directory with control characters breaks `new` on a fish login shell.
   - Double spaces in a directory name are collapsed.
   - The remote session list is not re-checked locally, so a name could be
     spoofed on screen.
   - The confirm-dialog focus code is duplicated.
   - The README puts the badge in the wrong corner and leaves out the 5 s
     refresh.
   - `preview.png` duplicates `assets/screenshot.png`, and the menu has no
     screenshot.
   - `Menu.open()` refreshes more often than needed.
   - The plan-1821 step-9 note is out of order.

   Proposed: only the README facts, since that file is being edited anyway.
2. **Upstream drift.** Upstream (jankeesvw) is 5 commits ahead: tab names
   (their PR 9) and theme status colours (their PR 10). Pull them in here, as
   their own task, or not at all? Proposed: their own task, because they touch
   the same files as this one and would conflict.
3. **Remote prompt cancel.** The proposed approach runs the remote command
   with `ssh -tt`, so a dropped connection sends SIGHUP to it. That allocates
   a remote tty, which herdr doesn't need. The alternative is a remote
   wrapper that watches its parent and kills the prompt when ssh goes away.
   The spec will choose; say now if you have a preference.
