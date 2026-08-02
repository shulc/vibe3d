module view;

import math;
import std.math : sqrt, tan, PI;
import std.json : JSONValue, JSONType;
import trackball : TrackballOption, resolveTrackball, trackballRadius,
                   trackballVector, trackballStep, trackballMouseSpeed;

/// Projection kind for the camera. Default Perspective.
/// Ortho sets an axis-locked viewpoint; orbit is disabled.
enum ProjKind { Perspective, Ortho }

/// Named view preset driving the axis-locked ortho orientation.
/// Camera and Perspective both use the free spherical camera.
enum ViewPreset { Perspective, Top, Bottom, Front, Back, Left, Right, Camera }

/// Serialise a camera orientation as a nine-element JSON array, LOSSLESSLY.
///
/// `%.9g` is not decoration: nine significant decimal digits is the round-trip
/// precision of a 32-bit float, so the parsed value is the SAME float, bit for
/// bit. The `%f` (six fixed decimals) every other camera field uses loses
/// roughly seven of the mantissa's bits — fine for an angle a human reads, not
/// fine for the matrix that IS the camera, where a lossy round trip means the
/// horizon quietly tilts a little on every save and load.
string orientationToJson(Orientation o) {
    import std.format : format;
    return format("[%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g]",
                  o.m[0], o.m[1], o.m[2], o.m[3], o.m[4],
                  o.m[5], o.m[6], o.m[7], o.m[8]);
}

/// Parse what `orientationToJson` wrote. Returns false (leaving `out_`
/// untouched) unless the value is an array of exactly nine numbers, so a
/// malformed or absent field leaves the caller's camera alone rather than
/// aiming it somewhere arbitrary.
///
/// Does NOT orthonormalise — that is the caller's write funnel
/// (`View.setOrientation`), which is the single place the discipline lives.
bool orientationFromJson(JSONValue v, out Orientation out_) {
    if (v.type != JSONType.array) return false;
    auto a = v.array;
    if (a.length != 9) return false;
    Orientation o;
    foreach (i, ref e; a) {
        switch (e.type) {
            case JSONType.float_:   o.m[i] = cast(float)e.floating;        break;
            case JSONType.integer:  o.m[i] = cast(float)e.integer;         break;
            case JSONType.uinteger: o.m[i] = cast(float)e.uinteger;        break;
            default: return false;
        }
    }
    out_ = o;
    return true;
}

// CameraView
class View {
    /// **The camera's rotational truth.** A full 3x3 (see `math.Orientation`),
    /// not three angles: only a matrix can carry a rotation reached by
    /// composing increments about arbitrary axes, and only a matrix is defined
    /// at the poles. `azimuth` / `elevation` / `roll` below are DERIVED views
    /// onto it — the same relationship a reference viewport has between the
    /// nine floats it persists per view and the heading/pitch/bank triple it
    /// reports for itself.
    ///
    /// Private with a `setOrientation` funnel so every write goes through the
    /// normalisation discipline; read it through `orientation`.
    private Orientation orient_ = Orientation.fromAngles(0.5f, 0.4f, 0.0f);
    float distance  =  3.0f;
    Vec3  focus     =  Vec3(0, 0, 0);

    /// The stored orientation. Read-only by design: writes go through
    /// `setOrientation` (or the three angle setters), which is what keeps the
    /// matrix orthonormal.
    @property Orientation orientation() const { return orient_; }

    /// Replace the whole rotation. **Re-orthonormalises**: this is the entry
    /// point for orientations that came from outside the model — a parsed
    /// document, an HTTP body, a captured nine-float atom, or an incremental
    /// composition — none of which can be trusted to be a clean rotation. A
    /// matrix that is already clean passes through bit-untouched (the
    /// normalisation is idempotent), which is what makes serialisation
    /// round-trip exactly.
    void setOrientation(Orientation o) { orient_ = o.orthonormalized(); }

    /// Rotate the camera by `angle` radians about the WORLD-space `axis`.
    /// The composition primitive the matrix storage exists for — an
    /// arbitrary-axis increment has no expression in the angle chart.
    void rotateAbout(Vec3 axis, float angle) {
        orient_ = orient_.rotatedAbout(axis, angle);
    }

    /// Orbit HEADING, radians — a DERIVED view of `orient_`.
    ///
    /// Reading recovers the chart coordinate; writing rebuilds the orientation
    /// from (this azimuth, the current elevation, the current roll). A write
    /// therefore round-trips the other two through the chart, which costs
    /// float dust (~1e-7) and, at a pole, cannot separate heading from bank —
    /// that is intrinsic to naming a rotation by three angles and is why the
    /// storage is the matrix. Code that wants to move the camera without
    /// touching the chart should use `rotateAbout` / `setOrientation`.
    @property float azimuth() const { return orient_.azimuth; }
    @property void  azimuth(float v) {
        float a, e, r; orient_.toAngles(a, e, r);
        orient_ = Orientation.fromAngles(v, e, r);
    }

    /// Orbit PITCH, radians — a DERIVED view of `orient_`. See `azimuth`.
    @property float elevation() const { return orient_.elevation; }
    @property void  elevation(float v) {
        float a, e, r; orient_.toAngles(a, e, r);
        orient_ = Orientation.fromAngles(a, v, r);
    }

