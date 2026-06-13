module display_sync;

import mesh : Mesh, GpuMesh;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;

// Seam 2b — the display-refresh gate.
//
// Mutating commands run their apply()/revert() against the Mesh* they were
// bound to at fire time (the command base's `Mesh* mesh` field). That mesh
// is NOT necessarily the one currently on screen once multiple layers
// coexist: an undo that reverts a background layer must mutate that layer's
// mesh + publish change-bus flags as usual, but it must NOT write the active
// layer's GPU display buffer or resize the GLOBAL pick caches against the
// foreign mesh.
//
// All such command refresh paths funnel through `refreshDisplay` below. The
// gate compares the command's target mesh against the app-installed
// `activeMeshResolver` and no-ops the GPU upload + cache resize/invalidate
// when they differ. In Stage 0a there is exactly one mesh, so the resolver
// always matches the target ⇒ this is provably byte-neutral (every command
// still uploads + resizes + invalidates exactly as before).
//
// app.d installs `activeMeshResolver` once at init (Stage 0a: `() => &mesh`;
// Stage 0b: `() => document.activeMesh()`). The same delegate the resolver
// returns is the one currently rendered, so the gate is the single authority
// on "is this command's mesh the one on screen?".

/// Installed once by app.d at init. Returns the mesh currently displayed
/// (the active layer's mesh). Stage 0a: resolves to the one global mesh.
__gshared Mesh* delegate() activeMeshResolver;

/// Gated display refresh shared by every mutating command's apply()/revert().
///
/// When `target` is the active (on-screen) mesh, this performs the same
/// GPU upload + cache resize/invalidate the command bodies did inline. When
/// `target` is a non-active (background) mesh, it is a no-op — the active
/// layer's display buffer and the global pick caches are never written
/// against a foreign mesh. The active layer is re-uploaded by the
/// layer-switch hook when it becomes active, so nothing is left stale.
///
/// The `resize` calls are guarded inside the cache types (a resize to the
/// same length is a genuine no-op), so routing both the resize-and-invalidate
/// commands and the invalidate-only commands through this single helper is
/// byte-neutral: topology-preserving commands hit the same-length fast path.
void refreshDisplay(Mesh* target, GpuMesh* gpu,
                    VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
    // Resolver not installed (e.g. tools/tests that construct commands
    // without app init): fall back to the legacy unconditional refresh so
    // those paths behave exactly as before this seam landed.
    if (activeMeshResolver !is null && target !is activeMeshResolver())
        return; // recorded layer not on screen — display refresh is a no-op

    gpu.upload(*target);
    vc.resize(target.vertices.length);                          vc.invalidate();
    ec.resize(target.edges.length);                             ec.invalidate();
    fc.resize(target.vertices.length, target.faces.length);     fc.invalidate();
}
