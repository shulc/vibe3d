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
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.packets  : FalloffPacket, FalloffType, FalloffShape,
                            LassoStyle, ElementConnect, ElementMode;
import operator          : Operator, Task, VectorStack, PacketKind;
import toolpipe.stages.workplane : WorkplaneStage;
import popup_state       : setStatePath;
import params            : Param, ParamHints, IntEnumEntry;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import imgui_style       : pushPopupStyle, popPopupStyle;

// ---------------------------------------------------------------------------
// FalloffStage — Phase 7.5 of doc/phase7_plan.md / doc/falloff_plan.md.
// Sits at ordinal 0x90 (after AXIS 0x70, before PINK 0xB0).
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
class FalloffStage : Stage, Operator {
    FalloffType  type        = FalloffType.None;
    FalloffShape shape       = FalloffShape.Smooth;

    Vec3 start  = Vec3(0, 0, 0);
    Vec3 end    = Vec3(0, 1, 0);
    Vec3 center = Vec3(0, 0, 0);
    Vec3 size   = Vec3(1, 1, 1);
    Vec3 normal = Vec3(0, 1, 0);    // cylinder axis (default +Y, the xfrm.vortex default)
    // Element falloff (Stage 14.1): sphere centred on the ACEN-
    // published pivot (state.actionCenter.center — same point the
    // gizmo sits on) with radius `dist`. The sphere CENTRE has a
    // single source of truth (ACEN); FalloffStage owns only the
    // RADIUS. To relocate the sphere, push ACEN.userPlaced (via
    // setUserPlaced from a tool, or HTTP
    // `tool.pipe.attr actionCenter userPlacedX/Y/Z`).
    float dist = 1.0f;
    // Stage 14.4: connectivity gate. When != Off, the per-vert
    // weight is multiplied by `connectMask[vi] ? 1 : 0` so verts
    // outside the picked component drop out regardless of distance.
    // Mask is populated by XfrmTransformTool's click-pick (BFS over
    // mesh.edges from the picked vert).
    ElementConnect connect = ElementConnect.Off;
    bool[]         connectMask;
    // Anchor ring — vertex indices that get weight=1.0 regardless
    // of the sphere math. Click-pick populates this with the
    // clicked element's vert ring (single vert / edge endpoints /
    // face vert ring). Together with the sphere around ACEN.center,
    // the two pieces form the `falloff.element` hybrid:
    // an "anchor + attenuation" weight function. The ring is not a
    // public attr — it's an implementation detail of the
    // falloff.element evaluation that short-circuits on it.
    //
    // Runtime-only (no setAttr on the field itself except the
    // `anchorRing` string parser for tests / scripting — most users
    // never touch it). Cleared on FalloffStage.reset and on type
    // change away from Element.
    uint[] anchorRing;
    // Stage 14.8: pick mode for the Element-falloff click-pick path.
    // `auto`/`autoCent`
    // try all element types; vertex/edge/polygon restrict; bare vs
    // Cent variants control the pivot policy. See ElementMode enum
    // doc in toolpipe/packets.d for the full semantic.
    ElementMode    elementMode = ElementMode.Auto;

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
    // "the line stands up out of the work plane".
    private Vec3 lastWpNormal_ = Vec3(0, 1, 0);

    // Last viewport cached at evaluate(). Used by autoSize() for Screen
    // type to project the selection bbox centroid into window pixels.
    // Default-init produces a degenerate viewport — autoSize() guards
    // against that with a "did we ever evaluate?" flag.
    private Viewport lastVp_;
    private bool     lastVpValid_ = false;

