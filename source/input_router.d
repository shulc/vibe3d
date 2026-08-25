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
// holds as a class reference -- so STEP 2 walked the remaining five handlers
// in, one commit each, in the plan's order (2a `handleKeyDown` +
// `handleKeyUp`, 2c `handleMouseMotion`, 2d `handleMouseButtonDown/Up`, 2e
// `processEvent`). STEP 2 IS COMPLETE: all seven handlers, the dispatcher
// that calls six of them, and the three picker bodies the press/motion pair
// reached through delegate fields are members of this struct. main()'s event
// loop now touches the input path at exactly two sites, both spelled
// `router.processEvent(...)`.
//
// What main() still keeps is the FORWARDER SET the frame body reads -- the
// cluster's `dragMode`/`rmbPath`/`anySpinning`/`buildToolVts`/hover-triple/
// `fbW`/`fbH`/`g_viewportWindowHovered`/`previewIndexSpaceStale` and the four
// surviving `pickX` wrappers. Those are step 3's, and step 3 is a rewrite of
// the frame body's call sites, not of this module.
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
import editor_app : EditorApp, RecordMode, Layout;
// Task 0781 step 2a -- what the two keyboard handlers reach that EditorApp
// does not carry. All of these were already module-level names in main()'s
// scope, and none of them imports this module back, so no cycle appears.
// `input_frame_state` is the cluster itself (step 1); `eventlog` is the F1/F2
// recorder's TYPE only (the instance stays a main() local, pointer-backed
// below); the rest are the free functions and __gshared state the moved
// bodies call by their own names.
import input_frame_state    : InputFrameState, DragMode;
import eventlog             : EventLogger, setOverrideMouse;
import toolpipe.packets     : SubjectPacket, GesturePacket, GestureTrack;
import operator             : VectorStack;
import shortcuts            : canonFromEvent, resolveBinding, BindingKind;
import seltype              : SelType, currentSelType, viewportPickType;
import editmode             : EditMode;
import viewport             : Viewport3D, ViewportManager;
// Task 0781 step 2c -- what the MOTION handler reaches beyond the two
// keyboard ones: `DragMode` (the cluster's enum, above), `GestureTrack`/
// `GesturePacket` (the cooked 2D event), `setOverrideMouse` (eventlog's
// replay-time cursor override), `Viewport`/`Vec3` (the camera-drag math)
// and `ImVec2` (the lasso trail's element type).
import math                 : Viewport, Vec3, ModelSpace, projectionSpace,
                              projectToWindow, pointInPolygon2D, frontFacingLocal;
import d_imgui.imgui_h      : ImVec2;
import pie_state            : g_pie, armPie, aimPie, closePie;
import handles.gizmo_metrics : stepGizmoHandleScale;
import log                  : logInfo;
// Task 0781 step 2d -- what the PRESS/RELEASE pair reaches beyond the three
// handlers already here. `ImGui` is the focus drop on a viewport click;
// `View` is `tbSpinCam`'s type; `snapshot`/`selection_edit`/`loop`/`connect`
// back the interactive-selection session and the double-click commands;
// `document`/`symmetry_pick`/the `math` names above are the RMB lasso's
// geometry half; the three `ai.*` modules are the press handler's
// interaction-log capture. None of them imports this module back.
import ImGui = d_imgui;
import view                 : View;
import snapshot             : SelectionSnapshot;
import document             : primaryModelSpace;
import symmetry_pick        : symmetricSelectVertex, symmetricSelectEdge,
                              symmetricSelectFace;
import commands.mesh.selection_edit : MeshSelectionEdit;
import commands.select.loop    : SelectLoop;
import commands.select.connect : SelectConnect;
import ai.element_candidates : collectElementCandidates,
                               resolveElementCandidateDecision,
                               publishElementCandidates;
