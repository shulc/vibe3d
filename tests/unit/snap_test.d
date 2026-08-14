// Module unittests for `snap`, moved verbatim out of source/snap.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.snap_test;

import std.math : sqrt, round, floor, isNaN;
import core.sync.mutex : Mutex;
import math : Vec3, Viewport, ModelSpace, projectionSpace, projectToWindowFull,
              screenRay, screenPointToRay,
              rayPlaneIntersect, pointInPolygon2D,
              closestOnSegment2DSquared, closestOnSegmentToRay, cross, dot,
              closestPointOnLineToRay, isOrtho, viewPixelScale,
              perpendicularFrame, rayTriangleIntersect,
              closestPointOnTriangle2D, triangulatePolygonEarClip;
import mesh : Mesh;
import toolpipe.packets : SnapPacket, SnapType, SnapMode;
import toolpipe.guide   : SnapGuide, kGuidePrioritySeed;
import perf_probe : g_perf, Cat;
import constraint : BackgroundSource;
import toolpipe.guide : GuideDrawState;
import snap;

// ---------------------------------------------------------------------------
// The client admission predicate: neutral when absent, and load-bearing in
// the one order that matters.
//
// `snapCursor`'s trailing `admit` is the seam between the SERVICE (which grids
// to query, how a candidate projects, how the winner is ranked — this module's,
// shared by every caller) and the CLIENT'S POLICY (which candidates are
// eligible at all — the caller's, and different between callers). Three
// obligations, one assertion block each:
//
//   1. NEUTRALITY. The same query with `admit` absent and with a permissive
//      `admit` must agree field-for-field. That is what makes this parameter a
//      no-op for every existing call site: none of them pass a predicate, so
//      all of them take the `admit is null` branch, which is the pre-existing
//      walk verbatim.
//   2. REJECTION. A predicate that admits nothing must produce the clean
//      pass-through — asserted here to be the SAME result a disabled snap
//      produces, field-for-field, which is the strongest available statement
//      of "as if no candidate had been enumerated".
//   3. ORDER. The rejection happens before the distance compare, not after the
//      winner is picked. Rejecting the nearest candidate must PROMOTE the
//      runner-up, never veto the snap: a rejected candidate that could still
//      lower the accumulator would silently suppress an admissible candidate
//      standing behind it. This is the assertion that would fail if the check
//      were moved past the `d < bestDist` accumulator.
//
// The fixture is four collinear vertices with NO faces, so `needVis` is false
// and no visibility gate can reorder the ranking: what the assertions observe
// is pure screen distance, which is the property under test.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI;

    // This module's other unittests populate the slot-0 grids from their own
    // meshes; a fresh local Mesh can land on a recycled stack address with the
    // same (zero) mutationVersion, so drop the grids rather than rely on the
    // staleness key noticing.
    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    Mesh m;
    m.vertices = [
        Vec3( 0.00f, 0, 0),   // 0 — directly under the cursor pixel
        Vec3( 0.25f, 0, 0),   // 1 — the runner-up, still inside acceptance
        Vec3( 0.50f, 0, 0),   // 2 — inside the gather range, outside acceptance
        Vec3(-3.00f, 0, 0),   // 3 — outside the gather range entirely
    ];

    // The cursor pixel is vertex 0's own projection, so its screen distance is
    // exactly zero and the ranking below is unambiguous.
    float px0, py0, ndc0;
    assert(projectToWindowFull(m.vertices[0], vp, px0, py0, ndc0),
        "fixture: vertex 0 must project on-screen");
    immutable int sx = cast(int)round(px0);
    immutable int sy = cast(int)round(py0);

    float pixDist(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every candidate must project on-screen");
        immutable float dx = qx - cast(float)sx;
        immutable float dy = qy - cast(float)sy;
        return sqrt(dx * dx + dy * dy);
    }

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.enabledTypes = SnapType.Vertex;   // discrete tier only, one type
    cfg.snapScope    = SnapMode.Global;
    cfg.innerRangePx = 30.0f;
    cfg.outerRangePx = 100.0f;

    // State the fixture's premises rather than trusting the arithmetic above:
    // strictly increasing distances, with the acceptance boundary falling
    // between vertex 1 and vertex 2 and the gather boundary between 2 and 3.
    immutable float d0 = pixDist(m.vertices[0]);
    immutable float d1 = pixDist(m.vertices[1]);
    immutable float d2 = pixDist(m.vertices[2]);
    immutable float d3 = pixDist(m.vertices[3]);
    assert(d0 < d1 && d1 < d2 && d2 < d3,
        "fixture: the four candidates must rank strictly by screen distance");
    assert(d1 < cfg.innerRangePx,
        "fixture: vertex 1 must be close enough to SNAP once 0 is rejected");
    assert(d2 > cfg.innerRangePx && d2 < cfg.outerRangePx,
        "fixture: vertex 2 must HIGHLIGHT but not snap once 0 and 1 are rejected");
    assert(d3 > cfg.outerRangePx,
        "fixture: vertex 3 must be out of the gather range in every case");

    // Deliberately not any vertex position: the pass-through assertions below
    // are only meaningful if the input is distinguishable from every candidate.
    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);

    static bool sameVec(Vec3 a, Vec3 b) {
        return a.x == b.x && a.y == b.y && a.z == b.z;
    }
    // Field-for-field, spelled out rather than `a == b`, so a failure names
    // WHICH field diverged and so a later field added to SnapResult shows up
    // here as a compile-time-visible omission rather than silently unchecked.
    static bool sameResult(SnapResult a, SnapResult b) {
        return sameVec(a.worldPos, b.worldPos)
            && sameVec(a.highlightPos, b.highlightPos)
            && a.snapped        == b.snapped
            && a.highlighted    == b.highlighted
            && a.targetType     == b.targetType
            && a.targetIndex    == b.targetIndex
            && a.targetSource   == b.targetSource
            && a.constraintType == b.constraintType;
    }

    // --- baseline: no predicate at all, i.e. every existing call site --------
    SnapResult bare = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
    assert(bare.snapped,        "baseline: vertex 0 sits under the cursor");
    assert(bare.targetType  == SnapType.Vertex);
    assert(bare.targetIndex == 0);
    assert(bare.targetSource == 0);
    assert(sameVec(bare.worldPos, m.vertices[0]));

    // --- 1. NEUTRALITY: permissive predicate == no predicate ----------------
    // The predicate doubles as an observation channel: it sees exactly what
    // the enumeration offered, which is how the count below is known.
    int offered;
    SnapResult permissive = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
        (SnapType t, int i, int s) { ++offered; return true; });
    assert(sameResult(bare, permissive),
        "S1 neutrality: a predicate that admits everything must reproduce the "
        ~ "no-predicate result field-for-field");
    assert(offered >= 3,
        "the ordering assertions below are only meaningful if the enumeration "
        ~ "actually offered the runner-ups");

    // --- 2. REJECTION: admitting nothing == snapping switched off -----------
    SnapResult admitNone = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
        (SnapType t, int i, int s) => false);
    SnapPacket offCfg = cfg;
    offCfg.enabled = false;
    SnapResult disabled = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), offCfg);
    assert(sameResult(admitNone, disabled),
        "S1 rejection: a predicate that admits nothing must be the same clean "
        ~ "pass-through as `cfg.enabled == false`");
    assert(sameVec(admitNone.worldPos, cursorWorld));
    assert(!admitNone.snapped && !admitNone.highlighted);
    assert(admitNone.targetIndex == -1);
    assert(admitNone.targetType == SnapType.None);

    // --- 3. ORDER: rejecting the winner promotes the runner-up --------------
    SnapResult noV0 = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
        (SnapType t, int i, int s) => !(t == SnapType.Vertex && i == 0 && s == 0));
    assert(noV0.snapped,
        "S1 order: rejecting the nearest candidate must hand the snap to the "
        ~ "runner-up, not cancel it — a rejected candidate must not be able to "
        ~ "lower the accumulator it was rejected from");
    assert(noV0.targetIndex == 1);
    assert(sameVec(noV0.worldPos, m.vertices[1]));

    // ...and rejecting BOTH accepted candidates leaves the third, which is
    // inside the gather range and outside acceptance: highlight, no snap. The
    // accumulator was genuinely re-ranked, not merely filtered at the end.
    SnapResult noV01 = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null,
        (SnapType t, int i, int s) =>
            !(t == SnapType.Vertex && (i == 0 || i == 1)));
    assert(!noV01.snapped && noV01.highlighted);
    assert(noV01.targetIndex == 2);
    assert(sameVec(noV01.highlightPos, m.vertices[2]));
    assert(sameVec(noV01.worldPos, cursorWorld),
        "a highlight-only result still passes the input position through");

    // --- the tie-break is part of "the same result" -------------------------
    // Two candidates at an exactly equal screen distance: `consider`'s strict
    // `<` gives the win to the first VISITED, and the grid hands candidates
    // over in ascending index order, so the lower index takes it. That rule is
    // as much a part of the result as the position is, so it gets stated on
    // both sides of the seam rather than left to the general equality above
    // (which the ranked fixture can never exercise).
    // Coincident vertices, not a mirrored pair: a mirrored pair is only a tie
    // up to floating-point luck in the projection, while two candidates at the
    // SAME world point tie by construction. It is also the honest case — an
    // unwelded duplicate is exactly where "which of these two wins" decides
    // what a weld does.
    Mesh tie;
    tie.vertices = [
        Vec3(0.25f, 0, 0),   // 0 — wins the tie by index
        Vec3(0.25f, 0, 0),   // 1 — the unwelded duplicate
    ];
    invalidateSnapGrids();
    assert(pixDist(tie.vertices[0]) == pixDist(tie.vertices[1]),
        "fixture: the two candidates must be an EXACT screen-distance tie, "
        ~ "otherwise this block tests ranking, not tie-breaking");
    assert(pixDist(tie.vertices[0]) < cfg.innerRangePx,
        "fixture: the tied pair must be close enough to snap");

    SnapResult tieBare = snapCursor(cursorWorld, sx, sy, vp, tie, ModelSpace.world(), cfg);
    assert(tieBare.snapped && tieBare.targetIndex == 0,
        "the tie goes to the lower index");
    SnapResult tiePermissive = snapCursor(cursorWorld, sx, sy, vp, tie, ModelSpace.world(), cfg, null,
        (SnapType t, int i, int s) => true);
    assert(sameResult(tieBare, tiePermissive),
        "S1 neutrality: a tie must break the same way with a permissive "
        ~ "predicate as with none");

    SnapResult tieNoV0 = snapCursor(cursorWorld, sx, sy, vp, tie, ModelSpace.world(), cfg, null,
        (SnapType t, int i, int s) => !(t == SnapType.Vertex && i == 0));
    assert(tieNoV0.snapped && tieNoV0.targetIndex == 1,
        "rejecting the side of the tie that won hands it to the other side");

    invalidateSnapGrids();

    // --- the constraint tier carries the same seam --------------------------
    // Constraint candidates are line/plane hits, not mesh elements, so the
    // predicate sees (type, -1, 0). Aimed at a pixel where a world axis is
    // exactly under the cursor and the view ray is not parallel to it.
    float pxa, pya, ndca;
    assert(projectToWindowFull(Vec3(1, 0, 0), vp, pxa, pya, ndca));
    immutable int ax = cast(int)round(pxa);
    immutable int ay = cast(int)round(pya);

    SnapPacket ccfg = cfg;
    ccfg.enabledTypes = SnapType.WorldAxis;   // constraint tier only

    SnapResult cBare = snapCursor(cursorWorld, ax, ay, vp, m, ModelSpace.world(), ccfg);
    assert(cBare.snapped && cBare.constraintType == SnapType.WorldAxis,
        "fixture: a world-axis constraint must fire at this pixel, otherwise "
        ~ "the constraint-tier assertions below are vacuous");

    SnapResult cPermissive = snapCursor(cursorWorld, ax, ay, vp, m, ModelSpace.world(), ccfg, null,
        (SnapType t, int i, int s) => true);
    assert(sameResult(cBare, cPermissive),
        "S1 neutrality holds in the constraint tier too");

    int constraintOffered;
    SnapResult cNone = snapCursor(cursorWorld, ax, ay, vp, m, ModelSpace.world(), ccfg, null,
        (SnapType t, int i, int s) {
            ++constraintOffered;
            assert(i == -1 && s == 0,
                "a constraint candidate has no element index and no source");
            return false;
        });
    assert(constraintOffered >= 1, "fixture: the axis lines must be offered");
    assert(!cNone.snapped);
    assert(cNone.constraintType == SnapType.None);
    assert(sameVec(cNone.worldPos, cursorWorld));
}

