// The transform gizmo's AXIS ARM drag conversion, end to end (task 0562).
//
// `test_tool_move_drag.d` already pins that an X-arrow drag moves the
// selection in +X and nothing else. This file pins the CONVERSION — the five
// properties that make the ported law a different law from the one it
// replaced, each of them a thing a user can feel:
//
//   1. THE GAIN IS FLAT. The world length delivered is the view's one scalar
//      pixel size times the pixel run projected onto the arm's screen
//      direction. No foreshortening compensation, and 4/5 of the pixel size a
//      cursor-locked drag would use. The number is computed here from
//      /api/camera alone — eye distance and pane height — so this test states
//      the gain independently of the module that implements it.
//
//   2. IT IS CUMULATIVE FROM THE PRESS, AGAINST A FROZEN BASE. Drag out and
//      back to the press pixel and the mesh is EXACTLY where it started. The
//      incremental form this replaced cannot do that on an axis whose motion
//      changes depth: it re-projects the arm at the LIVE gizmo centre, which
//      the wrapper walks along with the selection on every motion event, so
//      the gain on the way out is not the gain on the way back. Measured, on
//      the default camera with the code reverted: a 0.345-unit excursion
//      leaves a 0.0024 residual — 0.7 %, and it does not cancel out over a
//      session, it accumulates.
//
//   3. IT IS SCOPED OUT OF `Screen`, AND THAT IS A HOLD. Under the Screen
//      action centre the ported law does not run and the editor's own
//      compensated conversion is kept — not because the reference is known to
//      do that, but because it is known NOT to be readable yet. The reference
//      wraps its translator under `Screen` in a DECORATOR whose
//      `GetNewPosition` forwards to the inner conversion — the one that was
//      ported — and then adds a file-scope hit-handle triple that nobody has
//      read. So the reference under `Screen` is neither law, and this test
//      pins that the port left `Screen` exactly where it found it. It is a
//      neutrality pin on a parked divergence, NOT a specification of Screen.
//
//   4. THE SCALAR IS ROUNDED, TO A STEP THAT IS A STAIRCASE IN THE ZOOM. The
//      reference rounds the axis coordinate before it becomes a world offset
//      (measured, 30 of 30 evaluations), and the step is not a constant: it
//      is the world length of ONE screen pixel rounded up onto a 1-2-5
//      ladder, so it is flat over a band of zooms and then jumps. Measured
//      over 18 zoom levels spanning 1024x, 29 rows scored, 29 match.
//
//      This test drives that ACROSS RUNGS — five camera distances chosen so
//      the step takes several distinct values — because a test that samples
//      one zoom cannot tell a staircase from a constant, and that is exactly
//      how a constant shipped here in the first place. The rounding LAW and
//      the ladder are pinned in `drag.d`'s unittests against the reference's
//      own rows; what is pinned here is that the term survives the whole tool
//      path at every rung and is not swallowed by the wrapper.
//
//   5. THE WHOLE TERM IS BEHIND A USER SETTING, AND ITS `None` IS EXACT. The
//      reference gates coordinate rounding on a five-valued preference whose
//      first value turns it off. The default is rounding ON; under `None` the
//      same gesture must deliver the raw gain, off the grid.
//
// No reference engine is booted and none is needed: (1)'s expected value is
// arithmetic on our own camera, (2)/(3) are relations between two of our own
// drags, (4)'s step is computed here from the camera by the reference's own
// formula, and (5) is a relation between two of our own drags.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math   : fabs, sqrt, tan, PI;
import std.conv   : to;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

void cmd(string c) { post(BASE ~ "/api/command", c); }

