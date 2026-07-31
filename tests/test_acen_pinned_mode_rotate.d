// A press away from the rotate rings turns the selection in EVERY action-centre
// mode — and what it turns is one ball drawn in screen pixels.
//
// What was wrong. `RotateTool.onMouseButtonDown` asked "may this click relocate
// the pivot?" and used the answer to decide whether the press starts a DRAG.
// Only Auto / None / Screen relocate, so under Origin / Local / Select / Border
// a press off every ring returned false and the tool never engaged: no drag, no
// rotation, nothing. Under Auto it engaged just far enough to MOVE the pivot and
// then also did nothing. Eighteen rows of a cross-engine drag corpus were
// comparing the reference against a stationary mesh because of it.
//
// What the gesture is. An arcball in screen pixels, centred on the action
// centre's screen projection, radius 200 px (`source/tools/transform/arcball.d`
// carries the law and its measured rows). Its two limits are the two behaviours
// the corpus shows: a pinned pivot leaves the press hundreds of pixels out, so
// both lifted points sit on the rim and the model turns about the VIEW axis by
// the angle the pointer sweeps about the centre; a relocate puts the pivot under
// the press, so it is the trackball limit, `asin(|d| / 200 px)` about the axis
// perpendicular to the drag in the screen plane.
//
// What each assertion here is for, and what it would catch:
//
//   1. ENGAGEMENT. Every pinned mode turns the selection. Fails on the old code
//      with "moved 0.0" — that is the whole defect.
//
//   2. IT IS A RIGID ROTATION ABOUT THE PINNED PIVOT. Every moving vert keeps
//      its distance to the pivot. A gesture that engaged and translated, or that
//      turned about the press instead, passes (1) and fails here.
//
//   3. THE ANGLE IS PIVOT-DEPENDENT, and by the arcball's own amount. Two
//      presses at different distances from the pivot, same pixel drag, give
//      DIFFERENT angles — and each equals the swept polar angle about the
//      pivot's projection to a fraction of a degree. This is the assertion that
//      separates the law from the rival it was measured against (a fixed rate
//      on the perpendicular pixel component, which is pivot-INDEPENDENT and
//      agrees to 1.4 % at short drags).
//
//   4. AT 400 px THE RIVAL IS REFUTED BY A FACTOR OF TWO. The same rig at a long
//      drag, where the two laws part company. A test written only at 100 px
//      cannot tell them apart, so this one is written long on purpose.
//
//   5. AUTO IS THE TRACKBALL LIMIT. A relocating mode presses at its own new
//      centre, so 100 px turns 30 deg and 50 px turns 14.48 deg — asin, not a
//      linear rate — about the axis perpendicular to the drag. The two lengths
//      together are what make it asin rather than proportional.
//
//   6. THE PIN IS UNTOUCHED in a pinned mode. The half of the old predicate that
//      was CORRECT and had to survive: no user-placed pin, pivot unmoved.

import std.net.curl;
import std.json;
import std.math  : fabs, sqrt, atan2, acos, asin, PI, sin;
import std.conv  : to;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue pj(string p, string b) { return parseJSON(cast(string) post(baseUrl ~ p, b)); }
JSONValue gj(string p)           { return parseJSON(cast(string) get(baseUrl ~ p)); }
void settle()                    { Thread.sleep(150.msecs); }
void cmd(string c)               { pj("/api/command", c); }

Vec3[] verts() {
    Vec3[] outv;
    foreach (v; gj("/api/model")["vertices"].array) {
        auto a = v.array;
        outv ~= Vec3(cast(float) a[0].floating,
                     cast(float) a[1].floating,
                     cast(float) a[2].floating);
    }
    return outv;
}

