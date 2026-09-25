---
status: draft
issue: 16
author: olafkfreund
---

# Intent: the menu is sized by the theme, not by the screen

Closes #16.

## Problem

The menu is far too big on a normal desktop. On p620 (2560×1440 at scale 1,
theme font base size 12), with plugin `3b789dd`:

- **Text is 1.67× the theme font.** `Menu.qml:65` computes `1.25 × 1440 /
  1080`. The bar, the dropdown and the terminals all use 1.0×, so the menu's
  text is about 20 px next to everything else at about 12 px.
- **The card is 1152 px wide,** 45% of the 2560 px screen (`Menu.qml:66`),
  and fills most of the height with large rows.

The cause is a misreading, in #6, of the request that "text and windows need
to follow the desktop size and scale". It was built as "grow with the screen's
resolution". The request meant "match the desktop", and the desktop already
has two ways to do that. The plugin doesn't need to add a third:

- **The theme's font size.** `[font] base-size` in `shell.toml` feeds
  `Style.font.*`. With `scale-with-font`, it also feeds `Style.space()`.
- **Each monitor's scale factor.** Hyprland hands the shell logical pixels, so
  a scale-2 monitor already draws everything twice as large.

#13 lowered the multiplier from 1.6 to 1.25 but kept the screen-height rule,
so on a 1440p screen it's still 1.67×.

## Proposed outcome

- **Text matches the desktop.** The menu's text is the same size as the bar's,
  the dropdown's and the terminals': 1.0× the theme font, on every monitor. A
  larger theme font or a higher monitor scale makes it bigger, the same as
  everything else.
- **A modest card.** The card is `Style.space(760)` wide, which follows the
  theme through `Style.space`, capped at 60% of the screen and never wider
  than the gaps allow. That's the size the menu had before #6.
- **#13's fixes stay:** the menu sits below the bar, and auto-titled tabs are
  hidden.
- **The README says what the code does.** It currently promises that "text
  grows with the screen's height" (`README.md:34-36`).

## Affected users and systems

- **Users:** everyone who opens the menu. The bar dropdown and the pinned
  panel are unchanged; they already use 1.0×.
- **Files:** `Menu.qml` (the sizing properties and their comment) and
  `README.md` (two sentences).
- **Hosts:** nixarchy, p620 and razer get it through the usual pin bump and
  deploy.

## Constraints

- **The sizing uses only `Style` values and the screen-width cap.** No
  multiplier derived from resolution.
- **The approved decisions this reverses are named** in the spec: #6 D7 and
  #13 F2.
- **The change is checked on p620 by screenshot,** against the 2026-09-25
  screenshot: text the same size as the bar's, and a card about 760 px wide at
  base size 12.
- **One teammate:** a small change in two files.
- **Merge with a merge commit.**

## Open questions

None. Text at 1.0× and the width as above were chosen by the user
(2026-09-25).
