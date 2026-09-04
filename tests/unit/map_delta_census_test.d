// ===========================================================================
// Task 1903 Stage L1-P1 — the SOURCE-TEXT censuses for `Kind.MapValueDelta`.
//
// LANE: `dub test --config=tests` ONLY (`./run_test.d` links the prebuilt
// archive and never runs a `tests/unit/**` block).
//
// TWO THINGS A RUNTIME CELL CANNOT SAY, which is why these are text scans:
//
//   * W-K3 — that the exclusion is spelled ONCE. `MeshEditTracker.append` is
//     the only `log_ ~=` in its module, so every one of the sixteen recorders
//     passes the adjacency latch. A seventeenth recorder that appended
//     directly would bypass BOTH latches, produce a perfectly valid delta, and
//     nothing at runtime would notice.
//   * W-K12 — WHO calls the post-hoc recorders, and with WHAT argument. The
//     count row alone stays green when the ARGUMENT changes (L0-b's M-b4 /
//     M-b6 lesson), so the argument TEXT is a separate row.
//
// THE STATE OF W-K12'S ARGUMENT-TEXT HALF, updated at Stage L1-a (task 2230).
// It shipped VACUOUS at L1-P1 — the kind had zero production recorder callers,
// so there was no call site whose argument could be substituted. `morph.d` is
// the first, and the argument table below is now DRIVEN: it pins the before /
// after / presence arguments of all six of its calls, and a mutation that
// swaps one for another keeps every count row green and reddens only here.
// STAGE L1-b (task 2250) DISCHARGED `recordMapValueDiff`'s half of the debt.
// Eight production call sites now exist across the five UV value files, and
// two arguments of each are pinned below: the BEFORE-IMAGE (the one a caller
// substitutes for the live array, which keeps the count green and makes the
// undo restore nothing) and the PUBLISH CLASS (the one that silently moves the
// family from `Material` to `Maps`, changing what `docRevision()` counts —
// i.e. the unsaved-changes asterisk — on the RECORDED arm only).
//
// WHY AN ARGUMENT ROW AND NOT JUST A COUNT — L0-b's M-b4/M-b6 lesson, and this
// family gives it its sharpest form: the presence channel's before-image and
// after-image are two arrays of the same type, the same length, at adjacent
// argument positions. Passing the after-image where the before-image belongs
// compiles, keeps the count at one call, restores every float correctly, and
// silently drops the presence half of the undo.
// ===========================================================================
module tests.unit.map_delta_census_test;

import std.file   : readText, exists, dirEntries, SpanMode;
import std.format : format;
import std.path   : buildPath, dirName;
import std.string : splitLines;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    enclosingSymbols, symbolAt, LedgerRow, LedgerHit, reconcile, symbolTokenHits;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// The comment/string/unittest-body stripper is the SHARED one
// (`version_poll_census_test`), not a fourth copy: a doc comment that NAMES a
// symbol moves the count, and a unittest body that CALLS one is not a caller
// in the sense this census means. Reusing it also means a fix to its known
// desync cases lands here for free.
private string codeView(string src) {
    return blankUnittestBodies(blankNonCode(src));
}

private size_t countOccurrences(string hay, string needle) {
    size_t n = 0, i = 0;
    while (i + needle.length <= hay.length) {
        if (hay[i .. i + needle.length] == needle) { ++n; i += needle.length; }
        else ++i;
    }
    return n;
}

/// Every `needle(` call in `code`, as its balanced-paren argument text split on
/// TOP-LEVEL commas. This is the half of W-K12 that sees a substituted
/// before-image: a caller that swaps `pre` for `live.data` keeps the count and
/// changes this.
private struct CallSite {
    string symbol;
    string[] args;
    size_t line;
}

private size_t lineOf(string code, size_t pos) {
    size_t line = 1;
    foreach (c; code[0 .. pos]) if (c == '\n') ++line;
    return line;
}

