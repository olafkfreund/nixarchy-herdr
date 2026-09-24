<p align="center"><img src="assets/herdr-logo.svg" alt="herdr logo" width="96" /></p>

# Herdr for Nixarchy

Your [herdr](https://herdr.dev) sessions and the coding agents inside them, on
a keybind, in the Omarchy shell. Across machines, not just this one.

- **`SUPER + SHIFT + H`** opens a menu of every session and agent, here and on
  the hosts you list, and lands you on an agent's pane without starting a new
  session.
- **`n`** creates a session, locally or on another host.
- **`a`** sends a short prompt to an agent and shows its answer, without
  leaving what you are doing.
- **The bar icon** keeps the count and the attention colours of the original
  widget.

Built on [jankeesvw/omarchy-herdr](https://github.com/jankeesvw/omarchy-herdr)
(MIT), which is where the bar widget, its states and its pinned panel come
from. The herdr logo is from [herdrdev/herdr](https://github.com/herdrdev/herdr)
(Apache-2.0) and is used to identify herdr.

Herdr runs one server per named session. They are easy to start and they never
stop by themselves, because closing a window detaches rather than ends the
session. So they pile up unseen, on more than one machine.

![The Herdr panel open on a desktop, listing four sessions with the agents inside each](assets/screenshot.png)

## The menu

`SUPER + SHIFT + H` opens it on the screen you are working on, and the same
chord or `Esc` closes it. Its size and text follow that screen: text grows
with the screen's height, and the card takes a bit under half its width, within
set limits. It lists this machine's sessions first, then each
host in `~/.config/omarchy/herdr.json`, with every remote row named
`host · session`. The title line says how each host answered: `●` something
running, `○` nothing running, `–` no answer.

Every key is listed under [Keybindings](#keybindings).

**Landing on an agent** focuses its pane inside the server and then the window
already showing that session. A new window opens only when none shows it: a
local `herdr --session`, or `herdr --remote host --session` for another
machine.

**Prompting** goes to the agent that was under the cursor when you pressed
`a`. An agent that is working, waiting on a question, or unreadable asks
before the text is sent, because it would arrive in the middle of what the
agent is doing. The answer appears under the line: only the reply, without the
agent's footer or the conversation before it.

**Other hosts** are polled only while the menu is open, over ssh, and a host
that does not answer never delays the rest. Nothing is installed on them.

## Keybindings

### Opening

| Key | Does |
| --- | --- |
| `SUPER + SHIFT + H` | Open the menu on the screen you are using; press again to close |
| Click the bar icon | Open the dropdown panel (this machine's sessions only) |
| Middle-click the bar icon | Refresh the bar counts |

### In the menu and the dropdown panel

| Key | Does |
| --- | --- |
| `↓` / `j` | Next row |
| `↑` / `k` | Previous row |
| `→` / `l` | Move across a row to its buttons (open, then kill or delete) |
| `←` / `h` | Move back towards the row |
| `Tab` / `Shift+Tab` | Cycle through the row's buttons |
| `Enter` / `Space` | Jump to the agent, open the session, or press the button you are on |
| `o` | Open the session under the cursor |
| `K` (Shift+k) | Kill that session's server; asks first, with Cancel selected |
| `x` | Delete a stopped session; asks first, with Cancel selected |
| `r` | Refresh |
| `Esc` | Close |

Menu only:

| Key | Does |
| --- | --- |
| `n` | New session on the host under the cursor: `name` or `name /absolute/dir` |
| `a` | Prompt the agent under the cursor |

Dropdown panel only:

| Key | Does |
| --- | --- |
| `p` | Pin the panel to the desktop, or unpin it |

### In the input line (after `n` or `a`)

| Key | Does |
| --- | --- |
| `Enter` | Create the session, or send the prompt; the answer shows below |
| `Esc` | Close the line, and stop waiting on a prompt that is still running |

### In a confirm dialog (kill, delete, or prompting a busy agent)

| Key | Does |
| --- | --- |
| `←` / `→` | Choose between Cancel and Kill, Delete or Send |
| `Enter` | Confirm the highlighted choice; it opens on Cancel |
| `Esc` | Cancel |

Kill is `K`, not `k`: Omarchy's shared key handler takes lowercase `k` as
"up" before the menu sees it.

### In Omarchy's menus

`SUPER + SHIFT + H` appears in Omarchy's **Keybindings** menu under the
description given in `bindings.lua`. The keys above only exist while the menu
has the keyboard, so they are not Hyprland bindings, and binding them would
take those letters from every window. Instead, `bin/herdr-menu-keys` shows
them as a searchable sheet, the way Omarchy's **Learn → Herdr** and
**Learn → Tmux** sheets work. Add it to the Learn menu in
`~/.config/omarchy/extensions/omarchy-menu.jsonc`, next to any rows already
there:

```jsonc
"learn.herdr-plugin-keybindings": {
  "icon": "",
  "label": "Herdr plugin",
  "action": "~/.config/omarchy/plugins/nixarchy.herdr/bin/herdr-menu-keys"
}
```

`bin/herdr-menu-keys --print` prints the same list in a terminal.

## What it shows

The bar carries the number of running servers, on a badge sitting in the top
right corner of the icon. It turns red when an agent is blocked and waiting on
an answer, green when work finished while you were looking elsewhere, and amber
while something is still running. When every agent is idle there is nothing to
say, so the badge goes away and the icon stands on its own.

Each row in the panel is one session:

- its name, in bold when a window is already showing it
- the projects open inside it, taken from the workspace labels
- how many agents it holds, and what the most urgent of them is up to
- what every one of those agents is doing, from its terminal title, with its
  own status dot beside it. All of them, however many and wherever herdr keeps
  them: a pane in a second tab counts the same as one sitting in front of you.
  Each of those lines is its own way in
- a dot in the session's colour, taking the state of its loudest agent

## The states

Herdr classifies every agent, and two of those states are the reason to look
at all:

| | | |
|---|---|---|
| **needs you** | red | herdr recognised an approval or a question on screen: that agent is waiting on an answer |
| **done** | green | it finished work you have not seen yet. Focusing the tab turns it back into plain idle |
| working | accent | busy |
| idle | grey | ready for input, and already seen |

Every agent line carries its state as a word, right-aligned in one column down
the edge of the panel, so what the herd is doing is a single glance rather than
a scan. The agents inside a session are ordered by that state rather than by
where they happen to sit - what wants an answer first, then what finished
unseen, then what is busy, then what is only waiting for you to type. That is
herdr's own attention queue, the order its agent panel takes when
`agent_panel_sort = "priority"`. `idle` is written as **ready**, because it is the ordinary resting
state and "idle" reads like a fault.

Both **needs you** and **done** are written bold and in colour, along with the title beside them, and their whole row is washed in that colour: red for a question, green for work that finished. **working** and **ready** stay quiet, because a panel where every line is coloured is a panel where colour means nothing. A dot is something you have to be looking at; a row of colour is something you catch out of the corner of your eye, which is how a pinned panel is read at all. The badge in the bar takes the same colour, so a herd that wants something says so with the panel closed.

Waiting beats finished beats busy, wherever a session has to be summed up in
one colour.

## What it does

- **Click a row** (or `Enter`, or `o`) to open that session. A session shows at
  most one window, because two windows on one session mirror each other, so
  this focuses the window it already has, wherever it is, and only opens a new
  one when there is none. Without a window one is started, in foot.
- **Click one of the agent lines** to land on that agent rather than on
  whatever the session was last showing: its pane is focused inside the server
  first, then the window comes up. That also marks a finished agent as seen, so
  clicking the line that says **done** is what clears it.
- **The skull** (or `K`) ends that server, and is the only way it is ended from
  here. It asks first, and the dialog opens on **Cancel** rather than on the
  confirming side: a dialog that destroys something on a reflexive Enter is
  worse than no dialog, because it trains the reflex. Kill and delete stop to
  ask; opening and focusing do not, because they are recoverable or trivial
  and these two are not. `herdr session stop` asks over herdr's own socket, so a server too
  wedged to read that socket never hears the request and the button looks
  broken at exactly the moment you needed it. This signals the process instead:
  TERM first, and KILL a second later if that was not enough. The shared
  session is killed like any other, because it wedges like any other.
- **The bin** (or `x`) throws away a session that is already stopped - the
  directory and the state herdr kept in it - which is what clears it out of the
  list for good. It takes the same slot as the skull, because a session is
  never both running and stopped. It asks first, like the skull: the two share
  that slot, so a reflexive Enter lands on whichever the row happens to offer,
  and what herdr kept for the session does not come back. The shared session is
  herdr's own and is never deleted from here.
- **`r`** refreshes, and so does a middle click on the bar button.
- **`a`** and **`n`** do nothing in the bar panel; they belong to the menu.
- **The pin** (or `p`) takes the panel out of the bar and leaves it on the
  desktop. See below.

`K` rather than upstream's `k`, and `x` now works: Omarchy's shared key handler
takes `k` as "up" and turns `x` into its own delete signal before a panel sees
either, so the original shortcuts never fired.

A row marked **stopped** is a session whose server is not running. The session
itself still exists on disk, under `~/.config/herdr/sessions/<name>/`, which is
why it stays in the list: clicking it starts that server back up, and the bin
throws the session away for good. There is nothing to kill there, so the skull
gives way to the bin.

What survives the server is the layout - herdr keeps it in `session.json` - so
a stopped row still names the workspaces it was holding and the directories
they were opened in, the same names a running session shows. That is the
difference between a session worth starting back up and a name left over from
an afternoon, and it is not something the word "stopped" can tell you. A row
that saved nothing worth naming says **nothing saved**.

The list refreshes every three seconds while the panel is open and every twenty
seconds when it is closed.

## Pinning it

A dropdown is something you open to answer a question and close again. A herd you are running is something you glance at all afternoon, and a panel that shuts the moment you touch anything else cannot be glanced at. So the panel can come loose: click the pin in its header, or press `p`, and the same card carries on as a window of its own, on every workspace, above whatever you are working in, and still one click away from any agent in it.

- **Drag it by the six dots** in the header. Only that strip moves it. The rest of the card is rows and buttons, and those were click targets before the pin existed.
- **Resize it from the corner**, bottom right. A height you set is a height the list lives inside from then on, so the panel keeps the shape you gave it and scrolls rather than growing and shrinking every time an agent turns up or finishes.
- **It remembers where you put it.** Unpinning puts the card back under the bar button; pinning again brings it back to the same place at the same size, because that spot was a decision about your own desktop and re-deciding it on every pin is the panel forgetting something you told it. The first time, with nothing to remember, it opens in the bottom left corner, clear of the bar.
- **The bar button still shows and hides it**, and `Escape` hides it too. Neither of those unpins: only the pin does that.
- **It wears the accent border only while it has the keyboard**, the way every other window on the desktop does. A card that says "focused" all day is saying nothing at all, in the loudest colour the theme has.
- **A pin belongs to one screen.** Every monitor's bar carries its own copy of this widget, so the pinned card appears on the screen you pinned it from and nowhere else.

Position, size and screen are kept in this widget's own entry in `~/.config/omarchy/shell.json`, the same entry the bar's settings screen reads, so there is no config file of its own to keep track of:

```json
{ "id": "nixarchy.herdr", "pinned": true, "pinScreen": "DP-3", "pinX": 54, "pinY": 1404, "pinW": 420, "pinH": 240 }
```

## Screenshots

It follows the theme, so it reads the same on a light one:

![The same panel on a light theme, with every status colour still legible](assets/screenshot-light.png)

The data script has a demo mode, so a screenshot never carries real project
names or agent titles and looks the same in a year:

```bash
bin/herdr-sessions demo on
# ... take the screenshot ...
bin/herdr-sessions demo off
```

Every write is a no-op while it is on, so a click during a shoot cannot kill a
real server.

## Installing it

```bash
git clone https://github.com/olafkfreund/nixarchy-herdr ~/.config/omarchy/plugins/nixarchy.herdr
omarchy plugin enable nixarchy.herdr
omarchy bar move nixarchy.herdr --section right
```

`omarchy plugin add <git-url>` works as well. If `jankeesvw.herdr` is
installed, disable it: both put an icon in the bar.

Add the keybind to `~/.config/hypr/bindings.lua` and reload Hyprland:

```lua
o.bind("SUPER + SHIFT + H", "Herdr sessions menu", "omarchy-shell shell toggle nixarchy.herdr '{}'")
```

```bash
hyprctl reload
```

List other machines, by the names your `~/.ssh/config` knows them as:

```json
{ "hosts": ["razer"] }
```

in `~/.config/omarchy/herdr.json`. The file is watched, so an edit applies
while the menu is open. No file means this machine only.

**This machine** needs `herdr`, `jq`, `hyprctl`, `foot` (or
`xdg-terminal-exec`) and `ss` from iproute2, which the kill button uses to find
a session's server.

**Each remote host** needs `bash`, `jq` and `herdr` on the ssh user's `PATH`,
and a key that logs in without a prompt: every call uses `BatchMode=yes`. The
data script is piped to the host on each call, so nothing is installed there,
and one shared connection keeps polling to a handshake a minute.

## Removing it

```bash
omarchy plugin disable nixarchy.herdr
omarchy plugin remove nixarchy.herdr
```

Then delete the `SUPER + SHIFT + H` line from `~/.config/hypr/bindings.lua`,
run `hyprctl reload`, and remove `~/.config/omarchy/herdr.json` if you made one.

Nothing about your work is kept: every value on screen is read from herdr at
the moment it is drawn, and no session name, agent title, prompt or reply is
written to disk, locally or on another host.

The one file it can create is the demo flag, and only if you turned demo mode
on. It is empty and holds nothing about you, but it outlives the plugin:

```bash
rm -rf ~/.cache/omarchy-herdr
```

Your herdr sessions are untouched by removing the plugin - they live in
`~/.config/herdr/` and are herdr's, not this plugin's.

## License

MIT. Copyright (c) 2026 Jankees van Woezik and (c) 2026 olafkfreund; see
[LICENSE](LICENSE). The herdr logo in `assets/herdr-logo.svg` and
`assets/herdr-mark.svg` is from herdrdev/herdr under Apache-2.0.
