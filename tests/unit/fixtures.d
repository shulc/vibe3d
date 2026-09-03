// Shared fixtures for module unittests (task 0706).
//
// One copy of the small mesh helpers that every extracted test block used to
// carry inline. Only put something here once it is used by more than one test
// module and its contract is written down -- a fixture layer that accumulates
// one-off helpers is just a second god-file.
module tests.unit.fixtures;

import mesh;
import math;

/// Index in `m.edges[]` of the edge joining `a` and `b`, or **-1** when there
/// is none. Vertex order does not matter.
///
/// WHY THIS IS NOT `Mesh.edgeIndex`. `Mesh` already answers this question, and
/// answers it in O(1): `edgeIndex(a, b)` looks `a`/`b` up in `edgeIndexMap`.
/// The 36 inline copies this function replaces all chose the O(E) scan
/// instead, and merging them onto the fast one would be a behaviour change in
/// two separate ways:
///
///  1. **Different sentinel, and the difference is silent.** `edgeIndex`
///     returns `uint` and reports "no such edge" as `~0u`. Every one of the
///     copies returns `int` and tests the result with `>= 0` -- which is
///     vacuously true for a `uint`, so a mechanical swap would turn "not
///     found" into "found edge 4294967295" and index out of bounds one line
///     later, in a test whose whole job is to notice that kind of thing.
///  2. **Different precondition.** `edgeIndexMap` is derived state carrying an
///     explicit `Stale` / `Valid` / `DeliberatelyEmpty` status stamped against
///     `structVersion`; `Mesh` even ships `assertEdgeMapValid()` for readers
///     that must be settled. `edgeIndex` reads the map unguarded, so on a mesh
///     whose topology a kernel has just rewritten it can answer from stale
///     data. A scan over `m.edges[]` has no such precondition, and asserting
///     on a freshly mutated mesh is exactly what these tests do.
///
/// So the scan is kept deliberately. It is a fixture, not a hot path: O(E) on
/// meshes with tens of edges is free, and being independent of derived state
/// is the property that makes it safe to call anywhere in a test.
int findEdge(ref Mesh m, uint a, uint b)
{
    foreach (i; 0 .. m.edges.length)
    {
        uint x = m.edges[i][0], y = m.edges[i][1];
        if ((x == a && y == b) || (x == b && y == a)) return cast(int) i;
    }
    return -1;
}

/// Triangle-fan disk: a hub vertex at the origin plus `n` rim vertices on the
/// unit circle in the z=0 plane, joined by `n` triangles wound hub-first.
/// Vertex 0 is the hub; rim vertex `i` is index `1 + i`.
///
/// Loops and selection are built before returning, so the result is a settled
/// mesh a kernel can be pointed at directly.
Mesh makeDisk(int n)
{
    import std.math : cos, sin, PI;

    Mesh m;
    m.vertices ~= Vec3(0, 0, 0);
    foreach (i; 0 .. n)
    {
        immutable float a = 2.0f * PI * i / n;
        m.vertices ~= Vec3(cos(a), sin(a), 0);
    }
    foreach (i; 0 .. n)
        m.addFace([0u, cast(uint)(1 + i), cast(uint)(1 + (i + 1) % n)]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

// ---------------------------------------------------------------------------
// The fixtures' own contracts. These are what the 36 + 13 inline copies agreed
// on; pinning them here is what makes replacing the copies a refactor rather
// than a rewrite.
// ---------------------------------------------------------------------------

unittest // findEdge: symmetric in its arguments, and -1 (not ~0u) when absent
{
    auto m = makeCube();

    int ei = findEdge(m, 6, 7);
    assert(ei >= 0, "cube edge (6,7) must exist");
    assert(findEdge(m, 7, 6) == ei, "findEdge must not care about vertex order");

    uint x = m.edges[ei][0], y = m.edges[ei][1];
    assert((x == 6 && y == 7) || (x == 7 && y == 6),
           "findEdge must return the index of the edge it was asked for");

    // The sentinel is the whole reason this is not Mesh.edgeIndex: it must be
    // negative, so the `>= 0` test every caller writes actually discriminates.
    int missing = findEdge(m, 0, 6);   // a cube face diagonal — not an edge
    assert(missing == -1, "absent edge must report -1");
    assert(missing < 0, "the sentinel must fail a `>= 0` test");
    assert(m.edgeIndex(0, 6) == ~0u,
           "Mesh.edgeIndex reports absence as ~0u — which PASSES `>= 0`, "
           ~ "which is why these two are not interchangeable");
}

// ---------------------------------------------------------------------------
// makeTaggedGrid (task 1902) — every per-face/per-vertex PLANE non-uniform,
// on an OPEN mesh, for `mesh_planes.d`'s three-layer enumeration guard.
// ---------------------------------------------------------------------------

/// A small OPEN grid mesh with every per-face/per-vertex plane
/// `mesh_planes.d`'s primitive carries populated to a DISTINCT, non-uniform
/// value — the property that actually discriminates a carry failure (on a
/// one-material closed solid, "carried" and "zero-filled" read the same
/// array; CLAUDE.md's standing warning against testing facing-adjacent logic
/// on a cube is the same principle applied to a different plane). Built on
/// `Mesh.makeGridPlane(3)`: 9 quad faces in row-major order
/// (`fi = i*3 + j`, `i,j` in `0 .. 3`), 16 vertices, open (boundary) mesh —
/// which also exercises the orphan/boundary branch a closed solid never
/// reaches.
///
/// Populates, in order: `faceMaterial` (alternating 0/1), `facePart` (three
/// distinct values, 0/2/5), `faceSetMask` (a polygon set on ONE middle
/// face), `faceMarks` (one face Subpatch, a DIFFERENT face Hidden, a THIRD
/// face Selected), `faceSelectionOrder` (a non-zero stamp on two more
/// faces), a PolyVertex UV map (one distinct value per corner — the
/// genuinely hard plane, carried by the corner protocol rather than by
/// `kFacePlanes`, but populated here so a migrated kernel can be checked
/// against it too), and `vertexSetMask` (a vertex set, for the
/// `rewriteVertices` half).
Mesh makeTaggedGrid()
{
    import mesh_selsets : selSetEditPolygon, selSetEditVertex, SetEditMode;

    Mesh m = makeGridPlane(3);
    m.resetSelection();   // size every per-face/per-vertex plane to match

    // faceMaterial: alternating 0 / 1.
    foreach (fi; 0 .. m.faces.length)
        m.faceMaterial[fi] = cast(uint)(fi % 2);

    // facePart: three distinct values, cycling 0 / 2 / 5.
    static immutable uint[3] partCycle = [0, 2, 5];
    foreach (fi; 0 .. m.faces.length)
        m.facePart[fi] = partCycle[fi % 3];

    // faceSetMask: a polygon set on ONE middle face (the 3×3 grid's centre,
    // index 4 in row-major order) — deliberately not face 0 or the last
    // face, so a front- or tail-truncating carry bug would still show it.
    bool[] polySel = new bool[](m.faces.length);
    polySel[4] = true;
    selSetEditPolygon(m, "S", SetEditMode.replace, polySel);

    // faceMarks: one Subpatch face, a DIFFERENT Hidden face, a THIRD
    // Selected face — three distinct faces so the three bits are
    // independently observable (a single face carrying all three would not
    // tell a dropped bit from a bit that was never distinct in the first
    // place).
    m.setSubpatch(1, true);
    m.setFaceHidden(5, true);
    m.selectFace(7);

    // faceSelectionOrder: a non-zero stamp on two MORE faces, independent of
    // whichever face `selectFace` above already stamped (face 7) — direct
    // writes, since this plane's only setter is bundled with Marks.Select.
    m.faceSelectionOrder[2] = 11;
    m.faceSelectionOrder[6] = 23;

    // A PolyVertex (per-corner) UV map with a distinct value per corner —
    // NOT one of kFacePlanes (it rides the corner-provenance protocol
    // instead, see memory `percorner_map_carry`), but populated here so a
    // migrated kernel's corner carry can be checked against the same
    // fixture.
    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null, "fixture: UV map registration must succeed");
    foreach (i; 0 .. uv.data.length)
        uv.data[i] = cast(float) i;

    // vertexSetMask: a vertex set, for the rewriteVertices half.
    bool[] vertSel = new bool[](m.vertices.length);
    vertSel[0] = true;
    vertSel[5] = true;
    selSetEditVertex(m, "V", SetEditMode.replace, vertSel);

    return m;
}

unittest // makeTaggedGrid: shape + every plane distinct/non-uniform, as advertised
{
    auto m = makeTaggedGrid();
    assert(m.faces.length == 9,     "3x3 grid: 9 quad faces");
    assert(m.vertices.length == 16, "3x3 grid: 16 vertices");

    // Open mesh: at least one edge borders exactly one face (a boundary
    // edge) — the property the fixture doc comment claims. `edgePolygonCounts`
    // counts straight off `faces[]` (see its own doc comment on why this is
    // the truthful counter, not the `facesAroundEdge` ring walk).
    bool sawBoundary = false;
    foreach (c; m.edgePolygonCounts())
        if (c == 1) { sawBoundary = true; break; }
    assert(sawBoundary, "makeTaggedGrid must be OPEN (have a boundary edge)");

    // faceMaterial: not uniform.
    bool matVaries = false;
    foreach (fi; 1 .. m.faces.length)
        if (m.faceMaterial[fi] != m.faceMaterial[0]) { matVaries = true; break; }
    assert(matVaries, "faceMaterial must not be uniform");

    // facePart: at least three distinct values.
    bool[uint] parts;
    foreach (fi; 0 .. m.faces.length) parts[m.facePart[fi]] = true;
    assert(parts.length >= 3, "facePart must carry at least 3 distinct values");

    // faceSetMask: exactly face 4 carries the set bit.
    foreach (fi; 0 .. m.faces.length)
        assert(((m.faceSetMask[fi] & 1UL) != 0) == (fi == 4),
               "faceSetMask: exactly the middle face (4) must be a member");

    // faceMarks: subpatch/hide/select land on three DIFFERENT faces.
    assert(m.isFaceSubpatch(1) && !m.isFaceSubpatch(5) && !m.isFaceSubpatch(7));
    assert(m.isFaceHidden(5)   && !m.isFaceHidden(1)   && !m.isFaceHidden(7));
    assert(m.isFaceSelected(7) && !m.isFaceSelected(1) && !m.isFaceSelected(5));

    // faceSelectionOrder: non-zero on (at least) the two stamped faces.
    assert(m.faceSelectionOrder[2] != 0 && m.faceSelectionOrder[6] != 0);

    // The UV map: registered, PolyVertex-domain, per-corner distinct.
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null, "UV map must be registered");
    assert(uv.domain == MapDomain.PolyVertex);
    assert(uv.data.length == m.cornerCount() * 2,
           "UV map must be sized to loops.length * dim");
    bool uvVaries = false;
    foreach (i; 1 .. uv.data.length)
        if (uv.data[i] != uv.data[0]) { uvVaries = true; break; }
    assert(uvVaries, "the UV map must not be uniform");

    // vertexSetMask: exactly vertices 0 and 5 carry the set bit.
    foreach (vi; 0 .. m.vertices.length)
        assert(((m.vertexSetMask[vi] & 1UL) != 0) == (vi == 0 || vi == 5),
               "vertexSetMask: exactly vertices 0 and 5 must be members");
}

