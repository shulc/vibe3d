// tool_commit_seam_census_g2_test — the text half of the gesture-recording
// seam, for group G2, the alignment family (task 1905, phase C).
//
// ONE FILE PER FAMILY, for the reason phase B's G1 file states and this lane
// re-confirms from the other side: G2, G3, G4 and G5 migrate in PARALLEL
// worktrees. A single tree-wide census would serialise them, and the failure it
// invites is silent — two lanes each append a roster line to the same file, the
// merge keeps one, and the lost line's family is unwatched with nothing red to
// say so. Per-family files turn that into a textual conflict instead of a
// disappearance.
//
// THE KEY MEMBER KEYS ON THE WHOLE CALL SURFACE, NOT ON A REGEX OF ONE NAME.
// The census this file supersedes (`tool_gesture_runopen_g2_test.d`, block 2)
// keyed on `history_?\s*\.\s*(\w+)\s*\(` and was right to; the lesson from
// round 3 of the plan is that a regex over ONE name is a list the next person
// forgets to widen (revision 2's `history_?\.record` missed both of `box.d`'s
// other two primitives and all four of the slice family's `invalidateRedo`).
// So this file collects EVERY `history.<NAME>(` in the population and compares
// the multiset against a roster carrying a reason per name. A sixth history
// primitive called from an alignment tool tomorrow is red for free, with the
// name and the address, and no predicate edit.
//
// WHAT IT CANNOT SEE, said here so nobody trusts it for that: a seam that
// recorded the RIGHT carrier with the WRONG payload, and anything about the
// PREVIEW half of a gesture. Both are the frozen plane fixture's job
// (`tests/fixtures/tool_gesture/g2.json`, read by
// `tests/test_tool_gesture_g2.d`) — and for two of these five tools the preview
// is invisible to the change bus entirely, which is why that fixture's witness
// is a two-span band over drag AND drop rather than a counter zero. Nothing
// here substitutes for it.
//
// THE POPULATION IS THE DIRECTORY `source/tools/alignment/` PLUS `source/tool.d`.
//
//   * the DIRECTORY, walked and not enumerated, because G2 IS a directory —
//     five record sites and three files that hold none. A record site that
//     MOVES to a neighbouring file in the same directory is then red with the
//     file named, instead of slipping out of a hand-written list. (This is the
//     G0-G2 lane's D-G0G2-4, kept.)
//   * `source/tool.d`, because `class Tool` lives OUTSIDE `source/tools/**`.
//     A census keyed only on the tools directory reads "0 recorders" after the
//     migration and never looks at the one surviving recorder in the family —
//     the seam itself. That is a check that cannot come out differently, and
//     round 4 of the plan caught it as its first blocking fix.
//
// MUTATIONS, one per member, each reddening only its own (all six were run on
// this lane's tree; the card carries the verbatim messages):
//   1. drop a `.d` file into `source/tools/alignment/` -> member 1, by name.
//   2. write `history.consolidate(...)` into any G2 tool -> member 2, as
//      "UNROSTERED call on the history surface".
//   3. change a roster count on `source/tool.d` -> member 2, with both numbers.
//   4. `GestureRecordMode.Plain` -> `.InSession` at one site -> member 3, with
//      the per-file mode triple. (This is plan §5.4's `runOpen` row in its
//      post-seam spelling: the fixture cannot see the swap, and after the
//      migration neither can a `history.record(` count, because there is none
//      left to count.)
//   5. delete `t.setGestureBindings(...)` from one registration block (it
//      COMPILES — the tool is simply never bound) -> member 5, by wire id.
//   6. re-declare `CommandHistory history;` in a G2 tool (it COMPILES — D
//      shadows the base field silently) -> member 6, by file.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_commit_seam_census_g2_test;

import std.algorithm : sort;
import std.array     : appender;
import std.conv      : to;
import std.file      : dirEntries, exists, isDir, isFile, readText, SpanMode;
import std.path      : baseName, buildPath, dirName, extension;
import std.string    : indexOf;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The directory G2 IS.
private enum string kG2Dir = "source/tools/alignment";

/// The seam's own module — outside `source/tools/**`, and the whole reason
/// this census can still see a recorder at all after the migration.
private enum string kSeamFile = "source/tool.d";

