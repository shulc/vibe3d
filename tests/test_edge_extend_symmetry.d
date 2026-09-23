// Edge Extend under X symmetry (item 12; fixture cells `symmetry_*`,
// `no_symmetry_haul_control`, `on_plane_vertex_no_symmetry_control` of
// tests/fixtures/edge_extend_gesture_laws.json).
//
// The measured law: NO mirrored copy is created; an element whose SOURCE
// vertex has x > 0 receives (-ox, oy, oz), x < 0 receives o, and x == 0
// exactly receives (0, oy, oz) — it stays on the plane. The offset channel
// itself is not reflected.
//
// Every expected position is taken from a CONTROL run of the same gesture
// with symmetry off, earlier in this file, so no needle compares a channel
// with itself and no literal encodes our own pixel scale:
//   (k1) haul control, (k2) X-arm control, (k3) on-plane-rig control.
// Then symmetry is switched on — always AFTER the selection, because a
// selection made with symmetry on is itself mirrored and would turn every
// one-sided cell into a two-sided one.
//
// Order is the evidence order (controls and the side the law leaves alone
// first, the red line after them):
//   (k1) (k2) (k3)  green on HEAD and after the fix
//   (b)  (b')       -X ridge: the law gives o, which is what HEAD does
//   (a)             +X ridge, haul — RED on HEAD at "extend ignored symmetry"
//   (a') (c) (d)    below the red line: they run only once (a) is green
//
// The 12-vertex count in (a) is a FLOOR, not a mutation witness: there is no
// copying code to break.
//
// The press side (C2-sym-sel, `S-both M-press`): the sign of the reflection is
// chosen by the side of the ACTIVATING press. Every symmetry cell above
// therefore puts the press that starts the run on the -X side (the branch the
// cells were captured on) and pins it with a floor on `pressAnchor`; the arm
// cells start their run with a motionless click there and only then take the
// arm (an arm press continues the run and keeps the side). Below (d): (e) and
// (e-m) select by a real symmetric click in the front camera and press on the
// +X / -X side (outward / inward), (g) presses +X on the top rig.

import edge_extend_gesture_helpers;
import std.algorithm : sort;
import std.conv : to;
import std.format : format;
import std.math : abs;

void main() {}

enum int[2][] kPlusRidge  = [[6, 7], [7, 8]];
enum int[2][] kMinusRidge = [[0, 1], [1, 2]];
enum int[2][] kOnPlane    = [[5, 8]];          // (0,1,0)-(1,1,0)

/// Empty space on the -X side of the top rig (below the edge-on plane row).
Px negPx() { return topScreen(-0.3, 0.5); }

__gshared double[] ctlHaul;   // offsetX after each of 10 haul increments, no symmetry
__gshared double[] ctlArm;    // offsetX after each of 10 X-arm increments, no symmetry
__gshared double   ctlPlaneX, ctlPlaneZ;
__gshared Offset   ctlFront;  // front rig: haul (+4,+4) x 10, no symmetry

/// Haul (+4,0) x 10 on empty space; returns offsetX per increment. A
/// symmetry cell (`cell` non-null) presses on the -X side and pins it.
double[] haulX10(string cell = null) {
    auto tr = haul(cell is null ? haulPx() : negPx(), kIncrementPx, 0, 10);
    if (cell !is null)
        assert(pressAnchor()[0] < -0.05, cell ~ ": activating press not on the -X side (rig): "
            ~ pressAnchor().to!string);
    double[] xs;
    foreach (o; tr) xs ~= o.x;
    return xs;
}

/// A motionless click on the -X side starts the run, then X arm (+4,+4) x 10;
/// returns offsetX per increment. `cell` non-null pins the click's side.
double[] armX10(string what, string cell = null) {
    click(negPx());
    if (cell !is null)
        assert(pressAnchor()[0] < -0.05, cell ~ ": activating press not on the -X side (rig): "
            ~ pressAnchor().to!string);
    Px p = pressArm(kArmPressPx, 0, 0, what);
    Px end;
    auto tr = increments(p, kIncrementPx, kIncrementPx, 10, end);
    release(end);
    double[] xs;
    foreach (o; tr) xs ~= o.x;
    return xs;
}

double[3][] sortedByX(double[3][] vs) {
    auto c = vs.dup;
    c.sort!((a, b) => a[0] < b[0]);
    return c;
}

void assertAllX(double[3][] nv, double want, size_t n, string msg) {
    assert(nv.length == n, format("%s: %d new vertices, expected %d", msg, nv.length, n));
    foreach (v; nv)
        assert(abs(v[0] - want) <= 1e-4, format("%s: new vertex %s, expected x = %s", msg, v, want));
}