// The +Y face of the default cube, found by geometry rather than by a magic
// index so a change to the cube's face order cannot silently re-aim the test.
int topFaceIndex() {
    auto model = gj("/api/model");
    auto vs = model["vertices"].array;
    auto polys = ("polygons" in model) ? model["polygons"].array
                                       : model["faces"].array;
    foreach (fi, f; polys) {
        bool allTop = true;
        foreach (iv; f.array)
            if (vs[cast(size_t) iv.integer].array[1].floating < 0.49) { allTop = false; break; }
        if (allTop) return cast(int) fi;
    }
    assert(false, "no +Y face found on the cube");
}

string[string] acenAttrs() {
    foreach (st; gj("/api/toolpipe")["stages"].array) {
        if (st["task"].str == "ACEN") {
            string[string] m;
            foreach (k, v; st["attrs"].object) m[k] = v.str;
            return m;
        }
    }
    assert(false, "no ACEN stage");
}

Vec3 acenCenter() {
    auto a = acenAttrs();
    return Vec3(a["cenX"].to!float, a["cenY"].to!float, a["cenZ"].to!float);
}

// Fresh cube, +Y face selected, Rotate armed, action centre `mode`.
void setup(string mode) {
    pj("/api/reset", "");
    settle();
    pj("/api/select", format(`{"mode":"polygons","indices":[%d]}`, topFaceIndex()));
    cmd("actr." ~ mode);
    cmd("tool.set rotate");
    settle();
}

float len(Vec3 v) { return sqrt(v.x*v.x + v.y*v.y + v.z*v.z); }
bool  isTop(Vec3 v) { return v.y > 0.4f; }
float deg(float rad) { return rad * 180.0f / cast(float) PI; }

// The rotation a gesture actually performed, recovered from the geometry rather
// than read out of the tool: pick two independent vectors from the pivot to
// moving verts, and the rotation is fixed by where they went (the third basis
// vector is their cross product, which the rotation carries along). Recovering
// R by INDICES like this — rather than by a least-squares fit — is deliberate:
// a fit has an arbitrary axis sign, and a sign is exactly what this test is
// checking.
struct Turn { float angleRad; Vec3 axis; bool valid; }

Turn recoverTurn(Vec3[] before, Vec3[] after, Vec3 pivot) {
    Turn t;
    // two moving verts whose vectors from the pivot are not parallel
    Vec3 v1, v2, w1, w2; bool have1 = false, have2 = false;
    foreach (i, b; before) {
        if (!isTop(b)) continue;
        Vec3 v = b - pivot, w = after[i] - pivot;
        if (len(v) < 1e-4f) continue;
        if (!have1) { v1 = v; w1 = w; have1 = true; continue; }
        if (len(cross(v1, v)) > 1e-3f) { v2 = v; w2 = w; have2 = true; break; }
    }
    if (!have1 || !have2) return t;
    Vec3 v3 = cross(v1, v2), w3 = cross(w1, w2);
    // R = W * inv(V), both 3x3 with the vectors as COLUMNS
    float[9] V = [v1.x, v1.y, v1.z, v2.x, v2.y, v2.z, v3.x, v3.y, v3.z];
    float[9] W = [w1.x, w1.y, w1.z, w2.x, w2.y, w2.z, w3.x, w3.y, w3.z];
    float det = V[0]*(V[4]*V[8]-V[5]*V[7])
              - V[3]*(V[1]*V[8]-V[2]*V[7])
              + V[6]*(V[1]*V[5]-V[2]*V[4]);
    if (fabs(det) < 1e-9f) return t;
    float[9] inv;                                  // adjugate / det, columns
    inv[0] = (V[4]*V[8]-V[5]*V[7])/det; inv[1] = (V[2]*V[7]-V[1]*V[8])/det; inv[2] = (V[1]*V[5]-V[2]*V[4])/det;
    inv[3] = (V[5]*V[6]-V[3]*V[8])/det; inv[4] = (V[0]*V[8]-V[2]*V[6])/det; inv[5] = (V[2]*V[3]-V[0]*V[5])/det;
    inv[6] = (V[3]*V[7]-V[4]*V[6])/det; inv[7] = (V[1]*V[6]-V[0]*V[7])/det; inv[8] = (V[0]*V[4]-V[1]*V[3])/det;
    float[9] R;
    foreach (c; 0 .. 3) foreach (r; 0 .. 3) {
        float s = 0;
        foreach (k; 0 .. 3) s += W[k*3 + r] * inv[c*3 + k];
        R[c*3 + r] = s;
    }
    float tr = R[0] + R[4] + R[8];
    float ct = (tr - 1.0f) * 0.5f;
    if (ct >  1.0f) ct =  1.0f;
    if (ct < -1.0f) ct = -1.0f;
    t.angleRad = acos(ct);
    Vec3 ax = Vec3(R[5] - R[7], R[6] - R[2], R[1] - R[3]);   // 2 sin(t) * axis
    float n = len(ax);
    t.axis  = n > 1e-6f ? ax / n : Vec3(0, 0, 0);
    t.valid = n > 1e-6f;
    return t;
}