// ---------------------------------------------------------------------------
// The stripper, because the count is the whole point. A doc comment that names
// `history.record(` moves the number, and this file's job is to notice a real
// recorder, not a sentence about one (plan §5.1, Б16: a census that reddens on
// a rename inside a comment teaches people to bump its number without looking,
// and a number bumped without looking is not a witness).
//
// Copied from `tests/unit/tool_commit_seam_census_g1_test.d`, with the same
// known gap: wysiwyg strings (`r"…"`) and character literals (`'"'`) can desync
// it. Neither appears in the population today, and the guard against a silent
// desync is not a promise — it is the non-vacuity floor in member 2: a scanner
// that lost its place eats the rest of the file, the seam's own four calls
// vanish, and the floor reddens saying so.
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

private string joinLines(const(string)[] xs) {
    string r;
    foreach (x; xs) r ~= x ~ "\n";
    return r;
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
        if (p > 0 && isIdentChar(src[p - 1])) continue;   // whole identifier only
        size_t q = p + 7;
        if (q < src.length && src[q] == '_') ++q;         // `history_`
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
        if (r >= src.length || src[r] != '(') continue;   // a read, not a call
        hits ~= SurfaceHit(nm, lineOf(src, p));
    }
    return hits;
}

// ---------------------------------------------------------------------------
// THE FAMILY ROSTER. Five record sites, three files that hold no history call
// at all — and the three are NAMED with their reason rather than skipped,
// because two of them are the transform zone's and their ZERO is the thing
// being pinned.
// ---------------------------------------------------------------------------
private enum string[] kRecorderFiles = [
    "array_tool.d", "clone_tool.d", "mirror.d",
    "radial_array_tool.d", "radial_sweep_tool.d",
];

private enum string[2][] kSilentFiles = [
    ["align_kernels.d",
     "pure kernels — no Tool subclass, no binding, nothing to record"],
    ["linear_align_tool.d",
     "TRANSFORM ZONE (plan §6, out of task 1905's scope): a TransformTool "
     ~ "subclass committing through the shared TransformTool.recordCommit funnel"],
    ["radial_align_tool.d",
     "TRANSFORM ZONE (plan §6, out of task 1905's scope): same funnel as "
     ~ "linear_align_tool.d"],
];

private string[] familyPaths() {
    string[] r;
    foreach (f; kRecorderFiles)  r ~= buildPath(kG2Dir, f);
    foreach (row; kSilentFiles)  r ~= buildPath(kG2Dir, row[0]);
    r ~= kSeamFile;
    return r;
}

// ---------------------------------------------------------------------------
// 0. THE ROSTERS DO NOT REPEAT THEMSELVES.
//
//    A duplicated roster row is not a harmless typo here: every later member
//    looks its file up by FIRST match, so a duplicate leaves some other member
//    of the directory unscanned while the totals still add up. This is the
//    census's own name-uniqueness guard and it runs before anything trusts a
//    roster.
// ---------------------------------------------------------------------------
unittest {
    string[] dup;
    size_t[string] seen;
    foreach (f; kRecorderFiles) ++seen[f];
    foreach (row; kSilentFiles) ++seen[row[0]];
    foreach (k, v; seen)
        if (v != 1)
            dup ~= "    · `" ~ k ~ "` appears " ~ v.to!string ~ " times across "
                 ~ "kRecorderFiles + kSilentFiles";
    assert(dup.length == 0,
        "G2 census: a file is rostered more than once.\n" ~ joinLines(dup)
      ~ "  Lookups below take the FIRST match, so a duplicate silently drops "
      ~ "another file out of the scan while every total still adds up.");

    assert(kRecorderFiles.length == 5,
        "G2 census: the group is five tools (Array, Clone, RadialArray, Mirror, "
      ~ "RadialSweep) and the recorder roster names "
      ~ kRecorderFiles.length.to!string ~ ". Membership changed — the fixture "
      ~ "`tests/fixtures/tool_gesture/g2.json` has one cell per site and would "
      ~ "have to be re-frozen with it.");
}

