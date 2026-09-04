// confined_publisher_census_test — the CONFINED-DELIVERY marker has a closed
// caller set, and this is the thing that closes it (task 2000).
//
// ===========================================================================
// WHAT THE MARKER IS AND WHY ITS CALLER SET IS AN INVARIANT
// ===========================================================================
// `Mesh.publishConfinedChange` delivers a change exactly as `publishChange`
// does, plus one claim: *every vertex I moved is inside a live gesture's own
// moving set, and the tool that owns that gesture is already handing the same
// set to its consumers as an EXCLUSION*. On that claim
// `mesh_dirty.g_settledGeomEpochs` withholds its advance, and two caches — the
// snap candidate grid and the symmetry pair table — go on serving answers
// built before the gesture started.
//
// The claim is true at the three sites that make it today, and it was checked
// by hand at each: the transform tools pass `movingVertexIndices` (the
// processed verts UNION their symmetry partners) to `snapCursor` as
// `excludeVerts`, and `snap.kindExcluded` drops an element if ANY incident
// vertex is in that set — so "moves with this gesture" and "excluded from this
// query" are the same predicate.
//
// A FOURTH CALLER BREAKS IT SILENTLY. Some later tool mixes in
// `XfrmApplyImpl`, or a command decides its own edit is "confined too", and
// now a cache holds a table across a change nobody is excluding. The result is
// a mid-gesture answer describing where a vertex USED to be — precisely the
// failure task 1906 stage 2c existed to prevent.
//
// ===========================================================================
// WHY IT HAS TO BE A CENSUS AND NOT AN ASSERTION
// ===========================================================================
// Nothing in the language can express "these three call sites and no others":
// `package` on a member of the dotless root module `mesh` is reachable from NO
// other module at all (measured under task 1903, see
// `commit_seam_census_test.d`'s header for the probe), so there is no spelling
// that admits the legitimate callers.
//
// And nothing in the SUITE can express it either, which is the sharper half.
// The failure of a key that is too WIDE is a rate — visible, and pinned by
// `tests/test_snap_grid_drag_rate.d`. The failure of one that is too NARROW is
// a stale answer, and a stale bucket grid does not crash, does not change a
// draw call, and returns a plausible vertex. `test_bus_snap_grid_after_drag.d`
// catches the one shape of it we already knew about; a NEW confined publisher
// would be a new shape, with no fixture written for it. So the gate is on the
// caller set, where the invariant actually lives.
//
// ===========================================================================
// WHAT IS COUNTED
// ===========================================================================
// Four identifiers, over `source/**`, as whole words, in a CODE view:
//
//   publishConfinedChange   the publisher — the door itself
//   beginConfinedDelivery   \ the raw marker under it. Counted too, because
//   endConfinedDelivery     / a caller that opens the window by hand around
//                             an ordinary `publishChange` gets exactly the
//                             same licence while naming none of it — a hole
//                             a census of the publisher alone would leave
//                             wide open.
//   deliveryIsConfined      the single READER. If a second consumer starts
//                             keying on the marker it owes the obligation
//                             `mesh_dirty.g_settledGeomEpochs` documents (a
//                             stated reason why a confined change cannot
//                             reach its answer), and that is a review, not a
//                             silent edit.
//
// THE CODE VIEW MATTERS, AND IT IS THE SAME PAIR OF STRIPPERS THE VERSION-POLL
// CENSUS USES (imported, not copied):
//   * comments and string literals are blanked — this tree carries a dozen
//     prose mentions of every one of these names, including the paragraph you
//     are reading, and a census that counted sentences would move whenever
//     someone explained the mechanism;
//   * `unittest` bodies are blanked — `source/mesh_dirty.d`'s own cell drives
//     `beginConfinedDelivery` / `endConfinedDelivery` five times by hand, and
//     counting those would make this gate red every time that cell is edited
//     while saying nothing about production;
//   * `version (unittest)` blocks are LEFT ALONE, because they are production
//     seams a call can hide in.
//
// ===========================================================================
// HOW IT FAILS, AND THE PROOF THAT IT CAN
// ===========================================================================
// Per (DECLARATION, identifier) counts, so a message can say WHICH door moved
// rather than "the total went up" — and per DECLARATION rather than per FILE
// since task 4056, because the law is about the three call sites and not about
// which module they are filed under: `git mv`-ing `XfrmApplyImpl.applyFold`
// used to redden this census while changing nothing it is about. The findings
// come from `census_symbols.reconcile` and there are four, each with its own
// sentence: a recorded pair whose count changed, an identifier in a
// declaration nobody recorded, a recorded declaration that has vanished, and
// one symbol realised in two different files (which is the one shape a
// path-free key could otherwise let a site migrate through unseen).
//
// THE OLD TABLE'S PROSE WAS WRONG AND THE SYMBOLS SAY SO. It recorded the two
// `xfrm_apply.d` publishes as "the applyChain tail and the applyFold tail";
// the scanner reports `XfrmApplyImpl.applyTRSLegacyPowPath` and
// `XfrmApplyImpl.applyFold`. A count against a path cannot be checked against
// its own description — a count against a declaration is the description.
//
// SELF-DEFENDING AGAINST VACUITY, in both directions. Every recorded count is
// non-zero, so a stripper that lost its place and ate a file reports "recorded
// 2, found 0" rather than passing; and emptying `kSites` does not silence the
// gate either, because every occurrence then lands in the unrecorded branch.
// A floor on the total is asserted anyway, AFTER the gate it protects, so that
// it can never bury the message that matters.
//
// SEEN RED, 2026-08-26: adding `mesh.publishConfinedChange(MeshEditScope
// .Position);` to a fourth site turned this module red naming that file.
//
// SEEN RED AGAIN AFTER THE KEY CHANGED, 2026-09-04 (task 4056): the SAME
// mutation, in the same file, now names the DECLARATION —
// `mutation4056Drill|publishConfinedChange — NOT RECORDED AT ALL, scanner
// found 1 occurrence(s) / found source/tools/transform/rotate.d:2009`. And
// the move it was costing is now silent: renaming `xfrm_apply.d` (module line
// and its one import, no other edit) left this census green while three
// path-keyed checks elsewhere reddened on nothing.
module tests.unit.confined_publisher_census_test;

