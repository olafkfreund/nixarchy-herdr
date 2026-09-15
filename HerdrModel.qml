import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Session state, actions and polling for one surface that shows the herd.
// The bar widget and the menu each own one, and hand it to Card.qml as `panel`.
Item {
  id: root
  visible: false

  // The surface this model serves: it supplies whether it is open, whether it
  // is pinned, the bar-derived colours and font, and the card on screen.
  property var host: null

  readonly property bool opened: host ? host.opened === true : false
  readonly property bool pinned: host ? host.pinned === true : false
  readonly property bool pinnable: host ? host.pinnable !== false : true
  // A summoned menu is read from further away than a bar dropdown, so the
  // surface says how big its text should be.
  readonly property real textScale: host && host.textScale > 0 ? host.textScale : 1.0
  readonly property var activeCard: host ? host.activeCard : null
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color accent: host ? host.accent : Color.accent
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  function close() { if (host) host.close() }
  function togglePin() { if (host && typeof host.togglePin === "function") host.togglePin() }

  // The script sits next to this file, so the plugin runs from wherever it
  // was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/herdr-sessions").toString().replace(/^file:\/\//, "")

  readonly property string iconDot: "\uF111"
  readonly property string iconOpen: "\uF2D2"
  readonly property string iconTrash: "\uF1F8"
  // nf-md-skull, U+F068C. Written as its surrogate pair because a `\u`
  // escape takes exactly four hex digits, and this codepoint is past the
  // point where four is enough - `"\uF068C"` is a different glyph followed
  // by the letter C.
  readonly property string iconKill: "\uDB81\uDE8C"
  // nf-fa-thumb_tack, U+F08D.
  readonly property string iconPin: "\uF08D"

  // Omarchy themes carry a foreground, an accent and an urgent, and no green.
  // "Finished" is green everywhere there is a build, a test or a task list, and
  // borrowing the accent for it would leave a finished agent looking exactly
  // like a working one - which is the distinction this widget exists to draw.
  // So this one colour is picked rather than themed.
  readonly property color finished: "#5FA46B"
  // Working is amber for the same reason, and because it used to borrow the
  // accent: on a theme whose accent is red or green, "busy" was indistinguish-
  // able from "needs you" or "finished" - the two the badge exists to separate.
  readonly property color working: "#D6A84B"

  property var sessions: []
  // Sessions this machine answered with, kept apart from the remote ones so a
  // host that goes quiet does not take the local list down with it.
  property var localSessions: []

  // Other machines, named in ~/.config/omarchy/herdr.json as
  // { "hosts": ["razer"] }. Only a surface that asks for them polls them: the
  // bar stays local, so an unreachable host can never slow the badge down.
  property bool remote: false
  property var hostNames: []
  property var hostSessions: ({})
  // Per host: "ok" when it answered with servers running, "empty" when it
  // answered with none, "down" when it did not answer.
  property var hostState: ({})
  property int runningCount: 0
  property int agentCount: 0
  property int blockedCount: 0
  property int doneCount: 0
  property int workingCount: 0
  // The three states that turn into each other without you touching anything.
  // They decide the badge's colour, and they decide how often it is worth
  // asking - an idle herd cannot change until you change it.
  readonly property bool badgeActive:
    blockedCount > 0 || doneCount > 0 || workingCount > 0
  property bool reachable: true
  property string errorText: ""
  // Session the script is currently acting on, so its row can dim.
  property string pendingName: ""
  // The session the kill dialog is asking about, held while it is open.
  property var killTarget: null
  property bool confirmOpen: false

  // Which agent spoke last, as "<session>\u0000<pane>", and every agent that
  // was already asking when we last looked.
  //
  // Herdr plays a sound when an agent starts wanting something, and that
  // sound says only that it happened, not which of them it was. This is the
  // panel's answer to that: whoever turned blocked or done since the previous
  // refresh gets a dot that blinks, so the noise you just heard has a face.
  //
  // Worked out by comparing polls rather than by trusting a number in the
  // payload, because herdr's state_change_seq is documented as a sort field
  // and not as a clock, so whether it counts per server or per agent is not
  // something to build on. It is only used to break a tie when two agents
  // start asking within the same poll.
  property string attentionKey: ""
  property var wantingBefore: ({})
  // The first poll has nothing to compare against, so every agent that is
  // already waiting would look like it just spoke. That first answer only
  // sets the baseline: after a shell restart nothing blinks until something
  // actually changes, which is the honest thing for a signal that means
  // "this just happened".
  property bool attentionPrimed: false
  // Whether the cursor has been put on the best row for this opening of the
  // panel. Without it every refresh would drag the cursor back there, three
  // seconds after you moved it.
  property bool cursorPlaced: false

  // Where the cursor is across the row: 0 is the row itself, 1 the open
  // button, 2 the destructive one. Right and Tab walk out to the buttons,
  // Left walks back. Kept as a number rather than a per-row object so moving
  // up and down holds its place in the row: walking a column of kill buttons
  // is a thing you do on purpose.
  readonly property int columnRow: 0
  readonly property int columnOpen: 1
  readonly property int columnDestroy: 2
  property int column: 0
  property int cursor: -1

  // Names come back from herdr and go straight back out as an argument. The
  // script checks them too; this is the near end of the same fence.
  function validName(name) {
    return /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(String(name))
  }

  // Pane ids are herdr's own opaque handles - "w1:p2" - and travel back out
  // as an argument the same way names do.
  function validPane(pane) {
    return /^[A-Za-z0-9_-]{1,32}:[A-Za-z0-9_-]{1,32}$/.test(String(pane))
  }

  // Markup stripped rather than escaped: the bar tooltip is the shell's own
  // component, so `textFormat` there is not ours to set.
  function plain(s) {
    return String(s || "").replace(/[<>]/g, "")
  }

  function refresh() {
    if (!listProc.running) {
      listProc.command = [root.script, "list"]
      listProc.running = true
    }
    if (!remote) return
    // One process per host, and a host whose last poll is still out is
    // skipped rather than queued: an unreachable one costs the script's full
    // 8s ceiling, which is longer than the poll interval.
    for (var i = 0; i < hostPolls.count; i++) {
      var poll = hostPolls.objectAt(i)
      if (poll && !poll.running) poll.start()
    }
  }

  // Everything drawn, local first and then each host in the order the config
  // names them, with the counts taken over the lot so the title and the badge
  // describe what is on screen.
  function rebuild() {
    var all = localSessions.slice()
    if (remote)
      for (var i = 0; i < hostNames.length; i++) {
        var list = hostSessions[hostNames[i]] || []
        for (var j = 0; j < list.length; j++) all.push(list[j])
      }

    var running = 0, agents = 0, blocked = 0, done = 0, working = 0
    for (var k = 0; k < all.length; k++) {
      var session = all[k]
      if (session.running) running++
      agents += session.agents || 0
      blocked += session.blocked || 0
      done += session.done || 0
      working += session.working || 0
    }

    sessions = all
    runningCount = running
    agentCount = agents
    blockedCount = blocked
    doneCount = done
    workingCount = working

    updateAttention(all)
    if (opened && !cursorPlaced) {
      cursor = bestRow()
      cursorPlaced = true
      var row = rowAt(cursor)
      if (row) showRow(row.sessionIndex)
    }
    if (cursor > navRows.length - 1) cursor = navRows.length - 1
  }

  // What a host's dot says: it answered and something is running, it answered
  // with nothing running, or it did not answer at all.
  function stateOfHost(host) {
    if (!host) return "ok"
    return hostState[host] || "down"
  }

  function applyHostPayload(host, text) {
    // New objects every time: assigning the same object back is not a change
    // to QML, and the title line would keep the state from before it answered.
    var next = {}, state = {}, key
    for (key in hostSessions) next[key] = hostSessions[key]
    for (key in hostState) state[key] = hostState[key]
    try {
      var data = JSON.parse(text)
      if (data.ok !== true) throw new Error("not ok")
      next[host] = data.sessions || []
      state[host] = (data.sessions || []).some(function (s) { return s.running }) ? "ok" : "empty"
    } catch (e) {
      next[host] = []
      state[host] = "down"
    }
    hostSessions = next
    hostState = state
    rebuild()
  }

  function run(action, name, extra) {
    if (!validName(name) || actionProc.running) return
    pendingName = name
    var command = [root.script, action, name]
    if (extra !== undefined && extra !== "") command.push(extra)
    actionProc.command = command
    actionProc.running = true
  }

  // A dropdown is in the way of the window you just asked for, so acting from
  // one closes it. A pinned panel is not in the way of anything: you put it
  // where you wanted it, and a panel that vanishes every time you use it is a
  // panel you have to summon again to use twice.
  function dismiss() {
    if (!pinned) close()
  }

  // Focus the window this session is already showing, or open one.
  function openSession(session) {
    if (!session || !validName(session.name)) return
    run("open", session.name)
    dismiss()
  }

  // One step further in than openSession: the agent's own pane is focused
  // inside the server before the window comes up, so the click lands on the
  // work you were reading rather than on wherever that session was left.
  //
  // Focusing is also what marks a finished agent as seen - herdr turns `done`
  // back into `idle` the moment its pane is targeted - so clicking the line
  // that says "done" is what clears it.
  //
  // A pane herdr has not named yet falls back to opening the session, which
  // is what the click would have done anyway.
  function focusAgent(session, agent) {
    if (!session || !agent) return
    if (!validPane(agent.pane)) { openSession(session); return }
    if (!validName(session.name)) return
    run("focus", session.name, agent.pane)
    dismiss()
  }

  // Deleting throws away a session that is already stopped - its directory and
  // the state herdr kept in it - which is what clears it out of the list for
  // good. A running server is killed rather than deleted; the two never apply
  // to the same row. The shared session is herdr's own and is not deleted from
  // here at all.
  function removeSession(session) {
    if (!session || session.isDefault || session.running) return
    run("delete", session.name)
  }

  // How a running server is ended here, and the only way: `herdr session stop`
  // asks over herdr's own socket, so a server too wedged to read that socket
  // never hears the request, and the button that sent it looked broken at
  // exactly the moment you needed it. Signalling the process works either way,
  // so there is no reason to keep both.
  //
  // The shared session is killed like any other. It wedges like any other.
  function killSession(session) {
    if (!session || !session.running || !validName(session.name)) return
    run("kill", session.name)
  }

  // Killing is the one thing here that cannot be taken back: the server is
  // gone and so is everything that was running inside it, without anything
  // being asked to finish first. Opening a session, focusing an agent and even
  // deleting a stopped session are all recoverable or trivial by comparison,
  // so this is the only action that stops to ask.
  //
  // The dialog opens on Cancel rather than on the confirming side, which is
  // ConfirmDialog's own default: a dialog that destroys something on a
  // reflexive Enter is worse than no dialog, because it trains the reflex.
  function askKill(session) {
    if (!session || !session.running || !validName(session.name)) return
    killTarget = session
    confirmOpen = true
    if (activeCard) activeCard.beginConfirm()
  }

  function closeKill() {
    confirmOpen = false
    killTarget = null
    if (activeCard) activeCard.endConfirm()
  }

  function confirmKill() {
    var session = killTarget
    closeKill()
    killSession(session)
  }

  function killMessage() {
    if (!killTarget) return ""
    return "Kill the server for " + sessionLabel(killTarget)
      + "? Nothing running inside it is asked to stop first."
  }

  // What the arrow keys walk: the agents, in the order they are drawn, not the
  // servers holding them. A server is a place, an agent is the work, and the
  // work is what you came to reach.
  //
  // A session with no agents still gets a row of its own, or a stopped session
  // and an empty server would drop out of the keyboard entirely and there
  // would be no way to open or delete one without the mouse.
  readonly property var navRows: {
    var rows = []
    for (var i = 0; i < sessions.length; i++) {
      var agents = sessions[i].agentList || []
      if (agents.length === 0) {
        rows.push({ sessionIndex: i, agentIndex: -1 })
        continue
      }
      for (var j = 0; j < agents.length; j++)
        rows.push({ sessionIndex: i, agentIndex: j })
    }
    return rows
  }

  function rowAt(index) {
    if (index < 0 || index >= navRows.length) return null
    return navRows[index]
  }

  function sessionAt(index) {
    var row = rowAt(index)
    return row ? sessions[row.sessionIndex] : null
  }

  function agentAt(index) {
    var row = rowAt(index)
    if (!row || row.agentIndex < 0) return null
    return (sessions[row.sessionIndex].agentList || [])[row.agentIndex] || null
  }

  // How loudly an agent is asking, lowest number first, matching the order the
  // script already sorts them in. Used to pick where the cursor starts.
  function attentionRank(status) {
    if (status === "blocked") return 0
    if (status === "done") return 1
    if (status === "working") return 2
    if (status === "idle") return 3
    return 4
  }

  // Opening the panel puts the cursor on the agent that wants the most, not on
  // the first row: the reason you opened it is almost never the top of the
  // list. Ties go to whoever is drawn first, which is herdr's own order.
  function bestRow() {
    var best = -1
    var bestRank = 99
    for (var i = 0; i < navRows.length; i++) {
      var agent = agentAt(i)
      if (!agent) continue
      var rank = attentionRank(agent.status)
      if (rank < bestRank) { bestRank = rank; best = i }
    }
    return best >= 0 ? best : (navRows.length > 0 ? 0 : -1)
  }

  // The destructive button is not on every row: a stopped shared session has
  // nothing to kill and nothing that may be deleted, so its slot is empty and
  // the cursor must step over it rather than park on a dead control.
  function lastColumnFor(session) {
    if (!session) return root.columnRow
    if (session.running) return root.columnDestroy
    return session.isDefault ? root.columnOpen : root.columnDestroy
  }

  function clampColumn() {
    var last = lastColumnFor(sessionAt(cursor))
    if (column > last) column = last
    if (column < root.columnRow) column = root.columnRow
  }

  function moveColumn(delta) {
    if (navRows.length === 0) return
    if (cursor < 0) cursor = bestRow()
    column += delta
    clampColumn()
  }

  // Tab is the same walk with a wrap, so one key cycles a row without having
  // to know how many buttons it has.
  function cycleColumn(direction) {
    if (navRows.length === 0) return
    if (cursor < 0) { cursor = bestRow(); column = root.columnRow; return }
    var last = lastColumnFor(sessionAt(cursor))
    column += direction
    if (column > last) column = root.columnRow
    if (column < root.columnRow) column = last
  }

  function moveCursor(delta) {
    if (navRows.length === 0) return
    var next = cursor < 0 ? (delta > 0 ? 0 : navRows.length - 1) : cursor + delta
    if (next < 0) next = 0
    if (next > navRows.length - 1) next = navRows.length - 1
    cursor = next
    clampColumn()
    var row = rowAt(next)
    if (row) showRow(row.sessionIndex)
  }

  function showRow(sessionIndex) {
    if (activeCard) activeCard.showRow(sessionIndex)
  }

  // Enter goes as deep as the cursor is: onto the agent when it is on one, and
  // onto the session when the row is a session with nothing in it.
  function activateCursor() {
    var session = sessionAt(cursor)
    if (!session) return
    if (column === root.columnOpen) { openSession(session); return }
    if (column === root.columnDestroy) {
      if (session.running) askKill(session)
      else removeSession(session)
      return
    }
    var agent = agentAt(cursor)
    if (agent) focusAgent(session, agent)
    else openSession(session)
  }

  // True when the cursor is on the row itself rather than out on a button,
  // which is what the agent lines light up on.
  function cursorInBody() {
    return column === root.columnRow
  }

  // Which nav row a given agent is, so a delegate can tell whether the cursor
  // is on it without knowing anything about the flattening above.
  function cursorOnAgent(sessionIndex, agentIndex) {
    var row = rowAt(cursor)
    return row !== null && row.sessionIndex === sessionIndex
      && row.agentIndex === agentIndex
  }

  // The mouse moves the same cursor the keys do, so leaving the mouse and
  // reaching for the arrows carries on from where you were pointing.
  function cursorToAgent(sessionIndex, agentIndex) {
    column = root.columnRow
    for (var i = 0; i < navRows.length; i++)
      if (navRows[i].sessionIndex === sessionIndex && navRows[i].agentIndex === agentIndex) {
        cursor = i
        return
      }
  }

  function cursorToSession(sessionIndex) {
    column = root.columnRow
    for (var i = 0; i < navRows.length; i++)
      if (navRows[i].sessionIndex === sessionIndex) {
        cursor = i
        return
      }
  }

  function cursorOnSession(sessionIndex) {
    var row = rowAt(cursor)
    return row !== null && row.sessionIndex === sessionIndex
  }

  // "default" is herdr's own name for the shared session, and it reads as a
  // setting rather than a place. A numbered one is a Hyprland workspace,
  // which is worth saying out loud.
  function sessionLabel(session) {
    if (!session) return ""
    var label
    if (session.isDefault) label = "Shared session"
    else if (/^[0-9]+$/.test(session.name)) label = "Workspace " + session.name
    else label = session.name
    // Which machine it is on, said on the row itself rather than in a header
    // above a group: the rows are already sorted host by host, and a header
    // would have to live inside a delegate the bar panel shares.
    return session.host ? session.host + "  \u00b7  " + label : label
  }

  // What each configured host is doing, for the title line: answered with
  // something running, answered with nothing, or did not answer.
  function hostSummary() {
    if (!remote || hostNames.length === 0) return ""
    var parts = []
    for (var i = 0; i < hostNames.length; i++) {
      var state = stateOfHost(hostNames[i])
      parts.push(hostNames[i] + " "
                 + (state === "ok" ? "\u25cf" : state === "empty" ? "\u25cb" : "\u2013"))
    }
    return parts.join("   ")
  }

  // Asked for by a key in the card, answered by whichever surface can show an
  // input. The bar panel does not connect it, so `n` does nothing there.
  signal newSessionRequested()
  function requestNew() { newSessionRequested() }

  // Create on the host the cursor is on, so `n` while reading razer's
  // sessions makes one on razer.
  function hostAtCursor() {
    var session = sessionAt(cursor)
    return session && session.host ? String(session.host) : ""
  }

  function newSession(host, name, dir) {
    if (!validName(name) || actionProc.running) return
    pendingName = name
    var command = [root.script]
    if (host) command.push("--host", host)
    command.push("new", name)
    if (dir !== undefined && dir !== "") command.push(dir)
    actionProc.command = command
    actionProc.running = true
  }

  // A stopped session names what it is holding rather than only saying it is
  // down: herdr keeps the layout in session.json, so the workspaces and the
  // directories they were opened in survive the server. That is the difference
  // between a session worth starting back up and a name left over from an
  // afternoon, and it is not visible from the word "stopped".
  // Only where the agent lines are not already saying it. A running session
  // with agents in it now names its workspaces one per agent, next to the work
  // going on there, so repeating the merged list above them is the same words
  // twice with less meaning.
  function subtitleFor(session) {
    if (!session) return ""
    if (session.running && (session.agentList || []).length > 0) return ""
    var projects = session.projects || []
    if (projects.length > 0) return projects.join("  ·  ")
    return session.running ? "no workspaces yet" : "nothing saved"
  }

  // "stopped" belongs in the right-hand column with the agent counts and the
  // agent states, not in the subtitle: that column is where the panel says
  // what something is doing, and a stopped server is doing nothing.
  function countLabel(session) {
    if (!session) return ""
    if (!session.running) return "stopped"
    var n = session.agents || 0
    if (n === 0) return "no agents"
    return n === 1 ? "1 agent" : n + " agents"
  }

  // The one word worth colouring: blocked means an agent is waiting on you,
  // working means it is busy. Anything else is quiet and says nothing.
  // Waiting beats finished beats busy, everywhere a state has to be reduced
  // to one thing: a question on screen outranks work that has already ended,
  // and both outrank an agent that is simply busy.
  function noteLabel(session) {
    if (!session || !session.running) return ""
    if ((session.blocked || 0) > 0) return session.blocked + " needs you"
    if ((session.done || 0) > 0) return session.done + " done"
    if ((session.working || 0) > 0) return session.working + " working"
    return ""
  }

  // Herdr puts a spinner glyph in front of a title while its agent is working,
  // so the same task moves left and right as it ticks over. Dropping any run
  // of leading symbols keeps the titles in one column; the status dot beside
  // them says the same thing without moving.
  function cleanTitle(title) {
    var s = String(title || "").trim()
    var stripped = s.replace(/^[^0-9A-Za-z\u00C0-\u024F]+/, "").trim()
    return stripped !== "" ? stripped : s
  }

  // Every agent, however many there are and wherever herdr keeps them: a pane
  // in a second tab counts the same as one sitting in front of you, and an
  // agent summarised as "+1 more" is exactly the one you would have wanted to
  // read. The list scrolls when it has to; that is what the card's height cap
  // is for.
  function agentsOf(session) {
    if (!session) return []
    return session.agentList || []
  }

  function agentColor(status) {
    if (status === "blocked") return root.urgent
    if (status === "done") return root.finished
    if (status === "working") return root.accent
    return Qt.darker(root.foreground, 1.9)
  }

  // Every agent says what it is doing, in herdr's own terms: `blocked` is an
  // approval or a question on screen, `done` is work that finished while you
  // were looking elsewhere, `idle` is a prompt waiting for you to type - which
  // reads better as "ready", because "idle" sounds like a problem and it is
  // the ordinary resting state.
  //
  // These run down the right edge in one column, so the question is not "which
  // line has a label" but "what does that column say" - one glance instead of
  // a scan. Two of them are still news and two are not, and that is carried by
  // weight and colour rather than by leaving a word out: the ones that want
  // something are bold and coloured, the rest are quiet grey.
  function agentNote(status) {
    if (status === "blocked") return "needs you"
    if (status === "done") return "done"
    if (status === "working") return "working"
    if (status === "idle") return "ready"
    return "unknown"
  }

  function agentWants(status) {
    return status === "blocked" || status === "done"
  }

  function noteColor(session) {
    if (!session) return root.foreground
    if ((session.blocked || 0) > 0) return root.urgent
    if ((session.done || 0) > 0) return root.finished
    return root.accent
  }

  function statusColor(session) {
    if (!session || !session.running) return Qt.darker(root.foreground, 2.2)
    if ((session.blocked || 0) > 0) return root.urgent
    if ((session.done || 0) > 0) return root.finished
    if ((session.working || 0) > 0) return root.accent
    return Qt.darker(root.foreground, 1.7)
  }

  function badgeColor() {
    if (blockedCount > 0) return root.urgent
    if (doneCount > 0) return root.finished
    return root.working
  }

  function titleText() {
    var s = runningCount === 1 ? " server" : " servers"
    var a = agentCount === 1 ? " agent" : " agents"
    var title = "Herdr (" + runningCount + s + ", " + agentCount + a + ")"
    var hosts = hostSummary()
    return hosts === "" ? title : title + "   " + hosts
  }

  // The bar shows a bare number, which says nothing about what it counts. The
  // tooltip is where that gets spelled out, and where a herd that wants
  // something says so before the panel is even open.
  function tooltipText() {
    var parts = [runningCount + (runningCount === 1 ? " herdr server" : " herdr servers"),
                 agentCount + (agentCount === 1 ? " agent" : " agents")]
    if (blockedCount > 0) parts.push(blockedCount + " waiting on you")
    if (doneCount > 0) parts.push(doneCount + " finished")
    return parts.join(", ")
  }

  function agentKey(sessionName, pane) {
    return String(sessionName) + "\u0000" + String(pane)
  }

  // Everything that is asking for something right now, and which of those is
  // new since the previous poll. A tie inside one poll goes to the highest
  // state_change_seq, which is the best herdr can tell us; a tie there too
  // goes to nobody, because a dot that blinks on the wrong agent is worse
  // than one that does not blink at all.
  function updateAttention(sessionList) {
    var wantingNow = {}
    var freshest = null
    for (var i = 0; i < sessionList.length; i++) {
      var session = sessionList[i]
      var agents = session.agentList || []
      for (var j = 0; j < agents.length; j++) {
        if (!root.agentWants(agents[j].status)) continue
        var key = root.agentKey(session.name, agents[j].pane)
        wantingNow[key] = true
        if (root.wantingBefore[key]) continue
        if (freshest === null || (agents[j].seq || 0) > freshest.seq)
          freshest = { key: key, seq: agents[j].seq || 0 }
      }
    }

    // An agent that stopped asking stops blinking, even if nobody took its
    // place: the blink is about a question still standing, not about history.
    if (root.attentionKey !== "" && !wantingNow[root.attentionKey])
      root.attentionKey = ""
    if (freshest !== null && root.attentionPrimed) root.attentionKey = freshest.key

    root.wantingBefore = wantingNow
    root.attentionPrimed = true
  }

  function blinking(sessionName, agent) {
    if (!agent || root.attentionKey === "") return false
    return root.agentKey(sessionName, agent.pane) === root.attentionKey
  }

  function applyPayload(text) {
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      errorText = data.error || ""
      if (!reachable) return
      localSessions = data.sessions || []
      rebuild()
    } catch (e) {
      reachable = false
      errorText = "unexpected output from herdr-sessions"
    }
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      // The list may still be the one from the last poll, so place the cursor
      // on what we know now and again when the fresh answer lands.
      cursor = bestRow()
      column = root.columnRow
      cursorPlaced = false
    } else {
      cursor = -1
      column = root.columnRow
      cursorPlaced = false
    }
  }

  // The host list, watched so an edit applies without a restart. A missing or
  // unreadable file means this machine only.
  FileView {
    id: hostsFile
    path: Quickshell.env("HOME") + "/.config/omarchy/herdr.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.hostNames = root.parseHosts(text())
    onLoadFailed: root.hostNames = []
    onFileChanged: reload()
  }

  // Shape-checked here as well as in the script: a name that is not a host
  // name is dropped rather than passed on.
  function parseHosts(text) {
    try {
      var list = (JSON.parse(text) || {}).hosts || []
      var out = []
      for (var i = 0; i < list.length; i++) {
        var host = String(list[i])
        if (/^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$/.test(host) && out.indexOf(host) < 0)
          out.push(host)
      }
      return out
    } catch (e) {
      return []
    }
  }

  Instantiator {
    id: hostPolls
    model: root.remote ? root.hostNames : []
    delegate: Process {
      id: hostProc
      required property string modelData
      function start() {
        command = [root.script, "--host", modelData, "list"]
        running = true
      }
      stdout: StdioCollector {
        onStreamFinished: root.applyHostPayload(hostProc.modelData, text)
      }
      onExited: function (code) {
        if (code !== 0) root.applyHostPayload(hostProc.modelData, "")
      }
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) {
      root.pendingName = ""
      // A stopped server disappears from the list, and a freshly opened
      // window takes a moment to register its agents. One beat, then look
      // again.
      settleTimer.restart()
    }
  }

  Timer {
    id: settleTimer
    interval: 400
    onTriggered: root.refresh()
  }

  // Polled rather than subscribed: herdr has an event socket, but one per
  // server, and the count in the bar is the sort of thing that can be a few
  // seconds old. Faster while the panel is open, because the agent states in
  // it are what you came to read, and faster while anything is live, because
  // that is the only time the badge colour can go stale on its own. Idle costs
  // one poll every twenty seconds and catches the moment you start something.
  Timer {
    interval: root.opened ? 3000 : (root.badgeActive ? 5000 : 20000)
    // The bar keeps its badge current all the time. A surface that reaches
    // other machines polls only while it is open, so closing the menu stops
    // every ssh call; opening it refreshes straight away.
    running: !root.remote || root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
