import QtQuick
import Quickshell
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

  readonly property int cardWidth: Style.space(380)

  // Plugin lifecycle hooks. The host calls open(payloadJson) after
  // `omarchy-shell shell summon nixarchy.herdr ...` and close() when hidden.
  function open(payloadJson) {
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
  }

  PanelWindow {
    id: panel

    visible: root.opened
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
                       + Border.top(borderSpec) + Border.bottom(borderSpec),
                       panel.height - Style.gapsOut * 2)
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((panel.height - height) / 2))
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border,
                                     Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Card {
        id: card
        anchors.fill: parent
        anchors.topMargin: surface.contentTopInset
        anchors.rightMargin: surface.contentRightInset
        anchors.bottomMargin: surface.contentBottomInset
        anchors.leftMargin: surface.contentLeftInset
        panel: herd
        maxHeight: panel.height - Style.gapsOut * 2 - surface.padding * 2
      }
    }
  }
}