import std.algorithm : sort;
import std.array     : appender;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : splitLines;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
                                   enclosingSymbols, symbolAt,
                                   LedgerRow, LedgerHit, reconcile;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The four names that carry the confined-delivery licence.
private immutable string[] kIdents = [
    "publishConfinedChange", "beginConfinedDelivery",
    "endConfinedDelivery", "deliveryIsConfined",
];

/// THE RECORDED SET, keyed by the enclosing DECLARATION. Every row says what
/// the occurrences are; every CALL row additionally names the exclusion set
/// that makes its claim true, because that — not the call — is the thing a
/// reviewer has to check.
///
/// A declaration's own line sits in its ENCLOSING scope, which is why the
/// three `ChangeBus` rows and the `Mesh` row read as the aggregate: the door
/// is declared there. The calls INSIDE `Mesh.publishConfinedChange` carry the
/// method's own path, so the declaration and its body are two different keys
/// and neither can absorb the other.
private static immutable LedgerRow[] kSites = [
    LedgerRow("ChangeBus|beginConfinedDelivery", 1,
        "the declaration"),
    LedgerRow("ChangeBus|endConfinedDelivery", 1,
        "the declaration (clamped, and counts its own imbalance)"),
    LedgerRow("ChangeBus|deliveryIsConfined", 1,
        "the declaration — the read half"),

    LedgerRow("Mesh|publishConfinedChange", 1,
        "the declaration — the ONLY production pairing of the raw marker, "
      ~ "which is why the two rows below must stay at one each"),
    LedgerRow("Mesh.publishConfinedChange|beginConfinedDelivery", 1,
        "publishConfinedChange opens the window"),
    LedgerRow("Mesh.publishConfinedChange|endConfinedDelivery", 1,
        "…and closes it in a scope(exit), so a throw cannot leak the depth"),

    LedgerRow("noteMeshChange|deliveryIsConfined", 1,
        "noteMeshChange's gate — the single reader, and the whole of the "
      ~ "settled watcher's semantics"),

    LedgerRow("XfrmApplyImpl.applyTRSLegacyPowPath|publishConfinedChange", 1,
        "the legacy pow-path tail. Exclusion: the tool passes "
      ~ "`movingVertexIndices` to `snapCursor` as `excludeVerts`, and "
      ~ "`kindExcluded` drops any element with an incident moving vertex"),
    LedgerRow("XfrmApplyImpl.applyFold|publishConfinedChange", 1,
        "the applyFold tail. Same exclusion, same tool"),
    LedgerRow("TransformTool.uploadToGpu|publishConfinedChange", 1,
        "uploadToGpu's per-apply publish. Exclusion: `toProcess`, the same "
      ~ "set, handed to the same query"),
];

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// Whole-word occurrences of `id` in `ln`. `publishConfinedChangeTwice` must
/// not count as `publishConfinedChange`, and neither must a longer name that
/// merely ends with one of ours.
private size_t countIdent(string ln, string id) {
    if (id.length == 0 || id.length > ln.length) return 0;
    size_t n = 0;
    foreach (i; 0 .. ln.length - id.length + 1) {
        if (ln[i .. i + id.length] == id
            && (i == 0 || !isIdentChar(ln[i - 1]))
            && (i + id.length >= ln.length || !isIdentChar(ln[i + id.length])))
            ++n;
    }
    return n;
}

