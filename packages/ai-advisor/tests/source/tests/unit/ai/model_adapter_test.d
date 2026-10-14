// Module unittests for `ai.model_adapter`, moved verbatim out of source/ai/model_adapter.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.model_adapter_test;

import std.math : isFinite;
import ai.advisor : AiAdvisor;
import ai.interaction : AiAdvisorDecision, AiCandidate,
    AiInteractionContext, AiIntent;
import ai.model_adapter;

unittest {
    auto adapter = new AiModelAdapter();
    assert(adapter.availability.status == AiModelStatus.disabled);

    auto context = AiInteractionContext();
    auto decision = adapter.decide(context, null);
    assert(decision.keepDefault);
}
