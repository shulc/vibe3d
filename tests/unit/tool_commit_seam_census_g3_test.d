// tool_commit_seam_census_g3_test — the text half of the gesture-recording
// seam, for group G3 (deform: Smooth Shift + Stroke Extrude). Task 1905,
// phase C.
//
// ONE FILE PER FAMILY, and that is not filing tidiness. A single tree-wide
// census would serialise the four phase-C lanes behind each other, and the
// failure it invites is the silent one: two lanes each append a roster line to
// the same file, the merge keeps one, and the lost line's family is then
// unwatched with nothing red to say so. Per-family files make that collision a
// textual conflict instead of a disappearance. Shape copied deliberately from
// `tests/unit/tool_commit_seam_census_g1_test.d` (phase B), which in turn took
// its stripper and its accumulate-then-fail-once from
// `tests/unit/commit_seam_census_test.d`.
//
// THE KEY MEMBER KEYS ON THE WHOLE CALL SURFACE, NOT ON A REGEX OF ONE NAME.
// `history_?\.record` — the predicate revision 2 of the plan used — misses
// `replaceInSessionTailWith`, `recordInSession`, `consolidate` and (in the
// sibling slice family) all four legitimate `invalidateRedo` calls. The lesson
// is not "the regex was one name short"; a widened regex is another list the
// next person forgets to widen. So the census collects EVERY `history.<NAME>(`
// in the population and compares the multiset against a roster carrying a
// reason per name. A sixth history primitive called from a deform tool tomorrow
// reddens this for free, with the name and the address, and no predicate edit.
//
// WHAT IT CANNOT SEE, said here so nobody trusts it for that: a seam that
// recorded the RIGHT carrier with the WRONG payload. That is the frozen plane
// fixture's job (`tests/fixtures/tool_gesture/g3.json`, read by
// `tests/test_tool_gesture_g3.d`, frozen by lane 2710 before this migration).
//
// WHY `source/tool.d` IS IN THE POPULATION, and it is the member that keeps
// this file from being a check that cannot come out differently. After the
// migration BOTH G3 tools reach `CommandHistory` zero times. A census that
// asserts "no unrostered history call" over two files that contain none is
// satisfied by a stripper that lost its place, by a `repoRoot` pointing
// nowhere, and by a scanner that read the empty string — it is green for the
// right reason and for three wrong ones, indistinguishably. `class Tool` lives
// in `source/tool.d`, OUTSIDE `source/tools/**`, and it is the family's one
// surviving recorder; including it gives member 2 a non-vacuity floor made of
// calls that must be there. Plan §8's DoD is stated over
// `source/tools/** ∪ source/tool.d` for exactly this reason (round 4, fix 1).
//
// THE REDUNDANCY WITH G1's CENSUS IS DELIBERATE AND NAMED. Every phase-C family
// census carries the same four `source/tool.d` roster rows. They cannot drift
// apart silently — a seam change reddens all of them at once, loudly, in
// different files — and the alternative (one shared roster) is the lane
// serialiser this file exists to avoid.
//
// MUTATIONS, one per member, each reddening only its own:
//   1. add a file under `source/tools/deform/` -> member 1, by name.
//   2. write `history.consolidate(...)` into a deform tool -> member 2, as
//      "unknown name on the history surface", with the address.
//   3. turn one `recordGestureEdit` back into `history.record(cmd)` -> member 2
//      (an unrostered `record` in a tool). Run it ISOLATED: it also moves
//      member 3's count, and druntime stops a module at its first failed
//      assert, so the second reason hides behind the first.
//   4. change one site's mode `Plain` -> `InSession` -> member 3, with both
//      mode tuples, and member 2 stays green (no new history name appears).
//   5. delete a `setGestureBindings` line from a G3 registration -> member 5,
//      by wire id. It COMPILES; the tool is simply never bound.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_commit_seam_census_g3_test;

import std.algorithm : sort;
import std.array     : appender;
import std.conv      : to;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.path      : baseName, buildPath, dirName;
import std.string    : indexOf;

