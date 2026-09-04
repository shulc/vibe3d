// The prepared-protocol census must have a LIVE CALLER, and the caller is
// `run_test.d` (task 3691 follow-up).
//
// THE HOLE THIS CLOSES. The census — `tools/check_prepared_protocol.py` —
// used to hang off `preBuildCommands` of dub.json's `tests` configuration. It
// was moved out of there for cost (38.4 s on every `dub test --config=tests`
// that rebuilt anything) and into `run_test.d`'s main, as a barrier beside the
// test-liveness one. The move is right and the measurement is recorded at both
// sites. What the move LOST is the thing that made the old placement safe:
// dub could not silently stop running a preBuildCommand, whereas a call in a
// D source file can be deleted by anyone, in one line, and BOTH routine lanes
// stay green while doing it. That is the exact failure this project pays for
// most — a check that is satisfied by the broken tree too — and it would be
// invisible: a whole-tree property that has drifted produces a PASS, not a
// red. So the call site itself is pinned here.
//
// WHAT THE CENSUS IS NOW (task 4052). Its compile-fail half is gone: the 73
// fixtures under `tests/compile_fail/` were 72 compiler launches and 21.6 s of
// its 39.9 s, and both properties they stated are `static assert`s, now in
// `tests/unit/prepared_tool_transition_test.d`. What survives here is the part
// that has no assert-shaped substitute — statement ORDER inside another
// module's function body, caller sets across files no test binary imports,
// occurrence counts, body digests — plus the half of that new D census a
// compiler cannot see: that its module list still matches the .d files on
// disk. So this pin protects a smaller, cheaper scanner, and exactly the
// scanner that could not have been written as a test.
//
// WHY THIS CANNOT BE A SUBSTRING SEARCH. `run_test.d` MENTIONS
// `protocolCensus()` in prose more often than it calls it: at the time of
// writing, five raw occurrences, of which only three are code (the definition,
// the `--check-protocol` diagnostic, and the wide-path call) and two are
// comments explaining the move. A census that greps the raw file is therefore
// satisfied by a tree in which the call has been deleted and only its
// obituary remains — and equally by a commented-out call, or by the call's own
// name inside a `stderr.writeln` error message. So this file blanks comments
// and string literals to spaces FIRST (offsets preserved, so it can still name
// a line) and asks its question of the code that is left. The discrimination
// is not asserted by claim: `decoyMentionsOnly` below is a source fragment
// whose only occurrences are a comment and a string, and the predicate must
// REJECT it in the same run in which it accepts `run_test.d`.
//
// WHAT IS PINNED, and it is a position rather than a mere presence. The live
// call must sit in the window between the FIRST barrier's refusal
// (`HarnessStage.gateRefused`, the test-liveness gate) and the build
// (`dubBuild()`), and that window must also carry the census's own refusal
// (`HarnessStage.protocolRefused`) and the one sanctioned escape from it
// (`args.length > 1`, a narrow run naming a test). A call moved after the
// build, a call whose refusal was softened to a warning, or a skip widened
// past "the caller named a test" all redden here. Presence alone would not
// have caught any of them.
//
// MUTATION (run 2026-09-02): delete the `} else if (!protocolCensus())` arm
// from run_test.d's main and this file's first assert names it. Comment the
// same arm out instead — leaving the text in the file — and it still reddens,
// which is the half a grep would have missed.
module tests.unit.run_test_protocol_census_pin_test;

import std.exception : enforce;
import std.file      : exists, readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import tests.unit.census_symbols : sharedBlankNonCode = blankNonCode;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");

// The needles, all of them CODE tokens rather than prose.
private enum kCall       = "protocolCensus()";
private enum kFirstGate  = "HarnessStage.gateRefused";      // the liveness barrier's refusal
private enum kRefusal    = "HarnessStage.protocolRefused";  // this census's refusal
private enum kBuild      = "dubBuild()";
private enum kNarrowEsc  = "args.length > 1";               // the one sanctioned skip

/// Blank every comment and every string/char literal to spaces, in place, so
/// that what remains is code AND every surviving offset still indexes the
/// original text (newlines are kept, so a hit can be reported as a line).
private alias blankNonCode = sharedBlankNonCode;

