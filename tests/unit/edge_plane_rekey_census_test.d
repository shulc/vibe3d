// edge_plane_rekey_census_test — the SOUNDNESS BOUNDARY of the per-edge plane
// carry, stated as a predicate over the source instead of as a paragraph
// (task 4191).
//
// ===========================================================================
// THE LAW
// ===========================================================================
// An edge's key is a PAIR OF VERTEX INDICES (`mesh_topo.edgeKey`). So a
// vertex renumbering invalidates every edge key at once, and
// `Mesh.rebuildEdges` cannot see one: at `Mesh.compactUnreferenced` and at
// both weld remaps, `vertices` is reassigned and `faces` rewritten into the
// NEW numbering while `edges` still holds the OLD endpoints.
//
// `mesh_planes.applyEdgePlanes` looks each rebuilt edge up BY THAT KEY. Run
// it in that window and a lookup either MISSES — a dropped mark, the
// conservative failure — or COLLIDES: a mark landing on an unrelated edge,
// which is the dangerous one and is not rare, because a compaction shifts
// indices DOWN and old pairs land on live new pairs.
//
// Task 4059 therefore gave `EdgePlaneCarry.byKey` a stated restriction: it
// may only be asked for by a kernel that renumbers NO vertex. That
// restriction lives in `mesh_planes.d`'s enum header and in NOTHING ELSE —
// no type expresses it, and no behavioural test can, because the failure it
// prevents is a mark on a plausible neighbouring edge, which draws, picks and
// serialises exactly like a correct one. Hence a census, on the seam where
// the invariant actually lives.
//
// ===========================================================================
// WHAT IS ASSERTED, AND WHY IT IS THREE THINGS
// ===========================================================================
// (A) DISJOINTNESS — the boundary itself. No declaration both requests
//     `EdgePlaneCarry.byKey` and renumbers vertices. "Renumbers vertices" is
//     read off the tree's OWN marker for it: a call to
//     `mesh_selsets.selSetRekeyEdges`, which `kExemptPlanes` already names as
//     the caller's obligation on a vertex remap. That marker is the right key
//     precisely because it is not this test's invention — a kernel that
//     renumbers vertices and does not call it is already broken for
//     `edgeSetMask`, and `mesh_wire_compact_undo_test` is where that reddens.
//
// (B) THE LIVE-PATH MITIGATION — the reason (A) is not yet urgent. Every
//     vertex-renumbering declaration in `source/mesh.d` calls
//     `clearEdgeSelectionResize()` in its own body, so a stale Select bit
//     cannot outlive the renumbering on the live path. This was ASSERTED
//     rather than assumed because the card carried it as an estimate: the
//     three sites were read one by one (`Mesh.applyVertexRemapAndRebuild`,
//     `Mesh.applyVertexRemap`, `Mesh.compactUnreferenced`) and all three hold.
//     Pinning it matters because (A)'s tolerance depends on it — the day a
//     fourth renumbering kernel lands without the clear, `byKey` stops being
//     the only way a mark can move to a foreign edge.
//
// (C) THE LEDGER — every `selSetRekeyEdges` caller says HOW it settles the
//     edge planes, so a NEW one cannot be born green under someone else's
//     note. The five replay twins in `mesh_edit_delta.d` deliberately do NOT
//     call `clearEdgeSelectionResize`: they settle through `finalize()`'s
//     tail (`rebuildEdges()` at the DEFAULT `leaveIndexed`, then a raw length
//     fit, `refreshHiddenDerived()`, and an endpoint-keyed selection restore).
//     That is a different mechanism, and recording it as such is the point —
//     an assertion that demanded `clearEdgeSelectionResize` everywhere would
//     have to be relaxed for them, and a relaxed assertion is one nobody can
//     read.
//
// ===========================================================================
// WHY EACH HALF CANNOT BE VACUOUSLY TRUE
// ===========================================================================
// "The two sets are disjoint" holds over two empty sets, and that is the
// defect `CLAUDE.md` says this project pays for most. So BOTH populations are
// floored with exact counts before the disjointness is asked, and the floors
// sit ABOVE it: a stripper that lost its place and ate a file reports
// "expected 2 byKey requesters, found 0" rather than passing quietly. (B) is
// floored the same way — three declarations, named — so "every renumbering
// site clears" cannot be satisfied by finding no renumbering sites.
//
// ===========================================================================
// MUTATION (task 4191 `## Мутация`)
// ===========================================================================
// The drill is: change `Mesh.compactUnreferenced`'s `rebuildEdges();` to
// `rebuildEdges(EdgePlaneCarry.byKey);` — i.e. arm the key carry inside the
// one kernel that renumbers every vertex it keeps. That is the exact defect
// this file exists to catch, and it compiles.
//
// SEEN RED, 2026-09-05:
//
//   core.exception.AssertError@tests/unit/edge_plane_rekey_census_test.d(324):
//   SOUNDNESS BOUNDARY BROKEN: `Mesh.compactUnreferenced` asks `rebuildEdges`
//   for `EdgePlaneCarry.byKey` AND renumbers vertices (it calls
//   `selSetRekeyEdges(`).
//
// AND THE ORDER OF THE ASSERTS WAS FIXED BY THAT RUN, not by taste. The first
// attempt put the exact-count floors above the predicate, and the same
// mutation reddened `requesters.length == 2` instead — druntime stopped the
// module there, so the assertion carrying the LAW never ran and its
// explanation was never printed. A count that says "found 3" is a worse
// failure message than one that says which declaration is unsound and why.
// The counts now sit below the predicate; the only floor above it is
// non-emptiness, which is all that is needed to kill the vacuous pass.
//
// THE DEFECT IS REAL AND NOT MERELY DETECTED, which the same run also shows:
// arming that carry moved SEVEN rows of the frozen undo-parity corpus
// (`weld_merge`, `delete_remove`, `slice_cut`, `cleanup`, `bevel`,
// `vertex_bevel`, `extrude_extend`), each on `edgePlanes[N].order`, and put
// `edgeSelectionOrder` into `face_reindex_arming_test`'s armed-revert
// residual. That is the "eight rows of the corpus move" that
// `mesh_planes.EdgePlaneCarry`'s own header predicts for an unconditional
// carry, observed.
module tests.unit.edge_plane_rekey_census_test;