unittest { // (k1) haul control, no symmetry
    armRig(kPlusRidge, 1.0);
    ctlHaul = haulX10();
    assert(ctlHaul.length == 10 && ctlHaul[9] > 0, "symmetry control: haul did not extend " ~ ctlHaul.to!string);
    assert(vertexCount() == 12, "symmetry control: haul did not extend (" ~ vertexCount().to!string ~ " vertices)");
    assertAllX(newVertices(), 1 + ctlHaul[9], 3, "symmetry control: haul did not extend");
    cmd("tool.set edge.extend off");
}

unittest { // (k2) X-arm control, no symmetry
    armRig(kPlusRidge, 1.0);
    ctlArm = armX10("symmetry control: x arm press did not grab the arm");
    assert(ctlArm.length == 10 && ctlArm[9] > 0, "symmetry control: arm did not extend " ~ ctlArm.to!string);
    assertAllX(newVertices(), 1 + ctlArm[9], 3, "symmetry control: arm did not extend");
    cmd("tool.set edge.extend off");
}

unittest { // (k3) on-plane rig, no symmetry: diagonal haul on empty space
    armRig(kOnPlane, 0.5);
    auto tr = haul(haulPx(), kIncrementPx, kIncrementPx, 10);
    assert(tr.length == 10 && tr[9].x > 0 && tr[9].z != 0,
        "symmetry control: on-plane rig did not extend " ~ tr.to!string);
    ctlPlaneX = tr[9].x; ctlPlaneZ = tr[9].z;
    assert(vertexCount() == 11 && faceCount() == 5,
        format("symmetry control: on-plane rig did not extend (%d v / %d f)", vertexCount(), faceCount()));
    auto nv = sortedByX(newVertices());
    assert(nv.length == 2
        && abs(nv[0][0] - ctlPlaneX) <= 1e-4 && abs(nv[0][1] - 1) <= 1e-4 && abs(nv[0][2] - ctlPlaneZ) <= 1e-4
        && abs(nv[1][0] - (1 + ctlPlaneX)) <= 1e-4,
        format("symmetry control: on-plane rig did not extend: %s, o = (%s, 0, %s)", nv, ctlPlaneX, ctlPlaneZ));
    cmd("tool.set edge.extend off");
}

unittest { // (b) -X ridge, haul, symmetry on — the law gives +o here
    armRig(kMinusRidge, -1.0, true);
    haulX10("(b)");
    assert(vertexCount() == 12, "extend moved the negative side the wrong way: "
        ~ vertexCount().to!string ~ " vertices, expected 12");
    assertAllX(newVertices(), -1 + ctlHaul[9], 3, "extend moved the negative side the wrong way");
    cmd("tool.set edge.extend off");
}

unittest { // (b') -X ridge, X arm, symmetry on
    armRig(kMinusRidge, -1.0, true);
    armX10("extend moved the negative side the wrong way (arm): x arm press did not grab the arm", "(b')");
    assert(vertexCount() == 12, "extend moved the negative side the wrong way (arm): "
        ~ vertexCount().to!string ~ " vertices, expected 12");
    assertAllX(newVertices(), -1 + ctlArm[9], 3, "extend moved the negative side the wrong way (arm)");
    cmd("tool.set edge.extend off");
}

/// (a)/(a') body: +X ridge under symmetry; `ctl` is the matching control trace.
void plusSideCell(double[] trace, double[] ctl, string sfx) {
    // Floor: one ring, no mirrored copy.
    assert(vertexCount() == 12,
        "extend under symmetry created mirrored copies" ~ sfx ~ ": " ~ vertexCount().to!string ~ " vertices");
    // Needle: the x > 0 source receives -ox; the channel itself stays positive.
    immutable double ox = offset().x;
    assert(ox > 0, "extend ignored symmetry" ~ sfx ~ ": offset channel reflected, offsetX " ~ ox.to!string);
    assertAllX(newVertices(), 1 - ctl[9], 3, "extend ignored symmetry" ~ sfx);
    // Increment by increment the channel equals the no-symmetry control.
    assert(trace.length == 10, "symmetry trace read " ~ trace.length.to!string ~ " states" ~ sfx);
    foreach (i; 0 .. 10)
        assert(abs(trace[i] - ctl[i]) <= 1e-5,
            format("symmetry drag offset differs from the no-symmetry control%s: increment %d %s vs %s",
                   sfx, i + 1, trace[i], ctl[i]));
    // The COMMITTED mesh, after the drop, not the preview.
    cmd("tool.set edge.extend off");
    settle(250);
    assert(vertexCount() == 12, "extend ignored symmetry (committed)" ~ sfx ~ ": vertex count");
    assertAllX(newVertices(), 1 - ctl[9], 3, "extend ignored symmetry (committed)" ~ sfx);
}

unittest { // (a) +X ridge, haul — the red line on HEAD
    armRig(kPlusRidge, 1.0, true);
    auto tr = haulX10("(a)");
    plusSideCell(tr, ctlHaul, "");
}

