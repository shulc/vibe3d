// Tests for poly.unify and mesh.cleanup.
//
// Dirty mesh geometry is injected via /api/load-mesh.  The loader
// (commands/scene/load_mesh.d) validates that every face has ≥3 entries and
// all vertex indices are in range, so literal 2-vertex faces cannot be
// injected here.  Degenerate faces are expressed as:
//   - 3-entry faces with <3 DISTINCT vertices  (e.g. [0,1,1])
//   - zero-area triangles (three collinear points)
// Both pass the loader's entry-count check but are caught by cleanDegenerateFaces.
// Literal 2-vertex faces are exercised only in the mesh.d dub unittests.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

void postReset() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postLoadMesh(string body) {
    auto resp = post("http://localhost:8080/api/load-mesh", body);
    assert(parseJSON(resp)["status"].str == "ok",
           "/api/load-mesh failed: " ~ resp);
}

JSONValue postCommandRaw(string body) {
    return parseJSON(post("http://localhost:8080/api/command", body));
}

void postCommand(string body) {
    auto r = postCommandRaw(body);
    assert(r["status"].str == "ok", "command failed: " ~ r.toString);
}

JSONValue postUndo() {
    return parseJSON(post("http://localhost:8080/api/undo", ""));
}

JSONValue getModel() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

long undoCount() {
    return parseJSON(get("http://localhost:8080/api/history"))["undo"].array.length;
}

// ---------------------------------------------------------------------------
// poly.unify: standalone face-dedup
// ---------------------------------------------------------------------------

unittest { // duplicate face removed; undo restores it
    postReset();
    // Mesh: 4 vertices, a quad face listed twice (same unordered vertex set).
    // The loader accepts both because both have ≥3 entries and valid indices.
    postLoadMesh(`{
        "vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],
        "faces":[[0,1,2,3],[0,1,2,3]]
    }`);

    auto before = getModel();
    assert(before["faceCount"].integer == 2, "fixture: expected 2 faces");

    postCommand(`{"id":"poly.unify"}`);

    auto after = getModel();
    assert(after["faceCount"].integer == 1,
        "poly.unify: expected 1 face, got " ~ after["faceCount"].integer.to!string);
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
        "poly.unify: vertex count must not change");

    // Undo restores the original 2 faces.
    postUndo();
    auto undone = getModel();
    assert(undone["faceCount"].integer == 2,
        "undo: expected 2 faces restored, got " ~ undone["faceCount"].integer.to!string);
}

unittest { // reversed-winding duplicate is treated as a match
    postReset();
    // Two faces with the same vertex set but opposite winding.
    postLoadMesh(`{
        "vertices":[[0,0,0],[1,0,0],[0,1,0]],
        "faces":[[0,1,2],[2,1,0]]
    }`);
    assert(getModel()["faceCount"].integer == 2, "fixture: 2 faces");

    postCommand(`{"id":"poly.unify"}`);

    assert(getModel()["faceCount"].integer == 1,
        "reversed-winding dup must be removed");
}

unittest { // poly.unify no-op on clean mesh: false evaluate → no undo entry
    postReset();
    // Default cube has no duplicate faces — poly.unify is a no-op.
    const depthBefore = undoCount();
    // false-returning evaluate causes /api/command to return {"status":"error"};
    // ignore the response, the load-bearing check is the undo depth.
    cast(void) post("http://localhost:8080/api/command", `{"id":"poly.unify"}`);
    assert(undoCount() == depthBefore,
        "no-op poly.unify must not add undo entry");
}

// ---------------------------------------------------------------------------
// mesh.cleanup: full sweep with param toggles
// ---------------------------------------------------------------------------

/// Dirty mesh fixture used by several cleanup tests.
/// Layout (9 vertices, 4 faces):
///   verts 0-3: quad positions  (0,0,0)-(1,0,0)-(1,1,0)-(0,1,0)
///   vert 4:    (0.5,0,0) — used in zero-area triangle [0,4,1] (collinear)
///   vert 5:    (0,0,0)   — coincident with vert 0; in face [5,6,7]
///   verts 6-7: (2,0,0),(2,1,0) — valid triangle partner of vert 5
///   vert 8:    (9,9,9)   — pure orphan (not in any face)
///   faces: [0,1,2,3], [0,1,2,3] (dup), [0,4,1] (collinear/zero-area), [5,6,7]
string dirtyMeshFixture() {
    return `{
        "vertices":[
            [0,0,0],[1,0,0],[1,1,0],[0,1,0],
            [0.5,0,0],
            [0,0,0],
            [2,0,0],[2,1,0],
            [9,9,9]
        ],
        "faces":[
            [0,1,2,3],
            [0,1,2,3],
            [0,4,1],
            [5,6,7]
        ]
    }`;
}

