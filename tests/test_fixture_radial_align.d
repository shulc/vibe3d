// Fixture tests for the interactive Radial Align tool (task 0361,
// `xfrm.radialAlignTool`, source/tools/radial_align_tool.d) — the
// headless-attr-driven Post-Mode path (`tool.set ... on; tool.attr ...;
// tool.doApply`), same activation shape as xfrm.push/xfrm.bend. Exercises
// the interactive-tool entry point specifically: falloff-stage
// integration (the one-shot `mesh.radial_align` command does NOT have
// this — see tests/test_mesh_radial_align.d for the bit-exact/structural
// kernel-law coverage shared by both entry points), undo via
// tool.doApply's snapshot, and MANIFOLD validity (vertex/edge/face counts
// unchanged — a position-only align must never corrupt topology).
//
// The circle's BASE ANCHOR is an unverified implementation choice (see
// source/tools/align_kernels.d's radialAlignTargets doc comment), so
// these tests assert structural properties (radius from center, "moved
// substantially" vs. "stayed put" under falloff) rather than absolute
// target coordinates.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, sqrt, isNaN;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

double[3][] dumpVerts() {
    double[3][] out_;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        out_ ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return out_;
}

bool approxEq(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

int findVert(double[3][] verts, double x, double y, double z) {
    foreach (i, v; verts)
        if (approxEq(v[0], x) && approxEq(v[1], y) && approxEq(v[2], z))
            return cast(int)i;
    return -1;
}

double dist3(double[3] a, double[3] b) {
    double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return sqrt(dx*dx + dy*dy + dz*dz);
}

void assertManifold(long vBefore, long eBefore, long fBefore) {
    auto model = getJson("/api/model");
    assert(model["vertexCount"].integer == vBefore, "vertex count changed");
    assert(model["edgeCount"].integer == eBefore, "edge count changed");
    assert(model["faceCount"].integer == fBefore, "face count changed");
    foreach (v; model["vertices"].array)
        foreach (c; v.array)
            assert(!isNaN(c.floating), "NaN vertex coordinate after Radial Align");
}

int[4] buildLoop() {
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto before = dumpVerts();
    int idxA = findVert(before, -0.5, -0.5, -0.5);
    int idxB = findVert(before,  0.5, -0.5, -0.5);
    int idxC = findVert(before,  0.5, -0.5,  0.5);
    int idxE = findVert(before, -0.5, -0.5,  0.5);
    assert(idxA >= 0 && idxB >= 0 && idxC >= 0 && idxE >= 0);
    cmd("mesh.move_vertex from:{0.5,-0.5,-0.5} to:{0.7071,-0.5,0.0}");
    postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idxA.to!string ~ `,` ~ idxB.to!string
        ~ `,` ~ idxC.to!string ~ `,` ~ idxE.to!string ~ `]}`);
    return [idxA, idxB, idxC, idxE];
}

unittest { // interactive tool activation + Post-Mode apply reproduces the
           // SAME center/radius law as the one-shot command (bit-exact vs
           // the "ra_circle" capture case).
    auto idx = buildLoop();
    auto source = dumpVerts();
    double[3] center = [0, 0, 0];
    foreach (i; idx) foreach (c; 0 .. 3) center[c] += source[i][c];
    foreach (c; 0 .. 3) center[c] /= 4.0;

    auto model0 = getJson("/api/model");
    long v0 = model0["vertexCount"].integer, e0 = model0["edgeCount"].integer,
         f0 = model0["faceCount"].integer;

    cmd("tool.set xfrm.radialAlignTool on");
    cmd("tool.doApply");
    cmd("tool.set xfrm.radialAlignTool off");

    auto after = dumpVerts();
    foreach (i; idx) {
        double r = dist3(after[i], center);
        assert(approxEq(r, 0.688103, 2e-3), "tool radius mismatch, got " ~ r.to!string);
    }
    assertManifold(v0, e0, f0);

    cmd("history.undo");
    auto restored = dumpVerts();
    assert(approxEq(restored[idx[1]][0], 0.7071) && approxEq(restored[idx[1]][1], -0.5)
        && approxEq(restored[idx[1]][2], 0.0), "undo should restore B's displaced position");
}