// ---------------------------------------------------------------------------
// EVERY MEMBER BELOW ACCUMULATES AND RAISES ONCE — INCLUDING ITS FLOOR, and
// that is a DELIBERATE divergence from the phase-B template this file is
// otherwise copied from. Measured here, not reasoned about: the batch member's
// floor was written the phase-B way, as a leading `assert` ahead of the
// accumulator, and the mutation that opens a RECORDING batch in `slice_tool.d`
// reddened THE FLOOR ("only 9 unrecorded batch opening(s)") and swallowed both
// findings it was run to produce — the file's own count moving 8 -> 7, and the
// recording batch appearing at all. That is the shape lane 2710 already paid
// for once (decision D-G0G3G5-5) and CLAUDE.md's "a second, unnamed guard
// refuses first, so the guard under test is never reached". A floor is a
// finding like any other; it goes in the list with the rest, so a mutation run
// reads every offender at once instead of the first one alphabetically or
// structurally.
// ---------------------------------------------------------------------------

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// The stripper, because the count is the whole point. A doc comment that names
// `history.record(` moves the number, and this file's job is to notice a real
// recorder, not a sentence about one. Measured here, not assumed: both slice
// siblings mention `history.undo()` in prose, and the deform pair carry
// `factory`-era comments — without the strip this census would carry phantom
// rows.
//
// Same shape as `tests/unit/commit_seam_census_test.d`'s, and with the same
// known gap: wysiwyg strings (`r"…"`) and character literals (`'"'`) can desync
// it. None of the population contains either today, and the guard against a
// silent desync is not a promise — it is the non-vacuity floor in member 2: a
// scanner that lost its place eats the rest of the file, the seam's four calls
// vanish with it, and the floor reddens with a message that says so.
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
// THE FAMILY, and the directory is NOT the family — which is why this census
// carries two populations rather than one, and says which member uses which.
//
//   `kDeformDir`  — every file under `source/tools/deform/`. Members 1, 2 and 4
//                   run over it. Three of the five are not G3: `magnet.d` moved
//                   to G1 (phase B migrated it), and `bend.d` / `push.d` are
//                   `TransformTool` subclasses inside the T2 zone, out of scope
//                   for task 1905 entirely (plan D1). They are still scanned,
//                   because "this directory reaches `CommandHistory` nowhere but
//                   through the seam" is a property worth holding over all five,
//                   and because a file with no owner is exactly where an
//                   unwitnessed recorder would land.
//   `kG3Sites`    — the two files this group migrates. Member 3 (seam call
//                   sites and modes) runs over these plus `source/tool.d`, and
//                   deliberately NOT over `magnet.d`: magnet's call site and its
//                   mode belong to G1's roster, and rostering it here too would
//                   be the second dictionary that disagrees with the first.
// ---------------------------------------------------------------------------
private struct DirRow { string file; string group; string why; }

private enum DirRow[] kDeformDir = [
    DirRow("smooth_shift_tool.d", "G3",
        "SmoothShiftTool.commitEdit — one Plain record, migrated by this lane"),
    DirRow("stroke_extrude_tool.d", "G3",
        "StrokeExtrudeTool.commitEdit — one Plain record, migrated by this lane"),
    DirRow("magnet.d", "G1",
        "the tree's only non-wrapper MeshVertexEdit carrier; migrated in phase B "
      ~ "and rostered by tool_commit_seam_census_g1_test.d, not here"),
    DirRow("bend.d", "T2 (out of scope)",
        "a TransformTool subclass in the transform-state zone deferred by plan "
      ~ "D1; measured to reach CommandHistory not at all, and that zero is what "
      ~ "member 2 holds"),
    DirRow("push.d", "T2 (out of scope)",
        "as bend.d — same base, same deferral, same measured zero"),
];

private enum string[] kG3Sites = [
    "source/tools/deform/smooth_shift_tool.d",
    "source/tools/deform/stroke_extrude_tool.d",
];

private string[] deformDirPaths() {
    string[] r;
    foreach (row; kDeformDir) r ~= buildPath("source", "tools", "deform", row.file);
    return r;
}

