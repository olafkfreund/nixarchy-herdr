---
status: draft
issue: 16
spec: spec/2026-09-25-16-menu-theme-size.md
---

# Plan: the menu is sized by the theme, not by the screen

Closes #16. Branch `fix/16-menu-theme-size`, base master `d9e1856` (v1.0.0)
plus this task's artifact commits.

## Approved decisions (from the spec)

- **Reversals:** this undoes #6 D7 and #13 F2. #13 F1 (`ExclusionMode.Normal`)
  and F3 (named tabs only) stay.
- **T1, text** (`Menu.qml:64-65`):
  - Delete `scaleH`.
  - `textScale` becomes `readonly property real textScale: 1.0`.
  - The property itself stays, because `:361`, `:370`, `:401` and
    `HerdrModel.qml:21` read it.
- **T2, width** (`Menu.qml:66-67`, `:287`):
  - `cardWidth` becomes `Style.space(760)`.
  - The card's width becomes `Math.min(root.cardWidth, Math.round(panel.width
    * 0.6), panel.width - Style.gapsOut * 2)`.
- **T3, words:**
  - Rewrite the comment above the properties (`:57-63`). It says sizes come
    from the theme (`Style.font`, `Style.space`) and Hyprland's per-monitor
    scale. It also says that an earlier screen-height multiplier made the
    menu about 1.7× too large on 1440p, so it isn't to come back.
  - `README.md:34-36`: the text and width follow your theme's font size and
    the monitor's scale, like the rest of the desktop, and the menu stays
    below the bar.

## Team

One teammate, **menu**, in its own worktree from `fix/16-menu-theme-size`,
owns `Menu.qml` and `README.md`. It never edits this plan; deviations go to
the lead.

## Steps

M1. **`Menu.qml` (T1, T2, and T3's comment)**, then **`README.md` (T3)**.
Make one commit.

→ Verify:

- `grep -n "scaleH\|0.45" Menu.qml` prints nothing.
- `grep -n "textScale: 1.0" Menu.qml`, `grep -n "Style.space(760)" Menu.qml`
  and `grep -n "panel.width \* 0.6" Menu.qml` each find one line.
- `grep -n "ExclusionMode.Normal" Menu.qml` still finds one line.
- `grep -n "screen's height" README.md` prints nothing.

## Tests

| Command | Expected |
| --- | --- |
| `node tests/session-actions.cjs` | All cases pass |
| `bash tests/herdr-sessions.sh` | Cases 1–13 `ok` (unaffected) |
| `shellcheck` / `bash -n` on the 3 scripts | Clean |
| `omarchy plugin validate .` | Passes |
| CI on the PR | Green |

**On p620, after the nixarchy pin bump and a p620 deploy** (announced on the
bus, with the runner-unit check first), by screenshot on the 2560×1440
monitor:

- The menu's text is the same size as the bar's.
- The card is about 760 px wide; it was 1152 px.
- The top edge is below the bar.

## Rollback

`git revert` the M1 commit. After merge, revert the PR's merge commit. Merge
with a merge commit.
