// Module unittests for `view`, moved verbatim out of source/view.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.view_test;

import math;
import std.math : sqrt, tan, PI;
import std.json : JSONValue, JSONType;
import trackball : TrackballOption, resolveTrackball, trackballRadius,
                   trackballVector, trackballStep, trackballMouseSpeed,
                   SpinCurve, spinAngle, spinEnded, activeSpinCurve;
import std.math : isClose, abs;
import trackball : setTrackballGlobal, resetTrackball, setTrackballMouseSpeed, trackballRadius;
import std.math : acos;
import trackball : kSettleTimeMs, kSettleDurationMs, kSwingTimeMs, kSwingPeriodMs, setTrackballSwing, spinAngle, SpinCurve;
import std.math : asin;
import view;

unittest { // the JSON codec round-trips an arbitrary orientation BIT-EXACTLY
    import std.json : parseJSON;
    // An orientation reached by composing turns about three different axes:
    // no (azimuth, elevation, bank) triple names it, which is the case a
    // lossy or chart-based encoding would silently fail.
    Orientation want = Orientation.fromAngles(0.5f, 0.4f, 0.0f)
                           .rotatedAbout(Vec3(1, 0, 0), 0.7f)
                           .rotatedAbout(Vec3(0, 0, 1), -1.1f)
                           .rotatedAbout(normalize(Vec3(1, 2, 1)), 0.55f);
    Orientation got;
    assert(orientationFromJson(parseJSON(orientationToJson(want)), got),
           "the codec must accept what it produced");
    assert(got.m == want.m,
           "an orientation must survive JSON exactly — nine significant digits "
           ~ "is what pins a float, and the matrix IS the camera");

    // Non-vacuous: the six-decimal precision every other camera field uses
    // would NOT survive this.
    import std.format : format;
    string lossy = format("[%f,%f,%f,%f,%f,%f,%f,%f,%f]",
                          want.m[0], want.m[1], want.m[2], want.m[3], want.m[4],
                          want.m[5], want.m[6], want.m[7], want.m[8]);
    Orientation coarse;
    assert(orientationFromJson(parseJSON(lossy), coarse), "the lossy form parses");
    assert(coarse.m != want.m,
           "if %f round-tripped exactly there would be nothing to protect and "
           ~ "this codec would not need to exist");
}

unittest { // the codec refuses anything that is not nine numbers
    import std.json : parseJSON;
    Orientation sentinel = Orientation.fromAngles(1.1f, -0.2f, 0.3f);
    foreach (bad; [`[1,0,0,0,1,0]`,              // too few
                   `[1,0,0,0,1,0,0,0,1,0]`,      // too many
                   `[1,0,0,0,1,0,0,0,"x"]`,      // not a number
                   `{"m":[1,0,0,0,1,0,0,0,1]}`,  // not an array
                   `9`, `null`, `[]`]) {
        Orientation o = sentinel;
        assert(!orientationFromJson(parseJSON(bad), o),
               "the codec must reject " ~ bad);
    }
    // Integers are legal JSON numbers and must be accepted — an identity
    // matrix written by hand is all 1s and 0s.
    Orientation ident;
    assert(orientationFromJson(parseJSON(`[1,0,0,0,1,0,0,0,1]`), ident),
           "an all-integer matrix must parse");
    assert(ident.m == [1.0f,0,0, 0,1,0, 0,0,1], "and land on the identity");
}

unittest { // a camera survives serialise -> parse -> camera, bit-exactly
    // The whole point, at the level the task is about: an arbitrary rotation
    // put on a View, written out, read back into another View, is the same
    // camera to the last bit — INCLUDING through the re-normalising write
    // funnel the reader goes through.
    import std.json : parseJSON;
    auto a = new View(0, 0, 800, 600);
    a.setOrientation(Orientation.fromAngles(0.5f, 0.4f, 0.0f)
                         .rotatedAbout(normalize(Vec3(0.3f, 1, -0.7f)), 1.27f));
    a.distance = 4.75f;
    a.focus    = Vec3(1, -2, 0.5f);

    auto j = parseJSON(a.toJson());
    auto b = new View(0, 0, 800, 600);
    Orientation parsed;
    assert(orientationFromJson(j["orientation"], parsed), "the published field parses");
    b.setOrientation(parsed);
    b.distance = cast(float) j["distance"].floating;
    b.focus    = Vec3(cast(float) j["focus"]["x"].floating,
                      cast(float) j["focus"]["y"].floating,
                      cast(float) j["focus"]["z"].floating);

    assert(b.orientation.m == a.orientation.m,
           "the rotation must survive the round trip bit-exactly");
    assert(b.viewport().view == a.viewport().view,
           "and so must every lane of the view matrix it renders");
}

