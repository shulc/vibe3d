module toolpipe.stages.workplane;

import math : Vec3;
import toolpipe.stage    : Stage, TaskCode, ordWork;
import toolpipe.pipeline : ToolState;
import tools.create_common : pickMostFacingPlane;

// ---------------------------------------------------------------------------
// WorkplaneStage — fills ToolState.workplane based on the active mode.
//
// Phase 7.1 of doc/phase7_plan.md. Sits at ordinal LXs_ORD_WORK = 0x30 —
// the very first stage in the pipe — so subsequent stages (Snap,
// ActionCenter, …) can build on a known plane frame.
//
// Modes:
//   - **auto**     re-runs pickMostFacingPlane (matches today's per-tool
//                  default in BoxTool / Pen / Sphere / etc.)
//   - **worldX**   YZ plane, normal = +X
//   - **worldY**   XZ plane, normal = +Y (the default Y-up convention)
//   - **worldZ**   XY plane, normal = +Z
//
// Future modes from doc/phase7_plan.md (`screen`, `selection`) get
// added here as additional enum values.
// ---------------------------------------------------------------------------
class WorkplaneStage : Stage {
    enum Mode { Auto, WorldX, WorldY, WorldZ }
    Mode mode = Mode.Auto;

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Work; }
    override string   id()       const                          { return "workplane"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordWork; }

    override void evaluate(ref ToolState state) {
        final switch (mode) {
            case Mode.Auto:
                auto bp = pickMostFacingPlane(state.view);
                state.workplane.normal = bp.normal;
                state.workplane.axis1  = bp.axis1;
                state.workplane.axis2  = bp.axis2;
                state.workplane.isAuto = true;
                break;
            case Mode.WorldX:
                state.workplane.normal = Vec3(1, 0, 0);
                state.workplane.axis1  = Vec3(0, 1, 0);
                state.workplane.axis2  = Vec3(0, 0, 1);
                state.workplane.isAuto = false;
                break;
            case Mode.WorldY:
                state.workplane.normal = Vec3(0, 1, 0);
                state.workplane.axis1  = Vec3(1, 0, 0);
                state.workplane.axis2  = Vec3(0, 0, 1);
                state.workplane.isAuto = false;
                break;
            case Mode.WorldZ:
                state.workplane.normal = Vec3(0, 0, 1);
                state.workplane.axis1  = Vec3(1, 0, 0);
                state.workplane.axis2  = Vec3(0, 1, 0);
                state.workplane.isAuto = false;
                break;
        }
    }

    override bool setAttr(string name, string value) {
        if (name != "mode") return false;
        switch (value) {
            case "auto":   mode = Mode.Auto;   return true;
            case "worldX": mode = Mode.WorldX; return true;
            case "worldY": mode = Mode.WorldY; return true;
            case "worldZ": mode = Mode.WorldZ; return true;
            default: return false;
        }
    }

    override string[2][] listAttrs() const {
        string modeStr;
        final switch (mode) {
            case Mode.Auto:   modeStr = "auto";   break;
            case Mode.WorldX: modeStr = "worldX"; break;
            case Mode.WorldY: modeStr = "worldY"; break;
            case Mode.WorldZ: modeStr = "worldZ"; break;
        }
        return [["mode", modeStr]];
    }
}
