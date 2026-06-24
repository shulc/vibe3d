/// `AiModelBackend` backed by the ONNX candidate ranker (d-onnxruntime shim).
///
/// Loads `ranker.onnx` (the linear model produced by
/// `tools/ai/weights_to_onnx.py` from the trainer weights, task 0024/0026),
/// encodes the interaction context + candidates via `ai.ranker_schema` v1,
/// expands each candidate to the model's input width (candidate features ++
/// context×candidate cross terms), scores the batch through the shim and
/// returns a masked-argmax `AiModelBackendPrediction`.
///
/// The seam (`AiModelAdapter`) re-validates the prediction conservatively
/// (id↔index match, confidence threshold, keepDefault/default-winner reject),
/// so a low-confidence or malformed result degrades to the deterministic
/// fallback exactly like the runtime advisor path.
module ai.onnx_backend;

import ai.interaction : AiCandidate, AiCandidateKind, AiInteractionContext;
import ai.model_adapter : AiModelAvailability, AiModelBackend,
    AiModelBackendPrediction, AiModelStatus;
import ai.ranker_schema : aiRankerDefaultMaxCandidates,
    encodeAiRankerExpandedBatch, encodeAiRankerInput;

import onnxrt.backend : OnnxException, OnnxSession, backendAvailable, rank;

final class OnnxModelBackend : AiModelBackend {
    private OnnxSession session_;
    private bool ready_;
    private string reason_ = "onnx ranker not loaded";
    private size_t maxCandidates_;

    /// Load the ONNX ranker. Never throws: if the runtime backend is absent or
    /// the model fails to load, the backend reports `unavailable` and the
    /// adapter falls back deterministically.
    this(string modelPath, size_t maxCandidates = aiRankerDefaultMaxCandidates) {
        maxCandidates_ = maxCandidates;
        if (!backendAvailable()) {
            reason_ = "onnx runtime backend not linked";
            return;
        }
        try {
            session_ = OnnxSession(modelPath);
            ready_ = true;
        } catch (OnnxException e) {
            reason_ = e.msg;
            ready_ = false;
        }
    }

    AiModelAvailability availability() const {
        return ready_
            ? AiModelAvailability(AiModelStatus.ready)
            : AiModelAvailability(AiModelStatus.unavailable, reason_);
    }

    AiModelBackendPrediction predict(const ref AiInteractionContext context,
                                     const(AiCandidate)[] candidates) const {
        AiModelBackendPrediction prediction;
        if (!ready_ || candidates.length == 0)
            return prediction;

        auto batch = encodeAiRankerInput(deriveGroupId(candidates), context,
                                         candidates, maxCandidates_);
        auto input = encodeAiRankerExpandedBatch(batch);

        float[] scores;
        try {
            // Inference mutates the ORT session; the backend is logically const.
            auto self = cast(OnnxModelBackend) this;
            scores = self.session_.score(input, cast(int) batch.maxCandidates);
        } catch (OnnxException) {
            return prediction;
        }

        auto ranked = rank(scores, batch.candidateMask);
        if (ranked.index < 0 || ranked.index >= cast(int) candidates.length)
            return prediction;

        prediction.candidateIndex = ranked.index;
        prediction.candidateId = candidates[ranked.index].id;
        prediction.confidence = ranked.confidence;
        return prediction;
    }
}

/// Pick the ranker group from the candidate set's kind (handle / element /
/// mode-tool-context), matching `ai.ranker_schema.aiRankerGroupIndex`. The
/// adapter is invoked per candidate group, so the first typed candidate wins.
private string deriveGroupId(const(AiCandidate)[] candidates) {
    foreach (ref c; candidates) {
        if (c.kind == AiCandidateKind.handle)
            return "handle";
        if (c.kind == AiCandidateKind.element)
            return "element";
        if (c.kind == AiCandidateKind.mode || c.kind == AiCandidateKind.context)
            return "mode-tool-context";
    }
    return "";
}