import std.algorithm : canFind, sort;
import std.array     : appender;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : splitLines, strip;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
                                   enclosingSymbols, symbolAt,
                                   LedgerRow, LedgerHit, reconcile;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// The three needles. Each is spelled WITH its `(` or `.` where that is what
// separates a use from a mention, so the tree's own prose about these names
// — including the header you are reading — cannot be counted. (The comment
// and string strippers already blank prose; the punctuation is the second
// belt, and it is what keeps the `import mesh_selsets : … selSetRekeyEdges,`
// line at `mesh.d:152` out of the caller set.)
// ---------------------------------------------------------------------------

/// The request for the key carry. `Mesh.rebuildEdges` contains two of these
/// itself — they are the primitive's own dispatch, not a request — and the
/// requester set below subtracts that declaration by name.
private enum string kByKey = "EdgePlaneCarry.byKey";

/// The tree's marker for "this declaration renumbers vertices".
private enum string kRekey = "selSetRekeyEdges(";

/// The live-path settle.
private enum string kClear = "clearEdgeSelectionResize(";

/// The primitive that DISPATCHES on the carry. Its own two occurrences of
/// `kByKey` are comparisons inside `rebuildEdges`, so it is excluded from the
/// requester set — and named here rather than filtered by a line pattern, so
/// that moving the dispatch into a helper reddens (C) instead of silently
/// widening the exemption.
private enum string kCarryDispatcher = "Mesh.rebuildEdges";

/// The declaration line of `selSetRekeyEdges` itself sits at module scope in
/// `mesh_selsets.d`; it is a declaration, not a call.
private enum string kModuleScope = "(module scope)";

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

package LedgerHit[] scanEdgeSeamSource(string label, string src) {
    const string code = blankUnittestBodies(blankNonCode(src));
    const string[] syms = enclosingSymbols(code);
    auto hits = appender!(LedgerHit[]);
    foreach (li, ln; code.splitLines()) {
        static foreach (needle; [kByKey, kRekey, kClear]) {{
            size_t from = 0;
            while (from + needle.length <= ln.length) {
                const rel = ln[from .. $];
                size_t at = size_t.max;
                foreach (i; 0 .. rel.length - needle.length + 1)
                    if (rel[i .. i + needle.length] == needle) { at = i; break; }
                if (at == size_t.max) break;
                hits.put(LedgerHit(symbolAt(syms, li) ~ "|" ~ needle,
                                   label, li + 1, ln.strip));
                from += at + needle.length;
            }
        }}
    }
    return hits.data;
}

private LedgerHit[] scanTree() {
    auto hits = appender!(LedgerHit[]);
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        hits.put(scanEdgeSeamSource(de.name[repoRoot.length + 1 .. $],
                                    readText(de.name)));
    return hits.data;
}

