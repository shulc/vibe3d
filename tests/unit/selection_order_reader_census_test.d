// selection_order_reader_census_test — a tenth hand-rolled "which element was
// selected last" scan cannot be born (task 2440).
//
// THE RULE, stated so it survives a rename. The `*SelectionOrder` planes are a
// RANK, and a rank is only meaningful for an element that is still selected: a
// stale non-zero stamp on an UNSELECTED element is a deliberate, shipped state
// (`mesh_ops/bevel_vertex.d` and `mesh_ops/extrude.d` both re-mask the face
// marks word with `~Marks.Select` while `faceSelectionOrder`, a carried plane,
// keeps its values). So a reader that RANKS must filter by the Select bit
// first, and this repository keeps exactly two files that are allowed to do
// that ranking: `packages/mesh/source/mesh.d`, whose three readers are the law
// (`selectedFaceIndicesInSelectionOrder`, `selectedVerticesBySelectionOrder`,
// `lastSelectedInSelectionOrder`), and `packages/mesh-ops/source/mesh_ops/select_loop.d`, which
// holds the recorded verbatim twin of the first. Everywhere else the plane may
// be COPIED, ZEROED or SERIALISED — but not consulted to decide anything.
//
// WHAT WENT WRONG WITHOUT IT. `select.less`, `select.more` and
// `select.between` held NINE copies of the scan between them and none applied
// the filter, so all three read a phantom element after any vertex bevel or
// extrude. The behaviour is pinned by
// `tests/unit/selection_order_scan_test.d`; this file is the other half — it
// pins that the copies do not come back.
//
// WHY IT IS NOT PHRASED AS "NO `SelectionOrder[` OUTSIDE mesh.d". Because that
// is a spelling, and three whole families of legitimate site index these planes
// today: the undo image (`commands/mesh/selection_undo.d`), the plane carries
// (`mesh_planes.d`, `mesh_edit_delta.d`) and the wire serialiser
// (`http_json.d`). Forbidding the spelling would forbid them; permitting the
// spelling everywhere would permit the tenth copy. So the gate is a ROSTER: a
// value-read of the plane is legal only at a file this census names, with the
// count it names, and the reason recorded in `kRoster` below.
//
// THE THREE GATES, and each answers a different question:
//
//   1  THE NAMED RULE — `source/commands/select/**` holds ZERO value-reads.
//      This is the specific thing that went wrong, gated by name so the
//      failure message says so rather than making a reader diff two tables.
//   2  THE SET GATE — every other file's count equals its rostered count.
//      Catches a tenth copy written somewhere the first gate does not name,
//      AND an extra read added to a file that legitimately has some. A SWAP
//      inside one file (one read deleted, one added) is the stated residual,
//      the same one `version_poll_census_test.d` records for its own set gate.
//   3  THE FLOOR — the walk really scanned the tree. Asserted LAST: a canary
//      in front of the real message buries it.
//
// WHAT A VALUE-READ IS. An indexed expression `<plane>[…]` whose closing
// bracket is NOT followed by a plain `=`. `faceSelectionOrder[i] = 0` is a
// WRITE and is unrestricted — zeroing a stale stamp is the CURE, not the
// disease, and `snapshot.d` / `selection_undo.d` do it on the paths they own.
// `+=` and `==` are not plain assignments and count as reads (the safe
// direction: they demand a roster row).
//
// WHAT IT CANNOT SEE, stated rather than left to be discovered:
//   * A scan that takes the plane as a PARAMETER and indexes it under another
//     name. `Mesh.topTwoByOrder_` and `select_loop.selectLoopFaces`'s
//     `fOrderOf` are both that shape, which is why neither of the two declared
//     homes needs an exemption in the first place — the spelling never appears
//     there. A copy written that way in a third file is invisible here. What
//     limits it: the plane still has to be REACHED, and every reach is a bare
//     `mesh.faceSelectionOrder` mention, which `kBareMentions` below counts.
//   * A reader that goes through `Mesh.selectedFaceIndicesInSelectionOrder`
//     and then re-sorts. That is a correct reader being used oddly, not the
//     defect this gate is for.
module tests.unit.selection_order_reader_census_test;

import std.algorithm : canFind, sort;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : startsWith;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    enclosingSymbols, symbolAt, LedgerRow, LedgerHit, reconcile;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The three planes.
private immutable string[] kPlanes = [
    "vertexSelectionOrder", "edgeSelectionOrder", "faceSelectionOrder",
];

