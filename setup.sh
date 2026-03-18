#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHOSTTY_DIR="$PROJECT_DIR/ghostty"
GHOSTTY_LIB_DIR="$PROJECT_DIR/ghostty-lib"

cd "$PROJECT_DIR"

echo "==> Initializing submodules..."
git submodule update --init ghostty

echo "==> Checking for zig..."
if ! command -v zig &> /dev/null; then
    echo "Error: zig is not installed."
    echo "Install via your package manager, e.g.: sudo apt install zig"
    exit 1
fi

echo "==> Checking for GTK4 development files..."
if ! pkg-config --exists gtk4; then
    echo "Error: GTK4 development files not found."
    echo "Install via: sudo apt install libgtk-4-dev"
    exit 1
fi

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
CACHE_ROOT="${AMUX_GHOSTTYLIB_CACHE_DIR:-$HOME/.cache/amux/ghosttylib}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_SHA"

# zig build --prefix puts files in lib/ and include/ subdirectories
CACHE_LIB="$CACHE_DIR/lib/libghostty.so"
CACHE_HEADER="$CACHE_DIR/ghostty.h"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty submodule commit: $GHOSTTY_SHA"

if [ -f "$CACHE_LIB" ] && [ -f "$CACHE_HEADER" ]; then
    echo "==> Reusing cached libghostty.so"
else
    echo "==> Building libghostty.so for Linux (this may take a few minutes)..."
    (
        cd "$GHOSTTY_DIR"
        zig build \
            -Dapp-runtime=none \
            -Doptimize=ReleaseFast \
            --prefix "$CACHE_DIR"
    )

    # Copy our modified ghostty.h (with GHOSTTY_PLATFORM_LINUX) over
    # the upstream header. The build installs upstream's header to
    # include/ghostty.h but we need our extended version.
    cp "$PROJECT_DIR/ghostty.h" "$CACHE_HEADER"

    echo "==> Cached libghostty at $CACHE_DIR"
fi

# Symlink into the build directory
mkdir -p "$GHOSTTY_LIB_DIR"
ln -sfn "$CACHE_LIB" "$GHOSTTY_LIB_DIR/libghostty.so"
ln -sfn "$CACHE_HEADER" "$GHOSTTY_LIB_DIR/ghostty.h"

echo "==> Setup complete!"
echo ""
echo "You can now build amux:"
echo "  zig build"
