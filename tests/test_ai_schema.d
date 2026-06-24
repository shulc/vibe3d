// Pure schema and no-op advisor tests for the AI interaction API.

import ai.advisor;
import ai.interaction;

void main() {}

unittest { // schema defaults
    auto context = AiInteractionContext();
    assert(context.phase == AiInteractionPhase.unknown);
    assert(context.defaultIntent == AiIntent.keepDefault);
    assert(context.mouseX == -1);
    assert(context.mouseY == -1);
    assert(context.mouseDeltaX == 0);
    assert(context.mouseDeltaY == 0);
    assert(context.activeToolId.length == 0);
    assert(context.editModeId.length == 0);
    assert(!context.shift);
    assert(!context.ctrl);
    assert(!context.alt);
    assert(!context.isDragging);

    auto candidate = AiCandidate();
    assert(candidate.id.length == 0);
    assert(candidate.kind == AiCandidateKind.unknown);
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

    auto decision = AiAdvisorDecision();
    assert(decision.keepDefault);
    assert(decision.confidence == 0.0f);
    assert(decision.candidateIndex == -1);
    assert(decision.candidateId.length == 0);
}

unittest { // no-op advisor with explicit context and candidates
    auto context = AiInteractionContext();
    context.phase = AiInteractionPhase.mouseDown;
    context.defaultIntent = AiIntent.dragAxisX;
    context.mouseX = 320;
    context.mouseY = 240;
    context.activeToolId = "transform";
    context.editModeId = "vertex";

    AiCandidate candidate;
    candidate.id = "move-x";
    candidate.kind = AiCandidateKind.handle;
    candidate.intent = AiIntent.dragAxisX;
    candidate.screenDist = 3.0f;
    candidate.priorityFromCurrentRules = 1.0f;
    candidate.isDefaultWinner = true;
    candidate.hasScreenPosition = true;
    candidate.screenPosition = [320.0f, 240.0f];

    auto advisor = new AiAdvisor();
    auto decision = advisor.advise(context, [candidate]);
    assert(decision.keepDefault);
    assert(decision.intent == AiIntent.keepDefault);
    assert(decision.confidence == 0.0f);
    assert(decision.candidateIndex == -1);
    assert(decision.candidateId.length == 0);
}

unittest { // compatibility wrapper remains behavior-neutral
    auto advisor = new AiAdvisor();
    auto decision = advisor.advise();
    assert(decision.keepDefault);
    assert(decision.confidence == 0.0f);
    assert(decision.candidateIndex == -1);
}
