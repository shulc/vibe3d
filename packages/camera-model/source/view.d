module view;

import math;
import vibe3d.util.spatial.spatial : Orientation, Viewport, isOrtho, viewMatrixFrom;
import std.math : sqrt, tan, PI, isFinite;
import std.json : JSONValue, JSONType;
import vibe3d.util.spatial.trackball : TrackballOption, resolveTrackball, trackballRadius,
                   trackballVector, trackballStep, trackballMouseSpeed,
                   SpinCurve, spinAngle, spinEnded, activeSpinCurve;

/// Projection kind for the camera. Default Perspective.
/// Ortho sets an axis-locked viewpoint; orbit is disabled.
enum ProjKind { Perspective, Ortho }

/// Named view preset driving the axis-locked ortho orientation.
/// Camera and Perspective both use the free spherical camera.
enum ViewPreset { Perspective, Top, Bottom, Front, Back, Left, Right, Camera }

/// The SCREEN BASIS of an axis-locked preset: which world direction points
/// right, and which points up, when a cell renders that preset.
///
/// Returns `false` for `Perspective` / `Camera`, which name no axis — an
/// ortho cell on either keeps its free orbit, and there is no basis to hand
/// back. **The two `out` parameters are then UNTOUCHED, i.e. `Vec3.init`,
/// whose components are NaN** (`float.init`), so a caller that ignores the
/// return value gets a silently poisoned basis rather than a zero. Check it.
///
/// Lifted out of `View.effectiveOrientation` (task 0612 §4.3), which is its
/// first caller and stays behaviourally identical — this is the code that
/// decides where an ortho cell actually looks from, so anything that has to
/// agree with the camera about "which way is up in the Front view" must read
/// the SAME table. The second caller is `image_plane.resolvePlacement`: a
/// reference-image plane's two half-extent vectors are `right` and `up`
/// scaled, and a hand-written second copy of this table would be one sign
/// error away from a mirrored reference image that still looks plausible.
bool presetBasis(ViewPreset p, out Vec3 right, out Vec3 up) @safe pure nothrow @nogc {
    final switch (p) {
        case ViewPreset.Top:
            right = Vec3( 1, 0, 0); up = Vec3(0, 0,-1); return true;
        case ViewPreset.Bottom:
            right = Vec3( 1, 0, 0); up = Vec3(0, 0, 1); return true;
        case ViewPreset.Front:
            right = Vec3( 1, 0, 0); up = Vec3(0, 1, 0); return true;
        case ViewPreset.Back:
            right = Vec3(-1, 0, 0); up = Vec3(0, 1, 0); return true;
        case ViewPreset.Right:
            right = Vec3( 0, 0,-1); up = Vec3(0, 1, 0); return true;
        case ViewPreset.Left:
            right = Vec3( 0, 0, 1); up = Vec3(0, 1, 0); return true;
        case ViewPreset.Perspective:
        case ViewPreset.Camera:
            return false;
    }
}

