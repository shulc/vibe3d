// Pure tests for observational element candidate collection.

import ai.debug_trace : clearLatestAiDebugTraces, latestElementDebugTrace;
import ai.element_candidates : collectElementCandidates,
    publishElementCandidates, publishElementCandidatesWithAdvisor,
    resolveElementCandidateDecision;
import ai.interaction : AiAdvisorDecision, AiCandidateKind,
    AiElementCandidateKind, AiIntent;

void main() {}

unittest { // vertex, edge, face candidates keep deterministic priority order
    auto candidates = collectElementCandidates(100, 200, 4, 6, 8);
    assert(candidates.length == 3);

    assert(candidates[0].id == "element:vertex:4");
    assert(candidates[0].kind == AiCandidateKind.element);
    assert(candidates[0].elementKind == AiElementCandidateKind.vertex);
    assert(candidates[0].intent == AiIntent.hoverElement);
    assert(candidates[0].priorityFromCurrentRules == 0.0f);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[0].hasScreenPosition);
    assert(candidates[0].screenPosition == [100.0f, 200.0f]);

    assert(candidates[1].id == "element:edge:6");
    assert(candidates[1].elementKind == AiElementCandidateKind.edge);
    assert(candidates[1].priorityFromCurrentRules == 1.0f);
    assert(!candidates[1].isDefaultWinner);

    assert(candidates[2].id == "element:face:8");
    assert(candidates[2].elementKind == AiElementCandidateKind.face);
    assert(candidates[2].priorityFromCurrentRules == 2.0f);
    assert(!candidates[2].isDefaultWinner);
}

unittest { // current edit-mode single-type picks still become the default
    auto candidates = collectElementCandidates(9, 10, -1, -1, 12);
    assert(candidates.length == 1);
    assert(candidates[0].id == "element:face:12");
    assert(candidates[0].elementKind == AiElementCandidateKind.face);
    assert(candidates[0].priorityFromCurrentRules == 0.0f);
    assert(candidates[0].isDefaultWinner);
}

unittest { // no hit publishes an explicit background default
    auto candidates = collectElementCandidates(1, 2, -1, -1, -1);
    assert(candidates.length == 1);
    assert(candidates[0].id == "element:background");
    assert(candidates[0].elementKind == AiElementCandidateKind.background);
    assert(candidates[0].intent == AiIntent.keepDefault);
    assert(candidates[0].isDefaultWinner);
}

unittest { // publish/readback and global reset do not leave stale candidates
    clearLatestAiDebugTraces();
    publishElementCandidates(5, 6, -1, 3, -1);

    auto trace = latestElementDebugTrace();
    assert(trace.candidates.length == 1);
    assert(trace.candidates[0].id == "element:edge:3");
    assert(trace.defaultWinnerId == "element:edge:3");
    assert(trace.appliedWinnerId == "element:edge:3");
    assert(trace.advisor.keepDefault);

    clearLatestAiDebugTraces();
    auto empty = latestElementDebugTrace();
    assert(empty.candidates.length == 0);
    assert(empty.defaultWinnerIndex == -1);
    assert(empty.appliedWinnerIndex == -1);
}

unittest { // default/off decision keeps applied equal to deterministic default
    auto candidates = collectElementCandidates(10, 20, 1, 2, 3);

    auto resolution = resolveElementCandidateDecision(candidates);
    assert(resolution.defaultWinnerIndex == 0);
    assert(resolution.defaultWinnerId(candidates) == "element:vertex:1");
    assert(resolution.appliedWinnerIndex == 0);
    assert(resolution.appliedWinnerId(candidates) == "element:vertex:1");
    assert(resolution.advisor.keepDefault);
}

unittest { // valid advisory element choice can become applied in the seam
    clearLatestAiDebugTraces();

    AiAdvisorDecision decision;
    decision.intent = AiIntent.hoverElement;
    decision.confidence = 0.9f;
    decision.candidateIndex = 2;
    decision.candidateId = "element:face:3";

    auto resolution = publishElementCandidatesWithAdvisor(10, 20, 1, 2, 3,
                                                          decision);
    assert(resolution.defaultWinnerIndex == 0);
    assert(resolution.appliedWinnerIndex == 2);

    auto trace = latestElementDebugTrace();
    assert(trace.defaultWinnerId == "element:vertex:1");
    assert(trace.appliedWinnerId == "element:face:3");
    assert(trace.advisor.candidateIndex == 2);
    assert(trace.advisor.candidateId == "element:face:3");
}

unittest { // invalid advisory choices fall back to deterministic default
    auto candidates = collectElementCandidates(10, 20, 1, 2, 3);

    AiAdvisorDecision wrongId;
    wrongId.intent = AiIntent.hoverElement;
    wrongId.confidence = 0.95f;
    wrongId.candidateIndex = 1;
    wrongId.candidateId = "element:face:3";

    auto wrongIdResolution = resolveElementCandidateDecision(candidates,
                                                             wrongId);
    assert(wrongIdResolution.defaultWinnerIndex == 0);
    assert(wrongIdResolution.appliedWinnerIndex == 0);

    AiAdvisorDecision lowConfidence;
    lowConfidence.intent = AiIntent.hoverElement;
    lowConfidence.confidence = 0.5f;
    lowConfidence.candidateIndex = 2;
    lowConfidence.candidateId = "element:face:3";

    auto lowConfidenceResolution =
        resolveElementCandidateDecision(candidates, lowConfidence);
    assert(lowConfidenceResolution.appliedWinnerIndex == 0);
}

unittest { // existing production publisher still does not apply advisor choices
    clearLatestAiDebugTraces();

    AiAdvisorDecision decision;
    decision.intent = AiIntent.hoverElement;
    decision.confidence = 0.9f;
    decision.candidateIndex = 2;
    decision.candidateId = "element:face:3";
    publishElementCandidatesWithAdvisor(10, 20, 1, 2, 3, decision);
    assert(latestElementDebugTrace().appliedWinnerId == "element:face:3");

    publishElementCandidates(10, 20, 1, 2, 3);
    auto trace = latestElementDebugTrace();
    assert(trace.defaultWinnerId == "element:vertex:1");
    assert(trace.appliedWinnerId == "element:vertex:1");
    assert(trace.advisor.keepDefault);
}
