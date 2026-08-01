module tools.transform.relocate_plane_test;

// ---------------------------------------------------------------------------
// Tests for the click-relocate plane law.
//
// The first block is the measurement that fixes the SHAPE of the law: six
// landings captured off the reference, on two cameras and two principal axes.
// Those rows are the reason the quantum exists. They are NOT the reason it is
// switched off by default — that is a second measurement, and the two
// disagree; see `theQuantumStepIsContradictedAcrossRigs` below.
//
// THE TRAP THESE TESTS EXIST TO AVOID. This quantum was twice scored as
// evidence AGAINST the focus hypothesis, both times because the rig could not
// see it: once as a constant residual that was `step - remainder` and not a
// miss, once as six landings that all quantised to the same value. A rig
// whose focus sits ON a grid line proves nothing about a grid quantum,
// because the quantum is the IDENTITY there. Every assertion below that
// claims something about the quantum uses an OFF-LATTICE focus and sets
// `quantumStep` EXPLICITLY, and the fixed-point test states the blindness
// outright so a future reader cannot mistake a silent test for a passing one.
//
// The same trap has a second mouth, and it is the one that decided this
// port's default: a rig can also be blind because the step it would need is
// not the step another rig needs. Do not re-derive a constant here from one
// row without checking it against the other.
// ---------------------------------------------------------------------------

