// Fixture tests for the interactive Linear Align tool (task 0361,
// `xfrm.linearAlignTool`, source/tools/linear_align_tool.d) — the
// headless-attr-driven Post-Mode path (`tool.set ... on; tool.attr ...;
// tool.doApply`), same activation shape as xfrm.push/xfrm.bend. Exercises
// the interactive-tool entry point specifically: falloff-stage
// integration (which the one-shot `mesh.linear_align` command does NOT
// have — see tests/test_mesh_linear_align.d for the bit-exact kernel-law
// coverage shared by both entry points), undo via tool.doApply's
// snapshot, and MANIFOLD validity (vertex/edge/face counts unchanged — a
// position-only align must never corrupt topology; see task 0361's
// review-convention note on count-only fixtures missing non-manifold
// results).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs, isNaN;

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

void assertManifold(long vBefore, long eBefore, long fBefore) {
    auto model = getJson("/api/model");
    assert(model["vertexCount"].integer == vBefore,
        "vertex count changed: " ~ model["vertexCount"].integer.to!string ~ " != " ~ vBefore.to!string);
    assert(model["edgeCount"].integer == eBefore,
        "edge count changed: " ~ model["edgeCount"].integer.to!string ~ " != " ~ eBefore.to!string);
    assert(model["faceCount"].integer == fBefore,
        "face count changed: " ~ model["faceCount"].integer.to!string ~ " != " ~ fBefore.to!string);
    foreach (v; model["vertices"].array)
        foreach (c; v.array)
            assert(!isNaN(c.floating), "NaN vertex coordinate after Linear Align");
}

int[4] buildChain() {
    postJson("/api/reset", "");
    cmd("select.typeFrom vertex");
    auto before = dumpVerts();
    int idxA = findVert(before, -0.5, -0.5, -0.5);
    int idxB = findVert(before,  0.5, -0.5, -0.5);
    int idxC = findVert(before,  0.5, -0.5,  0.5);
    int idxD = findVert(before,  0.5,  0.5,  0.5);
    assert(idxA >= 0 && idxB >= 0 && idxC >= 0 && idxD >= 0);
    cmd("mesh.move_vertex from:{0.5,-0.5,-0.5} to:{0.2,-0.15,-0.1}");
    postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idxA.to!string ~ `,` ~ idxB.to!string
        ~ `,` ~ idxC.to!string ~ `,` ~ idxD.to!string ~ `]}`);
    return [idxA, idxB, idxC, idxD];
}

unittest { // interactive tool activation + Post-Mode apply reproduces the
           // SAME kernel law as the one-shot command (bit-exact vs the
           // "la_nonuniform" capture case).
    auto idx = buildChain();
    auto model0 = getJson("/api/model");
    long v0 = model0["vertexCount"].integer, e0 = model0["edgeCount"].integer,
         f0 = model0["faceCount"].integer;

    cmd("tool.set xfrm.linearAlignTool on");
    cmd("tool.doApply");
    cmd("tool.set xfrm.linearAlignTool off");

    auto after = dumpVerts();
    enum double nb = -0.0166667;
    assert(approxEq(after[idx[1]][0], nb) && approxEq(after[idx[1]][1], nb)
        && approxEq(after[idx[1]][2], nb), "tool B mismatch: " ~ after[idx[1]].to!string);
    assert(approxEq(after[idx[0]][0], -0.5), "endpoint A must not move");
    assert(approxEq(after[idx[3]][0],  0.5), "endpoint D must not move");

    assertManifold(v0, e0, f0);

    cmd("history.undo");
    auto restored = dumpVerts();
    assert(approxEq(restored[idx[1]][0], 0.2) && approxEq(restored[idx[1]][1], -0.15)
        && approxEq(restored[idx[1]][2], -0.1), "undo should restore B's displaced position");
}

unittest { // falloff integration (WGHT stage) — a tiny radial falloff
           // centered exactly at B's source position gives B weight~1 and
           // C (well outside the radius) weight~0, so B moves to its
           // aligned target while C stays at its source position. This is
           // the interactive tool's own falloff wiring — the one-shot
           // `mesh.linear_align` command has none (see class doc comment
           // in commands/mesh/linear_align.d).
    auto idx = buildChain();
    auto source = dumpVerts();

    cmd("tool.set xfrm.linearAlignTool on");
    cmd("tool.pipe.attr falloff type radial");
    cmd(`tool.pipe.attr falloff center "0.2,-0.15,-0.1"`);
    cmd(`tool.pipe.attr falloff size "0.05,0.05,0.05"`);
    cmd("tool.doApply");
    cmd("tool.set xfrm.linearAlignTool off");

    auto after = dumpVerts();
    // B (at the falloff center, weight~1) moved to (near) its aligned target.
    enum double nb = -0.0166667;
    assert(approxEq(after[idx[1]][0], nb, 5e-3) && approxEq(after[idx[1]][1], nb, 5e-3)
        && approxEq(after[idx[1]][2], nb, 5e-3),
        "falloff-weighted B should reach its aligned target: " ~ after[idx[1]].to!string);
    // C (well outside the falloff radius, weight~0) should stay put.
    assert(approxEq(after[idx[2]][0], source[idx[2]][0], 1e-3)
        && approxEq(after[idx[2]][1], source[idx[2]][1], 1e-3)
        && approxEq(after[idx[2]][2], source[idx[2]][2], 1e-3),
        "falloff-excluded C should not move: " ~ after[idx[2]].to!string);
}

unittest { // uniform=true panel attr reaches the kernel exactly like the
           // command's `uniform:true` argstring — bit-exact vs
           // la_uniform.json.
    auto idx = buildChain();

    cmd("tool.set xfrm.linearAlignTool on");
    cmd("tool.attr xfrm.linearAlignTool uniform true");
    cmd("tool.doApply");
    cmd("tool.set xfrm.linearAlignTool off");

    auto after = dumpVerts();
    enum double ub = -0.1666667;
    assert(approxEq(after[idx[1]][0], ub) && approxEq(after[idx[1]][1], ub)
        && approxEq(after[idx[1]][2], ub), "uniform tool B mismatch: " ~ after[idx[1]].to!string);
}

unittest { // weight attr blends source -> aligned — bit-exact vs
           // la_weight05.json.
    auto idx = buildChain();

    cmd("tool.set xfrm.linearAlignTool on");
    cmd("tool.attr xfrm.linearAlignTool weight 0.5");
    cmd("tool.doApply");
    cmd("tool.set xfrm.linearAlignTool off");

    auto after = dumpVerts();
    assert(approxEq(after[idx[1]][0], 0.0916667, 1e-3) && approxEq(after[idx[1]][1], -0.0833333, 1e-3)
        && approxEq(after[idx[1]][2], -0.0583333, 1e-3),
        "weight=0.5 tool B mismatch: " ~ after[idx[1]].to!string);
}

unittest { // DoS / degenerate-selection guard: activating the tool with
           // no selection falls back to whole-mesh (matching the
           // command); applyHeadless must not crash on a non-chain
           // selection, and mesh validity is preserved either way.
    postJson("/api/reset", "");
    auto model0 = getJson("/api/model");
    long v0 = model0["vertexCount"].integer, e0 = model0["edgeCount"].integer,
         f0 = model0["faceCount"].integer;

    cmd("tool.set xfrm.linearAlignTool on");
    cmd("tool.doApply");
    cmd("tool.set xfrm.linearAlignTool off");

    assertManifold(v0, e0, f0);
}
