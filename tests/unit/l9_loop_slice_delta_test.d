// l9_loop_slice_delta_test — the witnesses stage L9 owes that a frozen plane
// fixture cannot carry (task 1903 Stage L9; `undo_parity_l9_test.d` carries
// the plane-for-plane oracle, this file carries the SHAPE assertions).
//
// WHY THE SPLIT. `undo_parity_l9_test.d` compares two JSON dumps per cell.
// Four of the things this stage can get wrong are invisible in a dump:
//
//   * the op-log's KIND SEQUENCE. Stage J made the `[MeshMapDelta,
//     FaceReindex]` ADJACENCY contractual — `CornerCarry.payloadForCount`
//     binds by adjacency — so an interposed entry unpairs the corner restore
//     SILENTLY while the geometry round-trips. A dump of the reverted mesh
//     is identical either way as long as the payload happened to be
//     recoverable; a LENGTH assertion is satisfied by the broken log too.
//   * the multi-fragment corner restore at N >= 2. At N == 1 every fragment
//     restores slot for slot, so slot-for-slot IS correct there.
//   * `revert()` over an EMPTY delta answering `true`.
//   * which `MeshEditBatch` opens are RECORDING and which stay `unrecorded`.
//
// LANE. All of this is `dub test --config=tests` (lane U) — `./run_test.d`
// never runs a `tests/unit/**` unittest block. The COMMAND-CONSTRUCTOR half
// of the seam is in lane S (`tests/test_loop_slice_seam_counters.d`), because
// a unit cell that drives the KERNEL opens its own batch and stays green with
// the command still unrecorded.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score a mutation that
// reddens two of these cells by running them in isolation.
module tests.unit.l9_loop_slice_delta_test;

import std.conv   : to;
import std.format : format;

import command;
import mesh;
import mesh_edit_delta : MeshEditDelta;
import view;
import editmode;
import change_bus : changeBus;

import tests.unit.fixtures : makeTaggedGridFull, dumpMeshPlanes, diffMeshPlanes;
import commands.mesh.loop_slice : MeshAddLoop, MeshLoopSlice;

/// Edge 1 (`[1, 5]`) is interior on this stand; edge 0 (`[0, 1]`) is on the rim.
private enum uint kInteriorSeed = 1;

private Mesh* standSeeded(uint seed)
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    m.selectFace(0);
    m.clearEdgeSelection();
    m.selectEdge(seed);
    assert(m.isEdgeSelected(seed),
        format("the stand refused to select edge %d — every cell below would "
             ~ "then drive whichever edge happened to be selected", seed));
    return m;
}

private string kindsOf(in MeshEditDelta d)
{
    string s;
    foreach (i, ref e; d.log) s ~= (i ? " " : "") ~ e.kind.to!string;
    return s;
}

/// Every per-corner value of the UV map, flattened, as text.
private string uvOf(in Mesh m)
{
    auto uv = m.meshMap(kUvMapName);
    if (uv is null) return "<no map>";
    string s;
    foreach (i, f; uv.data) s ~= (i ? "," : "") ~ format("%.9g", f);
    return s;
}

