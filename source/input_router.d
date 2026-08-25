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
// THE FIRST SLICE moved exactly the two handlers 0781's own plan names as
// the shape probe (`handleWindowEvent` + `handleMouseWheel`, 43 lines
// together) -- deliberately NOT the other five, because every one of those
// reaches `buildToolVts` and the shared pick-family/`viewportInputAllowed`/
// `dragMode`/`rmbPath`/`anySpinning` surface that task 0782's
// not-yet-extracted frame body ALSO reads every frame. Moving them without
// deciding whether that surface belongs to the router, the frame cluster, or
// a third shared piece would be exactly the "quietly redesigned input path"
// 0781 warns against.
//
// STEP 1 ANSWERED THAT QUESTION -- the shared surface got its own home
// (`InputFrameState`, source/input_frame_state.d), which this struct now
// holds as a class reference -- so STEP 2 walks the remaining five handlers
// in, one commit each, in the plan's order (2a `handleKeyDown` +
// `handleKeyUp`, 2c `handleMouseMotion`, 2d `handleMouseButtonDown/Up`, 2e
// `processEvent`). Done so far: 2a. `handleMouseMotion`,
// `handleMouseButtonDown/Up` and `processEvent` are still nested in main().
//
// The `buildToolVts` ABI trap the paragraph above names is REAL and is now
// measured rather than reasoned (task 0781 step 2a Log): the real function is
// six-parameter and lives on the cluster; `EditorApp.buildToolVts` is a
// narrow two-parameter delegate closure over it. Inside a `with (app) { ... }`
// block a bare two-argument `buildToolVts(subj, vts)` COMPILES, silently
// binding to that field (`delegate `(*with).buildToolVts`` is what dmd calls
// it when the argument list forces the error) -- so every moved call site in
// this module spells the binding out as `ifs.buildToolVts(...)`. That rule
// covers any name carried by BOTH `EditorApp` and the cluster: the hover
// triple is the other one (doc/input_state_cluster_plan.md §5).
//
// `EditorApp` fields already cover `vpm` and `layout`, referenced here bare
// under `with (app) { ... }`, exactly as every `ui/panels.d` draw function
// already does. The remaining fields below are what `handleWindowEvent`
// reads/writes that EditorApp does not carry: `window` (assigned once, by-
// value, like EditorApp's own `io`/`shader` fields), `thickLineProgram`/
// `playbackMode` (also assigned once, by-value), and `winW`/`winH`/`fbW`/
// `fbH` (mutated via `&winW` etc. inside this very handler -- pointer-
// backed, exactly EditorApp's own Edit-class-1 rule for an address-taken
// local). `winW`/`winH` are still plain main()-locals; `fbW`/`fbH` point
// into the input/frame cluster's own fields instead (task 0781 step 1a
// moved their storage there -- see input_frame_state.d) -- the pointer
// indirection here is unaffected either way.

import bindbc.sdl;
import bindbc.opengl;
import editor_app : EditorApp;
// Task 0781 step 2a -- what the two keyboard handlers reach that EditorApp
// does not carry. All of these were already module-level names in main()'s
// scope, and none of them imports this module back, so no cycle appears.
// `input_frame_state` is the cluster itself (step 1); `eventlog` is the F1/F2
// recorder's TYPE only (the instance stays a main() local, pointer-backed
// below); the rest are the free functions and __gshared state the moved
// bodies call by their own names.
import input_frame_state    : InputFrameState;
import eventlog             : EventLogger;
import toolpipe.packets     : SubjectPacket;
import operator             : VectorStack;
import shortcuts            : canonFromEvent, resolveBinding, BindingKind;
import seltype              : SelType, currentSelType;
import editmode             : EditMode;
import viewport             : Viewport3D;
import pie_state            : g_pie, armPie;
import handles.gizmo_metrics : stepGizmoHandleScale;
import log                  : logInfo;

/// The input-router cluster (task 0781). Constructed once in main() after
/// EditorApp's own wiring, and threaded the same way ToolHost/vpm/etc.
/// already are. Grows towards the other five handlers only once their
/// shared-surface question (see module doc comment) has an owner's answer.
struct InputRouter {
    EditorApp app;

