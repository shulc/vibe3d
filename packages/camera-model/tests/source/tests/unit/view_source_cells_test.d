module tests.unit.view_source_cells_test;

import view;
import math;
import vibe3d.util.spatial.spatial;
import std.math;
import std.json;
import vibe3d.util.spatial.trackball;

version(unittest) {
    import math;
    import std.math : isClose, abs;
}

// Camera BANK (roll) — the third rotational degree of freedom.
//
// Vocabulary used below: the view matrix is column-major, so the world-space
// camera basis is read off it as
//     screen-right = (view[0], view[4], view[8])
//     screen-up    = (view[1], view[5], view[9])
//     forward      = (-view[2], -view[6], -view[10])
// which is exactly how every consumer in the tree already reads it (drag
// bases, gizmo shapes, handle depth, arcball). Those consumers do inherit the
// bank for free.
//
// The consumers that RECONSTRUCTED the basis from a hard-coded world up
// instead of reading it are the ones that had to be fixed, and there are
// THREE, not the two an earlier version of this comment claimed:
//     `viewportWith`   — here
//     `panDeltaWith`   — here
//     `render_mvp.d`'s IPR camera (`cd.up`) — outside the default build
// The audit that produced this list was run over the modeling configuration,
// and `source/render/*` is `version (WithRender)`-gated and therefore not
// compiled by a plain `dub build`. So the third site was neither flagged by
// the compiler (its call to `viewportWith` was a stale 4-arg one that only
// `--config=with-render` would reject) nor caught by reading. The lesson is
// the general one: "every consumer" must be established over BOTH build
// configurations, or it means "every consumer the default build compiles".
// These tests cover the two in this module; the render site is covered by
// `--config=with-render` compiling at all.
// ---------------------------------------------------------------------------

version(unittest) {
    private Vec3 rightRowOf(Viewport vp) {
        return Vec3(vp.view[0], vp.view[4], vp.view[8]);
    }
    private Vec3 upRowOf(Viewport vp) {
        return Vec3(vp.view[1], vp.view[5], vp.view[9]);
    }
    private Vec3 fwdRowOf(Viewport vp) {
        return Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
    }
}


unittest { // the rotation no longer depends on where the camera is or how far
    // The property bought by the ulps above, and the one that makes them a
    // correction. Same orbit, four different focus/zoom combinations: one
    // orientation, bit-identical, every time.
    auto v = new View(0, 0, 1098, 966);
    v.azimuth = -0.5040186f; v.elevation = 0.4138754f; v.roll = 0.2055634f;
    immutable Orientation want = v.orientation;
    foreach (d; [0.3f, 1.486323332f, 42.0f])
    foreach (f; [Vec3(0, 0, 0), Vec3(0.25f, -0.5f, 2.0f), Vec3(-900, 17, 3.5f)]) {
        v.distance = d;
        v.focus    = f;
        assert(v.orientation.m == want.m,
               "the stored rotation must not move when the camera zooms or pans");
        // ...and the rendered basis is that rotation, exactly.
        Viewport vp = v.viewport();
        assert(rightRowOf(vp).x == want.m[0] && rightRowOf(vp).y == want.m[1] &&
               rightRowOf(vp).z == want.m[2],
               "the view matrix screen-right must be the stored rotation's column");
    }
}

unittest { // the bank law: right.y == -sin(roll) * cos(elevation)
    // This is the identity that makes our `roll` the SAME quantity a
    // reference viewport reports as its bank, rather than merely "some
    // rotation about the view axis". It is what lets a captured bank be
    // transferred as a number instead of re-fitted.
    import std.math : sin, cos;
    auto v = new View(0, 0, 800, 600);
    v.distance = 2.0f;
    foreach (a; [-1.1f, 0.0f, 0.9f])
    foreach (e; [-0.9f, 0.0f, 0.4138754f, 1.0f])
    foreach (r; [-1.2f, -0.2055634f, 0.0f, 0.2055634f, 1.2f]) {
        v.azimuth = a; v.elevation = e; v.roll = r;
        Vec3 right = rightRowOf(v.viewport());
        assert(isClose(right.y, -sin(r) * cos(e), 2e-5f, 2e-5f),
               "screen-right.y must equal -sin(roll)*cos(elevation)");
    }
}

unittest { // a banked camera reproduces a RECORDED reference view basis
    // Numbers are a measurement, not a fit. A reference engine's own view
    // published heading/pitch/bank = (0.5040186, 0.4138754, 0.2055634) rad
    // for one capture camera, and an independent instrument read that same
    // view's world-space basis rows off the engine at the same moment:
    //
    //     screen-right  +0.817569  -0.186885  +0.544661
    //     screen-up     +0.368870  +0.896293  -0.246158
    //     forward       +0.442173  -0.402161  -0.801717
    //
    // Feeding heading/pitch/bank into OUR parameterisation (azimuth is the
    // negated heading; elevation is the pitch; roll is the bank) has to
    // return those three rows. Nothing here is tuned: the only freedom is
    // the azimuth sign, which is fixed independently by the forward row.
    //
    // Before this change the third input had nowhere to go, and the
    // screen-right row came out (+0.875649, 0, +0.482948) — the SAME view
    // axis with the horizon forced level. The 0.1869 in the y lane is
    // precisely what was unrepresentable.
    auto v = new View(0, 0, 1098, 966);
    v.azimuth   = -0.5040186f;   // = -heading
    v.elevation =  0.4138754f;   // = pitch
    v.roll      =  0.2055634f;   // = bank
    v.distance  =  1.486323332f;
    v.focus     =  Vec3(0, 0, 0);
    Viewport vp = v.viewport();

    Vec3 right = rightRowOf(vp), up = upRowOf(vp), fwd = fwdRowOf(vp);
    enum float tol = 2e-5f;
    assert(isClose(right.x,  0.817569f, tol, tol) &&
           isClose(right.y, -0.186885f, tol, tol) &&
           isClose(right.z,  0.544661f, tol, tol),
           "banked screen-right must reproduce the recorded reference row");
    assert(isClose(up.x,  0.368870f, tol, tol) &&
           isClose(up.y,  0.896293f, tol, tol) &&
           isClose(up.z, -0.246158f, tol, tol),
           "banked screen-up must reproduce the recorded reference row");
    assert(isClose(fwd.x,  0.442173f, tol, tol) &&
           isClose(fwd.y, -0.402161f, tol, tol) &&
           isClose(fwd.z, -0.801717f, tol, tol),
           "forward must be unchanged by the bank");

    // And the un-banked build of the same camera is the level-horizon basis
    // that could not carry it.
    v.roll = 0.0f;
    Vec3 level = rightRowOf(v.viewport());
    assert(level.y == 0.0f, "an un-banked camera has right.y exactly 0");
    assert(isClose(level.x, 0.875649f, tol, tol),
           "un-banked screen-right.x for this camera");
}

