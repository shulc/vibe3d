# Release packaging

Self-contained zip distributions of vibe3d with the Cycles + RPR
runtime libs bundled next to the executable.

## Layout

```
vibe3d-<platform>-render.zip
  vibe3d(.exe)              — the executable
  SDL2.dll                  — Windows only
  config/                   — tool presets etc.
  rpr/
    libNorthstar64.{so,dylib} / Northstar64.dll
    libRadeonProRender64.{so,dylib} / RadeonProRender64.dll
    libTahoe64.* / libRprLoadStore64.* / libProRenderGLTF.*
    hipbin/                 — precompiled HIP kernels (AMD GPU)
  lib/
    Blender runtime libs:
      libOpenImageIO*, libOpenColorIO*, libembree4*, libOpenImageDenoise*
      libOpenEXR*, libOpenEXRCore*, libIex*, libIlmThread*, libImath*
      libosdCPU*, libsycl*, libtbb*  (+ libur_loader*, libur_adapter_*)
```

The binary's RUNPATH (Linux) / rpath (macOS) has `$ORIGIN/lib`,
`$ORIGIN/rpr` (and the macOS `@executable_path/` equivalents)
prepended so the runtime loader finds the libs from the staged dir
without any env override. `ensureRuntimeLibPath()` in
`source/app.d` belt-and-suspenders prepends those dirs to
`LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` / `PATH` at startup too.

## Per-platform scripts

```bash
./tools/release/bundle_linux.sh   [--no-build] [--output PATH]
./tools/release/bundle_macos.sh   [--no-build] [--output PATH]
./tools/release/bundle_windows.ps1 [-NoBuild]  [-Output PATH]
```

Each script:

1. `dub build --config=with-render --build=release` (skip with
   `--no-build` if `./vibe3d` is already current).
2. Reads `dub describe` to find the resolved `d-cycles` and
   `bindbc-rpr` package directories.
3. Copies the platform-specific runtime libs out of those dirs into
   the staging area.
4. Iterates `ldd` / `otool -L` to close transitive dep gaps (Linux
   only; macOS deps are pinned by the explicit-list copy + an
   `otool -L` verification step).
5. Zips up the staged tree.

A relocate smoke test sits inside `bundle_linux.sh` — the staged
binary is `ldd`-checked with `LD_LIBRARY_PATH=$STAGE/lib:$STAGE/rpr`
and any "not found" entry fails the build. Once that passes, the
zip extracted to any location runs without dev-tree clones.

## Verification

Local roundtrip on Linux:

```bash
./tools/release/bundle_linux.sh
unzip -d /tmp vibe3d-linux-render.zip
mv ~/Code/D-RadeonProRender ~/Code/D-RadeonProRender_HIDDEN
mv ~/Code/D-Cycles            ~/Code/D-Cycles_HIDDEN
VIBE3D_IPR_BACKEND=rpr VIBE3D_IPR_AUTOSTART=1 VIBE3D_IPR_TRACE=1 \
  /tmp/vibe3d-linux-render/vibe3d
# IPR should start, render the cube, log `[ipr] grab: ok=true ver=N`
mv ~/Code/D-RadeonProRender_HIDDEN ~/Code/D-RadeonProRender
mv ~/Code/D-Cycles_HIDDEN            ~/Code/D-Cycles
```

macOS + Windows scripts mirror the Linux script structurally but
their first end-to-end runs happen in CI — we don't have local dev
boxes on those platforms.

## CI

`.github/workflows/build.yml` invokes the platform-appropriate
bundle script when its `with_render: true` matrix dim fires. Heavy
(Cycles needs Blender's lib bundle pulled via LFS, plus the
Cycles CMake build — both add ~10-20 minutes per platform), so
the with-render rows are kept behind `workflow_dispatch` only.
The modeling-only artifacts ship on every release tag as before.

---

# Self-contained Linux AppImage (modeling) — `bundle_linux_appimage.sh`

Produces a single-file **`Vibe3D-x86_64.AppImage`** that runs
"download → `chmod +x` → run" on any Linux with a modern-enough
glibc, **without the target having SDL2 or the GTK3 stack
installed**. This is the modeling configuration (no render backends).

```bash
./tools/release/bundle_linux_appimage.sh                 # build
./tools/release/bundle_linux_appimage.sh --no-build      # reuse ./vibe3d
./tools/release/bundle_linux_appimage.sh --verify        # build + Xvfb launch-check
./tools/release/bundle_linux_appimage.sh --output /tmp/V.AppImage
```

