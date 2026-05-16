module falloff_handles;

import bindbc.sdl;

import handler : Arrow, BoxHandler, Handler, gizmoSize;
import math   : Vec3, Viewport, projectToWindowFull, closestOnSegment2D, dot,
                screenRay, rayPlaneIntersect;
import shader : Shader;
import drag   : screenAxisDelta, planeDragDelta;
import toolpipe.packets  : FalloffPacket, FalloffType;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : Stage;
import tools.create_common : pickWorkplaneFrame, WorkplaneFrame;

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


// Outward axes for Radial size handles, matching the order used by
// `prim.sphere`'s radH[6]: 0:+X 1:-X 2:+Y 3:-Y 4:+Z 5:-Z. Each handle
// drives one component of the ellipsoid's `size` Vec3 in
// FalloffStage; pairs (0,1) ↔ X, (2,3) ↔ Y, (4,5) ↔ Z.
private static immutable Vec3[6] RAD_AXES = [
    Vec3( 1, 0, 0), Vec3(-1, 0, 0),
    Vec3( 0, 1, 0), Vec3( 0,-1, 0),
    Vec3( 0, 0, 1), Vec3( 0, 0,-1),
];

class FalloffGizmo {
    // Linear endpoints.
    FalloffEndpointHandle startHandle;
    FalloffEndpointHandle endHandle;

    // Radial: center mini-move + 6 ellipsoid-surface box handles
    // (±X / ±Y / ±Z). Mirrors prim.sphere's radius-edit pattern so
    // the falloff sphere feels the same to drag as a sphere primitive
    // gizmo.
    FalloffEndpointHandle centerHandle;
    BoxHandler[6]         sizeH;

private:
    // Per-mode drag state — at most one of these is ≥ 0 at any time
    // (a click consumed by Linear can't reach Radial dispatch).
    int activeLinear = -1;   // -1 idle, 0 = start, 1 = end
    int activeRadial = -1;   // -1 idle, 0 = center, 1..6 = size handle (idx-1)
    int sizeLastMX, sizeLastMY;
    Vec3 sizeAtDragStart;    // captured at down; incrementally mutated on motion

public:
    this() {
        startHandle  = new FalloffEndpointHandle();
        endHandle    = new FalloffEndpointHandle();
        centerHandle = new FalloffEndpointHandle();
        foreach (i; 0 .. 6) {
            Vec3 col = (i < 2) ? Vec3(0.9f, 0.2f, 0.2f)
                     : (i < 4) ? Vec3(0.2f, 0.9f, 0.2f)
                               : Vec3(0.2f, 0.2f, 0.9f);
            sizeH[i] = new BoxHandler(Vec3(0, 0, 0), col);
        }
    }

    void destroy() {
        startHandle.destroy();
        endHandle.destroy();
        centerHandle.destroy();
        foreach (h; sizeH) h.destroy();
    }

    void draw(const ref Shader shader, const ref Viewport vp,
              const ref FalloffPacket cfg)
    {
        if (!cfg.enabled) return;
        if (cfg.type == FalloffType.Linear) {
            startHandle.update(cfg.start, vp);
            endHandle.update  (cfg.end,   vp);
            startHandle.draw(shader, vp);
            endHandle.draw  (shader, vp);
        } else if (cfg.type == FalloffType.Radial) {
            centerHandle.update(cfg.center, vp);
            float[3] sz = [cfg.size.x, cfg.size.y, cfg.size.z];
            foreach (i; 0 .. 6) {
                int axis = i / 2;
                Vec3 worldPos = Vec3(
                    cfg.center.x + RAD_AXES[i].x * sz[axis],
                    cfg.center.y + RAD_AXES[i].y * sz[axis],
                    cfg.center.z + RAD_AXES[i].z * sz[axis]);
                sizeH[i].pos  = worldPos;
                sizeH[i].size = gizmoSize(worldPos, vp, 0.04f);
                sizeH[i].setForceHovered(activeRadial == cast(int)i + 1);
                sizeH[i].draw(shader, vp);
            }
            centerHandle.draw(shader, vp);
        }
    }

