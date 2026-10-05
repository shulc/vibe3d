// The viewport grid's plane choice (task 9451, capture K-D cell D3): auto +
// ortho draws the most-facing world plane; auto + perspective keeps the world
// XZ ground grid; a pinned plane draws in its own basis through its centre.
// Perspective also draws the work-plane lattice (task 9509, capture K-GR
// GR_P): `workPlaneLatticeModel`. The drawn-pixel witness is
// tests/test_view_grid_facing.d.
module ui.grid_plane_test;

import math : Vec3, Viewport, lookAt, normalize, orthographicMatrix, perspectiveMatrix;
import toolpipe.stages.workplane : WorkplaneStage;
import ui.viewport_render : gridPlaneModel, workPlaneLatticeModel;

private Viewport camera(Vec3 eye, Vec3 up, bool ortho) {
    Viewport vp;
    vp.view = lookAt(eye, Vec3(0, 0, 0), up);
    vp.proj = ortho ? orthographicMatrix(2.0f, 1.0f, 0.01f, 100.0f)
                    : perspectiveMatrix(0.8f, 1.0f, 0.01f, 100.0f);
    return vp;
}

/// The plane normal of a grid model: its local-Y column, unscaled.
private Vec3 normalOf(const float[16] m, float step) {
    return Vec3(m[4] / step, m[5] / step, m[6] / step);
}

private bool near(Vec3 a, Vec3 b) {
    import std.math : abs;
    return abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && abs(a.z - b.z) < 1e-6;
}

unittest { // auto: ortho faces the view on each axis; perspective stays XZ
    auto wp = new WorkplaneStage();
    assert(wp.isAuto, "rig: a fresh stage is auto");
    struct Cell { string name; Vec3 eye; Vec3 up; bool ortho; Vec3 normal; }
    immutable Cell[] cells = [
        Cell("top ortho",   Vec3(0, 10, 0.001f), Vec3(0, 1, 0), true,  Vec3(0, 1, 0)),
        Cell("front ortho", Vec3(0, 0, 10),      Vec3(0, 1, 0), true,  Vec3(0, 0, 1)),
        Cell("right ortho", Vec3(10, 0, 0),      Vec3(0, 1, 0), true,  Vec3(1, 0, 0)),
        Cell("front persp", Vec3(0, 0, 10),      Vec3(0, 1, 0), false, Vec3(0, 1, 0)),
        Cell("right persp", Vec3(10, 0, 0),      Vec3(0, 1, 0), false, Vec3(0, 1, 0)),
    ];
    size_t ran;
    foreach (c; cells) {
        auto vp = camera(c.eye, c.up, c.ortho);
        auto m = gridPlaneModel(vp, 0.5f, wp);
        immutable n = normalOf(m, 0.5f);
        assert(near(n, c.normal), c.name ~ ": wrong grid plane normal");
        assert(m[12] == 0 && m[13] == 0 && m[14] == 0 && m[15] == 1,
               c.name ~ ": the auto grid passes through the world origin");
        ++ran;
    }
    assert(ran == 5);
    // No stage at all reads as auto.
    auto front = camera(Vec3(0, 0, 10), Vec3(0, 1, 0), true);
    assert(near(normalOf(gridPlaneModel(front, 1, null), 1), Vec3(0, 0, 1)),
           "no stage: front ortho still faces the view");
}

unittest { // pinned: the stage basis through its centre, in every projection
    auto wp = new WorkplaneStage();
    assert(wp.setAttr("rotX", "90") && wp.setAttr("cenY", "2"), "rig: pin the plane");
    assert(!wp.isAuto, "rig: an explicit rotation pins the plane");
    Vec3 n, a1, a2;
    wp.currentBasis(n, a1, a2);
    foreach (ortho; [true, false]) {
        auto vp = camera(Vec3(0, 10, 0.001f), Vec3(0, 1, 0), ortho);
        auto m = gridPlaneModel(vp, 2.0f, wp);
        assert(near(normalOf(m, 2.0f), n), "pinned: the grid normal is the stage's");
        assert(m[12] == 0 && m[13] == 2 && m[14] == 0, "pinned: through the centre, unscaled");
    }
}

/// A perspective camera looking at `focus` from direction `back` at the
/// distance whose grid step is 0.1 m (the K-GR rig's step).
private Viewport perspAt(Vec3 back, Vec3 focus, Vec3 up) {
    Viewport vp;
    vp.width = 650; vp.height = 544;
    vp.focus = focus;
    vp.eye = focus + back * 2.4f;
    vp.view = lookAt(vp.eye, focus, up);
    vp.proj = perspectiveMatrix(0.8f, 650.0f / 544.0f, 0.01f, 100.0f);
    return vp;
}

unittest { // the perspective work-plane lattice: auto plane, rounded focus channel
    import std.format : format;
    import viewgrid : viewGridSizeFor, g_viewGrid;
    import std.math : abs;
    struct Cell { string name; Vec3 back; Vec3 up; Vec3 focus; Vec3 normal; float offset; }
    // GR_P_* (fixture K-GR.json, focus ~(0.07, 1.0..1.025, 0)): the measured
    // plane and offset; then the rounding cells, which separate "rounded to
    // ten steps" from "through the raw focus" and "through the origin".
    immutable Cell[] cells = [
        Cell("GR_P_def",  Vec3(0, 1, 0),            Vec3(0, 0, -1), Vec3(0.07f, 1.0f, 0),    Vec3(0, 1, 0), 1),
        Cell("GR_P_obl",  Vec3(0.551f, 0.702f, 0.451f), Vec3(0, 1, 0), Vec3(0.07f, 1.025f, 0), Vec3(0, 1, 0), 1),
        Cell("GR_P_xobl", Vec3(0.799f, 0.449f, 0.4f),   Vec3(0, 1, 0), Vec3(0.07f, 1.0f, 0),   Vec3(1, 0, 0), 0),
        Cell("GR_P_z",    Vec3(0.15f, 0.25f, 0.957f),   Vec3(0, 1, 0), Vec3(0.07f, 1.0f, 0),   Vec3(0, 0, 1), 0),
        Cell("GR_P_z2",   Vec3(0.05f, 0.08f, 0.996f),   Vec3(0, 1, 0), Vec3(0.07f, 1.0f, 0),   Vec3(0, 0, 1), 0),
        Cell("round down", Vec3(0, 1, 0),           Vec3(0, 0, -1), Vec3(0.3f, 1.4f, -0.2f), Vec3(0, 1, 0), 1),
        Cell("round up",   Vec3(0, 1, 0),           Vec3(0, 0, -1), Vec3(0.3f, 1.6f, -0.2f), Vec3(0, 1, 0), 2),
        Cell("round on Z", Vec3(0.15f, 0.25f, 0.957f), Vec3(0, 1, 0), Vec3(0.4f, 1.0f, 0.7f), Vec3(0, 0, 1), 1),
    ];
    size_t ran;
    foreach (c; cells) {
        auto vp = perspAt(normalize(c.back), c.focus, c.up);
        assert(abs(viewGridSizeFor(vp, g_viewGrid) - 0.1f) < 1e-6f,
               c.name ~ ": rig: the grid step must be 0.1 m");
        immutable m = workPlaneLatticeModel(vp, 0.1f);
        assert(near(normalOf(m, 0.1f), c.normal), c.name ~ ": wrong work-plane lattice normal");
        immutable Vec3 t = Vec3(m[12], m[13], m[14]);
        assert(near(t, c.normal * c.offset),
               format("%s: the lattice must shift along its normal to %s, got %s",
                      c.name, c.offset, t));
        ++ran;
    }
    assert(ran == 8);
}
