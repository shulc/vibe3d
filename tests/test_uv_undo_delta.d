// test_uv_undo_delta.d — what an undo/redo DELTA replay does to the per-corner
// (PolyVertex) map, task 0689.
//
// Pure-D unit test (no HTTP, no running vibe3d): builds a mesh with a UV map
// authored so that every corner's value NAMES ITS OWN IDENTITY (u = a key
// derived from the vertex the corner stands on, v = 1 + the face it belongs
// to), replays a MeshEditDelta over it, and asks one question of every corner:
// is the value you carry yours?
//
// Three outcomes are distinguishable, and the whole task turns on the
// difference:
//
//   * MINE — the corner carries the value authored for it. This is what the
//     delta owes after task 0689: `MeshOpEntry.Kind.MeshMapDelta` is a real
//     channel now, so a replay relocates the corners that survive it and
//     restores from the delta the corners of faces it re-creates.
//   * ZERO — a drop. Legitimate ONLY for a corner with no source in either
//     state (a brand-new face) or for a delta that carries no payload; the
//     tests below say which of the two they expect.
//   * SOMEONE ELSE'S — silent corruption, and what a replay produced before
//     task 0689: `resizePolyVertexMaps` (hung off buildLoops) KEEPS a map
//     whose length already matches, so a batch that renumbered corners
//     without changing their TOTAL left every value in place while the faces
//     beneath it moved.
//
// `assertNoForeignCorner` accepts MINE or ZERO and rejects the third;
// `assertEveryCornerMine` is the stronger form that also rejects ZERO, and is
// what the restore path is pinned with.

import std.conv : to;

import mesh : Mesh, MeshMap, MapDomain, kUvMapName, FaceIdx;
import math : Vec3;
import mesh_edit_delta : MeshEditDelta, MeshEditTracker, MeshOpEntry, MeshEditScope;

void main() {}

// The corner's identity, keyed on the vertex POSITION — never on its index.
// A delete compacts unreferenced vertices, so index-keyed identity would read
// as "moved" after a perfectly correct relocate. Every fixture vertex sits on
// integer x/y, so the key is exact in float and unique per vertex, and it is
// never 0 (so a DROP stays distinguishable from a wrong value).
private float cornerKey(Vec3 p) { return 1.0f + p.x * 10.0f + p.y; }

// u = the corner's identity key, v = 1 + face index. The two `assert*Corner*`
// helpers below read `u` only — they are deliberately order-agnostic, because a
// forward replay legitimately re-slots faces (a merge appends). `v` is what the
// byte-exact whole-buffer comparisons in the UNDO cases pin, and since task
// 0703 an undo does owe the pre-op face order, so those comparisons hold `v`
// to it.
private void authorUV(ref Mesh m) {
    auto map = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(map !is null, "UV map registration failed");
    foreach (fi; 0 .. m.faces.length)
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t slot = (m.faceLoop[fi] + c) * 2;
            map.data[slot]     = cornerKey(m.vertices[m.faces[fi][c]]);
            map.data[slot + 1] = 1.0f + fi;
        }
}

// Every corner must carry either nothing (a drop) or its OWN authored value.
// Face ORDER and vertex INDICES are both allowed to move (a forward replay
// re-slots faces, and a delete compacts vertices) — the key is the vertex
// position, so it survives both. Where the ORDER is also owed, the caller adds
// `assertFaceOrderRestored` / a whole-buffer comparison; this helper stays the
// weaker, order-free question on purpose.
private void assertNoForeignCorner(ref Mesh m, string what) {
    auto map = m.meshMap(kUvMapName);
    assert(map !is null, what ~ ": the UV map disappeared entirely");
    assert(map.data.length == m.loops.length * 2,
        what ~ ": UV map length " ~ map.data.length.to!string
        ~ " does not match " ~ (m.loops.length * 2).to!string ~ " corner slots");
    foreach (fi; 0 .. m.faces.length)
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t slot = (m.faceLoop[fi] + c) * 2;
            const float u    = map.data[slot];
            const Vec3  p    = m.vertices[m.faces[fi][c]];
            const float mine = cornerKey(p);
            assert(u == 0.0f || u == mine,
                what ~ ": face " ~ fi.to!string ~ " corner " ~ c.to!string
                ~ " (vertex at " ~ p.x.to!string ~ "," ~ p.y.to!string ~ ","
                ~ p.z.to!string ~ ") carries u=" ~ u.to!string
                ~ " but its own value is " ~ mine.to!string
                ~ " — a per-corner value landed on a foreign corner");
        }
}

