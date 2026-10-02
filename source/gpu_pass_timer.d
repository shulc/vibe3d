// GPU time per frame SECTION of one viewport cell (model M7 "pass cost",
// wave plan SP, task 9140). The cell's draw is PARTITIONED into segments:
// `beginFrame` opens `setup`, every `mark(GpuSeg)` closes the open
// GL_TIME_ELAPSED query and opens the next, `endFrame` closes the last.
// TIME_ELAPSED queries cannot nest, which the partition makes legal. A mark
// sits INSIDE the branch that issues its section's draws, so a section that
// did not run reports `samples:0` ("absent"), never a fabricated 0 ns.
// Results are harvested NON-BLOCKINGLY: `GL_QUERY_RESULT` is read only after
// every query of a frame slot answers `GL_QUERY_RESULT_AVAILABLE`; a slot that
// is about to be reused while still unavailable is dropped and counted.
// Counters are cumulative for the process; a reader takes deltas.
// Query names live for the process: the cells are pre-allocated and never
// freed, and no GL call may run from a destructor (no context there).
module gpu_pass_timer;

/// One frame section of `ViewportSceneRenderer.draw`. Appending slices add a
/// member AND its mark site (the census in `tests/unit/gpu_pass_timer_test.d`
/// fails on a member that is never marked).
enum GpuSeg : ubyte {
    setup, imagePlanes, grid, backdropFaces, faces, backdropWire, edges,
    verts, overlays,
}

/// Frame slots in flight per cell, chosen by the P0 measurement (task 9140
/// card): steady harvest lag 1-2 frames on both gate hosts, but 15 frames in
/// the transient after a 1 M-face scene load on an LDC perf build (an 8-slot
/// ring dropped 162 frames there); 32 is twice the worst measured lag.
enum size_t kGpuTimerFrames = 32;
/// Kernel cap on queries (segments) per frame slot; no Param scales it.
enum size_t MAX_GPU_MARKS = 64;
/// Entries of the per-frame total ring reported as `recent`.
enum size_t kGpuRecentFrames = 256;

/// Arm rule: env "1" arms, "0" disarms, anything else follows `--test`.
bool resolveGpuTimingArmed(bool testMode, string env) pure nothrow @safe @nogc {
    if (env == "1") return true;
    if (env == "0") return false;
    return testMode;
}

struct GpuSegStat {
    ulong samples;
    ulong sumNs;
    ulong lastNs;
}

/// The production backend: GL 3.3 core timer queries. Under `version (web)`
/// the probe answers unavailable with ZERO GL calls.
struct GlTimerBackend {
    bool probe(out string reason, out int bits) {
        version (web) {
            reason = "web build";
            return false;
        } else {
            import bindbc.opengl;
            if (glGenQueries is null)          { reason = "glGenQueries is null"; return false; }
            if (glBeginQuery is null)          { reason = "glBeginQuery is null"; return false; }
            if (glEndQuery is null)            { reason = "glEndQuery is null"; return false; }
            if (glGetQueryObjectiv is null)    { reason = "glGetQueryObjectiv is null"; return false; }
            if (glGetQueryObjectui64v is null) { reason = "glGetQueryObjectui64v is null"; return false; }
            if (glGetQueryiv is null)          { reason = "glGetQueryiv is null"; return false; }
            GLint b = 0;
            glGetQueryiv(GL_TIME_ELAPSED, GL_QUERY_COUNTER_BITS, &b);
            bits = b;
            if (b <= 0) { reason = "GL_QUERY_COUNTER_BITS is 0 for GL_TIME_ELAPSED"; return false; }
            return true;
        }
    }
    void gen(uint[] names) {
        version (web) {} else {
            import bindbc.opengl;
            glGenQueries(cast(GLsizei) names.length, names.ptr);
        }
    }
    void begin(uint name) {
        version (web) {} else {
            import bindbc.opengl;
            glBeginQuery(GL_TIME_ELAPSED, name);
        }
    }
    void end() {
        version (web) {} else {
            import bindbc.opengl;
            glEndQuery(GL_TIME_ELAPSED);
        }
    }
    bool available(uint name) {
        version (web) { return false; } else {
            import bindbc.opengl;
            GLint a = 0;
            glGetQueryObjectiv(name, GL_QUERY_RESULT_AVAILABLE, &a);
            return a != 0;
        }
    }
    ulong result(uint name) {
        version (web) { return 0; } else {
            import bindbc.opengl;
            GLuint64 ns = 0;
            glGetQueryObjectui64v(name, GL_QUERY_RESULT, &ns);
            return ns;
        }
    }
}

struct GpuPassTimerT(Backend) {
    Backend backend;

