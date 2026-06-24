module ai.debug_trace;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;

import ai.interaction : AiAdvisorDecision, AiCandidate, AiIntent;

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

private string jsonString(string s) {
    return JSONValue(s).toString();
}

struct AiHandleDebugTrace {
    AiAdvisorDecision advisor;
    AiCandidate[] candidates;
    int defaultWinnerIndex = -1;
    string defaultWinnerId = "";

    void clear() {
        advisor = AiAdvisorDecision();
        candidates.length = 0;
        defaultWinnerIndex = -1;
        defaultWinnerId = "";
    }

    void set(const(AiCandidate)[] observed,
             AiAdvisorDecision decision = AiAdvisorDecision()) {
        clear();
        advisor = decision;
        foreach (i, ref c; observed) {
            auto copy = AiCandidate();
            copy.id = c.id;
            copy.kind = c.kind;
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
            if (copy.isDefaultWinner && defaultWinnerIndex < 0) {
                defaultWinnerIndex = cast(int)i;
                defaultWinnerId = copy.id;
            }
            candidates ~= copy;
        }
    }

    string toJson(bool enabled) const {
        auto buf = appender!string();
        buf.put(format(`{"enabled":%s`, enabled ? "true" : "false"));
        buf.put(`,"advisor":`);
        putAdvisorJson(buf);
        buf.put(`,"handleTrace":{"candidateCount":`);
        buf.put(candidates.length.to!string);
        buf.put(`,"candidateIds":[`);
        foreach (i, ref c; candidates) {
            if (i) buf.put(`,`);
            buf.put(jsonString(c.id));
        }
        buf.put(`],"defaultWinner":{`);
        buf.put(format(`"present":%s,"id":%s,"index":%d`,
                       defaultWinnerIndex >= 0 ? "true" : "false",
                       jsonString(defaultWinnerId),
                       defaultWinnerIndex));
        buf.put(`}}}`);
        return buf.data;
    }

    private void putAdvisorJson(B)(ref B buf) const {
        buf.put(format(`{"intent":%s,"confidence":%f,"candidateIndex":%d,` ~
                       `"candidateId":%s,"keepDefault":%s}`,
                       jsonString(aiIntentId(advisor.intent)),
                       advisor.confidence,
                       advisor.candidateIndex,
                       jsonString(advisor.candidateId),
                       advisor.keepDefault ? "true" : "false"));
    }
}

private AiHandleDebugTrace g_latestHandleTrace;

void clearLatestHandleDebugTrace() {
    g_latestHandleTrace.clear();
}

void publishHandleDebugTrace(const(AiCandidate)[] candidates,
                             AiAdvisorDecision decision = AiAdvisorDecision()) {
    g_latestHandleTrace.set(candidates, decision);
}

const(AiHandleDebugTrace) latestHandleDebugTrace() {
    return g_latestHandleTrace;
}

string latestHandleDebugTraceJson(bool enabled) {
    return g_latestHandleTrace.toJson(enabled);
}

unittest {
    clearLatestHandleDebugTrace();
    auto empty = latestHandleDebugTrace();
    assert(empty.candidates.length == 0);
    assert(empty.defaultWinnerIndex == -1);
    assert(empty.defaultWinnerId.length == 0);
    assert(empty.advisor.keepDefault);
    assert(empty.toJson(false) ==
           `{"enabled":false,"advisor":{"intent":"keepDefault","confidence":0.000000,` ~
           `"candidateIndex":-1,"candidateId":"","keepDefault":true},` ~
           `"handleTrace":{"candidateCount":0,"candidateIds":[],` ~
           `"defaultWinner":{"present":false,"id":"","index":-1}}}`);
}
