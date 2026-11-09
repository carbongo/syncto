#!/bin/sh
# syncto installer: copies syncto.sh to ~/.local/share/syncto, links
# ~/.local/bin/syncto, seeds a config and puts ~/.local/bin on PATH. Idempotent.
# Usage: ./install.sh [--uninstall]. Scheduler units: syncto start

set -eu

PROG_NAME="syncto"
SHARE_DIR="$HOME/.local/share/$PROG_NAME"
BIN_DIR="$HOME/.local/bin"
BIN_PATH="$BIN_DIR/$PROG_NAME"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$PROG_NAME"
CONFIG_FILE="$CONFIG_DIR/config"
PATH_MARKER="# added by syncto installer"
PATH_LINE="export PATH=\"\$HOME/.local/bin:\$PATH\""

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)

usage() {
  cat <<EOF
Usage: install.sh [--uninstall]

  (no args)     install/update syncto into \$HOME/.local
  --uninstall   remove syncto (keeps your config and targets)
  -h, --help    show this help
EOF
}

# rc file for the user's login shell (same detection as cdto).
rc_file() {
  case "${SHELL:-}" in
    */zsh)  echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    */bash)
      case "$(uname -s 2>/dev/null || true)" in
        Darwin) echo "$HOME/.bash_profile" ;;
        *)      echo "$HOME/.bashrc" ;;
      esac
      ;;
    *)      echo "$HOME/.profile" ;;
  esac
}

do_uninstall() {
  uninstaller="$script_dir/uninstall.sh"
  if [ -n "$script_dir" ] && [ -f "$uninstaller" ]; then
    exec sh "$uninstaller"
  fi
  echo "syncto: uninstall.sh not found next to install.sh; cannot uninstall" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --uninstall) do_uninstall ;;
    -h|--help) usage; exit 0 ;;
    *) echo "syncto: unknown argument: $arg" >&2; usage >&2; exit 3 ;;
  esac
done

# Warn on an OS syncto is not tested on.
os=$(uname -s 2>/dev/null || echo unknown)
case "$os" in
  Darwin|Linux) : ;;
  *) echo "syncto: warning: unrecognized OS '$os', proceeding anyway" >&2 ;;
esac

if [ -z "$script_dir" ] || [ ! -f "$script_dir/syncto.sh" ]; then
  echo "syncto: could not find syncto.sh next to install.sh (looked in '$script_dir')" >&2
  exit 1
fi

mkdir -p "$SHARE_DIR"
cp "$script_dir/syncto.sh" "$SHARE_DIR/syncto.sh"
chmod +x "$SHARE_DIR/syncto.sh"

mkdir -p "$BIN_DIR"
rm -f "$BIN_PATH"
ln -s "$SHARE_DIR/syncto.sh" "$BIN_PATH"
chmod +x "$BIN_PATH" 2>/dev/null || true
echo "syncto: installed to $SHARE_DIR, linked at $BIN_PATH"

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
  if [ -n "$script_dir" ] && [ -f "$script_dir/config.example" ]; then
    cp "$script_dir/config.example" "$CONFIG_FILE"
    echo "syncto: seeded $CONFIG_FILE from config.example"
  else
    cat > "$CONFIG_FILE" <<EOF
# syncto global config: key=value, one per line.
interval=120
watch=off
mode=sync
branch=main
remote=origin
log=\$HOME/.local/state/syncto/syncto.log
EOF
    echo "syncto: wrote default config to $CONFIG_FILE (no config.example found)"
  fi
else
  echo "syncto: config already present at $CONFIG_FILE, leaving it alone"
fi

# Make sure ~/.local/bin is on PATH for future shells.
case ":$PATH:" in
  *":$BIN_DIR:"*) on_path=1 ;;
  *) on_path=0 ;;
esac

rc="$(rc_file)"
if [ "$on_path" = "1" ]; then
  echo "syncto: $BIN_DIR is already on PATH"
elif [ -f "$rc" ] && grep -Fq "$PATH_MARKER" "$rc" 2>/dev/null; then
  echo "syncto: PATH line already present in $rc"
else
  printf '\n%s\n%s\n' "$PATH_MARKER" "$PATH_LINE" >> "$rc"
  echo "syncto: added $BIN_DIR to PATH via $rc"
fi

cat <<EOF

Next steps:
  1. Restart your shell, or run:  export PATH="$BIN_DIR:\$PATH"
  2. Add a sync target:           syncto add <name> <path>
  3. Check status any time:       syncto
  4. Install a scheduler unit:    syncto start
     (schedulers have no ssh-agent: if a target pushes over ssh, give it
     a key= option so pushes don't hang)
EOF
