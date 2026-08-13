// test_uv_undo_delta.d — what an undo/redo DELTA replay does to the per-corner
// (PolyVertex) map, task 0689.
//
// Pure-D unit test (no HTTP, no running vibe3d): builds a mesh with a UV map
// authored so that every corner's value NAMES ITS OWN IDENTITY (u = 1 + the
// vertex the corner stands on, v = 1 + the face it belongs to), replays a
// MeshEditDelta over it, and asks one question of every corner: is the value
// you carry yours?
//
// The distinction the whole task turns on:
//
//   * a DROP (value 0) is a documented limitation — mesh.d's "v1 DROP set".
//     The delta carries no map values (MeshOpEntry.Kind.MeshMapDelta is still
//     a stub), so a replay that renumbers corners has nothing to restore.
//   * a value that belongs to a DIFFERENT corner is silent corruption, and
//     that is what a replay produced before task 0689: `resizePolyVertexMaps`
//     (hung off buildLoops) KEEPS a map whose length already matches, so a
//     batch that renumbers corners without changing their TOTAL left every
//     value in place while the faces beneath it moved.
//
// So the assertions below accept "0" or "mine" and reject "someone else's".
// They are therefore ALSO the acceptance test for the expensive half of the
// fork: if MeshMapDelta is ever implemented, the restored values are "mine"
// and these tests keep passing unchanged (only the DOCUMENTED-LIMIT test at
// the bottom, which pins the drop itself, would flip).

import std.conv : to;

import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
import math : Vec3;
import mesh_edit_delta : MeshEditDelta, MeshEditTracker, MeshOpEntry, MeshEditScope;

void main() {}

// The corner's identity, keyed on the vertex POSITION — never on its index.
// A delete compacts unreferenced vertices, so index-keyed identity would read
// as "moved" after a perfectly correct relocate. Every fixture vertex sits on
// integer x/y, so the key is exact in float and unique per vertex, and it is
// never 0 (so a DROP stays distinguishable from a wrong value).
private float cornerKey(Vec3 p) { return 1.0f + p.x * 10.0f + p.y; }

// u = the corner's identity key, v = 1 + face index (recorded for eyeballing;
// not asserted — a replay may legitimately restore faces in another ORDER).
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
// Face ORDER and vertex INDICES are both allowed to move (a replay legitimately
// restores faces in another order, and a delete compacts vertices) — the key is
// the vertex position, so it survives both.
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

// ---------------------------------------------------------------------------
// THE DEFECT (task 0689). A corner-count-NEUTRAL replay: drop face 0, append a
// face of the same arity. The corner TOTAL is unchanged (9 before, 9 after), so
// resizePolyVertexMaps sees a length-correct map and keeps every value — while
// the faces underneath have all moved one slot. Before the fix, face 0 (which
// is now the old triangle 1) reads the old triangle 0's UV.
//
// Hand-built rather than driven through a kernel deliberately: no kernel wired
// to the tracker today emits a corner-count-neutral batch (measured — delete,
// edge-dissolve, vertex-dissolve, edge-extrude and edge-extend all change the
// corner total, so today they land in the drop branch). This entry PAIR is a
// shape the recorder already emits (`removeEdgesByMask` records exactly
// RemoveFaces+AddFaces); only the arity arithmetic keeps live callers off the
// neutral case, and nothing in the code enforces that. So the test pins the
// REPLAY's contract, which is where the invariant belongs.
// ---------------------------------------------------------------------------
unittest {
    auto m = threeTriangles();

    MeshOpEntry rem;
    rem.kind      = MeshOpEntry.Kind.RemoveFaces;
    rem.fIdx      = [0u];
    rem.faceLists = [[0u, 1u, 2u]];
    rem.faceMat   = [0u];
    rem.facePrt   = [0u];
    rem.faceSub   = [0u];

    MeshOpEntry add;
    add.kind      = MeshOpEntry.Kind.AddFaces;
    add.fIdx      = [2u];                 // tail append, after the drop
    add.faceLists = [[0u, 1u, 2u]];       // the same triangle, now LAST

    MeshEditDelta d;
    d.scope_ = MeshEditScope.Geometry;
    d.log    = [rem, add];

    assert(d.apply(m));
    assert(m.faces.length == 3, "the count-neutral replay must keep three faces");
    assert(m.loops.length == 9, "…and nine corners — otherwise the length test "
        ~ "would have caught the renumbering and this fixture proves nothing");
    assertNoForeignCorner(m, "count-neutral forward replay");

    // The same must hold on the way back (revert runs the log LIFO: truncate
    // the appended face, re-insert the dropped one — neutral again).
    assert(d.revert(m));
    assert(m.loops.length == 9);
    assertNoForeignCorner(m, "count-neutral reverse replay");
}

