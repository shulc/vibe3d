// mesh_selsets — polygon-domain topology carry (task 1060, Stage 5c).
//
// `faceSetMask` must follow its face through every kernel that carries
// `facePart` (the site list IS `grep facePart`, per the task plan). This
// pins the carry across a representative sample of those kernels — a
// compaction (deleteFacesByMask), a vertex-count-reducing reshape
// (dissolveVerticesByMask) and a weld (weldVertexPairs) — by CENTROID, not
// index: every one of these kernels renumbers surviving faces, so an
// index-based assertion cannot tell "still correct" from "still stale".
module tests.unit.mesh_selsets_polygon_carry_test;

import math : Vec3;
import mesh;
import mesh_selsets;

private size_t faceByCentroid(ref Mesh m, Vec3 target, double tol = 1e-4) {
    foreach (fi; 0 .. m.faces.length) {
        Vec3 c = Vec3(0, 0, 0);
        auto f = m.faces[fi];
        foreach (vid; f) c = c + m.vertices[vid];
        c = Vec3(c.x / f.length, c.y / f.length, c.z / f.length);
        if ((c - target).length < tol) return fi;
    }
    assert(false, "no surviving face at the expected centroid");
}

private Vec3 centroidOf(ref Mesh m, size_t fi) {
    Vec3 c = Vec3(0, 0, 0);
    auto f = m.faces[fi];
    foreach (vid; f) c = c + m.vertices[vid];
    return Vec3(c.x / f.length, c.y / f.length, c.z / f.length);
}

private bool hasSet(ref Mesh m, size_t fi) {
    return (fi < m.faceSetMask.length) && (m.faceSetMask[fi] & 1UL) != 0;
}

unittest { // topology matrix: delete an unrelated face
    Mesh m = makeCube();
    m.syncSelection();

    immutable size_t tracked = 2;
    Vec3 wantCentroid = centroidOf(m, tracked);
    m.selectFace(cast(int) tracked);
    selSetEditPolygon(m, "S", SetEditMode.replace, m.selectedFaces);
    assert(hasSet(m, tracked));

    // Delete an unrelated face (index 0, distinct from `tracked`). Its own
    // survivors shift index — the whole point of tracking by centroid.
    bool[] mask = new bool[](m.faces.length);
    mask[0] = true;
    assert(tracked != 0);
    immutable size_t removed = m.deleteFacesByMask(mask);
    assert(removed == 1);

    immutable size_t survivor = faceByCentroid(m, wantCentroid);
    assert(survivor != tracked, "the face DID shift index — that's the point");
    assert(hasSet(m, survivor),
        "deleteFacesByMask: the tracked face's set membership must follow it");
    foreach (fi; 0 .. m.faces.length)
        if (fi != survivor)
            assert(!hasSet(m, fi), "no OTHER face may have picked up the bit");
}

unittest { // topology matrix: dissolve an unrelated vertex
    Mesh m = makeCube();
    m.syncSelection();

    immutable size_t tracked = 2;
    Vec3 wantCentroid = centroidOf(m, tracked);
    m.selectFace(cast(int) tracked);
    selSetEditPolygon(m, "S", SetEditMode.replace, m.selectedFaces);

    // Pick a vertex NOT on the tracked face — dissolving it reshapes its
    // OWN incident faces (quad -> triangle) but must not touch `tracked`.
    bool[] onTracked = new bool[](m.vertices.length);
    foreach (vid; m.faces[tracked]) onTracked[vid] = true;
    size_t victim = size_t.max;
    foreach (vi; 0 .. m.vertices.length) if (!onTracked[vi]) { victim = vi; break; }
    assert(victim != size_t.max, "cube fixture: every vertex touches the tracked face?!");

    bool[] vmask = new bool[](m.vertices.length);
    vmask[victim] = true;
    immutable size_t dissolved = m.dissolveVerticesByMask(vmask);
    assert(dissolved == 1);

    immutable size_t survivor = faceByCentroid(m, wantCentroid);
    assert(hasSet(m, survivor),
        "dissolveVerticesByMask: the tracked face's set membership must follow it");
}

unittest { // topology matrix: weld two unrelated vertices
    Mesh m = makeCube();
    m.syncSelection();

    immutable size_t tracked = 2;
    Vec3 wantCentroid = centroidOf(m, tracked);
    m.selectFace(cast(int) tracked);
    selSetEditPolygon(m, "S", SetEditMode.replace, m.selectedFaces);

    // Weld two ADJACENT corners of a face that shares NO vertex with
    // `tracked` (the shared-face rule requires adjacency — see
    // Mesh.weldVertexPairs's doc comment — and disjointness is what keeps
    // this weld from moving one of the TRACKED face's own corners, which
    // would legitimately move its centroid for a reason that has nothing
    // to do with the carry under test).
    bool[] onTrackedV = new bool[](m.vertices.length);
    foreach (vid; m.faces[tracked]) onTrackedV[vid] = true;
    size_t other = size_t.max;
    foreach (fi; 0 .. m.faces.length) {
        if (fi == tracked) continue;
        bool disjoint = true;
        foreach (vid; m.faces[fi]) if (onTrackedV[vid]) { disjoint = false; break; }
        if (disjoint) { other = fi; break; }
    }
    assert(other != size_t.max, "cube fixture: no face disjoint from `tracked`?!");
    auto of = m.faces[other];
    assert(of.length >= 2);
    immutable size_t welded = m.weldVertexPairs([[of[0], of[1]]]);
    assert(welded == 1);

    immutable size_t survivor = faceByCentroid(m, wantCentroid);
    assert(hasSet(m, survivor),
        "weldVertexPairs: the tracked face's set membership must follow it");
}

// ---------------------------------------------------------------------------
// Mutation proof, run by substitution (not asserted here — see the fork
// report): commenting out the `faceSetMask = keptSetMask;` line in
// `Mesh.deleteFacesByMask` (source/mesh.d) reddens the first unittest above
// — the survivor reads back with NO set membership, because the carry that
// gathers `faceSetMask` in lock-step with `facePart`/`faceMaterial` never
// ran.
// ---------------------------------------------------------------------------
