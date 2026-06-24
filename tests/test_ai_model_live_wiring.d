// Seam-composition coverage for the model-backed handle decision provider
// (task 0028). Drives a REAL `ToolHandles` (modeled on
// `test_ai_handle_candidates.d`) with the decision injected through
// `setHandleDecisionProvider`, so the assertions run through the production
// `publishHandleTrace` + `canApplyAdvisorDecision` gate — NOT a hand-copied
// predicate. The pure-adapter cases (unavailable / invalid-index / id-mismatch /
// low-conf / nan / default-reject) are already covered by
// `tests/test_ai_model_adapter.d` and are not re-derived here; the unique value
// is the composition of `AiModelAdapter.decide` + the today's-advisor fallthrough
// through the real handle gate.

import ai.advisor : AiAdvisor;
import ai.debug_trace : clearLatestHandleDebugTrace, latestHandleDebugTrace;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiInteractionPhase, AiIntent;
import ai.model_adapter : AiModelAdapter, AiModelAdapterConfig,
    AiModelAvailability, AiModelBackend, AiModelBackendPrediction,
    AiModelFallbackMode, AiModelStatus, aiModelAdapterMinConfidence;
import ai.onnx_backend : OnnxModelBackend;
import handler : Handler, HandleState, ToolHandles,
    setHandleAiAdvisor, setHandleDecisionProvider;
import math : Viewport;

void main() {}

private class TestHandle : Handler {
    bool shouldHit;
    float screenDistance;

    this(bool shouldHit, float screenDistance = 0.0f) {
        this.shouldHit = shouldHit;
        this.screenDistance = screenDistance;
    }

    override protected bool hitTest(int mx, int my, const ref Viewport vp) {
        return shouldHit;
    }

    override protected float aiScreenDistance(int mx, int my,
                                              const ref Viewport vp) {
        return shouldHit ? screenDistance : float.infinity;
    }
}

// Deterministic, controllable backend. `availability` + `prediction` are set by
// each test; `calls` counts inference invocations so we can prove the model was
// (or was not) consulted on a given phase.
private class MockBackend : AiModelBackend {
    AiModelAvailability avail = AiModelAvailability(AiModelStatus.ready);
    AiModelBackendPrediction prediction;
    int calls;

    AiModelAvailability availability() const {
        return avail;
    }

    AiModelBackendPrediction predict(const ref AiInteractionContext context,
                                     const(AiCandidate)[] candidates) const {
        // `predict` is `const`; the call-count is bookkeeping, so cast it away.
        (cast(MockBackend) this).calls++;
        return prediction;
    }
}

// Build the composing closure exactly as app.d injects it: model first, fall
// through to the supplied advisor on keepDefault. Returns the adapter so the
// caller can keep it (and its backend) alive and inspect `backend.calls`.
private AiModelAdapter installComposingProvider(AiModelBackend backend,
                                                AiAdvisor fallthroughAdvisor) {
    AiModelAdapterConfig cfg;
    cfg.availability = AiModelAvailability(AiModelStatus.ready);
    cfg.fallbackMode = AiModelFallbackMode.keepDefault;
    cfg.minConfidence = aiModelAdapterMinConfidence;
    auto adapter = new AiModelAdapter(cfg, backend);
    setHandleDecisionProvider(
        (const ref AiInteractionContext ctx, const(AiCandidate)[] cands) {
            auto d = adapter.decide(ctx, cands);
            return d.keepDefault ? fallthroughAdvisor.advise(ctx, cands) : d;
        });
    return adapter;
}

// Two registered handles: part 10 (default winner) and part 30 (later). The
// later one is index 1 in the candidate list, id "handle:30" — the prediction
// target the gate can switch to.
private ToolHandles twoHandles(TestHandle first, TestHandle later) {
    auto handles = new ToolHandles();
    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);
    return handles;
}

private MockBackend confidentPickOfLater() {
    auto backend = new MockBackend();
    AiModelBackendPrediction p;
    p.candidateIndex = 1;       // the later, non-default candidate
    p.candidateId = "handle:30";
    p.confidence = 0.9f;        // >= 0.75
    backend.prediction = p;
    return backend;
}

