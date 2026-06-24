module ai.ranker_schema;

import std.algorithm : min;
import std.math : isFinite;

import ai.debug_trace : aiElementCandidateKindId, aiIntentId;
import ai.interaction : AiCandidate, AiCandidateKind,
    AiElementCandidateKind, AiInteractionContext, AiInteractionPhase,
    AiIntent;
import ai.interaction_log : AiInteractionLogRecord, aiCandidateKindId,
    aiInteractionPhaseId;

enum int aiRankerFeatureSchemaVersion = 1;
enum size_t aiRankerDefaultMaxCandidates = 16;

enum size_t aiRankerGroupCategoryCount = 4;
enum size_t aiRankerPhaseCategoryCount = 9;
enum size_t aiRankerIntentCategoryCount = 23;
enum size_t aiRankerCandidateKindCategoryCount = 5;
enum size_t aiRankerElementKindCategoryCount = 5;

enum float aiRankerScreenPixelScale = 4096.0f;
enum float aiRankerScreenDeltaScale = 512.0f;
enum float aiRankerScreenDistanceScale = 256.0f;
enum float aiRankerWorldDistanceScale = 10.0f;
enum float aiRankerPriorityScale = cast(float)(aiRankerDefaultMaxCandidates - 1);

enum AiRankerCandidateGroup {
    unknown,
    handle,
    element,
    modeToolContext,
}

struct AiRankerFeatureBatch {
    int schemaVersion = aiRankerFeatureSchemaVersion;
    size_t maxCandidates = aiRankerDefaultMaxCandidates;
    size_t candidateCount = 0;
    float[] contextFeatures;
    float[][] candidateFeatures;
    float[] candidateMask;
}

struct AiRankerLabel {
    int index = -1;
    string candidateId = "";

    bool present() const {
        return index >= 0;
    }
}

AiRankerFeatureBatch encodeAiRankerInput(
    const ref AiInteractionLogRecord record,
    size_t maxCandidates = aiRankerDefaultMaxCandidates) {
    return encodeAiRankerInput(record.groupId,
                               record.context,
                               record.candidates,
                               maxCandidates);
}

AiRankerFeatureBatch encodeAiRankerInput(
    string groupId,
    const ref AiInteractionContext context,
    const(AiCandidate)[] candidates,
    size_t maxCandidates = aiRankerDefaultMaxCandidates) {
    AiRankerFeatureBatch batch;
    batch.maxCandidates = maxCandidates;
    batch.candidateCount = min(candidates.length, maxCandidates);
    batch.contextFeatures = encodeAiRankerContext(groupId, context);
    batch.candidateMask.length = maxCandidates;
    batch.candidateMask[] = 0.0f;
    batch.candidateFeatures.length = maxCandidates;

    immutable candidateFeatureCount = aiRankerCandidateFeatureNames().length;
    foreach (i; 0 .. maxCandidates) {
        batch.candidateFeatures[i].length = candidateFeatureCount;
        batch.candidateFeatures[i][] = 0.0f;
        if (i < batch.candidateCount) {
            batch.candidateMask[i] = 1.0f;
            batch.candidateFeatures[i] =
                encodeAiRankerCandidate(candidates[i]);
        }
    }
    return batch;
}

AiRankerLabel aiRankerLabelFromRecord(
    const ref AiInteractionLogRecord record,
    size_t maxCandidates = aiRankerDefaultMaxCandidates) {
    if (record.appliedWinnerId.length) {
        foreach (i, ref candidate; record.candidates) {
            if (candidate.id == record.appliedWinnerId)
                return i < maxCandidates
                    ? AiRankerLabel(cast(int)i, candidate.id)
                    : AiRankerLabel();
        }
        return AiRankerLabel();
    }

    if (record.appliedWinnerIndex < 0)
        return AiRankerLabel();

    immutable index = cast(size_t)record.appliedWinnerIndex;
    if (index >= record.candidates.length || index >= maxCandidates)
        return AiRankerLabel();
    return AiRankerLabel(record.appliedWinnerIndex,
                         record.candidates[index].id);
}

int aiRankerSelectArgmax(const(float)[] scores,
                         const(float)[] candidateMask) {
    int bestIndex = -1;
    float bestScore = 0.0f;

    immutable count = min(scores.length, candidateMask.length);
    foreach (i; 0 .. count) {
        if (candidateMask[i] <= 0.5f)
            continue;
        if (bestIndex < 0 || scores[i] > bestScore) {
            bestIndex = cast(int)i;
            bestScore = scores[i];
        }
    }
    return bestIndex;
}

