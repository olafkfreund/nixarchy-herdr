---
status: approved
issue: 4
spec: spec/2026-09-19-4-delete-confirm.md
---

# Plan: deleting a session asks first, and a failed delete says so

## Approved decisions (from the spec)

- **One dialog, two actions.** `killTarget` becomes `confirmTarget`, beside a
  new `confirmAction` (`"kill"` or `"delete"`). `askKill` keeps its shape and
  sets `"kill"`; a new `askDelete` takes `removeSession`'s guards (not the
  default session, not running, a valid name) and sets `"delete"`.
  `confirmKill` becomes `confirmPending`, `closeKill` becomes `closeConfirm`,
  `killMessage` becomes `confirmMessage`. Cancel stays the default.
- **Every Delete route goes through `askDelete`:** the `D` key
  (`Card.qml:97-99`), the trash button (`Card.qml:639`) and the destroy
  column's Enter on a stopped session (`HerdrModel.qml:443`). `removeSession`
  stays the action, called only by `confirmPending`.
- **A failed delete reports herdr's own message.** `cmd_delete`
  (`bin/herdr-sessions:815-823`) drops `|| true`, keeps stderr and calls `die`,
  which already prints `{"ok":false,"error":…}`. Remote deletes run the same
  function over ssh, so that path needs no change.
- **The panel can show action errors at all.** `actionProc`
  (`HerdrModel.qml:807`) has no stdout collector today, so no action failure
  has ever been visible. It gains one, feeding a new `actionError`, shown on
  `Card.qml`'s warning line (`:205-221`). It must not reuse `errorText`, which
  drives `reachable`.

## Steps

1. `tests/session-actions.cjs`: add case 2 from the spec, the source
   assertion. Assert that `Card.qml`'s `onDeleteRequested` body and the trash
   button's `onClicked`, and `HerdrModel.qml`'s destroy-column `else` branch,
   each mention `askDelete` and none of them calls `removeSession` directly.
   → Verify by running it **before** step 2: `node tests/session-actions.cjs`
   must fail, because all three call `removeSession` today. Capture that output
   for the PR (§1). This case, not case 1, is the red-first proof: case 1 could
   only fail with "missing function", which proves nothing.
2. `HerdrModel.qml`: rename `killTarget` → `confirmTarget`, `closeKill` →
   `closeConfirm`, `confirmKill` → `confirmPending`, `killMessage` →
   `confirmMessage`; add `confirmAction` and `askDelete`; make
   `confirmPending` dispatch to `killSession` or `removeSession`; point the
   destroy column's `else` at `askDelete`.
   → Verify with `grep -rn 'killTarget\|closeKill\|confirmKill\|killMessage'`
   over `*.qml`, which must print nothing.
3. `Card.qml`: `onDeleteRequested` and the trash button call `askDelete`; the
   dialog's `confirmText` follows `confirmAction` ("Kill" or "Delete") and its
   message comes from `confirmMessage()`.
   → Verify with `node tests/session-actions.cjs`: case 2 now passes.
4. `tests/session-actions.cjs`: add case 1, the behaviour case. Extract
   `askDelete`, `confirmPending`, `closeConfirm` and `removeSession`;
   `askDelete(stopped)` must leave `actionProc.running` false and set
   `confirmOpen`; `confirmPending()` must then run
   `herdr-sessions delete <name>`, and for a remote session
   `herdr-sessions --host <h> delete <name>`.
   → Verify with `node tests/session-actions.cjs`.
5. `bin/herdr-sessions`: `cmd_delete` keeps herdr's stderr and calls `die` on
   failure, exactly as the spec writes it.
   → Verify with case 3 (next step).
6. `tests/session-actions.cjs`: add case 3. Run `bin/herdr-sessions delete demo`
   with a stub `herdr` first on `PATH` that prints `no such session` to stderr
   and exits 1; the output must be `ok:false` with an error containing
   `no such session`.
   → Verify by writing the case **before** step 5 if the order allows, or by
   reverting step 5 once: it must print `{"ok":true}` (red), then `ok:false`
   (green). Capture the red output.
7. `HerdrModel.qml` and `Card.qml`: give `actionProc` a `StdioCollector`, set
   `actionError` from `data.error` when `ok` is false, clear it on success and
   when the panel reopens, and show it on the warning line.
   → Verify by hand in a live session: delete a session whose herdr call fails
   (a stub `herdr` first on `PATH`), and the panel shows the message. Say in
   the PR that this is the only by-hand check, since the test harness runs the
   QML functions outside a shell.
8. `README.md`: one line in the keys section, that Delete now asks first.
   → Verify by reading it.
9. Open the PR: `Closes #4`, links to the intent, spec and plan, and the red
   output from steps 1 and 6.

## Tests

| Command | Expected | Its §1 break |
|---|---|---|
| `node tests/session-actions.cjs` | PASS for every case, old and new | before step 3: case 2 fails, the three routes call `removeSession` |
| the same, case 3 | `ok:false` carrying herdr's message | before step 5: `{"ok":true}` |
| `grep -rn 'killTarget\|closeKill\|confirmKill\|killMessage' *.qml` | no output | a missed rename prints a line, and the harness then fails on a missing function |
| by hand: a failing delete in a live panel | the warning line shows herdr's error | — (untestable in the harness; named in the PR) |

## Rollback

Revert the commits. The rename is contained in `HerdrModel.qml` and `Card.qml`,
and `cmd_delete`'s change is three lines. Nothing persists between runs: no
state file, no config key, so a revert restores today's behaviour exactly,
including the unconfirmed Delete.
