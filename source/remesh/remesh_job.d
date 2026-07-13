module remesh.remesh_job;

// ---------------------------------------------------------------------------
// RemeshJob — a crash-isolated, per-frame-polled quad-remesh job.
//
// Runs the external `autoremesher_cli` helper (D-AutoRemesher, built and
// maintained separately — this module never links it, only spawns it) as a
// SUBPROCESS, never a worker thread: the helper's geogram backend can call
// abort() on non-manifold/degenerate input, and only process-level
// isolation survives that (a thread sharing our address space would take
// the whole vibe3d process down with it). UI responsiveness comes from
// non-blocking per-frame polling — app.d calls poll() once per frame; it
// never blocks. Marshalling is via temp OBJ files: the multi-second remesh
// cost dwarfs the file I/O overhead.
//
// Lifecycle mirrors ai3d.job_controller's shape (start / poll~drain /
// cancel) but is simpler: no HTTP, no worker thread — the "worker" is the
// OS process itself, and "drain" is a single per-frame tryWait() poll
// instead of an event queue.
// ---------------------------------------------------------------------------

import std.array   : split;
import std.conv    : to;
import std.file    : exists, tempDir, mkdirRecurse, rmdirRecurse, readText, thisExePath;
import std.path    : buildPath, expandTilde, dirName;
import std.process : Pid, spawnProcess, tryWait, kill, wait, environment, thisProcessID;
import std.stdio   : File, stdin;
import std.string  : strip;
import core.time   : MonoTime;

import mesh : Mesh;
import math : Vec3;

/// User-facing remesh parameters, mapped 1:1 onto autoremesher_cli's flags.
/// Values are hints only — `start()` is the kernel boundary that actually
/// clamps them (see MAX_REMESH_TARGET_QUADS below) before they ever reach
/// the subprocess, regardless of whether they arrived via the UI modal
/// (already `.min()/.max()`-hinted) or a headless `mesh.remesh.start`
/// argstring (which bypasses UI hints entirely).
struct RemeshParams {
    int    targetQuads = 6000;
    double adaptivity  = 1.0;
    double sharpEdge   = 90.0;
}

/// Kernel-side hard cap on target-quad count — independent of any UI Param
/// hint, since `.min()/.max()` on a Param is a UI-only affordance and does
/// NOT clamp a headless/argstring-driven call. Same order of magnitude as
/// `Ai3dMaxTotalFaces` (ai3d/scene_validator.d) — another face-count-shaped
/// budget for an external-tool-bound operation.
enum int MAX_REMESH_TARGET_QUADS = 500_000;
enum int MIN_REMESH_TARGET_QUADS = 4;

/// Drives one quad-remesh job end to end: start() spawns the helper
/// subprocess; poll() must be called once per frame (never blocks); state()
/// reports idle/running/succeeded/failed. On success, resultVertices()/
/// resultFaces() hold the parsed output mesh until clear() is called.
final class RemeshJob {
    enum State { idle, running, succeeded, failed }

    private State  state_ = State.idle;
    private string message_;
    private Pid    pid_;
    private bool   hasPid_;
    private string workDir_;
    private string outPath_;
    private string logPath_;
    private File   logFile_;
    private Vec3[]   resultVertices_;
    private uint[][] resultFaces_;

    State  state() const { return state_; }
    string message() const { return message_; }
    bool   busy() const { return state_ == State.running; }

    const(Vec3)[]   resultVertices() const { return resultVertices_; }
    const(uint[])[] resultFaces() const { return resultFaces_; }

    /// Reset to idle and drop the last result. Called by the consumer once
    /// it has read (and cached, if it needs the data to survive past this
    /// call) resultVertices()/resultFaces().
    void clear() {
        state_   = State.idle;
        message_ = null;
        resultVertices_ = null;
        resultFaces_    = null;
    }