// ---------------------------------------------------------------------------
// makeTaggedGridFull (task 1903 Stage B) — `makeTaggedGrid` plus the four
// planes it is missing, and PARAMETERISED by grid size.
// ---------------------------------------------------------------------------

/// The stand for task 1903's parity fixtures (plan §6.3) and for its O(Δ)
/// measurement (plan §8.1): an OPEN `n`x`n` grid with **every** plane the
/// burn-in class covers non-empty and non-uniform.
///
/// WHY A SIBLING AND NOT AN EXTENSION OF `makeTaggedGrid`. Task 1902's L3
/// behavioural oracle (`tests/unit/mesh_planes_test.d`) reads `makeTaggedGrid`
/// by name, and changing what that fixture CONTAINS changes what that gate
/// OBSERVES. So `makeTaggedGrid` is untouched and this is a second, larger
/// stand. The price is a second copy of the shared tagging, and the guard
/// against the two drifting apart is executable: the superset unittest below
/// asserts that at `n == 3` this fixture agrees with `makeTaggedGrid()` on
/// every plane that one populates.
///
/// THE FOUR ADDITIONS over `makeTaggedGrid`, each with why it matters:
///
///  1. **`edgeSetMask`** — the `ulong[ulong]` odd one out. Its re-key across a
///     topology edit is the CALLER's obligation
///     (`mesh_selsets.selSetRekeyEdges`), which is exactly why it is the plane
///     most likely to be forgotten by a migrated kernel, and why a fixture
///     without it cannot notice.
///  2. **A Point-domain map** — `makeTaggedGrid` carries only a PolyVertex
///     (per-corner) UV map, which rides the corner-provenance protocol. A
///     weight/morph-shaped Point map rides the per-VERTEX path instead, and the
///     two are carried by different code.
///  3. **Non-zero `vertexSelectionOrderCounter` / `edgeSelectionOrderCounter`**
///     — `selectFace` moves only the FACE counter, so on `makeTaggedGrid` the
///     other two counters are 0 and a delta that drops them reads identical.
///  4. **Two `surfaces` and an edge selection** — `faceMaterial` alternates
///     0/1, so without a second surface the material plane indexes a registry
///     of one; and `edgeMarks` is the plane whose INDEX SPACE a delta replay
///     rebuilds (plan §6.3), so it has to carry something.
///
/// `n` defaults to 3 so the §6.3 parity captures read `makeTaggedGridFull()`;
/// the §8 cells pass 316 (99 856 faces) and 100 (10 000 faces). `n` must be at
/// least 3 — the tagging names faces up to index 7 and vertices up to 5.
Mesh makeTaggedGridFull(int n = 3)
{
    import mesh_selsets : selSetEditPolygon, selSetEditVertex, selSetEditEdge,
                          SetEditMode;

    assert(n >= 3, "makeTaggedGridFull: the tagging names face 7, so n >= 3");

    Mesh m = makeGridPlane(n);
    m.resetSelection();   // size every per-element plane to match

    // ---- the `makeTaggedGrid` tagging, verbatim in effect ------------------
    foreach (fi; 0 .. m.faces.length)
        m.faceMaterial[fi] = cast(uint)(fi % 2);

    static immutable uint[3] partCycle = [0, 2, 5];
    foreach (fi; 0 .. m.faces.length)
        m.facePart[fi] = partCycle[fi % 3];

    bool[] polySel = new bool[](m.faces.length);
    polySel[4] = true;
    selSetEditPolygon(m, "S", SetEditMode.replace, polySel);

    m.setSubpatch(1, true);
    m.setFaceHidden(5, true);
    m.selectFace(7);

    m.faceSelectionOrder[2] = 11;
    m.faceSelectionOrder[6] = 23;

    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null, "fixture: UV map registration must succeed");
    foreach (i; 0 .. uv.data.length)
        uv.data[i] = cast(float) i;

    bool[] vertSel = new bool[](m.vertices.length);
    vertSel[0] = true;
    vertSel[5] = true;
    selSetEditVertex(m, "V", SetEditMode.replace, vertSel);

    // ---- addition 4a: a second surface, so `faceMaterial`'s 0/1 indexes a
    // registry with two entries rather than one and a padded default.
    m.surfaces ~= Surface("GridA", Vec3(0.8f, 0.2f, 0.2f));
    m.surfaces ~= Surface("GridB", Vec3(0.2f, 0.4f, 0.9f));

    // ---- addition 2: a Point-domain map, one distinct value per VERTEX.
    auto wm = m.addMeshMap("W", 1, MapDomain.Point);
    assert(wm !is null, "fixture: Point-domain map registration must succeed");
    foreach (i; 0 .. wm.data.length)
        wm.data[i] = 0.5f + cast(float) i;

    // ---- additions 3 + 4b: a vertex selection and an EDGE selection, which
    // are also what move the two selection-order counters `selectFace` leaves
    // at zero. Two vertices and two edges, so neither plane is a single bit.
    m.selectVertex(2);
    m.selectVertex(9);
    m.selectEdge(0);
    m.selectEdge(3);

    // ---- addition 1: an edge selection SET — the ulong[ulong] plane.
    bool[] edgeSel = new bool[](m.edges.length);
    edgeSel[1] = true;
    edgeSel[4] = true;
    selSetEditEdge(m, "E", SetEditMode.replace, edgeSel);

    return m;
}

unittest // makeTaggedGridFull: the four additions are present and non-uniform
{
    auto m = makeTaggedGridFull();

    assert(m.faces.length == 9,     "3x3 grid: 9 quad faces");
    assert(m.vertices.length == 16, "3x3 grid: 16 vertices");

    bool sawBoundary = false;
    foreach (c; m.edgePolygonCounts())
        if (c == 1) { sawBoundary = true; break; }
    assert(sawBoundary, "makeTaggedGridFull must be OPEN (have a boundary edge)");

    // 1. edgeSetMask — the plane a delta's caller must re-key by hand. This is
    // the message the M-F mutation (build the stand on makeCube()) reddens with.
    assert(m.edgeSetMask.length > 0,
           "makeTaggedGridFull: edgeSetMask must be non-empty");
    assert(m.edgeSetNames.length >= 1, "an edge set needs a name registry entry");

    // 2. A Point-domain map, distinct per vertex, ALONGSIDE the PolyVertex one.
    auto wm = m.meshMap("W");
    assert(wm !is null, "the Point-domain map must be registered");
    assert(wm.domain == MapDomain.Point, "map W must be Point-domain");
    assert(wm.data.length == m.vertices.length * wm.dim,
           "a Point map is sized to vertices.length * dim");
    bool wVaries = false;
    foreach (i; 1 .. wm.data.length)
        if (wm.data[i] != wm.data[0]) { wVaries = true; break; }
    assert(wVaries, "the Point-domain map must not be uniform");
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null && uv.domain == MapDomain.PolyVertex,
           "the PolyVertex map must survive alongside the Point one");

    // 3. All THREE selection-order counters are non-zero. `selectFace` alone
    // moves one of them, which is the gap this addition closes.
    assert(m.faceSelectionOrderCounter   != 0, "face order counter");
    assert(m.vertexSelectionOrderCounter != 0, "vertex order counter");
    assert(m.edgeSelectionOrderCounter   != 0, "edge order counter");

    // 4. Two surfaces, and an edge selection with a non-uniform edgeMarks.
    assert(m.surfaces.length >= 2,
           "faceMaterial alternates 0/1 — it needs two surfaces to index");
    size_t selEdges = 0;
    foreach (ei; 0 .. m.edges.length) if (m.isEdgeSelected(ei)) ++selEdges;
    assert(selEdges >= 2, "at least two edges must be selected");
    assert(selEdges < m.edges.length, "…and not all of them, or the plane is uniform");
}

unittest // makeTaggedGridFull(3) is a SUPERSET of makeTaggedGrid() — no drift
{
    // The guard on the deliberate second copy. `makeTaggedGridFull` is
    // documented as "makeTaggedGrid plus four", and this is what makes that
    // sentence executable rather than a comment that rots: every plane
    // `makeTaggedGrid` populates must read identically here.
    auto a = makeTaggedGrid();
    auto b = makeTaggedGridFull(3);

    assert(a.vertices.length == b.vertices.length, "same vertex count");
    assert(a.faces.length    == b.faces.length,    "same face count");
    import std.conv : to;
    foreach (fi; 0 .. a.faces.length)
        assert(a.faces[fi] == b.faces[fi], "winding differs at face " ~ fi.to!string);

    assert(a.faceMaterial       == b.faceMaterial,       "faceMaterial drifted");
    assert(a.facePart           == b.facePart,           "facePart drifted");
    assert(a.faceSetMask        == b.faceSetMask,        "faceSetMask drifted");
    assert(a.faceMarks          == b.faceMarks,          "faceMarks drifted");
    assert(a.faceSelectionOrder == b.faceSelectionOrder, "faceSelectionOrder drifted");
    assert(a.vertexSetMask      == b.vertexSetMask,      "vertexSetMask drifted");

    auto uvA = a.meshMap(kUvMapName);
    auto uvB = b.meshMap(kUvMapName);
    assert(uvA !is null && uvB !is null, "both carry the UV map");
    assert(uvA.data == uvB.data, "the UV map drifted");

    // …and the four additions are exactly what makeTaggedGrid does NOT have,
    // so the word "superset" is proper rather than "identical".
    assert(a.edgeSetMask.length == 0 && b.edgeSetMask.length > 0);
    assert(a.meshMap("W") is null && b.meshMap("W") !is null);
    assert(a.edgeSelectionOrderCounter == 0 && b.edgeSelectionOrderCounter != 0);
    assert(a.surfaces.length < 2 && b.surfaces.length >= 2);
}