private CallSite[] callArgs(string code, string needle) {
    import std.string : strip;
    CallSite[] outp;
    const symbols = enclosingSymbols(code);
    size_t i = 0;
    const string pat = needle ~ "(";
    while (i + pat.length <= code.length) {
        if (code[i .. i + pat.length] != pat) { ++i; continue; }
        // Skip a DECLARATION: a call is preceded by `.` or by whitespace after
        // an expression, a declaration by the return type. Cheap and adequate
        // here — the declaration is the one occurrence whose preceding
        // non-space character is not `.`.
        size_t j = i + pat.length;
        int depth = 1;
        size_t argStart = j;
        string[] args;
        while (j < code.length && depth > 0) {
            const char c = code[j];
            if (c == '(' || c == '[') ++depth;
            else if (c == ')' || c == ']') {
                --depth;
                if (depth == 0) { args ~= code[argStart .. j].strip; break; }
            } else if (c == ',' && depth == 1) {
                args ~= code[argStart .. j].strip;
                argStart = j + 1;
            }
            ++j;
        }
        const line = lineOf(code, i);
        outp ~= CallSite(symbolAt(symbols, line - 1), args, line);
        i = j + 1;
    }
    return outp;
}

private string sourceFile(string rel) {
    const p = buildPath(repoRoot, rel);
    assert(exists(p), "census: " ~ p ~ " is missing — the scan would report 0");
    return codeView(readText(p));
}

// ===========================================================================
// W-K3 — the funnel is a FUNNEL: one `log_ ~=` in the whole module.
// ===========================================================================
unittest
{
    const string code = sourceFile("source/mesh_edit_delta.d");

    // NON-VACUITY, FIRST. A stripper that lost its place eats the rest of the
    // file, and every count below then reads 0 and passes.
    assert(code.length >= 60_000, format(
        "census: the code view of mesh_edit_delta.d is only %d bytes — the "
      ~ "stripper ate the file (a wysiwyg string or a character literal will "
      ~ "do it) and every count below is meaningless", code.length));
    const size_t routed = countOccurrences(code, "append(e);");
    assert(routed >= 16, format(
        "census: only %d recorder sites route through `append(e);`, expected "
      ~ "at least 16. Either the scan is broken or recorders have gone around "
      ~ "the funnel.", routed));

    const size_t raw = countOccurrences(code, "log_ ~=");
    assert(raw == 1, format(
        "census: `log_ ~=` occurs %d times in source/mesh_edit_delta.d, "
      ~ "expected exactly 1 (inside MeshEditTracker.append). A recorder that "
      ~ "appends DIRECTLY bypasses both adjacency latches, produces a "
      ~ "perfectly valid-looking delta, and nothing at runtime would notice. "
      ~ "A rule spelled sixteen times is a rule that drifts, which is why it "
      ~ "is spelled once.", raw));

    // And that once is inside `append`, not somewhere else that happens to be
    // alone. The funnel's body is the only place the two latches are read.
    const size_t inAppend = countOccurrences(code,
        "sawIndexMove_ |= moves;\n        log_ ~= e;");
    assert(inAppend == 1, format(
        "census: the single `log_ ~=` is not the one inside `append` (found "
      ~ "%d matches for the latch-then-append sequence). Moving it out of the "
      ~ "funnel keeps the count at 1 and removes the rule.", inAppend));
}

// ===========================================================================
// The `final switch` inventory of `mesh_edit_delta.d`.
//
// The owner PRICED this kind at a branch in six switches over `Kind` plus the
// one in `tests/test_mesh_edit_delta.d`. The extracted `kindHoldsIndexSpace`
// REPLACED `indexSpaceStable`'s switch rather than adding one, and
// `patchMapValues` / `patchMapValuesWrite` / `mapEntryChangesValues` switch
// over the SUB-enums (`MapOp`, `MapAddressing`) — the `SelDomain` precedent,
// which does not count against the six.
//
// This row is a tripwire, not a style rule: a seventh switch over `Kind` is a
// seventh place a new kind must be argued, and it should be a deliberate,
// visible decision rather than a diff nobody counted.
// ===========================================================================
unittest
{
    const string code = sourceFile("source/mesh_edit_delta.d");
    const size_t n = countOccurrences(code, "final switch");
    enum size_t kExpected = 10;   // 6 over Kind, 1 over SelDomain, 3 over the
                                  // MapValueDelta sub-enums
    assert(n == kExpected, format(
        "census: mesh_edit_delta.d has %d `final switch`es, the inventory says "
      ~ "%d. Over `Kind` (6): kindHoldsIndexSpace, owesTopologyBump, "
      ~ "displayTermFor, owesDisplayRefresh, applyForward, applyReverse. Over "
      ~ "a SUB-enum (4): patchSelection (SelDomain), patchMapValues (MapOp), "
      ~ "mapEntryChangesValues (MapOp), patchMapValuesWrite (MapAddressing). "
      ~ "If you added one over `Kind`, say so here and in the plan — that is "
      ~ "the cost the owner priced.", n, kExpected));
}

