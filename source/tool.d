module tool;

import bindbc.sdl;
import bindbc.opengl;

import math;
import shader;
import params : Param, ParamProvider;
import editmode : EditMode;
import operator : VectorStack;
import std.json : JSONValue;
import tool_input : ToolAction, PassThrough, InputPhase, InputButton, InputMod,
                    ResetScope, InputBinding, resolveToolAction, resolveResetScope;

// ---------------------------------------------------------------------------
// Tool flags — tool-level behaviour bits. The enum carries two kinds of bit:
//
//  1. Preset-applied bits. Presets opt in by listing the names under a
//     `flags:` block in `config/tool_presets.yaml`; the preset loader ORs
//     them into the freshly-constructed Tool's `presetFlags`. Tools query
//     `hasFlag(ToolFlag.X)` to fork on behaviour without duplicating preset
//     state in their own classes.
//       - `Immediate`  : deactivate on mouse-up (one-shot tool, no further
//                        edits in the same session). Not yet consumed here.
//       - `BrushReset` : reset the edit baseline between strokes. Used by
//                        `xfrm.softDrag` so each LMB drag commits to history
//                        and the next click starts a fresh weighted pull
//                        from the new grab point (instead of accumulating
//                        onto the original baseline and rubber-banding back).
//
//  2. Static capability bits. A tool class declares the constant capabilities
//     it always has by overriding `flags()` to return them. The base
//     predicate `wantsHoverForType` derives from these bits, so a tool whose
//     capability is fixed need only list a flag rather than override a
//     method. Tools whose capability is computed at runtime keep overriding
//     the predicate method instead.
//       - `HoverVertices`  : wants vertex hover-highlight while active.
//       - `HoverEdges`     : wants edge hover-highlight while active.
//       - `HoverPolygons`  : wants polygon hover-highlight while active.
// ---------------------------------------------------------------------------
enum ToolFlag : uint {
    None          = 0,
    // Preset-applied bits.
    Immediate     = 1u << 0,
    BrushReset    = 1u << 1,
    // Static capability bits. (Bit 2 was NeedsFalloff — retired with the
    // dead consumesFalloff chain, task 0428; falloff weighting flows through
    // the WGHT packet into the transform kernels instead.)
    HoverVertices = 1u << 3,
    HoverEdges    = 1u << 4,
    HoverPolygons = 1u << 5,
}

// ---------------------------------------------------------------------------
// Tool — base class for all editing tools.
//
// The base owns four surfaces (task 0428 boundary):
//   * INPUT + RENDER — activate/deactivate/update, the onMouse*/onKey*
//     dispatch hooks, draw()/drawProperties().
//   * PARAMS — the ParamProvider schema (params/onParamChanged/paramEnabled/
//     evaluate/renderParamsAsPanel) driving the Tool Properties panel and the
//     headless tool.attr path.
//   * PIPE CAPABILITIES + INTROSPECTION — flags()/hover opt-ins/isDragging/
//     toolHandlesJson/toolStateJson/applyHeadless/supportedModes.
//   * The WIDE SESSION CONTRACT — hasUncommittedEdit / cancelUncommittedEdit
//     / resyncSession (see their block below).
//
// The session PROTOCOL (who calls those hooks, in what order — history
// navigation, refire, live re-eval, lifecycle-undo emit) lives in
// edit_session.d: EditSession is the sole driver, and the narrow per-tool
// opt-ins are its optional capability interfaces (LiveEvalClient,
// RefireClient, KeepAliveOnCancel, SessionStepUndo, LifecycleUndoEmitter),
// discovered by cast on the active tool.
// ---------------------------------------------------------------------------

class Tool : ParamProvider {
    // Set true only while an interactive property write is notifying the
    // tool, and left false on the headless `tool.attr` path. Tools that build live
    // geometry on a param change (e.g. EdgeExtrudeTool) gate their preview
    // rebuild on this so the headless flow's ToolDoApplyCommand pre-snapshot
    // stays clean — the headless apply is owned solely by applyHeadless().
    bool interactiveParamEdit = false;

    // Deliver one interactive parameter notification.  This is deliberately
    // narrower than the raw `tool.attr` path: callers must have established
    // that their write originated in an interactive control first.
    //
    // `final` since task 0705: it is a fixed wrapper around `onParamChanged`
    // — set the flag, delegate, restore — and had zero overriders. It was
    // virtual only by omission, and that omission was the audit's off-by-one
    // (33 counted, 34 present).
    final void notifyInteractiveParamChanged(string name) {
        bool wasInteractive = interactiveParamEdit;
        interactiveParamEdit = true;
        scope(exit) interactiveParamEdit = wasInteractive;
        onParamChanged(name);
    }

    // Preset-applied behaviour bits — see `ToolFlag`. The preset
    // loader writes this on the freshly-constructed tool before
    // activation. Tools query via `hasFlag` rather than reading the
    // mask directly so the bit names stay enforced by the type.
    uint presetFlags = 0;

    final bool hasFlag(ToolFlag f) const {
        return (presetFlags & cast(uint)f) != 0;
    }

