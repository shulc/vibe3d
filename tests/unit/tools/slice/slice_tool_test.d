// Module unittests for `tools.slice.slice_tool`, moved verbatim out of source/tools/slice/slice_tool.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.slice.slice_tool_test;

import bindbc.sdl;
import bindbc.opengl;
import std.json : JSONValue;
import std.math : sqrt, sin, cos, PI;
import ImGui = d_imgui;
import d_imgui.imgui_h;   // ImDrawList / ImVec2 / IM_COL32 for the RMB gap HUD (task 0288)
import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry, wireTagForValue;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import operator : VectorStack;
import display_sync : refreshDisplay;
import eventlog : queryMouse;
import handler : BoxHandler, FullCircleHandler, ToolHandles, gizmoSize, getGizmoPixels, drawWorldSegment, drawWorldQuad;
import viewport_scheme : schemeColor, SchemeColor;
import document : primaryModelSpace;
import tools.create.create_common : currentWorkplaneFrame, pickWorkplaneFrame, WorkplaneFrame;
import tools.slice.slice_tool;

// ---------------------------------------------------------------------------
// Non-cumulative preview + fast-gate parity (dub test). Proves the two S1
// invariants at the cut-kernel level without a GL context:
//   1. Dragging the line through many preview positions never accumulates —
//      each `sliceFromBaseline` reproduces a single clean cut of the pristine
//      baseline (a mid-plane cube cut is always 12v/10f, never 16v+).
//   2. The `fast`-deferred commit (one call at the final line) yields the
//      identical geometry to the live-preview path (N previews then a final
//      commit-position call).
// Runs on the `infinite` path (infinite=true): these positions vary the line
// LENGTH, and the point here is length-INDEPENDENT non-accumulation, so the
// whole-mesh plane cut is the right invariant. The clipped-default divergence
// (line length changes what is cut) is covered by cutByPlaneClipped's mesh.d
// unittests + test_fixture_slice_infinite.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // A drag of the End endpoint through several positions, all producing a
    // vertical (X-normal, through X=0) cut of the unit cube: the line lies
    // along Z (perpendicular to +Y work plane), start fixed at (0,0,-1).
    Vec3[] endPositions = [
        Vec3(0, 0, 0.4f), Vec3(0, 0, 0.7f), Vec3(0, 0, 1.0f), Vec3(0, 0, 1.3f),
    ];
    Vec3 start = Vec3(0, 0, -1);
    Vec3 wpN   = Vec3(0, 1, 0);   // default world-XZ work plane normal
    enum bool INF = true;         // whole-mesh plane — length-independent cut

    // --- Path A: live preview drag, then commit at the final line ---
    Mesh live = makeCube();
    auto baseline = MeshSnapshot.capture(live);
    assert(live.vertices.length == 8 && live.faces.length == 6);

    foreach (ep; endPositions) {
        size_t n = sliceFromBaseline(live, baseline, start, ep, wpN,
                                     SLICE_AXIS_DRAG, Vec3(0, 1, 0), INF);
        assert(n > 0, "each mid-plane preview must split faces");
        // NON-CUMULATIVE: always the single-cut topology, never accumulated.
        assert(live.vertices.length == 12, "preview must not accumulate verts");
        assert(live.faces.length == 10,    "preview must not accumulate faces");
    }
    // Commit at the final line (revert baseline + cut once — the same
    // non-cumulative kernel the deferred deactivate-commit records).
    size_t nCommit = sliceFromBaseline(live, baseline, start, endPositions[$-1], wpN,
                                       SLICE_AXIS_DRAG, Vec3(0, 1, 0), INF);
    assert(nCommit > 0);
    assert(live.vertices.length == 12 && live.faces.length == 10);

    // --- Path B: fast — no live preview, a single deferred commit ---
    Mesh fast = makeCube();
    auto fastBaseline = MeshSnapshot.capture(fast);
    size_t nFast = sliceFromBaseline(fast, fastBaseline, start, endPositions[$-1], wpN,
                                     SLICE_AXIS_DRAG, Vec3(0, 1, 0), INF);
    assert(nFast == nCommit);
    assert(fast.vertices.length == live.vertices.length);
    assert(fast.faces.length    == live.faces.length);

    // Byte-for-byte geometry parity between the fast-deferred and live-preview
    // commits (both are one cut of the pristine baseline at the same line).
    foreach (i; 0 .. live.vertices.length) {
        assert(abs(live.vertices[i].x - fast.vertices[i].x) < 1e-6f);
        assert(abs(live.vertices[i].y - fast.vertices[i].y) < 1e-6f);
        assert(abs(live.vertices[i].z - fast.vertices[i].z) < 1e-6f);
    }

    // --- Clip default: the SAME short line (end z=0.4) cuts LESS than infinite.
    // Its far crossing (z=+0.5) projects past the drawn span, so only the near
    // (z=−0.5) side splits cleanly — a countable proof the default clips. The
    // line ENDS inside the top & bottom faces (z=0.4 < 0.5), so those receive a
    // keyhole interior vertex (task 0289) instead of a clean split; the clip thus
    // still splits FEWER faces than the infinite belt (7 vs 10 total faces).
    Mesh clip = makeCube();
    auto clipBase = MeshSnapshot.capture(clip);
    size_t nClip = sliceFromBaseline(clip, clipBase, start, Vec3(0, 0, 0.4f), wpN);
    assert(nClip < 4, "clipped short line must split fewer faces than infinite (4)");
    assert(clip.faces.length < 10,
           "clipped short line splits fewer faces than the full belt (infinite=10)");
}

