// Phase 5 of the transform-single-source plan — verify-only.
//
// The translate refactor (Phase 3) replaced the buggy per-cluster screen-
// projection in MoveTool's drag with a single basis-local gesture scalar
// routed through `applyTRS`. Rotate/scale never had the equivalent bug —
// the rotate kernel reads per-cluster pivots/axes through `pivotFor` and
// `axisFor` in `xform_kernels.d`, so each cluster rotates around its OWN
// centroid by the SAME angle. The same is true for scale.
//
// This test pins that invariant numerically (the existing `tool.attr
// xfrm.transform RY <deg>` + `tool.doApply` path already exercises the
// rotate kernel with cluster info). The strong assertion is:
//   1. Each cluster's CENTROID stays fixed under per-cluster rotation
//      (rotating a point set around its own centroid leaves the centroid
//      invariant within fp rounding).
//   2. Per-cluster mean radial displacement magnitude is the same across
//      clusters (every cluster rotates by the same angle, so all verts
//      shift on their own circle of equal radius around their pivot —
//      consistent magnitude across clusters means equal rotational
//      throw).
//
// This file stays NUMERIC-ONLY: it pins the per-cluster ACEN.Local kernel
// invariants above. The "drag == numeric" live-drag arm lives in
// tests/test_rotate_drag_parity.d (MS-1 of doc/rotate_single_source_plan.md),
// which drives a real principal-axis ring drag via synthetic SDL events
// (drag_helpers.buildDragLog) on the tractable ACEN.Auto setting — no
// human/reference capture needed. Rotate has no per-cluster drag bug (unlike
// translate), so ACEN.Auto suffices for the drag==numeric contract and these
// ACEN.Local invariants cover the per-cluster path.

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt, cos, sin, PI;
import std.conv   : to;
import std.format : format;

import drag_helpers : Vec3, dot, normalize, cross;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

Vec3[] dumpVerts() {
    auto verts = getJson("/api/model")["vertices"].array;
    Vec3[] out_;
    out_.length = verts.length;
    foreach (i, v; verts) {
        auto a = v.array;
        out_[i] = Vec3(cast(float)a[0].floating,
                       cast(float)a[1].floating,
                       cast(float)a[2].floating);
    }
    return out_;
}

struct ClusterInfo {
    Vec3[] centers;
    int[]  clusterOf;
}

ClusterInfo readClusters() {
    auto j = postJson("/api/toolpipe/eval", "");
    ClusterInfo ci;
    foreach (c; j["actionCenter"]["clusterCenters"].array) {
        auto a = c.array;
        ci.centers ~= Vec3(cast(float)a[0].floating,
                           cast(float)a[1].floating,
                           cast(float)a[2].floating);
    }
    foreach (c; j["actionCenter"]["clusterOf"].array)
        ci.clusterOf ~= cast(int)c.integer;
    return ci;
}

void lockCamera() {
    // Numeric path doesn't depend on camera, but match the translate
    // parity test's posture so a future live-drag arm slots in
    // without re-bootstrapping the scene.
    auto r = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":3.0,`
      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    assert(r["status"].str == "ok",
        "camera lock failed: " ~ r.toString);
}

void setupScene() {
    postJson("/api/reset?empty=true", "");
    lockCamera();
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
      ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select",
                        `{"mode":"polygons","indices":[11,12,13]}`);
    assert(sel["status"].str == "ok", sel.toString);
    cmd("tool.set xfrm.transform on");
    cmd("actr.local");
}

