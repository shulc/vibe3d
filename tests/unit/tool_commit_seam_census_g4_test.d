// tool_commit_seam_census_g4_test — the text half of the gesture-recording
// seam, for group G4, the EDIT family (task 1905, phase C).
//
// ONE FILE PER FAMILY, and that is not filing tidiness. A single tree-wide
// census would serialise the four phase-C lanes behind each other, and the
// failure it invites is the silent one: two lanes each append a roster line to
// the same file, the merge keeps one, and the lost line's family is then
// unwatched with nothing red to say so. Per-family files make that collision a
// textual conflict instead of a disappearance. The structure below is lane
// G1's (`tool_commit_seam_census_g1_test.d`) member for member; what changed is
// the population, the roster, and the two places where G4 is not G1 — both
// marked HERE G4 DIFFERS.
//
// THE KEY MEMBER KEYS ON THE WHOLE CALL SURFACE, NOT ON A REGEX OF ONE NAME.
// Revision 2 of the plan measured these families with `history_?\.record`, and
// that predicate missed two recorders elsewhere in the tree and four legitimate
// `invalidateRedo` calls. The lesson is not "the regex was one name short"; a
// widened regex is another list the next person forgets to widen. So the census
// collects EVERY `history.<NAME>(` in the family and compares the multiset
// against a roster that carries a reason per name. A sixth history primitive
// called from a tool tomorrow reddens this for free, with the name and the
// address, and no predicate edit.
//
// HERE G4 DIFFERS (1) — WHY `source/tool.d` IS IN THE POPULATION, AND WHY IT
// CARRIES THE SAME FOUR ROWS AS G1'S FILE. After the migration NONE of G4's
// eleven tools touches `CommandHistory` at all: their whole call surface is
// EMPTY. A census over the eleven alone would therefore be satisfied by a
// scanner that read nothing — the exact "check that cannot come out
// differently" this project pays for most. `class Tool` lives in
// `source/tool.d`, outside `source/tools/**`, and after the migration it holds
// the family's ONLY surviving recorder. Including it makes the non-vacuity
// floor real (four calls, one per record primitive plus the belt's run-close)
// AND puts the seam itself under this lane's eye. Yes, G1's file rosters the
// same four rows; that duplication is deliberate — each family must be able to
// prove its own scan non-vacuous without depending on another lane's file
// still existing.
//
// HERE G4 DIFFERS (2) — WHAT THIS CENSUS ABSORBED. Lane G0-G4 shipped
// `tests/unit/tool_gesture_runopen_g4_test.d` with two blocks, the second of
// which asserted "each of the eleven files calls `history.record(` exactly
// once". Its own header named this file as its successor ("when that file
// lands it supersedes Block 2"), and phase C removed it: two censuses over one
// file set, with two rosters, is the merge hazard above in miniature. Members 2
// and 3 below are strictly wider than what they replaced — the whole surface
// rather than one name, plus the seam's own call sites and their MODES. The
// behavioural block of that file (record vs recordInSession really do differ in
// `runOpen()`, and really do agree on stack depth) stayed where it was; it is
// not a text census and nothing here replaces it.
//
// WHAT IT CANNOT SEE, said here so nobody trusts it for that: a seam that
// recorded the RIGHT carrier with the WRONG payload. That is the frozen plane
// fixture's job (`tests/fixtures/tool_gesture/g4.json`, read by
// `tests/test_tool_gesture_g4.d`, eleven cells). And it cannot see WHICH tool
// recorded, either: nine of G4's eleven commit under the single wire name
// `mesh.bevel_edit` (only `poly.extrude` and `mesh.reduceTool` stand apart), so
// the committed name discriminates two cells out of eleven and nothing else.
// The eleven `postCommit` plane dumps are pairwise distinct and are what the
// fixture keys on.
//
// MUTATIONS, one per member, each reddening only its own — every one of them
// was run, and the verbatim message is in the task card (3200):
//   1. drop a `.d` file into `source/tools/edit/` -> member 1, by name.
//   2. write `history.consolidate(...)` into any G4 tool -> member 2, as an
//      UNROSTERED name on the history surface with its file and line. This is
//      the mutation a `history_?\.record` regex would not have caught at all.
//   3. flip one site's `GestureRecordMode.Plain` to `.InSession` -> member 3,
//      with the per-file mode counts. (The plane fixture stays GREEN under
//      this one — measured by lane G0-G4 before the migration and re-measured
//      after it; both primitives push exactly once, so no wire surface moves.)
//   4. re-declare `void setUndoBindings` in any G4 tool -> member 4, by file.
//   5. delete `t.setGestureBindings(...)` from one registration block -> member
//      5, by wire id. It COMPILES; the tool is simply never bound.
//   6. re-declare `CommandHistory history;` in any G4 tool -> member 6, by
//      file. It COMPILES TOO, silently shadowing the base field — which is the
//      whole reason phase B's deletions and the base declaration had to be one
//      commit.
//
// EVERY NON-VACUITY FLOOR IS INSIDE THE ACCUMULATOR, NEVER AHEAD OF IT, and
// that is a correction to the shape lane G1 shipped (found by the G2 lane
// mutating its own census, 2026-08-29). A floor written as a separate assert
// ABOVE the roster raise aborts the module first — druntime stops at the first
// failed assert — so it SWALLOWS the roster row it exists to accompany: you
// read "the scanner found 0 calls" and never learn which file moved. Folded in,
// the floor is one more finding in the same list, the module fails once, and a
// mutation run can be checked on the observable that separates the two: does it
// report ITS OWN row, or the floor's line? Every mutation above was re-run
// against this shape and reports its own row.
//
// LANE: `dub test --config=tests`. (The mutation drill above also runs this
// file standalone — `dmd -unittest -main -run` — because it imports nothing
// from the repo and reads the tree as TEXT at run time, so its own binary is
// rebuilt from this exact source every time and the mutated files are read
// fresh. That is a convenience for the drill, never a substitute for the gate.)
module tests.unit.tool_commit_seam_census_g4_test;

