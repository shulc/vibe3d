// Behavioral test for the xfrm.softTransform preset.
//
// Verifies that the unified transform (T+R+S all banks) composes correctly
// with a radial falloff: per-vertex displacements attenuate monotonically
// with distance from the falloff center under each individual bank.
//
// Falloff geometry used throughout:
//   center = (-0.5,-0.5,-0.5) = v0, the cube corner sitting AT the center
//   size   = (2,2,2)           = radii 2 per axis, so the whole cube fits
//   Distances from center:
//     v0 = 0        → t = 0       → w = 1.0   (full weight)
//     {v1,v3,v4} = 1     → t = 0.5  → high weight
//     {v2,v5,v7} = √2    → t ≈ 0.71 → medium weight
//     v6 = √3 ≈ 1.732   → t ≈ 0.87 → w ≈ 0.13 (low weight)
//
// Three-bank coverage:
//   T bank — Y-arrow move drag via play-events. Asserts monotone attenuation
//            and byte-return undo on this single-bank drag.
//   R bank — tool.attr RZ + tool.doApply. Asserts radial attenuation
//            (v0 displaces more than v6). No undo-entry-count assertion
//            (multibank apply changes the count; undo left to /api/reset).
//   S bank — tool.attr SX + tool.doApply. Same assertion as R bank.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

