// ---------------------------------------------------------------------------
// TRACKBALL VIEWPORT NAVIGATION — one drag that orbits AND banks, with which
// one you get decided by WHERE on the pane the press landed.
//
// The ordinary orbit drag is two-axis: horizontal pixels turn the heading,
// vertical pixels turn the pitch, and the horizon never tilts. The trackball
// replaces that with a virtual sphere sitting in the pane: the press point and
// every subsequent cursor point are lifted onto the sphere, and the camera is
// rotated by the arc between them. Press near the middle and the arc lies in
// the screen plane, so you get a pure orbit; press near the edge and the arc is
// about the view axis, so you get a pure bank. In between you get a mixture,
// and the mixture is CONTINUOUS — this is the single most misdescribed thing
// about the gesture, including in the reference's own documentation, which says
// "inside the circle it orbits, outside it rolls" as though the two were
// separate modes. They are the two LIMITS of one formula (see `trackballStep`).
//
// This module is the LAW and nothing else: the circle, the lift onto the
// sphere, the arc between two lifted points, and the option that selects the
// gesture. It owns no camera. `View.trackballDown` / `View.trackballMove`
// (source/view.d) supply the pane rect and apply the arc to the stored
// orientation; that split is what lets every constant below be tested in closed
// form, against the law's own limits, with no camera and no viewport.
//
// Why a leaf module rather than members of `view.d`: the option is reached by
// `prefs.d` (persistence), `commands/prefs/trackball.d` (the setting),
// `registration.d` (the factory) and `view.d` (the gesture), and a leaf with
// only a `math` import lets all four reach it without importing each other.
// This mirrors `coord_rounding.d` exactly, for the same reason.
//
// THE MOMENTUM SPIN — the decaying turn a release leaves behind — is the last
// section of this module. It was held out of the gesture's own commit because
// it needs a per-frame camera tick this editor did not have; the tick now
// exists (source/app.d's main loop, one bool wide when nothing spins) and the
// two curves are here in closed form. It changes nothing about the gesture
// above: it only keeps applying arcs after the button is up.
// ---------------------------------------------------------------------------
module trackball;

import math : Vec3, cross, dot;
import std.math : sqrt, atan2, isFinite, sin, PI;

// ---------------------------------------------------------------------------
// The circle
// ---------------------------------------------------------------------------

/// The fraction of the pane half-extent the ball's radius takes.
///
/// Measured, not chosen: the reference recomputes the radius from the pane on
/// every view validate as `0.95 * max(w/2, (h/2)/aspect)`, and four different
/// pane sizes in one trace gave four radii all consistent with this factor and
/// with no other.
enum float kTrackballRadiusFraction = 0.95f;

/// The trackball circle's radius, in PIXELS, for a pane of `w` x `h` pixels.
///
/// **95 % of the half-extent of the LARGER dimension**, and the "larger" is the
/// whole point: half of the SMALLER dimension is the obvious guess, it is what
/// most published arcballs use, and it is wrong here by up to a factor of 2.3
/// on a tall narrow pane. It also produces a visibly different gesture: with
/// `max`, a ball on a landscape pane is TALLER than the pane, so you can never
/// leave it by dragging vertically, and the only regions outside it are the
/// four corners plus two thin strips at the left and right edges. That is
/// exactly the reference's own described feel ("orbit in the middle, drag out
/// toward a corner and it banks") and it is not what `min` would give.
///
/// The general form the reference computes is `0.95 * max(w/2, (h/2)/aspect)`,
/// where `aspect` is a per-view field. It is identically 1.0 for a 3D view —
/// that is a measurement (every one of the ~40 sites that sets it is a 2D view:
/// UV, rulers, sliders, graph editor), not an assumption — so the aspect term
/// is folded to 1 here rather than carried as a parameter no caller can vary.
/// If a non-square-pixel 3D view ever exists, the boundary generalises from a
/// circle to the ellipse `(x-cx)^2 + ((y-cy)/aspect)^2 = r^2` and this is the
/// one function that changes.
float trackballRadius(int w, int h) @safe pure nothrow @nogc {
    immutable float halfW = (w > 0 ? w : 0) * 0.5f;
    immutable float halfH = (h > 0 ? h : 0) * 0.5f;
    return kTrackballRadiusFraction * (halfW > halfH ? halfW : halfH);
}

