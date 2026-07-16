# Vibe3D

A polygonal 3D mesh editor in the spirit of modern box-modeling DCCs —
gizmo-driven direct manipulation, a configurable tool pipeline (action center /
axis / falloff / snap), falloff deformers, and Catmull-Clark subdivision.
Written in **D**, with OpenGL 3.3 Core Profile, SDL2 and Dear ImGui.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Language: D](https://img.shields.io/badge/language-D-b03931.svg)
[![CI](https://github.com/shulc/vibe3d/actions/workflows/ci.yaml/badge.svg)](https://github.com/shulc/vibe3d/actions/workflows/ci.yaml)
[![Latest release](https://img.shields.io/github/v/release/shulc/vibe3d?include_prereleases&sort=semver)](https://github.com/shulc/vibe3d/releases)
![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)

![vibe3d](https://github.com/user-attachments/assets/9d3df7bd-242b-4d0c-a8d4-b20f1180ccf9)

<!-- TODO: replace/supplement with an animated GIF of interactive editing
     (gizmo drag → edge extrude → falloff deform). A short loop sells the
     project far better than a static frame. -->

> **Status: alpha / under active development.** The modeling core is broad and
> usable — selection, transform tools, primitives, bevel / extrude / inset /
> bridge, slice tools, falloff deformers, subdivision & subpatch, UV tools,
> multi-layer documents, import/export, and undo/redo — but the project is young
> and rough edges are expected.

## What is this

Vibe3D is a from-scratch 3D modeling application built around a direct-manipulation
workflow familiar from industry-standard box modelers: you pick an edit mode
(vertices / edges / polygons), drop an interactive gizmo, and manipulate geometry
directly in the viewport. A configurable **tool pipeline** layers symmetry,
snapping, action-center and axis modes, and falloff on top of every transform, so
the same Move / Rotate / Scale core drives everything from a precise nudge to a
soft falloff deformation. An optional interactive preview render (IPR) panel
embeds the Cycles and Radeon ProRender engines for in-editor lighting checks.

It is written entirely in D and is, as far as we know, one of the few
ground-up polygon modelers in the D ecosystem.

## Download

Prebuilt binaries for **Linux, Windows and macOS** are on the releases page:

### → [Download the latest release](https://github.com/shulc/vibe3d/releases)

Downloads are self-contained per platform — Linux **AppImage** (`chmod +x` and
run), Windows zip or installer, macOS `.app` — with no extra dependencies to
stage. See **[INSTALL.md](INSTALL.md)** for per-platform steps (and the optional
AI image→3D generation add-on). Or [build from source](#build-from-source).

## Highlights

**Editing** — three modes (**Vertices** / **Edges** / **Polygons**; `1`/`2`/`3`,
`Space` to cycle) with rectangle drag-select (Shift adds, Ctrl removes), loop /
ring / connect / between, expand / contract, invert, and fill-holes. Every tool
takes numeric parameter entry in a YAML-driven **Tool Properties** panel.

**Transform** — interactive **Move** (`W`), **Rotate** (`E`), **Scale** (`R`)
gizmos and a unified **Transform** (`Y`) that exposes all three banks at once.

**Create** — Box, Sphere, Ellipsoid, Cylinder, Tube, Cone, Capsule, Torus and
Arc primitives (each a fully numeric interactive gizmo), plus click-to-place
**Pen** and single-**Vertex** tools.

**Mesh tools** — Bevel (vertex / edge / polygon), Inset, Extrude (edge / polygon
/ vertex / stroke), Bridge, Smooth Shift / Thicken, Spikey, Reduce; a Slice
family (Loop Slice, knife Slice, Edge Slice, Julienne, Axis / Screen Slice);
Edge Extrude / Extend / Slide / Spin; Make Polygon, Triple / Quadruple, Flip /
Fix Orientation, Clean Up; Duplicate / Mirror / Array / Radial Array / Radial
Sweep.

**Deform** — falloff-driven Soft Drag / Move / Rotate / Scale / Transform, Push,
Bend, Smooth, Jitter, Quantize, Shear, Twist, Swirl, Taper, Bulge, Flare,
Vortex, Flex, with on-screen, stackable falloff handles (linear / radial /
cylinder / screen / lasso / element / selection / vertex-map).

**Tool pipeline** — action-center and axis modes (auto / selection / border /
element / screen / origin / local / world / work-plane), snapping to seven target
types plus a fixed grid, symmetry (X/Y/Z or work-plane), and a configurable work
plane — all driven from the status bar.

**Surfaces** — **Catmull-Clark** subdivision (`D`) and toggleable **subpatch**
(`Tab`) surfaces; a UV toolkit (planar project, relax, fit, flip / rotate /
mirror, pack, per-map ops).

**Documents & I/O** — a multi-layer document model; native **`.v3d`** format
(JSON, lossless); import / export of **OBJ**, **glTF**, **FBX** (statically-linked
assimp) and **LWO**; an optional **AI image→3D** generation add-on; and **Quad
Remesh** via an external helper.

**Workspace** — a dockable multi-viewport layout with per-viewport cameras and
BVH-accelerated picking; undo / redo history (`Ctrl+Z` / `Ctrl+Shift+Z`), macro
recording, event recording (`F1`/`F2`) and deterministic playback
(`--playback <file>`); configurable keyboard shortcuts (`config/shortcuts.yaml`);
and an optional in-editor IPR render preview in the `with-render` build.

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
| Subdivide / Subpatch toggle | `D` / `Tab` |
| Undo / Redo | `Ctrl+Z` / `Ctrl+Shift+Z` |

## Build from source

Requires [DUB](https://dub.pm/) and a D compiler (DMD or LDC), plus an installed SDL2.

```sh
dub build                              # default = modeling (with the AI ranker)
dub build --config=modeling-noai       # modeling without the ONNX AI ranker
dub build --config=with-render         # adds the Cycles + RPR IPR backends
./vibe3d
```

The default `modeling` configuration is fast and free of external render
dependencies — modeling, selection, tools, undo/redo and event playback are all in
this build. `modeling-noai` drops the ONNX-based candidate ranker (this is the
Windows 7-capable build). The `with-render` configuration adds the optional IPR
panel (see below). All render code lives behind a `version (WithRender)` boundary
and is excluded from both modeling builds.

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
| `--window WxH` | Initial window size (e.g. `--window 1426x966`) |
| `--viewport WxH` | Size the window so the 3D viewport is exactly `WxH` |
| `--test` | Start the HTTP server used by the test harness |
| `--no-http` | Run without the HTTP server |
| `--http-port 9090` | HTTP server port (default: 8080) |

## Render backends (optional)

The `with-render` build embeds an Interactive Preview Render (IPR) panel powered by
the **Cycles** (CPU + CUDA/OptiX/Metal where available) and **Radeon ProRender**
(CPU; GPU gated behind `VIBE3D_RPR_ALLOW_GPU=1`) engines. Render code is fully
isolated behind a `version (WithRender)` boundary and is excluded from the default
modeling build.

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
`./run_all.d` fans out to every suite (unit tests, reference-geometry diffs,
module unittests) and prints a single PASS/FAIL summary.

## Dependencies

The default `modeling` build pulls only lightweight bindings and helpers (fetched
automatically by DUB):

- [bindbc-sdl](https://github.com/BindBC/bindbc-sdl) — SDL2 bindings
- [bindbc-opengl](https://github.com/BindBC/bindbc-opengl) — OpenGL bindings
- [d_imgui](https://github.com/shulc/D-ImGui) — Dear ImGui for D
- [D-OpenSubdiv](https://github.com/shulc/D-OpenSubdiv) — OpenSubdiv wrapper (Catmull-Clark)
- [D-BVH](https://github.com/shulc/D-BVH) — static-linked BVH for ray picking (bundles nanort)
- [bindbc-assimp6](https://github.com/shulc/bindbc-assimp6) — assimp bindings (static OBJ/glTF/FBX)
- [D-Lwo2Writer](https://github.com/shulc/D-Lwo2Writer) — clean-room LWO2 reader/writer
- [nfde](https://github.com/inochi2d/nativefiledialog-d) — native file dialogs
- [D-YAML](https://github.com/shulc/D-YAML) — YAML parsing (config files)
- [D-OnnxRuntime](https://github.com/shulc/D-OnnxRuntime) — ONNX Runtime for the AI candidate ranker (dropped in `modeling-noai`)

The `with-render` build additionally pulls:

- [D-Cycles](https://github.com/shulc/D-Cycles) — Cycles renderer wrapper
- [D-RadeonProRender](https://github.com/shulc/D-RadeonProRender) — Radeon ProRender SDK wrapper
- Transitive runtime libraries: OpenImageIO, OpenColorIO, OpenEXR, Imath,
  Embree, Open Image Denoise, oneTBB, Intel oneAPI DPC++/SYCL runtime.

The embedded UI font is [Inter](https://rsms.me/inter/) (SIL Open Font License 1.1).

## License

Vibe3D itself is released under the [MIT License](LICENSE).

Distribution zips bundle a number of third-party libraries with their own
open-source licenses (MIT, Apache-2.0, BSD-3-Clause, Zlib, BSL-1.0, OFL-1.1).
The full attribution text required for redistribution is in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). No EULA, activation or
click-through is involved — all components are redistributable under standard
OSI-approved terms.