// Reset, select all 8 cube vertices, activate xfrm.softTransform,
// and override the falloff so every corner has a distinct weight.
// Uses /api/script for the multi-command block (matches the existing
// radial-drag test recipe; the quoted vec3 value for `center` needs
// the script parser).
void setupSoftTransform() {
    postJson("/api/reset", "");
    auto selResp = postJson("/api/select",
                            `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    assert(selResp["status"].str == "ok",
        "select-all failed: " ~ selResp.toString);
    string script =
        "tool.set xfrm.softTransform on\n" ~
        `tool.pipe.attr falloff center "-0.5,-0.5,-0.5"` ~ "\n" ~
        `tool.pipe.attr falloff size "2,2,2"` ~ "\n";
    auto r = postJson("/api/script", script);
    assert(r["status"].str == "ok",
        "setupSoftTransform script failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// T bank: Y-arrow move drag → monotone radial attenuation + byte-return undo.
//
// A single-bank move drag (only the T fold fires) produces exactly one undo
// entry, so the byte-return assertion is clean. The R and S bank tests use
// tool.doApply (which records per-bank entries when all banks are enabled),
// so the strict undo-count assertion lives HERE only.
// ---------------------------------------------------------------------------
unittest {
    setupSoftTransform();

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Drag along the Y gizmo arrow (same geometry as test_falloff_radial_drag.d).
    Vec3 pivot = Vec3(0, 0, 0);   // ACEN.Auto = centroid of all-8-selected = origin
    float size = gizmoSize(pivot, vp);
    Vec3 arrowStart = Vec3(pivot.x, pivot.y + size / 6.0f, pivot.z);
    Vec3 arrowEnd   = Vec3(pivot.x, pivot.y + size,         pivot.z);
    float sx1, sy1, sx2, sy2;
    assert(projectToWindow(arrowStart, vp, sx1, sy1), "Y-arrow start off-camera");
    assert(projectToWindow(arrowEnd,   vp, sx2, sy2), "Y-arrow end off-camera");
    int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double sdx = cast(double)(sx2 - sx1), sdy = cast(double)(sy2 - sy1);
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    int x1 = x0 + cast(int)(100.0 * sdx / sLen);
    int y1 = y0 + cast(int)(100.0 * sdy / sLen);

    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              x0, y0, x1, y1, 20);
    playAndWait(log);
    Thread.sleep(dur!"msecs"(120)); // settle after playback

    double dy(int i) { return vertexPos(i)[1] - pre[i][1]; }

    double dy0 = dy(0); // v0 at falloff center → full weight → maximal move
    double dy6 = dy(6); // v6 opposite corner → low weight → small move

    assert(dy0 > 0.1,
        "v0 (at falloff center) barely moved: dy0=" ~ dy0.to!string);
    assert(dy6 < dy0 * 0.5 && dy6 >= 0,
        "v6 (far from falloff center) should move <50 % of v0: "
        ~ "dy0=" ~ dy0.to!string ~ " dy6=" ~ dy6.to!string);

    // Monotone: corners ordered by distance from (-0.5,-0.5,-0.5) must move
    // in the same order. Distances: v0=0, {v1,v3,v4}=1, {v2,v5,v7}=√2, v6=√3.
    foreach (i; [1, 3, 4]) {
        assert(dy(i) <= dy0 + 1e-3,
            "v" ~ i.to!string ~ " (dist 1) moved more than v0 (dist 0): "
            ~ dy(i).to!string ~ " > " ~ dy0.to!string);
        assert(dy(i) >= dy6 - 1e-3,
            "v" ~ i.to!string ~ " (dist 1) moved less than v6 (dist √3): "
            ~ dy(i).to!string ~ " < " ~ dy6.to!string);
    }
    foreach (i; [2, 5, 7]) {
        assert(dy(i) >= dy6 - 1e-3,
            "v" ~ i.to!string ~ " (dist √2) moved less than v6 (dist √3): "
            ~ dy(i).to!string ~ " < " ~ dy6.to!string);
    }

    // Byte-return: a single Y-axis move drag on the T bank records one undo
    // entry. Undo must restore every vertex to its pre-drag position.
    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    Thread.sleep(dur!"msecs"(120)); // settle after undo

    foreach (i; 0 .. 8) {
        auto pos = vertexPos(i);
        foreach (k; 0 .. 3)
            assert(approx(pos[k], pre[i][k]),
                "undo byte-return: v" ~ i.to!string
                ~ " component " ~ k.to!string
                ~ " got " ~ pos[k].to!string
                ~ " want " ~ pre[i][k].to!string);
    }
}

// ---------------------------------------------------------------------------
// R bank: tool.attr RZ + tool.doApply → radial attenuation.
//
// v0 at the falloff center (w=1) receives the full 45° matrix-lerp rotation;
// v6 at the far corner (w≈0.13) barely rotates. The unified xfrm.transform
// path uses matrix-lerp (not angle-scaling) for the rotate fold, consistent
// with xfrm.flex — no rotFalloffBlend is set on this preset.
// ---------------------------------------------------------------------------
unittest {
    setupSoftTransform();

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    cmd("tool.attr xfrm.softTransform RZ 45");
    cmd("tool.doApply");
    Thread.sleep(dur!"msecs"(80));

    double disp(int i) {
        auto pos = vertexPos(i);
        double dx = pos[0] - pre[i][0];
        double dy = pos[1] - pre[i][1];
        double dz = pos[2] - pre[i][2];
        return sqrt(dx*dx + dy*dy + dz*dz);
    }

    double d0 = disp(0); // w=1  → full 45° rotate, large displacement
    double d6 = disp(6); // w≈0.13 → small effective rotation, small displacement

    assert(d0 > 0.05,
        "R bank: v0 (at falloff center) barely rotated: disp=" ~ d0.to!string);
    assert(d0 > d6,
        "R bank: v0 should displace more than v6 under radial falloff: "
        ~ "d0=" ~ d0.to!string ~ " d6=" ~ d6.to!string);
}

// ---------------------------------------------------------------------------
// S bank: tool.attr SX + tool.doApply → radial attenuation.
//
// v0 at the falloff center (w=1) is scaled fully along X (SX=2, pivot=origin);
// v6 at the far corner (w≈0.13) barely shifts. Same matrix-lerp blend as the
// R bank — ACEN.Auto = centroid of all-8-selected = origin.
// ---------------------------------------------------------------------------
unittest {
    setupSoftTransform();

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    cmd("tool.attr xfrm.softTransform SX 2.0");
    cmd("tool.doApply");
    Thread.sleep(dur!"msecs"(80));

    double disp(int i) {
        auto pos = vertexPos(i);
        double dx = pos[0] - pre[i][0];
        double dy = pos[1] - pre[i][1];
        double dz = pos[2] - pre[i][2];
        return sqrt(dx*dx + dy*dy + dz*dz);
    }

    double d0 = disp(0); // w=1  → full SX=2 scale, large X displacement
    double d6 = disp(6); // w≈0.13 → small effective scale, small displacement

    assert(d0 > 0.0,
        "S bank: v0 (at falloff center) did not scale: disp=" ~ d0.to!string);
    assert(d0 > d6,
        "S bank: v0 should displace more than v6 under radial falloff: "
        ~ "d0=" ~ d0.to!string ~ " d6=" ~ d6.to!string);
}