// ---------------------------------------------------------------------------
// sliceSplitGap unittests (task 0291) — the partial-cut fallback (objection 2)
// and the caps==false routing note (DQ4).
// ---------------------------------------------------------------------------
unittest { // sliceSplitGap: a PARTIAL cut — one of the two offset planes never
    // finds any geometry within the clip span — does NOT fully separate the
    // mesh, so `cutByPlaneSplitGap` reports `separated == false`. Silently
    // dropping the gap here would be a REGRESSION (today's slide DOES open one
    // for the equivalent single center-plane cut), so `sliceSplitGap` must
    // roll back both offset cuts and reproduce the legacy single-cut+slide
    // (at the CENTER plane, not either offset) EXACTLY.
    //
    // Construction: a cube mid-plane cut (x=0, gap 0.4 center ⇒ offsets at
    // x=+0.2 and x=-0.2), CLIPPED to a segment lying ALONG the cut normal
    // itself (x from -0.25 to +0.1) rather than across it. `cutByPlaneClipped`
    // only tests a crossing's projection onto the segment's OWN direction —
    // it need not lie IN the cut plane — so this is a legal, if extreme,
    // clip. Every crossing at x=+0.2 (the `+offset` plane) projects to
    // s≈1.29 (past the segment's end) ⇒ OUT of band ⇒ that whole cut is a
    // no-op; every crossing at x=-0.2 (the `-offset` plane) projects to
    // s≈0.14 ⇒ IN band ⇒ that cut proceeds normally. With only ONE of the
    // two boundary planes actually cutting anything, there is no bounded
    // [-hiAmt,+loAmt] slab anywhere in the result — `deleteComponentsInSlab`
    // finds nothing (both resulting shells extend to the cube's far corners,
    // well past either offset), so `separated == false`. Crucially, the
    // crossing at x=0 (the CENTER plane the legacy path actually cuts at)
    // projects to s≈0.71 — IN band — so the legacy single-cut+slide at the
    // center plane, using this SAME clip segment, still opens a real gap.
    import std.math : abs;

    Mesh viaHelper = makeCube();
    viaHelper.buildLoops();
    viaHelper.resetSelection();
    Mesh viaLegacy = makeCube();
    viaLegacy.buildLoops();
    viaLegacy.resetSelection();

    Vec3 P = Vec3(0, 0, 0), N = Vec3(1, 0, 0);
    Vec3 segStart = Vec3(-0.25f, 0, 0), segEnd = Vec3(0.1f, 0, 0);
    enum float G = 0.4f;

    size_t nHelper = sliceSplitGap(viaHelper, P, N, /*clipped*/true, segStart, segEnd,
                                   /*caps*/true, G, /*gapSide*/0, null);

    // The kernel is a free function over `ref MeshEditBatch` (task 1903 Stage
    // E3), so the legacy arm opens its own UNRECORDED batch — exactly what
    // `sliceSplitGap` does internally for the arm this compares against.
    PlaneCutLoops loops;
    size_t nLegacy;
    {
        auto ed = MeshEditBatch.unrecorded(viaLegacy, kCutEditScope);
        nLegacy = ed.cutByPlaneEx(P, N, /*clipped*/true, segStart, segEnd,
                                  /*split*/true, /*caps*/true, loops,
                                  1e-5f, null, G, 0);
        ed.close();
    }

    assert(nHelper > 0, "the clipped segment must still cut some faces");
    assert(nHelper == nLegacy,
           "partial cut: the fallback must cut exactly as many faces as the legacy slide");
    assert(viaHelper.vertices.length == viaLegacy.vertices.length,
           "partial cut: fallback must reproduce the legacy slide's vertex count");
    assert(viaHelper.faces.length == viaLegacy.faces.length,
           "partial cut: fallback must reproduce the legacy slide's face count");
    foreach (i; 0 .. viaHelper.vertices.length) {
        Vec3 a = viaHelper.vertices[i], b = viaLegacy.vertices[i];
        assert(abs(a.x - b.x) < 1e-6f && abs(a.y - b.y) < 1e-6f && abs(a.z - b.z) < 1e-6f,
               "partial cut: fallback vertex must match the legacy slide exactly");
    }
    // Sanity: the fallback really opened a gap (grew past the pristine
    // cube's 8 verts), it did not silently no-op.
    assert(viaHelper.vertices.length > 8,
           "partial cut: the fallback must still open a gap, not drop it");
    // And it must NOT have taken the two-cut path silently: confirm the
    // TWO-CUT attempt on an independent copy really does report
    // separated==false for this exact scenario (the discriminator this test
    // exercises), rather than the byte-parity above passing by coincidence.
    {
        Mesh probe = makeCube();
        probe.buildLoops();
        probe.resetSelection();
        bool separated;
        {
            auto ed = MeshEditBatch.unrecorded(probe, kCutEditScope);
            ed.cutByPlaneSplitGap(P, N, /*clipped*/true, segStart, segEnd,
                                  /*caps*/true, G, /*gapSide*/0, separated, null);
            ed.close();
        }
        assert(!separated,
               "partial cut: the two offset cuts must NOT report separated==true "
               ~ "(one plane's crossings project entirely out of the clip band)");
    }
}