import std.algorithm : sort, uniq;
import std.array     : appender, array;
import std.conv      : to;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.path      : baseName, buildPath, dirName;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode, enclosingSymbols, symbolAt,
    LedgerRow, LedgerHit, reconcile, symbolTokenHits;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// The stripper, because the count is the whole point. A doc comment that names
// `history.record(` moves the number, and this file's job is to notice a real
// recorder, not a sentence about one.
//
// Same shape as `tests/unit/commit_seam_census_test.d`'s, and with the same
// known gap: wysiwyg strings (`r"…"`) and character literals (`'"'`) can desync
// it. None of the population contains either today, and the guard against a
// silent desync is not a promise — it is the non-vacuity floor in members 2 and
// 3: a scanner that lost its place eats the rest of the file, and both totals
// collapse and redden with a message that says so.
// ---------------------------------------------------------------------------
private alias stripCommentsAndStrings = blankNonCode;

private size_t countOccurrences(string hay, string needle) {
    size_t n = 0, i = 0;
    while (i + needle.length <= hay.length) {
        if (hay[i .. i + needle.length] == needle) { ++n; i += needle.length; }
        else ++i;
    }
    return n;
}

private size_t lineOf(string src, size_t pos) {
    size_t n = 1;
    foreach (i; 0 .. pos) if (src[i] == '\n') ++n;
    return n;
}

private bool isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// Every `history.<NAME>(` / `history_.<NAME>(` in `src`, as (name, line).
/// Hand-scanned rather than regex'd so the receiver term stays exactly the one
/// the plan's population is defined over.
private struct SurfaceHit { string symbol; string name; size_t line; }

