module view;

import math;
import std.math : sqrt, tan, PI;

/// Projection kind for the camera. Default Perspective.
/// Ortho sets an axis-locked viewpoint; orbit is disabled.
enum ProjKind { Perspective, Ortho }

/// Named view preset driving the axis-locked ortho orientation.
/// Camera and Perspective both use the free spherical camera.
enum ViewPreset { Perspective, Top, Bottom, Front, Back, Left, Right, Camera }

// CameraView
class View {
    float azimuth   =  0.5f;
    float elevation =  0.4f;
    float distance  =  3.0f;
    Vec3  focus     =  Vec3(0, 0, 0);
    immutable float minDist = 0.0001f;
    immutable float maxDist = float.max;
    immutable float maxElev = cast(float)(89.0f * PI / 180.0f);
    int width, height;
    int x, y;
    // No eye/view/proj mirror fields — viewport camera single-source (0181).
    // The single source of camera matrices is `viewportWith(...)` (and, for
    // a viewport-manager cell, the manager's follow-resolved `Viewport`
    // snapshot). Callers that need a snapshot use `viewport()` /
    // `viewportWith(...)`, never a stored field.
    ProjKind   projKind   = ProjKind.Perspective;
    ViewPreset viewPreset = ViewPreset.Perspective;

    this(int x, int y, int w, int h) { setSize(w, h); setPos(x, y); }
    void setSize(int w, int h) { width = w; height = h; }
    void setPos(int x, int y) { this.x = x; this.y = y; }
    void reset() {
        azimuth    =  0.5f;
        elevation  =  0.4f;
        distance   =  3.0f;
        focus      =  Vec3(0, 0, 0);
        projKind   = ProjKind.Perspective;
        viewPreset = ViewPreset.Perspective;
    }

    void orbit(int dx, int dy) {
        azimuth   -= dx * 0.005f;
        elevation += dy * 0.005f;
        if (elevation >  maxElev) elevation =  maxElev;
        if (elevation < -maxElev) elevation = -maxElev;
    }

    void zoom(int dx) {
        distance -= dx * 0.01f * distance;
        if (distance < minDist) distance = minDist;
        if (distance > maxDist) distance = maxDist;
    }

    void pan(int dx, int dy) {
        float speed = distance * 0.001f;
        if (projKind == ProjKind.Ortho) {
            // Ortho: derive right/up from the preset axis so pan tracks
            // the screen axes regardless of azimuth/elevation.
            Vec3 right, up;
            final switch (viewPreset) {
                case ViewPreset.Top:
                    right = Vec3( 1, 0, 0); up = Vec3(0, 0,-1); break;
                case ViewPreset.Bottom:
                    right = Vec3( 1, 0, 0); up = Vec3(0, 0, 1); break;
                case ViewPreset.Front:
                    right = Vec3( 1, 0, 0); up = Vec3(0, 1, 0); break;
                case ViewPreset.Back:
                    right = Vec3(-1, 0, 0); up = Vec3(0, 1, 0); break;
                case ViewPreset.Right:
                    right = Vec3( 0, 0,-1); up = Vec3(0, 1, 0); break;
                case ViewPreset.Left:
                    right = Vec3( 0, 0, 1); up = Vec3(0, 1, 0); break;
                case ViewPreset.Perspective:
                case ViewPreset.Camera:
                    right = Vec3( 1, 0, 0); up = Vec3(0, 1, 0); break;
            }
            focus += right * (-dx * speed);
            focus += up    * (dy * speed);
            return;
        }
        // Perspective: existing spherical basis (byte-identical).
        Vec3 off     = sphericalToCartesian(azimuth, elevation, distance);
        Vec3 forward = normalize(-off);
        Vec3 right   = normalize(cross(forward, Vec3(0, 1, 0)));
        Vec3 up      = cross(right, forward);
        focus += right * (-dx * speed);
        focus += up    * (dy * speed);
    }

