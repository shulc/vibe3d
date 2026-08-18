// Module unittests for `mesh`, moved verbatim out of source/mesh.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_test;

import std.math : sqrt;
import std.parallelism : parallel;
import std.range : iota;
import math;
import editmode : EditMode;
import mesh_edit_delta : MeshEditTracker, MeshEditScope;
import change_bus : SelDomain;
import mesh_ops.cut : MeshCutOps;
import mesh_ops.bridge : MeshBridgeOps;
import mesh_ops.loop_slice : MeshLoopSliceOps;
import mesh_ops.decimate : MeshDecimateOps;
import mesh_ops.revolve : MeshRevolveOps;
import mesh_ops.cleanup : MeshCleanupOps;
import mesh_ops.edge_bevel : MeshEdgeBevelOps;
import mesh_ops.extrude : MeshExtrudeOps;
import mesh_ops.connected_mask : MeshConnectedMaskOps;
import std.algorithm.sorting : sort;
import std.math : cos, sin, PI;
import std.format : format;
import mesh;

    unittest { // connectedComponentVertices: two disjoint cubes — island is
               // exactly the picked cube's 8 verts, not the other cube's.
        import std.conv : to;
        Mesh m = makeCube();
        Mesh other = makeCube();
        foreach (v; other.vertices) m.vertices ~= Vec3(v.x + 3.0f, v.y, v.z);
        foreach (f; other.faces) {
            uint[] shifted;
            foreach (vi; f) shifted ~= vi + 8;
            m.addFace(shifted);
        }
        m.buildLoops();
        assert(m.vertices.length == 16 && m.faces.length == 12);

        bool[] mask = m.connectedComponentVertices(0);   // a face of the first cube
        size_t count = 0;
        foreach (i, b; mask) { if (b) { assert(i < 8, "leaked into second cube's verts"); ++count; } }
        assert(count == 8, "expected exactly the first cube's 8 verts, got " ~ count.to!string);

        bool[] mask2 = m.connectedComponentVertices(8);  // a face of the second cube
        size_t count2 = 0;
        foreach (i, b; mask2) { if (b) { assert(i >= 8, "leaked into first cube's verts"); ++count2; } }
        assert(count2 == 8, "expected exactly the second cube's 8 verts, got " ~ count2.to!string);
    }

    unittest {
        import std.math : abs;

        // collapseEdgesByMask: collapse edge 0 ([v0,v3]) of a cube.
        // Edge 0 is the back-left vertical; midpoint = (-0.5, 0, -0.5).
        // Two of the six faces lose a corner and become triangles.
        {
            auto m = makeCube();
            bool[] mask = new bool[](m.edges.length);
            mask[0] = true;
            size_t n = m.collapseEdgesByMask(mask);
            assert(n > 0, "collapseEdgesByMask single: expected weld");
            assert(m.vertices.length == 7,
                "collapseEdgesByMask single: expected 7 verts");
            assert(m.faces.length == 6,
                "collapseEdgesByMask single: expected 6 faces");
            bool foundMid = false;
            foreach (v; m.vertices) {
                if (abs(v.x - (-0.5f)) < 1e-5f
                 && abs(v.y -   0.0f ) < 1e-5f
                 && abs(v.z - (-0.5f)) < 1e-5f) { foundMid = true; break; }
            }
            assert(foundMid, "collapseEdgesByMask single: midpoint absent");
        }

        // collapseEdgesByMask: two disjoint edges (0=[v0,v3], 6=[v6,v7])
        // — no shared vertex, two independent islands. Both must collapse
        // (if only the first collapsed, vertices.length would be 7 not 6).
        {
            auto m = makeCube();
            bool[] mask = new bool[](m.edges.length);
            mask[0] = true;   // [v0, v3]
            mask[6] = true;   // [v6, v7]
            size_t n = m.collapseEdgesByMask(mask);
            assert(n > 0, "collapseEdgesByMask disjoint: expected weld");
            assert(m.vertices.length == 6,
                "collapseEdgesByMask disjoint: both islands must collapse");
        }

        // collapseFacesByMask: collapse front face (fi=1, [4,5,6,7]).
        // Centroid = (0, 0, 0.5). Front face dropped; 4 neighbours → tris;
        // back face untouched. Result: 5 verts, 5 faces.
        {
            auto m = makeCube();
            bool[] mask = new bool[](m.faces.length);
            mask[1] = true;   // front face [4,5,6,7]
            size_t n = m.collapseFacesByMask(mask);
            assert(n > 0, "collapseFacesByMask single: expected weld");
            assert(m.vertices.length == 5,
                "collapseFacesByMask single: expected 5 verts");
            assert(m.faces.length == 5,
                "collapseFacesByMask single: expected 5 faces");
            bool foundCenter = false;
            foreach (v; m.vertices) {
                if (abs(v.x - 0.0f) < 1e-5f
                 && abs(v.y - 0.0f) < 1e-5f
                 && abs(v.z - 0.5f) < 1e-5f) { foundCenter = true; break; }
            }
            assert(foundCenter, "collapseFacesByMask single: centroid absent");
        }

        // collapseFacesByMask: two disjoint faces (fi=0=back, fi=1=front)
        // — each collapses to its own centroid. All 6 faces degenerate and
        // are dropped (every intermediate face has 2 verts from each island,
        // which reduces to a 2-corner degenerate). Result: empty mesh.
        // If only one island collapsed, we would get 5 verts / 5 faces.
        {
            auto m = makeCube();
            bool[] mask = new bool[](m.faces.length);
            mask[0] = true;   // back  face [0,3,2,1]
            mask[1] = true;   // front face [4,5,6,7]
            size_t n = m.collapseFacesByMask(mask);
            assert(n > 0, "collapseFacesByMask disjoint: expected weld");
            assert(m.vertices.length == 0,
                "collapseFacesByMask disjoint: both islands must collapse");
            assert(m.faces.length == 0,
                "collapseFacesByMask disjoint: all faces must degenerate");
        }
    }

    unittest {
        import std.math : abs, sqrt;
        import std.conv : to;

        // (a) Warped quad: the two z=+1 corners are pushed opposite in y,
        //     making the face genuinely non-planar.  After alignFacesByMask
        //     all 4 verts must be coplanar to within 1e-5.
        {
            Mesh m;
            m.vertices = [
                Vec3(-1.0f,  0.0f, -1.0f),   // v0
                Vec3( 1.0f,  0.0f, -1.0f),   // v1
                Vec3( 1.0f,  0.5f,  1.0f),   // v2 — pushed +y
                Vec3(-1.0f, -0.5f,  1.0f),   // v3 — pushed −y
            ];
            m.addFace([0u, 1u, 2u, 3u]);
            m.buildLoops();

            bool[] mask = [true];
            size_t n = m.alignFacesByMask(mask);
            assert(n > 0, "alignFacesByMask warped: expected moves");

            // Recompute plane from 3 post-align verts; check the 4th.
            Vec3 a = m.vertices[0], b = m.vertices[1], c = m.vertices[2];
            Vec3 ab = b - a, ac = c - a;
            Vec3 pn = Vec3(ab.y*ac.z - ab.z*ac.y,
                           ab.z*ac.x - ab.x*ac.z,
                           ab.x*ac.y - ab.y*ac.x);
            float pnlen = sqrt(pn.x*pn.x + pn.y*pn.y + pn.z*pn.z);
            assert(pnlen > 1e-6f, "alignFacesByMask warped: degenerate post-align plane");
            pn = Vec3(pn.x / pnlen, pn.y / pnlen, pn.z / pnlen);
            Vec3 d3 = m.vertices[3] - a;
            float dist = abs(d3.x * pn.x + d3.y * pn.y + d3.z * pn.z);
            assert(dist < 1e-5f,
                "alignFacesByMask warped: 4th vert not coplanar, dist=" ~ dist.to!string);
        }

        // (b) Already-planar but TILTED quad: z = 0.3*x + 0.2*y.
        //     Kernel must return 0 and leave every vertex byte-for-byte
        //     unchanged, proving the coordinate-scaled eps absorbs the ~1e-7
        //     float residual that a naive 1e-9 threshold would mis-read as motion.
        {
            Mesh m;
            m.vertices = [
                Vec3(0.0f, 0.0f, 0.0f),    // z = 0.0
                Vec3(1.0f, 0.0f, 0.3f),    // z = 0.3
                Vec3(1.0f, 1.0f, 0.5f),    // z = 0.5
                Vec3(0.0f, 1.0f, 0.2f),    // z = 0.2
            ];
            Vec3[4] orig;
            foreach (i; 0 .. 4) orig[i] = m.vertices[i];
            m.addFace([0u, 1u, 2u, 3u]);
            m.buildLoops();

            bool[] mask = [true];
            size_t n = m.alignFacesByMask(mask);
            assert(n == 0,
                "alignFacesByMask planar-tilted: expected no-op, got " ~ n.to!string);
            foreach (i; 0 .. 4)
                assert(m.vertices[i].x == orig[i].x
                    && m.vertices[i].y == orig[i].y
                    && m.vertices[i].z == orig[i].z,
                    "alignFacesByMask planar-tilted: vert " ~ i.to!string ~ " changed");
        }
    }

    unittest {
        // interiorEdgesOfSelectedFaces — Loop Slice polygon-activation rule.
        // Cube faces (makeCube): 0=z-0.5, 1=z+0.5, 2=x-0.5, 3=x+0.5,
        // 4=y+0.5, 5=y-0.5.
        bool[] mask(size_t[] on...) {
            auto m = new bool[](6);
            foreach (i; on) m[i] = true;
            return m;
        }

        // Two ADJACENT faces (front z=-0.5 & bottom y=-0.5) share edge (0,1)
        // → exactly one interior edge = that shared edge.
        auto m = makeCube();
        m.setFacesSelectedFrom(mask(0, 5));
        auto sharedEdges = m.interiorEdgesOfSelectedFaces();
        assert(sharedEdges.length == 1,
            "2 adjacent faces must yield exactly 1 shared edge");
        assert(sharedEdges[0] == m.edgeIndex(0, 1),
            "shared edge of front+bottom must be edge (0,1)");

        // Two NON-adjacent (opposite) faces (front z=-0.5 & back z=+0.5) share
        // no edge → empty.
        auto m2 = makeCube();
        m2.setFacesSelectedFrom(mask(0, 1));
        assert(m2.interiorEdgesOfSelectedFaces().length == 0,
            "2 opposite faces share no edge → no seed");

        // A single face has no interior edge (every edge touches only it).
        auto m3 = makeCube();
        m3.setFacesSelectedFrom(mask(0));
        assert(m3.interiorEdgesOfSelectedFaces().length == 0,
            "a lone selected face yields no seed");
    }

    // === Tests: the measured hide/derivation law (doc/hide_geometry_plan.md
    // §1.2/§5, Stage 0's own T-S0a/b/c/d — each case is chosen so a WRONG
    // law reads a DIFFERENT number, not merely "nothing happened", per the
    // plan's own testing gate, §7). makeCube()'s faces (defined further down
    // this module): f0=[0,3,2,1], f1=[4,5,6,7], f2=[0,4,7,3], f3=[1,2,6,5],
    // f4=[3,7,6,2], f5=[0,1,5,4] — so vertex 0's three incident faces are
    // exactly {f0, f2, f5}.
    unittest { // T-S0a — the edge rule derives from VERTICES, not polygons
        auto m = makeCube();
        m.syncSelection();   // makeCube() does not size the marks arrays itself
        // f0 and f2 share edge (0,3). Hiding both is exactly the case the
        // plan's pre-capture "conservative" guess got wrong: a
        // derived-FROM-POLYGONS rule would hide edge (0,3), because both of
        // its incident faces are hidden. The measured rule does not,
        // because vertex 0 still touches f5 and vertex 3 still touches f4,
        // and NEITHER of those is hidden.
        m.setFaceHidden(0, true);
        m.setFaceHidden(2, true);
        m.refreshHiddenDerived();
        const uint e03 = m.edgeIndex(0, 3);
        assert(e03 != ~0u, "cube must have an edge (0,3)");
        assert(!m.isEdgeHidden(e03),
            "edge (0,3) must stay visible — both endpoints still touch a third, visible face");
        // The discriminator only means something if f0/f2 really are edge
        // (0,3)'s ONLY incident faces (not merely that f0/f2 themselves are
        // hidden, which says nothing about which edge they border) — confirm
        // the incidence itself, via facesAroundEdge, or a stray third
        // incident face (visible or not) would make this assertion pass for
        // the wrong reason (code review, task 0613).
        uint[] incident;
        foreach (fi; m.facesAroundEdge(e03)) incident ~= fi;
        import std.algorithm.sorting : sort;
        incident.sort();
        assert(incident == [0u, 2u], "edge (0,3)'s incident faces must be exactly {f0, f2}");
        assert(m.isFaceHidden(0) && m.isFaceHidden(2));
    }

    unittest { // T-S0b — the vertex rule is ALL-incident, not ANY
        auto m = makeCube();
        m.syncSelection();   // makeCube() does not size the marks arrays itself
        // (i) hide two ADJACENT faces (f0, f2 — share vertices 0 and 3): an
        // ANY-incident rule would read 6 hidden vertices (4 + 4 - 2
        // shared); the measured ALL-incident rule reads 0, because every
        // vertex of f0/f2 still touches a third, visible face.
        m.setFaceHidden(0, true);
        m.setFaceHidden(2, true);
        m.refreshHiddenDerived();
        foreach (vi; 0 .. m.vertices.length)
            assert(!m.isVertexHidden(vi),
                "two adjacent hidden faces must hide ZERO vertices (ALL-incident, not ANY)");

        // (ii) hide the THIRD face meeting vertex 0 (f0, f2, f5 are exactly
        // vertex 0's incident faces) — vertex 0 must become hidden, and it
        // must be the ONLY one: no other vertex has all of ITS incident
        // faces hidden yet.
        m.setFaceHidden(5, true);
        m.refreshHiddenDerived();
        assert(m.isVertexHidden(0), "vertex 0's incident faces (f0, f2, f5) are all hidden now");
        foreach (vi; 1 .. m.vertices.length)
            assert(!m.isVertexHidden(vi), "no OTHER vertex has all of its incident faces hidden yet");
    }

    unittest { // T-S0c — the two per-component cases that pin the model
        // (i) A lone quad: hiding its only polygon hides all 4 of its
        // vertices AND all 4 of its edges. A purely-stored implementation
        // (no vertex/edge derivation at all) fails this half.
        {
            Mesh m;
            m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
            m.addFace([0, 1, 2, 3]);
            m.buildLoops();
            m.syncSelection();
            m.setFaceHidden(0, true);
            m.refreshHiddenDerived();
            foreach (vi; 0 .. 4)
                assert(m.isVertexHidden(vi), "the quad's only face is hidden — every vertex must derive hidden");
            foreach (ei; 0 .. m.edges.length)
                assert(m.isEdgeHidden(ei), "the quad's only face is hidden — every edge must derive hidden");
        }
        // (ii) A loose vertex (no incident face): hiding EVERY polygon in
        // the mesh must NOT touch it — it keeps its own, independently
        // settable bit. A purely-derived implementation (no own-bit
        // concept) fails this half.
        {
            auto m = makeCube();
            const uint loose = m.addVertex(Vec3(10, 10, 10));
            m.syncSelection();   // grow vertexMarks to include the new vertex
            foreach (fi; 0 .. m.faces.length) m.setFaceHidden(fi, true);
            m.refreshHiddenDerived();
            foreach (vi; 0 .. 8)
                assert(m.isVertexHidden(vi), "every cube vertex's incident faces are all hidden");
            assert(!m.isVertexHidden(loose),
                "a loose vertex has no incident face — a polygon hide must not touch it");
            m.setVertexHidden(loose, true);
            assert(m.isVertexHidden(loose), "a loose vertex's own bit is directly settable");
            m.refreshHiddenDerived();   // must NOT clear the own bit — hasFace[loose] is false
            assert(m.isVertexHidden(loose), "refreshHiddenDerived must not touch a loose vertex's own bit");
        }
        // (iii) §3.1 Select ∧ Hide = ∅ on the LOOSE half (task 0628).
        // refreshHiddenDerived upholds the invariant for face-bound vertices
        // and steps OVER loose points by design, so `setVertexHidden` is the
        // only place that can uphold it for them. mesh.hideInvert in
        // Vertices/Edges mode is the first production caller that sets a
        // loose point's bit, and a selected loose point it hides would
        // otherwise stay both selected and hidden with nothing able to heal
        // it. The order STAMP is asserted alongside the Select bit: a fix
        // that dropped Select but left the stamp leaves "selected with order
        // 0" state that every order-consuming command silently ignores.
        {
            auto m = makeCube();
            const uint loose = m.addVertex(Vec3(10, 10, 10));
            m.syncSelection();
            m.selectVertex(cast(int)loose);
            assert(m.isVertexSelected(loose), "premise: the loose point is selected");
            assert(m.vertexSelectionOrder[loose] != 0,
                   "premise: a selected element carries a nonzero order stamp");
            m.setVertexHidden(loose, true);
            assert(m.isVertexHidden(loose), "the loose point's own bit is settable");
            assert(!m.isVertexSelected(loose),
                   "Select ∧ Hide = ∅: a loose point that just became hidden "
                   ~ "cannot stay selected — refreshHiddenDerived steps over "
                   ~ "loose points, so nothing downstream would ever fix it");
            assert(m.vertexSelectionOrder[loose] == 0,
                   "the order stamp must be zeroed in the same write as the "
                   ~ "Select bit; a live stamp on a non-selected element is "
                   ~ "exactly the corruption the stamps exist to prevent");
            // The reverse direction must NOT invent a selection: un-hiding
            // restores visibility only.
            m.setVertexHidden(loose, false);
            assert(!m.isVertexHidden(loose) && !m.isVertexSelected(loose),
                   "un-hiding a loose point restores visibility, not selection");
        }
    }

    unittest { // S4 — the three hidden popcounts the "N hidden" readout reads
        // (R9). One fixture, chosen so the three planes carry THREE DIFFERENT
        // numbers: a cube with all three faces around vertex 0 hidden.
        //
        //   faces    3 — the ones hidden
        //   vertices 1 — only v0 has ALL of its incident faces hidden
        //   edges    3 — every edge with v0 as an endpoint
        //
        // The distinctness is the assertion. A readout wired to
        // countHiddenFaces three times reads 3/3/3; one that returns the
        // whole plane length reads 6/8/12; one that swaps the derived planes
        // reads 3/3/1. All three differ from 3/1/3, and none of them would
        // differ from it on a fixture where the counts happened to coincide
        // (e.g. a lone quad, where all three are 1/4/4 — still fine — but a
        // cube with ONE face hidden reads 1/0/0 and cannot separate a
        // vert/edge swap at all).
        auto m = makeCube();
        m.syncSelection();
        uint[] around;
        foreach (fi; m.facesAroundVertex(0)) around ~= fi;
        assert(around.length == 3, "a cube corner touches exactly three faces");
        foreach (fi; around) m.setFaceHidden(fi, true);
        m.refreshHiddenDerived();
        import std.conv : to;
        assert(m.countHiddenFaces()    == 3,
            "three faces hidden, got " ~ m.countHiddenFaces().to!string);
        assert(m.countHiddenVertices() == 1,
            "exactly the corner derives hidden, got " ~ m.countHiddenVertices().to!string);
        assert(m.countHiddenEdges()    == 3,
            "exactly the corner's three edges derive hidden, got "
            ~ m.countHiddenEdges().to!string);
        // And zero is really zero — the readout's "print nothing" branch.
        foreach (fi; around) m.setFaceHidden(fi, false);
        m.refreshHiddenDerived();
        assert(m.countHiddenFaces()    == 0);
        assert(m.countHiddenVertices() == 0);
        assert(m.countHiddenEdges()    == 0);
    }

    unittest { // T-S0d — refreshHiddenDerived() self-heals after a topology
        // change, with NO hide command running: the whole point of routing
        // it through commitChange rather than only the (not-yet-built,
        // Stage 2) hide commands.
        //
        // A 3-face fan around vertex 0 (an open tetrahedron corner):
        // f0=[0,1,2], f1=[0,2,3], f2=[0,3,1]. Vertex 0 touches all three;
        // vertices 1/2/3 each touch exactly two. f2 is hidden LAST
        // (highest index) deliberately: deleteFacesByMask's compaction does
        // not yet carry marks through an index shift (that is Stage 1's own
        // cost centre, T-S1, out of scope here) — deleting the
        // HIGHEST-indexed face is a stable-filter no-op for every surviving
        // index, so this case isolates the S0 claim under test (the funnel
        // refreshes on ANY geometry commit) from the S1 claim (a shift
        // preserves the bit on the right face), which this test does not
        // exercise.
        Mesh m;
        m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(-1,0,0)];
        m.addFace([0, 1, 2]);  // f0
        m.addFace([0, 2, 3]);  // f1
        m.addFace([0, 3, 1]);  // f2 — the last visible face touching vertex 0
        m.buildLoops();
        m.syncSelection();

        m.setFaceHidden(0, true);
        m.setFaceHidden(1, true);
        m.refreshHiddenDerived();
        assert(!m.isVertexHidden(0), "vertex 0 still touches the visible f2");

        // Delete f2 — no hide command runs. deleteFacesByMask ends in
        // commitChange(MeshEditScope.Geometry), which must call
        // refreshHiddenDerived() on our behalf. No vertex is orphaned by
        // this delete (1, 2 and 3 each still belong to a surviving face),
        // so compaction does not renumber anything either.
        bool[] mask = [false, false, true];
        const removed = m.deleteFacesByMask(mask);
        assert(removed == 1);
        assert(m.faces.length == 2, "f0 and f1 survive, unshifted — f2 was the last index");

        assert(m.isVertexHidden(0),
            "vertex 0's only surviving incident faces (f0, f1) are both hidden, and " ~
            "nothing called refreshHiddenDerived() explicitly after the delete");
    }

    // §3.1 — the marks invariant Select ∧ Hide = ∅, enforced in the WRITERS
    // (not the callers), so it holds on paths nobody thought to guard —
    // including undo/redo snapshot replay, which is exactly the path a
    // per-caller guard would miss.
    unittest { // face plane: the scalar writer, the bulk restore writer, and
        // the bulk SELECT writer's order-stamping side effect.
        auto m = makeCube();
        m.syncSelection();   // makeCube() does not size the marks arrays itself
        m.setFaceHidden(2, true);

        // Direct scalar writer. Both a hidden AND a visible face in the same
        // sequence, so "refused" reads differently from "did nothing".
        m.selectFace(2);
        m.selectFace(3);
        assert(!m.isFaceSelected(2), "selectFace must refuse a hidden face");
        assert(m.isFaceSelected(3),  "selectFace must still select a visible one");

        // Bulk restore writer (setFacesSelectedFrom / applySelectedFrom_ —
        // undo/redo snapshot replay's own primitive). One mask naming BOTH
        // faces at once.
        m.clearFaceSelection();
        auto want = new bool[](m.faces.length);
        want[2] = true; want[3] = true;
        m.setFacesSelectedFrom(want);
        assert(m.countSelectedFaces() == 1,
            "the mask asked for 2 faces; the hidden one must be refused — not both, not neither");
        assert(!m.isFaceSelected(2) && m.isFaceSelected(3));

        // Bulk SELECT writer (selectFacesFrom) must not stamp an order entry
        // for the refused face — a stale nonzero order on a
        // never-actually-selected element would corrupt select.more/less
        // and click-order-derived face winding.
        m.clearFaceSelection();
        m.selectFacesFrom(want);
        assert(m.faceSelectionOrder[2] == 0, "a refused (hidden) face must not receive an order stamp");
        assert(m.faceSelectionOrder[3] != 0, "the visible face must still be stamped");
    }

    // §3.2 — the L1 operand-mask funnel: the fallback branch ("nothing
    // selected ⇒ the whole mesh") must mean "every VISIBLE element", not
    // "every element". A real selection can never contain a hidden element
    // (§3.1, just above), so only the fallback branch needs checking.
    unittest {
        auto m = makeCube();
        m.syncSelection();   // makeCube() does not size the marks arrays itself
        m.setFaceHidden(0, true);
        m.setFaceHidden(4, true);   // non-adjacent, and index 0 is the low-index trap

        auto fmask = m.operandFaceMask();
        assert(fmask.length == 6);
        foreach (fi; 0 .. 6)
            assert(fmask[fi] == (fi != 0 && fi != 4),
                "operandFaceMask must select every VISIBLE face when nothing is selected");

        // A real selection must be returned as-is — the fallback must NOT
        // fire once something is selected.
        m.selectFace(1);
        auto fmask2 = m.operandFaceMask();
        assert(fmask2[1] && !fmask2[2], "a real selection must win over the whole-mesh fallback");

        // Vertex/edge fallbacks. Faces 0/4 alone hide no vertex (T-S0b), so
        // hide vertex 0's whole corner to get a discriminating case.
        auto m2 = makeCube();
        m2.syncSelection();
        m2.setFaceHidden(0, true);
        m2.setFaceHidden(2, true);
        m2.setFaceHidden(5, true);   // vertex 0's three incident faces
        m2.refreshHiddenDerived();
        assert(m2.isVertexHidden(0));

        auto vmask = m2.operandVertexMask(EditMode.Vertices);
        assert(!vmask[0], "operandVertexMask must exclude a hidden vertex from the whole-mesh fallback");
        assert(vmask[1],  "a visible vertex must still be included");

        auto emask = m2.operandEdgeMask();
        const uint e01 = m2.edgeIndex(0, 1);
        assert(!emask[e01], "operandEdgeMask must exclude an edge derived-hidden through its hidden endpoint");
    }

    // §3.2 shape A — the three `selectedVertexIndices*` accessors. These are
    // the only shape whose fallback returns an INDEX LIST rather than a mask,
    // and their live consumers are the transform drag (tools/transform) and
    // the magnet deform, i.e. every whole-mesh gizmo move. All three share one
    // fallback ("nothing selected ⇒ every vertex"), so all three are asserted.
    unittest {
        import std.conv : to;
        // C8d/C8e, the measured per-component law, is what makes this pair
        // discriminating: hiding two POLYGONS hides no vertex, so the vertex
        // operand set is still all 8 — an implementation that propagated the
        // face hide down to its corners reads 4 here. Hiding a whole corner's
        // faces derives exactly ONE hidden vertex, so it reads 7 — an
        // implementation that ignored hiding entirely reads 8, and one that
        // froze every vertex of a hidden face reads 4.
        auto a = makeCube();
        a.syncSelection();
        a.setFaceHidden(0, true);
        a.setFaceHidden(4, true);          // two polygons, opposite-ish
        assert(a.countHiddenVertices() == 0,
            "fixture: two polygon hides must derive NO hidden vertex (C8d)");
        assert(a.selectedVertexIndicesVertices().length == 8,
            "C8d: a polygon hide must not shrink the VERTEX operand set");
        assert(a.selectedVertexIndicesEdges().length    == 8, "C8d (edge accessor)");
        assert(a.selectedVertexIndicesFaces().length    == 8, "C8d (face accessor)");

        auto b = makeCube();
        b.syncSelection();
        b.setFaceHidden(0, true);
        b.setFaceHidden(2, true);
        b.setFaceHidden(5, true);          // vertex 0's three incident faces
        assert(b.isVertexHidden(0) && b.countHiddenVertices() == 1,
            "fixture: exactly vertex 0 derives hidden (C8e)");
        foreach (name, idx; ["Vertices": 0, "Edges": 1, "Faces": 2]) {
            auto got = idx == 0 ? b.selectedVertexIndicesVertices()
                     : idx == 1 ? b.selectedVertexIndicesEdges()
                                : b.selectedVertexIndicesFaces();
            assert(got.length == 7,
                "C8e / shape A (" ~ name ~ "): the whole-mesh fallback must return "
                ~ "7 VISIBLE vertices, got " ~ got.length.to!string);
            foreach (v; got)
                assert(v != 0, "C8e / shape A (" ~ name ~ "): vertex 0 is hidden and "
                    ~ "must not be in the whole-mesh operand set");
        }
    }

    // §3.3 — the backstop. A hand-built mask that reaches a `*ByMask` kernel
    // still cannot act on hidden geometry, even when no L1/L3 site is
    // involved: this calls the kernel DIRECTLY with an all-true mask, which is
    // precisely the shape an un-migrated caller (or a caller nobody has
    // written yet) produces.
    unittest {
        import std.conv : to;
        // flipFacesByMask is chosen because its effect is per-face and
        // readable WITHOUT any topology change: winding. So "4 of 6 flipped"
        // is checkable face by face, and the two hidden faces are asserted
        // bit-identical rather than merely counted.
        auto m = makeCube();
        m.syncSelection();
        m.setFaceHidden(1, true);
        m.setFaceHidden(3, true);

        auto before = new uint[][](m.faces.length);
        foreach (fi; 0 .. m.faces.length) before[fi] = m.faces[fi].dup;

        auto allTrueMask = new bool[](m.faces.length);
        allTrueMask[] = true;               // the un-migrated caller's mask
        const size_t n = m.flipFacesByMask(allTrueMask);

        assert(n == 4, "backstop: an all-true mask must flip the 4 VISIBLE faces, got "
            ~ n.to!string ~ " (unfiltered reads 6, a blanket refusal reads 0)");
        foreach (fi; 0 .. m.faces.length) {
            const hidden = (fi == 1 || fi == 3);
            const same   = m.faces[fi] == before[fi];
            assert(same == hidden,
                "backstop: face " ~ fi.to!string ~ (hidden ? " is hidden and must be "
                    ~ "bit-identical" : " is visible and must have been flipped"));
        }
    }

    // T-S6b / R6 — selectionSignature must react to a hide. Once the
    // whole-mesh fallback means "all VISIBLE", hiding an element changes the
    // operand set of an empty-selection op without changing its selection, so
    // a Select-only signature leaves the falloff / action-centre caches stale.
    unittest {
        auto base = makeCube();
        base.syncSelection();
        const ulong sig0 = base.selectionSignature(EditMode.Polygons);

        auto hid = makeCube();
        hid.syncSelection();
        hid.setFaceHidden(2, true);
        const ulong sigHide = hid.selectionSignature(EditMode.Polygons);
        assert(sigHide != sig0, "hiding a face must change the polygon signature");

        // The discriminator: hiding element i and SELECTING element i must
        // produce DIFFERENT signatures. A naive `mix(i+1)` for both collides,
        // and that collision is exactly what would serve a stale cache to an
        // operation whose operand set changed.
        auto sel = makeCube();
        sel.syncSelection();
        sel.selectFace(2);
        const ulong sigSel = sel.selectionSignature(EditMode.Polygons);
        assert(sigSel != sig0,  "selecting a face must change the signature");
        assert(sigSel != sigHide,
            "hiding element i and selecting element i must not collide");
    }

    unittest { // computeEdgeSharpness: cube — every one of the 12 edges is a
               // 90° dihedral, all interior, all sharp at a 30° threshold.
        Mesh m = makeCube();
        auto sharp = m.computeEdgeSharpness(30.0f);
        assert(sharp.length == m.edges.length);
        assert(sharp.length == 12);
        foreach (i, ref s; sharp) {
            assert(s.interior, "cube edge should have two adjacent faces");
            assert(s.sharp, "cube edge should be sharp at 30deg threshold");
            assert(s.angleDeg > 85.0f && s.angleDeg < 95.0f,
                   "cube dihedral should be ~90deg");
        }
        // A very permissive threshold makes every edge fall below it.
        auto notSharp = m.computeEdgeSharpness(120.0f);
        foreach (ref s; notSharp) assert(!s.sharp);
    }

    unittest { // Stage-0 parity golden (0190): providers == old inline builders;
               // CSR order == inline edge-based order (bit-stability guard for
               // smooth.d / smoothSubdivide / updateConnectMask, Stage 3).
        Mesh m = makeCube();

        // --- relation A: edge→edges-sharing-a-vertex, element-wise + per-edge order.
        int[][] edgeAdjInline = new int[][](m.edges.length);
        foreach (i; 0 .. m.edges.length)
            foreach (vi; m.edges[i])
                foreach (ni; m.edgesAroundVertex(vi))
                    if (ni != i) edgeAdjInline[i] ~= cast(int)ni;
        assert(m.edgeAdjacencySharingVertex() == edgeAdjInline,
            "edgeAdjacencySharingVertex must match the inline edge-adjacency "
            ~ "builder element-wise (including per-edge order)");

        // --- relation C: face→faces-sharing-a-vertex, element-wise + per-face order.
        uint[][] vertFacesInline = new uint[][](m.vertices.length);
        foreach (fi, face; m.faces)
            foreach (vi; face)
                vertFacesInline[vi] ~= cast(uint)fi;
        int[][] faceAdjInline = new int[][](m.faces.length);
        foreach (fi, face; m.faces) {
            bool[int] seen;
            foreach (vi; face)
                foreach (adjFi; vertFacesInline[vi])
                    if (adjFi != cast(uint)fi && (cast(int)adjFi) !in seen) {
                        seen[cast(int)adjFi] = true;
                        faceAdjInline[fi] ~= cast(int)adjFi;
                    }
        }
        assert(m.faceAdjacencySharingVertex() == faceAdjInline,
            "faceAdjacencySharingVertex must match the inline face-adjacency "
            ~ "builder element-wise");

        // --- relation D order-equality: CSR neighbor order == the inline
        // `foreach (e; edges) { neighbors[e0]~=e1; neighbors[e1]~=e0; }`
        // order, PER VERTEX. This is the SOLE runtime guarantee (not just a
        // proof-by-inspection) that Stage 3's swap of smooth.d /
        // smoothSubdivide / updateConnectMask's inline vert-neighbor build
        // for `vertexAdjacencyCSR` is bit-identical: float sums accumulate
        // in iteration order, so ORDER (not merely the neighbor SET) must
        // match exactly, or the smoothed positions diverge in the last bit.
        // Checked on two topologies (uniform-valence cube + a subdivided
        // mesh with non-uniform valence) so this is not a single-valence
        // coincidence that a reorder elsewhere in the file could sneak past.
        import std.conv : text;
        static void checkOrderEquality(ref Mesh mm) {
            uint[][] neighborsInline = new uint[][](mm.vertices.length);
            foreach (e; mm.edges) {
                neighborsInline[e[0]] ~= e[1];
                neighborsInline[e[1]] ~= e[0];
            }
            const(size_t)[] off;
            const(uint)[] nbrs;
            mm.vertexAdjacencyCSR(off, nbrs);
            assert(off.length == mm.vertices.length + 1,
                "CSR offset array length must be vertices.length + 1");
            foreach (vi; 0 .. mm.vertices.length) {
                auto csrSlice = nbrs[off[vi] .. off[vi + 1]];
                assert(csrSlice.length == neighborsInline[vi].length,
                    text("CSR neighbor COUNT must match inline edge-based count at vertex ", vi));
                foreach (k; 0 .. csrSlice.length)
                    assert(csrSlice[k] == neighborsInline[vi][k],
                        text("CSR neighbor ORDER must match inline edge-based order at vertex ", vi,
                             " position ", k, " (bit-stability for smooth.d/smoothSubdivide float sums)"));
            }
        }
        checkOrderEquality(m);

        bool[] allMask = new bool[](m.faces.length);
        allMask[] = true;
        Mesh sub = facetedSubdivide(m, allMask);
        checkOrderEquality(sub);
    }

    unittest {
        // fillSelectionHoles: a CONNECTED 4x4 block selection missing ONE
        // interior face leaves a single-face "hole" -- fully enclosed by
        // the selection, far smaller than it -- which must be folded back
        // in, collapsing the selection to a single connected component.
        auto m = makeGridPlane(6);
        assert(m.faces.length == 36);

        bool[] mask = new bool[](36);
        foreach (i; 1 .. 5) foreach (j; 1 .. 5)
            if (!(i == 2 && j == 3)) mask[i * 6 + j] = true;
        assert(!mask[2 * 6 + 3]);

        size_t selBefore = 0;
        foreach (b; mask) if (b) ++selBefore;
        assert(selBefore == 15);

        auto filled = m.fillSelectionHoles(mask);
        assert(filled[2 * 6 + 3], "the fully-enclosed single-face hole must be filled");

        size_t selAfter = 0;
        foreach (b; filled) if (b) ++selAfter;
        assert(selAfter == 16, "exactly the one missing face should be added back");

        auto faceAdj = m.faceAdjacencySharingVertex();
        auto comps = Mesh.faceComponentsOf(filled, faceAdj);
        assert(comps.length == 1, "the filled 4x4 block must be a single connected component");
    }

    unittest {
        // fillSelectionHoles: the "rest of the model" component (>= selCount)
        // must never be swallowed, even on a CLOSED mesh where it has no
        // open boundary at all (so the enclosure check alone would
        // otherwise pass).
        auto m = makeCube();
        bool[] mask = new bool[](m.faces.length);
        mask[0] = true; // select just 1 of the cube's 6 faces
        auto filled = m.fillSelectionHoles(mask);
        size_t selAfter = 0;
        foreach (b; filled) if (b) ++selAfter;
        assert(selAfter == 1, "a single selected face on a closed mesh must NOT swallow the other 5");
    }

    unittest {
        // fillSelectionHoles: two disjoint selected blocks separated by a
        // wide unselected gap (which also touches the mesh's own open
        // boundary -- not enclosed, and far larger than either block) must
        // be left completely alone, then split into 2 components.
        auto m = makeGridPlane(10);
        bool[] mask = new bool[](100);
        foreach (i; 1 .. 3) foreach (j; 1 .. 3) mask[i * 10 + j] = true; // block A, 2x2
        foreach (i; 6 .. 8) foreach (j; 6 .. 8) mask[i * 10 + j] = true; // block B, 2x2

        auto filled = m.fillSelectionHoles(mask);
        assert(filled == mask, "no small enclosed hole exists -- mask must be unchanged");

        auto faceAdj = m.faceAdjacencySharingVertex();
        auto comps = Mesh.faceComponentsOf(filled, faceAdj);
        assert(comps.length == 2, "two disjoint blocks must split into 2 connected components");
    }