unittest { // the bank is a rotation: basis stays orthonormal and right-handed
    import std.math : abs;
    auto v = new View(0, 0, 640, 480);
    v.azimuth = 0.77f; v.elevation = -0.31f; v.distance = 4.0f;
    foreach (r; [-2.5f, -0.6f, 0.3f, 1.4f, 3.0f]) {
        v.roll = r;
        Viewport vp = v.viewport();
        Vec3 rt = rightRowOf(vp), up = upRowOf(vp), fw = fwdRowOf(vp);
        assert(abs(rt.length - 1.0f) < 1e-5f, "right must stay unit");
        assert(abs(up.length - 1.0f) < 1e-5f, "up must stay unit");
        assert(abs(dot(rt, up)) < 1e-5f, "right must stay perpendicular to up");
        assert(abs(dot(rt, fw)) < 1e-5f, "right must stay perpendicular to forward");
        // right x up == -forward  (camera looks down its own -Z)
        Vec3 c = cross(rt, up);
        assert(abs(c.x + fw.x) < 1e-5f && abs(c.y + fw.y) < 1e-5f &&
               abs(c.z + fw.z) < 1e-5f, "basis must stay right-handed");
    }
}

unittest { // banking moves the horizon, never the eye
    auto v = new View(0, 0, 800, 600);
    v.azimuth = 0.3f; v.elevation = 0.6f; v.distance = 7.5f;
    v.focus = Vec3(-1, 2, 0.5f);
    Vec3 eye0 = v.viewport().eye;
    v.roll = 1.1f;
    Vec3 eye1 = v.viewport().eye;
    assert(eye0.x == eye1.x && eye0.y == eye1.y && eye0.z == eye1.z,
           "roll is a rotation about the view axis — the eye must not move");
    // ... and the forward direction is likewise untouched.
    v.roll = 0.0f; Vec3 f0 = fwdRowOf(v.viewport());
    v.roll = 1.1f; Vec3 f1 = fwdRowOf(v.viewport());
    assert(isClose(f0.x, f1.x, 1e-6f, 1e-6f) &&
           isClose(f0.y, f1.y, 1e-6f, 1e-6f) &&
           isClose(f0.z, f1.z, 1e-6f, 1e-6f),
           "roll must not change the view direction");
}


unittest { // ortho cells bank too, about their own preset axis
    import std.math : abs;
    auto v = new View(0, 0, 800, 600);
    v.projKind = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Top;
    v.distance = 5.0f;
    v.roll = 0.4f;
    Viewport vp = v.viewport();
    Vec3 fw = fwdRowOf(vp), rt = rightRowOf(vp);
    assert(abs(fw.x) < 1e-5f && isClose(fw.y, -1.0f, 1e-4f) && abs(fw.z) < 1e-5f,
           "Top preset forward must survive the bank");
    assert(abs(rt.y) < 1e-5f, "Top preset banks within the world XZ plane");
    assert(abs(rt.x - 1.0f) > 1e-3f, "Top preset screen-right must actually rotate");
    assert(isOrtho(vp), "banked Top preset must stay orthographic");
    // The ortho pan basis banks with it.
    Vec3 flat = v.panDeltaWith(100, 0, Orientation.fromAngles(v.azimuth, v.elevation, 0.0f));
    Vec3 bank = v.panDeltaWith(100, 0, Orientation.fromAngles(v.azimuth, v.elevation, 0.4f));
    assert(abs(dot(normalize(flat), normalize(bank)) - 1.0f) > 1e-4f,
           "ortho pan direction must follow the bank");
}


unittest { // the bank term downstream: reachable, decidable, and quantified
    // The off-handle scale axis election has exactly one bank-sensitive
    // clause. When the election drops the world Y axis it picks the
    // horizontal survivor by comparing two axes' projections onto the VIEW'S
    // OWN SCREEN-RIGHT — the row this file now produces. With the horizon
    // forced level that row's y lane is identically 0, so one side of the
    // comparison was structurally 0 and the clause was untestable.
    //
    // This test pins the camera INPUT to that comparison. It deliberately
    // does NOT port the election: the frame it would consume comes from the
    // axis stage, and electing is a separate task that must be measured.
    //
    // Camera + frame are the recorded corpus rig: the pinned action-centre
    // modes install the selected face's own frame, whose first and third
    // columns are world +X and world +Y.
    import std.math : abs;
    auto v = new View(0, 0, 1098, 966);
    v.azimuth = -0.5040186f; v.elevation = 0.4138754f; v.distance = 1.486323332f;
    immutable Vec3 A0 = Vec3(1, 0, 0);   // frame column 0 at the corpus rig
    immutable Vec3 A2 = Vec3(0, 1, 0);   // frame column 2 (the face normal)

    // 1. Level horizon: the comparison is degenerate — one side is exactly 0.
    v.roll = 0.0f;
    Vec3 n0 = rightRowOf(v.viewport());
    assert(abs(dot(A2, n0)) == 0.0f,
           "with no bank the clause's second operand is identically zero");

    // 2. At the recorded bank the term is non-zero, i.e. actually evaluated.
    v.roll = 0.2055634f;
    n0 = rightRowOf(v.viewport());
    assert(isClose(abs(dot(A0, n0)), 0.817569f, 2e-5f, 2e-5f),
           "clause operand |A0.N0| at the recorded bank");
    assert(isClose(abs(dot(A2, n0)), 0.186885f, 2e-5f, 2e-5f),
           "clause operand |A2.N0| at the recorded bank — the term the level "
           ~ "horizon could not produce");

    // 3. And the honest half: at THIS camera the recorded bank does not flip
    //    the clause. It flips at 0.66801 rad (38.27 deg), far beyond the
    //    11.78 deg the reference view actually carries — so a bank-capable
    //    camera makes the clause reachable and measurable, and by itself
    //    changes no elected axis on the corpus rig.
    assert(abs(dot(A0, n0)) > abs(dot(A2, n0)),
           "the recorded bank leaves the clause's winner unchanged");
    v.roll = 0.6680103f - 0.001f;
    n0 = rightRowOf(v.viewport());
    assert(abs(dot(A0, n0)) > abs(dot(A2, n0)), "just below the crossover");
    v.roll = 0.6680103f + 0.001f;
    n0 = rightRowOf(v.viewport());
    assert(abs(dot(A0, n0)) < abs(dot(A2, n0)), "just above the crossover it flips");
}