    /// Compute Viewport matrices from explicit transform inputs instead of member
    /// fields.  All projection math is identical to viewport() — just reads
    /// parameters.  `const` so it is callable without races from any thread.
    /// Writes NO members.
    Viewport viewportWith(Vec3 f, float d, float a, float e) const {
        if (projKind == ProjKind.Ortho) {
            Vec3 axisEye, upVec;
            final switch (viewPreset) {
                case ViewPreset.Top:
                    axisEye = Vec3(0,  d, 0); upVec = Vec3(0, 0,-1); break;
                case ViewPreset.Bottom:
                    axisEye = Vec3(0, -d, 0); upVec = Vec3(0, 0, 1); break;
                case ViewPreset.Front:
                    axisEye = Vec3(0, 0,  d); upVec = Vec3(0, 1, 0); break;
                case ViewPreset.Back:
                    axisEye = Vec3(0, 0, -d); upVec = Vec3(0, 1, 0); break;
                case ViewPreset.Right:
                    axisEye = Vec3( d, 0, 0); upVec = Vec3(0, 1, 0); break;
                case ViewPreset.Left:
                    axisEye = Vec3(-d, 0, 0); upVec = Vec3(0, 1, 0); break;
                case ViewPreset.Perspective:
                case ViewPreset.Camera:
                    axisEye = sphericalToCartesian(a, e, d);
                    upVec   = Vec3(0, 1, 0);
                    break;
            }
            Vec3 localEye = f + axisEye;
            float[16] localView = lookAt(localEye, f, upVec);
            float halfH  = d * tan(cast(float)(PI / 8.0));
            float aspect = cast(float)width / height;
            float[16] localProj = orthographicMatrix(halfH, aspect, 0.001f, 100.0f);
            Viewport vp = Viewport(localView, localProj, width, height, x, y, localEye);
            vp.focus = f;
            return vp;
        }
        Vec3 offset   = sphericalToCartesian(a, e, d);
        Vec3 localEye = f + offset;
        float[16] localView = lookAt(localEye, f, Vec3(0, 1, 0));
        float[16] localProj = perspectiveMatrix(45.0f * PI / 180.0f,
                                                 cast(float)width / height, 0.001f, 100.0f);
        Viewport vp = Viewport(localView, localProj, width, height, x, y, localEye);
        vp.focus = f;
        return vp;
    }

    /// Non-mutating — no member mirror to write back into (viewport camera
    /// single-source, 0181). Kept as a convenience wrapper over
    /// `viewportWith` (own transform inputs) so existing call sites and this
    /// module's unittests stay unchanged.
    Viewport viewport() const {
        return viewportWith(focus, distance, azimuth, elevation);
    }

    // ---------------------------------------------------------------------------
    // Frame-to-fit helper
    // ---------------------------------------------------------------------------

    // Adjusts `focus` and `distance` so the bounding sphere of `verts` fills
    // 90 % of the viewport (keeping the current orbit azimuth/elevation).
    string toJson() const {
        import std.format : format;
        // Derive eye from the current transform inputs (viewport camera
        // single-source, 0181) — no member mirror to read anymore.
        Vec3 eye_ = viewportWith(focus, distance, azimuth, elevation).eye;
        return format(
            `{"azimuth":%f,"elevation":%f,"distance":%f,` ~
            `"focus":{"x":%f,"y":%f,"z":%f},` ~
            `"eye":{"x":%f,"y":%f,"z":%f},` ~
            `"width":%d,"height":%d,"vpX":%d,"vpY":%d}`,
            azimuth, elevation, distance,
            focus.x, focus.y, focus.z,
            eye_.x, eye_.y, eye_.z,
            width, height, x, y);
    }

    /// Like toJson() but uses explicit transform inputs.  `const`, non-mutating —
    /// safe to call from any thread.  Eye is recomputed from the provided inputs.
    string toJsonWith(Vec3 f, float d, float a, float e) const {
        import std.format : format;
        Viewport vp = viewportWith(f, d, a, e);
        return format(
            `{"azimuth":%f,"elevation":%f,"distance":%f,` ~
            `"focus":{"x":%f,"y":%f,"z":%f},` ~
            `"eye":{"x":%f,"y":%f,"z":%f},` ~
            `"width":%d,"height":%d,"vpX":%d,"vpY":%d}`,
            a, e, d,
            f.x, f.y, f.z,
            vp.eye.x, vp.eye.y, vp.eye.z,
            width, height, x, y);
    }

