module vibe3d.mesh.core.tests.unit.mesh_topology_integration_test;
import vibe3d.mesh.core.mesh;
import vibe3d.util.math.math : Vec3;

unittest { // corrupted fan elsewhere in the SAME hub vertex recovers a clean
           // bystander edge's incident faces via the other-endpoint retry
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,2,0), Vec3(-1,1,0), Vec3(-1,-1,0),
        Vec3(1,-1,0), Vec3(9,9,0),
    ];
    m.faces = [
        [0u,1u,2u],   // face0 -- query edge (0,1) lives here
        [0u,2u,3u],   // face1
        [0u,3u,4u],   // face2
        [0u,4u,5u],   // face3
        [0u,5u,6u],   // face4
        [0u,6u,1u],   // face5 -- closes the fan back to vertex1
        [3u,0u,7u],   // faceBad -- reuses spoke (0,3) in the SAME direction (3→0)
                      // as face1's (3,0): a genuine same-direction shared edge,
                      // corrupting the vertex-0 half-edge fan elsewhere.
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    uint ei01 = m.edgeIndex(0, 1);
    assert(ei01 != ~0u, "edge (0,1) must exist");
    assert(m.edges[ei01][] == [0u, 1u], "sanity: default direction is va=0, vb=1");

    // The original private _tryFrom refusal remains in mesh_topo.
    // The retry-equipped public API must recover both true incident faces.
    uint[] found;
    foreach (fi; m.facesAroundEdge(ei01)) found ~= fi;
    import std.algorithm : sort, canFind;
    sort(found);
    assert(found == [0u, 5u],
        "facesAroundEdge must recover both faces incident on edge (0,1) via the "
        ~ "other-endpoint retry, not silently report zero");

    // collectEdgeRing (the direct cause of the Loop Slice no-op) is a thin
    // wrapper over facesAroundEdge (mesh.d ~9949) -- it inherits this fix
    // automatically. Not separately re-derived here: constructing a corrupted
    // fan where the retry ALSO recovers a clean quad-quad ring (rather than
    // just triangle incidence) needs a larger fixture without adding coverage
    // over what's proven above; see the follow-up note in the task file.
}

unittest { // well-formed mesh: retry is inert (never fires; the default
           // single-direction lookup always succeeds on its own, so
           // facesAroundEdge's result is byte-identical to before this fix)
    Mesh m = makeCube();
    m.buildLoops();
    foreach (ei; 0 .. cast(uint)m.edges.length) {
        bool[] ordered;
        foreach (vi; 0 .. cast(uint)m.vertices.length) ordered ~= m.vertexFanOrdered(vi);
        auto direct = EdgeFaceRange(m.loops, m.edges, m.vertLoop, ordered, null, null, ei);

        uint[] viaPublicApi;
        foreach (fi; m.facesAroundEdge(ei)) viaPublicApi ~= fi;
        import std.algorithm : sort;
        uint[] direct2;
        foreach (fi; direct) direct2 ~= fi;
        sort(direct2);
        auto viaSorted = viaPublicApi.dup;
        sort(viaSorted);
        assert(direct2 == viaSorted,
            "well-formed mesh: facesAroundEdge result must match the plain "
            ~ "single-direction lookup exactly -- the retry must not alter it");
    }
}
