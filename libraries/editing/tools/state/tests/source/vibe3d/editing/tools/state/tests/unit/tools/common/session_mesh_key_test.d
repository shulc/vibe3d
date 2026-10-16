module vibe3d.editing.tools.state.tests.unit.tools.common.session_mesh_key_test;

import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditScope;
import vibe3d.editing.tools.state.tools.common.session_mesh_key : SessionMeshKey;

// THE THREE TERMS ARE ONE BLOCK EACH, NOT ONE BLOCK OF THREE. druntime stops
// a module at its first failed assert, so a single block would let the earliest
// term hide the other two: a mutation that deletes the address/counter half
// would redden term 1 and say nothing about term 2, and both cells would be
// reported as "covered" on the strength of one. Split, each mutation names the
// terms it actually breaks.

unittest { // the basics: stamp matches, fresh and invalidated keys do not
    import vibe3d.mesh.core.mesh : makeCube;

    Mesh m = makeCube();
    SessionMeshKey k;
    k.stamp(m);
    assert(k.matches(m), "a freshly stamped key must match its own mesh");

    SessionMeshKey fresh;
    assert(!fresh.matches(m), "an unstamped key must not match a live mesh");
    k.invalidate();
    assert(!k.matches(m), "an invalidated key must not match");

}

unittest { // TERM 1 — the ADDRESS, isolated
    import vibe3d.mesh.core.mesh : makeCube;

    // The ADDRESS, isolated. Two identically-built meshes carry the
    // same counter AND the same counts (asserted, or this cell would be
    // satisfied by either of the other two terms), so only the address can
    // separate them. This is what an active-layer switch hands a live tool.
    Mesh a = makeCube();
    Mesh b = makeCube();
    assert(a.topologyVersion == b.topologyVersion
        && a.vertices.length == b.vertices.length
        && a.faces.length    == b.faces.length,
        "this cell is meant to isolate the ADDRESS term; the two cubes differ "
        ~ "in counter or counts, so a refusal here would not prove the address "
        ~ "term does anything");
    SessionMeshKey ka;
    ka.stamp(a);
    assert(!ka.matches(b),
        "the address term did not discriminate: a second identically-built "
        ~ "mesh matched a key stamped against the first");

}

unittest { // TERM 2 — the COUNTER, isolated
    import vibe3d.mesh.core.mesh : makeCube;

    // The COUNTER, isolated. Same object, so the address holds; a
    // bare Geometry-class commit adds no vertex and no face, so the counts
    // hold too. BOTH halves of that are asserted rather than assumed: the
    // first draft of this cell used `setSubpatch(0, true)`, which returns
    // early when `faceMarks` is shorter than the face list — on a freshly
    // built cube it moved nothing and the cell went red for the wrong reason.
    Mesh c = makeCube();
    SessionMeshKey kc;
    kc.stamp(c);
    immutable size_t nv = c.vertices.length, nf = c.faces.length;
    immutable ulong  tv = c.topologyVersion;
    c.commitChange(MeshEditScope.Polygons);
    assert(c.topologyVersion != tv,
        "this cell is meant to move the COUNTER, and it did not — a refusal "
        ~ "below would then prove nothing about the counter term");
    assert(c.vertices.length == nv && c.faces.length == nf,
        "this cell is meant to move the COUNTER while the counts hold still; "
        ~ "they moved, so it no longer isolates that term");
    assert(!kc.matches(c),
        "the topologyVersion term did not discriminate: a Geometry-class "
        ~ "change that left both counts alone still matched");

}
