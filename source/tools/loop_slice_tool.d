module tools.loop_slice_tool;

import bindbc.sdl;
import std.json : JSONValue;
import std.algorithm : sort;
import operator : VectorStack;

import tool;
import mesh;
import math;
import editmode : EditMode;
import params : Param, IntEnumEntry, wireTagForValue;
import hover_state : g_hoveredEdge;
import shader : Shader, LitShader;
import command_history : CommandHistory;
import commands.mesh.loop_slice_edit : MeshLoopSliceEdit;
import snapshot : MeshSnapshot;
import viewcache : VertexCache, EdgeCache, FaceBoundsCache;
import display_sync : refreshDisplay;

alias LoopSliceEditFactory = MeshLoopSliceEdit delegate();

/// The Loop Slice Slider HUD readout string. `position` is the authoritative
/// 0..1 slice offset; the slider shows it as a TRUE PERCENT (0.13 -> "13.00 %",
/// 0.9 -> "90.00 %"), matching the live reference slider (captured task 0246 —
/// the reference "Loop Slice Slider" prints the scaled percentage above a
/// purple track + position marker). Pure + unit-tested so the ×100 scaling law
/// is locked by `dub test` even though the draw itself is visual (app.d reads
/// this for the per-cell HUD label).
string loopSliceHudLabel(float positionFraction) {
    import std.format : format;
    return format("%.2f %%", positionFraction * 100.0f);
}

unittest {
    // 0..1 fraction -> percent readout (the ×100 the inline draw used to omit,
    // which printed the bare fraction next to a "%" — "0.13 %" instead of the
    // reference's "13.00 %").
    assert(loopSliceHudLabel(0.13f) == "13.00 %");
    assert(loopSliceHudLabel(0.9f)  == "90.00 %");
    assert(loopSliceHudLabel(0.5f)  == "50.00 %");
    assert(loopSliceHudLabel(0.0f)  == "0.00 %");
    assert(loopSliceHudLabel(1.0f)  == "100.00 %");
}

// ---------------------------------------------------------------------------
// 1D profile cutter (task 0256) — the profile DATA MODEL + built-in registry.
//
// The reference Loop Slice can load an arbitrary 1D profile curve (a "router
// bit" cross-section) from a profile preset browser and press it into
// each slice, scaled by `depth` (the "Inset"). A profile is a normalized 2D
// curve: X = position ALONG the cut (0..1, mapped to the loop's along-rail
// fraction), Y = HEIGHT (0..1, mapped to the normal-direction inset). Sampling
// the curve yields MULTIPLE loops; loop `i` is inserted at the sample's `t` and
// displaced off the surface by `height·depth` (see `Mesh.insertEdgeLoopsMulti`
// `profileHeights`/`profileDepth`).
//
// SCOPE / HONESTY: the reference's profile preset LIBRARY is closed
// source and its curves cannot be captured headlessly (the loop-slice gesture is
// human-VNC-only and Profile sits behind the `>>` overflow whose popover does not
// composite). So the MECHANISM here is reference-faithful, but the specific
// built-in curves below are vibe3d-DEFINED stand-ins — NOT a claim of exact
// preset match. `Flat` is the default and, being a null-profile sentinel, is
// byte-for-byte the prior single-/multi-loop flat behaviour.
enum LoopProfile { Flat, Round, Vee, Step }

immutable IntEnumEntry[4] loopProfileTable = [
    IntEnumEntry(cast(int)LoopProfile.Flat,  "flat",  "Flat (none)"),
    IntEnumEntry(cast(int)LoopProfile.Round, "round", "Round"),
    IntEnumEntry(cast(int)LoopProfile.Vee,   "vee",   "Vee"),
    IntEnumEntry(cast(int)LoopProfile.Step,  "step",  "Step"),
];

/// One normalized profile sample: `t` = along-cut fraction (0..1), `height` =
/// normal-direction inset (0..1, scaled by `depth` at cut time).
struct ProfileSample { float t; float height; }

/// The built-in profile curves (vibe3d-defined stand-ins — see the note above).
/// `Flat` returns an empty array (the null-profile sentinel: the caller then uses
/// its own Count/Position placement and passes NO heights to the kernel, so the
/// cut is byte-for-byte the flat behaviour). Every non-flat sample has `t` in
/// (0,1) so it clamps cleanly to the kernel's open-interval position range.
ProfileSample[] profileSamples(LoopProfile p) {
    final switch (p) {
        case LoopProfile.Flat:
            return null;
        case LoopProfile.Round:
            // Half-round: a semicircle bump, height = sqrt(1-(2t-1)^2). Sampled at
            // 5 interior fractions (peak 1.0 at the centre, symmetric).
            return [
                ProfileSample(0.1f, 0.6f),
                ProfileSample(0.3f, 0.9165151f),   // sqrt(1-0.16)
                ProfileSample(0.5f, 1.0f),
                ProfileSample(0.7f, 0.9165151f),
                ProfileSample(0.9f, 0.6f),
            ];
        case LoopProfile.Vee:
            // V-notch tent, height = 1-|2t-1| (apex 1.0 at centre). 3 samples.
            return [
                ProfileSample(0.25f, 0.5f),
                ProfileSample(0.5f,  1.0f),
                ProfileSample(0.75f, 0.5f),
            ];
        case LoopProfile.Step:
            // Rising step / plateau: flat (h=0) on the near half, raised (h=1) on
            // the far half, with a near-vertical wall at the centre.
            return [
                ProfileSample(0.25f, 0.0f),
                ProfileSample(0.49f, 0.0f),
                ProfileSample(0.51f, 1.0f),
                ProfileSample(0.75f, 1.0f),
            ];
    }
}

unittest {
    // Flat is the null-profile sentinel (empty); every non-flat profile has t in
    // (0,1) and at least one positive height (so depth>0 actually cuts).
    assert(profileSamples(LoopProfile.Flat).length == 0);
    foreach (p; [LoopProfile.Round, LoopProfile.Vee, LoopProfile.Step]) {
        auto s = profileSamples(p);
        assert(s.length >= 2, "a non-flat profile needs multiple loops");
        bool anyH = false;
        foreach (smp; s) {
            assert(smp.t > 0.0f && smp.t < 1.0f, "sample t must be in (0,1)");
            if (smp.height > 0.0f) anyH = true;
        }
        assert(anyH, "a non-flat profile must have some positive height");
    }
    // Vee apex is the centre sample at full height.
    auto vee = profileSamples(LoopProfile.Vee);
    assert(vee[1].t == 0.5f && vee[1].height == 1.0f);
}

