// test_bevel_fin_bundle.d — the seam cell for `mesh.bevel`'s NON-MANIFOLD
// fin-bundle path (task 1903 Stage E4).
//
// WHY THIS FILE EXISTS AND WHY IT LOADS ITS OWN MESH. Stage E4 converted
// `source/mesh_ops/bevel_fin.d` to free functions over `ref MeshEditBatch`, and
// its only caller — `bevelEdgesByMask` in `mesh_ops/edge_bevel.d` — was still a
// MIXIN body, i.e. it IS the mesh, so plan §4.1's "the command or the tool
// opens the batch" had nowhere to land. §4.4a's transitional shape applied: a
// narrow `unrecorded` batch at the two call sites, labelled, naming Stage G as
// the stage that removes it, and carrying a per-command `nestedBatchOpens`
// DELTA assert in that command's own suite test. This is that test.
//
// STAGE G REMOVED THE DEBT (2026-08-26) and this file survived it unchanged in
// every number. `bevelEdgesByMask` is a free function over `ref MeshEditBatch`
// now, so the batch these kernels run in is the one `mesh.bevel` opens at its
// own boundary, and the two transitional opens are gone. Every assertion below
// still holds and still means something — but read the nested-batch rows for
// what they are: they read 0 with the debt (it was the OUTERMOST open) and 0
// without it (there is no second open at all), so they never could have
// witnessed the removal. The row that does is the
// `MeshEditBatch.unrecorded(` == 0 count over `source/mesh_ops/edge_bevel.d` in
// `tests/unit/commit_seam_census_test.d`.
//
// THE DELTA IS THE LOAD-BEARING WORD. The single process-cumulative `== 0` in
// `tests/test_undo_tracker_delete.d` is NOT this tripwire: it never runs
// `mesh.bevel`, and under `-j 8` it is a different process.
//
// AND THE MESH MUST BE A FIN BUNDLE, which is why /api/load-mesh is here. The
// transitional block is only entered when a SELECTED edge is shared by three or
// more faces AND both its endpoints touch nothing but those fins. No fixture the
// suite already has can exhibit that — `/api/reset?type=cube` certainly cannot —
// so a delta assert on any ordinary bevel cell would sit downstream of a branch
// it never takes and could not come out differently.

import http_client : testBaseUrl, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import batchless_control_helpers;
import std.math : cos, sin, PI, abs;

void main() {}

alias BASE = testBaseUrl;


JSONValue model()   { return parseJSON(cast(string)get(BASE ~ "/api/model")); }
JSONValue changes() { return parseJSON(cast(string)get(BASE ~ "/api/changes")); }

void ok(JSONValue r, string what) {
    assert(r["status"].str == "ok" || r["status"].str == "success",
        what ~ " failed: " ~ r.toString);
}

/// A bundle of `n` fins sharing the spine (0,0,+1)-(0,0,-1), whose two spine
/// endpoints touch NOTHING but those fins — the ISOLATED bundle task 0438
/// measured. Vertex 0 / 1 are the spine; fin k uses [0, 2+2k, 3+2k, 1].
void loadFinBundle(int n) {
    string verts = `[[0,0,1],[0,0,-1]`;
    foreach (k; 0 .. n) {
        immutable double a = 2.0 * PI * k / n;
        verts ~= `,[` ~ cos(a).to!string ~ `,` ~ sin(a).to!string ~ `,1]`;
        verts ~= `,[` ~ cos(a).to!string ~ `,` ~ sin(a).to!string ~ `,-1]`;
    }
    verts ~= `]`;
    string faces = `[`;
    foreach (k; 0 .. n) {
        if (k) faces ~= `,`;
        faces ~= `[0,` ~ (2 + 2 * k).to!string ~ `,` ~ (3 + 2 * k).to!string ~ `,1]`;
    }
    faces ~= `]`;
    ok(postJson("/api/command", commandBody("scene.loadMesh", `{"vertices":` ~ verts ~ `,"faces":` ~ faces ~ `}`)),
       "/api/load-mesh (fin bundle)");
}

void loadCube() {
    ok(postJson("/api/reset", ""), "/api/reset");
}

/// The index of the edge joining `a` and `b` in the live mesh.
int edgeIndexOf(int a, int b) {
    auto m = model();
    foreach (i, e; m["edges"].array) {
        immutable int u = cast(int)e.array[0].integer, v = cast(int)e.array[1].integer;
        if ((u == a && v == b) || (u == b && v == a)) return cast(int)i;
    }
    return -1;
}

