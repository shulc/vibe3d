// Task 1860 — a selected element that is BEHIND geometry is drawn through it,
// blended, and a selected element in FRONT is not.
//
// ---------------------------------------------------------------------------
// Why this file exists at all, and why the counters are not enough
// ---------------------------------------------------------------------------
// `test_frame_counts.d` pins the STRUCTURE of the change: the highlight is
// submitted twice per frame, and its `expectedEdgeCalls` / vertex-pass
// formulas are exact, so a missing second pass reads as a wrong NUMBER there.
// What a submission census cannot see is what the second submission DOES. A
// second pass that forgot to invert the depth comparison, or forgot to set its
// alpha, produces byte-identical counts. Those are the two most plausible ways
// to get this wrong, so they are the two this file is built to separate.
//
// ---------------------------------------------------------------------------
// THREE ELEMENT TYPES, THREE ARMS, AND WHY ONE ARM IS NOT ENOUGH
// ---------------------------------------------------------------------------
// The occluded pass is issued from THREE draw entry points — `drawEdges`,
// `drawVertices` and `drawSelectedFacesOverlay` — and until this file grew its
// second arm only the edge one was probed. That gap was not theoretical:
// mutating pass B at the VERTEX site alone (its depth compare back to
// `GL_LEQUAL`, its alpha never written) left every gate in this project green
// while an occluded selected vertex vanished behind the model — neither the
// old law nor the new one. A mutation applied to BOTH sites at once cannot
// find that, because the edge arm's red hides the vertex site's silence. So U1
// probes an occluded EDGE and an occluded VERTEX, on one rig, and each arm has
// to be able to redden on its own site.
//
// U3 (task 1862) is the POLYGON FILL, the third site and the last selection
// surface that was still drawing through the model at full strength. It is a
// SEPARATE unittest block rather than a third arm of U1, and that is the same
// isolation rule stated the other way round: druntime stops a module at its
// first failed assert, so a mutation that must redden the fill has to be able
// to redden it in a block the edge arm cannot pre-empt.
//
// The fill's own hazard, which neither of the other two has: it is a 25 %
// SCREEN-DOOR STIPPLE. Three of every four pixels it covers are `discard`ed
// and read the surface underneath, so a single probe that happens to land on a
// discarded sample reads the background and "the occluded fill is not at full
// strength" passes for the wrong reason. The keep predicate has period 4 in x
// and 2 in y, so an offset found at one probe does NOT transfer to another
// (the two probes are projections of different world points; neither
// congruence holds by construction). U3 therefore reads a 4x2 NEIGHBOURHOOD at
// each site independently and asserts it splits exactly 6 surface / 2 fill —
// which doubles as a positive control on the lattice itself.
//
// ---------------------------------------------------------------------------
// THE DISCRIMINATING CELL — named before anything was driven
// ---------------------------------------------------------------------------
// ONE selected edge, HALF of it behind an opaque face and half of it clear of
// that face, in ONE frame. Same edge, same colour, same pass; the only thing
// that differs between the two probes is what is in front of them. The vertex
// arm reuses the same rig for the same reason: the bar's two top CORNERS are
// one behind the front quad and one clear of it, so the two dots differ in
// nothing but what is in front of them either.
//
//   * a CLOSED SOLID is refused: on a closed body "occluded" and "back-facing"
//     are the same set, so every candidate rule agrees and the fixture decides
//     nothing. The rig is an OPEN mesh of two quads.
//   * a FULLY VISIBLE selection is refused: it cannot separate "opaque
//     highlight" from "see-through highlight" — both paint the same pixels the
//     same colour. The occluded half is the whole point.
//
//     front quad  z = +1, x in [-1, 1], y in [-1, 1]     unselected, opaque
//     back  bar   z = -1, x in [-0.6, 3], y in [-0.5, 0.5]   its edges selected
//
// The bar's top edge runs from x = -0.6 to x = 3 at y = 0.5. Its left part is
// behind the front quad; its right part sticks out past the quad's x = 1 edge
// into clear space. Camera frontal, so +z is toward the eye.
//
// Four readings, and EVERY candidate implementation produces a different value
// at the occluded probe:
//
//   correct two-pass          -> round(0.30 * sel + 0.70 * background)
//   one pass, depth test off  -> `sel` at full strength    (what we shipped)
//   second pass missing       -> the front quad's own colour
//   alpha uniform not written -> `sel` at full strength again, WITH the
//                                submission census still green — which is
//                                exactly why both tiers exist
//
// The background is PROBED from a neighbouring pixel of the same face rather
// than written down, so the expected value is computed from the frame itself
// and a re-lit or re-themed surface cannot silently invalidate it. And the
// reading is asserted to sit further than the quantisation slack from BOTH
// endpoints, so "the blend happens to equal one of the things it blends" can
// never pass unnoticed.
//
// The fourth reading is the ALPHA channel, and it pins one specific GL call:
// the occluded pass blends colour with `GL_SRC_ALPHA / GL_ONE_MINUS_SRC_ALPHA`
// but leaves DESTINATION ALPHA alone (`GL_ZERO / GL_ONE`), because the cell's
// FBO alpha is a real attachment. A plain `glBlendFunc` would move it: at a
// destination alpha of 1.0 and a source alpha of 0.30 it composites to
// 0.3 + 0.7 = 1.0 for the naive src-alpha form... but the flat shader writes
// `u_alpha` into the source alpha, so the naive form stores
// 0.30*0.30 + 0.70*1.0 = 0.79 -> 201. This file asserts the occluded pixel's
// alpha equals its own background's, which refuses that.
//
// ---------------------------------------------------------------------------
// U2 pins the point-size wiring, on its own rig and for its own reason: after
// this change the base wire and the unselected dot share ONE colour, so a
// scan row through a vertex that lies on a horizontal edge would run the whole
// edge instead of the dot. The rig is a DIAMOND — a quad rotated 45 degrees —
// whose top vertex has two diagonal incident edges. At 45 degrees a line
// contributes exactly one pixel to the vertex's own row, and that pixel is
// inside the dot, so the run measured on that row IS the dot's width and
// nothing else.
//
// Both sizes are read at the SAME vertex in the SAME session and compared to
// each other, not to a frozen number: that fails on "both 3", on "both 6", and
// on a multiplier applied to the constant rather than to the argument, without
// depending on a driver's point-rasterisation convention.
//
// ---------------------------------------------------------------------------
// VERIFIED BY MUTATION — verbatim red output in doc/tasks/work/
// 1860-sel-display-align.md, section Мутация.
// ---------------------------------------------------------------------------

