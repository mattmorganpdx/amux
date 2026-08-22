#!/usr/bin/env bash
# Install amux, amux-cli and amuxd onto PATH.
#
# Symlinks by default rather than copying. A copy goes stale the moment you
# rebuild, and nothing tells you: you get an old binary that still launches, so
# the failure looks like a bug in the tool rather than a stale install. That
# happened -- a five-month-old `amux` opened its own local session and appeared
# to have lost the daemon's. Use --copy for a fixed install that does not track
# this checkout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/zig-out/bin"
BINARIES=(amux amux-cli amuxd)

MODE=symlink
PREFIX=""

while [ $# -gt 0 ]; do
    case "$1" in
        --copy)   MODE=copy; shift ;;
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        -h|--help)
            echo "usage: ./install.sh [--copy] [--prefix DIR]"
            echo "  --copy     install copies instead of symlinks into this checkout"
            echo "  --prefix   install here instead of the default"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

for b in "${BINARIES[@]}"; do
    if [ ! -x "$BIN_DIR/$b" ]; then
        echo "==> $b not built yet; running zig build"
        (cd "$HERE" && zig build)
        break
    fi
done

# Prefer a directory that needs no sudo, as long as PATH actually searches it.
on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

if [ -n "$PREFIX" ]; then
    DEST="$PREFIX"
elif on_path "$HOME/.local/bin"; then
    DEST="$HOME/.local/bin"
else
    DEST="/usr/local/bin"
fi

SUDO=""
mkdir -p "$DEST" 2>/dev/null || true
[ -w "$DEST" ] || SUDO=sudo

echo "==> installing to $DEST ($MODE)"
for b in "${BINARIES[@]}"; do
    if [ "$MODE" = symlink ]; then
        $SUDO ln -sfn "$BIN_DIR/$b" "$DEST/$b"
    else
        $SUDO install -m 0755 "$BIN_DIR/$b" "$DEST/$b"
    fi
    echo "    $b"
done

# An older copy earlier or later on PATH is the failure this script exists to
# prevent, so say so plainly rather than leaving it to be discovered.
echo
shadowed=0
for b in "${BINARIES[@]}"; do
    while read -r other; do
        [ -z "$other" ] && continue
        [ "$(readlink -f "$other")" = "$(readlink -f "$DEST/$b")" ] && continue
        echo "!!  another $b on PATH: $other"
        shadowed=1
    done < <(type -a -p "$b" 2>/dev/null | grep -vFx "$DEST/$b" || true)
done
if [ "$shadowed" = 1 ]; then
    echo "!!  PATH order decides which one runs. Remove the others, or reinstall"
    echo "!!  over them with:  ./install.sh --prefix /usr/local/bin"
    echo
fi

echo "Installed. Next, if you want the daemon always available:"
echo "    ./dist/systemd/install.sh     # socket activation; first call starts amuxd"
echo
echo "Then:"
echo "    amux             # the GUI, which attaches to the daemon if one is reachable"
echo "    amux-cli ping    # starts the daemon on demand under socket activation"
