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

import edge_extend_gesture_helpers;
import std.algorithm : sort;
import std.conv : to;
import std.format : format;
import std.math : abs;

void main() {}

enum int[2][] kPlusRidge  = [[6, 7], [7, 8]];
enum int[2][] kMinusRidge = [[0, 1], [1, 2]];
enum int[2][] kOnPlane    = [[5, 8]];          // (0,1,0)-(1,1,0)

__gshared double[] ctlHaul;   // offsetX after each of 10 haul increments, no symmetry
__gshared double[] ctlArm;    // offsetX after each of 10 X-arm increments, no symmetry
__gshared double   ctlPlaneX, ctlPlaneZ;

/// Haul (+4,0) x 10 on empty space; returns offsetX per increment.
double[] haulX10() {
    auto tr = haul(haulPx(), kIncrementPx, 0, 10);
    double[] xs;
    foreach (o; tr) xs ~= o.x;
    return xs;
}

/// Engage, then X arm (+4,+4) x 10; returns offsetX per increment.
double[] armX10(string what) {
    engage();
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
    haulX10();
    assert(vertexCount() == 12, "extend moved the negative side the wrong way: "
        ~ vertexCount().to!string ~ " vertices, expected 12");
    assertAllX(newVertices(), -1 + ctlHaul[9], 3, "extend moved the negative side the wrong way");
    cmd("tool.set edge.extend off");
}

unittest { // (b') -X ridge, X arm, symmetry on
    armRig(kMinusRidge, -1.0, true);
    armX10("extend moved the negative side the wrong way (arm): x arm press did not grab the arm");
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
    auto tr = haulX10();
    plusSideCell(tr, ctlHaul, "");
}

unittest { // (a') +X ridge, X arm
    armRig(kPlusRidge, 1.0, true);
    auto tr = armX10("extend ignored symmetry (arm): x arm press did not grab the arm");
    plusSideCell(tr, ctlArm, " (arm)");
}

unittest { // (c) both ridges
    armRig(kPlusRidge ~ kMinusRidge, 0.0, true);
    haulX10();
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
    haul(haulPx(), kIncrementPx, kIncrementPx, 10);
    assert(vertexCount() == 11 && faceCount() == 5,
        format("on-plane floor: counts (%d v / %d f), expected (11, 5)", vertexCount(), faceCount()));
    auto nv = sortedByX(newVertices());
    assert(nv.length == 2
        && abs(nv[0][0]) <= 1e-6 && abs(nv[0][2] - ctlPlaneZ) <= 1e-4
        && abs(nv[1][0] - (1 - ctlPlaneX)) <= 1e-4,
        format("on-plane vertex offset not zeroed: %s, control o = (%s, 0, %s)", nv, ctlPlaneX, ctlPlaneZ));
    cmd("tool.set edge.extend off");
}