// ---------------------------------------------------------------------------
// W-9-a3 — THE OP-LOG KIND SEQUENCE, at the COMMAND, at N = 1 and N = 3.
//
// MUTATION: interpose any entry between the `MeshMapDelta` and its
// `FaceReindex` (e.g. an extra `ed.setVertexPos` inside
// `insertEdgeLoopsMulti` between `recordPolyVertexPayload` and
// `rewriteFaces`). The geometry still round-trips and every plane dump still
// compares equal, because the payload is only consulted when it is ADJACENT —
// so nothing else in either lane reddens.
// ---------------------------------------------------------------------------
unittest
{
    foreach (count; [1, 3]) {
        auto m = standSeeded(kInteriorSeed);
        auto v = new View(0, 0, 800, 600);
        auto c = new MeshLoopSlice(m, v, EditMode.Edges);
        foreach (ref p; c.params()) if (p.name == "count") *p.iptr = count;

        assert(c.apply(), format("mesh.loopSlice count=%d refused the stand — "
                               ~ "every assertion below is then vacuous", count));

        immutable seq = kindsOf(c.recordedDelta());
        assert(seq == "AddVerts MeshMapDelta FaceReindex",
            format("mesh.loopSlice count=%d recorded [%s], expected "
                 ~ "[AddVerts MeshMapDelta FaceReindex]. The payload must be "
                 ~ "IMMEDIATELY BEFORE its face entry: `CornerCarry."
                 ~ "payloadForCount` binds by ADJACENCY, and an unpaired "
                 ~ "payload zeroes the per-corner map SILENTLY while the "
                 ~ "geometry round-trips and `revert()` still answers true",
                   count, seq));

        // …and the entry that carries the corner payload must not be empty,
        // or the sequence is right and the payload is a shell. The stand's
        // 36 corners grow to 45 (count=1) / 63 (count=3); the payload names
        // the PRE-op corner space, so it is 36 either way.
        assert(c.recordedDelta().log.length == 3,
            "the sequence matched but the log length did not — one of these "
          ~ "two assertions is wrong, which is a bug in this cell");
    }
}

// ---------------------------------------------------------------------------
// W-9-a2 — THE MULTI-FRAGMENT CORNER ROUND TRIP, value by value, at N = 3,
// with its N = 1 control beside it.
//
// WHAT THIS CELL IS, STATED HONESTLY, BECAUSE THE PLAN'S CLAIM FOR IT DIED ON
// MEASUREMENT. §5.5's L9 addendum promises a witness that is GREEN at N = 1
// and RED at N = 3 under "replace the payload lookup with a slot-for-slot
// copy off the first fragment". Measured 2026-08-28, both halves are false on
// this tree:
//
//   * THE REVERSE IS FRAGMENT-COUNT-BLIND. `CornerCarry.faceReindexReverse`
//     rebuilds each OLD face from the `MeshMapDelta` payload, which snapshots
//     the whole PRE-op corner space (`recordPolyVertexPayload(allOld)` in
//     `mesh_planes.rewriteFaces`) and is indexed by old face and running
//     corner base. It never consults a fragment. So no reverse-side mutation
//     can be N-sensitive, and the promised one is not expressible.
//   * SLOT-FOR-SLOT OFF THE FIRST FRAGMENT IS NOT CORRECT AT N = 1 EITHER.
//     Cutting a quad [a, b, c, d] gives [a, m0, m1, d] and [m0, b, c, m1] —
//     neither fragment holds all four original corners, so a first-fragment
//     copy loses two of them at N = 1 as well.
//
// So this is a COVERAGE cell, not a discriminating one, and it says so rather
// than posing as a witness. What it does buy: it drives the multi-fragment
// shape end to end (the reader `undo_parity_l9_test.d` asserts >= 3 fragments
// per crossed face for the N = 3 cell and EXACTLY 2 for the N = 1 control, so
// neither can silently become the other), it proves P0-L9-2's prediction —
// the N >= 2 corner round trip IS correct — and it freezes the N = 3 FORWARD
// in the fixture's `postOp`, which is the half a fragment-ordering regression
// would actually move.
//
// MUTATION THAT SCORES IT: delete the `recordPolyVertexPayload` call from
// `mesh_planes.rewriteFaces` (the Stage J publisher). Verbatim red, at the
// N = 1 arm first: "the per-corner UV plane did NOT come back … after :
// 0,0,0,…" — all 72 floats zeroed. W-9-a3 above reddens on the same
// mutation, so run them in isolation.
// ---------------------------------------------------------------------------
unittest
{
    foreach (count; [1, 3]) {
        auto m = standSeeded(kInteriorSeed);
        immutable preUv = uvOf(*m);
        immutable preV  = m.vertices.length;
        immutable preF  = m.faces.length;

        auto v = new View(0, 0, 800, 600);
        auto c = new MeshLoopSlice(m, v, EditMode.Edges);
        foreach (ref p; c.params()) if (p.name == "count") *p.iptr = count;
        assert(c.apply(), "the forward must apply");

        // The forward MOVED the plane — without this the round-trip below is
        // satisfied by an op that changed nothing.
        assert(uvOf(*m) != preUv,
            format("mesh.loopSlice count=%d left the per-corner UV plane "
                 ~ "exactly as it found it — a restore that does nothing then "
                 ~ "passes", count));
        assert(m.faces.length == preF + count * 3,
            format("mesh.loopSlice count=%d left F=%d, expected %d (3 crossed "
                 ~ "faces x %d new fragment boundaries) — if the cut did not "
                 ~ "cross three faces this cell is not measuring the "
                 ~ "multi-fragment case", count, m.faces.length,
                   preF + count * 3, count));

        assert(c.revert(), "the undo must succeed");
        assert(m.vertices.length == preV && m.faces.length == preF,
            format("count=%d: revert left V=%d F=%d, expected %d/%d",
                   count, m.vertices.length, m.faces.length, preV, preF));

        immutable postUv = uvOf(*m);
        if (postUv != preUv) {
            // Name the FIRST differing corner rather than dumping both.
            auto uv = m.meshMap(kUvMapName);
            size_t bad = size_t.max;
            auto pre = preUv, post = postUv;
            assert(uv !is null);
            assert(false, format(
                "mesh.loopSlice count=%d: the per-corner UV plane did NOT come "
              ~ "back.\n  before: %s\n  after : %s\nAt count=1 every fragment "
              ~ "restores slot-for-slot and this cell cannot fail; at count=3 "
              ~ "the corner on the far rail lives in the LAST fragment, which "
              ~ "is what the Stage J payload is for", count, pre, post));
        }
    }
}

