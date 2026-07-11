// Tests for the interactive Vertex Bevel tool (factory id
// `mesh.vertexBevel`, task 0360 — promotes the pre-existing one-shot
// mesh.vertexBevel command to a tool.set/tool.attr/tool.doApply-driven
// interactive tool). Geometry law itself (split points, cap, no-op at
// inset<=0) is already pinned by tests/test_vertex_bevel.d against
// mesh.bevelVerticesByMask directly — this file only exercises the
// interactive session lifecycle (activate/attr/apply/deactivate/undo),
// same shape as tests/test_poly_inset.d's Test F/G for its sibling tool.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : sqrt;

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

// Non-asserting variant for calls EXPECTED to report "did not apply" (e.g.
// tool.doApply on a genuine no-op — inset<=0 goes through
// mesh.bevelVerticesByMask's own `amount < 1e-6f` no-op guard, which
// reports failure the same way every other topology tool's kernel-level
// no-op does, matching the "postCommandRaw" convention other test files
// use for the one-shot command's own no-op case).
void postCommandRaw(string body) {
    post("http://localhost:8080/api/command", body);
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
JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }

// ---------------------------------------------------------------------------
// A — headless session: tool.set on, tool.attr inset 0.2, tool.doApply,
//     tool.set off -> same counts as the one-shot command (10v/7f on corner
//     0). Undo restores the original 8v/6f.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    postSelect("vertices", [0]);

    postCommand("tool.set mesh.vertexBevel on");
    postCommand("tool.attr mesh.vertexBevel inset 0.2");
    postCommand("tool.doApply");
    postCommand("tool.set mesh.vertexBevel off");

    auto m = getModel();
    assert(m["vertexCount"].integer == 10,
        "A: expected 10 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "A: expected 7 faces, got " ~ m["faceCount"].integer.to!string);

    auto u = postUndo();
    assert(u["status"].str == "ok", "A: undo failed: " ~ u.toString);
    auto mUndo = getModel();
    assert(mUndo["vertexCount"].integer == before["vertexCount"].integer,
        "A undo: vertex count not restored");
    assert(mUndo["faceCount"].integer == before["faceCount"].integer,
        "A undo: face count not restored");
}

// ---------------------------------------------------------------------------
// B — inset=0 (the reference default): interactive apply must be a genuine
//     no-op (captured law: BOTH inset==0 and inset<0 are byte-exact no-ops,
//     unlike poly.inset's degenerate split at 0). No undo entry should be
//     needed since nothing changed.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    postSelect("vertices", [0]);

    postCommand("tool.set mesh.vertexBevel on");
    postCommand("tool.attr mesh.vertexBevel inset 0");
    postCommand("tool.doApply");
    postCommand("tool.set mesh.vertexBevel off");

    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer,
        "B: inset=0 must not change vertex count");
    assert(m["faceCount"].integer == before["faceCount"].integer,
        "B: inset=0 must not change face count");
}

// ---------------------------------------------------------------------------
// C — negative inset (captured law: also a no-op, unlike a positive value).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = getModel();
    postSelect("vertices", [0]);

    postCommand("tool.set mesh.vertexBevel on");
    postCommand("tool.attr mesh.vertexBevel inset -0.2");
    postCommandRaw("tool.doApply");   // expected no-op, see helper doc-comment
    postCommand("tool.set mesh.vertexBevel off");

    auto m = getModel();
    assert(m["vertexCount"].integer == before["vertexCount"].integer,
        "C: negative inset must not change vertex count");
    assert(m["faceCount"].integer == before["faceCount"].integer,
        "C: negative inset must not change face count");
}