private size_t lineOf(string src, size_t off)
{
    size_t line = 1;
    foreach (ch; src[0 .. off]) if (ch == '\n') line++;
    return line;
}

private size_t countOf(string hay, string needle)
{
    size_t n, at;
    while (at < hay.length)
    {
        const rel = hay[at .. $].indexOf(needle);
        if (rel < 0) break;
        n++;
        at += rel + needle.length;
    }
    return n;
}

private struct Verdict { bool live; size_t line; string why; }

/// Is there a LIVE call to the protocol census on the wide path — after the
/// test-liveness barrier, before the build, refusing rather than warning?
private Verdict wideCensusCall(string src)
{
    const code = blankNonCode(src);

    const gate = code.indexOf(kFirstGate);
    if (gate < 0)
        return Verdict(false, 0, "no live `" ~ kFirstGate ~ "`: the test-liveness "
            ~ "barrier that anchors the window is gone, or survives only as prose");

    const rel = code[gate .. $].indexOf(kBuild);
    if (rel < 0)
        return Verdict(false, 0, "no live `" ~ kBuild ~ "` after the first barrier: "
            ~ "the window this census reasons about no longer closes");

    const lo = cast(size_t) gate, hi = lo + cast(size_t) rel;
    const window = code[lo .. hi];

    const call = window.indexOf(kCall);
    if (call < 0)
        return Verdict(false, 0, "no live call to `" ~ kCall ~ "` between the "
            ~ "test-liveness barrier and the build");
    if (window.indexOf(kRefusal) < 0)
        return Verdict(false, 0, "the call is there but `" ~ kRefusal ~ "` is not: "
            ~ "a census that does not refuse the run is a warning, and a warning "
            ~ "in a build log is how a whole-tree property rots unseen");
    if (window.indexOf(kNarrowEsc) < 0)
        return Verdict(false, 0, "no `" ~ kNarrowEsc ~ "` guard on the skip: the "
            ~ "ONLY sanctioned escape is a caller naming a test, and a skip "
            ~ "condition that widened past that has to be re-argued here");

    return Verdict(true, lineOf(src, lo + cast(size_t) call), "");
}

// A source fragment carrying every shape of MENTION and no call at all: a
// commented-out call, a commented-out refusal, and the names inside a string.
// The predicate must reject it — this is the substring census's false green,
// executed rather than described.
private enum decoyMentionsOnly =
      "    g_harness.stage = HarnessStage.gateRefused;\n"
    ~ "    // } else if (!protocolCensus()) {\n"
    ~ "    //     g_harness.stage = HarnessStage.protocolRefused;\n"
    ~ "    // skipped when args.length > 1\n"
    ~ "    stderr.writeln(\"protocolCensus() / HarnessStage.protocolRefused"
    ~ " / args.length > 1\");\n"
    ~ "    if (!noBuild && !dubBuild()) return 1;\n";

// The positive control: the same shape, actually called. Without this the
// rejection above would also be produced by a predicate that is simply always
// false, and the decoy would prove nothing.
private enum decoyLiveCall =
      "    g_harness.stage = HarnessStage.gateRefused;\n"
    ~ "    if (args.length > 1) { skip(); }\n"
    ~ "    else if (!protocolCensus()) {\n"
    ~ "        g_harness.stage = HarnessStage.protocolRefused;\n"
    ~ "        return 2;\n"
    ~ "    }\n"
    ~ "    if (!noBuild && !dubBuild()) return 1;\n";