import ai.interaction       : AiInteractionContext, AiInteractionPhase, AiIntent;
import ai.interaction_log   : makeAiInteractionLogRecord;
// Task 0781 step 2e -- what the DISPATCHER and the three picker bodies reach
// beyond the six handlers `processEvent` calls. `imgui_event_gate` is the ONE
// door into ImGui (its own unittest scans for a second caller -- see
// tests/unit/imgui_event_gate_test.d, whose existence check now names THIS
// module, because the dispatcher lives here); `item_pick` is only
// `pickItemUnderCursor`'s return type; `RecordMode` is `runUiCommand`'s second
// parameter and `Layout` is `applyWindowMetrics`' first. `pie_state` gained
// `aimPie`/`closePie` (the modal grab at the top of `processEvent`) and
// `ai.element_candidates` gained `publishElementCandidates` (the two picker
// bodies' publish). None of them imports this module back.
import imgui_event_gate     : feedImGui, keyBelongsToEditor;
import item_pick            : ItemHit;

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
    //      not-yet-extracted frame body (the frame body in app.d (the fbW/fbH readers around the FBO resize and the per-frame upload)); `winW`/`winH`
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

    // The two SDL-event logs, pointer-backed by the same Edit-class-1 rule as
    // `winW`/`winH` above -- and, like them, a NAMED exception to §4's "state
    // that moves is state that MOVES" rather than a shortcut around it.
    //
    // WHY THEY ARE NOT ROUTER STATE, stated once for both. `EventLogger` is a
    // struct, and main() owns each instance's whole LIFETIME: it decides from
    // the CLI flags whether to open (`evLog.open("events.log")` under
    // `!playbackMode`), it writes the viewport-metadata header the moment the
    // layout is known (`evLog.writeViewportMeta`, ~580 lines further down),
    // and it registers `scope(exit) evLog.close()` / `scope(exit)
    // recLog.close()` AT the declarations -- roughly 3,580 lines before
    // `InputRouter router;` exists. Moving the storage here would mean
    // re-registering those two `scope(exit)`s in the router-wiring block, which
    // reorders them against the ~20 other `scope(exit)`s declared in between
    // (`SDL_DestroyWindow`, `SDL_GL_DeleteContext`, the GL program deletes,
    // `gpu.destroy()`, `vpm.shutdown()`, `persistPrefsOnExit()`): both loggers
    // close LAST today and would close in the middle of GL teardown instead.
    // 0781's whole contract is byte-identical behaviour, so the pointer stays
    // and the reason is written down rather than left to be re-derived.
    //
    // Copying either by value would also fork the `active` flag: `File` is
    // reference-counted and would be shared, but a `close()` on one copy leaves
    // the other still believing it is open. A pointer keeps one recorder.
    //
    // `evLog` arrived in step 2e with `processEvent` (its per-event
    // `evLog.log(*ev)` is that method's first line); `recLog` arrived in 2a for
    // the F1/F2 recording branch and step 2e brought its second reader, the
    // per-event `recLog.log(*ev)` on the same two lines.
    EventLogger* evLogPtr;
    @property ref EventLogger evLog() { return *evLogPtr; }
    EventLogger* recLogPtr;
    @property ref EventLogger recLog() { return *recLogPtr; }

    // Task 0781 step 2d -- the argument-carrying command dispatcher, now a real
    // METHOD (step 2a parked it here as a `bool delegate(string, string)` field
    // while `doItemSelectPickAt` was still main()'s). Plan §4/Q2's deciding
    // grep, re-run at the move, still returned exactly the shape it predicts --
    // the declaration plus `handleKeyDown` and `doItemSelectPickAt` ×2, nothing
    // else -- so the plan's "move it" branch applies. The body is app.d's
    // verbatim; the ONLY edits are `app.reg` and `app.runCommand`, because this
    // method is not inside a `with (app)` block. `handleKeyDown`'s call site is
    // textually unchanged (the method name is the field's); `doItemSelectPickAt`
    // is still bound in main() until step 2e, so its two calls spell
    // `router.runCommandWithArgs`.
    //
    // Run a command immediately with a baked argstring injected — used by
    // shortcut bindings that pin arguments (`mesh.subdivide: "D ccsds"`), so a
    // param-carrying command applies at once instead of popping the args dialog
    // (mirrors baking `poly.subdivide ccsds` into its keymap). Positional
    // args map onto params() in declaration order; `name:value` args match by
    // name. Injection writes through the same param pointers the dialog uses.
    // Returns false only if the id has no factory.
    bool runCommandWithArgs(string commandId, string argstr) {
        import std.json  : JSONValue, JSONType;
        import params    : injectParamsInto;
        import argstring : parseArgstring;
        auto factory = commandId in app.reg.commandFactories;
        if (factory is null) return false;
        auto cmd    = (*factory)();
        auto schema = cmd.params();
        if (argstr.length > 0 && schema.length > 0) {
            auto pj = parseArgstring(commandId ~ " " ~ argstr).params;
            if (pj.type == JSONType.object) {
                // Positional args → schema order (so "ccsds" fills `mode`).
                if (auto pos = "_positional" in pj)
                    if (pos.type == JSONType.array)
                        foreach (i, ref v; pos.array)
                            if (i < schema.length)
                                pj.object[schema[i].name] = v;
                injectParamsInto(schema, pj);
            }
        }
        app.runCommand(cmd);
        return true;
    }

    // ---- Task 0781 step 2c: what `handleMouseMotion` owns ---------------
    //
    // All four MOVE -- storage HERE, never a pointer back into main(). That is
    // §4's own rule for every step-2 commit ("state that moves is state that
    // moves"), and the reason is that a pointer would freeze today's shape as
    // the contract. main() keeps a same-name forwarder for each only while its
    // OTHER readers are still nested there (`handleMouseButtonDown`/`Up`, and
    // `doSelectPickAt`'s binding site); step 2d moves those in and the
    // forwarders go with them.

    // The cooked 2D event, and the bookkeeping behind it. `gestureTrack` is
    // advanced once per SDL mouse event at the TOP of each of the three mouse
    // handlers (see GestureTrack.event's doc for why the placement is
    // load-bearing) -- in this module, at the top of `handleMouseMotion`; the
    // press/release handlers still do it from main() until step 2d.
    //
    // NOTHING READS THE PACKET. It is published so the shape exists at the one
    // place a gesture's pixel state is known; migrating the tools that keep
    // their own last-pixel bookkeeping onto it is a separate step, one tool
    // per commit, each under its own drag test.
    //
    // The publish SLOT it feeds (`gestureSlot`) is the CLUSTER's, not this
    // struct's: `VectorStack` stores POINTERS into it and the stack a caller
    // builds must outlive the call, so it needs storage that lives as long as
    // the cluster does. See input_frame_state.d.
    GestureTrack gestureTrack;

    // RMB path trail: is a right-button lasso in flight? Router-EXCLUSIVE
    // state by 0781's own classification, which is why it moves here and did
    // not join the cluster the way its trail `rmbPath` did -- the frame body
    // draws that trail every frame (the dashed lasso overlay) and never reads
    // this flag.
    bool rmbDragging = false;

    // The previous motion pixel: the drag deltas' origin. Written at the
    // BOTTOM of each of the three mouse handlers, so a handler that returns
    // early deliberately leaves them where the last completed step put them
    // (app.d's comment at the buildToolVts wiring records that this is the
    // intent, not an oversight).
    int lastMouseX, lastMouseY;

    // THE THREE PICKER DELEGATES ARE GONE -- step 2e turned them into real
    // METHODS (`doSelectPickAt`, `doItemSelectPickAt`, `refreshHoverPickAt`,
    // at the bottom of this struct). They were delegate FIELDS from 2c/2d only
    // because their bodies were still closures over main()'s frame; with the
    // bodies here there is nothing left to bind, and main()'s three
    // `router.doXxx = ...` assignments are deleted with them.
    //
    // The `!is null` guard each of the three call sites made went with the
    // field. It was never a behaviour gate -- it guarded the window between the
    // handlers' declaration and the binding ~1,000 lines later, and no SDL
    // event can arrive in between -- so removing it changes nothing a test can
    // see. It is also not something a coder can forget: a bare method name in a
    // boolean context is a call with no arguments, which does not compile.

    // ---- Task 0781 step 2d: what the PRESS/RELEASE pair owns -------------

    // Last element triple resolved by doSelectPickAt, stashed so the mouse-DOWN
    // dispatch path can capture an interaction-log record (task 0027) WITHOUT
    // re-running the pick — and without the shared delegate body (also bound to
    // mouse-MOTION) emitting one record per motion event. Exactly one of these
    // is >= 0 per editMode (vertices/edges/polygons); all -1 = a background pick.
    //
    // The READER moved here with `handleMouseButtonDown` in 2d; step 2e
    // brought the WRITER, `doSelectPickAt`'s body, so both ends are now inside
    // this struct and the three same-name `@property ref` forwarders main()
    // carried in the router-wiring block are deleted.
    int aiLastPickedVertex = -1;
    int aiLastPickedEdge   = -1;
    int aiLastPickedFace   = -1;

    // The interaction-log source tag, BY VALUE (assigned once at wiring, never
    // mutated -- the (в) class this struct already applies to `window` and
    // `playbackMode`), and the EditMode->schema-id mapper as a DELEGATE onto
    // main()'s nested function. Neither moves outright, and the reason is the
    // same for both: each has a second main()-side reader (the handle-apply
    // hook at the AI wiring block) that is lexically BEFORE `router` exists, so
    // it could not name the router. Holding `aiEditModeId` by delegate is also
    // what keeps the moved call site textually unchanged.
    string aiLogSource;
    string delegate() aiEditModeId;

    // ---- Trackball momentum spin (task 0582) ----------------------------
    // The camera whose trackball drag is in flight, captured on the press.
    // Held rather than re-derived because the release CANNOT re-derive it:
    // `vpm.dragOriginId` is cleared in the event router BEFORE the button-up
    // reaches its handler, so `originCamera()` there is whichever cell is
    // active — the same trap `View.trackballCancel`'s doc records. Null
    // whenever no trackball drag is in flight, which is always for a user who
    // has not switched the gesture on.
    View tbSpinCam = null;

    // Phase C.x: interactive selection edit session. `handleMouseButtonDown`
    // captures the selection-snapshot before any picking/lasso/clear happens;
    // `handleMouseButtonUp` captures after, builds a MeshSelectionEdit, and
    // records on history if anything actually changed. Both handlers, both
    // session functions and these three fields are now one object's -- the
    // pair below had no caller outside them (six sites, all inside this
    // struct's two press/release handlers).
    SelectionSnapshot pendingSelBefore;
    EditMode          pendingSelBeforeMode;
    bool              pendingSelOpen = false;

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
                // The SDL-free half, extracted so it has a unit test at all
                // (plan §6.1): `--test` never resizes the window and
                // `SDL_SetWindowSize` above runs only under `--playback`, so a
                // `sub:6` event fixture would run this handler and assert
                // nothing. `applyWindowMetrics` is the part a unittest CAN
                // drive -- see tests/unit/window_metrics_test.d.
                //
                // It also runs the vpm reflow that used to sit at the BOTTOM of
                // this block. Nothing between depends on it: `glViewport` and
                // `initThickLineProgram` read `fbW`/`fbH`, and
                // `setReplayCurrentViewport` reads `layout.vp*`, which
                // `applyWindowMetrics` has already written.
                applyWindowMetrics(layout, vpm, winW, winH);
                glViewport(0, 0, fbW, fbH);
                initThickLineProgram(thickLineProgram, fbW, fbH);
                // Keep replay-time pixel remapping calibrated to the new layout.
                setReplayCurrentViewport(layout.vpX, layout.vpY,
                                         layout.vpW, layout.vpH, kFovY);
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

    // ---- Task 0781 step 2d: the interactive-selection session ------------
    //
    // Both functions moved WHOLE, with the three `pendingSel*` fields above:
    // the press/release pair this struct just took were their only callers
    // (six sites), so nothing in main() names either any more. Bodies verbatim
    // apart from the `app.` prefixes -- and ONE line that is not a pure
    // prefix, flagged because R3 is exactly this shape: `&editMode` was the
    // address of a main() LOCAL and is now `&app.editMode()`, WITH the call
    // parens, because `&app.editMode` would address the @property FUNCTION.
    // The pointer is the same object either way (`app.editModePtr = &editMode`
    // at the ctx wiring), which is what makes the edit a spelling and not a
    // behaviour change.

    // Open an interactive selection edit session. Idempotent — repeated
    // calls before commitInteractiveSelEdit() are no-ops. Snapshot must be
    // captured BEFORE any pick/lasso/clear mutates the selection.
    void beginInteractiveSelEdit() {
        if (pendingSelOpen) return;
        app.mesh.syncSelection();
        pendingSelBefore     = SelectionSnapshot.capture(app.mesh);
        pendingSelBeforeMode = app.editMode;
        pendingSelOpen       = true;
    }

    // Close the session: capture post-state, build a MeshSelectionEdit and
    // record it if anything actually changed (selection arrays differ or
    // edit mode flipped). No-op when no session is open.
    void commitInteractiveSelEdit() {
        if (!pendingSelOpen) return;
        scope(exit) pendingSelOpen = false;

        app.mesh.syncSelection();
        auto after = SelectionSnapshot.capture(app.mesh);

        bool changed = (app.editMode != pendingSelBeforeMode)
                    || pendingSelBefore.selectedVertices != after.selectedVertices
                    || pendingSelBefore.selectedEdges    != after.selectedEdges
                    || pendingSelBefore.selectedFaces    != after.selectedFaces;
        if (!changed) return;

        auto cmd = (new MeshSelectionEdit(&app.mesh(), app.cameraView, app.editMode, &app.editMode()))
            .setPromoteHook((EditMode m) => app.promoteGeometryType(m));
        cmd.setBefore(pendingSelBefore, pendingSelBeforeMode);
        cmd.setAfter (after,            app.editMode);
        // P5: coalesce consecutive interactive selects into one undo entry.
        // An intervening geometry/non-selection edit becomes the top entry, so
        // the next select's compareOp(top) = Different → new entry (automatic
        // gesture boundary). Selection-undo stays in its own UI-undo class.
        app.history.recordCoalescing(cmd);
    }

    // ---- Task 0781 step 2d: the PRESS and RELEASE handlers ---------------
    //
    // `handleMouseButtonDown` (299 lines) and `handleMouseButtonUp` (467),
    // relocated from nested functions of the same name in app.d's main(). The
    // bodies are VERBATIM: a line-by-line diff of the moved text against the
    // pre-move block is 132 lines out of 766, and 130 of the 132 differ ONLY by
    // an `app.` or an `ifs.` prefix -- no comment, no blank line and no
    // indentation column changed. The two that are not pure prefixes are the
    // `router.doSelectPickAt` pair in the press handler's pick branch, which
    // lose the `router.` they needed while this struct was somebody else's
    // (step 2c's stated cost, now repaid). The card's Log lists all 132.
    //
    // NOT wrapped in `with (app)`, for the reason spelled out above
    // `handleMouseMotion` below and MEASURED in step 2a: a bare
    // `buildToolVts(subj, vts)` inside a `with (app)` compiles GREEN against
    // EditorApp's narrow two-parameter delegate field instead of the cluster's
    // real six-parameter function. This pair reaches that name SEVEN times, so
    // it is the worst place in the codebase for that trap; spelling `app.` /
    // `ifs.` out turns a bare cluster name into a compile error instead.
    //
    // Covered BY VALUE, named rather than assumed:
    // tests/test_lasso_select.d drives the whole RMB half -- `ifs.rmbPath`, the
    // lasso close, and the per-mode selection loops -- and asserts the selected
    // id sets exactly; tests/test_interactive_select_undo.d drives the
    // click-selection post-synthesis (`beginInteractiveSelEdit` ->
    // `commitInteractiveSelEdit` -> a coalesced `MeshSelectionEdit`) and
    // asserts what undo restores, which is the only oracle `pendingSelBefore`
    // has; tests/test_item_mode_geometry_gate.d drives the 0643 item branch and
    // `doItemSelectPickAt`; tests/test_camera.d's orbit/pan/zoom logs are the
    // cross-client witness for `ifs.dragMode`, written here and read by
    // `handleMouseMotion`; tests/test_pie_menu.d and
    // tests/test_command_availability.d reach `runCommandWithArgs`.

    void handleMouseButtonDown(ref SDL_MouseButtonEvent btn) {
        // Cook this event ONCE, before any dispatch: this handler reaches
        // buildToolVts from four different branches (RMB-to-tool, the
        // apply-and-continue re-arm, LMB-to-tool, the no-tool gizmo claim)
        // and they must not disagree about what the event was. A press also
        // re-anchors the gesture, which has to happen before the first
        // branch that could consume the event and return.
        GesturePacket gest = gestureTrack.event(GesturePacket.Phase.Down, btn.x, btn.y);
        // A PRESS CANCELS A RUNNING MOMENTUM SPIN (task 0582), before anything
        // else can consume this event and return. The reference re-arms the
        // spin with a rate of zero on its navigation press, which is the same
        // observable; widening it from that one chord to any press over
        // the cell is a port decision, and it can only ever stop the spin
        // SOONER — a camera that kept coasting through a click would be a bug
        // report, not parity. Cheap enough to be unconditional: `spinCancel`
        // on a camera that is not spinning writes three fields nobody reads.
        app.vpm.originCamera().spinCancel();
        // Viewport click → drop ImGui keyboard focus. The viewport is
        // raw OpenGL drawn under ImGui, so SDL clicks here don't reach
        // ImGui at all — without this, a previously-focused text input
        // (Filter, REPL, args dialog) keeps `io.WantTextInput` set
        // forever, and the event-loop guard at the top of
        // processSdlEvent() swallows EVERY subsequent KEYDOWN
        // (including Delete, Tab, 1/2/3 mode keys). User reported
        // "Delete doesn't work on selected polygons" — turned out the
        // History panel's Filter input was still focused after they
        // typed a search.
        if (ifs.viewportInputAllowed())
            ImGui.SetWindowFocus(null);
        if (btn.button == SDL_BUTTON_RIGHT) {
            import falloff_handles : screenFalloffActive, screenFalloffRMBDown,
                                     radialFalloffActive, radialFalloffRMBDown,
                                     elementFalloffActive, elementFalloffRMBDown;
            if (screenFalloffActive()) {
                screenFalloffRMBDown(btn.x, btn.y);
                return;
            }
            if (radialFalloffActive()) {
                SDL_Keymod mods = SDL_GetModState();
                bool ctrl = (mods & KMOD_CTRL) != 0;
                Viewport vp2 = app.vpm.originSnapshot();
                if (radialFalloffRMBDown(btn.x, btn.y, ctrl, vp2))
                    return;
                // Plane projection failed (camera aligned to plane);
                // fall through to lasso so the click isn't lost.
            }
            if (elementFalloffActive()) {
                Viewport vp2 = app.vpm.originSnapshot();
                if (elementFalloffRMBDown(btn.x, btn.y, vp2))
                    return;
                // Ray-parallel-to-camera-back is the only failure
                // mode (degenerate camera state); fall through.
            }
            // Give the ACTIVE tool first crack at RMB (task 0288). A tool may bind
            // RMB to its own gesture — Slice uses RMB as the gap-adjust drag
            // (dashed-circle + value HUD), and the live-edit tools cancel on RMB.
            // The falloff RMB handlers above kept their priority; if no tool
            // consumes the click, fall through to the RMB lasso select as before
            // (lasso runs with NO active tool, so it is unaffected).
            if (app.activeTool) {
                SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts, btn.x, btn.y, true, gest);
                if (app.activeTool.onMouseButtonDown(btn, vts)) return;
            }
            rmbDragging = true;
            ifs.rmbPath = [ImVec2(cast(float)btn.x, cast(float)btn.y)];
            // RMB lasso mutates selection on mouseUp; snapshot now.
            beginInteractiveSelEdit();
            return;
        }
        if (app.activeTool) {
            // Framework "apply and continue" (the reference editor's apply-
            // and-continue gesture, task 0461): a Shift+LMB while the active
            // tool holds an uncommitted edit commits it as its own undo entry
            // and re-arms the SAME tool session in place (no drop — ACEN/AXIS/
            // pipe state persist): commit-into-history then re-arm-in-place.
            //
            // COMBINED GESTURE: after the commit+rearm, THIS same Shift+LMB is
            // forwarded to the re-armed tool as a fresh gesture-start, so a
            // Shift+click+drag applies the old edit AND immediately hauls the
            // new one in one motion — no lift between operations (a "series of
            // bevels"). Shift is masked for the forwarded down because the
            // opted-in tools reject a raw Shift+LMB (reserving it for sel-add);
            // masking makes them treat it as a plain gesture-start. The forward
            // reads the live modifier state, so the mask must go through the
            // real SDL modstate (restored immediately after via scope(exit)).
            //
            // When the active tool has NO open edit, or opts out of in-place
            // commit (transform tools already commit per gesture),
            // applyAndContinue() returns false and this Shift+LMB falls through
            // unchanged to the selection-add path below — no edit is ever lost.
            // Alt/Ctrl chords stay excluded (camera / axis-lock).
            if (btn.button == SDL_BUTTON_LEFT && ifs.viewportInputAllowed()
                && (SDL_GetModState() & KMOD_SHIFT)
                && !(SDL_GetModState() & (KMOD_ALT | KMOD_CTRL))
                && app.session.applyAndContinue()) {
                SDL_Keymod savedMods = SDL_GetModState();
                SDL_SetModState(cast(SDL_Keymod)(savedMods & ~KMOD_SHIFT));
                scope(exit) SDL_SetModState(savedMods);
                SubjectPacket subjR; VectorStack vtsR; ifs.buildToolVts(subjR, vtsR, btn.x, btn.y, true, gest);
                app.activeTool.onMouseButtonDown(btn, vtsR);
                return;
            }
            // Refresh the hover pick at the click position BEFORE the tool sees
            // the event, so a tool that click-picks an element (XfrmTransformTool
            // under falloff.element) reads hover for THIS cursor, not the last
            // rendered frame's. Gated to a LEFT click on an element-hover tool —
            // the only case that reads g_hovered on mouse-down — so it never adds
            // a GPU readback to camera chords or non-picking tools. Ctrl is
            // ALLOWED (it's the axis-lock modifier the click-pick forwards as
            // ctrlMod): excluding it left the hover stale on a Ctrl+click, so the
            // first Ctrl element-move gesture failed to pick → no relocate, no
            // axis-lock (must mirror XfrmTransformTool's `pickAllowed` gate).
            // Alt stays excluded (Ctrl+Alt+LMB = camera zoom); Shift = sel-add.
            if (btn.button == SDL_BUTTON_LEFT && ifs.viewportInputAllowed()
                && !(SDL_GetModState() & (KMOD_ALT | KMOD_SHIFT))
                && (app.activeTool.wantsHoverForType(EditMode.Vertices)
                 || app.activeTool.wantsHoverForType(EditMode.Edges)
                 || app.activeTool.wantsHoverForType(EditMode.Polygons)))
                refreshHoverPickAt(btn.x, btn.y);
            SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts, btn.x, btn.y, true, gest);
            if (app.activeTool.onMouseButtonDown(btn, vts)) return;
        }
        // No tool, but the host's falloff gizmo may own this click (drag an
        // endpoint). Must run BEFORE the bare-LMB selection-clear below so a
        // handle grab isn't treated as a deselect. Skip alt/ctrl chords (camera).
        if (app.activeTool is null && btn.button == SDL_BUTTON_LEFT
            && !(SDL_GetModState() & (KMOD_ALT | KMOD_CTRL))) {
            import toolpipe.packets : FalloffPacket;
            SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts, btn.x, btn.y, true, gest);
            FalloffPacket fp;
            if (auto p = vts.get!FalloffPacket()) fp = *p;
            Viewport vpg = app.vpm.originSnapshot();
            if (app.pipeGizmoHost.tryClaimDown(btn, vpg, fp, app.pipeGizmoHost.ownPool()))
                return;
        }
        if (btn.button == SDL_BUTTON_LEFT && btn.clicks == 2 && app.activeTool is null
            && viewportPickType(app.selTypeOrder) != SelType.Item) {
            // Double-click loop / connect — these mutate selection. Wrap as
            // an interactive edit so undo restores the prior selection.
            //
            // Item-inclusive gate (task 0655): this is a GEOMETRY pick site
            // like every other, and it reached `editMode` — so under the item
            // type a double-click grew the geometry selection the user could
            // not even see. It falls through to the single-click handling
            // below, where the 0643 item branch takes it.
            beginInteractiveSelEdit();
            if (app.editMode == EditMode.Edges)
                new SelectLoop(&app.mesh(), app.cameraView, app.editMode).apply();
            else
                new SelectConnect(&app.mesh(), app.cameraView, app.editMode).apply();
            commitInteractiveSelEdit();
            return;
        }
        // Alt+MMB — camera BANK, the reference's own dedicated roll chord.
        // Placed AFTER the active-tool dispatch above so a tool that owns
        // the middle button (Slice) keeps first refusal, exactly as the
        // Alt+LMB camera chords do. Bare MMB is untouched.
        if (btn.button == SDL_BUTTON_MIDDLE) {
            SDL_Keymod mmods = SDL_GetModState();
            if ((mmods & KMOD_ALT) && !(mmods & KMOD_SHIFT) && !(mmods & KMOD_CTRL)) {
                ifs.dragMode   = DragMode.Roll;
                lastMouseX = btn.x;
                lastMouseY = btn.y;
            }
            return;
        }
        if (btn.button == SDL_BUTTON_LEFT) {
            SDL_Keymod mods = SDL_GetModState();
            bool ctrl  = (mods & KMOD_CTRL)  != 0;
            bool alt   = (mods & KMOD_ALT)   != 0;
            bool shift = (mods & KMOD_SHIFT)  != 0;
            bool anyToolActive = app.activeTool !is null;

            // ---- ITEM selection type: the click picks an ITEM (task 0643) ---
            //
            // BEFORE `beginInteractiveSelEdit` and before the clear/pick
            // branches below, and every word of that ordering is load-bearing:
            //
            //   * it returns before the bare-LMB "clear the selection for the
            //     current mode" branch, so clicking under Items does not wipe a
            //     geometry selection the user still has. There is no item
            //     analogue to wipe either — the document invariant is "at least
            //     one item selected", so a miss is simply nothing.
            //   * it returns before `doSelectPickAt`, and therefore before
            //     `commitInteractiveSelEdit` can build a `MeshSelectionEdit`
            //     whose promote hook would push the GEOMETRY type back to the
            //     front of the recent ordering. That is the recorded R3 trap:
            //     a mis-click silently turning the item mode into vertex mode.
            //     The guard is structural (we never reach the code) rather than
            //     a flag checked inside it.
            //
            // Alt chords are camera (orbit / pan / zoom) and keep first
            // refusal; an active tool keeps its own, exactly as the geometry
            // select path does — with a tool up, none of the Select drag modes
            // are entered either, so this branch is gated the same way its
            // neighbour is rather than in a new way.
            if (!anyToolActive && !alt
                && currentSelType(app.selTypeOrder) == SelType.Item) {
                doItemSelectPickAt(btn.x, btn.y, ctrl, shift);
                lastMouseX = btn.x;
                lastMouseY = btn.y;
                ifs.dragMode = DragMode.None;   // no rubber-band select under Items
                return;
            }

            // Capture pre-LMB selection snapshot now — BEFORE the bare-LMB
            // clear-selection branch below could mutate. If LMB ends up
            // being a camera drag (Alt / Ctrl+Alt / Alt+Shift), commit will
            // see no change and skip recording. Tool-driven LMB doesn't
            // need it (tools own their own undo plumbing).
            if (!anyToolActive && !alt)
                beginInteractiveSelEdit();

            if      (ctrl && alt)  ifs.dragMode = DragMode.Zoom;
            else if (alt && shift) ifs.dragMode = DragMode.Pan;
            else if (alt)          ifs.dragMode = DragMode.Orbit;
            else if (ctrl && !anyToolActive)  ifs.dragMode = DragMode.SelectRemove;
            else if (shift && !anyToolActive) ifs.dragMode = DragMode.SelectAdd;
            else if (!anyToolActive) {
                // No modifiers: clear selection for current mode
                if (app.editMode == EditMode.Vertices)
                    app.mesh.clearVertexSelection();
                else if (app.editMode == EditMode.Edges)
                    app.mesh.clearEdgeSelection();
                else if (app.editMode == EditMode.Polygons)
                    app.mesh.clearFaceSelection();
                ifs.dragMode = DragMode.Select;
            }
            lastMouseX = btn.x;
            lastMouseY = btn.y;

            // Trackball arming (task 0573). The trackball's rotation depends on
            // WHERE the press landed in the pane, not only on how far the
            // cursor has since travelled, so the absolute press pixel has to be
            // captured here on the DOWN — the motion path only ever sees a
            // delta. Armed only when the gesture would actually run it, which
            // is off by default: a user who has not switched the trackball on
            // reaches exactly the code they reached before.
            if (ifs.dragMode == DragMode.Orbit && !app.vpm.originIsOrtho()
                && app.vpm.originCamera().trackballActive()) {
                app.vpm.originCamera().trackballDown(btn.x, btn.y);
                // Remember WHICH camera, for the release that arms the spin.
                tbSpinCam = app.vpm.originCamera();
            }

            // Pick immediately on press for select clicks. A stationary
            // click (button pressed and released with no intervening motion
            // event) otherwise relies on a render frame landing during the
            // brief hold to run the per-frame picker (pickEdges, line ~5597).
            // A CPU-starved host can skip that frame — under CI `-j $(nproc)`
            // the trailing shift+click in selection_edges_add.log occasionally
            // failed to add its edge ("expected 3 selected edges, got 2").
            // Drags already pick per motion event (see handleMouseMotion);
            // this makes the zero-motion case just as deterministic. selectEdge
            // / deselectEdge are idempotent, so a later hold-frame pick of the
            // same element is harmless.
            if (ifs.dragMode == DragMode.Select
             || ifs.dragMode == DragMode.SelectAdd
             || ifs.dragMode == DragMode.SelectRemove) {
                doSelectPickAt(btn.x, btn.y);

                // Element apply capture (task 0027). Gated to the mouse-DOWN
                // dispatch path ONLY — doSelectPickAt is also bound to
                // mouse-MOTION during a select-drag, so capturing inside its
                // body would emit one record per motion event. The triple was
                // stashed by the pick above; doSelectPickAt sets exactly one of
                // vertex/edge/face per editMode (others -1, or all -1 for a
                // background pick), so collectElementCandidates yields a single
                // real candidate at index 0 = the default winner = the element
                // the user actually applied. No advisor runs here, so
                // resolveElementCandidateDecision's appliedWinnerIndex == the
                // default winner.
                if (app.aiLogWriter.enabled) {
                    auto candidates = collectElementCandidates(
                        btn.x, btn.y,
                        aiLastPickedVertex, aiLastPickedEdge, aiLastPickedFace);
                    auto resolution = resolveElementCandidateDecision(candidates);
                    AiInteractionContext ctx;
                    ctx.phase = AiInteractionPhase.mouseDown;
                    ctx.defaultIntent = AiIntent.selectElement;
                    ctx.mouseX = btn.x;
                    ctx.mouseY = btn.y;
                    ctx.shift = shift;
                    ctx.ctrl = ctrl;
                    ctx.alt = alt;
                    ctx.activeToolId = app.activeToolId;
                    ctx.editModeId = aiEditModeId();
                    auto record = makeAiInteractionLogRecord(
                        aiLogSource, "elements", ctx, candidates,
                        resolution.advisor, resolution.appliedWinnerIndex);
                    app.aiLogWriter.append(record);
                }
            }
        }
    }

    void handleMouseButtonUp(ref SDL_MouseButtonEvent btn) {
        // Cooked once, before dispatch — see handleMouseButtonDown. A
        // release does NOT re-anchor: the press pixel this packet carries is
        // still the one the gesture started from, which is the whole point
        // of the cumulative form.
        GesturePacket gest = gestureTrack.event(GesturePacket.Phase.Up, btn.x, btn.y);
        // Arm the settling spin (task 0582), FIRST — this handler returns early
        // from half a dozen branches below (the three falloff RMB paths, a
        // tool's own gesture end, the host gizmo's), and a release that took
        // one of them is still a release. `tbSpinCam` is non-null only when
        // this press armed a trackball drag, so the whole block is skipped on
        // every other button-up in the editor.
        if (btn.button == SDL_BUTTON_LEFT && tbSpinCam !is null) {
            tbSpinCam.trackballRelease(SDL_GetTicks());
            ifs.anySpinning = ifs.anySpinning || tbSpinCam.spinning();
            tbSpinCam = null;
        }
        if (btn.button == SDL_BUTTON_RIGHT) {
            import falloff_handles : screenFalloffRMBUp, radialFalloffRMBUp,
                                     elementFalloffRMBUp;
            if (screenFalloffRMBUp())  return;
            if (radialFalloffRMBUp())  return;
            if (elementFalloffRMBUp()) return;
            // Active tool RMB gesture end (task 0288): if a tool owns this RMB
            // (it consumed the RMB-down, so no lasso is in flight — rmbDragging is
            // false), let it finish its gesture (Slice bakes the final gap here).
            if (app.activeTool && !rmbDragging) {
                SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts, btn.x, btn.y, true, gest);
                if (app.activeTool.onMouseButtonUp(btn, vts)) return;
            }
            // The rubber-band is a VIEWPORT PICK, so it asks the ordering with
            // the item-inclusive candidate set (task 0655) — the same query
            // the click and the hover ask. Everything inside this block
            // branches on `editMode`, which is a cache of that query asked
            // WITHOUT items, so under the item type a lasso used to clear the
            // geometry selection and rebuild it from whatever the band
            // enclosed. There is no item rubber-band to run instead: the band
            // is still drawn and still cleared below, it simply selects
            // nothing.
            if (ifs.rmbPath.length >= 3
                && viewportPickType(app.selTypeOrder) != SelType.Item
                && !ifs.previewIndexSpaceStale()) {   // task 1730, see inside
                // ---------------------------------------------------------
                // Task 0617 Stage 3 (doc/picking_item_transform_plan.md):
                // this block used to project RAW LOCAL vertices while Stage 1
                // made the GPU occlusion probes below (`elementVisibility`,
                // `endpointVisibleEdgeFbo`) render at the layer's DRAWN pose
                // — a split-brain that made edge/vertex/face lasso select
                // NOTHING on a primary with a non-identity `ItemXform` (the
                // two tests agreed only at identity). Fixed by composing the
                // item transform into exactly ONE local-space viewport
                // (`vpLocal`, below) and routing every geometry test in this
                // block through it. The occlusion probes and the
                // `symmetricSelect*` calls keep seeing the WORLD viewport
                // (`vpWorld`) unmodified: they compose `ms` internally, or
                // anchor on local mesh coordinates themselves, so handing
                // them `vpLocal` would apply the item transform twice (R10).
                // ---------------------------------------------------------
                SDL_Keymod mods = SDL_GetModState();
                bool shift = (mods & KMOD_SHIFT) != 0;
                bool ctrl  = (mods & KMOD_CTRL)  != 0;
                const ModelSpace ms      = primaryModelSpace();
                Viewport         vpWorld = app.vpm.originSnapshot();
                const Viewport   vpLocal = projectionSpace(vpWorld, ms);
                float[] pxs = new float[](ifs.rmbPath.length);
                float[] pys = new float[](ifs.rmbPath.length);
                foreach (i, p; ifs.rmbPath) { pxs[i] = p.x; pys[i] = p.y; }
                // The only two projectors and the only front-facing test
                // permitted in this block — every local-space geometry test
                // below must go through one of these three, never a bare
                // `projectToWindow`/`dot(...)` against vpLocal directly.
                bool insideLasso(Vec3 vLocal) {
                    float sx, sy, ndcZ;
                    if (!projectToWindow(vLocal, vpLocal, sx, sy, ndcZ)) return false;
                    return pointInPolygon2D(sx, sy, pxs, pys);
                }
                bool projLocal(Vec3 vLocal, out float sx, out float sy) {
                    float ndcZ;
                    return projectToWindow(vLocal, vpLocal, sx, sy, ndcZ);
                }
                bool frontFacing(const(Vec3)[] vertsLocal, const(uint)[] ring) {
                    // Task 0832: the rule itself moved to
                    // `math.frontFacingLocal`, its one home. It takes the RING
                    // rather than a precomputed normal, because WHICH normal
                    // is the rule — this call site used to hand it
                    // `Mesh.faceNormal` (Newell over the whole polygon) while
                    // the two snap sites each built a different one. The
                    // adopted rule is the reference's, MEASURED for this
                    // gesture (task 0726 drove the lasso).
                    //
                    // No `ms.mirrored` correction here (task 0617 follow-up:
                    // the flip that used to live on this line was WRONG and
                    // has been removed — see math.d's `ModelSpace.mirrored`
                    // doc comment for the identity that replaces §3.7/§3.8).
                    // `vpLocal.eye` is already `M⁻¹·eyeWorld`
                    // (`projectionSpace`), so the local dot already answers
                    // "is the eye on the outward side" correctly for ANY
                    // invertible `M`, mirrored or not — XOR-ing `ms.mirrored`
                    // on top flipped a right answer wrong under a mirror.
                    return frontFacingLocal(vertsLocal, ring, vpLocal.eye);
                }
                // GPU-pick-buffer-driven visibility for the lasso.
                // doc/lasso_gpu_pick_buffer_fix.md — replaces the old
                // CPU `Mesh.visibleVertices` occlusion test that was
                // O(V × F\_front) (multi-minute hang on heavy imports;
                // mitigated by a 4 K-vert threshold that disabled
                // occlusion entirely). The per-mode ID FBO that
                // `gpuSelect.pick(...)` already maintains for hover
                // selection bakes occlusion via its depth pre-pass;
                // reading it back gives per-VBO-entry visibility in
                // ~ms regardless of mesh size. We keep the strict
                // "all face verts inside polygon" / "both edge ends
                // inside" CPU lasso semantic (preserves the existing
                // test_lasso_select.d behaviour) — only the visibility
                // source changes.
                import gpu_select : SelectMode;
                SelectMode vbMode;
                final switch (app.editMode) {
                    case EditMode.Vertices: vbMode = SelectMode.Vertex; break;
                    case EditMode.Edges:    vbMode = SelectMode.Edge;   break;
                    case EditMode.Polygons: vbMode = SelectMode.Face;   break;
                }
                app.ensureDisplayCurrent(); // mid-batch pull-guard: FBO readback below renders from the VBO

                // Task 1730 — the fourth `*OriginGpu` reader, and the one the
                // M-INV comment below already describes the danger of. While a
                // rebuild is in flight the VBOs hold a limit surface built
                // against the PREVIOUS cage, so `gpuVisible` — keyed by
                // preview face index — would be read as a cage index by the
                // `preview == false` branch. That is the "answers with the
                // WRONG element rather than crashing" case, stated three
                // paragraphs down, arrived at from the other side.
                //
                // The gate itself is on this block's own `if` above, NOT a
                // `return` from here: `rmbPath = null` runs further down in
                // `handleMouseButtonUp`, so returning out of the middle would
                // leave the band path armed — the next RMB drag would append
                // to it and the overlay would keep drawing the old rubber
                // band. Skipping the selection while still falling through to
                // the cleanup is the only shape that ends the gesture.
                //
                // Refusing the band outright rather than falling back to a
                // cage band: the band is a GESTURE the user completed against
                // pixels showing the limit surface, and answering it from cage
                // geometry would select a different set than the one they drew
                // around. Nothing selected is wrong in a way they can see and
                // repeat; a plausible wrong set is not.

                // Selection visibility, resolved ONCE for this gesture
                // (`select_visibility.d`). Under a display style that draws no
                // faces the ID buffer carries no depth pre-pass, so
                // `gpuVisible` marks everything that rasterised and the STRICT
                // endpoint probes below stop rejecting far edges: the lasso
                // picks vertices and edges THROUGH the model, exactly as click
                // and paint now do.
                //
                // The polygon half of the lasso is deliberately UNCHANGED:
                // `SelectMode.Face` never ran the pre-pass (the face pass is
                // the surface), and the separate `frontFacing` cull below is
                // its own, still-unwired term. See the follow-up named in
                // doc/tasks/work/1830-wireframe-select-through.md.
                //
                // Hoisted rather than resolved per element: it is one pure
                // resolve, and per-edge calls would put it inside the probe
                // loop for no gain.
                immutable bool occlTerm = app.vpm.pickVisibility().occlusionTerm;
                // vpWorld + ms — gpuSelect composes `ms` internally (R10).
                bool[] gpuVisible = app.gpuSelect.elementVisibility(
                    vbMode, app.mesh, app.gpu, vpWorld, ms, occlTerm);

                bool preview = app.subpatchPreview.active;
                // ---- M-INV (task 1500), CONSUMER 1 of 2 ----------------
                // ONE-SIDED, on purpose. `active` says the CPU side is in
                // preview index space; `gpuUploadedPreview` says the VBOs —
                // and `gpuVisible` below, which is keyed by PREVIEW face
                // index — are too. The dangerous direction is exactly this
                // one: a live trace against cage buffers reads someone
                // else's visibility, or skips the check entirely past the
                // mask's end, and answers with the WRONG element rather
                // than crashing.
                //
                // The converse (`uploaded && !active`) is reachable TODAY
                // and is legitimate: `deactivate()` runs from command hooks
                // inside `tickAll`, i.e. mid events phase, and until the
                // upload block runs the pair is split the SAFE way — the
                // pick then goes through the cage, where `*OriginGpu` maps
                // into the cage anyway. A two-sided assert would fire on
                // every `/api/reset`.
                //
                // A plain `assert`, not `debug { }`: `-unittest` does not
                // imply `-debug`, so a debug block would not even be
                // compiled in the lane that is supposed to witness this.
                if (preview) assert(app.gpuUploadedPreview,
                    "lasso: preview trace is live but the VBOs still hold the cage");
                // Phase 3c — preview.mesh.vertices may be stale after
                // a fan-out-only drag; lasso needs fresh positions.
                if (preview && app.subpatchPreview.lastRefreshSkipNonFace) {
                    app.subpatchPreview.osdAccel.readLimitIntoPreview(
                        app.subpatchPreview.mesh);
                    app.subpatchPreview.lastRefreshSkipNonFace = false;
                }
                const pv = preview ? &app.subpatchPreview.mesh : null;

                if (app.editMode == EditMode.Polygons) {
                    if (!shift && !ctrl)
                        app.mesh.clearFaceSelection();
                    if (preview) {
                        // Per cage face: every preview child that is
                        // BOTH front-facing AND has at least one
                        // visible pixel (per GPU FBO) must have all
                        // its verts inside the lasso for the cage
                        // face to be selected.
                        bool[] cageAllInside = new bool[](app.mesh.faces.length);
                        bool[] cageVisited   = new bool[](app.mesh.faces.length);
                        cageAllInside[] = true;
                        foreach (fi; 0 .. pv.faces.length) {
                            uint cage = app.subpatchPreview.trace.faceOrigin[fi];
                            if (cage == uint.max || cage >= app.mesh.faces.length) continue;
                            // Hide, branch 1/6 (task 0613 S4). It goes HERE,
                            // beside the identity the branch already resolved
                            // — the three closures above take a POINT
                            // (`insideLasso`, `projLocal`) or a bare vertex
                            // RING (`frontFacing`, task 0832), never a face
                            // INDEX, so none of them can know what is hidden.
                            // FACES keep their VBO slot (faceTriCount == 0,
                            // R3), so `gpuVisible[fi]` below stays correctly
                            // keyed and only this guard is needed.
                            if (app.mesh.isFaceHidden(cage)) continue;
                            auto face = pv.faces[fi];
                            if (face.length < 3) { cageAllInside[cage] = false; continue; }
                            if (!frontFacing(pv.vertices, face)) continue;
                            // GPU visibility per PREVIEW face index.
                            // faceIdVbo writes preview-face indices,
                            // so `gpuVisible[fi]` is the right key.
                            if (gpuVisible !is null
                                && fi < gpuVisible.length
                                && !gpuVisible[fi]) continue;
                            cageVisited[cage] = true;
                            foreach (vi; face) {
                                if (!insideLasso(pv.vertices[vi])) {
                                    cageAllInside[cage] = false;
                                    break;
                                }
                            }
                        }
                        foreach (fi; 0 .. app.mesh.faces.length) {
                            if (!cageVisited[fi] || !cageAllInside[fi]) continue;
                            symmetricSelectFace(&app.mesh(), vpWorld, app.editMode,
                                                cast(int)fi, /*deselect=*/ctrl);
                        }
                    } else {
                        // Cage mode — VBO entry IS cage face. faceIdVbo
                        // writes cage face indices; `gpuVisible[fi]`
                        // is direct.
                        foreach (fi; 0 .. app.mesh.faces.length) {
                            uint[] face = app.mesh.faces[fi];
                            if (face.length < 3) continue;
                            // Hide, branch 2/6. Same reasoning as the preview
                            // branch above, and the same key: a hidden face
                            // keeps its slot, so `fi` still indexes
                            // `gpuVisible` correctly here.
                            if (app.mesh.isFaceHidden(fi)) continue;
                            if (!frontFacing(app.mesh.vertices, face)) continue;
                            if (gpuVisible !is null
                                && fi < gpuVisible.length
                                && !gpuVisible[fi]) continue;
                            bool allInside = true;
                            foreach (vi; face) {
                                if (!insideLasso(app.mesh.vertices[vi])) {
                                    allInside = false;
                                    break;
                                }
                            }
                            if (allInside) {
                                symmetricSelectFace(&app.mesh(), vpWorld, app.editMode,
                                                    cast(int)fi, /*deselect=*/ctrl);
                            }
                        }
                    }
                } else if (app.editMode == EditMode.Vertices) {
                    if (!shift && !ctrl)
                        app.mesh.clearVertexSelection();
                    // gpuVisible is indexed by VBO entry — in cage
                    // mode k == vertex idx; in subpatch mode k is
                    // the kept-preview-vert position. Walk pv (or
                    // mesh) vertices, count k as we go, gate on
                    // gpuVisible[k].
                    if (preview) {
                        size_t k = 0;
                        foreach (pi; 0 .. pv.vertices.length) {
                            uint cage = app.subpatchPreview.trace.vertOrigin[pi];
                            if (cage == uint.max) continue;
                            // Hide, branch 3/6 — and note it sits BEFORE the
                            // `++k`, not after. `k` is a VBO-slot counter and
                            // `GpuMesh.upload` skips hidden vertices when it
                            // fills that buffer (S3), so a guard placed after
                            // the increment would leave `k` counting slots
                            // that do not exist and shift every `gpuVisible`
                            // lookup past the first hidden vertex. The
                            // predicate is the PREVIEW mesh's, byte-for-byte
                            // the one `upload` used (subpatch_osd stamps the
                            // preview's Hide planes from the cage), because
                            // matching the buffer is what keeps `k` honest.
                            if (pv.isVertexHidden(pi)) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            if (insideLasso(pv.vertices[pi])) {
                                symmetricSelectVertex(&app.mesh(), vpWorld, app.editMode,
                                                      cast(int)cage, /*deselect=*/ctrl);
                            }
                        }
                    } else {
                        // Hide, branch 4/6, and it is NOT just a `continue`:
                        // this branch used to key `gpuVisible` by CAGE index,
                        // which was right only while VBO slot == cage vertex.
                        // S3 broke that identity — `upload` skips hidden
                        // vertices — so the mask needs a SLOT key. `k` counts
                        // kept vertices in the same order and by the same
                        // predicate `upload` uses, which is exactly the shape
                        // the preview branch above already had (R11 part 2).
                        // Hiding vertex 0 is what tells the two apart: with the
                        // cage key every later lookup reads its neighbour's
                        // visibility, which selects a set of the RIGHT SIZE and
                        // the WRONG MEMBERS.
                        size_t k = 0;
                        foreach (vi; 0 .. app.mesh.vertices.length) {
                            if (app.mesh.isVertexHidden(vi)) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            if (insideLasso(app.mesh.vertices[vi])) {
                                symmetricSelectVertex(&app.mesh(), vpWorld, app.editMode,
                                                      cast(int)vi, /*deselect=*/ctrl);
                            }
                        }
                    }
                } else if (app.editMode == EditMode.Edges) {
                    if (!shift && !ctrl)
                        app.mesh.clearEdgeSelection();
                    if (preview) {
                        // Per cage edge: every preview segment that
                        // is visible (GPU FBO) must have both
                        // endpoints inside lasso. VBO-segment-index
                        // matches `pei` after kept-edge filtering;
                        // walk pv.edges, count k as we go.
                        bool[] cageAllInside = new bool[](app.mesh.edges.length);
                        bool[] cageVisited   = new bool[](app.mesh.edges.length);
                        cageAllInside[] = true;
                        size_t k = 0;
                        foreach (pei; 0 .. pv.edges.length) {
                            uint cage = app.subpatchPreview.trace.edgeOrigin[pei];
                            if (cage == uint.max || cage >= app.mesh.edges.length) continue;
                            // Hide, branch 5/6 — before the `++k`, for the
                            // reason spelled out in the vertex/preview branch
                            // above: `k` is a VBO segment index and `upload`
                            // skips hidden edges when it fills that buffer.
                            if (pv.isEdgeHidden(pei)) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            uint a = pv.edges[pei][0], b = pv.edges[pei][1];
                            cageVisited[cage] = true;
                            float sxa, sya, sxb, syb;
                            if (!projLocal(pv.vertices[a], sxa, sya) ||
                                !projLocal(pv.vertices[b], sxb, syb) ||
                                !pointInPolygon2D(sxa, sya, pxs, pys) ||
                                !pointInPolygon2D(sxb, syb, pxs, pys)) {
                                cageAllInside[cage] = false;
                            } else {
                                // STRICT: both preview-segment endpoints must be
                                // un-occluded in the Edge ID-FBO. The probe is
                                // window-space / key-agnostic so no preview-to-cage
                                // vertex mapping is needed (we are asking "any
                                // surviving edge pixel near this window point").
                                import std.math : lround;
                                // vpWorld + ms — see the elementVisibility call above (R10).
                                if (!app.gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxa), cast(int)lround(sya),
                                        app.gpu, vpWorld, ms, occlTerm) ||
                                    !app.gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxb), cast(int)lround(syb),
                                        app.gpu, vpWorld, ms, occlTerm)) {
                                    cageAllInside[cage] = false;
                                }
                            }
                        }
                        foreach (ei; 0 .. app.mesh.edges.length) {
                            if (!cageVisited[ei] || !cageAllInside[ei]) continue;
                            symmetricSelectEdge(&app.mesh(), vpWorld, app.editMode,
                                                cast(int)ei, /*deselect=*/ctrl);
                        }
                    } else {
                        // Hide, branch 6/6 — the edge twin of branch 4: skip
                        // hidden edges AND re-key `gpuVisible` from the cage
                        // index to the VBO segment index, which stopped being
                        // the same number when `upload` started dropping
                        // hidden edges (R11 part 2).
                        size_t k = 0;
                        foreach (ei; 0 .. app.mesh.edges.length) {
                            if (app.mesh.isEdgeHidden(ei)) continue;
                            scope(exit) ++k;
                            if (gpuVisible !is null
                                && k < gpuVisible.length
                                && !gpuVisible[k]) continue;
                            uint a = app.mesh.edges[ei][0], b = app.mesh.edges[ei][1];
                            float sxa, sya, sxb, syb;
                            if (!projLocal(app.mesh.vertices[a], sxa, sya)) continue;
                            if (!projLocal(app.mesh.vertices[b], sxb, syb)) continue;
                            if (pointInPolygon2D(sxa, sya, pxs, pys) &&
                                pointInPolygon2D(sxb, syb, pxs, pys)) {
                                // STRICT: both endpoints must be un-occluded in the
                                // Edge ID-FBO (depth-pre-pass baked). Probe a small
                                // window around each projected endpoint; reject the
                                // edge if either window has no surviving edge pixel.
                                // This is intentionally stricter than click (which
                                // only requires a surviving pixel near the cursor).
                                import std.math : lround;
                                // vpWorld + ms — see the elementVisibility call above (R10).
                                if (!app.gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxa), cast(int)lround(sya),
                                        app.gpu, vpWorld, ms, occlTerm)) continue;
                                if (!app.gpuSelect.endpointVisibleEdgeFbo(
                                        cast(int)lround(sxb), cast(int)lround(syb),
                                        app.gpu, vpWorld, ms, occlTerm)) continue;
                                symmetricSelectEdge(&app.mesh(), vpWorld, app.editMode,
                                                    cast(int)ei, /*deselect=*/ctrl);
                            }
                        }
                    }
                }
            }
            rmbDragging = false;
            ifs.rmbPath = null;
            // RMB lasso commit — close the selection edit session.
            commitInteractiveSelEdit();
            return;
        }
        if (app.activeTool) {
            SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts, btn.x, btn.y, true, gest);
            app.activeTool.onMouseButtonUp(btn, vts);
        }
        // Release a host falloff-gizmo drag (no tool active). routeUp does NOT
        // bump the tweak generation — that bump is XfrmTransformTool-specific
        // and the no-tool path never bumped.
        if (app.activeTool is null && app.pipeGizmoHost.routeUp(btn))
            return;
        // When BoxTool commits a new face it appends geometry via mesh
        // primitives (addVertex / addFace), which publish a Geometry change on
        // the change-notification bus. The per-frame flush therefore delivers
        // Geometry on this same frame (event dispatch precedes the flush), and
        // the loop's pick-cache block does the resize + invalidate +
        // syncSelection. No explicit hand-off needed here any more (Stage 2).
        if (btn.button == SDL_BUTTON_LEFT) {
            ifs.dragMode = DragMode.None;
            // LMB up — close any open selection edit session. If the LMB
            // was a camera drag (no selection touched), commit is a no-op.
            commitInteractiveSelEdit();
        }
        // MMB up ends a bank drag. Guarded on the mode so a tool's own
        // middle-button gesture (which never arms Roll) is not disturbed.
        if (btn.button == SDL_BUTTON_MIDDLE && ifs.dragMode == DragMode.Roll)
            ifs.dragMode = DragMode.None;
    }

    // ---- Task 0781 step 2c: the MOTION handler --------------------------
    //
    // `handleMouseMotion`, relocated from a nested function of the same name
    // in app.d's main(). The body is VERBATIM: a line-by-line diff of the
    // moved text against the pre-move block is 32 lines out of 130, and every
    // one of the 32 differs only by an `app.` or an `ifs.` prefix -- no
    // comment, no blank line and no indentation column changed. The card's
    // Log lists them.
    //
    // NOT wrapped in `with (app)`, unlike `handleKeyDown` above, and that is a
    // decision rather than a style drift. Three EditorApp names appear here
    // (`vpm`, `activeTool`, `pipeGizmoHost`) against three cluster ones
    // (`dragMode`, `rmbPath`, `buildToolVts`) -- and `buildToolVts` is exactly
    // the name §5/R2 warns is carried by BOTH. Step 2a MEASURED what a
    // `with (app)` does to it: a bare two-argument call compiled GREEN,
    // silently binding to EditorApp's narrow two-parameter delegate field.
    // Spelling `app.` / `ifs.` out turns that trap into a compile error here
    // (there is no `with` for a bare name to fall into) and keeps the moved
    // body's indentation identical to the original, so the 32-line diff above
    // is exactly the set of binding decisions and nothing else. The six-
    // parameter call below is the ABI half of the same trap: it is written
    // `ifs.buildToolVts(...)` for the same reason both keyboard handlers do.
    //
    // Covered BY VALUE, named rather than assumed -- three suite tests read
    // this handler through three different branches:
    // tests/test_camera.d replays Alt+LMB orbit / Alt+Shift+LMB pan /
    // Ctrl+Alt+LMB zoom event logs through /api/play-events and asserts the
    // resulting camera state exactly (`assertCameraState`), which is the
    // camera-drag half AND the cross-client witness for `ifs.dragMode`: the
    // press handler is still main()'s and writes the cluster through main()'s
    // forwarder, this handler reads it through the router's class reference,
    // so a by-value copy of the cluster would leave `dragMode` at `None` here
    // and the orbit would never happen;
    // tests/test_lasso_select.d drives an RMB lasso and asserts the selected
    // id set -- the `rmbDragging` / `ifs.rmbPath` append;
    // the `doSelectPickAt` call at the bottom has NO suite witness: the
    // hover-freeze and fresh-hover tests emit motion with the button held, but
    // under an active haul tool this handler returns at the tool's
    // onMouseMotion above the pick branch, and their assertions are satisfied
    // by the mouse-DOWN handler's own pick (measured: disabling the motion-path
    // pick left both green). What protects the receiver change is the
    // compiler at all three call sites; the missing fixture is a tool-less
    // select-drag sweeping several vertices in one event batch and asserting
    // the whole swept set.
    void handleMouseMotion(ref SDL_MouseMotionEvent mot) {
        // Cooked once, before dispatch — see handleMouseButtonDown. This
        // handler returns early from half a dozen branches (the three
        // falloff RMB drags, a tool that consumed the motion, the gizmo
        // drag, `dragMode == None`), so cooking here is also what keeps the
        // previous-event pixel advancing on every event rather than only on
        // the ones that reach the bottom.
        GesturePacket gest = gestureTrack.event(GesturePacket.Phase.Move, mot.x, mot.y);
        // Keep the queryMouse override in lockstep with the latest motion
        // event so picking in subsequent render frames reads the actual
        // cursor. Without this update, doSelectPickAt's setOverrideMouse
        // (only called during select-drag) latched stale coordinates on
        // the first drag, after which queryMouse forever returned that
        // position — so a later "clear-then-pick" click would re-select
        // the face under the old cursor instead of nothing.
        setOverrideMouse(mot.x, mot.y);
        {
            import falloff_handles : screenFalloffRMBDragging, screenFalloffRMBMotion,
                                     radialFalloffRMBDragging, radialFalloffRMBMotion,
                                     elementFalloffRMBDragging, elementFalloffRMBMotion;
            if (screenFalloffRMBDragging()) {
                screenFalloffRMBMotion(mot.x);
                return;
            }
            if (radialFalloffRMBDragging()) {
                Viewport vp2 = app.vpm.originSnapshot();
                radialFalloffRMBMotion(mot.x, mot.y, vp2);
                return;
            }
            if (elementFalloffRMBDragging()) {
                Viewport vp2 = app.vpm.originSnapshot();
                elementFalloffRMBMotion(mot.x, mot.y, vp2);
                return;
            }
        }
        if (rmbDragging)
            ifs.rmbPath ~= ImVec2(cast(float)mot.x, cast(float)mot.y);
        if (app.activeTool) {
            SubjectPacket subj; VectorStack vts; ifs.buildToolVts(subj, vts, mot.x, mot.y, true, gest);
            if (app.activeTool.onMouseMotion(mot, vts)) return;
        }
        // Host falloff-gizmo endpoint drag (no tool active). The gizmo writes
        // the new endpoint to the FalloffStage via tool.pipe.attr.
        if (app.activeTool is null && app.pipeGizmoHost.isDragging()) {
            Viewport vpg = app.vpm.originSnapshot();
            if (app.pipeGizmoHost.routeMotion(mot, vpg)) return;
        }
        if (ifs.dragMode == DragMode.None) return;

        SDL_Keymod mods = SDL_GetModState();
        bool ctrl  = (mods & KMOD_CTRL)  != 0;
        bool alt   = (mods & KMOD_ALT)   != 0;
        bool shift = (mods & KMOD_SHIFT)  != 0;

        bool modOk = (ifs.dragMode == DragMode.Zoom)      ? (ctrl && alt)
                   : (ifs.dragMode == DragMode.Pan)       ? (alt && shift)
                   : (ifs.dragMode == DragMode.Orbit)     ? (alt && !shift)
                   : (ifs.dragMode == DragMode.Roll)      ? (alt && !shift && !ctrl)
                   : (ifs.dragMode == DragMode.Select    ||
                      ifs.dragMode == DragMode.SelectAdd  ||
                      ifs.dragMode == DragMode.SelectRemove) ? true
                   : false;
        if (!modOk) { ifs.dragMode = DragMode.None; return; }

        int dx = mot.x - lastMouseX;
        int dy = mot.y - lastMouseY;

        // Coupled pan/zoom (task 0217): drag math (basis, screen-space delta)
        // always uses the ORIGIN cell's own camera (its ortho preset basis
        // for Pan; its own distance scale for Zoom), but the write target is
        // redirected to the linkage owner (scaleOwner/focusOwner) so a
        // default follower's drag moves the whole linked group instead of a
        // field `resolveFollow` never reads. A cell with `indScale`/
        // `indCenter` on (opt-in override) owns itself, so it zooms/pans
        // independently exactly as before.
        int originId = app.vpm.dragOriginId >= 0 ? app.vpm.dragOriginId : app.vpm.activeId;
        if      (ifs.dragMode == DragMode.Orbit && !app.vpm.originIsOrtho()) {
            // Two implementations of one drag, chosen by a preference. The
            // trackball reads the ABSOLUTE cursor (its arc is the angle between
            // where the press and the cursor sit on a virtual ball, so the same
            // delta rotates differently depending on where in the pane it
            // happens); the two-axis orbit reads the delta. With the option off
            // — the shipped default — this is the identical `orbit(dx, dy)`
            // call this line has always made, reached past one bool read.
            // The clock is the EVENT's, not the frame's, and the difference
            // is the whole reason this is a parameter. It is used for one
            // thing — dividing the last step's arc into a release rate — and
            // the honest divisor is the interval between the two MOTIONS, which
            // is what SDL stamps on the event when it arrives. Reading a clock
            // here instead would divide by the interval between the FRAMES that
            // happened to process them: identical for live input, and for a
            // replay a measurement of how loaded the machine is. A replayed
            // event carries the stamp its log gave it (0 unless the log says
            // otherwise), and two events sharing a stamp leave no spin — so a
            // log that never recorded when things happened reports, correctly,
            // that it does not know. See `EventPlayer`'s `ts` field.
            if (app.vpm.originCamera().trackballActive())
                app.vpm.originCamera().trackballMove(mot.x, mot.y, mot.timestamp);
            else
                app.vpm.originCamera().orbit(dx, dy);
        }
        // Bank writes the ORIGIN cell's own camera, mirroring orbit exactly
        // (orbit does not redirect through a rotate-owner either). Whatever
        // coupling orbit grows, bank inherits by construction.
        else if (ifs.dragMode == DragMode.Roll)  app.vpm.originCamera().rollBy(dx);
        else if (ifs.dragMode == DragMode.Zoom)  app.vpm.scaleOwnerCamera(originId).zoom(dx);
        else if (ifs.dragMode == DragMode.Pan ||
                 (ifs.dragMode == DragMode.Orbit && app.vpm.originIsOrtho())) {
            // Alt+LMB in an orthographic cell (task 0224): orbit is meaningless
            // in an axis-locked ortho view, so it pans instead — same coupled
            // focusOwner path as Alt+Shift+LMB (task 0217).
            Vec3 delta = app.vpm.originCamera().panDelta(dx, dy);
            app.vpm.focusOwnerCamera(originId).focus += delta;
        }

        // Select-drag: run the appropriate picker on EVERY motion event.
        // Without this, picks only happen once per render frame; in fast
        // event-playback scenarios (and any rapid drag) intermediate cursor
        // positions get skipped, missing verts/edges the cursor passed over.
        // The delegate is bound after the pickers are declared (see below).
        if (ifs.dragMode == DragMode.Select
         || ifs.dragMode == DragMode.SelectAdd
         || ifs.dragMode == DragMode.SelectRemove) {
            doSelectPickAt(mot.x, mot.y);
        }

        lastMouseX = mot.x;
        lastMouseY = mot.y;
    }

    // ---- Task 0781 step 2e: THE DISPATCHER AND THE THREE PICKER BODIES ---
    //
    // The last of the seven handlers, plus the three picker closures the
    // press/motion pair called through delegate fields since 2c/2d. Bodies are
    // app.d's verbatim; the only edits are the `app.` / `ifs.` bindings this
    // seam always costs and the three headers (`router.doXxx = (args) { ... };`
    // -> `void doXxx(args) { ... }`), because a closure over main()'s frame has
    // no frame left to close over.
    //
    // WHY THE DISPATCHER GOES LAST, and it is not just tidiness: it is the one
    // function that names the other six. Moving it first would have meant six
    // `router.handleX` call sites inside the router pointing at functions still
    // nested in main() -- exactly the split brain the step order exists to
    // avoid. With it here, every `case` in the switch is a bare method call on
    // `this`, and main()'s event loop has one entry point, `router.processEvent`.
    //
    // NO `with (app)` IN THIS BLOCK, deliberately (plan §5): `EditorApp` carries
    // members of the same names as the cluster's -- the hover triple and
    // `buildToolVts` -- so a bare name under `with (app)` would bind silently to
    // the wrong storage. Every binding below is spelled out.

    void doSelectPickAt(int mx, int my) {
        setOverrideMouse(mx, my);
        Viewport vp = app.vpm.activeSnapshot();
        int pickedVertex = -1;
        int pickedEdge = -1;
        int pickedFace = -1;
        // The ordering, item-inclusive (task 0655) — NOT `editMode`. The
        // mouse-DOWN path already returns before this under the item type
        // (the 0643 branch in handleMouseButtonDown), but this delegate is
        // ALSO bound to mouse-MOTION during a select drag, and a drag that
        // outlives a type flip would otherwise resume picking geometry from a
        // cache that never mentions items. Under `SelType.Item` none of the
        // three branches runs and the triple stays all -1, which
        // `publishElementCandidates` already reads as "no element here".
        final switch (viewportPickType(app.selTypeOrder)) {
            case SelType.Vertex:
                ifs.pickVertices(vp, false);
                pickedVertex = ifs.hoveredVertex;
                break;
            case SelType.Edge:
                ifs.pickEdges(vp, false);
                pickedEdge = ifs.hoveredEdge;
                break;
            case SelType.Polygon:
                ifs.pickFaces(vp, false);
                pickedFace = ifs.hoveredFace;
                break;
            case SelType.Item:
                break;
        }
        publishElementCandidates(mx, my, pickedVertex, pickedEdge, pickedFace);
        // Stash for the mouse-DOWN capture hook (cheap; the motion path runs
        // through here too but never reads these back, so it stays zero-cost).
        aiLastPickedVertex = pickedVertex;
        aiLastPickedEdge   = pickedEdge;
        aiLastPickedFace   = pickedFace;
    }

    void doItemSelectPickAt(int mx, int my, bool ctrl, bool shift) {
        if (!ifs.viewportInputAllowed()) return;
        setOverrideMouse(mx, my);
        Viewport vp = app.vpm.activeSnapshot();
        immutable ItemHit h = ifs.pickItemUnderCursor(mx, my, vp);
        // A MISS EMPTIES THE ITEM SELECTION (task 0654).
        //
        // 0643 made a miss do NOTHING, for one stated reason: "that state is
        // unrepresentable (at least one item is always selected)". The
        // reference was then measured (0653) and empties on a miss; the owner
        // decided we follow it, and 0654 removed the invariant that was the
        // whole basis of the do-nothing branch. So this is not a preference
        // reversal — the premise 0643 named is simply gone.
        //
        // The MODIFIED chords do not empty. Ctrl/shift are set-EDITING chords:
        // ctrl-clicking empty space means "remove nothing", shift-clicking it
        // means "add nothing". Emptying there would make a mis-aimed
        // ctrl-click destroy a set the user was building, and the geometry
        // select path treats a modified miss the same way.
        if (!h.hit) {
            if (ctrl || shift) return;
            if (app.document.selectedItemCount() == 0) return;  // already empty
            runCommandWithArgs("layer.select", "mode:clear");
            return;
        }
        // Already the SOLE selection: a bare `set` on it would push a UI-undo
        // entry that reverts to the state it came from, so clicking the one
        // selected item twice would cost the user an Esc-less undo step that
        // does nothing visible. All three conditions are needed — with two
        // items selected, a bare click on one of them genuinely collapses the
        // set to one and must go through.
        //
        // TASK 0671 — `.selected`, NOT `isPrimary`. The two agreed while the
        // edit target had to be a selected item, and `isPrimary` was the
        // spelling. They part company the moment a target is latched behind a
        // selection it is not in: click a reference plane (the plane alone is
        // selected, the mesh keeps the target), then click the MESH, and the
        // guard read `selCount == 1 && isPrimary(mesh)` as "already the sole
        // selection" and swallowed the click. The mesh was not selected at all
        // — the user could not select it back by clicking it.
        {
            size_t selCount = 0;
            foreach (l; app.document.layers) if (l !is null && l.selected) ++selCount;
            if (!ctrl && !shift && selCount == 1
                && app.document.layers[h.layerIndex].selected)
                return;
        }
        import std.format : format;
        immutable string mode = ctrl ? "remove" : (shift ? "add" : "set");
        runCommandWithArgs("layer.select",
                                  format("index:%d mode:%s", h.layerIndex, mode));
    }

    void refreshHoverPickAt(int mx, int my) {
        setOverrideMouse(mx, my);
        Viewport vp = app.vpm.activeSnapshot();
        ifs.pickVertices(vp, false);
        if (app.edgeCache().needsUpdate(vp)) { app.edgeCache().invalidate(); app.edgeCache().update(vp); }
        ifs.pickEdges(vp, false);
        if (app.faceCache().needsUpdate(vp)) { app.faceCache().invalidate(); app.faceCache().update(vp); }
        ifs.pickFaces(vp, false);
        int pickedVertex = ifs.hoveredVertex;
        int pickedEdge = ifs.hoveredEdge;
        int pickedFace = ifs.hoveredFace;
        // Tool-driven multi-type priority (vert first, then edge, then face),
        // mirroring the render-loop resolution so the published hover matches.
        if (app.activeTool !is null) {
            if (ifs.hoveredVertex >= 0) { ifs.hoveredEdge = -1; ifs.hoveredFace = -1; }
            else if (ifs.hoveredEdge >= 0) { ifs.hoveredFace = -1; }
        }
        publishElementCandidates(mx, my, pickedVertex, pickedEdge, pickedFace);
        import hover_state : g_hoveredVertex, g_hoveredEdge, g_hoveredFace;
        g_hoveredVertex = ifs.hoveredVertex;
        g_hoveredEdge   = ifs.hoveredEdge;
        g_hoveredFace   = ifs.hoveredFace;
    }

    void pieFireHovered() {
        import pie_menus       : findPieMenu;
        import ui.availability : actionRefusal;
        import ui.panels       : dispatchAction;

        auto m    = findPieMenu(g_pie.menuId);
        int  slot = g_pie.hover;
        closePie();
        if (m is null || slot < 0 || slot >= cast(int) m.items.length) return;

        auto btn = m.items[slot];
        if (btn.disabled) return;
        if (actionRefusal(app.reg, btn.action, app.document.hasEditTarget(),
                          app.activeToolId).length > 0) return;
        dispatchAction(app, btn.action);
    }

    // Is `sym` one of the modifier keys the opening chord required? Releasing
    // EITHER half of "Ctrl+Space" ends the gesture — a user who lets go of
    // Ctrl first has finished aiming just as much as one who lets go of Space.
    static bool pieChordModifier(SDL_Keycode sym, ushort mods) {
        switch (sym) {
            case SDLK_LCTRL:  case SDLK_RCTRL:  return (mods & KMOD_CTRL)  != 0;
            case SDLK_LSHIFT: case SDLK_RSHIFT: return (mods & KMOD_SHIFT) != 0;
            case SDLK_LALT:   case SDLK_RALT:   return (mods & KMOD_ALT)   != 0;
            case SDLK_LGUI:   case SDLK_RGUI:   return (mods & KMOD_GUI)   != 0;
            default: return false;
        }
    }

    bool processEvent(SDL_Event* ev) {
        evLog.log(*ev);
        bool isF1orF2 = ev.type == SDL_KEYDOWN &&
            (ev.key.keysym.sym == SDLK_F1 || ev.key.keysym.sym == SDLK_F2);
        if (!isF1orF2) recLog.log(*ev);

        // ---- Pie menu input grab (task 1800) ----------------------------
        //
        // BEFORE ImGui and before every gate below, because an open pie is
        // MODAL and is anchored wherever the chord was pressed — which may be
        // over a docked panel, where `viewportInputAllowed()` would otherwise
        // eat the very click meant for a wedge, or over an ImGui button, which
        // would otherwise see the press under the ring and fire on release.
        // The event is still LOGGED above, so a replay reproduces the gesture.
        if (g_pie.open) {
            switch (ev.type) {
                case SDL_MOUSEMOTION:
                    aimPie(ev.motion.x, ev.motion.y);
                    return true;
                case SDL_MOUSEBUTTONDOWN:
                    // Swallowed; the wedge runs on the RELEASE half of the
                    // click, off the position the button came UP at — which is
                    // the wedge the ring was visibly highlighting.
                    return true;
                case SDL_MOUSEBUTTONUP:
                    if (ev.button.button == SDL_BUTTON_LEFT) {
                        aimPie(ev.button.x, ev.button.y);
                        pieFireHovered();
                    } else {
                        closePie();
                    }
                    return true;
                case SDL_KEYUP:
                    // RELEASING THE CHORD DISMISSES — it never selects. The
                    // ring lives exactly as long as the chord is held down,
                    // and the only thing that runs a wedge is a CLICK while it
                    // is up (owner's call 2026-08-23, matching the reference).
                    //
                    // Either half of the chord ends it: a user who lets go of
                    // Ctrl first has stopped holding "Ctrl+Space" just as much
                    // as one who lets go of Space.
                    //
                    // `armedKey == 0` — a ring opened by something other than a
                    // chord (`/api/command ui.pie …`) — has no chord to
                    // release, so no key release may close it; it waits for the
                    // click or for Esc.
                    if (g_pie.armedKey != 0 &&
                        (ev.key.keysym.sym == g_pie.armedKey ||
                         pieChordModifier(ev.key.keysym.sym, g_pie.armedMods)))
                        closePie();
                    return true;
                case SDL_KEYDOWN:
                    if (ev.key.keysym.sym == SDLK_ESCAPE) { closePie(); return true; }
                    // Every other key is swallowed while the ring is up: it
                    // is a menu, not an overlay. The opening chord's own auto-
                    // repeat lands here too and stops here, so a held chord
                    // cannot re-dispatch `ui.pie` and drag the ring along
                    // under the cursor.
                    return true;
                default: break;
            }
        }

        // THE ONLY DOOR INTO IMGUI (task 1850). Tab is the subpatch toggle;
        // ImGui's keyboard-focus walk eats it as well, so one press both
        // toggled the flag and crept the focus one widget along. `feedImGui`
        // holds back exactly the Tab PRESSES ImGui would turn into a focus
        // move — bare and Shift+Tab — and passes everything else, releases
        // included. Ctrl+Tab still reaches ImGui: that is the window switcher,
        // not a focus move. The rule, and why it has no `WantTextInput`
        // carve-out, are in `source/imgui_event_gate.d`; do not re-inline this
        // call, a unittest scans `source/` for a second caller.
        feedImGui(ev);

        // Route through viewportInputAllowed() so mouse events over the docked
        // "Viewport" window still reach 3D picking/orbit (objection 1 fix).
        // In --test viewportInputAllowed()==!io.WantCaptureMouse → byte-identical.
        //
        // Drag-capture (task 0222): once a pointer gesture is ACTIVE
        // (`vpm.dragOriginId >= 0`, set on button-DOWN over a cell), the
        // remaining MOTION/UP events must reach the origin cell REGARDLESS of
        // where the cursor now is — over a panel, another Quad/Split cell, or
        // outside the window. Without this bypass an RMB-lasso (or LMB
        // box-select / camera drag) whose cursor left the origin cell had its
        // terminating UP swallowed by the gate → the gesture hung (lasso kept
        // drawing, selection never committed). The active-gesture guard lets
        // the UP through so handleMouseButtonUp always completes + clears it.
        // (SDL-level capture for the out-of-window case is already provided by
        // ImGui: the ##vpHit InvisibleButton becomes the active item on press,
        // and ImGui's SDL2 backend SDL_CaptureMouse()s while an item is active.)
        if (!app.testMode && !ifs.viewportInputAllowed() && app.vpm.dragOriginId < 0 &&
            (ev.type == SDL_MOUSEBUTTONDOWN ||
             ev.type == SDL_MOUSEBUTTONUP   ||
             ev.type == SDL_MOUSEMOTION      ||
             ev.type == SDL_MOUSEWHEEL))
            return true;

        // A FOCUSED TEXT FIELD OWNS THE KEYBOARD. Same rule as before, moved
        // into `imgui_event_gate` so it can be tabled in a unittest (task
        // 1850): the gate above now holds a bare Tab PRESS back from ImGui, so
        // the focus can no longer walk off a field by itself — which makes THIS
        // line the only thing between a Tab pressed mid-typing and the subpatch
        // toggle at `case SDLK_TAB`. It did not have that job before the fix
        // (the focus left the field on Tab #1 and Tab #2 came through here
        // unswallowed), so it is pinned now rather than left inline.
        if (!keyBelongsToEditor(ev.type, app.io.WantTextInput))
            return true;

        // Phase 1c — input-router seam: compute hovered/active viewport per
        // mouse event.  With ONE viewport (Phase 1) viewportUnderCursor()
        // trivially returns 0 or −1, so activeId/hoveredId never leave 0 and
        // the block is a no-op that doesn't change behaviour.
        //
        // Phase 4 will (a) route camera-manip to hoveredCamera(), (b) gate
        // viewport input on hoveredId >= 0, (c) freeze the active Viewport3D
        // at gizmo-drag start — all in this block.
        {
            int _rtx = -1, _rty = -1;
            if (ev.type == SDL_MOUSEBUTTONDOWN || ev.type == SDL_MOUSEBUTTONUP) {
                _rtx = ev.button.x; _rty = ev.button.y;
            } else if (ev.type == SDL_MOUSEMOTION) {
                _rtx = ev.motion.x; _rty = ev.motion.y;
            } else if (ev.type == SDL_MOUSEWHEEL) {
                SDL_GetMouseState(&_rtx, &_rty);
            }
            if (_rtx >= 0) {
                app.vpm.hoveredId = app.vpm.viewportUnderCursor(_rtx, _rty);
                // Focus-follows-mouse: the active cell tracks the hovered one
                // on every positioned mouse event (motion/wheel/down/up), not
                // just on click — see ViewportManager.followHover() for the
                // dragOriginId pin + panel-hover fallback rationale.
                app.vpm.followHover();
                if (ev.type == SDL_MOUSEBUTTONDOWN && app.vpm.hoveredId >= 0) {
                    app.vpm.activeId     = app.vpm.hoveredId;
                    app.vpm.dragOriginId = app.vpm.hoveredId;
                }
                if (ev.type == SDL_MOUSEBUTTONUP)
                    app.vpm.dragOriginId = -1;
            }
        }

        switch (ev.type) {
            // Window [X] / SIGINT (task 0434, re-pointed by 1521): build the
            // ORDINARY `file.quit` command and run it through the ONE guarded
            // UI entry, so the window close and Ctrl+Q are literally the same
            // path. `fromWindowClose` is the only difference and it buys
            // exactly one thing: `--test` must still be able to close the
            // window (the harness ends every session that way), while a
            // `file.quit` DISPATCHED by a test must not take the shared
            // instance down with it. Keep processing this frame (return true).
            case SDL_QUIT:
                {
                    import commands.file.quit : FileQuit;
                    auto q = cast(FileQuit) app.reg.commandFactories["file.quit"]();
                    if (q !is null) q.setFromWindowClose(true);
                    app.runUiCommand(q, RecordMode.Record, "file.quit");
                }
                break;
            case SDL_WINDOWEVENT:     handleWindowEvent(ev.window); break;
            case SDL_KEYDOWN:         handleKeyDown(ev.key);      break;
            // Task 0709 — the release side of the pair above. Absent until
            // this task, which is what made `Tool.onKeyUp` unreachable.
            case SDL_KEYUP:           handleKeyUp(ev.key);        break;
            case SDL_MOUSEBUTTONDOWN: handleMouseButtonDown(ev.button); break;
            case SDL_MOUSEBUTTONUP:   handleMouseButtonUp(ev.button);   break;
            case SDL_MOUSEWHEEL:      handleMouseWheel(ev.wheel);   break;
            case SDL_MOUSEMOTION:     handleMouseMotion(ev.motion); break;
            default: break;
        }
        return true;
    }
}


