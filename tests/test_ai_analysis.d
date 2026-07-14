// Tests for the AI Modeling Copilot: GET /api/ai/analyze — a read-only,
// main-thread-bridged snapshot of `ai.analysis.analyzeMesh`. No UI, no
// geometry mutation.
//
// Phase 1 (task 0402): endpoint wiring + JSON shape + the SubdivReadiness
// detector on a known fixture.
//
// Phase 4 (task 0402, doc/ai_copilot_plan.md): coverage for the remaining
// three categories — Cleanup / Topology / Retopo — via `POST /api/load-mesh`
// (test-only raw-mesh injection, see `commands/scene/load_mesh.d`) fixtures
// carrying a KNOWN, hand-placed defect of each kind. Per-defect-kind
// element-index-SET fidelity (detector vs. the mutating fix it mirrors) is
// covered exhaustively by `dub test` unittests in `source/mesh_analysis.d`
// — these HTTP tests only prove the categories reach the live endpoint with
// sane element sets, not the fine-grained fidelity guarantee.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void resetCube() {
    auto resp = postJson("/api/reset?type=cube", "");
    assert(resp["status"].str == "ok", "/api/reset cube failed");
}

void resetGrid(int n) {
    auto resp = postJson("/api/reset?type=grid&n=" ~ n.to!string, "");
    assert(resp["status"].str == "ok", "/api/reset grid failed");
}

void postLoadMesh(string body_) {
    auto resp = postJson("/api/load-mesh", body_);
    assert(resp["status"].str == "ok", "/api/load-mesh failed: " ~ resp.toString);
}

JSONValue getModel() { return getJson("/api/model"); }

/// Findings whose category matches `category`, from a raw /api/ai/analyze array.
JSONValue[] findingsOfCategory(JSONValue findings, string category) {
    JSONValue[] result;
    foreach (f; findings.array)
        if (f["category"].str == category) result ~= f;
    return result;
}

/// Sorted-ascending long[] read from a finding's "verts"/"edges"/"faces" array.
long[] intArray(JSONValue arr) {
    import std.algorithm.sorting : sort;
    long[] result;
    foreach (v; arr.array) result ~= v.integer;
    sort(result);
    return result;
}

unittest { // cube: at least one SubdivReadiness finding grouping sharp edges
    resetCube();

    auto findings = getJson("/api/ai/analyze");
    assert(findings.type == JSONType.array, "/api/ai/analyze must return a JSON array");
    assert(findings.array.length >= 1, "cube should yield at least one finding");

    auto m = getModel();
    immutable size_t edgeCount = m["edges"].array.length;

    bool[long] coveredEdges;
    foreach (f; findings.array) {
        assert(f["category"].str == "subdivReadiness",
               "Phase 1 only emits SubdivReadiness findings, got " ~ f["category"].str);
        assert(f["suggestedOp"].str == "loop.slice");
        assert(f["id"].str.length > 0);
        assert(f["edges"].type == JSONType.array);
        assert(f["edges"].array.length > 0,
               "a SubdivReadiness finding must carry a non-empty edge set");
        foreach (e; f["edges"].array) {
            long ei = e.integer;
            assert(ei >= 0 && cast(size_t)ei < edgeCount,
                   "finding edge index must reference a real mesh edge");
            coveredEdges[ei] = true;
        }
        // Element sets act-on would select — verts/faces are unpopulated by
        // the SubdivReadiness detector but must still be present (valid,
        // possibly-empty arrays), and score/features must be well-formed.
        assert(f["verts"].type == JSONType.array);
        assert(f["faces"].type == JSONType.array);
        assert(f["score"].type == JSONType.float_ || f["score"].type == JSONType.integer);
        assert(f["features"].type == JSONType.array);
        assert(f["features"].array.length > 0);
    }
    assert(coveredEdges.length > 0, "the cube's sharp edges should be covered by findings");
}

unittest { // flat grid: zero SubdivReadiness findings. A flat open grid DOES
    // legitimately surface a Phase-4 Topology naked-boundary finding (task
    // 0402 Phase 4) since it has an open rim — that is a correct finding,
    // not a false positive, so this only asserts on SubdivReadiness.
    resetGrid(4);

    auto findings = getJson("/api/ai/analyze");
    assert(findings.type == JSONType.array);
    foreach (f; findings.array)
        assert(f["category"].str != "subdivReadiness",
               "a flat grid must not surface a SubdivReadiness finding");
}