private struct Hit {
    string file;    // DIAGNOSTIC ONLY — never a key (task 4056)
    string ident;
    string symbol;  // the enclosing declaration path
    size_t line;    // 1-based, into the ORIGINAL text
    string text;
}

/// The ledger key: the declaration a door sits in, then the door's own name.
/// No path, by construction.
private string keyOf(const Hit h) { return h.symbol ~ "|" ~ h.ident; }

/// Scan one file's text. Split out from the tree walk so the cells below can
/// feed it a scratch buffer — a probe that has to be written into `source/`
/// and taken out again is a probe nobody re-runs.
package Hit[] scanConfinedSource(string label, string src) {
    const string code = blankUnittestBodies(blankNonCode(src));
    const string[] syms = enclosingSymbols(code);
    auto hits = appender!(Hit[]);
    foreach (li, ln; code.splitLines()) {
        foreach (id; kIdents) {
            const size_t n = countIdent(ln, id);
            foreach (_; 0 .. n) {
                import std.string : strip;
                hits.put(Hit(label, id, symbolAt(syms, li), li + 1, ln.strip));
            }
        }
    }
    return hits.data;
}

private Hit[] scanTree() {
    auto hits = appender!(Hit[]);
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        hits.put(scanConfinedSource(de.name[repoRoot.length + 1 .. $],
                                    readText(de.name)));
    return hits.data;
}

// ---------------------------------------------------------------------------
// SCANNER CELLS FIRST — druntime stops a module at its first failing assert,
// so a broken scanner has to say so in its own words rather than surface as a
// strange tree verdict below.
// ---------------------------------------------------------------------------

/// A real call is seen; the same name in prose is not. Both directions,
/// because a scanner that flagged the comments would be red for ever and one
/// that flagged nothing would be green for ever, and only the PAIR tells them
/// apart.
unittest {
    enum string probe = q"PROBE
        // A sentence about publishConfinedChange, which is not a call.
        /// And a doc comment naming beginConfinedDelivery too.
        void applyFold() {
            mesh.publishConfinedChange(MeshEditScope.Position);
        }
PROBE";
    auto h = scanConfinedSource("probe.d", probe);
    assert(h.length == 1, format(
        "the scanner must see exactly the ONE call in this probe and neither "
      ~ "of the two prose mentions above it — it saw %d: %s", h.length, h));
    assert(h[0].ident == "publishConfinedChange", h[0].ident);
    assert(h[0].line == 4, format("wrong line: %d", h[0].line));

    // THE KEY IS THE DECLARATION (task 4056), so the same call scanned under
    // a different file name yields the SAME key — this is the acceptance
    // criterion of that task, asserted inside the census it protects rather
    // than only in the scanner's own module.
    assert(h[0].symbol == "applyFold", format(
        "the enclosing declaration is `applyFold`; the walker said `%s`",
        h[0].symbol));
    auto moved = scanConfinedSource("somewhere/else.d", probe);
    assert(moved.length == 1 && keyOf(moved[0]) == keyOf(h[0]), format(
        "a `git mv` must not move this verdict: `%s` in one file, `%s` in "
      ~ "another", keyOf(h[0]), moved.length ? keyOf(moved[0]) : "-"));
}

/// A `unittest` body is not production; a `version (unittest)` block IS. The
/// two are one character of context apart, and `source/mesh_dirty.d` contains
/// both shapes today — its cell drives the marker by hand five times, and this
/// census must not count any of them.
unittest {
    enum string probe = q"PROBE
        version (unittest) {
            void hook() { changeBus.beginConfinedDelivery(); }
        }
        unittest {
            changeBus.beginConfinedDelivery();
            changeBus.endConfinedDelivery();
        }
PROBE";
    auto h = scanConfinedSource("probe.d", probe);
    assert(h.length == 1, format(
        "a `version (unittest)` block is a PRODUCTION seam and its call must "
      ~ "count; a real `unittest` body must not. Expected 1 hit, got %d: %s",
        h.length, h));
    assert(h[0].line == 2, format(
        "the surviving hit must be the one inside `version (unittest)`, at "
      ~ "line 2 — got line %d", h[0].line));
}

/// A name that merely CONTAINS one of ours is not one of ours.
unittest {
    enum string probe = q"PROBE
        void f() {
            mesh.publishConfinedChangeTwice(x);
            auto myEndConfinedDelivery = 1;
        }
PROBE";
    auto h = scanConfinedSource("probe.d", probe);
    assert(h.length == 0, format("whole-word matching failed: %s", h));
}

