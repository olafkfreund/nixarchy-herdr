---
status: approved
issue: 6
spec: spec/2026-09-24-6-review-fixes.md
---

# Plan: fixes from the September review

Closes #6. Branch `fix/6-review-fixes`, base `bed5fb2`.

## Approved decisions (from the spec)

**D1. Big inputs to jq go through pipes, not arguments.**

- `cmd_list`'s jq gets `$snapshots` and `$saved` through `--slurpfile
  snapshotsIn <(printf '%s' "$snapshots")` and `--slurpfile savedIn <(…)`.
  `$windows` and `$ghosts` go through `--rawfile windows <(…)` and `--rawfile
  ghosts <(…)`.
- The jq body starts with `($snapshotsIn[0]) as $snapshots | ($savedIn[0]) as
  $saved |`. The rest of the body doesn't change.
- `--argjson agentCap` stays as it is.
- `cmd_list_remote`'s `--arg windows` becomes `--rawfile windows <(…)`.
- No temp files. Upstream PR 13 is not used.

**D2. Local herdr calls time out.**

- Both `herdr … api snapshot` calls in `snapshot_for` run under `timeout 2`.
- `cmd_list`'s `herdr session list --json` runs under `timeout 4`.
- Neither needs a new error path: an empty answer already falls back or ends
  in `die`.

**D3. Every UI key includes the host.**

- In `HerdrModel.qml`, add `sessionKey(session)`, which returns `(session.host
  || "") + "\u0000" + session.name`.
- `pendingName` becomes `pendingKey`, set in `run()` and `newSession()`
  (through `sessionKey({host: host, name: name})`) and cleared where it is
  cleared today.
- `agentKey(session, pane)` returns `sessionKey(session) + "\u0000" + pane`.
- `updateAttention` passes the session object.
- `blinking(session, agent)` takes the session object instead of the name.
- In `Card.qml`, the dimming compares `panel.pendingKey ===
  panel.sessionKey(modelData)`, and the blink calls
  `panel.blinking(row.modelData, agentRow.modelData)`.

**D4. Kill and prompt report failure honestly.**

- **`cmd_kill`:**
  - If `kill -TERM` fails while `/proc/$pid` still exists, it calls `die "not
    allowed to stop that server"`.
  - After SIGKILL it polls `kill -0` up to 10 × 0.1 s. If the process is
    still alive, it calls `die "the server did not stop"`.
  - Only then does it print `{"ok":true}`.
- **`cmd_prompt`** keeps `rc` from `wait "$child"`:

  | `rc` | Result |
  | --- | --- |
  | 0 or 124 | The existing path |
  | 255, remote only | `die "$HOST is unreachable"` |
  | any other | Read the status as today, then `die` |

  For any other `rc`, the message depends on the status. If it is `blocked`:
  "the agent is waiting on a question; nothing was sent". Otherwise: "herdr
  did not start the prompt (agent is <status>)".
- The child stays a direct child, so TERM still reaches it.

**D5. Control characters are stripped from prompts.**

- The script runs `text=$(printf '%s' "$text" | tr -d
  '\000-\010\013-\037\177')` after the read. Tab and newline survive.
- `Menu.qml` strips `/[\u0080-\u009f]/g` before `promptProc.text = text`.

