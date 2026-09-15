import QtQuick
import Quickshell
import Quickshell.Hyprland
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
    return null
  }

  readonly property real textScale: 1.3
  readonly property int cardWidth: Style.space(460)

  // Plugin lifecycle hooks. The host calls open(payloadJson) after
  // `omarchy-shell shell summon nixarchy.herdr ...` and close() when hidden.
  function open(payloadJson) {
    root.targetScreen = root.focusedScreen()
    root.opened = true
    herd.refresh()
    Qt.callLater(function() { card.forceActiveFocus() })
  }

  function close() {
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
    onNewSessionRequested: root.beginNew()
  }

  // The new-session line. One field rather than a form: a name, optionally
  // followed by an absolute path to open it in.
  property bool newOpen: false
  property string newHost: ""

  function beginNew() {
    root.newHost = herd.hostAtCursor()
    root.newOpen = true
    newField.text = ""
    Qt.callLater(function () { newField.forceActiveFocus() })
  }

  function cancelNew() {
    root.newOpen = false
    newField.text = ""
    Qt.callLater(function () { card.forceActiveFocus() })
  }

  function submitNew() {
    var words = newField.text.trim().split(/\s+/)
    var name = words.length > 0 ? words[0] : ""
    var dir = words.length > 1 ? words.slice(1).join(" ") : ""
    if (name === "") { root.cancelNew(); return }
    herd.newSession(root.newHost, name, dir)
    root.cancelNew()
    root.close()
  }

  PanelWindow {
    id: panel

    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

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
      width: Math.min(root.cardWidth, panel.width - Style.gapsOut * 2)
      height: Math.min(card.bodyHeight + padding * 2
                       + Border.top(borderSpec) + Border.bottom(borderSpec)
                       + (root.newOpen ? newRow.height + Style.space(6) : 0),
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
          anchors.bottomMargin: root.newOpen ? Style.space(6) : 0
          panel: herd
          maxHeight: panel.height - Style.gapsOut * 2 - surface.padding * 2
                     - (root.newOpen ? newRow.height + Style.space(6) : 0)
        }

        Item {
          id: newRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: root.newOpen ? newField.implicitHeight + Style.space(10) : 0
          visible: root.newOpen
          clip: true

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
          }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.newHost === "" ? "new session" : "new on " + root.newHost
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Math.round(Style.font.caption * root.textScale)
              color: Qt.darker(root.foreground, 1.5)
            }

            TextInput {
              id: newField
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - parent.spacing * 2 - Style.space(120)
              font.family: root.fontFamily
              font.pixelSize: Math.round(Style.font.body * root.textScale)
              color: root.foreground
              selectByMouse: true
              // The name, then an optional absolute directory. The script
              // refuses anything else, so this only has to carry the words.
              Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Escape) { root.cancelNew(); event.accepted = true }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.submitNew(); event.accepted = true
                }
              }
            }
          }
        }
      }
    }
  }
}