private SurfaceHit[] historySurface(string src) {
    SurfaceHit[] hits;
    const symbols = enclosingSymbols(src);
    size_t i = 0;
    while (true) {
        auto rel = src[i .. $].indexOf("history");
        if (rel < 0) break;
        size_t p = i + cast(size_t) rel;
        i = p + 7;
        // Must be a whole identifier: nothing identifier-ish before it.
        if (p > 0 && isIdentChar(src[p - 1])) continue;
        size_t q = p + 7;
        if (q < src.length && src[q] == '_') ++q;            // `history_`
        while (q < src.length && (src[q] == ' ' || src[q] == '\t' || src[q] == '\n')) ++q;
        if (q >= src.length || src[q] != '.') continue;
        ++q;
        while (q < src.length && (src[q] == ' ' || src[q] == '\t' || src[q] == '\n')) ++q;
        size_t nameStart = q;
        while (q < src.length && isIdentChar(src[q])) ++q;
        if (q == nameStart) continue;
        string nm = src[nameStart .. q];
        size_t r = q;
        while (r < src.length && (src[r] == ' ' || src[r] == '\t' || src[r] == '\n')) ++r;
        if (r >= src.length || src[r] != '(') continue;      // a read, not a call
        const line = lineOf(src, p);
        hits ~= SurfaceHit(symbolAt(symbols, line - 1), nm, line);
    }
    return hits;
}

// ---------------------------------------------------------------------------
// THE FAMILY. All eleven G4 tools live in ONE directory, `source/tools/edit/`
// — the eight edit kernels plus Bridge, DragWeld and Tack — which is why
// member 1 can DERIVE the file set from a walk instead of trusting a table.
// The directory is not the family, though: four more `.d` files sit beside
// them and are named below with the reason each is not a G4 member.
//
// `source/tool.d` joins the population for the reason in the header: after the
// migration it is the family's only surviving recorder, and without it every
// scan below is vacuous.
// ---------------------------------------------------------------------------
private enum string[] kG4Files = [
    "bridge_tool.d", "drag_weld.d", "edge_bevel.d", "poly_bevel.d",
    "poly_extrude.d", "poly_inset_tool.d", "reduce.d", "tack.d",
    "vert_merge_tool.d", "vertex_bevel_tool.d", "vertex_extrude_tool.d",
];

private struct NonMember { string file; string why; }

private enum NonMember[] kEditDirNonMembers = [
    NonMember("edge_extend.d",
        "group G1 — one of the two `setDelta` carriers; migrated in phase B "
      ~ "and rostered by tool_commit_seam_census_g1_test.d"),
    NonMember("edge_extrude.d",
        "group G1 — the twin of the above, same phase, same census"),
    NonMember("preview_rebuild.d",
        "not a tool: the shared restore-the-cage-and-re-run-the-kernel seam "
      ~ "(task 1620). No class, no gesture, no history"),
    NonMember("smooth_relax.d",
        "not a tool: the pure-math relaxation kernel behind the Topology Pen's "
      ~ "Smooth gesture (task 0478). Its tool is G7's, in topology_pen/"),
];

private string[] populationPaths() {
    string[] r;
    foreach (f; kG4Files) r ~= buildPath("source", "tools", "edit", f);
    r ~= "source/tool.d";
    return r;
}

