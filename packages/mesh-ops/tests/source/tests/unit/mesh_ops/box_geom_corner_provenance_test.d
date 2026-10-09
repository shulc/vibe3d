// Task 0901 — corner-provenance obligation for the primitive-factory family
// (tools/create/*, mesh_ops/box_geom.d). `buildCuboidParametric` is the ONE
// public door every create-tool commit site (BoxTool.commitBase/commitCuboid/
// applyHeadless, and — via the shared PrimitiveCreateTool.appendBuildInto —
// cylinder/cone/capsule/tube/torus too) calls to APPEND a fresh primitive
// into the LIVE scene mesh ("existing geometry survives" is every leaf
// tool's documented commit convention). Verified before declaring anything:
// every path through this generator (flat/segmented cuboid, rounded cube,
// rounded plane, and the axis-swap delegates) only ever calls `dst.addFace`,
// never a bare `faces ~=`, so this is CornerProvenance.Kind.Appended, not
// `CornerDrop.PrimitiveRebuild` — see that reason's doc comment in
// mesh_corner_maps.d for the fuller argument.
module tests.unit.mesh_ops.box_geom_corner_provenance_test;

import mesh;
import math : Vec3;
import mesh_ops.box_geom : BoxParams, buildCuboidParametric;

// A quad the cuboid build never touches — the "did the append reach outside
// what it added" probe. Values keyed 1000+corner so a dropped (zeroed) value
// is unambiguous.
private Mesh meshWithUnrelatedUvQuad() {
    Mesh m;
    m.addVertex(Vec3(10, 0, 0));
    m.addVertex(Vec3(11, 0, 0));
    m.addVertex(Vec3(11, 1, 0));
    m.addVertex(Vec3(10, 1, 0));
    m.addFace([0, 1, 2, 3]);
    m.buildLoops();

    MeshMap uv;
    uv.name   = "uv";
    uv.dim    = 2;
    uv.domain = MapDomain.PolyVertex;
    uv.data.length = m.loops.length * 2;
    foreach (li; 0 .. m.loops.length) {
        uv.data[li * 2]     = 1000.0f + li;
        uv.data[li * 2 + 1] = 2000.0f + li;
    }
    m.meshMaps ~= uv;
    return m;
}

private const(float)[] uvDataOf(ref Mesh m) {
    foreach (ref mm; m.meshMaps)
        if (mm.domain == MapDomain.PolyVertex) return mm.data;
    return null;
}

unittest { // flat/segmented cuboid path (default params, no rounding)
    Mesh m = meshWithUnrelatedUvQuad();
    const float[] before = uvDataOf(m)[0 .. 8].dup;

    BoxParams p;   // unit cube at origin, defaults
    buildCuboidParametric(&m, p);
    m.buildLoops();

    assert(m.faces.length == 7, "6 cube faces appended after the 1 pre-existing quad");
    const(float)[] after = uvDataOf(m);
    assert(after.length == m.loops.length * 2, "map stays length-correct");
    assert(after[0 .. 8] == before,
           "an unrelated pre-existing face's UV must survive a primitive "
           ~ "append byte-for-byte — a PrimitiveRebuild-style whole-map drop "
           ~ "would zero this");
    foreach (v; after[8 .. $])
        assert(v == 0.0f, "the new cube's own corners are the honest zero — no invented UV");
}

unittest { // rounded-cube path (radius > 0) — a DIFFERENT internal generator
    Mesh m = meshWithUnrelatedUvQuad();
    const float[] before = uvDataOf(m)[0 .. 8].dup;

    BoxParams p;
    p.radius = 0.2f;
    buildCuboidParametric(&m, p);
    m.buildLoops();

    assert(m.faces.length > 7, "rounded cube adds more than 6 faces");
    const(float)[] after = uvDataOf(m);
    assert(after.length == m.loops.length * 2, "map stays length-correct");
    assert(after[0 .. 8] == before,
           "the rounded-cube generator must not touch a face outside itself");
    foreach (v; after[8 .. $])
        assert(v == 0.0f, "rounded cube's own corners are the honest zero");
}

unittest { // rounded-cube, axis=X path — the axis-swap delegate (builds into
           // a TEMPORARY Mesh first, then copies through dst.addFace)
    Mesh m = meshWithUnrelatedUvQuad();
    const float[] before = uvDataOf(m)[0 .. 8].dup;

    BoxParams p;
    p.radius = 0.2f;
    p.axis   = 0;
    buildCuboidParametric(&m, p);
    m.buildLoops();

    const(float)[] after = uvDataOf(m);
    assert(after.length == m.loops.length * 2, "map stays length-correct");
    assert(after[0 .. 8] == before,
           "the axis-swap delegate (builds into a temp Mesh, then re-emits "
           ~ "via dst.addFace) must not touch a pre-existing face either");
}