unittest // makeTaggedGridFull scales, and the tagging survives the scaling
{
    // The §8 cells build 316x316 and 100x100 stands; this is the cheap proof
    // that `n` reaches the planes rather than only the geometry.
    auto m = makeTaggedGridFull(6);
    assert(m.faces.length == 36,    "6x6 grid: 36 faces");
    assert(m.vertices.length == 49, "6x6 grid: 49 vertices");
    assert(m.edgeSetMask.length > 0, "the edge set scales with the grid");
    auto wm = m.meshMap("W");
    assert(wm !is null && wm.data.length == m.vertices.length,
           "the Point map is re-sized to the larger vertex array");
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null && uv.data.length == m.cornerCount() * 2,
           "the corner map is re-sized to the larger corner count");
}

// ---------------------------------------------------------------------------
// makeTaggedGridDirty (task 1903 Stage L5) — `makeTaggedGridFull` plus the
// dirt without which `mesh.cleanup` REFUSES.
// ---------------------------------------------------------------------------

/// The stand for stage L5's parity fixture
/// (`tests/fixtures/undo_parity/cleanup.json`) and for its witnesses.
///
/// WHY A FIFTH STAND AND NOT AN EDIT OF `makeTaggedGridFull`. The same
/// argument `makeTaggedGridBent` makes one line down: `makeTaggedGridFull` is
/// the stand of L0's and L3's frozen parity fixtures and of §8's O(Δ) cells,
/// and changing what it CONTAINS changes what those gates OBSERVE. This is a
/// fifth stand, and the superset unittest below is the guard against the two
/// drifting apart.
///
/// WHY IT HAS TO EXIST AT ALL, and it is measured rather than inherited. The
/// perf lane records `CmdExclusion("mesh.cleanup", "refuses: nothing
/// degenerate to clean on a fresh grid")` (`tools/perf/run.d`, 2026-08-19) —
/// a statement about the stand THAT lane used. Re-measured here on
/// `makeTaggedGridFull(3)` (2026-08-28): `cleanupMesh()` returns
/// `welded=0 degenerate=0 unified=0 orphans=0 dissolved=0 finalOrphans=0`,
/// so `anyAffected()` is FALSE, `MeshCleanup.evaluate` returns false and
/// every cell of an L5 fixture built on it would freeze a pair of identical
/// dumps. A cube is worse, not better, for two reasons rather than one: the
/// exclusion above was measured on a GRID and a cube is not less clean; and
/// on a closed solid the weld's face-DROP arm (a face falling below three
/// distinct corners) is unreachable without breaking the solid.
///
/// THE FOUR INJECTIONS, each traceable to the stage it must make fire, with
/// the measured per-stage counts they produce under a DEFAULT sweep
/// (`welded=1 degenerate=1 unified=1`, `V 19 -> 16`, `F 12 -> 10`):
///
///  1. **A coincident vertex** (`v16`, a bit-identical copy of `v1`) — the
///     WELD's operand, and the one injection Stage L5-a exists for. It is
///     referenced by TWO new faces rather than one, which is a deliberate
///     strengthening of the plan's shape: `f9` is DROPPED by the unify stage,
///     so a stand where the coincident vertex appears only there could observe
///     the weld's winding rewrite only through a RESTORED face. `f10` survives
///     the whole sweep with its winding rewritten `[16,4,8,9] -> [1,4,8,9]`,
///     which is the sharper channel.
///  2. **A zero-area face** (`f11 = [0, 1, v17]`, three collinear points —
///     `v0`, `v1` and `v17` all sit on `z == -1, y == 0`) — `cleanDegenerateFaces`'
///     operand. `v17` is referenced by NOTHING ELSE, so dropping the face
///     orphans it.
///  3. **A face that only becomes a duplicate once the weld lands**
///     (`f9 = [0, v16, 5, 4]`, which the weld rewrites to `[0, 1, 5, 4]` ==
///     face 0) — `unifyFaces`' operand, and the `RemoveFaces` half of the
///     mixed batch.
///  4. **A floating orphan vertex** (`v18`, referenced by no face) — so the
///     compaction has something to do.
///
/// THE FOURTH STAGE IS NOT ASSERTED BY ITS `CleanupResult` COUNT, and that is
/// a correction to the plan rather than a shortcut. `r.orphans` and
/// `r.finalOrphans` both read **0** on this stand — measured — because
/// `cleanDegenerateFaces` runs its own `compactUnreferenced` internally and
/// there is nothing left by the time the explicit orphan stages run. An
/// assertion of `orphans >= 1` would therefore REDDEN ON CORRECT CODE, which
/// is the vacuity disease from the other side. The compaction is asserted
/// where it is OBSERVABLE instead: exactly one `RemoveVerts` entry in the
/// op-log, and a drop in the vertex count across it (see
/// `tests/unit/undo_parity_l5_test.d`).
///
/// FOUR MORE THINGS THE INJECTIONS CARRY, none of them geometry, each named
/// because a plane the stand does not populate is a plane the fixture cannot
/// notice:
///
///  * `v16` and `v18` JOIN the vertex selection set `"V"`, so the sweep welds
///    one set member away and compacts another — without which stage L5-b's
///    `vertSetMaskBefore` payload has nothing to restore and its cells are
///    vacuous.
///  * BOTH new edges of the degenerate face (`(0,v17)` and `(1,v17)`) join the
///    edge selection set `"E"`, so the sweep drops two `edgeSetMask` entries
///    whose ENDPOINT disappears — the other half of that payload.
///  * `f9` is SELECTED and is dropped; face 7 (the base stand's selection) is
///    selected and survives. "Restored the selection" and "restored
///    everything" are then different pictures.
///  * Both maps are re-filled with distinct values ACROSS the appended
///    elements. `appendFaceRaw` zero-fills the appended corners and
///    `resizeVertexSelection` zero-fills the appended Point-map entries, so
///    without the re-fill the new corners all read 0.0 and a per-corner value
///    restored onto the WRONG corner would compare EQUAL.
Mesh makeTaggedGridDirty(int n = 3)
{
    import mesh_selsets : selSetEditVertex, selSetEditEdge, SetEditMode;

    Mesh m = makeTaggedGridFull(n);

    // ---- the three appended vertices ---------------------------------------
    // `p1` is read into a local first: `m.vertices ~= m.vertices[1]` reads an
    // element of the array it is appending to, which is safe today but is the
    // shape a reallocation makes a reader stop and think about.
    immutable Vec3 p1 = m.vertices[1];
    immutable uint vCoin = cast(uint) m.vertices.length;
    m.vertices ~= p1;                            // injection 1
    immutable uint vCol  = cast(uint) m.vertices.length;
    m.vertices ~= Vec3(3.0f, 0.0f, -1.0f);       // injection 2's third corner
    immutable uint vOrph = cast(uint) m.vertices.length;
    m.vertices ~= Vec3(0.0f, 5.0f, 0.0f);        // injection 4
    // Grows vertexMarks / vertexSelectionOrder / every Point-domain map /
    // vertexSetMask in one call — the primitive the topology mutators use, so
    // the stand cannot drift from what a real growth does.
    m.resizeVertexSelection();

    // ---- the three appended faces ------------------------------------------
    // `appendFaceRaw`, not a bare `faces ~=`: it grows every PolyVertex map by
    // the appended corners, which a bare append does not (task 0690 — "wipes
    // the UV of every face it never touched").
    immutable uint fDup  = cast(uint) m.faces.length;
    m.appendFaceRaw([0u, vCoin, 5u, 4u]);        // injection 3
    immutable uint fLive = cast(uint) m.faces.length;
    m.appendFaceRaw([vCoin, 4u, 8u, 9u]);        // injection 1's surviving face
    immutable uint fDeg  = cast(uint) m.faces.length;
    m.appendFaceRaw([0u, 1u, vCol]);             // injection 2

    m.rebuildEdgesFromFaces();
    m.buildLoops();
    // GROW, never `resetSelection()`: the base stand's whole tagging —
    // selection, order stamps, subpatch and hide bits, materials, parts, set
    // masks — is exactly what makes this a superset, and `resetSelection`
    // clears the three selections.
    m.syncSelection();

    // The per-face planes stay non-uniform across the appended faces too.
    m.faceMaterial[fDup] = 1; m.faceMaterial[fLive] = 0; m.faceMaterial[fDeg] = 1;
    m.facePart[fDup]     = 2; m.facePart[fLive]     = 5; m.facePart[fDeg]     = 0;
    // A SELECTED face that the sweep DROPS (face 7, selected by the base
    // stand, is the one that survives).
    m.selectFace(cast(int) fDup);

    // Set membership on the two vertices the sweep removes.
    bool[] vs = new bool[](m.vertices.length);
    vs[vCoin] = true;
    vs[vOrph] = true;
    selSetEditVertex(m, "V", SetEditMode.add, vs);

    // …and on both edges whose endpoint the sweep removes.
    bool[] es = new bool[](m.edges.length);
    immutable uint e0c = m.edgeIndex(0, vCol);
    immutable uint e1c = m.edgeIndex(1, vCol);
    assert(e0c != ~0u && e1c != ~0u,
           "makeTaggedGridDirty: the degenerate face's two new edges are not "
         ~ "in the rebuilt edge array — the edge-set half of the L5-b payload "
         ~ "would then have nothing to drop");
    es[e0c] = true;
    es[e1c] = true;
    selSetEditEdge(m, "E", SetEditMode.add, es);

    // Re-fill BOTH maps across their grown length, so no two elements share a
    // value. Same sequences `makeTaggedGridFull` uses, extended.
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null, "makeTaggedGridDirty: the base stand's UV map vanished");
    foreach (i; 0 .. uv.data.length) uv.data[i] = cast(float) i;
    auto wm = m.meshMap("W");
    assert(wm !is null, "makeTaggedGridDirty: the base stand's Point map vanished");
    foreach (i; 0 .. wm.data.length) wm.data[i] = 0.5f + cast(float) i;

    return m;
}

