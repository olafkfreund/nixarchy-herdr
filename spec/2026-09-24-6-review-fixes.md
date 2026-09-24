---
status: approved
issue: 6
intent: intent/2026-09-24-6-review-fixes.md
---

# Spec: fixes from the September review

## Design

Every change is the smallest one that removes the cause. Each change sits in
one file, so each file has one owner on the implementation team (see
"Ownership").

### D1. Large payloads reach jq through file descriptors, not argv

In `cmd_list` (`bin/herdr-sessions:429-434`), the four variable-size inputs
move off the command line. `$agentCap` is a small integer and stays as it is.

```bash
jq -c --slurpfile snapshotsIn <(printf '%s' "$snapshots") \
      --slurpfile savedIn     <(printf '%s' "$saved") \
      --rawfile   windows     <(printf '%s' "$windows") \
      --rawfile   ghosts      <(printf '%s' "$ghosts") \
      --argjson   agentCap    "$AGENT_COUNT_CAP" '
  ($snapshotsIn[0]) as $snapshots | ($savedIn[0]) as $saved | ...existing body...'
```

- **`--slurpfile` wraps its input in an array**, so the body gets `$snapshots`
  and `$saved` back through `[0]` and otherwise stays the same.
- **`--rawfile` keeps `$windows` and `$ghosts` as strings,** exactly as `--arg`
  did.
- **`cmd_list_remote` (`:518`)** gets the same change for `--arg windows`.
- **Process substitution uses `/dev/fd` pipes,** so nothing touches disk. That
  keeps the README's "nothing is written to disk" promise.
- **The remote side needs nothing new.** It runs this same script under bash,
  which has process substitution.

### D2. Local herdr calls get a timeout

- **`snapshot_for`** (`:335`, `:337`): `timeout 2 herdr … api snapshot`. It
  already returns 1 on empty output. A snapshot that times out falls back to
  what `session.json` remembers, the same as a server that never answered.
- **`cmd_list`'s `herdr session list --json`** (`:349`): `timeout 4`. A timeout
  there ends in the existing `die "could not reach herdr"`.
- The action commands (`open`, `focus`, `new`, `kill`, `delete`) are not in
  scope. Nothing runs them every 3 seconds.

Ceiling: one poll takes at most 4 s plus 2 s per session. The existing
`SESSION_COUNT_CAP` bounds that. `# ponytail:` note: if many stuck servers
ever matter, the fix is running the snapshots in parallel.

### D3. Session and agent keys include the host

In `HerdrModel.qml`:

- **New helper:** `function sessionKey(session) { return (session.host || "")
  + "\u0000" + session.name }`.
- **`pendingName` becomes `pendingKey`,** set to `sessionKey(session)` in
  `run()` (`:233`), to `sessionKey({host: host, name: name})` in `newSession()`
  (`:565`), and to `""` where it is cleared today (`:843`).
- **`agentKey(session, pane)`** returns `sessionKey(session) + "\u0000" +
  pane`.
- **`updateAttention`** (`:722`) passes the session object.
- **`blinking(session, agent)`** (`:740`) takes the session object instead of
  its name.

In `Card.qml`, two call sites change:

- **`:256`:** `opacity: panel.pendingKey === panel.sessionKey(modelData) ? 0.4
  : 1`.
- **`:475`:** `panel.blinking(row.modelData, agentRow.modelData)`.

A local session has no host (`undefined` or `""`), so its key starts with an
empty host and can never equal a remote one's.

### D4. Kill and prompt report failure honestly

**`cmd_kill`**

- If `kill -TERM` fails and `/proc/$pid` still exists, `die "not allowed to
  stop that server"`.
- After the existing TERM wait and SIGKILL, poll `kill -0` up to 10 × 0.1 s.
  If the process is still there, `die "the server did not stop"`.
- Only when it is gone does it print `{"ok":true}`.