// ---------------------------------------------------------------------------
// W-9-ROW8 — the closed F1 loss-list row 8 STAYS closed.
//
// `vertexSetMask` used to come back GROWN to the post-op length, which drops
// a whole named vertex set on the next reload. Stage L2-c closed it in
// `MeshEditDelta.finalize`. This is the family's own pin on it.
//
// MUTATION: delete `m.vertexSetMask.length = m.vertices.length;` from
// `mesh_edit_delta.finalize`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = standSeeded(kInteriorSeed);
    immutable preV    = m.vertices.length;
    immutable preMask = m.vertexSetMask.length;
    assert(preMask == preV, format(
        "the stand's vertexSetMask is %d long against %d vertices — this cell "
      ~ "measures a LENGTH and needs the two to agree at entry",
        preMask, preV));

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshLoopSlice(m, v, EditMode.Edges);
    assert(c.apply(), "the forward must apply");
    assert(m.vertices.length > preV, "the cut must have added vertices");
    assert(c.revert(), "the undo must succeed");

    assert(m.vertexSetMask.length == preV, format(
        "vertexSetMask came back %d long against %d vertices. Left GROWN, the "
      ~ "next `selSetMembersVertex` walk reads past the live vertex array and "
      ~ "a whole named set disappears on reload — F1 loss-list row 8, closed "
      ~ "at Stage L2-c in `MeshEditDelta.finalize`",
        m.vertexSetMask.length, preV));
}

// ---------------------------------------------------------------------------
// W-9-EMPTY — `MeshEditDelta.revert` over an EMPTY log answers `true` and
// changes nothing.
//
// THIS CELL MEASURES THE PRIMITIVE, NOT THE COMMAND'S GUARD, and it says so
// because the difference was measured rather than assumed. The plan's
// mutation for this witness is "add `if (delta_.log.length == 0) return
// false;` in front of `delta_.revert(*mesh)`" in the command — and on THIS
// family that mutation is INERT: `acceptRecordedEdit` drops the delta and
// leaves `recorded_` false whenever the log is empty, so a recorded
// `MeshLoopSlice` never holds one and the added line is unreachable. Run and
// confirmed green under that mutation, 2026-08-28.
//
// So the mutation that scores this cell is on the PRIMITIVE: add
// `if (log.length == 0) return false;` to `MeshEditDelta.revert`. That is
// where the prohibition actually lives — a `false` from a Model entry's
// `revert` pops the entry off BOTH history stacks and truncates the suffix
// after it (`command_history.d`, regression 0099) — and it is what L2, L3 and
// L5 all record. The command-level guard being unreachable here is a
// FINDING about this family, not a licence to leave the contract untested.
// ---------------------------------------------------------------------------
unittest
{
    auto m = standSeeded(kInteriorSeed);
    auto pre = dumpMeshPlanes(*m);

    MeshEditDelta empty;
    assert(empty.log.length == 0, "a default MeshEditDelta must have no log");
    assert(empty.revert(*m),
        "MeshEditDelta.revert answered FALSE over an empty log. It answers "
      ~ "true by construction, and every migrated command in this stage "
      ~ "relies on it: a `false` there is read by CommandHistory as a failed "
      ~ "undo and truncates the redo suffix");

    auto post = dumpMeshPlanes(*m);
    assert(diffMeshPlanes(pre, post) == "",
        "reverting an empty delta moved planes [" ~ diffMeshPlanes(pre, post)
      ~ "]");
}