// ---------------------------------------------------------------------------
// LoopSliceTool — interactive Loop Slice / edge-loop cut (factory id
// `mesh.loopSliceTool`). Coexists with the one-shot `mesh.loopSlice` /
// `mesh.addLoop` commands (source/commands/mesh/loop_slice.d) — those stay
// untouched (single-seed only); this tool reuses the SAME kernel
// (`Mesh.collectEdgeRing` + `Mesh.insertEdgeLoops`/`insertEdgeLoopsMulti`).
//
// v2 (task 0239, "Loop Slice v2"), building on v1 (0228) + the highlight fix
// (0231) + the HUD/Model-B lifecycle (0232) + the state hook (0234):
//
//   — SELECTION-BASED ACTIVATION: arming from a NON-EMPTY edge selection
//     seeds from EVERY selected edge (`seeds_[]`, multi-ring); the 0228
//     hover fallback (single seed from `g_hoveredEdge`) is preserved
//     byte-for-byte when nothing is selected.
//   — Edit (Move/Add/Remove) and Mode (Free/Uniform/Symmetry) govern how
//     `positions_[]`/`current_` are laid out and mutated — see the enum doc
//     comments below for the exact laws.
//   — Count = number of slices PER DISTINCT SEEDED RING (owner-decision D1):
//     the kernel (`Mesh.insertEdgeLoopsMulti`) dedups rings by canonical
//     face-set, so an over-selected edge set never double-cuts one ring.
//
// Interaction model — UNCHANGED from 0232's Model B ("arm-then-commit
// standing preview"): hover/select (no mutation) → ARM (LMB-down latches
// `seeds_[]` and immediately materialises the default-position cut) →
// SCRUB (mesh drag / HUD marker / panel edit, all converging on
// `scrubPosition()`) → COMMIT (Enter, or tool-drop while armed+built, one
// `MeshLoopSliceEdit` undo entry, then RE-ARMS) → CANCEL (Esc/RMB, restores
// `before_`, no undo entry). See doc/loop_slice_slider_hud_impl_plan.md for
// the full mechanism-by-mechanism rationale (navHistory redo-cancel,
// scene.reset/onActiveLayerChanged `dropArmedPreview()` calls, `armedKey_`
// mesh-swap guard) — none of that changed for v2, only WHAT gets latched
// (`seeds_[]` instead of a single `seedEdge_`) and WHAT gets rebuilt from
// (`positions_[]`/`current_` instead of a scalar `position_` + derived
// even-spacing).
//
// Headless (`tool.set mesh.loopSliceTool on; tool.attr ...; tool.doApply`)
// seeds from EVERY SELECTED EDGE (was: first-selected only, pre-0239) — NOT
// from hover (headless has no cursor) and NEVER sets `armed_`/`scrubbing_`
// (`--test` never arms). `applyHeadless()` must never touch `seeds_`/session
// state: `ToolDoApplyCommand` captures its own snapshot pair around the call
// and IS the undo entry.
// ---------------------------------------------------------------------------
final class LoopSliceTool : Tool {
public:
    // Edit — what a click on the HUD track / a marker does (task 0239).
    // Move (default): reposition the Current slice (today's scrub,
    // generalised to `current_`). Add: a click on the bare track at
    // fraction `t` inserts a NEW slice there (`addSlice`). Remove: a click
    // on a marker drops it (`removeSlice`, clamped at Count==1 — D7).
    enum Edit { Move, Add, Remove }

    // Mode — the placement LAW governing `positions_[]` (task 0239).
    // Free: independent per-slice positions; a scrub moves only
    // `positions_[current_]`. Uniform (reference default for Count>1):
    // `(k+1)/(count_+1)` for every slice — a scrub of Current is IGNORED,
    // the law owns every position (owner-decision D3 — this is what keeps
    // the pre-0239 `positions()` behaviour: Count>1 drag was always a
    // geometric no-op). Symmetry: slices form mirrored pairs about 0.5 —
    // scrubbing Current also moves its mirror partner to `1-t`
    // (owner-decision D4; the even-spacing law is ALSO the correct
    // symmetric-pairs default, since `(k+1)/(N+1)` is always symmetric
    // about 0.5 — see `applyModeLaw`).
    enum Mode { Free, Uniform, Symmetry }

private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    GpuMesh*         gpu;
    EditMode*        editMode;
    LitShader        litShader;

    VertexCache*     vc;
    EdgeCache*       ec;
    FaceBoundsCache* fc;

    CommandHistory       history;
    LoopSliceEditFactory factory;

    static immutable IntEnumEntry[3] editTable = [
        IntEnumEntry(cast(int)Edit.Move,   "move",   "Move"),
        IntEnumEntry(cast(int)Edit.Add,    "add",    "Add"),
        IntEnumEntry(cast(int)Edit.Remove, "remove", "Remove"),
    ];
    static immutable IntEnumEntry[3] modeTable = [
        IntEnumEntry(cast(int)Mode.Free,     "free",     "Free"),
        IntEnumEntry(cast(int)Mode.Uniform,  "uniform",  "Uniform"),
        IntEnumEntry(cast(int)Mode.Symmetry, "symmetry", "Symmetry"),
    ];

    // Panel params (shared by the interactive path and `tool.attr`).
    Edit    edit_          = Edit.Move;
    Mode    mode_          = Mode.Uniform;   // reference default for Count>1
    int     count_         = 1;
    int     current_       = 0;             // 0-based (owner-decision D6)
    float[] positions_     = [0.5f];         // authoritative slice offsets, length == count_
    float   positionProxy_ = 0.5f;           // Param-bound mirror of positions_[current_]
    float   insertAt_      = 0.5f;           // Add-trigger value (onParamChanged fires the add)
    bool    removeTrigger_ = false;          // Remove-trigger (self-resetting bool)
    bool    selectNew_     = true;
    // Slice Selected (`select`, task 0248): when ON, the cut is restricted to
    // the selected FACE region — only the run of selected faces each ring
    // crosses is sliced, and the cut terminates watertight at the selection
    // border (boundary neighbours absorb the terminating midpoints). When OFF
    // (default) the whole ring around the mesh is cut, byte-for-byte as before.
    bool    sliceSelected_ = false;
    // Keep Quads (`quad`, task 0249; watertight-by-default change): now a
    // GEOMETRIC NO-OP, retained only for panel/attribute parity. The absorb it
    // used to gate — where the ring terminates against a NON-QUAD face, the
    // neighbour absorbs the terminating midpoint into its boundary (n-gon) so the
    // cut stays watertight AND all-quad — now happens BY DEFAULT for every
    // terminating ring in `Mesh.insertEdgeLoopsMulti` (the reference default is
    // watertight there; Keep Quads on == off on every capturable mesh). Still
    // threaded to the kernel, which ignores it.
    bool    keepQuads_     = false;
    // Slice N-gon (`ngon`, task 0250): the quad ring stops at any non-quad face
    // by default. When ON, the ring is allowed to CONTINUE THROUGH a face with
    // more than four sides (N >= 5) — it enters, picks the opposite exit edge,
    // and the n-gon is sliced by the chord between the two edge midpoints, so
    // the cut spans the n-gon and reaches the faces beyond. Triangles still stop
    // the ring. OFF (default) is the whole-ring/terminate-at-non-quad behaviour
    // byte-for-byte. Composes with `quad`/`select` (all flow through the same
    // per-face split machinery in `Mesh.insertEdgeLoopsMulti`).
    bool    sliceNgon_     = false;
    // Split (`split`, task 0251): when ON the inserted loop DUPLICATES its rail
    // midpoints, so the single connected loop becomes TWO coincident boundary
    // edge-loops and the two sides of the cut are topologically DISCONNECTED
    // along it (each shared interior loop edge becomes two separate boundary
    // edges). OFF (default) is the single connected loop, byte-for-byte as
    // before. Foundation for Cap Sections (0252) + Gap (0253). Threads into the
    // kernel's `split` flag; composes with select/quad/ngon (the absorb/grid
    // neighbours attach to the connected side).
    bool    sliceSplit_    = false;
    // Cap Sections (`caps`, task 0252; geometry LIVE-corrected task 0261): only
    // meaningful when Split is ON. When ON (the reference default), each SECTION
    // Split opens is sealed with ONE cap polygon that fills that section's own
    // boundary loop in the loop's plane — the two split shells stay DISCONNECTED,
    // each closed into its own solid (boundary-edge count 0). When OFF, Split leaves
    // the open boundaries (0251's result). Threads into the kernel's `caps` flag.
    // The caps are full-area quads (in the loop plane); Gap (0253) then pulls the lo
    // cap from the hi cap along the rail, opening a real band between them. Default
    // TRUE, but a no-op whenever Split is off, so it never perturbs the default
    // (unsplit) cut. (The pre-0261 model wrongly bridged lo↔hi with a coplanar quad
    // band that hid the cut on flat faces — see the kernel comment.)
    bool    sliceCaps_     = true;
    // Gap (`gap`, task 0253, distance): only meaningful when Split is ON. `0` (the
    // factory default — the reference's live ~54.2 mm is a sticky seeded pref, not
    // a fresh default) keeps the two split boundary loops coincident, byte-for-byte
    // with 0251/0252. Non-zero opens a gap of that width between them: the kernel
    // pushes each `[lo,hi]` seam pair apart by `gap` (±gap/2, symmetric about the
    // split line) along the rail/cut direction (LIVE-confirmed correct, task 0261),
    // pulling the two shells' caps apart to open a real visible band. Positions only
    // — no topology change. Threads into the kernel's `gap` argument; a no-op
    // whenever Split is off.
    float   gap_           = 0.0f;
    // Preserve Curvature (`curvature`, task 0254): OFF (default) places each new
    // loop vertex at the LINEAR interpolation on the rail chord (byte-for-byte the
    // prior behaviour). ON places it on a Catmull-Rom spline through the rail's
    // neighbouring cage vertices, so a cut across a CURVED cage keeps the surface's
    // rounded profile (bulges off the chord) instead of flattening. Positions only
    // — composes with select/quad/ngon/split/caps/gap (the split duplicate + gap
    // displacement apply on top of the curved base position). Threads into the
    // kernel's `curvature` flag; `curveTension_` scales the bulge (1.0 = full
    // standard Catmull-Rom).
    //
    // Tension (`tension`, task 0255): `curveTension_` is the backing field of the
    // "Tension" param — the strength of Preserve Curvature. It is a fraction whose
    // UI display is a percent (1.0 = 100% = full spline bulge; 0.0 = 0% = the flat
    // linear chord, i.e. curvature disabled). The range is UNBOUNDED (matching the
    // reference, which has no min/max): negative pulls the new verts to the inside
    // of the chord and >1 overshoots further out. Only meaningful while `curvature_`
    // is ON — the kernel ignores `curveTension_` when `curvature` is off — so the
    // param is greyed (see paramEnabled) unless Preserve Curvature is enabled.
    bool    curvature_     = false;
    float   curveTension_  = 1.0f;

