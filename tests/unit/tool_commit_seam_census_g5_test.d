// tool_commit_seam_census_g5_test — the text half of the gesture-recording
// seam, for group G5 (slice: Edge Slice + Loop Slice + Slice). Task 1905,
// phase C.
//
// ONE FILE PER FAMILY, and that is not filing tidiness. A single tree-wide
// census would serialise the four phase-C lanes behind each other, and the
// failure it invites is the silent one: two lanes each append a roster line to
// the same file, the merge keeps one, and the lost line's family is then
// unwatched with nothing red to say so. Shape copied deliberately from
// `tests/unit/tool_commit_seam_census_g1_test.d` (phase B).
//
// G5 IS THE GROUP WITH A RULE OF ITS OWN, and it is the reason this file is
// not a copy of its G3 sibling with the names changed. The slice family holds
// the task's ONLY legitimate non-recorder mutation of the history:
// `CommandHistory.invalidateRedo()`, called four times — three in
// `edge_slice_tool.d` (`latchFirstPoint`, `armChain`, `rebuildPreview`), one in
// `loop_slice_tool.d` (`rebuildCut`). It is the task-0429 primitive: a standing
// preview writes into the real mesh OUTSIDE the history, so a redo stepping the
// stack under that preview would replay onto a mesh nobody recorded. Those four
// calls STAY. What must not happen is the number moving without an argument, so
// they are carried here as NAMED ROWS WITH THEIR COUNTS, per file, plus a family
// total — because a bare "four `invalidateRedo` calls exist somewhere in slice"
// is indistinguishable from someone having added a fifth, and a per-file count
// is also what separates "one deleted in edge slice" from "one added in loop
// slice" (lane 2710, decision D-G0G3G5-5).
//
// AND THE SET CANNOT BE PINNED BEHAVIOURALLY — measured, not assumed. Lane 2710
// deleted `latchFirstPoint`'s call and ran the suite: this census's ancestor
// reddened and `tests/test_tool_gesture_g5.d`'s Block 2 reddened, while the
// SHIPPED test named for the behaviour, `tests/test_standing_preview_redo.d`,
// stayed GREEN — its scenario A' arms the chain HEADLESSLY and lands in
// `armChain`, never in the interactive latch. Two of the four sites are not
// independently witnessable at all: by the time any `rebuildPreview` scrub runs,
// the latch has already emptied the redo stack, so the second call has nothing
// left to kill. That is the ordinary "a second, unnamed guard refuses first"
// shape — here not a defect but the order of the calls. Hence: the SET is pinned
// by a counted name, with the reason recorded beside it.
//
// THE KEY MEMBER KEYS ON THE WHOLE CALL SURFACE, NOT ON A REGEX OF ONE NAME.
// `history_?\.record` — revision 2 of the plan's predicate — misses
// `replaceInSessionTailWith`, `recordInSession`, `consolidate` and all four
// `invalidateRedo` calls above. A widened regex is another list the next person
// forgets to widen, so this census collects EVERY `history.<NAME>(` in the
// population and compares the multiset against a roster with a reason per name.
//
// WHAT IT CANNOT SEE: a seam that recorded the RIGHT carrier with the WRONG
// payload. That is `tests/fixtures/tool_gesture/g5.json`'s job, read by
// `tests/test_tool_gesture_g5.d` and frozen by lane 2710 before this migration.
//
// WHY `source/tool.d` IS IN THE POPULATION. After the migration all three G5
// tools reach `CommandHistory` only through `invalidateRedo`; none records
// directly. A census asserting "no unrostered history call" would be satisfied
// by a stripper that lost its place and by a `repoRoot` pointing nowhere,
// indistinguishably from the real green. `class Tool` lives in `source/tool.d`,
// OUTSIDE `source/tools/**`, and is the family's one surviving recorder;
// including it gives member 2 a non-vacuity floor made of calls that must be
// there. Plan §8's DoD is stated over `source/tools/** ∪ source/tool.d` for
// exactly this reason (round 4, fix 1). The floor is set at FOUR — the seam's
// calls alone, deliberately NOT eight — so that deleting an `invalidateRedo`
// cannot trip the floor and swallow the named finding it was run to produce.
//
// MUTATIONS, one per member, each reddening only its own:
//   1. add a file under `source/tools/slice/` -> member 1, by name.
//   2. write `history.consolidate(...)` into a slice tool -> member 2, as
//      "unknown name on the history surface", with the address.
//   3. delete ONE `history.invalidateRedo()` call -> member 2, with the file's
//      count AND the family total, and the reason quoted.
//   4. drop the `invalidateRedo` roster rows -> member 2, as four unrostered
//      names with their addresses.
//   5. change one site's mode `Plain` -> `InSession` -> member 3, with both
//      mode tuples; member 2 stays green (no new history NAME appears).
//   6. delete a `setGestureBindings` line from a G5 registration -> member 6,
//      by wire id. It COMPILES; the tool is simply never bound.
//   Run 3 and 5 ISOLATED from anything that also moves another member:
//   druntime stops a module at its first failed assert, so a second reason
//   hides behind the first.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_commit_seam_census_g5_test;

