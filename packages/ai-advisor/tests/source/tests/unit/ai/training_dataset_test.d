// Module unittests for `ai.training_dataset`, moved verbatim out of source/ai/training_dataset.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.training_dataset_test;

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
import ai.training_dataset;

unittest {
    auto result = exportAiSyntheticTrainingDatasetJsonl();
    assert(result.stats.total == 3);
    assert(result.stats.labeled == 3);
    assert(result.stats.unlabeled == 0);
    assert(result.stats.skipped == 0);
    assert(result.lines.length == 3);
}