// ---------------------------------------------------------------------------
// 1. THE FILE SET IS WALKED, NOT TRUSTED.
//
//    A new tool dropped into `source/tools/deform/` is a new inhabitant of this
//    census's territory whether or not anyone updates a table, and it must not
//    join the tree unnoticed by the family that owns the directory.
// ---------------------------------------------------------------------------
unittest {
    string[] found;
    foreach (e; dirEntries(buildPath(repoRoot, "source", "tools", "deform"),
                           "*.d", SpanMode.breadth))
        found ~= baseName(e.name);
    found.sort();

    string[] expect;
    foreach (row; kDeformDir) expect ~= row.file;
    expect.sort();

    string[] problems;
    if (found.length < 4)
        problems ~= "    · FLOOR: the walk of `source/tools/deform/` returned "
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
        "G3 census: the deform directory's file set moved.\n"
      ~ joinLines(problems)
      ~ "  Every file here needs a GROUP beside it: G3 (this lane's), G1 "
      ~ "(magnet, migrated in phase B), or the T2 zone plan D1 defers. A file "
      ~ "with no group is a tool whose record path no census owns — add its row "
      ~ "with its reason, and if it is a G3 site give it a fixture cell too.");
}

// ---------------------------------------------------------------------------
// 2. THE HISTORY CALL SURFACE, name by name, file by file.
//
//    After the migration every recorder reachable from this directory lives in
//    ONE place — the seam on `Tool` — and G3 holds NO legitimate non-recorder
//    at all, unlike the slice family whose roster names `invalidateRedo` four
//    times with its reason. So every deform file's row is the empty set, and
//    the only rostered names in the whole member belong to `source/tool.d`.
// ---------------------------------------------------------------------------
private struct RosterRow { string path; string name; size_t count; string why; }

private enum RosterRow[] kSurfaceRoster = [
    // The seam itself. THREE primitives, one per `GestureRecordMode` member,
    // plus the belt's run-close. This is the whole reason `source/tool.d` is in
    // the population: it is the family's only surviving recorder, and the only
    // thing here whose count is non-zero.
    RosterRow("source/tool.d", "record", 1,
        "GestureRecordMode.Plain -> CommandHistory.record"),
    RosterRow("source/tool.d", "recordInSession", 1,
        "GestureRecordMode.InSession -> CommandHistory.recordInSession"),
    RosterRow("source/tool.d", "replaceInSessionTailWith", 1,
        "GestureRecordMode.ReplaceRunTail -> CommandHistory.replaceInSessionTailWith"),
    RosterRow("source/tool.d", "consolidate", 1,
        "the refusal belt closing the run the skipped splice would have closed"),
];

