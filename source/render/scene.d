/// Backend-agnostic render Scene IR.
///
/// Persistent representation of "what is being rendered" — meshes, lights,
/// materials, camera, environment. Lives across IPR sessions and across
/// backend hot-swap (Cycles ↔ RPR). Follows a data/sync split: this module
/// owns the data, `render.backend_bridge` is the synchroniser that pushes
/// diffs into a `RenderBackend`.
///
/// Sync model:
///   - Each item carries a `dirty` flag set by mutators.
///   - Removals queue into `removedXxxIds` so the bridge can call
///     `backend.destroyXxx` on the old handle before forgetting it.
///   - `clearDirty()` is called by the bridge after a successful sync.
///   - On hot-swap the bridge ignores dirty bits and re-uploads everything.
///
/// Scene IDs are this module's own monotonic counters. They are NOT the
/// `MeshId / MaterialId / LightId` opaque handles returned by the backend
/// — the bridge owns the scene-id ↔ backend-handle map.
module render.scene;

version (WithRender):

import render.backend : LightDesc, CameraDesc, EnvDesc, CompiledMaterial;

// ---------------------------------------------------------------------------
// Per-item descriptors
// ---------------------------------------------------------------------------

struct SceneMesh
{
    ulong   id;
    float[] xyz;          // 3 floats / vertex
    float[] normals;      // 3 floats / vertex (or empty → flat shading)
    float[] uv;           // 2 floats / vertex (or empty)
    int[]   tris;         // 3 ints / triangle
    ulong   materialId;   // 0 = unassigned

    bool    geometryDirty;   // xyz / normals / uv / tris changed
    bool    assignmentDirty; // materialId changed
}

struct SceneLight
{
    ulong     id;
    LightDesc desc;
    bool      dirty;
}

struct SceneMaterial
{
    ulong            id;
    CompiledMaterial cm;
    bool             dirty;
}

struct SceneCamera
{
    CameraDesc desc;
    bool       dirty;
}

struct SceneEnvironment
{
    EnvDesc desc;
    bool    dirty;
}

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

final class Scene
{
    // Items keyed by scene-id. AA for O(1) lookup; iteration order is
    // non-deterministic but stable per AA layout, which is fine for sync.
    private SceneMesh[ulong]     _meshes;
    private SceneLight[ulong]    _lights;
    private SceneMaterial[ulong] _materials;

    SceneCamera      camera;
    SceneEnvironment environment;

    // Deferred deletes — bridge consumes them in sync(), then clears.
    ulong[] removedMeshIds;
    ulong[] removedLightIds;
    ulong[] removedMaterialIds;

    private ulong _nextId = 1;

    // -----------------------------------------------------------------------
    // Read views (const access to AA values)
    // -----------------------------------------------------------------------

    const(SceneMesh[ulong])     meshes()    const { return _meshes; }
    const(SceneLight[ulong])    lights()    const { return _lights; }
    const(SceneMaterial[ulong]) materials() const { return _materials; }

    // -----------------------------------------------------------------------
    // Mesh mutators
    // -----------------------------------------------------------------------

    ulong addMesh(in float[] xyz, in float[] normals, in float[] uv, in int[] tris)
    {
        const id = _nextId++;
        SceneMesh m;
        m.id            = id;
        m.xyz           = xyz.dup;
        m.normals       = normals.dup;
        m.uv            = uv.dup;
        m.tris          = tris.dup;
        m.geometryDirty = true;
        _meshes[id]     = m;
        return id;
    }

    /// Replace geometry for an existing mesh. Material assignment is kept.
    void updateMeshGeometry(ulong id, in float[] xyz, in float[] normals,
                            in float[] uv, in int[] tris)
    {
        auto p = id in _meshes;
        if (p is null) return;
        p.xyz           = xyz.dup;
        p.normals       = normals.dup;
        p.uv            = uv.dup;
        p.tris          = tris.dup;
        p.geometryDirty = true;
    }

