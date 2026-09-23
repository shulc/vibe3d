// Edge Extend — the first press after the tool's key (item 17; fixture cells
// `first_activation_by_key_*`, `first_press_after_typed_offset_*` of
// tests/fixtures/edge_extend_gesture_laws.json; gaps 217/220).
//
// The measured law: the tool's key arms Edge Extend without a handle; a value
// typed into the panel before the first press only sets the attribute; the
// first press - moving or not - discards it, writes offset 0 on all components
// and starts a zero-length ring; the first increment is proportional.
//
// Rig: ONE edge (7,8) of the plane, no symmetry, top orthographic camera, edge
// mode, selected by command; (S) is the capture's symmetric-click rig in the
// front camera. The handle is looked for in PIXELS (/api/viewport/probe) —
// GET /api/tool/handles is always null for Edge Extend, so it cannot say
// whether a handle is drawn.
//
// On HEAD the first red is (h0) "Edge Extend drew its handle before the first
// press": HEAD draws the gizmo the moment the key arms the tool.

import edge_extend_gesture_helpers;
import std.algorithm : sort;
import std.conv : to;
import std.format : format;
import std.math : abs;

void main() {}

enum int[2][] kEdge = [[7, 8]];

void freshRig() { rigNoArm(kEdge, false, 1.0); }

bool sameColour(int[3] a, int[3] b) {
    foreach (i; 0 .. 3) if (abs(a[i] - b[i]) > 8) return false;
    return true;
}

/// The two new vertices coincide with the edge's own ends (1,0,0), (1,1,0).
bool zeroLengthRing() {
    auto nv = newVertices();
    if (nv.length != 2) return false;
    nv.sort!((a, b) => a[1] < b[1]);
    return abs(nv[0][0] - 1) <= 1e-6 && abs(nv[0][1]) <= 1e-6 && abs(nv[0][2]) <= 1e-6
        && abs(nv[1][0] - 1) <= 1e-6 && abs(nv[1][1] - 1) <= 1e-6 && abs(nv[1][2]) <= 1e-6;
}

bool zeroOffset() {
    auto o = offset();
    return abs(o.x) <= 1e-9 && abs(o.y) <= 1e-9 && abs(o.z) <= 1e-9;
}

unittest { // (h0) no handle before the first press — the red line on HEAD
    freshRig();
    immutable Px px0 = zArmPx();
    immutable int[3] bg = probe(px0);
    keyArm();
    immutable Px px1 = zArmPx();
    assert(abs(px1.x - px0.x) <= 1 && abs(px1.y - px0.y) <= 1,
        format("rig: the handle pixel moved with the key (bg sampled another pixel): %s -> %s", px0, px1));
    assert(!runStarted() && !built(), "rig: the key started the run: " ~ toolState().toString);
    immutable int[3] now = probe(px0);
    assert(sameColour(now, bg), format("Edge Extend drew its handle before the first press (reference: none "
        ~ "until the first press, gap 217): pixel %s was %s, now %s", px0, bg, now));
    cmd("tool.set edge.extend off");
}

unittest { // (C) the first motionless click: offset 0, a zero-length ring
    freshRig();
    immutable int[3] bg = probe(zArmPx());
    keyArm();
    auto before = model();
    immutable long h = undoLen();
    click(clickPx());
    assert(zeroOffset(), "first motionless click wrote a non-zero offset: " ~ offset().to!string);
    auto after = model();
    foreach (i; 0 .. 9) {
        auto a = vtx(before, i), b = vtx(after, i);
        assert(abs(a[0] - b[0]) <= 1e-6 && abs(a[1] - b[1]) <= 1e-6 && abs(a[2] - b[2]) <= 1e-6,
            format("first motionless click moved the mesh: vertex %d %s -> %s", i, a, b));
    }
    assert(vertexCount() == 11 && faceCount() == 5 && zeroLengthRing(),
        format("first press did not start the run with a zero-length ring (reference: coincident ring "
             ~ "vertices, gap 217): %d v / %d f, new %s", vertexCount(), faceCount(), newVertices()));
    assert(undoLen() == h, "first press wrote a history record");
    // The control that must flip against (h0): after the press the probe
    // does see the handle, at the re-read gizmo pixel.
    immutable int[3] now = probe(zArmPx());
    assert(!sameColour(now, bg), format("instrument: the probe cannot see the Edge Extend handle after the "
        ~ "first press: %s vs background %s", now, bg));
    cmd("tool.set edge.extend off");
}

