module ai.synthetic_dataset;

import std.array : appender;

import ai.element_candidates : collectElementCandidates;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase, AiIntent;
import ai.interaction_log : AiInteractionLogRecord,
    makeAiInteractionLogRecord;
import ai.mode_candidates : collectModeToolContextCandidates;

enum aiSyntheticDatasetSourcePrefix = "ai-synthetic";

AiInteractionLogRecord[] makeAiSyntheticInteractionDataset() {
    AiInteractionLogRecord[] records;
    records ~= makeSyntheticHandleRecord();
    records ~= makeSyntheticElementRecord();
    records ~= makeSyntheticModeToolContextRecord();

    foreach (i, ref record; records)
        record.withSequence(cast(ulong)i + 1);
    return records;
}

string[] makeAiSyntheticInteractionDatasetJsonLines() {
    string[] lines;
    foreach (ref record; makeAiSyntheticInteractionDataset())
        lines ~= record.toJsonLine();
    return lines;
}

string makeAiSyntheticInteractionDatasetJsonl() {
    auto buf = appender!string();
    foreach (line; makeAiSyntheticInteractionDatasetJsonLines()) {
        if (buf.data.length)
            buf.put("\n");
        buf.put(line);
    }
    return buf.data;
}

private AiInteractionLogRecord makeSyntheticHandleRecord() {
    AiInteractionContext context;
    context.phase = AiInteractionPhase.mouseDown;
    context.defaultIntent = AiIntent.handle;
    context.mouseX = 616;
    context.mouseY = 318;
    context.activeToolId = "xfrm.transform";
    context.editModeId = "vertices";

    AiCandidate x = makeHandleCandidate("handle:x-axis", AiIntent.dragAxisX,
                                        11.0f, 0, true, context);
    AiCandidate y = makeHandleCandidate("handle:y-axis", AiIntent.dragAxisY,
                                        4.0f, 1, false, context);
    AiCandidate center = makeHandleCandidate("handle:center-free",
                                             AiIntent.dragCenterFree,
                                             19.0f, 2, false, context);
    auto candidates = [x, y, center];
    immutable appliedIndex = nearestScreenDistanceIndex(candidates);

    auto decision = decisionForCandidate(candidates, appliedIndex, 0.9f);
    return makeAiInteractionLogRecord(
        aiSyntheticDatasetSourcePrefix ~ ".handle",
        "handle",
        context,
        candidates,
        decision,
        appliedIndex)
        .withOutcome("accepted", "nearest-screen-distance", true);
}

private AiInteractionLogRecord makeSyntheticElementRecord() {
    AiInteractionContext context;
    context.phase = AiInteractionPhase.hover;
    context.defaultIntent = AiIntent.hoverElement;
    context.mouseX = 180;
    context.mouseY = 220;
    context.activeToolId = "select";
    context.editModeId = "polygons";

    auto candidates = collectElementCandidates(context.mouseX, context.mouseY,
                                               4, 6, 8);
    immutable appliedIndex = indexOfCandidateId(candidates, "element:face:8");

    auto decision = decisionForCandidate(candidates, appliedIndex, 0.95f);
    return makeAiInteractionLogRecord(
        aiSyntheticDatasetSourcePrefix ~ ".element",
        "element",
        context,
        candidates,
        decision,
        appliedIndex)
        .withOutcome("accepted", "explicit-synthetic-label", true);
}

private AiInteractionLogRecord makeSyntheticModeToolContextRecord() {
    AiInteractionContext context;
    context.phase = AiInteractionPhase.toolSwitch;
    context.defaultIntent = AiIntent.keepDefault;
    context.activeToolId = "move";
    context.editModeId = "polygons";

    auto candidates = collectModeToolContextCandidates(
        context,
        ["vertices", "edges"],
        ["bevel", "rotate"],
        "selection",
        ["snap"]);
    immutable appliedIndex = indexOfCandidateId(candidates, "tool:bevel");

    auto decision = decisionForCandidate(candidates, appliedIndex, 0.875f);
    return makeAiInteractionLogRecord(
        aiSyntheticDatasetSourcePrefix ~ ".mode-tool-context",
        "mode-tool-context",
        context,
        candidates,
        decision,
        appliedIndex)
        .withOutcome("accepted", "explicit-synthetic-label", true);
}

private AiCandidate makeHandleCandidate(string id,
                                        AiIntent intent,
                                        float screenDist,
                                        size_t priority,
                                        bool isDefault,
                                        const ref AiInteractionContext context) {
    AiCandidate candidate;
    candidate.id = id;
    candidate.kind = AiCandidateKind.handle;
    candidate.intent = intent;
    candidate.screenDist = screenDist;
    candidate.priorityFromCurrentRules = cast(float)priority;
    candidate.isDefaultWinner = isDefault;
    candidate.hasScreenPosition = true;
    candidate.screenPosition = [cast(float)context.mouseX,
                                cast(float)context.mouseY];
    return candidate;
}

private int nearestScreenDistanceIndex(const(AiCandidate)[] candidates) {
    int bestIndex = -1;
    float bestDist = float.infinity;
    foreach (i, ref candidate; candidates) {
        if (candidate.screenDist < bestDist) {
            bestDist = candidate.screenDist;
            bestIndex = cast(int)i;
        }
    }
    return bestIndex;
}

private int indexOfCandidateId(const(AiCandidate)[] candidates, string id) {
    foreach (i, ref candidate; candidates) {
        if (candidate.id == id)
            return cast(int)i;
    }
    return -1;
}

private AiAdvisorDecision decisionForCandidate(const(AiCandidate)[] candidates,
                                               int index,
                                               float confidence) {
    AiAdvisorDecision decision;
    if (index < 0 || cast(size_t)index >= candidates.length)
        return decision;

    auto candidate = candidates[cast(size_t)index];
    decision.intent = candidate.intent;
    decision.confidence = confidence;
    decision.candidateIndex = index;
    decision.candidateId = candidate.id;
    return decision;
}
