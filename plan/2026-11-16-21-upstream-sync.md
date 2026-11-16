---
status: draft
issue: 21
spec: spec/2026-11-16-21-upstream-sync.md
coders:
  1: codex   # small, tricky bash: the umask subshell must keep #20's launcher check and the tests' fakes intact
  2: coder   # Panel.qml containment change, well specified
  3: coder   # version and one README sentence
reviewers:
  - codex  # reads the Panel.qml step it did not write
  - agy    # reads the bash step; give it only this plan and the diff of bin/ and tests/
---

# Plan: bring in upstream's umask and new-shell badge fixes

Closes #21 on branch `fix/21-upstream-sync`.

**Prerequisite: PR #24 (#20) is merged.**

- Before step 1, the lead rebases this branch onto the new `master`.
- Line numbers below that refer to #20's code are given by function name,
  because #20 moves them.

## Approved decisions (copied from the spec, so this plan stands alone)

- **U1: umask (`73b6605`).**
  - `bin/herdr-sessions` records the starting umask before setting its own:

    ```bash
    INHERITED_UMASK=$(umask)
    readonly INHERITED_UMASK
    umask 077
    ```

    It is two statements because of shellcheck SC2155.
  - In `show_session` (#20's version), the launch line
    `without_herdr_env "${launch[@]}" >/dev/null 2>&1 &` becomes:

    ```bash
    ( umask "$INHERITED_UMASK" && without_herdr_env "${launch[@]}" ) >/dev/null 2>&1 &
    ```

  - **No `exec`:** `without_herdr_env` is a function, and `exec` of a function
    fails with 127.
  - `pid=$!`, `sleep 0.3`, `kill -0`, `wait` and `disown` stay as #20 has them.
  - Checked on p620: `uwsm-app` defaults to a scope, which inherits the
    caller's umask. With `UWSM_APP_UNIT_TYPE=service` it would not; the README
    says so in one line.
  - The script's own files stay under 077: the cache, the demo flag and the run
    directory.
- **U2: bar content (`b00a6ca`).** In `Panel.qml`'s `BarIconButton` (`:175-260`
  on master):
  - remove `opticalSize: root.barContentWidth`;
  - replace `iconComponent: Component { Item { … } }` with
    `hasVisualContent: true` plus the same `Item` as a direct child, with
    `anchors.fill: parent` and `scale: button.pressScale`;
  - add a one-line comment on why it isn't an `iconComponent`. The why: the
    shell hands `iconComponent` to `BarIconContent`, which scales the whole
    content to one icon by its bounds, so the badge shrank with the glyph.
    The comment may name `iconComponent`;
  - change nothing else in the artwork: the mark, the `MultiEffect` tint, the
    badge's anchors, ratios, colours, rim, count text and visibility.
- **U3: history.**
  - The branch's last commit is `git merge -s ours b00a6ca`, after the rebase.
  - Its message lists all eight non-merge commits in `49fca4a..b00a6ca`:

    | Commit | How it was handled |
    |---|---|
    | `73b6605` | ported (U1) |
    | `b00a6ca` | ported (U2) |
    | `4513202` | covered by #19 (`affd985`) |
    | `b4dceeb` | covered by the fork's jq file inputs and #20 |
    | `43e61b5` | covered by #20 D7 (`d8a1d25`) |
    | `d0df5ea`, `448fdd1`, `ff66115` | skipped on purpose (remotes stay on `herdr.json` + ssh) |

