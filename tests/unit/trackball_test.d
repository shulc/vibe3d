// Module unittests for `trackball`, moved verbatim out of source/trackball.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.trackball_test;

import math : Vec3, cross, dot;
import std.math : sqrt, atan2, isFinite, sin, PI;
import std.math : isClose, abs, cos;   // sin/PI come from the module import  // The two pane aspect ratios every radius assertion runs on. The first is // the corpus viewport (landscape, WIDTH is the larger dimension). The // second is a tall narrow pane observed in a reference trace, and it is the // discriminating one: its two half-extents differ by 2.27x, so `max` and // `min` cannot both be right to any tolerance. private enum int kWideW = 1098, kWideH = 832;
import trackball;

unittest { // the speed multiplier shrinks the CIRCLE, not just the rate
    immutable float r  = 200.0f;
    immutable float cx = 500.0f, cy = 300.0f;
    // A press at exactly half the radius is comfortably INSIDE at speed 1...
    immutable Vec3 slow = trackballVector(cx + 100.0f, cy, cx, cy, r, 1.0f);
    assert(slow.z > 0.0f, "at speed 1, r/2 pixels is inside the ball");
    // ...and lands exactly ON THE RIM at speed 2, because the effective pixel
    // circle is r/speed. This is the term that is easy to get wrong by applying
    // the multiplier to the resulting angle instead of to the pixel offsets.
    immutable Vec3 fast = trackballVector(cx + 100.0f, cy, cx, cy, r, 2.0f);
    assert(isClose(fast.z, 0.0f, 1e-5f, 1e-4f), "at speed 2, r/2 pixels is the rim");
    assert(isClose(fast.x, r, 1e-4f), "and it is clamped onto the rim");
}

unittest { // the arc: pure orbit at the centre, pure bank at the rim, blended between
    immutable float r  = 400.0f;
    immutable float cx = 500.0f, cy = 400.0f;

    float rollFractionAt(float pressRadius, float dragPx) {
        // Press at `pressRadius` to the RIGHT of centre, drag straight DOWN by
        // `dragPx` — a tangential step at every press radius, so the roll
        // content is a property of the press alone.
        immutable Vec3 v0 = trackballVector(cx + pressRadius, cy, cx, cy, r, 1.0f);
        immutable Vec3 v1 = trackballVector(cx + pressRadius, cy + dragPx,
                                            cx, cy, r, 1.0f);
        Vec3 axis; float angle;
        assert(trackballStep(v0, v1, axis, angle), "tangential step is not degenerate");
        return abs(axis.z);     // the VIEW-axis component == the bank content
    }

    // Centre: zero bank, to the last bit. `v0` is exactly (0,0,r) there, so the
    // cross product has an exactly-zero z component.
    assert(rollFractionAt(0.0f, 20.0f) == 0.0f, "a centre press is pure orbit");

    // Rim and beyond: the axis IS the view axis — pure bank, and it stays pure
    // however far out the press is.
    assert(isClose(rollFractionAt(r,        20.0f), 1.0f, 1e-4f), "a rim press is pure bank");
    assert(isClose(rollFractionAt(3.0f * r, 20.0f), 1.0f, 1e-4f), "and it stays pure bank");

    // Between: a MONOTONE staircase, each rung PINNED IN CLOSED FORM. For a
    // press at (rho, 0, z0) and an infinitesimal downward drag, `v1 x v0`
    // tends to (-z0, 0, rho) * eps, whose length is eps*r — so the bank
    // fraction tends to exactly rho/r. That is the value asserted at every
    // rung below.
    //
    // The RUNGS ARE THE TEST, and their placement is load-bearing: Shoemake
    // and Bell/Holroyd are IDENTICAL below the knee at r/sqrt(2), so a ladder
    // of interior rungs that all sit below 0.707 discriminates nothing no
    // matter how many rungs it has. This was verified the expensive way — an
    // earlier version of this ladder (0.1 / 0.25 / 0.5 / 0.707 / 0.9, asserting
    // only monotonicity plus one pin at 0.5) was mutation-tested against a
    // length-preserving hyperbolic sheet and SURVIVED. Most of the rungs below
    // are therefore deliberately PAST the knee.
    static immutable float[] fracs =
        [0.1f, 0.25f, 0.5f, 0.70710678f, 0.8f, 0.85f, 0.95f, 0.99f];
    float prev = -1.0f;
    foreach (f; fracs) {
        immutable float got = rollFractionAt(f * r, 0.05f);
        assert(isClose(got, f, 1e-2f),
               "the bank fraction at a press radius of f*r is exactly f");
        assert(got > prev, "and it grows monotonically with the press radius");
        assert(got > 0.0f && got < 1.0f, "staying strictly between the limits");
        prev = got;

        // What a hyperbolic sheet would have given at this rung, normalised
        // onto the same sphere so that ONLY the blend differs. Below the knee
        // the two agree exactly — which is why those rungs are here for the
        // shape and not for the discrimination — and past it they separate by
        // enough to see.
        if (f > 0.70710678f) {
            immutable float zb   = 1.0f / (2.0f * f);
            immutable float bell = f / sqrt(f * f + zb * zb);
            assert(!isClose(got, bell, 1e-2f),
                   "past the knee a hyperbolic sheet gives a different blend");
        }
    }

    // The separation, stated as numbers at the sharpest rung: at a press 1 %
    // inside the rim this law banks 99 % and a hyperbolic sheet banks 89 %.
    assert(isClose(rollFractionAt(0.99f * r, 0.05f), 0.99f, 1e-2f), "this law: 0.99");
    assert(isClose(0.99f / sqrt(0.99f * 0.99f + (1.0f / 1.98f) ^^ 2), 0.8907f, 1e-3f),
           "a hyperbolic sheet: 0.891, for contrast");
}