unittest // makeTaggedGridDirty: all four injections FIRE, and the fourth by its consequence
{
    import std.format : format;
    import mesh_ops.cleanup : cleanupMesh;
    import mesh_edit_delta  : MeshEditDelta, MeshOpEntry;

    auto m = makeTaggedGridDirty(3);
    assert(m.vertices.length == 19 && m.faces.length == 12,
        format("the stand is V=%d F=%d, expected V=19 F=12 — every index "
             ~ "constant in the L5 reader names a face or a vertex at random "
             ~ "otherwise", m.vertices.length, m.faces.length));

    // ---- 1/2/3 BY COUNT. MUTATION: build this on `makeTaggedGridFull(3)` —
    // all three read 0 and `anyAffected()` is false, i.e. `mesh.cleanup`
    // REFUSES, so every cell of the L5 fixture would freeze a pair of
    // identical dumps.
    immutable size_t preV = m.vertices.length;
    MeshEditDelta d;
    CleanupResult r;
    {
        auto ed = MeshEditBatch(m, kCleanupEditScope);   // RECORDING
        r = cleanupMesh(ed);
        d = ed.close();
    }
    assert(r.welded == 1 && r.degenerate == 1 && r.unified == 1,
        format("the sweep reported welded=%d degenerate=%d unified=%d, "
             ~ "expected 1/1/1 — this stand exists to make all three fire in "
             ~ "one call", r.welded, r.degenerate, r.unified));

    // ---- 4 BY ITS OBSERVABLE CONSEQUENCE, never by `r.orphans`. Both orphan
    // counters read 0 here as a MEASURED fact and not as slack: the earlier
    // stages compact internally. Asserting `orphans >= 1` would redden on
    // correct code — which is what the plan's own first draft of this stand
    // demanded, and why it is written out here.
    assert(r.orphans == 0 && r.finalOrphans == 0,
        format("the sweep reported orphans=%d finalOrphans=%d, expected 0/0 — "
             ~ "if these are non-zero the earlier stages stopped compacting "
             ~ "internally and the op-log below carries more than one "
             ~ "RemoveVerts", r.orphans, r.finalOrphans));
    size_t nRemoveVerts = 0;
    foreach (ref e; d.log)
        if (e.kind == MeshOpEntry.Kind.RemoveVerts) ++nRemoveVerts;
    assert(nRemoveVerts == 1,
        format("the sweep's op-log carries %d RemoveVerts entr(ies), expected "
             ~ "exactly 1 — this is where injection 4 is observable, since the "
             ~ "CleanupResult counters cannot see it", nRemoveVerts));
    assert(m.vertices.length < preV,
        format("the sweep left %d vertices of %d — nothing was compacted away, "
             ~ "so the RemoveVerts entry above describes an empty drop",
               m.vertices.length, preV));
}

unittest // makeTaggedGridDirty carries the four NON-geometry things its cells read
{
    import std.format : format;
    auto m = makeTaggedGridDirty(3);

    // ---- set membership on vertices the sweep removes (L5-b's vertex half).
    import mesh_selsets : selSetMembersVertex, selSetMembersEdge;
    auto vm = selSetMembersVertex(m, "V");
    assert(vm == [0u, 5u, 16u, 18u],
        format("vertex set \"V\" is %s, expected [0, 5, 16, 18] — 16 is the "
             ~ "coincident vertex the weld removes and 18 the floating orphan "
             ~ "the compaction removes. Without a MEMBER among the removed, "
             ~ "the `vertSetMaskBefore` payload has nothing to restore", vm));

    // ---- an edge-set entry on BOTH edges whose endpoint disappears.
    auto em = selSetMembersEdge(m, "E");
    bool sawColl = false;
    foreach (pr; em) if (pr[0] == 17u || pr[1] == 17u) sawColl = true;
    assert(sawColl,
        format("edge set \"E\" is %s and names no edge with endpoint 17 — that "
             ~ "vertex is the one the degenerate drop orphans, so without it "
             ~ "`selSetRekeyEdges` drops nothing and L5-b's EDGE half is "
             ~ "unreachable", em));

    // ---- a selected face that is DROPPED and one that SURVIVES.
    assert(m.isFaceSelected(7) && m.isFaceSelected(9),
        "the stand must select face 7 (interior, survives the sweep) AND face "
      ~ "9 (the duplicate the unify stage drops) — one alone makes 'restored "
      ~ "the selection' and 'restored everything' the same picture");
    assert(m.faceSelectionOrder[2] != 0 && m.faceSelectionOrder[6] != 0,
        "faceSelectionOrder is flat outside the selected faces — a revert that "
      ~ "drops the order plane would read identical");

    // ---- distinct per-corner and per-vertex values, ACROSS the appended tail.
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null && uv.domain == MapDomain.PolyVertex);
    assert(uv.data.length == m.cornerCount() * uv.dim,
        "the UV map is out of step with the appended corners");
    bool[float] seenU;
    foreach (k; 0 .. uv.data.length / uv.dim) {
        immutable float u = uv.data[k * uv.dim];
        assert((u in seenU) is null,
            format("uv corner %d repeats the value %s — a value restored onto "
                 ~ "the wrong corner would compare EQUAL, and the appended "
                 ~ "corners are exactly the ones `appendFaceRaw` zero-fills",
                   k, u));
        seenU[u] = true;
    }
    auto wm = m.meshMap("W");
    assert(wm !is null && wm.data.length == m.vertices.length,
        "the Point map is out of step with the appended vertices");
    bool[float] seenW;
    foreach (i; 0 .. wm.data.length) {
        assert((wm.data[i] in seenW) is null,
            format("Point-map vertex %d repeats the value %s", i, wm.data[i]));
        seenW[wm.data[i]] = true;
    }
}

unittest // makeTaggedGridDirty is a SUPERSET of makeTaggedGridFull — no drift
{
    // The guard on the fifth stand, the same shape `makeTaggedGridBent` and
    // `makeTaggedGridMaps` carry: every plane of the base stand must survive
    // the injections unchanged over its own index range.
    auto a = makeTaggedGridFull(3);
    auto b = makeTaggedGridDirty(3);
    import std.conv : to;

    assert(b.vertices.length == a.vertices.length + 3, "exactly three vertices added");
    assert(b.faces.length    == a.faces.length + 3,    "exactly three faces added");
    foreach (vi; 0 .. a.vertices.length)
        assert(a.vertices[vi] == b.vertices[vi],
               "base vertex " ~ vi.to!string ~ " moved");
    foreach (fi; 0 .. a.faces.length)
        assert(a.faces[fi] == b.faces[fi],
               "base winding differs at face " ~ fi.to!string);
    foreach (fi; 0 .. a.faces.length) {
        assert(a.faceMaterial[fi] == b.faceMaterial[fi], "faceMaterial drifted");
        assert(a.facePart[fi]     == b.facePart[fi],     "facePart drifted");
        assert(a.faceMarks[fi]    == b.faceMarks[fi],    "faceMarks drifted");
        assert(a.faceSetMask[fi]  == b.faceSetMask[fi],  "faceSetMask drifted");
    }
    assert(a.surfaces.length == b.surfaces.length, "the surface registry drifted");

    // …and the injections are exactly what the base stand does NOT have.
    CleanupResult ra, rb;
    { auto ed = MeshEditBatch.unrecorded(a, kCleanupEditScope); ra = ed.cleanupMesh(); ed.close(); }
    { auto ed = MeshEditBatch.unrecorded(b, kCleanupEditScope); rb = ed.cleanupMesh(); ed.close(); }
    assert(!ra.anyAffected() && rb.anyAffected(),
        "the base stand must be CLEAN (mesh.cleanup refuses it) and the dirty "
      ~ "one must not — that difference is the whole reason the fifth stand "
      ~ "exists, and it is the mutation W-5-0 reddens with");
}

// ---------------------------------------------------------------------------
// makeTaggedGridBent (task 1903 Stage L2) — `makeTaggedGridFull` plus the two
// additions without which two of stage L2's twelve commands REFUSE.
// ---------------------------------------------------------------------------

/// The stand for stage L2's parity fixture
/// (`tests/fixtures/undo_parity/create_stable.json`) and for its witnesses.
///
/// WHY A FOURTH STAND AND NOT AN EDIT OF `makeTaggedGridFull`. The same
/// argument that made `makeTaggedGridFull` a sibling of `makeTaggedGrid` and
/// `makeTaggedGridMaps` a sibling of `makeTaggedGridFull`, one level down:
/// `makeTaggedGridFull` is the stand of L0's frozen parity fixture
/// (`undo_parity_l0_test.d`) and of §8's O(Δ) cells, and changing what it
/// CONTAINS changes what those gates OBSERVE. This is a fourth stand, and the
/// superset unittest below is the guard against the two drifting apart.
///
/// THE TWO ADDITIONS, AND NEITHER IS FLAVOUR — MEASURED ON THIS TREE
/// (2026-08-27, `makeTaggedGridFull(3)`, this lane, both numbers came out of a
/// run rather than off a plan row):
///
///  1. **One face wound BACKWARDS.** Without it
///     `mesh_ops.cleanup.computeOrientationFlipMask` returns a mask with
///     **0** faces set on `makeTaggedGridFull(3)` — the sheet is already
///     uniformly wound — so `fixFaceOrientation` flips nothing,
///     `mesh.fixOrientation`'s `nFlipped == 0` arm REFUSES, and its parity
///     cell would freeze a pair of identical dumps.
///  2. **Two interior vertices lifted OFF the plane.** Without them
///     `Mesh.alignFacesByMask` returns **0** on all four operand
///     configurations measured (empty ⇒ whole-mesh operand, one face, one row
///     of three, every face): a planar sheet is its own best-fit plane, every
///     vertex is already on it, and `mesh.align` REFUSES. `alignFacesByMask`
///     unions selected faces into ISLANDS and fits one plane per island, so a
///     single lifted vertex is enough for the whole-mesh operand — the second
///     is what keeps a ONE-FACE operand non-vacuous too, which is the operand
///     `polygon_align`'s own cell drives.
///
/// Both refusals are also on record from the perf lane's exclusion list
/// (`tools/perf/run.d`, `CmdExclusion("mesh.fixOrientation", …)` /
/// `CmdExclusion("mesh.align", …)`, 2026-08-19). They were RE-MEASURED here
/// rather than inherited: a `CmdExclusion` is a statement about the stand the
/// perf lane used, and reading one as a statement about YOUR stand is how a
/// fixture ends up unable to exhibit its own phenomenon.
///
/// WHICH FACE, AND WHY NOT ANY FACE. Face **5 is HIDDEN** in
/// `makeTaggedGridFull` and every one of L2's face kernels runs its mask
/// through `maskMinusHiddenFaces`, so a corruption placed there would be
/// skipped by `flipFacesByMask` and the stand would be silently back to
/// uniform. Face 2 is visible, is not the selected face (7), is not the
/// polygon-set member (4), and carries `faceMaterial == 0` / `facePart == 5`,
/// so the mark planes stay non-uniform across it.
Mesh makeTaggedGridBent(int n = 3)
{
    import std.algorithm.mutation : reverse;

    assert(n >= 3, "makeTaggedGridBent: inherits makeTaggedGridFull's floor");

    Mesh m = makeTaggedGridFull(n);

    // Addition 1 — one face wound backwards. Written RAW (`reverse` on the
    // winding, then `buildLoops`) and NOT through `flipFacesByMask`: that
    // kernel is the very thing stage L2-a migrates, so building the stand with
    // it would make the stand a function of the code under test.
    reverse(m.faces[2]);

    // Addition 2 — two interior vertices off the plane. On a 3x3 grid the
    // interior vertices are 5, 6, 9 and 10; 5 and 10 are diagonal, so no single
    // face carries both and every face of the sheet is left non-planar by one
    // of them.
    m.vertices[5].y  += 0.37f;
    m.vertices[10].y -= 0.21f;

    m.buildLoops();
    return m;
}