unittest { // sliceSplitGap: caps==false + split + gap routes to the two-cut
    // path and still deletes the band (task 0291, DQ4) — the `gap != 0` gate
    // ignores `caps`, so an uncapped split+gap is NOT silently forced through
    // the legacy slide. A full mid-plane cut of a cube (gap 0.2 center,
    // caps=false): the band is still a bounded connected component (4 side
    // sub-quads forming a closed ring, no caps needed for DSU connectivity)
    // and gets removed exactly as in the capped case; only the 2 cap FACES
    // are absent, so each remaining shell's boundary loop is OPEN.
    static size_t boundaryEdgeCount(ref Mesh m) {
        size_t n = 0;
        foreach (ei; 0 .. m.edges.length) {
            size_t nf = 0;
            foreach (fi; m.facesAroundEdge(cast(uint)ei)) ++nf;
            if (nf == 1) ++n;
        }
        return n;
    }
    static size_t componentCount(ref Mesh m) {
        auto nf = m.faces.length;
        if (nf == 0) return 0;
        auto parent = new size_t[](nf);
        foreach (i; 0 .. nf) parent[i] = i;
        size_t find(size_t x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void uni(size_t a, size_t b) { parent[find(a)] = find(b); }
        uint[][uint] vFaces;
        foreach (fi, f; m.faces) foreach (v; f) vFaces[v] ~= cast(uint)fi;
        foreach (v, fs; vFaces) foreach (k; 1 .. fs.length) uni(fs[0], fs[k]);
        bool[size_t] roots;
        foreach (i; 0 .. nf) roots[find(i)] = true;
        return roots.length;
    }

    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();

    Vec3 P = Vec3(0, 0, 0), N = Vec3(1, 0, 0);
    enum float G = 0.2f;

    size_t n = sliceSplitGap(m, P, N, /*clipped*/false, P, P,
                            /*caps*/false, G, /*gapSide*/0, null);
    assert(n > 0, "the mid-plane must cut faces");
    assert(componentCount(m) == 2, "band removed: exactly 2 shells left, even uncapped");
    assert(m.vertices.length == 16, "caps add no verts — same 16v as the capped case");
    assert(m.faces.length == 10,
           "caps==false: 2 shells x (4 side + 1 original), no cap faces (12-2)");
    assert(boundaryEdgeCount(m) > 0,
           "caps==false must leave each shell's boundary loop OPEN (not sealed)");
}

// ---------------------------------------------------------------------------
// Cut-plane overlay geometry (task 0284). Proves, WITHOUT a GL context, that
// the translucent quad SliceTool.draw() renders:
//   1. lies IN the cut plane — every corner satisfies dot(corner - p, n) ≈ 0;
//   2. CONTAINS the Start→End segment (both endpoints project inside the
//      corner extents);
//   3. TRACKS the live state — changing `axis` (⇒ a different plane normal) and
//      moving an endpoint move the corners and keep them in the NEW plane.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // Assert all four corners lie in the plane (p, n) and contain the segment.
    static void checkQuad(Vec3 start, Vec3 end, Vec3 wpN, int axis, Vec3 vector) {
        Vec3 p, n;
        assert(planeForSlice(start, end, wpN, axis, vector, p, n),
               "test lines are chosen so the plane is well-defined");
        Vec3 dir, perp;
        assert(sliceOverlayBasis(start, end, n, dir, perp),
               "in-plane line ⇒ a valid overlay basis");

        // In-plane basis: both axes ⟂ the normal.
        assert(abs(dot(dir,  n)) < 1e-5f, "dir must be in-plane");
        assert(abs(dot(perp, n)) < 1e-5f, "perp must be in-plane");
        assert(abs(dot(dir, perp)) < 1e-5f, "dir ⟂ perp");

        // Size to a unit cube (the region being cut) + the segment.
        Mesh cube = makeCube();
        float aMin, aMax, bMin, bMax;
        sliceOverlayExtent(cube, ModelSpace.world(), p, dir, perp, start, end, aMin, aMax, bMin, bMax);
        Vec3[4] q = sliceOverlayQuad(p, dir, perp, aMin, aMax, bMin, bMax);

        // (1) every corner lies in the cut plane.
        foreach (c; q)
            assert(abs(dot(c - p, n)) < 1e-4f,
                   "quad corner must lie in the cut plane");

        // (2) the quad contains the segment: start/end project inside [aMin,aMax]
        //     along dir and [bMin,bMax] across perp.
        foreach (pt; [start, end]) {
            float a = dot(pt - p, dir), b = dot(pt - p, perp);
            assert(a >= aMin - 1e-4f && a <= aMax + 1e-4f, "segment within along-extent");
            assert(b >= bMin - 1e-4f && b <= bMax + 1e-4f, "segment within cross-extent");
        }
        // The extents are non-degenerate (a real rectangle).
        assert(aMax - aMin > 1e-3f && bMax - bMin > 1e-3f);
    }

    // Drag plane (no override): a Z-line ⇒ an X-normal plane; corners in-plane,
    // contain line.
    checkQuad(Vec3(0, 0, -1), Vec3(0, 0, 1), Vec3(0, 1, 0),
              SLICE_AXIS_DRAG, Vec3(0, 1, 0));

    // OWNER FIX 1 (0284): the overlay spans EXACTLY the segment along the line —
    // its along-`dir` extent never runs past the endpoint handles, no matter how
    // large the mesh is. A short Z-line on the unit cube must keep aMin/aMax at
    // the segment's own projection (here [0, 1]), NOT stretched to the cube's
    // ±0.5 along the line (which the pre-fix mesh-union extent would have done).
    {
        Vec3 s = Vec3(0, 0, -0.5f), e = Vec3(0, 0, 0.5f);   // a Z-line, length 1
        Vec3 p, n, dir, perp;
        assert(planeForSlice(s, e, Vec3(0,1,0), SLICE_AXIS_DRAG, Vec3(0,1,0), p, n));
        assert(sliceOverlayBasis(s, e, n, dir, perp));
        Mesh cube = makeCube();
        float aMin, aMax, bMin, bMax;
        sliceOverlayExtent(cube, ModelSpace.world(), p, dir, perp, s, e, aMin, aMax, bMin, bMax);
        // Along the line: exactly the segment [0, 1] (p == start, dir == +Z).
        assert(abs(aMin - 0.0f) < 1e-5f, "along-min flush with the Start handle");
        assert(abs(aMax - 1.0f) < 1e-5f, "along-max flush with the End handle (no overhang)");
        // Across the line the plane DOES cover the cube (≥ its ±0.5 depth) so the
        // cut reads through the geometry (owner fix 2 shows it, this sizes it).
        assert(bMax >= 0.5f - 1e-5f && bMin <= -0.5f + 1e-5f,
               "cross-line extent must still span the mesh depth");
    }

    // TRACKING — axis change (extrusion-direction model): the SAME X-line extruded
    // along Z vs along Y gives DIFFERENT planes, and the drawn line lies IN both.
    {
        Vec3 s = Vec3(-0.5f, 0, 0), e = Vec3(0.5f, 0, 0);  // an X-line
        // axis=Z ⇒ extrude the X-line along Z ⇒ Y-normal plane (n = cross(X,Z)).
        // The X-line still lies IN it (n ⟂ line by construction).
        Vec3 pZ, nZ, dirZ, perpZ;
        assert(planeForSlice(s, e, Vec3(0,1,0), cast(int)SliceAxis.Z, Vec3(0,1,0), pZ, nZ));
        assert(abs(dot(s - pZ, nZ)) < 1e-5f && abs(dot(e - pZ, nZ)) < 1e-5f,
               "both endpoints lie in the axis=Z plane");
        assert(sliceOverlayBasis(s, e, nZ, dirZ, perpZ));
        checkQuad(s, e, Vec3(0, 1, 0), cast(int)SliceAxis.Z, Vec3(0, 1, 0));
        // axis=Y ⇒ extrude along Y ⇒ Z-normal plane; the X-line still lies in it,
        // but the plane (and hence perp) differs from axis=Z — the overlay tracked it.
        Vec3 pY, nY, dirY, perpY;
        assert(planeForSlice(s, e, Vec3(0,1,0), cast(int)SliceAxis.Y, Vec3(0,1,0), pY, nY));
        assert(abs(dot(s - pY, nY)) < 1e-5f && abs(dot(e - pY, nY)) < 1e-5f,
               "both endpoints lie in the axis=Y plane");
        assert(sliceOverlayBasis(s, e, nY, dirY, perpY));
        assert(abs(dot(nZ, nY)) < 1.0f - 1e-4f,
               "a different extrusion axis yields a different plane normal");
        checkQuad(s, e, Vec3(0, 1, 0), cast(int)SliceAxis.Y, Vec3(0, 1, 0));
    }

    // TRACKING — endpoint move: extending End along the line grows the along-
    // extent (the quad spans the longer segment). Anchor p = start.
    {
        Vec3 s = Vec3(0, 0, -0.5f);
        Mesh cube = makeCube();
        Vec3 pS, nS, dir, perp;
        assert(planeForSlice(s, Vec3(0,0,0.5f), Vec3(0,1,0),
                             SLICE_AXIS_DRAG, Vec3(0,1,0), pS, nS));
        assert(sliceOverlayBasis(s, Vec3(0,0,0.5f), nS, dir, perp));
        float a0min, a0max, b0min, b0max;
        sliceOverlayExtent(cube, ModelSpace.world(), pS, dir, perp, s, Vec3(0,0,0.5f), a0min, a0max, b0min, b0max);
        float a1min, a1max, b1min, b1max;
        sliceOverlayExtent(cube, ModelSpace.world(), pS, dir, perp, s, Vec3(0,0,3.0f), a1min, a1max, b1min, b1max);
        assert(a1max > a0max + 1e-4f,
               "moving End further out must grow the overlay's along-extent");
    }

    // Degenerate: a line parallel to the plane normal has no in-plane direction.
    {
        Vec3 dir, perp;
        assert(!sliceOverlayBasis(Vec3(0,0,0), Vec3(0,1,0), Vec3(0,1,0), dir, perp),
               "a line ∥ the normal yields no overlay basis");
    }

    // OWNER BUG FIX (0284): when the axis is LOCKED to a world axis, the cut
    // plane's normal is that axis and the plane NO LONGER contains the drawn
    // line. The unlocked line-based basis then goes thin/degenerate when the
    // normal runs near-parallel to the line — so the locked path must derive its
    // basis from the NORMAL (not the line) and cover the mesh. Verify for
    // axis = X / Y / Z, each with a line drawn ALONG that same axis (i.e. the
    // line is PARALLEL to the locked normal — the worst case the unlocked basis
    // cannot handle): a valid, non-degenerate, mesh-spanning, in-plane quad.
    static void checkLocked(Vec3 n, Vec3 start, Vec3 end) {
        import std.math : abs;
        // The unlocked basis is degenerate for this line (∥ the normal)...
        Vec3 ud, up;
        assert(!sliceOverlayBasis(start, end, n, ud, up),
               "line ∥ locked normal ⇒ no unlocked (line-based) basis");
        // ...but the locked (normal-derived) basis is well-defined.
        Vec3 dir, perp;
        assert(sliceOverlayBasisLocked(n, dir, perp),
               "a valid unit normal always yields a locked basis");
        Vec3 nn = normalize(n);
        assert(abs(dot(dir,  nn)) < 1e-5f, "locked dir must be in-plane");
        assert(abs(dot(perp, nn)) < 1e-5f, "locked perp must be in-plane");
        assert(abs(dot(dir, perp)) < 1e-5f, "locked dir ⟂ perp");
        assert(abs(dir.length  - 1.0f) < 1e-5f, "locked dir is unit");
        assert(abs(perp.length - 1.0f) < 1e-5f, "locked perp is unit");

        // Extent covers the unit cube (the region being cut), anchored at p = start.
        Mesh cube = makeCube();
        Vec3 p = start;   // planeForSlice always sets p = start
        float aMin, aMax, bMin, bMax;
        sliceOverlayExtentLocked(cube, ModelSpace.world(), p, dir, perp, aMin, aMax, bMin, bMax);
        Vec3[4] q = sliceOverlayQuad(p, dir, perp, aMin, aMax, bMin, bMax);

        // (1) every corner lies in the cut plane.
        foreach (c; q)
            assert(abs(dot(c - p, nn)) < 1e-4f, "locked quad corner in the cut plane");
        // (2) the quad SPANS the mesh (not collapsed to the line): the unit cube
        //     measures 1.0 across each in-plane axis, so both extents clear ~0.9.
        assert(aMax - aMin > 0.9f, "locked quad spans the mesh along dir");
        assert(bMax - bMin > 0.9f, "locked quad spans the mesh along perp");
    }
    checkLocked(Vec3(1, 0, 0), Vec3(-0.5f, 0, 0), Vec3(0.5f, 0, 0));   // axis X, X-line
    checkLocked(Vec3(0, 1, 0), Vec3(0, -0.5f, 0), Vec3(0, 0.5f, 0));   // axis Y, Y-line
    checkLocked(Vec3(0, 0, 1), Vec3(0, 0, -0.5f), Vec3(0, 0, 0.5f));   // axis Z, Z-line

    // The UNLOCKED path is unchanged: an in-plane line still bounds the along-
    // extent to the drawn segment (never mesh-spanning along the line).
    {
        Vec3 s = Vec3(0, 0, -0.5f), e = Vec3(0, 0, 0.5f);   // a Z-line
        Vec3 p, n, dir, perp;
        assert(planeForSlice(s, e, Vec3(0,1,0), SLICE_AXIS_DRAG, Vec3(0,1,0), p, n));
        assert(sliceOverlayBasis(s, e, n, dir, perp));
        Mesh cube = makeCube();
        float aMin, aMax, bMin, bMax;
        sliceOverlayExtent(cube, ModelSpace.world(), p, dir, perp, s, e, aMin, aMax, bMin, bMax);
        assert(abs(aMin - 0.0f) < 1e-5f && abs(aMax - 1.0f) < 1e-5f,
               "unlocked along-extent stays flush with the drawn segment");
    }
}

