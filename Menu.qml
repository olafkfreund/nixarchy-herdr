import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
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
  readonly property color foreground: Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: Style.font.family
  function togglePin() {}

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
  // 1440p panel; don't bring that back. textScale stays at 1.0 because the
  // rows and HerdrModel read it.
  readonly property real textScale: 1.0
  readonly property int cardWidth: Style.space(760)

  // Plugin lifecycle hooks. The host calls open(payloadJson) after
  // `omarchy-shell shell summon nixarchy.herdr ...` and close() when hidden.
  function open(payloadJson) {
    root.targetScreen = root.focusedScreen()
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
  }

  // One input line under the card, used two ways: "new" takes a session name
  // and an optional absolute directory, "prompt" takes text for one agent.
  // Empty when the line is closed.
  property string inputMode: ""
  readonly property bool inputOpen: inputMode !== ""
  property string newHost: ""
  // The agent a prompt goes to, captured when `a` was pressed so a refresh
  // moving the cursor cannot redirect it.
  property var promptTarget: null
  property string promptReply: ""
  property bool promptConfirmOpen: false

  function beginInput(mode) {
    if (mode === "prompt") {
      var session = herd.sessionAt(herd.cursor)
      var agent = herd.agentAt(herd.cursor)
      if (!session || !agent) return
      root.promptTarget = { host: String(session.host || ""), session: session.name,
                            pane: agent.pane, title: herd.cleanTitle(agent.title) }
    } else {
      root.newHost = herd.hostAtCursor()
    }
    root.promptReply = ""
    root.inputMode = mode
    newField.text = ""
    Qt.callLater(function () { newField.forceActiveFocus() })
  }

  function cancelInput() {
    promptProc.running = false
    root.inputMode = ""
    root.promptTarget = null
    root.promptReply = ""
    root.promptConfirmOpen = false
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
    herd.newSession(root.newHost, name, dir)
    root.cancelInput()
    root.close()
  }

  // The target's state as of the latest poll, not as of the key press: an
  // agent that started working while you typed is still asked about.
  function targetStatus() {
    var t = root.promptTarget
    if (!t) return "unknown"
    for (var i = 0; i < herd.sessions.length; i++) {
      var s = herd.sessions[i]
      if (s.name !== t.session || String(s.host || "") !== t.host) continue
      var agents = s.agentList || []
      for (var j = 0; j < agents.length; j++)
        if (agents[j].pane === t.pane) return agents[j].status
    }
    return "unknown"
  }

  function submitPrompt(confirmed) {
    var text = newField.text
    if (!root.promptTarget || text.trim() === "" || promptProc.running) return
    if (!confirmed && herd.agentBusy(root.targetStatus())) {
      root.promptConfirmOpen = true
      promptConfirm.selectedIndex = 0
      Qt.callLater(function () { confirmKeys.forceActiveFocus() })
      return
    }
    var t = root.promptTarget
    var command = [herd.script]
    if (t.host) command.push("--host", t.host)
    command.push("prompt", t.session, t.pane)
    // C1 controls (U+0080-U+009F) are two bytes in UTF-8, so the script's
    // byte-wise tr cannot catch them; a terminal still acts on them.
    text = text.replace(/[\u0080-\u009f]/g, "")
    promptProc.text = text
    promptProc.command = command
    // Closed after each write; a second prompt needs it open again before
    // the process starts.
    promptProc.stdinEnabled = true
    root.promptReply = "waiting for " + t.title + "\u2026"
    newField.text = ""
    promptProc.running = true
  }

  function closeConfirm() {
    root.promptConfirmOpen = false
    Qt.callLater(function () { newField.forceActiveFocus() })
  }

  // The agent's answer out of its screen. Agents draw their input prompt
  // after the answer and their own footer - status line, hints, warnings -
  // below that, so everything from the last prompt marker down is dropped.
  // Blank lines and the box-drawing rules framing the input are noise too.
  function replyFrom(output) {
    var lines = String(output || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      if (/^\s*[\u276f>]\s*$/.test(lines[i])) { lines = lines.slice(0, i); break }
    }
    // Then only what follows the prompt that was sent, which the agent echoes
    // as "❯ <text>": everything above it is earlier conversation.
    for (var k = lines.length - 1; k >= 0; k--) {
      if (/^\s*[\u276f>]\s+\S/.test(lines[k])) { lines = lines.slice(k + 1); break }
    }
    lines = lines.map(function (line) { return line.replace(/^\s+/, "") })
    lines = lines.filter(function (line) {
      return line.trim() !== "" && !/^[\s\u2500-\u257f]+$/.test(line)
    })
    // The terminal wrapped the answer at its own width; this card wraps again
    // at a different one. Rejoin wrapped lines into paragraphs, starting a
    // new one only where a line opens with a marker: a bullet, the agent's
    // status glyphs, a list dash or a number.
    var paragraphs = []
    lines.forEach(function (line) {
      if (paragraphs.length === 0 || /^([\u25cf\u273b\u23bf\u2022*-]|\d+[.)])/.test(line))
        paragraphs.push(line)
      else
        paragraphs[paragraphs.length - 1] += " " + line
    })
    return paragraphs.slice(-6).join("\n")
  }

  // The prompt goes over stdin, never argv. Closing stdin after the write is
  // what tells the script the text is complete.
  Process {
    id: promptProc
    property string text: ""
    stdinEnabled: true
    onStarted: {
      write(text)
      text = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.promptReply = data.ok === true
            ? (root.replyFrom(data.output) || "(no output)")
            : "could not send: " + (data.error || "unknown error")
        } catch (e) {
          if (root.promptReply.indexOf("waiting") === 0) root.promptReply = "no reply"
        }
      }
    }
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

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
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
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border,
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
            ? inputBox.height + (replyText.visible ? replyText.implicitHeight + Style.space(6) : 0)
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
                width: Math.min(implicitWidth, Style.space(170))
                elide: Text.ElideRight
                text: root.inputMode === "prompt" && root.promptTarget
                  ? (root.promptTarget.host ? root.promptTarget.host + " \u00b7 " : "")
                    + root.promptTarget.title
                  : (root.newHost === "" ? "new session" : "new on " + root.newHost)
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Math.round(Style.font.caption * root.textScale)
                color: Qt.darker(root.foreground, 1.5)
              }

              TextInput {
                id: newField
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - parent.spacing - inputLabel.width
                font.family: root.fontFamily
                font.pixelSize: Math.round(Style.font.body * root.textScale)
                color: root.foreground
                selectByMouse: true
                readOnly: promptProc.running
                Keys.onPressed: function (event) {
                  if (event.key === Qt.Key_Escape) { root.cancelInput(); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.submitInput(); event.accepted = true
                  }
                }
              }
            }
          }

          // The agent's own screen, trimmed to its last lines. Plain text:
          // whatever an agent printed is external and never markup.
          Text {
            id: replyText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: inputBox.bottom
            anchors.topMargin: Style.space(6)
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            visible: root.inputMode === "prompt" && root.promptReply !== ""
            text: root.promptReply
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            maximumLineCount: 12
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.caption * root.textScale)
            color: Qt.darker(root.foreground, 1.2)
          }
        }

        // Asked before typing into an agent that is busy, blocked on a
        // question, or unreadable. Opens on Cancel, like the kill dialog.
        Item {
          id: confirmKeys
          anchors.fill: parent
          z: 10
          visible: root.promptConfirmOpen
          focus: root.promptConfirmOpen

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function (event) {
            if (promptConfirm.handleKey(event)) event.accepted = true
          }

          // Swallows every click, hover and scroll while the dialog is up, so
          // nothing underneath it can be hit while it is asking.
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: function (wheel) { wheel.accepted = true }
          }

          ConfirmDialog {
            id: promptConfirm
            anchors.fill: parent
            opened: root.promptConfirmOpen
            message: root.promptTarget
              ? herd.plain(root.promptTarget.title) + " is " + root.targetStatus()
                + ". Send anyway? It will arrive in the middle of what it is doing."
              : ""
            confirmText: "Send"
            background: Color.background
            foreground: root.foreground
            fontFamily: root.fontFamily
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
}
