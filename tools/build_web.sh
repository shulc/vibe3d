#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
emsdk_root=${EMSDK:-"$HOME/emsdk"}
ldc_root=${VIBE3D_LDC_ROOT:-"$HOME/.local/dlang/ldc2-1.43.0-linux-x86_64"}
ldc=${VIBE3D_LDC:-"$ldc_root/bin/ldc2"}
runtime_builder="$ldc_root/bin/ldc-build-runtime"
runtime_root="$repo_root/.build/web-runtime"
runtime_stamp="$runtime_root/.toolchain-fingerprint"
artifact_root="$repo_root/.build/web-artifacts"
link_root="$repo_root/.build/web-link"
web_dub_home="$repo_root/.build/web-dub-home"
shared_dub_packages="$HOME/.dub/packages"

archive_digest() {
    local root=$1
    if [[ ! -d $root ]]; then
        printf 'absent\n'
        return
    fi
    find "$root" -type f \( -name '*.a' -o -name '*.so' \) -print0 \
        | sort -z \
        | xargs -0 -r sha256sum \
        | sha256sum \
        | cut -d' ' -f1
}

# A wasm dependency build may run package hooks and must never repair or
# replace native archives in the user's shared Dub cache. Keep the complete
# web package/cache state under the task build root and enforce the boundary
# with a before/after digest of the shared native archives.
shared_archives_before=$(archive_digest "$shared_dub_packages")
export DUB_HOME="$web_dub_home"

for required in "$emsdk_root/emsdk_env.sh" "$ldc" "$runtime_builder"; do
    if [[ ! -e "$required" ]]; then
        echo "missing web toolchain component: $required" >&2
        exit 2
    fi
done

# shellcheck disable=SC1090
source "$emsdk_root/emsdk_env.sh" >/dev/null
# emsdk exposes a directory named cmake before the executable.
export PATH="/usr/bin:$PATH"

for tool in cmake ninja emcc em++; do
    if ! command -v "$tool" >/dev/null; then
        echo "required web build tool not found: $tool" >&2
        exit 2
    fi
done

fingerprint=$(python3 "$repo_root/tools/web_runtime_fingerprint.py" \
    "$ldc" "$runtime_builder" \
    "$emsdk_root/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake" \
    "$runtime_root")
old_fingerprint=$(cat "$runtime_stamp" 2>/dev/null || true)

if [[ $fingerprint != "$old_fingerprint" ||
      ! -f "$runtime_root/lib/libphobos2-ldc.a" ||
      ! -f "$runtime_root/lib/libdruntime-ldc.a" ]]; then
    cmake -E remove_directory "$runtime_root"
    "$runtime_builder" --ninja -j "${VIBE3D_WEB_JOBS:-8}" \
        --buildDir="$runtime_root" \
        --dFlags="-mtriple=wasm32-unknown-emscripten" \
        --targetSystem="Emscripten;UNIX" \
        "CMAKE_TOOLCHAIN_FILE=$emsdk_root/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake"
    # The builder downloads the exact LDC source archive and configures the
    # runtime tree. Recompute now so the stamp covers every druntime/Phobos
    # source and generated CMake input actually consumed by this build.
    fingerprint=$(python3 "$repo_root/tools/web_runtime_fingerprint.py" \
        "$ldc" "$runtime_builder" \
        "$emsdk_root/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake" \
        "$runtime_root")
    printf '%s\n' "$fingerprint" >"$runtime_stamp"
fi

for archive in libphobos2-ldc.a libdruntime-ldc.a; do
    if [[ ! -s "$runtime_root/lib/$archive" ]]; then
        echo "runtime builder did not produce $archive" >&2
        exit 3
    fi
done

"$repo_root/tools/build_web_native_deps.sh"

cd "$repo_root"
cmake -E make_directory "$artifact_root" "$link_root"
export VIBE3D_WEB_ARTIFACT_ROOT="$artifact_root"
# Dub has no root-package-only force switch: --force also rebuilds dependency
# hooks. Advance one real root input so only the final web target is stale.
cmake -E touch "$repo_root/source/app.d"
TMPDIR=/var/tmp dub build --config=web \
    --arch=wasm32-unknown-emscripten --compiler="$ldc" --dest="$link_root"

# An immediate repeat may legitimately be up to date and skip the linker.
# Keep the canonical browser set from the last successful private-target link
# instead of deleting it up front or forcing every dependency and package hook
# to rebuild. Copy any persistent target-side files that Dub does retain.
for artifact in vibe3d.js vibe3d.wasm vibe3d.data; do
    if [[ -s "$link_root/$artifact" ]]; then
        cmake -E copy "$link_root/$artifact" "$artifact_root/$artifact"
    fi
done

if [[ ! -s "$artifact_root/vibe3d.js" || ! -s "$artifact_root/vibe3d.wasm" ]]; then
    echo "web build did not produce vibe3d.js and vibe3d.wasm" >&2
    exit 3
fi

printf 'WEB-ARTIFACT js=%s wasm=%s\n' \
    "$(stat -c %s "$artifact_root/vibe3d.js")" \
    "$(stat -c %s "$artifact_root/vibe3d.wasm")"
python3 "$repo_root/tools/check_wasm_imports.py" "$artifact_root/vibe3d.wasm"

# WebAssembly is statically linked and must not acquire an ELF-style dynamic
# search path from the build-local Dub cache. llvm-readobj prints only the
# file header for this healthy wasm; keep an explicit guard for either tag.
dynamic_table=$("$emsdk_root/upstream/bin/llvm-readobj" --dynamic-table \
    "$artifact_root/vibe3d.wasm")
if grep -Eq '(^|[^A-Z])(RUNPATH|RPATH)([^A-Z]|$)' <<<"$dynamic_table"; then
    echo "web artifact contains a dynamic runtime search path" >&2
    exit 4
fi
printf 'WEB-DYNAMIC-LINKS rpath=0 runpath=0\n'

shared_archives_after=$(archive_digest "$shared_dub_packages")
if [[ $shared_archives_after != "$shared_archives_before" ]]; then
    echo "web build changed native archives in $shared_dub_packages" >&2
    exit 4
fi
printf 'WEB-CACHE-ISOLATION shared-native-archives=%s unchanged=1\n' \
    "$shared_archives_after"
