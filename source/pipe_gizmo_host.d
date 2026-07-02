module pipe_gizmo_host;

import bindbc.sdl;

import math    : Viewport;
import shader  : Shader;
import handler : ToolHandles;
import eventlog : queryMouse;
import falloff_handles : FalloffGizmo;
import toolpipe.packets : FalloffPacket;

// ---------------------------------------------------------------------------
// PipeGizmoHost — the single, app-level owner of the toolpipe falloff
// viewport gizmo + overlay.
//
// Today vibe3d hosts the falloff gizmo / overlay in FIVE divergent places
// (app.d standalone, XfrmTransformTool, CommandWrapperTool, and the
// overlay-only PushTool / BendTool). This module is the seam that
// collapses them into ONE persistent emitter, gated on `fp.enabled`,
// regardless of which tool (if any) is active — the host iterates the pipe
// modifiers and the falloff handles show because the falloff stage is active,
// not because some transform tool hosts them.
//
// The class is PURE ROUTING: the CALLER decides WHEN to invoke each method
// and supplies the arbiter pool for the current context (the
// per-context-arbiter invariant from the refactor plan):
//   - a TOOL is active  -> the caller passes the active tool's shared
//                          ToolHandles (banks 0/10/20 + falloff 100, single
//                          winner) so cross-bank hover arbitration survives;
//   - NO tool is active  -> the caller passes the host's OWN `handles`.
// Either way the host owns the emitter + its drag state centrally; only the
// pool varies per context.
//
// Wiring (construction in app.d, the five host-site migrations) is steps
// 2-6 of the refactor; THIS module is dormant and unreferenced.
//
// Design note (out of scope here, do not build): the seam generalizes.
// ACEN / Snap stage-gizmos could register additional emitters into the
// SAME pool through the same begin()/registerHandles()/setHaul()/update()
// arbiter cycle — the host conceptually holds a set of pipe-stage emitters,
// of which only falloff is wired today.
// ---------------------------------------------------------------------------
class PipeGizmoHost {
    // Single persistent emitter — the falloff viewport gizmo. The drag
    // state lives here, so it is independent of which tool is active.
    private FalloffGizmo gizmo;

    // The host's OWN arbiter pool, used ONLY for the no-tool case. When a
    // tool is active the caller passes the tool's shared pool instead.
    // Lazily created (GL-free, but kept lazy so the whole host can be
    // constructed before first draw). Exposed via ownPool() so the no-tool
    // caller can fetch it to pass back into draw()/tryClaimDown().
    private ToolHandles handles;

    // Part-base for the falloff emitter's handles within an arbiter pool.
    // Replaces command_wrapper.d's local FALLOFF_BASE + app.d's
    // kStandaloneFalloffBase with a single source of truth.
    enum int FALLOFF_BASE = 100;

    this() {
        // GL alloc stays lazy (matches command_wrapper.d / the app.d
        // standalone): the emitter is created on first draw, when a GL
        // context is guaranteed valid.
    }

    /// The host's own no-tool arbiter pool. The no-tool caller fetches this
    /// and hands it back into draw()/tryClaimDown() as `pool`, preserving
    /// the per-context-arbiter invariant (tool-active callers pass the
    /// tool's pool instead). Lazily created — ToolHandles holds no GL state.
    ToolHandles ownPool() {
        if (handles is null) handles = new ToolHandles();
        return handles;
    }

    // ---- draw -----------------------------------------------------------

    /// Draw the falloff overlay (always, from the packet), then — gated on
    /// `fp.enabled` — run the arbiter cycle on `pool` and draw the gizmo.
    /// `pool` is the active tool's shared ToolHandles when a tool is
    /// active, or the host's own `handles` when no tool is active (the
    /// caller decides; the host never picks the pool itself).
    ///
    /// Mirror of the falloff block in command_wrapper.d (~481-497), but
    /// using the passed-in `pool` and the mouse from queryMouse().
    ///
    /// `visualOnly` (task 0206, Quad/Split multi-cell overlays): true for a
    /// NON-interactive replica draw in a viewport cell other than the
    /// active/origin one. Skips `pool.begin()/registerHandles/setHaul/
    /// update()` entirely — NOT just to avoid re-registering into a foreign
    /// pool, but because `pool.update()` calls `Handler.setState(...)`
    /// directly on the registered handle OBJECTS (`FalloffGizmo`'s own
    /// handles — see `source/handler.d` `Handler.state`), which are SHARED
    /// regardless of which `ToolHandles` pool did the registering. Hit-
    /// testing under a foreign cell's `vp` with the ACTIVE mouse coords
    /// would resolve a wrong hot part and stomp that shared state. Skipping
    /// the whole cycle leaves the resident hot/captured state from the
    /// owner cell's last real pass untouched; `gizmo.draw()` below still
    /// renders the (world-derived) handles reprojected under `vp`, so the
    /// SAME highlighted part appears correctly in every cell.
    void draw(const ref Shader shader, const ref Viewport vp,
              const ref FalloffPacket fp, ToolHandles pool, bool visualOnly = false) {
        // The passive ImGui overlay (gradient lines / sphere wireframe /
        // disc / lasso polygon) used to be drawn here, on ImGui's
        // background list — occluded by the opaque per-cell viewport
        // image (task 0170) and never visible. It is now emitted once
        // per cell from the app.d `Viewport##k` window loop instead
        // (task 0213); only the GL handle draw remains here.
        if (!fp.enabled) return;

        if (gizmo is null) gizmo = new FalloffGizmo();

        if (!visualOnly) {
            // Host arbiter cycle: register the falloff handles into the
            // supplied pool, pin the hauled part during a drag, resolve one
            // hot/captured winner, then render.
            pool.begin();
            gizmo.registerHandles(pool, FALLOFF_BASE, fp);
            pool.setHaul(gizmo.isDragging() ? gizmo.capturedPart(FALLOFF_BASE) : -1);
            int mx, my;
            queryMouse(mx, my);
            pool.update(mx, my, vp);
        }
        gizmo.draw(shader, vp, fp);
    }

