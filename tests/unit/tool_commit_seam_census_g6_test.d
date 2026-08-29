// tool_commit_seam_census_g6_test — the text half of the gesture-recording
// seam, for group G6, the command-wrapper family (task 1905, phase D).
//
// WHY THIS FILE EXISTS AT ALL, because the plan argued it should not.
// §6 of the plan schedules G6 last and says "its present form is already the
// target and a migration would prove nothing new"; member 5 of
// `tool_commit_seam_census_g8_test.d` repeated that as the reason
// `CommandWrapperTool` kept its own binder. The claim was tested rather than
// re-quoted, and it is half right:
//
//   * TRUE of `commitNow`'s CONTRACT — seven early exits and "true iff it
//     really committed" (`command_wrapper.d`) — which the migration preserved
//     line for line and which member 6 below now pins;
//   * FALSE of the record CALL. `history.record(cmd)` in `commitNow` was the
//     last writing history primitive under `source/tools/**` outside the
//     transform zone, and it sat in NO census population. Measured 2026-08-29,
//     both directions: `static if (false) history.nextRun();` added to
//     `source/tools/common/command_wrapper.d` left `dub test --config=tests` at
//     383/383 GREEN, while the identical line in `source/tools/deform/magnet.d`
//     reddened `tool_commit_seam_census_g1_test.d(321)` AND
//     `tool_commit_seam_census_g3_test.d(385)`, each naming the file and the
//     line. The censuses were not inert; this family was simply unwatched.
//
// THE POPULATION IS `source/tools/common/**` (walked) + `source/tools/slice/
// edge_slide.d` (named) + `source/tool.d`.
//   * the walk, because a second wrapper dropped into `tools/common/` inherits
//     `CommandWrapperTool.commitNow` — the one record body all four wrapper
//     tools share — and would join this seam whether or not anyone said so;
//   * `edge_slide.d` by name, because `EdgeSlideTool` is the one member of this
//     family living in another family's DIRECTORY (`tools/slice/`, whose census
//     rosters it as "G6, records elsewhere"). A directory key would leave it in
//     neither file;
//   * `source/tool.d`, for the reason round 4 of the plan caught for G1:
//     `class Tool` lives OUTSIDE `source/tools/**`, so a census keyed only on
//     the tools directory reads "0 recorders" after the migration and never
//     looks at the one that survives.
//
// WHAT IT CANNOT SEE, said here so nobody trusts it for that: whether the
// recorded carrier holds the RIGHT payload, and whether the four wrapper tools
// are REACHED by the Shift+apply gesture at all. The first is a fixture's job;
// the second is driven at runtime by `tests/test_refire.d`,
// `tests/test_undo_resync_golden.d` and `tests/test_tool_undo_coordination.d`.
//
// MUTATIONS, one per member, each reddening only its own:
//   1. add a file under `source/tools/common/` -> member 1, by name.
//   2. write any `history.<name>(` into a G6 file -> member 2, with the address.
//   3. turn `recordGestureEdit` in `commitNow` back into `history.record(cmd)`
//      -> member 2 (unrostered `record` in a tool) AND member 3 (the count).
//   4. re-declare `void setUndoBindings` on `CommandWrapperTool` -> member 4.
//   5. flip one of the four registrations back to `setUndoBindings` -> member 5,
//      by wire id.
//   6. delete the `hist.onRecord` counter from the in-module commit test
//      -> member 6, by name.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_commit_seam_census_g6_test;

import std.algorithm : sort;
import std.array     : appender;
import std.conv      : to;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.path      : baseName, buildPath, dirName;
import std.string    : indexOf;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// ---------------------------------------------------------------------------
// The stripper and the surface scanner are the G1 file's, character for
// character, and deliberately so: two censuses that disagree about what counts
// as "a call" would let a site be legal in one file and invisible in the other.
// The known gap is the same one (wysiwyg strings / character literals can
// desync it), and so is the guard: the non-vacuity floors below.
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
// THE FAMILY.
// ---------------------------------------------------------------------------
private enum string[] kCommonDirFiles = [
    "command_wrapper.d", "session_mesh_key.d",
];