    // D.7 — Selection-falloff scratch buffer (xfrm.flex). Owned by
    // the stage so the slice we publish on the packet stays valid
    // for the duration of the pipe walk. Recomputed every evaluate()
    // when type=Selection — BFS over mesh.edges is O(V+E), cheap
    // enough that a cache with invalidation keys would add more code
    // than it saves wall-time.
    private float[] selWeights_;

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
        anchorRing.length = 0;
        publishState();
    }

    // ------------------------------------------------------------------
    // Operator interface (Phase 6: kernel lives directly in evaluate(vts)).
    // ------------------------------------------------------------------

    private FalloffPacket _publishedPacket;

    override Task task() const { return Task.Wght; }
    override PacketKind[] requiredPackets() const {
        return [PacketKind.Subject];
    }

    override bool evaluate(ref VectorStack vts) {
        if (!enabled) return false;
        import toolpipe.packets : SubjectPacket, WorkplanePacket,
                                  ActionCenterPacket;
        // Cache upstream WORK normal + viewport for autoSize() callers
        // outside the pipeline.
        if (auto wp = vts.get!WorkplanePacket()) lastWpNormal_ = wp.normal;
        if (auto subj = vts.get!SubjectPacket()) {
            lastVp_      = subj.viewport;
            lastVpValid_ = true;
        }
        FalloffPacket pkt;
        pkt.enabled      = (type != FalloffType.None);
        pkt.type         = type;
        pkt.shape        = shape;
        pkt.start        = start;
        pkt.end          = end;
        pkt.center       = center;
        pkt.size         = size;
        pkt.normal       = normal;
        // Sphere centre tracks ACEN.center. ACEN runs before us.
        if (auto acen = vts.get!ActionCenterPacket())
            pkt.pickedCenter = acen.center;
        pkt.pickedRadius = dist;
        pkt.connect      = connect;
        pkt.connectMask  = connectMask;
        pkt.anchorRing   = anchorRing;
        pkt.elementMode  = elementMode;
        pkt.screenCx     = screenCx;
        pkt.screenCy     = screenCy;
        pkt.screenSize   = screenSize;
        pkt.transparent  = transparent;
        pkt.lassoStyle   = lassoStyle;
        pkt.lassoPolyX   = lassoPolyX;
        pkt.lassoPolyY   = lassoPolyY;
        pkt.softBorderPx = softBorderPx;
        pkt.in_          = in_;
        pkt.out_         = out_;
        if (type == FalloffType.Selection)
            recomputeSelectionWeights();
        else
            selWeights_.length = 0;
        pkt.selectionWeights = selWeights_;
        pkt.compoundPasses   = 1.0f;
        _publishedPacket = pkt;
        vts.put(&_publishedPacket);
        return true;
    }

    override bool setAttr(string name, string value) {
        FalloffType prev = type;
        bool ok = applySetAttr(name, value);
        if (ok) {
            // Convention: switching the falloff type while a tool is
            // active auto-sizes the new falloff to the current
            // selection's bbox — the act of selecting the falloff type
            // automatically scales it to the bounding-box size of the
            // active selection. Only fires on a real
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
            ["dist",         format("%g", dist)],
            ["anchorRing",   anchorRingStr()],
            ["connect",      connectLabel()],
            ["mode",         elementModeLabel()],
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

    string anchorRingStr() const {
        if (anchorRing.length == 0) return "";
        string s = format("%d", anchorRing[0]);
        foreach (i; 1 .. anchorRing.length)
            s ~= format(",%d", anchorRing[i]);
        return s;
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

        IntEnumEntry[] elementModeEntries = [
            IntEnumEntry(cast(int)ElementMode.Auto,     "auto",     "Auto"),
            IntEnumEntry(cast(int)ElementMode.AutoCent, "autoCent", "Auto Center"),
            IntEnumEntry(cast(int)ElementMode.Vertex,   "vertex",   "Vertex"),
            IntEnumEntry(cast(int)ElementMode.Edge,     "edge",     "Edge"),
            IntEnumEntry(cast(int)ElementMode.EdgeCent, "edgeCent", "Edge Center"),
            IntEnumEntry(cast(int)ElementMode.Polygon,  "polygon",  "Polygon"),
            IntEnumEntry(cast(int)ElementMode.PolyCent, "polyCent", "Polygon Center"),
        ];

        IntEnumEntry[] elementConnectEntries = [
            IntEnumEntry(cast(int)ElementConnect.Off,      "off",      "Off"),
            IntEnumEntry(cast(int)ElementConnect.Vertex,   "vertex",   "Vertex"),
            IntEnumEntry(cast(int)ElementConnect.Edge,     "edge",     "Edge"),
            IntEnumEntry(cast(int)ElementConnect.Polygon,  "polygon",  "Polygon"),
            IntEnumEntry(cast(int)ElementConnect.Material, "material", "Material"),
        ];

        Param[] ps;
        // Shape preset is rendered via drawProperties() as a status-bar-
        // style popup-button; kept out of the schema list. HTTP
        // `tool.pipe.attr falloff shape <v>`
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
                // Element Mode dropdown first — primary control, drives
                // pick-type restriction (7-mode: auto / autoCent /
                // vertex / edge / edgeCent / polygon / polyCent).
                // The `falloff.element` `mode` UI dropdown.
                ps ~= Param.intEnum_("mode", "Element Mode",
                                     cast(int*)&elementMode, elementModeEntries,
                                     cast(int)ElementMode.Auto);
                ps ~= Param.float_("dist", "Range", &dist, 1.0f).min(1e-6f);
                ps ~= Param.intEnum_("connect", "Connect",
                                     cast(int*)&connect, elementConnectEntries,
                                     cast(int)ElementConnect.Off);
                break;
            case FalloffType.Selection:
                // `falloff.selection` (attr `steps`). `dist` field
                // re-used as the BFS-hop count (float so the existing
                // storage shared with Element can stay); the param is
                // labelled "Steps".
                ps ~= Param.float_("dist", "Steps",
                                   &dist, 4.0f).min(1.0f);
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
        // Header label baked from active type — "Linear Falloff" /
        // "Radial Falloff" section titles. The
        // status-bar Falloff pulldown owns type selection; the Tool
        // Properties section reflects whichever type is active.
        final switch (type) {
            case FalloffType.None:     return "Falloff";
            case FalloffType.Linear:          return "Linear Falloff";
            case FalloffType.Radial:          return "Radial Falloff";
            case FalloffType.Screen:          return "Screen Falloff";
            case FalloffType.Lasso:           return "Lasso Falloff";
            case FalloffType.Cylinder:        return "Cylinder Falloff";
            case FalloffType.Element:         return "Element Falloff";
            case FalloffType.Selection:       return "Selection Falloff";
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

    /// D.7: bake Selection per-vert weights into `selWeights_`,
    /// implementing `falloff.selection` semantics (see
    /// doc/deform_d7_flex_cross_engine_plan.md "Reverse-engineered
    /// model"):
    ///
    ///   - vert NOT in selection                  → weight = 0
    ///   - vert in selection, on boundary         → weight = 0
    ///     (selected vert with ≥1 unselected neighbour)
    ///   - vert in selection, geodesic g from boundary, g < G
    ///                                            → weight = applyShape(g/G)
    ///   - vert in selection, g ≥ G               → weight = 1
    ///
    /// `geodesic g` = Dijkstra shortest path from the SELECTED
    /// boundary set to v, walk confined to the in-selection
    /// subgraph, edges weighted by world-space length. Using
    /// geodesic distance rather than unit hops captures the
    /// per-vert variation produced when edge lengths differ across
    /// the selection (e.g. shorter top-cap edges vs longer side-face
    /// edges after Catmull-Clark).
    ///
    /// `G` (the "steps" range in geodesic units) =
    ///   `dist · avg_sel_edge_length`, where `dist` is the `steps`
    /// attr re-used. An empirical fit puts the exact G at
    /// `Steps · avg_edge · 0.81` (the 0.81 factor comes from the
    /// iterative smoothing convergence); we omit the 0.81 for
    /// cleanliness — at the cost of ~5 % residual.
    ///
    /// Empty selection → empty weight slice (caller treats as "no
    /// constraint", matching the "empty selection moves everything"
    /// convention every transform path uses).
    void recomputeSelectionWeights() {
        import std.math : sqrt;
        selWeights_.length = 0;
        if (mesh_ is null || editMode_ is null) return;
        size_t nVerts = mesh_.vertices.length;
        if (nVerts == 0) return;

        int[] selVertsList;
        bool hasAny;
        final switch (*editMode_) {
            case EditMode.Vertices:
                hasAny = mesh_.hasAnySelectedVertices();
                if (hasAny) selVertsList = mesh_.selectedVertexIndicesVertices();
                break;
            case EditMode.Edges:
                hasAny = mesh_.hasAnySelectedEdges();
                if (hasAny) selVertsList = mesh_.selectedVertexIndicesEdges();
                break;
            case EditMode.Polygons:
                hasAny = mesh_.hasAnySelectedFaces();
                if (hasAny) selVertsList = mesh_.selectedVertexIndicesFaces();
                break;
        }
        if (!hasAny) return;

        bool[] inSel = new bool[](nVerts);
        foreach (vi; selVertsList) {
            if (vi >= 0 && cast(size_t)vi < nVerts) inSel[vi] = true;
        }

        // Adjacency list. Edge lengths used to be required for the
        // Dijkstra-based weight pass; the iterative Laplacian
        // smoothing below ignores them (each in-selection neighbour
        // contributes equally), but we keep the build cheap and may
        // re-add edge-weighted smoothing if it ever helps a fit.
        uint[][]  adj    = new uint[][](nVerts);
        foreach (e; mesh_.edges) {
            uint a = e[0], b = e[1];
            if (a >= nVerts || b >= nVerts) continue;
            adj[a] ~= b;
            adj[b] ~= a;
        }

        // Boundary verts: selected with ≥1 unselected neighbour.
        // These are pinned to weight 0 across the smoothing — the
        // "soft border" hinge.
        bool[] isB = new bool[](nVerts);
        foreach (vi; 0 .. nVerts) {
            if (!inSel[vi]) continue;
            foreach (n; adj[vi]) {
                if (!inSel[n]) { isB[vi] = true; break; }
            }
        }

        // Iterative Laplacian smoothing — fits the falloff.selection
        // reference at RMS 0.0275 across Steps=1..4.
        // Initial state: boundary verts = 0,
        // interior selected verts = 1. Each iteration averages the
        // current weight with the mean of in-selection neighbours,
        // weighted by `alpha`. Boundary stays pinned at 0.
        //
        // dist (the falloff.selection `steps` attribute) maps to the
        // iteration count via `iters = 4·Steps + 1` (best-fit). With
        // Steps=0 we collapse to no smoothing — the selection-edge
        // hinge is the whole weight map (binary 0/1).
        enum float kLapAlpha = 0.76f;
        int stepsI = cast(int)dist;
        if (stepsI < 0) stepsI = 0;
        int iters = (stepsI <= 0) ? 0 : (4 * stepsI + 1);

        float[] wA = new float[](nVerts);
        float[] wB = new float[](nVerts);
        // Initial weights
        foreach (vi; 0 .. nVerts) {
            if (!inSel[vi])      wA[vi] = 0.0f;
            else if (isB[vi])    wA[vi] = 0.0f;
            else                 wA[vi] = 1.0f;
        }
        foreach (it; 0 .. iters) {
            // Per-iteration pass: wB[v] = (1-α)·wA[v] + α·avg(wA[selected_neighbours])
            foreach (vi; 0 .. nVerts) {
                if (!inSel[vi])      { wB[vi] = 0.0f; continue; }
                if (isB[vi])         { wB[vi] = 0.0f; continue; }
                float sum = 0.0f;
                int   cnt = 0;
                foreach (n; adj[vi]) {
                    if (!inSel[n]) continue;
                    sum += wA[n];
                    cnt += 1;
                }
                float avg = (cnt > 0) ? (sum / cast(float)cnt) : wA[vi];
                wB[vi] = (1.0f - kLapAlpha) * wA[vi] + kLapAlpha * avg;
            }
            // swap
            auto tmp = wA; wA = wB; wB = tmp;
        }

        // Apply shape AFTER smoothing — the curve shapes (smooth,
        // easeIn, easeOut) are post-process transforms on the linear
        // weight. smoothstep(3w² − 2w³) maps the linear weight curve to
        // the smooth one exactly within float precision.
        import falloff : applyShape;
        selWeights_.length = nVerts;
        foreach (vi; 0 .. nVerts) {
            if (!inSel[vi]) { selWeights_[vi] = 0.0f; continue; }
            // applyShape(0) = 1, applyShape(1) = 0 by vibe3d convention.
            // We have w ∈ [0, 1] where 0 = boundary, 1 = deep. Pass
            // (1 - w) so deeper-in-selection (w high) → applyShape
            // input low → result high.
            selWeights_[vi] = applyShape(1.0f - wA[vi], shape, in_, out_);
        }
    }

private:
    bool applySetAttr(string name, string value) {
        switch (name) {
            case "type": {
                FalloffType prev = type;
                if      (value == "none")            type = FalloffType.None;
                else if (value == "linear")          type = FalloffType.Linear;
                else if (value == "radial")          type = FalloffType.Radial;
                else if (value == "screen")          type = FalloffType.Screen;
                else if (value == "lasso")           type = FalloffType.Lasso;
                else if (value == "cylinder")        type = FalloffType.Cylinder;
                else if (value == "element")         type = FalloffType.Element;
                else if (value == "selection")       type = FalloffType.Selection;
                else return false;
                // anchorRing is Element-only state — wipe on leaving
                // Element so a later switch back to Element starts
                // clean (no stale ring from the previous session).
                if (prev == FalloffType.Element && type != FalloffType.Element)
                    anchorRing.length = 0;
                return true;
            }
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
            case "dist":         dist = parseFloat(value); return true;
            case "connect":
                if      (value == "off")      { connect = ElementConnect.Off;      return true; }
                else if (value == "vertex")   { connect = ElementConnect.Vertex;   return true; }
                else if (value == "edge")     { connect = ElementConnect.Edge;     return true; }
                else if (value == "polygon")  { connect = ElementConnect.Polygon;  return true; }
                else if (value == "material") { connect = ElementConnect.Material; return true; }
                return false;
            case "mode":
                // 7-mode `element-mode` enum: auto / autoCent
                // / vertex / edge / edgeCent / polygon / polyCent.
                if      (value == "auto")     { elementMode = ElementMode.Auto;     return true; }
                else if (value == "autoCent") { elementMode = ElementMode.AutoCent; return true; }
                else if (value == "vertex")   { elementMode = ElementMode.Vertex;   return true; }
                else if (value == "edge")     { elementMode = ElementMode.Edge;     return true; }
                else if (value == "edgeCent") { elementMode = ElementMode.EdgeCent; return true; }
                else if (value == "polygon")  { elementMode = ElementMode.Polygon;  return true; }
                else if (value == "polyCent") { elementMode = ElementMode.PolyCent; return true; }
                return false;
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
            case "anchorRing":
                // Comma-separated vertex indices that get weight=1
                // in elementWeight. Normally written by click-pick
                // (XfrmTransformTool); this string setter exists for
                // tests + scripted setups that bypass the GPU-hover-
                // driven click path. Empty string clears.
                return parseAnchorRing(value);
            default: return false;
        }
    }

    bool parseAnchorRing(string value) {
        import std.string : split, strip;
        import std.conv   : to;
        if (value.length == 0) { anchorRing.length = 0; return true; }
        uint[] vs;
        foreach (chunk; value.split(",")) {
            auto t = chunk.strip;
            if (t.length == 0) continue;
            try { vs ~= t.to!uint; }
            catch (Exception) { return false; }
        }
        anchorRing = vs;
        return true;
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
            case FalloffType.None:            return "none";
            case FalloffType.Linear:          return "linear";
            case FalloffType.Radial:          return "radial";
            case FalloffType.Screen:          return "screen";
            case FalloffType.Lasso:           return "lasso";
            case FalloffType.Cylinder:        return "cylinder";
            case FalloffType.Element:         return "element";
            case FalloffType.Selection:       return "selection";
        }
    }

    string connectLabel() const {
        final switch (connect) {
            case ElementConnect.Off:      return "off";
            case ElementConnect.Vertex:   return "vertex";
            case ElementConnect.Edge:     return "edge";
            case ElementConnect.Polygon:  return "polygon";
            case ElementConnect.Material: return "material";
        }
    }

    string elementModeLabel() const {
        final switch (elementMode) {
            case ElementMode.Auto:     return "auto";
            case ElementMode.AutoCent: return "autoCent";
            case ElementMode.Vertex:   return "vertex";
            case ElementMode.Edge:     return "edge";
            case ElementMode.EdgeCent: return "edgeCent";
            case ElementMode.Polygon:  return "polygon";
            case ElementMode.PolyCent: return "polyCent";
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
                     type == FalloffType.None     ? "true" : "false");
        setStatePath("falloff/types/linear",
                     type == FalloffType.Linear   ? "true" : "false");
        setStatePath("falloff/types/radial",
                     type == FalloffType.Radial   ? "true" : "false");
        setStatePath("falloff/types/cylinder",
                     type == FalloffType.Cylinder ? "true" : "false");
        setStatePath("falloff/types/screen",
                     type == FalloffType.Screen   ? "true" : "false");
        setStatePath("falloff/types/lasso",
                     type == FalloffType.Lasso    ? "true" : "false");
        setStatePath("falloff/types/element",
                     type == FalloffType.Element  ? "true" : "false");
        setStatePath("falloff/types/selection",
                     type == FalloffType.Selection ? "true" : "false");
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
    // type switch. Each type uses what it needs from the bbox; the
    // others' attrs are left alone.
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
                // The sphere centre is owned by ACEN (gizmo pivot) —
                // we only auto-size the RADIUS to the selection bbox
                // half-extent. ACEN.Element already returns the
                // selection-element centroid by default, so the
                // resulting sphere comfortably encloses the bbox.
                float maxHalf = bbHalf.x;
                if (bbHalf.y > maxHalf) maxHalf = bbHalf.y;
                if (bbHalf.z > maxHalf) maxHalf = bbHalf.z;
                if (maxHalf > 0) dist = maxHalf;
                break;
            case FalloffType.Selection:
                // `dist` is the BFS-hop range (the `steps` attr) —
                // bbox sizing doesn't apply. Pin to 4 so a fresh
                // selection switch ignores any prior `dist` value
                // left by a previous Element session.
                dist = 4.0f;
                break;
        }
    }
}
