// Module unittests for `ai.interaction`, moved verbatim out of source/ai/interaction.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.interaction_test;


import ai.interaction;

unittest {
    auto candidate = AiCandidate();
    assert(candidate.id.length == 0);
    assert(candidate.kind == AiCandidateKind.unknown);
    assert(candidate.elementKind == AiElementCandidateKind.none);
    assert(candidate.intent == AiIntent.keepDefault);
    assert(candidate.screenDist == float.infinity);
    assert(candidate.worldDist == float.infinity);
    assert(candidate.priorityFromCurrentRules == 0.0f);
    assert(!candidate.isDefaultWinner);
    assert(!candidate.isExplicitModifierChoice);
    assert(!candidate.hasScreenPosition);
    assert(candidate.screenPosition[0] == 0.0f);
    assert(candidate.screenPosition[1] == 0.0f);
    assert(!candidate.hasWorldPosition);
    assert(candidate.worldPosition[0] == 0.0f);
    assert(candidate.worldPosition[1] == 0.0f);
    assert(candidate.worldPosition[2] == 0.0f);

    auto context = AiInteractionContext();
    assert(context.phase == AiInteractionPhase.unknown);
    assert(context.defaultIntent == AiIntent.keepDefault);
    assert(context.mouseX == -1);
    assert(context.mouseY == -1);
    assert(context.mouseDeltaX == 0);
    assert(context.mouseDeltaY == 0);
    assert(!context.shift);
    assert(!context.ctrl);
    assert(!context.alt);
    assert(!context.isDragging);
    assert(context.activeToolId.length == 0);
    assert(context.editModeId.length == 0);

    auto decision = AiAdvisorDecision();
    assert(decision.keepDefault);
    assert(decision.confidence == 0.0f);
    assert(decision.candidateIndex == -1);
    assert(decision.candidateId.length == 0);
}
