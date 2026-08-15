module input_router;

// Task 0781 (campaign 0407 §V1 4.3, chain from 0678 §2C A10 / 0722): the
// input-router cluster. 0722 measured that the seven SDL-event handlers
// nested in app.d's main() close over 27 of main()'s locals (7 of the 27
// being the handlers themselves calling each other) and stopped there,
// because those ~20 remaining names are NOT one kind of thing -- some are
// plain references the router needs but does not own, some are the
// router's own state that should MOVE, and some are neighbouring nested
// functions each needing its own yes/no (see doc/tasks/work/0781-*.md and
// its Log for the full classification).
//
// `main()` is not a class, so the mixin-template seam that carried the
// pen/transform splits (0718/0719) does not apply the way it did there;
// this module instead follows the SAME seam 0415/0419/0722 already built
// for the UI-panel block: a plain struct of pointer-backed properties /
// by-value class-refs (`EditorApp`), constructed once in main() and
// threaded through. `InputRouter` is a SEPARATE cluster from `EditorApp`
// itself (per audit A10: EditorApp already carries ~190 members and did
// not earn input-router logic) that HOLDS an `EditorApp app` by value
// (cheap -- EditorApp is itself pointers/delegates/class-refs, already
// passed by value into every panel-draw call) for everything already
// wired there, plus its own small reference/state surface for what
// EditorApp does not (yet) carry.
//
// THIS FIRST SLICE moves exactly the two handlers 0781's own plan names as
// the shape probe (`handleWindowEvent` + `handleMouseWheel`, 43 lines
// together) -- deliberately NOT the other five. Every other handler
// (`handleKeyDown`, `handleMouseButtonDown/Up`, `handleMouseMotion`,
// `processEvent`) reaches `buildToolVts` with its 4 trailing cursor/gesture
// args (a wider signature than the 2-arg delegate `EditorApp.buildToolVts`
// already wires -- app.d's own comment at the LATE-wiring site calls out
// the ABI risk of casting across that mismatch) and the shared
// pick-family/`viewportInputAllowed`/`dragMode`/`rmbPath`/`anySpinning`
// surface that task 0782's not-yet-extracted frame body ALSO reads every
// frame (app.d lines ~6862-7019, ~8039-8329). Moving those five without
// deciding whether that shared surface belongs to the router, the frame
// cluster, or a third shared piece would be exactly the "quietly
// redesigned input path" 0781 warns against -- so they stay in main() for
// now. See the task Log for the full per-name table.
//
// `EditorApp` fields already cover `vpm` and `layout`, referenced here bare
// under `with (app) { ... }`, exactly as every `ui/panels.d` draw function
// already does. The remaining fields below are main()-locals
// `handleWindowEvent` reads/writes that EditorApp does not carry: `window`
// (assigned once, by-value, like EditorApp's own `io`/`shader` fields),
// `thickLineProgram`/`playbackMode` (also assigned once, by-value), and
// `winW`/`winH`/`fbW`/`fbH` (mutated via `&winW` etc. inside this very
// handler -- pointer-backed, exactly EditorApp's own Edit-class-1 rule for
// an address-taken local).

import bindbc.sdl;
import bindbc.opengl;
import editor_app : EditorApp;

/// The input-router cluster (task 0781). Constructed once in main() after
/// EditorApp's own wiring, and threaded the same way ToolHost/vpm/etc.
/// already are. Grows towards the other five handlers only once their
/// shared-surface question (see module doc comment) has an owner's answer.
struct InputRouter {
    EditorApp app;

    // ---- (в) by-value: assigned exactly once in main(), never reassigned
    //      (same rule EditorApp already applies to its own `io`/`shader`/
    //      `thickLineProgram`-shaped fields) ----
    SDL_Window* window;
    bool        playbackMode;
    GLuint      thickLineProgram;

    // ---- (а) pointer-backed: mutated in place via `&x` inside
    //      handleWindowEvent (SDL_GetWindowSize / SDL_GL_GetDrawableSize
    //      write through the pointer) -- EditorApp's own Edit-class-1 rule
    //      for an address-taken local (call-site edit `&x -> &x()`, since
    //      `&propertyCall` addresses the property FUNCTION, not the `ref`
    //      it returns). `fbW`/`fbH` are ALSO read every frame by the
    //      not-yet-extracted frame body (app.d ~8039-8329); `winW`/`winH`
    //      have no other reader once init finishes, but stay pointer-backed
    //      for the same address-of reason regardless. ----
    int* winWPtr;
    @property ref int winW() { return *winWPtr; }
    int* winHPtr;
    @property ref int winH() { return *winHPtr; }
    int* fbWPtr;
    @property ref int fbW() { return *fbWPtr; }
    int* fbHPtr;
    @property ref int fbH() { return *fbHPtr; }