unittest { // (a') +X ridge, X arm
    armRig(kPlusRidge, 1.0, true);
    auto tr = armX10("extend ignored symmetry (arm): x arm press did not grab the arm", "(a')");
    plusSideCell(tr, ctlArm, " (arm)");
}

unittest { // (c) both ridges
    armRig(kPlusRidge ~ kMinusRidge, 0.0, true);
    haulX10("(c)");
    assert(vertexCount() == 15, "extend under symmetry: both sides: " ~ vertexCount().to!string ~ " vertices");
    auto nv = sortedByX(newVertices());
    assert(nv.length == 6, "extend under symmetry: both sides: " ~ nv.length.to!string ~ " new vertices");
    foreach (i, v; nv)
        assert(abs(v[0] - (i < 3 ? -1 : 1) * (1 - ctlHaul[9])) <= 1e-4,
            format("extend under symmetry: both sides: %s, expected x = +-%s", nv, 1 - ctlHaul[9]));
    cmd("tool.set edge.extend off");
}

unittest { // (d) on-plane vertex: its X offset is zeroed
    armRig(kOnPlane, 0.5, true);
    haul(negPx(), kIncrementPx, kIncrementPx, 10);
    assert(pressAnchor()[0] < -0.05, "(d): activating press not on the -X side (rig): " ~ pressAnchor().to!string);
    assert(vertexCount() == 11 && faceCount() == 5,
        format("on-plane floor: counts (%d v / %d f), expected (11, 5)", vertexCount(), faceCount()));
    auto nv = sortedByX(newVertices());
    assert(nv.length == 2
        && abs(nv[0][0]) <= 1e-6 && abs(nv[0][2] - ctlPlaneZ) <= 1e-4
        && abs(nv[1][0] - (1 - ctlPlaneX)) <= 1e-4,
        format("on-plane vertex offset not zeroed: %s, control o = (%s, 0, %s)", nv, ctlPlaneX, ctlPlaneZ));
    assert(abs(nv[1][2] - ctlPlaneZ) <= 1e-4,
        format("on-plane vertex offset not zeroed (z of the (1,1,0) ring vertex): %s, control o_z %s", nv[1], ctlPlaneZ));
    cmd("tool.set edge.extend off");
}

// --- the press side (C2-sym-sel, front camera) ------------------------------

/// Front control: the capture's haul, no symmetry.
void frontControl() {
    rigNoArm([[7, 8]], true, 0.25, 0.55);
    keyArm();
    frontHaul(0.5, 1.35, kIncrementPx, kIncrementPx, 10);
    ctlFront = offset();
    assert(ctlFront.x > 0.05, "front control: the haul did not move: " ~ ctlFront.to!string);
    cmd("tool.set edge.extend off");
}

/// (e)/(e-m): the symmetric click selects both edges, the haul presses at `px`.
void pressSideCell(double px, bool outward, string msg) {
    frontControl();
    immutable double want = outward ? 1 + ctlFront.x : 1 - ctlFront.x;
    symSelRig();
    keyArm();
    frontHaul(px, 1.35, kIncrementPx, kIncrementPx, 10);
    assert(px > 0 ? pressAnchor()[0] > 0.05 : pressAnchor()[0] < -0.05,
        msg ~ ": the press was not on its side (rig): " ~ pressAnchor().to!string);
    assert(vertexCount() == 13, msg ~ ": " ~ vertexCount().to!string ~ " v, expected 13");
    auto nv = newVertices();
    size_t plus = 0, minus = 0;
    foreach (v; nv) {
        if (abs(v[0] - want) <= 1e-4) ++plus;
        else if (abs(v[0] + want) <= 1e-4) ++minus;
    }
    assert(plus == 2 && minus == 2, format("%s: new vertices %s, expected x = +-%s", msg, nv, want));
    cmd("tool.set edge.extend off");
}

unittest { // (e) C2-sym-sel: +X press, outward
    pressSideCell(0.5, true, "extend under symmetry ignored the press side (+X press, outward)");
}

unittest { // (e-m) C2-sym-sel-m: -X press, inward
    pressSideCell(-0.5, false, "extend under symmetry ignored the press side (-X press, inward)");
}

unittest { // (g) +X press on the top rig (+X ridge, symmetry after the selection)
    armRig(kPlusRidge, 1.0, true);
    auto tr = haul(haulPx(), kIncrementPx, 0, 10);
    assert(pressAnchor()[0] > 0.05, "(g): activating press not on the +X side (rig): " ~ pressAnchor().to!string);
    assert(vertexCount() == 12, "(g): " ~ vertexCount().to!string ~ " v, expected 12");
    assertAllX(newVertices(), 1 + ctlHaul[9], 3, "extend under symmetry: +X press still reflected the +X side");
    cmd("tool.set edge.extend off");
}