string[] aiRankerContextFeatureNames() {
    string[] names;
    appendOneHotNames(names, "context.group", aiRankerGroupCategoryNames());
    appendOneHotNames(names, "context.phase", aiRankerPhaseCategoryNames());
    appendOneHotNames(names, "context.default_intent",
                      aiRankerIntentCategoryNames());
    names ~= [
        "context.mouse_present",
        "context.mouse_x_norm",
        "context.mouse_y_norm",
        "context.mouse_delta_x_norm",
        "context.mouse_delta_y_norm",
        "context.shift",
        "context.ctrl",
        "context.alt",
        "context.is_dragging",
        "context.active_tool_present",
        "context.edit_mode_present",
    ];
    return names;
}

string[] aiRankerCandidateFeatureNames() {
    string[] names;
    appendOneHotNames(names, "candidate.kind",
                      aiRankerCandidateKindCategoryNames());
    appendOneHotNames(names, "candidate.element_kind",
                      aiRankerElementKindCategoryNames());
    appendOneHotNames(names, "candidate.intent",
                      aiRankerIntentCategoryNames());
    names ~= [
        "candidate.screen_dist_present",
        "candidate.screen_dist_norm",
        "candidate.world_dist_present",
        "candidate.world_dist_norm",
        "candidate.priority_norm",
        "candidate.rule_default",
        "candidate.explicit_modifier_choice",
        "candidate.screen_position_present",
        "candidate.screen_x_norm",
        "candidate.screen_y_norm",
        "candidate.world_position_present",
        "candidate.world_x_norm",
        "candidate.world_y_norm",
        "candidate.world_z_norm",
    ];
    return names;
}

float[] encodeAiRankerContext(string groupId,
                              const ref AiInteractionContext context) {
    auto values = new float[](aiRankerContextFeatureNames().length);
    values[] = 0.0f;
    size_t offset;
    putOneHot(values, offset, aiRankerGroupCategoryCount,
              aiRankerGroupIndex(groupId));
    putOneHot(values, offset, aiRankerPhaseCategoryCount,
              enumCategoryIndex(context.phase,
                                aiRankerPhaseCategoryCount));
    putOneHot(values, offset, aiRankerIntentCategoryCount,
              enumCategoryIndex(context.defaultIntent,
                                aiRankerIntentCategoryCount));

    immutable hasMouse = context.mouseX >= 0 && context.mouseY >= 0;
    values[offset++] = boolFeature(hasMouse);
    values[offset++] = hasMouse
        ? clamp01(cast(float)context.mouseX / aiRankerScreenPixelScale)
        : 0.0f;
    values[offset++] = hasMouse
        ? clamp01(cast(float)context.mouseY / aiRankerScreenPixelScale)
        : 0.0f;
    values[offset++] = clampSigned(cast(float)context.mouseDeltaX /
                                   aiRankerScreenDeltaScale);
    values[offset++] = clampSigned(cast(float)context.mouseDeltaY /
                                   aiRankerScreenDeltaScale);
    values[offset++] = boolFeature(context.shift);
    values[offset++] = boolFeature(context.ctrl);
    values[offset++] = boolFeature(context.alt);
    values[offset++] = boolFeature(context.isDragging);
    values[offset++] = boolFeature(context.activeToolId.length != 0);
    values[offset++] = boolFeature(context.editModeId.length != 0);
    return values;
}