// The strong form: EVERY corner carries its own value. Zero is a failure here.
// This is the assertion a "length-correct but zeroed" map cannot pass, so it is
// the one that separates "the delta carries per-corner maps" from "the delta
// happens not to corrupt them".
private void assertEveryCornerMine(ref Mesh m, string what) {
    auto map = m.meshMap(kUvMapName);
    assert(map !is null, what ~ ": the UV map disappeared entirely");
    assert(map.data.length == m.loops.length * 2,
        what ~ ": UV map length " ~ map.data.length.to!string
        ~ " does not match " ~ (m.loops.length * 2).to!string ~ " corner slots");
    foreach (fi; 0 .. m.faces.length)
        foreach (c; 0 .. m.faces[fi].length) {
            const size_t slot = (m.faceLoop[fi] + c) * 2;
            const float u    = map.data[slot];
            const Vec3  p    = m.vertices[m.faces[fi][c]];
            const float mine = cornerKey(p);
            assert(u == mine,
                what ~ ": face " ~ fi.to!string ~ " corner " ~ c.to!string
                ~ " (vertex at " ~ p.x.to!string ~ "," ~ p.y.to!string ~ ","
                ~ p.z.to!string ~ ") carries u=" ~ u.to!string
                ~ ", expected its own " ~ mine.to!string
                ~ (u == 0.0f
                    ? " — the replay DROPPED a corner it holds the value for"
                    : " — a per-corner value landed on a foreign corner"));
        }
}

// Face-for-face vertex-list identity, positional. The map assertions below are
// byte-exact against the pre-op buffer, which only means anything if the faces
// under it came back in the SAME ORDER — assert that separately so a future
// order regression names itself instead of surfacing as "the UV moved".
private void assertFaceOrderRestored(ref Mesh m, const uint[][] preFaces,
                                     string what) {
    assert(m.faces.length == preFaces.length,
        what ~ ": face count changed (" ~ m.faces.length.to!string ~ " vs "
        ~ preFaces.length.to!string ~ ")");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == preFaces[fi],
            what ~ ": face " ~ fi.to!string ~ " came back as "
            ~ m.faces[fi].to!string ~ ", expected " ~ preFaces[fi].to!string
            ~ " — the face ORDER is the key selection / faceMaterial / facePart "
            ~ "/ the per-corner maps all hang off");
}

// Three disconnected triangles: every face has the SAME arity, so a replay can
// permute them without changing the corner total — exactly the shape that
// slips past resizePolyVertexMaps' length test.
private Mesh threeTriangles() {
    Mesh m;
    foreach (t; 0 .. 3) {
        m.addVertex(Vec3(10.0f * t + 0, 0, 0));
        m.addVertex(Vec3(10.0f * t + 1, 0, 0));
        m.addVertex(Vec3(10.0f * t + 0, 1, 0));
    }
    m.addFace([0, 1, 2]);
    m.addFace([3, 4, 5]);
    m.addFace([6, 7, 8]);
    m.rebuildEdges();
    m.buildLoops();
    m.syncSelection();
    authorUV(m);
    return m;
}

// Two triangles sharing edge (1,2) — the fixture for an edge dissolve, which
// merges them into one quad and must be able to put both back.
private Mesh twoTriangleStrip() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addFace([0, 1, 2]);
    m.addFace([1, 3, 2]);
    m.rebuildEdges();
    m.buildLoops();
    m.syncSelection();
    authorUV(m);
    return m;
}

