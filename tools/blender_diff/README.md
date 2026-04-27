# Blender ↔ Vibe3D geometry diff

Run the same operation in both Blender and Vibe3D and report per-vertex
geometry differences. Used to validate that bevel/subdivision/etc. match
Blender's reference behavior.

## Requirements

- `blender` on PATH (tested with 5.1)
- `dub`, `dmd`, `rdmd`
- `python3` (no extra packages)
- `curl`

## Run

```bash
./run.d                            # all cases under cases/
./run.d cube_corner_w02_s4         # one case (no .json suffix)
./run.d --keep                     # leave vibe3d --test running afterwards
./run.d --no-build                 # skip dub build
```

Exit code = number of failing cases. A case fails if any vertex has no
counterpart within `tolerance` of the case JSON, or if face counts /
face-vertex-count distribution disagree.

Output JSONs land in `/tmp/vibe3d_diff/<case>.{blender,vibe3d}.json` for
post-mortem inspection.

## Adding a case

Drop a new `cases/<name>.json`:

```jsonc
{
  "_comment": "Optional human-readable description.",
  "ops": [
    {
      "op": "bevel",
      "edges": [
        {"v0": [x, y, z], "v1": [x, y, z]},
        ...
      ],
      "width": 0.2,
      "segments": 4,
      "superR": 2.0
    }
  ],
  "tolerance": 0.001
}
```

Edges are identified by **endpoint coordinates**, not indices — vibe3d and
Blender number them differently, so endpoints are the only portable key.
The starting mesh is always Blender's `primitive_cube_add(size=1.0)`,
which matches vibe3d's `makeCube()` (vertices at ±0.5).

## Limitations

- Only `bevel` op so far. Add new op handlers in `blender_dump.py` and
  `vibe3d_dump.d` to support more.
- `superR` must be `2.0` (circular). Other values raise — Blender's
  bevel `profile` knob doesn't have a clean closed-form inverse to the
  super-ellipse exponent.
- Diff matches by nearest-neighbor position only. Topology beyond
  vertex/face counts and face-vertex-count distribution is not checked.

## Architecture

```
run.d                            orchestrator (D rdmd)
├── (dub build)
├── starts vibe3d --test --http-port 18080
├── for each case:
│   ├── blender_dump.py <case> <out>      (Blender bpy script)
│   ├── vibe3d_dump.d  <case> <out>       (D rdmd, talks to /api/*)
│   └── diff.py <ref> <cand> --case ...   (Python, prints + exit code)
└── kills vibe3d (unless --keep)
```

The orchestrator never compiles the dump scripts — `rdmd` and `python`
run them straight from source. This keeps the tool installable as a
plain checkout of `tools/blender_diff/`.
