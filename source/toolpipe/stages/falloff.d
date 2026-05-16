module toolpipe.stages.falloff;

import std.format    : format;
import std.conv      : to;
import std.string    : split, strip;
import std.math      : abs;

import math : Vec3, Viewport, dot, projectToWindowFull;
import std.math : sqrt;
import mesh : Mesh;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordWght;
import toolpipe.pipeline : ToolState, g_pipeCtx;
import toolpipe.packets  : FalloffPacket, FalloffType, FalloffShape, LassoStyle;
import toolpipe.stages.workplane : WorkplaneStage;
import popup_state       : setStatePath;
import params            : Param, ParamHints, IntEnumEntry;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import imgui_style       : pushPopupStyle, popPopupStyle;

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
    Vec3 normal = Vec3(0, 1, 0);    // cylinder axis (default +Y, matches MODO xfrm.vortex)
    // Element falloff (Stage 14.1): sphere centred on the picked
    // element's centroid with radius `dist`. ElementMoveTool writes
    // `pickedCenter` on LMB-down; user can override either field via
    // `tool.pipe.attr falloff {pickedCenter|dist} <value>`.
    Vec3  pickedCenter = Vec3(0, 0, 0);
    float dist         = 1.0f;

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

    // Optional refs for auto-size on `setAttr("type", ...)`. Phase 7.5a
    // shipped without them (None type doesn't auto-size); 7.5b wires
    // them in app.d's initToolPipe so Linear / Radial / Screen / Lasso
    // can pre-fit to the active selection. nullable: unit tests that
    // bypass the app-level wiring still work; auto-size becomes a
    // no-op.
    private Mesh*     mesh_;
    private EditMode* editMode_;

    // Last workplane normal cached at evaluate(). Used by autoSize() to
    // orient Linear's start→end along the construction-plane normal —
    // matches MODO's "the line stands up out of the work plane"
    // convention.
    private Vec3 lastWpNormal_ = Vec3(0, 1, 0);

    // Last viewport cached at evaluate(). Used by autoSize() for Screen
    // type to project the selection bbox centroid into window pixels.
    // Default-init produces a degenerate viewport — autoSize() guards
    // against that with a "did we ever evaluate?" flag.
    private Viewport lastVp_;
    private bool     lastVpValid_ = false;

    this(Mesh* mesh = null, EditMode* editMode = null) {
        this.mesh_     = mesh;
        this.editMode_ = editMode;
        publishState();
    }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Wght; }
    override string   id()       const                          { return "falloff"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordWght; }

    /// Restore every mutable field to its declaration-time default.
    /// Invoked by SceneReset (= `/api/reset`) so a "start fresh" wipes
    /// the falloff config along with the mesh.
    override void reset() {
        type         = FalloffType.None;
        shape        = FalloffShape.Smooth;
        start        = Vec3(0, 0, 0);
        end          = Vec3(0, 1, 0);
        center       = Vec3(0, 0, 0);
        size         = Vec3(1, 1, 1);
        screenCx     = 0;
        screenCy     = 0;
        screenSize   = 64;
        transparent  = false;
        lassoStyle   = LassoStyle.Freehand;
        lassoPolyX.length = 0;
        lassoPolyY.length = 0;
        softBorderPx = 16;
        in_          = 0.5f;
        out_         = 0.5f;
        publishState();
    }

    override void evaluate(ref ToolState state) {
        // WORK stage has run before us (ord 0x30 < ord 0x90), so
        // state.workplane is populated. Cache its normal so autoSize()
        // (called from setAttr) can run without re-walking the pipe.
        lastWpNormal_              = state.workplane.normal;
        lastVp_                    = state.view;
        lastVpValid_               = true;
        state.falloff.enabled      = (type != FalloffType.None);
        state.falloff.type         = type;
        state.falloff.shape        = shape;
        state.falloff.start        = start;
        state.falloff.end          = end;
        state.falloff.center       = center;
        state.falloff.size         = size;
        state.falloff.normal       = normal;
        state.falloff.pickedCenter = pickedCenter;
        state.falloff.pickedRadius = dist;
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
        FalloffType prev = type;
        bool ok = applySetAttr(name, value);
        if (ok) {
            // MODO convention: switching the falloff type while a
            // tool is active auto-sizes the new falloff to the
            // current selection's bbox. Mirrors selection_falloffs
            // .html: "the act of simply selecting the falloff type
            // automatically scales the falloff to the bounding box
            // size of the active selection". Only fires on a real
            // type change (not no-op set-to-current); the user can
            // still manually re-tune attrs after auto-size.
            if (name == "type" && type != prev && type != FalloffType.None)
                autoSize();
            publishState();
        }
        return ok;
    }

    override string[2][] listAttrs() const {
        return [
            ["type",         typeLabel()],
            ["shape",        shapeLabel()],
            ["start",        vec3Str(start)],
            ["end",          vec3Str(end)],
            ["center",       vec3Str(center)],
            ["size",         vec3Str(size)],
            ["axis",         vec3Str(normal)],
            ["pickedCenter", vec3Str(pickedCenter)],
            ["dist",         format("%g", dist)],
            ["screenCx",     format("%g", screenCx)],
            ["screenCy",     format("%g", screenCy)],
            ["screenSize",   format("%g", screenSize)],
            ["transparent",  transparent ? "true" : "false"],
            ["lassoStyle",   lassoStyleLabel()],
            ["lassoPoly",    lassoPolyStr()],
            ["softBorder",   format("%g", softBorderPx)],
            ["in",           format("%g", in_)],
            ["out",          format("%g", out_)],
        ];
    }

    string lassoPolyStr() const {
        if (lassoPolyX.length == 0) return "";
        string s = format("%g,%g", lassoPolyX[0], lassoPolyY[0]);
        foreach (i; 1 .. lassoPolyX.length)
            s ~= format(";%g,%g", lassoPolyX[i], lassoPolyY[i]);
        return s;
    }

    // ------------------------------------------------------------------
    // Phase 7.9: Param[] schema for the Tool Properties panel. PropertyPanel
    // writes new values directly through the typed pointers in each Param;
    // onParamChanged() below mirrors the side-effects of setAttr (autoSize
    // on type change, publishState on every change) so the UI path produces
    // the same observable behaviour as the HTTP `tool.pipe.attr` path.
    //
    // Lasso polygon (lassoPolyX/Y arrays) isn't exposed here — there's no
    // single-line widget for it; users edit the lasso via direct viewport
    // gesture, not numeric input. setAttr still accepts "lassoPoly" via
    // the `applySetAttr` switch above.
    // ------------------------------------------------------------------
    override Param[] params() {
        // No active falloff → expose no schema, so the Tool Properties
        // iteration in app.d hides the section entirely (type=None
        // means falloff isn't modulating anything; no useful config
        // to show). The status-bar pulldown still controls type.
        // Falloff's own setAttr override below handles HTTP attr writes
        // independently of this list.
        if (type == FalloffType.None) return [];

        // Type selection lives in the status-bar Falloff pulldown, NOT
        // the Tool Properties panel — switching type in the panel
        // would conflict with auto-size + setStatePath flow that the
        // status pulldown owns. Tool Properties only exposes the
        // CONFIG of the active type.
        //
        // Filter params() per active type so the panel shows ONLY
        // type-relevant fields (start/end for Linear, center/size for
        // Radial, etc.) — irrelevant fields are hidden, not greyed.
        // HTTP `tool.pipe.attr falloff <attr>` still works for any
        // attr regardless of active type because FalloffStage's own
        // setAttr override (below) covers them all independently.
        IntEnumEntry[] lassoEntries = [
            IntEnumEntry(cast(int)LassoStyle.Freehand,  "freehand", "Freehand"),
            IntEnumEntry(cast(int)LassoStyle.Rectangle, "rect",     "Rectangle"),
            IntEnumEntry(cast(int)LassoStyle.Circle,    "circle",   "Circle"),
            IntEnumEntry(cast(int)LassoStyle.Ellipse,   "ellipse",  "Ellipse"),
        ];

        Param[] ps;
        // Shape preset is rendered via drawProperties() as a status-bar-
        // style popup-button (matches MODO's visual language); kept out
        // of the schema list. HTTP `tool.pipe.attr falloff shape <v>`
        // still works through FalloffStage's setAttr override.
        // In/Out tangent params are Custom-shape-only.
        if (shape == FalloffShape.Custom) {
            ps ~= Param.float_("in",  "In",  &in_,  0.5f).min(0.0f).max(1.0f)
                       .widget(ParamHints.Widget.Slider);
            ps ~= Param.float_("out", "Out", &out_, 0.5f).min(0.0f).max(1.0f)
                       .widget(ParamHints.Widget.Slider);
        }
        // Per-type geometry config.
        final switch (type) {
            case FalloffType.None:
                break;   // unreachable due to early-return above
            case FalloffType.Linear:
                ps ~= Param.vec3_("start", "Start", &start, Vec3(0, 0, 0));
                ps ~= Param.vec3_("end",   "End",   &end,   Vec3(0, 1, 0));
                break;
            case FalloffType.Radial:
                ps ~= Param.vec3_("center", "Center", &center, Vec3(0, 0, 0));
                ps ~= Param.vec3_("size",   "Size",   &size,   Vec3(1, 1, 1));
                break;
            case FalloffType.Screen:
                ps ~= Param.float_("screenCx",   "Screen Cx",   &screenCx,   0.0f);
                ps ~= Param.float_("screenCy",   "Screen Cy",   &screenCy,   0.0f);
                ps ~= Param.float_("screenSize", "Screen Size", &screenSize, 64.0f);
                ps ~= Param.bool_ ("transparent", "Transparent", &transparent, false);
                break;
            case FalloffType.Lasso:
                ps ~= Param.intEnum_("lassoStyle", "Lasso Style",
                                     cast(int*)&lassoStyle, lassoEntries,
                                     cast(int)LassoStyle.Freehand);
                ps ~= Param.float_("softBorder", "Soft Border", &softBorderPx, 16.0f);
                break;
            case FalloffType.Cylinder:
                ps ~= Param.vec3_("center", "Center", &center, Vec3(0, 0, 0));
                ps ~= Param.vec3_("size",   "Size",   &size,   Vec3(1, 1, 1));
                ps ~= Param.vec3_("axis",   "Axis",   &normal, Vec3(0, 1, 0));
                break;
            case FalloffType.Element:
                ps ~= Param.vec3_("pickedCenter", "Picked Center",
                                  &pickedCenter, Vec3(0, 0, 0));
                ps ~= Param.float_("dist", "Range", &dist, 1.0f).min(1e-6f);
                break;
        }
        return ps;
    }

    override void onParamChanged(string name) {
        // Mirror setAttr's side-effects so PropertyPanel (which writes
        // through the typed pointer directly, bypassing setAttr's
        // string-parse path) still triggers autoSize on type changes
        // and publishes state for the status-bar pulldown.
        // autoSize is a no-op for type=None; cheap to call always on
        // type change without prev-value tracking.
        if (name == "type" && type != FalloffType.None)
            autoSize();
        publishState();
    }

    override string displayName() const {
        // Header label baked from active type — mirrors MODO's
        // "Linear Falloff" / "Radial Falloff" section titles. The
        // status-bar Falloff pulldown owns type selection; the Tool
        // Properties section reflects whichever type is active.
        final switch (type) {
            case FalloffType.None:     return "Falloff";
            case FalloffType.Linear:   return "Linear Falloff";
            case FalloffType.Radial:   return "Radial Falloff";
            case FalloffType.Screen:   return "Screen Falloff";
            case FalloffType.Lasso:    return "Lasso Falloff";
            case FalloffType.Cylinder: return "Cylinder Falloff";
            case FalloffType.Element:  return "Element Falloff";
        }
    }

    override void drawProperties() {
        if (type == FalloffType.None) return;

        // Shape popup-button — matches the status-bar Falloff pulldown
        // visual (button face shows current shape, click opens popup
        // with checkmarks). Standard ImGui.Combo would render a
        // chevron; the bare button keeps the Tool Properties panel
        // visually consistent with the status row. pushPopupStyle()
        // applies the same LightWave grey / beige hover / flat black
        // border the status-bar popups use (imgui_style.d).
        static immutable string[5] shapeUiLabels = [
            "Linear", "Ease-In", "Ease-Out", "Smooth", "Custom",
        ];
        string buttonLabel = "Shape: " ~ shapeUiLabels[cast(int)shape];
        if (ImGui.Button(buttonLabel))
            ImGui.OpenPopup("##falloffShapePopup");
        // Push BEFORE BeginPopup — PopupBg / PopupRounding / PopupBorder
        // must be set when the popup window is created. Pop after
        // (regardless of whether BeginPopup returned true) so Push/Pop
        // stays balanced even when the popup isn't open this frame.
        pushPopupStyle();
        if (ImGui.BeginPopup("##falloffShapePopup")) {
            foreach (i; 0 .. 5) {
                bool selected = (cast(int)shape == cast(int)i);
                if (ImGui.MenuItem(shapeUiLabels[i], "", selected)) {
                    shape = cast(FalloffShape)i;
                    publishState();
                }
            }
            ImGui.EndPopup();
        }
        popPopupStyle();

        // Auto-size + Reverse: Linear-only (operate on start/end). For
        // Radial / Screen / Lasso the analogous "fit to selection" is
        // already covered by autoSize() called on type-switch — no
        // separate per-axis variant makes sense.
        if (type != FalloffType.Linear) return;
        ImGui.Text("Auto size:");
        ImGui.SameLine();
        if (ImGui.Button("X##fAuto")) { autoSizeAxis(0); publishState(); }
        ImGui.SameLine();
        if (ImGui.Button("Y##fAuto")) { autoSizeAxis(1); publishState(); }
        ImGui.SameLine();
        if (ImGui.Button("Z##fAuto")) { autoSizeAxis(2); publishState(); }
        if (ImGui.Button("Reverse")) {
            Vec3 t = start; start = end; end = t;
            publishState();
        }
    }

    /// Fit the Linear-falloff start/end through the selection bbox
    /// centre along world axis `axis` (0/1/2 = X/Y/Z), with length =
    /// bbox extent along that axis. Mirrors the existing autoSize()
    /// for Linear but takes the axis explicitly instead of using the
    /// current workplane normal — surfaces the per-axis Auto Size
    /// buttons in Tool Properties.
    void autoSizeAxis(int axis) {
        if (mesh_ is null || editMode_ is null) return;
        Vec3 bbMin, bbMax;
        bool seen;
        final switch (*editMode_) {
            case EditMode.Vertices:
                mesh_.selectionBBoxMinMaxVertices(bbMin, bbMax, seen); break;
            case EditMode.Edges:
                mesh_.selectionBBoxMinMaxEdges   (bbMin, bbMax, seen); break;
            case EditMode.Polygons:
                mesh_.selectionBBoxMinMaxFaces   (bbMin, bbMax, seen); break;
        }
        if (!seen) return;
        Vec3 bbCenter = (bbMin + bbMax) * 0.5f;
        Vec3 bbHalf   = (bbMax - bbMin) * 0.5f;
        Vec3 n = (axis == 0) ? Vec3(1, 0, 0)
               : (axis == 1) ? Vec3(0, 1, 0)
                             : Vec3(0, 0, 1);
        float ext = abs(bbHalf.x * n.x) + abs(bbHalf.y * n.y)
                  + abs(bbHalf.z * n.z);
        if (ext < 1e-6f) ext = 0.5f;
        start = bbCenter - n * ext;
        end   = bbCenter + n * ext;
    }

