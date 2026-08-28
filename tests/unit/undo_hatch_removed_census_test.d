// undo_hatch_removed_census_test — the `VIBE3D_UNDO_TRACKER` escape hatch has
// no CODE reader anywhere in the tree (task 1903 stage N).
//
// WHAT WAS REMOVED, so the census reads as more than a grep. Until stage N a
// read-once module global in `mesh_edit_delta.d` steered FIFTEEN branch sites:
// eleven position commands, the shared `runMapEdit`, `mesh.morph.apply`, and
// the two interactive edge tools. Under `=off` each ran the same kernel through
// an UNRECORDED batch and undid through a whole-mesh `MeshSnapshot` instead of
// the op-log. It was load-bearing on every one of the fifteen at the moment it
// was deleted — measured, not assumed: each site was driven twice in one
// process and recorded 0 op-log entries with the hatch shut against more than 0
// with it open.
//
// WHY THE COUNT IS OVER CODE AND NOT OVER RAW TEXT, and why that is not a
// weakening. Nineteen comments in `source/` and roughly as many under `tests/`
// still NAME the flag, deliberately: each records what a file used to do, which
// arm a retained fallback used to serve, or why a fixture can no longer be
// re-captured. Deleting that prose would delete the reason the code looks the
// way it does. A raw `== 0` would therefore be a census nobody could keep
// green without lying, so this file asserts the sharper statement instead:
//
//     code-level readers  == 0     (the gate)
//     raw mentions        >  0     (and they are all comments)
//
// The second half is not decoration — it is what makes the first half
// non-vacuous. If `blankNonCode` ever desynced and blanked whole files, the
// code count would read 0 for free; the raw count proves the text the scanner
// was handed actually contains the token it found nothing of. And the planted
// canary below proves the predicate fires on real tree text at all, which is
// exactly the failure mode that let `revert_entry_census_test`'s
// argument-bearing set stay invisible for four migration stages.
//
// MUTATION: restore one deleted `if (undoTrackerEnabled())` branch in, say,
// `source/commands/mesh/smooth.d`. This reddens naming the file.
module tests.unit.undo_hatch_removed_census_test;

import std.algorithm : canFind;
import std.array     : appender;
import std.file      : dirEntries, exists, isFile, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;

import tests.unit.revert_entry_census_test : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

/// The three spellings the hatch could be reached by. `VIBE3D_UNDO_TRACKER` is
/// the environment variable, the other two the functions that read and
/// overrode the cached value; the wire commands `undo.tracker.on` / `.off` were
/// string literals, so they are counted separately below (a literal is blanked
/// by `blankNonCode` along with comments, and a literal command id that no
/// factory serves is exactly as dead as a call to a deleted function).
private static immutable string[] kTokens = [
    "VIBE3D_UNDO_TRACKER",
    "undoTrackerEnabled",
    "setUndoTrackerEnabled",
];

/// The roots the census walks. Enumerated per-root rather than swept from the
/// repo top, so a root that stops existing is a red rather than a silently
/// smaller scan.
private static immutable string[] kDirRoots = ["source", "tests"];
private static immutable string[] kFileRoots = ["run_all.d", "run_test.d"];

private size_t countIn(string hay, string needle) {
    size_t n = 0, i = 0;
    while (i + needle.length <= hay.length) {
        if (hay[i .. i + needle.length] == needle) { ++n; i += needle.length; continue; }
        ++i;
    }
    return n;
}

private struct Scan { size_t files; size_t rawBytes; size_t rawHits; size_t codeHits;
                      string[] offenders; }