unittest // makeTaggedGridBent: BOTH additions are live, asserted BY NAME
{
    import mesh_ops.cleanup : computeOrientationFlipMask;
    import std.format : format;

    // The control first: the SHIPPED stand exhibits NEITHER phenomenon. This
    // half is what makes the two asserts below findings rather than
    // decorations — without it "the bent stand flips a face" is satisfied by a
    // predicate that says yes to everything.
    {
        auto flat = makeTaggedGridFull(3);
        flat.buildLoops();
        size_t nFlat = 0;
        foreach (b; computeOrientationFlipMask(flat)) if (b) ++nFlat;
        assert(nFlat == 0,
            format("the CONTROL moved: makeTaggedGridFull(3) now wants %d "
                 ~ "face(s) flipped. It measured 0 on 2026-08-27, which is the "
                 ~ "whole reason this stand exists — re-derive both additions "
                 ~ "before trusting anything below", nFlat));

        bool[] all = new bool[](flat.faces.length);
        all[] = true;
        assert(flat.alignFacesByMask(all) == 0,
            "the CONTROL moved: makeTaggedGridFull(3) is no longer planar, so "
          ~ "`mesh.align` no longer refuses it and addition 2 is no longer a "
          ~ "finding");
    }

    auto m = makeTaggedGridBent(3);

    // Addition 1: EXACTLY one face is inconsistently wound. Not ">= 1": a
    // mask that names every face is what a broken seed produces, and it would
    // satisfy a `> 0` test while making `mesh.flip`'s and
    // `mesh.fixOrientation`'s cells drive completely different operands.
    size_t nFlip = 0;
    foreach (b; computeOrientationFlipMask(m)) if (b) ++nFlip;
    assert(nFlip == 1,
        format("makeTaggedGridBent: computeOrientationFlipMask names %d "
             ~ "face(s), expected exactly 1 — without it mesh.fixOrientation "
             ~ "REFUSES (nFlipped == 0) and its parity cell freezes a pair of "
             ~ "identical dumps", nFlip));

    // …and the corrupted face is not the HIDDEN one, or `maskMinusHiddenFaces`
    // deletes it from the operand and the stand is uniform again in effect.
    assert(!m.isFaceHidden(2),
        "makeTaggedGridBent corrupts face 2 — it must be VISIBLE, because "
      ~ "every face kernel in stage L2 runs its mask through "
      ~ "maskMinusHiddenFaces and would skip it silently");

    // Addition 2: the sheet is BENT, on both the whole-mesh operand and a
    // single-face one (the operand `polygon_align`'s own parity cell drives).
    {
        auto a = makeTaggedGridBent(3);
        bool[] all = new bool[](a.faces.length);
        all[] = true;
        immutable size_t moved = a.alignFacesByMask(all);
        assert(moved > 0,
            format("makeTaggedGridBent: alignFacesByMask moved %d vertices on "
                 ~ "the whole-mesh operand, expected > 0 — mesh.align REFUSES "
                 ~ "a planar sheet in all four operand configurations "
                 ~ "(measured 2026-08-27)", moved));
    }
    {
        auto a = makeTaggedGridBent(3);
        bool[] one = new bool[](a.faces.length);
        one[4] = true;          // interior face, carries vertex 5
        assert(a.alignFacesByMask(one) > 0,
            "makeTaggedGridBent: a ONE-FACE operand must also be non-planar — "
          ~ "the second lifted vertex is what buys this, and polygon_align's "
          ~ "parity cell drives exactly this operand");
    }

    // The stand still IS makeTaggedGridFull in every other respect: the
    // additions must not have cost a plane. (`faces` is deliberately excluded —
    // face 2's winding is addition 1.)
    auto f = makeTaggedGridFull(3);
    assert(m.vertices.length == f.vertices.length, "vertex count preserved");
    assert(m.faces.length    == f.faces.length,    "face count preserved");
    assert(m.faceMaterial    == f.faceMaterial,    "faceMaterial preserved");
    assert(m.facePart        == f.facePart,        "facePart preserved");
    assert(m.faceSetMask     == f.faceSetMask,     "faceSetMask preserved");
    assert(m.faceMarks       == f.faceMarks,       "faceMarks preserved");
    assert(m.edgeSetMask     == f.edgeSetMask,     "edgeSetMask preserved");
    assert(m.surfaces.length == f.surfaces.length, "surfaces preserved");
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null && uv.domain == MapDomain.PolyVertex,
        "the PolyVertex map is what makes L2-a's corner-permutation witness "
      ~ "possible at all — a stand without it cannot exhibit the residual");
    assert(uv.data.length == m.cornerCount() * 2, "the corner map is in step");
    assert(m.meshMap("W") !is null, "the Point-domain map survives");

    // OPEN, and it is the thicken row that needs it: `thickenSurface`'s rim
    // bridge only runs on boundary loops, so on a closed solid the one
    // prerequisite that command owns is unreachable.
    bool sawBoundary = false;
    foreach (c; m.edgePolygonCounts()) if (c == 1) { sawBoundary = true; break; }
    assert(sawBoundary, "makeTaggedGridBent must be OPEN (mesh.thicken's rim)");
}

// ---------------------------------------------------------------------------
// makeTaggedGridMaps (task 1903 Stage L1) — `makeTaggedGridFull` plus the five
// things the MAP / SET family needs and which no existing stand carries.
// ---------------------------------------------------------------------------

