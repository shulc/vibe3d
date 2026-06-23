// Flex (acen=border, axis=select) ROTATE AXIS CHAINING — the rotation must
// happen about the DISPLAYED rotated ring axis, not the un-chained world axis.
//
// flex_border_handles_plan.md gesture-chaining follow-up. In ONE continuous tool
// session (no reset / selection change / tool drop between gestures — the GUI
// flow), a flex rotate about Z then a rotate about X: the X ring is DRAWN in the
// Z-rotated frame (R_gesture·softBasis), but BEFORE the fix the rotation happened
// about WORLD X — the applied rotation plane did NOT match the displayed ring.
//
// Root cause: the render of all banks sources B0 from the persisted softBasis a
// prior gesture left (render chained), and the move/scale INPUT banks override
// their inputBasis* off softBasis too — but the rotate bank's APPLIED ring axis is
// read from the run frame (runFrameR/U/F[ax]), which on the global matrix-truth
// path is the STALE world-snapped frame (a cross-axis rotate-after-rotate reuses
// the run frame — no re-bake). So apply rotated about world X while the ring drew
// rotated X. Render chained, input/apply NOT.
//
// The fix: beginRotateDragSession overrides the rotate bank's applied ring axis
// (rotateChain{R,U,F}, consumed by the principal-rotate drain) AND re-derives the
// sub-tool's frozen dragAxisVec/dragRefDir off the same softBasis, gated on
// softBasisValid && acenSettleAllowed() (mirroring the move/scale overrides),
// principal axes ONLY (the view-ring is camera-axis basis-independent, excluded).
//
// What this asserts — a rotation about a unit axis `a` leaves every vertex
// displacement PERPENDICULAR to `a` (a vertex orbits about `a`, so its delta lies
// in the plane normal to `a`). So the moved-set displacement direction is the
// engine-independent witness of the applied axis: after the chained rotate-X, the
// displacements must be ⟂ to the DISPLAYED rotated-X (softBasis X), NOT ⟂ to
// world X. This holds under selection falloff too (each vertex rotates by its own
// weighted angle about the SAME axis ⇒ its delta is still ⟂ to that axis).
//
//   RED   without the fix: apply rotates about WORLD X ⇒ displacements ⟂ world X,
//         so |mean dot(disp, softBasisX)| is LARGE (the displaced verts have a
//         big component along the rotated X) and |mean dot(disp, worldX)| ~ 0.
//   GREEN with the fix: apply rotates about softBasis X ⇒ displacements ⟂
//         softBasis X, so |mean dot(disp, softBasisX)| ~ 0 (and the world-X dot
//         is the larger one). The test asserts the softBasis-X perpendicularity
//         AND that it beats the world-X alignment.
//
// Modeled on tests/test_xfrm_flex_gesture_chain.d (chunked drag harness) and
// tests/test_run_absolute_rotate.d (principal-ring arc geometry).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, sin, cos, atan2, PI;
import std.conv : to;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

void main() {}

enum baseUrl = "http://localhost:8080";

JSONValue getJson(string p) { return parseJSON(cast(string) get(baseUrl ~ p)); }
JSONValue postJson(string p, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ p, body_));
}
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

