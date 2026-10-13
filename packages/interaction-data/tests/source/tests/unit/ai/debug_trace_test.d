// Module unittests for `ai.debug_trace`, moved verbatim out of source/ai/debug_trace.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.debug_trace_test;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiElementCandidateKind,
    AiIntent;
import ai.debug_trace;

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