// ---------------------------------------------------------------------------
// W-9-REF — THE REFUSAL, asserted rather than frozen.
//
// A refusing command leaves `postOp == postUndo == pre`, so a frozen pair of
// dumps for it is a check that cannot come out differently (stage L5 took the
// same decision, and this is the repeat of that argument). What CAN come out
// differently is what the refusal DOES.
//
// AND THE REFUSAL HERE IS PRE-BATCH, which the cell says in its own message
// rather than letting a `batchLeaks == 0` read as coverage of the recording
// path: both commands check the ring in a DRY RUN before the batch opens, so
// no `MeshEditBatch` is constructed on this path at all. The `!ok` arm — the
// one that CAN close a recording batch and then refuse — is unreachable from
// these two commands, because its only trigger inside
// `insertEdgeLoopsMulti` is the same `rings.length == 0` the dry run already
// caught. Its belt is asserted at the kernel instead, below.
// ---------------------------------------------------------------------------
unittest
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    m.clearEdgeSelection();          // NO seed edge -> `hasAnySelectedEdges` false
    auto pre = dumpMeshPlanes(*m);
    immutable ulong leaks0 = changeBus.batchLeaks;

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshLoopSlice(m, v, EditMode.Edges);

    assert(!c.apply(),
        "mesh.loopSlice APPLIED with no edge selected. `evaluate`'s "
      ~ "`hasAnySelectedEdges` arm is the refusal, and a command answering "
      ~ "true here lands a history entry describing no change");
    auto post = dumpMeshPlanes(*m);
    assert(diffMeshPlanes(pre, post) == "",
        "mesh.loopSlice refused and still moved the mesh: planes ["
      ~ diffMeshPlanes(pre, post) ~ "]");
    assert(changeBus.batchLeaks == leaks0, format(
        "mesh.loopSlice's refusal leaked %d edit frame(s). NOTE this refusal "
      ~ "is PRE-BATCH — no MeshEditBatch is constructed on it — so a green "
      ~ "here is NOT coverage of the recording path's unwind; it is the "
      ~ "assertion that the refusal stayed pre-flight",
        changeBus.batchLeaks - leaks0));
    assert(!c.revert(),
        "mesh.loopSlice's revert() answered TRUE after a refused forward — it "
      ~ "would then replay a belt that was never captured. Correct here ONLY "
      ~ "because the funnel never records the entry for a refused evaluate");
}

// ---------------------------------------------------------------------------
// P0-L9-3 — the kernel's own refusal records NOTHING, measured rather than
// read.
//
// `mesh_ops/loop_slice.d`'s seven refusal sites all claim to be pre-mutation.
// The commands' `!ok` belt (`delta_.revert` then discard) is written on that
// claim, so the claim gets an executable witness: a RECORDING batch over a
// refused cut must close with an EMPTY op-log.
//
// MUTATION: move `insertEdgeLoopsMulti`'s `positions.length == 0` bail after
// the first `getMids` call.
// ---------------------------------------------------------------------------
unittest
{
    import mesh_ops.loop_slice : insertEdgeLoops, kLoopSliceEditScope;

    auto m = standSeeded(kInteriorSeed);
    auto pre = dumpMeshPlanes(*m);

    MeshEditDelta d;
    bool ok;
    {
        auto ed = MeshEditBatch(*m, kLoopSliceEditScope);   // RECORDING
        ok = ed.insertEdgeLoops(kInteriorSeed, []);         // no positions
        d = ed.close();
    }
    assert(!ok, "insertEdgeLoops with no positions must refuse");
    assert(d.log.length == 0, format(
        "the refused cut recorded [%s]. Every refusal in this kernel is "
      ~ "supposed to be decided BEFORE the first geometry mutation; a "
      ~ "non-empty log here means one is not, and the command's `!ok` belt "
      ~ "stops being a belt and becomes load-bearing", kindsOf(d)));
    auto post = dumpMeshPlanes(*m);
    assert(diffMeshPlanes(pre, post) == "",
        "the refused cut moved planes [" ~ diffMeshPlanes(pre, post) ~ "]");
}