// ---------------------------------------------------------------------------
// Trackball gesture (task 0573)
// ---------------------------------------------------------------------------

version (unittest) {
    import vibe3d.util.spatial.trackball : setTrackballGlobal, resetTrackball, setTrackballMouseSpeed,
                       trackballRadius;

    // The two pane shapes every pane-dependent assertion runs on. The first is
    // the corpus viewport, where the WIDTH is the larger half-extent; the
    // second is a tall narrow pane where the HEIGHT is, and where the two
    // half-extents differ by 2.27x. One pane shape cannot tell a pane-tracking
    // radius from a constant, and a landscape-only pair cannot tell `max` from
    // `min`.
    private enum int kPaneWideW = 1098, kPaneWideH = 832;
    private enum int kPaneTallW =   82, kPaneTallH = 186;

    /// The angle a camera's view direction turned, in radians.
    private float backTurn(Orientation a, Orientation b) {
        import std.math : acos;
        float c = dot(a.back(), b.back());
        if (c >  1.0f) c =  1.0f;
        if (c < -1.0f) c = -1.0f;
        return acos(c);
    }

    /// A camera with the trackball switched on globally.
    private View trackballCamera(int w, int h) {
        setTrackballGlobal(true);
        auto v = new View(0, 0, w, h);
        assert(v.trackballActive(), "the fixture camera must run the trackball");
        return v;
    }

    /// The same, but LEVEL — elevation and bank both zero.
    ///
    /// Worth its own helper because the angle chart is only a faithful readout
    /// of this gesture at a level camera. The trackball rotates about an axis
    /// fixed in the SCREEN, and at a tilted camera the screen's vertical is not
    /// the world's, so a horizontal drag legitimately moves the chart's
    /// elevation as well as its heading. That is the documented difference
    /// between a trackball and a turntable, not a defect — the tests that want
    /// to talk in azimuth/elevation/roll therefore start level, and the ones
    /// that hold at ANY camera are stated as frame invariants instead.
    private View levelTrackballCamera(int w, int h) {
        auto v = trackballCamera(w, h);
        v.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
        return v;
    }
}

unittest { // a CENTRE press turns the camera the SAME WAY as the two-axis
           // orbit it replaces — which is what pins the sign
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;

    foreach (dx; [80, -80]) {
        auto tb = levelTrackballCamera(kPaneWideW, kPaneWideH);
        immutable float az0 = tb.azimuth;
        tb.trackballDown(cx, cy);
        tb.trackballMove(cx + dx, cy);

        // The same drag through the gesture it replaces, from the same camera.
        auto ob = new View(0, 0, kPaneWideW, kPaneWideH);
        ob.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
        ob.orbit(dx, 0);

        assert((tb.azimuth - az0) * (ob.azimuth - az0) > 0.0f,
               "a centre press must turn the heading the SAME WAY as orbit(); "
               ~ "an inverted sign here would flip every user's viewport the "
               ~ "moment they switched the preference on");
        assert(isClose(tb.elevation, 0.0f, 1e-4f, 1e-4f),
               "from LEVEL, a horizontal centre drag is a pure heading change");
        assert(isClose(tb.roll, 0.0f, 1e-4f, 1e-4f), "with no bank");
    }

    foreach (dy; [80, -80]) {
        auto tb = levelTrackballCamera(kPaneWideW, kPaneWideH);
        immutable float az0 = tb.azimuth;
        tb.trackballDown(cx, cy);
        tb.trackballMove(cx, cy + dy);

        auto ob = new View(0, 0, kPaneWideW, kPaneWideH);
        ob.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
        ob.orbit(0, dy);

        assert((tb.elevation - 0.0f) * (ob.elevation - 0.0f) > 0.0f,
               "a centre press must pitch the SAME WAY as orbit()");
        assert(isClose(tb.azimuth, az0, 1e-4f, 1e-4f),
               "from LEVEL, a vertical centre drag does not change the heading");
        assert(isClose(tb.roll, 0.0f, 1e-4f, 1e-4f), "with no bank");
    }
}

unittest { // the arc's AXIS is fixed in the screen — the invariant that holds
           // at ANY camera, tilted or not
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);

    // The default camera is TILTED (elevation 0.4), which is the point: these
    // three statements are about the rotation, not about the chart, so they
    // survive a camera the chart cannot describe cleanly.

    // Horizontal centre drag: the axis is the camera's own UP, so `up` is a
    // fixed vector of the rotation — invariant to the last bit.
    {
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Vec3 up0 = v.orientation.up();
        v.trackballDown(cx, cy);
        v.trackballMove(cx + 90, cy);
        immutable Vec3 up1 = v.orientation.up();
        assert(abs(dot(up0, up1) - 1.0f) < 1e-6f,
               "a horizontal centre drag rotates about SCREEN-UP, so screen-up "
               ~ "does not move");
        assert(abs(dot(v.orientation.back(), up0)) < 1e-6f,
               "and the view direction stays perpendicular to it");
    }

    // Vertical centre drag: the axis is SCREEN-RIGHT, so `right` is invariant.
    {
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Vec3 rt0 = v.orientation.right();
        v.trackballDown(cx, cy);
        v.trackballMove(cx, cy + 90);
        assert(abs(dot(rt0, v.orientation.right()) - 1.0f) < 1e-6f,
               "a vertical centre drag rotates about SCREEN-RIGHT");
    }

    // Outside press, tangential drag: the axis is the VIEW axis, so the camera
    // keeps looking at exactly the same point and only spins. This is the
    // sharpest statement of "outside the ball it banks" — and the two-axis
    // orbit cannot do it at any pixel.
    {
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Vec3 bk0 = v.orientation.back();
        immutable Vec3 rt0 = v.orientation.right();
        immutable int px = cx + cast(int)(2.0f * r);
        v.trackballDown(px, cy);
        v.trackballMove(px, cy + 200);
        assert(abs(dot(bk0, v.orientation.back()) - 1.0f) < 1e-6f,
               "an outside drag rotates about the VIEW axis: the camera does "
               ~ "not change where it looks");
        assert(dot(rt0, v.orientation.right()) < 0.999f,
               "it only spins — and it really did spin");
    }
}

