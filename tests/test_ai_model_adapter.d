// Pure tests for the AI runtime model adapter seam.

import ai.interaction : AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase, AiIntent;
import ai.model_adapter : AiModelAdapter, AiModelAdapterConfig,
    AiModelAvailability, AiModelBackend, AiModelBackendPrediction,
    AiModelFallbackMode, AiModelStatus;

void main() {}

private AiCandidate candidate(string id,
                              AiIntent intent,
                              float screenDist,
                              float priority,
                              bool isDefaultWinner = false) {
    AiCandidate c;
    c.id = id;
    c.kind = AiCandidateKind.handle;
    c.intent = intent;
    c.screenDist = screenDist;
    c.priorityFromCurrentRules = priority;
    c.isDefaultWinner = isDefaultWinner;
    return c;
}

private AiCandidate[] strongCandidates() {
    return [
        candidate("handle:x", AiIntent.dragAxisX, 48.0f, 5.0f, true),
        candidate("handle:y", AiIntent.dragAxisY, 8.0f, 1.0f),
    ];
}

private AiInteractionContext context() {
    AiInteractionContext c;
    c.phase = AiInteractionPhase.mouseDown;
    c.defaultIntent = AiIntent.dragAxisX;
    c.mouseX = 320;
    c.mouseY = 240;
    c.activeToolId = "xfrm.transform";
    c.editModeId = "vertices";
    return c;
}

private AiModelAdapterConfig config(AiModelStatus status,
                                    AiModelFallbackMode fallback =
                                        AiModelFallbackMode.deterministicAdvisor) {
    AiModelAdapterConfig c;
    c.availability = AiModelAvailability(status);
    c.fallbackMode = fallback;
    return c;
}

private class MockBackend : AiModelBackend {
    AiModelAvailability availability_;
    AiModelBackendPrediction prediction_;
    int calls;

    this(AiModelAvailability availability,
         AiModelBackendPrediction prediction) {
        availability_ = availability;
        prediction_ = prediction;
    }

    override AiModelAvailability availability() const {
        return availability_;
    }

    override AiModelBackendPrediction predict(
        const ref AiInteractionContext context,
        const(AiCandidate)[] candidates) const {
        ++(cast(MockBackend)this).calls;
        return prediction_;
    }
}

private AiModelBackendPrediction prediction(int index,
                                            string id,
                                            float confidence) {
    AiModelBackendPrediction p;
    p.candidateIndex = index;
    p.candidateId = id;
    p.confidence = confidence;
    return p;
}

unittest { // disabled/unavailable/no-backend all use deterministic fallback
    auto candidates = strongCandidates();
    auto c = context();

    auto disabled = new AiModelAdapter(config(AiModelStatus.disabled));
    auto d0 = disabled.decide(c, candidates);
    assert(d0.intent == AiIntent.dragAxisY);
    assert(d0.candidateIndex == 1);
    assert(d0.candidateId == "handle:y");

    auto unavailableBackend = new MockBackend(
        AiModelAvailability(AiModelStatus.unavailable, "missing model"),
        prediction(0, "handle:x", 0.99f));
    auto unavailable = new AiModelAdapter(
        config(AiModelStatus.ready), unavailableBackend);
    auto d1 = unavailable.decide(c, candidates);
    assert(unavailableBackend.calls == 0);
    assert(d1.intent == d0.intent);
    assert(d1.candidateIndex == d0.candidateIndex);
    assert(d1.candidateId == d0.candidateId);

    auto noBackend = new AiModelAdapter(config(AiModelStatus.ready));
    auto d2 = noBackend.decide(c, candidates);
    assert(noBackend.availability.status == AiModelStatus.unavailable);
    assert(d2.intent == d0.intent);
    assert(d2.candidateIndex == d0.candidateIndex);
    assert(d2.candidateId == d0.candidateId);
}

unittest { // safe-default fallback is available for conservative call sites
    auto adapter = new AiModelAdapter(
        config(AiModelStatus.unavailable, AiModelFallbackMode.keepDefault));
    auto c = context();
    auto candidates = strongCandidates();

    auto decision = adapter.decide(c, candidates);
    assert(decision.keepDefault);
    assert(decision.confidence == 0.0f);
    assert(decision.candidateIndex == -1);
    assert(decision.candidateId.length == 0);
}

