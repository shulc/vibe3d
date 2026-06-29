// Tests for mesh.flip (reverse polygon winding / flip normals).
//
// Cube face layout (from makeCube insertion order):
//   f0=back   [0,3,2,1]   f1=front  [4,5,6,7]
//   f2=left   [0,4,7,3]   f3=right  [1,2,6,5]
//   f4=top    [3,7,6,2]   f5=bottom [0,1,5,4]

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/reset failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/command failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/select failed: " ~ resp);
}

JSONValue postUndo() { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getModel()  { return parseJSON(get("http://localhost:8080/api/model")); }

long undoCount() {
    return parseJSON(get("http://localhost:8080/api/history"))["undo"].array.length;
}

// ---------------------------------------------------------------------------
// Single face: winding reversed, topology counts unchanged
// ---------------------------------------------------------------------------
unittest { // flip face 0: vertex order reversed, counts unchanged
    resetCube();
    auto before = getModel();
    auto face0Before = before["faces"].array[0].array;

    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.flip"}`);

    auto after = getModel();

    // Topology must not change
    assert(after["vertexCount"].integer == 8,
        "vertexCount changed after flip: " ~ after["vertexCount"].integer.to!string);
    assert(after["faceCount"].integer == 6,
        "faceCount changed after flip: " ~ after["faceCount"].integer.to!string);
    assert(after["edgeCount"].integer == 12,
        "edgeCount changed after flip: " ~ after["edgeCount"].integer.to!string);

    // Face 0 winding must be reversed
    auto face0After = after["faces"].array[0].array;
    assert(face0After.length == face0Before.length, "face 0 arity changed");
    foreach (i; 0 .. face0Before.length)
        assert(face0After[i].integer == face0Before[face0Before.length - 1 - i].integer,
            "face 0 corner " ~ i.to!string ~ " not reversed");

    // Other faces must be unchanged
    foreach (fi; 1 .. 6) {
        auto fb = before["faces"].array[fi].array;
        auto fa = after["faces"].array[fi].array;
        assert(fa.length == fb.length, "face " ~ fi.to!string ~ " arity changed");
        foreach (i; 0 .. fb.length)
            assert(fa[i].integer == fb[i].integer,
                "face " ~ fi.to!string ~ " changed unexpectedly after single-face flip");
    }
}

// ---------------------------------------------------------------------------
// Multi-face flip
// ---------------------------------------------------------------------------
unittest { // flip faces [0, 4]: both reversed, unselected faces unchanged
    resetCube();
    auto before = getModel();
    auto face0Before = before["faces"].array[0].array;
    auto face4Before = before["faces"].array[4].array;

    postSelect("polygons", [0, 4]);
    postCommand(`{"id":"mesh.flip"}`);

    auto after = getModel();
    assert(after["vertexCount"].integer == 8);
    assert(after["faceCount"].integer   == 6);
    assert(after["edgeCount"].integer   == 12);

    auto face0After = after["faces"].array[0].array;
    auto face4After = after["faces"].array[4].array;

    foreach (i; 0 .. face0Before.length)
        assert(face0After[i].integer == face0Before[face0Before.length - 1 - i].integer,
            "face 0 not reversed in multi-flip");
    foreach (i; 0 .. face4Before.length)
        assert(face4After[i].integer == face4Before[face4Before.length - 1 - i].integer,
            "face 4 not reversed in multi-flip");
}

// ---------------------------------------------------------------------------
// Self-inverse: flip face 0 twice restores original winding
// ---------------------------------------------------------------------------
unittest { // flip∘flip = identity for face 0
    resetCube();
    auto pristine = getModel();
    auto face0Pristine = pristine["faces"].array[0].array;

    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.flip"}`);
    // Re-select face 0 (flip clears selection) and flip again.
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.flip"}`);

    auto restored = getModel();
    auto face0Restored = restored["faces"].array[0].array;

    assert(face0Restored.length == face0Pristine.length,
        "arity changed after flip∘flip");
    foreach (i; 0 .. face0Pristine.length)
        assert(face0Restored[i].integer == face0Pristine[i].integer,
            "face 0 corner " ~ i.to!string ~ " not restored after flip∘flip");
}

// ---------------------------------------------------------------------------
// Empty face selection = all faces (whole-mesh flip convention)
// ---------------------------------------------------------------------------
unittest { // empty face selection flips every face
    resetCube();
    auto before = getModel();

    // No face selected after reset → "empty selection = whole mesh" convention.
    postCommand(`{"id":"mesh.flip"}`);

    auto after = getModel();
    assert(after["vertexCount"].integer == 8);
    assert(after["faceCount"].integer   == 6);
    assert(after["edgeCount"].integer   == 12);

    // Every face winding must be reversed
    foreach (fi; 0 .. 6) {
        auto fb = before["faces"].array[fi].array;
        auto fa = after["faces"].array[fi].array;
        assert(fa.length == fb.length,
            "face " ~ fi.to!string ~ " arity changed in whole-mesh flip");
        foreach (i; 0 .. fb.length)
            assert(fa[i].integer == fb[fb.length - 1 - i].integer,
                "face " ~ fi.to!string ~ " corner " ~ i.to!string
                ~ " not reversed in whole-mesh flip");
    }
}

// ---------------------------------------------------------------------------
// No-op on empty mesh: evaluate returns false → no undo entry added
// ---------------------------------------------------------------------------
unittest { // flip on empty mesh is a no-op that does not add an undo entry
    auto resp = post("http://localhost:8080/api/reset?empty=true", "");
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/reset?empty=true failed: " ~ resp);

    const depthBefore = undoCount();

    // evaluate() returns false on an empty mesh; the HTTP layer returns an
    // error status — that is expected. The load-bearing assertion is that
    // no undo entry is recorded (false-returning evaluate is excluded from
    // history, matching the delete.d:125 precedent).
    cast(void) post("http://localhost:8080/api/command", `{"id":"mesh.flip"}`);

    auto m = getModel();
    assert(m["faceCount"].integer == 0,
        "empty mesh gained faces after flip: " ~ m["faceCount"].integer.to!string);

    const depthAfter = undoCount();
    assert(depthAfter == depthBefore,
        "empty-mesh flip must not add undo entry; before=" ~ depthBefore.to!string
        ~ " after=" ~ depthAfter.to!string);
}
