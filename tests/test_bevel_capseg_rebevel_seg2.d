// Regression test: re-bevel of cap-arc polyline with seg≥2 in the 2nd
// pass closes the surface manifold-ly. Sister to test_bevel_capseg_rebevel.d
// which uses seg=1 in the 2nd pass; this one uses seg=2.
//
// Reproduction: cube → bevel 2 corner edges (selCount=2 valence=3 at v_6)
// width=0.165 seg=3 → cap arc has 4 sample points → 4-edge polyline
// {trimmed cube edge + 3 arc segments} → bevel polyline with seg=2.
//
// Pre-Phase-5 this left 6 boundary edges = 2 triangle holes at polyline
// endpoints (v_2 cube corner + v_8 arc tip). Phase 5 (vid-based
// non-degenerate-profile selection in materializeBevVert + capSamples)
// fixes the F_OTHER fullSplice + strip emission to share consistent
// cap-chain interior verts across selCount=2 valence=4 alternating
// alias-collapse cases. See doc/bevel_blender_refactor_plan.md.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

private JSONValue postJson(string url, string body_) {
    return parseJSON(post(url, body_));
}
private void resetCube() { post("http://localhost:8080/api/reset", ""); }
private void selectEdges(int[] indices) {
    string body_ = `{"mode":"edges","indices":[`;
    foreach (i, idx; indices) { if (i > 0) body_ ~= ","; body_ ~= idx.to!string; }
    body_ ~= "]}";
    auto resp = postJson("http://localhost:8080/api/select", body_);
    assert(resp["status"].str == "ok", "select failed: " ~ resp.toString());
}
private void runBevel(string params) {
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.bevel","params":` ~ params ~ `}`);
    assert(resp["status"].str == "ok", "bevel failed: " ~ resp.toString());
}
private JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

private int countBoundaryEdges(JSONValue m) {
    int[long] uses;
    static long ekey(long a, long b) {
        return (a < b) ? (a << 32) | b : (b << 32) | a;
    }
    foreach (f; m["faces"].array) {
        auto fv = f.array;
        foreach (i, _; fv) {
            long u = fv[i].integer, v = fv[(i + 1) % fv.length].integer;
            if (u == v) continue;
            uses[ekey(u, v)]++;
        }
    }
    int boundary = 0;
    foreach (k, c; uses) if (c == 1) boundary++;
    return boundary;
}

unittest { // Sanity: 1st bevel seg=3 of cube corner produces clean 17V/12F mesh.
    resetCube();
    selectEdges([5, 6]);
    runBevel(`{"width":0.165,"seg":3}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 17);
    assert(m["faceCount"].integer  == 12);
    assert(countBoundaryEdges(m) == 0);
}

unittest { // RE-BEVEL of cap-arc polyline with seg=2 in 2nd pass.
    resetCube();
    selectEdges([5, 6]);
    runBevel(`{"width":0.165,"seg":3}`);

    // Polyline: trimmed cube edge (v_2→v_6) + 3 cap-arc segments.
    // Edge indices stable under reset+select+bevel:
    //   E[13] = (v_2, v_6)
    //   E[24] = (v_6, v_10)
    //   E[23] = (v_10, v_9)
    //   E[21] = (v_9, v_8)
    selectEdges([13, 21, 23, 24]);
    runBevel(`{"width":0.05,"seg":2}`);
    auto m = getModel();

    int bd = countBoundaryEdges(m);

    // Post-Phase-5: vid-based non-degenerate-profile selection in
    // materializeBevVert and capSamples produces a manifold mesh.
    assert(bd == 0,
        "polyline rebevel with seg=2 must keep surface closed; got "
        ~ bd.to!string ~ " boundary edges. See "
        ~ "doc/bevel_blender_refactor_plan.md.");
}
