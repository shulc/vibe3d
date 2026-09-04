// l1_declined_census_test — the gate under task 1903 Stage L1's DECLINE:
// `source/commands/select/sets.d`'s five command classes stay PERMANENTLY
// DENSE (owner's L1 ruling, 2026-08-27, `doc/mesh_edit_seam_plan.md`).
//
// ===========================================================================
// WHY THIS FILE EXISTS AT ALL, AND WHY IT LANDS BEFORE THE MIGRATION
// ===========================================================================
// Stage L1-P1 shipped `MeshOpEntry.Kind.MapValueDelta`, a kind whose payload is
// "which MAP, which elements, what was, what is". From the moment that kind
// exists, `sets.d` reads as a natural fifth caller: it is in the same stage,
// it edits a named registry, and four of its five classes hold exactly the
// `MeshSnapshot` the map family is shedding. It is NOT a caller — the owner's
// ruling put the dividing line at the PLANE, not at the multiplicity — and
// these five declarations are what stops someone routing it there by analogy.
//
// Prose is not a check. A census over a comment is the WEAKEST instrument in
// this repository, so this module deliberately does not count the words in
// those declarations (except as one explicitly-labelled weak row). It counts
// the two things a migration would HAVE to change, plus the fact one of the
// declared reasons rests on:
//
//   GATE S1 — no `record*` call (nor the `.rec()` accessor that reaches one)
//     appears in `sets.d`. A migration IS such a call. Same instrument as
//     `l0_declined_census_test`'s GATE B, deliberately reused rather than
//     re-implemented: one scanner, one set of scanner cells, one place to fix.
//
//   GATE S2 — the dense captures the declarations promise INSTEAD are still
//     there, by count: `MeshSnapshot` for the four registry verbs and
//     `SelectionSnapshot` for `select.set.apply`. If a capture goes away the
//     undo is being restored from something else and the comment is now false.
//     `Touched` and `Document` are pinned in the same row because they are
//     `SelectSetApply`'s SECOND blocker made of code: the N-mesh binding.
//
//   GATE S3 — `Kind.SelectionDelta` still cannot carry a selection ORDER.
//     That is not a count, it is a driven cell, and it is the one row here
//     that can expire: blocker 1 of `SelectSetApply`'s declaration says
//     routing it onto `SelectionDelta` would restore the membership and lose
//     the order. If somebody later teaches `SelectionDelta` the order plane,
//     that sentence becomes false and this row goes red asking for the
//     declaration to be re-read. A gate that can only be broken by a
//     REGRESSION is half a gate; this one can also be broken by the fix.
//
// WHAT IS *NOT* FORBIDDEN HERE, because getting this wrong would block work
// that is still owed: the ruling declines the UNDO migration (axis 2) only.
// `sets.d` opening a `MeshEditBatch` so that `close()` owns its stamp is axis
// 0 and is still owed by it, exactly as it was by L0's three dense commands.
// `beginEditBatch` / `MeshEditBatch` / `commitChange` in this file are NOT a
// contradiction and are not counted.
//
// THE CODE VIEW. Both count gates read the file through `blankNonCode`
// (imported, not copied): comments and string literals are blanked. That is
// load-bearing in both directions — this tree now carries a dozen PROSE
// mentions of `MeshSnapshot` inside the very declarations this gate protects,
// and the row tables below name their identifiers as STRING LITERALS, so this
// module contributes nothing to its own scan.
//
// SEEN RED — every row, by its own mutation, in lane U
// (`dub test --config=tests`; `tests/unit/**` blocks never run in
// `./run_test.d`). See the task card (2230) for the verbatim messages.
// ===========================================================================
module tests.unit.l1_declined_census_test;

import std.algorithm : startsWith;
import std.file   : dirEntries, readText, SpanMode;
import std.format : format;
import std.path   : buildPath, dirName;
import std.string : splitLines;

import tests.unit.census_symbols : blankNonCode, enclosingSymbols, symbolAt,
    LedgerRow, LedgerHit, reconcile, symbolTokenHits;
import tests.unit.l0_declined_census_test  : countIdentIn, recorderCallsIn;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private enum string kAnchor   = "PERMANENTLY DENSE";