unittest { // applied: high-confidence valid model prediction on mouseDown
    clearLatestHandleDebugTrace();
    auto backend = confidentPickOfLater();
    auto adapter = installComposingProvider(backend, new AiAdvisor(false));
    scope (exit) setHandleDecisionProvider(null);

    auto handles = twoHandles(new TestHandle(true), new TestHandle(true));
    auto vp = Viewport();

    int winner = handles.test(123, 456, vp, AiInteractionPhase.mouseDown);
    assert(winner == 30);                  // model's pick applied by the gate
    assert(backend.calls == 1);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:30");
    assert(!trace.advisor.keepDefault);
    assert(trace.advisor.candidateIndex == 1);
    assert(trace.advisor.candidateId == "handle:30");
}

unittest { // applied: same prediction on the per-frame hover-preview path
    clearLatestHandleDebugTrace();
    auto backend = confidentPickOfLater();
    auto adapter = installComposingProvider(backend, new AiAdvisor(false));
    scope (exit) setHandleDecisionProvider(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.setAiHoverPreviewEnabled(true);
    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);

    handles.update(123, 456, vp);          // drives test(..., hover)
    assert(handles.hot == 30);             // hover gate applied the model pick
    assert(handles.secondaryDefault == 10);
    assert(first.getState() == HandleState.SecondaryDefault);
    assert(later.getState() == HandleState.Rollover);
    assert(backend.calls == 1);

    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:30");
}

unittest { // NOT applied — mid-drag (captured >= 0): gate rejects, model can't force
    clearLatestHandleDebugTrace();
    auto backend = confidentPickOfLater();
    auto adapter = installComposingProvider(backend, new AiAdvisor(false));
    scope (exit) setHandleDecisionProvider(null);

    auto first = new TestHandle(true);
    auto later = new TestHandle(true);
    auto handles = new ToolHandles();
    auto vp = Viewport();

    handles.setAiHoverPreviewEnabled(true);
    handles.begin();
    handles.add(first, 10);
    handles.add(later, 30);
    handles.captured = 30;                 // dragging: hot sticks, no retest

    handles.update(123, 456, vp);
    // The captured (dragging) path sticks to the latched part and short-circuits
    // before any decision source — the model cannot force a switch mid-drag.
    assert(handles.hot == 30);             // the captured part, not a model apply
    assert(handles.captured == 30);
    assert(backend.calls == 0);            // captured path never consults a source
}

unittest { // NOT applied — wrong phase (dragUpdate): falls to default
    clearLatestHandleDebugTrace();
    auto backend = confidentPickOfLater();
    auto adapter = installComposingProvider(backend, new AiAdvisor(false));
    scope (exit) setHandleDecisionProvider(null);

    auto handles = twoHandles(new TestHandle(true), new TestHandle(true));
    auto vp = Viewport();

    assert(handles.test(123, 456, vp, AiInteractionPhase.dragUpdate) == 10);
    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:10");
}

unittest { // NOT applied — confidence < 0.75: decide keepDefault -> fallthrough
    clearLatestHandleDebugTrace();
    auto backend = new MockBackend();
    AiModelBackendPrediction p;
    p.candidateIndex = 1;
    p.candidateId = "handle:30";
    p.confidence = 0.5f;                    // below threshold
    backend.prediction = p;
    auto adapter = installComposingProvider(backend, new AiAdvisor(false));
    scope (exit) setHandleDecisionProvider(null);

    auto handles = twoHandles(new TestHandle(true), new TestHandle(true));
    auto vp = Viewport();

    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 10);
    auto trace = latestHandleDebugTrace();
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.keepDefault);
}

unittest { // NOT applied — candidateId mismatch: decide keepDefault -> fallthrough
    clearLatestHandleDebugTrace();
    auto backend = new MockBackend();
    AiModelBackendPrediction p;
    p.candidateIndex = 1;
    p.candidateId = "handle:999";          // does not match candidates[1].id
    p.confidence = 0.9f;
    backend.prediction = p;
    auto adapter = installComposingProvider(backend, new AiAdvisor(false));
    scope (exit) setHandleDecisionProvider(null);

    auto handles = twoHandles(new TestHandle(true), new TestHandle(true));
    auto vp = Viewport();

    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 10);
    auto trace = latestHandleDebugTrace();
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.keepDefault);
}

