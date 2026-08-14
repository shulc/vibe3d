// Module unittests for `ai.ranker_schema`, moved verbatim out of source/ai/ranker_schema.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.ranker_schema_test;

import std.algorithm : min;
import std.math : isFinite;
import ai.debug_trace : aiElementCandidateKindId, aiIntentId;
import ai.interaction : AiCandidate, AiCandidateKind,
    AiElementCandidateKind, AiInteractionContext, AiInteractionPhase,
    AiIntent;
import ai.interaction_log : AiInteractionLogRecord, aiCandidateKindId,
    aiInteractionPhaseId;
import ai.ranker_schema;

unittest {
    auto contextNames = aiRankerContextFeatureNames();
    auto candidateNames = aiRankerCandidateFeatureNames();
    assert(contextNames.length == aiRankerGroupCategoryCount +
           aiRankerPhaseCategoryCount +
           aiRankerIntentCategoryCount + 11);
    assert(candidateNames.length == aiRankerCandidateKindCategoryCount +
           aiRankerElementKindCategoryCount +
           aiRankerIntentCategoryCount + 14);
}

unittest {
    // Expanded vector mirrors the trainer's FeatureSpace.encode_candidate:
    // candidate features first, then context*candidate (context outer).
    float[] ctx = [2.0f, 3.0f];
    float[] cand = [5.0f, 7.0f];
    auto ex = encodeAiRankerExpandedCandidate(ctx, cand);
    assert(ex.length == cand.length + ctx.length * cand.length);
    assert(ex[0] == 5.0f && ex[1] == 7.0f);             // candidate prefix
    assert(ex[2] == 2.0f * 5.0f && ex[3] == 2.0f * 7.0f); // ctx0 * cand
    assert(ex[4] == 3.0f * 5.0f && ex[5] == 3.0f * 7.0f); // ctx1 * cand

    assert(aiRankerExpandedFeatureCount() ==
           aiRankerCandidateFeatureNames().length +
           aiRankerContextFeatureNames().length *
           aiRankerCandidateFeatureNames().length);

    // Batch expansion is row-major and zero-pads masked rows.
    AiInteractionContext context;
    AiCandidate c;
    c.id = "x";
    auto batch = encodeAiRankerInput("handle", context, [c], 2);
    auto mat = encodeAiRankerExpandedBatch(batch);
    immutable width = aiRankerExpandedFeatureCount();
    assert(mat.length == 2 * width);          // maxCandidates rows
    bool padZero = true;
    foreach (v; mat[width .. $])              // second (padded) row
        if (v != 0.0f) { padZero = false; break; }
    assert(padZero);
}