// ---------------------------------------------------------------------------
// SELECTIVITY 1 — a replay that touches no faces must NOT drop the map. Without
// this, "drop whenever a delta replays" would pass the test above while
// throwing away UV that was never in danger.
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
// this corner's own values; dropping here would lose UV the kernel preserved.
//
// The corner's VERTEX changes, so `u` (= 1 + vertex) is checked against the
// PRE-replay vertex on purpose: the value must still be the one authored for
// this slot.
// ---------------------------------------------------------------------------
unittest {
    auto m = threeTriangles();
    m.addVertex(Vec3(9, 9, 0));                 // a spare vertex to repoint at
    const uint spare = cast(uint)(m.vertices.length - 1);
    auto before = m.meshMap(kUvMapName).data.dup;

    MeshOpEntry rs;
    rs.kind            = MeshOpEntry.Kind.ReshapeFaces;
    rs.fIdx            = [0u];
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
// DOCUMENTED LIMIT (task 0689's open fork). A real kernel run: delete a face
// inside an edit batch, then undo. The kernel's FORWARD path carries the UV
// correctly (deleteFacesByMask relocates through remapPolyVertexMaps) — the
// undo does not, because the delta stores no map values. The map comes back
// length-correct and ZEROED: UV work is LOST by a plain Ctrl+Z.
//
// This is the assertion to flip if the owner picks the expensive half of the
// fork (implement MeshMapDelta): it would then read "restored", and the
// no-foreign-corner assertions above would keep passing untouched.
// Note the snapshot path does NOT have this limitation — MeshSnapshot captures
// meshMaps — so `VIBE3D_UNDO_TRACKER=off` round-trips the UV today.
// ---------------------------------------------------------------------------
unittest {
    auto m = threeTriangles();

    bool[] fmask;
    fmask.length = m.faces.length;
    fmask[1] = true;

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    m.deleteFacesByMask(fmask);
    auto d = m.endEditBatch();
    assert(!d.isEmpty, "the delete must have recorded a delta");

    // Forward (the kernel's own path): the surviving corners keep their values.
    assertNoForeignCorner(m, "after delete");
    auto post = m.meshMap(kUvMapName);
    bool anyKept = false;
    foreach (v; post.data) if (v != 0.0f) { anyKept = true; break; }
    assert(anyKept, "deleteFacesByMask is supposed to RELOCATE the per-corner "
        ~ "map, not drop it — if this fires, the forward carry regressed");

    assert(d.revert(m));
    assertNoForeignCorner(m, "after delete + undo");
    auto back = m.meshMap(kUvMapName);
    assert(back.data.length == m.loops.length * 2);
    foreach (i, v; back.data)
        assert(v == 0.0f,
            "DOCUMENTED LIMIT (task 0689): an undo replay carries no per-corner "
            ~ "values, so the map comes back zeroed; slot " ~ i.to!string
            ~ " reads " ~ v.to!string ~ ". If MeshMapDelta was implemented, "
            ~ "update this assertion to expect the restored values.");
}

// ---------------------------------------------------------------------------
// A mesh with NO per-corner map must be unaffected by all of the above (and
// must not crash) — the drop path has to be a no-op, not a null dereference.
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