    void frameToVertices(Vec3[] verts)
    {
        if (verts.length == 0) return;

        float fovY = 45.0f * PI / 180.0f;

        Vec3 mn = verts[0], mx = verts[0];
        foreach (ref v; verts) {
            if (v.x < mn.x) mn.x = v.x;
            if (v.y < mn.y) mn.y = v.y;
            if (v.z < mn.z) mn.z = v.z;
            if (v.x > mx.x) mx.x = v.x;
            if (v.y > mx.y) mx.y = v.y;
            if (v.z > mx.z) mx.z = v.z;
        }

        focus = (mn + mx) * 0.5f;

        float dx = mx.x - mn.x, dy = mx.y - mn.y, dz = mx.z - mn.z;
        float radius = sqrt(dx*dx + dy*dy + dz*dz) * 0.5f;
        if (radius < 1e-6f) radius = 1e-6f;

        // Use the tighter field-of-view (Y or X) so the shape fits in both axes.
        float aspect    = cast(float)width / height;
        float halfTanY  = tan(fovY * 0.5f);
        float halfTanX  = halfTanY * aspect;
        float halfTanMin = halfTanY < halfTanX ? halfTanY : halfTanX;

        distance = radius / (0.9f * halfTanMin);
        // Keep the bounding sphere fully beyond the near clip plane (0.1).
        if (distance < radius + 0.001f) distance = radius + 0.001f;
        if (distance < minDist) distance = minDist;
        if (distance > maxDist) distance = maxDist;
    }
};

// ---------------------------------------------------------------------------
// Phase 3 — ortho projection unittests (pure, no GL).
// ---------------------------------------------------------------------------

version(unittest) {
    import math;
    import std.math : isClose, abs;
}

unittest { // viewport() ortho: Top preset — forward = -Y, eye above focus
    auto v = new View(0, 0, 800, 600);
    v.projKind   = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Top;
    v.focus      = Vec3(0, 0, 0);
    v.distance   = 5.0f;
    Viewport vp  = v.viewport();
    // eye must be above focus along +Y
    assert(isClose(vp.eye.x, 0.0f, 1e-5f, 1e-5f), "Top eye.x");
    assert(isClose(vp.eye.y, 5.0f, 1e-5f),         "Top eye.y == distance");
    assert(isClose(vp.eye.z, 0.0f, 1e-5f, 1e-5f), "Top eye.z");
    // forward = -m[2], -m[6], -m[10] must be (0,-1,0)
    float fx = -vp.view[2], fy = -vp.view[6], fz = -vp.view[10];
    assert(isClose(fx, 0.0f, 1e-4f, 1e-4f) && isClose(fy,-1.0f,1e-4f) && isClose(fz, 0.0f,1e-4f,1e-4f),
           "Top forward must be (0,-1,0)");
    // must be ortho
    assert(isOrtho(vp), "Top preset must produce ortho matrix");
}

unittest { // viewport() ortho: Front preset — forward = -Z
    auto v = new View(0, 0, 800, 600);
    v.projKind   = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Front;
    v.focus      = Vec3(0, 0, 0);
    v.distance   = 5.0f;
    Viewport vp  = v.viewport();
    assert(isClose(vp.eye.z, 5.0f, 1e-5f), "Front eye.z == distance");
    float fx = -vp.view[2], fy = -vp.view[6], fz = -vp.view[10];
    assert(isClose(fz,-1.0f,1e-4f), "Front forward.z must be -1");
    assert(isOrtho(vp), "Front preset must produce ortho matrix");
}

unittest { // viewport() perspective: default — byte-identical to old code
    auto v1 = new View(0, 0, 800, 600);
    Viewport vp1 = v1.viewport();
    // projKind defaults to Perspective → same as before.
    assert(!isOrtho(vp1), "Default must not be ortho");
    assert(vp1.proj[15] == 0.0f, "Default proj[15] must be 0");
}

