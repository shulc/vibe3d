// Task 0596 — WHICH colour reaches WHICH gizmo part, pinned by value.
//
// Pure unittest (no HTTP, no GL, and deliberately NO RENDERING): constructs
// the three handler banks directly and reads the colour off each named
// sub-handle. Model: tests/test_gizmo_handle_geometry.d, which pins where a
// handle IS by the same means.
//
// WHY THIS FILE EXISTS. `source/viewport_scheme.d`'s own unittests pin what
// each palette entry IS. They cannot see the other half of the bug, which is
// the half that actually reaches the user: a correct entry handed to the wrong
// part. Swapping two arguments in a constructor — Y's colour onto the Z arm,
// the plane outline onto its fill — changes no value, breaks no scheme test,
// and compiles. So the routing needs its own pins, and they belong here, on
// the constructed objects, not on the table.
//
// WHY NOT A SCREENSHOT. A pixel is the end of a long pipeline (geometry,
// shader, blending, gamma, compositor), so a mismatch localises nothing and a
// match proves nothing — two errors that cancel produce the identical image.
// We own this source, so the colour is readable directly, and reading it is
// both cheaper and strictly more informative than looking at it.
//
// EVERY EXPECTED VALUE IS RESTATED AS A LITERAL rather than imported from
// `viewport_scheme`. An independent restatement is the point — asserting
// `arrowY.color == schemeColor(SchemeColor.axisY)` passes no matter what
// either side says, and would have passed just as happily before this task
// when both said the wrong thing. Same convention as
// test_gizmo_handle_geometry.d's hard-coded geometry constants.

import std.math : abs;

import handler : MoveHandler, RotateHandler, ScaleHandler;
import math : Vec3;
import viewport_scheme : handleColor, planeRingColor, planeFillColor,
    kPlaneFillScale, HandlePaint;

void main() {}

// The scheme, restated. These are the values task 0596 pinned.
private enum Vec3 AXIS_X       = Vec3(0.9f, 0.2f, 0.2f);
private enum Vec3 AXIS_Y       = Vec3(0.2f, 0.8f, 0.2f);
private enum Vec3 AXIS_Z       = Vec3(0.2f, 0.4f, 1.0f);
private enum Vec3 HANDLE       = Vec3(0.4f, 1.0f, 1.0f);
private enum Vec3 ACTIVE       = Vec3(1.0f, 0.9f, 0.4f);
private enum Vec3 VIEW_RING    = Vec3(0.6f, 0.6f, 0.6f);

// What each of these REPLACED. Asserting their absence is what makes the
// pins above discriminating: without this block a test could pass by
// accident on a build where nothing was corrected at all.
private enum Vec3 WAS_AXIS_Y   = Vec3(0.2f, 0.9f, 0.2f);   // green too bright
private enum Vec3 WAS_AXIS_Z   = Vec3(0.2f, 0.2f, 0.9f);   // dark pure blue
private enum Vec3 WAS_CENTRE   = Vec3(0.0f, 0.9f, 0.9f);   // too dark/saturated
private enum Vec3 WAS_SCALEARM = Vec3(1.0f, 1.0f, 0.0f);   // hand-picked yellow
private enum Vec3 WAS_ROLLOVER = Vec3(1.0f, 0.95f, 0.15f); // a state that does not exist
private enum Vec3 WAS_SELECTED = Vec3(1.0f, 0.64f, 0.0f);  // the MESH selection orange

private bool same(Vec3 a, Vec3 b) {
    enum float EPS = 1e-6f;
    return abs(a.x - b.x) < EPS && abs(a.y - b.y) < EPS && abs(a.z - b.z) < EPS;
}

