#!/usr/bin/env bash
#
# Linux self-contained AppImage bundler (modeling configuration).
#
# Produces a single-file `Vibe3D-x86_64.AppImage` that runs "download →
# chmod +x → run" on any Linux with a modern-enough glibc, WITHOUT the
# target machine having SDL2 or the GTK3 stack installed.
#
# Why the whole GTK3 loader stack (not just SDL2)?
#   `ldd ./vibe3d` shows the real runtime closure is the entire GTK3 loader
#   stack — libgtk-3/libgdk-3/libgdk_pixbuf/libcairo/libpango/libjson-glib/
#   libglycin + wayland — pulled in by the native file dialog (nfde), NOT by
#   SDL2. `dub.json`'s `libs-linux` only names the tip of that iceberg. So we
#   bundle SDL2 + the GTK3 loader modules via `linuxdeploy-plugin-gtk`, which
#   also emits the GDK_PIXBUF_MODULE_FILE / GTK_PATH / GIO_MODULE_DIR env
#   wrappers that a hand-rolled tarball would have to replicate by hand.
#
# What stays SYSTEM (never bundled): libGL/GLX/EGL + graphics drivers, glibc,
#   libstdc++, and the X11 core — linuxdeploy's standard excludelist enforces
#   this (bundling libGL/drivers breaks on other GPUs; glibc must match host).
#
# glibc floor: LDC links against the host glibc, so an AppImage built here is
#   floored at this host's glibc (Fedora 43 ≈ 2.42). It runs only on glibc >=
#   that. Broader-distro reach (old-glibc container build) is a later decision;
#   the floor is printed at the end and documented in tools/release/README.md.
#
# Usage:
#   ./tools/release/bundle_linux_appimage.sh [--no-build] [--output PATH]
#                                            [--verify] [--help]
#
#   --no-build   reuse the existing ./vibe3d instead of building
#   --output P   write the AppImage to P (default: repo-root/Vibe3D-x86_64.AppImage)
#   --verify     after building, launch the AppImage headless under Xvfb with
#                software GL and probe its HTTP server to prove self-containment
#
# Env overrides:
#   DC   compiler (default: first ldc2 >= 1.41 found; system ldc 1.40 is too old)
#   DUB  dub binary (default: dub on PATH)
#
# Idempotent; exits non-zero on the first failure (set -euo pipefail).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/tools/release/.appimage-build"
TOOLS_DIR="${BUILD_DIR}/tools"
APPDIR="${BUILD_DIR}/AppDir"
OUTPUT="${REPO_ROOT}/Vibe3D-x86_64.AppImage"
BUILD=true
VERIFY=false

# Pinned upstream tool sources (single-file AppImages + the gtk plugin shell
# script). Cached under $TOOLS_DIR so re-runs don't re-download.
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
GTK_PLUGIN_URL="https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"
APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
PATCHELF_URL="https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz"

log() { echo "[appimage] $*"; }
die() { echo "[appimage] ERROR: $*" >&2; exit 1; }

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
    case "$1" in
        --no-build) BUILD=false; shift ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        --verify)   VERIFY=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) die "unknown arg: $1 (try --help)" ;;
    esac
done

cd "$REPO_ROOT"
mkdir -p "$TOOLS_DIR"

# --- Compiler: LDC >= 1.41 (2.111+ stabilized `ref` locals; older ldc rejects
#     6 pre-existing files). Mirror build.yml's "Locate LDC" search order. -----
ldc_version() {
    "$1" --version 2>/dev/null \
        | sed -n 's/.*LDC[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
        | head -1
}
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
find_ldc() {
    local cand vers candidates=()
    command -v ldc2 >/dev/null 2>&1 && candidates+=("$(command -v ldc2)")
    local d
    for d in "$HOME"/dlang/ldc*/bin "$HOME"/.local/dlang/ldc*/bin \
             /opt/ldc*/bin /usr/lib/ldc*/bin /usr/local/ldc*/bin; do
        [ -x "$d/ldc2" ] && candidates+=("$d/ldc2")
    done
    for cand in "${candidates[@]}"; do
        vers="$(ldc_version "$cand")"
        [ -n "$vers" ] && ver_ge "$vers" "1.41.0" && { echo "$cand"; return 0; }
    done
    return 1
}

DUB_BIN="${DUB:-dub}"
command -v "$DUB_BIN" >/dev/null 2>&1 || die "dub not found (set DUB=...)"