// ---------------------------------------------------------------------------
// OWNER FIX 3 (0284) — FROZEN cut-plane normal. Both the cut (sliceFromBaseline)
// and the overlay (draw) build their plane from the tool's effectiveNormal(),
// which is the normal FROZEN at the gesture that drew the line. This proves,
// analytically, that once frozen the plane is decoupled from the work-plane
// normal: feeding a DIFFERENT (post-orbit) work-plane normal does NOT move the
// plane, while the tool keeps using the frozen one — so the drawn cut and the
// committed cut cannot diverge under camera orbit. (Guarding against the OLD
// bug where draw()/updatePreview recomputed cachedWorkplaneNormal() live.)
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // A Z-line; the drag normal captured at gesture start is +Y (world-XZ work
    // plane). After the user orbits, the LIVE work-plane normal would tilt.
    Vec3 s = Vec3(0, 0, -1), e = Vec3(0, 0, 1);
    Vec3 frozenN  = Vec3(0, 1, 0);
    Vec3 orbitedN = normalize(Vec3(0.35f, 1.0f, 0.25f));   // camera moved

    // The plane the cut/overlay use is fully determined by the PASSED normal.
    Vec3 pFrozen, nFrozen;
    assert(planeForSlice(s, e, frozenN, SLICE_AXIS_DRAG, Vec3(0,1,0), pFrozen, nFrozen));

    // If the tool (wrongly) used the LIVE normal after an orbit, the plane would
    // move: prove the live normal yields a DIFFERENT plane normal.
    Vec3 pLive, nLive;
    assert(planeForSlice(s, e, orbitedN, SLICE_AXIS_DRAG, Vec3(0,1,0), pLive, nLive));
    assert(abs(dot(nFrozen, nLive)) < 1.0f - 1e-3f,
           "a changed work-plane normal WOULD move the drag plane (so freezing matters)");

    // The tool keeps passing the FROZEN normal, so the plane is unchanged after
    // the orbit — identical normal, identical through-point.
    Vec3 pStill, nStill;
    assert(planeForSlice(s, e, frozenN, SLICE_AXIS_DRAG, Vec3(0,1,0), pStill, nStill));
    assert(abs(nStill.x - nFrozen.x) < 1e-6f &&
           abs(nStill.y - nFrozen.y) < 1e-6f &&
           abs(nStill.z - nFrozen.z) < 1e-6f,
           "frozen normal ⇒ the cut/overlay plane stays put across camera orbit");

    // And the ACTUAL cut geometry is frozen too: cutting the cube with the frozen
    // normal is byte-for-byte identical regardless of the later live normal,
    // while the live normal would have produced a measurably different cut.
    Mesh a = makeCube(); auto ba = MeshSnapshot.capture(a);
    Mesh b = makeCube(); auto bb = MeshSnapshot.capture(b);
    Mesh c = makeCube(); auto bc = MeshSnapshot.capture(c);
    // `a`, `b`: cut with the FROZEN normal (the tool's behavior before + after orbit).
    sliceFromBaseline(a, ba, s, e, frozenN,  SLICE_AXIS_DRAG, Vec3(0,1,0), true);
    sliceFromBaseline(b, bb, s, e, frozenN,  SLICE_AXIS_DRAG, Vec3(0,1,0), true);
    // `c`: cut with the ORBITED normal (what the buggy live path would have done).
    sliceFromBaseline(c, bc, s, e, orbitedN, SLICE_AXIS_DRAG, Vec3(0,1,0), true);
    assert(a.vertices.length == b.vertices.length);
    bool frozenStable = true, liveDiffers = false;
    foreach (i; 0 .. a.vertices.length) {
        if (abs(a.vertices[i].x - b.vertices[i].x) > 1e-6f ||
            abs(a.vertices[i].y - b.vertices[i].y) > 1e-6f ||
            abs(a.vertices[i].z - b.vertices[i].z) > 1e-6f) frozenStable = false;
    }
    if (c.vertices.length == a.vertices.length) {
        foreach (i; 0 .. a.vertices.length)
            if (abs(a.vertices[i].x - c.vertices[i].x) > 1e-4f ||
                abs(a.vertices[i].y - c.vertices[i].y) > 1e-4f ||
                abs(a.vertices[i].z - c.vertices[i].z) > 1e-4f) liveDiffers = true;
    } else liveDiffers = true;
    assert(frozenStable, "frozen-normal cut is identical before/after orbit");
    assert(liveDiffers,  "the live-normal cut WOULD differ — so the freeze is load-bearing");
}

