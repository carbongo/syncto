#!/bin/sh
# syncto uninstaller — removes everything install.sh put in place, except
# user config (the config dir and its targets file are left untouched).
#
# Usage: ./uninstall.sh
# or:    ./install.sh --uninstall

set -eu

PROG_NAME="syncto"
SHARE_DIR="$HOME/.local/share/$PROG_NAME"
BIN_DIR="$HOME/.local/bin"
BIN_PATH="$BIN_DIR/$PROG_NAME"
PATH_MARKER="# added by syncto installer"
PATH_LINE="export PATH=\"\$HOME/.local/bin:\$PATH\""

# Best-effort: if a scheduler unit was installed, remove it first while the
# syncto binary is still around to do so.
if [ -x "$BIN_PATH" ] || [ -L "$BIN_PATH" ]; then
  "$BIN_PATH" --uninstall-service 2>/dev/null || true
fi

if [ -L "$BIN_PATH" ] || [ -f "$BIN_PATH" ]; then
  rm -f "$BIN_PATH"
  echo "syncto: removed $BIN_PATH"
fi

if [ -d "$SHARE_DIR" ]; then
  rm -rf "$SHARE_DIR"
  echo "syncto: removed $SHARE_DIR"
fi

# Strip the PATH lines we added, from every rc file we might have touched.
for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  grep -Fq "$PATH_MARKER" "$rc" 2>/dev/null || continue
  tmp="$rc.syncto-uninstall.tmp"
  # Drop the marker comment line and the PATH export line that follows it,
  # and any single blank line immediately preceding the marker that we
  # ourselves inserted (see install.sh's printf '\n%s\n%s\n').
  awk -v marker="$PATH_MARKER" -v pathline="$PATH_LINE" '
    { lines[NR] = $0 }
    END {
      skip_next_blank = 0
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        if (line == marker) {
          # skip this line and, if next line is the path export, skip it too
          if (i + 1 <= NR && lines[i + 1] == pathline) {
            i++
          }
          continue
        }
        print line
      }
    }
  ' "$rc" > "$tmp"
  mv "$tmp" "$rc"
  echo "syncto: removed PATH line from $rc"
done

cat <<EOF

syncto has been uninstalled. Your config and targets were left in place:
  ${XDG_CONFIG_HOME:-$HOME/.config}/syncto/
Remove that directory yourself if you no longer need it.
EOF