private:
    bool applySetAttr(string name, string value) {
        switch (name) {
            case "type":
                if      (value == "none")     { type = FalloffType.None;     return true; }
                else if (value == "linear")   { type = FalloffType.Linear;   return true; }
                else if (value == "radial")   { type = FalloffType.Radial;   return true; }
                else if (value == "screen")   { type = FalloffType.Screen;   return true; }
                else if (value == "lasso")    { type = FalloffType.Lasso;    return true; }
                else if (value == "cylinder") { type = FalloffType.Cylinder; return true; }
                else if (value == "element")  { type = FalloffType.Element;  return true; }
                return false;
            case "shape":
                if      (value == "linear")  { shape = FalloffShape.Linear;  return true; }
                else if (value == "easeIn")  { shape = FalloffShape.EaseIn;  return true; }
                else if (value == "easeOut") { shape = FalloffShape.EaseOut; return true; }
                else if (value == "smooth")  { shape = FalloffShape.Smooth;  return true; }
                else if (value == "custom")  { shape = FalloffShape.Custom;  return true; }
                return false;
            case "start":        return parseVec3(value, start);
            case "end":          return parseVec3(value, end);
            case "center":       return parseVec3(value, center);
            case "size":         return parseVec3(value, size);
            case "axis":         return parseVec3(value, normal);
            case "pickedCenter": return parseVec3(value, pickedCenter);
            case "dist":         dist = parseFloat(value); return true;
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
            case "lassoPoly":  return parseLassoPoly(value);
            case "lassoClear":
                lassoPolyX.length = 0;
                lassoPolyY.length = 0;
                return true;
            default: return false;
        }
    }

    // Parse a "x1,y1;x2,y2;..." polygon. Empty string clears the
    // polygon. Returns false on malformed input (odd token count,
    // non-numeric, etc.) — leaves existing polygon intact.
    bool parseLassoPoly(string value) {
        if (value.length == 0) {
            lassoPolyX.length = 0;
            lassoPolyY.length = 0;
            return true;
        }
        float[] xs;
        float[] ys;
        foreach (chunk; value.split(";")) {
            auto t = chunk.strip;
            if (t.length == 0) continue;
            auto pair = t.split(",");
            if (pair.length != 2) return false;
            try {
                xs ~= pair[0].strip.to!float;
                ys ~= pair[1].strip.to!float;
            } catch (Exception) {
                return false;
            }
        }
        if (xs.length < 3) return false;       // need a polygon, not a point/line
        lassoPolyX = xs;
        lassoPolyY = ys;
        return true;
    }

    string typeLabel() const {
        final switch (type) {
            case FalloffType.None:     return "none";
            case FalloffType.Linear:   return "linear";
            case FalloffType.Radial:   return "radial";
            case FalloffType.Screen:   return "screen";
            case FalloffType.Lasso:    return "lasso";
            case FalloffType.Cylinder: return "cylinder";
            case FalloffType.Element:  return "element";
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

    // Cache-bypass workplane-normal lookup for autoSize. Same value
    // `state.workplane.normal` would have on the next pipeline.evaluate,
    // but doesn't require an evaluate to have run since the last
    // `workplane.*` mutation. Falls back to the cached `lastWpNormal_`
    // when no pipeline / workplane stage is wired (unit tests that
    // construct FalloffStage in isolation).
    Vec3 currentWorkplaneNormal() {
        if (g_pipeCtx is null) return lastWpNormal_;
        foreach (s; g_pipeCtx.pipeline.all()) {
            if (auto wp = cast(const(WorkplaneStage))s) {
                Vec3 n, a1, a2;
                wp.currentBasis(n, a1, a2);
                return n;
            }
        }
        return lastWpNormal_;
    }

    // Pre-fit Linear / Radial / Screen / Lasso to the current selection
    // bbox, so the user gets an immediately useful starting point on
    // type switch (matches MODO behaviour). Each type uses what it
    // needs from the bbox; the others' attrs are left alone.
    void autoSize() {
        if (mesh_ is null || editMode_ is null) return;
        Vec3 bbMin, bbMax;
        bool seen;
        final switch (*editMode_) {
            case EditMode.Vertices:
                mesh_.selectionBBoxMinMaxVertices(bbMin, bbMax, seen); break;
            case EditMode.Edges:
                mesh_.selectionBBoxMinMaxEdges   (bbMin, bbMax, seen); break;
            case EditMode.Polygons:
                mesh_.selectionBBoxMinMaxFaces   (bbMin, bbMax, seen); break;
        }
        if (!seen) return;
        Vec3 bbCenter = (bbMin + bbMax) * 0.5f;
        Vec3 bbHalf   = (bbMax - bbMin) * 0.5f;

        final switch (type) {
            case FalloffType.None: break;
            case FalloffType.Linear: {
                // Anchor the line through bbCenter, oriented along the
                // workplane normal, length = bbox extent along that
                // normal. Falls back to a unit-Y line at the bbox
                // centre when the projected extent is zero (flat
                // selection in the construction plane).
                //
                // Query WorkplaneStage directly rather than reading the
                // `lastWpNormal_` cache populated by evaluate(). The
                // cache is only refreshed when pipeline.evaluate runs,
                // and nothing forces an evaluate between a
                // `tool.pipe.attr workplane mode worldY` and a
                // `tool.pipe.attr falloff type linear` issued in the
                // same frame — autoSize would otherwise pick up the
                // PREVIOUS workplane orientation and lay the Linear
                // line along the wrong axis. WorkplaneStage.currentBasis
                // computes from rotation alone, no pipe round-trip
                // required.
                Vec3 n = currentWorkplaneNormal();
                float ext = abs(bbHalf.x * n.x) + abs(bbHalf.y * n.y)
                          + abs(bbHalf.z * n.z);
                if (ext < 1e-6f) ext = 0.5f;
                start = bbCenter - n * ext;
                end   = bbCenter + n * ext;
                break;
            }
            case FalloffType.Radial:
                // Centre at bbox centre; per-axis radii = bbox half-
                // extents (so the ellipsoid surface touches the bbox).
                center = bbCenter;
                size   = Vec3(
                    bbHalf.x > 1e-6f ? bbHalf.x : 0.5f,
                    bbHalf.y > 1e-6f ? bbHalf.y : 0.5f,
                    bbHalf.z > 1e-6f ? bbHalf.z : 0.5f,
                );
                break;
            case FalloffType.Screen: {
                // Project bbCenter to window pixels; place screenCx/Cy
                // there. screenSize = max projected bbox extent in
                // pixels (one of the 8 corners furthest from the
                // centroid pixel). Falls back to defaults when
                // projection fails or no live viewport has been
                // captured yet.
                if (!lastVpValid_) break;
                float cx, cy, ndcZ;
                if (!projectToWindowFull(bbCenter, lastVp_, cx, cy, ndcZ))
                    break;
                screenCx = cx;
                screenCy = cy;
                float maxR = 0.0f;
                foreach (i; 0 .. 8) {
                    Vec3 corner = Vec3(
                        (i & 1) ? bbMax.x : bbMin.x,
                        (i & 2) ? bbMax.y : bbMin.y,
                        (i & 4) ? bbMax.z : bbMin.z,
                    );
                    float kx, ky, knz;
                    if (!projectToWindowFull(corner, lastVp_, kx, ky, knz))
                        continue;
                    float dx = kx - cx;
                    float dy = ky - cy;
                    float r = sqrt(dx * dx + dy * dy);
                    if (r > maxR) maxR = r;
                }
                // Screen-radius must be > 0 — a degenerate value would
                // make every vert weight = 0/0. Fall back to a 64-px
                // default (matches the FalloffPacket initializer).
                screenSize = maxR > 1.0f ? maxR : 64.0f;
                break;
            }
            case FalloffType.Lasso:
                // Lasso polygon needs the user's input gesture (7.5e);
                // nothing meaningful to auto-size.
                break;
            case FalloffType.Cylinder:
                // Mirrors the Radial branch: anchor the cylinder at the
                // bbox centre, isotropic radial extent. The cylinder
                // axis (`normal`) defaults to +Y per the FalloffPacket
                // default — explicit user override via
                // `tool.pipe.attr falloff axis "<x,y,z>"` if needed.
                center = bbCenter;
                size   = Vec3(
                    bbHalf.x > 0 ? bbHalf.x : 1.0f,
                    bbHalf.y > 0 ? bbHalf.y : 1.0f,
                    bbHalf.z > 0 ? bbHalf.z : 1.0f);
                break;
            case FalloffType.Element:
                // Sphere anchored at the bbox centre with radius =
                // largest half-extent. ElementMoveTool (Stage 14.3)
                // overwrites `pickedCenter` on click; until then, this
                // gives a reasonable manual default that covers the
                // whole selection.
                pickedCenter = bbCenter;
                float maxHalf = bbHalf.x;
                if (bbHalf.y > maxHalf) maxHalf = bbHalf.y;
                if (bbHalf.z > maxHalf) maxHalf = bbHalf.z;
                if (maxHalf > 0) dist = maxHalf;
                break;
        }
    }
}