void selectEdges(int[] idx) {
    string j = "[";
    foreach (i, v; idx) { if (i) j ~= ","; j ~= v.to!string; }
    j ~= "]";
    ok(postJson("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":` ~ j ~ `}`)), "/api/select edges");
}

size_t faceCount(JSONValue m) { return m["faces"].array.length; }
long   vertCount(JSONValue m) { return m["vertexCount"].integer; }

/// How many faces of arity `k` the model has — the fin law's fingerprint: a
/// fin-bundle bevel adds exactly TWO n-gon fan caps and leaves every fin at its
/// original arity, which an ordinary manifold bevel never produces.
int arity(JSONValue m, size_t k) {
    int n;
    foreach (f; m["faces"].array) if (f.array.length == k) ++n;
    return n;
}

// ---------------------------------------------------------------------------
unittest { // the fin-bundle path runs inside ONE batch, and it is the OUTERMOST one
    // POSITIVE CONTROL FIRST, and it is not decoration. Every counter assert
    // below is "this did not move", and a dead counter — the endpoint reading a
    // stale copy, the `g_isDocumentMesh` predicate uninstalled — satisfies that
    // for free. So make the SAME counter move first, with a command that is
    // deliberately still batchless.
    loadCube();
    ok(postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`)), "/api/select");
    auto c0 = changes();
    foreach (c; kBatchlessControlSeq)
        ok(postJson("/api/command", c), kBatchlessControlCommand);
    auto c1 = changes();
    immutable long ctrl = c1["unbatchedGeometryCommits"].integer
                        - c0["unbatchedGeometryCommits"].integer;
    assert(ctrl > 0,
        kBatchlessControlWhy ~ ctrl.to!string ~ kBatchlessControlFix);

    // ---- the single-spine door -------------------------------------------
    loadFinBundle(3);
    immutable int spine = edgeIndexOf(0, 1);
    assert(spine >= 0, "the loaded fin bundle has no (0,1) spine edge");
    selectEdges([spine]);

    auto b = changes();
    ok(postJson("/api/command", `{"id":"mesh.bevel","params":{"width":0.4}}`),
       "mesh.bevel on a 3-fin bundle");
    auto a = changes();
    auto m = model();

    // ANTI-VACUITY, AND IT IS THE PART THAT PROVES THE BRANCH WAS TAKEN.
    // `bevelEdgesByMask` refuses a >=3-face edge outright unless the isolated
    // bundle precondition holds, and a refusal makes NO commits at all — so
    // every "delta == 0" below would hold on a mesh nothing happened to. The
    // fin law's fingerprint is what says otherwise: the two spine vertices are
    // consumed and replaced by 2N rails (8 -> 12 verts), and exactly TWO
    // TRIANGLE fan caps appear beside the three still-quad fins. An ordinary
    // manifold bevel of this selection produces neither.
    assert(vertCount(m) == 12 && faceCount(m) == 5,
        "the 3-fin bundle bevel left V=" ~ vertCount(m).to!string ~ " F="
      ~ faceCount(m).to!string ~ ", expected V=12 F=5 (six rails in, the two "
      ~ "spine verts out, two fan caps added). On a REFUSAL the mesh is "
      ~ "byte-identical and every counter assertion below is vacuous "
      ~ "(task 1903 Stage E4).");
    assert(arity(m, 3) == 2 && arity(m, 4) == 3,
        "the bevel left " ~ arity(m, 3).to!string ~ " triangle(s) and "
      ~ arity(m, 4).to!string ~ " quad(s), expected 2 and 3 — the two N-gon fan "
      ~ "caps plus the three fins at their original arity. Without this the "
      ~ "count check above could be satisfied by some other edit "
      ~ "(task 1903 Stage E4).");

    // THE §4.4a TRIPWIRE — AND WHAT IT MEANS SINCE STAGE G. Until G,
    // edge_bevel.d held a TRANSITIONAL `unrecorded` batch here, safe only while
    // it was the OUTERMOST one. Stage G converted `bevelEdgesByMask` itself, so
    // that open is gone and the batch this path runs in is `mesh.bevel`'s own.
    // The delta is still 0 and this row is still the one that refuses a caller
    // above it holding a second batch — but note that it read 0 BEFORE the
    // removal too, so it is NOT the row that witnesses the removal. That is the
    // `MeshEditBatch.unrecorded(` == 0 row over edge_bevel.d in
    // tests/unit/commit_seam_census_test.d.
    immutable long nested = a["nestedBatchOpens"].integer - b["nestedBatchOpens"].integer;
    assert(nested == 0,
        "mesh.bevel opened " ~ nested.to!string ~ " NESTED batch(es) on the "
      ~ "fin-bundle path. Since Stage G the only batch on this path is the "
      ~ "COMMAND's — `bevelEdgesByMask` takes it as its receiver and hands it "
      ~ "straight to bevel_fin.d's kernels — so a non-zero delta means a caller "
      ~ "above `mesh.bevel` now holds one too. Collapse the two rather than "
      ~ "nesting (task 1903 Stage E4, re-anchored at Stage G, plan §4.4a).");

    immutable long unbatched = a["unbatchedGeometryCommits"].integer
                             - b["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        "mesh.bevel made " ~ unbatched.to!string ~ " UNBATCHED geometry "
      ~ "commit(s) on the fin-bundle path. The kernels' receiver is "
      ~ "`ref MeshEditBatch`, so their commits must defer into the frame and "
      ~ "stamp once at close(). Measured with the deferral disabled: +12 on "
      ~ "this three-fin stand, and it grows with N. Re-measured at Stage G "
      ~ "after the transitional batch was removed: the same +12, because the "
      ~ "count is of the KERNEL's commits and does not depend on which frame "
      ~ "holds them (task 1903 Stage E4, plan §3.2 L2).");

    // The batch is UNRECORDED and it must stay that way: `mesh.bevel` undoes
    // through a whole-mesh MeshSnapshot, so an op-log here is one nobody reads.
    immutable long opLog = a["opLogEntriesRecorded"].integer
                         - b["opLogEntriesRecorded"].integer;
    assert(opLog == 0,
        "mesh.bevel recorded " ~ opLog.to!string ~ " op-log entr(ies) on the "
      ~ "fin-bundle path. The command's batch is `unrecorded` deliberately "
      ~ "(plan §9): this command's undo is still a whole-mesh snapshot, so a "
      ~ "recorded delta is built and dropped (task 1903 Stage E4, Stage G).");
    assert(a["batchLeaks"].integer - b["batchLeaks"].integer == 0,
        "a MeshEditBatch leaked its frame during mesh.bevel — the handle's "
      ~ "destructor popped instead of close() (plan §2.2c)");
    assert(a["batchUpgradeRefusals"].integer - b["batchUpgradeRefusals"].integer == 0,
        "mesh.bevel refused a batch upgrade on the fin-bundle path (plan §2.3 "
      ~ "rule 3)");
}

