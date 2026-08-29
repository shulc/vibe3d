// tool_gesture_record_residue_test — success criterion 1 of task 1905, in the
// only form in which it can be true.
//
// THE CRITERION AS WRITTEN IS UNREACHABLE INSIDE ITS OWN SCOPE, and that is a
// defect in how "done" was written, not in the work. The card says
// `history.record*` under `source/tools/**` -> 0. Decision D1 of the same plan
// puts the TRANSFORM ZONE out of scope, and after group G6 landed on
// 2026-08-29 that zone holds EVERY remaining writing primitive there is. So the
// criterion asks the work to delete calls the same document forbids it to
// touch. Rounding that to "essentially zero" is what leaves a track nobody can
// ever close; the honest move is to state the reachable form and MEASURE it,
// which is this file.
//
// THE REACHABLE FORM: writing primitives of `CommandHistory` reached from
// `source/tools/**` ∪ `source/tool.d` are
//
//     ONE SITE  — `Tool.recordGestureEdit` in `source/tool.d`, which dispatches
//                 to three primitives, one per `GestureRecordMode` member;
//   + THREE     — the transform zone's, each REJECTED WITH A REASON (D1) and
//                 named below with its file, so a FOURTH cannot be born green;
//   + ZERO      — everywhere else under `source/tools/**`.
//
// WHY A NEW FILE AND NOT A MEMBER OF A FAMILY CENSUS. The seven
// `tool_commit_seam_census_g*_test.d` files are each scoped to their family's
// population, deliberately (one file per family, so parallel lanes collide
// textually instead of silently losing a roster line). The transform zone is in
// NO family, which is exactly how it came to be unguarded: measured 2026-08-29,
// no census names `source/tools/transform/**` on the history CALL SURFACE at
// all — `tool_commit_seam_census_g8_test.d` rosters its two surviving BINDER
// declarations and nothing else, so a fourth `record` added to `transform.d`
// reddens nothing anywhere. A criterion re-scoped to "zero OUTSIDE the
// transform zone" is only honest if the inside is enumerated too, and this file
// is that enumeration.
//
// WHAT COUNTS AS "WRITING", because the arithmetic depends on it. The set is
// the primitives that APPEND to or REWRITE the undo stack. `undo`, `redo`,
// `nextRun`, `runOpen`, `undoEpoch`, `bumpTweakGeneration`, `consolidate` and
// `invalidateRedo` are excluded: the first six do not touch the stack's
// contents, and the last two mutate what is already on it without adding an
// entry (the slice family's four `invalidateRedo` and the seam belt's
// `consolidate` are rostered as legal non-recorders by their own family files).
// This is the same partition §8 of the plan does its counting under, and it is
// what makes "1 + 3" a number rather than a slogan.
//
// MUTATIONS, one per member:
//   1. add `history.record(cmd);` to any file under `source/tools/**` that is
//      not `transform.d` -> member 1, with file, line and primitive.
//   2. add a SECOND `history.record(` to `source/tools/transform/transform.d`
//      -> member 1, as a count mismatch against its roster row.
//   3. delete the `GestureRecordMode.InSession` arm from the seam -> member 1,
//      as `source/tool.d`'s `recordInSession` count going 1 -> 0.
//   4. point `repoRoot` at a directory that does not exist -> member 2, the
//      non-vacuity floor, before any of the above can pass for free.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_record_residue_test;

import std.algorithm : sort;
import std.array     : appender;
import std.conv      : to;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.path      : baseName, buildPath, dirName, relativePath;
import std.string    : indexOf;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string stripCommentsAndStrings(string src) {
    auto sink = appender!string;
    size_t i = 0;
    while (i < src.length) {
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
            while (i < src.length && src[i] != '\n') { sink.put(' '); ++i; }
            continue;
        }
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '*') {
            i += 2; sink.put("  ");
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
                sink.put(src[i] == '\n' ? '\n' : ' '); ++i;
            }
            i = (i + 2 <= src.length) ? i + 2 : src.length;
            sink.put("  ");
            continue;
        }
        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') {
            int depth = 0;
            while (i < src.length) {
                if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '+') { ++depth; i += 2; sink.put("  "); continue; }
                if (i + 1 < src.length && src[i] == '+' && src[i + 1] == '/') { --depth; i += 2; sink.put("  "); if (depth == 0) break; continue; }
                sink.put(src[i] == '\n' ? '\n' : ' '); ++i;
            }
            continue;
        }
        if (src[i] == '"') {
            ++i; sink.put(' ');
            while (i < src.length && src[i] != '"') {
                if (src[i] == '\\' && i + 1 < src.length) { sink.put(' '); ++i; }
                sink.put(src[i] == '\n' ? '\n' : ' '); ++i;
            }
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            sink.put(' ');
            continue;
        }
        if (src[i] == '`') {
            ++i; sink.put(' ');
            while (i < src.length && src[i] != '`') { sink.put(src[i] == '\n' ? '\n' : ' '); ++i; }
            i = (i + 1 <= src.length) ? i + 1 : src.length;
            sink.put(' ');
            continue;
        }
        sink.put(src[i]);
        ++i;
    }
    return sink.data;
}

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

