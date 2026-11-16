import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Board — a bar button that toggles the bulletin-board popup (board.popup).
// Shows a pin glyph plus the number of cards on the board, read live from
// the store the popup writes (~/.local/state/omarchy/board/board.json).
BarWidget {
  id: root
  moduleName: "board"

  readonly property bool showCount: String(setting("showCount", "true")) !== "false"
  property int cardCount: 0

  readonly property string storePath:
    (Quickshell.env("XDG_STATE_HOME") !== ""
      ? Quickshell.env("XDG_STATE_HOME")
      : Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/board/board.json"

  function recount(raw) {
    var n = 0
    try {
      var doc = JSON.parse(raw || "{}")
      if (doc && Array.isArray(doc.items)) n = doc.items.length
    } catch (e) { n = 0 }
    root.cardCount = n
  }

  FileView {
    path: root.storePath
    watchChanges: true
    printErrors: false
    onLoaded: root.recount(text())
    onLoadFailed: root.cardCount = 0
    onFileChanged: reload()
  }

  implicitWidth: vertical ? barSize : button.implicitWidth
  implicitHeight: vertical ? button.implicitHeight : barSize

  WidgetButton {
    id: button
    bar: root.bar
    anchors.centerIn: parent
    fontFamily: bar ? bar.fontFamily : "monospace"
    horizontalMargin: 7
    hasVisualContent: true
    tooltipText: "Bulletin board"

    // nf-md-pin
    text: root.showCount && root.cardCount > 0 ? "󰐃 " + root.cardCount : "󰐃"

    onPressed: function(b) { if (root.bar) root.bar.run("omarchy-shell shell toggle board.popup") }
  }
}
