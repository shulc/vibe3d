// Tests for the interactive Vertex Extrude tool (factory id
// `mesh.vertexExtrude`, task 0360 — promotes the pre-existing one-shot
// mesh.vertexExtrude command, freshly ported to the cone/ring kernel, to a
// tool.set/tool.attr/tool.doApply-driven interactive tool with two
// independent handles, Extrude=shift and Width=width). Kernel-level laws
// (no-op, ring-around-stationary-apex, the golden 4-corner parity fixture)
// are pinned by tests/test_vertex_extrude.d directly against
// mesh.extrudeVerticesByMask — this file exercises the interactive session
// lifecycle (activate/two-attr/apply/deactivate/undo), same shape as
// tests/test_poly_inset.d's Test F/G for its sibling tool.

import std.net.curl;
import std.json;
import std.conv : to;
import std.string : split;

void main() {}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/command failed: " ~ resp ~ "\nbody: " ~ body);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel()     { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }

bool isVertexSelected(JSONValue sel, int vi) {
    foreach (jv; sel["selectedVertices"].array)
        if (cast(int)jv.integer == vi) return true;
    return false;
}

// Every DIRECTED face edge (a->b) must appear exactly once, with its
// reverse (b->a) also appearing exactly once elsewhere (task 0360
// deliverable: fixtures must assert manifold validity, not just counts).
void assertManifold(JSONValue m) {
    int[string] count;
    foreach (f; m["faces"].array) {
        auto vs = f.array;
        size_t n = vs.length;
        foreach (k; 0 .. n) {
            long a = vs[k].integer;
            long b = vs[(k + 1) % n].integer;
            string key = a.to!string ~ "_" ~ b.to!string;
            count[key] = (key in count ? count[key] : 0) + 1;
        }
    }
    foreach (key, c; count) {
        assert(c == 1, "non-manifold: directed edge " ~ key ~ " used " ~ c.to!string ~ " times");
        auto parts = key.split("_");
        string revKey = parts[1] ~ "_" ~ parts[0];
        assert((revKey in count) !is null && count[revKey] == 1,
               "non-manifold: edge " ~ key ~ " has no single matching reverse");
    }
}

// ---------------------------------------------------------------------------
// A — GOLDEN FIXTURE via the interactive path (task 0360 parity_case
//     corners4_width02_stationary_apex): 4 mutually-adjacent corners,
//     Extrude(shift)=0, Width=0.2 -> 8v/6f => 32v/30f, apex stationary +
//     still selected, manifold. Same numbers as the direct-kernel golden
//     fixture in test_vertex_extrude.d, driven this time through
//     tool.set/tool.attr/tool.doApply.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    assert(before["vertexCount"].integer == 8 && before["faceCount"].integer == 6,
        "A: base cube must be 8v/6f");
    postSelect("vertices", [1, 2, 5, 6]);

    postCommand("tool.set mesh.vertexExtrude on");
    postCommand("tool.attr mesh.vertexExtrude shift 0");
    postCommand("tool.attr mesh.vertexExtrude width 0.2");
    postCommand("tool.doApply");
    postCommand("tool.set mesh.vertexExtrude off");

    auto m = getModel();
    assert(m["vertexCount"].integer == 32,
        "A: expected 32 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 30,
        "A: expected 30 faces, got " ~ m["faceCount"].integer.to!string);

    auto sel = getSelection();
    foreach (vi; [1, 2, 5, 6])
        assert(isVertexSelected(sel, vi),
               "A: apex " ~ vi.to!string ~ " must remain selected");

    assertManifold(m);

    auto u = postUndo();
    assert(u["status"].str == "ok", "A: undo failed: " ~ u.toString);
    auto mUndo = getModel();
    assert(mUndo["vertexCount"].integer == before["vertexCount"].integer,
        "A undo: vertex count not restored");
    assert(mUndo["faceCount"].integer == before["faceCount"].integer,
        "A undo: face count not restored");
}

// ---------------------------------------------------------------------------
// B — Extrude (shift) alone, Width left at 0: confirmed no-op, no undo entry
//     needed.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    postSelect("vertices", [0]);

    postCommand("tool.set mesh.vertexExtrude on");
    postCommand("tool.attr mesh.vertexExtrude shift 0.3");
    postCommand("tool.doApply");
    postCommand("tool.set mesh.vertexExtrude off");

    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer,
        "B: shift-alone must not change vertex count");
    assert(m["faceCount"].integer == before["faceCount"].integer,
        "B: shift-alone must not change face count");
}

// ---------------------------------------------------------------------------
// C — Width alone on a single corner (valence 3): +6v/+6f, matches the
//     kernel-level test directly.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    postSelect("vertices", [0]);

    postCommand("tool.set mesh.vertexExtrude on");
    postCommand("tool.attr mesh.vertexExtrude width 0.2");
    postCommand("tool.doApply");
    postCommand("tool.set mesh.vertexExtrude off");

    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer + 6,
        "C: expected +6 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == before["faceCount"].integer + 6,
        "C: expected +6 faces, got " ~ m["faceCount"].integer.to!string);
    assertManifold(m);
}
