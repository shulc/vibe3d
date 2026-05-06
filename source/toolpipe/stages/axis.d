module toolpipe.stages.axis;

import std.format : format;
import std.math   : abs;

import math    : Vec3, Viewport;
import toolpipe.stage    : Stage, TaskCode, ordAxis;
import toolpipe.pipeline : ToolState;
import popup_state       : setStatePath;

// ---------------------------------------------------------------------------
// AxisStage — phase 7.2c. Sits at LXs_ORD_AXIS = 0x70 (after ACEN).
// Replaces TransformTool.currentBasis() — Move/Rotate/Scale read their
// gizmo orientation from state.axis instead of querying WorkplaneStage
// directly. Default mode=Auto reproduces the same basis as before
// (workplane when non-auto, pickMostFacingPlane fallback otherwise),
// so existing tool behaviour is preserved.
//
// Modes (mirror MODO `cmdhelptools.cfg` `axis.<X>` and `actr.<X>`):
//   - Auto       — same as Workplane if WorkplaneStage non-auto, else
//                  pickMostFacingPlane(view) (camera-snapped world axis
//                  triple). Matches MODO docs "axis aligned to World OR
//                  Work Plane".
//   - World      — identity (right=+X, up=+Y, fwd=+Z).
//   - Workplane  — workplane.axis1/normal/axis2 from upstream WORK
//                  stage. Mapping: right=axis1, up=normal, fwd=axis2
//                  (per phase7_2_plan §6 — Y-up convention).
//   - Select / SelectAuto / Element / Local / Origin / Screen / Manual
//                  stubbed (degrade to Auto until 7.2d/7.2e/7.2f land).
//
// AxisPacket layout: right / up / fwd (forward); axIndex hint stays at
// -1 in 7.2 — populated when an axis-locked tool needs the principal
// axis index (out of scope for 7.2).
// ---------------------------------------------------------------------------
class AxisStage : Stage {
    enum Mode {
        Auto       = 0,
        World      = 1,
        Workplane  = 2,
        Select     = 3,    // 7.2d
        SelectAuto = 4,    // 7.2d
        Element    = 5,    // 7.2d
        Local      = 6,    // 7.2e
        Origin     = 7,    // alias of World — rotates around (0,0,0) axes
        Screen     = 8,    // camera-aligned (7.2 follow-up)
        Manual     = 9,    // user-pinned right/up/fwd (7.2 follow-up)
    }

