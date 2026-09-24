// Task 7139 (gap 187, gap 219): an orthographic preset view turns with a
// pinned work plane, the camera focus stays WORLD, and a plane change moves
// the focus of a whole LINK GROUP only when every member is orthographic.
// Law: doc/measured_laws.md §23 (C4-oa/oc/of: the local focus NUMBERS are
// kept) and the C4-quad capture (Quad: the three ortho cells are one link
// group, the perspective cell is its own). No GL: `applyLayout` skips GPU
// init under unittest.
//
// Order is load-bearing: druntime stops a module at its first red. L9 (the
// group without any plane) is the floor of L7/L8 — a Quad whose ortho cells
// still follow the perspective cell reddens L9 first, by name.
module tests.unit.viewport_plane_turn_test;

import viewport;
import view : View, ProjKind, ViewPreset;
import math : Vec3, Viewport;
import toolpipe.packets : WorkplanePacket;
import toolpipe.stages.workplane : WorkplaneStage;
import std.math : abs;
import std.format : format;

private enum Vec3 kPan = Vec3(0.3f, 0.0f, 0.0f);

/// The oblique pinned plane of the witness: rotX 30, rotY 40 so no axis is a
/// world axis, off-origin. Built by the production stage (its own Euler law),
/// never re-derived here.
private WorkplanePacket obliquePlane() {
    auto st = new WorkplaneStage();
    st.edit(0.4f, -0.3f, 0.7f, 30.0f, 40.0f, 0.0f);
    auto p = st.currentState();
    assert(!p.isAuto, "rig: the typed plane is not pinned");
    assert(abs(p.axis1.x) < 0.99f && abs(p.normal.y) < 0.99f
        && abs(p.axis2.z) < 0.99f, "rig: the plane shares an axis with the world");
    return p;
}

private Vec3 toWorld(in WorkplanePacket p, Vec3 l) {
    return p.center + p.axis1 * l.x + p.normal * l.y + p.axis2 * l.z;
}

private bool near(Vec3 a, Vec3 b, float tol) {
    return abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol && abs(a.z - b.z) <= tol;
}

private bool sameMat(in float[16] a, in float[16] b, float tol) {
    foreach (i; 0 .. 16) if (abs(a[i] - b[i]) > tol) return false;
    return true;
}

private string s(Vec3 v) { return format("(%.6f, %.6f, %.6f)", v.x, v.y, v.z); }

private ViewportManager quad() {
    auto m = new ViewportManager(0, 0, 800, 600);
    m.applyLayout(LayoutPreset.Quad);
    assert(m.cellCount == 4, format("Quad population: %d cells, expected 4", m.cellCount));
    return m;
}

unittest { // L9 — the Quad link groups, no plane involved
    auto m = quad();
    Vec3[4] before;
    foreach (k; 0 .. 4) before[k] = m.resolvedSnapshot(k).focus;
    m.focusOwnerCamera(0).focus += kPan;
    foreach (k; 0 .. 3)
        assert(near(m.resolvedSnapshot(k).focus, before[k] + kPan, 1e-6f)
            && near(m.resolvedSnapshot(3).focus, before[3], 1e-6f),
            format("ortho cells are not one link group or the perspective cell "
                 ~ "follows them (gap 219): cell %d %s -> %s, cell 3 %s -> %s",
                   k, s(before[k]), s(m.resolvedSnapshot(k).focus),
                   s(before[3]), s(m.resolvedSnapshot(3).focus)));
}

