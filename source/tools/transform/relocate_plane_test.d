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
              normalize, lockedViewAxis;
import tools.transform.relocate_plane;
import viewgrid : dnint;
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

// THE "CONTRADICTION" WAS AN AXIS-INDEX MISTAKE, AND BOTH RIGS REPRODUCE.
//
// This block used to assert the opposite: that no single step satisfied both
// rigs, and that the quantum therefore had to stay dormant. That assertion
// was sound arithmetic on a wrong premise — it read the second rig's
// out-of-plane axis as X when it is Y — so it is replaced here rather than
// deleted, because the wrong version was persuasive and the correction is
// the useful artefact.
//
// What the two rigs actually measured:
//
//   * SWEEP rig, sub-step 0.005 -> its pixel size is in (0.002, 0.005], so
//     25 pixels is in (0.05, 0.125] and the grid step is 0.1 or 0.2 — a
//     quantum of 1.0 or 2.0. Its two rows need exactly that.
//   * BIG-PAN rig, sub-step 0.002 -> pixel size in (0.001, 0.002], 25 pixels
//     in (0.025, 0.05], grid step 0.05 — a quantum of 0.5. Its quantised
//     row is 0.3437 -> 0.5 on axis Y. The -1.0291 -> -1.03 row that used to
//     be read as the quantum is the IN-PLANE component snap, at 0.002.
//
// Two ordinary modelling zooms about a factor of two apart. The step is
// derived, not constant, so there was never anything to contradict.
//
// The assertions below are the two rigs, component by component, under
// `viewgrid`'s law — and, crucially, under a step DERIVED from each rig's own
// measured sub-step rather than hand-picked to fit. That is what makes this a
// test of the law and not a restatement of four numbers.
unittest {
    import viewgrid : ViewGridPrefs, viewGridSubStep, relocateQuantum,
                      viewGridSize;

    ViewGridPrefs g;                       // the shipped ladder, {1, 2, 5, 10}

    // For each rig, its measured SUB-STEP constrains the pixel size, and the
    // pixel size determines the quantum. So the quantum a rig may have had is
    // a derived SET, not a fitted number — and that set is what is asserted.
    //
    // The interval is derived by SELECTION rather than hand-computed: sweep a
    // wide range of pixel sizes, keep the ones whose sub-step is the value
    // that rig measured, and collect the quanta over exactly those. Nothing
    // here encodes an endpoint someone worked out on paper.
    struct Rig { string name; float subStep; float[] quanta; }
    foreach (r; [Rig("sweep",   0.005f, [1.0f, 2.0f]),
                 Rig("big-pan", 0.002f, [0.5f])]) {
        float[] seen;
        int matched = 0;
        enum int N = 4000;
        foreach (i; 0 .. N + 1) {
            // 1e-4 .. 1e-2, geometric.
            immutable float px = cast(float)(1e-4 * (100.0 ^^ (cast(double)i / N)));
            if (!near(viewGridSubStep(px, viewGridSize(px, g), g), r.subStep, 1e-7f))
                continue;
            ++matched;
            immutable float q = relocateQuantum(px, g);
            bool known = false;
            foreach (v; seen) if (near(v, q, 1e-6f)) known = true;
            if (!known) seen ~= q;
        }
        assert(matched > 100,
               format("%s: no pixel size in the sweep produces its measured "
                      ~ "sub-step %.4f — the selection is empty and this rig "
                      ~ "would assert nothing", r.name, r.subStep));
        assert(seen.length == r.quanta.length,
               format("%s: a sub-step of %.4f admits %d quantum value(s), got "
                      ~ "%d", r.name, r.subStep, r.quanta.length, seen.length));
        foreach (want; r.quanta) {
            bool found = false;
            foreach (v; seen) if (near(v, want, 1e-6f)) found = true;
            assert(found, format("%s: %.4f must be an admissible quantum",
                                 r.name, want));
        }
    }

    // SWEEP rig, both rows, all three components.
    immutable Vec3 sweepPan  = Vec3(0.6836f, 1.8255f, 2.0027f);   // axis Y
    immutable Vec3 sweepCtl  = Vec3(0.3426f, 0.0571f, -0.3551f);  // axis Z
    assert(nearV(niceOrigin(sweepPan, 1, 1.0f, 0.005f),
                 Vec3(0.685f, 2.0f, 2.005f), 1e-5f),
           "the sweep's pan row must reproduce on ALL THREE components");
    assert(nearV(niceOrigin(sweepCtl, 2, 1.0f, 0.005f),
                 Vec3(0.345f, 0.055f, 0.0f), 1e-5f),
           "the sweep's control row must reproduce on ALL THREE components");

    // BIG-PAN rig: out-of-plane axis Y, quantum 0.5, in-plane snap 0.002.
    // The row the old test misread is the FIRST component here, and it comes
    // out right precisely because it is NOT the quantised one.
    immutable Vec3 bigPan = Vec3(-1.0291f, 0.3437f, -1.0939f);
    assert(nearV(niceOrigin(bigPan, 1, 0.5f, 0.002f),
                 Vec3(-1.03f, 0.5f, -1.094f), 1e-5f),
           "the big-pan rig must reproduce on all three components with the "
           ~ "out-of-plane axis read as Y");

    // The refutation, stated as a test: reading that rig's axis as X is what
    // produced the empty intersection, and it visibly does NOT reproduce.
    assert(!nearV(niceOrigin(bigPan, 0, 0.5f, 0.002f),
                  Vec3(-1.03f, 0.5f, -1.094f), 1e-3f),
           "reading the big-pan rig's out-of-plane axis as X must NOT "
           ~ "reproduce it — that mistake is the whole of the old "
           ~ "'contradiction' and this assertion is what keeps it refuted");
}