// ---------------------------------------------------------------------------
// THE SELF-REFERENCE RULE: no element that MOVES with the drag may be a snap
// candidate for it (`kindExcluded`, and the exclusion `move.d` builds at
// `applySnapToDelta`).
//
// The exclusion was written to stop one thing — "a single-vert drag always
// snaps to its own (zero-distance) projected pixel" — and the rule it was
// written as, "excluded iff ALL its incident verts are dragged", delivers that
// for the Vertex type ALONE. Everything below is a candidate the OLD rule kept
// live during a single-vertex drag, and every one of them is the same defect
// the exclusion exists to prevent, wearing a different type tag:
//
//   1. EDGE CENTRE of an incident edge — recomputed from the MOVING endpoint
//      every frame, so it trails the drag at half speed.
//   2. EDGE, as a segment — its closest point to the cursor IS the dragged
//      endpoint at ~0 px, so the snap answers with the drag's own anchor and
//      the drag freezes.
//   3. POLYGON CENTRE of an incident face, at 1/n of the drag speed.
//   4. POLYGON, as a surface — closest point on a face one of whose corners is
//      being dragged.
//
// Each block below is written to fail on the ALL rule and pass on ANY, and
// each carries its own positive control: the SAME query with an empty
// exclusion must still find the candidate. Without that control a block would
// also "pass" if the fixture simply never reached the candidate.
//
// The fixture keeps ONE type enabled at a time so a single candidate walk
// decides each assertion, and gives the excluded element a far-away sibling
// that is deliberately OUTSIDE the gather range — so "did not snap" means the
// exclusion dropped it, not that something else won.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI;

    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    // Not any candidate's position: a pass-through `worldPos` must be
    // distinguishable from a snapped one.
    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);

    // The drag moves vertex 0 and nothing else — the single-vertex drag the
    // exclusion comment names.
    immutable uint[] dragged = [0u];

    int[2] pixelOf(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: the probe point must project on-screen");
        return [cast(int)round(qx), cast(int)round(qy)];
    }

    // --- 1 + 2: EDGE CENTRE and EDGE, on a face-less wire ------------------
    // No faces ⇒ `needVis` is false ⇒ ranking is pure screen distance and the
    // occlusion gate cannot silently do the excluding for us.
    {
        Mesh m;
        m.vertices = [
            Vec3(0.0f, 0, 0),   // 0 — dragged
            Vec3(1.0f, 0, 0),   // 1
            Vec3(3.0f, 0, 0),   // 2
        ];
        m.edges = [[0u, 1u], [1u, 2u]];

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        // 30, not 40, and the constant is the fixture's isolation rather than
        // a taste: vertex 1 projects 40.0 px from the cursor these blocks use,
        // so at 40 the sibling edge grazes the gather boundary from the inside
        // (`d > outerRangePx` is false at exactly equal). That was harmless
        // while a centre was its own candidate — edge 1's CENTRE is 120 px out
        // — and stopped being harmless when the centre became a refinement of
        // an elected EDGE, because it is the edge's near END that gets
        // gathered. 30 puts the whole sibling outside, which is what the block
        // header has always claimed the fixture does. The guard below now pins
        // that quantity instead of the centre's.
        cfg.innerRangePx = 30.0f;
        cfg.outerRangePx = 30.0f;

        // --- 1. EDGE CENTRE ------------------------------------------------
        cfg.enabledTypes = SnapType.EdgeCenter;
        immutable Vec3 c01 = Vec3(0.5f, 0, 0);          // edge 0's centre
        auto pc = pixelOf(c01);

        invalidateSnapGrids();
        SnapResult ctl = snapCursor(cursorWorld, pc[0], pc[1], vp, m, ModelSpace.world(), cfg);
        assert(ctl.snapped && ctl.targetType == SnapType.EdgeCenter
            && ctl.targetIndex == 0,
            "positive control: with NOTHING excluded the cursor sits on edge "
            ~ "0's centre and must snap to it — otherwise the exclusion "
            ~ "assertion below would pass for the wrong reason");
        assert(pixelOf(m.vertices[1])[0] - pc[0] > cfg.outerRangePx,
            "fixture: the sibling edge's NEAREST END must be outside the "
            ~ "gather range — not merely its centre — so a miss below means "
            ~ "the exclusion fired and not that a sibling won. The near end is "
            ~ "the right quantity because the leg is elected on the ON-EDGE "
            ~ "point and the centre only refines it afterwards");

        invalidateSnapGrids();
        SnapResult r = snapCursor(cursorWorld, pc[0], pc[1], vp, m, ModelSpace.world(), cfg, dragged);
        assert(!r.snapped,
            "an edge with ONE dragged endpoint moves with the drag: its centre "
            ~ "is recomputed from the moving coordinate every frame and trails "
            ~ "the gizmo at half speed. It is the drag's own geometry and must "
            ~ "not be a candidate for it");
        assert(r.targetType == SnapType.None && r.targetIndex == -1,
            "...and it must not be offered as a HIGHLIGHT either: a rejected "
            ~ "candidate is as if it were never enumerated");

        // --- 2. EDGE as a segment — the freeze ------------------------------
        cfg.enabledTypes = SnapType.Edge;
        auto pv = pixelOf(m.vertices[0]);   // the cursor is ON the dragged vert

        invalidateSnapGrids();
        SnapResult ectl = snapCursor(cursorWorld, pv[0], pv[1], vp, m, ModelSpace.world(), cfg);
        assert(ectl.snapped && ectl.targetType == SnapType.Edge
            && ectl.targetIndex == 0
            && ectl.worldPos.x == m.vertices[0].x
            && ectl.worldPos.y == m.vertices[0].y
            && ectl.worldPos.z == m.vertices[0].z,
            "positive control, and the defect stated as a measurement: the "
            ~ "closest point on the incident edge IS the dragged vertex, so an "
            ~ "unexcluded edge answers the query with the drag's own anchor — "
            ~ "delta becomes zero and the drag freezes");

        invalidateSnapGrids();
        SnapResult er = snapCursor(cursorWorld, pv[0], pv[1], vp, m, ModelSpace.world(), cfg, dragged);
        assert(!er.snapped,
            "the freeze is what the exclusion is FOR: an edge incident to the "
            ~ "dragged vertex must not be able to hand the drag its own anchor "
            ~ "back");
        assert(er.worldPos.x == cursorWorld.x && er.worldPos.y == cursorWorld.y
            && er.worldPos.z == cursorWorld.z,
            "...and a miss passes the input through unchanged, so the caller's "
            ~ "delta survives");
    }

    // --- 3 + 4: POLYGON CENTRE and POLYGON, on a quad ----------------------
    {
        Mesh m;
        m.vertices = [
            Vec3(-1, -1, 0),   // 0 — dragged
            Vec3( 1, -1, 0),   // 1
            Vec3( 1,  1, 0),   // 2
            Vec3(-1,  1, 0),   // 3
        ];
        m.addFace([0u, 1u, 2u, 3u]);

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.innerRangePx = 40.0f;
        cfg.outerRangePx = 40.0f;

        // The quad's centroid, i.e. the polygon centre AND a point on the
        // polygon surface — one cursor pixel serves both blocks.
        auto pc = pixelOf(Vec3(0, 0, 0));

        // --- 3. POLYGON CENTRE ---------------------------------------------
        cfg.enabledTypes = SnapType.PolyCenter;

        invalidateSnapGrids();
        SnapResult ctl = snapCursor(cursorWorld, pc[0], pc[1], vp, m, ModelSpace.world(), cfg);
        assert(ctl.snapped && ctl.targetType == SnapType.PolyCenter
            && ctl.targetIndex == 0,
            "positive control: the face is front-facing and unoccluded, so its "
            ~ "centre is a live candidate with nothing excluded");

        invalidateSnapGrids();
        SnapResult r = snapCursor(cursorWorld, pc[0], pc[1], vp, m, ModelSpace.world(), cfg, dragged);
        assert(!r.snapped,
            "a face with one dragged corner has a centroid that follows the "
            ~ "drag at 1/n of its speed, and the gizmo is pulled after its own "
            ~ "tail");

        // --- 4. POLYGON as a surface ---------------------------------------
        cfg.enabledTypes = SnapType.Polygon;

        invalidateSnapGrids();
        SnapResult pctl = snapCursor(cursorWorld, pc[0], pc[1], vp, m, ModelSpace.world(), cfg);
        assert(pctl.snapped && pctl.targetType == SnapType.Polygon
            && pctl.targetIndex == 0,
            "positive control: the cursor is over the face's interior");

        invalidateSnapGrids();
        SnapResult pr = snapCursor(cursorWorld, pc[0], pc[1], vp, m, ModelSpace.world(), cfg, dragged);
        assert(!pr.snapped,
            "the surface of a face being deformed by the drag is the drag's "
            ~ "own geometry too — the rule is about MOVING, not about which "
            ~ "type tag the candidate carries");
    }

    // --- 5. …and the rule still admits everything that does NOT move -------
    // The exclusion must be a scalpel, not a curtain: dropping the whole mesh
    // whenever anything is dragged would also pass every assertion above.
    {
        Mesh m;
        m.vertices = [
            Vec3(0.0f, 0, 0),   // 0 — dragged
            Vec3(0.2f, 0, 0),   // 1 — shares edge 0 with the dragged vert
            Vec3(0.4f, 0, 0),   // 2 — shares NOTHING with it
            Vec3(0.6f, 0, 0),   // 3
        ];
        m.edges = [[0u, 1u], [2u, 3u]];

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.innerRangePx = 200.0f;
        cfg.outerRangePx = 200.0f;
        cfg.enabledTypes = SnapType.EdgeCenter;

        auto pc = pixelOf(Vec3(0.1f, 0, 0));   // edge 0's centre: excluded

        invalidateSnapGrids();
        SnapResult r = snapCursor(cursorWorld, pc[0], pc[1], vp, m, ModelSpace.world(), cfg, dragged);
        assert(r.snapped && r.targetType == SnapType.EdgeCenter
            && r.targetIndex == 1,
            "edge 1 shares no vertex with the drag, so it does not move with "
            ~ "it and stays a candidate — the exclusion removes the drag's own "
            ~ "geometry and nothing else");

        // And a lone vertex that is not dragged is still a vertex candidate.
        cfg.enabledTypes = SnapType.Vertex;
        invalidateSnapGrids();
        SnapResult v = snapCursor(cursorWorld, pc[0], pc[1], vp, m, ModelSpace.world(), cfg, dragged);
        assert(v.snapped && v.targetType == SnapType.Vertex && v.targetIndex == 1,
            "the Vertex type is the one the old rule already protected, and it "
            ~ "must keep behaving exactly as it did: vertex 0 excluded, vertex "
            ~ "1 (the nearest survivor) wins");
    }

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// THE SHIPPED DEFAULT SNAPS TO A VERTEX, AND IT DOES SO BECAUSE VERTEX IS THE
// ONLY TYPE ON.
//
// This is the behavioural half of the default change; the arithmetic half (the
// stage's field agreeing with the packet's) is pinned in
// `toolpipe/stages/snap.d`. What is asserted here is the thing a user actually
// reported: a drag near a vertex must stick to THAT VERTEX.
//
// The fixture is built so the assertion cannot pass by luck. A grid point is
// placed STRICTLY NEARER the cursor than the vertex is — 1.6 px against 6.4 px
// — so if Grid were in the default set it would win on `consider`'s bare
// `d < bestDist` ranking, which has no per-type priority to save the vertex.
// That is exactly how the old default (Vertex|EdgeCenter|PolyCenter|Grid)
// failed in the field: the vertex candidate was generated and then silently
// outranked by a lattice point that is never further than half a cell away.
//
// The second half of the test is the claim that this was a DEFAULT change and
// not a MODEL change: turning Grid back on explicitly must restore the old
// outcome. If someone ever "simplifies" `enabledTypes` from a set to a
// single-valued enum, that half stops compiling or stops passing — which is
// the intent, because the reference's own UI is a per-type boolean set
// (twelve types x three scopes) and the set shape is the part we match.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI, round, abs;

    invalidateSnapGrids();

    // Looking straight down the +Y axis at the y=0 workplane, so the default
    // workplane (centre origin, normal +Y, axes X / Z) is seen face-on and
    // screen distance is a clean multiple of world distance.
    Viewport vp;
    vp.eye    = Vec3(0, 5, 0);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 0, -1));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    // One vertex, deliberately OFF the lattice: 0.1 world units from the grid
    // point at (2,0,0). No faces, so no visibility gate can reorder anything.
    Mesh m;
    m.vertices = [ Vec3(2.1f, 0, 0) ];

    float pixDist(Vec3 a, Vec3 b) {
        float ax, ay, az, bx, by, bz;
        assert(projectToWindowFull(a, vp, ax, ay, az)
            && projectToWindowFull(b, vp, bx, by, bz),
            "fixture: both points must project on-screen");
        return sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));
    }

    // The cursor sits between the grid point and the vertex, but NEARER the
    // grid point — the whole point of the fixture.
    immutable Vec3 cursorWorld = Vec3(2.02f, 0, 0);
    immutable Vec3 gridWorld   = Vec3(2.0f,  0, 0);
    float cx, cy, cz;
    assert(projectToWindowFull(cursorWorld, vp, cx, cy, cz),
        "fixture: the cursor point must project on-screen");
    immutable int sx = cast(int)round(cx);
    immutable int sy = cast(int)round(cy);

    // THE SHIPPED DEFAULT, taken from the packet rather than hand-written, so
    // this test tracks the default instead of restating it.
    SnapPacket cfg;
    cfg.enabled = true;
    assert(cfg.enabledTypes == SnapType.Vertex,
        "the shipped default target set is Vertex and nothing else — if this "
        ~ "fails the default changed, and the two assertions below are no "
        ~ "longer testing what they claim");

    // State the fixture's premises rather than trusting the arithmetic.
    immutable float dGrid = pixDist(gridWorld,     cursorWorld);
    immutable float dVert = pixDist(m.vertices[0], cursorWorld);
    assert(dGrid < dVert,
        "fixture: the grid point must be STRICTLY NEARER than the vertex, or "
        ~ "the vertex would win even with Grid enabled and the test would "
        ~ "prove nothing");
    assert(dVert < cfg.innerRangePx,
        "fixture: the vertex must be inside the acceptance radius, or it "
        ~ "could not snap under any configuration");

    // 1. THE DEFAULT. Vertex wins despite being the FURTHER candidate,
    //    because the nearer one is a type nobody turned on.
    SnapResult r = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg, null);
    assert(r.snapped && r.targetType == SnapType.Vertex && r.targetIndex == 0,
        "under the shipped default a drag near a vertex must stick to that "
        ~ "vertex — a nearer grid point must not be able to steal it, because "
        ~ "Grid is not in the default set");

    // 2. THE BIT IS STILL REACHABLE. This was a default change, not a model
    //    change: the set still has a Grid bit and turning it on still works.
    SnapPacket withGrid = cfg;
    withGrid.enabledTypes = SnapType.Vertex | SnapType.Grid;
    invalidateSnapGrids();
    SnapResult g = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), withGrid, null);
    assert(g.snapped && g.targetType == SnapType.Grid,
        "enabling Grid explicitly must restore the old outcome — the nearer "
        ~ "lattice point wins. `enabledTypes` is a SET and every bit stays "
        ~ "reachable; only the factory contents changed");

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// TASK 0551 — THE CROSS-TYPE CASCADE, CLAUSE BY CLAUSE.
//
// The comparator is the whole of the type priority, so it is pinned directly
// rather than only through `snapCursor`. Each case below names the BEHAVIOUR
// it pins, not the clause it happens to exit through — as the function's own
// docstring records, clauses 2, 3 and 4 are early-outs that the last two
// subsume for any non-negative distance, so "this case proves clause 4 exists"
// would be a claim the fixture cannot support.
//
// The distances are the ones the behavioural test below actually produces, so
// the two halves cannot drift apart: 16.49 px to the vertex, 4.00 px to the
// incident edge, and an 8.0 px base.
// ---------------------------------------------------------------------------
unittest {
    immutable float base = kCandidateToleranceBasePx;          // 8
    immutable float tolV = kVertexToleranceScale * base;  // 16
    immutable float A    = kAbsentClassDist;

    // No candidate of my class — nothing else can rescue it.
    {
        bool[3]  has  = [false, true, true];
        float[3] d    = [A, 1.0f, 2.0f];
        assert(!cascadeClassWins(kCascadeVertex, has, d, tolV),
            "a class with no candidate cannot win, however generous its "
            ~ "tolerance");
    }

    // Sole class. This is what every single-type configuration resolves to,
    // and it is what makes the split accumulator neutral.
    {
        bool[3]  has  = [true, false, false];
        float[3] d    = [37.0f, A, A];
        assert(cascadeClassWins(kCascadeVertex, has, d, tolV),
            "the only class with a candidate wins at ANY distance — the "
            ~ "acceptance range is applied later, by the merge, not here");
        assert(!cascadeClassWins(kCascadeEdge, has, d, base));
        assert(!cascadeClassWins(kCascadePolygon, has, d, base));
    }

    // Nearest of the three — wins with no help from the tolerance at all.
    {
        bool[3]  has  = [true, true, true];
        float[3] d    = [1.0f, 2.0f, 3.0f];
        assert(cascadeClassWins(kCascadeVertex, has, d, 0.0f),
            "the nearest class wins even with a ZERO tolerance");
    }

    // THE REPORTED CASE, and the one place the 2x multiplier is observable.
    //
    // With no polygon candidate the last clause is vacuously true (that is
    // what the finite sentinel buys), so the vertex loses ONLY through clause
    // 5: it must trail the edge by at least its own tolerance. 12.49 px of
    // trail is more than the single base and less than the doubled one.
    {
        bool[3]  has  = [true, true, false];
        float[3] d    = [16.4924f, 4.0f, A];
        immutable float trail = d[kCascadeVertex] - d[kCascadeEdge];
        assert(trail > base && trail < tolV,
            "fixture: the vertex must trail by MORE than one base and LESS "
            ~ "than the doubled tolerance, or this case cannot tell the "
            ~ "multiplier from 1.0");
        assert(cascadeClassWins(kCascadeVertex, has, d, tolV),
            "at the doubled tolerance the farther vertex wins — this is the "
            ~ "type priority, and the reported behaviour");
        assert(!cascadeClassWins(kCascadeVertex, has, d, base),
            "at a SINGLE base it loses. The multiplier is not decoration: "
            ~ "these two lines differ only by it");
    }

    // The third class stops being vacuous the moment a polygon candidate
    // exists, and the answer flips back to the edge. This is why the absent-
    // class distance is a finite sentinel and not infinity: `d[i] - d[k]`
    // must come out hugely negative, not NaN.
    {
        bool[3]  has  = [true, true, true];
        float[3] d    = [16.4924f, 4.0f, 0.0f];
        assert(!cascadeClassWins(kCascadeVertex, has, d, tolV),
            "with a polygon under the cursor the vertex now trails one of the "
            ~ "other two by more than its tolerance, and loses");
        assert(cascadeClassWins(kCascadeEdge, has, d, base),
            "and the edge takes it on its own tolerance");
    }
}

