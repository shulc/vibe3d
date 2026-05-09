module tool;

import bindbc.sdl;
import bindbc.opengl;

import math;
import shader;
import params : Param, ParamHints;

// ---------------------------------------------------------------------------
// Tool — base class for all editing tools
// ---------------------------------------------------------------------------

class Tool {
    // Human-readable name shown in the UI.
    string name() const { return "Tool"; }

    // Called when the tool becomes the active tool.
    void activate() {}

    // Called when another tool becomes active.
    void deactivate() {}

    // Called once per frame to recompute tool state (e.g. gizmo position).
    void update() {}

    // SDL event handlers.
    // Return true to mark the event as consumed (stops further processing).
    bool onMouseButtonDown(ref const SDL_MouseButtonEvent e) { return false; }
    bool onMouseButtonUp  (ref const SDL_MouseButtonEvent e) { return false; }
    bool onMouseMotion    (ref const SDL_MouseMotionEvent  e) { return false; }
    bool onKeyDown        (ref const SDL_KeyboardEvent     e) { return false; }
    bool onKeyUp          (ref const SDL_KeyboardEvent     e) { return false; }

    // Called once per frame after the 3-D geometry has been drawn.
    // Override to render tool-specific overlays (gizmos, highlights, etc.).
    void draw(const ref Shader shader, const ref Viewport vp) {}

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
    // integration points" for the rationale.
    bool consumesFalloff() const { return false; }

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
}