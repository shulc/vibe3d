module input_frame_state;

// Task 1040 (chain: 0678 §2C A10 / 0722 / 0781): the input/frame SHARED
// STATE cluster.
//
// 0781 classified main()'s free names for the input-router extraction and
// found a fourth class beyond InputRouter's own three buckets (pure
// references / router-exclusive state / neighbour functions): names that
// neither the not-yet-extracted router NOR the not-yet-extracted frame body
// (task 0782) owns, because input PRODUCES this state and the frame
// CONSUMES it -- the lasso path is appended by input and drawn by the
// frame; the spin-inertia flag is set by input and keeps the frame
// redrawing. Owner's decision (doc/tasks/work/0781-*.md, 2026-08-15,
// "ВАРИАНТ Г"): that state gets its own home FIRST, before either the
// router or the frame body moves further. This module IS that home.
//
// Measured shared surface (uses in app.d before this move): `dragMode` 46,
// `rmbPath` 13, `anySpinning` 6, `buildToolVts` 25, `viewportInputAllowed`
// 15.
//
// `DragMode` relocates here too, for the same reason `OverlayMode` already
// relocated from app.d to editor_app.d (task 0419, see app.d's own comment
// at the old declaration site): it is the type of exactly one field below,
// grep-verified to have zero real (non-comment) uses outside app.d, so
// moving it here and importing it back avoids a fresh app.d <->
// input_frame_state.d import cycle for a plain enum.
//
// Same seam as `InputRouter` (source/input_router.d) and `EditorApp`
// (source/editor_app.d): a class holding an `EditorApp app` by value plus
// its own state/logic, constructed once in main() and threaded through.
// Deliberately NOT a member of `EditorApp` itself (audit rule A10 --
// EditorApp already carries ~190 members) and NOT a member of
// `InputRouter` either -- 0781 stopped short of folding this surface into
// InputRouter specifically because its production/consumption split does
// not follow the router/frame boundary; it needed a third, separate home.
//
// `final class`, not a struct (task 0781 step 1a,
// doc/input_state_cluster_plan.md §2.1): task 1040 (below) made it a
// struct because at the time there was exactly one holder. Step 1a of
// 0781's plan gives `InputRouter` a reference to this SAME object (task
// 0781 step 2, not this commit) -- and `InputRouter` already holds its own
// `EditorApp app` field by value, cheaply, because `EditorApp` is itself a
// bag of pointers. `InputFrameState` is the opposite: the state lives IN
// it. A struct field on `InputRouter` would silently give the router its
// OWN `dragMode`/`rmbPath`/hover triple -- a router-side write would never
// reach the frame body's reads, and nothing would fail to compile. A class
// makes that misuse impossible to write instead of forbidden by a comment,
// the same reason `document.d`'s `Layer` and `viewport.d`'s
// `ViewportManager` are classes. `final` because nothing subclasses it and
// the per-event `dragMode` read/write path keeps a devirtualized call.
//
// Step 1a also folds three more names into the cluster, by the same
// producer/consumer argument as the original five: `fbW`/`fbH` (resize
// writes, the frame body's viewport/DPI math reads), the viewport-hover
// flag itself rather than a pointer back into main() (the frame body's
// three writes now go through a same-name forwarder that reaches straight
// into this object), and `previewIndexSpaceStale`'s body (task 1730's
// index-space-staleness guard, read by the pick family and the frame
// body). See each member below for the specific reasoning.
//
// Step 1b folds in the hover triple -- `hoveredVertex`/`hoveredEdge`/
// `hoveredFace`, three `main()` locals written by the pick family and read
// by the frame body, by `ui/viewport_render.d` under `with (app)`, and by
// the toolpipe hover key. `EditorApp`'s three POINTER fields
// (`hoveredVertexPtr`/`EdgePtr`/`FacePtr`) are repointed at these members
// rather than duplicated, so `EditorApp` gains no member and every
// existing reader sees the same storage. The cross-module publish channel
// `hover_state.g_hovered*` is deliberately NOT folded in (plan §2.3): the
// cluster owns the SOURCE, the `__gshared` triple stays the CHANNEL that
// four tool modules and two HTTP providers read without holding an
// `EditorApp`.
//
// TASK 1040'S OWN STEP -- the paragraph's figures below describe THAT
// commit, not today's cluster -- moved only the state and the two
// functions' bodies: five names, five same-name forwarders in main(),
// ~105 call sites left textually identical. The current membership and
// forwarder count are carried by the 0781 paragraphs above instead
// (step 1a: three functions, nine forwarders; step 1b: twelve
// forwarders). What has NOT changed is the rule that step established,
// and it still governs every member added since: a body moves, its
// callers do not. Who calls the cluster next is steps 2 and 3 -- the
// router, then the frame body, become its clients -- and until then
// main()'s existing call sites (inside the SDL-event handlers 0781 has
// not yet extracted, the pick* family, and the frame body) keep their
// bare, unqualified names behind a same-name forwarding declaration at
// each original position: a nested `@property ref` for a state field, a
// nested wrapper preserving the full parameter list for a function. See
// the task Log for the D forward-reference constraint (nested
// functions/closures cannot forward-reference a not-yet-declared sibling
// or local, confirmed by a standalone probe) that fixed where app.d's
// instance has to be declared: before EVERY forwarder, i.e. near the top
// of main(), well before `EditorApp app` itself is assembled -- its
// `.app` field is wired later, at the same point `InputRouter.app`
// already is.

