// Pure tests for JSONL-ready AI interaction log records.

import std.algorithm : canFind;
import std.json : JSONType, parseJSON;

import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiElementCandidateKind, AiInteractionContext, AiInteractionPhase,
    AiIntent;
import ai.interaction_log : AiInteractionLogRecord,
    aiInteractionLogSchemaVersion, makeAiInteractionLogRecord;

void main() {}

unittest { // empty/default record is deterministic and has no optional clocks
    auto record = AiInteractionLogRecord();
    auto json = record.toJsonLine();
    assert(!json.canFind(`"sequence"`));
    assert(!json.canFind(`"timestampUnixMs"`));

    auto j = parseJSON(json);
    assert(j["schemaVersion"].integer == aiInteractionLogSchemaVersion);
    assert(j["source"].str.length == 0);
    assert(j["groupId"].str.length == 0);
    assert(j["context"]["phase"].str == "unknown");
    assert(j["context"]["defaultIntent"].str == "keepDefault");
    assert(j["context"]["mouseX"].integer == -1);
    assert(j["context"]["mouseY"].integer == -1);
    assert(j["context"]["shift"].type == JSONType.false_);
    assert(j["context"]["ctrl"].type == JSONType.false_);
    assert(j["context"]["alt"].type == JSONType.false_);
    assert(j["context"]["isDragging"].type == JSONType.false_);
    assert(j["candidates"].array.length == 0);
    assert(j["advisorDecision"]["intent"].str == "keepDefault");
    assert(j["advisorDecision"]["keepDefault"].type == JSONType.true_);
    assert(j["defaultWinner"]["present"].type == JSONType.false_);
    assert(j["appliedWinner"]["present"].type == JSONType.false_);
    assert(j["outcome"]["present"].type == JSONType.false_);
}

unittest { // handle candidates include explicit group id, positions, and winner ids
    AiInteractionContext context;
    context.phase = AiInteractionPhase.mouseDown;
    context.defaultIntent = AiIntent.handle;
    context.mouseX = 320;
    context.mouseY = 240;
    context.mouseDeltaX = 7;
    context.mouseDeltaY = -3;
    context.shift = true;
    context.isDragging = true;
    context.activeToolId = "xfrm.transform";
    context.editModeId = "vertices";

    AiCandidate x;
    x.id = "handle:x";
    x.kind = AiCandidateKind.handle;
    x.intent = AiIntent.dragAxisX;
    x.screenDist = 12.5f;
    x.priorityFromCurrentRules = 1.0f;
    x.isDefaultWinner = true;
    x.hasScreenPosition = true;
    x.screenPosition = [320.0f, 240.0f];

    AiCandidate y;
    y.id = "handle:y";
    y.kind = AiCandidateKind.handle;
    y.intent = AiIntent.dragAxisY;
    y.screenDist = 2.0f;
    y.priorityFromCurrentRules = 0.0f;
    y.isExplicitModifierChoice = true;

    AiAdvisorDecision decision;
    decision.intent = AiIntent.dragAxisY;
    decision.confidence = 0.875f;
    decision.candidateIndex = 1;
    decision.candidateId = "handle:y";

    auto record = makeAiInteractionLogRecord(
        "tool-handles", "handles", context, [x, y], decision, 1);
    record.withSequence(42).withTimestampUnixMs(1_771_771_234_000);

    auto j = parseJSON(record.toJsonLine());
    assert(j["sequence"].integer == 42);
    assert(j["timestampUnixMs"].integer == 1_771_771_234_000);
    assert(j["source"].str == "tool-handles");
    assert(j["groupId"].str == "handles");
    assert(j["context"]["phase"].str == "mouseDown");
    assert(j["context"]["defaultIntent"].str == "handle");
    assert(j["context"]["mouseDeltaX"].integer == 7);
    assert(j["context"]["mouseDeltaY"].integer == -3);
    assert(j["context"]["shift"].type == JSONType.true_);
    assert(j["context"]["isDragging"].type == JSONType.true_);
    assert(j["context"]["activeToolId"].str == "xfrm.transform");

    auto candidates = j["candidates"].array;
    assert(candidates.length == 2);
    assert(candidates[0]["id"].str == "handle:x");
    assert(candidates[0]["kind"].str == "handle");
    assert(candidates[0]["intent"].str == "dragAxisX");
    assert(candidates[0]["isDefaultWinner"].type == JSONType.true_);
    assert(candidates[0]["screenPosition"]["present"].type == JSONType.true_);
    assert(candidates[0]["screenPosition"]["x"].floating == 320.0);
    assert(candidates[1]["id"].str == "handle:y");
    assert(candidates[1]["isExplicitModifierChoice"].type == JSONType.true_);

    assert(j["advisorDecision"]["intent"].str == "dragAxisY");
    assert(j["advisorDecision"]["candidateIndex"].integer == 1);
    assert(j["advisorDecision"]["candidateId"].str == "handle:y");
    assert(j["advisorDecision"]["keepDefault"].type == JSONType.false_);
    assert(j["defaultWinner"]["id"].str == "handle:x");
    assert(j["defaultWinner"]["index"].integer == 0);
    assert(j["appliedWinner"]["id"].str == "handle:y");
    assert(j["appliedWinner"]["index"].integer == 1);
}

