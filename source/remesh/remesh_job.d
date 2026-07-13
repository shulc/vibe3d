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
import core.time   : MonoTime, Duration;

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

    // --- Region-mode state (task 0385, local/selected-region remesh; task
    // 0386 extends this to a hole-filled, per-component queue). Populated at
    // start() time when a non-empty, non-total face selection is passed in;
    // read only while state_ == running. Everything the eventual stitch
    // needs is CAPTURED here rather than re-read from the live `Mesh` later,
    // mirroring the existing OBJ-marshalling convention: start() returns
    // immediately, and poll() (which does the stitching) runs long after the
    // caller's `mesh` reference may have moved on.
    private bool     regionMode_;
    private int      regionAttempt_;        // 1 = open-patch, 2 = triangle (retry)
    private string   helperBin_;             // located CLI path, reused across retries
    private string   regionInPath_;          // region-only input OBJ, same path reused per component/attempt
    private int      paramsTargetQuads_;
    private double   paramsAdaptivity_;
    private double   paramsSharpEdge_;

    // Task 0386: the (hole-filled) selection is split into connected
    // components and stitched SEQUENTIALLY against a WORKING mesh, re-seeded
    // after every successful component stitch. This is index-safe because
    // `region_stitch.stitchRegion` never renumbers EXISTING vertices (see
    // its module doc) — origVerts.dup + appended patch verts — so a
    // boundary loop's global vertex indices, computed ONCE up front per
    // component, stay valid against the working mesh no matter how many
    // earlier components have already been folded in.
    private Vec3[]   workingVerts_;          // current working mesh vertices (grows each success)
    private uint[][] workingFaces_;          // current working mesh faces
    private int[]    workingOwner_;          // parallel to workingFaces_: owning PENDING component
                                              // index, or -1 (never selected, or newly-created
                                              // patch/bridge geometry from an earlier component)
    private size_t   numComponents_;
    private size_t   componentIdx_;          // component currently being processed
    private size_t   succeededComponents_;
    private size_t   skippedComponents_;

    // Per-CURRENT-component transient state, (re)built by
    // prepareCurrentComponent() at the start of each component's turn and
    // reused unchanged across its open-patch -> triangle attempt escalation.
    private uint[][] regionKeepFaces_;       // every working face NOT in the current component
    private int[]    regionKeepOwners_;      // parallel to regionKeepFaces_ (see workingOwner_ doc)
    private uint[][] regionBoundaryLoops_;   // current component's Bo_i, ORIGINAL global vertex indices

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

        workDir_    = dir;
        outPath_    = outPath;
        logPath_    = logPath;
        regionMode_ = region;

        if (!region) {
            // Whole-mesh path — unchanged behavior (no `--mode` flag: the
            // helper's own default is `closed`).
            try {
                writeTriangulatedObj(mesh, inPath);
            } catch (Exception e) {
                try rmdirRecurse(dir); catch (Exception) {}
                state_   = State.failed;
                message_ = "failed to write input OBJ: " ~ e.msg;
                workDir_ = null; outPath_ = null; logPath_ = null;
                return;
            }

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
            return;
        }

        // ---- region mode (task 0385; hole-fill + per-component queue: 0386) --
        regionInPath_ = inPath;

        // Part A: fold small, fully-enclosed selection holes into the
        // region BEFORE splitting into components (see Mesh.fillSelectionHoles) —
        // a user who "missed a part" of an otherwise-connected patch would
        // otherwise leave internal boundary loops that the external
        // remesher's own hole-merging turns into a stitch-breaking loop-
        // count mismatch.
        auto filledMask = mesh.fillSelectionHoles(selectedFaceMask);

        // Part B step 1: split the (hole-filled) selection into connected
        // components (shared-vertex flood fill — Mesh.faceComponentsOf).
        auto faceAdj   = mesh.faceAdjacencySharingVertex();
        auto components = Mesh.faceComponentsOf(filledMask, faceAdj);

        if (components.length == 0) {
            try rmdirRecurse(dir); catch (Exception) {}
            state_   = State.failed;
            message_ = "selected region has no faces to remesh";
            workDir_ = null; outPath_ = null; logPath_ = null;
            return;
        }

        // Seed the working mesh = the FULL original mesh, every selected
        // face tagged with the (pending) component that owns it; every
        // other face tagged -1 (always "kept", never touched by any
        // component's stitch).
        const(uint[])[] allFaces = mesh.faces.range;
        workingVerts_ = mesh.vertices.dup;
        workingFaces_ = new uint[][](allFaces.length);
        workingOwner_ = new int[](allFaces.length);
        workingOwner_[] = -1;
        foreach (fi, f; allFaces) workingFaces_[fi] = f.dup;
        foreach (ci, comp; components)
            foreach (fi; comp) workingOwner_[fi] = cast(int) ci;

        numComponents_       = components.length;
        componentIdx_        = 0;
        succeededComponents_ = 0;
        skippedComponents_   = 0;

        // beginNextComponent() sets state_/message_ to running (a subprocess
        // is now in flight), or — if every component was immediately
        // skippable (e.g. all fully closed) or a hard error struck first —
        // straight to succeeded/failed via finalizeRegionJob()/its own error
        // path. Either way it owns state_/message_ from here; only clear
        // message_ on the "still running" outcome (finalize/hardError already
        // set the message they want shown).
        if (beginNextComponent()) message_ = null;
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
            // Task 0386: both attempts exhausted for THIS component (or the
            // triangle retry couldn't even be launched) — skip just this
            // one (its faces stay as-is in the working mesh) and keep the
            // queue moving, rather than failing the whole job over one bad
            // component.
            ++skippedComponents_;
            ++componentIdx_;
            beginNextComponent();
            return;
        }

        Vec3[]   patchVerts;
        uint[][] patchFaces;
        StitchResult sr;
        const bool parsed = parsePolygonObj(outPath_, patchVerts, patchFaces) && patchFaces.length > 0;
        if (parsed)
            sr = stitchRegion(workingVerts_, regionKeepFaces_, regionBoundaryLoops_, patchVerts, patchFaces);

        if (parsed && sr.ok) {
            // Fold this component's stitched result into the working mesh.
            // The kept prefix (regionKeepFaces_, unchanged in sr.faces per
            // stitchRegion's contract) carries its owner tags forward
            // unchanged — a still-pending component's faces are untouched
            // and stay findable on its own turn; the newly appended patch +
            // bridge faces belong to no pending component.
            workingVerts_ = sr.vertices;
            workingFaces_ = sr.faces;
            workingOwner_ = new int[](sr.faces.length);
            foreach (i, o; regionKeepOwners_) workingOwner_[i] = o;
            foreach (i; regionKeepOwners_.length .. sr.faces.length) workingOwner_[i] = -1;

            ++succeededComponents_;
            ++componentIdx_;
            beginNextComponent();
            return;
        }

        if (regionAttempt_ == 1 && spawnRegionAttempt(2)) return; // escalate to triangle

        // Task 0386: both attempts produced an unstitchable patch for this
        // component — skip it (graceful per-component degradation) and
        // keep the queue moving instead of failing the whole job.
        ++skippedComponents_;
        ++componentIdx_;
        beginNextComponent();
    }

    /// Advance the component queue (task 0386): skip past every already-
    /// decided/closed component, then either spawn the next stitchable
    /// one's first (open-patch) attempt, or — once the queue is empty —
    /// finalize the job (`finalizeRegionJob`). Returns true iff a
    /// subprocess is now running (state_ == running); false means state_
    /// has already been set to succeeded/failed by this call (or an earlier
    /// hard error) and the caller (start()/poll()) should just return.
    private bool beginNextComponent() {
        while (componentIdx_ < numComponents_) {
            string errMsg;
            final switch (prepareCurrentComponent(errMsg)) {
                case PrepResult.hardError:
                    state_   = State.failed;
                    message_ = errMsg;
                    cleanupFiles();
                    return false;
                case PrepResult.skip:
                    ++skippedComponents_;
                    ++componentIdx_;
                    continue;
                case PrepResult.ready:
                    if (spawnRegionAttempt(1)) return true;
                    state_   = State.failed;
                    message_ = "failed to launch remesher";
                    cleanupFiles();
                    return false;
            }
        }
        finalizeRegionJob();
        return false;
    }

    private enum PrepResult { ready, skip, hardError }

    /// Prepare `componentIdx_`'s turn: extract its own CURRENT faces out of
    /// the working mesh (still untouched original geometry — a not-yet-
    /// processed component's faces are always carried through unchanged by
    /// every earlier stitch, see workingOwner_'s doc), derive its boundary
    /// loops, and write its region-only input OBJ (overwriting whatever the
    /// previous component left there). Populates
    /// regionKeepFaces_/regionKeepOwners_/regionBoundaryLoops_ for
    /// spawnRegionAttempt()/poll() to use across this component's attempt(s).
    ///
    /// A component with no faces left (defensive — should not happen,
    /// components are non-empty by construction) or no open boundary
    /// (fully closed — nothing to stitch) returns `skip`: a per-geometry
    /// condition, not a systemic failure. Only an I/O error writing the
    /// input OBJ is a `hardError` (mirrors start()'s own launch-failure
    /// handling — an environment problem, not something retrying a
    /// different component would route around).
    private PrepResult prepareCurrentComponent(out string errMsg) {
        uint[][] regionFacesGlobal;
        uint[][] otherFacesGlobal;
        int[]    otherOwners;
        foreach (fi, f; workingFaces_) {
            if (workingOwner_[fi] == cast(int) componentIdx_) {
                regionFacesGlobal ~= f.dup;
            } else {
                otherFacesGlobal ~= f.dup;
                otherOwners      ~= workingOwner_[fi];
            }
        }
        if (regionFacesGlobal.length == 0) return PrepResult.skip;

        bool[uint] usedSet;
        foreach (f; regionFacesGlobal) foreach (v; f) usedSet[v] = true;
        uint[] usedGlobal = usedSet.keys.dup;
        sort(usedGlobal);
        uint[uint] g2l;
        foreach (i, v; usedGlobal) g2l[v] = cast(uint) i;

        Mesh regionMesh = Mesh.init;
        regionMesh.vertices = new Vec3[](usedGlobal.length);
        foreach (i, v; usedGlobal) regionMesh.vertices[i] = workingVerts_[v];
        uint[ulong] edgeLookup;
        foreach (f; regionFacesGlobal) {
            auto local = f.map!(v => g2l[v]).array;
            regionMesh.addFaceFast(edgeLookup, local);
        }
        regionMesh.buildLoops();

        auto localLoops = regionMesh.boundaryLoops();
        if (localLoops.length == 0) return PrepResult.skip; // fully closed component

        regionBoundaryLoops_ = localLoops.map!(loop => loop.map!(li => usedGlobal[li]).array).array;
        regionKeepFaces_      = otherFacesGlobal;
        regionKeepOwners_     = otherOwners;

        try {
            writeTriangulatedObj(regionMesh, regionInPath_);
        } catch (Exception e) {
            errMsg = "failed to write input OBJ: " ~ e.msg;
            return PrepResult.hardError;
        }
        return PrepResult.ready;
    }

    /// Finalize the region job once the component queue is empty (task
    /// 0386): if not a single component could be remeshed, the whole job
    /// soft-fails (mesh untouched — same externally-visible outcome as the
    /// pre-0386 single-region soft-fail); otherwise the working mesh
    /// (however many components actually succeeded) is the result, and a
    /// non-fatal note is attached if any component was skipped along the
    /// way. Always tears down the temp workdir — the job is done either way.
    private void finalizeRegionJob() {
        if (succeededComponents_ == 0) {
            state_   = State.failed;
            message_ = "region remesh: none of the " ~ numComponents_.to!string
                     ~ " selected region component(s) could be remeshed "
                     ~ "(all too complex/degenerate for the external remesher)";
        } else {
            resultVertices_ = workingVerts_;
            resultFaces_    = workingFaces_;
            state_          = State.succeeded;
            message_        = skippedComponents_ > 0
                ? "remeshed " ~ succeededComponents_.to!string ~ " of "
                  ~ numComponents_.to!string ~ " region components ("
                  ~ skippedComponents_.to!string ~ " too complex/degenerate)"
                : null;
        }
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

// ---------------------------------------------------------------------------
// Task 0386 — auto-fill-holes + per-component queue. Shared test helpers
// (`hf`-prefixed to avoid any ambiguity with the per-block local helpers of
// similar shape above). Manifold/seam metrics mirror region_stitch.d's own
// version(unittest) block (private to that module, so ported here rather
// than duplicated per test block below).
// ---------------------------------------------------------------------------

version (unittest) {
    private Mesh hfGridMesh(int nx, int ny, float cell) {
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

    private string hfGridPatchText(int nx, int ny, float cell, float x0, float y0) {
        import std.array : appender;
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

    private void hfWaitUntilDone(RemeshJob job, Duration timeout) {
        import core.thread : Thread;
        import core.time   : msecs;
        auto deadline = MonoTime.currTime + timeout;
        while (job.busy() && MonoTime.currTime < deadline) {
            job.poll();
            if (job.busy()) Thread.sleep(10.msecs);
        }
    }

    private ulong hfEdgeKey(uint a, uint b) {
        return a < b ? (cast(ulong) a << 32) | b : (cast(ulong) b << 32) | a;
    }

    private int[ulong] hfEdgeUseCounts(const(uint[])[] faces) {
        int[ulong] ec;
        foreach (f; faces) {
            const size_t n = f.length;
            foreach (k; 0 .. n) {
                ulong key = hfEdgeKey(f[k], f[(k + 1) % n]);
                if (auto p = key in ec) ++(*p); else ec[key] = 1;
            }
        }
        return ec;
    }

    private size_t hfCountNonManifold(const(uint[])[] faces) {
        size_t n = 0;
        foreach (c; hfEdgeUseCounts(faces).byValue) if (c > 2) ++n;
        return n;
    }

    private bool[ulong] hfBoundaryEdgeSet(const(uint[])[] faces) {
        bool[ulong] s;
        foreach (key, c; hfEdgeUseCounts(faces)) if (c == 1) s[key] = true;
        return s;
    }

    /// Count interior edges whose two faces traverse them in the SAME
    /// direction (flipped-normal seam). 0 == the whole mesh is consistently
    /// wound.
    private size_t hfCountOrientationDefects(const(uint[])[] faces) {
        int[ulong] dir;
        foreach (f; faces) {
            const size_t n = f.length;
            foreach (k; 0 .. n) {
                uint a = f[k], b = f[cast(size_t)((k + 1) % n)];
                ulong key = (cast(ulong) a << 32) | b;
                if (auto p = key in dir) ++(*p); else dir[key] = 1;
            }
        }
        size_t d = 0;
        foreach (key, c; dir) if (c >= 2) ++d;
        return d;
    }

    /// Fake CLI dispatch keyed on the region's own INPUT CONTENT (not
    /// `--mode`/call order): needed once a job serves more than one region
    /// component per run (task 0386) — each component's subprocess call
    /// must get ITS OWN footprint's canned patch. `marker` is a substring
    /// (e.g. a corner vertex line) unique to that footprint's input OBJ;
    /// `patchObj` is `cp`'d to `--output` whenever `--input` contains it —
    /// regardless of `--mode`, so this doubles as an "always this output"
    /// stub across the open-patch/triangle escalation. `elseObj` is used
    /// when NONE of the markers match (a component this test doesn't name
    /// explicitly, or a fallback bad patch).
    private void hfWriteDispatchScript(string scriptPath, string[] markers,
                                        string[] patchObjs, string elseObj) {
        import std.file : write, setAttributes;
        import std.conv : octal;
        import std.array : appender;
        auto app = appender!string;
        app.put("#!/bin/sh\n");
        app.put("in=\"\"; out=\"\"\n");
        app.put("while [ $# -gt 0 ]; do\n");
        app.put("  case \"$1\" in\n");
        app.put("    --input) shift; in=\"$1\" ;;\n");
        app.put("    --output) shift; out=\"$1\" ;;\n");
        app.put("  esac\n");
        app.put("  shift\n");
        app.put("done\n");
        if (markers.length == 0) {
            // No per-footprint dispatch needed (a single-component test) --
            // an unconditional `cp` (an `else` with no preceding `if` is
            // invalid POSIX shell syntax).
            app.put("cp \"" ~ elseObj ~ "\" \"$out\"\n");
        } else {
            foreach (i, marker; markers) {
                app.put((i == 0 ? "if" : "elif") ~ " grep -qF \"" ~ marker ~ "\" \"$in\"; then\n");
                app.put("  cp \"" ~ patchObjs[i] ~ "\" \"$out\"\n");
            }
            app.put("else\n");
            app.put("  cp \"" ~ elseObj ~ "\" \"$out\"\n");
            app.put("fi\n");
        }
        app.put("exit 0\n");
        write(scriptPath, app.data);
        setAttributes(scriptPath, octal!755);
    }
}

version (Posix)
unittest {
    // Task 0386, case (a): a CONNECTED 4x4 block selection missing ONE
    // interior face -- Mesh.fillSelectionHoles must fold the missed face
    // back in so the region collapses to a SINGLE connected component with
    // a single boundary loop, rather than the 2-loop shape that broke the
    // original single-region stitch ("patch has fewer boundary loops than
    // the region"). End to end through a fake CLI that returns a finer grid
    // over the (hole-filled) region's own footprint. Verifies the final
    // stitched mesh directly: non-manifold==0, orientation-defects==0, and
    // the seam is fully closed (result's boundary-edge set == the ORIGINAL
    // whole mesh's).
    import std.file : write;
    import core.time : seconds;

    // 6x6 grid; select the central 4x4 block (i,j in [1,5)) MINUS ONE
    // interior face (i=2,j=3) -- a single-face hole fully enclosed by the
    // rest of the block.
    auto m = hfGridMesh(6, 6, 1.0f);
    auto mask = new bool[](36);
    foreach (j; 1 .. 5) foreach (i; 1 .. 5)
        if (!(i == 2 && j == 3)) mask[j * 6 + i] = true;

    const patch = buildPath(tempDir(), "vibe3d_remesh_test_holefill_patch.obj");
    scope(exit) tryRemove(patch);
    // Finer grid over the SAME [1,5]x[1,5] footprint as the hole-filled region.
    write(patch, hfGridPatchText(8, 8, 0.5f, 1.0f, 1.0f));

    const script = buildPath(tempDir(), "vibe3d_remesh_fake_holefill.sh");
    scope(exit) tryRemove(script);
    hfWriteDispatchScript(script, [], [], patch); // single footprint -- always this patch

    environment["VIBE3D_AUTOREMESHER_BIN"] = script;
    scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

    auto job = new RemeshJob();
    job.start(m, RemeshParams(), mask);
    assert(job.busy());
    hfWaitUntilDone(job, 5.seconds);
    assert(job.state() == RemeshJob.State.succeeded, job.message());
    assert(job.message().length == 0,
           "a single clean component must succeed with no partial-success note: " ~ job.message());

    auto resultFaces = job.resultFaces();
    assert(hfCountNonManifold(resultFaces) == 0, "introduced non-manifold edges must be 0");
    assert(hfCountOrientationDefects(resultFaces) == 0, "seam must be consistently wound");

    uint[][] origFaces;
    foreach (fi; 0 .. m.faces.length) origFaces ~= m.faces[fi].dup;
    assert(hfBoundaryEdgeSet(resultFaces) == hfBoundaryEdgeSet(origFaces),
           "stitched mesh's boundary-edge set must equal the original mesh's");

    job.clear();
}

version (Posix)
unittest {
    // Task 0386, case (b): TWO DISJOINT selected blocks (a wide unselected
    // gap between them, itself touching the mesh's own open boundary and
    // far larger than either block) must NOT be merged by
    // Mesh.fillSelectionHoles -- they split into 2 connected components and
    // are remeshed/stitched INDEPENDENTLY, both succeeding on the first
    // (open-patch) attempt. The fake CLI dispatches on each component's own
    // input-OBJ content since the two subprocess calls must return
    // DIFFERENT footprints.
    import std.file : write;
    import core.time : seconds;

    // 10x10 grid; block A = i,j in [1,3) (footprint [1,3]x[1,3]), block B =
    // i,j in [6,8) (footprint [6,8]x[6,8]) -- far apart, share no vertices.
    auto m = hfGridMesh(10, 10, 1.0f);
    auto mask = new bool[](100);
    foreach (j; 1 .. 3) foreach (i; 1 .. 3) mask[j * 10 + i] = true;
    foreach (j; 6 .. 8) foreach (i; 6 .. 8) mask[j * 10 + i] = true;

    const patchA = buildPath(tempDir(), "vibe3d_remesh_test_2block_patchA.obj");
    const patchB = buildPath(tempDir(), "vibe3d_remesh_test_2block_patchB.obj");
    scope(exit) { tryRemove(patchA); tryRemove(patchB); }
    write(patchA, hfGridPatchText(4, 4, 0.5f, 1.0f, 1.0f)); // finer grid over [1,3]x[1,3]
    write(patchB, hfGridPatchText(4, 4, 0.5f, 6.0f, 6.0f)); // finer grid over [6,8]x[6,8]

    const script = buildPath(tempDir(), "vibe3d_remesh_fake_2block.sh");
    scope(exit) tryRemove(script);
    // Block A's own corner vertex line ("v 1.000000 1.000000 0.000000")
    // never appears in block B's input OBJ (max coord 3 < 6) and vice
    // versa, so this is an unambiguous per-component dispatch key.
    hfWriteDispatchScript(script, ["1.000000 1.000000"], [patchA], patchB);

    environment["VIBE3D_AUTOREMESHER_BIN"] = script;
    scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

    auto job = new RemeshJob();
    job.start(m, RemeshParams(), mask);
    assert(job.busy());
    hfWaitUntilDone(job, 8.seconds);
    assert(job.state() == RemeshJob.State.succeeded, job.message());
    assert(job.message().length == 0,
           "both components succeeding cleanly must carry no partial-success note: " ~ job.message());

    auto resultFaces = job.resultFaces();
    assert(hfCountNonManifold(resultFaces) == 0, "introduced non-manifold edges must be 0");
    assert(hfCountOrientationDefects(resultFaces) == 0, "both seams must be consistently wound");

    uint[][] origFaces;
    foreach (fi; 0 .. m.faces.length) origFaces ~= m.faces[fi].dup;
    assert(hfBoundaryEdgeSet(resultFaces) == hfBoundaryEdgeSet(origFaces),
           "stitched mesh's boundary-edge set must equal the original mesh's (both blocks)");

    job.clear();
}

version (Posix)
unittest {
    // Task 0386, case (c): of TWO disjoint selected blocks, one gets a
    // patch the stitch can never accept (positioned nowhere near its
    // region boundary -- fails BOTH open-patch and triangle attempts) while
    // the other succeeds normally. The job must still reach `succeeded`
    // (partial success), the failed component's ORIGINAL faces must remain
    // completely unchanged in the result, and the overall mesh must stay
    // manifold.
    import std.file : write;
    import std.algorithm.searching : canFind;
    import core.time : seconds;

    auto m = hfGridMesh(10, 10, 1.0f);
    auto mask = new bool[](100);
    foreach (j; 1 .. 3) foreach (i; 1 .. 3) mask[j * 10 + i] = true; // block A -- will succeed
    foreach (j; 6 .. 8) foreach (i; 6 .. 8) mask[j * 10 + i] = true; // block B -- will be skipped

    const patchGood = buildPath(tempDir(), "vibe3d_remesh_test_skip_good.obj");
    const patchBad  = buildPath(tempDir(), "vibe3d_remesh_test_skip_bad.obj");
    scope(exit) { tryRemove(patchGood); tryRemove(patchBad); }
    write(patchGood, hfGridPatchText(4, 4, 0.5f, 1.0f, 1.0f));  // matches block A's footprint
    write(patchBad,  hfGridPatchText(4, 4, 0.5f, 50.0f, 50.0f)); // nowhere near block B's rim

    const script = buildPath(tempDir(), "vibe3d_remesh_fake_skip.sh");
    scope(exit) tryRemove(script);
    // Block A's marker -> good patch (every attempt); anything else
    // (block B, both open-patch AND triangle attempts) -> the bad patch,
    // so block B fails identically on both tries and must be skipped.
    hfWriteDispatchScript(script, ["1.000000 1.000000"], [patchGood], patchBad);

    environment["VIBE3D_AUTOREMESHER_BIN"] = script;
    scope(exit) environment.remove("VIBE3D_AUTOREMESHER_BIN");

    // Block B's ORIGINAL face vertex-lists (untouched -- must survive
    // verbatim in the result once skipped).
    uint[][] blockBOrigFaces;
    foreach (j; 6 .. 8) foreach (i; 6 .. 8) blockBOrigFaces ~= m.faces[j * 10 + i].dup;
    assert(blockBOrigFaces.length == 4);

    auto job = new RemeshJob();
    job.start(m, RemeshParams(), mask);
    assert(job.busy());
    hfWaitUntilDone(job, 10.seconds);
    assert(job.state() == RemeshJob.State.succeeded,
           "one good + one unstitchable component must still be a partial success: " ~ job.message());
    assert(job.message().length > 0, "a partial success must carry a non-fatal note");
    assert(job.message().canFind("1") && job.message().canFind("2"),
           "the note should mention 1 (succeeded) of 2 (total) components: " ~ job.message());

    auto resultFaces = job.resultFaces();
    assert(hfCountNonManifold(resultFaces) == 0,
           "the mesh must stay manifold even with one component skipped");

    foreach (bf; blockBOrigFaces) {
        bool found = false;
        foreach (rf; resultFaces) if (rf == bf) { found = true; break; }
        assert(found, "a skipped component's original faces must survive unchanged in the result");
    }

    job.clear();
}
