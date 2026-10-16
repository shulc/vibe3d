module tests.unit.constraint_regression_test;

import constraint;
import math : Vec3;
import vibe3d.util.spatial.spatial : Viewport;
import toolpipe.packets : SnapPacket, ConstrainHitPacket, HoverTargetKind;


unittest { // the THREE measured numbers, and the two refutations behind them
    auto vp = makeHoverTestViewport();
    // The default snap configuration — the pen's own drag snapshot is exactly
    // this whenever the user has not moved the ranges, so the measured values
    // are still pinned here, just through their real owner.
    const SnapPacket snap;

    assert(viewPixelScale(vp) == 1.0f,
        "the measured radii are pixel constants; the scale seam is ours, and it is 1.0 today");

    assert(topoPenPressPickPx(vp) == 8.0f,
        "the press pick reaches the one limit the reference printed on every press");
    assert(topoPenSnapAcceptPx(vp, snap) == 24.0f,
        "the drag-snap acceptance is its own, separately measured radius — and it "
        ~ "is the snap service's DEFAULT inner range, one fact stored once");
    assert(topoPenSnapGatherPx(vp, snap) == 40.0f,
        "the drag-snap gather is a second measured nominal, not a factor on the acceptance");

    // The two queries are DIFFERENT reaches. This is the whole correction: a
    // single constant cannot serve both, and the 15px that used to sit here
    // was neither of them.
    assert(topoPenPressPickPx(vp) < topoPenSnapAcceptPx(vp, snap),
        "press pick and drag snap are two queries with two reaches, not one shared gate");
    assert(topoPenPressPickPx(vp) != 15.0f && topoPenSnapAcceptPx(vp, snap) != 15.0f,
        "15px was the fusion of the two queries and is neither of them");

    // gather : acceptance is 5/3. A `2.0` factor here was refuted outright.
    assert(topoPenSnapGatherPx(vp, snap) / topoPenSnapAcceptPx(vp, snap) == 5.0f / 3.0f,
        "the gather:acceptance ratio is 5/3, not the 2.0 the static reading assumed");
    assert(topoPenSnapGatherPx(vp, snap) != 2.0f * topoPenSnapAcceptPx(vp, snap),
        "the refuted 2.0 factor must not creep back in");

    // Type-uniformity of the GATHER is structural, not a value check: each
    // query has exactly one threshold function, so a per-type gather radius
    // cannot be expressed without adding one. These assertions document the
    // invariant the measurement proved (one acceptance under both a vertex and
    // an edge latch; one printed press limit shared by vertex and edge) so a
    // future per-type "improvement" to the GATHER has to delete a stated law
    // first. It says nothing about the reference's cross-type ARBITRATION,
    // whose tolerance is per-type and which we do not implement -- see the
    // block comment above (task 0507).
    assert(topoPenPressPickPx(vp) == topoPenPressPickPx(vp),
        "one press-pick GATHER reach for vertex, edge and polygon candidates alike");
    assert(topoPenSnapAcceptPx(vp, snap) == topoPenSnapAcceptPx(vp, snap),
        "one drag-snap acceptance for every candidate type");

    // THE DE-DUPLICATION, asserted rather than merely commented: the pen has no
    // acceptance/gather constants of its own left, so these two functions can
    // only be reporting the snap service's configuration. Move the ranges and
    // both must move with them — a re-introduced private constant would pin
    // them at 24/40 here and fail.
    SnapPacket moved;
    moved.innerRangePx = 12.0f;
    moved.outerRangePx = 33.0f;
    assert(topoPenSnapAcceptPx(vp, moved) == 12.0f,
        "the acceptance is the packet's inner range, not a constant this module owns");
    assert(topoPenSnapGatherPx(vp, moved) == 33.0f,
        "the gather is the packet's outer range, not a constant this module owns");

    // The press pick does NOT follow it: different query, different owner,
    // nothing configures it. This is the merge that must never happen.
    assert(topoPenPressPickPx(vp) == 8.0f,
        "the press pick is the pen's own reach and no snap setting may move it");
}


// ---------------------------------------------------------------------------
// Unit tests — run under `dub test --config=tests`.
// (MANDATORY for core math modules: the HTTP test suite silently skips
// unittest blocks in modules not imported by the test binary.)
// ---------------------------------------------------------------------------

















// ---------------------------------------------------------------------------
// P0 (topology-pen) unit tests: nearestFaceVertex / nearestFaceEdge.
// ---------------------------------------------------------------------------