// ---------------------------------------------------------------------------
// W-9-b1 — `MeshAddLoop` is present and non-vacuous.
//
// "A class silently absent from a fixture is indistinguishable from a class
// that passes." `MeshAddLoop` is the mechanical half of the stage and its
// single-position cut cannot fail the way `MeshLoopSlice`'s N=3 can — which
// is exactly why it needs its own cell rather than being assumed covered.
//
// MUTATION: leave `MeshAddLoop`'s batch on the `unrecorded` constructor. The
// op-log comes back EMPTY and the KIND assertion names it; the plane fixture
// alone would still be green, because an unrecorded forward plus a
// `DenseSelectionUndo` restore leaves the CUT in place and the two dumps
// simply both change — which the anti-vacuity assert catches only by
// accident.
// ---------------------------------------------------------------------------
unittest
{
    auto m = standSeeded(kInteriorSeed);
    immutable preV = m.vertices.length;

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshAddLoop(m, v, EditMode.Edges);
    assert(c.apply(), "mesh.addLoop refused the stand");
    assert(m.vertices.length == preV + 4, format(
        "mesh.addLoop left V=%d, expected %d — one belt across three faces "
      ~ "adds four rail vertices on this stand", m.vertices.length, preV + 4));

    immutable seq = kindsOf(c.recordedDelta());
    assert(seq == "AddVerts MeshMapDelta FaceReindex", format(
        "mesh.addLoop recorded [%s], expected [AddVerts MeshMapDelta "
      ~ "FaceReindex]. An EMPTY log here means the batch is still the "
      ~ "`unrecorded` constructor and this class never migrated", seq));

    assert(c.isOperationInverse(),
        "mesh.addLoop reports itself as a whole-mesh snapshot in "
      ~ "/api/history's `opInverse` field after recording a delta");

    assert(c.revert(), "the undo must succeed");
    assert(m.vertices.length == preV, "the undo must restore the vertex count");
}

// ---------------------------------------------------------------------------
// W-9-SEAM (unit half) — WHICH batch opens are RECORDING and which stay
// `unrecorded`, keyed on the ENCLOSING FUNCTION so a line-number drift cannot
// move a row.
//
// WHY A CENSUS AND NOT A COUNTER. A recording batch opened on the per-frame
// PREVIEW path builds and discards a full op-log at 60 Hz. Nothing in either
// lane reddens on that — the preview's output is byte-identical either way —
// so the only instrument that can see it is the text of the call site.
//
// WHAT THE PLAN GOT WRONG HERE, and it is worth stating because the row was
// quoted as settled: §5.5's L9 row says "FIVE call sites open the batch … the
// last two must stay `unrecorded` when L9 flips the first three". The count is
// right and the LABELS are not — site 3 is `applyHeadless()` (the
// `tool.doApply` path, declined on axis 2 for opacity), NOT the tool's
// commit: `LoopSliceTool.commitEdit()` opens no batch and calls no kernel, it
// captures a `MeshSnapshot`. So TWO flip and THREE stay.
//
// AND THE MIGRATION ADDED TWO MORE `unrecorded` OPENS THAT NO ROW PREDICTED:
// each command's REDO arm re-runs the kernel batchless, which still needs a
// batch to defer the stamps. So the family's steady state is TWO recording
// opens and FIVE unrecorded ones, not two and three, and the table below says
// which is which by function.
//
// MUTATION: flip `rebuildCut`'s preview open to the recording constructor.
// The row for that function reddens by NAME. (Or delete a table row: the
// scanner then reports an unaccounted site.)
// ---------------------------------------------------------------------------
private struct SeamRow { string file; string func; size_t unrecorded; size_t recording; string why; }

