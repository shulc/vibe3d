// SP1 (wave plan SP, task 9140): the GPU segment timer on a fake backend that
// enforces the GL nesting rule, plus the source census of its mark sites.
module tests.unit.gpu_pass_timer_test;

import gpu_pass_timer;

import std.algorithm : canFind, count;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.json : parseJSON, JSONType;
import std.path : buildPath, dirName;
import std.string : indexOf, strip;

import tests.unit.census_symbols : balancedSpan, blankNonCode, isIdentChar;

// [E1] the segment roster is a compile-time fence; an appending slice moves it
// together with its mark site (census below) and its suite cell.
static assert([__traits(allMembers, GpuSeg)] == [
    "setup", "imagePlanes", "grid", "backdropFaces", "faces", "backdropWire",
    "edges", "verts", "overlays"],
    "GpuSeg changed: move this pin, the census floor and the SP2 cells together");

private struct FakeLog {
    string[] calls;            // every backend call, in order
    bool open;                 // a query is open (TIME_ELAPSED cannot nest)
    bool probeOk = true;
    string probeReason = "fake: no timer";
    bool withheld;             // every query answers "not available"
    ulong ns = 1000;
    uint nextName;
    uint[] begun;
    bool[uint] unread;         // ended, never read back
    size_t resultCallsOnUnavailable;
    size_t rebeginsOfUnread;
    bool[uint] unavail;        // these names answer "not available"
    uint[] blockedNames;       // GL_QUERY_RESULT read while unavailable (blocks)
    uint blockUs;              // a blocking read takes this long (models the GPU wait)
}

private struct FakeBackend {
    FakeLog* log;
    bool probe(out string reason, out int bits) {
        log.calls ~= "probe";
        if (!log.probeOk) { reason = log.probeReason; return false; }
        bits = 64;
        return true;
    }
    void gen(uint[] names) {
        log.calls ~= "gen";
        foreach (ref n; names) n = ++log.nextName;
    }
    void begin(uint name) {
        assert(!log.open, "GL nesting rule: glBeginQuery while a TIME_ELAPSED query is open");
        log.calls ~= "begin";
        if (name in log.unread) ++log.rebeginsOfUnread;
        log.open = true;
        log.begun ~= name;
        log.unread[name] = true;
    }
    void end() {
        assert(log.open, "GL nesting rule: glEndQuery with no open query");
        log.calls ~= "end";
        log.open = false;
    }
    bool available(uint name) {
        log.calls ~= "avail";
        return !log.withheld && (name in log.unavail) is null;
    }
    ulong result(uint name) {
        log.calls ~= "result";
        if (log.withheld || (name in log.unavail) !is null) {
            ++log.resultCallsOnUnavailable;
            log.blockedNames ~= name;
            if (log.blockUs) {
                import core.thread : Thread;
                import core.time : usecs;
                Thread.sleep(log.blockUs.usecs);
            }
        }
        log.unread.remove(name);
        return log.ns;
    }
}

private alias FakeTimer = GpuPassTimerT!FakeBackend;

private FakeTimer* newTimer(FakeLog* log) {
    auto t = new FakeTimer;
    t.backend = FakeBackend(log);
    return t;
}

private string[] beginsAndEnds(const string[] calls) {
    string[] r;
    foreach (c; calls) if (c == "begin" || c == "end") r ~= c;
    return r;
}

// (a) partition: one frame of three segments is exactly 3 begin / 3 end,
// strictly alternating; the tags are [setup, grid, faces].
unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    t.beginFrame(true);
    t.mark(GpuSeg.grid);
    t.mark(GpuSeg.faces);
    t.endFrame();
    const be = beginsAndEnds(log.calls);
    assert(be.length == 6, format("(a) population floor: expected 6 begin/end calls, got %s", be));
    assert(be == ["begin", "end", "begin", "end", "begin", "end"],
        format("(a) begin/end must strictly alternate, got %s", be));
    t.beginFrame(true);            // harvests frame 1
    t.endFrame();
    assert(t.framesHarvested == 1, format("(a) harvested %d", t.framesHarvested));
    assert(log.calls.count("gen") == kGpuTimerFrames,
        format("(a) query names are generated once per ring row (%d), got %d gen calls",
               kGpuTimerFrames, log.calls.count("gen")));
    assert(t.segs[GpuSeg.setup].samples == 1 && t.segs[GpuSeg.grid].samples == 1
        && t.segs[GpuSeg.faces].samples == 1,
        "(a) tags must be [setup, grid, faces]");
    foreach (s; [GpuSeg.imagePlanes, GpuSeg.backdropFaces, GpuSeg.backdropWire,
                 GpuSeg.edges, GpuSeg.verts, GpuSeg.overlays])
        assert(t.segs[s].samples == 0, format("(a) %s has a sample it never marked", s));
}

