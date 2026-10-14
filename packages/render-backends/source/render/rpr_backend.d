/// RPR (AMD Radeon ProRender) implementation of `RenderBackend`.
///
/// Phase 2 / M2 status:
///   - CPU device only (Northstar HIP/OpenCL paths broken on this dev box —
///     NVIDIA RTX 3070 Ti, see doc/renderer_choice_plan.md Phase 0 status).
///   - Diffuse-only materials: `CompiledMaterial.baseColor` → RPR_MATERIAL_NODE_DIFFUSE.
///     The other Principled channels (metallic, IOR, emission, transmission)
///     are ignored — M3 swaps DIFFUSE for UberV2 with the full mapping.
///   - Lights: Point + Sun (→ DirectionalLight) + Spot (cone via SetConeShape) +
///     Area (emissive quad mesh) covered. Mesh-light kind falls back to Area
///     since LightDesc doesn't carry a mesh reference yet. Environment is
///     handled via setEnvironment, not uploadLight.
///   - Environment: Solid color via 1×1 RGBA32F constant image; HDRI via
///     `rprContextCreateImageFromFile`. Either drives a single env-light
///     attached to the scene.
///   - Camera: perspective (FOV → sensor/focal-length), orthographic
///     (default 4-unit ortho width — vibe3d's CameraDesc carries no explicit
///     ortho-width yet), DOF via FocusDistance + FStop (heuristic mapping).
///   - Async IPR loop (M3): a worker thread holds `sceneMtx` while it calls
///     `rprContextRender` + resolve + read, then publishes the pixel buffer
///     into the main-thread-visible `pixelCache` under a separate brief
///     `pixelMtx`. `tick()` is a no-op; the worker accumulates autonomously.
///     `grabPixels` reads from `pixelCache` only — no RPR calls on the main
///     thread, so the UI never blocks on a sample. Mutators (`uploadXxx`,
///     `setCamera`, `setEnvironment`, `resetAccumulation`) acquire
///     `sceneMtx`, which means they wait for the current sample to finish
///     (~tens of ms on CPU at small res). Scene changes are debounced
///     upstream so this is acceptable in practice.
///   - `tryBindGLTexture` always returns false; zero-copy interop is IPR-opt 4.
module render.rpr_backend;

version (WithRender):

import std.string         : toStringz, indexOf;
import std.format         : format;
import std.file           : exists, dirEntries, SpanMode, thisExePath;
import std.path           : buildPath, dirName, expandTilde;
import std.process        : environment;
import std.math           : tan, sqrt;
import core.thread        : Thread, msecs;
import core.sync.mutex    : Mutex;
import core.atomic        : atomicLoad, atomicStore, atomicOp;

import bindbc.rpr;

import render.backend;
import math : Vec3;

// ---------------------------------------------------------------------------
// Process-global Northstar plugin id. RPR rejects re-registration of the
// same plugin path inside a process, so we cache the id across init cycles.
// ---------------------------------------------------------------------------

private __gshared rpr_int g_pluginId = -1;

// ---------------------------------------------------------------------------
// Platform-specific RPR SDK layout. Plugin filename and the bundled-SDK
// subdir vary across OSes; the search-order helpers below stitch them
// in. Everything stays gated by `version (WithRender)` at the module
// level, so the modeling build sees none of this code.
// ---------------------------------------------------------------------------

version (linux) {
    private enum string kNorthstarFile = "libNorthstar64.so";
    private enum string kSdkSubdir     = "binUbuntu20";
} else version (OSX) {
    private enum string kNorthstarFile = "libNorthstar64.dylib";
    private enum string kSdkSubdir     = "binMacOS";
} else version (Windows) {
    private enum string kNorthstarFile = "Northstar64.dll";
    private enum string kSdkSubdir     = "binWin64";
} else {
    private enum string kNorthstarFile = "libNorthstar64.so";
    private enum string kSdkSubdir     = "binUbuntu20";
}

/// Probe the filesystem for the Northstar plugin. Returns the first
/// match in this order:
///   1. `VIBE3D_RPR_PLUGIN_PATH` env (explicit override, honoured
///      without further probing).
///   2. `<exeDir>/rpr/<kNorthstarFile>` (release-zip layout).
///   3. `~/Code/D-RadeonProRender/extern/RadeonProRenderSDK/RadeonProRender/<subdir>/<file>`
///      (the dev-machine convention: vibe3d + D-RadeonProRender are
///      siblings under ~/Code).
///   4. `~/.dub/packages/bindbc-rpr/*/bindbc-rpr/extern/RadeonProRenderSDK/RadeonProRender/<subdir>/<file>`
///      (dub git-clone cache; covers `dub build --config=with-render`
///      against the git-spec dep without a sibling working tree).
///
/// `tried[]` collects every candidate path inspected so the failure
/// message can list them.
private string resolveNorthstarPath(out string[] tried)
{
    if (auto p = environment.get("VIBE3D_RPR_PLUGIN_PATH")) {
        tried ~= p ~ "  [VIBE3D_RPR_PLUGIN_PATH]";
        if (exists(p)) return p;
    }
    try {
        const exeDir = thisExePath().dirName;
        const beside = buildPath(exeDir, "rpr", kNorthstarFile);
        tried ~= beside;
        if (exists(beside)) return beside;
    } catch (Exception) {}
    // Dev-tree probes: ~/Code/ (canonical) and ~/Documents/GitHub/ (Windows convention).
    // expandTilde is unreliable on Windows — use USERPROFILE directly.
    string homeDir = expandTilde("~");
    version (Windows) {
        if (auto up = environment.get("USERPROFILE")) homeDir = up;
    }
    foreach (rel; ["Code/D-RadeonProRender", "Documents/GitHub/D-RadeonProRender"]) {
        const dev = buildPath(homeDir, rel,
            "extern/RadeonProRenderSDK/RadeonProRender",
            kSdkSubdir, kNorthstarFile);
        tried ~= dev;
        if (exists(dev)) return dev;
    }
    // dub cache probes: ~/.dub/packages/ (Linux/macOS) and
    // %LOCALAPPDATA%/dub/packages/ (Windows).
    string[] dubBases = [buildPath(homeDir, ".dub", "packages", "bindbc-rpr")];
    version (Windows) {
        if (auto la = environment.get("LOCALAPPDATA"))
            dubBases ~= buildPath(la, "dub", "packages", "bindbc-rpr");
    }
    foreach (dubBase; dubBases) {
        if (!exists(dubBase)) continue;
        try {
            foreach (e; dirEntries(dubBase, SpanMode.shallow)) {
                if (!e.isDir) continue;
                const candidate = buildPath(e.name, "bindbc-rpr",
                    "extern/RadeonProRenderSDK/RadeonProRender",
                    kSdkSubdir, kNorthstarFile);
                tried ~= candidate;
                if (exists(candidate)) return candidate;
            }
        } catch (Exception) {}
    }
    return null;
}