unittest { // pan() ortho Top: +dx moves focus along world X only, no Y/Z leak
    auto v = new View(0, 0, 800, 600);
    v.projKind   = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Top;
    v.focus      = Vec3(0, 0, 0);
    v.distance   = 5.0f;
    Vec3 before  = v.focus;
    v.pan(100, 0);   // pure horizontal drag
    Vec3 delta = v.focus - before;
    // X changes, Y and Z must not change (Y is the view axis, Z is locked)
    assert(abs(delta.y) < 1e-6f, "pan Top +dx must not move focus.y");
    assert(abs(delta.z) < 1e-6f, "pan Top +dx must not move focus.z");
    assert(abs(delta.x) > 1e-6f, "pan Top +dx must move focus.x");
}

unittest { // pan() perspective: regression guard — basis unchanged
    auto v = new View(0, 0, 800, 600);
    // Default projKind = Perspective
    Vec3 before = v.focus;
    v.pan(0, 100);  // pure vertical drag
    // focus.y must change (up in the spherical basis)
    assert(abs((v.focus - before).y) > 1e-4f,
           "perspective pan vertical must change focus.y");
}

unittest { // viewportWith(own4) == viewport() for ortho Top
    auto v = new View(0, 0, 800, 600);
    v.projKind   = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Top;
    v.focus      = Vec3(1, 2, 3);
    v.distance   = 4.0f;
    v.azimuth    = 0.3f;
    v.elevation  = 0.2f;
    auto vp1 = v.viewport();
    auto vp2 = v.viewportWith(v.focus, v.distance, v.azimuth, v.elevation);
    assert(isClose(vp1.eye.x, vp2.eye.x, 1e-5f) &&
           isClose(vp1.eye.y, vp2.eye.y, 1e-5f) &&
           isClose(vp1.eye.z, vp2.eye.z, 1e-5f),
           "viewportWith(own4) eye must equal viewport() eye (ortho Top)");
    assert(vp1.view == vp2.view, "viewportWith(own4) view must match viewport() (ortho Top)");
    assert(vp1.proj == vp2.proj, "viewportWith(own4) proj must match viewport() (ortho Top)");
}

unittest { // viewportWith(own4) == viewport() for perspective
    auto v = new View(0, 0, 800, 600);
    v.focus    = Vec3(0.5f, 0, -1.0f);
    v.distance = 6.0f;
    v.azimuth  = 1.2f;
    v.elevation = -0.3f;
    auto vp1 = v.viewport();
    auto vp2 = v.viewportWith(v.focus, v.distance, v.azimuth, v.elevation);
    assert(isClose(vp1.eye.x, vp2.eye.x, 1e-5f) &&
           isClose(vp1.eye.y, vp2.eye.y, 1e-5f) &&
           isClose(vp1.eye.z, vp2.eye.z, 1e-5f),
           "viewportWith(own4) eye must equal viewport() eye (perspective)");
    assert(vp1.view == vp2.view, "viewportWith(own4) view must match viewport() (persp)");
    assert(vp1.proj == vp2.proj, "viewportWith(own4) proj must match viewport() (persp)");
}

unittest { // toJsonWith(own4) == toJson() after one viewport() call
    import std.json : parseJSON;
    auto v = new View(0, 0, 800, 600);
    v.focus    = Vec3(1, 0, 0);
    v.distance = 5.0f;
    v.azimuth  = 0.7f;
    v.elevation = 0.1f;
    v.viewport();  // prime the member eye
    string j1 = v.toJson();
    string j2 = v.toJsonWith(v.focus, v.distance, v.azimuth, v.elevation);
    auto o1 = parseJSON(j1);
    auto o2 = parseJSON(j2);
    assert(isClose(o1["azimuth"].floating,   o2["azimuth"].floating,   1e-5f), "toJsonWith az");
    assert(isClose(o1["elevation"].floating, o2["elevation"].floating, 1e-5f), "toJsonWith el");
    assert(isClose(o1["distance"].floating,  o2["distance"].floating,  1e-5f), "toJsonWith dist");
    assert(isClose(o1["eye"]["x"].floating,  o2["eye"]["x"].floating,  1e-5f), "toJsonWith eye.x");
    assert(isClose(o1["eye"]["y"].floating,  o2["eye"]["y"].floating,  1e-5f), "toJsonWith eye.y");
    assert(isClose(o1["eye"]["z"].floating,  o2["eye"]["z"].floating,  1e-5f), "toJsonWith eye.z");
}