    bool onMouseButtonDown(ref const SDL_MouseButtonEvent e,
                           const ref Viewport vp,
                           const ref FalloffPacket cfg)
    {
        if (!cfg.enabled) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;

        if (cfg.type == FalloffType.Linear) {
            // Endpoints shouldn't visually overlap unless start ≈ end
            // (degenerate falloff segment) so a deterministic
            // start-then-end order is fine.
            int hit = startHandle.hitTest(e.x, e.y, vp);
            if (hit >= 0) {
                activeLinear = 0; startHandle.dragAxis = hit;
                startHandle.lastMX = e.x; startHandle.lastMY = e.y;
                return true;
            }
            hit = endHandle.hitTest(e.x, e.y, vp);
            if (hit >= 0) {
                activeLinear = 1; endHandle.dragAxis = hit;
                endHandle.lastMX = e.x; endHandle.lastMY = e.y;
                return true;
            }
            return false;
        }
        if (cfg.type == FalloffType.Radial) {
            // Test center handle first (denser cluster of arrows + box
            // at the ellipsoid centroid); fall through to the 6 size
            // boxes on the surface.
            int hit = centerHandle.hitTest(e.x, e.y, vp);
            if (hit >= 0) {
                activeRadial = 0; centerHandle.dragAxis = hit;
                centerHandle.lastMX = e.x; centerHandle.lastMY = e.y;
                return true;
            }
            foreach (i; 0 .. 6) {
                if (sizeH[i].hitTest(e.x, e.y, vp)) {
                    activeRadial = cast(int)i + 1;
                    sizeLastMX = e.x; sizeLastMY = e.y;
                    sizeAtDragStart = cfg.size;
                    return true;
                }
            }
            return false;
        }
        return false;
    }

    bool onMouseMotion(ref const SDL_MouseMotionEvent e,
                       const ref Viewport vp)
    {
        if (activeLinear < 0 && activeRadial < 0) return false;
        if (g_pipeCtx is null) return true;

        if (activeLinear >= 0) {
            FalloffEndpointHandle h = (activeLinear == 0) ? startHandle : endHandle;
            bool skip;
            Vec3 delta = h.dragDelta(e.x, e.y, vp, skip);
            h.lastMX = e.x; h.lastMY = e.y;
            if (skip) return true;
            Vec3 newPos = Vec3(h.pos.x + delta.x,
                               h.pos.y + delta.y,
                               h.pos.z + delta.z);
            // Eagerly update local pos so a second motion event in the
            // same frame computes its incremental delta against the
            // post-event-1 position. Without this, h.pos stays stuck on
            // its pre-drag value (refreshed from cfg only in draw())
            // and every subsequent setAttr in the same frame overwrites
            // the previous one — gizmo doesn't follow the mouse past
            // the first step.
            h.pos = newPos;
            string attr = (activeLinear == 0) ? "start" : "end";
            foreach (s; g_pipeCtx.pipeline.all()) {
                if (s.id() != "falloff") continue;
                (cast(Stage)s).setAttr(attr,
                    format("%g,%g,%g", newPos.x, newPos.y, newPos.z));
                break;
            }
            return true;
        }

        // Radial.
        if (activeRadial == 0) {
            // Center drag — same dispatch as Linear endpoints, into
            // FalloffStage's `center` attribute.
            bool skip;
            Vec3 delta = centerHandle.dragDelta(e.x, e.y, vp, skip);
            centerHandle.lastMX = e.x; centerHandle.lastMY = e.y;
            if (skip) return true;
            Vec3 newCenter = Vec3(centerHandle.pos.x + delta.x,
                                  centerHandle.pos.y + delta.y,
                                  centerHandle.pos.z + delta.z);
            centerHandle.pos = newCenter;
            foreach (s; g_pipeCtx.pipeline.all()) {
                if (s.id() != "falloff") continue;
                (cast(Stage)s).setAttr("center",
                    format("%g,%g,%g", newCenter.x, newCenter.y, newCenter.z));
                break;
            }
            return true;
        }
        // Size handle 1..6 → index 0..5 in RAD_AXES.
        int idx     = activeRadial - 1;
        int axis    = idx / 2;
        Vec3 outward = RAD_AXES[idx];
        bool skip;
        Vec3 delta = screenAxisDelta(e.x, e.y, sizeLastMX, sizeLastMY,
                                     sizeH[idx].pos, outward, vp, skip);
        sizeLastMX = e.x; sizeLastMY = e.y;
        if (skip) return true;
        // Project drag onto outward axis to a scalar radius change. The
        // ±X and ±Y / ±Z opposite-side pairs both pull the same scalar
        // `size[axis]` outward, mirroring prim.sphere's behaviour.
        float d = dot(delta, outward);
        float[3] sz = [sizeAtDragStart.x, sizeAtDragStart.y, sizeAtDragStart.z];
        sz[axis] += d;
        if (sz[axis] < 0.0f) sz[axis] = 0.0f;
        sizeAtDragStart = Vec3(sz[0], sz[1], sz[2]);
        foreach (s; g_pipeCtx.pipeline.all()) {
            if (s.id() != "falloff") continue;
            (cast(Stage)s).setAttr("size",
                format("%g,%g,%g", sz[0], sz[1], sz[2]));
            break;
        }
        return true;
    }

