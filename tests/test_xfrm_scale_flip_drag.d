// Interactive Flex scale-handle drag regression test.
//
// Bug (pre-fix): in a Flex-style scale (axis.mode=select,
// actionCenter.mode=border, falloff=selection), dragging a single-axis
// scale BOX handle on a partial selection of a deforming mesh re-orients
// the gizmo MID-DRAG. The scale handle's orientation (handler.axisX/Y/Z)
// was overwritten every frame from the live select-derived basis, which
// flips its axis sign / swaps the in-plane axes as the selection
// deforms. ScaleTool.onMouseMotion's single-axis path projects the gizmo
// axis to screen and projects the screen drag onto it, so a flipping
// frame makes the per-step radial response OSCILLATE (the scale
// magnitude alternates / reverses without releasing LMB).
//
// The fix freezes the scale handle's orientation for the duration of an
// active drag (dragAxis >= 0), so the input-projection frame is fixed
// (the reference engine's drag-start-fixed gizmo). It mirrors the
// already-shipped MoveTool fix and the existing dragAxis>=0 gate in
// ScaleTool.update.
//
// What this test does:
//   1. Build a SUBDIVIDED cube (level-2 Catmull-Clark) so there are
//      interior verts that actually move under selection-falloff (a
//      plain cube is all-boundary → zero movement under Flex).
//   2. Select the upper face region (a partial set, up-axis = +Y) and
//      activate xfrm.flex, but with T/R off and S on so ONLY the scale
//      bank renders — no move-arrow / rotate-ring occlusion competes for
//      the single-axis box pixel.
//   3. Grab the SCALE single-axis box handle (Z axis, hitPart 2 → the
//      principal-axis scale path, NOT the uniform centre disc which is
//      immune) and drag it in CHUNKS — one play-events call per motion
//      step, button held down across calls — sampling the mean distance
//      of the moving set from the scale pivot after each step. (A single
//      one-shot play-events drag would NOT expose the mid-drag
//      re-orientation the same way the per-step trajectory does.)
//   4. Assert the per-step mean-radius increment is SMOOTH (sign-
//      consistent, no discontinuous jump). Pre-fix the increment
//      oscillates ~42 % step-to-step as the select-basis flips; post-fix
//      the frame is frozen and the increments vary < 2 %.
//
// The drag axis / camera / pixel here were chosen empirically so that
// the underlying AxisStage select-basis DOES flip during the drag
// (verified against an instrumented build): the handle's
// frozen-vs-live frame is what the assertion below pins.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, tan, PI;
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

// ---- minimal camera / projection math (duplicated from drag_helpers,
//      kept local so this test compiles standalone) ---------------------
struct V3 { double x = 0, y = 0, z = 0; }
double dot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
V3 cross(V3 a, V3 b) {
    return V3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
V3 norm(V3 v) {
    double L = sqrt(dot(v, v));
    return L > 1e-12 ? V3(v.x/L, v.y/L, v.z/L) : V3(0, 0, 0);
}
double[16] lookAt(V3 eye, V3 ctr, V3 up) {
    V3 f = norm(V3(ctr.x-eye.x, ctr.y-eye.y, ctr.z-eye.z));
    V3 r = norm(cross(f, up));
    V3 u = cross(r, f);
    return [ r.x, u.x, -f.x, 0, r.y, u.y, -f.y, 0, r.z, u.z, -f.z, 0,
        -(r.x*eye.x+r.y*eye.y+r.z*eye.z), -(u.x*eye.x+u.y*eye.y+u.z*eye.z),
         (f.x*eye.x+f.y*eye.y+f.z*eye.z), 1 ];
}
double[16] persp(double fovY, double asp, double n, double f) {
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
// World → window pixels.
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

// Play one JSON-Lines chunk and wait for the player to drain.
void play(string log) {
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (i; 0 .. 200) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(20));
    }
    Thread.sleep(dur!"msecs"(40));
}

double[3][] dumpVerts() {
    double[3][] outv;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        outv ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return outv;
}

// Mean distance of the verts that moved away from `pre`, measured from
// the scale pivot. A clean single-axis scale grows this monotonically;
// a mid-drag axis flip makes the per-step growth oscillate.
double movedMeanRadius(double[3][] pre, double[3][] now, V3 pivot) {
    double s = 0; int n = 0;
    foreach (k; 0 .. pre.length) {
        bool moved = false;
        foreach (c; 0 .. 3) if (fabs(now[k][c] - pre[k][c]) > 1e-4) moved = true;
        if (moved) {
            double dx = now[k][0] - pivot.x;
            double dy = now[k][1] - pivot.y;
            double dz = now[k][2] - pivot.z;
            s += sqrt(dx*dx + dy*dy + dz*dz);
            n++;
        }
    }
    return n > 0 ? s / n : 0;
}

