// mesh_thicken_surface_test -- `thickenSurface` closes a shell, on a full grid and on a holed one.
//
// Watertight is asserted by face count AND by `countOpenEdges` -- which
// travelled here with these blocks -- returning zero. The holed grid is the
// cell that separates `walk the outer boundary` from `walk EVERY boundary
// loop`; the full grid alone cannot.
//
// These blocks stood in the body of `struct Mesh` until task 3160 -- step 1
// of `doc/tasks/work/2910-mesh-struct-seams.md`, which took fifty `unittest`
// blocks out of a 16 782-line struct body. They are HERE rather than at
// module scope in `mesh.d` because they compile against `Mesh`'s PUBLIC API
// alone: the criterion `tests/unit/README.md` states and task 0706 set. The
// eighteen blocks that read a `private` name stayed behind under the same
// rule, at module scope in `mesh.d`. Bodies are byte-identical to what stood
// in the struct, dedented by four columns; the only edit is the member enum
// `Marks`, which is spelled `Mesh.Marks` outside the body.
//
// ONE PRIVATE FIXTURE TRAVELLED WITH THEM: `countOpenEdges` (the watertightness probe) was a
// `version (unittest) private` helper at module scope in `mesh.d` with NO
// reader outside these blocks, so it moved here and is `private` here.
// Nothing was widened; a fixture whose readers sit on BOTH sides of the
// seam -- `looseTestVertAt` and friends -- could not travel, and its
// blocks stayed in `mesh.d` for exactly that reason.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT, so a mutation that
// should redden two blocks here only ever proves the first. Run them in
// isolation.
module tests.unit.mesh_thicken_surface_test;

import mesh;
import math : Vec3;
import tests.unit.mesh_by_value_gate;

// The seam's compile-time gate: nothing in this module may take a `Mesh` by
// VALUE. `tests/unit/mesh_by_value_gate.d` says why nothing behavioural
// catches that, and carries the gate's own positive control.
private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

// Helper: count undirected edges shared by exactly one face.
version (unittest) private size_t countOpenEdges(ref Mesh m) {
    int[2][ulong] ef;
    foreach (i, f; m.faces)
        foreach (k; 0 .. f.length) {
            ulong key = edgeKey(f[k], f[(k+1)%f.length]);
            auto p = key in ef;
            if (p is null) ef[key] = [cast(int)i, -1];
            else if ((*p)[1] == -1 && (*p)[0] != cast(int)i) (*p)[1] = cast(int)i;
        }
    size_t cnt = 0;
    foreach (_, fp; ef) if (fp[1] == -1) cnt++;
    return cnt;
}

unittest { // thickenSurface: 2×2 grid → 16-face watertight shell
    Mesh m;
    foreach (j; 0 .. 3)
        foreach (i; 0 .. 3)
            m.addVertex(Vec3(cast(float)i, cast(float)j, 0));
    foreach (j; 0 .. 2)
        foreach (i; 0 .. 2) {
            uint a = cast(uint)(i     + 3 * j    );
            uint b = cast(uint)(i + 1 + 3 * j    );
            uint c = cast(uint)(i + 1 + 3 * (j+1));
            uint d = cast(uint)(i     + 3 * (j+1));
            m.addFace([a, b, c, d]);
        }
    m.buildLoops();

    size_t r;
    { auto ed = MeshEditBatch.unrecorded(m, kBridgeEditScope);
      r = m.thickenSurface(ed, 0.2f); ed.close(); }
    assert(r > 0, "thicken 2×2: non-zero result");
    assert(m.vertices.length == 18, "thicken 2×2: 18 verts");
    assert(m.faces.length == 16, "thicken 2×2: 16 faces");
    assert(m.boundaryLoops().length == 0, "thicken 2×2: watertight");
    assert(countOpenEdges(m) == 0, "thicken 2×2: no open edges");
}

unittest { // thickenSurface: 3×3 holed grid → 32-face watertight shell
    // 16 verts, 8 quads (center quad skipped).
    Mesh m;
    foreach (j; 0 .. 4)
        foreach (i; 0 .. 4)
            m.addVertex(Vec3(cast(float)i, cast(float)j, 0));
    size_t fi = 0;
    foreach (j; 0 .. 3)
        foreach (i; 0 .. 3) {
            uint a = cast(uint)(i     + 4 * j    );
            uint b = cast(uint)(i + 1 + 4 * j    );
            uint c = cast(uint)(i + 1 + 4 * (j+1));
            uint d = cast(uint)(i     + 4 * (j+1));
            if (fi != 4) m.addFace([a, b, c, d]);
            fi++;
        }
    m.buildLoops();

    size_t r;
    { auto ed = MeshEditBatch.unrecorded(m, kBridgeEditScope);
      r = m.thickenSurface(ed, 0.2f); ed.close(); }
    assert(r > 0, "thicken holed: non-zero result");
    assert(m.vertices.length == 32, "thicken holed: 32 verts");
    assert(m.faces.length == 32, "thicken holed: 32 faces (8+8+12+4)");
    assert(m.boundaryLoops().length == 0, "thicken holed: watertight");
    assert(countOpenEdges(m) == 0, "thicken holed: no open edges");
}
