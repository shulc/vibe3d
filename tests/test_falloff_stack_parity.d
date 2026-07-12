// test_falloff_stack_parity.d — integration fixture proving the analytic
// multiply-stack product formula end-to-end at the live transform level.
//
// What this pins:
//   The classic "two falloffs multiplied" behavior — the primary special case
//   of vibe3d's N-falloff honest stack — produces per-vertex displacements
//   that equal fullDisplacement · (w_primary · w_secondary) at every vertex.
//
// This is the integration-level parity proof complementing:
//   • test_falloff_combine.d  (unit: combiner produces correct Composite packet)
//   • test_falloff_multi.d    (lifecycle: stacked instance reaches live transform)
//
// Setup: two LINEAR falloffs, orthogonal axes (X and Y), both shape=linear,
// mix=Multiply.  A Y-arrow drag with all 8 cube verts selected produces
// per-vertex Y displacements whose RATIOS equal the analytic product weights
// exactly (weights evaluated at frozen baseline positions → invariant across
// all 20 drag frames; weights are exact IEEE 754 fractions for cube corners).
//
// Cube vertex layout (default cube, ±0.5):
//   v0=(-0.5,-0.5,-0.5)  v1=( 0.5,-0.5,-0.5)
//   v2=( 0.5, 0.5,-0.5)  v3=(-0.5, 0.5,-0.5)
//   v4=(-0.5,-0.5, 0.5)  v5=( 0.5,-0.5, 0.5)
//   v6=( 0.5, 0.5, 0.5)  v7=(-0.5, 0.5, 0.5)
//
// Primary falloff: Linear along X, start=(-1,0,0), end=(1,0,0), shape=linear
//   t(x)  = (x+1)/2        w_X(x) = 1 − t
//   w_X(−0.5) = 0.75       w_X( 0.5) = 0.25
//
// Secondary (falloff#1): Linear along Y, start=(0,−1,0), end=(0,1,0),
//   shape=linear, mix=Multiply
//   w_Y(−0.5) = 0.75       w_Y( 0.5) = 0.25
//
// Combined Multiply-stack weights at the 4 XY groups:
//   v0,v4: 0.75·0.75 = 9/16   v1,v5: 0.25·0.75 = 3/16
//   v2,v6: 0.25·0.25 = 1/16   v3,v7: 0.75·0.25 = 3/16
//
// Key assertions (all ratio-based; independent of drag magnitude):
//   dy(v0)/dy(v2) ≈ 9   — decisive Multiply discriminator
//                           (Add ⇒ 3, Max ⇒ 3, Min ⇒ 1)
//   dy(v0)/dy(v1) ≈ 3   — linear-X weight ratio (same Y-weight, different X)
//   dy(v1) ≈ dy(v3)     — product is symmetric: 0.25·0.75 = 0.75·0.25
//   dy(v4) ≈ dy(v0)     — Z doesn't affect either linear falloff
//   Absolute formula: dy(v) ≈ dyFull · combined_weight(v)  (within 5%)

import std.net.curl;
import std.json;
import std.math  : fabs, sqrt;
import std.conv  : to;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string c) {
    auto r = postJson("/api/command", c);
    assert(r["status"].str == "ok",
        "command failed: " ~ c ~ " → " ~ r.toString);
}

void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
}

