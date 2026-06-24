// Focused tests for the live-capture sink (task 0027): disabled-path inertness,
// enabled buffered append, flush-on-close completeness, reopen/append, and a
// full sink -> file -> parse -> export label-coverage pass. Sibling form
// (`void main(){}` + `unittest`, import `ai.*`). Harness:
//
//   ./run_test.d test_ai_interaction_log_writer
//
// Standalone (mirror sibling flags, keep -I=tests):
//
//   dmd -unittest -i -J=tests -Isource -I=tests -run \
//       tests/test_ai_interaction_log_writer.d
import std.file : exists, tempDir, remove, readText;
import std.path : buildPath;
import std.string : split, strip, startsWith;
import std.conv : to;

import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase, AiIntent;
import ai.interaction_log : AiInteractionLogRecord, makeAiInteractionLogRecord,
    parseAiInteractionLogLine;
import ai.interaction_log_writer : AiInteractionLogWriter, defaultLiveSource;
import ai.element_candidates : collectElementCandidates,
    resolveElementCandidateDecision;
import ai.training_dataset : exportAiTrainingDatasetJsonl;

void main() {}

private AiInteractionLogRecord elementRecord(int vertex) {
    auto candidates = collectElementCandidates(10, 20, vertex, -1, -1);
    auto resolution = resolveElementCandidateDecision(candidates);
    AiInteractionContext ctx;
    ctx.phase = AiInteractionPhase.mouseDown;
    ctx.defaultIntent = AiIntent.selectElement;
    ctx.mouseX = 10;
    ctx.mouseY = 20;
    ctx.editModeId = "vertices";
    return makeAiInteractionLogRecord(defaultLiveSource(), "elements", ctx,
                                      candidates, resolution.advisor,
                                      resolution.appliedWinnerIndex);
}

private size_t countLines(string text) {
    size_t n;
    foreach (line; text.split("\n"))
        if (line.strip.length)
            ++n;
    return n;
}

private string uniquePath(string stem) {
    import std.process : thisProcessID;
    return buildPath(tempDir(),
        "vibe3d_ai_log_" ~ stem ~ "_" ~ thisProcessID().to!string ~ ".jsonl");
}

// D forbids a try/catch lexically inside scope(exit); wrap removal here.
private void cleanup(string path) {
    try { remove(path); } catch (Exception) {}
}

// Disabled writer (empty path) creates no file and append is a no-op.
unittest {
    auto path = uniquePath("disabled");
    if (exists(path)) remove(path);

    auto writer = new AiInteractionLogWriter("");
    assert(!writer.enabled);
    writer.append(elementRecord(1));   // must not create `path` or any file
    writer.flush();
    writer.close();
    assert(!exists(path));
}

// fromEnv with an explicit CLI override path enables the writer; lines land.
unittest {
    auto path = uniquePath("fromenv");
    if (exists(path)) remove(path);
    scope(exit) cleanup(path);

    auto writer = AiInteractionLogWriter.fromEnv(path);
    assert(writer.enabled);
    writer.append(elementRecord(2));
    writer.close();   // flush-on-close
    assert(exists(path));
    assert(countLines(readText(path)) == 1);
}

// Enabled writer: N parseable lines, each live-session tagged with assigned
// sequence + timestamp; flush-on-close loses nothing; reopen accumulates.
unittest {
    auto path = uniquePath("append");
    if (exists(path)) remove(path);
    scope(exit) cleanup(path);

    auto writer = new AiInteractionLogWriter(path);
    assert(writer.enabled);
    enum N = 7;
    foreach (i; 0 .. N)
        writer.append(elementRecord(cast(int)i));
    writer.close();

    auto text = readText(path);
    assert(countLines(text) == N);
    ulong lastSeq = 0;
    foreach (line; text.split("\n")) {
        if (line.strip.length == 0) continue;
        auto rec = parseAiInteractionLogLine(line);
        assert(rec.source.startsWith("live-session"));
        assert(rec.hasSequence);
        assert(rec.hasTimestampUnixMs);
        assert(rec.sequence > lastSeq);   // monotonic
        lastSeq = rec.sequence;
    }

    // Reopen in append mode: no truncation, more lines accumulate.
    auto writer2 = new AiInteractionLogWriter(path);
    writer2.append(elementRecord(99));
    writer2.close();
    assert(countLines(readText(path)) == N + 1);
}

// E2E label coverage through the real file: write -> read file -> parse ->
// export. The parsed corpus must fully label.
unittest {
    auto path = uniquePath("e2e");
    if (exists(path)) remove(path);
    scope(exit) cleanup(path);

    string[] expectedIds;
    auto writer = new AiInteractionLogWriter(path);
    foreach (v; [3, 7, 11]) {
        auto rec = elementRecord(v);
        expectedIds ~= rec.appliedWinnerId;
        writer.append(rec);
    }
    writer.close();

    AiInteractionLogRecord[] parsed;
    foreach (line; readText(path).split("\n")) {
        if (line.strip.length == 0) continue;
        parsed ~= parseAiInteractionLogLine(line);
    }
    assert(parsed.length == expectedIds.length);

    auto result = exportAiTrainingDatasetJsonl(parsed);
    assert(result.stats.total == parsed.length);
    assert(result.stats.labeled == result.stats.total);   // coverage gate
    foreach (i, ref p; parsed)
        assert(p.appliedWinnerId == expectedIds[i]);
}
