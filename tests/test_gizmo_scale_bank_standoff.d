// Task 0606 — the scale bank's axis boxes stand further out when another bank
// shares the gizmo, and the PICK REGION goes out with them.
//
// Pure unittest (no HTTP, no GL): constructs `ScaleHandler` directly, drives
// the same `syncGeometry(vp)` the hit path drives, and asks the handle where
// it is and what it grabs. Model: tests/test_gizmo_handle_geometry.d, which
// pins the rest of this gizmo's geometry the same way. The WIRING — that the
// wrapper turns the stand-off on for either companion bank and not for a
// scale bank on its own — is pinned separately and behaviourally in
// tests/test_gizmo_scale_bank_gate.d; the two halves are deliberately not in
// one file, because a handler that carries the right number and a wrapper
// that hands it the wrong flag are different bugs.
//
// WHY THIS EXISTS. Our scale box sat co-terminal with the move arrowhead in
// BOTH presentations. The reference stands it a tenth of an arm further out
// whenever another bank is drawn beside it — so ours landed a 10 px box
// entirely inside a 24 px arrowhead, which is a thing you can see, and which
// was reported twice. Two earlier lanes closed the report after comparing our
// combined path against our own standalone one and finding them identical.
// They are identical. That says our two paths agree with each other and
// nothing at all about where the box belongs, because over there the two
// paths are DIFFERENT CODE: the standalone tool is a thin caller of a
// framework handle-draw call, and the combined tool bypasses that call
// entirely and emits its boxes itself, with an offset that call cannot
// express. So the pins below always measure a bank IN COMPANY against the
// SAME bank ALONE — never one of our paths against the other.
//
// Every constant is restated here rather than imported from the GIZMO_* enums
// (tests/test_gizmo_handle_geometry.d's convention, and the reason a value
// moving in gl_util.d fails loudly here instead of silently following).
// Mutation-checked: each assertion below was confirmed to fail with the
// stand-off forced to 0, and the ratio assertions additionally fail with the
// stand-off frozen to a 12 px constant instead of a tenth of the arm.

import std.conv : to;
import std.math : abs, sqrt;

import handler : ScaleHandler, gizmoSize, gizmoBoxHalfPx, gizmoHeadLenPx,
                 getGizmoPixels, setGizmoPixels, setGizmoHandleScale;
import math : Vec3, Viewport, projectToWindowFull, Orientation;
import view : View;

void main() {}

// The law under test, restated: the box's outer face sits at the arm when the
// bank is alone, and a tenth of an arm further out when it is not.
private enum float ARM_ALONE      = 1.00f;
private enum float CROSS_BANK_ADD = 0.10f;

// A face-on camera: the world X axis lies exactly in the screen plane, so a
// world distance along X converts to pixels with no foreshortening and the
// pixel numbers below are the numbers a user would measure with a ruler. (An
// oblique camera would still satisfy every RATIO here, but the absolute px
// assertions would have to carry a projection factor and would stop being
// readable.)
private Viewport faceOnVp(View v, float dist = 6.0f) {
    return v.viewportWith(Vec3(0, 0, 0), dist,
                          Orientation.fromAngles(0.0f, 0.0f, v.roll));
}

// Distance in WINDOW PIXELS from the gizmo centre to a world point.
private float pxFromCenter(Vec3 world, Vec3 center, const ref Viewport vp) {
    float wx, wy, wz, cx, cy, cz;
    assert(projectToWindowFull(world,  vp, wx, wy, wz), "probe point off-camera");
    assert(projectToWindowFull(center, vp, cx, cy, cz), "gizmo centre off-camera");
    return sqrt((wx - cx) * (wx - cx) + (wy - cy) * (wy - cy));
}