// THE PLANE-POINT SNAP IS MASKED BY THE QUANTUM, MEASURED RATHER THAN ARGUED.
//
// `niceOrigin` snaps all three components of Q and then quantises Q[k]. The
// quantum is `10 * gridSize` and the sub-step is `niceCeil(pixelSize)`; both
// are ladder values and the first is hundreds of times the second, so the
// quantum is always a whole number of sub-steps. Rounding to the sub-step
// first therefore cannot change what rounding to the quantum produces —
// except when the focus sits within half a sub-step of a quantum HALF-
// boundary, where the two roundings disagree by one quantum.
//
// The anchor plane reads ONLY Q[k], so the snap of the surviving component is
// masked here.
unittest {
    import viewgrid : ViewGridPrefs, viewGridSize, viewGridSubStep,
                      relocateQuantum;

    ViewGridPrefs g;
    int agree = 0, disagree = 0;
    foreach (i; 0 .. 2000) {
        immutable float px = 0.004f;                 // a plain modelling zoom
        immutable float q  = relocateQuantum(px, g);
        immutable float ss = viewGridSubStep(px, viewGridSize(px, g), g);
        assert(q > 0 && ss > 0);
        // A focus sweeping across several quanta, off any lattice.
        immutable float fy = -3.7f + 0.0037f * i;
        immutable float withSnap = niceOrigin(Vec3(0, fy, 0), 1, q, ss).y;
        immutable float bare     = niceOrigin(Vec3(0, fy, 0), 1, q, 0.0f).y;
        if (abs(withSnap - bare) < 1e-5f) ++agree; else ++disagree;
    }
    // Overwhelmingly masked, and the exceptions are exactly the half-boundary
    // ties. Asserted as a RATE rather than "always", because "always" is false
    // and a test that claimed it would be wrong in a way nobody would notice.
    assert(agree > 1990,
           format("the sub-step snap must be masked by the quantum on the "
                  ~ "quantised axis: %d of 2000 sweeps disagreed", disagree));
    assert(disagree <= 10,
           "the disagreements must be the rare half-boundary ties, not a rule");
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
// 3. The axis-view recogniser (`math.lockedViewAxis`).
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

} // version (unittest)
