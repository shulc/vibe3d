module playback_controller;

import core.time : MonoTime;
import eventlog : EventPlayer, ParsedEventLog;
import std.format : format;

/// Result of accepting one validated playback log on the main thread.
struct PlaybackAcceptOutcome {
    bool accepted;
    ulong generation;
    ulong replaced;
}

/// One coherent snapshot of the player state, including its identity.
struct PlaybackStatus {
    bool finished;
    size_t total;
    size_t remaining;
    size_t immediateMotions;
    ulong generation;
}

/// Main-thread owner for the HTTP playback player (task 5960 D2). Parsing may
/// happen on the HTTP thread, but accepting, ticking and observing a log all
/// pass through this controller. The focused ownership and phase evidence is
/// in tests/unit/playback_owner_test.d.
struct PlaybackController {
    EventPlayer eventPlayer;
    private ulong generation_;
    version(unittest) {
        private size_t acceptThreadForTest_;
        private size_t acceptCallsForTest_;
    }

    PlaybackAcceptOutcome accept(ParsedEventLog log, MonoTime notAfter)
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
        outcome.replaced = eventPlayer.active ? generation_ : 0;
        outcome.generation = ++generation_;
        eventPlayer.begin(log);
        return outcome;
    }

    bool tick() {
        return eventPlayer.tick();
    }

    void setFastForward(bool enabled) {
        eventPlayer.fastForward = enabled;
    }

    int mouseX() const { return eventPlayer.mouseX; }
    int mouseY() const { return eventPlayer.mouseY; }
    bool mouseDown() const { return eventPlayer.mouseDown; }

    PlaybackStatus status() const {
        PlaybackStatus result;
        result.finished = !eventPlayer.active;
        result.total = eventPlayer.entries.length;
        result.remaining = result.finished
            ? 0 : result.total - eventPlayer.idx;
        result.immediateMotions = eventPlayer.immediateMotionDeliveries();
        result.generation = generation_;
        return result;
    }

    version(unittest) {
        size_t acceptThreadForTest() const { return acceptThreadForTest_; }
        size_t acceptCallsForTest() const { return acceptCallsForTest_; }
    }
}

/// Compact by contract: run_test.d has a byte reader for `"finished":false`.
string encodePlaybackStatus(PlaybackStatus status) {
    return format(
        `{"finished":%s,"total":%d,"remaining":%d,"immediateMotions":%d,"generation":%d}`,
        status.finished ? "true" : "false",
        status.total,
        status.remaining,
        status.immediateMotions,
        status.generation);
}