unittest { // element candidates preserve element kind and world coordinates
    AiInteractionContext context;
    context.phase = AiInteractionPhase.hover;
    context.defaultIntent = AiIntent.hoverElement;

    AiCandidate vertex;
    vertex.id = "element:vertex:3";
    vertex.kind = AiCandidateKind.element;
    vertex.elementKind = AiElementCandidateKind.vertex;
    vertex.intent = AiIntent.hoverElement;
    vertex.isDefaultWinner = true;
    vertex.hasWorldPosition = true;
    vertex.worldPosition = [1.0f, 2.0f, 3.0f];

    AiCandidate face;
    face.id = "element:face:8";
    face.kind = AiCandidateKind.element;
    face.elementKind = AiElementCandidateKind.face;
    face.intent = AiIntent.selectElement;

    auto record = makeAiInteractionLogRecord(
        "picker", "elements", context, [vertex, face]);

    auto candidates = parseJSON(record.toJsonLine())["candidates"].array;
    assert(candidates[0]["kind"].str == "element");
    assert(candidates[0]["elementKind"].str == "vertex");
    assert(candidates[0]["worldPosition"]["present"].type == JSONType.true_);
    assert(candidates[0]["worldPosition"]["z"].floating == 3.0);
    assert(candidates[1]["elementKind"].str == "face");
    assert(candidates[1]["intent"].str == "selectElement");
}

unittest { // mode/context candidates can be represented by their group id
    AiInteractionContext context;
    context.phase = AiInteractionPhase.modeSwitch;
    context.editModeId = "edges";

    AiCandidate mode;
    mode.id = "mode:edge";
    mode.kind = AiCandidateKind.mode;
    mode.intent = AiIntent.keepDefault;
    mode.isDefaultWinner = true;

    AiCandidate tool;
    tool.id = "tool:bevel";
    tool.kind = AiCandidateKind.context;
    tool.intent = AiIntent.keepDefault;

    auto record = makeAiInteractionLogRecord(
        "mode-tool-context", "mode-tool-context", context, [mode, tool]);

    auto j = parseJSON(record.toJsonLine());
    assert(j["groupId"].str == "mode-tool-context");
    assert(j["context"]["phase"].str == "modeSwitch");
    assert(j["candidates"].array[0]["kind"].str == "mode");
    assert(j["candidates"].array[1]["kind"].str == "context");
    assert(j["defaultWinner"]["id"].str == "mode:edge");
    assert(j["appliedWinner"]["id"].str == "mode:edge");
}

unittest { // outcome metadata and escaped strings survive JSON round trip
    AiInteractionContext context;
    context.activeToolId = "tool \"quoted\"\nnext";
    context.editModeId = "poly\\face";

    AiCandidate candidate;
    candidate.id = "candidate \"A\"\nslash\\end";
    candidate.kind = AiCandidateKind.context;
    candidate.intent = AiIntent.keepDefault;
    candidate.isDefaultWinner = true;

    auto record = makeAiInteractionLogRecord(
        "source\nline", "group\"id", context, [candidate]);
    record.withOutcome("accepted", "manual \"override\"\nline", true,
                       "note\\tail");

    auto j = parseJSON(record.toJsonLine());
    assert(j["source"].str == "source\nline");
    assert(j["groupId"].str == `group"id`);
    assert(j["context"]["activeToolId"].str == "tool \"quoted\"\nnext");
    assert(j["context"]["editModeId"].str == `poly\face`);
    assert(j["candidates"].array[0]["id"].str ==
           "candidate \"A\"\nslash\\end");
    assert(j["outcome"]["present"].type == JSONType.true_);
    assert(j["outcome"]["status"].str == "accepted");
    assert(j["outcome"]["reason"].str == "manual \"override\"\nline");
    assert(j["outcome"]["accepted"].type == JSONType.true_);
    assert(j["outcome"]["note"].str == `note\tail`);
}

unittest { // stable top-level field order stays suitable for JSONL snapshots
    auto json = AiInteractionLogRecord().toJsonLine();
    assert(json ==
           `{"schemaVersion":1,"source":"","groupId":"","context":` ~
           `{"phase":"unknown","defaultIntent":"keepDefault",` ~
           `"mouseX":-1,"mouseY":-1,"mouseDeltaX":0,"mouseDeltaY":0,` ~
           `"shift":false,"ctrl":false,"alt":false,"isDragging":false,` ~
           `"activeToolId":"","editModeId":""},` ~
           `"candidates":[],"advisorDecision":` ~
           `{"intent":"keepDefault","confidence":0.000000,` ~
           `"candidateIndex":-1,"candidateId":"","keepDefault":true},` ~
           `"defaultWinner":{"present":false,"id":"","index":-1},` ~
           `"appliedWinner":{"present":false,"id":"","index":-1},` ~
           `"outcome":{"present":false,"status":"","reason":"",` ~
           `"accepted":false,"note":""}}`);
}
