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

unittest { // disabled advisor keeps the default even with strong candidates
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
    candidate.screenDist = 32.0f;
    candidate.priorityFromCurrentRules = 8.0f;
    candidate.isDefaultWinner = true;
    candidate.hasScreenPosition = true;
    candidate.screenPosition = [320.0f, 240.0f];

    AiCandidate better;
    better.id = "move-y";
    better.kind = AiCandidateKind.handle;
    better.intent = AiIntent.dragAxisY;
    better.screenDist = 2.0f;
    better.priorityFromCurrentRules = 0.0f;
    better.hasScreenPosition = true;
    better.screenPosition = [321.0f, 241.0f];

    auto advisor = new AiAdvisor();
    auto decision = advisor.advise(context, [candidate, better]);
    assert(decision.keepDefault);
    assert(decision.intent == AiIntent.keepDefault);
    assert(decision.confidence == 0.0f);
    assert(decision.candidateIndex == -1);
    assert(decision.candidateId.length == 0);
}

unittest { // enabled advisor keeps default when the margin is low
    AiCandidate defaultCandidate;
    defaultCandidate.id = "handle:1";
    defaultCandidate.kind = AiCandidateKind.handle;
    defaultCandidate.intent = AiIntent.dragAxisX;
    defaultCandidate.priorityFromCurrentRules = 0.0f;
    defaultCandidate.screenDist = 12.0f;
    defaultCandidate.isDefaultWinner = true;

    AiCandidate closeCandidate;
    closeCandidate.id = "handle:2";
    closeCandidate.kind = AiCandidateKind.handle;
    closeCandidate.intent = AiIntent.dragAxisY;
    closeCandidate.priorityFromCurrentRules = 0.0f;
    closeCandidate.screenDist = 6.0f;

    auto advisor = new AiAdvisor(true);
    auto context = AiInteractionContext();
    auto decision = advisor.advise(context, [defaultCandidate, closeCandidate]);
    assert(decision.keepDefault);
    assert(decision.confidence == 0.0f);
    assert(decision.candidateIndex == -1);
}

unittest { // enabled advisor emits an advisory candidate on high confidence
    AiCandidate defaultCandidate;
    defaultCandidate.id = "handle:1";
    defaultCandidate.kind = AiCandidateKind.handle;
    defaultCandidate.intent = AiIntent.dragAxisX;
    defaultCandidate.priorityFromCurrentRules = 5.0f;
    defaultCandidate.screenDist = 48.0f;
    defaultCandidate.isDefaultWinner = true;

    AiCandidate betterCandidate;
    betterCandidate.id = "handle:2";
    betterCandidate.kind = AiCandidateKind.handle;
    betterCandidate.intent = AiIntent.dragAxisY;
    betterCandidate.priorityFromCurrentRules = 1.0f;
    betterCandidate.screenDist = 8.0f;

    auto advisor = new AiAdvisor(true);
    auto context = AiInteractionContext();
    auto decision = advisor.advise(context, [defaultCandidate, betterCandidate]);
    assert(!decision.keepDefault);
    assert(decision.intent == AiIntent.dragAxisY);
    assert(decision.confidence >= 0.75f);
    assert(decision.candidateIndex == 1);
    assert(decision.candidateId == "handle:2");
}

unittest { // compatibility wrapper remains behavior-neutral
    auto advisor = new AiAdvisor();
    auto decision = advisor.advise();
    assert(decision.keepDefault);
    assert(decision.confidence == 0.0f);
    assert(decision.candidateIndex == -1);
}
