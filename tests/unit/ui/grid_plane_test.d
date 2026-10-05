// The viewport grid's plane choice (task 9451, capture K-D cell D3): auto +
// ortho draws the most-facing world plane; auto + perspective keeps the world
// XZ ground grid; a pinned plane draws in its own basis through its centre.
// The drawn-pixel witness is tests/test_view_grid_facing.d.
module ui.grid_plane_test;

import math : Vec3, Viewport, lookAt, orthographicMatrix, perspectiveMatrix;
import toolpipe.stages.workplane : WorkplaneStage;
import ui.viewport_render : gridPlaneModel;

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