import editor_app         : EditorApp;
import toolpipe.packets   : SubjectPacket, GesturePacket;
import operator           : VectorStack;
import toolpipe.subject   : SubjectSource, evaluateSubject;
import seltype             : currentSelType;
import d_imgui.imgui_h    : ImVec2;

/// Relocated verbatim from app.d (task 1040) -- see this module's doc
/// comment for why it moved instead of being imported back the other way.
enum DragMode { None, Orbit, Zoom, Pan, Roll, Select, SelectAdd, SelectRemove }

/// The input/frame shared-state cluster (task 1040). Constructed once in
/// main() (`auto ifs = new InputFrameState();`), wired the same way
/// `InputRouter router` already is. A `final class`, not a struct (task
/// 0781 step 1a) -- see the module doc comment above.
final class InputFrameState {
    EditorApp app;

    // ---- state: moved bodily from main() locals of the same name. Every
    //      existing main() read/write site keeps working through a same-
    //      name forwarding nested function declared at the field's
    //      original app.d declaration point (see app.d's Log for the exact
    //      lines) -- these three need no pointer back into main() (unlike
    //      InputRouter's winW/winH) because nothing outside this class
    //      reads them under their own name yet; the forwarders are, for
    //      now, this class's only callers. ----
    DragMode dragMode    = DragMode.None;
    ImVec2[] rmbPath;
    bool     anySpinning = false;

    // Task 0781 step 1a: framebuffer size in physical pixels, folded in
    // from main()'s own `fbW`/`fbH` locals by the same producer/consumer
    // argument as the three fields above -- resize (input) writes them,
    // the frame body's viewport/DPI math reads them. `InputRouter.fbWPtr`/
    // `fbHPtr` point straight at these two fields now, the same way they
    // already pointed at the main()-local pair before this step.
    int fbW, fbH;

    // Task 0781 step 1b: the hover triple, folded in from main() locals of
    // the same name by the same producer/consumer argument -- the pick
    // family (input) writes them, the frame body reads them (its hover
    // publish block, and the toolpipe display key's `hovV`/`hovE`/`hovF`
    // terms).
    //
    // These three have a THIRD reader the other members do not, and it is
    // why they must be fields and not a pointer: `EditorApp`'s
    // `hoveredVertexPtr`/`EdgePtr`/`FacePtr` are repointed straight at them
    // (app.d, next to the other pointer wiring), so `ui/viewport_render.d`
    // -- which reads `hoveredVertex`/`hoveredEdge`/`hoveredFace` BARE under
    // `with (app)`, never as `app.hoveredEdge` -- keeps seeing the same
    // storage the pickers write. `EditorApp` therefore gains no member;
    // three of its existing pointers just change what they point at, and
    // the `final class` from step 1a is what makes that address stable for
    // the whole run.
    //
    // NOT the same thing as `hover_state.g_hoveredVertex/Edge/Face`, and
    // those deliberately stay where they are (plan §2.3): that `__gshared`
    // triple is the cross-module PUBLISH channel four tool modules and two
    // HTTP providers read without holding an `EditorApp`. The publish sites
    // (`refreshHoverPickAt`'s tail and the frame body's pick block) mirror
    // these fields into it. This cluster owns the SOURCE; the channel stays
    // a channel.
    int hoveredVertex = -1;
    int hoveredEdge   = -1;
    int hoveredFace   = -1;

