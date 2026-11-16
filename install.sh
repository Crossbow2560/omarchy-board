#!/bin/bash
# Install the Board plugins (board.popup overlay + optional board bar button)
# into the Omarchy shell.
#
#   ./install.sh            copy the plugins into ~/.config/omarchy/plugins
#   ./install.sh --link     symlink instead (for hacking on a checkout)
#   ./install.sh --bar      also put the Board button on the bar
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$HOME/.config/omarchy/plugins"
link=0
bar=0

for arg in "$@"; do
  case "$arg" in
  --link) link=1 ;;
  --bar) bar=1 ;;
  -h | --help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "install.sh: unknown option: $arg" >&2; exit 1 ;;
  esac
done

for cmd in omarchy omarchy-shell wl-paste wl-copy grim slurp; do
  command -v "$cmd" >/dev/null || { echo "install.sh: '$cmd' not found" >&2; exit 1; }
done

mkdir -p "$dest"
for dir in board board-popup; do
  omarchy plugin validate "$here/$dir"
  target="$dest/$dir"
  if [[ -e $target || -L $target ]]; then
    echo "install.sh: $target already exists; remove it first (./uninstall.sh)" >&2
    exit 1
  fi
  if (( link )); then ln -s "$here/$dir" "$target"; else cp -r "$here/$dir" "$target"; fi
  echo "Installed $dir -> $target"
done

omarchy-shell shell rescanPlugins >/dev/null
sleep 0.5
omarchy plugin enable board.popup
(( bar )) && omarchy plugin enable board --section right

cat <<'EOF'

Board is installed. Open it with:

  omarchy-shell shell toggle board.popup                      # centred
  omarchy-shell shell toggle board.popup '{"mode":"quake"}'   # drops from the top

To bind keys, add to ~/.config/hypr/bindings.lua:

  o.bind("SUPER + ALT + B", "Bulletin board", "omarchy-shell shell toggle board.popup")

If the board doesn't open, run: omarchy restart shell
EOF