unittest { // viewport() ortho: Top preset — forward = -Y, eye above focus
    auto v = new View(0, 0, 800, 600);
    v.projKind   = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Top;
    v.focus      = Vec3(0, 0, 0);
    v.distance   = 5.0f;
    Viewport vp  = v.viewport();
    // eye must be above focus along +Y
    assert(isClose(vp.eye.x, 0.0f, 1e-5f, 1e-5f), "Top eye.x");
    assert(isClose(vp.eye.y, 5.0f, 1e-5f),         "Top eye.y == distance");
    assert(isClose(vp.eye.z, 0.0f, 1e-5f, 1e-5f), "Top eye.z");
    // forward = -m[2], -m[6], -m[10] must be (0,-1,0)
    float fx = -vp.view[2], fy = -vp.view[6], fz = -vp.view[10];
    assert(isClose(fx, 0.0f, 1e-4f, 1e-4f) && isClose(fy,-1.0f,1e-4f) && isClose(fz, 0.0f,1e-4f,1e-4f),
           "Top forward must be (0,-1,0)");
    // must be ortho
    assert(isOrtho(vp), "Top preset must produce ortho matrix");
}

unittest { // viewport() ortho: Front preset — forward = -Z
    auto v = new View(0, 0, 800, 600);
    v.projKind   = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Front;
    v.focus      = Vec3(0, 0, 0);
    v.distance   = 5.0f;
    Viewport vp  = v.viewport();
    assert(isClose(vp.eye.z, 5.0f, 1e-5f), "Front eye.z == distance");
    float fx = -vp.view[2], fy = -vp.view[6], fz = -vp.view[10];
    assert(isClose(fz,-1.0f,1e-4f), "Front forward.z must be -1");
    assert(isOrtho(vp), "Front preset must produce ortho matrix");
}

unittest { // viewport() perspective: default — byte-identical to old code
    auto v1 = new View(0, 0, 800, 600);
    Viewport vp1 = v1.viewport();
    // projKind defaults to Perspective → same as before.
    assert(!isOrtho(vp1), "Default must not be ortho");
    assert(vp1.proj[15] == 0.0f, "Default proj[15] must be 0");
}

unittest { // pan() ortho Top: +dx moves focus along world X only, no Y/Z leak
    auto v = new View(0, 0, 800, 600);
    v.projKind   = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Top;
    v.focus      = Vec3(0, 0, 0);
    v.distance   = 5.0f;
    Vec3 before  = v.focus;
    v.pan(100, 0);   // pure horizontal drag
    Vec3 delta = v.focus - before;
    // X changes, Y and Z must not change (Y is the view axis, Z is locked)
    assert(abs(delta.y) < 1e-6f, "pan Top +dx must not move focus.y");
    assert(abs(delta.z) < 1e-6f, "pan Top +dx must not move focus.z");
    assert(abs(delta.x) > 1e-6f, "pan Top +dx must move focus.x");
}

unittest { // pan() perspective: regression guard — basis unchanged
    auto v = new View(0, 0, 800, 600);
    // Default projKind = Perspective
    Vec3 before = v.focus;
    v.pan(0, 100);  // pure vertical drag
    // focus.y must change (up in the spherical basis)
    assert(abs((v.focus - before).y) > 1e-4f,
           "perspective pan vertical must change focus.y");
}

unittest { // viewportWith(own-inputs) == viewport() for ortho Top
    auto v = new View(0, 0, 800, 600);
    v.projKind   = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Top;
    v.focus      = Vec3(1, 2, 3);
    v.distance   = 4.0f;
    v.azimuth    = 0.3f;
    v.elevation  = 0.2f;
    auto vp1 = v.viewport();
    auto vp2 = v.viewportWith(v.focus, v.distance, v.orientation);
    assert(isClose(vp1.eye.x, vp2.eye.x, 1e-5f) &&
           isClose(vp1.eye.y, vp2.eye.y, 1e-5f) &&
           isClose(vp1.eye.z, vp2.eye.z, 1e-5f),
           "viewportWith(own-inputs) eye must equal viewport() eye (ortho Top)");
    assert(vp1.view == vp2.view, "viewportWith(own-inputs) view must match viewport() (ortho Top)");
    assert(vp1.proj == vp2.proj, "viewportWith(own-inputs) proj must match viewport() (ortho Top)");
}

