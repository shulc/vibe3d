module frame_stall;

/// A NAMED, environment-gated pause at ONE seam of the frame loop — off unless
/// its variable is set, and EDGE-TRIGGERED by the event whose window it widens.
///
/// WHY THIS IS PRODUCT CODE AND NOT A PATCH THAT GETS REVERTED (task 1670).
/// The defect this exists for is a sub-millisecond window between the HTTP
/// command bridge draining a `tool.set` and the same frame reaching
/// `activeTool.update(vts)`. A read of `/api/tool/state` landing inside it
/// answers the constructor default of a tool that has never been ticked. It
/// opened ONCE in 689 tests on the nightly runner (software GL, six workers)
/// and NEVER on this host: 40 idle repetitions and 30 under six-way load
/// produced zero failures. So repetition is not an instrument here, and a
/// test built on repetition would be an inert one.
///
/// Widening the window IS an instrument, and it was the one the diagnosis
/// used. Shipping it — rather than hand-editing a `Thread.sleep` in each time
/// — is what makes the fix's proof reproducible by the next reader: they set
/// one variable, revert one hunk, and watch the permanent cell go red. A
/// diagnosis whose evidence does not survive in the tree gets re-derived from
/// scratch, and this one cost a night of the runner to find.
///
/// The price of shipping it is one `bool` test per seam per frame when inert,
/// and the inertness is not asserted by inspection — the unittests below
/// assert it, by wall clock as well as by predicate, because "`inert()`
/// returns true" and "`waitAtSeam()` does nothing" are two different claims.

import core.thread : Thread;
import core.time   : dur;
import std.process : environment;

/// Hard ceiling on a stall, in milliseconds.
///
/// The value arrives from the ENVIRONMENT and multiplies a wall-clock wait, so
/// it is clamped HERE, at the consumer, and not merely documented: a mistyped
/// `VIBE3D_STALL_PRE_TOOL_TICK_MS=250000` would otherwise wedge a worker for
/// four minutes on every tool arm, which reads as a hang and not as a typo.
enum MAX_FRAME_STALL_MS = 5_000;

struct FrameStall {
    private int  pauseMs_;
    private bool pending_;

    /// Parse a millisecond count the way the environment hands one over.
    ///
    /// Anything that is not a POSITIVE integer literal is INERT — unset, empty,
    /// zero, negative, `"25ms"`, and an overflowing digit run all mean "off".
    /// The only safe reading of an unparseable stall is no stall at all: this
    /// runs in every build, including the owner's editor.
    static int parseMillis(string text) {
        import std.conv : to, ConvException;
        if (text.length == 0) return 0;
        int v;
        try {
            v = text.to!int;
        } catch (ConvException) {
            return 0;
        }
        if (v <= 0) return 0;
        return v > MAX_FRAME_STALL_MS ? MAX_FRAME_STALL_MS : v;
    }

    /// Clamped at this seam too, so a caller that skips `parseMillis` (the
    /// unittests below, and any future in-code configuration) cannot install
    /// an unbounded wait either.
    static FrameStall fromMillis(int ms) {
        FrameStall s;
        s.pauseMs_ = ms <= 0 ? 0
                   : (ms > MAX_FRAME_STALL_MS ? MAX_FRAME_STALL_MS : ms);
        return s;
    }

    /// Read once, at construction. Deliberately NOT re-read per frame: a stall
    /// that could switch on mid-run would be a second source of nondeterminism
    /// in exactly the lane that exists to remove one.
    static FrameStall fromEnvironment(string varName) {
        return FrameStall.fromMillis(parseMillis(environment.get(varName, "")));
    }

    int  pauseMs() const { return pauseMs_; }
    bool inert()   const { return pauseMs_ == 0; }
    bool pending() const { return pending_; }

    /// The watched event happened; the NEXT `waitAtSeam` pauses, once.
    /// A no-op on an inert stall, so nothing is left pending behind it.
    void arm() { if (pauseMs_ > 0) pending_ = true; }

    /// Pause iff something armed this stall since the last call, then disarm.
    ///
    /// EDGE-triggered on purpose. A level-triggered stall would pause every
    /// frame for the life of the process, which would make a whole test file
    /// unrunnable under it and push the reader back to hand-editing a sleep —
    /// the very thing this module replaces.
    void waitAtSeam() {
        if (!pending_) return;
        pending_ = false;
        Thread.sleep(dur!"msecs"(pauseMs_));
    }
}

