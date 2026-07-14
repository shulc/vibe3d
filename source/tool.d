module tool;

import bindbc.sdl;
import bindbc.opengl;

import math;
import shader;
import params : Param, ParamHints, ParamProvider;
import editmode : EditMode;
import operator : VectorStack;
import command : Command;
import std.json : JSONValue;

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
//     predicates (`consumesFalloff`, `wantsHoverForType`) derive from these
//     bits, so a tool whose capability is fixed need only list a flag rather
//     than override a method. Tools whose capability is computed at runtime
//     keep overriding the predicate method instead.
//       - `NeedsFalloff`   : per-vertex transforms multiply displacement by
//                            the per-vertex falloff weight.
//       - `HoverVertices`  : wants vertex hover-highlight while active.
//       - `HoverEdges`     : wants edge hover-highlight while active.
//       - `HoverPolygons`  : wants polygon hover-highlight while active.
// ---------------------------------------------------------------------------
enum ToolFlag : uint {
    None          = 0,
    // Preset-applied bits.
    Immediate     = 1u << 0,
    BrushReset    = 1u << 1,
    // Static capability bits.
    NeedsFalloff  = 1u << 2,
    HoverVertices = 1u << 3,
    HoverEdges    = 1u << 4,
    HoverPolygons = 1u << 5,
}

// ---------------------------------------------------------------------------
// Tool — base class for all editing tools
// ---------------------------------------------------------------------------

class Tool : ParamProvider {
    // Set true by PropertyPanel for the duration of an interactive
    // "Tool Properties" param edit (onParamChanged + evaluate), and left
    // false on the headless `tool.attr` path. Tools that build live
    // geometry on a param change (e.g. EdgeExtrudeTool) gate their preview
    // rebuild on this so the headless flow's ToolDoApplyCommand pre-snapshot
    // stays clean — the headless apply is owned solely by applyHeadless().
    bool interactiveParamEdit = false;

    // Preset-applied behaviour bits — see `ToolFlag`. The preset
    // loader writes this on the freshly-constructed tool before
    // activation. Tools query via `hasFlag` rather than reading the
    // mask directly so the bit names stay enforced by the type.
    uint presetFlags = 0;

    final bool hasFlag(ToolFlag f) const {
        return (presetFlags & cast(uint)f) != 0;
    }

    // Static capability bits for this tool class. Override to return the
    // OR of the constant capabilities the tool always has (NeedsFalloff,
    // HoverVertices/Edges/Polygons). The base capability predicates below
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

    // Called once per frame inside the ImGui window to append tool UI.
    // Returns true if the user clicked the activation button.
    bool drawImGui() { return false; }

    // Called inside the floating "Tool Properties" ImGui window.
    // Override to show/edit tool-specific properties.
    void drawProperties() {}

    // Schema: list of parameters. Default: none. Tools that surface a
    // numeric properties panel override this.
    Param[] params() { return []; }

    // Called before opening an args dialog (rare for tools, kept for
    // symmetry with Command).
    void dialogInit() {}

    // Called after a parameter value changes. Tools override to drive
    // their preview re-evaluation.
    void onParamChanged(string name) {}

    // Whether the named parameter widget should be enabled.
    bool paramEnabled(string name) const { return true; }

    // Phase 7.5: opt-in flag for the WGHT (Falloff) stage. Tools that
    // apply per-vertex transforms (Move / Rotate / Scale via the
    // TransformTool base) override to `true` so their drag math
    // multiplies per-vertex displacements by the falloff weight.
    // Other tools (Bevel, primitive create-tools, Pen) leave it
    // `false` — their geometry isn't per-vertex / has no meaningful
    // falloff interpretation. See doc/falloff_plan.md §"Tool
    // integration points" for the rationale. Derived from the static
    // `NeedsFalloff` capability bit by default.
    bool consumesFalloff() const { return hasCapability(ToolFlag.NeedsFalloff); }

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

    // Per-parameter hint overrides at runtime.
    void paramHints(string name, ref ParamHints hints) {}

    // Re-apply the tool's preview after a parameter change. Default
    // no-op (tools without params don't need this).
    void evaluate() {}

    // Whether the previous evaluation can be incrementally patched given
    // new attribute values, or must be rebuilt from scratch. Default:
    // always rebuild. (Renderer in phase 3+ will start using this for
    // big meshes / heavy tools.)
    bool canIncrementalUpdate() const { return false; }

