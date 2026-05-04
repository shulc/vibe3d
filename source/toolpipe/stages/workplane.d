module toolpipe.stages.workplane;

import std.math : sin, cos, PI, abs;
import std.conv : to;
import std.format : format;

import math : Vec3;
import toolpipe.stage    : Stage, TaskCode, ordWork;
import toolpipe.pipeline : ToolState;
import tools.create_common : pickMostFacingPlane;

// ---------------------------------------------------------------------------
// WorkplaneStage — MODO-aligned construction-plane state.
//
// Phase 7.1 of doc/phase7_plan.md. Sits at ordinal LXs_ORD_WORK = 0x30 —
// the first stage in the pipe — so subsequent stages (Snap,
// ActionCenter, …) build on a known plane frame.
//
// State (matches MODO's `workplane.edit` API in `popovers.cfg` /
// `workplane.html`):
//   - `isAuto`   : when true, the plane snaps to the camera-most-facing
//                  world plane via pickMostFacingPlane on every evaluate.
//   - `center`   : translation of the plane origin from the world origin.
//                  MODO `workplane.edit cenX/Y/Z`.
//   - `rotation` : Euler angles in DEGREES, applied as extrinsic XYZ
//                  (R_z * R_y * R_x). MODO `workplane.edit rotX/Y/Z`.
//                  rotation = (0,0,0) ↔ XZ plane, normal = +Y.
//
// Commands `workplane.reset`, `workplane.edit`, `workplane.rotate`,
// `workplane.offset`, `workplane.alignToSelection` mutate this state
// — see source/commands/workplane/.
//
// HTTP setAttr keys (used by the generic tool.pipe.attr machinery):
//   `auto`        : "true" / "false"
//   `cenX/Y/Z`    : float (world units)
//   `rotX/Y/Z`    : float (degrees)
//   `mode`        : convenience preset — "auto" / "worldX" / "worldY"
//                   / "worldZ" — translates to (auto, rotation) values.
// ---------------------------------------------------------------------------
class WorkplaneStage : Stage {
    bool isAuto    = true;
    Vec3 center    = Vec3(0, 0, 0);
    Vec3 rotation  = Vec3(0, 0, 0);   // degrees, extrinsic XYZ

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Work; }
    override string   id()       const                          { return "workplane"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordWork; }

    override void evaluate(ref ToolState state) {
        if (isAuto) {
            auto bp = pickMostFacingPlane(state.view);
            state.workplane.normal = bp.normal;
            state.workplane.axis1  = bp.axis1;
            state.workplane.axis2  = bp.axis2;
            state.workplane.isAuto = true;
            return;
        }
        Vec3 n, a1, a2;
        rotateBasis(rotation, n, a1, a2);
        state.workplane.normal = n;
        state.workplane.axis1  = a1;
        state.workplane.axis2  = a2;
        state.workplane.isAuto = false;
        // Center is intentionally NOT folded into the basis vectors —
        // tools that care about the workplane origin read it separately
        // (via state.workplane.center once we add that field). Phase 7.1
        // only emits orientation since no consumer reads the origin yet.
    }

    override bool setAttr(string name, string value) {
        switch (name) {
            case "auto":
                if      (value == "true"  || value == "1") { isAuto = true;  return true; }
                else if (value == "false" || value == "0") { isAuto = false; return true; }
                return false;
            case "cenX":  center.x   = parseFloat(value); return true;
            case "cenY":  center.y   = parseFloat(value); return true;
            case "cenZ":  center.z   = parseFloat(value); return true;
            case "rotX":  rotation.x = parseFloat(value); isAuto = false; return true;
            case "rotY":  rotation.y = parseFloat(value); isAuto = false; return true;
            case "rotZ":  rotation.z = parseFloat(value); isAuto = false; return true;
            case "mode":
                // Convenience presets — translate enum-style values into
                // (isAuto, rotation) pairs. `worldY` is the default flat
                // XZ plane; `worldX` / `worldZ` are 90° rotations of it.
                switch (value) {
                    case "auto":
                        isAuto = true;
                        rotation = Vec3(0, 0, 0);
                        center   = Vec3(0, 0, 0);
                        return true;
                    case "worldY":
                        isAuto = false;
                        rotation = Vec3(0, 0, 0);
                        return true;
                    case "worldX":
                        isAuto = false;
                        rotation = Vec3(0, 0, -90.0f);
                        return true;
                    case "worldZ":
                        isAuto = false;
                        rotation = Vec3(90.0f, 0, 0);
                        return true;
                    default: return false;
                }
            default: return false;
        }
    }

    override string[2][] listAttrs() const {
        return [
            ["auto",  isAuto ? "true" : "false"],
            ["cenX",  format("%g", center.x)],
            ["cenY",  format("%g", center.y)],
            ["cenZ",  format("%g", center.z)],
            ["rotX",  format("%g", rotation.x)],
            ["rotY",  format("%g", rotation.y)],
            ["rotZ",  format("%g", rotation.z)],
            ["mode",  modeLabel()],
        ];
    }

    /// Reset to default behaviour — auto-snap, world origin, no rotation.
    /// Backs the `workplane.reset` command.
    void reset() {
        isAuto   = true;
        center   = Vec3(0, 0, 0);
        rotation = Vec3(0, 0, 0);
    }

    /// Set absolute center / rotation. Pass NaN for any component to
    /// leave it unchanged (so partial argstrings like `workplane.edit
    /// rotZ:90` work cleanly). Switches isAuto off — any explicit edit
    /// pins the plane.
    void edit(float cx, float cy, float cz, float rx, float ry, float rz) {
        import std.math : isNaN;
        if (!isNaN(cx)) center.x   = cx;
        if (!isNaN(cy)) center.y   = cy;
        if (!isNaN(cz)) center.z   = cz;
        bool rotChanged = false;
        if (!isNaN(rx)) { rotation.x = rx; rotChanged = true; }
        if (!isNaN(ry)) { rotation.y = ry; rotChanged = true; }
        if (!isNaN(rz)) { rotation.z = rz; rotChanged = true; }
        if (rotChanged) isAuto = false;
    }

    /// Add `angle` (degrees) around world axis `axisIdx` (0=X, 1=Y, 2=Z)
    /// to the current rotation. Backs `workplane.rotate`.
    void rotateBy(int axisIdx, float angleDeg) {
        if (axisIdx < 0 || axisIdx > 2) return;
        final switch (axisIdx) {
            case 0: rotation.x += angleDeg; break;
            case 1: rotation.y += angleDeg; break;
            case 2: rotation.z += angleDeg; break;
        }
        isAuto = false;
    }

    /// Add `dist` (world units) to the center along axis `axisIdx`.
    /// Backs `workplane.offset`.
    void offsetBy(int axisIdx, float dist) {
        if (axisIdx < 0 || axisIdx > 2) return;
        final switch (axisIdx) {
            case 0: center.x += dist; break;
            case 1: center.y += dist; break;
            case 2: center.z += dist; break;
        }
    }

    /// Set the basis directly (used by `workplane.alignToSelection` to
    /// apply a computed orientation without going through Euler decompo
    /// — Euler decomposition for arbitrary frames is gimbal-prone).
    /// Stored rotation is left untouched; evaluate() falls back to the
    /// directBasis path when `directBasisActive` is true.
    void setBasis(Vec3 normal, Vec3 axis1, Vec3 axis2, Vec3 newCenter) {
        directNormal = normal;
        directAxis1  = axis1;
        directAxis2  = axis2;
        center       = newCenter;
        directBasisActive = true;
        isAuto = false;
    }