import http_client : getJson, postJson, testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.format  : format;
import std.math    : round, abs;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, DHVec3 = Vec3;

void main() {}

alias baseUrl = testBaseUrl;

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

/// A state change is visible only once a frame has RENDERED with it, and a
/// probe reads the last COMPLETED frame — so this has to cover two.
private void settle() { Thread.sleep(450.msecs); }

// ---------------------------------------------------------------------------
// Pixels
// ---------------------------------------------------------------------------

private struct Px {
    int r, g, b, a;
    bool valid;
    string toString() const {
        return valid ? format("(%d, %d, %d, a=%d)", r, g, b, a) : "<unreadable>";
    }
}

/// Probe FBO pixels, chunked so the request line stays short.
private Px[] probe(const int[2][] pts) {
    Px[] outp;
    for (size_t i = 0; i < pts.length; i += 50) {
        auto slice = pts[i .. (i + 50 > pts.length ? pts.length : i + 50)];
        string q = "/api/viewport/probe?cell=0&points=";
        foreach (k, p; slice) {
            if (k) q ~= ";";
            q ~= format("%d,%d", p[0], p[1]);
        }
        auto j = getJson(q);
        assert("error" !in j, "probe failed: " ~ j.toString);
        // The `--test` single-rendered-cell trap: a never-filled FBO reads
        // zeros, and "the selection colour is absent" would then pass for the
        // wrong reason. Assert the flag rather than trusting the default.
        assert(j["renders"].type == JSONType.true_,
            "the probed cell is not rendered under --test; every reading below "
            ~ "is void");
        foreach (e; j["points"].array) {
            Px p;
            if ("error" in e) { outp ~= p; continue; }
            p.r = cast(int)e["r"].integer;
            p.g = cast(int)e["g"].integer;
            p.b = cast(int)e["b"].integer;
            p.a = cast(int)e["a"].integer;
            p.valid = true;
            outp ~= p;
        }
    }
    return outp;
}

private Px probe1(int x, int y) {
    auto ps = probe([[x, y]]);
    assert(ps.length == 1 && ps[0].valid,
           format("pixel (%d, %d) could not be read", x, y));
    return ps[0];
}

private bool sameRgb(Px a, Px b, int slack = 1) {
    return abs(a.r - b.r) <= slack && abs(a.g - b.g) <= slack
        && abs(a.b - b.b) <= slack;
}

// ---------------------------------------------------------------------------
// The colours the draw passes hand to GL
// ---------------------------------------------------------------------------
//
// Declared as the FLOATS, and converted here, for the same reason
// `test_item_mode_geometry_gate.d` spells its predicate out: the framebuffer
// stores `round(f * 255)` and a channel whose product lands on a tie is the
// implementation's to round. None of the three below is a tie
// (255.0, 168.3, 40.8 / 183.6 / 140.0, 181.05, 198.9), so each is one value,
// but the derivation stays visible.

private enum float[3] kSelectionRgb    = [1.00f,  0.66f,  0.16f];
private enum float[3] kPreHighlightRgb = [0.549f, 0.710f, 0.780f];
private enum float[3] kWireframeRgb    = [0.72f,  0.72f,  0.72f];

/// This is a TRANSPARENCY of 0.70 subtracted from 1, not an opacity of 0.30
/// read straight off. See viewport_scheme.kOccludedSelectionAlpha.
private enum double kOccludedAlpha = 0.30;

private int toByte(float f) { return cast(int)round(f * 255.0); }

private Px asPx(const float[3] rgb) {
    return Px(toByte(rgb[0]), toByte(rgb[1]), toByte(rgb[2]), 255, true);
}

/// What the occluded half MUST read, given the background it composites over.
private Px blendOver(const float[3] src, Px dst) {
    int ch(float s, int d) {
        return cast(int)round(kOccludedAlpha * (s * 255.0)
                            + (1.0 - kOccludedAlpha) * d);
    }
    return Px(ch(src[0], dst.r), ch(src[1], dst.g), ch(src[2], dst.b),
              dst.a, true);
}

// ---------------------------------------------------------------------------
// The rig
// ---------------------------------------------------------------------------

private struct Cell { int vx, vy, vw, vh; }

private Cell cell() {
    auto c = getJson("/api/camera");
    return Cell(cast(int)c["vpX"].integer,  cast(int)c["vpY"].integer,
                cast(int)c["width"].integer, cast(int)c["height"].integer);
}

