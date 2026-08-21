#!/usr/bin/env bash
# Install amuxd as a socket-activated systemd user service.
#
# After this, the first `amux-cli` call starts the daemon on demand: nothing
# needs to be running beforehand and nothing needs to be launched by hand.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# Where amuxd lives. Prefer an explicit argument, then an installed copy, then
# this checkout's build output.
if [ $# -ge 1 ]; then
    AMUXD="$1"
elif command -v amuxd >/dev/null 2>&1; then
    AMUXD="$(command -v amuxd)"
elif [ -x "$HERE/../../zig-out/bin/amuxd" ]; then
    AMUXD="$(cd "$HERE/../.." && pwd)/zig-out/bin/amuxd"
else
    echo "error: cannot find amuxd. Pass its path, or run 'zig build' first." >&2
    exit 1
fi

if [ ! -x "$AMUXD" ]; then
    echo "error: $AMUXD is not executable" >&2
    exit 1
fi

echo "==> amuxd:     $AMUXD"
echo "==> unit dir:  $UNIT_DIR"

mkdir -p "$UNIT_DIR"
install -m 0644 "$HERE/amuxd.socket" "$UNIT_DIR/amuxd.socket"
sed "s|@AMUXD@|$AMUXD|" "$HERE/amuxd.service" > "$UNIT_DIR/amuxd.service"
chmod 0644 "$UNIT_DIR/amuxd.service"

systemctl --user daemon-reload
systemctl --user enable --now amuxd.socket

echo
echo "Socket activation is live. Nothing is running yet:"
systemctl --user --no-pager --lines=0 status amuxd.service 2>/dev/null | head -3 || true
echo
echo "The first call starts it:"
echo "    amux-cli ping"
echo
echo "Uninstall:"
echo "    systemctl --user disable --now amuxd.socket"
echo "    rm $UNIT_DIR/amuxd.{socket,service}"
echo "    systemctl --user daemon-reload"
