// Pure tests for the AI handle debug trace serialization.

import std.json : JSONType, parseJSON;

import ai.debug_trace;
import ai.interaction;

void main() {}

unittest { // default-empty trace is deterministic and safe
    clearLatestAiDebugTraces();

    auto j = parseJSON(latestHandleDebugTraceJson(false));
    assert(j["enabled"].type == JSONType.false_);
    assert(j["advisor"]["intent"].str == "keepDefault");
    assert(j["advisor"]["confidence"].floating == 0.0);
    assert(j["advisor"]["candidateIndex"].integer == -1);
    assert(j["advisor"]["candidateId"].str.length == 0);
    assert(j["advisor"]["keepDefault"].type == JSONType.true_);

    auto trace = j["handleTrace"];
    assert(trace["candidateCount"].integer == 0);
    assert(trace["candidateIds"].array.length == 0);
    assert(trace["candidates"].array.length == 0);
    assert(trace["defaultWinner"]["present"].type == JSONType.false_);
    assert(trace["defaultWinner"]["id"].str.length == 0);
    assert(trace["defaultWinner"]["index"].integer == -1);
    assert(trace["appliedWinner"]["present"].type == JSONType.false_);
    assert(trace["appliedWinner"]["id"].str.length == 0);
    assert(trace["appliedWinner"]["index"].integer == -1);

    auto elementTrace = j["elementTrace"];
    assert(elementTrace["candidateCount"].integer == 0);
    assert(elementTrace["candidateIds"].array.length == 0);
    assert(elementTrace["candidates"].array.length == 0);
    assert(elementTrace["defaultWinner"]["present"].type == JSONType.false_);
    assert(elementTrace["appliedWinner"]["present"].type == JSONType.false_);
}

unittest { // populated trace preserves candidate order and default winner
    clearLatestHandleDebugTrace();

    AiCandidate first;
    first.id = "handle:10";
    first.kind = AiCandidateKind.handle;
    first.intent = AiIntent.dragAxisX;
    first.priorityFromCurrentRules = 0.0f;
    first.isDefaultWinner = true;

    AiCandidate second;
    second.id = "handle:30";
    second.kind = AiCandidateKind.handle;
    second.intent = AiIntent.dragAxisZ;
    second.priorityFromCurrentRules = 2.0f;

    publishHandleDebugTrace([first, second]);

    auto j = parseJSON(latestHandleDebugTraceJson(true));
    assert(j["enabled"].type == JSONType.true_);
    assert(j["advisor"]["intent"].str == "keepDefault");
    assert(j["advisor"]["confidence"].floating == 0.0);
    assert(j["advisor"]["candidateIndex"].integer == -1);
    assert(j["advisor"]["keepDefault"].type == JSONType.true_);

    auto trace = j["handleTrace"];
    assert(trace["candidateCount"].integer == 2);
    assert(trace["candidateIds"].array[0].str == "handle:10");
    assert(trace["candidateIds"].array[1].str == "handle:30");
    assert(trace["candidates"].array[0]["id"].str == "handle:10");
    assert(trace["candidates"].array[0]["elementKind"].str == "none");
    assert(trace["candidates"].array[0]["isDefaultWinner"].type == JSONType.true_);
    assert(trace["candidates"].array[1]["id"].str == "handle:30");
    assert(trace["defaultWinner"]["present"].type == JSONType.true_);
    assert(trace["defaultWinner"]["id"].str == "handle:10");
    assert(trace["defaultWinner"]["index"].integer == 0);
    assert(trace["appliedWinner"]["present"].type == JSONType.true_);
    assert(trace["appliedWinner"]["id"].str == "handle:10");
    assert(trace["appliedWinner"]["index"].integer == 0);
}

unittest { // explicit advisor decisions serialize with the applied winner
    clearLatestHandleDebugTrace();

    AiCandidate candidate;
    candidate.id = "handle:42";
    candidate.kind = AiCandidateKind.handle;
    candidate.isDefaultWinner = true;

    AiAdvisorDecision decision;
    decision.intent = AiIntent.keepDefault;
    decision.confidence = 0.25f;
    decision.candidateIndex = 0;
    decision.candidateId = "handle:42";

    publishHandleDebugTrace([candidate], decision, 0);

    auto j = parseJSON(latestHandleDebugTraceJson(true));
    assert(j["advisor"]["intent"].str == "keepDefault");
    assert(j["advisor"]["confidence"].floating == 0.25);
    assert(j["advisor"]["candidateIndex"].integer == 0);
    assert(j["advisor"]["candidateId"].str == "handle:42");
    assert(j["advisor"]["keepDefault"].type == JSONType.true_);
    assert(j["handleTrace"]["defaultWinner"]["id"].str == "handle:42");
    assert(j["handleTrace"]["appliedWinner"]["id"].str == "handle:42");
}

unittest { // element trace preserves ids, element shape, and default winner
    clearLatestAiDebugTraces();

    AiCandidate vertex;
    vertex.id = "element:vertex:3";
    vertex.kind = AiCandidateKind.element;
    vertex.elementKind = AiElementCandidateKind.vertex;
    vertex.intent = AiIntent.hoverElement;
    vertex.priorityFromCurrentRules = 0.0f;
    vertex.isDefaultWinner = true;
    vertex.hasScreenPosition = true;
    vertex.screenPosition = [10.0f, 20.0f];

    AiCandidate face;
    face.id = "element:face:8";
    face.kind = AiCandidateKind.element;
    face.elementKind = AiElementCandidateKind.face;
    face.intent = AiIntent.hoverElement;
    face.priorityFromCurrentRules = 2.0f;

    publishElementDebugTrace([vertex, face]);

    auto trace = latestElementDebugTrace();
    assert(trace.candidates.length == 2);
    assert(trace.candidates[0].id == "element:vertex:3");
    assert(trace.candidates[0].kind == AiCandidateKind.element);
    assert(trace.candidates[0].elementKind == AiElementCandidateKind.vertex);
    assert(trace.candidates[0].screenPosition == [10.0f, 20.0f]);
    assert(trace.candidates[1].id == "element:face:8");
    assert(trace.candidates[1].elementKind == AiElementCandidateKind.face);
    assert(trace.defaultWinnerIndex == 0);
    assert(trace.defaultWinnerId == "element:vertex:3");
    assert(trace.appliedWinnerIndex == 0);
    assert(trace.appliedWinnerId == "element:vertex:3");
    assert(trace.advisor.keepDefault);

    auto j = parseJSON(latestHandleDebugTraceJson(true));
    auto e = j["elementTrace"];
    assert(e["candidateCount"].integer == 2);
    assert(e["candidateIds"].array[0].str == "element:vertex:3");
    assert(e["candidateIds"].array[1].str == "element:face:8");
    assert(e["candidates"].array[0]["elementKind"].str == "vertex");
    assert(e["candidates"].array[0]["isDefaultWinner"].type == JSONType.true_);
    assert(e["candidates"].array[1]["elementKind"].str == "face");
    assert(e["defaultWinner"]["id"].str == "element:vertex:3");
    assert(e["appliedWinner"]["id"].str == "element:vertex:3");
}