// The screen-polar angle the pointer sweeps about `c`, in degrees, y DOWN.
float sweptPolar(float cx, float cy, float px, float py, float dx, float dy) {
    float a0 = atan2(py - cy, px - cx);
    float a1 = atan2(py + dy - cy, px + dx - cx);
    float d  = a1 - a0;
    while (d >  PI) d -= 2.0f * PI;
    while (d < -PI) d += 2.0f * PI;
    return deg(d);
}

// Press at (px,py), drag by (dx,dy); returns before/after and the recovered
// rotation about the action centre as it stood BEFORE the press.
Turn rotateFrom(int px, int py, int dx, int dy, out Vec3 pivot, out Vec3[] before) {
    auto cam = fetchCamera(baseUrl);
    pivot  = acenCenter();
    before = verts();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             px, py, px + dx, py + dy, 8), baseUrl);
    settle();
    return recoverTurn(before, verts(), pivot);
}

// Two press pixels at DIFFERENT distances from the pivot, both far outside the
// 200 px ball and far from every ring (the rotate gizmo spans ~90 px about the
// pivot), and both well inside the viewport.
void pressPixels(Vec3 pivot, out int nearX, out int nearY,
                 out int farX, out int farY) {
    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);
    float cx, cy;
    assert(projectToWindow(pivot, vp, cx, cy), "pivot must project");
    nearX = cast(int)(cx + 230); nearY = cast(int)(cy + 60);
    farX  = cast(int)(cx + 430); farY  = cast(int)(cy + 120);
}

// -------------------------------------------------------------------------
// 1 + 2 — every pinned mode engages, and what it does is a rotation ABOUT THE
//         PINNED PIVOT.
// -------------------------------------------------------------------------
unittest {
    foreach (mode; ["origin", "local", "select", "border"]) {
        setup(mode);
        Vec3 pivot0 = acenCenter();
        int nx, ny, fx, fy; pressPixels(pivot0, nx, ny, fx, fy);

        Vec3 pivot; Vec3[] before;
        auto t = rotateFrom(nx, ny, 140, 0, pivot, before);
        auto after = verts();

        int moved = 0;
        foreach (i, b; before) {
            float d = len(after[i] - b);
            if (isTop(b)) {
                moved++;
                assert(fabs(len(after[i] - pivot) - len(b - pivot)) < 2e-3f,
                    format("actr.%s: vert %d changed its distance to the pivot "
                           ~ "by %g — an off-gizmo press must ROTATE about the "
                           ~ "pinned pivot, not translate or scale",
                           mode, i, len(after[i] - pivot) - len(b - pivot)));
            } else {
                assert(d < 1e-3f,
                    format("actr.%s: unselected vert %d moved by %g", mode, i, d));
            }
        }
        assert(moved == 4, format("actr.%s: expected 4 moving verts, got %d",
                                  mode, moved));
        assert(t.valid && deg(t.angleRad) > 1.0f,
            format("actr.%s: a press off the rings plus a drag must TURN the "
                   ~ "selection; it turned %g deg — the tool never engaged",
                   mode, t.valid ? deg(t.angleRad) : 0.0f));
    }
}