    // Static capability bits for this tool class. Override to return the
    // OR of the constant capabilities the tool always has
    // (HoverVertices/Edges/Polygons). The base capability predicates below
    // derive from these. Tools whose capability is computed at runtime
    // (e.g. hover that depends on the active falloff stage) leave this be
    // and override the predicate method instead.
    ToolFlag flags() const { return ToolFlag.None; }

    final bool hasCapability(ToolFlag f) const {
        return (cast(uint)flags() & cast(uint)f) != 0;
    }

    // Human-readable name shown in the UI.
    string name() const { return "Tool"; }

    // Called when the tool becomes the active tool.
    void activate() {}

    // Called when another tool becomes active.
    void deactivate() {}

    // Called once per frame to recompute tool state (e.g. gizmo
    // position). Receives the dispatcher-built vts so any toolpipe
    // reads stay coherent with the one the input handlers and draw()
    // see this frame.
    void update(ref VectorStack vts) {}

    // SDL event handlers — Phase 7 of doc/operator_refactor_plan.md.
    // The dispatcher (app.d's main event loop) builds a VectorStack
    // once per input event, walks the live toolpipe, and passes the
    // populated vts down to the Tool. Tools read upstream packets via
    // `vts.get!T()` — they MUST NOT call pipeline.evaluate themselves.
    // Each handler takes `vts` as a parameter. Return true to mark the
    // event consumed.
    bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) { return false; }
    bool onMouseButtonUp  (ref const SDL_MouseButtonEvent e, ref VectorStack vts) { return false; }
    bool onMouseMotion    (ref const SDL_MouseMotionEvent  e, ref VectorStack vts) { return false; }
    bool onKeyDown        (ref const SDL_KeyboardEvent     e, ref VectorStack vts) { return false; }
    bool onKeyUp          (ref const SDL_KeyboardEvent     e, ref VectorStack vts) { return false; }

    // ----- Centralized tool-input / modifier dispatch
    // (doc/tool_input_dispatch_design.md) ------------------------------------
    //
    // A shared alternative to hand-rolling a button x modifier grid inside a
    // tool: a tool DECLARES its (button, modifier) -> action table instead of
    // writing its own DOWN-side classifier, and implements one action handler
    // instead of an UP-side arm-flag cascade. `dispatchInput()` below is the
    // shared per-button state machine every opted-in tool reuses.
    //
    // The three hooks that seam needs live on `InputBindable` (below this
    // class), NOT on `Tool`. Task 0705 (audit 4, T6) moved them: one tool of
    // the ~43 in the build implements them, and three base virtuals carried
    // for one implementor is exactly the "zoo of hooks" the 0428 moratorium
    // was written against. `dispatchInput` resolves the capability with one
    // `cast` and answers `false` for a tool that does not implement it —
    // which is byte-identical to the old defaults (an empty `bindings()`
    // made every phase return `false` without ever calling the other two).

    // One armed `ToolAction` slot per physical button (`InputButton.Left`/
    // `Middle`/`Right`), set at Down and read back (then cleared) at Up.
    // Tracking arming PER BUTTON — instead of one shared set of flags — is
    // what makes a chord on one button structurally unable to clear a
    // gesture in progress on a different button.
    private ToolAction[3] armed_ = [PassThrough, PassThrough, PassThrough];

    /// Drops EVERY button's armed action (`armed_[] = PassThrough`) in one
    /// call — distinct from `ResetScope` above, which only ever (re)arms the
    /// SAME button `dispatchInput` is processing this Down on and never
    /// touches another button's slot. This is the seam an external resync
    /// trigger (e.g. an undo/redo that invalidates cached vertex/edge
    /// indices) needs to cancel every gesture in flight regardless of which
    /// button it is armed on — `armed_` is otherwise module-private, so
    /// nothing outside `dispatchInput` itself could reach it before this
    /// existed. Does NOT call `onInputResetAll()` — a caller that needs both
    /// (clear the tool's own seed state AND drop every arm) calls both
    /// explicitly; they are separate primitives.
    protected final void resetAllArmed() {
        armed_[] = PassThrough;
    }

    /// The central per-button dispatcher: resolves+arms on Down, routes to
    /// the armed action (then clears it) on Up, and forwards Move to
    /// whatever is currently armed on `button` (or declines if nothing is).
    /// `button`/`mods` are already the neutral `InputButton`/`InputMod`-mask
    /// forms (`tool_input.toButton`/`toMods` convert from raw SDL at the
    /// call site); `e`/`vts` pass through untouched to `onToolAction`.
    final bool dispatchInput(InputButton button, ubyte mods, InputPhase phase,
                              ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        // A physical button with no neutral mapping — a 4th/5th mouse button
        // that `toButton()` reports as `InputButton.None` — binds to no row and
        // must never index `armed_[]` (sized for Left/Middle/Right only; the
        // Up/Move cases below read `armed_[button]` UNCONDITIONALLY before the
        // PassThrough check, so an out-of-range index here would be a buffer
        // overread). Decline it outright: identical to a tool whose table lists
        // no row for the button, and to the pre-dispatch behavior where such
        // buttons were ignored.
        if (button == InputButton.None) return false;
        // The capability, resolved ONCE per dispatch. A tool that does not
        // implement `InputBindable` has no table, so nothing can resolve to
        // anything but `PassThrough` and nothing can be armed — the same
        // answer the empty-`bindings()` default used to produce, reached
        // without three virtual slots on the base.
        auto ib = cast(InputBindable) this;
        if (ib is null) return false;
        final switch (phase) {
        case InputPhase.Down: {
            // bindings() scanned ONCE and shared by both resolvers below —
            // a migrated tool returning an array literal would otherwise
            // allocate twice per Down for no reason (NIT-2).
            auto table = ib.bindings();
            auto a = resolveToolAction(table, button, mods);
            if (a == PassThrough) return false;
            if (resolveResetScope(table, button, mods) == ResetScope.AllButtons)
                ib.onInputResetAll();
            armed_[button] = a;
            return ib.onToolAction(a, InputPhase.Down, e, vts);
        }
        case InputPhase.Up: {
            auto a = armed_[button];
            if (a == PassThrough) return false;
            armed_[button] = PassThrough;
            return ib.onToolAction(a, InputPhase.Up, e, vts);
        }
        case InputPhase.Move: {
            auto a = armed_[button];
            if (a == PassThrough) return false;
            return ib.onToolAction(a, InputPhase.Move, e, vts);
        }
        }
    }

    // Called once per frame after the 3-D geometry has been drawn.
    // Receives the freshly-evaluated toolpipe vts; override to render
    // overlays (gizmos, falloff overlay, snap highlights, etc.).
    //
    // `visualOnly` (task 0206, Quad/Split multi-cell overlays): true when
    // this draw is a NON-interactive replica in a viewport cell OTHER than
    // the active/origin one. World-derived geometry (handler.draw, the
    // falloff gizmo, drawSnapOverlay/drawFalloffOverlay) still renders
    // reprojected under `vp` — that's what makes the same gizmo appear
    // correctly in every Quad cell. What MUST be skipped under
    // `visualOnly` is anything that writes INTERACTION state read by this
    // tool's event handlers under a FOREIGN cell's projection: `cachedVp`
    // writes and any ToolHandles register/hit-test (`begin`/`add`/
    // `update`) cycle. See XfrmTransformTool.draw + the Move/Rotate/Scale
    // sub-tool draw()s for the gated sites. Default false ⇒ every existing
    // call site (single-cell / `--test`) is byte-identical.
    void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {}

    // Called inside the floating "Tool Properties" ImGui window.
    // Override to show/edit tool-specific properties.
    void drawProperties() {}

    // Schema: list of parameters. Default: none. Tools that surface a
    // numeric properties panel override this.
    Param[] params() { return []; }

    // Called after a parameter value changes. Tools override to drive
    // their preview re-evaluation.
    void onParamChanged(string name) {}

    // Whether the named parameter widget should be enabled.
    bool paramEnabled(string name) const { return true; }

    // Per-element-type hover opt-in. Tools override to declare which
    // element types they want pickVertices / pickEdges / pickFaces to
    // run (and the renderer to highlight) while they're active.
    // Defaults to `false` — most tools (Move / Rotate / Scale / Bevel /
    // primitive-create) own LMB completely and skip hover entirely.
    // XfrmTransformTool returns `true` for the types matching the
    // active FalloffStage's `elementMode` when falloff.element is
    // wired (Auto → all three, vertex → only Vertices, etc.).
    // The base derives the answer from the static Hover* capability
    // bits; tools with a fixed hover set just declare the flags, while
    // tools whose hover depends on runtime state override this method.
    bool wantsHoverForType(EditMode type) const {
        final switch (type) {
            case EditMode.Vertices: return hasCapability(ToolFlag.HoverVertices);
            case EditMode.Edges:    return hasCapability(ToolFlag.HoverEdges);
            case EditMode.Polygons: return hasCapability(ToolFlag.HoverPolygons);
        }
    }

    // True while the tool owns an in-progress drag gesture (a gizmo / element
    // haul between mouse-down and mouse-up). The host uses this to FREEZE the
    // hover pick during the drag — so only the element picked at drag-start
    // stays highlighted, instead of every element the moving cursor passes
    // over lighting up. Default false; XfrmTransformTool overrides it.
    bool isDragging() const { return false; }

    // Pre-highlight the WHOLE edge loop under the cursor (not just the single
    // hovered edge). True only when an Element falloff is active in EdgeLoops
    // connect mode — the apply already expands a picked edge to its loop ring,
    // so the hover preview matches. Default false; XfrmTransformTool overrides
    // it. The renderer reads this to decide whether to compute + draw the
    // loop-edge mask (see source/app.d's edge-hover branch).
    bool wantsEdgeLoopHover() const { return false; }

    // When wantsEdgeLoopHover() is true, choose WHICH ring the hover mask
    // pre-highlights:
    //   false (default) — the classic edge LOOP through the hovered edge
    //     (edgeLoopRing), matching ElementMove / EdgeLoops-falloff whose apply
    //     expands the picked edge to its loop.
    //   true — the loop-SLICE ring: the seed edge plus every quad-ring exit
    //     rail that a loop cut would actually split (Mesh.loopSliceRingEdges).
    //     These run PERPENDICULAR to the edge loop, so a slice tool must use
    //     this or the highlighted ring won't match the cut. LoopSliceTool
    //     overrides it.
    bool edgeLoopHoverSliceRing() const { return false; }

    // Test-introspection hook (task 0234, GET /api/tool/handles): serialize
    // this tool's ToolHandles registry (part id / hover-state / visibility /
    // screen anchor per handle, plus the shared hot/captured part) so tests
    // can press a handle by data instead of reconstructing gizmo geometry.
    // Default `null` — tools with no handle arbiter (most non-transform
    // tools) report no handles; the HTTP provider wraps this under a
    // top-level `{"handles": ...}` key regardless. XfrmTransformTool
    // overrides this to wrap its shared `toolHandles.toJson(cachedVp)`.
    JSONValue toolHandlesJson() const { return JSONValue(null); }

    // Test-introspection hook (task 0234, GET /api/tool/state): per-tool
    // transient-state dump (active bank, drag axis, hover/latch state, etc.)
    // for tests that need to assert something other than final geometry.
    // Default empty object; XfrmTransformTool + LoopSliceTool override it.
    JSONValue toolStateJson() const { return JSONValue.emptyObject; }

    // Re-apply the tool's preview after a parameter change. Default
    // no-op (tools without params don't need this).
    void evaluate() {}

    // Apply tool one-shot (headless / scripted path). Default no-op returns
    // false. Implementations run business logic with current attribute
    // state — they MUST NOT snapshot themselves; the caller (eventual
    // ToolHeadlessCommand in phase 4.4) wraps with snapshot pair for undo.
    //
    // Currently unused; renderer in phase 4.4+ will start dispatching to it.
    bool applyHeadless() { return false; }

    // ----- Session contract (wide per-tool hooks) --------------------------
    //
    // hasUncommittedEdit / cancelUncommittedEdit / resyncSession are the
    // per-tool session contract: genuinely polymorphic (~30 interactive
    // overriders each), so they stay virtuals on the base. Their DRIVER is
    // EditSession (edit_session.d) exclusively — the only exception is two
    // documented READ-ONLY render gates in ui/panels.d (the held-drag
    // sub-window suppression) that consult hasUncommittedEdit() without
    // driving the protocol. The NARROW session hooks (standing-preview
    // redo/cancel shape, per-step in-session undo peel, refire, live
    // re-eval, lifecycle-undo emit) live as optional capability interfaces
    // in edit_session.d, discovered by cast.
    //
    // INVARIANT: hasUncommittedEdit() <=> a commit would fire if the tool's
    // session ended *right now*. This is deliberately NOT "state != Idle" and
    // NOT a single bool reused by every tool — it must equal the tool's REAL
    // commit guard, including any epsilon terms (e.g. a primitive whose height
    // is sub-epsilon has a live state but would commit nothing, so it must
    // return false). Each interactive tool overrides this to mirror the exact
    // predicate its deactivate()/commit path tests.
    bool hasUncommittedEdit() const { return false; }

    // Step the tool's open live edit BACK toward the session baseline WITHOUT
    // recording anything new to history. Contract (measured, 0428): this is
    // NOT guaranteed one-shot — the primitive live-run family pops ONE
    // recorded live step per call (the interactive undo ladder) and may
    // legitimately still report hasUncommittedEdit()==true afterwards; other
    // tools cancel fully in one call. The driver (EditSession.navigate)
    // re-reads hasUncommittedEdit() after every call and either steps again
    // on the next navigate or falls through to the drop branch — do NOT
    // assert the one-shot postcondition. Cancel bodies are heterogeneous
    // (live-mesh restore / preview-only reset / transform-cancel code) —
    // this is not uniformly "reuse the RMB handler".
    void cancelUncommittedEdit() {}

    // The cancel-survival shape (task 0400 — survivesEditCancel) and the
    // mid-session per-step undo peel (task 0321 — tryUndoStepInSession)
    // moved to the optional KeepAliveOnCancel / SessionStepUndo interfaces
    // in edit_session.d (task 0428). A tool not implementing them keeps the
    // former base defaults (cancel-then-drop; no per-step peel) — but note
    // the cancel-then-drop default no longer covers the create family:
    // PrimitiveCreateTool and BoxTool implement KeepAliveOnCancel (task
    // 0430). The redo direction never cancels an open edit for ANY tool: a
    // standing preview's write-points invalidate the redo timeline instead
    // (task 0429), so the former redo-cancel hook is gone.

    // Re-sync the tool's cached pre-edit baseline / gizmo to the CURRENT mesh
    // after history navigation moved geometry underneath an active tool. P0
    // ships a minimal stub (default no-op; transform marks its caches dirty,
    // EdgeExtrude re-captures its `before` snapshot). Promoted to a first-class
    // post-mode re-init in P1.
    void resyncSession() {}

    // Framework "apply and continue" (Shift+click on a creation/interactive-
    // edit tool, task 0461 — the reference editor's apply-and-continue
    // gesture). Finalize the tool's CURRENT open edit as its own permanent
    // undo entry WITHOUT dropping the tool, so the caller can then re-arm the
    // SAME session in place via resyncSession() — structurally commit-into-
    // history then re-arm-in-place, never a deactivate/reactivate (ACEN/AXIS/
    // pipe state persist).
    //
    // Returns true if it committed a discrete undo entry (⇒ the driver
    // re-arms). Default false — the tool opts OUT of in-place apply, and the
    // driver then LEAVES the open edit untouched (never re-arms on a no-op
    // commit, so a still-open edit is never silently discarded). Transform
    // tools that already commit per gesture (record+consolidate) keep the
    // default: they have nothing extra to finalize here. Only interactive
    // create/edit tools that hold a STANDING uncommitted edit
    // (hasUncommittedEdit()==true across frames) override this to record
    // that edit; the invariant is postcondition hasUncommittedEdit()==true
    // BEFORE and, after the driver's follow-up resyncSession(), ==false.
    bool commitUncommittedEdit() { return false; }

    // Refire (record-once, re-evaluate panel-edit sessions, undo/redo
    // migration P4) moved to the optional RefireClient interface in
    // edit_session.d (task 0428) — wantsRefire / buildRefireCommand /
    // setRefireDriving / onRefireCommitted. A tool not implementing the
    // interface keeps its onParamChanged() preview behaviour unchanged and
    // is never routed through refire.

    // Live re-evaluation (attr / pipe-stage edits re-running a live tool)
    // moved to the optional LiveEvalClient interface in edit_session.d
    // (task 0428) — hasLiveEval / hasLiveAttrEval / reEvaluate. A tool not
    // implementing the interface keeps the former base defaults (no live
    // session, re-eval a no-op).

    // Whether `params()` should be rendered by the inline PropertyPanel.
    // Tools that expose params() purely for the headless tool.attr path,
    // while drawProperties() handles the interactive UI (e.g. BevelTool
    // edge-mode), override this to false and let drawProperties() own
    // rendering — preventing duplicate widgets.
    bool renderParamsAsPanel() const { return true; }

    // Lifecycle-undo emit opt-in (ToolDeactivationCommand on drop) moved to
    // the LifecycleUndoEmitter marker interface in edit_session.d (task
    // 0428).

    // Edit modes in which this tool makes sense. Side-panel /
    // status-bar buttons auto-disable when the current edit mode is
    // not in this list. Default: every mode (most tools are mode-
    // agnostic — Move / Rotate / Scale operate on whatever the
    // current selection projects to). Specialised tools (BevelTool
    // only meaningful on edges, etc.) override.
    EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    // TASK 0669 — does ARMING this tool require a mesh edit target?
    //
    // The tool half of `Command.needsEditTarget()`, and the reason the
    // button's grey and the arm's refusal cannot disagree: `activateToolById`
    // and the button-draw resolve availability through the SAME answer
    // (`Registry.actionRefusal`), which reads this.
    //
    // TRUE for every tool in the build today — a tool binds `Mesh*` off the
    // edit target when it arms, and with an empty item selection there is
    // none, which is what 0654's arming refusal says. It is a method rather
    // than a constant so a future tool that touches no mesh (a camera or
    // measurement tool) declares itself once and BOTH sites follow; the
    // snapshot rule of `Command.needsEditTarget()` applies here too (cached
    // per id off a cold instance in `Registry.cacheSupportedModes`).
    bool needsEditTarget() const { return true; }
}

