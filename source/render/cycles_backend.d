/// Cycles implementation of `RenderBackend`.
///
/// Phase 1b strategy:
///   - All scene mutations (uploadTriMesh, uploadMaterial, uploadLight,
///     setCamera, setEnvironment) write into an internal "blueprint" of
///     D-side struct fields and mark `dirty`.
///   - `resetAccumulation()` destroys the live Cycles session (if any)
///     and rebuilds it from the blueprint. This is the destroy+recreate
///     workaround for Cycles' interactive-mode quirk (cancel+reset+start
///     on a live session doesn't reliably re-apply scene changes —
///     verified empirically; documented in
///     doc/shader_framework_plan.md → "IPR optimization track").
///   - `tick()` is a no-op: Cycles renders asynchronously in its own
///     worker thread once started.
///   - `grabPixels()` polls the CapturingDisplayDriver via
///     `cyc_session_display_read_pixels` + `cyc_session_display_version`
///     (returns false until the first update_end fires on the worker).
///   - `tryBindGLTexture()` always returns false in Phase 1b; interop
///     lands as IPR-opt 3 (DisplayDriver + GraphicsInterop).
///
/// Future work (IPR-opt 1+) replaces destroy+recreate with Cycles'
/// scene-mutex pattern (try_lock + reset + start), shrinking the
/// per-restart cost from ~200 ms to ~30 ms. The interface here doesn't
/// change.
module render.cycles_backend;

version (WithRender):

import std.process : environment;
import std.path    : buildPath, dirName;
import std.file    : thisExePath, exists;
import std.format  : format;
import std.conv    : to;

import bindbc.opengl;
import bindbc.sdl;
import cycles.c;

import render.backend;
import math : Vec3;

// ---------------------------------------------------------------------------
// Blueprint — D-side mirror of the scene, used to rebuild Cycles state
// after destroy+recreate.
// ---------------------------------------------------------------------------

private struct MeshBlueprint
{
    ulong   id;
    float[] xyz;          // 3 floats / vertex
    float[] normals;      // 3 floats / vertex (or empty → flat shading)
    float[] uv;           // 2 floats / vertex (or empty)
    int[]   tris;         // 3 ints / triangle
    ulong   materialId;   // 0 = unassigned
}

private struct LightBlueprint
{
    ulong     id;
    LightDesc desc;
}

private struct MaterialBlueprint
{
    ulong            id;
    CompiledMaterial cm;
}

// ---------------------------------------------------------------------------
// CyclesBackend
// ---------------------------------------------------------------------------

class CyclesBackend : RenderBackend
{
    // --- ID allocator (shared across all kinds for simplicity; Phase 1b has 1 of each) ---
    private ulong nextId = 1;

    // --- Blueprint ---
    private MeshBlueprint[ulong]     meshes;
    private MaterialBlueprint[ulong] materials;
    private LightBlueprint[ulong]    lights;
    private CameraDesc               cameraDesc;
    private EnvDesc                  envDesc;
    private BackendConfig            cfg;

    // --- Live Cycles handles. Recreated on resetAccumulation. ---
    private cyc_session_t* session;
    private cyc_scene_t*   scene;
    private cyc_device_type activeDevice;
    private int             bootW;     // resolution captured at last bootLiveSession
    private int             bootH;

    // Maps blueprint ID → Cycles handle, valid only while session is alive.
    private cyc_mesh_t*[ulong]   meshHandles;
    private cyc_object_t*[ulong] objHandles;     // one per mesh
    private cyc_shader_t*[ulong] shaderHandles;
    private cyc_light_t*[ulong]  lightHandles;
    private cyc_camera_t*        cameraHandle;

    // --- Display state ---
    private int     fbW = 512;
    private int     fbH = 512;
    private float[] fbScratch;          // last-read framebuffer; reused
    private ulong   lastReadVersion;    // last cyc_session_display_version
                                        // we copied — skip re-reads of same frame

    // --- IPR-opt 3: zero-copy GL interop ---
    // When the host calls tryBindGLTexture and we're on a CUDA/OPTIX
    // device, we allocate our own GL pixel-buffer (half4 RGBA), register
    // it with Cycles via cyc_session_display_bind_gl_pbo, and on each
    // frame_version bump blit the PBO into the host's texture. CPU
    // readback path is skipped (grabPixels returns false). On CPU
    // device or any setup error the bind returns false and the host
    // falls back to CPU readback.
    private bool   interopActive;
    private GLuint interopGlTex;
    private GLuint interopGlPbo;
    private int    interopW;
    private int    interopH;
    private ulong  lastInteropVersion;