// ===========================================================================
// W-K12 — the closed caller sets of the map recorders.
//
// EMPTY AT THIS COMMIT, DELIBERATELY. Every count below is "one occurrence,
// and it is the declaration". That is a live check in exactly one direction:
// a FIRST caller cannot be added while this file still says there is none.
// The argument-TEXT half is owed by L1-a (`recordMapCreate*`) and L1-e
// (`recordMapValueDiff`); its machinery is proven by the probe cell below.
// ===========================================================================
private immutable string[] kMapRecorders = [
    "recordMapValueDiff", "recordMapValuesOwned", "recordMapCreate",
    "recordMapCreateFilledOwned", "recordMapRemoveOwned", "recordMapRename",
];

unittest
{
    // THE SET IS CLOSED AND ENUMERATED. Six symbols; `mesh_edit_delta.d`'s row
    // for each is its DECLARATION, `mesh.d`'s two `recordMapValuesOwned` calls
    // are `recordMapValueDiff`'s own arms (the sparse one and the dense one,
    // which is why that method reports WHICH spelling won), and `morph.d` is
    // the kind's FIRST PRODUCTION CALLER — Stage L1-a, six calls across five
    // command classes.
    static immutable LedgerRow[] rows = [
        LedgerRow("MeshEditBatch|recordMapValueDiff", 1, "recorder declaration"),
        LedgerRow("MeshEditTracker|recordMapValuesOwned", 1, "recorder declaration"),
        LedgerRow("MeshEditBatch.recordMapValueDiff|recordMapValuesOwned", 2, "sparse and dense arms"),
        LedgerRow("MorphSet.setKernel|recordMapValuesOwned", 1, "mesh.morph.set"),
        LedgerRow("MorphClear.clearKernel|recordMapValuesOwned", 1, "mesh.morph.clear"),
        LedgerRow("WeightmapSet.setKernel|recordMapValuesOwned", 1, "mesh.weightmap.set"),
        LedgerRow("UvClear.clearKernel|recordMapValuesOwned", 1, "uv.clear"),

        LedgerRow("MeshEditTracker|recordMapCreate", 1, "recorder declaration"),
        LedgerRow("MorphCreate.createKernel|recordMapCreate", 1, "relative morph create"),
        LedgerRow("WeightmapCreate.createKernel|recordMapCreate", 1, "weight-map create"),
        LedgerRow("runCreaseWrites|recordMapCreate", 1, "crease-map create"),

        LedgerRow("MeshEditTracker|recordMapCreateFilledOwned", 1, "recorder declaration"),
        LedgerRow("MorphCreate.createKernel|recordMapCreateFilledOwned", 1, "absolute morph create"),
        LedgerRow("UvCopy.copyKernel|recordMapCreateFilledOwned", 1, "uv.copy"),
        LedgerRow("UvProject.kernel|recordMapCreateFilledOwned", 1, "uv.project created arm"),
        LedgerRow("UvUnwrap.recordUnwrap|recordMapCreateFilledOwned", 1, "uv.unwrap created arm"),

        LedgerRow("MeshEditTracker|recordMapRemoveOwned", 1, "recorder declaration"),
        LedgerRow("MorphRemove.removeKernel|recordMapRemoveOwned", 1, "mesh.morph.remove"),
        LedgerRow("WeightmapRemove.removeKernel|recordMapRemoveOwned", 1, "mesh.weightmap.remove"),
        LedgerRow("UvDelete.deleteKernel|recordMapRemoveOwned", 1, "uv.delete"),

        LedgerRow("MeshEditTracker|recordMapRename", 1, "recorder declaration"),
        LedgerRow("MorphRename.renameKernel|recordMapRename", 1, "mesh.morph.rename"),
        LedgerRow("WeightmapRename.renameKernel|recordMapRename", 1, "mesh.weightmap.rename"),
        LedgerRow("UvRename.renameKernel|recordMapRename", 1, "uv.rename"),

        LedgerRow("runCreaseWrites|recordMapValueDiff", 1, "crease writes"),
        LedgerRow("UvFit.kernel|recordMapValueDiff", 1, "uv.fit"),
        LedgerRow("UvPack.kernel|recordMapValueDiff", 1, "uv.pack"),
        LedgerRow("UvProject.kernel|recordMapValueDiff", 1, "uv.project existing arm"),
        LedgerRow("UvRelax.kernel|recordMapValueDiff", 1, "uv.relax"),
        LedgerRow("UvFlip.kernel|recordMapValueDiff", 1, "uv.flip"),
        LedgerRow("UvMirror.kernel|recordMapValueDiff", 1, "uv.mirror"),
        LedgerRow("UvRotate.kernel|recordMapValueDiff", 1, "uv.rotate"),
        LedgerRow("UvUnwrap.recordUnwrap|recordMapValueDiff", 1, "uv.unwrap existing arm"),
    ];


    size_t scannedFiles = 0, scannedBytes = 0;
    LedgerHit[] hits;

    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const string code = codeView(readText(de.name));
        ++scannedFiles;
        scannedBytes += code.length;
        const string rel = de.name[repoRoot.length + 1 .. $];
        foreach (recorder; kMapRecorders)
            hits ~= symbolTokenHits(code, rel, recorder ~ "(", recorder);
    }

    // The floor: a broken walk reports zero everywhere and passes.
    assert(scannedFiles >= 100 && scannedBytes >= 1_000_000, format(
        "census: only %d files / %d bytes of source/** were scanned — the walk "
      ~ "is broken and every count below is a zero it did not earn",
        scannedFiles, scannedBytes));

    const problems = reconcile(rows, hits);
    assert(problems.length == 0, format(
        "census: the map-recorder symbol ledger changed.%s\n"
      ~ "The recorder callers of Kind.MapValueDelta are ENUMERATED, not merely "
      ~ "counted: `commands/mesh/morph.d` (Stage L1-a, six calls), "
      ~ "`recordMapValueDiff`'s own two arms in mesh.d, and Stage L1-b's "
      ~ "three groups — `weightmap.d` (4), `uv_map_util.d` (4) and the five "
      ~ "UV value files (10 calls across 8 classes; the two hybrids each own "
      ~ "a Create as well as a diff). If you are a later stage: add your call "
      ~ "sites to the table "
      ~ "TOGETHER WITH the exact TEXT of each one's before-image / content "
      ~ "argument in the block below, because a count row stays green when the "
      ~ "ARGUMENT changes (L0-b, M-b4) and the two create spellings differ by "
      ~ "exactly that argument.", problems));
    assert(hits.length == 34,
        format("map-recorder census expected 34 sites, found %d", hits.length));
}