    /// Spawn the helper against `mesh`. No-op if a job is already running
    /// (single-in-flight, mirroring Ai3dJobController.start()). `p` is
    /// clamped/sanitized HERE — the kernel boundary — before it ever reaches
    /// the subprocess args, regardless of what a caller (UI modal, HTTP
    /// argstring) passed in.
    void start(const ref Mesh mesh, RemeshParams rawParams) {
        if (state_ == State.running) return;

        const p = sanitizeParams(rawParams);
        const targetQuads = p.targetQuads;
        const adaptivity  = p.adaptivity;
        const sharpEdge   = p.sharpEdge;

        auto bin = locateHelper();
        if (bin is null) {
            state_   = State.failed;
            message_ = "remesher not found (set VIBE3D_AUTOREMESHER_BIN or "
                     ~ "build ~/Code/D-AutoRemesher)";
            return;
        }

        string dir;
        try {
            dir = buildPath(tempDir(),
                "vibe3d_remesh_" ~ thisProcessID.to!string ~ "_"
                ~ MonoTime.currTime.ticks.to!string);
            mkdirRecurse(dir);
        } catch (Exception e) {
            state_   = State.failed;
            message_ = "failed to create temp dir: " ~ e.msg;
            return;
        }

        const inPath  = buildPath(dir, "in.obj");
        const outPath = buildPath(dir, "out.obj");
        const logPath = buildPath(dir, "log.txt");

        try {
            writeTriangulatedObj(mesh, inPath);
        } catch (Exception e) {
            try rmdirRecurse(dir); catch (Exception) {}
            state_   = State.failed;
            message_ = "failed to write input OBJ: " ~ e.msg;
            return;
        }

        File log;
        try {
            log = File(logPath, "w");
            auto args = [
                bin,
                "--input",        inPath,
                "--output",       outPath,
                "--target-quads", targetQuads.to!string,
                "--sharp-edge",   sharpEdge.to!string,
                "--adaptivity",   adaptivity.to!string,
            ];
            pid_    = spawnProcess(args, stdin, log, log);
            hasPid_ = true;
        } catch (Exception e) {
            if (log.isOpen) try log.close(); catch (Exception) {}
            try rmdirRecurse(dir); catch (Exception) {}
            state_   = State.failed;
            message_ = "failed to launch remesher: " ~ e.msg;
            return;
        }

        workDir_ = dir;
        outPath_ = outPath;
        logPath_ = logPath;
        logFile_ = log;
        state_   = State.running;
        message_ = null;
    }

    /// Non-blocking — call once per frame. Transitions running -> succeeded
    /// or running -> failed once the subprocess has terminated; a no-op
    /// otherwise (including when idle/succeeded/failed already, so it is
    /// always safe to call unconditionally from the main loop).
    void poll() {
        if (state_ != State.running) return;

        typeof(tryWait(pid_)) w;
        try {
            w = tryWait(pid_);
        } catch (Exception e) {
            state_   = State.failed;
            message_ = "tryWait failed: " ~ e.msg;
            cleanupFiles();
            return;
        }
        if (!w.terminated) return;

        scope(exit) cleanupFiles();

        if (w.status == 0) {
            Vec3[] verts;
            uint[][] faces;
            if (parsePolygonObj(outPath_, verts, faces) && faces.length > 0) {
                resultVertices_ = verts;
                resultFaces_    = faces;
                state_   = State.succeeded;
                message_ = null;
                return;
            }
            state_   = State.failed;
            message_ = "remesher produced no usable geometry" ~ readLogTail(logPath_);
            return;
        }

        state_   = State.failed;
        message_ = "remesher exited with status " ~ w.status.to!string
                 ~ readLogTail(logPath_);
    }

    /// Cooperative cancel: signal the subprocess, reap it, clean up temp
    /// files, and drop back to idle. No-op if not running.
    void cancel() {
        if (state_ != State.running) return;
        if (hasPid_) {
            try {
                // SIGKILL, not the default SIGTERM: cancel() runs on the UI
                // thread (Cancel button) and at shutdown (scope(exit)), and the
                // following wait() blocks with no timeout. A helper that traps
                // or is slow on SIGTERM would hang the editor; SIGKILL can't be
                // caught, so the child dies promptly and wait() returns at once.
                version (Posix) {
                    import core.sys.posix.signal : SIGKILL;
                    kill(pid_, SIGKILL);
                } else {
                    kill(pid_);
                }
                wait(pid_);
            } catch (Exception) {}
        }
        cleanupFiles();
        state_   = State.idle;
        message_ = null;
    }

    private void cleanupFiles() {
        if (logFile_.isOpen) try logFile_.close(); catch (Exception) {}
        if (workDir_.length && exists(workDir_)) {
            try rmdirRecurse(workDir_); catch (Exception) {}
        }
        workDir_ = null;
        outPath_ = null;
        logPath_ = null;
        hasPid_  = false;
    }
}