private static immutable SeamRow[] kL9Seam = [
    SeamRow("source/commands/mesh/loop_slice.d", "evaluate", 2, 2,
        "MeshAddLoop and MeshLoopSlice: one RECORDING open each (the commit "
      ~ "path, stage L9-a/-b) and one UNRECORDED each (the redo arm, which "
      ~ "re-runs the kernel batchless and keeps the first delta)"),
    SeamRow("source/tools/slice/loop_slice_tool.d", "applyHeadless", 1, 0,
        "the `tool.doApply` path — declined on axis 2 for OPACITY (plan "
      ~ "§6.2 item 2), not because it cannot be recorded"),
    SeamRow("source/tools/slice/loop_slice_tool.d", "rebuildCut", 1, 0,
        "the per-frame interactive PREVIEW — plan §9: a recording batch here "
      ~ "builds and discards a full op-log at 60 Hz"),
    SeamRow("source/tools/edit/topology_pen/tool.d", "commitAddLoop", 1, 0,
        "Topology Pen's Add Loop — its own family, stage M / task 1905"),
];

unittest
{
    import std.array : appender;
    import std.file  : exists, readText;
    import std.path  : buildPath, dirName;
    import std.string: strip;
    import tests.unit.census_symbols : blankNonCode;

    enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

    // (file, func) -> [unrecorded, recording]
    size_t[2][string] found;
    size_t scannedBytes = 0;
    bool[string] seenPath;

    foreach (ref r; kL9Seam) {
        if (r.file in seenPath) continue;
        seenPath[r.file] = true;
        immutable abs = buildPath(repoRoot, r.file);
        assert(abs.exists, "the L9 seam census names " ~ r.file
                         ~ " and that file is gone — move the row(s)");
        immutable raw  = readText(abs);
        immutable code = blankNonCode(raw);
        scannedBytes += raw.length;

        // Brace-walk to the nearest enclosing CALLABLE. The header
        // accumulator resets on `{`, `}` and `;` and NOT on a newline — a
        // multi-line signature would otherwise lose its own start. This is
        // `revert_entry_census_test`'s heuristic, duplicated rather than
        // imported, which is the accepted pattern between census files (see
        // that file's own header). It only has to be DETERMINISTIC: a
        // misresolved site still reddens, because the pair it reports will
        // not be in the table.
        ScopeEntry[] stack;
        string header;
        size_t i = 0;
        void note(size_t which) {
            string fn = "<module-level>";
            foreach_reverse (ref e; stack) if (e.isFunc) { fn = e.name; break; }
            immutable key = r.file ~ "\0" ~ fn;
            auto p = key in found;
            if (p is null) { size_t[2] z = [0, 0]; z[which] = 1; found[key] = z; }
            else (*p)[which] += 1;
        }
        while (i < code.length) {
            immutable char c = code[i];
            if (c == '{') {
                immutable h = header.strip;
                stack ~= ScopeEntry(looksLikeFunc(h) ? nameOf(h) : h, looksLikeFunc(h));
                header = ""; ++i; continue;
            }
            if (c == '}') { if (stack.length) stack = stack[0 .. $ - 1];
                            header = ""; ++i; continue; }
            if (c == ';') { header = ""; ++i; continue; }

            // The statement this open belongs to, up to its `;`.
            if (code[i .. $].length > 14 && code[i .. i + 14] == "MeshEditBatch.") {
                size_t semi = i;
                while (semi < code.length && code[semi] != ';') ++semi;
                if (code[i .. semi].indexOfSub("kLoopSliceEditScope")
                 && code[i .. semi].indexOfSub("unrecorded(")) note(0);
            } else if (code[i .. $].length > 14
                    && code[i .. i + 14] == "MeshEditBatch(") {
                size_t semi = i;
                while (semi < code.length && code[semi] != ';') ++semi;
                if (code[i .. semi].indexOfSub("kLoopSliceEditScope")) note(1);
            }
            header ~= c;
            ++i;
        }
    }

    // Vacuity floor: a scanner that lost its place reports nothing and every
    // comparison below passes for the wrong reason.
    assert(scannedBytes >= 100_000, format(
        "the L9 seam scanner read only %d byte(s) over %d distinct path(s) — "
      ~ "the three files together are far larger, so the walk lost its place "
      ~ "and this census is vacuous. Fix the walk, do not lower the floor",
        scannedBytes, seenPath.length));
    assert(seenPath.length == 3, format(
        "the table names %d distinct path(s), expected 3 — a duplicated path "
      ~ "literal would leave a file unscanned and this census green forever",
        seenPath.length));

    auto bad = appender!string;
    foreach (ref r; kL9Seam) {
        immutable key = r.file ~ "\0" ~ r.func;
        auto p = key in found;
        immutable size_t u = p is null ? 0 : (*p)[0];
        immutable size_t g = p is null ? 0 : (*p)[1];
        if (u != r.unrecorded || g != r.recording)
            bad.put(format("\n    %s :: %s — recorded %d unrecorded / %d "
                         ~ "recording, scanner found %d / %d\n        (%s)",
                           r.file, r.func, r.unrecorded, r.recording, u, g,
                           r.why));
    }
    foreach (key, counts; found) {
        bool known = false;
        foreach (ref r; kL9Seam)
            if (key == r.file ~ "\0" ~ r.func) known = true;
        if (!known) {
            auto parts = splitKey(key);
            bad.put(format("\n    %s :: %s — NOT IN THE TABLE, scanner found "
                         ~ "%d unrecorded / %d recording", parts[0], parts[1],
                           counts[0], counts[1]));
        }
    }
    assert(bad.data.length == 0, format(
        "task 1903 L9 (W-9-SEAM): the loop-slice family's batch-open SET no "
      ~ "longer matches the recorded table.%s\n\n  A recording batch on the "
      ~ "PREVIEW path builds and discards a full op-log at 60 Hz and NOTHING "
      ~ "else in either lane reddens on it; an `unrecorded` batch on a COMMIT "
      ~ "path silently drops that command's undo. Neither is visible from a "
      ~ "counter, which is why this is a text census.", bad.data));
}