    bool onMouseButtonUp(ref const SDL_MouseButtonEvent e)
    {
        if (activeLinear < 0 && activeRadial < 0) return false;
        if (activeLinear == 0) startHandle.dragAxis = -1;
        if (activeLinear == 1) endHandle.dragAxis   = -1;
        if (activeRadial == 0) centerHandle.dragAxis = -1;
        activeLinear = -1;
        activeRadial = -1;
        return true;
    }

    bool isDragging() const { return activeLinear >= 0 || activeRadial >= 0; }
}

// ---------------------------------------------------------------------------
// Screen-falloff RMB-radius gesture.
//
// When the active toolpipe has a FalloffStage of type Screen (e.g. the
// xfrm.softDrag preset), RMB is repurposed: click sets the falloff
// center to the cursor, drag along +X grows the radius. The disc
// already renders through drawFalloffOverlay() from the FalloffPacket
// the stage publishes — we only mutate the stage attributes here.
//
// Lives at module scope (not tied to any tool) because the gesture
// belongs to the falloff system itself: any tool that activates Screen
// falloff inherits it without overriding RMB handling. app.d's RMB
// dispatch consults `screenFalloffActive()` first and routes to these
// helpers instead of starting a selection lasso.
// ---------------------------------------------------------------------------
private bool  rmbScreenDragActive_ = false;
private int   rmbScreenDragX0_     = 0;
private int   rmbScreenDragY0_     = 0;
private float rmbScreenDragR0_     = 0;
// Bracketed by tools that consume screen falloff at LMB-down /
// LMB-up of their own drags (MoveTool when dragAxis transitions in
// and out of >=0). Drives `screenFalloffOverlayVisible()` so the
// disc renders for the duration of an active soft-drag pull as
// well as for the RMB-radius gesture.
private bool  lmbScreenDragActive_ = false;

bool screenFalloffActive() {
    import toolpipe.stages.falloff : FalloffStage;
    if (g_pipeCtx is null) return false;
    foreach (s; g_pipeCtx.pipeline.all()) {
        if (s.id() != "falloff") continue;
        auto fs = cast(FalloffStage)s;
        if (fs is null) return false;
        return fs.type == FalloffType.Screen;
    }
    return false;
}

bool screenFalloffRMBDragging() { return rmbScreenDragActive_; }

/// Tools call these at the start / end of an LMB drag they want the
/// Screen-falloff overlay to track. End is unconditional / idempotent
/// — safe to call from the generic drag-end path even when no drag
/// was started under screen falloff.
void screenFalloffLMBBegin() { lmbScreenDragActive_ = true;  }
void screenFalloffLMBEnd()   { lmbScreenDragActive_ = false; }

/// True when the Screen-falloff disc overlay should be visible:
/// either the RMB radius gesture is in flight, or a tool is mid-LMB
/// drag with screen falloff active. Outside both, the disc stays
/// hidden so it doesn't clutter the viewport during idle tool use.
bool screenFalloffOverlayVisible() {
    return rmbScreenDragActive_ || lmbScreenDragActive_;
}

