/// Convert a captured interaction-log JSONL file into trainer-input JSONL.
///
/// Closes the loop between the live capture sink (`ai.interaction_log_writer`,
/// task 0027) and the offline trainer (`tools/ai/ranker_trainer.py`, task
/// 0024): each captured line is parsed back into an `AiInteractionLogRecord`
/// and run through the same `exportAiTrainingDatasetJsonl` the synthetic dumper
/// uses, so the trainer trains on REAL labeled sessions. Pipe it in:
///
///   rdmd -I=source tools/ai/capture_to_training_dataset.d /tmp/x.jsonl > /tmp/train.jsonl
///   python3 ../vibe3d_private/tools/ai/ranker_trainer.py /tmp/train.jsonl \
///       --epochs 8 --learning-rate 0.25 --weights-out /tmp/weights.json
///
/// Reads a path argument, or stdin when none is given. Blank lines and
/// `//`-comment lines are skipped defensively. Stats (total / labeled) go to
/// stderr so stdout stays clean JSONL. Pulls in only `ai.* + Phobos` — no
/// mesh/app/GL/SDL — so it compiles standalone via `rdmd -I=source`.
module capture_to_training_dataset;

import std.stdio : writeln, writefln, stderr, stdin, File;
import std.string : strip, startsWith;

import ai.interaction_log : AiInteractionLogRecord, parseAiInteractionLogLine;
import ai.training_dataset : exportAiTrainingDatasetJsonl;

void main(string[] args) {
    AiInteractionLogRecord[] records;

    void consume(string line) {
        auto trimmed = line.strip;
        if (trimmed.length == 0 || trimmed.startsWith("//"))
            return;
        records ~= parseAiInteractionLogLine(trimmed);
    }

    if (args.length > 1) {
        foreach (line; File(args[1], "r").byLineCopy)
            consume(line);
    } else {
        foreach (line; stdin.byLineCopy)
            consume(line);
    }

    auto result = exportAiTrainingDatasetJsonl(records);
    if (result.jsonl.length)
        writeln(result.jsonl);

    stderr.writefln("capture_to_training_dataset: total=%d labeled=%d unlabeled=%d",
                    result.stats.total, result.stats.labeled,
                    result.stats.unlabeled);
}