// ---------------------------------------------------------------------------
// The lift: a pane pixel becomes a vector on the ball
// ---------------------------------------------------------------------------

/// Lift a pane-local pixel onto the ball, in the CAMERA frame: `x` is
/// screen-right, `y` is screen-UP, `z` points out of the screen at the viewer.
/// That is deliberately the same column order as `math.Orientation`
/// (right / up / back), so the caller maps the result into world space by a
/// plain basis combination with no sign fixups.
///
/// `x`, `y` are pane-local pixels with SDL's Y-DOWN sense; `cx`, `cy` are the
/// pane centre (`w/2`, `h/2`); `radius` is `trackballRadius`; `speed` is the
/// user's speed multiplier.
///
/// **Hemisphere inside, hard clamp to the rim outside** — this is Shoemake's
/// arcball, NOT the Bell/Holroyd hyperbolic sheet that most later arcballs use.
/// The difference is not cosmetic and it is not a tolerance: Bell/Holroyd
/// switches to a hyperbola at `r/sqrt(2)` and never reaches `z == 0` at any
/// finite radius, so it can never produce a pure bank, and it disagrees with
/// this by 27 % of the radius at a press only 10 % inside the rim. There is no
/// `r/sqrt(2)` knee here; the branch is at `r` and the outside arm is a plain
/// normalisation onto the rim.
///
/// **The speed multiplier scales the pixel offsets BEFORE the radius test**,
/// which is why it is an argument here and not applied to the resulting angle.
/// It therefore does two things at once: it scales the rate, AND it shrinks the
/// effective circle to `radius / speed` pixels. Applying it to the angle
/// instead would scale the rate and leave the circle alone — a plausible
/// reading that is measurably wrong.
Vec3 trackballVector(float x, float y, float cx, float cy,
                     float radius, float speed) @safe pure nothrow @nogc
{
    immutable float px =  (x - cx) * speed;
    immutable float py = -(y - cy) * speed;   // pane Y is down; the ball's is up
    immutable float d2 = px * px + py * py;
    immutable float r2 = radius * radius;
    // `>=`, so a press exactly on the rim takes the inside arm. Both arms agree
    // there (z -> 0 from inside, the clamp scale -> 1 from outside): the lift is
    // continuous across the boundary. Its DERIVATIVE is not — dz/dd goes to
    // -infinity at the rim from inside and is identically 0 outside — which is
    // the honest shape of "there is a hard branch here".
    if (r2 >= d2) return Vec3(px, py, sqrt(r2 - d2));
    immutable float d = sqrt(d2);
    immutable float k = radius / d;
    return Vec3(px * k, py * k, 0.0f);
}

// ---------------------------------------------------------------------------
// The arc: two lifted points become a rotation
// ---------------------------------------------------------------------------

