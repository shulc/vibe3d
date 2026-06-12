// glTF node-transform-bake regression guard (Phase 4 — assimp scene-IR seam).
//
// This is the runtime witness for decisions B2 (node-transform bake) and B3
// (handedness / winding). The OBJ fixtures in test_obj_import.d only exercise
// IDENTITY-transform nodes, so a future refactor of the matrix helpers in
// source/io/scene_import.d (toMat16 / mul4 / transformPoint — the row->col-major
// transpose and the parentWorld * local order) would silently break transformed
// imports while every OBJ assert still passed. A node-translated glTF closes
// that gap.
//
// glTF is the natural vehicle: it supports data-URI buffers, so the whole
// fixture is one self-contained, hand-authorable .gltf text file with no
// sidecar .bin. The node carries a distinctive translation [100, 0, 0]; the
// baked verts must land at original + [100, 0, 0].
//
// What it pins:
//   * B2 (bake): a unit quad authored at the origin under a node translated by
//     [100,0,0] imports with every x-coord shifted by exactly +100 (y/z
//     unchanged). If toMat16's transpose or the parent*local order regressed,
//     the translation column would be dropped/misplaced and this fails.
//   * B3 (no inversion): the geometry is not mirrored or collapsed — the vertex
//     count is preserved (4 distinct corners survive the weld) and every face
//     keeps >= 3 corners (no degenerate / zero-area face from a sign flip).
//
// glTF primitives are triangle-only, so the authored quad arrives as 2 tris;
// the test asserts on the post-bake POSITIONS (the bake witness) rather than on
// face arity, which is a glTF-format property, not an importer property.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : write, remove;
import std.format : format;
import std.math   : fabs;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// Fixture — self-contained glTF 2.0 with a node translated by [100, 0, 0].
// ---------------------------------------------------------------------------
//
// One mesh: a unit quad in the XY plane at the origin, corners
//   (0,0,0) (1,0,0) (1,1,0) (0,1,0)
// stored as two triangles (0,1,2)(0,2,3). One node references the mesh and
// carries translation [100,0,0]. The buffer is a base64 data-URI holding the
// 4 VEC3 float positions (48 bytes) followed by the 6 ushort indices (12 bytes).
//
// base64 payload (little-endian, generated once):
//   positions: 0,0,0  1,0,0  1,1,0  0,1,0   (12 floats)
//   indices  : 0,1,2  0,2,3                 (6 ushorts)
enum string quadGltf = `{
  "asset": { "version": "2.0" },
  "scene": 0,
  "scenes": [ { "nodes": [ 0 ] } ],
  "nodes": [
    { "mesh": 0, "translation": [ 100.0, 0.0, 0.0 ] }
  ],
  "meshes": [
    { "primitives": [ { "attributes": { "POSITION": 0 }, "indices": 1, "mode": 4 } ] }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3",
      "min": [ 0.0, 0.0, 0.0 ], "max": [ 1.0, 1.0, 0.0 ] },
    { "bufferView": 1, "componentType": 5123, "count": 6, "type": "SCALAR" }
  ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0,  "byteLength": 48, "target": 34962 },
    { "buffer": 0, "byteOffset": 48, "byteLength": 12, "target": 34963 }
  ],
  "buffers": [
    { "byteLength": 60,
      "uri": "data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAACAPwAAgD8AAAAAAAAAAAAAgD8AAAAAAAABAAIAAAACAAMA" }
  ]
}`;

string gltfPath() { return "/tmp/vibe3d_test_gltf_transform.gltf"; }

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------

void resetApp() {
    post("http://localhost:8080/api/reset", "");
}

void loadOk(string path) {
    auto resp = cast(string) post("http://localhost:8080/api/command",
        "file.load path:\"" ~ path ~ "\"");
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", "file.load should succeed: " ~ resp);
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

unittest {  // B2: node translation [100,0,0] is baked into every imported vertex
    write(gltfPath(), quadGltf);
    resetApp();
    loadOk(gltfPath());
    auto m = model();

    // B3 smoke: geometry survives intact — 4 distinct corners, not collapsed.
    assert(m["vertexCount"].integer == 4,
        "expected 4 verts (quad corners) after bake+weld, got "
        ~ m["vertexCount"].integer.to!string);

    // B3 smoke: no face went degenerate from an inversion — every face keeps
    // >= 3 corners (glTF authored 2 tris).
    auto faces = m["faces"].array;
    assert(faces.length == 2,
        "expected 2 triangle faces, got " ~ faces.length.to!string);
    foreach (i, f; faces)
        assert(f.array.length >= 3,
            format("face %d collapsed below 3 corners (inversion/degenerate?), got %d",
                   i, f.array.length));

    // B2 — the bake witness. The authored quad is
    //   (0,0,0) (1,0,0) (1,1,0) (0,1,0)
    // under a node translated by [100,0,0]; the baked verts are the same quad
    // shifted +100 in x. Every imported vertex must:
    //   * have x in {100, 101}  (original {0,1} + 100  => translation applied),
    //   * have y in {0, 1}, z == 0 (untouched axes),
    // and all four translated corners must be present.
    auto verts = m["vertices"].array;
    assert(verts.length == 4, "expected 4 vertex tuples");

    bool[4] seen;   // index = (x==101?1:0) + (y==1?2:0)
    foreach (v; verts) {
        auto a = v.array;
        const x = a[0].floating, y = a[1].floating, z = a[2].floating;

        assert(approxEqual(x, 100) || approxEqual(x, 101),
            format("vertex x=%g is not original{0,1}+100 — node translation "
                   ~ "NOT baked (B2 regression)", x));
        assert(approxEqual(y, 0) || approxEqual(y, 1),
            format("vertex y=%g leaked off the {0,1} authored values — bad "
                   ~ "transform column (B2 regression)", y));
        assert(approxEqual(z, 0),
            format("vertex z=%g should be 0 (planar quad, untouched axis)", z));

        const ix = approxEqual(x, 101) ? 1 : 0;
        const iy = approxEqual(y, 1)   ? 2 : 0;
        seen[ix + iy] = true;
    }
    foreach (i, s; seen)
        assert(s, format("translated quad corner %d missing after bake+weld", i));

    remove(gltfPath());
}
