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

import std.algorithm.iteration : map;
import std.algorithm.sorting   : sort;
import std.array   : array, split;
import std.conv    : to;
import std.file    : exists, tempDir, mkdirRecurse, rmdirRecurse, readText, thisExePath;
import std.path    : buildPath, expandTilde, dirName;
import std.process : Pid, spawnProcess, tryWait, kill, wait, environment, thisProcessID;
import std.stdio   : File, stdin;
import std.string  : strip;
import core.time   : MonoTime;

import mesh : Mesh;
import math : Vec3;
import remesh.region_stitch : stitchRegion, StitchResult;

/// User-facing remesh parameters, mapped 1:1 onto autoremesher_cli's flags.
/// Values are hints only — `start()` is the kernel boundary that actually
/// clamps them (see MAX_REMESH_TARGET_QUADS below) before they ever reach
/// the subprocess, regardless of whether they arrived via the UI modal
/// (already `.min()/.max()`-hinted) or a headless `mesh.remesh.start`
/// argstring (which bypasses UI hints entirely).
struct RemeshParams {
    int    targetQuads = 20_000;
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

    // --- Region-mode state (task 0385, local/selected-region remesh) -------
    // Populated at start() time when a non-empty, non-total face selection
    // is passed in; read only while state_ == running. Everything the
    // eventual stitch needs is CAPTURED here rather than re-read from the
    // live `Mesh` later, mirroring the existing OBJ-marshalling convention:
    // start() returns immediately, and poll() (which does the stitching)
    // runs long after the caller's `mesh` reference may have moved on.
    private bool     regionMode_;
    private int      regionAttempt_;        // 1 = open-patch, 2 = triangle (retry)
    private string   helperBin_;             // located CLI path, reused across retries
    private string   regionInPath_;          // region-only input OBJ, same across attempts
    private int      paramsTargetQuads_;
    private double   paramsAdaptivity_;
    private double   paramsSharpEdge_;
    private Vec3[]   regionOrigVerts_;       // FULL mesh vertex copy, global indices
    private uint[][] regionKeepFaces_;       // faces NOT in the region, global indices
    private uint[][] regionBoundaryLoops_;   // Bo_i, ordered ORIGINAL global vertex indices

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
    ///
    /// `selectedFaceMask`, when non-empty and covering at least one but NOT
    /// every face, switches to REGION mode (task 0385): only the selected
    /// faces are extracted, remeshed as an open patch, and stitched back
    /// into the rest of the mesh (boundary-pinned — see
    /// `remesh.region_stitch`). An empty selection, or a selection covering
    /// every face (nothing left to "keep"), takes the ORIGINAL whole-mesh
    /// path unchanged.
    void start(const ref Mesh mesh, RemeshParams rawParams, const(bool)[] selectedFaceMask = null) {
        if (state_ == State.running) return;

        const p = sanitizeParams(rawParams);
        paramsTargetQuads_ = p.targetQuads;
        paramsAdaptivity_  = p.adaptivity;
        paramsSharpEdge_   = p.sharpEdge;

        auto bin = locateHelper();
        if (bin is null) {
            state_   = State.failed;
            message_ = "remesher not found (set VIBE3D_AUTOREMESHER_BIN or "
                     ~ "build ~/Code/D-AutoRemesher)";
            return;
        }
        helperBin_ = bin;

        size_t selCount = 0;
        if (selectedFaceMask.length)
            foreach (b; selectedFaceMask) if (b) ++selCount;
        const bool region = selCount > 0 && selCount < mesh.faces.length;

        Mesh     regionMesh;
        uint[][] keepFacesGlobal;
        uint[][] globalLoops;

        if (region) {
            uint[][] regionFacesGlobal;
            foreach (fi, face; mesh.faces.range) {
                if (fi < selectedFaceMask.length && selectedFaceMask[fi])
                    regionFacesGlobal ~= face.dup;
                else
                    keepFacesGlobal ~= face.dup;
            }

            // Compact the region's own vertices (for the OBJ write + the
            // temp Mesh used to derive its boundary loops); translate back
            // to global indices immediately after.
            bool[uint] usedSet;
            foreach (f; regionFacesGlobal) foreach (v; f) usedSet[v] = true;
            uint[] usedGlobal = usedSet.keys.dup;
            sort(usedGlobal);
            uint[uint] g2l;
            foreach (i, v; usedGlobal) g2l[v] = cast(uint) i;

            regionMesh = Mesh.init;
            regionMesh.vertices = new Vec3[](usedGlobal.length);
            foreach (i, v; usedGlobal) regionMesh.vertices[i] = mesh.vertices[v];
            uint[ulong] edgeLookup;
            foreach (f; regionFacesGlobal) {
                auto local = f.map!(v => g2l[v]).array;
                regionMesh.addFaceFast(edgeLookup, local);
            }
            regionMesh.buildLoops();

            auto localLoops = regionMesh.boundaryLoops();
            if (localLoops.length == 0) {
                state_   = State.failed;
                message_ = "selected region has no open boundary (fully enclosed) -- "
                         ~ "cannot stitch; clear the selection to remesh the whole mesh";
                return;
            }
            globalLoops = localLoops.map!(loop => loop.map!(li => usedGlobal[li]).array).array;
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
            if (region) writeTriangulatedObj(regionMesh, inPath);
            else        writeTriangulatedObj(mesh, inPath);
        } catch (Exception e) {
            try rmdirRecurse(dir); catch (Exception) {}
            state_   = State.failed;
            message_ = "failed to write input OBJ: " ~ e.msg;
            return;
        }

        workDir_    = dir;
        outPath_    = outPath;
        logPath_    = logPath;
        regionMode_ = region;

        if (region) {
            regionOrigVerts_     = mesh.vertices.dup;
            regionKeepFaces_     = keepFacesGlobal;
            regionBoundaryLoops_ = globalLoops;
            regionInPath_        = inPath;

            if (!spawnRegionAttempt(1)) {
                try rmdirRecurse(dir); catch (Exception) {}
                state_   = State.failed;
                message_ = "failed to launch remesher";
                workDir_ = null; outPath_ = null; logPath_ = null;
                return;
            }
            message_ = null;
            return;
        }

        // Whole-mesh path — unchanged behavior (no `--mode` flag: the
        // helper's own default is `closed`).
        File log;
        try {
            log = File(logPath, "w");
            auto args = [
                bin,
                "--input",        inPath,
                "--output",       outPath,
                "--target-quads", paramsTargetQuads_.to!string,
                "--sharp-edge",   paramsSharpEdge_.to!string,
                "--adaptivity",   paramsAdaptivity_.to!string,
            ];
            pid_    = spawnProcess(args, stdin, log, log);
            hasPid_ = true;
        } catch (Exception e) {
            if (log.isOpen) try log.close(); catch (Exception) {}
            try rmdirRecurse(dir); catch (Exception) {}
            state_   = State.failed;
            message_ = "failed to launch remesher: " ~ e.msg;
            workDir_ = null; outPath_ = null; logPath_ = null;
            return;
        }

        logFile_ = log;
        state_   = State.running;
        message_ = null;
    }