// ---------------------------------------------------------------------------
// visibleVertices under a mirrored ModelSpace (task 0617 follow-up).
//
// The previous version of this fixture used a single flat quad centred on
// the origin: mirroring across X maps that quad's vertex SET to itself (same
// world pixels, same depth, only winding reversed), so the only thing the
// old assertion could measure was "did the flip line run" — not whether its
// answer was geometrically correct. It asserted visible-at-identity flips to
// hidden-when-mirrored, which is wrong on its face: a quad that is drawn at
// the literal same world position and orientation cannot become invisible
// just because its LOCAL vertex order changed.
//
// This fixture uses a cube translated off the mirror axis (local x in
// [1.5, 2.5], not straddling x=0), so the mirrored WORLD cube actually sits
// somewhere else (x in [-2.5, -1.5]) — mirroring is no longer a no-op on the
// drawn geometry. With the eye off-axis too (not on the mirror plane), the
// two per-vertex corner classifications below are independently verifiable
// by hand: at each pose, the cube corner nearest the eye must read visible,
// and the corner farthest from the eye — occluded by the cube itself on
// every side — must read hidden.
// ---------------------------------------------------------------------------
unittest {
    import math : lookAt, perspectiveMatrix, ModelSpace;
    import std.math : PI;

    Mesh m;
    // makeCube()'s layout, translated +2 along local X so the cube does not
    // straddle x=0 (the mirror axis used below).
    m.vertices = [
        Vec3( 1.5f, -0.5f, -0.5f), // 0
        Vec3( 2.5f, -0.5f, -0.5f), // 1
        Vec3( 2.5f,  0.5f, -0.5f), // 2
        Vec3( 1.5f,  0.5f, -0.5f), // 3
        Vec3( 1.5f, -0.5f,  0.5f), // 4
        Vec3( 2.5f, -0.5f,  0.5f), // 5
        Vec3( 2.5f,  0.5f,  0.5f), // 6
        Vec3( 1.5f,  0.5f,  0.5f), // 7
    ];
    m.faces = [
        [0u, 3u, 2u, 1u], // z = -0.5 (-Z)
        [4u, 5u, 6u, 7u], // z = +0.5 (+Z)
        [0u, 4u, 7u, 3u], // x = +1.5 (min-X face of this cube)
        [1u, 2u, 6u, 5u], // x = +2.5 (max-X face of this cube)
        [3u, 7u, 6u, 2u], // y = +0.5 (+Y)
        [0u, 1u, 5u, 4u], // y = -0.5 (-Y)
    ];

    Viewport vp;
    vp.eye  = Vec3(5, 5, 5); // off both the mirror plane (x=0) and the cube
    vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width = 400; vp.height = 400;

    // Fixture premise at IDENTITY: corner 6 (2.5,0.5,0.5) is the cube's
    // nearest corner to the eye — it sits on all three eye-facing faces
    // (+X, +Y, +Z) and nothing occludes it — so it must read visible.
    // Corner 0 (1.5,-0.5,-0.5) is the farthest corner, sitting on all three
    // AWAY-facing faces (min-X, -Y, -Z), so every face it belongs to is
    // back-facing and it must read hidden.
    bool[] visIdentity = m.visibleVertices(vp.eye, vp, ModelSpace.world());
    assert(visIdentity[6] == true,
        "fixture: at identity the cube corner nearest the eye must be visible");
    assert(visIdentity[0] == false,
        "fixture: at identity the cube corner farthest from the eye must be hidden");

    // Mirror across X: m = diag(-1,1,1), self-inverse, det < 0. Drawn world
    // cube now spans x in [-2.5, -1.5] — a different place than the local
    // cube, not a no-op.
    ModelSpace ms;
    ms.m          = [-1,0,0,0,  0,1,0,0,  0,0,1,0,  0,0,0,1];
    ms.mInv       = ms.m;               // diag(-1,1,1) is its own inverse
    ms.isIdentity = false;
    ms.invertible = true;
    ms.mirrored   = true;

    // Under the mirror, local corner 7 (1.5,0.5,0.5) is drawn at world
    // (-1.5,0.5,0.5) — the corner of the mirrored cube nearest eye (5,5,5)
    // (nearest in x among [-2.5,-1.5] is -1.5; nearest in y,z among
    // [-0.5,0.5] is 0.5) — so it must read visible. Local corner 1
    // (2.5,-0.5,-0.5) is drawn at world (-2.5,-0.5,-0.5), the farthest
    // corner from the eye, and must read hidden. A cull that reintroduces
    // the old `ms.mirrored` XOR gets this exactly backwards (see
    // `ModelSpace.mirrored`'s doc comment in math.d): it would report
    // corner 1 visible and corner 7 hidden instead.
    bool[] visMirrored = m.visibleVertices(vp.eye, vp, ms);
    assert(visMirrored[7] == true,
        "a mirrored ModelSpace's nearest-to-eye drawn corner must read visible");
    assert(visMirrored[1] == false,
        "a mirrored ModelSpace's farthest-from-eye drawn corner must read hidden");
}

// ---------------------------------------------------------------------------
// MeshCacheKey.matches: address is the sole discriminator when
// mutationVersion collides across two distinct Mesh instances.
// ---------------------------------------------------------------------------
unittest {
    Mesh a, b;
    a.vertices = [Vec3(0, 0, 0)];
    b.vertices = [Vec3(0, 0, 0)];
    a.mutationVersion = 7;
    b.mutationVersion = 7;   // hand-forced equal version — the aliasing hazard

    MeshCacheKey key;
    key.stamp(a);
    assert(key.matches(a), "key stamped from a must match a");
    assert(!key.matches(b),
        "key stamped from a must NOT match b even when mutationVersion is equal — "
        ~ "address is the sole discriminator");

    key.invalidate();
    assert(!key.matches(a), "invalidate() must fail every match");
    assert(!key.matches(b), "invalidate() must fail every match");
}

// ---------------------------------------------------------------------------
// vertexAdjacencyCSR provider isolation: two Mesh values at an equal
// hand-forced mutationVersion but DIFFERENT connectivity must yield
// DIFFERENT adjacency — each Mesh owns its own cache, so there is no
// address term to get wrong (the cache lives ON the object).
// ---------------------------------------------------------------------------
unittest {
    // a: a 4-cycle 0-1-2-3-0 (every vertex has 2 neighbors).
    Mesh a;
    a.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    a.resetSelection();
    a.addEdge(0, 1); a.addEdge(1, 2); a.addEdge(2, 3); a.addEdge(3, 0);

    // b: two disjoint edges 0-1, 2-3 (every vertex has 1 neighbor).
    Mesh b;
    b.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    b.resetSelection();
    b.addEdge(0, 1); b.addEdge(2, 3);

    a.mutationVersion = 7;
    b.mutationVersion = 7;   // hand-forced equal version, same vertex count

    const(size_t)[] offA, offB;
    const(uint)[]    nbA,  nbB;
    a.vertexAdjacencyCSR(offA, nbA);
    b.vertexAdjacencyCSR(offB, nbB);

    // Vertex 0's neighbor set differs: {1, 3} in the cycle vs {1} alone
    // in the disjoint-edges mesh.
    assert(offA[1] - offA[0] == 2, "cycle: vertex 0 must have 2 neighbors");
    assert(offB[1] - offB[0] == 1, "disjoint edges: vertex 0 must have 1 neighbor");
    assert(nbA[offA[0] .. offA[1]] != nbB[offB[0] .. offB[1]],
        "equal mutationVersion must NOT make two distinct Mesh instances "
        ~ "share adjacency — each Mesh owns its own CSR cache");
}

unittest { // makeGridPlane: vertex/face/edge counts + half-edge validity
    // n×n quads → (n+1)² verts, n² faces. Edges: each cell has 4 edges, but
    // interior edges are shared → dedup count is the closed-form
    // 2·n·(n+1) (n+1 lines each way, each split into n segments).
    foreach (n; [1, 2, 3, 4]) {
        Mesh m = makeGridPlane(n);
        immutable size_t side = n + 1;
        assert(m.vertices.length == side * side);
        assert(m.faces.length    == cast(size_t)n * n);
        assert(m.edges.length    == cast(size_t)2 * n * (n + 1));

        // Half-edge structure must be fully populated: buildLoops emits one
        // loop per face-corner, and every face's loops must resolve.
        size_t totalCorners = 0;
        foreach (ref f; m.faces) totalCorners += f.length;
        assert(m.loops.length    == totalCorners);
        assert(m.faceLoop.length == m.faces.length);
        assert(m.loopEdge.length == m.loops.length);

        // Every vertex index referenced by a face is in range, and every
        // face is a quad on the y = 0 plane.
        foreach (ref f; m.faces) {
            assert(f.length == 4);
            foreach (vi; f) {
                assert(vi < m.vertices.length);
                assert(m.vertices[vi].y == 0.0f);
            }
        }
    }
}

unittest { // subdivideCube: counts match uniform Catmull-Clark + valid loops
    // Cube → uniform CC. After L passes a quad-only mesh has
    //   F = 6 · 4^L faces, E = 2·F edges (every edge shared by 2 quads),
    //   V = E − F + 2 (Euler, genus 0).
    foreach (L; [1, 2]) {
        Mesh m = subdivideCube(L);
        immutable size_t F = 6 * (4UL ^^ L);
        immutable size_t E = 2 * F;
        immutable size_t V = E - F + 2;
        assert(m.faces.length    == F);
        assert(m.edges.length    == E);
        assert(m.vertices.length == V);

        // Fully valid editable mesh: loops resolve, all quads, indices in range.
        size_t totalCorners = 0;
        foreach (ref f; m.faces) {
            assert(f.length == 4);
            totalCorners += f.length;
            foreach (vi; f) assert(vi < m.vertices.length);
        }
        assert(m.loops.length    == totalCorners);
        assert(m.faceLoop.length == m.faces.length);
        assert(m.loopEdge.length == m.loops.length);
    }
}

unittest { // cube twin graph: involutive + complete + correct vertex ring (R1 guard)
    // A closed manifold cube has 24 loops (6 faces × 4 corners), 12 edges.
    // Every loop must have a valid twin (no boundary on a closed cube).
    Mesh m = makeCube();
    assert(m.loops.length == 24, "cube: 24 loops");
    assert(m.edges.length == 12, "cube: 12 edges");

    // Involutive: twin-of-twin == self for every loop.
    foreach (li; 0 .. m.loops.length) {
        uint t = m.loops[li].twin;
        assert(t != ~0u, "cube loop has no boundary twin");
        assert(m.loops[t].twin == cast(uint)li,
               "cube twin graph not involutive");
    }

    // verticesAroundVertex(0): cube vertex 0 is shared by 3 faces.
    // makeCube() defines faces [0,3,2,1], [0,4,7,3], [0,1,5,4]
    // → edges from 0: to 3, to 4, to 1 → neighbors {1, 3, 4}.
    import std.algorithm : sort;
    uint[] nb0;
    foreach (v; m.verticesAroundVertex(0)) nb0 ~= v;
    nb0.sort();
    assert(nb0 == [1u, 3u, 4u], "cube v0 neighbors must be {1,3,4}");
}

unittest { // non-manifold book: spine edge (3 faces) → all spine twins == ~0u (treatment A)
    // Three triangles sharing edge v0-v1 (the "spine"):
    //   face 0: [0,1,2],  face 1: [0,1,3],  face 2: [0,1,4]
    // After treatment A, the spine edge's 3 loops all get twin==~0u
    // (boundary-like).  Page edges (v0-v2, v0-v3, v0-v4, v1-v2, v1-v3,
    // v1-v4) are genuine boundary edges (one face each) → also twin==~0u.
    // Twin graph everywhere is trivially involutive (all boundary).
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),      // 0 — spine endpoint A
        Vec3(1, 0, 0),      // 1 — spine endpoint B
        Vec3(0.5f,  1, 0),  // 2 — page 0 tip
        Vec3(0.5f, -1, 0),  // 3 — page 1 tip
        Vec3(-0.5f, 0, 1),  // 4 — page 2 tip
    ];
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 1u, 3u]);
    m.addFace([0u, 1u, 4u]);
    m.buildLoops();

    // 3 triangles = 9 loops.  Spine + 6 page edges = 7 edges total.
    assert(m.loops.length == 9, "book: 9 loops");
    assert(m.edges.length == 7, "book: 7 edges (1 spine + 6 page)");

    // Find the spine edge index (shared by all 3 faces).
    uint spineEi = ~0u;
    foreach (ei; 0 .. m.edges.length) {
        uint va = m.edges[ei][0], vb = m.edges[ei][1];
        bool isSpine = (va == 0 && vb == 1) || (va == 1 && vb == 0);
        if (isSpine) { spineEi = cast(uint)ei; break; }
    }
    assert(spineEi != ~0u, "spine edge not found");

    // Under treatment A: all 3 spine loops must have twin==~0u.
    uint spineLoopCount = 0;
    foreach (li; 0 .. m.loops.length) {
        if (m.loopEdge[li] == spineEi) {
            assert(m.loops[li].twin == ~0u,
                   "spine loop twin must be ~0u under treatment A");
            ++spineLoopCount;
        }
    }
    assert(spineLoopCount == 3, "exactly 3 spine loops");

    // Twin graph is involutive everywhere (every non-~0u twin reciprocates).
    // On this all-boundary mesh every twin==~0u, so no pair violations.
    foreach (li; 0 .. m.loops.length) {
        uint t = m.loops[li].twin;
        if (t != ~0u)
            assert(m.loops[t].twin == cast(uint)li,
                   "twin graph not involutive at loop");
    }

    // Ring walks terminate (length is finite — no MAX_STEPS truncation needed)
    // AND, since task 1290, they are COMPLETE at a spine vertex.
    //
    // WHAT THIS BLOCK USED TO ASSERT, AND WHY IT NO LONGER DOES. It pinned
    // `nb0.length == 2` with the reasoning "treatment A: the walk truncates at
    // the first boundary/non-manifold edge, so each spine vertex sees exactly
    // 2 neighbours from its single anchored dart". That truncation was the
    // defect, not the contract: treatment A gives every spine dart
    // `twin == ~0u`, which is the same sentinel an OPEN RIM carries, so the
    // ordered twin-walk stopped there and v0 — a vertex genuinely on four
    // edges — reported two. Task 1290 marks both endpoints of a non-manifold
    // edge NOT `vertexFanOrdered`, which routes them through the complete CSR
    // fan walk (the same fallback a same-direction edge has always taken). The
    // twin values themselves are unchanged and are still asserted above; only
    // the WALK is no longer truncated by them.
    uint[] nb0;
    foreach (v; m.verticesAroundVertex(0)) nb0 ~= v;
    nb0.sort();
    assert(nb0 == [1u, 2u, 3u, 4u],
           "book v0: the complete fan is {1,2,3,4} — the spine plus all three "
           ~ "page tips (2 under the old truncating walk)");

    // Spine endpoint v1 is symmetric.
    uint[] nb1;
    foreach (v; m.verticesAroundVertex(1)) nb1 ~= v;
    nb1.sort();
    assert(nb1 == [0u, 2u, 3u, 4u], "book v1: the complete fan is {0,2,3,4}");

    // Both spine faces are reachable from a spine vertex, all three of them.
    uint[] fr0;
    foreach (f; m.facesAroundVertex(0)) fr0 ~= f;
    fr0.sort();
    assert(fr0 == [0u, 1u, 2u],
           "book v0: all three pages are incident on the spine vertex");

    // Non-vacuous: a PAGE TIP is not on the non-manifold edge, so its fan is
    // untouched by any of this and still walks the ordered path.
    assert(m.vertexFanOrdered(2),
           "a page tip's fan stays ordered — only the spine endpoints change");

    // Page tip v2 has 2 incident edges (v0-v2 and v1-v2), both boundary → 2 neighbors.
    uint[] nb2;
    foreach (v; m.verticesAroundVertex(2)) nb2 ~= v;
    assert(nb2.length == 2, "book v2: exactly 2 neighbors");

    // adjacentFaces(face 0): all its edges are boundary/non-manifold (twin==~0u)
    // → AdjacentFaceRange skips them → 0 adjacent faces.
    uint adjCount = 0;
    foreach (_; m.adjacentFaces(0)) ++adjCount;
    assert(adjCount == 0,
           "book face 0: no adjacent faces (spine treated as boundary under A)");

    // edgesAroundVertex(0) terminates with a finite result.
    uint[] edgeRing0;
    foreach (e; m.edgesAroundVertex(0)) edgeRing0 ~= e;
    assert(edgeRing0.length > 0 && edgeRing0.length < 64,
           "book v0 edge ring terminates");

    // vertexAdjacencyCSR (relation D, edge-based) vs verticesAroundVertex
    // (relation E, loop-based fan walk): the two relations are NOT the same
    // relation, and `connect.d`'s Vertices mode is left unfolded onto
    // `vertexAdjacencyCSR` (task 0190) because substituting one for the other
    // would silently change connected-component reachability.
    //
    // THIS GUARD'S WITNESS MOVED IN TASK 1290, AND THAT IS THE POINT OF
    // WRITING IT DOWN. It used to be anchored HERE, on the book: CSR saw v0's
    // four incident edges while the fan walk truncated at the non-manifold
    // spine and saw two, so `csrSet0 != loopSet0` held. That inequality was
    // not a property of the two relations — it was the truncation bug, and the
    // guard was resting on it. With the fan walk fixed the two now AGREE on
    // this vertex, so asserting inequality here would be asserting that the
    // bug is still present.
    //
    // The guard itself is still true and still needed; it just needs a witness
    // that is a real difference between the relations rather than a defect.
    // That witness is a BARE WIRE EDGE: `vertexAdjacencyCSR` reads `edges[]`,
    // while `vertLoop` is seeded only from FACE CORNERS, so an edge no face
    // uses is invisible to every fan walk. Measured below, and it is the same
    // asymmetry `vertexEdgeCounts` exists for.
    import std.algorithm : sort;
    const(size_t)[] csrOff;
    const(uint)[]   csrNbrs;
    m.vertexAdjacencyCSR(csrOff, csrNbrs);
    uint[] csrSet0 = csrNbrs[csrOff[0] .. csrOff[1]].dup;
    csrSet0.sort();
    uint[] loopSet0 = nb0.dup;
    loopSet0.sort();
    assert(csrSet0 == loopSet0,
        "book v0: with the fan walk no longer truncating at a non-manifold "
        ~ "edge, the edge-based CSR and the loop-based walk must now agree "
        ~ "here — {1,2,3,4} both ways");
}

unittest { // the CSR (relation D) and the fan walk (relation E) still differ,
           // on a bare wire edge — the witness that survives task 1290 and the
           // one that actually guards connect.d's Vertices mode against being
           // folded onto vertexAdjacencyCSR (task 0190).
    import std.algorithm : sort;

    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
        Vec3(-1, 0, 0),   // 4 — reachable from v0 by an edge NO FACE uses
    ];
    m.faces = [[0u, 1u, 2u, 3u]];
    m.rebuildEdgesFromFaces();
    m.addEdge(0u, 4u);          // bare wire
    m.buildLoops();
    m.resetSelection();

    uint[] loopSet;
    foreach (v; m.verticesAroundVertex(0)) loopSet ~= v;
    loopSet.sort();

    const(size_t)[] off;
    const(uint)[]   nbrs;
    m.vertexAdjacencyCSR(off, nbrs);
    uint[] csrSet = nbrs[off[0] .. off[1]].dup;
    csrSet.sort();

    assert(csrSet == [1u, 3u, 4u],
        "the edge-based CSR sees the wire's far endpoint");
    assert(loopSet == [1u, 3u],
        "the loop-based fan walk cannot: vertLoop is seeded from face corners "
        ~ "only, so an edge no face uses is invisible to it");
    assert(csrSet != loopSet,
        "the two relations must still differ somewhere — folding connect.d's "
        ~ "Vertices mode onto vertexAdjacencyCSR would change connected-"
        ~ "component reachability across loose wire geometry");
}

unittest { // facetedSubdivide: a hidden cage face comes through as exactly ONE
           // hidden face — the mark is neither dropped nor split (task 0632).
    import std.math : fabs;
    import std.conv : to;

    // Vacuity guard. With nothing hidden this same kernel is the wholesale
    // 24-quad refine, so the 21 below is a measurement of the exclusion and
    // not merely the number this kernel always produces.
    {
        Mesh all = makeCube();
        bool[] allMask = new bool[](all.faces.length);
        allMask[] = true;
        assert(facetedSubdivide(all, allMask).faces.length == 24,
            "vacuity: an unrestricted faceted subdivide of the cube is 24 faces");
    }

    Mesh m = makeCube();
    m.syncSelection();   // makeCube() does not size the marks arrays itself
    // Hide a MIDDLE face, never the last one. With the hidden face at f5 an
    // operand mask that was one element SHORT would exclude it for entirely
    // the wrong reason (an out-of-range read counts as unmarked), and the row
    // could not tell that implementation from the intended one.
    // makeCube's f2 = [0,4,7,3] is the x = -0.5 side.
    m.setFaceHidden(2, true);
    m.refreshHiddenDerived();

    Mesh sub = facetedSubdivide(m, m.visibleFaceMask());

    // 5 visible quads × 4 children + the hidden one carried through whole.
    assert(sub.faces.length == 21,
        "hidden face excluded from the operand: 5*4 + 1 = 21 faces");

    size_t nHidden = 0, hi = size_t.max;
    foreach (fi; 0 .. sub.faces.length)
        if (sub.isFaceHidden(fi)) { ++nHidden; hi = fi; }
    // Three readings, three different numbers: 0 = the rebuild dropped the
    // mark, 4 = the hidden face was refined and every child inherited the bit,
    // 1 = it was kept out of the operation. Only the last is the measured law,
    // and a test that asserted merely "hiding was not lost" would pass on two
    // of the three.
    assert(nHidden == 1,
        "exactly one hidden face must survive, got "
        ~ nHidden.to!string ~ " (0 = the rebuild dropped the mark, "
        ~ "4 = the hidden face was refined and every child inherited it)");

    // ...and it must be THE face that was hidden, not merely SOME face. The
    // survivor is the -X side carried across whole: eight corners (its four
    // originals plus the four edge points its refined neighbours spliced in),
    // every one of them at x = -0.5. Any other cube side spans x from -0.5 to
    // +0.5, and a refined CHILD of the hidden face would have four corners.
    assert(sub.faces[hi].length == 8,
        "the survivor is the widened cage face, not a refined child of it — "
        ~ "got " ~ sub.faces[hi].length.to!string ~ " corners, want 8");
    foreach (vi; sub.faces[hi])
        assert(fabs(sub.vertices[vi].x + 0.5f) < 1e-6f,
            "the survivor must be the x = -0.5 side — the face that was hidden");
}

unittest { // smoothSubdivide: cube → same topology as faceted; corners ≈ 0.41667
    import std.math : fabs;
    Mesh m = makeCube();
    bool[] mask = new bool[](m.faces.length);
    mask[] = true;

    Mesh sm = smoothSubdivide(m, mask);

    // Topology: identical to facetedSubdivide (26 verts, 48 edges, 24 quads).
    assert(sm.vertices.length == 26,
        "smoothSubdivide: expected 26 verts, got " ~ sm.vertices.length.stringof);
    assert(sm.edges.length    == 48,
        "smoothSubdivide: expected 48 edges");
    assert(sm.faces.length    == 24,
        "smoothSubdivide: expected 24 faces");

    // Analytic golden for cube corners after one Laplacian pass (λ=0.5):
    // Original corner at (0.5, 0.5, 0.5) has exactly 3 edge-midpoint
    // neighbors after faceted split. avg = (1/3, 1/3, 1/3) (by symmetry).
    // new = 0.5 + 0.5*(1/3 - 0.5) = 0.5 - 1/12 = 5/12 ≈ 0.41667.
    // facetedSubdivide preserves original vert indices: first 8 are cage corners.
    foreach (vi; 0 .. 8) {
        Vec3 v = sm.vertices[vi];
        assert(fabs(fabs(v.x) - 5.0f/12.0f) < 1e-4f
            && fabs(fabs(v.y) - 5.0f/12.0f) < 1e-4f
            && fabs(fabs(v.z) - 5.0f/12.0f) < 1e-4f,
            "smoothSubdivide: cage corner should relax to ≈ ±5/12 ≈ ±0.41667");
    }
}

unittest { // edgeLoopRing: valence-3 cube degenerates to the seed-edge fallback
    // A plain cube's 8 corners are all valence-3, so the loop walk has no
    // unambiguous "straight across" continuation at any vertex and bails to
    // the seed-edge fallback `[v0, v1]`. Pin that documented limitation so a
    // regression that silently changed the cube's loop behaviour is caught;
    // the REAL closed-loop walk is exercised on the valence-4 torus below
    // (and end-to-end by tests/fixtures/element_move.json
    // `element_move_edgeloops_lin_r0p5`).
    Mesh cube = makeCube();   // 6 quad faces, 12 edges, 8 valence-3 verts
    auto e = cube.edges[0];
    auto fb = edgeLoopRing(cube, e[0], e[1]);
    assert(fb.length == 2);
    assert(fb[0] == e[0] && fb[1] == e[1]);
}

