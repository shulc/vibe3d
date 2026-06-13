// ACEN.Local + symmetry — Stage 2b of doc/symmetry_deform_plan.md.
//
// Stage 2 made the GLOBAL fold mirror a drag as a two-pass S·M·S apply. Stage
// 2b extends that to the PER-CLUSTER (ACEN.Local) path: a mirror vertex now
// applies its DRIVER's reflected cluster operation
//   M' = Slin·clusterM[c]·Slin   about   S·clusterCenter[c]
// where c = the DRIVER's cluster (NOT the mirror vertex's own cluster, and NOT
// the unreflected cluster center). The per-cluster position-copy tail
// (applyTranslatePerCluster's applySymmetryMirror) is deleted.
//
// What these tests pin (headless, through applyFold → applyFoldSymmetryMirror's
// per-cluster Pass B):
//   • A multi-cluster selection STRADDLING the X=0 symmetry plane, where the
//     two clusters are X-mirror partners. Under +1 baseSide the +X cluster
//     drives; the −X cluster is overwritten by the reflection of the +X
//     cluster's operation.
//   • TRANSLATE: each cluster moves along its OWN signed fwd by the same
//     magnitude; the cloud stays symmetric about X=0. (The OLD per-cluster
//     mirror reflected the −X cluster's OWN matrix about the UNREFLECTED −X
//     center → wrong magnitude/direction; this test distinguishes.)
//   • ROTATE: the reflected per-cluster rotation (Slin·R·Slin) keeps the cloud
//     symmetric about X=0 (chirality handled), proving the mirror is correct
//     beyond translate.
//
// Geometry: a size-2, segments-2 cube. Faces 3 (−X, normal −X) and 7 (+X,
// normal +X) are disjoint and form two clusters whose vertices pair exactly
// across X=0:
//   face 3 verts 2,5,8,6  ↔  face 7 verts 11,16,17,13.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}
void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}
bool approxEq(double a, double b, double eps = 2e-3) {
    return fabs(a - b) < eps;
}

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

// Mirror-symmetry test about the X=0 plane: for every vert there is a vert at
// its X-reflection (−x, y, z).
bool symmetricAboutX(double[3][] verts, double eps = 2e-3) {
    foreach (v; verts) {
        bool found = false;
        foreach (w; verts) {
            if (approxEq(w[0], -v[0], eps) && approxEq(w[1], v[1], eps)
                && approxEq(w[2], v[2], eps)) { found = true; break; }
        }
        if (!found) return false;
    }
    return true;
}

// Empty reset → size-2 segments-2 cube → select faces 3 & 7 → move/rotate tool
// → actr.local → X symmetry. `toolId` is "move" or "rotate". The two selected
// faces are on opposite X sides and pair across X=0, so ACEN.Local sees two
// X-mirror clusters.
void setupLocalSymmScene(string toolId) {
    postJson("/api/reset?empty=true", "");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:2 sizeY:2 sizeZ:2 "
        ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
    cmd("select.typeFrom polygon");
    auto sel = postJson("/api/select",
                        `{"mode":"polygons","indices":[3,7]}`);
    assert(sel["status"].str == "ok", "select failed: " ~ sel.toString);
    cmd("tool.set " ~ toolId ~ " on");
    cmd("actr.local");                       // per-cluster action centers + axes
    cmd("tool.pipe.attr symmetry enabled true");
    cmd("tool.pipe.attr symmetry axis x");
    cmd("tool.pipe.attr symmetry offset 0");
}

// Confirm the scene really produced two X-mirror clusters before asserting on
// the deformation — otherwise a clustering regression would make the symmetry
// assertions vacuously pass.
void assertTwoMirrorClusters() {
    auto e = postJson("/api/toolpipe/eval", "");
    auto centers = e["actionCenter"]["clusterCenters"].array;
    assert(centers.length == 2,
        "expected 2 clusters, got " ~ centers.length.to!string);
    auto c0 = centers[0].array, c1 = centers[1].array;
    // Centers must be X-reflections of each other (same Y,Z, opposite X).
    assert(approxEq(c0[0].floating, -c1[0].floating)
        && approxEq(c0[1].floating,  c1[1].floating)
        && approxEq(c0[2].floating,  c1[2].floating),
        "the two cluster centers must be X-mirror partners: "
        ~ centers.to!string);
}

