---
status: draft
issue: 11
intent: intent/2026-09-24-11-upstream-sync.md
---

# Spec: bring in upstream's tab names and theme status colours

## Design

This ports upstream's `fab77b7`, `faf3d07` and `c8f3c27` (merged as
`49fca4a`) into the fork's layout. Upstream's model code is in `Panel.qml`;
the fork's is in `HerdrModel.qml`. Behaviour follows upstream exactly unless
a decision below says otherwise.

### U1. The tab name reaches each agent (`bin/herdr-sessions`)

In `cmd_list`'s jq, next to `$wslabels` (`:461-466`), build `$tablabels`
from the snapshot's tabs with upstream's rule:

```jq
| (($snap.tabs // [])
   | map({key: (.tab_id // ""),
          value: (if (.label // "") == ((.number // "") | tostring)
                  then "" else (.label // "") end)})
   | from_entries) as $tablabels
```

- **Each `agentList` entry** gains `tab: ($tablabels[.tab_id // ""] // "")`,
  beside `workspace:` at `:483`.
- **Snapshot fields.** The shape was checked against a live herdr 0.9.1
  snapshot: `.tabs[]` has `tab_id`, `label` and `number`, and each agent has a
  `tab_id`.
- **Unnamed tabs.** A tab nobody named has its number as its label, and joins
  as `""`.
- **Remote hosts** run this same script, so remote rows get `tab` with no
  other change.
- **Demo data** (`demo_list`) gains `tab` values, the way upstream's demo lines
  do.

### U2. Theme colours, and where an agent sits (`HerdrModel.qml`)

Upstream's code, placed where the fork keeps it:

```qml
function themeColor(key, fallback) {
  var value = Color.pick(key, "")
  return value ? Color.flatColor(value, fallback) : fallback
}
readonly property color finished: themeColor("herdr.done", "#5FA46B")        // was :52
readonly property color working: themeColor("herdr.working", "#D6A84B")      // was :56
readonly property color workingForeground: themeColor("herdr.working", root.accent)

function agentPlace(agent) {
  if (!agent) return ""
  var parts = []
  if (agent.workspace) parts.push(agent.workspace)
  if (agent.tab) parts.push(agent.tab)
  return parts.join("  ·  ")
}
```

- **The working foreground.** The three `root.accent` returns for a working
  state (`:645`, `:676`, `:683`) become `root.workingForeground`. Blocked keeps
  the theme's urgent colour.
- **The shell's colour helpers exist.** `Color.pick` and `Color.flatColor`
  were checked in the running shell (`Commons/Color.qml:30`, `:51`).
- **Upstream's explanation** is carried over with the code, in the comment
  above `finished`: why there's a fallback, and why `flatColor` is used.

### U3. The agent row shows its place (`Card.qml`)

- **`:513`**, `text: agentRow.modelData.workspace || ""`, becomes `text:
  panel.agentPlace(agentRow.modelData)`. The comment above it gets upstream's
  wording: "its workspace, then its tab".
- **The accessible name** from #8 becomes:
  - `cleanTitle(title)`,
  - then `", " + agentPlace(...)` when that isn't empty,
  - then `", " + agentNote(status)`.

  A screen reader then hears what the row shows.
- **Width is already handled.** The place line keeps its existing elide and
  width rule, which upstream's comment relies on: "never what pushes the
  title out".

### U4. README and manifest

- **README:**
  - Upstream's "Theme colours" section, adapted: the `[herdr]` keys, their
    fallbacks, and that `~/.config/omarchy/shell.toml` overrides the theme.
  - Upstream's sentence on the place line.
  - The credit line names upstream's PRs 9 and 10.
- **`manifest.json`:** `version` becomes `0.4.0`.

### U5. History records upstream as merged

As the last commit before the PR, the lead runs:

```bash
git merge -s ours upstream/master -m "Record upstream 49fca4a as merged; ported in #11"
```

It changes no file. `git merge-base master upstream/master` then says
`49fca4a`, so the next sync's diff starts there.

### Ownership

| Teammate | Files | Designs |
| --- | --- | --- |
| script | `bin/herdr-sessions`, `tests/herdr-sessions.sh` | U1 |
| model | `HerdrModel.qml`, `tests/session-actions.cjs` | U2 |
| ui | `Card.qml` | U3 |
| repo | `README.md`, `manifest.json` | U4 |
| lead | history | U5 |

- **Interfaces between teammates:**
  - `agentList[].tab`, from script, is read by `agentPlace` in model.
  - `agentPlace` and `workingForeground`, from model, are read by `Card.qml`
    in ui.
- **Names are fixed here** so the teammates can work at once. Each commit
  stands alone: `agentPlace` handles a missing `tab`, and Card works once
  model's commit is in. The lead integrates model before ui.

## Alternatives rejected

- **`git merge upstream/master` and resolving the conflicts.** It would pull
  in upstream's `Panel.qml` structure, which the fork deliberately left, and
  its `cmd_list`, which #6 and #8 rewrote. Every hunk would be hand-resolved
  anyway, and resolving conflicts hides decisions that a port writes down.
- **Cherry-picking upstream's commits.** Same conflicts, one commit at a time.
- **Filtering auto-titled tab labels,** such as `"1 · claude › yes continue"`,
  which the herdr-auto-title plugin produces. That would be new behaviour
  upstream doesn't have. See Risks.
- **Leaving history alone.** Rejected at intent approval.

## Risks

- **Auto-titled tabs make long place lines.** On p620 today a tab's label is
  `"1 · claude › yes continue"`. It isn't equal to its number, so upstream's
  rule shows it. The place line then repeats roughly what the agent's title
  says. The existing elide keeps the width in check, but the text is noisy.
  Accepted as upstream behaviour; if it reads badly on razer, a follow-up can
  drop a label that starts with `"<number> · "`.
- **A theme sets a colour that reads badly on the panel.** This is the
  theme's choice, as upstream documents. Themes that don't set the keys are
  unchanged.
- **`Color.pick` can't read dotted keys on an older shell.** It then returns
  `""`, the fallback applies, and today's colours hold. There's no failure
  mode.
- **Colours can't be tested by a script here.** There's no QML runtime in the
  tests. The function is checked with a stub (see Verification), and the look
  on razer.

## Verification

- **`tests/herdr-sessions.sh`, case 12, which fails first:** the fake
  snapshot has three agents.

  | Agent | Tab | Expected `tab` |
  | --- | --- | --- |
  | 1 | named `review` | `"review"` |
  | 2 | label `"2"` and number 2 | `""` |
  | 3 | no `tab_id` | `""` |

- **`tests/session-actions.cjs`, new cases, which fail first:**
  - **`agentPlace`** gives:

    | Input | Result |
    | --- | --- |
    | `{workspace:"w", tab:"t"}` | `"w  ·  t"` |
    | `{workspace:"w"}` | `"w"` |
    | `{tab:"t"}` | `"t"` |
    | `{}` | `""` |
    | `null` | `""` |

  - **`themeColor`**, with a `Color` stub:
    - `pick` returning `""` gives the fallback.
    - `pick` returning `"accent"` passes it to `flatColor`, with the fallback.
- **Checks:** `shellcheck` on the 3 scripts is clean, `bash -n` passes, `omarchy
  plugin validate .` passes, and CI is green.
- **`git merge-base master upstream/master`** is `49fca4a` after U5.
- **On razer, by hand:**
  - A named tab shows `workspace · tab`.
  - Setting `[herdr] done = "#006800"` in `~/.config/omarchy/shell.toml`
    changes the done colour.
  - Removing it restores the green.
