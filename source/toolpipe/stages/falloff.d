module toolpipe.stages.falloff;

import std.format    : format;
import std.conv      : to;
import std.string    : split, strip;
import std.math      : abs;

import math : Vec3, Viewport, dot, projectToWindowFull;
import std.math : sqrt;
import mesh : Mesh, MapDomain, MeshCacheKey;
import editmode : EditMode;
import toolpipe.stage    : Stage, TaskCode, ordWght;
import toolpipe.pipeline : g_pipeCtx;
import toolpipe.packets  : FalloffConfig, FalloffPacket, FalloffType, FalloffShape,
                            FalloffMix, LassoStyle, ElementConnect, ElementMode;
import operator          : Operator, Task, VectorStack, PacketKind;
import toolpipe.stages.workplane : WorkplaneStage;
import popup_state       : setStatePath;
import params            : Param, ParamHints, IntEnumEntry, wireTagForValue, valueForWireTag;

// ---------------------------------------------------------------------------
// Single-sourced enum token<->value tables (task 0184 / audit-2 C2). Each
// table used to be rebuilt inline in params() (rebuilding a fresh array every
// call) AND re-expressed as a hand-written parse switch (applySetAttr) AND a
// hand-written stringify switch (*Label()) — three bodies per enum, prone to
// drift. Now params()/applySetAttr/*Label() all read the SAME `static
// immutable` table via wireTagForValue/valueForWireTag. `type` is NOT one of
// these five — it is status-bar-owned (falloffTypeFromName/typeLabel), not a
// Param.
// ---------------------------------------------------------------------------
private static immutable IntEnumEntry[] lassoEntries = [
    IntEnumEntry(cast(int)LassoStyle.Freehand,  "freehand", "Freehand"),
    IntEnumEntry(cast(int)LassoStyle.Rectangle, "rect",     "Rectangle"),
    IntEnumEntry(cast(int)LassoStyle.Circle,    "circle",   "Circle"),
    IntEnumEntry(cast(int)LassoStyle.Ellipse,   "ellipse",  "Ellipse"),
];

private static immutable IntEnumEntry[] elementModeEntries = [
    IntEnumEntry(cast(int)ElementMode.Auto,    "auto",    "Auto"),
    IntEnumEntry(cast(int)ElementMode.Vertex,  "vertex",  "Vertex"),
    IntEnumEntry(cast(int)ElementMode.Edge,    "edge",    "Edge"),
    IntEnumEntry(cast(int)ElementMode.Polygon, "polygon", "Polygon"),
];

private static immutable IntEnumEntry[] elementConnectEntries = [
    IntEnumEntry(cast(int)ElementConnect.Ignore,          "ignore",          "Ignore"),
    IntEnumEntry(cast(int)ElementConnect.UseConnectivity, "useConnectivity", "Use Connectivity"),
    IntEnumEntry(cast(int)ElementConnect.Rigid,           "rigid",           "Rigid Connections"),
    IntEnumEntry(cast(int)ElementConnect.EdgeLoops,       "edgeLoops",       "Edge Loops"),
];

private static immutable IntEnumEntry[] mixEntries = [
    IntEnumEntry(cast(int)FalloffMix.Multiply, "multiply", "Multiply"),
    IntEnumEntry(cast(int)FalloffMix.Add,      "add",      "Add"),
    IntEnumEntry(cast(int)FalloffMix.Subtract, "subtract", "Subtract"),
    IntEnumEntry(cast(int)FalloffMix.Max,      "max",      "Max"),
    IntEnumEntry(cast(int)FalloffMix.Min,      "min",      "Min"),
];