// One quad — the fixture for a vertex dissolve, which shrinks it to a triangle
// (an ARITY-CHANGING ReshapeFaces) and must be able to put the fourth corner
// back with its own value.
private Mesh oneQuad() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0, 1, 2, 3]);
    m.rebuildEdges();
    m.buildLoops();
    m.syncSelection();
    authorUV(m);
    return m;
}

// ---------------------------------------------------------------------------
// THE DEFECT (task 0689). A corner-count-NEUTRAL replay: drop face 0, append a
// face of the same arity. The corner TOTAL is unchanged (9 before, 9 after), so
// resizePolyVertexMaps sees a length-correct map and keeps every value — while
// the faces underneath have all moved one slot. Before the fix, face 0 (which
// is now the old triangle 1) read the old triangle 0's UV.
//
// Hand-built rather than driven through a kernel deliberately: no kernel wired
// to the tracker today emits a corner-count-neutral batch (measured — delete,
// edge-dissolve, vertex-dissolve, edge-extrude and edge-extend all change the
// corner total). This entry PAIR is a shape the recorder already emits
// (`removeEdgesByMask` records exactly RemoveFaces+AddFaces); only the arity
// arithmetic keeps live callers off the neutral case, and nothing in the code
// enforces that. So the test pins the REPLAY's contract, which is where the
// invariant belongs.
//
// No map payload is attached here, so the appended face (forward) and the
// re-inserted one (reverse) are entitled to come back ZERO — what must NOT
// happen is the surviving triangles wearing each other's UV.
// ---------------------------------------------------------------------------
unittest {
    auto m = threeTriangles();

    MeshOpEntry rem;
    rem.kind      = MeshOpEntry.Kind.RemoveFaces;
    rem.fIdx      = [FaceIdx.assumeFaceSpace(0)];
    rem.faceLists = [[0u, 1u, 2u]];
    rem.faceMat   = [0u];
    rem.facePrt   = [0u];
    rem.faceSub   = [0u];

    MeshOpEntry add;
    add.kind      = MeshOpEntry.Kind.AddFaces;
    add.fIdx      = [FaceIdx.assumeFaceSpace(2)];                 // tail append, after the drop
    add.faceLists = [[0u, 1u, 2u]];       // the same triangle, now LAST

    MeshEditDelta d;
    d.scope_ = MeshEditScope.Geometry;
    d.log    = [rem, add];

    assert(d.apply(m));
    assert(m.faces.length == 3, "the count-neutral replay must keep three faces");
    assert(m.loops.length == 9, "…and nine corners — otherwise the length test "
        ~ "would have caught the renumbering and this fixture proves nothing");
    assertNoForeignCorner(m, "count-neutral forward replay");
    // The two SURVIVING triangles must have brought their values with them —
    // they are now at face indices 0 and 1. Accepting a blanket drop here would
    // let the pre-0689 "zero everything" fallback pass this test.
    auto fwd = m.meshMap(kUvMapName);
    foreach (fi; 0 .. 2)
        foreach (c; 0 .. m.faces[fi].length)
            assert(fwd.data[(m.faceLoop[fi] + c) * 2]
                   == cornerKey(m.vertices[m.faces[fi][c]]),
                "a face the replay only MOVED must keep its per-corner values");

    // The same must hold on the way back (revert runs the log LIFO: truncate
    // the appended face, re-insert the dropped one — neutral again).
    assert(d.revert(m));
    assert(m.loops.length == 9);
    assertNoForeignCorner(m, "count-neutral reverse replay");
}

