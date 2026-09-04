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
// that ranking: `source/mesh.d`, whose three readers are the law
// (`selectedFaceIndicesInSelectionOrder`, `selectedVerticesBySelectionOrder`,
// `lastSelectedInSelectionOrder`), and `source/mesh_ops/select_loop.d`, which
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

import tests.unit.version_poll_census_test : blankNonCode, blankUnittestBodies;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The three planes.
private immutable string[] kPlanes = [
    "vertexSelectionOrder", "edgeSelectionOrder", "faceSelectionOrder",
];

/// The two files allowed to RANK by these planes — the law's home and its one
/// recorded twin. Excluded from the walk entirely; see the header for why
/// neither actually spells an indexed read today.
private immutable string[] kDeclaredHomes = [
    "source/mesh.d",
    "source/mesh_ops/select_loop.d",
];

/// Gate 1's subject: the family that held the nine copies.
private enum string kZeroDir = "source/commands/select/";

/// Gate 2. One row per file that legitimately indexes a plane for its VALUE,
/// with the count and the reason. Ordered by path.
private struct Row { string path; int reads; string why; }
private immutable Row[] kRoster = [
    Row("source/commands/mesh/selection_undo.d", 2,
        "the dense undo IMAGE: reads the live stamp to store it and to decide "
      ~ "whether an edge was manually picked. Not a ranking — it never asks "
      ~ "which stamp is HIGHEST. The same file's three SCRUBBING writes "
      ~ "(`if (!isXSelected(i)) order[i] = 0`) are writes and are not counted."),
    Row("source/http_json.d", 1,
        "the wire serialiser: reports the stamp of one edge, defensively "
      ~ "bounds-checked. A report, not a decision."),
    Row("source/mesh_edit_delta.d", 3,
        "plane CARRIES across a vertex compaction / face reindex — the value "
      ~ "moves index-to-index and is never compared to another element's."),
    Row("source/mesh_planes.d", 0,
        "ZERO since task 4059, and the zero is a statement rather than an "
      ~ "absence. The dropped-face plane record used to spell "
      ~ "`m.faceSelectionOrder[fi]` out; it is now generated by "
      ~ "`FacePlaneDrops.captureFace`'s `static foreach` over `kFacePlanes`, "
      ~ "so the read reaches the plane through `__traits(getMember, m, n)` "
      ~ "and no TEXT scanner can see it. The read did not go away — this "
      ~ "census's reach did. What guards it instead is the plane table "
      ~ "itself plus `tests/unit/mesh_planes_test.d`'s deliberately "
      ~ "independent, hand-written plane list; do not restore a spelled-out "
      ~ "read here to make this row non-zero."),
    Row("source/tools/alignment/align_kernels.d", 2,
        "a genuine RANK read, and legal: `fallbackOrder` sorts an index list "
      ~ "that `operandVertexMask` already filtered to the selection, so the "
      ~ "selected-first rule is satisfied upstream of the sort rather than "
      ~ "inside it."),
];

/// NOT ROSTERED, and worth saying out loud because it is the file a reader
/// expects to find here: `source/snapshot.d` holds the SCRUBBER
/// (`if (!isXSelected(i)) order[i] = 0`, `:452-462`) and its three sites are
/// indexed WRITES, so the scanner classifies them as writes and they need no
/// row. If a genuine read is ever added there the file arrives with "NO roster
/// row" in gate 2, which is the outcome we want.

/// The floor for gate 3 — well under the ~430 `.d` files in `source/` today,
/// so it notices a walk that collapsed without tracking the tree's growth.
private enum size_t kMinFilesScanned = 300;

/// Gate 3's second half: bare mentions of a plane (indexed or not) across the
/// scanned set. This is the number that moves when someone starts passing a
/// plane somewhere new — the hole the header names. It is a FLOOR plus a
/// recorded value, not a rule, so it is asserted with the floor and not with
/// the gates.
private enum int kBareMentionsRecorded = 125;

// ---------------------------------------------------------------------------
// The scanner
// ---------------------------------------------------------------------------

private struct Site { string path; size_t line; string plane; string text; }

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
            found ~= Site(path, line, plane, code[ls .. le]);
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
    foreach (e; dirEntries(root, "*.d", SpanMode.depth)) paths ~= e.name;
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
        s ~= format("    %s:%d  %s  |%s|\n", st.path, st.line, st.plane, st.text);
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

    int[string] live;
    foreach (st; sc.sites) live[st.path] = live.get(st.path, 0) + 1;

    string[] problems;
    foreach (row; kRoster) {
        const got = live.get(row.path, 0);
        if (got != row.reads)
            problems ~= format("  %s: %d value-read(s), roster says %d\n" ~
                               "      why the rostered ones are legal: %s",
                               row.path, got, row.reads, row.why);
    }
    foreach (path, n; live) {
        bool rostered = false;
        foreach (row; kRoster) if (row.path == path) { rostered = true; break; }
        if (!rostered)
            problems ~= format("  %s: %d value-read(s) and NO roster row", path, n);
    }

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
               joinLines(problems), render(sc.sites)));
}

private string joinLines(const string[] xs) {
    string s;
    foreach (x; xs) s ~= x ~ "\n";
    return s;
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
