---
status: draft
issue: 22
author: olafkfreund
---

# Intent: show herdr-core and herdr-app agents, one row per space

Closes #22. This is the third of four issues from the 2026-11-16 review.
#20 (robustness) and #21 (upstream sync) are merged, and #23 (UI pass) comes
after this.

## Problem

The plugin reads only the classic herdr TUI: `herdr session list` and
`herdr api snapshot`. Herdr now has two newer parts, both installed and
running on p620:

- **herdr-core (`hc` 0.1.21)** keeps terminals and coding agents alive. Each
  terminal reports its own status (`idle`, `working`, `done`, `blocked`,
  `error`) and turn count, and carries labels: `where` (`"nixos / Codex"`),
  `herdr.space`, `herdr.tab` and `herdr.seen`.
  - `hc events --json` gives a full snapshot, then every change as it
    happens.
  - `hc machine ls` already lists razer as a connected machine.
- **herdr-app (0.1.16)** is the desktop window. It shows those terminals as
  spaces, tabs and panes.
  - `herdr-app ls` names the spaces and tabs, and gives each terminal's pane
    and status.
  - `herdr-app do agent.focus --terminal tN` brings an agent into view.

**What goes wrong:**

- **Agents in the app are invisible to the plugin.** One that is blocked on
  a question, or has finished unseen, never reaches the badge or the menu.
  The bar can say nothing is wrong while an app agent is waiting on you.
- **You can't reach them from the menu.** You can't land on an app agent,
  prompt it, interrupt it or end it.

**What upstream did.** Upstream (jankeesvw/omarchy-herdr) added herdr-app
support in `c22668d`, `8634049` and `83007e3`:

- one "Desktop app" row holding every app agent, read by polling `hc ls`;
- its kill button runs `hc server stop`, which ends every terminal in the
  app at once.

On 2026-11-16 you chose a different shape: alongside the classic sessions, one
row per space.

## Proposed outcome

- **Every herdr-app space appears in the menu and the bar panel as its own
  row,** next to the classic herdr sessions. Its agents are listed under it,
  with the same state words, colours and attention order as classic agents.
- **App agents count in the badge, the tooltip and the attention blink,**
  the same as classic ones. A blocked app agent turns the badge red.
- **Changes show up promptly,** without the plugin polling herdr-core every
  few seconds.
- **From an app agent's row you can:**
  - land on it in the herdr-app window (opening the window if it's closed);
  - prompt it and see the reply;
  - interrupt its current turn;
  - end that one terminal, after confirming;
  - create a new space from an app row.
- **Ending an agent never ends anything else.** Nothing in the plugin stops
  herdr-core or closes a whole space.
- **App agents on other machines** (razer, through `hc machine ls`) appear
  while the menu is open, the way classic remote sessions do.
- **Machines without herdr-core or herdr-app see no change,** and the bar is
  not slowed by it.

## Affected users and systems

- **Users:** anyone running agents in the herdr desktop app, and anyone with
  hc machines.
- **Files:**
  - `HerdrModel.qml`: a second data source, and the actions;
  - `Card.qml`: rows and labels;
  - `Menu.qml`: prompt and new space;
  - `bin/herdr-sessions`: only if the hc calls go through it;
  - the tests and the README.
- **Hosts:** p620 and razer, through the nixarchy pin bump.
- **Sessions:** the #2978 session is changing herdr-app and herdr-core on p620
  (herdr-app 0.1.16, herdr-core 0.1.21). The design depends on their CLIs, so
  it is checked against the versions deployed when the spec is written.

## Constraints

- **Classic herdr support stays as it is.** The two kinds sit side by side
  (decided 2026-11-16).
- **#20's guarantees carry over to hc:**
  - every call has a deadline;
  - a failure is shown, not dropped;
  - the cursor stays tied to an identity;
  - the confirm dialog acts on current state;
  - addresses and names are shape-checked before they reach a command line.
- **Never `hc server stop`, `space.close` or anything else that ends more
  than the one terminal asked for.**
- **No new runtime dependency on hosts that don't have hc.**
- **Tests use fakes for `hc` and `herdr-app`.** No test touches the real core
  or window.
- **Remote hc machines are polled only while the menu is open,** as classic
  remotes are.

## Open questions

These are for the spec, which checks each against the deployed versions:

1. **What `herdr.seen` means.** `"1"` on a finished terminal looks like
   "focused since it last changed". Is it reliable enough to drive the green
   "done" state, or should done come from `herdr-app ls`?
2. **Remote terminals.** Do `hc ls` and `hc events` include razer's terminals,
   or does each machine need its own call (`--on razer`)?
3. **Window class.** What is herdr-app's Hyprland window class, so focus can
   raise the window?
4. **Agents without a space.** Background terminals have no `herdr.space`
   label: helpers, and sub-agents parked by the app. Show them, or not?
   - Recommendation: show only those reporting a status, under their
     parent's row or a "background" row.
5. **Where the hc calls run.** In QML `Process` objects directly, or as
   `bin/herdr-sessions` subcommands?
   - Recommendation: one long-running `hc events` in QML, and actions through
     the script, so they get #20's deadlines and validation in one place.
