module ai.interaction_log;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.math : isFinite;

import ai.debug_trace : aiElementCandidateKindId, aiIntentId;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase;

enum aiInteractionLogSchemaVersion = 1;

struct AiInteractionLogOutcome {
    bool present = false;
    string status = "";
    string reason = "";
    bool accepted = false;
    string note = "";
}

struct AiInteractionLogRecord {
    int schemaVersion = aiInteractionLogSchemaVersion;
    bool hasSequence = false;
    ulong sequence = 0;
    bool hasTimestampUnixMs = false;
    long timestampUnixMs = 0;
    string source = "";
    string groupId = "";
    AiInteractionContext context;
    AiCandidate[] candidates;
    AiAdvisorDecision advisorDecision;
    int defaultWinnerIndex = -1;
    string defaultWinnerId = "";
    int appliedWinnerIndex = -1;
    string appliedWinnerId = "";
    AiInteractionLogOutcome outcome;

    ref AiInteractionLogRecord withSequence(ulong value) return {
        hasSequence = true;
        sequence = value;
        return this;
    }

    ref AiInteractionLogRecord withTimestampUnixMs(long value) return {
        hasTimestampUnixMs = true;
        timestampUnixMs = value;
        return this;
    }

    ref AiInteractionLogRecord withSource(string value) return {
        source = value;
        return this;
    }

    ref AiInteractionLogRecord withGroupId(string value) return {
        groupId = value;
        return this;
    }

    ref AiInteractionLogRecord withContext(const ref AiInteractionContext value) return {
        context = copyContext(value);
        return this;
    }

    ref AiInteractionLogRecord withCandidates(const(AiCandidate)[] values,
                                              int appliedIndex = -1) return {
        candidates.length = 0;
        defaultWinnerIndex = -1;
        defaultWinnerId = "";
        appliedWinnerIndex = -1;
        appliedWinnerId = "";

        foreach (i, ref candidate; values) {
            auto copy = copyCandidate(candidate);
            if (copy.isDefaultWinner && defaultWinnerIndex < 0) {
                defaultWinnerIndex = cast(int)i;
                defaultWinnerId = copy.id;
            }
            candidates ~= copy;
        }

        if (appliedIndex >= 0 && cast(size_t)appliedIndex < candidates.length) {
            appliedWinnerIndex = appliedIndex;
            appliedWinnerId = candidates[cast(size_t)appliedIndex].id;
        } else if (defaultWinnerIndex >= 0) {
            appliedWinnerIndex = defaultWinnerIndex;
            appliedWinnerId = defaultWinnerId;
        }
        return this;
    }

    ref AiInteractionLogRecord withAdvisorDecision(
        const ref AiAdvisorDecision value) return {
        advisorDecision = copyAdvisorDecision(value);
        return this;
    }

    ref AiInteractionLogRecord withAppliedWinner(int index, string id) return {
        appliedWinnerIndex = index;
        appliedWinnerId = id;
        return this;
    }

    ref AiInteractionLogRecord withOutcome(string status, string reason = "",
                                           bool accepted = false,
                                           string note = "") return {
        outcome.present = true;
        outcome.status = status;
        outcome.reason = reason;
        outcome.accepted = accepted;
        outcome.note = note;
        return this;
    }

    string toJsonLine() const {
        auto buf = appender!string();
        putJson(buf);
        return buf.data;
    }

    void putJson(B)(ref B buf) const {
        buf.put(`{"schemaVersion":`);
        buf.put(schemaVersion.to!string);
        if (hasSequence) {
            buf.put(`,"sequence":`);
            buf.put(sequence.to!string);
        }
        if (hasTimestampUnixMs) {
            buf.put(`,"timestampUnixMs":`);
            buf.put(timestampUnixMs.to!string);
        }
        buf.put(`,"source":`);
        putJsonString(buf, source);
        buf.put(`,"groupId":`);
        putJsonString(buf, groupId);
        buf.put(`,"context":`);
        putContextJson(buf, context);
        buf.put(`,"candidates":[`);
        foreach (i, ref candidate; candidates) {
            if (i) buf.put(`,`);
            putCandidateJson(buf, candidate);
        }
        buf.put(`],"advisorDecision":`);
        putAdvisorDecisionJson(buf, advisorDecision);
        buf.put(`,"defaultWinner":`);
        putWinnerJson(buf, defaultWinnerIndex, defaultWinnerId);
        buf.put(`,"appliedWinner":`);
        putWinnerJson(buf, appliedWinnerIndex, appliedWinnerId);
        buf.put(`,"outcome":`);
        putOutcomeJson(buf, outcome);
        buf.put(`}`);
    }
}

