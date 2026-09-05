module tools.common.session_mesh_key;

import mesh : Mesh, MeshTopoKey;
import mesh_edit_delta : MeshEditScope;

/// THE IDENTITY OF THE MESH A GESTURE WAS ARMED OVER (task 2880, backlog 2760).
///
/// WHAT IT IS FOR. Several tools freeze indices into the document mesh when a
/// gesture is armed — a loop, a profile, a touched-vertex list — and consume
/// them later, from `deactivate()` or from a commit at mouse-up. Their commit
/// guards were made of GESTURE state alone (`engaged`, `built`, `active`, a
/// state enum), and none of that is invalidated when the DOCUMENT changes
/// underneath a live tool. That is an ordinary path, not a corner: File → New,
/// a load, a scene reset, an active-layer switch. Three tools were measured
/// killing the process on it, each with a real gesture and a real reset:
///
///   * `mesh.bridgeTool`      ArrayIndexError@source/mesh_ops/bridge.d(204)
///   * `mesh.radialSweepTool` ArrayIndexError@source/mesh_ops/revolve.d(374)
///   * `xfrm.magnet`          ArrayIndexError@source/tools/deform/magnet.d(298)
///
/// WHY THE OBVIOUS TERMS DO NOT WORK, MEASURED RATHER THAN REASONED.
/// `SceneReset.applyImpl` writes `*mesh = Mesh.init` IN PLACE on the SURVIVING
/// primary layer (commands/scene/reset.d:208), THEN fires `onResetTool()` →
/// `dropActiveTool(sceneResetDrop)` → the tool's `deactivate()` (:279), and
/// only THEN publishes `MeshChangeAll` (:303). So on the very path in the
/// reproduction below:
///
///   * the mesh ADDRESS is unchanged — the `Layer` object survives the reset,
///     so no `noteMeshBirth` is minted and no address term moves (measured:
///     byte-identical address across both an empty reset and a cube reset);
///   * a `mesh_dirty` EPOCH still reads its pre-reset value, because the
///     publish that advances it runs 24 lines AFTER the tool was dropped.
///
/// A polled COUNTER is what survives that ordering, which is the shape
/// `LoopSliceTool.armedKey_` / `EdgeSliceTool` / `SliceTool` already use for
/// this same hazard. This type is that shape, named, so a fourth tool does not
/// have to rediscover it.
///
/// WHICH COUNTER, AND WHY NOT `mutationVersion`. What these tools freeze is a
/// VERTEX SET and a FACE SET, so the counter that owns the class is
/// `topologyVersion` (`MeshTopoKey`). `mutationVersion` ALSO moves on POSITION,
/// and two legal things move position under a live tool: `GpuMesh.upload`'s
/// suppressed-cage arm publishes `Position` on the document mesh every refresh
/// frame while a subpatch preview is live (task 1906), and Magnet's own drag
/// publishes `Position` on every motion. Keying on `mutationVersion` would
/// therefore refuse commits that are entirely correct — and a guard that
/// reddens on correct code is worse than the crash it replaces.
///
/// AND WHY THE COUNTS ARE A SECOND, INDEPENDENT TERM. `topologyVersion` is NOT
/// monotone across a document replacement: measured 2 → 1 on a reset to empty
/// (a fresh `Mesh` starts its counters over), which is why the compare must be
/// `!=` and never `>`, and why a gesture that happened to arm at exactly the
/// post-reset value would collide. The counts cannot collide on that path: an
/// armed gesture implies geometry to work on, and an emptied document has
/// none. Neither term can fire without a real change — a tool that does not
/// write the document mesh between its stamp and its commit (Bridge, Radial
/// Sweep) leaves all three terms alone, and one that writes only positions
/// (Magnet) leaves all three alone too.
struct SessionMeshKey {
    private MeshTopoKey key_;
    private size_t      verts_ = size_t.max;
    private size_t      faces_ = size_t.max;

    /// Freeze the identity of `m`. Call this exactly where the mesh-indexed
    /// state it protects is (re-)derived — including from a `resyncSession()`,
    /// or the guard refuses a commit undo/redo legitimately re-baselined.
    void stamp(ref Mesh m) nothrow @nogc {
        key_   = MeshTopoKey.init;
        key_.stamp(m);
        verts_ = m.vertices.length;
        faces_ = m.faces.length;
    }

    /// Is `m` still the mesh this gesture was armed over?
    bool matches(ref Mesh m) const nothrow @nogc {
        return key_.matches(m)
            && verts_ == m.vertices.length
            && faces_ == m.faces.length;
    }

    /// Forget the stamp — a fresh key matches nothing (`MeshTopoKey`'s own
    /// sentinels are `size_t.max` / `ulong.max`, which no live mesh can hold).
    void invalidate() nothrow @nogc {
        key_.invalidate();
        verts_ = size_t.max;
        faces_ = size_t.max;
    }
}

// THE THREE TERMS ARE ONE BLOCK EACH, NOT ONE BLOCK OF THREE. druntime stops
// a module at its first failed assert, so a single block would let the earliest
// term hide the other two: a mutation that deletes the address/counter half
// would redden term 1 and say nothing about term 2, and both cells would be
// reported as "covered" on the strength of one. Split, each mutation names the
// terms it actually breaks.

unittest { // the basics: stamp matches, fresh and invalidated keys do not
    import mesh : makeCube;

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
    import mesh : makeCube;

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
    import mesh : makeCube;

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

unittest { // TERM 3 — the COUNTS, isolated
    import mesh : makeCube;

    // The COUNTS, isolated, and the isolation has to be BUILT. A
    // reset to empty moves the counter as well (2 -> 1 was the measured pair
    // on the live path), so `stamp; m = Mesh.init; assert(!matches)` proves
    // nothing about the counts — the counter alone would carry it. Re-stamp
    // the counter half against the REPLACEMENT, leaving the counts as the
    // only surviving difference, and the refusal is then the counts and
    // nothing else. (Private, and reachable here because this is the type's
    // own module.)
    Mesh d = makeCube();
    SessionMeshKey kd;
    kd.stamp(d);
    d = Mesh.init;                       // exactly what `SceneReset` writes
    kd.key_.stamp(d);                    // hand the counter term the collision
    assert(kd.key_.matches(d),
        "the counter half was re-stamped and still refuses — this cell can no "
        ~ "longer isolate the counts");
    assert(!kd.matches(d),
        "the counts term did not discriminate: with the address and the "
        ~ "counter both matching, an EMPTY mesh still matched a key stamped "
        ~ "against the eight-vertex cube it replaced");

    // THE RESIDUAL, stated rather than hidden: a replacement that lands at the
    // same address with the same counter and the same counts is invisible to
    // all three terms — a reset from a cube to an identical cube is the one
    // shape that does it. It cannot crash (every frozen index is in range by
    // construction), so what it costs is a wrong commit, not the process.
}
