module tests.unit.viewgrid_regression_test;

import viewgrid;
import math : Vec3;
import vibe3d.util.spatial.spatial : Viewport, isOrtho;
import std.math : fabs;


// ===========================================================================
// Tests
// ===========================================================================










version (unittest) {
    import math : lookAt, perspectiveMatrix, orthographicMatrix;
    import std.math : PI, sin, cos, tan;

    private Viewport testViewport(float az, float el, float dist,
                                  int w, int h, float fovY = 45.0f * PI / 180.0f) {
        Vec3 back = Vec3(cos(el) * sin(az), sin(el), cos(el) * cos(az));
        Vec3 focus = Vec3(0, 0, 0);
        Vec3 eye = focus + back * dist;
        Viewport vp;
        vp.view = lookAt(eye, focus, Vec3(0, 1, 0));
        vp.proj = perspectiveMatrix(fovY, cast(float)w / h, 0.001f, 100.0f);
        vp.width = w; vp.height = h; vp.eye = eye; vp.focus = focus;
        return vp;
    }
}


unittest {
    // ---- viewWorldPerPixel is the two algebraic forms, and nothing else --
    enum int w = 1426, h = 966;
    enum float fovY = 45.0f * PI / 180.0f;
    immutable float focalPx = 0.5f * h / tan(fovY / 2);

    foreach (double dist; [0.5, 1.560178, 3.86, 12.559432]) {
        auto vp = testViewport(-0.159244f, 0.265694f, cast(float)dist, w, h, fovY);
        immutable float want = cast(float)(0.8 * dist) / focalPx;
        assert(fabs(viewWorldPerPixel(vp) - want) <= 1e-6f * want,
               "perspective pixel size must be (4/5)*eyeDistance/focalPx");
    }

    // It is a property of the VIEW, so it must not depend on where the camera
    // is pointing — only on how far away it is.
    auto a = testViewport(0.0f,  0.3f, 2.0f, w, h, fovY);
    auto b = testViewport(2.7f, -0.9f, 2.0f, w, h, fovY);
    assert(fabs(viewWorldPerPixel(a) - viewWorldPerPixel(b)) < 1e-7f,
           "pixel size must not depend on azimuth or elevation");

    // Orthographic: exactly 1/focalPx, with NO 4/5 and no distance term.
    Viewport o;
    o.view = lookAt(Vec3(0, 5, 0), Vec3(0, 0, 0), Vec3(0, 0, -1));
    o.proj = orthographicMatrix(1.5f, 800.0f / 600.0f, 0.001f, 100.0f);
    o.width = 800; o.height = 600;
    o.eye = Vec3(0, 5, 0); o.focus = Vec3(0, 0, 0);
    immutable float oFocal = 0.5f * o.height * o.proj[5];
    assert(fabs(viewWorldPerPixel(o) - 1.0f / oFocal) <= 1e-7f,
           "orthographic pixel size is 1/focalPx with no distance term");
    // Moving an orthographic camera further away must NOT change the step.
    auto o2 = o;
    o2.eye = Vec3(0, 50, 0);
    o2.view = lookAt(o2.eye, Vec3(0, 0, 0), Vec3(0, 0, -1));
    assert(viewWorldPerPixel(o2) == viewWorldPerPixel(o));

    // Degenerate views return the disabled value rather than a garbage step.
    Viewport z;
    assert(viewWorldPerPixel(z) == 0.0f);
}


unittest {
    // ---- The grid step doubles when the camera doubles its distance -----
    //
    // ...up to the ladder. This is the user-visible claim: zooming out by a
    // factor of ten multiplies the step by exactly ten (the ladder is closed
    // under x10), and zooming out by a factor that stays inside a rung leaves
    // the step ALONE. Both halves matter; the second is what "stepped" means.
    ViewGridPrefs p;
    auto v1 = testViewport(0.3f, 0.4f, 1.0f, 1426, 966);
    auto v10 = testViewport(0.3f, 0.4f, 10.0f, 1426, 966);
    immutable float g1  = viewGridSizeFor(v1, p);
    immutable float g10 = viewGridSizeFor(v10, p);
    assert(fabs(g10 - 10.0f * g1) <= 1e-5f * g10,
           "ten times the distance is exactly ten times the step");

    // A distance change small enough to stay inside one rung must not move
    // the step at all. 1.0 -> 1.01 cannot cross a rung boundary unless it
    // starts within 1% of one; assert on the pair we can compute.
    immutable float px1 = viewWorldPerPixel(v1);
    immutable float raw = cast(float)(kGridSizePixels * px1);
    // Pick a distance scale that provably keeps 25*px inside (prev, g1].
    immutable float head = g1 / raw;      // > 1 by construction
    if (head > 1.02f) {
        auto vNear = testViewport(0.3f, 0.4f, 1.01f, 1426, 966);
        assert(viewGridSizeFor(vNear, p) == g1,
               "a zoom that does not cross a rung must not move the step");
    }
}
