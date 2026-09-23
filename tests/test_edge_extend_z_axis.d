// Edge Extend — a Z-arm drag writes ONLY its own offset component, from the
// first increment on, with no jump (item 17; fixture cells
// `axis_arm_drag_world` and `axis_arm_drag_selection_axis` of
// tests/fixtures/edge_extend_gesture_laws.json).
//
// The drag is DIAGONAL on purpose. In this top view a vertical drag cannot
// tell the arm from the screen-plane haul — both write the Z channel only —
// so the diagonal's horizontal half is what separates them: the arm leaves X
// untouched, the haul moves it. The press floor (`dragAxis`) says which of
// the two actually began before the trace is read.
//
// Block B arms the selection-axis stage. There the arm that points along
// world Z is the Move bank's SECOND handler axis, not its third (measured:
// the selection frame of this ridge puts world Z in the handler's Y slot), so
// its floor names axis 1; the trace law is the same.
//
// Block C: a motionless click on empty space first, then the Z arm drawn
// after it — the arm is grabbable and the click leaves no zero-length ring
// of its own (C2-z', gap 214).
//
// Status on the HEAD this file was written against: GREEN in all blocks —
// the jump does not reproduce on this rig (recorded in the task card as the
// "not reproduced" outcome). The file stays as the regression witness.

import edge_extend_gesture_helpers;
import std.algorithm : sort;
import std.conv : to;
import std.format : format;
import std.math : abs;

void main() {}

enum int[2][] kPlusRidge = [[6, 7], [7, 8]];

void zArmCell(string axisMode, int expectAxis, string sfx, string floorMsg) {
    armRig(kPlusRidge, 1.0, false, axisMode);
    engage();
    immutable Offset o0 = offset();

    Px p = pressArm(0, kArmPressPx, expectAxis, floorMsg);
    Px end;
    auto tr = increments(p, kIncrementPx, -kIncrementPx, 10, end);
    release(end);

    // Floor: ten increments were read.
    assert(tr.length == 10, "z arm: read " ~ tr.length.to!string ~ " states, expected 10" ~ sfx);

    double[] d;
    double prev = o0.z;
    foreach (i, o; tr) {
        assert(abs(o.x - o0.x) <= 1e-6 && abs(o.y - o0.y) <= 1e-6,
            format("extend jumped on the first increment%s: increment %d wrote X/Y "
                 ~ "(%s -> %s) on a Z-arm drag", sfx, i + 1, o0, o));
        d ~= o.z - prev;
        prev = o.z;
    }
    // Strictly monotone Z, and the first step no larger than the typical one.
    foreach (i, s; d)
        assert(s != 0 && (s < 0) == (d[0] < 0),
            format("extend jumped on the first increment%s: Z not monotone at %d, steps %s", sfx, i + 1, d));
    auto mags = new double[d.length];
    foreach (i, s; d) mags[i] = abs(s);
    auto sorted = mags.dup; sorted.sort();
    immutable double median = (sorted[4] + sorted[5]) / 2;
    assert(mags[0] <= 1.5 * median,
        format("extend jumped on the first increment%s: |d1| = %s, median %s, steps %s",
               sfx, mags[0], median, d));

    // The released ring: x stays on the ridge, z is the offset channel.
    auto nv = newVertices();
    assert(nv.length == 3, "z arm: expected 3 new vertices, got " ~ nv.length.to!string ~ sfx);
    foreach (v; nv)
        assert(abs(v[0] - 1.0) <= 1e-5 && abs(v[2] - tr[$ - 1].z) <= 1e-5,
            format("z arm ring off the Z channel%s: %s, offsetZ %s", sfx, v, tr[$ - 1].z));
    cmd("tool.set edge.extend off");
}

unittest { // (A) world axis
    zArmCell(null, 2, "", "z arm press did not grab the arm");
}

unittest { // (B) selection axis stage armed
    zArmCell("select", 1, " (selection axis)",
             "z arm press did not grab the arm (selection axis: world Z is Move-bank axis 1)");
}

unittest { // (C) the Z arm after a motionless click (arm_press_after_motionless_click_no_read)
    armRig(kPlusRidge, 1.0);
    Px c = clickPx();
    click(c);
    Px p = pressArm(0, kArmPressPx, 2, "z arm after a motionless click was not grabbable");
    Px end;
    auto tr = increments(p, kIncrementPx, -kIncrementPx, 10, end);
    release(end);
    assert(tr.length == 10, "z arm after a click: read " ~ tr.length.to!string ~ " states");
    foreach (i, o; tr)
        assert(abs(o.x) <= 1e-6 && abs(o.y) <= 1e-6,
            format("arm after a motionless click wrote off-arm channels: increment %d %s", i + 1, o));
    auto nv = newVertices();
    bool coincident = false;
    foreach (i; 0 .. nv.length)
        foreach (j; i + 1 .. nv.length)
            if (abs(nv[i][0] - nv[j][0]) <= 1e-6 && abs(nv[i][1] - nv[j][1]) <= 1e-6
                && abs(nv[i][2] - nv[j][2]) <= 1e-6) coincident = true;
    assert(vertexCount() == 12 && !coincident,
        format("motionless click left a zero-length ring: %d v, new %s", vertexCount(), nv));
    cmd("tool.set edge.extend off");
}