// ---------------------------------------------------------------------------
// The parse is inert on everything that is not a positive integer, and the
// ceiling holds. This is the half a reader can check by eye; the next two
// cases are the half they cannot.
// ---------------------------------------------------------------------------
unittest {
    assert(FrameStall.parseMillis("")     == 0, "unset/empty is off");
    assert(FrameStall.parseMillis("0")    == 0, "an explicit zero is off");
    assert(FrameStall.parseMillis("-25")  == 0, "a negative is off, not a cast");
    assert(FrameStall.parseMillis("abc")  == 0, "a non-number is off");
    assert(FrameStall.parseMillis("25ms") == 0, "a unit suffix is off — the "
        ~ "variable's NAME carries the unit, so `25ms` is a typo, and a "
        ~ "partial parse of it would be a stall the author did not ask for");
    assert(FrameStall.parseMillis("99999999999999999999") == 0,
        "an overflowing digit run is off — ConvOverflowException is a "
        ~ "ConvException, so it lands in the same arm");

    assert(FrameStall.parseMillis("250") == 250, "…and a real value survives");
    assert(FrameStall.parseMillis("500000") == MAX_FRAME_STALL_MS,
        "a value past the ceiling is CLAMPED, never honoured: this multiplies "
        ~ "a wall-clock wait on every arm");
    assert(FrameStall.fromMillis(int.max).pauseMs == MAX_FRAME_STALL_MS,
        "the clamp is at the constructor too, not only in the parser");
}

// ---------------------------------------------------------------------------
// INERTNESS — the standing justification for this being product code, asserted
// rather than argued.
//
// Two separate claims, and the second is the one that matters: `inert()`
// answering true says the CONFIGURATION is off; only the clock says the SEAM
// costs nothing. Dropping the `pending_` guard in `waitAtSeam` would leave
// `inert()` telling the truth and the frame loop sleeping anyway.
// ---------------------------------------------------------------------------
unittest {
    import std.datetime.stopwatch : StopWatch, AutoStart;

    // A variable nobody sets — the state every build that is not running the
    // 1670 mutation is in, including the owner's editor.
    auto s = FrameStall.fromEnvironment("VIBE3D_STALL_THAT_NOBODY_SETS_1670");
    assert(s.inert && s.pauseMs == 0, "an unset variable is an inert stall");

    s.arm();
    assert(!s.pending,
        "arming an INERT stall must leave nothing pending — otherwise the "
        ~ "flag is live state in every build and only the pause is gated");

    auto sw = StopWatch(AutoStart.yes);
    foreach (_; 0 .. 20_000) { s.arm(); s.waitAtSeam(); }
    sw.stop();
    assert(sw.peek.total!"msecs" < 250,
        "20 000 inert seams must be free. If this is red, the seam is paying "
        ~ "for a feature nobody switched on.");
}

// ---------------------------------------------------------------------------
// …and the instrument actually works, once, per arm. Without this case the
// inertness above could be satisfied by a stall that never pauses at all —
// which would silently turn the 1670 mutation run into a green that proves
// nothing (the exact defect class the project calls an inert measurement).
// ---------------------------------------------------------------------------
unittest {
    import std.datetime.stopwatch : StopWatch, AutoStart;

    auto s = FrameStall.fromMillis(40);
    assert(!s.inert && s.pauseMs == 40);

    s.arm();
    assert(s.pending, "a configured stall arms");

    auto sw = StopWatch(AutoStart.yes);
    s.waitAtSeam();
    immutable long armedMs = sw.peek.total!"msecs";
    sw.reset();
    s.waitAtSeam();                       // no arm() in between
    immutable long disarmedMs = sw.peek.total!"msecs";
    sw.stop();

    assert(armedMs >= 30,
        "an armed seam must really pause (asked 40 ms, floor 30 for timer "
        ~ "granularity) — a stall that returns immediately widens no window");
    assert(disarmedMs < 20,
        "…and the SECOND call must not pause: one arm buys exactly one "
        ~ "pause, or the stall is level-triggered and every later frame in "
        ~ "the run pays for it");
    assert(!s.pending, "the seam disarms itself");
}