/// The declarations carrying at least one occurrence of `needle`, sorted and
/// deduplicated so a count is a count of DECLARATIONS, not of call sites.
private string[] declsWith(const LedgerHit[] hits, string needle) {
    string[] outp;
    foreach (ref h; hits) {
        const string suffix = "|" ~ needle;
        if (h.key.length <= suffix.length) continue;
        if (h.key[$ - suffix.length .. $] != suffix) continue;
        const string decl = h.key[0 .. $ - suffix.length];
        if (!outp.canFind(decl)) outp ~= decl;
    }
    sort(outp);
    return outp;
}

// ===========================================================================
// SCANNER CELL FIRST — druntime stops a module at its first failing assert,
// so a broken scanner has to say so in its own words rather than surface
// below as a strange verdict about the tree.
// ===========================================================================

/// A real use is seen; the same names in prose and in an import list are not.
/// BOTH directions, because a scanner that flagged the comments would be red
/// for ever and one that flagged nothing would be green for ever — only the
/// pair tells them apart.
unittest {
    enum string probe = q"PROBE
        // A sentence about EdgePlaneCarry.byKey, which is not a request.
        /// And a doc comment naming selSetRekeyEdges, which is not a call.
        import mesh_selsets : selSetResizeVertex, selSetRekeyEdges,
                              selSetGatherVertexMaskForward;
        void spinEdge() {
            rebuildEdges(EdgePlaneCarry.byKey);
        }
        void compactUnreferenced() {
            selSetRekeyEdges(this, (uint v) => v, WireKeyPolicy.carry);
            rebuildEdges();
            clearEdgeSelectionResize();
        }
PROBE";
    auto h = scanEdgeSeamSource("probe.d", probe);
    assert(h.length == 3, format(
        "the scanner must see exactly the THREE uses in this probe — the "
      ~ "byKey request, the rekey call and the clear — and none of the two "
      ~ "prose mentions or the import list; it saw %d: %s", h.length, h));

    assert(declsWith(h, kByKey) == ["spinEdge"], format(
        "the byKey request belongs to `spinEdge`; the walker said %s",
        declsWith(h, kByKey)));
    assert(declsWith(h, kRekey) == ["compactUnreferenced"], format(
        "the rekey call belongs to `compactUnreferenced`; the walker said %s",
        declsWith(h, kRekey)));
    assert(declsWith(h, kClear) == ["compactUnreferenced"], format(
        "the clear belongs to `compactUnreferenced`; the walker said %s",
        declsWith(h, kClear)));

    // THE KEY IS THE DECLARATION, not the path (task 4056): the same probe
    // scanned under another file name yields the same three keys, so a
    // `git mv` cannot move this verdict.
    auto moved = scanEdgeSeamSource("somewhere/else.d", probe);
    assert(moved.length == h.length, "a rename changed the hit count");
    foreach (i, ref x; moved)
        assert(x.key == h[i].key, format(
            "a rename moved a key: `%s` became `%s`", h[i].key, x.key));
}

// ===========================================================================
// (B) THE LIVE-PATH MITIGATION — asserted ABOVE (A), and deliberately so.
//
// This block must stay GREEN under (A)'s mutation, and everything above a
// first red line is an observation about control flow: to reach (A)'s
// failure the run had to clear every straight-line assert here. Ordering it
// this way buys both halves from one run, which `CLAUDE.md` prefers over
// isolation wherever two reds are not both required.
// ===========================================================================

unittest {
    auto hits = scanTree();

    // The population floor comes FIRST. "Every renumbering site clears" is
    // true over an empty set of renumbering sites, and that is exactly the
    // vacuity this project pays for; the exact three are named so that one
    // vanishing is a finding rather than a smaller true statement.
    immutable string[] kLiveRenumberers = [
        "Mesh.applyVertexRemap",            // weld remap (mesh.d)
        "Mesh.applyVertexRemapAndRebuild",  // the other weld remap
        "Mesh.compactUnreferenced",         // drop-and-permute
    ];

    const rekeyDecls = declsWith(hits, kRekey);
    const clearDecls = declsWith(hits, kClear);

    foreach (want; kLiveRenumberers)
        assert(rekeyDecls.canFind(want), format(
            "POPULATION FLOOR: `%s` is recorded as a vertex-renumbering "
          ~ "declaration and the scanner did not find `%s` in it. Either it "
          ~ "was renamed (move the row), or it stopped re-keying the edge "
          ~ "sets — which is a defect in `edgeSetMask`, not a ledger edit.\n"
          ~ "    scanner found these renumbering declarations: %s",
            want, kRekey, rekeyDecls));

    // …and only NOW the property. Each live renumbering kernel drops the edge
    // selection in its own body, so a Select bit cannot outlive the index
    // space it was written in.
    foreach (want; kLiveRenumberers)
        assert(clearDecls.canFind(want), format(
            "`%s` renumbers vertices (it calls `%s`) but its body no longer "
          ~ "calls `clearEdgeSelectionResize()`. After a renumbering the edge "
          ~ "array is rebuilt into a NEW index space while `edgeMarks` still "
          ~ "holds the old one, so a surviving Select bit denotes a DIFFERENT "
          ~ "edge — a mark on a foreign edge, which draws and picks exactly "
          ~ "like a correct one. Restore the clear, or state here what "
          ~ "replaces it.\n"
          ~ "    declarations that do call it: %s",
            want, kRekey, clearDecls));
}