unittest { // viewportWith(own-inputs) == viewport() for perspective
    auto v = new View(0, 0, 800, 600);
    v.focus    = Vec3(0.5f, 0, -1.0f);
    v.distance = 6.0f;
    v.azimuth  = 1.2f;
    v.elevation = -0.3f;
    auto vp1 = v.viewport();
    auto vp2 = v.viewportWith(v.focus, v.distance, v.orientation);
    assert(isClose(vp1.eye.x, vp2.eye.x, 1e-5f) &&
           isClose(vp1.eye.y, vp2.eye.y, 1e-5f) &&
           isClose(vp1.eye.z, vp2.eye.z, 1e-5f),
           "viewportWith(own-inputs) eye must equal viewport() eye (perspective)");
    assert(vp1.view == vp2.view, "viewportWith(own-inputs) view must match viewport() (persp)");
    assert(vp1.proj == vp2.proj, "viewportWith(own-inputs) proj must match viewport() (persp)");
}

unittest { // toJsonWith(own-inputs) == toJson() after one viewport() call
    import std.json : parseJSON;
    auto v = new View(0, 0, 800, 600);
    v.focus    = Vec3(1, 0, 0);
    v.distance = 5.0f;
    v.azimuth  = 0.7f;
    v.elevation = 0.1f;
    v.viewport();  // prime the member eye
    string j1 = v.toJson();
    string j2 = v.toJsonWith(v.focus, v.distance, v.orientation);
    auto o1 = parseJSON(j1);
    auto o2 = parseJSON(j2);
    assert(isClose(o1["azimuth"].floating,   o2["azimuth"].floating,   1e-5f), "toJsonWith az");
    assert(isClose(o1["elevation"].floating, o2["elevation"].floating, 1e-5f), "toJsonWith el");
    assert(isClose(o1["distance"].floating,  o2["distance"].floating,  1e-5f), "toJsonWith dist");
    assert(isClose(o1["eye"]["x"].floating,  o2["eye"]["x"].floating,  1e-5f), "toJsonWith eye.x");
    assert(isClose(o1["eye"]["y"].floating,  o2["eye"]["y"].floating,  1e-5f), "toJsonWith eye.y");
    assert(isClose(o1["eye"]["z"].floating,  o2["eye"]["z"].floating,  1e-5f), "toJsonWith eye.z");
}

unittest { // first press from an unrelated view lands on the primary face
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.One)   == ViewPreset.Top);
    assert(nextViewForKey(ViewPreset.Left,        NumpadViewKey.Two)   == ViewPreset.Front);
    assert(nextViewForKey(ViewPreset.Back,        NumpadViewKey.Three) == ViewPreset.Right);
}

unittest { // repeat press on the SAME key toggles to the opposite face
    assert(nextViewForKey(ViewPreset.Top,   NumpadViewKey.One)   == ViewPreset.Bottom);
    assert(nextViewForKey(ViewPreset.Front, NumpadViewKey.Two)   == ViewPreset.Back);
    assert(nextViewForKey(ViewPreset.Right, NumpadViewKey.Three) == ViewPreset.Left);
}

unittest { // third press (repeat again) returns to the primary face
    ViewPreset p = ViewPreset.Perspective;
    p = nextViewForKey(p, NumpadViewKey.One); // -> Top
    p = nextViewForKey(p, NumpadViewKey.One); // -> Bottom
    p = nextViewForKey(p, NumpadViewKey.One); // -> Top again
    assert(p == ViewPreset.Top, "third press must return to the primary face");
}

unittest { // numpad `.` is idempotent regardless of current preset
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Period) == ViewPreset.Perspective);
    assert(nextViewForKey(ViewPreset.Top,         NumpadViewKey.Period) == ViewPreset.Perspective);
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Period) == ViewPreset.Perspective);
}

unittest { // fresh-from-Perspective: each key's first press is independent of the others
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.One)    == ViewPreset.Top);
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Two)    == ViewPreset.Front);
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Three)  == ViewPreset.Right);
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Period) == ViewPreset.Perspective);
}