// ---------------------------------------------------------------------------
// InputBindable — the declarative input-dispatch capability (task 0705, T6).
//
// A tool that wants `Tool.dispatchInput`'s per-button state machine implements
// this; every other tool does not mention it and is unaffected. These three
// were base-class virtuals until task 0705 with ONE implementor between them
// out of ~43 tools in the build, which is precisely the shape task 0428's
// moratorium named ("новый одно-тульный хук допускается только с записанным
// инвариант-тестом" — no invariant test was ever written, and the surface grew
// 28 -> 34 anyway).
//
// The downgrade is free of call-site churn because all five dispatch points
// live inside `dispatchInput`, which is `final`: one `cast` there replaces
// three virtual slots on every tool in the program. Behaviour is unchanged —
// a tool that does not implement this reaches `dispatchInput`'s `ib is null`
// arm, which returns `false` exactly as the empty-`bindings()` default did in
// all three phases.
//
// Precedent: the five session capabilities in `edit_session.d`
// (LiveEvalClient / RefireClient / KeepAliveOnCancel / SessionStepUndo /
// LifecycleUndoEmitter), all discovered the same way.
// ---------------------------------------------------------------------------
interface InputBindable {
    /// Declarative (button, exact modifier combo) -> `ToolAction` table.
    const(InputBinding)[] bindings() const;