// (b) absent vs present, in the same harvest.
unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    t.beginFrame(true);
    t.mark(GpuSeg.grid);
    t.endFrame();
    t.beginFrame(true);
    // positive control first [E5]: the timer harvested the grid this frame
    assert(t.segs[GpuSeg.grid].samples == 1, "(b) control: grid must have one sample");
    assert(t.segs[GpuSeg.faces].samples == 0,
        "(b) a section that did not run must read absent (samples 0)");
    log.ns = 4242;
    t.mark(GpuSeg.faces);
    t.endFrame();
    t.beginFrame(true);
    assert(t.segs[GpuSeg.faces].samples == 1 && t.segs[GpuSeg.faces].sumNs == 4242
        && t.segs[GpuSeg.faces].lastNs == 4242,
        format("(b) present faces: %s", t.segs[GpuSeg.faces]));
}

// (c) non-blocking harvest and the drop of a reused unavailable slot.
unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    log.withheld = true;
    foreach (_; 0 .. 3) { t.beginFrame(true); t.endFrame(); }
    t.beginFrame(true);
    assert(log.resultCallsOnUnavailable == 0,
        format("(c) GL_QUERY_RESULT read on an unavailable query %d times (that call blocks)",
               log.resultCallsOnUnavailable));
    assert(t.framesHarvested == 0, "(c) nothing is available yet");
    t.endFrame();
    log.withheld = false;
    t.beginFrame(true);
    t.endFrame();
    assert(t.framesHarvested == 4,
        format("(c) the frame availability flips harvests all 4 pending, got %d", t.framesHarvested));
    assert(t.framesDropped == 0, "(c) no slot was reused while pending");
    assert(t.maxHarvestLag == 4,
        format("(c) frame 1 harvested at frame 5: maxHarvestLag must be 4, got %d", t.maxHarvestLag));
}

unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    log.withheld = true;
    foreach (_; 0 .. kGpuTimerFrames) { t.beginFrame(true); t.endFrame(); }
    assert(log.rebeginsOfUnread == 0 && t.framesDropped == 0, "(c) ring not wrapped yet");
    t.beginFrame(true);            // reuses slot 0 while it is still unavailable
    t.endFrame();
    assert(log.resultCallsOnUnavailable == 0, "(c) no blocking read on the wrap");
    assert(t.framesDropped == 1,
        format("(c) the reused unavailable slot must be dropped, framesDropped=%d", t.framesDropped));
    assert(log.rebeginsOfUnread == 1,
        format("(c) exactly the dropped slot's one name is re-begun, got %d", log.rebeginsOfUnread));
}

// (c2) the oldest slot answers on the very frame it is reused: harvest runs
// BEFORE the reuse check, so it is read, not dropped.
unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    log.withheld = true;
    foreach (_; 0 .. kGpuTimerFrames) { t.beginFrame(true); t.endFrame(); }
    assert(t.framesHarvested == 0 && t.framesDropped == 0, "(c2) ring full, nothing read yet");
    log.withheld = false;
    t.beginFrame(true);            // reuses slot 0, which is now available
    t.endFrame();
    assert(t.framesDropped == 0,
        format("(c2) a slot available on its reuse frame must be harvested, not dropped: "
             ~ "framesDropped=%d", t.framesDropped));
    assert(t.framesHarvested == kGpuTimerFrames,
        format("(c2) all %d slots harvested, got %d", kGpuTimerFrames, t.framesHarvested));
}

// (c3) oldest first: slot k unavailable, slot k+1 available ⇒ k+1 waits.
unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    t.beginFrame(true); t.endFrame();          // frame 1: one query
    t.beginFrame(true); t.endFrame();          // frame 2 (harvests frame 1)
    assert(t.framesHarvested == 1 && log.begun.length == 2, "(c3) premise: frame 1 harvested");
    log.unavail[log.begun[1]] = true;          // frame 2 not answered
    t.beginFrame(true); t.endFrame();          // frame 3 ends, available
    t.beginFrame(true);                        // frame 2 pending+unavailable, frame 3 ready
    assert(t.framesHarvested == 1,
        format("(c3) frame 3 must not be harvested past the unavailable frame 2: "
             ~ "framesHarvested=%d", t.framesHarvested));
    t.endFrame();
    log.unavail.remove(log.begun[1]);
    t.beginFrame(true);
    auto r = parseJSON(t.toJson())["recent"].array;
    assert(t.framesHarvested == 4 && r.length == 4 && r[1].array[0].integer == 2
        && r[2].array[0].integer == 3,
        format("(c3) control: once frame 2 answers, frames 2,3,4 follow in order: %s", r));
}