private struct ScopeEntry { string name; bool isFunc; }

private bool isIdentCh(char c)
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9');
}

/// Keywords that open a CONTROL-FLOW or non-callable block. Duplicated from
/// `revert_entry_census_test.kControlKeywords` — the accepted pattern between
/// census files.
private static immutable string[] kControlKw = [
    "if", "for", "foreach", "foreach_reverse", "while", "switch", "catch",
    "else", "try", "finally", "scope", "version", "debug", "synchronized",
    "with", "do", "case", "default", "class", "struct", "interface",
    "template", "union", "enum", "mixin", "static", "align", "extern",
    "import", "module", "unittest", "invariant", "in", "out", "body", "asm",
];

private bool looksLikeFunc(string h)
{
    if (h.length == 0) return false;
    size_t i = 0;
    while (i < h.length && isIdentCh(h[i])) ++i;
    if (i == 0) return false;
    foreach (kw; kControlKw) if (h[0 .. i] == kw) return false;
    return h.indexOfSub("(");
}

/// True when `hay` contains `needle` — a local three-liner so this census
/// carries no import that could pull a different `indexOf` overload in.
private bool indexOfSub(string hay, string needle)
{
    if (needle.length > hay.length) return false;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return true;
    return false;
}

/// `"private bool foo(int x)"` -> `"foo"`.
private string nameOf(string header)
{
    import std.string : strip;
    size_t paren = 0;
    while (paren < header.length && header[paren] != '(') ++paren;
    if (paren == header.length) return header.strip;
    string before = header[0 .. paren].strip;
    size_t e = before.length, s = e;
    while (s > 0 && isIdentCh(before[s - 1])) --s;
    return s < e ? before[s .. e] : "<anonymous>";
}

private string[2] splitKey(string key)
{
    foreach (i, c; key) if (c == '\0') return [key[0 .. i], key[i + 1 .. $]];
    return [key, ""];
}