    /// Deliver one resolved action at one phase. DOWN and UP for the SAME
    /// gesture arrive with the SAME `a` (the id `dispatchInput` armed on
    /// Down) — never re-derived from which of several bool flags happens to
    /// be set, so a tool's `final switch (a)` here cannot have one case's
    /// early return silently shadow another's.
    bool onToolAction(ToolAction a, InputPhase p,
                      ref const SDL_MouseButtonEvent e, ref VectorStack vts);

    /// Hook fired when a binding row declares `ResetScope.AllButtons` (and by
    /// tools that also wire it to external history navigation moving the mesh
    /// out from under an open gesture): clears whatever per-gesture SEED state
    /// the tool itself keeps (e.g. a cached start-vertex index).
    ///
    /// This does NOT clear any button's `armed_` slot — `dispatchInput` never
    /// clears a DIFFERENT button's armed action from here, only ever (re)arms
    /// the SAME button it is processing this Down on. That per-button
    /// isolation is REQUIRED for the two-button-chord property and holds
    /// regardless of which `ResetScope` fired this hook. To drop EVERY
    /// button's armed action in one call, use `Tool.resetAllArmed()`; it is a
    /// distinct primitive, not something this hook should do.
    void onInputResetAll();
}

// ---------------------------------------------------------------------------
// THE MORATORIUM, as a build error (task 0705, T6).
//
// Task 0428 cut `Tool`'s virtual surface 44 -> 28 and wrote down a moratorium:
// a new one-tool hook is admissible "only with a recorded invariant test". No
// such test was written, the rule lived only in a `done/` task file, and the
// surface grew back to 34 — six additions, none of which honoured the clause
// that admitted them. A rule with no mechanism is a rule that measures nothing.
//
// The list below is that mechanism. It is a hand-written whitelist ON PURPOSE:
// the point is not to describe the class (the compiler can already do that,
// which is what `toolVirtuals` does) but to make GROWING it an explicit,
// reviewable edit. Deriving both sides would assert nothing.
//
// Adding a virtual to `Tool` now fails the BUILD with the message below.
// Before you add a name here, check the alternative: if fewer than about three
// tools will override it, it belongs on a capability interface (see
// `InputBindable` above and the five in `edit_session.d`), not on the base.
// ---------------------------------------------------------------------------
private enum string[] kToolVirtualWhitelist = [
    // Wide contracts — dozens of overriders each. These are what a base class
    // is for.
    "name", "activate", "deactivate", "update",
    "onMouseButtonDown", "onMouseButtonUp", "onMouseMotion",
    "draw", "drawProperties",
    "params", "onParamChanged", "paramEnabled",
    "evaluate", "applyHeadless", "supportedModes",
    "toolHandlesJson", "toolStateJson",
    // The wide SESSION contract (task 0428) — ~30 overriders each.
    "hasUncommittedEdit", "cancelUncommittedEdit", "resyncSession",
    "commitUncommittedEdit",
    // Middling — 4 to 8 overriders. Fine on the base; listed so the next
    // reader can see where the line currently sits.
    "flags", "isDragging", "onKeyDown",
    // NARROW, and each one is a standing question rather than a settled
    // answer. They are on the base today because moving them costs call-site
    // churn that task 0705 judged not worth spending in a hygiene wave:
    //   onKeyUp                 1 overrider. Task 0709 gave it the dispatch
    //                                          site it had never had (`app.d`
    //                                          grew a `case SDL_KEYUP`); until
    //                                          then the one overrider's body
    //                                          was unreachable and its flag
    //                                          latched. Narrow now, not broken.
    //
    // Task 0709 also re-ran the "which of these has NO caller" sweep over the
    // whole list, since a virtual whose overriders never run is invisible to
    // the compiler and `onKeyUp` had hidden in here for months. `onKeyUp` was
    // the ONLY one. The near miss worth naming so it is not re-reported: `name`
    // sits in the wide bucket above on 48 overriders, but it has exactly ONE
    // call site in the tree — `tool_presets.applyToolAttrs`, building the text
    // of an "unknown attr" exception. Dozens of overriders serving one cold
    // error message is a different smell from this list's, and not a bug.
    //   wantsHoverForType       1 runtime overrider, but its BASE body is real
    //                                          logic over the ToolFlag.Hover*
    //                                          bits four tools set, and it is
    //                                          read on the per-frame hover
    //                                          path from 9 sites.
    //   wantsEdgeLoopHover      2 overriders, 3 per-frame call sites.
    //   edgeLoopHoverSliceRing  1 overrider.
    //   renderParamsAsPanel     1 overrider, 1 cold site.
    //   needsEditTarget         0 Tool overriders; its own doc admits it is
    //                                          "TRUE for every tool in the
    //                                          build today". Read once and
    //                                          cached at registration.
    "onKeyUp", "wantsHoverForType", "wantsEdgeLoopHover",
    "edgeLoopHoverSliceRing", "renderParamsAsPanel", "needsEditTarget",
];

