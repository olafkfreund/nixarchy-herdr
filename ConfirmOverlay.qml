import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The question a surface asks before something cannot be taken back: a layer
// that blocks everything under it and holds the shell's ConfirmDialog in the
// middle. The surface supplies the text, what Confirm does and, through
// `dialog`, nothing else; it is only alive while it is asking, because an
// invisible item cannot hold the focus the panel's own keys need.
//
// PanelKeyCatcher defines `Keys.onPressed` in the component itself, so the
// keys are handled here, before the item, and the catcher is left alone.
Item {
  id: root

  property bool opened: false
  property string message: ""
  property string confirmText: ""
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  // ConfirmDialog sizes its own text from the theme; the surface's scale is
  // carried so a caller never has to know that.
  property real textScale: 1.0
  readonly property alias dialog: dialog

  signal canceled()
  signal confirmed()

  anchors.fill: parent
  z: 10
  visible: opened
  focus: opened

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function (event) {
    if (dialog.handleKey(event)) event.accepted = true
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
    id: dialog
    anchors.fill: parent
    opened: root.opened
    message: root.message
    confirmText: root.confirmText
    background: Commons.Color.background
    foreground: root.foreground
    fontFamily: root.fontFamily
    onCanceled: root.canceled()
    onConfirmed: root.confirmed()
  }
}