unittest { // a degenerate step changes nothing, and does NOT advance the anchor
    immutable float r  = 300.0f;
    immutable float cx = 400.0f, cy = 400.0f;
    Vec3 axis; float angle;

    // No movement at all.
    immutable Vec3 v = trackballVector(cx + 30.0f, cy + 10.0f, cx, cy, r, 1.0f);
    assert(!trackballStep(v, v, axis, angle), "a zero-length step is degenerate");

    // Straight OUT along a ray, from outside the rim: both points clamp onto
    // the SAME rim vector, so the whole excursion is degenerate. This is a
    // real, reachable gesture — and it is the signature of a hard rim clamp. A
    // hyperbolic sheet would rotate here, because its z keeps changing with the
    // press radius.
    immutable Vec3 near = trackballVector(cx + r + 10.0f, cy, cx, cy, r, 1.0f);
    immutable Vec3 far  = trackballVector(cx + r + 900.0f, cy, cx, cy, r, 1.0f);
    assert(near.x == far.x && near.y == far.y && near.z == far.z,
           "every point on a ray outside the rim lifts to the same vector");
    assert(!trackballStep(near, far, axis, angle),
           "so dragging straight outward outside the ball does nothing at all");
}

unittest { // the option resolves the way the reference resolves it
    scope(exit) resetTrackball();
    resetTrackball();

    // Shipped default: off, everywhere.
    assert(!trackballGlobal(), "the global ships off");
    assert(!resolveTrackball(TrackballOption.Default), "a Default cell reads the global");
    assert(!resolveTrackball(TrackballOption.Off),     "an Off cell is off");
    assert( resolveTrackball(TrackballOption.On),      "an On cell overrides the global");

    // Global on: Default follows it, explicit Off still wins.
    setTrackballGlobal(true);
    assert(resolveTrackball(TrackballOption.Default), "Default follows the global");
    assert(!resolveTrackball(TrackballOption.Off),    "an explicit Off still wins");

    // Force: every cell reads the global, INCLUDING the ones that said Off.
    // Note what this does NOT mean — it is not "force on".
    setTrackballGlobalOverride(true);
    assert(resolveTrackball(TrackballOption.Off),
           "force makes an Off cell read the global, which is on");
    setTrackballGlobal(false);
    assert(!resolveTrackball(TrackballOption.On),
           "force with the global OFF turns an On cell off — force is not 'force on'");
}

unittest { // the speed multiplier is clamped and never lets a NaN reach a camera
    scope(exit) resetTrackball();
    resetTrackball();
    assert(trackballMouseSpeed() == kTrackballSpeedDefault, "ships at 1.0");

    setTrackballMouseSpeed(float.nan);
    assert(trackballMouseSpeed() == kTrackballSpeedDefault, "NaN falls back to the default");
    setTrackballMouseSpeed(float.infinity);
    assert(trackballMouseSpeed() == kTrackballSpeedDefault, "Inf falls back to the default");
    setTrackballMouseSpeed(0.0f);
    assert(trackballMouseSpeed() == kTrackballSpeedMin, "zero clamps up");
    setTrackballMouseSpeed(-4.0f);
    assert(trackballMouseSpeed() == kTrackballSpeedMin, "negative clamps up");
    setTrackballMouseSpeed(1e9f);
    assert(trackballMouseSpeed() == kTrackballSpeedMax, "absurd clamps down");
    setTrackballMouseSpeed(2.5f);
    assert(trackballMouseSpeed() == 2.5f, "a sane value passes through");

    // The tablet value is a separate store, not an alias of the mouse one.
    setTrackballTabletSpeed(3.5f);
    assert(trackballMouseSpeed() == 2.5f && trackballTabletSpeed() == 3.5f,
           "mouse and tablet multipliers are independent");
}

