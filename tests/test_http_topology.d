// Contract test: GET /api/model emits stable edge/face connectivity, and that
// connectivity is BYTE-STABLE across a vertex move.
//
// Downstream consumers resolve a bare edge/face *selection index* against the
// emitted `edges` / `faces` arrays to recover the affected vertex set. That
// only works if:
//   • `edges` is a list of 2-int vertex-index pairs, every index < vertexCount;
//   • `faces` is a list of vertex-index lists, every index < vertexCount;
//   • both arrays are IDENTICAL before and after a `/api/transform {translate}`
//     — a translate mutates `vertices`, never the topology arrays.
//
// The last invariant is the load-bearing one: any future refactor that rebuilt
// or reordered the topology on a vertex move would silently break index-based
// selection resolution. This test pins it.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

unittest { // /api/model emits in-range edges + faces; both stable under a move
    // Reset to the pristine startup cube (the runner shares one vibe3d per
    // worker across tests — without this the asserted mesh could be stale).
    post("http://localhost:8080/api/reset", "");

    auto before = getModel();

    assert("vertexCount" in before, "Missing vertexCount field");
    assert("edges" in before, "Missing edges field");
    assert("faces" in before, "Missing faces field");

    immutable long vertexCount = before["vertexCount"].integer;
    assert(vertexCount > 0, "vertexCount should be positive");

    // --- edges: 2-int vertex-index pairs, all in range -----------------------
    auto edges = before["edges"];
    assert(edges.type == JSONType.ARRAY, "edges should be an array");
    if ("edgeCount" in before)
        assert(edges.array.length == before["edgeCount"].integer,
            "edges length should equal edgeCount");
    foreach (i, e; edges.array) {
        assert(e.array.length == 2,
            "edge " ~ to!string(i) ~ " should be a 2-int pair");
        foreach (j, idx; e.array) {
            assert(idx.type == JSONType.INTEGER,
                "edge " ~ to!string(i) ~ " endpoint " ~ to!string(j)
                ~ " should be an integer index");
            assert(idx.integer >= 0 && idx.integer < vertexCount,
                "edge " ~ to!string(i) ~ " endpoint out of range: "
                ~ to!string(idx.integer));
        }
    }

    // --- faces: vertex-index lists, all in range -----------------------------
    auto faces = before["faces"];
    assert(faces.type == JSONType.ARRAY, "faces should be an array");
    if ("faceCount" in before)
        assert(faces.array.length == before["faceCount"].integer,
            "faces length should equal faceCount");
    foreach (i, f; faces.array) {
        assert(f.array.length >= 3,
            "face " ~ to!string(i) ~ " should have at least 3 vertices");
        foreach (j, idx; f.array) {
            assert(idx.type == JSONType.INTEGER,
                "face " ~ to!string(i) ~ " vertex " ~ to!string(j)
                ~ " should be an integer index");
            assert(idx.integer >= 0 && idx.integer < vertexCount,
                "face " ~ to!string(i) ~ " vertex out of range: "
                ~ to!string(idx.integer));
        }
    }

    // --- topology BYTE-STABLE across a vertex move ---------------------------
    // Select a vertex and translate it. The vertices change; the edge/face
    // index arrays must be byte-identical (toString comparison).
    auto sel = post("http://localhost:8080/api/select",
        `{"mode":"vertices","indices":[0]}`);
    assert(parseJSON(sel)["status"].str == "ok", "/api/select failed: " ~ sel);

    auto xf = post("http://localhost:8080/api/transform",
        `{"kind":"translate","delta":[1.0,0.5,-0.25]}`);
    assert(parseJSON(xf)["status"].str == "ok", "/api/transform failed: " ~ xf);

    auto after = getModel();

    // Sanity: the moved vertex actually moved (so we know the translate ran).
    auto v0Before = before["vertices"].array[0].array;
    auto v0After = after["vertices"].array[0].array;
    assert(v0Before[0].floating != v0After[0].floating
        || v0Before[1].floating != v0After[1].floating
        || v0Before[2].floating != v0After[2].floating,
        "vertex 0 should have moved after translate");

    // The load-bearing invariant: topology arrays unchanged byte-for-byte.
    assert(after["edges"].toString() == before["edges"].toString(),
        "edges array changed across a vertex move (topology must be stable)");
    assert(after["faces"].toString() == before["faces"].toString(),
        "faces array changed across a vertex move (topology must be stable)");
}
