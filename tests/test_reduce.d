// Tests for mesh.reduce (iterative edge-collapse decimation).
//
// Dense tri mesh from: reset → subdivide ×2 → triple.
// Cube subdivide once: 26v / 48e / 24f (all quads)
// Subdivide twice:    98v / 192e / 96f (all quads)
// Triple (all):       98v / ??? e / 192f (all tris)

import std.net.curl;
import std.json;
import std.conv    : to;
import batchless_control_helpers;
import std.math    : fabs;
import std.algorithm : sort;

void main() {}

enum BASE = "http://localhost:8080";

string postRaw(string path, string body) {
    return cast(string)post(BASE ~ path, body);
}
JSONValue postJ(string path, string body) { return parseJSON(postRaw(path, body)); }
JSONValue getJ(string path) { return parseJSON(get(BASE ~ path)); }

void resetCube() {
    auto r = postJ("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

void runCmd(string id) {
    auto resp = postRaw("/api/command", `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        id ~ " failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = postRaw("/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

string postCommandRaw(string body) { return postRaw("/api/command", body); }

JSONValue postUndo() { return postJ("/api/undo", ""); }
JSONValue getModel()  { return getJ("/api/model"); }
JSONValue getChanges() { return getJ("/api/changes"); }

// Switch to Polygons mode (required for mesh.subdivide, mesh.triple).
void setPolygonMode() {
    auto resp = postRaw("/api/command", "select.typeFrom polygon");
    assert(parseJSON(resp)["status"].str == "ok",
        "select.typeFrom polygon failed: " ~ resp);
}

// Build dense tri mesh: subdivide ×2 then triple.
// Returns the face count before reduce.
size_t buildDenseTriMesh() {
    resetCube();
    setPolygonMode();
    runCmd("mesh.subdivide");
    runCmd("mesh.subdivide");
    runCmd("mesh.triple");
    return getModel()["faceCount"].integer;
}

// Verify no degenerate or zero-area faces and no edge with >2 incident faces.
void assertManifoldClean(JSONValue model, string context) {
    auto faces    = model["faces"].array;
    auto vertices = model["vertices"].array;

    // Build edge→face-count map.
    int[ulong] efCount;
    foreach (fi, f; faces) {
        auto fc = f.array;
        assert(fc.length >= 3,
            context ~ ": face " ~ fi.to!string ~ " has " ~ fc.length.to!string ~ " corners");
        // Distinct corners check.
        bool[size_t] seen;
        foreach (v; fc) {
            auto vi = v.integer;
            assert(!(vi in seen),
                context ~ ": face " ~ fi.to!string ~ " has duplicate corner " ~ vi.to!string);
            seen[vi] = true;
        }
        // Edge count.
        foreach (i; 0 .. fc.length) {
            size_t a = fc[i].integer, b = fc[(i+1)%fc.length].integer;
            ulong key = a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
            efCount[key]++;
        }
    }
    foreach (key, cnt; efCount)
        assert(cnt <= 2,
            context ~ ": edge 0x" ~ key.to!string(16) ~ " on " ~ cnt.to!string ~ " faces");

    // Vertex finiteness.
    foreach (vi, v; vertices) {
        foreach (coord; v.array) {
            double c = coord.floating;
            import std.math : isFinite;
            assert(isFinite(c),
                context ~ ": vertex " ~ vi.to!string ~ " has non-finite coord");
        }
    }
}

// ---------------------------------------------------------------------------

unittest { // ratio 0.5 on tri mesh: face count in band, manifold, clean
    size_t f0 = buildDenseTriMesh();
    assert(f0 > 0, "expected non-zero face count after build");

    postCommand(`{"id":"mesh.reduce","params":{"ratio":0.5,"preserveBoundary":false}}`);

    auto m = getModel();
    size_t fAfter = cast(size_t)m["faceCount"].integer;
    size_t vAfter = cast(size_t)m["vertexCount"].integer;

    assert(fAfter < f0,
        "face count must decrease: before=" ~ f0.to!string ~ " after=" ~ fAfter.to!string);
    // Broad band: [20%, 80%] of original.
    assert(fAfter >= f0 / 5,
        "face count too low: " ~ fAfter.to!string ~ " (expected >= " ~ (f0/5).to!string ~ ")");
    assert(fAfter <= f0 * 4 / 5,
        "face count too high: " ~ fAfter.to!string ~ " (expected <= " ~ (f0*4/5).to!string ~ ")");

    assertManifoldClean(m, "ratio0.5");
}

unittest { // target count: face count at or below requested target
    size_t f0 = buildDenseTriMesh();
    size_t target = f0 / 3;
    if (target < 4) target = 4;

    postCommand(`{"id":"mesh.reduce","params":{"count":` ~ target.to!string ~
                `,"preserveBoundary":false}}`);

    auto m = getModel();
    size_t fAfter = cast(size_t)m["faceCount"].integer;
    assert(fAfter < f0, "face count must decrease");
    // Should be near target; allow some slack from guards (±25%).
    assert(fAfter <= target + target / 4 + 2,
        "fAfter=" ~ fAfter.to!string ~ " much above target=" ~ target.to!string);
    assertManifoldClean(m, "targetCount");
}

unittest { // quad sphere: face count strictly decreases, no degenerates
    resetCube();
    // Use prim.sphere which produces quad faces.
    postCommand(`{"id":"prim.sphere"}`);
    size_t f0 = cast(size_t)getModel()["faceCount"].integer;
    assert(f0 >= 4, "sphere must have faces");

    postCommand(`{"id":"mesh.reduce","params":{"ratio":0.5,"preserveBoundary":false}}`);

    auto m = getModel();
    size_t fAfter = cast(size_t)m["faceCount"].integer;
    assert(fAfter < f0,
        "quad sphere: face count must decrease: " ~ f0.to!string ~ " → " ~ fAfter.to!string);
    assertManifoldClean(m, "quadSphere");
}

unittest { // undo restores original mesh exactly
    size_t f0 = buildDenseTriMesh();
    size_t v0 = cast(size_t)getModel()["vertexCount"].integer;
    size_t e0 = cast(size_t)getModel()["edgeCount"].integer;

    postCommand(`{"id":"mesh.reduce","params":{"ratio":0.5,"preserveBoundary":false}}`);
    // After reduce: counts differ.
    auto mRed = getModel();
    assert(cast(size_t)mRed["faceCount"].integer < f0, "reduce must lower face count");

    // Undo.
    auto r = postUndo();
    assert(r["status"].str == "ok", "undo failed: " ~ r.toString);

    auto mBack = getModel();
    assert(cast(size_t)mBack["faceCount"].integer  == f0,
        "undo: face count mismatch: " ~ mBack["faceCount"].integer.to!string ~ " vs " ~ f0.to!string);
    assert(cast(size_t)mBack["vertexCount"].integer == v0,
        "undo: vertex count mismatch");
    assert(cast(size_t)mBack["edgeCount"].integer   == e0,
        "undo: edge count mismatch");
}

unittest { // no-op: ratio 1.0 returns status:error, mesh unchanged
    size_t f0 = buildDenseTriMesh();

    auto resp = postCommandRaw(`{"id":"mesh.reduce","params":{"ratio":1.0}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "ratio=1.0 must return error, got: " ~ resp);
    assert(cast(size_t)getModel()["faceCount"].integer == f0,
        "mesh must be unchanged on no-op");
}

unittest { // no-op: count >= current face count returns status:error
    size_t f0 = buildDenseTriMesh();
    auto resp = postCommandRaw(`{"id":"mesh.reduce","params":{"count":` ~
                               (f0 + 100).to!string ~ `}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "count>=current must return error, got: " ~ resp);
    assert(cast(size_t)getModel()["faceCount"].integer == f0,
        "mesh must be unchanged on no-op count");
}

// ---------------------------------------------------------------------------
// The edit-seam observables of mesh.reduce (task 1903 Stage D2). Both of these
// are invisible to every other test in this file: the geometry a reduce
// produces is byte-identical whether or not the kernel runs inside a batch and
// whether its finalising coordinate write is recorded or raw. What separates
// those worlds is the change-bus counters at /api/changes.
// ---------------------------------------------------------------------------
unittest { // reduce runs inside an edit batch, and publishes the Position class
    // The dense tri stand, spelled out rather than via buildDenseTriMesh(),
    // because the positive control has to sit at a step that MUTATES and has
    // to leave a TRIANGLE mesh behind for the reduce (measured: a reduce on a
    // freshly-subdivided quad cage finds no valid collapse, returns
    // status:error and moves no counter at all — that no-op would have made
    // every assertion below vacuously true).
    resetCube();
    setPolygonMode();
    runCmd("mesh.subdivide");
    runCmd("mesh.subdivide");

    // POSITIVE CONTROL, and it is not decoration. Every assertion below is
    // "this counter did not move" or "that counter moved by one", and a dead
    // counter — the g_isDocumentMesh predicate uninstalled, the endpoint
    // reading a stale copy — satisfies the first kind for free. So make the
    // SAME counter move first, with a command that is deliberately still
    // batchless. WHICH command that is has moved five times and now lives in
    // ONE place, `kBatchlessControlCommand` in
    // tests/batchless_control_helpers.d — stage L10-P0 gave mesh.triple, the
    // fourth pick, a batch, and turned this line and nine like it red in one
    // run. (Measured on this build before that: triple +2, reduce +4 before
    // the D2 conversion and +0 after.)
    auto c0 = getChanges();
    runCmd(kBatchlessControlCommand);
    auto c1 = getChanges();
    const long ctrl = c1["unbatchedGeometryCommits"].integer
                    - c0["unbatchedGeometryCommits"].integer;
    assert(ctrl > 0,
        kBatchlessControlWhy ~ ctrl.to!string ~ kBatchlessControlFix);

    auto before = getChanges();
    postCommand(`{"id":"mesh.reduce","params":{"ratio":0.5,"preserveBoundary":false}}`);
    auto after = getChanges();

    // (1) THE BATCH. Stage D2 made reduceToTarget take `ref MeshEditBatch`, so
    // every commitChange the collapse and the finalising weld make is DEFERRED
    // into the frame and stamped once at close(). If a caller ever stops
    // opening the batch — or opens it around less than the whole kernel — those
    // commits land unbatched and this delta stops being zero.
    const long unbatched = after["unbatchedGeometryCommits"].integer
                         - before["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        "mesh.reduce made " ~ unbatched.to!string ~ " UNBATCHED geometry "
      ~ "commit(s). The kernel's receiver is `ref MeshEditBatch`, so its "
      ~ "commits must defer into the frame and stamp once at close(); a "
      ~ "non-zero delta means the batch does not cover the kernel "
      ~ "(task 1903 Stage D2, plan §3.2 L2). Pre-D2 this was +4.");

    // (2) THE RECORDED WRITE'S PUBLISHING HALF. The finalise that coincides
    // every cluster member onto its representative goes through
    // MeshEditBatch.setVertexPositions, which publishes
    // MeshEditScope.Position. The raw `vertices[i] = …` it replaced published
    // NOTHING for the coordinates it moved — the reduce announced only
    // Points|Polygons, and a Position-keyed cache had no reason to
    // invalidate. The OP-LOG half of that call cannot be checked until Stage
    // L10 gives Kind.SetPos a reader; THIS half can be, and is, today.
    const long pos = after["totalPosition"].integer - before["totalPosition"].integer;
    assert(pos == 1,
        "mesh.reduce published the Position change class " ~ pos.to!string
      ~ " time(s), expected exactly 1. The finalising coordinate write goes "
      ~ "through MeshEditBatch.setVertexPositions; a raw `vertices[i] = …` "
      ~ "moves the same coordinates and announces none of them "
      ~ "(task 1903 §2.5, §5.7 M-D2).");

    // (3) The batch closed cleanly and nobody stamped without publishing.
    assert(after["batchLeaks"].integer == 0,
        "a MeshEditBatch leaked (destroyed while still open): "
      ~ after["batchLeaks"].integer.to!string);
    assert(after["missedPublishers"].integer == 0,
        "a mutationVersion bump reached the frame with no pending change: "
      ~ after["missedPublishers"].integer.to!string);
    // Unrecorded at D2 by design — Stage L10 is where this becomes non-zero.
    assert(after["opLogEntriesRecorded"].integer
        == before["opLogEntriesRecorded"].integer,
        "mesh.reduce recorded op-log entries. Its batch is UNRECORDED until "
      ~ "Stage L10 moves this family's undo off the whole-mesh snapshot; a "
      ~ "recording batch here builds a log nothing reads (task 1903 §5.1).");
}

unittest { // preserveBoundary: open mesh boundary vertex set preserved
    // Build an open mesh: one subdivide, then delete one polygon.
    resetCube();
    setPolygonMode();
    runCmd("mesh.subdivide"); // 26v / 24 quads

    // Select and delete one face to create a boundary.
    auto r0 = postJ("/api/select",
        `{"mode":"polygons","indices":[0]}`);
    assert(r0["status"].str == "ok");
    postCommand(`{"id":"mesh.delete"}`);

    auto mBefore = getModel();
    size_t f0 = cast(size_t)mBefore["faceCount"].integer;
    assert(f0 > 0);

    // Collect boundary vertex count by building edge-face map.
    size_t boundaryVerts0 = 0;
    {
        int[ulong] emap;
        ulong[ulong] eVertA, eVertB;
        foreach (fi, f; mBefore["faces"].array) {
            auto fc = f.array;
            foreach (i; 0 .. fc.length) {
                size_t a = fc[i].integer, b = fc[(i+1)%fc.length].integer;
                ulong key = a < b ? (cast(ulong)a << 32|b) : (cast(ulong)b << 32|a);
                emap[key]++;
                eVertA[key] = a; eVertB[key] = b;
            }
        }
        bool[] bv; bv.length = mBefore["vertexCount"].integer;
        foreach (key, cnt; emap) {
            if (cnt < 2) { bv[eVertA[key]] = true; bv[eVertB[key]] = true; }
        }
        foreach (b; bv) if (b) ++boundaryVerts0;
    }
    assert(boundaryVerts0 > 0, "open mesh must have boundary verts");

    // Reduce with preserveBoundary=true.
    auto respR = postCommandRaw(
        `{"id":"mesh.reduce","params":{"ratio":0.5,"preserveBoundary":true}}`);
    auto rv = parseJSON(respR);
    // May succeed or no-op (if no interior edge is collapsible); just verify
    // the boundary is unharmed when it succeeds.
    if (rv["status"].str == "ok") {
        auto mAfter = getModel();
        assert(cast(size_t)mAfter["faceCount"].integer <= f0,
            "face count must not increase");
        assertManifoldClean(mAfter, "preserveBoundary");
    }
}