/// Same probe shape, but for the precompiled HIP kernel directory.
/// Northstar reads this via `RPR_CONTEXT_PRECOMPILED_BINARY_PATH`;
/// when not found, init still proceeds (Northstar silently ignores
/// the property if the path is empty or doesn't exist — CPU rendering
/// works regardless; HIP/GPU paths just lose their precompiled binary
/// cache and fall back to runtime compile or fail at GPU init).
private string resolveHipbinPath()
{
    if (auto p = environment.get("VIBE3D_RPR_HIPBIN")) {
        if (exists(p)) return p;
    }
    try {
        const exeDir = thisExePath().dirName;
        const beside = buildPath(exeDir, "rpr", "hipbin");
        if (exists(beside)) return beside;
    } catch (Exception) {}
    string homeDir2 = expandTilde("~");
    version (Windows) {
        if (auto up = environment.get("USERPROFILE")) homeDir2 = up;
    }
    foreach (rel; ["Code/D-RadeonProRender", "Documents/GitHub/D-RadeonProRender"]) {
        const dev = buildPath(homeDir2, rel, "extern/RadeonProRenderSDK/hipbin");
        if (exists(dev)) return dev;
    }
    string[] dubBases = [buildPath(homeDir2, ".dub", "packages", "bindbc-rpr")];
    version (Windows) {
        if (auto la = environment.get("LOCALAPPDATA"))
            dubBases ~= buildPath(la, "dub", "packages", "bindbc-rpr");
    }
    foreach (dubBase; dubBases) {
        if (!exists(dubBase)) continue;
        try {
            foreach (e; dirEntries(dubBase, SpanMode.shallow)) {
                if (!e.isDir) continue;
                const candidate = buildPath(e.name, "bindbc-rpr",
                    "extern/RadeonProRenderSDK/hipbin");
                if (exists(candidate)) return candidate;
            }
        } catch (Exception) {}
    }
    return null;
}

// ---------------------------------------------------------------------------
// RPRBackend
// ---------------------------------------------------------------------------

class RPRBackend : RenderBackend
{
    // ID allocator. RPR doesn't need a Blueprint-rebuild pattern like Cycles
    // — its objects can be mutated in place inside the live context, so the
    // bridge's MeshId/MaterialId/LightId map directly to RPR handles.
    private ulong nextId = 1;

    // Live RPR handles.
    private rpr_context         ctx;
    private rpr_scene           scn;
    private rpr_camera          cam;
    private rpr_material_system matsys;
    private rpr_framebuffer     fbColor;
    private rpr_framebuffer     fbResolved;

    // Scene-id → RPR handle.
    private rpr_shape[ulong]         meshShapes;
    private rpr_material_node[ulong] matNodes;
    private rpr_light[ulong]         lightObjs;

    // Pending mesh ↔ material binding. Applied immediately if both sides
    // exist; otherwise replayed when the missing side is uploaded
    // (assignMaterial → uploadTriMesh, or the reverse).
    private ulong[ulong] meshMatMap;

    // Per-mesh face-count scratch (3s) kept alive while the shape lives —
    // RPR's createMesh requires a num_face_vertices array; we own its memory.
    // Per-mesh entry so successive uploads don't blow each other away.
    private rpr_int[][ulong] meshFvCounts;

    // Per-mesh generated flat-normal buffers (kept alive while the shape
    // lives). Empty for meshes whose caller supplied normals.
    private float[][ulong]   meshGenNormals;
    private rpr_int[][ulong] meshGenNIdx;

    // Area lights are emissive quad meshes — keep per-light side data
    // alive while the light handle lives (RPR may retain pointers).
    private rpr_shape[ulong]         areaShapes;
    private rpr_material_node[ulong] areaMats;
    private float[][ulong]           areaXyz;
    private float[][ulong]           areaNormals;
    private rpr_int[][ulong]         areaTris;
    private rpr_int[][ulong]         areaNIdx;
    private rpr_int[][ulong]         areaFvCounts;

    // Environment light state. setEnvironment destroys + recreates.
    private rpr_light envLight;
    private rpr_image envImage;

    // Display state.
    private int     fbW = 512;
    private int     fbH = 384;
    private bool    fbReady;
    private BackendConfig cfg;

    // M3 async pipeline. Worker thread owns rprContextRender + resolve +
    // read; main thread reads only `pixelCache` (a stable snapshot copied
    // out by the worker after each sample). sceneMtx serializes ALL RPR
    // object calls (render, resolve, read, uploads, setCamera, ...);
    // pixelMtx is brief (memcpy-only) so main never waits on the worker.
    private Thread       worker;
    private Mutex        sceneMtx;
    private Mutex        pixelMtx;
    private shared int   workerStop;       // 0 = run, 1 = stop
    private shared int   samplesAccum;
    private shared ulong verCounter;
    private float[]      pixelCache;       // owned by worker via pixelMtx
    private int          cachedW;
    private int          cachedH;
    private float[]      pixelReadOut;     // owned by main; stable buffer
                                            // returned to callers of grabPixels

    private string lastErrorMsg;

    // -----------------------------------------------------------------------
    // RenderBackend — identity
    // -----------------------------------------------------------------------

    string name() { return "rpr"; }
    string lastError() { return lastErrorMsg; }

