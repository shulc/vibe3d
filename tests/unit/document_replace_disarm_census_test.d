// Closed-set censuses for the document-replace disarm seam (task 3930).
// Behavioural coverage lives in tests/test_disarm_census.d; this module keeps
// the mechanism single-sourced and forces every prose claim about it to be
// read when it changes. The undo/revert path is deliberately absent: task
// 4010 owns SessionMeshKey/resyncSession because calling this seam re-entrantly
// from CommandHistory.undo() would violate keep-alive and can nest undo.
module tests.unit.document_replace_disarm_census_test;

import std.algorithm : count;
import std.array : appender;
import std.file : dirEntries, exists, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName;
import std.string : indexOf, splitLines, strip;

import tests.unit.version_poll_census_test : blankNonCode, blankUnittestBodies;

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

private struct SiteRow {
    string file;
    string ident;
    size_t count;
    string why;
}

private immutable SiteRow[] kCodeSites = [
    SiteRow("source/app.d", "dropsActiveToolBeforeApply", 1,
        "the single command-funnel policy call"),
    SiteRow("source/app.d", "g_disarmActiveTool", 2,
        "the app-side hook assignment and its delegate target"),
    SiteRow("source/command.d", "dropsActiveToolBeforeApply", 1,
        "the sole definition of the pre-apply policy"),
    SiteRow("source/commands/file/load.d",
        "disarmActiveToolBeforeDocumentReplace", 4,
        "import plus call in each of the native and interchange branches"),
    SiteRow("source/commands/layer/commands.d",
        "dropActiveToolBeforePrimaryMove", 2,
        "the guarded-primary wrapper's import and call"),
    SiteRow("source/commands/scene/load_mesh.d",
        "disarmActiveToolBeforeDocumentReplace", 2,
        "the validated load-mesh import and call"),
    SiteRow("source/commands/scene/reset.d",
        "disarmActiveToolBeforeDocumentReplace", 2,
        "the reset import and call"),
    SiteRow("source/http_server.d", "g_disarmCrossings", 2,
        "the /api/tool/disarm import and read"),
    SiteRow("source/registry.d", "dropsActiveToolBeforeApply", 2,
        "the registry-cache import and evaluation"),
    SiteRow("source/registry.d", "commandDropsToolBeforeApply", 3,
        "the cache declaration, fill and JSON publication"),
    SiteRow("source/tool_disarm.d", "g_disarmActiveTool", 3,
        "hook declaration plus the seam's presence check and invocation"),
    SiteRow("source/tool_disarm.d", "g_disarmCrossings", 2,
        "counter declaration and increment"),
    SiteRow("source/tool_disarm.d",
        "disarmActiveToolBeforeDocumentReplace", 2,
        "the seam definition and the primary-move wrapper's call"),
    SiteRow("source/tool_disarm.d", "dropActiveToolBeforePrimaryMove", 1,
        "the primary-move wrapper definition"),

    SiteRow("source/forms.d", kLayerAttrLiteral, 1,
        "namespace routing, not tool-drop policy"),
    SiteRow("source/registration.d", kLayerAttrLiteral, 1,
        "command registration, not tool-drop policy"),
    SiteRow("source/commands/layer/commands.d", kLayerAttrLiteral, 1,
        "the command name definition, not tool-drop policy"),
    SiteRow("source/command.d", kLayerAttrLiteral, 1,
        "the one authoritative pre-apply exclusion"),
];

