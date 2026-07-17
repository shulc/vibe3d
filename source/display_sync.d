module display_sync;

import mesh : Mesh, GpuMesh;
import mesh_edit_delta : MeshEditScope;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;

/// Change classes that require a DISPLAY refresh (GPU upload + pick-cache
/// resize/invalidate) of the active mesh — the mask the bus-driven refresh
/// engine (campaign 0407 §D4-в) keys on, both at the frame's flush site
/// (capture-and-upload in app.d's main loop) and in the mid-batch pull guard
/// `ensureDisplayCurrent` in front of every VBO reader that can run BEFORE
/// the flush (pickers, HTTP providers).
///
/// Deliberately excludes:
///   • Marks — selection/hover highlight is drawn each frame straight from
///     the mesh marks arrays (gpu.drawVertices/drawEdges), never baked into
///     the VBO; the subpatch-preview Tab gate keys on Marks separately.
/// Includes Material even though it is not geometry: per-face material ids
/// ARE baked into the VBO (GpuMesh.upload reads faceMaterial into matIdVbo).
enum uint DisplayRefreshMask =
      MeshEditScope.Position
    | MeshEditScope.Points
    | MeshEditScope.Polygons
    | MeshEditScope.Material;

// The display-refresh gate (seam 2b) — since task 0427 a TOOL-side seam.
//
// Mutating COMMANDS no longer refresh the display at all: they mutate and
// publish change-bus flags (noteChange/commitChange, mostly via the mesh
// kernels), and app.d's main loop drives the refresh — the flush-site
// capture-and-upload plus the mid-batch `ensureDisplayCurrent` pull guards,
// both keyed on `DisplayRefreshMask` below (campaign 0407 §D4-в).
//
// `refreshDisplay` remains the shared primitive for the INTERACTIVE paths
// that own their display mid-gesture (tool drag fills / previews), and for
// app.d's own pull guard. A tool runs against the mesh it was bound to,
// which is NOT necessarily the one on screen once multiple layers coexist —
// so the gate compares the target mesh against the app-installed
// `activeMeshResolver` and no-ops the GPU upload + cache resize/invalidate
// when they differ: the active layer's display buffer and the GLOBAL pick
// caches are never written against a foreign (background) mesh.
//
// app.d installs `activeMeshResolver` once at init
// (`() => document.activeMesh()`). The mesh the resolver returns is the one
// currently rendered, so the gate is the single authority on "is this
// target the mesh on screen?".

/// Installed once by app.d at init. Returns the mesh currently displayed
/// (the active layer's mesh). Stage 0a: resolves to the one global mesh.
__gshared Mesh* delegate() activeMeshResolver;

/// Gated display refresh — shared by the interactive tool paths (drag fills
/// / previews that own the display mid-gesture) and app.d's mid-batch pull
/// guard.
///
/// When `target` is the active (on-screen) mesh, this performs the full
/// GPU upload + cache resize/invalidate in one call. When
/// `target` is a non-active (background) mesh, it is a no-op — the active
/// layer's display buffer and the global pick caches are never written
/// against a foreign mesh. The active layer is re-uploaded by the
/// layer-switch hook when it becomes active, so nothing is left stale.
///
/// The `resize` calls are guarded inside the cache types (a resize to the
/// same length is a genuine no-op), so routing both topology-changing and
/// position-only refreshes through this single helper is uniform:
/// topology-preserving refreshes hit the same-length fast path.
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