    /// Spawn one region-mode attempt (`--mode open-patch` first; `--mode
    /// triangle` if poll() decides the first attempt's patch could not be
    /// stitched robustly). Reuses the SAME region input OBJ and output path
    /// across attempts — only the log is appended to (with a separator)
    /// so a final failure message can show both trials. Returns false if
    /// the subprocess could not even be spawned (I/O error); the caller
    /// then treats the job as a hard failure.
    private bool spawnRegionAttempt(int attempt) {
        const string modeStr = attempt == 1 ? "open-patch" : "triangle";
        try {
            if (logFile_.isOpen) try logFile_.close(); catch (Exception) {}
            logFile_ = File(logPath_, attempt == 1 ? "w" : "a");
            if (attempt != 1)
                logFile_.writefln("--- retry: --mode %s ---", modeStr);

            auto args = [
                helperBin_,
                "--input",        regionInPath_,
                "--output",       outPath_,
                "--mode",         modeStr,
                "--target-quads", paramsTargetQuads_.to!string,
                "--sharp-edge",   paramsSharpEdge_.to!string,
                "--adaptivity",   paramsAdaptivity_.to!string,
            ];
            pid_    = spawnProcess(args, stdin, logFile_, logFile_);
            hasPid_ = true;
            regionAttempt_ = attempt;
            state_  = State.running;
            return true;
        } catch (Exception) {
            return false;
        }
    }