unittest { // falloff integration (WGHT stage) — a tiny radial falloff
           // centered exactly at B's source position isolates B (weight
           // ~1) from C (weight ~0, well outside the radius): B must move
           // substantially while C stays at its source position. The
           // one-shot `mesh.radial_align` command has no falloff plumbing
           // (see class doc comment in commands/mesh/radial_align.d).
    auto idx = buildLoop();
    auto source = dumpVerts();

    cmd("tool.set xfrm.radialAlignTool on");
    cmd("tool.pipe.attr falloff type radial");
    cmd(`tool.pipe.attr falloff center "0.7071,-0.5,0.0"`);
    cmd(`tool.pipe.attr falloff size "0.05,0.05,0.05"`);
    cmd("tool.doApply");
    cmd("tool.set xfrm.radialAlignTool off");

    auto after = dumpVerts();
    double movedB = dist3(after[idx[1]], source[idx[1]]);
    assert(movedB > 0.05, "falloff-weighted B should move substantially, moved " ~ movedB.to!string);

    double movedC = dist3(after[idx[2]], source[idx[2]]);
    assert(movedC < 1e-3, "falloff-excluded C should not move, moved " ~ movedC.to!string);
}

unittest { // weight attr blends source -> aligned(weight=1) — bit-exact
           // vs ra_circle_weight05.json's law (checked structurally: the
           // weight=0.5 result must sit exactly halfway, per-component,
           // between the source and the weight=1 result).
    auto idx = buildLoop();
    auto source = dumpVerts();

    cmd("tool.set xfrm.radialAlignTool on");
    cmd("tool.doApply");
    cmd("tool.set xfrm.radialAlignTool off");
    auto aligned = dumpVerts();
    cmd("history.undo");

    cmd("select.typeFrom vertex");
    postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idx[0].to!string ~ `,` ~ idx[1].to!string
        ~ `,` ~ idx[2].to!string ~ `,` ~ idx[3].to!string ~ `]}`);

    cmd("tool.set xfrm.radialAlignTool on");
    cmd("tool.attr xfrm.radialAlignTool weight 0.5");
    cmd("tool.doApply");
    cmd("tool.set xfrm.radialAlignTool off");
    auto blended = dumpVerts();

    foreach (i; idx) {
        foreach (c; 0 .. 3) {
            double want = source[i][c] + (aligned[i][c] - source[i][c]) * 0.5;
            assert(approxEq(blended[i][c], want, 1e-3),
                "weight=0.5 mismatch at vert " ~ i.to!string ~ " axis " ~ c.to!string);
        }
    }
}

unittest { // nside mode + side param reach the kernel via tool.attr.
    auto idx = buildLoop();
    auto source = dumpVerts();
    double[3] center = [0, 0, 0];
    foreach (i; idx) foreach (c; 0 .. 3) center[c] += source[i][c];
    foreach (c; 0 .. 3) center[c] /= 4.0;

    cmd("tool.set xfrm.radialAlignTool on");
    cmd("tool.attr xfrm.radialAlignTool mode nside");
    cmd("tool.attr xfrm.radialAlignTool side 4");
    cmd("tool.doApply");
    cmd("tool.set xfrm.radialAlignTool off");

    auto after = dumpVerts();
    foreach (i; idx) {
        double r = dist3(after[i], center);
        assert(approxEq(r, 0.688103, 2e-3), "nside tool radius mismatch, got " ~ r.to!string);
    }
}

unittest { // `side` DoS clamp — an absurd value must not hang or corrupt
           // the mesh (task 0361 review convention: count param clamp).
    auto idx = buildLoop();
    auto model0 = getJson("/api/model");
    long v0 = model0["vertexCount"].integer, e0 = model0["edgeCount"].integer,
         f0 = model0["faceCount"].integer;

    cmd("tool.set xfrm.radialAlignTool on");
    cmd("tool.attr xfrm.radialAlignTool mode nside");
    cmd("tool.attr xfrm.radialAlignTool side 2000000000");
    cmd("tool.doApply");
    cmd("tool.set xfrm.radialAlignTool off");

    assertManifold(v0, e0, f0);
}

unittest { // no selection -> whole-mesh fallback must not crash.
    postJson("/api/reset", "");
    auto model0 = getJson("/api/model");
    long v0 = model0["vertexCount"].integer, e0 = model0["edgeCount"].integer,
         f0 = model0["faceCount"].integer;

    cmd("tool.set xfrm.radialAlignTool on");
    cmd("tool.doApply");
    cmd("tool.set xfrm.radialAlignTool off");

    assertManifold(v0, e0, f0);
}
