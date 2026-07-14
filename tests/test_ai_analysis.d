// Tests for the AI Modeling Copilot Phase 1 (task 0402, doc/ai_copilot_plan.md):
// GET /api/ai/analyze — a read-only, main-thread-bridged snapshot of
// `ai.analysis.analyzeMesh`. No UI, no geometry mutation; this only proves
// the endpoint wiring + JSON shape + the SubdivReadiness detector on a known
// fixture.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void resetCube() {
    auto resp = postJson("/api/reset?type=cube", "");
    assert(resp["status"].str == "ok", "/api/reset cube failed");
}

void resetGrid(int n) {
    auto resp = postJson("/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(resp["status"].str == "ok", "/api/reset grid failed");
}

JSONValue getModel() { return getJson("/api/model"); }

unittest { // cube: at least one SubdivReadiness finding grouping sharp edges
    resetCube();

    auto findings = getJson("/api/ai/analyze");
    assert(findings.type == JSONType.array, "/api/ai/analyze must return a JSON array");
    assert(findings.array.length >= 1, "cube should yield at least one finding");

    auto m = getModel();
    immutable size_t edgeCount = m["edges"].array.length;

    bool[long] coveredEdges;
    foreach (f; findings.array) {
        assert(f["category"].str == "subdivReadiness",
               "Phase 1 only emits SubdivReadiness findings, got " ~ f["category"].str);
        assert(f["suggestedOp"].str == "loop.slice");
        assert(f["id"].str.length > 0);
        assert(f["edges"].type == JSONType.array);
        assert(f["edges"].array.length > 0,
               "a SubdivReadiness finding must carry a non-empty edge set");
        foreach (e; f["edges"].array) {
            long ei = e.integer;
            assert(ei >= 0 && cast(size_t)ei < edgeCount,
                   "finding edge index must reference a real mesh edge");
            coveredEdges[ei] = true;
        }
        // Element sets act-on would select — verts/faces are unpopulated by
        // the SubdivReadiness detector but must still be present (valid,
        // possibly-empty arrays), and score/features must be well-formed.
        assert(f["verts"].type == JSONType.array);
        assert(f["faces"].type == JSONType.array);
        assert(f["score"].type == JSONType.float_ || f["score"].type == JSONType.integer);
        assert(f["features"].type == JSONType.array);
        assert(f["features"].array.length > 0);
    }
    assert(coveredEdges.length > 0, "the cube's sharp edges should be covered by findings");
}

unittest { // flat grid: zero findings
    resetGrid(4);

    auto findings = getJson("/api/ai/analyze");
    assert(findings.type == JSONType.array);
    assert(findings.array.length == 0,
           "a flat grid has no sharp edges; expected zero findings, got " ~
           findings.array.length.to!string);
}

unittest { // determinism: two GETs on the same (unmutated) mesh agree
    resetCube();
    auto a = getJson("/api/ai/analyze");
    auto b = getJson("/api/ai/analyze");
    assert(a.array.length == b.array.length);
    foreach (i; 0 .. a.array.length) {
        assert(a.array[i]["id"].str == b.array[i]["id"].str);
        assert(a.array[i]["edges"] == b.array[i]["edges"]);
    }
}
