module ai.interaction_log;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.math : isFinite;

import ai.debug_trace : aiElementCandidateKindFromId, aiElementCandidateKindId,
    aiIntentFromId, aiIntentId;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiElementCandidateKind, AiInteractionContext, AiInteractionPhase, AiIntent;

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

/// Reverse of `aiInteractionPhaseId` (unknown ids → `unknown`). Lives next to
/// the forward helper it inverts so the parser's import closure stays settled.
AiInteractionPhase aiInteractionPhaseFromId(string id) {
    switch (id) {
        case "unknown":    return AiInteractionPhase.unknown;
        case "hover":      return AiInteractionPhase.hover;
        case "mouseDown":  return AiInteractionPhase.mouseDown;
        case "dragStart":  return AiInteractionPhase.dragStart;
        case "dragUpdate": return AiInteractionPhase.dragUpdate;
        case "dragCommit": return AiInteractionPhase.dragCommit;
        case "dragCancel": return AiInteractionPhase.dragCancel;
        case "toolSwitch": return AiInteractionPhase.toolSwitch;
        case "modeSwitch": return AiInteractionPhase.modeSwitch;
        default:           return AiInteractionPhase.unknown;
    }
}

/// Reverse of `aiCandidateKindId` (unknown ids → `unknown`).
AiCandidateKind aiCandidateKindFromId(string id) {
    switch (id) {
        case "unknown": return AiCandidateKind.unknown;
        case "element": return AiCandidateKind.element;
        case "handle":  return AiCandidateKind.handle;
        case "mode":    return AiCandidateKind.mode;
        case "context": return AiCandidateKind.context;
        default:        return AiCandidateKind.unknown;
    }
}

/// Parse one serialized record (the inverse of `toJsonLine`/`putJson`). Field
/// names mirror the hand-rolled serializer byte-for-byte; `appliedWinner.id`
/// and every `candidates[].id` are preserved verbatim so the parsed record
/// still labels through `aiRankerLabelFromRecord`. Non-finite floats are
/// serialized as `null` (`putJsonFloat`); we map `null` distances back to
/// `float.infinity` and `null` positions to `0`. The derived `keepDefault`
/// key in `advisorDecision` is read-only output and is intentionally ignored
/// (it is a `const` method, not a stored field).
AiInteractionLogRecord parseAiInteractionLogRecord(JSONValue v) {
    AiInteractionLogRecord record;
    auto obj = v.object;

    if (auto p = "schemaVersion" in obj)
        record.schemaVersion = cast(int)jsonToLong(*p);
    if (auto p = "sequence" in obj) {
        record.hasSequence = true;
        record.sequence = cast(ulong)jsonToLong(*p);
    }
    if (auto p = "timestampUnixMs" in obj) {
        record.hasTimestampUnixMs = true;
        record.timestampUnixMs = jsonToLong(*p);
    }
    if (auto p = "source" in obj)
        record.source = p.str;
    if (auto p = "groupId" in obj)
        record.groupId = p.str;
    if (auto p = "context" in obj)
        record.context = parseContext(*p);

    if (auto p = "candidates" in obj) {
        foreach (ref c; p.array)
            record.candidates ~= parseCandidate(c);
    }

    if (auto p = "advisorDecision" in obj)
        record.advisorDecision = parseAdvisorDecision(*p);

    if (auto p = "defaultWinner" in obj) {
        auto w = parseWinner(*p);
        record.defaultWinnerIndex = w.index;
        record.defaultWinnerId = w.id;
    }
    if (auto p = "appliedWinner" in obj) {
        auto w = parseWinner(*p);
        record.appliedWinnerIndex = w.index;
        record.appliedWinnerId = w.id;
    }
    if (auto p = "outcome" in obj)
        record.outcome = parseOutcome(*p);

    return record;
}

/// Convenience: parse a single JSONL line.
AiInteractionLogRecord parseAiInteractionLogLine(string line) {
    import std.json : parseJSON;
    return parseAiInteractionLogRecord(parseJSON(line));
}

private struct ParsedWinner { bool present; string id; int index = -1; }

private ParsedWinner parseWinner(const ref JSONValue v) {
    ParsedWinner w;
    auto obj = v.object;
    if (auto p = "present" in obj)
        w.present = p.boolean;
    if (auto p = "id" in obj)
        w.id = p.str;
    if (auto p = "index" in obj)
        w.index = cast(int)jsonToLong(*p);
    return w;
}