**`cmd_prompt`** uses the prompt's exit code, `rc`, which it already gets from
`wait "$child"`. herdr 0.9.1 exits 1 with `{"error":{"code":…}}` when it
refuses (checked against a session that doesn't exist).

| `rc` | Meaning | Result |
| --- | --- | --- |
| 0 | Sent | Existing path |
| 124 | Our `timeout` | Existing path; status comes back as `timeout` |
| 255, remote only | ssh failed | `die "$HOST is unreachable"` |
| any other | herdr refused | Read the agent's status as today, then `die` (below) |

- **The agent is `blocked`:** "the agent is waiting on a question; nothing was
  sent".
- **Any other status:** "herdr did not start the prompt (agent is
  <status>)".

The menu already shows `ok:false` errors under the line (`Menu.qml` prompt
handler), so it needs no new UI.

Rejected: capturing herdr's JSON error text. The child has to stay a direct
child so a TERM reaches it (comment at `:717-720`). Capturing its stdout would
need a FIFO or a coprocess, and the exit code carries enough.

### D5. Control characters are stripped from the prompt

- **Script:** right after `text=$(head -c 16384)`, run
  `text=$(printf '%s' "$text" | tr -d '\000-\010\013-\037\177')`. That keeps
  tab and newline and removes ESC, CR and DEL. The script is the trust
  boundary, and remote hosts run this same code.
- **`Menu.qml`,** before `promptProc.text = text` (`:170`): `text =
  text.replace(/[\u0080-\u009f]/g, "")`. These C1 characters are multi-byte in
  UTF-8, so `tr` can't remove them safely.

### D6. ssh stops inheriting forwarding

Add to `SSH_OPTS` in `ssh_options` (`:138`): `-o ForwardAgent=no -o
ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no`. Options
given with `-o` on the command line override `~/.ssh/config`.

Rejected: `StrictHostKeyChecking=yes`. BatchMode already fails closed on
unknown keys unless the user chose `accept-new` or `no` on purpose, and
overriding that would break their existing setup.

### D7. The menu follows the screen

In `Menu.qml`, `scaleH` is the height of the screen the menu opens on, in
logical pixels. Hyprland already divides a monitor's size by its scale factor,
so a 4K monitor at scale 2 counts as 1080.

```qml
readonly property real scaleH: root.targetScreen ? root.targetScreen.height : 1080
readonly property real textScale: Math.max(1.2, Math.min(2.4, 1.6 * scaleH / 1080))
readonly property int cardWidth: Math.max(Style.space(560),
                                          Math.min(Style.space(1400), Math.round(panel.width * 0.45)))
```

- **Width at `:272`** becomes `Math.min(root.cardWidth, panel.width -
  Style.gapsOut * 2)`, so a narrow screen can never overflow.
- **The theme still applies.** `Style.font.*` and `Style.space()` already
  carry the theme's font size and spacing, and the screen factor multiplies
  them.

| Screen, logical | Text scale | Card width |
| --- | --- | --- |
| 1366×768 | 1.2 | 615 |
| 1920×1080 | 1.6 | 864 |
| 2560×1440 | 2.13 | 1152 |
| 3840×2160 at scale 1 | 2.4 | 1400 |

The card widths assume `Style.space(n)` = n, which is the theme default.
This replaces the fixed `textScale: 1.6` and `cardWidth: Style.space(760)`
approved as a deviation in plan 1821. Update the comment at `Menu.qml:19-21`
to match.

**Fallback screen:** `focusedScreen()` (`:53`) returns `screens.length > 0 ?
screens[0] : null` instead of `null`.

The bar dropdown and the pinned panel are unchanged. They keep `textScale`
1.0 from `HerdrModel.qml:21`.

### D8. Docs match the code

- **README :189-190:** Kill and Delete both ask first.
- **README :98-104:** the confirm dialog covers Kill, Delete and prompting a
  busy agent.
