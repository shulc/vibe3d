module ai.debug_trace;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;

import ai.interaction : AiAdvisorDecision, AiCandidate, AiElementCandidateKind,
    AiIntent;

string aiIntentId(AiIntent intent) {
    final switch (intent) {
        case AiIntent.keepDefault:       return "keepDefault";
        case AiIntent.handle:            return "handle";
        case AiIntent.hoverElement:      return "hoverElement";
        case AiIntent.selectElement:     return "selectElement";
        case AiIntent.boxOrLassoSelect:  return "boxOrLassoSelect";
        case AiIntent.dragAxisX:         return "dragAxisX";
        case AiIntent.dragAxisY:         return "dragAxisY";
        case AiIntent.dragAxisZ:         return "dragAxisZ";
        case AiIntent.dragPlaneXY:       return "dragPlaneXY";
        case AiIntent.dragPlaneYZ:       return "dragPlaneYZ";
        case AiIntent.dragPlaneXZ:       return "dragPlaneXZ";
        case AiIntent.dragCenterFree:    return "dragCenterFree";
        case AiIntent.rotateAxisX:       return "rotateAxisX";
        case AiIntent.rotateAxisY:       return "rotateAxisY";
        case AiIntent.rotateAxisZ:       return "rotateAxisZ";
        case AiIntent.rotateView:        return "rotateView";
        case AiIntent.scaleAxisX:        return "scaleAxisX";
        case AiIntent.scaleAxisY:        return "scaleAxisY";
        case AiIntent.scaleAxisZ:        return "scaleAxisZ";
        case AiIntent.scalePlaneXY:      return "scalePlaneXY";
        case AiIntent.scalePlaneYZ:      return "scalePlaneYZ";
        case AiIntent.scalePlaneXZ:      return "scalePlaneXZ";
        case AiIntent.scaleUniform:      return "scaleUniform";
    }
}

/// Reverse of `aiIntentId`: parse the serialized id back to its enum. Unknown
/// ids fall back to `keepDefault` so a forward-compatible log never crashes the
/// parser. Lives next to the forward helper it inverts.
AiIntent aiIntentFromId(string id) {
    switch (id) {
        case "keepDefault":       return AiIntent.keepDefault;
        case "handle":            return AiIntent.handle;
        case "hoverElement":      return AiIntent.hoverElement;
        case "selectElement":     return AiIntent.selectElement;
        case "boxOrLassoSelect":  return AiIntent.boxOrLassoSelect;
        case "dragAxisX":         return AiIntent.dragAxisX;
        case "dragAxisY":         return AiIntent.dragAxisY;
        case "dragAxisZ":         return AiIntent.dragAxisZ;
        case "dragPlaneXY":       return AiIntent.dragPlaneXY;
        case "dragPlaneYZ":       return AiIntent.dragPlaneYZ;
        case "dragPlaneXZ":       return AiIntent.dragPlaneXZ;
        case "dragCenterFree":    return AiIntent.dragCenterFree;
        case "rotateAxisX":       return AiIntent.rotateAxisX;
        case "rotateAxisY":       return AiIntent.rotateAxisY;
        case "rotateAxisZ":       return AiIntent.rotateAxisZ;
        case "rotateView":        return AiIntent.rotateView;
        case "scaleAxisX":        return AiIntent.scaleAxisX;
        case "scaleAxisY":        return AiIntent.scaleAxisY;
        case "scaleAxisZ":        return AiIntent.scaleAxisZ;
        case "scalePlaneXY":      return AiIntent.scalePlaneXY;
        case "scalePlaneYZ":      return AiIntent.scalePlaneYZ;
        case "scalePlaneXZ":      return AiIntent.scalePlaneXZ;
        case "scaleUniform":      return AiIntent.scaleUniform;
        default:                  return AiIntent.keepDefault;
    }
}

private string jsonString(string s) {
    return JSONValue(s).toString();
}

string aiElementCandidateKindId(AiElementCandidateKind kind) {
    final switch (kind) {
        case AiElementCandidateKind.none:       return "none";
        case AiElementCandidateKind.vertex:     return "vertex";
        case AiElementCandidateKind.edge:       return "edge";
        case AiElementCandidateKind.face:       return "face";
        case AiElementCandidateKind.background: return "background";
    }
}