// ===========================================================================
// W-K12's ARGUMENT-TEXT half, DRIVEN from Stage L1-a onwards.
//
// The count row above says WHO records; this one says WITH WHAT. The two
// failures it exists for are both invisible to a count:
//
//   * the before-image and the after-image are swapped, or one is passed
//     twice. For the presence channel that is a legal-looking undo that
//     restores every float and silently loses the presence plane — the
//     family's headline failure, measured at Stage F1 in its zero-fill form.
//   * a pre-op image is replaced by the LIVE array. The call still compiles,
//     still records one entry, and the entry's before-image is then equal to
//     its after-image, so the undo restores nothing and reports success.
//
// The arguments are pinned by INDEX into the call, which is what makes the row
// specific: a reordering of the recorder's parameters moves the expectations
// here and is meant to.
// ===========================================================================
private struct ArgRow {
    string symbol;  // enclosing declaration; stable when its body moves
    string sym;     // recorder name, no paren
    size_t arg;     // 0-based argument index
    string want;    // exact stripped text
    string why;
}

unittest
{
    static immutable ArgRow[] args = [
        // mesh.morph.set — one element, both channels, images read from the
        // LIVE map on both sides of the write.
        ArgRow("MorphSet.setKernel", "recordMapValuesOwned", 6, "before.dup",
            "the pre-op components, captured BEFORE setMorphValue runs"),
        ArgRow("MorphSet.setKernel", "recordMapValuesOwned", 7, "after.dup",
            "the post-op components, READ BACK from the live map rather than "
          ~ "reconstructed from the command's parameters"),
        ArgRow("MorphSet.setKernel", "recordMapValuesOwned", 8, "[presBefore]",
            "the presence bit as it was. Swap this for [presAfter] and every "
          ~ "float still restores while the presence half is lost"),
        ArgRow("MorphSet.setKernel", "recordMapValuesOwned", 9, "[presAfter]",
            "the presence bit as it now is"),
        // mesh.morph.clear — the selected set, four pre-sized arrays.
        ArgRow("MorphClear.clearKernel", "recordMapValuesOwned", 6, "before",
            "the pre-op values of the cleared elements"),
        ArgRow("MorphClear.clearKernel", "recordMapValuesOwned", 7, "after",
            "the post-clear values, gathered from the live map so a refused "
          ~ "element is recorded as it really is"),
        ArgRow("MorphClear.clearKernel", "recordMapValuesOwned", 8, "pb",
            "the presence bits as they were. THIS is the argument mutation M1 "
          ~ "substitutes; the count row stays green under it"),
        ArgRow("MorphClear.clearKernel", "recordMapValuesOwned", 9, "pa",
            "the presence bits after the clear — all zero for every element "
          ~ "the kernel actually reached"),
        // mesh.morph.create, absolute — the forward-faithful content.
        ArgRow("MorphCreate.createKernel", "recordMapCreateFilledOwned", 4, "m.data.dup",
            "the created content, carried so a FORWARD replay (redo through "
          ~ "MeshSessionEdit) reproduces the dense base snapshot"),
        ArgRow("MorphCreate.createKernel", "recordMapCreateFilledOwned", 5, "m.present.dup",
            "…and its presence channel, for the same reason"),
        // mesh.morph.remove — the whole map, plus the registry slot.
        ArgRow("MorphRemove.removeKernel", "recordMapRemoveOwned", 4, "slot",
            "the map's index in meshMaps BEFORE the splice. Pass uint.max "
          ~ "here and the undo restores the map's CONTENT at the wrong "
          ~ "position, which meshPlanesJson reads and the frozen oracle sees"),
        ArgRow("MorphRemove.removeKernel", "recordMapRemoveOwned", 5, "data",
            "the pre-op values, dup'd before removeMeshMap splices them away"),
        ArgRow("MorphRemove.removeKernel", "recordMapRemoveOwned", 6, "pres",
            "…and the presence channel"),
        // mesh.morph.rename — two strings and nothing else.
        ArgRow("MorphRename.renameKernel", "recordMapRename", 0, "from_", "the old name"),
        ArgRow("MorphRename.renameKernel", "recordMapRename", 1, "to_",   "the new name"),

        // ===================================================================
        // STAGE L1-b (task 2250).
        // ===================================================================
        // --- weightmap.d ---------------------------------------------------
        // mesh.weightmap.set — one element, both images read from the LIVE map
        // on either side of a write this command does not own.
        ArgRow("WeightmapSet.setKernel", "recordMapValuesOwned", 6, "[before]",
            "the pre-op value, captured BEFORE setVertexWeight runs"),
        ArgRow("WeightmapSet.setKernel", "recordMapValuesOwned", 7, "[after]",
            "the post-op value, READ BACK from the live map rather than "
          ~ "reconstructed from the command's own `weight_` parameter — the "
          ~ "write goes through a Mesh setter, and an entry whose after-image "
          ~ "disagrees with the mesh writes the wrong thing on redo"),
        ArgRow("WeightmapSet.setKernel", "recordMapValuesOwned", 8,
            "tracks ? [presBefore] : null",
            "the presence channel, decided by the KIND and never by the "
          ~ "array. A weight map does not track presence, and "
          ~ "`patchMapValuesWrite` REFUSES an entry that carries the channel "
          ~ "anyway — a refusal applies nothing and still answers true"),
        ArgRow("WeightmapSet.setKernel", "recordMapValuesOwned", 9,
            "tracks ? [presAfter] : null", "…and its after-image"),
        // mesh.weightmap.remove — the whole map plus the registry slot.
        ArgRow("WeightmapRemove.removeKernel", "recordMapRemoveOwned", 4, "slot",
            "the map's index in meshMaps BEFORE the splice. `uint.max` here "
          ~ "restores the map's CONTENT at the END of the registry: measured "
          ~ "on the frozen oracle, which reddens on "
          ~ "[mesh.weightmap.remove/postUndo] plane 'meshMaps'"),
        ArgRow("WeightmapRemove.removeKernel", "recordMapRemoveOwned", 5, "data",
            "the pre-op values, dup'd before removeMeshMap splices them away"),
        ArgRow("WeightmapRemove.removeKernel", "recordMapRemoveOwned", 6, "pres",
            "…and the presence channel, empty for this kind but carried "
          ~ "through the same field rather than hard-coded to null"),
        // --- uv_map_util.d -------------------------------------------------
        ArgRow("UvDelete.deleteKernel", "recordMapRemoveOwned", 4, "slot",
            "uv.delete's registry slot. `uint.max` reddens the frozen oracle "
          ~ "on [uv.delete/postUndo] plane 'meshMaps'"),
        ArgRow("UvCopy.copyKernel", "recordMapCreateFilledOwned", 4, "dst.data.dup",
            "uv.copy carries the COPIED content: the undo needs only a name, "
          ~ "but MeshSessionEdit replays a delta FORWARD for redo, and a "
          ~ "DefaultInit create would bring the map back correctly shaped and "
          ~ "full of zeros"),
        ArgRow("UvCopy.copyKernel", "recordMapCreateFilledOwned", 5, "dst.present.dup",
            "…and its presence channel"),
        ArgRow("UvClear.clearKernel", "recordMapValuesOwned", 5, "null",
            "uv.clear addresses WholeArray, so it lists NO indices. A "
          ~ "`Listed` entry with an empty index list is refused, which is the "
          ~ "empty-means-all trap the addressing enum exists to close"),
        ArgRow("UvClear.clearKernel", "recordMapValuesOwned", 6, "before",
            "THE ARGUMENT THIS WHOLE BLOCK EXISTS FOR. uv.clear's forward "
          ~ "result is all zeros, so passing the POST-clear image here makes "
          ~ "the undo zero-fill — every length still matches, the entry still "
          ~ "binds, and `revert()` still answers true. Stage F1 measured "
          ~ "exactly that failure"),
        ArgRow("UvClear.clearKernel", "recordMapValuesOwned", 7, "m.data.dup",
            "…and the after-image, read from the live map"),
        // --- the five UV value files: the POST-HOC door --------------------
        // Two arguments per call. Arg 1 is the pre-op image — substitute the
        // LIVE array and the call still compiles, still records one entry, and
        // that entry's before-image equals its after-image, so the undo
        // restores nothing and reports success. Arg 3 is the publish class —
        // drop it and the default `Maps` applies, moving what
        // `ChangeBus.docRevision()` counts, on the RECORDED arm only.
        ArgRow("UvFlip.kernel", "recordMapValueDiff", 1, "pre", "uv.flip"),
        ArgRow("UvFlip.kernel", "recordMapValueDiff", 3, "MeshEditScope.Material", "uv.flip's class"),
        ArgRow("UvMirror.kernel", "recordMapValueDiff", 1, "pre", "uv.mirror"),
        ArgRow("UvMirror.kernel", "recordMapValueDiff", 3, "MeshEditScope.Material", "uv.mirror's class"),
        ArgRow("UvRotate.kernel", "recordMapValueDiff", 1, "pre", "uv.rotate"),
        ArgRow("UvRotate.kernel", "recordMapValueDiff", 3, "MeshEditScope.Material", "uv.rotate's class"),
        ArgRow("UvFit.kernel", "recordMapValueDiff", 1, "pre", "uv.fit"),
        ArgRow("UvFit.kernel", "recordMapValueDiff", 3, "MeshEditScope.Material", "uv.fit's class"),
        ArgRow("UvPack.kernel", "recordMapValueDiff", 1, "pre", "uv.pack"),
        ArgRow("UvPack.kernel", "recordMapValueDiff", 3, "MeshEditScope.Material", "uv.pack's class"),
        ArgRow("UvRelax.kernel", "recordMapValueDiff", 1, "pre", "uv.relax"),
        ArgRow("UvRelax.kernel", "recordMapValueDiff", 3, "MeshEditScope.Material", "uv.relax's class"),
        ArgRow("UvProject.kernel", "recordMapValueDiff", 1, "preData",
            "uv.project's EXISTING-map branch. Named `preData` and not `pre` "
          ~ "because `pre` in that file is the map POINTER resolved before the "
          ~ "batch — passing it would not even compile, which is the only "
          ~ "reason this row differs from its siblings"),
        ArgRow("UvProject.kernel", "recordMapValueDiff", 3, "MeshEditScope.Material", "uv.project's class"),
        ArgRow("UvUnwrap.recordUnwrap", "recordMapValueDiff", 1, "preData",
            "uv.unwrap's EXISTING-map branch — and this image has a SECOND "
          ~ "job: it is also the rollback the kernel applies when `uvUnwrap` "
          ~ "refuses AFTER the seed write, which is why it is taken on every "
          ~ "arm and not behind `recording()`"),
        ArgRow("UvUnwrap.recordUnwrap", "recordMapValueDiff", 3, "MeshEditScope.Material", "uv.unwrap's class"),

        // ===================================================================
        // STAGE L5-d (task 2300) — the crease pair.
        // ===================================================================
        ArgRow("runCreaseWrites", "recordMapValueDiff", 1, "pre",
            "the pre-op crease values, dup'd from the live map AFTER it is "
          ~ "created and BEFORE the first setCreaseWeight. Replace this with "
          ~ "`mm.data` — the LIVE array — and the entry's before-image equals "
          ~ "its after-image: the undo restores nothing and reports success, "
          ~ "which is the exact failure this half of the census exists for"),
        ArgRow("runCreaseWrites", "recordMapValueDiff", 2, "null",
            "no presence channel: `kindInfo(creaseWeight).tracksPresence` is "
          ~ "false, and `recordMapValueDiff` refuses an entry that carries the "
          ~ "channel anyway — a refusal applies nothing and still answers true"),
        ArgRow("runCreaseWrites", "recordMapValueDiff", 3, "MeshEditScope.Material",
            "the class `setCreaseWeight` itself publishes, so the recorded arm "
          ~ "stamps exactly what the redo and the pre-migration path stamped"),
        ArgRow("runCreaseWrites", "recordMapCreate", 1, "mm.dim",
            "the shape terms are read back off the LIVE map rather than "
          ~ "hard-coded from `kindInfo`, so a registry that produced something "
          ~ "else cannot be described as something it is not"),
        ArgRow("runCreaseWrites", "recordMapCreate", 3, "mm.kind",
            "the KIND, which the replay uses as a refusal term — and it is "
          ~ "load-bearing here rather than a sanity check: an Edge/dim-1 map "
          ~ "of the WRONG kind binds on every other term"),
    ];

    // POPULATION FLOOR FIRST, and it is an exact count rather than `> 0`:
    // a table that resolved to zero rows would pass every assertion below by
    // never entering the loop, and a table that quietly lost ONE row would do
    // the same for that row alone. Nothing else in this cell can see a
    // deleted row — the per-row assertions only ever look at rows that are
    // still there — so this literal is the only guard against a census that
    // shrinks to fit.
    assert(args.length == 49, format(
        "the argument table holds %d row(s), recorded 49. A row that went "
      ~ "away silently stops being checked; move this number with it and say "
      ~ "in the commit why the row left.", args.length));

    bool[string] recorderSet;
    foreach (ref r; args) recorderSet[r.sym] = true;
    CallSite[][string] bySymbol;
    size_t scannedFiles;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const code = codeView(readText(de.name));
        ++scannedFiles;
        foreach (recorder; recorderSet.keys)
            foreach (site; callArgs(code, recorder))
                bySymbol[site.symbol ~ "|" ~ recorder] ~= site;
    }

    foreach (ref r; args) {
        const key = r.symbol ~ "|" ~ r.sym;
        const calls = bySymbol.get(key, null);
        assert(calls.length == 1, format(
            "census: `%s` holds %d call(s) to `%s`, expected exactly one. "
          ~ "Moving the declaration does not change this key; adding, removing, "
          ~ "or splitting its call does.", r.symbol, calls.length, r.sym));
        auto a = calls[0].args;
        assert(r.arg < a.length, format(
            "census: `%s`'s call to `%s` takes %d argument(s); the table "
          ~ "names #%d.", r.symbol, r.sym, a.length, r.arg));
        assert(a[r.arg] == r.want, format(
            "census: argument %d of `%s`'s call to `%s` reads `%s`, the "
          ~ "table says `%s` (%s).\n"
          ~ "This row exists because the COUNT row above stays green through "
          ~ "exactly this edit: same caller, same number of calls, different "
          ~ "array handed over. If the change is deliberate, move this row "
          ~ "with it — and check that a witness covers the new behaviour.",
            r.arg, r.symbol, r.sym, a[r.arg], r.want, r.why));
    }
    // NOT a `checked == args.length` tally. That counter was incremented once
    // per loop iteration and then compared to the length of the thing being
    // iterated, so it was true whenever the loop ran to the end and false
    // never — it restated control flow instead of measuring anything. The
    // row-by-row pin is `calls.length == 1` above; the population pin is the
    // `args.length == 49` floor before the loop. What is left here is the one
    // term neither of those covers: that the WALK actually visited the tree.
    assert(scannedFiles >= 200,
        format("the argument scan ran over only %d source files", scannedFiles));
}