    // Task 0781 step 2 -- the input/frame shared-state cluster
    // (source/input_frame_state.d), the SAME object main() holds. A class
    // REFERENCE, which is the whole reason step 1a flipped that type from a
    // struct to a `final class`: this router is the cluster's second holder,
    // and a by-value copy here would have given the router its own private
    // `dragMode`/`rmbPath`/hover triple with nothing failing to compile (see
    // doc/input_state_cluster_plan.md §2.1). Wired next to `app` below.
    InputFrameState ifs;

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

    // Task 0781 step 2a -- the F1/F2 recorder, pointer-backed by the same
    // Edit-class-1 rule as `winW`/`winH` above: `EventLogger` is a struct and
    // its INSTANCE stays a main() local, because main() still owns both its
    // lifetime (`scope(exit) recLog.close()` at the declaration) and its other
    // reader (`processEvent`'s per-event `recLog.log(*ev)`, which moves here in
    // step 2e). Copying it by value would fork the file handle; a pointer keeps
    // one recorder.
    EventLogger* recLogPtr;
    @property ref EventLogger recLog() { return *recLogPtr; }

    // Task 0781 step 2a -- the argument-carrying command dispatcher, held as a
    // DELEGATE onto main()'s own nested function rather than moved.
    // doc/input_state_cluster_plan.md §4/Q2 says to move the body once every
    // caller is router-side, and gives the deciding grep; re-run today it
    // returns exactly the four sites the plan predicts (declaration +
    // `handleKeyDown` + `doItemSelectPickAt` ×2), but `doItemSelectPickAt` does
    // not become a router method until step 2d. So this step takes the plan's
    // stated alternative -- a `bool delegate(string, string)` field, never a
    // duplicated body -- and 2d turns it into a real method when its second
    // caller arrives. The field NAME is the function's, so the moved call site
    // is textually unchanged.
    bool delegate(string, string) runCommandWithArgs;

    // The editor uses a fixed fovY=45° everywhere (see source/view.d).
    // Mirrors main()'s own `kFovY` (app.d, right after `layout.resize` at
    // init) -- duplicated rather than imported across the
    // app.d<->input_router.d pair to avoid a fresh circular-import surface for
    // a single compile-time literal; both copies must change together if the
    // fixed FOV ever does (view.d itself already repeats the same literal
    // twice, so this is the SAME pre-existing duplication, not a new one).
    // Struct-level since step 2a, when `handleKeyDown`'s F1 branch became the
    // second reader inside this type -- one copy per module, not per handler.
    enum float kFovY = 45.0f * 3.14159265358979f / 180.0f;

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
        // `kFovY` is the struct-level enum above -- same literal, same value;
        // it was this handler's own local until step 2a gave it a second
        // reader (`handleKeyDown`'s F1 branch).

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

    // ---- Task 0781 step 2a: the two KEYBOARD handlers ------------------
    //
    // `pieArmIfOpened` + `handleKeyDown` + `handleKeyUp`, relocated from
    // nested functions of the same names in app.d's main(). Bodies are
    // verbatim; the only edits are the free-name resolution this seam always
    // costs (main() locals -> InputRouter fields / `with (app)` EditorApp
    // fields) and the ONE binding below that `with (app)` would otherwise
    // have decided silently.
    //
    // WHY `ifs.buildToolVts(subj, vts)` IS SPELLED OUT, in both handlers.
    // EditorApp carries a member of that name too -- the NARROW two-parameter
    // delegate (editor_app.d, wired in main() as a real closure over the
    // cluster's six-parameter method; app.d's comment at that wiring records
    // the segfault a same-arity cast produced once). A bare
    // `buildToolVts(subj, vts)` inside a `with (app)` block is a legal call
    // against that field, so it would compile and route through the closure
    // instead of reaching the cluster directly: same behaviour, an extra
    // indirection, and a binding nobody chose. This is the ONE such name in
    // these two bodies -- measured, not assumed: the other overlap
    // doc/input_state_cluster_plan.md §5 names, the hover triple, has zero
    // occurrences here. The general rule for every step-2 commit: inside
    // `with (app)`, a name that exists on BOTH EditorApp and the cluster is
    // written `ifs.X`.
    //
    // Coverage, named rather than assumed. Three suite tests read this
    // handler BY VALUE, each through a different branch:
    // tests/test_numpad_view.d replays tests/events/numpad_view_toggle.log
    // (literal SDL_KEYDOWN scancode events) through /api/play-events and
    // asserts {viewPreset, projKind} after every press -- the numpad branch;
    // tests/test_subpatch_tab_toggle.d posts a synthesised SDLK_TAB keydown
    // and asserts the resulting per-face subpatch flags -- the SDLK_TAB
    // branch; tests/test_pie_menu.d drives the pie chord and its release --
    // the shortcut-table + `pieArmIfOpened` path. So a mutation that no-ops
    // this handler is caught by value; see the task Log for the exact
    // assertion each one reddened with.