    BackendCaps caps()
    {
        BackendCaps c;
        c.supportsGLInterop = false;   // M1; IPR-opt 4 wires this
        c.supportsOSL       = false;
        c.supportsMDL       = true;    // RPR native, no UI yet
        c.supportsAreaLight = true;
        c.supportsSunLight  = true;
        c.supportsHDRI      = true;
        c.maxLights         = 1024;
        return c;
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    bool init(in BackendConfig c)
    {
        cfg = c;

        // Resolve the Northstar plugin BEFORE loadRPR so we know which
        // directory to put on the dynamic-loader search path. bindbc-rpr's
        // build-time rpath is baked to the package's checkout location at
        // link time — that path is meaningless on any other machine
        // (release zip, CI runner, relocated dev tree). Adding the
        // resolved SDK dir to LD_LIBRARY_PATH / DYLD_LIBRARY_PATH / PATH
        // makes `dlopen("libRadeonProRender64.*")` find the right sibling
        // shared library without re-linking.
        string[] tried;
        const pluginPath = (g_pluginId == -1)
            ? resolveNorthstarPath(tried)
            : null;
        if (g_pluginId == -1 && pluginPath is null) {
            string msg = "Northstar plugin not found. Searched:\n";
            foreach (p; tried) msg ~= "  " ~ p ~ "\n";
            msg ~= "Set VIBE3D_RPR_PLUGIN_PATH=<path/to/" ~ kNorthstarFile
                 ~ "> to override.";
            return setError(msg);
        }
        if (pluginPath !is null) {
            const sdkDir = pluginPath.dirName;
            version (linux)        enum string ldEnvName = "LD_LIBRARY_PATH";
            else version (OSX)     enum string ldEnvName = "DYLD_LIBRARY_PATH";
            else version (Windows) enum string ldEnvName = "PATH";
            else                   enum string ldEnvName = "LD_LIBRARY_PATH";
            const existing = environment.get(ldEnvName, "");
            version (Windows) enum string sep = ";";
            else              enum string sep = ":";
            if (existing.length == 0)
                environment[ldEnvName] = sdkDir;
            else if (existing.indexOf(sdkDir) < 0)
                environment[ldEnvName] = sdkDir ~ sep ~ existing;
        }

        if (!isRPRLoaded()) {
            if (loadRPR() != RPRSupport.loaded)
                return setError("loadRPR: libRadeonProRender64 not loadable "
                              ~ "(plugin found at " ~ (pluginPath !is null ? pluginPath : "<none>")
                              ~ ", but the sibling shared library couldn't be dlopen'd).");
        }

        if (g_pluginId == -1) {
            g_pluginId = rprRegisterPlugin(pluginPath.toStringz);
            if (g_pluginId == -1)
                return setError("rprRegisterPlugin returned -1 for " ~ pluginPath);
        }

        rpr_int[1] plugins = [g_pluginId];

        // Precompiled HIP kernels location for Northstar. Optional —
        // CPU rendering works without it; GPU paths need it to skip a
        // (slow) runtime kernel compile. Pass null when the probe
        // fails so Northstar silently omits the property.
        const hipbin = resolveHipbinPath();
        const(char)* hipbinZ = (hipbin is null) ? null : hipbin.toStringz;
        rpr_context_properties[3] ctxProps = [
            cast(rpr_context_properties) RPR_CONTEXT_PRECOMPILED_BINARY_PATH,
            cast(rpr_context_properties) hipbinZ,
            cast(rpr_context_properties) null,
        ];

        // cfg.device is interpreted loosely:
        //   "cpu" / "auto" / default → CPU
        //   "gpu"                    → HIP GPU0
        //   "opencl"                 → GPU0 + OpenCL fallback
        //
        // M6 — soft fallback to CPU when the requested non-CPU device
        // returns an init error code (e.g. HybridPro → RPR_ERROR_INTERNAL
        // on NVIDIA). Hard failures (HIP's adl::DeviceHIP::initialize
        // SIGSEGV on NVIDIA RTX 3070 Ti, OpenCL's Tahoe::Exception kernel-
        // compile crash) still kill the process — those paths are hidden
        // from the IPR dropdown by default and only surface with the
        // user opt-in `VIBE3D_RPR_ALLOW_GPU=1` env (see render_mvp.d).
        rpr_creation_flags flags;
        switch (cfg.device) {
            case "gpu":    flags = RPR_CREATION_FLAGS_ENABLE_GPU0;                                  break;
            case "opencl": flags = RPR_CREATION_FLAGS_ENABLE_GPU0 | RPR_CREATION_FLAGS_ENABLE_OPENCL; break;
            default:       flags = RPR_CREATION_FLAGS_ENABLE_CPU;                                   break;
        }
        const bool wantNonCpu = (flags & RPR_CREATION_FLAGS_ENABLE_CPU) == 0;

        auto firstSt = rprCreateContext(RPR_VERSION_MAJOR_MINOR_REVISION,
                                        plugins.ptr, plugins.length,
                                        flags, ctxProps.ptr, null, &ctx);
        if (firstSt && wantNonCpu) {
            // Recoverable: retry on CPU and log so the user knows the
            // dropdown choice didn't survive.
            import log        : logWarn;
            import std.format : format;
            try {
                logWarn("render", format(
                    "rpr: non-CPU device %s init failed (rpr_status=%d); "
                    ~ "falling back to CPU. Set VIBE3D_RPR_ALLOW_GPU=1 only "
                    ~ "on AMD or HIP-on-CUDA hosts; on NVIDIA this fallback "
                    ~ "is the safe default.",
                    cfg.device, firstSt));
            } catch (Exception) {}
            cfg.device = "cpu";
            if (auto st = rprCreateContext(RPR_VERSION_MAJOR_MINOR_REVISION,
                                           plugins.ptr, plugins.length,
                                           RPR_CREATION_FLAGS_ENABLE_CPU,
                                           ctxProps.ptr, null, &ctx))
                return setError("rprCreateContext (CPU fallback)", st);
        } else if (firstSt) {
            return setError("rprCreateContext", firstSt);
        }
        if (auto st = rprContextSetActivePlugin(ctx, g_pluginId))
            return setError("rprContextSetActivePlugin", st);

        if (auto st = rprContextCreateScene(ctx, &scn))
            return setError("rprContextCreateScene", st);
        if (auto st = rprContextSetScene(ctx, scn))
            return setError("rprContextSetScene", st);

        if (auto st = rprContextCreateCamera(ctx, &cam))
            return setError("rprContextCreateCamera", st);
        if (auto st = rprSceneSetCamera(scn, cam))
            return setError("rprSceneSetCamera", st);

        if (auto st = rprContextCreateMaterialSystem(ctx, 0, &matsys))
            return setError("rprContextCreateMaterialSystem", st);

        if (!createFramebuffers(fbW, fbH))
            return false;

        // One iteration per rprContextRender call → progressive accumulation
        // driven by the worker loop's tight cycle of (render → resolve →
        // read → publish).
        if (auto st = rprContextSetParameterByKey1u(
                ctx, RPR_CONTEXT_ITERATIONS, 1))
            return setError("rprContextSetParameterByKey1u(ITERATIONS)", st);
        if (auto st = rprContextSetParameterByKey1f(
                ctx, RPR_CONTEXT_DISPLAY_GAMMA, 2.2f))
            return setError("rprContextSetParameterByKey1f(GAMMA)", st);

        // Spawn the async render worker LAST — everything above must be
        // initialized before the worker starts asking for sceneMtx.
        sceneMtx = new Mutex();
        pixelMtx = new Mutex();
        atomicStore(workerStop, 0);
        atomicStore(samplesAccum, 0);
        atomicStore(verCounter,   0UL);
        worker = new Thread(&workerLoop);
        worker.isDaemon = true;
        worker.start();
        return true;
    }

    void shutdown()
    {
        // Stop + join the worker BEFORE destroying any RPR object. The
        // worker may be inside rprContextRender right now — abort it from
        // here to keep teardown fast. RPR's docs say rprContextAbortRender
        // is safe from a thread other than the renderer.
        if (worker !is null) {
            atomicStore(workerStop, 1);
            if (ctx !is null) rprContextAbortRender(ctx);
            worker.join();
            worker = null;
        }
        sceneMtx = null;
        pixelMtx = null;

        foreach (h; lightObjs.byValue)   rprObjectDelete(h);
        foreach (h; matNodes.byValue)    rprObjectDelete(h);
        foreach (h; meshShapes.byValue)  rprObjectDelete(h);
        foreach (h; areaShapes.byValue)  rprObjectDelete(h);
        foreach (h; areaMats.byValue)    rprObjectDelete(h);
        lightObjs       = null;
        matNodes        = null;
        meshShapes      = null;
        meshMatMap      = null;
        meshFvCounts    = null;
        meshGenNormals  = null;
        meshGenNIdx     = null;
        areaShapes      = null;
        areaMats        = null;
        areaXyz         = null;
        areaNormals     = null;
        areaTris        = null;
        areaNIdx        = null;
        areaFvCounts    = null;

        if (envLight   !is null) { rprObjectDelete(envLight);   envLight   = null; }
        if (envImage   !is null) { rprObjectDelete(envImage);   envImage   = null; }
        if (matsys     !is null) { rprObjectDelete(matsys);     matsys     = null; }
        if (cam        !is null) { rprObjectDelete(cam);        cam        = null; }
        if (fbColor    !is null) { rprObjectDelete(fbColor);    fbColor    = null; }
        if (fbResolved !is null) { rprObjectDelete(fbResolved); fbResolved = null; }
        if (scn        !is null) { rprObjectDelete(scn);        scn        = null; }
        if (ctx        !is null) { rprObjectDelete(ctx);        ctx        = null; }

        pixelCache    = null;
        pixelReadOut  = null;
        atomicStore(samplesAccum, 0);
        atomicStore(verCounter,   0UL);
        fbReady = false;
    }

    // -----------------------------------------------------------------------
    // Async render worker
    // -----------------------------------------------------------------------

    /// Background loop that drives RPR's progressive accumulation. Holds
    /// `sceneMtx` for the (render → resolve → read) span of each sample,
    /// then publishes the result into `pixelCache` under `pixelMtx`.
    /// Exits when `workerStop` flips to 1 (set by shutdown).
    private void workerLoop() nothrow
    {
        try {
            while (atomicLoad(workerStop) == 0) {
                // Cap reached? Sleep then re-check (cap may be raised
                // mid-render via setSamples).
                if (atomicLoad(samplesAccum) >= cfg.samples) {
                    Thread.sleep(20.msecs);
                    continue;
                }
                if (!fbReady) {
                    Thread.sleep(20.msecs);
                    continue;
                }
                if (!renderOneSample()) {
                    // Render failed or was aborted — backoff briefly so we
                    // don't spin against the same error.
                    Thread.sleep(50.msecs);
                    continue;
                }
                // Yield between samples. Without this the worker re-acquires
                // sceneMtx instantly, RPR's internal thread pool keeps every
                // CPU core saturated, and the main thread gets starved by
                // the scheduler (visible as "IPR panel UI freezes while
                // sampling"). 5 ms is barely visible in sample throughput
                // (~10% drop) but restores main-thread responsiveness.
                Thread.sleep(5.msecs);
            }
        } catch (Throwable t) {
            // Last-ditch swallow — worker death should never crash the
            // process; the next mutator will detect lastErrorMsg.
            try setError("workerLoop threw: " ~ t.msg);
            catch (Throwable) {}
        }
    }

    /// Acquire sceneMtx, render exactly one sample, resolve + read into a
    /// temp buffer, release sceneMtx, then publish under pixelMtx and
    /// bump the version counter. Returns false on render error.
    private bool renderOneSample()
    {
        sceneMtx.lock();
        scope (exit) sceneMtx.unlock();

        // Re-check guards inside the lock (state may have changed).
        if (atomicLoad(workerStop) != 0) return false;
        if (!fbReady) return false;
        if (atomicLoad(samplesAccum) >= cfg.samples) return false;

        if (auto st = rprContextRender(ctx)) {
            if (st != RPR_ERROR_ABORTED)
                setError("rprContextRender (worker)", st);
            return false;
        }
        atomicOp!"+="(samplesAccum, 1);

        // Resolve + read on this thread; the framebuffer is owned by
        // ctx and can only be safely touched under sceneMtx. We bake into
        // a freshly-allocated array (cheap on dmd) so swapping into
        // pixelCache below is just a slice assignment.
        if (auto st = rprContextResolveFrameBuffer(
                ctx, fbColor, fbResolved, RPR_FALSE)) {
            setError("rprContextResolveFrameBuffer (worker)", st);
            return false;
        }
        size_t need;
        if (auto st = rprFrameBufferGetInfo(
                fbResolved, RPR_FRAMEBUFFER_DATA, 0, null, &need)) {
            setError("rprFrameBufferGetInfo size (worker)", st);
            return false;
        }
        const size_t floatCount = need / float.sizeof;
        auto temp = new float[floatCount];
        if (auto st = rprFrameBufferGetInfo(
                fbResolved, RPR_FRAMEBUFFER_DATA, need, temp.ptr, null)) {
            setError("rprFrameBufferGetInfo data (worker)", st);
            return false;
        }
        const int wSnap = fbW;
        const int hSnap = fbH;

        // Publish.
        pixelMtx.lock();
        pixelCache = temp;
        cachedW    = wSnap;
        cachedH    = hSnap;
        pixelMtx.unlock();

        atomicOp!"+="(verCounter, 1UL);
        return true;
    }

    // -----------------------------------------------------------------------
    // Scene mutators
    // -----------------------------------------------------------------------

    MeshId uploadTriMesh(in float[] xyz, in float[] normals,
                          in float[] uv,  in int[]   tris)
    {
        if (ctx is null) return MeshId(0);
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();

        const size_t numVerts = xyz.length / 3;
        const size_t numTris  = tris.length / 3;
        if (numVerts == 0 || numTris == 0) return MeshId(0);

        const id = nextId++;

        // Attribute pointers + per-attribute index arrays. RPR allows
        // attribute-specific index streams, but the bridge gives us shared
        // indexing.
        const(rpr_int)* triPtr = cast(const(rpr_int)*) tris.ptr;

        // Normals — generate flat per-face normals when caller omits them.
        // Without normals, RPR's lighting integrators see undefined
        // (likely zero) shading-normals → Lambert response = 0 → black
        // render. The fallback gives each triangle one normal indexed
        // by the per-tri index 0..numTris-1.
        const bool hasInputNormals = normals.length >= numVerts * 3;

        float[]   genNormals;
        rpr_int[] genNIdx;
        const(float)* normalsPtr;
        size_t        numNormals;
        rpr_int       normalStride;
        const(rpr_int)* nIdxPtr;
        rpr_int         nIdxStride;
        if (hasInputNormals) {
            normalsPtr   = normals.ptr;
            numNormals   = numVerts;
            normalStride = 12;
            nIdxPtr      = triPtr;
            nIdxStride   = 4;
        } else {
            genNormals.length = numTris * 3;
            genNIdx.length    = numTris * 3;
            foreach (size_t f; 0 .. numTris) {
                const int i0 = tris[f * 3 + 0];
                const int i1 = tris[f * 3 + 1];
                const int i2 = tris[f * 3 + 2];
                const float ax = xyz[i1 * 3 + 0] - xyz[i0 * 3 + 0];
                const float ay = xyz[i1 * 3 + 1] - xyz[i0 * 3 + 1];
                const float az = xyz[i1 * 3 + 2] - xyz[i0 * 3 + 2];
                const float bx = xyz[i2 * 3 + 0] - xyz[i0 * 3 + 0];
                const float by = xyz[i2 * 3 + 1] - xyz[i0 * 3 + 1];
                const float bz = xyz[i2 * 3 + 2] - xyz[i0 * 3 + 2];
                float nx = ay * bz - az * by;
                float ny = az * bx - ax * bz;
                float nz = ax * by - ay * bx;
                import std.math : sqrt;
                const float len = sqrt(nx * nx + ny * ny + nz * nz);
                const float inv = len > 0 ? 1.0f / len : 0.0f;
                nx *= inv; ny *= inv; nz *= inv;
                genNormals[f * 3 + 0] = nx;
                genNormals[f * 3 + 1] = ny;
                genNormals[f * 3 + 2] = nz;
                genNIdx[f * 3 + 0] = cast(rpr_int) f;
                genNIdx[f * 3 + 1] = cast(rpr_int) f;
                genNIdx[f * 3 + 2] = cast(rpr_int) f;
            }
            normalsPtr   = genNormals.ptr;
            numNormals   = numTris;
            normalStride = 12;
            nIdxPtr      = genNIdx.ptr;
            nIdxStride   = 4;
            // Keep alive for the lifetime of the shape.
            meshGenNormals[id] = genNormals;
            meshGenNIdx[id]    = genNIdx;
        }

        const bool hasUV = uv.length >= numVerts * 2;
        const(float)* uvPtr   = hasUV ? uv.ptr   : null;
        const size_t  numUv   = hasUV ? numVerts : 0;
        const rpr_int uvStride = hasUV ? 8       : 0;
        const(rpr_int)* uIdxPtr    = hasUV ? triPtr : null;
        const rpr_int   uIdxStride = hasUV ? 4      : 0;

        // Per-face-vertex counts (all 3 for triangulated mesh). Owned by us;
        // RPR may keep a pointer to the array until the mesh is destroyed.
        auto fvCounts = new rpr_int[numTris];
        fvCounts[] = 3;
        meshFvCounts[id] = fvCounts;

        rpr_shape shape;
        if (auto st = rprContextCreateMesh(ctx,
                xyz.ptr,            numVerts, 12,
                normalsPtr,         numNormals, normalStride,
                uvPtr,              numUv, uvStride,
                triPtr,             4,
                nIdxPtr,            nIdxStride,
                uIdxPtr,            uIdxStride,
                fvCounts.ptr,       numTris,
                &shape)) {
            meshFvCounts.remove(id);
            meshGenNormals.remove(id);
            meshGenNIdx.remove(id);
            setError("rprContextCreateMesh", st);
            return MeshId(0);
        }
        if (auto st = rprSceneAttachShape(scn, shape)) {
            rprObjectDelete(shape);
            meshFvCounts.remove(id);
            setError("rprSceneAttachShape", st);
            return MeshId(0);
        }

        meshShapes[id] = shape;

        // Replay pending material assignment, if any.
        if (auto matIdP = id in meshMatMap) {
            if (auto matP = *matIdP in matNodes)
                rprShapeSetMaterial(shape, *matP);
        }

        return MeshId(id);
    }

    void destroyMesh(MeshId mid)
    {
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();
        if (auto p = mid.id in meshShapes) {
            rprSceneDetachShape(scn, *p);
            rprObjectDelete(*p);
            meshShapes.remove(mid.id);
        }
        meshMatMap.remove(mid.id);
        meshFvCounts.remove(mid.id);
        meshGenNormals.remove(mid.id);
        meshGenNIdx.remove(mid.id);
    }

    MaterialId uploadMaterial(in CompiledMaterial cm)
    {
        if (ctx is null) return MaterialId(0);
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();

        rpr_material_node node;
        if (auto st = rprMaterialSystemCreateNode(
                matsys, RPR_MATERIAL_NODE_DIFFUSE, &node)) {
            setError("rprMaterialSystemCreateNode(DIFFUSE)", st);
            return MaterialId(0);
        }
        // M1 maps baseColor only. Roughness/metallic/IOR/emission etc.
        // arrive in M3 with UberV2.
        if (auto st = rprMaterialNodeSetInputFByKey(
                node, RPR_MATERIAL_INPUT_COLOR,
                cm.baseColor.x, cm.baseColor.y, cm.baseColor.z, 1.0f)) {
            rprObjectDelete(node);
            setError("rprMaterialNodeSetInputFByKey(COLOR)", st);
            return MaterialId(0);
        }

        const id = nextId++;
        matNodes[id] = node;
        return MaterialId(id);
    }

    void assignMaterial(MeshId mid, MaterialId matId)
    {
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();
        meshMatMap[mid.id] = matId.id;
        if (auto sp = mid.id in meshShapes)
            if (auto mp = matId.id in matNodes)
                rprShapeSetMaterial(*sp, *mp);
    }

    LightId uploadLight(in LightDesc ld)
    {
        if (ctx is null) return LightId(0);
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();

        const id = nextId++;

        // Area + Mesh fold into "emissive quad" path. RPR has no separate
        // area-light type — the area light is just a shape with an
        // emissive material attached. LightDesc.transform places the quad
        // in world space; areaSizeX/Y give the rectangle dimensions.
        // Mesh-light kind reuses the area path because LightDesc doesn't
        // carry a mesh reference — when we add that field, Mesh routes to
        // its own shape lookup.
        if (ld.kind == LightDesc.Kind.Area
            || ld.kind == LightDesc.Kind.Mesh) {
            if (!createAreaLight(id, ld)) {
                nextId--;
                return LightId(0);
            }
            return LightId(id);
        }

        rpr_light L;
        const bool isSun  = (ld.kind == LightDesc.Kind.Sun);
        const bool isSpot = (ld.kind == LightDesc.Kind.Spot);

        if (isSun) {
            if (auto st = rprContextCreateDirectionalLight(ctx, &L)) {
                setError("rprContextCreateDirectionalLight", st);
                return LightId(0);
            }
        } else if (isSpot) {
            if (auto st = rprContextCreateSpotLight(ctx, &L)) {
                setError("rprContextCreateSpotLight", st);
                return LightId(0);
            }
        } else {
            if (auto st = rprContextCreatePointLight(ctx, &L)) {
                setError("rprContextCreatePointLight", st);
                return LightId(0);
            }
        }

        // vibe3d's LightDesc.transform is row-major (matches the Cycles
        // convention). RPR's internal layout is column-major, so we ask
        // it to transpose on ingest via the `transpose=RPR_TRUE` flag.
        if (auto st = rprLightSetTransform(L, RPR_TRUE, ld.transform.ptr)) {
            rprObjectDelete(L);
            setError("rprLightSetTransform", st);
            return LightId(0);
        }

        // Intensity → radiant power conversion. Cycles' light.strength is
        // a unitless multiplier; RPR's RadiantPower is in raw watts for
        // point + spot lights, W/m² for directional. Boost point/spot so
        // a Cycles-equivalent "intensity=3" reads as visible without
        // tonemapping. The constants are heuristic — M5 will calibrate.
        const float intensity = ld.intensity > 0 ? ld.intensity : 1.0f;
        enum float kSunScale   = 1.0f;    // already in W/m², leave alone
        enum float kPointScale = 40.0f;   // point→watts: ~60 W "bulb-bright"
        enum float kSpotScale  = 40.0f;
        const float scale = isSun ? kSunScale : (isSpot ? kSpotScale : kPointScale);
        const float r = ld.color.x * intensity * scale;
        const float g = ld.color.y * intensity * scale;
        const float b = ld.color.z * intensity * scale;

        rpr_status powerSt;
        if (isSun)       powerSt = rprDirectionalLightSetRadiantPower3f(L, r, g, b);
        else if (isSpot) powerSt = rprSpotLightSetRadiantPower3f(L, r, g, b);
        else             powerSt = rprPointLightSetRadiantPower3f(L, r, g, b);
        if (powerSt) {
            rprObjectDelete(L);
            setError("rpr*LightSetRadiantPower3f", powerSt);
            return LightId(0);
        }

        // Spot cone — vibe3d's spotAngle is the outer full cone angle,
        // spotBlend ∈ [0,1] is the fraction blended from inner to outer.
        // RPR's iangle/oangle are half-angles; inside iangle the light
        // is at full intensity, between iangle..oangle it falls off,
        // beyond oangle is dark.
        if (isSpot) {
            const float outer = ld.spotAngle * 0.5f;
            const float inner = outer * (1.0f - ld.spotBlend);
            if (auto st = rprSpotLightSetConeShape(L, inner, outer)) {
                rprObjectDelete(L);
                setError("rprSpotLightSetConeShape", st);
                return LightId(0);
            }
        }

        if (auto st = rprSceneAttachLight(scn, L)) {
            rprObjectDelete(L);
            setError("rprSceneAttachLight", st);
            return LightId(0);
        }

        lightObjs[id] = L;
        return LightId(id);
    }

    /// Build an Area-light (emissive quad) from a LightDesc. Spawns the
    /// shape + emissive material + scene attachments, registers all four
    /// for cleanup in destroyLight().
    private bool createAreaLight(ulong id, in LightDesc ld)
    {
        // Build a flat XY-plane quad (normal +Z in local space), centered
        // on origin, sized by areaSizeX × areaSizeY. The LightDesc
        // transform places it in world space.
        const float hx = (ld.areaSizeX > 0 ? ld.areaSizeX : 1.0f) * 0.5f;
        const float hy = (ld.areaSizeY > 0 ? ld.areaSizeY : 1.0f) * 0.5f;

        float[] xyz = [
            -hx, -hy, 0.0f,
             hx, -hy, 0.0f,
             hx,  hy, 0.0f,
            -hx,  hy, 0.0f,
        ];
        // Two CCW triangles; normal = +Z.
        rpr_int[] tris = [0, 1, 2,  0, 2, 3];
        float[]   nrm  = [0.0f, 0.0f, 1.0f];
        rpr_int[] nIdx = [0, 0, 0,  0, 0, 0];
        rpr_int[] fv   = [3, 3];

        rpr_shape shape;
        if (auto st = rprContextCreateMesh(ctx,
                xyz.ptr,  4, 12,
                nrm.ptr,  1, 12,
                null,     0, 0,
                tris.ptr, 4,
                nIdx.ptr, 4,
                null,     0,
                fv.ptr,   2,
                &shape)) {
            setError("rprContextCreateMesh(area)", st);
            return false;
        }

        // World transform for the shape — same convention as light
        // transforms (row-major, ask RPR to transpose).
        if (auto st = rprShapeSetTransform(shape, RPR_TRUE, ld.transform.ptr)) {
            rprObjectDelete(shape);
            setError("rprShapeSetTransform(area)", st);
            return false;
        }

        // Emissive material.
        rpr_material_node emis;
        if (auto st = rprMaterialSystemCreateNode(
                matsys, RPR_MATERIAL_NODE_EMISSIVE, &emis)) {
            rprObjectDelete(shape);
            setError("rprMaterialSystemCreateNode(EMISSIVE)", st);
            return false;
        }
        // Area-light "intensity" → emissive RGB. Boost so it visibly
        // illuminates without saturating; M5 will recalibrate.
        const float intensity = ld.intensity > 0 ? ld.intensity : 1.0f;
        enum float kAreaScale = 8.0f;
        if (auto st = rprMaterialNodeSetInputFByKey(
                emis, RPR_MATERIAL_INPUT_COLOR,
                ld.color.x * intensity * kAreaScale,
                ld.color.y * intensity * kAreaScale,
                ld.color.z * intensity * kAreaScale,
                1.0f)) {
            rprObjectDelete(shape);
            rprObjectDelete(emis);
            setError("rprMaterialNodeSetInputFByKey(area COLOR)", st);
            return false;
        }
        if (auto st = rprShapeSetMaterial(shape, emis)) {
            rprObjectDelete(shape);
            rprObjectDelete(emis);
            setError("rprShapeSetMaterial(area)", st);
            return false;
        }
        if (auto st = rprSceneAttachShape(scn, shape)) {
            rprObjectDelete(shape);
            rprObjectDelete(emis);
            setError("rprSceneAttachShape(area)", st);
            return false;
        }

        areaShapes[id]   = shape;
        areaMats[id]     = emis;
        areaXyz[id]      = xyz;
        areaNormals[id]  = nrm;
        areaTris[id]     = tris;
        areaNIdx[id]     = nIdx;
        areaFvCounts[id] = fv;
        return true;
    }

    void destroyLight(LightId lid)
    {
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();
        if (auto p = lid.id in lightObjs) {
            rprSceneDetachLight(scn, *p);
            rprObjectDelete(*p);
            lightObjs.remove(lid.id);
        }
        // Area-light variant uses a shape + material instead of a true
        // RPR light. Tear it down here too.
        if (auto p = lid.id in areaShapes) {
            rprSceneDetachShape(scn, *p);
            rprObjectDelete(*p);
            areaShapes.remove(lid.id);
        }
        if (auto p = lid.id in areaMats) {
            rprObjectDelete(*p);
            areaMats.remove(lid.id);
        }
        areaXyz.remove(lid.id);
        areaNormals.remove(lid.id);
        areaTris.remove(lid.id);
        areaNIdx.remove(lid.id);
        areaFvCounts.remove(lid.id);
    }

    void setEnvironment(in EnvDesc ed)
    {
        if (ctx is null || scn is null) return;
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();

        // Destroy any previous env-light + image.
        if (envLight !is null) {
            rprSceneSetEnvironmentLight(scn, null);
            rprObjectDelete(envLight);
            envLight = null;
        }
        if (envImage !is null) {
            rprObjectDelete(envImage);
            envImage = null;
        }

        const bool isHDRI = (ed.kind == EnvDesc.Kind.HDRI);
        const bool isSolidLit = (ed.kind == EnvDesc.Kind.Solid)
            && (ed.color.x > 0 || ed.color.y > 0 || ed.color.z > 0);

        // No env lighting requested — leave scene without env-light.
        // Background rays escape to RPR's default black.
        if (!isHDRI && !isSolidLit) return;

        if (isHDRI) {
            if (ed.hdriPath.length == 0) {
                setError("setEnvironment: HDRI requested but hdriPath is empty");
                return;
            }
            auto pathZ = ed.hdriPath.toStringz;
            if (auto st = rprContextCreateImageFromFile(ctx, pathZ, &envImage)) {
                setError("rprContextCreateImageFromFile(" ~ ed.hdriPath ~ ")", st);
                envImage = null;
                return;
            }
        } else {
            // Solid color → tiny constant image (1×1 RGBA32F).
            float[4] px = [ed.color.x, ed.color.y, ed.color.z, 1.0f];
            rpr_image_format fmt = { num_components: 4, type: RPR_COMPONENT_TYPE_FLOAT32 };
            rpr_image_desc desc;
            desc.image_width       = 1;
            desc.image_height      = 1;
            desc.image_depth       = 1;
            desc.image_row_pitch   = cast(rpr_uint)(float.sizeof * 4);
            desc.image_slice_pitch = cast(rpr_uint)(float.sizeof * 4);
            if (auto st = rprContextCreateImage(ctx, fmt, &desc, px.ptr, &envImage)) {
                setError("rprContextCreateImage(solid)", st);
                envImage = null;
                return;
            }
        }

        if (auto st = rprContextCreateEnvironmentLight(ctx, &envLight)) {
            setError("rprContextCreateEnvironmentLight", st);
            rprObjectDelete(envImage);
            envImage = null;
            envLight = null;
            return;
        }
        if (auto st = rprEnvironmentLightSetImage(envLight, envImage)) {
            setError("rprEnvironmentLightSetImage", st);
            return;
        }
        // Solid env at color=(1,1,1) under intensity 1.0 already gives a
        // bright matte sky; HDRI brightness controlled by the file's
        // pixel values, intensity 1.0 unscaled.
        rprEnvironmentLightSetIntensityScale(envLight, 1.0f);
        if (auto st = rprSceneSetEnvironmentLight(scn, envLight)) {
            setError("rprSceneSetEnvironmentLight", st);
        }
    }

    void setCamera(in CameraDesc cd)
    {
        if (cam is null) return;
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();
        rprCameraLookAt(cam,
            cd.eye.x,    cd.eye.y,    cd.eye.z,
            cd.target.x, cd.target.y, cd.target.z,
            cd.up.x,     cd.up.y,     cd.up.z);

        const float aspect = cd.aspect > 0 ? cd.aspect : 1.0f;

        if (cd.kind == CameraDesc.Kind.Orthographic) {
            rprCameraSetMode(cam, RPR_CAMERA_MODE_ORTHOGRAPHIC);
            // CameraDesc has no explicit ortho width yet. Until that field
            // lands, use a reasonable default sized to the typical 4-unit
            // viewing volume that vibe3d uses for its "frame to fit"
            // distance. M5 / future CameraDesc extension will plumb this
            // from the View controller.
            enum float kDefaultOrthoWidth = 4.0f;
            rprCameraSetOrthoWidth(cam,  kDefaultOrthoWidth);
            rprCameraSetOrthoHeight(cam, kDefaultOrthoWidth / aspect);
        } else {
            rprCameraSetMode(cam, RPR_CAMERA_MODE_PERSPECTIVE);
            // Convert vertical FOV → focal length via a constant sensor
            // height. Width follows from aspect so sensor-aspect matches
            // viewport-aspect (otherwise RPR letterboxes/stretches).
            //   tan(vfov/2) = sensorH / (2 * focal)
            //   ⇒ focal = sensorH / (2 * tan(vfov/2))
            enum float sensorH = 24.0f;
            const float focal  = sensorH / (2.0f * tan(cd.fovRadiansVertical * 0.5f));
            rprCameraSetSensorSize(cam, sensorH * aspect, sensorH);
            rprCameraSetFocalLength(cam, focal);
        }
        rprCameraSetNearPlane(cam, cd.nearClip);
        rprCameraSetFarPlane(cam,  cd.farClip);

        // Depth of field — only active when caller asked for non-pinhole.
        // vibe3d's `dofAperture` carries semantics inherited from Cycles
        // (aperture size in world units). RPR uses F-stop. The two are
        // inversely proportional — Cycles bigger aperture = more blur,
        // RPR lower f-stop = more blur. Heuristic mapping:
        //     fstop ≈ 16 / max(aperture, 0.001)
        // gives a sensible visual match in the dev box; M5 will tighten.
        // Pinhole (aperture <= 0) → use a very high f-stop, effectively
        // disabling DOF in RPR.
        if (cd.dofAperture > 0 && cd.dofFocalDistance > 0) {
            rprCameraSetFocusDistance(cam, cd.dofFocalDistance);
            const float fstop = 16.0f / cd.dofAperture;
            rprCameraSetFStop(cam, fstop);
        } else {
            // Cycles' "no DOF" = aperture=0; convey via wide f-stop so RPR
            // does pinhole-like rays.
            rprCameraSetFStop(cam, 128.0f);
        }
    }

    // -----------------------------------------------------------------------
    // IPR display
    // -----------------------------------------------------------------------

    void resize(int w, int h)
    {
        if (w == fbW && h == fbH && fbReady) return;
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();
        fbW = w;
        fbH = h;
        createFramebuffers(w, h);
        atomicStore(samplesAccum, 0);
    }

    /// Internal — must be called under sceneMtx (or pre-worker, during init).
    private bool createFramebuffers(int w, int h)
    {
        if (ctx is null) return setError("createFramebuffers: ctx is null");

        if (fbColor    !is null) { rprObjectDelete(fbColor);    fbColor    = null; }
        if (fbResolved !is null) { rprObjectDelete(fbResolved); fbResolved = null; }

        rpr_framebuffer_desc desc = { fb_width: cast(rpr_uint)w, fb_height: cast(rpr_uint)h };
        rpr_framebuffer_format fmt = { num_components: 4, type: RPR_COMPONENT_TYPE_FLOAT32 };

        if (auto st = rprContextCreateFrameBuffer(ctx, fmt, &desc, &fbColor))
            return setError("rprContextCreateFrameBuffer(color)", st);
        if (auto st = rprContextCreateFrameBuffer(ctx, fmt, &desc, &fbResolved))
            return setError("rprContextCreateFrameBuffer(resolved)", st);
        if (auto st = rprContextSetAOV(ctx, RPR_AOV_COLOR, fbColor))
            return setError("rprContextSetAOV(COLOR)", st);

        rprFrameBufferClear(fbColor);
        rprFrameBufferClear(fbResolved);
        fbReady = true;
        return true;
    }

    bool resetAccumulation()
    {
        if (ctx is null) return false;
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();
        if (!fbReady && !createFramebuffers(fbW, fbH)) return false;
        rprFrameBufferClear(fbColor);
        rprFrameBufferClear(fbResolved);
        atomicStore(samplesAccum, 0);
        return true;
    }

    void tick()
    {
        // No-op — the worker renders autonomously. Kept for the interface.
    }

    bool tryBindGLTexture(uint glTex, int w, int h) { return false; }
    bool usingInterop() { return false; }

    /// Lock-free for the worker: reads `pixelCache` under `pixelMtx`
    /// (just a memcpy of the float buffer). No RPR calls — RPR objects
    /// are touched only by the worker under `sceneMtx`.
    bool grabPixels(ref float[] out_, out int w, out int h)
    {
        if (pixelMtx is null) return false;
        pixelMtx.lock();
        scope (exit) pixelMtx.unlock();

        if (pixelCache.length == 0) return false;
        if (pixelReadOut.length != pixelCache.length)
            pixelReadOut.length = pixelCache.length;
        pixelReadOut[] = pixelCache[];
        out_ = pixelReadOut;
        w    = cachedW;
        h    = cachedH;
        return true;
    }

    ulong frameVersion() { return atomicLoad(verCounter); }

    float progress()
    {
        if (cfg.samples <= 0) return 0;
        const float p = cast(float)atomicLoad(samplesAccum) / cast(float)cfg.samples;
        return p > 1.0f ? 1.0f : p;
    }

    bool setSamples(int samples)
    {
        if (samples <= 0) return false;
        if (sceneMtx !is null) sceneMtx.lock();
        scope (exit) if (sceneMtx !is null) sceneMtx.unlock();
        cfg.samples = samples;
        return true;
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private bool setError(string where, rpr_status st = RPR_SUCCESS)
    {
        lastErrorMsg = st == RPR_SUCCESS
            ? where
            : format("%s (rpr_status=%d)", where, st);
        return false;
    }
}