    // buildToolVts's own publish slot. Kept out of buildToolVts's own
    // stack frame for the same reason main() kept it out before the move
    // (app.d's original comment, carried forward here): VectorStack stores
    // POINTERS into it, and the stack a caller builds must outlive the
    // call (every caller holds its own `vts` across the dispatch that
    // follows) -- so it needs storage that lives as long as this cluster
    // does, i.e. the whole run, exactly like main()'s frame did before.
    GesturePacket gestureSlot;

    // Verbatim body from app.d's main() (task 1040 relocation). The only
    // free-name change is `mesh()`/`editMode`/`selTypeOrder`/`vpm` reading
    // through `app.` -- EditorApp's own properties forward to the SAME
    // main()-local `mesh()`/`editMode`/`selTypeOrder`/`vpm` this function
    // read directly before the move (see EditorApp.meshDg / .editModePtr /
    // .selTypeOrderPtr / .vpm, wired at app.d's early ctx-assembly block,
    // well before this method is ever called).
    //
    // Full six-parameter form, unlike `EditorApp.buildToolVts`'s own field
    // (still the narrow two-parameter delegate 0781 flagged as an ABI trap
    // -- see this class's module doc comment): this is the trap the owner
    // asked this task to fix. Whatever THIS cluster exposes IS the full
    // form, so a caller reaching it cannot silently get the short one the
    // way `EditorApp.buildToolVts`'s field-typed callers can.
    void buildToolVts(out SubjectPacket subj, ref VectorStack vts,
                       int curX = -1, int curY = -1, bool curValid = false,
                       GesturePacket gest = GesturePacket.init) {
        auto src = SubjectSource(&app.mesh(), app.editMode,
                                  currentSelType(app.selTypeOrder),
                                  app.vpm.inputSnapshot());
        src.cursorX     = curX;
        src.cursorY     = curY;
        src.cursorValid = curValid;
        gestureSlot = gest;
        evaluateSubject(subj, vts, src, &gestureSlot);
    }

    // Task 0781 step 1a: the flag itself, not a pointer back into main().
    // Before this step the not-yet-extracted frame body wrote
    // `g_viewportWindowHovered` (a main()-local `bool`) directly at three
    // sites, so this class only held a pointer at it. Now app.d's own
    // same-name forwarder (`g_viewportWindowHovered`, a `@property ref`
    // like `dragMode`'s) reaches straight into this field, so the frame
    // body's three writes land here with no indirection left to hold onto.
    bool viewportWindowHovered;

    // Verbatim body from app.d's main() (task 1040 relocation); reads
    // `viewportWindowHovered` directly instead of through a pointer (task
    // 0781 step 1a).
    bool viewportInputAllowed() {
        if (app.testMode) return !app.io.WantCaptureMouse;
        return viewportWindowHovered;
    }

    // Task 0781 step 1a: relocated from a nested function of the same name
    // in main() (task 1730's index-space-staleness guard -- see app.d's
    // comment at the surviving forwarder for what this predicate protects).
    // Reads through `app.subpatchPreview`/`app.gpuUploadedPreview` because
    // both stay main() locals (doc/input_state_cluster_plan.md §2.3) --
    // only the predicate itself moved.
    bool previewIndexSpaceStale() {
        return app.subpatchPreview.buildPending
            && !app.subpatchPreview.buildPastCeiling()
            && app.gpuUploadedPreview;
    }
}
