// The command-record class census for task 4570. The module name
// `command_record_class_census_test` is project-owned: an exact `grep -rl -w`
// over the SDK tree returned zero files before this test was added.
//
// This census is a closed allowlist of the concrete sites that may append to or
// rewrite command history. Each row names its enclosing symbol and primitive;
// adding a writer therefore requires an explicit classification here instead
// of inheriting permission from a familiar method spelling. In particular, the
// LayerAdd built by `/api/test/layer` must cross CommandExecutor instead of
// becoming a second apply+record implementation beside it.
module tests.unit.command_record_class_census_test;

import std.algorithm : sort;
import std.conv : to;
import std.file : dirEntries, exists, readText, SpanMode;
import std.path : buildPath, dirName, relativePath;

import tests.unit.census_symbols : LedgerHit, LedgerRow, blankNonCode,
    historySurface, reconcile, symbolTokenHits;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private enum LedgerRow[] kResidue = [
    LedgerRow("CommandExecutor.applyOrRefire|record", 1,
        "ordinary Command — the sole generic apply/fire/history executor"),
    LedgerRow("CommandExecutor.applyOrRefire|recordCoalescing", 1,
        "ordinary Command — the coalescing mode of the same executor"),
    LedgerRow("Tool.recordGestureEdit|record", 1,
        "GesturePayload — Tool validates the carrier before recording"),
    LedgerRow("Tool.recordGestureEdit|recordInSession", 1,
        "GesturePayload — the in-session gesture writer at source/tool.d:699"),
    LedgerRow("Tool.recordGestureEdit|replaceInSessionTailWith", 1,
        "GesturePayload — the run-tail gesture writer at source/tool.d:702"),
    LedgerRow("TransformTool.recordCommit|record", 1,
        "transform gesture edit — the deliberately unmigrated task-1905 zone"),
    LedgerRow("TransformTool.recordCommit|recordInSession", 1,
        "transform gesture edit — the in-session writer at "
      ~ "source/tools/transform/transform.d:854"),
    LedgerRow("XfrmTransformTool.recordPipeRefire|replaceInSessionTail", 1,
        "transform re-grade — the task-1905 run-tail replacement at "
      ~ "source/tools/transform/xfrm_transform.d:7207"),
    LedgerRow("InputRouter.commitInteractiveSelEdit|recordCoalescing", 1,
        "MeshSelectionEdit — the UI-selection undo class"),
];

// Test-only vocabulary, not a product API: an exact `grep -rl -w` for
// `isWritingPrimitive` in the SDK tree returned zero files. This partitions
// CommandHistory's call surface by EFFECT; the allowlist above names the sites.
private bool isWritingPrimitive(string name) {
    switch (name) {
        case "record":
        case "recordInSession":
        case "recordCoalescing":
        case "recordToolLifecycle":
        case "replaceInSessionTail":
        case "replaceInSessionTailWith":
            return true;
        default:
            return false;
    }
}

unittest {
    string[] population;
    immutable sourceRoot = buildPath(repoRoot, "source");
    assert(exists(sourceRoot),
        "command-record class census: source population root is missing");
    foreach (e; dirEntries(sourceRoot, "*.d", SpanMode.depth))
        population ~= relativePath(e.name, repoRoot);
    population.sort();
    assert(population.length > 100,
        "command-record class census: source population is implausibly small: "
        ~ population.length.to!string);

    LedgerHit[] records;
    LedgerHit[] layerClass;
    LedgerHit[] layerDispatch;
    foreach (rel; population) {
        auto code = blankNonCode(readText(buildPath(repoRoot, rel)));
        foreach (h; historySurface(code)) {
            if (!isWritingPrimitive(h.name)) continue;
            records ~= LedgerHit(h.symbol ~ "|" ~ h.name, rel, h.line,
                "history." ~ h.name ~ "(");
        }
        layerClass ~= symbolTokenHits(code, rel,
            "cast(LayerAdd)", "LayerAdd-class");
        layerDispatch ~= symbolTokenHits(code, rel,
            "executor.applyOrRefire(cmd, RecordMode.Record", "LayerAdd-executor");
    }
    assert(records.length == 9,
        "command-record class census: expected nine allowlisted direct record "
        ~ "sites, found " ~ records.length.to!string);
    foreach (record; records)
        assert(record.key !=
               "wireMutationHandlers.setInjectLayerHandler|record",
            "command-record class census: LayerAdd gained a direct history "
            ~ "writer outside CommandExecutor at " ~ record.file ~ ":"
            ~ record.line.to!string);
    auto problems = reconcile(kResidue, records);
    assert(problems.length == 0,
        "command-record class census: an unclassified writer may be a second "
        ~ "generic command executor.\n" ~ problems);

    assert(layerClass.length == 1 &&
           layerClass[0].key ==
               "wireMutationHandlers.setInjectLayerHandler|LayerAdd-class",
        "LayerAdd class witness moved out of wireMutationHandlers: "
        ~ (layerClass.length ? layerClass[0].key : "no hit"));
    assert(layerDispatch.length == 1 &&
           layerDispatch[0].key ==
               "wireMutationHandlers.setInjectLayerHandler|LayerAdd-executor",
        "LayerAdd must cross CommandExecutor exactly once: "
        ~ (layerDispatch.length ? layerDispatch[0].key : "no hit"));
}