unittest // the extractor's OWN probe — the half that is live before L1-a
{
    // Without this cell the argument-text machinery above ships untested and
    // its first real use is the commit that also writes its expectations.
    enum string probe = q{
        void f(ref MeshEditBatch ed, ref Mesh m) {
            auto pre = m.meshMap("uv").data.dup;   // "uv" is a string, stripped
            uvRelax(m);
            ed.recordMapValueDiff("uv", pre, null);
            ed.recordMapValueDiff("uv2", m.meshMap("uv2").data, presPre);
        }
    };
    const string code = codeView(probe);
    auto calls = callArgs(code, "recordMapValueDiff");
    assert(calls.length == 2, format(
        "the call extractor found %d calls in the probe, expected 2 — it "
      ~ "cannot report on L1-e's call sites if it cannot read this one",
        calls.length));
    assert(calls[0].args.length == 3 && calls[1].args.length == 3, format(
        "the extractor split the argument lists wrong: %s", calls));
    assert(calls[0].args[1] == "pre", format(
        "the BEFORE-IMAGE argument of call 0 read as `%s`, expected `pre`. "
      ~ "This is the term that sees a caller substituting the LIVE array for "
      ~ "its pre-op image — the substitution a count row cannot see.",
        calls[0].args[1]));
    import std.algorithm.searching : canFind;
    assert(calls[1].args[1].canFind("m.meshMap(") && calls[1].args[1].canFind(").data"), format(
        "the extractor did not keep a nested call intact: `%s`", calls[1].args[1]));

    // POTENCY: change the argument and the row must move.
    enum string probe2 = q{
        void f() { ed.recordMapValueDiff("uv", live.data, null); }
    };
    auto c2 = callArgs(codeView(probe2), "recordMapValueDiff");
    assert(c2.length == 1 && c2[0].args[1] == "live.data", format(
        "the extractor reported `%s` for a substituted before-image — if it "
      ~ "cannot tell `pre` from `live.data` the whole row is a decoy",
        c2.length ? c2[0].args[1] : "<none>"));
}
