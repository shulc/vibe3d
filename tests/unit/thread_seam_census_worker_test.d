module tests.unit.thread_seam_census_worker_test;

import std.algorithm : canFind;
import std.file : exists, readText;
import std.format : format;
import std.path : buildPath, dirName;
import std.string : indexOf;

import subpatch_osd : CageSnapshot, OsdAccel, PreviewBuildResult;
import subpatch_worker_web : SubpatchWorker;
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

private size_t coreThreadHits(string code) pure nothrow @safe
{
    string previous;
    size_t hits;
    size_t i;
    while (i < code.length)
    {
        if (!isIdentStart(code[i]))
        {
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
    immutable string[] subjects = ["subpatch_worker_web"];
    string[] subjectTexts;
    foreach (subject; subjects)
    {
        const path = buildPath(repoRoot, "source", subject ~ ".d");
        if (exists(path)) subjectTexts ~= readText(path);
    }

    const nativeRaw = readText(
        buildPath(repoRoot, "source", "subpatch_worker.d"));
    const previewRaw = readText(
        buildPath(repoRoot, "source", "subpatch_preview.d"));
    const providersRaw = readText(
        buildPath(repoRoot, "source", "http_providers.d"));
    const appRaw = readText(buildPath(repoRoot, "source", "app.d"));
    immutable scanned = subjectTexts.length + 3;

    assert(subjects.length == 1 && subjectTexts.length == subjects.length
            && scanned == 4,
        format("W15-C worker thread-seam census area changed: expected one "
             ~ "web subject and four scanned files, got subjects=%d, files=%d",
               subjects.length, scanned));

    immutable rawHits = coreThreadHits(blankNonCode(nativeRaw));
    assert(rawHits > 0,
        "W15-C positive control lost core.thread in source/subpatch_worker.d; "
        ~ "move all four wave-15 thread-census controls instead of weakening it");
    assert(nativeRaw.canFind(
            "@property bool supportsReceptionHold() const pure nothrow @nogc {\n"
            ~ "        return true;\n    }"),
        "W15-C native backend must retain its real reception-hold window");

    enum tokenInUnittest = "module m;\nunittest\n{\n"
        ~ "    import core.thread : Thread;\n}\n";
    enum tokenAtModule = "module m;\nimport core.thread : Thread;\n"
        ~ "unittest { }\n";
    enum nested = "module m;\nunittest\n{\n"
        ~ "    auto f = () { return 1; };\n}\n"
        ~ "import core.thread : Thread;\n";
    assert(coreThreadHits(blankUnittestBodies(blankNonCode(tokenInUnittest))) == 0
            && coreThreadHits(blankUnittestBodies(blankNonCode(tokenAtModule))) == 1
            && coreThreadHits(blankUnittestBodies(blankNonCode(nested))) == 1,
        "W15-C predicate must blank exactly in-module unittest bodies and "
        ~ "preserve module code after nested braces");

    string[] forbidden;
    foreach (i, raw; subjectTexts)
    {
        const code = blankUnittestBodies(blankNonCode(raw));
        if (coreThreadHits(code) != 0) forbidden ~= subjects[i];
    }
    assert(forbidden.length == 0,
        format("W15-C web worker still names core.thread: forbidden=%s "
             ~ "subjects=%s. MUTATION must report "
             ~ "[\"subpatch_worker_web\"] here.", forbidden, subjects));

    assert(previewRaw.canFind(
            "version (web) {\n    import subpatch_worker_web;\n} else {\n"
            ~ "    import subpatch_worker;\n}"),
        "W15-C backend selection must keep both web and native imports at "
        ~ "the SubpatchPreview seam");
    assert(appRaw.canFind("subpatchPreview.enableBuildBackend();")
            && appRaw.canFind(
                "subpatchPreview.pumpBuildResult(mesh, subpatchDepth);")
            && previewRaw.canFind("worker = new SubpatchWorker();")
            && previewRaw.canFind("backendEnabled = true;")
            && previewRaw.canFind("requestBackendBuild(source, d);")
            && previewRaw.canFind(
                "if (!backendEnabled || worker is null) return false;")
            && previewRaw.canFind(
                "if (backendEnabled && worker !is null) {")
            && previewRaw.canFind(
                "worker.submit(&osdAccel, snap, buildGeneration, pendingKey);")
            && previewRaw.canFind("if (!worker.tryTake(res)) return false;"),
        "W15-C editor and preview must retain the selected backend's "
        ~ "dispatch/receive seam and both availability guards");
    assert(previewRaw.canFind(
                "return backendEnabled && worker !is null")
            && previewRaw.canFind("&& worker.supportsReceptionHold;"),
        "W15-C hold capability must require an installed, supporting backend");

    const keyBodyBegin = previewRaw.indexOf(
        "private ulong computeStencilKeyWeb");
    const keyBodyEnd = previewRaw.indexOf(
        "private ulong computeStencilKey(", keyBodyBegin + 1);
    assert(keyBodyBegin >= 0 && keyBodyEnd > keyBodyBegin,
        "W15-C could not isolate the wasm stencil-key helper body");
    const webKeyRaw = previewRaw[keyBodyBegin .. keyBodyEnd];
    assert(previewRaw.canFind("return computeStencilKeyWeb(source, d);"),
        "W15-C web build no longer selects the wasm stencil key");
    immutable string[] webKeyTerms = [
        "ulong h = hashOf(cast(size_t)&source)",
        "foldSubpatchKeyMember(h, source.topologyVersion)",
        "foldSubpatchKeyMember(h, d)",
        "foldSubpatchKeyMember(h, source.vertices.length)",
        "foldSubpatchKeyMember(h, source.faces.length)",
        "foldSubpatchKeyMember(h, source.edges.length)",
        "cast(uint)(m & (Mesh.Marks.Subpatch | Mesh.Marks.Hide))",
        "foldSubpatchKeyMember(h, cw.data)",
        "foldSubpatchKeyMember(h, 0xC1EA5E00u)",
        "return h == 0 ? 1 : h",
    ];
    foreach (term; webKeyTerms)
        assert(webKeyRaw.canFind(term),
            "W15-C wasm stencil key lost term: " ~ term);

    const webRaw = subjectTexts[0];
    immutable string[] mailboxTerms = [
        "assert(!resultReady_",
        "accel.buildFromSnapshot(*snap, res);",
        "result_ = res;",
        "resultReady_ = true;",
        "if (!resultReady_) return false;",
        "resultReady_ = false;",
    ];
    foreach (term; mailboxTerms)
        assert(webRaw.canFind(term),
            "W15-C synchronous mailbox lost contract term: " ~ term);
    assert(providersRaw.canFind("if (!subpatchPreview.supportsReceptionHold)")
            && providersRaw.canFind(
                "subpatch hold unavailable in the synchronous web backend"),
        "W15-C /api/subpatch/hold must refuse the synchronous web backend "
        ~ "with its named reason");
}

unittest
{
    auto backend = new SubpatchWorker();
    assert(!backend.supportsReceptionHold,
        "W15-C web backend must not advertise a reception window");
    assert(!backend.busy && !backend.resultWaiting && backend.waitIdle(0),
        "W15-C fresh synchronous backend must be idle with no result");

    OsdAccel accel;
    CageSnapshot snap;
    backend.submit(&accel, &snap, 7, 11);
    assert(!backend.busy && backend.resultWaiting && backend.waitIdle(0),
        "W15-C inline submit must publish one result without becoming busy");

    PreviewBuildResult result;
    assert(backend.tryTake(result),
        "W15-C synchronous mailbox did not publish its completed build");
    assert(result.generation == 7 && result.key == 11 && !result.ok,
        format("W15-C synchronous mailbox changed metadata/refusal: %s", result));
    assert(!backend.tryTake(result) && !backend.resultWaiting,
        "W15-C synchronous mailbox result must be one-shot");
    backend.shutdown(0);
}
