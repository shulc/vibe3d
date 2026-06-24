module ai.model_adapter;

import std.math : isFinite;

import ai.advisor : AiAdvisor;
import ai.interaction : AiAdvisorDecision, AiCandidate,
    AiInteractionContext, AiIntent;

enum float aiModelAdapterMinConfidence = 0.75f;

enum AiModelStatus {
    disabled,
    unavailable,
    ready,
}

enum AiModelFallbackMode {
    keepDefault,
    deterministicAdvisor,
}

struct AiModelAvailability {
    AiModelStatus status = AiModelStatus.disabled;
    string reason = "";

    bool ready() const {
        return status == AiModelStatus.ready;
    }
}

struct AiModelBackendPrediction {
    int candidateIndex = -1;
    string candidateId = "";
    float confidence = 0.0f;

    bool present() const {
        return candidateIndex >= 0 || candidateId.length != 0;
    }
}

interface AiModelBackend {
    AiModelAvailability availability() const;

    AiModelBackendPrediction predict(
        const ref AiInteractionContext context,
        const(AiCandidate)[] candidates) const;
}

struct AiModelAdapterConfig {
    AiModelAvailability availability =
        AiModelAvailability(AiModelStatus.disabled);
    AiModelFallbackMode fallbackMode =
        AiModelFallbackMode.deterministicAdvisor;
    float minConfidence = aiModelAdapterMinConfidence;
}

class AiModelAdapter {
private:
    AiModelAdapterConfig config_;
    AiModelBackend backend_;

public:
    this(AiModelAdapterConfig config = AiModelAdapterConfig(),
         AiModelBackend backend = null) {
        config_ = config;
        backend_ = backend;
    }

    AiModelAdapterConfig config() const {
        return config_;
    }

    void setConfig(AiModelAdapterConfig config) {
        config_ = config;
    }

    void setBackend(AiModelBackend backend) {
        backend_ = backend;
    }

    AiModelAvailability availability() const {
        if (config_.availability.status != AiModelStatus.ready)
            return config_.availability;

        if (backend_ is null)
            return AiModelAvailability(
                AiModelStatus.unavailable,
                "no model backend");

        auto backendAvailability = backend_.availability();
        if (!backendAvailability.ready)
            return backendAvailability;
        return config_.availability;
    }

    AiAdvisorDecision decide(const ref AiInteractionContext context,
                             const(AiCandidate)[] candidates) const {
        if (!availability.ready)
            return fallbackDecision(context, candidates);

        AiModelBackendPrediction prediction;
        try {
            prediction = backend_.predict(context, candidates);
        } catch (Exception) {
            return fallbackDecision(context, candidates);
        }

        auto decision = decisionFromPrediction(candidates, prediction);
        return decision.keepDefault ? AiAdvisorDecision() : decision;
    }

private:
    AiAdvisorDecision fallbackDecision(
        const ref AiInteractionContext context,
        const(AiCandidate)[] candidates) const {
        final switch (config_.fallbackMode) {
            case AiModelFallbackMode.keepDefault:
                return AiAdvisorDecision();
            case AiModelFallbackMode.deterministicAdvisor:
                auto advisor = new AiAdvisor(true);
                return advisor.advise(context, candidates);
        }
    }

    AiAdvisorDecision decisionFromPrediction(
        const(AiCandidate)[] candidates,
        const ref AiModelBackendPrediction prediction) const {
        if (!prediction.present)
            return AiAdvisorDecision();
        if (!prediction.confidence.isFinite ||
            prediction.confidence < config_.minConfidence ||
            prediction.confidence > 1.0f)
            return AiAdvisorDecision();
        if (prediction.candidateIndex < 0)
            return AiAdvisorDecision();

        auto index = cast(size_t)prediction.candidateIndex;
        if (index >= candidates.length)
            return AiAdvisorDecision();
        if (prediction.candidateId.length == 0 ||
            prediction.candidateId != candidates[index].id)
            return AiAdvisorDecision();
        if (candidates[index].intent == AiIntent.keepDefault)
            return AiAdvisorDecision();

        immutable defaultIndex = defaultCandidateIndex(candidates);
        if (defaultIndex >= 0 && prediction.candidateIndex == defaultIndex)
            return AiAdvisorDecision();

        AiAdvisorDecision decision;
        decision.intent = candidates[index].intent;
        decision.confidence = prediction.confidence;
        decision.candidateIndex = prediction.candidateIndex;
        decision.candidateId = candidates[index].id;
        return decision;
    }
}

private int defaultCandidateIndex(const(AiCandidate)[] candidates) {
    foreach (i, ref candidate; candidates) {
        if (candidate.isDefaultWinner)
            return cast(int)i;
    }
    return -1;
}

unittest {
    auto adapter = new AiModelAdapter();
    assert(adapter.availability.status == AiModelStatus.disabled);

    auto context = AiInteractionContext();
    auto decision = adapter.decide(context, null);
    assert(decision.keepDefault);
}