// ---------------------------------------------------------------------------
// 1. THE FILE SET IS WALKED, NOT TRUSTED.
//
//    A new tool dropped into `source/tools/edit/` is a candidate member of this
//    family whether or not anyone updates a table, and it must not join the
//    tree unnoticed by the census that owns the directory it landed in. The
//    anti-duplication guard comes first: a typo in either roster throws when
//    the file is read, but a DUPLICATE is silent and would leave one real
//    member unscanned and green forever.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;

    auto names = kG4Files.dup;
    foreach (nm; kEditDirNonMembers) names ~= nm.file;
    auto sorted = names.dup;
    sorted.sort();
    if (sorted.uniq.array.length != names.length)
        problems ~= "    · the two rosters name only "
                  ~ sorted.uniq.array.length.to!string ~ " DISTINCT file(s) "
                  ~ "across " ~ names.length.to!string ~ " rows — a duplicate "
                  ~ "leaves one member unscanned, and its per-file checks below "
                  ~ "then pass by never running";

    string[] found;
    foreach (e; dirEntries(buildPath(repoRoot, "source", "tools", "edit"),
                           "*.d", SpanMode.shallow))
        found ~= baseName(e.name);
    found.sort();

    if (found.length < 12)
        problems ~= "    · NON-VACUITY: the walk of `source/tools/edit/` "
                  ~ "returned only " ~ found.length.to!string ~ " file(s). The "
                  ~ "path is wrong or the tree moved — the rows above and below "
                  ~ "are then measuring nothing";
    foreach (f; found) {
        bool known = false;
        foreach (x; kG4Files) if (x == f) { known = true; break; }
        if (!known)
            foreach (nm; kEditDirNonMembers) if (nm.file == f) { known = true; break; }
        if (!known)
            problems ~= "    · new in `source/tools/edit/`, in neither roster: " ~ f;
    }
    foreach (x; kG4Files) {
        bool present = false;
        foreach (f; found) if (f == x) { present = true; break; }
        if (!present)
            problems ~= "    · rostered G4 member is gone from the directory: " ~ x;
    }
    foreach (nm; kEditDirNonMembers) {
        bool present = false;
        foreach (f; found) if (f == nm.file) { present = true; break; }
        if (!present)
            problems ~= "    · rostered NON-member is gone: " ~ nm.file
                      ~ "  (was: " ~ nm.why ~ ")";
    }

    assert(problems.length == 0,
        "G4 census: the edit directory's file set moved.\n" ~ joinLines(problems)
      ~ "  Every tool here that records a gesture is a G4 member and must go "
      ~ "through `Tool.recordGestureEdit` with a fixture cell of its own. Add "
      ~ "it to `kG4Files`, or — if it records nothing, or belongs to another "
      ~ "group — to `kEditDirNonMembers` WITH THE REASON. Do not delete the "
      ~ "row that reddened.");
}

// The four surviving calls all live on stable Tool members. Tool files are
// intentionally absent: their required value is the exact zero implied by
// scanning the full population and reconciling every discovered hit.
private enum LedgerRow[] kSurfaceRoster = [
    LedgerRow("Tool.recordGestureEdit|record", 1, "plain recorder dispatch"),
    LedgerRow("Tool.recordGestureEdit|recordInSession", 1, "session recorder dispatch"),
    LedgerRow("Tool.recordGestureEdit|replaceInSessionTailWith", 1, "tail recorder dispatch"),
    LedgerRow("Tool.refuseGestureRecord|consolidate", 1, "refusal belt"),
];

unittest {
    LedgerHit[] ledgerHits;
    size_t totalHits;
    foreach (rel; populationPaths()) {
        const src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        const found = historySurface(src);
        totalHits += found.length;
        foreach (h; found)
            ledgerHits ~= LedgerHit(h.symbol ~ "|" ~ h.name, rel, h.line,
                                    "history." ~ h.name);
    }
    const problems = reconcile(kSurfaceRoster, ledgerHits);
    assert(problems.length == 0,
        "G4 census: the family's history call surface changed.\n" ~ problems);
    assert(totalHits == 4,
        "G4 census: history-surface population changed");
}