private immutable SiteRow[] kCommentSites = [
    SiteRow("source/app.d", "onResetTool", 3,
        "read 2026-09-03; true: reset-pipeline callback contract"),
    SiteRow("source/app.d", "tool_disarm", 1,
        "read 2026-09-03; true: app-side seam wiring"),
    SiteRow("source/commands/scene/load_mesh.d", "onResetTool", 1,
        "read 2026-09-03; true: names the former late callback after the seam"),
    SiteRow("source/commands/scene/reset.d", "onResetTool", 2,
        "read 2026-09-03; true: member plus historical late-teardown explanation"),
    SiteRow("source/commands/scene/reset.d", "tool_disarm", 1,
        "read 2026-09-03; true: points to the shared measurement"),
    SiteRow("source/registration.d", "onResetTool", 1,
        "read 2026-09-03; true: defensive reset callback after the main seam"),
    SiteRow("source/registration.d", "dropArmedPreview", 1,
        "read 2026-09-03; true: defensive fallback, not the main mechanism"),
    SiteRow("source/tool_disarm.d", "onResetTool", 1,
        "read 2026-09-03; true: historical reproduction before the seam"),
    SiteRow("source/tools/common/session_mesh_key.d", "onResetTool", 1,
        "read 2026-09-03; true: historical identity-key failure analysis"),
    SiteRow("source/tools/slice/edge_slice_tool.d", "dropArmedPreview", 2,
        "read 2026-09-03; true: chain cleanup and the remaining reset path"),
    SiteRow("source/tools/slice/loop_slice_tool.d", "dropArmedPreview", 2,
        "read 2026-09-03; true: remaining reset path and deactivate cleanup"),
    SiteRow("source/tools/slice/loop_slice_tool.d", "onResetTool", 1,
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
    string ident;
    size_t line;
    string text;
}

private Hit[] scanCode(string file, string src) {
    auto hits = appender!(Hit[]);
    const code = blankUnittestBodies(blankNonCode(src));
    foreach (li, line; code.splitLines()) foreach (ident; kCodeIdents) {
        foreach (_; 0 .. countIdent(line, ident))
            hits.put(Hit(file, ident, li + 1, line.strip));
    }
    const production = blankUnittestBodies(src);
    foreach (li, line; production.splitLines())
        foreach (_; 0 .. count(line, kLayerAttrLiteral))
            hits.put(Hit(file, kLayerAttrLiteral, li + 1, line.strip));
    return hits.data;
}

private Hit[] scanComments(string file, string src) {
    auto hits = appender!(Hit[]);
    const code = blankUnittestBodies(blankNonCode(src));
    const marks = blankUnittestBodies(blankNonCode(src, true));
    auto codeLines = code.splitLines;
    foreach (li, line; marks.splitLines()) foreach (ident; kCommentWords) {
        const marked = countIdent(line, ident);
        const coded = countIdent(codeLines[li], ident);
        foreach (_; 0 .. marked - coded)
            hits.put(Hit(file, ident, li + 1, line.strip));
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

private string compareSites(const SiteRow[] rows, const Hit[] hits,
                            out size_t recordedTotal) {
    size_t[string] found;
    foreach (ref hit; hits)
        ++found[hit.file ~ "|" ~ hit.ident];
    auto bad = appender!string;

    void dump(string file, string ident) {
        foreach (ref hit; hits)
            if (hit.file == file && hit.ident == ident)
                bad.put(format("\n        found %s:%d %s",
                    hit.file, hit.line, hit.text));
    }

    foreach (ref row; rows) {
        recordedTotal += row.count;
        assert(row.count > 0, "census rows must never record zero occurrences");
        assert(buildPath(repoRoot, row.file).exists, format(
            "%s records `%s` in vanished file %s",
            __MODULE__, row.ident, row.file));
        const n = found.get(row.file ~ "|" ~ row.ident, 0);
        if (n == row.count) continue;
        bad.put(format("\n    %s — `%s`: recorded %d, found %d; why: %s",
            row.file, row.ident, row.count, n, row.why));
        dump(row.file, row.ident);
    }

    foreach (key, n; found) {
        bool recorded;
        foreach (ref row; rows)
            if (row.file ~ "|" ~ row.ident == key) { recorded = true; break; }
        if (recorded) continue;
        const split = key.indexOf('|');
        bad.put(format("\n    %s — `%s`: NOT RECORDED, found %d",
            key[0 .. split], key[split + 1 .. $], n));
        dump(key[0 .. split], key[split + 1 .. $]);
    }
    return bad.data;
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