// ---------------------------------------------------------------------------
// resolveHoverTarget — topology-pen P1 (doc/topopen_p1_plan.md). GL-free
// pure unittests: a synthetic Viewport (identity-ish lookAt at Z=5, 90°
// symmetric perspective, 800x800) makes the projected-pixel math a plain
// scale by a hand-derivable constant, so every expected pixel distance
// below is independently computed (not round-tripped through the function
// under test) — same rigor as the HTTP fixture's threshold-flip cases
// (topo_pen_hover_target.json #5/#6).
//
// Camera: eye=(0,0,5), lookAt origin, up=(0,1,0), fovY=90 deg (f = 1/tan(45)
// = 1), aspect=1, width=height=800. Both the hit point and every candidate
// below sit at world Z=0 (same depth as the lookAt target), so the
// perspective divide's w is constant (== distance == 5) across all of
// them, and the projection collapses to a PURE uniform scale + centering:
//   screenX = 400 + S*worldX,  screenY = 400 - S*worldY,  S = f*0.5*height/eye.z
//           = 1 * 0.5*800/5 = 80 px per world unit.
// (This is the SAME derivation the topo_pen_hover_target.json fixture's
// provenance uses for its az=0/el=0 cube cases — see that file's notes.)
// ---------------------------------------------------------------------------
version (unittest) private Viewport makeHoverTestViewport() {
    import math : lookAt, perspectiveMatrix;
    import std.math : PI;
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}


unittest { // resolveHoverTarget — no hit -> None (default packet)
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;   // hit == false by default
    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.None, "no hit must resolve to None");
    assert(t.vert == -1 && t.edge == -1);
}


unittest { // resolveHoverTarget — vertex within threshold wins (S=80 px/unit;
           // a 0.1-world-unit offset at Z=0 depth projects to exactly 8px)
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit           = true;
    h.point         = Vec3(0, 0, 0);          // projects to (400,400)
    h.nearestVert   = 3;
    h.nearestVertPos = Vec3(0.1f, 0, 0);      // projects to (408,400): 8px away
    h.nearestEdge   = -1;                     // no edge candidate this case

    auto wide = resolveHoverTarget(h, vp, 12.0f);     // 8 <= 12
    assert(wide.kind == HoverTargetKind.Vertex, "8px within a 12px radius must snap to Vertex");
    assert(wide.vert == 3);

    auto narrow = resolveHoverTarget(h, vp, 4.0f);    // 8 > 4
    assert(narrow.kind == HoverTargetKind.Face, "8px outside a 4px radius must fall through to Face");
}


unittest { // resolveHoverTarget — edge wins when the vertex candidate is far
           // but the edge segment passes through the hit's projected pixel
           // (vert offset (2,0,0) -> 160px away; edge endpoints (0,+-0.1,0)
           // -> a vertical segment straddling (400,400) exactly, 0px).
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit         = true;
    h.point       = Vec3(0, 0, 0);
    h.nearestVert = 1;
    h.nearestVertPos = Vec3(2.0f, 0, 0);      // 160px away — outside any sane radius
    h.nearestEdge = 5;
    h.nearestEdgeA = Vec3(0,  0.1f, 0);       // projects to (400, 392)
    h.nearestEdgeB = Vec3(0, -0.1f, 0);       // projects to (400, 408)

    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.Edge, "vertex far / edge through the hit pixel must resolve to Edge");
    assert(t.edge == 5);
}


unittest { // resolveHoverTarget — a FARTHER vertex still beats a NEARER edge.
           //
           // Task 0496, the deliberately-opposite test. The rival law once
           // written into this file's docstring — "take the one closest
           // candidate across all types, apply the radius afterwards" — would
           // resolve the EDGE here. It was refuted on the reference twice, on
           // two independent cells (a vertex at 5.83px beat an edge at 3.00px
           // and a polygon at 0.00px; a vertex at 7.07px beat an edge at
           // 7.00px). This case is that shape, at this viewport's 80px per
           // world unit: the vertex sits 5.6px from the hit pixel and the edge
           // segment passes straight THROUGH it at 0px, with both inside the
           // press-pick reach — and the vertex must win.
           //
           // Red under "one closest across types"; green under the measured
           // vertex-first short circuit.
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit            = true;
    h.point          = Vec3(0, 0, 0);          // projects to (400, 400)
    h.nearestVert    = 2;
    h.nearestVertPos = Vec3(0.07f, 0, 0);      // 5.6px away — farther than the edge
    h.nearestEdge    = 9;
    h.nearestEdgeA   = Vec3(0,  0.1f, 0);      // the segment straddles (400,400):
    h.nearestEdgeB   = Vec3(0, -0.5f, 0);      // distance 0px, midpoint 16px away

    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.Vertex,
        "a vertex INSIDE the press-pick reach must win over a strictly nearer edge — the "
      ~ "'one closest candidate across types' law was measured-negative and must not be ported");
    assert(t.vert == 2, "and it must be that vertex");

    // K-P P5cA: an edge whose MIDPOINT is in reach and nearer than the vertex
    // vetoes the vertex (the readout runs the shared comparator).
    h.nearestEdgeB = Vec3(0, -0.1f, 0);        // midpoint on the hit pixel
    t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.Edge && t.edge == 9,
        "a nearer in-reach edge midpoint must veto the vertex (K-P P5cA)");
}


