module view;

import math;
import std.math : sqrt, tan, PI;

/// Projection kind for the camera. Default Perspective.
/// Ortho sets an axis-locked viewpoint; orbit is disabled.
enum ProjKind { Perspective, Ortho }

/// Named view preset driving the axis-locked ortho orientation.
/// Camera and Perspective both use the free spherical camera.
enum ViewPreset { Perspective, Top, Bottom, Front, Back, Left, Right, Camera }

/// Rotate a view's up-vector about its own FORWARD axis by `roll` radians —
/// the single place a bank enters the camera basis.
///
/// `forward` must be unit; `up0` is the un-banked up hint (the world +Y for
/// a perspective cell, the preset's up for an ortho one) and need not be
/// perpendicular to `forward`. The result IS perpendicular to `forward` and
/// unit, so `lookAt`'s own `normalize(cross(f, up))` reproduces the intended
/// screen-right EXACTLY rather than to within a renormalisation — that is
/// why the orthonormal pair is built here instead of handing `lookAt` a
/// rotated `up0` (whose cross with `forward` is short by `cos(elevation)`
/// and would rotate by the wrong angle).
///
/// `roll == 0` short-circuits and returns `up0` **unchanged**, by reference
/// equality of the value. That guard is the reason every un-banked viewport
/// stays bit-identical to the pre-roll code: `lookAt(eye, focus, Vec3(0,1,0))`
/// is still literally what runs, same operands, same rounding.
Vec3 rolledUpVector(Vec3 forward, Vec3 up0, float roll) {
    import std.math : cos, sin;
    if (roll == 0.0f) return up0;
    Vec3 r0 = cross(forward, up0);
    float rl = r0.length;
    // forward parallel to the up hint: no screen-right to bank about. The
    // perspective path cannot reach this (elevation is clamped to 89 deg),
    // the ortho presets are constructed perpendicular; a caller that does
    // reach it gets the un-banked basis rather than a NaN one.
    if (rl < 1e-6f) return up0;
    r0 = r0 * (1.0f / rl);
    Vec3 u0 = cross(r0, forward);
    return u0 * cos(roll) + r0 * sin(roll);
}

// CameraView
class View {
    float azimuth   =  0.5f;
    float elevation =  0.4f;
    float distance  =  3.0f;
    /// Viewport BANK, radians. The angle by which screen-right is rotated
    /// about the view FORWARD axis, positive = the same sense as the
    /// heading/pitch/BANK triple a reference viewport publishes for itself.
    ///
    /// Sign is pinned, not chosen: with the world up at +Y and no bank, the
    /// screen-right row of the view matrix satisfies `right.y == 0`. Under a
    /// bank it satisfies
    ///
    ///     right.y == -sin(roll) * cos(elevation)
    ///
    /// which is exactly the relation a reference capture's screen-right row
    /// obeys against its own reported bank (see the unittest at the end of
    /// this module that reproduces one such row to 1e-5).
    ///
    /// A third rotational degree of freedom is the whole point: with
    /// `azimuth`/`elevation` alone the view basis is forced perpendicular to
    /// +Y, so screen-right can never leave the world XZ plane, and any
    /// downstream rule that reads the view's own screen-right (drag bases,
    /// axis elections) is evaluated on a basis the reference does not have.
    ///
    /// Default 0 — every existing viewport is bit-identical to the pre-roll
    /// code path, which is guarded explicitly in `rolledUpVector`.
    float roll      =  0.0f;
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
        roll       =  0.0f;
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

    /// Bank gesture: accumulate `roll` from a horizontal drag.
    ///
    /// UNMEASURED CONSTANT. The per-pixel rate mirrors `orbit`'s 0.005
    /// rad/px so the two rotational drags feel the same; the reference's own
    /// rate for its dedicated bank drag is not stated in anything shipped
    /// with it (see doc/camera_roll_plan.md §2) and has not been captured.
    /// Unlike `elevation` there is no clamp: a bank wraps, exactly as
    /// `azimuth` does.
    void rollBy(int dx) {
        roll += dx * 0.005f;
    }