// ---------------------------------------------------------------------------
// OWNER FIX 4 (0284; extrusion-direction model) — the axis model has NO `Free`.
// SliceAxis offers only the {X, Y, Z, Custom} OVERRIDE; "no override" is the
// runtime SLICE_AXIS_DRAG mode (the frozen drag plane), which is the DEFAULT. This
// asserts the enum/table shape, that SLICE_AXIS_DRAG reproduces the drawn-line
// plane, and that every override mode extrudes the line along its axis so the
// plane CONTAINS BOTH endpoints (n ⟂ line) — the core owner-bug invariant.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // No `Free` member survives, and the values are the unchanged 1..4.
    static assert(!__traits(hasMember, SliceAxis, "Free"),
                  "SliceAxis must not expose a Free value (owner fix 4)");
    static assert(cast(int)SliceAxis.X == 1 && cast(int)SliceAxis.Y == 2 &&
                  cast(int)SliceAxis.Z == 3 && cast(int)SliceAxis.Custom == 4);
    static assert(SLICE_AXIS_DRAG == 0, "the no-override wire mode is 0 (planeForSlice default)");

    // The user-selectable table is exactly {x, y, z, custom} — no "free" tag.
    assert(sliceAxisTable.length == 4);
    foreach (entry; sliceAxisTable)
        assert(entry.wireTag != "free", "no 'free' entry in the Axis dropdown");
    assert(sliceAxisTable[0].wireTag == "x" && sliceAxisTable[1].wireTag == "y" &&
           sliceAxisTable[2].wireTag == "z" && sliceAxisTable[3].wireTag == "custom");

    // DEFAULT = the frozen drag plane: mode SLICE_AXIS_DRAG reproduces the
    // drawn-line ⟂ work-plane plane exactly (== planeFromLineAndWorkplane).
    Vec3 s = Vec3(0, 0, -1), e = Vec3(0.3f, 0, 1), wpN = Vec3(0, 1, 0);
    Vec3 pD, nD, pR, nR;
    assert(planeForSlice(s, e, wpN, SLICE_AXIS_DRAG, Vec3(0,1,0), pD, nD));
    assert(planeFromLineAndWorkplane(s, e, wpN, pR, nR));
    assert(abs(nD.x - nR.x) < 1e-6f && abs(nD.y - nR.y) < 1e-6f && abs(nD.z - nR.z) < 1e-6f,
           "the no-override default is the drawn-line drag plane");

    // OVERRIDE X/Y/Z/Custom: the line is EXTRUDED along the axis, so the plane
    // CONTAINS BOTH drawn endpoints (n ⟂ line) and n ⟂ the extrusion axis. This is
    // the owner-bug invariant: the axis-locked plane still passes through both
    // points, unlike the old normal=world-axis model (which passed through Start
    // only). Verify for each axis with the slanted line above.
    Vec3 p, n;
    static void checkExtrude(Vec3 s, Vec3 e, int mode, Vec3 axisDir, Vec3 vec) {
        Vec3 pp, nn;
        assert(planeForSlice(s, e, Vec3(0,1,0), mode, vec, pp, nn),
               "a line not parallel to the axis has a well-defined plane");
        assert(abs(nn.length - 1.0f) < 1e-5f, "unit normal");
        assert(abs(dot(s - pp, nn)) < 1e-5f, "Start lies in the extruded plane");
        assert(abs(dot(e - pp, nn)) < 1e-5f, "End lies in the extruded plane");
        assert(abs(dot(nn, normalize(axisDir))) < 1e-5f, "n ⟂ the extrusion axis");
    }
    checkExtrude(s, e, cast(int)SliceAxis.X, Vec3(1,0,0), Vec3(0,1,0));
    checkExtrude(s, e, cast(int)SliceAxis.Y, Vec3(0,1,0), Vec3(0,1,0));
    checkExtrude(s, e, cast(int)SliceAxis.Z, Vec3(0,0,1), Vec3(0,1,0));
    checkExtrude(s, e, cast(int)SliceAxis.Custom, Vec3(2,0,0), Vec3(2,0,0));

    // The override plane can DIFFER from the drag-plane normal for this line
    // (axis=Z vs. the drag plane) — proving lock ≠ default.
    assert(planeForSlice(s, e, wpN, cast(int)SliceAxis.Z, Vec3(0,1,0), p, n));
    assert(abs(dot(n, nD)) < 1.0f - 1e-4f,
           "an axis override yields a different plane than the drag default");

    // DEGENERATE GUARD: a line drawn ALONG the extrusion axis has no unique plane.
    assert(!planeForSlice(Vec3(-1,0,0), Vec3(1,0,0), wpN,
                          cast(int)SliceAxis.X, Vec3(0,1,0), p, n),
           "line ∥ extrusion axis X ⇒ planeForSlice returns false");
}

