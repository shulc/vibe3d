// Closed-set censuses for the document-replace disarm seam (task 3930).
// Behavioural coverage lives in tests/test_disarm_census.d; this module keeps
// the mechanism single-sourced and forces every prose claim about it to be
// read when it changes. The undo/revert path is deliberately absent: task
// 4010 owns SessionMeshKey/resyncSession because calling this seam re-entrantly
// from CommandHistory.undo() would violate keep-alive and can nest undo.
module tests.unit.document_replace_disarm_census_test;

import std.algorithm : canFind, count;
import std.array : appender;
import std.file : dirEntries, exists, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName;
import std.string : indexOf, splitLines, strip;

import tests.unit.census_symbols : blankNonCode, blankUnittestBodies,
    enclosingSymbols, symbolAt, LedgerRow, LedgerHit, reconcile;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private immutable string[] kCodeIdents = [
    "disarmActiveToolBeforeDocumentReplace",
    "dropActiveToolBeforePrimaryMove",
    "g_disarmActiveTool",
    "g_disarmCrossings",
    "dropsActiveToolBeforeApply",
    "commandDropsToolBeforeApply",
];

private immutable string[] kCommentWords = [
    "disarmActiveToolBeforeDocumentReplace",
    "tool_disarm",
    "dropArmedPreview",
    "onResetTool",
];

private enum string kLayerAttrLiteral = `"layer.attr"`;

private immutable LedgerRow[] kCodeSites = [
    LedgerRow("main.applyOrRefire|dropsActiveToolBeforeApply", 1,
        "the single command-funnel policy call"),
    LedgerRow("main|g_disarmActiveTool", 2,
        "the app-side hook assignment and its delegate target"),
    LedgerRow("(module scope)|dropsActiveToolBeforeApply", 1,
        "the sole definition of the pre-apply policy"),
    LedgerRow("FileLoad.applyImpl|disarmActiveToolBeforeDocumentReplace", 4,
        "import plus call in each of the native and interchange branches"),
    LedgerRow("LayerSelect.mutateGuardingPrimary|dropActiveToolBeforePrimaryMove", 2,
        "the guarded-primary wrapper's import and call"),
    LedgerRow("MeshLoadRaw.applyImpl|disarmActiveToolBeforeDocumentReplace", 2,
        "the validated load-mesh import and call"),
    LedgerRow("SceneReset.applyImpl|disarmActiveToolBeforeDocumentReplace", 2,
        "the reset import and call"),
    LedgerRow("HttpServer.route_apiToolDisarm|g_disarmCrossings", 2,
        "the /api/tool/disarm import and read"),
    LedgerRow("Registry.cacheSupportedModes|dropsActiveToolBeforeApply", 2,
        "the registry-cache import and evaluation"),
    LedgerRow("Registry|commandDropsToolBeforeApply", 1, "cache declaration"),
    LedgerRow("Registry.cacheSupportedModes|commandDropsToolBeforeApply", 1, "cache fill"),
    LedgerRow("Registry.registryJson|commandDropsToolBeforeApply", 1, "JSON publication"),
    LedgerRow("(module scope)|g_disarmActiveTool", 1, "hook declaration"),
    LedgerRow("disarmActiveToolBeforeDocumentReplace|g_disarmActiveTool", 2,
        "the seam's presence check and invocation"),
    LedgerRow("(module scope)|g_disarmCrossings", 1, "counter declaration"),
    LedgerRow("disarmActiveToolBeforeDocumentReplace|g_disarmCrossings", 1, "counter increment"),
    LedgerRow("(module scope)|disarmActiveToolBeforeDocumentReplace", 1, "seam definition"),
    LedgerRow("dropActiveToolBeforePrimaryMove|disarmActiveToolBeforeDocumentReplace", 1,
        "the primary-move wrapper's call"),
    LedgerRow("(module scope)|dropActiveToolBeforePrimaryMove", 1,
        "the primary-move wrapper definition"),

    LedgerRow("classifyNamespace|" ~ kLayerAttrLiteral, 1,
        "namespace routing, not tool-drop policy"),
    LedgerRow("registerItemCommands|" ~ kLayerAttrLiteral, 1,
        "command registration, not tool-drop policy"),
    LedgerRow("LayerAttr|" ~ kLayerAttrLiteral, 1,
        "the command name definition, not tool-drop policy"),
    LedgerRow("dropsActiveToolBeforeApply|" ~ kLayerAttrLiteral, 1,
        "the one authoritative pre-apply exclusion"),
];

private immutable LedgerRow[] kCommentSites = [
    LedgerRow("main|onResetTool", 3,
        "read 2026-09-03; true: reset-pipeline callback contract"),
    LedgerRow("main|tool_disarm", 1,
        "read 2026-09-03; true: app-side seam wiring"),
    LedgerRow("MeshLoadRaw.applyImpl|onResetTool", 1,
        "read 2026-09-03; true: names the former late callback after the seam"),
    LedgerRow("SceneReset|onResetTool", 1, "read 2026-09-03; true: member contract"),
    LedgerRow("SceneReset.applyImpl|onResetTool", 1, "read 2026-09-03; true: late teardown"),
    LedgerRow("SceneReset.applyImpl|tool_disarm", 1,
        "read 2026-09-03; true: points to the shared measurement"),
    LedgerRow("registerFileCommands.SceneReset|onResetTool", 1,
        "read 2026-09-03; true: defensive reset callback after the main seam"),
    LedgerRow("registerFileCommands.SceneReset|dropArmedPreview", 1,
        "read 2026-09-03; true: defensive fallback, not the main mechanism"),
    LedgerRow("(module scope).meshReplacement|onResetTool", 1,
        "read 2026-09-03; true: historical reproduction before the seam"),
    LedgerRow("(module scope).primaryIdentity|onResetTool", 1,
        "read 2026-09-03; true: historical identity-key failure analysis"),
    LedgerRow("EdgeSliceTool|dropArmedPreview", 2,
        "read 2026-09-03; true: chain cleanup and the remaining reset path"),
    LedgerRow("(module scope)|dropArmedPreview", 1, "read 2026-09-03; true: reset path"),
    LedgerRow("LoopSliceTool.deactivate|dropArmedPreview", 1, "read 2026-09-03; true: deactivate cleanup"),
    LedgerRow("LoopSliceTool|onResetTool", 1,
        "read 2026-09-03; true: defensive reset callback after the main seam"),
];