unittest { // a level camera is the SAME camera the eye/target build produced
    // RE-BASELINED, deliberately, and this comment is the record of it.
    //
    // This assertion used to be `got.view == want` — bit equality against
    // `lookAt(focus + sphericalToCartesian(az, el, d), focus, +Y)` — and it
    // guarded the reference-comparison corpus (17 move legs / 18 rotate legs)
    // against moving by an ulp. Bit equality is UNATTAINABLE once the rotation
    // is stored, and the reason is a defect in what it was pinning: `lookAt`
    // derives its basis from `normalize(center - eye)`, so the matrix it
    // returned depended on the DISTANCE (it normalises a vector `d` long, and
    // scaling changes the rounding) and on the FOCUS (`center - eye`
    // re-rounds when the focus sits far from the origin). A rotation has
    // neither. Reproducing the old bits would mean reproducing both
    // dependencies, i.e. not storing a rotation at all.
    //
    // The residual is MEASURED, not assumed: over this sweep the nine
    // rotation lanes differ by at most 4.2e-7 and the three translation lanes
    // by at most 5.7e-7 of the distance — a few ulps, ~1e-6 of a world unit on
    // a 1.5-unit camera, some five orders below one pixel at this viewport
    // size. The corpus claim is now carried by RUNNING the corpus, and the
    // rendered-pixel claim by the framebuffer-digest probe, rather than by a
    // proxy that can no longer be true.
    auto v = new View(0, 0, 1098, 966);
    float worstRot = 0, worstTransRel = 0;
    int lookAtVariedWithFocus = 0;
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-1.5f, -0.4f, 0.0f, 0.4138754f, 1.5f]) {
        v.azimuth = a; v.elevation = e; v.distance = 1.486323332f;
        v.focus = Vec3(0.25f, -0.5f, 2.0f);
        v.roll = 0.0f;
        Viewport got = v.viewport();
        Vec3 off = sphericalToCartesian(a, e, v.distance);
        float[16] want = lookAt(v.focus + off, v.focus, Vec3(0, 1, 0));
        foreach (i; [0, 1, 2, 4, 5, 6, 8, 9, 10]) {
            immutable float dd = abs(got.view[i] - want[i]);
            if (dd > worstRot) worstRot = dd;
        }
        foreach (i; [12, 13, 14]) {
            immutable float rel = abs(got.view[i] - want[i]) / v.distance;
            if (rel > worstTransRel) worstTransRel = rel;
        }
        // The old oracle could only ever have held by replaying the focus
        // dependence. Show it was there: the SAME rotation about the origin
        // gives `lookAt` a different basis.
        float[16] atOrigin = lookAt(off, Vec3(0, 0, 0), Vec3(0, 1, 0));
        foreach (i; [0, 4, 8, 1, 5, 9, 2, 6, 10])
            if (atOrigin[i] != want[i]) { lookAtVariedWithFocus++; break; }
    }
    assert(worstRot <= 4.2e-7f,
           "a level camera's view basis must match the eye/target build to a few ulps");
    assert(worstTransRel <= 5.7e-7f,
           "a level camera's view translation must match to a few ulps of the distance");
    assert(lookAtVariedWithFocus >= 19,
           "the eye/target build really did make the BASIS depend on the focus — "
           ~ "if that stops being true, bit equality is back on the table and "
           ~ "this re-baseline must be revisited");
}

unittest { // pan follows the banked screen axes, by exactly the bank angle
    import std.math : sin, cos, abs;
    auto v = new View(0, 0, 800, 600);
    v.azimuth = -0.5040186f; v.elevation = 0.4138754f; v.distance = 3.0f;
    enum float r = 0.2055634f;
    Vec3 flat = v.panDeltaWith(100, 0, Orientation.fromAngles(v.azimuth, v.elevation, 0.0f));
    Vec3 bank = v.panDeltaWith(100, 0, Orientation.fromAngles(v.azimuth, v.elevation, r));
    // Same length (a rotation), and the angle between them is the bank.
    assert(isClose(flat.length, bank.length, 1e-4f), "pan magnitude is bank-invariant");
    float cosang = dot(normalize(flat), normalize(bank));
    assert(isClose(cosang, cos(r), 1e-4f, 1e-4f),
           "a horizontal pan under a bank rotates by exactly the bank angle");
    // A pan under a bank leaves the world XZ plane; the un-banked one cannot.
    assert(abs(flat.y) < 1e-6f, "un-banked horizontal pan stays in world XZ");
    assert(abs(bank.y) > 1e-3f, "banked horizontal pan must acquire a y component");
}