unittest { // L7 (+L2) — an all-orthographic group keeps its local numbers
    auto m = quad();
    m.views[3].camera.focus = Vec3(-0.2f, 0.1f, 0.4f);
    m.focusOwnerCamera(0).focus = Vec3(0.3f, 0.2f, -0.1f);
    immutable Vec3 f = m.resolvedSnapshot(0).focus;
    immutable Vec3 f3 = m.views[3].camera.focus;
    immutable float[16] v3 = m.resolvedSnapshot(3).view;
    m.views[0].camera.focus = Vec3(0.9f, -0.4f, 0.2f);   // followers' own (unread) foci
    m.views[2].camera.focus = Vec3(-0.6f, 0.5f, 0.8f);
    immutable Vec3 own0 = m.views[0].camera.focus, own2 = m.views[2].camera.focus;
    auto p = obliquePlane();
    m.applyPlaneFrame(WorkplanePacket.init, p, true);
    foreach (k; 0 .. 3)
        assert(near(m.resolvedSnapshot(k).focus, toWorld(p, f), 1e-5f),
            format("all-orthographic link group did not keep its plane-local focus "
                 ~ "numbers (gap 219): cell %d focus %s, expected O + B*%s = %s",
                   k, s(m.resolvedSnapshot(k).focus), s(f), s(toWorld(p, f))));
    assert(near(m.views[3].camera.focus, f3, 1e-7f),
        format("a plane transition moved the perspective cell's focus: %s -> %s",
               s(f3), s(m.views[3].camera.focus)));
    assert(sameMat(m.resolvedSnapshot(3).view, v3, 1e-7f),
        "the perspective cell turned with the plane");
    assert(near(m.views[0].camera.focus, own0, 1e-7f) && near(m.views[2].camera.focus, own2, 1e-7f),
        format("the plane transition composed a follower's own focus (a group moves ONCE, "
             ~ "through its owner): cell 0 %s -> %s, cell 2 %s -> %s", s(own0),
               s(m.views[0].camera.focus), s(own2), s(m.views[2].camera.focus)));
}

unittest { // L8 — a group with a perspective member keeps its WORLD focus
    auto m = quad();
    applyCellViewPreset(m.views[2], ViewPreset.Perspective);
    m.focusOwnerCamera(0).focus = Vec3(0.3f, 0.2f, -0.1f);
    Vec3[3] before;
    foreach (k; 0 .. 3) before[k] = m.resolvedSnapshot(k).focus;
    m.applyPlaneFrame(WorkplanePacket.init, obliquePlane(), true);
    foreach (k; 0 .. 3)
        assert(near(m.resolvedSnapshot(k).focus, before[k], 1e-7f),
            format("a link group with a perspective member moved its world focus "
                 ~ "(gap 219): cell %d %s -> %s", k, s(before[k]),
                   s(m.resolvedSnapshot(k).focus)));
}

unittest { // L1 — every linked ortho preset cell turns; L5 — a non-preset one does not
    auto m = quad();
    auto p = obliquePlane();
    m.applyPlaneFrame(WorkplanePacket.init, p, true);
    // Top (cell 0): right = B*X, up = B*(-Z); Front (cell 1): right = B*X, up = B*Y.
    Viewport v0 = m.resolvedSnapshot(0), v1 = m.resolvedSnapshot(1);
    Vec3 r0 = Vec3(v0.view[0], v0.view[4], v0.view[8]);
    Vec3 u0 = Vec3(v0.view[1], v0.view[5], v0.view[9]);
    Vec3 r1 = Vec3(v1.view[0], v1.view[4], v1.view[8]);
    Vec3 u1 = Vec3(v1.view[1], v1.view[5], v1.view[9]);
    assert(near(r0, p.axis1, 1e-5f) && near(u0, p.axis2 * -1.0f, 1e-5f)
        && near(r1, p.axis1, 1e-5f) && near(u1, p.normal, 1e-5f),
        format("linked ortho follower did not turn: Top right %s up %s, Front right "
             ~ "%s up %s; plane X %s Y %s Z %s", s(r0), s(u0), s(r1), s(u1),
               s(p.axis1), s(p.normal), s(p.axis2)));

    // L5: an orthographic cell on the free (Camera) preset has no preset basis.
    auto c = m.views[3].camera;
    c.projKind = ProjKind.Ortho;
    c.viewPreset = ViewPreset.Camera;
    m.applyPlaneFrame(p, WorkplanePacket.init, false);
    immutable float[16] flat = m.resolvedSnapshot(3).view;
    m.applyPlaneFrame(WorkplanePacket.init, p, false);
    // The rotation rows only: this cell owns its focus, so what is asserted is
    // the basis, independent of any focus transition.
    immutable float[16] now = m.resolvedSnapshot(3).view;
    foreach (i; [0, 1, 2, 4, 5, 6, 8, 9, 10])
        assert(abs(now[i] - flat[i]) <= 1e-7f, "a non-preset ortho cell turned with the plane");
}