    void zoom(int dx) {
        distance -= dx * 0.01f * distance;
        if (distance < minDist) distance = minDist;
        if (distance > maxDist) distance = maxDist;
    }

    void pan(int dx, int dy) {
        focus += panDelta(dx, dy);
    }

    /// World-space focus delta for a screen-space drag of (dx, dy), computed
    /// from THIS camera's own basis (projKind/viewPreset/distance/azimuth/
    /// elevation) but not written anywhere — pure, `const`. Extracted from
    /// `pan()` (task 0217) so a quad/split cell can compute its own
    /// screen-correct delta while the caller decides which camera's `focus`
    /// actually receives it (coupled-pan: the linkage owner, not necessarily
    /// `this`).
    Vec3 panDelta(int dx, int dy) const {
        return panDeltaWith(dx, dy, roll);
    }

    /// `panDelta` with the BANK supplied explicitly.
    ///
    /// Everything else still comes from this camera's own members, exactly as
    /// `panDelta` always did (task 0217: the drag basis is the ORIGIN cell's,
    /// only the write target is redirected). The bank is separated out anyway
    /// so `panDelta`'s one caller cannot silently pan on a level basis while
    /// the same camera renders banked — the failure mode is a drag that
    /// slides off the cursor, which is invisible in a screenshot and obvious
    /// in the hand.
    Vec3 panDeltaWith(int dx, int dy, float r) const {
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
            // Ortho presets ship an explicit screen basis; a bank rotates
            // that basis about the preset's own view axis. `r == 0` returns
            // `up` untouched, so every existing ortho cell is unchanged.
            if (r != 0.0f) {
                Vec3 fwd = cross(up, right);   // right x up == -fwd
                up    = rolledUpVector(fwd, up, r);
                right = cross(fwd, up);
            }
            return right * (-dx * speed) + up * (dy * speed);
        }
        // Perspective: existing spherical basis (byte-identical at r == 0).
        Vec3 off     = sphericalToCartesian(azimuth, elevation, distance);
        Vec3 forward = normalize(-off);
        Vec3 upVec   = rolledUpVector(forward, Vec3(0, 1, 0), r);
        Vec3 right   = normalize(cross(forward, upVec));
        Vec3 up      = cross(right, forward);
        return right * (-dx * speed) + up * (dy * speed);
    }

    /// Compute Viewport matrices from explicit transform inputs instead of member
    /// fields.  All projection math is identical to viewport() — just reads
    /// parameters.  `const` so it is callable without races from any thread.
    /// Writes NO members.
    ///
    /// `r` = the BANK to render with, in radians. It is an explicit input
    /// for the same reason `a`/`e` are: a follower cell renders the MASTER's
    /// rotation, and `this.roll` is then the wrong number (see
    /// `ViewportManager.resolveFollow`). There is deliberately NO four-arg
    /// overload defaulting to `this.roll` — that overload would compile at
    /// the follow-resolved call sites and silently render the follower's own
    /// bank.
    Viewport viewportWith(Vec3 f, float d, float a, float e, float r) const {
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
            upVec = rolledUpVector(normalize(f - localEye), upVec, r);
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
        float[16] localView = lookAt(localEye, f,
                                     rolledUpVector(normalize(-offset), Vec3(0, 1, 0), r));
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
        return viewportWith(focus, distance, azimuth, elevation, roll);
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
        Vec3 eye_ = viewportWith(focus, distance, azimuth, elevation, roll).eye;
        return format(
            `{"azimuth":%f,"elevation":%f,"distance":%f,"roll":%f,` ~
            `"focus":{"x":%f,"y":%f,"z":%f},` ~
            `"eye":{"x":%f,"y":%f,"z":%f},` ~
            `"width":%d,"height":%d,"vpX":%d,"vpY":%d}`,
            azimuth, elevation, distance, roll,
            focus.x, focus.y, focus.z,
            eye_.x, eye_.y, eye_.z,
            width, height, x, y);
    }

    /// Like toJson() but uses explicit transform inputs.  `const`, non-mutating —
    /// safe to call from any thread.  Eye is recomputed from the provided inputs.
    string toJsonWith(Vec3 f, float d, float a, float e, float r) const {
        import std.format : format;
        Viewport vp = viewportWith(f, d, a, e, r);
        return format(
            `{"azimuth":%f,"elevation":%f,"distance":%f,"roll":%f,` ~
            `"focus":{"x":%f,"y":%f,"z":%f},` ~
            `"eye":{"x":%f,"y":%f,"z":%f},` ~
            `"width":%d,"height":%d,"vpX":%d,"vpY":%d}`,
            a, e, d, r,
            f.x, f.y, f.z,
            vp.eye.x, vp.eye.y, vp.eye.z,
            width, height, x, y);
    }

    // Pure framing computation shared by `frameToVertices` and the
    // viewport-owner fit redirect (task 0221). Writes NOTHING to `this` —
    // returns the fitted center + distance via out params. Byte-identical
    // math to the historical `frameToVertices` body. `const` so it is
    // callable without races from any thread. Splitting the computation from
    // the assignment lets the fit path write the CENTER to the focus-owner
    // camera and the DISTANCE to the scale-owner camera when a Quad cell's
    // independence flags route them to different cells (mirrors task 0217's
    // owner redirect for pan/zoom). With an empty `verts` the out params are
    // left at their default init — callers must guard on `verts.length`.
    void computeFrame(Vec3[] verts, out Vec3 outFocus, out float outDistance) const
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

        outFocus = (mn + mx) * 0.5f;

        float dx = mx.x - mn.x, dy = mx.y - mn.y, dz = mx.z - mn.z;
        float radius = sqrt(dx*dx + dy*dy + dz*dz) * 0.5f;
        if (radius < 1e-6f) radius = 1e-6f;

        // Use the tighter field-of-view (Y or X) so the shape fits in both axes.
        float aspect    = cast(float)width / height;
        float halfTanY  = tan(fovY * 0.5f);
        float halfTanX  = halfTanY * aspect;
        float halfTanMin = halfTanY < halfTanX ? halfTanY : halfTanX;

        outDistance = radius / (0.9f * halfTanMin);
        // Keep the bounding sphere fully beyond the near clip plane (0.1).
        if (outDistance < radius + 0.001f) outDistance = radius + 0.001f;
        if (outDistance < minDist) outDistance = minDist;
        if (outDistance > maxDist) outDistance = maxDist;
    }

    // Adjusts `focus` and `distance` so the bounding sphere of `verts` fills
    // 90 % of the viewport (keeping the current orbit azimuth/elevation).
    void frameToVertices(Vec3[] verts)
    {
        if (verts.length == 0) return;
        Vec3 f; float d;
        computeFrame(verts, f, d);
        focus    = f;
        distance = d;
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
    auto vp2 = v.viewportWith(v.focus, v.distance, v.azimuth, v.elevation, v.roll);
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
    auto vp2 = v.viewportWith(v.focus, v.distance, v.azimuth, v.elevation, v.roll);
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
    string j2 = v.toJsonWith(v.focus, v.distance, v.azimuth, v.elevation, v.roll);
    auto o1 = parseJSON(j1);
    auto o2 = parseJSON(j2);
    assert(isClose(o1["azimuth"].floating,   o2["azimuth"].floating,   1e-5f), "toJsonWith az");
    assert(isClose(o1["elevation"].floating, o2["elevation"].floating, 1e-5f), "toJsonWith el");
    assert(isClose(o1["distance"].floating,  o2["distance"].floating,  1e-5f), "toJsonWith dist");
    assert(isClose(o1["eye"]["x"].floating,  o2["eye"]["x"].floating,  1e-5f), "toJsonWith eye.x");
    assert(isClose(o1["eye"]["y"].floating,  o2["eye"]["y"].floating,  1e-5f), "toJsonWith eye.y");
    assert(isClose(o1["eye"]["z"].floating,  o2["eye"]["z"].floating,  1e-5f), "toJsonWith eye.z");
}

