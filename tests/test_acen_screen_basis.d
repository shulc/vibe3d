// Task 0081: AXIS Screen-basis (camera remap, not Auto fallback).
//
// Verifies:
// - Mode.Screen publishes a camera-aligned basis:
//     right = camUp,  up = camRight,  fwd = camFwd   (capture-verified remap).
// - axis.type == 8 (Screen) and axis.isAuto == false (not an Auto fallback).
// - Basis is right-handed and orthonormal.
// - Basis is selection-independent (polygon selection / no selection → same basis).
// - Basis tracks the live camera (changes when the camera orbits).
// - World mode still returns identity (no-regression sentinel).

import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs, sqrt, sin, cos;
import std.format: format;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetEmpty() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset?empty=true", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
}

void setCamera(float az, float el, float dist,
               float fx = 0.0f, float fy = 0.0f, float fz = 0.0f) {
    auto body_ = format(
        `{"azimuth":%f,"elevation":%f,"distance":%f,`
      ~ `"focus":{"x":%f,"y":%f,"z":%f}}`,
        az, el, dist, fx, fy, fz);
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/camera", body_));
    assert(j["status"].str == "ok", "/api/camera failed: " ~ j.toString);
}

// Run a fresh pipeline.evaluate via the HTTP eval endpoint and return
// the "axis" sub-object.  The eval uses cameraView.viewport() at call
// time, so a preceding /api/camera POST is immediately visible here.
JSONValue evalAxis() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/toolpipe/eval", ""));
    return j["axis"];
}

// ---------------------------------------------------------------------------
// Camera-frame math — mirrors view.d + math.lookAt exactly so tests can
// compute the expected basis without a round-trip through the app.
//
//   offset = sphericalToCartesian(az, el, dist)
//   eye    = focus(=origin) + offset
//   f      = normalize(focus - eye) = normalize(-offset)   [view direction]
//   r      = normalize(cross(f, worldUp=(0,1,0)))           [camera right]
//   u      = cross(r, f)                                   [camera up]
//
// Screen remap: axis.right=camUp(u), axis.up=camRight(r), axis.fwd=camFwd(f).
// ---------------------------------------------------------------------------

struct CamFrame { float[3] right, up, fwd; }

private float _len3(float[3] v) {
    return sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
}
private float[3] _norm3(float[3] v) {
    float l = _len3(v);
    return [v[0]/l, v[1]/l, v[2]/l];
}
private float[3] _cross3(float[3] a, float[3] b) {
    return [a[1]*b[2]-a[2]*b[1],
            a[2]*b[0]-a[0]*b[2],
            a[0]*b[1]-a[1]*b[0]];
}
private float _dot3(float[3] a, float[3] b) {
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}

CamFrame computeCamFrame(float az, float el, float dist) {
    float[3] offset = [
        dist * cos(el) * sin(az),
        dist * sin(el),
        dist * cos(el) * cos(az),
    ];
    float[3] fwd   = _norm3([-offset[0], -offset[1], -offset[2]]);
    float[3] wup   = [0.0f, 1.0f, 0.0f];
    float[3] right = _norm3(_cross3(fwd, wup));
    float[3] up    = _cross3(right, fwd);
    return CamFrame(right, up, fwd);
}

// Read one of axis.right / axis.up / axis.fwd as a float[3].
// Handles all JSON numeric types (float_, integer, uinteger).
float[3] axisVec(JSONValue ax, string key) {
    auto arr = ax[key].array;
    float fromJ(JSONValue v) {
        switch (v.type) {
            case JSONType.float_:   return cast(float)v.floating;
            case JSONType.integer:  return cast(float)v.integer;
            case JSONType.uinteger: return cast(float)v.uinteger;
            default: assert(false, "non-numeric in axis vector: " ~ v.toString);
        }
    }
    return [fromJ(arr[0]), fromJ(arr[1]), fromJ(arr[2])];
}