AiInteractionLogRecord makeAiInteractionLogRecord(
    string source,
    string groupId,
    const ref AiInteractionContext context,
    const(AiCandidate)[] candidates,
    AiAdvisorDecision advisorDecision = AiAdvisorDecision(),
    int appliedWinnerIndex = -1) {
    auto record = AiInteractionLogRecord();
    record.withSource(source)
          .withGroupId(groupId)
          .withContext(context)
          .withCandidates(candidates, appliedWinnerIndex)
          .withAdvisorDecision(advisorDecision);
    return record;
}

string aiInteractionPhaseId(AiInteractionPhase phase) {
    final switch (phase) {
        case AiInteractionPhase.unknown:    return "unknown";
        case AiInteractionPhase.hover:      return "hover";
        case AiInteractionPhase.mouseDown:  return "mouseDown";
        case AiInteractionPhase.dragStart:  return "dragStart";
        case AiInteractionPhase.dragUpdate: return "dragUpdate";
        case AiInteractionPhase.dragCommit: return "dragCommit";
        case AiInteractionPhase.dragCancel: return "dragCancel";
        case AiInteractionPhase.toolSwitch: return "toolSwitch";
        case AiInteractionPhase.modeSwitch: return "modeSwitch";
    }
}

string aiCandidateKindId(AiCandidateKind kind) {
    final switch (kind) {
        case AiCandidateKind.unknown: return "unknown";
        case AiCandidateKind.element: return "element";
        case AiCandidateKind.handle:  return "handle";
        case AiCandidateKind.mode:    return "mode";
        case AiCandidateKind.context: return "context";
    }
}

private void putJsonString(B)(ref B buf, string value) {
    buf.put(JSONValue(value).toString());
}

private void putContextJson(B)(ref B buf, const ref AiInteractionContext context) {
    buf.put(`{"phase":`);
    putJsonString(buf, aiInteractionPhaseId(context.phase));
    buf.put(`,"defaultIntent":`);
    putJsonString(buf, aiIntentId(context.defaultIntent));
    buf.put(format(`,"mouseX":%d,"mouseY":%d,"mouseDeltaX":%d,` ~
                   `"mouseDeltaY":%d,"shift":%s,"ctrl":%s,"alt":%s,` ~
                   `"isDragging":%s,"activeToolId":`,
                   context.mouseX,
                   context.mouseY,
                   context.mouseDeltaX,
                   context.mouseDeltaY,
                   jsonBool(context.shift),
                   jsonBool(context.ctrl),
                   jsonBool(context.alt),
                   jsonBool(context.isDragging)));
    putJsonString(buf, context.activeToolId);
    buf.put(`,"editModeId":`);
    putJsonString(buf, context.editModeId);
    buf.put(`}`);
}

private void putCandidateJson(B)(ref B buf, const ref AiCandidate candidate) {
    buf.put(`{"id":`);
    putJsonString(buf, candidate.id);
    buf.put(`,"kind":`);
    putJsonString(buf, aiCandidateKindId(candidate.kind));
    buf.put(`,"elementKind":`);
    putJsonString(buf, aiElementCandidateKindId(candidate.elementKind));
    buf.put(`,"intent":`);
    putJsonString(buf, aiIntentId(candidate.intent));
    buf.put(`,"screenDist":`);
    putJsonFloat(buf, candidate.screenDist);
    buf.put(`,"worldDist":`);
    putJsonFloat(buf, candidate.worldDist);
    buf.put(`,"priorityFromCurrentRules":`);
    putJsonFloat(buf, candidate.priorityFromCurrentRules);
    buf.put(format(`,"isDefaultWinner":%s,` ~
                   `"isExplicitModifierChoice":%s,` ~
                   `"screenPosition":{"present":%s,"x":`,
                   jsonBool(candidate.isDefaultWinner),
                   jsonBool(candidate.isExplicitModifierChoice),
                   jsonBool(candidate.hasScreenPosition)));
    putJsonFloat(buf, candidate.screenPosition[0]);
    buf.put(`,"y":`);
    putJsonFloat(buf, candidate.screenPosition[1]);
    buf.put(format(`},"worldPosition":{"present":%s,"x":`,
                   jsonBool(candidate.hasWorldPosition)));
    putJsonFloat(buf, candidate.worldPosition[0]);
    buf.put(`,"y":`);
    putJsonFloat(buf, candidate.worldPosition[1]);
    buf.put(`,"z":`);
    putJsonFloat(buf, candidate.worldPosition[2]);
    buf.put(`}}`);
}