// ---------------------------------------------------------------------------
// THE CHANNEL (task 0689), hand-built. The same count-neutral pair, but with a
// `MeshMapDelta` payload in front of the RemoveFaces — the shape
// `Mesh.recordPolyVertexPayload` emits. On revert, the re-inserted face must
// come back with the values the payload carries, not with zeros.
//
// This is the test that would keep passing if `MeshMapDelta` went back to being
// a `break; // deferred` stub in name only: it asserts the payload is READ.
// ---------------------------------------------------------------------------
unittest {
    auto m = threeTriangles();

    // The values face 0 will be carrying when it is dropped — captured here the
    // same way the recorder captures them (corner-major, one map, dim 2).
    float[] vals;
    foreach (c; 0 .. 3) {
        vals ~= cornerKey(m.vertices[m.faces[0][c]]);
        vals ~= 1.0f;
    }

    MeshOpEntry pay;
    pay.kind     = MeshOpEntry.Kind.MeshMapDelta;
    pay.mapDims  = [cast(ubyte)2];
    pay.mapArity = [3u];
    pay.mapVals  = vals;

    MeshOpEntry rem;
    rem.kind      = MeshOpEntry.Kind.RemoveFaces;
    rem.fIdx      = [FaceIdx.assumeFaceSpace(0)];
    rem.faceLists = [[0u, 1u, 2u]];
    rem.faceMat   = [0u];
    rem.facePrt   = [0u];
    rem.faceSub   = [0u];

    MeshEditDelta d;
    d.scope_ = MeshEditScope.Geometry;
    d.log    = [pay, rem];

    assert(d.apply(m));
    assert(m.faces.length == 2, "the drop must have landed");
    assertEveryCornerMine(m, "payload replay, forward (survivors relocate)");

    assert(d.revert(m));
    assert(m.faces.length == 3, "the dropped face must be back");
    assertEveryCornerMine(m,
        "payload replay, reverse — the re-inserted face must take its values "
        ~ "from the MeshMapDelta payload");
}

// ---------------------------------------------------------------------------
// SELECTIVITY 1 — a replay that touches no faces must NOT disturb the map.
// Without this, "drop whenever a delta replays" would pass the tests above
// while throwing away UV that was never in danger.
// ---------------------------------------------------------------------------
unittest {
    auto m = threeTriangles();
    auto before = m.meshMap(kUvMapName).data.dup;

    MeshOpEntry mv;
    mv.kind      = MeshOpEntry.Kind.SetPos;
    mv.vIdx      = [1u];
    mv.posBefore = [m.vertices[1]];
    mv.posAfter  = [Vec3(1, 0, 0.5f)];

    MeshEditDelta d;
    d.scope_ = MeshEditScope.Position;
    d.log    = [mv];

    assert(d.apply(m));
    assert(m.meshMap(kUvMapName).data == before,
        "a position-only replay renumbers no corner — the per-corner map must "
        ~ "come through byte-identical, not be dropped");
    assert(d.revert(m));
    assert(m.meshMap(kUvMapName).data == before,
        "…and the same on revert");
}

// ---------------------------------------------------------------------------
// SELECTIVITY 2 — an EQUAL-ARITY ReshapeFaces (the extrude/inset "repoint this
// neighbour at its new inset vertex" shape) keeps each corner's slot AND its
// count. Per-corner values are addressed by (face, corner), so they are still
// this corner's own values; dropping OR vertex-matching here would lose UV the
// kernel preserved.
//
// The corner's VERTEX changes, so `u` (= the key of the PRE-replay vertex) is
// checked against the pre-replay data on purpose: the value must still be the
// one authored for this slot.
// ---------------------------------------------------------------------------
unittest {
    auto m = threeTriangles();
    m.addVertex(Vec3(9, 9, 0));                 // a spare vertex to repoint at
    const uint spare = cast(uint)(m.vertices.length - 1);
    auto before = m.meshMap(kUvMapName).data.dup;

    MeshOpEntry rs;
    rs.kind            = MeshOpEntry.Kind.ReshapeFaces;
    rs.fIdx            = [FaceIdx.assumeFaceSpace(0)];
    rs.faceListsBefore = [[0u, 1u, 2u]];
    rs.faceListsAfter  = [[0u, 1u, spare]];     // same arity, one corner repointed

    MeshEditDelta d;
    d.scope_ = MeshEditScope.Geometry;
    d.log    = [rs];

    assert(d.apply(m));
    assert(m.faces[0][2] == spare, "the reshape did not land");
    assert(m.meshMap(kUvMapName).data == before,
        "an equal-arity reshape moves no corner slot — the per-corner map must "
        ~ "survive it intact");
    assert(d.revert(m));
    assert(m.meshMap(kUvMapName).data == before,
        "…and the same on revert");
}