/// World point -> FBO pixel, through the live camera. No probe below is a
/// magic number: a different window size moves them all with it.
private int[2] fbo(DHVec3 world) {
    auto camS = fetchCamera(baseUrl);
    auto vp   = viewportFromCamera(camS);
    float px, py;
    assert(projectToWindow(world, vp, px, py),
        format("rig: the world point (%g, %g, %g) is behind the camera",
               world.x, world.y, world.z));
    return [cast(int)round(px) - camS.vpX, cast(int)round(py) - camS.vpY];
}

private void loadMesh(string verts, string faces) {
    auto j = postJson("/api/load-mesh",
                      format(`{"vertices":%s,"faces":%s}`, verts, faces));
    assert(j["status"].str == "ok", "load-mesh failed: " ~ j.toString);
}

/// Frontal camera: the eye ends up on +z, so a larger z is NEARER. Set AFTER
/// the mesh load, which resets the camera.
private void frontalCamera(double distance) {
    post(baseUrl ~ "/api/camera?viewport=0",
         format(`{"azimuth":0.0,"elevation":0.0,"distance":%.3f}`, distance));
    settle();
    auto c = fetchCamera(baseUrl);
    assert(c.eye.z > 1.0f && abs(c.eye.x) < 0.01f && abs(c.eye.y) < 0.01f,
        format("rig: the camera must sit on +z looking at the origin, so that "
               ~ "a larger z is nearer the eye. It is at (%g, %g, %g), and "
               ~ "every 'in front of' claim below would be reversed",
               c.eye.x, c.eye.y, c.eye.z));
}

private void selectEdges(const long[] idx) {
    import std.conv : to;
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    postJson("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":` ~ s ~ `]}`));
    settle();
}

private void selectVerts(const long[] idx) {
    import std.conv : to;
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":` ~ s ~ `]}`));
    settle();
}

private string selType() { return getJson("/api/selection")["selType"].str; }

/// The edge index of the segment joining model vertices `a` and `b`, read from
/// /api/model. DERIVED, never typed: an edge array is deduplicated and ordered
/// by the builder, so a literal index is a claim about an implementation
/// detail and goes stale silently.
private long edgeBetween(long a, long b) {
    auto edges = getJson("/api/model")["edges"].array;
    foreach (ei, e; edges) {
        immutable long p = e.array[0].integer, q = e.array[1].integer;
        if ((p == a && q == b) || (p == b && q == a)) return cast(long)ei;
    }
    assert(false, format("rig: the mesh has no edge between vertices %d and %d",
                         a, b));
}

/// Park the pointer clear of the geometry so nothing is pre-highlighted while
/// the selection colours are read. The pre-highlight is a THIRD colour and
/// would otherwise turn one probe into a silent exception.
private void parkPointer(Cell c) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n", c.vx, c.vy, c.vw, c.vh);
    foreach (i; 0 .. 3)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,`
                      ~ `"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                      30.0 + i * 20.0, c.vx + 10, c.vy + c.vh - 10);
    playAndWait(log, baseUrl);
    settle();
}

private void hoverAt(Cell c, int fx, int fy) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n", c.vx, c.vy, c.vw, c.vh);
    foreach (i; 0 .. 5)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,`
                      ~ `"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                      50.0 + i * 20.0, fx + c.vx, fy + c.vy);
    playAndWait(log, baseUrl);
    settle();
}

private void selectPolys(const long[] idx) {
    import std.conv : to;
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    postJson("/api/command", commandBody("mesh.select", `{"mode":"polygons","indices":` ~ s ~ `]}`));
    settle();
}

/// Which face is IN FRONT of this cell pixel, asked of a channel that is not
/// the pixel itself. `/api/pick` raycasts the mesh and answers the NEAREST
/// face, so it is what turns "the probe is occluded" from an assumption about
/// the projection into a reading. Takes cell coordinates and adds the cell
/// origin, because the pick endpoint speaks window coordinates.
private long faceUnder(Cell c, const int[2] p) {
    auto j = getJson(format("/api/pick?x=%d&y=%d&engine=bvh",
                            p[0] + c.vx, p[1] + c.vy));
    return j["faceIndex"].integer;
}

/// The 4x2 neighbourhood whose top-left corner is `p`, as raw pixels.
private Px[] block4x2(const int[2] p, string what) {
    int[2][] pts;
    foreach (dy; 0 .. 2) foreach (dx; 0 .. 4) pts ~= [p[0] + dx, p[1] + dy];
    auto blk = probe(pts);
    assert(blk.length == 8,
        format("the %s block came back with %d pixels, not 8", what, blk.length));
    foreach (i, px; blk)
        assert(px.valid, format("the %s block's pixel (%d, %d) is unreadable",
                                what, pts[i][0], pts[i][1]));
    return blk;
}

private string dumpBlock(const int[2] p, const Px[] blk) {
    string d;
    foreach (i, px; blk)
        d ~= format("(%d,%d)=%s ", p[0] + (i % 4), p[1] + (i / 4), px.toString);
    return d;
}

/// Assert the 4x2 block is ONE colour and return it. The positive control that
/// a window is clean surface — no wireframe, no dot, no silhouette, and no
/// stipple — before any coverage is counted over it.
private Px pureBlock(const int[2] p, string what) {
    auto blk = block4x2(p, what);
    foreach (px; blk)
        assert(sameRgb(px, blk[0]),
            format("rig premise: the %s 4x2 window at (%d, %d) is not one flat "
                   ~ "surface, so every count taken over it below would be "
                   ~ "counting a wire, a dot or a silhouette: %s",
                   what, p[0], p[1], dumpBlock(p, blk)));
    return blk[0];
}