unittest { // The stand-off is a FRACTION OF THE ARM, over the whole size band
    // Three handle sizes, chosen as the ends and the middle of the shipped
    // ladder ([0.5, 5.0] in steps of 0.5 — 60 px to 600 px of arm). The
    // stand-off must be a tenth of the arm at each, which is what separates
    // the ported law from a 12 px constant fitted at the default size: at
    // handle scale 5 a constant would be 12 px where the law says 60.
    immutable float savedPx = getGizmoPixels();
    scope(exit) setGizmoPixels(savedPx);

    auto v = new View(0, 0, 800, 600);

    foreach (handleScale; [0.5f, 1.0f, 5.0f]) {
        setGizmoHandleScale(handleScale);
        immutable float armPx = handleScale * 120.0f;
        auto vp = faceOnVp(v);
        Vec3 pivot = Vec3(0, 0, 0);

        auto sc = new ScaleHandler(pivot);

        // ALONE — unchanged from what we have always drawn.
        sc.syncGeometry(vp);
        immutable float alonePx = pxFromCenter(sc.arrowX.end, pivot, vp);
        assert(abs(alonePx - armPx * ARM_ALONE) < 0.75f,
               "a scale bank on its own must still end at the arm ("
               ~ (armPx * ARM_ALONE).to!string ~ " px at handle scale "
               ~ handleScale.to!string ~ "); it ends at " ~ alonePx.to!string);

        // IN COMPANY — a tenth of an arm further out.
        sc.setCrossBankShift(true);
        sc.syncGeometry(vp);
        immutable float besidePx = pxFromCenter(sc.arrowX.end, pivot, vp);
        assert(abs(besidePx - armPx * (ARM_ALONE + CROSS_BANK_ADD)) < 0.75f,
               "beside another bank the scale box must stand at 1.10 of the arm ("
               ~ (armPx * (ARM_ALONE + CROSS_BANK_ADD)).to!string ~ " px at handle "
               ~ "scale " ~ handleScale.to!string ~ "); it stands at "
               ~ besidePx.to!string);

        // The RATIO is the part that cannot be satisfied by a pixel constant.
        immutable float ratio = besidePx / alonePx;
        assert(abs(ratio - (ARM_ALONE + CROSS_BANK_ADD) / ARM_ALONE) < 0.004f,
               "the stand-off must be a tenth of the ARM, not a fixed pixel "
               ~ "count — at handle scale " ~ handleScale.to!string
               ~ " the in-company box is " ~ ratio.to!string ~ "x the alone box");

        // And turning it back off returns the box exactly whence it came, so
        // a preset that drops its move bank mid-session does not leave the
        // scale bank standing out.
        sc.setCrossBankShift(false);
        sc.syncGeometry(vp);
        assert(abs(pxFromCenter(sc.arrowX.end, pivot, vp) - alonePx) < 0.01f,
               "clearing the stand-off did not restore the alone position");
    }
}

unittest { // The box CLEARS the arrowhead — the defect, stated as geometry
    // The visible symptom, and the one the owner kept reporting: with both
    // banks drawn, our 10 px box sat wholly inside the move bank's 24 px
    // arrowhead. This pins the clearance rather than the position, so it
    // stays meaningful if either extent is re-measured later.
    immutable float savedPx = getGizmoPixels();
    scope(exit) setGizmoPixels(savedPx);
    setGizmoHandleScale(1.0f);

    auto v  = new View(0, 0, 800, 600);
    auto vp = faceOnVp(v);
    Vec3 pivot = Vec3(0, 0, 0);
    immutable float armPx     = 120.0f;
    immutable float boxHalfPx = gizmoBoxHalfPx();   // 5 px at the default
    immutable float headLenPx = gizmoHeadLenPx();   // 24 px at the default

    // The move bank's arrowhead occupies [arm - headLen, arm]; its apex is
    // the arm itself. (MoveHandler is not built here on purpose — the span is
    // a property of the arm and the head length, and building the bank would
    // add a dependency this assertion does not need.)
    immutable float headApexPx = armPx;

    auto sc = new ScaleHandler(pivot);
    sc.setCrossBankShift(true);
    sc.syncGeometry(vp);

    // CubicArrow centres its head at `end - half·dir`, so the box spans
    // [end - 2·boxHalf, end] and its outer face IS the arm end.
    immutable float outerPx = pxFromCenter(sc.arrowX.end, pivot, vp);
    immutable float innerPx = outerPx - 2.0f * boxHalfPx;

    assert(innerPx > headApexPx + 1.0f,
           "the scale box must sit BEYOND the move arrowhead's apex when both "
           ~ "banks are drawn: box inner face " ~ innerPx.to!string
           ~ " px against an apex at " ~ headApexPx.to!string ~ " px");
    assert(innerPx - headApexPx < 4.0f,
           "the box has been pushed too far out — the ported clearance is a "
           ~ "small gap (2 px at the shipped size), not an 18 % stagger; "
           ~ "gap is " ~ (innerPx - headApexPx).to!string ~ " px");

    // And the defect itself, so the failing state is on record rather than
    // implied: with no stand-off the whole box lies inside the head's span.
    sc.setCrossBankShift(false);
    sc.syncGeometry(vp);
    immutable float defectOuter = pxFromCenter(sc.arrowX.end, pivot, vp);
    immutable float defectInner = defectOuter - 2.0f * boxHalfPx;
    assert(defectInner > armPx - headLenPx && defectOuter <= armPx + 0.5f,
           "the alone position is expected to fall inside the arrowhead's own "
           ~ "span — if it no longer does, the head or the arm moved and this "
           ~ "file's account of the defect needs re-reading");
}