struct V3 { double x = 0, y = 0, z = 0; }
double dot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
V3 cross(V3 a, V3 b) {
    return V3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
double len(V3 v) { return sqrt(dot(v, v)); }
V3 norm(V3 v) { double L = len(v); return L > 1e-12 ? V3(v.x/L, v.y/L, v.z/L) : V3(0, 0, 0); }
V3 scl(V3 v, double s) { return V3(v.x*s, v.y*s, v.z*s); }
V3 add(V3 a, V3 b) { return V3(a.x+b.x, a.y+b.y, a.z+b.z); }

double[16] lookAt(V3 eye, V3 ctr, V3 up) {
    V3 f = norm(V3(ctr.x-eye.x, ctr.y-eye.y, ctr.z-eye.z));
    V3 r = norm(cross(f, up));
    V3 u = cross(r, f);
    return [ r.x, u.x, -f.x, 0, r.y, u.y, -f.y, 0, r.z, u.z, -f.z, 0,
        -(r.x*eye.x+r.y*eye.y+r.z*eye.z), -(u.x*eye.x+u.y*eye.y+u.z*eye.z),
         (f.x*eye.x+f.y*eye.y+f.z*eye.z), 1 ];
}
double[16] persp(double fovY, double asp, double n, double f) {
    import std.math : tan;
    double fn = 1.0 / tan(fovY * 0.5); double nf = n - f;
    return [ fn/asp,0,0,0, 0,fn,0,0, 0,0,(f+n)/nf,-1, 0,0,2*f*n/nf,0 ];
}

struct Cam { V3 eye, focus; int w, h, vpX, vpY; }
Cam fetchCam() {
    auto j = getJson("/api/camera");
    Cam c;
    c.eye   = V3(j["eye"]["x"].floating,   j["eye"]["y"].floating,   j["eye"]["z"].floating);
    c.focus = V3(j["focus"]["x"].floating, j["focus"]["y"].floating, j["focus"]["z"].floating);
    c.w = cast(int)j["width"].integer; c.h = cast(int)j["height"].integer;
    c.vpX = cast(int)j["vpX"].integer;  c.vpY = cast(int)j["vpY"].integer;
    return c;
}
bool project(V3 world, const ref double[16] view, const ref double[16] p,
             int w, int h, int vpX, int vpY, out double px, out double py) {
    double vx = view[0]*world.x+view[4]*world.y+view[8]*world.z+view[12];
    double vy = view[1]*world.x+view[5]*world.y+view[9]*world.z+view[13];
    double vz = view[2]*world.x+view[6]*world.y+view[10]*world.z+view[14];
    double vw = view[3]*world.x+view[7]*world.y+view[11]*world.z+view[15];
    double cx = p[0]*vx+p[4]*vy+p[8]*vz+p[12]*vw;
    double cy = p[1]*vx+p[5]*vy+p[9]*vz+p[13]*vw;
    double cw = p[3]*vx+p[7]*vy+p[11]*vz+p[15]*vw;
    if (!(cw > 0)) return false;
    px = (cx/cw*0.5+0.5)*w + vpX;
    py = (1-(cy/cw*0.5+0.5))*h + vpY;
    return true;
}
bool projWorld(Cam cam, V3 w, out double px, out double py) {
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    return project(w, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, px, py);
}
// World-space gizmo radius (matches source/handler.d:gizmoSize, 90px default).
double gizmoRadius(Cam cam, V3 center) {
    double cx, cy, ex, ey;
    if (!projWorld(cam, center, cx, cy)) return 0.5;
    // Offset the center one world unit along camera-right, measure px delta.
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    V3 camRight = V3(view[0], view[4], view[8]);
    double rx, ry;
    if (!projWorld(cam, add(center, camRight), rx, ry)) return 0.5;
    double pxPerUnit = sqrt((rx-cx)*(rx-cx) + (ry-cy)*(ry-cy));
    return pxPerUnit > 1e-6 ? 90.0 / pxPerUnit : 0.5;
}

void play(string log) {
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (i; 0 .. 200) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(20));
    }
    Thread.sleep(dur!"msecs"(40));
}