// Common setup: empty scene → cube → move tool → actr.screen.
void setupScreenTool() {
    resetEmpty();
    cmd(`{"id":"prim.cube"}`);
    cmd("tool.set move on");
    cmd("actr.screen");
}

// -------------------------------------------------------------------------
// Case 1 — Basis matches the camera remap; type=8; isAuto=false.
// -------------------------------------------------------------------------

unittest { // Screen basis = camera remap; type=8, isAuto=false
    setupScreenTool();
    immutable float az = 0.5f, el = 0.4f, dist = 3.0f;
    setCamera(az, el, dist);
    auto ax = evalAxis();

    // Packet metadata
    assert(ax["type"].integer == 8,
        "Screen must publish type=8, got " ~ ax["type"].toString);
    assert(ax["isAuto"].type == JSONType.FALSE,
        "Screen must publish isAuto=false");

    auto got   = axisVec(ax, "right");
    auto gotUp = axisVec(ax, "up");
    auto gotFw = axisVec(ax, "fwd");
    auto cf    = computeCamFrame(az, el, dist);

    immutable float tol = 1e-4f;
    // axis.right = camUp, axis.up = camRight, axis.fwd = camFwd
    foreach (i; 0 .. 3) {
        assert(abs(got[i]   - cf.up[i])    < tol,
            format("right[%d]: expected camUp %f, got %f",   i, cf.up[i],    got[i]));
        assert(abs(gotUp[i] - cf.right[i]) < tol,
            format("up[%d]: expected camRight %f, got %f",   i, cf.right[i], gotUp[i]));
        assert(abs(gotFw[i] - cf.fwd[i])   < tol,
            format("fwd[%d]: expected camFwd %f, got %f",    i, cf.fwd[i],   gotFw[i]));
    }
}

// -------------------------------------------------------------------------
// Case 2 — Right-handed and orthonormal.
// -------------------------------------------------------------------------

unittest { // Screen basis is right-handed and orthonormal
    setupScreenTool();
    setCamera(0.5f, 0.4f, 3.0f);
    auto ax = evalAxis();
    auto r  = axisVec(ax, "right");
    auto u  = axisVec(ax, "up");
    auto f  = axisVec(ax, "fwd");

    immutable float tol = 1e-4f;

    // Unit length
    assert(abs(_len3(r) - 1.0f) < tol, "right not unit: " ~ _len3(r).to!string);
    assert(abs(_len3(u) - 1.0f) < tol, "up not unit: "    ~ _len3(u).to!string);
    assert(abs(_len3(f) - 1.0f) < tol, "fwd not unit: "   ~ _len3(f).to!string);

    // Pairwise orthogonal
    assert(abs(_dot3(r, u)) < tol, "right·up != 0: "  ~ _dot3(r, u).to!string);
    assert(abs(_dot3(r, f)) < tol, "right·fwd != 0: " ~ _dot3(r, f).to!string);
    assert(abs(_dot3(u, f)) < tol, "up·fwd != 0: "    ~ _dot3(u, f).to!string);

    // Right-handed: cross(right, up) ≈ fwd
    auto rxu = _cross3(r, u);
    foreach (i; 0 .. 3)
        assert(abs(rxu[i] - f[i]) < tol,
            format("cross(right,up)[%d] = %f, fwd[%d] = %f", i, rxu[i], i, f[i]));
}

// -------------------------------------------------------------------------
// Case 3 — Selection-independent.
// -------------------------------------------------------------------------

