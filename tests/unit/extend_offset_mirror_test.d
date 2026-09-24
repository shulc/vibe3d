// EDGE EXTEND UNDER SYMMETRY — the kernel's offset mirror (task 7118).
//
// `extendEdgesByMask` takes an `ExtendOffsetMirror`: no mirrored copies, but a
// ring vertex whose SOURCE vertex lies on the side the activating press latched
// takes the offset as is, one on the other side takes it reflected about the
// plane, and one exactly on the plane takes it with the normal component zeroed
// (capture laws: gap 172 / 209, cells C2-sym-*, C2-sym-0, C2-sym-sel M-press;
// public fixture tests/fixtures/edge_extend_gesture_laws.json). The cells here
// drive the kernel directly on the capture rig: an open 2x2 plane in XY with
// vertex index (x+1)*3+(y+1), offset o = (0.105, 0, 0).
module tests.unit.extend_offset_mirror_test;

import std.format : format;
import std.math : abs;
import math : Vec3;
import mesh : Mesh, MeshEditBatch, edgeKey;
import mesh_ops.extrude : extendEdgesByMask, ExtendOffsetMirror, kExtrudeEditScope;

private enum float kO = 0.105f;

private Mesh planeRig() {
    Mesh m;
    foreach (xi; 0 .. 3) foreach (yi; 0 .. 3)
        m.addVertex(Vec3(xi - 1.0f, yi - 1.0f, 0));
    uint at(int x, int y) { return cast(uint)((x + 1) * 3 + (y + 1)); }
    foreach (x; -1 .. 1) foreach (y; -1 .. 1)
        m.addFace([at(x, y), at(x + 1, y), at(x + 1, y + 1), at(x, y + 1)]);
    m.buildLoops();
    return m;
}

// A one-quad strip whose left edge sits at x = `x0`.
private Mesh stripRig(float x0) {
    Mesh m;
    m.addVertex(Vec3(x0, 0, 0)); m.addVertex(Vec3(x0, 1, 0));
    m.addVertex(Vec3(x0 + 1, 1, 0)); m.addVertex(Vec3(x0 + 1, 0, 0));
    m.addFace([0u, 3u, 2u, 1u]);
    m.buildLoops();
    return m;
}

private bool[] maskOf(ref Mesh m, uint[2][] pairs) {
    auto mask = new bool[](m.edges.length);
    foreach (p; pairs) {
        auto e = edgeKey(p[0], p[1]) in m.edgeIndexMap;
        assert(e !is null, format("rig: edge (%d,%d) missing", p[0], p[1]));
        mask[*e] = true;
    }
    return mask;
}

private Vec3[] extendNew(ref Mesh m, bool[] mask, ExtendOffsetMirror mirror,
                         bool passMirror = true) {
    immutable before = m.vertices.length;
    auto ed = MeshEditBatch.unrecorded(m, kExtrudeEditScope);
    immutable n = passMirror
        ? ed.extendEdgesByMask(mask, 0, 0, Vec3(kO, 0, 0), Vec3(0, 0, 0),
                               Vec3(1, 1, 1), 1, Vec3(0, 0, 0), mirror)
        : ed.extendEdgesByMask(mask, 0, 0, Vec3(kO, 0, 0), Vec3(0, 0, 0),
                               Vec3(1, 1, 1), 1, Vec3(0, 0, 0));
    ed.close();
    assert(n > 0, "rig: the kernel extended nothing");
    return m.vertices[before .. $].dup;
}

private ExtendOffsetMirror symX(int pressSide) {
    ExtendOffsetMirror mm;
    mm.enabled = true;
    mm.planePoint = Vec3(0, 0, 0);
    mm.planeNormal = Vec3(1, 0, 0);
    mm.pressSide = pressSide;
    return mm;
}

// Every new vertex has x == want (+-tol); the population is pinned first.
private void allX(Vec3[] nv, size_t count, float want, float tol, string what) {
    assert(nv.length == count, format("%s: %d new vertices, expected %d",
        what, nv.length, count));
    foreach (v; nv)
        assert(abs(v.x - want) <= tol,
            format("%s: new vertex x %.7f, expected %.7f", what, v.x, want));
}

unittest { // pressSide -1 (the CAP-2 cells' press side): +X reflected, -X as is
    auto m = planeRig();
    allX(extendNew(m, maskOf(m, [[6u, 7u], [7u, 8u]]), symX(-1)), 3,
         1 - kO, 1e-6f, "+X ridge, press -X");
    auto n = planeRig();
    allX(extendNew(n, maskOf(n, [[0u, 1u], [1u, 2u]]), symX(-1)), 3,
         -1 + kO, 1e-6f, "-X ridge, press -X");
}

unittest { // pressSide +1 (C2-sym-sel M-press): +X as is, -X reflected
    auto m = planeRig();
    allX(extendNew(m, maskOf(m, [[6u, 7u], [7u, 8u]]), symX(+1)), 3,
         1 + kO, 1e-6f, "+X ridge, press +X");
    auto n = planeRig();
    allX(extendNew(n, maskOf(n, [[0u, 1u], [1u, 2u]]), symX(+1)), 3,
         -1 - kO, 1e-6f, "-X ridge, press +X");
}

unittest { // on-plane vertex (C2-sym-0): the normal component is zeroed, either press side
    foreach (side; [-1, +1]) {
        auto m = planeRig();
        auto nv = extendNew(m, maskOf(m, [[5u, 8u]]), symX(side));
        assert(nv.length == 2, format("on-plane rig: %d new vertices", nv.length));
        size_t onPlane;
        foreach (v; nv) if (abs(v.y - 1) <= 1e-6f && abs(v.x) <= 1e-7f) ++onPlane;
        assert(onPlane == 1, format("on-plane vertex offset not zeroed (press %+d): %s",
            side, nv));
    }
}

unittest { // near-plane cells: no band, the sign law holds at x = +-1e-4
    {
        auto m = stripRig(1e-4f);
        allX(extendNew(m, maskOf(m, [[0u, 1u]]), symX(-1)), 2,
             1e-4f - kO, 1e-6f, "x = +1e-4 (reflected)");
    }
    {
        auto m = stripRig(-1e-4f);
        allX(extendNew(m, maskOf(m, [[0u, 1u]]), symX(-1)), 2,
             -1e-4f + kO, 1e-6f, "x = -1e-4 (as is)");
    }
}

unittest { // ExtendOffsetMirror.init is the pre-symmetry kernel, bit for bit
    auto a = planeRig();
    auto b = planeRig();
    auto mask = maskOf(a, [[6u, 7u], [7u, 8u], [0u, 1u]]);
    auto withInit = extendNew(a, mask, ExtendOffsetMirror.init);
    auto without = extendNew(b, mask.dup, ExtendOffsetMirror.init, false);
    assert(withInit.length == 5 && without.length == 5,
        format("init rig: %d / %d new vertices", withInit.length, without.length));
    assert(withInit == without, "ExtendOffsetMirror.init changed the kernel's output");
    assert(a.vertices == b.vertices && a.faces == b.faces,
        "ExtendOffsetMirror.init changed the mesh");
}