private void pushScreenFalloff(float cx, float cy, float size) {
    if (g_pipeCtx is null) return;
    foreach (s; g_pipeCtx.pipeline.all()) {
        if (s.id() != "falloff") continue;
        auto st = cast(Stage)s;
        st.setAttr("screenCx",   format("%g", cx));
        st.setAttr("screenCy",   format("%g", cy));
        st.setAttr("screenSize", format("%g", size));
        break;
    }
}

/// Push only the center (cx, cy) of the screen falloff disc, leaving
/// the current radius untouched. Transform tools call this on LMB-down
/// so the falloff re-centers at every fresh grab. Safe to call when
/// the pipeline has no falloff stage (returns silently).
void screenFalloffSetCenter(int x, int y) {
    if (g_pipeCtx is null) return;
    foreach (s; g_pipeCtx.pipeline.all()) {
        if (s.id() != "falloff") continue;
        auto st = cast(Stage)s;
        st.setAttr("screenCx", format("%g", cast(float)x));
        st.setAttr("screenCy", format("%g", cast(float)y));
        break;
    }
}

/// Begin RMB-radius gesture: re-center the falloff disc at (x, y) and
/// capture the current radius as the baseline for the drag delta.
/// Returns true so callers can early-out.
bool screenFalloffRMBDown(int x, int y) {
    rmbScreenDragActive_ = true;
    rmbScreenDragX0_     = x;
    rmbScreenDragY0_     = y;
    rmbScreenDragR0_     = readScreenFalloffSize();
    pushScreenFalloff(cast(float)x, cast(float)y, rmbScreenDragR0_);
    return true;
}

/// Update radius from the X-axis drag offset, applied as a signed
/// delta on top of the radius captured at RMB-down. The center stays
/// pinned at the click location. Clamps to ≥1 px so the disc never
/// inverts.
void screenFalloffRMBMotion(int x) {
    if (!rmbScreenDragActive_) return;
    float r = rmbScreenDragR0_ + cast(float)(x - rmbScreenDragX0_);
    if (r < 1.0f) r = 1.0f;
    pushScreenFalloff(cast(float)rmbScreenDragX0_,
                      cast(float)rmbScreenDragY0_, r);
}

private float readScreenFalloffSize() {
    import toolpipe.stages.falloff : FalloffStage;
    if (g_pipeCtx is null) return 1.0f;
    foreach (s; g_pipeCtx.pipeline.all()) {
        if (s.id() != "falloff") continue;
        auto fs = cast(FalloffStage)s;
        if (fs is null) return 1.0f;
        return fs.screenSize > 1.0f ? fs.screenSize : 1.0f;
    }
    return 1.0f;
}

/// End the gesture. Returns true iff a drag was active (so app.d can
/// suppress lasso commit).
bool screenFalloffRMBUp() {
    if (!rmbScreenDragActive_) return false;
    rmbScreenDragActive_ = false;
    return true;
}

// ---------------------------------------------------------------------------
// Radial-falloff RMB create gesture.
//
// Mirrors prim.sphere's click+drag UX, applied to the falloff stage
// rather than mesh creation:
//
// - plain RMB drag → flat ellipsoid on the most-facing workplane axis
//   pair. plane-normal axis is held at size=0 so radialWeight collapses
//   to a 2D disc on that plane (see `radialWeight` in falloff.d, which
//   skips axes with size ≤ 1e-9).
// - Ctrl+RMB drag → uniform 3D sphere (size.x = size.y = size.z = r,
//   r = distance from click to cursor along the same drag plane).
//
// Like screen-falloff RMB, lives at module scope so any tool with
// radial falloff inherits the gesture. app.d's RMB dispatch consults
// `radialFalloffActive()` before falling through to lasso.
// ---------------------------------------------------------------------------
// Two-stage RMB-create state machine, mirroring prim.sphere:
//   Idle → FirstActive (RMB held, dragging in-plane disc radius)
//        → FirstDone   (RMB released; flat disc committed,
//                        awaiting second RMB to set height)
//        → SecondActive (RMB held again, extruding the disc along
//                        the construction-plane normal into a 3D
//                        ellipsoid)
//        → Idle
//
// Ctrl at the first RMB-down skips the two-stage flow — the drag
// directly produces a uniform 3D sphere (FirstActive but with a
// `uniform` flag set), and RMB-up returns to Idle.
private enum RadialStage { Idle, FirstActive, FirstDone, SecondActive }
private RadialStage radialStage_   = RadialStage.Idle;
private bool        rmbRadialUniform_      = false;
private Vec3        rmbRadialCenter_       = Vec3(0, 0, 0);
private Vec3        rmbRadialPlaneN_       = Vec3(0, 1, 0);
private Vec3        rmbRadialFlatSize_     = Vec3(0, 0, 0); // size frozen after first drag
private Vec3        rmbRadialHpn_          = Vec3(1, 0, 0); // height-plane normal (in-plane camera dir)
private Vec3        rmbRadialHeightStart_  = Vec3(0, 0, 0); // hit on height plane at second RMB-down