unittest { // ready mock backend can produce an accepted advisory decision
    auto backend = new MockBackend(
        AiModelAvailability(AiModelStatus.ready),
        prediction(1, "handle:y", 0.92f));
    auto adapter = new AiModelAdapter(config(AiModelStatus.ready), backend);
    auto c = context();
    auto candidates = strongCandidates();

    auto decision = adapter.decide(c, candidates);
    assert(backend.calls == 1);
    assert(!decision.keepDefault);
    assert(decision.intent == AiIntent.dragAxisY);
    assert(decision.confidence == 0.92f);
    assert(decision.candidateIndex == 1);
    assert(decision.candidateId == "handle:y");
}

unittest { // invalid backend index is rejected before it can become a decision
    auto backend = new MockBackend(
        AiModelAvailability(AiModelStatus.ready),
        prediction(7, "handle:y", 0.99f));
    auto adapter = new AiModelAdapter(
        config(AiModelStatus.ready, AiModelFallbackMode.keepDefault),
        backend);
    auto c = context();
    auto candidates = strongCandidates();

    auto decision = adapter.decide(c, candidates);
    assert(backend.calls == 1);
    assert(decision.keepDefault);
}

unittest { // backend candidate id must match the chosen candidate index
    auto backend = new MockBackend(
        AiModelAvailability(AiModelStatus.ready),
        prediction(1, "handle:x", 0.99f));
    auto adapter = new AiModelAdapter(
        config(AiModelStatus.ready, AiModelFallbackMode.keepDefault),
        backend);
    auto c = context();
    auto candidates = strongCandidates();

    auto decision = adapter.decide(c, candidates);
    assert(backend.calls == 1);
    assert(decision.keepDefault);
}

unittest { // low-confidence backend output is rejected conservatively
    auto backend = new MockBackend(
        AiModelAvailability(AiModelStatus.ready),
        prediction(1, "handle:y", 0.50f));
    auto adapter = new AiModelAdapter(
        config(AiModelStatus.ready, AiModelFallbackMode.keepDefault),
        backend);
    auto c = context();
    auto candidates = strongCandidates();

    auto decision = adapter.decide(c, candidates);
    assert(backend.calls == 1);
    assert(decision.keepDefault);
}

unittest { // non-finite and above-one confidence are rejected
    auto c = context();
    auto candidates = strongCandidates();

    auto nanBackend = new MockBackend(
        AiModelAvailability(AiModelStatus.ready),
        prediction(1, "handle:y", float.nan));
    auto nanAdapter = new AiModelAdapter(
        config(AiModelStatus.ready, AiModelFallbackMode.keepDefault),
        nanBackend);
    assert(nanAdapter.decide(c, candidates).keepDefault);
    assert(nanBackend.calls == 1);

    auto highBackend = new MockBackend(
        AiModelAvailability(AiModelStatus.ready),
        prediction(1, "handle:y", 1.25f));
    auto highAdapter = new AiModelAdapter(
        config(AiModelStatus.ready, AiModelFallbackMode.keepDefault),
        highBackend);
    assert(highAdapter.decide(c, candidates).keepDefault);
    assert(highBackend.calls == 1);
}

unittest { // backend cannot select default or keepDefault candidates
    auto c = context();

    auto defaultBackend = new MockBackend(
        AiModelAvailability(AiModelStatus.ready),
        prediction(0, "handle:x", 0.99f));
    auto defaultAdapter = new AiModelAdapter(
        config(AiModelStatus.ready, AiModelFallbackMode.keepDefault),
        defaultBackend);
    assert(defaultAdapter.decide(c, strongCandidates()).keepDefault);
    assert(defaultBackend.calls == 1);

    auto candidates = strongCandidates();
    candidates ~= candidate("context:noop", AiIntent.keepDefault,
                            1.0f, 0.0f);
    auto keepDefaultBackend = new MockBackend(
        AiModelAvailability(AiModelStatus.ready),
        prediction(2, "context:noop", 0.99f));
    auto keepDefaultAdapter = new AiModelAdapter(
        config(AiModelStatus.ready, AiModelFallbackMode.keepDefault),
        keepDefaultBackend);
    assert(keepDefaultAdapter.decide(c, candidates).keepDefault);
    assert(keepDefaultBackend.calls == 1);
}

unittest { // exposed deterministic fallback is repeatable
    auto adapter = new AiModelAdapter(config(AiModelStatus.disabled));
    auto c = context();
    auto candidates = strongCandidates();

    auto first = adapter.decide(c, candidates);
    auto second = adapter.decide(c, candidates);
    assert(first.intent == second.intent);
    assert(first.confidence == second.confidence);
    assert(first.candidateIndex == second.candidateIndex);
    assert(first.candidateId == second.candidateId);
}
