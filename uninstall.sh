#!/bin/bash
# Remove the Board plugins from the Omarchy shell. Your boards in
# ~/.local/state/omarchy/board are kept unless you pass --purge.
set -euo pipefail

dest="$HOME/.config/omarchy/plugins"
purge=0
[[ ${1:-} == --purge ]] && purge=1

omarchy plugin disable board.popup 2>/dev/null || true
omarchy plugin disable board 2>/dev/null || true
for dir in board board-popup; do
  if [[ -e $dest/$dir || -L $dest/$dir ]]; then
    rm -rf -- "${dest:?}/$dir"
    echo "Removed $dest/$dir"
  fi
done
omarchy-shell shell rescanPlugins >/dev/null || true

state="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/board"
if (( purge )); then
  rm -rf -- "$state"
  echo "Deleted all boards in $state"
else
  echo "Your boards are still in $state (rerun with --purge to delete them)"
fi