    // Worker-thread shared GL context, used by Cycles for CUDA-GL
    // queries (cuGLGetDevices, cuGraphicsGLRegisterBuffer). Without it,
    // CUDADevice::should_use_graphics_interop returns false → naive
    // CPU path. Created lazily on tryBindGLTexture by cloning the
    // host's current context with SDL_GL_SHARE_WITH_CURRENT_CONTEXT,
    // then SDL_GL_MakeCurrent'd onto the worker via the interop
    // activate callback.
    private SDL_Window*   sdlWindow;
    private SDL_GLContext workerGlCtx;

    // Pending interop request from a tryBindGLTexture that happened
    // before the live session existed. bootLiveSession picks this up
    // right after cyc_session_create so the PBO + callbacks are
    // registered BEFORE the render worker starts and races us to the
    // first should_use_graphics_interop check.
    private bool   interopPendingRequest;
    private GLuint interopPendingGlTex;
    private int    interopPendingW;
    private int    interopPendingH;

    // One-shot warning latch for SDL_GL_MakeCurrent failures (typically
    // Wayland + EGL_BAD_ACCESS — see activateInteropCallback for the
    // workaround). Avoids spamming the log on every interop call.
    private bool   interopMakeCurrentWarned;

    // --- Error ---
    private string lastErrorMsg;

    // -----------------------------------------------------------------------
    // RenderBackend — identity
    // -----------------------------------------------------------------------

    string name() { return "cycles"; }
    string lastError() { return lastErrorMsg; }

    BackendCaps caps()
    {
        BackendCaps c;
        c.supportsGLInterop = false;        // Phase 1b — IPR-opt 3 enables
        c.supportsOSL       = true;         // Cycles native
        c.supportsMDL       = false;
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
        ensureKernelPathSet();
        return true;
    }

    void shutdown()
    {
        destroyLiveSession();
        meshes  = null;
        materials = null;
        lights  = null;
        fbScratch = null;
        if (interopGlPbo != 0) {
            glDeleteBuffers(1, &interopGlPbo);
            interopGlPbo = 0;
        }
        if (workerGlCtx !is null) {
            SDL_GL_DeleteContext(workerGlCtx);
            workerGlCtx = null;
        }
        interopActive      = false;
        lastInteropVersion = 0;
    }

    // -----------------------------------------------------------------------
    // Scene mutators — write blueprint only. Live Cycles state is rebuilt
    // in resetAccumulation().
    // -----------------------------------------------------------------------

    MeshId uploadTriMesh(in float[] xyz, in float[] normals,
                         in float[] uv,  in int[]   tris)
    {
        auto id = nextId++;
        MeshBlueprint mb;
        mb.id      = id;
        mb.xyz     = xyz.dup;
        mb.normals = normals.dup;
        mb.uv      = uv.dup;
        mb.tris    = tris.dup;
        meshes[id] = mb;
        return MeshId(id);
    }

    void destroyMesh(MeshId mid)
    {
        meshes.remove(mid.id);
    }

    MaterialId uploadMaterial(in CompiledMaterial cm)
    {
        auto id = nextId++;
        materials[id] = MaterialBlueprint(id, cm);
        return MaterialId(id);
    }

    void assignMaterial(MeshId meshId, MaterialId matId)
    {
        if (auto p = meshId.id in meshes) {
            p.materialId = matId.id;
        }
    }

    LightId uploadLight(in LightDesc ld)
    {
        auto id = nextId++;
        lights[id] = LightBlueprint(id, ld);
        return LightId(id);
    }

    void destroyLight(LightId lid)
    {
        lights.remove(lid.id);
    }

    void setEnvironment(in EnvDesc ed) { envDesc    = ed; }
    void setCamera(in CameraDesc cd)   { cameraDesc = cd; }

    // -----------------------------------------------------------------------
    // IPR display
    // -----------------------------------------------------------------------