/// The 25 %% stipple's two readings at one site: the SURFACE it leaves alone
/// and the FILL it paints, recovered from the block's own 6/2 split rather
/// than from a copy of the shader's keep predicate.
private struct FillBlock { Px surface; Px fill; }

private FillBlock fillBlock(const int[2] p, string what) {
    auto blk = block4x2(p, what);
    // How many of the eight each pixel agrees with, itself included. A surface
    // pixel must agree with 6, a fill pixel with 2. Nothing here knows WHICH
    // pixels the lattice keeps — that the split is 6/2 at all is the assertion.
    int[8] n;
    foreach (i; 0 .. 8) foreach (j; 0 .. 8) if (sameRgb(blk[i], blk[j])) n[i]++;

    FillBlock r;
    int nSurf = 0, nFill = 0;
    foreach (i; 0 .. 8) {
        if      (n[i] == 6) { r.surface = blk[i]; nSurf++; }
        else if (n[i] == 2) { r.fill    = blk[i]; nFill++; }
    }
    assert(nSurf == 6 && nFill == 2,
        format("the %s 4x2 window must split 6 surface / 2 fill — the "
               ~ "selection fill is a 25 %% screen door and this window is two "
               ~ "full periods in x and one in y. It splits %d / %d, over "
               ~ "per-pixel agreement counts %s. All eight agreeing means the "
               ~ "fill is ABSENT from this window (or is the same colour as "
               ~ "the surface, in which case nothing below discriminates); a "
               ~ "6/2 split the other way round means it went opaque over "
               ~ "three quarters of the face: %s",
               what, nSurf, nFill, n, dumpBlock(p, blk)));
    return r;
}

