module display_sync;

import mesh : Mesh;
import mesh_gpu : GpuMesh;
import perf_probe : g_perf, Cat;

// The display-refresh gate (seam 2b) — since task 0427 a TOOL-side seam.
//
// Mutating COMMANDS no longer refresh the display at all: they mutate and
// publish change-bus flags (noteChange/commitChange, mostly via the mesh
// kernels), and app.d's main loop drives the refresh — the flush-site
// capture-and-upload plus the mid-batch `ensureDisplayCurrent` pull guards,
// both keyed on `mesh_edit_delta.DisplayRefreshMask` (campaign 0407 §D4-в).
//
// `refreshDisplay` remains the shared primitive for the INTERACTIVE paths
// that own their display mid-gesture (tool drag fills / previews), and for
// app.d's own pull guard. A tool runs against the mesh it was bound to,
// which is NOT necessarily the one on screen once multiple layers coexist —
// so the gate compares the target mesh against the app-installed
// `activeMeshResolver` and no-ops the GPU upload when they differ: the
// active layer's display buffer is never written against a foreign
// (background) mesh.
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
/// When `target` is the active (on-screen) mesh, this performs the GPU
/// upload. When `target` is a non-active (background) mesh, it is a no-op
/// — the active layer's display buffer is never written against a foreign
/// mesh. The active layer is re-uploaded by the layer-switch hook when it
/// becomes active, so nothing is left stale.
///
/// UNTIL TASK 1930 this helper also took three pick-cache pointers (the
/// vertex / edge / face-bounds caches of the since-deleted `viewcache`
/// module) and resized+invalidated them here. That payload had no readers
/// and no writers — the pick path (`gpu_select`, the BVH) never looked at
/// it — so the work was per-frame byte-clearing of arrays nobody read, and
/// the parameters existed only to thread three pointers through every
/// interactive tool. Both are gone; the camera term they were nominally
/// guarding lives at its real consumer as `CameraStamp`
/// (`camera_stamp.d`), keyed by `gpu_select`'s slot.
void refreshDisplay(Mesh* target, GpuMesh* gpu) {
    // Resolver not installed (e.g. tools/tests that construct commands
    // without app init): fall back to the legacy unconditional refresh so
    // those paths behave exactly as before this seam landed.
    if (activeMeshResolver !is null && target !is activeMeshResolver())
        return; // recorded layer not on screen — display refresh is a no-op

    // Perf (task 1370): the REFRESH half of every interactive-tool preview
    // rebuild — a full `gpu.upload`. (Until task 1930 it also paid three
    // cache resize/invalidate pairs; see the doc comment above.)
    // Timed here, once, rather than at each caller — see Cat.previewRefresh.
    //
    // Opened AFTER the background-mesh gate above, deliberately: a no-op
    // return must not land a ~0 ns sample, or `count` would report refusals
    // as work (the same rule the tool-side `Cat.toolPreview` timers follow,
    // and task 1370's M1 mutation shows what ignoring it buys).
    //
    // This is the shared primitive, so app.d's pull guard and the other
    // interactive tools reach it too; that the perf lane's window contains
    // ONLY its driven rebuilds is checked by invariant I8c, not assumed.
    auto zRefresh = g_perf.scope_(Cat.previewRefresh);

    gpu.upload(*target);
}
