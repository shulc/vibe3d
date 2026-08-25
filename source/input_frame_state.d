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
// body). See each member below for the specific reasoning. Forwarder count
// in main() after step 1a: NINE (`dragMode`, `rmbPath`, `anySpinning`,
// `buildToolVts`, `viewportInputAllowed` from task 1040, plus `fbW`, `fbH`,
// `g_viewportWindowHovered`, `previewIndexSpaceStale`).
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
// `EditorApp`. Forwarder count in main() after step 1b: TWELVE (the nine
// above plus the triple).
//
// Step 1c folds in the PICK FAMILY -- `pickHover` and its `pickVertices`/
// `pickEdges` instantiations, `pickFaces`, `pickItemUnderCursor`,
// `pickItems` -- together with the two references only they read,
// `itemPicker` and `useBvhFacePick`. They belong here and not in the
// not-yet-extracted router for the reason the task card measured: the frame
// body calls four of them DIRECTLY, not only through the router's picker
// delegates. Unlike 1a and 1b this is not a verbatim move -- the bodies
// read eleven `EditorApp`-backed names bare, 38 occurrences, every one of
// which now reads `app.X` -- but it is compiler-checked rather than
// reviewed; see the block comment at the family itself. Forwarder count in
// main() after step 1c: SEVENTEEN (the twelve above plus five picker
// forwarders; `pickHover` itself needs none, nothing outside the family
// names it).
//
// TASK 1040'S OWN STEP -- the paragraph's figures below describe THAT
// commit, not today's cluster -- moved only the state and the two
// functions' bodies: five names, five same-name forwarders in main(),
// ~105 call sites left textually identical. The current membership and
// forwarder count are NOT restated here -- each 0781 paragraph above
// carries its own, so the number is updated where the step that changed it
// is described. What has NOT changed is the rule that step established,
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
import seltype             : SelType, currentSelType, viewportPickType,
                             geometrySelType;
import d_imgui.imgui_h    : ImVec2;
// Task 0781 step 1c -- the pick family's own dependencies. All of these were
// already reachable from main()'s scope; none of them imports this module
// back, so no cycle appears. `math.Viewport` is the per-cell snapshot every
// picker takes by `ref`; `eventlog.queryMouse` is the replay-aware cursor
// read; `document.primaryModelSpace` is the primary layer's pose (task 0617),
// which both engines pick against.
import editmode           : EditMode;
import gpu_select         : SelectMode;
import item_pick          : ItemRayPicker, ItemHit;
import symmetry_pick      : symmetricSelectVertex, symmetricSelectEdge,
                            symmetricSelectFace;
