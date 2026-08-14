// Module unittests for `ai.interaction_log_writer`, moved verbatim out of source/ai/interaction_log_writer.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai.interaction_log_writer_test;

import std.array : appender;
import std.process : environment;
import ai.interaction_log : AiInteractionLogRecord;
import ai.interaction_log_writer;

// Disabled writer (empty path) opens no file and `append` is a pure no-op.
unittest {
    import std.file : exists, tempDir, remove;
    import std.path : buildPath;
    import ai.interaction : AiInteractionContext;
    import ai.interaction_log : makeAiInteractionLogRecord;

    auto missing = buildPath(tempDir(), "vibe3d_ai_log_should_not_exist.jsonl");
    if (exists(missing))
        remove(missing);

    auto writer = new AiInteractionLogWriter("");
    assert(!writer.enabled);

    AiInteractionContext ctx;
    auto record = makeAiInteractionLogRecord("live-session", "elements",
                                             ctx, []);
    writer.append(record);   // no-op
    writer.flush();
    writer.close();
    assert(!exists(missing));
}

// Enabled writer appends N parseable lines, each tagged live-session, and a
// flush-on-close loses nothing.
unittest {
    import std.array : split;
    import std.file : tempDir, readText, remove, exists;
    import std.path : buildPath;
    import std.string : startsWith, strip;
    import ai.interaction : AiInteractionContext;
    import ai.interaction_log : makeAiInteractionLogRecord,
        parseAiInteractionLogLine;

    auto path = buildPath(tempDir(), "vibe3d_ai_log_writer_test.jsonl");
    if (exists(path))
        remove(path);
    static void cleanup(string p) { try { remove(p); } catch (Exception) {} }
    scope(exit) cleanup(path);

    auto writer = new AiInteractionLogWriter(path);
    assert(writer.enabled);

    AiInteractionContext ctx;
    enum N = 5;
    foreach (i; 0 .. N) {
        auto record = makeAiInteractionLogRecord(defaultLiveSource(),
                                                 "elements", ctx, []);
        writer.append(record);
    }
    writer.close();   // flush-on-close

    auto text = readText(path);
    auto lines = text.split("\n");
    size_t count;
    foreach (line; lines) {
        if (line.strip.length == 0)
            continue;
        ++count;
        auto rec = parseAiInteractionLogLine(line);
        assert(rec.source.startsWith("live-session"));
        assert(rec.hasSequence);
        assert(rec.hasTimestampUnixMs);
    }
    assert(count == N);

    // Reopen in append mode: more lines accumulate (no truncation).
    auto writer2 = new AiInteractionLogWriter(path);
    assert(writer2.enabled);
    auto record = makeAiInteractionLogRecord(defaultLiveSource(),
                                             "handles", ctx, []);
    writer2.append(record);
    writer2.close();

    auto text2 = readText(path);
    size_t count2;
    foreach (line; text2.split("\n"))
        if (line.strip.length)
            ++count2;
    assert(count2 == N + 1);
}