// Guard the guard: if any "was" value ever equalled its replacement, the
// absence assertions below would be vacuous and would say so.
unittest {
    assert(!same(AXIS_Y, WAS_AXIS_Y));
    assert(!same(AXIS_Z, WAS_AXIS_Z));
    assert(!same(HANDLE, WAS_CENTRE));
    assert(!same(AXIS_X, WAS_SCALEARM) && !same(AXIS_Y, WAS_SCALEARM)
        && !same(AXIS_Z, WAS_SCALEARM));
    assert(!same(ACTIVE, WAS_ROLLOVER) && !same(ACTIVE, WAS_SELECTED));
}

unittest { // Move bank: three arms, a centre, three plane rings
    auto m = new MoveHandler(Vec3(0, 0, 0));

    // The arms. Note the discriminating half: X was already right, so only
    // Y and Z prove anything about the correction — and Z is the one that
    // was furthest off, a dark pure blue where it should be a light one.
    assert(same(m.arrowX.color, AXIS_X), "move X arm");
    assert(same(m.arrowY.color, AXIS_Y), "move Y arm — must not be the old bright green");
    assert(same(m.arrowZ.color, AXIS_Z), "move Z arm — must not be the old dark blue");
    assert(!same(m.arrowY.color, WAS_AXIS_Y));
    assert(!same(m.arrowZ.color, WAS_AXIS_Z));

    // The centre handle belongs to no axis, so it takes the axis-less entry.
    assert(same(m.centerBox.color, HANDLE), "move centre handle");
    assert(!same(m.centerBox.color, WAS_CENTRE));

    // The plane rings, and THE ROUTING CLAIM THIS FILE EXISTS FOR: each ring
    // is coloured by the axis NORMAL to its plane, not by an axis lying in
    // it. XY's normal is Z, YZ's is X, XZ's is Y. Get this pairing wrong and
    // every value is still a legal scheme colour.
    assert(same(m.circleXY.color, AXIS_Z), "XY plane ring is coloured by its normal, Z");
    assert(same(m.circleYZ.color, AXIS_X), "YZ plane ring is coloured by its normal, X");
    assert(same(m.circleXZ.color, AXIS_Y), "XZ plane ring is coloured by its normal, Y");

    // ...and each ring's fill is derived from ITS OWN outline, so a corrected
    // axis can never leave its plane fill behind (the drift that put six
    // hand-darkened literals out of step with three axis literals).
    assert(same(m.circleXY.fillColor, planeFillColor(AXIS_Z)));
    assert(same(m.circleYZ.fillColor, planeFillColor(AXIS_X)));
    assert(same(m.circleXZ.fillColor, planeFillColor(AXIS_Y)));
    // Derived, and strictly darker — a fill equal to its outline would erase
    // the two-part construction while passing every equality above.
    static assert(kPlaneFillScale > 0.0f && kPlaneFillScale < 1.0f);
    assert(!same(m.circleXY.fillColor, m.circleXY.color));
}

unittest { // Rotate bank: three axis arcs and the axis-less view ring
    auto r = new RotateHandler(Vec3(0, 0, 0));

    assert(same(r.arcX.color, AXIS_X), "rotate X ring");
    assert(same(r.arcY.color, AXIS_Y), "rotate Y ring");
    assert(same(r.arcZ.color, AXIS_Z), "rotate Z ring");
    assert(!same(r.arcY.color, WAS_AXIS_Y));
    assert(!same(r.arcZ.color, WAS_AXIS_Z));

    // The screen-plane ring belongs to no axis and must not be mistakable for
    // one. It was already correct before this task — the single hand-picked
    // constant that turned out right — so this pin is here to keep it that way
    // while everything around it moved.
    assert(same(r.arcView.color, VIEW_RING), "view ring stays flat grey");
    assert(!same(r.arcView.color, AXIS_X) && !same(r.arcView.color, AXIS_Y)
        && !same(r.arcView.color, AXIS_Z));
}

