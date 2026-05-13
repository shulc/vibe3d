// Repro for the "tab + move vertex shows no change" bug discovered
// after Phase 3c (subpatch GPU fan-out). User scenario:
//   • Spawn cube
//   • Tab → all 6 faces become subpatch (mesh.subpatch_toggle with
//     empty selection)
//   • Select 1 vertex (vertex 0 here)
//   • Move it (Y axis +1)
//   • Surface should follow.
//
// Two layers are verified:
//   1. Cage state via /api/model — catches plain "/api/transform
//      didn't apply" regressions.
//   2. Rendered surface via /api/gpu/face-vbo — catches GPU fan-out
//      regressions where the cage moved but gpu.faceVbo didn't get
//      rewritten, which is what the original bug report described
//      ("я выделяю вершину и пытаюсь сделать move, и ничего не
//      происходит" — visually no change).

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

bool approxEq(double a, double b) { return fabs(a - b) < 1e-4; }

double[3] cageVertex(int idx) {
    auto m  = getJson("/api/model");
    auto v  = m["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

bool[] subpatchFlags() {
    auto a = getJson("/api/model")["isSubpatch"].array;
    bool[] r;
    foreach (n; a) r ~= n.type == JSONType.true_;
    return r;
}

struct GpuSurface {
    int        faceVertCount;
    double[3][] positions;
}

GpuSurface gpuSurface() {
    auto j = getJson("/api/gpu/face-vbo");
    GpuSurface s;
    s.faceVertCount = cast(int) j["faceVertCount"].integer;
    foreach (p; j["positions"].array) {
        auto a = p.array;
        s.positions ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return s;
}

double maxDelta(in double[3][] a, in double[3][] b) {
    assert(a.length == b.length, "vertex count must match for delta");
    double m = 0;
    foreach (i; 0 .. a.length)
        foreach (k; 0 .. 3) {
            double d = fabs(a[i][k] - b[i][k]);
            if (d > m) m = d;
        }
    return m;
}

unittest { // cage vertex moves through /api/transform while subpatch is active
    // Fresh cube.
    postJson("/api/reset", "");

    // mesh.subpatch_toggle requires Polygons mode; with no selection
    // it flips every face. That mirrors the Tab keyboard handler.
    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/command", `{"id":"mesh.subpatch_toggle"}`);

    auto sub = subpatchFlags();
    assert(sub.length == 6, "cube should still have 6 faces");
    foreach (i, b; sub)
        assert(b, "face " ~ i.to!string ~ " should be subpatch after Tab");

    // Switch back to vertex mode and select vertex 0.
    postJson("/api/command", "select.typeFrom vertex");
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);

    auto before = cageVertex(0);

    // Translate the selection by (0, 1, 0) — same input the move tool
    // would produce on a Y-axis gizmo drag.
    auto r = postJson("/api/transform",
                       `{"kind":"translate","delta":[0,1,0]}`);
    assert(r["status"].str == "ok",
        "/api/transform reported error: " ~ r.toString);

    auto after = cageVertex(0);
    assert(approxEq(after[0], before[0]),
        "cage v0 X drifted: " ~ before[0].to!string
                              ~ " → " ~ after[0].to!string);
    assert(approxEq(after[1], before[1] + 1.0),
        "cage v0 Y should have moved by 1, got "
        ~ before[1].to!string ~ " → " ~ after[1].to!string);
    assert(approxEq(after[2], before[2]),
        "cage v0 Z drifted: " ~ before[2].to!string
                              ~ " → " ~ after[2].to!string);
}

unittest { // gpu.faceVbo (the surface that the user sees) actually
           // changes when we move a vertex of a subpatch cube
    postJson("/api/reset", "");
    auto cageSurface = gpuSurface();
    // Cage cube renders 6 faces × 2 triangles × 3 verts = 36 face-verts.
    assert(cageSurface.faceVertCount == 36,
        "fresh cube should expose 36 face-verts, got "
        ~ cageSurface.faceVertCount.to!string);

    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/command", `{"id":"mesh.subpatch_toggle"}`);

    auto preSurface = gpuSurface();
    assert(preSurface.faceVertCount > cageSurface.faceVertCount,
        "subpatch preview should expose more face-verts than the cage "
        ~ "(got " ~ preSurface.faceVertCount.to!string
        ~ " vs cage " ~ cageSurface.faceVertCount.to!string
        ~ ") — if not, subpatch isn't actually active");

    // Move vertex 0 by (0, 1, 0).
    postJson("/api/command", "select.typeFrom vertex");
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    auto r = postJson("/api/transform",
                       `{"kind":"translate","delta":[0,1,0]}`);
    assert(r["status"].str == "ok",
        "/api/transform reported error: " ~ r.toString);

    auto postSurface = gpuSurface();
    assert(preSurface.faceVertCount == postSurface.faceVertCount,
        "face-vert count changed (" ~ preSurface.faceVertCount.to!string
        ~ " → " ~ postSurface.faceVertCount.to!string
        ~ ") — topology shouldn't shift on a translate");

    auto delta = maxDelta(preSurface.positions, postSurface.positions);
    assert(delta > 0.1,
        "subpatch surface didn't move after /api/transform translate "
        ~ "(0,1,0): max per-vertex |Δ| = " ~ delta.to!string
        ~ " (expected something close to 1 — the cage vertex moved by "
        ~ "1 unit and at depth 2 several preview verts pile onto "
        ~ "that corner). If you see this, the GPU fan-out path is "
        ~ "writing stale/garbage positions into gpu.faceVbo.");
}