/// Every virtual (overridable) method `Tool` declares, in declaration order,
/// derived by the compiler. `final`, `static` and `private` members are not
/// virtual and do not appear; a name with several overloads appears once.
private enum string[] toolVirtuals = () {
    string[] r;
    static foreach (m; __traits(derivedMembers, Tool)) {
        static if (__traits(compiles, __traits(getOverloads, Tool, m))) {
            static foreach (ov; __traits(getOverloads, Tool, m)) {
                static if (__traits(isVirtualMethod, ov)) {
                    {
                        bool seen = false;
                        foreach (x; r) if (x == m) seen = true;
                        if (!seen) r ~= m;
                    }
                }
            }
        }
    }
    return r;
}();


// ---------------------------------------------------------------------------
// Centralized tool-input dispatch — Tool-base seam tests (Phase 1, ADDITIVE +
// INERT, doc/tool_input_dispatch_design.md). No SDL runtime call, no GL, no
// live vibe3d instance: `SDL_MouseButtonEvent` is a plain POD struct and
// `VectorStack` default-constructs empty, so `dispatchInput` is exercised as
// bare data exactly like `tool_input.resolveToolAction` is in its own module.
// ---------------------------------------------------------------------------

version(unittest) {
    private enum : ToolAction { TestActionMove = 0, TestActionRemove = 1 }

    /// Test-only stub: a non-empty bindings() table plus a recording
    /// onToolAction/onInputResetAll, so the tests below can assert exactly
    /// which (action, phase) pairs dispatchInput delivered.
    private class RecordingTool : Tool, InputBindable {
        override const(InputBinding)[] bindings() const {
            return [
                InputBinding(InputButton.Left,   InputMod.None,  TestActionMove),
                InputBinding(InputButton.Middle, InputMod.Ctrl,  TestActionRemove, ResetScope.AllButtons),
            ];
        }

        string[] log;
        int resetAllCount;

        override bool onToolAction(ToolAction a, InputPhase p, ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
            import std.conv : to;
            log ~= "a=" ~ a.to!string ~ " p=" ~ p.to!string;
            return true;
        }

        override void onInputResetAll() { resetAllCount++; }
    }

    /// Plain base `Tool` — empty bindings(), inert onToolAction/onInputResetAll
    /// defaults. Stands in for every one of today's unmigrated tool subclasses.
    private SDL_MouseButtonEvent dummyEvent() {
        SDL_MouseButtonEvent e;
        return e;
    }
}

