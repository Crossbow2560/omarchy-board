import QtQuick
import QtQuick.Window
import qs.Commons

// One card on the board: a sticky note, an image, or a todo list.
//
// The card reads its initial geometry and content from `modelData` and then
// owns that state itself; edits are written back into the board's item
// object in place (board.patch) so typing never rebuilds the card.
Item {
  id: card

  required property var modelData
  property var board: null

  readonly property string itemId: modelData.id
  readonly property string kind: modelData.type
  property int colorIndex: modelData.color || 0
  readonly property color tint: board ? board.paletteColor(colorIndex) : "#888888"

  readonly property int headerHeight: Style.space(24)
  readonly property int minW: kind === "image" ? Style.space(40) : Style.space(140)
  readonly property int minH: kind === "image" ? Style.space(30) : Style.space(70)

  property var todos: (modelData.todos || []).slice()

  x: modelData.x
  y: modelData.y
  z: modelData.z || 0
  width: Math.max(minW, modelData.w)
  height: kind === "todo"
    ? headerHeight + todoBody.implicitHeight + Style.space(12)
    : Math.max(minH, modelData.h)

  function commitGeometry() {
    if (board) board.patch(itemId, { x: Math.round(x), y: Math.round(y), w: Math.round(width), h: Math.round(height) })
  }
  function raise() { if (board) z = board.raise(itemId) }

  readonly property bool isImage: kind === "image"

  // --- surface (notes and todos only; images sit bare on the board) --------
  Rectangle {
    visible: !card.isImage
    anchors.fill: parent
    radius: Math.min(Style.cornerRadius, Style.space(8))
    color: card.board.cardBg
    border.width: hover.hovered || bodyFocus.activeFocus ? 2 : 1
    border.color: Qt.rgba(card.tint.r, card.tint.g, card.tint.b, hover.hovered ? 0.9 : 0.55)

    Rectangle {
      anchors.fill: parent
      anchors.margins: parent.border.width
      radius: parent.radius
      color: Qt.rgba(card.tint.r, card.tint.g, card.tint.b, card.kind === "image" ? 0.05 : 0.12)
    }
  }

  HoverHandler { id: hover }

  // Click anywhere on the card brings it to the front.
  TapHandler { onTapped: card.raise() }

  // --- header: drag handle + actions ------------------------------------------
  Item {
    id: header
    visible: !card.isImage
    width: parent.width
    height: card.headerHeight

    MouseArea {
      anchors.fill: parent
      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      drag.target: card
      drag.threshold: 0
      onPressed: card.raise()
      onReleased: card.commitGeometry()
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      // colour dot — click to cycle (like todo's priority glyph)
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(10); height: width; radius: width / 2
        color: card.tint
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(5)
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            card.colorIndex = (card.colorIndex + 1) % card.board.palette.length
            card.board.patch(card.itemId, { color: card.colorIndex })
          }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: card.board ? card.board.stamp(card.modelData.ts) : ""
        color: Qt.darker(card.board.fg, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      opacity: hover.hovered ? 1 : 0

      Text {
        id: copyGlyph
        visible: card.kind !== "todo"
        textFormat: Text.PlainText
        text: copiedTimer.running ? "copied" : "󰆏"
        color: copiedTimer.running ? card.board.accentColor : Qt.darker(card.board.fg, 1.2)
        font.family: Style.font.family
        font.pixelSize: copiedTimer.running ? Style.font.caption : Style.font.body
        Timer { id: copiedTimer; interval: 1100 }
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(5)
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (card.kind === "image") card.board.copyImage(card.modelData.src)
            else card.board.copyText(noteEdit.text)
            copiedTimer.restart()
          }
        }
      }
      Text {
        textFormat: Text.PlainText
        text: "󰅖"
        color: Qt.darker(card.board.fg, 1.2)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(5)
          cursorShape: Qt.PointingHandCursor
          onClicked: card.board.removeItem(card.itemId)
        }
      }
    }
  }

  // --- body ------------------------------------------------------------------
  Item {
    id: body
    anchors.top: card.isImage ? parent.top : header.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: card.isImage ? 0 : Style.space(8)
    anchors.topMargin: 0
    clip: true

    // keeps "is something inside this card focused" in one place
    FocusScope { id: bodyFocus; anchors.fill: parent

      // sticky note
      Flickable {
        id: noteFlick
        visible: card.kind === "note"
        anchors.fill: parent
        contentHeight: noteEdit.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        TextEdit {
          id: noteEdit
          width: noteFlick.width
          textFormat: TextEdit.PlainText
          wrapMode: TextEdit.Wrap
          selectByMouse: true
          text: card.kind === "note" ? (card.modelData.text || "") : ""
          color: card.board.fg
          selectionColor: Style.selectionFillFor(card.board.fg, card.board.accentColor)
          selectedTextColor: card.board.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          onTextChanged: if (card.kind === "note") card.board.patch(card.itemId, { text: text })
          onActiveFocusChanged: if (activeFocus) card.raise()
          Keys.onEscapePressed: card.board.focusBoard()
          onCursorRectangleChanged: {
            if (cursorRectangle.y < noteFlick.contentY) noteFlick.contentY = cursorRectangle.y
            else if (cursorRectangle.y + cursorRectangle.height > noteFlick.contentY + noteFlick.height)
              noteFlick.contentY = cursorRectangle.y + cursorRectangle.height - noteFlick.height
          }

          Text {
            visible: noteEdit.text === "" && !noteEdit.activeFocus
            textFormat: Text.PlainText
            text: "Type a note…"
            color: Qt.darker(card.board.fg, 1.8)
            font: noteEdit.font
          }
        }
      }

      // image
      Image {
        id: img
        visible: card.kind === "image"
        anchors.fill: parent
        source: card.kind === "image" && card.modelData.src ? "file://" + card.modelData.src : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        onStatusChanged: {
          // First load: size the card to the picture (logical pixels, capped).
          if (status !== Image.Ready || !card.modelData.fit) return
          var dpr = Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
          var w = implicitWidth / dpr, h = implicitHeight / dpr
          var maxW = Style.space(460), maxH = Style.space(380)
          var s = Math.min(1, maxW / Math.max(1, w), maxH / Math.max(1, h))
          card.width = Math.max(Style.space(40), Math.round(w * s))
          card.height = Math.max(Style.space(40), Math.round(h * s))
          card.board.patch(card.itemId, { fit: false })
          card.commitGeometry()
        }
      }
      MouseArea {
        visible: card.isImage
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        drag.target: pressedButtons & Qt.RightButton ? null : card
        property bool moved: false
        // left: drag to move · right: menu
        onPressed: function(m) {
          moved = false
          card.raise()
          if (m.button === Qt.RightButton) {
            var p = mapToItem(card.parent, m.x, m.y)
            card.board.openImageMenu(card.itemId, card.modelData.src, p.x, p.y)
          } else card.board.closeMenu()
        }
        onPositionChanged: if (drag.active) moved = true
        onReleased: if (moved) card.commitGeometry()
      }
      Text {
        visible: card.kind === "image" && img.status === Image.Error
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "image missing"
        color: Qt.darker(card.board.fg, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // todo list
      Column {
        id: todoBody
        visible: card.kind === "todo"
        width: parent.width
        spacing: Style.space(2)

        Repeater {
          model: card.kind === "todo" ? card.todos : []
          delegate: Item {
            id: row
            required property int index
            required property var modelData
            width: todoBody.width
            height: Math.max(Style.space(22), rowText.implicitHeight + Style.space(4))
            HoverHandler { id: rowHover }

            Text {
              id: check
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: row.modelData.done ? "☑" : "☐"
              color: row.modelData.done ? card.tint : card.board.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                cursorShape: Qt.PointingHandCursor
                onClicked: card.toggleTodo(row.index)
              }
            }
            Text {
              id: rowText
              anchors.left: check.right
              anchors.leftMargin: Style.space(6)
              anchors.right: rowDel.left
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: row.modelData.text
              font.strikeout: row.modelData.done
              color: row.modelData.done ? Qt.darker(card.board.fg, 1.7) : card.board.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              id: rowDel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              opacity: rowHover.hovered ? 1 : 0
              textFormat: Text.PlainText
              text: "󰅖"
              color: Qt.darker(card.board.fg, 1.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                cursorShape: Qt.PointingHandCursor
                onClicked: card.removeTodo(row.index)
              }
            }
          }
        }

        TextInput {
          id: todoInput
          width: parent.width
          height: Style.space(24)
          verticalAlignment: TextInput.AlignVCenter
          color: card.board.fg
          selectByMouse: true
          selectionColor: Style.selectionFillFor(card.board.fg, card.board.accentColor)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          onActiveFocusChanged: if (activeFocus) card.raise()
          onAccepted: { card.addTodo(text); text = "" }
          Keys.onEscapePressed: card.board.focusBoard()

          Text {
            visible: todoInput.text === ""
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "+ add item"
            color: Qt.darker(card.board.fg, 1.8)
            font: todoInput.font
          }
        }
      }
    }
  }

  function setTodos(next) {
    card.todos = next
    board.patch(itemId, { todos: next })
  }
  function addTodo(t) {
    t = String(t || "").trim()
    if (t === "") return
    var next = card.todos.slice(); next.push({ text: t.slice(0, 500), done: false }); setTodos(next)
  }
  function toggleTodo(i) {
    var next = card.todos.slice()
    next[i] = { text: next[i].text, done: !next[i].done }
    setTodos(next)
  }
  function removeTodo(i) { var next = card.todos.slice(); next.splice(i, 1); setTodos(next) }

  function focusEditor() {
    if (kind === "note") noteEdit.forceActiveFocus()
    else if (kind === "todo") todoInput.forceActiveFocus()
  }

  // --- resize grip (notes and images; todo cards grow with their list) -------------
  Item {
    visible: card.kind !== "todo"
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    width: Style.space(16); height: width
    opacity: hover.hovered ? 1 : 0

    Canvas {
      anchors.fill: parent
      onPaint: {
        var ctx = getContext("2d"); ctx.reset()
        ctx.strokeStyle = String(card.tint); ctx.lineWidth = 1.5
        for (var k = 1; k <= 2; k++) {
          ctx.beginPath()
          ctx.moveTo(width - 3, height - 3 - k * 4)
          ctx.lineTo(width - 3 - k * 4, height - 3)
          ctx.stroke()
        }
      }
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.SizeFDiagCursor
      property real sx: 0
      property real sy: 0
      property real sw: 0
      property real sh: 0
      onPressed: function(m) {
        var p = mapToItem(card.parent, m.x, m.y)
        sx = p.x; sy = p.y; sw = card.width; sh = card.height
        card.raise()
      }
      onPositionChanged: function(m) {
        var p = mapToItem(card.parent, m.x, m.y)
        card.width = Math.max(card.minW, sw + p.x - sx)
        // pictures keep their aspect ratio
        card.height = card.isImage
          ? Math.round(card.width * sh / Math.max(1, sw))
          : Math.max(card.minH, sh + p.y - sy)
      }
      onReleased: card.commitGeometry()
    }
  }
}
