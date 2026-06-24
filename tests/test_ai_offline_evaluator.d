// Pure tests for the AI offline evaluator baseline.

import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiIntent;
import ai.interaction_log : makeAiInteractionLogRecord;
import ai.offline_evaluator : evaluateAiOfflineBaseline,
    predictAiOfflineBaselineWinner, replayAiOfflineAdvisorDecision;
import ai.synthetic_dataset : makeAiSyntheticInteractionDataset;

void main() {}

private AiCandidate candidate(string id,
                              float screenDist = float.infinity,
                              float priority = 0.0f,
                              bool isDefaultWinner = false) {
    AiCandidate c;
    c.id = id;
    c.kind = AiCandidateKind.handle;
    c.intent = AiIntent.handle;
    c.screenDist = screenDist;
    c.priorityFromCurrentRules = priority;
    c.isDefaultWinner = isDefaultWinner;
    return c;
}

private AiAdvisorDecision decisionFor(string id, int index) {
    AiAdvisorDecision decision;
    decision.intent = AiIntent.handle;
    decision.confidence = 0.9f;
    decision.candidateId = id;
    decision.candidateIndex = index;
    return decision;
}

unittest { // synthetic dataset is evaluated by feature-only baseline
    auto report = evaluateAiOfflineBaseline(
        makeAiSyntheticInteractionDataset());

    assert(report.overall.total == 3);
    assert(report.overall.evaluated == 3);
    assert(report.overall.missingWinner == 0);
    assert(report.overall.correct == 1);
    assert(report.overall.accuracy == cast(double)1 / 3);

    assert(report.byGroup.length == 3);
    assert(report.byGroup[0].groupId == "handle");
    assert(report.byGroup[0].metrics.total == 1);
    assert(report.byGroup[0].metrics.correct == 1);
    assert(report.byGroup[0].metrics.accuracy == 1.0);

    assert(report.byGroup[1].groupId == "element");
    assert(report.byGroup[1].metrics.total == 1);
    assert(report.byGroup[1].metrics.correct == 0);

    assert(report.byGroup[2].groupId == "mode-tool-context");
    assert(report.byGroup[2].metrics.total == 1);
    assert(report.byGroup[2].metrics.correct == 0);
}

unittest { // empty dataset has stable zero metrics
    auto report = evaluateAiOfflineBaseline(null);

    assert(report.overall.total == 0);
    assert(report.overall.evaluated == 0);
    assert(report.overall.missingWinner == 0);
    assert(report.overall.correct == 0);
    assert(report.overall.accuracy == 0.0);
    assert(report.byGroup.length == 0);
}

unittest { // missing and unknown applied winners are counted, not guessed
    AiInteractionContext context;
    auto candidates = [
        candidate("handle:x", 12.0f, 0.0f, true),
        candidate("handle:y", 3.0f, 1.0f),
    ];

    auto missing = makeAiInteractionLogRecord(
        "test", "handles", context, candidates);
    missing.withAppliedWinner(-1, "");

    auto unknown = makeAiInteractionLogRecord(
        "test", "handles", context, candidates);
    unknown.withAppliedWinner(7, "handle:z");

    auto report = evaluateAiOfflineBaseline([missing, unknown]);

    assert(report.overall.total == 2);
    assert(report.overall.evaluated == 0);
    assert(report.overall.missingWinner == 2);
    assert(report.overall.correct == 0);
    assert(report.overall.accuracy == 0.0);
    assert(report.byGroup.length == 1);
    assert(report.byGroup[0].groupId == "handles");
    assert(report.byGroup[0].metrics.missingWinner == 2);
}

unittest { // baseline predictor uses feature score, then default
    auto candidates = [
        candidate("handle:x", 50.0f, 0.0f, true),
        candidate("handle:y", 4.0f, 1.0f),
        candidate("handle:z", 9.0f, 2.0f),
    ];

    auto prediction = predictAiOfflineBaselineWinner(candidates);
    assert(prediction.present);
    assert(prediction.candidateIndex == 1);
    assert(prediction.candidateId == "handle:y");

    auto defaultOnly = [
        candidate("mode:vertex", float.infinity, float.infinity, true),
        candidate("mode:edge", float.infinity, float.infinity),
    ];
    prediction = predictAiOfflineBaselineWinner(defaultOnly);
    assert(prediction.candidateIndex == 0);
    assert(prediction.candidateId == "mode:vertex");
}

unittest { // advisor replay is explicit and separate from feature baseline
    auto candidates = [
        candidate("handle:x", 50.0f, 0.0f, true),
        candidate("handle:y", 4.0f, 1.0f),
        candidate("handle:z", 9.0f, 2.0f),
    ];

    auto baseline = predictAiOfflineBaselineWinner(candidates);
    assert(baseline.candidateId == "handle:y");

    auto replay = replayAiOfflineAdvisorDecision(
        candidates, decisionFor("handle:z", 2));
    assert(replay.present);
    assert(replay.candidateIndex == 2);
    assert(replay.candidateId == "handle:z");
}