// -------------------------------------------------------------------------
// 3 — the angle is the swept polar angle about the PIVOT's projection, so it
//     depends on where the press landed. Origin is the discriminating mode:
//     its pivot is a fixed world point that cannot drift between gestures.
// -------------------------------------------------------------------------
unittest {
    setup("origin");
    Vec3 pivot0 = acenCenter();
    int nx, ny, fx, fy; pressPixels(pivot0, nx, ny, fx, fy);
    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);
    float cx, cy;
    assert(projectToWindow(pivot0, vp, cx, cy));

    Vec3 pv; Vec3[] before;
    setup("origin");
    auto tn = rotateFrom(nx, ny, 140, 0, pv, before);
    setup("origin");
    auto tf = rotateFrom(fx, fy, 140, 0, pv, before);
    assert(tn.valid && tf.valid, "both gestures must turn the selection");

    float wantN = sweptPolar(cx, cy, nx, ny, 140, 0);
    float wantF = sweptPolar(cx, cy, fx, fy, 140, 0);
    assert(fabs(deg(tn.angleRad) - fabs(wantN)) < 0.35f,
        format("the near press must turn by its own swept polar angle about "
               ~ "the pivot: got %g deg, swept %g deg",
               deg(tn.angleRad), wantN));
    assert(fabs(deg(tf.angleRad) - fabs(wantF)) < 0.35f,
        format("the far press must turn by its own swept polar angle about the "
               ~ "pivot: got %g deg, swept %g deg", deg(tf.angleRad), wantF));

    // …and the two must genuinely DIFFER. A pivot-independent rate on the
    // perpendicular pixel component — the rival this law was measured against —
    // would give the same angle from both presses.
    assert(deg(tn.angleRad) - deg(tf.angleRad) > 1.0f,
        format("a press NEARER the pivot must buy MORE rotation for the same "
               ~ "pixels; got %g deg near vs %g deg far — the angle has stopped "
               ~ "depending on the pivot",
               deg(tn.angleRad), deg(tf.angleRad)));

    // Both rim rotations turn about the VIEW axis.
    Vec3 fwd = normalize(Vec3(cam.focus.x - cam.eye.x,
                              cam.focus.y - cam.eye.y,
                              cam.focus.z - cam.eye.z));
    assert(fabs(fabs(dot(tn.axis, fwd)) - 1.0f) < 5e-3f,
        format("a press outside the ball must turn about the VIEW axis; "
               ~ "axis.fwd = %g", dot(tn.axis, fwd)));
}

// -------------------------------------------------------------------------
// 4 — at 400 px the rival is refuted by a factor of two.
// -------------------------------------------------------------------------
unittest {
    setup("origin");
    Vec3 pivot0 = acenCenter();
    int nx, ny, fx, fy; pressPixels(pivot0, nx, ny, fx, fy);
    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);
    float cx, cy;
    assert(projectToWindow(pivot0, vp, cx, cy));

    // The rate the SHORT drag implies, per perpendicular pixel. The rival law
    // says the long drag scales by this rate; the arcball says it does not,
    // because the pointer is sweeping an arc and the arc's angle is not linear
    // in its chord.
    Vec3 pv; Vec3[] before;
    setup("origin");
    auto tShort = rotateFrom(nx, ny, 100, 0, pv, before);
    setup("origin");
    auto tLong  = rotateFrom(nx, ny, 400, 0, pv, before);
    assert(tShort.valid && tLong.valid);

    immutable float rivalDeg = deg(tShort.angleRad) * 4.0f;
    immutable float wantDeg  = fabs(sweptPolar(cx, cy, nx, ny, 400, 0));
    assert(fabs(deg(tLong.angleRad) - wantDeg) < 0.5f,
        format("the 400 px drag must sweep its own polar angle: got %g deg, "
               ~ "swept %g deg", deg(tLong.angleRad), wantDeg));
    assert(fabs(deg(tLong.angleRad) - rivalDeg) > 3.0f,
        format("…and it must be nowhere near four times the 100 px angle, or "
               ~ "this row is not buying the separation it was written for: "
               ~ "got %g deg, the linear rival wants %g deg",
               deg(tLong.angleRad), rivalDeg));
}