// ---------------------------------------------------------------------------
// TASK 0551 — THE BEHAVIOUR A USER REPORTED: A VERTEX MUST BEAT THE EDGE THAT
// RUNS THROUGH IT.
//
// The geometry is the complaint's geometry and it is not incidental. Our edge
// candidate is the closest point on the projected SEGMENT, so for any edge
// incident to the target vertex that point is never FARTHER from the cursor
// than the vertex is — with equality only when the cursor sits exactly on the
// vertex pixel. Under the bare "nearest wins" that used to rank the discrete
// tier, the vertex therefore could not win: it could only tie, and it won the
// tie by being enumerated first. Every cursor position that is not exactly on
// the vertex went to the edge.
//
// This test is RED before the cascade (it resolves to Edge) and green after.
//
// The reporting user runs with vertex AND edge both enabled, which is why the
// shipped single-type default does not conceal this — the fixture turns both
// on explicitly, exactly as their configuration does.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI, round, abs;

    invalidateSnapGrids();

    // 80 px per world unit at z = 0: screen = (400 + 80x, 400 - 80y).
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    // One edge along +X. Vertex 0 is the target; the edge runs out of it.
    Mesh m;
    m.vertices = [ Vec3(0, 0, 0), Vec3(1, 0, 0) ];
    m.edges    = [ [0u, 1u] ];

    float[2] pixelOf(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every fixture point must project on-screen");
        return [qx, qy];
    }

    // The cursor is off the vertex along the edge AND off the edge line, so
    // the two candidates are at genuinely different distances.
    immutable Vec3 cursorWorld = Vec3(0.2f, 0.05f, 0);
    auto cpix = pixelOf(cursorWorld);
    immutable int sx = cast(int)round(cpix[0]);
    immutable int sy = cast(int)round(cpix[1]);

    // State the premises instead of trusting them.
    auto vpix = pixelOf(m.vertices[0]);
    immutable float dVert = sqrt((vpix[0] - sx) * (vpix[0] - sx)
                               + (vpix[1] - sy) * (vpix[1] - sy));
    auto epixA = pixelOf(m.vertices[0]);
    auto epixB = pixelOf(m.vertices[1]);
    float t;
    immutable float dEdge = sqrt(closestOnSegment2DSquared(
        cast(float)sx, cast(float)sy, epixA[0], epixA[1], epixB[0], epixB[1], t));

    assert(dEdge < dVert,
        "fixture: the edge must be STRICTLY nearer, or the vertex would win "
        ~ "under the old distance rule too and this test would prove nothing");

    immutable float base  = kCandidateToleranceBasePx;
    immutable float trail = dVert - dEdge;
    assert(trail > base,
        "fixture: the vertex must trail by more than ONE base, or a scale of "
        ~ "1.0 would resolve it the same way and the multiplier would be "
        ~ "untested here");
    assert(trail < kVertexToleranceScale * base,
        "fixture: and by less than the DOUBLED tolerance, or nothing could "
        ~ "save the vertex");

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.enabledTypes = SnapType.Vertex | SnapType.Edge;   // the user's pair
    assert(dVert <= cfg.innerRangePx,
        "fixture: the vertex must be inside the acceptance range, or the "
        ~ "cascade could name it and the merge would still refuse to snap");
    assert(cfg.innerRangePx >= base,
        "fixture: the tolerance base is min(acceptance, hit size), and this "
        ~ "case assumes the hit size is the smaller");

    SnapResult r = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
    assert(r.snapped, "something must snap here — both candidates are in range");
    assert(r.targetType == SnapType.Vertex && r.targetIndex == 0,
        "a vertex inside its tolerance must beat the edge that runs through "
        ~ "it, even though that edge's nearest point is closer to the cursor. "
        ~ "Resolving Edge here is the bare nearest-wins rule this task "
        ~ "replaced");
    assert(r.worldPos.x == m.vertices[0].x
        && r.worldPos.y == m.vertices[0].y
        && r.worldPos.z == m.vertices[0].z,
        "and the snapped position must be the vertex itself");

    // NEUTRALITY, on this very fixture: with the vertex class switched off
    // there is no contest, the cascade's sole-class leg returns the edge's own
    // nearest, and the answer is the pre-cascade one at the pre-cascade
    // distance. A cascade that changed single-type configurations would fail
    // here, and every single-type test in this module is a further witness.
    SnapPacket edgeOnly = cfg;
    edgeOnly.enabledTypes = SnapType.Edge;
    invalidateSnapGrids();
    SnapResult e = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), edgeOnly);
    assert(e.snapped && e.targetType == SnapType.Edge && e.targetIndex == 0,
        "with only one cascade class enabled the merge must be exactly what "
        ~ "it always was");
    assert(abs(e.worldPos.y - 0.0f) < 1e-6f,
        "and the edge's snapped point is the closest point ON the segment");

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// THE CENTRE TYPES REFINE AN ELECTED LEG; THEY DO NOT COMPETE (task 0560).
//
// Four laws, one block each, and each block is written so that the OLD model —
// EdgeCenter / PolyCenter as independent candidates ranked on bare screen
// distance — produces a different, nameable answer:
//
//   A. a centre can only ever be the centre of the element the cascade
//      ELECTED. Under the old model the nearest centre won outright, so a
//      centre belonging to an element that lost could be the result.
//   B. with the element type OFF the centre REPLACES the elected point, and
//      it inherits the ELEMENT's rank — so a centre far outside the
//      acceptance range is snapped to on the strength of its element being
//      inside it. The old model ranked the centre on its own distance and
//      could not reach that point at all.
//   C. with BOTH on, the two points contest on bare screen distance, with
//      TIES GOING TO THE CENTRE.
//   D. the same one leg over, for the polygon.
//
// NONE OF THIS IS VISIBLE AT THE SHIPPED DEFAULT, which is Vertex alone. Every
// block sets `enabledTypes` explicitly; a block that forgot to would assert
// nothing at all, which is why each carries a positive control on the type it
// expects to see.
//
// The viewport is the one the rest of this file's behavioural tests use:
// 80 px per world unit at z = 0, screen = (400 + 80x, 400 - 80y).
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI, abs;

    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    // Never any candidate's position, so a pass-through is distinguishable.
    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);

    float distPx(Vec3 w, int sx, int sy) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every fixture point must project on-screen");
        return sqrt((qx - sx) * (qx - sx) + (qy - sy) * (qy - sy));
    }
    bool near(Vec3 a, Vec3 b) {
        return abs(a.x - b.x) < 1e-3f && abs(a.y - b.y) < 1e-3f
            && abs(a.z - b.z) < 1e-3f;
    }

    // --- A. A CENTRE BELONGS TO THE ELECTED LEG, NOT TO THE NEAREST CENTRE --
    // Two edges. E0 runs close past the cursor and away, so its ON-EDGE point
    // is the nearest thing on the mesh and its MIDPOINT is the farthest. E1
    // sits off to the side: its on-edge point is far, but its midpoint is much
    // nearer than E0's. Ranking centres against each other therefore answers
    // E1; ranking ELEMENTS and then taking the winner's centre answers E0.
    {
        Mesh m;
        m.vertices = [
            Vec3(0.1f, 0.0f, 0),   // 0 — E0 near end,  px (408, 400)
            Vec3(2.1f, 0.0f, 0),   // 1 — E0 far end,   px (568, 400)
            Vec3(0.3f, 0.3f, 0),   // 2 — E1,           px (424, 376)
            Vec3(0.5f, 0.3f, 0),   // 3 — E1,           px (440, 376)
        ];
        m.edges = [[0u, 1u], [2u, 3u]];

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.enabledTypes = SnapType.EdgeCenter;
        cfg.innerRangePx = 100.0f;
        cfg.outerRangePx = 100.0f;

        immutable int sx = 400, sy = 400;
        immutable Vec3 mid0 = Vec3(1.1f, 0.0f, 0);
        immutable Vec3 mid1 = Vec3(0.4f, 0.3f, 0);

        assert(distPx(mid1, sx, sy) < distPx(mid0, sx, sy),
            "fixture: E1's centre must be STRICTLY nearer than E0's, or "
            ~ "'the nearest centre did not win' is not being asserted");
        assert(distPx(mid0, sx, sy) <= cfg.outerRangePx,
            "fixture: and E0's centre must be inside the gather range, so a "
            ~ "centre-ranking model really could have offered both");
        assert(distPx(m.vertices[0], sx, sy) < distPx(m.vertices[2], sx, sy),
            "fixture: E0 must be the nearer ELEMENT, which is the leg the "
            ~ "cascade elects");

        invalidateSnapGrids();
        SnapResult r = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
        assert(r.snapped && r.targetType == SnapType.EdgeCenter,
            "positive control: EdgeCenter is the only type on and it must "
            ~ "still be able to answer");
        assert(r.targetIndex == 0 && near(r.worldPos, mid0),
            "a centre is not a candidate: it is the centre of the element the "
            ~ "cascade ELECTED. E1's centre is nearer the cursor than E0's and "
            ~ "must lose anyway, because E1 is not the elected edge. Answering "
            ~ "E1 here means centres are being ranked against each other, "
            ~ "which is a contest the reference has no way to hold");
    }

    // --- B. ELEMENT OFF: THE CENTRE REPLACES, AND INHERITS THE LEG'S RANK ---
    // One edge, its near end just inside the acceptance range and its midpoint
    // far outside the HIGHLIGHT range. A model that ranks the centre on its
    // own distance cannot produce that midpoint at all — it is not even
    // gathered. A model that ranks the EDGE and then refines produces it,
    // because the edge is what was found to be in range.
    {
        Mesh m;
        m.vertices = [ Vec3(0.1f, 0, 0), Vec3(2.1f, 0, 0) ];
        m.edges    = [ [0u, 1u] ];

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.enabledTypes = SnapType.EdgeCenter;
        cfg.innerRangePx = 24.0f;
        cfg.outerRangePx = 40.0f;

        immutable int sx = 400, sy = 400;
        immutable Vec3 mid = Vec3(1.1f, 0, 0);

        assert(distPx(m.vertices[0], sx, sy) <= cfg.innerRangePx,
            "fixture: the edge must be inside the ACCEPTANCE range");
        assert(distPx(mid, sx, sy) > cfg.outerRangePx,
            "fixture: and its centre must be outside the HIGHLIGHT range, so "
            ~ "a centre ranked on its own distance could not even highlight");

        invalidateSnapGrids();
        SnapResult r = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
        assert(r.snapped && r.targetType == SnapType.EdgeCenter
            && r.targetIndex == 0,
            "with the element type off the centre replaces the elected point "
            ~ "outright — there is no contest to lose");
        assert(near(r.worldPos, mid),
            "and it INHERITS the leg's rank rather than carrying its own: the "
            ~ "edge is what was elected and what was found to be in range, so "
            ~ "the snap lands on a point far outside that range. Refusing here "
            ~ "means the centre is being re-ranked after the refinement, which "
            ~ "re-introduces the contest this whole model removes");
    }

    // --- C. BOTH ON: BARE SCREEN DISTANCE, TIES TO THE CENTRE ---------------
    {
        Mesh m;
        m.vertices = [ Vec3(-1, 0, 0), Vec3(1, 0, 0) ];
        m.edges    = [ [0u, 1u] ];

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.enabledTypes = SnapType.Edge | SnapType.EdgeCenter;
        cfg.innerRangePx = 100.0f;
        cfg.outerRangePx = 100.0f;

        // The cursor ON the midpoint's pixel: the closest point on the edge IS
        // the midpoint, so the two distances are EQUAL and the tie rule is the
        // only thing that can decide.
        invalidateSnapGrids();
        SnapResult tie = snapCursor(cursorWorld, 400, 400, vp, m, ModelSpace.world(), cfg);
        assert(tie.snapped && near(tie.worldPos, Vec3(0, 0, 0)),
            "positive control: both types on, and the edge answers at zero "
            ~ "distance either way");
        assert(tie.targetType == SnapType.EdgeCenter,
            "the contest is a BARE screen distance with TIES TO THE CENTRE — "
            ~ "the element keeps the point only when it is STRICTLY nearer. "
            ~ "Reading Edge here is the tie going the wrong way; the position "
            ~ "cannot show it because at a tie the two points coincide, so the "
            ~ "type tag is the whole assertion");

        // …and off the midpoint the element is strictly nearer and keeps it.
        invalidateSnapGrids();
        SnapResult off = snapCursor(cursorWorld, 460, 400, vp, m, ModelSpace.world(), cfg);
        assert(off.snapped && off.targetType == SnapType.Edge
            && near(off.worldPos, Vec3(0.75f, 0, 0)),
            "and where the on-edge point is STRICTLY nearer it keeps the "
            ~ "point: the centre refines the leg, it does not capture it");
    }

    // --- D. THE POLYGON LEG IS THE SAME LAW ONE LEG OVER --------------------
    // A wide quad the cursor sits inside (surface distance 0) whose centroid
    // is far outside the highlight range — B's shape for PolyCenter.
    {
        Mesh m;
        m.vertices = [
            Vec3(-0.05f, -2, 0), Vec3(3, -2, 0),
            Vec3(3,       2, 0), Vec3(-0.05f, 2, 0),
        ];
        m.addFace([0u, 1u, 2u, 3u]);

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.enabledTypes = SnapType.PolyCenter;
        cfg.innerRangePx = 24.0f;
        cfg.outerRangePx = 40.0f;

        immutable int sx = 400, sy = 400;
        immutable Vec3 centroid = m.faceCentroid(0);

        assert(distPx(centroid, sx, sy) > cfg.outerRangePx,
            "fixture: the centroid must be outside the HIGHLIGHT range, so a "
            ~ "centroid ranked on its own distance could not produce it");

        invalidateSnapGrids();
        SnapResult r = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
        assert(r.snapped && r.targetType == SnapType.PolyCenter
            && r.targetIndex == 0,
            "positive control: the face is front-facing, unoccluded and under "
            ~ "the cursor");
        assert(near(r.worldPos, centroid),
            "the polygon leg refines exactly as the edge leg does: the face "
            ~ "surface is what was elected and what was in range, and the "
            ~ "centroid is where that election points");
    }

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// A CENTRE IS REACHABLE EXACTLY WHEN ITS ELEMENT IS (task 0560, follow-up).
//
// Blocks A-D above all put the centre FARTHER from the cursor than its element,
// which is the ordinary arrangement and the one the reported defect lived in.
// This block is the other side, and it exists because the first revision of
// this port asserted a theorem it does not have: that the elected on-edge point
// is never farther from the cursor than the midpoint, and therefore that the
// edge gather covers everything the old centre gather did.
//
// It does not. Our on-edge candidate is the 3D CLOSEST APPROACH between the
// world segment and the cursor's eye ray, CLAMPED to the segment — see THE EDGE
// LEG in `snapCursor`. That point is not the one nearest the cursor in pixels,
// and the two part company whenever the edge's ends sit at different depths. At
// a clamp they part company entirely: on the rig below the election clamps to
// the near endpoint at 21.5 px while the midpoint sits at 7.8 px.
//
// The ARRANGEMENT this block needs therefore has to come from depth, not from
// parking the cursor on the midpoint. Under the elected-in-3D law a point on
// the cursor's own pixel lies on the cursor's eye ray at zero perpendicular
// distance, so it is always exactly what gets elected — "elected point far,
// midpoint under the cursor" is unreachable for EVERY edge. The rig note inside
// the block says the same thing at greater length; read it before touching the
// fixture.
//
// What survives, and what this block pins, is the rule the model is made of:
// the centre rides its ELEMENT's election, so a range that cannot reach the
// edge cannot reach that edge's centre either — even with the cursor sitting
// comfortably inside the centre's own acceptance. Under the old model, where a
// centre carried a gather of its own, that cursor snapped. The rule is stated
// as reachability rather than as a distance inequality on purpose: it holds
// under ANY on-edge election law, including both the laws this file has now
// shipped, where the inequality has to be re-derived for each.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI, abs;

    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);

    // RIG MIGRATED, on this block's own written instruction. The message below
    // used to say "if this fires, the edge candidate has become
    // perspective-correct — re-derive it on a sharper edge rather than deleting
    // it", and it fired the moment the edge election became the 3D closest
    // approach to the eye ray. Every RULE assertion below is untouched; only
    // the geometry it is asked about moved, because the old geometry can no
    // longer express the premise.
    //
    // WHY THE OLD RIG STOPPED WORKING, and it is worth writing down because it
    // rules out a whole family of replacements. The old cursor sat on the world
    // midpoint's OWN pixel. A point that projects onto the cursor's pixel lies
    // ON the cursor's eye ray, at zero perpendicular distance — so under the
    // elected-in-3D law the midpoint is always exactly what gets elected, and
    // "the elected point is far while the midpoint is near" is unreachable for
    // EVERY edge, not just this one. No sharpening of that arrangement helps.
    //
    // THE SHARP EDGE THAT DOES WORK is a CLAMP. Near end one unit in front of
    // the eye, far end twenty: the far end is farther off the eye ray in world
    // units yet nearer to the cursor in pixels, because it is twenty times
    // deeper. The 3D election therefore recedes monotonically and clamps to the
    // near endpoint at 21.5 px, while the midpoint sits at 7.8 px. Which is the
    // same inequality the block has always needed — elected point far, midpoint
    // near — reached by depth instead of by standing on the midpoint's pixel.
    Mesh m;
    m.vertices = [ Vec3(0.05f, 0.02f, 4.0f), Vec3(0.25f, -0.30f, -15.0f) ];
    m.edges    = [ [0u, 1u] ];
    immutable Vec3 mid = (m.vertices[0] + m.vertices[1]) * 0.5f;

    float[2] pixelOf(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every fixture point must project on-screen");
        return [qx, qy];
    }
    immutable int sx = 400;
    immutable int sy = 400;
    float distPx(Vec3 w) {
        auto p = pixelOf(w);
        return sqrt((p[0] - sx) * (p[0] - sx) + (p[1] - sy) * (p[1] - sy));
    }

    SnapPacket cfg;
    cfg.enabled   = true;
    cfg.snapScope = SnapMode.Global;

    // What the edge leg actually elects here, asked through the public API at a
    // range wide enough that nothing can be rejected for being far.
    cfg.enabledTypes = SnapType.Edge;
    cfg.innerRangePx = 400.0f;
    cfg.outerRangePx = 400.0f;
    invalidateSnapGrids();
    SnapResult wide = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
    assert(wide.snapped && wide.targetType == SnapType.Edge,
        "positive control: with a 400 px range the single edge must answer");

    immutable float dOnEdge = distPx(wide.worldPos);
    immutable float dMid    = distPx(mid);
    assert(dOnEdge > 10.0f && dMid < 10.0f,
        "fixture, and the finding this block exists for: the ELECTED on-edge "
        ~ "point is farther from the cursor than the midpoint is. That is what "
        ~ "makes the 10 px probes below mean anything — the range has to be "
        ~ "able to reach the centre's pixel and NOT the elected point, or the "
        ~ "reachability rule is never actually put to the question. If this "
        ~ "fires, the edge election changed again; re-derive it on a sharper "
        ~ "edge rather than deleting it, and read the rig note above first — "
        ~ "putting the cursor on the midpoint's own pixel cannot work");

    // --- the rule: 10 px reaches the centre's pixel and reaches NOTHING ------
    cfg.innerRangePx = 10.0f;
    cfg.outerRangePx = 10.0f;

    cfg.enabledTypes = SnapType.Edge;
    invalidateSnapGrids();
    SnapResult e10 = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
    assert(!e10.snapped && !e10.highlighted,
        "control on the element: 10 px does not reach the elected on-edge "
        ~ "point, and that is the EDGE type's own pre-existing arithmetic — it "
        ~ "is true with both centre types off, so the block below is about "
        ~ "reachability being SHARED and not about the centre being broken");

    cfg.enabledTypes = SnapType.EdgeCenter;
    invalidateSnapGrids();
    SnapResult c10 = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
    assert(!c10.snapped && !c10.highlighted
        && c10.targetType == SnapType.None && c10.targetIndex == -1,
        "a centre is reachable exactly when its element is: the midpoint sits "
        ~ "7.8 px from the cursor, well inside this 10 px range, and the "
        ~ "centre must STILL be unreachable — because the range does not reach "
        ~ "the ELECTED on-edge point, 21.5 px out, which is what would have to "
        ~ "win first. Snapping here means a centre has a gather of its own "
        ~ "again — which is the old model, and the one the reference cannot "
        ~ "express");

    // --- and the positive control: reach the element, get the centre --------
    // 30 px, not 20: the elected point on the migrated rig is 21.5 px out, so
    // this is the same "one notch past the elected point" the block always had.
    cfg.innerRangePx = 30.0f;
    cfg.outerRangePx = 30.0f;
    cfg.enabledTypes = SnapType.EdgeCenter;
    invalidateSnapGrids();
    SnapResult c20 = snapCursor(cursorWorld, sx, sy, vp, m, ModelSpace.world(), cfg);
    assert(c20.snapped && c20.targetType == SnapType.EdgeCenter
        && c20.targetIndex == 0
        && abs(c20.worldPos.x - mid.x) < 1e-3f
        && abs(c20.worldPos.y - mid.y) < 1e-3f
        && abs(c20.worldPos.z - mid.z) < 1e-3f,
        "…and the rule is reachability, not a ban: 20 px does reach the "
        ~ "elected on-edge point, so the same cursor now gets the centre. A "
        ~ "block that only asserted the refusal above would pass just as well "
        ~ "with the centre types deleted");

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// THE VERTEX VETO IS A SEPARATE MECHANISM, AND IT IS NOT GATED ON ANY TYPE.
//
// Same geometric quantity as the refinement above — the winning edge's
// midpoint — at a different site, doing a different thing. It CLEARS the
// vertex candidate when the cursor is nearer that midpoint than the vertex,
// and it consults no snap type at all: `EdgeCenter` is OFF in both blocks
// below, and a port that modelled the veto as "edgeCenter snapping" would
// therefore leave the vertex standing in the first one.
//
// The pair is built so the CASCADE INPUTS ARE IDENTICAL: the same vertex
// distance and the same edge distance in both, chosen so the vertex trails by
// less than its doubled tolerance and wins the cascade on that clause. The ONLY
// difference is where the elected edge's midpoint lands — inside the vertex's
// distance in the first, far outside it in the second. So an answer that
// differs between the two blocks can only be the veto.
//
// WHAT THE VETO IS OBSERVABLY FOR, since it is not obvious from the rule: the
// projected world midpoint of an edge lies ON that edge's projected segment, so
// it is never nearer the cursor than the nearest point of that segment. In the
// ordinary case the elected edge candidate IS that nearest point, and the veto
// then only fires when the EDGE is already nearer than the vertex — the case
// where the vertex would otherwise win anyway, on its doubled tolerance. The
// veto is exactly the withdrawal of that tolerance bonus once the cursor has
// drifted past the midpoint.
//
// "Ordinary" is doing work in that sentence and this file no longer pretends
// otherwise: our elected on-edge point is the 3D closest approach between the
// world segment and the cursor's eye ray, clamped to the segment (see THE EDGE
// LEG in `snapCursor`), and that is NOT in general the nearest point of the
// projected segment. Where the two ends differ sharply in depth — and always at
// a clamp — the elected point can rank many pixels worse than the segment's
// screen-nearest point, so the veto can fire with the edge candidate ranking
// WORSE than the vertex. The behaviour is still the measured one — the veto
// reads the MIDPOINT, not the elected point — but do not lean on "the edge is
// always nearer" as if it were a theorem about our numbers.
// ---------------------------------------------------------------------------
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI, abs;

    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);
    immutable int  sx = 410, sy = 390;

    float distPxAt(Vec3 w, int px, int py) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every fixture point must project on-screen");
        return sqrt((qx - px) * (qx - px) + (qy - py) * (qy - py));
    }
    float distPx(Vec3 w) { return distPxAt(w, sx, sy); }
    bool near(Vec3 a, Vec3 b) {
        return abs(a.x - b.x) < 1e-3f && abs(a.y - b.y) < 1e-3f
            && abs(a.z - b.z) < 1e-3f;
    }

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.snapScope    = SnapMode.Global;
    cfg.enabledTypes = SnapType.Vertex | SnapType.Edge;   // EdgeCenter is OFF
    cfg.innerRangePx = 24.0f;
    cfg.outerRangePx = 40.0f;

    immutable Vec3 theVertex = Vec3(0, 0.3125f, 0);    // px (400, 375)
    immutable Vec3 onEdge    = Vec3(0.125f, 0, 0);     // px (410, 400)
    immutable float base = kCandidateToleranceBasePx;
    immutable float tolV = kVertexToleranceScale * base;

    // Both meshes: the same contested vertex, and an edge running through the
    // same point 10 px below the cursor. Only the edge's EXTENT differs, which
    // moves only its midpoint.
    Mesh vetoed;
    vetoed.vertices = [ theVertex, Vec3(-0.5f, 0, 0), Vec3(0.5f, 0, 0) ];
    vetoed.edges    = [ [1u, 2u] ];                    // midpoint px (400, 400)

    Mesh spared;
    spared.vertices = [ theVertex, Vec3(-0.25f, 0, 0), Vec3(1.25f, 0, 0) ];
    spared.edges    = [ [1u, 2u] ];                    // midpoint px (440, 400)

    immutable float dVert = distPx(theVertex);
    immutable float dEdge = distPx(onEdge);
    immutable float dMidV = distPx(Vec3(0.0f, 0, 0));   // vetoed mesh's midpoint
    immutable float dMidS = distPx(Vec3(0.5f, 0, 0));   // spared mesh's midpoint

    assert(dEdge < dVert && dVert - dEdge < tolV && dVert - dEdge > base,
        "fixture: the vertex must trail the edge by more than one tolerance "
        ~ "base and less than its own DOUBLED one, so the cascade prefers the "
        ~ "vertex and does so on the tolerance clause the veto withdraws");
    assert(dVert <= cfg.innerRangePx,
        "fixture: and the vertex must be inside the acceptance range, or the "
        ~ "difference would show as a highlight rather than a snap");
    foreach (v; [vetoed.vertices[1], vetoed.vertices[2],
                 spared.vertices[1], spared.vertices[2]])
        assert(distPx(v) > dVert,
            "fixture: an edge ENDPOINT is a vertex candidate too — every one "
            ~ "of them must be farther than the contested vertex, or the "
            ~ "vertex class would carry a distance the pair does not share");
    assert(dMidV < dVert && dMidV < cfg.innerRangePx,
        "fixture: block 1's midpoint must be nearer than the vertex AND "
        ~ "inside the caller's range — both are preconditions of the veto");
    assert(dMidS > dVert && dMidS > cfg.innerRangePx,
        "fixture: block 2's midpoint must fail both, so its ONLY difference "
        ~ "from block 1 is the thing the veto reads");

    // --- 1. the veto fires, with EdgeCenter OFF ----------------------------
    invalidateSnapGrids();
    SnapResult r = snapCursor(cursorWorld, sx, sy, vp, vetoed, ModelSpace.world(), cfg);
    assert(r.snapped && r.targetType == SnapType.Edge && r.targetIndex == 0
        && near(r.worldPos, onEdge),
        "the vertex slot is CLEARED when the cursor is nearer the winning "
        ~ "edge's midpoint than the vertex, and nothing about that consults a "
        ~ "snap type — EdgeCenter is off here. Answering Vertex means either "
        ~ "the veto is missing or it was gated on the centre preference, and "
        ~ "the reference gates it on neither");

    // --- 2. …and it is the MIDPOINT that decides, not the edge -------------
    invalidateSnapGrids();
    SnapResult s = snapCursor(cursorWorld, sx, sy, vp, spared, ModelSpace.world(), cfg);
    assert(s.snapped && s.targetType == SnapType.Vertex && s.targetIndex == 0
        && near(s.worldPos, theVertex),
        "with the SAME vertex distance and the SAME edge distance, moving "
        ~ "only the midpoint out of range restores the vertex — which is what "
        ~ "makes block 1 a statement about the veto and not about the cascade. "
        ~ "Answering Edge here means the veto lost its preconditions and is "
        ~ "firing whenever an edge is nearer, i.e. it has silently become "
        ~ "'the vertex tolerance was deleted'");

    // --- 3. turning the centre type ON changes nothing about the veto ------
    cfg.enabledTypes = SnapType.Vertex | SnapType.Edge | SnapType.EdgeCenter;
    invalidateSnapGrids();
    SnapResult rc = snapCursor(cursorWorld, sx, sy, vp, vetoed, ModelSpace.world(), cfg);
    assert(rc.snapped && rc.targetIndex == 0 && near(rc.worldPos, onEdge),
        "the two mechanisms are independent in both directions: with the "
        ~ "centre type ON the veto still fires the same way, and the centre "
        ~ "contest still hands the point to the strictly-nearer on-edge point");
    invalidateSnapGrids();
    SnapResult sc = snapCursor(cursorWorld, sx, sy, vp, spared, ModelSpace.world(), cfg);
    assert(sc.snapped && sc.targetType == SnapType.Vertex,
        "and turning the centre type on does not manufacture a veto either");

    // --- 4. the midpoint must be inside the CALLER'S RANGE ------------------
    // The veto has two preconditions and blocks 1-3 defeat both at once, so
    // they cannot tell them apart. This block isolates the range one, and it
    // has to reach for the only geometry where that clause is observable at
    // all: `dMid < dVert` with `dMid >= innerRange` forces `dVert > innerRange`
    // too, i.e. a vertex that can HIGHLIGHT but not snap. So the difference the
    // clause makes is a highlight surviving instead of a snap firing.
    //
    // Fresh cursor (the pixel above is built for the other preconditions) and
    // a fresh mesh: a vertex 30 px out, an edge whose closest point is 20 px
    // out — inside the vertex's doubled tolerance, so the cascade prefers the
    // vertex — and that edge's midpoint at 26.9 px, nearer than the vertex but
    // OUTSIDE the acceptance range. The edge's endpoints are pushed far enough
    // out that they cannot displace the contested vertex in its own class.
    {
        immutable int rx = 400, ry = 400;

        Mesh m;
        m.vertices = [
            Vec3( 0.0f,   0.375f, 0),   // 0 — the contested vertex, px (400, 370)
            Vec3(-0.4f,  -0.25f,  0),   // 1 — edge end,             px (368, 420)
            Vec3( 0.85f, -0.25f,  0),   // 2 — edge end,             px (468, 420)
        ];
        m.edges = [ [1u, 2u] ];

        SnapPacket rcfg;
        rcfg.enabled      = true;
        rcfg.snapScope    = SnapMode.Global;
        rcfg.enabledTypes = SnapType.Vertex | SnapType.Edge;
        rcfg.innerRangePx = 24.0f;
        rcfg.outerRangePx = 40.0f;

        immutable float rVert = distPxAt(m.vertices[0], rx, ry);
        immutable float rEdge = distPxAt(Vec3(0, -0.25f, 0), rx, ry);
        immutable float rMid  = distPxAt(Vec3(0.225f, -0.25f, 0), rx, ry);

        assert(rVert > rcfg.innerRangePx && rVert <= rcfg.outerRangePx,
            "fixture: the vertex must be able to HIGHLIGHT and not to snap — "
            ~ "that is forced by wanting the midpoint nearer than the vertex "
            ~ "and outside the range at the same time");
        assert(rEdge <= rcfg.innerRangePx && rVert - rEdge < kVertexToleranceScale
                                                            * kCandidateToleranceBasePx,
            "fixture: the edge must be able to snap, and the vertex must "
            ~ "still beat it in the cascade, or the veto would change nothing");
        assert(rMid < rVert && rMid >= rcfg.innerRangePx,
            "fixture: and the midpoint must satisfy the NEARER precondition "
            ~ "while failing the RANGE one — that pair is the whole point of "
            ~ "this block");

        invalidateSnapGrids();
        SnapResult h = snapCursor(cursorWorld, rx, ry, vp, m, ModelSpace.world(), rcfg);
        assert(!h.snapped && h.highlighted && h.targetType == SnapType.Vertex
            && h.targetIndex == 0,
            "the veto also asks whether the midpoint is inside the caller's "
            ~ "range, and here it is not — so the vertex stands and answers "
            ~ "with a highlight. Snapping to the edge here means the range "
            ~ "clause was dropped and the veto now fires on proximity alone");
    }

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// task 0617 Stage 4 review BLOCKER 2 — `legCenterPoint`'s two consumers
// (`refineElectedLeg`, which publishes an edge-centre leg's midpoint as the
// snap result's WORLD position, and `vertexSlotVetoed` above, which compares
// that midpoint's screen distance against the WORLD viewport) both treat
// `legCenterPoint`'s return value as world. Before the fix, `legCenterPoint`
// averaged `m.vertices[]` raw — LOCAL for a background source — so a
// background layer carrying any transform published a midpoint three world
// units from where it was actually drawn (a translated layer's `EdgeCenter`
// snap would land in empty space) and silently stopped vetoing the vertex
// slot (a "midpoint nearer than the vertex" test run against the wrong
// point degrades to always-false).
//
// Both tests below install their geometry as a BACKGROUND source (slot 1,
// via setBackgroundSnapSources) with a non-identity ModelSpace, reusing this
// file's own identity fixtures' WORLD coordinates verbatim — only the
// SOURCE of that geometry changes (a translated background layer instead of
// the untransformed primary), so a reversion of the fix is visible as the
// exact same divergence the review's repro describes: the published point
// lands at the translation vector's distance from where the geometry is
// actually drawn.
// ---------------------------------------------------------------------------
unittest { // legCenterPoint via refineElectedLeg — EdgeCenter published position
    import math     : lookAt, perspectiveMatrix, translationMatrix;
    import std.math : PI, abs;

    invalidateSnapGrids();
    scope(exit) { setBackgroundSnapSources(null, null); invalidateSnapGrids(); }

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);

    // The edge's WORLD endpoints and midpoint — identical numbers to this
    // file's identity EdgeCenter fixture above, so a correct fix reproduces
    // that fixture's result through an extra (background-layer) indirection.
    immutable Vec3 worldA = Vec3(0.0f, 0, 0);
    immutable Vec3 worldB = Vec3(1.0f, 0, 0);
    immutable Vec3 worldMid = Vec3(0.5f, 0, 0);
    immutable Vec3 T = Vec3(3, 0, 0);   // "a background layer at position x=3"

    ModelSpace ms;
    ms.m    = translationMatrix(T);
    ms.mInv = translationMatrix(Vec3(-T.x, -T.y, -T.z));
    ms.isIdentity = false;

    // LOCAL geometry: the world edge shifted by -T, so `ms.toWorldPoint`
    // reconstructs worldA/worldB exactly.
    Mesh bg;
    bg.vertices = [worldA - T, worldB - T];
    bg.edges    = [[0u, 1u]];
    const(Mesh)*[] bgSrc = [&bg];
    setBackgroundSnapSources(bgSrc, [ms]);

    Mesh empty;   // primary layer contributes nothing — every candidate is slot 1

    int[2] pixelOf(Vec3 w) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: the probe point must project on-screen");
        return [cast(int)round(qx), cast(int)round(qy)];
    }
    auto pc = pixelOf(worldMid);

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.snapScope    = SnapMode.Global;
    cfg.enabledTypes = SnapType.EdgeCenter;
    cfg.innerRangePx = 40.0f;
    cfg.outerRangePx = 40.0f;

    invalidateSnapGrids();
    SnapResult r = snapCursor(cursorWorld, pc[0], pc[1], vp, empty, ModelSpace.world(), cfg);
    assert(r.snapped && r.targetType == SnapType.EdgeCenter && r.targetIndex == 0
        && r.targetSource == 1,
        "fixture: the background edge's centre must win — otherwise the "
      ~ "position assertion below would pass for the wrong reason");
    assert(abs(r.worldPos.x - worldMid.x) < 1e-3f
        && abs(r.worldPos.y - worldMid.y) < 1e-3f
        && abs(r.worldPos.z - worldMid.z) < 1e-3f,
        "the published EdgeCenter position must be the midpoint WHERE THE "
      ~ "BACKGROUND LAYER IS DRAWN (world) — reverting the fix averages the "
      ~ "raw LOCAL vertices instead, publishing a point 3 world units away "
      ~ "at the layer's untransformed (identity) position");
}

