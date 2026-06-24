module ai.interaction;

enum AiIntent {
    keepDefault,
    handle,
    hoverElement,
    selectElement,
    boxOrLassoSelect,
    dragAxisX,
    dragAxisY,
    dragAxisZ,
    dragPlaneXY,
    dragPlaneYZ,
    dragPlaneXZ,
    dragCenterFree,
    rotateAxisX,
    rotateAxisY,
    rotateAxisZ,
    rotateView,
    scaleAxisX,
    scaleAxisY,
    scaleAxisZ,
    scalePlaneXY,
    scalePlaneYZ,
    scalePlaneXZ,
    scaleUniform,
}

enum AiInteractionPhase {
    unknown,
    hover,
    mouseDown,
    dragStart,
    dragUpdate,
    dragCommit,
    dragCancel,
    toolSwitch,
    modeSwitch,
}

enum AiCandidateKind {
    unknown,
    element,
    handle,
    mode,
    context,
}

struct AiCandidate {
    string id = "";
    AiCandidateKind kind = AiCandidateKind.unknown;
    AiIntent intent = AiIntent.keepDefault;
    float screenDist = float.infinity;
    float worldDist = float.infinity;
    float priorityFromCurrentRules = 0.0f;
    bool isDefaultWinner = false;
    bool isExplicitModifierChoice = false;
    bool hasScreenPosition = false;
    float[2] screenPosition = [0.0f, 0.0f];
    bool hasWorldPosition = false;
    float[3] worldPosition = [0.0f, 0.0f, 0.0f];
}

struct AiInteractionContext {
    AiInteractionPhase phase = AiInteractionPhase.unknown;
    AiIntent defaultIntent = AiIntent.keepDefault;
    int mouseX = -1;
    int mouseY = -1;
    int mouseDeltaX = 0;
    int mouseDeltaY = 0;
    bool shift = false;
    bool ctrl = false;
    bool alt = false;
    bool isDragging = false;
    string activeToolId = "";
    string editModeId = "";
}

struct AiAdvisorDecision {
    AiIntent intent = AiIntent.keepDefault;
    float confidence = 0.0f;
    int candidateIndex = -1;
    string candidateId = "";

    bool keepDefault() const {
        return intent == AiIntent.keepDefault;
    }
}

unittest {
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
