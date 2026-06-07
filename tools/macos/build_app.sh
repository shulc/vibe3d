#!/usr/bin/env bash
#
# Build a local macOS .app bundle for the modeling configuration.
#
# Usage:
#   ./tools/macos/build_app.sh
#   ./tools/macos/build_app.sh --no-build
#   ./tools/macos/build_app.sh --output /tmp/Vibe3D.app

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_PATH="${REPO_ROOT}/vibe3d.app"
BUILD=true
if [[ -n "${DUB:-}" ]]; then
    DUB_BIN="$DUB"
elif [[ -x "${REPO_ROOT}/../dub/bin/dub" ]]; then
    DUB_BIN="${REPO_ROOT}/../dub/bin/dub"
else
    DUB_BIN="dub"
fi

while (($#)); do
    case "$1" in
        --no-build) BUILD=false; shift ;;
        --output)   APP_PATH="$2"; shift 2 ;;
        --dub)      DUB_BIN="$2"; shift 2 ;;
        *) echo "[app] unknown arg: $1" >&2; exit 1 ;;
    esac
done

cd "$REPO_ROOT"

if [[ "$BUILD" == true ]]; then
    "$DUB_BIN" build --config=modeling
fi
if [[ ! -x ./vibe3d ]]; then
    echo "[app] ./vibe3d not found; build first or omit --no-build" >&2
    exit 1
fi
if [[ ! -f assets/icon/vibe3d.icns ]]; then
    echo "[app] assets/icon/vibe3d.icns not found" >&2
    exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp -p ./vibe3d "$APP_PATH/Contents/MacOS/vibe3d"
cp -p assets/icon/vibe3d.icns "$APP_PATH/Contents/Resources/vibe3d.icns"
cp -R config "$APP_PATH/Contents/Resources/config"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Vibe3D</string>
    <key>CFBundleExecutable</key>
    <string>vibe3d</string>
    <key>CFBundleIconFile</key>
    <string>vibe3d</string>
    <key>CFBundleIdentifier</key>
    <string>com.shulc.vibe3d</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Vibe3D</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "[app] built $APP_PATH"
