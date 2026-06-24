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
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"

cp -p ./vibe3d "$APP_PATH/Contents/MacOS/vibe3d"
cp -p assets/icon/vibe3d.icns "$APP_PATH/Contents/Resources/vibe3d.icns"
cp -R config "$APP_PATH/Contents/Resources/config"

# Bundle SDL2 so the .app runs on a clean macOS without Homebrew. It is the
# only non-system runtime dependency — every other dylib vibe3d links or
# dlopens (OpenGL, AppKit, libc++, libobjc, CoreFoundation, Foundation,
# libSystem) ships with macOS 11+. SDL2 in turn pulls in only system
# frameworks, so the single dylib is self-contained. The app loads it from
# Contents/Frameworks by explicit path (see bundledSDL2Path() in app.d).
SDL2_DYLIB_NAME="libSDL2-2.0.0.dylib"
find_sdl2() {
    if [[ -n "${SDL2_DYLIB:-}" && -f "${SDL2_DYLIB}" ]]; then echo "${SDL2_DYLIB}"; return 0; fi
    if command -v brew >/dev/null 2>&1; then
        local prefix; prefix="$(brew --prefix sdl2 2>/dev/null || true)"
        if [[ -n "$prefix" && -f "$prefix/lib/${SDL2_DYLIB_NAME}" ]]; then
            echo "$prefix/lib/${SDL2_DYLIB_NAME}"; return 0
        fi
    fi
    local d
    for d in /opt/homebrew/opt/sdl2/lib /opt/homebrew/lib \
             /usr/local/opt/sdl2/lib /usr/local/lib; do
        if [[ -f "$d/${SDL2_DYLIB_NAME}" ]]; then echo "$d/${SDL2_DYLIB_NAME}"; return 0; fi
    done
    return 1
}
SDL2_SRC="$(find_sdl2 || true)"
if [[ -z "${SDL2_SRC}" ]]; then
    echo "[app] ${SDL2_DYLIB_NAME} not found (install via 'brew install sdl2' or set SDL2_DYLIB)" >&2
    exit 1
fi
cp -L "${SDL2_SRC}" "$APP_PATH/Contents/Frameworks/${SDL2_DYLIB_NAME}"
chmod u+w "$APP_PATH/Contents/Frameworks/${SDL2_DYLIB_NAME}"   # Homebrew copy is r--r--r--
# Drop the absolute Homebrew install_name so the bundled copy is self-describing
# (the app dlopens it by path, but a stray absolute reference is cleaner).
install_name_tool -id "@rpath/${SDL2_DYLIB_NAME}" \
    "$APP_PATH/Contents/Frameworks/${SDL2_DYLIB_NAME}" 2>/dev/null || true
echo "[app] bundled SDL2 from ${SDL2_SRC}"

# Bundle ONNX Runtime (AI candidate ranker backend; hard dependency). The
# onnxrt shim links it with an @executable_path/../Frameworks rpath, so the
# .dylib lives next to SDL2 in Contents/Frameworks.
ONNX_PKG_PATH="$("$DUB_BIN" describe --config=modeling 2>/dev/null | sed -n '/^{/,$p' \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(p['path'] for p in d['packages'] if p['name']=='d-onnxruntime'))")"
ONNX_LIB_BASE="${ONNX_PKG_PATH%/}/build/onnxruntime/sdk/lib"
shopt -s nullglob
onnx_libs=( "$ONNX_LIB_BASE"/libonnxruntime*.dylib )
shopt -u nullglob
if ((${#onnx_libs[@]} == 0)); then
    echo "[app] no libonnxruntime under $ONNX_LIB_BASE — is d-onnxruntime built?" >&2
    exit 1
fi
for f in "${onnx_libs[@]}"; do
    cp -P "$f" "$APP_PATH/Contents/Frameworks/$(basename "$f")"
done
chmod -R u+w "$APP_PATH/Contents/Frameworks"
echo "[app] bundled ONNX Runtime from ${ONNX_LIB_BASE}"

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

codesign --force --deep --sign - "$APP_PATH"

echo "[app] built $APP_PATH"
