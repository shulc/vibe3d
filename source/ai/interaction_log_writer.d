module ai.interaction_log_writer;

import std.array : appender;
import std.process : environment;

import ai.interaction_log : AiInteractionLogRecord;

/// Opt-in buffered JSONL sink for live interaction-log capture.
///
/// Design constraints (all load-bearing — see task 0027 plan, "UI-thread
/// safety"):
///   - Runs on the main/SDL thread. No background thread, no locks.
///   - Every file operation is wrapped so a failed open/write degrades to a
///     silent no-op (`disabled_`); an exception is NEVER allowed to propagate
///     up through the event handler that called `append`.
///   - When constructed with an empty path the writer is fully inert: no file
///     is opened, `append` early-returns with zero allocation and zero syscall.
///     Callers therefore never need a null check.
class AiInteractionLogWriter {
    import std.stdio : File;

    private string path_;
    private bool disabled_ = true;
    private bool open_;
    private File file_;
    private ulong nextSequence_ = 1;
    private string[] buffer_;
    private size_t flushThreshold_ = 32;
    private bool warned_;

    /// Empty/null path ⇒ disabled (no file opened). Non-empty ⇒ try to open in
    /// append mode; on failure stay disabled and warn once to stderr.
    this(string path) {
        path_ = path;
        if (path.length == 0)
            return;
        try {
            file_ = File(path, "a");
            open_ = true;
            disabled_ = false;
        } catch (Exception e) {
            warnOnce("could not open '" ~ path ~ "': " ~ e.msg);
        }
    }

    /// Resolve a path from CLI override (wins) else the `VIBE3D_AI_LOG` env var.
    /// Returns a disabled writer when both are empty so callers never null-check.
    static AiInteractionLogWriter fromEnv(string cliPathOverride = "") {
        string path = cliPathOverride.length
            ? cliPathOverride
            : environment.get("VIBE3D_AI_LOG", "");
        return new AiInteractionLogWriter(path);
    }

    bool enabled() const {
        return !disabled_ && open_;
    }

    /// Append one record. No-op when disabled. Assigns a monotonic `sequence`
    /// and a `timestampUnixMs` when the record carries neither, then buffers the
    /// serialized line and flushes when the buffer crosses the threshold. Taken
    /// by value so the caller's rvalue or lvalue both bind and we get a mutable
    /// copy to stamp (the struct is small; its arrays are shared, not deep-
    /// copied, which is fine — we only read them via toJsonLine).
    void append(AiInteractionLogRecord rec) {
        if (!enabled)
            return;

        if (!rec.hasSequence)
            rec.withSequence(nextSequence_++);
        if (!rec.hasTimestampUnixMs)
            rec.withTimestampUnixMs(currentUnixTimeMs());

        buffer_ ~= rec.toJsonLine();
        if (buffer_.length >= flushThreshold_)
            flush();
    }

    /// Flush the in-memory buffer to the file. Any I/O failure disables the
    /// writer rather than throwing.
    void flush() {
        if (!enabled || buffer_.length == 0)
            return;
        try {
            auto buf = appender!string();
            foreach (line; buffer_) {
                buf.put(line);
                buf.put("\n");
            }
            file_.write(buf.data);
            file_.flush();
            buffer_.length = 0;
        } catch (Exception e) {
            warnOnce("write failed: " ~ e.msg);
            disabled_ = true;
        }
    }

    /// Flush remaining lines and close the file. Safe to call more than once.
    void close() {
        flush();
        if (open_) {
            try {
                file_.close();
            } catch (Exception) {
                // closing a broken handle must never throw upward.
            }
            open_ = false;
        }
        disabled_ = true;
    }

    ~this() {
        close();
    }

    private void warnOnce(string msg) {
        if (warned_)
            return;
        warned_ = true;
        try {
            import std.stdio : stderr;
            stderr.writeln("[ai] interaction-log capture disabled: " ~ msg);
        } catch (Exception) {
        }
    }
}

private long currentUnixTimeMs() {
    import std.datetime.systime : Clock;
    return Clock.currTime.toUnixTime!long * 1000;
}

/// Default `source` tag for live capture, suffixed with a per-process id so
/// corpora from different sessions are distinguishable and never collide with
/// `ai-synthetic.*`.
string defaultLiveSource() {
    import std.conv : to;
    import std.process : thisProcessID;
    return "live-session:" ~ thisProcessID().to!string;
}

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