/// Kernel-boundary clamp (task's numeric-Param-DoS convention): every field
/// is bounded to a sane range regardless of caller (`.min()/.max()` on the
/// RemeshStart Param is a UI-only hint and does NOT clamp a headless
/// `mesh.remesh.start` argstring call — this is the one place that always
/// runs). Non-finite floats fall back to their default rather than being
/// clamped (NaN/Inf compares false against any bound, so a plain min/max
/// clamp would silently let them through).
private RemeshParams sanitizeParams(RemeshParams p) @safe pure nothrow @nogc {
    import std.math : isFinite;

    RemeshParams o;

    o.targetQuads = p.targetQuads;
    if (o.targetQuads < MIN_REMESH_TARGET_QUADS) o.targetQuads = MIN_REMESH_TARGET_QUADS;
    if (o.targetQuads > MAX_REMESH_TARGET_QUADS) o.targetQuads = MAX_REMESH_TARGET_QUADS;

    o.adaptivity = isFinite(p.adaptivity) ? p.adaptivity : 1.0;
    if (o.adaptivity < 0.0) o.adaptivity = 0.0;
    if (o.adaptivity > 10.0) o.adaptivity = 10.0;

    o.sharpEdge = isFinite(p.sharpEdge) ? p.sharpEdge : 90.0;
    if (o.sharpEdge < 0.0) o.sharpEdge = 0.0;
    if (o.sharpEdge > 180.0) o.sharpEdge = 180.0;

    return o;
}

unittest {
    // In-range values pass through untouched.
    auto p = sanitizeParams(RemeshParams(6000, 1.0, 90.0));
    assert(p.targetQuads == 6000);
    assert(p.adaptivity  == 1.0);
    assert(p.sharpEdge   == 90.0);

    // Out-of-range / hostile values (a headless argstring caller bypassing
    // every UI slider hint) are clamped to the kernel ceiling, not rejected.
    auto clamped = sanitizeParams(RemeshParams(int.max, 1_000.0, -45.0));
    assert(clamped.targetQuads == MAX_REMESH_TARGET_QUADS);
    assert(clamped.adaptivity  == 10.0);
    assert(clamped.sharpEdge   == 0.0);

    auto tooLow = sanitizeParams(RemeshParams(-100, -5.0, 999.0));
    assert(tooLow.targetQuads == MIN_REMESH_TARGET_QUADS);
    assert(tooLow.adaptivity  == 0.0);
    assert(tooLow.sharpEdge   == 180.0);

    // NaN/Inf fall back to the default rather than being let through by a
    // plain min/max compare (both compare false against any bound).
    auto nonFinite = sanitizeParams(RemeshParams(6000, double.nan, double.infinity));
    assert(nonFinite.adaptivity == 1.0);
    assert(nonFinite.sharpEdge  == 90.0);
}

/// Locate the helper binary: env override first, then the developer's fixed
/// checkout path, then the same relative layout off the running exe's dir
/// (a sibling `D-AutoRemesher` checkout next to the vibe3d one). Returns
/// null if none of the three exist.
private string locateHelper() {
    auto envPath = environment.get("VIBE3D_AUTOREMESHER_BIN");
    if (envPath.length && exists(envPath)) return envPath;

    auto home = expandTilde("~/Code/D-AutoRemesher/bin/autoremesher_cli");
    if (exists(home)) return home;

    try {
        auto exeDir = dirName(thisExePath());
        auto rel = buildPath(exeDir, "..", "D-AutoRemesher", "bin", "autoremesher_cli");
        if (exists(rel)) return rel;
    } catch (Exception) {}

    return null;
}

/// Fan-triangulate every face around its first vertex and write a plain
/// OBJ (`v`/`f` only, 1-based indices) — the helper wants triangles in;
/// vibe3d's own n-gon mesh is never triangulated on the way back OUT (see
/// parsePolygonObj).
private void writeTriangulatedObj(const ref Mesh mesh, string path) {
    auto f = File(path, "w");
    foreach (ref v; mesh.vertices)
        f.writefln("v %.6f %.6f %.6f", v.x, v.y, v.z);
    foreach (face; mesh.faces.range) {
        if (face.length < 3) continue;
        foreach (i; 1 .. face.length - 1)
            f.writefln("f %d %d %d", face[0] + 1, face[i] + 1, face[i + 1] + 1);
    }
}