unittest {
    string[] problems;
    size_t   totalHits = 0;

    auto population = deformDirPaths() ~ ["source/tool.d"];

    foreach (rel; population) {
        immutable full = buildPath(repoRoot, rel);
        assert(exists(full), "G3 census: population member is missing: " ~ rel);
        auto src  = stripCommentsAndStrings(readText(full));
        auto hits = historySurface(src);
        totalHits += hits.length;

        foreach (h; hits) {
            bool rostered = false;
            foreach (row; kSurfaceRoster)
                if (row.path == rel && row.name == h.name) { rostered = true; break; }
            if (!rostered)
                problems ~= "    · UNROSTERED call on the history surface: `history."
                          ~ h.name ~ "(` at " ~ rel ~ ":" ~ h.line.to!string
                          ~ "  — after phase C every record reachable from "
                          ~ "`source/tools/deform/` goes through "
                          ~ "`Tool.recordGestureEdit`, and this group holds no "
                          ~ "legal non-recorder (the slice family's "
                          ~ "`invalidateRedo` rows are the only ones in the "
                          ~ "task). If this call is legitimate, add a roster row "
                          ~ "with its reason; do not widen a regex.";
        }
        foreach (row; kSurfaceRoster) {
            if (row.path != rel) continue;
            size_t n = 0;
            foreach (h; hits) if (h.name == row.name) ++n;
            if (n != row.count)
                problems ~= "    · " ~ rel ~ ": `history." ~ row.name ~ "(` x "
                          ~ n.to!string ~ ", roster says " ~ row.count.to!string
                          ~ "  (" ~ row.why ~ ")";
        }
    }

    // NON-VACUITY, and for this family it is load-bearing rather than
    // decorative: BOTH G3 files legitimately hold zero history calls, so every
    // "unrostered == 0" above is satisfied for free by a scanner that read
    // nothing. The four seam calls are the only ones that must be there.
    //
    // A FLOOR, not an equality: an EXTRA call is caught above with its name and
    // its address, which is the message worth reading.
    if (totalHits < 4)
        problems ~= "    · FLOOR: the scan found " ~ totalHits.to!string
                  ~ " call(s) on the history surface across the whole "
                  ~ "population, and the seam alone makes four. Either the "
                  ~ "scanner read nothing (check `repoRoot` and the stripper) "
                  ~ "or a seam primitive was deleted — the per-file line above "
                  ~ "says which, and it says so only because this line is a "
                  ~ "finding rather than a guard placed in front of it.";

    assert(problems.length == 0,
        "G3 census: the family's history call surface is not what the seam "
      ~ "leaves behind.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 3. THE SEAM'S CALL SITES, per file and PER MODE.
//
//    Population: G3's two files plus `source/tool.d`. `magnet.d` is NOT here
//    even though it names the seam — its site and mode are G1's roster rows,
//    and a second dictionary over the same fact is how the two drift apart.
//    A deform file that names the seam and is not listed reddens by name.
// ---------------------------------------------------------------------------
private struct CallRow { string path; size_t calls, plain, inSession, replaceTail; }

private enum CallRow[] kCallRoster = [
    // The seam: one declaration, one dispatch arm per mode — plus a SECOND
    // mention of `ReplaceRunTail`, the belt's `mode ==` test in
    // `refuseGestureRecord`. That second one is counted, not tolerated: if it
    // disappears the belt has stopped closing the run it skipped.
    CallRow("source/tool.d",                                  1, 1, 1, 2),
    CallRow("source/tools/deform/smooth_shift_tool.d",        1, 1, 0, 0),
    CallRow("source/tools/deform/stroke_extrude_tool.d",      1, 1, 0, 0),
];

unittest {
    string[] problems;
    size_t   totalCalls = 0;

    auto population = kG3Sites.dup ~ ["source/tool.d"];

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
            problems ~= "    · " ~ rel ~ " is in the G3 site population and not "
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

    // A deform file OUTSIDE the G3 site list that starts naming the seam is a
    // migration nobody rostered — the mirror image of the member above.
    foreach (rel; deformDirPaths()) {
        bool isSite = false;
        foreach (s; kG3Sites) if (s == rel) { isSite = true; break; }
        if (isSite || rel == "source/tools/deform/magnet.d") continue;
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t calls = countOccurrences(src, "recordGestureEdit(");
        if (calls != 0)
            problems ~= "    · " ~ rel ~ " names the seam " ~ calls.to!string
                      ~ " time(s) and is neither a G3 site nor magnet. It is in "
                      ~ "the T2 zone plan D1 defers; a record appearing there "
                      ~ "moves work this task deliberately did not schedule";
    }

    if (totalCalls < 3)
        problems ~= "    · FLOOR: only " ~ totalCalls.to!string
                  ~ " `recordGestureEdit(` in the whole population. Two tool "
                  ~ "sites plus the seam's own declaration are expected; a "
                  ~ "number near zero means the scanner read nothing, not that "
                  ~ "the family stopped recording.";

    assert(problems.length == 0,
        "G3 census: the seam's call sites moved.\n" ~ joinLines(problems)
      ~ "\n  Both G3 sites are `Plain`, and that is the group's whole contract: "
      ~ "each commits ONE entry from `deactivate`, with no live run to extend "
      ~ "or splice. `InSession` or `ReplaceRunTail` here would leave a run open "
      ~ "that nothing in this family ever closes.");
}

// ---------------------------------------------------------------------------
// 4. THE FAMILY BINDS THROUGH THE BASE, and declares no binder of its own.
//    Run over the whole deform directory: `magnet.d` lost its declaration in
//    phase B and `bend.d` / `push.d` never had one, so the correct value here
//    is zero for all five and stays zero.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;
    size_t   seamDecls = 0;

    foreach (rel; deformDirPaths() ~ ["source/tool.d"]) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t oldDecls = countOccurrences(src, "void setUndoBindings");
        immutable size_t newDecls = countOccurrences(src, "void setGestureBindings");
        seamDecls += newDecls;
        if (oldDecls != 0)
            problems ~= "    · " ~ rel ~ " still declares setUndoBindings x "
                      ~ oldDecls.to!string ~ " — the deform directory binds "
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
        "G3 census: binding declarations moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 5. EVERY G3 REGISTRATION CALLS THE BASE BINDER.
//
//    Scoped to the two wire ids this group owns, deliberately: a count of
//    `setGestureBindings` over the whole of `registration.d` would be a number
//    every later family has to bump — i.e. a lane serialiser, and a merge
//    conflict between the three sibling phase-C lanes on a line that carries no
//    information. Per-id it is exact AND it does not move when G2/G4/G5 land.
// ---------------------------------------------------------------------------
private enum string[] kG3WireIds = [
    "tool.strokeExtrude", "mesh.smoothShiftTool",
];

unittest {
    // RAW source here, not the stripped copy, and that is the one place in this
    // file where it has to be: the stripper blanks string literals, and the wire
    // id IS a string literal. The needle keeps `] = ` on the end so it matches
    // the DEFINITION and not a second mention of the same key in a neighbouring
    // `commandFactories` entry; the uniqueness check below makes that a claim
    // rather than an assumption (`tool.strokeExtrude` has such a neighbour —
    // the one-shot `mesh.strokeExtrude` command — which is why it is checked).
    immutable src = readText(buildPath(repoRoot, "source", "registration.d"));
    string[] problems;
    size_t   checked = 0;

    foreach (id; kG3WireIds) {
        immutable needle = "reg.toolFactories[\"" ~ id ~ "\"] = ";
        if (countOccurrences(src, needle) != 1) {
            problems ~= "    · wire id `" ~ id ~ "`: found "
                      ~ countOccurrences(src, needle).to!string
                      ~ " registration definitions, expected exactly 1";
            continue;
        }
        auto at   = src.indexOf(needle);
        auto rest = src[cast(size_t) at .. $];
        auto end  = rest.indexOf("};");
        immutable block = (end < 0) ? rest : rest[0 .. cast(size_t) end];
        ++checked;
        if (countOccurrences(block, "setGestureBindings(") != 1)
            problems ~= "    · `" ~ id ~ "` does not bind through "
                      ~ "setGestureBindings exactly once";
        if (countOccurrences(block, "setUndoBindings(") != 0)
            problems ~= "    · `" ~ id ~ "` still calls setUndoBindings — a G3 "
                      ~ "tool has no such method any more, so this would not "
                      ~ "even compile; if you are reading this, the id resolved "
                      ~ "to the wrong block";
    }

    if (checked != kG3WireIds.length)
        problems ~= "    · FLOOR: located only " ~ checked.to!string ~ " of "
                  ~ kG3WireIds.length.to!string ~ " registration blocks. The "
                  ~ "scan is reading the wrong file or the needle stopped "
                  ~ "matching — every per-id check above then passes vacuously.";
    assert(problems.length == 0,
        "G3 census: a registration left the base binder.\n" ~ joinLines(problems)
      ~ "  An unbound tool still COMPILES and still runs: `history` and "
      ~ "`gestureFactory` stay null, `commitEdit` returns at its first gate, "
      ~ "and the gesture edits the mesh with no undo entry behind it.");
}

private string joinLines(const(string)[] xs) {
    string r;
    foreach (x; xs) r ~= x ~ "\n";
    return r;
}
