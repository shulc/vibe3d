// ---------------------------------------------------------------------------
// Byte-identity guard for the drag conversion seam (task 0514).
//
// `source/drag.d` collapsed three copies of the axis-projection law onto one
// core and lifted a duplicated pixel-scale scalar out of three tools. Float
// arithmetic is not associative, so "mathematically the same" is not good
// enough: the refactor has to be BIT-identical, and that is what this module
// proves.
//
// It holds FROZEN copies of the pre-refactor bodies — verbatim, expression
// order and guard order included — and a unittest that drives both the frozen
// copies and the live entry points over a spread of cameras, anchors, axes and
// pixel deltas (degenerate cases included, so every guard fires) and compares
// the results BITWISE.
//
// The frozen copies are a historical record. DO NOT "fix", tidy or re-format
// them, and do not follow drag.d if it changes: if a future change to drag.d
// makes this test fail, that change altered behaviour, and the failure is the
// point. When a task deliberately lands a new law, it deletes this module in
// the same commit rather than editing the frozen bodies.
//
// Everything here is under `version (unittest)`, so the shipping binary gets
// nothing from this file.
// ---------------------------------------------------------------------------
module drag_identity;

version (unittest):

import std.math : sqrt, PI, tan;
import math;
import handler : MoveHandler, gizmoSize, getGizmoPixels;
import drag : axisDragDelta, screenAxisDelta, haulWorldPerPixel;

// ===========================================================================
// FROZEN pre-refactor bodies — copied out of drag.d / the three haul tools at
// commit 001480c. Do not edit.
// ===========================================================================

// drag.d :: axisDragDelta(handler) — frozen.
private Vec3 frozenAxisDragDeltaHandler(
                   int mx,     int my,
                   int lastMX, int lastMY,
                   int dragAxis,
                   MoveHandler handler,
                   const ref Viewport vp,
                   out bool skip)
{
    skip = false;
    Vec3 center  = handler.center;
    Vec3 axisEnd = dragAxis == 0 ? handler.arrowX.end
                 : dragAxis == 1 ? handler.arrowY.end
                                 : handler.arrowZ.end;

    float cx, cy, cndcZ, ax_, ay_, andcZ;
    if (!projectToWindowFull(center,  vp, cx,  cy,  cndcZ) ||
        !projectToWindowFull(axisEnd, vp, ax_, ay_, andcZ))
    { skip = true; return Vec3(0,0,0); }

    float sdx = ax_ - cx, sdy = ay_ - cy;
    float slen2 = sdx*sdx + sdy*sdy;
    if (slen2 < 1.0f) { skip = true; return Vec3(0,0,0); }

    Vec3  ae      = axisEnd - center;
    float axisLen = sqrt(ae.x*ae.x + ae.y*ae.y + ae.z*ae.z);
    if (axisLen < 1e-9f) { skip = true; return Vec3(0,0,0); }
    Vec3 axisDir = ae / axisLen;

    float d = ((mx - lastMX) * sdx + (my - lastMY) * sdy) / slen2 * axisLen;
    return axisDir * d;
}

// drag.d :: axisDragDelta(inputBasis) — frozen.
private Vec3 frozenAxisDragDeltaBasis(
                   int mx,     int my,
                   int lastMX, int lastMY,
                   int dragAxis,
                   MoveHandler handler,
                   Vec3 inputBasisX, Vec3 inputBasisY, Vec3 inputBasisZ,
                   const ref Viewport vp,
                   out bool skip)
{
    skip = false;
    Vec3 center    = handler.center;
    Vec3 inputAxis = dragAxis == 0 ? inputBasisX
                   : dragAxis == 1 ? inputBasisY
                                   : inputBasisZ;

    Vec3  ae      = handler.arrowX.end - center;
    float axisLen = sqrt(ae.x*ae.x + ae.y*ae.y + ae.z*ae.z);
    if (axisLen < 1e-9f) { skip = true; return Vec3(0,0,0); }

    Vec3 axisEnd = center + inputAxis * axisLen;

    float cx, cy, cndcZ, ax_, ay_, andcZ;
    if (!projectToWindowFull(center,  vp, cx,  cy,  cndcZ) ||
        !projectToWindowFull(axisEnd, vp, ax_, ay_, andcZ))
    { skip = true; return Vec3(0,0,0); }

    float sdx = ax_ - cx, sdy = ay_ - cy;
    float slen2 = sdx*sdx + sdy*sdy;
    if (slen2 < 1.0f) { skip = true; return Vec3(0,0,0); }

    float d = ((mx - lastMX) * sdx + (my - lastMY) * sdy) / slen2 * axisLen;
    return inputAxis * d;
}

