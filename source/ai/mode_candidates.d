module ai.mode_candidates;

import ai.debug_trace : publishModeToolContextDebugTrace;
import ai.interaction : AiCandidate, AiCandidateKind, AiInteractionContext,
    AiIntent;

private bool startsWithId(string value, string prefix) {
    return value.length >= prefix.length && value[0 .. prefix.length] == prefix;
}

private string modeCandidateId(string id) {
    if (id.length == 0)
        return "";
    if (startsWithId(id, "mode:"))
        return id;

    switch (id) {
        case "vertices":
        case "vertex":
            return "mode:vertex";
        case "edges":
        case "edge":
            return "mode:edge";
        case "polygons":
        case "polygon":
        case "faces":
        case "face":
            return "mode:polygon";
        case "items":
        case "item":
            return "mode:item";
        default:
            return "mode:" ~ id;
    }
}

private string prefixedCandidateId(string prefix, string id) {
    if (id.length == 0)
        return "";
    auto fullPrefix = prefix ~ ":";
    return startsWithId(id, fullPrefix) ? id : fullPrefix ~ id;
}

private bool containsId(const(AiCandidate)[] candidates, string id) {
    foreach (ref c; candidates) {
        if (c.id == id)
            return true;
    }
    return false;
}

private void appendCandidate(ref AiCandidate[] candidates,
                             string id,
                             AiCandidateKind kind,
                             bool isDefault) {
    if (id.length == 0 || containsId(candidates, id))
        return;

    AiCandidate c;
    c.id = id;
    c.kind = kind;
    c.intent = AiIntent.keepDefault;
    c.priorityFromCurrentRules = cast(float)candidates.length;
    c.isDefaultWinner = isDefault;
    candidates ~= c;
}

AiCandidate[] collectModeCandidates(const ref AiInteractionContext context,
                                    const(string)[] alternativeModeIds = null) {
    AiCandidate[] candidates;

    appendCandidate(candidates, modeCandidateId(context.editModeId),
                    AiCandidateKind.mode, true);
    foreach (modeId; alternativeModeIds)
        appendCandidate(candidates, modeCandidateId(modeId),
                        AiCandidateKind.mode, false);
    return candidates;
}

AiCandidate[] collectToolCandidates(const ref AiInteractionContext context,
                                    const(string)[] alternativeToolIds = null) {
    AiCandidate[] candidates;

    appendCandidate(candidates, prefixedCandidateId("tool", context.activeToolId),
                    AiCandidateKind.context, true);
    foreach (toolId; alternativeToolIds)
        appendCandidate(candidates, prefixedCandidateId("tool", toolId),
                        AiCandidateKind.context, false);
    return candidates;
}

AiCandidate[] collectContextCandidates(string currentContextId = "",
                                       const(string)[] alternativeContextIds = null) {
    AiCandidate[] candidates;

    appendCandidate(candidates, prefixedCandidateId("context", currentContextId),
                    AiCandidateKind.context, true);
    foreach (contextId; alternativeContextIds)
        appendCandidate(candidates, prefixedCandidateId("context", contextId),
                        AiCandidateKind.context, false);
    return candidates;
}

AiCandidate[] collectModeToolContextCandidates(
    const ref AiInteractionContext context,
    const(string)[] alternativeModeIds = null,
    const(string)[] alternativeToolIds = null,
    string currentContextId = "",
    const(string)[] alternativeContextIds = null) {
    AiCandidate[] candidates;

    foreach (ref c; collectModeCandidates(context, alternativeModeIds))
        appendCandidate(candidates, c.id, c.kind, c.isDefaultWinner);
    foreach (ref c; collectToolCandidates(context, alternativeToolIds))
        appendCandidate(candidates, c.id, c.kind, c.isDefaultWinner);
    foreach (ref c; collectContextCandidates(currentContextId,
                                             alternativeContextIds))
        appendCandidate(candidates, c.id, c.kind, c.isDefaultWinner);
    return candidates;
}

void publishModeToolContextCandidates(const ref AiInteractionContext context,
                                      const(string)[] alternativeModeIds = null,
                                      const(string)[] alternativeToolIds = null,
                                      string currentContextId = "",
                                      const(string)[] alternativeContextIds = null) {
    publishModeToolContextDebugTrace(
        collectModeToolContextCandidates(context,
                                         alternativeModeIds,
                                         alternativeToolIds,
                                         currentContextId,
                                         alternativeContextIds));
}

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