// ===========================================================================
// U1 — the occluded half of a selection is drawn THROUGH the surface, blended;
//      the visible half is not. Asserted at BOTH draw entry points: an edge
//      arm over `drawEdges`, then a vertex arm over `drawVertices`, each able
//      to redden on a mutation confined to its own site.
// ===========================================================================
unittest {
    postJson("/api/reset", "{}");
    settle();
    loadMesh(`[[-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1],`
             ~ `[-0.6,-0.5,-1],[3.0,-0.5,-1],[3.0,0.5,-1],[-0.6,0.5,-1]]`,
             `[[0,1,2,3],[4,5,6,7]]`);
    frontalCamera(9.0);
    auto c = cell();
    parkPointer(c);

    // The two probes on the SAME edge of the back bar: y = 0.5, z = -1.
    //   x = 0.0  -> inside the front quad's footprint  => OCCLUDED
    //   x = 2.0  -> past the front quad's x = 1 edge   => CLEAR
    immutable int[2] pOcc = fbo(DHVec3(0.0f,  0.5f, -1.0f));
    immutable int[2] pVis = fbo(DHVec3(2.0f,  0.5f, -1.0f));
    // The background for the occluded probe: the SAME face, a few pixels below
    // the line so no edge or dot is on it. Read live rather than written down.
    immutable int[2] pBg  = fbo(DHVec3(0.0f,  0.42f, -1.0f));

    // The VERTEX arm's three probes, on the same rig and by the same rule.
    // The bar's two top corners are model vertices 7 and 6:
    //   v7 = (-0.6, 0.5, -1)  -> inside the front quad's footprint => OCCLUDED
    //   v6 = ( 3.0, 0.5, -1)  -> past the front quad's x = 1 edge  => CLEAR
    // Its background is read NEAR v7 rather than reusing `pBg`, so the
    // expected blend is computed from the surface the dot actually composites
    // over: 0.25 in x from the bar's left edge and 0.22 in y from its top
    // edge, which at this camera is tens of pixels clear of both a 1 px line
    // and a 6 px dot.
    immutable int[2] pVOcc = fbo(DHVec3(-0.6f,  0.5f,  -1.0f));
    immutable int[2] pVVis = fbo(DHVec3( 3.0f,  0.5f,  -1.0f));
    immutable int[2] pVBg  = fbo(DHVec3(-0.35f, 0.28f, -1.0f));

    static struct Named { string what; int[2] p; }
    foreach (n; [Named("occluded", pOcc), Named("visible", pVis),
                 Named("background", pBg),
                 Named("occluded vertex", pVOcc), Named("clear vertex", pVVis),
                 Named("vertex background", pVBg)])
        assert(n.p[0] >= 4 && n.p[1] >= 4
            && n.p[0] < c.vw - 4 && n.p[1] < c.vh - 4,
            format("rig: the %s probe lands at FBO (%d, %d), off or against "
                   ~ "the edge of the %dx%d cell", n.what, n.p[0], n.p[1],
                   c.vw, c.vh));
    assert(pOcc[0] != pVis[0],
        "rig: the two probes on the selected edge landed on the same column");

    // ---- RIG PREMISE, asserted BEFORE anything is selected ----------------
    // The occluded probe must currently read the FRONT quad, and the visible
    // one must not. If that is not true the whole block is measuring a
    // geometry that has no occlusion in it, and every reading below would be
    // about the wrong thing.
    selectEdges([]);
    immutable Px preOcc = probe1(pOcc[0], pOcc[1]);
    immutable Px preBg  = probe1(pBg[0],  pBg[1]);
    assert(sameRgb(preOcc, preBg),
        format("rig premise: with nothing selected the occluded probe %s and "
               ~ "its background %s must both be the front quad's surface — "
               ~ "they differ, so the probe is not on the face and there is no "
               ~ "occlusion to measure", preOcc.toString, preBg.toString));
    immutable Px sel = asPx(kSelectionRgb);
    assert(!sameRgb(preOcc, sel, 8),
        format("rig premise: the front quad's surface %s is already the "
               ~ "selection colour %s — the reading below could not tell a "
               ~ "blend from the surface it blends over",
               preOcc.toString, sel.toString));

    // The visible probe currently sits on the BASE WIREFRAME of the same edge,
    // which is the positive control that the probe is on the line at all.
    immutable Px preVis = probe1(pVis[0], pVis[1]);
    assert(sameRgb(preVis, asPx(kWireframeRgb)),
        format("rig premise: unselected, the clear half of the bar's top edge "
               ~ "must read the base wireframe colour %s — it reads %s, so "
               ~ "this probe is not on the line",
               asPx(kWireframeRgb).toString, preVis.toString));

    // ---- Select that ONE edge --------------------------------------------
    immutable long topEdge = edgeBetween(6, 7);   // (3, 0.5, -1) .. (-0.6, 0.5, -1)
    selectEdges([topEdge]);
    assert(selType() == "edge",
        "the app is feeding back " ~ selType() ~ ", not the edge type — the "
        ~ "selection highlight pass under test would not be the one running");

    immutable Px gotOcc = probe1(pOcc[0], pOcc[1]);
    immutable Px gotVis = probe1(pVis[0], pVis[1]);
    immutable Px bg     = probe1(pBg[0],  pBg[1]);

    // (1) THE VISIBLE HALF is the selection colour at full strength.
    assert(sameRgb(gotVis, sel),
        format("the CLEAR half of the selected edge must be the selection "
               ~ "colour %s at full strength; it reads %s",
               sel.toString, gotVis.toString));

    // (2) THE OCCLUDED HALF is the blend, computed from the background as it
    //     is in THIS frame.
    immutable Px want = blendOver(kSelectionRgb, bg);
    assert(sameRgb(gotOcc, want),
        format("the OCCLUDED half of the selected edge must be %.2f of the "
               ~ "selection colour over the surface in front of it: %s over "
               ~ "%s = %s. It reads %s. Full strength (%s) means one pass with "
               ~ "the depth test off, or a second pass whose alpha was never "
               ~ "written; the plain surface (%s) means the second pass is not "
               ~ "happening at all",
               kOccludedAlpha, sel.toString, bg.toString, want.toString,
               gotOcc.toString, sel.toString, bg.toString));

    // (3) NON-VACUITY. A blend is only evidence if it is distinguishable from
    //     both of the things it blends. Two of the four candidate
    //     implementations land exactly on an endpoint, so if the endpoints are
    //     within the slack of the expected value this assertion says nothing.
    assert(!sameRgb(want, sel, 2),
        format("the expected blend %s is indistinguishable from the selection "
               ~ "colour %s — this rig cannot see a missing alpha",
               want.toString, sel.toString));
    assert(!sameRgb(want, bg, 2),
        format("the expected blend %s is indistinguishable from the surface "
               ~ "%s — this rig cannot see a missing second pass",
               want.toString, bg.toString));

    // (4) DESTINATION ALPHA IS UNTOUCHED. The colour blends; the FBO's alpha
    //     attachment must come out of the occluded pass exactly as its
    //     neighbours did. This is the direct guard on
    //     glBlendFuncSeparate(..., GL_ZERO, GL_ONE): a plain glBlendFunc
    //     writes `srcA*srcA + (1-srcA)*dstA` here and moves it.
    assert(gotOcc.a == bg.a,
        format("the occluded pass must leave DESTINATION ALPHA alone — the "
               ~ "blended pixel carries a=%d where the surface beside it "
               ~ "carries a=%d. The cell FBO's alpha is a real attachment; a "
               ~ "plain glBlendFunc punches holes in it",
               gotOcc.a, bg.a));

    // =======================================================================
    // THE VERTEX ARM. Same rig, same frame geometry, the OTHER draw entry
    // point. `drawVertices` issues its own pair of passes, and a mutation
    // confined to that function is invisible to everything above.
    // =======================================================================
    selectEdges([]);
    selectVerts([]);
    assert(selType() == "vertex",
        "the app is feeding back " ~ selType() ~ ", not the vertex type — the "
        ~ "dot passes under test would not be the ones running");

    // ---- RIG PREMISE, before anything is selected -------------------------
    // Unselected, the occluded corner's dot is depth-tested away, so its probe
    // and its background must BOTH read the front quad. If they differ, the
    // probe is not on plain surface and the blend computed from it is void.
    immutable Px preVOcc = probe1(pVOcc[0], pVOcc[1]);
    immutable Px preVBg  = probe1(pVBg[0],  pVBg[1]);
    assert(sameRgb(preVOcc, preVBg),
        format("rig premise: with nothing selected the occluded VERTEX probe "
               ~ "%s and its background %s must both be the front quad's "
               ~ "surface — they differ, so one of the two is on a line or a "
               ~ "dot and there is no clean occlusion to measure",
               preVOcc.toString, preVBg.toString));
    assert(!sameRgb(preVOcc, sel, 8),
        format("rig premise: the front quad's surface %s is already the "
               ~ "selection colour %s — the vertex reading below could not "
               ~ "tell a blend from the surface it blends over",
               preVOcc.toString, sel.toString));

    // The clear corner currently carries the UNSELECTED dot, which is the
    // positive control that the probe is on a dot at all rather than on empty
    // surface a few pixels off it.
    immutable Px preVVis = probe1(pVVis[0], pVVis[1]);
    assert(sameRgb(preVVis, asPx(kWireframeRgb)),
        format("rig premise: unselected, the bar's clear top corner must "
               ~ "carry the unselected vertex dot in the wireframe colour %s "
               ~ "— it reads %s, so this probe is not on the dot",
               asPx(kWireframeRgb).toString, preVVis.toString));

    // ---- Select BOTH corners ---------------------------------------------
    // One selection, two dots, one frame: the only difference between the two
    // readings is what is in front of each.
    selectVerts([6, 7]);
    assert(selType() == "vertex",
        "the app is feeding back " ~ selType() ~ ", not the vertex type");

    immutable Px gotVOcc = probe1(pVOcc[0], pVOcc[1]);
    immutable Px gotVVis = probe1(pVVis[0], pVVis[1]);
    immutable Px vbg     = probe1(pVBg[0],  pVBg[1]);

    // (5) THE CLEAR DOT is the selection colour at full strength.
    assert(sameRgb(gotVVis, sel),
        format("the CLEAR selected vertex dot must be the selection colour %s "
               ~ "at full strength; it reads %s", sel.toString,
               gotVVis.toString));

    // (6) THE OCCLUDED DOT is the blend, over the surface in front of it.
    immutable Px wantV = blendOver(kSelectionRgb, vbg);
    assert(sameRgb(gotVOcc, wantV),
        format("the OCCLUDED selected vertex dot must be %.2f of the "
               ~ "selection colour over the surface in front of it: %s over "
               ~ "%s = %s. It reads %s. Full strength (%s) means one pass with "
               ~ "the depth test off, or a second pass whose alpha was never "
               ~ "written; the plain surface (%s) means the vertex pass's "
               ~ "second submission is not happening at all — and note that "
               ~ "the EDGE assertions above stay green for every one of those, "
               ~ "because `drawVertices` has its own pair of passes",
               kOccludedAlpha, sel.toString, vbg.toString, wantV.toString,
               gotVOcc.toString, sel.toString, vbg.toString));

    // (7) NON-VACUITY, the same two guards the edge arm carries: a blend is
    //     evidence only if it is distinguishable from both endpoints.
    assert(!sameRgb(wantV, sel, 2),
        format("the expected vertex blend %s is indistinguishable from the "
               ~ "selection colour %s — this arm cannot see a missing alpha",
               wantV.toString, sel.toString));
    assert(!sameRgb(wantV, vbg, 2),
        format("the expected vertex blend %s is indistinguishable from the "
               ~ "surface %s — this arm cannot see a missing second pass",
               wantV.toString, vbg.toString));

    // (8) DESTINATION ALPHA IS UNTOUCHED at the vertex site too. The blend
    //     state is shared between the two draw entry points, but "shared" is
    //     a claim about today's code, not a licence to leave one site unprobed.
    assert(gotVOcc.a == vbg.a,
        format("the occluded vertex pass must leave DESTINATION ALPHA alone — "
               ~ "the blended dot carries a=%d where the surface beside it "
               ~ "carries a=%d", gotVOcc.a, vbg.a));
}