    // Task 0219 window resize (task 0781 relocation). Verbatim body from
    // app.d's main() -- only the free-name resolution changed (main()
    // locals -> InputRouter fields / `with (app)` EditorApp fields).
    //
    // NOT covered by any test: every fixture in tests/events/*.log that
    // carries an SDL_WINDOWEVENT uses a sub-event other than
    // SDL_WINDOWEVENT_SIZE_CHANGED (task 0781 Log has the grep) -- the
    // comment already inside this handler says why ("--test never resizes
    // the window"). Recorded here rather than silently assumed green.
    void handleWindowEvent(ref SDL_WindowEvent we) {
        import viewport : ViewportManager;
        import eventlog : setReplayCurrentViewport;
        import handles.gl_util : initThickLineProgram;
        // The editor uses a fixed fovY=45° everywhere (see source/view.d).
        // Mirrors main()'s own `kFovY` (app.d, right after `layout.resize`
        // at init) -- duplicated rather than imported across the
        // app.d<->input_router.d pair to avoid a fresh circular-import
        // surface for a single compile-time literal; both copies must
        // change together if the fixed FOV ever does (view.d itself
        // already repeats the same literal twice, so this is the SAME
        // pre-existing duplication, not a new one).
        enum float kFovY = 45.0f * 3.14159265358979f / 180.0f;

        if (we.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
            with (app) {
                if (playbackMode)
                    SDL_SetWindowSize(window, we.data1, we.data2);
                SDL_GetWindowSize(window, &winW(), &winH());
                SDL_GL_GetDrawableSize(window, &fbW(), &fbH());
                layout.resize(winW, winH);
                glViewport(0, 0, fbW, fbH);
                initThickLineProgram(thickLineProgram, fbW, fbH);
                // Keep replay-time pixel remapping calibrated to the new layout.
                setReplayCurrentViewport(layout.vpX, layout.vpY,
                                         layout.vpW, layout.vpH, kFovY);

                // Single event-driven writer of the picking region (vpm.l*) and
                // reflow of the live cells' rects on a resize.  This is a near-
                // dead path in practice — the interactive ImGui window loop
                // re-stamps every cell's rect from GetContentRegionAvail/
                // GetCursorScreenPos on the very next frame, and --test never
                // resizes the window — but it keeps vpm.l* (read by
                // viewportUnderCursor/applyLayout) coherent for the narrow
                // window between this event and that next stamp.  Only rects are
                // touched (NOT a full applyLayout, which would also reset
                // independence/preset).
                vpm.lx = layout.vpX; vpm.ly = layout.vpY;
                vpm.lw = layout.vpW; vpm.lh = layout.vpH;
                int[4] _rxs, _rys, _rws, _rhs;
                ViewportManager.cellRectsFor(vpm.layout, vpm.lx, vpm.ly, vpm.lw, vpm.lh,
                                             _rxs, _rys, _rws, _rhs);
                foreach (k; 0 .. vpm.cellCount) {
                    vpm.views[k].winX = _rxs[k]; vpm.views[k].winY = _rys[k];
                    vpm.views[k].winW = _rws[k]; vpm.views[k].winH = _rhs[k];
                }
            }
        }
    }

    // Task 0217 coupled zoom (task 0781 relocation). Verbatim body --
    // needs nothing beyond `app.vpm`, already an EditorApp field, so this
    // handler adds ZERO new members on its own.
    //
    // Covered: tests/test_camera.d's "WHEEL ZOOM: SDL_MOUSEWHEEL changes
    // camera distance" unittest plays an SDL_MOUSEWHEEL event through
    // /api/play-events and asserts the resulting camera distance -- a
    // mutation that no-ops this handler's body is caught by value, not by
    // inference.
    void handleMouseWheel(ref SDL_MouseWheelEvent wheel) {
        with (app) {
            if (wheel.y == 0) return;
            // Coupled zoom (task 0217): a wheel zoom over a default follower
            // (e.g. an ortho Quad cell) writes the linkage owner's distance, not
            // the hovered cell's own (which resolvedSnapshot never reads unless
            // that cell has `viewport.indScale` on).
            int hid = vpm.hoveredId >= 0 ? vpm.hoveredId : vpm.activeId;
            vpm.scaleOwnerCamera(hid).zoom(wheel.y * 10);
        }
    }
}