    void resize(int w, int h)
    {
        fbW = w;
        fbH = h;
        if (interopActive && session !is null
            && (w != interopW || h != interopH)) {
            const ulong byteSize = cast(ulong)w * cast(ulong)h * 8UL;
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, interopGlPbo);
            glBufferData(GL_PIXEL_UNPACK_BUFFER,
                         cast(GLsizeiptr)byteSize, null, GL_DYNAMIC_DRAW);
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
            cyc_session_display_bind_gl_pbo(session, interopGlPbo, byteSize);
            interopW           = w;
            interopH           = h;
            lastInteropVersion = 0;
        }
    }

    /// Push the D-side blueprint into Cycles' scene under the scene
    /// mutex, then ask the session to restart accumulation. The
    /// interactive-render update sequence is:
    ///
    ///   1. session->scene->mutex.try_lock()
    ///   2. cam->set_*() / mesh->set_*() / shader->set_*()    ← auto-tags
    ///      via Node::set (graph/node.cpp:23)
    ///   3. scene->mutex.unlock()
    ///   4. session->reset(session_params, buffer_params)    ← outside mutex
    ///
    /// Notes:
    ///  - We intentionally bypass `cyc_session_ready_to_reset()` (which
    ///    requires a DisplayDriver — we install only a CapturingOutput-
    ///    Driver, so its `did_draw_after_reset_` latch never flips and
    ///    the gate is wedged at false). Cost of skipping: `Session::reset`
    ///    → `path_trace_->cancel` may block for the current sample
    ///    iteration (~ tens of ms on small scenes). Acceptable.
    ///  - `session->reset` MUST be called outside the scene mutex —
    ///    it calls `path_trace_->cancel` which the worker thread joins
    ///    via the scene mutex, so holding it on the main thread =
    ///    deadlock.
    ///  - First call (no live session yet) does the one-time boot:
    ///    create session + sync + start. After that, the worker runs
    ///    continuously and `reset` just restarts accumulation.
    bool resetAccumulation()
    {
        // First-time boot.
        if (session is null) {
            if (!bootLiveSession()) return false;
            if (!syncBlueprint())   { destroyLiveSession(); return false; }
            if (!startLiveSession()){ destroyLiveSession(); return false; }
            return true;
        }

        // Resolution change since session boot. Cycles' session->reset
        // with a *different* buffer_params dimension reliably ends up
        // writing only a partial slice to display_rgba_half_ on the
        // subsequent renders — the host-side buffer keeps its init-zero
        // outside the slice and the image goes mostly black.
        // (Reproduced: opt 2 + dynamic resolution; same image at fixed
        // res renders correctly. Cycles bug or shim wrapper gap.)
        // Fall back to the destroy+recreate pattern from before opt 1
        // for the resize case — slower (~200 ms) but reliable, and
        // resize is rare (once per panel-size settle).
        if (fbW != bootW || fbH != bootH) {
            destroyLiveSession();
            if (!bootLiveSession()) return false;
            if (!syncBlueprint())   { destroyLiveSession(); return false; }
            if (!startLiveSession()){ destroyLiveSession(); return false; }
            return true;
        }

        // Live session — scene-mutex update pattern.
        if (cyc_session_scene_try_lock(session) == 0) {
            // Worker is in its short scene-update window. Skip this
            // tick; caller's debounce loop will retry. Blueprint stays
            // intact, so nothing is lost.
            return false;
        }
        const bool synced = syncBlueprint();
        cyc_session_scene_unlock(session);

        if (!synced) {
            // Hard error inside syncBlueprint (setError already called).
            // Drop the session so the next tick reboots clean.
            destroyLiveSession();
            return false;
        }

        // session->reset triggers worker restart (no need to call
        // cyc_session_start — the worker is already running and
        // reset() wakes it via the pause condvar).
        if (auto st = cyc_session_reset(session, fbW, fbH)) {
            setError("session_reset", st);
            destroyLiveSession();
            return false;
        }
        return true;
    }

    /// Drive the host-side half of GL interop (when active): on each new
    /// Cycles frame_version, blit the half4 RGBA data the worker thread
    /// wrote into our PBO straight into the host's bound texture. Worker
    /// renders asynchronously; this is just the per-frame nudge.
    ///
    /// Auto-fallback: Cycles may advertise interop support, accept our
    /// PBO, then silently fall back to the CPU "naive" path inside
    /// `copy_to_display_interop` (e.g. CUDA-GL context activation
    /// failed — requires a worker-thread-current shared GL context we
    /// haven't built yet). Once we detect that fallback via the shim's
    /// cpu_path_used flag, we disable interop on the host side so
    /// grabPixels resumes the working CPU readback path.
    void tick()
    {
        if (!interopActive || session is null) return;

        if (cyc_session_display_cpu_path_used(session) != 0) {
            interopActive = false;
            return;
        }

        const ulong cur = cyc_session_display_version(session);
        if (cur == 0 || cur == lastInteropVersion) return;

        // PBO contains the latest CUDA-written half4 RGBA pixels.
        // Bind it as PIXEL_UNPACK_BUFFER and re-spec the target
        // texture; the driver reads from the bound PBO instead of
        // a CPU pointer. internalFormat=RGBA32F lets it upcast half→
        // float so the texture matches the CPU fallback path's
        // format-wise.
        //
        // Note: Cycles writes bottom-up like all GL framebuffers; the
        // host UV-flips on Image() when interop is active.
        glBindTexture(GL_TEXTURE_2D, interopGlTex);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, interopGlPbo);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F,
                     interopW, interopH, 0,
                     GL_RGBA, GL_HALF_FLOAT, null);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, 0);

        lastInteropVersion = cur;
    }

    /// Phase 2 (IPR-opt 3): zero-copy GL interop. Allocate a PBO sized
    /// for half4 RGBA, register it with Cycles' DisplayDriver, store the
    /// host's texture for per-frame blit in tick(). Only effective on
    /// CUDA/OPTIX device — CPU device can't write to a GL PBO via
    /// interop, so we return false and the host keeps the CPU path.
    bool tryBindGLTexture(uint glTex, int w, int h)
    {
        if (w <= 0 || h <= 0) return false;

        // VIBE3D_NO_INTEROP=1 — diagnostic switch. With the interop
        // bind suppressed, the host stays on the CPU readback path
        // exactly as in opt 2. Used to verify whether the interop
        // attempt itself (CUDA-GL probing + naive fallback) is what
        // breaks rendering on hosts without a shared GL context.
        if (environment.get("VIBE3D_NO_INTEROP") !is null) return false;

        // Record the request. Actual session-side registration (PBO
        // bind + interop callbacks) is deferred to bootLiveSession so
        // it lands BEFORE cyc_session_start — otherwise the render
        // worker races us to should_use_graphics_interop on its first
        // tick, sees no callback, falls back to naive, and caches that
        // decision for the session's lifetime.
        interopPendingRequest = true;
        interopPendingGlTex   = glTex;
        interopPendingW       = w;
        interopPendingH       = h;

        // If a session is already live (e.g. host re-binds at the same
        // resolution after a switchTo without recreating the worker),
        // perform the registration now. Otherwise it'll happen the
        // next time bootLiveSession runs.
        if (session !is null) return finishInteropBind();
        return true;
    }

    /// Actually wire up the GL interop: ensure shared worker GL ctx,
    /// allocate PBO sized for half4 RGBA, register both with the
    /// running session. MUST be called while session is live and
    /// activeDevice is known. Returns false on hard failure (CPU
    /// device, GL ctx couldn't be created, shim refused PBO bind).
    private bool finishInteropBind()
    {
        if (session is null || !interopPendingRequest) return false;
        if (activeDevice != cyc_device_type.CUDA &&
            activeDevice != cyc_device_type.OPTIX) {
            return false;
        }

        // Worker-shared GL context — main thread is current right now
        // (host invokes us from its ImGui tick). Create the shared ctx
        // and restore main as current.
        if (workerGlCtx is null) {
            sdlWindow = SDL_GL_GetCurrentWindow();
            auto mainCtx = SDL_GL_GetCurrentContext();
            if (sdlWindow is null || mainCtx is null) return false;

            SDL_GL_SetAttribute(SDL_GL_SHARE_WITH_CURRENT_CONTEXT, 1);
            workerGlCtx = SDL_GL_CreateContext(sdlWindow);
            SDL_GL_MakeCurrent(sdlWindow, mainCtx);
            if (workerGlCtx is null) return false;
        }

        if (interopGlPbo == 0) glGenBuffers(1, &interopGlPbo);
        const ulong byteSize = cast(ulong)interopPendingW *
                                cast(ulong)interopPendingH * 8UL;  // half4 = 8 B/px
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, interopGlPbo);
        glBufferData(GL_PIXEL_UNPACK_BUFFER,
                     cast(GLsizeiptr)byteSize, null, GL_DYNAMIC_DRAW);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);

        if (auto st = cyc_session_display_bind_gl_pbo(
                session, interopGlPbo, byteSize)) {
            glDeleteBuffers(1, &interopGlPbo);
            interopGlPbo = 0;
            return false;
        }

        cyc_session_display_set_interop_callbacks(session,
            &activateInteropCallback, &deactivateInteropCallback,
            cast(void*)this);

        interopGlTex       = interopPendingGlTex;
        interopW           = interopPendingW;
        interopH           = interopPendingH;
        interopActive      = true;
        lastInteropVersion = 0;
        return true;
    }

    /// Cycles worker thread asks the host to make the shared GL context
    /// current. Called via cyc_session_display_set_interop_callbacks.
    ///
    /// On Wayland + EGL this typically fails with `EGL_BAD_ACCESS`:
    /// EGL doesn't allow a context to be taken from one thread to
    /// another while another context is current somewhere, even with
    /// SDL_GL_SHARE_WITH_CURRENT_CONTEXT. The workaround is to start
    /// vibe3d under X11/GLX: `SDL_VIDEODRIVER=x11 ./vibe3d`. Cycles
    /// then falls back to its CPU naive path via cpu_path_used, and
    /// the host's usingInterop() reports false so the texture pipeline
    /// stays correct.
    private extern (C) static void activateInteropCallback(void* userdata) nothrow @nogc
    {
        import core.stdc.stdio : fprintf, stderr;
        auto self = cast(CyclesBackend) userdata;
        if (self is null || self.sdlWindow is null || self.workerGlCtx is null)
            return;
        auto cur = SDL_GL_GetCurrentContext();
        if (cur is self.workerGlCtx) return;
        const int rc = SDL_GL_MakeCurrent(self.sdlWindow, self.workerGlCtx);
        if (rc != 0 && !self.interopMakeCurrentWarned) {
            self.interopMakeCurrentWarned = true;
            try fprintf(stderr,
                "[ipr] GL interop disabled — SDL_GL_MakeCurrent on the "
                ~ "worker thread failed (%s).\n"
                ~ "      Likely Wayland+EGL — start vibe3d with "
                ~ "SDL_VIDEODRIVER=x11 to enable zero-copy interop.\n"
                ~ "      Falling back to CPU readback (rendering still "
                ~ "correct, just slower at high res).\n",
                SDL_GetError());
            catch (Exception) {}
        }
    }

    /// Counter-hook to activate. We DON'T release the context — worker
    /// thread keeps it for the lifetime of the session; release-per-call
    /// just adds churn since main thread has its own (separate) context.
    private extern (C) static void deactivateInteropCallback(void* userdata) nothrow @nogc
    {
        /* intentional no-op */
    }

    /// True when GL interop was bound AND Cycles is actually writing
    /// to the PBO (didn't silently fall back to the CPU naive path).
    /// Host uses this to choose UV-flip in ImGui.Image and to skip
    /// redundant texture uploads.
    ///
    /// Requires `frame_version > 0` so we don't claim interop before
    /// Cycles has actually produced anything — otherwise the first
    /// few frames after switchTo (e.g. Samples slider commit) would
    /// flip UV on a stale carry-over texture, showing the previous
    /// session's image upside-down before the fresh CPU/interop pixels
    /// land.
    bool usingInterop()
    {
        if (!interopActive || session is null) return false;
        if (cyc_session_display_version(session) == 0) return false;
        return cyc_session_display_cpu_path_used(session) == 0;
    }

    bool grabPixels(ref float[] out_, out int w, out int h)
    {
        if (session is null) return false;
        // Interop is actively pushing pixels — host shouldn't blit
        // again. But if Cycles fell back to the CPU naive path, the
        // PBO is stale and we MUST read buffer_ instead.
        if (usingInterop()) return false;

        // Display-driver frame counter (bumps on Cycles' update_end on
        // the worker thread). Zero before the very first frame.
        const ulong cur = cyc_session_display_version(session);
        if (cur == 0 || cur == lastReadVersion) return false;

        const need = cast(size_t)(fbW * fbH * 4);
        if (fbScratch.length != need) fbScratch.length = need;

        // Diagnostic: VIBE3D_IPR_OUTPUT_DRIVER=1 uses the legacy
        // CapturingOutputDriver path instead of the half4 DisplayDriver.
        // If artifacts ("black stripes from middle of model") on CPU
        // device vanish under this flag, the bug lives in our
        // DisplayDriver buffer-management; if they persist, the bug
        // is deeper in Cycles' CPU progressive write path.
        cyc_status st;
        if (environment.get("VIBE3D_IPR_OUTPUT_DRIVER") !is null) {
            st = cyc_session_read_framebuffer(session, fbScratch.ptr, fbW, fbH);
        } else {
            st = cyc_session_display_read_pixels(session, fbScratch.ptr, fbW, fbH);
        }
        // CYC_ERR_INTERNAL = size mismatch (we just resized? wait next frame)
        // or buffer empty (race with reset).
        if (st == CYC_ERR_INTERNAL) return false;
        if (st != CYC_OK) {
            setError("display_read_pixels", st);
            return false;
        }

        out_ = fbScratch;
        w = fbW;
        h = fbH;
        lastReadVersion = cur;
        return true;
    }

    ulong frameVersion()
    {
        return session is null ? 0 : cyc_session_display_version(session);
    }

    float progress()
    {
        if (session is null) return 0.0f;
        float p = 0;
        cyc_session_progress(session, &p);
        return p;
    }

    /// Live samples update — no destroy/recreate, no scene resync.
    /// Updates the running ccl::Session's sample cap and pokes its
    /// scheduler to keep going if it had already converged on the old
    /// cap. Critical for the Samples slider: a full switchTo on every
    /// commit was tearing down Cycles' CUDA-GL interop registration
    /// and the next session occasionally failed to recover (progress
    /// stuck partway through).
    bool setSamples(int samples)
    {
        if (session is null || samples <= 0) return false;
        cyc_session_set_samples(session, samples);
        cfg.samples = samples;
        return true;
    }

    // -----------------------------------------------------------------------
    // Live session lifecycle (private)
    // -----------------------------------------------------------------------

    private bool bootLiveSession()
    {
        // Device selection. `cfg.device` is a string from BackendConfig:
        //   "cpu"   — CPU only
        //   "cuda"  — NVIDIA CUDA backend (fast, works in vibe3d's
        //             GL context — verified empirically)
        //   "optix" — NVIDIA OPTIX with RT cores (faster, but segfaults
        //             when SDL has already created a GL-CUDA interop
        //             context — see plan doc IPR-opt OPTIX-fix track)
        //   "metal" — Apple Silicon GPU. No Metal→GL zero-copy interop
        //             on macOS (Apple deprecated GL); the framebuffer
        //             routes through the CPU readback path (finishInterop
        //             Bind bails out for non-CUDA/OPTIX devices). Still
        //             gives big speedup over CPU for the actual sampling.
        //   "auto"  — try CUDA → CPU (skips OPTIX intentionally until
        //             init-order fix lands)
        cyc_device_type[] chain;
        switch (cfg.device) {
            case "cpu":   chain = [cyc_device_type.CPU];                          break;
            case "cuda":  chain = [cyc_device_type.CUDA, cyc_device_type.CPU];    break;
            case "optix": chain = [cyc_device_type.OPTIX, cyc_device_type.CPU];   break;
            case "metal": chain = [cyc_device_type.METAL, cyc_device_type.CPU];   break;
            case "auto":  chain = [cyc_device_type.CUDA, cyc_device_type.CPU];    break;
            default:      chain = [cyc_device_type.CPU];                          break;
        }

        foreach (dev; chain) {
            cyc_session_params sp;
            sp.device_type  = dev;
            sp.device_index = cfg.deviceIndex;
            sp.samples      = cfg.samples > 0 ? cfg.samples : 1_000_000;
            sp.threads      = 0;
            sp.tile_size    = 0;
            sp.use_denoiser = cfg.useDenoiser ? 1 : 0;
            sp.interactive  = 1;

            cyc_session_t* s;
            auto st = cyc_session_create(&sp, &s);
            if (st == CYC_OK && s !is null) {
                session      = s;
                scene        = cyc_session_scene(s);
                activeDevice = dev;
                bootW        = fbW;
                bootH        = fbH;
                // Register GL interop BEFORE startLiveSession spawns the
                // worker's render. The worker thread exists from session
                // ctor but sits in SESSION_THREAD_WAIT until start() —
                // safe window to wire PBO + callbacks.
                if (interopPendingRequest) finishInteropBind();
                return true;
            }
            // Try next device in chain. Note: hard crashes (segfaults)
            // are NOT recoverable here — that's what kills OPTIX path.
        }

        return setError("session_create: all devices in chain failed");
    }

    /// Sync the D-side blueprint into live Cycles scene objects.
    /// Idempotent: creates handles on first call, updates them in
    /// place on subsequent calls. Called both on initial session boot
    /// and on every resetAccumulation while the scene mutex is held.
    private bool syncBlueprint()
    {
        // GC orphan handles. When the caller drops a mesh/light/material
        // from its blueprint (e.g. user loads a new model → bridge
        // calls destroyMesh+uploadTriMesh), the live cyc_*_t handle is
        // left behind in our handle map — destroyMesh only forgets the
        // blueprint entry.  If we don't actually destroy the Cycles
        // object inside the scene mutex, it stays visible in IPR (the
        // old cube ghosts under the new model — reported regression).
        // Walk our handle maps and destroy whatever no longer has a
        // corresponding blueprint.
        ulong[] deadObjs;
        foreach (id; objHandles.byKey)
            if (id !in meshes) deadObjs ~= id;
        foreach (id; deadObjs) {
            cyc_object_destroy(scene, objHandles[id]);
            objHandles.remove(id);
        }

        ulong[] deadMeshes;
        foreach (id; meshHandles.byKey)
            if (id !in meshes) deadMeshes ~= id;
        foreach (id; deadMeshes) {
            cyc_mesh_destroy(scene, meshHandles[id]);
            meshHandles.remove(id);
        }

        ulong[] deadLights;
        foreach (id; lightHandles.byKey)
            if (id !in lights) deadLights ~= id;
        foreach (id; deadLights) {
            cyc_light_destroy(scene, lightHandles[id]);
            lightHandles.remove(id);
        }

        ulong[] deadShaders;
        foreach (id; shaderHandles.byKey)
            if (id !in materials) deadShaders ~= id;
        foreach (id; deadShaders) {
            cyc_shader_destroy(scene, shaderHandles[id]);
            shaderHandles.remove(id);
        }

        // --- Materials → Cycles shaders ---
        foreach (mat; materials.byValue) {
            cyc_shader_t* sh;
            if (auto p = mat.id in shaderHandles) {
                sh = *p;
            } else {
                if (auto st = cyc_shader_create_principled(scene, &sh))
                    return setError("shader_create", st);
                shaderHandles[mat.id] = sh;
            }
            const cm = mat.cm;
            if (auto st = cyc_shader_set_principled_base_color(sh,
                    cm.baseColor.x, cm.baseColor.y, cm.baseColor.z))
                return setError("shader_base_color", st);
            if (auto st = cyc_shader_set_principled_roughness(sh, cm.specularRoughness))
                return setError("shader_roughness", st);
            if (auto st = cyc_shader_set_principled_metallic(sh, cm.metallic))
                return setError("shader_metallic", st);
            if (cm.emissionStrength > 0) {
                if (auto st = cyc_shader_set_principled_emission(sh,
                        cm.emissionColor.x, cm.emissionColor.y, cm.emissionColor.z,
                        cm.emissionStrength))
                    return setError("shader_emission", st);
            }
            if (cm.transmission > 0) {
                if (auto st = cyc_shader_set_principled_transmission(sh, cm.transmission))
                    return setError("shader_transmission", st);
            }
        }

        // --- Meshes → Cycles meshes + objects ---
        foreach (mb; meshes.byValue) {
            cyc_mesh_t* m;
            if (auto p = mb.id in meshHandles) {
                m = *p;
            } else {
                if (auto st = cyc_mesh_create(scene, &m))
                    return setError("mesh_create", st);
                meshHandles[mb.id] = m;
            }
            const numVerts = cast(int)(mb.xyz.length / 3);
            // Setters internally tag_modified the mesh node so device
            // re-uploads. Cheap if data is identical.
            if (auto st = cyc_mesh_set_verts(m, mb.xyz.ptr, numVerts))
                return setError("mesh_set_verts", st);
            if (auto st = cyc_mesh_set_triangles(m, mb.tris.ptr,
                                                  cast(int)(mb.tris.length / 3), null))
                return setError("mesh_set_triangles", st);
            if (mb.normals.length > 0) {
                if (auto st = cyc_mesh_set_normals(m, mb.normals.ptr, numVerts))
                    return setError("mesh_set_normals", st);
            }
            if (mb.uv.length > 0) {
                if (auto st = cyc_mesh_set_uvs(m, mb.uv.ptr, numVerts, "UVMap".ptr))
                    return setError("mesh_set_uvs", st);
            }

            cyc_object_t* obj;
            if (auto p = mb.id in objHandles) {
                obj = *p;
            } else {
                if (auto st = cyc_object_create(scene, &obj))
                    return setError("object_create", st);
                if (auto st = cyc_object_set_mesh(obj, m))
                    return setError("object_set_mesh", st);
                objHandles[mb.id] = obj;
            }
            if (auto sh = mb.materialId in shaderHandles) {
                if (auto st = cyc_object_set_shader(obj, *sh))
                    return setError("object_set_shader", st);
            }
        }

        // --- Lights ---
        foreach (lb; lights.byValue) {
            cyc_light_t* L;
            if (auto p = lb.id in lightHandles) {
                L = *p;
            } else {
                const cyc_light_type t = toCycLightType(lb.desc.kind);
                if (auto st = cyc_light_create(scene, t, &L))
                    return setError("light_create", st);
                lightHandles[lb.id] = L;
            }
            if (auto st = cyc_light_set_transform(L, lb.desc.transform.ptr))
                return setError("light_xform", st);
            if (auto st = cyc_light_set_color(L,
                    lb.desc.color.x, lb.desc.color.y, lb.desc.color.z))
                return setError("light_color", st);
            if (auto st = cyc_light_set_intensity(L, lb.desc.intensity))
                return setError("light_intensity", st);
            if (lb.desc.kind == LightDesc.Kind.Sun) {
                if (auto st = cyc_light_set_sun_angle(L, lb.desc.sunAngle))
                    return setError("light_sun_angle", st);
            }
            if (lb.desc.kind == LightDesc.Kind.Spot) {
                if (auto st = cyc_light_set_spot_angle(L,
                        lb.desc.spotAngle, lb.desc.spotBlend))
                    return setError("light_spot_angle", st);
            }
            if (lb.desc.kind == LightDesc.Kind.Area) {
                if (auto st = cyc_light_set_size(L,
                        lb.desc.areaSizeX, lb.desc.areaSizeY))
                    return setError("light_size", st);
            }
        }

        // --- Camera ---
        if (cameraHandle is null) {
            if (cameraDesc.kind == CameraDesc.Kind.Orthographic) {
                if (auto st = cyc_camera_create_ortho(scene, &cameraHandle))
                    return setError("camera_create_ortho", st);
            } else {
                if (auto st = cyc_camera_create_perspective(scene, &cameraHandle))
                    return setError("camera_create_persp", st);
            }
            if (auto st = cyc_scene_set_active_camera(scene, cameraHandle))
                return setError("set_active_camera", st);
        }
        if (auto st = cyc_camera_lookat(cameraHandle,
                cameraDesc.eye.x,    cameraDesc.eye.y,    cameraDesc.eye.z,
                cameraDesc.target.x, cameraDesc.target.y, cameraDesc.target.z,
                cameraDesc.up.x,     cameraDesc.up.y,     cameraDesc.up.z))
            return setError("camera_lookat", st);
        // Cycles' `Camera::fov` socket is the vertical FOV (its
        // `projection_perspective` scales both screen axes by
        // 1/tan(fov/2), and the horizontal extent then comes from the
        // auto-computed viewplane = make_float2(aspect, 1)).
        if (auto st = cyc_camera_set_fov(cameraHandle, cameraDesc.fovRadiansVertical))
            return setError("camera_fov", st);
        if (auto st = cyc_camera_set_aspect(cameraHandle, cameraDesc.aspect))
            return setError("camera_aspect", st);
        if (auto st = cyc_camera_set_clip(cameraHandle, cameraDesc.nearClip, cameraDesc.farClip))
            return setError("camera_clip", st);
        if (cameraDesc.dofAperture > 0) {
            if (auto st = cyc_camera_set_dof(cameraHandle,
                    cameraDesc.dofFocalDistance, cameraDesc.dofAperture))
                return setError("camera_dof", st);
        }

        return true;
    }

    private bool startLiveSession()
    {
        if (auto st = cyc_session_reset(session, fbW, fbH))
            return setError("session_reset", st);
        if (auto st = cyc_session_start(session))
            return setError("session_start", st);
        return true;
    }

    private void destroyLiveSession()
    {
        if (session !is null) {
            cyc_session_cancel(session);
            cyc_session_destroy(session);
        }
        session         = null;
        scene           = null;
        cameraHandle    = null;
        meshHandles     = null;
        objHandles      = null;
        shaderHandles   = null;
        lightHandles    = null;
        lastReadVersion = 0;   // new session restarts version counter from 1
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private bool setError(string where, cyc_status st = CYC_OK)
    {
        lastErrorMsg = st == CYC_OK
            ? where
            : format("%s (cyc_status=%d)", where, st);
        return false;
    }

    private static void ensureKernelPathSet()
    {
        if (environment.get("CYCLESC_KERNEL_PATH") !is null) return;
        const exeDir = dirName(thisExePath);
        const guess  = buildPath(exeDir, "..", "D-Cycles", "extern", "blender",
                                  "build_cycles", "bin");
        if (guess.exists)
            environment["CYCLESC_KERNEL_PATH"] = guess;
    }

    private static cyc_light_type toCycLightType(LightDesc.Kind k)
    {
        final switch (k) {
            case LightDesc.Kind.Point:       return cyc_light_type.POINT;
            case LightDesc.Kind.Sun:         return cyc_light_type.SUN;
            case LightDesc.Kind.Spot:        return cyc_light_type.SPOT;
            case LightDesc.Kind.Area:        return cyc_light_type.AREA_RECT;
            case LightDesc.Kind.Mesh:        return cyc_light_type.POINT;       // TODO: emissive geometry, not a native cycles primitive
            case LightDesc.Kind.Environment: return cyc_light_type.BACKGROUND;
        }
    }
}