The script builds `dub build --config=modeling --build=release
--d-version=ReleaseBuild` with LDC (defaults to the first `ldc2 >=
1.41` it finds — the Fedora system `ldc2` 1.40 can't build vibe3d),
fetches its packaging tools on first run (cached under
`.appimage-build/`), stages an AppDir, runs
`linuxdeploy` + `linuxdeploy-plugin-gtk`, and packs with
`appimagetool`.

## Why the whole GTK3 stack (not just SDL2)

`ldd ./vibe3d` shows the real runtime closure is the **entire GTK3
loader stack** (`libgtk-3`/`libgdk-3`/`libgdk_pixbuf` + its loader
modules/`libcairo`/`libpango`/`libjson-glib`/`libglycin` + wayland),
pulled in by the **native file dialog (nfde), not SDL2**.
`dub.json`'s `libs-linux` only names the tip. So the AppImage bundles
SDL2 **and** the GTK3 loader stack (via the gtk plugin, which also
emits the `GDK_PIXBUF_MODULE_FILE` / `GTK_PATH` / `GIO_MODULE_DIR`
env wrappers).

## Bundle vs system split

- **Bundled** (into `usr/lib`): `libSDL2`, the GTK3 stack + gdk-pixbuf
  loader modules, `libgobject/glib/gio`, `libjson-glib`, `libglycin`,
  `libcairo`, `libpango*`, `libgdk_pixbuf`, plus `libonnxruntime`
  (from the dub cache; the AI candidate-ranker backend). The full
  ldd closure resolves to the bundled copies.
- **System** (linuxdeploy's standard excludelist): `libGL/GLX/EGL` +
  graphics drivers, glibc / `libstdc++`, the X11 core, and the
  universally-present stable-ABI libs `libwayland-client`,
  `libfreetype`, `libfontconfig`, `libharfbuzz`. **Never** bundle
  GL/driver/glibc — bundling `libGL`/drivers breaks on other GPUs.

## glibc floor

LDC links against the host glibc, so an AppImage built here is
**floored at this build host's glibc** — Fedora 43 ≈ **glibc 2.42**.
It runs only on glibc ≥ that (breaks Ubuntu 22.04 = 2.35, 20.04 =
2.31). The script prints the floor at the end. Broader-distro reach
(building inside an old-glibc container, e.g. `manylinux_2_28` /
`ubuntu-22.04`) is a **follow-up decision, not done here** — this
slice validates the self-contained approach on the dev host.

## Fedora 43 / patchelf RELR workaround

Fedora 43 builds every shared lib with **RELR relative relocations**
(`-z pack-relative-relocs`). `linuxdeploy` runs `patchelf 0.18` on
each bundled lib to stamp an `$ORIGIN` rpath, but patchelf 0.18
**mis-rewrites RELR** — the lib's `.init_array` pointers relocate to
garbage and its constructor SIGSEGVs at load (crash in `call_init`,
before `main`; the app dies with an empty log). linuxdeploy's bundled
`strip` chokes on the same `.relr.dyn` section, so `NO_STRIP=1` is set.
The script works around the patchelf corruption by (1) copying the
**pristine** system lib back over each patchelf'd one, and (2) giving
the **executable** a *transitive* `DT_RPATH` (`$ORIGIN/../lib`) so the
now-rpath-less bundled libs still resolve their bundled siblings —
avoiding both per-lib rpath (no patchelf on the libs) and
`LD_LIBRARY_PATH` (which would leak into child processes and crash
them against the host libc). *If a future patchelf fixes RELR, or the
build moves into an old-glibc container with an older toolchain, this
workaround can be dropped.*

## Runtime layout note

vibe3d reads `config/` **relative to the CWD** (`config/tool_presets.yaml`
etc. — fatal if absent) and writes `events.log`/prefs to the CWD. The
AppImage mount is read-only, so the custom `AppRun` chdirs into a
writable working dir (`${XDG_CACHE_HOME:-~/.cache}/vibe3d/cwd`, override
with `VIBE3D_WORKDIR`) that symlinks the bundled `config/` + `assets/`,
then sources the gtk env hooks and execs the binary.

## Verify

`--verify` (or manually) launches it headless under Xvfb with software
GL and probes the HTTP test server:

```bash
env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 LIBGL_ALWAYS_SOFTWARE=1 \
    xvfb-run -a ./Vibe3D-x86_64.AppImage --test --http-port 8760 &
curl -s -X POST localhost:8760/api/reset      # {"status":"ok"}
curl -s localhost:8760/api/model              # 8 verts / 6 faces (cube)
# kill by PID when done
```

A clean start prints `[io] libassimp … linked statically` / `[http]
HTTP server started` with **no** `not found` / `error while loading`
lines. `ldd AppDir/usr/bin/vibe3d` should show SDL2/GTK3 resolving to
`$ORIGIN/../lib` while `libGL`/`libc`/`libstdc++`/`libX11` stay
`/lib64`.

## Not done here (owner sign-off)

- **Broad-distro glibc floor** — decide container-build vs the 2.42
  floor above.
- **CI wiring** — `build.yml` is deliberately untouched; adding the
  AppImage as a release asset is a separate, reviewable step.
- Genuine "clean non-dev distro" run (no SDL2/GTK installed).