bool radialFalloffActive() {
    import toolpipe.stages.falloff : FalloffStage;
    if (g_pipeCtx is null) return false;
    foreach (s; g_pipeCtx.pipeline.all()) {
        if (s.id() != "falloff") continue;
        auto fs = cast(FalloffStage)s;
        if (fs is null) return false;
        return fs.type == FalloffType.Radial;
    }
    return false;
}

bool radialFalloffRMBDragging() {
    return radialStage_ == RadialStage.FirstActive
        || radialStage_ == RadialStage.SecondActive;
}

private void pushRadialFalloff(Vec3 center, Vec3 size) {
    if (g_pipeCtx is null) return;
    foreach (s; g_pipeCtx.pipeline.all()) {
        if (s.id() != "falloff") continue;
        auto st = cast(Stage)s;
        st.setAttr("center",
            format("%g,%g,%g", center.x, center.y, center.z));
        st.setAttr("size",
            format("%g,%g,%g", size.x,   size.y,   size.z));
        break;
    }
}

/// Compute the height-drag plane analogous to
/// `MeshSphereTool.setupHeightPlane`: plane through `center`, normal =
/// camera direction projected into the construction plane (= camera
/// dir with its plane-normal component removed). User's screen-
/// vertical mouse motion then projects cleanly onto the construction
/// plane's normal axis.
private Vec3 computeHpn(Vec3 center, Vec3 planeN, const ref Viewport vp) {
    Vec3 toCamera = Vec3(vp.eye.x - center.x,
                         vp.eye.y - center.y,
                         vp.eye.z - center.z);
    float dProj = dot(toCamera, planeN);
    Vec3 inPlane = Vec3(toCamera.x - planeN.x * dProj,
                        toCamera.y - planeN.y * dProj,
                        toCamera.z - planeN.z * dProj);
    float len = sqrt(inPlane.x*inPlane.x + inPlane.y*inPlane.y + inPlane.z*inPlane.z);
    if (len > 1e-6f) return Vec3(inPlane.x/len, inPlane.y/len, inPlane.z/len);
    // Camera looking straight along plane normal — degenerate; pick any
    // vector perpendicular to planeN.
    if (abs(planeN.x) < 0.9f) return Vec3(1, 0, 0);
    return Vec3(0, 1, 0);
}

