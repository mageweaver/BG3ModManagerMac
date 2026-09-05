#!/bin/bash
#
# Builds "BG3 Mod Manager.app" from the Swift package and registers the nxm:// URL scheme,
# so the Nexus "Mod Manager Download" button hands off to this app — no Xcode project needed,
# just the Xcode command-line tools.
#
# Usage:  ./build_app.sh              (release build → ./BG3 Mod Manager.app)
#         ./build_app.sh --debug      (faster debug build)
#         ./build_app.sh --universal  (Apple Silicon + Intel — what the GitHub releases ship)
#
set -euo pipefail

APP_NAME="BG3 Mod Manager"
BIN_NAME="BG3ModManagerMac"
CONFIG="release"
ARCHS=()
for arg in "$@"; do
  case "$arg" in
    --debug)     CONFIG="debug" ;;
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")"

# ${ARCHS[@]+…} keeps an empty array from tripping `set -u` on macOS's bash 3.2.
echo "▶ Compiling ($CONFIG${ARCHS[@]+, universal})…"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

if [ ! -f "$BIN_DIR/$BIN_NAME" ]; then
  echo "✗ Build did not produce $BIN_DIR/$BIN_NAME" >&2
  exit 1
fi

APP_DIR="$APP_NAME.app"
echo "▶ Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"

# Make sure the bundle points at the executable we just copied.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BIN_NAME" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true

# Ad-hoc codesign so Gatekeeper/Hardened Runtime are happy enough for local use.
if command -v codesign >/dev/null 2>&1; then
  echo "▶ Ad-hoc signing…"
  codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "  (codesign skipped)"
fi

# Register with LaunchServices so macOS routes nxm:// links here.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  echo "▶ Registering nxm:// handler…"
  "$LSREGISTER" -f "$PWD/$APP_DIR" || true
fi

echo "✓ Built: $PWD/$APP_DIR"
echo "  Double-click it, or run: open \"$APP_DIR\""
echo "  Nexus 'Mod Manager Download' (nxm://) links will now offer this app."
