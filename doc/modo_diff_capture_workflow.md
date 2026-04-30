# modo_diff: capturing a new test case from interactive MODO

Workflow for adding a new `tools/modo_diff/cases/*.json` case by recording a
manual MODO session (selection + bevel parameters), then letting the
`run.d` orchestrator re-run the operation headlessly and compare against
vibe3d.

## Why this workflow

`tools/modo_diff/run.d` always re-runs MODO via `modo_dump.py` to produce
the reference output (we never cache MODO geometry). So a new case only
needs:

- which polygons were selected (their **original** vertex coordinates,
  before the bevel),
- the bevel parameters (`insert`, `shift`, `group`).

The simplest way to capture both is to run a small helper script in
MODO's Script Editor **before** applying the bevel manually.

## Step 1 — capture the selection in MODO

1. Open MODO interactively (full GUI).
2. Create a unit cube (`Item → Create → Mesh Item → Cube`) if the scene
   is empty.
3. Switch to Polygons mode and select the polygons you want to bevel.
4. Open the Script Editor (`F5` / `Layout → Editors → Scripting`).
5. Paste the script below into a new tab and **edit `INSET`, `SHIFT`,
   `GROUP`** at the top to the values you intend to apply manually. Run
   it (`Ctrl+Enter`).

```python
#python
# Run AFTER selecting polygons in MODO, BEFORE applying bevel.
# Dumps selected polygon orig coords + chosen bevel params to
# /tmp/modo_capture.json — the file I (Claude) will turn into a case
# JSON in tools/modo_diff/cases/.
import lx, modo, json

scene = modo.Scene()
mesh = next((m for m in scene.items("mesh") if len(m.geometry.vertices) > 0), None)
assert mesh, "no mesh in scene — add a cube first"

# Read selected polys via layerservice query, then collect their
# polygon-vertex coords (these are the ORIG coords for the case JSON).
sel_q = lx.eval('query layerservice polys ? selected') or ''
sel_set = set(int(s) for s in str(sel_q).replace('(', '').replace(')', '').replace("'", '').split(',') if s.strip().lstrip('-').isdigit())

sel_polys = []
for p in mesh.geometry.polygons:
    if p.index in sel_set:
        sel_polys.append([list(v.position) for v in p.vertices])

# Edit these to whatever you'll apply manually:
INSET = 0.10
SHIFT = 0.05
GROUP = False   # True for grouped multi-face bevel

case = {
    "_comment": "Captured from MODO interactive session.",
    "ops": [{
        "op":     "polygon_bevel",
        "faces":  sel_polys,
        "insert": INSET,
        "shift":  SHIFT,
        "group":  GROUP,
    }],
    "tolerance": 0.001,
}
with open("/tmp/modo_capture.json", "w") as f:
    json.dump(case, f, indent=2)
print("wrote /tmp/modo_capture.json with", len(sel_polys), "selected polys")
print("inset =", INSET, "shift =", SHIFT, "group =", GROUP)
```

## Step 2 — apply the bevel manually (optional sanity check)

After the script runs, you can apply Bevel Polygon (`B`) with the same
`INSET`, `SHIFT`, `GROUP` values you put in the script. This is just for
your own visual sanity check — `run.d` will re-do the bevel headlessly
when it runs the comparison.

## Step 3 — hand off to Claude

Tell Claude "готово" (or paste the contents of `/tmp/modo_capture.json`).
Claude will:

1. Read `/tmp/modo_capture.json`.
2. Create a new case file under `tools/modo_diff/cases/<name>.json`
   with that content (and a friendlier filename + comment).
3. Optionally also drop a sister copy under `tools/blender_diff/cases/`
   so blender_diff stays in sync.
4. Run `rdmd tools/modo_diff/run.d --no-build <name>` and report PASS /
   FAIL / XFAIL.

If the case fails, the diff output will tell us exactly which vertices
disagree and by how much — that points at any remaining feature gap in
vibe3d's `source/poly_bevel.d`.

## Alternative: tell Claude verbally

If you don't want to run the script, you can just describe what you did:

> "I selected the +y top face and the -x left face of a unit cube,
> applied inset=0.1, shift=0.05, group=true."

Claude will create the case JSON manually and run the comparison. Less
foolproof for non-axis-aligned coordinates, but fine for cube tests.
