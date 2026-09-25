---
status: draft
issue: 16
intent: intent/2026-09-25-16-menu-theme-size.md
---

# Spec: the menu is sized by the theme, not by the screen

## Design

This **reverses** #6 D7 (text and card width derived from the screen) and
#13 F2 (the 1.25× rule). #13 F1 (`ExclusionMode.Normal`) and F3 (named tabs
only) stay.

### T1. Text at the theme's size (`Menu.qml:64-65`)

- **`scaleH` is deleted** (`:64`); nothing else reads it.
- **`textScale` becomes `readonly property real textScale: 1.0`** (`:65`).
- **Why the property stays:** three places in `Menu.qml` multiply by it
  (`:361`, `:370`, `:401`), and `HerdrModel.qml:21` reads it through `host`
  for every Card row. Keeping it at 1.0 is a one-line change, while deleting
  it would touch five sites for the same result.
- **What sets the size now:** `Style.font.*` carries the theme's `[font]
  base-size`, and Hyprland applies each monitor's scale. So the menu's text
  follows exactly what the bar's and the terminals' text follows.

### T2. The card at a theme-relative width (`Menu.qml:66-67`, `:287`)

```qml
readonly property int cardWidth: Style.space(760)
...
width: Math.min(root.cardWidth, Math.round(panel.width * 0.6),
                panel.width - Style.gapsOut * 2)
```

- **`Style.space(760)`** grows with the theme's spacing scale, and with its
  font size when `scale-with-font` is on. On p620 (spacing scale 1.0, base
  size 12) it is **760 px**.
- **The 60% cap** comes from the code before #6. It keeps the card narrow on a
  small screen.
- **The gaps term** is kept from #6, so a card can never touch the screen's
  edges.

### T3. Comment and README

- **`Menu.qml`:** the comment above the properties (`:57-63`) is rewritten to
  say:
  - The menu takes its sizes from the theme (`Style.font`, `Style.space`) like
    everything else on the desktop, and Hyprland's per-monitor scale does the
    rest.
  - An earlier version multiplied by screen height, which made it about 1.7×
    too large on 1440p. This line records why not to bring that back.
- **`README.md:34-36`:** "Its size and text follow that screen: text grows
  with the screen's height, and the card takes a bit under half its width,
  within set limits." becomes: its text and width follow your theme's font
  size and the monitor's scale, like the rest of the desktop, and it stays
  below the bar.

### Ownership

One teammate, **menu**, owns `Menu.qml` and `README.md`.

## Alternatives rejected

- **Keeping a small multiplier (1.1×) for "read from further away".**
  Considered, but the user chose 1.0×.
- **Deleting `textScale` everywhere.** It touches five sites and
  `HerdrModel`'s interface, all for the same visible result.
- **A percentage of the screen for width.** That is what #6 did, and a 2560
  px screen made it 1152 px. A theme unit with a screen cap is what the
  desktop's other surfaces use.

## Risks

- **A theme with a large base size makes a large menu.** That's intended: the
  menu follows the theme the same way the bar does.
- **760 units can feel narrow for long agent titles.** Titles already elide.
  If it reads cramped, the number is one line to change, with its own intent.

## Verification

- **`grep -n "scaleH\|1.25 \* scaleH\|0.45" Menu.qml`** prints nothing.
- **`grep -n "textScale: 1.0\|Style.space(760)\|0.6" Menu.qml`** finds all
  three.
- **Checks:** `node tests/session-actions.cjs` passes, `bash
  tests/herdr-sessions.sh` passes cases 1–13 (unaffected), `omarchy plugin
  validate .` passes, and CI is green.
- **On p620, by screenshot,** after the nixarchy bump and deploy (announced
  on the bus):
  - The menu's text is the same size as the bar's.
  - The card is about 760 px wide on a 2560×1440 screen, where it's 1152 px
    today.
  - It still sits below the bar.
