// tool_commit_seam_census_g1_test — the text half of the gesture-recording
// seam, for group G1 (task 1905, phase B).
//
// ONE FILE PER FAMILY, and that is not filing tidiness. A single tree-wide
// census would serialise the four phase-C lanes behind each other, and the
// failure it invites is the silent one: two lanes each append a roster line to
// the same file, the merge keeps one, and the lost line's family is then
// unwatched with nothing red to say so. Per-family files make that collision a
// textual conflict instead of a disappearance.
//
// THE KEY MEMBER KEYS ON THE WHOLE CALL SURFACE, NOT ON A REGEX OF ONE NAME.
// Revision 2 of the plan measured this family with `history_?\.record`, and
// that predicate MISSED two recorders — `box.d`'s `replaceInSessionTailWith`
// and `xfrm_transform.d`'s `replaceInSessionTail` — and all four of the slice
// family's legitimate `invalidateRedo` calls. The lesson is not "the regex was
// one name short"; a widened regex is another list the next person forgets to
// widen. So the census collects EVERY `history.<NAME>(` in the family and
// compares the multiset against a roster that carries a reason per name. A
// sixth history primitive called from a tool tomorrow reddens this for free,
// with the name and the address, and no predicate edit.
//
// WHAT IT CANNOT SEE, said here so nobody trusts it for that: a seam that
// recorded the RIGHT carrier with the WRONG payload. That is the frozen plane
// fixture's job (`tests/fixtures/tool_gesture/g1.json`, read by
// `tests/test_tool_gesture_g1.d`).
//
// THE POPULATION IS `source/tools/create/**` + THREE NAMED FILES + `source/tool.d`.
// The last one is not decoration. `class Tool` lives in `source/tool.d`, OUTSIDE
// `source/tools/**`, so a census keyed only on the tools directory reads "0
// recorders" after the migration and never looks at the one surviving recorder
// in the family — the seam itself. That is a check that cannot come out
// differently, and round 4 of the plan caught it as its first blocking fix.
//
// MUTATIONS, one per member, each reddening only its own:
//   1. add a file under `source/tools/create/` -> member 1, by name.
//   2. write `history.consolidate(...)` into any G1 tool -> member 2, as
//      "unknown name on the history surface".
//   3. drop `nextRun: 1` from box's roster row -> member 2, with the number.
//   4. turn one `recordGestureEdit` back into `history.record(cmd)` -> member 2
//      (an unrostered `record` in a tool) AND member 3 (the call count).
//   5. flip one registration back to `setUndoBindings` -> member 5, by wire id.
//   6. re-declare `CommandHistory history;` in any tool -> member 6, by file.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_commit_seam_census_g1_test;

import std.algorithm : sort;
import std.array     : appender;
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
// silent desync is not a promise — it is the non-vacuity floor at the bottom of
// this file: a scanner that lost its place eats the rest of the file, and the
// `recordGestureEdit(` total collapses and reddens with a message that says so.
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
// THE FAMILY. `source/tools/create/**` is WALKED (member 1); the other four
// paths are named, because G1's membership is not a directory — it is the set
// of tools that between them exercise all three record primitives and all four
// payload forms, and three of them live in other families' directories
// (`magnet` in deform/, the two twins in edit/). Keying the lane on the
// directory instead is exactly what round 3 rejected: it would have left the
// two `setDelta` carriers, on which this phase's whole delta/snapshot fork
// rests, outside the group that freezes the interface.
// ---------------------------------------------------------------------------
private enum string[] kCreateDirFiles = [
    "arc.d", "box.d", "capsule.d", "cone.d", "create_common.d", "cylinder.d",
    "pen.d", "primitive_create_tool.d", "sphere.d", "torus.d", "tube.d",
    "vertex_place.d",
];

private enum string[] kNamedMembers = [
    "source/tools/deform/magnet.d",
    "source/tools/edit/edge_extend.d",
    "source/tools/edit/edge_extrude.d",
    "source/tool.d",
];

private string[] familyPaths() {
    string[] r;
    foreach (f; kCreateDirFiles) r ~= buildPath("source", "tools", "create", f);
    foreach (f; kNamedMembers)   r ~= f;
    return r;
}

