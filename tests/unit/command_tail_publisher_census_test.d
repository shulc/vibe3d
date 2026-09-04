// command_tail_publisher_census_test — a command's LAST mesh publisher must
// be a DELIVERING one (task 1932, closing task 1906 stage 2a review item 1).
//
// WHAT THIS GATE IS FOR. `Mesh` has TWO accumulate-only funnels —
// `noteChange` (`source/mesh.d:2246`) and `noteSelectionChange`
// (`source/mesh.d:2610`, "the SECOND of two funnels", `:2625`) — and neither
// one registers with `deliverPending`/the batch close on its own. A command
// whose only mesh-side calls are accumulate-only therefore delivers NOTHING
// on its own commits and rides only the once-per-frame drain (or, since task
// 1932 stage 3, the `Command.apply` anchor) — measured on the live app:
// `select.invert` moved `deliveryCount` by 0 while moving `flushCount` by 1.
// Three such tails were found witness-less by review (`load.d` revert,
// `import_result.d` apply + revert) and closed at the RULE level rather than
// with three individual behavioural cells — the table below is the rule's
// executable form.
//
// THE RULE, PRECISELY. Scan `source/commands/**` for occurrences of EITHER
// funnel. An occurrence is LEGAL only if the SAME operation reaches a real
// publisher — `publishChange`, `commitChange` or `commitRestored` — AFTER it,
// so the accumulate-only call is a "note now, real publish comes right after"
// shape rather than a genuine dead tail. "After it" takes three shapes, and
// each row below names WHICH, because they are not equally easy to keep true:
//   (a) lower in the SAME function — the strongest, and the only shape under
//       `source/commands/**` today (`hide.d`);
//   (b) in the CALLER, which the note's own function cannot see — a row of
//       this shape is only as durable as the caller, so it names the caller;
//   (c) EARLIER in the same operation (a write-after-publish), which is legal
//       only because the class was already published for this edit. That argument cannot be checked mechanically (it needs to know
// WHICH function, and whether the publisher is really downstream in the same
// operation) — so it is checked BY HAND, once, and recorded in the table
// below with the file:line of the real publisher that makes it legal. What
// IS checked mechanically is that the SET of accumulate-only occurrences
// does not grow past what was checked by hand.
//
// Empty on the FIRST funnel today: zero `noteChange(` under
// `source/commands/**`. Seven legal occurrences on the combined set: three
// `noteSelectionChange(` in `commands/mesh/hide.d` (block A) and four
// `noteChange(MeshEditScope.Maps)` under `source/tools/**` (block C, made
// mandatory by review O1 — the same rule, the same mechanism, a different
// root). An EIGHTH occurrence anywhere, in either root, is a finding.
//
// KEYED ON (file, COUNT), NOT (file, line) — same move
// `revert_entry_census_test.d` makes and for the same reason (R2-4): a line
// number rots on any unrelated insertion above it, and the argument lives in
// this table's TEXT, not in a line number the table would have to keep in
// sync by hand. `hide.d`'s three sites collapse to one row with count 3; the
// four `source/tools/**` sites are documented as four individual rows (one
// per site, matching the card's own table by hand) and aggregated by file
// when compared, because `morph_route.d` carries two of the four.
//
// THREE BLOCKS, ONE COMMIT (both roots share the mechanism, so the table and
// the exception rows are reviewed together):
//   A — `source/commands/**`, both funnels, against the recorded exceptions.
//   B — POSITIVE CONTROL: `publishChange(` is found in exactly the twelve
//       named files under `source/commands/**`. Without this, block A is
//       vacuous on a scanner that lost its place: a desynced blanker finds
//       NOTHING for either funnel and reports a clean, wrong, pass.
//   C — `source/tools/**`, same rule, own root, own floor, own exceptions.
//
// THE COMMENT STRIPPER IS MANDATORY, NOT HYGIENE — two live witnesses, not a
// hypothetical: `source/commands/file/load.d`'s own doc comment contains the
// prose "`publishChange`, not `noteChange`" and
// `source/commands/mesh/loop_slice.d`'s contains
// "`noteSelectionChange(...); deliverPending();`" verbatim, INSIDE a
// backtick span, with the trailing paren a naive line-grep would match. A
// scanner that did not blank comments would either double-count a legal
// site or, worse, invent a finding in a file that has none. Probed directly
// below with the same sentences.
module tests.unit.command_tail_publisher_census_test;