/// The two files allowed to RANK by these planes — the law's home and its one
/// recorded twin. Excluded from the walk entirely; see the header for why
/// neither actually spells an indexed read today.
private immutable string[] kDeclaredHomes = [
    "packages/mesh/source/mesh.d",
    "packages/mesh-ops/source/mesh_ops/select_loop.d",
];

/// Gate 1's subject: the family that held the nine copies.
private enum string kZeroDir = "source/commands/select/";

/// Wave8: three replay carry reads moved into the already-declared Mesh home.
/// The core exclusion still applies; they retain their original non-ranking bodies.
/// Gate 2. One row per owning symbol that legitimately indexes a plane for
/// its VALUE, with the count and the reason.
private immutable LedgerRow[] kRoster = [
    LedgerRow("DenseSelectionUndo.capture.carries", 1,
        "the dense undo IMAGE: reads the live stamp to store it and to decide "
      ~ "whether an edge was manually picked. Not a ranking — it never asks "
      ~ "which stamp is HIGHEST. The same file's three SCRUBBING writes "
      ~ "(`if (!isXSelected(i)) order[i] = 0`) are writes and are not counted."),
    LedgerRow("DenseSelectionUndo.capture", 1,
        "the dense undo IMAGE stores the live edge-selection stamp; the "
      ~ "decision-bearing carry predicate is recorded separately above"),
    LedgerRow("meshPlanesJson", 1,
        "the wire serialiser: reports the stamp of one edge, defensively "
      ~ "bounds-checked. A report, not a decision."),
    LedgerRow("edgeChainWalk", 1,
        "a RANK read, and legal for the same reason as the row below: the "
      ~ "loop `continue`s on `!isEdgeSelected` one line above the read, so "
      ~ "only selected edges are ranked (mesh.makePolygon's edge chain, task "
      ~ "7132; an accessor twin in `Mesh` would bump the struct-member ratchet)."),
    LedgerRow("reseedOpenChains", 2,
        "selected-first complete-edge packets: isEdgeSelected filters the full "
      ~ "index list before ascending stamps; inc.selected restricts chain keys. "
      ~ "The two-element last-selected accessor cannot represent this sequence."),
    LedgerRow("extractAlignChain.fallbackOrder", 2,
        "a genuine RANK read, and legal: `fallbackOrder` sorts an index list "
      ~ "that `operandVertexMask` already filtered to the selection, so the "
      ~ "selected-first rule is satisfied upstream of the sort rather than "
      ~ "inside it."),
];

/// NOT ROSTERED, and worth saying out loud because it is the file a reader
/// expects to find here: `packages/mesh-snapshot/source/snapshot.d` holds the SCRUBBER
/// (`if (!isXSelected(i)) order[i] = 0`, `:452-462`) and its three sites are
/// indexed WRITES, so the scanner classifies them as writes and they need no
/// row. If a genuine read is ever added there the file arrives with "NO roster
/// row" in gate 2, which is the outcome we want.

/// ALSO NOT ROSTERED, and it used to be: `packages/mesh/source/mesh_planes.d`. Until task
/// 4059 the dropped-face plane record spelled `m.faceSelectionOrder[fi]` out
/// and `rewriteFaces` carried a row for it. It is now generated by
/// `FacePlaneDrops.captureFace`'s `static foreach` over `kFacePlanes`, so the
/// read reaches the plane through `__traits(getMember, m, n)` and no TEXT
/// scanner can see it. The read did not go away — this census's reach did.
/// What guards it instead is the plane table itself plus
/// `tests/unit/mesh_planes_test.d`'s deliberately independent, hand-written
/// plane list; do not restore a spelled-out read here to make a row non-zero.
///
/// WHY THIS IS PROSE AND NOT A `count == 0` ROW, which is what the path-keyed
/// table carried. A zero row needs a KEY, and the key of this ledger is the
/// enclosing DECLARATION: there is no declaration left that reads the plane,
/// so a zero row would have to name a symbol chosen for having no sites — a
/// row that cannot move in either direction. The coverage the zero row bought
/// is bought instead by `reconcile`'s "NOT RECORDED AT ALL" arm: a re-spelled
/// read anywhere under `source/` is attributed to whatever declaration
/// encloses it, that key is not in `kRoster`, and gate 2 reddens naming it.
/// That arm is wider than the old row, which only watched one path.

