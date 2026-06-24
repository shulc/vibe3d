module ai.advisor;

public import ai.interaction : AiAdvisorDecision, AiCandidate,
    AiCandidateKind, AiInteractionContext, AiInteractionPhase, AiIntent;

/// Schema-only advisor shell. Future advisors can rank existing editor
/// candidates behind this boundary; today it is deliberately behavior-neutral.
class AiAdvisor {
    AiAdvisorDecision advise(const ref AiInteractionContext context,
                             const(AiCandidate)[] candidates) const {
        return AiAdvisorDecision();
    }

    AiAdvisorDecision advise() const {
        auto context = AiInteractionContext();
        return advise(context, null);
    }
}

unittest {
    auto advisor = new AiAdvisor();
    auto d = advisor.advise();
    assert(d.keepDefault);
    assert(d.confidence == 0.0f);
    assert(d.candidateIndex == -1);
}