unittest {
    // ---- scene: level-2 Catmull-Clark cube, upper-region face patch ----
    postJson("/api/reset?type=subdivcube&levels=2", "");
    postJson("/api/camera", `{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);

    // Select every face whose centroid sits in the upper region
    // (y > -0.35) — a PARTIAL set with a deep interior (the moving verts)
    // and an anchored boundary ring, exactly the Flex case where the
    // select-basis is sensitive to the deformation.
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
    string selStr = "[";
    foreach (i, s; sel) selStr ~= (i ? "," : "") ~ s.to!string;
    selStr ~= "]";
    postJson("/api/select", `{"mode":"polygons","indices":` ~ selStr ~ `}`);

    // Flex preset (axis.mode=select, actionCenter.mode=border,
    // falloff=selection), but scale-only: T/R off so ONLY the scale bank
    // renders and the single-axis scale box is the unambiguous handle the
    // drag pixel grabs (no move-arrow / rotate-ring occlusion).
    cmd("tool.set xfrm.flex on");
    cmd("tool.attr xfrm.flex T false");
    cmd("tool.attr xfrm.flex R false");
    cmd("tool.attr xfrm.flex S true");

    // ---- locate the SCALE Z-axis box handle in screen pixels ----
    // The scale Z-axis arrow at this camera projects toward the lower-left
    // of the gizmo; (400,402) was found (empirically, against an
    // instrumented build) to land on the scale-bank Z-axis arrow shaft
    // (hitPart == 2), routing the drag through ScaleTool's single-axis
    // drag path — NOT the uniform centre disc (dragAxis == 3) which is
    // immune because it never reads handler.axis*. We hard-code it rather
    // than recompute the gizmo layout (arrow start offset, gizmo pixel
    // size) which the test can't observe.
    Cam cam = fetchCam();
    int x0 = 400, y0 = 402;     // on the scale Z-axis arrow shaft
    int x1 = x0 - 60, y1 = y0;  // drag 60 px toward screen-left (scale up)

    // The scale pivot (border center) must project on-screen.
    auto tp = getJson("/api/toolpipe/eval");
    auto ac = tp["actionCenter"]["center"].array;
    V3 pivot = V3(ac[0].floating, ac[1].floating, ac[2].floating);
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    double ppx, ppy;
    assert(project(pivot, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, ppx, ppy),
        "gizmo pivot projects off-camera — camera setup changed");

    // ---- chunked drag: one play-events per motion step, button held ----
    enum int steps = 20;
    double[3][] pre = dumpVerts();
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));

    double[] radSeq;           // moving-set mean radius (from pivot) after each step
    int lastX = x0, lastY = y0;
    double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
        radSeq ~= movedMeanRadius(pre, dumpVerts(), pivot);
    }
    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x1, y1));

    // ---- assertions ----
    // The drag must actually have engaged the scale handle: verts moved,
    // the moving set grew its mean radius from the pivot (scaling up).
    assert(radSeq.length == steps);
    double firstRad = radSeq[0];
    double finalRad = radSeq[$ - 1];
    assert(firstRad > 0.1,
        "Flex scale-Z drag produced no motion (firstRad=" ~ firstRad.to!string
        ~ ") — handle hit-test or selection setup is wrong");
    assert(finalRad > firstRad,
        "Flex scale-Z drag did not grow the moving-set radius (first="
        ~ firstRad.to!string ~ " final=" ~ finalRad.to!string ~ ")");

    // Per-step mean-radius increments along the drag.
    double[] inc;
    foreach (i; 1 .. radSeq.length) inc ~= radSeq[i] - radSeq[i - 1];

    // Every increment must be POSITIVE (no reversal mid-drag): a
    // re-oriented frame can flip the sign of the per-step scale response.
    foreach (i, d; inc)
        assert(d > 1e-5,
            "Flex scale-Z drag reversed at step " ~ (i + 1).to!string
            ~ " (drad=" ~ d.to!string ~ ") — gizmo frame flipped mid-drag");

    // The increments must be SMOOTH. Pre-fix, the select-basis flip
    // mid-drag makes the per-step radial growth OSCILLATE (the screen→
    // world projection of the scale axis alternates), measured at ~42 %
    // step-to-step. Post-fix the frame is frozen and the increments vary
    // < 2 %. Assert no step-to-step jump exceeds 12 %.
    double maxJump = 0;
    size_t jumpAt = 0;
    foreach (i; 1 .. inc.length) {
        if (inc[i - 1] <= 1e-9) continue;
        double ratio = fabs(inc[i] - inc[i - 1]) / inc[i - 1];
        if (ratio > maxJump) { maxJump = ratio; jumpAt = i; }
    }
    assert(maxJump < 0.12,
        "Flex scale-Z drag per-step response jumped " ~ maxJump.to!string
        ~ " at step " ~ (jumpAt + 1).to!string
        ~ " — the gizmo frame re-oriented mid-drag (frozen-frame fix regressed)."
        ~ "\n increments: " ~ inc.to!string);
}