    // Apply tool one-shot (headless / scripted path). Default no-op returns
    // false. Implementations run business logic with current attribute
    // state — they MUST NOT snapshot themselves; the caller (eventual
    // ToolHeadlessCommand in phase 4.4) wraps with snapshot pair for undo.
    //
    // Currently unused; renderer in phase 4.4+ will start dispatching to it.
    bool applyHeadless() { return false; }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    //
    // INVARIANT: hasUncommittedEdit() <=> a commit would fire if the tool's
    // session ended *right now*. This is deliberately NOT "state != Idle" and
    // NOT a single bool reused by every tool — it must equal the tool's REAL
    // commit guard, including any epsilon terms (e.g. a primitive whose height
    // is sub-epsilon has a live state but would commit nothing, so it must
    // return false). Each interactive tool overrides this to mirror the exact
    // predicate its deactivate()/commit path tests.
    bool hasUncommittedEdit() const { return false; }

    // Abort the tool's open live edit, restoring the mesh to the session's
    // pre-edit baseline WITHOUT recording anything to history. Postcondition:
    // hasUncommittedEdit() == false and the mesh is coherent. Cancel bodies are
    // heterogeneous across tools (live-mesh restore / preview-only reset / new
    // transform-cancel code) — this is not uniformly "reuse the RMB handler".
    void cancelUncommittedEdit() {}

    // Whether an interactive history REDO (Ctrl+Shift+Z) should CANCEL this
    // tool's open uncommitted edit instead of stepping the redo stack. The
    // undo direction always cancels an open edit (there is nothing to undo
    // into a still-open session); the redo direction, by default, does NOT —
    // refire-based tools (e.g. BoxTool's live property edit) legitimately hold
    // an uncommitted edit AND must redo their own param changes on Ctrl+Shift+Z.
    // Only a tool whose uncommitted edit is a STANDING preview sitting on the
    // mesh across arbitrary frames (LoopSliceTool's `armed_`) overrides this to
    // true, so a redo reachable while the preview is up cancels it first rather
    // than applying a redo on top of the dirty mesh. Default false ⇒ every
    // other tool keeps the pre-0232 redo-steps-the-stack behavior.
    bool cancelsOnRedo() const { return false; }

    // Task 0400: whether cancelling this tool's open uncommitted edit (via
    // cancelUncommittedEdit(), reached from navHistory()'s whole-edit-cancel
    // branch below) leaves the tool with a still-meaningful session to stay
    // in, versus nothing further to do. The reference editor's interactive
    // Ctrl+Z NEVER drops an active interactive tool — undo always operates on
    // mesh-edit history and the tool stays live. For most tools here, an
    // uncommitted edit IS the tool's whole reason to be active (a one-shot
    // create/drag gesture — Box, Pen, a primitive's live resize), so
    // navHistory's default of cancel-then-drop mirrors Esc and matches the
    // pre-0400, still-correct behavior for that shape. A STANDING-PREVIEW
    // tool is a different shape: the preview sits on the mesh across
    // arbitrary frames and is re-armable after every commit/cancel
    // (LoopSliceTool/EdgeSliceTool — the same family that already opts into
    // cancelsOnRedo() above), so cancelling its live preview is a normal step
    // WITHIN an ongoing session, not the end of the tool's usefulness — those
    // tools override this to true. Default false ⇒ every other tool keeps
    // its pre-0400 cancel-then-drop behavior byte-for-byte.
    bool survivesEditCancel() const { return false; }

    // Mid-session per-step undo peel (task 0321). The app's navHistory()
    // chokepoint calls this FIRST, before its own hasUncommittedEdit()
    // whole-edit-cancel branch: a tool holding some internal sequence of
    // not-yet-committed steps (e.g. EdgeSliceTool's latched chain points) can
    // peel exactly ONE of those steps here and report true, so a real Ctrl+Z
    // keystroke un-does one step at a time instead of unwinding the whole
    // live edit. Default false ⇒ every other tool's undo behavior (and the
    // existing hasUncommittedEdit()/cancelsOnRedo() cancel-whole-edit path)
    // is completely unaffected.
    bool tryUndoStepInSession() { return false; }

    // Re-sync the tool's cached pre-edit baseline / gizmo to the CURRENT mesh
    // after history navigation moved geometry underneath an active tool. P0
    // ships a minimal stub (default no-op; transform marks its caches dirty,
    // EdgeExtrude re-captures its `before` snapshot). Promoted to a first-class
    // post-mode re-init in P1.
    void resyncSession() {}

    // ----- Refire (record-once, re-evaluate) hooks (undo/redo migration P4) --
    //
    // A Tool-Properties (panel) param edit on an opted-in tool becomes ONE
    // re-evaluated undo entry instead of a tool-internal preview followed by a
    // separate commit-at-deactivate. The driver (app.d's tool.attr dispatch)
    // brackets a panel-param-edit SESSION with the history's refireBegin /
    // refireEnd primitives and, on each param change inside the bracket, fires
    // buildRefireCommand() so each tick reverts the previous live command and
    // applies the freshly-evaluated one — the net stack effect is a single
    // entry reflecting the LAST param value.
    //
    // Opt-in. Default false: a non-opted-in tool keeps its existing
    // onParamChanged() preview behaviour unchanged and is never routed through
    // refire.
    bool wantsRefire() const { return false; }

