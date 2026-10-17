// The full suite must reach the lightweight prepared-protocol boundary census.
module tests.unit.run_test_protocol_census_pin_test;

import std.exception : enforce;
import std.file : exists, readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import tools.harness.dsource : sharedBlankNonCode = blankNonCode;

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
      ~ "which checks source population and forbidden entry paths. "
      ~ "Restore the call before dubBuild(), or move this pin "
      ~ "with it and say in the message where it went.", v.why));

    // Definition and wide-path call must both be code, not just comments.
    const codeHits = countOf(code, kCall);
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

    // Task 20263020: helper refusal controls must protect the actual CLI
    // observation path; see doc/ci_runner_failures_plan_2026-10-16.md.
    const cliPath = buildPath(repoRoot, "tests/test_standalone_cli.d");
    const cliCode = blankNonCode(readText(cliPath));
    const cliFn = cliCode.indexOf("private Run runCli(");
    assert(cliFn >= 0, "CLI readiness wiring: runCli definition missing");
    size_t cliStart = cast(size_t) cliFn;
    while (cliStart < cliCode.length && cliCode[cliStart] != '{') cliStart++;
    size_t cliDepth, cliEnd = cliStart;
    for (; cliEnd < cliCode.length; cliEnd++)
    {
        if (cliCode[cliEnd] == '{') cliDepth++;
        else if (cliCode[cliEnd] == '}' && --cliDepth == 0) { cliEnd++; break; }
    }
    assert(cliStart < cliEnd && cliDepth == 0,
        "CLI readiness wiring: runCli body missing or incomplete");
    const cliBody = cliCode[cliStart .. cliEnd];
    assert(countOf(cliBody, "awaitLoaded(pid, reaped, diagnostics, fifo)") == 1,
        "CLI readiness wiring: runCli must call awaitLoaded before process observation");
}
