---
status: draft
issue: 21
intent: intent/2026-11-16-21-upstream-sync.md
---

# Spec: bring in upstream's umask and new-shell badge fixes

Implements the approved intent. Already resolved there: record the sync with
`git merge -s ours b00a6ca` after #20 merges.

Line numbers are on `origin/master` `affd985`. Where #20 (PR #24) changes the
same code, the #20 version is named, because implementation starts after #24
merges.

## Design

### U1. The opened terminal gets the caller's umask (`73b6605`)

**Checked on p620:** `uwsm app` defaults to `-t scope`.

```text
( umask 077; uwsm-app -- sh -c umask )   # prints 0077
( umask 022; uwsm-app -- sh -c umask )   # prints 0022
```

So the terminal inherits the umask of whoever launches it, through uwsm as
well. Restoring it at the launch reaches the terminal on this machine too. It
would not reach it with `UWSM_APP_UNIT_TYPE=service`, which is unset here; the
README says so in one line.

- **Keep the starting umask.** `bin/herdr-sessions` records it before setting
  its own (`:39`):

  ```bash
  INHERITED_UMASK=$(umask)
  readonly INHERITED_UMASK
  umask 077
  ```

  It is two statements because shellcheck SC2155 flags
  `readonly X=$(...)`.
- **Restore it for the launch only.**
  - The launch in `show_session` (`:624` on master; on #20 the line with
    `without_herdr_env "${launch[@]}" … &`, followed by `pid=$!`) becomes:

    ```bash
    ( umask "$INHERITED_UMASK" && exec without_herdr_env "${launch[@]}" ) >/dev/null 2>&1 &
    ```

  - `exec` keeps the subshell's PID as the launcher's PID, so #20's 0.3 s
    launcher check and `disown "$pid"` work unchanged.
- **The rest stays private.** The cache directory, the demo flag and #20's run
  directory are created by the script under 077. #20's `run_dir_init` also
  sets `umask 077` in its own subshell.
- **Remote hosts are unchanged.** There the launch is local (`herdr --remote`
  runs on this machine), and the remote server's umask is that host's own.

### U2. The bar content sits in the button, not in `iconComponent` (`b00a6ca`)

`BarIconButton` (Omarchy shell `Ui/BarIconButton.qml:84-90`) hands
`iconComponent` to `BarIconContent`. That item scales its content to
`Style.bar.iconSize` from the content's bounds (`BarIconContent.qml:9-10`), so
the glyph and the badge shrink together.

- **`Panel.qml` changes as upstream did** (`:175-260`):
  - remove `opticalSize: root.barContentWidth` (`:181`);
  - replace `iconComponent: Component { Item { … } }` (`:184`) with
    `hasVisualContent: true` and the same `Item { anchors.fill: parent; … }`
    as a direct child of the button;
  - add upstream's one-line comment on why.
- **What stays as it is:**
  - the herdr mark (`Image` + `MultiEffect`, tinted `root.barForeground`);
  - the badge: anchors, ratios, `herd.badgeColor()`, the rim in
    `Commons.Color.bar.background`;
  - the count: `herd.blockedCount > 0 ? herd.blockedCount : herd.runningCount`;
  - the visibility rule (`reachable && runningCount > 0 && badgeActive`).
- **Upstream differs only in content:** its glyph is a font `Text` and its
  badge sits top-right. Only the containment change is ported.
- **Bar sizing is unchanged.** `barContentWidth` (`:109`) still sizes the slot
  and the open-panel indicator (`:115-118`).

### U3. Upstream history

The last commit on the branch is `git merge -s ours b00a6ca`, as #11 did
(`440a513`). It changes no file. Its message lists, for each of the eight
non-merge commits in `49fca4a..b00a6ca`, how it was handled:

| Commit | How it was handled |
|---|---|
| `73b6605` | ported here (U1) |
| `b00a6ca` | ported here (U2) |
| `4513202` | covered by #19 (`affd985`) |
| `b4dceeb` | covered by the fork's jq file inputs and #20 (prompt screen on stdin) |
| `43e61b5` | covered by #20 D7 (`d8a1d25`) |
| `d0df5ea`, `448fdd1`, `ff66115` | skipped on purpose; remotes stay on `herdr.json` + ssh (2026-11-16) |

After it:

- `git log HEAD..upstream/master --no-merges` lists only `c22668d`, `8634049`
  and `83007e3` (herdr-app, for #22).
- The branch is rebased onto master after #24 merges, so `43e61b5`'s and
  `b4dceeb`'s coverage is really in the tree when they are recorded.

### U4. Version and docs

- `manifest.json` goes to `1.0.2`, one past #20's `1.0.1`.
- **README:**
  - The badge paragraph (`:137-141`) says "the number of running servers". It
    already misstates the blocked count, which is #23's to fix, so it is not
    touched here.
  - The "Opening a session" text gains one sentence: the terminal gets the
    umask the panel was started with (scope launches, uwsm's default).

## Alternatives rejected

- **Keep `iconComponent` and size the content so the scaling does nothing:**
  `BarIconContent` scales by the content's bounds whatever their size, so it
  would fight every shell update. Upstream moved the content out for the same
  reason.
- **Read the umask in QML and pass it in:** the script already knows its
  starting umask, and passing it would add an argument and a validation for
  nothing.
- **`git merge upstream/master`:** that would bring in the herdr-app commits,
  which are #22's to design.
- **Starting before #24 merges:** both change `show_session`'s launch line, so
  that would conflict for nothing.

## Risks

- **Older Omarchy shells:** if razer runs a shell from before the iconComponent
  scaling, the direct-child form renders as it did before upstream's change
  (upstream's own commit says so). That is checked live on razer.
- **Hover and click:** the content `Item` has no `MouseArea`, so the button's
  own input handling underneath still gets every event. Checked live.
- **A shell launched with `umask 077`:** then the terminal gets 077 too, which
  is the caller's choice. The README sentence says "the umask the panel was
  started with".

## Verification

**Tests** (`tests/herdr-sessions.sh`, fakes only):

- **Umask reaches the launch.** Run the script under `umask 022`, with the fake
  terminal logging `umask` to `FAKE_LOG`, then `open` a session: the log says
  `0022`.
- **The same through `uwsm-app`:** the fake `uwsm-app` execs, and the result is
  the same.
- **The script stays private.** Under `umask 022`, `demo on` still creates the
  cache directory with mode 700, and the demo file with no group or other
  bits.
- **#20's launcher-check cases still pass.** The PID passed to the check is
  still the launcher's.

**Static checks:**

- `omarchy plugin validate .`
- `node tests/session-actions.cjs`
- `bash -n` on each script, and shellcheck
- `grep -n iconComponent Panel.qml` returns nothing.

**History:**

- `git merge-base --is-ancestor b00a6ca HEAD` exits 0.
- `git log HEAD..upstream/master --no-merges --format=%h` prints exactly
  `c22668d`, `8634049` and `83007e3`.

**Live, after merge**, with the pin bump and p620 deploy (owner's OK) and
razer:

- The badge is readable at normal size on p620 (Omarchy edge-20261116) in four
  states: blocked (red), done (green), working (amber), and a two-digit count.
  It disappears when everything is idle.
- Hover, click and middle click on the bar button still work.
- On razer, same check on its shell.
- A session opened from the menu: `umask` in its terminal prints the shell's
  umask (normally `0022`).
