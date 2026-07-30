// Topology Pen — WHY a Ctrl+LMB Slide press did not arm, over
// `/api/tool/state` (doc/tasks/work/0482-topopen-move-nonvertex.md item 3
// follow-up).
//
// The blind spot this closes: `onCtrlLmbDown` declines on two structurally
// different outcomes, and both used to leave the exact same observable state
// (`slideArmed:false`, `slideSeed:-1`, because the seed is only assigned once
// the gesture arms):
//   * a genuine PICK MISS — no primary edge within the snap radius;
//   * a deliberate CONTRACT DECLINE — an edge was resolved, but neither
//     endpoint's rail resolves, so the shipped hold-fixed contract leaves
//     nothing to slide.
// A consumer that cannot separate those has to score every non-apply as a
// possible port-side pick failure. `slideDeclineReason` (+ `slideDeclineSeed`
// for the resolved-but-unarmed edge) makes the distinction explicit.
//
// Rig = the same 2-quad "domino" `test_topopen_slide_drag.d` uses
// (F0=[0,1,2,3], F1=[1,4,5,2] sharing edge 1-2), because it already contains
// both shapes in one mesh:
//   * edge 3-0 — both endpoints valence-2, each rail resolves -> ARMS;
//   * edge 1-2 — the shared interior edge, both endpoints hit the "2+ distinct
//     continuation candidates" open case -> declines with `no_continuation`.
// No background layer: Slide is a pure topology gesture and never consults the
// CONS surface hit, so adding one would only add moving parts.
//
// Presses are DOWN-only (`ctrlDown`), so each probe reads the arm decision the
// press itself made, with no release/commit in between — the same idiom
// test_topopen_move_state.d uses. A matching UP is sent afterwards so the
// harness's own button state does not leak into the next probe.
//
// Run via: ./run_test.d topopen_slide_decline_state

import topopen_place_helpers;
import std.json;
import std.math   : sqrt;
import std.format : format;

void main() {}

enum uint LCTRL = 0x0040;   // KMOD_LCTRL — the Slide gesture's own modifier

// The tool's own screen-space pick tolerance (`topoPenSnapPx`), mirrored so
// the "far from every edge" precondition is stated in the same units.
enum float kSnapPx = 15.0f;

string dominoMeshBody() {
    return `{
        "vertices":[[0,0,0],[1,0,0],[1,0,1],[0,0,1],[2,0,0],[2,0,1]],
        "faces":[[0,1,2,3],[1,4,5,2]]
    }`;
}

string viewportLine(int vpX, int vpY, int vpW, int vpH) {
    return format(`{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                  vpX, vpY, vpW, vpH);
}

/// A Ctrl-held LEFT button DOWN with no partner — probes the arm decision.
string ctrlDown(double t, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,`
                ~ `"clicks":1,"mod":%u}`, t, px, py, LCTRL);
}