if [[ "$BUILD" == true ]]; then
    DC="${DC:-}"
    if [[ -z "$DC" ]]; then
        DC="$(find_ldc)" || die "no LDC >= 1.41 found (system ldc 1.40 can't build vibe3d). Install LDC 1.42+ or set DC=..."
    fi
    log "compiler: $DC ($(ldc_version "$DC"))"
    log "$DUB_BIN build --config=modeling --build=release --d-version=ReleaseBuild --compiler=$DC"
    "$DUB_BIN" build --config=modeling --build=release --d-version=ReleaseBuild --compiler="$DC"
else
    log "--no-build: reusing existing ./vibe3d"
fi
[[ -x "$REPO_ROOT/vibe3d" ]] || die "$REPO_ROOT/vibe3d not found (build first, or drop --no-build)"

# --- Fetch the packaging tools (cached) -------------------------------------
fetch() {  # url dest
    local url="$1" dest="$2"
    if [[ -f "$dest" ]]; then log "cached: $(basename "$dest")"; return 0; fi
    log "fetching: $(basename "$dest")"
    curl -fSL --retry 3 --connect-timeout 30 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
}

LINUXDEPLOY="$TOOLS_DIR/linuxdeploy-x86_64.AppImage"
APPIMAGETOOL="$TOOLS_DIR/appimagetool-x86_64.AppImage"
GTK_PLUGIN="$TOOLS_DIR/linuxdeploy-plugin-gtk.sh"
fetch "$LINUXDEPLOY_URL"   "$LINUXDEPLOY"
fetch "$GTK_PLUGIN_URL"    "$GTK_PLUGIN"
fetch "$APPIMAGETOOL_URL"  "$APPIMAGETOOL"
chmod +x "$LINUXDEPLOY" "$APPIMAGETOOL" "$GTK_PLUGIN"

# patchelf: linuxdeploy requires it and Fedora 43 doesn't ship it. Fetch a
# static build into the cache and put it on PATH if the host has none.
PATCHELF_BIN="$TOOLS_DIR/patchelf/bin/patchelf"
if ! command -v patchelf >/dev/null 2>&1 && [[ ! -x "$PATCHELF_BIN" ]]; then
    fetch "$PATCHELF_URL" "$TOOLS_DIR/patchelf.tar.gz"
    mkdir -p "$TOOLS_DIR/patchelf"
    tar -xzf "$TOOLS_DIR/patchelf.tar.gz" -C "$TOOLS_DIR/patchelf"
fi
[[ -x "$PATCHELF_BIN" ]] && export PATH="$TOOLS_DIR/patchelf/bin:$PATH"

# Make the gtk plugin discoverable to linuxdeploy (`--plugin gtk` searches PATH
# for linuxdeploy-plugin-gtk.sh).
export PATH="$TOOLS_DIR:$PATH"

# Run the bundled tools FUSE-free (headless CI/containers often lack /dev/fuse).
export APPIMAGE_EXTRACT_AND_RUN=1

# linuxdeploy ships an old binutils `strip` that cannot parse the `.relr.dyn`
# section (ELF type 0x13) emitted by Fedora 43's toolchain — it aborts the run.
# Skip stripping (bundled libs stay a few MB larger; harmless for correctness).
export NO_STRIP=1

log "tool versions:"
log "  linuxdeploy : $("$LINUXDEPLOY" --list-plugins >/dev/null 2>&1; "$LINUXDEPLOY" --version 2>/dev/null | head -1 || echo '(continuous)')"
log "  appimagetool: $("$APPIMAGETOOL" --version 2>&1 | head -1 || echo '(continuous)')"
log "  patchelf    : $(patchelf --version 2>/dev/null || echo 'host')"

# --- Stage the AppDir --------------------------------------------------------
DESKTOP_SRC="$REPO_ROOT/assets/icon/vibe3d.desktop"
ICON_SRC="$REPO_ROOT/assets/icon/png/vibe3d_256.png"
SVG_SRC="$REPO_ROOT/assets/icon/vibe3d.svg"
[[ -f "$DESKTOP_SRC" ]] || die "missing $DESKTOP_SRC"
[[ -f "$ICON_SRC" ]]    || die "missing $ICON_SRC"

rm -rf "$APPDIR"
mkdir -p "$APPDIR"

log "running linuxdeploy (+gtk plugin) — bundling SDL2 + GTK3 loader stack"
DEPLOY_GTK_VERSION=3 ARCH=x86_64 \
    "$LINUXDEPLOY" --appdir "$APPDIR" \
        --executable "$REPO_ROOT/vibe3d" \
        --desktop-file "$DESKTOP_SRC" \
        --icon-file "$ICON_SRC" --icon-filename vibe3d \
        --plugin gtk