// ===========================================================================
// U2 — the vertex dot is BASE x MULTIPLIER, and a pre-highlighted dot is drawn
//      at the SELECTED size.
// ===========================================================================
unittest {
    postJson("/api/reset", "{}");
    settle();
    // A DIAMOND: a quad rotated 45 degrees, so the two edges meeting at the
    // top vertex leave its own scan row immediately. See the header.
    loadMesh(`[[0,1,0],[1,0,0],[0,-1,0],[-1,0,0]]`, `[[0,1,2,3]]`);
    frontalCamera(6.0);
    auto c = cell();
    parkPointer(c);

    immutable int[2] apex = fbo(DHVec3(0.0f, 1.0f, 0.0f));
    assert(apex[0] >= 12 && apex[1] >= 12
        && apex[0] < c.vw - 12 && apex[1] < c.vh - 12,
        format("rig: the diamond's apex lands at FBO (%d, %d), too close to "
               ~ "the %dx%d cell edge to scan a run across it",
               apex[0], apex[1], c.vw, c.vh));

    /// The run of `want`-coloured pixels centred on the apex, along its own
    /// row. A window of 21 is far wider than any dot size this project could
    /// plausibly ship, so a run that fills it is reported as such rather than
    /// silently clipped.
    int runAt(const float[3] want) {
        enum int kHalf = 10;
        int[2][] pts;
        foreach (dx; -kHalf .. kHalf + 1) pts ~= [apex[0] + dx, apex[1]];
        auto row = probe(pts);
        immutable Px w = asPx(want);
        int n = 0;
        foreach (p; row) if (p.valid && sameRgb(p, w)) ++n;
        assert(n < 2 * kHalf + 1,
            format("the run of %s filled the whole %d-pixel window — it is not "
                   ~ "a dot that is being measured", w.toString, 2 * kHalf + 1));
        return n;
    }

    // ---- unselected ------------------------------------------------------
    selectVerts([]);
    assert(selType() == "vertex",
        "the app is feeding back " ~ selType() ~ ", not the vertex type — the "
        ~ "dot pass under test is not the one running");
    immutable int unsel = runAt(kWireframeRgb);
    assert(unsel > 0,
        "no unselected dot at the apex at all — the vertex-dot pass is not "
        ~ "running, so nothing below measures a size");

    // ---- selected --------------------------------------------------------
    selectVerts([0]);
    immutable int selRun = runAt(kSelectionRgb);

    // ---- pre-highlighted -------------------------------------------------
    // A different vertex is hovered from the one that is selected would mix
    // the two; hovering the SELECTED apex is the simplest cell, because the
    // hover pass draws last and wins the pixel.
    selectVerts([]);
    hoverAt(c, apex[0], apex[1]);
    immutable int hoverRun = runAt(kPreHighlightRgb);

    // ---- the law ---------------------------------------------------------
    //
    // A RELATION between two runs measured at the same vertex in the same
    // session, not two frozen numbers. "Both 3" and "both 6" both fail it, and
    // so does a multiplier applied to the constant instead of the argument
    // (which would leave the selected dot at the unselected size for any base
    // but the shipped one — and at the shipped one there is nothing to see, so
    // the unit test carries that half).
    assert(selRun == 2 * unsel,
        format("a selected vertex dot is measured at TWICE the unselected "
               ~ "size: the apex's row carries %d unselected pixels and %d "
               ~ "selected ones", unsel, selRun));
    // A loose absolute bracket, so that a rig which somehow measured 1 and 2
    // (an anti-aliased sliver, a probe off the dot) cannot satisfy the ratio.
    assert(unsel >= 2 && unsel <= 4,
        format("the unselected dot measured %d px across; the shipped base is "
               ~ "3 px and a reading outside 2..4 means the probe is not on "
               ~ "the dot", unsel));
    assert(selRun >= 5 && selRun <= 8,
        format("the selected dot measured %d px across; 3 px x 2 is 6 and a "
               ~ "reading outside 5..8 means the multiplier is not being "
               ~ "applied", selRun));

    // A PRE-HIGHLIGHTED dot is drawn at the SELECTED size — measured, and in
    // our code it used to be true only because the hover pass inherited the
    // point size the selected pass had left in the GL state one line above.
    assert(hoverRun == selRun,
        format("a pre-highlighted vertex is drawn at the SELECTED size: the "
               ~ "hovered dot measured %d px across against the selected "
               ~ "dot's %d (the unselected size is %d)",
               hoverRun, selRun, unsel));

    parkPointer(c);
}

