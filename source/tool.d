module tool;

import bindbc.sdl;
import bindbc.opengl;

import math;
import shader;

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
}