// ---------------------------------------------------------------------------
// Numpad view-shortcut toggle (task 0215) — pure, GL-free.
//
// Numpad 1/2/3 switch a viewport cell to its primary axis view; a repeat
// press of the SAME key toggles to the opposite face. Numpad `.` always sets
// Perspective (no opposite — idempotent). This function only computes WHICH
// preset to switch to; the caller (app.d) resolves the target cell and
// performs the actual write via the shared `applyCellViewPreset` helper
// (viewport.d) so the toggle logic stays independent of any cell/GL state.
enum NumpadViewKey { One, Two, Three, Period }

ViewPreset nextViewForKey(ViewPreset cur, NumpadViewKey key) {
    final switch (key) {
        case NumpadViewKey.One:
            return cur == ViewPreset.Top   ? ViewPreset.Bottom : ViewPreset.Top;
        case NumpadViewKey.Two:
            return cur == ViewPreset.Front ? ViewPreset.Back   : ViewPreset.Front;
        case NumpadViewKey.Three:
            return cur == ViewPreset.Right ? ViewPreset.Left   : ViewPreset.Right;
        case NumpadViewKey.Period:
            return ViewPreset.Perspective;
    }
}

unittest { // first press from an unrelated view lands on the primary face
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.One)   == ViewPreset.Top);
    assert(nextViewForKey(ViewPreset.Left,        NumpadViewKey.Two)   == ViewPreset.Front);
    assert(nextViewForKey(ViewPreset.Back,        NumpadViewKey.Three) == ViewPreset.Right);
}