// ---------------------------------------------------------------------------
// 3. THE SEAM'S CALL SITES, per file and PER MODE.
//
//    G4 is a one-mode family: eleven `Plain` sites and nothing else. That is
//    not a coincidence to be tolerated, it is a fact worth pinning, because it
//    is what makes the plan's discriminating mutation M2 (suppress only the
//    `ReplaceRunTail` dispatch and expect exactly one fixture cell to redden,
//    in group G1) INAPPLICABLE here: this family has no site on that branch, so
//    M2 over G4 predicts eleven greens. The moment `ReplaceRunTail` or
//    `InSession` appears below, that reasoning stops holding and this member
//    says so first.
// ---------------------------------------------------------------------------
private enum LedgerRow[] kCallRoster = [
    LedgerRow("Tool|call", 1, "seam declaration"),
    LedgerRow("Tool.recordGestureEdit|plain", 1, "plain dispatch"),
    LedgerRow("Tool.recordGestureEdit|inSession", 1, "session dispatch"),
    LedgerRow("Tool.recordGestureEdit|replaceTail", 1, "tail dispatch"),
    LedgerRow("Tool.refuseGestureRecord|replaceTail", 1, "tail refusal belt"),
    LedgerRow("BridgeTool.commitBridgeEdit|call", 1, "tool commit"),
    LedgerRow("BridgeTool.commitBridgeEdit|plain", 1, "plain mode"),
    LedgerRow("DragWeldTool.onMouseButtonUp|call", 1, "tool commit"),
    LedgerRow("DragWeldTool.onMouseButtonUp|plain", 1, "plain mode"),
    LedgerRow("EdgeBevelTool.commitEdit|call", 1, "tool commit"),
    LedgerRow("EdgeBevelTool.commitEdit|plain", 1, "plain mode"),
    LedgerRow("PolyBevelTool.commitEdit|call", 1, "tool commit"),
    LedgerRow("PolyBevelTool.commitEdit|plain", 1, "plain mode"),
    LedgerRow("PolyExtrudeTool.commitEdit|call", 1, "tool commit"),
    LedgerRow("PolyExtrudeTool.commitEdit|plain", 1, "plain mode"),
    LedgerRow("PolyInsetTool.commitEdit|call", 1, "tool commit"),
    LedgerRow("PolyInsetTool.commitEdit|plain", 1, "plain mode"),
    LedgerRow("ReductionTool.commitEdit|call", 1, "tool commit"),
    LedgerRow("ReductionTool.commitEdit|plain", 1, "plain mode"),
    LedgerRow("TackTool.commitTackEdit|call", 1, "tool commit"),
    LedgerRow("TackTool.commitTackEdit|plain", 1, "plain mode"),
    LedgerRow("VertexMergeTool.commitEdit|call", 1, "tool commit"),
    LedgerRow("VertexMergeTool.commitEdit|plain", 1, "plain mode"),
    LedgerRow("VertexBevelTool.commitEdit|call", 1, "tool commit"),
    LedgerRow("VertexBevelTool.commitEdit|plain", 1, "plain mode"),
    LedgerRow("VertexExtrudeTool.commitEdit|call", 1, "tool commit"),
    LedgerRow("VertexExtrudeTool.commitEdit|plain", 1, "plain mode"),
];

unittest {
    LedgerHit[] hits;
    size_t totalCalls;
    foreach (rel; populationPaths()) {
        const src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        const calls = symbolTokenHits(src, rel, "recordGestureEdit(", "call");
        totalCalls += calls.length;
        hits ~= calls;
        hits ~= symbolTokenHits(src, rel, "GestureRecordMode.Plain", "plain");
        hits ~= symbolTokenHits(src, rel, "GestureRecordMode.InSession", "inSession");
        hits ~= symbolTokenHits(src, rel, "GestureRecordMode.ReplaceRunTail", "replaceTail");
    }
    const problems = reconcile(kCallRoster, hits);
    assert(problems.length == 0,
        "G4 census: the seam's call sites changed.\n" ~ problems);
    assert(totalCalls == 12,
        "G4 census: recordGestureEdit population changed");
}