unittest { // Screen basis is selection-independent
    setupScreenTool();
    setCamera(0.5f, 0.4f, 3.0f);

    // (a) polygon face selected
    auto selR = parseJSON(cast(string)post(baseUrl ~ "/api/select",
        `{"mode":"polygons","indices":[4]}`));
    assert(selR["status"].str == "ok", "polygon select failed");
    auto axPoly = evalAxis();
    auto rPoly  = axisVec(axPoly, "right");
    auto uPoly  = axisVec(axPoly, "up");
    auto fPoly  = axisVec(axPoly, "fwd");

    // (b) vertex mode, nothing selected
    cmd("select.typeFrom vertex");
    auto axNone = evalAxis();
    auto rNone  = axisVec(axNone, "right");
    auto uNone  = axisVec(axNone, "up");
    auto fNone  = axisVec(axNone, "fwd");

    immutable float tol = 1e-5f;
    foreach (i; 0 .. 3) {
        assert(abs(rPoly[i] - rNone[i]) < tol,
            format("right[%d] poly=%f none=%f — must be equal", i, rPoly[i], rNone[i]));
        assert(abs(uPoly[i] - uNone[i]) < tol,
            format("up[%d] poly=%f none=%f",                    i, uPoly[i], uNone[i]));
        assert(abs(fPoly[i] - fNone[i]) < tol,
            format("fwd[%d] poly=%f none=%f",                   i, fPoly[i], fNone[i]));
    }
}

// -------------------------------------------------------------------------
// Case 4 — Orbit tracking: basis follows the live camera.
// -------------------------------------------------------------------------

unittest { // Screen basis tracks camera orbit
    setupScreenTool();
    immutable float az1 = 0.5f,  el1 =  0.4f, dist1 = 3.0f;
    immutable float az2 = 1.6f,  el2 = -0.3f, dist2 = 4.0f;

    setCamera(az1, el1, dist1);
    auto ax1 = evalAxis();
    auto r1  = axisVec(ax1, "right");
    auto f1  = axisVec(ax1, "fwd");

    setCamera(az2, el2, dist2);
    auto ax2 = evalAxis();
    auto r2  = axisVec(ax2, "right");
    auto u2  = axisVec(ax2, "up");
    auto f2  = axisVec(ax2, "fwd");

    // Basis must change when the camera changes
    bool changed = false;
    foreach (i; 0 .. 3)
        if (abs(r1[i] - r2[i]) > 1e-3f || abs(f1[i] - f2[i]) > 1e-3f)
            { changed = true; break; }
    assert(changed, "Screen basis did not change after orbit — not tracking camera");

    // Second basis must match the expected camera remap for camera 2
    auto cf2 = computeCamFrame(az2, el2, dist2);
    immutable float tol = 1e-4f;
    foreach (i; 0 .. 3) {
        assert(abs(r2[i] - cf2.up[i])    < tol,
            format("cam2 right[%d]: expected (camUp) %f, got %f",    i, cf2.up[i],    r2[i]));
        assert(abs(u2[i] - cf2.right[i]) < tol,
            format("cam2 up[%d]: expected (camRight) %f, got %f",    i, cf2.right[i], u2[i]));
        assert(abs(f2[i] - cf2.fwd[i])   < tol,
            format("cam2 fwd[%d]: expected (camFwd) %f, got %f",     i, cf2.fwd[i],   f2[i]));
    }
}

// -------------------------------------------------------------------------
// Case 5 — No-regression sentinel: World mode still returns identity.
// -------------------------------------------------------------------------

unittest { // World mode still returns identity (no-regression)
    resetEmpty();
    cmd(`{"id":"prim.cube"}`);
    cmd("tool.set move on");
    cmd("tool.pipe.attr axis mode world");
    setCamera(0.5f, 0.4f, 3.0f);
    auto ax = evalAxis();
    auto r  = axisVec(ax, "right");
    auto u  = axisVec(ax, "up");
    auto f  = axisVec(ax, "fwd");

    immutable float tol = 1e-5f;
    assert(abs(r[0]-1.0f) < tol && abs(r[1]) < tol && abs(r[2]) < tol,
        "World mode right != +X: " ~ r.to!string);
    assert(abs(u[0]) < tol && abs(u[1]-1.0f) < tol && abs(u[2]) < tol,
        "World mode up != +Y: "    ~ u.to!string);
    assert(abs(f[0]) < tol && abs(f[1]) < tol && abs(f[2]-1.0f) < tol,
        "World mode fwd != +Z: "   ~ f.to!string);
}
