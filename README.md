# Vibe3D

A polygonal 3D mesh editor in the spirit of MODO and LightWave3D — gizmo-driven
direct manipulation, a configurable tool pipeline (action center / axis / falloff /
snap), falloff deformers, and Catmull-Clark subdivision. Written in **D**, with
OpenGL 3.3 Core Profile, SDL2 and Dear ImGui.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Language: D](https://img.shields.io/badge/language-D-b03931.svg)
[![CI](https://github.com/shulc/vibe3d/actions/workflows/ci.yaml/badge.svg)](https://github.com/shulc/vibe3d/actions/workflows/ci.yaml)
[![Latest release](https://img.shields.io/github/v/release/shulc/vibe3d?include_prereleases&sort=semver)](https://github.com/shulc/vibe3d/releases)
![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)

![vibe3d](https://github.com/user-attachments/assets/9d3df7bd-242b-4d0c-a8d4-b20f1180ccf9)

<!-- TODO: replace/supplement with an animated GIF of interactive editing
     (gizmo drag → edge extrude → falloff deform). A short loop sells the
     project far better than a static frame. -->

> **Status: alpha / under active development.** The modeling core works —
> selection, transform tools, primitives, edge tools, falloff deformers,
> subdivision, undo/redo — but the project is young and rough edges are
> expected.

## What is this

Vibe3D is a from-scratch 3D modeling application built around a MODO/LightWave-style
workflow: you pick an edit mode (vertices / edges / polygons), drop an interactive
gizmo, and manipulate geometry directly in the viewport. A configurable **tool
pipeline** layers symmetry, snapping, action-center and axis modes, and falloff on
top of every transform, so the same Move / Rotate / Scale core drives everything
from a precise nudge to a soft falloff deformation. An optional interactive preview
render (IPR) panel embeds Cycles and Radeon ProRender for in-editor lighting checks.

It is written entirely in D and is, as far as we know, one of the few
ground-up polygon modelers in the D ecosystem.

## Download

Prebuilt binaries for **Linux, Windows and macOS** are on the releases page:

### → [Download the latest release](https://github.com/shulc/vibe3d/releases)

Downloads are self-contained per platform — Linux **AppImage** (`chmod +x` and
run), Windows zip or installer, macOS `.app` — with no extra dependencies to
stage. See **[INSTALL.md](INSTALL.md)** for per-platform steps (and the optional
Linux AI-generation add-on). Or [build from source](#build-from-source).

## Highlights

- Polygon editing in three modes: **Vertices**, **Edges**, **Polygons** (`1`/`2`/`3`, or `Space` to cycle)
- Interactive transform gizmos: **Move** (`W`), **Rotate** (`E`), **Scale** (`R`), and a unified **Transform** (`Y`) that exposes all three banks at once
- **Create** primitives — Box, Sphere, Cylinder, Cone, Capsule, Torus — plus a click-to-place **Pen** tool
- **Edge tools** — interactive **Edge Extrude** and **Edge Extend**
- **Falloff deformers** — Soft Drag / Move / Rotate / Scale, plus Push, Bend, Smooth, Jitter, Quantize, Shear, Twist, Swirl, Taper, Bulge, Flare, Vortex
- Configurable **tool pipeline**: symmetry, snapping, action-center and axis modes, with on-screen falloff handles (linear / radial / cylinder / screen)
- Rich selection: rectangle drag-select (Shift adds, Ctrl removes), connected flood-fill, invert, loop / ring / between, expand / contract
- **Catmull-Clark** subdivision surfaces (`D`)
- Numeric parameter entry for every tool in the ImGui properties panel
- Adaptive screen-space gizmo sizing (`-` / `=`); back-facing geometry is not pickable
- Undo / redo command history (`Ctrl+Z` / `Ctrl+Shift+Z`)
- OpenGL VBO/VAO rendering with GPU offset-drag and partial vertex upload
- Configurable keyboard shortcuts (`config/shortcuts.yaml`)
- Event recording (`F1`/`F2`) and deterministic playback (`--playback <file>`)

**Full tool reference and keyboard controls:** see [USAGE.md](USAGE.md).

## Usage

A quick taste of the controls (the complete cheat-sheet lives in [USAGE.md](USAGE.md)):

| Action | Keys / mouse |
|---|---|
| Orbit / Pan / Zoom camera | Alt+LMB / Alt+Shift+LMB / Ctrl+Alt+LMB |
| Frame scene / selection | `A` / Shift+`A` |
| Vertices / Edges / Polygons mode | `1` / `2` / `3` |
| Move / Rotate / Scale / Transform | `W` / `E` / `R` / `Y` |
| Connected select / Invert | `]` / `[` |
| Subdivide | `D` |
| Undo / Redo | `Ctrl+Z` / `Ctrl+Shift+Z` |

## Build from source

Requires [DUB](https://dub.pm/) and a D compiler (DMD or LDC), plus an installed SDL2.

```sh
dub build                              # default = modeling-only
dub build --config=with-render         # adds Cycles + RPR IPR backends
./vibe3d
```

The default `modeling` configuration is fast and free of external render
dependencies — modeling, selection, tools, undo/redo and event playback are all in
this build. The `with-render` configuration adds the optional IPR panel (see below).

You can also produce a self-contained release bundle locally:

```sh
./tools/release/bundle_linux.sh        # Linux
./tools/release/bundle_macos.sh        # macOS
.\tools\release\bundle_windows.ps1     # Windows (PowerShell)
```

### Runtime flags

| Flag | Description |
|---|---|
| `--playback events.log` | Replay a recorded event session |
| `--test` | Start the HTTP server used by the test harness |
| `--no-http` | Run without the HTTP server |
| `--http-port 9090` | HTTP server port (default: 8080) |

## Render backends (optional)

The `with-render` build embeds an Interactive Preview Render (IPR) panel powered by
[Cycles](https://projects.blender.org/blender/cycles) (CPU + CUDA/OPTIX/Metal where
available) and [Radeon ProRender](https://gpuopen.com/radeon-prorender/) (CPU; GPU
gated behind `VIBE3D_RPR_ALLOW_GPU=1`). Render code is fully isolated behind a
`version (WithRender)` boundary and is excluded from the default modeling build.

## Testing

Unit tests are D programs that drive a running vibe3d instance through its HTTP API:

```sh
./run_test.d                     # all unit tests (auto-scaled workers)
./run_test.d -j N                # override the worker count
./run_test.d test_pen            # one test (also: pen, tests/test_pen.d)
./run_test.d -v test_pen         # stream the test's stdout/stderr
./run_test.d --keep              # leave vibe3d running after tests finish
./run_test.d --no-build          # skip `dub build`
```

With no `-j`, the worker count auto-scales to the host (`clamp(nCPU/4, 4, 12)`).
Pin a per-machine default by exporting `VIBE3D_TEST_JOBS` (e.g. in your shell
rc); an explicit `-j` still overrides it.

Test files live in `tests/test_*.d`; recorded event sessions in `tests/events/*.log`.

## Dependencies

Modeling build:

- [bindbc-sdl](https://github.com/BindBC/bindbc-sdl) — SDL2 bindings
- [bindbc-opengl](https://github.com/BindBC/bindbc-opengl) — OpenGL bindings
- [d_imgui](https://github.com/shulc/imgui) — Dear ImGui for D
- [D-OpenSubdiv](https://github.com/shulc/D-OpenSubdiv) — Pixar's OpenSubdiv wrapper
- [nfde](https://code.dlang.org/packages/nfde) — native file dialogs
- [dyaml](https://github.com/dlang-community/D-YAML) — YAML parsing

`with-render` build additionally pulls:

- [D-Cycles](https://github.com/shulc/D-Cycles) — Cycles renderer wrapper
- [D-RadeonProRender](https://github.com/shulc/D-RadeonProRender) — Radeon ProRender SDK
- Transitive runtime libraries: OpenImageIO, OpenColorIO, OpenEXR, Imath,
  Embree, Open Image Denoise, oneTBB, Intel oneAPI DPC++/SYCL runtime.

## License

Vibe3D itself is released under the [MIT License](LICENSE).

Distribution zips bundle a number of third-party libraries (Cycles, RPR SDK,
OpenImageIO, etc.) with their own open-source licenses (Apache-2.0, BSD-3-Clause,
MIT, Zlib, BSL-1.0). The full attribution text required for redistribution is in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). No EULA, activation or
click-through is involved — all components are redistributable under standard
OSI-approved terms.