    // 1D profile cutter (task 0256). `profile_` selects a built-in profile curve
    // (Flat = default = null-profile = byte-for-byte the flat cut); `depth_` is the
    // reference "Inset" — the scale applied to the profile's normalized height when
    // it is pressed along the surface normal (default 0 per spec.json, so a non-flat
    // profile with the default Inset still lands flat). When `profile_ != Flat` the
    // profile's along-cut sample fractions REPLACE the Count/Position placement and
    // its heights drive the kernel's per-loop normal displacement (`kernelFeed`).
    //
    // Profile MODIFIERS (all real params now; default off = byte-for-byte the 0256
    // profile cut):
    //   • reverseX_ (0257 "Reverse Direction"): mirror the profile along the cut,
    //     t → 1-t (re-sorted in `kernelFeed`), so the curve is evaluated end-to-start.
    //   • reverseY_ (0258 "Reverse Inset"): negate the height, h → -h (in `kernelFeed`),
    //     flipping the inset to the other side of the surface.
    //   • aspect_ (0259 "Keep Aspect"): auto-derive the effective Inset from the cut's
    //     world span so the normalized profile keeps its own aspect ratio, instead of
    //     the user `depth_` (applied in `effectiveDepth`).
    LoopProfile profile_ = LoopProfile.Flat;
    float       depth_   = 0.0f;
    bool        reverseX_ = false;   // 0257 hook
    bool        reverseY_ = false;   // 0258 hook
    bool        aspect_   = false;   // 0259 hook

    // Task 0232: Loop Slice Slider HUD geometry — screen-pixel width
    // (`length_`) and offset (`sliderX_`/`sliderY_`) of the track drawn in
    // the active viewport cell's top-left corner. Pure display geometry:
    // they never affect the cut (onParamChanged() below early-returns for
    // these three names) and are NOT reset by reinitSession() — a user's
    // HUD placement should persist across re-arms within a session.
    int   length_  = 200;
    int   sliderX_ = 20;
    int   sliderY_ = 50;

