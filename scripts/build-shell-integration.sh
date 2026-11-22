#!/bin/sh
# Build Crosswire's shell-integration dylibs (Dock icons, Dock names, own
# Space for games) that Wine.runProcess injects into engine processes.
#
# Usage: scripts/build-shell-integration.sh <output-dir>
# Produces <output-dir>/CrosswireShell.dylib and CrosswireShellUI.dylib.
# The engine runs x86_64 under Rosetta today; arm64 is included so a native
# engine works unchanged.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ShellIntegration"
OUT="${1:?usage: $0 <output-dir>}"
mkdir -p "$OUT"

COMMON="-arch x86_64 -arch arm64 -mmacosx-version-min=11.0 -dynamiclib -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter"

clang $COMMON -framework Foundation \
    -install_name @loader_path/CrosswireShell.dylib \
    -o "$OUT/CrosswireShell.dylib" "$SRC/CrosswireShell.m"

clang $COMMON -framework AppKit -framework Foundation \
    -install_name @loader_path/CrosswireShellUI.dylib \
    -o "$OUT/CrosswireShellUI.dylib" "$SRC/CrosswireShellUI.m"

codesign --force --sign - "$OUT/CrosswireShell.dylib" "$OUT/CrosswireShellUI.dylib"
echo "Built shell integration into $OUT"