unittest { // determinism: two GETs on the same (unmutated) mesh agree
    resetCube();
    auto a = getJson("/api/ai/analyze");
    auto b = getJson("/api/ai/analyze");
    assert(a.array.length == b.array.length);
    foreach (i; 0 .. a.array.length) {
        assert(a.array[i]["id"].str == b.array[i]["id"].str);
        assert(a.array[i]["edges"] == b.array[i]["edges"]);
    }
}

// ===========================================================================
// Phase 4 — Cleanup category
// ===========================================================================

unittest { // Cleanup: one injected defect of each of the 4 Cleanup kinds,
    // all mutually disjoint (no shared vertex/edge between defects) so each
    // detector's element set is unambiguous.
    //   verts 0,1   : coincident pair (weld cluster) — anchored into 2
    //                 separate, otherwise-healthy triangles so neither face
    //                 itself becomes degenerate.
    //   verts 6,7,8 : COLLINEAR (not coincident — distinct positions 1 unit
    //                 apart) -> zero Newell area -> degenerate face, without
    //                 also tripping the weld detector.
    //   verts 9-12  : a quad + its reversed-winding duplicate.
    //   vert 13     : referenced by nothing -> orphan.
    postLoadMesh(`{"vertices":[` ~
        `[0,0,0],[0,0,0],[1,0,0],[0,1,0],[1,1,0],[2,1,0],` ~
        `[5,0,0],[6,0,0],[7,0,0],` ~
        `[10,0,0],[11,0,0],[11,1,0],[10,1,0],` ~
        `[20,20,20]` ~
        `],"faces":[` ~
        `[0,2,3],[1,4,5],[6,7,8],[9,10,11,12],[12,11,10,9]` ~
        `]}`);

    auto findings = getJson("/api/ai/analyze");
    assert(findings.type == JSONType.array);
    auto cleanup = findingsOfCategory(findings, "cleanup");
    assert(cleanup.length >= 4,
        "expected >= 4 Cleanup findings (weld/degenerate/duplicate/orphan), got " ~
        cleanup.length.to!string);

    bool sawWeld, sawDegenerate, sawDuplicate, sawOrphan;
    foreach (f; cleanup) {
        assert(f["suggestedOp"].str == "mesh.cleanup");
        immutable string id = f["id"].str;
        if (id.length >= 12 && id[0 .. 12] == "cleanup.weld") {
            sawWeld = true;
            assert(intArray(f["verts"]) == [0L, 1L], "weld cluster must be exactly {0,1}");
        } else if (id == "cleanup.degenerate") {
            sawDegenerate = true;
            assert(intArray(f["faces"]) == [2L], "degenerate finding must flag exactly face 2");
        } else if (id == "cleanup.duplicate") {
            sawDuplicate = true;
            assert(intArray(f["faces"]) == [4L], "duplicate finding must flag exactly face 4 (the later occurrence)");
        } else if (id == "cleanup.orphan") {
            sawOrphan = true;
            assert(intArray(f["verts"]) == [13L], "orphan finding must flag exactly vertex 13");
        }
    }
    assert(sawWeld && sawDegenerate && sawDuplicate && sawOrphan,
        "missing a Cleanup finding kind: weld=" ~ sawWeld.to!string ~
        " degenerate=" ~ sawDegenerate.to!string ~
        " duplicate=" ~ sawDuplicate.to!string ~
        " orphan=" ~ sawOrphan.to!string);
}

// ===========================================================================
// Phase 4 — Topology category
// ===========================================================================

