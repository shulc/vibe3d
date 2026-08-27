// Task 1903 §L0-d, witness W-d6 — the mesh-edit SEAM counters across each of
// the nine migrated position commands.
//
// WHY DELTAS AND NEVER ABSOLUTES. Every counter on `/api/changes` is
// PROCESS-CUMULATIVE: `/api/reset` does not zero them, and the boot sequence
// plus whatever ran before this file in the same worker has already moved them.
// An absolute assert here would be a test of the run ORDER (памятка 7).
//
// WHAT EACH ROW IS WORTH — and one of them is worth LESS than the plan assumed,
// which is said here rather than left for a reader to discover:
//
//   batchLeaks        LIVE. `~MeshEditBatch` pops a leaked frame and ticks
//                     this; it is the observable behind §2.4's rule that every
//                     guard, `return false` and `throw` is resolved BEFORE the
//                     batch opens. `vertex_set`'s unknown-axis `throw` is the
//                     one concrete site, and the last block drives it.
//   nestedBatchOpens  LIVE. These commands open a batch from `evaluate`; a
//                     caller that already held one would make the inner open
//                     nest, and a RECORDING open inside an UNRECORDED one is
//                     refused outright (`batchUpgradeRefusals`).
//   missedPublishers  LIVE. `app.d`'s flush block compares each document mesh
//                     against its own `stampedVersion_`; a bump that did not
//                     go through the funnel ticks it.
//   opLogEntriesRecorded  LIVE, and it is the only SUITE-tier proof that these
//                     commands record anything at all. It must GROW.
//   unbatchedGeometryCommits  MEASURED VACUOUS FOR THIS FAMILY, and the plan
//                     listed it as a live row. `MeshEditScope.Geometry` is
//                     `Points | Polygons` and these nine publish `Position`
//                     ALONE, so the counter's own `flags & Geometry` guard was
//                     already false before the migration and is false after it.
//                     The row is kept — a command that starts publishing a
//                     Geometry class outside a batch is exactly what it is for
//                     — but it is NOT evidence that this stage moved anything,
//                     and quoting it as such would be a check that cannot come
//                     out differently.
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.stdio  : writefln;

void main() {}

enum BASE = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string)get(BASE ~ path)); }
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(BASE ~ path, body_));
}

struct Seam {
    long batchLeaks, nestedBatchOpens, missedPublishers;
    long unbatchedGeometryCommits, batchUpgradeRefusals, opLogEntriesRecorded;
}

Seam seam() {
    auto j = getJson("/api/changes");
    Seam s;
    s.batchLeaks               = j["batchLeaks"].integer;
    s.nestedBatchOpens         = j["nestedBatchOpens"].integer;
    s.missedPublishers         = j["missedPublishers"].integer;
    s.unbatchedGeometryCommits = j["unbatchedGeometryCommits"].integer;
    s.batchUpgradeRefusals     = j["batchUpgradeRefusals"].integer;
    s.opLogEntriesRecorded     = j["opLogEntriesRecorded"].integer;
    return s;
}