unittest { // the centre RATE is speed/radius — NOT the two-axis orbit's 0.005
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);   // 521.55

    auto tb = trackballCamera(kPaneWideW, kPaneWideH);
    immutable Orientation before = tb.orientation;
    tb.trackballDown(cx, cy);
    tb.trackballMove(cx + 100, cy);
    immutable float got = backTurn(before, tb.orientation);

    // Closed form: a 100 px step from the centre subtends
    // atan(100 / sqrt(r^2 - 100^2)) on the ball.
    import std.math : atan;
    immutable float want = atan(100.0f / sqrt(r * r - 10000.0f));
    assert(isClose(got, want, 1e-3f), "the centre arc is atan(d / z0)");

    // ...and that is 2.6x SLOWER than the drag it replaces. Reusing the
    // two-axis orbit's flat 0.005 rad/px here is the single easiest way to
    // port this wrong: it looks plausible and is wrong at every pane size but
    // one.
    immutable float twoAxis = 100 * 0.005f;      // 0.5 rad
    assert(isClose(twoAxis / got, 2.585f, 1e-2f),
           "the trackball's centre rate is ~2.6x slower than 0.005 rad/px");
    assert(got < twoAxis * 0.5f, "and it is nowhere near it");
}

unittest { // the rate is PANE-DEPENDENT, on two sharply different pane shapes
    scope(exit) resetTrackball();
    resetTrackball();

    float centreTurn(int w, int h, int dx) {
        auto v = trackballCamera(w, h);
        immutable Orientation before = v.orientation;
        v.trackballDown(w / 2, h / 2);
        v.trackballMove(w / 2 + dx, h / 2);
        return backTurn(before, v.orientation);
    }

    import std.math : atan;
    float wantTurn(int w, int h, int dx) {
        immutable float r = trackballRadius(w, h);
        return atan(dx / sqrt(r * r - cast(float)dx * dx));
    }

    // Landscape pane: the WIDTH is the larger half-extent.
    immutable float wide = centreTurn(kPaneWideW, kPaneWideH, 10);
    assert(isClose(wide, wantTurn(kPaneWideW, kPaneWideH, 10), 1e-3f),
           "wide pane: the arc follows 0.95*w/2");

    // Portrait pane: the HEIGHT is. This is the shape that separates a radius
    // built on `max` from one built on `min` — they differ by 2.27x here.
    immutable float tall = centreTurn(kPaneTallW, kPaneTallH, 10);
    assert(isClose(tall, wantTurn(kPaneTallW, kPaneTallH, 10), 1e-3f),
           "tall pane: the arc follows 0.95*h/2, not 0.95*w/2");

    // The SAME pixel drag rotates ~5.9x further on the small pane. A rate that
    // did not track the pane would give a ratio of exactly 1.
    assert(tall / wide > 5.0f && tall / wide < 7.0f,
           "the same drag must rotate much further on a smaller pane");

    // And a radius built on the SMALLER half-extent would have given a
    // materially different answer on the tall pane — stated so the assertion
    // above cannot be satisfied by the wrong law.
    immutable float rMin  = 0.95f * kPaneTallW / 2.0f;          // 38.95
    immutable float wrong = atan(10.0f / sqrt(rMin * rMin - 100.0f));
    assert(!isClose(tall, wrong, 5e-2f),
           "a min(w,h) radius is out by more than 5% on this pane");
}

unittest { // the bank blends continuously — it is NOT gated on leaving the ball
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);

    // From LEVEL, so the chart's `roll` is a faithful readout of the arc's
    // view-axis content. SIGNED — see the sign block below.
    float signedBankAt(float frac, int dy) {
        auto v = levelTrackballCamera(kPaneWideW, kPaneWideH);
        immutable int px = cx + cast(int)(frac * r);
        v.trackballDown(px, cy);
        v.trackballMove(px, cy + dy);
        return v.roll;
    }
    float bankAt(float frac) { return abs(signedBankAt(frac, 40)); }

    // THE BANK'S SIGN, which is not a free choice: the arc comes from ONE
    // formula whose overall sense is already pinned at the centre (against the
    // two-axis orbit), and the bank is the same formula continued outward, so
    // the sign here is forced. Asserting it is what catches a camera-frame axis
    // carried into world space through the wrong basis column — a mutation that
    // leaves the orbit limits untouched and silently runs the bank backwards.
    //
    // The sense, in the hand: grab the ball on its right and push down, and the
    // model turns clockwise on screen — the grabbed point follows the cursor,
    // which is the same "the model follows you" the centre press has. On the
    // chart that reads as a NEGATIVE bank.
    assert(signedBankAt(0.5f,  40) < 0.0f, "press right, drag down -> bank -");
    assert(signedBankAt(0.5f, -40) > 0.0f, "press right, drag up   -> bank +");
    assert(signedBankAt(-0.5f, 40) > 0.0f, "press left,  drag down -> bank +");
    // Mirroring the press and the drag together must return the same bank.
    assert(isClose(signedBankAt(0.5f, 40), signedBankAt(-0.5f, -40), 1e-4f),
           "the gesture is symmetric under mirroring both press and drag");

    // Every one of these presses is INSIDE the circle, where the shipped
    // description says the gesture "just orbits". It banks at all of them, and
    // it banks more the further out the press is.
    immutable float b25 = bankAt(0.25f);
    immutable float b50 = bankAt(0.50f);
    immutable float b90 = bankAt(0.90f);
    assert(b25 > 1e-4f, "a press a quarter of the way out already banks");
    assert(b50 > b25 && b90 > b50,
           "and the bank grows monotonically with the press radius, with no "
           ~ "cliff at the rim");
    // The centre is the one place it is exactly zero.
    assert(bankAt(0.0f) < 1e-6f, "only a dead-centre press is bank-free");
    // The blend is roughly linear in the press radius (the closed form is
    // exactly rho/r; `source/trackball.d` pins that to 1 %). Here it is enough
    // to show the ratio reaches the camera rather than being flattened.
    assert(isClose(b50 / b25, 2.0f, 5e-2f),
           "twice the press radius is twice the bank");
}