/// Begin or continue the RMB create gesture. Two-stage by default,
/// matching prim.sphere:
///   - From Idle: pick the most-facing axis of the active workplane
///     (analogue of `MeshSphereTool.choosePlane`), project the click
///     onto the plane through `frame.origin` perpendicular to that
///     axis, seed the falloff at the hit with size 0. Ctrl skips the
///     two-stage flow and goes straight to a uniform 3D sphere drag.
///   - From FirstDone (flat disc already committed): re-project the
///     click onto the height-drag plane; the next motion extrudes
///     the disc along the construction-plane normal.
/// Returns false if the click ray is parallel to the chosen plane
/// (rare degenerate camera angle); state is left untouched so app.d
/// can fall through to its usual RMB lasso.
bool radialFalloffRMBDown(int x, int y, bool ctrl, const ref Viewport vp) {
    if (radialStage_ == RadialStage.FirstDone) {
        // Second-stage RMB. Ctrl here repurposes the existing center
        // for a uniform-radius drag (cursor → all three axes); plain
        // RMB enters height-extrude mode.
        Vec3 dir = screenRay(cast(float)x, cast(float)y, vp);
        Vec3 hit;
        if (ctrl) {
            // Uniform: project onto construction plane through center,
            // use distance as r for all three world axes.
            if (!rayPlaneIntersect(vp.eye, dir, rmbRadialCenter_, rmbRadialPlaneN_, hit))
                return false;
            rmbRadialUniform_     = true;
            rmbRadialHeightStart_ = rmbRadialCenter_;     // unused in uniform path
            radialStage_          = RadialStage.SecondActive;
            return true;
        }
        // Height extrude: project onto the height plane.
        Vec3 hpn = computeHpn(rmbRadialCenter_, rmbRadialPlaneN_, vp);
        if (!rayPlaneIntersect(vp.eye, dir, rmbRadialCenter_, hpn, hit))
            hit = rmbRadialCenter_;
        rmbRadialUniform_     = false;
        rmbRadialHpn_         = hpn;
        rmbRadialHeightStart_ = hit;
        radialStage_          = RadialStage.SecondActive;
        return true;
    }

    // Idle or stale state — start fresh. Pick the most-facing
    // workplane axis as the plane normal.
    WorkplaneFrame frame = pickWorkplaneFrame(vp);
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    float aA = abs(dot(camBack, frame.axis1));
    float aN = abs(dot(camBack, frame.normal));
    float a2 = abs(dot(camBack, frame.axis2));
    Vec3 pn;
    if      (aA >= aN && aA >= a2) pn = frame.axis1;
    else if (aN >= aA && aN >= a2) pn = frame.normal;
    else                           pn = frame.axis2;

    Vec3 dir = screenRay(cast(float)x, cast(float)y, vp);
    Vec3 hit;
    if (!rayPlaneIntersect(vp.eye, dir, frame.origin, pn, hit))
        return false;
    rmbRadialUniform_  = ctrl;
    rmbRadialCenter_   = hit;
    rmbRadialPlaneN_   = pn;
    rmbRadialFlatSize_ = Vec3(0, 0, 0);
    radialStage_       = RadialStage.FirstActive;
    pushRadialFalloff(hit, Vec3(0, 0, 0));
    return true;
}

