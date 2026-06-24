/// Dump the v1 AI ranker training dataset as JSONL to stdout.
///
/// Closes the gap between the D exporter (`ai.training_dataset`, task 0023) and
/// the offline trainer (`tools/ai/ranker_trainer.py`, task 0024): the exporter
/// was previously only exercised from unit tests. Pipe this into the trainer:
///
///   rdmd -I=source tools/ai/dump_training_dataset.d > /tmp/train.jsonl
///   python3 ../vibe3d_private/tools/ai/ranker_trainer.py /tmp/train.jsonl \
///       --epochs 8 --learning-rate 0.25 --weights-out /tmp/weights.json
///
/// Default source is the deterministic synthetic corpus
/// (`makeAiSyntheticInteractionDataset`); real interaction logs can be fed
/// through `exportAiTrainingDatasetJsonl` in a later runner.
module dump_training_dataset;

import std.stdio : writeln;

import ai.training_dataset : exportAiSyntheticTrainingDatasetJsonl;

void main() {
    auto result = exportAiSyntheticTrainingDatasetJsonl();
    writeln(result.jsonl);
}
