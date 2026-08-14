// Module unittests for `ai.exploration`, moved verbatim out of source/ai/exploration.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.exploration_test;

import std.conv   : to;
import std.format : format;
import ai.interaction_log : AiInteractionLogRecord;
import ai.interaction     : AiCandidate;
import ai.interaction : AiInteractionContext;
import ai.interaction_log : makeAiInteractionLogRecord, AiInteractionLogRecord;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind;
import ai.exploration;

unittest { // fromEnv with no env var ⇒ disabled
    import std.process : environment;
    // Make sure VIBE3D_AI_EXPLORE is absent for this test.
    // We can't unset it reliably in a cross-platform way, so just test the
    // direct constructor instead, which fromEnv delegates to.
    auto ctrl = new AiExplorationController(0.0f, 42u);
    assert(!ctrl.enabled());
}

unittest { // ε=0 ⇒ sampleOverrideIndex always -1
    auto ctrl = new AiExplorationController(0.0f, 42u);
    foreach (_; 0 .. 100)
        assert(ctrl.sampleOverrideIndex(5, 0) == -1);
}

unittest { // candidateCount < 2 ⇒ always -1 regardless of ε
    auto ctrl = new AiExplorationController(1.0f, 42u);
    assert(ctrl.sampleOverrideIndex(0, 0) == -1);
    assert(ctrl.sampleOverrideIndex(1, 0) == -1);
}

unittest { // ε=1 ⇒ always overrides; override never equals defaultIndex
    auto ctrl = new AiExplorationController(1.0f, 12345u);
    foreach (defaultIdx; 0 .. 4) {
        foreach (_; 0 .. 50) {
            int idx = ctrl.sampleOverrideIndex(5, defaultIdx);
            assert(idx >= 0 && idx < 5);
            assert(idx != defaultIdx);
        }
    }
}

unittest { // seeded determinism: same seed ⇒ same sequence
    auto a = new AiExplorationController(0.5f, 99u);
    auto b = new AiExplorationController(0.5f, 99u);
    foreach (_; 0 .. 30) {
        int ia = a.sampleOverrideIndex(3, 0);
        int ib = b.sampleOverrideIndex(3, 0);
        assert(ia == ib);
    }
}

unittest { // buildCandidateKey is order-independent
    import ai.interaction : AiCandidate, AiCandidateKind;
    AiCandidate c1, c2, c3;
    c1.id = "handle:20"; c1.kind = AiCandidateKind.handle;
    c2.id = "handle:0";  c2.kind = AiCandidateKind.handle;
    c3.id = "handle:10"; c3.kind = AiCandidateKind.handle;
    string k1 = buildCandidateKey([c1, c2, c3]);
    string k2 = buildCandidateKey([c3, c1, c2]);
    assert(k1 == k2);
    assert(k1 == "handle:0|handle:10|handle:20");
}

unittest { // parseHandlePart
    assert(parseHandlePart("handle:0")  ==  0);
    assert(parseHandlePart("handle:12") == 12);
    assert(parseHandlePart("element:5") == -1);
    assert(parseHandlePart("handle:x")  == -1);
}
