// `BackgroundRayPicker.nearestAtPixel` — the ONE pixel → nearest background
// hit query (task 9357, Pen parity wave S2). Rig: two stacked quads as two
// background sources — source 0 the FAR quad (z = -1, larger), source 1 the
// NEAR quad (z = 0) — under an ORTHO camera looking -Z through a NON-square
// 400 x 200 viewport (halfH 1, aspect 2: pixel (sx, sy) -> world
// x = (sx / 200 - 1) * 2, y = 1 - sy / 100). The far quad is listed FIRST so
// a "first source wins" or "farthest wins" answer reads srcIdx 0, not 1.
module tests.unit.background_pixel_ray_test;

import std.format : format;
import std.math   : fabs;

import bvh_pick   : BackgroundRayPicker, SurfaceHit;
import constraint : BackgroundSource;
import math       : Vec3, Viewport, ModelSpace, lookAt, orthographicMatrix;
import mesh       : Mesh;

private bool near3(Vec3 a, Vec3 b) {
    return fabs(a.x - b.x) < 1e-5f && fabs(a.y - b.y) < 1e-5f && fabs(a.z - b.z) < 1e-5f;
}

private Mesh quadAt(float z, float x0, float x1, float y0, float y1) {
    Mesh m;
    m.vertices = [Vec3(x0, y0, z), Vec3(x1, y0, z), Vec3(x1, y1, z), Vec3(x0, y1, z)];
    m.faces    = [cast(uint[])[0, 1, 2, 3]];
    return m;
}

private Viewport orthoRig() {
    immutable eye = Vec3(0, 0, 5);
    return Viewport(lookAt(eye, Vec3(0, 0, 0), Vec3(0, 1, 0)),
                    orthographicMatrix(1.0f, 2.0f, 0.01f, 100.0f), 400, 200, 0, 0, eye);
}

unittest {
    Mesh far  = quadAt(-1.0f, -1.5f, 1.5f, -0.75f, 0.75f);
    Mesh near = quadAt( 0.0f, -1.0f, 1.2f, -0.6f,  0.6f);
    BackgroundSource[] srcs = [BackgroundSource(&far,  ModelSpace.world()),
                               BackgroundSource(&near, ModelSpace.world())];
    const(BackgroundSource)[] csrcs = srcs;
    auto vp = orthoRig();
    BackgroundRayPicker picker;

    // Must stay green first: the ORACLE is `nearest` on the hand-built ray
    // over the near quad ALONE (one source, so the nearest-of-several rule
    // cannot touch it): the centre ray hits it at the origin.
    const(BackgroundSource)[] nearOnly = csrcs[1 .. 2];
    SurfaceHit want; size_t wantIdx;
    assert(picker.nearest(Vec3(0, 0, 5), Vec3(0, 0, -1), nearOnly, want, wantIdx),
           "oracle: the hand-built centre ray must hit the near quad");
    assert(wantIdx == 0 && near3(want.point, Vec3(0, 0, 0)),
           format("oracle: centre ray must hit the near quad at the origin; got %s", want.point));

    // (a) centre pixel over BOTH sources == the oracle, EXACTLY; the near quad
    // (src 1) answers although the far one is listed first. Farthest-wins
    // reddens here with srcIdx 0.
    SurfaceHit h; size_t idx;
    assert(picker.nearestAtPixel(200.0f, 100.0f, vp, csrcs, h, idx),
           "centre pixel: nearestAtPixel must hit");
    assert(idx == 1, format("centre pixel: srcIdx must be the NEAR quad (1); got %s", idx));
    assert(h.point == want.point && h.t == want.t && h.face == want.face,
           format("centre pixel: nearestAtPixel %s t=%s must equal nearest %s t=%s exactly",
                  h.point, h.t, want.point, want.t));

    // (b) an OFF-centre pixel of the non-square viewport: (300, 50) is world
    // (1.0, 0.5) on the near quad; swapped, (50, 300) is world (-1.5, -2),
    // off both quads, so an x/y swap changes the answer.
    SurfaceHit wantOff; size_t wantOffIdx;
    assert(picker.nearest(Vec3(1.0f, 0.5f, 5), Vec3(0, 0, -1), nearOnly, wantOff, wantOffIdx),
           "oracle: the hand-built off-centre ray must hit");
    assert(picker.nearestAtPixel(300.0f, 50.0f, vp, csrcs, h, idx),
           "off-centre pixel (300, 50): nearestAtPixel must hit (an x/y swap misses here)");
    assert(idx == 1 && h.point == wantOff.point && near3(h.point, Vec3(1.0f, 0.5f, 0)),
           format("off-centre pixel (300, 50): must equal the hand-built ray's hit %s on the near quad "
                  ~ "at (1, 0.5, 0); got src %s at %s", wantOff.point, idx, h.point));

    // (c) a pixel off both quads misses: (390, 10) is world (1.9, 0.9).
    assert(!picker.nearestAtPixel(390.0f, 10.0f, vp, csrcs, h, idx),
           format("pixel (390, 10) is off both quads and must miss; got src %s at %s", idx, h.point));
}
