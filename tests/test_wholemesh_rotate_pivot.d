// Regression: a whole-mesh (empty-selection) rotate must pivot at the mesh
// centroid and stay rigid — it must NOT launch the model to coordinates far
// outside its own bounding box.
//
// Background. A reported bug had a loaded, off-center mesh "fly away" when
// rotated with an empty selection. Two pivot-source hypotheses were ruled out
// during investigation:
//   * a stale ActionCenterStage userPlaced/softPlaced pin leaking the gizmo
//     pivot to a far point (it is cleared before the rotate applies), and
//   * the centroid fallback scanning a stale subpatch-preview vertex buffer
//     (it reads the cage `mesh.vertices` via selectionBBoxCenter*, which is
//     bounded by the loaded geometry).
// The true root cause was the interactive rotate ring integrating its angle
// from per-frame deltas, which a near-edge-on ray-plane singularity could
// poison by ~PI in a single frame (fixed in source/tools/rotate.d by an
// absolute-angle measurement with a horizon-graze reject).
//
// This test is a deterministic GUARD on the surviving, scriptable invariant:
// for an off-center mesh with EMPTY selection, the rotate apply path must
// pivot at the mesh centroid. It exercises the headless RY apply (which goes
// through the same queryActionCenter pivot the gizmo uses) and asserts the
// result is a clean rotation about the centroid — every vertex stays on its
// orbit radius about the centroid (so the mesh cannot fly), pairwise
// distances are preserved, and the recovered fixed point is the centroid
// (NOT a stale far pin). A regression to either ruled-out pivot source, or a
// non-rigid/launched transform, fails here.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, sin, cos, atan2, PI;
import std.conv : to;

void main() {}

struct V3 { double x = 0, y = 0, z = 0; }

void cmd(string line) {
    auto r = post("http://localhost:8080/api/script", line);
    assert(parseJSON(cast(string)r)["status"].str == "ok",
        "cmd failed: " ~ line ~ " -> " ~ cast(string)r);
}

V3[] dumpVerts() {
    auto j = parseJSON(cast(string)get("http://localhost:8080/api/model"));
    V3[] o;
    foreach (vv; j["vertices"].array) {
        auto a = vv.array;
        o ~= V3(a[0].floating, a[1].floating, a[2].floating);
    }
    return o;
}

double dist(V3 a, V3 b) {
    double dx = a.x-b.x, dy = a.y-b.y, dz = a.z-b.z;
    return sqrt(dx*dx + dy*dy + dz*dz);
}

unittest { // whole-mesh rotate pivots at the centroid; mesh cannot fly
    post("http://localhost:8080/api/reset", "");

    // Tall, off-center box: x in [4,5], y in [0,6], z in [4,5].
    // Centroid = (4.5, 3, 4.5); longest half-extent from the centroid is
    // sqrt(0.5^2 + 3^2 + 0.5^2) ~= 3.082. A clean rotation about the centroid
    // keeps every vert at its own constant orbit radius (<= 3.082) — it can
    // never reach the tens/hundreds-of-units coordinates the bug produced.
    string mesh = `{"vertices":[`
        ~ `[4,0,4],[5,0,4],[5,0,5],[4,0,5],`
        ~ `[4,6,4],[5,6,4],[5,6,5],[4,6,5]],`
        ~ `"faces":[[0,1,2,3],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7]]}`;
    auto lr = post("http://localhost:8080/api/load-mesh", mesh);
    assert(parseJSON(cast(string)lr)["status"].str == "ok",
        "load-mesh failed: " ~ cast(string)lr);

    V3 centroid = V3(4.5, 3.0, 4.5);

    // EMPTY selection => the whole mesh is the moving set.
    auto sel = parseJSON(cast(string)get("http://localhost:8080/api/selection"));
    assert(sel["selectedVertices"].array.length == 0
        && sel["selectedEdges"].array.length == 0
        && sel["selectedFaces"].array.length == 0,
        "expected empty selection (whole-mesh rotate)");

    auto pre = dumpVerts();

    // Per-vertex orbit radius about the centroid, captured before the rotate.
    double[] orbit = new double[](pre.length);
    foreach (i, v; pre) orbit[i] = dist(v, centroid);

    // Activate rotate and apply a large RY through the headless apply path.
    // This shares queryActionCenter (the gizmo pivot) — a stale far pin or a
    // bad centroid would move the pivot off (4.5,3,4.5) and the orbit-radius
    // assertion below would fail.
    cmd("tool.set TransformRotate on");
    cmd("tool.beginSession");
    cmd("tool.attr TransformRotate RY 85.9");

    auto post_ = dumpVerts();
    assert(post_.length == pre.length, "vertex count changed during rotate");

    // (1) NO FLY + correct pivot: every vert stays on its own orbit radius
    // about the centroid. (If the pivot were the far (170,1.52,28) point the
    // bug reported, these radii would change wildly.)
    foreach (i; 0 .. post_.length) {
        double rPost = dist(post_[i], centroid);
        assert(fabs(rPost - orbit[i]) < 1e-2,
            "vert " ~ i.to!string ~ " left its centroid orbit: "
            ~ orbit[i].to!string ~ " -> " ~ rPost.to!string
            ~ " (pivot is not the mesh centroid)");
    }

    // (2) Bounded: no coordinate escapes the centroid's max half-extent.
    double maxR = 0;
    foreach (v; post_) {
        double r = dist(v, centroid);
        if (r > maxR) maxR = r;
    }
    assert(maxR < 3.2,
        "mesh flew away: max |vert - centroid| = " ~ maxR.to!string
        ~ " (rigid bound ~3.08)");

    // (3) Rigid: pairwise distances between corners preserved.
    static int[2][] pairs = [[0,6],[1,7],[2,4],[3,5],[0,2],[4,6]];
    foreach (pr; pairs) {
        double dPre  = dist(pre[pr[0]],   pre[pr[1]]);
        double dPost = dist(post_[pr[0]], post_[pr[1]]);
        assert(fabs(dPre - dPost) < 1e-2,
            "non-rigid rotation: |v" ~ pr[0].to!string ~ "v" ~ pr[1].to!string
            ~ "| " ~ dPre.to!string ~ " -> " ~ dPost.to!string);
    }

    // (4) The rotation actually happened (about +Y): the recovered angle is
    // non-trivial and consistent across the XZ projection of every vert.
    double accC = 0, accS = 0;
    foreach (i; 0 .. post_.length) {
        double ax = pre[i].x - centroid.x,   az = pre[i].z - centroid.z;
        double bx = post_[i].x - centroid.x, bz = post_[i].z - centroid.z;
        if (ax*ax + az*az < 1e-6) continue;
        accC += (ax*bx + az*bz);
        accS += (az*bx - ax*bz);
    }
    double theta = atan2(accS, accC) * 180.0 / PI;
    assert(fabs(fabs(theta) - 85.9) < 1.0,
        "recovered Y angle " ~ theta.to!string ~ " deg != applied 85.9 — "
        ~ "rotate did not pivot cleanly about the centroid");
}
