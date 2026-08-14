// Module unittests for `handles.gl_util`, moved verbatim out of source/handles/gl_util.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.handles.gl_util_test;

import bindbc.opengl;
import std.math : sqrt, PI, abs;
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import gl_thread_guard : glThreadGuard;
import shader : seedSharedFragUniforms;
import math;
import handles.gl_util;

unittest {
    // ONE literal on every gizmo line batch — and after task 0604 this identity
    // is what keeps `GIZMO_ALPHA_ARM` pinned at all.
    //
    // The arm now reaches the framebuffer through TWO emissions (see
    // ShaftedArrow.doubledShaft), so its observed opacity is `1-(1-a)^2`. That
    // curve is nearly flat at the top: its slope is `2(1-a)`, i.e. 0.1 at
    // a = 0.95, so moving the arm's alpha by 0.05 moves the composite by 0.005
    // — well under one 8-bit level over any background contrast the viewport
    // offers. A pixel test therefore CANNOT bracket the arm's own literal any
    // more; the best it can do is exclude a single emission, which is a
    // statement about the doubling and not about the value.
    //
    // The rotate ring is emitted ONCE at the same measured literal, so its
    // composite still moves 1:1 with it and tests/test_gizmo_handle_alpha.d
    // Flow B brackets it from both sides at the pixel. This assertion is the
    // link that carries that bracket back to the arm: drift either constant on
    // its own and the chain breaks here, loudly, with the reason attached.
    assert(GIZMO_ALPHA_ARM == GIZMO_ALPHA_ROTATE_RING,
           "the arm and the rotate ring are the same measured line alpha. If "
           ~ "one really has to change, the other's pixel bracket stops "
           ~ "standing in for it — give the arm its own measurable pin first");
}

unittest {
    // The threshold is a CONE, and it is bracketed from both sides here so
    // that moving the constant in either direction fails a case.
    import std.math : cos, sin, PI;

    static Viewport perspAt(Vec3 eye) {
        Viewport vp;
        vp.view = lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
        vp.eye  = eye;
        vp.width = 800; vp.height = 600;
        return vp;
    }

    // A camera 5.5 deg off the X axis: X is INSIDE the 5.126 deg cone at 4.5
    // and OUTSIDE it at 5.5, and the arm must follow.
    foreach (degOff; [0.0f, 2.0f, 4.5f, 5.0f, 5.5f, 10.0f, 45.0f]) {
        immutable float r = degOff * cast(float)PI / 180.0f;
        auto vp = perspAt(Vec3(10.0f * cos(r), 0, 10.0f * sin(r)));
        immutable bool hidden = axisFacesViewer(Vec3(1, 0, 0), Vec3(0, 0, 0), vp);
        immutable bool expect = degOff < 5.126f;
        assert(hidden == expect,
               "the X arm's cull must switch exactly at 5.126 deg");
    }

    // PERSPECTIVE IS NOT EXEMPT. This is the half our old rule could not do:
    // the camera above is perspective throughout, and the 0-deg case must hide.
    {
        auto vp = perspAt(Vec3(10, 0, 0));
        assert(axisFacesViewer(Vec3(1, 0, 0), Vec3(0, 0, 0), vp),
               "an axis pointing straight at a PERSPECTIVE camera is culled too");
    }

    // The eye vector is per-point, so a gizmo away from the focus is judged by
    // the ray through ITSELF. Camera on +Z looking at the origin: the Z axis
    // faces it at the origin, and a gizmo pushed far along +X does not.
    {
        auto vp = perspAt(Vec3(0, 0, 10));
        assert(axisFacesViewer(Vec3(0, 0, 1), Vec3(0, 0, 0), vp));
        assert(!axisFacesViewer(Vec3(0, 0, 1), Vec3(8, 0, 0), vp));
    }

    // The plane handle takes its two SPANNED axes. With X pointing at the
    // camera, the two handles whose planes CONTAIN X go, and the one normal to
    // X — the only one seen face-on — stays. That is the reference's own
    // per-projection table for an axis view, restated as a predicate.
    {
        auto vp = perspAt(Vec3(10, 0, 0));
        immutable Vec3 X = Vec3(1, 0, 0), Y = Vec3(0, 1, 0), Z = Vec3(0, 0, 1);
        assert( planeHandleHidden(X, Y, Vec3(0, 0, 0), vp), "XY spans X");
        assert( planeHandleHidden(X, Z, Vec3(0, 0, 0), vp), "XZ spans X");
        assert(!planeHandleHidden(Y, Z, Vec3(0, 0, 0), vp), "YZ does not span X");
    }

    // THE DISCRIMINATOR between the two candidate plane rules, as the reference
    // measured it: hold a plane exactly edge-on and sweep. The XY plane's
    // normal is Z; with the camera in the XY plane the normal is perpendicular
    // to the view ray at EVERY elevation, so a normal-based rule would hide
    // this handle throughout. The spanned-axes rule keeps it except in the two
    // narrow cones, and the spanned-axes rule is the measured one.
    foreach (elDeg; [10.0f, 30.0f, 45.0f, 60.0f, 80.0f]) {
        immutable float e = elDeg * cast(float)PI / 180.0f;
        auto vp = perspAt(Vec3(10.0f * cos(e), 10.0f * sin(e), 0));
        assert(!planeHandleHidden(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 0), vp),
               "an edge-on plane handle stays drawn away from its axes' cones");
    }

    // Rotate: the gate is the viewport TYPE, so a perspective cell keeps every
    // ring however it is aimed — including the two that are exactly edge-on.
    {
        auto vp = perspAt(Vec3(0, 0, 10));
        assert(!rotateRingHidden(Vec3(1, 0, 0), Vec3(0, 0, 0), vp));
        assert(!rotateRingHidden(Vec3(0, 1, 0), Vec3(0, 0, 0), vp));
        assert(!rotateRingHidden(Vec3(0, 0, 1), Vec3(0, 0, 0), vp));
    }

    // ...and an ortho axis view drops exactly the edge-on ones. With the world
    // basis that leaves one ring, which is what the reference shows in each of
    // its axis views; with a basis rotated 45 deg about Y it leaves TWO, where
    // "keep only the face-on ring" would have left none.
    {
        Viewport vp;
        vp.view = lookAt(Vec3(0, 0, 10), Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj = orthographicMatrix(2.0f, 1.0f, 0.001f, 100.0f);
        vp.eye  = Vec3(0, 0, 10);
        vp.width = 800; vp.height = 600;
        assert(lockedViewAxis(vp) == 2, "fixture premise: this is a Z axis view");

        assert( rotateRingHidden(Vec3(1, 0, 0), Vec3(0, 0, 0), vp), "X ring edge-on");
        assert( rotateRingHidden(Vec3(0, 1, 0), Vec3(0, 0, 0), vp), "Y ring edge-on");
        assert(!rotateRingHidden(Vec3(0, 0, 1), Vec3(0, 0, 0), vp), "Z ring face-on");

        immutable float s = cast(float)(1.0 / 1.4142135623730951);
        immutable Vec3 rx = Vec3( s, 0, -s), ry = Vec3(0, 1, 0), rz = Vec3(s, 0, s);
        assert(!rotateRingHidden(rx, Vec3(0, 0, 0), vp), "a 45 deg ring is usable");
        assert( rotateRingHidden(ry, Vec3(0, 0, 0), vp), "...its Y sibling is not");
        assert(!rotateRingHidden(rz, Vec3(0, 0, 0), vp), "...and so is its partner");
    }
}

