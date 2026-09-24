---
status: draft
issue: 6
author: olafkfreund
---

# Intent: fixes from the September review

Closes #6.

A deep review (five agents, Codex and Antigravity) of `bed5fb2` turned up the
problems below. Only findings that were checked against the code are included.
Claims that turned out to be wrong were dropped.

## Problem

**The list breaks or freezes**

- **Large sessions break the list.** `cmd_list` passes the snapshots to jq as
  command-line arguments (`bin/herdr-sessions:429-434`, and `:518` for remote
  hosts). Linux limits one argument to 128 KiB, but the script allows 2 MB per
  snapshot. Past the limit jq never starts, and the panel shows "unexpected
  output from herdr". This was reproduced. Upstream PR 13 fixes it by writing
  temp files, which would break the README promise that nothing is written to
  disk.
- **One stuck server freezes every poll.** The local `herdr api snapshot` and
  `herdr session list --json` calls (`:335`, `:337`, `:349`) have no timeout.
  Every ssh call does. The model starts a new poll only after the last one
  finishes, so one stuck server stops all updates.

**The panel says the wrong thing**

- **Dimming and blinking ignore the host.** `pendingName`
  (`HerdrModel.qml:233`, `:565`, compared at `Card.qml:256`) and the
  attention key (`agentKey` at `HerdrModel.qml:705`, `updateAttention` at
  `:722`, `blinking()` at `:740`, `Card.qml:475`) use the session name alone.
  Sessions are often named after workspace numbers, so local "3" and a remote
  "3" dim together, and the blink can point at the wrong machine. This is the
  same bug class PR #3 fixed for the actions themselves.
- **Two actions report success they didn't have.** `cmd_kill` prints
  `{"ok":true}` without checking that the server died (`bin/herdr-sessions`,
  end of `cmd_kill`). `cmd_prompt` discards herdr's refusal (`agent_blocked`,
  `agent_prompt_stalled`), so the menu shows the old screen as though it were
  the reply.
- **The docs contradict the code since #5.** README :189 still says kill is
  the only action that asks first. The confirm-dialog lines (README :98-104)
  and `bin/herdr-menu-keys:30`, `:42` leave out Delete.

**The menu doesn't follow the screen**

- **Nothing in the menu responds to screen size.** Text is `Style.font.* ×
  1.6` (`Menu.qml:55`), and the card is `min(Style.space(760), 60% of the
  screen)` wide (`Menu.qml:56`, `:272`). The shell's `Style` scales with the
  theme's font size only; nothing in it reads the screen. Hyprland applies each
  output's scale factor, but a large monitor still gets a small menu with
  fixed-size text. The 1.6 and the 760 were approved as a deviation in plan
  1821. This reverses that decision.
- **The menu can fail to appear.** `focusedScreen()` (`Menu.qml:46-53`)
  returns `null` when Hyprland's monitor name matches no screen, and the
  window is then created with `screen: null`. Nothing reports the failure.

**ssh and prompt hardening**

Neither item is exploitable today; both are defence in depth.

- **Polls inherit ssh config.** The poller runs every 3 s and keeps the
  connection open for 60 s. It inherits whatever `~/.ssh/config` sets for the
  host, including ForwardAgent, ForwardX11 and LocalCommand
  (`bin/herdr-sessions:138`).
- **Control characters reach the agent.** A pasted prompt can carry ESC, CR or
  C1 bytes straight into `herdr agent prompt` (`:711`).

## Proposed outcome

- A session with a snapshot over 128 KiB lists normally, locally and remotely,
  and nothing new is written to disk.
- A stuck local server gives that one session an error or drops it from the
  list. The other sessions keep updating.
- Acting on, or an agent blinking in, local "3" affects only local "3", not a
  remote "3".
- A kill that leaves the server running reports an error. A prompt herdr
  refuses reports the refusal, not a stale reply.
- README and the key sheet describe the confirm for both Kill and Delete.
- The menu's width and text size follow the size of the screen it opens on.
  They stay readable at 1366×768 and grow on a 4K screen. The theme's font
  setting is still respected.
- The menu always opens: on the focused screen, or on the first screen if
  that one can't be found.
- Remote polls ignore forwarding and LocalCommand from ssh config.
- Control characters are stripped from prompt text before it is sent.

## Affected users and systems

- **Users:** everyone running the widget or the menu. The ssh changes affect
  users with remote hosts in `~/.config/omarchy/herdr.json`.
- **Files:**
  - `bin/herdr-sessions`
  - `HerdrModel.qml`
  - `Card.qml`
  - `Menu.qml`
  - `README.md`
  - `bin/herdr-menu-keys`
  - `tests/session-actions.cjs`
- **Remote hosts** run this same script over ssh, so they get the fixes with
  nothing to install.

## Constraints

- **Nothing about sessions or agents gets written to disk** (README promise).
  Use process substitution or stdin for jq, not temp files.
- **The script keeps its JSON contract** of `ok`, `error` and the existing
  fields.
- **The bar dropdown and the pinned panel keep their current size**
  (`textScale` 1.0 from `HerdrModel.qml:21`). Only the menu changes.
- **Scaling builds on the theme's `Style` values.** The screen factor
  multiplies them; it doesn't replace them.
- **Tests fail before each fix and pass after,** in
  `tests/session-actions.cjs` or a new shell test with fake `herdr` and `ssh`
  on PATH:
  - a 200 KB snapshot
  - host-qualified keys
  - kill that fails
  - refused prompt
  - control-character stripping
- **Work is split across an agent team** with one owner per file, so the
  implementers don't edit the same file. The split and its order go in the
  plan.

## Open questions

1. **Scaling rule for the menu.** The proposed default: width is 45% of the
   screen, between `Style.space(560)` and `Style.space(1400)`. Text scale is
   `clamp(screen.height / 1080 × 1.6, 1.2, 2.4)`. Other options:
   - a single `menu.scale` setting in `herdr.json`
   - keeping 1.6, with a setting to override it
2. **Scope.** This intent leaves out:
   - CI
   - licence text for the logo
   - the manifest version bump
   - accessibility annotations
   - the upstream issues (4, 11, 12, 13)

   Should any of these be pulled in?