// ===========================================================================
// (A) THE BOUNDARY — the assert this file exists for.
// ===========================================================================

unittest {
    auto hits = scanTree();

    // Requesters of the key carry, minus the primitive's own dispatch.
    string[] requesters;
    foreach (d; declsWith(hits, kByKey))
        if (d != kCarryDispatcher) requesters ~= d;

    // Declarations that renumber vertices, minus the declaration line of
    // `selSetRekeyEdges` itself.
    string[] renumberers;
    foreach (d; declsWith(hits, kRekey))
        if (d != kModuleScope) renumberers ~= d;

    // NON-EMPTINESS FIRST, AND ONLY NON-EMPTINESS. Disjointness is true of
    // two empty sets, so a stripper fault that ate a file would otherwise
    // read as a clean bill of health. This is the floor that kills that
    // vacuity, and it is deliberately the WEAKEST statement that does —
    // see the ORDERING note below for why the exact counts sit lower.
    assert(requesters.length > 0 && renumberers.length > 0, format(
        "POPULATION FLOOR: the disjointness below is vacuously true over an "
      ~ "empty set. Requesters of `%s`: %s. Declarations that renumber "
      ~ "vertices (they call `%s`): %s. Both must be non-empty for this "
      ~ "module to be asserting anything at all; a zero here is a scanner "
      ~ "fault, not a clean tree.",
        kByKey, requesters, kRekey, renumberers));

    // THE PREDICATE, ABOVE THE EXACT COUNTS AND NOT BELOW THEM. Ordering is
    // load-bearing here and it was fixed by a measurement, not by taste: with
    // the exact-count floors first, arming the carry in
    // `Mesh.compactUnreferenced` reddened `requesters.length == 2` and
    // druntime stopped the module there, so the assertion that states the
    // actual LAW never ran and its message — the one that explains why a key
    // carry over a renumbering is unsound — was never printed. The counts
    // still guard drift; they just do it after the thing they are guarding
    // has had its say.
    //
    // THE PREDICATE. An edge key is a pair of vertex indices, so a kernel
    // that renumbers vertices and asks for the key carry hands
    // `applyEdgePlanes` OLD keys to look up in a NEW index space.
    foreach (r; requesters)
        assert(!renumberers.canFind(r), format(
            "SOUNDNESS BOUNDARY BROKEN: `%s` asks `rebuildEdges` for `%s` AND "
          ~ "renumbers vertices (it calls `%s`).\n"
          ~ "    An edge key is a PAIR OF VERTEX INDICES. In that declaration "
          ~ "`edges` still holds endpoints in the OLD numbering when "
          ~ "`captureEdgePlanes` keys off them, while the rebuilt `edges` are "
          ~ "in the NEW one — so every lookup either misses (a dropped mark) "
          ~ "or COLLIDES, putting a mark on an unrelated edge. A compaction "
          ~ "shifts indices down, so collisions are not rare.\n"
          ~ "    This is the restriction stated at "
          ~ "`mesh_planes.EdgePlaneCarry` (task 4059) and the subject of task "
          ~ "4191. Either re-key the edge endpoints through the same "
          ~ "permutation BEFORE `rebuildEdges`, or leave this kernel at "
          ~ "`EdgePlaneCarry.leaveIndexed`.", r, kByKey, kRekey));

    // …and only now the EXACT counts. A new requester that renumbers nothing
    // is not unsound, so it does not trip the predicate above — but it is
    // still a decision somebody owes an argument for, and this is where it
    // gets asked.
    assert(requesters == ["Mesh.spinEdge", "Mesh.spinEdgesByKeys"], format(
        "exactly two declarations may ask `rebuildEdges` for `%s` — "
      ~ "`Mesh.spinEdge` and `Mesh.spinEdgesByKeys`, the two kernels that "
      ~ "rewrite windings only. The scanner found %s.\n"
      ~ "    A NEW requester is not automatically wrong — the predicate above "
      ~ "stayed green, so whatever was added renumbers no vertex — but it "
      ~ "owes the argument that this is so, and a row in `kSites`.",
        kByKey, requesters));

    assert(renumberers.length == 8, format(
        "eight declarations renumber vertices today (three live kernels in "
      ~ "`mesh.d`, five replay twins in `mesh_edit_delta.d`). The scanner "
      ~ "found %d: %s", renumberers.length, renumberers));
}