import std.algorithm : sort;
import std.array     : appender;
import std.conv      : to;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.path      : baseName, buildPath, dirName;
import std.string    : indexOf;

// ---------------------------------------------------------------------------
// EVERY MEMBER BELOW ACCUMULATES AND RAISES ONCE — INCLUDING ITS FLOOR, and
// that is a DELIBERATE divergence from the phase-B template this file is
// otherwise copied from. Measured here, not reasoned about: member 5's floor
// was written the phase-B way, as a leading `assert` ahead of the accumulator,
// and the mutation that opens a RECORDING batch in `slice_tool.d` reddened THE
// FLOOR ("only 9 unrecorded batch opening(s)") and swallowed both findings it
// was run to produce — the file's own count moving 8 -> 7, and the recording
// batch appearing at all. That is the shape lane 2710 already paid for once
// (decision D-G0G3G5-5) and CLAUDE.md's "a second, unnamed guard refuses first,
// so the guard under test is never reached". A floor is a finding like any
// other; it goes in the list with the rest, so a mutation run reads every
// offender at once instead of the first one structurally.
// ---------------------------------------------------------------------------

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// The stripper. Measured, not assumed: `edge_slice_tool.d` and
// `loop_slice_tool.d` BOTH mention `history.undo()` in prose, and without the
// strip this census would carry two phantom rows — the exact shape that teaches
// people to bump a number without looking, and a number bumped without looking
// is not a witness (plan §5.1, Б16).
//
// Same shape as `tests/unit/commit_seam_census_test.d`'s, with the same known
// gap: wysiwyg strings (`r"…"`) and character literals (`'"'`) can desync it.
// None of the population contains either today, and the guard against a silent
// desync is not a promise — it is member 2's non-vacuity floor: a scanner that
// lost its place eats the rest of the file, the seam's four calls vanish with
// it, and the floor reddens saying so.
// ---------------------------------------------------------------------------
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

/// Every `history.<NAME>(` / `history_.<NAME>(` in `src`, as (name, line).
/// Hand-scanned rather than regex'd so the receiver term stays exactly the one
/// the plan's population is defined over.
private struct SurfaceHit { string name; size_t line; }