    // Task 1800 — if the command this keypress just ran put a pie menu up,
    // remember the chord that did it, so that RELEASING that chord dismisses
    // the ring (and so that releasing any OTHER key does not). This is the only
    // place the keysym is known: the binding reaches the command through
    // `runCommandWithArgs`, which carries an argstring and no key. A pie opened
    // any other way (an `/api/command ui.pie` from a test, a button) stays
    // unarmed and simply waits for the click.
    //
    // `g_pie.armedKey == 0` is what makes this "did THIS press open it": a
    // press arriving while a ring is already up never reaches here — the grab
    // in `processEvent` swallows it.
    void pieArmIfOpened(ref SDL_KeyboardEvent kev) {
        if (g_pie.open && g_pie.armedKey == 0)
            armPie(cast(uint) kev.keysym.sym, cast(ushort) kev.keysym.mod);
    }

    void handleKeyDown(ref SDL_KeyboardEvent kev) {
        with (app) {
            // Active tool gets first dibs on key events. Tools that handle keys
            // (e.g. PenTool's Enter/Backspace/Esc) return true to consume; tools
            // that don't override onKeyDown fall through to the default false
            // and the rest of the handler runs as before.
            SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts);
            if (activeTool && activeTool.onKeyDown(kev, vts)) return;

            // YAML-driven shortcut lookup, resolved IN CONTEXT (task 1810).
            //
            // The three legacy sections and the `bindings:` list are one table by
            // the time they get here; `resolveBinding` picks the most specific row
            // whose zone / mode / armed-tool slots accept the current context, and
            // a row with no slots filled — which is every legacy row — matches
            // everywhere, exactly as before this task.
            string canon = canonFromEvent(kev.keysym.sym, cast(SDL_Keymod)kev.keysym.mod);
            if (canon.length > 0) {
                import input_context : currentInputContext;
                import seltype       : selTypeToken;
                auto ictx = currentInputContext(
                    selTypeToken(currentSelType(selTypeOrder)), activeToolId);
                immutable int bi = resolveBinding(shortcuts.bindings, canon,
                                                  ictx.zone, ictx.mode, ictx.whenTool);
                if (bi >= 0) {
                  auto bnd = shortcuts.bindings[bi];
                  if (bnd.kind == BindingKind.tool) {
                    activateToolById(bnd.id);
                    return;
                  }
                  if (bnd.kind == BindingKind.command) {
                    auto id = &bnd.id;
                    // AUTO-REPEAT MUST NOT RE-OPEN A PIE (task 1800). The ring is
                    // held-open: it closes when the chord is released, and it also
                    // closes the moment a wedge is clicked — while the chord is
                    // still physically down. From that instant the OS keeps sending
                    // this same chord as repeats, and each one would dispatch
                    // `ui.pie` again and pop the ring straight back up under the
                    // cursor. While the ring IS open no repeat gets this far (the
                    // grab in `processEvent` swallows every keydown), so this guard
                    // covers exactly the window between "closed" and "released".
                    if (*id == "ui.pie" && kev.repeat != 0) return;
                    // Interactive history nav (Ctrl+Z / Ctrl+Shift+Z) goes through
                    // the navHistory chokepoint so an active tool with an open live
                    // edit gets a chance to cancel it (instead of popping a prior
                    // committed step underneath the live preview). The command
                    // FACTORIES stay raw — they are shared with macro/replay/
                    // scripted history nav and must remain tool-agnostic.
                    if (*id == "history.undo") { navHistory(true);  return; }
                    if (*id == "history.redo") { navHistory(false); return; }
                    // A binding that pinned arguments (baked "D ccsds", or a
                    // `bindings:` row's inline "ui.pie viewport") runs immediately
                    // with them injected — no args dialog.
                    if (bnd.args.length > 0) {
                        runCommandWithArgs(*id, bnd.args);
                        pieArmIfOpened(kev);
                        return;
                    }
                    if (!tryOpenArgsDialog(*id))
                        runCommand(reg.commandFactories[*id]());
                    pieArmIfOpened(kev);
                    return;
                  }
                  {
                    auto id = &bnd.id;
                    // Route the selection-type keys through the selection-type
                    // funnel: it promotes the SelType, sets editMode in lockstep,
                    // and drops the active tool ONLY on a front-flip (pressing the
                    // key for the mode you are already in does NOT drop the tool —
                    // Stage 1 B2).
                    //
                    // `items` (task 0642) takes the OTHER funnel — `switchItemType`
                    // — because there is no EditMode to set in lockstep: EditMode
                    // is the geometry view and must keep its remembered value under
                    // SelType.Item. Same front-flip contract otherwise.
                    switch (*id) {
                        case "vertices": switchGeometryType(EditMode.Vertices); break;
                        case "edges":    switchGeometryType(EditMode.Edges);    break;
                        case "polygons": switchGeometryType(EditMode.Polygons); break;
                        case "items":    switchItemType();                      break;
                        default: break;
                    }
                    return;
                  }
                }
            }

            // Numpad view shortcuts (task 0215): 1/2/3 switch the hovered (else
            // active) viewport cell's view, toggling to the opposite face on a
            // repeat press of the same key; numpad `.` sets Perspective
            // (idempotent — repeat is a no-op). Read the SCANCODE (not keysym)
            // so this survives NumLock OFF — with NumLock off the keysym arrives
            // as SDLK_KP_END/KP_DOWN/…, but the scancode is always
            // SDL_SCANCODE_KP_1.. (bindbc-sdl scancode.d). Distinct from the
            // top-row Digit1..3 scancodes (30-32) driving edit-mode above — no
            // collision.
            //
            // Gate: this function has exactly ONE call site (the SDL_KEYDOWN
            // case below in processEvent), reached only AFTER that dispatcher's
            // own `if (io.WantTextInput && (KEYDOWN||KEYUP)) return true;` gate —
            // so io.WantTextInput is already guaranteed false by the time we get
            // here. io.WantCaptureKeyboard is NOT usable as an extra local guard
            // in this app: NavEnableKeyboard is enabled at boot (app.d ImGui
            // init), and per Dear ImGui's own doc comment WantCaptureKeyboard is
            // "also true ... when an imgui window is focused and navigation is
            // enabled" — i.e. true whenever ANY docked panel (incl. the Viewport
            // window itself) merely has nav focus, not just while a widget is
            // actively being edited. Verified empirically: it reads true for
            // EVERY keydown in --test (even a plain 'A' viewport.fit press,
            // which still fires normally because that path never checks it) —
            // gating on it here would make the numpad branch permanently dead
            // rather than test-mode-only, so it is intentionally NOT checked a
            // second time; the upstream WantTextInput gate is the real and
            // sufficient protection here, exactly as it already is for every
            // other shortcut this same function dispatches (tool activation,
            // commandIdByCanon, editModeByCanon — none of them re-check it
            // either).
            {
                import view : NumpadViewKey, nextViewForKey;
                import viewport : applyCellViewPreset;
                bool handled = true;
                NumpadViewKey nvKey;
                switch (kev.keysym.scancode) {
                    case SDL_SCANCODE_KP_1:      nvKey = NumpadViewKey.One;    break;
                    case SDL_SCANCODE_KP_2:      nvKey = NumpadViewKey.Two;    break;
                    case SDL_SCANCODE_KP_3:      nvKey = NumpadViewKey.Three;  break;
                    case SDL_SCANCODE_KP_PERIOD: nvKey = NumpadViewKey.Period; break;
                    default: handled = false; break;
                }
                if (handled) {
                    int cell = (vpm.hoveredId >= 0 && vpm.hoveredId < vpm.cellCount)
                        ? vpm.hoveredId : vpm.activeId;
                    Viewport3D vcell = vpm.views[cell];
                    applyCellViewPreset(vcell, nextViewForKey(vcell.camera.viewPreset, nvKey));
                    return;
                }
            }

            // Ctrl+Z / Ctrl+Shift+Z are dispatched via shortcuts.yaml as the
            // history.undo / history.redo commands (registered in commandFactories
            // above) — see config/shortcuts.yaml.

            switch (kev.keysym.sym) {
                case SDLK_F1:
                    recLog.close();
                    recLog.open("recording.jsonl");
                    recLog.writeViewportMeta(layout.vpX, layout.vpY,
                                             layout.vpW, layout.vpH, kFovY);
                    logInfo("rec", "started → recording.jsonl");
                    break;
                case SDLK_F2:
                    recLog.close();
                    logInfo("rec", "stopped");
                    break;
                // Esc no longer quits — Ctrl+Q (file.quit) is the canonical
                // exit shortcut now. Leaving Esc unbound here means the key
                // falls through to the global / tool handlers (e.g. cancel
                // an in-progress lasso, deselect, …) instead of killing the
                // session by accident.
                case SDLK_SPACE:
                    // Space drops an active tool; with no tool it cycles the
                    // geometry mode. Route the cycle through the selection-type
                    // funnel so selTypeOrder + the currentTypeChanged signal stay in
                    // sync (the cycle always flips the front, hence always notes a
                    // current-type change; the tool is already null so the in-funnel
                    // tool-drop is a no-op).
                    if (activeTool) setActiveTool(null);
                    else switchGeometryType(
                        cast(EditMode)((cast(int)editMode + 1) % 3));
                    break;
                case SDLK_TAB: {
                    // Toggle subpatch flag. Scope is MODE-AWARE (parity): the face
                    // selection is honored ONLY while Polygon is the current
                    // selection type — in edge/vertex/item modes a persisted face
                    // selection is ignored and the toggle applies to the WHOLE
                    // model (matches the reference editor, which drops the polygon
                    // selection's authority outside polygon mode). Whole-model when
                    // nothing is face-selected in polygon mode too. The preview
                    // rebuilds next frame via mutationVersion bumped inside
                    // setSubpatch.
                    mesh.syncSelection();
                    bool scoped = currentSelType(selTypeOrder) == SelType.Polygon
                                  && mesh.hasAnySelectedFaces();
                    foreach (fi; 0 .. mesh.faces.length) {
                        if (scoped && !mesh.isFaceSelected(fi))
                            continue;
                        mesh.setSubpatch(fi, !mesh.isFaceSubpatch(fi));
                    }
                    break;
                }
                case SDLK_MINUS:
                    stepGizmoHandleScale(-1);
                    break;
                case SDLK_EQUALS:
                    stepGizmoHandleScale(+1);
                    break;
                default: break;
            }
        }
    }

    // Key RELEASE dispatch (task 0709). `Tool.onKeyUp` has existed next to
    // `onKeyDown` since the base class was written, but until this task no
    // `case SDL_KEYUP` existed in `processEvent`'s switch at all, so no
    // release ever reached a tool: the single overrider (`SliceTool`'s X
    // chord — "while X is held, snapping is temporarily inverted") set its
    // flag on the press and had no reachable path to clear it, latching the
    // inversion for the rest of the tool session.
    //
    // THE ROUTE THIS OPENS, named deliberately rather than inherited as a
    // side effect: the active tool now gets first refusal on EVERY key
    // release, exactly as it already does on every key press. Nothing else
    // in this handler acts on a release — there is no shortcut lookup, no
    // edit-mode switch, no command dispatch on key-up — so a tool that does
    // not override `onKeyUp` (every tool but `SliceTool`) falls through to
    // the base `return false` and the release is discarded precisely as it
    // was before. The consuming `return` is kept symmetric with
    // `handleKeyDown` so a future release-side consumer has the same shape
    // to extend.
    //
    // Not wrapped in a `with (app)` block, unlike `handleKeyDown` above:
    // two names in two lines, so both bindings are written out instead of
    // inferred -- and `ifs.buildToolVts` is the same explicit-binding rule
    // stated at the block comment above, for the same reason.
    void handleKeyUp(ref SDL_KeyboardEvent kev) {
        SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts);
        if (app.activeTool && app.activeTool.onKeyUp(kev, vts)) return;
    }
}