/// Serialise a camera orientation as a nine-element JSON array, LOSSLESSLY.
///
/// `%.9g` is not decoration: nine significant decimal digits is the round-trip
/// precision of a 32-bit float, so the parsed value is the SAME float, bit for
/// bit. The `%f` (six fixed decimals) every other camera field uses loses
/// roughly seven of the mantissa's bits — fine for an angle a human reads, not
/// fine for the matrix that IS the camera, where a lossy round trip means the
/// horizon quietly tilts a little on every save and load.
/// The nine values go out through `jsonNum` (task 1550) so a non-finite
/// orientation prints `null` instead of the bare token `nan`, which is not
/// JSON. The `%.9g` is handed over EXPLICITLY at every one of the nine —
/// `jsonNum` has no default specifier, exactly so this precision cannot be
/// erased by a call that forgets to state it.
string orientationToJson(Orientation o) {
    import std.format : format;
    import vibe3d.util.json_number.json_num   : jsonNum;
    return format("[%s,%s,%s,%s,%s,%s,%s,%s,%s]",
                  jsonNum(o.m[0], "%.9g"), jsonNum(o.m[1], "%.9g"),
                  jsonNum(o.m[2], "%.9g"), jsonNum(o.m[3], "%.9g"),
                  jsonNum(o.m[4], "%.9g"), jsonNum(o.m[5], "%.9g"),
                  jsonNum(o.m[6], "%.9g"), jsonNum(o.m[7], "%.9g"),
                  jsonNum(o.m[8], "%.9g"));
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
    enum float defaultFovY = 45.0f * PI / 180.0f;
    private float fovY_ = defaultFovY;
    @property float fovY() const { return fovY_; }

    // One per-cell lens funnel proves positive finite projection coefficients
    // for every positive signed-int pane (10790; camera_intrinsics_test).
    static float validatedFovY(double supplied) {
        import std.exception : enforce;
        enforce(isFinite(supplied) && supplied > 0 && supplied < PI,
                "'fovY' must be finite and between zero and PI radians");
        const narrowed = cast(float)supplied;
        enforce(isFinite(narrowed) && narrowed > 0 && cast(double)narrowed < PI,
                "'fovY' is outside the float lens domain");
        const float tangent = tan(narrowed * 0.5f);
        const float f = 1.0f / tangent;
        enum float aMin = cast(float)1 / cast(float)int.max;
        enum float aMax = cast(float)int.max / cast(float)1;
        const float horizontalMin = f / aMin;
        const float horizontalMax = f / aMax;
        enforce(isFinite(tangent) && tangent > 0 && isFinite(f) && f > 0 &&
                isFinite(horizontalMin) && horizontalMin > 0 &&
                isFinite(horizontalMax) && horizontalMax > 0,
                "'fovY' cannot represent a positive finite projection for all positive panes");
        return narrowed;
    }
    void setFovY(double supplied) { fovY_ = validatedFovY(supplied); }

    /// **The camera's rotational truth.** A full 3x3 (see `spatial.Orientation`),
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

    // Task 7139 (gap 187): the pinned work plane's world basis columns
    // (local X, Y = normal, Z), read only by `effectiveOrientation`. Derived
    // from the work plane, never serialised (not in toJson, prefs or .v3d);
    // written by `ViewportManager.applyPlaneFrame`.
    private Vec3[3] planeAxes_ = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    private bool    planeTurned_;

    /// True when this camera's view turns with a pinned plane: an ortho cell
    /// on an axis preset. An ortho cell on the free Perspective/Camera preset
    /// has no preset basis, does not turn, and so counts with perspective for
    /// the focus transition (task 7139; no such cell exists at the reference).
    bool turnsWithPlane() const {
        Vec3 r, u;
        return projKind == ProjKind.Ortho && presetBasis(viewPreset, r, u);
    }

    /// Express the ortho presets in a pinned plane's frame (`on`), or in the
    /// world frame again. `x`, `y`, `z` are the plane's world axes.
    void setPlaneTurn(bool on, Vec3 x, Vec3 y, Vec3 z) {
        planeTurned_ = on;
        planeAxes_ = [x, y, z];
    }

    this(int x, int y, int w, int h) { setSize(w, h); setPos(x, y); }
    void setSize(int w, int h) { width = w; height = h; }
    void setPos(int x, int y) { this.x = x; this.y = y; }
    void reset() {
        // One chart write, not four: setting the three angles one at a time
        // would round-trip the matrix through the chart three times and leave
        // the default camera a few ulps off the literal default orientation.
        orient_    = Orientation.fromAngles(0.5f, 0.4f, 0.0f);
        fovY_      = defaultFovY;
        distance   =  3.0f;
        focus      =  Vec3(0, 0, 0);
        projKind   = ProjKind.Perspective;
        viewPreset = ViewPreset.Perspective;
        // The per-cell trackball override and any in-flight arming go back to
        // launch state too: a cell left explicitly On by one test is exactly
        // the kind of setting that resurfaces as an unrelated failure later.
        trackballOption = TrackballOption.Default;
        tbArmed_        = false;
        // A running settling spin is in-flight gesture state as well, and it is
        // the one piece that would keep WRITING this camera after the reset:
        // File → New with a spin still running would re-aim the camera it just
        // put back. Stopped here, not merely disarmed.
        spinCancel();
        tbHaveStep_     = false;
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

    /// The LAST composed step: its world axis, its angle, and the clock
    /// readings of the last two motion events that produced a step. This is
    /// everything a release needs to compute the momentum it hands to the spin,
    /// and it is written ONLY by a step that actually rotated the camera — a
    /// degenerate motion event advances neither the angle nor the stamps, which
    /// is the reference's own ordering (it returns before storing them).
    private Vec3   tbLastAxis_;
    private float  tbLastAngle_   = 0.0f;
    private uint   tbStepMs_      = 0;
    private uint   tbPrevStepMs_  = 0;
    private bool   tbHaveStep_    = false;

    /// A running settling spin: the WORLD axis it turns about, the release rate in
    /// rad/ms, the clock at the release, and how much of the profile's angle
    /// has already been applied.
    ///
    /// The axis is stored in WORLD space and never re-derived, and that is not
    /// a shortcut: a spin about a camera-frame axis and a spin about the world
    /// axis it maps to at the release are the SAME motion, because
    /// `R(O·a, t)·O == O·R(a, t)` and `O·R(a,t)·a == O·a` — the axis of a
    /// rotation is fixed by that rotation. Re-deriving it every frame would
    /// only add drift.
    private Vec3        tbSpinAxis_;
    private double      tbSpinRate_    = 0.0;
    private uint        tbSpinStartMs_ = 0;
    private double      tbSpinApplied_ = 0.0;
    private SpinCurve tbSpinCurve_ = SpinCurve.Settle;
    private bool        tbSpinning_    = false;

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
    /// `nowMs` is the app's millisecond clock at this motion event. It is used
    /// for NOTHING but the release momentum (`trackballRelease`), so a caller
    /// that has no clock — and every unit test that does not care about the
    /// spin — can pass the same value twice and get the documented consequence:
    /// two motion events sharing a timestamp leave no spin.
    void trackballMove(int mx, int my, uint nowMs) {
        if (!tbArmed_) return;
        immutable Vec3 v1 = ballVectorAt(mx, my);
        Vec3 axisCam; float angle;
        // A degenerate step leaves the ANCHOR alone as well as the camera,
        // which is the reference's own ordering. It is faithful rather than
        // load-bearing — a degenerate step is exactly one where the two lifted
        // vectors are equal, so advancing would write the same value — and
        // `trackballStep`'s doc records the mutation that proved it.
        //
        // It leaves the MOMENTUM stamps alone too, and there that ordering IS
        // observable: dragging out along a ray outside the ball is step after
        // degenerate step, and it must neither add angle nor advance the clock
        // the release divides by.
        if (!trackballStep(tbPrev_, v1, axisCam, angle)) return;
        immutable Vec3 axisWorld = orient_.right() * axisCam.x
                                 + orient_.up()    * axisCam.y
                                 + orient_.back()  * axisCam.z;
        orient_ = orient_.rotatedAbout(axisWorld, angle);
        tbPrev_ = v1;

        tbLastAxis_   = axisWorld;
        tbLastAngle_  = angle;
        tbPrevStepMs_ = tbStepMs_;
        tbStepMs_     = nowMs;
        tbHaveStep_   = true;
    }

    version (unittest) {
        /// A motion event with NO clock, for the tests that are about the
        /// gesture's geometry and not about its momentum. Every step then
        /// carries the same stamp, so by the documented rule the release
        /// momentum is zero and no spin can leak sideways into a test that
        /// never mentions one. Deliberately unittest-only: product code has a
        /// clock and must pass it.
        void trackballMove(int mx, int my) { trackballMove(mx, my, 0); }
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

    // -----------------------------------------------------------------------
    // Momentum spin: the spin a release leaves behind
    // -----------------------------------------------------------------------

    /// Arm a settling spin from the momentum of the drag that just ended.
    /// `nowMs` is the app's millisecond clock at the release — the epoch
    /// `spinTick` will measure against.
    ///
    /// **The rate is the LAST STEP's, not the whole drag's average**: the angle
    /// of the final composed arc divided by the interval between the last two
    /// motion events that produced one. So a drag that decelerates into the
    /// release leaves a slow spin and a flick leaves a fast one, which is the
    /// entire point of the gesture — an average over the drag would launch a
    /// camera the user had just brought to rest.
    ///
    /// **A still release leaves no spin.** Two motion events sharing a
    /// timestamp make the interval zero; the reference returns a rate of zero
    /// there rather than dividing, and so does this. That is the guard, and it
    /// is also the honest answer for a replayed session whose events all arrive
    /// in one frame.
    ///
    /// Momentum spin is TRACKBALL-ONLY (the reference's momentum block sits
    /// inside its trackball branch), so the gate is the same `trackballActive`
    /// the gesture itself is gated on — including the ortho exclusion, which
    /// this inherits for free rather than restating.
    ///
    /// NOT SETTLED, and not asserted anywhere: the reference reaches its
    /// momentum block only for one navigation-mode tag, and which chord that
    /// tag is was never identified. This editor arms the spin on the release of
    /// the drag that ran the trackball, which is the only navigation drag that
    /// can produce the state the momentum is computed from.
    void trackballRelease(uint nowMs) {
        if (!trackballActive()) return;
        if (!tbHaveStep_) return;
        // Unsigned, so an out-of-order or wrapped pair would read as an
        // enormous interval rather than a negative one; `<=` rejects both that
        // and the equal-stamp case in one test.
        if (tbStepMs_ <= tbPrevStepMs_) return;
        immutable double dt = cast(double)(tbStepMs_ - tbPrevStepMs_);
        immutable double rate = cast(double)tbLastAngle_ / dt;
        if (!(rate > 0.0)) return;

        tbSpinAxis_    = tbLastAxis_;
        tbSpinRate_    = rate;
        tbSpinStartMs_ = nowMs;
        tbSpinApplied_ = 0.0;
        tbSpinCurve_   = activeSpinCurve();
        tbSpinning_    = true;
    }

    /// Advance a running spin to the app clock `nowMs`. A no-op — one bool
    /// read, no clock arithmetic, no camera write — when nothing is spinning.
    ///
    /// The step applied is the DIFFERENCE of the curve's closed form at two
    /// clock readings, never an accumulation of per-frame increments: the
    /// camera a spin lands on is then a function of the wall clock alone, so a
    /// dropped frame or a 200 ms hitch costs the same total rotation as a
    /// smooth 60 Hz run. Accumulating increments would make the spin's total
    /// depend on the frame rate, which is the classic way this feature ends up
    /// travelling further on a fast machine.
    void spinTick(uint nowMs) {
        if (!tbSpinning_) return;
        // Unsigned difference: correct across the clock's 49-day wrap, and a
        // clock that somehow ran backwards reads as "long past the end", which
        // stops the spin rather than reversing it.
        immutable double t = cast(double)(nowMs - tbSpinStartMs_);
        immutable double want = spinAngle(tbSpinCurve_, tbSpinRate_, t);
        immutable double step = want - tbSpinApplied_;
        tbSpinApplied_ = want;
        if (step != 0.0)
            orient_ = orient_.rotatedAbout(tbSpinAxis_, cast(float)step);
        if (spinEnded(tbSpinCurve_, t)) spinCancel();
    }

    /// Stop a running spin dead. This is what a press does — the reference
    /// re-arms the spin with a rate of zero on every navigation press, which is
    /// the same observable — and what `reset` does.
    void spinCancel() {
        tbSpinning_    = false;
        tbSpinRate_    = 0.0;
        tbSpinApplied_ = 0.0;
    }

    /// Is a spin running on this camera? Read by the app's per-frame tick to
    /// decide whether the tick is needed at all, so unlike `trackballArmed`
    /// this one IS product state.
    bool spinning() const { return tbSpinning_; }

    /// The running spin's rate (rad/ms) and world axis. Test seams: they let a
    /// unittest predict the camera the spin must land on from the curve's
    /// closed form, instead of asserting the numbers the implementation
    /// happened to produce.
    double spinRate() const { return tbSpinRate_; }
    Vec3   spinAxis() const { return tbSpinAxis_; }

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
    ///
    /// With a pinned work plane (`setPlaneTurn`) the preset is expressed in the
    /// plane's frame — right/up become `B*right`/`B*up` — so an ortho preset
    /// cell TURNS with the plane while a perspective one does not (§23, gap
    /// 187, task 7139). The focus stays world; only the basis turns, here, and
    /// both `viewportWith` and `panDeltaWith` read it.
    private Orientation effectiveOrientation(Orientation o) const {
        if (projKind != ProjKind.Ortho) return o;
        Vec3 right, up;
        // An ortho cell that is not axis-locked (`Perspective` / `Camera`)
        // keeps the free orbit — that is exactly the `false` answer.
        if (!presetBasis(viewPreset, right, up)) return o;
        if (planeTurned_) {
            right = planeAxes_[0] * right.x + planeAxes_[1] * right.y + planeAxes_[2] * right.z;
            up    = planeAxes_[0] * up.x    + planeAxes_[1] * up.y    + planeAxes_[2] * up.z;
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
            localProj = perspectiveMatrix(fovY_,
                                          cast(float)width / height, 0.001f, 100.0f);
        }
        Viewport vp = Viewport(localView, localProj, width, height, x, y, localEye);
        vp.focus = f;
        Vec3 pr, pu;
        vp.axisPreset = presetBasis(viewPreset, pr, pu);
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
        import vibe3d.util.json_number.json_num   : jsonNum;
        Viewport vp = viewportWith(f, d, o);
        float a, e, r;
        o.toAngles(a, e, r);
        return format(
            `{"azimuth":%s,"elevation":%s,"distance":%s,"roll":%s,` ~
            `"orientation":%s,"fovY":%s,` ~
            `"focus":{"x":%s,"y":%s,"z":%s},` ~
            `"eye":{"x":%s,"y":%s,"z":%s},` ~
            `"width":%d,"height":%d,"vpX":%d,"vpY":%d}`,
            jsonNum(a, "%f"), jsonNum(e, "%f"), jsonNum(d, "%f"),
            jsonNum(r, "%f"),
            orientationToJson(o), jsonNum(fovY_, "%.9g"),
            jsonNum(f.x, "%f"), jsonNum(f.y, "%f"), jsonNum(f.z, "%f"),
            jsonNum(vp.eye.x, "%f"), jsonNum(vp.eye.y, "%f"),
            jsonNum(vp.eye.z, "%f"),
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
    void computeFrame(Vec3[] verts, out Vec3 outFocus, out float outDistance) const {
        computeFrame(verts, outFocus, outDistance,
                     projKind == ProjKind.Ortho ? defaultFovY : fovY_);
    }

    void computeFrame(Vec3[] verts, out Vec3 outFocus, out float outDistance,
                      float framingFovY) const
    {
        if (verts.length == 0) return;
        const float fovY = framingFovY;

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





// ---------------------------------------------------------------------------