private static immutable IntEnumEntry[] shapeEntries = [
    IntEnumEntry(cast(int)FalloffShape.Linear,  "linear",  "Linear"),
    IntEnumEntry(cast(int)FalloffShape.EaseIn,  "easeIn",  "Ease-In"),
    IntEnumEntry(cast(int)FalloffShape.EaseOut, "easeOut", "Ease-Out"),
    IntEnumEntry(cast(int)FalloffShape.Smooth,  "smooth",  "Smooth"),
    IntEnumEntry(cast(int)FalloffShape.Custom,  "custom",  "Custom"),
];

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
    // Config field-set (type/shape/start/end/center/size/normal/pickedRadius/
    // connect/elementMode/steps/anchorRing/screenCx/…/mapName) — the SAME
    // struct FalloffPacket embeds, so evaluate()/snapshotConfigToPacket()/
    // restoreConfigFromPacket()/reset() all copy this ONE value instead of a
    // hand-maintained field list (task 0179 / audit-2 F1). `alias config
    // this` keeps every unqualified `type` / `start` / `pickedRadius` / …
    // read-or-write below (and every external `stage.<field>` reader)
    // resolving exactly as before.
    FalloffConfig config;
    alias config this;

    // userLocked: true when the user EXPLICITLY chose this falloff (status-bar
    // type pulldown → `tool.pipe.attr falloff type <X>`, or a `falloff.<type>`
    // sub-tool). resetTransientPipeStages (tool.set / tool switch) then SKIPS
    // resetting it, so a user-set falloff survives a tool change — matching the
    // reference editor (parity captured 2026-06-16). A preset-BUNDLED falloff applies
    // its type via Stage.setAttr directly (not through a command), never sets
    // this flag, and so stays transient (resets on the next tool switch).
    // Cleared by reset() (full reset / SceneReset) and by selecting type=none.
    bool userLocked = false;
    // NOTE: the Element-falloff sphere RADIUS (wire attr `dist`), the
    // Selection "Steps" BFS-hop count, the Connected-Elements `connect` gate,
    // the Element pick-type `elementMode`, and the raw picked `anchorRing`
    // (weight=1.0 short-circuit indices) all now live in the embedded
    // `FalloffConfig` above (`config.pickedRadius` / `config.steps` /
    // `config.connect` / `config.elementMode` / `config.anchorRing` —
    // resolved unqualified below via `alias config this`). `connectMask`
    // just below is the DERIVED BFS-component mask (not config — rebuilt
    // every evaluate() from `anchorRing` + mesh edge-adjacency, see
    // resolveConnectMask), so it stays a direct stage field.
    bool[]         connectMask;
    // Resolved world positions of `anchorRing`, parallel to it. Owned by
    // the stage so the slice published on the packet (pkt.anchorPos) stays
    // valid for the whole pipe walk. Rebuilt every evaluate() from the live
    // mesh; out-of-range indices are skipped (so a stale ring after a
    // topology edit degrades gracefully rather than reading garbage).
    private Vec3[] anchorPos_;
    // Headless-resolved connected-component mask, parallel to mesh
    // vertices. Owned by the stage (like anchorPos_) so the slice
    // published on the packet stays valid for the whole pipe walk.
    // Rebuilt every evaluate() from `anchorRing` + mesh edge-adjacency
    // when the interactive click-pick did NOT already fill `connectMask`
    // (so headless tool.doApply gets connectivity gating too). Empty
    // when `connect == Ignore`, the ring is empty, or the mesh is null.
    private bool[] connectMask_;
    // Edge-Loops resolved ring (ordered loop vertex indices). Owned by the
    // stage (like anchorPos_ / connectMask_) so the slice published on
    // pkt.anchorRing stays valid for the whole pipe walk. Populated only
    // when `connect == EdgeLoops` and the picked element is an edge (a
    // 2-vert `anchorRing`); empty otherwise (the packet then uses the raw
    // `anchorRing`). When `anchorRing` already holds ≥3 verts it is treated
    // as a pre-resolved ring and copied through verbatim (idempotent), so
    // scripted tests can set the full ring directly via `anchorRing`.
    private uint[] loopRing_;
    // NOTE: `config.elementMode` (Element pick-type restriction),
    // `config.screenCx/screenCy/screenSize/transparent` (Screen),
    // `config.lassoStyle/lassoPolyX/lassoPolyY/softBorderPx` (Lasso),
    // `config.in_/out_` (Custom-shape tangents), and `config.mix`
    // (multi-falloff Mix Mode) now live in the embedded `FalloffConfig`
    // above — see that struct's field docs for the full semantics
    // previously documented at each of these decls.

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
    // mode), `steps` (→ stepsI/iters), and the shape params (shape/in_/out_).
    // ALL of those are frozen during a transform drag (selection frozen,
    // topology frozen — transform tools mutate vertex POSITIONS directly
    // without bumping mesh.mutationVersion). So the map can be computed
    // ONCE per drag and reused across the ~17 iteration frames, instead of
    // re-running the Laplacian smoothing every pipe walk. We cache it keyed
    // on (mutationVersion, editMode, selectionSignature, stepsI, shape,
    // in_, out_); a key miss recomputes.
    private float[] selWeights_;

    // VertexMap: `config.mapName` (embedded above) names the active weight
    // map; `vertexMapWeights_` is the pre-baked weight buffer. The buffer is
    // re-baked in evaluate() whenever type == VertexMap and is cleared by
    // reset(). NOT cached by mutationVersion (mesh maps can change without
    // bumping the topology version) — always rebaked every pipe walk.
    private float[] vertexMapWeights_;

    // --- selWeights_ cache key (see recomputeSelectionWeights) ---
    // mutationVersion bumps on every topology/geometry-structure edit and is
    // NOT bumped by selection writes nor drag-time vertex moves. Selection
    // lives in the Marks.Select bit and has no version counter, so a cheap
    // FNV-1a rolling hash over the selected-element set is folded into the
    // key (mirrors ActionCenterStage.selectionSignature). `_selCacheValid`
    // is force-cleared whenever the non-Selection branch in evaluate() runs,
    // so flipping the falloff type away from Selection and back recomputes.
    // `_selKey` folds the (address, mutationVersion) pair a plain
    // `_selCacheMutVer` used to carry — a stage cache lives OUTSIDE the Mesh
    // it reads (mesh_ is a live delegate that can silently retarget to a
    // different layer's primary), so the address term is required to stop
    // two distinct Mesh instances at an equal mutationVersion from aliasing
    // this cache. See mesh.d's MeshCacheKey doc comment.
    private bool   _selCacheValid    = false;
    private MeshCacheKey _selKey;
    private int    _selCacheEditMode = -1;
    private ulong  _selCacheSelSig   = 0;
    private int    _selCacheSteps    = int.min;
    private FalloffShape _selCacheShape = cast(FalloffShape)(-1);
    private float  _selCacheIn        = float.nan;
    private float  _selCacheOut       = float.nan;
    // Vertex→neighbor CSR adjacency is now owned by Mesh itself
    // (mesh_.vertexAdjacencyCSR) — a Mesh-owned cache cannot alias across
    // layers the way a stage-owned copy could, so no address key is needed
    // for it (the address IS the object). See mesh.d's vertexAdjacencyCSR
    // doc comment.

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
    ///
    /// `config = FalloffConfig.init` resets the WHOLE config field-set
    /// structurally (every field carries its declaration-time default per
    /// FalloffConfig's doc — no field can be forgotten the way a hand-listed
    /// reset previously forgot `connect`/`elementMode`/`dist`/`steps`, see
    /// [[falloff_reset_incomplete_bleed]]). This is a MORE COMPLETE reset than
    /// before: the prior hand-written reset() did not touch `normal` (cylinder
    /// axis) or clear `anchorPos_`; this one does (config.normal resets to
    /// (0,1,0), and the derived-buffer clears below still zero anchorPos_) —
    /// intentional robustness fix, not a byte-stability regression, per task
    /// 0179 guardrail #2.
    override void reset() {
        config = FalloffConfig.init;
        loopRing_.length     = 0;
        connectMask_.length  = 0;
        connectMask.length   = 0;
        anchorPos_.length    = 0;
        userLocked   = false;   // full reset clears the user-lock (SceneReset)
        vertexMapWeights_.length = 0;
        // Drop the selection-weight cache so a fresh start recomputes.
        selWeights_.length = 0;
        _selCacheValid     = false;
        _selKey.invalidate();
        publishState();
    }

    /// resetTransient: same contract as ActionCenter/Axis — a full reset()
    /// UNLESS the user explicitly locked the falloff (userLocked), in which case
    /// it is preserved across the tool switch. Called by app.d's
    /// resetTransientPipeStages on every tool activation.
    void resetTransient() {
        if (userLocked) return;
        reset();
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
        // One copy site (task 0179): the whole config field-set travels in
        // one assignment instead of ~25 hand-listed `pkt.<field> = <field>;`
        // lines. `pkt.enabled` / `pkt.pickedCenter` / the derived buffers
        // below are NOT part of `config` (see FalloffPacket's doc) and are
        // still set individually.
        FalloffPacket pkt;
        pkt.config  = config;
        pkt.enabled = (type != FalloffType.None);
        // Sphere centre tracks ACEN.center. ACEN runs before us.
        if (auto acen = vts.get!ActionCenterPacket())
            pkt.pickedCenter = acen.center;
        // Edge-Loops: walk the quad edge-loop from the picked edge so the
        // ring (anchorRing + anchorPos) is the ORDERED loop. For other
        // connect modes this is a no-op (returns `anchorRing` unchanged).
        // Done BEFORE resolveConnectMask / resolveAnchorPos so both read
        // the resolved ring. Owned buffer → slice stays valid.
        resolveEdgeLoopRing();
        // Resolve the connected-component mask headless so `connect`
        // works in tool.doApply, not just on interactive click-pick.
        // When click-pick already filled `connectMask`, that takes
        // precedence; otherwise BFS the component(s) of `anchorRing`
        // over mesh edge-adjacency (mirrors resolveAnchorPos()).
        resolveConnectMask();
        pkt.connectMask  = (connectMask.length > 0) ? connectMask
                                                    : cast(bool[]) connectMask_;
        // Published ring is the RESOLVED ring (EdgeLoops substitutes the
        // ordered loop) — overwrites the RAW `config.anchorRing` the bulk
        // copy above just carried over. `snapshotConfigToPacket` (config
        // round-trip) keeps the RAW ring; see FalloffConfig.anchorRing doc.
        pkt.config.anchorRing = (loopRing_.length > 0) ? loopRing_ : anchorRing;
        // Resolve the picked element's vert indices → world positions so
        // the Element falloff can attenuate by distance to the element
        // GEOMETRY (segment / face), not the centroid point. Owned buffer
        // → slice stays valid for the pipe walk.
        resolveAnchorPos();
        pkt.anchorPos    = anchorPos_;
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

        // VertexMap: bake per-vertex weights from the named Point dim-1 map.
        // Rebaked every pipe walk (mesh maps can change without bumping the
        // topology version). An empty / missing name, null mesh, or absent map
        // leaves vertexMapWeights_ empty → evaluateFalloff returns 1.0 per vert.
        if (type == FalloffType.VertexMap) {
            auto m = mesh_;
            if (m !is null && mapName.length > 0) {
                auto map = m.meshMap(mapName);
                if (map !is null && map.domain == MapDomain.Point && map.dim == 1) {
                    vertexMapWeights_.length = map.data.length;
                    vertexMapWeights_[] = map.data[];
                } else {
                    vertexMapWeights_.length = 0;
                }
            } else {
                vertexMapWeights_.length = 0;
            }
        } else {
            vertexMapWeights_.length = 0;
        }
        pkt.vertexMapWeights = vertexMapWeights_;
        pkt.compoundPasses   = 1.0f;

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
    /// from this stage's own fields — now the WHOLE `FalloffConfig`, including
    /// `steps` and `mapName`, which previously had no packet field at all and
    /// so were silently NOT restored — task 0179 fix). It does NOT touch the
    /// ACEN-owned sphere centre (`pickedCenter`) — that pivot has its own
    /// source of truth + its own pin hooks — nor the derived caches
    /// (selWeights_, adjacency, connectMask), which rebuild on the next
    /// evaluate().
    void restoreConfigFromPacket(const ref FalloffPacket p) {
        config = p.config.dup();
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
    /// Captures the WHOLE `FalloffConfig` (same set restoreConfigFromPacket
    /// consumes — now including `steps` / `mapName`). It deliberately does NOT
    /// capture the ACEN-owned sphere centre (`pickedCenter`) or the derived
    /// caches — restoreConfigFromPacket would not consume them anyway.
    /// `config.dup()` deep-copies the slice members so the snapshot is
    /// independent of subsequent in-place stage mutation.
    FalloffPacket snapshotConfigToPacket() const {
        FalloffPacket p;
        p.config  = config.dup();
        p.enabled = (type != FalloffType.None);
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
    // Derived from `listAttrs()` (its names ARE the authoritative attr set)
    // instead of a second hand-maintained literal — the two could no longer
    // drift apart. The `applySetAttr` leg still can't be derived (it's a
    // hand-written string-switch parser, not enumerable), so it stays
    // in sync via the enforced invariant in the unittest at the bottom of
    // this file (every `listAttrs()` name must round-trip through a dry-run
    // `applySetAttr`), rather than a "keep in sync" comment.
    override string[] knownAttrs() {
        import std.algorithm : map;
        import std.array     : array;
        return listAttrs().map!(a => a[0]).array;
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
            ["dist",         format("%g", pickedRadius)],
            ["steps",        format("%d", steps)],
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
            ["map",          mapName],
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
        //
        // The five IntEnumEntry tables (lasso/elementMode/elementConnect/
        // mix/shape) are single-sourced module-level `static immutable`
        // constants (top of file) — read here AND by applySetAttr's parse
        // legs AND by the *Label() stringifiers, so the tables can no longer
        // drift apart the way three separately hand-written bodies could.
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
                                 cast(int*)&config.mix, mixEntries,
                                 cast(int)FalloffMix.Multiply);

        // Shape preset — the weight-curve shape (Linear / Ease-In / Ease-Out /
        // Smooth / Custom). Exposed as a form dropdown (config/forms/falloff.yaml
        // "Shape Preset"); the legacy drawProperties() popup that used to render
        // it was retired in favour of this row.
        //
        // NOT exposed for the Screen type: screenWeight() uses a FIXED linear
        // ramp (matching the reference editor's screen falloff, which has no
        // shape control), so the preset would be inert. Omitting it from
        // params() makes the forms resolver hide the Shape Preset + In/Out rows
        // for screen (value-driven row hiding), same as a per-type field.
        if (type != FalloffType.Screen) {
            ps ~= Param.intEnum_("shape", "Shape Preset",
                                 cast(int*)&config.shape, shapeEntries,
                                 cast(int)FalloffShape.Smooth);

            // In/Out tangent params are Custom-shape-only.
            if (shape == FalloffShape.Custom) {
                ps ~= Param.float_("in",  "In",  &config.in_,  0.5f).min(0.0f).max(1.0f)
                           .widget(ParamHints.Widget.Slider);
                ps ~= Param.float_("out", "Out", &config.out_, 0.5f).min(0.0f).max(1.0f)
                           .widget(ParamHints.Widget.Slider);
            }
        }
        // Per-type geometry config.
        final switch (type) {
            case FalloffType.None:
                break;   // unreachable due to early-return above
            case FalloffType.Linear:
                ps ~= Param.vec3_("start", "Start", &config.start, Vec3(0, 0, 0));
                ps ~= Param.vec3_("end",   "End",   &config.end,   Vec3(0, 1, 0));
                break;
            case FalloffType.Radial:
                ps ~= Param.vec3_("center", "Center", &config.center, Vec3(0, 0, 0));
                ps ~= Param.vec3_("size",   "Size",   &config.size,   Vec3(1, 1, 1));
                break;
            case FalloffType.Screen:
                ps ~= Param.float_("screenCx",   "Screen Cx",   &config.screenCx,   0.0f);
                ps ~= Param.float_("screenCy",   "Screen Cy",   &config.screenCy,   0.0f);
                ps ~= Param.float_("screenSize", "Screen Size", &config.screenSize, 64.0f);
                ps ~= Param.bool_ ("transparent", "Transparent", &config.transparent, false);
                break;
            case FalloffType.Lasso:
                ps ~= Param.intEnum_("lassoStyle", "Lasso Style",
                                     cast(int*)&config.lassoStyle, lassoEntries,
                                     cast(int)LassoStyle.Freehand);
                ps ~= Param.float_("softBorder", "Soft Border", &config.softBorderPx, 16.0f);
                break;
            case FalloffType.Cylinder:
                ps ~= Param.vec3_("center", "Center", &config.center, Vec3(0, 0, 0));
                ps ~= Param.vec3_("size",   "Size",   &config.size,   Vec3(1, 1, 1));
                ps ~= Param.vec3_("axis",   "Axis",   &config.normal, Vec3(0, 1, 0));
                break;
            case FalloffType.Element:
                // Element Mode dropdown first — primary control, restricts
                // pick type (auto / vertex / edge / polygon).
                // The `falloff.element` `mode` UI dropdown.
                ps ~= Param.intEnum_("mode", "Element Mode",
                                     cast(int*)&config.elementMode, elementModeEntries,
                                     cast(int)ElementMode.Auto);
                ps ~= Param.float_("dist", "Range", &config.pickedRadius, 1.0f).min(1e-6f);
                ps ~= Param.intEnum_("connect", "Connected Elements",
                                     cast(int*)&config.connect, elementConnectEntries,
                                     cast(int)ElementConnect.Ignore);
                break;
            case FalloffType.Selection:
                // `falloff.selection` (attr `steps`) — the BFS-hop count, a
                // proper integer (discrete smoothing iterations).
                ps ~= Param.int_("steps", "Steps", &config.steps, 4).min(1);
                break;
            case FalloffType.Composite:
                // A FalloffStage's own `type` is never Composite — that
                // is a synthesized PACKET type the WGHT combiner publishes,
                // not a value any single stage holds. No per-type config.
                break;
            case FalloffType.VertexMap: {
                // Build weight-map name choices dynamically from the live mesh.
                // Choices are rebuilt per call to params() (per frame) so a newly
                // created weight map appears immediately. Empty / no-mesh
                // fallback: one disabled placeholder entry.
                import std.algorithm : map;
                import std.array : array;
                auto m = mesh_;
                string[] names = (m !is null) ? m.weightMapNames() : [];
                string[2][] choices;
                if (names.length == 0) {
                    choices = [["", "(no weight maps)"]];
                } else {
                    foreach (n; names)
                        choices ~= [n, n];
                }
                ps ~= Param.enum_("map", "Weight Map", &config.mapName, choices, "");
                break;
            }
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
            case FalloffType.VertexMap:       return "Vertex Map Falloff";
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
    ///   `steps · avg_sel_edge_length`. An empirical fit puts the exact G at
    /// `Steps · avg_edge · 0.81` (the 0.81 factor comes from the
    /// iterative smoothing convergence); we omit the 0.81 for
    /// cleanliness — at the cost of ~5 % residual.
    ///
    /// Empty selection → empty weight slice (caller treats as "no
    /// constraint", matching the "empty selection moves everything"
    /// convention every transform path uses).
    void recomputeSelectionWeights() {
        import std.math : sqrt, lround;
        if (mesh_ is null || editMode_ is null) { selWeights_.length = 0; return; }
        size_t nVerts = mesh_.vertices.length;
        if (nVerts == 0) { selWeights_.length = 0; return; }

        // --- Cache gate -------------------------------------------------
        // selWeights_ is position-independent. If every key field matches
        // the cached values AND the buffer is the right length, the result
        // is identical to last frame — reuse it and skip the smoothing.
        int stepsI = steps;
        if (stepsI < 0) stepsI = 0;
        const int    editModeI = cast(int)(*editMode_);
        const ulong  selSig    = selectionSignature();
        if (_selCacheValid
         && selWeights_.length == nVerts
         && _selKey.matches(*mesh_)
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
        // contributes equally). Owned by Mesh itself and rebuilt only when
        // mutationVersion moves — no per-call uint[][] GC churn.
        const(size_t)[] adjOffset;
        const(uint)[]    adjNeighbors;
        mesh_.vertexAdjacencyCSR(adjOffset, adjNeighbors);

        // Boundary verts: selected with ≥1 unselected neighbour.
        // These are pinned to weight 0 across the smoothing — the
        // "soft border" hinge.
        bool[] isB = new bool[](nVerts);
        foreach (vi; 0 .. nVerts) {
            if (!inSel[vi]) continue;
            foreach (n; adjNeighbors[adjOffset[vi] .. adjOffset[vi + 1]]) {
                if (!inSel[n]) { isB[vi] = true; break; }
            }
        }

        // Iterative Laplacian smoothing — a DIFFUSION APPROXIMATION of
        // the reference engine's selection-falloff weight. The reference's
        // exact operator is NOT a uniform Laplacian and is closed-source,
        // so this is meaningfully closer, not bit-perfect: an irreducible
        // ~4–9.5 % per-vertex residual remains across the steps range.
        //
        // Initial state: boundary (selection-border) verts = 0, interior
        // selected verts = 1. Each iteration replaces every interior weight
        // with the mean of its in-selection neighbours (α = 1.0 → pure
        // Jacobi neighbour-mean; over-relaxation α > 1 was tested and does
        // NOT help). Boundary stays pinned at 0 (the soft-border hinge).
        //
        // Iteration count scales QUADRATICALLY with steps:
        //   iters ≈ round(0.7·steps² + 2).
        // The smoothing is a diffusion process whose reach (how far the
        // weight gradient penetrates from the border) grows ∝ √iters; the
        // reference engine scales that reach LINEARLY in steps, so matching
        // it requires iters ∝ steps². With steps == 0 we collapse to no
        // smoothing — the selection-edge hinge is the whole weight map
        // (binary 0/1).
        enum float kLapAlpha = 1.0f;
        // stepsI computed at the cache gate above.
        int iters = (stepsI <= 0) ? 0 : cast(int) lround(0.7f * stepsI * stepsI + 2.0f);

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
                foreach (n; adjNeighbors[adjOffset[vi] .. adjOffset[vi + 1]]) {
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

        storeSelCacheKey(editModeI, selSig, stepsI);
    }

    // Cheap rolling hash of the Select bit across the marks array relevant
    // to the active edit mode. Selection writes bump no version counter, so
    // this folds WHICH elements are selected (and how many) into the cache
    // key. A collision would only ever produce a stale weight map, and the
    // selection is frozen during a drag, so this is safe for cache-key use.
    // Thin wrapper over the single canonical Mesh.selectionSignature (mirrors
    // ActionCenterStage.selectionSignature, which wraps the same call).
    ulong selectionSignature() const {
        if (mesh_ is null || editMode_ is null) return 0;
        return mesh_.selectionSignature(*editMode_);
    }

    // Resolve `anchorRing` vertex indices to their live world positions into
    // `anchorPos_` (parallel to anchorRing). Out-of-range indices are
    // skipped, so the two arrays may differ in length after a topology edit
    // left a stale ring — that is benign: elementWeight only cares about the
    // geometry the resolved positions describe (point / segment / polygon),
    // and the anchorRing→weight-1.0 short-circuit keys on indices separately.
    // When the mesh is unavailable or the ring is empty, anchorPos_ is empty
    // and elementWeight falls back to the pickedCenter point distance.
    void resolveAnchorPos() {
        anchorPos_.length = 0;
        // For Edge-Loops, resolve positions from the ordered loop ring so
        // the polyline distance in elementWeight runs over the actual loop.
        const(uint)[] ring = (loopRing_.length > 0) ? cast(const(uint)[])loopRing_
                                                     : cast(const(uint)[])anchorRing;
        if (ring.length == 0) return;
        Mesh* m = mesh_;
        if (m is null) return;
        const size_t nV = m.vertices.length;
        foreach (vi; ring)
            if (cast(size_t)vi < nV) anchorPos_ ~= m.vertices[vi];
    }

    // Edge-Loops ring resolver. When `connect == EdgeLoops`:
    //   * anchorRing has exactly 2 verts (a picked edge) → walk the quad
    //     edge-loop from that edge (mesh.edgeLoopRing) to build the ordered
    //     ring, stored in loopRing_.
    //   * anchorRing has ≥3 verts → treat it as a pre-resolved ring (a
    //     scripted full-ring set); copy it through verbatim (idempotent —
    //     the walk would otherwise re-seed from the first edge and mangle a
    //     ring that is already correct).
    // For every other connect mode loopRing_ is left empty (no-op) and the
    // packet uses the raw anchorRing.
    void resolveEdgeLoopRing() {
        loopRing_.length = 0;
        if (connect != ElementConnect.EdgeLoops) return;
        if (anchorRing.length >= 3) {
            loopRing_ = anchorRing.dup;        // pre-resolved ring
            return;
        }
        if (anchorRing.length != 2) return;    // need a picked edge
        Mesh* m = mesh_;
        if (m is null) return;
        import mesh : edgeLoopRing;
        loopRing_ = edgeLoopRing(*m, anchorRing[0], anchorRing[1]);
    }

    // Resolve the connected-component mask into `connectMask_` (parallel
    // to mesh vertices, `true` for verts reachable from any `anchorRing`
    // vert over mesh edge-adjacency). Mirrors resolveAnchorPos(): rebuilt
    // every evaluate() so headless tool.doApply gets connectivity gating
    // without an interactive click. No-op (empty mask) when connect is
    // Ignore, the ring is empty, or the mesh is unavailable — in which
    // case elementWeight falls back to the unrestricted sphere.
    void resolveConnectMask() {
        connectMask_.length = 0;
        if (connect == ElementConnect.Ignore) return;
        // EdgeLoops attenuates by polyline distance to the ordered loop ring,
        // not by connected-component membership — its elementWeight gate
        // explicitly excludes connectMask (see falloff.d elementWeight,
        // `connect != EdgeLoops`). So the BFS + allocation below would be
        // pure dead work for EdgeLoops; skip it (no behavior change).
        if (connect == ElementConnect.EdgeLoops) return;
        if (anchorRing.length == 0) return;
        Mesh* m = mesh_;
        if (m is null) return;
        const size_t nV = m.vertices.length;
        if (nV == 0) return;
        const(size_t)[] adjOffset;
        const(uint)[]    adjNeighbors;
        m.vertexAdjacencyCSR(adjOffset, adjNeighbors);   // Mesh-owned, mutVer-cached
        auto visited = new bool[](nV);
        size_t[] stack;
        foreach (vi; anchorRing) {
            if (cast(size_t)vi >= nV || visited[vi]) continue;
            visited[vi] = true;
            stack ~= cast(size_t)vi;
        }
        while (stack.length > 0) {
            size_t v = stack[$ - 1];
            stack.length -= 1;
            foreach (j; adjOffset[v] .. adjOffset[v + 1]) {
                size_t nb = adjNeighbors[j];
                if (!visited[nb]) { visited[nb] = true; stack ~= nb; }
            }
        }
        connectMask_ = visited;
    }

    // Record the current cache key as valid. Shape params are captured here
    // (not passed) since they are stage fields read directly.
    void storeSelCacheKey(int editModeI, ulong selSig, int stepsI) {
        _selCacheValid    = true;
        _selKey.stamp(*mesh_);
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
                import toolpipe.packets : falloffTypeFromName;
                FalloffType prev = type;
                if (value == "none") {
                    type = FalloffType.None;
                } else {
                    FalloffType t;
                    if (!falloffTypeFromName(value, t)) return false;
                    type = t;
                }
                // anchorRing is Element-only state — wipe on leaving
                // Element so a later switch back to Element starts
                // clean (no stale ring from the previous session).
                if (prev == FalloffType.Element && type != FalloffType.Element)
                    anchorRing.length = 0;
                return true;
            }
            case "shape": {
                int v;
                if (!valueForWireTag(shapeEntries, value, v)) return false;
                shape = cast(FalloffShape)v;
                return true;
            }
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
            case "dist":         pickedRadius = parseFloat(value); return true;
            case "steps":        steps = cast(int)parseFloat(value); return true;
            case "connect": {
                int v;
                if (!valueForWireTag(elementConnectEntries, value, v)) return false;
                connect = cast(ElementConnect)v;
                return true;
            }
            case "mode": {
                // 4-mode `element-mode` enum: auto / vertex / edge / polygon.
                // Retired tokens autoCent / edgeCent / polyCent are accepted
                // as PARSE-ONLY aliases for their bare equivalents (normalised
                // BEFORE the table lookup) so old scripts keep working;
                // listAttrs still echoes back the bare token (the table has
                // no alias entries — normalisation happens here, once).
                string tok = value;
                if      (tok == "autoCent") tok = "auto";
                else if (tok == "edgeCent") tok = "edge";
                else if (tok == "polyCent") tok = "polygon";
                int v;
                if (!valueForWireTag(elementModeEntries, tok, v)) return false;
                elementMode = cast(ElementMode)v;
                return true;
            }
            case "screenCx":   screenCx     = parseFloat(value); return true;
            case "screenCy":   screenCy     = parseFloat(value); return true;
            case "screenSize": screenSize   = parseFloat(value); return true;
            case "transparent":
                if      (value == "true"  || value == "1") { transparent = true;  return true; }
                else if (value == "false" || value == "0") { transparent = false; return true; }
                return false;
            case "lassoStyle": {
                int v;
                if (!valueForWireTag(lassoEntries, value, v)) return false;
                lassoStyle = cast(LassoStyle)v;
                return true;
            }
            case "softBorder": softBorderPx = parseFloat(value); return true;
            case "in":         in_          = parseFloat(value); return true;
            case "out":        out_         = parseFloat(value); return true;
            case "mix": {
                // Multi-falloff Mix Mode wire keys (5): multiply / add /
                // subtract / max / min. Bogus values are refused so the
                // field keeps its previous value (mirrors `connect`/`mode`).
                int v;
                if (!valueForWireTag(mixEntries, value, v)) return false;
                mix = cast(FalloffMix)v;
                return true;
            }
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
            case "map":
                mapName = value;
                return true;
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
            case FalloffType.VertexMap:       return "vertexMap";
        }
    }

    // The five table-backed stringifiers below all read the single-sourced
    // module-level tables (top of file) via wireTagForValue — the same
    // tables applySetAttr's parse legs read via valueForWireTag. `type` is
    // NOT one of these (see typeLabel() below, which stays on its own
    // falloffTypeFromName path — `type` isn't a Param table).
    string connectLabel() const {
        return wireTagForValue(elementConnectEntries, cast(int)connect);
    }

    string elementModeLabel() const {
        return wireTagForValue(elementModeEntries, cast(int)elementMode);
    }

    string shapeLabel() const {
        return wireTagForValue(shapeEntries, cast(int)shape);
    }

    string mixLabel() const {
        return wireTagForValue(mixEntries, cast(int)mix);
    }

    string lassoStyleLabel() const {
        return wireTagForValue(lassoEntries, cast(int)lassoStyle);
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
        setStatePath("falloff/types/vertexMap",
                     type == FalloffType.VertexMap ? "true" : "false");
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
                if (maxHalf > 0) pickedRadius = maxHalf;
                break;
            case FalloffType.Selection:
                // `steps` is the BFS-hop range — bbox sizing doesn't apply.
                // Pin to the default so a fresh selection switch starts clean.
                steps = 4;
                break;
            case FalloffType.Composite:
                // Never a stage's own type — nothing to auto-size.
                break;
            case FalloffType.VertexMap:
                // Weights come from a named map — no spatial auto-sizing.
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

// ---------------------------------------------------------------------------
// Regression guard for recomputeSelectionWeights() — locks the two empirically
// fitted smoothing constants (alpha = 1.0, iters = round(0.7*steps^2 + 2)). The
// asserts split into mesh-agnostic STRUCTURAL invariants (hold for any mesh)
// and a small FROZEN-OUTPUT table on one specific grid+selection (what fails
// if someone reverts alpha or relinearises the iteration count). The frozen
// values are NOT a reference-parity claim — recomputeSelectionWeights is a
// diffusion APPROXIMATION of the closed-source reference operator (~4-9.5 %
// per-vertex residual).
//
// READ-ONLY / side-effect-free: this block compiles into the live editor's
// unittest pass, so it only constructs a throwaway Mesh + FalloffStage and
// reads computed state — it never touches global/shared editor state.
unittest {
    import mesh : makeGridPlane;
    import std.math : abs, isNaN;

    // makeGridPlane(8): a flat 9x9 vertex grid (vertex(i,j) = i*9 + j) of
    // 8x8 = 64 quad faces (face(i,j) = i*8 + j). We select the interior
    // 6x6 block of faces (rows/cols 1..6) so the selection has a clear
    // one-quad-deep border plus a genuine interior.
    enum int N    = 8;          // faces per side
    enum int side = N + 1;      // verts per side (9)
    Mesh grid = makeGridPlane(N);
    grid.resetSelection(); // size the selection-mark arrays to match geometry

    // Border-distance INTO the selection: the selected faces span face
    // rows/cols 1..6, so selected verts span vertex rows/cols 1..7.
    // hopDepth(i,j) = min(i, j, 8-i, 8-j) - 1: 0 on the selection border,
    // growing inward. Deepest interior verts are the centre 2x2 (depth 3).
    // Returns < 0 for verts outside the selected block.
    static int hopDepth(int i, int j) {
        int d = i;
        if (j < d) d = j;
        if (side - 1 - i < d) d = side - 1 - i;
        if (side - 1 - j < d) d = side - 1 - j;
        return d - 1;
    }

    // A FalloffStage bound to the grid via a delegate; editMode in Polygons.
    EditMode em = EditMode.Polygons;
    Mesh* meshPtr = &grid;
    auto fs = new FalloffStage(() => meshPtr, &em);
    fs.type = FalloffType.Selection;

    // Select the interior 6x6 block of faces (rows/cols 1..6).
    foreach (i; 1 .. N - 1)
        foreach (j; 1 .. N - 1)
            grid.selectFace(i * N + j);

    int vi(int i, int j) { return i * side + j; }

    // --- steps == 0: binary hinge map (no smoothing) -----------------------
    fs.steps = 0;
    fs.recomputeSelectionWeights();
    assert(fs.selWeights_.length == grid.vertices.length);
    foreach (i; 1 .. side - 1)
        foreach (j; 1 .. side - 1) {
            int hd = hopDepth(i, j);
            if (hd < 0) continue; // not a selected vert
            // applyShape(1 - w): boundary w=0 -> applyShape(1)=0; interior
            // w=1 -> applyShape(0)=1. So selected interior == 1, border == 0.
            float got = fs.selWeights_[vi(i, j)];
            if (hd == 0)
                assert(abs(got - 0.0f) < 1e-6f, "steps=0 border must be 0");
            else
                assert(abs(got - 1.0f) < 1e-6f, "steps=0 interior must be 1");
        }

    // --- steps > 0: smoothed weights, border pinned to 0, monotone with hop
    // depth, bounded in [0,1]. NOTE on direction: more steps == more diffusion
    // passes == the falloff reaches FARTHER from the pinned-0 border, so the
    // interior weight DECREASES as steps grow (at steps=1 the centre still
    // sits near 1; by steps=6 it has bled almost to 0). The "deepest interior
    // > 0.9" saturation invariant therefore holds at the shallow end
    // (steps=1); the in-range + border-pin + monotone invariants hold at
    // every steps>0.
    fs.steps = 2;
    fs.recomputeSelectionWeights();
    auto w2 = fs.selWeights_;
    foreach (i; 1 .. side - 1)
        foreach (j; 1 .. side - 1) {
            int hd = hopDepth(i, j);
            if (hd < 0) continue;
            float got = w2[vi(i, j)];
            assert(!isNaN(got));
            assert(got >= -1e-6f && got <= 1.0f + 1e-6f, "weight in [0,1]");
            if (hd == 0) assert(abs(got) < 1e-6f, "border vert must be 0");
        }
    // Monotone non-decreasing along a straight ray from the border into the
    // deepest interior: (4,1)->(4,2)->(4,3)->(4,4) has hopDepth 0,1,2,3.
    assert(w2[vi(4, 1)] <= w2[vi(4, 2)] + 1e-6f);
    assert(w2[vi(4, 2)] <= w2[vi(4, 3)] + 1e-6f);
    assert(w2[vi(4, 3)] <= w2[vi(4, 4)] + 1e-6f);

    // Deepest-interior selected vert (centre, hopDepth 3) saturates near 1 at
    // the shallow end (steps=1, before the falloff has bled inward).
    fs.steps = 1;
    fs.recomputeSelectionWeights();
    auto w1 = fs.selWeights_;
    assert(w1[vi(4, 4)] > 0.9f, "deepest interior must exceed 0.9 at steps=1");

    // --- FROZEN OUTPUT -----------------------------------------------------
    // Frozen output of alpha = 1.0 / iters = round(0.7*steps^2 + 2) on this
    // exact grid + selection — locks the constants; NOT a reference-parity
    // claim. (Reverting alpha to 0.76 or relinearising iters to 4*steps+1
    // changes these and fails here.) Tolerance 1e-4 absorbs float-order noise.
    assert(abs(w2[vi(4, 2)] - 0.320533f) < 1e-4f); // steps=2, hopDepth 1
    assert(abs(w2[vi(4, 3)] - 0.718783f) < 1e-4f); // steps=2, hopDepth 2
    assert(abs(w2[vi(4, 4)] - 0.830364f) < 1e-4f); // steps=2, hopDepth 3 (centre)
    assert(abs(w2[vi(3, 3)] - 0.593262f) < 1e-4f); // steps=2, off-axis interior
    assert(abs(w1[vi(4, 4)] - 0.988770f) < 1e-4f); // steps=1 centre (near 1)
}

// ---------------------------------------------------------------------------
// Task 0179 Stage 4: enforced invariant replacing the retired "KEEP IN SYNC
// with applySetAttr" comment on knownAttrs()/listAttrs(). knownAttrs() is now
// DERIVED from listAttrs() (can't drift from it structurally), but
// applySetAttr is a hand-written string-switch parser that can't be derived
// the same way — so this unittest pins the remaining half of the invariant:
// every name listAttrs() reports must be a name applySetAttr actually
// accepts, round-tripping the CURRENT value back through a dry-run setAttr.
// A name present in listAttrs() but rejected by applySetAttr (or vice versa,
// caught indirectly since knownAttrs() == listAttrs() names by construction)
// would fail here instead of silently drifting.
// ---------------------------------------------------------------------------
unittest {
    auto fs = new FalloffStage();
    // Default-state stage — listAttrs() always reports the full static attr
    // set regardless of the active type (only params(), the Tool Properties
    // schema, is type-filtered), so one pass over the default values already
    // exercises every accepted attr name once.
    foreach (pair; fs.listAttrs()) {
        string name  = pair[0];
        string value = pair[1];
        assert(fs.applySetAttr(name, value),
               "listAttrs() name '" ~ name ~ "' (value '" ~ value
               ~ "') was rejected by applySetAttr — knownAttrs()/listAttrs()/"
               ~ "applySetAttr have drifted apart");
    }
    // knownAttrs() is DERIVED from listAttrs() — this is a structural
    // tautology today, but pins the derivation against a future edit that
    // reintroduces a second hand-written list.
    auto known = fs.knownAttrs();
    auto listed = fs.listAttrs();
    assert(known.length == listed.length);
    foreach (i, k; known)
        assert(k == listed[i][0]);
}

// ---------------------------------------------------------------------------
// Task 0184 / audit-2 C2 — OBJ-3: mandatory round-trip / alias / NEGATIVE /
// table-completeness asserts for the five single-sourced enum tables (lasso /
// elementMode / elementConnect / mix / shape). The 0179 invariant above only
// proves listAttrs()'s CURRENT value round-trips; it can't catch a dropped
// parse alias, a widened accept-set, or lost `final switch` exhaustiveness
// (a table lookup with a string/`%d` fallback has none by construction) —
// this block restores all three.
// ---------------------------------------------------------------------------
unittest {
    import params : tableCoversEnum;

    auto fs = new FalloffStage();

    // --- Round-trip every wire tag through setAttr -> *Label() -------------
    foreach (tag; ["freehand", "rect", "circle", "ellipse"]) {
        assert(fs.applySetAttr("lassoStyle", tag), "lassoStyle " ~ tag ~ " rejected");
        assert(fs.lassoStyleLabel() == tag);
    }
    foreach (tag; ["auto", "vertex", "edge", "polygon"]) {
        assert(fs.applySetAttr("mode", tag), "mode " ~ tag ~ " rejected");
        assert(fs.elementModeLabel() == tag);
    }
    foreach (tag; ["ignore", "useConnectivity", "rigid", "edgeLoops"]) {
        assert(fs.applySetAttr("connect", tag), "connect " ~ tag ~ " rejected");
        assert(fs.connectLabel() == tag);
    }
    foreach (tag; ["multiply", "add", "subtract", "max", "min"]) {
        assert(fs.applySetAttr("mix", tag), "mix " ~ tag ~ " rejected");
        assert(fs.mixLabel() == tag);
    }
    foreach (tag; ["linear", "easeIn", "easeOut", "smooth", "custom"]) {
        assert(fs.applySetAttr("shape", tag), "shape " ~ tag ~ " rejected");
        assert(fs.shapeLabel() == tag);
    }

    // --- Alias asserts: retired `mode` tokens accepted, bare token echoed --
    assert(fs.applySetAttr("mode", "autoCent"));
    assert(fs.elementModeLabel() == "auto");
    assert(fs.applySetAttr("mode", "edgeCent"));
    assert(fs.elementModeLabel() == "edge");
    assert(fs.applySetAttr("mode", "polyCent"));
    assert(fs.elementModeLabel() == "polygon");

    // --- (a) NEGATIVE: a bogus token is rejected for every enum leg --------
    assert(!fs.applySetAttr("lassoStyle", "bogus"));
    assert(!fs.applySetAttr("mode",       "bogus"));
    assert(!fs.applySetAttr("connect",    "bogus"));
    assert(!fs.applySetAttr("mix",        "bogus"));
    assert(!fs.applySetAttr("shape",      "bogus"));

    // --- (b) TABLE-COMPLETENESS: every enum member has a table entry -------
    assert(tableCoversEnum(lassoEntries, [
        cast(int)LassoStyle.Freehand, cast(int)LassoStyle.Rectangle,
        cast(int)LassoStyle.Circle,   cast(int)LassoStyle.Ellipse,
    ]));
    assert(tableCoversEnum(elementModeEntries, [
        cast(int)ElementMode.Auto, cast(int)ElementMode.Vertex,
        cast(int)ElementMode.Edge, cast(int)ElementMode.Polygon,
    ]));
    assert(tableCoversEnum(elementConnectEntries, [
        cast(int)ElementConnect.Ignore, cast(int)ElementConnect.UseConnectivity,
        cast(int)ElementConnect.Rigid,  cast(int)ElementConnect.EdgeLoops,
    ]));
    assert(tableCoversEnum(mixEntries, [
        cast(int)FalloffMix.Multiply, cast(int)FalloffMix.Add,
        cast(int)FalloffMix.Subtract, cast(int)FalloffMix.Max, cast(int)FalloffMix.Min,
    ]));
    assert(tableCoversEnum(shapeEntries, [
        cast(int)FalloffShape.Linear, cast(int)FalloffShape.EaseIn,
        cast(int)FalloffShape.EaseOut, cast(int)FalloffShape.Smooth,
        cast(int)FalloffShape.Custom,
    ]));
}

// ---------------------------------------------------------------------------
// M9 load-bearing aliasing proof: the sel-weight cache (_selKey) must NOT
// alias two distinct Mesh instances that happen to share a mutationVersion.
// mesh_ is a live delegate that can be repointed at a different primary
// mid-session (a real layer switch), so the danger is real: without the
// address term, `a` and `b` below have an EQUAL (mutVer, editMode, selSig,
// steps, shape, in_, out_) key and the cache would wrongly serve `a`'s
// stale weights back for `b`.
//
// `a` is a 4-cycle 0-1-2-3-0 with verts {0,1,2} selected: vertex 0's
// neighbors are {1,3}, and 3 is unselected, so vertex 0 sits on the
// selection BORDER (pinned weight 0). `b` is two disjoint edges 0-1 / 2-3
// with the SAME selection {0,1,2}: vertex 0's only neighbor is 1 (selected),
// so vertex 0 is INTERIOR (weight 1 at steps=0, no smoothing). Both meshes
// are hand-forced to mutationVersion == 7 — the exact aliasing hazard M9
// closes.
// ---------------------------------------------------------------------------
unittest {
    import mesh : Mesh;

    Mesh a;
    a.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    a.resetSelection();
    a.addEdge(0, 1); a.addEdge(1, 2); a.addEdge(2, 3); a.addEdge(3, 0);
    a.selectVertex(0); a.selectVertex(1); a.selectVertex(2);
    a.mutationVersion = 7;

    Mesh b;
    b.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    b.resetSelection();
    b.addEdge(0, 1); b.addEdge(2, 3);
    b.selectVertex(0); b.selectVertex(1); b.selectVertex(2);
    b.mutationVersion = 7;   // hand-forced EQUAL to a — the aliasing hazard

    EditMode em = EditMode.Vertices;
    Mesh* meshPtr = &a;
    auto fs = new FalloffStage(() => meshPtr, &em);
    fs.steps = 0;   // no smoothing — border/interior read straight off isB

    fs.recomputeSelectionWeights();
    assert(fs.selWeights_.length == 4);
    float aVertex0 = fs.selWeights_[0];
    assert(abs(aVertex0 - 0.0f) < 1e-6f,
        "a: vertex 0 is a selection-border vert (neighbor 3 unselected) — weight must be 0");

    // Repoint mesh_ at b — SAME mutationVersion, editMode, and selection
    // signature (identical selected indices {0,1,2} at identical marks
    // length) as a. Only the connectivity differs.
    meshPtr = &b;
    fs.recomputeSelectionWeights();
    float bVertex0 = fs.selWeights_[0];
    assert(abs(bVertex0 - 1.0f) < 1e-6f,
        "b: vertex 0 is INTERIOR (its only neighbor, 1, is selected) — weight must be 1. "
        ~ "If this reads 0 (a's value), the address term was dropped from the cache "
        ~ "key and b wrongly reused a's cached weights.");
    assert(abs(aVertex0 - bVertex0) > 0.5f,
        "a and b must diverge at vertex 0 — same mutationVersion + editMode + "
        ~ "selection signature, different connectivity, and the MeshCacheKey "
        ~ "address term is the only thing that can tell them apart");
}
