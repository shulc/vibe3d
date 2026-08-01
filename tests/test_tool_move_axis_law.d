// The transform gizmo's AXIS ARM drag conversion, end to end (task 0562).
//
// `test_tool_move_drag.d` already pins that an X-arrow drag moves the
// selection in +X and nothing else. This file pins the CONVERSION — the four
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
//   4. THE SCALAR IS QUANTISED. The reference rounds the axis coordinate to
//      the nearest 0.002 before it becomes a world offset (measured, 30 of 30
//      evaluations), so every delivered length is a multiple of that step.
//      The rounding LAW is pinned on the scalar in `drag.d`'s unittests
//      against the reference's own six (before, after) pairs; what is pinned
//      here is only that the shipped drag really does come out on the grid —
//      i.e. that the term survives the whole tool path and is not swallowed
//      by the wrapper.
//
// No reference engine is booted and none is needed: (1)'s expected value is
// arithmetic on our own camera, (2)/(3) are relations between two of our own
// drags, and (4) is a property of a single number.

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt, tan, PI;
import std.conv   : to;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";

void cmd(string c) { post(BASE ~ "/api/command", c); }

void setupAxisDrag(string acen) {
    post(BASE ~ "/api/reset", "");
    auto sel = post(BASE ~ "/api/select", `{"mode":"vertices","indices":[6]}`);
    assert(parseJSON(cast(string)sel)["status"].str == "ok",
           "select failed: " ~ cast(string)sel);
    auto set = post(BASE ~ "/api/script", "tool.set move");
    assert(parseJSON(cast(string)set)["status"].str == "ok",
           "tool.set move failed: " ~ cast(string)set);
    Thread.sleep(200.msecs);
    cmd("actr." ~ acen);
    Thread.sleep(250.msecs);   // the gizmo must redraw for /api/tool/handles
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
                out CameraState cam, out double[3] pivot)
{
    setupAxisDrag(acen);
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

unittest {  // 4. the delivered length lands on the reference's 0.002 grid
    // The rounding law is pinned on the scalar in drag.d against the
    // reference's own six (before, after) pairs. This pins only that the term
    // is still there at the far end of the tool path — through the wrapper,
    // the command, and the mesh write — because a quantum that is computed and
    // then averaged away by a downstream blend is worth nothing.
    //
    // FIVE runs, not one. Multiple-of-the-quantum is exact when the quantum is
    // present and, when it is absent, fails for any run whose raw value is not
    // within 1 % of a step by chance. One run could pass by luck; five cannot.
    enum double Q = 0.002;
    foreach (runPx; [96, 108, 117, 129, 141]) {
        double[3] d, pivot; double alongPx; CameraState cam;
        oneArmDrag("auto", runPx, false, d, alongPx, cam, pivot);

        const double got   = vlen3(d);
        assert(got > 0.05, format("the %d px arm drag did not engage", runPx));

        const double steps = got / Q;
        const double off   = fabs(steps - cast(double)cast(long)(steps + 0.5));
        assert(off * Q < 2e-5,
               format("the axis arm's delivered length must land on the "
                    ~ "reference's 0.002 grid: %d px delivered %.9f, which is "
                    ~ "%.4f steps — %.7f off the nearest one. The reference "
                    ~ "rounds the SCALAR before it becomes a world offset "
                    ~ "(measured 30/30); a value off the grid means the "
                    ~ "quantum was dropped, or applied to the position "
                    ~ "instead of the scalar, or averaged out downstream.",
                    runPx, got, steps, off * Q));
    }
}
