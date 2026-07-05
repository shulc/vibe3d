// Slice tool (mesh.sliceTool) — CUSTOM-AXIS ROTATE GIZMO (task 0287).
//
// Owner observation: when the Slice `axis` is set to Custom, an ADDITIONAL gizmo
// appears that ROTATES the cut plane around the axis defined by the two drawn
// points (the Start→End line). The two points stay put; the plane tilts about
// the line. vibe3d draws that as a RING around the line (its plane ⟂ the line);
// dragging it rotates the Custom `vector` about the line, which under the
// extrusion model (normal = cross(lineDir, vector)) tilts the plane about the
// line while both endpoints stay fixed and remain in the plane.
//
// This drives a REAL ring drag through /api/play-events (the interactive
// onMouseButtonDown/Motion/Up path). It is fully deterministic: it reconstructs
// the EXACT ring geometry the tool builds — centre = line midpoint, plane ⟂ the
// line, world radius = gizmoSize(centre, vp, 46 px) (the tool's RING_RADIUS_PX)
// — and drags between two world points that lie exactly ON that ring, so the DOWN
// pixel is guaranteed to grab the ring and the UP pixel maps to a known rotation
// angle about the line. It then asserts, from /api/tool/state:
//   * the two endpoints (start_/end_) DID NOT move,
//   * the Custom vector CHANGED,
//   * the plane normal cross(lineDir, vector) rotated by the expected angle about
//     the line, stays ⟂ the line, and both endpoints stay in the plane,
//   * and the ring is Custom-ONLY (part id absent from /api/tool/handles for a
//     non-Custom axis).

import std.net.curl;
import std.json;
import std.math  : abs, fabs, sqrt, sin, cos, atan2, PI;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers;   // Vec3, Viewport, fetchCamera, viewportFromCamera, projectToWindow, gizmoSize, buildDragLog, playAndWait, dot, cross, normalize

void main() {}

enum string BASE = "http://localhost:8080";

// Must match SliceTool.RING_RADIUS_PX (the screen-constant ring radius). The
// world radius is gizmoSize(centre, vp, RING_RADIUS_PX) — drag_helpers.gizmoSize
// with gizmoPixels = RING_RADIUS_PX reproduces the tool's ringRadiusWorld exactly
// (both are 2·RING_RADIUS_PX·depth / (proj[5]·height)).
enum float RING_RADIUS_PX = 46.0f;

