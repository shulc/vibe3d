// Module unittests for `ai.interaction_log`, moved verbatim out of source/ai/interaction_log.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.interaction_log_test;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.math : isFinite;
import ai.debug_trace : aiElementCandidateKindFromId, aiElementCandidateKindId,
    aiIntentFromId, aiIntentId;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiElementCandidateKind, AiInteractionContext, AiInteractionPhase, AiIntent;
import ai.interaction_log;

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
