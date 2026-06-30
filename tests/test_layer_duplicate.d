// HTTP test suite for `layer.duplicate` (task 0122).
//
// Pure command-dispatch test — no event playback, no GL. Every assertion is
// read back over /api/layers and /api/model?layer=N so the test is headless
// and deterministic.
//
// Cases:
//   1. count + primary flags after duplicate
//   2. clone name == source.name ~ " copy"
//   3. geometry equality (clone == source vertex-for-vertex within 1e-4)
//   4. deep-copy independence (editing the active clone leaves source unchanged)
//   5. undo restores 1 layer + prior primary; redo re-applies

import std.net.curl;
import std.json;
import std.conv    : to;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP helpers (same patterns as test_layers.d)
// ---------------------------------------------------------------------------

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue cmdJson(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    clearHistory();
}

void clearHistory() {
    cmdJson(`{"id":"history.clear"}`);
}

JSONValue postUndo() {
    return parseJSON(cast(string)post(baseUrl ~ "/api/undo", ""));
}

JSONValue postRedo() {
    return parseJSON(cast(string)post(baseUrl ~ "/api/redo", ""));
}

JSONValue getLayers()              { return getJson("/api/layers"); }
JSONValue getModelLayer(int layer) { return getJson("/api/model?layer=" ~ layer.to!string); }

size_t layerCount()  { return getLayers()["layers"].array.length; }
size_t activeLayer() { return cast(size_t)getLayers()["active"].integer; }

size_t vertCount(int layer) {
    return getModelLayer(layer)["vertices"].array.length;
}

double[3] vertexAt(int layer, int idx) {
    auto v = getModelLayer(layer)["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

bool approx(double a, double b) {
    auto d = a - b;
    return (d < 0 ? -d : d) < 1e-4;
}

// Index of the first vertex in `layer` whose x is approximately `x`, or -1.
int vIndexNear(int layer, double x) {
    auto verts = getModelLayer(layer)["vertices"].array;
    foreach (i, v; verts)
        if (approx(v.array[0].floating, x)) return cast(int)i;
    return -1;
}

// Move the vertex at `from` to `to` on the ACTIVE layer (mesh.move_vertex).
void moveVertexActive(double[3] from, double[3] to) {
    string v3(double[3] p) {
        return "[" ~ p[0].to!string ~ "," ~ p[1].to!string ~ "," ~ p[2].to!string ~ "]";
    }
    cmdJson(`{"id":"mesh.move_vertex","params":{"from":` ~ v3(from)
            ~ `,"to":` ~ v3(to) ~ `}}`);
}

// ---------------------------------------------------------------------------
// 1. count + primary flags
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmdJson(`{"id":"layer.duplicate"}`);

    assert(layerCount() == 2,
           "after duplicate: expected 2 layers, got " ~ layerCount().to!string);
    assert(activeLayer() == 1,
           "after duplicate: active must be 1 (the clone), got "
           ~ activeLayer().to!string);

    auto layers = getLayers()["layers"].array;

    // Clone (layer 1): primary, selected, visible, not background.
    assert(layers[1]["primary"].type  == JSONType.true_,
           "clone must be primary");
    assert(layers[1]["selected"].type == JSONType.true_,
           "clone must be selected");
    assert(layers[1]["visible"].type  == JSONType.true_,
           "clone must be visible");

    // Source (layer 0): not primary, not selected, visible → background (derived).
    assert(layers[0]["primary"].type  == JSONType.false_,
           "source must NOT be primary after duplicate");
    assert(layers[0]["selected"].type == JSONType.false_,
           "source must NOT be selected after duplicate");
    assert(layers[0]["background"].type == JSONType.true_,
           "source must be background (visible && !selected)");
}

// ---------------------------------------------------------------------------
// 2. clone name == source.name ~ " copy"
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto srcName = getLayers()["layers"].array[0]["name"].str;
    cmdJson(`{"id":"layer.duplicate"}`);

    auto layers = getLayers()["layers"].array;
    assert(layers[0]["name"].str == srcName,
           "source name must be unchanged");
    assert(layers[1]["name"].str == srcName ~ " copy",
           "clone name must be source.name ~ ' copy', got '"
           ~ layers[1]["name"].str ~ "'");
}

// ---------------------------------------------------------------------------
// 3. geometry equality — clone vertices match source vertex-for-vertex
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmdJson(`{"id":"layer.duplicate"}`);

    size_t nv = vertCount(0);
    assert(vertCount(1) == nv,
           "clone must have the same vertex count as source, expected "
           ~ nv.to!string ~ " got " ~ vertCount(1).to!string);

    foreach (i; 0 .. cast(int)nv) {
        auto v0 = vertexAt(0, i);
        auto v1 = vertexAt(1, i);
        foreach (k; 0 .. 3)
            assert(approx(v0[k], v1[k]),
                   "vertex " ~ i.to!string ~ " component " ~ k.to!string
                   ~ ": source=" ~ v0[k].to!string
                   ~ " clone=" ~ v1[k].to!string);
    }
}

// ---------------------------------------------------------------------------
// 4. deep-copy independence — editing the active clone leaves source unchanged
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmdJson(`{"id":"layer.duplicate"}`);
    // Active layer is now the clone (layer 1). Move a vertex on it.
    moveVertexActive([-0.5, -0.5, -0.5], [99.0, -0.5, -0.5]);

    // Clone (layer 1) must have the moved vertex.
    assert(vIndexNear(1, 99.0) >= 0,
           "clone (layer 1) must have a vertex near x=99 after edit");

    // Source (layer 0) must be completely untouched.
    assert(vIndexNear(0, 99.0) < 0,
           "source (layer 0) must NOT have a vertex near x=99 (deep-copy independence)");
    assert(vIndexNear(0, -0.5) >= 0,
           "source (layer 0) must still have the original vertex near x=-0.5");
}

// ---------------------------------------------------------------------------
// 5. undo restores 1 layer + prior primary; redo re-applies
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmdJson(`{"id":"layer.duplicate"}`);
    assert(layerCount() == 2, "pre-undo: expected 2 layers");

    // Undo the duplicate.
    auto u = postUndo();
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(layerCount() == 1,
           "post-undo: expected 1 layer, got " ~ layerCount().to!string);
    assert(activeLayer() == 0,
           "post-undo: active must be 0 (original source), got "
           ~ activeLayer().to!string);
    {
        auto layers = getLayers()["layers"].array;
        assert(layers[0]["primary"].type  == JSONType.true_,
               "post-undo: layer 0 must be primary");
        assert(layers[0]["selected"].type == JSONType.true_,
               "post-undo: layer 0 must be selected");
    }

    // Redo re-applies: 2 layers again with the clone as primary.
    auto r = postRedo();
    assert(r["status"].str == "ok", "redo must succeed: " ~ r.toString);
    assert(layerCount() == 2,
           "post-redo: expected 2 layers, got " ~ layerCount().to!string);
    assert(activeLayer() == 1,
           "post-redo: active must be 1 (clone), got " ~ activeLayer().to!string);
    {
        auto layers = getLayers()["layers"].array;
        assert(layers[1]["primary"].type  == JSONType.true_,
               "post-redo: layer 1 must be primary");
        assert(layers[1]["selected"].type == JSONType.true_,
               "post-redo: layer 1 must be selected");
    }
}
