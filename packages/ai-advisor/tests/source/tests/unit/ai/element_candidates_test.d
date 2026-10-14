// Module unittests for `ai.element_candidates`, moved verbatim out of source/ai/element_candidates.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.element_candidates_test;

import std.conv : to;
import ai.debug_trace : publishElementDebugTrace;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiElementCandidateKind, AiIntent;
import ai.element_candidates;

unittest {
    auto candidates = collectElementCandidates(12, 34, 5, 7, 9);
    assert(candidates.length == 3);
    assert(candidates[0].id == "element:vertex:5");
    assert(candidates[0].kind == AiCandidateKind.element);
    assert(candidates[0].elementKind == AiElementCandidateKind.vertex);
    assert(candidates[0].intent == AiIntent.hoverElement);
    assert(candidates[0].priorityFromCurrentRules == 0.0f);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[0].hasScreenPosition);
    assert(candidates[0].screenPosition == [12.0f, 34.0f]);

    assert(candidates[1].id == "element:edge:7");
    assert(candidates[1].elementKind == AiElementCandidateKind.edge);
    assert(candidates[1].priorityFromCurrentRules == 1.0f);
    assert(!candidates[1].isDefaultWinner);

    assert(candidates[2].id == "element:face:9");
    assert(candidates[2].elementKind == AiElementCandidateKind.face);
    assert(candidates[2].priorityFromCurrentRules == 2.0f);
    assert(!candidates[2].isDefaultWinner);
}

unittest {
    auto candidates = collectElementCandidates(1, 2, -1, -1, -1);
    assert(candidates.length == 1);
    assert(candidates[0].id == "element:background");
    assert(candidates[0].kind == AiCandidateKind.element);
    assert(candidates[0].elementKind == AiElementCandidateKind.background);
    assert(candidates[0].intent == AiIntent.keepDefault);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[0].screenDist == float.infinity);
}
