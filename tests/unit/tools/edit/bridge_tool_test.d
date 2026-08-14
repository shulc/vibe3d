// Module unittests for `tools.edit.bridge_tool`, moved verbatim out of source/tools/edit/bridge_tool.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.edit.bridge_tool_test;

import bindbc.opengl;
import bindbc.sdl;
import operator : VectorStack;
import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import shader : Shader, LitShader, drawLitPreview;
import std.json : JSONValue;
import std.conv : to;
import tools.edit.bridge_tool;

unittest { // Edge mode: remove=true is a safe no-op when the loop bounds
           // no existing face (the common "open hole" case — matches
           // vibe3d's pre-existing edge-mode behaviour).
    Mesh m;
    // Two disjoint square rims with NO cap faces at all — just the 4 side
    // quads connecting them (an already-open tube).
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    m.addFace([0u,1u,5u,4u]);
    m.addFace([1u,2u,6u,5u]);
    m.addFace([2u,3u,7u,6u]);
    m.addFace([3u,0u,4u,7u]);
    m.buildLoops();
    m.faceMarks.length = m.faces.length;
    m.edgeMarks.length = m.edges.length;
    m.faceSelectionOrder.length = m.faces.length;
    m.edgeSelectionOrder.length = m.edges.length;
    foreach (ei; 0 .. m.edges.length) {
        auto e = m.edges[ei];
        bool bothA = e[0] < 4 && e[1] < 4;
        bool bothB = e[0] >= 4 && e[1] >= 4;
        if (bothA || bothB) m.selectEdge(cast(int)ei);
    }
    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(sel.valid, "edge-mode selection must resolve");
    assert(sel.capFaces.length == 0, "no face bounds either rim on an open tube");

    BridgeParams p; p.segments = 1; p.remove = true;
    size_t facesBefore = m.faces.length;
    auto r = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, p);
    assert(r.added == 4, "expected 4 new bridge quads");
    assert(!r.removed, "no cap face existed to remove");
    assert(m.faces.length == facesBefore + 4, "face count: 4 existing + 4 new");
}

unittest { // Edge mode OPEN rows (task 0395 owner repro): cube minus 2
           // adjacent faces (8v/4f), select the 4 boundary edges away from
           // the two connector edges (two 2-edge open arcs) — resolve must
           // be valid + openRows=true + capFaces EMPTY (an open chain never
           // bounds an existing face), and applyBridgeOp(spans=1) must
           // reconstruct the 2 deleted faces bit-for-bit: 8v/4f -> 8v/6f,
           // reusing the existing boundary vertices (no new verts).
    int findEdge(ref Mesh m, uint a, uint b) {
        foreach (ei; 0 .. m.edges.length) {
            auto e = m.edges[ei];
            if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) return cast(int)ei;
        }
        return -1;
    }

    Mesh m;
    m.addVertex(Vec3(-0.5,-0.5,-0.5)); m.addVertex(Vec3(0.5,-0.5,-0.5));
    m.addVertex(Vec3(0.5,0.5,-0.5));   m.addVertex(Vec3(-0.5,0.5,-0.5));
    m.addVertex(Vec3(-0.5,-0.5,0.5));  m.addVertex(Vec3(0.5,-0.5,0.5));
    m.addVertex(Vec3(0.5,0.5,0.5));    m.addVertex(Vec3(-0.5,0.5,0.5));
    m.addFace([0u,3u,2u,1u]);
    m.addFace([4u,5u,6u,7u]);
    m.addFace([0u,4u,7u,3u]);
    m.addFace([0u,1u,5u,4u]);
    m.buildLoops();
    m.faceMarks.length = m.faces.length;
    m.edgeMarks.length = m.edges.length;
    m.faceSelectionOrder.length = m.faces.length;
    m.edgeSelectionOrder.length = m.edges.length;

    int e32 = findEdge(m, 3, 2), e21 = findEdge(m, 2, 1);
    int e56 = findEdge(m, 5, 6), e67 = findEdge(m, 6, 7);
    assert(e32 >= 0 && e21 >= 0 && e56 >= 0 && e67 >= 0,
        "owner repro: all 4 boundary edges must exist on the fixture mesh");
    m.selectEdge(e32); m.selectEdge(e21);
    m.selectEdge(e56); m.selectEdge(e67);

    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(sel.valid, "owner repro: two open rows must resolve valid (was a silent no-op pre-0395)");
    assert(sel.openRows, "owner repro: must be detected as openRows");
    assert(!sel.polygonMode, "owner repro: edge mode is not polygonMode");
    assert(sel.capFaces.length == 0,
        "owner repro: open rows never bound an existing face, expected empty capFaces, got "
        ~ sel.capFaces.length.to!string);

    BridgeParams p; p.segments = 1; p.remove = true;
    size_t facesBefore = m.faces.length, vertsBefore = m.vertices.length;
    auto r = applyBridgeOp(m, sel.loopA, sel.loopB, sel.capFaces, p, sel.openRows);
    assert(r.added == 2, "owner repro: expected 2 new quads, got " ~ r.added.to!string);
    assert(!r.removed, "owner repro: capFaces empty, nothing to remove");
    assert(m.faces.length == facesBefore + 2,
        "owner repro: expected 8v/6f (4+2 quads), got " ~ m.faces.length.to!string ~ " faces");
    assert(m.vertices.length == vertsBefore,
        "owner repro: bridge must reuse existing boundary verts, no new verts");

    // Winding-consistency (task 0395 rr-refinement): each new bridge face
    // must traverse any edge it shares with a PRE-EXISTING face in the
    // OPPOSITE direction — the same half-edge manifold invariant
    // `orientFaceConsistent` enforces for `makePolygonFromVerts` (task
    // 0394), now reused by `bridgeStripPaired`/`bridgeFanRows`. A
    // same-direction shared edge would corrupt the half-edge fan there —
    // this is exactly the connected-topology case the owner repro exercises
    // (both new quads border two of the cube's 4 remaining original faces).
    bool sharesEdgeSameDirection(const(uint)[] a, const(uint)[] b) {
        foreach (i; 0 .. a.length) {
            uint u = a[i], v = a[(i + 1) % a.length];
            foreach (k; 0 .. b.length) {
                uint p = b[k], q = b[(k + 1) % b.length];
                if (u == p && v == q) return true;
            }
        }
        return false;
    }
    foreach (nfi; facesBefore .. m.faces.length)
        foreach (ofi; 0 .. facesBefore)
            assert(!sharesEdgeSameDirection(m.faces[nfi], m.faces[ofi]),
                "owner repro: new face " ~ nfi.to!string ~ " traverses a shared edge in the "
                ~ "SAME direction as pre-existing face " ~ ofi.to!string ~ " (winding corruption)");
}

unittest { // Edge mode: mixed open+closed selection is a safe no-op
           // (deferred, task 0395) — resolve must report invalid, not crash
           // or silently pick one interpretation.
    Mesh m;
    // Open chain: verts 0-1-2.
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
    // Closed cycle: verts 3-4-5-6.
    m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(1,1,0));
    m.addVertex(Vec3(1,2,0)); m.addVertex(Vec3(0,2,0));
    m.addEdge(0, 1); m.addEdge(1, 2);
    m.addEdge(3, 4); m.addEdge(4, 5); m.addEdge(5, 6); m.addEdge(6, 3);
    m.buildLoops();
    m.resizeEdgeSelection();
    foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

    auto sel = resolveBridgeSelection(m, EditMode.Edges);
    assert(!sel.valid, "mixed open+closed selection must resolve invalid (no-op), not pick a side");
}
