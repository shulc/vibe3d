// Regression test: re-bevel of cap-arc segment edges produced by a prior
// multi-segment bevel leaves the surface with boundary holes.
//
// Reproduction: cube → select 2 edges meeting at corner v_6 → bevel
// (width=0.165, seg=6) → cap arc has 7 segments [v_6 → v_13 → ... → v_8]
// + the trimmed cube edge (v_2, v_6) is selected automatically. Re-select
// the 7-edge polyline (cube_edge + 6 arc segments) and bevel again.
//
// Currently produces ≈30 boundary edges. The root cause is the wedge-based
// BoundVert model in source/bevel.d:populateBoundVerts: when adjacent
// F_OTHER faces share a non-bev edge through the bv.vert and that vertex
// has selCount=2 (each cap-arc junction here), the per-side BV replacement
// in materializeBevVert breaks edge ownership across the F_OTHER pair.
// On a clean cube the same selCount=2 valence=3 pattern (test_bevel_corner)
// closes correctly because the F_OTHER faces are simple quads; here one
// flank is the 10-vert face that absorbed a cap-profile splice from the
// FIRST bevel, exposing the model's lack of edge-keyed BoundVert ownership.
//
// Fix: see doc/bevel_blender_refactor_plan.md — Phase 4 switches strip
// emission and F_OTHER replacement to use eh.leftBV/eh.rightBV (Blender's
// edge-ownership model from bmesh_bevel.cc:6850-6865), which makes both
// F_OTHERs naturally share the same BV at their common edge.

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
    foreach (i, idx; indices) {
        if (i > 0) body_ ~= ",";
        body_ ~= idx.to!string;
    }
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

private int countNonManifoldEdges(JSONValue m) {
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
    int nonManifold = 0;
    foreach (k, c; uses) if (c > 2) nonManifold++;
    return nonManifold;
}

unittest { // Sanity: 1st multi-seg bevel of two corner-adjacent cube edges is clean.
    resetCube();
    selectEdges([5, 6]);  // two edges meeting at v_6 (+X+Y+Z corner)
    runBevel(`{"width":0.165,"seg":6}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 26);
    assert(m["faceCount"].integer  == 18);
    assert(countBoundaryEdges(m) == 0,
        "1st bevel left " ~ countBoundaryEdges(m).to!string ~ " boundary edges");
    assert(countNonManifoldEdges(m) == 0);
}

unittest { // RE-BEVEL of cap-arc polyline must keep the surface closed.
    resetCube();
    selectEdges([5, 6]);
    runBevel(`{"width":0.165,"seg":6}`);

    // The 1st bevel produced (with seg=6) the cap arc v_6 → v_13 → v_12
    // → v_11 → v_10 → v_9 → v_8 plus the trimmed cube edge (v_2, v_6).
    // Edge indices are deterministic under reset+select+bevel:
    //   E[16] = (v_2,  v_6)   — trimmed +Y/+Z cube edge segment
    //   E[36] = (v_6,  v_13)  — cap arc seg 0
    //   E[35] = (v_13, v_12)  —          seg 1
    //   E[33] = (v_12, v_11)  —          seg 2
    //   E[31] = (v_11, v_10)  —          seg 3
    //   E[29] = (v_10, v_9)   —          seg 4
    //   E[27] = (v_9,  v_8)   —          seg 5
    selectEdges([16, 27, 29, 31, 33, 35, 36]);
    runBevel(`{"width":0.05}`);
    auto m = getModel();

    // ─────────────────────────────────────────────────────────────────────
    // EXPECTED FAILURE TODAY (≈30 boundary edges). Will pass once Phase 4
    // of doc/bevel_blender_refactor_plan.md lands (eh.leftBV/eh.rightBV
    // edge-keyed BoundVert ownership in F_OTHER replacement).
    // ─────────────────────────────────────────────────────────────────────
    int bd = countBoundaryEdges(m);
    int nm = countNonManifoldEdges(m);
    assert(nm == 0,
        "re-bevel produced " ~ nm.to!string ~ " non-manifold edges (>2 faces)");
    assert(bd == 0,
        "re-bevel of cap-arc polyline must keep surface closed; got "
        ~ bd.to!string ~ " boundary edges. See "
        ~ "doc/bevel_blender_refactor_plan.md (Phase 4).");
}