unittest { // legCenterPoint via vertexSlotVetoed — the veto's own consumer,
           // on a translated background source. Same shape as this file's
           // identity vertex-veto fixture above (block 1: "the veto fires"),
           // ported one indirection deeper.
    import math     : lookAt, perspectiveMatrix, translationMatrix;
    import std.math : PI, abs;

    invalidateSnapGrids();
    scope(exit) { setBackgroundSnapSources(null, null); invalidateSnapGrids(); }

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    immutable Vec3 cursorWorld = Vec3(7.5f, -3.25f, 1.125f);
    immutable int  sx = 410, sy = 390;

    float distPxAt(Vec3 w, int px, int py) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: every fixture point must project on-screen");
        return sqrt((qx - px) * (qx - px) + (qy - py) * (qy - py));
    }
    float distPx(Vec3 w) { return distPxAt(w, sx, sy); }
    bool near(Vec3 a, Vec3 b) {
        return abs(a.x - b.x) < 1e-3f && abs(a.y - b.y) < 1e-3f
            && abs(a.z - b.z) < 1e-3f;
    }

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.snapScope    = SnapMode.Global;
    cfg.enabledTypes = SnapType.Vertex | SnapType.Edge;   // EdgeCenter is OFF
    cfg.innerRangePx = 24.0f;
    cfg.outerRangePx = 40.0f;

    // Identical WORLD geometry to the identity vertex-veto fixture's block 1
    // ("the veto fires") above.
    immutable Vec3 theVertex = Vec3(0, 0.3125f, 0);    // px (400, 375)
    immutable Vec3 onEdge    = Vec3(0.125f, 0, 0);     // px (410, 400)

    immutable float dVert = distPx(theVertex);
    immutable float dEdge = distPx(onEdge);
    immutable float dMidV = distPx(Vec3(0.0f, 0, 0));   // this mesh's edge midpoint
    assert(dEdge < dVert && dVert <= cfg.innerRangePx && dMidV < dVert
        && dMidV < cfg.innerRangePx,
        "fixture: reuses the identity vertex-veto test's own preconditions "
      ~ "verbatim — see that test for why each one matters");

    immutable Vec3 T = Vec3(3, 0, 0);   // "a background layer at position x=3"
    ModelSpace ms;
    ms.m    = translationMatrix(T);
    ms.mInv = translationMatrix(Vec3(-T.x, -T.y, -T.z));
    ms.isIdentity = false;

    Mesh bg;
    bg.vertices = [theVertex - T, Vec3(-0.5f, 0, 0) - T, Vec3(0.5f, 0, 0) - T];
    bg.edges    = [[1u, 2u]];
    const(Mesh)*[] bgSrc = [&bg];
    setBackgroundSnapSources(bgSrc, [ms]);

    Mesh empty;

    invalidateSnapGrids();
    SnapResult r = snapCursor(cursorWorld, sx, sy, vp, empty, ModelSpace.world(), cfg);
    assert(r.snapped && r.targetType == SnapType.Edge && r.targetIndex == 0
        && r.targetSource == 1 && near(r.worldPos, onEdge),
        "the vertex slot must be CLEARED by the veto exactly as it is for "
      ~ "the identity fixture — reverting the fix compares the cursor "
      ~ "against the background edge's raw LOCAL midpoint (3 world units "
      ~ "from where it is drawn), which never satisfies the veto's "
      ~ "'nearer than the vertex' precondition, so the vertex wins instead "
      ~ "of the edge");
}