unittest { // the MULTI-EDGE door — the second transitional batch, same law
    loadFinBundle(3);
    immutable int spine = edgeIndexOf(0, 1);
    immutable int extra = edgeIndexOf(0, 2);     // fin 0's outer rim edge at +z
    assert(spine >= 0 && extra >= 0,
        "the loaded fin bundle lost its spine or its +z rim edge");
    selectEdges([spine, extra]);

    auto b = changes();
    ok(postJson("/api/command", `{"id":"mesh.bevel","params":{"width":0.4}}`),
       "mesh.bevel on a 3-fin bundle + one extra edge");
    auto a = changes();
    auto m = model();

    // Anti-vacuity: the multi-edge builder REFUSES anything past the measured
    // shape and refuses byte-identically, so the fingerprint has to say the
    // miter path ran. It differs from the single-spine cell by the corner-cut:
    // the extra edge's far vertex is replaced by TWO (a perpendicular inset of
    // the fin's next edge and a slide along it) and, being used by that fin
    // alone, is then dropped by the tail compaction — net +1 over the plain
    // case, V=13 against 12, with the same five faces. MEASURED, not derived:
    // an earlier draft of this cell predicted 14 by counting the two new points
    // and forgetting the one they replace, and the suite is what corrected it.
    assert(vertCount(m) == 13 && faceCount(m) == 5,
        "the multi-edge fin bevel left V=" ~ vertCount(m).to!string ~ " F="
      ~ faceCount(m).to!string ~ ", expected V=13 F=5 (the plain 12, plus the "
      ~ "extra edge's far vertex corner-cut into two and the original dropped). "
      ~ "On a REFUSAL every counter assertion below is vacuous "
      ~ "(task 1903 Stage E4).");

    assert(a["nestedBatchOpens"].integer - b["nestedBatchOpens"].integer == 0,
        "mesh.bevel opened a NESTED batch on the MULTI-EDGE fin path. This "
      ~ "arm was the SECOND of edge_bevel.d's two transitional opens until "
      ~ "Stage G removed both (plan §4.4a); the cell above only covers the "
      ~ "first arm, and the two arms are different code "
      ~ "(task 1903 Stage E4, Stage G).");
    assert(a["unbatchedGeometryCommits"].integer
         - b["unbatchedGeometryCommits"].integer == 0,
        "mesh.bevel made UNBATCHED geometry commits on the MULTI-EDGE fin path "
      ~ "(task 1903 Stage E4).");
    assert(a["opLogEntriesRecorded"].integer - b["opLogEntriesRecorded"].integer == 0,
        "mesh.bevel recorded op-log entries on the MULTI-EDGE fin path — the "
      ~ "command's batch must stay `unrecorded` (task 1903 Stage E4, Stage G).");
}

unittest { // undo still restores the bundle — the snapshot path is untouched
    // Stage E4 is a CONVERSION stage: the undo axis is L7's. This cell is what
    // says so out loud, on the one path whose caller had to grow a batch.
    loadFinBundle(3);
    immutable int spine = edgeIndexOf(0, 1);
    selectEdges([spine]);
    ok(postJson("/api/command", `{"id":"mesh.bevel","params":{"width":0.4}}`),
       "mesh.bevel");
    assert(vertCount(model()) == 12, "the bevel did not apply; undo proves nothing");
    ok(postJson("/api/undo", ""), "/api/undo");
    auto m = model();
    assert(vertCount(m) == 8 && faceCount(m) == 3,
        "undo left V=" ~ vertCount(m).to!string ~ " F=" ~ faceCount(m).to!string
      ~ ", expected the loaded bundle's V=8 F=3. The command's batch is "
      ~ "UNRECORDED and this command still undoes through a whole-mesh "
      ~ "MeshSnapshot; if that stopped working, the batch is committing "
      ~ "something it should not (task 1903 Stage E4, Stage G).");
}