// A tool with an EMPTY bindings() (the base Tool default — i.e. every
// existing, unmigrated subclass) gets PassThrough for every button/phase:
// dispatchInput declines (returns false) without ever calling onToolAction,
// so nothing about this seam existing changes an unmigrated tool's behavior.
unittest {
    auto t = new Tool();
    auto e = dummyEvent();
    VectorStack vts;

    assert(!t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Down, e, vts));
    assert(!t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Up, e, vts));
    assert(!t.dispatchInput(InputButton.Middle, InputMod.Ctrl, InputPhase.Down, e, vts));
    assert(!t.dispatchInput(InputButton.Right, InputMod.Shift, InputPhase.Move, e, vts));
}

// Down arms armed_[button]; Up routes to onToolAction with that SAME action
// id, then clears the arm — a second Up on the same button (no intervening
// Down) is then correctly PassThrough.
unittest {
    auto t = new RecordingTool();
    auto e = dummyEvent();
    VectorStack vts;

    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Down, e, vts));
    assert(t.log == ["a=0 p=Down"]);

    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Up, e, vts));
    assert(t.log == ["a=0 p=Down", "a=0 p=Up"]);

    // Arm was cleared by the Up above — a second Up is a no-op PassThrough.
    t.log = [];
    assert(!t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Up, e, vts));
    assert(t.log == []);
}