unittest { // mesh.cleanup defaults: all stages fire, final counts correct
    postReset();
    postLoadMesh(dirtyMeshFixture());

    auto before = getModel();
    assert(before["vertexCount"].integer == 9, "fixture: 9 verts");
    assert(before["faceCount"].integer   == 4, "fixture: 4 faces");

    postCommand(`{"id":"mesh.cleanup"}`);

    auto after = getModel();
    // Surviving geometry: verts {0,1,2,3,6,7}, faces [0,1,2,3] and [0,6,7]
    assert(after["faceCount"].integer   == 2,
        "cleanup: expected 2 faces, got "   ~ after["faceCount"].integer.to!string);
    assert(after["vertexCount"].integer == 6,
        "cleanup: expected 6 verts, got "   ~ after["vertexCount"].integer.to!string);
}

unittest { // mesh.cleanup undo: restores original dirty mesh
    postReset();
    postLoadMesh(dirtyMeshFixture());

    postCommand(`{"id":"mesh.cleanup"}`);
    assert(getModel()["faceCount"].integer == 2, "post-cleanup: 2 faces");

    postUndo();
    auto undone = getModel();
    assert(undone["vertexCount"].integer == 9,
        "undo: expected 9 verts, got " ~ undone["vertexCount"].integer.to!string);
    assert(undone["faceCount"].integer == 4,
        "undo: expected 4 faces, got " ~ undone["faceCount"].integer.to!string);
}

unittest { // weld-creates-a-duplicate order guard
    // Coincident verts A(0) and B(3) plus faces [0,1,2] and [3,1,2].
    // With correct order (weld-before-unify): B→A, both faces become [0,1,2],
    // unifyFaces removes the dup → 1 face.
    // Wrong order (unify-before-weld): dup survives (looked distinct pre-weld).
    postReset();
    postLoadMesh(`{
        "vertices":[[0,0,0],[1,0,0],[0,1,0],[0,0,0]],
        "faces":[[0,1,2],[3,1,2]]
    }`);
    assert(getModel()["faceCount"].integer == 2, "fixture: 2 faces");

    postCommand(`{"id":"mesh.cleanup"}`);

    auto after = getModel();
    assert(after["faceCount"].integer == 1,
        "weld-dup: expected 1 face after cleanup, got " ~
        after["faceCount"].integer.to!string);
    assert(after["vertexCount"].integer == 3,
        "weld-dup: expected 3 verts, got " ~
        after["vertexCount"].integer.to!string);
}

unittest { // mergeVerts toggle: OFF leaves coincident verts unwelded
    postReset();
    // Use the full dirty fixture (degenerate + duplicate + coincident vert 5 ≡ vert 0).
    // With mergeVerts:false, vert 5 is NOT welded to vert 0, so 7 verts survive
    // (default run welded 5→0 and got 6).  The degenerate + dup are still cleaned.
    postLoadMesh(dirtyMeshFixture());
    postCommand(`{"id":"mesh.cleanup","params":{"mergeVerts":false}}`);
    auto after = getModel();
    // Vert 5 (coincident with 0) survives → 7 verts: {0,1,2,3,5,6,7}.
    // Faces: [0,1,2,3] and [5,6,7] (degenerate + dup cleaned; no weld rename).
    assert(after["vertexCount"].integer == 7,
        "mergeVerts:false must leave coincident vert in place; got " ~
        after["vertexCount"].integer.to!string);
    assert(after["faceCount"].integer == 2,
        "degenerate + dup still cleaned with mergeVerts:false; got " ~
        after["faceCount"].integer.to!string);
}

