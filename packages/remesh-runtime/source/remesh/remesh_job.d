module remesh.remesh_job;

// ---------------------------------------------------------------------------
// RemeshJob — a crash-isolated, per-frame-polled quad-remesh job.
//
// Native runs `autoremesher_cli` as a subprocess. Web runs the same CLI and
// core in an independent wasm instance inside a disposable Web Worker. Either
// boundary contains geogram aborts, which a thread sharing the editor's
// address space could not. app.d calls non-blocking poll() once per frame.
// Marshalling remains via OBJ files in each instance's filesystem.
//
// Lifecycle mirrors ai3d.job_controller's shape (start / poll~drain /
// cancel) but is simpler: no HTTP; completion is a single per-frame poll
// instead of an event queue.
//
// Corner-provenance (task 0901, `CornerDrop.ForeignTopology`): verified NOT
// APPLICABLE anywhere in this module. Every intermediate `Mesh` value here
// (e.g. `prepareCurrentComponent`'s `regionMesh`) is a fresh `Mesh.init` used
// as a scratch topology helper and never registers a PolyVertex map; the
// external subprocess's result comes back through OBJ marshalling as raw
// vertex/face data (`resultVertices()`/`resultFaces()`), not a `Mesh`. The
// document mesh is only ever touched once, by the landing command
// (`commands/mesh/remesh.d`'s `*mesh = result`) — see that site's own note.
// ---------------------------------------------------------------------------

import std.algorithm.iteration : map;
import std.algorithm.sorting   : sort;
import std.array   : array, split;
import std.conv    : to;
import std.file    : exists, tempDir, mkdirRecurse, rmdirRecurse, readText, thisExePath;
import std.path    : buildPath, expandTilde, dirName;
version (web) {
    version (Emscripten) {
        private extern(C) int vibe3d_web_remesh_start(const(char)* path,
            const(char)* output, const(char)* log, int mode, int target,
            double adaptivity, double sharp);
        private extern(C) int vibe3d_web_remesh_poll();
        private extern(C) void vibe3d_web_remesh_cancel();
    } else {
        private int vibe3d_web_remesh_start(const(char)*, const(char)*,
            const(char)*, int, int, double, double) { return 0; }
        private int vibe3d_web_remesh_poll() { return -1; }
        private void vibe3d_web_remesh_cancel() {}
    }
} else {
    import std.process : Pid, spawnProcess, tryWait, kill, wait, environment, thisProcessID;
}
version (unittest) import std.process : environment;
import std.stdio   : File, stdin;
import std.string  : strip;
import core.time   : MonoTime, Duration;

import mesh : Mesh, MeshKey, MeshTermMutation, edgeKey;
import mesh_dirty : MeshTermGeomEpoch, noteMeshChange;
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

    // The helper receives a position-dependent snapshot. The address keeps a
    // replacement mesh from aliasing the source; the geometry epoch covers
    // version-silent interactive movement; the mutation counter covers
    // committed changes, including scratch meshes outside the change bus.
    alias SourceKey = MeshKey!(MeshTermGeomEpoch, MeshTermMutation);

    private State  state_ = State.idle;
    private SourceKey sourceKey_;
    private string message_;
    version (web) {
    } else {
        private Pid  pid_;
        private bool hasPid_;
    }
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

    /// Whether the live mesh is still the exact source snapshot this job was
    /// started from. A completed result must be checked before entering any
    /// command path with pre-apply side effects.
    bool sourceMatches(ref const Mesh mesh) const {
        return sourceKey_.matches(mesh);
    }

    /// Reset to idle and drop the last result. Called by the consumer once
    /// it has read (and cached, if it needs the data to survive past this
    /// call) resultVertices()/resultFaces().
    void clear() {
        state_   = State.idle;
        message_ = null;
        resultVertices_ = null;
        resultFaces_    = null;
        sourceKey_.invalidate();
    }

    /// Start the helper against `mesh`. No-op if a job is already running
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

        sourceKey_.stamp(mesh);

        const p = sanitizeParams(rawParams);
        paramsTargetQuads_ = p.targetQuads;
        paramsAdaptivity_  = p.adaptivity;
        paramsSharpEdge_   = p.sharpEdge;

        version (web) auto bin = "web-worker";
        else auto bin = locateHelper();
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
            version (web) enum processTag = "web";
            else auto processTag = thisProcessID.to!string;
            dir = buildPath(tempDir(), "vibe3d_remesh_" ~ processTag ~ "_"
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

            version (web) {
                import std.string : toStringz;
                if (!vibe3d_web_remesh_start(inPath.toStringz,
                        outPath.toStringz, logPath.toStringz, 0,
                        paramsTargetQuads_, paramsAdaptivity_, paramsSharpEdge_)) {
                    cleanupFiles();
                    state_ = State.failed;
                    message_ = "failed to start remesh worker";
                    return;
                }
                state_ = State.running;
                message_ = null;
                return;
            } else {
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
        version (web) {
            import std.string : toStringz;
            if (!vibe3d_web_remesh_start(regionInPath_.toStringz,
                    outPath_.toStringz, logPath_.toStringz, attempt,
                    paramsTargetQuads_, paramsAdaptivity_, paramsSharpEdge_))
                return false;
            regionAttempt_ = attempt;
            state_ = State.running;
            return true;
        } else {
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
    }

    /// Non-blocking — call once per frame. Transitions running -> succeeded
    /// or running -> failed once the helper has finished; a no-op
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

        struct WaitResult { bool terminated; int status; }
        WaitResult w;
        version (web) {
            auto status = vibe3d_web_remesh_poll();
            w.terminated = status != 0;
            w.status = status == 1 ? 0 : 1;
        } else {
        try {
            auto result = tryWait(pid_);
            w.terminated = result.terminated;
            w.status = result.status;
        } catch (Exception e) {
            state_   = State.failed;
            message_ = "tryWait failed: " ~ e.msg;
            cleanupFiles();
            return;
        }
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

    /// Cooperative cancel: terminate the helper, clean up temp
    /// files, and drop back to idle. No-op if not running.
    void cancel() {
        if (state_ != State.running) return;
        version (web) vibe3d_web_remesh_cancel();
        else {
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
        }
        cleanupFiles();
        state_   = State.idle;
        message_ = null;
        sourceKey_.invalidate();
    }

    private void cleanupFiles() {
        if (logFile_.isOpen) try logFile_.close(); catch (Exception) {}
        if (workDir_.length && exists(workDir_)) {
            try rmdirRecurse(workDir_); catch (Exception) {}
        }
        workDir_ = null;
        outPath_ = null;
        logPath_ = null;
        version (web) {} else hasPid_ = false;
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
version (web) {} else private string locateHelper() {
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
version (unittest) public void tryRemove(string path) nothrow {
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
