// Topology Pen P7 — slide_drag (Tier-C, best-effort HTTP,
// doc/topopen_p7_slide_plan.md "Testing Strategy").
//
// Ctrl+LMB-drags an edge of a 2-quad "domino" fixture (SAME topology as the
// P5 removeFaceAt domino rig: F0=[0,1,2,3], F1=[1,4,5,2] sharing edge 1-2)
// through the real event-log/dispatch path. Vertex valence is engineered so
// the SAME fixture exercises both cases the plan pins:
//   - grab edge 3-0: BOTH endpoints valence-2 -> a genuine two-sided
//     colinear slide (vertex 3 along its own 3-2 edge, vertex 0 along its
//     own 0-1 edge, independently).
//   - grab edge 0-1: vertex 0 (valence-2) slides toward vertex 3; vertex 1
//     is the shared valence-3 hub and must be HELD FIXED (mixed valence).
//     A large overshoot on this same drag also proves clamp-at-neighbor.
//
// The exact drag->t FORMULA is unmeasured (plan §5, vibe3d-divergence) — this
// test asserts only the STRUCTURAL invariants the plan pins: colinearity to
// the endpoint's OWN incident edge, [0,1]-boundedness, zero topology delta,
// clamp-at-neighbor on overshoot, held-fixed on the valence>2 endpoint, and
// exact undo restoration. Uses an LCTRL-hold-around-LMB-drag chord (same
// fragility P5/P6 flagged for their own MMB chords).
//
// Run via: ./run_test.d topopen_slide_drag

import topopen_place_helpers;
import std.json;
import std.math   : sqrt;
import std.format : format;

void main() {}

enum uint LCTRL = 0x0040;   // KMOD_LCTRL — the Slide gesture's own modifier

double perpDistToLine(Vec3 p, Vec3 a, Vec3 b) {
    Vec3 ab = b - a;
    double abLen2 = dot(ab, ab);
    if (abLen2 < 1e-12) {
        Vec3 d = p - a;
        return sqrt(cast(double)dot(d, d));
    }
    double t = dot(p - a, ab) / abLen2;
    Vec3 proj = a + ab * cast(float)t;
    Vec3 d = p - proj;
    return sqrt(cast(double)dot(d, d));
}

double fractionOnSegment(Vec3 p, Vec3 a, Vec3 b) {
    Vec3 ab = b - a;
    double abLen2 = dot(ab, ab);
    if (abLen2 < 1e-12) return 0.0;
    return dot(p - a, ab) / abLen2;
}

Vec3 toVec3(double[3] v) { return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]); }

