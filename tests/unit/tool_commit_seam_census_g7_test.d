// tool_commit_seam_census_g7_test — the text half of the gesture-recording
// seam, for group G7, the TOPOLOGY-PEN family (task 1905, phase D).
//
// ONE FILE PER FAMILY, and that is not filing tidiness. A single tree-wide
// census would serialise the lanes behind each other, and the failure it
// invites is the silent one: two lanes each append a roster line to the same
// file, the merge keeps one, and the lost line's family is then unwatched with
// nothing red to say so. Per-family files make that collision a textual
// conflict instead of a disappearance. Members 1-6 below are lane G4's
// (`tool_commit_seam_census_g4_test.d`) member for member; what changed is the
// population, the roster, and the three places where G7 is not G4 — all three
// marked HERE G7 DIFFERS. Member 7 has no sibling at all.
//
// THE KEY MEMBER KEYS ON THE WHOLE CALL SURFACE, NOT ON A REGEX OF ONE NAME.
// Revision 2 of the plan measured these families with `history_?\.record`, and
// that predicate missed two recorders elsewhere in the tree and four legitimate
// `invalidateRedo` calls. The lesson is not "the regex was one name short"; a
// widened regex is another list the next person forgets to widen. So the census
// collects EVERY `history.<NAME>(` in the family and compares the multiset
// against a roster that carries a reason per name. A sixth history primitive
// called from this package tomorrow reddens this for free, with the name and
// the address, and no predicate edit.
//
// HERE G7 DIFFERS (1) — THE FAMILY IS A PACKAGE, NOT A DIRECTORY OF TOOLS.
// G1's family was the `create/` directory, G4's was eleven of the fifteen files
// in `edit/`. G7 is ONE tool class split across six modules
// (`source/tools/edit/topology_pen/`), and exactly one of them — `tool.d` — is
// allowed to reach the seam at all. So member 1 walks the package directory and
// there are no non-members to except: every `.d` beside them IS the family.
// `source/tool.d` joins the population for the reason G4's file gives: after
// the migration the six pen modules hold ZERO calls on the history surface, so
// a census over them alone would be satisfied by a scanner that read nothing.
//
// HERE G7 DIFFERS (2) — TWO SEAM SITES IN ONE FILE, NOT ONE PER FILE. Every
// earlier family had one record site per tool file. G7 has two, both in
// `tool.d`, and they are not interchangeable:
//
//   * `placeVertexAt` — the RAW site. Its carrier is a `MeshVertexNew`, the
//     only G7 gesture whose payload class is not `MeshSessionEdit`, so it is
//     the one that occupies the base's single `gestureFactory` slot and the one
//     that casts back and counts the null (`noteGestureCarrierMismatch`).
//   * `recordSnapshotUndo` — the SHARED TAIL, reached from THIRTEEN call sites
//     covering fourteen gestures. Its factory parameter is typed, so it needs
//     no cast; what its callers can still get wrong is WHICH factory, and that
//     is member 7's business.
//
// HERE G7 DIFFERS (3) — THE FAMILY STILL DECLARES A METHOD THAT TAKES A
// `CommandHistory`, ON PURPOSE, AND IT IS ROSTERED. Phase B could not delete
// the pen's `history_` spelling outright: the in-package white-box rig
// (`tests/unit/tools/edit/topology_pen/gestures_test.d`) names itself into this
// package precisely to reach `package` members and binds it many times over,
// and `protected` on the base does not reach a sibling module. So a one-line
// bridge setter survives. Member 4 rosters it BY NAME with that reason rather
// than making the rule "no CommandHistory parameters anywhere", which would
// have been a rule the tree cannot satisfy and would therefore have been
// relaxed by the first person to hit it.
//
// WHAT IT CANNOT SEE, said here so nobody trusts it for that: a seam that
// recorded the RIGHT carrier with the WRONG payload. That is the frozen plane
// fixture's job (`tests/fixtures/tool_gesture/g7.json`, read by
// `tests/test_tool_gesture_g7.d`, six cells). And for G7 there is a second
// blind spot the sibling families do not have: ONE wire name
// (`mesh.topoPen_build`) is bound to TWO gestures whose four plane dumps are
// BYTE-IDENTICAL — the fixture lane measured that — so neither this file nor
// any plane separates them. Only the LABEL does, and the label is passed by the
// tool at the call site, not carried by the factory.
//
// MUTATIONS, one per member, each reddening only its own — every one of them
// was run, and the verbatim message is in the task card (3250):
//   1. drop a `.d` file into `source/tools/edit/topology_pen/` -> member 1, by
//      name.
//   2. write `history.consolidate(...)` into any pen module -> member 2, as an
//      UNROSTERED name on the history surface with its file and line. This is
//      the mutation a `history_?\.record` regex would not have caught at all.
//   3. flip one site's `GestureRecordMode.Plain` to `.InSession` -> member 3,
//      with the per-file mode counts. (The plane fixture stays GREEN under this
//      one — measured by lane G0-G7 before the migration: both primitives push
//      exactly once, so no wire surface moves.)
//   4. re-declare `void setUndoBindings` in `tool.d`, or give any pen method a
//      second `CommandHistory` parameter -> member 4, by file and by name.
//   5. delete `t.setPenFactories(...)` from the registration block -> member 5.
//      It COMPILES — every parameter is defaulted — and the pen then places
//      vertices and commits NOTHING for its other fourteen gestures.
//   6. re-declare `CommandHistory history;` in `tool.d` -> member 6, by file.
//      It COMPILES TOO, silently shadowing the base field — which is the whole
//      reason phase B's deletions and the base declaration had to be one
//      commit, and it was verified under a forced rebuild rather than reasoned
//      about.
//   7. swap two adjacent factory arguments at the registration site -> member
//      7, naming BOTH positions and BOTH wire names, and nothing else.
//
// EVERY NON-VACUITY FLOOR IS INSIDE THE ACCUMULATOR, NEVER AHEAD OF IT. A floor
// written as a separate assert ABOVE the roster raise aborts the module first —
// druntime stops at the first failed assert — so it SWALLOWS the roster row it
// exists to accompany: you read "the scanner found 0 calls" and never learn
// which file moved. Folded in, the floor is one more finding in the same list,
// the module fails once, and a mutation run can be checked on the observable
// that separates the two: does it report ITS OWN row, or the floor's line?
// Every mutation above was re-run against this shape and reports its own row.
//
// LANE: `dub test --config=tests`. (The mutation drill also runs this file
// standalone — `dmd -unittest -main -run` — because it imports nothing from the
// repo and reads the tree as TEXT at run time, so its own binary is rebuilt
// from this exact source every time and the mutated files are read fresh. That
// is a convenience for the drill, never a substitute for the gate.)
module tests.unit.tool_commit_seam_census_g7_test;