unittest { // edgeLoopRing walks a REAL closed loop on a valence-4 quad torus
    // Build a quad torus: R major rings × S minor segments, BOTH directions
    // wrapping. Every vertex is valence-4 and every face is a quad, so the
    // edge-loop walk has a well-defined "straight across" continuation at
    // each vertex — exactly the topology edgeLoopRing is designed for (unlike
    // the valence-3 cube above, which falls back to the seed edge).
    //
    //   idx(r, s) = (r % R) * S + (s % S)
    //   face q(r, s) = [idx(r,s), idx(r,s+1), idx(r+1,s+1), idx(r+1,s)]
    //
    // A seed along the MAJOR direction (fixed minor column s, stepping r)
    // continues straight across each valence-4 vertex to the next major
    // neighbour, wrapping the whole major circle: idx(0,0) → idx(1,0) →
    // idx(2,0) → idx(3,0) → back to idx(0,0). So the ring is the ordered
    // major circle of exactly R verts and is CLOSED.
    enum int R = 4;          // major rings
    enum int S = 3;          // minor segments
    Mesh m;
    m.vertices.length = R * S;
    foreach (r; 0 .. R)
        foreach (s; 0 .. S)
            m.vertices[r * S + s] = Vec3(cast(float)r, cast(float)s, 0.0f);

    static uint idx(int r, int s) { return cast(uint)(((r % R) * S) + (s % S)); }
    foreach (r; 0 .. R)
        foreach (s; 0 .. S)
            m.addFace([idx(r, s), idx(r, s + 1), idx(r + 1, s + 1), idx(r + 1, s)]);
    m.buildLoops();

    assert(m.vertices.length == R * S);   // 12 verts
    assert(m.faces.length    == R * S);   // 12 quad faces (closed torus)

    // Major-direction seed (0,0) → (1,0): expect the closed major circle.
    auto ring = edgeLoopRing(m, idx(0, 0), idx(1, 0));

    // (a) A real loop ran, not the 2-vert fallback.
    assert(ring.length > 2);
    // (b) It is the full closed major circle of exactly R verts.
    assert(ring.length == R);
    // (c) All verts are unique.
    foreach (i; 0 .. ring.length)
        foreach (j; i + 1 .. ring.length)
            assert(ring[i] != ring[j]);

    // The ring is the ordered major circle through column s == 0, i.e. each
    // entry is a multiple of S (no minor offset), and the four entries are
    // exactly the four major-circle verts. This nails the loop's identity,
    // not just its length.
    bool[uint] seen;
    foreach (v; ring) {
        assert(v % S == 0);                 // on the s == 0 minor column
        seen[v] = true;
    }
    foreach (r; 0 .. R)
        assert(idx(r, 0) in seen);          // every major-ring vert present

    // It forms a cycle: consecutive ring verts (wrapping last→first) are
    // each one major step apart (a mesh edge exists between them).
    foreach (i; 0 .. ring.length) {
        uint a = ring[i];
        uint b = ring[(i + 1) % ring.length];
        bool adjacent = false;
        foreach (ed; m.edges)
            if ((ed[0] == a && ed[1] == b) || (ed[0] == b && ed[1] == a)) {
                adjacent = true;
                break;
            }
        assert(adjacent);
    }
}

unittest { // ring verts → cage-edge-index mask (the edge-loop HOVER mask path)
    // Mirrors app.d's rebuildLoopHoverMask: walk the loop ring through a
    // hovered edge, then map each consecutive ring vert pair (CLOSED:
    // last→first too) back to its cage edge via edgeKey + edgeIndexMap. On a
    // CLOSED loop the mask has exactly `ring.length` edges set (one per pair,
    // wrapping). Built on the same valence-4 quad torus as the ring walk above.
    enum int R = 4;          // major rings
    enum int S = 3;          // minor segments
    Mesh m;
    m.vertices.length = R * S;
    foreach (r; 0 .. R)
        foreach (s; 0 .. S)
            m.vertices[r * S + s] = Vec3(cast(float)r, cast(float)s, 0.0f);
    static uint idx(int r, int s) { return cast(uint)(((r % R) * S) + (s % S)); }
    foreach (r; 0 .. R)
        foreach (s; 0 .. S)
            m.addFace([idx(r, s), idx(r, s + 1), idx(r + 1, s + 1), idx(r + 1, s)]);
    m.buildLoops();

    // Closed major circle through column s == 0: ring length == R.
    auto ring = edgeLoopRing(m, idx(0, 0), idx(1, 0));
    assert(ring.length == R);

    // Build the loop-edge mask exactly as rebuildLoopHoverMask does.
    auto mask = new bool[](m.edges.length);
    foreach (i; 0 .. ring.length) {
        uint a = ring[i];
        uint b = ring[(i + 1) % ring.length];
        if (a == b) continue;
        if (auto p = edgeKey(a, b) in m.edgeIndexMap) {
            uint ei = *p;
            assert(ei < mask.length);
            mask[ei] = true;
        }
    }

    // (a) Exactly R edges are set — one per consecutive pair, closed.
    int set = 0;
    foreach (e; mask) if (e) set++;
    assert(set == R);

    // (b) Each set edge is precisely a major-circle edge idx(r,0)→idx(r+1,0)
    //     and EVERY such edge is present (the full closed ring, no stray
    //     minor-direction or cross-loop edges).
    bool[ulong] expected;
    foreach (r; 0 .. R)
        expected[edgeKey(idx(r, 0), idx(r + 1, 0))] = true;
    assert(expected.length == R);   // R distinct major edges
    foreach (ei, e; mask) {
        if (!e) continue;
        ulong k = edgeKey(m.edges[ei][0], m.edges[ei][1]);
        assert(k in expected);      // every set edge is a major-circle edge
        expected.remove(k);
    }
    assert(expected.length == 0);   // every major edge was covered

    // (c) The single hovered seed edge is among the masked edges (the hover
    //     preview always contains the edge under the cursor).
    auto seed = m.edges[0];
    auto seedRing = edgeLoopRing(m, seed[0], seed[1]);
    auto seedMask = new bool[](m.edges.length);
    foreach (i; 0 .. seedRing.length) {
        uint a = seedRing[i], b = seedRing[(i + 1) % seedRing.length];
        if (a == b) continue;
        if (auto p = edgeKey(a, b) in m.edgeIndexMap) seedMask[*p] = true;
    }
    assert(seedMask[0]);            // edge 0 (the hovered seed) is lit
}

unittest { // flipFacesByMask: winding reversed, normal negated, edge set invariant, self-inverse
    import std.algorithm : sort;
    import std.conv : to;
    import mesh_edit_delta : MeshEditScope;

    Mesh m = makeCube();
    Mesh ref_ = makeCube(); // pristine reference for other-face comparison

    // Capture pre-flip state for face 0.
    auto face0Before = m.faces[0].dup;
    Vec3 norm0Before = m.faceNormal(0);

    // Capture the edge multiset (sorted canonical keys, order-independent).
    ulong[] edgesBefore;
    foreach (e; m.edges) edgesBefore ~= edgeKey(e[0], e[1]);
    edgesBefore.sort();

    // Flip face 0 only.
    auto mask = new bool[](m.faces.length);
    mask[0] = true;
    const n = m.flipFacesByMask(mask);
    assert(n == 1, "flipFacesByMask should report 1 flipped face");

    // Winding must be reversed.
    auto face0After = m.faces[0].dup;
    assert(face0After.length == face0Before.length, "face 0 arity changed");
    foreach (i; 0 .. face0Before.length)
        assert(face0After[i] == face0Before[face0Before.length - 1 - i],
               "face 0 corner " ~ i.to!string ~ " not reversed");

    // Normal must be negated (dot product < -0.99).
    Vec3 norm0After = m.faceNormal(0);
    assert(dot(norm0After, norm0Before) < -0.99f,
           "face 0 normal not negated after flip");

    // Edge set must be invariant (R1 guard).
    ulong[] edgesAfter;
    foreach (e; m.edges) edgesAfter ~= edgeKey(e[0], e[1]);
    edgesAfter.sort();
    assert(edgesAfter == edgesBefore, "edge set changed after flip (R1 violated)");

    // Other faces must be unchanged.
    foreach (fi; 1 .. m.faces.length)
        assert(m.faces[fi][] == ref_.faces[fi][],
               "untouched face " ~ fi.to!string ~ " changed after flip");

    // Self-inverse: flip face 0 a second time must restore original winding.
    m.flipFacesByMask(mask);
    assert(m.faces[0][] == face0Before[], "flip∘flip ≠ identity for face winding");

    // Empty mask (all-false) must be a no-op that returns 0.
    auto zeroMask = new bool[](m.faces.length);
    const n2 = m.flipFacesByMask(zeroMask);
    assert(n2 == 0, "all-false mask must return 0");
    assert(m.faces[0][] == face0Before[], "all-false mask must not mutate faces");
}

unittest { // flipFacesByMask: PolyVertex (UV) map follows reversed winding (R5)
    import std.conv : to;

    // Build a 2-face mesh (two quads sharing one edge) and attach a UV map.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), // 0
        Vec3(1,0,0), // 1
        Vec3(1,1,0), // 2
        Vec3(0,1,0), // 3
        Vec3(2,0,0), // 4
        Vec3(2,1,0), // 5
    ];
    m.addFace([0u, 1u, 2u, 3u]);  // face 0: 4 corners at loops 0..3
    m.addFace([1u, 4u, 5u, 2u]);  // face 1: 4 corners at loops 4..7
    m.buildLoops();

    // Register a PolyVertex UV map (dim=2).
    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null, "failed to register UV map");

    // Assign distinct per-corner UV values so reversal is detectable.
    uvMap.data = [
        0.0f, 0.0f,   // loop 0: face0 corner 0
        1.0f, 0.0f,   // loop 1: face0 corner 1
        1.0f, 1.0f,   // loop 2: face0 corner 2
        0.0f, 1.0f,   // loop 3: face0 corner 3
        1.0f, 0.0f,   // loop 4: face1 corner 0
        2.0f, 0.0f,   // loop 5: face1 corner 1
        2.0f, 1.0f,   // loop 6: face1 corner 2
        1.0f, 1.0f,   // loop 7: face1 corner 3
    ];
    auto origData = uvMap.data.dup;

    // Flip face 0 only.
    auto mask = new bool[](m.faces.length);
    mask[0] = true;
    m.flipFacesByMask(mask);

    // After flip, face 0's new corner j must carry the UV that was at old
    // corner (N-1-j): new corner 0 ← old corner 3, etc.
    auto mapAfter = m.meshMap(kUvMapName);
    assert(mapAfter !is null, "UV map lost after flip");

    const uint base0 = m.faceLoop[0]; // = 0 (arity preserved, same CSR offsets)
    const uint n0    = cast(uint) m.faces[0].length; // = 4
    foreach (j; 0 .. n0) {
        const size_t newSlot = (base0 + j) * 2;
        const size_t oldSlot = (base0 + (n0 - 1 - j)) * 2;
        assert(mapAfter.data[newSlot]     == origData[oldSlot],
               "UV u at new corner " ~ j.to!string ~ " not relocated");
        assert(mapAfter.data[newSlot + 1] == origData[oldSlot + 1],
               "UV v at new corner " ~ j.to!string ~ " not relocated");
    }

    // Face 1 corners must be byte-identical (untouched face).
    const uint base1 = m.faceLoop[1]; // = 4
    const uint n1    = cast(uint) m.faces[1].length; // = 4
    foreach (j; 0 .. n1) {
        const size_t slot = (base1 + j) * 2;
        assert(mapAfter.data[slot]     == origData[slot],
               "face1 UV u changed unexpectedly at corner " ~ j.to!string);
        assert(mapAfter.data[slot + 1] == origData[slot + 1],
               "face1 UV v changed unexpectedly at corner " ~ j.to!string);
    }

    // Self-inverse for UVs: flipping face 0 again must restore every value.
    m.flipFacesByMask(mask);
    auto mapRestored = m.meshMap(kUvMapName);
    assert(mapRestored !is null, "UV map lost after second flip");
    assert(mapRestored.data == origData,
           "flip∘flip must restore all UV per-corner values exactly");

    // No-UV-map branch: kernel must not crash and must NOT call remapPolyVertexMaps.
    Mesh mNoUV = makeCube();
    assert(mNoUV.meshMap(kUvMapName) is null, "makeCube should register no UV map");
    auto noUVMask = new bool[](mNoUV.faces.length);
    noUVMask[0] = true;
    const nNoUV = mNoUV.flipFacesByMask(noUVMask);
    assert(nNoUV == 1, "no-UV mesh: should report 1 flipped");
    assert(mNoUV.meshMap(kUvMapName) is null, "no UV map should remain absent");
}

unittest { // triangulateFacesByMask: cube (6 quads) → 12 tris, same verts
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto mask = new bool[](m.faces.length);
    mask[] = true;
    size_t changed = m.triangulateFacesByMask(mask);
    assert(changed == 6, "triple: expected 6 changed faces, got " ~ changed.to!string);
    assert(m.faces.length == 12, "triple: expected 12 faces");
    assert(m.vertices.length == 8, "triple: expected 8 verts (no new verts)");
    assert(m.edges.length == 18,   "triple: expected 18 edges");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 3,
            "triple: face " ~ fi.to!string ~ " is not a triangle");
}

unittest { // triangulateFacesByMask: subpatch bit propagates to children
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    // Mark face 0 as subpatch before triangulating.
    m.resizeSubpatch();       // ensure faceMarks exists (was setFaceSubpatchFrom's job)
    m.setSubpatch(0, true);
    auto mask = new bool[](m.faces.length);
    mask[0] = true;  // only face 0
    m.triangulateFacesByMask(mask);
    // faces 0..n-1 are now 2 tris from old face 0; the rest are the 5 old quads.
    // The first two faces (children of old face 0) should be subpatch.
    assert(m.isFaceSubpatch(0), "child tri 0 should inherit parent subpatch bit");
    assert(m.isFaceSubpatch(1), "child tri 1 should inherit parent subpatch bit");
    // The old untouched faces start at index 2; none should be subpatch.
    foreach (fi; 2 .. m.faces.length)
        assert(!m.isFaceSubpatch(fi),
            "non-child face " ~ fi.to!string ~ " should not be subpatch");
}

unittest { // triangulateFacesByMask: faceOrigin maps children → parent
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto mask = new bool[](m.faces.length);
    mask[] = true;
    uint[] faceOrigin;
    m.triangulateFacesByMask(mask, &faceOrigin);
    assert(faceOrigin.length == 12,
        "faceOrigin length should match new face count");
    // Each original face produced 2 children; children 0,1 → parent 0,
    // children 2,3 → parent 1, etc. (fan always produces 2 tris from a quad).
    foreach (fi; 0 .. 12)
        assert(faceOrigin[fi] == fi / 2,
            "faceOrigin[" ~ fi.to!string ~ "] = " ~ faceOrigin[fi].to!string
            ~ ", expected " ~ (fi / 2).to!string);
}

unittest { // triangulateFacesByMask: SOUNDNESS + ring-order invariance over
           // adversarial rings, every rotation — task 1190.
    //
    // A geometric fan anchor makes the orbit invariant but says nothing about
    // whether the triangles are any good, and the reverse is also true. This
    // asserts both, on the ring families that separate them, at EVERY rotation
    // of each:
    //
    //   1. exactly n-2 triangles;
    //   2. every triangle wound the same way as the ring and non-degenerate
    //      (signed area strictly positive against the ring's own normal) — so
    //      no inverted and no zero-area triangle;
    //   3. the triangle areas SUM to the ring's area. This is the one that
    //      catches an overlap or a gap: a triangle that strays outside the
    //      polygon, or two that cover the same ground, break the sum while
    //      leaving the count and the winding intact;
    //   4. rotating the ring gives the SAME set of triangles.
    //
    // Measured against the old fan from `ring[0]` on a 306-cell corpus of the
    // same four families: 126 cells failed (3), 259 triangles fell outside the
    // ring, 330 were zero-area, and all 36 orbits were ring-order dependent.
    // The families are chosen for that reason — a convex ring cannot fail any
    // of these and would make the test vacuous.
    import std.conv : to;
    import std.math : fabs, cos, sin, PI;

    static double ringArea2(const Vec3[] r) {
        double s = 0;
        foreach (i; 0 .. r.length) {
            const a = r[i], b = r[(i + 1) % r.length];
            s += cast(double)a.x * b.z - cast(double)b.x * a.z;
        }
        return s;
    }
    static double tri2(Vec3 a, Vec3 b, Vec3 c) {
        return (cast(double)b.x - a.x) * (cast(double)c.z - a.z)
             - (cast(double)c.x - a.x) * (cast(double)b.z - a.z);
    }
    // A triangle named by its three positions, order-free, so two rotations
    // can be compared without assuming anything about vertex numbering.
    static string triKeyOf(Vec3 a, Vec3 b, Vec3 c) {
        string[3] k = [format("%.4f,%.4f", a.x, a.z),
                       format("%.4f,%.4f", b.x, b.z),
                       format("%.4f,%.4f", c.x, c.z)];
        foreach (i; 0 .. 3) foreach (j; i + 1 .. 3)
            if (k[j] < k[i]) { auto t = k[i]; k[i] = k[j]; k[j] = t; }
        return k[0] ~ "|" ~ k[1] ~ "|" ~ k[2];
    }

    Vec3[][] corpus;
    string[] names;
    // eight-pointed star: four reflex corners, four congruent tips (an exact
    // tie the area metric cannot break)
    {
        Vec3[] r;
        foreach (i; 0 .. 8) {
            immutable double a = 2.0 * PI * i / 8.0;
            immutable double rad = (i % 2 == 0) ? 1.0 : 0.35;
            r ~= Vec3(cast(float)(cos(a) * rad), 0, cast(float)(sin(a) * rad));
        }
        corpus ~= r; names ~= "star8";
    }
    // a square with three EXTRA collinear points on one edge — the family the
    // old fan turned into zero-area triangles
    {
        Vec3[] r = [Vec3(0,0,0), Vec3(0.75f,0,0), Vec3(1.5f,0,0), Vec3(2.25f,0,0),
                    Vec3(3,0,0), Vec3(3,0,3), Vec3(0,0,3)];
        corpus ~= r; names ~= "collinear_run";
    }
    // deep notches: thin ears and many reflex corners
    {
        Vec3[] r;
        foreach (i; 0 .. 4) {
            r ~= Vec3(cast(float)i, 0, 0);
            r ~= Vec3(cast(float)i + 0.5f, 0, 1.6f);
        }
        r ~= Vec3(4, 0, 0); r ~= Vec3(4, 0, -1); r ~= Vec3(0, 0, -1);
        corpus ~= r; names ~= "comb";
    }
    // the dart — the smallest ring the old fan got wrong
    {
        corpus ~= [Vec3(0,0,0), Vec3(2,0,1.2f), Vec3(4,0,0), Vec3(2,0,3)];
        names ~= "dart";
    }
    // one reflex AND one exactly-collinear corner on the same ring
    {
        corpus ~= [Vec3(0,0,0), Vec3(2,0,0), Vec3(4,0,0),
                   Vec3(4,0,4), Vec3(2,0,1.4f), Vec3(0,0,4)];
        names ~= "reflex_and_flat_hex";
    }

    foreach (ci, base; corpus) {
        immutable size_t n = base.length;
        immutable double want = fabs(ringArea2(base));
        immutable double tol  = 1e-4 * (want > 1.0 ? want : 1.0);
        string[] firstKeys;
        foreach (rot; 0 .. n) {
            Vec3[] r;
            foreach (k; 0 .. n) r ~= base[(rot + k) % n];
            immutable double sgn = ringArea2(r) > 0 ? 1.0 : -1.0;

            Mesh m;
            m.vertices = r.dup;
            uint[] ring;
            foreach (k; 0 .. n) ring ~= cast(uint)k;
            m.addFace(ring);
            m.buildLoops();
            m.resetSelection();
            auto mask = new bool[](m.faces.length);
            mask[] = true;
            m.triangulateFacesByMask(mask);

            immutable string who = names[ci] ~ " rot" ~ rot.to!string;
            assert(m.faces.length == n - 2,
                who ~ ": expected " ~ (n - 2).to!string ~ " triangles, got "
                ~ m.faces.length.to!string);

            double sum = 0;
            string[] keys;
            foreach (fi; 0 .. m.faces.length) {
                assert(m.faces[fi].length == 3, who ~ ": face " ~ fi.to!string
                    ~ " is not a triangle");
                const a = m.vertices[m.faces[fi][0]];
                const b = m.vertices[m.faces[fi][1]];
                const c = m.vertices[m.faces[fi][2]];
                immutable double s = tri2(a, b, c) * sgn;
                assert(s > tol * 1e-3,
                    who ~ ": triangle " ~ fi.to!string ~ " has signed area "
                    ~ s.to!string ~ " against the ring's own winding — it is "
                    ~ "inverted or degenerate, which is what a fan from a fixed "
                    ~ "ring index produced on this shape");
                sum += s;
                keys ~= triKeyOf(a, b, c);
            }
            assert(fabs(sum - want) <= tol,
                who ~ ": the triangles cover " ~ sum.to!string
                ~ " but the ring encloses " ~ want.to!string
                ~ " — they overlap or leave a gap");

            foreach (i; 0 .. keys.length)
                foreach (j; i + 1 .. keys.length)
                    if (keys[j] < keys[i]) { auto t = keys[i]; keys[i] = keys[j]; keys[j] = t; }
            if (rot == 0) firstKeys = keys;
            else assert(keys == firstKeys,
                who ~ ": rotating the ring changed the triangle SET — "
                ~ "triangulation must not depend on where the ring starts "
                ~ "(rot0 gave " ~ firstKeys.to!string ~ ", this gave "
                ~ keys.to!string ~ ")");
        }
    }
}

unittest { // triangulateFacesByMask: a per-CORNER map value must travel with
           // the corner the ear clip actually named — task 1190.
    //
    // The kernel used to hardcode the fan's mapping (old corners 0, i, i+1).
    // Now the diagonals are chosen geometrically, so a triangle's corners can
    // be any three ring positions, and `declareCornerProvenance` has to be
    // told the REAL ones. Get this wrong and UVs land on foreign corners in
    // silence — the geometry is identical either way, which is exactly why
    // this needs its own check.
    //
    // The ring is the reflex pentagon from ledger row 25, chosen because the
    // clip does NOT fan from corner 0 on it (it fans from the reflex corner,
    // ring index 3). On a convex quad the two mappings would coincide and this
    // test would prove nothing.
    import std.conv : to;
    import mesh : kUvMapName, MapDomain;

    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),   // 0
        Vec3(4, 0, 0),   // 1
        Vec3(4, 0, 4),   // 2
        Vec3(2, 0, 1),   // 3  — the reflex corner
        Vec3(0, 0, 4),   // 4
    ];
    m.addFace([0u, 1u, 2u, 3u, 4u]);
    m.buildLoops();
    m.resetSelection();

    auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uv !is null, "failed to register the UV map");
    assert(uv.data.length == 10, "UV map must be sized to 5 corners * dim 2");
    // One unmistakable value per corner: u = vertex id, v = 100 + vertex id.
    foreach (c; 0 .. 5) {
        uv.data[2*c]     = cast(float)c;
        uv.data[2*c + 1] = 100.0f + cast(float)c;
    }

    auto mask = new bool[](m.faces.length);
    mask[] = true;
    const changed = m.triangulateFacesByMask(mask);
    assert(changed == 1, "expected 1 triangulated face, got " ~ changed.to!string);
    assert(m.faces.length == 3, "a pentagon must give 3 triangles, got "
        ~ m.faces.length.to!string);

    auto after = m.meshMap(kUvMapName);
    assert(after !is null, "UV map lost by triangulation");
    assert(after.data.length == m.loops.length * 2,
        "UV map length " ~ after.data.length.to!string ~ " != loops "
        ~ m.loops.length.to!string ~ " * 2");

    // No vertex is created or moved here, and every vertex appears in exactly
    // one corner of the source pentagon — so the authored value for a corner
    // is recoverable from its vertex id, and a corner that ended up with a
    // DIFFERENT vertex's value is a mis-mapped corner, not a lost one.
    size_t slot = 0;
    foreach (fi; 0 .. m.faces.length) {
        foreach (c; 0 .. m.faces[fi].length) {
            immutable uint v = m.faces[fi][c];
            assert(after.data[2*slot] == cast(float)v
                && after.data[2*slot + 1] == 100.0f + cast(float)v,
                "face " ~ fi.to!string ~ " corner " ~ c.to!string
                ~ " (vertex " ~ v.to!string ~ ") carries UV ("
                ~ after.data[2*slot].to!string ~ ", "
                ~ after.data[2*slot + 1].to!string
                ~ ") — it belongs to vertex "
                ~ (cast(uint)after.data[2*slot]).to!string
                ~ ". The corner provenance declared by triangulateFacesByMask "
                ~ "does not name the corners the ear clip actually used.");
            ++slot;
        }
    }
}

unittest { // quadrupleFacesByMask: triple → quadruple round-trips a cube
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    m.triangulateFacesByMask(allF);
    assert(m.faces.length == 12);
    auto allF2 = new bool[](m.faces.length);
    allF2[] = true;
    size_t dissolved = m.quadrupleFacesByMask(allF2);
    assert(dissolved == 6,
        "quadruple: expected 6 edges dissolved (one diagonal per cube face), got "
        ~ dissolved.to!string);
    assert(m.faces.length == 6,  "quadruple: expected 6 faces");
    assert(m.vertices.length == 8, "quadruple: expected 8 verts");
    assert(m.edges.length == 12,   "quadruple: expected 12 edges");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 4,
            "quadruple: face " ~ fi.to!string ~ " is not a quad");
}

unittest { // quadrupleFacesByMask: planarity — every result quad is flat
    import std.conv : to;
    import math : dot;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    m.triangulateFacesByMask(allF);
    auto allF2 = new bool[](m.faces.length);
    allF2[] = true;
    m.quadrupleFacesByMask(allF2);
    foreach (fi; 0 .. m.faces.length) {
        assert(m.faces[fi].length == 4);
        // Split quad [a,b,c,d] into tris (a,b,c) and (a,c,d).
        auto f  = m.faces[fi];
        Vec3 pa = m.vertices[f[0]], pb = m.vertices[f[1]],
             pc = m.vertices[f[2]], pd = m.vertices[f[3]];
        import math : cross, normalize;
        import std.math : sqrt;
        Vec3 n1 = normalize(cross(pb - pa, pc - pa));
        Vec3 n2 = normalize(cross(pc - pa, pd - pa));
        float d = dot(n1, n2);
        assert(d > 0.999f,
            "quadruple planarity: face " ~ fi.to!string
            ~ " bent-quad dot=" ~ d.to!string);
    }
}

unittest { // detriangulateFacesByMask: triple → detriangulate round-trips a cube
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    m.triangulateFacesByMask(allF);
    assert(m.faces.length == 12);
    auto allF2 = new bool[](m.faces.length);
    allF2[] = true;
    size_t dissolved = m.detriangulateFacesByMask(allF2);
    assert(dissolved == 6,
        "detriangulate: expected 6 edges dissolved, got " ~ dissolved.to!string);
    assert(m.faces.length == 6,   "detriangulate: expected 6 faces");
    assert(m.vertices.length == 8,"detriangulate: expected 8 verts");
    assert(m.edges.length == 12,  "detriangulate: expected 12 edges");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 4,
            "detriangulate: face " ~ fi.to!string ~ " not a quad");
}

unittest { // detriangulateFacesByMask: partial mask — only masked faces merge
    // Mask only 2 tris (children of cube face 0) → 1 merge; other tris untouched.
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    uint[] faceOrigin;
    m.triangulateFacesByMask(allF, &faceOrigin);  // 12 tris
    // Find the 2 children of original face 0.
    bool[] partMask = new bool[](m.faces.length);
    foreach (fi; 0 .. faceOrigin.length)
        if (faceOrigin[fi] == 0) partMask[fi] = true;
    m.detriangulateFacesByMask(partMask);
    // 1 merge: 12 - 2 + 1 = 11 faces.
    assert(m.faces.length == 11,
        "detriangulate partial: expected 11 faces, got " ~ m.faces.length.to!string);
}

unittest { // insetFacesByMask: single flat quad — inset=0 still splits (task 0359
           // reference parity) + constant-centroid-distance corner law
    import std.math : abs, sqrt;
    import std.conv : to;
    // 1×1 quad at y=0, corners (±0.5, 0, ±0.5), winding [0,1,2,3], centroid
    // (0,0,0). Every corner is equidistant from the centroid (a square), so
    // moving "toward the centroid by an absolute distance of `inset`" lands
    // each corner at distance inset/sqrt(2) closer along BOTH its x and z
    // components (the diagonal toward the centroid).
    Mesh m;
    m.vertices = [
        Vec3(-0.5f, 0f, -0.5f), // 0
        Vec3( 0.5f, 0f, -0.5f), // 1
        Vec3( 0.5f, 0f,  0.5f), // 2
        Vec3(-0.5f, 0f,  0.5f), // 3
    ];
    m.addFace([0, 1, 2, 3]);
    m.buildLoops();

    // inset=0 is NOT a no-op (reference-matched, task 0359 toolcard
    // `behavior.default_value_is_not_skipped`): the split still happens,
    // landing the 4 new corners exactly on the 4 original ones (a
    // degenerate zero-width ring — same topology delta as any other inset).
    bool[] allOne = [true];
    assert(m.insetFacesByMask(allOne, 0.0f) == 1, "inset=0 must still process 1 face");
    assert(m.vertices.length == 8, "expected 8 verts after inset=0 split");
    assert(m.faces.length    == 5, "expected 5 faces (1 inner + 4 ring quads) after inset=0 split");
    bool hasVertExact(float x, float z) {
        foreach (v; m.vertices)
            if (abs(v.x - x) < 1e-5f && abs(v.z - z) < 1e-5f) return true;
        return false;
    }
    // Degenerate ring: the 4 new corners are bit-coincident with the 4
    // originals (2 verts at each of the 4 corner positions).
    foreach (x; [-0.5f, 0.5f])
        foreach (z; [-0.5f, 0.5f])
            assert(hasVertExact(x, z), "inset=0: degenerate corner missing at ("
                ~ x.to!string ~ ",0," ~ z.to!string ~ ")");

    // Fresh mesh for the inset=0.1 case (the inset=0 split above already
    // mutated `m`'s topology).
    Mesh m2;
    m2.vertices = m.vertices[0 .. 4].dup;
    m2.addFace([0, 1, 2, 3]);
    m2.buildLoops();

    // inset=0.1: 4 new verts, 4 ring quads + 1 inner face = 5 faces total.
    assert(m2.insetFacesByMask(allOne, 0.1f) == 1, "inset=0.1 must process 1 face");
    assert(m2.vertices.length == 8, "expected 8 verts after single-face inset");
    assert(m2.faces.length    == 5, "expected 5 faces (1 inner + 4 ring quads)");

    // Inner corners must be at (±(0.5 - 0.1/sqrt(2)), 0, ±(0.5 - 0.1/sqrt(2)))
    // — constant-absolute-distance-toward-centroid (task 0359), NOT the old
    // per-edge-miter ±0.4 law (which moved 0.1 along EACH axis independently,
    // i.e. inset*sqrt(2) total displacement — ruled out by the reference
    // capture, see toolcard `behavior.per_vertex_law`).
    immutable float d = 0.1f / sqrt(2.0f);
    bool hasVert(float x, float z) {
        foreach (v; m2.vertices)
            if (abs(v.x - x) < 1e-4f && abs(v.z - z) < 1e-4f) return true;
        return false;
    }
    assert(hasVert(-(0.5f - d), -(0.5f - d)), "inner corner missing (-,-)");
    assert(hasVert( (0.5f - d), -(0.5f - d)), "inner corner missing (+,-)");
    assert(hasVert( (0.5f - d),  (0.5f - d)), "inner corner missing (+,+)");
    assert(hasVert(-(0.5f - d),  (0.5f - d)), "inner corner missing (-,+)");
}