string ctrlUp(double t, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,`
                ~ `"clicks":1,"mod":%u}`, t, px, py, LCTRL);
}

/// Distance from (px,py) to the SEGMENT (ax,ay)-(bx,by), in pixels.
float distToSeg(float px, float py, float ax, float ay, float bx, float by) {
    float vx = bx - ax, vy = by - ay;
    float wx = px - ax, wy = py - ay;
    float len2 = vx * vx + vy * vy;
    float t = len2 > 1e-9f ? (wx * vx + wy * vy) / len2 : 0.0f;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    float dx = px - (ax + vx * t), dy = py - (ay + vy * t);
    return sqrt(dx * dx + dy * dy);
}

/// Index of the (unordered) edge a-b in the layer's edge list, or -1.
int edgeIndexOf(int[2][] edges, int a, int b) {
    foreach (i, e; edges) {
        if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) return cast(int)i;
    }
    return -1;
}

unittest {
    postJson("/api/reset", "");
    auto lr = postJson("/api/load-mesh", dominoMeshBody());
    assert(lr["status"].str == "ok", "load-mesh (domino) failed: " ~ lr.toString);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.35, 0.5, 6.0, 1.0, 0.0, 0.5));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);
    immutable string vpl = viewportLine(c.vpX, c.vpY, c.width, c.height);

    assert(vertexCountLayer(0) == 6 && edgeCountLayer(0) == 7 && faceCountLayer(0) == 2,
        "setup: pre-state must be the untouched domino (6v/7e/2f)");

    auto edges = readEdgesLayer(0);
    immutable int e12 = edgeIndexOf(edges, 1, 2);
    immutable int e30 = edgeIndexOf(edges, 3, 0);
    assert(e12 >= 0 && e30 >= 0, "setup: the domino must carry both edge 1-2 and edge 3-0");

    auto verts = readVerticesLayer(0);
    float[6] px, py;
    foreach (i; 0 .. 6) {
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float)verts[i][0], cast(float)verts[i][1],
                                    cast(float)verts[i][2]), vp, sx, sy),
            format("setup: vertex %d must project on-screen", i));
        px[i] = sx; py[i] = sy;
    }

    cmd("tool.set mesh.topoPen on");

    // --- BASELINE: a freshly activated pen has no decline to explain.
    auto s0 = getJson("/api/tool/state");
    assert("slideDeclineReason" in s0,
        "/api/tool/state must publish slideDeclineReason: " ~ s0.toString);
    assert("slideDeclineSeed" in s0,
        "/api/tool/state must publish slideDeclineSeed: " ~ s0.toString);
    assert(s0["slideDeclineReason"].str == "none",
        "a freshly activated pen must report no decline; got " ~ s0["slideDeclineReason"].str);
    assert(cast(int)s0["slideDeclineSeed"].integer == -1,
        "a freshly activated pen must report no declined seed");

    // --- CASE 1: a real PICK MISS -> "no_edge".
    // Top-left corner of the viewport, asserted below to be clear of every
    // projected edge of the domino (which sits around the viewport centre).
    immutable int mx = c.vpX + 8, my = c.vpY + 8;
    foreach (e; edges) {
        float d = distToSeg(mx, my, px[e[0]], py[e[0]], px[e[1]], py[e[1]]);
        assert(d > kSnapPx,
            format("setup: the miss pixel must be farther than %.0fpx from edge %d-%d; "
                 ~ "got %.1fpx", kSnapPx, e[0], e[1], d));
    }

    postJson("/api/play-events", vpl ~ "\n" ~ ctrlDown(10.0, mx, my) ~ "\n");
    waitPlayerIdle();

    auto s1 = getJson("/api/tool/state");
    assert(s1["slideDeclineReason"].str == "no_edge",
        "a Ctrl+LMB press with no edge in range must report \"no_edge\"; got "
      ~ s1["slideDeclineReason"].str);
    assert(cast(int)s1["slideDeclineSeed"].integer == -1,
        "a pick miss resolved no edge, so it must report no declined seed");
    assert(s1["slideArmed"].type == JSONType.false_, "a pick miss must not arm Slide");

    postJson("/api/play-events", vpl ~ "\n" ~ ctrlUp(20.0, mx, my) ~ "\n");
    waitPlayerIdle();

    // --- CASE 2: the CONTRACT DECLINE -> "no_continuation", and the resolved
    // edge is named. Edge 1-2 is the shared interior edge: both endpoints land
    // in the "2+ distinct continuation candidates" open case, so no rail
    // resolves at either end.
    immutable int ix = cast(int)((px[1] + px[2]) * 0.5f);
    immutable int iy = cast(int)((py[1] + py[2]) * 0.5f);

    postJson("/api/play-events", vpl ~ "\n" ~ ctrlDown(10.0, ix, iy) ~ "\n");
    waitPlayerIdle();

    auto s2 = getJson("/api/tool/state");
    assert(s2["slideDeclineReason"].str == "no_continuation",
        "a Ctrl+LMB press on the ambiguous interior edge must report "
      ~ "\"no_continuation\", NOT a pick miss; got " ~ s2["slideDeclineReason"].str);
    assert(cast(int)s2["slideDeclineSeed"].integer == e12,
        format("the declined seed must name the edge that WAS resolved (1-2, index %d); got %d "
             ~ "— this is what lets a differential check the pick itself, not just that a "
             ~ "pick happened", e12, cast(int)s2["slideDeclineSeed"].integer));
    assert(s2["slideArmed"].type == JSONType.false_,
        "the contract decline must still leave Slide unarmed");
    assert(cast(int)s2["slideSeed"].integer == -1,
        "`slideSeed` keeps its ARMED-gesture meaning and must stay -1 on a decline");

    postJson("/api/play-events", vpl ~ "\n" ~ ctrlUp(20.0, ix, iy) ~ "\n");
    waitPlayerIdle();

    assert(vertexCountLayer(0) == 6 && edgeCountLayer(0) == 7 && faceCountLayer(0) == 2,
        "the declined press+release must not change topology");
    auto after = readVerticesLayer(0);
    foreach (i; 0 .. 6) {
        foreach (k; 0 .. 3) {
            assert(after[i][k] == verts[i][k],
                format("the declined press+release must not move vertex %d", i));
        }
    }

    // --- CASE 3: the DISCRIMINATOR — a press that DOES arm must report
    // "none". Without this, a stuck-at-"none" field (or one cleared by the
    // arm-reset that runs before every LEFT press) would look identical to a
    // working one in cases 1-2. Edge 3-0 has two valence-2 endpoints, so both
    // rails resolve.
    immutable int ax = cast(int)((px[3] + px[0]) * 0.5f);
    immutable int ay = cast(int)((py[3] + py[0]) * 0.5f);

    postJson("/api/play-events", vpl ~ "\n" ~ ctrlDown(10.0, ax, ay) ~ "\n");
    waitPlayerIdle();

    auto s3 = getJson("/api/tool/state");
    assert(s3["slideArmed"].type == JSONType.true_,
        "a press on edge 3-0 (both rails resolve) must ARM Slide");
    assert(cast(int)s3["slideSeed"].integer == e30,
        format("the armed seed must be edge 3-0 (index %d); got %d",
               e30, cast(int)s3["slideSeed"].integer));
    assert(s3["slideDeclineReason"].str == "none",
        "an ARMED press must report no decline; got " ~ s3["slideDeclineReason"].str);
    assert(cast(int)s3["slideDeclineSeed"].integer == -1,
        "an armed press must clear any earlier declined seed");

    // Release at the SAME pixel — a zero-delta no-op — and the reason must
    // still read "none" (the release path neither sets nor clears it).
    postJson("/api/play-events", vpl ~ "\n" ~ ctrlUp(20.0, ax, ay) ~ "\n");
    waitPlayerIdle();

    auto s4 = getJson("/api/tool/state");
    assert(s4["slideArmed"].type == JSONType.false_, "the release must disarm Slide");
    assert(s4["slideDeclineReason"].str == "none",
        "a committed (zero-delta) gesture must not invent a decline reason; got "
      ~ s4["slideDeclineReason"].str);
}