version (unittest) {

import math : Vec3, Viewport, lookAt, perspectiveMatrix, orthographicMatrix,
              normalize;
import tools.transform.relocate_plane;
import std.math : abs, PI, tan;
import std.format : format;

private bool near(float a, float b, float eps = 1e-4f) {
    return abs(a - b) < eps;
}

private bool nearV(Vec3 a, Vec3 b, float eps = 1e-4f) {
    return near(a.x, b.x, eps) && near(a.y, b.y, eps) && near(a.z, b.z, eps);
}

// A perspective viewport looking at `focus` from `eye`.
private Viewport perspVp(Vec3 eye, Vec3 focus) {
    Viewport vp;
    vp.view   = lookAt(eye, focus, Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 1098.0f / 832.0f, 0.01f, 100.0f);
    vp.width  = 1098;
    vp.height = 832;
    vp.eye    = eye;
    vp.focus  = focus;
    return vp;
}

// An axis-locked orthographic viewport: `axis` 0/1/2, `sign` +1/-1.
private Viewport orthoAxisVp(int axis, float sign, Vec3 focus, float dist = 3.0f) {
    Vec3 off = axis == 0 ? Vec3(sign * dist, 0, 0)
             : axis == 1 ? Vec3(0, sign * dist, 0)
             :             Vec3(0, 0, sign * dist);
    Vec3 up  = axis == 1 ? Vec3(0, 0, -sign) : Vec3(0, 1, 0);
    Viewport vp;
    vp.eye    = focus + off;
    vp.view   = lookAt(vp.eye, focus, up);
    vp.proj   = orthographicMatrix(dist * tan(cast(float)(PI / 8.0)),
                                   1098.0f / 832.0f, 0.001f, 100.0f);
    vp.width  = 1098;
    vp.height = 832;
    vp.focus  = focus;
    return vp;
}

// -------------------------------------------------------------------------
// 1. THE MEASUREMENT. Six landings off the reference, two cameras.
//
// Each row is (focus, principal axis k, the plane point the reference
// returned). Only Q is compared, because Q is what the capture read: it
// called the plane-point entry point directly rather than driving a click.
//
// The rig's own view snap step was 0.005 and its quantum was 1.0. Both are
// passed explicitly here — this block asserts that THE LAW reproduces the
// rig, not that vibe3d's defaults match a foreign host's preferences.
// -------------------------------------------------------------------------
unittest {
    static struct Row { Vec3 focus; int k; Vec3 q; string name; }
    // control_no_pan is one camera; the other five rows of the sweep are the
    // same camera under five different navigations and returned identical
    // numbers, so they are one row here and the count is stated honestly.
    immutable Row[] rows = [
        Row(Vec3(0.3426f, 0.0571f, -0.3551f), 2, Vec3(0.345f, 0.055f, 0.0f),
            "control_no_pan"),
        Row(Vec3(0.6836f, 1.8255f,  2.0027f), 1, Vec3(0.685f, 2.0f,  2.005f),
            "pan (x5: small_pan_x, big_pan_x, big_pan_y, big_pan_z, diagonal)"),
    ];
    foreach (r; rows) {
        auto got = niceOrigin(r.focus, r.k, 1.0f, 0.005f);
        assert(nearV(got, r.q, 1e-5f),
               format("plane point diverged on reference row '%s': "
                      ~ "law gave (%.6f, %.6f, %.6f), reference measured "
                      ~ "(%.6f, %.6f, %.6f)",
                      r.name, got.x, got.y, got.z, r.q.x, r.q.y, r.q.z));
    }
}

// THE CONTRADICTION, PINNED. `theQuantumStepIsContradictedAcrossRigs`.
//
// Two rigs in this tree measured this term, and no single step satisfies
// both. This test asserts that, so a later reader who wants to switch the
// quantum on has to confront it rather than rediscover it:
//
//   * SWEEP rig — focus 1.8255 came back as 2.0 (and -0.3551 as 0.0). That
//     pair admits 1.0 and 2.0, and nothing else in 0.05..20.
//   * BIG-PAN probe — focus -1.0291, on the out-of-plane axis, came back as
//     -1.03. That admits only steps at or below ~0.26.
//
// The intersection is EMPTY. Hence `RelocatePlanePrefs.quantumStep` defaults
// to 0 and the law's rounding is dormant until the grid-size question is
// answered by a read rather than by a fit.
unittest {
    immutable Vec3 sweepFocus  = Vec3(0.6836f, 1.8255f, 2.0027f);
    immutable Vec3 sweepFocus2 = Vec3(0.3426f, 0.0571f, -0.3551f);
    immutable float bigPanFocusOop = -1.0291f;
    immutable float bigPanEngine   = -1.03f;

    // The sweep rig is reproduced by 1.0 ...
    assert(near(niceOrigin(sweepFocus,  1, 1.0f, 0.005f).y, 2.0f, 1e-5f),
           "the sweep's pan row must be reproduced by a 1.0 step");
    assert(near(niceOrigin(sweepFocus2, 2, 1.0f, 0.005f).z, 0.0f, 1e-5f),
           "the sweep's control row must be reproduced by a 1.0 step");

    // ... and 1.0 is REFUTED by the big-pan probe, which the same step sends
    // to -1.0 instead of the -1.03 the engine returned.
    immutable float atOne = niceOrigin(Vec3(bigPanFocusOop, 0, 0), 0, 1.0f, 0.0f).x;
    assert(near(atOne, -1.0f, 1e-5f) && !near(atOne, bigPanEngine, 1e-3f),
           format("a 1.0 step must send the big-pan focus to -1.0, not to the "
                  ~ "measured -1.03 — got %.6f", atOne));

    // And every step that DOES reproduce the big-pan probe fails the sweep.
    foreach (i; 1 .. 521) {          // 0.0005 .. 0.2605
        immutable float s = i * 0.0005f;
        if (!near(niceOrigin(Vec3(bigPanFocusOop, 0, 0), 0, s, 0.0f).x,
                  bigPanEngine, 5e-5f)) continue;
        immutable float y = niceOrigin(sweepFocus, 1, s, 0.0f).y;
        assert(!near(y, 2.0f, 1e-3f),
               format("step %.4f reproduces BOTH rigs (big-pan -1.03 and sweep "
                      ~ "2.0) — the contradiction this test pins has been "
                      ~ "resolved and the default should be revisited", s));
    }
}

// The default is OFF, and that is a decision, not an oversight: with it off
// the plane point is the RAW focus, which is what every fixture in this tree
// was captured against.
unittest {
    auto vp = perspVp(Vec3(2, 3, 4), Vec3(0.4f, 1.7f, 0.2f));
    RelocatePlanePrefs p;
    auto pp = workPlanePoint(vp, 1, p);
    assert(near(pp.q.y, 1.7f),
           format("with the quantum off the plane point must be the RAW focus: "
                  ~ "y should be 1.7, got %.6f", pp.q.y));
}

// The view snap step does not change the LANDING, only the plane point's
// in-plane components — which the landing never reads. This is why the port
// can default it to "off" without losing the measurement.
unittest {
    immutable Vec3[2] focuses = [Vec3(0.6836f, 1.8255f, 2.0027f),
                                 Vec3(0.3426f, 0.0571f, -0.3551f)];
    immutable int[2]  ks      = [1, 2];
    foreach (i; 0 .. 2) {
        auto withSnap = niceOrigin(focuses[i], ks[i], 1.0f, 0.005f);
        auto without  = niceOrigin(focuses[i], ks[i], 1.0f, 0.0f);
        immutable float a = axisComp(withSnap, ks[i]);
        immutable float b = axisComp(without,  ks[i]);
        assert(near(a, b, 1e-6f),
               format("the out-of-plane component must not depend on the view "
                      ~ "snap step on row %d: %.6f with snap, %.6f without",
                      i, a, b));
    }
}

// -------------------------------------------------------------------------
// 2. The quantum, stated as behaviour.
// -------------------------------------------------------------------------

// An OFF-LATTICE focus moves the plane, and moves it to the lattice.
unittest {
    auto vp = perspVp(Vec3(2, 3, 4), Vec3(0.4f, 1.7f, 0.2f));
    RelocatePlanePrefs p;
    p.quantumStep = 1.0f;                 // the default is OFF — see the field
    auto pp = workPlanePoint(vp, 1, p);
    assert(pp.k == 1);
    assert(near(pp.q.y, 2.0f),
           format("focus y=1.7 must quantise to 2.0, got %.6f", pp.q.y));
    // The in-plane components are untouched with the snap step off.
    assert(near(pp.q.x, 0.4f) && near(pp.q.z, 0.2f),
           "in-plane components must be untouched when the view snap step is off");
}

// THE BLINDNESS, NAMED. A focus on a grid line is a fixed point of the
// quantum, so no rig built on one can see it. Every fixture in this tree puts
// the camera focus at the world origin, which is such a point.
unittest {
    auto vp = perspVp(Vec3(2, 3, 4), Vec3(0, 0, 0));
    RelocatePlanePrefs p;
    p.quantumStep = 1.0f;                 // LIVE, or this test asserts nothing
    foreach (k; 0 .. 3) {
        auto pp = workPlanePoint(vp, k, p);
        assert(nearV(pp.q, Vec3(0, 0, 0), 1e-9f),
               "a focus at the origin is a FIXED POINT of the quantum — a rig "
               ~ "built on one cannot discriminate the law from its absence");
    }
}

// -------------------------------------------------------------------------
// 3. The locked-axis short-circuit.
// -------------------------------------------------------------------------

unittest { // the six axis presets are recognised, perspective is not
    foreach (axis; 0 .. 3) {
        foreach (sign; [1.0f, -1.0f]) {
            auto vp = orthoAxisVp(axis, sign, Vec3(0, 0, 0));
            assert(lockedViewAxis(vp) == axis,
                   format("ortho preset axis=%d sign=%.0f must report locked "
                          ~ "axis %d, got %d", axis, sign, axis,
                          lockedViewAxis(vp)));
        }
    }
    auto pv = perspVp(Vec3(2, 3, 4), Vec3(0, 0, 0));
    assert(lockedViewAxis(pv) == -1, "a perspective view has no locked axis");
}

// In an axis-locked view the plane point is the RAW focus — no quantum — and
// the landing keeps the click's other two coordinates exactly.
unittest {
    // Focus deliberately off-lattice on every axis so a leaked quantum shows.
    auto vp = orthoAxisVp(1, 1.0f, Vec3(0.4f, 1.7f, 0.2f));
    RelocatePlanePrefs p;
    p.quantumStep = 1.0f;                 // LIVE: the point is that it must NOT apply here
    auto pp = workPlanePoint(vp, 1, p);
    assert(near(pp.q.y, 1.7f),
           format("an axis-locked view takes the RAW focus; y must stay 1.7, "
                  ~ "got %.6f (2.0 means the quantum leaked into this arm)",
                  pp.q.y));

    // And the landing: one coordinate replaced, no ray.
    Vec3 click = Vec3(-1.25f, 99.0f, 0.75f);   // y is the discarded depth
    Vec3 dir   = Vec3(0, -1, 0);
    Vec3 c;
    assert(posToPrincipalPlane(vp, click, dir, 1, pp.q, false, 0.0f, c),
           "the locked arm cannot fail — a refusal here means the ray arm ran");
    assert(nearV(c, Vec3(-1.25f, 1.7f, 0.75f)),
           format("locked arm must replace only the locked coordinate, "
                  ~ "got (%.4f, %.4f, %.4f)", c.x, c.y, c.z));
}

// The locked arm ignores the principal axis entirely: the answer is the same
// whichever k it is handed. That is the property that distinguishes it from a
// ray that happens to be axis-parallel.
unittest {
    auto vp = orthoAxisVp(2, 1.0f, Vec3(0.4f, 1.7f, 0.2f));
    Vec3 q  = Vec3(9.0f, 8.0f, 0.2f);
    Vec3 click = Vec3(-1.25f, 0.5f, 42.0f);
    Vec3 first;
    // k=0 with a ray along -Z is UNREACHABLE by the ray arm (D[0] == 0). The
    // locked arm answers it anyway, and that is the whole distinction.
    assert(posToPrincipalPlane(vp, click, Vec3(0, 0, -1), 0, q, false, 0.0f, first),
           "the locked arm must answer a k the ray arm could never reach — "
           ~ "a refusal here means the short-circuit is gone");
    foreach (k; 0 .. 3) {
        Vec3 c;
        assert(posToPrincipalPlane(vp, click, Vec3(0, 0, -1), k, q, false, 0.0f, c),
               format("the locked arm must not refuse, but k=%d did", k));
        assert(nearV(c, first, 1e-9f),
               format("the locked arm must not read k, but k=%d moved the "
                      ~ "answer", k));
    }
    assert(nearV(first, Vec3(-1.25f, 0.5f, 0.2f)),
           format("locked landing must be the click with z replaced by Q[z], "
                  ~ "got (%.4f, %.4f, %.4f)", first.x, first.y, first.z));
}

// -------------------------------------------------------------------------
// 4. The work-plane bias.
// -------------------------------------------------------------------------

// Disabled by default: strength 0 leaves the argmax alone whatever the view.
unittest {
    RelocatePlanePrefs p;
    assert(p.strength == 0.0f && p.preferredAxis == -1 && !p.lock
           && p.lockVal == 0.0f && p.viewSnapStep == 0.0f
           && p.quantumStep == 0.0f,
           "every preference must default to the value that disables it");
    foreach (k; 0 .. 3)
        assert(biasedAxis(k, normalize(Vec3(0.1f, 0.99f, 0.05f)), p) == k,
               "a zero strength must never move the axis");
}

// The rule, and its exact threshold.
//
// |D[1]| = 0.75, so the swap fires iff strength > 0.25. Both 0.75 and 0.25
// are exact in binary floating point and so is their difference — the
// threshold case below is a REAL tie, not a tie that rounding turned into a
// comparison of two nearby numbers.
unittest {
    Vec3 d = Vec3(0.0f, 0.75f, 0.0f);
    RelocatePlanePrefs p;
    p.preferredAxis = 1;

    p.strength = 0.5f;
    assert(biasedAxis(0, d, p) == 1,
           "strength 0.5 > 1-0.75 must adopt the preferred axis");

    p.strength = 0.125f;
    assert(biasedAxis(0, d, p) == 0,
           "strength 0.125 < 1-0.75 must leave the argmax winner");

    // STRICTLY greater: at exactly the threshold the argmax wins.
    assert(1.0f - 0.75f == 0.25f, "the threshold must be exact for this test");
    p.strength = 0.25f;
    assert(biasedAxis(0, d, p) == 0,
           "the comparison is STRICT — at strength == 1-|D[j]| the argmax wins");

    // Face-on to a DIFFERENT axis: the preferred plane is edge-on, no swap.
    p.strength = 0.5f;
    assert(biasedAxis(0, Vec3(0.99f, 0.02f, 0.0f), p) == 0,
           "the bias must not fire when the preferred plane is edge-on");
}

// The bias re-derives the plane point, because the quantum is applied to
// whichever coordinate is out-of-plane and the bias changes which that is.
unittest {
    // Focus off-lattice on X and Y by different amounts so the two candidate
    // plane points are distinguishable.
    auto vp = perspVp(Vec3(0.2f, 8.0f, 0.1f), Vec3(0.4f, 1.7f, 0.2f));
    RelocatePlanePrefs p;
    p.quantumStep   = 1.0f;
    p.preferredAxis = 1;
    p.strength      = 0.99f;                 // fires for almost any view
    auto pp = workPlanePoint(vp, 0, p);
    assert(pp.k == 1, "the bias must move the principal axis to the preference");
    assert(near(pp.q.y, 2.0f),
           format("the plane point must be RE-QUANTISED on the new axis: "
                  ~ "y should be 2.0, got %.6f", pp.q.y));
    assert(near(pp.q.x, 0.4f),
           format("and the old axis must go back to being in-plane and raw: "
                  ~ "x should be 0.4, got %.6f", pp.q.x));
}

// The bias is skipped in an axis-locked view, and skipped under a lock.
unittest {
    RelocatePlanePrefs p;
    p.preferredAxis = 1;
    p.strength      = 0.99f;
    auto lockedVp = orthoAxisVp(2, 1.0f, Vec3(0.4f, 1.7f, 0.2f));
    assert(workPlanePoint(lockedVp, 0, p).k == 0,
           "an axis-locked view is excluded from the bias");
    p.lock = true;
    assert(biasedAxis(0, Vec3(0, 1, 0), p) == 0,
           "a locked work plane is excluded from the bias");
}

// -------------------------------------------------------------------------
// 5. The lock.
// -------------------------------------------------------------------------

unittest {
    auto vp = perspVp(Vec3(2, 3, 4), Vec3(0.4f, 1.7f, 0.2f));
    RelocatePlanePrefs p;
    p.lock          = true;
    p.preferredAxis = 0;
    p.lockVal       = -2.5f;
    auto pp = workPlanePoint(vp, 1, p);
    assert(pp.k == 0, "a lock with a preferred axis forces that axis");
    assert(near(pp.q.x, -2.5f),
           format("the locked coordinate must be the lock value, got %.6f",
                  pp.q.x));

    // In an axis-locked VIEW the lock does not get to move the axis (the
    // reference gates that on the view having no locked axis of its own),
    // but the lock VALUE is still written.
    auto lockedVp = orthoAxisVp(2, 1.0f, Vec3(0.4f, 1.7f, 0.2f));
    auto pp2 = workPlanePoint(lockedVp, 1, p);
    assert(pp2.k == 1,
           "an axis-locked view must keep the argmax axis under a lock");
    assert(near(pp2.q.y, -2.5f),
           format("the lock value is written to the axis in use, got %.6f",
                  pp2.q.y));
}

// -------------------------------------------------------------------------
// 6. The final snap of the answer.
// -------------------------------------------------------------------------

unittest {
    auto vp = perspVp(Vec3(0, 5, 0), Vec3(0, 0, 0));
    Vec3 c;
    // Ray straight down from (0.37, 5, 0.61) meets y=0 at (0.37, 0, 0.61).
    assert(posToPrincipalPlane(vp, Vec3(0.37f, 5, 0.61f), Vec3(0, -1, 0),
                               1, Vec3(0, 0, 0), false, 0.0f, c));
    assert(nearV(c, Vec3(0.37f, 0, 0.61f)), "unsnapped landing");

    assert(posToPrincipalPlane(vp, Vec3(0.37f, 5, 0.61f), Vec3(0, -1, 0),
                               1, Vec3(0, 0, 0), true, 0.25f, c));
    assert(nearV(c, Vec3(0.25f, 0, 0.5f)),
           format("a 0.25 snap step must round the ANSWER, got (%.4f, %.4f, %.4f)",
                  c.x, c.y, c.z));

    // A non-positive step returns immediately rather than rounding by zero.
    assert(posToPrincipalPlane(vp, Vec3(0.37f, 5, 0.61f), Vec3(0, -1, 0),
                               1, Vec3(0, 0, 0), true, 0.0f, c));
    assert(nearV(c, Vec3(0.37f, 0, 0.61f)),
           "a zero snap step must leave the answer alone");
}

// -------------------------------------------------------------------------
// 7. Pieces.
// -------------------------------------------------------------------------

unittest { // Dnint rounds half AWAY FROM ZERO, not half-to-even
    assert(dnint(0.5f)  ==  1.0f, "0.5 must round to 1, not to 0 (half-to-even)");
    assert(dnint(1.5f)  ==  2.0f);
    assert(dnint(2.5f)  ==  3.0f, "2.5 must round to 3, not to 2 (half-to-even)");
    assert(dnint(-0.5f) == -1.0f, "-0.5 must round to -1");
    assert(dnint(-2.5f) == -3.0f);
    assert(dnint(1.4f)  ==  1.0f);
    assert(dnint(-1.4f) == -1.0f);
}

unittest { // the ray arm refuses a view direction lying in the plane
    auto vp = perspVp(Vec3(5, 0, 0), Vec3(0, 0, 0));
    Vec3 c;
    assert(!posToPrincipalPlane(vp, Vec3(5, 0, 0), Vec3(-1, 0, 0),
                                1, Vec3(0, 0, 0), false, 0.0f, c),
           "a ray with no component along the principal axis must refuse");
}

unittest { // the whole chain reports the axis it actually used, and lands on it
    auto vp = perspVp(Vec3(0.2f, 8.0f, 0.1f), Vec3(0.4f, 1.7f, 0.2f));
    RelocatePlanePrefs p;
    p.quantumStep   = 1.0f;
    p.preferredAxis = 0;
    p.strength      = 0.99f;   // the view is near face-on to Y, so X needs ~0.97
    Vec3 c;
    int used;
    // An oblique ray: it must have a component along X or the X plane it is
    // about to be sent to cannot be reached.
    assert(principalPlaneCenter(vp, Vec3(0.4f, 8.0f, 0.2f),
                                normalize(Vec3(-1, -1, 0)), 1, p, c, used));
    assert(used == 0,
           format("principalPlaneCenter must report the axis the bias chose, "
                  ~ "got %d", used));
    // focus.x = 0.4 quantises to 0.0, so the landing sits on x = 0.
    assert(near(c.x, 0.0f),
           format("the landing must sit on the QUANTISED plane x=0, got %.6f",
                  c.x));
}

} // version (unittest)
