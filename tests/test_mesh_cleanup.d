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
import batchless_control_helpers;

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

JSONValue getChanges() {
    return parseJSON(get("http://localhost:8080/api/changes"));
}

// Required before the seam block below, which uses a polygon command as its
// positive control.
void setPolygonMode() {
    auto resp = post("http://localhost:8080/api/command", "select.typeFrom polygon");
    assert(parseJSON(resp)["status"].str == "ok",
        "select.typeFrom polygon failed: " ~ resp);
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
    // TASK 1903 STAGE L5-c — this cell now covers a DELTA replay, not a
    // whole-mesh snapshot restore, and its undo-depth half is new for that
    // reason. `MeshCleanup` records an operation-log delta and reverts it; the
    // failure mode that shape brings is an `/api/undo` that answers `ok`
    // having done nothing, which the geometry compare below cannot see —
    // it would then be comparing a mesh against itself. A witness was inert
    // TWICE in this task for exactly that, so the count is asserted.
    postReset();
    postLoadMesh(dirtyMeshFixture());

    const depthBefore = undoCount();
    postCommand(`{"id":"mesh.cleanup"}`);
    assert(getModel()["faceCount"].integer == 2, "post-cleanup: 2 faces");
    assert(undoCount() == depthBefore + 1,
        "mesh.cleanup left the undo stack at " ~ undoCount().to!string
      ~ ", expected " ~ (depthBefore + 1).to!string ~ " — the command applied "
      ~ "but recorded no history entry, so there is nothing for the undo "
      ~ "below to act on");

    postUndo();
    assert(undoCount() == depthBefore,
        "/api/undo answered but the undo stack went from "
      ~ (depthBefore + 1).to!string ~ " to " ~ undoCount().to!string
      ~ " — nothing was undone and the geometry compare below is a mesh "
      ~ "against itself");
    auto undone = getModel();
    assert(undone["vertexCount"].integer == 9,
        "undo: expected 9 verts, got " ~ undone["vertexCount"].integer.to!string);
    assert(undone["faceCount"].integer == 4,
        "undo: expected 4 faces, got " ~ undone["faceCount"].integer.to!string);
}