// ---------------------------------------------------------------------------
// 1. THE FILE SET IS WALKED, NOT TRUSTED.
//
//    A new tool dropped into `source/tools/create/` is a new member of this
//    family whether or not anyone updates a table, and it must not join the
//    tree unnoticed by the census that owns its family.
// ---------------------------------------------------------------------------
unittest {
    string[] found;
    foreach (e; dirEntries(buildPath(repoRoot, "source", "tools", "create"),
                           "*.d", SpanMode.breadth))
        found ~= baseName(e.name);
    found.sort();
    auto expect = kCreateDirFiles.dup;
    expect.sort();

    assert(found.length >= 10,
        "G1 census: the walk of `source/tools/create/` returned only "
      ~ found.length.to!string ~ " file(s). The path is wrong or the tree "
      ~ "moved — every member below is then measuring nothing");

    string bad;
    foreach (f; found) {
        bool known = false;
        foreach (x; expect) if (x == f) { known = true; break; }
        if (!known) bad ~= (bad.length ? ", " : "") ~ f;
    }
    string gone;
    foreach (f; expect) {
        bool present = false;
        foreach (x; found) if (x == f) { present = true; break; }
        if (!present) gone ~= (gone.length ? ", " : "") ~ f;
    }
    assert(bad.length == 0 && gone.length == 0,
        "G1 census: the create family's file set moved.\n"
      ~ "    new, not in the roster: " ~ (bad.length ? bad : "(none)") ~ "\n"
      ~ "    rostered, now missing:  " ~ (gone.length ? gone : "(none)") ~ "\n"
      ~ "  A new tool here inherits `PrimitiveCreateTool.commitEdit` — the one "
      ~ "record body nine tools already share — so it joins this seam whether "
      ~ "or not it says so. Add it to `kCreateDirFiles` and give it a fixture "
      ~ "cell, or explain at its declaration why it has no gesture to record.");
}

// ---------------------------------------------------------------------------
// 2. THE HISTORY CALL SURFACE OF THE FAMILY, name by name, file by file.
//
//    After phase B every recorder in this family lives in ONE place — the seam
//    on `Tool` — and what remains inside the tools is two legitimate
//    non-recorders, both in `box.d`, both named here so that "1" cannot drift
//    into "2" unnoticed.
// ---------------------------------------------------------------------------
private enum LedgerRow[] kSurfaceRoster = [
    // The seam itself. THREE primitives, one per `GestureRecordMode` member,
    // plus the belt's run-close. This is the whole reason `source/tool.d` is in
    // the population: it is the family's only surviving recorder.
    LedgerRow("Tool.recordGestureEdit|record", 1,
        "GestureRecordMode.Plain -> CommandHistory.record"),
    LedgerRow("Tool.recordGestureEdit|recordInSession", 1,
        "GestureRecordMode.InSession -> CommandHistory.recordInSession"),
    LedgerRow("Tool.recordGestureEdit|replaceInSessionTailWith", 1,
        "GestureRecordMode.ReplaceRunTail -> CommandHistory.replaceInSessionTailWith"),
    LedgerRow("Tool.refuseGestureRecord|consolidate", 1,
        "the refusal belt closing the run the skipped splice would have closed"),
    // The two legitimate non-recorders left inside a G1 tool.
    LedgerRow("BoxTool.ensureLiveRun|nextRun", 1,
        "ensureLiveRun() opens the live-edit run id; a read/allocate, not a record"),
    LedgerRow("BoxTool.cancelUncommittedEdit|undo", 1,
        "the interactive undo LADDER inside cancelUncommittedEdit (task 0414); "
      ~ "it pops a live step and is not a record"),
];

unittest {
    LedgerHit[] ledgerHits;
    size_t   totalHits = 0;

    foreach (rel; familyPaths()) {
        immutable full = buildPath(repoRoot, rel);
        assert(exists(full), "G1 census: population member is missing: " ~ rel);
        auto src  = stripCommentsAndStrings(readText(full));
        auto hits = historySurface(src);
        totalHits += hits.length;

        foreach (h; hits) {
            ledgerHits ~= LedgerHit(h.symbol ~ "|" ~ h.name, rel, h.line,
                                    "history." ~ h.name);
        }
    }

    // NON-VACUITY. A stripper that lost its place, or a repoRoot that points
    // nowhere, produces an EMPTY surface and satisfies every "unrostered == 0"
    // above for free.
    // A FLOOR, not an equality: an EXTRA call is caught below with its name and
    // its address, which is the message worth reading. This one only refuses a
    // scanner that read nothing at all.
    assert(totalHits >= 4,
        "G1 census: the scan found " ~ totalHits.to!string ~ " call(s) on the "
      ~ "history surface across the whole family, and the seam alone makes "
      ~ "four. The scanner read nothing — check `repoRoot` and the stripper "
      ~ "before believing any green above it.");

    const problems = reconcile(kSurfaceRoster, ledgerHits);
    assert(problems.length == 0,
        "G1 census: the family's history call surface is not what the seam "
      ~ "leaves behind.\n" ~ problems);
    assert(ledgerHits.length == 6,
        "G1 census: expected exactly six history-surface sites");
}

