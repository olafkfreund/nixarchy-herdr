---
status: approved
issue: 8
spec: spec/2026-09-24-8-review-followups.md
---

# Plan: follow-ups from the September review

Closes #8. Branch `fix/8-review-followups`, base `899f5d5` (master after
#7).

## Approved decisions (from the spec)

**F1. Window matching,** in `window_map` in `bin/herdr-sessions`.

- The jq over `hyprctl clients -j` keeps only PIDs with exactly one window:
  `[.[] | select(.pid > 0)] | group_by(.pid) | map(select(length == 1) |
  .[0]) | .[] | …`
- `ps -eo pid=,args= | grep -E 'her[d]r'` becomes `pgrep -af herdr`.
- In `session_in_args`, a word counts as herdr only if it is exactly `herdr`
  or ends in `/bin/herdr`.

**F2. Remote reads get size caps.**

- `cmd_new`'s polled `ssh_run "herdr session list --json"` gets `head -c
  $((SESSIONS_BYTE_CAP + 1))`.
- Both `agent get` reads in `cmd_prompt` get `head -c $((SNAPSHOT_BYTE_CAP +
  1))`.

**F3. Demo mode touches only its own file.** `private_dir` drops its two
`find` lines. It still creates the directory 0700, checks its owner and
refuses a symlink.

**F4. A cancelled remote prompt stops on the remote host.**

- The remote command runs the prompt in the background (`& p=$!`), then:
  - ignores SIGPIPE (`trap '' PIPE`)
  - loops while `kill -0 $p`: `printf '\n'`, and if that fails, `kill -TERM
    $p` and break; then `sleep 1`
  - ends with `wait "$p"`, so herdr's exit code comes back unchanged
- Not `ssh -tt`, and not watching the parent process.

**F5. No host polling while the menu is closed,** in `HerdrModel.qml`.

- `refresh()` returns before the host loop when `!remote || !opened`.
- The closed branch of `onOpenedChanged` sets `running = false` on every host
  poll.
- `applyHostPayload` returns at once when `remote && !opened`.

**F6. Confirm dialogs block clicks.** A `MouseArea` goes before the
`ConfirmDialog`, inside `confirmKeys`, in both `Card.qml` and `Menu.qml`. It
fills its parent, accepts all buttons, enables hover and accepts wheel
events.

**F7. Accessibility,** in `Card.qml`.

- **Session row:** `Accessible.role: Accessible.ListItem`; `Accessible.name:`
  `sessionLabel(modelData) + ", " + countLabel(modelData)`.
- **Agent row:** `Accessible.role: Accessible.ListItem`; `Accessible.name:`
  `cleanTitle(title) + ", " + agentNote(status)`.
- **Correction (2026-09-24, during U2):**
  - `sessionLabel()` already prefixes the host (`host · label`), so the
    planned `" on " + host` would have read the host twice.
  - `agentNote()` never returns `""`, so the `|| status` fallback could never
    fire.
  - Both are dropped.

**F8. CI** in `.github/workflows/ci.yml`.

- **Triggers:** push and pull_request, one job on ubuntu-latest.
- **Steps:**
  1. checkout
  2. `bash -n` on the three scripts
  3. `shellcheck` on them, default severity
  4. `node tests/session-actions.cjs`
  5. `bash tests/herdr-sessions.sh`
- **Warning fixes:**
  - SC2174: `mkdir -p` then `chmod`
  - SC2009: gone with F1
  - SC2178: `window_map`'s `seen` array becomes `emitted`
- No qmllint.

**F9. Licence, manifest and README.**

- `assets/LICENSE-herdr` is the verbatim herdrdev/herdr `LICENSE`.
- `herdr-mark.svg` gets a comment saying what was changed. `herdr-logo.svg`
  gets a comment with its source and licence, plus a list of changes if it
  differs from upstream.
- The README credit names `assets/LICENSE-herdr`.
- `manifest.json`: version `0.3.0`, and the new top-level description from
  the spec. `barWidget.description` doesn't change.
- README:
  - remote kill needs `ss`, `/proc`, `grep` and `awk`
  - the badge is bottom-right
  - there is a 5 s refresh while something is active
  - a note on F1's new-window behaviour for single-process terminals

## Team

The work is done by an agent team, one teammate per file set, each in its own
git worktree branched from `fix/8-review-followups`. The lead cherry-picks
their commits.

| Teammate | Owns | Steps |
| --- | --- | --- |
| script | `bin/herdr-sessions`, `tests/herdr-sessions.sh` | S1–S5 |
| model | `HerdrModel.qml`, `tests/session-actions.cjs` | M1 |
| ui | `Card.qml`, `Menu.qml` | U1–U2 |
| repo | `.github/workflows/ci.yml`, `manifest.json`, `assets/*`, `README.md` | R1–R3 |

- **Order:** all four start at once. Within a set, steps run in order.
- **Commits:** one per step, `fix(herdr): … (#8)` for code and `docs(herdr): …
  (#8)` or `ci: … (#8)` otherwise, with its test in the same commit.
- **Deviations:** a teammate never edits this plan. Deviations go to the
  lead, who records them here in the same commit as the code.

## Steps

### script

S1. **Window matching (F1). Tests 6–8 first.**

- `tests/herdr-sessions.sh`: the fake `hyprctl` answers `clients -j` from
  `FAKE_CLIENTS`, a JSON file in the temp dir. Each case starts a real
  background process, `bash -c 'sleep 30; :' <args>` (the `; :` keeps bash
  from exec-ing `sleep` and losing the args), and puts its PID in
  `FAKE_CLIENTS`.
  - **Case 6:** args `herdr --session s1`, with two windows for that PID. The
    output's `s1` has an empty `windowAddress`. Also assert that with one
    window it is set.
  - **Case 7:** `COLUMNS=40` exported, args `herdr --session s1
    --x<200 chars>`, one window. `windowAddress` is set.
  - **Case 8:** args `vim /tmp/src/herdr --session s1`, one window.
    `windowAddress` is empty.
  - Every case kills its background process in the harness's cleanup trap.
- Run the cases first. 6, 7 and 8 must fail. Then make the F1 changes.

→ Verify: cases 1–8 pass.

S2. **Remote read caps (F2). Test 11 first.**

- The fake `ssh` runs the remote command locally with `bash -c`. With
  `FAKE_AGENT_GET_BYTES=3000000`, the fake herdr's `agent get` prints that
  many bytes.
- `printf hi | bin/herdr-sessions --host h1 prompt s1 w1:p1` must exit within
  10 s with `ok:false`, printing under 64 KB.
- Run it first; it must fail. It either prints megabytes or hits the
  `SNAPSHOT_BYTE_CAP` path with no cap, whichever the failure is, recorded.
- Then add the two `head -c` caps, plus the one in `cmd_new`.

→ Verify: case 11 passes.

S3. **Demo mode (F3). Test 9 first.**

- Pre-create `$HOME/.cache/omarchy-herdr/keep/` and `…/keep.txt`, mode 644.
  Run `bin/herdr-sessions demo on`. Both still exist, and `keep.txt` is still
  644. Then run `demo off`.
- Run it first; it must fail. Then make the F3 change.

→ Verify: case 9 passes.

S4. **Remote prompt cancel (F4). Test 10 first.**

- The fake `ssh`, when `FAKE_SSH_PIPE=1`, runs the remote command with its
  stdout piped into `head -c 1 >/dev/null`, so the first heartbeat byte is
  read and then the reader exits.
  - That stands in for sshd closing the command's stdout.
  - The fake herdr's `agent prompt` sleeps 60 s and writes its PID to
    `FAKE_LOG`.
- Assert: within 5 s of starting `prompt` over `--host h1`, that PID no
  longer exists.
- Run it first; it must fail, because the prompt is still alive after 5 s.
- Then make the F4 change in `cmd_prompt`'s remote branch. Keep the existing
  `# shellcheck disable=SC2016` and `printf %q` construction style.

→ Verify: case 10 passes, and cases 3 and 4 from #6 still pass.

S5. **Shellcheck warnings (part of F8).**

- `private_dir`: `mkdir -p -- "$dir"`. The chmod 700 that follows already
  exists.
- `window_map`: rename the `seen` array to `emitted`.

→ Verify: `shellcheck bin/herdr-sessions bin/herdr-menu-keys
tests/herdr-sessions.sh` prints nothing and exits 0. `bash -n` passes. All
test cases pass.

### model

M1. **No polling while closed (F5). Test first.**

- `tests/session-actions.cjs`: extract `refresh` and `applyHostPayload`.
- **Case 1:** a context with `remote: true`, `opened: false`, `listProc: {
  running: true }`, and `hostPolls` where `count` is 1 and `objectAt()`
  returns a stub whose `start()` records a call. After `refresh()`, `start`
  wasn't called.
- **Case 2:** with `hostState: { h1: "ok" }`, `applyHostPayload("h1", "")`
  leaves `hostState.h1 === "ok"`.
- Give the context whatever `applyHostPayload` reads.
- Run first; both cases must fail. Then make the F5 changes, including
  stopping the polls in `onOpenedChanged`.

→ Verify: `node tests/session-actions.cjs` passes every case.

### ui

U1. **Confirm dialogs block clicks (F6),** in `Card.qml` and `Menu.qml`.

→ Verify: by reading the code. In each file the `MouseArea` is the first
child of `confirmKeys`, before `ConfirmDialog`. No automated QML test exists;
the runtime check is listed under Tests.

U2. **Accessibility (F7),** in `Card.qml`.

→ Verify: by reading the code. Both names use only helpers that exist in
`HerdrModel.qml`: `sessionLabel`, `countLabel`, `cleanTitle`, `agentNote`.
Check each with `grep -n "function <name>"`.

### repo

R1. **`.github/workflows/ci.yml` (F8).**

→ Verify: `python3 -c 'import yaml,sys;
yaml.safe_load(open(".github/workflows/ci.yml"))'` parses. Every command in
it is listed in the plan's Tests table. The run itself goes green on the PR,
which the lead checks after integration.

R2. **Licence (F9).**

- Fetch herdrdev/herdr's `LICENSE` with `gh api
  repos/herdrdev/herdr/contents/LICENSE --jq .content | base64 -d`, and write
  it to `assets/LICENSE-herdr`.
- Fetch upstream's logo file(s) the same way. Compare them with
  `assets/herdr-logo.svg` and `assets/herdr-mark.svg`, and write the comments
  from what actually differs.
- Update the README credit.

→ Verify:

- `head -3 assets/LICENSE-herdr` shows "Apache License".
- Both SVGs still start with `<svg` or an XML comment. Check with `python3 -c
  'import xml.dom.minidom as m; m.parse("assets/herdr-mark.svg")'` for each.

R3. **Manifest and README (F9).**

→ Verify:

- `jq -e '.version == "0.3.0"' manifest.json`.
- `omarchy plugin validate .` passes.
- `grep -n "top right" README.md` prints nothing.
- The README remote section mentions `ss`.

## Tests

The lead runs these on the integrated branch:

| Command | Expected |
| --- | --- |
| `bash -n bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh` | Exit 0 |
| `shellcheck bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh` | No output, exit 0 |
| `node tests/session-actions.cjs` | All cases pass |
| `bash tests/herdr-sessions.sh` | Cases 1–11 `ok`, exit 0 |
| `omarchy plugin validate .` | Passes |
| CI on the PR | Green |

Then check these by hand after the plugin is updated:

- **Kill confirm:** a click beside an open Kill confirm does nothing.
- **Screen reader:** orca reads a session row and an agent row.
- **F4 on p620:** send a long prompt, press Esc, and within 2 s `pgrep -af
  "agent prompt"` on p620 is empty.
- **The #7 checks still open:** kill, per-monitor size, two-host dim and
  blink, prompt round trip.

Record the results in the PR.

## Rollback

Each step is its own commit, so `git revert <sha>` undoes one change. After
merge, revert the merge commit. Merge with a merge commit, not a squash. If
CI misbehaves, deleting `.github/workflows/ci.yml` turns it off without
touching the code.
