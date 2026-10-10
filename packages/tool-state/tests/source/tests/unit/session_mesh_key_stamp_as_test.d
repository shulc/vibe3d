module tests.unit.session_mesh_key_stamp_as_test;

// Task 7112: `SessionMeshKey.stampAs(image, liveAddr)` — the key a slice
// tool's prepared param update computes from its CANDIDATE image, which
// `installPreparedMeshImage` then copies whole into the live mesh. One block
// per property (druntime stops a module at its first failed assert, so a
// shared block would let the first cell hide the rest). Every cell builds its
// candidate with a Polygons commit, so its topology counter differs from the
// live mesh's — asserted, or (a) and (d) could not be told apart.

import mesh : Mesh, makeCube, installPreparedMeshImage;
import mesh_edit_delta : MeshEditScope;
import tools.common.session_mesh_key : SessionMeshKey;

private Mesh candidateOf(ref const Mesh live) {
    Mesh c = makeCube();
    c.commitChange(MeshEditScope.Polygons);
    assert(c.topologyVersion != live.topologyVersion,
        "stampAs floor: the candidate's topology counter equals the live one, "
        ~ "so no cell here can separate a stamp of the image from one of the live mesh");
    return c;
}

unittest { // (a) stampAs + install => the live mesh matches
    Mesh live = makeCube();
    Mesh candidate = candidateOf(live);
    SessionMeshKey k;
    k.stampAs(candidate, cast(size_t)&live);
    installPreparedMeshImage(live, candidate);
    assert(k.matches(live),
        "stampAs (a): a key stamped from the image at the live address does not "
        ~ "match the live mesh after the image was installed");
}

unittest { // (b) why stampAs exists: stamp(image) names the image's address
    Mesh live = makeCube();
    Mesh candidate = candidateOf(live);
    SessionMeshKey k;
    k.stamp(candidate);
    installPreparedMeshImage(live, candidate);
    assert(!k.matches(live),
        "stampAs (b): a plain stamp of the image matched the live mesh — the "
        ~ "address term no longer separates the image from its install target");
}

unittest { // (c) the point of the fix: a Position commit keeps the match
    Mesh live = makeCube();
    Mesh candidate = candidateOf(live);
    SessionMeshKey k;
    k.stampAs(candidate, cast(size_t)&live);
    installPreparedMeshImage(live, candidate);
    const mv = live.mutationVersion, tv = live.topologyVersion;
    live.vertices[0].x += 0.25f;
    live.commitChange(MeshEditScope.Position);
    assert(live.mutationVersion != mv && live.topologyVersion == tv,
        "stampAs (c) floor: a Position commit must move mutationVersion and "
        ~ "leave topologyVersion alone, or this cell tests nothing");
    assert(k.matches(live),
        "stampAs (c): a Position commit (the live subpatch preview's per-frame "
        ~ "publish) unmatched the key");
}

unittest { // (d) stampAs without the install => no match
    Mesh live = makeCube();
    Mesh candidate = candidateOf(live);
    SessionMeshKey k;
    k.stampAs(candidate, cast(size_t)&live);
    assert(!k.matches(live),
        "stampAs (d): a key stamped from an image that was never installed "
        ~ "matched the live mesh");
}