// ---------------------------------------------------------------------------
// 3. THE SEAM'S CALL SITES, per file and PER MODE.
//
//    The per-mode counts are what makes the plan's discriminating mutation
//    (M2 — suppress only the `ReplaceRunTail` dispatch, expect exactly one
//    fixture cell to redden) a checkable claim rather than a hope: there is
//    exactly ONE `ReplaceRunTail` site in the family, and it is box's.
// ---------------------------------------------------------------------------
private enum LedgerRow[] kCallRoster = [
    // The seam: one declaration, one dispatch arm per mode — plus a SECOND
    // mention of `ReplaceRunTail`, the belt's `mode ==` test in
    // `refuseGestureRecord`. That second one is the whole of round 4's fix 3
    // and it is counted, not tolerated: if it disappears the belt has stopped
    // closing the run it skipped.
    LedgerRow("Tool|call", 1, "seam declaration"),
    LedgerRow("Tool.recordGestureEdit|plain", 1, "plain dispatch arm"),
    LedgerRow("Tool.recordGestureEdit|inSession", 1, "in-session dispatch arm"),
    LedgerRow("Tool.recordGestureEdit|replaceTail", 1, "tail dispatch arm"),
    LedgerRow("Tool.refuseGestureRecord|replaceTail", 1, "refusal belt"),
    LedgerRow("ArcTool.commitArcEdit|call", 1, "arc commit"),
    LedgerRow("ArcTool.commitArcEdit|plain", 1, "arc mode"),
    LedgerRow("BoxTool.commitBoxEdit|call", 2, "box commit paths"),
    LedgerRow("BoxTool.commitBoxEdit|plain", 1, "box plain path"),
    LedgerRow("BoxTool.commitBoxEdit|replaceTail", 1, "box tail path"),
    LedgerRow("BoxTool.recordLiveEdit|call", 1, "box live record"),
    LedgerRow("BoxTool.recordLiveEdit|inSession", 1, "box live mode"),
    LedgerRow("PenTool.commitPolygonWithUndo|call", 1, "pen commit"),
    LedgerRow("PenTool.commitPolygonWithUndo|plain", 1, "pen mode"),
    LedgerRow("PrimitiveCreateTool.commitEdit|call", 1, "primitive commit"),
    LedgerRow("PrimitiveCreateTool.commitEdit|plain", 1, "primitive mode"),
    LedgerRow("VertexTool.onMouseButtonDown|call", 1, "vertex commit"),
    LedgerRow("VertexTool.onMouseButtonDown|plain", 1, "vertex mode"),
    LedgerRow("MagnetTool.commitEdit|call", 1, "magnet commit"),
    LedgerRow("MagnetTool.commitEdit|plain", 1, "magnet mode"),
    LedgerRow("EdgeExtendTool.commitEdit|call", 2, "edge-extend commit paths"),
    LedgerRow("EdgeExtendTool.commitEdit|plain", 2, "edge-extend modes"),
    LedgerRow("EdgeExtrudeTool.commitEdit|call", 2, "edge-extrude commit paths"),
    LedgerRow("EdgeExtrudeTool.commitEdit|plain", 2, "edge-extrude modes"),
];

unittest {
    LedgerHit[] hits;
    size_t   totalCalls = 0;

    foreach (rel; familyPaths()) {
        immutable full = buildPath(repoRoot, rel);
        auto src = stripCommentsAndStrings(readText(full));
        auto calls = symbolTokenHits(src, rel, "recordGestureEdit(", "call");
        totalCalls += calls.length;
        hits ~= calls;
        hits ~= symbolTokenHits(src, rel, "GestureRecordMode.Plain", "plain");
        hits ~= symbolTokenHits(src, rel, "GestureRecordMode.InSession", "inSession");
        hits ~= symbolTokenHits(src, rel, "GestureRecordMode.ReplaceRunTail", "replaceTail");
    }

    assert(totalCalls >= 13,
        "G1 census: only " ~ totalCalls.to!string ~ " `recordGestureEdit(` in the "
      ~ "whole family. Twelve tool sites plus the seam's own declaration are "
      ~ "expected; a number near zero means the scanner read nothing, not that "
      ~ "the family stopped recording.");

    const problems = reconcile(kCallRoster, hits);
    assert(problems.length == 0,
        "G1 census: the seam's call sites changed.\n" ~ problems
      ~ "\n  Exactly ONE `ReplaceRunTail` dispatch exists in this family "
      ~ "(box's commit while a live run is open). That is what licenses the "
      ~ "plan's M2 mutation to predict a single reddened fixture cell — if the "
      ~ "count above is not 1, that prediction no longer holds.");
}

