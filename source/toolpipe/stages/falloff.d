module toolpipe.stages.falloff;

import std.format    : format;
import std.conv      : to;
import std.string    : split, strip;

import math : Vec3;
import toolpipe.stage    : Stage, TaskCode, ordWght;
import toolpipe.pipeline : ToolState;
import toolpipe.packets  : FalloffPacket, FalloffType, FalloffShape, LassoStyle;
import popup_state       : setStatePath;

// ---------------------------------------------------------------------------
// FalloffStage — Phase 7.5 of doc/phase7_plan.md / doc/falloff_plan.md.
// Sits at LXs_ORD_WGHT = 0x90 (after AXIS 0x70, before PINK 0xB0).
//
// Publishes a FalloffPacket with the active type + per-type
// configuration. The actual weight math runs on demand in
// source/falloff.d's `evaluateFalloff()` (called per-vertex during
// transform-tool drags), since per-vertex weight depends on the live
// vertex position which can't be precomputed once per pipeline.
//
// Phase 7.5a (this commit) ships ONLY the `None` type plumbing —
// `type` setAttr round-trips through listAttrs, the packet is
// published with `enabled = false`, and tools see weight = 1.0 from
// the (stub) evaluateFalloff. Subsequent subphases add the actual
// types: 7.5b Linear + Move integration, 7.5c Radial + Rotate / Scale,
// 7.5d Screen, 7.5e Lasso.
//
// HTTP setAttr keys (full set; only `type none` is meaningful in 7.5a):
//   `type`         : "none" / "linear" / "radial" / "screen" / "lasso"
//   `shape`        : "linear" / "easeIn" / "easeOut" / "smooth" / "custom"
//   `start`        : "x,y,z" world-space
//   `end`          : "x,y,z" world-space
//   `center`       : "x,y,z" world-space
//   `size`         : "x,y,z" per-axis ellipsoid radii
//   `screenCx`     : float, window pixels
//   `screenCy`     : float, window pixels
//   `screenSize`   : float, window pixels
//   `transparent`  : "true" / "false"
//   `lassoStyle`   : "freehand" / "rect" / "circle" / "ellipse"
//   `softBorder`   : float, window pixels
//   `in`           : float, custom-shape tangent at t=0
//   `out`          : float, custom-shape tangent at t=1
// ---------------------------------------------------------------------------
class FalloffStage : Stage {
    FalloffType  type        = FalloffType.None;
    FalloffShape shape       = FalloffShape.Smooth;

    Vec3 start  = Vec3(0, 0, 0);
    Vec3 end    = Vec3(0, 1, 0);
    Vec3 center = Vec3(0, 0, 0);
    Vec3 size   = Vec3(1, 1, 1);

    float screenCx     = 0;
    float screenCy     = 0;
    float screenSize   = 64;
    bool  transparent  = false;

    LassoStyle lassoStyle   = LassoStyle.Freehand;
    float[]    lassoPolyX;
    float[]    lassoPolyY;
    float      softBorderPx = 16;

    float in_  = 0.5f;
    float out_ = 0.5f;

    this() { publishState(); }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Wght; }
    override string   id()       const                          { return "falloff"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordWght; }

    override void evaluate(ref ToolState state) {
        state.falloff.enabled      = (type != FalloffType.None);
        state.falloff.type         = type;
        state.falloff.shape        = shape;
        state.falloff.start        = start;
        state.falloff.end          = end;
        state.falloff.center       = center;
        state.falloff.size         = size;
        state.falloff.screenCx     = screenCx;
        state.falloff.screenCy     = screenCy;
        state.falloff.screenSize   = screenSize;
        state.falloff.transparent  = transparent;
        state.falloff.lassoStyle   = lassoStyle;
        state.falloff.lassoPolyX   = lassoPolyX;
        state.falloff.lassoPolyY   = lassoPolyY;
        state.falloff.softBorderPx = softBorderPx;
        state.falloff.in_          = in_;
        state.falloff.out_         = out_;
    }

    override bool setAttr(string name, string value) {
        bool ok = applySetAttr(name, value);
        if (ok) publishState();
        return ok;
    }

    override string[2][] listAttrs() const {
        return [
            ["type",        typeLabel()],
            ["shape",       shapeLabel()],
            ["start",       vec3Str(start)],
            ["end",         vec3Str(end)],
            ["center",      vec3Str(center)],
            ["size",        vec3Str(size)],
            ["screenCx",    format("%g", screenCx)],
            ["screenCy",    format("%g", screenCy)],
            ["screenSize",  format("%g", screenSize)],
            ["transparent", transparent ? "true" : "false"],
            ["lassoStyle",  lassoStyleLabel()],
            ["softBorder",  format("%g", softBorderPx)],
            ["in",          format("%g", in_)],
            ["out",         format("%g", out_)],
        ];
    }