    // Session state (task 0232 Model B, generalised to multi-seed in 0239).
    bool         active;
    bool         armed_;       // a standing preview cut sits on the real mesh
    bool         scrubbing_;   // a MESH drag is currently repositioning it (subset of armed_)
    bool         built_;       // true once the last rebuildCut() materialised a cut
    uint[]       seeds_;       // latched seed set (was scalar seedEdge_ pre-0239)
    Vec3         seedA_, seedB_;   // ORIGINAL (pre-cut) world-space endpoints of seeds_[0]'s ring, cached at arm
    MeshSnapshot before_;      // idle baseline: mesh == before_ whenever !armed_
    // Address + mutationVersion of the mesh exactly as WE last left it — see
    // the header comment. Stamped at the end of every successful rebuildCut()
    // (and once, trusted, at arm-time). Any commit/cancel/rebuild first checks
    // this against the CURRENT mesh; a mismatch means some OTHER path (reset,
    // layer switch) touched the mesh since, and the preview is dropped rather
    // than committed/restored against the wrong target.
    MeshCacheKey armedKey_;
    Viewport     cachedVp;
    // The ORIGINAL selected-face set latched at arm time (before the standing
    // preview overwrote the selection). Slice-Selected reads its restriction
    // from THIS, so toggling `select` mid-arm still restricts to the faces the
    // user actually selected rather than the cut's re-selected sub-quads.
    uint[]       armedSelFaces_;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode, LitShader litShader,
         VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        this.meshSrc_  = meshSrc;
        this.gpu       = gpu;
        this.editMode  = editMode;
        this.litShader = litShader;
        this.vc        = vc;
        this.ec        = ec;
        this.fc        = fc;
    }

    void setUndoBindings(CommandHistory h, LoopSliceEditFactory f) {
        this.history = h;
        this.factory = f;
    }

    override string name() const { return "Loop Slice"; }

    // Edges is the classic activation type; Polygons is the 0245 activation
    // model — a face selection acts on the edge(s) BETWEEN the selected
    // polygons (see `activationSeeds`), so the tool is offered in both modes.
    override EditMode[] supportedModes() const { return [EditMode.Edges, EditMode.Polygons]; }

    // HoverEdges: needed so app.d's picker keeps writing hover_state while
    // this tool owns the viewport (pickEdges() gates on wantsHoverForType).
    override ToolFlag flags() const { return ToolFlag.HoverEdges; }

    // Ring highlight before anything is armed; suppressed for the WHOLE armed
    // period (not just a live mesh-drag) — the standing preview already shows
    // the live cut, and a stale ring overlay computed from a frozen/now-
    // invalid hover index would just be noise (task 0232 widens this from
    // 0231's `!dragging_` to `!armed_`).
    override bool wantsEdgeLoopHover() const { return !armed_; }

    // The hover ring must be the ring the SLICE lands on (seed + quad-ring exit
    // rails), NOT the classic edge loop through the hovered edge — those run
    // perpendicular. Without this the highlighted ring and the actual cut point
    // in different directions (task 0231).
    override bool edgeLoopHoverSliceRing() const { return true; }

    // True only during an actual MESH drag (subset of `armed_`) — the app's
    // per-frame hover freeze (isDragging-guard) only needs to hold during a
    // real drag gesture, not for the whole (potentially long) armed period.
    override bool isDragging() const { return scrubbing_; }

    // Task 0234 (GET /api/tool/state), extended by task 0239 with
    // edit/mode/current/positions[]/seeds[] so a headless test can assert
    // the full v2 state without a screenshot. `seedEdge` stays a scalar
    // (seeds_[0], or -1 when nothing is armed) for backward compatibility
    // with the pre-0239 hover-parity test (`test_loop_slice_hover_state.d`),
    // which only ever observes the hover (pre-arm) state.
    //
    // `sliceRing` is UNCHANGED from 0234/0231: gated on
    // `edgeLoopHoverSliceRing()` (the same switch app.d's
    // `rebuildLoopHoverMask` reads) and computed from `g_hoveredEdge` alone
    // — the single-hover-ring preview, not a union over an armed multi-seed
    // set (that preview is the STANDING cut itself once armed; the hover
    // ring is only ever shown pre-arm, per `wantsEdgeLoopHover`).
    public override JSONValue toolStateJson() const {
        auto root = JSONValue.emptyObject;
        root["tool"]        = JSONValue("loopSlice");
        root["hoveredEdge"] = JSONValue(g_hoveredEdge);
        root["seedEdge"]    = JSONValue(seeds_.length > 0 ? cast(int)seeds_[0] : -1);
        root["dragging"]    = JSONValue(scrubbing_);   // 0232 renamed dragging_ -> scrubbing_ (mesh drag)
        root["armed"]       = JSONValue(armed_);       // 0232 standing preview held on the mesh
        root["built"]       = JSONValue(built_);
        root["position"]    = JSONValue(positionProxy_);
        root["count"]       = JSONValue(count_);
        root["select"]      = JSONValue(sliceSelected_);   // Slice Selected (task 0248)
        root["quad"]        = JSONValue(keepQuads_);        // Keep Quads (task 0249)
        root["ngon"]        = JSONValue(sliceNgon_);        // Slice N-gon (task 0250)
        root["split"]       = JSONValue(sliceSplit_);       // Split (task 0251)
        root["caps"]        = JSONValue(sliceCaps_);        // Cap Sections (task 0252)
        root["gap"]         = JSONValue(gap_);              // Gap (task 0253)
        root["curvature"]   = JSONValue(curvature_);        // Preserve Curvature (task 0254)
        root["tension"]     = JSONValue(curveTension_);      // Tension (task 0255)
        root["profile"]     = JSONValue(wireTagForValue(loopProfileTable, cast(int)profile_)); // Profile (task 0256)
        root["depth"]       = JSONValue(depth_);             // Inset (task 0256)
        root["reversex"]    = JSONValue(reverseX_);          // Reverse Direction (task 0257)
        root["reversey"]    = JSONValue(reverseY_);          // Reverse Inset (task 0258)
        root["aspect"]      = JSONValue(aspect_);            // Keep Aspect (task 0259)
        root["edit"]        = JSONValue(wireTagForValue(editTable, cast(int)edit_));
        root["mode"]        = JSONValue(wireTagForValue(modeTable, cast(int)mode_));
        root["current"]     = JSONValue(current_);

        JSONValue[] posArr;
        foreach (p; positions_) posArr ~= JSONValue(p);
        root["positions"] = JSONValue(posArr);

        JSONValue[] seedArr;
        foreach (s; seeds_) seedArr ~= JSONValue(cast(int)s);
        root["seeds"] = JSONValue(seedArr);

        int[] ringEdges;
        if (g_hoveredEdge >= 0 && g_hoveredEdge < cast(int)mesh.edges.length) {
            if (edgeLoopHoverSliceRing()) {
                foreach (ei; mesh.loopSliceRingEdges(cast(uint)g_hoveredEdge))
                    ringEdges ~= ei;
            } else {
                // Classic parallel edge loop — reproduces app.d's
                // rebuildLoopHoverMask else-branch (ring-vert-pairs → cage
                // edge index via edgeIndexMap) so this field means the SAME
                // thing whichever way the gate above resolves.
                auto seed = mesh.edges[g_hoveredEdge];
                uint[] ring = edgeLoopRing(*mesh, seed[0], seed[1]);
                foreach (i; 0 .. ring.length) {
                    uint a = ring[i];
                    uint b = ring[(i + 1) % ring.length];
                    if (a == b) continue;
                    if (auto p = edgeKey(a, b) in mesh.edgeIndexMap)
                        ringEdges ~= cast(int)*p;
                }
            }
        }
        JSONValue[] ringArr;
        foreach (ei; ringEdges) ringArr ~= JSONValue(ei);
        root["sliceRing"] = JSONValue(ringArr);
        return root;
    }

    override Param[] params() {
        return [
            Param.float_("position", "Position", &positionProxy_, 0.5f)
                 .min(0.001f).max(0.999f),
            Param.int_("count", "Count", &count_, 1).min(1),
            Param.int_("current", "Current", &current_, 0).min(0),
            Param.intEnum_("edit", "Edit", cast(int*)&edit_, editTable, cast(int)Edit.Move),
            Param.intEnum_("mode", "Mode", cast(int*)&mode_, modeTable, cast(int)Mode.Uniform),
            Param.float_("insertAt", "Insert At", &insertAt_, 0.5f)
                 .min(0.001f).max(0.999f),
            Param.bool_("removeCurrent", "Remove Current", &removeTrigger_, false),
            Param.bool_("selectNew", "Select New Polygons", &selectNew_, true),
            Param.bool_("select", "Slice Selected", &sliceSelected_, false),
            Param.bool_("quad", "Keep Quads", &keepQuads_, false),
            Param.bool_("ngon", "Slice N-gon", &sliceNgon_, false),
            Param.bool_("split", "Split", &sliceSplit_, false),
            Param.bool_("caps", "Cap Sections", &sliceCaps_, true),
            Param.float_("gap", "Gap", &gap_, 0.0f),
            Param.bool_("curvature", "Preserve Curvature", &curvature_, false),
            // Tension (task 0255): strength of Preserve Curvature. Fraction (UI
            // percent): 1.0 = 100% = full spline bulge, 0.0 = flat chord. No
            // min/max — the reference range is unbounded (negative insets inward,
            // >1 overshoots outward). Greyed unless `curvature` is on (paramEnabled).
            Param.float_("tension", "Tension", &curveTension_, 1.0f),
            // 1D profile cutter (task 0256): `Profile` selects a built-in profile
            // curve (Flat = default, byte-for-byte the flat cut); `depth` is the
            // reference "Inset" (default 0 per spec.json — a non-flat profile still
            // lands flat until Inset is raised). See the field + registry comments.
            Param.intEnum_("profile", "Profile", cast(int*)&profile_,
                           loopProfileTable, cast(int)LoopProfile.Flat),
            Param.float_("depth", "Inset", &depth_, 0.0f),
            // Reverse Direction (task 0257): mirror the 1D profile along the cut
            // (t → 1-t, re-sorted in `kernelFeed`), so an asymmetric profile
            // (e.g. Step) cuts in the mirrored orientation. Default OFF =
            // byte-for-byte the un-reversed profile. Only bites once a non-flat
            // Profile is chosen (Flat passes no samples), so it is greyed while
            // Flat — same gating as Inset (see paramEnabled).
            Param.bool_("reversex", "Reverse Direction", &reverseX_, false),
            // Reverse Inset (task 0258): flip the profile's inset/displacement sign
            // (h → -h in `kernelFeed`), so the profile presses OUT of the surface
            // instead of into it (or vice-versa). Default OFF = byte-for-byte the
            // un-reversed profile. Like Inset/Reverse Direction, it only bites once a
            // non-flat Profile is chosen, so it is greyed while Flat (paramEnabled).
            Param.bool_("reversey", "Reverse Inset", &reverseY_, false),
            // Keep Aspect (task 0259): when ON, the Inset is auto-derived from the
            // cut's world span so the normalized profile keeps its own height:width
            // proportions (effectiveDepth = cut span) instead of using the manual
            // Inset. Default OFF = byte-for-byte the raw `depth_` (0256–0258). Like
            // the other profile modifiers it is a no-op with no profile loaded, so it
            // is greyed while Flat (paramEnabled). While ON, the manual Inset row is
            // greyed too (it no longer drives the cut). See `effectiveDepth`.
            Param.bool_("aspect", "Keep Aspect", &aspect_, false),
            // Task 0232 — HUD geometry only, see the field comments above.
            Param.int_("length",  "Length",   &length_,  200).min(20).max(2000),
            Param.int_("sliderX", "Slider X", &sliderX_, 20).min(0),
            Param.int_("sliderY", "Slider Y", &sliderY_, 50).min(0),
        ];
    }

    // -------------------------------------------------------------------
    // Read-only accessors for app.d's HUD block (kept the fields private;
    // the HUD reads through here rather than reaching in).
    // -------------------------------------------------------------------
    public float position() const { return positionProxy_; }
    public int   length_px() const { return length_; }
    public int   sliderX()  const { return sliderX_; }
    public int   sliderY()  const { return sliderY_; }
    public int   count()    const { return count_; }
    public int   current()  const { return current_; }
    public const(float)[] positionsArray() const { return positions_; }
    public Edit  edit()     const { return edit_; }
    public Mode  mode()     const { return mode_; }

    /// HUD marker-select (task 0239 M5): choose WHICH slice a subsequent
    /// drag/scrub targets, without touching the mesh (mirrors the
    /// `onParamChanged("current")` clamp+sync, but callable directly from
    /// app.d's per-frame HUD code rather than through the Param/attr path).
    public void setCurrent(int k) {
        if (k < 0) k = 0;
        if (k >= count_) k = count_ - 1;
        current_ = k;
        syncProxy();
    }

    override void activate() {
        active = true;
        reinitSession();
    }

    private void reinitSession() {
        armed_          = false;
        scrubbing_      = false;
        built_          = false;
        seeds_          = [];
        edit_           = Edit.Move;
        mode_           = Mode.Uniform;
        count_          = 1;
        current_        = 0;
        positions_      = [0.5f];
        positionProxy_  = 0.5f;
        insertAt_       = 0.5f;
        removeTrigger_  = false;
        selectNew_      = true;
        sliceSelected_  = false;
        keepQuads_      = false;
        sliceNgon_      = false;
        sliceSplit_     = false;
        sliceCaps_      = true;   // reference default ON; no-op while Split is off
        gap_            = 0.0f;   // factory default 0 (coincident) — no-op unless Split
        curvature_      = false;  // linear placement (byte-for-byte prior behaviour)
        curveTension_   = 1.0f;   // full Catmull-Rom bulge (0255 "Tension" scales this)
        profile_        = LoopProfile.Flat;   // null-profile (byte-for-byte flat cut)
        depth_          = 0.0f;   // Inset — reference default 0 (no displacement)
        reverseX_       = false;  // 0257 hook
        reverseY_       = false;  // 0258 hook
        aspect_         = false;  // 0259 hook
        armedSelFaces_  = [];
        // length_/sliderX_/sliderY_ deliberately NOT reset — see field comment.
        armedKey_.invalidate();
        before_    = MeshSnapshot.capture(*mesh);
    }

    override void deactivate() {
        // D3 (task 0232): an armed+built standing preview is a deliberate
        // placement — commit it on tool-drop, same as any other tool-switch
        // commit point. A mid-scrub interruption, or an armed-but-unbuilt
        // edge case, cancels instead. Both commitEdit()/cancelLiveEdit()
        // self-guard against a mesh swapped out from under us (see their
        // bodies) — but for the two KNOWN swap sites (scene.reset/file.new,
        // active-layer switch) app.d calls `dropArmedPreview()` explicitly
        // BEFORE this ever runs, so `armed_` is already false here in those
        // cases and this branch is a no-op.
        if (active && armed_) {
            if (built_) commitEdit();
            else        cancelLiveEdit();
        }
        active = false;
        dropArmedPreview();
    }

    public override bool hasUncommittedEdit() const {
        return active && armed_;
    }

    public override void cancelUncommittedEdit() {
        cancelLiveEdit();
    }

    // A standing armed preview sits on the mesh across arbitrary frames, so a
    // REDO reachable while armed must cancel it first (else the redo would apply
    // on top of the uncommitted cut and resyncSession() would bake it in). This
    // is what makes the navHistory redo-cancel narrow: it fires ONLY for this
    // tool's armed preview, never for refire-based tools (BoxTool) whose
    // uncommitted edit must redo normally on Ctrl+Shift+Z.
    public override bool cancelsOnRedo() const {
        return active && armed_;
    }

    public override void resyncSession() {
        if (!active) return;
        // An armed standing preview must never be silently wiped by a
        // resync — the only authorized way to end one is commit/cancel
        // (Enter/Esc/RMB/tool-drop), or the navHistory chokepoint's own
        // cancelUncommittedEdit() call, which always runs BEFORE this could
        // be reached for an armed session (see app.d's navHistory). This
        // guard is defence in depth: it should never actually trigger.
        if (armed_) return;
        reinitSession();
    }

    /// Discard the standing preview WITHOUT touching the mesh or recording
    /// anything to history. For exit paths where the underlying mesh may
    /// already have been swapped/overwritten out from under this tool by the
    /// time this runs — scene.reset's `onResetTool` fires AFTER `*mesh = ...`
    /// has already run; an active-layer-change hook fires AFTER the primary
    /// already switched — committing or restoring there would corrupt the
    /// new mesh or fabricate a bogus undo entry (task 0232). Safe to call
    /// even when nothing is armed (no-op). Task 0239: resets `seeds_`
    /// (formerly the scalar `seedEdge_`) — `positions_`/`current_`/`edit_`/
    /// `mode_`/`count_` are session PARAMS, not per-arm latch state, and are
    /// intentionally left untouched here (they're reset by
    /// `reinitSession()`, called at tool activation, and persist across a
    /// single re-arm-after-commit within the same activation — matching
    /// pre-0239 behaviour for `position_`/`count_`/`uniform_`).
    public void dropArmedPreview() {
        armed_     = false;
        scrubbing_ = false;
        built_     = false;
        seeds_     = [];
        armedSelFaces_ = [];
        armedKey_.invalidate();
    }

    // Tension (task 0255) is only meaningful while Preserve Curvature is on — the
    // kernel ignores `curveTension_` when `curvature` is off. Grey the row (the
    // reference greys "Tension" until "Preserve Curvature" is enabled). All other
    // params stay enabled.
    override bool paramEnabled(string name) const {
        if (name == "tension") return curvature_;
        // Inset (depth) only bites once a non-flat Profile is chosen (Flat passes
        // no heights to the kernel, so depth is a no-op) — grey it while Flat, the
        // way the reference greys the profile sub-controls until a Profile loads.
        // Keep Aspect (0259) auto-derives the Inset, so the manual value no longer
        // drives the cut while aspect is ON — grey it there too (the reference
        // "automatically sets the Inset value from the profile's aspect ratio").
        if (name == "depth") return profile_ != LoopProfile.Flat && !aspect_;
        // Reverse Direction (task 0257) mirrors the profile samples, so it is a
        // no-op with no profile loaded — grey it while Flat, like Inset (the
        // reference greys it "until a Profile is loaded", spec.json 0244).
        if (name == "reversex") return profile_ != LoopProfile.Flat;
        // Reverse Inset (task 0258) flips the profile height sign — a no-op with no
        // profile loaded (Flat passes no heights), so grey it while Flat, same as
        // Inset/Reverse Direction (the reference greys it "until a Profile is loaded").
        if (name == "reversey") return profile_ != LoopProfile.Flat;
        // Keep Aspect (task 0259) auto-derives the Inset from the profile's aspect
        // ratio — a no-op with no profile loaded (Flat passes no heights), so grey
        // it while Flat, same as Inset/Reverse Direction/Reverse Inset.
        if (name == "aspect") return profile_ != LoopProfile.Flat;
        return true;
    }

    override void onParamChanged(string pname) {
        // HUD geometry only — never touches the cut.
        if (pname == "length" || pname == "sliderX" || pname == "sliderY") return;

        if (pname == "count") {
            syncPositionsToCount();
            if (armed_) rebuildCut();
            return;
        }
        if (pname == "current") {
            if (current_ < 0) current_ = 0;
            if (current_ >= count_) current_ = count_ - 1;
            syncProxy();
            return;
        }
        if (pname == "edit") return;   // pure interactive-affordance state (HUD click semantics)
        if (pname == "mode") {
            applyModeLaw();
            syncProxy();
            if (armed_) rebuildCut();
            return;
        }
        if (pname == "select") { if (armed_) rebuildCut(); return; }
        if (pname == "quad")   { if (armed_) rebuildCut(); return; }
        if (pname == "ngon")   { if (armed_) rebuildCut(); return; }
        if (pname == "split")  { if (armed_) rebuildCut(); return; }
        if (pname == "caps")   { if (armed_) rebuildCut(); return; }
        if (pname == "gap")    { if (armed_) rebuildCut(); return; }
        if (pname == "curvature") { if (armed_) rebuildCut(); return; }
        if (pname == "tension") { if (armed_) rebuildCut(); return; }
        if (pname == "profile") { if (armed_) rebuildCut(); return; }   // task 0256
        if (pname == "depth")   { if (armed_) rebuildCut(); return; }   // task 0256 (Inset)
        if (pname == "reversex") { if (armed_) rebuildCut(); return; }   // task 0257 (Reverse Direction)
        if (pname == "reversey") { if (armed_) rebuildCut(); return; }   // task 0258 (Reverse Inset)
        if (pname == "aspect")   { if (armed_) rebuildCut(); return; }   // task 0259 (Keep Aspect)
        if (pname == "insertAt") { addSlice(insertAt_); return; }
        if (pname == "removeCurrent") {
            if (removeTrigger_) { removeSlice(); removeTrigger_ = false; }
            return;
        }
        if (pname == "position") { scrubPosition(positionProxy_); return; }

        if (interactiveParamEdit && armed_) rebuildCut();
    }
    override void evaluate() {}

    /// Single entry point for repositioning the ARMED standing preview's
    /// CURRENT slice — the mesh-drag path (`onMouseMotion`), the HUD marker
    /// (app.d), and a Tool-Properties panel edit of `Position`
    /// (`onParamChanged`) all converge here so they can never diverge in
    /// effect. Clamps to (0,1) and applies the Mode law (task 0239 D3/D4),
    /// then, while armed, re-runs `rebuildCut()`.
    public void scrubPosition(float p) {
        if      (p < 0.001f) p = 0.001f;
        else if (p > 0.999f) p = 0.999f;

        if (count_ <= 1) {
            // Owner objection #1 (MAJOR, task 0239): Count<=1 ALWAYS honors
            // the scrub regardless of Mode — a default Mode (Uniform) must
            // never freeze a Count==1 Position at 0.5. Preserves the pre-
            // 0239 T2 test AND the 0232 HUD scrub, both of which are
            // Count==1-gated.
            if (positions_.length == 0) positions_ ~= p;
            else                        positions_[0] = p;
            current_ = 0;
        } else final switch (mode_) {
            case Mode.Uniform:
                // D3: the even-spacing law owns every position — a scrub is
                // a no-op (preserves the pre-0239 T6 "Count>1 drag is a
                // deliberate geometric no-op" test, since Uniform is the
                // default Mode for Count>1).
                break;
            case Mode.Free:
                if (current_ >= 0 && cast(size_t)current_ < positions_.length)
                    positions_[current_] = p;
                break;
            case Mode.Symmetry:
                if (current_ >= 0 && cast(size_t)current_ < positions_.length) {
                    positions_[current_] = p;
                    size_t mirror = cast(size_t)count_ - 1 - cast(size_t)current_;
                    if (mirror != cast(size_t)current_ && mirror < positions_.length)
                        positions_[mirror] = 1.0f - p;
                }
                break;
        }
        syncProxy();
        if (armed_) rebuildCut();
    }

    /// Edit=Add: insert a NEW slice at fraction `t` (a click on the bare HUD
    /// track, or the `insertAt` param headlessly). Count grows by one,
    /// Current moves to the new slice, and the Mode law re-lays the whole
    /// set (a no-op for Free, which keeps the appended `t` as-is).
    public void addSlice(float t) {
        if      (t < 0.001f) t = 0.001f;
        else if (t > 0.999f) t = 0.999f;
        positions_ ~= t;
        count_   = cast(int)positions_.length;
        current_ = cast(int)positions_.length - 1;
        applyModeLaw();
        syncProxy();
        if (armed_) rebuildCut();
    }

    /// Edit=Remove: drop `positions_[current_]` (a click on a HUD marker, or
    /// the `removeCurrent` trigger headlessly). Owner-decision D7: a no-op
    /// at Count==1 (stays armed, does nothing — Remove never de-arms the
    /// tool or drops below one slice).
    public void removeSlice() {
        if (count_ <= 1) return;
        if (positions_.length > 0) {
            size_t idx = (current_ >= 0 && cast(size_t)current_ < positions_.length)
                       ? cast(size_t)current_ : positions_.length - 1;
            positions_ = positions_[0 .. idx] ~ positions_[idx + 1 .. $];
        }
        count_ = cast(int)positions_.length;
        if (current_ >= count_) current_ = count_ - 1;
        if (current_ < 0) current_ = 0;
        applyModeLaw();
        syncProxy();
        if (armed_) rebuildCut();
    }

    // -------------------------------------------------------------------
    // Headless apply (tool.doApply). Seeds from EVERY SELECTED EDGE (task
    // 0239 — was: first-selected only, pre-0239) — MUST NOT touch seeds_/
    // armed_/scrubbing_/built_; ToolDoApplyCommand wraps this with its own
    // snapshot pair.
    // -------------------------------------------------------------------
    override bool applyHeadless() {
        if (mesh.edges.length == 0) return false;

        // Same activation rule as the interactive arm (0245): EDGES mode seeds
        // every selected edge (unchanged from 0239); POLYGONS mode seeds the
        // interior/shared edge(s) between the selected faces. No hover fallback
        // here — headless has no cursor.
        uint[] seeds = activationSeeds();
        if (seeds.length == 0) return false;

        uint[] newFaceIndices;
        float[] pos, heights;
        kernelFeed(pos, heights);
        bool ok = mesh.insertEdgeLoopsMulti(seeds, pos, newFaceIndices,
                                            restrictFor(selectedFaceIndices()), keepQuads_,
                                            sliceNgon_, sliceSplit_, sliceCaps_, null, gap_,
                                            curvature_, curveTension_,
                                            heights, effectiveDepth(seedEdgeSpan(seeds)));
        if (!ok) return false;
        if (selectNew_)
            foreach (fi; newFaceIndices) mesh.selectFace(cast(int)fi);
        gpu.upload(*mesh);
        return true;
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active) return false;
        if (e.button == SDL_BUTTON_RIGHT) { cancelLiveEdit(); return true; }
        if (e.button != SDL_BUTTON_LEFT)  return false;
        SDL_Keymod mods = SDL_GetModState();
        if (mods & (KMOD_ALT | KMOD_SHIFT)) return false;
        // Edges (classic hover/edge-select activation) OR Polygons (0245
        // face-selection activation). Other modes never arm this tool.
        if (*editMode != EditMode.Edges && *editMode != EditMode.Polygons) return false;
        if (scrubbing_)                     return false;   // re-entrancy guard

        if (armed_) {
            // D2 (task 0232): a press while already armed re-scrubs the
            // SAME seed set. To cut a different ring/set the user
            // commits/cancels first. If the mesh underneath the armed
            // preview was swapped/clobbered since our last touch, drop it
            // instead of re-engaging against the wrong target.
            if (seeds_.length == 0 || !armedKey_.matches(*mesh)) {
                dropArmedPreview();
                return false;
            }
            seedRail(seeds_[0], seedA_, seedB_);
            scrubbing_ = true;
            return true;
        }

        // Selection-based activation (task 0239 M2 + 0245): EDGES mode seeds
        // from EVERY selected edge (multi-ring); POLYGONS mode seeds the
        // interior/shared edge(s) between the selected faces (0245 — two
        // adjacent selected quads seed their shared edge, so the ring crossing
        // it is cut). Falls back to the 0228 single hover seed only when the
        // selection yields nothing — the edge/hover paths stay byte-for-byte.
        uint[] candSeeds = activationSeeds();
        if (candSeeds.length == 0) {
            int hov = g_hoveredEdge;
            if (hov < 0 || hov >= cast(int)mesh.edges.length) return false;
            candSeeds = [cast(uint)hov];
        }

        // Require at least ONE candidate seed to yield a real ring — don't
        // arm (latch armed_=true) on a set that would produce nothing (the
        // 0228 no-engage-on-bad-seed guard, generalised to a set).
        bool anyValid = false;
        foreach (s; candSeeds) {
            bool closed;
            if (mesh.collectEdgeRing(s, closed).length > 0) { anyValid = true; break; }
        }
        if (!anyValid) return false;

        seeds_ = candSeeds;
        // Latch the ORIGINAL selection now, before rebuildCut()'s standing
        // preview overwrites it — Slice Selected restricts to THIS set.
        armedSelFaces_ = selectedFaceIndices();
        seedRail(seeds_[0], seedA_, seedB_);
        armed_     = true;
        scrubbing_ = true;
        built_     = false;
        // Trusted baseline: this IS the mesh we're arming against (nothing
        // could have swapped it out between the hover/selection read above
        // and here, all synchronous within this one handler).
        armedKey_.stamp(*mesh);
        rebuildCut();   // materialise the default-position cut(s) immediately
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_) return false;

        Vec3 origin, dir;
        screenPointToRay(cast(float)e.x, cast(float)e.y, cachedVp, origin, dir);
        Vec3 hit = closestPointOnSegmentToRay(seedA_, seedB_, origin, dir);

        // `hit` is a clamped POINT; recover the scalar t the kernel wants by
        // re-projecting it onto the (unclamped) segment direction.
        Vec3  ab    = seedB_ - seedA_;
        float denom = dot(ab, ab);
        if (denom > 1e-12f) {
            float t = dot(hit - seedA_, ab) / denom;
            scrubPosition(t);
        }
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (!active || !scrubbing_) return false;
        if (e.button != SDL_BUTTON_LEFT) return false;
        scrubbing_ = false;
        // Model B: mouse-up no longer commits — the preview STAYS armed
        // until Enter (commit) or Esc/RMB (cancel). If the last rebuildCut()
        // somehow failed to build (should not happen — a valid seed always
        // builds), fail safe by cancelling rather than leaving a bogus
        // armed-but-empty state.
        if (!built_) cancelLiveEdit();
        return true;
    }

    // Commit (Enter/Return) / cancel (Esc) the standing preview. RMB is
    // already handled in onMouseButtonDown for the "held mouse" path; this
    // covers the keyboard path, which is how a scrub-free arm (HUD/panel-only
    // scrubbing, mouse never held) gets committed.
    override bool onKeyDown(ref const SDL_KeyboardEvent e, ref VectorStack vts) {
        if (!active || !armed_) return false;
        switch (e.keysym.sym) {
            case SDLK_RETURN:
            case SDLK_KP_ENTER:
                commitEdit();
                return true;
            case SDLK_ESCAPE:
                cancelLiveEdit();
                return true;
            default:
                return false;
        }
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        // No gizmo/ghost overlay in the revised (mutate/revert) model — the
        // real mesh already shows the live cut. Only the viewport needs
        // caching, for the seed-edge ray cast in onMouseMotion.
        cachedVp = vp;
    }