private bool isIdentChar(char c) {
    return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
        || c >= '0' && c <= '9' || c == '_';
}

private size_t countIdent(string line, string ident) {
    if (ident.length == 0 || ident.length > line.length) return 0;
    size_t n;
    foreach (i; 0 .. line.length - ident.length + 1)
        if (line[i .. i + ident.length] == ident
            && (i == 0 || !isIdentChar(line[i - 1]))
            && (i + ident.length == line.length
                || !isIdentChar(line[i + ident.length]))) ++n;
    return n;
}

private struct Hit {
    string file;
    string symbol;
    string ident;
    size_t line;
    string text;
}

private Hit[] scanCode(string file, string src) {
    auto hits = appender!(Hit[]);
    const code = blankUnittestBodies(blankNonCode(src));
    const symbols = enclosingSymbols(code);
    foreach (li, line; code.splitLines()) foreach (ident; kCodeIdents) {
        foreach (_; 0 .. countIdent(line, ident))
            hits.put(Hit(file, symbolAt(symbols, li), ident, li + 1, line.strip));
    }
    const production = blankUnittestBodies(src);
    foreach (li, line; production.splitLines())
        foreach (_; 0 .. count(line, kLayerAttrLiteral))
            hits.put(Hit(file, symbolAt(symbols, li), kLayerAttrLiteral,
                         li + 1, line.strip));
    return hits.data;
}

private Hit[] scanComments(string file, string src) {
    auto hits = appender!(Hit[]);
    const code = blankUnittestBodies(blankNonCode(src));
    const marks = blankUnittestBodies(blankNonCode(src, true));
    const symbols = enclosingSymbols(code);
    auto codeLines = code.splitLines;
    foreach (li, line; marks.splitLines()) foreach (ident; kCommentWords) {
        const marked = countIdent(line, ident);
        const coded = countIdent(codeLines[li], ident);
        foreach (_; 0 .. marked - coded)
        {
            string symbol = symbolAt(symbols, li);
            if (symbol == "(module scope)" && ident == "onResetTool")
                symbol ~= line.canFind("primary layer")
                    ? ".primaryIdentity" : ".meshReplacement";
            hits.put(Hit(file, symbol, ident, li + 1, line.strip));
        }
    }
    return hits.data;
}

private Hit[] scanTree(bool comments) {
    auto hits = appender!(Hit[]);
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        const file = de.name[repoRoot.length + 1 .. $];
        const src = readText(de.name);
        hits.put(comments ? scanComments(file, src) : scanCode(file, src));
    }
    return hits.data;
}

private string compareSites(const LedgerRow[] rows, const Hit[] hits,
                            out size_t recordedTotal) {
    LedgerHit[] ledgerHits;
    foreach (ref hit; hits)
        ledgerHits ~= LedgerHit(hit.symbol ~ "|" ~ hit.ident,
                                hit.file, hit.line, hit.text);
    foreach (ref row; rows) {
        recordedTotal += row.count;
        assert(row.count > 0, "census rows must never record zero occurrences");
    }
    return reconcile(rows, ledgerHits);
}

unittest {
    enum probe = q"PROBE
        // dropArmedPreview and tool_disarm are prose.
        void f() { dropActiveToolBeforePrimaryMove(); }
        enum n = "layer.attr";
        unittest { disarmActiveToolBeforeDocumentReplace(); }
PROBE";
    auto code = scanCode("probe.d", probe);
    auto comments = scanComments("probe.d", probe);
    assert(code.length == 2,
        format("scanner must see one code name and one literal, got %s", code));
    assert(comments.length == 2,
        format("scanner must see two comment words, got %s", comments));
}

// K8 / C-B: mechanism identifiers and the policy literal are a closed set.
unittest {
    auto hits = scanTree(false);
    size_t recorded;
    const bad = compareSites(kCodeSites, hits, recorded);
    assert(bad.length == 0, format(
        "task 3930: document-replace disarm CODE census changed.%s\n"
      ~ "Recorded %d occurrences in %d rows; scanner found %d. A new seam "
      ~ "caller or a second copy of the pre-apply policy needs an explicit "
      ~ "decision and a table row.",
        bad, recorded, kCodeSites.length, hits.length));
    assert(hits.length >= 30,
        format("document-replace disarm code census collapsed to %d hits",
            hits.length));
}

// K9 / C-C: a new prose claim is a mandatory review, not silent documentation.
unittest {
    auto hits = scanTree(true);
    size_t recorded;
    const bad = compareSites(kCommentSites, hits, recorded);
    assert(bad.length == 0, format(
        "task 3930: document-replace disarm COMMENT census changed.%s\n"
      ~ "Recorded %d checked comments in %d rows; scanner found %d. Read every "
      ~ "new or moved claim and record whether it is true today.",
        bad, recorded, kCommentSites.length, hits.length));
    assert(hits.length >= 12,
        format("document-replace disarm comment census collapsed to %d hits",
            hits.length));
}