/// The stand for stage L1's parity fixture (`tests/fixtures/undo_parity/
/// uv_maps_sets.json`) and for its dense/payload measurement.
///
/// WHY A THIRD STAND AND NOT AN EXTENSION OF `makeTaggedGridFull`. Identical
/// argument to the one that made `makeTaggedGridFull` a sibling rather than an
/// edit of `makeTaggedGrid`, one level down: `makeTaggedGridFull` is read by
/// stage §8's O(Δ) cells and by L0-b's and L0-d's witnesses, and its own
/// superset unittest asserts it agrees with `makeTaggedGrid`. Changing what it
/// CONTAINS changes what those gates observe. So this is a third, larger stand
/// and the superset unittest below is the guard against the two drifting.
///
/// THE FIVE ADDITIONS over `makeTaggedGridFull`, each with why the L1 family
/// cannot be measured without it:
///
///  1. **Two morph maps (`morphAbsolute` + `morphRelative`) with a SPARSE
///     presence channel.** `MeshMap.present` is the plane a forward-only check
///     misses in this family: empty MEANS "all present" (`mesh.d`'s `isPresent`),
///     so a revert that restores `data` and drops `present` produces a legal,
///     WRONG map rather than a crash. The channel is only discriminating if it
///     carries all three states at once, so each map gets:
///       * an ABSENT element,
///       * a PRESENT element with a non-zero value,
///       * a PRESENT element whose stored value is EXACTLY 0.0f — the cell
///         that separates "restored the value" from "restored the presence",
///         because those two are indistinguishable everywhere else.
///     Both KINDS are present because they are not one kind with a flag: they
///     differ in `absentIsZero`, so for `morphAbsolute` an absent entry MOVES
///     the vertex and for `morphRelative` it does not.
///  2. **An Edge-domain map.** `MapDomain` has three members and no stand
///     exercised the third; the L1 family's (V) payload is indexed in the
///     map's OWN element space, which is a different array per domain.
///  3. **A SECOND named set per domain.** With one set per domain every bit
///     position is 0, so a delta that carried the mask and dropped the NAME
///     registry — or carried bit 0 for the wrong name — reads identical.
///  4. **Non-monotonic selection ORDER in two domains.** The restoration law
///     for a set-apply is by ORDER POSITION, so a stand whose order stamps
///     ascend with the element index is green under a revert that re-derives
///     the order from the index instead of restoring it.
///  5. **A second UV-shaped PolyVertex map**, so `uv.copy`'s source and
///     destination are both real and its undo has a registry to shrink.
///  6. **A REALISTIC layout on the inherited `uv` map.** `makeTaggedGridFull`
///     fills it with `data[i] = i`, which is fine for a plane dump — every
///     corner distinct — and useless as an operand: with a unique UV per
///     corner every corner is its own UV island, so every corner is a SEAM,
///     `uvRelax` finds nothing unpinned and REFUSES, and the cell freezes a
///     refusal rather than an edit. Replaced here by a planar unwrap in which
///     corners meeting at a vertex share a UV, i.e. what a UV map on a grid
///     actually looks like. This is the one place the stand overwrites an
///     inherited plane rather than adding one, and it is why the superset
///     unittest below compares the geometry and mark planes but NOT `uv`.
///
/// `n` defaults to 3 so the parity capture reads `makeTaggedGridMaps()`; the
/// dense/payload measurement passes 316 (99 856 faces).
Mesh makeTaggedGridMaps(int n = 3)
{
    import mesh_selsets : selSetEditPolygon, selSetEditVertex, selSetEditEdge,
                          SetEditMode;

    assert(n >= 3, "makeTaggedGridMaps: inherits makeTaggedGridFull's n >= 3");

    Mesh m = makeTaggedGridFull(n);

    // ---- addition 6: a REAL UV layout on the inherited map ----------------
    // Planar (x, z) unwrap normalised to [0,1]. Corners that meet at a vertex
    // get the SAME uv, which is what makes the map have interior (non-seam)
    // corners at all — the property every UV kernel in the family needs and
    // `data[i] = i` destroys.
    {
        auto uv0 = m.meshMap(kUvMapName);
        assert(uv0 !is null, "fixture: the inherited UV map must be there");
        float minX = m.vertices[0].x, maxX = minX;
        float minZ = m.vertices[0].z, maxZ = minZ;
        foreach (ref p; m.vertices) {
            if (p.x < minX) minX = p.x;  if (p.x > maxX) maxX = p.x;
            if (p.z < minZ) minZ = p.z;  if (p.z > maxZ) maxZ = p.z;
        }
        immutable float spanX = (maxX > minX) ? (maxX - minX) : 1.0f;
        immutable float spanZ = (maxZ > minZ) ? (maxZ - minZ) : 1.0f;
        // A per-VERTEX table, then broadcast to that vertex's corners — so
        // the shared-uv property is a property of the construction and not an
        // accident of the formula.
        auto uvOfVert = new float[2][](m.vertices.length);
        foreach (vi, ref p; m.vertices)
            uvOfVert[vi] = [(p.x - minX) / spanX, (p.z - minZ) / spanZ];

        // …and then PERTURB two interior vertices. A perfectly uniform unwrap
        // is a FIXED POINT of the relax kernel — it moves nothing and
        // `uvRelax` answers false — which is the identical trap `mesh.smooth`
        // has on a flat grid. The perturbation is what gives the family's
        // smoothing kernels something to converge from. Interior vertices of a
        // 3x3 grid are 5/6/9/10 (row-major, i*4+j); two of them are enough and
        // the asymmetry is deliberate.
        if (uvOfVert.length > 10) {
            uvOfVert[5][0]  += 0.17f;  uvOfVert[5][1]  -= 0.11f;
            uvOfVert[10][0] -= 0.09f;  uvOfVert[10][1] += 0.21f;
        }

        foreach (L; 0 .. m.loops.length) {
            const uint vi = m.loops[L].vert;
            uv0.data[L * 2]     = uvOfVert[vi][0];
            uv0.data[L * 2 + 1] = uvOfVert[vi][1];
        }
    }

    // ---- addition 5: a second PolyVertex map, so uv.copy has a real target.
    auto uv2 = m.addMeshMap("uv2", 2, MapDomain.PolyVertex);
    assert(uv2 !is null, "fixture: second UV map registration must succeed");
    foreach (i; 0 .. uv2.data.length)
        uv2.data[i] = 0.25f * cast(float) i;

    // ---- addition 2: the Edge domain, through the classified door so `dim`
    // and `domain` come from `kindInfo` and cannot drift from the shape table.
    auto cw = m.addMeshMapOfKind(MapKind.creaseWeight);
    assert(cw !is null, "fixture: crease map registration must succeed");
    assert(cw.domain == MapDomain.Edge, "fixture: crease map must be Edge-domain");
    // Written directly rather than through `setCreaseWeight`, which publishes
    // AND bumps `topologyVersion` per call; the stand is built, not edited, and
    // a stand that arrives with a version history is a stand whose counters
    // cannot be used as a baseline.
    foreach (i; 0 .. cw.data.length)
        cw.data[i] = (i % 3 == 0) ? 0.0f : (0.1f * cast(float)(i + 1));

    // ---- addition 1: the two morph maps, with the three presence states.
    //
    // `addMeshMapOfKind` creates a presence-tracked map ABSENT EVERYWHERE, so
    // "absent" is the default and the two present states are written through
    // the PRODUCTION path (`setMorphValue`) rather than by hand — which is what
    // makes the fixture exercise the presence write the family will have to
    // restore.
    static struct MorphSpec { MapKind kind; string name; }
    static immutable MorphSpec[2] morphSpecs =
        [ MorphSpec(MapKind.morphAbsolute, "MA"),
          MorphSpec(MapKind.morphRelative, "MR") ];
    foreach (ref spec; morphSpecs)
    {
        auto mm = m.addMeshMapOfKind(spec.kind, spec.name);
        assert(mm !is null, "fixture: morph map registration must succeed");
        assert(mm.present.length == m.vertices.length,
               "fixture: a morph map must carry a per-vertex presence channel");
        // present, NON-ZERO
        m.setMorphValue(spec.name, 1, Vec3(0.30f, -0.20f, 0.10f));
        m.setMorphValue(spec.name, 4, Vec3(-0.05f, 0.45f, 0.00f));
        // present, stored value EXACTLY zero — indistinguishable from absent
        // in `data`, distinguishable only in `present`.
        m.setMorphValue(spec.name, 2, Vec3(0.0f, 0.0f, 0.0f));
        // absent, and reached through the production clear rather than left at
        // the creation default, so the clear path itself is in the fixture.
        m.setMorphValue(spec.name, 3, Vec3(9.0f, 9.0f, 9.0f));
        m.clearMorphValue(spec.name, 3);
    }

    // ---- addition 3: a second named set in each of the three domains.
    bool[] polySel2 = new bool[](m.faces.length);
    polySel2[0] = true;
    polySel2[3] = true;
    selSetEditPolygon(m, "S2", SetEditMode.replace, polySel2);

    bool[] vertSel2 = new bool[](m.vertices.length);
    vertSel2[1] = true;
    vertSel2[4] = true;
    vertSel2[7] = true;
    selSetEditVertex(m, "V2", SetEditMode.replace, vertSel2);

    bool[] edgeSel2 = new bool[](m.edges.length);
    edgeSel2[0] = true;
    edgeSel2[2] = true;
    selSetEditEdge(m, "E2", SetEditMode.replace, edgeSel2);

    // ---- addition 4: make the inherited selection order NON-MONOTONIC.
    //
    // `makeTaggedGridFull` stamps `faceSelectionOrder[2] = 11` and `[6] = 23`,
    // which ASCENDS with the index; and its vertex/edge selections are stamped
    // by `selectVertex`/`selectEdge` in index order for the same reason. A
    // revert that re-derives the order from the element index is green on
    // that. Two domains are re-stamped in DESCENDING order here, which is the
    // shape only a restore can reproduce.
    assert(m.vertexSelectionOrder.length > 9 && m.edgeSelectionOrder.length > 3,
           "fixture: the inherited selections must exist before re-stamping");
    m.vertexSelectionOrder[2] = 40;
    m.vertexSelectionOrder[9] = 17;   // later index, EARLIER stamp
    m.edgeSelectionOrder[0]   = 31;
    m.edgeSelectionOrder[3]   = 12;   // later index, EARLIER stamp
    if (m.vertexSelectionOrderCounter < 41) m.vertexSelectionOrderCounter = 41;
    if (m.edgeSelectionOrderCounter   < 32) m.edgeSelectionOrderCounter   = 32;

    return m;
}

