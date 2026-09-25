module playback_controller;

import core.time : MonoTime;
import eventlog : EventLogParseResult, EventPlayer, ImmediateEventSink,
    ParsedEventLog, parseEventLog;
import std.format : format;

/// Result of accepting one validated playback log on the main thread.
struct PlaybackAcceptOutcome {
    bool accepted;
    bool invalidLog;
    ulong generation;
    ulong replaced;
}

static assert([__traits(allMembers, PlaybackAcceptOutcome)]
        == ["accepted", "invalidLog", "generation", "replaced"],
    "6810 playback accept outcome composition changed");

/// One coherent snapshot of the player state, including its identity.
struct PlaybackStatus {
    bool finished;
    size_t total;
    size_t remaining;
    size_t immediateMotions;
    ulong generation;
    /// Filled by the HTTP owner, not by `status()`: `frame` is the tickAll pass
    /// that served the read, and `processed` is `finished` plus at least one
    /// COMPLETED frame after the one that dispatched the last event (card
    /// test-sleep-removal; witness tests/unit/playback_owner_test.d U9).
    bool processed;
    ulong frame;
}

/// Main-thread owner for the HTTP playback player (tasks 5960 D2 and 6810).
/// Parsing, accepting, ticking and observing a log all pass through this
/// controller; the transport carries only the owned raw body. Evidence:
/// tests/unit/playback_parse_owner_test.d and playback_owner_test.d.
struct PlaybackController {
    private EventPlayer eventPlayer_;
    private ulong generation_;
    version(unittest) {
        private size_t parseThreadForTest_;
        private size_t parseCallsForTest_;
        private size_t acceptThreadForTest_;
        private size_t acceptCallsForTest_;
    }

    PlaybackAcceptOutcome accept(string data, MonoTime notAfter)
    {
        PlaybackAcceptOutcome outcome;
        if (MonoTime.currTime >= notAfter)
            return outcome;

        version(unittest) {
            import core.thread : Thread;
            parseThreadForTest_ = cast(size_t) cast(void*) Thread.getThis();
            ++parseCallsForTest_;
        }
        EventLogParseResult parsed;
        try parsed = parseEventLog(data);
        // Catch Exception, not Throwable: an Error is a broken invariant.
        catch (Exception) {
            outcome.invalidLog = true;
            return outcome;
        }
        if (!parsed.accepted) {
            outcome.invalidLog = true;
            return outcome;
        }
        return acceptParsed(parsed.log, notAfter);
    }

    private PlaybackAcceptOutcome acceptParsed(ParsedEventLog log,
                                                 MonoTime notAfter)
    in (log.entries.length > 0)
    {
        PlaybackAcceptOutcome outcome;
        if (MonoTime.currTime >= notAfter)
            return outcome;

        outcome.accepted = true;
        version(unittest) {
            import core.thread : Thread;
            acceptThreadForTest_ = cast(size_t) cast(void*) Thread.getThis();
            ++acceptCallsForTest_;
        }
        outcome.replaced = eventPlayer_.active ? generation_ : 0;
        outcome.generation = ++generation_;
        eventPlayer_.begin(log);
        return outcome;
    }

    bool tick() {
        return eventPlayer_.tick();
    }

    void setFastForward(bool enabled) {
        eventPlayer_.fastForward = enabled;
    }

    void setImmediateSink(ImmediateEventSink sink) {
        eventPlayer_.setImmediateSink(sink);
    }

    int mouseX() const { return eventPlayer_.mouseX; }
    int mouseY() const { return eventPlayer_.mouseY; }
    bool mouseDown() const { return eventPlayer_.mouseDown; }
    auto recordedViewport() const { return eventPlayer_.recordedViewport; }

    PlaybackStatus status() const {
        PlaybackStatus result;
        result.finished = !eventPlayer_.active;
        result.total = eventPlayer_.entries.length;
        result.remaining = result.finished
            ? 0 : result.total - eventPlayer_.idx;
        result.immediateMotions = eventPlayer_.immediateMotionDeliveries();
        result.generation = generation_;
        return result;
    }

    version(unittest) {
        size_t parseThreadForTest() const { return parseThreadForTest_; }
        size_t parseCallsForTest() const { return parseCallsForTest_; }
        size_t acceptThreadForTest() const { return acceptThreadForTest_; }
        size_t acceptCallsForTest() const { return acceptCallsForTest_; }
    }
}

/// Compact by contract: run_test.d has byte readers for `"finished":false`
/// and `"processed":false`.
string encodePlaybackStatus(PlaybackStatus status) {
    return format(
        `{"finished":%s,"total":%d,"remaining":%d,"immediateMotions":%d,"generation":%d,"processed":%s,"frame":%d}`,
        status.finished ? "true" : "false",
        status.total,
        status.remaining,
        status.immediateMotions,
        status.generation,
        status.processed ? "true" : "false",
        status.frame);
}