unittest { // repeat press on the SAME key toggles to the opposite face
    assert(nextViewForKey(ViewPreset.Top,   NumpadViewKey.One)   == ViewPreset.Bottom);
    assert(nextViewForKey(ViewPreset.Front, NumpadViewKey.Two)   == ViewPreset.Back);
    assert(nextViewForKey(ViewPreset.Right, NumpadViewKey.Three) == ViewPreset.Left);
}

unittest { // third press (repeat again) returns to the primary face
    ViewPreset p = ViewPreset.Perspective;
    p = nextViewForKey(p, NumpadViewKey.One); // -> Top
    p = nextViewForKey(p, NumpadViewKey.One); // -> Bottom
    p = nextViewForKey(p, NumpadViewKey.One); // -> Top again
    assert(p == ViewPreset.Top, "third press must return to the primary face");
}

unittest { // numpad `.` is idempotent regardless of current preset
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Period) == ViewPreset.Perspective);
    assert(nextViewForKey(ViewPreset.Top,         NumpadViewKey.Period) == ViewPreset.Perspective);
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Period) == ViewPreset.Perspective);
}

unittest { // fresh-from-Perspective: each key's first press is independent of the others
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.One)    == ViewPreset.Top);
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Two)    == ViewPreset.Front);
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Three)  == ViewPreset.Right);
    assert(nextViewForKey(ViewPreset.Perspective, NumpadViewKey.Period) == ViewPreset.Perspective);
}
// ---------------------------------------------------------------------------
// Camera BANK (roll) — the third rotational degree of freedom.
//
// Vocabulary used below: the view matrix is column-major, so the world-space
// camera basis is read off it as
//     screen-right = (view[0], view[4], view[8])
//     screen-up    = (view[1], view[5], view[9])
//     forward      = (-view[2], -view[6], -view[10])
// which is exactly how every consumer in the tree already reads it (drag
// bases, gizmo shapes, handle depth, arcball). Those consumers do inherit the
// bank for free.
//
// The consumers that RECONSTRUCTED the basis from a hard-coded world up
// instead of reading it are the ones that had to be fixed, and there are
// THREE, not the two an earlier version of this comment claimed:
//     `viewportWith`   — here
//     `panDeltaWith`   — here
//     `render_mvp.d`'s IPR camera (`cd.up`) — outside the default build
// The audit that produced this list was run over the modeling configuration,
// and `source/render/*` is `version (WithRender)`-gated and therefore not
// compiled by a plain `dub build`. So the third site was neither flagged by
// the compiler (its call to `viewportWith` was a stale 4-arg one that only
// `--config=with-render` would reject) nor caught by reading. The lesson is
// the general one: "every consumer" must be established over BOTH build
// configurations, or it means "every consumer the default build compiles".
// These tests cover the two in this module; the render site is covered by
// `--config=with-render` compiling at all.
// ---------------------------------------------------------------------------

