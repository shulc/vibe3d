/// BackendBridge — orchestrates a `RenderBackend` from a `Scene`.
///
/// Holds scene-id ↔ backend-handle maps, reads dirty bits off the Scene,
/// pushes diff into the active backend, and clears the bits. Hot-swap is a
/// teardown + re-init + full re-upload from the Scene (mark-all-dirty then
/// sync).
///
/// Phase 1b: only Cycles is wired up. RPR slot is left ready for Phase 2.
module render.backend_bridge;

version (WithRender):

import render.backend;
import render.scene;
import render.cycles_backend : CyclesBackend;
import render.rpr_backend    : RPRBackend;

// ---------------------------------------------------------------------------
// BackendBridge
// ---------------------------------------------------------------------------

final class BackendBridge
{
    private RenderBackend _active;
    private string        _activeName;
    private BackendConfig _config;

    // Scene-id → backend-handle maps. Cleared on shutdown / switchTo.
    private MeshId[ulong]     meshHandles;
    private MaterialId[ulong] matHandles;
    private LightId[ulong]    lightHandles;

    private string _lastError;

    // -----------------------------------------------------------------------
    // Introspection
    // -----------------------------------------------------------------------

    string        activeName() const { return _activeName; }
    BackendConfig config()     const { return _config; }
    RenderBackend backend()          { return _active; }
    string        lastError()  const { return _lastError; }
    bool          isInitialized() const { return _active !is null; }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    bool init(string backendName, in BackendConfig cfg)
    {
        shutdown();
        auto b = createBackend(backendName);
        if (b is null) {
            _lastError = "unknown backend: " ~ backendName;
            return false;
        }
        if (!b.init(cfg)) {
            _lastError = "backend.init: " ~ b.lastError();
            return false;
        }
        _active     = b;
        _activeName = backendName;
        _config     = cfg;
        return true;
    }

    void shutdown()
    {
        if (_active !is null) {
            try { _active.shutdown(); } catch (Exception) {}
            _active = null;
        }
        _activeName = "";
        meshHandles  = null;
        matHandles   = null;
        lightHandles = null;
    }

    // -----------------------------------------------------------------------
    // Sync
    // -----------------------------------------------------------------------