    /// Non-blocking — call once per frame. Transitions running -> succeeded
    /// or running -> failed once the subprocess has terminated; a no-op
    /// otherwise (including when idle/succeeded/failed already, so it is
    /// always safe to call unconditionally from the main loop).
    ///
    /// Region mode (task 0385) additionally may transition running ->
    /// running: if the open-patch attempt's output can't be stitched back
    /// robustly (`region_stitch.stitchRegion` reports `!ok`, which folds in
    /// both "wrong rim-loop count" and "outer-rim too far from the region
    /// boundary" — see that module), a SECOND attempt (`--mode triangle`)
    /// is spawned automatically and poll() keeps running against it. Only
    /// if that second attempt ALSO fails to produce a stitchable patch does
    /// the job soft-fail (mesh untouched).
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

        if (!regionMode_) {
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
            return;
        }

        // ---- region mode ----------------------------------------------
        if (w.status != 0) {
            if (regionAttempt_ == 1 && spawnRegionAttempt(2)) return; // escalate to triangle
            state_   = State.failed;
            message_ = "remesher exited with status " ~ w.status.to!string
                     ~ " (open-patch and triangle attempts both failed)"
                     ~ readLogTail(logPath_);
            cleanupFiles();
            return;
        }

        Vec3[]   patchVerts;
        uint[][] patchFaces;
        StitchResult sr;
        const bool parsed = parsePolygonObj(outPath_, patchVerts, patchFaces) && patchFaces.length > 0;
        if (parsed)
            sr = stitchRegion(regionOrigVerts_, regionKeepFaces_, regionBoundaryLoops_, patchVerts, patchFaces);

        if (parsed && sr.ok) {
            resultVertices_ = sr.vertices;
            resultFaces_    = sr.faces;
            state_   = State.succeeded;
            message_ = null;
            cleanupFiles();
            return;
        }

        if (regionAttempt_ == 1 && spawnRegionAttempt(2)) return; // escalate to triangle