version(unittest) {
    private Vec3 rightRowOf(Viewport vp) {
        return Vec3(vp.view[0], vp.view[4], vp.view[8]);
    }
    private Vec3 upRowOf(Viewport vp) {
        return Vec3(vp.view[1], vp.view[5], vp.view[9]);
    }
    private Vec3 fwdRowOf(Viewport vp) {
        return Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
    }
}

unittest { // roll == 0 is BIT-IDENTICAL to the pre-roll code path
    // The regression this file exists to prevent: the reference-comparison
    // corpus (17 move legs / 18 rotate legs) must not move by one ulp when
    // the camera merely GAINS the ability to bank. `rolledUpVector` returns
    // its input unchanged at exactly 0, so `lookAt(eye, focus, Vec3(0,1,0))`
    // is still the literal call, with the literal same operands.
    auto v = new View(0, 0, 1098, 966);
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-1.5f, -0.4f, 0.0f, 0.4138754f, 1.5f]) {
        v.azimuth = a; v.elevation = e; v.distance = 1.486323332f;
        v.focus = Vec3(0.25f, -0.5f, 2.0f);
        v.roll = 0.0f;
        Viewport got = v.viewport();
        Vec3 off = sphericalToCartesian(a, e, v.distance);
        float[16] want = lookAt(v.focus + off, v.focus, Vec3(0, 1, 0));
        assert(got.view == want,
               "un-banked viewport must be bit-identical to lookAt(eye, focus, +Y)");
    }
}

unittest { // the bank law: right.y == -sin(roll) * cos(elevation)
    // This is the identity that makes our `roll` the SAME quantity a
    // reference viewport reports as its bank, rather than merely "some
    // rotation about the view axis". It is what lets a captured bank be
    // transferred as a number instead of re-fitted.
    import std.math : sin, cos;
    auto v = new View(0, 0, 800, 600);
    v.distance = 2.0f;
    foreach (a; [-1.1f, 0.0f, 0.9f])
    foreach (e; [-0.9f, 0.0f, 0.4138754f, 1.0f])
    foreach (r; [-1.2f, -0.2055634f, 0.0f, 0.2055634f, 1.2f]) {
        v.azimuth = a; v.elevation = e; v.roll = r;
        Vec3 right = rightRowOf(v.viewport());
        assert(isClose(right.y, -sin(r) * cos(e), 2e-5f, 2e-5f),
               "screen-right.y must equal -sin(roll)*cos(elevation)");
    }
}

