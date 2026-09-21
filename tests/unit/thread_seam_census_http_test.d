module tests.unit.thread_seam_census_http_test;

import std.file : readText;
import std.format : format;
import std.path : buildPath, dirName;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private bool isIdentStart(char c) pure nothrow @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isIdentRest(char c) pure nothrow @safe
{
    return isIdentStart(c) || (c >= '0' && c <= '9');
}

// Count the identifier sequence, not one punctuation spelling. That covers
// module imports, selective imports and qualified uses without a formatting
// loophole, including occurrences inside block-bodied lambdas.
private size_t coreThreadHits(string code) pure nothrow @safe
{
    string previous;
    size_t hits;
    size_t i;
    while (i < code.length) {
        if (!isIdentStart(code[i])) {
            ++i;
            continue;
        }
        immutable begin = i++;
        while (i < code.length && isIdentRest(code[i])) ++i;
        const token = code[begin .. i];
        if (previous == "core" && token == "thread") ++hits;
        previous = token;
    }
    return hits;
}

unittest
{
    enum subjects = ["source/http_server.d"];
    enum transportPath = "source/http_transport.d";
    enum foreignCarrierPath = "source/subpatch_worker.d";

    const routerRaw = readText(buildPath(repoRoot, subjects[0]));
    const transportRaw = readText(buildPath(repoRoot, transportPath));
    const foreignRaw = readText(buildPath(repoRoot, foreignCarrierPath));
    immutable scanned = subjects.length + 2;

    // 1. Population floor: all three named areas were actually read and the
    // subject set cannot silently become empty or grow.
    assert(scanned == 3 && subjects.length == 1,
        format("W15-E HTTP thread-seam census area changed: scanned %d files, "
             ~ "subject population %d (expected 3 and 1)",
               scanned, subjects.length));

    // 2. Positive needles. The foreign file is the wave-wide independent
    // control; the other two are W15-E's legal carriers (native transport and
    // the router's in-module route witness). If the worker loses its token,
    // all four wave-15 controls must move rather than deleting this assertion.
    immutable foreignRawHits = coreThreadHits(blankNonCode(foreignRaw));
    immutable transportRawHits = coreThreadHits(blankNonCode(transportRaw));
    immutable routerRawHits = coreThreadHits(blankNonCode(routerRaw));
    assert(foreignRawHits > 0 && transportRawHits > 0 && routerRawHits > 0,
        format("W15-E core.thread needle lost a legal carrier: worker=%d, "
             ~ "transport=%d, router-unittest=%d",
               foreignRawHits, transportRawHits, routerRawHits));

    // 3. Structural self-test of the narrowing predicate. These fixtures pin
    // both directions, nested braces, code after a unittest, and every token
    // spelling the identifier scanner promises to accept.
    enum tokenInUnittest = "module m;\nunittest\n{\n"
        ~ "    import core.thread : Thread;\n}\n";
    enum tokenAtModule = "module m;\nimport core.thread : Thread;\n"
        ~ "unittest { }\n";
    enum nested = "module m;\nunittest\n{\n"
        ~ "    auto f = () { return 1; };\n}\n"
        ~ "import core.thread : Thread;\n";
    enum spellings = "import core.thread;\n"
        ~ "import core /* gap */ . thread : Thread;\n"
        ~ "auto t = core.thread.Thread.getThis();\n"
        ~ "// core.thread\nstring s = `core.thread`;\n";
    assert(coreThreadHits(blankUnittestBodies(blankNonCode(tokenInUnittest))) == 0
        && coreThreadHits(blankUnittestBodies(blankNonCode(tokenAtModule))) == 1
        && coreThreadHits(blankUnittestBodies(blankNonCode(nested))) == 1
        && coreThreadHits(blankNonCode(spellings)) == 3,
        "W15-E predicate must blank exactly in-module unittest bodies, match "
        ~ "nested braces, preserve following code, and count all identifier spellings");

    // 4. Stationary pin. This is TRUE on the correct tree. The expected
    // mutation belongs in the message: restoring a module-level import in the
    // router must make this assertion report [\"http_server\"].
    string[] forbidden;
    foreach (subject; subjects) {
        const raw = readText(buildPath(repoRoot, subject));
        const code = blankUnittestBodies(blankNonCode(raw));
        if (coreThreadHits(code) != 0) forbidden ~= "http_server";
    }
    assert(forbidden.length == 0,
        format("W15-E HTTP router still names core.thread outside its legal "
             ~ "in-module unittest: forbidden=%s subjects=%s. MUTATION that "
             ~ "must report [\"http_server\"] here: restore `import "
             ~ "core.thread;` at module scope in source/http_server.d.",
               forbidden, subjects));
}