// Task 0597 — the four CLAMPED ornaments, sampled ACROSS their knees.
//
// This is the coverage the bug got past. Every one of these sizes used to be a
// flat fraction of the arm, which is correct at the shipped default and wrong
// everywhere else — so a test that only checked the default would have passed
// on the broken code. Each assertion below therefore samples BELOW the floor,
// AT the default and ABOVE the ceiling, and the ceiling rows are the load-
// bearing ones: they are what a fraction-of-the-arm implementation fails.
//
// The values are restated here as literals rather than recomputed from the
// enums, so that moving an enum has to fail here. They come from a live sweep
// of the reference over the full handle-scale range, both ends of every clamp.
unittest {
    import std.math : abs;

    immutable float saved = getGizmoPixels();
    scope(exit) setGizmoPixels(saved);

    static bool near(float a, float b) { return abs(a - b) < 1e-4f; }

    // handle scale -> (head length px, head half-width px, box half px).
    // 0.5  : the reachable floor. The two box clamps are ON their floor here
    //        (0.75 * 5 = 3.75, not 0.5 * 5 = 2.5) and the head half-width is
    //        on its floor too (4, not 60/16 = 3.75) — the floors are what stop
    //        the ornaments shrinking away on `-`.
    // 1.0  : the shipped default. Every value sits strictly inside its band
    //        except the boxes, which sit at the band's centre. A broken
    //        implementation agrees with all of these, which is the point.
    // 1.25 : the knee. Head length reaches its ceiling exactly here; the head
    //        half-width (knee 1.2) and the boxes (knee 1.25) are already at
    //        theirs.
    // 5.0  : the reachable ceiling — a 4x longer arm than 1.25 and a 10x
    //        longer arm than 0.5, with all three ornaments bit-identical to
    //        their 1.25 row. This row alone refutes "a fraction of the arm".
    static immutable float[4][6] rows = [
        // ts     headLen  headHalf  boxHalf
        [0.5f,    12.0f,    4.0f,    3.75f],
        [0.75f,   18.0f,    5.625f,  3.75f],   // still on the box floor
        [1.0f,    24.0f,    7.5f,    5.00f],
        [1.2f,    28.8f,    9.0f,    6.00f],   // half-width knee, boxes still rising
        [1.25f,   30.0f,    9.0f,    6.25f],   // length + box knees
        [5.0f,    30.0f,    9.0f,    6.25f],   // 4x the arm, identical ornaments
    ];

    foreach (r; rows) {
        setGizmoHandleScale(r[0]);
        assert(near(gizmoHandleScale(), r[0]), "the preference did not round-trip");
        assert(near(gizmoHeadLenPx(),  r[1]), "arrowhead length off its clamped law");
        assert(near(gizmoHeadHalfPx(), r[2]), "arrowhead half-width off its clamped law");
        assert(near(gizmoBoxHalfPx(),  r[3]), "box half-extent off its clamped law");
    }

    // The ceiling rows must be EXACT, not merely close: the reference's own
    // sharpest reading is that two very different arms give a bit-identical
    // box, and that is the property a ratio can never have.
    setGizmoHandleScale(1.25f);
    immutable float lenAtKnee = gizmoHeadLenPx();
    immutable float halfAtKnee = gizmoHeadHalfPx();
    immutable float boxAtKnee = gizmoBoxHalfPx();
    setGizmoHandleScale(5.0f);
    assert(gizmoHeadLenPx()  == lenAtKnee,  "arrowhead length still grows past its knee");
    assert(gizmoHeadHalfPx() == halfAtKnee, "arrowhead width still grows past its knee");
    assert(gizmoBoxHalfPx()  == boxAtKnee,  "box still grows past its knee");

    // ... and the floor rows likewise, against the OTHER failure mode: an
    // implementation with only the ceiling ported shrinks these on `-`.
    setGizmoHandleScale(0.5f);
    immutable float boxAtFloor = gizmoBoxHalfPx();
    setGizmoHandleScale(0.75f);
    assert(gizmoBoxHalfPx() == boxAtFloor, "box shrinks below its floor on `-`");

    // The line-draw coupling: the arrowhead's half-width is GEOMETRY, and the
    // stroke width multiplies it. Measured on the reference at the default
    // handle size: 1.0 -> 8.0 takes the half-width 7.5 px -> 30 px. At or
    // below the 2.0 floor the factor is exactly 1.0, so our default is inert.
    setGizmoHandleScale(1.0f);
    assert(gizmoHeadHalfPx(8.0f) == 30.0f, "line width must scale the arrowhead");
    assert(gizmoHeadHalfPx(1.0f) == gizmoHeadHalfPx(2.0f),
           "line widths under the 2.0 floor must be indistinguishable");
    assert(gizmoHeadHalfPx(float.nan) == gizmoHeadHalfPx(2.0f),
           "a NaN line width must take the floor, not poison the geometry");
}