/// Reverse of `aiElementCandidateKindId`: parse the serialized id back to its
/// enum (unknown ids → `none`). Lives next to the forward helper it inverts.
AiElementCandidateKind aiElementCandidateKindFromId(string id) {
    switch (id) {
        case "none":       return AiElementCandidateKind.none;
        case "vertex":     return AiElementCandidateKind.vertex;
        case "edge":       return AiElementCandidateKind.edge;
        case "face":       return AiElementCandidateKind.face;
        case "background": return AiElementCandidateKind.background;
        default:           return AiElementCandidateKind.none;
    }
}

private AiCandidate copyCandidate(const ref AiCandidate c) {
    auto copy = AiCandidate();
    copy.id = c.id;
    copy.kind = c.kind;
    copy.elementKind = c.elementKind;
    copy.intent = c.intent;
    copy.screenDist = c.screenDist;
    copy.worldDist = c.worldDist;
    copy.priorityFromCurrentRules = c.priorityFromCurrentRules;
    copy.isDefaultWinner = c.isDefaultWinner;
    copy.isExplicitModifierChoice = c.isExplicitModifierChoice;
    copy.hasScreenPosition = c.hasScreenPosition;
    copy.screenPosition = c.screenPosition;
    copy.hasWorldPosition = c.hasWorldPosition;
    copy.worldPosition = c.worldPosition;
    return copy;
}

struct AiCandidateDebugTrace {
    AiAdvisorDecision advisor;
    AiCandidate[] candidates;
    int defaultWinnerIndex = -1;
    string defaultWinnerId = "";
    int appliedWinnerIndex = -1;
    string appliedWinnerId = "";

    void clear() {
        advisor = AiAdvisorDecision();
        candidates.length = 0;
        defaultWinnerIndex = -1;
        defaultWinnerId = "";
        appliedWinnerIndex = -1;
        appliedWinnerId = "";
    }

    void set(const(AiCandidate)[] observed,
             AiAdvisorDecision decision = AiAdvisorDecision(),
             int appliedIndex = -1) {
        clear();
        advisor = decision;
        foreach (i, ref c; observed) {
            auto copy = copyCandidate(c);
            if (copy.isDefaultWinner && defaultWinnerIndex < 0) {
                defaultWinnerIndex = cast(int)i;
                defaultWinnerId = copy.id;
            }
            candidates ~= copy;
        }
        if (appliedIndex >= 0 &&
            cast(size_t)appliedIndex < candidates.length) {
            appliedWinnerIndex = appliedIndex;
            appliedWinnerId = candidates[cast(size_t)appliedIndex].id;
        } else if (defaultWinnerIndex >= 0) {
            appliedWinnerIndex = defaultWinnerIndex;
            appliedWinnerId = defaultWinnerId;
        }
    }

    void putTraceJson(B)(ref B buf, string fieldName) const {
        buf.put(`,"`);
        buf.put(fieldName);
        buf.put(`":{"candidateCount":`);
        buf.put(candidates.length.to!string);
        buf.put(`,"candidateIds":[`);
        foreach (i, ref c; candidates) {
            if (i) buf.put(`,`);
            buf.put(jsonString(c.id));
        }
        buf.put(`],"candidates":[`);
        foreach (i, ref c; candidates) {
            if (i) buf.put(`,`);
            buf.put(format(`{"id":%s,"elementKind":%s,` ~
                           `"isDefaultWinner":%s,"priorityFromCurrentRules":%f}`,
                           jsonString(c.id),
                           jsonString(aiElementCandidateKindId(c.elementKind)),
                           c.isDefaultWinner ? "true" : "false",
                           c.priorityFromCurrentRules));
        }
        buf.put(`],"defaultWinner":{`);
        buf.put(format(`"present":%s,"id":%s,"index":%d`,
                       defaultWinnerIndex >= 0 ? "true" : "false",
                       jsonString(defaultWinnerId),
                       defaultWinnerIndex));
        buf.put(`},"appliedWinner":{`);
        buf.put(format(`"present":%s,"id":%s,"index":%d`,
                       appliedWinnerIndex >= 0 ? "true" : "false",
                       jsonString(appliedWinnerId),
                       appliedWinnerIndex));
        buf.put(`}}`);
    }