// ---------------------------------------------------------------------------
// THE GATE.
// ---------------------------------------------------------------------------
unittest {
    // NO "recorded file still exists" PRE-CHECK ANY MORE. It was there to
    // turn a moved module into a readable diagnosis; since task 4056 a moved
    // module is not a finding at all, and a RENAMED declaration gets that
    // diagnosis from `reconcile`'s found-NONE branch instead.
    auto hits = scanTree();

    auto led = appender!(LedgerHit[]);
    foreach (ref h; hits)
        led.put(LedgerHit(keyOf(h), h.file, h.line, h.text));

    size_t recordedTotal = 0;
    foreach (ref r; kSites) recordedTotal += r.count;

    const string bad = reconcile(kSites, led.data);

    assert(bad.length == 0, format(
        "task 2000: the CONFINED-DELIVERY caller set no longer matches the "
      ~ "recorded one.%s\n\n"
      ~ "  Recorded: %d occurrence(s) over %d (declaration, name) pair(s). "
      ~ "Scanner: %d.\n\n"
      ~ "  A confined publish is not an ordinary one. It tells "
      ~ "`mesh_dirty.g_settledGeomEpochs` to WITHHOLD its advance, so the snap "
      ~ "candidate grid and the symmetry pair table keep answering from a "
      ~ "table built before this change. That is sound for exactly one reason: "
      ~ "the vertices the publisher moved are the ones its own tool is "
      ~ "handing those consumers as an EXCLUSION, so every element it made "
      ~ "stale is an element the query already drops.\n"
      ~ "    * a NEW publisher — name the consumer-side exclusion set that "
      ~ "makes your claim true, at the call, and add the row here. If you "
      ~ "cannot name one, you want `publishChange`: it delivers identically "
      ~ "and withholds nothing.\n"
      ~ "    * a raw `beginConfinedDelivery` outside `Mesh"
      ~ ".publishConfinedChange` — this takes the same licence while naming "
      ~ "none of the reasoning. Route it through the publisher.\n"
      ~ "    * a NEW `deliveryIsConfined` reader — it inherits the obligation "
      ~ "written over `g_settledGeomEpochs`: state, at your own reader, why a "
      ~ "confined change cannot reach your answer. A consumer that cannot "
      ~ "keys on `g_geomEpochs`, which is the default.\n"
      ~ "    * FEWER than recorded — a site was deleted, or the declaration "
      ~ "holding it was renamed; move or drop the row in the same commit.\n"
      ~ "    * MOVING one of these functions to another FILE is none of the "
      ~ "above and must be silent here. If a plain `git mv` reddened this "
      ~ "census, the census is wrong, not the move.\n\n"
      ~ "  Getting this wrong is INVISIBLE to every value assertion in the "
      ~ "tree: a cache keyed too narrowly returns a plausible stale answer, "
      ~ "one keyed too widely returns the right answer slowly, and the draw "
      ~ "calls are identical either way.",
        bad, recordedTotal, kSites.length, hits.length));

    // Vacuity floor, AFTER the assertion it protects. The gate above is
    // already self-defending — every recorded count is non-zero, so an eaten
    // file reddens as a shortfall — but a floor costs one line and covers the
    // case where the recorded list itself is emptied along with the scanner.
    // 10 occurrences stood at the round-1 review fold; the floor is set below
    // that so ordinary growth does not touch it.
    assert(hits.length >= 6, format(
        "only %d occurrence(s) of the confined-delivery names found in "
      ~ "source/** — there were 10 when this census was written, and the "
      ~ "declarations alone account for four. A collapse like this means the "
      ~ "stripper lost its place (an unhandled wysiwyg or token string "
      ~ "desyncs it and it eats the rest of the file), not that the mechanism "
      ~ "was removed. Fix the scanner; do not lower this floor.", hits.length));

    // POPULATION, the other half. `reconcile` returning "" is ALSO what an
    // empty table over an empty scan returns, so the ledger needs its own
    // floor, and the two totals need to be stated as an equality — which
    // costs no ceremony, `recordedTotal` being summed from the table itself.
    assert(kSites.length >= 8, format(
        "the recorded set is down to %d row(s) from 10. A table that small "
      ~ "cannot be the confined-delivery caller set, and `reconcile` agreeing "
      ~ "with it over a dead scanner is a green that measured nothing.",
        kSites.length));
    assert(hits.length == recordedTotal, format(
        "the scanner found %d occurrence(s) and the table records %d. The "
      ~ "gate above passed, so the two agree declaration by declaration; this "
      ~ "can therefore only mean the arithmetic changed under it.",
        hits.length, recordedTotal));
}
