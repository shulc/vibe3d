// Module unittests for `ai.mode_candidates`, moved verbatim out of source/ai/mode_candidates.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.mode_candidates_test;

import ai.debug_trace : publishModeToolContextDebugTrace;
import ai.interaction : AiCandidate, AiCandidateKind, AiInteractionContext,
    AiIntent;
import ai.mode_candidates;

unittest {
    AiInteractionContext context;
    context.editModeId = "vertices";

    auto candidates = collectModeCandidates(context, ["edges", "polygons"]);
    assert(candidates.length == 3);
    assert(candidates[0].id == "mode:vertex");
    assert(candidates[0].kind == AiCandidateKind.mode);
    assert(candidates[0].intent == AiIntent.keepDefault);
    assert(candidates[0].priorityFromCurrentRules == 0.0f);
    assert(candidates[0].isDefaultWinner);
    assert(candidates[1].id == "mode:edge");
    assert(candidates[1].priorityFromCurrentRules == 1.0f);
    assert(!candidates[1].isDefaultWinner);
    assert(candidates[2].id == "mode:polygon");
}