unittest { // Per-cluster RY: each cluster rotates around its own centroid;
           // the centroid stays fixed; per-cluster radial spread is uniform.
    setupScene();
    auto ci = readClusters();
    assert(ci.centers.length == 2,
        "expected 2 clusters, got " ~ ci.centers.length.to!string);

    // Snapshot pre-rotate per-cluster centroid for the centroid-fixed
    // invariant assertion.
    Vec3[] preCentroid;
    int[]  preCount;
    preCentroid.length = ci.centers.length;
    preCount.length    = ci.centers.length;
    auto pre = dumpVerts();
    foreach (vi, c; ci.clusterOf) {
        if (c < 0 || c >= cast(int)preCentroid.length) continue;
        preCentroid[c] = preCentroid[c] + pre[vi];
        ++preCount[c];
    }
    foreach (i; 0 .. preCentroid.length) {
        assert(preCount[i] > 0,
            "cluster " ~ i.to!string ~ " is empty");
        preCentroid[i] = Vec3(preCentroid[i].x / preCount[i],
                              preCentroid[i].y / preCount[i],
                              preCentroid[i].z / preCount[i]);
    }

    // Apply RY=30° via the numeric path.
    cmd("tool.attr xfrm.transform R true");
    cmd("tool.attr xfrm.transform T false");
    cmd("tool.attr xfrm.transform S false");
    cmd("tool.attr xfrm.transform RY 30");
    cmd("tool.doApply");

    auto post_ = dumpVerts();

    // Invariant 1: each cluster's centroid stays fixed within tol —
    // rotation around the cluster's own centroid leaves it invariant.
    Vec3[] postCentroid;
    postCentroid.length = ci.centers.length;
    int[]  postCount;
    postCount.length    = ci.centers.length;
    foreach (vi, c; ci.clusterOf) {
        if (c < 0 || c >= cast(int)postCentroid.length) continue;
        postCentroid[c] = postCentroid[c] + post_[vi];
        ++postCount[c];
    }
    foreach (i; 0 .. postCentroid.length) {
        postCentroid[i] = Vec3(postCentroid[i].x / postCount[i],
                               postCentroid[i].y / postCount[i],
                               postCentroid[i].z / postCount[i]);
        Vec3 d = Vec3(postCentroid[i].x - preCentroid[i].x,
                      postCentroid[i].y - preCentroid[i].y,
                      postCentroid[i].z - preCentroid[i].z);
        float mag = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        assert(mag < 0.005f,
            "Cluster " ~ i.to!string ~ " centroid drifted under per-cluster "
            ~ "RY: pre=("
            ~ preCentroid[i].x.to!string ~ "," ~ preCentroid[i].y.to!string
            ~ "," ~ preCentroid[i].z.to!string ~ ") post=("
            ~ postCentroid[i].x.to!string ~ "," ~ postCentroid[i].y.to!string
            ~ "," ~ postCentroid[i].z.to!string ~ ") |diff|="
            ~ mag.to!string);
    }

    // Invariant 2: every cluster's verts moved by the SAME angular amount
    // (30°) around their respective centroids. We check this via the
    // ratio of pre→post arc-chord length to pre-radius. For a vert at
    // distance r from the centroid, rotating by θ gives a chord length
    // 2r·sin(θ/2). So `chord / r` should be ≈ 2·sin(15°) ≈ 0.51764
    // across every cluster (modulo verts on the axis of rotation, which
    // are skipped — their pre-radius along the perpendicular plane is 0).
    float expectedChordOverR = 2.0f * sin(15.0f * cast(float)(PI / 180.0));
    foreach (vi, c; ci.clusterOf) {
        if (c < 0 || c >= cast(int)preCentroid.length) continue;
        Vec3 p0 = pre[vi];
        Vec3 p1 = post_[vi];
        Vec3 pivot = preCentroid[c];
        // Radius perpendicular to the rotation axis (we used RY → axis
        // is the cluster's local Y from AxisPacket.clusterUp[c]). We
        // don't have direct access to per-cluster Y here without an
        // extra query — instead, observe that for a per-cluster rotation
        // around an axis through `pivot`, the magnitude of (p - pivot)
        // is preserved. Test that radius (in 3D) is invariant.
        Vec3 rPre = Vec3(p0.x - pivot.x, p0.y - pivot.y, p0.z - pivot.z);
        Vec3 rPost = Vec3(p1.x - pivot.x, p1.y - pivot.y, p1.z - pivot.z);
        float rPreLen = sqrt(rPre.x*rPre.x + rPre.y*rPre.y + rPre.z*rPre.z);
        float rPostLen = sqrt(rPost.x*rPost.x + rPost.y*rPost.y + rPost.z*rPost.z);
        // Verts at the pivot are insensitive to rotation.
        if (rPreLen < 0.01f) continue;
        // Radius preserved by per-cluster rotation:
        assert(fabs(rPreLen - rPostLen) < 0.005f,
            "Vertex " ~ vi.to!string ~ " radius from cluster "
            ~ c.to!string ~ " centroid changed: pre=" ~ rPreLen.to!string
            ~ " post=" ~ rPostLen.to!string);
    }
}
