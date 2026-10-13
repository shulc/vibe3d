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

enum AiElementCandidateKind {
    none,
    vertex,
    edge,
    face,
    background,
}

struct AiCandidate {
    string id = "";
    AiCandidateKind kind = AiCandidateKind.unknown;
    AiElementCandidateKind elementKind = AiElementCandidateKind.none;
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