    /// Push pending Scene changes into the backend. Returns true if any
    /// change was applied (caller may want to bump `resetAccumulation()`).
    /// On error returns false and sets `lastError`.
    bool sync(Scene scene)
    {
        if (_active is null) {
            _lastError = "sync: backend not initialized";
            return false;
        }

        bool touched = false;

        // 1. Drain removes (lights, meshes, materials).
        foreach (id; scene.removedLightIds) {
            if (auto h = id in lightHandles) {
                _active.destroyLight(*h);
                lightHandles.remove(id);
                touched = true;
            }
        }
        foreach (id; scene.removedMeshIds) {
            if (auto h = id in meshHandles) {
                _active.destroyMesh(*h);
                meshHandles.remove(id);
                touched = true;
            }
        }
        // No destroyMaterial in interface — bridge just forgets the handle.
        // Backend's per-resetAccumulation rebuild reclaims the Cycles-side
        // allocation. (See cycles_backend's blueprint design.)
        foreach (id; scene.removedMaterialIds) {
            matHandles.remove(id);
            touched = true;
        }

        // 2. Materials first (meshes may reference them via assignmentDirty).
        foreach (ref const mat; scene.materials.byValue) {
            const sceneId = mat.id;
            const exists  = (sceneId in matHandles) !is null;
            if (!exists || mat.dirty) {
                // Re-upload as fresh handle. Old one (if any) leaks in the
                // backend's blueprint until next resetAccumulation rebuilds
                // from scratch.
                matHandles[sceneId] = _active.uploadMaterial(mat.cm);
                touched = true;
            }
        }

        // 3. Lights.
        foreach (ref const l; scene.lights.byValue) {
            const sceneId = l.id;
            auto existing = sceneId in lightHandles;
            if (existing is null) {
                lightHandles[sceneId] = _active.uploadLight(l.desc);
                touched = true;
            } else if (l.dirty) {
                _active.destroyLight(*existing);
                lightHandles[sceneId] = _active.uploadLight(l.desc);
                touched = true;
            }
        }

        // 4. Meshes: geometry first, assignments second.
        foreach (ref const m; scene.meshes.byValue) {
            const sceneId = m.id;
            auto existing = sceneId in meshHandles;
            if (existing is null) {
                meshHandles[sceneId] = _active.uploadTriMesh(
                    m.xyz, m.normals, m.uv, m.tris);
                touched = true;
            } else if (m.geometryDirty) {
                _active.destroyMesh(*existing);
                meshHandles[sceneId] = _active.uploadTriMesh(
                    m.xyz, m.normals, m.uv, m.tris);
                touched = true;
            }
        }

        // 5. Material assignments. Done after both materials AND meshes are
        //    uploaded so both handles exist. Re-applied also after a mesh
        //    geometry re-upload (which produced a new MeshId).
        foreach (ref const m; scene.meshes.byValue) {
            const sceneId = m.id;
            if (m.materialId == 0) continue;
            if (!m.assignmentDirty && !m.geometryDirty) continue;

            auto mh = sceneId in meshHandles;
            auto sh = m.materialId in matHandles;
            if (mh is null || sh is null) {
                _lastError = "sync: dangling material assignment";
                return false;
            }
            _active.assignMaterial(*mh, *sh);
            touched = true;
        }

        // 6. Camera + environment.
        if (scene.camera.dirty) {
            _active.setCamera(scene.camera.desc);
            touched = true;
        }
        if (scene.environment.dirty) {
            _active.setEnvironment(scene.environment.desc);
            touched = true;
        }

        scene.clearDirty();
        return touched;
    }

    /// Tear down current backend, init a new one of `backendName`, then
    /// fully re-upload Scene contents. Used by the UI device/backend dropdown.
    bool switchTo(string backendName, in BackendConfig cfg, Scene scene)
    {
        if (!init(backendName, cfg)) return false;
        scene.markAllDirty();
        return sync(scene);
    }

    // -----------------------------------------------------------------------
    // RenderBackend delegates — let the panel talk to the bridge, not to
    // the backend object directly. Keeps backend-swap transparent.
    // -----------------------------------------------------------------------

    void resize(int w, int h)
    {
        if (_active !is null) _active.resize(w, h);
    }

    /// Returns false if the backend couldn't reset right now (e.g.
    /// scene mutex held by worker thread). Caller should retry next
    /// tick without committing applied state.
    bool resetAccumulation()
    {
        return _active is null ? false : _active.resetAccumulation();
    }

    void tick()
    {
        if (_active !is null) _active.tick();
    }

    bool grabPixels(ref float[] out_, out int w, out int h)
    {
        if (_active is null) return false;
        return _active.grabPixels(out_, w, h);
    }

    ulong frameVersion()
    {
        return _active is null ? 0 : _active.frameVersion();
    }

    float progress()
    {
        return _active is null ? 0.0f : _active.progress();
    }

    bool tryBindGLTexture(uint glTex, int w, int h)
    {
        if (_active is null) return false;
        return _active.tryBindGLTexture(glTex, w, h);
    }

    bool usingInterop()
    {
        return _active is null ? false : _active.usingInterop();
    }

    bool setSamples(int samples)
    {
        if (_active is null) return false;
        _config.samples = samples;
        return _active.setSamples(samples);
    }

    BackendCaps caps()
    {
        return _active is null ? BackendCaps.init : _active.caps();
    }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/// Build a backend instance by name. Returns null for unknown / unavailable.
private RenderBackend createBackend(string name)
{
    switch (name) {
        case "cycles": return new CyclesBackend();
        case "rpr":    return new RPRBackend();
        default:       return null;
    }
}