unittest { // bevelFacesByMask: cube top face, inset=0.1 shift=0.2
    import std.math : abs, sqrt;
    // Cube top face is index 4: [3,7,6,2], normal +Y.
    // Verts: 3=(-0.5,0.5,-0.5) 7=(-0.5,0.5,0.5) 6=(0.5,0.5,0.5) 2=(0.5,0.5,-0.5)
    // inset=0.1, shift=0.2 → cap corners at (±0.4, 0.7, ±0.4), ring connects to
    // original corners at y=0.5.  Total: 8+4=12 verts, 6−1+1+4=10 faces.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;

    // Parity (fuzz D6): inset==0 && shift==0 is NOT a no-op — the reference
    // still builds a ZERO-WIDTH bevel ring (the inset cap coincides with the
    // original boundary). 8 orig + 4 coincident cap verts = 12; 6-1+1+4 = 10
    // all-quad faces. An EMPTY mask remains a genuine no-op.
    {
        auto mz = makeCube();
        bool[] mzmask; mzmask.length = mz.faces.length; mzmask[] = false; mzmask[4] = true;
        assert(mz.bevelFacesByMask(mzmask, 0.0f, 0.0f) == 1,
            "inset=0, shift=0 must build a zero-width ring (fuzz D6 parity)");
        assert(mz.vertices.length == 12, "zero-width ring: expected 12 verts");
        assert(mz.faces.length    == 10, "zero-width ring: expected 10 faces");
        int[int] fvd;
        foreach (f; mz.faces) fvd[cast(int)f.length]++;
        assert(fvd.get(4, 0) == 10, "zero-width ring: all faces must stay quads");

        auto me = makeCube();
        bool[] emptyMask; emptyMask.length = me.faces.length; emptyMask[] = false;
        assert(me.bevelFacesByMask(emptyMask, 0.0f, 0.0f) == 0,
            "empty mask must remain a no-op even at inset=0/shift=0");
        assert(me.vertices.length == 8);
        assert(me.faces.length    == 6);
    }

    // inset=0.1, shift=0.2 (m is still a pristine cube — the D6 block used
    // its own fresh meshes).
    assert(m.bevelFacesByMask(mask, 0.1f, 0.2f) == 1, "should process 1 face");
    assert(m.vertices.length == 12, "expected 12 verts");
    assert(m.faces.length    == 10, "expected 10 faces");

    bool hasV(float x, float y, float z) {
        foreach (v; m.vertices)
            if (abs(v.x-x)<1e-4f && abs(v.y-y)<1e-4f && abs(v.z-z)<1e-4f) return true;
        return false;
    }
    // inner cap corners at y=0.7 (shifted by 0.2 from y=0.5)
    assert(hasV(-0.4f, 0.7f, -0.4f), "inner corner (-0.4,0.7,-0.4) missing");
    assert(hasV( 0.4f, 0.7f, -0.4f), "inner corner ( 0.4,0.7,-0.4) missing");
    assert(hasV( 0.4f, 0.7f,  0.4f), "inner corner ( 0.4,0.7, 0.4) missing");
    assert(hasV(-0.4f, 0.7f,  0.4f), "inner corner (-0.4,0.7, 0.4) missing");

    // shift-only: inset=0, shift=0.2 → cap corners at (±0.5, 0.7, ±0.5)
    auto m2 = makeCube();
    bool[] mask2; mask2.length = m2.faces.length; mask2[] = false; mask2[4] = true;
    assert(m2.bevelFacesByMask(mask2, 0.0f, 0.2f) == 1, "shift-only: should process 1 face");
    assert(m2.vertices.length == 12);
    assert(m2.faces.length    == 10);
    bool hasV2(float x, float y, float z) {
        foreach (v; m2.vertices)
            if (abs(v.x-x)<1e-4f && abs(v.y-y)<1e-4f && abs(v.z-z)<1e-4f) return true;
        return false;
    }
    assert(hasV2(-0.5f, 0.7f, -0.5f), "shift-only inner corner (-0.5,0.7,-0.5) missing");
    assert(hasV2( 0.5f, 0.7f, -0.5f), "shift-only inner corner ( 0.5,0.7,-0.5) missing");
    assert(hasV2( 0.5f, 0.7f,  0.5f), "shift-only inner corner ( 0.5,0.7, 0.5) missing");
    assert(hasV2(-0.5f, 0.7f,  0.5f), "shift-only inner corner (-0.5,0.7, 0.5) missing");
}

unittest { // bevelFacesByMask: exact-collapse ring (fuzz D3 parity) — an
           // inset at/beyond a face's inradius clamps to the collapse point.
           // The reference KEEPS that as a DEGENERATE QUAD RING (coincident
           // cap corners, zero-area cap + ring quads all stay 4-vertex), NOT
           // a welded + fan-triangulated cap. This is the corrected behaviour
           // of the former task-0304 overshoot guard, which welded the
           // collapse away (a `vibe3d-divergence`).
    import std.conv : to;

    // The top face (index 4 = [3,7,6,2]) is a unit square at y=0.5, normal
    // +Y, centroid (0,0.5,0). At/over inradius the four cap corners all land
    // on the shifted centroid → 12 verts (8 orig + 4 coincident cap), 10
    // all-quad faces (5 cube + 1 cap + 4 ring), with exactly 4 verts stacked
    // at the collapse point.
    void assertCollapseRing(ref Mesh m, string tag, float shift) {
        assert(m.vertices.length == 12,
            tag ~ ": expected 12 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length == 10,
            tag ~ ": expected 10 faces, got " ~ m.faces.length.to!string);
        int quads = 0, tris = 0;
        foreach (f; m.faces) {
            if      (f.length == 4) ++quads;
            else if (f.length == 3) ++tris;
        }
        assert(quads == 10 && tris == 0,
            tag ~ ": expected 10 quads / 0 tris (degenerate quad ring, not a "
            ~ "fan), got " ~ quads.to!string ~ " quads / " ~ tris.to!string ~ " tris");
        immutable Vec3 collapse = Vec3(0, 0.5f + shift, 0);
        int atCollapse = 0;
        foreach (v; m.vertices)
            if ((v - collapse).length < 1e-5f) ++atCollapse;
        assert(atCollapse == 4,
            tag ~ ": expected 4 coincident cap corners at the collapse point, got "
            ~ atCollapse.to!string);
    }

    // inset==inradius (0.5 on a unit face) — the primary D3 repro.
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
        size_t n = m.bevelFacesByMask(mask, 0.5f, 0.0f);
        assert(n == 1, "inset==inradius should still process (clamped)");
        assertCollapseRing(m, "inset==inradius", 0.0f);
    }

    // inset==2x inradius clamps to the SAME collapse point → same ring.
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
        size_t n = m.bevelFacesByMask(mask, 1.0f, 0.0f);
        assert(n == 1, "inset==2x inradius should still process (clamped)");
        assertCollapseRing(m, "inset==2x inradius", 0.0f);
    }

    // Sanity: a normal small inset does NOT reach the collapse path — 12v/10f
    // with all four cap corners still DISTINCT (none stacked on the centroid).
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
        assert(m.bevelFacesByMask(mask, 0.1f, 0.0f) == 1);
        assert(m.vertices.length == 12, "normal inset must be unaffected by the collapse path");
        assert(m.faces.length    == 10);
        int atCentroid = 0;
        foreach (v; m.vertices)
            if ((v - Vec3(0, 0.5f, 0)).length < 1e-5f) ++atCentroid;
        assert(atCentroid == 0, "normal inset must not collapse any cap corner onto the centroid");
    }
}

unittest { // bevelFacesByMask: group=true shared-corner accumulator manifold
           // cleanliness backstop (task 0391 Phase 4) — the 3-face
           // cube-corner grouped case (topology-diff-golden-verified via
           // test_fixture_poly_bevel_corner.d; this adds the winding/
           // manifold check the fixture harness cannot see, plus an exact
           // apex-position law check).
    import std.conv : to;

    void assertClean(ref Mesh m, string tag) {
        foreach (i; 0 .. m.vertices.length)
            foreach (j; i + 1 .. m.vertices.length)
                assert((m.vertices[i] - m.vertices[j]).length > 1e-6f,
                    tag ~ ": coincident verts " ~ i.to!string ~ "," ~ j.to!string);
        int[ulong] edgeUse;
        static ulong ekey(uint a, uint b) {
            return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
        }
        foreach (f; m.faces) {
            bool[uint] distinct;
            foreach (v; f) distinct[v] = true;
            assert(distinct.length >= 3, tag ~ ": degenerate face");
            foreach (k; 0 .. f.length) edgeUse[ekey(f[k], f[(k + 1) % f.length])]++;
        }
        foreach (key, count; edgeUse)
            assert(count == 2, tag ~ ": non-manifold edge (used by " ~
                count.to!string ~ " faces, expected 2)");
    }

    // +X, +Y, +Z faces of makeCube() all share corner 6=(0.5,0.5,0.5).
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[3] = true; // +X = [1,2,6,5]
    mask[4] = true; // +Y = [3,7,6,2]
    mask[1] = true; // +Z = [4,5,6,7]
    size_t n = m.bevelFacesByMask(mask, 0.15f, 0.1f, true, 0);
    assert(n == 3, "should process all 3 grouped faces");
    assert(m.vertices.length == 14, "expected 14 verts (8-1 orphaned apex-source+7 new)");
    assert(m.faces.length    == 12, "expected 12 faces");
    int[int] fvd;
    foreach (f; m.faces) fvd[cast(int)f.length]++;
    assert(fvd.get(4, 0) == 12, "grouped cap should be ALL quads (no triangle/pentagon)");
    assertClean(m, "grouped poly-bevel corner");

    // Exact apex-position law: orig corner + shift along EACH of the 3
    // group faces' own normals (NOT the averaged/normalized diagonal) —
    // capture-verified (0.5,0.5,0.5) + (0.1,0.1,0.1) = (0.6,0.6,0.6).
    bool foundApex = false;
    foreach (v; m.vertices)
        if ((v - Vec3(0.6f, 0.6f, 0.6f)).length < 1e-4f) foundApex = true;
    assert(foundApex, "grouped shared apex should sit at orig + per-face shift sum (0.6,0.6,0.6)");
}

unittest { // bevelFacesByMask: GROUP x SEGMENTS — task 0458 Phase 1 (+S1),
           // finding S1. mesh.d's own doc comment marked this combination
           // "KNOWN-UNTESTED" before this task. Orthogonal 2-face cube
           // selection (AVE_N coincides with the naive sum here — see the
           // asymmetric G1 unittest above for the discriminator) isolates
           // the segments x group interaction: the shared ridge corner
           // must be segmented the same equal-lerp way as every other
           // boundary vertex, AND its intermediate (non-final) ring vertex
           // must be shared across both faces (not duplicated per face —
           // the pre-0458 kernel created 22 verts here; the reference/
           // fixed kernel produces 20, matching poly_bevel_S1_group_segs2).
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    mask[1] = true; // +Z = [4,5,6,7]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, true, 2);
    assert(n == 2);
    assert(m.vertices.length == 20, "expected 20 verts (8 orig + 6 intermediate-ring + 6 final-ring, shared corner not duplicated)");
    assert(m.faces.length    == 18);
    bool foundMidShared = false;
    foreach (v; m.vertices)
        if ((v - Vec3(0.375f, 0.575f, 0.575f)).length < 1e-4f) foundMidShared = true;
    assert(foundMidShared, "the group-shared corner's t=1-of-2 intermediate ring vertex should land at exactly half inset/half shift (0.375,0.575,0.575)");
}

unittest { // bevelFacesByMask: SQUARE CORNER, finding Q1 (single-face, no
           // group) — task 0458 Phase 3. See `poly_bevel_Q1_single_square`
           // (toolcards/poly.bevel/findings.md §3): one cube top face,
           // inset=0.25, shift=0.15, square=true → 20v/14f. Every corner is
           // STANDALONE (no group): 8 orig (retained) + 4 final inset/shift
           // corners + 8 split points (2 per original top-face edge, at
           // distance=inset from each endpoint) = 20. 1 bottom quad + 4
           // side hexagons (absorb the 2 splits on their shared edge) + 1
           // inner quad + 4 edge-panel quads + 4 corner-cap quads = 14.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, false, 0, true);
    assert(n == 1);
    assert(m.vertices.length == 20, "8 orig + 4 final corners + 8 split points");
    assert(m.faces.length    == 14, "1 bottom + 4 side hexagons + 1 inner + 4 panels + 4 caps");

    // Original top-face corners MUST be retained (square keeps them, unlike
    // the non-square kernel which replaces them outright).
    foreach (orig; [Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,0.5f,0.5f),
                    Vec3(0.5f,0.5f,0.5f),   Vec3(0.5f,0.5f,-0.5f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - orig).length < 1e-5f) found = true;
        assert(found, "original top-face corner should be retained by square");
    }
    // The 4 final inset+shift corners (same law as the non-square kernel,
    // just now a SEPARATE vertex from the retained original corner).
    foreach (fc; [Vec3(-0.25f,0.65f,-0.25f), Vec3(-0.25f,0.65f,0.25f),
                  Vec3(0.25f,0.65f,0.25f),   Vec3(0.25f,0.65f,-0.25f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - fc).length < 1e-4f) found = true;
        assert(found, "expected final inset+shift corner missing");
    }
    // Split points: distance=inset (0.25) from each original corner along
    // the ORIGINAL (un-shifted) top-face edges.
    foreach (sp; [Vec3(-0.25f,0.5f,-0.5f), Vec3(-0.5f,0.5f,-0.25f),
                  Vec3(-0.5f,0.5f,0.25f),  Vec3(-0.25f,0.5f,0.5f),
                  Vec3(0.25f,0.5f,0.5f),   Vec3(0.5f,0.5f,0.25f),
                  Vec3(0.5f,0.5f,-0.25f),  Vec3(0.25f,0.5f,-0.5f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - sp).length < 1e-4f) found = true;
        assert(found, "expected split point missing");
    }
}

unittest { // bevelFacesByMask: SQUARE CORNER, finding Q2 (two NON-adjacent
           // faces) — task 0458 Phase 3. `poly_bevel_Q2_nonadjacent_square`
           // (findings.md §3): cube top (+Y) AND bottom (-Y), group=true
           // (inert — no shared edge, so square is pure per-face), inset=
           // 0.25, shift=0.15 → 32v/22f: two INDEPENDENT Q1 patterns, and
           // the 4 side faces (each bordering BOTH squares) become
           // OCTAGONS (absorb 2 splits from top + 2 from bottom).
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    mask[5] = true; // -Y = [0,1,5,4]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, true, 0, true);
    assert(n == 2);
    assert(m.vertices.length == 32, "8 orig + 2x(4 final + 8 splits) = 32");
    assert(m.faces.length    == 22, "2 inner + 2x(4 panels+4 caps) + 4 octagon sides = 22");

    size_t octagons = 0, quads = 0;
    foreach (f; m.faces) {
        if (f.length == 8) ++octagons;
        else if (f.length == 4) ++quads;
    }
    assert(octagons == 4, "the 4 side faces should each become an octagon");
    // 2 inner (final) quads + 2x4 panel quads + 2x4 cap quads = 18 quads.
    assert(quads == 18, "expected 18 remaining quads (2 inner + 8 panels + 8 caps)");
}

unittest { // bevelFacesByMask: SQUARE CORNER, finding Q3 (square + segments
           // together) — task 0458 Phase 3. `poly_bevel_Q3_square_segs2`
           // (findings.md §3): one cube top face, inset=0.25, shift=0.15,
           // segments=2, square=true → 24v/18f. Square treatment applies
           // ONLY at the outermost ring (original boundary → ring[1]),
           // split distance = inset/segs = 0.125; the remaining ring
           // (ring[1] → ring[2]=final) interpolates via plain (unsquared)
           // quads, unchanged from the ordinary segments path.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, false, 2, true);
    assert(n == 1);
    assert(m.vertices.length == 24, "8 orig + 4 ring1(half-step) + 4 final(full-step) + 8 splits(at inset/segs=0.125)");
    assert(m.faces.length    == 18, "1 bottom + 4 side hexagons + 1 final-inner + 4 square-panels + 4 square-caps + 4 plain ring1->final panels");

    // Splits at HALF the full inset (0.125, the outermost ring's own step),
    // NOT the full 0.25 — the Q3-specific finding.
    foreach (sp; [Vec3(-0.375f,0.5f,-0.5f), Vec3(-0.5f,0.5f,-0.375f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - sp).length < 1e-4f) found = true;
        assert(found, "expected split point at inset/segs=0.125, not the full inset");
    }
    // ring1 (half-step) corner and the true final corner both present.
    bool foundRing1 = false, foundFinal = false;
    foreach (v; m.vertices) {
        if ((v - Vec3(-0.375f,0.575f,-0.375f)).length < 1e-4f) foundRing1 = true;
        if ((v - Vec3(-0.25f,0.65f,-0.25f)).length   < 1e-4f) foundFinal = true;
    }
    assert(foundRing1, "expected ring1 (half-step) corner");
    assert(foundFinal, "expected the true final (full-step) corner");
}

unittest { // bevelFacesByMask: SQUARE CORNER, finding Q4 (grouped, 2
           // adjacent faces) — task 0458 Phase 3. `poly_bevel_two_faces_
           // grouped_square1` (findings.md §3): the SAME 2-face selection
           // as the GROUPxSEGMENTS unittest above (+Y, +Z sharing one
           // ridge edge), inset=0.25, shift=0.15, group=true, square=true,
           // segments=0 → 22v/16f (a full topology rewrite, re-verified
           // bit-exact against the reference dump). The two RIDGE corners
           // (the shared edge's endpoints) get NEITHER split NOR cap —
           // they stay at their ORIGINAL position, connected directly into
           // the two edge-panels meeting there.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    mask[1] = true; // +Z = [4,5,6,7]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, true, 0, true);
    assert(n == 2);
    assert(m.vertices.length == 22, "8 orig + 6 final ring corners (4 standalone + 2 shared ridge) + 8 splits (4 standalone corners x 2, ridge corners get none)");
    assert(m.faces.length    == 16, "4 unselected hexagons + 2 inner quads + 6 panels (one per boundary-contour edge) + 4 caps (standalone corners only)");

    // The ridge (shared) corner — the top-front edge's own two endpoints,
    // (-0.5,0.5,0.5) and (0.5,0.5,0.5) — must be RETAINED at their exact
    // original position (no split, no cap moves them).
    foreach (orig; [Vec3(-0.5f,0.5f,0.5f), Vec3(0.5f,0.5f,0.5f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - orig).length < 1e-5f) found = true;
        assert(found, "ridge corner should be retained at its original position");
    }
    // The ridge corners' shared FINAL positions (bit-exact against the
    // non-square group law, poly_bevel_two_faces_grouped.json's own ridge
    // verts — same formula, square just wraps it).
    foreach (fc; [Vec3(0.25f,0.65f,0.65f), Vec3(-0.25f,0.65f,0.65f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - fc).length < 1e-4f) found = true;
        assert(found, "expected ridge corner's shared final (group-solved) position");
    }
    size_t hexagons = 0;
    foreach (f; m.faces) if (f.length == 6) ++hexagons;
    assert(hexagons == 4, "the 4 unselected side/bottom faces bordering the group's boundary contour should become hexagons");
}

unittest { // bevelFacesByMask: square=false is byte-identical to the
           // pre-Phase-3 kernel — task 0458 Phase 3 regression guard. Same
           // selection/params as the Q1 unittest above, just without the
           // trailing `square` arg (defaults false) vs. explicitly false.
    auto m0 = makeCube();
    auto m1 = makeCube();
    bool[] mask; mask.length = m0.faces.length; mask[] = false;
    mask[4] = true;
    size_t n0 = m0.bevelFacesByMask(mask, 0.25f, 0.15f); // pre-0458-Phase-3 call site (5 args)
    size_t n1 = m1.bevelFacesByMask(mask, 0.25f, 0.15f, false, 0, false); // explicit square=false
    assert(n0 == 1 && n1 == 1);
    assert(m0.vertices.length == m1.vertices.length);
    assert(m0.faces.length    == m1.faces.length);
    assert(m0.vertices.length == 12, "square=false: 8 orig + 4 final — no split points, no retained-original-plus-final duplication");
    foreach (i; 0 .. m0.vertices.length)
        assert((m0.vertices[i] - m1.vertices[i]).length < 1e-9f, "square=false must be byte-identical regardless of how it's spelled");
}

unittest { // bevelFacesByMask: 0458 Phase-3 hardening — square with a ZERO
           // effective inset (inset=0, shift>0, square=true — reachable via the
           // square UI toggle) must NOT produce degenerate zero-area caps or
           // duplicate verts. The `doSquare = square && effInset>eps` gate makes
           // it fall back to the plain (square=false) shift bevel.
    auto m0 = makeCube();
    auto m1 = makeCube();
    bool[] mask; mask.length = m0.faces.length; mask[] = false;
    mask[4] = true;
    m0.bevelFacesByMask(mask, 0.0f, 0.15f, false, 0, true);  // inset=0, square ON
    m1.bevelFacesByMask(mask, 0.0f, 0.15f, false, 0, false); // inset=0, square OFF
    assert(m0.vertices.length == m1.vertices.length,
        "square+inset=0 must fall back to the plain bevel — no extra split/cap verts");
    assert(m0.faces.length == m1.faces.length,
        "square+inset=0 must fall back to the plain bevel — no extra cap/panel faces");
    foreach (i; 0 .. m0.vertices.length)
        assert((m0.vertices[i] - m1.vertices[i]).length < 1e-9f,
            "square+inset=0 must be byte-identical to square=false (doSquare gate)");
    foreach (i; 0 .. m0.vertices.length)
        foreach (j; i + 1 .. m0.vertices.length)
            assert((m0.vertices[i] - m0.vertices[j]).length > 1e-7f,
                "square+inset=0 must not introduce coincident/duplicate vertices");
}

unittest { // bevelFacesByMask: group=false is byte-identical to the pre-0391
           // kernel on the SAME 3-face-corner selection — the shared-corner
           // accumulator is opt-in only (task 0391 Phase 4 back-compat gate).
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[3] = true; mask[4] = true; mask[1] = true;
    size_t n = m.bevelFacesByMask(mask, 0.15f, 0.1f); // group defaults false, segments 0
    assert(n == 3);
    // Ungrouped: each face computes its OWN 4 independent corners — no
    // vertex is shared, so no orphaning, and no ring quad is suppressed.
    assert(m.vertices.length == 8 + 3 * 4, "ungrouped should add 4 new verts per face, no sharing/orphaning");
    assert(m.faces.length    == 6 + 3 * 4, "ungrouped should add 4 ring quads per face, none suppressed");
}

unittest { // bevelFacesByMask: Segments — LINEAR staircase law (task 0391
           // Phase 5, `vibe3d-divergence` from edge.bevel's Round Level TRUE
           // ARC — plain equal-lerp rings, not a circle). N=3 on a lone
           // face's pure inset (no shift) should land intermediate rings at
           // EXACTLY 1/3 and 2/3 of the final inset.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true; // +Y top face
    size_t n = m.bevelFacesByMask(mask, 0.3f, 0.0f, false, 3);
    assert(n == 1);
    // +4 verts per extra segment (2 intermediate rings of 4 corners each) +
    // the final ring (4) = +12 total; +4 ring quads per segment (3 segs ×
    // 4 edges = 12) vs. the flat case's 4.
    assert(m.vertices.length == 8 + 12, "expected 8+12=20 verts at segments=3");
    assert(m.faces.length    == 6 + 12, "expected 6+12=18 faces at segments=3 (3 rings x 4 edges)");
    // Top face corners start at y=0.5, x/z=±0.5; pure inset (no shift) pulls
    // each corner toward the centroid by 0.3 total over 3 equal steps —
    // 0.1 per step along BOTH in-plane axes (a 90° corner's offsetMeet is
    // additive per axis, verified above). Ring 1 (t=1/3) should land a
    // corner near (0.4, 0.5, 0.4); ring 2 (t=2/3) near (0.3, 0.5, 0.3).
    bool foundStep1 = false, foundStep2 = false;
    foreach (v; m.vertices) {
        if ((v - Vec3(0.4f, 0.5f, 0.4f)).length < 1e-4f) foundStep1 = true;
        if ((v - Vec3(0.3f, 0.5f, 0.3f)).length < 1e-4f) foundStep2 = true;
    }
    assert(foundStep1, "segments=3 should land an intermediate ring at exactly 1/3 inset");
    assert(foundStep2, "segments=3 should land an intermediate ring at exactly 2/3 inset");
}

unittest { // bevelFacesByMask: segments<=1 is byte-identical to the flat
           // (pre-0391) single-ring result — segs=0 == segs=1 == today.
    auto m0 = makeCube();
    auto m1 = makeCube();
    auto mF = makeCube();
    bool[] mask; mask.length = m0.faces.length; mask[] = false; mask[4] = true;
    assert(m0.bevelFacesByMask(mask, 0.1f, 0.2f, false, 0) == 1);
    assert(m1.bevelFacesByMask(mask, 0.1f, 0.2f, false, 1) == 1);
    assert(mF.bevelFacesByMask(mask, 0.1f, 0.2f)            == 1); // pre-0391 2-arg call site
    assert(m0.vertices.length == m1.vertices.length && m1.vertices.length == mF.vertices.length);
    assert(m0.faces.length    == m1.faces.length    && m1.faces.length    == mF.faces.length);
    foreach (i; 0 .. m0.vertices.length) {
        assert((m0.vertices[i] - m1.vertices[i]).length < 1e-6f, "segments=0 must equal segments=1");
        assert((m0.vertices[i] - mF.vertices[i]).length < 1e-6f, "segments=0 must equal the pre-0391 2-arg call");
    }
}

unittest { // bevelFacesByMask: segments DoS clamp — an absurd segment count
           // must clamp to MAX_BEVEL_SEGMENTS, not allocate N linear rings
           // (task 0391 Phase 5). A direct/scripted caller can reach this
           // kernel without the command/tool Param's `.max()` hint, which
           // is UI/HTTP-only and does not clamp this path.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
    size_t n = m.bevelFacesByMask(mask, 0.1f, 0.0f, false, 1_000_000);
    assert(n == 1, "should still process (segments clamped, not rejected)");
    // MAX_BEVEL_SEGMENTS=64 → 64 rings x 4 edges = 256 ring quads for this
    // one face — bounded, not the 1,000,000 the raw request would imply.
    assert(m.faces.length > 10 && m.faces.length < 400,
        "ring-quad count should reflect the CLAMPED segment count, not the raw request");
}

unittest { // spinEdge: tri–tri flip, boundary no-op, fold-over SPINS (task 1200)
    // ---- case 1: successful tri–tri spin ----
    // Four vertices of a unit quad split along diagonal 0–2.
    //   v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1)
    //   f0=[0,1,2]  f1=[0,2,3]   shared edge: 0–2
    // After spin: new edge 1–3; faces become {0,1,3} and {1,2,3}.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 2u, 3u]);
    m.buildLoops();

    uint ei02 = m.edgeIndex(0, 2);
    assert(ei02 != ~0u, "shared edge 0-2 must exist before spin");

    bool ok = m.spinEdge(ei02);
    assert(ok, "spinEdge must return true on a valid tri pair");

    // Old diagonal absent; new diagonal present.
    assert(m.edgeIndex(0, 2) == ~0u, "edge 0-2 must be absent after spin");
    assert(m.edgeIndex(1, 3) != ~0u, "edge 1-3 must exist after spin");

    // Counts unchanged: 4 verts, 5 edges, 2 faces.
    assert(m.vertices.length == 4, "vertex count unchanged");
    assert(m.edges.length    == 5, "edge count unchanged");
    assert(m.faces.length    == 2, "face count unchanged");

    // Face vertex sets must be {0,1,3} and {1,2,3} (order-independent).
    bool[uint] f0s, f1s;
    foreach (v; m.faces[0]) f0s[v] = true;
    foreach (v; m.faces[1]) f1s[v] = true;
    bool has013 = (0u in f0s && 1u in f0s && 3u in f0s)
               || (0u in f1s && 1u in f1s && 3u in f1s);
    bool has123 = (1u in f0s && 2u in f0s && 3u in f0s)
               || (1u in f1s && 2u in f1s && 3u in f1s);
    assert(has013, "one face must be {0,1,3}");
    assert(has123, "one face must be {1,2,3}");

    // ---- case 2: boundary edge → no-op ----
    Mesh m2;
    m2.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0.5f,0,1)];
    m2.addFace([0u, 1u, 2u]);
    m2.buildLoops();

    uint bEi = m2.edgeIndex(0, 1);
    assert(bEi != ~0u);
    assert(!m2.spinEdge(bEi), "spinEdge on boundary edge must return false");
    assert(m2.faces.length  == 1, "faces unchanged after boundary no-op");
    assert(m2.edges.length  == 3, "edges unchanged after boundary no-op");

    // ---- case 3: fold-over — the prospective diagonal already exists ----
    // [0,1,2] + [0,2,3] share edge 0-2.  [1,2,3] already owns edge 1-3.
    //
    // Task 1200 (ledger row 17): the reference spins ANYWAY, and the owner's
    // call (2026-08-18) was to match it. The result is non-manifold by
    // construction, and both halves of that are asserted here rather than
    // described: the EDGE COUNT FALLS (the "new" diagonal was already in the
    // mesh, so one edge leaves and none arrives) and edge 1-3 ends up with
    // THREE incident faces.
    Mesh m3;
    m3.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0.5f,0,1), Vec3(0.5f,0.5f,0.5f)];
    m3.addFace([0u, 1u, 2u]);
    m3.addFace([0u, 2u, 3u]);
    m3.addFace([1u, 2u, 3u]);
    m3.buildLoops();

    uint ei02m3 = m3.edgeIndex(0, 2);
    assert(ei02m3 != ~0u);
    assert(m3.edges.length == 6, "fixture: six edges before the spin");
    assert(m3.spinEdge(ei02m3),
           "spinEdge must APPLY even though the new diagonal already exists");
    assert(m3.edgeIndex(0, 2) == ~0u, "the spun diagonal 0-2 is gone");
    assert(m3.edgeIndex(1, 3) != ~0u, "1-3 is now the shared diagonal too");
    assert(m3.edges.length == 5,
           "edge count must FALL 6 -> 5 — the created diagonal already existed");
    assert(m3.faces.length == 3, "still three faces");
    assert(m3.edgeFaceUseCounts()[m3.edgeIndex(1, 3)] == 3,
           "edge 1-3 now carries THREE faces — non-manifold, measured");
    // Two faces on the same vertex set {1,2,3}: the spin's product duplicates
    // the pre-existing third face, exactly as the reference's does.
    int on123 = 0;
    foreach (ref f; m3.faces) {
        if (f.length != 3) continue;
        bool[uint] fs;
        foreach (v; f) fs[v] = true;
        if (1u in fs && 2u in fs && 3u in fs) ++on123;
    }
    assert(on123 == 2, "TWO faces must stand on {1,2,3} after the spin");
}

