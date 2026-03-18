#!/usr/bin/env bash
# Install amux and amux-cli to /usr/local/bin
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/zig-out/bin"

if [[ ! -f "$BIN_DIR/amux" || ! -f "$BIN_DIR/amux-cli" ]]; then
    echo "Binaries not found. Building first..."
    cd "$SCRIPT_DIR" && zig build
fi

sudo cp "$BIN_DIR/amux" "$BIN_DIR/amux-cli" /usr/local/bin/
echo "Installed amux and amux-cli to /usr/local/bin/"
