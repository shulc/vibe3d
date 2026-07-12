// Tests for poly.extrude (Mesh.extrudeFacesByMask) against non-manifold input
// (mesh-robustness batch, fuzz-found).
//
// A "book" mesh — one undirected edge shared by 3+ faces (e.g. 3 quad "pages"
// all hinged on the same edge) — is invalid input for extrude: the kernel's
// island/adjacency bookkeeping (buildEdgeFaces' int[2] slot) can't even see
// the 3rd/4th incident face, so extruding a region touching that edge risked
// winding/coincident corruption. The fix rejects the whole operation (clean
// no-op) whenever a SELECTED face touches an edge already shared by >2 faces
// total. A normal disjoint region (no book edge in its neighborhood) must
// still extrude exactly as before — the guard must not over-reject.
//
// Helpers are a local copy of the 0109 test's assertManifoldClean idiom
// (tests/test_reduce_tool.d).

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

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = postJ("/api/select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(resp["status"].str == "ok", "/api/select failed: " ~ resp.toString);
}

string postCommandRaw(string body) { return postRaw("/api/command", body); }
JSONValue getModel() { return getJ("/api/model"); }

/// Verify no degenerate/duplicate-corner faces, no edge on >2 faces, all
/// vertex coordinates finite.
void assertManifoldClean(JSONValue model, string context) {
    auto faces    = model["faces"].array;
    auto vertices = model["vertices"].array;

    int[ulong] efCount;
    foreach (fi, f; faces) {
        auto fc = f.array;
        assert(fc.length >= 3,
            context ~ ": face " ~ fi.to!string ~ " has " ~ fc.length.to!string ~ " corners");
        bool[size_t] seen;
        foreach (v; fc) {
            auto vi = cast(size_t)v.integer;
            assert(!(vi in seen),
                context ~ ": face " ~ fi.to!string ~ " has duplicate corner " ~ vi.to!string);
            seen[vi] = true;
        }
        foreach (i; 0 .. fc.length) {
            size_t a = cast(size_t)fc[i].integer;
            size_t b = cast(size_t)fc[(i + 1) % fc.length].integer;
            ulong key = a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
            efCount[key]++;
        }
    }
    foreach (key, cnt; efCount)
        assert(cnt <= 2,
            context ~ ": edge 0x" ~ key.to!string(16) ~ " on " ~ cnt.to!string ~ " faces");

    foreach (vi, v; vertices) {
        foreach (coord; v.array) {
            import std.math : isFinite;
            double c = coord.floating;
            assert(isFinite(c),
                context ~ ": vertex " ~ vi.to!string ~ " has non-finite coord");
        }
    }
}

// ---------------------------------------------------------------------------
// Book mesh: 3 quad "pages" all hinged on the shared edge (v0,v1) — the
// undirected edge (0,1) is used by all 3 faces (incidence count 3, i.e.
// non-manifold input).
//
//   page A: [0,1,2,3]   page B: [0,1,4,5]   page C: [0,1,6,7]
// ---------------------------------------------------------------------------

enum string BOOK_MESH = `{
  "vertices": [
    [0,0,0], [0,1,0], [1,1,0], [1,0,0],
    [0,1,1], [0,0,1], [-1,1,0], [-1,0,0]
  ],
  "faces": [
    [0,1,2,3],
    [0,1,4,5],
    [0,1,6,7]
  ]
}`;

// A normal, fully-manifold 2-quad region sharing one interior edge (9-... see
// below) — NOT touching any book edge. Used to prove the guard does not
// over-reject an ordinary adjacent-face selection.
enum string DISJOINT_PAIR_MESH = `{
  "vertices": [
    [0,0,0], [1,0,0], [2,0,0], [0,0,1], [1,0,1], [2,0,1]
  ],
  "faces": [
    [0,1,4,3],
    [1,2,5,4]
  ]
}`;

unittest { // BookEdgeNonManifoldExtrudeIsNoOp
    postLoadMesh(BOOK_MESH);

    auto before = getModel();
    assert(before["vertices"].array.length == 8, "BEFORE: expected 8 verts");
    assert(before["faces"].array.length == 3, "BEFORE: expected 3 faces");

    // Select page A (face 0) — touches the book edge (v0,v1), shared by 3 faces.
    postSelect("polygons", [0]);
    string raw = postCommandRaw(`{"id":"poly.extrude","params":{"distance":0.5}}`);

    auto after = getModel();
    // Strict no-op: exact same vertex/face arrays as the injected input —
    // the kernel must reject BEFORE emitting any geometry.
    assert(after["vertices"] == before["vertices"],
        "book-edge extrude: vertices must be byte-identical after reject, got: "
        ~ after["vertices"].toString);
    assert(after["faces"] == before["faces"],
        "book-edge extrude: faces must be byte-identical after reject, got: "
        ~ after["faces"].toString);
}

unittest { // DisjointPairStillExtrudesNormally
    postLoadMesh(DISJOINT_PAIR_MESH);

    auto before = getModel();
    size_t vertsBefore = before["vertices"].array.length;
    size_t facesBefore = before["faces"].array.length;
    assert(vertsBefore == 6, "BEFORE: expected 6 verts");
    assert(facesBefore == 2, "BEFORE: expected 2 faces");

    // Select both faces — a normal, fully-manifold adjacent pair; no book
    // edge anywhere in this mesh, so this must extrude exactly as before.
    postSelect("polygons", [0, 1]);
    auto resp = postJ("/api/command", `{"id":"poly.extrude","params":{"distance":0.4}}`);
    assert(resp["status"].str == "ok", "poly.extrude on disjoint pair failed: " ~ resp.toString);

    auto after = getModel();
    assert(after["vertices"].array.length > vertsBefore,
        "disjoint pair extrude: expected new verts, got same count " ~ vertsBefore.to!string);
    assert(after["faces"].array.length != facesBefore,
        "disjoint pair extrude: expected face count to change from " ~ facesBefore.to!string);
    assertManifoldClean(after, "DisjointPairStillExtrudesNormally");
}
