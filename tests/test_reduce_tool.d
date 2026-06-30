// Tests for mesh.reduceTool — interactive reduction tool wrapping reduceToTarget.
// Drives the headless path: tool.set / tool.attr / tool.doApply.
// Helpers are a local copy of the 0109 test's buildDenseTriMesh / assertManifoldClean.

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

void resetCube() {
    auto r = postJ("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

void runCmd(string id) {
    auto resp = postRaw("/api/command", `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(resp)["status"].str == "ok", id ~ " failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = postRaw("/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

string postCommandRaw(string body) { return postRaw("/api/command", body); }

JSONValue postUndo() { return postJ("/api/undo", ""); }
JSONValue getModel()  { return getJ("/api/model"); }

void setPolygonMode() {
    auto resp = postRaw("/api/command", "select.typeFrom polygon");
    assert(parseJSON(resp)["status"].str == "ok",
        "select.typeFrom polygon failed: " ~ resp);
}

/// Build dense tri mesh: reset → subdivide ×2 → triple ≈ 192 tri faces.
/// Returns the face count before reduction.
size_t buildDenseTriMesh() {
    resetCube();
    setPolygonMode();
    runCmd("mesh.subdivide");
    runCmd("mesh.subdivide");
    runCmd("mesh.triple");
    return cast(size_t)getModel()["faceCount"].integer;
}

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

unittest { // headless apply: ratio 0.5 reduces face count into expected band + manifold
    size_t f0 = buildDenseTriMesh();
    assert(f0 > 0, "expected non-zero face count after build");

    postCommand("tool.set mesh.reduceTool on");
    postCommand("tool.attr mesh.reduceTool ratio 0.5");
    postCommand("tool.attr mesh.reduceTool preserveBoundary false");
    postCommand("tool.doApply");
    postCommand("tool.set mesh.reduceTool off");

    auto m = getModel();
    size_t fAfter = cast(size_t)m["faceCount"].integer;

    assert(fAfter < f0,
        "face count must decrease: before=" ~ f0.to!string ~ " after=" ~ fAfter.to!string);
    assert(fAfter >= f0 / 5,
        "face count too low: " ~ fAfter.to!string ~ " (expected >= " ~ (f0 / 5).to!string ~ ")");
    assert(fAfter <= f0 * 4 / 5,
        "face count too high: " ~ fAfter.to!string ~ " (expected <= " ~ (f0 * 4 / 5).to!string ~ ")");

    assertManifoldClean(m, "reduceTool-ratio0.5");
}

unittest { // undo restores original mesh exactly
    size_t f0 = buildDenseTriMesh();
    size_t v0 = cast(size_t)getModel()["vertexCount"].integer;
    size_t e0 = cast(size_t)getModel()["edgeCount"].integer;

    postCommand("tool.set mesh.reduceTool on");
    postCommand("tool.attr mesh.reduceTool ratio 0.5");
    postCommand("tool.attr mesh.reduceTool preserveBoundary false");
    postCommand("tool.doApply");
    postCommand("tool.set mesh.reduceTool off");

    auto mRed = getModel();
    assert(cast(size_t)mRed["faceCount"].integer < f0,
        "tool must lower face count before undo");

    auto r = postUndo();
    assert(r["status"].str == "ok", "undo failed: " ~ r.toString);

    auto mBack = getModel();
    assert(cast(size_t)mBack["faceCount"].integer  == f0,  "undo: face count mismatch");
    assert(cast(size_t)mBack["vertexCount"].integer == v0, "undo: vertex count mismatch");
    assert(cast(size_t)mBack["edgeCount"].integer   == e0, "undo: edge count mismatch");
}

unittest { // no-op: ratio 1.0 → status:error + mesh unchanged
    size_t f0 = buildDenseTriMesh();

    postCommand("tool.set mesh.reduceTool on");
    postCommand("tool.attr mesh.reduceTool ratio 1.0");
    auto resp = postCommandRaw("tool.doApply");
    assert(parseJSON(resp)["status"].str == "error",
        "ratio=1.0 must return error, got: " ~ resp);
    assert(cast(size_t)getModel()["faceCount"].integer == f0,
        "mesh must be unchanged on no-op");

    postCommand("tool.set mesh.reduceTool off");
}