// The two-button-chord property: a MIDDLE Down/Up pair (its own action, its
// own button slot) does NOT touch a LEFT gesture that is still armed —
// proves ResetScope.SelfButton (the default for the Left row here) means a
// held drag on one button survives a chord on another. Deliberately uses
// MIDDLE's `AllButtons` row (not a plain SelfButton one) as the a-fortiori
// case: if firing onInputResetAll() still leaves armed_[Left] untouched,
// a weaker SelfButton chord trivially leaves it untouched too.
unittest {
    auto t = new RecordingTool();
    auto e = dummyEvent();
    VectorStack vts;

    // Arm LEFT first (a plain-LMB gesture "in progress").
    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Down, e, vts));
    t.log = [];

    // A MIDDLE+Ctrl chord arrives mid-drag. Its row is ResetScope.AllButtons,
    // so onInputResetAll() DOES fire — but that only clears state the tool
    // itself keeps; the armed_[] slots stay per-button, so LEFT's slot is
    // unaffected by MIDDLE's own Down/Up below.
    assert(t.dispatchInput(InputButton.Middle, InputMod.Ctrl, InputPhase.Down, e, vts));
    assert(t.resetAllCount == 1);
    assert(t.dispatchInput(InputButton.Middle, InputMod.Ctrl, InputPhase.Up, e, vts));
    assert(t.log == ["a=1 p=Down", "a=1 p=Up"]);

    // LEFT's arm (from before the MIDDLE chord) is untouched: its Up still
    // resolves to the ORIGINAL action, not PassThrough.
    t.log = [];
    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Up, e, vts));
    assert(t.log == ["a=0 p=Up"]);
}

// A DIFFERENT button's Down never touches another button's armed_ slot even
// when that other row's ResetScope is SelfButton (the ordinary case) —
// dispatchInput only ever writes/reads armed_[button] for the button of the
// event it's handling.
unittest {
    auto t = new RecordingTool();
    auto e = dummyEvent();
    VectorStack vts;

    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Down, e, vts));
    // A second, unrelated Down on a button with no matching row (Right is
    // unbound in RecordingTool's table) resolves to PassThrough and must not
    // disturb armed_[Left].
    assert(!t.dispatchInput(InputButton.Right, InputMod.None, InputPhase.Down, e, vts));

    t.log = [];
    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Up, e, vts));
    assert(t.log == ["a=0 p=Up"]);
}