private:
    // Shared activation seeding (task 0245) — the single source of truth for
    // "which ring(s) does the current selection cut", used by BOTH the headless
    // apply (`applyHeadless`) and the interactive arm (`onMouseButtonDown`):
    //   • EDGES mode + a non-empty edge selection → every selected edge, in
    //     ascending index order (unchanged from 0239 — `insertEdgeLoopsMulti`
    //     dedups rings by canonical face-set, so an over-selected loop never
    //     double-cuts one ring).
    //   • POLYGONS mode + a face selection → the interior/shared cage edges of
    //     the selected region (`Mesh.interiorEdgesOfSelectedFaces`): two
    //     adjacent selected quads seed their one shared edge, so the ring
    //     crossing that edge is cut; a lone / non-adjacent face selection
    //     yields nothing.
    //   • Anything else → empty (the interactive path then tries a hover seed;
    //     the headless path treats empty as a no-op).
    uint[] activationSeeds() {
        if (*editMode == EditMode.Edges && mesh.hasAnySelectedEdges()) {
            uint[] s;
            foreach (i, sel; mesh.selectedEdges)
                if (sel && i < mesh.edges.length) s ~= cast(uint)i;
            return s;
        }
        if (*editMode == EditMode.Polygons && mesh.hasAnySelectedFaces())
            return mesh.interiorEdgesOfSelectedFaces();
        return [];
    }

    // The currently-selected face indices, ascending. Empty when nothing is
    // face-selected. Read once at arm (latched into `armedSelFaces_`) and
    // live in the headless path.
    uint[] selectedFaceIndices() {
        uint[] r;
        if (!mesh.hasAnySelectedFaces()) return r;
        foreach (i, sel; mesh.selectedFaces)
            if (sel) r ~= cast(uint)i;
        return r;
    }

    // The face-restriction set the kernel should honour for THIS cut: the
    // given selected-face set when Slice Selected is ON and a face selection
    // exists, else `null` (⇒ whole ring, byte-for-byte unchanged).
    uint[] restrictFor(uint[] selFaces) {
        return (sliceSelected_ && selFaces.length > 0) ? selFaces : null;
    }

    // The directed world-space endpoints `position_`/`t` are measured against
    // — MUST match the direction `insertEdgeLoops` actually treats as this
    // seed edge's p-rail, or a drag toward one end lands the cut near the
    // OTHER end. `mesh.edges[seedEdge][0..1]`'s stored order is NOT reliable
    // for this (it's whichever direction `rebuildEdges` first saw while
    // scanning faces in ascending index order, which need not agree with
    // `collectEdgeRing`'s own face-visit order). Instead replicate exactly
    // what `collectEdgeRing` does: the FIRST face `facesAroundEdge` yields
    // (== its own `incFaces[0]`) is the face whose local winding direction
    // for this edge becomes the p-rail's (a,b) — findEdgeInFace + a face-array
    // read reproduce that direction without needing access to the kernel's
    // private `EdgeRingEntry` fields. Exact for a CLOSED ring (the seed
    // edgeKey is only ever touched once, via this face — cube/cylinder belts,
    // the common case); for an OPEN (boundary-terminated) ring the OTHER
    // incident face also touches the same edgeKey and — if it happens to sit
    // at a LOWER face-array index — the kernel's actual direction can flip
    // relative to this. Documented v1 limitation (not invented/fixed here):
    // an open-ring drag may occasionally run toward the opposite end from
    // the cursor; the resulting cut is still valid, undoable geometry.
    // (Task 0239: multi-seed drag reference is always seeds_[0]'s ring —
    // the HUD/scrub is ONE shared track over the shared positions_[], per
    // the plan; the OTHER seeded rings are cut with the SAME positions_ but
    // don't need their own drag reference.)
    void seedRail(uint seedEdge, out Vec3 a, out Vec3 b) {
        uint firstFace = uint.max;
        foreach (fi; mesh.facesAroundEdge(seedEdge)) { firstFace = fi; break; }
        if (firstFace == uint.max) {
            // Unreachable in practice (collectEdgeRing already validated a
            // ring exists at the call site) — fall back to the raw order.
            uint va = mesh.edges[seedEdge][0], vb = mesh.edges[seedEdge][1];
            a = mesh.vertices[va]; b = mesh.vertices[vb];
            return;
        }
        int j0 = mesh.findEdgeInFace(firstFace, mesh.edgeKeyOf(seedEdge));
        auto face = mesh.faces[firstFace];
        uint va = face[j0], vb = face[(j0 + 1) % face.length];
        a = mesh.vertices[va];
        b = mesh.vertices[vb];
    }

    // Re-lay `positions_` per the Mode law (task 0239). A no-op below
    // Count==2 for either law (owner objection #1 — see `scrubPosition`):
    // Count<=1 is ALWAYS just whatever `positions_[0]` currently is,
    // regardless of Mode.
    void applyModeLaw() {
        if (count_ <= 1) return;
        final switch (mode_) {
            case Mode.Free:
                break;   // independent positions — nothing to re-lay
            case Mode.Uniform:
            case Mode.Symmetry:
                // `(k+1)/(count_+1)` is ALSO the correct symmetric-pairs-
                // about-0.5 default for Symmetry (D4): position(k) and
                // position(count_-1-k) always sum to 1 under this formula,
                // so a fresh (re-)layout under either law looks identical —
                // they diverge only in how a SUBSEQUENT scrub behaves
                // (`scrubPosition` above).
                foreach (k; 0 .. count_)
                    positions_[k] = (k + 1.0f) / (count_ + 1.0f);
                break;
        }
    }

    // Grow/shrink `positions_` to match `count_` (a direct Count param
    // write — headless-testable path for "Add grows / Remove shrinks", the
    // count-only shape of Edit; the CURRENT-aware `addSlice`/`removeSlice`
    // are what the HUD's Add-track-click / Remove-marker-click actually
    // invoke). New slots default to 0.5 before the Mode law re-lays them.
    void syncPositionsToCount() {
        if (count_ < 1) count_ = 1;
        if (positions_.length < cast(size_t)count_) {
            while (positions_.length < cast(size_t)count_) positions_ ~= 0.5f;
        } else if (positions_.length > cast(size_t)count_) {
            positions_.length = cast(size_t)count_;
        }
        if (current_ >= count_) current_ = count_ - 1;
        if (current_ < 0)       current_ = 0;
        applyModeLaw();
        syncProxy();
    }

    // Keep the Param-bound `positionProxy_` mirror in sync with
    // `positions_[current_]` after ANY mutation that isn't itself driven by
    // a "position" param write — so the Tool Properties panel always shows
    // the TRUE current value (e.g. after a Uniform-mode scrub was ignored,
    // or Current/Count/Mode changed which slot "Position" refers to).
    void syncProxy() {
        positionProxy_ = (positions_.length > 0
                           && current_ >= 0 && cast(size_t)current_ < positions_.length)
                        ? positions_[current_] : 0.5f;
    }

    // The kernel feed: a SORTED copy of positions_. `positions_`'s own
    // array order follows insertion/Current-indexing history (stable
    // addressing for the UI), but `insertEdgeLoopsMulti` builds each ring's
    // sub-quad chain in ARRAY order — an out-of-order Free-mode scrub (a
    // later slice's `t` smaller than an earlier one's) would otherwise fold
    // the chain back on itself into a self-overlapping/degenerate sub-quad.
    // Sorting the kernel feed is a pure safety measure: it is a no-op for
    // every case the DoD specifies (Uniform/Symmetry are already
    // monotonic-by-construction; Count<=1 is trivially sorted).
    float[] kernelPositions() const {
        auto copy = positions_.dup;
        sort(copy);
        return copy;
    }

    // The world-space span of the cut for the given seed set: the world length
    // of the FIRST seed edge (the p-rail the profile is pressed across). This is
    // the "cut width" the aspect rule scales against. `seeds[0]` must index a
    // valid edge in the CURRENT mesh (true at every call site: the headless path
    // reads the live selection; `rebuildCut` restores `before_` first, so
    // `seeds_[0]` indexes the baseline edge array). Falls back to `1.0` for an
    // empty/out-of-range seed set (a defensive proxy — never hit in practice).
    float seedEdgeSpan(const(uint)[] seeds) const {
        if (seeds.length > 0 && seeds[0] < mesh.edges.length) {
            auto e = mesh.edges[seeds[0]];
            return (mesh.vertices[e[1]] - mesh.vertices[e[0]]).length();
        }
        return 1.0f;
    }

    // The effective Inset (task 0256 / 0259 "Keep Aspect"). With `aspect_` off
    // (the default — see reinitSession) this is just the user `depth_`, so every
    // 0256–0258 cut is byte-for-byte unchanged.
    //
    // 0259 — Keep Aspect (aspect_): when ON (and a non-flat Profile is loaded) the
    // Inset is AUTO-DERIVED from the cut's world span instead of the manual
    // `depth_`, so the normalized profile keeps its own height:width proportions.
    // The profile is a UNIT-normalized curve: X = along-cut fraction (0..1), Y =
    // height (0..1). Pressing it into the cut maps 1 unit of X onto `cutSpan`
    // world units along the rail; to KEEP ASPECT the Y (inset) axis must use the
    // SAME world-units-per-normalized-unit factor — i.e. scale isotropically. So
    // `effectiveDepth = cutSpan × 1.0 = cutSpan`. (Aspect-preservation is exactly
    // isotropic scaling: setting world_height/world_width = normalized_height/
    // normalized_width solves to depth = cutSpan regardless of the specific curve,
    // so the built-in profile shape doesn't enter the factor.)
    //
    // DERIVED, not captured: the loop-slice gesture is human-VNC-only and the
    // reference profile preset library is closed source (see the 0256 note), so
    // the exact reference formula behind "automatically sets the Inset value from
    // the profile's aspect ratio" was NOT recorded. `effectiveDepth = cutSpan` is
    // the canonical aspect-preserving construction — no exact-match claim.
    float effectiveDepth(float cutSpan) const {
        if (aspect_ && profile_ != LoopProfile.Flat)
            return cutSpan;
        return depth_;
    }

    // The kernel feed for the profile cutter (task 0256). Flat profile ⇒ the
    // existing sorted Count/Position placement with NO heights (kernel stays
    // byte-for-byte flat). A non-flat profile REPLACES the placement with the
    // profile's own along-cut sample fractions and returns the parallel per-loop
    // heights (normalized 0..1); the kernel then insets loop `i` by
    // `heights[i]·effectiveDepth`. Positions + heights are sorted TOGETHER by `t`
    // (the kernel builds each ring's sub-quad chain in position order), so the
    // reverseX hook (t → 1-t) re-sorts cleanly. `heights` is null for Flat.
    void kernelFeed(out float[] pos, out float[] heights) const {
        if (profile_ == LoopProfile.Flat) {
            pos = kernelPositions();
            heights = null;
            return;
        }
        ProfileSample[] s = profileSamples(profile_).dup;
        foreach (ref smp; s) {
            // 0257 HOOK — Reverse Direction: mirror along the cut.
            if (reverseX_) smp.t = 1.0f - smp.t;
            // 0258 HOOK — Reverse Inset: flip the inset to the other surface side.
            if (reverseY_) smp.height = -smp.height;
            // Clamp t into the kernel's open (0,1) interval.
            if      (smp.t < 0.001f) smp.t = 0.001f;
            else if (smp.t > 0.999f) smp.t = 0.999f;
        }
        sort!((a, b) => a.t < b.t)(s);
        pos = new float[](s.length);
        heights = new float[](s.length);
        foreach (i, smp; s) { pos[i] = smp.t; heights[i] = smp.height; }
    }

    // The mutate/revert preview: restore the idle baseline, then reapply the
    // cut from the ORIGINAL seeds_ (valid again immediately after the
    // restore — insertEdgeLoopsMulti rebuilds `edges`/`faces` from scratch
    // every call, so seeds_ would be stale against the mesh's CURRENT edge
    // array otherwise).
    //
    // Guarded by `armedKey_` (task 0232 fold #1): if the mesh underneath an
    // armed preview was swapped/clobbered by something else since our last
    // touch, drop the preview instead of restoring/inserting against the
    // WRONG mesh.
    void rebuildCut() {
        if (!before_.filled || seeds_.length == 0) return;
        if (!armedKey_.matches(*mesh)) { dropArmedPreview(); return; }
        before_.restore(*mesh);
        uint[] newFaceIndices;
        float[] pos, heights;
        kernelFeed(pos, heights);
        bool ok = mesh.insertEdgeLoopsMulti(seeds_, pos, newFaceIndices,
                                            restrictFor(armedSelFaces_), keepQuads_,
                                            sliceNgon_, sliceSplit_, sliceCaps_, null, gap_,
                                            curvature_, curveTension_,
                                            heights, effectiveDepth(seedEdgeSpan(seeds_)));
        built_ = ok;
        if (ok && selectNew_)
            foreach (fi; newFaceIndices) mesh.selectFace(cast(int)fi);
        // Re-stamp regardless of `ok` — after this line the mesh is in a
        // KNOWN state WE produced (either the successful cut, or just the
        // restored baseline if insertEdgeLoopsMulti failed).
        armedKey_.stamp(*mesh);
        refreshCaches();
    }

    void commitEdit() {
        if (history is null || factory is null || !before_.filled) return;
        if (!armedKey_.matches(*mesh)) {
            // The mesh underneath us was swapped/clobbered (scene reset,
            // active-layer switch) since our last touch — the standing
            // preview is no longer meaningfully "ours" to commit. Committing
            // here would fabricate a bogus undo entry against the wrong
            // mesh (task 0232 fold #1); silently drop it instead.
            dropArmedPreview();
            return;
        }
        auto cmd  = factory();
        auto post = MeshSnapshot.capture(*mesh);
        cmd.setSnapshots(before_, post, "Loop Slice");
        history.record(cmd);
        // Re-arm: the just-committed state becomes the new idle baseline so
        // the tool is ready for another cut (each cut its own undo entry).
        before_ = post;
        dropArmedPreview();
    }

    void cancelLiveEdit() {
        // Same hazard as commitEdit: only restore `before_` if the mesh is
        // still the one we armed against (armedKey_ match) — otherwise there
        // is nothing safely ours to restore; just drop the state.
        if (armedKey_.matches(*mesh) && before_.filled) before_.restore(*mesh);
        dropArmedPreview();
        refreshCaches();
    }

    void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
