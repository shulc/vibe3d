module drag_source_helpers;

import std.math : sqrt, isNaN, abs;
import math;
import vibe3d.util.spatial.spatial : Orientation, Viewport, eyeVectorAt, lockedViewAxis, projectToWindowFull, screenPointToRay, viewPixelScale;
import handler : MoveHandler, gizmoSize, getGizmoPixels;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : GesturePacket, GestureTrack;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : ComponentGuide;
import coord_rounding : CoordinateRounding, kFixedIncrementDefault, coordRounding,
                       coordRoundingFixedIncrement;

version (unittest) {
    import std.math : PI, sin, cos, tan;

    // The cameras the cross-engine drag corpus actually runs, in our own
    // terms. `az`/`el`/`dist` came out of the corpus harness's own camera
    // conversion, applied to the reference's recorded state for the named
    // case; they are inputs here, not fits.
    private struct Cam { string name; float az, el, dist; int w, h; }

    public immutable Cam[] corpusCams = [
        Cam("real_perspective", -0.159244f, 0.265694f,  1.560178f, 1426, 966),
        Cam("reported_topview",  0.0f,      1.570796f,  0.5f,      1219, 966),
        Cam("far_perspective",  -0.159244f, 0.265694f, 12.559432f, 1426, 966),
        Cam("side_camera",       0.97397f,  0.359541f,  3.142141f, 1227, 966),
    ];

    public Viewport corpusViewport(Cam c, Vec3 focus = Vec3(0, 0, 0)) {
        Vec3 back = Vec3(cos(c.el) * sin(c.az), sin(c.el), cos(c.el) * cos(c.az));
        Vec3 eye  = focus + back * c.dist;
        Viewport vp;
        vp.view   = lookAt(eye, focus, Vec3(0, 1, 0));
        vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f,
                                      cast(float)c.w / c.h, 0.001f, 100.0f);
        vp.width  = c.w;
        vp.height = c.h;
        vp.eye    = eye;
        vp.focus  = focus;
        return vp;
    }

    // The pre-0520 body of `planeDragDelta`'s tail, verbatim: two ray/plane
    // intersections differenced. The oracle the port is measured AGAINST, kept
    // here rather than described.
    public Vec3 exactPlaneDelta(int mx, int my, int lastMX, int lastMY,
                                 Vec3 center, Vec3 n, const ref Viewport vp,
                                 out bool skip)
    {
        skip = false;
        Vec3 origCurr, dirCurr, origPrev, dirPrev;
        screenPointToRay(cast(float)mx,     cast(float)my,     vp, origCurr, dirCurr);
        screenPointToRay(cast(float)lastMX, cast(float)lastMY, vp, origPrev, dirPrev);
        Vec3 hitCurr, hitPrev;
        if (!rayPlaneIntersect(origCurr, dirCurr, center, n, hitCurr) ||
            !rayPlaneIntersect(origPrev, dirPrev, center, n, hitPrev))
        { skip = true; return Vec3(0, 0, 0); }
        return hitCurr - hitPrev;
    }

    public float vlen(Vec3 v) { return sqrt(v.x*v.x + v.y*v.y + v.z*v.z); }
}