- **U4: version and docs.**
  - `manifest.json` goes to `1.0.2`.
  - The README gains one sentence where a session is opened: the terminal gets
    the umask the panel was started with (a scope launch, uwsm's default).
  - The badge paragraph is left to #23.

## Repo traps (apply to every step)

- **The script is piped to remote hosts as `bash -s`.** It stays
  self-contained, needing only bash, jq, herdr, ss, grep, awk, timeout and
  /proc.
- **CI runs shellcheck.** New code passes it, or carries a one-line
  `# shellcheck disable=` with a reason.
- **Tests never launch a real terminal, herdr, ssh or hyprctl.**
  - The fakes for `foot` and `xdg-terminal-exec` (one shared `FAKE_FOOT_RC`
    knob), `setsid` and `uwsm-app` are in `tests/herdr-sessions.sh`.
  - Any fake process a test starts is killed by the test.
- **Every QML `Text` keeps `textFormat: Text.PlainText`.**
- **Implementers never stage, commit, push or switch branches.**

## Steps

1. **`bin/herdr-sessions` and `tests/herdr-sessions.sh`: U1.**
   - **Script:**
     - Add the two `INHERITED_UMASK` lines before `umask 077` (`:39`).
     - Change the launch line in `show_session` as above.
     - Add a one-line comment saying why the umask is restored for the launch
       only.
   - **Tests:** both terminal fakes, `foot` and `xdg-terminal-exec`, change
     the same way:
     - they log `umask-seen $(umask)` and `term-pid $$` to `FAKE_LOG` first;
     - then, with `FAKE_TERM_SLEEP` set, they `exec sleep "$FAKE_TERM_SLEEP"`;
     - otherwise they exit with `FAKE_FOOT_RC`.

     The test kills the logged PID afterwards. `show_session` disowns the
     launcher, so the script returns before the fake ends.
     - Under `umask 022`, `open s1` logs `umask-seen 0022`, through the
       `uwsm-app` fake as well.
     - `FAKE_TERM_SLEEP=1` (alive past the 0.3 s check) gives `ok:true` and
       the inherited umask. The test kills it afterwards.
     - `FAKE_FOOT_RC=1` still gives `the terminal exited at once`, and
       `FAKE_FOOT_RC=0` still gives `ok:true` (#20's cases).
     - Under `umask 022`:
       - `demo on` creates the cache directory with mode 700, and a demo file
         with no group or other bits;
       - the run directory is mode 700 while a slow fake list runs.

   Verify:

   ```bash
   for f in bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh; do bash -n "$f"; done
   shellcheck bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh
   bash tests/herdr-sessions.sh
   ```

   Traps:
   - No `exec` before the function.
   - Keep `pid=$!` on the line after the launch.

2. **`Panel.qml`: U2.** The `BarIconButton { id: button … }` block (`:175-260`
   on master):
   - remove `opticalSize`;
   - turn the `iconComponent` wrapper into a direct child `Item`, adding
     `anchors.fill: parent` and `scale: button.pressScale`;
   - add `hasVisualContent: true` and the comment.

   Verify:

   ```bash
   ! grep -nE '^\s*(iconComponent|opticalSize)\s*:' Panel.qml   # no such property left; comments may name it
   grep -n 'hasVisualContent: true' Panel.qml
   grep -n 'scale: button.pressScale' Panel.qml
   omarchy plugin validate .
   node tests/session-actions.cjs
   ```

   Limit: `validate` does not type-check QML against the shell, so a typo in
   the new properties shows up only in step 5's live check (the shell log).

   Traps:
   - `button` is the `BarIconButton`'s id.
   - The artwork keeps referring to `root.*` and `herd.*` exactly as now.

3. **`manifest.json` and `README.md`: U4.**
   - Set `"version": "1.0.2"`.
   - Add one sentence to the "What it does" first bullet, after the launcher
     check sentence #20 added: the terminal gets the umask the panel was
     started with. That holds for uwsm's default scope launch, not
     `UWSM_APP_UNIT_TYPE=service`.

   - Location: the spec names the "Opening a session" text. Since #20, the
     launch behaviour is described in the "What it does" first bullet, so the
     sentence goes there, next to the launcher check sentence.
   - The badge paragraph (`README.md:137-141`) stays untouched.

   Verify:

   ```bash
   jq -e '.version == "1.0.2"' manifest.json
   git diff master -- README.md   # one added sentence; the badge paragraph is unchanged
   omarchy plugin validate .
   ```

4. **Lead: commit, record the history, then the full check.**
   - **Commit first.** After each of steps 1-3, the lead reviews the diff
     against that step and commits it. Before the merge, `git status
     --porcelain` must print nothing.
   - **Record the history and check it:**

     ```bash
     git fetch upstream
     git merge -s ours b00a6ca -m "<U3 table>"
     git rev-parse HEAD^2 | grep -q "^$(git rev-parse b00a6ca)"   # second parent is b00a6ca
     [ "$(git rev-parse HEAD^{tree})" = "$(git rev-parse HEAD^1^{tree})" ]   # no file changed
     for c in 73b6605 b00a6ca 4513202 b4dceeb 43e61b5 d0df5ea 448fdd1 ff66115; do
       git log -1 --format=%B | grep -q "$c" || echo "missing $c"; done   # all eight named
     git log --reverse HEAD..83007e3 --no-merges --format=%h   # c22668d 8634049 83007e3
     ```

   - **The PR is merged with a merge commit** (`gh pr merge --merge`). A squash
     or rebase would drop `b00a6ca` from master's history, and a fast-forward
     would leave the empty `-s ours` merge as master's tip.
   - **Fixes from review go before the history merge.** Any fix from the
     reviews is committed before the `-s ours` merge, which is then redone so
     it stays the last commit.

   Then the Tests below, push, and a PR that links the intent, spec and plan.

5. **Lead, after merge: live check.**
   - **Prerequisites, done outside this repo:**
     - the nixarchy flake's pin of this plugin is bumped;
     - p620 is deployed, with the owner's OK, announced on the agent bus;
     - the owner, or the lead with that OK, does both.
     - Evidence before the check starts: the deployed store path under
       `~/.config/omarchy/plugins/nixarchy.herdr` contains `manifest.json`
       with version `1.0.2`.
   - **On p620** (Omarchy edge-20261116):
     - the badge is readable at normal size in four states: blocked, done,
       working, and a two-digit count;
     - it disappears when everything is idle;
     - hover, click and middle click work;
     - the press animation still shrinks the icon;
     - the open-panel indicator shows;
     - the bar works in both horizontal and vertical layouts.
   - **On razer:** the same badge check on its shell.
   - **A session opened from the menu:** `umask` in its terminal prints the
     shell's umask.

## Tests

```bash
for f in bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh; do bash -n "$f"; done
shellcheck bin/herdr-sessions bin/herdr-menu-keys tests/herdr-sessions.sh
bash tests/herdr-sessions.sh      # #20's cases plus ~6 new, all ok
node tests/session-actions.cjs    # unchanged, all PASS
omarchy plugin validate .
```

## Review

- **Opus:** a fresh agent on `model: "opus"` gets this plan,
  `git diff master...fix/21-upstream-sync`, and
  `git show --stat HEAD` / `git log -3 --format=%H%n%P%n%B` for the U3 merge.
- **codex:** this plan and the `Panel.qml` diff; it may open `Panel.qml` in
  full (for `id: button`).
- **agy:** this plan plus the diff of `bin/` and `tests/` only, kept narrow so
  it fits inside its print timeout.
- **Context:** codex and agy may also open the changed files in full in the
  repo, for surrounding code.

## Rollback

- **Before merge:** delete the branch.
- **After merge:** `git revert -m 1 <merge commit>`. The `-s ours` merge
  changes no file, so reverting the PR's merge removes U1, U2 and U4.
  `b00a6ca` stays in master's history; that only records upstream as
  handled.
- **No state migration.**
