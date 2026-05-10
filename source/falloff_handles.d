module falloff_handles;

import bindbc.sdl;

import handler : Arrow, BoxHandler, Handler, gizmoSize;
import math   : Vec3, Viewport, projectToWindowFull, closestOnSegment2D;
import shader : Shader;
import drag   : screenAxisDelta, planeDragDelta;
import toolpipe.packets  : FalloffPacket, FalloffType;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : Stage;

import std.format : format;
import std.math   : sqrt, abs;

// ---------------------------------------------------------------------------
// FalloffLinearGizmo — interactive draggable handles for linear falloff
// endpoints (start = full influence, end = zero influence).
//
// Each endpoint carries a mini move-tool gizmo: 3 axis arrows (red X /
// green Y / blue Z) for axis-locked drag plus a cyan center box for
// screen-plane drag — same control set MoveHandler exposes for the
// main tool, sized down so it doesn't visually dominate the falloff
// segment. Mirrors MODO 9's linear-falloff overlay where each endpoint
// has the same set of axis arrows + box marker.
//
// On drag, the new endpoint position is pushed through FalloffStage's
// setAttr (same path as `tool.pipe.attr falloff start <x,y,z>`).
// TransformTool's update() detects mid-tool falloff changes (Phase
// 7.5h) and re-applies the per-vertex weighting onto the open edit
// baseline, so the mesh re-evaluates live as the user drags.
//
// Tools that consume falloff (Move / Rotate / Scale) own one of these
// gizmos and must dispatch mouse events through it BEFORE their own
// gizmo handlers — clicking a falloff endpoint handle drags the
// falloff, not the selection.
// ---------------------------------------------------------------------------

// Mini move-tool gizmo for a single falloff endpoint. 3 axis arrows + 1
// box, positioned around `pos`. Sized via gizmoSize() with a small
// scale factor so the falloff handles don't compete visually with the
// main MoveHandler at the selection center.
class FalloffEndpointHandle {
    Vec3 pos;
    Arrow      arrowX, arrowY, arrowZ;
    BoxHandler centerBox;
    int        dragAxis = -1;   // -1 idle, 0 X, 1 Y, 2 Z, 3 centerBox
    int        lastMX, lastMY;

    enum float SCALE   = 0.4f;  // mini — 40% of main MoveHandler size

    this() {
        // Same colours as MoveHandler arrows so the meaning carries
        // over (red = X, green = Y, blue = Z). Center box cyan so it
        // reads as "falloff handle" at a glance.
        arrowX = new Arrow(Vec3(0,0,0), Vec3(1,0,0), Vec3(0.9f, 0.2f, 0.2f));
        arrowY = new Arrow(Vec3(0,0,0), Vec3(0,1,0), Vec3(0.2f, 0.9f, 0.2f));
        arrowZ = new Arrow(Vec3(0,0,0), Vec3(0,0,1), Vec3(0.2f, 0.2f, 0.9f));
        centerBox = new BoxHandler(Vec3(0,0,0), Vec3(0.4f, 0.9f, 0.95f));
        // Slimmer arrow shafts — secondary control, not the main tool.
        arrowX.lineWidth = 2.5f;
        arrowY.lineWidth = 2.5f;
        arrowZ.lineWidth = 2.5f;
    }

    void destroy() {
        arrowX.destroy();
        arrowY.destroy();
        arrowZ.destroy();
        centerBox.destroy();
    }

    /// Reposition the sub-handles around `pos` with on-screen-constant
    /// scaling. Called every draw so the gizmo follows live falloff
    /// attribute changes.
    void update(Vec3 newPos, const ref Viewport vp) {
        pos = newPos;
        float size = gizmoSize(pos, vp, SCALE);
        // Arrows offset from center so they don't z-fight with the
        // centerBox; mirrors MoveHandler's arrow offset.
        Vec3 ax = Vec3(1, 0, 0);
        Vec3 ay = Vec3(0, 1, 0);
        Vec3 az = Vec3(0, 0, 1);
        arrowX.start = Vec3(pos.x + ax.x*size/6, pos.y + ax.y*size/6, pos.z + ax.z*size/6);
        arrowX.end   = Vec3(pos.x + ax.x*size,   pos.y + ax.y*size,   pos.z + ax.z*size);
        arrowY.start = Vec3(pos.x + ay.x*size/6, pos.y + ay.y*size/6, pos.z + ay.z*size/6);
        arrowY.end   = Vec3(pos.x + ay.x*size,   pos.y + ay.y*size,   pos.z + ay.z*size);
        arrowZ.start = Vec3(pos.x + az.x*size/6, pos.y + az.y*size/6, pos.z + az.z*size/6);
        arrowZ.end   = Vec3(pos.x + az.x*size,   pos.y + az.y*size,   pos.z + az.z*size);
        centerBox.pos  = pos;
        centerBox.size = size * 0.05f;

        // Hide arrows pointing too directly toward / away from camera —
        // same convention as MoveHandler: a near-coaxial arrow has zero
        // on-screen length and isn't pickable anyway.
        Vec3 d = Vec3(vp.eye.x - pos.x, vp.eye.y - pos.y, vp.eye.z - pos.z);
        float dist = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
        Vec3 viewDir = dist > 1e-6f
            ? Vec3(d.x/dist, d.y/dist, d.z/dist)
            : Vec3(0, 0, 1);
        enum float HIDE = 0.995f;
        arrowX.setVisible(abs(viewDir.x) < HIDE);
        arrowY.setVisible(abs(viewDir.y) < HIDE);
        arrowZ.setVisible(abs(viewDir.z) < HIDE);
    }