// drag.d :: screenAxisDelta — frozen.
private Vec3 frozenScreenAxisDelta(
                     int mx,     int my,
                     int lastMX, int lastMY,
                     Vec3 origin, Vec3 axis,
                     const ref Viewport vp,
                     out bool skip)
{
    skip = false;
    Vec3 tip = origin + axis;
    float ox, oy, ondcZ, tx, ty, tndcZ;
    if (!projectToWindowFull(origin, vp, ox, oy, ondcZ) ||
        !projectToWindowFull(tip,    vp, tx, ty, tndcZ))
    { skip = true; return Vec3(0,0,0); }

    float sdx = tx - ox, sdy = ty - oy;
    float slen2 = sdx*sdx + sdy*sdy;
    if (slen2 < 1.0f) { skip = true; return Vec3(0,0,0); }

    float axisLen = sqrt(axis.x*axis.x + axis.y*axis.y + axis.z*axis.z);
    float d = ((mx - lastMX) * sdx + (my - lastMY) * sdy) / slen2 * axisLen;
    return axis * d;
}

// poly_inset_tool.d / vert_merge_tool.d / poly_bevel.d :: haulWorldPerPixel —
// frozen tail (the three copies were identical below the anchor).
private float frozenHaulWorldPerPixel(Vec3 anchor, const ref Viewport vp) {
    float px = getGizmoPixels();
    if (px < 1e-6f) px = 90.0f;
    return gizmoSize(anchor, vp, 1.0f) / px;
}

// ===========================================================================
// The sweep
// ===========================================================================

private bool bitEq(float a, float b) @trusted {
    return *cast(const(uint)*)&a == *cast(const(uint)*)&b;
}

private bool bitEq(Vec3 a, Vec3 b) {
    return bitEq(a.x, b.x) && bitEq(a.y, b.y) && bitEq(a.z, b.z);
}

private Viewport mkVp(Vec3 eye, Vec3 focus, bool ortho, int w, int h, int ox, int oy,
                      float halfH = 2.0f) {
    Viewport vp;
    vp.view   = lookAt(eye, focus, Vec3(0, 1, 0));
    float asp = cast(float)w / cast(float)h;
    vp.proj   = ortho ? orthographicMatrix(halfH, asp, 0.1f, 100.0f)
                      : perspectiveMatrix(cast(float)(45.0 * PI / 180.0), asp, 0.05f, 500.0f);
    vp.width  = w;
    vp.height = h;
    vp.x      = ox;
    vp.y      = oy;
    vp.eye    = eye;
    vp.focus  = focus;
    return vp;
}

