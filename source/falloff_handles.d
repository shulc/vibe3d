module falloff_handles;

import bindbc.sdl;

import handler : Arrow, BoxHandler, Handler, ToolHandles, gizmoSize;
import math   : Vec3, Viewport, projectToWindowFull, closestOnSegment2D, dot;
import viewport_scheme : axisColor, schemeColor, SchemeColor;
import shader : Shader;
import drag   : screenAxisDelta, planeDragDelta, haulWorldPerPixel;
import toolpipe.packets  : FalloffPacket, FalloffType;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.stage    : TaskCode;
import toolpipe.stages.falloff : FalloffStage;
import tools.create.create_common : screenToConstructionPlane,
                                    ConstructionPlaneMode;

import std.format : format;
import std.math   : sqrt, abs;

// Resolve the PRIMARY falloff (WGHT) stage — the same "first WGHT-task
// stage" the pipeline registers before any `falloff.add` extras. Every
// interactive gizmo / RMB-gesture site in this module addresses only the
// primary (stacked "falloff#N" extras are edited exclusively via
// `tool.pipe.attr falloff#N <attr>`, not the viewport handles), so this one
// helper replaces the ~13 hand-rolled `foreach (...) { if (s.id() !=
// "falloff") continue; ...; break; }` pipeline walks. Null-safe (returns
// null when the pipeline isn't initialised or carries no WGHT stage).
private FalloffStage primaryFalloffStage() {
    if (g_pipeCtx is null) return null;
    return cast(FalloffStage) g_pipeCtx.pipeline.findByTask(TaskCode.Wght);
}