    // Build the command that represents the tool's CURRENT param state, ready
    // to apply(). For a deform tool this re-runs the deformation against the
    // session baseline and packages the resulting per-vertex before/after as a
    // single undoable command, WITHOUT recording it (the history's fire() owns
    // the apply / revert / record lifecycle). Returns null when there is no
    // meaningful edit to fire (e.g. the params produced a no-op diff) — the
    // driver then skips the fire() for that tick. Default null: only tools that
    // return true from wantsRefire() override this.
    Command buildRefireCommand() { return null; }

    // Toggle the tool's "a refire session is driving me" state. Set true by the
    // driver around a param injection so the tool suppresses its own internal
    // preview (the fired command owns mutation); cleared by the driver when the
    // session ends. Default no-op — only opted-in tools track it.
    void setRefireDriving(bool on) {}

    // Driver callback once a refire session committed its single entry (after
    // refireEnd). Lets the tool latch its double-record guard and advance its
    // baseline so the subsequent commit chokepoint records nothing. Default
    // no-op.
    void onRefireCommitted() {}

    // ----- Live re-evaluation hooks (attr edit re-runs a live tool) ---------
    //
    // Whether this tool has an OPEN live-evaluation session that an attribute
    // edit should re-run. While false, a `tool.attr` edit just stores the new
    // value into the tool's attribute store and changes no geometry — the
    // faithful "fresh-tool inertness" semantics. While true, the attr-command
    // driver may call reEvaluate() to re-run the tool's apply with the freshly
    // written attribute values.
    //
    // INVARIANT: no tool may BOTH override evaluate() to mutate geometry AND
    // return hasLiveEval()==true. The attr-command path already calls
    // onParamChanged()+evaluate() before the re-eval trigger, so a tool doing
    // both would apply twice on one attr write. Tools whose preview runs through
    // evaluate() (primitives) keep hasLiveEval()==false; tools whose geometry
    // runs through a session replay (the transform tool) keep evaluate() a no-op.
    bool hasLiveEval() const { return false; }

    // Live-eval predicate SPECIFICALLY for a value-attribute write (`tool.attr
    // <id> RX 30` etc.), distinct from `hasLiveEval()` (which also gates the
    // pipe-stage config path `tool.pipe.attr falloff …`). Defaults to
    // `hasLiveEval()` so existing tools are unaffected. The transform tool widens
    // THIS predicate (only) to include a still-open gizmo RUN whose per-gesture
    // edit session already self-committed (P-F): a panel RX/RY/RZ edit after a
    // gizmo gesture must compose onto the run baseline, but a falloff CONFIG
    // change in that same window must STILL flow through the idle re-grade record
    // path (which appends a tagged in-session entry) rather than the silent
    // panel-replay. Keeping the pipe path on the narrower `hasLiveEval()`
    // preserves that falloff-refire entry-count contract.
    bool hasLiveAttrEval() const { return hasLiveEval(); }

    // Re-run this tool's apply from its open live-evaluation session baseline
    // using the tool's CURRENT attribute values (ABSOLUTE — read the value
    // straight from the baseline, never accumulate a per-call delta). Only
    // meaningful when hasLiveEval() is true; calling it otherwise is a no-op.
    // The result coalesces into the session's single undo entry, committed when
    // the session ends. Default no-op — only tools with a live session override.
    void reEvaluate() {}

    // Whether `params()` should be rendered by the inline PropertyPanel.
    // Tools that expose params() purely for the headless tool.attr path,
    // while drawProperties() handles the interactive UI (e.g. BevelTool
    // edge-mode), override this to false and let drawProperties() own
    // rendering — preventing duplicate widgets.
    bool renderParamsAsPanel() const { return true; }

    // Whether this tool emits a ToolDeactivationCommand on drop, enabling
    // undo-cursor lifecycle stepping. Default false (only transform tools
    // that interleave geometry commits with tool sessions opt in).
    bool emitsLifecycleUndo() const { return false; }


    // Edit modes in which this tool makes sense. Side-panel /
    // status-bar buttons auto-disable when the current edit mode is
    // not in this list. Default: every mode (most tools are mode-
    // agnostic — Move / Rotate / Scale operate on whatever the
    // current selection projects to). Specialised tools (BevelTool
    // only meaningful on edges, etc.) override.
    EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }
}