// ---------------------------------------------------------------------------
// DELETE POLYGONS — the live loss task 0689 was filed for. A real kernel run:
// delete a face inside an edit batch, then undo. The kernel's FORWARD path
// carries the UV correctly (deleteFacesByMask relocates through
// remapPolyVertexMaps); before this task the UNDO came back length-correct and
// ZEROED, so a plain Ctrl+Z ate every UV in the mesh — including the faces the
// delete never touched.
//
// Now the delta owes the map BYTE-FOR-BYTE: the replay restores the exact
// pre-op face and vertex index space, so the per-corner plane must land on it
// unchanged.
// ---------------------------------------------------------------------------
unittest {
    auto m = threeTriangles();
    auto pristine = m.meshMap(kUvMapName).data.dup;

    bool[] fmask;
    fmask.length = m.faces.length;
    fmask[1] = true;

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    m.deleteFacesByMask(fmask);
    auto d = m.endEditBatch();
    assert(!d.isEmpty, "the delete must have recorded a delta");

    // Forward (the kernel's own path): the surviving corners keep their values.
    assertEveryCornerMine(m, "after delete");

    // Undo.
    assert(d.revert(m));
    assert(m.faces.length == 3, "the deleted face must be back");
    assertEveryCornerMine(m, "after delete + undo");
    assert(m.meshMap(kUvMapName).data == pristine,
        "delete + undo must return the per-corner map byte-for-byte — the "
        ~ "delta restores the exact pre-op index space, so the map has to "
        ~ "land on it unchanged");

    // Redo through the delta (not through the kernel): the survivors relocate
    // again, and the deleted face's values stay in the delta for the next undo.
    assert(d.apply(m));
    assert(m.faces.length == 2, "the redo must have dropped the face again");
    assertEveryCornerMine(m, "after delete + undo + redo");
    assert(d.revert(m));
    assert(m.meshMap(kUvMapName).data == pristine,
        "…and a second undo must still return the map byte-for-byte (the "
        ~ "payload is not consumed by being read once)");
}

// ---------------------------------------------------------------------------
// DELETE EDGES — `removeEdgesByMask` merges the two faces around the dissolved
// edge into one, recording RemoveFaces (the two components, in the PRE-drop
// index space) + AddFaces (the merged quad, a tail append). Undo has to put
// both triangles back WITH their corner values, which live nowhere but the
// delta by then.
//
// BYTE-EXACT since task 0703. It was per-FACE (order-independent) up to then,
// and the reason was a PRE-EXISTING GEOMETRY defect this test walked into at
// 0689: `removeEdgesByMask` recorded the two dropped component faces at
// POST-drop index 0 — both of them — while `removeFacesReverse` inserts
// ascending at the recorded index, so undo returned them in the opposite ORDER
// ([f1, f0]). Nothing to do with per-corner maps; the map followed its faces
// faithfully, which is why the weaker per-face assertion passed. 0703 brought
// all three kernels onto the one PRE-drop space `removeFacesReverse` inverts,
// so the whole buffer must now come back identical.
// ---------------------------------------------------------------------------
unittest {
    auto m = twoTriangleStrip();
    auto pristine     = m.meshMap(kUvMapName).data.dup;
    auto preFaces     = new uint[][](m.faces.length);
    foreach (fi; 0 .. m.faces.length) preFaces[fi] = m.faces[fi].dup;
    auto preFaceLoop  = m.faceLoop.dup;

    // The shared edge is (1,2).
    bool[] emask;
    emask.length = m.edges.length;
    size_t hits = 0;
    foreach (ei; 0 .. m.edges.length) {
        const a = m.edges[ei][0], b = m.edges[ei][1];
        if ((a == 1 && b == 2) || (a == 2 && b == 1)) { emask[ei] = true; ++hits; }
    }
    assert(hits == 1, "the fixture must present exactly one shared edge");

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    const dissolved = m.removeEdgesByMask(emask);
    auto d = m.endEditBatch();
    assert(dissolved == 1, "the edge dissolve must have run");
    assert(m.faces.length == 1, "…and merged the two triangles into one poly");

    assert(d.revert(m));
    assert(m.faces.length == 2, "undo must put both triangles back");
    assertFaceOrderRestored(m, preFaces, "after edge dissolve + undo");
    assert(m.faceLoop == preFaceLoop,
        "after edge dissolve + undo: the corner layout must be the pre-op one");
    assertEveryCornerMine(m, "after edge dissolve + undo");
    assert(m.meshMap(kUvMapName).data == pristine,
        "edge dissolve + undo must return the per-corner map byte-for-byte — "
        ~ "tightened from the per-face check at task 0703, which fixed the "
        ~ "face-ORDER defect that forced the weaker assertion at 0689");
}