unittest { // mesh.edgeCrease.set / .clear: one undo step each, and it restores
    // TASK 1903 STAGE L5-d — the crease pair moved from `MeshSnapshot` to the
    // delta, and this is the suite-lane half of that: a map-value edit moves
    // NO geometry count, so the only thing a lane-S cell can read cheaply is
    // the undo DEPTH — and that is what separates "the undo restored it" from
    // "the undo did nothing and there was never anything to restore". The
    // stored weights themselves are pinned by value in
    // `tests/test_edge_weight_v3d.d`, which round-trips them through a saved
    // document rather than through this endpoint.
    postReset();
    // Two edges of the default cube, named explicitly — the same operand
    // `tests/test_edge_weight_v3d.d` uses. Two and not one: a single-edge
    // crease plane is uniform, and a restore onto the wrong edge would
    // compare EQUAL.
    auto selResp = post("http://localhost:8080/api/select",
                        `{"mode":"edges","indices":[6,9]}`);
    assert(parseJSON(selResp)["status"].str == "ok",
           "/api/select failed: " ~ selResp);

    const depth0 = undoCount();
    postCommand(`{"id":"mesh.edgeCrease.set","params":{"weight":0.5}}`);
    assert(undoCount() == depth0 + 1,
        "mesh.edgeCrease.set left the undo stack at " ~ undoCount().to!string
      ~ ", expected " ~ (depth0 + 1).to!string);

    postCommand(`{"id":"mesh.edgeCrease.clear"}`);
    assert(undoCount() == depth0 + 2,
        "mesh.edgeCrease.clear left the undo stack at " ~ undoCount().to!string
      ~ ", expected " ~ (depth0 + 2).to!string ~ " — a clear over a map that "
      ~ "really carries 0.5 on every edge is a REAL edit, not a no-op");

    postUndo();
    assert(undoCount() == depth0 + 1,
        "the clear's undo did not pop a step");
    postUndo();
    assert(undoCount() == depth0,
        "the set's undo did not pop a step");
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

// ---------------------------------------------------------------------------
// The edit-seam observables of mesh.cleanup and poly.unify (task 1903 Stage
// E1). These are invisible to every other test in this file: the geometry a
// hygiene sweep produces is byte-identical whether or not the kernel runs
// inside a batch. What separates those worlds is the change-bus counters at
// /api/changes.
// ---------------------------------------------------------------------------
unittest { // both commands run their kernel inside ONE edit batch
    postReset();
    setPolygonMode();

    // POSITIVE CONTROL, and it is not decoration. Every assertion below is
    // "this counter did not move", and a dead counter — the g_isDocumentMesh
    // predicate uninstalled, the endpoint reading a stale copy — satisfies
    // that for free. So make the SAME counter move first, with a command that
    // is deliberately still batchless — `kBatchlessControlCommand`, which
    // lives in tests/batchless_control_helpers.d because the answer has moved
    // five times, most recently when stage L10-P0 gave mesh.triple a batch.
    auto c0 = getChanges();
    foreach (c; kBatchlessControlSeq) postCommand(c);
    auto c1 = getChanges();
    const long ctrl = c1["unbatchedGeometryCommits"].integer
                    - c0["unbatchedGeometryCommits"].integer;
    assert(ctrl > 0,
        kBatchlessControlWhy ~ ctrl.to!string ~ kBatchlessControlFix);

    // (1) mesh.cleanup — the caller with the most to gain: a default sweep
    // runs weld, degenerate, unify and two compactions, each of which commits
    // at least once on its own. Inside the batch they all defer and stamp once
    // at close(). The pre-E1 delta is a MEASURED number and it lives in the
    // assertion's own message below, in one place: this comment used to carry
    // a second copy of it, the two drifted (+7 here against +8 there) and the
    // copy nothing reads is the one that was wrong.
    postLoadMesh(dirtyMeshFixture());
    auto b1 = getChanges();
    postCommand(`{"id":"mesh.cleanup"}`);
    auto a1 = getChanges();
    const long unbatchedCleanup = a1["unbatchedGeometryCommits"].integer
                                - b1["unbatchedGeometryCommits"].integer;
    assert(unbatchedCleanup == 0,
        "mesh.cleanup made " ~ unbatchedCleanup.to!string ~ " UNBATCHED "
      ~ "geometry commit(s). The kernel's receiver is `ref MeshEditBatch`, so "
      ~ "its commits must defer into the frame and stamp once at close(); a "
      ~ "non-zero delta means the batch does not cover the kernel "
      ~ "(task 1903 Stage E1, plan §3.2 L2). Pre-E1 this was +8.");

    // …and the sweep actually did something, so the zero above is not the
    // zero of a rejected command.
    assert(getModel()["faceCount"].integer == 2,
        "the sweep left " ~ getModel()["faceCount"].integer.to!string
      ~ " faces, expected 2 — a rejected mesh.cleanup would move no counter "
      ~ "at all and make the assertion above vacuous");

    // (2) poly.unify — one kernel, two internal commits
    // (deleteFacesByMask's Geometry and its compactUnreferenced's Points).
    // Pre-E1 delta: in the message below, same rule as (1).
    postLoadMesh(`{
        "vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],
        "faces":[[0,1,2,3],[0,1,2,3]]
    }`);
    auto b2 = getChanges();
    postCommand(`{"id":"poly.unify"}`);
    auto a2 = getChanges();
    const long unbatchedUnify = a2["unbatchedGeometryCommits"].integer
                              - b2["unbatchedGeometryCommits"].integer;
    assert(unbatchedUnify == 0,
        "poly.unify made " ~ unbatchedUnify.to!string ~ " UNBATCHED geometry "
      ~ "commit(s) (task 1903 Stage E1, plan §3.2 L2). Pre-E1 this was +2.");
    assert(getModel()["faceCount"].integer == 1,
        "poly.unify left " ~ getModel()["faceCount"].integer.to!string
      ~ " faces, expected 1 — a rejected unify would make the assertion above "
      ~ "vacuous");

    // (3) The batches closed cleanly, nobody stamped without publishing, and
    // no kernel opened one of its own (this family has NO intra-Mesh caller,
    // so unlike D3's thicken/sweep it owes no transitional-batch debt — the
    // delta below is what says so).
    const long nested = a2["nestedBatchOpens"].integer
                      - c0["nestedBatchOpens"].integer;
    assert(nested == 0,
        "the cleanup family moved changeBus.nestedBatchOpens by "
      ~ nested.to!string ~ ", expected 0. Its batches are opened at the three "
      ~ "command boundaries and nowhere else; a nested open means a kernel "
      ~ "started opening one, which §2.3 rule 2 forbids (task 1903 Stage E1).");
    assert(a2["batchLeaks"].integer == 0,
        "a MeshEditBatch leaked (destroyed while still open): "
      ~ a2["batchLeaks"].integer.to!string);
    assert(a2["missedPublishers"].integer == 0,
        "a mutationVersion bump reached the frame with no pending change: "
      ~ a2["missedPublishers"].integer.to!string);
    // RECORDING as of Stage L10-c, and the number is exact. It was 0 through
    // E1, which is what this assertion pinned then; L10 moved `poly.unify`'s
    // undo off the whole-mesh snapshot, so the batch is now the thing
    // `revert()` replays. L10, not L5: the L-table (plan §5.5) is keyed by
    // COMMAND, and `unify` sits in the topo-misc/reindexing row beside
    // collapse and weld, while L5 is the cleanup/remesh row that owns
    // `mesh.cleanup`.
    const long unifyOpLog = a2["opLogEntriesRecorded"].integer
                          - b2["opLogEntriesRecorded"].integer;
    assert(unifyOpLog == 1,
        "poly.unify recorded " ~ unifyOpLog.to!string ~ " op-log entrie(s), "
      ~ "expected exactly 1 — `unifyFaces` reaches `deleteFacesByMask`, which "
      ~ "records one RemoveFaces for the duplicate face it drops (task 1903 "
      ~ "Stage L10-c). A 0 means the batch went back to UNRECORDED and this "
      ~ "command's undo restores nothing while `revert()` still answers true.");
}