// ---------------------------------------------------------------------------
// 4. THE FAMILY BINDS THROUGH THE BASE, and declares no binder of its own.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;
    size_t seamDecls = 0;

    foreach (rel; familyPaths()) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t oldDecls = countOccurrences(src, "void setUndoBindings");
        immutable size_t newDecls = countOccurrences(src, "void setGestureBindings");
        seamDecls += newDecls;
        if (oldDecls != 0)
            problems ~= "    · " ~ rel ~ " still declares setUndoBindings x "
                      ~ oldDecls.to!string ~ " — the family binds through "
                      ~ "`Tool.setGestureBindings` now";
        if (rel != "source/tool.d" && newDecls != 0)
            problems ~= "    · " ~ rel ~ " declares its own setGestureBindings; "
                      ~ "the base's is `final` and there is nothing to add";
    }

    assert(seamDecls == 1,
        "G1 census: `void setGestureBindings` is declared " ~ seamDecls.to!string
      ~ " time(s) in the family; exactly one, on `Tool`, is the point of it");
    assert(problems.length == 0,
        "G1 census: binding declarations moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 5. EVERY G1 REGISTRATION CALLS THE BASE BINDER.
//
//    Scoped to the fourteen wire ids this group owns, deliberately: a count of
//    `setGestureBindings` over the whole of `registration.d` would be a number
//    that every later family has to bump, i.e. a lane serialiser. Per-id it is
//    exact AND it does not move when G2 lands.
// ---------------------------------------------------------------------------
private enum string[] kG1WireIds = [
    "prim.cube", "prim.sphere", "prim.ellipsoid", "prim.cylinder", "prim.tube",
    "prim.cone", "prim.capsule", "prim.torus", "prim.arc", "pen", "prim.vertex",
    "edge.extrude", "edge.extend", "xfrm.magnet",
];

unittest {
    // RAW source here, not the stripped copy, and that is the one place in this
    // file where it has to be: the stripper blanks string literals, and the wire
    // id IS a string literal. The needle keeps `] = ` on the end so it matches
    // the DEFINITION and not the second mention of the same key inside the
    // neighbouring `commandFactories` entry; the uniqueness assert below is what
    // makes that claim rather than assumes it.
    immutable src = readText(buildPath(repoRoot, "source", "registration.d"));
    string[] problems;
    size_t checked = 0;

    foreach (id; kG1WireIds) {
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
                      ~ "setGestureBindings exactly once";
        if (countOccurrences(block, "setUndoBindings(") != 0)
            problems ~= "    · `" ~ id ~ "` still calls setUndoBindings — a G1 "
                      ~ "tool has no such method any more, so this would not "
                      ~ "even compile; if you are reading this, the id resolved "
                      ~ "to the wrong block";
    }

    assert(checked == kG1WireIds.length,
        "G1 census: located only " ~ checked.to!string ~ " of "
      ~ kG1WireIds.length.to!string ~ " registration blocks. The scan is "
      ~ "reading the wrong file or the stripper ate it — every per-id check "
      ~ "above then passes vacuously.");
    assert(problems.length == 0,
        "G1 census: a registration left the base binder.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 6. NO TOOL DECLARES ITS OWN HISTORY FIELD — tree-wide, and permanently zero.
//
//    This is the one member that is deliberately NOT family-scoped, because its
//    correct value can never rise: D silently SHADOWS a base field with a
//    same-named derived one, so a tool that declares `CommandHistory history;`
//    keeps compiling, reads its own never-bound copy, and records into null.
//    That is the exact failure the one-commit rule of phase B exists to make
//    impossible, and a later family cannot need to raise this number.
// ---------------------------------------------------------------------------
unittest {
    string[] offenders;
    size_t scanned = 0;

    foreach (e; dirEntries(buildPath(repoRoot, "source", "tools"), "*.d", SpanMode.depth)) {
        ++scanned;
        auto src = stripCommentsAndStrings(readText(e.name));
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
                offenders ~= "    · " ~ baseName(e.name) ~ ":"
                           ~ lineOf(src, p).to!string ~ "  `CommandHistory "
                           ~ fieldName ~ ";`";
        }
    }

    assert(scanned >= 30,
        "G1 census: the walk of `source/tools/` visited only " ~ scanned.to!string
      ~ " file(s); the shadowing guard below is vacuous over an empty walk");
    assert(offenders.length == 0,
        "G1 census: a tool declares its own CommandHistory field again.\n"
      ~ joinLines(offenders) ~ "\n"
      ~ "  `Tool.history` is `protected` and bound by `setGestureBindings`. A "
      ~ "same-named field in a subclass SHADOWS it silently in D: the tool "
      ~ "compiles, reads its own never-bound copy, and records into null. "
      ~ "Thirty-two of these were deleted in one commit precisely so that no "
      ~ "half-migrated state could exist; this number does not go up.");
}

private string joinLines(const(string)[] xs) {
    string r;
    foreach (x; xs) r ~= x ~ "\n";
    return r;
}