private enum string[] kNamedMembers = [
    "source/tools/slice/edge_slide.d",
    "source/tool.d",
];

private string[] familyPaths() {
    string[] r;
    foreach (f; kCommonDirFiles) r ~= buildPath("source", "tools", "common", f);
    foreach (f; kNamedMembers)   r ~= f;
    return r;
}

// ---------------------------------------------------------------------------
// 1. THE FILE SET IS WALKED, NOT TRUSTED.
// ---------------------------------------------------------------------------
unittest {
    string[] found;
    foreach (e; dirEntries(buildPath(repoRoot, "source", "tools", "common"),
                           "*.d", SpanMode.breadth))
        found ~= baseName(e.name);
    found.sort();
    auto expect = kCommonDirFiles.dup;
    expect.sort();

    assert(found.length >= 2,
        "G6 census: the walk of `source/tools/common/` returned only "
      ~ found.length.to!string ~ " file(s). The path is wrong or the tree "
      ~ "moved — every member below is then measuring nothing");

    string bad, gone;
    foreach (f; found) {
        bool known = false;
        foreach (x; expect) if (x == f) { known = true; break; }
        if (!known) bad ~= (bad.length ? ", " : "") ~ f;
    }
    foreach (f; expect) {
        bool present = false;
        foreach (x; found) if (x == f) { present = true; break; }
        if (!present) gone ~= (gone.length ? ", " : "") ~ f;
    }
    assert(bad.length == 0 && gone.length == 0,
        "G6 census: the command-wrapper family's file set moved.\n"
      ~ "    new, not in the roster: " ~ (bad.length ? bad : "(none)") ~ "\n"
      ~ "    rostered, now missing:  " ~ (gone.length ? gone : "(none)") ~ "\n"
      ~ "  A new file here is a new member whether or not it says so: anything "
      ~ "deriving `CommandWrapperTool` inherits `commitNow`, the ONE record "
      ~ "body the four wrapper tools share. Add it to `kCommonDirFiles`, or "
      ~ "explain at its declaration why it has no gesture to record.");
}

// ---------------------------------------------------------------------------
// 2. THE HISTORY CALL SURFACE OF THE FAMILY, name by name, file by file.
//
//    After phase D the family's only recorder is the seam on `Tool`, and the
//    wrapper files hold NOTHING on the history surface. That zero is the whole
//    finding of this group and it is written as a roster with no rows for the
//    wrapper files, not as a sentence.
// ---------------------------------------------------------------------------
private struct RosterRow { string path; string name; size_t count; string why; }