    bool armed;
    bool probed;
    bool available;
    string reason;
    int bits;
    ulong framesHarvested;
    ulong framesDropped;
    ulong overflowMarks;
    /// Largest observed distance, in this cell's frames, between a slot's
    /// frame and the frame that harvested it (the ring-depth witness).
    ulong maxHarvestLag;
    GpuSegStat[GpuSeg.max + 1] segs;

    private {
        bool namesMade_;
        uint[MAX_GPU_MARKS][kGpuTimerFrames] names_;
        GpuSeg[MAX_GPU_MARKS][kGpuTimerFrames] tags_;
        size_t[kGpuTimerFrames] used_;
        bool[kGpuTimerFrames] pending_;
        ulong[kGpuTimerFrames] slotSeq_;
        size_t cur_;
        size_t next_;
        bool inFrame_;
        ulong seq_;
        ulong[2][kGpuRecentFrames] recent_;
        size_t recentLen_;
        size_t recentHead_;
    }

    /// Open frame `seq+1` (segment `setup`) after harvesting what is ready.
    void beginFrame(bool armed_) {
        armed = armed_;
        if (!armed_) return;
        if (!probed) {
            probed = true;
            available = backend.probe(reason, bits);
        }
        if (!available) return;
        if (!namesMade_) {
            namesMade_ = true;
            foreach (ref row; names_) backend.gen(row[]);
        }
        ++seq_;
        harvest();
        // The slot about to be reused: still unavailable ⇒ dropped, never read.
        if (pending_[next_]) {
            pending_[next_] = false;
            ++framesDropped;
        }
        cur_ = next_;
        used_[cur_] = 0;
        slotSeq_[cur_] = seq_;
        inFrame_ = true;
        open(GpuSeg.setup);
    }

    /// End the open segment and begin one tagged `seg`.
    void mark(GpuSeg seg) {
        if (!inFrame_) return;
        if (used_[cur_] >= MAX_GPU_MARKS) {
            ++overflowMarks;
            return;
        }
        backend.end();
        open(seg);
    }

    void endFrame() {
        if (!inFrame_) return;
        backend.end();
        pending_[cur_] = true;
        next_ = (cur_ + 1) % kGpuTimerFrames;
        inFrame_ = false;
    }

    private void open(GpuSeg seg) {
        immutable size_t i = used_[cur_]++;
        tags_[cur_][i] = seg;
        backend.begin(names_[cur_][i]);
    }

    private void harvest() {
        foreach (k; 0 .. kGpuTimerFrames) {
            immutable size_t s = (next_ + k) % kGpuTimerFrames;
            if (!pending_[s]) continue;
            foreach (i; 0 .. used_[s])
                if (!backend.available(names_[s][i])) return;   // oldest first
            ulong total = 0;
            foreach (i; 0 .. used_[s]) {
                immutable ulong ns = backend.result(names_[s][i]);
                auto st = &segs[tags_[s][i]];
                ++st.samples;
                st.sumNs += ns;
                st.lastNs = ns;
                total += ns;
            }
            pending_[s] = false;
            ++framesHarvested;
            immutable ulong lag = seq_ - slotSeq_[s];
            if (lag > maxHarvestLag) maxHarvestLag = lag;
            recent_[recentHead_] = [slotSeq_[s], total];
            recentHead_ = (recentHead_ + 1) % kGpuRecentFrames;
            if (recentLen_ < kGpuRecentFrames) ++recentLen_;
        }
    }

    /// The per-cell dump of `/api/viewport/display` (`"gpuTiming"`): every
    /// `GpuSeg` member key is always present; absent = `samples:0`.
    string toJson() const {
        import std.array : appender;
        import std.format : formattedWrite;
        import std.conv : to;
        auto w = appender!string();
        w.formattedWrite(`{"armed":%s,"available":%s,"reason":"%s","bits":%d,`
            ~ `"framesHarvested":%d,"framesDropped":%d,"overflowMarks":%d,`
            ~ `"maxHarvestLag":%d,"ringFrames":%d,"segments":{`,
            armed, available, reason, bits, framesHarvested, framesDropped,
            overflowMarks, maxHarvestLag, kGpuTimerFrames);
        foreach (i, st; segs) {
            if (i) w.put(',');
            w.formattedWrite(`"%s":{"samples":%d,"sumNs":%d,"lastNs":%d}`,
                (cast(GpuSeg) i).to!string, st.samples, st.sumNs, st.lastNs);
        }
        w.put(`},"recent":[`);
        immutable size_t first =
            (recentHead_ + kGpuRecentFrames - recentLen_) % kGpuRecentFrames;
        foreach (k; 0 .. recentLen_) {
            if (k) w.put(',');
            const e = recent_[(first + k) % kGpuRecentFrames];
            w.formattedWrite(`[%d,%d]`, e[0], e[1]);
        }
        w.put("]}");
        return w.data;
    }
}

alias GpuPassTimer = GpuPassTimerT!GlTimerBackend;
