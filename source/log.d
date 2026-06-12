// Leaf logging service: named-subsystem diagnostics with severity, a rolling
// in-memory ring buffer, listener subscription, and a built-in stderr echo
// sink. Deliberately a LEAF module — it imports only `std` + `core.sync.mutex`
// and NOTHING from the project, so render-side code may import it under the
// one-way render→modeling-only dependency rule.
//
// Concepts mirror a conventional subsystem log: a subsystem tag, a severity
// level, a per-entry listener notification, and a rolling buffer that a future
// "Event Log" UI panel can poll. Flat function API — no objects to register.
//
// Threading: the ring buffer and the once-gate seen-set are guarded by a
// `Mutex` because `http_server` logs from its background thread. Listeners are
// invoked on the CALLING thread, AFTER the mutex is released (the entry is
// copied out first), so a subscriber must either be thread-safe or prefer
// `snapshot()` polling. This module must NEVER log (no reentrancy) and never
// invoke listeners while holding the lock.
module log;

import std.stdio : stderr;
import core.time : MonoTime;
import core.sync.mutex : Mutex;

/// Severity of a log entry. `Info` is the default floor for the stderr sink.
enum LogLevel { Info, Warn, Error }

/// One log record. `time` is captured at emit; `subsystem` is the short tag
/// (e.g. "io", "http"); `msg` is the human-readable text WITHOUT the `[tag] `
/// prefix (the stderr sink adds that).
struct LogEntry {
    MonoTime time;
    LogLevel level;
    string   subsystem;
    string   msg;
}

// ---------------------------------------------------------------------------
// Internal state. All access is serialized through `g_logMutex`, except the
// stderr echo (done after the lock is released) and the listener fan-out.
// ---------------------------------------------------------------------------

private enum size_t kRingCapacity = 1024;

private __gshared LogEntry[kRingCapacity] g_ring;
private __gshared size_t g_ringCount; // total entries ever written (monotonic)
private __gshared Mutex  g_logMutex;
private __gshared bool[string] g_seenOnce;
private __gshared void delegate(ref const(LogEntry))[] g_listeners;

/// Minimum level the built-in stderr echo sink prints. Defaults to `Info`
/// (everything). Raise it (e.g. in `--test`) if Info chatter ever spams test
/// stderr — not needed today since the migration adds no new sites.
__gshared LogLevel g_stderrMinLevel = LogLevel.Info;

// Lazily construct the mutex on first use so the module needs no explicit
// init call from the app. `Mutex` construction is itself thread-safe enough
// for our single-process startup (the first log generally happens on the main
// thread before the http thread spins up); the double-checked guard below is
// belt-and-braces.
private __gshared bool g_mutexReady;
private Mutex logMutex() @trusted nothrow {
    if (!g_mutexReady) {
        synchronized {
            if (!g_mutexReady) {
                g_logMutex = new Mutex();
                g_mutexReady = true;
            }
        }
    }
    return g_logMutex;
}

// ---------------------------------------------------------------------------
// Public emit API
// ---------------------------------------------------------------------------

/// Log an informational status line.
void logInfo(string subsystem, string msg)  @trusted nothrow { emit(LogLevel.Info,  subsystem, msg); }
/// Log a non-fatal diagnostic / warning.
void logWarn(string subsystem, string msg)  @trusted nothrow { emit(LogLevel.Warn,  subsystem, msg); }
/// Log a fatal / error condition (load aborts, GL/backend init failures).
void logError(string subsystem, string msg) @trusted nothrow { emit(LogLevel.Error, subsystem, msg); }

/// Log a warning the first time a given `(subsystem, key)` pair is seen; later
/// calls with the same key are silently dropped. Replaces an ad-hoc
/// `bool[string]` once-gate. Always emits at `Warn`.
void logWarnOnce(string subsystem, string key, string msg) @trusted nothrow {
    auto m = logMutex();
    bool firstTime;
    try {
        m.lock();
        scope(exit) m.unlock();
        if (key in g_seenOnce) return;
        g_seenOnce[key] = true;
        firstTime = true;
    } catch (Exception) {
        // Mutex failures are not actionable; fall through without the gate.
        firstTime = true;
    }
    if (firstTime) emit(LogLevel.Warn, subsystem, msg);
}

/// Return an ordered (oldest→newest) copy of the ring buffer contents. Safe to
/// call from any thread; the future Event Log panel polls this on the main
/// thread.
LogEntry[] snapshot() @trusted nothrow {
    auto m = logMutex();
    try {
        m.lock();
        scope(exit) m.unlock();
        return snapshotLocked();
    } catch (Exception) {
        return null;
    }
}

// ---------------------------------------------------------------------------
// Listener registration
// ---------------------------------------------------------------------------

/// Subscribe to per-entry notifications. The delegate is invoked on the
/// thread that emitted the entry, after the lock is released.
void addLogListener(void delegate(ref const(LogEntry)) listener) @trusted nothrow {
    auto m = logMutex();
    try {
        m.lock();
        scope(exit) m.unlock();
        g_listeners ~= listener;
    } catch (Exception) {}
}