unittest { // (hp) a press exactly on the hidden handle's centre is off-handle
    freshRig();
    keyArm();
    Px g = gizmoPx();
    press(g);
    assert(moveOffGizmo() && grabbedAxis() == 3, format("first press after the key grabbed a hidden handle "
        ~ "(reference: no handle before the first press): moveOffGizmo %s, dragAxis %d", moveOffGizmo(), grabbedAxis()));
    release(g);
    cmd("tool.set edge.extend off");
}

/// Key, then Offset X (and Y) typed into the panel.
void typedRig(bool alsoY) {
    freshRig();
    keyArm();
    typePanel("tool.attr edge.extend offsetX 0.3");
    if (alsoY) typePanel("tool.attr edge.extend offsetY 0.2");
    auto o = offset();
    assert(abs(o.x - 0.3) <= 1e-6 && (!alsoY || abs(o.y - 0.2) <= 1e-6),
        "rig: the typed offset did not land: " ~ o.to!string);
}

unittest { // (Z) P-noapply + T-zero (first_press_after_typed_offset_motionless_click)
    typedRig(true);
    assert(vertexCount() == 9 && !built(), format("a value typed before the first press applied the operation "
        ~ "(reference: the attribute only, 9 v, gap 220): %d v, built %s", vertexCount(), built()));
    click(clickPx());
    assert(zeroOffset(), "first press did not discard the typed offset (reference writes 0 on all three "
        ~ "components, gap 220): " ~ offset().to!string);
    assert(vertexCount() == 11 && faceCount() == 5 && zeroLengthRing(),
        format("first press after a typed offset did not start a zero-length ring (gap 220): %d v / %d f, new %s",
               vertexCount(), faceCount(), newVertices()));
    cmd("tool.set edge.extend off");
}

unittest { // (Zd) J-zero (first_press_after_typed_offset_drag)
    typedRig(false);
    Px p = haulPx();
    press(p);
    Px end;
    auto tr = increments(p, kIncrementPx, kIncrementPx, 10, end);
    release(end);
    assert(tr.length == 10, "typed-offset drag: read " ~ tr.length.to!string ~ " states");
    assert(tr[0].x < 0.1, format("first drag after a typed offset started from the typed value (reference "
        ~ "starts at 0: k1 0.01, gap 220): o_1 %s", tr[0]));
    cmd("tool.set edge.extend off");
}

unittest { // (J) the first increment after the key is proportional
    freshRig();
    keyArm();
    Px p = haulPx();
    press(p);
    Offset[] tr;
    size_t[] counts;
    foreach (i; 0 .. 10) {
        p = Px(p.x + kIncrementPx, p.y + kIncrementPx);
        motion(p, kIncrementPx, kIncrementPx);
        tr ~= offset();
        counts ~= vertexCount();
    }
    release(p);
    assert(tr.length == 10, "first drag: read " ~ tr.length.to!string ~ " states");
    double len(Offset o) { import std.math : sqrt; return sqrt(o.x * o.x + o.y * o.y + o.z * o.z); }
    assert(len(tr[9]) > 0, "first drag did not move: " ~ tr.to!string);
    double[] d;
    Offset prev = Offset(0, 0, 0);
    foreach (o; tr) { d ~= len(Offset(o.x - prev.x, o.y - prev.y, o.z - prev.z)); prev = o; }
    auto rest = d[1 .. $].dup;
    rest.sort();
    immutable double median = rest[4];
    assert(d[0] > 0 && d[0] <= 1.5 * median, format("first increment after key activation jumped (reference: "
        ~ "proportional, gap 217): d %s", d));
    foreach (i, c; counts)
        assert(c == 11, format("the first drag started more than one ring: %d v at increment %d", c, i + 1));
    cmd("tool.set edge.extend off");
}

unittest { // (S) under symmetry the first press starts a zero-length ring on both sides
    symSelRig();
    keyArm();
    Px p = frontScreen(0.5, 1.35);
    press(p);
    assert(pressAnchor()[0] > 0.05, "rig: the first press was not on the +X side: " ~ pressAnchor().to!string);
    release(p);
    auto nv = newVertices();
    size_t hits = 0;
    foreach (v; nv)
        if (abs(abs(v[0]) - 1) <= 1e-6 && (abs(v[1]) <= 1e-6 || abs(v[1] - 1) <= 1e-6) && abs(v[2]) <= 1e-6) ++hits;
    assert(vertexCount() == 13 && faceCount() == 6 && hits == 4,
        format("first press under symmetry did not start a zero-length ring on both sides (gap 217): %d v / %d f, new %s",
               vertexCount(), faceCount(), nv));
    cmd("tool.set edge.extend off");
}