/// Parse a polygon OBJ — quads/n-gons are kept as-is, NOT triangulated.
/// `vt`/`vn` lines are ignored; `f` tokens are read as `idx[/vt[/vn]]`,
/// 1-based (or OBJ-style negative/relative) -> 0-based. Returns false if no
/// vertices or no usable (arity >= 3) faces were found. Never throws —
/// malformed lines are skipped rather than aborting the whole parse.
private bool parsePolygonObj(string path, out Vec3[] verts, out uint[][] faces) {
    if (!exists(path)) return false;
    Vec3[]   vs;
    uint[][] fs;
    File f;
    try f = File(path, "r");
    catch (Exception) return false;

    foreach (rawLine; f.byLine) {
        auto line = rawLine.idup.strip;
        if (line.length < 2) continue;
        if (line[0] == 'v' && line[1] == ' ') {
            auto toks = line[2 .. $].strip.split;
            if (toks.length < 3) continue;
            try vs ~= Vec3(toks[0].to!float, toks[1].to!float, toks[2].to!float);
            catch (Exception) continue;
        } else if (line[0] == 'f' && line[1] == ' ') {
            auto toks = line[2 .. $].strip.split;
            uint[] idx;
            foreach (tok; toks) {
                auto vstr = tok.split("/")[0];
                if (vstr.length == 0) continue;
                long vi;
                try vi = vstr.to!long;
                catch (Exception) continue;
                if (vi < 0) vi = cast(long) vs.length + vi + 1; // relative index
                if (vi < 1) continue;
                // Drop out-of-range highs BEFORE the cast: a `vi > uint.max`
                // would wrap `cast(uint)(vi-1)` into a small in-range index the
                // evaluate-side `idx >= vertexCount` guard can't catch, silently
                // binding the wrong vertex. (v precedes f in the helper's OBJ,
                // so vs.length is the full vertex count here.)
                if (vi > cast(long) vs.length) continue;
                idx ~= cast(uint)(vi - 1);
            }
            if (idx.length >= 3) fs ~= idx;
        }
    }
    verts = vs;
    faces = fs;
    return verts.length > 0 && faces.length > 0;
}