private:
    bool applySetAttr(string name, string value) {
        switch (name) {
            case "type":
                if      (value == "none")   { type = FalloffType.None;   return true; }
                else if (value == "linear") { type = FalloffType.Linear; return true; }
                else if (value == "radial") { type = FalloffType.Radial; return true; }
                else if (value == "screen") { type = FalloffType.Screen; return true; }
                else if (value == "lasso")  { type = FalloffType.Lasso;  return true; }
                return false;
            case "shape":
                if      (value == "linear")  { shape = FalloffShape.Linear;  return true; }
                else if (value == "easeIn")  { shape = FalloffShape.EaseIn;  return true; }
                else if (value == "easeOut") { shape = FalloffShape.EaseOut; return true; }
                else if (value == "smooth")  { shape = FalloffShape.Smooth;  return true; }
                else if (value == "custom")  { shape = FalloffShape.Custom;  return true; }
                return false;
            case "start":  return parseVec3(value, start);
            case "end":    return parseVec3(value, end);
            case "center": return parseVec3(value, center);
            case "size":   return parseVec3(value, size);
            case "screenCx":   screenCx     = parseFloat(value); return true;
            case "screenCy":   screenCy     = parseFloat(value); return true;
            case "screenSize": screenSize   = parseFloat(value); return true;
            case "transparent":
                if      (value == "true"  || value == "1") { transparent = true;  return true; }
                else if (value == "false" || value == "0") { transparent = false; return true; }
                return false;
            case "lassoStyle":
                if      (value == "freehand") { lassoStyle = LassoStyle.Freehand;  return true; }
                else if (value == "rect")     { lassoStyle = LassoStyle.Rectangle; return true; }
                else if (value == "circle")   { lassoStyle = LassoStyle.Circle;    return true; }
                else if (value == "ellipse")  { lassoStyle = LassoStyle.Ellipse;   return true; }
                return false;
            case "softBorder": softBorderPx = parseFloat(value); return true;
            case "in":         in_          = parseFloat(value); return true;
            case "out":        out_         = parseFloat(value); return true;
            default: return false;
        }
    }

    string typeLabel() const {
        final switch (type) {
            case FalloffType.None:   return "none";
            case FalloffType.Linear: return "linear";
            case FalloffType.Radial: return "radial";
            case FalloffType.Screen: return "screen";
            case FalloffType.Lasso:  return "lasso";
        }
    }

    string shapeLabel() const {
        final switch (shape) {
            case FalloffShape.Linear:  return "linear";
            case FalloffShape.EaseIn:  return "easeIn";
            case FalloffShape.EaseOut: return "easeOut";
            case FalloffShape.Smooth:  return "smooth";
            case FalloffShape.Custom:  return "custom";
        }
    }

    string lassoStyleLabel() const {
        final switch (lassoStyle) {
            case LassoStyle.Freehand:  return "freehand";
            case LassoStyle.Rectangle: return "rect";
            case LassoStyle.Circle:    return "circle";
            case LassoStyle.Ellipse:   return "ellipse";
        }
    }

    void publishState() {
        // Drives the status-bar Falloff pulldown (added in 7.5f) — same
        // checked-state convention as the SNAP / ACEN pulldowns.
        setStatePath("falloff/type",  typeLabel());
        setStatePath("falloff/shape", shapeLabel());
        setStatePath("falloff/enabled",
                     type != FalloffType.None ? "true" : "false");
        // Per-type bits — drive the per-row checkmark in the Falloff
        // popup. Mirrors `type == FalloffType.<X>` on / off.
        setStatePath("falloff/types/none",
                     type == FalloffType.None   ? "true" : "false");
        setStatePath("falloff/types/linear",
                     type == FalloffType.Linear ? "true" : "false");
        setStatePath("falloff/types/radial",
                     type == FalloffType.Radial ? "true" : "false");
        setStatePath("falloff/types/screen",
                     type == FalloffType.Screen ? "true" : "false");
        setStatePath("falloff/types/lasso",
                     type == FalloffType.Lasso  ? "true" : "false");
    }

    static float parseFloat(string s) {
        return s.length == 0 ? 0.0f : s.to!float;
    }

    // "x,y,z" → Vec3. Returns false on parse error so setAttr can
    // refuse the change instead of corrupting the field.
    static bool parseVec3(string s, ref Vec3 out_v) {
        auto parts = s.split(",");
        if (parts.length != 3) return false;
        try {
            out_v.x = parts[0].strip.to!float;
            out_v.y = parts[1].strip.to!float;
            out_v.z = parts[2].strip.to!float;
        } catch (Exception) {
            return false;
        }
        return true;
    }

    static string vec3Str(Vec3 v) {
        return format("%g,%g,%g", v.x, v.y, v.z);
    }
}
