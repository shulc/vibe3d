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
