---
status: approved
issue: 4
intent: intent/2026-09-19-4-delete-confirm.md
---

# Spec: deleting a session asks first, and a failed delete says so

## Design

### One confirm, two actions

Kill's confirm becomes the confirm for both destructive actions, without a
second dialog (a constraint in the intent).

- `killTarget` becomes `confirmTarget`, plus `property string confirmAction`
  (`"kill"` or `"delete"`), in `HerdrModel.qml:87-88`.
- `askKill(session)` (`:300`) sets `confirmAction = "kill"`. A new
  `askDelete(session)` has the same shape, the same guard as `removeSession`
  (not the default session, not running, a valid name), and sets
  `confirmAction = "delete"`. Both open the same dialog, which starts on Cancel,
  as `ConfirmDialog` already does.
- `confirmKill()` (`:313`) becomes `confirmPending()`: it closes the dialog,
  then calls `killSession` or `removeSession` depending on `confirmAction`.
  `closeKill()` becomes `closeConfirm()`.
- `killMessage()` (`:319`) becomes `confirmMessage()`. Kill keeps its text.
  Delete asks "Delete the saved session …? The state herdr kept for it is
  removed."
- In `Card.qml` (`:664+`), the dialog's `confirmText` follows the action
  ("Kill" or "Delete"), and its message comes from `confirmMessage()`.

**Every Delete route goes through `askDelete`:**
- the `D` key (`Card.qml:97-99`, `onDeleteRequested`);
- the trash button (`Card.qml:639`);
- the destroy column's Enter on a stopped session (`HerdrModel.qml:443`, which
  calls `removeSession` today).

`removeSession` stays as the action itself, and only `confirmPending` calls it.

### A failed delete says so

In `bin/herdr-sessions`, `cmd_delete` (`:815-823`) keeps herdr's error text
instead of discarding it:

```bash
local err
if ! err=$(herdr session delete "$name" 2>&1 >/dev/null); then
  die "herdr session delete failed: ${err:-no message from herdr}"
fi
printf '{"ok":true}\n'
```

`die` already prints the `{"ok":false,"error":…}` shape (`:51-52`). Remote
deletes run this same function over ssh, and `remote_action` passes the output
back unchanged (`:830-833`), so the remote path needs no change of its own.

**The widget shows action errors, which it doesn't do today.** `actionProc`
(`HerdrModel.qml:807`) has no stdout collector at all, so no action's failure
has ever been visible. The intent assumed otherwise, and the spec corrects that.
`actionProc` gains a `StdioCollector` whose output feeds a new
`property string actionError`: set from `data.error` when `ok` is false, and
cleared when an action succeeds or the panel reopens.

`Card.qml`'s warning line (`:205-221`) shows `actionError` when it isn't empty.
It doesn't reuse `errorText`, which is the list's reachability message: setting
it would wrongly mark herdr unreachable.

## Alternatives rejected

- **A second dialog for Delete.** The intent's constraint rules it out; one
  component, parameterised by the action.
- **Reusing `errorText` for action failures.** Wrong meaning: it drives
  `reachable`.
- **Confirming only from the trash button.** `D` and the destroy column are the
  same action, and a confirm with a shortcut around it isn't a confirm.

## Risks

- **Renaming `askKill`, `confirmKill` and `killMessage`** touches every caller.
  A grep for the old names must come up empty after the change; the test
  extracts the functions by name, so a missed one fails there.
- **Confirming a delete that fails** now shows an error where it used to show
  nothing. That's the point of the change.

## Verification

`tests/session-actions.cjs` gains three cases.

1. **Delete asks first:** extract `askDelete`, `confirmPending`, `closeConfirm`
   and `removeSession`. `askDelete(stopped)` must leave `actionProc.running`
   false and set `confirmOpen`. Then `confirmPending()` must run
   `herdr-sessions delete <name>`, and for a remote session
   `herdr-sessions --host <h> delete <name>`.
2. **Every Delete route goes through the confirm:** a source assertion that
   `Card.qml`'s `onDeleteRequested` and the trash button's `onClicked`, and
   `HerdrModel.qml`'s destroy-column branch, call `askDelete` and never
   `removeSession` directly.
   - **Red first:** on today's code this fails, because all three call
     `removeSession`.
3. **A failed delete says so:** run `bin/herdr-sessions delete demo` with a stub
   `herdr` first on `PATH` that prints `no such session` to stderr and exits 1.
   The output must be `ok:false`, with an error containing `no such session`.
   - **Red first:** today it prints `{"ok":true}`.

Case 1 on its own isn't a red-first proof: before the change it can only fail
with "missing function", which proves nothing. Case 2 is what pins today's
behaviour, and case 1 pins the new one.

`node tests/session-actions.cjs` prints PASS for every case.