// (k) perf mode (`waitWhenFull`): a FULL ring blocks on the oldest slot's
// queries only — no drop, no re-begin of an unread name; gate mode never blocks.
unittest {
    foreach (perf; [false, true]) {
        auto log = new FakeLog;
        auto t = newTimer(log);
        log.withheld = true;
        log.blockUs = 500;
        foreach (_; 0 .. kGpuTimerFrames) {
            t.beginFrame(true, perf); t.mark(GpuSeg.faces); t.endFrame();
        }
        assert(log.resultCallsOnUnavailable == 0 && t.throttleWaits == 0,
            format("(k perf=%s) a ring that is not full never blocks", perf));
        assert(log.begun.length == 2 * kGpuTimerFrames, "(k) population floor: 2 queries per frame");
        foreach (_; 0 .. 3) { t.beginFrame(true, perf); t.mark(GpuSeg.faces); t.endFrame(); }
        if (!perf) {
            assert(log.resultCallsOnUnavailable == 0 && t.throttleWaits == 0 && t.throttleNs == 0,
                format("(k gate) gate mode must never block: %d blocking reads, %d waits",
                       log.resultCallsOnUnavailable, t.throttleWaits));
            assert(t.framesDropped == 3, format("(k gate) 3 reused slots dropped, got %d", t.framesDropped));
            continue;
        }
        assert(t.framesDropped == 0 && log.rebeginsOfUnread == 0,
            format("(k perf) a full ring must wait, not drop: dropped=%d rebegins=%d",
                   t.framesDropped, log.rebeginsOfUnread));
        assert(log.blockedNames == log.begun[0 .. 6],
            format("(k perf) the blocking reads must be exactly frames 1..3's queries (the "
                 ~ "oldest slot each time), got %s", log.blockedNames));
        assert(t.throttleWaits == 3 && t.framesHarvested == 3 && t.maxHarvestLag == kGpuTimerFrames,
            format("(k perf) waits=%d harvested=%d lag=%d", t.throttleWaits, t.framesHarvested,
                   t.maxHarvestLag));
        assert(t.throttleNs >= 6 * 500_000,
            format("(k perf) throttleNs must hold the 6 blocking reads' time (>= 3 ms), got %d ns",
                   t.throttleNs));
        auto j = parseJSON(t.toJson());
        assert(j["throttleWaits"].integer == 3 && j["throttleNs"].integer == t.throttleNs
            && j["oldestPendingAge"].integer == kGpuTimerFrames - 1,
            "(k perf) JSON throttle columns and the oldest pending age: " ~ t.toJson());
    }
}

// (d) the kernel cap on queries per frame.
unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    t.beginFrame(true);                              // segment 1 (setup)
    foreach (_; 0 .. MAX_GPU_MARKS + 4) t.mark(GpuSeg.edges);   // segments 2 .. MAX+5
    t.endFrame();
    const begins = log.calls.count("begin");
    assert(begins == MAX_GPU_MARKS,
        format("(d) begin count must stop at MAX_GPU_MARKS=%d, got %d", MAX_GPU_MARKS, begins));
    assert(t.overflowMarks == 5, format("(d) overflowMarks=%d, expected 5", t.overflowMarks));
    assert(!log.open, "(d) endFrame closes the last query");
}

// (e) disarmed costs zero backend calls; an unavailable probe likewise after it.
unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    foreach (_; 0 .. 5) { t.beginFrame(false); t.mark(GpuSeg.faces); t.endFrame(); }
    assert(log.calls.length == 0, format("(e) disarmed made backend calls: %s", log.calls));
    assert(t.toJson().indexOf(`"armed":false`) >= 0, "(e) JSON reports armed:false");
}

unittest {
    auto log = new FakeLog;
    log.probeOk = false;
    auto t = newTimer(log);
    foreach (_; 0 .. 5) { t.beginFrame(true); t.mark(GpuSeg.faces); t.endFrame(); }
    assert(log.calls == ["probe"], format("(e) unavailable: only the probe may call, got %s", log.calls));
    auto j = parseJSON(t.toJson());
    assert(j["available"].type == JSONType.FALSE && j["reason"].str == "fake: no timer",
        "(e) JSON must say available:false with the reason: " ~ t.toJson());
}