// ---------------------------------------------------------------------------
// (translate) Per-cluster TRANSLATE under ACEN.Local + X symmetry. Each cluster
// moves along its OWN signed fwd (±X) by the same magnitude; the +X cluster
// drives and the −X cluster is the reflection of the +X cluster's operation.
// Result: +X verts → x=+1.5, −X verts → x=−1.5, cloud symmetric about X=0.
//
// The OLD per-cluster mirror (reflect the −X cluster's OWN matrix about the
// UNREFLECTED −X center) gives x=−0.5 for the −X verts — this test fails it.
// ---------------------------------------------------------------------------
unittest {
    setupLocalSymmScene("move");
    assertTwoMirrorClusters();
    auto before = dumpVerts();

    cmd("tool.attr move TZ 0.5");             // along each cluster's fwd
    cmd("tool.doApply");

    auto after = dumpVerts();
    assert(after.length == before.length, "vert count changed");

    // +X cluster verts (11,13,16,17) move to x=+1.5 along +X (their fwd).
    foreach (vi; [11, 13, 16, 17]) {
        assert(approxEq(after[vi][0], 1.5),
            "+X cluster vert " ~ vi.to!string ~ " must reach x=+1.5 "
            ~ "(driver, fwd=+X, |Δ|=0.5); got " ~ after[vi][0].to!string);
        // Y/Z untouched by a fwd-only translate.
        assert(approxEq(after[vi][1], before[vi][1])
            && approxEq(after[vi][2], before[vi][2]),
            "+X cluster vert " ~ vi.to!string ~ " Y/Z must not move");
    }
    // −X cluster verts (2,5,6,8) are the REFLECTION of the +X cluster: they
    // move to x=−1.5 (NOT x=−0.5, the old wrong-cluster/unreflected-pivot
    // result). This is the Stage-2b assertion.
    foreach (vi; [2, 5, 6, 8]) {
        assert(approxEq(after[vi][0], -1.5),
            "−X mirror cluster vert " ~ vi.to!string ~ " must reach x=−1.5 "
            ~ "(reflection of the +X DRIVER cluster, NOT its own cluster's "
            ~ "matrix about the unreflected center → x=−0.5). got "
            ~ after[vi][0].to!string);
        assert(approxEq(after[vi][1], before[vi][1])
            && approxEq(after[vi][2], before[vi][2]),
            "−X mirror cluster vert " ~ vi.to!string ~ " Y/Z must not move");
    }

    // Whole-cloud mirror invariant.
    assert(symmetricAboutX(after),
        "per-cluster translate under X-symm must keep the mesh symmetric "
        ~ "about X=0");
}

// ---------------------------------------------------------------------------
// (rotate) Per-cluster ROTATE under ACEN.Local + X symmetry. A rotate about
// each cluster's fwd, mirrored as Slin·R·Slin about the reflected cluster
// center, must keep the cloud symmetric about X=0 (chirality handled). Pins
// the per-cluster mirror beyond translate.
// ---------------------------------------------------------------------------
unittest {
    setupLocalSymmScene("rotate");
    assertTwoMirrorClusters();
    auto before = dumpVerts();

    cmd("tool.attr rotate RZ 40");
    cmd("tool.doApply");

    auto after = dumpVerts();
    assert(after.length == before.length, "vert count changed");

    assert(symmetricAboutX(after),
        "per-cluster rotate under X-symm must keep the mesh symmetric about "
        ~ "X=0 (Slin·R·Slin per cluster, reflected center)");

    // Sanity: geometry actually rotated (some cluster vert's Y or Z moved).
    bool moved = false;
    foreach (vi; [2, 5, 6, 8, 11, 13, 16, 17])
        if (!approxEq(after[vi][1], before[vi][1])
         || !approxEq(after[vi][2], before[vi][2])) { moved = true; break; }
    assert(moved, "RZ=40 per-cluster rotate should actually move geometry");

    // X is the symmetry axis and the rotate is about ±X → X coords of the
    // selected cluster verts are unchanged (rotation about X preserves X).
    foreach (vi; [2, 5, 6, 8, 11, 13, 16, 17])
        assert(approxEq(after[vi][0], before[vi][0]),
            "rotate about cluster fwd (±X) must preserve X for vert "
            ~ vi.to!string);
}