unittest { // the two time constants are what they are said to be
    // The decimals are the shadow; the closed forms are the law. Both are
    // asserted so a later edit cannot quietly replace `8000/pi` with the
    // rounded 2546.479 (which would move the termination off 4000 ms by
    // 0.7 microseconds — invisible in a test that only checked the decimal).
    assert(isClose(kSettleTimeMs, 8000.0 / PI, 1e-15), "A is 8000/pi");
    assert(isClose(kSettleTimeMs, 2546.4790894703256, 1e-15), "...= 2546.4790894703256");
    assert(isClose(kSwingTimeMs, 800.0 / PI, 1e-15), "C is 800/pi");
    assert(isClose(kSwingTimeMs, 254.64790894703253, 1e-15), "...= 254.64790894703253");
    // Ten, exactly. The swing is the same profile run ten times faster, which
    // is why one number governs both and why mixing them up is a factor of ten
    // rather than a tolerance.
    assert(isClose(kSettleTimeMs / kSwingTimeMs, 10.0, 1e-14), "A is exactly 10*C");
    // The two durations follow from the constants, not from a second reading.
    assert(isClose(kSettleTimeMs * PI / 2.0, kSettleDurationMs, 1e-12),
           "settling spin ends at A*pi/2 = 4000 ms exactly");
    assert(isClose(2.0 * PI * kSwingTimeMs, kSwingPeriodMs, 1e-12),
           "the swing's period is 2*pi*C = 1600 ms exactly");
}

unittest { // settling spin: the closed form, the termination, and the total
    immutable double rate = 0.003;   // rad/ms — a brisk but ordinary flick

    // The profile IS `rate * A * sin(t/A)`, checked against the expression
    // rather than against sampled numbers, at a ladder that includes both ends.
    foreach (t; [0.0, 1.0, 250.0, 1000.0, 2000.0, 3000.0, 3999.0, 4000.0]) {
        immutable double want = rate * kSettleTimeMs * sin(t / kSettleTimeMs);
        assert(isClose(spinAngle(SpinCurve.Settle, rate, t), want, 1e-12, 1e-15),
               "settling spin angle is rate*A*sin(t/A)");
    }

    // It STARTS at the release rate — this is what makes the spin continuous
    // with the drag instead of a jump. A one-microsecond finite difference at
    // t = 0 recovers `rate` to eleven digits.
    immutable double d0 = (spinAngle(SpinCurve.Settle, rate, 1e-3) -
                           spinAngle(SpinCurve.Settle, rate, 0.0)) / 1e-3;
    assert(isClose(d0, rate, 1e-9), "the spin starts at exactly the release rate");

    // ...and it STOPS: the rate at the end is zero, so the camera coasts to a
    // halt rather than being cut off mid-motion.
    immutable double dEnd = (spinAngle(SpinCurve.Settle, rate, 4000.0) -
                             spinAngle(SpinCurve.Settle, rate, 3999.0)) / 1.0;
    assert(dEnd >= 0.0 && dEnd < rate * 1e-3,
           "the last millisecond of a settling spin moves ~nothing");

    // The total is `rate * A`, and the profile is pinned there for ever after.
    immutable double total = rate * kSettleTimeMs;
    immutable double atEnd = spinAngle(SpinCurve.Settle, rate, 4000.0);
    assert(isClose(atEnd, total, 1e-12), "the total extra angle is rate * 8000/pi");
    // BIT-equal, not close: after the end the camera must stop dead, so a tick
    // arriving at 4001 ms or an hour later applies a delta of exactly zero.
    foreach (t; [4000.0, 4001.0, 1.0e6])
        assert(spinAngle(SpinCurve.Settle, rate, t) == atEnd,
               "and it does not move again, ever — not even back down the sine");

    // Monotone the whole way. Without the clamp above, `sin` would turn over
    // past 4000 ms and the camera would spin BACKWARDS to where it started —
    // the single most likely way to get this profile wrong.
    double prev = -1.0;
    for (double t = 0; t <= 4000.0; t += 25.0) {
        immutable double a = spinAngle(SpinCurve.Settle, rate, t);
        assert(a >= prev, "the settling spin never runs backwards");
        prev = a;
    }
    assert(spinAngle(SpinCurve.Settle, rate, 8000.0) > 0.5 * total,
           "an unclamped sin(t/A) would be back at zero by 8000 ms");

    // Termination is at 4000, not at 3999 and not at 4001.
    assert(!spinEnded(SpinCurve.Settle, 3999.999), "still spinning at 3999.999 ms");
    assert( spinEnded(SpinCurve.Settle, 4000.0),   "over at exactly 4000 ms");

    // Before the release there is no angle at all (and a NaN clock cannot
    // reach the camera through this function).
    assert(spinAngle(SpinCurve.Settle, rate,  0.0) == 0.0, "t = 0 is no angle");
    assert(spinAngle(SpinCurve.Settle, rate, -5.0) == 0.0, "nor is t < 0");
    assert(spinAngle(SpinCurve.Settle, rate, double.nan) == 0.0, "nor is a NaN clock");
}

