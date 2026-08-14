// Module unittests for `ai.advisor`, moved verbatim out of source/ai/advisor.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.advisor_test;

public import ai.interaction : AiAdvisorDecision, AiCandidate,
    AiCandidateKind, AiInteractionContext, AiInteractionPhase, AiIntent;
import ai.advisor;

unittest {
    auto advisor = new AiAdvisor();
    auto d = advisor.advise();
    assert(d.keepDefault);
    assert(d.confidence == 0.0f);
    assert(d.candidateIndex == -1);
}
