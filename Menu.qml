import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The herd on a keybind: the same card the bar widget drops down, summoned
// over whatever you are working in and driven from the keyboard.
//
// A bar widget is a thing you point at. Reaching an agent should not need the
// mouse at all, so this entry point puts the same list on a chord, centred and
// holding the keyboard while it is up.
//
// It owns a HerdrModel of its own rather than sharing the bar's: a plugin's
// entry points are separate component trees, and a model each keeps the
// summoned menu working on a machine whose bar does not carry the widget.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property var shell: null
  property var manifest: null

  property bool opened: false

  // What HerdrModel expects of a surface. The menu is never pinned - it is
  // the opposite of a panel you leave lying about - so the pin is a no-op and
  // the card hides its button.
  readonly property bool pinned: false
  readonly property bool pinnable: false
  readonly property var activeCard: card
  readonly property color foreground: Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: Style.font.family
  function togglePin(fromKey) {}

  // The output Hyprland has focused, which is where a keyboard-summoned
  // surface belongs - the same rule Omarchy's own bar uses to route a panel.
  // Resolved on the way in rather than bound, so the menu does not jump to
  // another screen while you are reading it.
  property var targetScreen: null

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    // No focused output yet, or a name that matches nothing: any screen beats
    // a surface the compositor has to place on its own.
    return screens.length > 0 ? screens[0] : null
  }

  // The menu takes its sizes from the theme - Style.font for text,
  // Style.space for the card - like the rest of the desktop, and Hyprland's
  // per-monitor scale does the rest. An earlier version also multiplied them
  // by the screen's height, which made the menu about 1.7x too large on a
  // 1440p panel; don't bring that back. The text size is the model's
  // (herd.textScale), shared with the bar and kept in a file.
  // The reply may use 40 % of the height the menu can ever have. That is
  // fixed by the screen, so the card around it can size from it without a loop.
  readonly property real replyBudget: Math.max(Style.space(40),
    (surface ? surface.parent.height : 600) * 0.4)
  readonly property int cardWidth: Math.round(Style.space(760) * herd.textScale)

  // This machine's name, for a new session that names no other host.
  FileView {
    id: hostFile
    path: "/etc/hostname"
  }
  readonly property string localHost: String(hostFile.text() || "").trim()

  // Plugin lifecycle hooks. The host calls open(payloadJson) after
  // `omarchy-shell shell summon nixarchy.herdr ...` and close() when hidden.
  function open(payloadJson) {
    root.targetScreen = root.focusedScreen()
    // A prompt whose process never reported its exit must not lock the line
    // for good; one that is still running keeps it locked.
    if (!promptProc.running) root.awaitingExit = false
    root.opened = true
    herd.refresh()
    Qt.callLater(function() { card.forceActiveFocus() })
  }

  function close() {
    // A prompt still waiting on its agent is abandoned with the menu, so no
    // process outlives the surface that asked for it.
    root.cancelInput()
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  HerdrModel {
    id: herd
    host: root
    // Only the menu reaches other machines: the bar's badge stays local so a
    // host that is down can never slow it.
    remote: true
    onNewSessionRequested: root.beginInput("new")
    onPromptRequested: root.beginInput("prompt")
    onActionFinished: function (action, ok) { root.actionDone(action, ok) }
  }

  // One input line under the card, used two ways: "new" takes a session name
  // and an optional absolute directory, "prompt" takes text for one agent.
  // Empty when the line is closed.
  property string inputMode: ""
  readonly property bool inputOpen: inputMode !== ""
  property string newHost: ""
  // What `n` was pressed on, captured with the host: "app" makes a space in
  // the desktop app, anything else a session.
  property string newKind: ""
  // The agent a prompt goes to, captured when `a` was pressed so a refresh
  // moving the cursor cannot redirect it.
  property var promptTarget: null
  property string promptReply: ""
  // Seconds since the prompt was sent, counted only while it is awaited.
  property int waitSecs: 0
  property bool promptConfirmOpen: false
  // A `new` is running: the line is read-only until its result comes in.
  property bool newPending: false
  // From the moment a prompt starts until its process has exited. Esc stops
  // waiting at once, but a new prompt waits for the old one to be gone.
  property bool awaitingExit: false

  function beginInput(mode) {
    if (root.awaitingExit) {
      herd.actionError = "a prompt is still waiting; Esc stops waiting"
      return
    }
    // The line holds the name of a session still being created; replacing it
    // would lose the text a failure is meant to give back.
    if (root.newPending) {
      herd.actionError = "busy: new is still running"
      return
    }
    if (mode === "prompt") {
      var session = herd.sessionAt(herd.cursor)
      var agent = herd.agentAt(herd.cursor)
      if (!session || !agent) return
      root.promptTarget = { kind: session.kind === "app" ? "app" : "", host: String(session.host || ""),
                            session: session.kind === "app" ? session.spaceId : session.name,
                            pane: agent.pane, title: herd.cleanTitle(agent.title) }
    } else {
      var at = herd.sessionAt(herd.cursor)
      root.newHost = herd.hostAtCursor()
      root.newKind = at && at.kind === "app" ? "app" : ""
    }
    root.promptReply = ""
    root.inputMode = mode
    newField.text = ""
    Qt.callLater(function () { newField.forceActiveFocus() })
  }

  function cancelInput() {
    promptProc.running = false
    root.newPending = false
    root.inputMode = ""
    root.promptTarget = null
    root.promptReply = ""
    root.promptConfirmOpen = false
    waitTimer.running = false
    newField.text = ""
    Qt.callLater(function () { card.forceActiveFocus() })
  }

  function submitInput() {
    if (root.inputMode === "new") root.submitNew()
    else if (root.inputMode === "prompt") root.submitPrompt(false)
  }

  function submitNew() {
    var words = newField.text.trim().split(/\s+/)
    var name = words.length > 0 ? words[0] : ""
    var dir = words.length > 1 ? words.slice(1).join(" ") : ""
    if (name === "") { root.cancelInput(); return }
    // False means it did not start and the model says why; the line stays.
    var started = root.newKind === "app" ? herd.newAppSpace(root.newHost, name, dir)
      : herd.newSession(root.newHost, name, dir)
    if (started) root.newPending = true
  }

  // Only the model's `new` result matters here: a kill or a poll finishing
  // must not close the line or the menu.
  function actionDone(action, ok) {
    if (action !== "new" || !root.newPending) return
    root.newPending = false
    if (ok) {
      root.cancelInput()
      root.close()
    } else {
      Qt.callLater(function () { newField.forceActiveFocus() })
    }
  }

  // The target's state as of the latest poll, not as of the key press: an
  // agent that started working while you typed is still asked about.
  function targetStatus() {
    var t = root.promptTarget
    if (!t) return "unknown"
    for (var i = 0; i < herd.sessions.length; i++) {
      var s = herd.sessions[i]
      if ((s.kind === "app") !== (t.kind === "app")) continue
      if ((t.kind === "app" ? s.spaceId : s.name) !== t.session || String(s.host || "") !== t.host) continue
      var agents = s.agentList || []
      for (var j = 0; j < agents.length; j++)
        if (agents[j].pane === t.pane) return agents[j].status
    }
    return "unknown"
  }

  function submitPrompt(confirmed) {
    var text = newField.text
    if (!root.promptTarget || text.trim() === "" || root.awaitingExit) return
    if (!confirmed && herd.agentBusy(root.targetStatus())) {
      root.promptConfirmOpen = true
      promptConfirm.dialog.selectedIndex = 0
      Qt.callLater(function () { promptConfirm.forceActiveFocus() })
      return
    }
    var t = root.promptTarget
    // Asked again here, not only when `a` was pressed: the subscription may
    // have dropped while the text was being typed.
    if (t.kind === "app" && herd.appRowNotLive({ kind: "app", host: t.host })) return
    var command = [herd.script]
    if (t.kind === "app") {
      command.push("app-prompt", t.pane)
      if (confirmed === true) command.push("--force")
    } else {
      if (t.host) command.push("--host", t.host)
      command.push("prompt", t.session, t.pane)
    }
    // C1 controls (U+0080-U+009F) are two bytes in UTF-8, so the script's
    // byte-wise tr cannot catch them; a terminal still acts on them.
    text = text.replace(/[\u0080-\u009f]/g, "")
    promptProc.text = text
    promptProc.command = command
    // Closed after each write; a second prompt needs it open again before
    // the process starts.
    promptProc.stdinEnabled = true
    root.promptReply = "waiting for " + t.title + "\u2026"
    root.waitSecs = 0
    waitTimer.running = true
    promptProc.gotOut = false
    promptProc.gotExit = false
    root.awaitingExit = true
    promptProc.running = true
  }

  // Both of a run's signals (stdout and exit) come in either order; the
  // second one completes it.
  function storePrompt(which, value) {
    if (which === "out") { promptProc.out = value; promptProc.gotOut = true }
    else { promptProc.code = value; promptProc.gotExit = true }
    if (!promptProc.gotOut || !promptProc.gotExit) return
    promptProc.gotOut = false
    promptProc.gotExit = false
    root.awaitingExit = false
    root.promptDone(promptProc.out, promptProc.code)
  }

  // Quickshell reports a command that could not start only by `running`
  // going false; the exit and the output never come.
  function promptStartFailed() {
    if (!root.awaitingExit || promptProc.gotExit) return
    promptProc.gotOut = false
    root.awaitingExit = false
    root.promptDone(JSON.stringify({ ok: false, error: "could not start herdr-sessions" }), -1)
  }

  // The text is cleared only when it was sent. A run for a line that has been
  // cancelled since has nowhere to show anything.
  function promptDone(out, code) {
    waitTimer.running = false
    if (root.inputMode !== "prompt") return
    var data = null
    try { data = JSON.parse(out) } catch (e) { data = null }
    if (!data) {
      root.promptReply = "no reply"
    } else if (data.ok === true && code === 0) {
      var excerpt = root.replyExcerpt(data.output)
      root.promptReply = data.status === "timeout"
        ? "still working after 5 min" + (excerpt ? "\n" + excerpt : "")
        : (excerpt || "(no output)")
      newField.text = ""
    } else {
      root.promptReply = "could not send: "
        + (data.error || (code !== 0 ? "exited with code " + code : "unknown error"))
    }
  }

  function closeConfirm() {
    root.promptConfirmOpen = false
    Qt.callLater(function () { newField.forceActiveFocus() })
  }

  // The tail of the agent's screen, as drawn: indentation kept so code and
  // lists stay readable. At most 40 lines and 4000 characters, cut at a line
  // start; one longer last line keeps its end behind an ellipsis.
  function replyExcerpt(output) {
    var lines = String(output || "").replace(/\s+$/, "").split("\n").slice(-40)
    var text = lines.join("\n")
    while (text.length > 4000 && lines.length > 1) {
      lines.shift()
      text = lines.join("\n")
    }
    return text.length > 4000 ? "\u2026" + text.slice(-4000) : text
  }

  // What the line says it is for. A new session names where it will run, so
  // the host comes last and is the part that survives eliding.
  function inputLabelText() {
    if (root.inputMode === "prompt" && root.promptTarget)
      return (root.promptTarget.host ? root.promptTarget.host + " \u00b7 " : "") + root.promptTarget.title
    return (root.newKind === "app" ? "New space" : "New session") + " on "
      + (root.newHost !== "" ? root.newHost : root.localHost)
  }

  // The prompt crosses the panel and ssh on stdin, but the script hands it to
  // herdr as an argument, so local processes can see it while it waits.
  // Closing stdin after the write is what tells the script it is complete.
  Process {
    id: promptProc
    property string text: ""
    stdinEnabled: true
    onStarted: {
      write(text)
      text = ""
      stdinEnabled = false
    }
    property string out: ""
    property int code: 0
    property bool gotOut: false
    property bool gotExit: false
    stdout: StdioCollector {
      onStreamFinished: root.storePrompt("out", text)
    }
    onExited: function (exitCode) { root.storePrompt("exit", exitCode) }
    onRunningChanged: if (!running) root.promptStartFailed()
  }

  // One tick a second, only while a prompt is awaited.
  Timer {
    id: waitTimer
    interval: 1000
    repeat: true
    onTriggered: root.waitSecs++
  }

  PanelWindow {
    id: panel

    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Normal

    WlrLayershell.namespace: "nixarchy-herdr-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    onVisibleChanged: if (visible) Qt.callLater(function() { card.forceActiveFocus() })

    // Text size from the keyboard, also while an input has the focus. Card's
    // own shortcuts are off in the menu (pinnable is false), so these are the
    // only ones here.
    Shortcut {
      sequences: ["Ctrl+=", "Ctrl++"]
      context: Qt.WindowShortcut
      onActivated: herd.textBigger()
    }
    Shortcut {
      sequences: ["Ctrl+-"]
      context: Qt.WindowShortcut
      onActivated: herd.textSmaller()
    }
    Shortcut {
      sequences: ["Ctrl+0"]
      context: Qt.WindowShortcut
      onActivated: herd.textReset()
    }

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
    }

    // Clicking away closes, the way every summoned surface on this desktop
    // does. The card declares its own MouseArea below so a click inside it
    // does not reach this one.
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: surface
      // On a narrow screen the card gives way: at most 60% of it, and never
      // past the gaps.
      width: Math.min(root.cardWidth, Math.round(panel.width * 0.6), panel.width - Style.gapsOut * 2)
      height: Math.min(card.bodyHeight + padding * 2
                       + Border.top(borderSpec) + Border.bottom(borderSpec)
                       + (root.inputOpen ? newRow.height + Style.space(6) : 0),
                       panel.height - Style.gapsOut * 2)
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((panel.height - height) / 2))
      color: Commons.Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border,
                                     Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: surface.contentTopInset
        anchors.rightMargin: surface.contentRightInset
        anchors.bottomMargin: surface.contentBottomInset
        anchors.leftMargin: surface.contentLeftInset

        // Card.qml fills its parent by default; a positioner cannot override
        // that, so the fill is cleared here and the card sits above the input.
        Card {
          id: card
          anchors.fill: undefined
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: newRow.top
          anchors.bottomMargin: root.inputOpen ? Style.space(6) : 0
          panel: herd
          maxHeight: panel.height - Style.gapsOut * 2 - surface.padding * 2
                     - (root.inputOpen ? newRow.height + Style.space(6) : 0)
        }

        Item {
          id: newRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: root.inputOpen
            ? inputBox.height + (replyBox.visible ? replyBox.height + Style.space(6) : 0)
            : 0
          visible: root.inputOpen
          clip: true

          Rectangle {
            id: inputBox
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: newField.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(6)

              Text {
                id: inputLabel
                anchors.verticalCenter: parent.verticalCenter
                // Up to half the row; when it must give, the leading words go
                // and the host at the end stays.
                width: Math.min(implicitWidth, Math.round(inputBox.width / 2))
                elide: root.inputMode === "prompt" ? Text.ElideRight : Text.ElideLeft
                text: root.inputLabelText()
                Accessible.name: text
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Math.round(Style.font.caption * herd.textScale)
                color: Qt.alpha(root.foreground, 0.88)
              }

              TextInput {
                id: newField
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - parent.spacing - inputLabel.width
                font.family: root.fontFamily
                font.pixelSize: Math.round(Style.font.body * herd.textScale)
                color: root.foreground
                selectByMouse: true
                Accessible.name: inputLabel.text
                readOnly: root.newPending || root.awaitingExit
                Text {
                  anchors.fill: parent
                  visible: newField.text === ""
                  text: root.inputMode === "prompt" && root.promptTarget
                    ? "message to " + root.promptTarget.title
                    : "name, then optionally a folder"
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  font: newField.font
                  color: Qt.alpha(root.foreground, 0.68)
                }
                Keys.onPressed: function (event) {
                  if (event.key === Qt.Key_Escape) { root.cancelInput(); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.submitInput(); event.accepted = true
                  }
                }
              }
            }
          }

          // The agent's own screen, trimmed to its last lines, in a box that
          // scrolls past 40% of the card. Plain text: whatever an agent
          // printed is external and never markup.
          Flickable {
            id: replyBox
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: inputBox.bottom
            anchors.topMargin: Style.space(6)
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            visible: root.inputMode === "prompt" && root.promptReply !== ""
            // From the surface, not the card: the card is sized around this box.
            height: Math.min(replyText.implicitHeight, root.replyBudget)
            contentWidth: width
            contentHeight: replyText.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Text {
              id: replyText
              width: replyBox.width
              text: waitTimer.running
                ? "waiting " + root.waitSecs + " s \u00b7 Esc cancels"
                : root.promptReply
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              font.family: "monospace"
              font.pixelSize: Math.round(Style.font.caption * herd.textScale)
              color: Qt.alpha(root.foreground, 0.97)
            }
          }
        }

        // Asked before typing into an agent that is busy, blocked on a
        // question, or unreadable. Opens on Cancel, like the kill dialog.
        ConfirmOverlay {
          id: promptConfirm
          opened: root.promptConfirmOpen
          message: root.promptTarget
            ? herd.plain(root.promptTarget.title) + " is " + root.targetStatus()
              + ". Send anyway? It will arrive in the middle of what it is doing."
            : ""
          confirmText: "Send"
          foreground: root.foreground
          fontFamily: root.fontFamily
          textScale: herd.textScale
          onCanceled: root.closeConfirm()
          onConfirmed: {
            root.promptConfirmOpen = false
            root.submitPrompt(true)
            Qt.callLater(function () { newField.forceActiveFocus() })
          }
        }
      }
    }
  }
}