/// Remove a previously registered listener (by identity). No-op if absent.
void removeLogListener(void delegate(ref const(LogEntry)) listener) @trusted nothrow {
    auto m = logMutex();
    try {
        m.lock();
        scope(exit) m.unlock();
        foreach (i, l; g_listeners) {
            if (l is listener) {
                g_listeners = g_listeners[0 .. i] ~ g_listeners[i + 1 .. $];
                break;
            }
        }
    } catch (Exception) {}
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

private void emit(LogLevel level, string subsystem, string msg) @trusted nothrow {
    LogEntry e;
    e.level     = level;
    e.subsystem = subsystem;
    e.msg       = msg;
    try { e.time = MonoTime.currTime; } catch (Exception) {}

    // Append under the lock; copy out listeners + the entry so the fan-out and
    // the stderr echo happen WITHOUT the lock held.
    void delegate(ref const(LogEntry))[] listenersCopy;
    auto m = logMutex();
    try {
        m.lock();
        scope(exit) m.unlock();
        g_ring[g_ringCount % kRingCapacity] = e;
        g_ringCount++;
        listenersCopy = g_listeners.dup;
    } catch (Exception) {}

    // stderr echo sink — preserve today's `[tag] msg` shape byte-for-byte.
    if (level >= g_stderrMinLevel) {
        try {
            stderr.writeln("[", subsystem, "] ", msg);
            stderr.flush();
        } catch (Exception) {}
    }

    // Notify listeners on the calling thread, lock released.
    foreach (l; listenersCopy) {
        try { l(e); } catch (Exception) {}
    }
}

// Caller must hold the lock.
private LogEntry[] snapshotLocked() @trusted nothrow {
    if (g_ringCount == 0) return null;
    const n = g_ringCount < kRingCapacity ? g_ringCount : kRingCapacity;
    auto outBuf = new LogEntry[n];
    if (g_ringCount <= kRingCapacity) {
        // No wrap yet: entries 0 .. n-1 are in order.
        foreach (i; 0 .. n) outBuf[i] = g_ring[i];
    } else {
        // Wrapped: oldest entry is at (count % cap).
        const start = g_ringCount % kRingCapacity;
        foreach (i; 0 .. n) outBuf[i] = g_ring[(start + i) % kRingCapacity];
    }
    return outBuf;
}

// ---------------------------------------------------------------------------
// Unit tests. These exercise the __gshared ring, so each test resets the
// shared state up-front to avoid cross-unittest bleed. `g_stderrMinLevel` is
// raised to silence the echo during tests (and restored). Samples are fully
// self-contained.
// ---------------------------------------------------------------------------

version (unittest) {
    // Test-only hard reset of the shared state. Acquires the lock so it is safe
    // even though tests run single-threaded.
    private void resetLogForTest() @trusted {
        auto m = logMutex();
        m.lock();
        scope(exit) m.unlock();
        g_ringCount = 0;
        g_seenOnce  = null;
        g_listeners = null;
        foreach (ref e; g_ring) e = LogEntry.init;
    }
}

// snapshot() returns appended entries in order, and is empty before any log.
unittest {
    auto saved = g_stderrMinLevel;
    g_stderrMinLevel = LogLevel.Error; // silence Info/Warn echo
    scope(exit) g_stderrMinLevel = saved;
    resetLogForTest();

    assert(snapshot() is null, "fresh ring must be empty");

    logWarn("t", "first");
    logWarn("t", "second");
    logWarn("t", "third");

    auto snap = snapshot();
    assert(snap.length == 3);
    assert(snap[0].msg == "first");
    assert(snap[1].msg == "second");
    assert(snap[2].msg == "third");
    assert(snap[0].subsystem == "t");
    assert(snap[0].level == LogLevel.Warn);
}

// Ring wrap-around: after writing capacity+extra entries, snapshot holds only
// the last `kRingCapacity` in oldest→newest order.
unittest {
    auto saved = g_stderrMinLevel;
    g_stderrMinLevel = LogLevel.Error;
    scope(exit) g_stderrMinLevel = saved;
    resetLogForTest();

    import std.conv : to;
    enum extra = 5;
    foreach (i; 0 .. kRingCapacity + extra) logWarn("t", i.to!string);

    auto snap = snapshot();
    assert(snap.length == kRingCapacity);
    // Oldest surviving entry is index `extra`; newest is capacity+extra-1.
    assert(snap[0].msg == extra.to!string);
    assert(snap[$ - 1].msg == (kRingCapacity + extra - 1).to!string);
    // Interior order is preserved.
    assert(snap[1].msg == (extra + 1).to!string);
}

// A registered listener receives the emitted entry; a removed one does not.
unittest {
    auto saved = g_stderrMinLevel;
    g_stderrMinLevel = LogLevel.Error;
    scope(exit) g_stderrMinLevel = saved;
    resetLogForTest();

    LogEntry[] got;
    void sink(ref const(LogEntry) e) { got ~= e; }

    addLogListener(&sink);
    logError("sub", "boom");
    assert(got.length == 1);
    assert(got[0].msg == "boom");
    assert(got[0].subsystem == "sub");
    assert(got[0].level == LogLevel.Error);

    removeLogListener(&sink);
    logError("sub", "again");
    assert(got.length == 1, "removed listener must not fire");
}

// logWarnOnce fires exactly once per key, but distinct keys each fire.
unittest {
    auto saved = g_stderrMinLevel;
    g_stderrMinLevel = LogLevel.Error;
    scope(exit) g_stderrMinLevel = saved;
    resetLogForTest();

    logWarnOnce("forms", "stageA", "broke A");
    logWarnOnce("forms", "stageA", "broke A again");
    logWarnOnce("forms", "stageB", "broke B");

    auto snap = snapshot();
    assert(snap.length == 2, "stageA logged once, stageB once");
    assert(snap[0].msg == "broke A");
    assert(snap[1].msg == "broke B");
}