unittest { // spinEdge: quad–quad spin, MIXED spin, quad fold-over spin, d==e reject
    // ---- case 4: quad–quad positive spin ----
    // Six vertices, two quads sharing edge 1–2.
    //   v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1) v4=(2,0,0) v5=(2,0,1)
    //   f0=[0,1,2,3]  f1=[1,4,5,2]   shared edge: 1–2
    // After spin (c=3, e=4): new diagonal 3–4; newFace1={0,1,3,4}, newFace2={2,3,4,5}.
    Mesh m4;
    m4.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1),
                   Vec3(2,0,0), Vec3(2,0,1)];
    m4.addFace([0u, 1u, 2u, 3u]);
    m4.addFace([1u, 4u, 5u, 2u]);
    m4.buildLoops();

    uint ei12 = m4.edgeIndex(1, 2);
    assert(ei12 != ~0u, "shared edge 1-2 must exist before quad spin");

    bool ok4 = m4.spinEdge(ei12);
    assert(ok4, "spinEdge must return true on a valid quad pair");

    // Old diagonal 1-2 gone; new diagonal 3-4 present.
    assert(m4.edgeIndex(1, 2) == ~0u, "edge 1-2 must be absent after quad spin");
    assert(m4.edgeIndex(3, 4) != ~0u, "edge 3-4 must exist after quad spin");

    // Counts unchanged: 6 verts, 7 edges, 2 faces.
    assert(m4.vertices.length == 6, "vertex count unchanged after quad spin");
    assert(m4.edges.length    == 7, "edge count unchanged after quad spin");
    assert(m4.faces.length    == 2, "face count unchanged after quad spin");

    // Face vertex sets: {0,1,3,4} and {2,3,4,5} (order-independent).
    bool[uint] q0s, q1s;
    foreach (v; m4.faces[0]) q0s[v] = true;
    foreach (v; m4.faces[1]) q1s[v] = true;
    bool has0134 = (0u in q0s && 1u in q0s && 3u in q0s && 4u in q0s)
                || (0u in q1s && 1u in q1s && 3u in q1s && 4u in q1s);
    bool has2345 = (2u in q0s && 3u in q0s && 4u in q0s && 5u in q0s)
                || (2u in q1s && 3u in q1s && 4u in q1s && 5u in q1s);
    assert(has0134, "one face must be {0,1,3,4} after quad spin");
    assert(has2345, "one face must be {2,3,4,5} after quad spin");
    // Both faces must remain quads.
    assert(m4.faces[0].length == 4, "face 0 must remain a quad");
    assert(m4.faces[1].length == 4, "face 1 must remain a quad");

    // ---- case 5: mixed tri–quad pair → SPINS, valences preserved ----
    // f0=[0,1,2] (tri) and f1=[1,3,4,2] (quad) share edge 1–2.
    // Task 1200 (ledger row 9): the reference's gate never asked for equal
    // valence. Each face keeps its OWN arity across the spin — the triangle
    // stays a triangle — which is the part a rule that merely "supported mixed
    // pairs" could get wrong while still returning true.
    Mesh m5;
    m5.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(2,0,0), Vec3(2,0,1)];
    m5.addFace([0u, 1u, 2u]);
    m5.addFace([1u, 3u, 4u, 2u]);
    m5.buildLoops();

    uint ei12m5 = m5.edgeIndex(1, 2);
    assert(ei12m5 != ~0u, "shared edge 1-2 must exist for mixed case");
    assert(m5.spinEdge(ei12m5), "mixed tri–quad must APPLY");
    assert(m5.edgeIndex(1, 2) == ~0u, "the old diagonal 1-2 is gone");
    assert(m5.edgeIndex(0, 3) != ~0u, "the new diagonal is 0-3");
    assert(m5.edges.length == 6, "one diagonal out, one in — six edges either way");
    assert(m5.faces.length == 2, "still two faces");
    assert(m5.faces[0].length == 3, "the triangle is STILL a triangle");
    assert(m5.faces[1].length == 4, "the quad is STILL a quad");
    {
        bool[uint] t, q;
        foreach (v; m5.faces[0]) t[v] = true;
        foreach (v; m5.faces[1]) q[v] = true;
        assert(0u in t && 1u in t && 3u in t, "the triangle is {0,1,3}");
        assert(0u in q && 2u in q && 3u in q && 4u in q, "the quad is {0,2,3,4}");
    }

    // ---- case 6: quad fold-over → SPINS (task 1200, row 17's law on quads) ----
    // Two quads sharing edge 1–2, plus a triangle [3,4,6] that pre-creates
    // edge 3–4 (the prospective diagonal c–e).
    Mesh m6;
    m6.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1),
                   Vec3(2,0,0), Vec3(2,0,1), Vec3(1,-1,0.5f)];
    m6.addFace([0u, 1u, 2u, 3u]);   // quad; dart 1→2 at j=1
    m6.addFace([1u, 4u, 5u, 2u]);   // quad; dart 2→1 at j=3
    m6.addFace([3u, 4u, 6u]);       // triangle; adds edge 3–4 (= c–e diagonal)
    m6.buildLoops();

    uint ei12m6 = m6.edgeIndex(1, 2);
    assert(ei12m6 != ~0u, "shared edge 1-2 must exist for quad fold-over case");
    assert(m6.edgeIndex(3, 4) != ~0u, "edge 3-4 must pre-exist (fold-over setup)");
    assert(m6.edges.length == 10, "fixture: ten edges before the spin");
    assert(m6.spinEdge(ei12m6), "quad fold-over must APPLY");
    assert(m6.edgeIndex(1, 2) == ~0u, "the old diagonal 1-2 is gone");
    assert(m6.edges.length == 9,
           "edge count falls 10 -> 9: the created diagonal 3-4 already existed");
    assert(m6.edgeFaceUseCounts()[m6.edgeIndex(3, 4)] == 3,
           "edge 3-4 now carries THREE faces");

    // ---- case 7: d==e degenerate case (Risk 3a) ----
    // Two quads sharing edge 1–2 where a boundary vertex coincides across faces.
    //   f0=[0,1,2,3]: dart 1→2 at j=1; c=3, d=0.
    //   f1=[2,1,0,4]: dart 2→1 at j=0; e=0, f_=4.
    //   → d==e==0; "two faces share two edges" — the spin would build a face
    //     with a REPEATED corner, which the shape guard still refuses. Task
    //     1200 replaced the six-way all-distinct test with a direct
    //     repeated-vertex test on the two rings the spin is about to write;
    //     this case is what pins that the replacement did not lose it.
    Mesh m7;
    m7.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1), Vec3(2,0,1)];
    m7.addFace([0u, 1u, 2u, 3u]);   // dart 1→2 at j=1; c=3, d=0
    m7.addFace([2u, 1u, 0u, 4u]);   // dart 2→1 at j=0; e=0, f_=4 → d==e==0
    m7.buildLoops();

    uint ei12m7 = m7.edgeIndex(1, 2);
    assert(ei12m7 != ~0u, "shared edge 1-2 must exist for degenerate case");
    assert(!m7.spinEdge(ei12m7), "d==e degenerate case must return false");
    // Mesh must be completely unmutated.
    assert(m7.faces[0].length == 4, "face 0 unchanged after degenerate no-op");
    assert(m7.faces[1].length == 4, "face 1 unchanged after degenerate no-op");
    assert(m7.edgeIndex(1, 2) != ~0u, "edge 1-2 must still exist after degenerate no-op");

    // ---- case 8: c==e degenerate — all-distinct guard is the SOLE catch ----
    // Two quads sharing edge a–b (0–1) PLUS a third shared boundary vertex X=2,
    // producing c == e == 2.  No self-loop edge 2–2 can exist in any mesh, so
    // edgeIndex(2, 2) == ~0u and the fold-over guard is bypassed entirely.
    // Only the all-distinct guard (bv[2]==bv[4]) catches this degeneracy.
    //
    //   v0=(1,0,0)  v1=(1,0,1)  v2=(0.5,1,0.5)  v3=(0,0,1)  v4=(2,0,0)
    //   f0=[0,1,2,3]:  dart 0→1 at j=0; c = f0[(0+2)%4] = 2, d = f0[(0+3)%4] = 3
    //   f1=[1,0,2,4]:  dart 1→0 at j=0; e = f1[(0+2)%4] = 2, f_ = f1[(0+3)%4] = 4
    //   boundary verts = [a=0, b=1, c=2, d=3, e=2, f_=4] → bv[2]==bv[4].
    //   Without the all-distinct guard, spinEdge would build degenerate faces
    //   [2,3,0,2] and [2,4,1,2] (vertex 2 repeated) and return true — RED.
    Mesh m8;
    m8.vertices = [Vec3(1,0,0), Vec3(1,0,1), Vec3(0.5f,1,0.5f), Vec3(0,0,1), Vec3(2,0,0)];
    m8.addFace([0u, 1u, 2u, 3u]);   // dart 0→1 at j=0 → c=2, d=3
    m8.addFace([1u, 0u, 2u, 4u]);   // dart 1→0 at j=0 → e=2, f_=4 → c==e==2
    m8.buildLoops();

    uint ei01m8 = m8.edgeIndex(0, 1);
    assert(ei01m8 != ~0u, "shared edge 0-1 must exist for c==e case");
    // Confirm that the fold-over guard is bypassed: no self-loop edge 2–2 exists.
    assert(m8.edgeIndex(2, 2) == ~0u, "no self-loop edge 2-2 should exist (fold-over guard bypassed)");
    // Only the all-distinct guard blocks this; spinEdge must refuse.
    assert(!m8.spinEdge(ei01m8), "c==e degenerate: all-distinct guard must return false");
    // Mesh must be completely unmutated.
    assert(m8.faces[0].length == 4, "face 0 unchanged after c==e no-op");
    assert(m8.faces[1].length == 4, "face 1 unchanged after c==e no-op");
    assert(m8.edgeIndex(0, 1) != ~0u, "edge 0-1 must still exist after c==e no-op");
}

unittest { // extractSelectedEdgeCycles: two rings, figure-eight rejection
    // Build a tiny mesh with two isolated quad rings as boundary edges.
    // The mesh: two coaxial caps (faces 0 and 1), no other faces.
    Mesh m;
    // A cap: verts 0-3 at z=0
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    // B cap: verts 4-7 at z=1
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    m.addFace([0u,1u,2u,3u]);
    m.addFace([4u,5u,6u,7u]);
    m.buildLoops();
    m.syncSelection();   // resize edgeMarks to edges.length before selectEdge

    // Select all edges (each cap's 4-edge perimeter = 8 edges total).
    foreach (ei; 0 .. m.edges.length)
        m.selectEdge(cast(int)ei);

    auto cycles = m.extractSelectedEdgeCycles();
    assert(cycles.length == 2, "two disjoint cycles");
    assert(cycles[0].length == 4 || cycles[1].length == 4, "4-vertex cycles");

    // Figure-eight: vertex shared by both triangles → degree 4 → rejected.
    // Triangle A: [0,1,2], Triangle B: [2,3,4], vertex 2 is shared.
    Mesh m2;
    foreach (i; 0 .. 5) m2.addVertex(Vec3(cast(float)i, 0, 0));
    m2.addFace([0u,1u,2u]);
    m2.addFace([2u,3u,4u]);
    m2.buildLoops();
    m2.syncSelection();  // resize edgeMarks before selectEdge
    foreach (ei; 0 .. m2.edges.length) m2.selectEdge(cast(int)ei);
    auto c2 = m2.extractSelectedEdgeCycles();
    assert(c2.length == 0, "figure-eight (degree-4 vertex) must be rejected");
}

unittest { // happy-path quad: 4 free coplanar verts → 1 face, 4 edges, winding = click order
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    int fi = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fi == 0, "expected face index 0");
    assert(m.faces.length == 1, "expected 1 face");
    assert(m.edges.length == 4, "expected 4 edges");
    assert(m.faces[0][] == [0u, 1u, 2u, 3u], "winding mismatch");
}

unittest { // winding follows selection order exactly (different from ascending index)
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    int fi = m.makePolygonFromVerts([0, 3, 2, 1], false);
    assert(fi == 0, "expected face 0");
    assert(m.faces[0][] == [0u, 3u, 2u, 1u], "winding must follow click order, not index order");
}

unittest { // flip reverses winding
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    int fi = m.makePolygonFromVerts([0, 1, 2, 3], true);
    assert(fi == 0);
    assert(m.faces[0][] == [3u, 2u, 1u, 0u], "flip must reverse winding");
}

unittest { // <3 distinct verts → reject
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0)];
    m.buildLoops();
    assert(m.makePolygonFromVerts([0, 1], false) == -1, "<2 verts must reject");
    assert(m.makePolygonFromVerts([0, 0, 0], false) == -1, "all-same verts must reject");
    assert(m.faces.length == 0, "no face should be added on reject");
}

unittest { // collinear / zero-area → reject
    Mesh m;
    // Three collinear points on the x-axis
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0)];
    m.buildLoops();
    assert(m.makePolygonFromVerts([0, 1, 2], false) == -1, "collinear must reject");
    assert(m.faces.length == 0);
}

unittest { // duplicate face → no-op (returns -1, faceCount unchanged)
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    int fi1 = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fi1 == 0);
    // Re-run with same vertices in a different order (same unordered set)
    int fi2 = m.makePolygonFromVerts([2, 3, 0, 1], false);
    assert(fi2 == -1, "duplicate vertex set must be rejected");
    assert(m.faces.length == 1, "faceCount must stay 1 on dup reject");
}

unittest { // edge dedup: new face shares one edge with existing triangle → only 2 new edges
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    // First triangle [0,1,2] creates 3 edges
    m.makePolygonFromVerts([0, 1, 2], false);
    size_t edgesAfterTri = m.edges.length;
    assert(edgesAfterTri == 3, "triangle should have 3 edges");
    // Second triangle [1,3,2] shares edge 1-2 with the first face
    m.makePolygonFromVerts([1, 3, 2], false);
    assert(m.edges.length == edgesAfterTri + 2,
        "expected exactly 2 new edges (shared edge reused)");
    assert(m.faces.length == 2);
}

unittest { // non-convex (concave) click order is ACCEPTED as-is (trust click order contract)
    // 5-vertex concave polygon: v3=(2,1,0) is a reflex vertex pushed inward from
    // the convex hull. Order [0,1,2,3,4] visits it in sequence and the kernel MUST
    // preserve that order (no silent convex-hull reordering). Newell area ≈ 20 → passes.
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(4, 0, 0), Vec3(4, 4, 0), Vec3(2, 1, 0), Vec3(0, 4, 0),
    ];
    m.buildLoops();
    int fi = m.makePolygonFromVerts([0, 1, 2, 3, 4], false);
    assert(fi == 0, "concave click order must be accepted");
    assert(m.faces[0][] == [0u, 1u, 2u, 3u, 4u], "concave order must not be reordered");
}

unittest { // adjacent polygon auto-orients to match a neighbor's winding, even
           // when the hand-picked vertex order would traverse the shared edge
           // in the SAME direction as the existing face (the exact corruption
           // that broke facesAroundEdge/collectEdgeRing/Loop Slice in task 0394).
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), // 0..3: quad A
        Vec3(2, 1, 0), Vec3(2, 0, 0),                               // 4,5: quad B's extra corners
    ];
    m.buildLoops();
    int fiA = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fiA == 0, "quad A must be created");
    // Quad A traverses the shared edge as 1→2. The correctly-wound neighbor
    // quad (the simple, non-self-intersecting square spanning x=1..2) is the
    // cycle [1,5,4,2] (or any rotation) — traversing the shared edge as 2→1,
    // opposite A. Entering it as [1,2,4,5] instead (a rotation of the
    // REVERSED cycle) is still the same simple quad shape, but now traverses
    // the shared edge 1→2 — same direction as A, which a manifold forbids.
    // The kernel must flip it back to a rotation of the correct cycle.
    int fiB = m.makePolygonFromVerts([1, 2, 4, 5], false);
    assert(fiB == 1, "adjacent quad B must be created");
    assert(m.faces[fiB][] == [5u, 4u, 2u, 1u],
        "B must be auto-flipped to [5,4,2,1] so the shared edge (1,2) is "
        ~ "traversed opposite A's direction, not left as the literal [1,2,4,5] click order");

    // No same-direction shared edge should exist between A and B afterward.
    auto fA = m.faces[fiA], fB = m.faces[fiB];
    bool sameDirFound = false;
    foreach (ka; 0 .. fA.length) {
        uint au = fA[ka], av = fA[(ka + 1) % fA.length];
        foreach (kb; 0 .. fB.length) {
            uint bu = fB[kb], bv = fB[(kb + 1) % fB.length];
            if (au == bu && av == bv) sameDirFound = true;
        }
    }
    assert(!sameDirFound,
        "adjacent faces must not traverse their shared edge in the same direction");
}

unittest { // free-floating polygon (no shared edge with ANY existing face) still
           // honors orderedIdx + flip exactly as before -- auto-orient only
           // engages when there's an adjacent face to key off of. A DISTANT,
           // unrelated face already exists in the mesh to prove the adjacency
           // scan correctly finds nothing relevant, not merely "mesh is empty".
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), // 0..3: unrelated distant tri lives elsewhere
        Vec3(10, 0, 0), Vec3(11, 0, 0), Vec3(11, 1, 0), Vec3(10, 1, 0), // 4..7: the free-floating quad
    ];
    m.buildLoops();
    int fiFar = m.makePolygonFromVerts([0, 1, 2], false);
    assert(fiFar == 0, "unrelated distant triangle must be created");

    // flip=false: winding must follow click order verbatim.
    int fi1 = m.makePolygonFromVerts([4, 5, 6, 7], false);
    assert(fi1 == 1);
    assert(m.faces[fi1][] == [4u, 5u, 6u, 7u], "free-floating: no-flip must follow click order exactly");

    // flip=true on a SECOND free-floating quad: must reverse exactly as before.
    m.vertices ~= [Vec3(20, 0, 0), Vec3(21, 0, 0), Vec3(21, 1, 0), Vec3(20, 1, 0)];
    m.buildLoops();
    int fi2 = m.makePolygonFromVerts([8, 9, 10, 11], true);
    assert(fi2 == 2);
    assert(m.faces[fi2][] == [11u, 10u, 9u, 8u], "free-floating: flip=true must reverse click order exactly");
}

unittest { // ONE-vs-ONE tie (pre-existing mesh corruption, out of scope for
           // this fix): equal same-direction / opposite-direction vote counts
           // keep `idx` exactly as entered, honoring `orderedIdx` + `flip`
           // rather than arbitrarily picking a side. Under the old "first
           // edge decides" rule this happened to match too (P is checked
           // first and wants no flip) -- this test now documents the TIE
           // rule specifically, since majority-vote (task 0394) no longer
           // cares about scan order, only the final tally.
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), // 0..3: the new quad F
        Vec3(2, -1, 0),   // 4: P's extra corner
        Vec3(2, 2, 0),    // 5: Q's extra corner
    ];
    m.buildLoops();
    // P traverses the shared edge (0,1) as 1→0 -- OPPOSITE of F's future [0,1,2,3]
    // (0→1) -- an "opposite" vote (no flip wanted).
    m.addFace([1, 0, 4]);
    // Q traverses the shared edge (2,3) as 2→3 -- the SAME direction F's
    // [0,1,2,3] would use (2→3) -- a "same-direction" vote (flip wanted).
    m.addFace([2, 3, 5]);

    int fiF = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fiF >= 0, "F must be created (neither shared edge is already 2-faced)");
    // 1 same-direction vote (Q) vs 1 opposite-direction vote (P) -- a tie.
    // Majority vote requires STRICTLY more same-direction votes to flip, so
    // a tie keeps the literal click order.
    assert(m.faces[fiF][] == [0u, 1u, 2u, 3u],
        "a 1-vs-1 vote tie must keep F's literal click order unflipped, not "
        ~ "flip just because SOME neighbor disagrees");
}

unittest { // genuine 2-vs-1 MAJORITY (reference-editor parity, task 0394): a clear
           // majority of same-direction votes must flip the new face even
           // though the FIRST boundary edge checked (in idx order) is an
           // opposite-direction vote that alone would want no flip -- this
           // is exactly where "first edge decides" and "majority vote" (this
           // fix) diverge.
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), // 0..3: the new quad F
        Vec3(2, -1, 0),    // 4: P's extra corner (opposite-direction vote)
        Vec3(2, 0.5, 0),   // 5: Q1's extra corner (same-direction vote)
        Vec3(-1, 0.5, 0),  // 6: Q2's extra corner (same-direction vote)
    ];
    m.buildLoops();
    // P: shared edge (0,1) as 1→0 -- OPPOSITE of F's future (0→1) -- opposite vote.
    m.addFace([1, 0, 4]);
    // Q1: shared edge (1,2) as 1→2 -- SAME as F's future (1→2) -- same-direction vote.
    m.addFace([1, 2, 5]);
    // Q2: shared edge (2,3) as 2→3 -- SAME as F's future (2→3) -- same-direction vote.
    m.addFace([2, 3, 6]);

    int fiF = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fiF >= 0, "F must be created (no shared edge is already 2-faced)");
    // 2 same-direction votes (Q1, Q2) beat 1 opposite-direction vote (P) --
    // majority says flip, even though P (checked first, at i=0) wanted none.
    assert(m.faces[fiF][] == [3u, 2u, 1u, 0u],
        "2-vs-1 same-direction majority must flip F, overriding the "
        ~ "first-checked edge's opposite-direction vote");
}

unittest { // epsSq <= 0: never welds anything (matches naive: squared distance is never < 0)
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(0,0,0), Vec3(1,1,1)];
    m.faces = [[0u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t welded = m.weldCoincidentVertices(0.0);
    assert(welded == 0, "epsSq==0 must weld nothing, even for exactly-coincident verts");
}

unittest { // two-quad strip: edge slides toward positive rail at t=0.5
    // Layout (top view):
    //   v3---v2---v5
    //   |  f0 | f1 |
    //   v0---v1---v4
    // Selected edge: v1-v2.  Rails: v0/v3 (negative), v4/v5 (positive).
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),   // v0-v3
        Vec3(2,0,0), Vec3(2,1,0),                               // v4, v5
    ];
    m.makePolygonFromVerts([0, 1, 2, 3], false);
    m.makePolygonFromVerts([1, 4, 5, 2], false);
    m.buildLoops();

    uint selEi = m.edgeIndex(1, 2);
    assert(selEi != ~0u, "edge v1-v2 must exist");
    bool[] mask = new bool[](m.edges.length);
    mask[selEi] = true;

    // t=0: identity.
    auto pos0 = edgeSlidePositions(m, mask, 0.0f);
    foreach (i; 0 .. m.vertices.length)
        assert(pos0[i] == m.vertices[i], "t=0 must be identity");

    // t=0.5: both endpoints move halfway toward their same-side rails.
    auto pos05 = edgeSlidePositions(m, mask, 0.5f);
    // v1 moves from x=1 toward either v0(x=0) or v4(x=2) by 0.5.
    assert(pos05[1].x != 1.0f, "v1 must move at t=0.5");
    assert(pos05[2].x != 1.0f, "v2 must move at t=0.5");
    // Both must move the same direction (same Δx sign).
    float dv1 = pos05[1].x - 1.0f;
    float dv2 = pos05[2].x - 1.0f;
    assert((dv1 > 0) == (dv2 > 0), "v1 and v2 must slide the same direction");
    // Magnitude: 0.5 × rail distance = 0.5 × 1.0 = 0.5.
    assert(dv1 == 0.5f || dv1 == -0.5f, "magnitude must be 0.5");
    assert(dv2 == 0.5f || dv2 == -0.5f, "magnitude must be 0.5");
    // Non-slid vertices unchanged.
    assert(pos05[0] == m.vertices[0]); assert(pos05[3] == m.vertices[3]);
    assert(pos05[4] == m.vertices[4]); assert(pos05[5] == m.vertices[5]);

    // t=1: both endpoints land exactly on their rail neighbours.
    auto pos1 = edgeSlidePositions(m, mask, 1.0f);
    assert(pos1[1].x == 0.0f || pos1[1].x == 2.0f,
           "v1 at t=1 must coincide with v0 or v4");
    assert(pos1[2].x == 0.0f || pos1[2].x == 2.0f,
           "v2 at t=1 must coincide with v3 or v5");
    // Both land on the SAME side.
    assert(pos1[1].x == pos1[2].x, "v1 and v2 must land on the same-side rail");

    // t=-0.5: opposite direction from t=+0.5.
    auto posN = edgeSlidePositions(m, mask, -0.5f);
    float dvN1 = posN[1].x - 1.0f;
    assert((dv1 > 0) != (dvN1 > 0), "t and -t must slide opposite directions");
}

unittest { // degraded case: single quad, no positive-side rail → vertex unchanged
    // Only one face at the selected edge: no colour-1 face at either endpoint.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.makePolygonFromVerts([0, 1, 2, 3], false);
    m.buildLoops();

    uint selEi = m.edgeIndex(0, 1);
    assert(selEi != ~0u);
    bool[] mask = new bool[](m.edges.length);
    mask[selEi] = true;

    // t=+0.5 → positive side has no rail → both endpoints unchanged.
    // t=-0.5 → negative side has a rail → both endpoints move.
    auto posP = edgeSlidePositions(m, mask,  0.5f);
    auto posN = edgeSlidePositions(m, mask, -0.5f);
    // One of the two sides has no rail (the exposed boundary side).
    // At least one side must leave the endpoints unchanged.
    bool posUnchanged = (posP[0] == m.vertices[0] && posP[1] == m.vertices[1]);
    bool negUnchanged = (posN[0] == m.vertices[0] && posN[1] == m.vertices[1]);
    assert(posUnchanged || negUnchanged,
           "boundary vertex must be unchanged on at least one side");
}

unittest { // loop consistency: all loop verts slide the same direction
    // 3-ring tube (4 verts/ring, 2 rings of quads).
    // Ring 0 (top y=+1): v0..v3   Ring 1 (mid y=0): v4..v7
    // Ring 2 (bot y=-1): v8..v11
    Mesh m;
    m.vertices = [
        Vec3( 1, 1, 0), Vec3( 0, 1, 1), Vec3(-1, 1, 0), Vec3( 0, 1,-1),  // v0-v3
        Vec3( 1, 0, 0), Vec3( 0, 0, 1), Vec3(-1, 0, 0), Vec3( 0, 0,-1),  // v4-v7
        Vec3( 1,-1, 0), Vec3( 0,-1, 1), Vec3(-1,-1, 0), Vec3( 0,-1,-1),  // v8-v11
    ];
    // Upper quads (ring 0 → ring 1).
    m.makePolygonFromVerts([0, 1, 5, 4], false);
    m.makePolygonFromVerts([1, 2, 6, 5], false);
    m.makePolygonFromVerts([2, 3, 7, 6], false);
    m.makePolygonFromVerts([3, 0, 4, 7], false);
    // Lower quads (ring 1 → ring 2).
    m.makePolygonFromVerts([ 4,  5,  9,  8], false);
    m.makePolygonFromVerts([ 5,  6, 10,  9], false);
    m.makePolygonFromVerts([ 6,  7, 11, 10], false);
    m.makePolygonFromVerts([ 7,  4,  8, 11], false);
    m.buildLoops();

    // Select the middle ring (v4-v5, v5-v6, v6-v7, v7-v4).
    bool[] mask = new bool[](m.edges.length);
    foreach (pair; [[4u,5u],[5u,6u],[6u,7u],[7u,4u]]) {
        uint ei = m.edgeIndex(pair[0], pair[1]);
        assert(ei != ~0u, "middle-ring edge must exist");
        mask[ei] = true;
    }

    // t=0.5: all 4 middle verts move the same direction with the same |ΔY|.
    auto posP = edgeSlidePositions(m, mask, 0.5f);
    float[4] dyP;
    foreach (i; 0 .. 4) dyP[i] = posP[4 + i].y - m.vertices[4 + i].y;
    foreach (i; 0 .. 4)
        assert(dyP[i] != 0.0f, "middle vert must move with t=0.5");
    // All deltas must have the same sign (consistency).
    bool allPos = true, allNeg = true;
    foreach (d; dyP) { if (d <= 0) allPos = false; if (d >= 0) allNeg = false; }
    assert(allPos || allNeg, "all middle-ring verts must slide the same direction");
    // All |ΔY| must be equal.
    foreach (i; 1 .. 4)
        assert(dyP[i] == dyP[0], "all middle-ring verts must slide the same amount");

    // t=-0.5 must slide in the opposite direction.
    auto posN = edgeSlidePositions(m, mask, -0.5f);
    foreach (i; 0 .. 4) {
        float dyN = posN[4 + i].y - m.vertices[4 + i].y;
        assert((dyP[i] > 0) != (dyN > 0),
               "t=+0.5 and t=-0.5 must slide in opposite Y directions");
    }
}

unittest { // task 0307: 3-of-4 quad edges selected — mutual-rail must not collapse
    import std.conv : to;
    // Cube face [0,1,5,4] (y=-0.5 face): edges 0-1, 1-5, 5-4, 4-0.
    // Select 3 of its 4 edges (0-1, 1-5, 4-0), leaving 4-5 unselected. Verts
    // 4 and 5 are then each other's ONLY rail candidate on that face — the
    // pre-fix kernel slid both toward each other's *original* position and
    // they coincided exactly at t=0.5 (fuzz-found; fixed by the
    // slidVert(nb) mutual-rail guard above).
    Mesh m = makeCube();
    bool[] mask = new bool[](m.edges.length);
    foreach (pair; [[0u,1u],[1u,5u],[0u,4u]]) {
        uint ei = m.edgeIndex(pair[0], pair[1]);
        assert(ei != ~0u, "quad face-edge must exist");
        mask[ei] = true;
    }
    uint eUnsel = m.edgeIndex(4, 5);
    assert(eUnsel != ~0u && !mask[eUnsel],
        "edge 4-5 must be the lone unselected edge of the quad");

    auto pos = edgeSlidePositions(m, mask, 0.5f);

    // Regression: verts 4 and 5 must NOT coincide.
    float d45 = (pos[4] - pos[5]).length();
    assert(d45 > 0.05f,
        "task 0307 regression: mutual-rail verts 4/5 collapsed, dist=" ~ d45.to!string);

    // Graceful degradation: this is the ONLY face touching 4/5 with a
    // candidate rail, and that candidate is mutual — so both stay put
    // rather than sliding onto (or past) one another.
    assert((pos[4] - m.vertices[4]).length() < 1e-6f,
        "vert 4 has no valid (non-mutual) rail — must stay unchanged");
    assert((pos[5] - m.vertices[5]).length() < 1e-6f,
        "vert 5 has no valid (non-mutual) rail — must stay unchanged");

    // No face becomes degenerate: no two distinct vertices of any face
    // coincide after the slide.
    foreach (const f; m.faces) {
        foreach (ai; 0 .. f.length)
            foreach (bi; ai + 1 .. f.length)
                assert((pos[f[ai]] - pos[f[bi]]).length() > 1e-4f,
                    "task 0307 regression: face has coincident vertices after slide");
    }
}

// effectiveDeleteMode unittests (task 0110)
unittest { // returns current when current mode has a selection
    Mesh m = makeCube();
    m.resetSelection();   // initialises faceMarks / edgeMarks / vertexMarks arrays
    m.selectFace(0);
    m.selectVertex(0);
    // Both polygons and vertices have selections.
    // When current == Polygons, active mode has a selection → return Polygons.
    assert(m.effectiveDeleteMode(EditMode.Polygons) == EditMode.Polygons,
        "active mode has face selection → must return Polygons");
    // When current == Vertices, active mode has a selection → return Vertices.
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Vertices,
        "active mode has vertex selection → must return Vertices");
}

unittest { // redirects to the type that holds a selection (task 0110 cross-mode case)
    Mesh m = makeCube();
    m.resetSelection();
    m.selectFace(0);   // face 0 selected; no verts or edges selected

    // Active mode = Vertices (has NO selection) → redirect to Polygons.
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Polygons,
        "vertices active + only face selected → must redirect to Polygons");
    // Active mode = Edges (has NO selection) → redirect to Polygons.
    assert(m.effectiveDeleteMode(EditMode.Edges) == EditMode.Polygons,
        "edges active + only face selected → must redirect to Polygons");
    // Active mode = Polygons → no redirect (has the selection).
    assert(m.effectiveDeleteMode(EditMode.Polygons) == EditMode.Polygons,
        "polygons active + face selected → no redirect");
}

unittest { // priority: Polygons > Edges > Vertices when multiple types are selected
    Mesh m = makeCube();
    m.resetSelection();
    m.selectFace(0);
    m.selectEdge(0);
    m.selectVertex(0);
    // Active mode = Vertices, but all three types have selections.
    // Vertices has a selection, so no redirect (returns Vertices).
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Vertices,
        "active mode has vertex selection → return Vertices (no redirect needed)");

    // Now clear vertex selection to test Polygons-priority redirect.
    m.deselectVertex(0);
    // Active mode = Vertices (empty), face+edge selected → Polygons wins.
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Polygons,
        "vertices empty, faces+edges selected → Polygons priority");

    // Edges > Vertices: deselect the face too; only edge 0 + vertex 0 remain.
    // Active mode = Polygons (empty, no face selected) → Edges wins over Vertices.
    m.deselectFace(0);
    assert(m.effectiveDeleteMode(EditMode.Polygons) == EditMode.Edges,
        "polygons empty, edges+verts selected → Edges priority over Vertices");
}

unittest { // truly empty (nothing selected anywhere) → return current (whole-mesh path)
    Mesh m = makeCube();
    m.resetSelection();
    // No selection in any mode → effectiveDeleteMode returns current unchanged.
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Vertices,
        "nothing selected → return current (whole-mesh convention)");
    assert(m.effectiveDeleteMode(EditMode.Edges) == EditMode.Edges,
        "nothing selected → return current (whole-mesh convention)");
    assert(m.effectiveDeleteMode(EditMode.Polygons) == EditMode.Polygons,
        "nothing selected → return current (whole-mesh convention)");
}