/// Best-effort tail of the helper's captured stdout+stderr log, folded into
/// a failure message. Never throws.
private string readLogTail(string path, size_t maxBytes = 800) {
    try {
        if (!exists(path)) return "";
        auto text = readText(path);
        if (text.length > maxBytes) text = text[$ - maxBytes .. $];
        auto t = text.strip;
        return t.length ? " -- log: " ~ t : "";
    } catch (Exception) {
        return "";
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

// D disallows a try/catch directly inside a scope(exit) statement, so every
// best-effort test-file cleanup below goes through this nothrow helper.
version (unittest) private void tryRemove(string path) nothrow {
    import std.file : remove;
    try remove(path); catch (Exception) {}
}

unittest {
    // parsePolygonObj: quad kept as a quad (not triangulated), vt/vn/comment
    // lines ignored, a trailing triangle with a "v//vn"-style face token
    // still parses (the vn half is simply dropped).
    import std.file : write, remove;

    auto path = buildPath(tempDir(), "vibe3d_remesh_test_parse.obj");
    scope(exit) tryRemove(path);

    write(path,
        "# comment\n"
      ~ "v 0.0 0.0 0.0\n"
      ~ "v 1.0 0.0 0.0\n"
      ~ "v 1.0 1.0 0.0\n"
      ~ "v 0.0 1.0 0.0\n"
      ~ "v 0.5 0.5 1.0\n"
      ~ "vt 0.0 0.0\n"
      ~ "vn 0.0 0.0 1.0\n"
      ~ "f 1 2 3 4\n"
      ~ "f 1//1 2//1 5//1\n");

    Vec3[] verts;
    uint[][] faces;
    assert(parsePolygonObj(path, verts, faces));
    assert(verts.length == 5);
    assert(faces.length == 2);
    assert(faces[0] == [0u, 1u, 2u, 3u], "quad must stay a quad");
    assert(faces[1] == [0u, 1u, 4u]);
}

unittest {
    // parsePolygonObj: missing file / no faces -> false.
    Vec3[] verts;
    uint[][] faces;
    assert(!parsePolygonObj(buildPath(tempDir(), "vibe3d_remesh_does_not_exist.obj"),
                             verts, faces));
}

unittest {
    // writeTriangulatedObj: a single quad face fans into exactly two
    // triangle `f` lines, 1-based indices, first-vertex-anchored.
    import std.file : remove;

    Mesh m = Mesh.init;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    uint[ulong] edgeLookup;
    m.addFaceFast(edgeLookup, [0u, 1u, 2u, 3u]);
    m.buildLoops();

    auto path = buildPath(tempDir(), "vibe3d_remesh_test_write.obj");
    scope(exit) tryRemove(path);
    writeTriangulatedObj(m, path);

    auto text = readText(path);
    assert(text.canFindLine("f 1 2 3"));
    assert(text.canFindLine("f 1 3 4"));
}

version (unittest) private bool canFindLine(string text, string line) {
    import std.algorithm.iteration : splitter;
    foreach (l; text.splitter('\n'))
        if (l.strip == line) return true;
    return false;
}

version (Posix)
unittest {
    // Full RemeshJob lifecycle (success / failure / cancel), driven through
    // VIBE3D_AUTOREMESHER_BIN pointed at tiny throwaway shell scripts —
    // never the real (heavy, environment-specific) autoremesher_cli.
    import std.file : write, setAttributes, remove;
    import std.conv : octal;
    import core.thread : Thread;
    import core.time : Duration, msecs, seconds;

    Mesh cube() {
        Mesh m = Mesh.init;
        m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
        uint[ulong] edgeLookup;
        m.addFaceFast(edgeLookup, [0u, 1u, 2u, 3u]);
        m.buildLoops();
        return m;
    }

    void waitUntilDone(RemeshJob job, Duration timeout) {
        auto deadline = MonoTime.currTime + timeout;
        while (job.busy() && MonoTime.currTime < deadline) {
            job.poll();
            if (job.busy()) Thread.sleep(10.msecs);
        }
    }

    // --- success path: fake helper writes a valid quad OBJ and exits 0 ---
    {
        auto script = buildPath(tempDir(), "vibe3d_remesh_fake_ok.sh");
        write(script,
            "#!/bin/sh\n"
          ~ "out=\"\"\n"
          ~ "while [ $# -gt 0 ]; do\n"
          ~ "  if [ \"$1\" = \"--output\" ]; then shift; out=\"$1\"; fi\n"
          ~ "  shift\n"
          ~ "done\n"
          ~ "printf 'v 0 0 0\\nv 1 0 0\\nv 1 1 0\\nv 0 1 0\\nf 1 2 3 4\\n' > \"$out\"\n"
          ~ "exit 0\n");
        setAttributes(script, octal!755);
        scope(exit) tryRemove(script);

        environment["VIBE3D_AUTOREMESHER_BIN"] = script;
        scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

        auto job = new RemeshJob();
        auto m = cube();
        job.start(m, RemeshParams());
        assert(job.busy());
        waitUntilDone(job, 5.seconds);
        assert(job.state() == RemeshJob.State.succeeded);
        assert(job.resultVertices().length == 4);
        assert(job.resultFaces().length == 1);
        assert(job.resultFaces()[0].length == 4);
        job.clear();
        assert(job.state() == RemeshJob.State.idle);
        assert(job.resultVertices().length == 0);
    }

    // --- failure path: fake helper exits non-zero, no output written ---
    {
        auto script = buildPath(tempDir(), "vibe3d_remesh_fake_fail.sh");
        write(script, "#!/bin/sh\necho boom 1>&2\nexit 1\n");
        setAttributes(script, octal!755);
        scope(exit) tryRemove(script);

        environment["VIBE3D_AUTOREMESHER_BIN"] = script;
        scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

        auto job = new RemeshJob();
        auto m = cube();
        job.start(m, RemeshParams());
        waitUntilDone(job, 5.seconds);
        assert(job.state() == RemeshJob.State.failed);
        assert(job.message().length > 0);
        job.clear();
    }

    // --- cancel: fake helper sleeps well past our cancel() call ---
    {
        auto script = buildPath(tempDir(), "vibe3d_remesh_fake_slow.sh");
        write(script, "#!/bin/sh\nsleep 5\nexit 0\n");
        setAttributes(script, octal!755);
        scope(exit) tryRemove(script);

        environment["VIBE3D_AUTOREMESHER_BIN"] = script;
        scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

        auto job = new RemeshJob();
        auto m = cube();
        job.start(m, RemeshParams());
        assert(job.busy());
        job.cancel();
        assert(!job.busy());
        assert(job.state() == RemeshJob.State.idle);
    }
}