    void putAdvisorJson(B)(ref B buf) const {
        buf.put(format(`{"intent":%s,"confidence":%f,"candidateIndex":%d,` ~
                       `"candidateId":%s,"keepDefault":%s}`,
                       jsonString(aiIntentId(advisor.intent)),
                       advisor.confidence,
                       advisor.candidateIndex,
                       jsonString(advisor.candidateId),
                       advisor.keepDefault ? "true" : "false"));
    }
}

alias AiHandleDebugTrace = AiCandidateDebugTrace;
alias AiElementDebugTrace = AiCandidateDebugTrace;
alias AiModeToolContextDebugTrace = AiCandidateDebugTrace;

private AiHandleDebugTrace g_latestHandleTrace;
private AiElementDebugTrace g_latestElementTrace;
private AiModeToolContextDebugTrace g_latestModeToolContextTrace;

private string tracesToJson(bool enabled) {
        auto buf = appender!string();
        buf.put(format(`{"enabled":%s`, enabled ? "true" : "false"));
        buf.put(`,"advisor":`);
        g_latestHandleTrace.putAdvisorJson(buf);
        g_latestHandleTrace.putTraceJson(buf, "handleTrace");
        g_latestElementTrace.putTraceJson(buf, "elementTrace");
        buf.put(`}`);
        return buf.data;
}

void clearLatestHandleDebugTrace() {
    g_latestHandleTrace.clear();
    g_latestElementTrace.clear();
    g_latestModeToolContextTrace.clear();
}

void clearLatestElementDebugTrace() {
    g_latestElementTrace.clear();
}

void clearLatestModeToolContextDebugTrace() {
    g_latestModeToolContextTrace.clear();
}

void clearLatestAiDebugTraces() {
    clearLatestHandleDebugTrace();
}

void publishHandleDebugTrace(const(AiCandidate)[] candidates,
                             AiAdvisorDecision decision = AiAdvisorDecision(),
                             int appliedWinnerIndex = -1) {
    g_latestHandleTrace.set(candidates, decision, appliedWinnerIndex);
}

void publishElementDebugTrace(const(AiCandidate)[] candidates,
                              AiAdvisorDecision decision = AiAdvisorDecision(),
                              int appliedWinnerIndex = -1) {
    g_latestElementTrace.set(candidates, decision, appliedWinnerIndex);
}

void publishModeToolContextDebugTrace(const(AiCandidate)[] candidates,
                                      AiAdvisorDecision decision = AiAdvisorDecision(),
                                      int appliedWinnerIndex = -1) {
    g_latestModeToolContextTrace.set(candidates, decision, appliedWinnerIndex);
}

const(AiHandleDebugTrace) latestHandleDebugTrace() {
    return g_latestHandleTrace;
}

const(AiElementDebugTrace) latestElementDebugTrace() {
    return g_latestElementTrace;
}

const(AiModeToolContextDebugTrace) latestModeToolContextDebugTrace() {
    return g_latestModeToolContextTrace;
}

string latestHandleDebugTraceJson(bool enabled) {
    return tracesToJson(enabled);
}

unittest {
    clearLatestAiDebugTraces();
    auto empty = latestHandleDebugTrace();
    assert(empty.candidates.length == 0);
    assert(empty.defaultWinnerIndex == -1);
    assert(empty.defaultWinnerId.length == 0);
    assert(empty.appliedWinnerIndex == -1);
    assert(empty.appliedWinnerId.length == 0);
    assert(empty.advisor.keepDefault);
    assert(latestHandleDebugTraceJson(false) ==
           `{"enabled":false,"advisor":{"intent":"keepDefault","confidence":0.000000,` ~
           `"candidateIndex":-1,"candidateId":"","keepDefault":true},` ~
           `"handleTrace":{"candidateCount":0,"candidateIds":[],"candidates":[],` ~
           `"defaultWinner":{"present":false,"id":"","index":-1},` ~
           `"appliedWinner":{"present":false,"id":"","index":-1}},` ~
           `"elementTrace":{"candidateCount":0,"candidateIds":[],"candidates":[],` ~
           `"defaultWinner":{"present":false,"id":"","index":-1},` ~
           `"appliedWinner":{"present":false,"id":"","index":-1}}}`);
}