**D6. ssh doesn't inherit forwarding.** `ssh_options` adds `-o
ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o
PermitLocalCommand=no`. There is no `StrictHostKeyChecking` override.

**D7. The menu follows the screen.**

- `Menu.qml` sets:
  - `scaleH` to `targetScreen.height`, or 1080 when there is no screen
  - `textScale` to `clamp(1.6 × scaleH / 1080, 1.2, 2.4)`
  - `cardWidth` to `clamp(round(panel.width × 0.45), Style.space(560),
    Style.space(1400))`
- The card width becomes `min(cardWidth, panel.width - 2 × Style.gapsOut)`.
- `focusedScreen()` falls back to `screens[0]`.
- A comment above the new sizing properties explains the rule. (Correction
  2026-09-24: the plan cited a comment at `Menu.qml:19-21`, which does not
  exist; there was no sizing comment to update.)
- The bar dropdown and the pinned panel don't change.

**D8. The docs say what the code does.**

- README :189-190 says Kill and Delete both ask first.
- README :98-104 lists the confirm dialog for Kill, Delete and prompting a
  busy agent.
- The README says the menu's size follows the screen.
- `bin/herdr-menu-keys:30` gets "(asks first)", and `:42` becomes "Cancel or
  Kill / Delete / Send".

## Team

The work is done by an agent team, one teammate per file set. No two
teammates write the same file.

| Teammate | Owns | Steps |
| --- | --- | --- |
| script | `bin/herdr-sessions`, `tests/herdr-sessions.sh` (new) | S1–S6 |
| model | `HerdrModel.qml`, `Card.qml`, `tests/session-actions.cjs` | M1–M2 |
| menu | `Menu.qml` | U1–U2 |
| docs | `README.md`, `bin/herdr-menu-keys` | T1 |

- **Order:** all four start at once, because nothing depends across the sets.
  Within a set, steps run in order.
- **Commits:** each step is one commit, `fix(herdr): … (#6)`, with its test
  in the same commit. A commit must not stage another teammate's files.
- **Integration:** the lead runs the full Tests section on the branch at the
  end.
- **Deviations:** a deviation from this plan is edited into this file in the
  same commit as the code. The lead must agree to it first.

## Steps

### script

S1. **`tests/herdr-sessions.sh`: create the harness.**

- It runs with `set -u`, a temp `HOME` and `XDG_RUNTIME_DIR`, and a temp
  `bin/` first on `PATH`.
- It installs fake `herdr`, `ssh` and `hyprctl` scripts there. `hyprctl`
  prints `[]`.
- It installs no fake `ss`: the script's `ss` calls only serve kill.
- The fake `herdr` is driven by env vars that point into the temp directory:
  `FAKE_SNAPSHOT_BYTES`, `FAKE_SNAPSHOT_SLEEP`, `FAKE_PROMPT_RC`,
  `FAKE_AGENT_STATUS`, and `FAKE_LOG`, a file that records argv.
- Its `session list --json` prints one running session named `s1`.
- It exits 0 only if every case passes and prints `ok <case>` or `FAIL
  <case>`.

→ Verify: `bash tests/herdr-sessions.sh` runs, with no cases yet.

S2. **Case 1 is a 200 KB snapshot (D1).**

- Add the case: `bin/herdr-sessions list` with `FAKE_SNAPSHOT_BYTES=200000`
  must output JSON whose `.sessions[0].name == "s1"` and whose agents came
  from the snapshot.
- Run it first. It must fail with "unexpected output from herdr". Save that
  output for the PR.
- Then make the D1 change in `cmd_list` and `cmd_list_remote`.

→ Verify: case 1 passes, and `node tests/session-actions.cjs` still passes.

S3. **Case 2 is a stuck server (D2).**

- Add the case: `FAKE_SNAPSHOT_SLEEP=30`, and `list` must return within 8 s
  and still list `s1`. Wrap it in `timeout 20` so a failing run doesn't hang.
- Run it first. It must fail by exceeding 8 s.
- Then add the D2 timeouts.

→ Verify: case 2 passes.

S4. **Cases 3 and 4 are prompt refusal and control characters (D4 prompt,
D5 script).**

- Case 3: `FAKE_PROMPT_RC=1` with `FAKE_AGENT_STATUS=blocked`. `printf hi |
  bin/herdr-sessions prompt s1 w1:p1` must print `ok:false`, with an error
  containing "waiting on a question".
- Case 4: the prompt text `a\x1b[201~b\rc\x7fd` must reach the fake herdr, as
  `FAKE_LOG` records it, as `a[201~bcd`.
- Run both first; both must fail. Then make the D4 prompt change and the D5
  `tr`.

→ Verify: cases 3 and 4 pass, and case 1 still passes.

S5. **Case 5 is the ssh options (D6).**

- The fake `ssh` appends its argv to `FAKE_LOG` and prints nothing.
- `bin/herdr-sessions --host h1 list` fails with "unreachable", which is
  expected. `FAKE_LOG` must contain `ForwardAgent=no` and
  `PermitLocalCommand=no`.
- Run it first; it must fail. Then make the D6 change.

→ Verify: case 5 passes.

S6. **Kill (D4 kill).**

- Make the `cmd_kill` change.
- There is no automated test. The spec records why: a process that survives
  SIGKILL, or one owned by another user, can't be produced in a test run.

→ Verify: `bash -n bin/herdr-sessions` and `shellcheck bin/herdr-sessions`
show no new warnings. By hand: start a scratch session, `herdr session attach
zz6` in a spare terminal, then detach, run `bin/herdr-sessions kill zz6`, and
confirm `{"ok":true}` and that the server is gone. Record the result in the
PR.

### model

M1. **`tests/session-actions.cjs`: write the test first (D3).**

- Add `sessionKey`, `agentKey`, `blinking` and `updateAttention` to the
  extracted function list.
- Assertions:
  - `sessionKey({name:"3"}) !== sessionKey({name:"3", host:"razer"})`.
  - After `run()` on the local "3", `pendingKey` equals the local key and
    differs from the remote one.
  - With `attentionKey` set from a remote "3"/`w1:p1`,
    `blinking({name:"3", host:"razer"}, {pane:"w1:p1"})` is true and
    `blinking({name:"3"}, {pane:"w1:p1"})` is false.
- Run it first. It must fail, with `sessionKey` missing.

→ Verify: the red output is saved for the PR.

M2. **`HerdrModel.qml` and `Card.qml`: make the D3 change.**

- `grep -n pendingName *.qml` must return nothing afterwards. `Menu.qml` and
  `Panel.qml` don't use it today; confirm that.

→ Verify: `node tests/session-actions.cjs` passes all cases, old and new.

### menu

U1. **`Menu.qml`: make the D7 change and the fallback screen.**

- There is no test file change, because the model teammate owns
  `tests/session-actions.cjs`.
- Verify the arithmetic with a throwaway `node -e` that evaluates the
  two formulas for 768, 1080, 1440 and 2160 at `Style.space(n) = n`. It must
  match the table:

  | Screen height | Text scale | Card width |
  | --- | --- | --- |
  | 768 | 1.2 | 615 |
  | 1080 | 1.6 | 864 |
  | 1440 | 2.13 | 1152 |
  | 2160 | 2.4 | 1400 |

  The widths use real screen widths (1366, 1920, 2560, 3840). (Correction
  2026-09-24: an exact 16:9 width for 768 is 1365.33, which gives 614.)

→ Verify: the numbers match. `omarchy plugin validate .` passes.

U2. **`Menu.qml`: make the D5 QML strip.**

→ Verify: by reading the code; the line sits before `promptProc.text = text`.
At runtime: pasting text that contains U+0085 sends it without that
character.

### docs

T1. **`README.md` and `bin/herdr-menu-keys`: make the D8 change.**

→ Verify:

- `grep -n "only action" README.md` returns nothing.
- `bin/herdr-menu-keys` lists "asks first" for x.
- `bash -n bin/herdr-menu-keys` passes.

## Tests

Run on the branch after all teammates finish:

| Command | Expected |
| --- | --- |
| `bash -n bin/herdr-sessions bin/herdr-menu-keys` | Exit 0 |
| `shellcheck bin/herdr-sessions bin/herdr-menu-keys` | No warnings beyond the 4 already on `bed5fb2` (SC2174, SC2009, 2×SC2178) |
| `node tests/session-actions.cjs` | All cases pass |
| `bash tests/herdr-sessions.sh` | Cases 1–5 `ok`, exit 0 |
| `omarchy plugin validate .` | Passes |
| `git diff bed5fb2 --stat` | Only the owned files, plus this plan |

Then check these by hand after installing the plugin:

- The menu opens on each monitor with the D7 text scale.
- With the same session name on two hosts, only the row acted on dims or
  blinks.
- One prompt to an agent on p620 goes round trip.
- The step S6 kill check.

Record the results in the PR.

## Rollback

Every step is its own commit on `fix/6-review-fixes`, so `git revert <sha>`
undoes one fix without touching the others. Before merge, drop the branch.
After merge, revert the merge commit. Use a merge commit, not a squash, so the
approval commits stay on master. The plugin is loaded from the checkout, so a
revert takes effect when the shell reloads it. No data or state migrates.