string dominoMeshBody() {
    return `{
        "vertices":[[0,0,0],[1,0,0],[1,0,1],[0,0,1],[2,0,0],[2,0,1]],
        "faces":[[0,1,2,3],[1,4,5,2]]
    }`;
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

    assert(vertexCountLayer(0) == 6 && edgeCountLayer(0) == 7 && faceCountLayer(0) == 2,
        "setup: pre-state must be the untouched domino (6v/7e/2f)");

    Vec3[] pre;
    foreach (v; readVerticesLayer(0)) pre ~= toVec3(v);

    cmd("tool.set mesh.topoPen on");

    // --- Two-sided colinear slide: grab edge 3-0 (both endpoints valence-2:
    // vertex 3's other edge is 2-3, vertex 0's other edge is 0-1). ---
    {
        float p3x, p3y, p0x, p0y;
        assert(projectToWindow(pre[3], vp, p3x, p3y), "vertex 3 must project on-screen");
        assert(projectToWindow(pre[0], vp, p0x, p0y), "vertex 0 must project on-screen");
        int mx = cast(int)((p3x + p0x) / 2), my = cast(int)((p3y + p0y) / 2);   // edge midpoint

        float p2x, p2y;
        assert(projectToWindow(pre[2], vp, p2x, p2y), "vertex 2 must project on-screen");
        // A genuine PARTIAL drag toward vertex 2's screen position (vertex
        // 3's own rail direction) — not a full overshoot.
        int rx = mx + cast(int)((p2x - mx) * 0.35f);
        int ry = my + cast(int)((p2y - my) * 0.35f);

        auto pr = postJson("/api/play-events",
            buildDragLog(c.vpX, c.vpY, c.width, c.height, mx, my, rx, ry, 16, LCTRL, 1));
        assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
        waitPlayerIdle();

        assert(vertexCountLayer(0) == 6 && edgeCountLayer(0) == 7 && faceCountLayer(0) == 2,
            "Slide must never change topology (zero delta)");

        auto post = readVerticesLayer(0);
        Vec3 v3 = toVec3(post[3]);
        Vec3 v0 = toVec3(post[0]);

        enum double eps = 2e-2;
        assert(perpDistToLine(v3, pre[3], pre[2]) < eps,
            "vertex 3 must slide COLINEARLY along its own incident edge (3-2)");
        assert(perpDistToLine(v0, pre[0], pre[1]) < eps,
            "vertex 0 must slide COLINEARLY along its own incident edge (0-1)");

        double t3 = fractionOnSegment(v3, pre[3], pre[2]);
        double t0 = fractionOnSegment(v0, pre[0], pre[1]);
        assert(t3 > -eps && t3 < 1.0 + eps,
            format("vertex 3's slide fraction must be in [0,1]; got %f", t3));
        assert(t0 > -eps && t0 < 1.0 + eps,
            format("vertex 0's slide fraction must be in [0,1]; got %f", t0));
        assert(t3 > 0.01 && t0 > 0.01,
            "sanity: the drag must have genuinely moved both endpoints");

        auto u = postJson("/api/undo", "");
        assert(u["status"].str == "ok", "undo must succeed after a real Slide: " ~ u.toString);
        auto restored = readVerticesLayer(0);
        foreach (i, v; restored)
            assert(approxVec(pre[i], v, 1e-5),
                format("undo must restore vertex %d exactly", i));
    }

    // --- Mixed valence + overshoot: grab edge 0-1 (vertex 0 valence-2,
    // slidable toward vertex 3; vertex 1 is the valence-3 hub). A large
    // overshoot toward vertex 3 also proves clamp-at-neighbor.
    //
    // The valence-3 hub is the POLYGON-CONTINUATION case: the grabbed edge
    // 0-1 borders exactly ONE polygon (the quad 0-1-2-3), whose walk
    // continues across vertex 1 onto edge 1-2, so vertex 1 must travel along
    // 1-2 — NOT stay put (the old under-approximation), and NOT take the
    // competing 1-4 rail. The choice reads topology only; the drag heads
    // toward vertex 3, i.e. away from vertex 2, and the rail is unaffected.
    {
        float p0x, p0y, p1x, p1y;
        assert(projectToWindow(pre[0], vp, p0x, p0y));
        assert(projectToWindow(pre[1], vp, p1x, p1y));
        int mx = cast(int)((p0x + p1x) / 2), my = cast(int)((p0y + p1y) / 2);

        float p3x, p3y;
        assert(projectToWindow(pre[3], vp, p3x, p3y));
        int rx = mx + cast(int)((p3x - mx) * 3.0f);   // overshoot past vertex 3
        int ry = my + cast(int)((p3y - my) * 3.0f);

        auto pr = postJson("/api/play-events",
            buildDragLog(c.vpX, c.vpY, c.width, c.height, mx, my, rx, ry, 16, LCTRL, 1));
        assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
        waitPlayerIdle();

        assert(vertexCountLayer(0) == 6 && edgeCountLayer(0) == 7 && faceCountLayer(0) == 2,
            "Slide must never change topology (zero delta)");

        auto post = readVerticesLayer(0);
        assert(approxVec(pre[3], post[0], 1e-2),
            "overshoot must clamp EXACTLY to the neighbor's (vertex 3's) pre-slide position");
        Vec3 v1 = toVec3(post[1]);
        enum double eps2 = 2e-2;
        assert(perpDistToLine(v1, pre[1], pre[2]) < eps2,
            "the valence-3 hub (vertex 1) must travel along its POLYGON-CONTINUATION "
          ~ "rail 1-2, not stay put");
        assert(perpDistToLine(v1, pre[1], pre[4]) > 10 * eps2,
            "...and NOT along the competing 1-4 rail");
        double t1 = fractionOnSegment(v1, pre[1], pre[2]);
        assert(t1 > 0.01 && t1 < 1.0 + eps2,
            format("vertex 1 must have genuinely moved along 1-2, within [0,1]; got %f", t1));

        auto u = postJson("/api/undo", "");
        assert(u["status"].str == "ok", "undo must succeed after a real Slide: " ~ u.toString);
        auto restored = readVerticesLayer(0);
        foreach (i, v; restored)
            assert(approxVec(pre[i], v, 1e-5),
                format("undo must restore vertex %d exactly", i));
    }

    // --- OPEN CASE, still held fixed: grab the INTERIOR edge 1-2, shared by
    // BOTH quads. Each endpoint then has two competing continuation rails
    // (one per incident face) and nothing measured picks between them, so
    // both endpoints stay fixed — with neither endpoint slidable, the press
    // arms nothing at all and the whole gesture is a clean no-op (no vertex
    // write, no undo entry). This pins the deferral: a later "just take the
    // first face" tie-break would break here. ---
    {
        float p1x, p1y, p2x, p2y;
        assert(projectToWindow(pre[1], vp, p1x, p1y));
        assert(projectToWindow(pre[2], vp, p2x, p2y));
        int mx = cast(int)((p1x + p2x) / 2), my = cast(int)((p1y + p2y) / 2);

        float p0x, p0y;
        assert(projectToWindow(pre[0], vp, p0x, p0y));
        int rx = mx + cast(int)((p0x - mx) * 0.6f);
        int ry = my + cast(int)((p0y - my) * 0.6f);

        auto pr = postJson("/api/play-events",
            buildDragLog(c.vpX, c.vpY, c.width, c.height, mx, my, rx, ry, 16, LCTRL, 1));
        assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
        waitPlayerIdle();

        assert(vertexCountLayer(0) == 6 && edgeCountLayer(0) == 7 && faceCountLayer(0) == 2,
            "an ambiguous-rail Slide must never change topology either");
        auto post = readVerticesLayer(0);
        foreach (i, v; post)
            assert(approxVec(pre[i], v, 1e-5),
                format("ambiguous interior-edge Slide must be a byte-clean no-op; "
                     ~ "vertex %d moved", i));
    }
}