// ---------------------------------------------------------------------------
// FalloffLinearGizmo — interactive draggable handles for linear falloff
// endpoints (start = full influence, end = zero influence).
//
// Each endpoint carries a mini move-tool gizmo: 3 axis arrows (red X /
// green Y / blue Z) for axis-locked drag plus a cyan center box for
// screen-plane drag — same control set MoveHandler exposes for the
// main tool, sized down so it doesn't visually dominate the falloff
// segment. A linear-falloff overlay where each endpoint has the same
// set of axis arrows + box marker.
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
        // The scheme's axis colours, read from the one table rather than
        // copied — these used to be a second set of literals that had to be
        // kept in step with MoveHandler's by hand, and were not.
        arrowX = new Arrow(Vec3(0,0,0), Vec3(1,0,0), axisColor(0));
        arrowY = new Arrow(Vec3(0,0,0), Vec3(0,1,0), axisColor(1));
        arrowZ = new Arrow(Vec3(0,0,0), Vec3(0,0,1), axisColor(2));
        // Axis-less, so the scheme's `handle` colour.
        centerBox = new BoxHandler(Vec3(0,0,0), schemeColor(SchemeColor.handle));
        // Slimmer arrow shafts — secondary control, not the main tool.
        // WINDOW PIXELS. Halved from 2.5f with task 0600's geometry-shader unit
        // fix (see shader.thickLineGeomSrc): the old number rendered 1.25 px,
        // and this one renders the same 1.25 px. Nothing about these handles
        // has been measured against the reference, so their look is held still.
        arrowX.lineWidth = 1.25f;
        arrowY.lineWidth = 1.25f;
        arrowZ.lineWidth = 1.25f;
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
        // vp.eye used as camera position for gizmo-facing direction, NOT as a ray origin.
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

    // Register this endpoint's 4 sub-handles into the shared arbiter at
    // `base`, in hitTest priority order (box first, then arrows). Positions
    // come from the prior draw()'s layout (last-frame geometry), consistent
    // with the gizmo banks.
    void registerHandles(ToolHandles th, int base) {
        th.add(centerBox, base + 3);
        th.add(arrowX,    base + 0);
        th.add(arrowY,    base + 1);
        th.add(arrowZ,    base + 2);
    }

    void draw(const ref Shader shader, const ref Viewport vp) {
        // Highlight is owned by the shared ToolHandles arbiter now (the
        // sub-handles are registered via registerHandles); no self-
        // hover here.
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
            // Six size handles, a ±pair per axis: 0,1 → X, 2,3 → Y, 4,5 → Z.
            sizeH[i] = new BoxHandler(Vec3(0, 0, 0), axisColor(cast(int)i / 2));
        }
    }

    void destroy() {
        startHandle.destroy();
        endHandle.destroy();
        centerHandle.destroy();
        foreach (h; sizeH) h.destroy();
    }

    // Task 0212: CPU-only geometry re-layout, factored out of draw() so it
    // can be re-run (idempotently, no GL side effects) immediately before a
    // Test-pass hit-test resolves against these handles — see
    // PipeGizmoHost.syncGeometry.
    private void layout(const ref Viewport vp, const ref FalloffPacket cfg) {
        if (!cfg.enabled) return;
        if (cfg.type == FalloffType.Linear) {
            startHandle.update(cfg.start, vp);
            endHandle.update  (cfg.end,   vp);
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
            }
        }
    }

    /// Re-lay this gizmo's handles under `vp` with NO draw call — the same
    /// idempotent math `draw()` runs, exposed so a Test-pass hit-test can
    /// refresh geometry ahead of resolving a click/hover (task 0212).
    void syncGeometry(const ref Viewport vp, const ref FalloffPacket cfg) {
        layout(vp, cfg);
    }

    void draw(const ref Shader shader, const ref Viewport vp,
              const ref FalloffPacket cfg)
    {
        if (!cfg.enabled) return;
        layout(vp, cfg);
        if (cfg.type == FalloffType.Linear) {
            startHandle.draw(shader, vp);
            endHandle.draw  (shader, vp);
        } else if (cfg.type == FalloffType.Radial) {
            foreach (i; 0 .. 6) sizeH[i].draw(shader, vp);
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
            if (auto fs = primaryFalloffStage())
                fs.setAttr(attr,
                    format("%g,%g,%g", newPos.x, newPos.y, newPos.z));
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
            if (auto fs = primaryFalloffStage())
                fs.setAttr("center",
                    format("%g,%g,%g", newCenter.x, newCenter.y, newCenter.z));
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
        if (auto fs = primaryFalloffStage())
            fs.setAttr("size",
                format("%g,%g,%g", sz[0], sz[1], sz[2]));
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

    /// Force-release any in-flight endpoint drag without an LMB-up event. The
    /// standalone (tool-less) host calls this when a tool activates mid-drag —
    /// otherwise isDragging() would stay latched and a later tool-less motion
    /// would move an endpoint with no fresh grab.
    void cancelDrag() nothrow { activeLinear = -1; activeRadial = -1; }

    // Register the active falloff handles into the shared arbiter at `base`
    // so they join the single-winner pool. Part layout (mutually exclusive
    // by mode, so no clash): Linear start = base+0..3, end = base+10..13;
    // Radial center = base+0..3, size handles = base+20..25.
    void registerHandles(ToolHandles th, int base, const ref FalloffPacket cfg) {
        if (!cfg.enabled) return;
        if (cfg.type == FalloffType.Linear) {
            startHandle.registerHandles(th, base + 0);
            endHandle.registerHandles  (th, base + 10);
        } else if (cfg.type == FalloffType.Radial) {
            centerHandle.registerHandles(th, base + 0);
            foreach (i; 0 .. 6) th.add(sizeH[i], base + 20 + cast(int)i);
        }
    }

    // Global part id of the falloff handle currently being hauled (offset by
    // `base`), or -1 when no falloff drag is live — lets the host arbiter
    // keep the dragged handle highlighted (setHaul). Mirrors the part layout
    // in registerHandles.
    int capturedPart(int base) {
        if (activeLinear == 0) return base + 0  + startHandle.dragAxis;
        if (activeLinear == 1) return base + 10 + endHandle.dragAxis;
        if (activeRadial == 0) return base + 0  + centerHandle.dragAxis;
        if (activeRadial >= 1) return base + 20 + (activeRadial - 1);
        return -1;
    }
}

// ---------------------------------------------------------------------------
// Falloff RMB gestures.
//
// The falloff kinds intentionally split into three independent disciplines:
// point placement in world space, an absolute integer haul in pixels, and an
// incremental floating-point haul scaled by the view. Kinds outside those
// groups do not claim RMB here, so the ordinary tool/lasso routing remains
// available.
// ---------------------------------------------------------------------------

/// Stable census used by dispatch and by the population test. None means
/// this module does not own an attribute gesture for the kind.
enum FalloffRMBDiscipline : ubyte {
    None,
    Point3D,
    AbsoluteInteger,
    IncrementalFloat,
}

FalloffRMBDiscipline falloffRMBDiscipline(FalloffType type) pure nothrow {
    final switch (type) {
        case FalloffType.Linear:
        case FalloffType.Radial:
        case FalloffType.Cylinder:
            return FalloffRMBDiscipline.Point3D;

        case FalloffType.Screen:
        case FalloffType.Selection:
            return FalloffRMBDiscipline.AbsoluteInteger;

        case FalloffType.Element:
            return FalloffRMBDiscipline.IncrementalFloat;

        case FalloffType.None:
        case FalloffType.Lasso:
        case FalloffType.Composite:
        case FalloffType.VertexMap:
            return FalloffRMBDiscipline.None;
    }
}

private FalloffType rmbFalloffKind_ = FalloffType.None;
private Vec3 rmbPointAnchor_ = Vec3(0, 0, 0);

private int   rmbAbsoluteX0_       = 0;
private int   rmbAbsoluteY0_       = 0;
private float rmbScreenBase_       = 0.0f;
private float rmbScreenCurrent_    = 0.0f;
private int   rmbSelectionBase_    = 1;
private int   rmbSelectionCurrent_ = 1;

private struct IncrementalFloatTracker {
    int previousX;
    float initialValue;
    float value;
    float unitsPerPixel;

    void begin(int x, float initial, float scale) {
        previousX = x;
        initialValue = initial;
        value = initial;
        unitsPerPixel = scale;
    }

    float track(int x) {
        value += cast(float)(x - previousX) * unitsPerPixel;
        previousX = x;
        return value;
    }
}
private IncrementalFloatTracker rmbElementTracker_;
private enum int kAbsoluteHaulFloor = 1;

// Bracketed by tools that consume screen falloff at LMB-down / LMB-up.
private bool lmbScreenDragActive_ = false;

bool screenFalloffActive() {
    auto fs = primaryFalloffStage();
    return fs !is null && fs.type == FalloffType.Screen;
}

void screenFalloffLMBBegin() { lmbScreenDragActive_ = true;  }
void screenFalloffLMBEnd()   { lmbScreenDragActive_ = false; }

bool screenFalloffOverlayVisible() {
    return rmbFalloffKind_ == FalloffType.Screen || lmbScreenDragActive_;
}

bool elementFalloffOverlayVisible() {
    return rmbFalloffKind_ == FalloffType.Element;
}

private string vecAttr(Vec3 value) {
    return format("%g,%g,%g", value.x, value.y, value.z);
}

private void pushPointAnchor(FalloffType kind, Vec3 anchor) {
    auto st = primaryFalloffStage();
    if (st is null) return;

    final switch (kind) {
        case FalloffType.Linear:
            st.setAttr("end", vecAttr(anchor));
            break;

        case FalloffType.Radial:
        case FalloffType.Cylinder:
            st.setAttr("center", vecAttr(anchor));
            break;

        case FalloffType.None:
        case FalloffType.Screen:
        case FalloffType.Lasso:
        case FalloffType.Element:
        case FalloffType.Selection:
        case FalloffType.Composite:
        case FalloffType.VertexMap:
            break;
    }
}

private void pushPointSize(FalloffType kind, Vec3 anchor, Vec3 delta) {
    auto st = primaryFalloffStage();
    if (st is null) return;

    if (kind == FalloffType.Linear)
        st.setAttr("start", vecAttr(anchor + delta));
    else if (kind == FalloffType.Radial || kind == FalloffType.Cylinder)
        st.setAttr("size", vecAttr(delta));
}

private void pushScreenCenter(int x, int y) {
    auto st = primaryFalloffStage();
    if (st is null) return;
    st.setAttr("screenCx", format("%g", cast(float)x));
    st.setAttr("screenCy", format("%g", cast(float)y));
}

private void pushScreenSize(float size) {
    auto st = primaryFalloffStage();
    if (st !is null) st.setAttr("screenSize", format("%g", size));
}

private float readScreenFalloffSize() {
    auto fs = primaryFalloffStage();
    if (fs is null) return cast(float)kAbsoluteHaulFloor;
    return fs.screenSize > kAbsoluteHaulFloor
        ? fs.screenSize : cast(float)kAbsoluteHaulFloor;
}

private int absoluteHaulDelta(int x, int y) {
    return x - rmbAbsoluteX0_;
}

private Vec3 pointDragDelta(Vec3 current) {
    return current - rmbPointAnchor_;
}

private void pushSelectionSteps(int steps) {
    auto st = primaryFalloffStage();
    if (st !is null) st.setAttr("steps", format("%d", steps));
}

private void pushElementDist(float dist) {
    auto st = primaryFalloffStage();
    if (st !is null) st.setAttr("dist", format("%g", dist));
}

private struct ElementFalloffState {
    Vec3 pickedCenter = Vec3(0, 0, 0);
    float dist = 1.0f;
}

private ElementFalloffState readElementState() {
    import toolpipe.stages.actcenter : ActionCenterStage;

    ElementFalloffState state;
    if (g_pipeCtx is null) return state;
    if (auto fs = primaryFalloffStage())
        state.dist = fs.pickedRadius;
    if (auto ac = cast(ActionCenterStage)
            g_pipeCtx.pipeline.findByTask(TaskCode.Acen))
        state.pickedCenter = ac.currentCenter();
    return state;
}

/// Push only the center of a screen falloff. Transform tools use this for
/// their LMB grabs as well as the shared RMB dispatcher below.
void screenFalloffSetCenter(int x, int y) {
    pushScreenCenter(x, y);
}

/// Start the active kind's RMB discipline. The gesture deliberately owns the
/// whole viewport; whether a kind requires a handle hit is not established.
bool falloffRMBDown(int x, int y, const ref Viewport vp) {
    auto st = primaryFalloffStage();
    if (st is null) return false;

    FalloffRMBDiscipline discipline = falloffRMBDiscipline(st.type);
    if (discipline == FalloffRMBDiscipline.None) return false;

    rmbFalloffKind_ = st.type;
    final switch (discipline) {
        case FalloffRMBDiscipline.Point3D:
            rmbPointAnchor_ = screenToConstructionPlane(
                cast(float)x, cast(float)y, vp,
                ConstructionPlaneMode.activeWorkplane);
            pushPointAnchor(rmbFalloffKind_, rmbPointAnchor_);
            pushPointSize(rmbFalloffKind_, rmbPointAnchor_, Vec3(0, 0, 0));
            return true;

        case FalloffRMBDiscipline.AbsoluteInteger:
            rmbAbsoluteX0_ = x;
            rmbAbsoluteY0_ = y;
            if (rmbFalloffKind_ == FalloffType.Screen) {
                rmbScreenBase_ = readScreenFalloffSize();
                rmbScreenCurrent_ = rmbScreenBase_;
                pushScreenCenter(x, y);
                pushScreenSize(rmbScreenCurrent_);
            } else {
                rmbSelectionBase_ = st.steps >= kAbsoluteHaulFloor
                    ? st.steps : kAbsoluteHaulFloor;
                rmbSelectionCurrent_ = rmbSelectionBase_;
            }
            return true;

        case FalloffRMBDiscipline.IncrementalFloat:
            auto state = readElementState();
            rmbElementTracker_.begin(
                x, state.dist, haulWorldPerPixel(state.pickedCenter, vp));
            return true;

        case FalloffRMBDiscipline.None:
            return false;
    }
}

/// Apply one motion event according to the discipline latched at the press.
void falloffRMBMotion(int x, int y, const ref Viewport vp) {
    final switch (falloffRMBDiscipline(rmbFalloffKind_)) {
        case FalloffRMBDiscipline.Point3D:
            Vec3 current = screenToConstructionPlane(
                cast(float)x, cast(float)y, vp,
                ConstructionPlaneMode.activeWorkplane);
            Vec3 delta = pointDragDelta(current);
            pushPointSize(rmbFalloffKind_, rmbPointAnchor_, delta);
            break;

        case FalloffRMBDiscipline.AbsoluteInteger:
            if (rmbFalloffKind_ == FalloffType.Screen) {
                // The existing screen law is intentionally unchanged: X only,
                // one size unit per pixel, with a floor of one.
                rmbScreenCurrent_ =
                    rmbScreenBase_ + cast(float)absoluteHaulDelta(x, y);
                if (rmbScreenCurrent_ < kAbsoluteHaulFloor)
                    rmbScreenCurrent_ = cast(float)kAbsoluteHaulFloor;
                pushScreenCenter(rmbAbsoluteX0_, rmbAbsoluteY0_);
                pushScreenSize(rmbScreenCurrent_);
            } else {
                rmbSelectionCurrent_ =
                    rmbSelectionBase_ + absoluteHaulDelta(x, y);
                if (rmbSelectionCurrent_ < kAbsoluteHaulFloor)
                    rmbSelectionCurrent_ = kAbsoluteHaulFloor;
                pushSelectionSteps(rmbSelectionCurrent_);
            }
            break;

        case FalloffRMBDiscipline.IncrementalFloat:
            float dist = rmbElementTracker_.track(x);
            if (dist < 0.0f) dist = 0.0f;
            pushElementDist(dist);
            break;

        case FalloffRMBDiscipline.None:
            break;
    }
}

bool falloffRMBDragging() {
    return falloffRMBDiscipline(rmbFalloffKind_)
        != FalloffRMBDiscipline.None;
}

/// Finish a claimed gesture. Selection repeats its final integer at release;
/// Screen retains its existing delivery boundary until that change is owned.
bool falloffRMBUp() {
    if (!falloffRMBDragging()) return false;

    if (rmbFalloffKind_ == FalloffType.Selection)
        pushSelectionSteps(rmbSelectionCurrent_);

    rmbFalloffKind_ = FalloffType.None;
    return true;
}
