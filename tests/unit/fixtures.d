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
