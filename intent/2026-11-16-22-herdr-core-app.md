---
status: approved
issue: 22
author: olafkfreund
---

# Intent: show herdr-core and herdr-app agents, one row per space

Closes #22. This is the third of four issues from the 2026-11-16 review.
#20 (robustness) and #21 (upstream sync) are merged, and #23 (UI pass) comes
after this.

Revision 2, after the Codex review (gpt-6.1-sol). The agy review was not
obtained: it hit its 10-minute print timeout.

## Problem

The plugin reads only the classic herdr TUI: `herdr session list` and
`herdr api snapshot`. Herdr now has two newer parts, both installed on p620:

- **herdr-core (`hc` 0.1.21)** keeps terminals and coding agents alive,
  whether or not any window shows them.
  - `hc events --json` gives a snapshot, then changes as they happen. A
    `missed` snapshot means it resynchronised, so it is not a lossless
    history.
  - Its schema says the listing and the events include connected machines'
    terminals, addressed as `machine/tN`. `hc machine ls` lists razer as
    connected.
- **herdr-app (0.1.16)** is the desktop window. It shows those terminals as
  spaces, tabs and panes.
  - `herdr-app ls` names the spaces and tabs, and gives each terminal's pane
    and status, but only while the window is open. Otherwise it fails
    ("connection refused").
  - `herdr-app do agent.focus --terminal tN` brings an agent into view.

**Not every terminal is an agent.** Observed on p620:

- A plain shell is `live` with `status: null` and `turn: 0`.
- A killed agent is `finished` with `status: null`. The snapshot keeps
  eleven finished terminals that `hc ls` hides.
- A sub-agent carries `parent` and `die_with_parent: true`.

So an agent, its state, and whether you have seen it need defining, not
assuming. In particular:

- a process that finished is not an agent whose work is `done`;
- `herdr.seen` exists but is not documented, and the spec has to establish
  what it means.

**What goes wrong:**

- **Agents in the app are invisible to the plugin.** One blocked on a
  question, or finished unseen, never reaches the badge or the menu. The bar
  can say nothing is wrong while an app agent waits on you.
- **That holds with the window closed as well.** The agents keep running in
  herdr-core.
- **You can't reach them from the menu.** You can't land on one, prompt it,
  interrupt it or end it.
- **A machine with herdr-core but no classic `herdr` gets no plugin at all.**
  `bin/herdr-sessions` requires `herdr` to run (`require_tools`, `:233`).

**What upstream did.** Upstream (jankeesvw/omarchy-herdr):

- `c22668d` added one "Desktop app" row for every app agent. It read both
  `hc ls` and `herdr-app ls`, using the app's status when the window is up.
  Its kill button stopped all of herdr-core.
- `83007e3` removed that kill again ("the desktop app is not stopped from
  here").
- `8634049` showed the row on machines without classic herdr.

On 2026-11-16 you chose a different shape: alongside the classic sessions, one
row per space.

## Proposed outcome

- **Every herdr-app space with at least one agent appears as its own row,**
  in the menu and the bar panel, next to the classic sessions.
  - Its agents are listed under it, with the same state words, colours and
    attention order as classic agents.
  - Spaces holding only plain shells, and finished terminals, are not shown as
    agents.
- **App agents count in the badge, the tooltip and the attention blink,**
  the same as classic ones.
  - A blocked app agent turns the badge red.
  - "done" means the agent reported `done` and you have not looked at it yet.
    It clears when you have. It never comes from a process merely having
    exited.
  - `error` gets its own word and colour instead of "unknown".
- **A change in an app agent's state reaches the badge within 2 seconds,**
  locally. Machines without herdr-core see no change in the bar's cost.
- **It works with the app window closed.**
  - The agents still show, under the space names hc's labels give.
  - Landing on one opens the window.
- **It works on a machine with herdr-core and no classic herdr.**
- **From an app agent's row you can:**
  - land on it in the window;
  - prompt it and see the reply;
  - interrupt its current turn;
  - end it, after a confirmation that names any sub-agents ending with it;
  - create a new space from an app row.
- **Ending an agent never ends unrelated work.**
  - Nothing in the plugin stops herdr-core or closes a whole space.
  - Only the agent you picked ends, along with its own sub-agents, which the
    confirmation names.
- **App agents on connected machines (razer) appear while the menu is open,**
  under their machine's name. None is counted twice.
- **Lost connections are shown, not hidden.** That covers the core, a remote
  machine and the window. The rows say so instead of going quiet.

## Affected users and systems

- **Users:** anyone running agents in the herdr desktop app, or through `hc`,
  including on hc machines.
- **Files:**
  - `HerdrModel.qml`: a second source, and the actions;
  - `Card.qml`: rows and labels;
  - `Menu.qml`: prompt and new space;
  - `bin/herdr-sessions`: the tool gate, and the actions;
  - the tests and the README.
- **Hosts:** p620 and razer, through the nixarchy pin bump.
- **Sessions:** the #2978 session is changing herdr-app and herdr-core on p620.
  The design is checked against the versions deployed when the spec is
  written.

## Constraints

- **Classic herdr support stays as it is,** and the two kinds sit side by
  side (decided 2026-11-16).
- **#20's guarantees carry over:**
  - every request has a deadline;
  - a long-lived subscription, if one is used, is watched and restarted
    instead;
  - failures are shown;
  - the cursor stays on an identity;
  - the confirm dialog acts on current state;
  - addresses and names are shape-checked before they reach a command line.
- **Never `hc server stop`, `space.close`, or anything else that ends work
  the user didn't pick.**
- **No new runtime dependency on hosts that don't have hc.**
- **Tests use fakes for `hc` and `herdr-app`.** No test touches the real core
  or window.

## Open questions

These are for the spec, which settles each against the deployed versions:

1. **What `herdr.seen` means,** and whether "done, not yet seen" can come from
   hc alone when the window is closed.
2. **Whether remote terminals really appear** in `hc ls` and `hc events`. The
   schema says yes, but no remote terminal was running when checked.
3. **The window's Hyprland class.** Upstream uses `herdr-app`; this needs
   confirming on p620.
4. **Agents without a space label,** such as background helpers.
   - Recommendation: a sub-agent shows under its parent; any other agent that
     reports a status goes in one "background" row. Plain shells are never
     shown.
5. **Where the hc calls run.**
   - Recommendation: a subscription in QML that is read line by line, not with
     `StdioCollector`, which waits for the stream to end.
   - Actions go through `bin/herdr-sessions`, for #20's deadlines and
     validation.
   - Also decide whether the bar and the menu share one subscription.