void ok(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

/// A grid plane with three interior vertices pushed off it, so `smooth` and
/// `linear_align` are not the identity on this stand (see the unit file's
/// `standMesh` for why a flat uniform grid cannot exhibit them).
void standMesh() {
    postJson("/api/reset", "");
    // A 4x4 vertex grid (3x3 quads) in the XY plane, loaded explicitly rather
    // than built from a primitive command, so this file drives exactly the
    // nine commands it is measuring and nothing else contributes op-log
    // entries to the deltas below.
    enum int N = 3;
    string verts = "[";
    foreach (j; 0 .. N + 1)
        foreach (i; 0 .. N + 1) {
            if (i || j) verts ~= ",";
            // Three interior vertices pushed OFF the plane, and that is the
            // whole reason this is not a flat grid: on a uniform planar grid
            // the discrete laplacian of an interior vertex IS that vertex, so
            // `mesh.smooth` is the identity and its `opLogEntriesRecorded`
            // delta would be 0 for a reason that has nothing to do with the
            // migration. It also breaks collinearity for `linear_align`.
            double z = 0.0;
            const int vi = j * (N + 1) + i;
            if (vi == 5) z =  0.37;
            if (vi == 6) z = -0.23;
            if (vi == 9) z =  0.19;
            verts ~= format("[%.6f,%.6f,%.6f]",
                            -1.0 + 2.0 * i / N, -1.0 + 2.0 * j / N, z);
        }
    verts ~= "]";
    string faces = "[";
    foreach (j; 0 .. N)
        foreach (i; 0 .. N) {
            if (i || j) faces ~= ",";
            const int a = j * (N + 1) + i;
            faces ~= format("[%d,%d,%d,%d]", a, a + 1, a + N + 2, a + N + 1);
        }
    faces ~= "]";
    auto r = postJson("/api/load-mesh",
                      format(`{"vertices":%s,"faces":%s}`, verts, faces));
    assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
    ok("select.typeFrom vertex");
}

/// The index in `edges[]` of the edge joining `a` and `b`, read off
/// `/api/model` rather than assumed. `~0` is impossible here and asserts.
int edgeIndexByEnds(int a, int b) {
    auto es = getJson("/api/model")["edges"].array;
    foreach (i, e; es) {
        const int x = cast(int)e.array[0].integer;
        const int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    assert(false, format("the stand has no edge %d-%d — its numbering "
                       ~ "changed and this cell would be sliding an edge "
                       ~ "picked at random", a, b));
}

void selectVerts(int[] idx) {
    string s = "[";
    foreach (i, v; idx) { if (i) s ~= ","; s ~= v.to!string; }
    s ~= "]";
    auto r = postJson("/api/select", `{"mode":"vertices","indices":` ~ s ~ `}`);
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
}

// The nine, each with the selection its kernel needs. `edge_slide` selects an
// EDGE; everything else a vertex set.
struct Drive { string label; void delegate() run; }

Drive[] drives() {
    return [
        Drive("mesh.smooth", {
            selectVerts([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]);
            ok(`{"id":"mesh.smooth","iter":2,"strn":0.8}`); }),
        Drive("mesh.jitter", {
            selectVerts([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]);
            ok(`{"id":"mesh.jitter","rangeX":0.2,"rangeY":0.2,"rangeZ":0.2,"seed":7}`); }),
        Drive("mesh.quantize", {
            selectVerts([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]);
            ok(`{"id":"mesh.quantize","X":0.3,"Y":0.3,"Z":0.3}`); }),
        Drive("mesh.magnet", {
            selectVerts([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]);
            ok(`{"id":"mesh.magnet","target":[6,0,0],"strength":0.5,"dist":100,"center":[0,0,0]}`); }),
        Drive("mesh.linear_align", {
            selectVerts([4,5,6,7]);
            ok(`{"id":"mesh.linear_align","weight":1.0}`); }),
        Drive("mesh.radial_align", {
            selectVerts([4,5,6,7]);
            ok(`{"id":"mesh.radial_align","weight":1.0}`); }),
        Drive("mesh.centerVertices", {
            selectVerts([1,5,6,9]);
            ok(`{"id":"mesh.centerVertices","axis":"y"}`); }),
        Drive("mesh.setPosition", {
            selectVerts([1,5,6,9]);
            ok(`{"id":"mesh.setPosition","axis":"z","value":0.25}`); }),
        Drive("mesh.edge_slide", {
            ok("select.typeFrom edge");
            // BY ENDPOINTS, not by a hardcoded index. An interior edge is
            // what has a rail on both sides; a boundary one slides nothing,
            // `touchedIdx` comes back empty, the delta is empty, and
            // `opLogEntriesRecorded` reads 0 for a reason that has nothing to
            // do with the migration. Measured: index 8 on this stand is such
            // an edge, and the first run of this file reddened on it.
            const int ei = edgeIndexByEnds(5, 6);
            auto r = postJson("/api/select",
                              format(`{"mode":"edges","indices":[%d]}`, ei));
            assert(r["status"].str == "ok", "edge select: " ~ r.toString);
            ok(`{"id":"mesh.edge_slide","t":0.6}`);
            ok("select.typeFrom vertex"); }),
    ];
}

// ---------------------------------------------------------------------------
// The nine, forward + undo + redo, one seam reading per command.
// ---------------------------------------------------------------------------
unittest {
    foreach (d; drives()) {
        standMesh();
        const before = seam();

        d.run();
        ok(`{"id":"history.undo"}`);
        ok(`{"id":"history.redo"}`);
        ok(`{"id":"history.undo"}`);

        const after = seam();
        const dLeaks   = after.batchLeaks               - before.batchLeaks;
        const dNested  = after.nestedBatchOpens         - before.nestedBatchOpens;
        const dMissed  = after.missedPublishers         - before.missedPublishers;
        const dUnbatch = after.unbatchedGeometryCommits - before.unbatchedGeometryCommits;
        const dRefuse  = after.batchUpgradeRefusals     - before.batchUpgradeRefusals;
        const dOps     = after.opLogEntriesRecorded     - before.opLogEntriesRecorded;

        writefln("[L0-d seam] %-20s leaks=%d nested=%d missed=%d "
               ~ "unbatched=%d refusals=%d ops=+%d",
                 d.label, dLeaks, dNested, dMissed, dUnbatch, dRefuse, dOps);

        assert(dLeaks == 0,
            format("%s: changeBus.batchLeaks moved by %d across "
                 ~ "forward+undo+redo+undo. A batch was left open — some guard, "
                 ~ "`return false` or `throw` sits BELOW the batch open instead "
                 ~ "of above it (task 1903 §L0-d §2.4). `~MeshEditBatch` pops "
                 ~ "the frame and ticks this rather than asserting, because it "
                 ~ "runs during unwinding and an Error there would replace the "
                 ~ "exception the command funnel is handling.",
                   d.label, dLeaks));
        assert(dNested == 0,
            format("%s: changeBus.nestedBatchOpens moved by %d. These commands "
                 ~ "open their batch from `evaluate`, which the funnel calls at "
                 ~ "batch depth 0; a non-zero means some caller now holds a "
                 ~ "batch across the command, and a RECORDING open inside an "
                 ~ "UNRECORDED one is refused outright — the delta would be "
                 ~ "`MeshEditDelta.init` and the undo would silently fall back "
                 ~ "to the legacy loop.", d.label, dNested));
        assert(dRefuse == 0,
            format("%s: changeBus.batchUpgradeRefusals moved by %d — a "
                 ~ "recording batch was opened inside an unrecorded one and "
                 ~ "the frame was marked errored, so `close()` handed back an "
                 ~ "EMPTY delta.", d.label, dRefuse));
        assert(dMissed == 0,
            format("%s: changeBus.missedPublishers moved by %d. A "
                 ~ "`mutationVersion` bump on a document mesh did not go "
                 ~ "through `commitChange`/`commitRestored` (CLAUDE.md's "
                 ~ "funnel law).", d.label, dMissed));
        assert(dUnbatch == 0,
            format("%s: changeBus.unbatchedGeometryCommits moved by %d. READ "
                 ~ "THE HEADER BEFORE TREATING A GREEN HERE AS EVIDENCE: this "
                 ~ "family publishes `Position`, which is NOT in "
                 ~ "`MeshEditScope.Geometry`, so this counter was 0 before the "
                 ~ "migration for a reason unrelated to it. The row guards "
                 ~ "against a future Geometry-class publish escaping the batch, "
                 ~ "nothing more.", d.label, dUnbatch));

        // THE ONE THAT MUST GROW. Every other row above is satisfied by a
        // command that records NOTHING — the counters it names all measure
        // absence. This is the suite-tier half of W-d3a.
        assert(dOps > 0,
            format("%s: changeBus.opLogEntriesRecorded did not move across "
                 ~ "forward+undo+redo+undo (delta %d). The command recorded no "
                 ~ "op-log entry at all and its undo fell back to the legacy "
                 ~ "revert — which restores the right positions, so every "
                 ~ "geometry assertion in the suite stays green. This counter "
                 ~ "and the op-log-shape cell in "
                 ~ "tests/unit/commands/mesh/position_delta_test.d are the only "
                 ~ "two checks that see it.", d.label, dOps));
    }
}

// ---------------------------------------------------------------------------
// THE MUTATION'S OWN CELL — `vertex_set`'s unknown-axis throw.
//
// Separate `unittest` block: druntime stops a module at its first failed
// assert, and the block above must be able to redden for its own reasons
// without hiding this one. The drill for W-d6 moves the batch open ABOVE the
// axis switch in `source/commands/mesh/vertex_set.d`; that makes the `throw`
// unwind through `~MeshEditBatch` and this `batchLeaks` delta reads 1.
// ---------------------------------------------------------------------------
unittest {
    standMesh();
    selectVerts([1,5,6,9]);
    const before = seam();

    auto r = postJson("/api/command",
                      `{"id":"mesh.setPosition","axis":"q","value":1.0}`);
    assert(r["status"].str == "error",
        "an unknown axis must answer status:error — the throw is the subject "
      ~ "of this cell and without it there is no unwind to measure: "
      ~ r.toString);

    const after = seam();
    const dLeaks = after.batchLeaks - before.batchLeaks;
    writefln("[L0-d seam] %-20s leaks=%d (the unknown-axis throw)",
             "mesh.setPosition/q", dLeaks);
    assert(dLeaks == 0,
        format("changeBus.batchLeaks moved by %d when `mesh.setPosition` "
             ~ "refused an unknown axis. The `throw` at the axis switch is "
             ~ "BELOW the batch open; §2.4 requires it above. The counter is "
             ~ "the only observable — the command still answers status:error "
             ~ "either way, the mesh is still untouched either way, and the "
             ~ "frame the destructor popped means every LATER `commitChange` "
             ~ "on this mesh would have deferred forever had it not popped.",
               dLeaks));
}