unittest { // dist widening: near-but-not-coincident verts welded with larger eps
    postReset();
    // Two verts 0.001 apart (beyond the default 1e-5 eps, within a 0.01 eps).
    postLoadMesh(`{
        "vertices":[[0,0,0],[0.001,0,0],[1,0,0],[0,1,0]],
        "faces":[[0,2,3],[1,2,3]]
    }`);
    // Default dist 1e-5: verts 0 and 1 are 0.001 apart → NOT welded → no-op.
    cast(void) post("http://localhost:8080/api/command", `{"id":"mesh.cleanup"}`);
    assert(getModel()["faceCount"].integer == 2,
        "default dist must not weld near-but-not-coincident verts (contrast case)");

    postReset();
    postLoadMesh(`{
        "vertices":[[0,0,0],[0.001,0,0],[1,0,0],[0,1,0]],
        "faces":[[0,2,3],[1,2,3]]
    }`);
    // dist=0.01: weld threshold 0.01 > 0.001 → verts 0,1 welded → dup face removed.
    postCommand(`{"id":"mesh.cleanup","params":{"dist":0.01}}`);
    auto afterWide = getModel();
    assert(afterWide["faceCount"].integer < 2,
        "wider dist must weld near-coincident verts and remove dup face; got " ~
        afterWide["faceCount"].integer.to!string);
}

unittest { // degenerate face [0,1,1] injected and removed
    postReset();
    // face [0,1,1]: 3 entries (loader accepts it), but <3 distinct verts.
    // Plus a valid quad so the mesh is non-trivial after cleanup.
    postLoadMesh(`{
        "vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],
        "faces":[[0,1,2,3],[0,1,1]]
    }`);
    assert(getModel()["faceCount"].integer == 2, "fixture: 2 faces");

    postCommand(`{"id":"mesh.cleanup"}`);

    assert(getModel()["faceCount"].integer == 1,
        "degenerate [0,1,1] must be removed by cleanup");
}

unittest { // mesh.cleanup no-op on clean cube: false evaluate → no undo entry
    postReset();
    // The default cube has 8 verts 1 unit apart (>> 1e-5 weld eps), no
    // degenerate faces, no duplicates → cleanup is a no-op.
    const depthBefore = undoCount();
    // false-returning evaluate → /api/command returns {"status":"error"};
    // ignore the response body, assert undo depth is unchanged.
    cast(void) post("http://localhost:8080/api/command", `{"id":"mesh.cleanup"}`);
    assert(undoCount() == depthBefore,
        "no-op cleanup on clean cube must not add undo entry");
}

unittest { // removeOrphans:false: floating vert preserved when no other stage fires
    postReset();
    // Valid triangle + one orphan vert (not referenced by any face).
    // No dirty geometry → all other default stages are no-ops.
    postLoadMesh(`{
        "vertices":[[0,0,0],[1,0,0],[0,1,0],[9,9,9]],
        "faces":[[0,1,2]]
    }`);
    assert(getModel()["vertexCount"].integer == 4, "fixture: 4 verts (1 orphan)");

    // removeOrphans:false → orphan must survive; all other stages no-op → status:error.
    const depthBefore = undoCount();
    cast(void) post("http://localhost:8080/api/command",
        `{"id":"mesh.cleanup","params":{"removeOrphans":false}}`);
    assert(getModel()["vertexCount"].integer == 4,
        "removeOrphans:false must preserve the floating vert");
    assert(undoCount() == depthBefore,
        "no-op (orphan preserved, no other stage fired) must not add undo entry");
}

unittest { // all-stages-off + orphan: true no-op, no undo entry (no-op contract)
    // Before the fix, the unconditional final compactUnreferenced would mutate
    // the mesh even with every stage disabled, creating a spurious undo entry.
    postReset();
    postLoadMesh(`{
        "vertices":[[0,0,0],[1,0,0],[0,1,0],[9,9,9]],
        "faces":[[0,1,2]]
    }`);
    assert(getModel()["vertexCount"].integer == 4, "fixture: 4 verts (1 orphan)");

    const depthBefore = undoCount();
    cast(void) post("http://localhost:8080/api/command",
        `{"id":"mesh.cleanup","params":{"mergeVerts":false,"dropDegenerate":false,"unify":false,"removeOrphans":false,"dissolve2Valent":false}}`);
    assert(getModel()["vertexCount"].integer == 4,
        "all-stages-off must not remove the orphan vert");
    assert(undoCount() == depthBefore,
        "all-stages-off must not add undo entry (no-op contract)");
}