unittest { // a banked camera reproduces a RECORDED reference view basis
    // Numbers are a measurement, not a fit. A reference engine's own view
    // published heading/pitch/bank = (0.5040186, 0.4138754, 0.2055634) rad
    // for one capture camera, and an independent instrument read that same
    // view's world-space basis rows off the engine at the same moment:
    //
    //     screen-right  +0.817569  -0.186885  +0.544661
    //     screen-up     +0.368870  +0.896293  -0.246158
    //     forward       +0.442173  -0.402161  -0.801717
    //
    // Feeding heading/pitch/bank into OUR parameterisation (azimuth is the
    // negated heading; elevation is the pitch; roll is the bank) has to
    // return those three rows. Nothing here is tuned: the only freedom is
    // the azimuth sign, which is fixed independently by the forward row.
    //
    // Before this change the third input had nowhere to go, and the
    // screen-right row came out (+0.875649, 0, +0.482948) — the SAME view
    // axis with the horizon forced level. The 0.1869 in the y lane is
    // precisely what was unrepresentable.
    auto v = new View(0, 0, 1098, 966);
    v.azimuth   = -0.5040186f;   // = -heading
    v.elevation =  0.4138754f;   // = pitch
    v.roll      =  0.2055634f;   // = bank
    v.distance  =  1.486323332f;
    v.focus     =  Vec3(0, 0, 0);
    Viewport vp = v.viewport();

    Vec3 right = rightRowOf(vp), up = upRowOf(vp), fwd = fwdRowOf(vp);
    enum float tol = 2e-5f;
    assert(isClose(right.x,  0.817569f, tol, tol) &&
           isClose(right.y, -0.186885f, tol, tol) &&
           isClose(right.z,  0.544661f, tol, tol),
           "banked screen-right must reproduce the recorded reference row");
    assert(isClose(up.x,  0.368870f, tol, tol) &&
           isClose(up.y,  0.896293f, tol, tol) &&
           isClose(up.z, -0.246158f, tol, tol),
           "banked screen-up must reproduce the recorded reference row");
    assert(isClose(fwd.x,  0.442173f, tol, tol) &&
           isClose(fwd.y, -0.402161f, tol, tol) &&
           isClose(fwd.z, -0.801717f, tol, tol),
           "forward must be unchanged by the bank");

    // And the un-banked build of the same camera is the level-horizon basis
    // that could not carry it.
    v.roll = 0.0f;
    Vec3 level = rightRowOf(v.viewport());
    assert(level.y == 0.0f, "an un-banked camera has right.y exactly 0");
    assert(isClose(level.x, 0.875649f, tol, tol),
           "un-banked screen-right.x for this camera");
}

unittest { // the bank is a rotation: basis stays orthonormal and right-handed
    import std.math : abs;
    auto v = new View(0, 0, 640, 480);
    v.azimuth = 0.77f; v.elevation = -0.31f; v.distance = 4.0f;
    foreach (r; [-2.5f, -0.6f, 0.3f, 1.4f, 3.0f]) {
        v.roll = r;
        Viewport vp = v.viewport();
        Vec3 rt = rightRowOf(vp), up = upRowOf(vp), fw = fwdRowOf(vp);
        assert(abs(rt.length - 1.0f) < 1e-5f, "right must stay unit");
        assert(abs(up.length - 1.0f) < 1e-5f, "up must stay unit");
        assert(abs(dot(rt, up)) < 1e-5f, "right must stay perpendicular to up");
        assert(abs(dot(rt, fw)) < 1e-5f, "right must stay perpendicular to forward");
        // right x up == -forward  (camera looks down its own -Z)
        Vec3 c = cross(rt, up);
        assert(abs(c.x + fw.x) < 1e-5f && abs(c.y + fw.y) < 1e-5f &&
               abs(c.z + fw.z) < 1e-5f, "basis must stay right-handed");
    }
}

unittest { // banking moves the horizon, never the eye
    auto v = new View(0, 0, 800, 600);
    v.azimuth = 0.3f; v.elevation = 0.6f; v.distance = 7.5f;
    v.focus = Vec3(-1, 2, 0.5f);
    Vec3 eye0 = v.viewport().eye;
    v.roll = 1.1f;
    Vec3 eye1 = v.viewport().eye;
    assert(eye0.x == eye1.x && eye0.y == eye1.y && eye0.z == eye1.z,
           "roll is a rotation about the view axis — the eye must not move");
    // ... and the forward direction is likewise untouched.
    v.roll = 0.0f; Vec3 f0 = fwdRowOf(v.viewport());
    v.roll = 1.1f; Vec3 f1 = fwdRowOf(v.viewport());
    assert(isClose(f0.x, f1.x, 1e-6f, 1e-6f) &&
           isClose(f0.y, f1.y, 1e-6f, 1e-6f) &&
           isClose(f0.z, f1.z, 1e-6f, 1e-6f),
           "roll must not change the view direction");
}