// -------------------------------------------------------------------------
// 5 — Auto is the SAME ball, pressed at its centre: the trackball limit.
// -------------------------------------------------------------------------
unittest {
    // A relocating mode moves the pivot to the click, so the press lands at the
    // ball's centre and the drag alone decides: asin(|d| / 200 px), about the
    // axis perpendicular to the drag in the screen plane.
    struct Case { int dx, dy; float wantDeg; }
    immutable Case[] cases = [
        Case(100, 0, 30.0f),        // asin(0.50)
        Case( 50, 0, 14.4775f),     // asin(0.25) — together these two are what
    ];                              // make it asin and not a linear rate
    auto cam = fetchCamera(baseUrl);
    int px = cam.vpX + cam.width / 2 + 260;
    int py = cam.vpY + cam.height / 2 + 150;

    float[] got;
    foreach (c; cases) {
        setup("auto");
        Vec3 pv; Vec3[] before;
        // The relocate moves the pivot ON the press, so the rotation is about
        // the RELOCATED centre — read it back after the gesture.
        auto camS = fetchCamera(baseUrl);
        auto beforeV = verts();
        playAndWait(buildDragLog(camS.vpX, camS.vpY, camS.width, camS.height,
                                 px, py, px + c.dx, py + c.dy, 8), baseUrl);
        settle();
        auto t = recoverTurn(beforeV, verts(), acenCenter());
        assert(t.valid, "actr.auto: an off-gizmo press must turn the selection");
        got ~= deg(t.angleRad);
        assert(fabs(deg(t.angleRad) - c.wantDeg) < 0.6f,
            format("actr.auto: a %d px drag from a relocated centre must turn "
                   ~ "asin(%d/200) = %g deg; got %g deg",
                   c.dx, c.dx, c.wantDeg, deg(t.angleRad)));
        // perpendicular to the drag, in the screen plane: a horizontal drag
        // turns about screen UP.
        auto vp = viewportFromCamera(camS);
        Vec3 up = Vec3(vp.view[1], vp.view[5], vp.view[9]);
        assert(fabs(fabs(dot(t.axis, up)) - 1.0f) < 5e-3f,
            format("actr.auto: a horizontal drag must turn about screen UP; "
                   ~ "axis.up = %g", dot(t.axis, up)));
    }
    // Doubling the drag must NOT double the angle — that is the whole content
    // of asin, which is CONVEX, so the second 50 px buys MORE than the first.
    // A linear trackball ("k degrees per pixel") passes every assert above and
    // fails exactly here, which is why both lengths are in this test.
    assert(got[0] / got[1] > 2.0f + 0.03f,
        format("asin bends: 100 px must turn MORE than twice what 50 px turns; "
               ~ "got %g deg and %g deg (ratio %g)",
               got[0], got[1], got[0] / got[1]));
}

// -------------------------------------------------------------------------
// 6 — a pinned mode's pin survives the gesture untouched.
// -------------------------------------------------------------------------
unittest {
    setup("origin");
    Vec3 pivot0 = acenCenter();
    int nx, ny, fx, fy; pressPixels(pivot0, nx, ny, fx, fy);
    Vec3 pv; Vec3[] before;
    auto t = rotateFrom(nx, ny, 140, 0, pv, before);
    assert(t.valid, "the gesture must have run");

    auto a = acenAttrs();
    assert(a["userPlaced"] == "false",
        "actr.origin: an off-gizmo rotate must not place a user pin; got "
        ~ "userPlaced=" ~ a["userPlaced"]);
    foreach (k; ["cenX", "cenY", "cenZ"])
        assert(fabs(a[k].to!float) < 1e-4f,
            format("actr.origin: the pivot must stay at the world origin; %s=%s",
                   k, a[k]));
}