// ---------------------------------------------------------------------------
// OWNER FIX 1 (0284; extrusion-direction model) — the drag plane's EXTRUSION
// DIRECTION classifies to a concrete Axis so the Tool-Properties dropdown reflects
// the drawn cut. Proves, WITHOUT a GL context: (a) an axis-aligned extrusion dir →
// X/Y/Z; (b) a slanted extrusion dir → Custom with vector == the direction; (c) the
// classification ROUND-TRIPS the plane (drag plane → classify the extrusion dir →
// planeForSlice(classifiedAxis) reproduces the SAME plane); (d) the cut is
// BYTE-IDENTICAL whether cut in drag mode (SLICE_AXIS_DRAG) or via the classified
// axis — so reflecting the panel never moves the geometry.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    // Each world axis (both signs) classifies to its axis — the extrusion dir is
    // the frozen work-plane normal, classified sign-agnostically (|dir·axis| ≥ tol).
    {
        Vec3 v;
        assert(classifyPlaneAxis(Vec3( 1,0,0), v) == SliceAxis.X);
        assert(classifyPlaneAxis(Vec3(-1,0,0), v) == SliceAxis.X);
        assert(classifyPlaneAxis(Vec3(0, 1,0), v) == SliceAxis.Y);
        assert(classifyPlaneAxis(Vec3(0,-1,0), v) == SliceAxis.Y);
        assert(classifyPlaneAxis(Vec3(0,0, 1), v) == SliceAxis.Z);
        assert(classifyPlaneAxis(Vec3(0,0,-1), v) == SliceAxis.Z);
    }
    // (a) The default +Y work plane (the headless drag extrusion direction)
    //     classifies to axis Y.
    {
        Vec3 v;
        assert(classifyPlaneAxis(Vec3(0,1,0), v) == SliceAxis.Y,
               "the +Y work-plane extrusion direction classifies to axis Y");
    }
    // (b) A slanted extrusion direction ⇒ Custom, vector == normalize(direction).
    {
        Vec3 d = normalize(Vec3(0.3f, 1.0f, 0.0f));   // off every world axis
        Vec3 v;
        assert(classifyPlaneAxis(d, v) == SliceAxis.Custom,
               "an off-axis extrusion direction classifies to Custom");
        assert(abs(v.x - d.x) < 1e-6f && abs(v.y - d.y) < 1e-6f && abs(v.z - d.z) < 1e-6f,
               "Custom vector == the extrusion direction");
    }

    // (c) ROUND-TRIP + (d) BYTE-IDENTICAL cut: build the drag plane, classify its
    //     extrusion direction (the work-plane normal), rebuild via the classified
    //     axis, and assert BOTH the plane (n, p) and the resulting cube cut match.
    static void assertRoundTrip(Vec3 s, Vec3 e, Vec3 wpN) {
        // Drag plane (extrude the line along wpN).
        Vec3 pD, nD;
        assert(planeForSlice(s, e, wpN, SLICE_AXIS_DRAG, Vec3(0,1,0), pD, nD));
        // Classify the EXTRUSION direction (the work-plane normal), NOT the cut normal.
        Vec3 v;
        SliceAxis a = classifyPlaneAxis(wpN, v);
        // Rebuild via the classified axis and assert the SAME plane.
        Vec3 pC, nC;
        assert(planeForSlice(s, e, wpN, cast(int)a, v, pC, nC));
        assert(abs(nC.x - nD.x) < 1e-5f && abs(nC.y - nD.y) < 1e-5f && abs(nC.z - nD.z) < 1e-5f,
               "classified-axis plane normal == the drag plane normal");
        assert(abs(pC.x - pD.x) < 1e-6f && abs(pC.y - pD.y) < 1e-6f && abs(pC.z - pD.z) < 1e-6f,
               "classified-axis through-point == the drag through-point");
        // ...and the actual cube cut is byte-identical either way.
        Mesh md = makeCube(); auto bd = MeshSnapshot.capture(md);
        sliceFromBaseline(md, bd, s, e, wpN, SLICE_AXIS_DRAG, Vec3(0,1,0), true);
        Mesh mc = makeCube(); auto bc = MeshSnapshot.capture(mc);
        sliceFromBaseline(mc, bc, s, e, wpN, cast(int)a, v, true);
        assert(md.vertices.length == mc.vertices.length,
               "classified-axis cut has the same vert count as the drag-mode cut");
        foreach (i; 0 .. md.vertices.length)
            assert(abs(md.vertices[i].x - mc.vertices[i].x) < 1e-6f &&
                   abs(md.vertices[i].y - mc.vertices[i].y) < 1e-6f &&
                   abs(md.vertices[i].z - mc.vertices[i].z) < 1e-6f,
                   "classified-axis cut is byte-identical to the drag-mode cut");
    }
    // Axis-aligned extrusion direction (+Y work plane ⇒ axis Y).
    assertRoundTrip(Vec3(0,0,-1), Vec3(0,0,1), Vec3(0,1,0));
    // Slanted extrusion direction ⇒ Custom; the Custom vector rebuilds it exactly.
    assertRoundTrip(Vec3(0,0,-1), Vec3(0,0,1), normalize(Vec3(0.4f, 1.0f, 0.0f)));
}