    void draw(const ref Shader shader, const ref Viewport vp) {
        // Force-hover the active sub-handle so it stays highlighted
        // through the drag (Arrow / BoxHandler highlight on hover).
        arrowX.setForceHovered(dragAxis == 0);
        arrowY.setForceHovered(dragAxis == 1);
        arrowZ.setForceHovered(dragAxis == 2);
        centerBox.setForceHovered(dragAxis == 3);
        arrowX.draw(shader, vp);
        arrowY.draw(shader, vp);
        arrowZ.draw(shader, vp);
        centerBox.draw(shader, vp);
    }

    // Hit-test mouse against sub-handles. Returns 0/1/2 for X/Y/Z
    // arrow, 3 for centerBox, -1 for miss. Order matches MoveTool's
    // hitTestAxes: box first (smaller, easier to lose), then arrows.
    int hitTest(int mx, int my, const ref Viewport vp) {
        if (centerBox.hitTest(mx, my, vp)) return 3;
        Arrow[3] arrows = [arrowX, arrowY, arrowZ];
        foreach (i, arrow; arrows) {
            if (!arrow.isVisible()) continue;
            float sax, say, az, sbx, sby, bz;
            if (!projectToWindowFull(arrow.start, vp, sax, say, az)) continue;
            if (!projectToWindowFull(arrow.end,   vp, sbx, sby, bz)) continue;
            float t;
            if (closestOnSegment2D(cast(float)mx, cast(float)my,
                                   sax, say, sbx, sby, t) < 8.0f)
                return cast(int)i;
        }
        return -1;
    }

    // Pick a delta for the current drag axis. Returns Vec3(0,0,0) and
    // sets skip when the drag math degenerates (axis projects to a
    // point on screen, etc.).
    Vec3 dragDelta(int mx, int my, const ref Viewport vp, out bool skip) {
        skip = false;
        if (dragAxis == 0)
            return screenAxisDelta(mx, my, lastMX, lastMY,
                                   pos, Vec3(1, 0, 0), vp, skip);
        if (dragAxis == 1)
            return screenAxisDelta(mx, my, lastMX, lastMY,
                                   pos, Vec3(0, 1, 0), vp, skip);
        if (dragAxis == 2)
            return screenAxisDelta(mx, my, lastMX, lastMY,
                                   pos, Vec3(0, 0, 1), vp, skip);
        if (dragAxis == 3)
            return planeDragDelta(mx, my, lastMX, lastMY,
                                  /*plane=most-facing*/0, pos, vp, skip);
        skip = true;
        return Vec3(0, 0, 0);
    }
}


class FalloffLinearGizmo {
    FalloffEndpointHandle startHandle;
    FalloffEndpointHandle endHandle;

private:
    int active = -1;   // -1 idle, 0 = start, 1 = end

public:
    this() {
        startHandle = new FalloffEndpointHandle();
        endHandle   = new FalloffEndpointHandle();
    }

    void destroy() {
        startHandle.destroy();
        endHandle.destroy();
    }

    void draw(const ref Shader shader, const ref Viewport vp,
              const ref FalloffPacket cfg)
    {
        if (!cfg.enabled || cfg.type != FalloffType.Linear) return;
        startHandle.update(cfg.start, vp);
        endHandle.update  (cfg.end,   vp);
        startHandle.draw(shader, vp);
        endHandle.draw  (shader, vp);
    }

    bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                           const ref Viewport vp,
                           const ref FalloffPacket cfg)
    {
        if (!cfg.enabled || cfg.type != FalloffType.Linear) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        // Test start endpoint first; fall through to end. Endpoints
        // shouldn't visually overlap unless start ≈ end (degenerate
        // falloff segment) so a deterministic order is fine.
        int hit = startHandle.hitTest(e.x, e.y, vp);
        if (hit >= 0) {
            active = 0; startHandle.dragAxis = hit;
            startHandle.lastMX = e.x; startHandle.lastMY = e.y;
            return true;
        }
        hit = endHandle.hitTest(e.x, e.y, vp);
        if (hit >= 0) {
            active = 1; endHandle.dragAxis = hit;
            endHandle.lastMX = e.x; endHandle.lastMY = e.y;
            return true;
        }
        return false;
    }

    bool onMouseMotion(ref const SDL_MouseMotionEvent e,
                       const ref Viewport vp)
    {
        if (active < 0) return false;
        FalloffEndpointHandle h = (active == 0) ? startHandle : endHandle;
        bool skip;
        Vec3 delta = h.dragDelta(e.x, e.y, vp, skip);
        h.lastMX = e.x; h.lastMY = e.y;
        if (skip) return true;
        Vec3 newPos = Vec3(h.pos.x + delta.x,
                           h.pos.y + delta.y,
                           h.pos.z + delta.z);
        // Eagerly update the local handle pos so a second motion event
        // in the same frame computes its incremental delta against the
        // post-event-1 position. Without this, h.pos stays stuck on
        // its pre-drag value (it's only refreshed from cfg in draw())
        // and every subsequent setAttr in the same frame overwrites
        // the previous one with the SAME world position — gizmo
        // doesn't follow the mouse past the first step.
        h.pos = newPos;
        if (g_pipeCtx is null) return true;
        foreach (s; g_pipeCtx.pipeline.all()) {
            if (s.id() != "falloff") continue;
            string attr = (active == 0) ? "start" : "end";
            (cast(Stage)s).setAttr(attr,
                format("%g,%g,%g", newPos.x, newPos.y, newPos.z));
            break;
        }
        return true;
    }

    bool onMouseButtonUp(ref const SDL_MouseButtonEvent e)
    {
        if (active < 0) return false;
        if (active == 0) startHandle.dragAxis = -1;
        else             endHandle.dragAxis   = -1;
        active = -1;
        return true;
    }

    bool isDragging() const { return active >= 0; }
}