// ===========================================================================
// U3 — the selected-POLYGON FILL, the third draw entry point (task 1862).
//
//      Same rig as U1, same discriminating cell, one selected FACE instead of
//      an edge or a pair of dots: half of the back bar is behind the front
//      quad and half sticks out past it, so the two readings differ in nothing
//      but what is in front of them.
//
//      A SEPARATE unittest block, deliberately. druntime aborts a module at
//      its first failed assert, so folding this into U1 would let the edge
//      arm's red hide the fill site's silence — the exact trap the vertex arm
//      was added to close.
//
//      Four candidate implementations, four different readings at the
//      occluded probe, exactly as in U1:
//
//        correct two-pass          -> round(0.30 * fill + 0.70 * surface)
//        one pass, depth test off  -> `fill` at full strength  (pre-1862)
//        second pass missing       -> the front quad's own surface
//        alpha uniform not written -> `fill` at full strength again
//
//      ...and one more that only the fill can produce, because only the fill
//      is a stipple: a probe on a DISCARDED sample reads the surface and looks
//      exactly like "second pass missing". That is why every reading here is
//      taken over a 4x2 window with an asserted 6/2 split rather than at a
//      single pixel.
// ===========================================================================
unittest {
    postJson("/api/reset", "{}");
    settle();
    loadMesh(`[[-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1],`
             ~ `[-0.6,-0.5,-1],[3.0,-0.5,-1],[3.0,0.5,-1],[-0.6,0.5,-1]]`,
             `[[0,1,2,3],[4,5,6,7]]`);
    frontalCamera(9.0);
    auto c = cell();
    parkPointer(c);

    // ---- WHICH DISPLAY STYLE THIS RUNS UNDER, asserted not assumed --------
    // Under a style whose DrawPlan draws no faces there is no surface in the
    // depth buffer for the fill to be behind: pass A would pass everywhere,
    // pass B nowhere, and the fill would correctly paint at full strength.
    // That is a real cell of the shipped behaviour and it is NOT the cell this
    // block measures, so the plan is read back rather than trusted.
    {
        auto d = getJson("/api/viewport/display");
        auto plan = d["cells"].array[0]["plan"]["active"];
        assert(plan["drawFaces"].type == JSONType.true_,
            "rig: cell 0's display plan draws no faces, so nothing occludes "
            ~ "anything and every reading below is void — this block measures "
            ~ "the face-drawing styles, and the no-face style is a separate "
            ~ "(and deliberately full-strength) case");
    }

    // Two windows on the SAME selected face, y = 0.25 so that neither the
    // bar's own top/bottom edges (y = +-0.5) nor the ground grid's edge-on
    // line (world y = 0) is anywhere near them.
    //   x = 0.0  -> inside the front quad's footprint  => OCCLUDED
    //   x = 2.0  -> past the front quad's x = 1 edge   => CLEAR
    immutable int[2] pOccF = fbo(DHVec3(0.0f, 0.25f, -1.0f));
    immutable int[2] pVisF = fbo(DHVec3(2.0f, 0.25f, -1.0f));

    static struct Named { string what; int[2] p; }
    foreach (n; [Named("occluded fill", pOccF), Named("clear fill", pVisF)])
        assert(n.p[0] >= 4 && n.p[1] >= 4
            && n.p[0] + 4 < c.vw - 4 && n.p[1] + 2 < c.vh - 4,
            format("rig: the %s window starts at FBO (%d, %d), off or against "
                   ~ "the edge of the %dx%d cell", n.what, n.p[0], n.p[1],
                   c.vw, c.vh));
    assert(pOccF[0] + 4 <= pVisF[0] || pVisF[0] + 4 <= pOccF[0],
        "rig: the two 4x2 windows overlap in x — they must be two independent "
        ~ "readings of the same face");

    // ---- RIG PREMISE (1): WHAT IS IN FRONT, read from a second channel ----
    // `/api/pick` raycasts and answers the nearest face, so this is evidence
    // about the geometry rather than about the pixels under test. Face 0 is
    // the front quad, face 1 the back bar.
    assert(faceUnder(c, pOccF) == 0,
        format("rig premise: the OCCLUDED window must have the front quad "
               ~ "(face 0) in front of it; the picker says face %d is nearest "
               ~ "there, so there is no occlusion to measure",
               faceUnder(c, pOccF)));
    assert(faceUnder(c, pVisF) == 1,
        format("rig premise: the CLEAR window must see the back bar (face 1) "
               ~ "with nothing in front of it; the picker says face %d",
               faceUnder(c, pVisF)));

    // ---- RIG PREMISE (2): both windows are clean surface before selection --
    selectPolys([]);
    immutable Px preOccSurf = pureBlock(pOccF, "occluded (unselected)");
    immutable Px preVisSurf = pureBlock(pVisF, "clear (unselected)");
    immutable Px sel = asPx(kSelectionRgb);
    assert(!sameRgb(preOccSurf, sel, 8),
        format("rig premise: the front quad's surface %s is already the "
               ~ "selection colour %s — the occluded reading below could not "
               ~ "tell a blend from the surface it blends over",
               preOccSurf.toString, sel.toString));

    // ---- Select the BACK BAR's face --------------------------------------
    selectPolys([1]);
    assert(selType() == "polygon",
        "the app is feeding back " ~ selType() ~ ", not the polygon type — the "
        ~ "checker fill under test would not be the pass running");

    auto occ = fillBlock(pOccF, "occluded");
    auto vis = fillBlock(pVisF, "clear");

    // (1) THE CLEAR HALF is the selection colour at FULL STRENGTH.
    //     Asserted against the colour itself, not merely "not the surface": a
    //     clear fill drawn at 0.30 is still non-background, and that is exactly
    //     what a swapped GL_LEQUAL/GL_GREATER — or a depth mismatch between
    //     the fill's vertex program and the lit one — would produce.
    assert(sameRgb(vis.fill, sel),
        format("the CLEAR half of the selected face must be the selection "
               ~ "colour %s at full strength; its stipple reads %s over a "
               ~ "surface of %s. A reading part-way to the surface means the "
               ~ "two depth comparisons are the wrong way round, or the "
               ~ "visible pass is losing its own face's depth",
               sel.toString, vis.fill.toString, vis.surface.toString));

    // (2) THE SURFACE UNDER THE OCCLUDED WINDOW did not move: it is still the
    //     front quad, exactly as it read before anything was selected.
    assert(sameRgb(occ.surface, preOccSurf),
        format("the occluded window's surface changed from %s to %s when the "
               ~ "back face was selected — the fill is painting the discarded "
               ~ "samples too, so the 6/2 split below is not measuring a "
               ~ "stipple", preOccSurf.toString, occ.surface.toString));

    // (3) THE OCCLUDED HALF is the blend, computed from the surface as it is
    //     in THIS frame.
    immutable Px want = blendOver(kSelectionRgb, occ.surface);
    assert(sameRgb(occ.fill, want),
        format("the OCCLUDED half of the selected face must be %.2f of the "
               ~ "selection colour over the surface in front of it: %s over "
               ~ "%s = %s. It reads %s. Full strength (%s) means one pass with "
               ~ "the depth test off, or a second pass whose alpha was never "
               ~ "written; the plain surface (%s) means the second pass is not "
               ~ "happening at all — and note the EDGE and VERTEX arms stay "
               ~ "green for every one of those, because the fill has its own "
               ~ "pair of passes and its own program's alpha",
               kOccludedAlpha, sel.toString, occ.surface.toString,
               want.toString, occ.fill.toString, sel.toString,
               occ.surface.toString));

    // (4) NON-VACUITY. A blend is evidence only if it is distinguishable from
    //     both of the things it blends.
    assert(!sameRgb(want, sel, 2),
        format("the expected fill blend %s is indistinguishable from the "
               ~ "selection colour %s — this arm cannot see a missing alpha",
               want.toString, sel.toString));
    assert(!sameRgb(want, occ.surface, 2),
        format("the expected fill blend %s is indistinguishable from the "
               ~ "surface %s — this arm cannot see a missing second pass",
               want.toString, occ.surface.toString));

    // (5) DESTINATION ALPHA IS UNTOUCHED at the fill site too. The blend state
    //     is shared with the other two entry points, but "shared" is a claim
    //     about today's code, not a licence to leave a site unprobed — and
    //     this one binds a DIFFERENT program, whose fragment shader now writes
    //     u_alpha into the source alpha for the first time.
    assert(occ.fill.a == occ.surface.a,
        format("the occluded fill must leave DESTINATION ALPHA alone — the "
               ~ "blended stipple carries a=%d where the surface beside it "
               ~ "carries a=%d. The cell FBO's alpha is a real attachment",
               occ.fill.a, occ.surface.a));

    // (6) And the clear half did not punch the alpha either: its visible pass
    //     runs with blending OFF, so it writes u_alpha = 1.0 straight through.
    assert(vis.fill.a == vis.surface.a,
        format("the VISIBLE fill pass moved the destination alpha: the fill "
               ~ "carries a=%d against the surface's a=%d. That is the shape "
               ~ "of a program whose new u_alpha uniform was never seeded — "
               ~ "GL initialises an unset uniform to 0",
               vis.fill.a, vis.surface.a));
    assert(sameRgb(vis.surface, preVisSurf),
        format("the clear window's surface changed from %s to %s under "
               ~ "selection", preVisSurf.toString, vis.surface.toString));
}