unittest { // Scale bank: arms, the scale-feedback arrows, plane rings
    auto s = new ScaleHandler(Vec3(0, 0, 0));

    assert(same(s.arrowX.color, AXIS_X), "scale X arm");
    assert(same(s.arrowY.color, AXIS_Y), "scale Y arm");
    assert(same(s.arrowZ.color, AXIS_Z), "scale Z arm");

    // The feedback arrows wear their OWN axis colour. All three were the same
    // hand-picked yellow, which threw away the one thing the arrow has to
    // communicate — which axis is being scaled. Note this also pins that they
    // are not all equal to each other, which a single shared constant would be.
    assert(same(s.scaleArrowX.color, AXIS_X), "scale-feedback X arrow");
    assert(same(s.scaleArrowY.color, AXIS_Y), "scale-feedback Y arrow");
    assert(same(s.scaleArrowZ.color, AXIS_Z), "scale-feedback Z arrow");
    assert(!same(s.scaleArrowX.color, WAS_SCALEARM));
    assert(!same(s.scaleArrowY.color, WAS_SCALEARM));
    assert(!same(s.scaleArrowZ.color, WAS_SCALEARM));
    assert(!same(s.scaleArrowX.color, s.scaleArrowY.color));

    // A feedback arrow matches the arm it grows out of.
    assert(same(s.scaleArrowX.color, s.arrowX.color));
    assert(same(s.scaleArrowY.color, s.arrowY.color));
    assert(same(s.scaleArrowZ.color, s.arrowZ.color));

    // Same normal-axis pairing as the move bank.
    assert(same(s.circleXY.color, AXIS_Z));
    assert(same(s.circleYZ.color, AXIS_X));
    assert(same(s.circleXZ.color, AXIS_Y));
}

unittest { // The common law, applied to the parts that obey it
    auto m = new MoveHandler(Vec3(0, 0, 0));
    auto r = new RotateHandler(Vec3(0, 0, 0));
    auto s = new ScaleHandler(Vec3(0, 0, 0));

    foreach (idle; [m.arrowX.color, m.arrowY.color, m.arrowZ.color,
                    m.centerBox.color, r.arcX.color, r.arcView.color,
                    s.arrowZ.color, s.scaleArrowY.color]) {
        // Idle keeps the part's own colour.
        assert(same(handleColor(idle, HandlePaint.idle), idle));
        // The pointer resting on the part, and a haul, take the active colour
        // REGARDLESS of the part's own colour — one active colour, not one per
        // axis, and the same one for both states. Every part in this list
        // agrees about hover and grab; the plane RING is the one that does not
        // (see the plane-ring unittest below).
        assert(same(handleColor(idle, HandlePaint.hover),   ACTIVE));
        assert(same(handleColor(idle, HandlePaint.grabbed), ACTIVE));
    }

    // The active colour is neither of the two colours it replaced.
    assert(!same(ACTIVE, WAS_ROLLOVER), "the hand-picked hover yellow is retired");
    assert(!same(ACTIVE, WAS_SELECTED), "the mesh-selection orange is not a handle colour");
}

unittest { // The plane ring — the one part that does NOT obey it
    auto m = new MoveHandler(Vec3(0, 0, 0));

    // Each plane circle's outline wears the colour of the axis NORMAL to its
    // plane, and that outline is the part whose hover and grab differ. Driven
    // off the constructed handlers so this cannot drift from the bank.
    foreach (ring; [m.circleXY.color, m.circleYZ.color, m.circleXZ.color]) {
        assert(same(planeRingColor(ring, HandlePaint.idle),    ring));
        assert(same(planeRingColor(ring, HandlePaint.hover),   ACTIVE));
        // ...and BACK to its own colour on the grab. The ring is the only cue
        // that says which plane this is, so the grab keeps it legible.
        assert(same(planeRingColor(ring, HandlePaint.grabbed), ring));
    }

    // The disc inside follows the common law, so the two parts of one handle
    // DISAGREE about a grab — which is the whole reason the law needs three
    // states and could not stay a bool.
    assert(same(handleColor(m.circleXY.fillColor, HandlePaint.grabbed), ACTIVE));
    assert(!same(planeRingColor(m.circleXY.color, HandlePaint.grabbed), ACTIVE));
}