// ---------------------------------------------------------------------------
// 1. THE FILE SET IS WALKED, NOT TRUSTED.
//
//    G2 is DEFINED by this directory, so a `.d` file added here is either a
//    sixth record site — which changes what the frozen fixture is an oracle FOR
//    — or a silent helper that needs a row and a reason. Neither may arrive
//    unnoticed.
// ---------------------------------------------------------------------------
unittest {
    immutable dir = buildPath(repoRoot, kG2Dir);
    assert(exists(dir) && isDir(dir),
        "G2 census: `" ~ dir ~ "` is not a directory. The group is DEFINED by "
      ~ "this directory, so every member below is measuring nothing");

    string[] onDisk;
    foreach (e; dirEntries(dir, SpanMode.shallow))
        if (e.isFile && e.name.extension == ".d") onDisk ~= e.name.baseName;
    onDisk.sort();

    assert(onDisk.length >= 5,
        "G2 census: the walk of `" ~ kG2Dir ~ "` returned only "
      ~ onDisk.length.to!string ~ " file(s) — the path is wrong or the tree "
      ~ "moved, and every per-file member below then passes vacuously");

    bool[string] rostered;
    foreach (f; kRecorderFiles) rostered[f] = true;
    foreach (row; kSilentFiles) rostered[row[0]] = true;

    string[] problems;
    foreach (f; onDisk)
        if (f !in rostered)
            problems ~= "    · " ~ f ~ ": a NEW file in `" ~ kG2Dir ~ "` that no "
                      ~ "roster row names. Either it is a sixth record site — "
                      ~ "and then `tests/fixtures/tool_gesture/g2.json` needs a "
                      ~ "cell and a re-freeze, because a sixth site changes what "
                      ~ "that fixture is an oracle FOR — or it is a silent "
                      ~ "helper and needs a row in `kSilentFiles` with a reason.";
    foreach (f, _; rostered) {
        bool present = false;
        foreach (x; onDisk) if (x == f) { present = true; break; }
        if (!present)
            problems ~= "    · " ~ f ~ ": rostered but absent from `" ~ kG2Dir
                      ~ "`. The file moved or was renamed — fix the roster "
                      ~ "deliberately, because a census over a file it cannot "
                      ~ "read proves nothing.";
    }
    assert(problems.length == 0,
        "G2 census: the alignment family's file set moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 2. THE HISTORY CALL SURFACE OF THE FAMILY, name by name, file by file.
//
//    After phase C every recorder in this family lives in ONE place — the seam
//    on `Tool` — and the family's own five files reach `CommandHistory` ZERO
//    times. Unlike G1, G2 leaves behind no legitimate non-recorder at all:
//    there is no `nextRun`, no `undo` ladder, no `invalidateRedo`. Its roster
//    is therefore the seam's four rows and nothing else, and ANY name on the
//    surface inside `source/tools/alignment/` is a finding.
// ---------------------------------------------------------------------------
private struct RosterRow { string path; string name; size_t count; string why; }

private enum RosterRow[] kSurfaceRoster = [
    RosterRow(kSeamFile, "record", 1,
        "GestureRecordMode.Plain -> CommandHistory.record; this is the branch "
      ~ "ALL FIVE G2 sites take"),
    RosterRow(kSeamFile, "recordInSession", 1,
        "GestureRecordMode.InSession -> CommandHistory.recordInSession (G1's "
      ~ "live-box site; no G2 site reaches it)"),
    RosterRow(kSeamFile, "replaceInSessionTailWith", 1,
        "GestureRecordMode.ReplaceRunTail -> CommandHistory.replaceInSessionTailWith "
      ~ "(G1's splice; no G2 site reaches it)"),
    RosterRow(kSeamFile, "consolidate", 1,
        "the refusal belt closing the run the skipped splice would have closed"),
];

unittest {
    string[] problems;
    size_t   totalHits = 0;

    foreach (rel; familyPaths()) {
        immutable full = buildPath(repoRoot, rel);
        assert(exists(full), "G2 census: population member is missing: " ~ rel);
        auto src  = stripCommentsAndStrings(readText(full));
        auto hits = historySurface(src);
        totalHits += hits.length;

        foreach (h; hits) {
            bool ok = false;
            foreach (row; kSurfaceRoster)
                if (row.path == rel && row.name == h.name) { ok = true; break; }
            if (!ok)
                problems ~= "    · UNROSTERED call on the history surface: `history."
                          ~ h.name ~ "(` at " ~ rel ~ ":" ~ h.line.to!string
                          ~ "  — after phase C every record in this family goes "
                          ~ "through `Tool.recordGestureEdit`, and this family "
                          ~ "keeps no legitimate non-recorder of its own. If this "
                          ~ "call is genuinely legitimate, add a roster row with "
                          ~ "the reason; do not widen a regex.";
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

    // NON-VACUITY, AND IT GOES INTO THE SAME ACCUMULATOR — never in front of
    // it. A stripper that lost its place, or a repoRoot pointing nowhere,
    // produces an EMPTY surface and satisfies every "unrostered == 0" above for
    // free; for THIS family that is the likelier accident, because its own five
    // files are supposed to contribute zero hits. But as a SEPARATE assert
    // placed above, this floor swallows the very finding it is meant to
    // accompany: measured on this lane, deleting the belt's `consolidate` call
    // from `source/tool.d` printed the floor and NOT the roster row that names
    // the missing primitive. That is CLAUDE.md's "a second, unnamed guard
    // refuses first" happening inside a witness written to catch exactly that,
    // so the floor is a LAST line of the same message.
    if (totalHits < 4)
        problems ~= "    · NON-VACUITY: the scan found only " ~ totalHits.to!string
                  ~ " call(s) on the history surface across the whole "
                  ~ "population, and the seam alone makes four. If the rows "
                  ~ "above do not explain that, the scanner read nothing — "
                  ~ "check `repoRoot` and the stripper before believing any "
                  ~ "green. This floor matters more here than in G1: G2's own "
                  ~ "five files are expected to contribute ZERO, so an empty "
                  ~ "read looks exactly like a clean migration.";

    assert(problems.length == 0,
        "G2 census: the family's history call surface is not what the seam "
      ~ "leaves behind.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 3. THE SEAM'S CALL SITES, per file and PER MODE.
//
//    All five G2 sites are `Plain`, and that uniformity is what the per-mode
//    triple pins. It is load-bearing twice.
//
//    (a) It is this group's post-seam form of plan §5.4's `runOpen` row. Before
//        the migration that row's mutation was `history.record(` ->
//        `history.recordInSession(` at one site, caught by counting record
//        primitives per file. After the migration there is no `history.record(`
//        left in the family to count: the one-token slip is now
//        `GestureRecordMode.Plain` -> `.InSession`, and this triple is the only
//        text member that can see it. The HTTP fixture still cannot — both
//        primitives push exactly once, so the stack depth and every plane
//        round-trip identically (block 1 of
//        `tests/unit/tool_gesture_runopen_g2_test.d` re-derives that on a live
//        CommandHistory rather than quoting it).
//    (b) It keeps the plan's M2 prediction checkable: `ReplaceRunTail` occurs
//        ZERO times in this family, which is why suppressing that branch must
//        leave all five G2 cells green. When this zero stops being zero, that
//        prediction has to be re-argued and this member reddens first.
// ---------------------------------------------------------------------------
private struct CallRow { string path; size_t calls, plain, inSession, replaceTail; }

private enum CallRow[] kCallRoster = [
    // The seam: one declaration, one dispatch arm per mode — plus a SECOND
    // mention of `ReplaceRunTail`, the belt's `mode ==` test in
    // `refuseGestureRecord`. That second one is counted, not tolerated: if it
    // disappears the belt has stopped closing the run it skipped.
    CallRow(kSeamFile,                                        1, 1, 1, 2),
    CallRow("source/tools/alignment/array_tool.d",            1, 1, 0, 0),
    CallRow("source/tools/alignment/clone_tool.d",            1, 1, 0, 0),
    CallRow("source/tools/alignment/mirror.d",                1, 1, 0, 0),
    CallRow("source/tools/alignment/radial_array_tool.d",     1, 1, 0, 0),
    CallRow("source/tools/alignment/radial_sweep_tool.d",     1, 1, 0, 0),
];

unittest {
    string[] problems;
    size_t   totalCalls = 0, totalPlain = 0, totalTail = 0;

    foreach (rel; familyPaths()) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t calls = countOccurrences(src, "recordGestureEdit(");
        immutable size_t plain = countOccurrences(src, "GestureRecordMode.Plain");
        immutable size_t sess  = countOccurrences(src, "GestureRecordMode.InSession");
        immutable size_t tail  = countOccurrences(src, "GestureRecordMode.ReplaceRunTail");
        totalCalls += calls; totalPlain += plain; totalTail += tail;

        size_t wantC, wantP, wantS, wantT;
        bool listed = false;
        foreach (row; kCallRoster)
            if (row.path == rel) {
                wantC = row.calls; wantP = row.plain;
                wantS = row.inSession; wantT = row.replaceTail;
                listed = true; break;
            }
        if (!listed) {
            if (calls || plain || sess || tail)
                problems ~= "    · " ~ rel ~ " names the seam (" ~ calls.to!string
                          ~ " call(s)) and is not in the call roster. Two files "
                          ~ "of this directory belong to the TRANSFORM zone and "
                          ~ "one holds pure kernels; a record site appearing in "
                          ~ "any of them is a sixth G2 site with no fixture cell.";
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

    // Same rule as member 2: the floor is the LAST line of the accumulator, not
    // an assert in front of it.
    if (totalCalls < 6)
        problems ~= "    · NON-VACUITY: only " ~ totalCalls.to!string
                  ~ " `recordGestureEdit(` across the whole population. Five "
                  ~ "tool sites plus the seam's own declaration are expected; a "
                  ~ "number near zero means the scanner read nothing, not that "
                  ~ "the family stopped recording.";

    assert(problems.length == 0,
        "G2 census: the seam's call sites moved.\n" ~ joinLines(problems)
      ~ "\n  When all five G2 sites are `Plain`, `GestureRecordMode.Plain` is "
      ~ "counted SIX times over this population — one per site plus the seam's "
      ~ "own dispatch arm; this run counted " ~ totalPlain.to!string
      ~ ". `ReplaceRunTail` is counted " ~ totalTail.to!string
      ~ " time(s), and every one of them is inside `source/tool.d`. Those two "
      ~ "facts are what license the plan's M2 prediction that suppressing the "
      ~ "splice branch leaves every G2 cell green.");
}

// ---------------------------------------------------------------------------
// 4. THE FAMILY BINDS THROUGH THE BASE, and carries no carrier plumbing of its
//    own — no `setUndoBindings`, no `*EditFactory` alias, no factory field.
//
//    The five aliases this family used to declare (`ArrayEditFactory`,
//    `MeshCloneEditFactory`, `MirrorEditFactory`, `RadialArrayEditFactory`,
//    `RadialSweepEditFactory`) were five spellings of ONE type,
//    `MeshSessionEdit delegate()`. The base takes a plain `Command delegate()`,
//    so they are gone; a new one is a tool building its own binding path around
//    the seam.
//
//    THE `…EditFactory =` NEEDLE COUNTED SIX THINGS AT THE BRANCH POINT, NOT
//    FIVE, and it keeps both kinds on purpose. Five were the aliases; the sixth
//    was `mirror.d`'s `this.mirrorEditFactory = factory;` — the assignment
//    inside the old binder body. Both are the same defect in different clothes,
//    so the needle is not narrowed to `alias`.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;
    size_t seamDecls = 0;

    foreach (rel; familyPaths()) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t oldDecls = countOccurrences(src, "void setUndoBindings");
        immutable size_t newDecls = countOccurrences(src, "void setGestureBindings");
        immutable size_t aliases  = countOccurrences(src, "EditFactory =");
        seamDecls += newDecls;

        if (oldDecls != 0)
            problems ~= "    · " ~ rel ~ " still declares setUndoBindings x "
                      ~ oldDecls.to!string ~ " — this family binds through "
                      ~ "`Tool.setGestureBindings` now";
        if (rel != kSeamFile && newDecls != 0)
            problems ~= "    · " ~ rel ~ " declares its own setGestureBindings; "
                      ~ "the base's is `final` and there is nothing to add";
        if (rel != kSeamFile && aliases != 0)
            problems ~= "    · " ~ rel ~ " carries carrier-factory plumbing of "
                      ~ "its own: `…EditFactory =` x " ~ aliases.to!string
                      ~ ". The needle is deliberately broad — it matches the "
                      ~ "ALIAS this family used to declare and the ASSIGNMENT "
                      ~ "the old `setUndoBindings` bodies made, because both "
                      ~ "mean one thing: a binding path around "
                      ~ "`Tool.gestureFactory`.";
    }

    assert(seamDecls == 1,
        "G2 census: `void setGestureBindings` is declared " ~ seamDecls.to!string
      ~ " time(s) in the population; exactly one, on `Tool`, is the point of it");
    assert(problems.length == 0,
        "G2 census: binding declarations moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 5. EVERY G2 REGISTRATION CALLS THE BASE BINDER — AND WITH THE FACTORY THE
//    FIXTURE WAS FROZEN AGAINST.
//
//    Scoped to the five wire ids this group owns, deliberately: a count of
//    `setGestureBindings` over the whole of `registration.d` would be a number
//    every later family has to bump, i.e. a lane serialiser.
//
//    THE FACTORY IDENTIFIER IS PINNED TOO, and that is specific to G2. Unlike
//    the create family, this group does NOT share one wire name: it has FOUR
//    names over FIVE cells, and `mesh.mirrorTool` / `mesh.radialSweepTool`
//    collide on `bevelEditFactory`. The G0-G2 lane proved by mutation that the
//    fixture's `entryNames` still discriminates INSIDE that collision —
//    redirecting one of the two reddens exactly its own cell and leaves the
//    other green. This row is the text half of the same fact: it says WHICH
//    factory each id binds, so a redirect is red here by identifier as well as
//    red there by recorded name.
// ---------------------------------------------------------------------------
private enum string[2][] kG2Registrations = [
    ["mesh.mirrorTool",      "bevelEditFactory"],
    ["mesh.radialSweepTool", "bevelEditFactory"],
    ["mesh.radialArrayTool", "radialArrayEditFactory"],
    ["mesh.clone",           "cloneEditFactory"],
    ["mesh.arrayTool",       "arrayEditFactory"],
];

unittest {
    // RAW source here, not the stripped copy, and that is the one place in this
    // file where it has to be: the stripper blanks string literals, and the wire
    // id IS a string literal. The needle keeps `] = ` on the end so it matches
    // the DEFINITION and not the second mention of the same key in the
    // neighbouring `commandFactories` entry; the uniqueness check below makes
    // that a claim rather than an assumption.
    immutable src = readText(buildPath(repoRoot, "source", "registration.d"));
    string[] problems;
    size_t checked = 0;

    foreach (row; kG2Registrations) {
        immutable id  = row[0];
        immutable fac = row[1];
        immutable needle = "reg.toolFactories[\"" ~ id ~ "\"] = ";
        immutable size_t defs = countOccurrences(src, needle);
        if (defs != 1) {
            problems ~= "    · wire id `" ~ id ~ "`: found " ~ defs.to!string
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
                      ~ "setGestureBindings exactly once — an unbound tool "
                      ~ "COMPILES and simply records nothing";
        if (countOccurrences(block, "setUndoBindings(") != 0)
            problems ~= "    · `" ~ id ~ "` still calls setUndoBindings — a G2 "
                      ~ "tool has no such method any more, so this would not "
                      ~ "even compile; if you are reading this, the id resolved "
                      ~ "to the wrong block";
        if (countOccurrences(block, "setGestureBindings(history, " ~ fac ~ ")") != 1)
            problems ~= "    · `" ~ id ~ "` no longer binds `" ~ fac ~ "`. The "
                      ~ "frozen cell for this tool in "
                      ~ "`tests/fixtures/tool_gesture/g2.json` records the wire "
                      ~ "NAME that factory writes; two of these five ids share "
                      ~ "one factory, so a redirect between them is invisible "
                      ~ "to a count and visible only to this identifier.";
    }

    assert(checked == kG2Registrations.length,
        "G2 census: located only " ~ checked.to!string ~ " of "
      ~ kG2Registrations.length.to!string ~ " registration blocks. The scan is "
      ~ "reading the wrong file or the needle stopped matching — every per-id "
      ~ "check above then passes vacuously.");
    assert(problems.length == 0,
        "G2 census: a registration left the base binder.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 6. NO G2 TOOL DECLARES ITS OWN HISTORY FIELD OR ITS OWN CARRIER FACTORY FIELD.
//
//    FAMILY-SCOPED ON PURPOSE, and not a second copy of G1's tree-wide member:
//    `tool_commit_seam_census_g1_test.d` already owns the tree-wide zero for
//    `CommandHistory <name>;` and states why that number can never rise. Two
//    files asserting one tree-wide number is two files to edit and no extra
//    signal. What is G2's own is the pair below over its EIGHT files — the five
//    it migrated and the three that never recorded — which reddens here, naming
//    an alignment file, without waiting on another family's census.
//
//    Why it is worth a member at all: D lets a derived class declare a field of
//    the same name and SILENTLY SHADOWS the base one. A tool that re-declares
//    `CommandHistory history;` compiles, reads its own never-bound copy, and
//    records into null — with no compiler diagnostic anywhere. Phase B
//    confirmed that by running the mutation, not by reading the spec.
// ---------------------------------------------------------------------------
unittest {
    string[] offenders;
    size_t scanned = 0;

    foreach (f; kRecorderFiles ~ [kSilentFiles[0][0], kSilentFiles[1][0], kSilentFiles[2][0]]) {
        immutable rel  = buildPath(kG2Dir, f);
        immutable full = buildPath(repoRoot, rel);
        if (!exists(full)) continue;    // member 1 owns "a rostered file vanished"
        ++scanned;
        auto src = stripCommentsAndStrings(readText(full));

        static immutable string[2][] kTypes = [
            ["CommandHistory",
             "shadows `Tool.history`: the tool compiles, reads its own "
             ~ "never-bound copy, and records into null"],
            ["MeshSessionEdit delegate",
             "a private carrier factory beside `Tool.gestureFactory`: the "
             ~ "registration binds the base one, this one stays null, and the "
             ~ "commit body returns before it records"],
        ];

        foreach (t; kTypes) {
            immutable string ty = t[0];
            size_t i = 0;
            while (true) {
                auto rel2 = src[i .. $].indexOf(ty);
                if (rel2 < 0) break;
                size_t p = i + cast(size_t) rel2;
                i = p + ty.length;
                if (p > 0 && isIdentChar(src[p - 1])) continue;
                size_t q = p + ty.length;
                while (q < src.length && (src[q] == ' ' || src[q] == '\t')) ++q;
                // `MeshSessionEdit delegate()` — step over the parameter list.
                if (q + 1 < src.length && src[q] == '(' && src[q + 1] == ')') {
                    q += 2;
                    while (q < src.length && (src[q] == ' ' || src[q] == '\t')) ++q;
                }
                size_t nameStart = q;
                while (q < src.length && isIdentChar(src[q])) ++q;
                if (q == nameStart) continue;
                immutable string fieldName = src[nameStart .. q];
                while (q < src.length && (src[q] == ' ' || src[q] == '\t')) ++q;
                if (q < src.length && src[q] == ';')
                    offenders ~= "    · " ~ rel ~ ":" ~ lineOf(src, p).to!string
                               ~ "  `" ~ ty ~ " " ~ fieldName ~ ";`  — " ~ t[1];
            }
        }
    }

    assert(scanned >= 5,
        "G2 census: the field scan visited only " ~ scanned.to!string
      ~ " alignment file(s); the shadowing guard below is vacuous over an "
      ~ "empty walk");
    assert(offenders.length == 0,
        "G2 census: an alignment tool declares its own recording plumbing again.\n"
      ~ joinLines(offenders) ~ "\n"
      ~ "  `Tool.history` and `Tool.gestureFactory` are `protected` and bound "
      ~ "together by `setGestureBindings`. A same-named field in a subclass "
      ~ "shadows the base one SILENTLY in D — which is why this family's five "
      ~ "declarations were deleted in the same commit that added their record "
      ~ "call, and why this number does not go up.");
}
