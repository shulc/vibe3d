// Phase 1 of the transform-single-source plan.
//
// What this pins (live, end-to-end, through the SDL/tool dispatch):
//
//   Under ACEN.Local + axis.local (≥2 disjoint clusters with their OWN
//   signed local frames), a single-handle interactive translate drag
//   must move every cluster by the SAME signed scalar along its OWN
//   signed `fwd` axis. Equivalently: the basis-local TZ scalar fed into
//   `headlessTranslate` is one number across all clusters; each
//   cluster's vert displacement = `clusterFwd[cid] * scalar`. Clusters
//   with OPPOSITE-signed normals (e.g. top +Y vs bottom -Y) move in
//   OPPOSITE WORLD DIRECTIONS by the SAME magnitude — that is the
//   "uniform amount in its own local frame" invariant.
//
//   The pre-refactor MoveTool drag projects the screen mouse motion
//   onto each cluster's OWN screen-projected axis INDEPENDENTLY (see
//   `MoveTool.applyPerClusterDelta` in `source/tools/move.d`), so per-
//   cluster magnitudes scale with each axis's screen-projection length
//   and diverge. The captured live drag (committed alongside this
//   test) records 0.2291 for cluster A vs 0.3621 for cluster B along
//   their signed `fwd` — the bug, frozen.
//
//   Post-refactor the wrapper computes ONE basis-local scalar per
//   frame and pushes it into `headlessTranslate`; `applyTRS` re-uses
//   the per-cluster kernel `applyTranslatePerCluster` which already
//   reads each cluster's own frame. Per-cluster |scalar| converges.
//
// Per-cluster frame construction matches `source/toolpipe/stages/axis.d`
// (~lines 443-473) exactly:
//   fwd   = signed snapped average face normal of the cluster
//   right = normalize(world+X − fwd·dot(world+X, fwd))   (world+Z when
//           the normal is X-aligned, to avoid a degenerate tangent)
//   up    = fwd × right
//
// The captured drag (manual, ACEN.Local, 3-poly asymmetric selection
// on a clean segments-2 cube, blue Z-handle pull) has the
// `axis.clusterFwd` values:
//   cluster A (top -X cells, normal +Y) → fwd = +Y
//   cluster B (bottom +X+Z cell, normal -Y) → fwd = -Y
// and the captured world-Y motion is negative → cluster A's projection
// onto +Y is NEGATIVE; cluster B's projection onto -Y is POSITIVE; both
// representing the SAME basis-local scalar (negative TZ).
//
// Primary assertion (RED before Phase 3, GREEN after):
//   The SIGNED basis-local scalar along each cluster's OWN signed `fwd`
//   must AGREE across clusters within tol = 0.005. Pre-refactor
//   cluster A reads -0.229 and cluster B reads +0.362 — divergent
//   magnitudes AND opposite signs. Post-refactor every cluster reads
//   the SAME signed scalar.
//
// Secondary assertion (RED before Phase 3, GREEN after):
//   Recover the cluster-local scalar `s` from the post-drag mesh.
//   Reset to a fresh scene + same selection + ACEN.Local, fire
//   `tool.attr move TZ <s>` + `tool.doApply`, and assert drag-result
//   ≈ numeric-result per vertex within 0.005. This pins the
//   "drag == numeric" invariant the refactor introduces.

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt;
import std.conv   : to;
import std.string : strip;
import std.file   : readText;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers : Vec3, dot, normalize;

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

void playAndWait(string log) {
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success",
        "play-events failed: " ~ r.toString);
    // Captured drag's t-stamps span ~32 s of real time (manual idle
    // before the click), so the player needs that much wall-clock to
    // drain. 900 × 100ms = 90s headroom.
    foreach (i; 0 .. 900) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.TRUE) return;
        Thread.sleep(dur!"msecs"(100));
    }
    assert(false, "play-events did not finish within 90s");
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
    Vec3[] centers;        // ACEN.clusterCenters (per cluster)
    Vec3[] fwd;            // AXIS.clusterFwd (per cluster, signed)
    Vec3   sharedRight;    // AXIS.right (shared basis from non-cluster path)
    Vec3   sharedUp;
    Vec3   sharedFwd;
    int[]  clusterOf;      // per-vertex cluster id (-1 = unassigned)
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
    foreach (f; j["axis"]["clusterFwd"].array) {
        auto a = f.array;
        ci.fwd ~= Vec3(cast(float)a[0].floating,
                       cast(float)a[1].floating,
                       cast(float)a[2].floating);
    }
    auto r = j["axis"]["right"].array;
    auto u = j["axis"]["up"].array;
    auto f = j["axis"]["fwd"].array;
    ci.sharedRight = Vec3(cast(float)r[0].floating,
                          cast(float)r[1].floating,
                          cast(float)r[2].floating);
    ci.sharedUp    = Vec3(cast(float)u[0].floating,
                          cast(float)u[1].floating,
                          cast(float)u[2].floating);
    ci.sharedFwd   = Vec3(cast(float)f[0].floating,
                          cast(float)f[1].floating,
                          cast(float)f[2].floating);
    return ci;
}

