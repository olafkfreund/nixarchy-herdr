---
status: approved
issue: 11
spec: spec/2026-09-24-11-upstream-sync.md
---

# Plan: bring in upstream's tab names and theme status colours

Closes #11. Branch `feat/11-upstream-sync`. The base is master at `9c3a9fa`
plus this task's artifact commits. This ports upstream's `fab77b7`, `faf3d07`
and `c8f3c27`, merged upstream as `49fca4a`.

## Approved decisions (from the spec)

- **U1: tab names** (`bin/herdr-sessions`, `cmd_list` jq).
  - Next to `$wslabels`, build `$tablabels` from `$snap.tabs`, keyed by
    `tab_id`.
  - A label equal to `(.number | tostring)` becomes `""`.
  - Each `agentList` entry gets `tab: ($tablabels[.tab_id // ""] // "")`, next
    to `workspace:`.
  - `demo_list` agents gain `tab` values.
  - Remote hosts get this for free, because they run the same script.
- **U2: theme colours and place** (`HerdrModel.qml`).
  - Add `themeColor(key, fallback)`, which calls `Color.pick(key, "")`. It
    returns `Color.flatColor(value, fallback)` when that gives a value, and
    `fallback` otherwise.
  - `finished` becomes `themeColor("herdr.done", "#5FA46B")`.
  - `working` becomes `themeColor("herdr.working", "#D6A84B")`.
  - Add `workingForeground`, which is `themeColor("herdr.working",
    root.accent)`.
  - The three returns for a working state, `root.accent` at `:645`, `:676` and
    `:683`, become `root.workingForeground`.
  - Add `agentPlace(agent)`: the workspace and the tab, whichever exist,
    joined with `"  ·  "`, or `""` when there are none or `agent` is
    null.
  - Upstream's explanation comment comes with the code.
- **U3: the agent row** (`Card.qml`).
  - `:513` becomes `text: panel.agentPlace(agentRow.modelData)`, with
    upstream's comment wording.
  - The agent row's `Accessible.name` becomes `cleanTitle(title)`, then `", "
    + place` if the place isn't empty, then `", " + agentNote(status)`.
  - The existing elide and width stay.
- **U4: README and manifest.**
  - The README gets upstream's "Theme colours" section, adapted: the
    `[herdr]` keys, their fallbacks, and the `~/.config/omarchy/shell.toml`
    override.
  - It also gets the sentence on the place line, and credit to upstream PRs 9
    and 10.
  - `manifest.json` goes to version `0.4.0`.
- **U5: history.** The last commit on the branch is `git merge -s ours
  upstream/master`, which changes no file.
- **Accepted risk:** auto-titled tab labels are shown, as upstream does. Any
  follow-up waits until razer has been checked by eye.

## Team

The agents work in separate worktrees, each branched from
`feat/11-upstream-sync`. The lead cherry-picks their commits in this order:
script, model, ui, repo. Then the lead adds U5.

| Teammate | Owns | Steps |
| --- | --- | --- |
| script | `bin/herdr-sessions`, `tests/herdr-sessions.sh` | S1 |
| model | `HerdrModel.qml`, `tests/session-actions.cjs` | M1 |
| ui | `Card.qml` | C1 |
| repo | `README.md`, `manifest.json` | R1 |

- **Names are fixed here:** `tab`, `agentPlace` and `workingForeground`.
  Nobody depends on another teammate's commit being there first.
- **Deviations:** a teammate never edits this plan. A deviation goes to the
  lead, who records it here in the same commit as the code.

## Steps

S1. **script (U1). Test first.**

- In `tests/herdr-sessions.sh`, add case 12. The fake snapshot has
  `tabs: [{tab_id:"w1:t1",label:"review",number:1},
  {tab_id:"w1:t2",label:"2",number:2}]` and three agents:

  | Agent | `tab_id` | Expected `tab` |
  | --- | --- | --- |
  | 1 | `w1:t1` | `"review"` |
  | 2 | `w1:t2` | `""` |
  | 3 | none | `""` |

- Run it; it must fail, because `tab` is absent.
- Then make the U1 change, and add `tab` to `demo_list`.

→ Verify: cases 1–12 pass, and `shellcheck` on the three scripts is clean.

M1. **model (U2). Test first.**

- In `tests/session-actions.cjs`, extract `agentPlace` and `themeColor`.
- **`agentPlace`** must give:

  | Input | Result |
  | --- | --- |
  | `{workspace:"w", tab:"t"}` | `"w  ·  t"` |
  | `{workspace:"w"}` | `"w"` |
  | `{tab:"t"}` | `"t"` |
  | `{}` | `""` |
  | `null` | `""` |

- **`themeColor`**, with a `Color` stub in the context:
  - When `pick` returns `""`, the result is the fallback, and `flatColor` isn't
    called.
  - When `pick` returns `"accent"`, `flatColor("accent", fb)` is called and its
    result is returned.
- Run it; it must fail, because the functions are missing. Then make the U2
  changes.

→ Verify: every node case passes. `grep -n "return root.accent" HerdrModel.qml`
shows no return for a working state.

C1. **ui (U3).** Make the `Card.qml` changes.

→ Verify:

- By reading the code: `agentPlace` is used at the place line and in the
  accessible name.
- `node tests/session-actions.cjs` still passes, since some of its assertions
  read `Card.qml`.
- No QML runtime test exists; the look is checked on razer.

R1. **repo (U4).** Make the README and manifest changes. Take upstream's text
with `git show upstream/master:README.md`, and adapt it to the fork's voice.

→ Verify:

- `jq -e '.version=="0.4.0"' manifest.json`.
- `omarchy plugin validate .`.
- `grep -n "\[herdr\]" README.md` finds the section.

L1. **lead (U5).** After integrating S1, M1, C1 and R1 and running Tests:

```bash
git merge -s ours upstream/master -m "Record upstream 49fca4a as merged; ported in #11"
```

→ Verify:

- `git merge-base HEAD upstream/master` gives `49fca4a`.
- `git diff HEAD^1 HEAD --stat` is empty.

## Tests

| Command | Expected |
| --- | --- |
| `bash -n` on the 3 scripts | Exit 0 |
| `shellcheck` on the 3 scripts | No output |
| `node tests/session-actions.cjs` | All cases pass |
| `bash tests/herdr-sessions.sh` | Cases 1–12 `ok` |
| `omarchy plugin validate .` | Passes |
| CI on the PR | Green |

**On razer, after nixarchy is bumped:**

- A named tab shows `workspace · tab`.
- `[herdr] done = "#006800"` in `~/.config/omarchy/shell.toml` changes the
  done colour, and removing it restores the green.
- Check how auto-titled tab labels read.

## Rollback

Each step is its own commit, so `git revert <sha>` undoes one change. The U5
merge changes no file, so reverting it only changes history. After merge,
revert the PR's merge commit. Merge the PR with a merge commit, not a squash.