private enum RosterRow[] kSurfaceRoster = [
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

    foreach (rel; familyPaths()) {
        immutable full = buildPath(repoRoot, rel);
        assert(exists(full), "G6 census: population member is missing: " ~ rel);
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
                          ~ "  — the command-wrapper family records through "
                          ~ "`Tool.recordGestureEdit` and holds NO legal "
                          ~ "non-recorder of its own (unlike box's `nextRun`/"
                          ~ "`undo` in G1 or the slice family's four "
                          ~ "`invalidateRedo`). This file was unwatched before "
                          ~ "phase D and a line added here reddened nothing; "
                          ~ "add a roster row with a reason, do not widen a regex.";
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

    // NON-VACUITY. The wrapper files are EXPECTED to contribute zero, so
    // "unrostered == 0" is satisfied for free by a scanner that read nothing.
    // The seam alone makes four, and that is the floor.
    assert(totalHits >= 4,
        "G6 census: the scan found " ~ totalHits.to!string ~ " call(s) on the "
      ~ "history surface across the whole family, and `source/tool.d` alone "
      ~ "makes four. The scanner read nothing — check `repoRoot` and the "
      ~ "stripper before believing any green above it. This floor matters more "
      ~ "here than in the other families: every other roster row in this file "
      ~ "is an expected ZERO.");

    assert(problems.length == 0,
        "G6 census: the family's history call surface is not what the seam "
      ~ "leaves behind.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 3. THE SEAM'S CALL SITES, per file and PER MODE.
// ---------------------------------------------------------------------------
private struct CallRow { string path; size_t calls, plain, inSession, replaceTail; }

private enum CallRow[] kCallRoster = [
    // The seam: one declaration, one dispatch arm per mode, plus the belt's
    // `mode ==` test for ReplaceRunTail (hence 2).
    CallRow("source/tool.d",                            1, 1, 1, 2),
    // ONE record site for the whole family: `CommandWrapperTool.commitNow`,
    // reached by all four wrapper tools and by both of its callers
    // (`deactivate()` and `commitUncommittedEdit()`). `buildRefireCommand` also
    // builds a MeshVertexEdit but hands it to the history's own fire()/
    // refireEnd() lifecycle and records NOTHING itself — which is why this row
    // is 1 and not 2.
    CallRow("source/tools/common/command_wrapper.d",    1, 1, 0, 0),
];

unittest {
    string[] problems;
    size_t   totalCalls = 0;

    foreach (rel; familyPaths()) {
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
        if (!listed && (calls || plain || sess || tail)) {
            problems ~= "    · " ~ rel ~ " names the seam and is not in the call "
                      ~ "roster (" ~ calls.to!string ~ " call(s)). `edge_slide.d` "
                      ~ "in particular records through `CommandWrapperTool."
                      ~ "commitNow` in the base and must stay at zero";
            continue;
        }
        if (!listed) continue;
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

    assert(totalCalls >= 2,
        "G6 census: only " ~ totalCalls.to!string ~ " `recordGestureEdit(` in "
      ~ "the whole family. One tool site plus the seam's own declaration are "
      ~ "expected; a number near zero means the scanner read nothing, not that "
      ~ "the family stopped recording.");

    assert(problems.length == 0,
        "G6 census: the seam's call sites moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 4. THE FAMILY BINDS THROUGH THE BASE, and declares no binder of its own.
//
//    `CommandWrapperTool` held the THIRD and last surviving `setUndoBindings`
//    declaration outside the transform zone (the other two are
//    `transform.d` and `xfrm_transform.d`, kept by decision D1). Member 5 of
//    `tool_commit_seam_census_g8_test.d` rosters that residue tree-wide; this
//    member is the family-local half, so a re-declaration here is named by its
//    own group rather than only by the tree-wide count.
// ---------------------------------------------------------------------------
unittest {
    string[] problems;

    foreach (rel; familyPaths()) {
        auto src = stripCommentsAndStrings(readText(buildPath(repoRoot, rel)));
        immutable size_t oldDecls = countOccurrences(src, "void setUndoBindings");
        immutable size_t newDecls = countOccurrences(src, "void setGestureBindings");
        if (oldDecls != 0)
            problems ~= "    · " ~ rel ~ " declares setUndoBindings x "
                      ~ oldDecls.to!string ~ " — the command-wrapper family "
                      ~ "binds through `Tool.setGestureBindings` since phase D";
        if (rel != "source/tool.d" && newDecls != 0)
            problems ~= "    · " ~ rel ~ " declares its own setGestureBindings; "
                      ~ "the base's is `final` and there is nothing to add";
    }

    // NON-VACUITY: the reader must actually have found the base declaration.
    immutable seam = countOccurrences(
        stripCommentsAndStrings(readText(buildPath(repoRoot, "source", "tool.d"))),
        "void setGestureBindings");
    assert(seam == 1,
        "G6 census: `void setGestureBindings` is declared " ~ seam.to!string
      ~ " time(s) on `Tool`; exactly one is the point of it, and a zero here "
      ~ "means the file was not read, which makes the loop above vacuous");
    assert(problems.length == 0,
        "G6 census: binding declarations moved.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 5. EVERY G6 REGISTRATION CALLS THE BASE BINDER.
// ---------------------------------------------------------------------------
private enum string[] kG6WireIds = [
    "xfrm.smooth", "xfrm.jitter", "xfrm.quantize", "edge.slide",
];

unittest {
    // RAW source: the wire id IS a string literal and the stripper blanks it.
    immutable src = readText(buildPath(repoRoot, "source", "registration.d"));
    string[] problems;
    size_t checked = 0;

    foreach (id; kG6WireIds) {
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
            problems ~= "    · `" ~ id ~ "` still calls setUndoBindings — a G6 "
                      ~ "tool has no such method any more, so this would not "
                      ~ "even compile; if you are reading this, the id resolved "
                      ~ "to the wrong block";
    }

    assert(checked == kG6WireIds.length,
        "G6 census: located only " ~ checked.to!string ~ " of "
      ~ kG6WireIds.length.to!string ~ " registration blocks. The scan is "
      ~ "reading the wrong file or the stripper ate it — every per-id check "
      ~ "above then passes vacuously.");
    assert(problems.length == 0,
        "G6 census: a registration left the base binder.\n" ~ joinLines(problems));
}

// ---------------------------------------------------------------------------
// 6. THE IN-MODULE COMMIT TEST SURVIVES, AND STILL COUNTS.
//
//    This member has no sibling in the other six census files, and it is the
//    reason the plan wanted G6 left alone. `command_wrapper.d` carries the ONLY
//    in-module commit test in the whole tools tree that checks its claim by
//    COUNTING records rather than by asking `canUndo()` — task 0685 T2's own
//    lesson, written into that test's comments. A migration that quietly
//    dropped it would trade a real witness for a text census, which is the
//    wrong trade and is exactly what "a migration would prove nothing new"
//    was protecting against.
//
//    So the three load-bearing parts are named here individually: the counter
//    hook, the exact-one assertion, and the refire-latch assertion that pins
//    "true iff it really committed". Deleting any one reddens by name.
// ---------------------------------------------------------------------------
unittest {
    immutable src = readText(buildPath(repoRoot, "source", "tools", "common",
                                       "command_wrapper.d"));
    string[] missing;

    static struct Needle { string text; string why; }
    immutable Needle[] kNeedles = [
        Needle("hist.onRecord = ",
            "the record COUNTER. Without it the test falls back to canUndo(), "
          ~ "which stays green for a commit that recorded two entries or none "
          ~ "of its own on top of an earlier one (task 0685 T2)"),
        Needle("in-place commit must record exactly ONE entry",
            "the exact-one assertion — the positive half of the Shift+apply "
          ~ "contract for XfrmSmooth / XfrmJitter / XfrmQuantize / EdgeSlide"),
        Needle("a commit that recorded nothing must not report success",
            "the refire-latch assertion. This is the one that pins commitNow's "
          ~ "invariant (\"true iff it really committed\") on the path that "
          ~ "actually bites: the latch clears `dirty` and records NOTHING, so "
          ~ "answering true rebaselines over geometry with no undo entry"),
        Needle("t.setGestureBindings(hist,",
            "the test drives the BASE binder. If this reverts to "
          ~ "setUndoBindings the test is exercising a method the tool no "
          ~ "longer has, i.e. it stopped compiling — or someone re-added it"),
        Needle("recordGestureEdit(cmd, GestureRecordMode.Plain)",
            "the seam call inside commitNow. Its disappearance means the "
          ~ "family left the seam, and member 2 says so with an address; this "
          ~ "row says it in the language of the test that covers it"),
    ];

    foreach (n; kNeedles)
        if (src.indexOf(n.text) < 0)
            missing ~= "    · gone: `" ~ n.text ~ "`\n        " ~ n.why;

    assert(src.length > 20_000,
        "G6 census: `command_wrapper.d` read back as " ~ src.length.to!string
      ~ " bytes. The path is wrong and every needle below is vacuously absent "
      ~ "or vacuously present.");

    assert(missing.length == 0,
        "G6 census: the in-module commit test lost a load-bearing part.\n"
      ~ joinLines(missing) ~ "\n"
      ~ "  `grep -rl 'canUndo()\\|onRecord' source/tools` returns this file and "
      ~ "nothing else: it is the only in-module commit test in the tools tree "
      ~ "with a mutation check. Phase D migrated the RECORD CALL out of "
      ~ "`commitNow` and deliberately left the CONTRACT — seven early exits and "
      ~ "\"true iff it really committed\" — untouched. This member is what "
      ~ "makes that promise checkable.");
}

private string joinLines(const(string)[] xs) {
    string r;
    foreach (x; xs) r ~= x ~ "\n";
    return r;
}
