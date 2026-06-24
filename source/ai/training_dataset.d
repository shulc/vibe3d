module ai.training_dataset;

import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.math : isFinite;

import ai.interaction_log : AiInteractionLogRecord;
import ai.ranker_schema : AiRankerFeatureBatch, AiRankerLabel,
    aiRankerCandidateFeatureNames, aiRankerContextFeatureNames,
    aiRankerDefaultMaxCandidates,
    aiRankerFeatureSchemaVersion, aiRankerLabelFromRecord,
    encodeAiRankerInput;
import ai.synthetic_dataset : makeAiSyntheticInteractionDataset;

enum int aiTrainingDatasetSchemaVersion = 1;
enum int aiTrainingDatasetExporterVersion = 1;

struct AiTrainingDatasetExportStats {
    size_t total = 0;
    size_t labeled = 0;
    size_t unlabeled = 0;
    size_t skipped = 0;
}

struct AiTrainingDatasetExportResult {
    string jsonl = "";
    string[] lines;
    AiTrainingDatasetExportStats stats;
}

AiTrainingDatasetExportResult exportAiTrainingDatasetJsonl(
    const(AiInteractionLogRecord)[] records,
    size_t maxCandidates = aiRankerDefaultMaxCandidates) {
    AiTrainingDatasetExportResult result;
    result.lines = exportAiTrainingDatasetJsonLines(records,
                                                    result.stats,
                                                    maxCandidates);

    auto buf = appender!string();
    foreach (line; result.lines) {
        if (buf.data.length)
            buf.put("\n");
        buf.put(line);
    }
    result.jsonl = buf.data;
    return result;
}

string[] exportAiTrainingDatasetJsonLines(
    const(AiInteractionLogRecord)[] records,
    ref AiTrainingDatasetExportStats stats,
    size_t maxCandidates = aiRankerDefaultMaxCandidates) {
    stats = AiTrainingDatasetExportStats();

    string[] lines;
    foreach (ref record; records) {
        ++stats.total;

        auto batch = encodeAiRankerInput(record, maxCandidates);
        auto label = aiRankerLabelFromRecord(record, maxCandidates);
        if (label.present)
            ++stats.labeled;
        else
            ++stats.unlabeled;

        auto buf = appender!string();
        putTrainingDatasetRecordJson(buf, record, batch, label);
        lines ~= buf.data;
    }
    return lines;
}

AiTrainingDatasetExportResult exportAiSyntheticTrainingDatasetJsonl(
    size_t maxCandidates = aiRankerDefaultMaxCandidates) {
    return exportAiTrainingDatasetJsonl(makeAiSyntheticInteractionDataset(),
                                        maxCandidates);
}

private void putTrainingDatasetRecordJson(B)(
    ref B buf,
    const ref AiInteractionLogRecord record,
    const ref AiRankerFeatureBatch batch,
    const ref AiRankerLabel label) {
    buf.put(`{"schemaVersion":`);
    buf.put(aiTrainingDatasetSchemaVersion.to!string);
    buf.put(`,"exporterVersion":`);
    buf.put(aiTrainingDatasetExporterVersion.to!string);
    buf.put(`,"source":`);
    putJsonString(buf, record.source);
    buf.put(`,"groupId":`);
    putJsonString(buf, record.groupId);
    buf.put(`,"inputFeatureSchemaVersion":`);
    buf.put(aiRankerFeatureSchemaVersion.to!string);
    buf.put(`,"input":`);
    putInputJson(buf, batch);
    buf.put(`,"label":`);
    putLabelJson(buf, label.present, label.index, label.candidateId);
    buf.put(`}`);
}

private void putInputJson(B)(ref B buf, const ref AiRankerFeatureBatch batch) {
    buf.put(`{"featureSchemaVersion":`);
    buf.put(aiRankerFeatureSchemaVersion.to!string);
    buf.put(`,"contextFeatureNames":`);
    putStringArrayJson(buf, aiRankerContextFeatureNames());
    buf.put(`,"candidateFeatureNames":`);
    putStringArrayJson(buf, aiRankerCandidateFeatureNames());
    buf.put(`,"contextFeatures":`);
    putFloatArrayJson(buf, batch.contextFeatures);
    buf.put(`,"candidateFeatures":`);
    putFloatMatrixJson(buf, batch.candidateFeatures);
    buf.put(`,"candidateMask":`);
    putFloatArrayJson(buf, batch.candidateMask);
    buf.put(`,"candidateCount":`);
    buf.put(batch.candidateCount.to!string);
    buf.put(`,"maxCandidates":`);
    buf.put(batch.maxCandidates.to!string);
    buf.put(`}`);
}

private void putLabelJson(B)(ref B buf,
                             bool present,
                             int index,
                             string candidateId) {
    buf.put(`{"present":`);
    buf.put(present ? "true" : "false");
    buf.put(`,"index":`);
    buf.put(present ? index.to!string : "-1");
    buf.put(`,"id":`);
    putJsonString(buf, present ? candidateId : "");
    buf.put(`}`);
}

private void putStringArrayJson(B)(ref B buf, string[] values) {
    buf.put(`[`);
    foreach (i, value; values) {
        if (i) buf.put(`,`);
        putJsonString(buf, value);
    }
    buf.put(`]`);
}

private void putFloatMatrixJson(B)(ref B buf, const(float[][]) values) {
    buf.put(`[`);
    foreach (i, row; values) {
        if (i) buf.put(`,`);
        putFloatArrayJson(buf, row);
    }
    buf.put(`]`);
}

private void putFloatArrayJson(B)(ref B buf, const(float)[] values) {
    buf.put(`[`);
    foreach (i, value; values) {
        if (i) buf.put(`,`);
        putJsonFloat(buf, value);
    }
    buf.put(`]`);
}

private void putJsonString(B)(ref B buf, string value) {
    buf.put(JSONValue(value).toString());
}

private void putJsonFloat(B)(ref B buf, float value) {
    if (value.isFinite)
        buf.put(format("%.9g", value));
    else
        buf.put(`null`);
}

unittest {
    auto result = exportAiSyntheticTrainingDatasetJsonl();
    assert(result.stats.total == 3);
    assert(result.stats.labeled == 3);
    assert(result.stats.unlabeled == 0);
    assert(result.stats.skipped == 0);
    assert(result.lines.length == 3);
}