    Mode mode = Mode.Auto;
    Vec3 manualRight = Vec3(1, 0, 0);
    Vec3 manualUp    = Vec3(0, 1, 0);
    Vec3 manualFwd   = Vec3(0, 0, 1);
    int  axIndex     = -1;

private:
    // Cached upstream view + workplane — Auto mode in absence of an
    // active workplane needs the camera direction; Screen mode (when
    // it lands) needs the same.
    Viewport lastView_;
    Vec3     lastWpAxis1_  = Vec3(1, 0, 0);
    Vec3     lastWpNormal_ = Vec3(0, 1, 0);
    Vec3     lastWpAxis2_  = Vec3(0, 0, 1);
    bool     lastWpIsAuto_ = true;

public:
    this() { publishState(); }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Axis; }
    override string   id()       const                          { return "axis"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordAxis; }

    override void evaluate(ref ToolState state) {
        lastView_      = state.view;
        lastWpAxis1_   = state.workplane.axis1;
        lastWpNormal_  = state.workplane.normal;
        lastWpAxis2_   = state.workplane.axis2;
        lastWpIsAuto_  = state.workplane.isAuto;
        Vec3 r, u, f;
        computeBasis(r, u, f);
        state.axis.right   = r;
        state.axis.up      = u;
        state.axis.fwd     = f;
        state.axis.axIndex = axIndex;
        state.axis.type    = cast(int)mode;
        state.axis.isAuto  = (mode == Mode.Auto);
    }

    override bool setAttr(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    override string[2][] listAttrs() const {
        Vec3 r, u, f;
        currentBasis(r, u, f);
        return [
            ["mode",   modeLabel()],
            ["rightX", format("%g", r.x)], ["rightY", format("%g", r.y)], ["rightZ", format("%g", r.z)],
            ["upX",    format("%g", u.x)], ["upY",    format("%g", u.y)], ["upZ",    format("%g", u.z)],
            ["fwdX",   format("%g", f.x)], ["fwdY",   format("%g", f.y)], ["fwdZ",   format("%g", f.z)],
        ];
    }

    /// Snapshot-friendly basis read for callers outside the pipeline
    /// (e.g. listAttrs / property panel). Uses last-cached upstream
    /// values when called between evaluate() passes.
    void currentBasis(out Vec3 right, out Vec3 up, out Vec3 fwd) const {
        computeBasis(right, up, fwd);
    }

private:
    void computeBasis(out Vec3 r, out Vec3 u, out Vec3 f) const {
        final switch (mode) {
            case Mode.World:
            case Mode.Origin:
                r = Vec3(1, 0, 0); u = Vec3(0, 1, 0); f = Vec3(0, 0, 1);
                return;
            case Mode.Workplane: {
                Vec3 a1, n, a2;
                if (queryWorkplaneBasis(a1, n, a2)) {
                    r = a1; u = n; f = a2;
                } else {
                    // No WorkplaneStage registered or it's auto-mode
                    // without a recent evaluate — fall back to last
                    // cached values (default identity).
                    r = lastWpAxis1_; u = lastWpNormal_; f = lastWpAxis2_;
                }
                return;
            }
            case Mode.Auto: {
                // Workplane non-auto ⇒ use its basis directly. Auto
                // workplane has no permanent basis until evaluate runs
                // with a viewport — return cached or fall back to
                // identity.
                Vec3 a1, n, a2;
                if (queryWorkplaneBasis(a1, n, a2)) {
                    r = a1; u = n; f = a2;
                } else {
                    r = lastWpAxis1_; u = lastWpNormal_; f = lastWpAxis2_;
                }
                return;
            }
            case Mode.Manual:
                r = manualRight; u = manualUp; f = manualFwd;
                return;
            case Mode.Select:
            case Mode.SelectAuto:
            case Mode.Element:
            case Mode.Local:
            case Mode.Screen:
                // 7.2d / 7.2e / follow-up — degrade to current Auto
                // basis until those subphases land.
                Vec3 a1, n, a2;
                if (queryWorkplaneBasis(a1, n, a2)) {
                    r = a1; u = n; f = a2;
                } else {
                    r = lastWpAxis1_; u = lastWpNormal_; f = lastWpAxis2_;
                }
                return;
        }
    }

    // Look up WorkplaneStage from the global pipe context and read its
    // current basis directly. Returns false if no WorkplaneStage is
    // registered OR it's in auto-mode (auto-mode basis is camera-derived
    // — only available during evaluate()). True path lets listAttrs and
    // out-of-pipeline callers see the live workplane basis without
    // running a full pipe.evaluate().
    bool queryWorkplaneBasis(out Vec3 axis1, out Vec3 normal, out Vec3 axis2) const {
        import toolpipe.pipeline       : g_pipeCtx;
        import toolpipe.stages.workplane : WorkplaneStage;
        if (g_pipeCtx is null) return false;
        auto wp = cast(WorkplaneStage)g_pipeCtx.pipeline.findByTask(TaskCode.Work);
        if (wp is null || wp.isAuto) return false;
        wp.currentBasis(normal, axis1, axis2);
        return true;
    }

    bool applySetAttr(string name, string value) {
        switch (name) {
            case "mode": {
                Mode m;
                if      (value == "auto")       m = Mode.Auto;
                else if (value == "world")      m = Mode.World;
                else if (value == "workplane")  m = Mode.Workplane;
                else if (value == "select")     m = Mode.Select;
                else if (value == "selectauto") m = Mode.SelectAuto;
                else if (value == "element")    m = Mode.Element;
                else if (value == "local")      m = Mode.Local;
                else if (value == "origin")     m = Mode.Origin;
                else if (value == "screen")     m = Mode.Screen;
                else if (value == "manual")     m = Mode.Manual;
                else return false;
                mode = m;
                return true;
            }
            default: return false;
        }
    }

    string modeLabel() const {
        final switch (mode) {
            case Mode.Auto:       return "auto";
            case Mode.World:      return "world";
            case Mode.Workplane:  return "workplane";
            case Mode.Select:     return "select";
            case Mode.SelectAuto: return "selectauto";
            case Mode.Element:    return "element";
            case Mode.Local:      return "local";
            case Mode.Origin:     return "origin";
            case Mode.Screen:     return "screen";
            case Mode.Manual:     return "manual";
        }
    }

    void publishState() {
        setStatePath("axis/mode", modeLabel());
    }
}