import std.algorithm : canFind, startsWith;
import std.array     : appender;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : strip;

import tests.unit.census_symbols : sharedBlankNonCode = blankNonCode,
    sharedBlankUnittestBodies = blankUnittestBodies, enclosingSymbols,
    symbolAt, LedgerRow, LedgerHit, reconcile, symbolTokenHits;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// Duplicated from `version_poll_census_test.d` / `revert_entry_census_test.d`
// (accepted pattern between census files — see either file's own header).
// ---------------------------------------------------------------------------
package alias blankNonCode = sharedBlankNonCode;

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private alias blankUnittestBodies = sharedBlankUnittestBodies;

private string codeView(string src) { return blankUnittestBodies(blankNonCode(src)); }

// ---------------------------------------------------------------------------
// Scanning.
// ---------------------------------------------------------------------------

private struct FunnelSite { string file; string symbol; string funnel; size_t line; }

/// EVERY spelling of an accumulate-only tail. Four names, not two, and neither
/// half of that is decoration — task 2007 built an escape for each.
///
///   `noteChange` / `noteSelectionChange` — the two funnels, matched as BARE
///   IDENTIFIERS. This file scanned for the literal `"noteChange("` until task
///   2007 finding #3, which showed `auto fn = &mesh.noteChange; fn(x);` — a
///   genuine dead accumulate tail with no publisher after it — scanning as ZERO
///   sites, because the parenthesis belongs to `fn`.
///
///   `undeliveredChanges_` / `undeliveredSelDomains_` — the FIELDS, and this is
///   task 2007's third pass, which is the sharper of the two findings because it
///   needs no delegate trick at all. Both funnels reduce to
///   `undeliveredChanges_ |= flags;` (plus `undeliveredSelDomains_` for the
///   second), and BOTH fields are declared on `struct Mesh` with no `private`
///   in front of them — `struct Mesh` carries no visibility label at all, so
///   every field is public by D's default. The pass proved it live: a
///   `mesh.undeliveredChanges_ |= MeshEditScope.Maps;` written into
///   `commands/mesh/add_point.d`'s `applyImpl` left this census green.
///   Neither field occurs anywhere under `source/**` outside `mesh.d` today
///   (checked), so these two names add no site and cost no exception row; they
///   simply make the one remaining way to write the tail visible.
///
/// This is the same correction `sel_channel_census_test.d` already carries for
/// the same reason — its `kField` (`selSubs`) exists because the METHOD name
/// was not the only way to register a subscriber.
private immutable string[] kFunnels = [
    "noteChange", "noteSelectionChange",
    "undeliveredChanges_", "undeliveredSelDomains_",
];

/// Whole-word occurrence of `id` in `ln`: `noteChangeTwice` must not count as
/// `noteChange`, and an identifier that merely ENDS in one of the four must not
/// either.
private bool containsIdent(string ln, string id) {
    if (id.length == 0 || ln.length < id.length) return false;
    foreach (i; 0 .. ln.length - id.length + 1) {
        if (ln[i .. i + id.length] != id) continue;
        if (i > 0 && isIdentChar(ln[i - 1])) continue;
        if (i + id.length < ln.length && isIdentChar(ln[i + id.length])) continue;
        return true;
    }
    return false;
}

/// Every accumulate-only funnel, over one file's already-code-only text. One
/// site per (line, name), as before — a line naming a funnel twice is still one
/// site, which is what the recorded per-file COUNTS were measured against.
private FunnelSite[] scanFunnels(string label, string code) {
    auto sites = appender!(FunnelSite[]);
    auto lines = code.splitLinesKeep();
    const symbols = enclosingSymbols(code);
    foreach (li, ln; lines)
        foreach (f; kFunnels)
            if (containsIdent(ln, f))
                sites.put(FunnelSite(label, symbolAt(symbols, li), f, li + 1));
    return sites.data;
}

/// `std.string.splitLines`, spelled locally so the file has one fewer import
/// to keep in sync with the other census files' duplicated helper set.
private string[] splitLinesKeep(string s) {
    import std.string : splitLines;
    return s.splitLines();
}

private bool hasPublisher(string code) {
    return code.canFind("publishChange(");
}

private struct TreeScan {
    FunnelSite[] sites;
    LedgerHit[]   publisherHits;
    size_t        filesScanned;
}