/// The floor for gate 3 — well under the ~430 `.d` files in `source/` today,
/// so it notices a walk that collapsed without tracking the tree's growth.
private enum size_t kMinFilesScanned = 300;

/// Gate 3's second half: bare mentions of a plane (indexed or not) across the
/// scanned set. This is the number that moves when someone starts passing a
/// plane somewhere new — the hole the header names. It is a FLOOR plus a
/// recorded value, not a rule, so it is asserted with the floor and not with
/// the gates.
// Wave8 moves all 22 old replay mentions into the excluded core home.
// Preserve the old complement floor by subtraction: 125 - 22 = 103.
private enum int kBareMentionsRecorded = 103;

// ---------------------------------------------------------------------------
// The scanner
// ---------------------------------------------------------------------------

private struct Site { string path; string symbol; size_t line; string plane; string text; }

/// Index of the `]` matching the `[` at `open`, or `text.length` if unbalanced.
private size_t matchBracket(string text, size_t open) {
    int depth = 0;
    foreach (i; open .. text.length) {
        if (text[i] == '[') ++depth;
        else if (text[i] == ']') { --depth; if (depth == 0) return i; }
    }
    return text.length;
}

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// Every VALUE-read of a plane in one already-code-only file body.
private Site[] readsIn(string path, string code) {
    Site[] found;
    const symbols = enclosingSymbols(code);
    foreach (plane; kPlanes) {
        size_t from = 0;
        while (true) {
            const idx = indexFrom(code, plane, from);
            if (idx == size_t.max) break;
            from = idx + plane.length;
            // whole identifier, and indexed right here
            if (idx > 0 && isIdentChar(code[idx - 1])) continue;
            size_t b = from;
            while (b < code.length && (code[b] == ' ' || code[b] == '\t')) ++b;
            if (b >= code.length || code[b] != '[') continue;
            const close = matchBracket(code, b);
            if (close >= code.length) continue;
            // A plain `=` after the bracket is a WRITE.
            size_t a = close + 1;
            while (a < code.length && (code[a] == ' ' || code[a] == '\t')) ++a;
            const isWrite = a < code.length && code[a] == '='
                         && (a + 1 >= code.length || code[a + 1] != '=');
            if (isWrite) continue;
            size_t line = 1, ls = 0;
            foreach (k; 0 .. idx) if (code[k] == '\n') { ++line; ls = k + 1; }
            size_t le = idx;
            while (le < code.length && code[le] != '\n') ++le;
            found ~= Site(path, symbolAt(symbols, line - 1), line, plane,
                          code[ls .. le]);
        }
    }
    return found;
}

private size_t indexFrom(string hay, string needle, size_t from) {
    if (needle.length == 0 || from + needle.length > hay.length) return size_t.max;
    foreach (i; from .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle) return i;
    return size_t.max;
}

private int bareMentionsIn(string code) {
    int n = 0;
    foreach (plane; kPlanes) {
        size_t from = 0;
        while (true) {
            const idx = indexFrom(code, plane, from);
            if (idx == size_t.max) break;
            from = idx + plane.length;
            if (idx > 0 && isIdentChar(code[idx - 1])) continue;
            if (from < code.length && isIdentChar(code[from])) continue;
            ++n;
        }
    }
    return n;
}

private struct Scan {
    Site[] sites;
    size_t files;
    int    bareMentions;
}

private Scan scanSource() {
    Scan sc;
    const root = buildPath(repoRoot, "source");
    assert(exists(root), "census: source/ not found under " ~ repoRoot);
    string[] paths;
    foreach (scanSourceRoot; [root, buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (e; dirEntries(scanSourceRoot, "*.d", SpanMode.depth)) paths ~= e.name;
    const string[] sourceCarriersWave14_1 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];
    import std.file : exists;
    import std.path : buildPath;
    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);

    }
    foreach (sourceCarrier; sourceCarriersWave14_1)
        paths ~= buildPath(repoRoot, sourceCarrier);
    paths.sort();
    foreach (name; paths) {
        string rel = name[repoRoot.length + 1 .. $];
        if (kDeclaredHomes.canFind(rel)) continue;
        ++sc.files;
        const code = blankUnittestBodies(blankNonCode(readText(name)));
        sc.sites ~= readsIn(rel, code);
        sc.bareMentions += bareMentionsIn(code);
    }
    return sc;
}