unittest { // resolveHoverTarget — neither candidate in range -> Face
           // (vert offset (2,0,0) -> 160px; edge same offset -> also far)
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit         = true;
    h.point       = Vec3(0, 0, 0);
    h.nearestVert = 0;
    h.nearestVertPos = Vec3(2.0f, 0, 0);
    h.nearestEdge = 0;
    h.nearestEdgeA = Vec3(2.0f,  0.1f, 0);
    h.nearestEdgeB = Vec3(2.0f, -0.1f, 0);

    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.Face, "no candidate within the default radius must resolve to Face");
    assert(t.vert == -1 && t.edge == -1);
}


unittest { // resolveHoverTarget — near-threshold, independently computed:
           // a 0.1499-world-unit offset at S=80px/unit projects to ~11.992px
           // (0.1499*80=11.992), a hair BELOW the 12.0f this case passes rather
           // than exactly on it (review NIT-2 — the prior version picked an
           // offset landing EXACTLY at the threshold and asserted `==`
           // through the full lookAt/perspective/mulMV pipeline; that FP
           // chain isn't guaranteed bit-exact, so resting a "must snap"
           // assertion on hitting the boundary precisely was fragile).
           // Comfortably-separated margins on both sides (12.0 - 11.992 =
           // 0.008px "inside", 11.992 - 11.9 = 0.092px "outside") are each
           // orders of magnitude larger than any plausible FP rounding
           // noise from that pipeline, so this still exercises the `<=`
           // inclusive comparison's intent (a just-inside point snaps)
           // without resting on exact equality.
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit           = true;
    h.point         = Vec3(0, 0, 0);
    h.nearestVert   = 7;
    h.nearestVertPos = Vec3(0.1499f, 0, 0);   // ~11.992px from the hit
    h.nearestEdge   = -1;

    auto justInside = resolveHoverTarget(h, vp, 12.0f);
    assert(justInside.kind == HoverTargetKind.Vertex,
        "a point just inside the snap radius must snap");

    auto justOutside = resolveHoverTarget(h, vp, 11.9f);
    assert(justOutside.kind == HoverTargetKind.Face,
        "a threshold just below the point's actual distance must NOT snap");
}


unittest { // resolveHoverTarget — stale candidate reset to -1 by the
           // producer's consistency guard (review NIT-1) resolves to Face,
           // not a phantom vertex at the world origin. Before NIT-1,
           // `raycastBackground` (source/toolpipe/stages/constrain.d)
           // could leave `nearestVert`/`nearestEdge` at whatever
           // nearestFaceVertex/nearestFaceEdge returned while separately
           // gating ONLY the position fill on an in-bounds check — so a
           // stale index (>= 0) could reach here paired with the packet's
           // default `Vec3(0,0,0)` position. Since the hit point itself is
           // ALSO at the origin, a buggy producer trusting that pairing
           // would make resolveHoverTarget snap to a "vertex" that is
           // really just the struct default, at 0px away — a false
           // positive indistinguishable from a genuine coincident hit.
           // `consistentCandidateIndex` (constraint.d) now resets the
           // index to -1 in that case, so this packet (as the FIXED
           // producer would actually publish it) must fall through to
           // Face instead.
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit            = true;
    h.point          = Vec3(0, 0, 0);          // projects to (400, 400)
    h.nearestVert    = -1;                     // consistentCandidateIndex()'s output
    h.nearestVertPos = Vec3(0, 0, 0);           // struct default — never actually filled
    h.nearestEdge    = -1;                      // same story for the edge candidate
    h.nearestEdgeA   = Vec3(0, 0, 0);
    h.nearestEdgeB   = Vec3(0, 0, 0);

    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.Face,
        "a reset (-1) candidate must never resolve to a phantom origin vertex/edge");
    assert(t.vert == -1 && t.edge == -1);
}