        state_ = State.failed;
        const string reason = parsed ? sr.failReason : "remesher produced no usable geometry";
        message_ = "region remesh: stitch failed after open-patch + triangle attempts -- "
                 ~ reason ~ readLogTail(logPath_);
        cleanupFiles();
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

version (Posix)
unittest {
    // Region mode (task 0385): start()'s selection-mask path, driven end to
    // end through a FAKE `autoremesher_cli` (never the real, heavy,
    // environment-specific binary) that branches on `--mode` so both the
    // first-attempt-succeeds path and the open-patch -> triangle escalation
    // path are exercised through the REAL start()/poll() state machine (not
    // just region_stitch.stitchRegion in isolation, which has its own
    // dedicated unit tests in region_stitch.d).
    import std.file    : write, setAttributes, remove;
    import std.conv    : octal;
    import std.array   : appender;
    import core.thread : Thread;
    import core.time   : Duration, msecs, seconds;

    // A 6x6 quad grid (row-major face index = j*6+i), matching
    // region_stitch.d's own grid-test conventions.
    Mesh gridMesh(int nx, int ny, float cell) {
        Mesh m = Mesh.init;
        m.vertices = new Vec3[]((nx + 1) * (ny + 1));
        foreach (j; 0 .. ny + 1)
            foreach (i; 0 .. nx + 1)
                m.vertices[j * (nx + 1) + i] = Vec3(i * cell, j * cell, 0);
        uint[ulong] lookup;
        foreach (j; 0 .. ny)
            foreach (i; 0 .. nx) {
                uint v00 = cast(uint)(j * (nx + 1) + i);
                uint v10 = cast(uint)(j * (nx + 1) + i + 1);
                uint v11 = cast(uint)((j + 1) * (nx + 1) + i + 1);
                uint v01 = cast(uint)((j + 1) * (nx + 1) + i);
                m.addFaceFast(lookup, [v00, v10, v11, v01]);
            }
        m.buildLoops();
        return m;
    }

    // An nx*ny quad-grid OBJ over [x0,x0+nx*cell] x [y0,y0+ny*cell] — used
    // to write canned "remesher output" patches for the fake CLI to `cp`.
    string gridObjText(int nx, int ny, float cell, float x0, float y0) {
        auto app = appender!string;
        foreach (j; 0 .. ny + 1)
            foreach (i; 0 .. nx + 1)
                app.put("v " ~ (x0 + i * cell).to!string ~ " " ~ (y0 + j * cell).to!string ~ " 0\n");
        foreach (j; 0 .. ny)
            foreach (i; 0 .. nx) {
                uint v00 = cast(uint)(j * (nx + 1) + i) + 1;
                uint v10 = cast(uint)(j * (nx + 1) + i + 1) + 1;
                uint v11 = cast(uint)((j + 1) * (nx + 1) + i + 1) + 1;
                uint v01 = cast(uint)((j + 1) * (nx + 1) + i) + 1;
                app.put("f " ~ v00.to!string ~ " " ~ v10.to!string ~ " "
                       ~ v11.to!string ~ " " ~ v01.to!string ~ "\n");
            }
        return app.data;
    }

    // Fake CLI: ignores the input entirely (the region OBJ is written by
    // the real start(), but this stand-in doesn't need to read it) and
    // `cp`s a pre-baked patch depending on `--mode`.
    void writeModeSwitchScript(string scriptPath, string openPatchObj, string triangleObj) {
        write(scriptPath,
            "#!/bin/sh\n"
          ~ "out=\"\"; mode=\"closed\"\n"
          ~ "while [ $# -gt 0 ]; do\n"
          ~ "  case \"$1\" in\n"
          ~ "    --output) shift; out=\"$1\" ;;\n"
          ~ "    --mode) shift; mode=\"$1\" ;;\n"
          ~ "  esac\n"
          ~ "  shift\n"
          ~ "done\n"
          ~ "if [ \"$mode\" = \"open-patch\" ]; then cp \"" ~ openPatchObj ~ "\" \"$out\"; "
          ~ "else cp \"" ~ triangleObj ~ "\" \"$out\"; fi\n"
          ~ "exit 0\n");
        setAttributes(scriptPath, octal!755);
    }

    void waitUntilDone(RemeshJob job, Duration timeout) {
        auto deadline = MonoTime.currTime + timeout;
        while (job.busy() && MonoTime.currTime < deadline) {
            job.poll();
            if (job.busy()) Thread.sleep(10.msecs);
        }
    }

    // 6x6 grid, select the central 2x2 block (faces (i,j) with i,j in [2,4)) --
    // matches region_stitch.d's own "single hole" test exactly.
    bool[] centralRegionMask() {
        auto mask = new bool[](36);
        foreach (j; 0 .. 6) foreach (i; 0 .. 6)
            if (i >= 2 && i < 4 && j >= 2 && j < 4) mask[j * 6 + i] = true;
        return mask;
    }

    const goodPatch = buildPath(tempDir(), "vibe3d_remesh_test_good_patch.obj");
    const badPatch  = buildPath(tempDir(), "vibe3d_remesh_test_bad_patch.obj");
    scope(exit) { tryRemove(goodPatch); tryRemove(badPatch); }
    // Good: finer grid over the SAME [2,4]x[2,4] footprint as the region.
    write(goodPatch, gridObjText(4, 4, 0.5f, 2.0f, 2.0f));
    // Bad: same shape, but at the WRONG location -- its rim sits nowhere
    // near the region's boundary loop, so stitchRegion must reject it.
    write(badPatch, gridObjText(4, 4, 0.5f, 20.0f, 20.0f));

    // --- A: open-patch succeeds on the FIRST attempt --------------------
    {
        auto script = buildPath(tempDir(), "vibe3d_remesh_fake_region_ok.sh");
        scope(exit) tryRemove(script);
        writeModeSwitchScript(script, goodPatch, goodPatch);

        environment["VIBE3D_AUTOREMESHER_BIN"] = script;
        scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

        auto job = new RemeshJob();
        auto m   = gridMesh(6, 6, 1.0f);
        job.start(m, RemeshParams(), centralRegionMask());
        assert(job.busy());
        waitUntilDone(job, 5.seconds);
        assert(job.state() == RemeshJob.State.succeeded, job.message());
        // 49 original verts + 25 patch verts (16 faces used) = at least the
        // original count; exact patch-interior count depends on trimming,
        // so just assert it grew and every face is a valid triangle/quad.
        assert(job.resultVertices().length > 49);
        assert(job.resultFaces().length > 32, "expected kept(32) + new geometry");
        job.clear();
    }

    // --- B: open-patch's patch can't be stitched -> escalates to triangle,
    //        which succeeds -- validates the retry state machine. ---------
    {
        auto script = buildPath(tempDir(), "vibe3d_remesh_fake_region_escalate.sh");
        scope(exit) tryRemove(script);
        writeModeSwitchScript(script, badPatch, goodPatch);

        environment["VIBE3D_AUTOREMESHER_BIN"] = script;
        scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

        auto job = new RemeshJob();
        auto m   = gridMesh(6, 6, 1.0f);
        job.start(m, RemeshParams(), centralRegionMask());
        waitUntilDone(job, 5.seconds);
        assert(job.state() == RemeshJob.State.succeeded,
               "escalation to triangle should still succeed: " ~ job.message());
        assert(job.resultFaces().length > 32);
        job.clear();
    }

    // --- C: both attempts produce an unstitchable patch -> soft-fail ----
    {
        auto script = buildPath(tempDir(), "vibe3d_remesh_fake_region_fail.sh");
        scope(exit) tryRemove(script);
        writeModeSwitchScript(script, badPatch, badPatch);

        environment["VIBE3D_AUTOREMESHER_BIN"] = script;
        scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

        auto job = new RemeshJob();
        auto m   = gridMesh(6, 6, 1.0f);
        job.start(m, RemeshParams(), centralRegionMask());
        waitUntilDone(job, 5.seconds);
        assert(job.state() == RemeshJob.State.failed);
        assert(job.message().length > 0);
        job.clear();
    }
}

version (Posix)
unittest {
    // Region mode: a selection covering EVERY face is equivalent to no
    // selection at all (nothing left to "keep") -- must take the ORIGINAL
    // whole-mesh path, not the region path (there is no boundary loop to
    // pin against a fully-selected closed surface). Distinguished from the
    // region path deterministically: only the region path ever passes
    // `--mode`, so a fake CLI that records its own argv lets us assert the
    // whole-mesh path was taken without depending on message text.
    import std.file    : write, setAttributes, readText;
    import std.conv     : octal;
    import std.algorithm.searching : canFind;
    import core.thread  : Thread;
    import core.time    : Duration, seconds, msecs;

    void waitUntilDone(RemeshJob job, Duration timeout) {
        auto deadline = MonoTime.currTime + timeout;
        while (job.busy() && MonoTime.currTime < deadline) {
            job.poll();
            if (job.busy()) Thread.sleep(10.msecs);
        }
    }

    Mesh cube() {
        Mesh m = Mesh.init;
        m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
        uint[ulong] edgeLookup;
        m.addFaceFast(edgeLookup, [0u, 1u, 2u, 3u]);
        m.buildLoops();
        return m;
    }

    auto m = cube();
    auto allSelected = new bool[](m.faces.length);
    allSelected[] = true;

    const argvLog = buildPath(tempDir(), "vibe3d_remesh_test_allsel_argv.txt");
    scope(exit) tryRemove(argvLog);

    auto script = buildPath(tempDir(), "vibe3d_remesh_fake_allsel.sh");
    scope(exit) tryRemove(script);
    write(script,
        "#!/bin/sh\n"
      ~ "echo \"$@\" > \"" ~ argvLog ~ "\"\n"
      ~ "out=\"\"\n"
      ~ "while [ $# -gt 0 ]; do\n"
      ~ "  if [ \"$1\" = \"--output\" ]; then shift; out=\"$1\"; fi\n"
      ~ "  shift\n"
      ~ "done\n"
      ~ "printf 'v 0 0 0\\nv 1 0 0\\nv 1 1 0\\nv 0 1 0\\nf 1 2 3 4\\n' > \"$out\"\n"
      ~ "exit 0\n");
    setAttributes(script, octal!755);

    environment["VIBE3D_AUTOREMESHER_BIN"] = script;
    scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

    auto job = new RemeshJob();
    job.start(m, RemeshParams(), allSelected);
    waitUntilDone(job, 5.seconds);
    assert(job.state() == RemeshJob.State.succeeded, job.message());

    const argv = readText(argvLog);
    assert(!argv.canFind("--mode"),
           "an all-faces selection must take the whole-mesh path (no --mode flag), got: " ~ argv);
}