// ===========================================================================
// (C) THE LEDGER — every occurrence, keyed by declaration, with the reason.
// A new site of any of the three needles lands in "NOT RECORDED AT ALL"
// rather than under a neighbour's note.
// ===========================================================================

/// Only the two seam needles are ledgered. `clearEdgeSelectionResize` is NOT:
/// it has 27 call sites across nine files, almost all of them ordinary
/// topology mutators with nothing to do with this seam, and a row per site
/// would make this file red on every unrelated bevel edit while saying
/// nothing about the boundary. Its three seam-relevant occurrences are
/// asserted positionally in (B) instead, which is where they mean something.
private static immutable LedgerRow[] kSites = [
    LedgerRow("Mesh.rebuildEdges|" ~ kByKey, 2,
        "the primitive's own dispatch — the `edgePlanes == byKey` test that "
      ~ "arms the capture, and the one that applies it. Not requests, and "
      ~ "excluded from the requester set by name"),
    LedgerRow("Mesh.spinEdge|" ~ kByKey, 1,
        "requester 1 of 2. Rewrites the two windings across a shared edge; "
      ~ "touches no vertex, so every edge key stays valid"),
    LedgerRow("Mesh.spinEdgesByKeys|" ~ kByKey, 1,
        "requester 2 of 2. Same kernel, driven by keys; same argument"),

    LedgerRow(kModuleScope ~ "|" ~ kRekey, 1,
        "the declaration line of `selSetRekeyEdges` in `mesh_selsets.d`, "
      ~ "which sits at module scope. A declaration, not a call"),

    LedgerRow("Mesh.applyVertexRemapAndRebuild|" ~ kRekey, 1,
        "LIVE weld remap. Settles with `rebuildEdges(); "
      ~ "clearEdgeSelectionResize();` — asserted in (B)"),
    LedgerRow("Mesh.applyVertexRemap|" ~ kRekey, 1,
        "LIVE weld remap. Same settle, asserted in (B)"),
    LedgerRow("Mesh.compactUnreferenced|" ~ kRekey, 1,
        "LIVE drop-and-permute. Same settle, asserted in (B). This is the "
      ~ "kernel (A)'s mutation arms, because it renumbers every vertex it "
      ~ "keeps"),

    LedgerRow("applyForward|" ~ kRekey, 1,
        "REPLAY twin. Settles through `finalize()`'s tail, not through "
      ~ "`clearEdgeSelectionResize` — see this file's (C)"),
    LedgerRow("applyReindexForward|" ~ kRekey, 1,
        "REPLAY twin of `compactUnreferenced`'s permutation. Same tail"),
    LedgerRow("applyReindexReverse|" ~ kRekey, 1,
        "REPLAY twin, restoring the pre-compaction index space. Same tail"),
    LedgerRow("removeVertsForward|" ~ kRekey, 1,
        "REPLAY twin of the vertex drop. Same tail"),
    LedgerRow("removeVertsReverse|" ~ kRekey, 1,
        "REPLAY twin re-inserting dropped vertices. Same tail"),
];

unittest {
    LedgerHit[] seam;
    foreach (ref h; scanTree()) {
        const string suffix = "|" ~ kClear;
        if (h.key.length > suffix.length
            && h.key[$ - suffix.length .. $] == suffix) continue;
        seam ~= h;
    }
    const string bad = reconcile(kSites, seam);
    assert(bad.length == 0,
        "THE EDGE-PLANE SEAM CENSUS MOVED (task 4191).\n"
      ~ "Every declaration that asks `rebuildEdges` for the KEY carry, and "
      ~ "every declaration that renumbers vertices, is recorded above with "
      ~ "what makes it sound. A finding here means one of those two sets "
      ~ "changed; read the boundary at `mesh_planes.EdgePlaneCarry` before "
      ~ "editing a row.\n" ~ bad);

    // Floor on the total, AFTER the gate it protects so it can never bury the
    // message that matters.
    assert(seam.length >= 12, format(
        "the seam census found only %d occurrences; it recorded 12, so a "
      ~ "scanner that ate a file would otherwise pass here", seam.length));
}
