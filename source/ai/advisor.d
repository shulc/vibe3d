module ai.advisor;

enum AiIntent {
    keepDefault,
}

struct AiAdvisorDecision {
    AiIntent intent = AiIntent.keepDefault;
    float confidence = 0.0f;

    bool keepDefault() const {
        return intent == AiIntent.keepDefault;
    }
}

/// Phase-A shell only. Future advisors can rank existing editor candidates
/// behind this boundary; today it is deliberately behavior-neutral.
class AiAdvisor {
    AiAdvisorDecision advise() const {
        return AiAdvisorDecision(AiIntent.keepDefault, 0.0f);
    }
}

unittest {
    auto advisor = new AiAdvisor();
    auto d = advisor.advise();
    assert(d.keepDefault);
    assert(d.confidence == 0.0f);
}