import math               : Viewport;
import eventlog           : queryMouse;
import document           : primaryModelSpace;

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

    // Task 0781 step 1c: the two picker-owned references, moved in with the
    // pick family below because that family is their ONLY reader -- measured
    // repo-wide, not just in app.d. `itemPicker` is `pickItemUnderCursor`'s
    // CPU ray picker over the whole layer array (task 0647), deliberately a
    // second object from `app.bvhPick`, which is the PRIMARY layer's tree and
    // is keyed on that one mesh. `useBvhFacePick` is `pickFaces`'s engine
    // switch, read once from VIBE3D_FACE_PICK at startup (a runtime change
    // needs a relaunch); the environment READ stays a single site in main(),
    // but the DEFAULT lives here -- see the constructor below.
    ItemRayPicker itemPicker;
    bool          useBvhFacePick = true;

    // Task 0781 step 2, from step 1c's review: both of the fields above are
    // BORN correct instead of being correct only after main() gets to its
    // wiring block. Before this constructor the null window on `itemPicker`
    // ran from `new InputFrameState()` (app.d, top of main()) all the way to
    // `ifs.itemPicker = new ItemRayPicker()` in the LATE wiring block -- ~3,570
    // lines of main(), where step 1c's own move had widened it from the ~100
    // lines the deleted main() local had. Nothing dereferences it in that
    // window today (the pick family only runs inside the frame loop), which is
    // exactly why a regression there would be quiet rather than a startup
    // crash, so the window is closed rather than documented.
    //
    // A field initialiser cannot do this (`new` is not a compile-time
    // expression for a field), hence a constructor. `useBvhFacePick = true`
    // is its EFFECTIVE default -- main() reads `VIBE3D_FACE_PICK` with "bvh"
    // as the fallback and only "gpu" turns it off -- and it is declared as the
    // field's initialiser so that a unit test constructing this class directly
    // gets the BVH engine the app ships, not the GPU one a plain `bool`'s
    // `false` would have handed it.
    this() {
        itemPicker = new ItemRayPicker();
    }

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

    // ---- Task 0781 step 1c: the PICK FAMILY ------------------------------
    //
    // `pickHover` (+ its `pickVertices`/`pickEdges` instantiations),
    // `pickFaces`, `pickItemUnderCursor` and `pickItems`, relocated from
    // nested functions of the same names in main(). Same producer/consumer
    // argument as every member above, and the card's own key finding is what
    // puts them HERE rather than in the not-yet-extracted router: the frame
    // body calls these four DIRECTLY (its per-frame hover block), not only
    // through the router's three picker delegates -- so they are shared
    // surface, not router-exclusive.
    //
    // NOT a verbatim relocation, and the difference is worth stating because
    // it is the whole safety argument. These bodies used to read eleven
    // EditorApp-backed names BARE, as main() locals -- `activeTool`, `mesh`,
    // `vpm`, `editMode`, `selTypeOrder`, `gpu`, `gpuSelect`,
    // `ensureDisplayCurrent`, `subpatchPreview`, `document`, `bvhPick`, 38
    // occurrences between them -- and every one now reads through `app.`.
    // A MISSED PREFIX CANNOT BE SILENT: this class declares no member of any
    // of those names, and there is no `with (app)` anywhere in this module or
    // in app.d, so an un-prefixed name is an undefined identifier rather than
    // a second binding. (Do not open a `with (app)` block here: EditorApp
    // carries members named `hoveredVertex`/`hoveredEdge`/`hoveredFace` and
    // `buildToolVts` too, and under a `with` those would quietly shadow this
    // class's own -- see doc/input_state_cluster_plan.md §5.)
    //
    // The names that STAY bare are this class's own, and they are the
    // intended bindings: the hover triple, `dragMode`, `viewportInputAllowed`,
    // `previewIndexSpaceStale`, `itemPicker`, `useBvhFacePick`. That includes
    // `pickHover`'s `alias hovered = hoveredVertex;` trick, which survives the
    // move unchanged BECAUSE the triple moved first (step 1b): inside a class
    // method the alias binds a MEMBER and carries `this`. The intermediate
    // spelling `alias hovered = ifs.hoveredVertex;` does NOT compile -- it
    // binds the symbol and loses the instance -- which is why 1b could not
    // have been folded into this step.
    //
    // main() keeps five same-name forwarders at these functions' old
    // positions (`pickVertices`, `pickEdges`, `pickFaces`, `pickItems`,
    // `pickItemUnderCursor`), so every existing call site -- the three
    // router-exclusive picker delegates and the frame body's four calls --
    // is textually unchanged, exactly as steps 1a and 1b did. `pickHover`
    // itself gets no forwarder: nothing outside this family ever named it.

    // pickVertices / pickEdges share one body — they differ only in the
    // SelectMode/EditMode pair, the symmetricSelect* function, the pick
    // radius (4 px for verts, 6 px for edges) and the hovered* slot written.
    void pickHover(SelectMode sm, EditMode em, alias symSel, int radius)(
            ref Viewport vp, bool doingCameraDrag) {
        static if (em == EditMode.Vertices)
            alias hovered = hoveredVertex;
        else
            alias hovered = hoveredEdge;
        app.ensureDisplayCurrent(); // mid-batch pull-guard: VBO reader below
        // Task 1730 — the SAME freeze, for the same reason, over a different
        // window: this picker reads the ID buffer and maps it back through
        // `gpu.vertOriginGpu` / `edgeOriginGpu`, and while a rebuild is in
        // flight those map into the cage the preview was built against, not
        // the one that exists. Returning without re-picking holds the last
        // answer, exactly as the drag freeze below does.
        if (previewIndexSpaceStale()) return;
        // Freeze hover during an active tool drag (element-move haul): return
        // WITHOUT re-picking so the element picked at drag-start stays
        // highlighted instead of every element the moving cursor passes over.
        if (app.activeTool !is null && app.activeTool.isDragging()) return;
        hovered = -1;
        if (!viewportInputAllowed() || doingCameraDrag) return;
        // No active tool → ASK THE ORDERING, with the item-inclusive candidate
        // set (task 0655). This line used to read `if (editMode != em) return;`
        // and that was the defect in one line: `editMode` is a cache of the
        // SAME query asked without `Item`, so it answers a geometry type even
        // while items are the current selection type — and this hover picker
        // then ran, lighting a vertex the user cannot select. With an active
        // tool, defer to `wantsHoverForType` so tools like XfrmTransformTool
        // (with falloff.element wired) can opt in to multi-type hover
        // regardless of the current type (Stage 14.9).
        if (app.activeTool is null) {
            if (viewportPickType(app.selTypeOrder) != geometrySelType(em)) return;
        } else {
            if (!app.activeTool.wantsHoverForType(em)) return;
        }

        int mx, my;
        queryMouse(mx, my);

        // Offscreen ID buffer: GPU rasterises every cage element as an
        // ID-tagged primitive, depth-tested against the face surface so
        // elements inside / behind opaque geometry drop out. Subpatch mode
        // maps VBO indices back to cage indices inside GpuSelectBuffer.pick
        // (the picker handles its own cache + VBO→cage translation).
        // Task 0617: `mesh`/`vp` here are the PRIMARY layer's — pair with
        // primaryModelSpace() so a transformed primary is picked where it's
        // drawn, not at its identity pose.
        // Selection visibility (`select_visibility.d`), resolved for the cell
        // whose ID buffer this is: under a style that draws no faces the
        // picker stops running its face depth pre-pass, so a vertex or edge
        // behind the surface keeps its id and can be picked. One code path for
        // hover, click and paint (`doSelectPickAt` calls this same function),
        // so all three follow the style together.
        //
        // NO FACING TERM HERE, ever: `pickVisibility().facingTerm` is resolved
        // and deliberately not read on this path — it is MEASURED to have
        // none (`CLAUDE.md` §Measured laws).
        int hit = app.gpuSelect.pick(sm, mx, my, radius, app.mesh, app.gpu, vp,
                                 primaryModelSpace(),
                                 app.vpm.pickVisibility().occlusionTerm);
        if (hit < 0) return;

        hovered = hit;
        if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
            symSel(&app.mesh(), vp, app.editMode, hovered, /*deselect=*/false);
        else if (dragMode == DragMode.SelectRemove)
            symSel(&app.mesh(), vp, app.editMode, hovered, /*deselect=*/true);
    }
    alias pickVertices = pickHover!(SelectMode.Vertex, EditMode.Vertices,
                                    symmetricSelectVertex, 4);
    alias pickEdges    = pickHover!(SelectMode.Edge,   EditMode.Edges,
                                    symmetricSelectEdge,   6);

    void pickFaces(ref Viewport vp, bool doingCameraDrag) {
        // Mid-batch pull-guard — covers BOTH engines: the GPU path reads the
        // ID-FBO rendered from the VBO, and the BVH path is keyed on
        // gpu.uploadVersion, so the guard's upload is what triggers its
        // rebuild against the post-mutation mesh.
        app.ensureDisplayCurrent();
        // Task 1730 — freeze while the drawn surface and the cage disagree.
        // Under option C (task 1540) this picker answers from the ID buffer
        // whenever a preview is `active`, so it is a `*OriginGpu` reader like
        // the two above. It is frozen even on the BVH branch, which reads no
        // GPU buffer at all: that branch would answer against the CAGE while
        // the LIMIT surface is what is on screen, i.e. pick geometry the user
        // cannot see. A held answer beats a confidently wrong one.
        if (previewIndexSpaceStale()) return;
        if (app.activeTool !is null && app.activeTool.isDragging()) return;  // freeze hover mid-drag
        hoveredFace = -1;
        if (!viewportInputAllowed() || doingCameraDrag) return;
        // The face twin of the gate in `pickHover` — same query, same reason
        // (task 0655).
        if (app.activeTool is null) {
            if (viewportPickType(app.selTypeOrder) != SelType.Polygon) return;
        } else {
            if (!app.activeTool.wantsHoverForType(EditMode.Polygons)) return;
        }

        int mx, my;
        queryMouse(mx, my);

        // BVH ray-cast (default) or GPU face re-render (VIBE3D_FACE_PICK=gpu).
        // BVH: O(log n) per pick, view-independent, no GL readback. Keyed on
        // (gpu.uploadVersion, source-mesh-address) — identical to gpu_select.d:31.
        // Task 0617: both engines pick against the PRIMARY layer here —
        // primaryModelSpace() for both, so the BVH/GPU A/B stays apples-to-apples.
        //
        // TASK 1540 — WHILE A SUBPATCH PREVIEW IS LIVE, THE ENGINE IS THE GPU
        // ONE, AND THAT IS A PERF DECISION MADE ON A MEASUREMENT.
        //
        // The BVH is keyed on (gpu.uploadVersion, source-mesh address), and
        // under a live preview the source is the LIMIT surface — four times
        // the cage at level 1. Installing a fresh preview moves both key
        // terms, so the very next hover pick pays a full construction over
        // that surface. Measured, grid n=316 (99 856 cage quads -> 798 848
        // limit triangles), `frames --n 316 tab-cold`:
        //
        //     worst frame  BVH engine 1719.6 ms   GPU engine 125.0 ms
        //     `cache` phase   1588.9 ms              0.072 ms
        //
        // and the 1588.9 ms IS one `dbvh_build` — it and the phase agree to
        // four microseconds. So on the frame a preview lands, the structure
        // that exists to make picking cheap is what makes the window freeze.
        //
        // WHY THE GATE IS `active` AND NOT `active || buildPending`. While a
        // build is in flight the VBOs still hold the CAGE, so the cage tree is
        // both correct and the thing being drawn — and it is a quarter the
        // size. Gating on `buildPending` too would ALSO make the engine a
        // function of whether a worker thread had finished, i.e. of wall
        // clock, and selection under scripted input would stop being
        // reproducible. `active` is document state; this branch is
        // deterministic.
        //
        // WHAT MAKES THIS SAFE is that the two engines are held equivalent by
        // a test, not by intent: `tests/test_bvh_pick_equivalence.d` sweeps
        // (fixture, camera, pixel) and includes a subpatch-preview fixture.
        // Both engines answer in CAGE face indices — the GPU one translates
        // through `gpu.faceOriginGpu` after readback (gpu_select.d), the BVH
        // one folds the same map into `_triToFace` at build time
        // (bvh_pick.d). The documented exemption is exactly-coincident /
        // coplanar faces, where GPU draw order and nanort's arbitrary `t`
        // may disagree.
        //
        // WHAT IT COSTS: ~143 us per pick against ~0.8 us, and a full ID
        // re-render whenever the camera moves (the GPU slot key carries view
        // and proj). Both are bounded — this branch is only taken while a
        // preview is live, and `pickFaces` returns above during a camera
        // drag, so the re-render is one per camera settle rather than one per
        // frame. `/api/pick?engine=bvh` is UNCHANGED and still reaches the
        // BVH directly, so the oracle that proves the equivalence above does
        // not route through this decision.
        int hit;
        if (useBvhFacePick && !app.subpatchPreview.active) {
            hit = app.bvhPick.pickFace(mx, my, vp, app.mesh(), app.gpu, primaryModelSpace());
        } else {
            // The term is inert for `SelectMode.Face` by construction (the
            // face pass IS the surface, so no pre-pass ever ran for it) — it
            // is passed rather than hardcoded so this call site does not
            // become the one place that pins a policy of its own if the face
            // path ever grows a through-mode.
            hit = app.gpuSelect.pick(SelectMode.Face, mx, my, /*r=*/0,
                                  app.mesh, app.gpu, vp, primaryModelSpace(),
                                  app.vpm.pickVisibility().occlusionTerm);
        }
        if (hit < 0) return;

        hoveredFace = hit;
        if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
            symmetricSelectFace(&app.mesh(), vp, app.editMode,
                                hoveredFace, /*deselect=*/false);
        else if (dragMode == DragMode.SelectRemove)
            symmetricSelectFace(&app.mesh(), vp, app.editMode,
                                hoveredFace, /*deselect=*/true);
    }

    // Which ITEM is under the cursor (task 0647). Runs only while the current
    // selection type is Item — that is the whole gate, and it is the same gate
    // the highlight pass reads.
    //
    // WHY IT IS NOT `pickHover` WITH A FOURTH MODE. The three element pickers
    // share a body because they differ only in a SelectMode/EditMode pair and a
    // radius; this one differs in every part that matters. It ranges over the
    // layer array rather than the primary's elements, it uses a CPU ray rather
    // than the GPU ID buffer (the ID buffer is rendered from the primary's VBO
    // alone, so it cannot see another layer at all), and its answer is a
    // document index rather than an element index.
    //
    // THE CLEAR COMES BEFORE EVERY EARLY RETURN BUT ONE, so that "the cursor
    // moved off the item" and "the cursor moved onto empty space" are the same,
    // non-latching state — measured: returning to a parking pixel restored a
    // zero-difference frame every time, so nothing here may hold the previous
    // answer.
    //
    // The one exception is a live DRAG, which freezes the hover exactly as the
    // element pickers freeze theirs: the item the gesture started on is the one
    // it must keep for its whole duration. That freeze is itself conditional on
    // Item still being the current type — a type flip during a drag must not
    // leave a stale item index visible to `/api/layers`.
    //
    // Declared ABOVE `pickItems` because a nested function is not visible
    // before its definition: `pickItems` calls it.
    //
    // The item ray, with the ACTIVE cell's projection identity attached
    // (task 0643). An image plane is drawn only in the cell whose preset it
    // names, so "which item is under this pixel" is not answerable without the
    // cell — and the hover path and the click path must ask it the same way,
    // which is why this is one function rather than two call sites that each
    // remember to pass the pair. `vp` is the active cell's snapshot at both,
    // so `activeCamera()` is the camera it was taken from.
    ItemHit pickItemUnderCursor(int mx, int my, ref Viewport vp) {
        import view : ProjKind;
        return itemPicker.pickItemAt(app.document, mx, my, vp,
                                     app.vpm.activeCamera().viewPreset,
                                     app.vpm.activeCamera().projKind == ProjKind.Ortho);
    }

    void pickItems(ref Viewport vp, bool doingCameraDrag) {
        import hover_state : g_hoveredItem;
        immutable bool isItem = currentSelType(app.selTypeOrder) == SelType.Item;
        if (isItem && app.activeTool !is null && app.activeTool.isDragging()) return;
        g_hoveredItem = -1;
        if (!isItem) return;
        if (!viewportInputAllowed() || doingCameraDrag) return;

        int mx, my;
        queryMouse(mx, my);
        immutable ItemHit h = pickItemUnderCursor(mx, my, vp);
        if (h.hit) g_hoveredItem = h.layerIndex;
    }
}
