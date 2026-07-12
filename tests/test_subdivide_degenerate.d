// Tests for mesh.subdivide (Catmull-Clark via catmullClarkOsd) against
// degenerate input (mesh-robustness batch, fuzz-found).
//
// A zero-area / collinear marked face used to either (a) get silently fed
// into OSD as-is (risking coincident verts / NaNs in the refined output), or
// worse (b) when EVERY face in the refine subset is degenerate, OSD can't
// build a topology at all and `catmullClarkOsd` returns `Mesh.init` — which
// the caller (`commands/mesh/subdivide.d`) used to assign straight into
// `*mesh` with NO guard, WIPING the live mesh (0 verts, 0 faces).
//
// The fix: `catmullClarkOsd` rejects the WHOLE refine (returns `Mesh.init`)
// as soon as any marked face is degenerate (reject-whole, not per-face
// skip); the caller now guards that empty result and treats it as a clean
// no-op instead of assigning it into `*mesh`. Both the "one bad face poisons
// a normal mesh" case and the "every face is bad" wipe case are covered here.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

enum BASE = "http://localhost:8080";

string postRaw(string path, string body) {
    return cast(string)post(BASE ~ path, body);
}
JSONValue postJ(string path, string body) { return parseJSON(postRaw(path, body)); }
JSONValue getJ(string path) { return parseJSON(cast(string)get(BASE ~ path)); }

void postLoadMesh(string body) {
    auto resp = postJ("/api/load-mesh", body);
    assert(resp["status"].str == "ok", "/api/load-mesh failed: " ~ resp.toString);
}

string postCommandRaw(string body) { return postRaw("/api/command", body); }
JSONValue getModel() { return getJ("/api/model"); }

// ---------------------------------------------------------------------------
// Mesh A: one normal planar quad (verts 0-3) + one degenerate COLLINEAR
// "triangle" (verts 4-6, all on the line y=0,z=0 — zero area).
// ---------------------------------------------------------------------------
enum string MIXED_MESH = `{
  "vertices": [
    [0,0,0], [1,0,0], [1,0,1], [0,0,1],
    [2,0,0], [3,0,0], [4,0,0]
  ],
  "faces": [
    [0,1,2,3],
    [4,5,6]
  ]
}`;

// Mesh B: ONLY the degenerate collinear triangle — every marked face is
// degenerate, so OSD can't build ANY topology (the pre-existing empty-mesh
// wipe path).
enum string ALL_DEGENERATE_MESH = `{
  "vertices": [
    [2,0,0], [3,0,0], [4,0,0]
  ],
  "faces": [
    [0,1,2]
  ]
}`;

unittest { // MixedMeshDegenerateFaceRejectsWhole
    postLoadMesh(MIXED_MESH);

    auto before = getModel();
    assert(before["vertices"].array.length == 7, "BEFORE: expected 7 verts");
    assert(before["faces"].array.length == 2, "BEFORE: expected 2 faces");

    // No selection (Vertices mode after load) => refine whole mesh, which
    // includes the degenerate triangle. Reject-whole must leave the mesh
    // byte-identical to the injected input (clean no-op).
    string raw = postCommandRaw(`{"id":"mesh.subdivide"}`);

    auto after = getModel();
    assert(after["vertices"] == before["vertices"],
        "mixed-mesh subdivide: vertices must be byte-identical after reject, got: "
        ~ after["vertices"].toString);
    assert(after["faces"] == before["faces"],
        "mixed-mesh subdivide: faces must be byte-identical after reject, got: "
        ~ after["faces"].toString);
}

unittest { // AllDegenerateMeshSurvivesNoWipe
    postLoadMesh(ALL_DEGENERATE_MESH);

    auto before = getModel();
    assert(before["vertices"].array.length == 3, "BEFORE: expected 3 verts");
    assert(before["faces"].array.length == 1, "BEFORE: expected 1 face");

    string raw = postCommandRaw(`{"id":"mesh.subdivide"}`);

    auto after = getModel();
    // The critical regression guard: the mesh must SURVIVE (not be wiped to
    // 0 verts / 0 faces) when every marked face is degenerate.
    assert(after["vertices"].array.length > 0,
        "all-degenerate subdivide: mesh must not be wiped (0 verts)");
    assert(after["faces"].array.length > 0,
        "all-degenerate subdivide: mesh must not be wiped (0 faces)");
    // Clean no-op: byte-identical to the injected input.
    assert(after["vertices"] == before["vertices"],
        "all-degenerate subdivide: vertices must be byte-identical after reject");
    assert(after["faces"] == before["faces"],
        "all-degenerate subdivide: faces must be byte-identical after reject");
}