/// The rotation carrying the ball from `v0` to `v1`: the axis (in the CAMERA
/// frame, unit length) and the angle in radians, both `out`. Returns false and
/// writes nothing meaningful when the step is degenerate.
///
/// On a false return the caller should also leave `v0` alone rather than
/// advance it to `v1`, which is the order the reference uses — it returns before
/// storing the new previous-vector.
///
/// **That ordering is faithful but NOT independently observable, and saying so
/// is worth more than a test that pretends otherwise.** A step is degenerate
/// exactly when `v1 x v0` vanishes; both vectors have length `radius` by
/// construction, so that happens exactly when `v1 == v0` — and storing a value
/// equal to the one already there is the same write. Mutating the caller to
/// advance the anchor on a degenerate step was tried against the whole suite
/// and SURVIVED, which is the correct outcome rather than a gap. What IS
/// observable, and is tested, is the consequence: outside the ball every point
/// on a ray lifts to the same rim vector, so dragging straight outward from the
/// rim is step after degenerate step and moves the camera not at all.
///
/// Roll content, which is the part worth stating explicitly: the axis is
/// `v1 x v0`, so its VIEW-AXIS component is `x1*y0 - y1*x0`. At a centre press
/// `v0 = (0,0,r)` and that component is exactly zero — pure orbit. At a rim
/// press both vectors have `z == 0` and the axis is entirely the view axis —
/// pure bank. Everywhere between, it is non-zero for any non-radial drag and
/// grows monotonically with the press radius. So bank accrues at EVERY non-zero
/// press radius; "inside orbits, outside banks" describes the two limits, not
/// the implementation.
///
/// The angle is `atan2(|v1 x v0|, dot(v1, v0))` rather than
/// `acos(dot(v1,v0) / r^2)`. These are the same number — both lifted vectors
/// have length exactly `radius`, which is what lets the reference divide by
/// `r^2` and skip the norms — but `acos` near 1 loses about half the mantissa,
/// and the common case of this gesture is a one-pixel step where the argument
/// IS near 1. `atan2` is well conditioned across the whole range and needs no
/// clamp against float dust pushing the cosine outside [-1, 1]. The deviation
/// is in conditioning only, not in the law.
bool trackballStep(Vec3 v0, Vec3 v1, out Vec3 axis, out float angle)
    @safe pure nothrow @nogc
{
    immutable Vec3 c = cross(v1, v0);
    immutable float cl = c.length;
    // `!(cl > 0)` rather than `cl <= 0` so a NaN (which compares false against
    // everything) is caught here instead of reaching the camera.
    if (!(cl > 0.0f)) return false;
    axis  = c * (1.0f / cl);
    angle = atan2(cl, dot(v1, v0));
    if (!isFinite(angle)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// The option
// ---------------------------------------------------------------------------

/// Per-viewport trackball selection. `Default` defers to the global setting;
/// the other two are explicit per-cell overrides. The integers are the wire
/// values, so a persisted file stays readable if an arm is ever added.
enum TrackballOption : int {
    Default = -1,
    Off     =  0,
    On      =  1,
}

/// The shipped default for the global setting.
///
/// **OFF, and this is a port decision rather than a reading.** The reference's
/// resolution rule was read exactly (see `resolveTrackball`) but the DEFAULT
/// VALUE of its global was not, so there is nothing to copy. Off is the choice
/// that makes "nothing changes for a user who does not use this gesture" true
/// by construction rather than by measurement: with it off, the orbit drag runs
/// the same two-axis code it always did and this module is never entered. If
/// the reference's default is later measured to be on, this is the one constant
/// that moves.
enum bool kTrackballDefault = false;

/// The shipped speed multiplier. Measured: the reference initialises its pair
/// of multipliers (one for a mouse, one for a tablet) to 1.0 in code, not in a
/// config file. At 1.0 the effective pixel circle is exactly `trackballRadius`.
enum float kTrackballSpeedDefault = 1.0f;

/// Guard rails on the speed multiplier. NOT from the reference — a port-side
/// clamp, because this multiplier reaches the camera's stored rotation and a
/// non-finite or absurd value there is unrecoverable: the orientation's
/// re-normalisation would fall through its degenerate arms and silently re-aim
/// the camera rather than fail. A zero or negative speed is also nonsense (zero
/// collapses every pixel onto the pane centre, so the gesture becomes a no-op).
enum float kTrackballSpeedMin = 0.01f;
enum float kTrackballSpeedMax = 100.0f;

// ---------------------------------------------------------------------------
// Momentum spin: the spin a release leaves behind
// ---------------------------------------------------------------------------

/// The curve a released spin follows. Both are `rate * K * sin(t/K)` for a
/// curve-specific time constant `K`; they differ ONLY in `K` — and by a factor
/// of exactly ten, which is what turns a spin that dies into one that swings
/// for ever (see `spinEnded`).
enum SpinCurve : int { Settle = 0, Swing = 1 }

/// The SETTLE curve's time constant in MILLISECONDS: `8000/pi`.
///
/// Read, not fitted. The curve is `angle(t) = rate * A * sin(t/A)`, so the
/// angular RATE is `rate * cos(t/A)` — it starts at exactly the release rate
/// (the spin is continuous with the drag that armed it, which is the whole
/// feel of the gesture) and reaches zero when `t/A == pi/2`.
enum double kSettleTimeMs = 8000.0 / PI;          // 2546.4790894703256

/// ...and that zero is at `A * pi/2` = **exactly 4000 ms**. A round number out
/// of two irrational-looking ones is the tell that `8000/pi` is the real
/// constant and 2546.479 is its decimal shadow.
enum double kSettleDurationMs = 4000.0;

/// The SWING curve's time constant, ms: `800/pi` — Settle's, divided by ten.
enum double kSwingTimeMs = 800.0 / PI;              // 254.64790894703253

/// The swing's full period, `2*pi*C` = **1600 ms**. It NEVER terminates: the
/// angle keeps travelling between `+rate*C` and `-rate*C` until a press cancels
/// it. That is not a decay with a long tail — it is an undamped oscillation,
/// which is why `spinEnded` has to answer differently for the two arms rather
/// than comparing both against one duration.
enum double kSwingPeriodMs = 1600.0;

/// The curve's time constant, ms.
double spinTimeConstant(SpinCurve p) @safe pure nothrow @nogc {
    final switch (p) {
        case SpinCurve.Settle: return kSettleTimeMs;
        case SpinCurve.Swing:  return kSwingTimeMs;
    }
}

/// The CUMULATIVE angle, in radians, `tMs` after a release that armed a spin of
/// `rate` rad/ms. Cumulative rather than incremental on purpose: a frame tick
/// applies `spinAngle(now) - spinAngle(then)`, so the total is a closed form of
/// the clock alone and a dropped frame, a long frame or a burst of short ones
/// all land on the same camera. Accumulating per-frame increments instead would
/// make the spin's total depend on the frame rate.
///
/// Before the release (`tMs <= 0`, and any NaN) the angle is zero. After
/// Settle's 4000 ms it is pinned at `rate * A` — the total the curve is heading
/// for — so a tick that arrives late still lands exactly there instead of
/// stepping past the top of the sine and running backwards.
double spinAngle(SpinCurve p, double rate, double tMs) @safe pure nothrow @nogc {
    if (!(tMs > 0.0)) return 0.0;
    immutable double k = spinTimeConstant(p);
    if (p == SpinCurve.Settle && tMs >= kSettleDurationMs)
        return rate * k;
    return rate * k * sin(tMs / k);
}

/// Has the curve finished at `tMs`? Settle ends; Swing does not.
bool spinEnded(SpinCurve p, double tMs) @safe pure nothrow @nogc {
    final switch (p) {
        case SpinCurve.Settle: return tMs >= kSettleDurationMs;
        case SpinCurve.Swing:    return false;
    }
}

/// The shipped choice between the two curves.
///
/// **A port decision, like `kTrackballDefault`.** What is read is the SELECTOR
/// — the reference picks the swinging arm off a navigation flag — not that
/// flag's shipped value. Settle is the only arm that terminates, so it is the
/// one that ships: a spin that never stops is not something to hand a user who
/// did not ask for it. If the reference's own default is later measured to be
/// the other arm, this constant is what moves.
enum bool kSpinSwingDefault = false;

private __gshared bool  g_trackball      = kTrackballDefault;
private __gshared bool  g_trackballGlobalOverride = false;
private __gshared float g_speedMouse     = kTrackballSpeedDefault;
private __gshared float g_speedTablet    = kTrackballSpeedDefault;
private __gshared bool  g_swing      = kSpinSwingDefault;

/// The swing setting: which curve a release arms.
bool trackballSwing() { return g_swing; }
void setTrackballSwing(bool v) { g_swing = v; }

/// The curve a release arms right now. One reader of the setting rather than a
/// `?:` at every arming site, so the two can never disagree.
SpinCurve activeSpinCurve() {
    return g_swing ? SpinCurve.Swing : SpinCurve.Settle;
}

/// The global trackball setting a `Default` cell defers to.
bool trackballGlobal() { return g_trackball; }
void setTrackballGlobal(bool v) { g_trackball = v; }

/// The global override: when set, EVERY viewport uses the global setting and
/// per-cell overrides are ignored.
bool trackballGlobalOverride() { return g_trackballGlobalOverride; }
void setTrackballGlobalOverride(bool v) { g_trackballGlobalOverride = v; }

/// Resolve a per-viewport option against the globals — the reference's own
/// rule, which is not the obvious one: the override does not force the
/// trackball ON, it forces every cell to READ THE GLOBAL, whatever the global
/// says. So the override with the global off turns the trackball off
/// everywhere, including in cells that explicitly asked for it.
bool resolveTrackball(TrackballOption opt) {
    if (opt == TrackballOption.Default || g_trackballGlobalOverride) return g_trackball;
    return opt == TrackballOption.On;
}

/// The mouse speed multiplier.
float trackballMouseSpeed() { return g_speedMouse; }

/// The tablet speed multiplier. The reference keeps a separate value and picks
/// between the two by querying the input device at press time; this editor has
/// no tablet input path, so the value round-trips through the settings and is
/// never selected. It exists so a profile written by a future tablet arm is not
/// silently dropped.
float trackballTabletSpeed() { return g_speedTablet; }

/// Clamp an incoming speed into the guarded band, rejecting non-finite. Kept
/// separate from the setters so persistence can sanitise a hand-edited file
/// through the identical path the command uses.
float clampTrackballSpeed(float v) @safe pure nothrow @nogc {
    if (!isFinite(v)) return kTrackballSpeedDefault;
    if (v < kTrackballSpeedMin) return kTrackballSpeedMin;
    if (v > kTrackballSpeedMax) return kTrackballSpeedMax;
    return v;
}

void setTrackballMouseSpeed(float v)  { g_speedMouse  = clampTrackballSpeed(v); }
void setTrackballTabletSpeed(float v) { g_speedTablet = clampTrackballSpeed(v); }

/// Restore every global to its shipped default.
///
/// **Deliberately NOT called by `/api/reset`.** These are user settings, not
/// scene state, and `/api/reset` shares its handler with File → New — resetting
/// a preference there would mean opening a new document silently changed how
/// the viewport navigates. The coordinate-rounding setting made the same call
/// for the same reason. The consequence is that a TEST which flips one of these
/// has to put it back; `tests/test_trackball.d` does, through `scope(exit)`.
/// The PER-CELL override is different — that is camera state, and `View.reset`
/// does clear it.
void resetTrackball() {
    g_trackball               = kTrackballDefault;
    g_trackballGlobalOverride = false;
    g_speedMouse              = kTrackballSpeedDefault;
    g_speedTablet             = kTrackballSpeedDefault;
    g_swing               = kSpinSwingDefault;
}

/// Wire name for an option value — stable, lowercase, what the setting command
/// takes and what a profile stores.
string trackballOptionName(TrackballOption o) @safe pure nothrow {
    final switch (o) {
        case TrackballOption.Default: return "default";
        case TrackballOption.Off:     return "off";
        case TrackballOption.On:      return "on";
    }
}

/// Parse a wire name. Returns false (leaving `out_` untouched) on an
/// unrecognised name, so a caller can report the error rather than land on an
/// arm nobody asked for.
bool parseTrackballOption(string s, out TrackballOption out_) @safe pure nothrow {
    switch (s) {
        case "default": out_ = TrackballOption.Default; return true;
        case "off":     out_ = TrackballOption.Off;     return true;
        case "on":      out_ = TrackballOption.On;      return true;
        default:        return false;
    }
}

// ---------------------------------------------------------------------------
// Tests — the law against its own limits
// ---------------------------------------------------------------------------

version (unittest) {
    import std.math : isClose, abs, cos;   // sin/PI come from the module import

    // The two pane aspect ratios every radius assertion runs on. The first is
    // the corpus viewport (landscape, WIDTH is the larger dimension). The
    // second is a tall narrow pane observed in a reference trace, and it is the
    // discriminating one: its two half-extents differ by 2.27x, so `max` and
    // `min` cannot both be right to any tolerance.
    private enum int kWideW = 1098, kWideH = 832;
    private enum int kTallW =   82, kTallH =  186;
}

unittest { // the radius follows the LARGER half-extent, on both pane shapes
    // Landscape: width wins.
    immutable float rw = trackballRadius(kWideW, kWideH);
    assert(isClose(rw, 0.95f * kWideW / 2.0f), "wide pane radius = 0.95*w/2");
    assert(isClose(rw, 521.55f, 1e-6f), "wide pane radius is 521.55 px");
    // ...and it is NOT the smaller half-extent.
    assert(!isClose(rw, 0.95f * kWideH / 2.0f, 1e-3f),
           "wide pane radius must not track the height");

    // Portrait: HEIGHT wins. This is the row that separates max from min.
    immutable float rt = trackballRadius(kTallW, kTallH);
    assert(isClose(rt, 0.95f * kTallH / 2.0f), "tall pane radius = 0.95*h/2");
    assert(isClose(rt, 88.35f, 1e-5f), "tall pane radius is 88.35 px");
    immutable float wrongMin = 0.95f * kTallW / 2.0f;   // 38.95
    assert(rt > wrongMin * 2.2f,
           "min(w,h) would give 38.95 px — out by a factor of 2.27");

    // A square pane cannot tell the two apart, which is exactly why a test on
    // one pane shape proves nothing.
    assert(isClose(trackballRadius(400, 400), 0.95f * 200.0f),
           "square pane: max and min agree, so it discriminates nothing");

    // Degenerate panes must not produce a NaN radius.
    assert(trackballRadius(0, 0) == 0.0f, "0x0 pane has radius 0");
    assert(trackballRadius(-5, -5) == 0.0f, "negative pane clamps to 0");
}

unittest { // the lift is Shoemake's, and a hyperbolic sheet would fail here
    immutable float r = trackballRadius(kWideW, kWideH);   // 521.55
    immutable float cx = kWideW * 0.5f, cy = kWideH * 0.5f;

    // A ladder of press radii as a FRACTION of r, walking from the centre out
    // past the rim. `rho <= 0.7071` is where Shoemake and Bell/Holroyd agree,
    // so a test that stopped there would not discriminate; the rungs beyond it
    // are the ones that do.
    static immutable float[] rungs = [0.0f, 0.25f, 0.5f, 0.70710678f,
                                      0.9f, 1.0f, 1.5f, 3.0f];
    foreach (frac; rungs) {
        immutable float rho = frac * r;
        immutable Vec3 v = trackballVector(cx + rho, cy, cx, cy, r, 1.0f);
        // Every lifted vector has length exactly the radius — inside by
        // Pythagoras, outside by the rim clamp. This is what lets the arc be
        // computed without normalising either vector.
        assert(isClose(v.length, r, 1e-5f),
               "lift must land on the sphere of radius r at every rung");

        immutable float wantZ = (frac <= 1.0f)
            ? r * sqrt(1.0f - frac * frac)     // hemisphere
            : 0.0f;                            // hard rim clamp
        assert(isClose(v.z, wantZ, 1e-4f, 1e-4f),
               "Shoemake hemisphere inside, z == 0 outside");

        // What a Bell/Holroyd sheet would have produced at this rung. Beyond
        // the knee it never reaches zero, so it can never yield a pure bank.
        immutable float bellZ = (frac <= 0.70710678f)
            ? r * sqrt(1.0f - frac * frac)
            : r / (2.0f * frac);
        if (frac > 0.70710678f)
            assert(!isClose(v.z, bellZ, 1e-2f),
                   "a hyperbolic sheet must be visibly wrong past the knee");
    }

    // The single sharpest rung, stated as a number: 10 % inside the rim, the
    // two laws differ by 27 % of the radius.
    immutable Vec3 v90 = trackballVector(cx + 0.9f * r, cy, cx, cy, r, 1.0f);
    assert(isClose(v90.z, 0.43589f * r, 1e-4f), "Shoemake at 0.9r");
    assert(isClose(0.5555556f * r, r / 1.8f, 1e-5f), "Bell at 0.9r, for contrast");
    assert(abs(v90.z - r / 1.8f) > 0.11f * r, "the two laws are 27% of r apart");
}

unittest { // the lift is continuous across the rim; its DERIVATIVE is not
    immutable float r = trackballRadius(kWideW, kWideH);   // 521.55
    // Centre at the origin so the offsets below are not eaten by float spacing
    // at a large coordinate (one ulp at x = 1100 is already 1.2e-4 px).
    immutable float cx = 0.0f, cy = 0.0f;

    immutable Vec3 inside  = trackballVector(r - 0.01f, 0, cx, cy, r, 1.0f);
    immutable Vec3 outside = trackballVector(r + 0.01f, 0, cx, cy, r, 1.0f);
    assert(isClose(inside.x, outside.x, 1e-4f), "x is continuous at the rim");
    assert(outside.z == 0.0f, "z is identically 0 outside");
    assert(inside.z > 0.0f && inside.z < 0.01f * r, "z is small just inside");

    // The approach to zero is SQRT, not linear — z ~ sqrt(2*r*delta) — which is
    // the infinite derivative stated as a measurement: shrink the offset by
    // 100x and z falls by only 10x. A linear (C1) transition, which is what a
    // hyperbolic sheet is chosen to give, would fall by 100x.
    immutable float zNear = trackballVector(r - 0.01f, 0, cx, cy, r, 1.0f).z;
    immutable float zFar  = trackballVector(r - 1.00f, 0, cx, cy, r, 1.0f).z;
    assert(isClose(zFar / zNear, 10.0f, 1e-2f),
           "z approaches the rim as sqrt(offset): 100x closer is 10x smaller");

    // The pane Y sense is flipped on the way in: a pixel BELOW the centre lifts
    // to a NEGATIVE ball y.
    immutable Vec3 below = trackballVector(cx, cy + 50.0f, cx, cy, r, 1.0f);
    assert(below.y < 0.0f, "pane Y is down; the ball's Y is up");
}




unittest { // the arc's angle is the angle between the lifted vectors
    immutable float r  = 500.0f;
    immutable float cx = 600.0f, cy = 500.0f;
    Vec3 axis; float angle;

    // Two rim points a known angle apart: the arc must be exactly that angle,
    // about the view axis.
    foreach (deg; [5.0f, 30.0f, 90.0f, 150.0f]) {
        immutable float th = deg * cast(float)PI / 180.0f;
        immutable Vec3 v0 = trackballVector(cx + 2.0f * r, cy, cx, cy, r, 1.0f);
        immutable Vec3 v1 = trackballVector(cx + 2.0f * r * cos(th),
                                            cy - 2.0f * r * sin(th),
                                            cx, cy, r, 1.0f);
        assert(trackballStep(v0, v1, axis, angle), "rim-to-rim step is well defined");
        assert(isClose(angle, th, 1e-4f), "the arc angle is the rim angle");
        assert(isClose(abs(axis.z), 1.0f, 1e-5f), "about the view axis");
    }

    // The centre rate: for a small drag from the centre the angle per pixel is
    // speed/radius. On the corpus pane that is 1/521.55 = 0.00192 rad/px — a
    // number worth pinning, because the ordinary two-axis orbit's rate is a
    // flat 0.005 rad/px and reusing THAT constant here gives a viewport that
    // spins 2.6x too fast, and does so at every pane size but one.
    immutable float rc = trackballRadius(kWideW, kWideH);
    immutable Vec3 c0 = trackballVector(549.0f, 416.0f, 549.0f, 416.0f, rc, 1.0f);
    immutable Vec3 c1 = trackballVector(550.0f, 416.0f, 549.0f, 416.0f, rc, 1.0f);
    assert(trackballStep(c0, c1, axis, angle), "one-pixel centre step");
    assert(isClose(angle, 1.0f / rc, 1e-3f), "centre rate is speed/radius rad/px");
    assert(angle < 0.005f * 0.5f, "and it is far slower than the two-axis orbit");
}