void cmd(string s) {
    auto resp = cast(string) post(BASE ~ "/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

void resetCube() {
    auto resp = cast(string) post(BASE ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

JSONValue getModel()     { return parseJSON(cast(string) get(BASE ~ "/api/model")); }
JSONValue getToolState() { return parseJSON(cast(string) get(BASE ~ "/api/tool/state")); }

size_t vertCount() { return getModel()["vertices"].array.length; }
size_t faceCount() { return getModel()["faces"].array.length; }

void settle() { Thread.sleep(dur!"msecs"(180)); }   // post-playback drain guard

void scr(Vec3 w, const ref Viewport vp, out int px, out int py) {
    float fx, fy;
    bool ok = projectToWindow(w, vp, fx, fy);
    assert(ok, "world point projected off-screen — camera assumptions broke");
    px = cast(int)(fx + 0.5f);
    py = cast(int)(fy + 0.5f);
}

void toolLine(out Vec3 s, out Vec3 e) {
    auto st = getToolState();
    s = Vec3(cast(float)st["startX"].floating, cast(float)st["startY"].floating,
             cast(float)st["startZ"].floating);
    e = Vec3(cast(float)st["endX"].floating, cast(float)st["endY"].floating,
             cast(float)st["endZ"].floating);
}

Vec3 toolVector() {
    auto st = getToolState();
    return Vec3(cast(float)st["vectorX"].floating, cast(float)st["vectorY"].floating,
                cast(float)st["vectorZ"].floating);
}

// The two in-plane world axes of the tool's auto construction plane (mirrors
// test_slice_input_model.inPlaneAxes): U along, V across.
void inPlaneAxes(const ref Viewport vp, out Vec3 U, out Vec3 V) {
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    float ax = fabs(camBack.x), ay = fabs(camBack.y), az = fabs(camBack.z);
    if (ax >= ay && ax >= az)       { V = Vec3(0,1,0); U = Vec3(0,0,1); }
    else if (ay >= ax && ay >= az)  { V = Vec3(1,0,0); U = Vec3(0,0,1); }
    else                            { V = Vec3(1,0,0); U = Vec3(0,1,0); }
}

// Deterministic in-plane basis for the ring — MUST match SliceTool.sliceRingPlaneBasis.
void ringPlaneBasis(Vec3 axis, out Vec3 right, out Vec3 up) {
    Vec3 a = normalize(axis);
    Vec3 r = cross(a, Vec3(0, 1, 0));
    if (sqrt(dot(r, r)) < 1e-6f) r = cross(a, Vec3(1, 0, 0));
    right = normalize(r);
    up    = normalize(cross(a, right));
}

float len(Vec3 v) { return sqrt(dot(v, v)); }

// Signed angle from `from` to `to` about `axis` (matches SliceTool.signedAngleAboutAxis).
float signedAngle(Vec3 from, Vec3 to, Vec3 axis) {
    Vec3 a = normalize(axis);
    return atan2(dot(cross(from, to), a), dot(from, to));
}

// ---------------------------------------------------------------------------
// Draw a Custom-axis line, then DRAG THE ROTATE RING and assert the plane tilts
// about the line by the expected angle while the endpoints stay put.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    assert(vertCount() == 8 && faceCount() == 6, "fresh cube must be 8v/6f");

    cmd("tool.set mesh.sliceTool on");
    settle();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 U, V;
    inPlaneAxes(vp, U, V);

    // (1) FIRST drag: draw a mid-plane line along U (through the origin).
    Vec3 A = U * (-0.6f), B = U * (0.6f);
    int ax, ay, bx, by;
    scr(A, vp, ax, ay);
    scr(B, vp, bx, by);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, ax, ay, bx, by, 20, 0), BASE);
    settle();
    assert(getToolState()["lineDrawn"].type == JSONType.TRUE, "first drag draws a line");

    Vec3 s0, e0; toolLine(s0, e0);

    // (2) Engage Custom axis + a Custom vector across the line (V ⟂ the U-line).
    cmd("tool.attr mesh.sliceTool axis custom");
    cmd(format("tool.attr mesh.sliceTool vectorX %g", V.x));
    cmd(format("tool.attr mesh.sliceTool vectorY %g", V.y));
    cmd(format("tool.attr mesh.sliceTool vectorZ %g", V.z));
    settle();
    assert(getToolState()["axis"].str == "custom", "axis is now Custom");

    Vec3 vec0    = toolVector();
    Vec3 lineDir = normalize(e0 - s0);
    Vec3 n0      = normalize(cross(lineDir, vec0));   // plane normal before the tilt

    // (3) Build the EXACT ring the tool draws: centre = midpoint, plane ⟂ line,
    //     world radius = gizmoSize(centre, vp, RING_RADIUS_PX). Two world points
    //     ON the ring (α0, α1) give the DOWN pixel (grabs the ring) and the UP
    //     pixel (a known rotation angle about the line).
    Vec3 center = (s0 + e0) * 0.5f;
    float radius = gizmoSize(center, vp, RING_RADIUS_PX);
    Vec3 rgt, upv;
    ringPlaneBasis(lineDir, rgt, upv);
    enum float A0 = PI * 0.5f;             // start grab at the ring "top"
    enum float DA = 0.7f;                  // ≈ +40° tilt about the line
    Vec3 P0 = center + rgt * (cos(A0) * radius)         + upv * (sin(A0) * radius);
    Vec3 P1 = center + rgt * (cos(A0 + DA) * radius)    + upv * (sin(A0 + DA) * radius);
    int p0x, p0y, p1x, p1y;
    scr(P0, vp, p0x, p0y);
    scr(P1, vp, p1x, p1y);
    // The grab pixel must be clear of the endpoint squares (else it grabs an
    // endpoint instead of the ring — a broken test setup, not a tool bug).
    int s0x, s0y, e0x, e0y;
    scr(s0, vp, s0x, s0y);
    scr(e0, vp, e0x, e0y);
    float dStart = sqrt(cast(float)((p0x-s0x)*(p0x-s0x) + (p0y-s0y)*(p0y-s0y)));
    float dEnd   = sqrt(cast(float)((p0x-e0x)*(p0x-e0x) + (p0y-e0y)*(p0y-e0y)));
    assert(dStart > 12.0f && dEnd > 12.0f,
           format("ring grab pixel must be clear of endpoints (dStart=%.1f dEnd=%.1f)", dStart, dEnd));

    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, p0x, p0y, p1x, p1y, 20, 0), BASE);
    settle();

    // (4a) The two endpoints DID NOT move — a rotate never touches the line.
    Vec3 s1, e1; toolLine(s1, e1);
    assert(len(s1 - s0) < 1e-3f, format("Start must stay put (|Δ|=%.4f)", len(s1 - s0)));
    assert(len(e1 - e0) < 1e-3f, format("End must stay put (|Δ|=%.4f)", len(e1 - e0)));

    // (4b) The Custom vector CHANGED (the drag tilted it).
    Vec3 vec1 = toolVector();
    assert(len(vec1 - vec0) > 1e-3f, format("rotate drag must change the vector (|Δ|=%.4f)", len(vec1 - vec0)));

    // (4c) The plane normal rotated by ~DA about the line, stays ⟂ the line, and
    //      both endpoints remain in the plane (cross(lineDir,·) ⟂ lineDir).
    Vec3 n1 = normalize(cross(lineDir, vec1));
    assert(fabs(dot(n1, lineDir)) < 1e-3f, "tilted normal stays ⟂ the line");
    assert(fabs(dot(e0 - s0, n1)) < 1e-3f, "the line (both endpoints) stays in the plane");
    float measured = signedAngle(n0, n1, lineDir);
    // The screen-interpolated drag lands its FINAL motion + up at P1, so the
    // final tilt is DA about the line (sign may fold with the basis handedness —
    // compare magnitude, which is what "tilts by the expected angle" means).
    assert(fabs(fabs(measured) - DA) < 0.06f,
           format("plane must tilt ≈%.3f rad about the line, measured %.3f", DA, measured));

    cmd("tool.set mesh.sliceTool off");
    settle();
}

