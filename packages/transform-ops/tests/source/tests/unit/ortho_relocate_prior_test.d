// The orthographic relocate keeps the PRE-PRESS centre's depth
// (`tools.transform.relocate_plane.orthoRelocateThroughPrior`; gap 364, task
// 7134; fixture tests/fixtures/relocate_axis_view_depth.json). The production
// wiring is witnessed end to end by tests/test_relocate_view_depth.d; these
// cells pin the pure rule's three arms on rigs where the focus, the prior
// centre and the click all sit at DIFFERENT depths, so no arm can pass by
// reading the wrong one of them.
module tests.unit.ortho_relocate_prior_test;

import math : Vec3, Viewport, lookAt, orthographicMatrix, screenPointToRay;
import tools.transform.relocate_plane : orthoRelocateThroughPrior;
import std.format : format;
import std.math : abs, PI, tan;

private Viewport ortho(Vec3 eye, Vec3 focus, Vec3 up, bool axisPreset) {
    Viewport vp;
    vp.axisPreset = axisPreset;
    vp.eye    = eye;
    vp.focus  = focus;
    vp.view   = lookAt(eye, focus, up);
    vp.proj   = orthographicMatrix(3.0f * tan(cast(float)(PI / 8.0)), 1.0f, 0.001f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    return vp;
}

private bool near(float a, float b, float eps) { return abs(a - b) <= eps; }

unittest { // axis view: depth from the prior centre, in-plane snapped
    // Front (looks along -Z), focus at depth 2.3, prior centre at depth 1.7.
    auto vp = ortho(Vec3(0.25f, 0.15f, 5.3f), Vec3(0.25f, 0.15f, 2.3f), Vec3(0, 1, 0), true);
    Vec3 o, d;
    screenPointToRay(400.0f + 210.0f, 400.0f - 160.0f, vp, o, d);
    Vec3 c;
    assert(orthoRelocateThroughPrior(vp, o, d, Vec3(9, 9, 1.7f), 0.01f, c));
    assert(near(c.z, 1.7f, 1e-6f), format("axis view kept depth %s, not the prior centre's 1.7", c.z));
    // In-plane: the unprojected click, on the 0.01 lattice and within a step.
    foreach (i, v; [c.x, c.y]) {
        immutable float raw = i == 0 ? o.x : o.y;
        assert(near(v, raw, 0.005f + 1e-5f), format("in-plane %d moved off the click: %s vs %s", i, v, raw));
        assert(abs(v / 0.01f - cast(int)(v / 0.01f + (v >= 0 ? 0.5f : -0.5f))) < 1e-3f,
            format("in-plane %d is not snapped to 0.01: %s", i, v));
    }
    // Snap step 0 is off: the raw click comes back in-plane.
    assert(orthoRelocateThroughPrior(vp, o, d, Vec3(9, 9, 1.7f), 0.0f, c));
    assert(near(c.x, o.x, 1e-6f) && near(c.y, o.y, 1e-6f) && near(c.z, 1.7f, 1e-6f),
        format("snap 0 must leave the click raw: %s vs %s", c, o));
}

unittest { // ortho with no locked axis: the view-perpendicular plane through the prior centre, unsnapped
    auto vp = ortho(Vec3(3, 4, 5), Vec3(0.3f, 0.2f, 0.1f), Vec3(0, 1, 0), false);
    Vec3 o, d;
    screenPointToRay(517.0f, 333.0f, vp, o, d);
    immutable Vec3 prior = Vec3(-1.2f, 0.7f, 2.9f);
    Vec3 c;
    assert(orthoRelocateThroughPrior(vp, o, d, prior, 0.01f, c));
    immutable Vec3 n = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    immutable float depthC = n.x * c.x + n.y * c.y + n.z * c.z;
    immutable float depthP = n.x * prior.x + n.y * prior.y + n.z * prior.z;
    assert(near(depthC, depthP, 1e-4f), format("depth %s, prior centre's %s", depthC, depthP));
    // On the click's ray: c - o is parallel to d.
    immutable Vec3 e = c - o;
    immutable float t = e.x * d.x + e.y * d.y + e.z * d.z;
    immutable Vec3 off = e - d * t;
    assert(abs(off.x) + abs(off.y) + abs(off.z) < 1e-4f, format("landing %s is off the click ray", c));
}