    void assignMaterial(ulong meshId, ulong matId)
    {
        auto p = meshId in _meshes;
        if (p is null) return;
        if (p.materialId == matId) return;
        p.materialId      = matId;
        p.assignmentDirty = true;
    }

    void removeMesh(ulong id)
    {
        if ((id in _meshes) is null) return;
        _meshes.remove(id);
        removedMeshIds ~= id;
    }

    // -----------------------------------------------------------------------
    // Material mutators
    // -----------------------------------------------------------------------

    ulong addMaterial(in CompiledMaterial cm)
    {
        const id = _nextId++;
        _materials[id] = SceneMaterial(id, cm, /*dirty*/ true);
        return id;
    }

    void updateMaterial(ulong id, in CompiledMaterial cm)
    {
        auto p = id in _materials;
        if (p is null) return;
        p.cm    = cm;
        p.dirty = true;
    }

    void removeMaterial(ulong id)
    {
        if ((id in _materials) is null) return;
        _materials.remove(id);
        removedMaterialIds ~= id;
    }

    // -----------------------------------------------------------------------
    // Light mutators
    // -----------------------------------------------------------------------

    ulong addLight(in LightDesc ld)
    {
        const id = _nextId++;
        _lights[id] = SceneLight(id, ld, /*dirty*/ true);
        return id;
    }

    void updateLight(ulong id, in LightDesc ld)
    {
        auto p = id in _lights;
        if (p is null) return;
        p.desc  = ld;
        p.dirty = true;
    }

    void removeLight(ulong id)
    {
        if ((id in _lights) is null) return;
        _lights.remove(id);
        removedLightIds ~= id;
    }

    // -----------------------------------------------------------------------
    // Singleton-ish: camera + environment
    // -----------------------------------------------------------------------

    void setCamera(in CameraDesc cd)
    {
        camera.desc  = cd;
        camera.dirty = true;
    }

    void setEnvironment(in EnvDesc ed)
    {
        environment.desc  = ed;
        environment.dirty = true;
    }

    // -----------------------------------------------------------------------
    // Sync support
    // -----------------------------------------------------------------------

    /// Reset all dirty bits + drain pending-remove queues. Called by the
    /// bridge after a successful incremental sync.
    void clearDirty()
    {
        foreach (ref m; _meshes.byValue) {
            m.geometryDirty   = false;
            m.assignmentDirty = false;
        }
        foreach (ref l; _lights.byValue) l.dirty = false;
        foreach (ref mat; _materials.byValue) mat.dirty = false;
        camera.dirty      = false;
        environment.dirty = false;
        removedMeshIds.length     = 0;
        removedLightIds.length    = 0;
        removedMaterialIds.length = 0;
    }

    /// Mark every existing item dirty (for hot-swap full re-upload).
    void markAllDirty()
    {
        foreach (ref m; _meshes.byValue) {
            m.geometryDirty   = true;
            m.assignmentDirty = (m.materialId != 0);
        }
        foreach (ref l;   _lights.byValue)    l.dirty   = true;
        foreach (ref mat; _materials.byValue) mat.dirty = true;
        camera.dirty      = true;
        environment.dirty = true;
        // Pending removes are intentionally NOT replayed — they refer to
        // ids that no longer exist on the new backend either.
        removedMeshIds.length     = 0;
        removedLightIds.length    = 0;
        removedMaterialIds.length = 0;
    }

    /// True iff anything needs syncing.
    bool isDirty() const
    {
        if (camera.dirty || environment.dirty) return true;
        if (removedMeshIds.length || removedLightIds.length
            || removedMaterialIds.length) return true;
        foreach (ref const m; _meshes.byValue)
            if (m.geometryDirty || m.assignmentDirty) return true;
        foreach (ref const l;   _lights.byValue)    if (l.dirty)   return true;
        foreach (ref const mat; _materials.byValue) if (mat.dirty) return true;
        return false;
    }
}