// ---------------------------------------------------------------------------
// THE EDGE POINT ELECTION — the elected on-edge point is the 3D closest
// approach to the cursor's eye ray, and this test spans DEPTH because nothing
// shallower can see the difference.
//
// Three laws are in play and a badly chosen rig cannot tell them apart:
//
//   E-1  the reference's, and now ours: the point on the world segment closest
//        to the eye RAY, clamped to [0, 1], ranked by its re-projected screen
//        distance.
//   E-2  what this file used to do: the closest parameter on the PROJECTED
//        segment, applied as a WORLD parameter.
//   E-3  the perspective-correct SCREEN-NEAREST point,
//        `u = t*wa / ((1-t)*wb + t*wa)`. Plausible, filed as the fix once, and
//        NOT what the reference computes.
//
// E-1 and E-3 coincide exactly whenever the eye, the cursor ray and the edge
// are COPLANAR — both then reduce to finding the zero of one affine function.
// A coplanar fixture therefore passes under either law and proves only that
// E-2 is gone. Both rigs below are deliberately non-coplanar (the two
// endpoints' offsets from the ray are not parallel), and the second one is
// chosen at a CLAMP, which is where E-1 and E-3 separate the most.
unittest {
    import math     : lookAt, perspectiveMatrix;
    import std.math : PI;

    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;

    float distPxAt(Vec3 w, int cx, int cy) {
        float qx, qy, qz;
        assert(projectToWindowFull(w, vp, qx, qy, qz),
            "fixture: the probe point must project on-screen");
        immutable float dx = qx - cast(float)cx;
        immutable float dy = qy - cast(float)cy;
        return sqrt(dx * dx + dy * dy);
    }
    float dist3(Vec3 p, Vec3 q) {
        immutable Vec3 d = p - q;
        return sqrt(dot(d, d));
    }

    // -----------------------------------------------------------------------
    // RIG 1 — the headline effect. An edge running from just in front of the
    // camera (world z = 4, i.e. one unit of depth) out to z = -15 (twenty
    // units), so the endpoints' depths differ by a factor of twenty. The
    // cursor sits beside the projected segment.
    //
    // E-1 elects t = 0.04499, whose pixel is 0.79 px from the cursor.
    // E-2 elects t = 0.48547, whose pixel is 25.41 px away — an EIGHT-unit
    // world displacement along the edge, and it loses a snap the cursor is
    // sitting on top of.
    // -----------------------------------------------------------------------
    {
        immutable int cx = 415, cy = 385;
        Mesh m;
        m.vertices = [ Vec3(0.06f,  0.10f,   4.0f),
                       Vec3(0.35f, -0.60f, -15.0f) ];
        m.edges    = [ [0u, 1u] ];

        immutable Vec3 a = m.vertices[0], b = m.vertices[1];
        immutable Vec3 pE1 = a + (b - a) * 0.044985f;   // the 3D closest approach
        immutable Vec3 pE2 = a + (b - a) * 0.485466f;   // the old projected-t point

        // Premises, stated rather than trusted: this rig separates E-1 from
        // E-2 by 25 px of rank and 8 world units of position.
        assert(distPxAt(pE1, cx, cy) < 1.5f,
            "fixture: the 3D closest approach must sit on the cursor's pixel");
        assert(distPxAt(pE2, cx, cy) > 20.0f,
            "fixture: the projected-t point must be far off it, or this rig "
            ~ "proves nothing about which law ran");

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.enabledTypes = SnapType.Edge;      // the edge leg alone, no cascade
        cfg.innerRangePx = 10.0f;
        cfg.outerRangePx = 60.0f;

        invalidateSnapGrids();
        SnapResult r = snapCursor(Vec3(0, 0, 0), cx, cy, vp, m, ModelSpace.world(), cfg);
        assert(r.snapped && r.targetType == SnapType.Edge && r.targetIndex == 0,
            "an edge whose 3D-closest point is under the cursor must SNAP; a "
            ~ "projected-t election ranks the same edge 25 px out and misses "
            ~ "the 10 px acceptance entirely");
        assert(dist3(r.worldPos, pE1) < 1e-3f,
            "the elected point must be the closest approach to the eye ray");
        assert(dist3(r.worldPos, pE2) > 1.0f,
            "and must NOT be the projected parameter applied as a world one");
    }

    // -----------------------------------------------------------------------
    // RIG 2 — the discriminator, at a clamp. Same depth span, but the edge
    // recedes from the eye ray monotonically in 3D while its SCREEN offset
    // shrinks (the far end is farther off-axis in world units and nearer to
    // the cursor in pixels, because it is twenty times deeper).
    //
    //   E-1 clamps to t = 0      -> endpoint A, 21.54 px from the cursor
    //   E-3 elects  t ~ 0.696    -> 7.80 px from the cursor
    //   E-2 elects  t ~ 0.979    -> 7.81 px from the cursor
    //
    // So here the reference's law is the one that ranks WORSE in pixels, and
    // that is the point: this is a law, not an optimisation. The three elected
    // points are 13.2 and 18.6 world units apart, so nothing about float
    // tolerance is doing the work.
    //
    // This rig is why a coplanar test is not enough. On a coplanar rig E-1 and
    // E-3 agree to the last bit; here they disagree by 0.696 in parameter,
    // which is the largest kind of disagreement the two laws have.
    // -----------------------------------------------------------------------
    {
        immutable int cx = 400, cy = 400;
        Mesh m;
        m.vertices = [ Vec3(0.05f,  0.02f,   4.0f),
                       Vec3(0.25f, -0.30f, -15.0f) ];
        m.edges    = [ [0u, 1u] ];

        immutable Vec3 a = m.vertices[0], b = m.vertices[1];
        immutable Vec3 pE1 = a;                          // the clamp
        immutable Vec3 pE3 = a + (b - a) * 0.695945f;    // screen-nearest
        immutable Vec3 pE2 = a + (b - a) * 0.978622f;    // projected-t-as-world

        // The premise that makes this rig a discriminator and not a tautology:
        // the reference's answer is the FARTHEST of the three in pixels, so a
        // test that merely demanded "the nearest pixel" would assert the wrong
        // law and pass under both rivals.
        immutable float d1 = distPxAt(pE1, cx, cy);
        immutable float d3 = distPxAt(pE3, cx, cy);
        immutable float d2 = distPxAt(pE2, cx, cy);
        assert(d1 > d3 + 10.0f && d1 > d2 + 10.0f,
            "fixture: at this clamp the 3D election ranks WORSE in pixels than "
            ~ "either rival — that asymmetry is what makes the rig decisive");
        assert(dist3(pE1, pE3) > 10.0f && dist3(pE1, pE2) > 10.0f,
            "fixture: and the three elected points must be far apart in world "
            ~ "space, so no tolerance can blur them together");

        SnapPacket cfg;
        cfg.enabled      = true;
        cfg.snapScope    = SnapMode.Global;
        cfg.enabledTypes = SnapType.Edge;
        cfg.innerRangePx = 30.0f;    // wide enough to accept the 21.5 px answer
        cfg.outerRangePx = 60.0f;

        invalidateSnapGrids();
        SnapResult r = snapCursor(Vec3(0, 0, 0), cx, cy, vp, m, ModelSpace.world(), cfg);
        assert(r.snapped && r.targetType == SnapType.Edge && r.targetIndex == 0,
            "the edge must still be elected and accepted at 21.5 px");
        assert(dist3(r.worldPos, pE1) < 1e-4f,
            "the elected point must be the CLAMPED 3D closest approach. "
            ~ "Landing on the screen-nearest point instead means the "
            ~ "perspective-correct-interpolation law was implemented — a "
            ~ "different law that happens to agree with this one on every "
            ~ "coplanar rig, including the one this fix was first measured on");
        assert(dist3(r.worldPos, pE3) > 10.0f && dist3(r.worldPos, pE2) > 10.0f,
            "and it must be neither rival's point");
    }

    invalidateSnapGrids();
}

