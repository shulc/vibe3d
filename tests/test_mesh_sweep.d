// test_mesh_sweep.d — HTTP smoke tests for the mesh.sweep command.
//
// mesh.sweep revolves a selected edge profile (or polygon face) around a
// principal axis to produce a surface of revolution.
//
// Fixtures use prim.arc (faceless wire) via /api/reset?empty=true so the
// arc is the ONLY geometry — reset leaves no default cube, and prim.arc
// APPENDS to whatever is in the scene, so an empty-reset is required.
//
// Key invariants under test:
//   360° open-profile sweep:
//     faces   == segments * count
//     vertices == (segments+1) * count        (no seam dup)
//     all faces are quads
//     boundary edges == 2 * count             (two open rims)
//
//   Partial arc open-profile sweep:
//     faces == segments * (count-1)           (open-arc inclusive endpoints)
//
//   Closed-profile (polygon) sweep:
//     faces == sides * count                  (closed ring, no cap)
//
//   Rejection:
//     count < 2          → status == "error", mesh unchanged
//     empty edge sel     → status == "error", mesh unchanged
//
//   Undo round-trip:
//     history.undo restores pre-sweep vertex and face counts

import http_client : testBaseUrl, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import batchless_control_helpers;

void main() {}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

alias BASE = testBaseUrl;


void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

void setSelection(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices)
        idxJson ~= (i > 0 ? "," : "") ~ v.to!string;
    idxJson ~= "]";
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

JSONValue model() {
    return parseJSON(cast(string)get(BASE ~ "/api/model"));
}

long vertCount() { return model()["vertexCount"].integer; }
long faceCount() { return model()["faces"].array.length; }

// face-vertex-count histogram, e.g. {4: 24}.
int[int] fvDist(JSONValue m) {
    int[int] h;
    foreach (f; m["faces"].array) h[cast(int)f.array.length] += 1;
    return h;
}

// Count boundary edge incidences: edges appearing in only one face.
// (Built from the face list, so it works on any mesh JSON returned by /api/model.)
long boundaryEdgeCount(JSONValue m) {
    int[string] inc;
    foreach (f; m["faces"].array) {
        auto vs = f.array;
        foreach (k; 0 .. vs.length) {
            long a = vs[k].integer, b = vs[(k + 1) % vs.length].integer;
            if (a > b) { auto tmp = a; a = b; b = tmp; }
            string key = a.to!string ~ "_" ~ b.to!string;
            inc[key]++;
        }
    }
    long cnt = 0;
    foreach (v; inc.values) if (v == 1) cnt++;
    return cnt;
}

// Reset to empty mesh (no default cube), then build an arc with `segs` segments
// along the Y axis (axis=1).  Results in segs+1 verts and segs edges at indices
// 0 .. segs-1.
void buildArc(int segs) {
    postJson("/api/reset?empty=true", "");
    cmd(`{"id":"prim.arc","segments":` ~ segs.to!string ~ `,"axis":1}`);
}