private struct SurfaceHit { string name; size_t line; }

private SurfaceHit[] historySurface(string src) {
    SurfaceHit[] hits;
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
        hits ~= SurfaceHit(nm, lineOf(src, p));
    }
    return hits;
}


// ---------------------------------------------------------------------------
// THE POPULATION: every `.d` under `source/tools/`, plus `source/tool.d`.
//
// `source/tool.d` is named because `class Tool` lives OUTSIDE the tools
// directory: a scan keyed only on `source/tools/**` reads "zero writers" after
// the migration and never looks at the one writer that survives on purpose.
// Round 4 of the plan caught that as its first blocking fix for the G1 census;
// the same trap applies here and the same repair is used.
// ---------------------------------------------------------------------------
private string[] population() {
    string[] r;
    immutable root = buildPath(repoRoot, "source", "tools");
    if (exists(root))
        foreach (e; dirEntries(root, "*.d", SpanMode.depth))
            r ~= relativePath(e.name, repoRoot);
    r ~= "source/tool.d";
    r.sort();
    return r;
}

/// The primitives that APPEND to or REWRITE the undo stack. See the header for
/// why `consolidate` / `invalidateRedo` / `nextRun` / `runOpen` / `undo` /
/// `redo` / `undoEpoch` / `bumpTweakGeneration` are not here.
private bool isWritingPrimitive(string name) {
    switch (name) {
        case "record":
        case "recordInSession":
        case "recordCoalescing":
        case "replaceInSessionTail":
        case "replaceInSessionTailWith":
            return true;
        default:
            return false;
    }
}

private struct ResidueRow { string path; string name; size_t count; string why; }

private enum ResidueRow[] kResidue = [
    // ---- THE ONE SITE ------------------------------------------------------
    // `Tool.recordGestureEdit`. One method, three primitives, one per
    // `GestureRecordMode` member — which is why the plan counts it as ONE SITE
    // and this roster as three rows. A mode losing its arm shows up here as a
    // count going 1 -> 0, which no runtime test can see: the two remaining
    // modes still record, so every undo depth in the suite is unchanged.
    ResidueRow("source/tool.d", "record", 1,
        "GestureRecordMode.Plain — the mode every family but box's live run uses"),
    ResidueRow("source/tool.d", "recordInSession", 1,
        "GestureRecordMode.InSession — a record that OPENS a run; it cannot be "
      ~ "derived from history state, which is why `mode` has no default"),
    ResidueRow("source/tool.d", "replaceInSessionTailWith", 1,
        "GestureRecordMode.ReplaceRunTail — one site in the whole tree "
      ~ "(box's commit while a live run is open), and the licence for the "
      ~ "plan's M2 mutation predicting exactly one reddened fixture cell"),

    // ---- THE THREE REJECTED, EACH WITH ITS REASON --------------------------
    // Decision D1: the transform zone is out of task 1905's scope. It is not
    // "not yet done" in the sense of an unfinished family — it is deferred to
    // the transform-state redesign (T2 of audit 0678), because two redesigns
    // over one place cost more than one. These rows are what stop that
    // deferral from becoming a hole: the zone may keep the three it has and
    // may not grow a fourth without saying so here.
    ResidueRow("source/tools/transform/transform.d", "recordInSession", 1,
        "TransformTool.commitEdit's in-session arm — REJECTED by D1, "
      ~ "transform zone, moves with T2"),
    ResidueRow("source/tools/transform/transform.d", "record", 1,
        "TransformTool.commitEdit's plain arm — REJECTED by D1, transform "
      ~ "zone, moves with T2"),
    ResidueRow("source/tools/transform/xfrm_transform.d", "replaceInSessionTail", 1,
        "the run-tail splice — REJECTED by D1. It is also the site the plan's "
      ~ "round-3 predicate `history_?\\.record` could not see at all, which is "
      ~ "why this file keys on the whole call surface and filters by name "
      ~ "afterwards rather than grepping for one spelling"),
];