unittest
{
    enforce(exists(runnerPath), "run_test.d not found at " ~ runnerPath);
    const src  = readText(runnerPath);
    const code = blankNonCode(src);

    // 1. THE PIN. run_test.d calls the census on the wide path.
    const v = wideCensusCall(src);
    assert(v.live, format(
        "run_test.d no longer calls the prepared-protocol census on the wide "
      ~ "path: %s.\n"
      ~ "That census is the ONLY caller of tools/check_prepared_protocol.py, "
      ~ "which pins properties no red assert can express — the ORDER of "
      ~ "statements inside another module's body, the caller set of a symbol "
      ~ "across files nothing imports, occurrence counts, body digests. With "
      ~ "this call gone both routine lanes stay green over a tree in which "
      ~ "every one of them has drifted. Restore the call in main (between the "
      ~ "test-liveness "
      ~ "barrier and dubBuild()), or, if it truly must move, move this pin "
      ~ "with it and say in the message where it went.", v.why));

    // 2. THE DISCRIMINATION IS LIVE, not claimed: the raw file really does
    //    mention the call more often than it makes it, so a grep-shaped census
    //    would be satisfied by strictly less than this one requires.
    const rawHits  = countOf(src,  kCall);
    const codeHits = countOf(code, kCall);
    assert(rawHits > codeHits, format(
        "expected run_test.d to MENTION `%s` in comments as well as call it "
      ~ "(raw %d, code %d). If the prose was removed, this census still works, "
      ~ "but the demonstration that it discriminates has gone with it — and "
      ~ "that demonstration is the reason it is not a grep.",
        kCall, rawHits, codeHits));
    assert(codeHits >= 2, format(
        "expected at least two LIVE occurrences of `%s` in run_test.d (the "
      ~ "definition and the wide-path call); found %d", kCall, codeHits));

    // 3. THE PREDICATE ITSELF, both ways, in this run.
    const dead = wideCensusCall(decoyMentionsOnly);
    assert(!dead.live,
        "the predicate accepted a source whose only occurrences are a "
      ~ "commented-out call and a string: it is behaving as a substring "
      ~ "search, which is exactly the census this file exists not to be");
    assert(wideCensusCall(decoyLiveCall).live,
        "the predicate rejected a source that really does call the census — "
      ~ "it is failing closed, so its rejection of the decoy proves nothing");

    // 4. THE CALL MUST STILL REACH THE SCANNER. A pinned call into a gutted
    //    `protocolCensus()` that returns true is the same hole with a call
    //    site, so brace-match the body and require both the scanner constant
    //    and a real process spawn inside it.
    const fn = code.indexOf("bool " ~ kCall);
    assert(fn >= 0, "run_test.d no longer defines `bool " ~ kCall ~ "`");
    size_t i = cast(size_t) fn;
    while (i < code.length && code[i] != '{') i++;
    size_t depth = 0, end = i;
    for (; end < code.length; end++)
    {
        if (code[end] == '{') depth++;
        else if (code[end] == '}' && --depth == 0) { end++; break; }
    }
    const body_ = code[i .. end];
    assert(body_.indexOf("kProtocolScanner") >= 0 && body_.indexOf("spawnProcess") >= 0,
        format("`%s` (run_test.d:%d) no longer spawns the scanner: its body "
             ~ "mentions neither kProtocolScanner nor spawnProcess, so the "
             ~ "pinned call site now calls nothing", kCall, lineOf(src, cast(size_t) fn)));

    // 5. And the scanner it names is on disk. "The file is not there" must not
    //    be indistinguishable from "the fixtures are fine".
    const decl = src.indexOf("enum string kProtocolScanner");
    assert(decl >= 0, "run_test.d no longer declares kProtocolScanner");
    const q1 = cast(size_t) decl + cast(size_t) src[decl .. $].indexOf('"') + 1;
    const q2 = q1 + cast(size_t) src[q1 .. $].indexOf('"');
    const scanner = src[q1 .. q2];
    assert(exists(buildPath(repoRoot, scanner)), format(
        "run_test.d names `%s` as the prepared-protocol scanner and no such "
      ~ "file exists in the tree", scanner));

    // 6. Anchor hygiene: the window's lower edge must be the unambiguous one
    //    it was chosen to be, so this census cannot start measuring some other
    //    stretch of main after a refactor moves a same-named token in.
    assert(countOf(code, kFirstGate) == 1, format(
        "`%s` occurs %d times in run_test.d's code; this census anchors its "
      ~ "window on it and needs it to be the single test-liveness refusal",
        kFirstGate, countOf(code, kFirstGate)));
}