V3 readRight(JSONValue blk) {
    auto a = blk["right"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
V3 moveRight() { return readRight(getJson("/api/toolpipe/eval")["transform"]["moveRenderFrame"]); }
V3 rotateRight() { return readRight(getJson("/api/toolpipe/eval")["transform"]["rotateRenderFrame"]); }
V3 acenCenter() {
    auto a = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
double maxDev(V3 a, V3 b) {
    double m = fabs(a.x-b.x);
    m = fabs(a.y-b.y) > m ? fabs(a.y-b.y) : m;
    m = fabs(a.z-b.z) > m ? fabs(a.z-b.z) : m;
    return m;
}

double[3][] dumpVerts() {
    double[3][] outv;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        outv ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return outv;
}
long undoCount() { return getJson("/api/history")["undo"].array.length; }

// Mean |dot(disp, axis)| over the verts that moved between pre and now. For a
// pure rotation about `axis` this is ~0 (disp ⟂ axis); for a rotation about a
// DIFFERENT axis it is large. Returns (perpScore, moveCount).
double meanAlong(double[3][] pre, double[3][] now, V3 axis, out int n) {
    double acc = 0; n = 0;
    foreach (k; 0 .. pre.length) {
        V3 d = V3(now[k][0]-pre[k][0], now[k][1]-pre[k][1], now[k][2]-pre[k][2]);
        if (len(d) < 2e-3) continue;       // unmoved (falloff-zero or on the axis)
        acc += fabs(dot(d, norm(axis)));   // |component of disp along axis|
        n++;
    }
    return n > 0 ? acc / n : 0;
}

// --- principal ring drag around an ARBITRARY world-space axis ----------------
// Replica of test_run_absolute_rotate.d:principalRingGesture, but the ring axis
// is supplied explicitly (a world vector) so we can grab the DISPLAYED ROTATED
// ring after a prior gesture, not just a world axis. Returns the moved-set
// vertex dump delta via dumpVerts pre/post (caller compares).
void localFrame(V3 normal, out V3 right, out V3 up) {
    V3 fwd = norm(normal);
    V3 tmp = fabs(fwd.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0);
    right = norm(cross(fwd, tmp));
    up    = cross(right, fwd);
}
double arcStartAngle(V3 nAxis, V3 camFwd, V3 right, V3 up) {
    V3 dir = cross(nAxis, camFwd);
    double l = len(dir);
    if (l <= 1e-4) return 0.0;
    dir = scl(dir, 1.0 / l);
    V3 mid = cross(nAxis, dir);
    if (dot(mid, camFwd) < 0.0) dir = scl(dir, -1.0);
    return atan2(dot(dir, up), dot(dir, right));
}
// Drive ONE principal-ring gesture about world axis `axisVec` at `center`. Retry
// on the undo count (a missed grab records nothing). Returns true on a recorded
// grab. `dumpPre`/`dumpPost` receive the geometry before/after the gesture.
bool ringGesture(V3 axisVec, V3 center, long wantCount, double arcDelta,
                 out double[3][] dumpPre, out double[3][] dumpPost) {
    foreach (attempt; 0 .. 16) {
        Thread.sleep(dur!"msecs"(60));
        Cam cam = fetchCam();
        double radius = gizmoRadius(cam, center);
        V3 right, up;
        localFrame(axisVec, right, up);
        auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
        V3 camFwd = V3(-view[2], -view[6], -view[10]);
        double startAngle = arcStartAngle(norm(axisVec), camFwd, right, up);
        double pull = arcDelta + attempt * 0.08;
        double a0 = startAngle + PI / 2.0;
        double a1 = a0 + pull;
        V3 w0 = add(center, add(scl(right, cos(a0) * radius), scl(up, sin(a0) * radius)));
        V3 w1 = add(center, add(scl(right, cos(a1) * radius), scl(up, sin(a1) * radius)));
        double x0, y0, x1, y1;
        if (!projWorld(cam, w0, x0, y0)) continue;
        if (!projWorld(cam, w1, x1, y1)) continue;

        dumpPre = dumpVerts();
        enum int steps = 18;
        play(format(
            `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
            `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
            cam.vpX, cam.vpY, cam.w, cam.h, cast(int)x0, cast(int)y0));
        int lastX = cast(int)x0, lastY = cast(int)y0;
        double t = 100.0;
        foreach (i; 1 .. steps + 1) {
            int xx = cast(int)(x0 + (x1 - x0) * i / steps);
            int yy = cast(int)(y0 + (y1 - y0) * i / steps);
            play(format(
                `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
                t, xx, yy, xx - lastX, yy - lastY));
            lastX = xx; lastY = yy; t += 50.0;
        }
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
            t, cast(int)x1, cast(int)y1));
        Thread.sleep(dur!"msecs"(60));
        if (undoCount() >= wantCount) {
            dumpPost = dumpVerts();
            return true;
        }
        // missed grab — nothing recorded; the geometry is unchanged, retry.
    }
    return false;
}

// Select the upper region of the subdivcube — a large patch giving a stable
// Border pivot AND enough moved verts (with non-trivial radius from the pivot)
// that the rotation displacement is well above noise under selection falloff. A
// tight top cap sits near the Border pivot and barely moves (falloff-attenuated +
// small lever arm), so the displacement-direction witness needs the bigger patch.
// (Mirrors tests/test_xfrm_flex_gesture_chain.d:selectUpperRegion, cy > -0.35.)
void selectUpperRegion() {
    auto model = getJson("/api/model");
    auto verts = model["vertices"].array;
    auto faces = model["faces"].array;
    int[] sel;
    foreach (fi, f; faces) {
        auto idx = f.array;
        double cy = 0;
        foreach (vi; idx) cy += verts[cast(size_t)vi.integer].array[1].floating;
        cy /= idx.length;
        if (cy > -0.35) sel ~= cast(int)fi;
    }
    assert(sel.length > 30, "expected a large upper-region patch, got "
        ~ sel.length.to!string);
    string s = "[";
    foreach (i, v; sel) s ~= (i ? "," : "") ~ v.to!string;
    s ~= "]";
    postJson("/api/select", `{"mode":"polygons","indices":` ~ s ~ `}`);
}

void setupFlex() {
    postJson("/api/reset?type=subdivcube&levels=2", "");
    postJson("/api/camera", `{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);
    selectUpperRegion();
    cmd("tool.set xfrm.flex on");
    cmd("tool.attr xfrm.flex T true");
    cmd("tool.attr xfrm.flex R true");
    cmd("tool.attr xfrm.flex S true");
}

unittest {
    setupFlex();

    // Idle pre-rotate frame = the world-snapped B0 (rotate ring X ≈ world X).
    V3 worldX = rotateRight();
    assert(fabs(worldX.x) > 0.9 && fabs(worldX.y) < 0.2 && fabs(worldX.z) < 0.2,
        "precondition: idle Border rotate X ring is ~world X; got " ~ worldX.to!string);

    V3 pivot = acenCenter();

    // ---- GESTURE 1: principal rotate about WORLD Z (establishes softBasis) ----
    long want = undoCount() + 1;
    double[3][] g1pre, g1post;
    bool ok1 = ringGesture(V3(0, 0, 1), pivot, want, 0.55, g1pre, g1post);
    assert(ok1, "gesture-1 (rotate Z) ring grab never recorded (ring-grab flake)");

    // The Z rotation re-oriented the X ring: the persisted rotate-X ring is now
    // the ROTATED X (softBasis X), no longer world X. This is the precondition
    // for the chaining bug — render rotated, apply (un-fixed) still world.
    V3 rotX = rotateRight();
    double rotDev = maxDev(rotX, worldX);
    assert(rotDev > 0.15,
        "gesture-1 did not rotate the X ring off world (dev=" ~ rotDev.to!string
        ~ ") — softBasis precondition failed.");
    // pivot is unchanged (rotation about its own pivot) — re-read for safety.
    pivot = acenCenter();

    // ---- GESTURE 2 (SAME SESSION): grab the DISPLAYED rotated X ring ----------
    // No reset / selection change / tool drop between gestures. Grab the ring
    // around the ROTATED X axis (softBasis X = rotX), the ring the user sees.
    want = undoCount() + 1;
    double[3][] g2pre, g2post;
    bool ok2 = ringGesture(rotX, pivot, want, 0.55, g2pre, g2post);
    assert(ok2, "gesture-2 (rotate displayed-X) ring grab never recorded "
        ~ "(ring-grab flake on the rotated ring)");

    // The applied rotation axis is witnessed by the moved-set displacement
    // direction: a rotation about `a` keeps every displacement ⟂ to `a`.
    int nSoft, nWorld;
    double alongSoftX  = meanAlong(g2pre, g2post, rotX,   nSoft);
    double alongWorldX = meanAlong(g2pre, g2post, worldX, nWorld);
    assert(nSoft > 5,
        "gesture-2 moved too few verts (" ~ nSoft.to!string ~ ") to witness the axis");

    // THE FIX: rotation about the DISPLAYED rotated X ⇒ displacements ⟂ rotX, so
    // the along-rotX component is ~0 AND clearly smaller than the along-worldX
    // component (which a world-X rotation would have driven to ~0 instead).
    //
    // RED without the fix: apply rotates about WORLD X ⇒ disp ⟂ worldX ⇒
    // alongWorldX ~ 0 and alongSoftX is the LARGE one → both asserts below fail.
    assert(alongSoftX < alongWorldX,
        "gesture-2 rotated about the WRONG axis: |disp·rotX|=" ~ alongSoftX.to!string
        ~ " is NOT smaller than |disp·worldX|=" ~ alongWorldX.to!string
        ~ " — the apply rotated about WORLD X while the ring displays ROTATED X "
        ~ "(rotate axis chaining missing).");
    assert(alongSoftX < 0.5 * alongWorldX + 1e-3,
        "gesture-2 displacements are not clearly ⟂ to the displayed rotated X "
        ~ "(|disp·rotX|=" ~ alongSoftX.to!string ~ " vs |disp·worldX|="
        ~ alongWorldX.to!string ~ ") — applied plane does not match the ring.");
}
