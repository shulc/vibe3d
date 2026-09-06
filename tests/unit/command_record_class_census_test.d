// The command-record class census for task 4570. The module name
// `command_record_class_census_test` is project-owned: an exact `grep -rl -w`
// over the SDK tree returned zero files before this test was added.
//
// This census does not ban `history.record` by spelling. It classifies every
// direct generic record site by the command class carried there: the shared
// executor owns ordinary Command records, Tool/Transform own gesture records,
// and InputRouter owns MeshSelectionEdit. In particular, the LayerAdd built by
// `/api/test/layer` must cross CommandExecutor instead of becoming a second
// apply+record implementation beside it.
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
    LedgerRow("TransformTool.recordCommit|record", 1,
        "transform gesture edit — the deliberately unmigrated task-1905 zone"),
    LedgerRow("InputRouter.commitInteractiveSelEdit|recordCoalescing", 1,
        "MeshSelectionEdit — the UI-selection undo class"),
];

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
    foreach (rel; population) {
        auto code = blankNonCode(readText(buildPath(repoRoot, rel)));
        foreach (h; historySurface(code)) {
            if (h.name != "record" && h.name != "recordCoalescing") continue;
            records ~= LedgerHit(h.symbol ~ "|" ~ h.name, rel, h.line,
                "history." ~ h.name ~ "(");
        }
    }
    foreach (record; records)
        assert(record.key !=
               "wireMutationHandlers.setInjectLayerHandler|record",
            "command-record class census: LayerAdd gained a direct history "
            ~ "writer outside CommandExecutor at " ~ record.file ~ ":"
            ~ record.line.to!string);
    assert(records.length == 5,
        "command-record class census: expected five classified direct record "
        ~ "sites, found " ~ records.length.to!string);
    auto problems = reconcile(kResidue, records);
    assert(problems.length == 0,
        "command-record class census: an unclassified writer may be a second "
        ~ "generic command executor.\n" ~ problems);

    immutable providersRel = "source/http_providers.d";
    auto providers = blankNonCode(readText(buildPath(repoRoot, providersRel)));
    auto layerClass = symbolTokenHits(providers, providersRel,
        "cast(LayerAdd)", "LayerAdd-class");
    assert(layerClass.length == 1 &&
           layerClass[0].key ==
               "wireMutationHandlers.setInjectLayerHandler|LayerAdd-class",
        "LayerAdd class witness moved out of wireMutationHandlers: "
        ~ (layerClass.length ? layerClass[0].key : "no hit"));
    auto layerDispatch = symbolTokenHits(providers, providersRel,
        "executor.applyOrRefire(cmd, RecordMode.Record", "LayerAdd-executor");
    assert(layerDispatch.length == 1 &&
           layerDispatch[0].key ==
               "wireMutationHandlers.setInjectLayerHandler|LayerAdd-executor",
        "LayerAdd must cross CommandExecutor exactly once: "
        ~ (layerDispatch.length ? layerDispatch[0].key : "no hit"));
}