// Lock the camera explicitly so the captured drag's screen pixels
// project onto the same gizmo + workplane regardless of any future
// default-orbit/elevation/distance drift. The captured event log was
// taken with the standard vibe3d test-mode defaults (azimuth=0.5,
// elevation=0.4, distance=3.0, focus at origin). The VIEWPORT line in
// the log handles size remapping separately.
void lockCamera() {
    auto r = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":3.0,`
      ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`);
    assert(r["status"].str == "ok",
        "camera lock failed: " ~ r.toString);
}

void setupScene() {
    // Empty reset → cube segments-2 → asymmetric 3-poly selection →
    // tool.set move on → actr.local. Order matters: actr.local needs
    // ACEN + AXIS stages registered by the active tool's preset, so
    // the tool must come on before the preset switch.
    postJson("/api/reset?empty=true", "");
    lockCamera();
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
      ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select",
                        `{"mode":"polygons","indices":[11,12,13]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    cmd("tool.set move on");
    cmd("actr.local");
}

// Per-cluster mean displacement projected onto each cluster's signed
// `fwd`. Returns one signed scalar per cluster.
float[] perClusterFwdScalars(Vec3[] pre, Vec3[] post_, ClusterInfo ci) {
    Vec3[] meanDisp;
    int[]  count;
    meanDisp.length = ci.centers.length;
    count.length    = ci.centers.length;
    foreach (vi, c; ci.clusterOf) {
        if (c < 0 || c >= cast(int)meanDisp.length) continue;
        Vec3 d = Vec3(post_[vi].x - pre[vi].x,
                      post_[vi].y - pre[vi].y,
                      post_[vi].z - pre[vi].z);
        meanDisp[c] = meanDisp[c] + d;
        ++count[c];
    }
    float[] scalars;
    scalars.length = ci.centers.length;
    foreach (i; 0 .. meanDisp.length) {
        assert(count[i] > 0,
            "cluster " ~ i.to!string ~ " has no assigned vertices");
        Vec3 m = Vec3(meanDisp[i].x / count[i],
                      meanDisp[i].y / count[i],
                      meanDisp[i].z / count[i]);
        scalars[i] = dot(m, ci.fwd[i]);
    }
    return scalars;
}

unittest { // Per-cluster signed-fwd scalar EQUALITY (the bug Phase 3 fixes)
    setupScene();

    auto ci = readClusters();
    assert(ci.centers.length == 2,
        "expected 2 clusters, got " ~ ci.centers.length.to!string);
    assert(ci.fwd.length == ci.centers.length,
        "clusterFwd length mismatch: "
      ~ ci.fwd.length.to!string ~ " vs "
      ~ ci.centers.length.to!string);

    auto pre = dumpVerts();

    // Replay the captured live SDL drag (manual blue-Z-handle pull).
    string log = readText("tests/events/acen_local_translate_drag.log");
    playAndWait(log);

    auto post_ = dumpVerts();
    assert(post_.length == pre.length,
        "mesh vertex count changed during drag");

    auto scalars = perClusterFwdScalars(pre, post_, ci);

    // Sanity: the drag must have actually moved geometry — otherwise
    // the captured event log is missing the handle and we'd be
    // testing nothing.
    float maxAbs = 0;
    foreach (s; scalars) {
        float a = fabs(s);
        if (a > maxAbs) maxAbs = a;
    }
    assert(maxAbs > 0.05,
        "Drag produced no measurable per-cluster motion (|max scalar|="
        ~ maxAbs.to!string ~ "). The captured events.log mouse pixels "
        ~ "may not be hitting a move handle at the test's camera / "
        ~ "viewport setup.");

    // Primary assertion (refactor target):
    //   For every cluster, the SIGNED basis-local scalar along its
    //   OWN signed `fwd` must agree. Pre-refactor cluster A reads
    //   -0.229 and cluster B reads +0.362 — divergent magnitudes AND
    //   opposite signs. Post-refactor every cluster reads the SAME
    //   signed scalar (e.g. ~-0.30 for the captured negative-Y pull);
    //   `fwd[A] = +Y, fwd[B] = -Y` while the world displacement
    //   tracks the single basis-local scalar.
    //
    // Pinning the SIGNED scalar (not just |scalar|) rules out the
    // case where cluster A has |s|=0.229 and cluster B |s|=0.229
    // with opposite signs — that would still be inconsistent (each
    // cluster reading its OWN sign), distinct from the post-refactor
    // semantics where the BASIS-LOCAL scalar is one number.
    float s0 = scalars[0];
    foreach (i, s; scalars) {
        float diff = fabs(s - s0);
        assert(diff < 0.005f,
            "Per-cluster signed-fwd scalar divergence (Phase 3 bug):\n"
            ~ "  cluster 0 scalar along its fwd: " ~ s0.to!string ~ "\n"
            ~ "  cluster " ~ i.to!string
            ~ " scalar along its fwd: " ~ s.to!string ~ "\n"
            ~ "  |diff|: " ~ diff.to!string);
    }
}

unittest { // Drag-result ≈ numeric-result per vertex (drag == numeric)
    // Reproduces the drag to recover its basis-local scalar; then
    // re-runs the scenario but applies that scalar through the numeric
    // `tool.attr move TZ <s>` + `tool.doApply` path. Per-vertex
    // equality within 0.005 demonstrates the wrapper's `applyTRS`
    // is the SINGLE source of truth.
    setupScene();
    auto ci = readClusters();
    auto preD = dumpVerts();
    string log = readText("tests/events/acen_local_translate_drag.log");
    playAndWait(log);
    auto postD = dumpVerts();

    // Recover the cluster-local scalar from cluster 0's signed-fwd
    // projection (post-refactor every cluster yields the same scalar
    // — the prior assertion already pinned this; we read cluster 0
    // because it has more verts → more averaging).
    auto scalars = perClusterFwdScalars(preD, postD, ci);
    float s = scalars[0];

    // The drag pulled the BLUE (Z) handle. Under axis.local the
    // basis-local Z component of `headlessTranslate` flows to
    // `applyTranslatePerCluster` as `localDelta.z`, multiplied per
    // vert by `fwd[cid]`. So `TZ s` numerically reproduces the drag.
    setupScene();
    auto preN = dumpVerts();
    cmd(format("tool.attr move TX 0.0"));
    cmd(format("tool.attr move TY 0.0"));
    cmd(format("tool.attr move TZ %.6f", s));
    cmd("tool.doApply");
    auto postN = dumpVerts();

    // Per-vertex compare drag vs numeric.
    assert(postD.length == postN.length,
        "drag/numeric vertex count mismatch: "
      ~ postD.length.to!string ~ " vs " ~ postN.length.to!string);
    float maxDiff = 0;
    int   worstVi = -1;
    foreach (vi; 0 .. preD.length) {
        Vec3 dD = Vec3(postD[vi].x - preD[vi].x,
                       postD[vi].y - preD[vi].y,
                       postD[vi].z - preD[vi].z);
        Vec3 dN = Vec3(postN[vi].x - preN[vi].x,
                       postN[vi].y - preN[vi].y,
                       postN[vi].z - preN[vi].z);
        Vec3 diff = Vec3(dD.x - dN.x, dD.y - dN.y, dD.z - dN.z);
        float m = sqrt(diff.x*diff.x + diff.y*diff.y + diff.z*diff.z);
        if (m > maxDiff) { maxDiff = m; worstVi = cast(int)vi; }
    }
    assert(maxDiff < 0.005f,
        "Drag vs numeric divergence (the bug Phase 3 fixes): max per-vert "
        ~ "drift = " ~ maxDiff.to!string ~ " at vertex "
        ~ worstVi.to!string);
}