// ---------------------------------------------------------------------------
// OWNER FIX 2 (0284) — the overlay is a RECTANGLE biased LARGER across the line
// (the no-handle `perp` axis) than along it (the handle axis). For an in-plane
// line the perpendicular extent is STRICTLY greater than the along extent, while
// the along extent still equals the drawn segment exactly.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;
    Vec3 s = Vec3(0,0,-0.5f), e = Vec3(0,0,0.5f);   // a unit Z-line (length 1)
    Vec3 p, n, dir, perp;
    assert(planeForSlice(s, e, Vec3(0,1,0), SLICE_AXIS_DRAG, Vec3(0,1,0), p, n));
    assert(sliceOverlayBasis(s, e, n, dir, perp));
    Mesh cube = makeCube();
    float aMin, aMax, bMin, bMax;
    sliceOverlayExtent(cube, ModelSpace.world(), p, dir, perp, s, e, aMin, aMax, bMin, bMax);
    float along = aMax - aMin, across = bMax - bMin;
    // ALONG-line = the drawn segment exactly ([0,1]) — handles at its ends.
    assert(abs(aMin - 0.0f) < 1e-5f && abs(aMax - 1.0f) < 1e-5f,
           "along-line extent stays flush with the drawn segment");
    // PERPENDICULAR (no-handle) is STRICTLY larger — the plane extends past the
    // handles rather than reading as a thin square between them.
    assert(across > along + 1e-4f,
           "perpendicular-to-line extent must be strictly greater than along-line");
    // ...and still spans the mesh depth (±0.5) with room to spare.
    assert(bMax >= 0.5f && bMin <= -0.5f, "cross extent still spans the mesh");
}

// ---------------------------------------------------------------------------
// T8 (task 0619, doc/tool_aiming_item_transform_plan.md §1.2) — the overlay's
// mesh union is taken over where the vertices are DRAWN.
//
// THE PAIR, and the two wrong-but-plausible implementations it separates:
//
//   correct   union over `M*v`, obtained by carrying the plane into local:
//             `dot(v - M^-1 p, M^T perp)`
//   wrong (1) union over the raw `v` — the pre-0619 code, no transform at all
//   wrong (2) union over `dot(v - M^-1 p, M^-1 perp)` — `toLocalDir` used to
//             carry a NORMAL. Identical to the correct law for any rotation,
//             so a rotation-only fixture cannot see it.
//
// THE ORACLE, chosen so it re-derives nothing from the function under test:
// scanning the ALREADY-DRAWN geometry with an IDENTITY transform must produce
// byte-comparable extents to scanning the LOCAL geometry with `ms`. The
// padding/min-band law is thereby held constant on both sides and only the
// space question can move the numbers.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;
    import document : ItemXform;

    // Non-uniform scale is MANDATORY here (wrong (2) collapses onto the
    // correct law without it) and the rotation is deliberately not a multiple
    // of 90 degrees (a quarter turn maps a cube's vertex set to itself).
    ItemXform xf;
    xf.pos = Vec3( 1.30f, -0.60f, 0.40f);
    xf.rot = Vec3(11.0f,  40.0f, -7.0f);
    xf.scl = Vec3( 1.70f,  1.00f, 0.60f);
    const ModelSpace ms = xf.modelSpace();
    assert(!ms.isIdentity && ms.invertible);
    immutable float[16] M = xf.composedMatrix();

    // Geometry asymmetric on every axis — a plain cube would still work under
    // this M, but an asymmetric body removes any doubt that a coincidence of
    // the fixture (rather than the law) is what the assertions read.
    Mesh local = makeCube();
    foreach (i, ref v; local.vertices) {
        float k = cast(float)i;
        v = v + Vec3(0.13f * k, -0.07f * k * k * 0.1f, 0.21f * k);
    }
    // The SAME body, pre-drawn: vertices already through M, so an identity
    // ModelSpace scans exactly the drawn positions.
    Mesh drawn = makeCube();
    drawn.vertices = local.vertices.dup;
    foreach (ref v; drawn.vertices) v = transformPoint(M, v);

    // The drawn line runs mostly along Z and the work-plane normal is X, so
    // `perp` comes out X-dominant (`perp == cross(n, dir)` lands on the
    // component of the work-plane normal across the line). That matters: `M^T`
    // and `M^-1` differ on X by the ratio 1.7 : 1/1.7, whereas on Y — where a
    // Y-normal work plane would have put `perp` — `scl.y == 1` makes them
    // nearly agree and the second anti-vacuity check below only just separates.
    Vec3 s = Vec3(0.2f, 0.1f, -0.5f), e = Vec3(0.35f, -0.15f, 0.5f);
    Vec3 p, n, dir, perp;
    assert(planeForSlice(s, e, Vec3(1,0,0), SLICE_AXIS_DRAG, Vec3(1,0,0), p, n));
    assert(sliceOverlayBasis(s, e, n, dir, perp));

    float gaMin, gaMax, gbMin, gbMax;   // ground truth: drawn body, identity ms
    sliceOverlayExtent(drawn, ModelSpace.world(), p, dir, perp, s, e,
                       gaMin, gaMax, gbMin, gbMax);
    float aMin, aMax, bMin, bMax;       // under test: local body + ms
    sliceOverlayExtent(local, ms, p, dir, perp, s, e, aMin, aMax, bMin, bMax);

    assert(abs(bMin - gbMin) < 1e-4f && abs(bMax - gbMax) < 1e-4f,
        "the mesh union must be taken over the DRAWN vertices");
    // The along-line extent is a pure world construct (start/end only) and
    // must not have moved at all.
    assert(abs(aMin - gaMin) < 1e-6f && abs(aMax - gaMax) < 1e-6f,
        "the along-line extent is start/end only — the transform must not touch it");

    // ANTI-VACUITY (1): wrong (1), the pre-0619 no-transform law, must read a
    // materially different cross extent on this fixture.
    float wMin, wMax, junk0, junk1;
    sliceOverlayExtent(local, ModelSpace.world(), p, dir, perp, s, e,
                       junk0, junk1, wMin, wMax);
    assert(abs(wMax - gbMax) > 0.25f || abs(wMin - gbMin) > 0.25f,
        "fixture is vacuous: the untransformed union reads the same extent");

    // ANTI-VACUITY (2): wrong (2), `toLocalDir` on the plane normal. Computed
    // here rather than injected, because there is no way to pass a bad carry
    // through the API — which is the point of the API.
    Vec3 pL   = ms.toLocalPoint(p);
    Vec3 good = ms.toLocalNormal(perp);
    Vec3 bad  = ms.toLocalDir(perp);
    float gLo = float.infinity, gHi = -float.infinity;
    float bLo = float.infinity, bHi = -float.infinity;
    foreach (v; local.vertices) {
        float g = dot(v - pL, good), b = dot(v - pL, bad);
        if (g < gLo) gLo = g;  if (g > gHi) gHi = g;
        if (b < bLo) bLo = b;  if (b > bHi) bHi = b;
    }
    assert(abs(bHi - gHi) > 0.25f || abs(bLo - gLo) > 0.25f,
        "fixture is vacuous: carrying the normal with M^-1 reads the same union");
}

