# omarchy-board

A bulletin board for the [Omarchy](https://omarchy.org/) shell. Paste
screenshots and text onto it, pin sticky notes and todo lists, snip part of
the screen, and draw over everything, on an infinite canvas with as many
boards as you want.

It's a Quickshell plugin, so it opens instantly as an overlay, follows your
Omarchy theme, and survives `omarchy update`.

## Features

- **Paste anything** with `Ctrl+V`: images, text, or files copied in a file
  manager. Dragging image files onto the board works too.
- **Sticky notes** (`N`, or double-click empty space) and **todo cards** (`T`).
  Click a card's colour dot to cycle its colour.
- **Snip** (`S`): the board hides, you drag over part of the screen, and the
  capture lands on the board.
- **Images** sit on the board with no frame. Left-drag moves them; right-click
  gives Copy, Open in viewer, Bring to front, Send to back, Delete. Resizing
  keeps the aspect ratio.
- **Ink**: freehand pen (`P`) and eraser (`E`) over everything, six colours
  (`1`–`6`), adjustable size (`[` `]`).
- **Infinite canvas**: drag empty space or middle-drag anywhere to pan; scroll,
  pinch or `Ctrl`+scroll to zoom (5%–800%); `F` fits everything into view,
  `Ctrl+0` resets to 100%.
- **Multiple boards**: switch, create, rename and delete from the menu on the
  board's name; `Ctrl+Tab` cycles through them.
- **Two layouts**: centred, or quake-style dropping down from the top edge.
- **Undo** (`Ctrl+Z`) for ink, added cards and deleted cards.
- **Autosaves** everything (cards, ink, images, and where you were zoomed)
  a moment after each change, with atomic writes.

## Install

Requires Omarchy 4 with its shell, plus `wl-clipboard`, `grim` and `slurp`
(all part of a stock Omarchy install).

```bash
git clone https://github.com/Crossbow2560/omarchy-board.git
cd omarchy-board
./install.sh          # add --bar for a bar button, --link to symlink instead of copy
```

`omarchy plugin add` handles one plugin per repo, and Board is two (the
overlay and an optional bar button), so it ships its own installer.

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + B", "Bulletin board", "omarchy-shell shell toggle board.popup")
-- or quake-style:
o.bind("SUPER + ALT + grave", "Bulletin board (quake)", [[omarchy-shell shell toggle board.popup '{"mode":"quake"}']])
```

If it doesn't open straight away, run `omarchy restart shell`.

## Keys

| Key | Action |
|---|---|
| `Ctrl+V` | Paste image / text / copied files |
| `N` / `T` | New note / todo card |
| `S` | Snip a screen region |
| `V` / `P` / `E` | Move / pen / eraser |
| `1`–`6`, `[` `]` | Pen colour, pen size |
| Scroll, pinch, `Ctrl` `+` / `−` | Zoom |
| Drag empty space, middle-drag | Pan |
| `F` / `Ctrl+0` | Fit all / 100% |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous board |
| `Ctrl+Z` | Undo |
| `Esc` | Leave text field / tool, then close |

## Storage

```
~/.local/state/omarchy/board/
├── boards.json            # list of boards + which one is open
└── boards/<id>/
    ├── board.json         # cards, ink, viewport
    └── img-*.png          # pasted and snipped images for that board
```

Images that no card uses any more are cleaned up when you close or switch
boards.

## Uninstall

```bash
./uninstall.sh           # keeps your boards
./uninstall.sh --purge   # also deletes them
```

## License

MIT
