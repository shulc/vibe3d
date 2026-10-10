module viewport_overlay_mode;

// Task 6361: the per-cell decision depends only on cell identity and whether
// any overlay exists. Keeping this lower policy module import-free lets the
// viewport renderer name the mode without application context; the import
// census and Flow C in tests/test_quad_overlay_all_cells.d are its witnesses.

/// Per-cell overlay-draw mode for the N-cell viewport loop (task 0206 quad/
/// split overlays). Moved app.d -> editor_app.d in task 0419, then here in
/// task 6361 so the viewport renderer no longer imports editor_app.
enum OverlayMode { None, Visual, Interactive }

/// The per-cell overlay-draw decision for the N-cell FBO loop, in ONE place
/// (task 1650). The render loop calls this once per considered cell and stamps
/// `Viewport3D.lastOverlayMode`; `/api/viewport/display` reports that stamp and
/// must not call this (see that field).
///
/// `anyOverlay` is "there is something to draw at all"
/// (`activeTool !is null || anyFalloffActive()`), which is exactly the pair of
/// branches inside `renderViewportSceneToFbo`'s overlay block. The owner cell
/// gets `Interactive`; EVERY other live cell gets `Visual`.
///
/// **There is deliberately no tool-type term here.** Until task 1650 the
/// non-owner branch was gated on a hand-written list of concrete tool classes
/// (`XfrmTransformTool` / `CommandWrapperTool` / no-tool-falloff), so a tool
/// that COMPOSES a transform wrapper instead of inheriting one — `EdgeExtendTool`,
/// `EdgeBevelTool` — failed both casts and its cells were told to draw nothing.
/// The user-visible defect was that in a Quad layout those gizmos appeared only
/// in the cell under the cursor.
///
/// What makes dropping the list safe is NOT that every tool honours
/// `Tool.draw`'s `visualOnly` contract — measured, most do not: of the 38
/// `Tool.draw` overrides only 11 read the flag in their body, and 20 of the
/// remaining 27 write `cachedVp` and/or run a `ToolHandles` register/hit-test
/// cycle unconditionally. It is `viewport.overlayDrawOrder`, which visits every
/// non-owner cell FIRST and the owner LAST: every one of those writes is
/// overwritten by the owner's own `Interactive` draw before the frame ends, and
/// no event handling interleaves inside a draw pass. (The same audit found no
/// `draw` body that mutates the mesh or fires a command, so nothing ACCUMULATES
/// across the extra per-cell calls either — that, not the flag, is the property
/// the ordering cannot rescue.) `visualOnly` remains the right contract and the
/// cheaper path; it is simply not what this gate rests on.
OverlayMode resolveOverlayMode(int cellId, int ownerId, bool anyOverlay)
        pure @safe nothrow @nogc {
    if (!anyOverlay) return OverlayMode.None;
    return (cellId == ownerId) ? OverlayMode.Interactive : OverlayMode.Visual;
}