private TreeScan scanRoot(string relRoot) {
    TreeScan r;
    foreach (de; dirEntries(buildPath(repoRoot, relRoot), "*.d", SpanMode.depth)) {
        ++r.filesScanned;
        const string label = de.name[repoRoot.length + 1 .. $];
        const string code  = codeView(readText(de.name));
        r.sites.put_(scanFunnels(label, code));
        r.publisherHits ~= symbolTokenHits(code, label, "publishChange(");
    }
    return r;
}

// appender-free accumulation helper (TreeScan.sites is a plain dynamic
// array; `put_` just appends, named to avoid colliding with Appender.put).
private void put_(ref FunnelSite[] arr, FunnelSite[] more) { arr ~= more; }

// ---------------------------------------------------------------------------
// SCANNER CELLS, FIRST.
// ---------------------------------------------------------------------------

/// The comment stripper is load-bearing, not hygiene — reproduced verbatim
/// from `source/commands/mesh/loop_slice.d`'s own prose, which contains the
/// funnel call INSIDE a comment, backticked, with the trailing paren a naive
/// line-grep would match.
unittest {
    enum string probe = q"PROBE
void f() {
    // every selection writer calls
    // `noteSelectionChange(...); deliverPending();` unconditionally. So
    // the kernel's tail delivers from inside this batch.
}
PROBE";
    const code = codeView(probe);
    assert(scanFunnels("probe.d", code).length == 0,
        "a funnel call quoted INSIDE A COMMENT must not be a site — this is "
      ~ "loop_slice.d's own sentence, verbatim");
}

/// Same for `load.d`'s prose ("`publishChange`, not `noteChange`"). This cell
/// used to say the bare word was harmless because it carries no trailing paren
/// — TRUE of the old `"noteChange("` needle and FALSE since task 2007 made the
/// trigger a bare identifier. The stripper is now the ONLY thing keeping this
/// sentence out of the site set, which is what the cell is here to prove.
unittest {
    enum string probe = q"PROBE
void f() {
    // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`, and this site
    // is the one that was MEASURED blind.
}
PROBE";
    const code = codeView(probe);
    assert(scanFunnels("probe.d", code).length == 0);
}

/// TASK 2007 FINDING #3 — THE DELEGATE ESCAPE, PINNED. A dead accumulate tail
/// with no publisher after it, written as an indirect call. Under the old
/// `"noteChange("` needle this scanned as ZERO sites; put that needle back and
/// this assert reddens by its own message.
unittest {
    enum string probe = q"PROBE
void applyImpl() {
    auto fn = &mesh.noteChange;
    fn(MeshEditScope.Maps);
}
PROBE";
    const code = codeView(probe);
    auto s = scanFunnels("probe.d", code);
    assert(s.length == 1 && s[0].funnel == "noteChange",
        format("the delegate take `&mesh.noteChange` scanned as %d site(s), "
             ~ "expected 1 on `noteChange` — task 2007 finding #3's escape: %s",
               s.length, s));
}

/// TASK 2007, THIRD PASS — THE FIELD ESCAPE, PINNED, and it needs no delegate
/// at all. `noteChange` IS `undeliveredChanges_ |= flags;`, and the field is
/// public (`struct Mesh` carries no visibility label), so the tail can be
/// written without either funnel name appearing. The pass proved this live in
/// `commands/mesh/add_point.d` with the census fully green.
unittest {
    enum string probe = q"PROBE
void applyImpl() {
    mesh.undeliveredChanges_ |= MeshEditScope.Maps;
    return true;
}
PROBE";
    const code = codeView(probe);
    auto s = scanFunnels("probe.d", code);
    assert(s.length == 1 && s[0].funnel == "undeliveredChanges_",
        format("a direct write to the public accumulate field scanned as %d "
             ~ "site(s), expected 1 on `undeliveredChanges_`: %s", s.length, s));
}

/// …and its selection-domain sibling, which `noteSelectionChange` writes as
/// well as `undeliveredChanges_`.
unittest {
    enum string probe = q"PROBE
void applyImpl() {
    mesh.undeliveredSelDomains_ |= 1u << SelDomain.Vertex;
}
PROBE";
    const code = codeView(probe);
    auto s = scanFunnels("probe.d", code);
    assert(s.length == 1 && s[0].funnel == "undeliveredSelDomains_",
        format("%s", s));
}

