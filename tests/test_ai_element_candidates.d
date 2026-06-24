// Pure tests for observational element candidate collection.

import ai.debug_trace : clearLatestAiDebugTraces, latestElementDebugTrace;
import ai.element_candidates : collectElementCandidates, publishElementCandidates;
import ai.interaction : AiCandidateKind, AiElementCandidateKind, AiIntent;

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
