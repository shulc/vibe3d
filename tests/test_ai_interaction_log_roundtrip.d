// Focused tests for the interaction-log parser + the live-capture round-trip
// (task 0027). Sibling form (`void main(){}` + `unittest`, import `ai.*`) so
// run_test.d compiles it against the project and ./run_all.d runs it. Harness:
//
//   ./run_test.d test_ai_interaction_log_roundtrip
//
// Standalone (mirror the sibling flags exactly, keep -I=tests):
//
//   dmd -unittest -i -J=tests -Isource -I=tests -run \
//       tests/test_ai_interaction_log_roundtrip.d
import std.array : split;
import std.string : strip;

import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiElementCandidateKind, AiInteractionContext, AiInteractionPhase, AiIntent;
import ai.interaction_log : AiInteractionLogRecord, makeAiInteractionLogRecord,
    parseAiInteractionLogLine;
import ai.element_candidates : collectElementCandidates,
    resolveElementCandidateDecision;
import ai.training_dataset : exportAiTrainingDatasetJsonl;
import ai.ranker_schema : aiRankerLabelFromRecord;

void main() {}

// Build a representative element record exactly as the live element hook does:
// from a picked triple via collectElementCandidates + resolveElementCandidate-
// Decision (no advisor → applied == default winner = the picked element).
private AiInteractionLogRecord elementRecord(int vertex, int edge, int face) {
    auto candidates = collectElementCandidates(120, 240, vertex, edge, face);
    auto resolution = resolveElementCandidateDecision(candidates);
    AiInteractionContext ctx;
    ctx.phase = AiInteractionPhase.mouseDown;
    ctx.defaultIntent = AiIntent.selectElement;
    ctx.mouseX = 120;
    ctx.mouseY = 240;
    ctx.activeToolId = "move";
    ctx.editModeId = "vertices";
    return makeAiInteractionLogRecord("live-session:1", "elements", ctx,
                                      candidates, resolution.advisor,
                                      resolution.appliedWinnerIndex);
}

private AiCandidate handle(string id, AiIntent intent, int priority,
                           bool isDefault) {
    AiCandidate c;
    c.id = id;
    c.kind = AiCandidateKind.handle;
    c.intent = intent;
    c.priorityFromCurrentRules = cast(float)priority;
    c.isDefaultWinner = isDefault;
    c.hasScreenPosition = true;
    c.screenPosition = [120.0f, 240.0f];
    return c;
}

private AiInteractionLogRecord handleRecord() {
    AiCandidate[] candidates = [
        handle("handle:10", AiIntent.dragAxisX, 0, true),
        handle("handle:11", AiIntent.dragAxisY, 1, false),
    ];
    AiInteractionContext ctx;
    ctx.phase = AiInteractionPhase.mouseDown;
    ctx.mouseX = 120;
    ctx.mouseY = 240;
    ctx.activeToolId = "move";
    ctx.editModeId = "vertices";
    // Applied index 0 = default handle (no advisor override).
    return makeAiInteractionLogRecord("live-session:1", "handles", ctx,
                                      candidates, AiAdvisorDecision(), 0);
}

// Pure record-from-context+candidates+applied: the constructed element record
// labels itself with the picked element.
unittest {
    auto record = elementRecord(3, -1, -1);
    assert(record.groupId == "elements");
    assert(record.candidates.length == 1);
    assert(record.candidates[0].id == "element:vertex:3");
    assert(record.appliedWinnerId == "element:vertex:3");
    assert(record.appliedWinnerIndex == 0);
}

// Round-trip fidelity: serialize -> parse -> serialize is byte-identical and
// label-bearing fields survive exactly.
unittest {
    foreach (record; [elementRecord(3, -1, -1),
                      elementRecord(-1, -1, -1),   // background pick
                      handleRecord()]) {
        auto line = record.toJsonLine();
        auto reparsed = parseAiInteractionLogLine(line);
        assert(reparsed.toJsonLine() == line);
        assert(reparsed.appliedWinnerId == record.appliedWinnerId);
        assert(reparsed.candidates.length == record.candidates.length);
        foreach (i, ref c; record.candidates)
            assert(reparsed.candidates[i].id == c.id);
    }
}

// Multi-line corpus: a captured JSONL blob parses line-by-line back into the
// same records.
unittest {
    AiInteractionLogRecord[] originals = [
        elementRecord(3, -1, -1),
        elementRecord(-1, 9, -1),
        handleRecord(),
    ];
    string blob;
    foreach (i, ref r; originals) {
        if (i) blob ~= "\n";
        blob ~= r.toJsonLine();
    }
    AiInteractionLogRecord[] parsed;
    foreach (line; blob.split("\n")) {
        if (line.strip.length == 0) continue;
        parsed ~= parseAiInteractionLogLine(line);
    }
    assert(parsed.length == originals.length);
    foreach (i, ref p; parsed)
        assert(p.toJsonLine() == originals[i].toJsonLine());
}

// End-to-end label coverage on PARSED records (the coverage > 0 gate): build
// records for both v1 groupIds, serialize, PARSE BACK, then export. Every
// parsed record must label, and each output label.id must equal the original
// appliedWinnerId — proving appliedWinnerId + candidate ids survived parse
// byte-exact so aiRankerLabelFromRecord still matches.
unittest {
    AiInteractionLogRecord[] originals = [
        elementRecord(3, -1, -1),
        elementRecord(-1, 9, -1),
        elementRecord(-1, -1, 5),
        handleRecord(),
    ];

    // Serialize then parse back — do NOT export the freshly-built structs.
    AiInteractionLogRecord[] parsed;
    string[] expectedIds;
    foreach (ref r; originals) {
        parsed ~= parseAiInteractionLogLine(r.toJsonLine());
        expectedIds ~= r.appliedWinnerId;
    }

    auto result = exportAiTrainingDatasetJsonl(parsed);
    assert(result.stats.total == originals.length);
    // Coverage gate: every parsed record labels.
    assert(result.stats.labeled == result.stats.total);
    assert(result.stats.unlabeled == 0);

    // Each parsed record's label id equals the original applied winner id.
    foreach (i, ref p; parsed) {
        auto label = aiRankerLabelFromRecord(p);
        assert(label.present);
        assert(label.candidateId == expectedIds[i]);
    }
}
