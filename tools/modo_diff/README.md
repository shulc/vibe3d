# modo_diff

Geometry comparison harness for vibe3d vs MODO 9 (902). Sister tool to
`tools/blender_diff/` — same case JSON schema, same reused
`vibe3d_dump.d` and `diff.py` from blender_diff.

Currently focused on **polygon bevel** comparison (the modeling
operation vibe3d's polygon mode is most directly inspired by). Edge
bevel is not yet supported on the MODO side because MODO 9's
edge-bevel parameterization (`Width Mode`, `Round Level`, `Inset`) does
not map 1:1 to vibe3d's edge bevel.

## Layout

```
tools/modo_diff/
├── modo_dump.py    # MODO Python: applies the case ops, dumps mesh JSON.
├── run.d           # Orchestrator: starts vibe3d --test, runs modo_dump
│                   # + the shared vibe3d_dump.d + diff.py per case.
├── cases/          # Test cases (JSON schema = blender_diff cases/).
└── README.md
```

## Requirements

- MODO 9 (902) installed locally with `modo_cl` available.
- The MODO launcher needs:
  - `LD_LIBRARY_PATH` pointing at libidn.so (for libidn → libidn2 stub).
  - `NEXUS_CONTENT` pointing at `~/.luxology/Content`.
- `python3` for diff.py.
- `dub`, `dmd` for vibe3d build.

## Usage

```bash
./run.d                                          # all cases
./run.d poly_bevel_top_face_inset_extrude        # single case
./run.d --no-build                               # skip dub build
./run.d --keep                                   # keep vibe3d alive after run
```

Environment overrides (defaults shown):

```bash
MODO_BIN=/home/ashagarov/Program/Modo902/modo_cl
MODO_LD_LIBRARY_PATH=/home/ashagarov/.local/lib
MODO_NEXUS_CONTENT=/home/ashagarov/.luxology/Content
```

## Status

| Case | Result | Notes |
|---|---|---|
| poly_bevel_top_face_inset_extrude | PASS | bit-for-bit |
| poly_bevel_top_face_pure_inset    | PASS | bit-for-bit |
| poly_bevel_top_face_pure_extrude  | PASS | bit-for-bit |
| poly_bevel_two_faces_individual   | PASS | bit-for-bit |
| poly_bevel_two_faces_grouped      | XFAIL | vibe3d first-face-wins ≠ MODO accumulated-shift at shared corners |
| poly_bevel_irregular_quad         | PASS | bit-for-bit (non-square trapezoid) |

## Implementation notes

### MODO scripting in headless mode

MODO 9 / `modo_cl` in headless mode has several quirks worth recording:

1. **Python script invocation**: `lx.eval('pyscript.run "/path/to.py"')`
   doesn't work. Instead, write a Modo command-script-style file that
   starts with `#python` shebang and load via `@/path/to/script.py`
   (delivered through `modo_cl`'s stdin or as a `-cmd` arg).

2. **Selection via `select.element`**: silently no-ops in headless mode.
   Use `modo.Polygon.select(replace=True)` (Python API) instead. For
   additive selection on subsequent polygons, call `.select()` with no
   args (modo 9's modo.py treats no-arg as additive).

3. **Polygon bevel command**: `poly.bevel` is a TOOL, not a command.
   Sequence: `tool.set poly.bevel on 0` → `tool.attr poly.bevel inset N`,
   `tool.attr poly.bevel shift N`, `tool.attr poly.bevel group 0|1` →
   `tool.doApply` → `tool.set poly.bevel off 0`.

4. **`foundrycrashhandler` deadlock**: MODO forks a daemon
   `foundrycrashhandler` that inherits the parent's stdout/stderr fds
   and stays alive after `modo_cl` exits. Capturing modo_cl output via
   a pipe (`pipeProcess` / `executeShell` without redirect) deadlocks —
   the parent reads forever waiting for EOF that never comes because
   the crash handler holds the pipe open. Workaround: redirect modo_cl's
   stdout/stderr to a regular file (`> /tmp/foo 2>&1`). The fd is
   non-blocking; the shell exits cleanly. Background crash handlers
   accumulate over multiple runs — periodically `pkill -9 foundrycrashhandler`
   or accept them as harmless (they exit when the parent shell does).

### Group mode divergence

Vibe3D's `group=true` is **MODO-INSPIRED but not MODO-equivalent**.
- Vibe3D: per-face center/normal + first-face-wins at shared corners.
- MODO: per-face center/normal + **accumulated shift** from all faces
  touching the shared corner.

The two-faces-grouped case is the simplest scenario where this
diverges. To close that XFAIL we'd need a region-aware shared-corner
solver (similar to Blender's `bmesh.ops.inset_region`). For now the
single-face and individual-mode cases all pass bit-for-bit.
