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
import toolpipe.packets  : FalloffPacket, FalloffType, FalloffShape, FalloffMix,
                            LassoStyle, ElementConnect, ElementMode;
import operator          : Operator, Task, VectorStack, PacketKind;
import toolpipe.stages.workplane : WorkplaneStage;
import popup_state       : setStatePath;
import params            : Param, ParamHints, IntEnumEntry;

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

    // Multi-falloff Mix Mode. When this stage is stacked as a non-first
    // contributor (Phase 4 add/remove verbs), its weight folds into the
    // running accumulator via this op (see the Composite branch of
    // evaluateFalloff). The primary / first contributor's `mix` is unused
    // (it seeds the accumulator), but every instance carries the field so
    // it round-trips through snapshot/restore and the forms UI. Default
    // Multiply preserves single-falloff behaviour (irrelevant for one).
    FalloffMix mix = FalloffMix.Multiply;

    // Optional refs for auto-size on `setAttr("type", ...)`. Phase 7.5a
    // shipped without them (None type doesn't auto-size); 7.5b wires
    // them in app.d's initToolPipe so Linear / Radial / Screen / Lasso
    // can pre-fit to the active selection. nullable: unit tests that
    // bypass the app-level wiring still work; auto-size becomes a
    // no-op.
    private Mesh* delegate() meshSrc_;
    private @property Mesh* mesh_() const { return meshSrc_ ? meshSrc_() : null; }
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
    // for the duration of the pipe walk.
    //
    // The weight map is COMPLETELY position-independent: it depends only
    // on mesh topology (edges + vertex count), the selection (per edit
    // mode), `dist` (→ stepsI/iters), and the shape params (shape/in_/out_).
    // ALL of those are frozen during a transform drag (selection frozen,
    // topology frozen — transform tools mutate vertex POSITIONS directly
    // without bumping mesh.mutationVersion). So the map can be computed
    // ONCE per drag and reused across the ~17 iteration frames, instead of
    // re-running the Laplacian smoothing every pipe walk. We cache it keyed
    // on (mutationVersion, editMode, selectionSignature, stepsI, shape,
    // in_, out_); a key miss recomputes.
    private float[] selWeights_;

    // --- selWeights_ cache key (see recomputeSelectionWeights) ---
    // mutationVersion bumps on every topology/geometry-structure edit and is
    // NOT bumped by selection writes nor drag-time vertex moves. Selection
    // lives in the Marks.Select bit and has no version counter, so a cheap
    // FNV-1a rolling hash over the selected-element set is folded into the
    // key (mirrors ActionCenterStage.selectionSignature). `_selCacheValid`
    // is force-cleared whenever the non-Selection branch in evaluate() runs,
    // so flipping the falloff type away from Selection and back recomputes.
    private bool   _selCacheValid    = false;
    private ulong  _selCacheMutVer   = ulong.max;
    private int    _selCacheEditMode = -1;
    private ulong  _selCacheSelSig   = 0;
    private int    _selCacheSteps    = int.min;
    private FalloffShape _selCacheShape = cast(FalloffShape)(-1);
    private float  _selCacheIn        = float.nan;
    private float  _selCacheOut       = float.nan;
    // Cached vertex→neighbor CSR adjacency (flat neighbor list + per-vertex
    // [offset, offset+1] bounds). Topology-invariant, rebuilt only when
    // mutationVersion moves. Used by the Laplacian smoothing so neighbor
    // lookup is O(degree) instead of allocating uint[][] every recompute.
    private ulong    _adjMutVer   = ulong.max;
    private uint[]   _adjNeighbors;   // flattened neighbor ids
    private size_t[] _adjOffset;      // length nV+1; neighbors of v are
                                      // _adjNeighbors[_adjOffset[v] .. _adjOffset[v+1]]

    // Unique stage id. The PRIMARY falloff keeps the bare "falloff" id so
    // the status-bar pulldown, the `falloff.<type>` set-primary commands,
    // and every `pipe.falloff.type` preset keep targeting it unchanged.
    // Stacked extras (Phase 4 `falloff.add`) get "falloff#1", "falloff#2", …
    // so `Pipeline.findById` can address each one (and `tool.pipe.attr
    // falloff#1 …` works). Multi-falloff combine is type-agnostic; the id
    // is purely the addressing handle.
    private string instanceId_ = "falloff";

    this(Mesh* delegate() meshSrc = null, EditMode* editMode = null,
         string instanceId = "falloff") {
        this.meshSrc_ = meshSrc;
        this.editMode_   = editMode;
        this.instanceId_ = instanceId;
        publishState();
    }

    override TaskCode taskCode() const pure nothrow @nogc @safe { return TaskCode.Wght; }
    override string   id()       const                          { return instanceId_; }
    // Every falloff instance (primary "falloff" + stacked "falloff#N") resolves
    // the SAME config form; the per-instance params() filter + the stageId write
    // rebind make each section show/edit its own type+config.
    override string   formFamilyId() const                      { return "falloff"; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ordWght; }

    /// Is this the compat anchor (`id() == "falloff"`)? The primary is never
    /// removable and never auto-cleared by `falloff.clear`; only the stacked
    /// `falloff#N` extras are. Set once at construction.
    bool isPrimary() const { return instanceId_ == "falloff"; }

    /// Does this instance actually contribute (a real type is selected)?
    /// The primary anchor stays plugged in with type None when no
    /// falloff is active; UI that lists "active falloffs" gates on this.
    bool isActive() const { return type != FalloffType.None; }

    /// Expose the mesh / editMode pointers so `falloff.add` can construct a
    /// stacked instance sharing the primary's references (auto-size +
    /// selection-weight math need them).
    Mesh*     meshPtr()     { return mesh_; }
    EditMode* editModePtr() { return editMode_; }

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
        mix          = FalloffMix.Multiply;
        anchorRing.length = 0;
        // Drop the selection-weight cache so a fresh start recomputes.
        selWeights_.length = 0;
        _selCacheValid     = false;
        _selCacheMutVer    = ulong.max;
        _adjMutVer         = ulong.max;
        _adjOffset.length  = 0;
        _adjNeighbors.length = 0;
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
        else {
            selWeights_.length = 0;
            // Force a miss next time the type returns to Selection: the key
            // does not include `type`, so without this a stale cached map
            // could be reused after a type round-trip.
            _selCacheValid = false;
        }
        pkt.selectionWeights = selWeights_;
        pkt.compoundPasses   = 1.0f;
        pkt.mix              = mix;

        // --- Multi-falloff combine (WGHT slot, last-writer-wins) ---
        //
        // The VectorStack's Falloff slot holds exactly one FalloffPacket;
        // multiple FalloffStage instances run in pipe order and each
        // REPLACES the slot. To stack them we read the packet a prior
        // FalloffStage already published and fold ourselves in:
        //
        //   * prior is null  → we're the first (or only) active falloff:
        //     publish OUR sub-packet directly. With exactly one active
        //     falloff this is the verbatim pre-stacking packet, so the
        //     geometry output is byte-for-byte identical (no Composite,
        //     `mix` irrelevant for one).
        //   * prior present  → build a Composite whose `contributors` are
        //     (prior's contributors, if it is already a Composite — FLATTEN,
        //     don't nest) ~ our sub-packet, and publish THAT (replacing the
        //     slot). The last stacked FalloffStage to run thus publishes the
        //     composite of all; every downstream consumer reads ONE packet
        //     unchanged.
        //
        // Contributor lifetime: contributors are VALUE COPIES owned by this
        // stage's `_publishedPacket` member (which persists past evaluate),
        // so the published pointer + its contributors stay valid for the
        // whole pipe walk and never alias another stage's live fields.
        auto prior = vts.get!FalloffPacket();
        if (prior is null) {
            _publishedPacket = pkt;
        } else {
            FalloffPacket comp;
            comp.enabled = true;
            comp.type    = FalloffType.Composite;
            if (prior.type == FalloffType.Composite)
                comp.contributors = prior.contributors.dup ~ pkt;
            else
                comp.contributors = [*prior, pkt];
            _publishedPacket = comp;
        }
        vts.put(&_publishedPacket);
        return true;
    }

    /// Restore the user-facing CONFIG fields from a previously-published
    /// FalloffPacket and re-publish so the visible handle / status pulldown
    /// follow. Used by the wrapper's in-session falloff-refire undo/redo hooks
    /// (P-A): an in-session Ctrl+Z of a falloff re-grade restores the geometry
    /// (the MeshVertexEdit revert) AND the falloff config to its PRE-tweak
    /// value (this method, via the entry's revert hook); redo restores the
    /// POST-tweak config (via the apply hook). Mirrors
    /// ActionCenterStage.restorePinState — assign + publish, no session.
    ///
    /// Restores only STAGE-owned config (the fields a FalloffPacket round-trips
    /// from this stage's own fields). It does NOT touch the ACEN-owned sphere
    /// centre (`pickedCenter`) — that pivot has its own source of truth + its
    /// own pin hooks — nor the derived caches (selWeights_, adjacency,
    /// connectMask), which rebuild on the next evaluate(). The `dist` field is
    /// re-used as the radius / step count, so it tracks `pickedRadius`.
    void restoreConfigFromPacket(const ref FalloffPacket p) {
        type         = p.type;
        shape        = p.shape;
        start        = p.start;
        end          = p.end;
        center       = p.center;
        size         = p.size;
        normal       = p.normal;
        dist         = p.pickedRadius;
        connect      = p.connect;
        elementMode  = p.elementMode;
        screenCx     = p.screenCx;
        screenCy     = p.screenCy;
        screenSize   = p.screenSize;
        transparent  = p.transparent;
        lassoStyle   = p.lassoStyle;
        lassoPolyX   = p.lassoPolyX.dup;
        lassoPolyY   = p.lassoPolyY.dup;
        softBorderPx = p.softBorderPx;
        in_          = p.in_;
        out_         = p.out_;
        mix          = p.mix;
        anchorRing   = p.anchorRing.dup;
        // The Selection-weight cache is keyed on (mutationVersion, editMode,
        // selectionSig, steps, shape, in_, out_); restoring config that changes
        // any of those must invalidate it so the next evaluate() recomputes.
        _selCacheValid     = false;
        publishState();
    }

    /// Snapshot the stage's LIVE user-facing CONFIG fields into a FalloffPacket
    /// — the exact inverse of `restoreConfigFromPacket`. Used by the wrapper's
    /// gesture-commit hooks (P-A blocker fix) to capture the RUN-START falloff
    /// config at the moment the first gesture commits, so the merged-run revert
    /// hook (first.revert) can restore both the pin AND the run-start config.
    ///
    /// Captures only the STAGE-owned fields that round-trip through
    /// restoreConfigFromPacket (same set, same `dist`↔`pickedRadius` mapping).
    /// It deliberately does NOT capture the ACEN-owned sphere centre
    /// (`pickedCenter`) or the derived caches — restoreConfigFromPacket would
    /// not consume them anyway. Slices are .dup'd so the snapshot is independent
    /// of subsequent in-place stage mutation.
    FalloffPacket snapshotConfigToPacket() const {
        FalloffPacket p;
        p.enabled      = (type != FalloffType.None);
        p.type         = type;
        p.shape        = shape;
        p.start        = start;
        p.end          = end;
        p.center       = center;
        p.size         = size;
        p.normal       = normal;
        p.pickedRadius = dist;
        p.connect      = connect;
        p.elementMode  = elementMode;
        p.screenCx     = screenCx;
        p.screenCy     = screenCy;
        p.screenSize   = screenSize;
        p.transparent  = transparent;
        p.lassoStyle   = lassoStyle;
        p.lassoPolyX   = lassoPolyX.dup;
        p.lassoPolyY   = lassoPolyY.dup;
        p.softBorderPx = softBorderPx;
        p.in_          = in_;
        p.out_         = out_;
        p.mix          = mix;
        p.anchorRing   = anchorRing.dup;
        return p;
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

    // Full static attr universe for forms-engine startup validation.
    // FalloffStage.params() is FILTERED per active falloff type (only
    // Linear exposes start/end, only Radial exposes center/size, …) and
    // `applySetAttr` (~line 810) is a non-enumerable switch, so the base
    // Stage.knownAttrs() default (params() names) would reject perfectly
    // valid cross-type attrs at startup. This is the authoritative list of
    // every attr `applySetAttr` accepts regardless of active type.
    //
    // KEEP IN SYNC with the `applySetAttr` switch (~line 810) AND with
    // `listAttrs()` below — all three must enumerate the same attr set.
    override string[] knownAttrs() {
        return [
            "type", "shape", "start", "end", "center", "size", "axis",
            "dist", "anchorRing", "connect", "mode", "screenCx", "screenCy",
            "screenSize", "transparent", "lassoStyle", "lassoPoly",
            "softBorder", "in", "out", "mix",
        ];
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
            ["mix",          mixLabel()],
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

        IntEnumEntry[] mixEntries = [
            IntEnumEntry(cast(int)FalloffMix.Multiply, "multiply", "Multiply"),
            IntEnumEntry(cast(int)FalloffMix.Add,      "add",      "Add"),
            IntEnumEntry(cast(int)FalloffMix.Subtract, "subtract", "Subtract"),
            IntEnumEntry(cast(int)FalloffMix.Max,      "max",      "Max"),
            IntEnumEntry(cast(int)FalloffMix.Min,      "min",      "Min"),
        ];

        // Wire tags MUST match the applySetAttr("shape", …) switch.
        IntEnumEntry[] shapeEntries = [
            IntEnumEntry(cast(int)FalloffShape.Linear,  "linear",  "Linear"),
            IntEnumEntry(cast(int)FalloffShape.EaseIn,  "easeIn",  "Ease-In"),
            IntEnumEntry(cast(int)FalloffShape.EaseOut, "easeOut", "Ease-Out"),
            IntEnumEntry(cast(int)FalloffShape.Smooth,  "smooth",  "Smooth"),
            IntEnumEntry(cast(int)FalloffShape.Custom,  "custom",  "Custom"),
        ];

        Param[] ps;
        // Mix Mode — multi-falloff stacking control: how this falloff combines
        // with the others. A LONE falloff has nothing to combine with, so the
        // dropdown is hidden until a second falloff is stacked (falloff.add);
        // then every stacked section carries it. Gated by exposing the `mix`
        // param only when >1 WGHT stage is registered — the forms resolver hides
        // the row whenever the attr is absent (the same value-driven filter that
        // hides per-type rows). `mix` stays in knownAttrs()/listAttrs(), so the
        // setAttr round-trip and form validation are unaffected.
        bool stacked = g_pipeCtx !is null
            && g_pipeCtx.pipeline.findAllByTask(TaskCode.Wght).length > 1;
        if (stacked)
            ps ~= Param.intEnum_("mix", "Mix",
                                 cast(int*)&mix, mixEntries,
                                 cast(int)FalloffMix.Multiply);

        // Shape preset — the weight-curve shape (Linear / Ease-In / Ease-Out /
        // Smooth / Custom). Exposed as a form dropdown (config/forms/falloff.yaml
        // "Shape Preset"); the legacy drawProperties() popup that used to render
        // it was retired in favour of this row.
        ps ~= Param.intEnum_("shape", "Shape Preset",
                             cast(int*)&shape, shapeEntries,
                             cast(int)FalloffShape.Smooth);

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
            case FalloffType.Composite:
                // A FalloffStage's own `type` is never Composite — that
                // is a synthesized PACKET type the WGHT combiner publishes,
                // not a value any single stage holds. No per-type config.
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
            case FalloffType.Composite:       return "Falloff";  // never a stage's own type
        }
    }

    override void drawProperties() {
        // Shape preset, per-axis Auto Size, and Reverse all moved into the
        // config-driven Tool Properties form (config/forms/falloff.yaml):
        //   * shape   → "Shape Preset" dropdown (exposed in params()).
        //   * autosize→ "Auto Size" X/Y/Z button row (tool.pipe.attr autosize).
        //   * reverse → "Reverse" button (tool.pipe.attr reverse).
        // Nothing left for the legacy imperative panel to draw.
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
        if (mesh_ is null || editMode_ is null) { selWeights_.length = 0; return; }
        size_t nVerts = mesh_.vertices.length;
        if (nVerts == 0) { selWeights_.length = 0; return; }

        // --- Cache gate -------------------------------------------------
        // selWeights_ is position-independent. If every key field matches
        // the cached values AND the buffer is the right length, the result
        // is identical to last frame — reuse it and skip the smoothing.
        int stepsI = cast(int)dist;
        if (stepsI < 0) stepsI = 0;
        const ulong  mutVer    = mesh_.mutationVersion;
        const int    editModeI = cast(int)(*editMode_);
        const ulong  selSig    = selectionSignature();
        if (_selCacheValid
         && selWeights_.length == nVerts
         && _selCacheMutVer   == mutVer
         && _selCacheEditMode == editModeI
         && _selCacheSelSig   == selSig
         && _selCacheSteps    == stepsI
         && _selCacheShape    == shape
         && _selCacheIn       == in_
         && _selCacheOut      == out_)
            return; // hit — keep the existing selWeights_ slice as-is.

        selWeights_.length = 0;

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
        if (!hasAny) {
            // Empty selection → empty weights (caller treats as "no
            // constraint", moves everything). selWeights_ is already
            // length 0; leave the cache invalid — the empty-selection path
            // is just a hasAny() query, so re-running it per frame is cheap
            // and the length-0 buffer can never satisfy the hit guard
            // (nVerts > 0 here) anyway.
            _selCacheValid = false;
            return;
        }

        bool[] inSel = new bool[](nVerts);
        foreach (vi; selVertsList) {
            if (vi >= 0 && cast(size_t)vi < nVerts) inSel[vi] = true;
        }

        // Vertex→neighbor CSR adjacency. Edge lengths used to be required
        // for the Dijkstra-based weight pass; the iterative Laplacian
        // smoothing below ignores them (each in-selection neighbour
        // contributes equally). Built once per topology version (cached
        // across drag frames) — no per-call uint[][] GC churn.
        ensureVertexAdjacency();

        // Boundary verts: selected with ≥1 unselected neighbour.
        // These are pinned to weight 0 across the smoothing — the
        // "soft border" hinge.
        bool[] isB = new bool[](nVerts);
        foreach (vi; 0 .. nVerts) {
            if (!inSel[vi]) continue;
            foreach (n; _adjNeighbors[_adjOffset[vi] .. _adjOffset[vi + 1]]) {
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
        // stepsI computed at the cache gate above.
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
                foreach (n; _adjNeighbors[_adjOffset[vi] .. _adjOffset[vi + 1]]) {
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

        storeSelCacheKey(mutVer, editModeI, selSig, stepsI);
    }

    // Cheap rolling hash of the Select bit across the marks array relevant
    // to the active edit mode (mirrors ActionCenterStage.selectionSignature).
    // Selection writes bump no version counter, so this folds WHICH elements
    // are selected (and how many) into the cache key. A collision would only
    // ever produce a stale weight map, and the selection is frozen during a
    // drag, so this is safe for cache-key use.
    ulong selectionSignature() const {
        if (mesh_ is null || editMode_ is null) return 0;
        ulong h = 1469598103934665603UL; // FNV-1a offset basis
        void mix(ulong x) { h ^= x; h *= 1099511628211UL; }
        const(uint)[] marks;
        final switch (*editMode_) {
            case EditMode.Vertices: marks = mesh_.vertexMarks; break;
            case EditMode.Edges:    marks = mesh_.edgeMarks;   break;
            case EditMode.Polygons: marks = mesh_.faceMarks;   break;
        }
        mix(marks.length);
        foreach (i, m; marks)
            if (m & 1 /*Marks.Select*/) mix(cast(ulong)i + 1);
        return h;
    }

    // Build (or reuse) the vertex→neighbor CSR adjacency from mesh_.edges.
    // Topology-invariant, so it is rebuilt only when mutationVersion moves.
    void ensureVertexAdjacency() {
        const size_t nV = mesh_.vertices.length;
        if (_adjMutVer == mesh_.mutationVersion
         && _adjOffset.length == nV + 1)
            return;
        // Counting pass → per-vertex degree, then prefix-sum into offsets.
        _adjOffset.length = nV + 1;
        _adjOffset[] = 0;
        foreach (e; mesh_.edges) {
            if (e[0] >= nV || e[1] >= nV) continue;
            _adjOffset[e[0] + 1]++;
            _adjOffset[e[1] + 1]++;
        }
        foreach (i; 1 .. nV + 1) _adjOffset[i] += _adjOffset[i - 1];
        _adjNeighbors.length = _adjOffset[nV];
        // Fill pass with a temporary cursor per vertex.
        auto cursor = new size_t[](nV);
        foreach (i; 0 .. nV) cursor[i] = _adjOffset[i];
        foreach (e; mesh_.edges) {
            if (e[0] >= nV || e[1] >= nV) continue;
            _adjNeighbors[cursor[e[0]]++] = e[1];
            _adjNeighbors[cursor[e[1]]++] = e[0];
        }
        _adjMutVer = mesh_.mutationVersion;
    }

    // Record the current cache key as valid. Shape params are captured here
    // (not passed) since they are stage fields read directly.
    void storeSelCacheKey(ulong mutVer, int editModeI, ulong selSig, int stepsI) {
        _selCacheValid    = true;
        _selCacheMutVer   = mutVer;
        _selCacheEditMode = editModeI;
        _selCacheSelSig   = selSig;
        _selCacheSteps    = stepsI;
        _selCacheShape    = shape;
        _selCacheIn       = in_;
        _selCacheOut      = out_;
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
            // ACTION pseudo-attrs (fire-only `cmd` form rows, not readable state
            // — deliberately absent from knownAttrs()/listAttrs()). Both operate
            // on the Linear start/end endpoints, so they no-op for other types.
            case "autosize": {
                if (type != FalloffType.Linear) return true;   // no-op, not error
                if      (value == "x" || value == "0") autoSizeAxis(0);
                else if (value == "y" || value == "1") autoSizeAxis(1);
                else if (value == "z" || value == "2") autoSizeAxis(2);
                else return false;
                return true;
            }
            case "reverse": {
                if (type == FalloffType.Linear) {
                    Vec3 t = start; start = end; end = t;
                }
                return true;   // no-op for non-Linear, not an error
            }
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
            case "mix":
                // Multi-falloff Mix Mode wire keys (5): multiply / add /
                // subtract / max / min. Bogus values are refused so the
                // field keeps its previous value (mirrors `connect`/`mode`).
                if      (value == "multiply") { mix = FalloffMix.Multiply; return true; }
                else if (value == "add")      { mix = FalloffMix.Add;      return true; }
                else if (value == "subtract") { mix = FalloffMix.Subtract; return true; }
                else if (value == "max")      { mix = FalloffMix.Max;      return true; }
                else if (value == "min")      { mix = FalloffMix.Min;      return true; }
                return false;
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
            case FalloffType.Composite:       return "composite";  // never a stage's own type
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

    string mixLabel() const {
        final switch (mix) {
            case FalloffMix.Multiply: return "multiply";
            case FalloffMix.Add:      return "add";
            case FalloffMix.Subtract: return "subtract";
            case FalloffMix.Max:      return "max";
            case FalloffMix.Min:      return "min";
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
        // Only the PRIMARY drives the shared status-bar Falloff pulldown
        // state path. Stacked `falloff#N` extras must NOT clobber the
        // primary's `falloff/*` popup-state (they render via the legacy
        // Tool Properties panel, not the status pulldown). Guarding here
        // keeps the pulldown a faithful mirror of the primary, exactly as
        // before stacking existed.
        if (!isPrimary()) return;
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
            case FalloffType.Composite:
                // Never a stage's own type — nothing to auto-size.
                break;
        }
    }
}

// ---------------------------------------------------------------------------
// Set-aware falloff CONFIG snapshot / restore
//
// The single-stage `snapshotConfigToPacket` / `restoreConfigFromPacket` above
// round-trip ONE FalloffStage's user-facing config. When multiple falloff
// instances are stacked at runtime (`falloff.add radial`, …) the in-session
// re-grade undo/redo hooks must snapshot + restore the WHOLE active set, not
// just the primary, or an in-session Ctrl+Z would leave the secondary
// instances at their post-tweak config while reverting the primary.
//
// `FalloffSetSnapshot` pairs each captured stage REFERENCE with its config
// packet. Restore is keyed by identity (the captured stage ref), NOT by blind
// index against a freshly-queried list, so it always targets the same instance
// even if the pipe order shifts between snapshot and restore. The active set
// does not change mid-gesture (add/remove is a pipeline mutation outside a
// gesture), so the captured ref list stays valid for the hook's lifetime.
//
// SINGLE-FALLOFF BYTE-STABILITY: with exactly one falloff the snapshot is a
// 1-element list and restore calls `restoreConfigFromPacket` on that one stage
// — identical to the prior single-stage path.
struct FalloffSetSnapshot {
    FalloffStage[]  stages;   // captured instance refs (identity keys)
    FalloffPacket[] cfgs;     // cfgs[i] = stages[i].snapshotConfigToPacket()

    bool empty() const { return stages.length == 0; }
    size_t count() const { return stages.length; }
}

/// Snapshot the CONFIG of every stage in `set` (typically
/// `falloffStagesForHooks()` in pipe order). Each stage's config is captured
/// via its own `snapshotConfigToPacket`; the stage ref is retained so restore
/// can target the same instance by identity.
FalloffSetSnapshot snapshotFalloffSet(FalloffStage[] set) {
    FalloffSetSnapshot s;
    foreach (st; set) {
        if (st is null) continue;
        s.stages ~= st;
        s.cfgs   ~= st.snapshotConfigToPacket();
    }
    return s;
}

/// Restore every captured stage's config from the snapshot, keyed by the
/// retained stage reference (identity), not by index against a re-query.
void restoreFalloffSet(ref FalloffSetSnapshot s) {
    foreach (i, st; s.stages) {
        if (st is null) continue;
        st.restoreConfigFromPacket(s.cfgs[i]);
    }
}

/// Restore a falloff SET from a COMBINED published packet (the WGHT combiner's
/// output). For a single active falloff the combined packet IS the primary's
/// own config, so the one stage is restored from it directly (byte-identical to
/// the prior `restoreConfigFromPacket(combined)` path). For a multi-falloff
/// Composite the per-stage configs live in `combined.contributors`, built by
/// the combiner in the SAME pipe order as `findAllByTask(Wght)` — so stage[i]
/// is restored from `contributors[i]`. The stage set does not change across the
/// re-grade window, so the positional pairing is stable.
///
/// `set` is the live stage list at restore time (e.g. `falloffStagesForHooks()`
/// resolved inside the hook). Any length mismatch (stage count vs contributor
/// count) falls back to restoring only what pairs up — defensive, never throws.
void restoreFalloffSetFromCombined(FalloffStage[] set,
                                   const ref FalloffPacket combined) {
    if (set.length == 0) return;
    if (combined.type == FalloffType.Composite) {
        immutable size_t n = set.length < combined.contributors.length
                           ? set.length : combined.contributors.length;
        foreach (i; 0 .. n) {
            if (set[i] is null) continue;
            set[i].restoreConfigFromPacket(combined.contributors[i]);
        }
    } else {
        // Single active falloff: the published packet is the primary's own
        // config. Restore the first (primary) stage from it; any extra stages
        // (shouldn't exist when the packet is non-Composite) are left as-is.
        if (set[0] !is null)
            set[0].restoreConfigFromPacket(combined);
    }
}