private string render(const Site[] sites) {
    string s;
    foreach (st; sites)
        s ~= format("    %s  %s:%d  %s  |%s|\n", st.symbol, st.path,
                    st.line, st.plane, st.text);
    return s;
}

// ---------------------------------------------------------------------------
// Gate 1 — the named rule: no select command reads a rank plane
// ---------------------------------------------------------------------------
unittest {
    const sc = scanSource();
    Site[] offenders;
    foreach (st; sc.sites) if (st.path.startsWith(kZeroDir)) offenders ~= st;

    assert(offenders.length == 0,
        format("A tenth hand-rolled selection-order scan has been written under " ~
               "%s:\n%s\n" ~
               "\"Which element was selected last\" is `Mesh." ~
               "lastSelectedInSelectionOrder(mode)`, and \"the selection in click " ~
               "order\" is `Mesh.selectedFaceIndicesInSelectionOrder` / " ~
               "`selectedVerticesBySelectionOrder`. All three filter by the Select " ~
               "bit BEFORE they rank, which a hand-written scan over the plane " ~
               "does not: `bevel_vertex` and `extrude` leave a stale stamp on an " ~
               "UNSELECTED face on purpose, and reading it makes select.less a " ~
               "silent no-op and gives select.more / select.between a phantom " ~
               "pair to extrapolate from (task 2440, " ~
               "tests/unit/selection_order_scan_test.d).",
               kZeroDir, render(offenders)));
}

// ---------------------------------------------------------------------------
// Gate 2 — the set gate: per-file counts match the roster exactly
// ---------------------------------------------------------------------------
unittest {
    const sc = scanSource();

    LedgerHit[] hits;
    foreach (st; sc.sites)
        hits ~= LedgerHit(st.symbol, st.path, st.line, st.plane ~ "  |" ~ st.text ~ "|");
    const problems = reconcile(kRoster, hits);

    // Accumulate, then assert once: a gate that asserts inside the loop names
    // only the first offender.
    assert(problems.length == 0,
        format("The set of files that read a *SelectionOrder plane for its VALUE " ~
               "has changed:\n%s\n\nSites found:\n%s\n" ~
               "If the new read RANKS elements, route it through `Mesh." ~
               "lastSelectedInSelectionOrder` / " ~
               "`selectedFaceIndicesInSelectionOrder` instead — those filter by " ~
               "the Select bit first and a raw plane scan does not (task 2440). " ~
               "If it copies, zeroes or reports the plane, add a roster row here " ~
               "saying which and why.",
               problems, render(sc.sites)));
    // POPULATION FLOOR. It was 9 when this cell was written and is 8 since
    // task 4059 generated `mesh_planes.d`'s dropped-face record through a
    // `static foreach`, which put that read out of a text scanner's reach —
    // see the "ALSO NOT ROSTERED" note above for why the row went away rather
    // than becoming a zero. 9 again since task 7132's `edgeChainWalk` row.
    assert(hits.length == 8,
        format("selection-order value-read population changed: expected 8, found %d",
               hits.length));
}


// ---------------------------------------------------------------------------
// Gate 3 — the floor, asserted last
// ---------------------------------------------------------------------------
unittest {
    const sc = scanSource();

    assert(sc.files >= kMinFilesScanned,
        format("the census walked only %d files under source/ (floor %d) — a " ~
               "scanner that lost its place finds nothing and every gate above " ~
               "passes for the wrong reason", sc.files, kMinFilesScanned));
    assert(sc.sites.length > 0,
        "the census found no plane reads at all, anywhere — the stripper has " ~
        "desynced or the plane names have been renamed out from under it");
    assert(sc.bareMentions >= kBareMentionsRecorded,
        format("bare mentions of a *SelectionOrder plane fell to %d from the " ~
               "recorded %d. That is not a failure by itself, but the recorded " ~
               "number is what makes the header's stated hole — a scan that " ~
               "takes the plane as a PARAMETER and indexes it under another " ~
               "name — visible at all. Re-count and update the constant with " ~
               "the reason.", sc.bareMentions, kBareMentionsRecorded));
}
