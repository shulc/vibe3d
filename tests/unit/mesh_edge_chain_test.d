// mesh_edge_chain_test -- `extractSelectedEdgeChain(s)` -- open arcs, closed cycles, and the four refusals.
//
// One chain, several chains, a cycle, a branch point, more than one
// component, and empty. The refusals are the point: a walker that follows
// the first branch it meets is green on every well-formed input.
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
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT, so a mutation that
// should redden two blocks here only ever proves the first. Run them in
// isolation.
module tests.unit.mesh_edge_chain_test;

import mesh;
import math : Vec3;
import tests.unit.mesh_by_value_gate;

// The seam's compile-time gate: nothing in this module may take a `Mesh` by
// VALUE. `tests/unit/mesh_by_value_gate.d` says why nothing behavioural
// catches that, and carries the gate's own positive control.
private void byValueGateAnchor() {}
mixin MeshByValueGate!(__traits(parent, byValueGateAnchor));

unittest { // extractSelectedEdgeChains: two open arcs, single open chain,
           // two closed cycles, degree-3 rejection, mixed open+closed
    import std.conv : to;

    void selectAll(ref Mesh m) {
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;
    }

    // (1) Two disjoint open arcs (2 edges each, 3 verts each).
    {
        Mesh m;
        foreach (i; 0 .. 6) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2);
        m.addEdge(3, 4); m.addEdge(4, 5);
        m.buildLoops();
        selectAll(m);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 2,
            "two open arcs: expected 2 chains, got " ~ chains.length.to!string);
        foreach (c; chains) {
            assert(!c.closed, "two open arcs: both chains must be open");
            assert(c.verts.length == 3,
                "two open arcs: expected 3 verts/chain, got " ~ c.verts.length.to!string);
        }
    }

    // (2) Single open chain alone — one component, no second group.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(2, 3);
        m.buildLoops();
        selectAll(m);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 1,
            "single chain: expected 1 chain, got " ~ chains.length.to!string);
        assert(!chains[0].closed, "single chain: must be open");
        assert(chains[0].verts.length == 4,
            "single chain: expected 4 verts, got " ~ chains[0].verts.length.to!string);
    }

    // (3) Two closed 4-cycles — must match extractSelectedEdgeCycles' own count.
    {
        Mesh m;
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
        m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
        m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
        m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
        m.addFace([0u,1u,2u,3u]);
        m.addFace([4u,5u,6u,7u]);
        m.buildLoops();
        m.syncSelection();
        foreach (ei; 0 .. m.edges.length) m.selectEdge(cast(int)ei);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 2,
            "two closed cycles: expected 2 chains, got " ~ chains.length.to!string);
        foreach (c; chains) {
            assert(c.closed, "two closed cycles: both must be closed");
            assert(c.verts.length == 4,
                "two closed cycles: expected 4 verts/cycle, got " ~ c.verts.length.to!string);
        }
        auto cycles = m.extractSelectedEdgeCycles();   // untouched extractor, same selection
        assert(cycles.length == chains.length,
            "extractSelectedEdgeChains must agree with extractSelectedEdgeCycles on an all-closed selection");
    }

    // (4) Branching vertex (degree 3) anywhere → whole call rejected.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(1, 3);
        m.buildLoops();
        selectAll(m);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 0,
            "degree-3 branching: expected rejection, got " ~ chains.length.to!string);
    }

    // (5) Mixed: one open chain + one closed cycle selected together.
    {
        Mesh m;
        // Open chain: verts 0-1-2.
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
        // Closed cycle: verts 3-4-5-6.
        m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(1,1,0));
        m.addVertex(Vec3(1,2,0)); m.addVertex(Vec3(0,2,0));
        m.addEdge(0, 1); m.addEdge(1, 2);
        m.addEdge(3, 4); m.addEdge(4, 5); m.addEdge(5, 6); m.addEdge(6, 3);
        m.buildLoops();
        selectAll(m);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 2,
            "mixed open+closed: expected 2 chains, got " ~ chains.length.to!string);
        int openCount = 0, closedCount = 0;
        foreach (c; chains) { if (c.closed) ++closedCount; else ++openCount; }
        assert(openCount == 1 && closedCount == 1,
            "mixed open+closed: expected exactly 1 open + 1 closed chain");
    }
}

unittest { // extractSelectedEdgeChain: open chain, closed cycle, branching + multi-component rejections, empty
    import std.conv : to;

    // (1) Open chain: v0-v1-v2-v3 (3 edges, endpoints at v0 and v3).
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(2, 3);
        m.buildLoops();
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(!closed, "open chain: expected isClosed=false");
        assert(chain.length == 4,
            "open chain: expected 4 verts, got " ~ chain.length.to!string);
        assert((chain[0] == 0 && chain[$-1] == 3)
            || (chain[0] == 3 && chain[$-1] == 0),
            "open chain: endpoints must be v0 and v3");
    }

    // (2) Closed cycle: v0-v1-v2-v3-v0 (4 edges, all degree 2).
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(2, 3); m.addEdge(3, 0);
        m.buildLoops();
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(closed, "closed cycle: expected isClosed=true");
        assert(chain.length == 4,
            "closed cycle: expected 4 verts, got " ~ chain.length.to!string);
    }

    // (3) Branching vertex (degree 3): v0-v1, v1-v2, v1-v3 → must reject.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(1, 3);
        m.buildLoops();
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(chain.length == 0,
            "branching vertex: expected rejection (empty chain), got length "
            ~ chain.length.to!string);
    }

    // (4) Two disconnected edges (multi-component, 4 degree-1 endpoints) → must reject.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(2, 3);
        m.buildLoops();
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(chain.length == 0,
            "multi-component: expected rejection, got length "
            ~ chain.length.to!string);
    }

    // (5) No edges selected → empty result.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2);
        m.buildLoops();
        m.resizeEdgeSelection();
        // edgeMarks grown to cover 2 edges but Select bit NOT set.

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(chain.length == 0,
            "no selection: expected empty chain, got length "
            ~ chain.length.to!string);
    }
}