unittest { // NOT applied — prediction == default index: decide keepDefault -> fallthrough
    clearLatestHandleDebugTrace();
    auto backend = new MockBackend();
    AiModelBackendPrediction p;
    p.candidateIndex = 0;                   // the default winner itself
    p.candidateId = "handle:10";
    p.confidence = 0.9f;
    backend.prediction = p;
    auto adapter = installComposingProvider(backend, new AiAdvisor(false));
    scope (exit) setHandleDecisionProvider(null);

    auto handles = twoHandles(new TestHandle(true), new TestHandle(true));
    auto vp = Viewport();

    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 10);
    auto trace = latestHandleDebugTrace();
    assert(trace.appliedWinnerId == "handle:10");
    assert(trace.advisor.keepDefault);
}

unittest { // provider unset = today's advisor path (byte-identical default)
    clearLatestHandleDebugTrace();
    setHandleAiAdvisor(new AiAdvisor(true));
    scope (exit) setHandleAiAdvisor(null);
    // No setHandleDecisionProvider — the seam default is the advisor call.

    auto handles = twoHandles(new TestHandle(true, 42.0f),
                              new TestHandle(true, 6.0f));
    auto vp = Viewport();

    // The deterministic advisor switches to the closer later candidate (mirrors
    // test_ai_handle_candidates.d:142-177).
    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 30);
    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:30");
}

unittest { // keepDefault from a not-ready adapter falls through to today's advisor
    clearLatestHandleDebugTrace();
    setHandleAiAdvisor(null);
    // Composing closure with a NOT-ready backend -> decide() returns keepDefault
    // -> delegates to the supplied advisor, which is the enabled deterministic
    // advisor. Result must equal the provider-unset advisor case above.
    auto backend = new MockBackend();
    backend.avail =
        AiModelAvailability(AiModelStatus.unavailable, "not loaded");
    auto fallthrough = new AiAdvisor(true);
    auto adapter = installComposingProvider(backend, fallthrough);
    scope (exit) setHandleDecisionProvider(null);

    auto handles = twoHandles(new TestHandle(true, 42.0f),
                              new TestHandle(true, 6.0f));
    auto vp = Viewport();

    assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 30);
    assert(backend.calls == 0);            // not-ready -> backend never queried
    auto trace = latestHandleDebugTrace();
    assert(trace.defaultWinnerId == "handle:10");
    assert(trace.appliedWinnerId == "handle:30");
}

unittest { // ready-backend smoke: loading the fixture never throws, and a
           // not-ready load still yields the advisor fallthrough through the
           // composing closure. Guarded so a missing onnx runtime cannot fail.
    auto backend = new OnnxModelBackend("tests/fixtures/ai_ranker.onnx");
    auto avail = backend.availability();
    // Either the runtime is present (ready) or absent (unavailable) — never a
    // throw, and never any other status.
    assert(avail.status == AiModelStatus.ready ||
           avail.status == AiModelStatus.unavailable);

    if (avail.status == AiModelStatus.unavailable) {
        // Not ready -> the composing closure must fall through to the advisor,
        // identical to the not-ready MockBackend case.
        clearLatestHandleDebugTrace();
        setHandleAiAdvisor(null);
        auto adapter = installComposingProvider(
            new SmokeAdapterBackend(backend), new AiAdvisor(true));
        scope (exit) setHandleDecisionProvider(null);

        auto handles = twoHandles(new TestHandle(true, 42.0f),
                                  new TestHandle(true, 6.0f));
        auto vp = Viewport();
        assert(handles.test(123, 456, vp, AiInteractionPhase.mouseDown) == 30);
    }
}

// Thin AiModelBackend wrapper so the smoke test can route a real
// OnnxModelBackend (a final class) through `installComposingProvider`, which
// expects the controllable MockBackend type only for `calls`. We do not touch
// `calls` here.
private class SmokeAdapterBackend : AiModelBackend {
    private OnnxModelBackend inner_;
    this(OnnxModelBackend inner) { inner_ = inner; }
    AiModelAvailability availability() const { return inner_.availability(); }
    AiModelBackendPrediction predict(const ref AiInteractionContext context,
                                     const(AiCandidate)[] candidates) const {
        return inner_.predict(context, candidates);
    }
}
