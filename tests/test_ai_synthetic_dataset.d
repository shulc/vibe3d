// Pure tests for the deterministic synthetic AI interaction dataset.

import std.algorithm : count;
import std.json : JSONType, parseJSON;
import std.string : splitLines;

import ai.interaction_log : aiInteractionLogSchemaVersion;
import ai.synthetic_dataset : makeAiSyntheticInteractionDataset,
    makeAiSyntheticInteractionDatasetJsonLines,
    makeAiSyntheticInteractionDatasetJsonl;

void main() {}

unittest { // generator returns the expected deterministic record families
    auto records = makeAiSyntheticInteractionDataset();
    assert(records.length == 3);

    assert(records[0].source == "ai-synthetic.handle");
    assert(records[0].groupId == "handle");
    assert(records[0].appliedWinnerId == "handle:y-axis");

    assert(records[1].source == "ai-synthetic.element");
    assert(records[1].groupId == "element");
    assert(records[1].appliedWinnerId == "element:face:8");

    assert(records[2].source == "ai-synthetic.mode-tool-context");
    assert(records[2].groupId == "mode-tool-context");
    assert(records[2].appliedWinnerId == "tool:bevel");

    foreach (i, ref record; records) {
        assert(record.schemaVersion == aiInteractionLogSchemaVersion);
        assert(record.hasSequence);
        assert(record.sequence == cast(ulong)i + 1);
        assert(!record.hasTimestampUnixMs);
    }
}

unittest { // JSONL lines parse and preserve schema/source/group distribution
    auto lines = makeAiSyntheticInteractionDatasetJsonLines();
    assert(lines.length == 3);

    size_t handleCount;
    size_t elementCount;
    size_t modeToolContextCount;
    foreach (line; lines) {
        auto j = parseJSON(line);
        assert(j["schemaVersion"].integer == aiInteractionLogSchemaVersion);
        assert(j["source"].str.length > 0);
        assert(j["candidates"].array.length > 0);
        assert(j["appliedWinner"]["present"].type == JSONType.true_);
        assert(j["outcome"]["accepted"].type == JSONType.true_);

        switch (j["groupId"].str) {
            case "handle":
                ++handleCount;
                assert(j["source"].str == "ai-synthetic.handle");
                assert(j["context"]["phase"].str == "mouseDown");
                assert(j["appliedWinner"]["id"].str == "handle:y-axis");
                break;
            case "element":
                ++elementCount;
                assert(j["source"].str == "ai-synthetic.element");
                assert(j["context"]["phase"].str == "hover");
                assert(j["appliedWinner"]["id"].str == "element:face:8");
                break;
            case "mode-tool-context":
                ++modeToolContextCount;
                assert(j["source"].str ==
                       "ai-synthetic.mode-tool-context");
                assert(j["context"]["phase"].str == "toolSwitch");
                assert(j["appliedWinner"]["id"].str == "tool:bevel");
                break;
            default:
                assert(false, "unexpected synthetic dataset group");
        }
    }

    assert(handleCount == 1);
    assert(elementCount == 1);
    assert(modeToolContextCount == 1);
}

unittest { // joined JSONL is stable and contains one line per record
    auto jsonl = makeAiSyntheticInteractionDatasetJsonl();
    assert(jsonl.count('\n') == 2);

    auto lines = jsonl.splitLines();
    assert(lines.length == 3);
    assert(parseJSON(lines[0])["appliedWinner"]["id"].str ==
           "handle:y-axis");
    assert(parseJSON(lines[1])["appliedWinner"]["id"].str ==
           "element:face:8");
    assert(parseJSON(lines[2])["appliedWinner"]["id"].str == "tool:bevel");
}