/// THE BOUNDARY CONTROL. A bare-identifier trigger must not swallow a LONGER
/// name that merely contains one of the four — otherwise the widening buys a
/// false positive, which is the same defect as a check that cannot redden.
unittest {
    enum string probe = q"PROBE
void applyImpl() {
    mesh.noteChangeTwice(MeshEditScope.Maps);
    auto x = preNoteChange;
    auto y = undeliveredChanges_Shadow;
}
PROBE";
    const code = codeView(probe);
    auto s = scanFunnels("probe.d", code);
    assert(s.length == 0,
        format("an identifier that merely CONTAINS a funnel name was counted "
             ~ "as a site: %s", s));
}

/// A live site is still found when comments surround it.
unittest {
    enum string probe = q"PROBE
void applyImpl() {
    // a real note, then a real publisher right after
    mesh.noteSelectionChange(SelDomain.Vertex);
    mesh.commitChange(MeshEditScope.Marks);
}
PROBE";
    const code = codeView(probe);
    auto s = scanFunnels("probe.d", code);
    assert(s.length == 1 && s[0].funnel == "noteSelectionChange",
        format("%s", s));
}

/// The positive control's own discriminator: `publishChange(` is found, and
/// a nearby `noteChange` (a DIFFERENT identifier, `publishChange` is not a
/// substring match of it) is not confused with it.
unittest {
    enum string withPublisher = q"PROBE
void applyImpl() {
    mesh.publishChange(MeshEditScope.Position);
}
PROBE";
    assert(hasPublisher(codeView(withPublisher)));

    enum string withoutPublisher = q"PROBE
void applyImpl() {
    mesh.noteChange(MeshEditScope.Maps);
}
PROBE";
    assert(!hasPublisher(codeView(withoutPublisher)));
}

// ---------------------------------------------------------------------------
// THE RECORDED TABLES.
// ---------------------------------------------------------------------------

/// `count` is how many funnel occurrences THIS row accounts for — 3 for
/// `hide.d`'s single row (all three sites share one argument), 1 for each of
/// block C's four individual-site rows.
/// Block A's exceptions, `source/commands/**`. One row: `hide.d` carries
/// three `noteSelectionChange(` calls, all legal because the SAME function
/// (`revertImpl`'s restore path) calls the real publisher
/// `mesh.commitChange(MeshEditScope.Marks | MeshEditScope.Visibility)` right
/// after them, at `hide.d:277`.
private static immutable LedgerRow[] kCommandsExceptions = [
    LedgerRow("HideRevertCommon.revertImpl|noteSelectionChange", 3,
        "three noteSelectionChange( calls (Vertex/Edge/Face) followed, in "
      ~ "the same function, by the real publisher "
      ~ "mesh.commitChange(MeshEditScope.Marks | MeshEditScope.Visibility) "
      ~ "at hide.d:277"),
];

/// The twelve files under `source/commands/**` known to call `publishChange(`
/// — block B's positive control. NAMES only; block B does not count
/// occurrences per file.
private static immutable LedgerRow[] kPublishChangeSites = [
    LedgerRow("Ai3dImportResult.applyImpl", 1, "AI import apply"),
    LedgerRow("Ai3dImportResult.revertImpl", 1, "AI import revert"),
    LedgerRow("FileLoad.applyImpl", 1, "document load apply"),
    LedgerRow("FileLoad.revertImpl", 1, "document load revert"),
    LedgerRow("MeshDetriangulate.runKernel", 1, "detriangulate publisher"),
    LedgerRow("MeshMergeFaces.runKernel", 1, "merge publisher"),
    LedgerRow("MeshMoveVertex.evaluate", 1, "move publisher"),
    LedgerRow("MeshQuadruple.runKernel", 1, "quadruple publisher"),
    LedgerRow("Remesh.evaluate", 1, "remesh publisher"),
    LedgerRow("Subdivide.evaluate", 1, "subdivide publisher"),
    LedgerRow("runFacetedFamily", 1, "faceted subdivision publisher"),
    LedgerRow("MeshTriple.runKernel", 1, "triple publisher"),
    LedgerRow("MeshLoadRaw.applyImpl", 1, "mesh-load publisher"),
    LedgerRow("SceneReset.applyImpl", 1, "scene-reset publisher"),
];

