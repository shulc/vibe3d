module ai.advisor;

public import ai.interaction : AiAdvisorDecision, AiCandidate,
    AiCandidateKind, AiInteractionContext, AiInteractionPhase, AiIntent;

private bool finite(float value) {
    return value == value &&
        value != float.infinity &&
        value != -float.infinity;
}

private float clamp01(float value) {
    if (value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

/// Deterministic advisory scorer for existing editor candidates. The decision
/// is intentionally conservative and remains advisory-only at the call site.
class AiAdvisor {
    private bool enabled_;
    private bool delegate() enabledFn_;

    this() {
    }

    this(bool enabled) {
        enabled_ = enabled;
    }

    this(bool delegate() enabledFn) {
        enabledFn_ = enabledFn;
    }

    bool enabled() const {
        return enabledFn_ !is null ? enabledFn_() : enabled_;
    }

    void setEnabled(bool enabled) {
        enabled_ = enabled;
    }

    AiAdvisorDecision advise(const ref AiInteractionContext context,
                             const(AiCandidate)[] candidates) const {
        if (!enabled || candidates.length < 2)
            return AiAdvisorDecision();

        ptrdiff_t defaultIndex = -1;
        foreach (i, ref c; candidates) {
            if (c.isDefaultWinner) {
                defaultIndex = cast(ptrdiff_t)i;
                break;
            }
        }
        if (defaultIndex < 0)
            return AiAdvisorDecision();

        const defaultCandidate = candidates[cast(size_t)defaultIndex];
        if (defaultCandidate.isExplicitModifierChoice)
            return AiAdvisorDecision();

        ptrdiff_t bestIndex = -1;
        float bestConfidence = 0.0f;
        float bestMargin = 0.0f;

        foreach (i, ref c; candidates) {
            if (cast(ptrdiff_t)i == defaultIndex)
                continue;
            if (c.intent == AiIntent.keepDefault)
                continue;

            immutable priorityAdvantage =
                defaultCandidate.priorityFromCurrentRules -
                c.priorityFromCurrentRules;

            float screenAdvantage = 0.0f;
            if (finite(defaultCandidate.screenDist) && finite(c.screenDist))
                screenAdvantage = defaultCandidate.screenDist - c.screenDist;

            float worldAdvantage = 0.0f;
            if (finite(defaultCandidate.worldDist) && finite(c.worldDist))
                worldAdvantage = defaultCandidate.worldDist - c.worldDist;

            immutable priorityConfidence = priorityAdvantage / 4.0f;
            immutable screenConfidence = screenAdvantage / 24.0f;
            immutable worldConfidence = worldAdvantage / 0.5f;
            immutable confidence = clamp01(
                priorityConfidence > screenConfidence
                    ? (priorityConfidence > worldConfidence
                        ? priorityConfidence : worldConfidence)
                    : (screenConfidence > worldConfidence
                        ? screenConfidence : worldConfidence));

            immutable clearMargin =
                priorityAdvantage >= 2.0f ||
                screenAdvantage >= 18.0f ||
                worldAdvantage >= 0.375f;
            if (!clearMargin || confidence < 0.75f)
                continue;

            immutable margin = priorityAdvantage +
                screenAdvantage / 24.0f +
                worldAdvantage / 0.5f;
            if (confidence > bestConfidence ||
                (confidence == bestConfidence && margin > bestMargin)) {
                bestIndex = cast(ptrdiff_t)i;
                bestConfidence = confidence;
                bestMargin = margin;
            }
        }

        if (bestIndex < 0)
            return AiAdvisorDecision();

        const best = candidates[cast(size_t)bestIndex];
        AiAdvisorDecision decision;
        decision.intent = best.intent;
        decision.confidence = bestConfidence;
        decision.candidateIndex = cast(int)bestIndex;
        decision.candidateId = best.id;
        return decision;
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