unittest { // weightMapNames + addWeightMap + vertexWeight + setVertexWeight
    auto m = makeCube();
    assert(m.weightMapNames().length == 0, "fresh cube has no weight maps");
    auto wm = m.addWeightMap("test");
    assert(wm !is null, "addWeightMap returned null");
    assert(m.weightMapNames() == ["test"]);
    assert(wm.data.length == m.vertices.length);
    assert(wm.domain == MapDomain.Point && wm.dim == 1);
    assert(m.vertexWeight("test", 0) == 0.0f, "fresh weight must be 0");
    assert(m.setVertexWeight("test", 0, 0.75f));
    import std.math : fabs;
    assert(fabs(m.vertexWeight("test", 0) - 0.75f) < 1e-6f);
    assert(m.addWeightMap("test") is null, "duplicate name must be rejected");
    assert(m.removeMeshMap("test"));
    assert(m.weightMapNames().length == 0);
    assert(m.vertexWeight("missing", 0) == 0.0f);
    assert(!m.setVertexWeight("missing", 0, 1.0f));
}

unittest { // splitFaceByVertices: selected parent → BOTH halves selected
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    m.selectFace(0);

    size_t n = m.splitFaceByVertices(0, 0, 2); // chord across the non-adjacent diagonal

    assert(n == 1, "quad splits along the 0-2 chord");
    assert(m.faces.length == 2, "2 sub-faces after the split");
    assert(m.isFaceSelected(0) && m.isFaceSelected(1),
           "splitFaceByVertices: both halves of a selected parent must stay selected");
}

unittest { // boundaryLoops: single open grid → 1 loop; closed cube → 0 loops
    Mesh g;
    g.addVertex(Vec3(0,0,0)); g.addVertex(Vec3(1,0,0)); g.addVertex(Vec3(2,0,0));
    g.addVertex(Vec3(0,1,0)); g.addVertex(Vec3(1,1,0)); g.addVertex(Vec3(2,1,0));
    g.addFace([0u,1u,4u,3u]);
    g.addFace([1u,2u,5u,4u]);
    g.buildLoops();
    auto loops = g.boundaryLoops();
    assert(loops.length == 1, "2×1 grid: expected 1 boundary loop");
    assert(loops[0].length == 6, "2×1 grid: boundary loop has 6 verts");

    Mesh c = makeCube();
    c.buildLoops();
    assert(c.boundaryLoops().length == 0, "closed cube: expected 0 boundary loops");
}

unittest { // boundaryLoops: 3×3 grid with center quad removed → 2 loops
    // 16 verts, 8 quads (3×3 minus center at face index 4).
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
            if (fi != 4) m.addFace([a, b, c, d]); // skip center (fi==4)
            fi++;
        }
    m.buildLoops();
    auto loops = m.boundaryLoops();
    assert(loops.length == 2, "3×3 grid minus center: expected 2 boundary loops");
}

unittest { // thickenSurface: closed cube → no-op
    Mesh m = makeCube();
    m.buildLoops();
    const V0 = m.vertices.length, F0 = m.faces.length;
    assert(m.thickenSurface(0.1f) == 0, "thicken cube: no-op");
    assert(m.vertices.length == V0 && m.faces.length == F0, "thicken cube: unchanged");
}

unittest { // thickenSurface: zero thickness → no-op
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addFace([0u,1u,2u,3u]);
    m.buildLoops();
    assert(m.thickenSurface(0.0f) == 0, "zero thickness: no-op");
    assert(m.vertices.length == 4 && m.faces.length == 1, "zero thickness: unchanged");
}

unittest { // thickenSurface: symmetric mode places originals at ±t/2
    import std.math : abs;
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addFace([0u,1u,2u,3u]);
    m.buildLoops();
    m.thickenSurface(0.4f, true);
    foreach (i; 0 .. 4)
        assert(abs(m.vertices[i].z - 0.2f) < 1e-5f, "symmetric: outer vert at +0.2");
    foreach (i; 4 .. 8)
        assert(abs(m.vertices[i].z + 0.2f) < 1e-5f, "symmetric: inner vert at -0.2");
}

unittest { // cube corner v6 (3 incident faces) → 2 copies, 10 verts, 6 faces
    // makeCube faces:
    //   fi=0: [0,3,2,1]  fi=1: [4,5,6,7]  fi=2: [0,4,7,3]
    //   fi=3: [1,2,6,5]  fi=4: [3,7,6,2]  fi=5: [0,1,5,4]
    // v6=(+0.5,+0.5,+0.5) appears in fi=1,3,4.
    // First encounter (fi=1) keeps original; fi=3 → v8; fi=4 → v9.
    auto m = makeCube();
    bool[] mask = new bool[](m.vertices.length);
    mask[6] = true;
    size_t copies = m.splitVerticesByMask(mask);
    assert(copies == 2,               "splitVerticesByMask: expected 2 copies for corner v6");
    assert(m.vertices.length == 10,   "splitVerticesByMask: expected 10 verts");
    assert(m.faces.length    == 6,    "splitVerticesByMask: face count must not change");

    // The 3 faces that originally contained v6 must now reference 3 distinct
    // indices, all at position (+0.5, +0.5, +0.5).
    import std.math : fabs;
    uint[3] splitIdxs = [6u, 8u, 9u];  // deterministic: fi=1 keeps 6, fi=3→8, fi=4→9
    foreach (si; splitIdxs) {
        assert(si < m.vertices.length, "splitVerticesByMask: split index out of range");
        Vec3 p = m.vertices[si];
        assert(fabs(p.x - 0.5f) < 1e-6f && fabs(p.y - 0.5f) < 1e-6f && fabs(p.z - 0.5f) < 1e-6f,
               "splitVerticesByMask: copy position mismatch");
    }
    assert(splitIdxs[0] != splitIdxs[1] && splitIdxs[1] != splitIdxs[2],
           "splitVerticesByMask: copies must be distinct indices");

    // The three faces that touch v6 now each hold a different index.
    // fi=1→v6, fi=3→v8, fi=4→v9.
    bool v6InF1, v8InF3, v9InF4;
    foreach (vid; m.faces[1]) if (vid == 6) v6InF1 = true;
    foreach (vid; m.faces[3]) if (vid == 8) v8InF3 = true;
    foreach (vid; m.faces[4]) if (vid == 9) v9InF4 = true;
    assert(v6InF1, "splitVerticesByMask: fi=1 must keep v6");
    assert(v8InF3, "splitVerticesByMask: fi=3 must get v8");
    assert(v9InF4, "splitVerticesByMask: fi=4 must get v9");

    // Faces that did not contain v6 are unchanged (no v8/v9 in them).
    foreach (vid; m.faces[0]) assert(vid != 8 && vid != 9, "splitVerticesByMask: fi=0 must be untouched");
    foreach (vid; m.faces[2]) assert(vid != 8 && vid != 9, "splitVerticesByMask: fi=2 must be untouched");
    foreach (vid; m.faces[5]) assert(vid != 8 && vid != 9, "splitVerticesByMask: fi=5 must be untouched");
}

unittest { // vertex with exactly 1 incident face → no-op, returns 0
    // Build a single triangle: v0, v1, v2.  v0 is in only 1 face.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u]);
    m.buildLoops();

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;  // v0 is in face 0 only
    size_t copies = m.splitVerticesByMask(mask);
    assert(copies == 0,              "splitVerticesByMask: single-incident vertex must be no-op");
    assert(m.vertices.length == 3,   "splitVerticesByMask: no-op must not add verts");
    assert(m.faces.length    == 1,   "splitVerticesByMask: no-op must not change face count");
}

unittest { // Point-domain map (weight map) values propagate to copies
    // This is the only assertion that exercises the deferred Point-map copy
    // path.  If map values were copied inside the corner loop (before
    // resizeVertexSelection), the write would be OOB → RangeError.
    auto m = makeCube();
    auto wm = m.addWeightMap("split_wt");
    assert(wm !is null);
    m.setVertexWeight("split_wt", 6, 0.75f);

    bool[] mask = new bool[](m.vertices.length);
    mask[6] = true;
    size_t copies = m.splitVerticesByMask(mask);
    assert(copies == 2, "splitVerticesByMask/Point-map: expected 2 copies");

    import std.math : fabs;
    // v6 (kept), v8 (copy 1), v9 (copy 2) must all carry 0.75.
    assert(fabs(m.vertexWeight("split_wt", 6) - 0.75f) < 1e-6f,
           "splitVerticesByMask/Point-map: original v6 weight must be preserved");
    assert(fabs(m.vertexWeight("split_wt", 8) - 0.75f) < 1e-6f,
           "splitVerticesByMask/Point-map: v8 copy must carry source weight");
    assert(fabs(m.vertexWeight("split_wt", 9) - 0.75f) < 1e-6f,
           "splitVerticesByMask/Point-map: v9 copy must carry source weight");
    // Unrelated vertices must remain at 0.
    assert(m.vertexWeight("split_wt", 0) == 0.0f,
           "splitVerticesByMask/Point-map: unrelated vertex must stay 0");
}

// addEdgePoint: midpoint t=0.5 on cube edge {0,1} → +1 vertex at (0,-0.5,-0.5),
// both incident faces share the new index (no T-junction), bare 0-1 adjacency gone.
unittest {
    import std.math : abs;
    auto m = makeCube();
    // Edge {0,1} is stored as [1,0] (first occurrence in addFace([0,3,2,1]) is
    // the 1→0 step at winding position k=3).  Midpoint is orientation-independent.
    uint ei = m.edgeIndexMap[edgeKey(0, 1)];
    uint vi = m.addEdgePoint(ei, 0.5f);
    assert(vi != uint.max,           "addEdgePoint: must succeed on valid cube edge");
    assert(m.vertices.length == 9,   "addEdgePoint: V must be 9 after midpoint split");
    // Midpoint of {0,1}: verts 0=(-0.5,-0.5,-0.5) and 1=(0.5,-0.5,-0.5) → (0,-0.5,-0.5).
    assert(abs(m.vertices[vi].x - 0.0f) < 1e-5f, "addEdgePoint: new vert x must be 0");
    assert(abs(m.vertices[vi].y + 0.5f) < 1e-5f, "addEdgePoint: new vert y must be -0.5");
    assert(abs(m.vertices[vi].z + 0.5f) < 1e-5f, "addEdgePoint: new vert z must be -0.5");
    // No face may still have a bare 0→1 or 1→0 adjacency (index-shared).
    foreach (face; m.faces) {
        for (size_t k = 0; k < face.length; k++) {
            uint fa = face[k], fb = face[(k + 1) % face.length];
            assert(!((fa == 0 && fb == 1) || (fa == 1 && fb == 0)),
                   "addEdgePoint: bare 0-1 edge must not remain in any face");
        }
    }
    // Exactly two faces contain the new vertex (the two former incident faces).
    int facesWithVi = 0;
    foreach (face; m.faces)
        foreach (v; face)
            if (v == vi) { facesWithVi++; break; }
    assert(facesWithVi == 2, "addEdgePoint: exactly 2 faces must contain the new vertex");
}

// addEdgePoint: open-interval guards reject t=0 and t=1 without mutation.
unittest {
    auto m = makeCube();
    uint ei = m.edgeIndexMap[edgeKey(0, 1)];
    assert(m.addEdgePoint(ei, 0.0f) == uint.max, "addEdgePoint: t=0 must fail");
    assert(m.addEdgePoint(ei, 1.0f) == uint.max, "addEdgePoint: t=1 must fail");
    assert(m.vertices.length == 8,               "addEdgePoint: guards must not mutate mesh");
    assert(m.edges.length    == 12,              "addEdgePoint: guards must not mutate edges");
}

// structVersion / loops-validity stamp: the Stage-2 trace table (M7 plan).
// A connectivity sub-version bumped ONLY by the edge/face structural
// primitives, so Points/Position/Marks/isSubpatch changes correctly leave
// loopsValid()/edgeMapUsable() true, while a forgotten buildLoops() after a
// structural change correctly reads invalid.
unittest {
    auto m = makeCube();
    // 1. face op (addFace, inside makeCube) → buildLoops → valid.
    assert(m.loopsValid(),    "trace: face op + buildLoops must be loopsValid");
    assert(m.edgeMapUsable(), "trace: face op + buildLoops must be edgeMapUsable");
    ulong afterBuild = m.structVersion;

    // 2. face op → (forgot buildLoops) → commit(Geometry): structVersion
    //    moves (addFace bumps it) but loopsStamp is left behind → INVALID.
    //    This is the target bug the stamp exists to catch.
    m.addFace([0u, 1u, 2u]); // degenerate w.r.t. real topology, fine for this probe
    assert(m.structVersion > afterBuild,
        "trace: addFace must bump structVersion");
    assert(!m.loopsValid(),
        "trace: addFace without a following buildLoops must read loops INVALID");
    m.buildLoops();
    assert(m.loopsValid(), "trace: buildLoops after the forgotten-rebuild case must re-validate");
}

unittest {
    // 3. bare addVertex (Points-only, wires nothing) must NOT bump
    //    structVersion and must leave loops/edgeMap valid.
    auto m = makeCube();
    assert(m.loopsValid() && m.edgeMapUsable());
    ulong sv0 = m.structVersion;
    m.addVertex(Vec3(9, 9, 9));
    assert(m.structVersion == sv0,
        "trace: Points-only addVertex must NOT bump structVersion");
    assert(m.loopsValid(),    "trace: addVertex must leave loops valid");
    assert(m.edgeMapUsable(), "trace: addVertex must leave edgeMap usable");
}

unittest {
    // 4. position-only commit must NOT bump structVersion and must leave
    //    loops/edgeMap valid.
    auto m = makeCube();
    ulong sv0 = m.structVersion;
    m.vertices[0].x += 1.0f;
    m.commitChange(MeshEditScope.Position);
    assert(m.structVersion == sv0,
        "trace: Position-only commit must NOT bump structVersion");
    assert(m.loopsValid(),    "trace: position commit must leave loops valid");
    assert(m.edgeMapUsable(), "trace: position commit must leave edgeMap usable");
}

unittest {
    // 5. isSubpatch toggle (Marks-class + explicit topologyVersion bump)
    //    must NOT bump structVersion and must leave loops/edgeMap valid.
    auto m = makeCube();
    ulong sv0 = m.structVersion;
    m.setSubpatch(0, true);
    assert(m.structVersion == sv0,
        "trace: isSubpatch toggle must NOT bump structVersion");
    assert(m.loopsValid(),    "trace: isSubpatch toggle must leave loops valid");
    assert(m.edgeMapUsable(), "trace: isSubpatch toggle must leave edgeMap usable");
}

unittest {
    // 6. addFaceFast (batch, external lookup) defers edgeIndexMap: bumps
    //    structVersion (edge/face structural change) but edgeMapUsable()
    //    reads false until the caller's terminal buildLoops(). Once that
    //    runs, both read valid.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    ulong sv0 = m.structVersion;
    uint[ulong] lookup;
    m.addFaceFast(lookup, [0u, 1u, 2u, 3u]);
    assert(m.structVersion > sv0,
        "trace: addFaceFast must bump structVersion");
    assert(!m.edgeMapUsable(),
        "trace: addFaceFast must leave this.edgeIndexMap Stale (deferred contract)");
    assert(!m.loopsValid(),
        "trace: addFaceFast must leave loops stale until the caller's buildLoops()");
    m.buildLoops();
    assert(m.loopsValid(),    "trace: buildLoops after addFaceFast must validate loops");
    assert(m.edgeMapUsable(), "trace: buildLoops after addFaceFast must validate edgeMap");
}

// ---------------------------------------------------------------------------
// 7. Task 0833 — the two stamps are NOT symmetric, and that asymmetry decides
//    which half of a paired `assertLoopsValid(); assertEdgeMapValid();` guard
//    a test can ever demonstrate.
//
//    `addFace` maintains edgeIndexMap as it goes (every edge is inserted
//    through `addEdge`) and re-stamps it Valid at the NEW structVersion, but
//    it does not rebuild loops. So it is a producer of (loops STALE, edgeMap
//    VALID) — the state that makes the loops assert of a pair fire alone.
//
//    The MIRROR state (loops valid, edgeMap stale) has no producer here: every
//    primitive that leaves edgeIndexMap Stale — `addFaceFast` (case 6) and
//    `rebuildEdgesFromFaces` (below) — bumps `structVersion` in the same
//    breath, which invalidates the loops stamp too; `markDerivedEmpty()`
//    invalidates both by construction; and the one arm that would once have
//    validated loops while deliberately emptying the map — `buildLoops(bool
//    rebuildEdgeIndexMap)`'s `false` branch — no longer exists at all: task
//    0790 deleted the parameter after finding zero callers repo-wide for
//    three months. So on this tree `loopsValid()` implies `edgeMapUsable()`
//    not merely "as observed" but BY CONSTRUCTION — `buildLoops()` now always
//    stamps both Valid together, and `markDerivedEmpty()` always drops both
//    together — and the SECOND assert of a pair cannot be the sole failure.
//    This block is the measurement behind that claim; the three paired call
//    sites cite it (commands/select/loop.d, app.d rebuildLoopHoverMask,
//    tools/slice/loop_slice_tool.d toolStateJson).
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    assert(m.loopsValid() && m.edgeMapUsable(), "setup: makeCube is settled");

    // A face on four FRESH vertices — a real face append, not a duplicate of
    // an existing one. addVertex is Points-class and bumps no structVersion.
    const uint a = m.addVertex(Vec3(2, 0, 0));
    const uint b = m.addVertex(Vec3(3, 0, 0));
    const uint c = m.addVertex(Vec3(3, 0, 1));
    const uint d = m.addVertex(Vec3(2, 0, 1));
    m.addFace([a, b, c, d]);

    assert(!m.loopsValid(),
        "trace: addFace without a following buildLoops must read loops STALE");
    assert(m.edgeMapUsable(),
        "trace: addFace maintains edgeIndexMap through addEdge and re-stamps "
        ~ "it Valid — this asymmetry is what lets the loops half of a paired "
        ~ "guard fire on its own");

    // The other direction: the map-invalidating primitive takes the loops
    // stamp down with it, so no legal call leaves (loops valid, map stale).
    auto n = makeCube();
    n.rebuildEdgesFromFaces();
    assert(!n.edgeMapUsable(),
        "trace: rebuildEdgesFromFaces reassigns `edges` directly and must "
        ~ "leave edgeIndexMap Stale");
    assert(!n.loopsValid(),
        "trace: ...and it bumps structVersion, so the loops stamp goes stale "
        ~ "in the same breath — the (loops valid, map stale) state this would "
        ~ "have to produce for an edgeMap-only assert to fire has no producer");
}

unittest { // mergeFacesByMask: 2-quad strip → 1 six-corner n-gon; non-adjacent → no-op
    import std.algorithm : sort;
    import std.conv      : to;

    // Build a flat 2×1 quad grid:
    //   verts: 0=(0,0,0) 1=(1,0,0) 2=(2,0,0)
    //          3=(0,0,1) 4=(1,0,1) 5=(2,0,1)
    //   face 0 = [0,1,4,3], face 1 = [1,2,5,4]  (shared edge 1–4)
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1)); m.addVertex(Vec3(2,0,1));
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.buildLoops();

    // Merge both faces — 1 interior edge (1–4) dissolved.
    bool[] mask = [true, true];
    size_t dissolved = m.mergeFacesByMask(mask);
    assert(dissolved == 1, "expected 1 edge dissolved, got " ~ dissolved.to!string);
    assert(m.faces.length == 1, "expected 1 merged face");

    // The combined boundary has 6 corners (collinear midpoints 1 and 4 survive
    // — v1 restriction: removeEdgesByMask does not dissolve 2-valent verts).
    uint[] corners = m.faces[0].dup;
    assert(corners.length == 6,
           "merged face must have 6 corners (incl. collinear midpoints)");

    // Corner index SET must equal {0,1,2,3,4,5} — all verts lie on the boundary.
    sort(corners);
    assert(corners == [0u,1u,2u,3u,4u,5u],
           "merged face must reference all 6 verts");

    // Non-adjacent mask (only face 0): no shared interior edges → 0 dissolved.
    Mesh m2;
    m2.addVertex(Vec3(0,0,0)); m2.addVertex(Vec3(1,0,0)); m2.addVertex(Vec3(2,0,0));
    m2.addVertex(Vec3(0,0,1)); m2.addVertex(Vec3(1,0,1)); m2.addVertex(Vec3(2,0,1));
    m2.addFace([0u,1u,4u,3u]);
    m2.addFace([1u,2u,5u,4u]);
    m2.buildLoops();
    assert(m2.mergeFacesByMask([true, false]) == 0,
           "single-face mask must dissolve nothing");
    assert(m2.faces.length == 2, "face count unchanged on no-op");
}

unittest { // splitFaceByVertices: quad split along diagonal {0,2} → two tris + attr carry
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    // Set non-default attrs before the split to prove carry-over.
    m.surfaces ~= Surface("TestMat", Vec3(1, 0, 0));
    m.faceMaterial[0] = 1u;
    m.setSubpatch(0, true);

    size_t n = m.splitFaceByVertices(0, 0, 2);
    assert(n == 1,               "splitFaceByVertices: expected 1 split");
    assert(m.faces.length == 2,  "splitFaceByVertices: expected 2 faces");
    assert(m.edges.length == 5,  "splitFaceByVertices: expected 5 edges (4 boundary + 1 chord)");

    // Winding: i=0, j=2 in the scan → f1=[0,1,2], f2=[2,3,0].
    bool hasF1 = false, hasF2 = false;
    foreach (f; m.faces) {
        if (f[] == [0u,1u,2u]) hasF1 = true;
        if (f[] == [2u,3u,0u]) hasF2 = true;
    }
    assert(hasF1, "splitFaceByVertices: expected face [0,1,2]");
    assert(hasF2, "splitFaceByVertices: expected face [2,3,0]");

    // Attr carry: both halves must inherit material=1 and subpatch flag.
    assert(m.faceMaterial.length >= 2,       "splitFaceByVertices: faceMaterial must cover both halves");
    assert(m.faceMaterial[0] == 1u,          "splitFaceByVertices: f0 must carry parent material");
    assert(m.faceMaterial[1] == 1u,          "splitFaceByVertices: f1 must carry parent material");
    assert(m.isFaceSubpatch(0),              "splitFaceByVertices: f0 must carry parent subpatch flag");
    assert(m.isFaceSubpatch(1),              "splitFaceByVertices: f1 must carry parent subpatch flag");
}

unittest { // splitFaceByVertices: adjacent verts → no-op (returns 0, mesh unchanged)
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    // Standard-adjacent: 0→1 and wrap-adjacent: 3→0.
    assert(m.splitFaceByVertices(0, 0, 1) == 0, "adjacent: must return 0");
    assert(m.splitFaceByVertices(0, 3, 0) == 0, "wrap-adjacent: must return 0");
    assert(m.faces.length == 1,                 "adjacent no-op: face count unchanged");
    assert(m.edges.length == 4,                 "adjacent no-op: edge count unchanged");
}

unittest { // splitFaceByVertices: same-vert / OOB / not-in-face → all return 0
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    assert(m.splitFaceByVertices(0, 0,  0)  == 0, "same-vert: must return 0");
    assert(m.splitFaceByVertices(0, 0, 99)  == 0, "OOB vert: must return 0");
    assert(m.splitFaceByVertices(5, 0,  2)  == 0, "OOB face: must return 0");
    assert(m.faces.length == 1,                   "guards: face count unchanged");
}

// Basic: one quad → 4 tri fan, 1 apex at centroid + normal*disp.
unittest {
    import std.math : abs, sqrt, fabs;
    import std.conv : to;
    // Single 2×2 quad in the XZ plane (Y=0).
    // Winding (-1,0,-1),(-1,0,1),(1,0,1),(1,0,-1) gives +Y normal via Newell.
    // (Verified: ny = Σ(a.z-b.z)*(a.x+b.x) over the 4 edges = +8 > 0.)
    // Centroid = (0,0,0); perimeter = 4*2 = 8; N=4; disp = amount*(8/4) = amount*2
    // With amount=0.5: disp = 1.0 → apex at (0,1,0).
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1));
    m.addVertex(Vec3(-1, 0,  1));
    m.addVertex(Vec3( 1, 0,  1));
    m.addVertex(Vec3( 1, 0, -1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.syncSelection();

    // Assign non-default material + subpatch to the face before spiking.
    m.faceMaterial[0] = 7u;
    m.setFaceSubpatch(0, true);

    bool[] mask = [true];
    size_t n = m.spikeFacesByMask(mask, 0.5f);

    assert(n == 1,                 "spikey: expected 1 face processed");
    assert(m.faces.length  == 4,   "spikey: 1 quad → 4 fan tris");
    assert(m.vertices.length == 5, "spikey: 4 original + 1 apex");

    // Apex should be at (0, 0 + 1.0, 0) = (0, 1, 0).
    Vec3 apex;
    bool apexFound = false;
    foreach (v; m.vertices) {
        float dx = v.x - 0f, dy = v.y - 1.0f, dz = v.z - 0f;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-5f) { apex = v; apexFound = true; break; }
    }
    assert(apexFound, "spikey: apex not at expected position (0,1,0)");

    // All 4 fan tris must carry parent material (7) and subpatch flag.
    foreach (fi; 0 .. m.faces.length) {
        assert(m.faceMaterial.length > fi && m.faceMaterial[fi] == 7u,
               "spikey: material not carried to fan tri " ~ fi.to!string);
        assert(m.isFaceSubpatch(fi),
               "spikey: subpatch not carried to fan tri " ~ fi.to!string);
    }

    // Hole-free: every undirected edge shared by ≤ 2 faces.
    int[ulong] undirected;
    foreach (f; m.faces) {
        foreach (k; 0 .. f.length) {
            ulong a = f[k], b = f[(k + 1) % f.length];
            ulong lo = a < b ? a : b, hi = a < b ? b : a;
            undirected[(lo << 32) | hi]++;
        }
    }
    foreach (_, c; undirected) assert(c <= 2, "spikey: non-manifold edge found");
}

// No-op: mask with no face ≥3 verts → returns 0, mesh unchanged.
unittest {
    auto m = makeCube();
    bool[] mask = new bool[](m.faces.length); // all false
    size_t n = m.spikeFacesByMask(mask, 1.0f);
    assert(n == 0, "spikey no-op: expected 0 processed");
    assert(m.faces.length == 6, "spikey no-op: face count must not change");
    assert(m.vertices.length == 8, "spikey no-op: vertex count must not change");
}

// amount=0: fan-triangulate in place (apex at centroid, zero offset).
unittest {
    import std.math : sqrt;
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1));
    m.addVertex(Vec3( 1, 0, -1));
    m.addVertex(Vec3( 1, 0,  1));
    m.addVertex(Vec3(-1, 0,  1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask = [true];
    size_t n = m.spikeFacesByMask(mask, 0.0f);
    assert(n == 1,                "spikey amount=0: expected 1 processed");
    assert(m.faces.length  == 4,  "spikey amount=0: 1 quad → 4 tris");
    assert(m.vertices.length == 5,"spikey amount=0: 4 + 1 apex at centroid");
    // Apex at centroid = (0,0,0)
    bool found = false;
    foreach (v; m.vertices) {
        float d2 = v.x*v.x + v.y*v.y + v.z*v.z;
        if (d2 < 1e-10f) { found = true; break; }
    }
    assert(found, "spikey amount=0: apex must be at centroid (0,0,0)");
}

unittest { // cutByPlane: facePart must carry over to both split halves
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    m.facePart.length = 1;
    m.facePart[0] = 5u;

    size_t nSplit = m.cutByPlane(Vec3(0.5f, 0, 0), Vec3(1, 0, 0));
    assert(nSplit == 1, "facePart/cutByPlane: expected 1 split");
    assert(m.faces.length == 2, "facePart/cutByPlane: expected 2 faces");
    assert(m.facePart.length >= 2, "facePart must cover both sub-faces");
    assert(m.facePart[0] == 5u, "f0 must inherit parent facePart 5");
    assert(m.facePart[1] == 5u, "f1 must inherit parent facePart 5");
}

unittest { // splitFaceByVertices: facePart must carry over to both halves
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    m.facePart.length = 1;
    m.facePart[0] = 3u;

    size_t n = m.splitFaceByVertices(0, 0, 2);
    assert(n == 1, "facePart/splitFaceByVertices: expected 1 split");
    assert(m.facePart.length >= 2, "facePart must cover both halves");
    assert(m.facePart[0] == 3u, "f0 must carry parent facePart 3");
    assert(m.facePart[1] == 3u, "f1 must carry parent facePart 3");
}

unittest { // spikeFacesByMask: facePart must carry to all fan tris
    import std.conv : to;
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1)); m.addVertex(Vec3(-1, 0,  1));
    m.addVertex(Vec3( 1, 0,  1)); m.addVertex(Vec3( 1, 0, -1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.syncSelection();

    m.facePart.length = 1;
    m.facePart[0] = 9u;

    bool[] mask = [true];
    size_t n = m.spikeFacesByMask(mask, 0.5f);
    assert(n == 1, "facePart/spike: expected 1 face processed");
    assert(m.faces.length == 4, "facePart/spike: expected 4 fan tris");
    foreach (fi; 0 .. m.faces.length)
        assert(m.facePart.length > fi && m.facePart[fi] == 9u,
               "facePart not carried to fan tri " ~ fi.to!string);
}

// weldVertexPair unittests
unittest { // basic weld: two separate quads, weld cross-quad → count drops exactly 1
    import std.math : abs;
    import std.conv : to;
    // Two separate quads with no shared vertices:
    //   quad A: v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1) → face [0,1,2,3]
    //   quad B: v4=(3,0,0) v5=(4,0,0) v6=(4,0,1) v7=(3,0,1) → face [4,5,6,7]
    // Weld keep=1, drop=5: v1=(1,0,0) ← v5=(4,0,0).
    // v1 and v5 share no face → weld must succeed (welded=1, 7 verts after).
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,0,1)); m.addVertex(Vec3(0,0,1));
    m.addVertex(Vec3(3,0,0)); m.addVertex(Vec3(4,0,0));
    m.addVertex(Vec3(4,0,1)); m.addVertex(Vec3(3,0,1));
    m.addFace([0u,1u,2u,3u]);
    m.addFace([4u,5u,6u,7u]);
    m.buildLoops();

    size_t welded = m.weldVertexPair(1, 5);
    assert(welded == 1,
        "weldVertexPair basic: expected welded=1, got " ~ welded.to!string);
    // Exactly 1 vertex removed (not more — orphan removal must not over-count).
    assert(m.vertices.length == 7,
        "weldVertexPair basic: expected 7 vertices, got " ~ m.vertices.length.to!string);
    // Survivor position = keep's (1,0,0).
    bool foundKeep = false;
    foreach (v; m.vertices) {
        if (abs(v.x - 1.0f) < 1e-6f && abs(v.y) < 1e-6f && abs(v.z) < 1e-6f)
            foundKeep = true;
    }
    assert(foundKeep, "weldVertexPair basic: no vertex at keep position (1,0,0)");
    // No face may have a repeated vertex index.
    foreach (fi, face; m.faces) {
        foreach (ai; 0 .. face.length) {
            foreach (bi; ai + 1 .. face.length) {
                assert(face[ai] != face[bi],
                    "weldVertexPair basic: face " ~ fi.to!string
                    ~ " has repeated index " ~ face[ai].to!string);
            }
        }
    }
    // Both faces must still be present (neither collapses to < 3 verts).
    assert(m.faces.length == 2,
        "weldVertexPair basic: expected 2 faces, got " ~ m.faces.length.to!string);
}

