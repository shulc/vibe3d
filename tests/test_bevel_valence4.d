// Regression test for the F_OTHER splice bug: bevel of a single edge whose
// endpoints have valence > 3 (e.g. after Catmull-Clark subdivision of a
// cube). Two-stage history:
//
//  1) vibe3d used to splice the full cap profile [BV_left, BV_right] into
//     EVERY F_OTHER face around the bev endpoint, producing 5-vert faces.
//     Fix: per-side replace — F_OTHERs CCW-closer to BV_left replace
//     v.vert with BV_left, the others with BV_right (line 1311+ in
//     source/bevel.d). Faces stay quads.
//
//  2) That fix hit a fresh bug for EVEN valence ≥ 4: with no equidistant
//     F_OTHER (only odd valences have one), the boundary between the
//     left-group and right-group of F_OTHERs ran along a non-bev edge
//     "EH_b" that was previously shared via v.vert. After per-side
//     replace, one side keeps v.vert (via reusesOrig) while the other has
//     BV_right — the edge no longer matches → 6 boundary edges (2 missing
//     triangular cap faces, one per endpoint of the beveled edge).
//     Fix: emit a `materializeBackCapEvenValence` cap face (triangle for
//     seg=1) bridging (rightBV, leftBV, EH_b's other endpoint).
//
// This test must catch both regressions: face-arity check (no 5-vert
// faces from #1) AND closed-manifold check (no boundary edges from #2).

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

private JSONValue postJson(string url, string body_) {
    return parseJSON(post(url, body_));
}

private void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

private void subdivide() {
    // mesh.subdivide requires polygon edit mode (face-level op).
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.subdivide"}`);
    assert(resp["status"].str == "ok", "subdivide failed: " ~ resp.toString());
}

unittest { // bevel an edge between 2 valence-4 verts (CC-subdivided cube edge)
    resetCube();
    subdivide();
    // After CC of cube: 26v, 48e, 24 quad faces. Pick any inner edge whose
    // both endpoints are valence-4 (= CC-introduced edge midpoints + face
    // points). Use edge index 20 = [v_14, v_21] per the canonical
    // post-CC ordering (face point of +Z face to the +Y/+Z edge midpoint).
    post("http://localhost:8080/api/select",
         `{"mode":"edges","indices":[20]}`);
    auto resp = postJson("http://localhost:8080/api/command",
                         `{"id":"mesh.bevel","params":{"width":0.15,"seg":1}}`);
    assert(resp["status"].str == "ok", "bevel failed: " ~ resp.toString());
    auto m = parseJSON(get("http://localhost:8080/api/model"));

    // After CC: 26V/48E/24F. After bevel of one edge with the Phase 2
    // edge-keyed BoundVert model (doc/bevel_blender_refactor_plan.md
    // REVISED v2):
    //   +4 verts (each endpoint: 1 new BV "rightBV-of-bev" + 1 edge-BV
    //             on the back EH; reused leftBV stays at the original
    //             vertId)
    //   +1 strip quad (4-vert)
    //   +4 F_OTHER pentagons (was 4 quads; splice-2 inserts edge-BV
    //                         + flanking BV at each F_OTHER's v_orig
    //                         corner)
    //   +2 cap-at-v triangles (rightBV → leftBV → edgeBV per endpoint)
    //   = 30V / 27F with arity {4: 21, 5: 4, 3: 2}
    // Matches Blender's bmesh_bevel.cc bit-for-bit on this case
    // (tools/blender_diff/cases/cc_valence4_single_edge.json XPASS).
    assert(m["vertexCount"].integer == 30,
        "expected 30 verts after CC+bevel-single-edge, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 27,
        "expected 27 faces (16 + 4 quads bev + 1 strip + 4 pent + 2 tri), got "
        ~ m["faceCount"].integer.to!string);

    // Arity check: 21 quads, 4 pentagons (F_OTHER splice-2), 2 triangles
    // (cap-at-v). Anything else signals a regression.
    int nQuad = 0, nPent = 0, nTri = 0, nOther = 0;
    foreach (f; m["faces"].array) {
        switch (f.array.length) {
            case 4: nQuad++; break;
            case 5: nPent++; break;
            case 3: nTri++;  break;
            default: nOther++; break;
        }
    }
    assert(nQuad == 21,
        "expected 21 quads, got " ~ nQuad.to!string);
    assert(nPent == 4,
        "expected 4 F_OTHER pentagons (splice-2 of edge-BV at each "
        ~ "F_OTHER corner), got " ~ nPent.to!string);
    assert(nTri == 2,
        "expected 2 cap-at-v triangles (one per endpoint), got "
        ~ nTri.to!string);
    assert(nOther == 0,
        "expected only 4-, 5-, 3-vert faces; got " ~ nOther.to!string
        ~ " faces with other arity");

    // CRITICAL #2: closed manifold — every undirected edge must be
    // incident to exactly two faces. The pre-#2-fix bug left 6 boundary
    // edges (2 triangular holes, one per endpoint).
    int[long] uses;
    static long ekey(long a, long b) {
        return (a < b) ? (a << 32) | b : (b << 32) | a;
    }
    foreach (f; m["faces"].array) {
        auto fv = f.array;
        foreach (i, _; fv) {
            long u = fv[i].integer, v = fv[(i + 1) % fv.length].integer;
            uses[ekey(u, v)]++;
        }
    }
    int boundary = 0, nonManifold = 0;
    foreach (k, c; uses) {
        if (c == 1) boundary++;
        else if (c > 2) nonManifold++;
    }
    assert(boundary == 0,
        "expected closed manifold after CC+bevel-single-edge, got "
        ~ boundary.to!string ~ " boundary edges");
    assert(nonManifold == 0,
        "expected manifold after CC+bevel-single-edge, got "
        ~ nonManifold.to!string ~ " edges shared by >2 faces");
}
