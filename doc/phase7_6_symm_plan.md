# Symmetry Plan — Phase 7.6 of `phase7_plan.md`

Detailed breakdown for the **SYMM** Tool Pipe stage. Sits at
`LXs_ORD_SYMM = 0x31` (between WORK `0x30` and SNAP `0x40`). Source
of truth: MODO 9.0.2 SDK (`LXSDK_661446/`), bundled help pages,
`resrc/*.cfg` configuration files. Same overall format as
`doc/snap_plan.md` and `doc/falloff_plan.md`.

The skeleton already exists: `TaskCode.Symm` and `ordSymm = 0x31`
live in `source/toolpipe/stage.d`; `SymmetryPacket` (with
`bool[3] axisFlags` + `Vec3 pivot`) sits in
`source/toolpipe/packets.d:186` and is threaded into `ToolState`.
What's missing is the concrete `SymmetryStage`, its UI plumbing,
and per-tool consumption.

---

## Goal

Add a **mirror plane** to vibe3d: while symmetry is on, every
selection / transform / primitive-creation acts on both the
near-side element and its mirror across the plane. Matches MODO's
"scene-wide symmetry" toggle (the orange button next to the modes
toolbar), not the deformer Symmetry Tool. Concretely:

1. Status-bar Symmetry pulldown (X / Y / Z / Off) ⇆ HTTP attrs.
2. Move / Rotate / Scale automatically mirror per-vertex deltas
   across the plane while the tool drags.
3. Selection clicks (vertex / edge / face) auto-add the mirror
   counterpart.
4. Primitive creation tools (Box / Sphere / Cylinder / Cone /
   Capsule / Torus / Pen) snap their construction to be plane-
   symmetric when placed across the plane (deferrable subphase).
5. One-shot `vert.symmetrize` command — clean up small asymmetries
   in the existing mesh by snapping near-mirror vertex pairs to
   the same position. (Optional in-scope; may slip to 7.6f.)

After 7.6 lands, the workflow `Symmetry On → tweak one corner of a
cube → both corners move` works with no extra clicks, the way it
does in MODO / Blender / Maya.

---

## MODO source-of-truth (verified locally)

### SDK — `LXSDK_661446/include/lxtool.h`

The task code, ordinal, and packet keys vibe3d already mirrors:

```c
#define LXi_TASK_SYMM      LXxID4 ('S','Y','M','M')   // ←  TaskCode.Symm
#define LXs_TASK_SYMM      "SYMM"
#define LXs_ORD_SYMM       "\x31"                     // ←  ordSymm

#define LXsP_TOOL_SYMMETRY "tool.symmetry"            // ←  SymmetryPacket
#define LXu_SYMMETRYPACKET "F13F6933-1289-4EFC-9CE1-D5C4F13EE7D8"
```

The C interface tools consume to read symmetry state
(`ILxSymmetryPacket`, `lxtool.h:526`):

```c
typedef struct vt_ILxSymmetryPacket {
    int          Active   (self);
    int          Axis     (self, LXtFVector axvec, float *offset);
       // returns 0..2 for X/Y/Z, 3 for arbitrary
    LXtPointID   Point    (self, mesh, LXtPointID   vrx);
    LXtPolygonID Polygon  (self, mesh, LXtPolygonID pol);
    LXtEdgeID    Edge     (self, mesh, LXtEdgeID    edge);
    int          Position (self, const LXtFVector pos, LXtFVector sv);
       // mirrors `pos` into `sv`; returns 0 if pos is on the plane
    int          BaseSide (self);
    void         SetBase  (self, const LXtFVector pos);
    int          TestSide (self, const LXtFVector pos, int useBase);
} ILxSymmetryPacket;
```

Three groups of methods:

* **Configuration** — `Active()`, `Axis()` give the plane.
* **Element pairing** — `Point/Polygon/Edge()` return the symmetric
  counterpart of an existing mesh element (or NULL if none). MODO
  caches a per-element pairing table; vibe3d will recompute it from
  vertex positions on demand (or cache after first build).
