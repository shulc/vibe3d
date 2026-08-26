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
// Per (file, identifier) counts, so a message can say WHICH door moved rather
// than "the total went up". Three findings are possible and each has its own
// sentence: a recorded pair whose count changed, an identifier appearing in a
// file nobody recorded, and a recorded file that has vanished.
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
module tests.unit.confined_publisher_census_test;

import std.algorithm : sort;
import std.array     : appender;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : splitLines;

import tests.unit.version_poll_census_test : blankNonCode, blankUnittestBodies;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The four names that carry the confined-delivery licence.
private immutable string[] kIdents = [
    "publishConfinedChange", "beginConfinedDelivery",
    "endConfinedDelivery", "deliveryIsConfined",
];

private struct SiteRow {
    string file;
    string ident;
    size_t count;
    string why;     // what those occurrences ARE, and for a call, the
                    // consumer-side exclusion its claim rests on
}

/// THE RECORDED SET. Every row says what the occurrences are; every CALL row
/// additionally names the exclusion set that makes its claim true, because
/// that — not the call — is the thing a reviewer has to check.
private immutable SiteRow[] kSites = [
    SiteRow("source/change_bus.d", "beginConfinedDelivery", 1,
        "the declaration"),
    SiteRow("source/change_bus.d", "endConfinedDelivery", 1,
        "the declaration (clamped, and counts its own imbalance)"),
    SiteRow("source/change_bus.d", "deliveryIsConfined", 1,
        "the declaration — the read half"),

    SiteRow("source/mesh.d", "publishConfinedChange", 1,
        "the declaration — the ONLY production pairing of the raw marker, "
      ~ "which is why the two rows below must stay at one each"),
    SiteRow("source/mesh.d", "beginConfinedDelivery", 1,
        "publishConfinedChange opens the window"),
    SiteRow("source/mesh.d", "endConfinedDelivery", 1,
        "…and closes it in a scope(exit), so a throw cannot leak the depth"),

    SiteRow("source/mesh_dirty.d", "deliveryIsConfined", 1,
        "noteMeshChange's gate — the single reader, and the whole of the "
      ~ "settled watcher's semantics"),

    SiteRow("source/tools/transform/xfrm_apply.d", "publishConfinedChange", 2,
        "the applyChain tail and the applyFold tail. Exclusion: the tool "
      ~ "passes `movingVertexIndices` to `snapCursor` as `excludeVerts`, and "
      ~ "`kindExcluded` drops any element with an incident moving vertex"),
    SiteRow("source/tools/transform/transform.d", "publishConfinedChange", 1,
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
    string file;
    string ident;
    size_t line;    // 1-based, into the ORIGINAL text
    string text;
}

/// Scan one file's text. Split out from the tree walk so the cells below can
/// feed it a scratch buffer — a probe that has to be written into `source/`
/// and taken out again is a probe nobody re-runs.
package Hit[] scanConfinedSource(string label, string src) {
    const string code = blankUnittestBodies(blankNonCode(src));
    auto hits = appender!(Hit[]);
    foreach (li, ln; code.splitLines()) {
        foreach (id; kIdents) {
            const size_t n = countIdent(ln, id);
            foreach (_; 0 .. n) {
                import std.string : strip;
                hits.put(Hit(label, id, li + 1, ln.strip));
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
    // Recorded files must still exist — checked FIRST so a moved module gets
    // that diagnosis instead of the gate's "recorded 2, found 0".
    foreach (ref r; kSites)
        assert(buildPath(repoRoot, r.file).exists, format(
            "task 2000 records %d occurrence(s) of `%s` in %s and that file is "
          ~ "gone. If the module moved, move the row; if the call went with "
          ~ "it, move the row to the new file.", r.count, r.ident, r.file));

    auto hits = scanTree();

    size_t[string] found;   // "file|ident" -> count
    foreach (ref h; hits)
        found[h.file ~ "|" ~ h.ident] = found.get(h.file ~ "|" ~ h.ident, 0) + 1;

    auto bad = appender!string;
    size_t recordedTotal = 0;

    void dump(string file, string ident) {
        foreach (ref h; hits)
            if (h.file == file && h.ident == ident)
                bad.put(format("\n        found  %s:%d  %s",
                               h.file, h.line, h.text));
    }

    foreach (ref r; kSites) {
        recordedTotal += r.count;
        const size_t n = found.get(r.file ~ "|" ~ r.ident, 0);
        if (n == r.count) continue;
        bad.put(format("\n    %s — `%s`: recorded %d, scanner found %d\n"
                     ~ "        recorded as: %s",
                       r.file, r.ident, r.count, n, r.why));
        dump(r.file, r.ident);
    }

    foreach (key, n; found) {
        bool recorded = false;
        foreach (ref r; kSites)
            if (r.file ~ "|" ~ r.ident == key) { recorded = true; break; }
        if (recorded) continue;
        import std.string : indexOf;
        const i = key.indexOf('|');
        bad.put(format("\n    %s — `%s`: NOT RECORDED AT ALL, scanner found "
                     ~ "%d occurrence(s)", key[0 .. i], key[i + 1 .. $], n));
        dump(key[0 .. i], key[i + 1 .. $]);
    }

    assert(bad.data.length == 0, format(
        "task 2000: the CONFINED-DELIVERY caller set no longer matches the "
      ~ "recorded one.%s\n\n"
      ~ "  Recorded: %d occurrence(s) over %d (file, name) pair(s). "
      ~ "Scanner: %d over %d.\n\n"
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
      ~ "    * FEWER than recorded — a site was deleted or moved; drop the "
      ~ "row in the same commit.\n\n"
      ~ "  Getting this wrong is INVISIBLE to every value assertion in the "
      ~ "tree: a cache keyed too narrowly returns a plausible stale answer, "
      ~ "one keyed too widely returns the right answer slowly, and the draw "
      ~ "calls are identical either way.",
        bad.data, recordedTotal, kSites.length, hits.length, found.length));

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
}