    /// Viewport BANK, radians — a DERIVED view of `orient_`. The angle by
    /// which screen-right is rotated about the view FORWARD axis, positive =
    /// the same sense as the heading/pitch/BANK triple a reference viewport
    /// publishes for itself.
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
    /// A third rotational degree of freedom was the first thing the two-angle
    /// camera could not hold; an arbitrary-axis composition is the second, and
    /// a scalar bank cannot hold THAT either, which is why the scalar is gone
    /// and the matrix is the storage.
    @property float roll() const { return orient_.roll; }
    @property void  roll(float v) {
        float a, e, r; orient_.toAngles(a, e, r);
        orient_ = Orientation.fromAngles(a, e, v);
    }
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
        // One chart write, not four: setting the three angles one at a time
        // would round-trip the matrix through the chart three times and leave
        // the default camera a few ulps off the literal default orientation.
        orient_    = Orientation.fromAngles(0.5f, 0.4f, 0.0f);
        distance   =  3.0f;
        focus      =  Vec3(0, 0, 0);
        projKind   = ProjKind.Perspective;
        viewPreset = ViewPreset.Perspective;
        // The per-cell trackball override and any in-flight arming go back to
        // launch state too: a cell left explicitly On by one test is exactly
        // the kind of setting that resurfaces as an unrelated failure later.
        trackballOption = TrackballOption.Default;
        tbArmed_        = false;
    }

    void orbit(int dx, int dy) {
        // Reads the chart once, writes it once. The clamp keeps the ORBIT
        // GESTURE short of the pole exactly as before; it is no longer load-
        // bearing for the arithmetic (`Orientation` is defined at the pole),
        // only for what a drag is allowed to do, which this task does not
        // change.
        float a, e, r;
        orient_.toAngles(a, e, r);
        a -= dx * 0.005f;
        e += dy * 0.005f;
        if (e >  maxElev) e =  maxElev;
        if (e < -maxElev) e = -maxElev;
        orient_ = Orientation.fromAngles(a, e, r);
    }

    /// Bank gesture: accumulate `roll` from a horizontal drag.
    ///
    /// UNMEASURED CONSTANT. The per-pixel rate mirrors `orbit`'s 0.005
    /// rad/px so the two rotational drags feel the same; the reference's own
    /// rate for its dedicated bank drag is not stated in anything shipped
    /// with it (see doc/camera_roll_plan.md §2) and has not been captured.
    /// Unlike `elevation` there is no clamp: a bank wraps, exactly as
    /// `azimuth` does.
    ///
    /// A bank is a rotation about the camera's OWN view axis, so it composes
    /// on the matrix directly rather than through the chart. That also makes
    /// it well defined when the camera is looking straight down, where the
    /// chart cannot tell a bank from a heading.
    void rollBy(int dx) {
        // About FORWARD, not back: a positive bank turns screen-right toward
        // screen-down (`right.y == -sin(roll)*cos(elevation)`), which is the
        // -back sense. Rotating about `back` would run the gesture backwards.
        orient_ = orient_.rotatedAbout(orient_.forward(), dx * 0.005f);
    }

    // -----------------------------------------------------------------------
    // Trackball orbit/bank (see source/trackball.d for the law)
    // -----------------------------------------------------------------------

    /// This cell's trackball setting. `Default` defers to the global; the two
    /// explicit arms are a per-viewport override. Per-cell rather than global
    /// because the reference's own option is per-viewport, and because a Quad
    /// layout has exactly one cell where the gesture makes sense.
    TrackballOption trackballOption = TrackballOption.Default;

    /// The previous lifted ball vector — the gesture's whole state, three
    /// floats. Not `Vec3.init`-sensitive: `tbArmed_` gates every read.
    private Vec3 tbPrev_;
    private bool tbArmed_ = false;

    /// Does an orbit drag on THIS camera run the trackball?
    ///
    /// The ortho exclusion lives here rather than at the call site because it
    /// is a property of the view type, not of the gesture. The reference's
    /// rotation gate simply returns without touching the trackball flag when
    /// the view type is ortho — note the precise shape of that: the flag is not
    /// written, it is not "forced off". The observable consequence is the same
    /// one this expresses, that an ortho cell never takes the trackball path,
    /// and it is the only part of a stateful flag's behaviour that a stateless
    /// query can carry.
    ///
    /// This editor's orbit drag already redirects to a pan in an ortho cell, so
    /// in practice the branch is belt-and-braces — which is the point: it means
    /// the exclusion survives someone later deciding an ortho cell should orbit
    /// after all.
    bool trackballActive() const {
        if (projKind == ProjKind.Ortho) return false;
        return resolveTrackball(trackballOption);
    }

    /// Arm the trackball at a press, in WINDOW pixels.
    ///
    /// Window rather than pane-local because that is what an SDL event carries
    /// and because this camera already knows its own rect (`x`/`y`/`width`/
    /// `height` are the cell rect's single owner) — converting at the call site
    /// would put the same subtraction in two places and let them drift.
    void trackballDown(int mx, int my) {
        tbPrev_  = ballVectorAt(mx, my);
        tbArmed_ = true;
    }

    /// Compose one motion step, in WINDOW pixels.
    ///
    /// The lifted vectors are in the CAMERA frame, so the arc's axis is too and
    /// has to be carried into world space before it can rotate the stored
    /// orientation — that is the `right`/`up`/`back` combination below, which
    /// is exactly the orientation matrix applied to the axis.
    ///
    /// **Sign.** The magnitudes above are read; the overall SENSE is not, and
    /// this is the one place that matters. What the reference's instruction
    /// stream fixes is the axis expression (`v1 x v0`) and that the angle it
    /// pairs with it is negated; what it does NOT fix, without also pinning its
    /// matrix-composition order and row/column convention, is which way that
    /// lands. So the sense is pinned by a constraint that is available here
    /// instead: the trackball and the two-axis orbit are alternative
    /// implementations of the SAME drag, selected by a preference, so flipping
    /// that preference must not invert the user's viewport. At a centre press
    /// the trackball's limit therefore has to move the camera the way
    /// `orbit(dx, dy)` does — drag right and the model follows right — and that
    /// fixes the sign uniquely, on both axes at once. The unittests at the end
    /// of this module assert exactly that agreement rather than a chosen sign.
    void trackballMove(int mx, int my) {
        if (!tbArmed_) return;
        immutable Vec3 v1 = ballVectorAt(mx, my);
        Vec3 axisCam; float angle;
        // A degenerate step leaves the ANCHOR alone as well as the camera,
        // which is the reference's own ordering. It is faithful rather than
        // load-bearing — a degenerate step is exactly one where the two lifted
        // vectors are equal, so advancing would write the same value — and
        // `trackballStep`'s doc records the mutation that proved it.
        if (!trackballStep(tbPrev_, v1, axisCam, angle)) return;
        immutable Vec3 axisWorld = orient_.right() * axisCam.x
                                 + orient_.up()    * axisCam.y
                                 + orient_.back()  * axisCam.z;
        orient_ = orient_.rotatedAbout(axisWorld, angle);
        tbPrev_ = v1;
    }

    /// Disarm, so a motion event that arrives without a press does nothing.
    ///
    /// Deliberately NOT wired to button-up. Arming is idempotent — every press
    /// re-anchors — and the motion path is gated on the drag mode, so there is
    /// nothing for a release to clean up. Wiring it there would also be a trap:
    /// the release handler runs AFTER the gesture's origin cell has been
    /// cleared, so it would disarm whichever cell happens to be active rather
    /// than the one that was dragged. `reset()` is the path that does clear it.
    void trackballCancel() { tbArmed_ = false; }

    /// Whether a trackball gesture is currently armed. Test seam only — no
    /// product code branches on this.
    bool trackballArmed() const { return tbArmed_; }

    private Vec3 ballVectorAt(int mx, int my) const {
        return trackballVector(cast(float)(mx - x), cast(float)(my - y),
                               width * 0.5f, height * 0.5f,
                               trackballRadius(width, height),
                               trackballMouseSpeed());
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
        return panDeltaWith(dx, dy, orient_);
    }

    /// `panDelta` with the ORIENTATION supplied explicitly.
    ///
    /// Everything else still comes from this camera's own members, exactly as
    /// `panDelta` always did (task 0217: the drag basis is the ORIGIN cell's,
    /// only the write target is redirected). The rotation is separated out
    /// anyway so `panDelta`'s one caller cannot silently pan on one basis
    /// while the same camera renders on another — the failure mode is a drag
    /// that slides off the cursor, which is invisible in a screenshot and
    /// obvious in the hand.
    ///
    /// The pan basis is now READ off the orientation rather than rebuilt from
    /// a hard-coded world up, so it inherits an arbitrary rotation for free —
    /// this was one of the three sites that reconstructed a basis and had to
    /// be corrected for a bank; it needs no further correction for a matrix.
    Vec3 panDeltaWith(int dx, int dy, Orientation o) const {
        float speed = distance * 0.001f;
        Orientation eff = effectiveOrientation(o);
        return eff.right() * (-dx * speed) + eff.up() * (dy * speed);
    }

    /// The orientation this camera actually RENDERS with, given a candidate
    /// rotation `o`.
    ///
    /// For a perspective cell that is `o` itself. For an axis-locked ortho
    /// cell the preset dictates the view axis and `o`'s heading/pitch are
    /// ignored — only its BANK carries over, rotating the preset's own screen
    /// basis about the preset axis. That is exactly what the pre-matrix camera
    /// did (an ortho cell ignored azimuth/elevation but honoured `roll`), kept
    /// deliberately so a numpad view switch still returns to the orbit the
    /// camera had before it.
    ///
    /// The bank is read through the chart here, which is the one place this
    /// module still depends on it. It is sound for a preset cell because the
    /// stored rotation is a free-camera one and the chart is only degenerate
    /// when THAT rotation is polar.
    private Orientation effectiveOrientation(Orientation o) const {
        if (projKind != ProjKind.Ortho) return o;
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
                // An ortho cell that is not axis-locked keeps the free orbit.
                return o;
        }
        Orientation preset = Orientation.fromBasis(right, up, cross(right, up));
        immutable float r = o.roll;
        if (r == 0.0f) return preset;
        return preset.rotatedAbout(preset.forward(), r);
    }

    /// Compute Viewport matrices from explicit transform inputs instead of member
    /// fields.  All projection math is identical to viewport() — just reads
    /// parameters.  `const` so it is callable without races from any thread.
    /// Writes NO members.
    ///
    /// `o` = the ORIENTATION to render with. It is an explicit input for the
    /// same reason `f`/`d` are: a follower cell renders the MASTER's rotation,
    /// and `this.orientation` is then the wrong matrix (see
    /// `ViewportManager.resolveFollow`). There is deliberately NO two-arg
    /// overload defaulting to `this.orientation` — that overload would compile
    /// at the follow-resolved call sites and silently render the follower's
    /// own rotation, i.e. two linked cells with mutually rotated horizons both
    /// reporting the same rotation.
    ///
    /// The camera basis is now taken straight from the stored rotation
    /// (`viewMatrixFrom`) instead of being rebuilt by `lookAt` from an
    /// eye/target/world-up triple. That is what lets an arbitrary orientation
    /// render at all: `lookAt` can only produce rotations whose screen-right
    /// is perpendicular to the up hint it is given.
    Viewport viewportWith(Vec3 f, float d, Orientation o) const {
        Orientation eff = effectiveOrientation(o);
        Vec3 localEye   = f + eff.back() * d;
        float[16] localView = viewMatrixFrom(eff, localEye);
        float[16] localProj;
        if (projKind == ProjKind.Ortho) {
            float halfH  = d * tan(cast(float)(PI / 8.0));
            float aspect = cast(float)width / height;
            localProj = orthographicMatrix(halfH, aspect, 0.001f, 100.0f);
        } else {
            localProj = perspectiveMatrix(45.0f * PI / 180.0f,
                                          cast(float)width / height, 0.001f, 100.0f);
        }
        Viewport vp = Viewport(localView, localProj, width, height, x, y, localEye);
        vp.focus = f;
        return vp;
    }

    /// Non-mutating — no member mirror to write back into (viewport camera
    /// single-source, 0181). Kept as a convenience wrapper over
    /// `viewportWith` (own transform inputs) so existing call sites and this
    /// module's unittests stay unchanged.
    Viewport viewport() const {
        return viewportWith(focus, distance, orient_);
    }

    // ---------------------------------------------------------------------------
    // Frame-to-fit helper
    // ---------------------------------------------------------------------------

    // Adjusts `focus` and `distance` so the bounding sphere of `verts` fills
    // 90 % of the viewport (keeping the current orbit azimuth/elevation).
    string toJson() const {
        return toJsonWith(focus, distance, orient_);
    }

    /// Like toJson() but uses explicit transform inputs.  `const`, non-mutating —
    /// safe to call from any thread.  Eye is recomputed from the provided inputs.
    ///
    /// `orientation` is the LOSSLESS field and the only one that can carry an
    /// arbitrary rotation; `azimuth`/`elevation`/`roll` remain published as
    /// the derived chart reads they now are, at their historical `%f`
    /// precision, so every existing reader is unaffected.
    string toJsonWith(Vec3 f, float d, Orientation o) const {
        import std.format : format;
        Viewport vp = viewportWith(f, d, o);
        float a, e, r;
        o.toAngles(a, e, r);
        return format(
            `{"azimuth":%f,"elevation":%f,"distance":%f,"roll":%f,` ~
            `"orientation":%s,` ~
            `"focus":{"x":%f,"y":%f,"z":%f},` ~
            `"eye":{"x":%f,"y":%f,"z":%f},` ~
            `"width":%d,"height":%d,"vpX":%d,"vpY":%d}`,
            a, e, d, r,
            orientationToJson(o),
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

// ---------------------------------------------------------------------------
// The orientation JSON codec.
//
// It lives here as free functions rather than inside the HTTP handler because
// it is the CODEC, not an endpoint: any surface that needs to persist a camera
// wants the same nine losslessly-encoded floats. Note that nothing else
// persists a camera today — `prefs.d` says so in as many words ("Camera / view
// / edit-mode / per-document state are deliberately NOT persisted here") and
// the `.v3d` document has no camera field at all — so these are tested here on
// their own terms, not only through the endpoint that currently uses them.
// ---------------------------------------------------------------------------

unittest { // the JSON codec round-trips an arbitrary orientation BIT-EXACTLY
    import std.json : parseJSON;
    // An orientation reached by composing turns about three different axes:
    // no (azimuth, elevation, bank) triple names it, which is the case a
    // lossy or chart-based encoding would silently fail.
    Orientation want = Orientation.fromAngles(0.5f, 0.4f, 0.0f)
                           .rotatedAbout(Vec3(1, 0, 0), 0.7f)
                           .rotatedAbout(Vec3(0, 0, 1), -1.1f)
                           .rotatedAbout(normalize(Vec3(1, 2, 1)), 0.55f);
    Orientation got;
    assert(orientationFromJson(parseJSON(orientationToJson(want)), got),
           "the codec must accept what it produced");
    assert(got.m == want.m,
           "an orientation must survive JSON exactly — nine significant digits "
           ~ "is what pins a float, and the matrix IS the camera");

    // Non-vacuous: the six-decimal precision every other camera field uses
    // would NOT survive this.
    import std.format : format;
    string lossy = format("[%f,%f,%f,%f,%f,%f,%f,%f,%f]",
                          want.m[0], want.m[1], want.m[2], want.m[3], want.m[4],
                          want.m[5], want.m[6], want.m[7], want.m[8]);
    Orientation coarse;
    assert(orientationFromJson(parseJSON(lossy), coarse), "the lossy form parses");
    assert(coarse.m != want.m,
           "if %f round-tripped exactly there would be nothing to protect and "
           ~ "this codec would not need to exist");
}

unittest { // the codec refuses anything that is not nine numbers
    import std.json : parseJSON;
    Orientation sentinel = Orientation.fromAngles(1.1f, -0.2f, 0.3f);
    foreach (bad; [`[1,0,0,0,1,0]`,              // too few
                   `[1,0,0,0,1,0,0,0,1,0]`,      // too many
                   `[1,0,0,0,1,0,0,0,"x"]`,      // not a number
                   `{"m":[1,0,0,0,1,0,0,0,1]}`,  // not an array
                   `9`, `null`, `[]`]) {
        Orientation o = sentinel;
        assert(!orientationFromJson(parseJSON(bad), o),
               "the codec must reject " ~ bad);
    }
    // Integers are legal JSON numbers and must be accepted — an identity
    // matrix written by hand is all 1s and 0s.
    Orientation ident;
    assert(orientationFromJson(parseJSON(`[1,0,0,0,1,0,0,0,1]`), ident),
           "an all-integer matrix must parse");
    assert(ident.m == [1.0f,0,0, 0,1,0, 0,0,1], "and land on the identity");
}

unittest { // a camera survives serialise -> parse -> camera, bit-exactly
    // The whole point, at the level the task is about: an arbitrary rotation
    // put on a View, written out, read back into another View, is the same
    // camera to the last bit — INCLUDING through the re-normalising write
    // funnel the reader goes through.
    import std.json : parseJSON;
    auto a = new View(0, 0, 800, 600);
    a.setOrientation(Orientation.fromAngles(0.5f, 0.4f, 0.0f)
                         .rotatedAbout(normalize(Vec3(0.3f, 1, -0.7f)), 1.27f));
    a.distance = 4.75f;
    a.focus    = Vec3(1, -2, 0.5f);

    auto j = parseJSON(a.toJson());
    auto b = new View(0, 0, 800, 600);
    Orientation parsed;
    assert(orientationFromJson(j["orientation"], parsed), "the published field parses");
    b.setOrientation(parsed);
    b.distance = cast(float) j["distance"].floating;
    b.focus    = Vec3(cast(float) j["focus"]["x"].floating,
                      cast(float) j["focus"]["y"].floating,
                      cast(float) j["focus"]["z"].floating);

    assert(b.orientation.m == a.orientation.m,
           "the rotation must survive the round trip bit-exactly");
    assert(b.viewport().view == a.viewport().view,
           "and so must every lane of the view matrix it renders");
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

unittest { // viewportWith(own-inputs) == viewport() for ortho Top
    auto v = new View(0, 0, 800, 600);
    v.projKind   = ProjKind.Ortho;
    v.viewPreset = ViewPreset.Top;
    v.focus      = Vec3(1, 2, 3);
    v.distance   = 4.0f;
    v.azimuth    = 0.3f;
    v.elevation  = 0.2f;
    auto vp1 = v.viewport();
    auto vp2 = v.viewportWith(v.focus, v.distance, v.orientation);
    assert(isClose(vp1.eye.x, vp2.eye.x, 1e-5f) &&
           isClose(vp1.eye.y, vp2.eye.y, 1e-5f) &&
           isClose(vp1.eye.z, vp2.eye.z, 1e-5f),
           "viewportWith(own-inputs) eye must equal viewport() eye (ortho Top)");
    assert(vp1.view == vp2.view, "viewportWith(own-inputs) view must match viewport() (ortho Top)");
    assert(vp1.proj == vp2.proj, "viewportWith(own-inputs) proj must match viewport() (ortho Top)");
}

unittest { // viewportWith(own-inputs) == viewport() for perspective
    auto v = new View(0, 0, 800, 600);
    v.focus    = Vec3(0.5f, 0, -1.0f);
    v.distance = 6.0f;
    v.azimuth  = 1.2f;
    v.elevation = -0.3f;
    auto vp1 = v.viewport();
    auto vp2 = v.viewportWith(v.focus, v.distance, v.orientation);
    assert(isClose(vp1.eye.x, vp2.eye.x, 1e-5f) &&
           isClose(vp1.eye.y, vp2.eye.y, 1e-5f) &&
           isClose(vp1.eye.z, vp2.eye.z, 1e-5f),
           "viewportWith(own-inputs) eye must equal viewport() eye (perspective)");
    assert(vp1.view == vp2.view, "viewportWith(own-inputs) view must match viewport() (persp)");
    assert(vp1.proj == vp2.proj, "viewportWith(own-inputs) proj must match viewport() (persp)");
}

unittest { // toJsonWith(own-inputs) == toJson() after one viewport() call
    import std.json : parseJSON;
    auto v = new View(0, 0, 800, 600);
    v.focus    = Vec3(1, 0, 0);
    v.distance = 5.0f;
    v.azimuth  = 0.7f;
    v.elevation = 0.1f;
    v.viewport();  // prime the member eye
    string j1 = v.toJson();
    string j2 = v.toJsonWith(v.focus, v.distance, v.orientation);
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

unittest { // a level camera is the SAME camera the eye/target build produced
    // RE-BASELINED, deliberately, and this comment is the record of it.
    //
    // This assertion used to be `got.view == want` — bit equality against
    // `lookAt(focus + sphericalToCartesian(az, el, d), focus, +Y)` — and it
    // guarded the reference-comparison corpus (17 move legs / 18 rotate legs)
    // against moving by an ulp. Bit equality is UNATTAINABLE once the rotation
    // is stored, and the reason is a defect in what it was pinning: `lookAt`
    // derives its basis from `normalize(center - eye)`, so the matrix it
    // returned depended on the DISTANCE (it normalises a vector `d` long, and
    // scaling changes the rounding) and on the FOCUS (`center - eye`
    // re-rounds when the focus sits far from the origin). A rotation has
    // neither. Reproducing the old bits would mean reproducing both
    // dependencies, i.e. not storing a rotation at all.
    //
    // The residual is MEASURED, not assumed: over this sweep the nine
    // rotation lanes differ by at most 4.2e-7 and the three translation lanes
    // by at most 5.7e-7 of the distance — a few ulps, ~1e-6 of a world unit on
    // a 1.5-unit camera, some five orders below one pixel at this viewport
    // size. The corpus claim is now carried by RUNNING the corpus, and the
    // rendered-pixel claim by the framebuffer-digest probe, rather than by a
    // proxy that can no longer be true.
    auto v = new View(0, 0, 1098, 966);
    float worstRot = 0, worstTransRel = 0;
    int lookAtVariedWithFocus = 0;
    foreach (a; [-2.7f, -0.5040186f, 0.0f, 0.5f, 1.9f])
    foreach (e; [-1.5f, -0.4f, 0.0f, 0.4138754f, 1.5f]) {
        v.azimuth = a; v.elevation = e; v.distance = 1.486323332f;
        v.focus = Vec3(0.25f, -0.5f, 2.0f);
        v.roll = 0.0f;
        Viewport got = v.viewport();
        Vec3 off = sphericalToCartesian(a, e, v.distance);
        float[16] want = lookAt(v.focus + off, v.focus, Vec3(0, 1, 0));
        foreach (i; [0, 1, 2, 4, 5, 6, 8, 9, 10]) {
            immutable float dd = abs(got.view[i] - want[i]);
            if (dd > worstRot) worstRot = dd;
        }
        foreach (i; [12, 13, 14]) {
            immutable float rel = abs(got.view[i] - want[i]) / v.distance;
            if (rel > worstTransRel) worstTransRel = rel;
        }
        // The old oracle could only ever have held by replaying the focus
        // dependence. Show it was there: the SAME rotation about the origin
        // gives `lookAt` a different basis.
        float[16] atOrigin = lookAt(off, Vec3(0, 0, 0), Vec3(0, 1, 0));
        foreach (i; [0, 4, 8, 1, 5, 9, 2, 6, 10])
            if (atOrigin[i] != want[i]) { lookAtVariedWithFocus++; break; }
    }
    assert(worstRot <= 4.2e-7f,
           "a level camera's view basis must match the eye/target build to a few ulps");
    assert(worstTransRel <= 5.7e-7f,
           "a level camera's view translation must match to a few ulps of the distance");
    assert(lookAtVariedWithFocus >= 19,
           "the eye/target build really did make the BASIS depend on the focus — "
           ~ "if that stops being true, bit equality is back on the table and "
           ~ "this re-baseline must be revisited");
}

unittest { // the rotation no longer depends on where the camera is or how far
    // The property bought by the ulps above, and the one that makes them a
    // correction. Same orbit, four different focus/zoom combinations: one
    // orientation, bit-identical, every time.
    auto v = new View(0, 0, 1098, 966);
    v.azimuth = -0.5040186f; v.elevation = 0.4138754f; v.roll = 0.2055634f;
    immutable Orientation want = v.orientation;
    foreach (d; [0.3f, 1.486323332f, 42.0f])
    foreach (f; [Vec3(0, 0, 0), Vec3(0.25f, -0.5f, 2.0f), Vec3(-900, 17, 3.5f)]) {
        v.distance = d;
        v.focus    = f;
        assert(v.orientation.m == want.m,
               "the stored rotation must not move when the camera zooms or pans");
        // ...and the rendered basis is that rotation, exactly.
        Viewport vp = v.viewport();
        assert(rightRowOf(vp).x == want.m[0] && rightRowOf(vp).y == want.m[1] &&
               rightRowOf(vp).z == want.m[2],
               "the view matrix screen-right must be the stored rotation's column");
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
    Vec3 flat = v.panDeltaWith(100, 0, Orientation.fromAngles(v.azimuth, v.elevation, 0.0f));
    Vec3 bank = v.panDeltaWith(100, 0, Orientation.fromAngles(v.azimuth, v.elevation, r));
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
    Vec3 flat = v.panDeltaWith(100, 0, Orientation.fromAngles(v.azimuth, v.elevation, 0.0f));
    Vec3 bank = v.panDeltaWith(100, 0, Orientation.fromAngles(v.azimuth, v.elevation, 0.4f));
    assert(abs(dot(normalize(flat), normalize(bank)) - 1.0f) > 1e-4f,
           "ortho pan direction must follow the bank");
}

unittest { // rollBy keeps turning, and, unlike elevation, does not clamp
    auto v = new View(0, 0, 800, 600);
    assert(isClose(v.roll, 0.0f, 1e-6f, 1e-6f), "a fresh camera is level");
    v.rollBy(100);
    assert(isClose(v.roll, 0.5f, 1e-5f), "rollBy is 0.005 rad/px");
    v.rollBy(-100);
    assert(isClose(v.roll, 0.0f, 1e-5f, 1e-5f), "rollBy is signed and reversible");

    // "Does not clamp" now means what it should mean. The bank used to be an
    // unbounded accumulator, so a full turn was witnessed by `roll > 2*PI`.
    // With the rotation stored as a matrix there is no accumulator to
    // overflow: a bank of 3*PI IS a bank of PI, the same camera, and the
    // derived chart reads it back in (-PI, PI]. The property worth pinning is
    // therefore the one that always mattered — the drag keeps turning past a
    // full circle instead of stopping — so: roll a whole turn and land back on
    // the starting camera, bit-close, having passed through the far side.
    Orientation start = v.orientation;
    bool passedHalfway = false;
    foreach (i; 0 .. 20) {                 // 20 * 100 px * 0.005 = 10 rad
        v.rollBy(100);
        if (i == 6) passedHalfway = true;  // ~3.5 rad, beyond half a turn
    }
    assert(passedHalfway, "the sweep must go past half a turn");
    Orientation want = start.rotatedAbout(start.forward(), 10.0f);
    foreach (i; 0 .. 9)
        assert(abs(v.orientation.m[i] - want.m[i]) < 1e-5f,
               "twenty steps of 0.5 rad must be a turn of exactly 10 rad — a "
               ~ "clamp would have parked the camera short of it");
    // ...and 10 rad is past a full circle, so the chart necessarily wrapped.
    assert(v.roll < 10.0f - 2.0f * PI + 1e-4f,
           "the derived bank reads back on the (-PI, PI] chart, not as an "
           ~ "unbounded accumulator");

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
    auto vp2 = v.viewportWith(v.focus, v.distance, v.orientation);
    assert(vp1.view == vp2.view, "banked viewportWith(own-inputs) must match viewport()");
    // ...and a DIFFERENT rotation must produce a different matrix, so the
    // equality above is not vacuous.
    auto vp3 = v.viewportWith(v.focus, v.distance,
                              Orientation.fromAngles(v.azimuth, v.elevation, 0.0f));
    assert(vp1.view != vp3.view, "the orientation argument must reach the matrix");

    auto o1 = parseJSON(v.toJson());
    auto o2 = parseJSON(v.toJsonWith(v.focus, v.distance, v.orientation));
    assert(isClose(o1["roll"].floating, o2["roll"].floating, 1e-5f),
           "toJsonWith must report the bank it rendered");
    assert(isClose(o1["roll"].floating, 0.4137f, 1e-5f),
           "/api/camera must publish the bank");
}

// ---------------------------------------------------------------------------
// Trackball gesture (task 0573)
// ---------------------------------------------------------------------------

version (unittest) {
    import trackball : setTrackballGlobal, resetTrackball, setTrackballMouseSpeed,
                       trackballRadius;

    // The two pane shapes every pane-dependent assertion runs on. The first is
    // the corpus viewport, where the WIDTH is the larger half-extent; the
    // second is a tall narrow pane where the HEIGHT is, and where the two
    // half-extents differ by 2.27x. One pane shape cannot tell a pane-tracking
    // radius from a constant, and a landscape-only pair cannot tell `max` from
    // `min`.
    private enum int kPaneWideW = 1098, kPaneWideH = 832;
    private enum int kPaneTallW =   82, kPaneTallH = 186;

    /// The angle a camera's view direction turned, in radians.
    private float backTurn(Orientation a, Orientation b) {
        import std.math : acos;
        float c = dot(a.back(), b.back());
        if (c >  1.0f) c =  1.0f;
        if (c < -1.0f) c = -1.0f;
        return acos(c);
    }

    /// A camera with the trackball switched on globally.
    private View trackballCamera(int w, int h) {
        setTrackballGlobal(true);
        auto v = new View(0, 0, w, h);
        assert(v.trackballActive(), "the fixture camera must run the trackball");
        return v;
    }

    /// The same, but LEVEL — elevation and bank both zero.
    ///
    /// Worth its own helper because the angle chart is only a faithful readout
    /// of this gesture at a level camera. The trackball rotates about an axis
    /// fixed in the SCREEN, and at a tilted camera the screen's vertical is not
    /// the world's, so a horizontal drag legitimately moves the chart's
    /// elevation as well as its heading. That is the documented difference
    /// between a trackball and a turntable, not a defect — the tests that want
    /// to talk in azimuth/elevation/roll therefore start level, and the ones
    /// that hold at ANY camera are stated as frame invariants instead.
    private View levelTrackballCamera(int w, int h) {
        auto v = trackballCamera(w, h);
        v.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
        return v;
    }
}

unittest { // a CENTRE press turns the camera the SAME WAY as the two-axis
           // orbit it replaces — which is what pins the sign
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;

    foreach (dx; [80, -80]) {
        auto tb = levelTrackballCamera(kPaneWideW, kPaneWideH);
        immutable float az0 = tb.azimuth;
        tb.trackballDown(cx, cy);
        tb.trackballMove(cx + dx, cy);

        // The same drag through the gesture it replaces, from the same camera.
        auto ob = new View(0, 0, kPaneWideW, kPaneWideH);
        ob.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
        ob.orbit(dx, 0);

        assert((tb.azimuth - az0) * (ob.azimuth - az0) > 0.0f,
               "a centre press must turn the heading the SAME WAY as orbit(); "
               ~ "an inverted sign here would flip every user's viewport the "
               ~ "moment they switched the preference on");
        assert(isClose(tb.elevation, 0.0f, 1e-4f, 1e-4f),
               "from LEVEL, a horizontal centre drag is a pure heading change");
        assert(isClose(tb.roll, 0.0f, 1e-4f, 1e-4f), "with no bank");
    }

    foreach (dy; [80, -80]) {
        auto tb = levelTrackballCamera(kPaneWideW, kPaneWideH);
        immutable float az0 = tb.azimuth;
        tb.trackballDown(cx, cy);
        tb.trackballMove(cx, cy + dy);

        auto ob = new View(0, 0, kPaneWideW, kPaneWideH);
        ob.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
        ob.orbit(0, dy);

        assert((tb.elevation - 0.0f) * (ob.elevation - 0.0f) > 0.0f,
               "a centre press must pitch the SAME WAY as orbit()");
        assert(isClose(tb.azimuth, az0, 1e-4f, 1e-4f),
               "from LEVEL, a vertical centre drag does not change the heading");
        assert(isClose(tb.roll, 0.0f, 1e-4f, 1e-4f), "with no bank");
    }
}

unittest { // the arc's AXIS is fixed in the screen — the invariant that holds
           // at ANY camera, tilted or not
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);

    // The default camera is TILTED (elevation 0.4), which is the point: these
    // three statements are about the rotation, not about the chart, so they
    // survive a camera the chart cannot describe cleanly.

    // Horizontal centre drag: the axis is the camera's own UP, so `up` is a
    // fixed vector of the rotation — invariant to the last bit.
    {
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Vec3 up0 = v.orientation.up();
        v.trackballDown(cx, cy);
        v.trackballMove(cx + 90, cy);
        immutable Vec3 up1 = v.orientation.up();
        assert(abs(dot(up0, up1) - 1.0f) < 1e-6f,
               "a horizontal centre drag rotates about SCREEN-UP, so screen-up "
               ~ "does not move");
        assert(abs(dot(v.orientation.back(), up0)) < 1e-6f,
               "and the view direction stays perpendicular to it");
    }

    // Vertical centre drag: the axis is SCREEN-RIGHT, so `right` is invariant.
    {
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Vec3 rt0 = v.orientation.right();
        v.trackballDown(cx, cy);
        v.trackballMove(cx, cy + 90);
        assert(abs(dot(rt0, v.orientation.right()) - 1.0f) < 1e-6f,
               "a vertical centre drag rotates about SCREEN-RIGHT");
    }

    // Outside press, tangential drag: the axis is the VIEW axis, so the camera
    // keeps looking at exactly the same point and only spins. This is the
    // sharpest statement of "outside the ball it banks" — and the two-axis
    // orbit cannot do it at any pixel.
    {
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Vec3 bk0 = v.orientation.back();
        immutable Vec3 rt0 = v.orientation.right();
        immutable int px = cx + cast(int)(2.0f * r);
        v.trackballDown(px, cy);
        v.trackballMove(px, cy + 200);
        assert(abs(dot(bk0, v.orientation.back()) - 1.0f) < 1e-6f,
               "an outside drag rotates about the VIEW axis: the camera does "
               ~ "not change where it looks");
        assert(dot(rt0, v.orientation.right()) < 0.999f,
               "it only spins — and it really did spin");
    }
}

unittest { // the centre RATE is speed/radius — NOT the two-axis orbit's 0.005
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);   // 521.55

    auto tb = trackballCamera(kPaneWideW, kPaneWideH);
    immutable Orientation before = tb.orientation;
    tb.trackballDown(cx, cy);
    tb.trackballMove(cx + 100, cy);
    immutable float got = backTurn(before, tb.orientation);

    // Closed form: a 100 px step from the centre subtends
    // atan(100 / sqrt(r^2 - 100^2)) on the ball.
    import std.math : atan;
    immutable float want = atan(100.0f / sqrt(r * r - 10000.0f));
    assert(isClose(got, want, 1e-3f), "the centre arc is atan(d / z0)");

    // ...and that is 2.6x SLOWER than the drag it replaces. Reusing the
    // two-axis orbit's flat 0.005 rad/px here is the single easiest way to
    // port this wrong: it looks plausible and is wrong at every pane size but
    // one.
    immutable float twoAxis = 100 * 0.005f;      // 0.5 rad
    assert(isClose(twoAxis / got, 2.585f, 1e-2f),
           "the trackball's centre rate is ~2.6x slower than 0.005 rad/px");
    assert(got < twoAxis * 0.5f, "and it is nowhere near it");
}

unittest { // the rate is PANE-DEPENDENT, on two sharply different pane shapes
    scope(exit) resetTrackball();
    resetTrackball();

    float centreTurn(int w, int h, int dx) {
        auto v = trackballCamera(w, h);
        immutable Orientation before = v.orientation;
        v.trackballDown(w / 2, h / 2);
        v.trackballMove(w / 2 + dx, h / 2);
        return backTurn(before, v.orientation);
    }

    import std.math : atan;
    float wantTurn(int w, int h, int dx) {
        immutable float r = trackballRadius(w, h);
        return atan(dx / sqrt(r * r - cast(float)dx * dx));
    }

    // Landscape pane: the WIDTH is the larger half-extent.
    immutable float wide = centreTurn(kPaneWideW, kPaneWideH, 10);
    assert(isClose(wide, wantTurn(kPaneWideW, kPaneWideH, 10), 1e-3f),
           "wide pane: the arc follows 0.95*w/2");

    // Portrait pane: the HEIGHT is. This is the shape that separates a radius
    // built on `max` from one built on `min` — they differ by 2.27x here.
    immutable float tall = centreTurn(kPaneTallW, kPaneTallH, 10);
    assert(isClose(tall, wantTurn(kPaneTallW, kPaneTallH, 10), 1e-3f),
           "tall pane: the arc follows 0.95*h/2, not 0.95*w/2");

    // The SAME pixel drag rotates ~5.9x further on the small pane. A rate that
    // did not track the pane would give a ratio of exactly 1.
    assert(tall / wide > 5.0f && tall / wide < 7.0f,
           "the same drag must rotate much further on a smaller pane");

    // And a radius built on the SMALLER half-extent would have given a
    // materially different answer on the tall pane — stated so the assertion
    // above cannot be satisfied by the wrong law.
    immutable float rMin  = 0.95f * kPaneTallW / 2.0f;          // 38.95
    immutable float wrong = atan(10.0f / sqrt(rMin * rMin - 100.0f));
    assert(!isClose(tall, wrong, 5e-2f),
           "a min(w,h) radius is out by more than 5% on this pane");
}

unittest { // the bank blends continuously — it is NOT gated on leaving the ball
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);

    // From LEVEL, so the chart's `roll` is a faithful readout of the arc's
    // view-axis content. SIGNED — see the sign block below.
    float signedBankAt(float frac, int dy) {
        auto v = levelTrackballCamera(kPaneWideW, kPaneWideH);
        immutable int px = cx + cast(int)(frac * r);
        v.trackballDown(px, cy);
        v.trackballMove(px, cy + dy);
        return v.roll;
    }
    float bankAt(float frac) { return abs(signedBankAt(frac, 40)); }

    // THE BANK'S SIGN, which is not a free choice: the arc comes from ONE
    // formula whose overall sense is already pinned at the centre (against the
    // two-axis orbit), and the bank is the same formula continued outward, so
    // the sign here is forced. Asserting it is what catches a camera-frame axis
    // carried into world space through the wrong basis column — a mutation that
    // leaves the orbit limits untouched and silently runs the bank backwards.
    //
    // The sense, in the hand: grab the ball on its right and push down, and the
    // model turns clockwise on screen — the grabbed point follows the cursor,
    // which is the same "the model follows you" the centre press has. On the
    // chart that reads as a NEGATIVE bank.
    assert(signedBankAt(0.5f,  40) < 0.0f, "press right, drag down -> bank -");
    assert(signedBankAt(0.5f, -40) > 0.0f, "press right, drag up   -> bank +");
    assert(signedBankAt(-0.5f, 40) > 0.0f, "press left,  drag down -> bank +");
    // Mirroring the press and the drag together must return the same bank.
    assert(isClose(signedBankAt(0.5f, 40), signedBankAt(-0.5f, -40), 1e-4f),
           "the gesture is symmetric under mirroring both press and drag");

    // Every one of these presses is INSIDE the circle, where the shipped
    // description says the gesture "just orbits". It banks at all of them, and
    // it banks more the further out the press is.
    immutable float b25 = bankAt(0.25f);
    immutable float b50 = bankAt(0.50f);
    immutable float b90 = bankAt(0.90f);
    assert(b25 > 1e-4f, "a press a quarter of the way out already banks");
    assert(b50 > b25 && b90 > b50,
           "and the bank grows monotonically with the press radius, with no "
           ~ "cliff at the rim");
    // The centre is the one place it is exactly zero.
    assert(bankAt(0.0f) < 1e-6f, "only a dead-centre press is bank-free");
    // The blend is roughly linear in the press radius (the closed form is
    // exactly rho/r; `source/trackball.d` pins that to 1 %). Here it is enough
    // to show the ratio reaches the camera rather than being flattened.
    assert(isClose(b50 / b25, 2.0f, 5e-2f),
           "twice the press radius is twice the bank");
}

unittest { // a degenerate step leaves the ANCHOR where it was
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);
    immutable int px = cx + cast(int)(1.2f * r);   // outside the rim

    // Press outside, wander straight OUTWARD along the ray, then drag
    // tangentially. Every outward step lifts to the SAME rim vector — that is
    // the hard rim clamp's signature, and a hyperbolic sheet would rotate here
    // because its z keeps changing with the press radius.
    auto a = trackballCamera(kPaneWideW, kPaneWideH);
    a.trackballDown(px, cy);
    immutable Orientation afterPress = a.orientation;
    a.trackballMove(px + 100, cy);
    a.trackballMove(px + 400, cy);
    foreach (i; 0 .. 9)
        assert(a.orientation.m[i] == afterPress.m[i],
               "dragging straight outward beyond the rim must not move the "
               ~ "camera by a single bit");
    a.trackballMove(px + 400, cy + 150);

    // The same press taken straight to the tangential position. The excursion
    // must have left no trace at all. (This does NOT pin the reference's
    // "do not advance the anchor" ordering — a degenerate step is one where the
    // two lifted vectors are equal, so that ordering is unobservable; see
    // `trackballStep`.)
    auto b = trackballCamera(kPaneWideW, kPaneWideH);
    b.trackballDown(px, cy);
    b.trackballMove(px + 400, cy + 150);

    foreach (i; 0 .. 9)
        assert(abs(a.orientation.m[i] - b.orientation.m[i]) < 1e-6f,
               "an outward excursion beyond the rim must leave no trace");
    // ...and (a) is not vacuously equal to its own press state.
    bool moved = false;
    foreach (i; 0 .. 9)
        if (abs(a.orientation.m[i] - afterPress.m[i]) > 1e-3f) moved = true;
    assert(moved, "the tangential step must have actually rotated the camera");
}

unittest { // the ball is centred on the PANE, not on the window
    scope(exit) resetTrackball();
    resetTrackball();

    // A cell parked away from the window origin — a Split/Quad layout's
    // right-hand or bottom cell. Pressing at the CELL's centre must be the
    // bank-free case; pressing at the window centre must not be.
    setTrackballGlobal(true);
    auto v = new View(640, 360, 800, 600);
    v.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
    assert(v.trackballActive(), "fixture");

    v.trackballDown(640 + 400, 360 + 300);      // the cell's centre
    v.trackballMove(640 + 480, 360 + 300);
    assert(isClose(v.roll, 0.0f, 1e-4f, 1e-4f),
           "the cell centre must be the bank-free point, so the pane rect's "
           ~ "origin has to be subtracted before the lift");

    auto w = new View(640, 360, 800, 600);
    w.setOrientation(Orientation.fromAngles(0.5f, 0.0f, 0.0f));
    w.trackballDown(400, 300);                  // the WINDOW centre — far off-pane
    w.trackballMove(480, 300);
    assert(abs(w.roll) > 1e-3f,
           "a press at the window centre is nowhere near the cell centre and "
           ~ "must bank — otherwise the subtraction is not happening");
}

unittest { // the speed multiplier scales the rate AND shrinks the circle
    scope(exit) resetTrackball();
    resetTrackball();

    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    immutable float r = trackballRadius(kPaneWideW, kPaneWideH);

    // Rate: at the centre, twice the speed is twice the arc (to first order).
    float centreArc(float speed) {
        setTrackballMouseSpeed(speed);
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Orientation before = v.orientation;
        v.trackballDown(cx, cy);
        v.trackballMove(cx + 5, cy);
        return backTurn(before, v.orientation);
    }
    immutable float a1 = centreArc(1.0f);
    immutable float a2 = centreArc(2.0f);
    assert(isClose(a2 / a1, 2.0f, 5e-3f), "speed scales the rate");

    // Circle: a press at 60 % of the radius is INSIDE at speed 1 (so the arc
    // keeps a view-direction component) and ON THE RIM at speed 2 (so it is a
    // pure spin and the view direction is invariant).
    float viewMove(float speed) {
        setTrackballMouseSpeed(speed);
        auto v = trackballCamera(kPaneWideW, kPaneWideH);
        immutable Vec3 bk0 = v.orientation.back();
        immutable int px = cx + cast(int)(0.6f * r);
        v.trackballDown(px, cy);
        v.trackballMove(px, cy + 40);
        return 1.0f - dot(bk0, v.orientation.back());
    }
    assert(viewMove(1.0f) > 1e-5f,
           "at speed 1 a press at 0.6r is inside, so the view direction moves");
    assert(viewMove(2.0f) < 1e-6f,
           "at speed 2 the same pixel is on the rim: pure spin, view direction "
           ~ "fixed — the multiplier shrank the circle, not just the rate");
}

unittest { // the option gates the gesture, and ortho is excluded outright
    scope(exit) resetTrackball();
    resetTrackball();

    auto v = new View(0, 0, kPaneWideW, kPaneWideH);
    assert(!v.trackballActive(), "shipped default is off");

    v.trackballOption = TrackballOption.On;
    assert(v.trackballActive(), "a per-cell On overrides the global");

    // Ortho: excluded regardless of the option. The reference's rotation gate
    // never writes its trackball flag for the ortho view type; this is the
    // observable half of that.
    v.projKind = ProjKind.Ortho;
    assert(!v.trackballActive(), "an ortho cell never runs the trackball");
    v.projKind = ProjKind.Perspective;
    assert(v.trackballActive(), "and it comes back when the cell does");

    // reset() returns the cell to deferring to the global.
    v.reset();
    assert(v.trackballOption == TrackballOption.Default,
           "reset() must clear the per-cell override");
    assert(!v.trackballActive(), "so a reset cell follows the (off) global");
}

unittest { // a motion event with no press does nothing at all
    scope(exit) resetTrackball();
    resetTrackball();

    auto v = trackballCamera(kPaneWideW, kPaneWideH);
    assert(!v.trackballArmed(), "a fresh camera is not armed");
    immutable Orientation before = v.orientation;
    v.trackballMove(100, 100);
    foreach (i; 0 .. 9)
        assert(v.orientation.m[i] == before.m[i],
               "an unarmed move must not touch the camera");

    v.trackballDown(200, 200);
    assert(v.trackballArmed(), "the press arms it");
    v.trackballCancel();
    assert(!v.trackballArmed(), "and cancelling disarms it");
    v.trackballMove(300, 300);
    foreach (i; 0 .. 9)
        assert(v.orientation.m[i] == before.m[i],
               "a move after cancel must not touch the camera either");
}

unittest { // the composed rotation stays a clean rotation over a long gesture
    scope(exit) resetTrackball();
    resetTrackball();

    // 400 motion events around a circle well inside the ball — the case where
    // an incremental composition would accumulate drift if the write funnel's
    // re-normalisation were not doing its job.
    import std.math : sin, cos;
    auto v = trackballCamera(kPaneWideW, kPaneWideH);
    immutable int cx = kPaneWideW / 2, cy = kPaneWideH / 2;
    v.trackballDown(cx + 200, cy);
    foreach (i; 1 .. 401) {
        immutable float t = i * 0.05f;
        v.trackballMove(cx + cast(int)(200 * cos(t)), cy + cast(int)(200 * sin(t)));
    }
    assert(v.orientation.orthonormalityDefect() < 1e-5f,
           "400 composed steps must leave an orthonormal camera");
    // ...and it actually went somewhere, so the assertion is not vacuous.
    auto fresh = new View(0, 0, kPaneWideW, kPaneWideH);
    bool moved = false;
    foreach (i; 0 .. 9)
        if (abs(v.orientation.m[i] - fresh.orientation.m[i]) > 1e-3f) moved = true;
    assert(moved, "the sweep must have actually rotated the camera");
}