private SurfaceHit[] historySurface(string src) {
    SurfaceHit[] hits;
    size_t i = 0;
    while (true) {
        auto rel = src[i .. $].indexOf("history");
        if (rel < 0) break;
        size_t p = i + cast(size_t) rel;
        i = p + 7;
        if (p > 0 && isIdentChar(src[p - 1])) continue;      // whole identifier
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
// THE FAMILY, and the directory is NOT quite the family — one file in it
// belongs to another group, so the census carries two populations and says
// which member uses which.
//
//   `kSliceDir`  — every file under `source/tools/slice/`. Members 1, 2 and 5
//                  run over it. `edge_slide.d` is not G5: it is a
//                  `CommandWrapperTool`, group G6, and it reaches
//                  `CommandHistory` not at all (its commit path is
//                  `CommandWrapperTool.commitNow`, in another file). It is still
//                  scanned, because "this directory reaches the history only
//                  through the seam and through four named `invalidateRedo`
//                  calls" is a property worth holding over all four files.
//   `kG5Sites`   — the three files this group migrates. Member 3 (seam call
//                  sites and modes) runs over these plus `source/tool.d`.
// ---------------------------------------------------------------------------
private struct DirRow { string file; string group; string why; }

private enum DirRow[] kSliceDir = [
    DirRow("edge_slice_tool.d", "G5",
        "EdgeSliceTool.commitChain — ONE Plain record for a whole N-cut chain, "
      ~ "migrated by this lane; also three of the family's four invalidateRedo"),
    DirRow("loop_slice_tool.d", "G5",
        "LoopSliceTool.commitEdit — one Plain record per committed cut, "
      ~ "migrated by this lane; also the fourth invalidateRedo"),
    DirRow("slice_tool.d", "G5",
        "SliceTool.commitCurrentSlice — one Plain record at deactivate, "
      ~ "migrated by this lane; its preview never touches the history"),
    DirRow("edge_slide.d", "G6 (command wrapper)",
        "a CommandWrapperTool: it records through CommandWrapperTool.commitNow "
      ~ "in tools/common/, not from this file, and its measured history surface "
      ~ "here is empty. G6 LANDED 2026-08-29 and that changed nothing on this "
      ~ "side — commitNow moved onto the seam, so the record this file does not "
      ~ "make is now made by `Tool.recordGestureEdit`. The file is rostered by "
      ~ "`tests/unit/tool_commit_seam_census_g6_test.d`; both zeros below stay "
      ~ "zeros, and that is what makes them a check rather than a coincidence"),
];

private enum string[] kG5Sites = [
    "source/tools/slice/edge_slice_tool.d",
    "source/tools/slice/loop_slice_tool.d",
    "source/tools/slice/slice_tool.d",
];

private string[] sliceDirPaths() {
    string[] r;
    foreach (row; kSliceDir) r ~= buildPath("source", "tools", "slice", row.file);
    return r;
}

// ---------------------------------------------------------------------------
// 1. THE FILE SET IS WALKED, NOT TRUSTED.
// ---------------------------------------------------------------------------
unittest {
    string[] found;
    foreach (e; dirEntries(buildPath(repoRoot, "source", "tools", "slice"),
                           "*.d", SpanMode.breadth))
        found ~= baseName(e.name);
    found.sort();

    string[] expect;
    foreach (row; kSliceDir) expect ~= row.file;
    expect.sort();

    string[] problems;
    if (found.length < 3)
        problems ~= "    · FLOOR: the walk of `source/tools/slice/` returned "
                  ~ "only " ~ found.length.to!string ~ " file(s). The path is "
                  ~ "wrong or the tree moved — every member below is then "
                  ~ "measuring nothing, and the two lines under this one are "
                  ~ "how it looks from the roster's side";

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
    if (bad.length || gone.length)
        problems ~= "    · new, not in the roster: " ~ (bad.length ? bad : "(none)")
                  ~ "\n    · rostered, now missing:  " ~ (gone.length ? gone : "(none)");

    assert(problems.length == 0,
        "G5 census: the slice directory's file set moved.\n"
      ~ joinLines(problems)
      ~ "  Every file here needs a GROUP beside it. A new slice tool that holds "
      ~ "a standing preview needs more than a roster line: it needs its own "
      ~ "`invalidateRedo` row below, or it silently ships a redo that replays "
      ~ "onto a mesh nobody recorded (task 0429).");
}

// ---------------------------------------------------------------------------
// 2. THE HISTORY CALL SURFACE, name by name, file by file — AND THE NAMED
//    NON-RECORDER ROWS THAT MAKE THIS FAMILY DIFFERENT.
// ---------------------------------------------------------------------------
private struct RosterRow { string path; string name; size_t count; string why; }

private enum RosterRow[] kSurfaceRoster = [
    // The seam itself. THREE primitives, one per `GestureRecordMode` member,
    // plus the belt's run-close.
    RosterRow("source/tool.d", "record", 1,
        "GestureRecordMode.Plain -> CommandHistory.record"),
    RosterRow("source/tool.d", "recordInSession", 1,
        "GestureRecordMode.InSession -> CommandHistory.recordInSession"),
    RosterRow("source/tool.d", "replaceInSessionTailWith", 1,
        "GestureRecordMode.ReplaceRunTail -> CommandHistory.replaceInSessionTailWith"),
    RosterRow("source/tool.d", "consolidate", 1,
        "the refusal belt closing the run the skipped splice would have closed"),

    // THE FOUR LEGAL NON-RECORDERS — the whole reason this file differs from
    // its G3 sibling. Task 0429: a standing preview writes into the real mesh
    // outside the history, so it must kill the redo timeline or a redo pressed
    // under the preview replays onto a mesh nobody recorded.
    RosterRow("source/tools/slice/edge_slice_tool.d", "invalidateRedo", 3,
        "latchFirstPoint (the chain opens, BEFORE the tool has written a "
      ~ "vertex — the only one of the four isolable by behaviour, and "
      ~ "tests/test_tool_gesture_g5.d Block 2 is that witness), armChain (the "
      ~ "headless arm bakes directly) and rebuildPreview (every other "
      ~ "standing-preview write; NOT isolable — by the time any scrub runs the "
      ~ "latch has already emptied the redo stack)"),
    RosterRow("source/tools/slice/loop_slice_tool.d", "invalidateRedo", 1,
        "rebuildCut — this tool's single standing-preview write-point; the "
      ~ "shipped tests/test_standing_preview_redo.d scenario A reaches it"),
];

/// The family total of the one legal non-recorder. Named separately because
/// the per-file rows and the sum answer different questions: the rows separate
/// "one deleted in edge slice" from "one added in loop slice"; the sum refuses
/// a fifth site in a file that had none. Both go into the SAME accumulator,
/// never in front of it (lane 2710, D-G0G3G5-5: a total asserted ahead of the
/// per-file lines swallowed the very finding the mutation was run to produce).
private enum size_t kInvalidateRedoTotal = 4;

unittest {
    string[] problems;
    size_t   totalHits    = 0;
    size_t   totalInvalid = 0;

    auto population = sliceDirPaths() ~ ["source/tool.d"];

    foreach (rel; population) {
        immutable full = buildPath(repoRoot, rel);
        assert(exists(full), "G5 census: population member is missing: " ~ rel);
        auto src  = stripCommentsAndStrings(readText(full));
        auto hits = historySurface(src);
        totalHits += hits.length;
        foreach (h; hits) if (h.name == "invalidateRedo") ++totalInvalid;

        foreach (h; hits) {
            bool rostered = false;
            foreach (row; kSurfaceRoster)
                if (row.path == rel && row.name == h.name) { rostered = true; break; }
            if (!rostered)
                problems ~= "    · UNROSTERED call on the history surface: `history."
                          ~ h.name ~ "(` at " ~ rel ~ ":" ~ h.line.to!string
                          ~ "  — after phase C every record in this family goes "
                          ~ "through `Tool.recordGestureEdit`, and the ONLY "
                          ~ "non-recorder this task blesses is `invalidateRedo`, "
                          ~ "rostered per file with its reason. If this call is "
                          ~ "legitimate, add a roster row with the reason; do "
                          ~ "not widen a regex.";
        }
        foreach (row; kSurfaceRoster) {
            if (row.path != rel) continue;
            size_t n = 0;
            foreach (h; hits) if (h.name == row.name) ++n;
            if (n != row.count)
                problems ~= "    · " ~ rel ~ ": `history." ~ row.name ~ "(` x "
                          ~ n.to!string ~ ", roster says " ~ row.count.to!string
                          ~ ". " ~ (row.name == "invalidateRedo"
                              ? ("This is a LEGAL non-recorder, not a defect — "
                               ~ row.why ~ ". It stays; what must not happen is "
                               ~ "the number moving without an argument. FEWER "
                               ~ "means a deliberate primitive was deleted and "
                               ~ "a standing preview now leaves the redo "
                               ~ "timeline alive; MORE means a new "
                               ~ "standing-preview write-point nobody named.")
                              : ("(" ~ row.why ~ ")"));
        }
    }

    // The family total, into the SAME accumulator as the per-file rows above.
    if (totalInvalid != kInvalidateRedoTotal)
        problems ~= "    · TOTAL: " ~ totalInvalid.to!string
                  ~ " `invalidateRedo(` call(s) across the slice family, "
                  ~ "expected exactly " ~ kInvalidateRedoTotal.to!string
                  ~ ". This is the ONE group of task 1905 holding a legitimate "
                  ~ "non-recorder mutation of the history, and the whole point "
                  ~ "of counting it by name is that a bare '4' is otherwise "
                  ~ "indistinguishable from someone having added a fifth. Two "
                  ~ "of the four sites have no behavioural witness anywhere in "
                  ~ "the suite and cannot get one — this count IS their pin.";

    // NON-VACUITY, and the floor is FOUR on purpose. The seam's own calls are
    // the only ones that must be there; setting it at eight (seam + the four
    // legal non-recorders) would make a deleted `invalidateRedo` trip THIS
    // assert first and swallow the named finding above, which is the exact
    // failure the mutation is run to expose.
    if (totalHits < 4)
        problems ~= "    · FLOOR: the scan found " ~ totalHits.to!string
                  ~ " call(s) on the history surface across the whole "
                  ~ "population, and the seam alone makes four. Either the "
                  ~ "scanner read nothing (check `repoRoot` and the stripper) "
                  ~ "or a seam primitive was deleted — the per-file line above "
                  ~ "says which, and it says so only because this line is a "
                  ~ "finding rather than a guard placed in front of it.";

    assert(problems.length == 0,
        "G5 census: the family's history call surface is not what the seam "
      ~ "leaves behind.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 3. THE SEAM'S CALL SITES, per file and PER MODE.
//
//    All three G5 sites are `Plain`, and that is the group's contract: each
//    commits ONE entry (edge slice: one for a whole chain), none opens a live
//    run, none splices a tail. `InSession` here would leave a run open that
//    nothing in this family ever closes — and nothing on the HTTP surface would
//    say so, which is why the mode is counted in text rather than driven.
// ---------------------------------------------------------------------------
private struct CallRow { string path; size_t calls, plain, inSession, replaceTail; }

private enum CallRow[] kCallRoster = [
    // The seam: one declaration, one dispatch arm per mode — plus a SECOND
    // mention of `ReplaceRunTail`, the belt's `mode ==` test in
    // `refuseGestureRecord`. Counted, not tolerated: if it disappears the belt
    // has stopped closing the run it skipped.
    CallRow("source/tool.d",                            1, 1, 1, 2),
    CallRow("source/tools/slice/edge_slice_tool.d",     1, 1, 0, 0),
    CallRow("source/tools/slice/loop_slice_tool.d",     1, 1, 0, 0),
    CallRow("source/tools/slice/slice_tool.d",          1, 1, 0, 0),
];

unittest {
    string[] problems;
    size_t   totalCalls = 0;

    auto population = kG5Sites.dup ~ ["source/tool.d"];

    foreach (rel; population) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t calls = countOccurrences(src, "recordGestureEdit(");
        immutable size_t plain = countOccurrences(src, "GestureRecordMode.Plain");
        immutable size_t sess  = countOccurrences(src, "GestureRecordMode.InSession");
        immutable size_t tail  = countOccurrences(src, "GestureRecordMode.ReplaceRunTail");
        totalCalls += calls;

        size_t wantC, wantP, wantS, wantT;
        bool listed = false;
        foreach (row; kCallRoster)
            if (row.path == rel) {
                wantC = row.calls; wantP = row.plain;
                wantS = row.inSession; wantT = row.replaceTail;
                listed = true; break;
            }
        if (!listed) {
            problems ~= "    · " ~ rel ~ " is in the G5 site population and not "
                      ~ "in the call roster";
            continue;
        }
        if (calls != wantC)
            problems ~= "    · " ~ rel ~ ": recordGestureEdit( x " ~ calls.to!string
                      ~ ", roster says " ~ wantC.to!string;
        if (plain != wantP || sess != wantS || tail != wantT)
            problems ~= "    · " ~ rel ~ ": modes {Plain " ~ plain.to!string
                      ~ ", InSession " ~ sess.to!string ~ ", ReplaceRunTail "
                      ~ tail.to!string ~ "}, roster says {Plain " ~ wantP.to!string
                      ~ ", InSession " ~ wantS.to!string ~ ", ReplaceRunTail "
                      ~ wantT.to!string ~ "}";
    }

    // A slice file OUTSIDE the G5 site list that starts naming the seam is a
    // migration nobody rostered — the mirror image of the member above.
    foreach (rel; sliceDirPaths()) {
        bool isSite = false;
        foreach (s; kG5Sites) if (s == rel) { isSite = true; break; }
        if (isSite) continue;
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t calls = countOccurrences(src, "recordGestureEdit(");
        if (calls != 0)
            problems ~= "    · " ~ rel ~ " names the seam " ~ calls.to!string
                      ~ " time(s) and is not a G5 site. `edge_slide.d` is a "
                      ~ "CommandWrapperTool and belongs to G6, which landed "
                      ~ "2026-08-29 WITHOUT adding a seam call here: its record "
                      ~ "lives in `CommandWrapperTool.commitNow`. A non-zero "
                      ~ "count means this file grew its own, which is a "
                      ~ "deliberate move to make in the G6 roster, not a drift";
    }

    if (totalCalls < 4)
        problems ~= "    · FLOOR: only " ~ totalCalls.to!string
                  ~ " `recordGestureEdit(` in the whole population. Three tool "
                  ~ "sites plus the seam's own declaration are expected; a "
                  ~ "number near zero means the scanner read nothing, not that "
                  ~ "the family stopped recording.";

    assert(problems.length == 0,
        "G5 census: the seam's call sites moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 4. THE FAMILY BINDS THROUGH THE BASE, and declares no binder of its own.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;
    size_t   seamDecls = 0;

    foreach (rel; sliceDirPaths() ~ ["source/tool.d"]) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t oldDecls = countOccurrences(src, "void setUndoBindings");
        immutable size_t newDecls = countOccurrences(src, "void setGestureBindings");
        seamDecls += newDecls;
        if (oldDecls != 0)
            problems ~= "    · " ~ rel ~ " still declares setUndoBindings x "
                      ~ oldDecls.to!string ~ " — the slice directory binds "
                      ~ "through `Tool.setGestureBindings` now";
        if (rel != "source/tool.d" && newDecls != 0)
            problems ~= "    · " ~ rel ~ " declares its own setGestureBindings; "
                      ~ "the base's is `final` and there is nothing to add";
    }

    if (seamDecls != 1)
        problems ~= "    · `void setGestureBindings` is declared "
                  ~ seamDecls.to!string ~ " time(s) in the population; exactly "
                  ~ "one, on `Tool`, is the point of it";
    assert(problems.length == 0,
        "G5 census: binding declarations moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 5. THE PREVIEW BATCHES STAY UNRECORDED — the family's other standing promise.
//
//    Plan §6 hands G5 a two-sided statement it asked not to be collapsed: the
//    slice family ships with NON-WRITING preview batches. `slice_tool.d` opens
//    eight `MeshEditBatch.unrecorded` and `loop_slice_tool.d` two, and the
//    reason it matters is `mesh_ops/cut.d`: its terminus splice writes by raw
//    index PAST the delta tracker, and that write is harmless today ONLY
//    because every caller of the clipped entry point sits under an unrecorded
//    batch — nothing is recorded, so nothing is wrong. A RECORDING batch opened
//    beside them would make the same code silently drop a write from the delta.
//    So the row is two-sided: the unrecorded count is held AND the recorded
//    count is held at zero, and a single "cut.d is fine" assertion would have
//    been green over either failure.
// ---------------------------------------------------------------------------
private struct BatchRow { string file; size_t unrecorded; }

private enum BatchRow[] kBatchRoster = [
    BatchRow("slice_tool.d",      8),
    BatchRow("loop_slice_tool.d", 2),
    BatchRow("edge_slice_tool.d", 0),
    BatchRow("edge_slide.d",      0),
];

unittest {
    string[] problems;
    size_t   totalUnrecorded = 0;

    foreach (row; kBatchRoster) {
        immutable rel = buildPath("source", "tools", "slice", row.file);
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t unrec = countOccurrences(src, "MeshEditBatch.unrecorded(");
        immutable size_t opens = countOccurrences(src, "MeshEditBatch(");
        totalUnrecorded += unrec;
        if (unrec != row.unrecorded)
            problems ~= "    · " ~ row.file ~ ": MeshEditBatch.unrecorded( x "
                      ~ unrec.to!string ~ ", roster says "
                      ~ row.unrecorded.to!string;
        if (opens != 0)
            problems ~= "    · " ~ row.file ~ " opens a RECORDING MeshEditBatch x "
                      ~ opens.to!string ~ ". The slice family ships with "
                      ~ "non-writing preview batches, and `mesh_ops/cut.d`'s "
                      ~ "terminus splice writes by raw index past the delta "
                      ~ "tracker: under a recording batch that write is "
                      ~ "silently dropped from the delta. If a recording batch "
                      ~ "is wanted here, `cut.d` has to be fixed FIRST";
    }

    if (totalUnrecorded < 10)
        problems ~= "    · FLOOR: only " ~ totalUnrecorded.to!string
                  ~ " unrecorded batch opening(s) across the slice family, "
                  ~ "expected 10. The two-sided rows above are vacuous if the "
                  ~ "scanner cannot see the openings that are there — and if "
                  ~ "one of them says a RECORDING batch appeared, this line is "
                  ~ "its consequence, not a second independent finding.";
    assert(problems.length == 0,
        "G5 census: the family's edit batches moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 6. EVERY G5 REGISTRATION CALLS THE BASE BINDER.
//
//    Scoped to the three wire ids this group owns, deliberately: a count over
//    the whole of `registration.d` would be a number every later family has to
//    bump — a lane serialiser, and a merge conflict between the three sibling
//    phase-C lanes on a line carrying no information.
//
//    TWO OF THE THREE SHARE A FACTORY. `mesh.sliceTool` and `mesh.edgeSliceTool`
//    both bind `bevelEditFactory` and therefore both record under the wire name
//    `mesh.bevel_edit`; only `mesh.loopSliceTool` has a name of its own. That is
//    measured (lane 2710, finding 1) and it is why a G5 mutation that must
//    redden exactly one fixture cell keys on the plane dumps for that pair, not
//    on `entryNames`.
// ---------------------------------------------------------------------------
private enum string[] kG5WireIds = [
    "mesh.loopSliceTool", "mesh.sliceTool", "mesh.edgeSliceTool",
];

unittest {
    // RAW source here, not the stripped copy, and that is the one place in this
    // file where it has to be: the stripper blanks string literals, and the wire
    // id IS a string literal. The needle keeps `] = ` on the end so it matches
    // the DEFINITION and not a second mention of the same key in a neighbouring
    // `commandFactories` entry; the uniqueness check below makes that a claim
    // rather than an assumption.
    immutable src = readText(buildPath(repoRoot, "source", "registration.d"));
    string[] problems;
    size_t   checked = 0;

    foreach (id; kG5WireIds) {
        immutable needle = "reg.toolFactories[\"" ~ id ~ "\"] = ";
        if (countOccurrences(src, needle) != 1) {
            problems ~= "    · wire id `" ~ id ~ "`: found "
                      ~ countOccurrences(src, needle).to!string
                      ~ " registration definitions, expected exactly 1";
            continue;
        }
        auto at   = src.indexOf(needle);
        auto rest = src[cast(size_t) at .. $];
        auto end  = rest.indexOf("});");
        immutable block = (end < 0) ? rest : rest[0 .. cast(size_t) end];
        ++checked;
        if (countOccurrences(block, "setGestureBindings(") != 1)
            problems ~= "    · `" ~ id ~ "` does not bind through "
                      ~ "setGestureBindings exactly once";
        if (countOccurrences(block, "setUndoBindings(") != 0)
            problems ~= "    · `" ~ id ~ "` still calls setUndoBindings — a G5 "
                      ~ "tool has no such method any more, so this would not "
                      ~ "even compile; if you are reading this, the id resolved "
                      ~ "to the wrong block";
    }

    if (checked != kG5WireIds.length)
        problems ~= "    · FLOOR: located only " ~ checked.to!string ~ " of "
                  ~ kG5WireIds.length.to!string ~ " registration blocks. The "
                  ~ "scan is reading the wrong file or the needle stopped "
                  ~ "matching — every per-id check above then passes vacuously.";
    assert(problems.length == 0,
        "G5 census: a registration left the base binder.\n" ~ joinLines(problems)
      ~ "  An unbound tool still COMPILES and still runs: `history` and "
      ~ "`gestureFactory` stay null, the commit returns at its first gate, and "
      ~ "the gesture edits the mesh with no undo entry behind it.");
}

private string joinLines(const(string)[] xs) {
    string r;
    foreach (x; xs) r ~= x ~ "\n";
    return r;
}