import std.algorithm : sort, uniq;
import std.array     : appender, array, split;
import std.conv      : to;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.path      : baseName, buildPath, dirName;
import std.regex     : regex, matchAll, replaceAll;
import std.string    : indexOf, strip;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private enum string kPenDir = "source/tools/edit/topology_pen";

// ---------------------------------------------------------------------------
// Two strippers, and which one a member uses is load-bearing.
//
// `stripCommentsAndStrings` — for every member that COUNTS something. A doc
// comment that names `history.record(` moves the number, and this package's
// comments name it three times over; a census that reddens from a sentence
// teaches people to bump its number without looking, and a number bumped
// without looking is not a witness (plan §5.1, Б16).
//
// `stripCommentsOnly` — for members 5 and 7, which have to READ string literals
// (the wire id `"mesh.topoPen"`, and the thirteen `"mesh.topoPen_*"` names
// `app.d` builds its factories with). G4's file used the RAW source for its
// equivalent of member 5; comments-only is strictly better — same string
// literals, minus the chance that a sentence in a comment satisfies a count.
//
// Known gap, shared with `tests/unit/commit_seam_census_test.d`: wysiwyg
// strings (`r"…"`) and character literals (`'"'`) can desync the first
// stripper. None of the population contains either today, and the guard against
// a silent desync is not a promise — it is the non-vacuity floor in members 2
// and 3: a scanner that lost its place eats the rest of the file, and both
// totals collapse and redden with a message that says so.
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