// ---------------------------------------------------------------------------
// 1. THE RESIDUE IS ENUMERATED, NOT MERELY PERMITTED.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;
    size_t   totalWriting = 0, totalSurface = 0, filesRead = 0;

    foreach (rel; population()) {
        immutable full = buildPath(repoRoot, rel);
        if (!exists(full)) {
            problems ~= "    · population member vanished: " ~ rel;
            continue;
        }
        ++filesRead;
        auto src  = stripCommentsAndStrings(readText(full));
        auto hits = historySurface(src);
        totalSurface += hits.length;

        foreach (h; hits) {
            if (!isWritingPrimitive(h.name)) continue;
            ++totalWriting;
            bool rostered = false;
            foreach (row; kResidue)
                if (row.path == rel && row.name == h.name) { rostered = true; break; }
            if (!rostered)
                problems ~= "    · UNROSTERED WRITING PRIMITIVE: `history."
                          ~ h.name ~ "(` at " ~ rel ~ ":" ~ h.line.to!string
                          ~ "\n        Criterion 1 of task 1905 is: ONE site "
                          ~ "(`Tool.recordGestureEdit`) plus the THREE the "
                          ~ "transform zone keeps by decision D1. A tool that "
                          ~ "writes to the undo stack itself is back to the "
                          ~ "shape the whole task removed — the mesh is already "
                          ~ "mutated when the call is reached, so a tool that "
                          ~ "gets this wrong loses the entry SILENTLY. Route it "
                          ~ "through `recordGestureEdit(cmd, mode)`, or add a "
                          ~ "row here with the reason it cannot be.";
        }

        foreach (row; kResidue) {
            if (row.path != rel) continue;
            size_t n = 0;
            foreach (h; hits) if (h.name == row.name) ++n;
            if (n != row.count)
                problems ~= "    · " ~ rel ~ ": `history." ~ row.name ~ "(` x "
                          ~ n.to!string ~ ", roster says " ~ row.count.to!string
                          ~ "\n        (" ~ row.why ~ ")";
        }
    }

    foreach (row; kResidue)
        if (!exists(buildPath(repoRoot, row.path)))
            problems ~= "    · rostered file is gone from the tree: " ~ row.path
                      ~ "  (was: " ~ row.why ~ ")";

    assert(problems.length == 0,
        "task 1905 criterion 1: the writing-primitive residue moved.\n"
      ~ joinLines(problems)
      ~ "\n  The criterion is NOT \"zero under source/tools/**\" — that form is "
      ~ "unreachable inside the plan's own scope, because decision D1 puts the "
      ~ "transform zone out of it and the zone holds every remaining writer. "
      ~ "The reachable form is ONE seam site plus THREE named rejections, and "
      ~ "the rejections are enumerated above so the deferral cannot quietly "
      ~ "become a hole.");
}

// ---------------------------------------------------------------------------
// 2. NON-VACUITY, and it is not one floor but two.
//
//    Member 1's shape is "no unrostered hits", which a reader that returned
//    nothing satisfies perfectly. Two independent floors refuse that: the file
//    COUNT (the walk found the tree) and the WRITING count (the scanner found
//    the calls). Either alone can be satisfied by an accident — a tree with the
//    files but a desynced stripper, or a roster of four over a tree of one.
// ---------------------------------------------------------------------------
unittest {
    size_t files = 0, writing = 0, surface = 0;
    foreach (rel; population()) {
        immutable full = buildPath(repoRoot, rel);
        if (!exists(full)) continue;
        ++files;
        auto hits = historySurface(stripCommentsAndStrings(readText(full)));
        surface += hits.length;
        foreach (h; hits) if (isWritingPrimitive(h.name)) ++writing;
    }

    assert(files >= 60,
        "task 1905 criterion 1: the walk of `source/tools/` visited only "
      ~ files.to!string ~ " file(s). Member 1 above is then vacuous — it found "
      ~ "no unrostered writer because it read almost nothing.");

    assert(surface >= 20,
        "task 1905 criterion 1: only " ~ surface.to!string ~ " call(s) on the "
      ~ "history surface across the whole population. The tools reach it far "
      ~ "more often than that for `undo`, `runOpen`, `nextRun` and "
      ~ "`invalidateRedo` alone; a number this low means the stripper lost its "
      ~ "place and ate the rest of every file.");

    assert(writing == 6,
        "task 1905 criterion 1: " ~ writing.to!string ~ " writing primitive(s) "
      ~ "reached from `source/tools/** ∪ source/tool.d`, and the roster carries "
      ~ "SIX — three arms of the one seam site, three rejected transform-zone "
      ~ "calls. A number BELOW six with member 1 green means a roster row is "
      ~ "matching nothing (good news that still has to be written down); a "
      ~ "number above six is caught by member 1 with its address.");
}

private string joinLines(const(string)[] xs) {
    string r;
    foreach (x; xs) r ~= x ~ "\n";
    return r;
}