private AiInteractionContext parseContext(const ref JSONValue v) {
    AiInteractionContext c;
    auto obj = v.object;
    if (auto p = "phase" in obj)
        c.phase = aiInteractionPhaseFromId(p.str);
    if (auto p = "defaultIntent" in obj)
        c.defaultIntent = aiIntentFromId(p.str);
    if (auto p = "mouseX" in obj)
        c.mouseX = cast(int)jsonToLong(*p);
    if (auto p = "mouseY" in obj)
        c.mouseY = cast(int)jsonToLong(*p);
    if (auto p = "mouseDeltaX" in obj)
        c.mouseDeltaX = cast(int)jsonToLong(*p);
    if (auto p = "mouseDeltaY" in obj)
        c.mouseDeltaY = cast(int)jsonToLong(*p);
    if (auto p = "shift" in obj)
        c.shift = p.boolean;
    if (auto p = "ctrl" in obj)
        c.ctrl = p.boolean;
    if (auto p = "alt" in obj)
        c.alt = p.boolean;
    if (auto p = "isDragging" in obj)
        c.isDragging = p.boolean;
    if (auto p = "activeToolId" in obj)
        c.activeToolId = p.str;
    if (auto p = "editModeId" in obj)
        c.editModeId = p.str;
    return c;
}

private AiCandidate parseCandidate(const ref JSONValue v) {
    AiCandidate c;
    auto obj = v.object;
    if (auto p = "id" in obj)
        c.id = p.str;
    if (auto p = "kind" in obj)
        c.kind = aiCandidateKindFromId(p.str);
    if (auto p = "elementKind" in obj)
        c.elementKind = aiElementCandidateKindFromId(p.str);
    if (auto p = "intent" in obj)
        c.intent = aiIntentFromId(p.str);
    if (auto p = "screenDist" in obj)
        c.screenDist = jsonToFloat(*p, float.infinity);
    if (auto p = "worldDist" in obj)
        c.worldDist = jsonToFloat(*p, float.infinity);
    if (auto p = "priorityFromCurrentRules" in obj)
        c.priorityFromCurrentRules = jsonToFloat(*p, 0.0f);
    if (auto p = "isDefaultWinner" in obj)
        c.isDefaultWinner = p.boolean;
    if (auto p = "isExplicitModifierChoice" in obj)
        c.isExplicitModifierChoice = p.boolean;
    if (auto p = "screenPosition" in obj) {
        auto sp = p.object;
        if (auto pres = "present" in sp)
            c.hasScreenPosition = pres.boolean;
        if (auto x = "x" in sp)
            c.screenPosition[0] = jsonToFloat(*x, 0.0f);
        if (auto y = "y" in sp)
            c.screenPosition[1] = jsonToFloat(*y, 0.0f);
    }
    if (auto p = "worldPosition" in obj) {
        auto wp = p.object;
        if (auto pres = "present" in wp)
            c.hasWorldPosition = pres.boolean;
        if (auto x = "x" in wp)
            c.worldPosition[0] = jsonToFloat(*x, 0.0f);
        if (auto y = "y" in wp)
            c.worldPosition[1] = jsonToFloat(*y, 0.0f);
        if (auto z = "z" in wp)
            c.worldPosition[2] = jsonToFloat(*z, 0.0f);
    }
    return c;
}

private AiAdvisorDecision parseAdvisorDecision(const ref JSONValue v) {
    AiAdvisorDecision d;
    auto obj = v.object;
    if (auto p = "intent" in obj)
        d.intent = aiIntentFromId(p.str);
    if (auto p = "confidence" in obj)
        d.confidence = jsonToFloat(*p, 0.0f);
    if (auto p = "candidateIndex" in obj)
        d.candidateIndex = cast(int)jsonToLong(*p);
    if (auto p = "candidateId" in obj)
        d.candidateId = p.str;
    // "keepDefault" is a derived const method, not a stored field — ignore it.
    return d;
}

private AiInteractionLogOutcome parseOutcome(const ref JSONValue v) {
    AiInteractionLogOutcome o;
    auto obj = v.object;
    if (auto p = "present" in obj)
        o.present = p.boolean;
    if (auto p = "status" in obj)
        o.status = p.str;
    if (auto p = "reason" in obj)
        o.reason = p.str;
    if (auto p = "accepted" in obj)
        o.accepted = p.boolean;
    if (auto p = "note" in obj)
        o.note = p.str;
    return o;
}