// ---------------------------------------------------------------------------
// The rotate ring is CUSTOM-ONLY: its handle part id (3) is registered (and so
// exposed by /api/tool/handles) only when axis == Custom, absent otherwise. This
// asserts the "gizmo only shows for axis==Custom" requirement at the state level,
// independent of pixels.
// ---------------------------------------------------------------------------
enum int PART_ROTATE = 3;   // SliceTool.DragRotate

bool ringHandleFound() {
    // /api/tool/handles (task 0234): the rotate ring is registered (and on-camera,
    // its anchor = the line midpoint) only when axis == Custom, so fetchHandlePart
    // resolves it only then.
    double sx, sy; bool found;
    fetchHandlePart(PART_ROTATE, sx, sy, found, BASE);
    return found;
}

unittest {
    resetCube();
    cmd("tool.set mesh.sliceTool on");
    settle();

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 U, V;
    inPlaneAxes(vp, U, V);

    // Draw a line (needed for any handle to render). Force at least one draw
    // frame by requesting the model (the app renders between requests).
    Vec3 A = U * (-0.6f), B = U * (0.6f);
    int ax, ay, bx, by;
    scr(A, vp, ax, ay);
    scr(B, vp, bx, by);
    playAndWait(buildDragLog(vp.x, vp.y, vp.width, vp.height, ax, ay, bx, by, 20, 0), BASE);
    settle();

    // Default/classified axis (NOT Custom right after a fresh draw): no ring.
    // (classifyDrawnPlaneAxis may pick X/Y/Z/Custom; force a known non-Custom.)
    cmd("tool.attr mesh.sliceTool axis y");
    settle();
    assert(!ringHandleFound(), "rotate ring must be ABSENT for a non-Custom axis");

    // Custom axis: the ring registers.
    cmd("tool.attr mesh.sliceTool axis custom");
    settle();
    assert(ringHandleFound(), "rotate ring must be PRESENT for axis == Custom");

    cmd("tool.set mesh.sliceTool off");
    settle();
}