/// Update center + size from a drag. First-drag uses in-plane distance
/// from center to project onto a flat (or uniform if Ctrl was held)
/// ellipsoid. Second-drag projects onto the height plane and grows
/// the plane-normal axis from the frozen flat-disc base.
void radialFalloffRMBMotion(int x, int y, const ref Viewport vp) {
    if (radialStage_ == RadialStage.FirstActive) {
        Vec3 dir = screenRay(cast(float)x, cast(float)y, vp);
        Vec3 hit;
        if (!rayPlaneIntersect(vp.eye, dir, rmbRadialCenter_, rmbRadialPlaneN_, hit))
            return;
        Vec3 d = Vec3(hit.x - rmbRadialCenter_.x,
                      hit.y - rmbRadialCenter_.y,
                      hit.z - rmbRadialCenter_.z);
        float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        Vec3 size = rmbRadialUniform_
            ? Vec3(r, r, r)
            // Flat disc: r along the two plane axes, 0 along plane
            // normal. Plane normal is cardinal in the common case so
            // |pn.i| ∈ {0, 1} maps cleanly to "this axis is the normal".
            : Vec3(r * (1.0f - abs(rmbRadialPlaneN_.x)),
                   r * (1.0f - abs(rmbRadialPlaneN_.y)),
                   r * (1.0f - abs(rmbRadialPlaneN_.z)));
        pushRadialFalloff(rmbRadialCenter_, size);
        return;
    }
    if (radialStage_ == RadialStage.SecondActive) {
        Vec3 dir = screenRay(cast(float)x, cast(float)y, vp);
        Vec3 hit;
        if (rmbRadialUniform_) {
            // Re-derive all three radii from cursor distance to center
            // (in the construction plane). Replaces the flat disc.
            if (!rayPlaneIntersect(vp.eye, dir, rmbRadialCenter_, rmbRadialPlaneN_, hit))
                return;
            Vec3 d = Vec3(hit.x - rmbRadialCenter_.x,
                          hit.y - rmbRadialCenter_.y,
                          hit.z - rmbRadialCenter_.z);
            float r = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
            pushRadialFalloff(rmbRadialCenter_, Vec3(r, r, r));
            return;
        }
        // Height extrude: project onto height plane, take signed
        // drag-distance along plane normal as the extrude radius;
        // add it to the frozen flat-disc size weighted by |pn[i]|
        // so cardinal pn cleanly grows just the plane-normal axis.
        if (!rayPlaneIntersect(vp.eye, dir, rmbRadialCenter_, rmbRadialHpn_, hit))
            return;
        Vec3 dh = Vec3(hit.x - rmbRadialHeightStart_.x,
                       hit.y - rmbRadialHeightStart_.y,
                       hit.z - rmbRadialHeightStart_.z);
        float h = abs(dot(dh, rmbRadialPlaneN_));
        Vec3 size = Vec3(rmbRadialFlatSize_.x + h * abs(rmbRadialPlaneN_.x),
                         rmbRadialFlatSize_.y + h * abs(rmbRadialPlaneN_.y),
                         rmbRadialFlatSize_.z + h * abs(rmbRadialPlaneN_.z));
        pushRadialFalloff(rmbRadialCenter_, size);
        return;
    }
}