private void putAdvisorDecisionJson(B)(ref B buf,
                                       const ref AiAdvisorDecision decision) {
    buf.put(`{"intent":`);
    putJsonString(buf, aiIntentId(decision.intent));
    buf.put(`,"confidence":`);
    putJsonFloat(buf, decision.confidence);
    buf.put(format(`,"candidateIndex":%d,"candidateId":`,
                   decision.candidateIndex));
    putJsonString(buf, decision.candidateId);
    buf.put(`,"keepDefault":`);
    buf.put(jsonBool(decision.keepDefault));
    buf.put(`}`);
}

private void putWinnerJson(B)(ref B buf, int index, string id) {
    buf.put(format(`{"present":%s,"id":`,
                   index >= 0 ? "true" : "false"));
    putJsonString(buf, id);
    buf.put(format(`,"index":%d}`, index));
}

private void putOutcomeJson(B)(ref B buf,
                               const ref AiInteractionLogOutcome outcome) {
    buf.put(`{"present":`);
    buf.put(jsonBool(outcome.present));
    buf.put(`,"status":`);
    putJsonString(buf, outcome.status);
    buf.put(`,"reason":`);
    putJsonString(buf, outcome.reason);
    buf.put(`,"accepted":`);
    buf.put(jsonBool(outcome.accepted));
    buf.put(`,"note":`);
    putJsonString(buf, outcome.note);
    buf.put(`}`);
}

private string jsonBool(bool value) {
    return value ? "true" : "false";
}

private void putJsonFloat(B)(ref B buf, float value) {
    if (value.isFinite)
        buf.put(format("%f", value));
    else
        buf.put(`null`);
}

private AiInteractionContext copyContext(const ref AiInteractionContext context) {
    auto copy = AiInteractionContext();
    copy.phase = context.phase;
    copy.defaultIntent = context.defaultIntent;
    copy.mouseX = context.mouseX;
    copy.mouseY = context.mouseY;
    copy.mouseDeltaX = context.mouseDeltaX;
    copy.mouseDeltaY = context.mouseDeltaY;
    copy.shift = context.shift;
    copy.ctrl = context.ctrl;
    copy.alt = context.alt;
    copy.isDragging = context.isDragging;
    copy.activeToolId = context.activeToolId;
    copy.editModeId = context.editModeId;
    return copy;
}

private AiCandidate copyCandidate(const ref AiCandidate candidate) {
    auto copy = AiCandidate();
    copy.id = candidate.id;
    copy.kind = candidate.kind;
    copy.elementKind = candidate.elementKind;
    copy.intent = candidate.intent;
    copy.screenDist = candidate.screenDist;
    copy.worldDist = candidate.worldDist;
    copy.priorityFromCurrentRules = candidate.priorityFromCurrentRules;
    copy.isDefaultWinner = candidate.isDefaultWinner;
    copy.isExplicitModifierChoice = candidate.isExplicitModifierChoice;
    copy.hasScreenPosition = candidate.hasScreenPosition;
    copy.screenPosition = candidate.screenPosition;
    copy.hasWorldPosition = candidate.hasWorldPosition;
    copy.worldPosition = candidate.worldPosition;
    return copy;
}

private AiAdvisorDecision copyAdvisorDecision(
    const ref AiAdvisorDecision decision) {
    auto copy = AiAdvisorDecision();
    copy.intent = decision.intent;
    copy.confidence = decision.confidence;
    copy.candidateIndex = decision.candidateIndex;
    copy.candidateId = decision.candidateId;
    return copy;
}

unittest {
    auto record = AiInteractionLogRecord();
    assert(record.schemaVersion == aiInteractionLogSchemaVersion);
    assert(!record.hasSequence);
    assert(!record.hasTimestampUnixMs);
    assert(record.source.length == 0);
    assert(record.groupId.length == 0);
    assert(record.candidates.length == 0);
    assert(record.defaultWinnerIndex == -1);
    assert(record.appliedWinnerIndex == -1);
    assert(!record.outcome.present);
}