unittest {
    // --- cameras: near/far, oblique, near-top-down, offset viewport, ortho ---
    Viewport[] vps = [
        mkVp(Vec3(0,    0,   5),    Vec3(0,0,0), false, 1280, 720,  0,  0),
        mkVp(Vec3(4,    3,   5),    Vec3(0,0,0), false, 1280, 720,  0,  0),
        mkVp(Vec3(0.2f, 0.3f, 0.6f),Vec3(0,0,0), false,  800, 600,  0,  0), // very close
        mkVp(Vec3(0.1f, 6,   0.05f),Vec3(0,0,0), false, 1920,1080,  0,  0), // near top-down
        mkVp(Vec3(-7,   2,  -9),    Vec3(0,0,0), false, 1024, 768, 37, 19), // offset vp
        mkVp(Vec3(4,    3,   5),    Vec3(0,0,0), true,  1280, 720,  0,  0), // ortho
        // Two ortho zooms chosen so the guards stop shadowing each other and
        // each one is independently observable:
        //   halfH 514  → a 1.0-world axis spans ~0.70 px, so slen2 ≈ 0.49 —
        //                inside the (0,1) band the slen2 guard is defined by,
        //                while other arms in the same sweep land above it.
        //   halfH 1e-8 → a 1e-10-world axis still spans ~3.6 px, so slen2 ≈ 13
        //                and the axisLen guard is the ONLY thing that can
        //                reject it. Without this camera a relaxed axisLen
        //                threshold is invisible, because slen2 catches the
        //                same cases first (measured: it did).
        mkVp(Vec3(4,    3,   5),    Vec3(0,0,0), true,  1280, 720,  0,  0, 514.0f),
        mkVp(Vec3(4,    3,   5),    Vec3(0,0,0), true,  1280, 720,  0,  0, 1e-8f),
    ];

    // --- anchors: origin, off-centre, far, and one BEHIND the first camera ---
    Vec3[] anchors = [
        Vec3(0, 0, 0),
        Vec3(1.5f, -0.75f, 2.25f),
        Vec3(-3, 2, -1),
        Vec3(12, -7, 3),
        Vec3(0, 0, 30),          // behind camera 0 → projection guard
    ];

    // --- axes: units, oblique unit, long, degenerate, camera-parallel ---
    Vec3[] axes = [
        Vec3(1, 0, 0),
        Vec3(0, 1, 0),
        Vec3(0, 0, 1),
        Vec3(0.5773502691f, 0.5773502691f, 0.5773502691f),
        Vec3(2.5f, 0, 0),                 // non-unit → gain scales with length
        Vec3(1e-12f, 0, 0),               // sub-pixel screen segment → slen2 guard
        Vec3(0, 0, 0),                    // zero axis → slen2 guard
        Vec3(0, 0, -1),                   // straight at camera 0 → slen2 guard
    ];

    // --- pixel deltas: none, unit, mixed sign, large ---
    int[2][] dpx = [
        [0, 0], [1, 0], [0, 1], [-3, 7], [137, -91], [10000, 10000],
    ];

    // --- gizmo arm lengths, including both axisLen guard tripwires ---
    float[] arms = [1.0f, 3.7f, 0.013f, 1e-10f, 0.0f];

    // A rotated input basis, so entry 2's inputAxis != the arrow direction.
    Vec3 bX = Vec3(0.8f, 0.6f, 0);
    Vec3 bY = Vec3(-0.6f, 0.8f, 0);
    Vec3 bZ = Vec3(0, 0, 1);

    // NOTE: no handler.destroy() — that path is glDeleteVertexArrays, and
    // there is no GL context under `dub test`. The ctor is safe (buildVao3f
    // is a no-op under version(unittest)); the GC reclaims the object.
    auto handler = new MoveHandler(Vec3(0, 0, 0));

    size_t samples = 0, matches = 0;
    size_t skipsSeen = 0;

    void check(Vec3 got, bool gotSkip, Vec3 want, bool wantSkip) {
        ++samples;
        if (bitEq(got, want) && gotSkip == wantSkip) ++matches;
        if (wantSkip) ++skipsSeen;
    }

    foreach (ref vp; vps)
    foreach (anchor; anchors)
    foreach (d; dpx) {
        int mx = 400 + d[0], my = 300 + d[1];
        int lastMX = 400,    lastMY = 300;

        // ---- LAW C: haulWorldPerPixel -------------------------------------
        {
            float want = frozenHaulWorldPerPixel(anchor, vp);
            float got  = haulWorldPerPixel(anchor, vp);
            ++samples;
            if (bitEq(got, want)) ++matches;
        }

        // ---- LAW A entry 3: screenAxisDelta -------------------------------
        foreach (axis; axes) {
            bool skipA, skipB;
            Vec3 want = frozenScreenAxisDelta(mx, my, lastMX, lastMY, anchor, axis, vp, skipA);
            Vec3 got  =       screenAxisDelta(mx, my, lastMX, lastMY, anchor, axis, vp, skipB);
            check(got, skipB, want, skipA);
        }

        // ---- LAW A entries 1 + 2: the two handler overloads ---------------
        foreach (arm; arms) {
            handler.center      = anchor;
            handler.arrowX.end  = anchor + Vec3(arm, 0, 0);
            handler.arrowY.end  = anchor + Vec3(0, arm, 0);
            handler.arrowZ.end  = anchor + Vec3(0, 0, arm);
            foreach (int dragAxis; 0 .. 3) {
                bool skipA, skipB;
                Vec3 want = frozenAxisDragDeltaHandler(mx, my, lastMX, lastMY,
                                                       dragAxis, handler, vp, skipA);
                Vec3 got  =       axisDragDelta(mx, my, lastMX, lastMY,
                                                dragAxis, handler, vp, skipB);
                check(got, skipB, want, skipA);

                bool skipC, skipD;
                Vec3 want2 = frozenAxisDragDeltaBasis(mx, my, lastMX, lastMY,
                                                      dragAxis, handler, bX, bY, bZ, vp, skipC);
                Vec3 got2  =       axisDragDelta(mx, my, lastMX, lastMY,
                                                 dragAxis, handler, bX, bY, bZ, vp, skipD);
                check(got2, skipD, want2, skipC);
            }
        }
    }

    // The sweep has to be big enough to be worth calling a proof, and it has
    // to have actually tripped the guards rather than only walking happy paths.
    assert(samples  > 5000,  "drag byte-identity sweep too small");
    assert(skipsSeen > 100,  "drag byte-identity sweep never tripped a guard");
    assert(matches == samples,
           "drag conversion is NOT byte-identical after the refactor");

    // Loud on success too: the report quotes these numbers.
    import std.stdio : writefln;
    writefln("[drag byte-identity] %s / %s exact (bitwise), %s guard returns",
             matches, samples, skipsSeen);
}