unittest { // L3 — own-focus ortho (Single): pin, pinned->pinned, unpin keep the numbers
    auto m = new ViewportManager(0, 0, 800, 600);
    m.applyLayout(LayoutPreset.Single);
    applyCellViewPreset(m.views[0], ViewPreset.Front);
    assert(m.focusOwner(0) == 0, "rig: Single cell 0 does not own its focus");
    immutable Vec3 f = Vec3(0.3f, 0.2f, 0.0f);
    m.views[0].camera.focus = f;
    auto p = obliquePlane();
    m.applyPlaneFrame(WorkplanePacket.init, p, true);
    assert(near(m.views[0].camera.focus, toWorld(p, f), 1e-5f),
        format("own-focus ortho cell ignored the transition rule (pin): %s, expected %s",
               s(m.views[0].camera.focus), s(toWorld(p, f))));
    WorkplanePacket q = p;   // re-aligned: another pinned frame
    q.center = Vec3(0.0f, 0.5f, 0.0f);
    q.axis1 = p.axis2; q.normal = p.axis1; q.axis2 = p.normal;
    m.applyPlaneFrame(p, q, true);
    assert(near(m.views[0].camera.focus, toWorld(q, f), 1e-5f),
        format("own-focus ortho cell ignored the transition rule (pinned to pinned): "
             ~ "%s, expected %s", s(m.views[0].camera.focus), s(toWorld(q, f))));
    m.applyPlaneFrame(q, WorkplanePacket.init, true);
    assert(near(m.views[0].camera.focus, f, 1e-5f),
        format("own-focus ortho cell ignored the transition rule (unpin): %s, expected %s",
               s(m.views[0].camera.focus), s(f)));
}

unittest { // L4 — a pan in a turned ortho cell follows its screen
    auto m = quad();
    auto p = obliquePlane();
    m.applyPlaneFrame(WorkplanePacket.init, p, true);
    auto c = m.views[1].camera;
    immutable Vec3 got = c.panDelta(100, 0);
    immutable Vec3 want = p.axis1 * (-100.0f * c.distance * 0.001f);
    assert(near(got, want, 1e-6f),
        format("pan in a turned ortho cell does not follow its screen: %s, expected %s",
               s(got), s(want)));
}

unittest { // L6 — a non-user publication (load, reset) turns the view but keeps the focus
    auto m = new ViewportManager(0, 0, 800, 600);
    m.applyLayout(LayoutPreset.Single);
    applyCellViewPreset(m.views[0], ViewPreset.Front);
    immutable Vec3 f = Vec3(0.3f, 0.2f, 0.0f);
    m.views[0].camera.focus = f;
    m.applyPlaneFrame(WorkplanePacket.init, obliquePlane(), false);
    assert(near(m.views[0].camera.focus, f, 1e-7f),
        format("a non-user plane publication moved the focus: %s -> %s",
               s(f), s(m.views[0].camera.focus)));
}

unittest { // L10 — a cell that goes live after the pin renders turned
    auto m = new ViewportManager(0, 0, 800, 600);
    m.applyLayout(LayoutPreset.Single);
    auto p = obliquePlane();
    m.applyPlaneFrame(WorkplanePacket.init, p, true);
    m.applyLayout(LayoutPreset.Quad);
    Viewport v1 = m.resolvedSnapshot(1);
    Vec3 r1 = Vec3(v1.view[0], v1.view[4], v1.view[8]);
    Vec3 u1 = Vec3(v1.view[1], v1.view[5], v1.view[9]);
    assert(near(r1, p.axis1, 1e-5f) && near(u1, p.normal, 1e-5f),
        format("a cell that went live after the pin did not turn: Front right %s up %s",
               s(r1), s(u1)));
}

unittest { // L11 — the stage publishes every effective-frame change, flagged by its origin
    enum float nan = float.nan;
    auto st = new WorkplaneStage();
    bool[] user;
    bool[] pinned;
    st.onEffectiveFrameChanged = (in WorkplanePacket b, in WorkplanePacket a, bool u) {
        user ~= u;
        pinned ~= !a.isAuto;
    };
    st.edit(nan, nan, nan, 30.0f, 40.0f, 0.0f);   // pin: user
    st.edit(0.4f, nan, nan, nan, nan, nan);       // pinned -> pinned: user
    st.reset();                                   // lifecycle reset: not a user edit
    st.reset();                                   // no change: no publication
    st.edit(nan, nan, nan, 10.0f, 0.0f, 0.0f);    // pin again: user
    st.resetByUser();                             // `workplane.reset`: user
    assert(user == [true, true, false, true, true] && pinned == [true, true, false, true, false],
        format("work-plane publications differ: user %s pinned %s (expected user "
             ~ "[true, true, false, true, true], pinned [true, true, false, true, false])",
               user, pinned));
}