// ---------------------------------------------------------------------------
// CUSTOM-AXIS ROTATE GIZMO (task 0287) — the rotate-math kernel + the geometric
// invariants the ring drag must uphold: rotating the Custom `vector` about the
// drawn line by θ tilts the cut-plane normal by the SAME θ about the line, while
// BOTH endpoints stay in the plane and the line stays contained (n ⟂ line). The
// two drawn points never move. Pure — no GL context.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs, fabs, PI, cos, sin;

    // (a) Rodrigues basics: +Y about +X by +90° → +Z (right-handed).
    {
        Vec3 r = rotateVectorAboutAxis(Vec3(0,1,0), Vec3(1,0,0), cast(float)(PI/2));
        assert(fabs(r.x) < 1e-5f && fabs(r.y) < 1e-5f && fabs(r.z - 1.0f) < 1e-5f,
               "rotate +Y about +X by +90° = +Z");
    }
    // (a2) The axis component of a vector is preserved; length is preserved.
    {
        Vec3 v = Vec3(0.3f, 1.0f, 0.4f);
        Vec3 axis = normalize(Vec3(0.2f, 0.1f, 1.0f));
        Vec3 r = rotateVectorAboutAxis(v, axis, 0.7f);
        assert(fabs(r.length - v.length) < 1e-5f, "rotation preserves |v|");
        assert(fabs(dot(r, axis) - dot(v, axis)) < 1e-5f, "axis component preserved");
    }
    // (b) signedAngleAboutAxis round-trips against a known rotation.
    {
        Vec3 axis = normalize(Vec3(0.1f, 0.2f, 1.0f));
        Vec3 from = Vec3(1, 0, 0);
        // Make `from` ⟂ axis so the in-plane angle is exactly the applied one.
        from = normalize(from - axis * dot(from, axis));
        float theta = 0.6f;
        Vec3 to = rotateVectorAboutAxis(from, axis, theta);
        assert(fabs(signedAngleAboutAxis(from, to, axis) - theta) < 1e-5f,
               "signed angle recovers the applied rotation");
        assert(fabs(signedAngleAboutAxis(to, from, axis) + theta) < 1e-5f,
               "signed angle is antisymmetric");
    }

    // (c) THE LOAD-BEARING INVARIANT. A drawn line (start,end), a Custom vector
    //     not parallel to it, and the extrusion model normal = cross(lineDir,vec).
    //     Rotating `vec` about lineDir by θ must rotate the NORMAL by θ about
    //     lineDir, keep both endpoints in the plane, and keep n ⟂ line — for a
    //     sweep of angles — and planeForSlice(Custom, vec') must agree.
    static void checkTilt(Vec3 start, Vec3 end, Vec3 vec0, float theta) {
        Vec3 lineDir = normalize(end - start);
        // Baseline plane from the frozen vector.
        Vec3 p0, n0;
        assert(planeForSlice(start, end, Vec3(0,1,0), cast(int)SliceAxis.Custom, vec0, p0, n0),
               "baseline Custom plane is well-defined (vec not ∥ line)");
        // Tilt the vector about the line, exactly what the gizmo drag does.
        Vec3 vec1 = rotateVectorAboutAxis(vec0, lineDir, theta);
        Vec3 p1, n1;
        assert(planeForSlice(start, end, Vec3(0,1,0), cast(int)SliceAxis.Custom, vec1, p1, n1),
               "tilted Custom plane is well-defined");
        // n ⟂ line, and BOTH endpoints lie in the tilted plane (the line stays).
        assert(fabs(dot(n1, lineDir)) < 1e-5f, "tilted normal ⟂ the line");
        assert(fabs(dot(start - p1, n1)) < 1e-5f, "Start stays in the tilted plane");
        assert(fabs(dot(end   - p1, n1)) < 1e-5f, "End stays in the tilted plane");
        // The through-point p is start for both (the endpoints never move).
        assert(fabs((p1 - p0).length) < 1e-6f, "through-point (= Start) unchanged");
        // The NORMAL rotated by EXACTLY θ about the line: signed angle n0→n1 = θ
        // (both n0, n1 are ⟂ lineDir, so the in-plane signed angle is exact).
        float measured = signedAngleAboutAxis(n0, n1, lineDir);
        // Compare on the circle (fold to (-π,π]); a straight diff handles the
        // moderate angles swept here.
        assert(fabs(measured - theta) < 1e-4f,
               "plane normal tilts by exactly the applied angle about the line");
    }
    // A slanted line + an oblique Custom vector, swept across several angles.
    Vec3 s = Vec3(-0.7f, -0.4f, 0.3f), e = Vec3(0.7f, 0.4f, -0.3f);
    Vec3 vec0 = Vec3(0.3f, 1.0f, 0.4f);
    foreach (k; 0 .. 7) {
        float theta = -0.9f + 0.3f * k;   // −0.9 … +0.9 rad
        checkTilt(s, e, vec0, theta);
    }
    // An axis-aligned line too (X-line, vector with a Y/Z tilt).
    checkTilt(Vec3(-1,0,0), Vec3(1,0,0), Vec3(0, 1, 0.5f), 0.5f);
    checkTilt(Vec3(-1,0,0), Vec3(1,0,0), Vec3(0, 1, 0.5f), -0.8f);
}
