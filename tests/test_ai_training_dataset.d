// Pure tests for AI ranker training dataset JSONL export.

import std.algorithm : canFind;
import std.json : JSONType, parseJSON;
import std.string : splitLines;

import ai.interaction : AiAdvisorDecision, AiCandidate, AiCandidateKind,
    AiInteractionContext, AiIntent;
import ai.interaction_log : makeAiInteractionLogRecord;
import ai.ranker_schema : aiRankerCandidateFeatureNames,
    aiRankerContextFeatureNames, aiRankerDefaultMaxCandidates,
    aiRankerFeatureSchemaVersion;
import ai.synthetic_dataset : makeAiSyntheticInteractionDataset;
import ai.training_dataset : aiTrainingDatasetExporterVersion,
    aiTrainingDatasetSchemaVersion, exportAiSyntheticTrainingDatasetJsonl,
    exportAiTrainingDatasetJsonl;

void main() {}

private AiCandidate handleCandidate(string id, bool isDefault = false) {
    AiCandidate candidate;
    candidate.id = id;
    candidate.kind = AiCandidateKind.handle;
    candidate.intent = AiIntent.handle;
    candidate.isDefaultWinner = isDefault;
    return candidate;
}

unittest { // synthetic dataset exports deterministic parseable JSONL
    auto first = exportAiSyntheticTrainingDatasetJsonl();
    auto second = exportAiSyntheticTrainingDatasetJsonl();

    assert(first.lines.length == 3);
    assert(first.lines == second.lines);
    assert(first.jsonl == second.jsonl);
    assert(first.jsonl.splitLines().length == 3);

    foreach (i, line; first.lines) {
        auto j = parseJSON(line);
        assert(j["schemaVersion"].integer == aiTrainingDatasetSchemaVersion);
        assert(j["exporterVersion"].integer ==
               aiTrainingDatasetExporterVersion);
        assert(j["source"].str.length > 0);
        assert(j["groupId"].str.length > 0);
        assert(j["inputFeatureSchemaVersion"].integer ==
               aiRankerFeatureSchemaVersion);
        assert(j["input"]["featureSchemaVersion"].integer ==
               aiRankerFeatureSchemaVersion);
        assert(j["label"]["present"].type == JSONType.true_);
        assert(j["label"]["index"].integer >= 0);
        assert(j["label"]["id"].str.length > 0);

        if (i == 0)
            assert(j["label"]["id"].str == "handle:y-axis");
        else if (i == 1)
            assert(j["label"]["id"].str == "element:face:8");
        else if (i == 2)
            assert(j["label"]["id"].str == "tool:bevel");
    }
}

unittest { // export stats count total, labeled, and unlabeled records
    auto synthetic = exportAiSyntheticTrainingDatasetJsonl();
    assert(synthetic.stats.total == 3);
    assert(synthetic.stats.labeled == 3);
    assert(synthetic.stats.unlabeled == 0);
    assert(synthetic.stats.skipped == 0);

    AiInteractionContext context;
    auto candidates = [
        handleCandidate("handle:x", true),
        handleCandidate("handle:y"),
    ];

    auto labeled = makeAiInteractionLogRecord(
        "test", "handle", context, candidates, AiAdvisorDecision(), 1);
    auto missing = makeAiInteractionLogRecord(
        "test", "handle", context, candidates);
    missing.withAppliedWinner(-1, "");

    auto mixed = exportAiTrainingDatasetJsonl([labeled, missing]);
    assert(mixed.stats.total == 2);
    assert(mixed.stats.labeled == 1);
    assert(mixed.stats.unlabeled == 1);
    assert(mixed.stats.skipped == 0);
}

unittest { // missing, unknown, and truncated winners export as unlabeled
    AiInteractionContext context;
    auto candidates = [
        handleCandidate("handle:x", true),
        handleCandidate("handle:y"),
    ];

    auto missing = makeAiInteractionLogRecord(
        "test", "handle", context, candidates);
    missing.withAppliedWinner(-1, "");

    auto unknown = makeAiInteractionLogRecord(
        "test", "handle", context, candidates);
    unknown.withAppliedWinner(7, "handle:unknown");

    auto truncated = makeAiInteractionLogRecord(
        "test", "handle", context, candidates, AiAdvisorDecision(), 1);

    auto result = exportAiTrainingDatasetJsonl(
        [missing, unknown, truncated], 1);
    assert(result.stats.total == 3);
    assert(result.stats.labeled == 0);
    assert(result.stats.unlabeled == 3);
    assert(result.stats.skipped == 0);

    foreach (line; result.lines) {
        auto label = parseJSON(line)["label"];
        assert(label["present"].type == JSONType.false_);
        assert(label["index"].integer == -1);
        assert(label["id"].str.length == 0);
    }
}

unittest { // exported feature arrays align with schema names and masks
    auto records = makeAiSyntheticInteractionDataset();
    auto result = exportAiTrainingDatasetJsonl(records);

    foreach (recordIndex, line; result.lines) {
        auto input = parseJSON(line)["input"];
        auto contextNames = input["contextFeatureNames"].array;
        auto candidateNames = input["candidateFeatureNames"].array;
        auto contextFeatures = input["contextFeatures"].array;
        auto candidateFeatures = input["candidateFeatures"].array;
        auto candidateMask = input["candidateMask"].array;

        assert(contextNames.length == aiRankerContextFeatureNames().length);
        assert(candidateNames.length == aiRankerCandidateFeatureNames().length);
        assert(contextFeatures.length == contextNames.length);
        assert(candidateFeatures.length == aiRankerDefaultMaxCandidates);
        assert(candidateMask.length == aiRankerDefaultMaxCandidates);
        assert(input["candidateCount"].integer ==
               records[recordIndex].candidates.length);
        assert(input["maxCandidates"].integer ==
               aiRankerDefaultMaxCandidates);

        foreach (i, row; candidateFeatures) {
            assert(row.array.length == candidateNames.length);
            immutable expectedMask =
                i < records[recordIndex].candidates.length ? 1 : 0;
            assert(candidateMask[i].integer == expectedMask);
        }
    }
}

unittest { // input JSON contains no label-like fields
    auto result = exportAiSyntheticTrainingDatasetJsonl();

    foreach (line; result.lines) {
        auto inputJson = parseJSON(line)["input"].toString();
        foreach (forbidden; ["advisor", "applied", "outcome", "accepted",
                             "label", "winner", "confidence"]) {
            assert(!inputJson.canFind(forbidden));
        }
    }
}