unittest // makeTaggedGridMaps: every one of the five additions, asserted by NAME
{
    // MUTATION M-F′ FOR THIS BLOCK: point `makeTaggedGridMaps`'s body at
    // `makeTaggedGridFull(n)` and return immediately. Every presence, domain,
    // second-set and order witness below goes red — which is the point: without
    // this block a stand that quietly lost its morph maps would leave the L1
    // parity fixture green under a delta that carries no presence channel at
    // all, and nothing else in the tree would notice.
    auto m = makeTaggedGridMaps();

    // ---- 1: the two morph kinds, and all THREE presence states in each ------
    foreach (nm; ["MA", "MR"])
    {
        auto mm = m.meshMap(nm);
        assert(mm !is null, "morph map '" ~ nm ~ "' must exist");
        assert(mm.domain == MapDomain.Point && mm.dim == 3,
               "morph map '" ~ nm ~ "' must be Point/dim 3");
        assert(mm.present.length == m.vertices.length,
               "morph map '" ~ nm ~ "' must carry a per-vertex presence channel; "
             ~ "an EMPTY channel MEANS all-present and is the whole failure this "
             ~ "stand exists to expose");

        size_t absent, presentZero, presentNonZero;
        foreach (vi; 0 .. m.vertices.length)
        {
            const b = vi * 3;
            const bool isZero = mm.data[b] == 0.0f && mm.data[b + 1] == 0.0f
                             && mm.data[b + 2] == 0.0f;
            if (!mm.isPresent(vi)) { ++absent; continue; }
            if (isZero) ++presentZero; else ++presentNonZero;
        }
        assert(absent > 0,
               "morph map '" ~ nm ~ "': no ABSENT element — the presence channel "
             ~ "is uniform and carries no information");
        assert(presentNonZero > 0,
               "morph map '" ~ nm ~ "': no PRESENT non-zero element");
        assert(presentZero > 0,
               "morph map '" ~ nm ~ "': no element that is PRESENT with a stored "
             ~ "value of exactly 0.0f — that element is the ONLY one on which "
             ~ "'restored the value' and 'restored the presence' differ");
    }
    assert(m.meshMap("MA").kind == MapKind.morphAbsolute
        && m.meshMap("MR").kind == MapKind.morphRelative,
           "the two morph maps must be of DIFFERENT kinds: they have identical "
         ~ "shape and differ only in what an absent entry MEANS");

    // ---- 2: the third MapDomain -------------------------------------------
    size_t edgeDomainMaps;
    foreach (ref mm; m.meshMaps) if (mm.domain == MapDomain.Edge) ++edgeDomainMaps;
    assert(edgeDomainMaps > 0, "no Edge-domain map — MapDomain's third member "
                             ~ "is unexercised by every other stand");
    auto cw = m.meshMap(kCreaseWeightMapName);
    assert(cw !is null && cw.data.length == m.edges.length,
           "the Edge-domain map must be sized to the EDGE array");
    bool creaseNonUniform;
    foreach (v; cw.data) if (v != cw.data[0]) { creaseNonUniform = true; break; }
    assert(creaseNonUniform, "the Edge-domain map's values must be non-uniform");

    // ---- 3: a second named set in each domain ------------------------------
    assert(m.vertexSetNames.length  >= 2, "vertex sets: need a SECOND name, or "
                                        ~ "every mask bit is bit 0");
    assert(m.polygonSetNames.length >= 2, "polygon sets: need a SECOND name");
    assert(m.edgeSetNames.length    >= 2, "edge sets: need a SECOND name");
    // …and the second name's bit must actually be set somewhere, or the extra
    // registry entry is a name with no mask and the masks are still one-bit.
    bool sawHighVertexBit, sawHighFaceBit, sawHighEdgeBit;
    foreach (w; m.vertexSetMask) if ((w & ~1UL) != 0) { sawHighVertexBit = true; break; }
    foreach (w; m.faceSetMask)   if ((w & ~1UL) != 0) { sawHighFaceBit   = true; break; }
    foreach (k; m.edgeSetMask.keys) if ((m.edgeSetMask[k] & ~1UL) != 0) { sawHighEdgeBit = true; break; }
    assert(sawHighVertexBit, "the second VERTEX set owns no mask bit");
    assert(sawHighFaceBit,   "the second POLYGON set owns no mask bit");
    assert(sawHighEdgeBit,   "the second EDGE set owns no mask bit");

    // ---- 4: the selection order is NON-MONOTONIC in two domains ------------
    static bool nonMonotonic(const(int)[] order)
    {
        int prev = 0; bool sawDescent;
        foreach (v; order) {
            if (v == 0) continue;               // unstamped
            if (prev != 0 && v < prev) sawDescent = true;
            prev = v;
        }
        return sawDescent;
    }
    assert(nonMonotonic(m.vertexSelectionOrder),
           "vertexSelectionOrder ascends with the index — a revert that "
         ~ "RE-DERIVES the order instead of restoring it is green on that");
    assert(nonMonotonic(m.edgeSelectionOrder),
           "edgeSelectionOrder ascends with the index — same hole");

    // ---- 6: the inherited UV map has INTERIOR (non-seam) corners ----------
    // The property, not the layout: at least one vertex must be reached by two
    // corners carrying the SAME uv. Under `data[i] = i` no vertex is, every
    // corner is a seam, and `uv.relax` refuses outright.
    {
        auto uv0 = m.meshMap(kUvMapName);
        assert(uv0 !is null, "the inherited UV map must be there");
        size_t sharedCorners;
        foreach (a; 0 .. m.loops.length)
            foreach (b; a + 1 .. m.loops.length) {
                if (m.loops[a].vert != m.loops[b].vert) continue;
                if (uv0.data[a * 2] == uv0.data[b * 2]
                 && uv0.data[a * 2 + 1] == uv0.data[b * 2 + 1]) ++sharedCorners;
            }
        assert(sharedCorners > 0,
               "no two corners at one vertex share a uv — every corner is its "
             ~ "own UV island, so every corner is a SEAM and the UV kernels "
             ~ "have nothing unpinned to move. A stand in that state freezes "
             ~ "REFUSALS, not edits.");
    }

    // ---- 5: the second PolyVertex map --------------------------------------
    size_t polyVertexMaps;
    foreach (ref mm; m.meshMaps) if (mm.domain == MapDomain.PolyVertex) ++polyVertexMaps;
    assert(polyVertexMaps >= 2, "uv.copy needs a real destination map");

    // ---- the tripwire for the NEXT MeshMap field --------------------------
    // The third copy of this assert (the other two are `MeshMap.dup` in
    // mesh.d and `MeshSnapshot.byteSize` in snapshot.d). It is here because a
    // seventh field would be invisible to every check above: they enumerate
    // the fields this stand was written to populate, so a new one arrives
    // populated with its default and nothing says the stand stopped covering
    // the struct.
    static assert(MeshMap.tupleof.length == 6,
        "MeshMap gained a field — decide whether makeTaggedGridMaps must "
      ~ "populate it non-uniformly before bumping this count. A field left at "
      ~ "its default here is a plane the L1 parity fixture cannot discriminate.");
}

unittest // makeTaggedGridMaps is a SUPERSET of makeTaggedGridFull — no drift
{
    // The guard on the third copy. `makeTaggedGridMaps` is documented as
    // "makeTaggedGridFull plus five", and this is what makes that executable:
    // every plane the parent populates must read identically here, so a later
    // edit to this stand that perturbs an INHERITED plane is caught rather than
    // silently changing what L1's fixture and L0's fixture disagree about.
    auto a = makeTaggedGridFull(3);
    auto b = makeTaggedGridMaps(3);

    assert(a.vertices.length == b.vertices.length, "vertex count must match");
    assert(a.faces.length    == b.faces.length,    "face count must match");
    assert(a.edges.length    == b.edges.length,    "edge count must match");
    assert(a.vertices        == b.vertices,        "positions must match");
    assert(a.faceMarks       == b.faceMarks,       "faceMarks must match");
    assert(a.vertexMarks     == b.vertexMarks,     "vertexMarks must match");
    assert(a.edgeMarks       == b.edgeMarks,       "edgeMarks must match");
    assert(a.faceMaterial    == b.faceMaterial,    "faceMaterial must match");
    assert(a.facePart        == b.facePart,        "facePart must match");
    assert(a.faceSelectionOrder == b.faceSelectionOrder,
           "faceSelectionOrder must match — additions 4 re-stamps the VERTEX "
         ~ "and EDGE orders only, deliberately, so this one stays inherited");
    assert(a.surfaces.length == b.surfaces.length, "surfaces must match");

    // …and the five additions are exactly what the parent does NOT have.
    assert(a.meshMap("MA") is null && a.meshMap("MR") is null
        && a.meshMap(kCreaseWeightMapName) is null && a.meshMap("uv2") is null,
           "the parent must NOT carry the additions — if it does, this stand "
         ~ "has stopped being the thing that adds them");
    assert(a.vertexSetNames.length == 1 && a.polygonSetNames.length == 1
        && a.edgeSetNames.length == 1,
           "the parent must carry exactly ONE set per domain");
    assert(b.meshMaps.length == a.meshMaps.length + 4,
           "four new maps: uv2, crease, MA, MR");
    // …and `uv` is DELIBERATELY not compared: addition 6 replaces its values.
    // Asserted as a difference rather than skipped in silence, so a later edit
    // that drops the re-layout is caught here and not only by a refusing cell.
    assert(a.meshMap(kUvMapName).data != b.meshMap(kUvMapName).data,
           "addition 6 (the realistic UV layout) is gone — the child now "
         ~ "inherits `data[i] = i`, on which every UV kernel refuses");
}

unittest // makeDisk: hub-first fan, n triangles, n+1 verts, all rim on the unit circle
{
    import std.math : abs, sqrt;

    foreach (n; [3, 4, 6, 12])
    {
        auto m = makeDisk(n);
        assert(m.vertices.length == n + 1, "disk: one hub plus n rim verts");
        assert(m.faces.length == n,        "disk: one triangle per rim segment");
        assert(m.vertices[0].x == 0 && m.vertices[0].y == 0 && m.vertices[0].z == 0,
               "disk: vertex 0 is the hub at the origin");

        foreach (i; 1 .. m.vertices.length)
        {
            auto v = m.vertices[i];
            assert(abs(sqrt(v.x * v.x + v.y * v.y) - 1.0f) < 1e-5f,
                   "disk: rim vertices sit on the unit circle");
            assert(v.z == 0, "disk: the fan is planar in z=0");
        }

        foreach (fi; 0 .. m.faces.length)
        {
            assert(m.faces[fi].length == 3, "disk: every face is a triangle");
            assert(m.faces[fi][0] == 0,     "disk: every triangle is wound hub-first");
        }

        // Boundary: the rim is open, so every rim edge borders exactly one face.
        assert(m.edges.length == 2 * n,
               "disk: n spokes + n rim edges");
    }
}

// ---------------------------------------------------------------------------
// dumpMeshPlanes (task 1903 Stage K) — the WHOLE mesh state as a plane -> text
// table, for a revert that claims to restore all of it.
// ---------------------------------------------------------------------------