// `dist <= 0` keeps whatever camera /api/reset left; a positive value pushes
// the camera to that eye distance, which is how (4) walks the zoom staircase.
void setupAxisDrag(string acen, string rounding = "fine", double dist = 0) {
    post(BASE ~ "/api/reset", "");
    // Coordinate Rounding is selected EXPLICITLY in every scenario, never
    // inherited: the runner reuses one vibe3d per worker across test
    // binaries, and a test that left the setting somewhere else would make
    // every later one's grid assertion depend on the schedule. `fine` is also
    // the shipped default, so passing it is a statement, not a change.
    // An EMPTY string means "select nothing" — the one scenario that asserts
    // what the untouched default is.
    if (rounding.length) cmd("pref.coordRounding " ~ rounding);
    if (dist > 0) {
        post(BASE ~ "/api/camera",
             format(`{"azimuth":0.5,"elevation":0.4,"distance":%.6f}`, dist));
        Thread.sleep(120.msecs);
    }
    auto sel = post(BASE ~ "/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[6]}`));
    assert(parseJSON(cast(string)sel)["status"].str == "ok",
           "select failed: " ~ cast(string)sel);
    auto set = post(BASE ~ "/api/script", "tool.set move");
    assert(parseJSON(cast(string)set)["status"].str == "ok",
           "tool.set move failed: " ~ cast(string)set);
    Thread.sleep(200.msecs);
    cmd("actr." ~ acen);
    Thread.sleep(250.msecs);   // the gizmo must redraw for /api/tool/handles
}

// The reference's rounding step at THIS camera, from the camera alone: the
// world length of one screen pixel rounded UP onto the 1-2-5 ladder.
// Deliberately reimplemented here rather than imported, so this test states
// the law independently of the module that implements it — the same stance
// `viewWorldPerPixelFromCamera` takes for the gain.
double ladderCeil125(double x) {
    import std.math : log10, floor, fabs;
    if (!(x > 0)) return 0;
    const double e    = floor(log10(x));
    const double frac = log10(x) - e;
    static immutable double[4] ladder = [1.0, 2.0, 5.0, 10.0];
    foreach (m; ladder)
        if (log10(m) >= frac) return (10.0 ^^ e) * m;
    return (10.0 ^^ e) * 10.0;
}

double roundingStepFromCamera(CameraState c) {
    return ladderCeil125(viewWorldPerPixelFromCamera(c));
}

// The gain the port claims, from the camera and nothing else:
//   pixelScale = (4/5) * eyeDistance / focalPx,  focalPx = (h/2) / tan(fovY/2)
// with our hard-coded 45-degree vertical fov.
double viewWorldPerPixelFromCamera(CameraState c) {
    Vec3 d = Vec3(c.eye.x - c.focus.x, c.eye.y - c.focus.y, c.eye.z - c.focus.z);
    double dist    = sqrt(cast(double)dot(d, d));
    return 0.8 * dist / focalPxOf(c);
}

double focalPxOf(CameraState c) {
    return 0.5 * c.height / tan(22.5 * PI / 180.0);
}

// The gizmo pivot's depth along the view axis — what the editor's OWN
// conversion turns into world-per-pixel, and the number (3) predicts.
double pivotDepth(CameraState c, double[3] pivot) {
    Vec3 f = Vec3(c.focus.x - c.eye.x, c.focus.y - c.eye.y, c.focus.z - c.eye.z);
    double L = sqrt(cast(double)dot(f, f));
    return ((pivot[0] - c.eye.x) * f.x
          + (pivot[1] - c.eye.y) * f.y
          + (pivot[2] - c.eye.z) * f.z) / L;
}

double[3] toolPivot() {
    auto st = parseJSON(cast(string)get(BASE ~ "/api/tool/state"));
    return [st["pivot"].array[0].floating,
            st["pivot"].array[1].floating,
            st["pivot"].array[2].floating];
}

// The FIRST arm's screen position and the gizmo centre's, from the tool's own
// handle serialization. Taking the direction from the handles rather than from
// a world axis keeps this test correct under Screen, where the gizmo's basis
// is the screen frame and part 0 is not world +X.
void armGeometry(out int x0, out int y0, out double sx, out double sy) {
    double ax, ay, cx, cy; bool foundArm, foundCentre;
    fetchHandlePart(0, ax, ay, foundArm);
    fetchHandlePart(3, cx, cy, foundCentre);
    assert(foundArm && foundCentre,
           "the move gizmo's arm (part 0) or centre (part 3) is not in "
           ~ "/api/tool/handles — numbering or draw timing regressed");
    double dx = ax - cx, dy = ay - cy;
    double L  = sqrt(dx*dx + dy*dy);
    assert(L > 10.0, "the arm projects to nothing — camera is edge-on");
    sx = dx / L; sy = dy / L;
    x0 = cast(int)ax; y0 = cast(int)ay;
}

// A down + out-leg + (optional) back-leg + up log. `buildDragLog` only walks
// one way, and (2) needs the return trip in ONE gesture.
string dragLog(CameraState cam, int x0, int y0, int x1, int y1,
               int steps, bool andBack)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        cam.vpX, cam.vpY, cam.width, cam.height);
    double t = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x0, y0);
    int lastX = x0, lastY = y0;
    void leg(int ax, int ay, int bx, int by) {
        foreach (i; 1 .. steps + 1) {
            int x = ax + cast(int)((cast(double)(bx - ax) * i) / steps);
            int y = ay + cast(int)((cast(double)(by - ay) * i) / steps);
            t += 50.0;
            log ~= format(
                `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
                t, x, y, x - lastX, y - lastY);
            lastX = x; lastY = y;
        }
    }
    leg(x0, y0, x1, y1);
    if (andBack) leg(x1, y1, x0, y0);
    t += 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, lastX, lastY);
    return log;
}

// One gesture: press the arm, run `runPx` pixels along it (and optionally
// back), return the world displacement of the dragged vertex and how many
// pixels of the run actually landed on the arm's screen direction.
void oneArmDrag(string acen, int runPx, bool andBack,
                out double[3] delta, out double alongPx,
                out CameraState cam, out double[3] pivot,
                string rounding = "fine", double dist = 0)
{
    setupAxisDrag(acen, rounding, dist);
    cam   = fetchCamera(BASE);
    pivot = toolPivot();

    int x0, y0; double sx, sy;
    armGeometry(x0, y0, sx, sy);
    int x1 = x0 + cast(int)(runPx * sx);
    int y1 = y0 + cast(int)(runPx * sy);
    alongPx = (x1 - x0) * sx + (y1 - y0) * sy;

    auto pre = vertexPos(6, BASE);
    playAndWait(dragLog(cam, x0, y0, x1, y1, 20, andBack), BASE);
    auto post_ = vertexPos(6, BASE);
    foreach (k; 0 .. 3) delta[k] = post_[k] - pre[k];
}

double vlen3(double[3] d) { return sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]); }

unittest {  // 1. the delivered world length IS pixelScale * (pixels along the arm)
    double[3] d, pivot; double alongPx; CameraState cam;
    oneArmDrag("auto", 120, false, d, alongPx, cam, pivot);

    const double ps   = viewWorldPerPixelFromCamera(cam);
    const double want = ps * alongPx;
    const double got  = vlen3(d);
    assert(ps > 0 && alongPx > 10.0);

    assert(got > 0.05,
           "the arm drag did not engage at all (got " ~ got.to!string ~ ")");
    // 1 % is not slack for its own sake. Two terms live under it: the arm's
    // screen DIRECTION is differenced over a short step while `alongPx` is
    // laid along the drawn chord, and the delivered scalar is rounded to the
    // nearest 0.002 (a half-step is ~0.35 % of this run). Tightening this
    // would be pinning those two, not the gain. The gain itself is pinned
    // exactly, pre-snap, in `drag.d`.
    assert(fabs(got - want) <= 0.01 * want,
           format("the axis arm's gain must be the view's flat pixel scale: "
                ~ "want %.6f = pixelScale %.8f x %.3f px along the arm, got "
                ~ "%.6f (ratio %.4f). A ratio near 1.25 means the 4/5 was "
                ~ "dropped; a ratio that tracks the pivot's depth instead of "
                ~ "the eye distance means the foreshortening compensation is "
                ~ "back.", want, ps, alongPx, got, got / want));

    // The matrix sandwich around the reference's `t` collapses to "exactly one
    // position attribute changes". Under actr.auto the gizmo basis is world
    // XYZ and part 0 is +X, so exactly one WORLD component may move.
    assert(fabs(d[1]) < 1e-3 && fabs(d[2]) < 1e-3,
           format("an axis-arm drag must change exactly one component; "
                ~ "got (%.5f, %.5f, %.5f)", d[0], d[1], d[2]));
}

unittest {  // 2. out and back to the press pixel returns the mesh EXACTLY
    double[3] d, pivot; double alongPx; CameraState cam;
    oneArmDrag("auto", 160, true, d, alongPx, cam, pivot);

    const double excursion = viewWorldPerPixelFromCamera(cam) * alongPx;
    assert(excursion > 0.2,
           "the out leg is too short for this test to discriminate");

    foreach (k; 0 .. 3)
        assert(fabs(d[k]) < 2e-4,
               format("a drag that returns to its press pixel must deliver "
                    ~ "nothing: component %d moved by %.6f over an excursion "
                    ~ "of %.4f. A residual here means the conversion is "
                    ~ "incremental again — re-projected per event against a "
                    ~ "gizmo centre that walks with the selection — instead "
                    ~ "of cumulative from the press against a frozen base. "
                    ~ "The reverted code leaves 0.0024 here.",
                    k, d[k], excursion));
}

unittest {  // 3. Screen is HELD at its pre-port behaviour, not re-specified
    double[3] d, pivot; double alongPx; CameraState cam;
    oneArmDrag("screen", 120, false, d, alongPx, cam, pivot);

    const double got   = vlen3(d);
    const double flat  = viewWorldPerPixelFromCamera(cam) * alongPx;
    // The value `Screen` produced BEFORE this port, recomputed from the camera:
    // the editor's own law is `axisLen/|s|` world units per projected pixel,
    // which for an arm lying in the screen plane (Screen's basis IS the screen
    // frame) is exactly the pivot's depth over the focal length. This is a
    // CHARACTERIZATION of what we already did, not a claim about the reference.
    const double comp  = alongPx * pivotDepth(cam, pivot) / focalPxOf(cam);

    assert(got > 0.05, "the Screen-mode arm drag did not engage");

    // The content of this test: the ported law did NOT reach Screen.
    assert(fabs(got - flat) > 0.05 * flat,
           format("under actr.screen the arm must NOT deliver the ported "
                ~ "law's flat gain — the port is scoped out there. Got %.6f "
                ~ "against a flat prediction of %.6f. (If these two are close "
                ~ "because the camera cannot tell the laws apart — the "
                ~ "compensated prediction is %.6f — the test is vacuous here "
                ~ "and the camera or pivot must move, which is the other way "
                ~ "this assertion fires.)", got, flat, comp));

    // And it is held at exactly the value it had before, so this change is
    // behaviour-neutral under Screen. Deliberately NOT phrased as "the
    // reference does this": the reference's Screen translator is a decorator
    // that FORWARDS to the ported conversion and then adds an unread
    // hit-handle term, so what Screen should deliver is an open question and
    // this number is not an answer to it — it is the value we parked on while
    // the question stays open.
    assert(fabs(got - comp) <= 0.015 * comp,
           format("actr.screen must be left exactly as the port found it: the "
                ~ "editor's own compensated conversion, %.6f (= %.3f px x "
                ~ "depth %.4f / focal %.2f), got %.6f. A change here means "
                ~ "the port leaked into a mode it was scoped out of, or that "
                ~ "Screen was re-specified without the read that would "
                ~ "justify it.",
                comp, alongPx, pivotDepth(cam, pivot), focalPxOf(cam), got));
}

unittest {  // 4. the delivered length lands on the step — ACROSS THE STAIRCASE
    // The rounding law and the ladder are pinned on the scalar in drag.d
    // against the reference's own rows. This pins that the term is still
    // there at the far end of the tool path — through the wrapper, the
    // command, and the mesh write — because a step that is computed and then
    // averaged away by a downstream blend is worth nothing.
    //
    // SAMPLED ACROSS RUNGS, and that is the content this test gained. The
    // step is a staircase in the zoom, so five camera distances spanning 8x
    // put the drag on several different rungs; a run at one zoom cannot
    // distinguish the law from the constant that used to be here, and this
    // test's earlier form could not. Each distance also drives THREE pixel
    // runs: landing on a multiple is exact when the term is present and, when
    // it is absent, fails for any run whose raw value is not within 1 % of a
    // step by chance. One run could pass by luck; fifteen cannot.
    //
    // 8x is the span, not a round number for its own sake: the widest gap on
    // the 1-2-5 ladder is 2.5x, so 8x crosses at least two rung boundaries
    // whatever pane the harness happens to give us — which is what makes the
    // "at least 3 distinct" assertion below safe rather than lucky. The lower
    // end stops at 1.5 because at 0.75 the gizmo no longer projects at all
    // (every handle's `screen` comes back null) and the test would be
    // measuring the near plane.
    double[] stepsSeen;
    foreach (dist; [1.5, 2.4, 3.0, 6.0, 12.0]) {
        foreach (runPx; [96, 117, 141]) {
            double[3] d, pivot; double alongPx; CameraState cam;
            oneArmDrag("auto", runPx, false, d, alongPx, cam, pivot,
                       "fine", dist);

            // The step this camera implies, computed here from /api/camera by
            // the reference's own formula — never read out of the editor.
            const double q = roundingStepFromCamera(cam);
            assert(q > 0, "the camera implies no rounding step at all");
            stepsSeen ~= q;

            const double got = vlen3(d);
            assert(got > 0.02,
                   format("the %d px arm drag at distance %.2f did not engage "
                        ~ "(got %.9f)", runPx, dist, got));

            const double n   = got / q;
            const double off = fabs(n - cast(double)cast(long)(n + 0.5));
            assert(off * q < 2e-5,
                   format("the axis arm's delivered length must land on the "
                        ~ "view's own rounding step: at eye distance %.3f the "
                        ~ "step is %.9g, and a %d px run delivered %.9f = "
                        ~ "%.4f steps — %.8f off the nearest one. The "
                        ~ "reference rounds the SCALAR before it becomes a "
                        ~ "world offset (measured 30/30); a value off the "
                        ~ "grid means the step was dropped, computed from the "
                        ~ "wrong quantity, applied to the position instead of "
                        ~ "the scalar, or averaged out downstream.",
                        dist, q, runPx, got, n, off * q));
        }
    }

    // And the sampling really did cross rungs. Without this the loop above
    // would pass unchanged against a hard-coded constant — which is the
    // defect that shipped here, and the reason a one-zoom test could not see
    // it. Five distances spanning 16x must not all share one step.
    import std.algorithm : sort, uniq;
    import std.array     : array;
    auto distinct = stepsSeen.dup.sort.uniq.array;
    assert(distinct.length >= 3,
           format("this test must sample the staircase across RUNGS: five "
                ~ "eye distances spanning 8x produced only %d distinct "
                ~ "step(s) (%s). With one rung the assertion above cannot "
                ~ "tell the ported law from a constant.",
                distinct.length, distinct));
}

unittest {  // 5. the whole term is behind the setting, and `None` is exact
    // The rounding is a user preference with five values, shipped ON at the
    // one-pixel step. `None` is not a fine grid — it is the exact identity,
    // which is the only thing that makes running a quantisation-blind
    // regression test under it legitimate rather than a fudge.
    //
    // WHAT THIS PINS AND WHAT IT DOES NOT, because the two are different and
    // the difference was found by mutation, not by argument. What this pins
    // is that the SETTING REACHES the tool path: a call site that ignored the
    // mode and always rounded fails the off-grid assertion below, and a
    // default of `None` fails the last one. What it does NOT pin is the
    // EXACTNESS of the identity — a `None` that secretly rounded to 1e-4
    // passes everything here, because 1e-4 is far inside the 1 % the raw-gain
    // prediction has to allow (the screen direction is finite-differenced at
    // the base, and the pixel endpoints are integers). Exactness is pinned
    // BITWISE where a bitwise claim can be made: `drag.d`'s gate unittest
    // asserts `axisArmDelta(..., None) == axisArmDeltaUnsnapped(...)` with
    // `==`, and a step of 1e-9 there fails it. Do not "strengthen" the
    // tolerance below to try to cover that — it would only make this test
    // flaky about the finite difference.
    //
    // Same gesture, same camera, same everything except the setting.
    enum int RUN = 117;

    double[3] dOn, pivotOn; double alongOn; CameraState camOn;
    oneArmDrag("auto", RUN, false, dOn, alongOn, camOn, pivotOn, "fine");
    double[3] dOff, pivotOff; double alongOff; CameraState camOff;
    oneArmDrag("auto", RUN, false, dOff, alongOff, camOff, pivotOff, "none");

    const double q      = roundingStepFromCamera(camOn);
    const double gotOn  = vlen3(dOn);
    const double gotOff = vlen3(dOff);
    assert(gotOn > 0.05 && gotOff > 0.05, "one of the two drags did not engage");
    assert(fabs(alongOn - alongOff) < 1e-9,
           "the two runs must be the same gesture for this comparison to mean "
           ~ "anything");

    // ON: on the grid (this is (4)'s property, restated here so the pair is
    // read together).
    const double nOn = gotOn / q;
    assert(fabs(nOn - cast(double)cast(long)(nOn + 0.5)) * q < 2e-5,
           format("with rounding on, %d px must land on the step %.9g; got "
                ~ "%.9f = %.4f steps", RUN, q, gotOn, nOn));

    // OFF: the raw gain, and specifically NOT on the grid. The predicted raw
    // value comes from the camera, so this asserts what `None` delivers, not
    // merely that it differs.
    const double raw = viewWorldPerPixelFromCamera(camOff) * alongOff;
    assert(fabs(gotOff - raw) <= 0.01 * raw,
           format("under Coordinate Rounding = None the arm must deliver the "
                ~ "RAW gain: want %.9f = pixelScale x %.3f px, got %.9f. A "
                ~ "value that still lands on a grid means `None` was ported "
                ~ "as a small step instead of as the identity.",
                raw, alongOff, gotOff));
    const double nOff = gotOff / q;
    assert(fabs(nOff - cast(double)cast(long)(nOff + 0.5)) * q > 2e-5,
           format("...and it must be OFF the grid, or this test cannot tell "
                ~ "the setting apart: %.9f is %.4f steps of %.9g. (If the raw "
                ~ "value lands within 2e-5 of a step by chance the run length "
                ~ "must move — that is the other way this fires.)",
                gotOff, nOff, q));

    // The default is the reference's default, not `None`. The reset inside
    // `setupAxisDrag` restores it — which is also what stops the `none` drag
    // above from switching the rounding off for every later test sharing this
    // vibe3d process — and this run selects NOTHING, so what it measures is
    // whatever the untouched setting is.
    double[3] dDef, pivotDef; double alongDef; CameraState camDef;
    oneArmDrag("auto", RUN, false, dDef, alongDef, camDef, pivotDef, "");

    const double qd = roundingStepFromCamera(camDef);
    const double gd = vlen3(dDef);
    assert(gd > 0.05, "the default-mode drag did not engage");
    const double nd = gd / qd;
    assert(fabs(nd - cast(double)cast(long)(nd + 0.5)) * qd < 2e-5,
           format("the SHIPPED DEFAULT must be rounding ON: after a reset, "
                ~ "with no mode selected, %d px delivered %.9f = %.4f steps "
                ~ "of %.9g. A default of None would ship the measured term "
                ~ "switched off and call it ported.", RUN, gd, nd, qd));
}