* **Position math** — `Position(pos, sv)` mirrors a free point;
  `BaseSide` / `SetBase` / `TestSide` track which side of the plane
  the user clicked on first (so subsequent mirrored ops keep the
  user's side as "base"). Vibe3d stage exposes the same primitives.

Mesh-level helpers (`lxmesh.h`):

```c
int Symmetry        (LXtMeshID, LXtPointID);   // returns the mirror point or NULL
int OnSymmetryCenter(LXtMeshID, LXtPointID);   // 1 if the point IS on the plane
```

These are a convenience wrapper — same data the packet exposes,
but indexed by mesh + element ID. Vibe3d won't ship a mesh-level
API; the stage owns the pairing logic.

### Configuration (`resrc/cmdhelp.cfg` & friends)

Six commands frame the user surface:

| Command                  | Meaning                                       |
|--------------------------|-----------------------------------------------|
| `symmetry.state`         | Master on/off (orange toolbar button).        |
| `symmetry.axis <X/Y/Z/Arbitrary>` | Pick the mirror axis.                |
| `symmetry.topology`      | Topological pairing instead of position-based.|
| `symmetry.useSSet`       | Use a named edge selection set as the spine.  |
| `symmetry.assignSSet`    | Assign current edge sel as the topology spine.|
| `select.symmetry`        | Full options dialog (axis, vec, offset, useXfrm, topology, …). |

The `select.symmetry` argument list is the canonical schema:

```
active     bool      master toggle
axis       enum      x | y | z | arbitrary    (ArgumentType "symm-axis")
vecX/Y/Z   float     arbitrary axis vector    (axis == arbitrary)
offset     float     plane offset along axis  (so X=2 mirrors at x=2)
useXfrm    bool      mirror plane ≡ Work Plane (instead of world axes)
topology   bool      topological pairing
uvActive   bool      ── UV symmetry (out of scope for vibe3d)
uvAxis     enum
uvOffset   float
```

The Symmetry Tool deformer (`symmetry.tool`, `props.cfg:15600`)
is a *separate* tool that forces existing mesh topology to become
plane-symmetric. It has its own attrs (`threshold`, `mode`,
`reverse`). Out of scope for the SYMM **stage**, but vibe3d may
expose its action under `vert.symmetrize` (see 7.6f).

### Bundled help — `help/pages/modeling/symmetry.html`

Distilled UX rules:

* Title of the toolbar button updates to reflect the active axis
  ("Symmetry: X").
* Operations apply to *corresponding* elements. "Best results when
  the model is perfectly symmetrical".
* Off-plane vertices: the plane is always at the zero coordinate
  unless `offset` is non-zero. Position-based pairing only matches
  vertices within an epsilon.
* Topological mode handles models whose topology is symmetric but
  whose positions aren't (e.g. asymmetrical pose). Requires either
  a flood-fill from a centerline edge or an explicit selection
  set.
* `Use Selection Set` / `Assign Selection Set` — define the
  centerline edge loop for topological mode.
* `Symmetrize` (a.k.a. `vert.symmetrize`) — one-shot: pick a side
  (positive or negative) and the other side is rebuilt to match.

### `SymmetryPopover.cfg`

Compact UI: Symmetry toggle • Axis dropdown • Topology toggle •
Use Selection Set • Assign Selection Set • Symmetrize • More
Options. Vibe3d's status-bar pulldown follows the same set,
minus topology / selection-set rows in v1 (see 7.6 scope below).

---

## Vibe3d adaptation

We are not building MODO; we are building a focused subset.

**In-scope:**

* X / Y / Z plane axes (no arbitrary axis in v1 — adds a 4×4 frame
  to the packet but no UX path to enter it).
* Plane offset along the chosen axis (already supported via
  `pivot` field; ship the UI).
* Optional `useXfrm` (mirror plane ≡ active workplane). Keeps the
  packet honest with the WORK stage upstream.
* Position-based pairing with epsilon — runs in `O(n log n)` after
  any mesh edit, cached on `Mesh.mutationVersion`.
* Move / Rotate / Scale per-vertex mirroring during drag.
* Symmetric selection on click (vertex / edge / face).
* Symmetric primitive creation when the new element straddles the
  plane.
* `vert.symmetrize` one-shot: snap mirror-pairs to averaged
  positions; flag stragglers (no pair within epsilon).

**Deferred:**

* Arbitrary axis. The packet will reserve a `Vec3 axisVec` field;
  the v1 pulldown picks among X/Y/Z only.
* Topological symmetry. Schema knob `topology` is wired but the
  evaluator returns "fall back to position" until a follow-up
  ships flood-fill pairing from an edge selection set.
* UV symmetry — vibe3d has no UV system.
* Symmetry Tool (the deformer). `vert.symmetrize` covers the most
  common need; the interactive deformer can land later.

---

## Architecture

### Packets — `source/toolpipe/packets.d`

`SymmetryPacket` already exists; extend it with the runtime data
consumers need:

```d
struct SymmetryPacket {
    bool          enabled       = false;        // master on/off
    int           axisIndex     = -1;           // 0=X 1=Y 2=Z (-1 if disabled)
    float         offset        = 0.0f;         // plane = axis * offset
    bool          useWorkplane  = false;        // mirror ≡ workplane (overrides axis/offset)
    bool          topology      = false;        // reserved; v1 = false
    float         epsilonWorld  = 1e-4f;        // pairing tolerance
    // Cached plane (populated by SymmetryStage.evaluate from the
    // axis / offset / workplane fields above):
    Vec3          planePoint    = Vec3(0,0,0);
    Vec3          planeNormal   = Vec3(1,0,0);  // normalized
    // Vertex-pairing snapshot. Indices into Mesh.vertices; -1 if
    // the vertex sits on the plane (`onPlane[i] == true`) or has
    // no mirror within epsilon. Re-built when mesh.mutationVersion
    // changes; consumers see a stable view for the duration of one
    // pipeline.evaluate.
    int[]         pairOf;
    bool[]        onPlane;
    // Backwards-compat fields the existing stub already declared
    // (kept for now; new code uses the named fields above):
    bool[3]       axisFlags;                    // derived from axisIndex
    Vec3          pivot         = Vec3(0,0,0);  // derived from offset+axis
}
```

Backwards-compat: the old `axisFlags[3]` stays as a derived view
(`stage.evaluate` populates it from `axisIndex`) so any code that
already reads it keeps working through the migration.

Pure helper colocated with the packet (no GL / no ImGui):

```d
/// Mirror a world-space point across the symmetry plane.
Vec3 mirrorPosition(const ref SymmetryPacket sp, Vec3 pos);

/// Is `pos` on the plane (within `sp.epsilonWorld`)?
bool isOnPlane(const ref SymmetryPacket sp, Vec3 pos);

/// Vertex index pair for `vi`: returns -1 for "on plane" or
/// "no mirror found". Reads sp.pairOf without recomputation.
int  mirrorVertex(const ref SymmetryPacket sp, int vi);
```

### Stage — `source/toolpipe/stages/symmetry.d` (new, ~250 LOC)

```d
class SymmetryStage : Stage {
    // — config
    bool   enabled       = false;
    int    axisIndex     = 0;          // 0/1/2 (X/Y/Z)  — only meaningful when enabled
    float  offset        = 0.0f;
    bool   useWorkplane  = false;
    bool   topology      = false;      // schema-only in v1
    float  epsilonWorld  = 1e-4f;

    // — pairing cache (rebuilt when mesh.mutationVersion changes)
    private uint    cachedMutationVersion_ = 0;
    private int[]   pairOf_;
    private bool[]  onPlane_;
    private Vec3    cachedPlanePt_;
    private Vec3    cachedPlaneN_;

    // injected refs (mirrors FalloffStage / ActionCenterStage shape)
    private Mesh*     mesh_;
    private EditMode* editMode_;

    override TaskCode taskCode() const … { return TaskCode.Symm; }
    override string   id()       const   { return "symmetry"; }
    override ubyte    ordinal()  const … { return ordSymm; }

    override void evaluate(ref ToolState state) {
        // 1. Resolve plane from useWorkplane / axisIndex / offset.
        //    state.workplane is already populated (WORK ord 0x30 < SYMM 0x31).
        // 2. Rebuild pair table if (!enabled) → drop; else if cached
        //    mutationVersion / plane changed → rebuildPairing().
        // 3. Publish into state.symmetry — copy planePoint, planeNormal,
        //    pairOf[], onPlane[] (slice; no allocation when unchanged).
    }

    // params() exposes: enabled (bool), axis (intEnum X/Y/Z),
    //                    offset (float), useWorkplane (bool),
    //                    topology (bool, disabled until topo lands),
    //                    epsilon (float, slider).
    override Param[] params() { … }
    override string  displayName() const {
        return enabled ? format("Symmetry: %s", axisName(axisIndex)) : "Symmetry";
    }
}
```

Pairing algorithm (`rebuildPairing` private to the stage):

```text
1. Compute mirror image of each vertex into a temp Vec3[] M[i].
2. Build a flat index sorted by the dominant axis of the plane
   normal: idx[] = order of vertices by axisIndex coord.
3. For each vertex i, binary-search idx[] for any vertex j whose
   coord lies within epsilon, then check |M[i] - V[j]| < epsilon
   in the other two axes too. If found AND j != i, set pairOf[i]=j.
4. Mark onPlane[i] = (|axisCoord(V[i]) - offset| < epsilon).
5. Asymmetric stragglers → pairOf[i] = -1 (no warning at evaluate
   time; vert.symmetrize surfaces them).
```

Cost: `O(n log n)` build; `pairOf[]` slice handed out by reference.
For a 100k-vertex mesh that's well under a frame; rebuilds only
on mesh edits or plane changes.

### Visual feedback — `source/symmetry_render.d` (new, ~80 LOC)

Translucent gridded plane drawn into the viewport when symmetry
is active. Same shader path as the existing grid (`shader.d`'s
`gridShader`) but parameterised on plane-normal / plane-offset.
Rendered before the gizmo so transform handles overlay on top.

Optional: a thin orange line through the symmetric counterpart of
the hovered vertex / edge / face during pick. Keeps the user
informed about "what's mirrored". Skip in v1 if it bloats the
subphase.

### Tool integration points

The existing transform tools take a `FalloffPacket` snapshot at
drag start. SYMM follows the same pattern — capture
`SymmetryPacket` once, then mirror every per-vertex displacement.

`source/tools/move.d::applyDeltaImmediate` (and its sibling in
rotate / scale) gain:

```d
// AFTER the existing per-vertex transform but BEFORE the GPU upload:
if (dragSymmetry.enabled) {
    foreach (vi; vertexIndicesToProcess) {
        int mi = dragSymmetry.pairOf[vi];
        if (mi < 0 || mi == vi) continue;       // on-plane / unpaired
        Vec3 mirrored = mirrorPosition(dragSymmetry, mesh.vertices[vi]);
        mesh.vertices[mi] = mirrored;
    }
}
```

For Rotate / Scale, the cluster framework (`drag.d` /
`acen_modo_parity_plan.md`) already groups vertices into per-
cluster pivots. Symmetry adds one more cluster pre-step: pair
each cluster with its mirror cluster (or the cluster mirrors onto
itself if it straddles the plane), and rotate the mirrored
cluster around the *mirrored* pivot with the *flipped* axis.

Edge cases worth calling out:

* **Drag spans the plane.** The selected vertex moves to the
  other side; its mirror also crosses → both sides flip. The
  pairing table built once at drag start stays consistent
  because we look up by index, not by current position.
* **Selection includes a vertex *and* its mirror** (e.g. user
  selected the whole mesh). The mirror loop sees both as "drive
  side"; the second pass overwrites the first with the mirrored
  delta. Guard: `if (mi <= vi) continue;` makes each pair fire
  exactly once.
* **Vertex ON the plane.** `onPlane[vi] == true`; transform it
  but constrain its motion to the plane (project the delta onto
  it) so it doesn't drift off. MODO's behaviour.

### Selection integration

`source/handler.d` (or the picking code in `app.d`) checks the
SYMM packet after a successful pick and adds the mirror
counterpart to the selection. Three new helpers in
`source/mesh.d`:

```d
int mirrorVertex (const ref Mesh m, const ref SymmetryPacket sp, int vi);
int mirrorEdge   (const ref Mesh m, const ref SymmetryPacket sp, int ei);
int mirrorFace   (const ref Mesh m, const ref SymmetryPacket sp, int fi);
```

Edges mirror by mirroring both endpoints and looking up the
resulting pair via `Mesh.edgeIndex`. Faces by mirroring all
vertices and matching against the existing face winding (reverse
the loop order so the mirrored face still has consistent
orientation).

### Status-bar UI — `source/buttonset.d` / `app.d`

New popup-button next to the Falloff pulldown:

```
[ ⊕ Symmetry: X ▾ ]
   ┌─────────────────┐
   │ ✓ Off           │
   │   X             │
   │   Y             │
   │   Z             │
   │ ─────────────── │
   │   Workplane     │  ← bool toggle (use workplane normal)
   │   Symmetrize…   │  ← cmd vert.symmetrize
   └─────────────────┘
```

Same pattern as the Snap pulldown (`source/snap.d` UI row): button
face shows the active state; popup has check-marked items. The
Tool Properties panel shows the rest (offset, epsilon, topology
when implemented).

---

## Subphases

Plan in 6 subphases following the snap / falloff convention.
Sizes are estimates relative to similar work that already shipped
(SnapStage was 277 LOC + 188 stage; FalloffStage 318 + 604).

### 7.6a — `SymmetryStage` skeleton + master toggle (~180 LOC)

* Add `source/toolpipe/stages/symmetry.d` — Stage subclass with
  enabled / axisIndex / offset attrs, `params()` schema, default
  `evaluate()` populates the packet but skips pairing (pair
  arrays empty when `!enabled`).
* Extend `SymmetryPacket` per the structure above.
* Wire the stage into `app.d::initToolPipe` after the FalloffStage.
* HTTP attrs round-trip: `tool.pipe.attr symmetry enabled true`,
  `tool.pipe.attr symmetry axis X`, etc.
* No tool integration yet — a smoke test verifies the packet
  fields propagate through `pipeline.evaluate`.
* New unit test `tests/test_toolpipe_symm.d` mirrors
  `test_toolpipe_skeleton.d` shape.

### 7.6b — Vertex pairing + Move integration (~220 LOC)

* `rebuildPairing()` — O(n log n) by the dominant axis, epsilon
  match in the orthogonal pair, `mutationVersion` cache.
* `mirrorPosition` / `mirrorVertex` helpers in
  `source/symmetry.d` (new).
* MoveTool consumes the packet: at drag start, snapshot
  `SymmetryPacket` via `g_pipeCtx.run()`; at every
  `applyDeltaImmediate`, mirror per-vertex.
* On-plane vertices: project delta onto the plane.
* New unit tests:
  * `test_toolpipe_symm_pair`: cube → 8 pairs across X.
  * `test_move_with_symm`: drag one corner, mirror corner moves.

### 7.6c — Symmetric selection (vertex/edge/face) (~150 LOC)

* `mirrorEdge` / `mirrorFace` in `source/mesh.d`.
* Picking path: after the existing single-element pick, if
  `state.symmetry.enabled`, also flip-select the mirror element.
  Implemented as a post-pick step in `app.d::handleClick` so the
  pick itself stays simple and Symmetric Pick falls out for
  free in Vertices / Edges / Polygons modes.
* Test: load a cube, click a vertex, assert `selectedVertices`
  has both clicked + mirror set.

### 7.6d — Rotate / Scale + symmetric clusters (~180 LOC)

* Extend `applyDeltaImmediate` mirror-pass to RotateTool and
  ScaleTool; mirror axis on both sides of the plane (right-handed
  rotation flips when crossing).
* Cluster pairing: `tools/rotate.d` and `tools/scale.d` already
  build cluster pivots via `acen_modo_parity_plan`; new
  `pairClusters()` matches each cluster to its mirror so the
  rotation axis can be flipped per side.
* Tests adapted from `test_move_with_symm`: rotate one edge
  around Y, mirror edge rotates the other way.

### 7.6e — Visual feedback (~120 LOC)

* `source/symmetry_render.d` — translucent plane wireframe.
* Status-bar pulldown ("Symmetry: X ▾") with the same popup-style
  used by Snap / Falloff.
* `displayName()` in the stage flips to `"Symmetry: X"` etc.
* Tool Properties section (auto, via the stage's `params()`).
* No test (visual-only); manual smoke note in the subphase commit.

### 7.6f — `vert.symmetrize` + asymmetry report (~100 LOC)

* Command in `source/commands/mesh/` (mirror the existing
  command-architecture pattern). Args: `side` (positive /
  negative).
* Walks `pairOf[]`; for each pair, copies the chosen side's
  position to the other (mirrored).
* Stragglers (`pairOf[i] == -1` and `!onPlane[i]`) → reported
  back via `/api/log` so callers see what didn't pair.
* History-aware (single undo entry).
* Test: mesh with one off-by-epsilon vertex; symmetrize fixes it.

### 7.6g — (deferred) Topological pairing

Out of scope for v1 — schema knob already shipped in 7.6a but
falls back to position pairing. A follow-up phase ships flood-
fill from an `Assign Selection Set` edge loop. Documented as
deferred so the schema doesn't grow unexpectedly later.

### 7.6h — (deferred) Primitive-creation symmetric placement

Out of scope for v1. Currently primitive tools place a single
mesh; a future phase wires them to instantiate two and
auto-merge across the plane. Captured here so the open-questions
list stays explicit.

---

## Decisions (resolved)

* **Axis enumeration.** v1 ships X / Y / Z (the MODO `symm-axis2`
  enum minus "arbitrary"). Arbitrary axis stays a deferred bolt-on
  via the `axisVec` packet field reservation.
* **Pairing strategy.** Position-based with epsilon, rebuilt on
  `mutationVersion` change. Topology mode is schema-only.
* **Plane source priority.** When `useWorkplane=true`, the
  workplane normal/center wins; `axisIndex` / `offset` are
  ignored. WORK stage runs first (`0x30 < 0x31`), so the data is
  there when SYMM evaluates.
* **Cluster mirroring for Rotate/Scale.** Clusters are paired in a
  separate pass; on-plane clusters mirror onto themselves. The
  per-cluster pivot is mirrored, the per-cluster axis (right /
  up / fwd) is mirrored too — the rotation framework already
  takes a basis per cluster.
* **On-plane behaviour.** Vertices flagged `onPlane` are
  constrained to motion within the plane (delta projected). This
  matches MODO and avoids "user pulled the centre vertex 1mm,
  the mesh is now asymmetric forever". An `actr.local` style
  override is out of scope.
* **Selection set widening.** Mirror counterpart joins the
  selection on click; deselect-by-click also deselects the
  mirror. Selection inversion / "Select Symmetric" full menu
  command is deferred.
* **HTTP API.** Only `tool.pipe.attr symmetry <name> <value>` plus
  the new `vert.symmetrize` command. No `/api/symmetry` endpoint
  yet — `/api/toolpipe` already returns the live packet.

## Open questions

* **Selection-set spine for topology.** The MODO config makes the
  spine a named edge selection set. Vibe3d has no edge selection
  sets yet; introducing them touches `selection.d` more than
  symmetry warrants. Deferred to 7.6g.
* **Mesh topology changes during drag.** A bevel / extrude that
  mutates vertex count mid-tool would invalidate `pairOf[]`. v1
  catches this by re-checking `mutationVersion` at every
  `evaluate()`; if changed mid-drag, rebuild and continue. May
  need a "freeze pairing for the drag duration" option for
  extreme cases.
* **Primitive creation across the plane.** Out of scope for 7.6
  but worth noting: making a Box that straddles X=0 with
  symmetry on should produce symmetric vertices. v1 leaves
  primitives untouched; users can `vert.symmetrize` after
  creation.
* **Falloff × Symmetry interaction.** Does the falloff weight
  evaluate at the *mirrored* position or the *original* position?
  MODO uses the original (so a Linear falloff with start at the
  mirror plane gets symmetric weights for free). Vibe3d will
  match — apply falloff weight to the unmirrored delta first,
  then mirror that already-weighted displacement.

## Sizes

| Subphase                          | Est. LOC |
|-----------------------------------|---------:|
| 7.6a Stage skeleton + toggle      |     180  |
| 7.6b Pairing + Move               |     220  |
| 7.6c Symmetric selection          |     150  |
| 7.6d Rotate / Scale clusters      |     180  |
| 7.6e Visual feedback + UI         |     120  |
| 7.6f vert.symmetrize              |     100  |
| **Total (in-scope v1)**           |   **950**|

Comparable to FalloffStage's final footprint (~950 LOC across
seven subphases). Topology + primitives carry no LOC budget — they
ship in their own follow-up phases.

## Migration safety

Every subphase keeps `./run_all.d --no-build` green at its prior
PASS / XFAIL counts.

* 7.6a: stage exists but `enabled=false` by default → existing
  tests untouched.
* 7.6b–7.6d: new tests live in `tests/test_*.d`; flake-prone
  scenarios get the same treatment as the existing
  `test_toolpipe_axis` — single-worker exclusion only if a real
  race shows up.
* 7.6e: visual-only; covered by manual screenshots in the commit.
* 7.6f: one new test plus an optional `tools/blender_diff` /
  `tools/modo_diff` case with `expected_fail` if MODO's
  `vert.symmetrize` is unreachable headlessly. Mirror suite MAY
  fail to drive `vert.symmetrize` headlessly — guard with
  `expected_fail: true` per the convention in
  `doc/vibe3d_acen_*` plans.

## Where this lands relative to phase7_plan.md

Subphase 7.6 in the master roadmap. The pipeline order after
landing:

```
WORK 0x30 → SYMM 0x31 → SNAP 0x40 → ACEN 0x60 → AXIS 0x70 →
WGHT 0x90 → ACTR 0xF0
```

Still missing after 7.6 (per the master plan): `CONS 0x41`
(constraint-to-surface, phase 7.4), `PATH 0x80` (phase 7.8),
`POST 0xF1` (phase 7.7).