// Build a 4-vert closed quad profile in the XZ plane via /api/load-mesh.
// The four verts sit at unit radius from the Y axis; the single quad face
// is at index 0.  Call setSelection("polygons",[0]) after to activate it.
void buildClosedQuadProfile() {
    // load-mesh replaces the current mesh entirely; no reset required, but
    // an explicit reset first keeps the mode clean.
    postJson("/api/reset?empty=true", "");
    auto r = postJson("/api/command", commandBody("scene.loadMesh", `{
        "vertices": [[1,0,0],[0,0,1],[-1,0,0],[0,0,-1]],
        "faces": [[0,1,2,3]]
    }`));
    assert(r["status"].str == "ok", "buildClosedQuadProfile /api/load-mesh failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// test 1: 360° sweep of open arc profile — tube of revolution
// ---------------------------------------------------------------------------

unittest {
    // Arc: 4 segments → 5 verts, 4 edges (indices 0..3).
    // Sweep 360° with count=6:
    //   faces   = 4 * 6 = 24
    //   vertices = 5 * 6 = 30   (no seam duplicate for 360° closed sweep)
    //   boundary edges = 2 * 6 = 12  (two open rims, each a hexagon)
    immutable int segs  = 4;
    immutable int count = 6;

    buildArc(segs);
    // Select all arc edges (indices 0..segs-1) in edge mode.
    int[] arcEdges;
    foreach (i; 0 .. segs) arcEdges ~= i;
    setSelection("edges", arcEdges);

    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":6.2831853}`);

    auto m = model();
    long wantFaces = segs * count;
    long wantVerts = (segs + 1) * count;
    long wantBdry  = 2 * count;

    assert(m["faces"].array.length == wantFaces,
        "360° sweep: expected " ~ wantFaces.to!string ~ " faces, got "
        ~ m["faces"].array.length.to!string);
    assert(m["vertexCount"].integer == wantVerts,
        "360° sweep: expected " ~ wantVerts.to!string ~ " verts, got "
        ~ m["vertexCount"].integer.to!string);

    // All faces must be quads.
    assert(fvDist(m).get(4, 0) == wantFaces,
        "360° sweep: all faces must be quads");

    // Two open rims (one per arc endpoint, each of length `count`).
    long bdry = boundaryEdgeCount(m);
    assert(bdry == wantBdry,
        "360° sweep: expected " ~ wantBdry.to!string ~ " boundary edges, got "
        ~ bdry.to!string);
}

// ---------------------------------------------------------------------------
// test 2: partial arc (90°) sweep — open patch, more boundary
// ---------------------------------------------------------------------------

unittest {
    // Arc: 4 segments.  Open 90° sweep with count=4:
    //   stepAngle = (π/2)/(count-1) — inclusive endpoints.
    //   faces   = segs * (count-1) = 4 * 3 = 12
    //   vertices = (segs+1) * count = 5 * 4 = 20
    immutable int segs  = 4;
    immutable int count = 4;

    buildArc(segs);
    int[] arcEdges;
    foreach (i; 0 .. segs) arcEdges ~= i;
    setSelection("edges", arcEdges);

    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":1.5707963}`);   // π/2

    auto m = model();
    long wantFaces = segs * (count - 1);
    long wantVerts = (segs + 1) * count;

    assert(m["faces"].array.length == wantFaces,
        "90° sweep: expected " ~ wantFaces.to!string ~ " faces, got "
        ~ m["faces"].array.length.to!string);
    assert(m["vertexCount"].integer == wantVerts,
        "90° sweep: expected " ~ wantVerts.to!string ~ " verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(fvDist(m).get(4, 0) == wantFaces, "90° sweep: all faces must be quads");
}

// ---------------------------------------------------------------------------
// test 3: 360° sweep of a closed polygon profile (polygon mode)
// ---------------------------------------------------------------------------

unittest {
    // 4-vert closed quad profile at unit radius from Y axis (from /api/load-mesh).
    // Sweep 360° with count=8:
    //   faces    = 4 * 8 = 32  (closed profile → `count` bridge steps)
    //   vertices = 4 * 8 = 32  (no seam dup; closed sweep reuses ring[0])
    //   boundary = 0            (watertight toroid)
    immutable int sides = 4;
    immutable int count = 8;

    buildClosedQuadProfile();
    setSelection("polygons", [0]);

    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":6.2831853}`);

    auto m = model();
    long wantFaces = sides * count;
    long wantVerts = cast(long)(sides) * count;

    assert(m["faces"].array.length == wantFaces,
        "closed-profile 360°: expected " ~ wantFaces.to!string ~ " faces, got "
        ~ m["faces"].array.length.to!string);
    assert(m["vertexCount"].integer == wantVerts,
        "closed-profile 360°: expected " ~ wantVerts.to!string ~ " verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(fvDist(m).get(4, 0) == wantFaces,
        "closed-profile 360°: all faces must be quads");

    // Watertight: no boundary edges.
    long bdry = boundaryEdgeCount(m);
    assert(bdry == 0,
        "closed-profile 360°: expected 0 boundary edges (watertight), got "
        ~ bdry.to!string);
}

// ---------------------------------------------------------------------------
// test 4: rejection — count < 2 → error, mesh unchanged
// ---------------------------------------------------------------------------

unittest {
    immutable int segs = 3;
    buildArc(segs);
    int[] arcEdges;
    foreach (i; 0 .. segs) arcEdges ~= i;
    setSelection("edges", arcEdges);

    long vertsBefore = vertCount();
    long facesBefore = faceCount();

    auto r = postJson("/api/command",
        `{"id":"mesh.sweep","count":1,"axis":"Y","angle":6.2831853}`);
    assert(r["status"].str != "ok",
        "count=1 rejection: expected non-ok status, got " ~ r.toString);

    assert(vertCount() == vertsBefore, "count=1 rejection: vertex count must be unchanged");
    assert(faceCount() == facesBefore, "count=1 rejection: face count must be unchanged");
}

// ---------------------------------------------------------------------------
// test 5: rejection — empty edge selection → error, mesh unchanged
// ---------------------------------------------------------------------------

unittest {
    buildArc(3);
    // Switch to edge mode but select NO edges.
    setSelection("edges", []);

    long vertsBefore = vertCount();
    long facesBefore = faceCount();

    auto r = postJson("/api/command",
        `{"id":"mesh.sweep","count":6,"axis":"Y","angle":6.2831853}`);
    assert(r["status"].str != "ok",
        "empty-sel rejection: expected non-ok status, got " ~ r.toString);

    assert(vertCount() == vertsBefore, "empty-sel rejection: vertex count must be unchanged");
    assert(faceCount() == facesBefore, "empty-sel rejection: face count must be unchanged");
}

// ---------------------------------------------------------------------------
// test 6: undo round-trip
// ---------------------------------------------------------------------------

unittest {
    immutable int segs  = 4;
    immutable int count = 5;

    buildArc(segs);
    long vertsBefore = vertCount();   // segs+1 = 5
    long facesBefore = faceCount();   // 0

    int[] arcEdges;
    foreach (i; 0 .. segs) arcEdges ~= i;
    setSelection("edges", arcEdges);

    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":6.2831853}`);

    // Confirm sweep ran.
    assert(faceCount() > facesBefore, "undo test: sweep must produce faces");

    // Undo.
    cmd(`{"id":"history.undo"}`);

    assert(vertCount() == vertsBefore,
        "undo: expected " ~ vertsBefore.to!string ~ " verts, got "
        ~ vertCount().to!string);
    assert(faceCount() == facesBefore,
        "undo: expected " ~ facesBefore.to!string ~ " faces, got "
        ~ faceCount().to!string);
}

// ---------------------------------------------------------------------------
// test 7: the COMMIT SEAM of mesh.sweep (task 1903 Stage E2).
//
// These cells are invisible to every other test in this file: the surface a
// sweep produces is byte-identical whether or not the kernel runs inside a
// batch. What separates those worlds is the change-bus counters at
// /api/changes.
//
// WHAT E2 CHANGED, AND WHY BOTH PROFILE KINDS ARE HERE. Until Stage E2
// `revolveProfileEx` was a `mixin` inside `struct Mesh` that called the
// already-converted `bridgeLoopsPaired`, so it had to open a TRANSITIONAL
// `MeshEditBatch` of its own — and Stage D3's review narrowed that block to the
// CLOSED-profile arm alone, because the open arm bridges its strip with a plain
// `addFace` loop and calls no Bridge kernel. The two arms therefore lived in
// different worlds: measured over /api/changes, `unbatchedGeometryCommits` per
// `mesh.sweep` was +22 on the closed profile and +49 on the open one. E2 gives
// the kernel a `ref MeshEditBatch` receiver, `commands/mesh/sweep.d` opens the
// batch at the command boundary, and BOTH arms defer to one `close()`.
//
// So the OPEN-profile cell below is the one that could not have passed before
// this stage, and the CLOSED ones are D3's tripwire kept alive in its finished
// form: `nestedBatchOpens` must still be 0, but now because there is exactly
// ONE batch and the kernel opens none — not because the kernel's own batch
// happened to be the outermost.
//
// THREE CELLS, NOT TWO, AND THE THIRD IS WHY. A closed profile can arrive two
// ways: as a selected polygon (which the command deletes after sweeping) or as
// a closed EDGE CYCLE (which it does not). Only the edge-cycle form measures
// the KERNEL alone; the polygon form still carries the deletion's two commits,
// outside the batch by this command's own choice. Measuring both is what makes
// "+2" attributable — see cell (3).
//
// THE MUTATIONS THAT REDDEN THEM:
//   * put the transitional block back inside `revolveProfileEx`
//     (`auto ringEd = MeshEditBatch.unrecorded(ed.mesh, kRevolveEditScope);`
//     around the closed arm's ring loop, `ringEd.close();` after it) → the
//     closed cell's `nestedBatchOpens` delta becomes 1 and it reddens by name;
//   * delete the `auto ed = MeshEditBatch.unrecorded(…)` / `ed.close()` pair in
//     `commands/mesh/sweep.d` → a compile error, because the kernel's receiver
//     IS the enforcement. To reach the counters instead, break
//     `Mesh.commitChange`'s deferral (`if (auto f = currentBatchFrame(&this))`
//     → `if (false) if (…)`) and both `unbatchedGeometryCommits` cells redden.
//
// WHY A DELTA HERE AND NOT THE `== 0` IN test_undo_tracker_delete.d: that one
// is a single end-of-test read of a process-cumulative counter, in a test that
// never runs `mesh.sweep` — and at `-j 8` it is a different process (task 1903
// Stage D3 review MAJOR-1, measured on the thicken twin).
// ---------------------------------------------------------------------------

long busCounter(string key) {
    auto j = parseJSON(cast(string)get(BASE ~ "/api/changes"));
    return j[key].integer;
}

unittest { // mesh.sweep runs its kernel inside ONE caller-held edit batch
    // POSITIVE CONTROL, and it is not decoration. Every assertion below is
    // "this counter did not move", and a dead counter — the g_isDocumentMesh
    // predicate uninstalled, the endpoint reading a stale copy — satisfies that
    // for free. So make the SAME counter move first, with a command that is
    // deliberately still batchless — `kBatchlessControlCommand`, which lives
    // in tests/batchless_control_helpers.d because the answer has moved five
    // times,
    // exactly as mesh.sweep's open-profile arm did before Stage E2.
    postJson("/api/reset", "");          // the default cube, so triple has work
    setSelection("polygons", []);
    // `batchLeaks` / `batchUpgradeRefusals` are PROCESS-CUMULATIVE, like every
    // other counter this file reads: the app instance is shared with every
    // other test in the run, so an absolute `== 0` at the bottom is a claim
    // about the whole session and not about `mesh.sweep`. Sample them here and
    // assert the DELTA — the same discipline this block's header states for
    // the two counters it already sampled (Stage E2 review, MINOR m5).
    immutable long leaks0    = busCounter("batchLeaks");
    immutable long refusals0 = busCounter("batchUpgradeRefusals");
    immutable long ctl0 = busCounter("unbatchedGeometryCommits");
    foreach (c; kBatchlessControlSeq) cmd(c);
    immutable long ctrl = busCounter("unbatchedGeometryCommits") - ctl0;
    assert(ctrl > 0,
        kBatchlessControlWhy ~ ctrl.to!string ~ kBatchlessControlFix);

    // (1) CLOSED profile reached through an EDGE CYCLE. This is the
    // DISCRIMINATING cell of the three: it runs the arm that carried the D3
    // transitional batch, and because the profile arrives as edges there is no
    // source FACE to delete afterwards — so the delta measures the kernel and
    // nothing else. Without it, cell (3)'s "+2" could equally be a kernel that
    // leaks two commits and a deletion that leaks none.
    immutable int sides = 4;
    immutable int count = 8;
    buildClosedQuadProfile();
    setSelection("edges", [0, 1, 2, 3]);

    immutable long nested0    = busCounter("nestedBatchOpens");
    immutable long unbatched0 = busCounter("unbatchedGeometryCommits");
    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":6.2831853}`);
    immutable long nestedCycle    = busCounter("nestedBatchOpens") - nested0;
    immutable long unbatchedCycle = busCounter("unbatchedGeometryCommits")
                                  - unbatched0;

    assert(nestedCycle == 0,
        "mesh.sweep (closed edge-cycle profile) moved "
      ~ "changeBus.nestedBatchOpens by " ~ nestedCycle.to!string
      ~ ", expected 0. Since task 1903 Stage E2 the ONLY batch on this path is "
      ~ "the one commands/mesh/sweep.d opens: `revolveProfileEx` takes a "
      ~ "`ref MeshEditBatch` and opens nothing of its own. A non-zero delta "
      ~ "means a kernel opened one again — most likely the D3 transitional "
      ~ "block around the closed arm's ring loop, reinstated. Kernels do not "
      ~ "open batches (plan §2.3 rule 2); the boundary does (§4.1).");
    assert(unbatchedCycle == 0,
        "mesh.sweep (closed edge-cycle profile) made "
      ~ unbatchedCycle.to!string ~ " UNBATCHED geometry commit(s), expected 0. "
      ~ "This profile runs the CLOSED arm and deletes no source face, so the "
      ~ "delta is the kernel's own contribution and nothing else: every commit "
      ~ "it makes must defer into the caller's frame and stamp once at close(). "
      ~ "MEASURED on this exact cell with the batch taken away (Mesh."
      ~ "commitChange's deferral disabled): +60 (task 1903 Stage E2, plan "
      ~ "§3.2 L2).");
    assert(faceCount() == sides * count + 1,
        "sweep seam probe (edge cycle): expected " ~ (sides * count + 1).to!string
      ~ " faces (the swept band plus the original profile face, which edge mode "
      ~ "does not delete), got " ~ faceCount().to!string
      ~ " — the command did not run, so the deltas above were measured across "
      ~ "nothing");

    // (2) OPEN profile — the arm D3 deliberately left committing per face, and
    // the cell that could not have passed before Stage E2.
    immutable int segs     = 4;
    immutable int arcCount = 6;
    buildArc(segs);
    int[] arcEdges;
    foreach (i; 0 .. segs) arcEdges ~= i;
    setSelection("edges", arcEdges);

    immutable long nested1    = busCounter("nestedBatchOpens");
    immutable long unbatched1 = busCounter("unbatchedGeometryCommits");
    cmd(`{"id":"mesh.sweep","count":` ~ arcCount.to!string ~
        `,"axis":"Y","angle":6.2831853}`);
    immutable long nestedOpen    = busCounter("nestedBatchOpens") - nested1;
    immutable long unbatchedOpen = busCounter("unbatchedGeometryCommits")
                                 - unbatched1;

    assert(nestedOpen == 0,
        "mesh.sweep (open profile) moved changeBus.nestedBatchOpens by "
      ~ nestedOpen.to!string ~ ", expected 0 (task 1903 Stage E2).");
    assert(unbatchedOpen == 0,
        "mesh.sweep (open profile) made " ~ unbatchedOpen.to!string
      ~ " UNBATCHED geometry commit(s), expected 0. This is the arm Stage D3 "
      ~ "could not cover — its transitional batch was narrowed to the CLOSED "
      ~ "profile, so the open strip kept committing once per addFace. MEASURED "
      ~ "on this exact cell: +49 before Stage E2, and +49 again with the batch "
      ~ "taken away (Mesh.commitChange's deferral disabled) — the two agree "
      ~ "because this arm never had a batch at all. E2 hands the kernel the "
      ~ "caller's batch and both arms defer to one close() (task 1903 Stage E2, "
      ~ "plan §3.2 L2).");
    assert(faceCount() == segs * arcCount,
        "sweep seam probe (open): expected " ~ (segs * arcCount).to!string
      ~ " faces, got " ~ faceCount().to!string
      ~ " — the command did not run, so the deltas above were measured across "
      ~ "nothing");

    // (3) CLOSED profile in POLYGON mode — the same kernel, plus the one thing
    // this command still does OUTSIDE the batch: it deletes the source profile
    // face after the sweep. That deletion reads +2 where cell (1) read 0.
    //
    // WHICH TWO, traced at the tick site (`Mesh.commitChange`'s
    // `++changeBus.unbatchedGeometryCommits`, printing `flags`) on this exact
    // cell: `0x4` then `0x6` — Polygons, from `deleteFacesByMask`'s own
    // `rebuildEdges()` (whose `inserted` arm commits Polygons itself), then
    // Geometry, from the primitive's tail commit. `compactUnreferenced` is NOT
    // one of them: it early-returns at `removed == 0` BEFORE its own commit,
    // because `mesh.sweep` leaves `startAngle` at 0 and `revolveProfileEx`
    // then makes ring 0 REUSE the profile's own vertices — so deleting the
    // profile face orphans nothing. It would commit (Points, `0x2`, plus a
    // second Polygons from its internal `rebuildEdges`) on a deletion that DID
    // orphan a vertex: `RadialSweepTool`'s non-zero Start Angle path rotates
    // ring 0 away from the profile and reads +4 on the same call, measured.
    //
    // The number is MEASURED, not budgeted, and it is asserted exactly rather
    // than as "> 0" so that a THIRD unbatched commit appearing here — a kernel
    // regression, or a new post-kernel write — cannot hide inside it.
    //
    // STAGE L10-e FLIPPED THIS, and the flip is why the expectation below is
    // 0 rather than 2. Stage E2 left the deletion outside the batch on
    // purpose — folding it in would have been a second edit hiding inside a
    // move, the rule D3's review had to apply to its own transitional block —
    // and wrote the number down so this line would redden BY DESIGN when the
    // deletion moved in. It has: `commands/mesh/sweep.d` now runs
    // `ed.deleteFacesByMask` inside the same frame as `revolveProfile`,
    // because the command's undo is an op-log delta and a delta recorded
    // across the appends alone says NOTHING about the deletion.
    //
    // WHAT THE 0 IS NOT: it is not "the counter died". Cell (1) above reads 0
    // through a path that deletes no face at all, so a dead counter would read
    // 0 in both and prove nothing — which is why THIS block also asserts the
    // op-log delta below, a channel that was 0 before this stage and is 3 now.
    buildClosedQuadProfile();
    setSelection("polygons", [0]);

    immutable long nested2    = busCounter("nestedBatchOpens");
    immutable long unbatched2 = busCounter("unbatchedGeometryCommits");
    immutable long opLog2     = busCounter("opLogEntriesRecorded");
    cmd(`{"id":"mesh.sweep","count":` ~ count.to!string ~
        `,"axis":"Y","angle":6.2831853}`);
    immutable long nestedPoly    = busCounter("nestedBatchOpens") - nested2;
    immutable long unbatchedPoly = busCounter("unbatchedGeometryCommits")
                                 - unbatched2;

    assert(nestedPoly == 0,
        "mesh.sweep (closed polygon profile) moved changeBus.nestedBatchOpens "
      ~ "by " ~ nestedPoly.to!string ~ ", expected 0 (task 1903 Stage E2).");
    assert(unbatchedPoly == 0,
        "mesh.sweep (closed polygon profile) made " ~ unbatchedPoly.to!string
      ~ " UNBATCHED geometry commit(s), expected exactly 0 as of task 1903 "
      ~ "Stage L10-e. Until that stage this read exactly 2, traced at the tick "
      ~ "site as flags 0x4 then 0x6: the rebuildEdges() inside "
      ~ "deleteFacesByMask (Polygons) and that primitive's tail commit "
      ~ "(Geometry), which the command ran AFTER the batch closed. NOT "
      ~ "compactUnreferenced: it early-returns here, because startAngle is 0 "
      ~ "and ring 0 reuses the profile's own vertices, so the deletion orphans "
      ~ "none. MEASURED on this exact cell with the batch taken away "
      ~ "(Mesh.commitChange's deferral disabled): +62. A NON-ZERO here now "
      ~ "means the deletion has left the frame again — and with it the op-log "
      ~ "entry that inverts it, so mesh.sweep's undo would stop restoring the "
      ~ "profile face while every count still round-tripped.");
    assert(faceCount() == sides * count,
        "sweep seam probe (polygon): expected " ~ (sides * count).to!string
      ~ " faces, got " ~ faceCount().to!string
      ~ " — the command did not run, so the deltas above were measured across "
      ~ "nothing");

    // (4) The batches closed cleanly, and the polygon-mode sweep RECORDED an
    // op-log — three entries, measured. Until Stage L10-e undo for
    // `mesh.sweep` was a whole-mesh MeshSnapshot and both callers opened
    // UNRECORDED batches, so this delta was 0.
    //
    // It is the second, independent channel on the same change as the 0
    // above: the counter delta says the deletion is inside the frame, this
    // says the frame is RECORDING. A dead `unbatchedGeometryCommits` would
    // satisfy the first and not the second.
    immutable long opLogPoly = busCounter("opLogEntriesRecorded") - opLog2;
    assert(opLogPoly == 3,
        "mesh.sweep (closed polygon profile) recorded " ~ opLogPoly.to!string
      ~ " op-log entrie(s), expected exactly 3 (task 1903 Stage L10-e: "
      ~ "AddVerts + AddFaces from revolveProfile, RemoveFaces from the profile "
      ~ "deletion now inside the same frame). A 0 means the batch went back to "
      ~ "UNRECORDED and mesh.sweep's undo restores nothing; a different "
      ~ "non-zero means the kernel's entry shape moved and the undo needs "
      ~ "re-measuring, not re-baselining.");
    immutable long leaksDelta    = busCounter("batchLeaks")            - leaks0;
    immutable long refusalsDelta = busCounter("batchUpgradeRefusals") - refusals0;
    assert(leaksDelta == 0,
        "changeBus.batchLeaks moved by " ~ leaksDelta.to!string
      ~ " across this block's three sweeps, expected 0 — a MeshEditBatch "
      ~ "handle was destroyed while still open, i.e. an exception escaped "
      ~ "between the open and the close (task 1903 §2.2c). Read as a DELTA "
      ~ "against the sample taken at the top of this block: the counter is "
      ~ "process-cumulative and every other test in the run shares this "
      ~ "instance, so an absolute == 0 would fail on someone else's leak and "
      ~ "pass on our own if the run order changed.");
    assert(refusalsDelta == 0,
        "changeBus.batchUpgradeRefusals moved by " ~ refusalsDelta.to!string
      ~ " across this block's three sweeps, expected 0 (task 1903 §2.3 "
      ~ "rule 3). A DELTA, for the same reason as batchLeaks above.");
}
