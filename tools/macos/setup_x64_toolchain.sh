#!/usr/bin/env bash
# Provision the Intel build tools on an Apple Silicon runner without touching
# its arm64 Homebrew installation. Run once on the runner host.
set -euo pipefail

root="${VIBE3D_MACOS_X64_ROOT:-$HOME/opt/vibe3d-macos-x64}"
mkdir -p "$root/downloads" "$root/bin"

download() {
    local name="$1" url="$2" sha="$3" path="$root/downloads/$1"
    if [[ ! -f "$path" ]] || ! echo "$sha  $path" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 "$url" -o "$path.tmp"
        mv "$path.tmp" "$path"
    fi
    echo "$sha  $path" | shasum -a 256 -c - >/dev/null
}

if ! /usr/bin/arch -x86_64 /usr/bin/true; then
    echo "Rosetta 2 is required: softwareupdate --install-rosetta --agree-to-license" >&2
    exit 1
fi

ldc_archive=ldc2-1.42.0-osx-x86_64.tar.xz
download "$ldc_archive" \
    "https://github.com/ldc-developers/ldc/releases/download/v1.42.0/$ldc_archive" \
    3d3d4283c2f0856f65aca4af3c1e14d25f12619808893ca755ea6f088508503e
if [[ ! -x "$root/ldc/bin/ldc2" ]]; then
    mkdir -p "$root/ldc"
    tar -xJf "$root/downloads/$ldc_archive" -C "$root/ldc" --strip-components=1
fi

cmake_archive=cmake-4.3.3-macos-universal.tar.gz
download "$cmake_archive" \
    "https://github.com/Kitware/CMake/releases/download/v4.3.3/$cmake_archive" \
    5221a13450c7a0219a2a0d1b6c9085eb06489721fafd8488ccebc1584175d2fb
if [[ ! -x "$root/cmake/CMake.app/Contents/bin/cmake" ]]; then
    mkdir -p "$root/cmake"
    tar -xzf "$root/downloads/$cmake_archive" -C "$root/cmake" --strip-components=1
fi

# CMake must itself run as x86_64: d-onnxruntime selects its prebuilt SDK using
# CMAKE_SYSTEM_PROCESSOR. Invoke this wrapper even when dub is an arm64 process.
cat > "$root/bin/cmake" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/arch -x86_64 "$root/cmake/CMake.app/Contents/bin/cmake" "$@"
WRAPPER
chmod +x "$root/bin/cmake"

sdl_archive=SDL2-2.32.10.tar.gz
download "$sdl_archive" \
    "https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/$sdl_archive" \
    5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
if [[ ! -f "$root/sdl2/lib/libSDL2-2.0.0.dylib" ]] || \
   ! vtool -show-build "$root/sdl2/lib/libSDL2-2.0.0.dylib" | grep -q 'minos 11.0'; then
    mkdir -p "$root/src"
    tar -xzf "$root/downloads/$sdl_archive" -C "$root/src"
    PATH="$root/bin:/opt/homebrew/bin:$PATH" \
        "$root/bin/cmake" -S "$root/src/SDL2-2.32.10" -B "$root/sdl2-build" \
        -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
        -DCMAKE_INSTALL_PREFIX="$root/sdl2" \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF
    PATH="$root/bin:/opt/homebrew/bin:$PATH" "$root/bin/cmake" --build "$root/sdl2-build" -j 4
    PATH="$root/bin:/opt/homebrew/bin:$PATH" "$root/bin/cmake" --install "$root/sdl2-build"
fi

for binary in "$root/ldc/bin/ldc2" "$root/cmake/CMake.app/Contents/bin/cmake" \
              "$root/sdl2/lib/libSDL2-2.0.0.dylib"; do
    lipo -archs "$binary" | grep -qw x86_64 || {
        echo "Missing x86_64 slice: $binary" >&2; exit 1;
    }
done
# D-ImGui also adds /opt/homebrew/lib to the link search path. Put the
# matching static D runtime in our earlier SDL2_DIR/lib search path so the
# arm64 Homebrew archives can never satisfy LDC's -lphobos/-ldruntime flags.
for library in "$root/ldc/lib"/libdruntime-ldc*.a \
               "$root/ldc/lib"/libphobos2-ldc*.a; do
    ln -sfn "../../ldc/lib/$(basename "$library")" \
        "$root/sdl2/lib/$(basename "$library")"
done
mkdir -p "$root/dub"
echo "x64 toolchain ready at $root"
