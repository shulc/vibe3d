// W15-B: keep the WebAssembly perf-probe seam free of native thread imports.
module tests.unit.thread_seam_census_perf_test;

import std.algorithm : canFind, count;
import std.file : exists, readText;
import std.format : format;
import std.path : buildPath, dirName;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    immutable string[] subjects = ["perf_probe"];
    string[] subjectTexts;
    foreach (subject; subjects) {
        const path = buildPath(repoRoot, "source", subject ~ ".d");
        if (exists(path)) subjectTexts ~= readText(path);
    }

    assert(subjects.length == 1,
           format("W15-B perf thread-seam subject population changed: expected 1, got %d",
                  subjects.length));
    assert(subjectTexts.length > 0,
           "W15-B perf thread-seam census found zero subject files");
    assert(subjectTexts.length == subjects.length,
           format("W15-B perf thread-seam scan area changed: expected %d files, found %d",
                  subjects.length, subjectTexts.length));

    // This legal native carrier is deliberately outside the subject set. If
    // it loses the token, move all four thread-census positive controls.
    const carrier = readText(buildPath(repoRoot, "source", "subpatch_worker.d"));
    immutable rawHits = count(carrier, "core.thread");
    assert(rawHits > 0,
           "W15-B positive control lost core.thread in source/subpatch_worker.d; " ~
           "move the four thread-census controls instead of weakening them");

    enum kTokenInUnittest = "module m;\nunittest\n{\n    import core.thread : Thread;\n}\n";
    enum kTokenAtModule = "module m;\nimport core.thread : Thread;\nunittest { }\n";
    assert(!blankUnittestBodies(blankNonCode(kTokenInUnittest)).canFind("core.thread"),
           "W15-B predicate does not blank an in-module unittest block");
    assert(blankUnittestBodies(blankNonCode(kTokenAtModule)).canFind("core.thread"),
           "W15-B predicate blanks too much; the stationary census would be vacuous");

    enum kNested = "module m;\nunittest\n{\n    auto f = () { return 1; };\n}\n" ~
                   "import core.thread : Thread;\n";
    assert(blankUnittestBodies(blankNonCode(kNested)).canFind("core.thread"),
           "W15-B unittest blanking consumed code after a nested-brace block");

    string[] forbidden;
    foreach (i, text; subjectTexts) {
        if (blankUnittestBodies(blankNonCode(text)).canFind("core.thread"))
            forbidden ~= subjects[i];
    }
    assert(forbidden.length == 0,
           format("W15-B perf thread seam: %s still name core.thread; subjects=%s. " ~
                  "Mutation expected here as [\"perf_probe\"]: restore " ~
                  "`import core.thread.osthread : Thread;` in currentThreadId().",
                  forbidden, subjects));
}