unittest { // non-adjacent same-face guard: opposite quad corners → 0 (no-op)
    import std.conv : to;
    // Single quad [0,1,2,3]; weld opposite corners 0 and 2 → shared-face guard.
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,0,1)); m.addVertex(Vec3(0,0,1));
    m.addFace([0u,1u,2u,3u]);
    m.buildLoops();

    size_t vBefore = m.vertices.length;
    size_t fBefore = m.faces.length;
    size_t welded = m.weldVertexPair(0, 2);
    assert(welded == 0,
        "weldVertexPair shared-face: expected 0 (no-op), got " ~ welded.to!string);
    assert(m.vertices.length == vBefore,
        "weldVertexPair shared-face: vertices must not change");
    assert(m.faces.length == fBefore,
        "weldVertexPair shared-face: faces must not change");
}

unittest { // faceless guard: two isolated verts with no faces → 0 (no-op)
    import std.conv : to;
    Mesh m;
    m.addVertex(Vec3(0,0,0));
    m.addVertex(Vec3(0.001f,0,0));
    // No faces — both verts are unreferenced.
    size_t welded = m.weldVertexPair(0, 1);
    assert(welded == 0,
        "weldVertexPair faceless: expected 0 (no-op), got " ~ welded.to!string);
    assert(m.vertices.length == 2,
        "weldVertexPair faceless: must not remove vertices");
}

unittest { // adjacent same-face weld: edge collapse → succeeds, quad collapses to triangle
    import std.math : abs;
    import std.conv : to;
    // Single quad [0,1,2,3]; weld adjacent corners keep=0 and drop=1.
    // weldVerticesByMask remaps 1→0: face becomes [0,0,2,3]; the adjacent
    // duplicate is stripped → [0,2,3], a valid triangle.
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,0,1)); m.addVertex(Vec3(0,0,1));
    m.addFace([0u,1u,2u,3u]);
    m.buildLoops();

    size_t welded = m.weldVertexPair(0, 1);
    assert(welded == 1,
        "adjacent-weld: expected welded=1, got " ~ welded.to!string);
    // One vertex removed: 4 → 3.
    assert(m.vertices.length == 3,
        "adjacent-weld: expected 3 vertices, got " ~ m.vertices.length.to!string);
    // Quad collapses to a single triangle.
    assert(m.faces.length == 1,
        "adjacent-weld: expected 1 face, got " ~ m.faces.length.to!string);
    assert(m.faces[0].length == 3,
        "adjacent-weld: face must be a triangle, got length "
        ~ m.faces[0].length.to!string);
    // No repeated index in the resulting face.
    foreach (ai; 0 .. m.faces[0].length)
        foreach (bi; ai + 1 .. m.faces[0].length)
            assert(m.faces[0][ai] != m.faces[0][bi],
                "adjacent-weld: face has repeated vertex index at "
                ~ ai.to!string ~ " and " ~ bi.to!string);
    // Survivor position = keep (0,0,0); drop's original (1,0,0) must be absent.
    bool foundKeep = false, foundDrop = false;
    foreach (v; m.vertices) {
        if (abs(v.x) < 1e-6f && abs(v.y) < 1e-6f && abs(v.z) < 1e-6f) foundKeep = true;
        if (abs(v.x - 1.0f) < 1e-6f && abs(v.y) < 1e-6f && abs(v.z) < 1e-6f) foundDrop = true;
    }
    assert(foundKeep, "adjacent-weld: survivor position (0,0,0) missing");
    assert(!foundDrop, "adjacent-weld: drop position (1,0,0) must be absent after weld");
}

unittest { // a pair spanning two DISJOINT faces welds — the adjacency rule is
           // about corners of ONE face and must not leak across the sweep
    import std.conv : to;
    // Two quads that share nothing. The keep sits at corner 0 of the first,
    // the drop at corner 2 of the second: a distance of 2, which is neither
    // adjacent nor the head/tail wrap. If the face sweep's scratch survives
    // from one face into the next, the second face reads the keep's position
    // in the FIRST one, computes that distance, and refuses a pair that shares
    // no face at all. Positions chosen for exactly that reason.
    Mesh m;
    m.addVertex(Vec3(0, 0, 0)); m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 0, 1)); m.addVertex(Vec3(0, 0, 1));
    m.addVertex(Vec3(3, 0, 0)); m.addVertex(Vec3(4, 0, 0));
    m.addVertex(Vec3(4, 0, 1)); m.addVertex(Vec3(3, 0, 1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.rebuildEdges();
    m.buildLoops();

    uint[2][] pairs = [[0u, 6u]];   // keep at corner 0 of face 0, drop at corner 2 of face 1
    assert(m.weldVertexPairs(pairs) == 1,
        "a pair whose two ends live in DIFFERENT faces shares no winding and must weld");
    assert(m.vertices.length == 7,
        "cross-face weld: expected V=7, got " ~ m.vertices.length.to!string);
    assert(m.faces.length == 2,
        "cross-face weld: both quads survive, got F=" ~ m.faces.length.to!string);
    foreach (i, ref f; m.faces)
        assert(f.length == 4,
            "cross-face weld: face " ~ i.to!string ~ " must still be a quad, got length "
            ~ f.length.to!string);
}

unittest { // two faceless vertices cannot weld — that is a vanish, not a weld
    import std.conv : to;
    Mesh m;
    m.addVertex(Vec3(0, 0, 0)); m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 0, 1)); m.addVertex(Vec3(0, 0, 1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.addVertex(Vec3(5, 0, 0));      // 4 — isolated
    m.addVertex(Vec3(5.001f, 0, 0)); // 5 — isolated
    m.rebuildEdges();
    m.buildLoops();

    uint[2][] pairs = [[4u, 5u]];
    assert(m.weldVertexPairs(pairs) == 0,
        "a pair with no incident face anywhere must be refused");
    assert(m.vertices.length == 6,
        "faceless reject: BOTH isolated vertices must survive — honouring the pair would "
        ~ "have run the rebuild, and compactUnreferenced would then have taken them both; "
        ~ "got V=" ~ m.vertices.length.to!string);
}

unittest { // weldVerticesByMask average flag: survivor at cluster centroid
    import std.math : abs;
    import std.conv : to;
    // Two nearby verts (0.4,-0.5,-0.5) & (0.5,-0.5,-0.5) plus two far corners
    // form a quad; welding the pair (dist 0.2 → epsSq 0.04, gap² 0.01) collapses
    // the quad to a triangle whose surviving corner is the merged vertex.
    Mesh makeQuad() {
        Mesh m;
        m.addVertex(Vec3(0.4f, -0.5f, -0.5f));  // v0  (mask)
        m.addVertex(Vec3(0.5f, -0.5f, -0.5f));  // v1  (mask)
        m.addVertex(Vec3(0.5f,  0.5f, -0.5f));  // v2
        m.addVertex(Vec3(0.4f,  0.5f, -0.5f));  // v3
        m.addFace([0u, 1u, 2u, 3u]);
        m.buildLoops();
        return m;
    }
    bool[] mask = [true, true, false, false];
    double epsSq = 0.2 * 0.2;

    // average:true — survivor lands at the pair's centroid x = 0.45.
    Mesh ma = makeQuad();
    assert(ma.weldVerticesByMask(mask, epsSq, true) == 1,
        "average-weld: expected 1 weld");
    float sx = float.nan;
    foreach (v; ma.vertices)
        if (abs(v.y + 0.5f) < 1e-4f && abs(v.z + 0.5f) < 1e-4f) sx = v.x;
    assert(abs(sx - 0.45f) < 1e-4f,
        "average-weld: survivor x expected 0.45, got " ~ sx.to!string);

    // Default (average omitted) keeps merge-to-first: survivor stays at 0.4.
    Mesh md = makeQuad();
    assert(md.weldVerticesByMask(mask, epsSq) == 1, "first-weld: expected 1 weld");
    float dx = float.nan;
    foreach (v; md.vertices)
        if (abs(v.y + 0.5f) < 1e-4f && abs(v.z + 0.5f) < 1e-4f) dx = v.x;
    assert(abs(dx - 0.4f) < 1e-4f,
        "first-weld: survivor x expected 0.4 (lowest-index), got " ~ dx.to!string);
}

unittest { // buildEdgeFaces: all-faces, masked, and faceLimit prefix +
           // open-edge-shared-with-a-face-beyond-the-limit correctness
    import std.conv : to;

    // Three quads: FaceA and FaceC share edge (1,2); FaceB (between them in
    // face-index order) is a disjoint quad that touches neither vertex.
    //   FaceA (idx0): [0,1,2,3]
    //   FaceB (idx1): [4,5,6,7]   -- unrelated filler
    //   FaceC (idx2): [2,1,8,9]   -- shares edge (1,2) with FaceA
    Mesh m;
    foreach (i; 0 .. 10) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.addFace([2u, 1u, 8u, 9u]);
    m.buildLoops();

    ulong keyAC = edgeKey(1, 2);

    // (1) All-faces (default): edge(1,2) sees BOTH FaceA(0) and FaceC(2) → interior.
    auto allEf = m.buildEdgeFaces();
    auto pAll = keyAC in allEf;
    assert(pAll !is null, "buildEdgeFaces all-faces: edge(1,2) missing");
    assert((*pAll)[0] == 0 && (*pAll)[1] == 2,
        "buildEdgeFaces all-faces: edge(1,2) expected faces [0,2], got ["
        ~ (*pAll)[0].to!string ~ "," ~ (*pAll)[1].to!string ~ "]");
    // Total distinct edges: FaceA(4) + FaceB(4) + FaceC(3 new, edge(1,2) shared) = 11.
    assert(allEf.length == 11,
        "buildEdgeFaces all-faces: expected 11 distinct edges, got "
        ~ allEf.length.to!string);

    // (2) Masked: exclude FaceC (idx2) → edge(1,2) only sees FaceA → open.
    bool[] maskNoC = [true, true, false];
    auto maskedEf = m.buildEdgeFaces(maskNoC);
    auto pMasked = keyAC in maskedEf;
    assert(pMasked !is null, "buildEdgeFaces masked: edge(1,2) missing");
    assert((*pMasked)[0] == 0 && (*pMasked)[1] == -1,
        "buildEdgeFaces masked (FaceC excluded): edge(1,2) expected open [0,-1], got ["
        ~ (*pMasked)[0].to!string ~ "," ~ (*pMasked)[1].to!string ~ "]");

    // (3) faceLimit prefix: consider only faces [0,2) (A, B) — FaceC (idx2) is
    // BEYOND the limit, so edge(1,2) must stay open WITHIN THE PREFIX. This is
    // exactly the boundaryLoops correctness case the plan called out: an edge
    // open within [0,nf) that is also shared with a face >= nf must NOT be
    // wrongly marked interior by an unbounded (or null-mask "all faces") build.
    auto prefixEf = m.buildEdgeFaces(null, 2);
    auto pPrefix = keyAC in prefixEf;
    assert(pPrefix !is null, "buildEdgeFaces faceLimit=2: edge(1,2) missing");
    assert((*pPrefix)[0] == 0 && (*pPrefix)[1] == -1,
        "buildEdgeFaces faceLimit=2: edge(1,2) must stay open (face 2 excluded "
        ~ "by the prefix), got [" ~ (*pPrefix)[0].to!string ~ ","
        ~ (*pPrefix)[1].to!string ~ "]");
    // The prefix build must not see FaceC's own edges at all (e.g. edge (8,9)).
    ulong keyC89 = edgeKey(8, 9);
    assert((keyC89 in prefixEf) is null,
        "buildEdgeFaces faceLimit=2: FaceC-only edge (8,9) must be absent "
        ~ "from the prefix build");
    // Prefix distinct-edge count: FaceA(4) + FaceB(4) = 8 (FaceC excluded entirely).
    assert(prefixEf.length == 8,
        "buildEdgeFaces faceLimit=2: expected 8 distinct edges, got "
        ~ prefixEf.length.to!string);
}

unittest { // mirrorFacesPlane: tilted 45° plane — reflected positions match
           // the general reflection formula directly (independent check of
           // the same math the implementation uses, on a non-axis-aligned
           // normal), and each cloned face's normal is the REFLECTION of its
           // source face's normal across the plane (with the extra winding-
           // flip negation) — proves the winding-reversal pass stays correct
           // for an arbitrary plane, not just "points away from center".
    import std.conv : to;

    auto m = makeCube();               // 8 verts, 6 faces
    bool[] mask = new bool[](m.faces.length);
    mask[] = true;                     // whole-mesh mirror

    Vec3 center = Vec3(0, 0, 0);
    // Unit normal at 45° between +X and +Z (NOT axis-aligned).
    Vec3 normal = normalize(Vec3(1, 0, 1));

    size_t origVertCount = m.vertices.length;
    size_t origFaceCount = m.faces.length;
    size_t inserted = m.mirrorFacesPlane(mask, center, normal, 0.0f, true);
    assert(inserted == origFaceCount, "mirrorFacesPlane: expected " ~
        origFaceCount.to!string ~ " new faces, got " ~ inserted.to!string);
    assert(m.faces.length == origFaceCount * 2,
        "mirrorFacesPlane: face count must double");

    // (a) Every cloned vert equals the general reflection formula applied
    // to its ORIGINAL position (verts 0..7 map to cloned 8..15 — whole-mesh
    // mirror with no pre-existing coincidences clones each vert exactly once
    // and appends in traversal order, so index i+8 corresponds to source i;
    // proved structurally by comparing SETS below instead of relying on
    // that order).
    bool[] matched = new bool[](origVertCount);
    foreach (i; 0 .. origVertCount) {
        Vec3 orig = m.vertices[i];
        float d = dot(orig - center, normal);
        Vec3 expectedReflected = orig - normal * (2.0f * d);
        bool found = false;
        foreach (j; origVertCount .. m.vertices.length) {
            Vec3 c = m.vertices[j];
            if ((c - expectedReflected).length < 1e-4f) { found = true; break; }
        }
        assert(found, "mirrorFacesPlane: no cloned vert matches the "
            ~ "reflection of original vert " ~ i.to!string);
    }

    // (b) Winding inversion is plane-independent: for a REFLECTION (an
    // orientation-reversing linear map, det = -1), reflecting a face's
    // vertices while keeping the SAME winding order yields normal
    // -R(srcNormal) (the standard A(u)×A(v) = det(A)·A(u×v) identity for an
    // orthogonal A). Reversing the winding order (flipNormals) negates the
    // normal again, so the net result is exactly R(srcNormal) — the plain
    // reflection of the source normal, no extra sign flip. This is the
    // "outward-facing" invariant flipNormals is meant to produce, verified
    // directly (not the weaker "points away from center" check) so the
    // proof holds for any plane orientation, not just axis-aligned ones.
    foreach (fi; 0 .. origFaceCount) {
        Vec3 srcN = m.faceNormal(cast(uint)fi);
        float dn = dot(srcN, normal);
        Vec3 expectedClonedN = srcN - normal * (2.0f * dn);
        Vec3 clonedN = m.faceNormal(cast(uint)(origFaceCount + fi));
        assert((clonedN - expectedClonedN).length < 1e-3f,
            "mirrorFacesPlane: cloned face " ~ fi.to!string ~ " normal does "
            ~ "not match the reflected source normal (flipNormals must "
            ~ "reproduce R(srcNormal), not its negation)");
    }
}

unittest { // KILLER-1 RED/GREEN witness: a vertex on a bare (face-less) edge
           // classifies as degree-1 via edgeNeighbors, NOT degree-0 as the
           // loop-fan helpers (vertexValence/edgesAroundVertex) would report.
    Mesh m;
    m.addVertex(Vec3(0,0,0));   // 0 — carries a bare edge, no face at all
    m.addVertex(Vec3(1,0,0));   // 1
    m.addEdge(0, 1);
    m.buildLoops();

    // RED-witness precondition: the loop-fan helper is blind to a bare edge
    // (vertLoop is seeded ONLY from face corners in buildLoops) — this
    // documents the exact blind spot edgeNeighbors exists to fix, so a
    // regression that made vertexValence "just see it too" would be a sign
    // this witness needs re-checking, not silently pass either way.
    assert(m.vertexValence(0) == 0,
        "loop-fan vertexValence must NOT see the bare edge (documents the "
        ~ "blind spot edgeNeighbors below fixes)");

    // GREEN: the raw edges[] scan sees it correctly.
    auto en = m.edgeNeighbors(0);
    assert(en.length == 1, "edgeNeighbors must report exactly 1 neighbor for a bare-edge vertex");
    assert(en[0] == 1, "edgeNeighbors must report vertex 1 as 0's neighbor");
    assert(m.edgeNeighbors(1).length == 1 && m.edgeNeighbors(1)[0] == 0,
        "edgeNeighbors must be symmetric for the same bare edge");
}

unittest { // KILLER-2 witness: deleteFacesByMask(keepOrphans:true,
           // keepFloatingEdges:true) keeps EVERY former edge of the deleted
           // face (now bordering no face) AND an unrelated floating edge
           // elsewhere in the mesh, untouched.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(5,5,5), Vec3(6,5,5)];
    m.addFace([0u, 1u, 2u]);   // the face to delete
    m.addEdge(3, 4);           // an UNRELATED floating edge elsewhere
    m.buildLoops();

    assert(m.edgeIndex(0,1) != ~0u && m.edgeIndex(1,2) != ~0u && m.edgeIndex(0,2) != ~0u);
    assert(m.edgeIndex(3,4) != ~0u);
    assert(m.edges.length == 4);

    bool[] mask = new bool[](m.faces.length);
    mask[0] = true;
    size_t removed = m.deleteFacesByMask(mask, /*keepOrphans*/true, /*keepFloatingEdges*/true);
    assert(removed == 1);
    assert(m.faces.length == 0, "the triangle face must be gone");

    // Every one of the triangle's 3 edges — now bordering NO face — must
    // survive as a floating orphan, exactly like the unrelated edge.
    assert(m.edgeIndex(0,1) != ~0u, "former triangle edge (0,1) must survive");
    assert(m.edgeIndex(1,2) != ~0u, "former triangle edge (1,2) must survive");
    assert(m.edgeIndex(0,2) != ~0u, "former triangle edge (0,2) must survive");
    assert(m.edgeIndex(3,4) != ~0u, "unrelated floating edge must survive untouched");
    assert(m.edges.length == 4, "no edge must be lost mesh-wide (would happen "
        ~ "under the OLD unconditional rebuildEdges())");
    assert(m.vertices.length == 5, "keepOrphans must leave every vertex in place");
}

unittest { // KILLER-2 end-to-end: reproduces the SESSION-3 CASE-QUAD dump
           // bit-for-bit — triangle [0,5,4] (edges (0,4),(0,5),(4,5)) spliced
           // into quad [5,0,4,6], the old (4,5) edge surviving as a
           // non-bounding orphan diagonal.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),   // 0
        Vec3(9,9,9),   // 1 (unused filler, keeps indices matching the capture)
        Vec3(9,9,9),   // 2
        Vec3(9,9,9),   // 3
        Vec3(1,0,0),   // 4
        Vec3(0,1,0),   // 5
        Vec3(1,1,0),   // 6
    ];

    int triFi = m.makePolygonFromVerts([0u, 5u, 4u], false);
    assert(triFi == 0, "seed triangle must build");
    assert(m.faces[triFi] == [0u, 5u, 4u]);
    assert(m.edges.length == 3);
    assert(m.edgeIndex(0,4) != ~0u && m.edgeIndex(0,5) != ~0u && m.edgeIndex(4,5) != ~0u);

    // Delete the triangle, keeping BOTH the orphan verts and every edge —
    // the ONLY way to remove a face without a rebuildEdges (plan's load
    // -bearing rule).
    bool[] mask = new bool[](m.faces.length);
    mask[triFi] = true;
    size_t removed = m.deleteFacesByMask(mask, /*keepOrphans*/true, /*keepFloatingEdges*/true);
    assert(removed == 1);
    assert(m.faces.length == 0);
    assert(m.edges.length == 3, "all 3 former triangle edges must survive as orphans");

    // Splice the quad in the prescribed verbatim construction order —
    // winding is a fixed convention, not adjacency-derived (autoOrient:false).
    int quadFi = m.makePolygonFromVerts([5u, 0u, 4u, 6u], false, /*autoOrient*/false);
    assert(quadFi == 0, "quad must build");
    assert(m.faces[quadFi] == [5u, 0u, 4u, 6u],
        "quad winding must be emitted VERBATIM in construction order");

    // Exact SESSION-3 edge-set match: (0,4),(0,5),(4,5),(4,6),(5,6) — 5 edges,
    // the old (4,5) diagonal now bounding NO face.
    assert(m.edges.length == 5, "expected 5 edges total (3 old + 2 new)");
    assert(m.edgeIndex(0,4) != ~0u);
    assert(m.edgeIndex(0,5) != ~0u);
    assert(m.edgeIndex(4,5) != ~0u, "the old diagonal must survive, unbounded by any face");
    assert(m.edgeIndex(4,6) != ~0u, "new boundary edge (4,6)");
    assert(m.edgeIndex(5,6) != ~0u, "new boundary edge (5,6)");

    auto ef = m.buildEdgeFaces();
    assert((edgeKey(4, 5) in ef) is null,
        "diagonal (4,5) must border zero faces post-splice");
}

unittest { // makePolygonFromVerts(autoOrient:false) — the winding bypass
           // emits the caller's index order VERBATIM (no majority-vote
           // reversal against an existing same-direction neighbor), while
           // every other guard (degenerate, duplicate-face) still runs.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),   // 0
        Vec3(1,0,0),   // 1
        Vec3(1,1,0),   // 2
        Vec3(0,1,0),   // 3
        Vec3(1,0,-1),  // 4
        Vec3(0,0,-1),  // 5
        Vec3(2,0,0),   // 6 — collinear with 0,1 for the degenerate-guard check
    ];

    // fi0 traverses shared edge (0,1) in the 0->1 direction.
    int fi0 = m.makePolygonFromVerts([0u, 1u, 2u, 3u], false);
    assert(fi0 == 0);

    // fi1 ALSO traverses (0,1) in the SAME 0->1 direction — a same-direction
    // share the default autoOrient:true path would flip (task 0394
    // majority-vote). autoOrient:false must NOT flip it.
    int fi1 = m.makePolygonFromVerts([0u, 1u, 4u, 5u], false, /*autoOrient*/false);
    assert(fi1 != -1, "must still build despite the bypass");
    assert(m.faces[fi1] == [0u, 1u, 4u, 5u],
        "autoOrient:false must emit the caller's order verbatim, even where "
        ~ "the default auto-orient would reverse it");

    // Control: the IDENTICAL index order and same-direction share, under the
    // DEFAULT (autoOrient:true) path, DOES get reversed — proves the two
    // modes genuinely differ, not just that the bypass never fires.
    Mesh m2;
    m2.vertices = m.vertices.dup;
    m2.makePolygonFromVerts([0u, 1u, 2u, 3u], false);
    int fi1Default = m2.makePolygonFromVerts([0u, 1u, 4u, 5u], false);
    assert(fi1Default != -1);
    assert(m2.faces[fi1Default] != [0u, 1u, 4u, 5u],
        "control: the default (autoOrient:true) path DOES reverse a "
        ~ "same-direction shared edge — otherwise this witness proves nothing");

    // The bypass must not defeat any other guard.
    assert(m.makePolygonFromVerts([0u, 1u], false, false) == -1,
        "<3 verts must still reject with autoOrient:false");
    assert(m.makePolygonFromVerts([0u, 0u, 0u], false, false) == -1,
        "all-same verts must still reject with autoOrient:false");
    assert(m.makePolygonFromVerts([0u, 1u, 6u], false, false) == -1,
        "collinear must still reject with autoOrient:false");
    assert(m.makePolygonFromVerts([0u, 1u, 2u, 3u], false, false) == -1,
        "duplicate face (same unordered vertex set as fi0) must still reject "
        ~ "with autoOrient:false");
}

// ---------------------------------------------------------------------------
// Task 1200 — `MakePolyGates`: each of the four refusals can be switched OFF
// INDEPENDENTLY, and the default is still every one of them ON.
//
// This is the kernel half of ledger row 7. The command half (`mesh.makePolygon`
// asking for `none`, and agreeing with the reference cell for cell) is
// tests/test_make_polygon.d and tests/fixtures/make_polygon_gates.json.
//
// Testing each flag ALONE is the point. `gates: none` on its own would pass
// even if the four refusals had been collapsed into one switch, and then the
// Topology Pen — which asks for the default and relies on the zero-area
// refusal specifically — would have no test standing between it and a later
// "simplification" of the flag into a bool.
// ---------------------------------------------------------------------------
unittest {
    // Four coplanar points, plus three collinear ones on the X axis.
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1),
                  Vec3(2, 0, 0), Vec3(3, 0, 0)];
    m.buildLoops();

    alias G = Mesh.MakePolyGates;

    // --- the degenerate gate, alone ---------------------------------------
    assert(m.makePolygonFromVerts([0u, 1u, 4u], false, true, G.all) == -1,
        "collinear must reject under the default gates");
    assert(m.makePolygonFromVerts([0u, 1u, 4u], false, true,
                                  G.duplicate | G.manifold) >= 0,
        "collinear must BUILD once the degenerate gate alone is off");
    assert(m.faces.length == 1 && m.faces[0].length == 3,
        "the zero-area triangle is a real face with three corners");

    // Two corners: refused by the same gate, through the ARITY floor rather
    // than through Newell's normal — and the floor moves with the flag.
    assert(m.makePolygonFromVerts([2u, 3u], false, true, G.all) == -1,
        "a 2-corner ring must reject under the default gates");
    immutable int twoFi = m.makePolygonFromVerts([2u, 3u], false, true, G.none);
    assert(twoFi >= 0, "a 2-corner ring must build with the gates off");
    assert(m.faces[twoFi].length == 2, "and it must keep BOTH corners, not be padded");
    // The floor itself does not move: one corner is refused however the flag
    // reads. Two is the smallest ring the reference was measured to build.
    assert(m.makePolygonFromVerts([5u], false, true, G.none) == -1,
        "one corner is refused whatever `gates` says — the floor is not a gate");
    assert(m.makePolygonFromVerts([], false, true, G.none) == -1,
        "and so is an empty ring");

    // --- the duplicate gate, alone ----------------------------------------
    Mesh d;
    d.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1)];
    d.buildLoops();
    assert(d.makePolygonFromVerts([0u, 1u, 2u, 3u], false) >= 0, "seed quad");
    assert(d.makePolygonFromVerts([2u, 3u, 0u, 1u], false, true, G.all) == -1,
        "the same unordered vertex set must reject under the default gates");
    assert(d.makePolygonFromVerts([2u, 3u, 0u, 1u], false, true,
                                  G.degenerate | G.manifold) >= 0,
        "and must build once the duplicate gate alone is off");
    assert(d.faces.length == 2, "two faces now stand on the same four corners");
    assert(d.edges.length == 4, "and the duplicate adds no edge at all");

    // --- the manifold gate, alone -----------------------------------------
    // Two quads of a plate share edge 1-4; a third face on that edge would
    // push it to three.
    Mesh n;
    n.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0),
                  Vec3(0, 0, 1), Vec3(1, 0, 1), Vec3(2, 0, 1),
                  Vec3(1, 1, 0.5f)];
    n.faces = [[0u, 1u, 4u, 3u], [1u, 2u, 5u, 4u]];
    n.rebuildEdgesFromFaces();
    n.buildLoops();
    assert(n.edgeFaceUseCounts()[n.edgeIndex(1, 4)] == 2,
        "fixture: edge 1-4 starts saturated");
    assert(n.makePolygonFromVerts([1u, 4u, 6u], false, true, G.all) == -1,
        "a third face on a saturated edge must reject under the default gates");
    assert(n.makePolygonFromVerts([1u, 4u, 6u], false, true,
                                  G.degenerate | G.duplicate) >= 0,
        "and must build once the manifold gate alone is off");
    assert(n.edgeFaceUseCounts()[n.edgeIndex(1, 4)] == 3,
        "edge 1-4 now carries THREE faces — the non-manifold state the owner "
        ~ "chose to allow (ledger row 7, duplicate_over_existing_face)");
}

// ---------------------------------------------------------------------------
// consumedFanVertexMask / removeEdgesByMask(mask, keepConsumedVerts) — task
// 0494, the recovered "a vertex disappears iff its WHOLE polygon fan was
// consumed" purge rule.
//
// The fixture is `makeGridPlane(3)` — a 4x4 planar grid, 16v/24e/9f, vertex
// index 4*row + col, one quad per cell — which is exactly the rig the
// behaviour was captured on, so the numbers below are comparable to the
// capture row by row.
//
// READ THIS BEFORE TOUCHING THESE TESTS: on a plain quad grid dissolving a
// whole edge loop, the fan rule and this file's OTHER cleanup pass
// (`dissolveDegree2Verts`, a VALENCE rule) predict the identical post-mesh. A
// green loop test therefore proves nothing about which of the two is
// implemented, which is why the fourth block below is a two-armed witness on a
// CONSTRUCTED mask where they disagree — delete that block and the rest of
// this file no longer pins the rule at all.
// ---------------------------------------------------------------------------
unittest { // single interior edge: the purge RUNS and deletes NOTHING
    Mesh m = makeGridPlane(3);
    assert(m.vertices.length == 16 && m.edges.length == 24 && m.faces.length == 9,
        "setup: makeGridPlane(3) must be the 4x4 grid the capture used");

    auto mask = new bool[](m.edges.length);
    mask[m.edgeIndex(5, 9)] = true;

    // Vertices 5 and 9 each carry a fan of FOUR quads of which the dissolve
    // consumes TWO — partial fans, so nothing is purged even with the purge
    // enabled. This is the cheap regression anchor for the rule: a valence
    // test would be equally quiet here, but a "drop every touched endpoint"
    // implementation would wrongly take both.
    foreach (i, c; m.consumedFanVertexMask(mask))
        assert(!c, "a partially consumed fan must never be purged");

    assert(m.removeEdgesByMask(mask, /*keepConsumedVerts*/false) == 1);
    assert(m.vertices.length == 16 && m.edges.length == 23 && m.faces.length == 8,
        "an interior edge dissolve merges its two quads into one hexagon and "
        ~ "loses nothing else");
    assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
}

unittest { // an edge LOOP, both ways round the keep-vertex flag
    // The vertical 3-edge run through the middle column of the grid.
    static bool[] loopMask(ref Mesh m) {
        auto mask = new bool[](m.edges.length);
        mask[m.edgeIndex(1, 5)]  = true;
        mask[m.edgeIndex(5, 9)]  = true;
        mask[m.edgeIndex(9, 13)] = true;
        return mask;
    }

    // KEEP the consumed vertices: the merged hexagons carry them as corners.
    {
        Mesh m = makeGridPlane(3);
        assert(m.removeEdgesByMask(loopMask(m)) == 3);
        assert(m.vertices.length == 16 && m.edges.length == 21 && m.faces.length == 6);
        assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
    }

    // DROP them (the reference default): each hexagon collapses back to a
    // quad, and the four re-stitching edges appear.
    {
        Mesh m = makeGridPlane(3);
        auto pre  = m.vertices.dup;
        auto mask = loopMask(m);

        auto consumed = m.consumedFanVertexMask(mask);
        uint[] taken;
        foreach (i, c; consumed) if (c) taken ~= cast(uint)i;
        assert(taken == [1u, 5u, 9u, 13u],
            "exactly the loop's own endpoints, whose fans the dissolve eats whole "
            ~ "— NOT vertex 4, whose fan is also eaten but which is nobody's "
            ~ "dissolving endpoint");

        assert(m.removeEdgesByMask(mask, /*keepConsumedVerts*/false) == 3);
        assert(m.vertices.length == 12 && m.edges.length == 17 && m.faces.length == 6,
            "dropping the four consumed vertices re-stitches the survivors");
        assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");

        // Positions, not indices: the dissolve reindexes.
        int idxOf(Vec3 p) {
            foreach (i, ref v; m.vertices)
                if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
            return -1;
        }
        foreach (gone; [1, 5, 9, 13])
            assert(idxOf(pre[gone]) < 0, "a consumed vertex must be gone");
        foreach (pair; [[0, 2], [4, 6], [8, 10], [12, 14]]) {
            immutable int a = idxOf(pre[pair[0]]), b = idxOf(pre[pair[1]]);
            assert(a >= 0 && b >= 0 && m.edgeIndex(cast(uint)a, cast(uint)b) != ~0u,
                "the survivors must be re-stitched across the gap");
        }
    }
}