unittest { // a degenerate step leaves the ANCHOR where it was
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);
    immutable int px = cx + cast(int)(1.2f * r);   // outside the rim

    // Press outside, wander straight OUTWARD along the ray, then drag
    // tangentially. Every outward step lifts to the SAME rim vector — that is
    // the hard rim clamp's signature, and a hyperbolic sheet would rotate here
    // because its z keeps changing with the press radius.
    auto a = trackballCamera(kPaneWideW, kPaneWideH);
    a.trackballDown(px, cy);
    immutable Orientation afterPress = a.orientation;
    a.trackballMove(px + 100, cy);
    a.trackballMove(px + 400, cy);
    foreach (i; 0 .. 9)
        assert(a.orientation.m[i] == afterPress.m[i],
               "dragging straight outward beyond the rim must not move the "
               ~ "camera by a single bit");
    a.trackballMove(px + 400, cy + 150);

    // The same press taken straight to the tangential position. The excursion
    // must have left no trace at all. (This does NOT pin the reference's
    // "do not advance the anchor" ordering — a degenerate step is one where the
    // two lifted vectors are equal, so that ordering is unobservable; see
    // `trackballStep`.)
    auto b = trackballCamera(kPaneWideW, kPaneWideH);
    b.trackballDown(px, cy);
    b.trackballMove(px + 400, cy + 150);

    foreach (i; 0 .. 9)
        assert(abs(a.orientation.m[i] - b.orientation.m[i]) < 1e-6f,
               "an outward excursion beyond the rim must leave no trace");
    // ...and (a) is not vacuously equal to its own press state.
    bool moved = false;
    foreach (i; 0 .. 9)
        if (abs(a.orientation.m[i] - afterPress.m[i]) > 1e-3f) moved = true;
    assert(moved, "the tangential step must have actually rotated the camera");
}


unittest { // the speed multiplier scales the rate AND shrinks the circle
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);

    // Rate: at the centre, twice the speed is twice the arc (to first order).
    float centreArc(float speed) {
        setTrackballMouseSpeed(speed);
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Orientation before = v.orientation;
        v.trackballDown(cx, cy);
        v.trackballMove(cx + 5, cy);
        return backTurn(before, v.orientation);
    }
    immutable float a1 = centreArc(1.0f);
    immutable float a2 = centreArc(2.0f);
    assert(isClose(a2 / a1, 2.0f, 5e-3f), "speed scales the rate");

    // Circle: a press at 60 % of the radius is INSIDE at speed 1 (so the arc
    // keeps a view-direction component) and ON THE RIM at speed 2 (so it is a
    // pure spin and the view direction is invariant).
    float viewMove(float speed) {
        setTrackballMouseSpeed(speed);
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Vec3 bk0 = v.orientation.back();
        immutable int px = cx + cast(int)(0.6f * r);
        v.trackballDown(px, cy);
        v.trackballMove(px, cy + 40);
        return 1.0f - dot(bk0, v.orientation.back());
    }
    assert(viewMove(1.0f) > 1e-5f,
           "at speed 1 a press at 0.6r is inside, so the view direction moves");
    assert(viewMove(2.0f) < 1e-6f,
           "at speed 2 the same pixel is on the rim: pure spin, view direction "
           ~ "fixed — the multiplier shrank the circle, not just the rate");
}

unittest { // the option gates the gesture, and ortho is excluded outright
    scope(exit) resetTrackball();
    resetTrackball();

    auto v = new View(0, 0, kPaneWideW, kPaneWideH);
    assert(!v.trackballActive(), "shipped default is off");

    v.trackballOption = TrackballOption.On;
    assert(v.trackballActive(), "a per-cell On overrides the global");

    // Ortho: excluded regardless of the option. The reference's rotation gate
    // never writes its trackball flag for the ortho view type; this is the
    // observable half of that.
    v.projKind = ProjKind.Ortho;
    assert(!v.trackballActive(), "an ortho cell never runs the trackball");
    v.projKind = ProjKind.Perspective;
    assert(v.trackballActive(), "and it comes back when the cell does");

    // reset() returns the cell to deferring to the global.
    v.reset();
    assert(v.trackballOption == TrackballOption.Default,
           "reset() must clear the per-cell override");
    assert(!v.trackballActive(), "so a reset cell follows the (off) global");
}

unittest { // a motion event with no press does nothing at all
    scope(exit) resetTrackball();
    resetTrackball();

    auto v = trackballCamera(kPaneWideW, kPaneWideH);
    assert(!v.trackballArmed(), "a fresh camera is not armed");
    immutable Orientation before = v.orientation;
    v.trackballMove(100, 100);
    foreach (i; 0 .. 9)
        assert(v.orientation.m[i] == before.m[i],
               "an unarmed move must not touch the camera");

    v.trackballDown(200, 200);
    assert(v.trackballArmed(), "the press arms it");
    v.trackballCancel();
    assert(!v.trackballArmed(), "and cancelling disarms it");
    v.trackballMove(300, 300);
    foreach (i; 0 .. 9)
        assert(v.orientation.m[i] == before.m[i],
               "a move after cancel must not touch the camera either");
}

unittest { // the composed rotation stays a clean rotation over a long gesture
    scope(exit) resetTrackball();
    resetTrackball();

    // 400 motion events around a circle well inside the ball — the case where
    // an incremental composition would accumulate drift if the write funnel's
    // re-normalisation were not doing its job.
    import std.math : sin, cos;
    auto v = trackballCamera(kPaneWideW, kPaneWideH);
    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    v.trackballDown(cx + 200, cy);
    foreach (i; 1 .. 401) {
        immutable float t = i * 0.05f;
        v.trackballMove(cx + cast(int)(200 * cos(t)), cy + cast(int)(200 * sin(t)));
    }
    assert(v.orientation.orthonormalityDefect() < 1e-5f,
           "400 composed steps must leave an orthonormal camera");
    // ...and it actually went somewhere, so the assertion is not vacuous.
    auto fresh = new View(0, 0, kPaneWideW, kPaneWideH);
    bool moved = false;
    foreach (i; 0 .. 9)
        if (abs(v.orientation.m[i] - fresh.orientation.m[i]) > 1e-3f) moved = true;
    assert(moved, "the sweep must have actually rotated the camera");
}