/// End the current stage. FirstActive → FirstDone (snapshot the flat
/// size so the second drag can extrude from it). SecondActive → Idle.
/// Returns true iff a drag was active (so app.d can suppress lasso
/// commit).
bool radialFalloffRMBUp() {
    if (radialStage_ == RadialStage.FirstActive) {
        if (rmbRadialUniform_) {
            // Ctrl-first-drag finishes the sphere outright; no second
            // stage to wait for.
            radialStage_ = RadialStage.Idle;
            return true;
        }
        // Freeze the flat-disc size as the baseline for height extrude.
        // Read it back from the pipeline so we capture exactly what
        // motion last pushed (no need to recompute from the last r).
        if (g_pipeCtx is null) {
            radialStage_ = RadialStage.Idle;
            return true;
        }
        import toolpipe.stages.falloff : FalloffStage;
        foreach (s; g_pipeCtx.pipeline.all()) {
            if (s.id() != "falloff") continue;
            auto fs = cast(FalloffStage)s;
            if (fs !is null) rmbRadialFlatSize_ = fs.size;
            break;
        }
        radialStage_ = RadialStage.FirstDone;
        return true;
    }
    if (radialStage_ == RadialStage.SecondActive) {
        radialStage_ = RadialStage.Idle;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Element-falloff RMB radius gesture (Stage 14.6).
//
// Mirrors screen-falloff's RMB API: RMB-down anchors the gesture at
// the current pickedCenter (and captures the current `dist`); RMB-
// motion remaps cursor distance from the anchor (projected onto a
// camera-facing plane through pickedCenter) to a new `dist`; RMB-up
// ends. The pickedCenter itself isn't relocated by the gesture —
// LMB click-to-pick (ElementMoveTool) owns that. RMB only edits
// the sphere radius around the currently-picked element.
//
// Lives at module scope (like screen / radial) so any tool with
// falloff.element active inherits the gesture. app.d's RMB dispatch
// consults `elementFalloffActive()` after the screen / radial
// checks but before the lasso fallback.
// ---------------------------------------------------------------------------
private bool  rmbElementDragActive_ = false;
private int   rmbElementDragX0_     = 0;
private int   rmbElementDragY0_     = 0;
private float rmbElementDragR0_     = 0.0f;
private Vec3  rmbElementDragAnchor_ = Vec3(0, 0, 0);  // world hit at RMB-down
private Vec3  rmbElementPlaneN_     = Vec3(0, 0, 1);  // camera-back at RMB-down

bool elementFalloffActive() {
    import toolpipe.stages.falloff : FalloffStage;
    if (g_pipeCtx is null) return false;
    foreach (s; g_pipeCtx.pipeline.all()) {
        if (s.id() != "falloff") continue;
        auto fs = cast(FalloffStage)s;
        if (fs is null) return false;
        return fs.type == FalloffType.Element;
    }
    return false;
}

bool elementFalloffRMBDragging() { return rmbElementDragActive_; }

private void pushElementDist(float dist) {
    if (g_pipeCtx is null) return;
    foreach (s; g_pipeCtx.pipeline.all()) {
        if (s.id() != "falloff") continue;
        auto st = cast(Stage)s;
        st.setAttr("dist", format("%g", dist));
        break;
    }
}

private FalloffStageState readElementState() {
    import toolpipe.stages.falloff : FalloffStage;
    FalloffStageState s;
    if (g_pipeCtx is null) return s;
    foreach (st; g_pipeCtx.pipeline.all()) {
        if (st.id() != "falloff") continue;
        auto fs = cast(FalloffStage)st;
        if (fs is null) return s;
        s.pickedCenter = fs.pickedCenter;
        s.dist         = fs.dist;
        break;
    }
    return s;
}

private struct FalloffStageState {
    Vec3  pickedCenter = Vec3(0, 0, 0);
    float dist         = 1.0f;
}

/// Begin RMB-radius gesture. Project the click ray onto a camera-
/// back plane through the current pickedCenter; cache the hit as
/// the anchor and snapshot the current dist as the baseline. Returns
/// true so caller can early-out; false on degenerate camera (ray ∥
/// plane normal — extremely rare).
bool elementFalloffRMBDown(int x, int y, const ref Viewport vp) {
    auto state = readElementState();
    // Construction plane: through pickedCenter, normal = camera-back.
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    Vec3 dir = screenRay(cast(float)x, cast(float)y, vp);
    Vec3 hit;
    if (!rayPlaneIntersect(vp.eye, dir, state.pickedCenter, camBack, hit))
        return false;
    rmbElementDragActive_ = true;
    rmbElementDragX0_     = x;
    rmbElementDragY0_     = y;
    rmbElementDragR0_     = state.dist;
    rmbElementDragAnchor_ = hit;
    rmbElementPlaneN_     = camBack;
    return true;
}

/// Update dist from the cursor's world-space distance to the click
/// anchor on the camera-back plane through pickedCenter. New dist =
/// baseline + signed_world_distance. Clamped to ≥ 1e-4 so the sphere
/// never inverts (and the elementWeight degenerate-radius branch
/// stays out of NaN territory).
void elementFalloffRMBMotion(int x, int y, const ref Viewport vp) {
    if (!rmbElementDragActive_) return;
    auto state = readElementState();
    Vec3 dir = screenRay(cast(float)x, cast(float)y, vp);
    Vec3 hit;
    if (!rayPlaneIntersect(vp.eye, dir, state.pickedCenter,
                           rmbElementPlaneN_, hit))
        return;
    // Signed: +X drag from anchor → grow; −X → shrink (same direction
    // mapping screen-falloff uses, just on a world-space plane).
    Vec3 d = Vec3(hit.x - rmbElementDragAnchor_.x,
                  hit.y - rmbElementDragAnchor_.y,
                  hit.z - rmbElementDragAnchor_.z);
    float wd  = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
    // Direction: rightward screen drag → grow. Compute the screen-X
    // sign of the anchor→hit vector by projecting `d` onto the
    // camera's right vector (view matrix row 0).
    Vec3 camRight = Vec3(vp.view[0], vp.view[4], vp.view[8]);
    float signR   = dot(d, camRight);
    float signed  = (signR >= 0) ? wd : -wd;
    float r = rmbElementDragR0_ + signed;
    if (r < 1e-4f) r = 1e-4f;
    pushElementDist(r);
}

/// End gesture. Returns true iff a drag was active.
bool elementFalloffRMBUp() {
    if (!rmbElementDragActive_) return false;
    rmbElementDragActive_ = false;
    return true;
}