private Scan scanRoots() {
    Scan r;
    void one(string rel, string text) {
        ++r.files;
        r.rawBytes += text.length;
        const string code = blankNonCode(text);
        foreach (t; kTokens) {
            const size_t raw  = countIn(text, t);
            const size_t codeN = countIn(code, t);
            r.rawHits  += raw;
            r.codeHits += codeN;
            if (codeN != 0)
                r.offenders ~= format("%s — `%s` appears %d time(s) in CODE",
                                      rel, t, codeN);
        }
        // The wire ids were string literals; `blankNonCode` erases those, so
        // they are looked for in the RAW text and reported separately.
        foreach (t; ["\"undo.tracker.on\"", "\"undo.tracker.off\""])
            if (countIn(text, t) != 0)
                r.offenders ~= format("%s — the wire id %s is still issued; no "
                                    ~ "factory serves it since task 1903 stage N",
                                      rel, t);
    }
    foreach (root; kDirRoots) {
        immutable dir = buildPath(repoRoot, root);
        assert(dir.exists, "census root " ~ root ~ " does not exist — the scan "
                         ~ "would be silently smaller, not red");
        foreach (de; dirEntries(dir, "*.d", SpanMode.depth))
            one(de.name[repoRoot.length + 1 .. $], readText(de.name));
    }
    foreach (f; kFileRoots) {
        immutable path = buildPath(repoRoot, f);
        assert(path.exists && path.isFile,
               "census root " ~ f ~ " does not exist");
        one(f, readText(path));
    }
    return r;
}

/// THE GATE.
unittest {
    const s = scanRoots();

    assert(s.offenders.length == 0, format(
        "task 1903 stage N: the `VIBE3D_UNDO_TRACKER` hatch has a CODE reader "
      ~ "again.%-(\n    %s%)\n\n"
      ~ "  The flag, its two accessors and the `undo.tracker.on/off` wire "
      ~ "commands were all deleted at stage N, after measuring that all "
      ~ "fifteen branch sites were still live. A new reader is not a smaller "
      ~ "version of the old hatch — it is a second undo path with no parity "
      ~ "oracle behind it, because the oracles that judged the first one "
      ~ "(tests/fixtures/undo_parity/*.json) were captured on an arm that no "
      ~ "longer exists and cannot be re-captured.",
        s.offenders));

    assert(s.codeHits == 0, format(
        "the code-level hit count is %d with no offender named — the two "
      ~ "halves of this census have drifted apart", s.codeHits));

    // NON-VACUITY, and this is the half that makes the zero mean something.
    // The historical comments are supposed to be there; if this reads 0 the
    // scanner was handed blank text and the gate above passed for free.
    assert(s.rawHits > 0, format(
        "the census found %d RAW mention(s) of the hatch across %d file(s) / "
      ~ "%d byte(s). Zero here does not mean the tree is clean — it means the "
      ~ "scanner read nothing, and the `codeHits == 0` gate above is then "
      ~ "satisfied for free. The historical comments naming the flag are "
      ~ "deliberate; see this module's header.",
        s.rawHits, s.files, s.rawBytes));

    assert(s.files >= 400, format(
        "the census walked only %d file(s) — it has lost its place. Fix the "
      ~ "walk, do not lower this floor.", s.files));
}

/// THE PLANTED CANARY (task 1903 P0-N-3). The gate above is a count of ZERO,
/// and a predicate that matches nothing reads zero without ever being wrong.
/// So: take real tree text, plant one CODE-level `undoTrackerEnabled()` call in
/// it, and require the scan to see it. Blanking the call into a comment must
/// take it back out again — otherwise the census is counting comments and the
/// nineteen deliberate historical mentions would all read as offenders.
unittest {
    immutable host = readText(buildPath(repoRoot, "source/commands/mesh/smooth.d"));

    size_t codeHits(string text) {
        const string code = blankNonCode(text);
        size_t n = 0;
        foreach (t; kTokens) n += countIn(code, t);
        return n;
    }

    assert(codeHits(host) == 0,
        "the canary's host file already holds a CODE-level hatch reader — the "
      ~ "plant below could not be told apart from it");

    immutable planted = host ~ "\nbool censusCanary() { return undoTrackerEnabled(); }\n";
    assert(codeHits(planted) == 1,
        "the census predicate did NOT see a planted `undoTrackerEnabled()` "
      ~ "call in real tree text. It matches nothing the tree could write, so "
      ~ "the `== 0` gate above is satisfied for free — this is the inert-gate "
      ~ "shape task 1903 stage N-d had to repair in the revert census.");

    immutable commented = host ~ "\n// bool censusCanary() { return undoTrackerEnabled(); }\n";
    assert(codeHits(commented) == 0,
        "a COMMENTED `undoTrackerEnabled()` counted as a code-level reader. "
      ~ "The census would then be red over the deliberate historical comments "
      ~ "and the only way to green it would be to delete them.");
}
