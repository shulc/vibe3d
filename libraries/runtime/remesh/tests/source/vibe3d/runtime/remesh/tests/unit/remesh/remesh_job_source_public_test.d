module vibe3d.runtime.remesh.tests.unit.remesh.remesh_job_source_public_test;

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
import vibe3d.mesh.core.mesh : Mesh, edgeKey;
import vibe3d.util.math.math : Vec3;
import vibe3d.runtime.remesh.remesh.region_stitch : stitchRegion, StitchResult;
import std.file : remove;
import std.algorithm.iteration : splitter;
import std.array : appender;
import core.thread : Thread;
import core.time   : msecs;
import std.file : write, setAttributes;
import std.conv : octal;
import vibe3d.runtime.remesh.remesh.remesh_job;

import vibe3d.mesh.change.mesh_dirty : MeshTermGeomEpoch, noteMeshChange;
import vibe3d.runtime.remesh.remesh.remesh_job : tryRemove;


version (Posix)
unittest {
    // Full RemeshJob lifecycle (success / failure / cancel), driven through
    // VIBE3D_AUTOREMESHER_BIN pointed at tiny throwaway shell scripts —
    // never the real (heavy, environment-specific) autoremesher_cli.
    import std.file : write, setAttributes, remove;
    import std.conv : octal;
    import core.thread : Thread;
    import core.time : Duration, msecs, seconds;
    import vibe3d.mesh.change.change_bus : MeshEditScope;

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
        assert(job.sourceMatches(m),
               "a running job must recognize the exact mesh snapshot it captured");
        auto replacement = cube();
        assert(!job.sourceMatches(replacement),
               "equal counters on another mesh address must not alias the source");
        m.vertices[0].x += 0.25f;
        // A bare module test has no app-owned ChangeBus subscriber forwarding
        // deliveries into mesh_dirty. Drive that listener body directly, as
        // mesh_dirty's headless-test contract requires.
        noteMeshChange(cast(size_t) &m, MeshEditScope.Position);
        assert(!job.sourceMatches(m),
               "a version-silent position publication must stale the source snapshot");
        waitUntilDone(job, 5.seconds);
        assert(job.state() == RemeshJob.State.succeeded);
        assert(job.resultVertices().length == 4);
        assert(job.resultFaces().length == 1);
        assert(job.resultFaces()[0].length == 4);
        job.clear();
        assert(job.state() == RemeshJob.State.idle);
        assert(job.resultVertices().length == 0);
        assert(!job.sourceMatches(m), "clear must invalidate the captured source");
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

    private int[ulong] hfEdgeUseCounts(const(uint[])[] faces) {
        int[ulong] ec;
        foreach (f; faces) {
            const size_t n = f.length;
            foreach (k; 0 .. n) {
                ulong key = edgeKey(f[k], f[(k + 1) % n]);
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