unittest { // a BORDER edge in the mask neither dissolves nor nominates anything
    Mesh m = makeGridPlane(3);
    auto mask = new bool[](m.edges.length);
    mask[m.edgeIndex(0, 1)] = true;   // top-left border edge, ONE incident quad

    foreach (c; m.consumedFanVertexMask(mask))
        assert(!c, "a one-polygon edge cannot consume a fan");
    assert(m.removeEdgesByMask(mask, /*keepConsumedVerts*/false) == 0);
    assert(m.vertices.length == 16 && m.edges.length == 24 && m.faces.length == 9,
        "border seed must be a total no-op");
}

unittest { // THE KERNEL TRAP, both arms — "whole fan consumed" is NOT "2-valent"
    // Two dissolving edges meeting at interior vertex 5, whose fourth quad
    // [5,6,10,9] is NOT consumed. The fan rule spares 5; the valence rule
    // takes it (after the dissolve 5 has exactly two edges left) and mangles
    // that surviving quad into a triangle.
    static bool[] trapMask(ref Mesh m) {
        auto mask = new bool[](m.edges.length);
        mask[m.edgeIndex(1, 5)] = true;
        mask[m.edgeIndex(4, 5)] = true;
        return mask;
    }
    static int idxOf(ref Mesh m, Vec3 p) {
        foreach (i, ref v; m.vertices)
            if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
        return -1;
    }

    // Arm 1 — the implemented rule.
    {
        Mesh m = makeGridPlane(3);
        auto pre = m.vertices.dup;

        uint[] taken;
        foreach (i, c; m.consumedFanVertexMask(trapMask(m))) if (c) taken ~= cast(uint)i;
        assert(taken == [1u, 4u],
            "only the endpoints whose fan is eaten WHOLE — vertex 5 keeps one quad");

        assert(m.removeEdgesByMask(trapMask(m), /*keepConsumedVerts*/false) == 2);
        assert(m.vertices.length == 14 && m.edges.length == 20 && m.faces.length == 7);
        assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
        assert(idxOf(m, pre[5]) >= 0, "vertex 5 must SURVIVE — its fan was not eaten");
        assert(idxOf(m, pre[1]) < 0 && idxOf(m, pre[4]) < 0);
        foreach (ref f; m.faces)
            assert(f.length >= 4, "no surviving quad may be reduced to a triangle");
    }

    // Arm 2 — the valence rule on the SAME input, to prove the two genuinely
    // disagree here rather than that the first arm merely passed.
    {
        Mesh m = makeGridPlane(3);
        auto pre = m.vertices.dup;
        assert(m.removeEdgesByMask(trapMask(m)) == 2);
        m.dissolveDegree2Verts(m.edgeDeleteRegion(), /*keepOrphans*/true);
        assert(m.vertices.length == 13 && m.edges.length == 19 && m.faces.length == 7,
            "control: the valence rule takes one vertex more");
        assert(idxOf(m, pre[5]) < 0, "control: the valence rule DELETES vertex 5");
        bool anyTri = false;
        foreach (ref f; m.faces) if (f.length == 3) anyTri = true;
        assert(anyTri, "control: and mangles the unconsumed quad into a triangle");
    }
}

unittest { // a WHOLE fan in the mask: the shared vertex goes, its neighbours
           // go, the untouched ring stays — and here the two rules COINCIDE,
           // recorded so nobody reads this block as a second discriminator.
    Mesh m = makeGridPlane(3);
    auto pre = m.vertices.dup;
    auto mask = new bool[](m.edges.length);
    foreach (pair; [[1, 5], [4, 5], [5, 6], [5, 9]])
        mask[m.edgeIndex(cast(uint)pair[0], cast(uint)pair[1])] = true;

    uint[] taken;
    foreach (i, c; m.consumedFanVertexMask(mask)) if (c) taken ~= cast(uint)i;
    assert(taken == [1u, 4u, 5u],
        "5 (whole fan), plus 1 and 4 whose two-quad fans are also eaten whole; "
        ~ "6 and 9 keep an outer quad each");

    assert(m.removeEdgesByMask(mask, /*keepConsumedVerts*/false) == 4);
    assert(m.vertices.length == 13 && m.edges.length == 18 && m.faces.length == 6);
    assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
    int idxOf(Vec3 p) {
        foreach (i, ref v; m.vertices)
            if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
        return -1;
    }
    assert(idxOf(pre[5]) < 0 && idxOf(pre[1]) < 0 && idxOf(pre[4]) < 0);
}

// ---------------------------------------------------------------------------
// Task 0502 — `edgePolygonCounts` sees a NON-MANIFOLD fan. Three quads share
// edge 0-1 here.
//
// This is the fixture that separates a real count from an undercount, and it
// is why every "how many polygons border this edge" test in the repo must run
// on it rather than on a grid (where the two agree).
//
// TASK 1290 CLOSED THE BLIND SPOT THIS BLOCK USED TO PIN. `facesAroundEdge`
// reported ONE face here — not three, and not even two — and the assertion
// below was written as `viaRings < 3` with an explicit instruction attached:
// "if the rings ever learn to enumerate a non-manifold fan, delete this line —
// but do NOT weaken edgePolygonCounts to match". They have, so it is replaced
// by the equality rather than deleted, and the counter is untouched: it is
// still the answer for a COUNT, still reads off `faces[]`, and still cannot
// undercount whatever the rings do.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(1,1,0),
                 Vec3(0,0,1), Vec3(1,0,1), Vec3(0,-1,0), Vec3(1,-1,0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 3u, 2u]);
    m.addFace([0u, 1u, 5u, 4u]);
    m.addFace([0u, 1u, 7u, 6u]);
    m.buildLoops();

    immutable uint shared_ = m.edgeIndex(0, 1);
    auto counts = m.edgePolygonCounts();
    assert(counts[shared_] == 3, "three quads border this edge, and the count says so");

    uint[] viaRings;
    foreach (fi; m.facesAroundEdge(shared_)) viaRings ~= fi;
    import std.algorithm : sort;
    auto ringSet = viaRings.dup;
    ringSet.sort();
    assert(ringSet == [0u, 1u, 2u],
        "task 1290: the rings enumerate the whole fan now — all three quads, "
      ~ "as a SET. This used to be `< 3` (the walk yielded one face) and the "
      ~ "old line carried the instruction that replaced it.");
    assert(viaRings.length == counts[shared_],
        "and the two answers agree on the number: the ring walk no longer "
      ~ "undercounts, and edgePolygonCounts was NOT weakened to meet it");

    // The other two answers the counter has to get right on the same mesh.
    assert(counts[m.edgeIndex(1, 3)] == 1, "a border edge of one quad");
    m.addVertex(Vec3(9, 9, 9));
    m.addVertex(Vec3(9, 9, 8));
    m.addEdge(8, 9);
    assert(m.edgePolygonCounts()[m.edgeIndex(8, 9)] == 0, "a bare wire edge borders nothing");
}

// Task 0694 — `edgePolygonCounts` has TWO arms (darts when the loops are
// valid, the hashed key table when they are not) and they must return the
// same array element for element. The fast arm is what a dissolve pays on a
// 200 000-edge cage, so a divergence here would be a silent topology answer,
// not a crash: a wire counted as bordered is geometry a dissolve then eats.
//
// `markDerivedEmpty` is the lever that forces the fallback: it flips the loop
// VALIDITY state without touching `faces`/`edges`, so both arms are asked the
// identical question about the identical mesh.
unittest {
    Mesh m;
    foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(1,1,0),
                 Vec3(0,0,1), Vec3(1,0,1), Vec3(0,-1,0), Vec3(1,-1,0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 3u, 2u]);      // quad
    m.addFace([0u, 1u, 5u, 4u]);      // second quad on edge 0-1
    m.addFace([0u, 1u, 7u, 6u]);      // third — a NON-MANIFOLD fan
    m.addFace([2u, 3u, 5u]);          // a triangle: mixed arity
    m.addVertex(Vec3(9, 9, 9));
    m.addVertex(Vec3(9, 9, 8));
    m.addEdge(8, 9);                  // a bare wire, bordered by nothing
    m.buildLoops();

    assert(m.loopsValid(), "setup: the dart arm is the one that answers first");
    auto viaDarts = m.edgePolygonCounts();
    m.markDerivedEmpty();
    assert(!m.loopsValid(), "setup: now the hashed arm answers");
    auto viaHash = m.edgePolygonCounts();
    assert(viaDarts == viaHash,
        "the dart tally and the hashed tally are the same count, per edge");
    // ...and the answers the counter has to get right are actually in there,
    // so the equality above cannot be satisfied by two empty arrays.
    assert(viaDarts[m.edgeIndex(0, 1)] == 3, "the fan is reported at its true size");
    assert(viaDarts[m.edgeIndex(1, 3)] == 1, "a border edge of one quad");
    assert(viaDarts[m.edgeIndex(8, 9)] == 0, "a bare wire borders nothing");

    // The `faceLoop.length == faces.length` half of the gate. `appendFaceRaw`
    // grows `faces[]` with NO version bump by design, so the stamp still reads
    // Valid while the darts no longer cover every face. The appended face
    // re-uses edges that already exist, so a dart arm taken in this window
    // would under-count them — the guard has to send this to the hashed arm.
    m.buildLoops();
    assert(m.loopsValid() && m.faceLoop.length == m.faces.length, "setup");
    auto before = m.edgePolygonCounts();
    m.appendFaceRaw([0u, 1u, 3u, 2u].dup);   // a duplicate of face 0
    assert(m.loopsValid(), "setup: appendFaceRaw deliberately does not bump");
    auto after = m.edgePolygonCounts();
    assert(after[m.edgeIndex(0, 1)] == before[m.edgeIndex(0, 1)] + 1,
        "the un-bumped appended face is counted — the dart arm must have "
      ~ "stood down (its darts do not cover that face)");
}

// ---------------------------------------------------------------------------
// Task 1061 — `vertexEdgeCounts` / `vertexPolygonCounts`: honest per-vertex
// counters for `select.byStat.vertex`'s edgeCount/polygonCount rows. Pinned
// on a closed cube, an open cube (the dump's own partition), a floating edge
// (the case that separates the honest scan from `vertexValence`'s fan walk),
// and a face repeating a vertex (the case that separates it from a raw
// per-corner tally).
// ---------------------------------------------------------------------------
unittest {   // closed cube: every vertex has 3 edges and 3 polygons.
    Mesh m = makeCube();
    auto ec = m.vertexEdgeCounts();
    auto pc = m.vertexPolygonCounts();
    assert(ec.length == 8 && pc.length == 8);
    foreach (i; 0 .. 8) {
        assert(ec[i] == 3, "cube vertex has 3 incident edges");
        assert(pc[i] == 3, "cube vertex has 3 incident polygons");
    }
}

unittest {   // open cube (+Y face removed): the dump's own partition --
             // every vertex keeps 3 edges, the top ring drops to 2 polygons,
             // the bottom ring stays at 3.
    Mesh m = makeCube();
    // +Y face is [3,7,6,2] in makeCube()'s face list (index 4).
    size_t topFace = size_t.max;
    foreach (fi, ref f; m.faces)
        if (f.length == 4 && f[0] == 3 && f[1] == 7 && f[2] == 6 && f[3] == 2)
            topFace = fi;
    assert(topFace != size_t.max, "setup: found the +Y face");
    m.faces = m.faces[0 .. topFace] ~ m.faces[topFace + 1 .. $];
    m.buildLoops();

    auto ec = m.vertexEdgeCounts();
    foreach (i; 0 .. 8)
        assert(ec[i] == 3, "deleting a face does not remove its shared edges");

    auto pc = m.vertexPolygonCounts();
    bool[uint] topRing = [3: true, 7: true, 6: true, 2: true];
    foreach (i; 0 .. 8) {
        if (cast(uint) i in topRing)
            assert(pc[i] == 2, "a vertex of the deleted face now borders 2 polygons");
        else
            assert(pc[i] == 3, "an untouched vertex still borders 3 polygons");
    }
}

unittest {   // a bare floating edge: `vertexEdgeCounts` must see it even
             // though it touches no face -- `vertexValence`'s fan walk
             // (seeded from vertLoop, populated only from face corners)
             // reads it as degree 0. This is the mutation-reddening case:
             // swapping vertexEdgeCounts for a vertexValence-based tally
             // turns this red.
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addEdge(0, 1);
    m.buildLoops();

    auto ec = m.vertexEdgeCounts();
    assert(ec[0] == 1 && ec[1] == 1,
        "a floating edge's endpoints must be counted, unlike vertexValence");
    assert(m.vertexValence(0) == 0 && m.vertexValence(1) == 0,
        "setup: the fan walk really does see this vertex as isolated");
}

unittest {   // a face listing the same vertex twice must count once, not
             // twice -- the last-face-stamp guard.
    Mesh m;
    foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)])
        m.addVertex(p);
    // Degenerate face: vertex 0 appears at two winding positions.
    // `vertexPolygonCounts` is a pure scan over `faces[]`, independent of
    // loop/dart validity, so no `buildLoops()` is needed to exercise it.
    m.appendFaceRaw([0u, 1u, 2u, 0u, 3u].dup);

    auto pc = m.vertexPolygonCounts();
    assert(pc[0] == 1, "vertex 0 appears twice in the face's winding but "
        ~ "borders it exactly once");
}

// ---------------------------------------------------------------------------
// TASK 0920 — `compactUnreferenced` builds a full old->new `remap` and
// permutes `vertices` by it, but used to leave `vertexMarks` /
// `vertexSelectionOrder` / every Point-domain MeshMap (vertex weight, vertex
// color) behind: the tail `resizeVertexSelection()` only grows/shrinks these
// arrays by LENGTH, it does not move a value between slots, so dropping a
// vertex out of the MIDDLE of the array left every survivor after it wearing
// the weight/selection-order stamp that used to sit at its NEW index, not its
// own. Its own inverse (`applyReindexForward`, mesh_edit_delta.d) already
// permutes `vertexMarks`/`vertexSelectionOrder` correctly for this exact
// compaction; this pins the forward kernel doing the same.
//
// Fixture measured by task 0831: 7 vertices — a triangle [0,1,2], a hanging
// (unreferenced) vertex 3 in the middle, a second triangle [4,5,6]. A weight
// map filled value == index. `compactUnreferenced` drops only v3, so v4..v6
// shift down to slots 3..5 while v0..v2 keep theirs — a MIDDLE drop, not a
// tail drop: on a tail drop, truncation and permutation agree and the test
// would prove nothing (the same "one dropped face" trap task 0703 hid behind).
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    foreach (i; 0 .. 7) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addFace([0u, 1u, 2u]);
    m.addFace([4u, 5u, 6u]);
    m.buildLoops();
    m.syncSelection();

    m.addWeightMap("w");
    foreach (i; 0 .. 7) m.setVertexWeight("w", i, cast(float)i);
    // A non-hidden vertex's manual selection-order stamp — the same
    // discriminator the mesh_edit_delta S3 test uses for
    // vertexSelectionOrder, exercised here on the FORWARD kernel instead of
    // its undo/redo inverse.
    m.vertexSelectionOrder[6] = 9;

    const removed = m.compactUnreferenced();
    assert(removed == 1, "setup: only the hanging vertex 3 is unreferenced");
    assert(m.vertices.length == 6);

    // Expected post-compaction order: old [0,1,2,4,5,6] -> new [0,1,2,3,4,5].
    static immutable int[6] oldOfNew = [0, 1, 2, 4, 5, 6];
    foreach (newIdx, oldIdx; oldOfNew)
        assert(m.vertexWeight("w", newIdx) == cast(float)oldIdx,
            format("compactUnreferenced: new slot %d must carry old v%d's own "
                 ~ "weight (%d), not a neighbour's truncated-from-the-tail "
                 ~ "value (got %s)", newIdx, oldIdx, oldIdx,
                 m.vertexWeight("w", newIdx)));

    assert(m.vertexSelectionOrder[5] == 9,
        "compactUnreferenced: old v6's selection-order stamp must land at "
      ~ "its new slot (5), not stay behind at its old slot (6) or truncate "
      ~ "away entirely");
}

// ---------------------------------------------------------------------------
// TASK 0921 — `applyVertexRemap` (the weld path's real face compaction) drops
// a face that degenerates below 3 corners after the merge and shifts every
// surviving face after it, but used to only TRUNCATE `faceMaterial` /
// `facePart` / Subpatch from the front instead of gathering them by the same
// `faceRemap` it already builds. The site's own per-corner (UV) relocation two
// lines above IS keyed by that remap correctly — this pins the four face
// planes doing the same.
//
// Fixture measured by task 0831: three triangles; the first has two
// coincident vertices (v2 == v0), so it degenerates to 2 distinct corners
// after weld and is DROPPED entirely — not from the tail (it is face 0 of
// 3), so a truncation and a correct gather disagree.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    // Face 0 -- degenerate: vertex 2 coincides with vertex 0.
    m.addVertex(Vec3(0, 0, 0));   // 0
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(0, 0, 0));   // 2 -- coincides with 0
    m.addFace([0u, 1u, 2u]);
    // Face 1 -- ordinary, spatially isolated from face 0's cluster.
    m.addVertex(Vec3(10, 0, 0));  // 3
    m.addVertex(Vec3(11, 0, 0));  // 4
    m.addVertex(Vec3(10, 1, 0));  // 5
    m.addFace([3u, 4u, 5u]);
    // Face 2 -- ordinary, spatially isolated from both.
    m.addVertex(Vec3(20, 0, 0));  // 6
    m.addVertex(Vec3(21, 0, 0));  // 7
    m.addVertex(Vec3(20, 1, 0));  // 8
    m.addFace([6u, 7u, 8u]);
    m.buildLoops();
    m.syncSelection();

    m.faceMaterial = [100u, 111u, 122u];
    m.facePart     = [10u, 11u, 12u];
    m.setFaceSubpatch(0, false);
    m.setFaceSubpatch(1, false);
    m.setFaceSubpatch(2, true);

    const welded = m.weldCoincidentVertices(1e-12);
    assert(welded == 1, "setup: exactly v2 welds onto v0");
    assert(m.faces.length == 2,
        "setup: face 0's two coincident corners collapse it below 3 distinct "
      ~ "corners, so weld must drop it entirely");

    assert(m.faceMaterial == [111u, 122u],
        format("applyVertexRemap: surviving faces must keep their OWN "
             ~ "material via faceRemap, not a front-truncated slice of the "
             ~ "original array (got %s)", m.faceMaterial));
    assert(m.facePart == [11u, 12u],
        format("applyVertexRemap: surviving faces must keep their OWN part "
             ~ "id via faceRemap (got %s)", m.facePart));
    assert(!m.isFaceSubpatch(0),
        "surviving new face 0 (old face 1) must not inherit a Subpatch bit "
      ~ "it never had");
    assert(m.isFaceSubpatch(1),
        "surviving new face 1 (old face 2) must keep its OWN Subpatch bit, "
      ~ "not lose it to front-truncation");
}

// Task 1054 U1 — `selectedFaceIndicesInSelectionOrder` (Phase 1, doc/
// loop_slice_corner_plan.md §5/§6): click order preserved; 0-stamp faces
// sort last with ties ascending; survives a short `faceSelectionOrder`
// (R4, `resizeFaceSelection` deliberately does not resize it — mesh.d
// :5773-5778); a stale non-zero stamp on an unselected face is ignored.
unittest {
    // Click order preserved -- NOT ascending index order.
    {
        Mesh m = makeCube();
        m.resetSelection();
        m.selectFace(2);
        m.selectFace(0);
        m.selectFace(1);
        assert(m.selectedFaceIndicesInSelectionOrder() == [2u, 0u, 1u],
            format("click order must be preserved, got %s",
                   m.selectedFaceIndicesInSelectionOrder()));
    }

    // A ranked (individually-clicked) face sorts before every 0-stamp
    // (bulk-selected, never individually ranked) face; the 0-stamp faces
    // tie and fall back to ascending index among themselves.
    {
        Mesh m = makeCube();
        m.resetSelection();
        bool[] fsel; fsel.length = m.faces.length;
        fsel[3] = true; fsel[1] = true;   // bulk select: no per-element rank
        m.setFacesSelectedFrom(fsel);
        m.selectFace(4);                  // ranked select, after the bulk one
        assert(m.selectedFaceIndicesInSelectionOrder() == [4u, 1u, 3u],
            format("ranked face first, zero-stamped faces tie ascending, got %s",
                   m.selectedFaceIndicesInSelectionOrder()));
    }

    // Mutation-style check: dropping the sort (returning ascending order
    // instead) would read as [1,3,4] above and this assert would catch it --
    // covered by the assert already; no separate block needed.

    // Survives a `faceSelectionOrder` shorter than `faces` (R4) without a
    // RangeError -- reproduces the shape `resizeFaceSelection` leaves behind
    // (faceMarks grows, faceSelectionOrder does not) directly, rather than
    // depending on any one mutator's internals to produce it.
    {
        Mesh m = makeCube();
        m.resetSelection();
        m.selectFace(0);
        m.selectFace(5);
        assert(m.faceSelectionOrder.length == m.faces.length);
        m.faceSelectionOrder = m.faceSelectionOrder[0 .. 3];   // now shorter than faces
        uint[] got;
        bool threw = false;
        try got = m.selectedFaceIndicesInSelectionOrder();
        catch (Throwable) threw = true;
        assert(!threw, "accessor must not RangeError on a short faceSelectionOrder");
        // Face 5's stamp sits past the short array -> reads as unranked (0)
        // -> sorts LAST, after face 0's real rank.
        assert(got == [0u, 5u],
            format("short-stamp face must read as unranked (sorts last), got %s", got));
    }

    // A stale non-zero stamp on an UNSELECTED face is ignored -- the
    // accessor filters by `isFaceSelected` FIRST, never trusting a non-zero
    // stamp alone (caveat 2, extrude.d/edge_bevel.d leave exactly this kind
    // of residue behind).
    {
        Mesh m = makeCube();
        m.resetSelection();
        m.selectFace(0);
        m.selectFace(1);
        m.deselectFace(1);
        m.faceSelectionOrder[1] = 99;   // force a stale non-zero stamp back in
        assert(m.selectedFaceIndicesInSelectionOrder() == [0u],
            "a stale non-zero stamp on an unselected face must be ignored");
    }
}

// Task 1054 U6 — the ascending bulk stamp (§3.5b-iii, doc/
// loop_slice_corner_plan.md): our RMB polygon lasso stamps ascending face
// index (`app.d:5074-5148`, a `foreach (fi; 0 .. faces.length)` sweep calling
// `symmetricSelectFace` per hit) -- and as of task 1054 that stamp is an
// INPUT to the band-walk cut law, not an incidental iteration order. Pin it
// at the level the law consumes: a lasso-shaped ascending sweep must come
// back from the Phase-1 accessor in ascending order.
//
// Asserts the RAW `faceSelectionOrder` stamp array directly (task 1054
// review), not just `selectedFaceIndicesInSelectionOrder()`'s sorted
// projection of it: that accessor's own tie-break is ascending index
// (`mesh.d:8127`), so an UNSTAMPED selection (every rank tied at
// `int.max`) sorts to the identical ascending output as a selection
// stamped 1..N in order -- reddening only "reverse the sweep" (a mutation
// of THIS TEST's own iteration order, not of production code) proves
// nothing about whether `Mesh.selectFace` stamps at all. Verified by
// mutation: deleting `faceSelectionOrder[idx] = ++faceSelectionOrderCounter;`
// from `Mesh.selectFace` (mesh.d, the actual production stamp site) left
// the OLD accessor-based assert here green; asserting `faceSelectionOrder`
// directly reddens on that same deletion (got all-zero instead of
// `[1..6]`).
unittest {
    import symmetry_pick : symmetricSelectFace;
    import math : Viewport;

    Mesh m = makeCube();
    m.resetSelection();
    Viewport vp;
    // `symmetricSelectFace` returns silently to a plain `mesh.selectFace`
    // when the toolpipe isn't registered (its own doc comment, "unit
    // tests") -- exactly this context, so it exercises the same stamping
    // path the lasso drives without needing a live SymmetryStage.
    foreach (fi; 0 .. m.faces.length)
        symmetricSelectFace(&m, vp, EditMode.Polygons, cast(int)fi, false);
    int[] expectedStamp;
    foreach (fi; 0 .. m.faces.length) expectedStamp ~= cast(int)(fi + 1);
    assert(m.faceSelectionOrder == expectedStamp,
        format("a lasso-shaped ascending sweep must stamp faceSelectionOrder "
               ~ "1..N in face-index order, got %s", m.faceSelectionOrder));

    // The accessor's sorted projection is still the law's actual input --
    // keep this as a companion assert, not a replacement for the one above.
    uint[] expected;
    foreach (fi; 0 .. m.faces.length) expected ~= cast(uint)fi;
    assert(m.selectedFaceIndicesInSelectionOrder() == expected,
        format("a lasso-shaped ascending sweep must stamp ascending order, got %s",
               m.selectedFaceIndicesInSelectionOrder()));
}


// --------------------------------------------------------------------------
// Task 1210 — the three weld policy bits `vert.join` needs, at kernel level.
// Each block is written so that reverting the ONE production line it exercises
// turns it red, and the default-policy block is what says the other five weld
// producers were not moved.
// --------------------------------------------------------------------------

private Mesh makePlate2x1() {
    // 6 verts, 2 quads — the base the reference was driven on.
    Mesh m;
    foreach (v; [Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),
                 Vec3(0,0,1), Vec3(1,0,1), Vec3(2,0,1)])
        m.addVertex(v);
    m.addFace([0u, 1u, 4u, 3u]);
    m.addFace([1u, 2u, 5u, 4u]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

unittest { // selectedVerticesBySelectionOrder: stamped first, unstamped last
    Mesh m = makePlate2x1();
    m.resetSelection();
    // Click 4, then 1, then 0 — the stamps are 1,2,3 in THAT order.
    m.selectVertex(4); m.selectVertex(1); m.selectVertex(0);
    assert(m.selectedVerticesBySelectionOrder() == [4u, 1u, 0u],
        format("click order must survive verbatim, got %s",
               m.selectedVerticesBySelectionOrder()));

    // A vertex committed through the RESTORE setter carries stamp 0 and must
    // sort LAST, not first — the convention makePolygon established.
    bool[] want = new bool[](m.vertices.length);
    want[4] = want[1] = want[0] = true;
    want[5] = true;                       // the unstamped one
    m.setVerticesSelectedFrom(want);
    assert(m.selectedVerticesBySelectionOrder() == [4u, 1u, 0u, 5u],
        format("an unstamped vertex must sort behind every clicked one, got %s",
               m.selectedVerticesBySelectionOrder()));
}

unittest { // JoinWeldPolicy.survivor decides WHICH vertex a cluster keeps
    // The two welded corners end up at the SAME position, so a position or a
    // count assert cannot see which one survived — that shape of test would be
    // green either way. Identity is read off a per-vertex ATTRIBUTE instead:
    // vertex 0 is Selected and vertex 2 is not, and `compactUnreferenced`
    // carries `vertexMarks` through its permutation, so the merged vertex is
    // selected exactly when 0 was the survivor.
    foreach (prefer; [-1, 2]) {
        Mesh m = makePlate2x1();
        m.resetSelection();
        m.selectVertex(0);              // the distinguishing mark

        bool[] mask = new bool[](m.vertices.length);
        mask[0] = mask[2] = true;
        m.collapseVerticesByMask(mask, Vec3(2, 0, 0));

        JoinWeldPolicy pol;
        pol.survivor = prefer;
        const welded = m.weldVerticesByMask(mask, 1e-12, false, pol);
        assert(welded == 1, "exactly one of the pair must weld away");
        assert(m.vertices.length == 5,
            format("expected 5 verts after the weld, got %d", m.vertices.length));

        // Find the merged vertex by position and ask whether it carries 0's mark.
        int merged = -1;
        foreach (i; 0 .. m.vertices.length)
            if (m.vertices[i].x == 2.0f && m.vertices[i].z == 0.0f) merged = cast(int)i;
        assert(merged >= 0, "the merged vertex must sit at the weld target");

        const bool zeroSurvived = m.isVertexSelected(merged);
        assert(zeroSurvived == (prefer != 2),
            format("survivor=%d: expected vertex %s to be the one kept, but the "
                   ~ "merged vertex %s carry vertex 0's mark",
                   prefer, prefer == 2 ? "2" : "0",
                   zeroSurvived ? "does" : "does not"));
    }
}

unittest { // survivor + keepOrphanSurvivor: collapsing EVERYTHING leaves it
    Mesh m = makePlate2x1();
    bool[] all = new bool[](m.vertices.length);
    all[] = true;
    m.collapseVerticesByMask(all, Vec3(1, 0, 0.5f));

    JoinWeldPolicy pol;
    pol.survivor           = 5;      // the last-selected, in vert.join's terms
    pol.keepOrphanSurvivor = true;
    m.weldVerticesByMask(all, 1e-12, false, pol);

    assert(m.faces.length == 0, "every face collapses below the arity floor");
    assert(m.vertices.length == 1,
        format("the joined vertex must survive its own orphaning, got %d verts",
               m.vertices.length));
    assert(m.vertices[0].x == 1.0f && m.vertices[0].z == 0.5f,
        format("the survivor must sit at the join point, got %s", m.vertices[0]));

    // The pin is opt-in: the SAME weld without it empties the mesh, which is
    // what every other weld producer still does.
    Mesh m2 = makePlate2x1();
    bool[] all2 = new bool[](m2.vertices.length);
    all2[] = true;
    m2.collapseVerticesByMask(all2, Vec3(1, 0, 0.5f));
    m2.weldVerticesByMask(all2, 1e-12);
    assert(m2.vertices.length == 0,
        format("without the pin the compaction must still empty the mesh, "
               ~ "got %d verts", m2.vertices.length));
}

unittest { // keepTwoPointFaces lowers the arity floor from 3 to 2
    // A fan hub joined to one spoke leaves two of the eight triangles with
    // exactly two distinct corners.
    Mesh makeFan8() {
        Mesh f;
        f.addVertex(Vec3(0, 0, 0));
        immutable float s = 0.70710678f;
        foreach (v; [Vec3(1,0,0), Vec3(s,0,s), Vec3(0,0,1), Vec3(-s,0,s),
                     Vec3(-1,0,0), Vec3(-s,0,-s), Vec3(0,0,-1), Vec3(s,0,-s)])
            f.addVertex(v);
        foreach (k; 0 .. 8)
            f.addFace([0u, cast(uint)(k + 1), cast(uint)(k == 7 ? 1 : k + 2)]);
        f.buildLoops();
        f.syncSelection();
        return f;
    }

    foreach (keep; [false, true]) {
        Mesh m = makeFan8();
        bool[] mask = new bool[](m.vertices.length);
        mask[0] = mask[1] = true;
        m.collapseVerticesByMask(mask, Vec3(0.5f, 0, 0));

        JoinWeldPolicy pol;
        pol.survivor          = 1;
        pol.keepTwoPointFaces = keep;
        m.weldVerticesByMask(mask, 1e-12, false, pol);

        assert(m.faces.length == (keep ? 8 : 6),
            format("keep=%s must leave %d faces, got %d",
                   keep, keep ? 8 : 6, m.faces.length));
        if (keep) {
            size_t twoPoint = 0;
            foreach (ref f; m.faces) if (f.length == 2) ++twoPoint;
            assert(twoPoint == 2,
                format("expected exactly two TWO-POINT polygons, got %d",
                       twoPoint));
        }
        // A 2-corner ring visits (a,b) AND (b,a); the dedup must fold them
        // into one entry, or every such polygon would double an edge.
        bool[ulong] seen;
        foreach (e; m.edges) {
            const k = edgeKey(e[0], e[1]);
            assert((k in seen) is null,
                format("rebuildEdges emitted a duplicate edge %s", e));
            seen[k] = true;
        }
        assert(m.edges.length == 13,
            format("expected 13 edges either way here, got %d", m.edges.length));
    }
}