float[] encodeAiRankerCandidate(const ref AiCandidate candidate) {
    auto values = new float[](aiRankerCandidateFeatureNames().length);
    values[] = 0.0f;
    size_t offset;
    putOneHot(values, offset, aiRankerCandidateKindCategoryCount,
              enumCategoryIndex(candidate.kind,
                                aiRankerCandidateKindCategoryCount));
    putOneHot(values, offset, aiRankerElementKindCategoryCount,
              enumCategoryIndex(candidate.elementKind,
                                aiRankerElementKindCategoryCount));
    putOneHot(values, offset, aiRankerIntentCategoryCount,
              enumCategoryIndex(candidate.intent,
                                aiRankerIntentCategoryCount));

    immutable hasScreenDist = candidate.screenDist.isFinite;
    values[offset++] = boolFeature(hasScreenDist);
    values[offset++] = hasScreenDist
        ? clamp01(candidate.screenDist / aiRankerScreenDistanceScale)
        : 0.0f;

    immutable hasWorldDist = candidate.worldDist.isFinite;
    values[offset++] = boolFeature(hasWorldDist);
    values[offset++] = hasWorldDist
        ? clamp01(candidate.worldDist / aiRankerWorldDistanceScale)
        : 0.0f;

    values[offset++] = candidate.priorityFromCurrentRules.isFinite
        ? clamp01(candidate.priorityFromCurrentRules / aiRankerPriorityScale)
        : 0.0f;
    values[offset++] = boolFeature(candidate.isDefaultWinner);
    values[offset++] = boolFeature(candidate.isExplicitModifierChoice);
    values[offset++] = boolFeature(candidate.hasScreenPosition);
    values[offset++] = candidate.hasScreenPosition
        ? clamp01(candidate.screenPosition[0] / aiRankerScreenPixelScale)
        : 0.0f;
    values[offset++] = candidate.hasScreenPosition
        ? clamp01(candidate.screenPosition[1] / aiRankerScreenPixelScale)
        : 0.0f;
    values[offset++] = boolFeature(candidate.hasWorldPosition);
    values[offset++] = candidate.hasWorldPosition
        ? clampSigned(candidate.worldPosition[0] / aiRankerWorldDistanceScale)
        : 0.0f;
    values[offset++] = candidate.hasWorldPosition
        ? clampSigned(candidate.worldPosition[1] / aiRankerWorldDistanceScale)
        : 0.0f;
    values[offset++] = candidate.hasWorldPosition
        ? clampSigned(candidate.worldPosition[2] / aiRankerWorldDistanceScale)
        : 0.0f;
    return values;
}

string[] aiRankerGroupCategoryNames() {
    return ["unknown", "handle", "element", "mode_tool_context"];
}

string[] aiRankerPhaseCategoryNames() {
    string[] names;
    foreach (i; 0 .. aiRankerPhaseCategoryCount)
        names ~= aiInteractionPhaseId(cast(AiInteractionPhase)i);
    return names;
}

string[] aiRankerIntentCategoryNames() {
    string[] names;
    foreach (i; 0 .. aiRankerIntentCategoryCount)
        names ~= aiIntentId(cast(AiIntent)i);
    return names;
}

string[] aiRankerCandidateKindCategoryNames() {
    string[] names;
    foreach (i; 0 .. aiRankerCandidateKindCategoryCount)
        names ~= aiCandidateKindId(cast(AiCandidateKind)i);
    return names;
}

string[] aiRankerElementKindCategoryNames() {
    string[] names;
    foreach (i; 0 .. aiRankerElementKindCategoryCount)
        names ~= aiElementCandidateKindId(cast(AiElementCandidateKind)i);
    return names;
}

int aiRankerGroupIndex(string groupId) {
    switch (groupId) {
        case "handle":
        case "handles":
            return cast(int)AiRankerCandidateGroup.handle;
        case "element":
        case "elements":
            return cast(int)AiRankerCandidateGroup.element;
        case "mode-tool-context":
        case "mode_tool_context":
            return cast(int)AiRankerCandidateGroup.modeToolContext;
        default:
            return cast(int)AiRankerCandidateGroup.unknown;
    }
}

private int enumCategoryIndex(E)(E value, size_t count) {
    immutable index = cast(int)value;
    return index >= 0 && cast(size_t)index < count ? index : 0;
}

private void appendOneHotNames(ref string[] names,
                               string prefix,
                               string[] categories) {
    foreach (category; categories)
        names ~= prefix ~ "." ~ category;
}

private void putOneHot(ref float[] values,
                       ref size_t offset,
                       size_t count,
                       int index) {
    foreach (i; 0 .. count)
        values[offset + i] = cast(int)i == index ? 1.0f : 0.0f;
    offset += count;
}

private float boolFeature(bool value) {
    return value ? 1.0f : 0.0f;
}

private float clamp01(float value) {
    if (!value.isFinite || value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

private float clampSigned(float value) {
    if (!value.isFinite) return 0.0f;
    if (value < -1.0f) return -1.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

unittest {
    auto contextNames = aiRankerContextFeatureNames();
    auto candidateNames = aiRankerCandidateFeatureNames();
    assert(contextNames.length == aiRankerGroupCategoryCount +
           aiRankerPhaseCategoryCount +
           aiRankerIntentCategoryCount + 11);
    assert(candidateNames.length == aiRankerCandidateKindCategoryCount +
           aiRankerElementKindCategoryCount +
           aiRankerIntentCategoryCount + 14);
}