// (f) the arm rule, full truth table.
unittest {
    foreach (tm; [false, true]) {
        assert(resolveGpuTimingArmed(tm, "1") == true,  "(f) env 1 arms");
        assert(resolveGpuTimingArmed(tm, "0") == false, "(f) env 0 disarms");
        assert(resolveGpuTimingArmed(tm, "") == tm,     "(f) unset follows --test");
        assert(resolveGpuTimingArmed(tm, "yes") == tm,  "(f) other follows --test");
    }
}

// (g) JSON: every GpuSeg key is present, absent ones included.
unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    t.beginFrame(true); t.mark(GpuSeg.grid); t.endFrame();
    t.beginFrame(true); t.endFrame();
    auto j = parseJSON(t.toJson());
    auto segs = j["segments"];
    size_t n;
    static foreach (m; __traits(allMembers, GpuSeg)) {
        assert(m in segs.object, "(g) segment key missing from JSON: " ~ m);
        ++n;
    }
    assert(n == 9 && segs.object.length == 9, format("(g) %d keys", segs.object.length));
    assert(segs["faces"]["samples"].integer == 0 && segs["grid"]["samples"].integer == 1,
        "(g) absent faces = samples 0, grid = 1: " ~ t.toJson());
    assert(j["recent"].array.length == 1 && j["framesHarvested"].integer == 1,
        "(g) recent carries one [seq,ns] per harvested frame");
}

// (g2) the `recent` ring keeps the newest kGpuRecentFrames frames, in order.
unittest {
    auto log = new FakeLog;
    auto t = newTimer(log);
    foreach (_; 0 .. 300) { t.beginFrame(true); t.endFrame(); }
    t.beginFrame(true);            // harvests frame 300
    auto r = parseJSON(t.toJson())["recent"].array;
    assert(r.length == kGpuRecentFrames,
        format("(g2) recent holds %d entries, expected %d", r.length, kGpuRecentFrames));
    assert(r[0].array[0].integer == 300 - kGpuRecentFrames + 1 && r[$ - 1].array[0].integer == 300,
        format("(g2) recent must run seq %d..300 oldest first, got %s..%s",
               300 - kGpuRecentFrames + 1, r[0], r[$ - 1]));
}

// (j) the GL backend's probe, GL-free: each missing entry point and a zero-bit
// counter answer unavailable with a reason naming it (bindbc's pointers are
// swapped for the cell and restored).
version (web) {} else
unittest {
    import bindbc.opengl;
    static extern (System) void fakeGen(GLsizei, GLuint*) nothrow @nogc {}
    static extern (System) void fakeBegin(GLenum, GLuint) nothrow @nogc {}
    static extern (System) void fakeEnd(GLenum) nothrow @nogc {}
    static extern (System) void fakeObjI(GLuint, GLenum, GLint*) nothrow @nogc {}
    static extern (System) void fakeObjU64(GLuint, GLenum, GLuint64*) nothrow @nogc {}
    static __gshared GLint fakeBits;
    static extern (System) void fakeQueryiv(GLenum target, GLenum pname, GLint* p) nothrow @nogc {
        *p = (target == GL_TIME_ELAPSED && pname == GL_QUERY_COUNTER_BITS) ? fakeBits : -1;
    }
    auto sGen = glGenQueries, sBegin = glBeginQuery, sEnd = glEndQuery,
         sObjI = glGetQueryObjectiv, sObjU = glGetQueryObjectui64v, sQiv = glGetQueryiv;
    scope (exit) {
        glGenQueries = sGen; glBeginQuery = sBegin; glEndQuery = sEnd;
        glGetQueryObjectiv = sObjI; glGetQueryObjectui64v = sObjU; glGetQueryiv = sQiv;
    }
    void installAll() {
        glGenQueries = &fakeGen; glBeginQuery = &fakeBegin; glEndQuery = &fakeEnd;
        glGetQueryObjectiv = &fakeObjI; glGetQueryObjectui64v = &fakeObjU64;
        glGetQueryiv = &fakeQueryiv;
    }
    string probeReason(out bool ok, out int bits) {
        GlTimerBackend b;
        string reason;
        ok = b.probe(reason, bits);
        return reason;
    }
    bool ok; int bits;
    installAll(); fakeBits = 64;
    assert(probeReason(ok, bits) == "" && ok && bits == 64,
        "(j) positive control: all six entry points and 64 counter bits must probe available");
    static foreach (name; ["glGenQueries", "glBeginQuery", "glEndQuery", "glGetQueryObjectiv",
                           "glGetQueryObjectui64v", "glGetQueryiv"]) {{
        installAll();
        mixin(name ~ " = null;");
        immutable r = probeReason(ok, bits);
        assert(!ok && r == name ~ " is null",
            "(j) a missing " ~ name ~ " must answer unavailable naming it, got '" ~ r ~ "'");
    }}
    installAll(); fakeBits = 0;
    immutable r0 = probeReason(ok, bits);
    assert(!ok && bits == 0 && r0.indexOf("GL_QUERY_COUNTER_BITS is 0") >= 0,
        "(j) a zero-bit TIME_ELAPSED counter must answer unavailable, got '" ~ r0 ~ "'");
}