# Scalable icon alongside the rasterized one (launchers that prefer SVG).
if [[ -f "$SVG_SRC" ]]; then
    install -Dm644 "$SVG_SRC" \
        "$APPDIR/usr/share/icons/hicolor/scalable/apps/vibe3d.svg"
fi

# --- Work around patchelf 0.18 + RELR corruption ----------------------------
# Fedora 43 builds every shared lib with RELR relative relocations
# (-z pack-relative-relocs). linuxdeploy runs patchelf on each bundled lib to
# stamp an $ORIGIN rpath, but patchelf 0.18 mis-rewrites RELR: the lib's
# .init_array pointers relocate to garbage and its constructor SIGSEGVs at load
# time (crash in call_init, before main) — every bundled lib is poisoned, so
# the app dies with an empty log. Undo it: copy the PRISTINE system lib back
# over each patchelf'd one, then give the EXECUTABLE a *transitive* DT_RPATH so
# the now-rpath-less bundled libs still resolve their bundled siblings. DT_RPATH
# (unlike DT_RUNPATH) is honoured for the whole dependency chain, so no per-lib
# rpath is needed — hence no patchelf on the libs — and no LD_LIBRARY_PATH,
# which would leak into child processes (mkdir, xdg-open, the remesh worker …)
# and crash them against the host libc.
log "de-corrupting bundled libs (restore pristine over patchelf'd RELR libs)"
# Snapshot the ldconfig soname→path map ONCE (piping ldconfig into an early-exit
# awk per lib would SIGPIPE ldconfig and trip `set -o pipefail`).
LDCONFIG_MAP="$(ldconfig -p 2>/dev/null || true)"
n_restored=0; n_kept=0
while IFS= read -r f; do
    soname="$(patchelf --print-soname "$f" 2>/dev/null || true)"
    [[ -z "$soname" ]] && soname="$(basename "$f")"
    src="$(awk -v s="$soname" 'index($0, s" ")>0 {print $NF; exit}' <<<"$LDCONFIG_MAP" || true)"
    if [[ -n "$src" && -f "$src" ]] && cp -L "$src" "$f" 2>/dev/null; then
        n_restored=$((n_restored+1))
    else
        n_kept=$((n_kept+1))   # e.g. libonnxruntime (dub cache; no RELR, uncorrupted)
    fi
done < <(find "$APPDIR/usr/lib" -maxdepth 1 -type f -name '*.so*')
# gdk-pixbuf loader modules live outside ldconfig — restore from the system dir.
sysloaders="$(ls -d /usr/lib64/gdk-pixbuf-2.0/*/loaders /usr/lib/gdk-pixbuf-2.0/*/loaders 2>/dev/null | head -1 || true)"
if [[ -n "$sysloaders" && -d "$sysloaders" ]]; then
    while IFS= read -r f; do
        [[ -f "$sysloaders/$(basename "$f")" ]] && cp -L "$sysloaders/$(basename "$f")" "$f" 2>/dev/null \
            && n_restored=$((n_restored+1)) || true
    done < <(find "$APPDIR/usr/lib" -path '*/gdk-pixbuf-2.0/*/loaders/*.so' -type f)
fi
log "  restored $n_restored pristine libs (kept $n_kept non-system, e.g. onnxruntime)"

log "setting transitive DT_RPATH (\$ORIGIN/../lib) on the executable"
patchelf --remove-rpath "$APPDIR/usr/bin/vibe3d" 2>/dev/null || true
patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$APPDIR/usr/bin/vibe3d"

# Runtime data. vibe3d reads config/ RELATIVE TO THE CWD (config/tool_presets.yaml
# etc. — fatal if absent). The AppRun below chdirs into a writable working dir
# that symlinks these in. assets/ isn't read at runtime (fonts + icon are
# string-imported into the binary) but is shipped to mirror the zip layout.
log "staging config/ + assets/"
cp -r "$REPO_ROOT/config" "$APPDIR/config"
[[ -d "$REPO_ROOT/assets" ]] && cp -r "$REPO_ROOT/assets" "$APPDIR/assets"
[[ -f "$REPO_ROOT/LICENSE" ]]                 && cp "$REPO_ROOT/LICENSE"                 "$APPDIR/LICENSE"
[[ -f "$REPO_ROOT/THIRD_PARTY_LICENSES.md" ]] && cp "$REPO_ROOT/THIRD_PARTY_LICENSES.md" "$APPDIR/THIRD_PARTY_LICENSES.md"

