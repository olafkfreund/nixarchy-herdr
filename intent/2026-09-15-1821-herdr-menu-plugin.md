---
status: draft
issue: 1821
author: olafkfreund
---

# Intent: herdr menu plugin for Omarchy

Tracking issue: olafkfreund/nixos_config#1821

## Problem

Coding agents run inside herdr sessions on several machines, and reaching one
takes too many steps.

- The installed `jankeesvw.herdr` plugin is a bar widget. Nothing opens it from
  the keyboard, so reaching an agent means reaching for the mouse.
- It only sees herdr servers on the local machine. Sessions on razer are
  invisible from p620, and the way in is to SSH over and attach by hand.
- It can open, focus, kill and delete sessions, but not create one. A new
  session means dropping to a terminal and typing `herdr --session <name>`.
- Talking to an agent means finding its window and pane first. There is no way
  to hand an agent a short instruction from where you are.
- omarchy-ask shows the launcher-with-a-prompt shape that fits here, but its
  agents are separate throwaway ACP processes. They are not the agents already
  running in herdr.

## Proposed outcome

- A keybind opens a herdr menu in the Omarchy shell. It is fully usable from
  the keyboard and closes on Escape.
- The menu lists herdr sessions and the agents inside them, with each agent's
  state, for the local machine and every configured tailnet host. Hosts are
  grouped, and each is marked reachable or unreachable.
- Choosing an agent lands on that agent's pane in a window that is already
  showing its session. A new window, or a remote attach, opens only when no
  window shows that session. A herdr session is never created as a side effect
  of opening one.
- A new session can be created from the menu on a chosen host, with a name and
  a working directory.
- A short prompt can be sent to an existing herdr agent from the menu, and its
  reply is visible there.
- Everything `jankeesvw.herdr` does today keeps working: the bar badge, the
  attention ordering, kill with confirmation, delete of stopped sessions, and
  the pinned panel.
- The plugin is built in its own repository so it can grow in small steps,
  with hot reload during development.

## Affected users and systems

- User: olafkfreund, on the Omarchy session on p620 and razer.
- Hosts: p620 (primary, herdr 0.9.0), razer (herdr 0.9.0). p510 is on the
  tailnet but has no herdr today.
- Omarchy shell (Quickshell) plugin system: `~/.config/omarchy/plugins/`.
- Hyprland bindings: `~/.config/hypr/bindings.lua` on each host.
- `jankeesvw.herdr`, which this replaces on hosts that adopt it. It currently
  carries one local edit: the badge shows the blocked count first.
- nixos_config: runtime dependencies (`herdr`, `jq`, `foot`, `openssh`) on the
  hosts that get the plugin.

## Constraints

- Must follow the Omarchy Quattro plugin contract
  (<https://plugins.omarchy.org/develop.html>). It must pass
  `omarchy plugin validate` and `qmllint`, and contain no symlinks, so the
  plugin tree cannot be a Home Manager `home.file` symlink.
- Must run inside the shared shell process. It must never start a second
  Quickshell, and a slow or offline host must never freeze the shell or the menu.
- Remote access must go over existing SSH keys and the tailnet only. No
  interactive password prompts (BatchMode), no new listening ports, no
  credentials stored by the plugin.
- Must never start, stop or delete a herdr server on another machine without
  an explicit action in the menu. Killing a server keeps its confirmation.
- Must not persist agent output, prompts or titles to disk. That matches
  upstream's privacy stance.
- p510 changes (installing herdr, deploying anything) need explicit approval.
- MIT attribution to `jankeesvw/omarchy-herdr` must be kept.
- Agent prompting sends text to existing herdr agents only (option (a) from
  the design discussion). It does not spawn separate ACP agent processes.

## Open questions

1. Can one manifest declare several kinds (`menu`, `service`, `bar-widget`)?
   Or does the menu have to be the bar widget's panel, summoned by the
   keybind? Settled by `omarchy plugin validate` during the spec.
2. Which hosts go in the list: p620 and razer only, or p510 too, which would
   mean installing herdr there?
3. Should remote hosts be reached through plain `ssh <host> herdr ...`, or
   through herdr's own saved machines (`herdr machine add`, `--machine`)?
   The latter prepares the remote server when it is added.
4. Where does the repository live: a public fork `olafkfreund/omarchy-herdr`,
   a private repository, or local only for now? And should generally useful
   parts go back upstream as pull requests?
5. Which keybind chord opens the menu?
6. Should a prompt to an agent that is `working` or `blocked` be refused,
   queued, or sent after a confirmation?