unittest { // pan follows the banked screen axes, by exactly the bank angle
    import std.math : sin, cos, abs;
    auto v = new View(0, 0, 800, 600);
    v.azimuth = -0.5040186f; v.elevation = 0.4138754f; v.distance = 3.0f;
    enum float r = 0.2055634f;
    Vec3 flat = v.panDeltaWith(100, 0, 0.0f);
    Vec3 bank = v.panDeltaWith(100, 0, r);
    // Same length (a rotation), and the angle between them is the bank.
    assert(isClose(flat.length, bank.length, 1e-4f), "pan magnitude is bank-invariant");
    float cosang = dot(normalize(flat), normalize(bank));
    assert(isClose(cosang, cos(r), 1e-4f, 1e-4f),
           "a horizontal pan under a bank rotates by exactly the bank angle");
    // A pan under a bank leaves the world XZ plane; the un-banked one cannot.
    assert(abs(flat.y) < 1e-6f, "un-banked horizontal pan stays in world XZ");
    assert(abs(bank.y) > 1e-3f, "banked horizontal pan must acquire a y component");
}

unittest { // ortho cells bank too, about their own preset axis
    import std.math : abs;
    auto v = new View(0, 0, 800, 600);
    v.projKind = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Top;
    v.distance = 5.0f;
    v.roll = 0.4f;
    Viewport vp = v.viewport();
    Vec3 fw = fwdRowOf(vp), rt = rightRowOf(vp);
    assert(abs(fw.x) < 1e-5f && isClose(fw.y, -1.0f, 1e-4f) && abs(fw.z) < 1e-5f,
           "Top preset forward must survive the bank");
    assert(abs(rt.y) < 1e-5f, "Top preset banks within the world XZ plane");
    assert(abs(rt.x - 1.0f) > 1e-3f, "Top preset screen-right must actually rotate");
    assert(isOrtho(vp), "banked Top preset must stay orthographic");
    // The ortho pan basis banks with it.
    Vec3 flat = v.panDeltaWith(100, 0, 0.0f);
    Vec3 bank = v.panDeltaWith(100, 0, 0.4f);
    assert(abs(dot(normalize(flat), normalize(bank)) - 1.0f) > 1e-4f,
           "ortho pan direction must follow the bank");
}

unittest { // rollBy accumulates and, unlike elevation, does not clamp
    auto v = new View(0, 0, 800, 600);
    assert(v.roll == 0.0f, "a fresh camera is level");
    v.rollBy(100);
    assert(isClose(v.roll, 0.5f, 1e-6f), "rollBy is 0.005 rad/px");
    v.rollBy(-100);
    assert(isClose(v.roll, 0.0f, 1e-6f, 1e-6f), "rollBy is signed and reversible");
    foreach (i; 0 .. 20) v.rollBy(100);
    assert(v.roll > 2.0f * PI,
           "bank wraps like azimuth — a full turn must not be clamped");
    v.reset();
    assert(v.roll == 0.0f, "reset() must level the horizon");
}

