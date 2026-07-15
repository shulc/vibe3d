#!/usr/bin/env bash
#
# Build the self-contained Linux AppImage inside an OLD-GLIBC container so it
# runs broadly (glibc >= 2.31: Ubuntu 20.04+, Debian 11+, Fedora 32+, RHEL 9+),
# NOT just on the (Fedora 43 / glibc 2.42) dev host.
#
# It (1) builds/caches the Ubuntu-20.04 builder image from
# appimage-builder.Containerfile, then (2) runs the modeling build + AppImage
# pack inside it against the repo bind-mounted at /src. The finished
# `Vibe3D-x86_64.AppImage` lands in the repo root.
#
# Usage:
#   tools/release/build_linux_appimage_container.sh [--rebuild] [--verify]
#                                                   [--output PATH] [--help]
#
#   --rebuild     force a rebuild of the builder image (default: reuse if present)
#   --verify      pass --verify to the in-container bundler (Xvfb X11 + headless
#                 Wayland launch probe of the packed AppImage)
#   --output P    where to write the AppImage (default: repo-root/Vibe3D-x86_64.AppImage)
#
# Env overrides:
#   DOCKER   container engine (default: podman; docker also works)
#   IMAGE    builder image tag (default: vibe3d-appimage-builder:ubuntu20.04)
#
# set -euo pipefail; clear logging; exits non-zero on the first failure.

set -euo pipefail

DOCKER="${DOCKER:-podman}"
IMAGE="${IMAGE:-vibe3d-appimage-builder:ubuntu20.04}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTAINERFILE="$SCRIPT_DIR/appimage-builder.Containerfile"

REBUILD=false
VERIFY=false
OUTPUT_HOST="${REPO_ROOT}/Vibe3D-x86_64.AppImage"

log()  { echo "[appimage-container] $*"; }
die()  { echo "[appimage-container] ERROR: $*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
    case "$1" in
        --rebuild) REBUILD=true; shift ;;
        --verify)  VERIFY=true; shift ;;
        --output)  OUTPUT_HOST="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown arg: $1 (try --help)" ;;
    esac
done

command -v "$DOCKER" >/dev/null 2>&1 || die "container engine '$DOCKER' not found (set DOCKER=...)"
[[ -f "$CONTAINERFILE" ]] || die "missing $CONTAINERFILE"

# The AppImage is always written to /src/Vibe3D-x86_64.AppImage inside the
# container (repo root == /src). We move it to $OUTPUT_HOST afterwards if the
# caller asked for a different path.
INCONTAINER_OUT="/src/Vibe3D-x86_64.AppImage"

# --- 1. Build / cache the builder image -------------------------------------
if [[ "$REBUILD" == true ]] || ! "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1; then
    log "building builder image: $IMAGE (Ubuntu 20.04, glibc 2.31)"
    "$DOCKER" build -t "$IMAGE" -f "$CONTAINERFILE" "$SCRIPT_DIR"
else
    log "reusing cached builder image: $IMAGE (pass --rebuild to force)"
fi

# --- 2. Run the build + pack inside the container ---------------------------
# Persist dub's package + build cache across runs (gitignored, container-only —
# kept separate from the host's ~/.dub so the glibc-2.31 artifacts never mix
# with host-built ones).
DUB_CACHE="${REPO_ROOT}/tools/release/.appimage-build/container-dub"
mkdir -p "$DUB_CACHE"

VERIFY_ARG=""
[[ "$VERIFY" == true ]] && VERIFY_ARG="--verify"

# SELinux (Fedora host): :Z relabels the bind mounts for container access.
# Harmless on non-SELinux hosts.
log "running build inside container ($DOCKER)"
log "  build : dub build --config=modeling --build=release --d-version=ReleaseBuild --compiler=ldc2"
log "  pack  : bundle_linux_appimage.sh --no-build ${VERIFY_ARG}"
"$DOCKER" run --rm \
    -v "$REPO_ROOT":/src:Z \
    -v "$DUB_CACHE":/root/.dub:Z \
    -w /src \
    -e APPIMAGE_EXTRACT_AND_RUN=1 \
    -e HOME=/root \
    "$IMAGE" \
    bash -lc "
        set -euo pipefail

        # Resolve + fetch the dependency tree WITHOUT running preBuild steps, so
        # the nfde package is on disk but nativefiledialog-extended is not cloned
        # yet. nfde's own preBuildCommand does 'git clone --depth 1' WITHOUT
        # --recurse-submodules, which leaves its bundled wayland-protocols
        # submodule empty and its CMake fails on a missing xdg-foreign XML. On a
        # long-lived dev-host dub cache this is masked (the tree was seeded once);
        # a fresh container cache is not. Pre-seed a RECURSIVE clone so nfde's
        # preBuildCommand sees an existing .git and skips its shallow clone.
        dub describe --config=modeling --compiler=ldc2 >/dev/null
        wl_marker=3ps/wayland-protocols/unstable/xdg-foreign/xdg-foreign-unstable-v1.xml
        for nfde_dir in /root/.dub/packages/nfde/*/nfde; do
            [ -d \"\$nfde_dir\" ] || continue
            tgt=\"\$nfde_dir/nativefiledialog-extended\"
            # Re-seed whenever the required submodule file is absent — covers both
            # a missing clone AND a stale shallow clone from a prior failed run
            # (which left a .git but an empty wayland-protocols submodule).
            if [ ! -e \"\$tgt/\$wl_marker\" ]; then
                echo \"[appimage-container] pre-seeding nfde submodules -> \$tgt\"
                rm -rf \"\$tgt\"
                git clone --depth 1 --recurse-submodules --shallow-submodules \
                    https://github.com/btzy/nativefiledialog-extended.git \"\$tgt\"
            fi
        done

        dub build --config=modeling --build=release --d-version=ReleaseBuild --compiler=ldc2
        tools/release/bundle_linux_appimage.sh --no-build --output '$INCONTAINER_OUT' ${VERIFY_ARG}
    "

# --- 3. Report / relocate output --------------------------------------------
PRODUCED="${REPO_ROOT}/Vibe3D-x86_64.AppImage"
[[ -f "$PRODUCED" ]] || die "expected AppImage not produced at $PRODUCED"
if [[ "$OUTPUT_HOST" != "$PRODUCED" ]]; then
    mv -f "$PRODUCED" "$OUTPUT_HOST"
fi
log "DONE — AppImage at: $OUTPUT_HOST"
log "  size: $(du -h "$OUTPUT_HOST" | awk '{print $1}')"
