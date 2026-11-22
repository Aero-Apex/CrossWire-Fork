#!/bin/sh
# Assemble a runnable Crosswire.app from a local Xcode build.
#
# The Xcode product lacks the engine (the release pipeline bundles it with
# bundle-engine-into-app.sh), so it is cloned from an existing Crosswire.app.
# Also adds the shell integration dylibs and the Direct3D 10/11 graphics pack.
#
# Usage: scripts/assemble-local-app.sh <built Crosswire.app> <engine source Crosswire.app> \
#                                      <graphics pack dir> <output Crosswire.app>
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="${1:?built app}"
ENGINE_SOURCE="${2:?app to take Engine from}"
GRAPHICS_PACK="${3:?graphics pack dir}"
OUT="${4:?output app}"

[ -d "$ENGINE_SOURCE/Contents/Resources/Engine" ] || { echo "No Engine in $ENGINE_SOURCE" >&2; exit 1; }
[ -f "$GRAPHICS_PACK/MoltenVK/MoltenVK_icd.json" ] || { echo "Bad graphics pack: $GRAPHICS_PACK" >&2; exit 1; }

rm -rf "$OUT"
ditto "$BUILT" "$OUT"
RES="$OUT/Contents/Resources"

# APFS clone: instant and takes no extra space.
cp -Rc "$ENGINE_SOURCE/Contents/Resources/Engine" "$RES/Engine"
# Stray DXVK state caches written next to the engine binaries by old launches.
find "$RES/Engine/bin" -maxdepth 1 -name '*.dxvk-cache' -delete

"$ROOT/scripts/build-shell-integration.sh" "$RES/ShellIntegration"
ditto "$GRAPHICS_PACK" "$RES/GraphicsPack"

# Ad-hoc signature like the shipped app; keep the build's entitlements minus
# get-task-allow (a debug-only entitlement Xcode adds to local builds).
ENT="$(mktemp -t crosswire-ent).plist"
codesign -d --entitlements - --xml "$BUILT" > "$ENT" 2>/dev/null || true
if [ -s "$ENT" ]; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$ENT" 2>/dev/null || true
    codesign --force --sign - --entitlements "$ENT" "$OUT"
else
    codesign --force --sign - "$OUT"
fi
rm -f "$ENT"
codesign --verify --strict "$OUT"
echo "Assembled $OUT"