// ---------------------------------------------------------------------------
// DELETE VERTICES — `dissolveVerticesByMask` shortens the quad's corner list,
// recording an ARITY-CHANGING ReshapeFaces. That is the one entry kind whose
// corner slots genuinely move WITHIN a face, so it is the entry the payload
// matters most for: the dissolved corner's value cannot be recovered from the
// post-op map by any amount of matching.
// ---------------------------------------------------------------------------
unittest {
    auto m = oneQuad();
    auto pristine = m.meshMap(kUvMapName).data.dup;

    bool[] vmask;
    vmask.length = m.vertices.length;
    vmask[1] = true;                     // dissolve the corner at (1,0,0)

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    const n = m.dissolveVerticesByMask(vmask, /*keepOrphans=*/true);
    auto d = m.endEditBatch();
    assert(n == 1, "the vertex dissolve must have run");
    assert(m.faces[0].length == 3, "…and shortened the quad to a triangle");
    // Forward is the kernel's own mechanism (b) carry — the surviving three
    // corners keep their values.
    assertEveryCornerMine(m, "after vertex dissolve");

    assert(d.revert(m));
    assert(m.faces[0].length == 4, "undo must restore the quad");
    assertEveryCornerMine(m, "after vertex dissolve + undo");
    assert(m.meshMap(kUvMapName).data == pristine,
        "vertex dissolve + undo must return the per-corner map byte-for-byte — "
        ~ "including the dissolved corner, whose value exists only in the delta");

    // Redo THROUGH THE DELTA (MeshDelete re-runs the kernel instead, but the
    // replay owes the same answer): the forward arity-changing reshape has no
    // payload to read, so the three surviving corners can only keep their
    // values by being matched to the old corner standing on the SAME VERTEX.
    // This is the one assertion that exercises that match.
    assert(d.apply(m));
    assert(m.faces[0].length == 3, "the redo must shorten the quad again");
    assertEveryCornerMine(m,
        "after vertex dissolve + undo + redo — an arity-changing reshape "
        ~ "replayed FORWARD must match its corners by vertex");
}

// ---------------------------------------------------------------------------
// A mesh with NO per-corner map must be unaffected by all of the above (and
// must not crash) — the carry path has to be a no-op, not a null dereference.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeCube;
    Mesh m = makeCube();
    m.buildLoops();
    m.syncSelection();
    assert(m.meshMap(kUvMapName) is null, "makeCube should register no UV map");

    bool[] fmask;
    fmask.length = m.faces.length;
    fmask[0] = true;

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    m.deleteFacesByMask(fmask);
    auto d = m.endEditBatch();
    assert(d.revert(m));
    assert(m.meshMap(kUvMapName) is null, "no UV map should have appeared");
    assert(m.faces.length == 6, "the delete must have been undone");
}
