---
status: approved
issue: 4
author: olafkfreund
---

# Intent: deleting a session asks first, and a failed delete says so

Closes #4.

## Problem

nixarchy ships this widget on by default (olafkfreund/nixarchy#787), so Delete
is now one keypress away on every nixarchy desktop. Two things about it are
unsafe or dishonest:

- **Delete doesn't ask.** `D` (`Card.qml:97-99`, `onDeleteRequested` calls
  `panel.removeSession`) and the trash button (`Card.qml:639`) delete a stopped
  session's saved state immediately. Kill, the other destructive action,
  already asks first: `askKill` opens a confirm that starts on Cancel
  (`HerdrModel.qml:297-314`, `Card.qml:670+`).
- **A failed delete reports success.** `cmd_delete` runs
  `herdr session delete "$name" >/dev/null 2>&1 || true` and then always prints
  `{"ok":true}` (`bin/herdr-sessions:821-822`). When herdr refuses or fails,
  the widget shows success, and the session reappears on the next refresh with
  no explanation.

## Proposed outcome

- Delete, from the key and from the button, opens the same confirm Kill uses,
  on Cancel by default. Enter on Cancel, or Escape, leaves the session alone.
- Confirming deletes it, as today.
- A failed `herdr session delete` returns `{"ok":false,"error":"…"}` with
  herdr's own message, and the widget shows it, as it already does for other
  failed commands.

## Affected users and systems

Every user of the widget, including the remote-host path (the script pipes
itself over ssh, so the same fix covers remote deletes). It affects `Card.qml`,
`HerdrModel.qml`, `bin/herdr-sessions` and `tests/session-actions.cjs`.

## Constraints

- **Reuse Kill's confirm** rather than adding a second dialog: one confirm
  component, parameterised by the action.
- **Default stays on Cancel,** the same reasoning as Kill's.
- The script keeps its JSON contract, with `ok` and `error` as the other
  commands already use.
- Both changes are proven by tests that fail first in
  `tests/session-actions.cjs`: Delete doesn't run before confirming, and a
  failing `herdr session delete` yields `ok:false`.

## Open questions

None.
