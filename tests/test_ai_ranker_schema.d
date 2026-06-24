// Pure tests for the candidate ranker feature schema.

import std.algorithm : canFind;

import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiIntent;
import ai.interaction_log : makeAiInteractionLogRecord;
import ai.ranker_schema : aiRankerCandidateFeatureNames,
    aiRankerContextFeatureNames, aiRankerDefaultMaxCandidates,
    aiRankerFeatureSchemaVersion, aiRankerLabelFromRecord,
    aiRankerSelectArgmax, encodeAiRankerInput;
import ai.synthetic_dataset : makeAiSyntheticInteractionDataset;

void main() {}

unittest { // synthetic dataset records encode into padded feature batches
    foreach (ref record; makeAiSyntheticInteractionDataset()) {
        auto batch = encodeAiRankerInput(record);
        auto label = aiRankerLabelFromRecord(record);

        assert(batch.schemaVersion == aiRankerFeatureSchemaVersion);
        assert(batch.maxCandidates == aiRankerDefaultMaxCandidates);
        assert(batch.candidateCount == record.candidates.length);
        assert(batch.contextFeatures.length ==
               aiRankerContextFeatureNames().length);
        assert(batch.candidateFeatures.length == aiRankerDefaultMaxCandidates);
        assert(batch.candidateMask.length == aiRankerDefaultMaxCandidates);
        assert(label.present);
        assert(label.candidateId == record.appliedWinnerId);

        foreach (i; 0 .. aiRankerDefaultMaxCandidates) {
            assert(batch.candidateFeatures[i].length ==
                   aiRankerCandidateFeatureNames().length);
            assert(batch.candidateMask[i] ==
                   (i < batch.candidateCount ? 1.0f : 0.0f));
        }
    }
}

unittest { // label-like record fields do not alter encoded input features
    auto record = makeAiSyntheticInteractionDataset()[0];
    auto original = encodeAiRankerInput(record);

    record.advisorDecision.confidence = 1.0f;
    record.advisorDecision.candidateIndex = 2;
    record.advisorDecision.candidateId = "handle:center-free";
    record.withAppliedWinner(2, "handle:center-free");
    record.withOutcome("accepted", "changed-after-input", true);

    auto changed = encodeAiRankerInput(record);
    assert(original.contextFeatures == changed.contextFeatures);
    assert(original.candidateMask == changed.candidateMask);
    foreach (i; 0 .. original.candidateFeatures.length)
        assert(original.candidateFeatures[i] == changed.candidateFeatures[i]);

    auto label = aiRankerLabelFromRecord(record);
    assert(label.present);
    assert(label.index == 2);
    assert(label.candidateId == "handle:center-free");
}

unittest { // variable candidate count uses mask and drops labels past max
    AiInteractionContext context;
    context.defaultIntent = AiIntent.handle;

    AiCandidate x;
    x.id = "handle:x";
    x.kind = AiCandidateKind.handle;
    x.intent = AiIntent.dragAxisX;
    x.isDefaultWinner = true;

    AiCandidate y;
    y.id = "handle:y";
    y.kind = AiCandidateKind.handle;
    y.intent = AiIntent.dragAxisY;

    AiCandidate z;
    z.id = "handle:z";
    z.kind = AiCandidateKind.handle;
    z.intent = AiIntent.dragAxisZ;

    auto record = makeAiInteractionLogRecord(
        "test", "handle", context, [x, y, z], AiAdvisorDecision(), 2);

    auto batch = encodeAiRankerInput(record, 2);
    assert(batch.maxCandidates == 2);
    assert(batch.candidateCount == 2);
    assert(batch.candidateMask == [1.0f, 1.0f]);
    assert(!aiRankerLabelFromRecord(record, 2).present);
    assert(aiRankerLabelFromRecord(record, 3).index == 2);
}

unittest { // missing and unknown labels are represented as absent
    AiInteractionContext context;
    AiCandidate candidate;
    candidate.id = "handle:x";
    candidate.kind = AiCandidateKind.handle;
    candidate.intent = AiIntent.dragAxisX;

    auto missing = makeAiInteractionLogRecord(
        "test", "handle", context, [candidate]);
    missing.withAppliedWinner(-1, "");
    assert(!aiRankerLabelFromRecord(missing).present);

    auto unknown = makeAiInteractionLogRecord(
        "test", "handle", context, [candidate]);
    unknown.withAppliedWinner(7, "handle:unknown");
    assert(!aiRankerLabelFromRecord(unknown).present);
}

unittest { // feature names are input-only and expose no training labels
    foreach (name; aiRankerContextFeatureNames() ~
                   aiRankerCandidateFeatureNames()) {
        assert(!name.canFind("advisor"));
        assert(!name.canFind("applied"));
        assert(!name.canFind("outcome"));
        assert(!name.canFind("accepted"));
        assert(!name.canFind("label"));
        assert(!name.canFind("winner"));
        assert(!name.canFind("confidence"));
    }
}

unittest { // v1 feature order has a small golden prefix/suffix contract
    auto contextNames = aiRankerContextFeatureNames();
    assert(contextNames[0] == "context.group.unknown");
    assert(contextNames[1] == "context.group.handle");
    assert(contextNames[4] == "context.phase.unknown");
    assert(contextNames[$ - 2] == "context.active_tool_present");
    assert(contextNames[$ - 1] == "context.edit_mode_present");

    auto candidateNames = aiRankerCandidateFeatureNames();
    assert(candidateNames[0] == "candidate.kind.unknown");
    assert(candidateNames[1] == "candidate.kind.element");
    assert(candidateNames[10] == "candidate.intent.keepDefault");
    assert(candidateNames[$ - 3] == "candidate.world_x_norm");
    assert(candidateNames[$ - 2] == "candidate.world_y_norm");
    assert(candidateNames[$ - 1] == "candidate.world_z_norm");
}

unittest { // output contract is score per candidate plus masked argmax index
    assert(aiRankerSelectArgmax([0.2f, 0.9f, 1.0f],
                                [1.0f, 1.0f, 0.0f]) == 1);
    assert(aiRankerSelectArgmax([0.2f, 0.9f],
                                [0.0f, 0.0f]) == -1);
}