unittest { // the bank term downstream: reachable, decidable, and quantified
    // The off-handle scale axis election has exactly one bank-sensitive
    // clause. When the election drops the world Y axis it picks the
    // horizontal survivor by comparing two axes' projections onto the VIEW'S
    // OWN SCREEN-RIGHT — the row this file now produces. With the horizon
    // forced level that row's y lane is identically 0, so one side of the
    // comparison was structurally 0 and the clause was untestable.
    //
    // This test pins the camera INPUT to that comparison. It deliberately
    // does NOT port the election: the frame it would consume comes from the
    // axis stage, and electing is a separate task that must be measured.
    //
    // Camera + frame are the recorded corpus rig: the pinned action-centre
    // modes install the selected face's own frame, whose first and third
    // columns are world +X and world +Y.
    import std.math : abs;
    auto v = new View(0, 0, 1098, 966);
    v.azimuth = -0.5040186f; v.elevation = 0.4138754f; v.distance = 1.486323332f;
    immutable Vec3 A0 = Vec3(1, 0, 0);   // frame column 0 at the corpus rig
    immutable Vec3 A2 = Vec3(0, 1, 0);   // frame column 2 (the face normal)

    // 1. Level horizon: the comparison is degenerate — one side is exactly 0.
    v.roll = 0.0f;
    Vec3 n0 = rightRowOf(v.viewport());
    assert(abs(dot(A2, n0)) == 0.0f,
           "with no bank the clause's second operand is identically zero");

    // 2. At the recorded bank the term is non-zero, i.e. actually evaluated.
    v.roll = 0.2055634f;
    n0 = rightRowOf(v.viewport());
    assert(isClose(abs(dot(A0, n0)), 0.817569f, 2e-5f, 2e-5f),
           "clause operand |A0.N0| at the recorded bank");
    assert(isClose(abs(dot(A2, n0)), 0.186885f, 2e-5f, 2e-5f),
           "clause operand |A2.N0| at the recorded bank — the term the level "
           ~ "horizon could not produce");

    // 3. And the honest half: at THIS camera the recorded bank does not flip
    //    the clause. It flips at 0.66801 rad (38.27 deg), far beyond the
    //    11.78 deg the reference view actually carries — so a bank-capable
    //    camera makes the clause reachable and measurable, and by itself
    //    changes no elected axis on the corpus rig.
    assert(abs(dot(A0, n0)) > abs(dot(A2, n0)),
           "the recorded bank leaves the clause's winner unchanged");
    v.roll = 0.6680103f - 0.001f;
    n0 = rightRowOf(v.viewport());
    assert(abs(dot(A0, n0)) > abs(dot(A2, n0)), "just below the crossover");
    v.roll = 0.6680103f + 0.001f;
    n0 = rightRowOf(v.viewport());
    assert(abs(dot(A0, n0)) < abs(dot(A2, n0)), "just above the crossover it flips");
}

unittest { // viewportWith / toJsonWith carry a NON-ZERO bank the same way
    // The existing own-inputs round-trip tests above run at the default
    // bank of 0, where a dropped `roll` argument would be invisible. These
    // repeat them banked, so the explicit-inputs path is pinned on the term
    // that actually distinguishes it.
    import std.json : parseJSON;
    auto v = new View(0, 0, 800, 600);
    v.focus = Vec3(0.5f, 0, -1.0f);
    v.distance = 6.0f; v.azimuth = 1.2f; v.elevation = -0.3f;
    v.roll = 0.4137f;
    auto vp1 = v.viewport();
    auto vp2 = v.viewportWith(v.focus, v.distance, v.azimuth, v.elevation, v.roll);
    assert(vp1.view == vp2.view, "banked viewportWith(own5) must match viewport()");
    // ...and a DIFFERENT bank must produce a different matrix, so the
    // equality above is not vacuous.
    auto vp3 = v.viewportWith(v.focus, v.distance, v.azimuth, v.elevation, 0.0f);
    assert(vp1.view != vp3.view, "the roll argument must reach the matrix");

    auto o1 = parseJSON(v.toJson());
    auto o2 = parseJSON(v.toJsonWith(v.focus, v.distance, v.azimuth,
                                     v.elevation, v.roll));
    assert(isClose(o1["roll"].floating, o2["roll"].floating, 1e-5f),
           "toJsonWith must report the bank it rendered");
    assert(isClose(o1["roll"].floating, 0.4137f, 1e-5f),
           "/api/camera must publish the bank");
}