unittest { // rollBy keeps turning, and, unlike elevation, does not clamp
    auto v = new View(0, 0, 800, 600);
    assert(isClose(v.roll, 0.0f, 1e-6f, 1e-6f), "a fresh camera is level");
    v.rollBy(100);
    assert(isClose(v.roll, 0.5f, 1e-5f), "rollBy is 0.005 rad/px");
    v.rollBy(-100);
    assert(isClose(v.roll, 0.0f, 1e-5f, 1e-5f), "rollBy is signed and reversible");

    // "Does not clamp" now means what it should mean. The bank used to be an
    // unbounded accumulator, so a full turn was witnessed by `roll > 2*PI`.
    // With the rotation stored as a matrix there is no accumulator to
    // overflow: a bank of 3*PI IS a bank of PI, the same camera, and the
    // derived chart reads it back in (-PI, PI]. The property worth pinning is
    // therefore the one that always mattered — the drag keeps turning past a
    // full circle instead of stopping — so: roll a whole turn and land back on
    // the starting camera, bit-close, having passed through the far side.
    Orientation start = v.orientation;
    bool passedHalfway = false;
    foreach (i; 0 .. 20) {                 // 20 * 100 px * 0.005 = 10 rad
        v.rollBy(100);
        if (i == 6) passedHalfway = true;  // ~3.5 rad, beyond half a turn
    }
    assert(passedHalfway, "the sweep must go past half a turn");
    Orientation want = start.rotatedAbout(start.forward(), 10.0f);
    foreach (i; 0 .. 9)
        assert(abs(v.orientation.m[i] - want.m[i]) < 1e-5f,
               "twenty steps of 0.5 rad must be a turn of exactly 10 rad — a "
               ~ "clamp would have parked the camera short of it");
    // ...and 10 rad is past a full circle, so the chart necessarily wrapped.
    assert(v.roll < 10.0f - 2.0f * PI + 1e-4f,
           "the derived bank reads back on the (-PI, PI] chart, not as an "
           ~ "unbounded accumulator");

    v.reset();
    assert(v.roll == 0.0f, "reset() must level the horizon");
}

unittest { // viewportWith / toJsonWith carry a NON-ZERO bank the same way
    // The existing own-inputs round-trip tests above run at the default
    // bank of 0, where a dropped `roll` argument would be invisible. These
    // repeat them banked, so the explicit-inputs path is pinned on the term
    // that actually distinguishes it.
    import std.json : parseJSON;
    auto v = new View(0, 0, 800, 600);
    v.focus = Vec3(0.5f, 0, -1.0f);
    v.distance = 6.0f; v.azimuth = 1.2f; v.elevation = -0.3f;
    v.roll = 0.4137f;
    auto vp1 = v.viewport();
    auto vp2 = v.viewportWith(v.focus, v.distance, v.orientation);
    assert(vp1.view == vp2.view, "banked viewportWith(own-inputs) must match viewport()");
    // ...and a DIFFERENT rotation must produce a different matrix, so the
    // equality above is not vacuous.
    auto vp3 = v.viewportWith(v.focus, v.distance,
                              Orientation.fromAngles(v.azimuth, v.elevation, 0.0f));
    assert(vp1.view != vp3.view, "the orientation argument must reach the matrix");

    auto o1 = parseJSON(v.toJson());
    auto o2 = parseJSON(v.toJsonWith(v.focus, v.distance, v.orientation));
    assert(isClose(o1["roll"].floating, o2["roll"].floating, 1e-5f),
           "toJsonWith must report the bank it rendered");
    assert(isClose(o1["roll"].floating, 0.4137f, 1e-5f),
           "/api/camera must publish the bank");
}

unittest { // the ball is centred on the PANE, not on the window
    scope(exit) resetTrackball();
    resetTrackball();

    // A cell parked away from the window origin — a Split/Quad layout's
    // right-hand or bottom cell. Pressing at the CELL's centre must be the
    // bank-free case; pressing at the window centre must not be.
    setTrackballGlobal(true);
    auto v = new View(640, 360, 800, 600);
    v.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
    assert(v.trackballActive(), "fixture");

    v.trackballDown(640 + 400, 360 + 300);      // the cell's centre
    v.trackballMove(640 + 480, 360 + 300);
    assert(isClose(v.roll, 0.0f, 1e-4f, 1e-4f),
           "the cell centre must be the bank-free point, so the pane rect's "
           ~ "origin has to be subtracted before the lift");

    auto w = new View(640, 360, 800, 600);
    w.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
    w.trackballDown(400, 300);                  // the WINDOW centre — far off-pane
    w.trackballMove(480, 300);
    assert(abs(w.roll) > 1e-3f,
           "a press at the window centre is nowhere near the cell centre and "
           ~ "must bank — otherwise the subtraction is not happening");
}
