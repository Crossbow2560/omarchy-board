import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Board Popup — a pop-out bulletin board on an (almost) infinite canvas.
//
//   • Cards: sticky notes, todo lists, and images. Notes/todos drag by their
//     header; images are frameless (left-drag moves, right-click = menu).
//   • Paste (Ctrl+V): images, text, or files copied in a file manager.
//     Dragging image files onto the board works too.
//   • Snip (S): hide the board, pick a screen region, pin the capture.
//   • Ink: freehand pen / eraser drawn over everything.
//   • Canvas: drag empty space (or middle-drag anywhere) to pan; wheel /
//     pinch / Ctrl+wheel to zoom, trackpad two-finger scroll to pan.
//   • Boards: several named boards, switched from the toolbar menu.
//
//   V move · P pen · E eraser · N note · T todo · S snip · Ctrl+V paste
//   Ctrl+Z undo · 1–6 pen colour · [ ] pen size · Ctrl +/−/0 zoom · F fit
//   Ctrl+Tab next board · Esc back / close
//
// Two layouts: centred (default) and "quake" (drops from the top edge),
// chosen by the payload: `omarchy-shell shell toggle board.popup '{"mode":"quake"}'`.
//
// State: ~/.local/state/omarchy/board/boards.json (board list) and
// boards/<id>/board.json + that board's pasted images. Everything autosaves.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property string mode: "center"      // center | quake

  property var items: []
  property var strokes: []
  property var history: []
  property var current: null          // stroke being drawn
  property bool ready: false          // current board read (or found missing)
  property string tool: "select"      // select | pen | eraser
  property int penColor: 1
  property int penWidth: 3
  property int topZ: 1
  property string status: ""
  property point lastPointer: Qt.point(-1, -1)

  // viewport: screen = world * zoom + pan
  property real panX: 0
  property real panY: 0
  property real zoom: 1
  readonly property real minZoom: 0.05
  readonly property real maxZoom: 8

  // boards
  property var boards: []             // [{ id, name }]
  property string currentId: ""
  property bool boardsMenuOpen: false
  property string renamingId: ""
  property string confirmDeleteId: ""

  readonly property string fontFamily: Style.font.family
  readonly property var cardBorder: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  readonly property string stateDir:
    (Quickshell.env("XDG_STATE_HOME") !== ""
      ? Quickshell.env("XDG_STATE_HOME")
      : Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/board"
  readonly property string indexPath: stateDir + "/boards.json"
  readonly property string boardDir: currentId !== "" ? stateDir + "/boards/" + currentId : ""
  readonly property string storePath: boardDir !== "" ? boardDir + "/board.json" : ""
  readonly property string currentName: {
    for (var i = 0; i < boards.length; i++) if (boards[i].id === currentId) return boards[i].name
    return "Board"
  }

  // Theme colours first so cards re-skin with `omarchy theme set`, then two
  // fixed sticky-note colours for variety.
  readonly property var palette: [Color.foreground, Color.accent, Color.urgent, Color.muted, "#d8a657", "#7daea3"]
  function paletteColor(i) { return palette[((i || 0) % palette.length + palette.length) % palette.length] }

  // Card.qml can't see the qs.Commons Color singleton, so hand it the tokens.
  readonly property color fg: Color.foreground
  readonly property color accentColor: Color.accent
  readonly property color cardBg: Color.popups.background

  function stamp(ts) {
    if (!ts) return ""
    var d = new Date(ts), now = new Date()
    var hh = ("0" + d.getHours()).slice(-2), mm = ("0" + d.getMinutes()).slice(-2)
    if (d.toDateString() === now.toDateString()) return hh + ":" + mm
    var mon = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][d.getMonth()]
    return mon + " " + d.getDate() + ", " + hh + ":" + mm
  }

  readonly property var imageMimes: ["image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp"]
  readonly property var imageExts: ["png", "jpg", "jpeg", "webp", "gif", "bmp"]

  // --- open / close ------------------------------------------------------------
  function open(payloadJson) {
    var p = {}
    try { p = JSON.parse(payloadJson || "{}") || {} } catch (e) { p = {} }
    root.mode = p.mode === "quake" ? "quake" : "center"
    root.opened = true
    Qt.callLater(focusBoard)
  }
  function close() {
    root.opened = false
    root.menuItemId = ""
    closeBoardsMenu()
    if (root.tool !== "select") root.tool = "select"
    flushSave()
  }
  function toggle() { root.opened ? root.close() : root.open("{}") }
  function dismiss() {
    root.close()
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "board.popup")
  }
  function focusBoard() { keyCatcher.forceActiveFocus() }

  // --- board index ---------------------------------------------------------------
  function validId(id) { return /^[a-z0-9]{4,40}$/.test(String(id || "")) }

  function loadIndex(raw) {
    var doc = null
    try { doc = JSON.parse(raw || "") } catch (e) { doc = null }
    var list = []
    if (doc && Array.isArray(doc.boards))
      for (var i = 0; i < doc.boards.length; i++) {
        var b = doc.boards[i]
        if (b && validId(b.id)) list.push({ id: b.id, name: String(b.name || "Board").slice(0, 60) })
      }
    if (list.length === 0) { firstRun(); return }
    root.boards = list
    var want = doc && validId(doc.current) ? doc.current : list[0].id
    var found = false
    for (var j = 0; j < list.length; j++) if (list[j].id === want) found = true
    root.currentId = found ? want : list[0].id
  }
  function saveIndex() {
    indexStore.setText(JSON.stringify({ version: 1, current: root.currentId, boards: root.boards }, null, 2) + "\n")
  }
  // First run: move a pre-boards board.json (if any) into boards/<id>/ as "Main".
  function firstRun() {
    var id = newId()
    migrateProc.boardId = id
    migrateProc.command = ["sh", "-c",
      "mkdir -p \"$1/boards/$2\" && if [ -f \"$1/board.json\" ] && [ ! -e \"$1/boards/$2/board.json\" ]; then mv -- \"$1/board.json\" \"$1/boards/$2/board.json\"; fi",
      "sh", root.stateDir, id]
    migrateProc.running = true
  }
  Process {
    id: migrateProc
    property string boardId: ""
    onExited: function(code) {
      root.boards = [{ id: boardId, name: "Main" }]
      root.currentId = boardId
      root.saveIndex()
    }
  }

  FileView {
    id: indexStore
    path: root.indexPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadIndex(text())
    onLoadFailed: root.firstRun()
  }

  function switchBoard(id) {
    if (!validId(id) || id === root.currentId) { closeBoardsMenu(); return }
    flushSave()
    sweepImages()
    root.ready = false
    root.history = []
    root.items = []
    root.strokes = []
    root.menuItemId = ""
    root.currentId = id          // FileView follows storePath and loads it
    saveIndex()
    closeBoardsMenu()
    flash(root.currentName)
  }
  function cycleBoard(step) {
    if (root.boards.length < 2) return
    var i = 0
    for (var k = 0; k < root.boards.length; k++) if (root.boards[k].id === root.currentId) i = k
    switchBoard(root.boards[(i + step + root.boards.length) % root.boards.length].id)
  }
  function newBoard() {
    var id = newId()
    var n = root.boards.length + 1
    root.boards = root.boards.concat([{ id: id, name: "Board " + n }])
    Quickshell.execDetached(["mkdir", "-p", root.stateDir + "/boards/" + id])
    switchBoard(id)
    // drop straight into renaming it
    root.boardsMenuOpen = true
    root.renamingId = id
  }
  function renameBoard(id, name) {
    name = String(name || "").trim().slice(0, 60)
    root.renamingId = ""
    if (name === "") { focusBoard(); return }
    var next = []
    for (var i = 0; i < root.boards.length; i++)
      next.push(root.boards[i].id === id ? { id: id, name: name } : root.boards[i])
    root.boards = next
    saveIndex()
    focusBoard()
  }
  function deleteBoard(id) {
    if (!validId(id)) return
    if (root.confirmDeleteId !== id) { root.confirmDeleteId = id; return }
    root.confirmDeleteId = ""
    var rest = root.boards.filter(function(b) { return b.id !== id })
    if (rest.length === 0) {
      var fresh = newId()
      rest = [{ id: fresh, name: "Main" }]
      Quickshell.execDetached(["mkdir", "-p", root.stateDir + "/boards/" + fresh])
    }
    if (id === root.currentId) {
      // switch away first so the deleted board can't be saved back
      flushSave()
      root.ready = false
      root.history = []
      root.items = []; root.strokes = []
      root.boards = rest
      root.currentId = rest[0].id
    } else {
      root.boards = rest
    }
    saveIndex()
    Quickshell.execDetached(["rm", "-rf", "--", root.stateDir + "/boards/" + id])
  }
  function closeBoardsMenu() {
    root.boardsMenuOpen = false
    root.renamingId = ""
    root.confirmDeleteId = ""
  }

  // --- persistence (current board) ---------------------------------------------
  function load(raw) {
    try {
      var doc = JSON.parse(raw || "{}")
      root.items = Array.isArray(doc.items) ? doc.items : []
      root.strokes = Array.isArray(doc.strokes) ? doc.strokes : []
      var v = doc.view || {}
      root.zoom = clampZoom(Number(v.z) || 1)
      root.panX = isFinite(Number(v.x)) ? Number(v.x) : 0
      root.panY = isFinite(Number(v.y)) ? Number(v.y) : 0
    } catch (e) {
      // Never let an unreadable file get overwritten by an empty board:
      // keep a copy of it next to the store first.
      Quickshell.execDetached(["cp", "--", root.storePath, root.storePath + ".corrupt-" + Date.now()])
      root.items = []; root.strokes = []
      root.zoom = 1; root.panX = 0; root.panY = 0
    }
    var z = 1
    for (var i = 0; i < root.items.length; i++) z = Math.max(z, root.items[i].z || 0)
    root.topZ = z
    root.ready = true
    ink.requestPaint()
    grid.requestPaint()
  }
  function scheduleSave() { if (root.ready) saveTimer.restart() }
  function flushSave() {
    if (!saveTimer.running) return
    saveTimer.stop()
    writeStore()
  }
  function writeStore() {
    if (!root.ready || root.storePath === "") return
    store.setText(JSON.stringify({
      version: 2,
      view: { x: Math.round(root.panX), y: Math.round(root.panY), z: Math.round(root.zoom * 1000) / 1000 },
      items: root.items,
      strokes: root.strokes
    }) + "\n")
  }

  Timer { id: saveTimer; interval: 300; onTriggered: root.writeStore() }

  FileView {
    id: store
    path: root.storePath
    // Only this overlay writes the file; reloading on our own writes would
    // rebuild every card mid-typing.
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.load(text())
    onLoadFailed: if (root.storePath !== "") root.load("{}")
  }

  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", root.stateDir + "/boards"])
  // Plugin hot-reloads and shell restarts destroy this item: write anything
  // still waiting on the debounce first.
  Component.onDestruction: flushSave()

  // --- viewport ------------------------------------------------------------------
  function clampZoom(z) { return Math.max(root.minZoom, Math.min(root.maxZoom, z)) }
  function toWorld(vx, vy) { return Qt.point((vx - root.panX) / root.zoom, (vy - root.panY) / root.zoom) }
  function toView(wx, wy) { return Qt.point(wx * root.zoom + root.panX, wy * root.zoom + root.panY) }
  function zoomAt(vx, vy, z) {
    z = clampZoom(z)
    if (z === root.zoom) return
    root.panX = vx - (vx - root.panX) * z / root.zoom
    root.panY = vy - (vy - root.panY) * z / root.zoom
    root.zoom = z
    scheduleSave()
  }
  function zoomBy(f) { zoomAt(boardArea.width / 2, boardArea.height / 2, root.zoom * f) }
  function panBy(dx, dy) { root.panX += dx; root.panY += dy; scheduleSave() }
  function resetZoom() { zoomAt(boardArea.width / 2, boardArea.height / 2, 1) }
  // Fit everything on the board into view (never zooming past 100%).
  function fitAll() {
    var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
    for (var i = 0; i < root.items.length; i++) {
      var c = cardFor(root.items[i].id)
      var it = root.items[i]
      var w = c ? c.width : (it.w || 200), h = c ? c.height : (it.h || 120)
      x0 = Math.min(x0, it.x); y0 = Math.min(y0, it.y)
      x1 = Math.max(x1, it.x + w); y1 = Math.max(y1, it.y + h)
    }
    for (var s = 0; s < root.strokes.length; s++) {
      var p = root.strokes[s].p
      for (var j = 0; j + 1 < p.length; j += 2) {
        x0 = Math.min(x0, p[j]); y0 = Math.min(y0, p[j + 1])
        x1 = Math.max(x1, p[j]); y1 = Math.max(y1, p[j + 1])
      }
    }
    if (!isFinite(x0)) { root.zoom = 1; root.panX = 0; root.panY = 0; scheduleSave(); return }
    var pad = Style.space(40)
    var z = clampZoom(Math.min(1, (boardArea.width - 2 * pad) / Math.max(1, x1 - x0),
                                  (boardArea.height - 2 * pad) / Math.max(1, y1 - y0)))
    root.zoom = z
    root.panX = boardArea.width / 2 - (x0 + x1) / 2 * z
    root.panY = boardArea.height / 2 - (y0 + y1) / 2 * z
    scheduleSave()
  }
  onPanXChanged: { ink.requestPaint(); grid.requestPaint() }
  onPanYChanged: { ink.requestPaint(); grid.requestPaint() }
  onZoomChanged: { ink.requestPaint(); grid.requestPaint() }

  // --- items -------------------------------------------------------------------
  function newId() { return Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36) }

  function indexOf(id) {
    for (var i = 0; i < root.items.length; i++) if (root.items[i].id === id) return i
    return -1
  }
  // Mutate one item in place (no rebuild), then save.
  function patch(id, fields) {
    var i = indexOf(id)
    if (i < 0) return
    for (var k in fields) root.items[i][k] = fields[k]
    scheduleSave()
  }
  function raise(id) {
    root.topZ += 1
    patch(id, { z: root.topZ })
    return root.topZ
  }

  // Where a new card goes (world coords): under the pointer if it's on the
  // board, else a cascade around the middle of the view.
  function spawnPoint(w, h) {
    var vx, vy
    if (lastPointer.x >= 0 && lastPointer.y >= 0) {
      vx = lastPointer.x; vy = lastPointer.y
      var a = toWorld(vx, vy)
      return { x: Math.round(a.x - w / 2), y: Math.round(a.y - Style.space(12)) }
    }
    var n = root.items.length % 8
    var c = toWorld(boardArea.width / 2, boardArea.height / 2)
    return {
      x: Math.round(c.x - w / 2 + n * Style.space(22) - Style.space(80)),
      y: Math.round(c.y - h / 2 + n * Style.space(18) - Style.space(70))
    }
  }

  function addItem(item, focus) {
    root.topZ += 1
    item.id = newId()
    item.z = root.topZ
    item.ts = Date.now()
    var next = root.items.slice(); next.push(item)
    root.items = next
    pushHistory({ k: "add", id: item.id })
    scheduleSave()
    if (focus) Qt.callLater(function() { focusCard(item.id) })
    return item.id
  }
  function focusCard(id) { var c = cardFor(id); if (c) c.focusEditor() }

  function addNote(text) {
    var w = Style.space(240), h = Style.space(160)
    var p = spawnPoint(w, h)
    return addItem({ type: "note", x: p.x, y: p.y, w: w, h: h, color: 4, text: String(text || "").slice(0, 20000) }, text === undefined)
  }
  function addTodo() {
    var w = Style.space(240)
    var p = spawnPoint(w, Style.space(120))
    return addItem({ type: "todo", x: p.x, y: p.y, w: w, h: 0, color: 5, todos: [] }, true)
  }
  function addImage(path) {
    var w = Style.space(320), h = Style.space(240)
    var p = spawnPoint(w, h)
    addItem({ type: "image", x: p.x, y: p.y, w: w, h: h, color: 1, src: path, fit: true }, false)
  }

  function removeItem(id) {
    var i = indexOf(id)
    if (i < 0) return
    var gone = root.items[i]
    var next = root.items.slice(); next.splice(i, 1)
    root.items = next
    pushHistory({ k: "remove", item: gone })
    scheduleSave()
    focusBoard()
    // Image files stay on disk until the board is closed or switched with the
    // card still gone, so undo can bring the picture back.
  }

  // --- image context menu (right-click a picture) ------------------------------
  property string menuItemId: ""
  property string menuSrc: ""
  property point menuPos: Qt.point(0, 0)
  // x, y arrive in world coordinates (the card's parent)
  function openImageMenu(id, src, x, y) {
    root.menuItemId = id; root.menuSrc = src || ""
    root.menuPos = toView(x, y)
    focusBoard()
  }
  function closeMenu() { root.menuItemId = "" }
  function menuAction(what) {
    var id = root.menuItemId, src = root.menuSrc
    closeMenu()
    if (what === "copy") { copyImage(src); flash("Image copied") }
    else if (what === "open") { if (isOurFile(src)) Quickshell.execDetached(["xdg-open", src]) }
    else if (what === "front") { raise(id); rebuildZ(id) }
    else if (what === "back") sendToBack(id)
    else if (what === "delete") removeItem(id)
  }
  function cardFor(id) {
    for (var i = 0; i < cards.count; i++) { var c = cards.itemAt(i); if (c && c.itemId === id) return c }
    return null
  }
  function rebuildZ(id) { var c = cardFor(id); if (c) c.z = root.items[indexOf(id)].z; return true }
  function sendToBack(id) {
    var lo = 0
    for (var i = 0; i < root.items.length; i++) lo = Math.min(lo, root.items[i].z || 0)
    patch(id, { z: lo - 1 })
    var c = cardFor(id); if (c) c.z = lo - 1
  }

  function copyText(t) { Quickshell.execDetached(["wl-copy", "--", String(t || "")]) }
  function copyImage(path) {
    if (!isOurFile(path)) return
    Quickshell.execDetached(["sh", "-c", "wl-copy < \"$1\"", "sh", path])
  }
  function isOurFile(path) { return String(path || "").indexOf(root.stateDir + "/") === 0 }

  // Delete this board's image files that no card (and no undo entry) uses.
  function sweepImages() {
    if (root.boardDir === "" || !root.ready) return
    var keep = {}
    for (var i = 0; i < root.items.length; i++) if (root.items[i].src) keep[root.items[i].src] = true
    for (var j = 0; j < root.history.length; j++) {
      var h = root.history[j]
      if (h.k === "remove" && h.item && h.item.src) keep[h.item.src] = true
    }
    var args = ["sh", "-c", "dir=$1; shift; for f in \"$dir\"/img-*; do [ -e \"$f\" ] || continue; keep=0; for k in \"$@\"; do [ \"$f\" = \"$k\" ] && keep=1; done; [ $keep = 1 ] || rm -f -- \"$f\"; done", "sh", root.boardDir]
    for (var k in keep) args.push(k)
    Quickshell.execDetached(args)
  }
  onOpenedChanged: if (!opened && ready) { sweepImages(); root.history = [] }

  // --- ink -----------------------------------------------------------------------
  // px, py in world coordinates
  function eraseAt(px, py) {
    var r = Style.space(10) / root.zoom
    var keep = [], gone = []
    for (var i = 0; i < root.strokes.length; i++) {
      var s = root.strokes[i], hit = false
      var rr = (r + s.w / 2) * (r + s.w / 2)
      for (var j = 0; j + 1 < s.p.length; j += 2) {
        var dx = s.p[j] - px, dy = s.p[j + 1] - py
        if (dx * dx + dy * dy <= rr) { hit = true; break }
      }
      if (hit) gone.push(s); else keep.push(s)
    }
    if (gone.length === 0) return
    root.strokes = keep
    pushHistory({ k: "erase", strokes: gone })
    scheduleSave()
    ink.requestPaint()
  }
  function clearInk() {
    if (root.strokes.length === 0) return
    pushHistory({ k: "erase", strokes: root.strokes })
    root.strokes = []
    scheduleSave()
    ink.requestPaint()
  }

  // --- undo ------------------------------------------------------------------------
  function pushHistory(h) {
    var next = root.history.slice(-99); next.push(h)
    root.history = next
  }
  function undo() {
    if (root.history.length === 0) { flash("Nothing to undo"); return }
    var next = root.history.slice()
    var h = next.pop()
    root.history = next
    if (h.k === "stroke") {
      root.strokes = root.strokes.slice(0, -1)
      ink.requestPaint()
    } else if (h.k === "erase") {
      root.strokes = root.strokes.concat(h.strokes)
      ink.requestPaint()
    } else if (h.k === "add") {
      var i = indexOf(h.id)
      if (i >= 0) { var a = root.items.slice(); a.splice(i, 1); root.items = a }
    } else if (h.k === "remove") {
      var b = root.items.slice(); b.push(h.item); root.items = b
    }
    scheduleSave()
  }

  function flash(msg) { root.status = msg; statusTimer.restart() }
  Timer { id: statusTimer; interval: 2200; onTriggered: root.status = "" }

  // --- clipboard paste -----------------------------------------------------------
  function newImagePath(ext) { return root.boardDir + "/img-" + newId() + "." + (ext || "png") }

  function paste() {
    if (typesProc.running || root.boardDir === "") return
    typesProc.running = true
  }
  function handleTypes(raw) {
    var types = String(raw || "").split("\n").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
    if (types.length === 0) { flash("Clipboard is empty"); return }
    for (var i = 0; i < root.imageMimes.length; i++) {
      if (types.indexOf(root.imageMimes[i]) >= 0) {
        var mime = root.imageMimes[i]
        var ext = mime === "image/jpeg" ? "jpg" : mime.split("/")[1]
        imgProc.dest = newImagePath(ext)
        imgProc.command = ["sh", "-c", "wl-paste --no-newline --type \"$1\" > \"$2\"", "sh", mime, imgProc.dest]
        imgProc.running = true
        return
      }
    }
    if (types.indexOf("text/uri-list") >= 0) { uriProc.running = true; return }
    textProc.running = true
  }

  Process {
    id: typesProc
    command: ["wl-paste", "--list-types"]
    stdout: StdioCollector { id: typesOut; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) { root.flash("Clipboard is empty"); return }
      root.handleTypes(typesOut.text)
    }
  }
  Process {
    id: imgProc
    property string dest: ""
    onExited: function(code) {
      if (code === 0) { root.addImage(dest); root.flash("Pasted image") }
      else root.flash("Couldn't read the image")
    }
  }
  Process {
    id: textProc
    command: ["wl-paste", "--no-newline", "--type", "text"]
    stdout: StdioCollector { id: textOut; waitForEnd: true }
    onExited: function(code) {
      var t = String(textOut.text || "")
      if (code !== 0 || t.trim() === "") { root.flash("Nothing to paste"); return }
      root.addNote(t)
      root.flash("Pasted text")
    }
  }
  Process {
    id: uriProc
    command: ["wl-paste", "--no-newline", "--type", "text/uri-list"]
    stdout: StdioCollector { id: uriOut; waitForEnd: true }
    onExited: function(code) { root.importUris(String(uriOut.text || "").split(/\r?\n/)) }
  }

  // Copy image files (from a file manager copy or a drop) into the board dir,
  // one at a time; anything that isn't an image becomes a note with its path.
  property var importQueue: []
  function importUris(lines) {
    var queued = 0, others = []
    for (var i = 0; i < lines.length && i < 30; i++) {
      var u = String(lines[i] || "").trim()
      if (u === "" || u.charAt(0) === "#") continue
      if (u.indexOf("file://") !== 0) { others.push(u); continue }
      var path
      try { path = decodeURIComponent(u.slice(7)) } catch (e) { continue }
      var ext = path.split(".").pop().toLowerCase()
      if (root.imageExts.indexOf(ext) >= 0) {
        root.importQueue = root.importQueue.concat([{ src: path, ext: ext }])
        queued++
      } else others.push(path)
    }
    if (others.length) root.addNote(others.join("\n"))
    if (queued) nextImport()
    else if (!others.length) flash("Nothing to paste")
  }
  function nextImport() {
    if (importProc.running || root.importQueue.length === 0) return
    var job = root.importQueue[0]
    root.importQueue = root.importQueue.slice(1)
    importProc.dest = newImagePath(job.ext)
    importProc.command = ["cp", "--", job.src, importProc.dest]
    importProc.running = true
  }
  Process {
    id: importProc
    property string dest: ""
    onExited: function(code) {
      if (code === 0) root.addImage(dest)
      else root.flash("Couldn't copy a file")
      root.nextImport()
    }
  }

  // --- screen snip ---------------------------------------------------------------
  function snip() {
    if (snipProc.running || root.boardDir === "") return
    snipProc.dest = newImagePath("png")
    snipProc.reopenMode = root.mode
    snipProc.command = ["sh", "-c", "sleep 0.35; g=$(slurp -d) || exit 1; grim -g \"$g\" \"$1\"", "sh", snipProc.dest]
    root.dismiss()
    snipProc.running = true
  }
  Process {
    id: snipProc
    property string dest: ""
    property string reopenMode: "center"
    onExited: function(code) {
      if (code === 0) root.addImage(dest)
      Quickshell.execDetached(["omarchy-shell", "shell", "summon",
        (root.manifest && root.manifest.id) || "board.popup",
        JSON.stringify({ mode: reopenMode })])
    }
  }

  // --- UI ----------------------------------------------------------------------------
  component ToolButton: Rectangle {
    id: tb
    property string label: ""
    property bool active: false
    signal clicked()
    implicitWidth: tbText.implicitWidth + Style.space(18)
    implicitHeight: Style.space(28)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    radius: Math.min(Style.cornerRadius, Style.space(6))
    color: active
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
      : (tbHover.hovered ? Style.normalFillFor(Color.foreground, Color.accent) : "transparent")
    border.width: active ? 1 : 0
    border.color: Color.accent
    HoverHandler { id: tbHover }
    Text {
      id: tbText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tb.label
      color: tb.active ? Color.accent : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: tb.clicked()
    }
  }
  component Sep: Rectangle {
    width: 1; height: Style.space(18)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18)
  }
  component Gap: Item { width: Style.space(8); height: 1 }

  PanelWindow {
    id: panel
    visible: root.opened || card.opacity > 0
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; bottom: true; left: true; right: true }

    WlrLayershell.namespace: "board-popup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // dim backdrop; click outside the board to close
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, root.opened ? (root.mode === "quake" ? 0.2 : 0.35) : 0)
      Behavior on color { ColorAnimation { duration: Style.duration(150) } }
      MouseArea {
        anchors.fill: parent
        enabled: root.opened
        onClicked: root.dismiss()
      }
    }

    BorderSurface {
      id: card
      readonly property bool quake: root.mode === "quake"
      readonly property int edge: Style.space(10)

      x: quake ? edge : Math.round((parent.width - width) / 2)
      width: quake ? parent.width - 2 * edge : Math.round(parent.width * 0.86)
      height: quake ? Math.round(parent.height * 0.62) : Math.round(parent.height * 0.84)
      // quake: slides down from above the top edge; centre: settles in place
      y: quake
        ? (root.opened ? edge : -height - edge)
        : Math.round((parent.height - height) / 2)
      Behavior on y {
        enabled: card.quake
        NumberAnimation { duration: Style.duration(root.opened ? 180 : 120); easing.type: Easing.OutCubic }
      }

      padding: Style.spacing.panelPadding
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: root.cardBorder
      opacity: root.opened ? 1.0 : 0
      scale: quake ? 1.0 : (root.opened ? 1.0 : 0.97)
      Behavior on opacity { NumberAnimation { duration: Style.duration(root.opened ? 180 : 120); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

      MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onPressed: root.closeBoardsMenu() }

      // keyboard shortcuts live on this item; text fields take focus while
      // you type and Esc hands it back
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(e) {
          if (e.isAutoRepeat && e.key !== Qt.Key_Plus && e.key !== Qt.Key_Equal && e.key !== Qt.Key_Minus) { e.accepted = true; return }
          var ctrl = (e.modifiers & Qt.ControlModifier) !== 0
          if (ctrl) {
            switch (e.key) {
            case Qt.Key_V: root.paste(); break
            case Qt.Key_Z: root.undo(); break
            case Qt.Key_Plus: case Qt.Key_Equal: root.zoomBy(1.2); break
            case Qt.Key_Minus: root.zoomBy(1 / 1.2); break
            case Qt.Key_0: root.resetZoom(); break
            case Qt.Key_Tab: root.cycleBoard(1); break
            case Qt.Key_Backtab: root.cycleBoard(-1); break
            default: return
            }
            e.accepted = true
            return
          }
          switch (e.key) {
          case Qt.Key_Escape:
            if (root.boardsMenuOpen) root.closeBoardsMenu()
            else if (root.menuItemId !== "") root.closeMenu()
            else if (root.tool !== "select") root.tool = "select"
            else root.dismiss()
            break
          case Qt.Key_V: root.tool = "select"; break
          case Qt.Key_P: case Qt.Key_B: root.tool = "pen"; break
          case Qt.Key_E: root.tool = "eraser"; break
          case Qt.Key_N: root.addNote(); break
          case Qt.Key_T: root.addTodo(); break
          case Qt.Key_S: root.snip(); break
          case Qt.Key_F: root.fitAll(); break
          case Qt.Key_BracketLeft: root.penWidth = Math.max(1, root.penWidth - 1); break
          case Qt.Key_BracketRight: root.penWidth = Math.min(24, root.penWidth + 1); break
          default:
            if (e.key >= Qt.Key_1 && e.key <= Qt.Key_6) {
              root.penColor = e.key - Qt.Key_1
              if (root.tool !== "pen") root.tool = "pen"
              break
            }
            return
          }
          e.accepted = true
        }
      }

      Column {
        id: content
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        height: card.height - card.contentTopInset - card.contentBottomInset
        spacing: Style.space(10)

        // --- toolbar --------------------------------------------------------------
        Item {
          id: toolbar
          width: parent.width
          height: Style.space(30)
          z: 10

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            // board switcher
            Rectangle {
              id: boardButton
              anchors.verticalCenter: parent.verticalCenter
              implicitWidth: Math.min(Style.space(220), boardLabel.implicitWidth + Style.space(30))
              width: implicitWidth
              height: Style.space(30)
              radius: Math.min(Style.cornerRadius, Style.space(6))
              color: bbHover.hovered || root.boardsMenuOpen ? Style.normalFillFor(Color.foreground, Color.accent) : "transparent"
              HoverHandler { id: bbHover }
              Text {
                id: boardLabel
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: caret.left
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.currentName
                elide: Text.ElideRight
                color: Color.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Text {
                id: caret
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "▾"
                color: Qt.darker(Color.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.boardsMenuOpen ? root.closeBoardsMenu() : (root.boardsMenuOpen = true)
              }
            }

            Gap {}
            ToolButton { label: "Move"; active: root.tool === "select"; onClicked: root.tool = "select" }
            ToolButton { label: "Pen"; active: root.tool === "pen"; onClicked: root.tool = "pen" }
            ToolButton { label: "Eraser"; active: root.tool === "eraser"; onClicked: root.tool = "eraser" }
            Gap {}

            Repeater {
              model: root.palette.length
              delegate: Rectangle {
                required property int index
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18); height: width; radius: width / 2
                color: root.paletteColor(index)
                border.width: root.penColor === index ? 2 : 0
                border.color: Color.foreground
                scale: root.penColor === index ? 1.15 : 1
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(2)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.penColor = parent.index; root.tool = "pen" }
                }
              }
            }

            ToolButton { label: "−"; onClicked: root.penWidth = Math.max(1, root.penWidth - 1) }
            Item {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22); height: Style.space(22)
              Rectangle {
                anchors.centerIn: parent
                width: Math.max(3, Math.min(Style.space(22), root.penWidth * 1.4)); height: width; radius: width / 2
                color: root.paletteColor(root.penColor)
              }
            }
            ToolButton { label: "+"; onClicked: root.penWidth = Math.min(24, root.penWidth + 1) }

            Gap {}
            Sep {}
            Gap {}
            ToolButton { label: "+ Note"; onClicked: root.addNote() }
            ToolButton { label: "+ Todo"; onClicked: root.addTodo() }
            ToolButton { label: "Paste"; onClicked: root.paste() }
            ToolButton { label: "Snip"; onClicked: root.snip() }
            Gap {}
            Sep {}
            Gap {}
            ToolButton { label: "Undo"; onClicked: root.undo() }
            ToolButton { label: "Clear ink"; onClicked: root.clearInk() }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            ToolButton { label: "−"; onClicked: root.zoomBy(1 / 1.25) }
            ToolButton {
              label: Math.round(root.zoom * 100) + "%"
              implicitWidth: Style.space(58)
              onClicked: root.resetZoom()
            }
            ToolButton { label: "+"; onClicked: root.zoomBy(1.25) }
            ToolButton { label: "Fit"; onClicked: root.fitAll() }
            Gap {}
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "󰅖"
              color: Color.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.dismiss()
              }
            }
          }

          // --- boards menu ------------------------------------------------------
          Rectangle {
            id: boardsMenu
            visible: root.boardsMenuOpen
            x: boardButton.x
            y: toolbar.height + Style.space(4)
            width: Style.space(260)
            height: boardsCol.implicitHeight + Style.space(8)
            radius: Math.min(Style.cornerRadius, Style.space(6))
            color: Color.popups.background
            border.width: 1
            border.color: Color.popups.border

            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

            Column {
              id: boardsCol
              x: Style.space(4); y: Style.space(4)
              width: parent.width - Style.space(8)

              Repeater {
                model: root.boards
                delegate: Rectangle {
                  id: brow
                  required property var modelData
                  readonly property bool isCurrent: modelData.id === root.currentId
                  readonly property bool renaming: root.renamingId === modelData.id
                  readonly property bool confirming: root.confirmDeleteId === modelData.id
                  width: boardsCol.width
                  height: Style.space(30)
                  radius: Math.min(Style.cornerRadius, Style.space(4))
                  color: browHover.hovered && !renaming ? Style.normalFillFor(Color.foreground, Color.accent) : "transparent"
                  HoverHandler { id: browHover }

                  MouseArea {
                    anchors.fill: parent
                    enabled: !brow.renaming
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.switchBoard(brow.modelData.id)
                    onDoubleClicked: root.renamingId = brow.modelData.id
                  }

                  Text {
                    visible: !brow.renaming
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    anchors.right: actions.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: (brow.isCurrent ? "● " : "   ") + brow.modelData.name
                    color: brow.isCurrent ? Color.accent : Color.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  TextField {
                    id: renameField
                    visible: brow.renaming
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    verticalPadding: Style.space(3)
                    onVisibleChanged: if (visible) { text = brow.modelData.name; selectAll(); forceActiveFocus() }
                    Component.onCompleted: if (visible) { text = brow.modelData.name; selectAll(); forceActiveFocus() }
                    onAccepted: root.renameBoard(brow.modelData.id, text)
                    Keys.onEscapePressed: { root.renamingId = ""; root.focusBoard() }
                  }

                  Row {
                    id: actions
                    visible: !brow.renaming
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)
                    opacity: browHover.hovered || brow.confirming ? 1 : 0

                    Text {
                      textFormat: Text.PlainText
                      text: "rename"
                      color: Qt.darker(Color.foreground, 1.3)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.space(4)
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.renamingId = brow.modelData.id
                      }
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: brow.confirming ? "delete?" : "󰅖"
                      color: brow.confirming ? Color.urgent : Qt.darker(Color.foreground, 1.3)
                      font.family: root.fontFamily
                      font.pixelSize: brow.confirming ? Style.font.caption : Style.font.body
                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.space(4)
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.deleteBoard(brow.modelData.id)
                      }
                    }
                  }
                }
              }

              Rectangle {
                width: boardsCol.width; height: 1
                color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
              }
              Rectangle {
                width: boardsCol.width
                height: Style.space(30)
                radius: Math.min(Style.cornerRadius, Style.space(4))
                color: nbHover.hovered ? Style.normalFillFor(Color.foreground, Color.accent) : "transparent"
                HoverHandler { id: nbHover }
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "+ New board"
                  color: Color.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.newBoard()
                }
              }
            }
          }
        }

        // --- the board (viewport onto the infinite canvas) ----------------------
        Rectangle {
          id: boardArea
          width: parent.width
          height: parent.height - toolbar.height - parent.spacing
          radius: Math.min(Style.cornerRadius, Style.space(8))
          clip: true
          color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.025)
          border.width: 1
          border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08)

          // dot grid, in screen space but following pan/zoom
          Canvas {
            id: grid
            anchors.fill: parent
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d"); ctx.reset()
              var c = Color.foreground
              ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, 0.12)
              var step = Style.space(24) * root.zoom
              while (step < Style.space(14)) step *= 4
              var ox = ((root.panX % step) + step) % step
              var oy = ((root.panY % step) + step) % step
              for (var x = ox; x < width; x += step)
                for (var y = oy; y < height; y += step)
                  ctx.fillRect(x - 1, y - 1, 2, 2)
            }
          }

          // empty space: click drops text focus, drag pans, double-click
          // drops a note; middle-drag pans from anywhere (even over cards)
          MouseArea {
            id: panArea
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            cursorShape: dragging ? Qt.ClosedHandCursor : Qt.ArrowCursor
            property bool dragging: false
            property real lx: 0
            property real ly: 0
            onPressed: function(m) {
              root.closeMenu(); root.closeBoardsMenu()
              lx = m.x; ly = m.y; dragging = false
            }
            onPositionChanged: function(m) {
              if (!pressed) return
              var dx = m.x - lx, dy = m.y - ly
              if (!dragging && dx * dx + dy * dy < 9) return
              dragging = true
              root.panX += dx; root.panY += dy
              lx = m.x; ly = m.y
            }
            onReleased: {
              if (dragging) root.scheduleSave()
              else root.focusBoard()
              dragging = false
            }
            onDoubleClicked: function(m) {
              if (m.button !== Qt.LeftButton) return
              root.lastPointer = Qt.point(m.x, m.y); root.addNote()
            }
          }

          HoverHandler {
            id: boardHover
            onPointChanged: root.lastPointer = point.position
            onHoveredChanged: if (!hovered) root.lastPointer = Qt.point(-1, -1)
          }

          // mouse wheel zooms around the pointer; a trackpad's two-finger
          // scroll pans (Ctrl+scroll zooms); pinch zooms
          WheelHandler {
            target: null
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(ev) {
              var trackpad = ev.pixelDelta.x !== 0 || ev.pixelDelta.y !== 0
              var ctrl = (ev.modifiers & Qt.ControlModifier) !== 0
              if (trackpad && !ctrl) {
                root.panBy(ev.pixelDelta.x, ev.pixelDelta.y)
              } else {
                var dy = trackpad ? ev.pixelDelta.y / 2 : ev.angleDelta.y / 8
                root.zoomAt(ev.x, ev.y, root.zoom * Math.pow(1.0018, dy * 6))
              }
              ev.accepted = true
            }
          }
          PinchHandler {
            target: null
            property real lastScale: 1
            onActiveChanged: lastScale = 1
            onActiveScaleChanged: {
              var f = activeScale / lastScale
              lastScale = activeScale
              root.zoomAt(centroid.position.x, centroid.position.y, root.zoom * f)
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.ready && root.items.length === 0 && root.strokes.length === 0
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "Empty board.\nCtrl+V to paste an image or text · N note · T todo · S snip the screen · P draw\nDrag empty space to pan, scroll to zoom. Double-click to drop a note. Drag image files in."
            color: Qt.darker(Color.foreground, 1.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            lineHeight: 1.4
          }

          // the infinite canvas: cards live here in world coordinates
          Item {
            id: world
            x: root.panX
            y: root.panY
            scale: root.zoom
            transformOrigin: Item.TopLeft
            width: 1; height: 1

            Repeater {
              id: cards
              model: root.items
              delegate: Card { board: root }
            }
          }

          // ink layer — above cards so you can annotate pictures; it only
          // takes the mouse while the pen or eraser is active
          Canvas {
            id: ink
            anchors.fill: parent
            z: 100000
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            function drawStroke(ctx, s) {
              var p = s.p
              if (!p || p.length < 2) return
              ctx.strokeStyle = String(root.paletteColor(s.c))
              ctx.fillStyle = ctx.strokeStyle
              ctx.lineWidth = s.w
              if (p.length < 4) {
                ctx.beginPath(); ctx.arc(p[0], p[1], s.w / 2, 0, Math.PI * 2); ctx.fill()
                return
              }
              ctx.beginPath()
              ctx.moveTo(p[0], p[1])
              // smooth through segment midpoints
              for (var i = 2; i + 3 < p.length; i += 2) {
                var mx = (p[i] + p[i + 2]) / 2, my = (p[i + 1] + p[i + 3]) / 2
                ctx.quadraticCurveTo(p[i], p[i + 1], mx, my)
              }
              ctx.lineTo(p[p.length - 2], p[p.length - 1])
              ctx.stroke()
            }

            onPaint: {
              var ctx = getContext("2d"); ctx.reset()
              ctx.translate(root.panX, root.panY)
              ctx.scale(root.zoom, root.zoom)
              ctx.lineCap = "round"; ctx.lineJoin = "round"
              for (var i = 0; i < root.strokes.length; i++) drawStroke(ctx, root.strokes[i])
              if (root.current) drawStroke(ctx, root.current)
            }

            MouseArea {
              id: inkMouse
              anchors.fill: parent
              enabled: root.tool !== "select"
              hoverEnabled: true
              cursorShape: Qt.CrossCursor
              onPressed: function(m) {
                root.focusBoard()
                var w = root.toWorld(m.x, m.y)
                if (root.tool === "eraser") { root.eraseAt(w.x, w.y); return }
                // width is stored in world units so it looks like the chosen
                // size at the zoom you drew it at
                root.current = { c: root.penColor, w: Math.round(root.penWidth / root.zoom * 100) / 100,
                                 p: [Math.round(w.x * 10) / 10, Math.round(w.y * 10) / 10] }
                ink.requestPaint()
              }
              onPositionChanged: function(m) {
                if (!pressed) return
                var w = root.toWorld(m.x, m.y)
                if (root.tool === "eraser") { root.eraseAt(w.x, w.y); return }
                if (!root.current) return
                var p = root.current.p
                var dx = (w.x - p[p.length - 2]) * root.zoom, dy = (w.y - p[p.length - 1]) * root.zoom
                if (dx * dx + dy * dy < 4) return
                p.push(Math.round(w.x * 10) / 10, Math.round(w.y * 10) / 10)
                ink.requestPaint()
              }
              onReleased: {
                if (!root.current) return
                root.strokes = root.strokes.concat([root.current])
                root.current = null
                root.pushHistory({ k: "stroke" })
                root.scheduleSave()
                ink.requestPaint()
              }
            }

            // brush / eraser preview ring
            Rectangle {
              visible: inkMouse.enabled && inkMouse.containsMouse
              readonly property real d: root.tool === "eraser" ? Style.space(20) : Math.max(4, root.penWidth)
              width: d; height: d; radius: d / 2
              x: inkMouse.mouseX - d / 2
              y: inkMouse.mouseY - d / 2
              color: root.tool === "eraser" ? "transparent" : root.paletteColor(root.penColor)
              border.width: root.tool === "eraser" ? 1 : 0
              border.color: Color.foreground
              opacity: 0.8
            }
          }

          Text {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(8)
            z: 100002
            textFormat: Text.PlainText
            text: root.status !== "" ? root.status
              : "V move · P pen · E erase · N note · T todo · S snip · ^V paste · ^Z undo · scroll zoom · F fit · ^Tab boards · Esc close"
            color: root.status !== "" ? Color.accent : Qt.darker(Color.foreground, 1.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // right-click menu for pictures
          MouseArea {
            anchors.fill: parent
            z: 100003
            visible: root.menuItemId !== ""
            acceptedButtons: Qt.AllButtons
            onPressed: root.closeMenu()
          }
          Rectangle {
            id: imgMenu
            z: 100004
            visible: root.menuItemId !== ""
            x: Math.max(Style.space(4), Math.min(root.menuPos.x, boardArea.width - width - Style.space(4)))
            y: Math.max(Style.space(4), Math.min(root.menuPos.y, boardArea.height - height - Style.space(4)))
            width: Style.space(170)
            height: menuCol.implicitHeight + Style.space(8)
            radius: Math.min(Style.cornerRadius, Style.space(6))
            color: Color.popups.background
            border.width: 1
            border.color: Color.popups.border

            Column {
              id: menuCol
              x: Style.space(4); y: Style.space(4)
              width: parent.width - Style.space(8)
              Repeater {
                model: [
                  { k: "copy", t: "Copy image" },
                  { k: "open", t: "Open in viewer" },
                  { k: "front", t: "Bring to front" },
                  { k: "back", t: "Send to back" },
                  { k: "delete", t: "Delete" }
                ]
                delegate: Rectangle {
                  required property var modelData
                  width: menuCol.width
                  height: Style.space(28)
                  radius: Math.min(Style.cornerRadius, Style.space(4))
                  color: miHover.hovered ? Style.normalFillFor(Color.foreground, Color.accent) : "transparent"
                  HoverHandler { id: miHover }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: Style.space(10)
                    textFormat: Text.PlainText
                    text: parent.modelData.t
                    color: parent.modelData.k === "delete" ? Color.urgent : Color.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.menuAction(parent.modelData.k)
                  }
                }
              }
            }
          }

          // drag image files (or text) in from anywhere
          DropArea {
            anchors.fill: parent
            z: 100001
            onDropped: function(drop) {
              root.lastPointer = Qt.point(drop.x, drop.y)
              if (drop.hasUrls) {
                var lines = []
                for (var i = 0; i < drop.urls.length; i++) lines.push(String(drop.urls[i]))
                root.importUris(lines)
              } else if (drop.hasText) {
                root.addNote(drop.text)
              }
              drop.accept()
            }
          }
        }
      }
    }
  }
}