// ---------------------------------------------------------------------------
// Integration proof: Multiply-combine of two linear falloffs produces
// per-vertex displacements equal to fullDisplacement × (w_X · w_Y).
// ---------------------------------------------------------------------------
unittest {
    // approx: absolute-difference check with a caller-supplied epsilon.
    bool approx(double a, double b, double eps) {
        return fabs(a - b) < eps;
    }

    resetCube();

    // Select all 8 cube vertices.
    auto selResp = post(baseUrl ~ "/api/select",
                        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(parseJSON(cast(string) selResp)["status"].str == "ok",
        "select all verts failed: " ~ cast(string) selResp);

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    // Activate the move tool.
    cmd("tool.set move");

    // ── Primary: Linear along X ───────────────────────────────────────────
    // start=(-1,0,0), end=(1,0,0), shape=linear.
    // t(x) = (x+1)/2  →  w_X(−0.5)=0.75, w_X(0.5)=0.25.
    // NOTE: default shape is Linear; set it explicitly anyway so this test
    //       stays correct regardless of what the default happens to be —
    //       exact rational weights at cube corners require Linear.
    cmd("tool.pipe.attr falloff type linear");
    cmd(`tool.pipe.attr falloff start "-1,0,0"`);
    cmd(`tool.pipe.attr falloff end "1,0,0"`);
    cmd("tool.pipe.attr falloff shape linear");

    // ── Secondary: Linear along Y (mix=Multiply) ─────────────────────────
    // start=(0,−1,0), end=(0,1,0), shape=linear, mix=multiply.
    // t(y) = (y+1)/2  →  w_Y(−0.5)=0.75, w_Y(0.5)=0.25.
    // falloff.add creates a new stage (id="falloff#1") and sets its type;
    // shape is set explicitly here too, so the case doesn't depend on the
    // stage's default curve.
    cmd("falloff.add linear");
    cmd(`tool.pipe.attr falloff#1 start "0,-1,0"`);
    cmd(`tool.pipe.attr falloff#1 end "0,1,0"`);
    cmd("tool.pipe.attr falloff#1 shape linear");
    cmd("tool.pipe.attr falloff#1 mix multiply");

    // ── Project and drag the Y-axis gizmo arrow ───────────────────────────
    // ACEN.Auto for 8 selected verts → centroid at (0,0,0).
    // Drag 100 px along the Y arrow, 20 steps (each step delivers the same
    // world-space delta; weights are evaluated at frozen baseline positions,
    // so the ratio between any two verts' displacements equals the ratio of
    // their combined weights — exactly, not approximately).
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 pivot     = Vec3(0, 0, 0);
    float size     = gizmoSize(pivot, vp);
    Vec3 arrowBot  = Vec3(pivot.x, pivot.y + size / 6.0f, pivot.z);
    Vec3 arrowTip  = Vec3(pivot.x, pivot.y + size,         pivot.z);

    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowBot, vp, sx1, sy1), "Y-arrow base off-camera");
    assert(projectToWindow(arrowTip, vp, sx2, sy2), "Y-arrow tip off-camera");

    // Grab point at 70 % along the shaft.
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));

    // Drag direction along the arrow's screen-space projection.
    double sdx = sx2 - sx1, sdy = sy2 - sy1;
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(100.0 * sdx / sLen);
    int y1 = y0 + cast(int)(100.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);

    // ── Measure Y displacements ───────────────────────────────────────────
    double dy(int i) { return vertexPos(i)[1] - pre[i][1]; }

    double dy0 = dy(0);  // combined weight 9/16 = 0.5625
    double dy1 = dy(1);  // combined weight 3/16 = 0.1875
    double dy2 = dy(2);  // combined weight 1/16 = 0.0625
    double dy3 = dy(3);  // combined weight 3/16 = 0.1875
    double dy4 = dy(4);  // Z-mirror of v0; same weight 9/16

    // Highest-weight group must have moved measurably.
    assert(dy0 > 0.01,
        "v0 (combined weight 9/16) barely moved; dy0=" ~ dy0.to!string);
    // Lowest-weight group must have moved at all (weight 1/16 > 0).
    assert(dy2 > 1e-5,
        "v2 (combined weight 1/16) did not move; dy2=" ~ dy2.to!string);

    // ── Core product assertion: dy0/dy2 ≈ 9 ─────────────────────────────
    // (9/16) ÷ (1/16) = 9.
    // Disambiguation table for the same pair of individual weights (0.75, 0.25):
    //   Multiply : (0.75·0.25) / (0.75·0.25·... wait — v0 vs v2):
    //     v0 = 0.75·0.75 = 0.5625, v2 = 0.25·0.25 = 0.0625 → ratio 9
    //   Add      : (0.75+0.75) / (0.25+0.25) = 1.5/0.5 = 3   ← ruled out
    //   Max      :  0.75       / 0.25         = 3              ← ruled out
    //   Min      :  0.75       / 0.25         = 3              ← ruled out
    //   (Add with final clamp: 1.0/0.5=2 or 1/1=1)
    double ratio02 = dy0 / dy2;
    assert(approx(ratio02, 9.0, 0.05),
        "dy0/dy2 should be 9 (Multiply: 9/16 ÷ 1/16); "
        ~ "got " ~ ratio02.to!string
        ~ " (Add/Max/Min would give ≤3)");

    // Linear-X weight ratio: same Y-weight (both y=−0.5), different X.
    // dy0/dy1 = (9/16) / (3/16) = 3.
    double ratio01 = dy0 / dy1;
    assert(approx(ratio01, 3.0, 0.02),
        "dy0/dy1 should be 3 (X-weight 0.75/0.25); got " ~ ratio01.to!string);

    // ── Symmetry of the Multiply combine ─────────────────────────────────
    // v1 and v3 both have combined weight 3/16, via DIFFERENT individual
    // weights (X·Y = 0.25·0.75 vs 0.75·0.25). Equal displacement proves
    // multiplication is commutative and both axes contribute — not just
    // one of them being ignored.
    assert(approx(dy1, dy3, dy0 * 0.01),
        "dy1 ≈ dy3 (product symmetric: 0.25·0.75 = 0.75·0.25); "
        ~ "dy1=" ~ dy1.to!string ~ " dy3=" ~ dy3.to!string);

    // ── Z-axis independence ───────────────────────────────────────────────
    // v4 = (−0.5,−0.5,+0.5): same X and Y as v0, different Z.
    // Neither linear falloff depends on Z, so dy4 must equal dy0.
    assert(approx(dy4, dy0, dy0 * 0.01),
        "v4 (Z-mirror of v0) should move identically to v0; "
        ~ "dy4=" ~ dy4.to!string ~ " dy0=" ~ dy0.to!string);

    // ── Absolute product formula ──────────────────────────────────────────
    // Infer dyFull from v0 (weight 9/16 = 0.5625) and verify every vertex
    // matches the analytic product within 5 % of dyFull.
    double dyFull = dy0 / 0.5625;
    double tol    = dyFull * 0.05;
    assert(approx(dy1, dyFull * 0.1875, tol),
        "v1: expected dyFull·3/16 ≈ " ~ (dyFull * 0.1875).to!string
        ~ "; got " ~ dy1.to!string);
    assert(approx(dy2, dyFull * 0.0625, tol),
        "v2: expected dyFull·1/16 ≈ " ~ (dyFull * 0.0625).to!string
        ~ "; got " ~ dy2.to!string);
    assert(approx(dy3, dyFull * 0.1875, tol),
        "v3: expected dyFull·3/16 ≈ " ~ (dyFull * 0.1875).to!string
        ~ "; got " ~ dy3.to!string);

    cmd("falloff.clear");
}
