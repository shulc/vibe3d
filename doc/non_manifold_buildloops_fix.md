# Fix: non-manifold edges break `buildLoops` twin pairing

## Status

Identified, demoted (commit `8b7cc0e`). The crashing `debug assert` was
softened to a one-time stderr warning so debug-build sessions on
imported LWO files don't crash on every double-click — but the
underlying twin-pairing logic still produces incorrect adjacency on
non-manifold inputs.

## Symptom

* Loaded an LWO mesh with one or more edges shared by 3+ faces.
* Vertices mode → double-click → `SelectConnect` walks every cage vert
  via `mesh.verticesAroundVertex(vi)`.
* `VertexNeighborRange.popFront` exceeds `MAX_STEPS = 1024` and trips
  `debug assert(false, …)` (pre-`8b7cc0e`).
* Same hazard for `VertexDartRange` and `VertexEdgeRange`.

## Root cause

`buildLoops` (mesh.d:1438) pairs twin half-edges through a two-slot
table per edge:

```d
int[] edgeLoopA = new int[](edges.length);
int[] edgeLoopB = new int[](edges.length);
edgeLoopA[] = -1;
edgeLoopB[] = -1;
foreach (idx; 0 .. total) {
    uint ei = loopEdge[idx];
    if (ei == ~0u) continue;
    if (edgeLoopA[ei] == -1) edgeLoopA[ei] = cast(int)idx;
    else                     edgeLoopB[ei] = cast(int)idx;
}
```

For a non-manifold edge shared by loops L1, L2, L3:

* `edgeLoopA[ei] = L1` (first seen).
* `edgeLoopB[ei] = L2`, then **overwritten** to `L3` (each new loop
  past the first overwrites B).

Final state: B points at the last loop. The twin writeback then
becomes inconsistent:

* L1.twin = L3   (idx == A, so twin = B = L3)
* L2.twin = L1   (idx != A, idx != B, so twin = A = L1)
* L3.twin = L1   (idx != A, idx == B, so twin = A = L1)

L2 and L3 both think L1 is their twin; L1 only points at L3. The
per-vertex ring walk traces an open chain rather than closing back
to the starting dart, so MAX_STEPS triggers.

## Proposed fix

Detect non-manifold edges during the slot-fill pass and treat them
as boundaries (leave all their loops' `twin = ~0u`). The walk then
hits the boundary fall-through in `popFront`:

```d
if (twinPrev == ~0u) { _atExtra = true; return; }
```

and terminates cleanly via the extra-dart branch.

### Sketch

```d
// One extra pass to count loops per edge, or use a third sentinel
// during the existing fill loop:
int[] edgeLoopA = new int[](edges.length);
int[] edgeLoopB = new int[](edges.length);
bool[] edgeNonManifold = new bool[](edges.length);
edgeLoopA[] = -1;
edgeLoopB[] = -1;
foreach (idx; 0 .. total) {
    uint ei = loopEdge[idx];
    if (ei == ~0u) continue;
    if (edgeNonManifold[ei]) continue;
    if (edgeLoopA[ei] == -1)      edgeLoopA[ei] = cast(int)idx;
    else if (edgeLoopB[ei] == -1) edgeLoopB[ei] = cast(int)idx;
    else {
        edgeNonManifold[ei] = true;
        edgeLoopA[ei]       = -1;   // force boundary for ALL loops on this edge
        edgeLoopB[ei]       = -1;
    }
}
```

Twin writeback already short-circuits when `A == -1 || B == -1`, so
non-manifold edges naturally fall through to boundary behaviour.

## Side effects to verify

* `select.connect`, `select.loop`, bevel, edge-loop walks must
  terminate correctly (the symptom we fixed).
* Visible boundaries: `drawEdges` highlights boundary edges
  separately if vibe3d does that — check whether non-manifold edges
  get the boundary treatment visually. If they should NOT (LWO users
  expect to see them as interior), keep a separate `bool[]
  edgeNonManifold` mask and treat them as "interior with no twin"
  rather than as boundary.
* `gpu.upload` filters: not affected (uploads geometry positions, not
  twin pointers).

## Test case

* Construct a minimal non-manifold mesh in-source via `addFace`:
  three triangles sharing one edge (a "book" with three pages).
* Walk vert 0 (on the shared edge) via `verticesAroundVertex`.
* Pre-fix: hits MAX_STEPS or stops on the second neighbour without
  finishing.
* Post-fix: emits all 4 neighbouring verts via the boundary path,
  then terminates cleanly.

## When to do this

Whenever LWO import / bevel-on-imported-mesh / select-loop
correctness becomes a stronger priority than the OSD migration
follow-ups. Likely candidate for the same pass that hardens the
SubpatchTrace consumers against partially-non-manifold cages
(currently they assume manifold; trace.edgeOrigin == uint.max for a
limit edge whose cage edge is non-manifold should be fine, but worth
verifying).