// ---------------------------------------------------------------------------
// The recorded counts, measured on this tree 2026-08-27 through the code view.
// Each row says what the number is MADE OF, so a changed count is legible
// rather than a number to re-baseline.
// ---------------------------------------------------------------------------
private immutable LedgerRow[] kSetsDense = [
    LedgerRow("SelectSetStore|MeshSnapshot", 1, "store field"),
    LedgerRow("SelectSetStore.applyImpl|MeshSnapshot", 1, "store capture"),
    LedgerRow("SelectSetEdit|MeshSnapshot", 1, "edit field"),
    LedgerRow("SelectSetEdit.applyImpl|MeshSnapshot", 1, "edit capture"),
    LedgerRow("SelectSetRename|MeshSnapshot", 1, "rename field"),
    LedgerRow("SelectSetRename.applyImpl|MeshSnapshot", 3,
        "the capture and two `.init` refusal resets; the field is the sibling "
      ~ "row. This is the dense capture the declaration promises instead of "
      ~ "a recorded delta"),
    LedgerRow("SelectSetDelete|MeshSnapshot", 1, "delete field"),
    LedgerRow("SelectSetDelete.applyImpl|MeshSnapshot", 2, "delete capture/reset"),
    LedgerRow("SelectSetApply|SelectionSnapshot", 1, "Touched snapshot field"),
    LedgerRow("SelectSetApply.applyImpl|SelectionSnapshot", 1,
        "the per-layer capture in `select.set.apply`; the field inside "
      ~ "`Touched` is the sibling row. A different type from the four above because it "
      ~ "captures the nine-plane selection object — Select bits, three "
      ~ "`*SelectionOrder` arrays and three counters — which is blocker 1 of "
      ~ "that command's declaration"),
    LedgerRow("SelectSetApply|Touched", 2, "declaration and touched_ field"),
    LedgerRow("SelectSetApply.applyImpl|Touched", 2,
        "the `struct Touched` declaration, the `Touched[] touched_` field, the "
      ~ "local in `applyImpl` and the append that fills it. Blocker 2 made of "
      ~ "code: this command accumulates a LIST of edited meshes"),
    LedgerRow("SelectSetApply|Document", 2,
        "the `Document* doc` field and the constructor parameter. "
      ~ "The other half of blocker 2 — a `MeshEditDelta` is produced by a "
      ~ "batch over ONE `Mesh` and replayed into ONE `Mesh`, and no decision "
      ~ "about a Marks publisher changes that"),
];

unittest // GATE S1 — no recorder call in sets.d
{
    LedgerHit[] calls;
    size_t filesRead;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const rel = de.name[repoRoot.length + 1 .. $];
        const code = blankNonCode(readText(de.name));
        const symbols = enclosingSymbols(code);
        foreach (li, line; code.splitLines) {
            const symbol = symbolAt(symbols, li);
            if (!symbol.startsWith("SelectSet")) continue;
            foreach (hit; recorderCallsIn(line))
                calls ~= LedgerHit(symbol, rel, li + 1, hit);
        }
        ++filesRead;
    }
    assert(calls.length == 0, format(
        "L1 PERMANENTLY DENSE broken: SelectSet declarations now carry %d recorder-call "
      ~ "signal(s) — %s. All five classes declare, each with its "
      ~ "own reason, that they are NEVER migrated to a recorded "
      ~ "MeshEditDelta: four of them write the named-set REGISTRY, a plane no "
      ~ "MeshOpEntry.Kind carries as a payload, and select.set.apply has two "
      ~ "independent blockers on top of that. Migrating one of them is a "
      ~ "decision to REOPEN the owner's L1 ruling, not an edit: change the "
      ~ "declaration first, in the same commit.", calls.length, calls));
    assert(filesRead >= 200,
        format("L1 decline census scanned only %d source files", filesRead));
}

unittest // GATE S2 — the dense captures the declarations promise are still there
{
    LedgerHit[] hits;
    size_t anchorCount;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const raw = readText(de.name);
        const code = blankNonCode(raw);
        const file = de.name[repoRoot.length + 1 .. $];
        size_t before = hits.length;
        foreach (ident; ["MeshSnapshot", "SelectionSnapshot", "Touched", "Document"])
            foreach (hit; symbolTokenHits(code, file, ident, ident))
                if (hit.key.startsWith("SelectSet"))
                    hits ~= hit;
        if (hits.length != before) anchorCount += countIdentIn(raw, kAnchor);
    }
    const bad = reconcile(kSetsDense, hits);
    assert(bad.length == 0, format("L1 dense-capture symbol ledger changed:%s", bad));
    assert(hits.length == 19,
        format("L1 dense-capture population changed: expected 19, found %d", hits.length));

    // THE WEAK ROW, labelled as such. A comment census can see a declaration
    // DELETED and can never see one that has drifted away from the code —
    // which is exactly why the two rows above, not this one, carry the gate.
    assert(anchorCount == 5, format(
        "L1 decline declaration missing or duplicated: the owner files carry the marker "
      ~ "`%s` %d time(s), recorded 5 — one at each of the five command "
      ~ "classes. If you moved a declaration, move this number with it.",
        kAnchor, anchorCount));
}

