---
status: approved
issue: 11
author: olafkfreund
---

# Intent: bring in upstream's tab names and theme status colours

Closes #11.

## Problem

This fork was taken from jankeesvw/omarchy-herdr at `fa545a4` (1.1.0,
2026-09-10). Upstream has moved on five commits to `49fca4a` (1.2.0,
2026-09-18), and the fork has neither of its two features.

- **Tab names (their PR 9).** An agent row says which workspace the agent is
  in (`Card.qml:513`, `agentRow.modelData.workspace`), but not which tab.
  herdr names both. With more than one tab in a workspace, the row doesn't say
  where the agent is.
- **Theme status colours (their PR 10).** The "done" and "working" colours are
  hard-coded at `HerdrModel.qml:52`, `#5FA46B`, and `:56`, `#D6A84B`, because
  Omarchy themes carry no green. The "working" foreground is the theme accent
  (`:645`, `:676`, `:683`). A theme can't choose any of them. Upstream lets a
  theme set `done` and `working` under `[herdr]` in its `shell.toml`, passed
  through the shell's own `flatColor`.

A plain `git merge upstream/master` won't apply cleanly. The fork moved
upstream's model code out of `Panel.qml` into `HerdrModel.qml`. Upstream's
colour and place logic is written against `Panel.qml`, and its jq change sits
in a `cmd_list` that #6 and #8 rewrote around pipes.

## Proposed outcome

- **Tab names:** an agent row shows "workspace · tab" when both have names,
  and only the part that exists otherwise. A tab nobody named, whose label is
  just its number, isn't shown. That matches upstream's rule.
- **Theme colours:** a theme with `[herdr] done = …` and/or `working = …` in
  its `shell.toml` changes those colours in the bar, the dropdown, the pinned
  panel and the menu. A theme without them looks exactly as it does today. A
  role name like `accent` or an eight-digit hex works, and a value `flatColor`
  can't read falls back to today's colour, not black.
- **README:** documents both. It credits upstream for them.
- **Future syncs start from `49fca4a`:** git records upstream as merged, so
  the next sync's diff starts there, not at `fa545a4`.

## Affected users and systems

- **Users:** everyone running the widget or the menu. Colours only change for
  themes that set the new keys.
- **Files:**
  - `bin/herdr-sessions`, for the `tab` field in `agentList` and the demo data
  - `HerdrModel.qml`
  - `Card.qml`
  - `README.md`
  - `manifest.json`
  - `tests/`
- **nixarchy:** it pins this repo, so it gets this through a later pin bump,
  as with #954.

## Constraints

- **Port upstream's behaviour into the fork's structure; don't copy its files
  over ours.** Everything #5, #6 and #8 changed stays:
  - host-keyed state
  - the jq inputs through pipes
  - the size caps
  - screen scaling
  - accessible names
- **Credit stays correct.** Upstream is MIT, and `LICENSE` already names both
  holders, which nixarchy's build checks. The commits say which upstream
  commits they port.
- **Tests fail first, where there is logic:**
  - the `tab` join in `tests/herdr-sessions.sh`, with a named tab, an unnamed
    tab and no tab
  - `agentPlace()` and the colour fallback in `tests/session-actions.cjs`
- **CI stays green,** with shellcheck clean.
- **Work is split across an agent team with one owner per file,** as in #6
  and #8.
- **Merge with a merge commit.**

## Open questions

Resolved at approval (2026-09-24), with the proposed defaults:

1. `git merge -s ours upstream/master`, in its own commit.
2. 0.4.0.
3. The accessible name includes the place.


1. **Recording upstream as merged.** Proposed: after the port, run `git merge
   -s ours upstream/master` in its own commit. That records the ancestry
   without taking upstream's files. The alternative is to leave the history
   alone, so every future sync diff starts again at `fa545a4`.
2. **Version.** The fork is 0.3.0 and upstream is 1.2.0; the two numbers are
   unrelated. Proposed: 0.4.0.
3. **Accessible names.** Should an agent row's accessible name (added in #8)
   also say "workspace · tab"? Proposed: yes, so a screen reader hears what is
   on screen.