// ---------------------------------------------------------------------------
// 4. THE FAMILY BINDS THROUGH THE BASE, and declares no binder of its own.
//
//    Eleven `void setUndoBindings(CommandHistory, <alias>)` declarations were
//    deleted by this phase, one per tool, along with the eleven
//    `alias …EditFactory = MeshSessionEdit delegate();` they were typed on.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;
    size_t seamDecls = 0;

    foreach (rel; populationPaths()) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t oldDecls = countOccurrences(src, "void setUndoBindings");
        immutable size_t newDecls = countOccurrences(src, "void setGestureBindings");
        seamDecls += newDecls;
        if (oldDecls != 0)
            problems ~= "    · " ~ rel ~ " still declares setUndoBindings x "
                      ~ oldDecls.to!string ~ " — the family binds through "
                      ~ "`Tool.setGestureBindings` now, and a second binder is "
                      ~ "a second place to forget";
        if (rel != "source/tool.d" && newDecls != 0)
            problems ~= "    · " ~ rel ~ " declares its own setGestureBindings; "
                      ~ "the base's is `final` and there is nothing to add";
    }

    if (seamDecls != 1)
        problems ~= "    · `void setGestureBindings` is declared "
                  ~ seamDecls.to!string ~ " time(s) in the population; exactly "
                  ~ "one, on `Tool`, is the point of it — and a zero here means "
                  ~ "the scan read nothing, so the per-file rows above are "
                  ~ "vacuous too";
    assert(problems.length == 0,
        "G4 census: binding declarations moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 5. EVERY G4 REGISTRATION CALLS THE BASE BINDER.
//
//    Scoped to the eleven wire ids this group owns, deliberately: a count of
//    `setGestureBindings` over the whole of `registration.d` would be a number
//    every later family has to bump, i.e. a lane serialiser. Per-id it is exact
//    AND it does not move when G2, G3 or G5 lands — which matters here, because
//    the four phase-C lanes edit sites nine to nineteen lines apart in ONE
//    function and meet each other at the rebase.
// ---------------------------------------------------------------------------
private enum string[] kG4WireIds = [
    "mesh.tack", "mesh.bridgeTool", "mesh.dragWeld", "poly.extrude",
    "poly.bevel", "mesh.polyInsetTool", "edge.bevel", "mesh.vertexBevel",
    "mesh.vertexExtrude", "vert.merge", "mesh.reduceTool",
];

unittest {
    // RAW source here, not the stripped copy, and that is the one place in this
    // file where it has to be: the stripper blanks string literals, and the wire
    // id IS a string literal. The needle keeps `] = ` on the end so it matches
    // the DEFINITION and not the second mention of the same key inside the
    // neighbouring `commandFactories` entry; the uniqueness check below is what
    // makes that claim rather than assumes it.
    immutable src = readText(buildPath(repoRoot, "source", "registration.d"));
    string[] problems;
    size_t checked = 0;

    auto ids = kG4WireIds.dup;
    ids.sort();
    if (ids.uniq.array.length != kG4WireIds.length)
        problems ~= "    · the wire-id roster names only "
                  ~ ids.uniq.array.length.to!string ~ " DISTINCT id(s) across "
                  ~ kG4WireIds.length.to!string ~ " rows — a duplicate leaves "
                  ~ "one registration unchecked";

    foreach (id; kG4WireIds) {
        immutable needle = "reg.toolFactories[\"" ~ id ~ "\"] = ";
        if (countOccurrences(src, needle) != 1) {
            problems ~= "    · wire id `" ~ id ~ "`: found "
                      ~ countOccurrences(src, needle).to!string
                      ~ " registration definitions, expected exactly 1";
            continue;
        }
        auto at = src.indexOf(needle);
        auto rest = src[cast(size_t) at .. $];
        auto end  = rest.indexOf("});");
        immutable block = (end < 0) ? rest : rest[0 .. cast(size_t) end];
        ++checked;
        if (countOccurrences(block, "setGestureBindings(") != 1)
            problems ~= "    · `" ~ id ~ "` does not bind through "
                      ~ "setGestureBindings exactly once. An unbound tool is "
                      ~ "SILENT: `recordGestureEdit` sees a null history and "
                      ~ "returns false, the mesh stays edited, and no undo "
                      ~ "entry is written";
        if (countOccurrences(block, "setUndoBindings(") != 0)
            problems ~= "    · `" ~ id ~ "` still calls setUndoBindings — a G4 "
                      ~ "tool has no such method any more, so this would not "
                      ~ "even compile; if you are reading this, the id resolved "
                      ~ "to the wrong block";
    }

    if (checked != kG4WireIds.length)
        problems ~= "    · NON-VACUITY: located only " ~ checked.to!string
                  ~ " of " ~ kG4WireIds.length.to!string ~ " registration "
                  ~ "blocks. The scan is reading the wrong file — every per-id "
                  ~ "row above then passes by never running";
    assert(problems.length == 0,
        "G4 census: a registration left the base binder.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 6. NO G4 TOOL DECLARES ITS OWN HISTORY FIELD.
//
//    D silently SHADOWS a base field with a same-named derived one, so a tool
//    that declares `CommandHistory history;` keeps compiling, reads its own
//    never-bound copy, and records into null — an edit with no undo entry and
//    nothing red anywhere. Phase B measured that a re-declaration COMPILES;
//    this is the family-scoped guard against it coming back here.
//
//    The TREE-WIDE zero is `tool_commit_seam_census_g1_test.d`'s member 6, and
//    it is deliberately not duplicated: a second tree-wide walk in each of four
//    family files is four numbers to keep in step for one fact. This member is
//    narrow on purpose — it names the ELEVEN, so its message points at a G4
//    file and its line, which the tree-wide one does not.
// ---------------------------------------------------------------------------
unittest {
    string[] offenders;
    size_t mentions = 0;

    foreach (f; kG4Files) {
        auto src = stripCommentsAndStrings(
            readText(buildPath(repoRoot, "source", "tools", "edit", f)));
        mentions += countOccurrences(src, "CommandHistory");
        // A FIELD declaration, not a parameter: `CommandHistory <ident> ;`.
        size_t i = 0;
        while (true) {
            auto rel = src[i .. $].indexOf("CommandHistory");
            if (rel < 0) break;
            size_t p = i + cast(size_t) rel;
            i = p + 14;
            if (p > 0 && isIdentChar(src[p - 1])) continue;
            size_t q = p + 14;
            while (q < src.length && (src[q] == ' ' || src[q] == '\t')) ++q;
            size_t nameStart = q;
            while (q < src.length && isIdentChar(src[q])) ++q;
            if (q == nameStart) continue;
            immutable string fieldName = src[nameStart .. q];
            while (q < src.length && (src[q] == ' ' || src[q] == '\t')) ++q;
            if (q < src.length && src[q] == ';')
                offenders ~= "    · " ~ f ~ ":" ~ lineOf(src, p).to!string
                           ~ "  `CommandHistory " ~ fieldName ~ ";`";
        }
    }

    // NON-VACUITY, and NOT a loop-invariant: counting the files this loop
    // visited would be a tautology over the roster it iterates. What proves the
    // scanner read real text is that the TOKEN is there to be found — each of
    // the eleven still carries `import command_history : CommandHistory;` (a
    // line the field predicate correctly does NOT match, because the `;`
    // follows the type with no field name between). A stripper that lost its
    // place, or a `repoRoot` pointing nowhere, drives this to zero.
    if (mentions < kG4Files.length)
        offenders ~= "    · NON-VACUITY: the token `CommandHistory` appears "
                   ~ mentions.to!string ~ " time(s) across the "
                   ~ kG4Files.length.to!string ~ " rostered file(s); at least "
                   ~ "one per file is expected. The scan read nothing, so a "
                   ~ "zero above is not evidence of anything";
    assert(offenders.length == 0,
        "G4 census: a G4 tool declares its own CommandHistory field again.\n"
      ~ joinLines(offenders) ~ "\n"
      ~ "  `Tool.history` is `protected` and bound by `setGestureBindings`. A "
      ~ "same-named field in a subclass SHADOWS it silently in D: the tool "
      ~ "compiles, reads its own never-bound copy, and records into null. "
      ~ "Phase B deleted thirty-two of these in ONE commit precisely so that no "
      ~ "half-migrated state could exist; this number does not go up.");
}

private string joinLines(const(string)[] xs) {
    string r;
    foreach (x; xs) r ~= x ~ "\n";
    return r;
}