unittest // GATE S1/S2 instrument — the scanners can actually find something
{
    // POTENCY. GATE S1 is a `length == 0` against a file that contains no
    // recorder call; if `recorderCallsIn` returned empty for EVERY input it
    // would be green under any migration. `magnet.d` is a MIGRATED L0 command
    // and records its own positions, so it is the control. (Deliberately NOT
    // `morph.d`: that file migrates in the NEXT commit, and a control that
    // changes state between two commits of one stage is a control that has to
    // be edited to stay true.)
    const migrated = readText(buildPath(repoRoot, "source/commands/mesh/magnet.d"));
    const calls = recorderCallsIn(blankNonCode(migrated));
    assert(calls.length >= 1, format(
        "instrument: `magnet.d` records through `ed.rec().recordSetPos(…)`; "
      ~ "the recorder scan must find it, or GATE S1 is vacuous. Found: %s",
        calls));

    // …and the identity counter must distinguish absent from present, or
    // GATE S2's four rows are four readings of the same constant.
    assert(countIdentIn("auto s = MeshSnapshot.capture(*mesh);", "MeshSnapshot") == 1,
        "instrument: the identifier counter must see a real mention");
    assert(countIdentIn("auto s = MeshSnapshotX.capture(*mesh);", "MeshSnapshot") == 0,
        "instrument: the identifier counter must be whole-word");
}

// ===========================================================================
// GATE S3 — the reason blocker 1 gives is still TRUE.
//
// `SelectSetApply`'s declaration says: `Kind.SelectionDelta` carries mark
// WORDS only, so an undo routed onto it would restore the membership and
// silently lose the pick ORDER. This cell drives that, on the vertex domain,
// in one replay:
//
//   * POTENCY half — the same revert really does put the Select BIT back. A
//     cell that only asserted "the order did not come back" would be green
//     over a replay that did nothing at all.
//   * CLAIM half — the `vertexSelectionOrder` stamp is NOT restored. It is
//     perturbed BETWEEN apply and revert, so the assertion does not have to
//     model what a real deselection does to the order array; it only has to
//     observe that the replay never writes that plane.
//
// This row can expire, and that is the point. If `SelectionDelta` (or
// `finalize`'s tail) is ever taught to carry the order, this goes red and the
// declaration must be re-read — blocker 2 would still stand alone, which is
// exactly why the declaration states both.
// ===========================================================================
unittest
{
    import mesh            : Mesh, makeCube;
    import mesh_edit_delta : MeshEditTracker, MeshOpEntry;

    auto m = new Mesh;
    *m = makeCube();
    m.buildLoops();
    m.syncSelection();

    // A non-monotonic stamp: a revert that RE-DERIVED the order from the
    // element index would reproduce 3 and 4 in index order and look correct.
    m.selectVertex(3);
    m.selectVertex(4);
    assert(m.vertexSelectionOrder.length > 4,
        "stand: the order plane must exist before it can be observed");
    m.vertexSelectionOrder[3] = 41;
    m.vertexSelectionOrder[4] = 12;   // later index, EARLIER stamp

    MeshEditTracker rec;
    rec.recordSelectionDelta(MeshOpEntry.SelDomain.Vertex, [3u], [1u], [0u]);
    auto delta = rec.finish();
    assert(!delta.isEmpty, "stand: the hand-built entry must reach the log");

    assert(delta.apply(*m), "the forward replay must succeed");
    assert(!m.isVertexSelected(3), "stand: the forward must clear the bit, or "
                                 ~ "the revert below has nothing to restore");

    // Perturb the ORDER plane while the selection is down. Nothing in the
    // entry mentions it, so whatever comes back is what the replay writes.
    m.vertexSelectionOrder[3] = 7;

    assert(delta.revert(*m), "the reverse replay must succeed");

    assert(m.isVertexSelected(3), format(
        "GATE S3 potency: the SelectionDelta revert did not restore the Select "
      ~ "bit, so the order observation below is being made about a replay that "
      ~ "did nothing. Fix this before reading the next assertion."));

    assert(m.vertexSelectionOrder[3] == 7, format(
        "GATE S3: a SelectionDelta revert RESTORED the selection order stamp "
      ~ "(vertexSelectionOrder[3] came back as %d, it was perturbed to 7 while "
      ~ "the selection was down). That is a real improvement — and it expires "
      ~ "BLOCKER 1 of select.set.apply's PERMANENTLY DENSE declaration, "
      ~ "which says this kind carries mark words only and would lose the "
      ~ "order. Re-read that declaration: BLOCKER 2 (it binds a Document and "
      ~ "edits several meshes, while a MeshEditDelta binds one) is untouched "
      ~ "by this and still stands on its own.",
        m.vertexSelectionOrder[3]));
}