// ---------------------------------------------------------------------------
// Momentum spin — the spin a release leaves behind
// ---------------------------------------------------------------------------

version (unittest) {
    import vibe3d.util.spatial.trackball : kSettleTimeMs, kSettleDurationMs, kSwingTimeMs,
                       kSwingPeriodMs, setTrackballSwing, spinAngle,
                       SpinCurve;

    /// One motion event every `kStepMs` milliseconds. Chosen so the spins the
    /// tests below arm total LESS THAN pi radians: `rotAngleBetween` is an
    /// `acos`, so a bigger total would wrap and every assertion about it would
    /// be reading a folded angle. That is a property of the instrument, not of
    /// the feature — the feature is happy to spin the camera eight times round.
    private enum uint kStepMs = 20;

    /// A trackball drag from the pane centre, advancing by `dxs[i]` pixels on
    /// event `i`, one event every `kStepMs`. Returns the camera with the button
    /// still notionally down; the tests do their own release.
    ///
    /// The per-step array rather than a uniform step because the momentum rule
    /// is "the LAST step's rate", and only a drag whose steps differ can tell
    /// that from "the drag's average rate".
    /// The camera is LEVEL, and every drag here is horizontal along the pane's
    /// horizontal diameter — so the step axis is exactly screen-up, which at a
    /// level camera is exactly world-up, and the whole rotation is a heading
    /// change the angle chart reports faithfully. That is what lets the tests
    /// below assert the spin's DIRECTION (`azimuth`) as well as its magnitude.
    private View draggedCamera(const(int)[] dxs, uint t0 = 1000) {
        auto v = levelTrackballCamera(kPaneWideW, kPaneWideH);
        immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
        v.trackballDown(cx, cy);
        int x = 0;
        foreach (i, d; dxs) {
            x += d;
            v.trackballMove(cx + x, cy, t0 + (cast(uint)i + 1) * kStepMs);
        }
        return v;
    }

    /// The EXACT arc a horizontal step from `x0` to `x1` pixels right of the
    /// pane centre subtends on the ball: both points lift onto the horizontal
    /// diameter, where the polar angle is `asin(x/r)`. The gesture's own closed
    /// form — so a momentum assertion is checked against the law rather than
    /// against whatever this implementation happened to compute.
    private double armArc(double x0, double x1) {
        import std.math : asin;
        immutable double r = trackballRadius(kPaneWideW, kPaneWideH);
        // Outside the rim the lift clamps onto it, i.e. onto the equator.
        double polar(double x) { return x >= r ? PI / 2.0 : asin(x / r); }
        return polar(x1) - polar(x0);
    }

    /// How far apart two orientations are, as the largest difference over the
    /// nine lanes. The instrument for SMALL differences: `rotAngleBetween`
    /// below is an `acos` near 1 there and has a noise floor around 3e-4 even
    /// between a matrix and itself, so an assertion like "these two cameras
    /// agree to 1e-4" is unanswerable in that metric and exact in this one.
    private double maxEntryDiff(Orientation a, Orientation b) {
        double worst = 0.0;
        foreach (i; 0 .. 9) {
            immutable double d = abs(cast(double)a.m[i] - cast(double)b.m[i]);
            if (d > worst) worst = d;
        }
        return worst;
    }

    /// The angle of the rotation carrying `a` to `b`, radians in [0, pi].
    /// Reads the trace of `b * a^T`, which is `1 + 2 cos(theta)` for any
    /// rotation — chart-free, so it is meaningful at any camera. Use it for
    /// the LARGE angles a spin covers; use `maxEntryDiff` for "did not move".
    private double rotAngleBetween(Orientation a, Orientation b) {
        import std.math : acos;
        double tr = 0.0;
        foreach (i; 0 .. 3)
            foreach (k; 0 .. 3)
                tr += cast(double)b.m[i * 3 + k] * cast(double)a.m[i * 3 + k];
        double c = (tr - 1.0) * 0.5;
        if (c >  1.0) c =  1.0;
        if (c < -1.0) c = -1.0;
        return acos(c);
    }
}

unittest { // a release with the cursor moving spins the camera, and lands
           // exactly where the profile's closed form says it must
    scope(exit) resetTrackball();
    resetTrackball();

    // Six 9 px steps, the last from 45 px to 54 px right of centre.
    static immutable int[] kSteps = [9, 9, 9, 9, 9, 9];
    auto v = draggedCamera(kSteps);
    immutable Orientation atRelease = v.orientation;
    v.trackballRelease(2000);
    assert(v.spinning(), "a release with the cursor moving arms a spin");

    // The rate is the last step's arc over its interval, pinned against the
    // gesture's own closed form rather than against a number this
    // implementation produced.
    immutable double wantRate = armArc(45, 54) / cast(double)kStepMs;
    assert(isClose(v.spinRate(), wantRate, 1e-5),
           "the release rate is the last step's angle over its interval");

    // Ticking is what moves the camera — the release itself does not.
    foreach (i; 0 .. 9)
        assert(v.orientation.m[i] == atRelease.m[i],
               "the release must not move the camera by itself");

    // Halfway through the profile, the camera has turned by exactly
    // rate*A*sin(t/A) about the last step's axis. This is the whole claim:
    // ANY decaying-spin implementation would keep moving here, and only this
    // one lands on that number.
    v.spinTick(2000 + 2000);
    immutable double want2s = spinAngle(SpinCurve.Settle, wantRate, 2000.0);
    assert(isClose(rotAngleBetween(atRelease, v.orientation), want2s, 5e-3),
           "at t = 2000 ms the spin has covered rate*A*sin(t/A)");

    // ...and the axis is the one the drag ended on, unchanged: a horizontal
    // drag along the diameter turns about screen-up, so screen-up survives the
    // spin.
    assert(isClose(dot(atRelease.up(), v.orientation.up()), 1.0, 1e-4),
           "the spin turns about the LAST STEP's axis, which here is screen-up");

    // And it turns THE SAME WAY the drag was turning. This is the whole
    // user-facing promise of the feature — flick left, keep going left — and
    // it is the one claim a magnitude-only test cannot make: at a level camera
    // this rotation is a pure heading change, so the chart reports it exactly,
    // and an axis that came out backwards would show up here as a spin that
    // rewinds the drag.
    immutable double dDrag = cast(double)atRelease.azimuth - 0.5;   // the drag
    immutable double dSpin = cast(double)v.azimuth - cast(double)atRelease.azimuth;
    assert(dDrag * dSpin > 0.0,
           "the spin continues the drag's own direction, it does not rewind it");
    assert(isClose(abs(dSpin), want2s, 5e-3),
           "and the heading it has covered is the profile's angle exactly");

    // It ends at 4000 ms — not before, not after — and the total is rate*A.
    v.spinTick(2000 + 3999);
    assert(v.spinning(), "still spinning at 3999 ms");
    v.spinTick(2000 + 4000);
    assert(!v.spinning(), "and stopped at exactly 4000 ms");
    assert(isClose(rotAngleBetween(atRelease, v.orientation),
                   wantRate * kSettleTimeMs, 5e-3),
           "the total extra angle is rate * 8000/pi");

    // A tick after the end is a no-op, to the bit. A profile without the
    // post-4000 clamp would walk the camera back down the sine from here.
    immutable Orientation settled = v.orientation;
    foreach (t; [4001, 6000, 60_000])
        v.spinTick(2000 + cast(uint)t);
    foreach (i; 0 .. 9)
        assert(v.orientation.m[i] == settled.m[i],
               "a tick after the spin ended must not move the camera at all");
}