// The SDL-free half of `handleWindowEvent`: the window-size law, extracted so
// it can be asserted at all (task 0781 step 2e, plan §6.1).
//
// THIS EXISTS BECAUSE THE HANDLER HAD NO ORACLE AND COULD NOT GET ONE FROM AN
// EVENT LOG. `EventPlayer` does replay a `SIZE_CHANGED` payload, but
// `handleWindowEvent` only feeds it to `SDL_SetWindowSize`, and only under
// `playbackMode` -- which is true for `--playback` and false under
// `/api/play-events`, the way every suite test drives the app. Everything
// downstream then comes from `SDL_GetWindowSize`, i.e. from the real, unchanged
// window: a `sub:6` fixture would run the handler and assert nothing. The
// unittest in tests/unit/window_metrics_test.d drives THIS function instead,
// at two window sizes and two layout presets.
//
// The SDL half (`SDL_SetWindowSize`/`SDL_GetWindowSize`/`SDL_GL_GetDrawableSize`,
// `glViewport`, `initThickLineProgram`, `setReplayCurrentViewport`) is still
// unwitnessed and is registered as such rather than papered over.
//
// The vpm block below is a near-dead path in practice -- the interactive ImGui
// window loop re-stamps every cell's rect from GetContentRegionAvail/
// GetCursorScreenPos on the very next frame, and --test never resizes the
// window -- but it keeps vpm.l* (read by viewportUnderCursor/applyLayout)
// coherent for the narrow window between this event and that next stamp. Only
// rects are touched (NOT a full applyLayout, which would also reset
// independence/preset).
void applyWindowMetrics(ref Layout layout, ViewportManager vpm, int w, int h) {
    layout.resize(w, h);

    // Single event-driven writer of the picking region (vpm.l*) and reflow of
    // the live cells' rects on a resize.
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