// (h) census: every segment but `setup` (opened by beginFrame) has a mark
// site; `beginFrame(` occurs once in ViewportSceneRenderer.draw, followed by
// `scope (exit)` that calls `endFrame(`.
private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    size_t[string] sites;
    size_t files;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++files;
        const code = blankNonCode(readText(entry.name));
        enum needle = ".mark(GpuSeg.";
        for (ptrdiff_t p = code.indexOf(needle); p >= 0;
             p = code.indexOf(needle, p + needle.length)) {
            size_t e = p + needle.length;
            while (e < code.length && isIdentChar(code[e])) ++e;
            sites[code[p + needle.length .. e]] += 1;
        }
    }
    assert(files > 400, format("(h) census area: only %d source files scanned", files));
    size_t total;
    foreach (k, v; sites) total += v;
    assert(total == 18, format("(h) measured mark-site count: %d (grep -o '.mark(GpuSeg.' = 18)", total));
    static foreach (m; __traits(allMembers, GpuSeg)) {
        static if (m != "setup")
            assert((m in sites) !is null,
                "(h) GpuSeg." ~ m ~ " has no .mark(GpuSeg." ~ m ~ ") site: "
                ~ "a segment that is never marked always reads absent");
    }
    assert(("setup" in sites) is null, "(h) setup is opened by beginFrame, never marked");

    const code = blankNonCode(readText(buildPath(repoRoot, "source", "ui", "viewport_render.d")));
    const at = code.indexOf("void draw(SceneInputs");
    assert(at >= 0, "(h) ViewportSceneRenderer.draw not found");
    const body_ = balancedSpan(code, code.indexOf('{', at), '{', '}');
    assert(body_.length > 1000, "(h) draw body not captured");
    assert(body_.count("beginFrame(") == 1,
        format("(h) beginFrame( must occur once in draw, got %d", body_.count("beginFrame(")));
    // The wait flag is the perf flag: draw passes it, and the one write of it
    // in source/ sits in app.d's `--perf` argument arm (never `--test`).
    assert(body_.count("beginFrame(gpuTimingArmed_, g_gpuTimerPerfMode)") == 1,
        "(h) draw must pass g_gpuTimerPerfMode as beginFrame's waitWhenFull");
    size_t writes;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth))
        writes += blankNonCode(readText(entry.name)).count("g_gpuTimerPerfMode = ");
    const app = readText(buildPath(repoRoot, "source", "app.d"));   // raw: the arm key is a string literal
    const perfArm = app.indexOf(`args[i] == "--perf")`);
    assert(perfArm >= 0, "(h) app.d --perf argument arm not found");
    const armEnd = app.indexOf("} else if", perfArm);
    assert(writes == 1 && app[perfArm .. armEnd].count("g_gpuTimerPerfMode = true") == 1,
        format("(h) g_gpuTimerPerfMode must be written once, in the --perf arm (writes=%d)", writes));
    const b = body_.indexOf("beginFrame(");
    const semi = body_.indexOf(';', b);
    const next = body_[semi + 1 .. $].strip;
    assert(next.length > 14 && next[0 .. 12] == "scope (exit)",
        "(h) the statement after beginFrame must be scope (exit): " ~ next[0 .. $ < 40 ? $ : 40]);
    const stmtEnd = balancedSpan(next, next.indexOf('{'), '{', '}');
    assert(stmtEnd.indexOf("endFrame(") >= 0,
        "(h) the scope (exit) after beginFrame must call endFrame(: every return path closes the last query");
}