unittest { // a STILL release leaves no spin, and neither does a drag that
           // ended on degenerate steps
    scope(exit) resetTrackball();
    resetTrackball();

    // Two motion events sharing a timestamp: the interval is zero, so there is
    // no rate to hand the profile. This is the reference's own guard and it is
    // the difference between "released while flicking" and "released while
    // parked", which is the whole user-facing contract of the feature.
    {
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
        v.trackballDown(cx, cy);
        v.trackballMove(cx + 20, cy, 5000);
        v.trackballMove(cx + 40, cy, 5000);      // same millisecond
        immutable Orientation before = v.orientation;
        v.trackballRelease(5000);
        assert(!v.spinning(), "two events in one millisecond leave no spin");
        v.spinTick(5100);
        v.spinTick(9000);
        foreach (i; 0 .. 9)
            assert(v.orientation.m[i] == before.m[i],
                   "and the camera does not move after such a release");
    }

    // A release with no motion at all since the press: nothing to be moving.
    {
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        v.trackballDown(400, 400);
        v.trackballRelease(5000);
        assert(!v.spinning(), "a press-and-release with no drag leaves no spin");
    }

    // Dragging straight OUT along a ray from outside the rim is step after
    // degenerate step: the camera never moved, so there is no momentum — even
    // though motion events kept arriving with advancing timestamps.
    {
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
        immutable int rim = cast(int)trackballRadius(kPaneWideW, kPaneWideH);
        v.trackballDown(cx + rim + 20, cy);
        foreach (i; 1 .. 6) v.trackballMove(cx + rim + 20 + i * 40, cy, 7000 + i);
        v.trackballRelease(7010);
        assert(!v.spinning(),
               "a drag that rotated nothing leaves nothing spinning");
    }
}

unittest { // a degenerate step advances NEITHER the arc nor the clock it is
           // divided by
    scope(exit) resetTrackball();
    resetTrackball();

    // Real steps, then a slow slide straight outward from beyond the rim —
    // motion events that lift onto the same rim vector and so rotate nothing —
    // then a release. The momentum must still be the last REAL step's, because
    // the reference stores its clock AFTER the degenerate return, not before.
    //
    // The slide is deliberately SLOW (a second between events) so the two
    // orderings are 50x apart rather than a rounding argument: writing the
    // stamps before the return would divide the same arc by 1000 ms instead of
    // by 20, and a flick would land as a crawl.
    auto v = trackballCamera(kPaneWideW, kPaneWideH);
    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable int rim = cast(int)trackballRadius(kPaneWideW, kPaneWideH);
    v.trackballDown(cx, cy);
    v.trackballMove(cx + 45, cy, 1000);
    v.trackballMove(cx + rim + 40, cy, 1000 + kStepMs);   // the last REAL step
    v.trackballMove(cx + rim + 400, cy, 2000);            // on the rim: degenerate
    v.trackballMove(cx + rim + 900, cy, 3000);            // still degenerate
    v.trackballRelease(3000);

    assert(v.spinning(), "the real steps still carry momentum");
    assert(isClose(v.spinRate(), armArc(45, rim + 40) / cast(double)kStepMs, 1e-5),
           "and the rate is theirs — the degenerate slide neither added arc "
           ~ "nor stretched the interval");
}

unittest { // the momentum is the LAST step's rate, not the drag's average
    scope(exit) resetTrackball();
    resetTrackball();

    // A drag that DECELERATES into the release: 40, 30, 20, 10, then 2 px.
    // The user was braking, and the camera must come to rest with them. An
    // implementation that averaged the gesture would launch it instead — and
    // by an order of magnitude, which is what makes this test decisive rather
    // than a tolerance argument.
    auto v = draggedCamera([40, 30, 20, 10, 2]);
    v.trackballRelease(3000);
    assert(v.spinning(), "a decelerating drag still leaves a little spin");

    immutable double lastStep = armArc(100, 102) / cast(double)kStepMs;
    immutable double average  = armArc(0, 102) / cast(double)(5 * kStepMs);
    assert(isClose(v.spinRate(), lastStep, 1e-5),
           "the rate is the FINAL step's arc over the final interval");
    assert(average > 8.0 * lastStep,
           "the average over this drag is 8x larger — the two are far apart");
    assert(v.spinRate() < 0.25 * average,
           "so a rate anywhere near the average would fail here");
}

