module tool;

import bindbc.sdl;
import bindbc.opengl;

import math;
import shader;
import params : Param, ParamHints, ParamProvider;
import editmode : EditMode;
import operator : VectorStack;

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
    void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts) {}

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

    // Whether `params()` should be rendered by the inline PropertyPanel.
    // Tools that expose params() purely for the headless tool.attr path,
    // while drawProperties() handles the interactive UI (e.g. BevelTool
    // edge-mode), override this to false and let drawProperties() own
    // rendering — preventing duplicate widgets.
    bool renderParamsAsPanel() const { return true; }


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