// Pure tests for the AI handle debug trace serialization.

import std.json : JSONType, parseJSON;

import ai.debug_trace;
import ai.interaction;

void main() {}

unittest { // default-empty trace is deterministic and safe
    clearLatestHandleDebugTrace();

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
    assert(trace["defaultWinner"]["present"].type == JSONType.false_);
    assert(trace["defaultWinner"]["id"].str.length == 0);
    assert(trace["defaultWinner"]["index"].integer == -1);
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
    assert(trace["defaultWinner"]["present"].type == JSONType.true_);
    assert(trace["defaultWinner"]["id"].str == "handle:10");
    assert(trace["defaultWinner"]["index"].integer == 0);
}

unittest { // explicit advisor decisions serialize without affecting winners
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

    publishHandleDebugTrace([candidate], decision);

    auto j = parseJSON(latestHandleDebugTraceJson(true));
    assert(j["advisor"]["intent"].str == "keepDefault");
    assert(j["advisor"]["confidence"].floating == 0.25);
    assert(j["advisor"]["candidateIndex"].integer == 0);
    assert(j["advisor"]["candidateId"].str == "handle:42");
    assert(j["advisor"]["keepDefault"].type == JSONType.true_);
    assert(j["handleTrace"]["defaultWinner"]["id"].str == "handle:42");
}
