import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

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
  // How big the text is on every surface that shows the herd. Kept in a file
  // under the cache directory, so the bar panel and the menu agree and the
  // size outlives a shell restart.
  property real textScale: 1.0
  readonly property var activeCard: host ? host.activeCard : null
  readonly property color foreground: host ? host.foreground : Commons.Color.foreground
  readonly property color accent: host ? host.accent : Commons.Color.accent
  readonly property color urgent: host ? host.urgent : Commons.Color.urgent
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  // Emitted once when an action started by run() or newSession() finishes.
  // Never for a kill, a list or a host poll.
  signal actionFinished(string action, bool ok)

  function close() { if (host) host.close() }
  // `fromKey` tells the pinned window the pin came from the keyboard, so it
  // takes focus at once instead of after the mouse-pin delay.
  function togglePin(fromKey) {
    if (host && typeof host.togglePin === "function") host.togglePin(fromKey === true)
  }

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
  //
  // Working is amber for the same reason, and because it used to borrow the
  // accent: on a theme whose accent is red or green, "busy" was indistinguish-
  // able from "needs you" or "finished" - the two the badge exists to separate.
  //
  // A theme that wants to say otherwise can, through `done` and `working`
  // under [herdr] in its shell.toml. The values go through the same
  // flatColor the shell uses for its own roles, so a role name like "accent"
  // or an eight-digit hex means what it means everywhere else, and a typo
  // lands on the fallback instead of on black.
  function themeColor(key, fallback) {
    var value = Commons.Color.pick(key, "")
    return value ? Commons.Color.flatColor(value, fallback) : fallback
  }
  readonly property color finished: themeColor("herdr.done", "#5FA46B")
  readonly property color working: themeColor("herdr.working", "#D6A84B")
  readonly property color workingForeground: themeColor("herdr.working", root.accent)

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
  // answered with none, "down" when it did not answer, and "checking" until
  // the first answer after the menu opened.
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
  // What the badge counts: the agents that want you.
  readonly property int needCount: blockedCount + doneCount
  property bool reachable: true
  property string errorText: ""
  // Why an action refused, as it said so itself. `errorText` is about the
  // list not arriving; this is about the one thing you just pressed, which
  // otherwise failed by leaving the row exactly where it was.
  property string actionError: ""
  property string ownerToken: ""
  readonly property var actionSlot: HerdrActions.slot(ownerToken, "action")
  readonly property var killSlot: HerdrActions.slot(ownerToken, "kill")
  readonly property string actionName: actionSlot ? actionSlot.meta.actionName || "" : ""
  readonly property bool actionDismiss: actionSlot ? actionSlot.meta.actionDismiss === true : false
  readonly property string killPendingKey: killSlot ? killSlot.meta.killPendingKey || "" : ""
  // Sessions the script left out of the list for size, and running servers
  // whose agents it could not read.
  property int hiddenSessions: 0
  property int unreadableCount: 0
  // Bumped when the menu closes; a host poll started before that is stale.
  property int pollGen: 0
  // Session the script is currently acting on, as sessionKey(), so its row
  // can dim.
  readonly property string pendingKey: actionSlot ? actionSlot.meta.pendingKey || "" : ""
  // The session the confirm dialog is asking about, held while it is open,
  // and which of the two destructive actions it will run on Confirm.
  property var confirmTarget: null
  property string confirmAction: ""
  property bool confirmOpen: false
  // The agent an app kill is asking about, and the one a kill is running on,
  // so a `changed` reply can reopen the question with the new cascade.
  property var confirmAgent: null
  readonly property var killSessionRef: killSlot ? killSlot.meta.session || null : null
  readonly property var killAgentRef: killSlot ? killSlot.meta.agent || null : null

  // herdr-core and herdr-app, read through `hc events` (a subscription that
  // only says "something changed") and `herdr-sessions app-list`.
  property bool hcAvailable: true
  property bool appStale: false
  // A failure mark for the bar badge: unconditional while stale, but never when
  // hc is absent (that case is silent by design).
  readonly property bool appMark: hcAvailable && appStale
  readonly property bool badgeShown: appMark || badgeActive
  property bool appDirty: false
  property bool appSubLive: false
  property string appError: ""
  property var appSessions: []
  property var appHostSessions: []
  property var appMachines: []
  property int appCoalesceMs: 250
  property int appWatchdogMs: 40000
  property int appBackoffMs: 2000
  property int appBackoffCur: 0
  property int appListRetries: 0
  // Bumped on a failed start and on every restart: an app-list that began
  // before then answers for a subscription that is gone, and is dropped.
  property int appGen: 0

  // Which agent spoke last, as agentKey(), and every agent that
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
  // The blink lasts one minute from the moment it starts, so a herd that is
  // left alone does not blink all night.
  property bool blinkExpired: false
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

  // The same fence as valid_hc_address in the script.
  function validHcAddress(addr) {
    return /^([A-Za-z0-9][A-Za-z0-9._-]{0,31}\/)?t[0-9a-z]{1,9}$/.test(String(addr))
  }

  // Markup stripped rather than escaped: the bar tooltip is the shell's own
  // component, so `textFormat` there is not ours to set.
  function plain(s) {
    return String(s || "").replace(/[<>]/g, "")
  }

  function refresh() {
    if (!listProc.running && !listProc.open) {
      listProc.command = [root.script, "list"]
      listProc.open = true
      listProc.running = true
    }
    // Other machines are asked only while the menu is open. The settle timer
    // after an action lands here too, and would otherwise start an ssh per
    // host behind a closed menu.
    if (!remote || !opened) return
    // One process per host, and a host whose last poll is still out is
    // skipped rather than queued: an unreachable one costs the script's full
    // 8s ceiling, which is longer than the poll interval.
    for (var i = 0; i < hostPolls.count; i++) {
      var poll = hostPolls.objectAt(i)
      if (poll && !poll.running) poll.start()
    }
  }

  // Both signals of a process (its stdout and its exit) come in either order.
  // Store each, and complete the run when the second one arrives.
  function storeResult(proc, which, value) {
    if (which === "out") { proc.out = value; proc.gotOut = true }
    else { proc.code = value; proc.gotExit = true }
    if (!proc.gotOut || !proc.gotExit) return
    finishRun(proc, proc.out, proc.code)
  }

  // Quickshell reports a command that could not start only by `running`
  // going false, with neither stdout nor an exit: complete that run once, as
  // a failure, or whatever waits on it waits for good.
  function startFailed(proc) {
    if (!proc.open) return
    finishRun(proc, JSON.stringify({ ok: false, error: "could not start herdr-sessions" }), -1)
  }

  function finishRun(proc, out, code) {
    proc.open = false
    proc.gotOut = false
    proc.gotExit = false
    complete(proc.kind, out, code, proc)
    // A poll asked for again while it was still exiting starts over now.
    if (proc.restartPending === true) {
      proc.restartPending = false
      if (opened) proc.start()
    }
  }

  // One completion per run. Only an action may dismiss the surface.
  function complete(kind, out, code, proc) {
    if (kind === "list") { applyPayload(out, code); return }
    if (kind === "applist") { applyAppList(out, code, proc.gen); return }
    if (kind === "host") {
      if (proc.gen !== pollGen) return
      applyHostPayload(proc.modelData, code === 0 ? out : "")
      return
    }
  }

  function onResult(kind, meta, result) {
    var action = kind === "kill" ? "kill" : meta.actionName
    // The cascade moved since it was shown: ask again with the new one.
    if (kind === "kill" && result.changed && meta.session && meta.agent) {
      confirmTarget = meta.session
      confirmAgent = Object.assign({}, meta.agent,
        { cascade: result.cascade, cascadeKey: result.cascadeKey })
      confirmAction = "appkill"
      confirmOpen = true
      actionError = ""
      if (activeCard) activeCard.beginConfirm()
      return
    }
    actionError = result.ok ? result.note : result.error
    if (kind === "action") {
      if (result.ok && meta.actionDismiss) dismiss()
      actionFinished(action, result.ok)
    }
    // A stopped server disappears from the list, and a freshly opened window
    // takes a moment to register its agents. One beat, then look again.
    settleTimer.restart()
  }

  function claimActions() {
    var taken = HerdrActions.claimMenu()
    if (!taken.action && !taken.kill) return
    var errors = []
    for (var kind of ["action", "kill"]) {
      var item = taken[kind]
      if (!item) continue
      var message = kind === "kill" && item.result.changed && item.meta.session && item.meta.agent
        ? "the agents to end changed; press the key again"
        : item.result.ok ? item.result.note : item.result.error
      if (message) errors.push(message)
    }
    actionError = errors.join("; ")
    settleTimer.restart()
    appRunList()
  }

  // Everything drawn, local first and then each host in the order the config
  // names them, with the counts taken over the lot so the title and the badge
  // describe what is on screen.
  function rebuild() {
    var all = localSessions.concat(appSessions)
    if (remote) {
      for (var i = 0; i < hostNames.length; i++) {
        var list = hostSessions[hostNames[i]] || []
        for (var j = 0; j < list.length; j++) all.push(list[j])
      }
      all = all.concat(appHostSessions)
    }

    // The cursor follows what it is on, not the number of the row: a refresh
    // that re-sorts the list must not move it onto a different session.
    var oldKey = cursor >= 0 ? rowKey(sessions, rowAt(cursor)) : ""
    var rows = navRowsFor(all)
    var found = -1
    if (oldKey !== "")
      for (var r = 0; r < rows.length; r++)
        if (rowKey(all, rows[r]) === oldKey) { found = r; break }

    var running = 0, agents = 0, blocked = 0, done = 0, working = 0, unreadable = 0
    for (var k = 0; k < all.length; k++) {
      var session = all[k]
      // App spaces are not herdr servers.
      if (session.running && session.kind !== "app") running++
      if (session.running && session.readable === false) unreadable++
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
    unreadableCount = unreadable
    var moved = found >= 0 && found !== cursor
    if (found >= 0) cursor = found
    else if (cursor > rows.length - 1) cursor = rows.length - 1

    updateAttention(all)
    if (opened && !cursorPlaced) {
      cursor = bestRow()
      cursorPlaced = true
      var row = rowAt(cursor)
      if (row) showRow(row.sessionIndex, row.agentIndex)
    } else if (moved && opened) {
      // Same row, new place: a re-sort must not leave it out of sight.
      var kept = rowAt(cursor)
      if (kept) showRow(kept.sessionIndex, kept.agentIndex)
    }
  }

  // What a host's dot says: it answered and something is running, it answered
  // with nothing running, or it did not answer at all.
  function stateOfHost(host) {
    if (!host) return "ok"
    return hostState[host] || "checking"
  }

  function applyHostPayload(host, text) {
    // An answer that lands after the menu closed is dropped: the dots and the
    // title are not on screen, and the next open asks again.
    if (remote && !opened) return
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

  // Starts the script for one action. Returns false, with the reason in
  // actionError, when it cannot start. Kill has its own process.
  function launch(action, host, name, extra, dismissOnSuccess) {
    var kind = action === "kill" ? "kill" : "action"
    var key = sessionKey({ host: host, name: name })
    var meta = kind === "kill" ? { killPendingKey: key }
      : { pendingKey: key, actionName: action, actionDismiss: dismissOnSuccess === true }
    var command = [root.script]
    if (host) command.push("--host", host)
    command.push(action, name)
    if (extra !== undefined && extra !== "") command.push(extra)
    if (HerdrActions.start(ownerToken, kind, command, meta)) return true
    actionError = "busy: " + (kind === "kill" ? "kill" : actionName) + " is still running"
    return false
  }

  function run(action, session, extra, dismissOnSuccess) {
    if (!session || session.kind === "app" || !validName(session.name)) return false
    return launch(action, session.host, session.name, extra, dismissOnSuccess)
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
    if (session && session.kind === "app") { focusAgent(session, (session.agentList || [])[0]); return }
    if (!session || !validName(session.name)) return
    run("open", session, undefined, true)
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
    if (session.kind === "app") {
      if (!validHcAddress(agent.pane) || appRowNotLive(session)) return
      appLaunch(["app-focus", agent.pane], "app-focus", true, sessionKey(session), false)
      return
    }
    if (!validPane(agent.pane)) { openSession(session); return }
    if (!validName(session.name)) return
    run("focus", session, agent.pane, true)
  }

  // Deleting throws away a session that is already stopped - its directory and
  // the state herdr kept in it - which is what clears it out of the list for
  // good. A running server is killed rather than deleted; the two never apply
  // to the same row. The shared session is herdr's own and is not deleted from
  // here at all.
  function removeSession(session) {
    if (!session || session.isDefault || session.running || hostUnchecked(session)) return
    run("delete", session)
  }

  // How a running server is ended here, and the only way: `herdr session stop`
  // asks over herdr's own socket, so a server too wedged to read that socket
  // never hears the request, and the button that sent it looked broken at
  // exactly the moment you needed it. Signalling the process works either way,
  // so there is no reason to keep both.
  //
  // The shared session is killed like any other. It wedges like any other.
  function killSession(session) {
    if (!session || !session.running || !validName(session.name) || hostUnchecked(session)) return
    run("kill", session)
  }

  // Both of these destroy something a keystroke away from the cursor, so both
  // stop to ask. Killing takes the server and everything running inside it
  // without asking anything to finish; deleting throws away the state herdr
  // kept for a stopped session. Neither can be taken back, and the two share
  // the destroy key, so a mistaken press lands on whichever the row offers.
  //
  // The dialog opens on Cancel rather than on the confirming side, which is
  // ConfirmDialog's own default: a dialog that destroys something on a
  // reflexive Enter is worse than no dialog, because it trains the reflex.
  function askKill(session) {
    if (session && session.kind === "app") { askKillAgent(session); return }
    if (!session || !session.running || !validName(session.name) || hostUnchecked(session)) return
    ask(session, "kill")
  }

  function askDelete(session) {
    if (!session || session.kind === "app" || session.isDefault || session.running || hostUnchecked(session)) return
    ask(session, "delete")
  }

  // A host that has not answered since the menu opened shows rows from before,
  // or none: acting on them would be acting on a guess.
  function hostUnchecked(session) {
    if (!session.host) return false
    var state = stateOfHost(session.host)
    if (state !== "checking" && state !== "down") return false
    actionError = session.host + " not checked yet"
    return true
  }

  function ask(session, action) {
    confirmTarget = session
    confirmAction = action
    confirmOpen = true
    if (activeCard) activeCard.beginConfirm()
  }

  function closeConfirm() {
    confirmOpen = false
    confirmTarget = null
    confirmAgent = null
    confirmAction = ""
    if (activeCard) activeCard.endConfirm()
  }

  function confirmPending() {
    var target = confirmTarget
    var action = confirmAction
    var agent = confirmAgent
    closeConfirm()
    if (!target) return
    // The list may have changed while the dialog was open: act on what is
    // there now, and only if it is still what was asked about.
    var current = null
    var key = sessionKey(target)
    for (var i = 0; i < sessions.length; i++)
      if (sessionKey(sessions[i]) === key) current = sessions[i]
    if (action === "appkill") {
      var live = current && agent && (current.agentList || []).some(function (a) { return a.pane === agent.pane })
      if (!live) { actionError = String(agent ? agent.pane : "agent") + " changed; nothing done"; return }
      appKill(current, agent)
      return
    }
    if (!current || (action === "kill" && !current.running)
        || (action === "delete" && current.running)) {
      actionError = sessionLabel(target) + " changed; nothing done"
      return
    }
    if (action === "kill") killSession(current)
    else if (action === "delete") removeSession(current)
  }

  function confirmMessage() {
    if (!confirmTarget) return ""
    if (confirmAction === "appkill" && confirmAgent) {
      var cascade = confirmAgent.cascade || []
      var msg = "End " + cleanTitle(confirmAgent.title) + " (" + confirmAgent.pane + ")?"
        + " It is not asked to finish first."
      if (cascade.length > 0)
        msg += " This also ends " + cascade.length + ": " + cascade.map(function (c) {
          return c.address + (c.title ? " " + cleanTitle(c.title) : "")
        }).join(", ") + "."
      return msg
    }
    if (confirmAction === "delete")
      return "Delete " + sessionLabel(confirmTarget)
        + "? Everything herdr kept for this session goes with it."
    return "Kill the server for " + sessionLabel(confirmTarget)
      + "? Nothing running inside it is asked to stop first."
  }

  // What the arrow keys walk: the agents, in the order they are drawn, not the
  // servers holding them. A server is a place, an agent is the work, and the
  // work is what you came to reach.
  //
  // A session with no agents still gets a row of its own, or a stopped session
  // and an empty server would drop out of the keyboard entirely and there
  // would be no way to open or delete one without the mouse.
  readonly property var navRows: navRowsFor(sessions)

  function navRowsFor(all) {
    var rows = []
    for (var i = 0; i < all.length; i++) {
      var agents = all[i].agentList || []
      if (agents.length === 0) {
        rows.push({ sessionIndex: i, agentIndex: -1 })
        continue
      }
      for (var j = 0; j < agents.length; j++)
        rows.push({ sessionIndex: i, agentIndex: j })
    }
    return rows
  }

  // What a row is, independent of where it sits: an agent by its pane, a
  // session with no agents by its name.
  function rowKey(list, row) {
    var session = row ? list[row.sessionIndex] : null
    if (!session) return ""
    if (row.agentIndex < 0) return sessionKey(session) + "\u0000"
    var agent = (session.agentList || [])[row.agentIndex]
    return agent ? agentKey(session, agent.pane) : ""
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

  function moveCursor(delta) {
    if (navRows.length === 0) return
    cursorPlaced = true
    var next = cursor < 0 ? (delta > 0 ? 0 : navRows.length - 1) : cursor + delta
    if (next < 0) next = 0
    if (next > navRows.length - 1) next = navRows.length - 1
    cursor = next
    var row = rowAt(next)
    if (row) showRow(row.sessionIndex, row.agentIndex)
  }

  function showRow(sessionIndex, agentIndex) {
    if (activeCard) activeCard.showRow(sessionIndex, agentIndex)
  }

  // Enter goes as deep as the cursor is: onto the agent when it is on one, and
  // onto the session when the row is a session with nothing in it.
  function activateCursor() {
    var session = sessionAt(cursor)
    if (!session) return
    var agent = agentAt(cursor)
    if (agent) focusAgent(session, agent)
    else openSession(session)
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
    cursorPlaced = true
    for (var i = 0; i < navRows.length; i++)
      if (navRows[i].sessionIndex === sessionIndex && navRows[i].agentIndex === agentIndex) {
        cursor = i
        return
      }
  }

  function cursorToSession(sessionIndex) {
    cursorPlaced = true
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
                 + (state === "ok" ? "\u25cf" : state === "empty" ? "\u25cb"
                    : state === "checking" ? "\u2026" : "\u2013"))
    }
    return parts.join("   ")
  }

  // Asked for by a key in the card, answered by whichever surface can show an
  // input. The bar panel does not connect it, so `n` does nothing there.
  signal newSessionRequested()
  function requestNew() {
    var session = sessionAt(cursor)
    if (appRowNotLive(session)) return
    newSessionRequested()
  }

  // The same arrangement for `a`: only when the cursor is on an agent, since a
  // prompt goes to one pane and a bare session has none to receive it.
  signal promptRequested()
  function requestPrompt() {
    if (!agentAt(cursor) || appRowNotLive(sessionAt(cursor))) return
    promptRequested()
  }

  // An agent in the middle of something, or one herdr cannot read. Typing into
  // it interleaves with its own output, so the menu asks before sending.
  function agentBusy(status) {
    return status === "working" || status === "blocked" || status === "unknown"
  }

  // Create on the host the cursor is on, so `n` while reading razer's
  // sessions makes one on razer.
  function hostAtCursor() {
    var session = sessionAt(cursor)
    return session && session.host ? String(session.host) : ""
  }

  function newSession(host, name, dir) {
    if (!validName(name)) {
      actionError = "not a valid session name"
      return false
    }
    return launch("new", host, name, dir, false)
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
    if (session.kind === "app")
      return appRowStale(session) ? "not live"
        : "desktop app" + (session.host ? "  \u00b7  " + session.host : "")
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
    if (session.readable === false) return "unreadable"
    var n = session.agents || 0
    if (n === 0) return "no agents"
    var label = n === 1 ? "1 agent" : n + " agents"
    var hidden = session.hiddenAgents || 0
    return hidden > 0 ? label + " (" + hidden + " not shown)" : label
  }

  // The one word worth colouring: blocked means an agent is waiting on you,
  // working means it is busy. Anything else is quiet and says nothing.
  // Waiting beats finished beats busy, everywhere a state has to be reduced
  // to one thing: a question on screen outranks work that has already ended,
  // and both outrank an agent that is simply busy.
  // The one word that says what a count of agents is doing: `c` is anything
  // with blocked, done and working counts - a session, or the herd's totals.
  function priority(c) {
    if (!c) return "idle"
    if ((c.blocked || 0) > 0) return "blocked"
    if ((c.done || 0) > 0) return "done"
    if ((c.working || 0) > 0) return "working"
    return "idle"
  }

  function noteLabel(session) {
    if (!session || !session.running) return ""
    var p = priority(session)
    if (p === "blocked") return session.blocked + " needs you"
    if (p === "done") return session.done + " done"
    if (p === "working") return session.working + " working"
    return ""
  }

  // Herdr puts a spinner glyph in front of a title while its agent is working,
  // so the same task moves left and right as it ticks over. Dropping any run
  // of leading symbols keeps the titles in one column; the status dot beside
  // them says the same thing without moving.
  function cleanTitle(title) {
    var s = String(title || "").trim()
    // Only what herdr's spinners are made of, so a CJK or emoji title stays.
    var stripped = s.replace(/^[\u2800-\u28FF\u2500-\u257F\u2733\u273B\u25CF\u25D0\u25D3\u25D1\u25D2\u2022 ]+/, "").trim()
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

  // The address of the work: the workspace it sits in, then the tab inside
  // that workspace. Either half can be empty - herdr only hands back a label
  // a tab or workspace was given - so the line is whichever parts exist, and
  // nothing at all when neither does.
  function agentPlace(agent) {
    if (!agent) return ""
    var parts = []
    if (agent.workspace) parts.push(agent.workspace)
    if (agent.tab) parts.push(agent.tab)
    return parts.join("  ·  ")
  }

  function agentColor(status) {
    if (status === "blocked") return root.urgent
    if (status === "done") return root.finished
    if (status === "working") return root.workingForeground
    if (status === "error") return root.urgent
    return Qt.alpha(root.foreground, 0.78)
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
  function agentNote(status, kind) {
    if (status === "error") return "error"
    if (status === "blocked") return kind ? "needs you: " + kind : "needs you"
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
    var p = priority(session)
    if (p === "blocked") return root.urgent
    if (p === "done") return root.finished
    return root.workingForeground
  }

  function statusColor(session) {
    if (!session || !session.running) return Qt.alpha(root.foreground, 0.62)
    var p = priority(session)
    if (p === "blocked") return root.urgent
    if (p === "done") return root.finished
    if (p === "working") return root.workingForeground
    return Qt.alpha(root.foreground, 0.82)
  }

  function badgeColor() {
    if (appMark) return root.urgent
    var p = priority({ blocked: blockedCount, done: doneCount, working: workingCount })
    if (p === "blocked") return root.urgent
    if (p === "done") return root.finished
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
  // One line under the title, most specific first: what you just pressed, then
  // the list failing, then the desktop app failing, then what was left out.
  function errorLine() {
    if (actionError !== "") return actionError
    if (errorText !== "") return errorText
    if (appError !== "") return appError
    if (!reachable) return "Could not reach herdr."
    return hiddenSessions > 0 ? hiddenSessions + " sessions not shown" : ""
  }

  // Every part that is not zero, and the failures: the classic list failing
  // is said next to the app counts, which stay true while it fails.
  function tooltipText() {
    var parts = []
    if (!reachable) parts.push(errorText || "could not reach herdr")
    if (runningCount > 0) parts.push(runningCount + (runningCount === 1 ? " herdr server" : " herdr servers"))
    if (agentCount > 0) parts.push(agentCount + (agentCount === 1 ? " agent" : " agents"))
    if (blockedCount > 0) parts.push(blockedCount + " waiting on you")
    if (doneCount > 0) parts.push(doneCount + " finished")
    if (workingCount > 0) parts.push(workingCount + " working")
    if (unreadableCount > 0) parts.push(unreadableCount + " unreadable")
    if (appStale) parts.push("herdr-core not reachable")
    if (parts.length === 0) return "Herdr: no sessions"
    return reachable ? parts.join(", ") : "Herdr: " + parts.join(", ")
  }

  // A session name is only unique on its own host, so every key the UI
  // matches rows by carries the host too.
  function sessionKey(session) {
    if (session.kind === "app") return "app\u0000" + (session.host || "") + "\u0000" + session.spaceId
    return (session.host || "") + "\u0000" + session.name
  }

  function agentKey(session, pane) {
    return sessionKey(session) + "\u0000" + String(pane)
  }

  // Everything that is asking for something right now, and which of those is
  // new since the previous poll. A tie inside one poll goes to the highest
  // state_change_seq, which is the best herdr can tell us; a tie there too
  // goes to nobody, because a dot that blinks on the wrong agent is worse
  // than one that does not blink at all.
  function updateAttention(sessionList) {
    var wantingNow = {}
    var freshest = null
    var tied = false
    for (var i = 0; i < sessionList.length; i++) {
      var session = sessionList[i]
      var agents = session.agentList || []
      for (var j = 0; j < agents.length; j++) {
        if (!root.agentWants(agents[j].status)) continue
        var key = root.agentKey(session, agents[j].pane)
        wantingNow[key] = true
        if (root.wantingBefore[key]) continue
        var seq = agents[j].seq || 0
        // App seqs are epoch ms and classic ones are herdr's counters: never
        // compared across. Within a scale the seq decides; across, classic wins.
        var app = session.kind === "app"
        if (freshest === null || (app !== freshest.app ? !app : seq > freshest.seq)) {
          freshest = { key: key, seq: seq, app: app }
          tied = false
        } else if (app === freshest.app && seq === freshest.seq) {
          tied = true
        }
      }
    }

    // An agent that stopped asking stops blinking, even if nobody took its
    // place: the blink is about a question still standing, not about history.
    if (root.attentionKey !== "" && !wantingNow[root.attentionKey])
      root.attentionKey = ""
    // Each new key starts an episode, which blinks for a minute.
    if (freshest !== null && root.attentionPrimed) {
      root.attentionKey = tied ? "" : freshest.key
      if (root.attentionKey !== "") {
        root.blinkExpired = false
        blinkTimer.restart()
      }
    }
    if (root.attentionKey === "") blinkTimer.stop()

    root.wantingBefore = wantingNow
    root.attentionPrimed = true
  }

  function blinking(session, agent) {
    if (!agent || root.attentionKey === "" || root.blinkExpired) return false
    return root.agentKey(session, agent.pane) === root.attentionKey
  }

  Timer {
    id: blinkTimer
    interval: 60000
    onTriggered: root.blinkExpired = true
  }

  // ---- text size ----

  // A read is in flight from start; a change during one is read after it.
  property bool textReading: true
  property bool textReadAgain: false
  property bool textMissing: false
  readonly property string textScalePath:
    (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
    + "/omarchy-herdr/text-scale"

  // Steps of a tenth between 0.8 and 1.6, rounded so twenty presses do not
  // drift. Only a key press writes the file: a load never does, so two
  // surfaces cannot feed each other.
  function setTextScale(value) {
    var v = Math.round(Math.max(0.8, Math.min(1.6, value)) * 10) / 10
    textScale = v
    textFile.setText(String(v))
  }
  function textBigger() { setTextScale(textScale + 0.1) }
  function textSmaller() { setTextScale(textScale - 0.1) }
  function textReset() { setTextScale(1.0) }

  // Anything that is not a number in range leaves the size as it is.
  function textFileChanged() {
    if (textReading) { textReadAgain = true; return }
    textReading = true
    textFile.reload()
  }
  function textFileLoaded(text) {
    textReading = false
    // A file that isn't there yet can't be watched; each poll looks again.
    textMissing = text === null
    if (text !== null) applyTextScale(text)
    if (textReadAgain) { textReadAgain = false; textReading = true; textFile.reload() }
  }

  function applyTextScale(text) {
    var t = String(text).trim()
    var v = t === "" ? NaN : Number(t)
    if (isFinite(v) && v >= 0.8 && v <= 1.6) textScale = Math.round(v * 10) / 10
  }

  // The file is the one source of truth, watched so a change on another
  // surface lands here. A failed write keeps the size for this session.
  FileView {
    id: textFile
    path: root.textScalePath
    watchChanges: true
    printErrors: false
    // Quickshell 0.3.2 ignores reload() while a read is in flight, so a
    // change that lands during a read is queued and read once it finishes.
    onLoaded: root.textFileLoaded(text())
    onLoadFailed: root.textFileLoaded(null)
    onFileChanged: root.textFileChanged()
  }

  // ---- herdr-core and herdr-app ----------------------------------------

  function appMachineState(host) {
    for (var i = 0; i < appMachines.length; i++)
      if (appMachines[i].name === host) return appMachines[i].state
    return ""
  }

  // Not live: the subscription is down or the last read failed, or the row's
  // machine is not connected. Nothing is acted on a row in that state.
  function appRowStale(session) {
    if (!session || session.kind !== "app") return false
    return !hcAvailable || appStale || (session.host ? appMachineState(session.host) !== "connected" : false)
  }

  function appRowNotLive(session) {
    if (!appRowStale(session)) return false
    actionError = (session.host || "desktop app") + " is not live"
    return true
  }

  // Action and kill use separate slots so neither blocks the other.
  function appLaunch(command, label, dismissOnSuccess, key, killing, refs) {
    var kind = killing ? "kill" : "action"
    var meta = killing ? { killPendingKey: key, session: refs.session, agent: refs.agent }
      : { pendingKey: key, actionName: label, actionDismiss: dismissOnSuccess === true }
    if (HerdrActions.start(ownerToken, kind, [root.script].concat(command), meta)) return true
    actionError = "busy: " + (killing ? "kill" : actionName) + " is still running"
    return false
  }

  function requestInterrupt() {
    var session = sessionAt(cursor), agent = agentAt(cursor)
    if (!session || !agent || session.kind !== "app" || !validHcAddress(agent.pane)) return
    if (appRowNotLive(session)) return
    appLaunch(["app-interrupt", agent.pane], "app-interrupt", false, sessionKey(session), false)
  }

  function askKillAgent(session) {
    var agent = agentAt(cursor)
    if (!agent || sessionAt(cursor) !== session || !validHcAddress(agent.pane)) return
    if (appRowNotLive(session)) return
    confirmAgent = agent
    ask(session, "appkill")
  }

  function appKill(session, agent) {
    if (appRowNotLive(session)) return
    appLaunch(["app-kill", agent.pane, String(agent.cascadeKey || "")], "kill", false,
              sessionKey(session), true, { session: session, agent: agent })
  }

  // Always three arguments, so an empty directory or machine stays in place.
  function newAppSpace(host, name, dir) {
    if (!validName(name)) {
      actionError = "not a valid session name"
      return false
    }
    if (!hcAvailable || appStale || (host && appMachineState(host) !== "connected")) {
      actionError = (host || "desktop app") + " is not live"
      return false
    }
    return appLaunch(["app-new", name, dir || "", host || ""], "new", false, "", false)
  }

  function appStart() {
    if (!hcAvailable) return
    appGen++
    appSubProc.launched = true
    appSubProc.exited = false
    appSubProc.running = true
    appWatchdog.restart()
  }

  // Every line proves the subscription alive. Anything but a heartbeat means
  // "something changed", and only that; its fields are never read.
  function appLine(line) {
    appWatchdog.restart()
    appSubLive = true
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (!msg || typeof msg !== "object") return
    for (var k in msg) if (msg[k] === "heartbeat") return
    appListRetries = 0
    appRetry.stop()
    if (appListProc.open) appDirty = true
    else if (!appCoalesce.running) appCoalesce.start()
  }

  function appRunList() {
    if (!hcAvailable) return
    if (appListProc.running || appListProc.open) { appDirty = true; return }
    appListProc.gotOut = false
    appListProc.gotExit = false
    appListProc.open = true
    appListProc.gen = appGen
    appListProc.command = remote ? [root.script, "app-list", "--remote"] : [root.script, "app-list"]
    appListProc.running = true
  }

  // The subscription ended or went quiet: mark stale, retry after a longer wait.
  function appSubDown() {
    if (!hcAvailable || appBackoff.running) return
    appWatchdog.stop()
    appCoalesce.stop()
    appRetry.stop()
    appListRetries = 0
    if (appSubProc.running) { appSubProc.launched = false; appSubProc.running = false }
    appSubLive = false
    appStale = true
    appBackoff.interval = nextBackoff()
    appBackoff.start()
  }

  function nextBackoff() {
    var wait = appBackoffCur > 0 ? appBackoffCur : appBackoffMs
    appBackoffCur = Math.min(wait * 2, 60000)
    return wait
  }

  function appSubExited() {
    if (!appSubProc.launched) return
    appSubProc.launched = false
    appSubProc.exited = true
    appSubDown()
  }

  // No hc to run: no rows, and no retry.
  function appSubStartFailed() {
    appSubProc.launched = false
    appWatchdog.stop()
    hcAvailable = false
    appGen++
    appRetry.stop()
    appStale = false
    appSessions = []
    appHostSessions = []
    appMachines = []
    rebuild()
  }

  function applyAppList(text, code, gen) {
    var data = null
    try { data = JSON.parse(text) } catch (e) { data = null }
    if (gen !== appGen) {
      // A stale answer changes nothing, but a change that came meanwhile still needs a run.
    } else if (data && data.ok === true && code === 0) {
      var rows = data.sessions || []
      appSessions = rows.filter(function (r) { return !r.host })
      appHostSessions = remote ? rows.filter(function (r) { return r.host }) : []
      appMachines = data.machines || []
      appError = ""
      if (appSubLive) appStale = false
      appListRetries = 0
      appRetry.stop()
      appBackoffCur = 0
      rebuild()
    } else {
      appStale = true
      appError = data && data.error ? String(data.error)
        : code > 0 ? "herdr-sessions exited with code " + code : "unexpected output from herdr-sessions"
      // Heartbeats keep the watchdog quiet, so nothing else would ask again.
      // Two retries, then the stale mark waits for a real event or a restart.
      if (hcAvailable && appSubLive && !appRetry.running && appListRetries < 2) {
        appListRetries++
        appRetry.interval = nextBackoff()
        appRetry.start()
      }
    }
    if (appDirty) { appDirty = false; appRunList() }
  }

  function applyPayload(text, code) {
    if (textMissing) textFileChanged()
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true && !(code > 0)
      errorText = data.error || (code > 0 ? "herdr-sessions exited with code " + code : "")
      if (!reachable) return
      localSessions = data.sessions || []
      hiddenSessions = data.hidden || 0
      rebuild()
    } catch (e) {
      reachable = false
      errorText = "unexpected output from herdr-sessions"
    }
  }

  // The poll rate: faster while the panel is open, and while anything can
  // change by itself. A done-only herd is waiting for you, not for herdr.
  function pollInterval() {
    if (opened) return 3000
    return blockedCount > 0 || workingCount > 0 ? 5000 : 20000
  }

  // A host list that changed drops what was kept for the hosts that left.
  function applyHosts(list) {
    var next = {}, state = {}
    for (var i = 0; i < list.length; i++) {
      if (hostSessions[list[i]] !== undefined) next[list[i]] = hostSessions[list[i]]
      if (hostState[list[i]] !== undefined) state[list[i]] = hostState[list[i]]
    }
    hostNames = list
    hostSessions = next
    hostState = state
    rebuild()
  }

  onOpenedChanged: {
    if (opened) {
      actionError = ""
      if (remote) claimActions()
      hostState = ({})
      // A poll still exiting from the last opening starts over when it does.
      for (var p = 0; p < hostPolls.count; p++) {
        var old = hostPolls.objectAt(p)
        if (old && old.running) old.restartPending = true
      }
      refresh()
      // The list may still be the one from the last poll, so place the cursor
      // on what we know now and again when the fresh answer lands.
      cursor = bestRow()
      cursorPlaced = false
    } else {
      // Closing stops every ssh call, including the ones still out, and
      // whatever they were going to say is out of date.
      pollGen++
      closeConfirm()
      for (var i = 0; i < hostPolls.count; i++) {
        var poll = hostPolls.objectAt(i)
        if (poll) poll.running = false
      }
      cursor = -1
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
    onLoaded: root.applyHosts(root.parseHosts(text()))
    onLoadFailed: root.applyHosts([])
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
      property string kind: "host"
      property int gen: 0
      property bool restartPending: false
      property string out: ""
      property int code: 0
      property bool gotOut: false
      property bool gotExit: false
      property bool open: false
      function start() {
        gen = root.pollGen
        gotOut = false
        gotExit = false
        open = true
        command = [root.script, "--host", modelData, "list"]
        running = true
      }
      stdout: StdioCollector {
        onStreamFinished: root.storeResult(hostProc, "out", text)
      }
      onExited: function (exitCode) { root.storeResult(hostProc, "exit", exitCode) }
      onRunningChanged: if (!running) root.startFailed(hostProc)
    }
  }

  Process {
    id: listProc
    property string kind: "list"
    property string out: ""
    property int code: 0
    property bool gotOut: false
    property bool gotExit: false
    property bool open: false
    stdout: StdioCollector {
      onStreamFinished: root.storeResult(listProc, "out", text)
    }
    onExited: function (exitCode) { root.storeResult(listProc, "exit", exitCode) }
    onRunningChanged: if (!running) root.startFailed(listProc)
  }

  Process {
    id: appSubProc
    property bool launched: false
    property bool exited: false
    command: ["hc", "events", "--json"]
    stdout: SplitParser {
      onRead: function (line) { root.appLine(line) }
    }
    onExited: root.appSubExited()
    onRunningChanged: if (!running && launched && !exited) root.appSubStartFailed()
  }

  Process {
    id: appListProc
    property string kind: "applist"
    property int gen: 0
    property string out: ""
    property int code: 0
    property bool gotOut: false
    property bool gotExit: false
    property bool open: false
    stdout: StdioCollector {
      onStreamFinished: root.storeResult(appListProc, "out", text)
    }
    onExited: function (exitCode) { root.storeResult(appListProc, "exit", exitCode) }
    onRunningChanged: if (!running) root.startFailed(appListProc)
  }

  // The first change line waits this long for its neighbours, and later ones
  // do not push it back, so a burst costs one app-list.
  Timer {
    id: appCoalesce
    interval: root.appCoalesceMs
    onTriggered: root.appRunList()
  }

  Timer {
    id: appWatchdog
    interval: root.appWatchdogMs
    onTriggered: root.appSubDown()
  }

  Timer {
    id: appRetry
    onTriggered: root.appRunList()
  }

  Timer {
    id: appBackoff
    onTriggered: root.appStart()
  }

  Component.onCompleted: {
    ownerToken = HerdrActions.register(remote)
    appStart()
  }
  Component.onDestruction: HerdrActions.unregister(ownerToken)

  Connections {
    target: HerdrActions
    function onFinished(owner, kind, meta, result) {
      if (owner === root.ownerToken) root.onResult(kind, meta, result)
    }
    function onUnclaimedChanged() {
      if (root.remote && root.opened) root.claimActions()
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
    interval: root.pollInterval()
    // The bar keeps its badge current all the time. A surface that reaches
    // other machines polls only while it is open, so closing the menu stops
    // every ssh call; opening it refreshes straight away.
    running: !root.remote || root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