// ---------------------------------------------------------------------------
// Task 0617 Stage 4: a source's ModelSpace must be honoured by the vertex
// leg — a click at the DRAWN (world) pixel snaps; the same pixel the vertex
// would have projected to at its pre-transform LOCAL pose does not. This is
// `walkSource`'s `toWorld()` wiring end to end, through the public
// `snapCursor` entry point (the same one every tool/create/create-common
// call site drives), not a white-box test of the closure itself.
// ---------------------------------------------------------------------------
unittest {
    import math             : lookAt, perspectiveMatrix, translationMatrix, ModelSpace;
    import toolpipe.packets : SnapPacket, SnapType, SnapMode;
    import std.math         : PI, round, sqrt;

    invalidateSnapGrids();

    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 400;
    vp.height = 400;

    Mesh m;
    m.vertices = [Vec3(0, 0, 0)];   // the ONLY vertex, at the LOCAL origin

    // Translate +X by 2 — no rotation/scale, so mInv is exact and trivial.
    ModelSpace ms;
    ms.m          = translationMatrix(Vec3(2, 0, 0));
    ms.mInv       = translationMatrix(Vec3(-2, 0, 0));
    ms.isIdentity = false;
    ms.invertible = true;
    ms.mirrored   = false;

    SnapPacket cfg;
    cfg.enabled      = true;
    cfg.enabledTypes = SnapType.Vertex;
    cfg.snapScope    = SnapMode.Global;
    cfg.innerRangePx = 20.0f;
    cfg.outerRangePx = 200.0f;

    // Two candidate pixels: where the vertex is actually DRAWN (world =
    // ms.m * local), and where it would project if `ms` were never applied
    // (the pre-0617 bug's answer).
    float dwx, dwy, dwz;
    assert(projectToWindowFull(Vec3(2, 0, 0), vp, dwx, dwy, dwz),
        "fixture: the drawn (world) position must project on-screen");
    immutable int drawnX = cast(int)round(dwx), drawnY = cast(int)round(dwy);

    float lwx, lwy, lwz;
    assert(projectToWindowFull(Vec3(0, 0, 0), vp, lwx, lwy, lwz),
        "fixture: the identity-pose (local) position must project on-screen too");
    immutable int localX = cast(int)round(lwx), localY = cast(int)round(lwy);

    // Anti-vacuity guard (0614 lesson): the two pixels must differ enough
    // that a miss at one and a hit at the other cannot be noise.
    immutable float sep = sqrt(cast(float)((drawnX - localX) * (drawnX - localX)
                                          + (drawnY - localY) * (drawnY - localY)));
    assert(sep > 20.0f,
        "fixture: the drawn and identity-pose pixels must differ meaningfully, "
        ~ "or neither assertion below can discriminate the fix from the bug");

    invalidateSnapGrids();
    SnapResult drawn = snapCursor(Vec3(0, 0, 0), drawnX, drawnY, vp, m, ms, cfg);
    assert(drawn.snapped && drawn.targetIndex == 0,
        "a click at the vertex's DRAWN (world) pixel must snap to it — the "
        ~ "whole point of routing the vertex leg's `consider()` call through "
        ~ "ms.toWorldPoint()");

    invalidateSnapGrids();
    SnapResult identity = snapCursor(Vec3(0, 0, 0), localX, localY, vp, m, ms, cfg);
    assert(!identity.snapped,
        "a click at the vertex's PRE-TRANSFORM local pixel must NOT snap — "
        ~ "this is exactly the regression the fix closes: offering the "
        ~ "candidate at m.vertices[vi] unmodified would snap HERE instead of "
        ~ "at the drawn position");

    // Review NIT: leave the grid cache invalidated on exit, matching the
    // convention every other unittest in this file follows (this one
    // installs no background sources, so there is nothing else to restore).
    invalidateSnapGrids();
}