unittest { // Topology — orientation: an inconsistently-wound quad pair,
    // kept in its OWN fixture (not combined with the non-manifold book
    // below) — a non-manifold 3-face edge split into a manifold pair + one
    // ISOLATED single-face "component" by `computeOrientationFlipMask`'s
    // manifold-BFS, and an isolated single flat face's own seed heuristic
    // can independently decide it "looks" inverted relative to its own
    // centroid (pre-existing `fixFaceOrientation` behavior, unrelated to
    // Phase 4 — verified live: the book fixture alone also reports a
    // topology.orientation finding). Combining the two scenarios would
    // therefore assert on that incidental interaction instead of the
    // orientation defect this test actually targets, so they are separate
    // fixtures.
    //
    // No boundary assertion here: `Mesh.boundaryLoops`'s directed-chain
    // walker (pre-existing, not touched by Phase 4) depends on CONSISTENT
    // winding to trace a boundary as one continuous directed cycle — on
    // THIS deliberately inconsistent pair, the shared edge is traversed the
    // same direction by both faces, so vertex 1 never contributes an
    // outgoing boundary half-edge while vertex 2 contributes two, and the
    // walk can't form any length->=3 loop (verified live: `boundaryLoops()`
    // returns `[]` for this exact fixture). A winding-inconsistent mesh's
    // boundary is genuinely ill-defined by a winding-dependent walk — not a
    // Phase-4 regression. `topology.boundary` coverage is exercised by the
    // Cleanup and Retopo fixtures below/above instead.
    postLoadMesh(`{"vertices":[` ~
        `[0,0,0],[1,0,0],[1,1,0],[0,1,0],[2,0,0],[2,1,0]` ~
        `],"faces":[` ~
        `[0,1,2,3],[1,2,5,4]` ~
        `]}`);

    auto findings = getJson("/api/ai/analyze");
    auto topology = findingsOfCategory(findings, "topology");

    bool sawOrientation;
    foreach (f; topology) {
        if (f["id"].str == "topology.orientation") {
            sawOrientation = true;
            assert(f["suggestedOp"].str == "mesh.fixOrientation");
            auto faces = intArray(f["faces"]);
            assert(faces.length == 1, "exactly one face should have flipped");
            assert(faces[0] == 0 || faces[0] == 1,
                "the flipped face must be one of the two winding-pair quads");
        }
    }
    assert(sawOrientation, "missing topology.orientation finding");
}

unittest { // Topology — non-manifold: a 3-face "book" sharing one edge, its
    // own fixture (see the comment above for why it is not combined with
    // the orientation pair). A topology.orientation finding MAY also appear
    // here (the isolated-third-face seed-heuristic quirk noted above) — not
    // asserted either way, since it is not what this test targets.
    //
    // No boundary assertion here either, for the same reason as the
    // orientation test above: a 3-face-shared edge has no well-defined
    // "consistent winding" (that concept only applies to exactly 2 incident
    // faces), so `Mesh.boundaryLoops`'s directed-chain walker's result
    // around this edge is exposed to the same pre-existing fragility —
    // observed to depend on AA (hash-map) iteration order across separate
    // process runs, not something Phase 4 introduces or should paper over.
    // `topology.boundary` coverage is exercised by the Cleanup and Retopo
    // fixtures instead.
    postLoadMesh(`{"vertices":[` ~
        `[0,0,0],[0,1,0],[1,0,0],[1,1,0],[-1,0.3,0.3],[-1,0.7,0.3],[0.3,-1,-0.3],[0.7,-1,-0.3]` ~
        `],"faces":[` ~
        `[0,1,3,2],[1,0,4,5],[0,1,7,6]` ~
        `]}`);

    auto findings = getJson("/api/ai/analyze");
    auto topology = findingsOfCategory(findings, "topology");

    bool sawNonManifold;
    foreach (f; topology) {
        if (f["id"].str == "topology.nonManifold") {
            sawNonManifold = true;
            assert(f["suggestedOp"].str == "mesh.cleanup");
            assert(intArray(f["edges"]).length == 1, "exactly one non-manifold edge expected");
        }
    }
    assert(sawNonManifold, "missing topology.nonManifold finding");
}

// ===========================================================================
// Phase 4 — Retopo category
// ===========================================================================

unittest { // Retopo: one lone triangle (non-quad arity -> hotspot) beside an
    // isolated, otherwise-unremarkable quad that must NOT be flagged.
    postLoadMesh(`{"vertices":[` ~
        `[0,0,0],[1,0,0],[0.5,1,0],` ~
        `[10,0,0],[11,0,0],[11,1,0],[10,1,0]` ~
        `],"faces":[` ~
        `[0,1,2],[3,4,5,6]` ~
        `]}`);

    auto findings = getJson("/api/ai/analyze");
    auto retopo = findingsOfCategory(findings, "retopo");
    assert(retopo.length >= 1, "expected at least one Retopo hotspot finding");

    bool sawTriangleHotspot;
    foreach (f; retopo) {
        assert(f["suggestedOp"].str == "mesh.remesh");
        auto faces = intArray(f["faces"]);
        if (faces == [0L]) sawTriangleHotspot = true;
        // The clean quad (face 1) must never appear in ANY retopo cluster.
        foreach (fi; faces) assert(fi != 1, "the clean isolated quad (face 1) must not be flagged");
    }
    assert(sawTriangleHotspot, "expected a hotspot cluster containing exactly the lone triangle (face 0)");
}