# --- Custom AppRun -----------------------------------------------------------
# Replaces linuxdeploy's default AppRun. It still sources the gtk plugin's env
# hooks (apprun-hooks/*.sh set GDK_PIXBUF_MODULE_FILE / GTK_PATH / GIO_MODULE_DIR)
# but ADDS a chdir into a writable working directory that exposes the bundled
# config/ (+ assets/). vibe3d resolves config/ against the CWD and writes
# events.log/prefs there; the AppImage mount is read-only, so a plain chdir into
# $APPDIR would crash on the first config-read / log-write. The symlinks are
# re-pointed every launch because a FUSE/extract mount path is ephemeral.
log "writing custom AppRun (writable-cwd + gtk hooks)"
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
# vibe3d AppImage entry point.
HERE="$(dirname "$(readlink -f "${0}")")"
export APPDIR="${APPDIR:-$HERE}"

# vibe3d loads config/ (fatal if missing) relative to the CWD and writes
# events.log / prefs to the CWD. The AppImage mount is READ-ONLY, so run from a
# writable working dir that exposes the bundled config/ + assets/ via symlinks.
# The symlinks are re-pointed every launch because a FUSE / extract-and-run
# mount path is ephemeral. Done FIRST — before the gtk hooks — so these coreutils
# helpers run with a clean environment.
WORKDIR="${VIBE3D_WORKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/vibe3d/cwd}"
if ! mkdir -p "$WORKDIR" 2>/dev/null; then
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe3d.XXXXXX")"
fi
ln -sfn "$APPDIR/config" "$WORKDIR/config"
[ -d "$APPDIR/assets" ] && ln -sfn "$APPDIR/assets" "$WORKDIR/assets"

# GTK / gdk-pixbuf / GIO env from linuxdeploy-plugin-gtk (sets GTK_PATH,
# GDK_PIXBUF_MODULE_FILE, GIO_MODULE_DIR — absolute paths under $APPDIR).
# Sourced, not exec'd, so the exports persist into the final exec.
if [ -d "$APPDIR/apprun-hooks" ]; then
    for hook in "$APPDIR"/apprun-hooks/*.sh; do
        [ -r "$hook" ] && . "$hook"
    done
fi

# NB: we deliberately do NOT export LD_LIBRARY_PATH. The binary's RUNPATH is
# $ORIGIN/../lib, so the bundled SDL2 + GTK3 stack resolve without it — and
# leaking the bundled lib dir onto LD_LIBRARY_PATH would SIGSEGV any system
# helper (mkdir, xdg-open, …) that loaded the bundled libselinux/libpcre2
# against the host libc.
cd "$WORKDIR" || exit 1
exec "$APPDIR/usr/bin/vibe3d" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# --- Pack --------------------------------------------------------------------
log "packing AppImage → $OUTPUT"
rm -f "$OUTPUT"
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUTPUT"
chmod +x "$OUTPUT"

GLIBC="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
GLIBC="${GLIBC:-?}"
SZ="$(du -h "$OUTPUT" | awk '{print $1}')"
echo
log "DONE"
log "  output     : $OUTPUT"
log "  size       : $SZ"
log "  glibc floor: requires glibc >= $GLIBC (built on this host)."
log "               Older distros (Ubuntu 22.04=2.35, 20.04=2.31) need an"
log "               old-glibc container build — see tools/release/README.md."

# --- Optional launch verification -------------------------------------------
if [[ "$VERIFY" == true ]]; then
    command -v xvfb-run >/dev/null 2>&1 || die "--verify needs xvfb-run"
    PORT="${VERIFY_PORT:-8760}"
    VLOG="$BUILD_DIR/verify.log"
    log "launch-verify: Xvfb + software GL, HTTP probe on 127.0.0.1:$PORT"
    rm -f "$VLOG"
    setsid env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 LIBGL_ALWAYS_SOFTWARE=1 \
        APPIMAGE_EXTRACT_AND_RUN=1 VIBE3D_WORKDIR="$BUILD_DIR/verify-cwd" \
        xvfb-run -a "$OUTPUT" --test --http-port "$PORT" >"$VLOG" 2>&1 &
    PGID=$!
    ok=false
    for _ in $(seq 1 40); do
        code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' \
            "http://127.0.0.1:$PORT/api/selection" 2>/dev/null || true)"
        if [[ -n "$code" && "$code" != "000" ]]; then ok=true; break; fi
        sleep 0.5
    done
    kill -TERM "-$PGID" 2>/dev/null || true
    sleep 1
    kill -KILL "-$PGID" 2>/dev/null || true
    if [[ "$ok" == true ]]; then
        log "VERIFY OK — AppImage started self-contained; HTTP responded (code $code)"
    else
        echo "[appimage] VERIFY FAILED — tail of $VLOG:" >&2
        tail -30 "$VLOG" >&2 || true
        exit 1
    fi
fi
