import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Herdr: how many herdr servers are running, and a way into each of them.
//
// Herdr keeps one server per named session. They are easy to start and never
// stop by themselves - closing a window detaches, it does not end the session
// - so they pile up unseen. The bar shows the count; the panel names them,
// says which project and how many agents each one holds, and opens or kills
// one on a click.
//
// A session shows at most one window, because two windows on one session
// mirror each other. So "open" means: focus the window already showing this
// session, wherever it is, and only start a new one when there is none.
// `bin/herdr-sessions` does that matching by reading the herdr client's own
// command line off the processes behind each Hyprland window.
//
// The agent lines under a session are click targets of their own, one step
// further in: the pane is focused inside the server before the window is
// brought up, so a click lands on the piece of work you were reading rather
// than on wherever that session happened to be left.
//
// Project names are directory names and session names are whatever was passed
// to `herdr --session`, so every Text carries `textFormat: Text.PlainText`.
// Left on the default AutoText, Qt decides for itself that a string looks
// like markup and renders it as rich text - and rich text really does load
// `<img src="http://...">`, a request out of the shell process to a server
// someone else picked.
//
// The panel can also be pinned, which takes the same card out of the bar and
// leaves it on screen as a window you drag where you want it. A dropdown is
// something you open to answer a question and close again; a herd you are
// running is something you glance at all afternoon, and a panel that shuts
// the moment you touch anything else cannot be glanced at.
//
// Glyphs are \u escapes rather than literal characters, so the source
// survives editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "nixarchy.herdr"
  ipcTarget: "nixarchy.herdr"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  HerdrModel {
    id: herd
    host: root
  }

  // Where the card is: in the bar as a dropdown, or loose on screen as a
  // window of its own. Not a property this widget sets, but one it reads back
  // out of its own settings, so a pinned panel is still pinned after a shell
  // restart and lands where you left it.
  //
  // Every screen carries its own bar and therefore its own copy of this
  // widget, and a pin is a thing in one place, not the same thing repeated on
  // every monitor. So the setting names the output it was pinned on and the
  // copies on the other screens read it as "not me".
  readonly property var barScreen:
    button.QsWindow.window ? button.QsWindow.window.screen : null
  readonly property string screenName: barScreen ? barScreen.name : ""
  readonly property bool pinned: setting("pinned", false) === true
    && setting("pinScreen", "") === screenName && screenName !== ""
  readonly property real pinX: Number(setting("pinX", -1))
  readonly property real pinY: Number(setting("pinY", -1))
  // Zero means "not chosen": the width falls back to a default and the height
  // follows whatever is in the herd. Once you have dragged the corner, both
  // are yours and stay that way, which is the point of resizing a panel that
  // is going to sit there all day: it stops changing shape under you every
  // time an agent finishes.
  readonly property real pinW: Number(setting("pinW", 0))
  readonly property real pinH: Number(setting("pinH", 0))

  // Whichever card is on screen, so the cursor scrolls the list it is walking
  // and the kill dialog takes focus in the surface it was opened from. Only
  // one of the two is ever shown, which is what makes picking by `pinned`
  // rather than by asking them enough.
  //
  // Not called `card`, however much it wants to be: the pinned window names
  // its own surface that, and an id beats a property of the same name in every
  // expression in this file. The three calls below would then land on a
  // Rectangle, throw, and be swallowed by the try around the poll, so the
  // panel would report the herd as unreadable while drawing it perfectly.
  readonly property var activeCard: pinned ? pinCard : dropCard


  // How wide a card is before anybody resizes one. The list inside is two
  // short columns and a title that elides, so the width is a choice about how
  // much of a terminal title you want to read rather than something the
  // content asks for, and a narrower card sits better next to the work it is
  // describing.
  readonly property int cardWidth: Style.space(300)
  readonly property int cardMinWidth: Style.space(210)
  readonly property int cardMinHeight: Style.space(120)

  // The glyph, plus the few pixels the badge overhangs its corner by. Without
  // them the disc spills onto whatever widget sits next in the bar.
  readonly property int barContentWidth: Style.bar.iconFont + Style.space(4)

  // Panel is a bare Item with no size of its own, so the bar would hand this
  // widget zero width. Set it from the computed content width, never from a
  // child that fills this item: that is a loop where nothing decides the size,
  // the content still paints, and the button quietly stops being clickable.
  readonly property int barSlot: barContentWidth + Style.space(10)

  readonly property real openPanelIndicatorWidth: barContentWidth
  readonly property real openPanelIndicatorHeight: barContentWidth
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)


  // Pinning and unpinning are the same click, and neither of them opens or
  // closes anything: `opened` is what the bar button has always meant, and it
  // goes on meaning it. All the pin changes is which surface that state is
  // drawn in. So pinning an open dropdown leaves an open panel, and unpinning
  // a pinned one leaves the dropdown open where the bar button would have put
  // it, which is what makes the two feel like one panel in two places rather
  // than two panels.
  //
  // Pinning never moves the card. Wherever you dragged it to last time is
  // where it comes back, because that spot was a decision you made about your
  // own desktop and re-deciding it on every pin is the panel forgetting
  // something you told it. The position outlives the unpin for exactly that
  // reason: unpinning is putting it away, not throwing it out.
  function togglePin() {
    persistSettings(pinned ? { pinned: false }
                           : { pinned: true, pinScreen: screenName })
  }

  function rememberPin(x, y) {
    if (!pinned) return
    if (Math.round(x) === Math.round(pinX) && Math.round(y) === Math.round(pinY)) return
    persistSettings({ pinX: Math.round(x), pinY: Math.round(y) })
  }

  function rememberPinSize(w, h) {
    if (!pinned) return
    if (Math.round(w) === Math.round(pinW) && Math.round(h) === Math.round(pinH)) return
    persistSettings({ pinW: Math.round(w), pinH: Math.round(h) })
  }

  // Written into this widget's own entry in shell.json, the same entry the
  // bar's settings screen reads, so the two can never disagree and there is no
  // config file of our own to keep. Applied locally first, so the panel
  // redraws on the click rather than on the write coming back.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings)
      if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // A pinned panel that came back from a restart is a panel that should be on
  // screen, so the state the bar button drives is set to match what the
  // settings say. Unpinning deliberately leaves it alone: the card goes back
  // to being a dropdown, still open, under the button it came from.
  onPinnedChanged: if (pinned && !opened) open()


  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    opacity: herd.reachable ? 1 : 0.5
    slotSize: root.barSlot
    opticalSize: root.barContentWidth
    tooltipText: herd.plain(herd.tooltipText())

    iconComponent: Component {
      Item {
        Text {
          id: serverIcon
          anchors.centerIn: parent
          text: herd.iconServer
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          // barForeground, not the theme's foreground: on a transparent bar
          // the shell picks the glyph colour off what is behind it, so the
          // icon turns dark over a light wallpaper the way every other bar
          // icon does. The theme foreground is only right where the panel
          // paints its own background.
          //
          // Nothing here reacts to the panel being open: the bar draws that
          // itself, as an accent line on the module's inner edge, for every
          // widget that has a panel. Tinting the glyph as well says the same
          // thing twice, in the one colour that means something else.
          color: root.barForeground
        }

        // The server count rides the glyph's top-right corner, the way an
        // unread count rides an app icon, and is sized off the icon font so a
        // theme that resizes the bar takes it along. The ratios are what the
        // default 13px icon can carry: a 12px disc around a 9px digit. Three
        // quarters of the glyph leaves the digit on 6px, which is a coloured
        // speck rather than a count - unreadable at two digits - and the badge
        // exists to say how many as much as it says which colour.
        Rectangle {
          id: badge
          anchors.horizontalCenter: serverIcon.horizontalCenter
          anchors.horizontalCenterOffset: Math.round(Style.bar.iconFont * 0.42)
          anchors.verticalCenter: serverIcon.verticalCenter
          anchors.verticalCenterOffset: -Math.round(Style.bar.iconFont * 0.40)
          visible: herd.reachable && herd.runningCount > 0 && herd.badgeActive
          height: Math.round(Style.bar.iconFont * 0.95)
          width: Math.max(height, count.implicitWidth + Math.round(height * 0.45))
          radius: height / 2
          color: herd.badgeColor()
          // A rim in the bar's own background separates the badge from the
          // glyph it sits on, so the corner it covers still reads as a corner
          // and not as two shapes fused together.
          border.width: Math.round(Style.bar.iconFont * 0.06)
          border.color: Color.bar.background

          Text {
            id: count
            anchors.centerIn: parent
            // Centring the text item leaves the digit riding high: a line box
            // reserves descender room a digit never uses. Nudge it back down
            // onto the middle of the disc.
            anchors.verticalCenterOffset: Math.round(font.pixelSize * 0.1)
            text: herd.blockedCount > 0 ? herd.blockedCount : herd.runningCount
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Math.round((badge.height - 2 * badge.border.width) * 0.88)
            font.bold: true
            renderType: Text.NativeRendering
            color: Color.background
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) herd.refresh()
      else root.toggle()
    }
  }


  // ------------------------------------------------------------- dropdown
  //
  // The card in the bar, under the button, open for as long as you are
  // looking at it. Nothing here is different from before the pin existed
  // except that it stays shut while the pinned window has the card: two
  // copies of the same panel on screen at once is not a second view, it is
  // the same view twice, and the cursor would be walking both.

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && !root.pinned
    focusTarget: dropCard
    contentWidth: panel.fittedContentWidth(root.cardWidth)
    contentHeight: panel.fittedContentHeight(dropCard.bodyHeight)

    Card {
      id: dropCard
      anchors.fill: parent
      panel: herd
      maxHeight: panel.availableCardHeight - panel.verticalContentInset
    }
  }

  // --------------------------------------------------------- pinned window
  //
  // The same card, loose on the desktop. A layer-shell surface rather than a
  // real window, because that is what a shell plugin has to work with, and it
  // buys something a real window would not: it is on every workspace at once.
  // A herd you are running does not belong to the workspace you happened to
  // start it from, and a panel you have to switch away to see is a panel you
  // stop looking at.
  //
  // The surface covers the screen and the card is placed inside it, the way
  // the dropdown does it. That is what makes dragging smooth: the card moves
  // within a surface that never moves, so the compositor is never asked to
  // reposition a window sixty times a second. `mask` then hands every pixel
  // that is not the card back to whatever is underneath, so the invisible
  // rest of this surface does not quietly eat a click on your editor.

  PanelWindow {
    id: pinWindow

    screen: root.barScreen
    visible: root.pinned && root.opened
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "omarchy-herdr-pin"
    WlrLayershell.layer: WlrLayer.Overlay

    // Keyboard focus arrives on a click and not a moment earlier. Hyprland
    // hands focus to an OnDemand surface when it first maps, which is right
    // when you just pressed the pin and wrong every other time: a shell
    // restart would take the keyboard out of whatever you were typing in and
    // give it to a panel nobody asked for. So the surface maps as None and
    // becomes OnDemand once it is up, which leaves click-to-focus working and
    // map-to-focus not happening.
    WlrLayershell.keyboardFocus: pinWindow.focusArmed
      ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    property bool focusArmed: false

    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region { item: card }

    readonly property int edge: Style.gapsOut * 2
    // A dropdown is on screen for the seconds it is being used, so it wears
    // the accent border the whole time and that is honest. A pinned card is on
    // screen all day, and a card that says "focused" all day is saying nothing
    // at all, in the loudest colour the theme has. So it follows the keyboard
    // the way every real window on this desktop does: lit when it has it, a
    // quiet line when it does not.
    readonly property real borderWidth: Math.max(1, Style.space(2))
    readonly property bool active: pinCard.activeFocus
    readonly property var borderSpec: active
      ? Border.surfaceSpec("popups", "border", Color.popups.border, borderWidth)
      : Border.flat(Qt.rgba(root.foreground.r, root.foreground.g,
                            root.foreground.b, 0.22), borderWidth)
    readonly property int padding: Style.spacing.popupPadding
    readonly property real verticalInset:
      padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

    // The size you chose, or nothing, in which case the width is the default
    // and the height is however tall the herd happens to be. Written only by
    // the corner, read back out of the settings on the way in.
    property real chosenWidth: root.pinW
    property real chosenHeight: root.pinH

    readonly property real roomWidth: Math.max(root.cardMinWidth, width - edge * 2)
    readonly property real roomHeight: Math.max(root.cardMinHeight, height - edge * 2)

    readonly property real cardWidth: Math.min(roomWidth,
      Math.max(root.cardMinWidth, chosenWidth > 0 ? chosenWidth : root.cardWidth))
    readonly property real cardHeight: Math.min(roomHeight,
      Math.max(root.cardMinHeight, chosenHeight > 0
        ? chosenHeight : pinCard.bodyHeight + verticalInset))

    // Whether this surface knows how big it is yet. A layer-shell window
    // exists before the compositor has told it anything, and through those
    // first frames it reports a hundred pixels square. Every sum below is
    // about fitting a card inside a screen, and against a screen that small
    // there is no position that fits, so all of them answer "the corner".
    //
    // That is what threw a pinned card away: unpinning unmaps the surface, its
    // size collapses, the clamp fires on the way down and overwrites the spot
    // you had dragged it to. The card came back to a corner rather than to
    // where you left it, and the setting it came back from was right all
    // along.
    //
    // The test is the card itself rather than the screen: `cardWidth` already
    // refuses to go below a minimum, so a window too small to hold the card
    // with its margins is a window that has not been told its size.
    readonly property bool sized: width >= card.width + edge * 2
      && height >= card.height + edge * 2

    // Whether the card has been put somewhere for this showing. Until it has,
    // a size change means "try again"; after it has, it means "stay inside the
    // screen", and those are not the same instruction.
    property bool placed: false

    // Keep the card inside the screen whatever changes underneath it: a
    // shorter list, a resized output, a position read back from a settings
    // file somebody edited by hand. `fit` is the only thing that ever decides
    // where the card may sit, so there is one answer rather than three.
    function fit(value, limit) {
      var n = Number(value)
      if (!isFinite(n)) n = 0
      if (!(limit > pinWindow.edge)) return Math.round(n)
      return Math.round(Math.max(pinWindow.edge, Math.min(n, limit)))
    }

    // How much of the screen the bar is already using on its own side. A
    // layer at Overlay is free to sit on top of the bar, and a panel that
    // opens there on its first day looks like a mistake.
    readonly property real barSize: {
      var w = button.QsWindow.window
      if (!w || !root.bar) return 0
      var side = root.bar.position
      return (side === "left" || side === "right") ? w.width : w.height
    }

    readonly property string barSide: root.bar ? root.bar.position : "top"

    // Bottom left, which is the corner a thing you keep an eye on goes in: out
    // of the way of the window you are working in, away from the notifications
    // that come down the other side, and not under the bar.
    readonly property point defaultOrigin: {
      var x = edge + (barSide === "left" ? barSize + Style.gapsOut : 0)
      var y = height - card.height - edge
        - (barSide === "bottom" ? barSize + Style.gapsOut : 0)
      return Qt.point(Math.round(x), Math.round(y))
    }

    function place() {
      if (!sized) return
      var known = isFinite(root.pinX) && root.pinX >= 0
                  && isFinite(root.pinY) && root.pinY >= 0
      card.x = known ? fit(root.pinX, width - card.width - edge) : defaultOrigin.x
      card.y = known ? fit(root.pinY, height - card.height - edge) : defaultOrigin.y
      placed = true
    }

    function reclamp() {
      if (!sized) return
      if (!placed) { place(); return }
      card.x = fit(card.x, width - card.width - edge)
      card.y = fit(card.y, height - card.height - edge)
    }

    onSizedChanged: if (sized && visible && !placed) place()

    // Growing runs down and right from where the card already is, so the
    // corner you are holding is the corner that moves and the other three stay
    // put. That is what stops a resize from also being a small unasked-for
    // drag.
    function resize(w, h) {
      chosenWidth = Math.max(root.cardMinWidth, Math.min(w, width - card.x - edge))
      chosenHeight = Math.max(root.cardMinHeight, Math.min(h, height - card.y - edge))
    }

    onVisibleChanged: {
      focusArmed = false
      // Every showing places the card again, from the setting rather than
      // from wherever the last one left it lying.
      placed = false
      if (visible) {
        Qt.callLater(pinWindow.place)
        armTimer.restart()
      }
    }

    Timer {
      id: armTimer
      interval: 300
      onTriggered: pinWindow.focusArmed = pinWindow.visible
    }

    Connections {
      target: root
      function onPinXChanged() { pinWindow.place() }
      function onPinYChanged() { pinWindow.place() }
      function onPinWChanged() { pinWindow.chosenWidth = root.pinW }
      function onPinHChanged() { pinWindow.chosenHeight = root.pinH }
    }

    BorderSurface {
      id: card
      width: pinWindow.cardWidth
      height: pinWindow.cardHeight
      color: Color.popups.background
      borderSpec: pinWindow.borderSpec
      padding: pinWindow.padding
      radius: Style.cornerRadius

      onHeightChanged: pinWindow.reclamp()
      onWidthChanged: pinWindow.reclamp()

      // Declared before the card's own content, so everything drawn in the
      // card sits on top of this and takes its own clicks first. What is left
      // over inside the strip is the header background around the title, and
      // that is the handle: the pin button on the right of the same row goes
      // on working because it is above this, not because this knows about it.
      //
      // Dragging moves the card inside a surface that stays put, so the drag
      // is a scene-graph translation rather than a stream of window moves, and
      // it keeps up with the pointer.
      MouseArea {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: card.contentTopInset + pinCard.headerHeight
        acceptedButtons: Qt.LeftButton
        cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        drag.target: card
        drag.axis: Drag.XAndYAxis
        drag.threshold: 3
        drag.minimumX: pinWindow.edge
        drag.maximumX: pinWindow.width - card.width - pinWindow.edge
        drag.minimumY: pinWindow.edge
        drag.maximumY: pinWindow.height - card.height - pinWindow.edge
        onReleased: root.rememberPin(card.x, card.y)
      }

      Card {
        id: pinCard
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        panel: herd
        // A height you chose is a height the list has to live inside, so the
        // panel keeps the shape you gave it and scrolls instead of growing.
        // Until then the screen is the only limit.
        maxHeight: pinWindow.chosenHeight > 0
          ? pinWindow.chosenHeight - pinWindow.verticalInset
          : pinWindow.roomHeight - pinWindow.verticalInset
      }

      // Last child, above everything, in the corner the card's own padding
      // leaves empty. Six dots stepped down the diagonal, which is the corner
      // every resizable window has had for thirty years.
      //
      // Scene coordinates on both ends of the sum, never the pointer's
      // position inside this item: this item is anchored to the corner it is
      // dragging, so it moves out from under the cursor as the card grows and
      // a local delta would chase itself.
      MouseArea {
        id: resizer
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // The hit area keeps the whole corner, which is what makes it easy to
        // grab. The dots sit further in, clear of the border: a mark that
        // touches the edge reads as part of the edge.
        width: Style.space(24)
        height: Style.space(24)
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.SizeFDiagCursor

        property real startWidth: 0
        property real startHeight: 0
        property point startPoint: Qt.point(0, 0)

        function scenePoint(mouse) {
          return mapToItem(null, mouse.x, mouse.y)
        }

        onPressed: function(mouse) {
          startWidth = card.width
          startHeight = card.height
          startPoint = scenePoint(mouse)
        }

        onPositionChanged: function(mouse) {
          if (!pressed) return
          var now = scenePoint(mouse)
          pinWindow.resize(startWidth + (now.x - startPoint.x),
                           startHeight + (now.y - startPoint.y))
        }

        onReleased: root.rememberPinSize(card.width, card.height)

        Column {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          // Clear of the rounded corner, not tucked against it: the border
          // curves away here, so a mark set tight to the edge ends up reading
          // as part of the border rather than as something you can grab.
          anchors.rightMargin: Style.space(9)
          anchors.bottomMargin: Style.space(9)
          spacing: Math.max(2, Style.space(3))

          Repeater {
            model: 3

            Row {
              id: dotRow
              required property int index
              anchors.right: parent.right
              spacing: Math.max(2, Style.space(3))

              Repeater {
                model: dotRow.index + 1

                Rectangle {
                  width: Math.max(2, Style.space(3))
                  height: width
                  radius: width / 2
                  color: Qt.darker(root.foreground, 2.2)
                }
              }
            }
          }
        }
      }
    }
  }
}