unittest { // swing: an swing that never ends, and is NOT a slow settling spin
    immutable double rate = 0.003;

    foreach (t; [0.0, 100.0, 400.0, 800.0, 1200.0, 1600.0, 5000.0]) {
        immutable double want = rate * kSwingTimeMs * sin(t / kSwingTimeMs);
        assert(isClose(spinAngle(SpinCurve.Swing, rate, t), want, 1e-12, 1e-15),
               "swing angle is rate*C*sin(t/C)");
        assert(!spinEnded(SpinCurve.Swing, t), "the swing never terminates");
    }

    // A quarter period out it is at its extreme, a half period out it is back
    // through zero, and a full period out it is home. That is the shape the
    // 1600 ms number NAMES, and it is what distinguishes this from a decay.
    immutable double amp = rate * kSwingTimeMs;
    assert(isClose(spinAngle(SpinCurve.Swing, rate, 400.0), amp, 1e-9),
           "peak displacement at a quarter period is rate*C");
    assert(spinAngle(SpinCurve.Swing, rate, 800.0).isClose(0.0, 1e-9, 1e-9),
           "back through zero at half a period");
    assert(isClose(spinAngle(SpinCurve.Swing, rate, 1200.0), -amp, 1e-9),
           "and PAST it: the swing reverses, which a decay never does");
    assert(spinAngle(SpinCurve.Swing, rate, 1600.0).isClose(0.0, 1e-9, 1e-9),
           "home again after one full 1600 ms period");
    // Same value one period later — the swing is undamped.
    assert(isClose(spinAngle(SpinCurve.Swing, rate, 400.0),
                   spinAngle(SpinCurve.Swing, rate, 2000.0), 1e-9),
           "and it repeats undamped, for ever");

    // The two profiles are not interchangeable, stated where they differ MOST
    // and not where they nearly agree: both leave the release at the same rate,
    // so at 50 ms they are within 0.5 % of each other and no assertion there
    // discriminates. One swing period later the swing is home at zero and the
    // settling spin has covered 59 % of its total travel and is still going.
    assert(spinAngle(SpinCurve.Swing, rate, kSwingPeriodMs)
             .isClose(0.0, 1e-9, 1e-9),
           "the swing is home after one period");
    assert(spinAngle(SpinCurve.Settle, rate, kSwingPeriodMs)
             > 0.5 * rate * kSettleTimeMs,
           "while the settling spin is past half its total travel — the two are "
           ~ "not one profile with two labels");
}

unittest { // the setting selects the profile, and ships on the terminating arm
    scope(exit) resetTrackball();
    resetTrackball();
    assert(!trackballSwing(), "the swing ships OFF");
    assert(activeSpinCurve() == SpinCurve.Settle,
           "so a release arms the settling spin");
    setTrackballSwing(true);
    assert(activeSpinCurve() == SpinCurve.Swing, "and the setting flips it");
    resetTrackball();
    assert(activeSpinCurve() == SpinCurve.Settle, "a reset puts it back");
}

unittest { // wire names round-trip
    foreach (o; [TrackballOption.Default, TrackballOption.Off, TrackballOption.On]) {
        TrackballOption got;
        assert(parseTrackballOption(trackballOptionName(o), got), "name parses");
        assert(got == o, "and round-trips");
    }
    TrackballOption unused;
    assert(!parseTrackballOption("yes", unused), "an unknown name is an error");
    assert(!parseTrackballOption("", unused),    "and so is an empty one");
}