private:
    bool directBasisActive = false;
    Vec3 directNormal;
    Vec3 directAxis1;
    Vec3 directAxis2;

    string modeLabel() const {
        if (isAuto) return "auto";
        if (rotation == Vec3(0, 0, 0)) return "worldY";
        if (rotation == Vec3(0, 0, -90.0f)) return "worldX";
        if (rotation == Vec3(90.0f, 0, 0)) return "worldZ";
        return "custom";
    }

    // Apply Euler XYZ (degrees, extrinsic) to the world axes (X,Y,Z) and
    // return the rotated triple as (normal=Y_rot, axis1=X_rot, axis2=Z_rot).
    void rotateBasis(Vec3 rotDeg, out Vec3 normal, out Vec3 axis1, out Vec3 axis2) const {
        if (directBasisActive) {
            normal = directNormal;
            axis1  = directAxis1;
            axis2  = directAxis2;
            return;
        }
        float rx = cast(float)(rotDeg.x * PI / 180.0);
        float ry = cast(float)(rotDeg.y * PI / 180.0);
        float rz = cast(float)(rotDeg.z * PI / 180.0);
        // R_z * R_y * R_x applied to (1,0,0), (0,1,0), (0,0,1).
        Vec3 ex = rotateXYZ(Vec3(1, 0, 0), rx, ry, rz);
        Vec3 ey = rotateXYZ(Vec3(0, 1, 0), rx, ry, rz);
        Vec3 ez = rotateXYZ(Vec3(0, 0, 1), rx, ry, rz);
        normal = ey;
        axis1  = ex;
        axis2  = ez;
    }

    static Vec3 rotateXYZ(Vec3 v, float rx, float ry, float rz) {
        // X-rotation
        float cy0 = cos(rx), sy0 = sin(rx);
        Vec3 a = Vec3(v.x, cy0 * v.y - sy0 * v.z, sy0 * v.y + cy0 * v.z);
        // Y-rotation
        float cy1 = cos(ry), sy1 = sin(ry);
        Vec3 b = Vec3(cy1 * a.x + sy1 * a.z, a.y, -sy1 * a.x + cy1 * a.z);
        // Z-rotation
        float cz1 = cos(rz), sz1 = sin(rz);
        Vec3 c = Vec3(cz1 * b.x - sz1 * b.y, sz1 * b.x + cz1 * b.y, b.z);
        return c;
    }

    static float parseFloat(string s) {
        return s.length == 0 ? 0.0f : s.to!float;
    }
}
