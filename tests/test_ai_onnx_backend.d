// Focused tests for the ONNX-backed AiModelBackend (ai.onnx_backend).
//
// Source-backed test: importing `ai.*` makes run_test.d compile it against the
// project + harvested `dub describe` flags, which include the d-onnxruntime
// import path and the libonnxrt/libonnxruntime link tail. The ready-path test
// loads a tiny committed linear ranker.onnx (single MatMul, 2256-wide) embedded
// via `-J=tests` and written to a temp file (onnx_create takes a path).
import std.file : write, remove, tempDir;
import std.path : buildPath;

import ai.interaction : AiCandidate, AiCandidateKind,
    AiInteractionContext, AiIntent;
import ai.model_adapter : AiModelAdapter, AiModelAdapterConfig,
    AiModelAvailability, AiModelFallbackMode, AiModelStatus;
import ai.onnx_backend : OnnxModelBackend;
import onnxrt.backend : backendAvailable;

void main() {}

private AiCandidate handle(string id, AiIntent intent, float screenDist,
                           float priority, bool isDefault = false) {
    AiCandidate c;
    c.id = id;
    c.kind = AiCandidateKind.handle;
    c.intent = intent;
    c.screenDist = screenDist;
    c.priorityFromCurrentRules = priority;
    c.isDefaultWinner = isDefault;
    return c;
}

private AiCandidate[] handleCandidates() {
    return [
        handle("handle:x", AiIntent.dragAxisX, 48.0f, 5.0f, true),
        handle("handle:y", AiIntent.dragAxisY, 8.0f, 1.0f),
    ];
}

private string writeFixtureModel() {
    immutable bytes = import("fixtures/ai_ranker.onnx");
    auto path = buildPath(tempDir(), "vibe3d_test_ai_ranker.onnx");
    write(path, bytes);
    return path;
}

private void removeQuiet(string path) nothrow {
    try { remove(path); } catch (Exception) {}
}

// Unavailable: a bad model path never throws — backend reports unavailable and
// predict() returns not-present, so the adapter falls back deterministically.
unittest {
    auto backend = new OnnxModelBackend("/no/such/ranker.onnx");
    assert(backend.availability.status == AiModelStatus.unavailable);

    AiInteractionContext context;
    assert(!backend.predict(context, handleCandidates()).present);
}

// Ready path: load the real linear model and rank candidates.
unittest {
    if (!backendAvailable)
        return;  // dependency-free stub/mock build: ready path needs real ORT

    auto path = writeFixtureModel();
    scope(exit) removeQuiet(path);

    auto backend = new OnnxModelBackend(path);
    assert(backend.availability.status == AiModelStatus.ready);

    AiInteractionContext context;
    auto candidates = handleCandidates();

    auto prediction = backend.predict(context, candidates);
    assert(prediction.present);
    assert(prediction.candidateIndex >= 0
        && prediction.candidateIndex < cast(int) candidates.length);
    // id must match the chosen index (the adapter re-checks this).
    assert(prediction.candidateId == candidates[prediction.candidateIndex].id);
    assert(prediction.confidence > 0.0f && prediction.confidence <= 1.0f);

    // Empty candidate set → not present.
    assert(!backend.predict(context, []).present);

    // Through the adapter seam: with a ready config the ONNX decision is used,
    // or conservatively rejected to keepDefault — both are valid, never a crash.
    auto config = AiModelAdapterConfig(
        AiModelAvailability(AiModelStatus.ready),
        AiModelFallbackMode.keepDefault);
    auto adapter = new AiModelAdapter(config, backend);
    auto decision = adapter.decide(context, candidates);
    if (!decision.keepDefault) {
        assert(decision.candidateIndex >= 0);
        assert(decision.confidence >= config.minConfidence);
        assert(decision.candidateId == candidates[decision.candidateIndex].id);
    }
}