/// Every plane a `MeshSnapshot` would have restored, one map entry per plane,
/// so a diff can NAME what a delta revert did not put back instead of only
/// answering "different".
///
/// WHY A TABLE AND NOT ONE STRING. The three test modules that had a
/// `dumpMeshState` before this one each compared a single concatenated string,
/// and the failure message could then only say "the state differs". Stage K's
/// whole result is a LIST of surviving residuals per family — Select bits and
/// array lengths on the armed families, per-vertex VALUES on the two bevels —
/// and a single string cannot express the difference between those two, which
/// is exactly the line the stage draws (plan §5.3).
///
/// `%a` — the HEX float form, so floats compare BITS: `%g` would let a
/// `-0.0`/`+0.0` pair read as equal (task 1903 Stage D2's signed-zero cell).
/// Every array is dumped with its LENGTH, because "values right, array grown"
/// is a distinct measured outcome here and a value-only dump hides it.
string[string] dumpMeshPlanes(ref Mesh m)
{
    import std.format : format;
    import std.conv : to;
    import snapshot : MeshSnapshot;

    // A NEW `MeshSnapshot` PLANE CANNOT BE BORN UNCOVERED. This dump's whole
    // contract is "every plane a snapshot would have restored", and the one
    // way that contract rots silently is a field added to `MeshSnapshot` and
    // not to the table below — the diff then keeps answering "the planes
    // agree" about a plane it never read. 24 is the 23 state planes plus
    // `filled`. Precedent for the shape of this guard: `MeshMap.dup`'s own
    // field-count assert (`source/mesh.d`) and the two in `source/snapshot.d`.
    static assert(MeshSnapshot.tupleof.length == 24,
        "MeshSnapshot gained or lost a field — add the plane to "
      ~ "dumpMeshPlanes below, or write here why it is not restorable state, "
      ~ "before bumping this count");

    string[string] t;
    t["counts"] = format("V=%d F=%d E=%d",
                         m.vertices.length, m.faces.length, m.edges.length);

    string vs;
    foreach (i, v; m.vertices) vs ~= format(" v%d(%a,%a,%a)", i, v.x, v.y, v.z);
    t["vertices"] = vs;

    string fs;
    foreach (i, f; m.faces) fs ~= format(" f%d%s", i, f.to!string);
    t["faces"] = fs;

    string es;
    foreach (i; 0 .. m.edges.length)
        es ~= format(" e%d[%d,%d]", i, m.edges[i][0], m.edges[i][1]);
    t["edges"] = es;

    t["vertexMarks"]          = m.vertexMarks.to!string;
    t["edgeMarks"]            = m.edgeMarks.to!string;
    t["faceMarks"]            = m.faceMarks.to!string;
    t["vertexSelectionOrder"] = m.vertexSelectionOrder.to!string;
    t["edgeSelectionOrder"]   = m.edgeSelectionOrder.to!string;
    t["faceSelectionOrder"]   = m.faceSelectionOrder.to!string;
    t["orderCounters"]        = format("%d/%d/%d",
                                       m.vertexSelectionOrderCounter,
                                       m.edgeSelectionOrderCounter,
                                       m.faceSelectionOrderCounter);
    t["faceMaterial"]  = m.faceMaterial.to!string;
    t["facePart"]      = m.facePart.to!string;
    t["faceSetMask"]   = m.faceSetMask.to!string;
    t["vertexSetMask"] = m.vertexSetMask.to!string;

    // `edgeSetMask` is an associative array keyed by an endpoint PAIR — sorted
    // so the dump is order-stable across rebuilds (its iteration order is not).
    import std.algorithm.sorting : sort;
    string eks;
    foreach (k; m.edgeSetMask.keys.dup.sort) eks ~= format(" %d=%d", k, m.edgeSetMask[k]);
    t["edgeSetMask"] = eks;
    string wks;
    foreach (k; m.wireEdgeKeys.keys.dup.sort) wks ~= format(" %d", k);
    t["wireEdgeKeys"] = wks;

    // `surfaces` USED TO BE ITS LENGTH ALONE, and the three set-NAME
    // registries were absent outright (Stage K review, MINOR-5). Both holes
    // have the same shape: a revert that put back two surfaces with the wrong
    // colours, or dropped the name of a set whose mask plane it restored,
    // compared EQUAL here. Measured inert on today's stands — pre == post on
    // every armed family — which is the reason to write them down now rather
    // than after something starts moving them.
    string sfs;
    foreach (i, ref sf; m.surfaces)
        sfs ~= format(" s%d(%s|%a,%a,%a|%a,%a,%a,%a|%s)", i, sf.name,
                      sf.baseColor.x, sf.baseColor.y, sf.baseColor.z,
                      sf.diffuseAmount, sf.specularAmount, sf.glossiness,
                      sf.opacity, sf.compiledFromTreeId);
    t["surfaces"] = format("len=%d:%s", m.surfaces.length, sfs);

    t["vertexSetNames"]  = m.vertexSetNames.to!string;
    t["edgeSetNames"]    = m.edgeSetNames.to!string;
    t["polygonSetNames"] = m.polygonSetNames.to!string;

    foreach (ref mm; m.meshMaps) {
        // `kind` and `present` are the two `MeshMap` fields this dump dropped.
        // `present` is the dangerous one: EMPTY MEANS "ALL PRESENT", so a
        // revert that dropped the presence channel outright yields a legal,
        // WRONG map — not garbage, not a crash — and a values-only dump reads
        // it as identical. That is the same trap `MeshMap.dup` guards with its
        // own field-count assert (`source/mesh.d`).
        string s = format("dim=%d dom=%s kind=%s present=%s len=%d:",
                          mm.dim, mm.domain, mm.kind, mm.present,
                          mm.data.length);
        foreach (v; mm.data) s ~= format(" %a", v);
        t["map:" ~ mm.name] = s;
    }
    return t;
}

/// The names of the planes on which `a` and `b` disagree, sorted, comma-joined;
/// `""` when they agree on every plane. A plane present in only one side is
/// reported with a `(GONE)`/`(NEW)` suffix rather than skipped — a map that a
/// revert deleted outright is a difference, not an absence of one.
string diffMeshPlanes(string[string] a, string[string] b)
{
    import std.algorithm.sorting : sort;
    import std.array : join;

    string[] bad;
    foreach (k; a.keys.dup.sort) {
        auto pb = k in b;
        if (pb is null)   { bad ~= k ~ "(GONE)"; continue; }
        if (*pb != a[k])    bad ~= k;
    }
    foreach (k; b.keys.dup.sort)
        if ((k in a) is null) bad ~= k ~ "(NEW)";
    return bad.join(", ");
}

/// The same diff, rendered with the values, for a failure message that has to
/// show what came back instead of only which plane did not.
string explainMeshPlaneDiff(string[string] a, string[string] b)
{
    import std.algorithm.sorting : sort;
    import std.format : format;

    string s;
    foreach (k; a.keys.dup.sort) {
        auto pb = k in b;
        if (pb !is null && *pb == a[k]) continue;
        immutable string got = pb is null ? "<plane gone>" : *pb;
        s ~= format("\n    %s\n      expected: %s\n      got     : %s",
                    k, clip(a[k]), clip(got));
    }
    return s;
}

private string clip(string s) { return s.length > 400 ? s[0 .. 400] ~ " …" : s; }

// ---------------------------------------------------------------------------
// makeTaggedGridWeldSets (task 1903 Stage L10) — `makeTaggedGridDirty` plus the
// ONE plane no earlier stand can exhibit: an edge-set membership that MERGES.
// ---------------------------------------------------------------------------

/// The stand for stage L10's parity fixture
/// (`tests/fixtures/undo_parity/weld_merge.json`) and for its witnesses.
///
/// WHY A SIXTH STAND AND NOT AN EDIT OF `makeTaggedGridDirty`. The same rule
/// the four stands above follow: `makeTaggedGridDirty` is the stand of L5's
/// frozen parity fixture (`tests/fixtures/undo_parity/cleanup.json`, read by
/// `undo_parity_l5_test.d`), and changing what it CONTAINS changes what that
/// frozen gate OBSERVES. This is a sibling, and the superset unittest below is
/// the guard against the two drifting apart.
///
/// THE ONE ADDITION, and it is the stage's discriminating instrument.
/// `makeTaggedGridDirty` tags edges `(0,vCol)` and `(1,vCol)`, whose shared
/// endpoint `vCol` is DROPPED by the compaction — so it exercises the edge-set
/// payload's DROP predicate (Stage L5-b) and the RENUMBER of the survivors, and
/// **nothing else**. It cannot exhibit a MERGE by construction: no tagged edge
/// is incident to the WELDED vertex.
///
/// This stand tags `(0, vCoin)` — `vCoin` being `makeTaggedGridDirty`'s
/// coincident duplicate of vertex 1 — into its own edge set `"M"`. Post-weld
/// `(0,vCoin)` re-keys to `(0,1)`, **which already exists and is NOT a member**,
/// so `mesh_selsets.selSetRekeyEdges` OR-merges two keys into one. A merge is
/// not invertible entry by entry: after it, "was this key here before?" is not
/// derivable from the state, which is why Stage L10 records the pre-image
/// (`Kind.EdgeSetRekey`, task 2310) rather than inverting per entry.
///
/// The FAILURE THIS EXISTS TO SEE moves no count: V, F, E, every mark word,
/// `vertexSetMask`, `faceSetMask`, `faceMaterial`, `facePart` and every map
/// compare EQUAL across it. Exactly two AA entries differ — one absent
/// (`(0,vCoin)` lost its membership) and one spurious (`(0,1)` gained one).
///
/// A SEPARATE SET NAME, not `"E"`, and that is deliberate: with the merge in
/// its own slot a cell can print the plane's two halves by name, and a red
/// cannot be read as the DROP half (`"E"`) regressing.
///
/// The second half of the discriminator — a vertex in a named vertex set that
/// is welded AWAY rather than merely orphaned — is INHERITED, not added:
/// `makeTaggedGridDirty` already puts `vCoin` in set `"V"`. It is ASSERTED
/// here so that a change to the parent which drops it reddens at this stand
/// instead of quietly making this one weaker.
Mesh makeTaggedGridWeldSets(int n = 3)
{
    import mesh_selsets : selSetEditEdge, SetEditMode;

    Mesh m = makeTaggedGridDirty(n);

    // `vCoin` is the FIRST of `makeTaggedGridDirty`'s three appended vertices,
    // derived rather than hard-coded: the parent appends three, in the order
    // coincident / collinear / orphan.
    immutable uint vCoin = cast(uint) m.vertices.length - 3;
    assert(m.vertices[vCoin] == m.vertices[1],
           "makeTaggedGridWeldSets: the parent's coincident vertex is no longer "
         ~ "a duplicate of vertex 1 — the weld this stand is about would not "
         ~ "fire, and every cell on it would pass over an operation that did "
         ~ "nothing");

    immutable uint eMerge = m.edgeIndex(0, vCoin);
    immutable uint eSurv  = m.edgeIndex(0, 1);
    assert(eMerge != ~0u && eSurv != ~0u,
           "makeTaggedGridWeldSets: the merge pair (0,vCoin) and (0,1) are not "
         ~ "BOTH in the edge array — with only one of them present the weld "
         ~ "re-keys onto a free slot, which is a RENUMBER and is already "
         ~ "covered by the parent stand");

    bool[] es = new bool[](m.edges.length);
    es[eMerge] = true;
    selSetEditEdge(m, "M", SetEditMode.add, es);

    // Both halves of the pre-op image, asserted rather than assumed: a cell
    // that reads a post-undo red must be able to rule out "the stand never had
    // it" and "the stand always had it" without re-deriving either.
    assert(m.edgeSetMask.get(edgeKeyOf(0, vCoin), 0UL) != 0,
           "makeTaggedGridWeldSets: the merge-case edge is not a member");
    assert(m.edgeSetMask.get(edgeKeyOf(0, 1), 0UL) == 0,
           "makeTaggedGridWeldSets: the SURVIVOR edge (0,1) is ALREADY a "
         ~ "member — the spurious half of the loss would then be invisible");

    // Inherited, and asserted so the parent cannot weaken this stand quietly.
    assert(m.vertexSetMask.length > vCoin && m.vertexSetMask[vCoin] != 0,
           "makeTaggedGridWeldSets: the parent no longer puts the WELDED "
         ~ "vertex in a named vertex set, so this stand covers only the "
         ~ "orphan/drop case the parent already covered");

    return m;
}

/// The edge-set registry's key, spelled once here so the stand and its cells
/// agree with the registry rather than with each other.
private ulong edgeKeyOf(uint a, uint b)
{
    import mesh : edgeKey;
    return edgeKey(a, b);
}