unittest { // THE TRAP: the pick region tracks the DRAWN box
    // `ScaleHandler.updateGeometry` used to take the box distance as a
    // defaulted parameter that no call site overrode. Handing the stand-off
    // to the DRAW site alone would have moved the drawn box and left the hit
    // region where it was: `syncGeometry` — the call that re-derives what the
    // hit test reads, and which is what `refreshBankGeometry` runs immediately
    // before the arbiter's Test pass — passes no arguments and would have kept
    // the old distance. The handle would move and the place you must click
    // would not.
    //
    // Nothing that only READS positions can see that. `/api/tool/handles`
    // reports an anchor derived from the same field the draw overwrites later
    // in the frame, so a static read reports the drawn value either way. It
    // takes a hit test, at a pixel chosen relative to the drawn box.
    immutable float savedPx = getGizmoPixels();
    scope(exit) setGizmoPixels(savedPx);
    setGizmoHandleScale(1.0f);

    auto v  = new View(0, 0, 800, 600);
    auto vp = faceOnVp(v);
    Vec3 pivot = Vec3(0, 0, 0);

    auto sc = new ScaleHandler(pivot);
    sc.setCrossBankShift(true);
    sc.syncGeometry(vp);            // the HIT path's call, verbatim

    // 1. The synced geometry — not merely the drawn geometry — carries the
    //    stand-off. This is the assertion the trap fails.
    immutable float syncedPx = pxFromCenter(sc.arrowX.end, pivot, vp);
    assert(abs(syncedPx - 132.0f) < 0.75f,
           "syncGeometry — the call that feeds the HIT test — must produce the "
           ~ "stood-off box (132 px); it produced " ~ syncedPx.to!string
           ~ " px. Draw and hit have been allowed to disagree again.");

    // 2. A press 6 px BEYOND the drawn box grabs the axis. The registered hit
    //    region for this bank in the full presentation is the shaft capsule
    //    (8 px around start..end), so a point just past the drawn end is
    //    inside it — and, when the stand-off is missing, that same point is
    //    12 + 6 = 18 px past the end and outside it. Six pixels of margin on
    //    each side of an 8 px band, measured in screen pixels, so no camera
    //    or projection assumption is doing any work.
    float ex, ey, ez, cx, cy, cz;
    assert(projectToWindowFull(sc.arrowX.end, vp, ex, ey, ez));
    assert(projectToWindowFull(pivot,         vp, cx, cy, cz));
    immutable float ux = (ex - cx) / syncedPx;
    immutable float uy = (ey - cy) / syncedPx;
    immutable int probeX = cast(int)(ex + ux * 6.0f);
    immutable int probeY = cast(int)(ey + uy * 6.0f);

    assert(sc.arrowX.hitTest(probeX, probeY, vp),
           "a press 6 px past the drawn box did not grab the scale axis — the "
           ~ "pick region is not where the box is");

    // 3. The control, and the half that makes (2) mean something: with the
    //    stand-off cleared the box retreats 12 px and that same pixel must
    //    now MISS. Without this, (2) would also pass on a hit region that
    //    simply never moved.
    sc.setCrossBankShift(false);
    sc.syncGeometry(vp);
    assert(!sc.arrowX.hitTest(probeX, probeY, vp),
           "the same pixel still grabs the axis with the stand-off cleared — "
           ~ "the pick region is not tracking the box at all");
}