unittest { // a press cancels a running spin
    scope(exit) resetTrackball();
    resetTrackball();

    auto v = draggedCamera([9, 9, 9, 9, 9, 9]);
    immutable Orientation atRelease = v.orientation;
    v.trackballRelease(2000);
    assert(v.spinning(), "armed");
    v.spinTick(2500);                      // let it run for half a second
    immutable Orientation midSpin = v.orientation;
    // Half a second into a 4-second profile, most of the travel is still to
    // come — so freezing here is visibly different from letting it finish, and
    // the assertions below are not "the spin ended on time" in disguise.
    immutable double remaining = v.spinRate() * kSettleTimeMs
                               - rotAngleBetween(atRelease, midSpin);
    assert(remaining > 0.5 * v.spinRate() * kSettleTimeMs,
           "the cancel must land mid-profile, with most of the travel unspent");

    v.spinCancel();                        // this is what a press does
    assert(!v.spinning(), "a press stops the spin");
    foreach (t; [2600, 3000, 6000])
        v.spinTick(cast(uint)t);
    foreach (i; 0 .. 9)
        assert(v.orientation.m[i] == midSpin.m[i],
               "and the camera is frozen from that instant, mid-profile");
}

unittest { // the tick is inert when nothing is spinning
    scope(exit) resetTrackball();
    resetTrackball();

    // A camera that has never seen the gesture — the state a user who does not
    // use the trackball is in on every frame of every session.
    auto v = new View(0, 0, kPaneWideW, kPaneWideH);
    assert(!v.spinning(), "a fresh camera is not spinning");
    immutable Orientation before = v.orientation;
    foreach (t; 0 .. 500) v.spinTick(cast(uint)(t * 16));
    foreach (i; 0 .. 9)
        assert(v.orientation.m[i] == before.m[i],
               "500 ticks on an idle camera must change nothing");

    // ...and the release path itself arms nothing unless the camera runs the
    // GESTURE. Both arms are checked on a camera that HAS a step recorded and
    // would otherwise spin, because a camera with no step returns one line
    // earlier and cannot tell whether the gate exists at all.
    {
        // The gesture switched off between the drag and the release.
        auto w = draggedCamera([9, 9, 9, 9, 9, 9]);
        setTrackballGlobal(false);
        assert(!w.trackballActive(), "the gesture is now off for this camera");
        w.trackballRelease(3000);
        assert(!w.spinning(), "momentum spin is trackball-only");
        setTrackballGlobal(true);
    }
    {
        // ...and an ORTHO cell, which never takes the trackball path. The gate
        // is `trackballActive` precisely so this exclusion is inherited rather
        // than restated — and a restatement is what would rot.
        auto w = draggedCamera([9, 9, 9, 9, 9, 9]);
        w.projKind = ProjKind.Ortho;
        assert(!w.trackballActive(), "an ortho cell never runs the gesture");
        w.trackballRelease(3000);
        assert(!w.spinning(), "so it never settling spins either");
    }
}

unittest { // reset stops a spin — a new document must not keep re-aiming
    scope(exit) resetTrackball();
    resetTrackball();

    auto v = draggedCamera([9, 9, 9, 9, 9, 9]);
    v.trackballRelease(2000);
    assert(v.spinning(), "armed");
    v.reset();
    assert(!v.spinning(), "reset stops the spin");
    immutable Orientation after = v.orientation;
    foreach (t; [2100, 3000, 5000]) v.spinTick(cast(uint)t);
    foreach (i; 0 .. 9)
        assert(v.orientation.m[i] == after.m[i],
               "and the reset camera stays where the reset put it");
}

unittest { // the swing arm: same rate, an swing that returns and never ends
    scope(exit) resetTrackball();
    resetTrackball();
    setTrackballSwing(true);

    auto v = draggedCamera([9, 9, 9, 9, 9, 9]);
    immutable Orientation atRelease = v.orientation;
    v.trackballRelease(2000);
    assert(v.spinning(), "the swing arms the same way");

    // A quarter period out it is at its extreme...
    v.spinTick(2000 + cast(uint)(kSwingPeriodMs / 4));
    immutable double amp = v.spinRate() * kSwingTimeMs;
    assert(isClose(rotAngleBetween(atRelease, v.orientation), amp, 5e-3),
           "the swing's peak displacement is rate*C");

    // ...and a full period out it is back where it started. A decaying profile
    // cannot do that, so this single assertion separates the two arms.
    v.spinTick(2000 + cast(uint)kSwingPeriodMs);
    assert(rotAngleBetween(atRelease, v.orientation) < 5e-3,
           "and it is home again after 1600 ms");
    assert(v.spinning(), "the swing does not terminate — only a press stops it");

    // Still going a full settling spin lifetime later, which is the other half of
    // "never terminates".
    v.spinTick(2000 + 5000);
    assert(v.spinning(), "still swinging well past 4000 ms");
}

unittest { // the spin's total does not depend on how the frames fell
    scope(exit) resetTrackball();
    resetTrackball();

    // The same release, ticked three ways: one tick at the end, sixty-hertz
    // frames, and a pathological run of two long hitches. A per-frame
    // ACCUMULATION would give three different cameras; a closed form of the
    // clock gives one.
    Orientation runWith(const(uint)[] ticks) {
        auto v = draggedCamera([9, 9, 9, 9, 9, 9]);
        v.trackballRelease(2000);
        foreach (t; ticks) v.spinTick(t);
        return v.orientation;
    }

    uint[] smooth;
    for (uint t = 2000; t <= 2000 + 4000; t += 16) smooth ~= t;
    smooth ~= 2000 + 4000;
    uint[] hitching = [2000 + 1900, 2000 + 1901, 2000 + 4000];

    immutable Orientation once  = runWith([2000 + 4000]);
    immutable Orientation many  = runWith(smooth);
    immutable Orientation hitch = runWith(hitching);

    // The bound is on the nine lanes, not on an angle: see `maxEntryDiff`.
    // 1e-5 against a total travel of ~2.2 radians is one part in a hundred
    // thousand — comfortably tighter than the difference a per-frame
    // accumulation would make, which grows with the number of ticks and is
    // 250 times the per-step rounding here, not once.
    assert(maxEntryDiff(once, many) < 1e-5,
           "one tick and 250 ticks must land on the same camera");
    assert(maxEntryDiff(once, hitch) < 1e-5,
           "and so must a run with two 1.9-second hitches");
    // The comparison is only worth anything if the spin went somewhere.
    auto still = draggedCamera([9, 9, 9, 9, 9, 9]);
    assert(rotAngleBetween(still.orientation, once) > 2.0,
           "and the spin these three agree about covered over 2 radians");
}