- **`bin/herdr-menu-keys:30`:** "x → Delete a stopped session (asks first)".
- **`bin/herdr-menu-keys:42`:** "Cancel or Kill / Delete / Send".
- **README scaling section:** the menu's size follows the screen it opens on.

### Ownership (one teammate per file set, no shared files)

| Teammate | Files | Designs |
| --- | --- | --- |
| script | `bin/herdr-sessions`, new `tests/herdr-sessions.sh` | D1, D2, D4, D5 (script part), D6 |
| model | `HerdrModel.qml`, `Card.qml`, `tests/session-actions.cjs` | D3 |
| menu | `Menu.qml` | D5 (QML part), D7 |
| docs | `README.md`, `bin/herdr-menu-keys` | D8 |

The four sets don't touch each other's files. The one interface between them
is `Menu.qml` reading `ok:false` errors from `cmd_prompt`, and that JSON shape
doesn't change.

## Alternatives rejected

- **Upstream PR 13 (temp files for jq):** it writes agent titles to disk,
  breaking the README promise, and its `trap RETURN` leaks the temp directory
  when `die` exits.
- **Piping the snapshots to jq on stdin:** stdin already carries
  `$sessions_json`, and combining the two would mean rewriting the jq program.
- **A `menu.scale` setting in `herdr.json`:** the intent approval kept the
  screen-relative rule. A setting can be added later if the rule falls short.
- **Scaling the bar dropdown too:** it lives in the bar, whose size the theme
  already sets.
- **`StrictHostKeyChecking=yes`, and capturing herdr's error JSON:** see D6
  and D4.

## Risks

- **D1: process substitution on the remote bash.** A host whose `bash` lacks
  `/dev/fd` would fail. Linux has it everywhere. Verify on p620 and razer.
- **D2: a slow but healthy server.** One that is busy for more than 2 s has
  its row fall back to saved data for that poll. The effect is cosmetic, and
  the next poll catches up.
- **D4: exit codes vary with herdr's version.** The exit-code mapping assumes
  herdr ≥ 0.9.1 semantics. On an older herdr a non-zero exit is still a
  failure, so the worst case is a less specific message.
- **D4: testing a kill that fails.** A process that survives SIGKILL, or one
  that belongs to another user, can't be produced in a test run as the same
  user. The escalation path is tested (a fake server that ignores TERM). The
  "did not stop" and "not allowed" paths are verified by review only. This falls short of the intent's
  constraint that every fix has a test that fails first.
- **D7: fonts on a 4K screen at scale 1.** Text at 2.4× may look large to
  someone used to the old size. The clamp is the knob to tune; the numbers
  sit in two `readonly` properties.
- **D5: multi-line prompts.** Newline is kept on purpose, since the input line
  is single-line today.

## Verification

- `bash -n bin/*` and `shellcheck bin/*` show no new warnings.
- `node tests/session-actions.cjs` passes, including new cases:
  - local and remote sessions both named "3" get different
    `sessionKey`/`pendingKey`/`agentKey` values
  - `blinking()` lights only the right one
- The new `tests/herdr-sessions.sh` runs with fake `herdr` and `ssh` first on
  PATH in a temp HOME, and checks:
  1. `list` with a 200 KB snapshot returns the session. This fails before D1.
  2. `list` with a snapshot that sleeps 30 s returns within 8 s and still
     lists the session.
  3. `prompt` when the fake `agent prompt` exits 1 and `agent get` says
     `blocked` returns `ok:false` with the "waiting on a question" error.
  4. `prompt` text containing ESC, CR and DEL reaches the fake herdr without
     them.
  5. `--host h list` makes the fake `ssh` see `ForwardAgent=no`.
  6. `kill` against a fake herdr server that ignores TERM still ends with
     `ok:true`, and the process is gone.
- `omarchy plugin validate .` passes.
- Runtime, by hand, after install:
  - The menu opens on each monitor, with the text scale from the D7 table.
  - A two-host setup with the same session name dims and blinks only the row
    acted on.
  - One remote prompt round trip works on p620.