private long jsonToLong(const ref JSONValue v) {
    import std.json : JSONType;
    final switch (v.type) {
        case JSONType.integer:  return v.integer;
        case JSONType.uinteger: return cast(long)v.uinteger;
        case JSONType.float_:   return cast(long)v.floating;
        case JSONType.string:   return v.str.to!long;
        case JSONType.true_:    return 1;
        case JSONType.false_:   return 0;
        case JSONType.null_:    return 0;
        case JSONType.array:    return 0;
        case JSONType.object:   return 0;
    }
}

// `putJsonFloat` emits `null` for non-finite values; map that back to the
// caller-supplied default (infinity for distances, 0 for positions).
private float jsonToFloat(const ref JSONValue v, float fallback) {
    import std.json : JSONType;
    switch (v.type) {
        case JSONType.float_:    return cast(float)v.floating;
        case JSONType.integer:   return cast(float)v.integer;
        case JSONType.uinteger:  return cast(float)v.uinteger;
        case JSONType.null_:     return fallback;
        default:                 return fallback;
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

// Round-trip: a fully-populated record survives toJsonLine -> parse ->
// toJsonLine unchanged (string equality sidesteps float formatting).
unittest {
    AiInteractionContext ctx;
    ctx.phase = AiInteractionPhase.mouseDown;
    ctx.defaultIntent = AiIntent.selectElement;
    ctx.mouseX = 120;
    ctx.mouseY = 240;
    ctx.mouseDeltaX = -3;
    ctx.mouseDeltaY = 7;
    ctx.shift = true;
    ctx.alt = true;
    ctx.activeToolId = "move";
    ctx.editModeId = "vertices";

    AiCandidate c0;
    c0.id = "element:vertex:3";
    c0.kind = AiCandidateKind.element;
    c0.elementKind = AiElementCandidateKind.vertex;
    c0.intent = AiIntent.hoverElement;
    c0.screenDist = 0.0f;            // finite
    c0.worldDist = float.infinity;   // null on the wire
    c0.priorityFromCurrentRules = 0.0f;
    c0.isDefaultWinner = true;
    c0.hasScreenPosition = true;
    c0.screenPosition = [120.0f, 240.0f];
    c0.hasWorldPosition = true;
    c0.worldPosition = [1.5f, -2.25f, 0.0f];

    AiCandidate c1;
    c1.id = "element:edge:9";
    c1.kind = AiCandidateKind.element;
    c1.elementKind = AiElementCandidateKind.edge;
    c1.intent = AiIntent.hoverElement;

    AiAdvisorDecision adv;
    adv.intent = AiIntent.selectElement;
    adv.confidence = 0.875f;
    adv.candidateIndex = 0;
    adv.candidateId = "element:vertex:3";

    auto record = makeAiInteractionLogRecord("live-session:42", "elements",
                                             ctx, [c0, c1], adv, 0)
                      .withSequence(7)
                      .withTimestampUnixMs(1700000000000L)
                      .withOutcome("applied", "user-pick", true, "note");

    auto line = record.toJsonLine();
    auto reparsed = parseAiInteractionLogLine(line);
    assert(reparsed.toJsonLine() == line);

    // Label-bearing fields survive byte-exact (coverage guard).
    assert(reparsed.appliedWinnerId == "element:vertex:3");
    assert(reparsed.candidates.length == 2);
    assert(reparsed.candidates[0].id == "element:vertex:3");
    assert(reparsed.candidates[1].id == "element:edge:9");
    // Non-finite float round-trips through null.
    assert(reparsed.candidates[0].worldDist == float.infinity);
    assert(reparsed.candidates[0].screenDist == 0.0f);

    // A minimal record (no optional sequence/timestamp) parses cleanly.
    AiInteractionContext minCtx;
    auto minimal = makeAiInteractionLogRecord("live-session", "handles",
                                              minCtx, []);
    auto minLine = minimal.toJsonLine();
    auto minBack = parseAiInteractionLogLine(minLine);
    assert(!minBack.hasSequence);
    assert(!minBack.hasTimestampUnixMs);
    assert(minBack.toJsonLine() == minLine);
}