/// Block C's exceptions, `source/tools/**` — one row per site (four total,
/// matching the card's table by hand), all `noteChange(MeshEditScope.Maps)`.
/// `morph_route.d` carries two; the argument is the SAME shape for all four
/// — a real publisher lower in the same operation — and `xfrm_apply.d`
/// writes that argument out loud at `:299-308`.
private static immutable LedgerRow[] kToolsExceptions = [
    LedgerRow("applyXformMatrix|noteChange", 1,
        "noteChange(Maps) at :716 — SHAPE (b): the publisher is in the "
      ~ "CALLER, xfrm_apply.d's routed-constraint apply (:971), not in this "
      ~ "function; this row is only as durable as that caller"),
    LedgerRow("applySymmetryMirrorRouted|noteChange", 1,
        "noteChange(Maps) at :214 — SHAPE (b), same caller (site 1 of 2)"),
    LedgerRow("applySymmetryMirrorDeltaRouted|noteChange", 1,
        "noteChange(Maps) at :367 — SHAPE (b), same caller (site 2 of 2)"),
    LedgerRow("XfrmApplyImpl.applyTRS|noteChange", 1,
        "noteChange(Maps) at :289 — SHAPE (c), write-after-publish: the "
      ~ "class was already published by applyFold EARLIER in the same apply; "
      ~ "xfrm_apply.d:299-308 writes that argument out loud"),
];

// ---------------------------------------------------------------------------
// Shared comparison, reused by blocks A and C so the "unaccounted" message is
// worded once.
// ---------------------------------------------------------------------------
private void assertNoUnaccountedTails(string blockLabel, string rootLabel,
                                       const FunnelSite[] sites,
                                       const LedgerRow[] recorded)
{
    LedgerHit[] hits;
    foreach (ref s; sites)
        hits ~= LedgerHit(s.symbol ~ "|" ~ s.funnel, s.file, s.line, s.funnel);
    const bad = reconcile(recorded, hits);

    assert(bad.length == 0, format(
        "task 1932 (%s, %s): the accumulate-only funnel tail SET no longer "
      ~ "matches the recorded exception table.%s\n\n"
      ~ "  A command's tail must be a `publishChange` / `commitChange` / "
      ~ "`commitRestored` — a DELIVERING publisher. An accumulate-only "
      ~ "funnel call (`noteChange` / `noteSelectionChange`) is legal ONLY if "
      ~ "a real publisher runs lower in the SAME function for the SAME "
      ~ "operation — add the file to this table with that argument and bump "
      ~ "its count, or (if there truly is no downstream publisher) give the "
      ~ "command a real one instead of leaving it silent.",
        blockLabel, rootLabel, bad));
}

// ---------------------------------------------------------------------------
// THE GATE — one commit, three blocks.
// ---------------------------------------------------------------------------
unittest {
    // Block A + (part of) B: source/commands/**.
    const cmdScan = scanRoot("source/commands");

    assertNoUnaccountedTails("block A", "source/commands",
        cmdScan.sites, kCommandsExceptions);

    // Block B — positive control. Without it, block A is vacuous on a
    // scanner that lost its place: a desynced blanker finds nothing for
    // EITHER funnel and ALSO nothing for `publishChange(`, so a bad walk and
    // a healthy tree with the funnels genuinely retired look identical to
    // block A alone.
    {
        const publisherProblems = reconcile(kPublishChangeSites,
                                             cmdScan.publisherHits);
        assert(publisherProblems.length == 0, format(
            "task 1932 block B (positive control): the set of "
          ~ "source/commands/** files calling publishChange( no longer "
          ~ "matches the recorded twelve.%s%s",
            publisherProblems, ""));
        assert(cmdScan.publisherHits.length == 14,
            format("expected 14 command publishChange sites, found %d",
                   cmdScan.publisherHits.length));
    }

    assert(cmdScan.filesScanned >= 150, format(
        "the tail-publisher census only walked %d file(s) under "
      ~ "source/commands/ — it has almost certainly lost its place (164 "
      ~ "stand there as of 2026-08-26). Fix the walk, do not lower this "
      ~ "floor.", cmdScan.filesScanned));

    // Block C — source/tools/**, same rule, own root (mandatory per review
    // O1: the mechanism the first two blocks build is needed here anyway).
    const toolsScan = scanRoot("source/tools");

    assertNoUnaccountedTails("block C", "source/tools",
        toolsScan.sites, kToolsExceptions);

    assert(toolsScan.filesScanned >= 60, format(
        "the tail-publisher census only walked %d file(s) under "
      ~ "source/tools/ — it has almost certainly lost its place (65 stand "
      ~ "there as of 2026-08-26). Fix the walk, do not lower this floor.",
        toolsScan.filesScanned));

}
