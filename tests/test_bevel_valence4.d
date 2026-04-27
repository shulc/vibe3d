// Regression test for the F_OTHER splice bug: bevel of a single edge whose
// endpoints have valence > 3 (e.g. after Catmull-Clark subdivision of a
// cube). vibe3d used to splice the full cap profile [BV_left, BV_right]
// into EVERY F_OTHER face around the bev endpoint, producing 5-vert faces
// where Blender (and topology) expects 4-vert quads. The fix:
// for valence ≥ 4 selCount=1, each F_OTHER face is on a specific side of
// the bev edge in the CCW ring; replace v.vert with just BV_left or
// BV_right based on that side.

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

    // The bevel adds 2 new BV verts and 1 new bevel-quad face.
    // After CC: 26v / 24f. After bevel of one edge: 28v / 25f.
    assert(m["vertexCount"].integer == 28,
        "expected 28 verts after CC+bevel-single-edge, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 25,
        "expected 25 faces, got " ~ m["faceCount"].integer.to!string);

    // CRITICAL: every face must remain a quad. The pre-fix bug produced
    // 5-vert faces in the F_OTHER positions because the cap-profile splice
    // inserted both BVs into faces that should only see one.
    int nonQuad = 0;
    foreach (f; m["faces"].array)
        if (f.array.length != 4) nonQuad++;
    assert(nonQuad == 0,
        "expected all faces quad after valence-4 selCount=1 bevel, got "
        ~ nonQuad.to!string ~ " non-quad faces");
}