// Task 0597 — the `-` / `+` ladder: ten LINEAR steps, saturating at both ends.
unittest {
    import std.math : abs;

    immutable float saved = getGizmoPixels();
    scope(exit) setGizmoPixels(saved);

    // Walk up from the shipped default and collect every arm length the user
    // can reach. The reference's reachable set is exactly {0.5, 1.0 ... 5.0},
    // i.e. 60, 120 ... 600 px — a linear ladder, where ours was nine geometric
    // steps 50..480. Sizes are exact in binary floating point at every rung,
    // so these are `==`, not tolerance compares.
    setGizmoHandleScale(1.0f);
    assert(getGizmoPixels() == 120.0f, "the default arm must stay 120 px");

    float[] up;
    foreach (_; 0 .. 12) { stepGizmoHandleScale(+1); up ~= getGizmoPixels(); }
    assert(up[0] == 180.0f && up[1] == 240.0f && up[2] == 300.0f);
    assert(up[7] == 600.0f, "eight presses from the default must reach 600 px");
    assert(up[$ - 1] == 600.0f, "`+` past the ceiling must saturate, not wrap");

    float[] down;
    setGizmoHandleScale(1.0f);
    foreach (_; 0 .. 4) { stepGizmoHandleScale(-1); down ~= getGizmoPixels(); }
    assert(down[0] == 60.0f, "one `-` from the default must reach the floor");
    assert(down[$ - 1] == 60.0f, "`-` past the floor must saturate");

    // The step is a CONSTANT 60 px of arm, not a ratio — the property that
    // decides whether a clamped ornament is ever seen changing.
    setGizmoHandleScale(1.0f);
    float prev = getGizmoPixels();
    foreach (_; 0 .. 8) {
        stepGizmoHandleScale(+1);
        assert(abs((getGizmoPixels() - prev) - 60.0f) < 1e-4f,
               "the ladder must be linear in the arm, not geometric");
        prev = getGizmoPixels();
    }

    // Clamp-on-write, independent of the stepping path — the reference clamps
    // in its setter so its keyboard and preference paths cannot disagree.
    setGizmoHandleScale(0.2f);   assert(getGizmoPixels() == 60.0f);
    setGizmoHandleScale(99.0f);  assert(getGizmoPixels() == 600.0f);
    setGizmoHandleScale(float.nan);
    assert(getGizmoPixels() == 60.0f, "a NaN preference must land on the floor");
}