private string stripCommentsOnly(string src) {
    return src.replaceAll(regex(`/\*[\s\S]*?\*/`), "")
              .replaceAll(regex(`//[^\n]*`), "");
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

private string joinLines(const(string)[] xs) {
    string r;
    foreach (x; xs) r ~= x ~ "\n";
    return r;
}

/// Every `history.<NAME>(` / `history_.<NAME>(` in `src`, as (name, line).
/// Hand-scanned rather than regex'd so the receiver term stays exactly the one
/// the plan's population is defined over. Note what it deliberately does NOT
/// match: `history = h;` (an assignment) and `history_(CommandHistory h)` (the
/// bridge setter's own declaration) — neither is a call on the surface, and the
/// pen holds both.
private struct SurfaceHit { string name; size_t line; }

private SurfaceHit[] historySurface(string src) {
    SurfaceHit[] hits;
    size_t i = 0;
    while (true) {
        auto rel = src[i .. $].indexOf("history");
        if (rel < 0) break;
        size_t p = i + cast(size_t) rel;
        i = p + 7;
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
// THE FAMILY. Six modules, one package, one tool class.
// ---------------------------------------------------------------------------
private enum string[] kG7Files = [
    "defs.d", "json.d", "package.d", "render.d", "snap_guide.d", "tool.d",
];

/// The one module of the package allowed to reach the seam.
private enum string kG7SeamFile = "tool.d";

private string[] populationPaths() {
    string[] r;
    foreach (f; kG7Files) r ~= buildPath(kPenDir, f);
    r ~= "source/tool.d";
    return r;
}

// ---------------------------------------------------------------------------
// 1. THE FILE SET IS WALKED, NOT TRUSTED.
//
//    A seventh module dropped into the pen's package is a candidate member of
//    this family whether or not anyone updates a table, and it must not join
//    the tree unnoticed by the census that owns the directory it landed in.
//    Unlike G4's directory there are no non-members to except here — the
//    directory IS the family — so a new file is always a roster edit, never a
//    classification question. The anti-duplication guard comes first: a typo in
//    the roster throws when the file is read, but a DUPLICATE is silent and
//    would leave one real member unscanned and green forever.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;

    auto sorted = kG7Files.dup;
    sorted.sort();
    if (sorted.uniq.array.length != kG7Files.length)
        problems ~= "    · the roster names only "
                  ~ sorted.uniq.array.length.to!string ~ " DISTINCT file(s) "
                  ~ "across " ~ kG7Files.length.to!string ~ " rows — a "
                  ~ "duplicate leaves one member unscanned, and its per-file "
                  ~ "checks below then pass by never running";

    string[] found;
    foreach (e; dirEntries(buildPath(repoRoot, kPenDir), "*.d", SpanMode.shallow))
        found ~= baseName(e.name);
    found.sort();

    // NON-VACUITY, and it is a ROW, not a leading assert: as its own assert it
    // would abort ahead of the accumulator and hide the file that moved.
    if (found.length < kG7Files.length)
        problems ~= "    · NON-VACUITY: the walk of `" ~ kPenDir ~ "` returned "
                  ~ "only " ~ found.length.to!string ~ " file(s), the roster "
                  ~ "holds " ~ kG7Files.length.to!string ~ ". The path is wrong "
                  ~ "or the tree moved — the rows above and below are then "
                  ~ "measuring nothing";

    foreach (f; found) {
        bool known = false;
        foreach (x; kG7Files) if (x == f) { known = true; break; }
        if (!known)
            problems ~= "    · new in `" ~ kPenDir ~ "`, not in the roster: " ~ f;
    }
    foreach (x; kG7Files) {
        bool present = false;
        foreach (f; found) if (f == x) { present = true; break; }
        if (!present)
            problems ~= "    · rostered G7 member is gone from the package: " ~ x;
    }

    assert(problems.length == 0,
        "G7 census: the topology-pen package's file set moved.\n"
      ~ joinLines(problems)
      ~ "  Every module here belongs to the one tool class this family is, and "
      ~ "every one of them is scanned by the members below. Add the new file to "
      ~ "`kG7Files`. Do not delete the row that reddened.");
}

// ---------------------------------------------------------------------------
// 2. THE HISTORY CALL SURFACE OF THE FAMILY, name by name, file by file.
//
//    After phase D every recorder in this family lives in ONE place — the seam
//    on `Tool` — and NOTHING is left inside the six pen modules. G7 holds no
//    legitimate non-recorder to except (contrast G1's `box.d`, which
//    legitimately keeps `nextRun` and `undo`, and G5's four `invalidateRedo`):
//    its roster for the package is an exact, checked ZERO.
// ---------------------------------------------------------------------------
private struct RosterRow { string path; string name; size_t count; string why; }

private enum RosterRow[] kSurfaceRoster = [
    // The seam itself. THREE primitives, one per `GestureRecordMode` member,
    // plus the belt's run-close. This is the whole reason `source/tool.d` is in
    // the population: it is the family's only surviving recorder, and the only
    // thing keeping this member's scan non-vacuous.
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

    foreach (rel; populationPaths()) {
        immutable full = buildPath(repoRoot, rel);
        if (!exists(full)) {
            problems ~= "    · population member is missing from the tree: " ~ rel;
            continue;
        }
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
                          ~ "  — after phase D every record in this family goes "
                          ~ "through `Tool.recordGestureEdit`, and no module of "
                          ~ "the topology-pen package has a legitimate reason to "
                          ~ "reach `CommandHistory` at all. If this call really "
                          ~ "is legitimate, add a roster row with the reason; do "
                          ~ "not widen a regex.";
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

    // NON-VACUITY, load-bearing exactly as it is for G4: the six pen modules
    // contribute ZERO hits by design, so without `source/tool.d` in the
    // population this member would be satisfied by a stripper that lost its
    // place, a `repoRoot` pointing nowhere, or a scan of an empty list. A
    // FLOOR, not an equality: an EXTRA call is caught above with its name and
    // its address, which is the message worth reading. IN the accumulator, not
    // ahead of it.
    if (totalHits < 4)
        problems ~= "    · NON-VACUITY: the scan found " ~ totalHits.to!string
                  ~ " call(s) on the history surface across the whole "
                  ~ "population, and the seam alone makes four. The scanner "
                  ~ "read nothing — check `repoRoot` and the stripper before "
                  ~ "believing any row above";

    assert(problems.length == 0,
        "G7 census: the family's history call surface is not what the seam "
      ~ "leaves behind.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 3. THE SEAM'S CALL SITES, per file and PER MODE.
//
//    TWO sites, both in `tool.d`, both `Plain`. The count is the fact worth
//    pinning as much as the mode is: a THIRD site in this package would be a
//    gesture recording outside the two the frozen fixture is an oracle for, and
//    a site that vanished would be a gesture that silently stopped recording.
//
//    The mode zero is what makes plan §5.5's discriminating mutation M2
//    (suppress only the `ReplaceRunTail` dispatch, expect exactly one cell to
//    redden, in group G1) INAPPLICABLE here: this family has no site on that
//    branch, so M2 over G7 predicts six greens — not because there is no
//    witness, but because there is no site. The moment `ReplaceRunTail` or
//    `InSession` appears below, that reasoning stops holding and this member
//    says so first.
// ---------------------------------------------------------------------------
private struct CallRow { string path; size_t calls, plain, inSession, replaceTail; }

private enum CallRow[] kCallRoster = [
    // The seam: one declaration, one dispatch arm per mode — plus a SECOND
    // mention of `ReplaceRunTail`, the belt's `mode ==` test in
    // `refuseGestureRecord`. That second one is counted, not tolerated: if it
    // disappears the belt has stopped closing the run it skipped.
    CallRow("source/tool.d",                                    1, 1, 1, 2),
    CallRow("source/tools/edit/topology_pen/tool.d",             2, 2, 0, 0),
    CallRow("source/tools/edit/topology_pen/defs.d",             0, 0, 0, 0),
    CallRow("source/tools/edit/topology_pen/json.d",             0, 0, 0, 0),
    CallRow("source/tools/edit/topology_pen/package.d",          0, 0, 0, 0),
    CallRow("source/tools/edit/topology_pen/render.d",           0, 0, 0, 0),
    CallRow("source/tools/edit/topology_pen/snap_guide.d",       0, 0, 0, 0),
];

unittest {
    string[] problems;
    size_t   totalCalls = 0;

    foreach (rel; populationPaths()) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t calls  = countOccurrences(src, "recordGestureEdit(");
        immutable size_t plain  = countOccurrences(src, "GestureRecordMode.Plain");
        immutable size_t sess   = countOccurrences(src, "GestureRecordMode.InSession");
        immutable size_t tail   = countOccurrences(src, "GestureRecordMode.ReplaceRunTail");
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
            problems ~= "    · " ~ rel ~ " is in the population and not in the "
                      ~ "call roster (" ~ calls.to!string ~ " call(s)) — every "
                      ~ "member of this family is named here, with its number";
            continue;
        }
        if (calls != wantC)
            problems ~= "    · " ~ rel ~ ": recordGestureEdit( x " ~ calls.to!string
                      ~ ", roster says " ~ wantC.to!string
                      ~ ". G7 holds exactly two seam sites, BOTH in `"
                      ~ kG7SeamFile ~ "` (`placeVertexAt` raw on a "
                      ~ "`MeshVertexNew`, `recordSnapshotUndo` the tail thirteen "
                      ~ "gesture commits funnel through)";
        if (plain != wantP || sess != wantS || tail != wantT)
            problems ~= "    · " ~ rel ~ ": modes {Plain " ~ plain.to!string
                      ~ ", InSession " ~ sess.to!string ~ ", ReplaceRunTail "
                      ~ tail.to!string ~ "}, roster says {Plain " ~ wantP.to!string
                      ~ ", InSession " ~ wantS.to!string ~ ", ReplaceRunTail "
                      ~ wantT.to!string ~ "}";
    }

    if (totalCalls < 3)
        problems ~= "    · NON-VACUITY: only " ~ totalCalls.to!string
                  ~ " `recordGestureEdit(` in the whole population. Two pen "
                  ~ "sites plus the seam's own declaration are expected; a "
                  ~ "number near zero means the scanner read nothing, not that "
                  ~ "the family stopped recording";

    assert(problems.length == 0,
        "G7 census: the seam's call sites moved.\n" ~ joinLines(problems)
      ~ "\n  This family is `Plain` at both of its sites. A site that moves to "
      ~ "`InSession` or `ReplaceRunTail` leaves the history run OPEN, and "
      ~ "NOTHING on the wire says so — not the stack depth, not the committed "
      ~ "names, not the labels, not one plane of the frozen fixture (measured by "
      ~ "lane G0-G7 under exactly that mutation: `Total: 1 Passed: 1`). This "
      ~ "line is the only witness.");
}

// ---------------------------------------------------------------------------
// 4. THE FAMILY BINDS THROUGH THE BASE, and declares no binder of its own.
//
//    `void setUndoBindings(CommandHistory h, VertexNewFactory f, <13 more>)` is
//    gone; history and the raw site's carrier come from
//    `Tool.setGestureBindings`, and the thirteen typed factories from
//    `setPenFactories`, which takes no `CommandHistory` and therefore cannot be
//    the second place someone forgets to bind one.
//
//    THE `CommandHistory`-PARAMETER ROSTER, and why it is a roster rather than
//    a zero. One survivor is legitimate and named: the phase-B bridge setter
//    `package void history_(CommandHistory h)`, which exists because the
//    in-package white-box rig reaches `package` members that `protected` on the
//    base does not reach. A rule of "no such parameter anywhere" would be a rule
//    the tree cannot satisfy, and a rule the tree cannot satisfy gets relaxed
//    rather than obeyed. So: exactly this one, by file and by name.
//
//    AND THE ROSTER CARRIES A COUNT, not just a name. The first draft of this
//    member keyed on (file, parameter name) alone, and the C4 mutation caught
//    it: a re-declared `void setUndoBindings(CommandHistory h)` in `tool.d`
//    names its parameter `h` too, so it MATCHED the rostered survivor and the
//    parameter half stayed quiet — the whole finding came from the
//    `setUndoBindings` name check beside it, which a binder called anything
//    else would have walked straight past. With the count, a SECOND
//    `CommandHistory` parameter in a rostered file is a row of its own whatever
//    the method or the parameter is called.
// ---------------------------------------------------------------------------
private struct ParamRow { string file; string name; size_t count; string why; }

private enum ParamRow[] kHistoryParamRoster = [
    ParamRow("tool.d", "h", 1,
        "the phase-B bridge setter `package void history_(CommandHistory h)` — "
      ~ "the pen's former field spelling, kept reachable for the in-package "
      ~ "white-box rig (tests/unit/tools/edit/topology_pen/gestures_test.d), "
      ~ "which `protected` on the base does not reach. A SETTER, never a second "
      ~ "field: there is one storage location, on `Tool`"),
];

/// Every `CommandHistory <ident>` sitting in a PARAMETER position in `src`,
/// as (name, line): the token must be preceded by `(` or `,` and the identifier
/// after it followed by `)`, `,` or `=`. A field declaration
/// (`CommandHistory history;`) is member 6's business and is deliberately not
/// matched here.
private SurfaceHit[] historyTypedParams(string src) {
    SurfaceHit[] hits;
    enum tok = "CommandHistory";
    size_t i = 0;
    while (true) {
        auto rel = src[i .. $].indexOf(tok);
        if (rel < 0) break;
        size_t p = i + cast(size_t) rel;
        i = p + tok.length;
        if (p > 0 && isIdentChar(src[p - 1])) continue;
        // preceding non-space must open or continue a parameter list
        ptrdiff_t b = cast(ptrdiff_t) p - 1;
        while (b >= 0 && (src[b] == ' ' || src[b] == '\t' || src[b] == '\n')) --b;
        if (b < 0 || (src[b] != '(' && src[b] != ',')) continue;
        size_t q = p + tok.length;
        while (q < src.length && (src[q] == ' ' || src[q] == '\t' || src[q] == '\n')) ++q;
        size_t nameStart = q;
        while (q < src.length && isIdentChar(src[q])) ++q;
        if (q == nameStart) continue;
        string nm = src[nameStart .. q];
        while (q < src.length && (src[q] == ' ' || src[q] == '\t' || src[q] == '\n')) ++q;
        if (q >= src.length) continue;
        if (src[q] != ')' && src[q] != ',' && src[q] != '=') continue;
        hits ~= SurfaceHit(nm, lineOf(src, p));
    }
    return hits;
}

unittest {
    string[] problems;
    size_t seamDecls  = 0;
    size_t seenParams = 0;
    size_t[string] paramCount;   // "<file>:<paramName>" -> how many
    string[string] paramWhere;   // the same key -> "<rel>:<line>" of the first

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
        if (rel == "source/tool.d") continue;

        immutable string f = baseName(rel);
        foreach (h; historyTypedParams(src)) {
            ++seenParams;
            immutable string key = f ~ ":" ~ h.name;
            ++paramCount[key];
            if (key !in paramWhere) paramWhere[key] = rel ~ ":" ~ h.line.to!string;
        }
    }

    // Anything the roster does not name at all.
    foreach (key, n; paramCount) {
        bool rostered = false;
        foreach (row; kHistoryParamRoster)
            if (row.file ~ ":" ~ row.name == key) { rostered = true; break; }
        if (!rostered)
            problems ~= "    · UNROSTERED `CommandHistory` parameter `" ~ key
                      ~ "` x " ~ n.to!string ~ ", first at " ~ paramWhere[key]
                      ~ "  — a pen method that takes a history can bind one, and "
                      ~ "a tool that can bind its own history is the second place "
                      ~ "to forget that `Tool.setGestureBindings` exists to "
                      ~ "remove. If it is legitimate, add a roster row with the "
                      ~ "reason.";
    }
    // And every rostered survivor with its EXACT count. This row is also the
    // member's non-vacuity floor for the parameter half: a scanner that read
    // nothing drives every count to zero and reports it here, in the same
    // accumulator as everything else, rather than aborting ahead of it.
    size_t wantParams = 0;
    foreach (row; kHistoryParamRoster) {
        wantParams += row.count;
        immutable string key = row.file ~ ":" ~ row.name;
        immutable size_t n = (key in paramCount) ? paramCount[key] : 0;
        if (n != row.count)
            problems ~= "    · `CommandHistory " ~ row.name ~ "` in " ~ row.file
                      ~ ": " ~ n.to!string ~ " parameter(s), roster says "
                      ~ row.count.to!string ~ "  (" ~ row.why ~ ")";
    }

    if (seamDecls != 1)
        problems ~= "    · `void setGestureBindings` is declared "
                  ~ seamDecls.to!string ~ " time(s) in the population; exactly "
                  ~ "one, on `Tool`, is the point of it — and a zero here means "
                  ~ "the scan read nothing, so the per-file rows above are "
                  ~ "vacuous too";
    if (seenParams < wantParams)
        problems ~= "    · NON-VACUITY: the scan found " ~ seenParams.to!string
                  ~ " `CommandHistory` parameter(s) across the six pen modules; "
                  ~ "the roster alone expects " ~ wantParams.to!string
                  ~ ". The parameter scanner read nothing, so the unrostered "
                  ~ "rows above are vacuous";

    assert(problems.length == 0,
        "G7 census: binding declarations moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 5. THE `mesh.topoPen` REGISTRATION CALLS BOTH BINDERS, EACH EXACTLY ONCE.
//
//    Scoped to the one wire id this group owns, deliberately: a count over the
//    whole of `registration.d` would be a number every later family has to
//    bump, i.e. a lane serialiser.
//
//    TWO calls where every sibling family has one, and the second is the one
//    that can go missing quietly. Every parameter of `setPenFactories` is
//    DEFAULTED (they have been since P3, so that direct-construction rigs can
//    bind one at a time), so deleting the whole call COMPILES: the pen would
//    still place vertices through the base binding and commit nothing at all
//    for its other fourteen gestures.
// ---------------------------------------------------------------------------
unittest {
    // Comments stripped, string literals KEPT: the wire id is a string literal,
    // and the block's own comments name both binders in prose.
    immutable src = stripCommentsOnly(
        readText(buildPath(repoRoot, "source", "registration.d")));
    string[] problems;
    size_t   checked = 0;

    immutable needle = "reg.toolFactories[\"mesh.topoPen\"] = ";
    immutable size_t defs = countOccurrences(src, needle);
    if (defs != 1) {
        problems ~= "    · wire id `mesh.topoPen`: found " ~ defs.to!string
                  ~ " registration definitions, expected exactly 1";
    } else {
        auto at   = src.indexOf(needle);
        auto rest = src[cast(size_t) at .. $];
        auto end  = rest.indexOf("};");
        immutable block = (end < 0) ? rest : rest[0 .. cast(size_t) end];
        ++checked;

        if (countOccurrences(block, "setGestureBindings(") != 1)
            problems ~= "    · `mesh.topoPen` does not bind through "
                      ~ "setGestureBindings exactly once. An unbound tool is "
                      ~ "SILENT: `recordGestureEdit` sees a null history and "
                      ~ "returns false, the mesh stays edited, and no undo entry "
                      ~ "is written";
        if (countOccurrences(block, "setPenFactories(") != 1)
            problems ~= "    · `mesh.topoPen` does not call setPenFactories "
                      ~ "exactly once. Every one of its thirteen parameters is "
                      ~ "defaulted, so a missing call COMPILES — and then the "
                      ~ "pen places vertices (that path is bound by the base) "
                      ~ "and silently commits NOTHING for the other fourteen "
                      ~ "gestures, because `commitReady` refuses on a null "
                      ~ "factory before touching the mesh";
        if (countOccurrences(block, "setUndoBindings(") != 0)
            problems ~= "    · `mesh.topoPen` still calls setUndoBindings — the "
                      ~ "pen has no such method any more, so this would not even "
                      ~ "compile; if you are reading this, the id resolved to the "
                      ~ "wrong block";
    }

    if (checked != 1)
        problems ~= "    · NON-VACUITY: located " ~ checked.to!string
                  ~ " registration block(s), expected 1. The scan is reading the "
                  ~ "wrong file — every row above then passes by never running";

    assert(problems.length == 0,
        "G7 census: a registration left a binder.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 6. NO PEN MODULE DECLARES ITS OWN HISTORY FIELD.
//
//    D silently SHADOWS a base field with a same-named derived one, so a tool
//    that declares `CommandHistory history;` keeps compiling — verified under a
//    forced rebuild, with no compiler diagnostic at all — reads its own
//    never-bound copy, and records into null: an edit with no undo entry and
//    nothing red anywhere. Phase B measured that; this is the family-scoped
//    guard against it coming back here.
//
//    The TREE-WIDE zero is `tool_commit_seam_census_g1_test.d`'s member 6, and
//    it is deliberately not duplicated: a second tree-wide walk in each family
//    file is N numbers to keep in step for one fact. This member is narrow on
//    purpose — it names the SIX, so its message points at a pen module and its
//    line, which the tree-wide one does not.
// ---------------------------------------------------------------------------
unittest {
    string[] offenders;
    size_t   moduleDecls = 0;

    foreach (f; kG7Files) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, kPenDir, f)));
        moduleDecls += countOccurrences(src, "module tools.edit.topology_pen");
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
    // visited would be a tautology over the roster it iterates. Nor can it be
    // the `CommandHistory` token — five of the six modules do not mention it at
    // all, so a zero there proves nothing. What proves the scanner read real
    // text is a token every module of a package necessarily carries: its own
    // `module tools.edit.topology_pen…` declaration. It is code, so the
    // stripper keeps it; the field predicate correctly does not match it; and a
    // stripper that lost its place, or a `repoRoot` pointing nowhere, drives
    // this to zero.
    if (moduleDecls < kG7Files.length)
        offenders ~= "    · NON-VACUITY: the token `module tools.edit.topology_pen` "
                   ~ "appears " ~ moduleDecls.to!string ~ " time(s) across the "
                   ~ kG7Files.length.to!string ~ " rostered file(s); one per file "
                   ~ "is expected. The scan read nothing, so a zero above is not "
                   ~ "evidence of anything";

    assert(offenders.length == 0,
        "G7 census: a topology-pen module declares its own CommandHistory field "
      ~ "again.\n" ~ joinLines(offenders) ~ "\n"
      ~ "  `Tool.history` is `protected` and bound by `setGestureBindings`. A "
      ~ "same-named field in a subclass SHADOWS it silently in D: the tool "
      ~ "compiles, reads its own never-bound copy, and records into null. Phase "
      ~ "B deleted thirty-two of these in ONE commit precisely so that no "
      ~ "half-migrated state could exist; this number does not go up. The pen's "
      ~ "own former spelling survives as a SETTER (`package void "
      ~ "history_(CommandHistory h)`), which is member 4's row, not a field.");
}

// ---------------------------------------------------------------------------
// 7. THE POSITIONAL BINDING. NO SIBLING FAMILY HAS THIS MEMBER.
//
//    `TopologyPenTool.setPenFactories` takes the family's THIRTEEN
//    `MeshSessionEdit delegate()` factories as thirteen structurally IDENTICAL
//    defaulted parameters, and `source/registration.d` passes them BY POSITION.
//    The declaration's own comment says what that costs: a mis-ordered argument
//    "would compile and silently label one op as another". The blast radius is
//    not hypothetical — three of the thirteen (`remove`, `removeEdge`,
//    `removeVertex`) differ ONLY in the wire name they were built with, and one
//    factory (`build`) is bound to TWO gestures.
//
//    The frozen fixture reaches only the four factories it drives (`build`,
//    `move`, `remove`, `dupLoop`). This member closes the other nine by
//    composing the chain the compiler cannot see:
//
//        registration argument position  ->  setPenFactories parameter name
//                                        ->  `factories_.<field>` assignment
//                                        ->  the wire name `source/app.d` built
//                                            that factory identifier with
//
//    and pinning all thirteen triples. A swap of two arguments at the
//    registration site re-pairs two fields with two identifiers and reddens
//    naming both, and nothing else.
//
//    WHERE IT CAME FROM, AND WHY IT MOVED. Lane G0-G7 (task 2870) shipped this
//    as Block 3 of `tests/unit/tool_gesture_runopen_g7_test.d`, whose header
//    called Blocks 1 and 3 "independent" of this census. Phase D moved it: the
//    binder it parses is the one this phase reshaped, and two files carrying
//    two rosters over ONE binding surface is exactly the merge hazard that made
//    the census per-family in the first place. Block 2 of that file (the
//    record-primitive census) is superseded by members 2 and 3 here — its own
//    header said it would be — and Block 1, the live `CommandHistory` positive
//    control, is behavioural and stays where it is.
//
//    WHAT IT DELIBERATELY DOES NOT CLAIM. The factory carries the WIRE NAME
//    (`MeshSessionEdit.name()` returns `wireName_` verbatim); it does NOT carry
//    the label that reaches the history. `setSnapshots(before, after, label)`
//    overrides the constructor's default label, and the pen passes its own label
//    at every one of the thirteen call sites — which is why the Shift+LMB
//    duplicate-edge gesture records under `mesh.topoPen_build` with the label
//    "Topology Duplicate Edge". So a factory swap moves `entryNames` and leaves
//    `entryLabels` GREEN (measured by lane G0-G7, not deduced), and the roster
//    below pins the wire name only.
// ---------------------------------------------------------------------------

/// One row of the composed chain.
private struct Bind {
    string field;   // the `factories_.<field>` the parameter is assigned to
    string ident;   // the `source/app.d` factory identifier registration passes
    string wire;    // the wire name app.d built that identifier with
}

/// The FROZEN roster, position by position, as `source/registration.d` passes
/// them today. Thirteen rows; `build` is the one bound to two gestures, and
/// `remove` / `removeEdge` / `removeVertex` are the three that differ ONLY by
/// wire name — the pairs a mis-ordered argument would silently exchange.
private enum Bind[] kFrozenBinds = [
    Bind("build",        "topoPenBuildEditFactory",        "mesh.topoPen_build"),
    Bind("move",         "topoPenMoveEditFactory",         "mesh.topoPen_move"),
    Bind("remove",       "topoPenRemoveEditFactory",       "mesh.topoPen_remove"),
    Bind("addLoop",      "topoPenAddLoopEditFactory",      "mesh.topoPen_addloop"),
    Bind("slide",        "topoPenSlideEditFactory",        "mesh.topoPen_slide"),
    Bind("smooth",       "topoPenSmoothEditFactory",       "mesh.topoPen_smooth"),
    Bind("split",        "topoPenSplitEditFactory",        "mesh.topoPen_split"),
    Bind("moveLoop",     "topoPenMoveLoopEditFactory",     "mesh.topoPen_moveloop"),
    Bind("dupLoop",      "topoPenDupLoopEditFactory",      "mesh.topoPen_duploop"),
    Bind("smoothLoop",   "topoPenSmoothLoopEditFactory",   "mesh.topoPen_smoothloop"),
    Bind("fill",         "topoPenFillEditFactory",         "mesh.topoPen_fill"),
    Bind("removeEdge",   "topoPenRemoveEdgeEditFactory",   "mesh.topoPen_removeedge"),
    Bind("removeVertex", "topoPenRemoveVertexEditFactory", "mesh.topoPen_removevertex"),
];

private enum string kBinderDecl = "void setPenFactories(";

/// The substring of `src` starting at `open` (which must index an opening
/// bracket) and ending at its match, brackets included. Counting rather than a
/// regex because the registration block and the parameter list both nest.
private string balanced(string src, size_t open, char lo, char hi) {
    int depth = 0;
    foreach (i; open .. src.length) {
        if (src[i] == lo) ++depth;
        else if (src[i] == hi) {
            --depth;
            if (depth == 0) return src[open .. i + 1];
        }
    }
    assert(false, "unbalanced '" ~ lo ~ "' at " ~ open.to!string
                ~ " — the parse below would silently read the rest of the file");
}

/// Parameter names of `setPenFactories`, in declaration order. Phase D removed
/// the two non-factory leaders (`h`, `f`) the former `setUndoBindings` had, so
/// there is nothing to skip any more — but the position NUMBERING is unchanged,
/// because it always numbered the factory list, which started at `bf` either
/// way.
private string[] factoryParams(string toolSrc) {
    immutable ptrdiff_t at = toolSrc.indexOf(kBinderDecl);
    assert(at >= 0,
        "G7 census (member 7): `" ~ kBinderDecl ~ "` not found in the pen's "
      ~ "tool.d. The declaration was renamed or reformatted; fix this parse "
      ~ "deliberately rather than letting the roster below compare against an "
      ~ "empty list");
    immutable size_t open = cast(size_t) at + kBinderDecl.length - 1;
    auto list = balanced(toolSrc, open, '(', ')');
    string[] names;
    foreach (p; list[1 .. $ - 1].split(",")) {
        auto lhs = p.split("=")[0].strip();
        auto tok = lhs.split();
        assert(tok.length >= 2,
            "G7 census (member 7): parameter `" ~ p.strip()
          ~ "` has no type+name pair — the parse is not reading a parameter list");
        names ~= tok[$ - 1].strip();
    }
    return names;
}

unittest {
    immutable toolSrc = stripCommentsOnly(
        readText(buildPath(repoRoot, kPenDir, "tool.d")));
    immutable regSrc  = stripCommentsOnly(
        readText(buildPath(repoRoot, "source", "registration.d")));
    immutable appSrc  = stripCommentsOnly(
        readText(buildPath(repoRoot, "source", "app.d")));

    string[] bad;

    // (i) parameter name -> `factories_.<field>`, read out of the body.
    auto params = factoryParams(toolSrc);
    string[string] paramToField;
    {
        immutable ptrdiff_t at = toolSrc.indexOf(kBinderDecl);
        immutable size_t po = cast(size_t) at + kBinderDecl.length - 1;
        auto plist = balanced(toolSrc, po, '(', ')');
        immutable size_t bo = po + plist.length;
        immutable ptrdiff_t brace = toolSrc[bo .. $].indexOf("{");
        assert(brace >= 0, "G7 census (member 7): no body after "
                         ~ kBinderDecl ~ "...)");
        auto body_ = balanced(toolSrc, bo + cast(size_t) brace, '{', '}');
        foreach (mt; body_.matchAll(regex(`factories_\.(\w+)\s*=\s*(\w+)\s*;`)))
            paramToField[mt[2]] = mt[1];
    }

    // (ii) `source/app.d` factory identifier -> the wire name it was built with.
    string[string] identToWire;
    foreach (mt; appSrc.matchAll(regex(
            `auto\s+(topoPen\w*EditFactory)\s*=\s*\(\)\s*=>\s*new\s+MeshSessionEdit\([^;]*?"([^"]+)"\s*,`)))
        identToWire[mt[1]] = mt[2];

    // (iii) the registration call's argument identifiers, IN ORDER. The base
    // binder's own arguments (`history`, and a `() => new MeshVertexNew(...)`
    // lambda) carry no `topoPen…EditFactory` token, so the scan of the block
    // still yields exactly the thirteen and in the order they are passed.
    string[] idents;
    {
        immutable string key = `reg.toolFactories["mesh.topoPen"] = () {`;
        immutable ptrdiff_t at = regSrc.indexOf(key);
        assert(at >= 0,
            "G7 census (member 7): the `mesh.topoPen` registration block was not "
          ~ "found in source/registration.d. Every row below would then compare "
          ~ "an empty list against the frozen roster — fix the parse, do not "
          ~ "relax it");
        immutable size_t bo = cast(size_t) at + key.length - 1;
        auto block = balanced(regSrc, bo, '{', '}');
        foreach (mt; block.matchAll(regex(`topoPen\w*EditFactory`)))
            idents ~= mt.hit;
    }

    // Compose, then compare position by position.
    Bind[] fresh;
    foreach (i, ident; idents) {
        string field = "<no parameter at this position>";
        if (i < params.length) {
            auto pf = params[i] in paramToField;
            field = (pf is null)
                  ? "<param " ~ params[i] ~ " assigned to no field>" : *pf;
        }
        auto pw = ident in identToWire;
        immutable string wire = (pw is null)
            ? "<no `auto " ~ ident ~ " = () => new MeshSessionEdit(...)` in "
            ~ "source/app.d>" : *pw;
        fresh ~= Bind(field, ident, wire);
    }

    if (params.length != kFrozenBinds.length)
        bad ~= "    · setPenFactories takes " ~ params.length.to!string
             ~ " factory parameter(s), the roster holds "
             ~ kFrozenBinds.length.to!string ~ ". A factory added or removed "
             ~ "re-numbers every position after it, which is exactly the silent "
             ~ "mis-labelling the declaration's own comment warns about";
    if (idents.length != kFrozenBinds.length)
        bad ~= "    · the `mesh.topoPen` registration passes "
             ~ idents.length.to!string
             ~ " factory argument(s), the roster holds "
             ~ kFrozenBinds.length.to!string;

    immutable size_t n = fresh.length < kFrozenBinds.length
                       ? fresh.length : kFrozenBinds.length;
    foreach (i; 0 .. n) {
        if (fresh[i] == kFrozenBinds[i]) continue;
        bad ~= "    · position " ~ i.to!string ~ ": frozen "
             ~ kFrozenBinds[i].field ~ " <- " ~ kFrozenBinds[i].ident
             ~ " (" ~ kFrozenBinds[i].wire ~ "), fresh "
             ~ fresh[i].field ~ " <- " ~ fresh[i].ident
             ~ " (" ~ fresh[i].wire ~ "). The thirteen factories are "
             ~ "structurally identical delegates passed BY POSITION, so this "
             ~ "compiles and silently labels one gesture's undo entry with "
             ~ "another gesture's wire name — in the history and in a replay. "
             ~ "If the re-order is deliberate, re-freeze this roster and "
             ~ "re-freeze `tests/fixtures/tool_gesture/g7.json`, whose "
             ~ "`entryNames` are the behavioural half of this same claim";
    }

    // ANTI-VACUITY, and it is not decoration. Everything above is "the parsed
    // list equals the frozen one" — which a parse that returned the roster by
    // accident, or a comparison that cannot see a difference, satisfies for
    // free. So swap two adjacent rows of the FRESH list in a copy and require
    // the comparison to notice, and require the parsed maps to be non-empty.
    //
    // ALL THREE ARE ROWS OF THE SAME ACCUMULATOR, and that is a correction to
    // the shape lane G0-G7 shipped: there they sat between the accumulation and
    // the raise, as bare asserts, so a control failure aborted the module and
    // swallowed every position row it was supposed to accompany. Folded in,
    // they cost nothing under the mutation this member exists for (a swapped
    // argument moves neither map) and they no longer hide it.
    if (paramToField.length != kFrozenBinds.length)
        bad ~= "    · CONTROL: the body of `setPenFactories` yielded "
             ~ paramToField.length.to!string ~ " `factories_.X = param;` "
             ~ "assignment(s), expected " ~ kFrozenBinds.length.to!string
             ~ ". With fewer, the `field` column above is a placeholder string "
             ~ "and the roster compares placeholders to placeholders";
    if (identToWire.length < kFrozenBinds.length)
        bad ~= "    · CONTROL: source/app.d yielded " ~ identToWire.length.to!string
             ~ " topoPen factory->wire-name pair(s), expected at least "
             ~ kFrozenBinds.length.to!string ~ " — the `wire` column would "
             ~ "otherwise be a constant placeholder on every row";
    if (fresh.length >= 2) {
        auto probe = fresh.dup;
        auto t = probe[0]; probe[0] = probe[1]; probe[1] = t;
        if (probe[0] == kFrozenBinds[0] && probe[1] == kFrozenBinds[1])
            bad ~= "    · CONTROL: swapping the first two parsed bindings "
                 ~ "produced a list the roster still accepts. `Bind`'s "
                 ~ "comparison cannot see an argument swap, so every row above "
                 ~ "is green under the mutation this member exists for";
    } else {
        bad ~= "    · CONTROL: fewer than two bindings were parsed, so the swap "
             ~ "probe never ran and the comparison is unproven";
    }

    assert(bad.length == 0,
        "G7 positional-binding census: " ~ bad.length.to!string
      ~ " finding(s) over source/registration.d -> "
      ~ kPenDir ~ "/tool.d -> source/app.d:\n" ~ joinLines(bad));
}