// AllButtons reset scope: onInputResetAll() fires exactly once per qualifying
// Down, not per Up, and not at all for a SelfButton row.
unittest {
    auto t = new RecordingTool();
    auto e = dummyEvent();
    VectorStack vts;

    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Down, e, vts));
    assert(t.resetAllCount == 0);   // SelfButton row: no reset-all

    assert(t.dispatchInput(InputButton.Middle, InputMod.Ctrl, InputPhase.Down, e, vts));
    assert(t.resetAllCount == 1);   // AllButtons row: fires once on Down

    assert(t.dispatchInput(InputButton.Middle, InputMod.Ctrl, InputPhase.Up, e, vts));
    assert(t.resetAllCount == 1);   // Up never triggers a reset
}

// Move is delivered to whatever is currently armed on that button, and
// declines once nothing is armed there.
unittest {
    auto t = new RecordingTool();
    auto e = dummyEvent();
    VectorStack vts;

    assert(!t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Move, e, vts)); // nothing armed yet
    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Down, e, vts));
    t.log = [];
    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Move, e, vts));
    assert(t.log == ["a=0 p=Move"]);
}

// resetAllArmed() (the Phase 2 resync seam): arm TWO different buttons, call
// resetAllArmed(), and confirm BOTH armed_ slots are cleared — a subsequent
// Up on EITHER button now routes nothing. Distinct from ResetScope.AllButtons
// above: resetAllArmed() clears every button's arm but does NOT itself call
// onInputResetAll() (they are separate primitives a resync caller can invoke
// together if it needs both effects).
unittest {
    auto t = new RecordingTool();
    auto e = dummyEvent();
    VectorStack vts;

    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Down, e, vts));
    assert(t.dispatchInput(InputButton.Middle, InputMod.Ctrl, InputPhase.Down, e, vts));
    assert(t.resetAllCount == 1); // MIDDLE's row is AllButtons — fired once on its own Down
    t.log = [];
    t.resetAllCount = 0;

    t.resetAllArmed();

    // Both armed_ slots are now PassThrough: neither button's Up routes to
    // onToolAction, and resetAllArmed() itself never touched onInputResetAll.
    assert(!t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Up, e, vts));
    assert(!t.dispatchInput(InputButton.Middle, InputMod.Ctrl, InputPhase.Up, e, vts));
    assert(t.log == []);
    assert(t.resetAllCount == 0);
}

// InputButton.None (an unmapped 4th/5th mouse button from toButton) is declined
// in EVERY phase and never touches armed_[] — no binding fires, no reset runs,
// and a LEFT gesture already in flight is left completely undisturbed (the
// guard runs before armed_[button] is ever indexed, so armed_[None] — which
// would be an out-of-range read — is never evaluated).
unittest {
    auto t = new RecordingTool();
    auto e = dummyEvent();
    VectorStack vts;

    // Arm a real LEFT gesture first.
    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Down, e, vts));
    t.log = [];
    t.resetAllCount = 0;

    // A None press/move/release in the middle of that gesture is a no-op:
    // declined in all three phases, no onToolAction call, no onInputResetAll.
    assert(!t.dispatchInput(InputButton.None, InputMod.None, InputPhase.Down, e, vts));
    assert(!t.dispatchInput(InputButton.None, InputMod.None, InputPhase.Move, e, vts));
    assert(!t.dispatchInput(InputButton.None, InputMod.None, InputPhase.Up, e, vts));
    assert(t.log == []);
    assert(t.resetAllCount == 0);

    // LEFT's armed slot survived untouched: its Up still routes to onToolAction.
    assert(t.dispatchInput(InputButton.Left, InputMod.None, InputPhase.Up, e, vts));
    assert(t.log.length == 1);
}


static assert(sameSet(toolVirtuals, kToolVirtualWhitelist),
    "Tool's virtual surface no longer matches kToolVirtualWhitelist.\n"
  ~ "  added, not in the whitelist: " ~ missingFrom(toolVirtuals, kToolVirtualWhitelist) ~ "\n"
  ~ "  whitelisted, no longer present: " ~ missingFrom(kToolVirtualWhitelist, toolVirtuals) ~ "\n"
  ~ "This is task 0428's moratorium, finally enforced (task 0705). REMOVING a "
  ~ "virtual is good news — delete its line. ADDING one is the question: if "
  ~ "fewer than about three tools will override it, put it on a capability "
  ~ "interface (see InputBindable above, and the five in edit_session.d) and "
  ~ "reach it with a cast, instead of giving every tool in the program a slot "
  ~ "it does not use.");

private bool sameSet(const(string)[] a, const(string)[] b) pure {
    return missingFrom(a, b).length == 0 && missingFrom(b, a).length == 0;
}

/// Names present in `a` but not in `b`, comma-joined (CTFE, so a `static
/// assert` can name the offender instead of just failing).
private string missingFrom(const(string)[] a, const(string)[] b) pure {
    string r;
    foreach (x; a) {
        bool found = false;
        foreach (y; b) if (x == y) { found = true; break; }
        if (!found) r ~= (r.length ? ", " : "") ~ x;
    }
    return r;
}