    // ---- event routing --------------------------------------------------

    /// Try to claim an LMB-down for the falloff gizmo. Returns true iff the
    /// gizmo grabbed a handle (the caller should then stop its own
    /// down-handling). The `pool` parameter is kept for symmetry / future
    /// emitters; FalloffGizmo.onMouseButtonDown takes only (e, vp, fp)
    /// (registration into the pool happens in draw()), so it is unused here.
    bool tryClaimDown(ref const SDL_MouseButtonEvent e, const ref Viewport vp,
                      const ref FalloffPacket fp, ToolHandles pool) {
        if (gizmo is null) return false;
        return gizmo.onMouseButtonDown(e, vp, fp);
    }

    /// Route an LMB motion to the in-flight falloff drag. Returns true iff
    /// the gizmo consumed it. Caller gates on isDragging() as it sees fit.
    bool routeMotion(ref const SDL_MouseMotionEvent e, const ref Viewport vp) {
        if (gizmo is null) return false;
        return gizmo.onMouseMotion(e, vp);
    }

    /// Route an LMB-up, ending any in-flight falloff drag. Returns true iff
    /// the gizmo consumed it. MUST NOT bump the tweak generation — that
    /// stays at the XfrmTransformTool call site (a later step), because the
    /// bump is specific to a direct-stage falloff drag under a held
    /// transform gesture, and the standalone / CommandWrapper up sites do
    /// not bump.
    bool routeUp(ref const SDL_MouseButtonEvent e) {
        if (gizmo is null) return false;
        return gizmo.onMouseButtonUp(e);
    }

    // ---- in-cycle (with-tool) registration ------------------------------
    //
    // When a TOOL is active, the falloff emitter must live INSIDE the tool's
    // SINGLE shared-arbiter cycle: the tool calls pool.begin(), then these
    // three methods register / pin / draw the falloff handles into that SAME
    // pool (alongside the tool's gizmo banks), so cross-bank single-winner
    // hover arbitration is preserved. The tool owns begin()/update(); the host
    // only contributes its emitter's handles + draw. (The no-tool `draw()`
    // above runs the whole cycle itself on the host's own pool instead.)

    /// Register the falloff emitter's handles into the supplied (tool-owned)
    /// pool at FALLOFF_BASE. The caller must have already called pool.begin();
    /// this just adds the falloff parts (registered FIRST = highest priority).
    void registerInto(ToolHandles pool, const ref FalloffPacket fp) {
        if (gizmo is null) gizmo = new FalloffGizmo();
        gizmo.registerHandles(pool, FALLOFF_BASE, fp);
    }

    /// Task 0212 (rotate/scale hover-highlight flicker fix, optional
    /// extension): CPU-only, idempotent re-layout of the falloff emitter's
    /// handles under `vp`, mirroring the gizmo-bank `refreshBankGeometry`
    /// prepass in XfrmTransformTool. The emitter's hit geometry (endpoint
    /// `centerBox.size`, radial size-handle positions) is view-dependent
    /// (`gizmoSize`) and shared like the T/R/S banks, but — unlike
    /// RotateHandler.startAngle / ScaleHandler's disc normal — it never
    /// discretely FLIPS (Arrow/Box-style hit shapes, only a benign size
    /// scale), so this wasn't the reported flicker; call it anyway ahead of
    /// a Test-pass hit-test for uniform robustness. No-op when no emitter
    /// exists yet (nothing registered = nothing to refresh).
    void syncGeometry(const ref Viewport vp, const ref FalloffPacket fp) {
        if (gizmo is null) return;
        gizmo.syncGeometry(vp, fp);
    }

    /// The hauled falloff part for the tool's setHaul() precedence check, or
    /// -1 if no emitter / no drag. Null-safe.
    int capturedPart() {
        return gizmo is null ? -1 : gizmo.capturedPart(FALLOFF_BASE);
    }

    /// Draw ONLY the falloff gizmo (no overlay, no begin/update — the tool
    /// owns the arbiter cycle and draws the overlay itself). Lazily creates
    /// the emitter so a tool that first observes an enabled packet here still
    /// gets a gizmo.
    void drawGizmo(const ref Shader shader, const ref Viewport vp,
                   const ref FalloffPacket fp) {
        if (gizmo is null) gizmo = new FalloffGizmo();
        gizmo.draw(shader, vp, fp);
    }

    // ---- state / lifecycle ----------------------------------------------

    /// True while a falloff endpoint / center / size drag is in flight.
    bool isDragging() const {
        return gizmo !is null && gizmo.isDragging();
    }

    /// Force-release any in-flight drag without an LMB-up. The caller
    /// invokes this on a tool-activate that interrupts a no-tool drag (as
    /// app.d does today for the standalone), and across /api/reset
    /// (cancel, NOT destroy — scene reset never destroys the gizmo).
    void cancelDrag() {
        if (gizmo !is null) gizmo.cancelDrag();
    }

    /// Release GL resources. Called once at app shutdown (fixes the
    /// ef43dd9 standalone-gizmo leak). The host's own arbiter pool holds no
    /// GL state of its own (it only references the emitter's handles), so
    /// there is nothing to tear down for `handles`.
    void destroyGL() {
        if (gizmo !is null) {
            gizmo.destroy();
            gizmo = null;
        }
    }
}
