module toolpipe.packets;

import math : Vec3, Viewport;
import mesh : Mesh;
import editmode : EditMode;
import seltype : SelType;

// ---------------------------------------------------------------------------
// Packet types — the wire format between tool pipe stages.
//
// Each packet type carries the state one stage publishes for downstream
// stages to read (subject, action center, axis, falloff, symmetry, ...).
//
// Phase 7.0 ships only the SubjectPacket (constructed at pipe entry from
// the current scene state). The remaining packet types are stubbed here
// with the fields each later subphase needs, so the ToolState struct
// shape is stable and 7.1+ subphases just populate values without
// rearranging the layout.
// ---------------------------------------------------------------------------

/// Subject packet — mesh + selection + edit mode at pipe entry.
/// Read-only snapshot; stages must not mutate the scene mesh through this
/// pointer (use the regular Mesh* path with snapshot/undo as elsewhere).
struct SubjectPacket {
    Mesh*      mesh;
    EditMode   editMode;
    // What kind of thing the pipe is operating on: a geometry element
    // (Vertex/Edge/Polygon, mirroring `editMode`) or the layer/item itself
    // (`SelType.Item`). Stages read this to decide whether to compute a
    // geometry-derived value (selection centroid, mesh basis, ...) or an
    // item-derived one (the layer's world pivot / world axes). Defaults to
    // `Vertex` so a builder that forgets to set it degrades to the existing
    // geometry-mode behaviour rather than spuriously entering item mode
    // (doc/item_mode_transform_plan.md Phase 1, R4).
    SelType    selType = SelType.Vertex;
    // Selection is NOT snapshotted into this packet. Stages that compute
    // selection-derived values (Action Center "selection center", Falloff
    // weight/lasso) read it straight from `mesh` via the non-allocating
    // mark accessors / index helpers (`mesh.hasAnySelected*()`,
    // `mesh.selectedVertexIndices*()`). The selection lives solely in the
    // mesh's mark arrays, so there is nothing to copy here — and copying it
    // would re-introduce a per-pipe-eval `bool[]` allocation for fields no
    // consumer reads (see doc/element_marks_migration_plan.md Phase 4 / B6).
    // Active 3D viewport at evaluation time. Some upstream stages
    // (workplane-auto, snap, screen falloff) depend on the camera frame.
    // Added in Phase 0 of doc/operator_refactor_plan.md so the new
    // VectorStack-based dispatch can carry this without a separate
    // function parameter. Default-init (zero matrices) — stages that
    // require a real viewport early-out when this is invalid.
    Viewport   viewport;

    // Cursor pixel at evaluation time — added for the CONS stage's
    // background-surface raycast (topology-pen P0,
    // doc/topopen_p0_plan.md REV-1). `cursorValid` is the THREAD-SAFETY
    // gate: it is stamped true ONLY by the main-thread mouse-event
    // dispatch path (`app.d`'s `buildToolVts` optional cursor params, set
    // from `handleMouseMotion`/`handleMouseButtonDown`/`Up`'s own event
    // coordinates) and the main-thread-bridged `/api/surface-raycast`
    // provider. EVERY OTHER caller — the per-frame render-loop's
    // `buildToolVts` calls and every HTTP-thread subject builder
    // (`/api/toolpipe`, `/api/snap`, `/api/constrain`, `/api/path`) —
    // leaves this at its default `false`, so a stage's raycast branch
    // gated on `cursorValid` never runs off the main thread and never
    // runs more than once per real input event (not once per render
    // frame). `cursorX`/`cursorY` are meaningless when `cursorValid` is
    // false and MUST NOT be read.
    int  cursorX     = -1;
    int  cursorY     = -1;
    bool cursorValid = false;
}


/// The cooked 2D event — the single place a gesture's pixel state is stated.
///
/// CALLER-SUPPLIED, exactly like `SubjectPacket` above, and for the same
/// reason: it is not derived from anything a stage can see. The input event
/// arrives in the vector stack; no slot computes it. `app.d`'s
/// `buildToolVts` publishes it, and its trailing `GesturePacket` parameter
/// defaults to `GesturePacket.init` — so the mouse-event dispatch sites
/// (which cook one per SDL event, see `GestureTrack` below) publish a valid
/// packet and EVERY other call site — the per-frame render loop, the
/// key-down dispatch, the overlay-packet builders, any HTTP-thread subject
/// builder — publishes the default, whose `valid` is false. That is the
/// exact discipline `SubjectPacket.cursorValid` already carries, and a
/// consumer must honour it the same way: when `valid` is false, NO other
/// field of this packet means anything.
///
/// Both the incremental and the cumulative form are carried, deliberately.
/// The cumulative offset (cursor minus the gesture's anchor pixel) is where
/// this is going; the increment (cursor minus the previous event's pixel)
/// is what every tool in this tree computes for itself today. Carrying both
/// is a MIGRATION DEVICE, not a mirror of anything: it makes the eventual
/// move to the cumulative convention a separate, named, behaviour-changing
/// commit instead of a silent side effect of adopting the packet. Do not
/// "tidy" one of the two away — deleting `increment*` presumes the switch
/// already happened, and deleting `cumulative*` deletes the destination.
///
/// `phase` names the SDL event that produced this packet, nothing more. A
/// hover motion with no button held is a `Move` like any other; the packet
/// does not model button state, and a consumer that needs "is a button
/// down" must read it from the event it was handed. `pressX/pressY` and
/// `prevX/prevY` are only meaningful inside a gesture — between a press and
/// its release they describe that gesture; outside one they describe the
/// last press that happened, which is not a measurement of anything.
struct GesturePacket {
    enum Phase : ubyte { Idle, Down, Move, Up }
    Phase phase   = Phase.Idle;
    bool  valid   = false;

    int pressX = -1, pressY = -1;   // the anchor pixel of this gesture
    int curX   = -1, curY   = -1;   // this event's pixel
    int prevX  = -1, prevY  = -1;   // the previous event's pixel

    int cumulativeX() const { return curX - pressX; }
    int cumulativeY() const { return curY - pressY; }
    int incrementX()  const { return curX - prevX;  }
    int incrementY()  const { return curY - prevY;  }

    /// The press-time world anchor, when known. NOTHING SETS THESE TODAY —
    /// the event dispatch that cooks this packet has pixels and no scene
    /// query, and the tools that do hold a press-time world point keep it
    /// in their own session state. The pair is declared here so the field
    /// that a world-anchored consumer will need has one agreed name and one
    /// agreed validity flag, instead of three tools inventing three. Read it
    /// only through `anchorValid`, which is false until a producer exists.
    Vec3 anchorWorld = Vec3(0, 0, 0);
    bool anchorValid = false;
}

/// The caller's press/previous bookkeeping behind `GesturePacket`. NOT a
/// packet: it never goes on the wire, it is per-event mutable state, and it
/// lives here only so the stamping rule sits next to the thing it stamps and
/// can be pinned by a unittest instead of hiding inside a nested function in
/// `app.d`.
///
/// One instance per event source (`app.d` keeps a single one, on the main
/// thread, alongside the other mouse bookkeeping).
struct GestureTrack {
    int pressX = -1, pressY = -1;
    int prevX  = -1, prevY  = -1;

    /// Cook ONE mouse event and advance the bookkeeping.
    ///
    /// Call this exactly once per SDL mouse event, at the TOP of the
    /// handler, BEFORE any dispatch — two properties depend on that
    /// placement and neither is cosmetic:
    ///
    ///  * every dispatch site inside one handler then publishes the SAME
    ///    cooked event (a handler can reach `buildToolVts` from several
    ///    branches; they must not disagree about what the event was), and
    ///  * `prev` advances on EVERY event, including the handler's many
    ///    early returns — otherwise a gesture that passes through a
    ///    consumed branch would leave `prev` behind and the next
    ///    `increment*` would silently span two events.
    ///
    /// A `Down` re-anchors: press and prev both become this pixel, so the
    /// press event's own increment and cumulative offset are both zero,
    /// which is what "the gesture has not moved yet" means.
    GesturePacket event(GesturePacket.Phase ph, int x, int y) {
        if (ph == GesturePacket.Phase.Down) {
            pressX = x; pressY = y;
            prevX  = x; prevY  = y;
        }
        GesturePacket g;
        g.phase  = ph;
        g.valid  = true;
        g.pressX = pressX; g.pressY = pressY;
        g.prevX  = prevX;  g.prevY  = prevY;
        g.curX   = x;      g.curY   = y;
        prevX = x; prevY = y;
        return g;
    }
}

/// Action-center packet — the action origin produced by ACEN stage in 7.2.
/// Default = world origin so 7.0 callers see a sane value if they read
/// it before any ACEN stage is registered.
struct ActionCenterPacket {
    Vec3 center = Vec3(0, 0, 0);
    // Whether this center is "auto" (recomputes on selection change) or
    // "manual" / preset-driven (sticky until user moves it). Surfaced as
    // the A column in the tool pipe panel.
    bool isAuto = true;
    // Mode enum (the `actr.<mode>` presets). 0 = Auto, see
    // toolpipe.stages.actcenter.ActionCenterStage.Mode for full list.
    int  type   = 0;
    // Per-element pivots (Phase 3 of the action-center design doc).
    // Populated by `actr.local` when the selection has multiple disjoint
    // clusters: each cluster scales/rotates around its own centroid.
    // `clusterCenters[clusterOf[vi]]` is the per-vertex pivot.
    // `clusterOf[vi] == -1` means vertex `vi` is not in the selection
    // (tools must skip it). When `clusterCenters.length == 0` the packet
    // is in single-pivot mode and tools fall back to `center`.
    Vec3[] clusterCenters;
    int [] clusterOf;
}

/// Axis packet — orientation produced by AXIS stage in 7.2.
/// Default = world axes (right=+X, up=+Y, fwd=+Z).
struct AxisPacket {
    Vec3 right = Vec3(1, 0, 0);
    Vec3 up    = Vec3(0, 1, 0);
    Vec3 fwd   = Vec3(0, 0, 1);
    // Hint for axis-aligned consumers: 0/1/2 = principal world axis,
    // -1 = arbitrary basis.
    int  axIndex = -1;
    // Mode enum (the `axis.<mode>` presets). 0 = Auto, see
    // toolpipe.stages.axis.AxisStage.Mode for full list.
    int  type    = 0;
    bool isAuto  = true;
    // Item mode 0614 (review should-fix 1): the SINGLE declared "does this
    // basis co-rotate with a selection-derived gesture?" capability —
    // `AxisStage.modeTracksSelection(type)` narrowed by the SAME subject
    // selType the evaluate() call that produced `right/up/fwd` actually
    // used. Publishing it here (rather than leaving consumers to recompute
    // `modeTracksSelection(type)` themselves against the raw `type`) is
    // load-bearing: `type` still names the configured mode (e.g. Select)
    // even when the item-mode guard in `computeBasis()` made THIS evaluation
    // fall back to the Auto/world basis, so a consumer keyed off `type`
    // alone would believe a world-fixed item frame co-rotates with the
    // gesture. Consumers (xfrm_transform.d's renderBasis) must read this
    // field, not re-derive from `type`.
    bool tracksSelection = false;
    // Per-cluster basis (Phase 4 of the action-center design doc).
    // Mirrors ActionCenterPacket.clusterCenters / clusterOf semantics:
    // when `clusterRight.length >= 2` the packet is in multi-cluster
    // mode and tools must use `clusterRight[clusterId]` /
    // `clusterUp[clusterId]` / `clusterFwd[clusterId]`. Cluster ids
    // come from ActionCenterPacket.clusterOf so the two packets stay
    // in lockstep. Lengths match ActionCenterPacket.clusterCenters.
    Vec3[] clusterRight;
    Vec3[] clusterUp;
    Vec3[] clusterFwd;

    // Cached orthonormal frame matrix (forward-compat — see below).
    //
    // `m` is the rotation-only orthonormal frame whose upper-left 3x3 has
    // the basis vectors right/up/fwd in columns 0/1/2 (translation = 0,
    // bottom-right w = 1). Column-major, m[row + col*4] — the same layout
    // as every other matrix in math.d (modelMatrix / matMul4 / mulMV).
    // `mInv` is its inverse; because the frame is orthonormal the inverse
    // equals the transpose of the rotation part, so we store the transpose
    // directly.
    //
    // No current consumer reconstructs a frame matrix from right/up/fwd —
    // every existing reader uses the three basis vectors directly. These two
    // fields are provided for downstream use (a consumer that wants to map
    // world<->frame coordinates without rebuilding the matrix each call) and
    // are populated by AxisStage.evaluate from the SAME right/up/fwd it
    // computes, so they never disagree with the vectors. GLOBAL frame only:
    // there is deliberately no per-cluster m/mInv (no consumer needs it; the
    // per-cluster basis stays available as the clusterRight/Up/Fwd vectors).
    float[16] m    = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    float[16] mInv = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
}

/// Workplane state — produced by WORK stage in 7.1. Default = world XZ
/// plane (normal = +Y, axis1 = +X, axis2 = +Z, center = origin), matching
/// the Y-up convention. A stage choosing the most-camera-facing plane
/// (which today's BoxTool / Pen / etc. do via `pickMostFacingPlane`)
/// overrides the basis; `center` is whatever the workplane stage published
/// (auto-mode keeps it at world origin; manual / alignToSelection moves it).
struct WorkplanePacket {
    Vec3 normal = Vec3(0, 1, 0);
    Vec3 axis1  = Vec3(1, 0, 0);
    Vec3 axis2  = Vec3(0, 0, 1);
    Vec3 center = Vec3(0, 0, 0);
    bool isAuto = true;
}

/// Falloff type — published by WGHT stage in phase 7.5. Originally one
/// active type at a time; multi-falloff stacking adds `Composite` (a
/// packet whose weight is the Mix-Mode combination of N sub-packets in
/// `FalloffPacket.contributors`). The choice is stashed on the stage
/// rather than using one tool per type.
enum FalloffType : uint {
    None      = 0,   // 7.5a — packet present but `enabled = false`
    Linear    = 1,   // 7.5b
    Radial    = 2,   // 7.5c
    Screen    = 3,   // 7.5d
    Lasso     = 4,   // 7.5e
    Cylinder  = 5,   // Stage 12 — radial-perpendicular-to-axis (xfrm.vortex)
    Element   = 6,   // Stage 14.1 — sphere around picked element centroid (xfrm.elementMove preset)
    Selection = 7,   // D.7 — `falloff.selection`; confined to the selection, boundary pinned to 0, interior weight rises with graph-hop ring distance from the border (xfrm.flex preset)
    Composite = 8,   // multi-falloff — weight = Mix-Mode accumulation of `contributors` (each sub-packet carries its own `mix`)
    VertexMap = 9,   // per-vertex weight read from a named Point dim-1 MeshMap; defaults to 1.0 for unregistered / out-of-range vertices
}

/// Maps a wire `type` token to its `FalloffType`, or returns `false` for an
/// unrecognised token. Deliberately does NOT accept `"none"` — the two
/// call sites disagree on what to do with it: `FalloffStage.applySetAttr`'s
/// "type" case accepts it directly (setting `FalloffType.None`, a real state
/// a stage can hold), while `commands.falloff.validFalloffType` (a
/// `falloff.add`/`falloff.<type>` guard) must REJECT it (adding an inert
/// None-type stage makes no sense) — so both share this ONE lookup for the
/// nine real types instead of two independently hand-maintained token lists
/// that could drift apart (task 0179 Stage 4).
bool falloffTypeFromName(string name, out FalloffType type) {
    switch (name) {
        case "linear":    type = FalloffType.Linear;    return true;
        case "radial":    type = FalloffType.Radial;    return true;
        case "screen":    type = FalloffType.Screen;    return true;
        case "lasso":     type = FalloffType.Lasso;     return true;
        case "cylinder":  type = FalloffType.Cylinder;  return true;
        case "element":   type = FalloffType.Element;   return true;
        case "selection": type = FalloffType.Selection; return true;
        case "vertexMap": type = FalloffType.VertexMap; return true;
        default: return false;
    }
}

/// Falloff Mix Mode — how a contributor's per-vertex weight combines with
/// the running accumulator when multiple falloffs are stacked (see the
/// Composite branch of `evaluateFalloff` in source/falloff.d). The FIRST
/// contributor seeds the accumulator, so its `mix` is unused; every later
/// contributor's `mix` selects the combine op against the accumulator.
/// Wire keys (used by `tool.pipe.attr falloff mix <key>`): multiply / add
/// / subtract / max / min.
///
/// Int-backed (NOT ubyte) so the FalloffStage Tool-Properties dropdown can
/// bind it via `Param.intEnum_(cast(int*)&mix, ...)` — that helper takes an
/// `int*` and writes 4 bytes through it, so the field must be int-sized.
enum FalloffMix : int {
    Multiply = 0,   // accum * w   (default)
    Add      = 1,   // accum + w
    Subtract = 2,   // accum - w
    Max      = 3,   // max(accum, w)
    Min      = 4,   // min(accum, w)
}

/// Element-falloff "Connected Elements" mode — the `falloff.element`
/// `connect` attr, realigned to the reference modeling app's taxonomy:
///
///   * Ignore          — ignore connectivity entirely; a vert anywhere
///                       in range attenuates by pure geometric distance
///                       regardless of which surface it belongs to.
///   * UseConnectivity — only the same connected surface participates;
///                       verts in other components are gated to weight 0,
///                       but verts in the picked component still attenuate
///                       by distance within the falloff radius.
///   * Rigid           — "Rigid Connections": the whole picked connected
///                       component moves rigidly the full distance
///                       (weight 1, no attenuation); other components 0.
///   * EdgeLoops       — only the connected quad edge-loop row. NOT
///                       implemented yet (needs quad-loop detection + a
///                       reference capture); the enum value exists so the
///                       dropdown / round-trip is complete, but the
///                       evaluation currently behaves as UseConnectivity.
///
/// All three implemented modes use the same BFS over `mesh.edges` to
/// build the connected-component mask; they differ only in how the gate
/// shapes the weight (UseConnectivity attenuates, Rigid forces 1).
enum ElementConnect : ubyte {
    Ignore          = 0,
    UseConnectivity = 1,
    Rigid           = 2,
    EdgeLoops       = 3,
}

/// Element-falloff pick mode (Stage 14.8) — the `falloff.element`
/// `element-mode` enum surfaced in the UI dropdown. Controls which
/// element TYPE is eligible to be picked:
///
///   * `auto`    — accept vertex / edge / face (priority vert → edge → face).
///   * `vertex`  — vertices only.
///   * `edge`    — edges only.
///   * `polygon` — faces only.
///
/// All modes anchor the gizmo pivot and falloff sphere at the picked
/// element's geometric centre (vertex position, edge midpoint, face
/// centroid). Values kept non-contiguous for byte-stability with
/// serialised data (integers 1, 4, 6 are retired and must not be reused).
enum ElementMode : ubyte {
    Auto    = 0,
    Vertex  = 2,
    Edge    = 3,
    Polygon = 5,
}

/// Per-shape attenuation curve. `t ∈ [0, 1]` is the normalised
/// distance from full-influence to no-influence; the curve maps it
/// to a weight ∈ [0, 1].
///
///   Linear  → 1 - t                    even attenuation (default)
///   EaseIn  → 1 - t²                   stronger near full-influence
///   EaseOut → (1 - t)²                 stronger near zero-influence
///   Smooth  → 1 - smoothstep(t)        S-curve
///   Custom  → cubic Bézier via in_/out_ control coords
enum FalloffShape : ubyte {
    Linear  = 0,
    EaseIn  = 1,
    EaseOut = 2,
    Smooth  = 3,
    Custom  = 4,
}

/// Lasso shape — the "Style" property in the lasso falloff panel.
/// Freehand stores an arbitrary polygon in `lassoPolyX/Y`; the other
/// three styles are 2-corner shapes computed on the fly.
enum LassoStyle : ubyte {
    Freehand  = 0,
    Rectangle = 1,
    Circle    = 2,
    Ellipse   = 3,
}

/// Falloff CONFIG — the value field-set shared by `FalloffStage` (the live
/// tool config) and `FalloffPacket` (the published wire copy). Embedding this
/// ONE struct in both (`FalloffConfig config; alias config this;`) collapses
/// the ~8 hand-copied field lists (evaluate / snapshotConfigToPacket /
/// restoreConfigFromPacket / reset / knownAttrs / listAttrs / applySetAttr /
/// falloffPacketsEqual) down to a single declaration site, so equality
/// (compiler-generated `==`) and the snapshot/restore round-trip can never
/// drift again (task 0179 / audit-2 F1: `falloffPacketsEqual` had drifted and
/// silently omitted `normal` / `pickedRadius` / `connect` / `elementMode` /
/// `anchorRing`, and `steps` / `mapName` had no packet field at all).
///
/// Every field carries its declaration-time default EXPLICITLY (never a bare
/// `Vec3`/`float` decl) — `float.init` / `Vec3.init` is NaN, and `reset()`
/// does `config = FalloffConfig.init`, so a bare field would both poison the
/// reset AND break equality forever (`NaN != NaN` ⇒ `config != config`).
///
/// Does NOT hold: `enabled` (derived = `type != None`, compared as its own
/// scalar), `pickedCenter` (ACEN-owned, published per-evaluate — outside
/// `config`, but still compared by `falloffPacketsEqual` as its own
/// Element-gated scalar since task 0724), or any of the derived/published
/// buffers
/// (`connectMask`, `anchorPos`, `selectionWeights`, `vertexMapWeights`,
/// `compoundPasses`, `contributors`) — those stay direct members of
/// `FalloffPacket` / `FalloffStage`, rebuilt every evaluate().
struct FalloffConfig {
    FalloffType  type        = FalloffType.None;
    FalloffShape shape       = FalloffShape.Linear;

    // Linear: gradient between two world-space points. weight = 1.0
    // at `start`, 0.0 at `end`, attenuated by `shape`.
    Vec3         start       = Vec3(0, 0, 0);
    Vec3         end         = Vec3(0, 1, 0);

    // Radial: ellipsoid centred at `center` with per-axis radii
    // `size`. weight = 1.0 at the centre, 0.0 outside the ellipsoid
    // surface.
    Vec3         center      = Vec3(0, 0, 0);
    Vec3         size        = Vec3(1, 1, 1);

    // Cylinder: same `center` + `size` as Radial, but the falloff
    // depends only on the perpendicular distance from `axis` (an
    // infinite cylinder around the line `center` + t*axis). Default
    // axis = +Y matches the xfrm.vortex preset (axisY=1.0).
    Vec3         normal      = Vec3(0, 1, 0);

    // Element: spherical falloff around `pickedCenter` (ACEN-owned,
    // NOT config — see struct doc), radius `pickedRadius`. Radius is
    // the `dist`/Range attr (wire attr name stays `dist`). Default
    // radius 1.0 — gets relocated by XfrmTransformTool's click-to-pick
    // (when falloff.element is active) or by the user via
    // `tool.pipe.attr falloff dist <r>`.
    float        pickedRadius  = 1.0f;
    // Element connectivity gate (Stage 14.4). When != Off, the
    // sphere weight is shaped by the connected-component mask
    // (`connectMask`, a BFS over mesh.edges from the picked element).
    // The `connect` attr is one of Ignore / UseConnectivity / Rigid /
    // EdgeLoops (see ElementConnect): Ignore disables the gate,
    // UseConnectivity gates non-component verts to 0 (attenuating
    // within the component), Rigid forces component verts to weight 1.
    // EdgeLoops is a documented stub that currently behaves as
    // UseConnectivity (pending quad edge-loop detection).
    ElementConnect connect    = ElementConnect.Ignore;
    // Element pick mode (Stage 14.8). XfrmTransformTool reads this
    // (when falloff.element is active) to restrict which element
    // types LMB-pick will hit and where pickedCenter lands on the
    // picked element. Default Auto = vert→edge→face priority,
    // centred on the natural pick point.
    ElementMode    elementMode = ElementMode.Auto;

    // Selection (D.7, xfrm.flex): the "Steps" count — the ring-seed cap
    // depth `S` (`S = max(steps, 1)`) the per-vert weight ramps across
    // from the selection border inward (`seed = min(ring, S) / S`). The
    // blur that follows the seed is a FIXED 4-pass graph-Laplacian Jacobi,
    // independent of this value — see `recomputeSelectionWeights`. Integer
    // by nature (discrete hops).
    int steps = 2;

    // Anchor ring — vertex indices that get weight=1.0 regardless
    // of the sphere math. Click-pick populates with the clicked
    // element's vert ring (single vert / edge endpoints / face vert
    // ring). Together with the sphere around `pickedCenter`, they
    // form a hybrid "anchor + attenuation" weight function. Empty
    // when no pick. RAW picked ring (config round-trip value) — the
    // PUBLISHED packet's copy is overwritten post-copy in evaluate()
    // with the RESOLVED ring (EdgeLoops substitutes the ordered loop);
    // see FalloffStage.evaluate's `pkt.config.anchorRing = …` line.
    // Mutable (not `const(uint)[]`) — the owning stage mutates it in
    // reset() / restoreConfigFromPacket() / the `anchorRing` setAttr
    // parser.
    uint[]  anchorRing;

    // Screen: disc in window pixels at (cx, cy), radius `screenSize`,
    // projected as an infinite cylinder along the camera-back axis.
    // `transparent = false` means the falloff only affects camera-
    // facing geometry (verts behind the camera get weight 0).
    float        screenCx     = 0;
    float        screenCy     = 0;
    float        screenSize   = 64;
    bool         transparent  = false;

    // Lasso: screen-space polygon (Freehand) or 2-corner shape
    // (Rectangle/Circle/Ellipse). Inside the polygon weight = 1.0;
    // outside, attenuated across `softBorderPx` pixels via `shape`.
    LassoStyle   lassoStyle   = LassoStyle.Freehand;
    float[]      lassoPolyX;
    float[]      lassoPolyY;
    float        softBorderPx = 16;

    // Custom shape (when `shape == FalloffShape.Custom`): cubic
    // Bézier control coords at t=0 (in_) and t=1 (out_). Both ∈ [0, 1].
    float        in_         = 0.5f;
    float        out_        = 0.5f;

    // Multi-falloff Mix Mode — how this sub-packet's weight combines with
    // the accumulator when it is contributor i≥1 inside a Composite (the
    // first contributor's `mix` is unused; it seeds the accumulator). For
    // a stand-alone (non-Composite) packet this field is irrelevant and
    // stays at the default.
    FalloffMix mix = FalloffMix.Multiply;

    // VertexMap: name of the active weight map (a Point dim-1 MeshMap).
    // Empty / missing map degenerates to full influence (weight 1.0).
    string mapName = "";

    /// Deep copy, so the copy is independent of subsequent in-place
    /// mutation of the source's mutable slice members (`anchorRing`,
    /// `lassoPolyX`, `lassoPolyY`). Iterates `tupleof` so it CANNOT drift
    /// as fields are added — a mutable array field is `.dup`'d, a `string`
    /// (immutable elements) is shared by value, everything else (scalars /
    /// enums / Vec3) is a plain value copy. Field-by-field (not
    /// `FalloffConfig c = this;`) because a struct containing mutable slices
    /// can't implicitly const→mutable copy in D. Used by
    /// snapshot/restoreConfigFromPacket.
    FalloffConfig dup() const {
        FalloffConfig c;
        foreach (i, ref dst; c.tupleof) {
            static if (is(typeof(dst) == string))
                dst = this.tupleof[i];          // immutable elements — share
            else static if (is(typeof(dst) : E[], E))
                dst = this.tupleof[i].dup;       // mutable slice — deep copy
            else
                dst = this.tupleof[i];          // scalar / enum / Vec3 value
        }
        return c;
    }
}

/// Falloff packet — soft-selection weight, populated by WGHT stage
/// in 7.5. Value-typed (no `Object`-derived state), matching
/// SnapPacket's pattern; `evaluateFalloff(packet, pos, vi, vp)` in
/// `source/falloff.d` does the actual weight math, dispatched on
/// `type`. Returns 1.0 for every vertex when `enabled == false`, so
/// transform tools can blindly multiply by the weight without
/// short-circuiting.
///
/// The CONFIG field-set (type/shape/start/end/…/anchorRing/mapName) lives in
/// the embedded `FalloffConfig` (`alias config this` — every external
/// `pkt.<field>` read/write below keeps resolving unqualified). The fields
/// declared directly here are DERIVED / published-per-evaluate and
/// deliberately excluded from `config` (and so from `falloffPacketsEqual`'s
/// `config ==` comparison), per FalloffConfig's doc comment — with
/// `pickedCenter` the one exception, compared by its own explicit scalar
/// check there (task 0724).
struct FalloffPacket {
    FalloffConfig config;
    alias config this;

    bool         enabled;

    // Element: spherical falloff centre. ACEN-owned (published per-evaluate
    // from ActionCenterPacket) — NOT part of `config`, and the gizmo pivot
    // does have its own source of truth and its own pin hooks. It IS
    // nevertheless compared by `falloffPacketsEqual`, under an Element-type
    // gate, because `elementWeight` reads it: being ACEN-owned makes it not a
    // config field, it does not make it not an input (audit-4 P9 / task 0724
    // — see that function for why the gate is load-bearing and not an
    // optimisation).
    // Default centre at origin; relocated by XfrmTransformTool's click-to-
    // pick when falloff.element is active, or by moving the action centre
    // itself — e.g. `tool.pipe.attr actionCenter userPlacedCenter "x,y,z"`.
    // There is NO `tool.pipe.attr falloff pickedCenter` (this comment claimed
    // one until 0724; the falloff stage's setAttr has no such case, so the
    // route was always ACEN's).
    Vec3         pickedCenter  = Vec3(0, 0, 0);

    // BFS-precomputed component mask for the picked element: index
    // into the same vert array, `true` for verts in the picked
    // element's connected component(s). Two producers fill it:
    // XfrmTransformTool's interactive click-pick, AND — for headless
    // tool.doApply — FalloffStage.evaluate / transform.d resolve it
    // from `anchorRing` + mesh edge-adjacency at packet-publish time
    // (mirroring how `anchorPos` is resolved). Consumers see an empty
    // mask only when `connect == Ignore` or no anchor ring exists; in
    // that case `elementWeight` applies the unrestricted sphere.
    const(bool)[] connectMask;

    // Anchor positions — the WORLD positions of the picked element's
    // verts, parallel to the RESOLVED `anchorRing` (anchorPos[i] is the
    // world position of vertex anchorRing[i]). This is the GEOMETRY the
    // Element falloff attenuates from: `elementWeight` measures the
    // distance from each vert to this geometry (point / segment /
    // polygon) rather than to the single `pickedCenter` centroid, so
    // an edge / polygon pick attenuates by distance to the SEGMENT /
    // FACE — matching the reference editor (a centroid-only sphere
    // diverges for non-vertex picks). Empty when no pick (or for a
    // non-pick scripted falloff): `elementWeight` then falls back to
    // the `pickedCenter` point distance.
    const(Vec3)[]  anchorPos;

    // Selection (D.7, xfrm.flex): pre-baked per-vert weights ∈ [0, 1]
    // from a ring-distance seed (graph-hop BFS from the selection border)
    // + a fixed-4-pass graph-Laplacian Jacobi blur + a fixed smoothstep
    // ease (see `recomputeSelectionWeights`). Selected verts on the
    // boundary → 0 (anchor); deep interior → close to 1; unselected → 0.
    // Empty slice degenerates to "no falloff" (caller multiplies by 1.0
    // for every vert).
    const(float)[] selectionWeights;

    // VertexMap: pre-baked per-vert weights read from a named Point
    // dim-1 MeshMap. Values are clamped to [0, 1] at READ time in
    // falloff.d so the slice stays raw (future parity modes may want
    // the un-clamped data). Empty slice degenerates to full influence.
    const(float)[] vertexMapWeights;

    // Compound passes — exponent the SCALE kernel applies to
    // the per-axis factor: `s_eff = (1 + (s-1)·w) ^ compoundPasses`.
    // For Selection falloff this equals `Steps · 0.955`, an
    // empirical Flex Scale saturation convergence factor (the 0.955
    // captures the "saturation falls short of SY^Steps" property of
    // the iterative weight smoothing). Float so the fractional
    // 0.955 multiplier round-trips through `pow`. Every other
    // falloff type ships 1.0 → the standard single-application
    // `factor = 1 + (s-1)·w` path. Translate / Rotate kernels
    // ignore this field; compounding only makes physical sense
    // for the multiplicative Scale formula.
    float compoundPasses = 1.0f;

    // Composite sub-packets. Only populated when `type == Composite`.
    // Each entry is a VALUE COPY of a contributing falloff's packet (the
    // combiner owns them outright — it never stores pointers/slices into
    // another stage's live members, so the contributors outlive the
    // stage that produced them and stay valid for the whole pipe walk).
    // `evaluateFalloff` on a Composite accumulates the contributors'
    // weights in order via each contributor's `mix` (see source/falloff.d).
    // FLAT: contributors are never themselves Composite (the combiner
    // flattens on build), so the accumulation is a single linear pass.
    FalloffPacket[] contributors;
}

/// Symmetry packet — populated by SYMM stage in 7.6. v1 ships
/// X / Y / Z plane axes with optional offset; arbitrary-axis support is
/// reserved (axisIndex == -1) but no UX path enters it.
///
/// `pairOf` / `onPlane` are the per-vertex pairing snapshot the SYMM
/// stage rebuilds when `Mesh.mutationVersion` changes; consumers see a
/// stable view for the duration of one `pipeline.evaluate`.
/// `pairOf[i] == -1` means "no mirror within `epsilonWorld`" OR
/// "on the plane" (the latter is distinguished by `onPlane[i] == true`).
///
/// `axisFlags[3]` / `pivot` are the original phase-7.0 stub fields;
/// kept derived so any pre-7.6 code that read them keeps working
/// (`axisFlags[axisIndex] == true` when enabled; pivot = axis * offset).
struct SymmetryPacket {
    bool         enabled      = false;        // master on/off
    int          axisIndex    = -1;           // 0=X 1=Y 2=Z; -1 when disabled
    float        offset       = 0.0f;         // plane = axis * offset
    bool         useWorkplane = false;        // mirror ≡ workplane (overrides axis/offset)
    // WIRED, not reserved (stale comment fixed, task 1060 side-errand):
    // `SymmetryStage.evaluate` branches on this — true routes to
    // `symmetry.rebuildPairingTopological` (a real connectivity walk from
    // on-plane seam vertices), false to the plane-distance pairing. Exposed
    // as the `topology` HTTP setAttr key and the `mesh.symmetrize` `topology`
    // arg (source/commands/mesh/symmetrize.d).
    bool         topology     = false;
    float        epsilonWorld = 1e-4f;        // pairing tolerance

    // Cached plane (populated by SymmetryStage.evaluate from the axis /
    // offset / workplane fields above):
    Vec3         planePoint   = Vec3(0, 0, 0);
    Vec3         planeNormal  = Vec3(1, 0, 0);  // normalized

    // Per-vertex pairing snapshot. Length matches `subject.mesh.vertices`
    // when `enabled` (otherwise empty). Indices into `mesh.vertices`,
    // or -1 (= unpaired or on-plane — see `onPlane`).
    int[]        pairOf;
    bool[]       onPlane;

    // Per-vertex pre-translate side of the symmetry plane: -1 / 0 / +1.
    // Built alongside `pairOf` by `rebuildPairing` from the snapshot
    // mesh, so it stays stable through one operation even if a
    // translate would push a vertex across the plane mid-op. `0` means
    // the vert is on the plane (and `onPlane[i]` is also true).
    int[]        vertSign;

    // Base side — which side of the plane the user last anchored on.
    // Drives the mirror loop's choice of
    // "user side" when a symmetric pair is fully selected (e.g.
    // 7.6c auto-add put both sides in the same selection). Default
    // +1 so unset state behaves predictably; `SymmetryStage.anchorAt`
    // updates it from a world-space anchor point.
    int          baseSide = +1;

    // Backwards-compat fields the phase-7.0 stub already declared. The
    // stage populates them from `axisIndex` / `offset` so any code that
    // reads them keeps working through the migration.
    bool[3]      axisFlags;
    Vec3         pivot = Vec3(0, 0, 0);
}

// ---------------------------------------------------------------------------
// CONS packet types
// ---------------------------------------------------------------------------

/// Geometry constraint mode — dispatches how CONS projects moving verts
/// onto the background surface.
///
/// `off`    — disabled (packet present but no projection).
/// `screen` — project along camera forward (capture-gated, currently no-op;
///             ships accepted as an attr but returns identity until Stage 0
///             of doc/cons_constraint_plan.md resolves the direction).
/// `vector` — project along motion delta (capture-gated, same no-op policy).
/// `point`  — nearest world-space point on background surface (default;
///             ships as "nearest-foot closest-point" working assumption —
///             see plan §stage-4 and DoD notes on the two unverified
///             assumptions: nearest-foot vs camera-ray, and per-vertex vs
///             per-delta application).
///
/// Int-backed so an IntEnum Param / dropdown can bind it the same way
/// FalloffMix is (cast(int*)&geom).
enum ConstrainGeom : int {
    Off    = 0,
    Screen = 1,
    Vector = 2,
    Point  = 3,
}

/// Constraint packet — published by the CONS stage into the VectorStack
/// when the stage is enabled. Consumed by the transform apply path to
/// re-project each moved vertex onto the nearest background-mesh surface.
///
/// `screen`/`vector` modes and the `offset`/`handle`/`dblSided` fields
/// are capture-gated: they are round-trippable attrs (no-op in Stage 4)
/// and will be wired in Stage 5 once the Stage-0 captures resolve their
/// exact semantics. Default values match the survey §2 presets.
struct ConstrainPacket {
    bool          enabled  = false;
    ConstrainGeom geom     = ConstrainGeom.Point;
    float         offset   = 0.0f;    // standoff from surface; sign/direction capture-gated
    bool          handle   = true;    // constrain handle vs geometry; capture-gated
    bool          dblSided = false;   // project onto back faces; capture-gated
}

/// Background-surface RAYCAST result — published by the CONS stage
/// (topology-pen P0, doc/topopen_p0_plan.md) alongside `ConstrainPacket`
/// when `subj.cursorValid` is true. Distinct from `ConstrainPacket`
/// (the stage's CONFIG, always published when enabled): this packet
/// carries the per-cursor RESULT of casting a ray from the current pixel
/// through every background layer's mesh (`snap.backgroundSourcesSnapshot`)
/// and keeping the nearest hit — the thin `TopologyPenTool` consumer reads
/// this, never the raycast machinery itself (BvhPick lives in
/// `source/bvh_pick.d`; the raycast branch lives in the CONS stage).
///
/// Every field carries an explicit default (`Vec3.init`/`float.init` is
/// NaN in this codebase's convention) so a struct literal / `.init` never
/// reads as a real hit.
struct ConstrainHitPacket {
    bool  hit         = false;
    Vec3  point       = Vec3(0, 0, 0);
    Vec3  normal      = Vec3(0, 1, 0);
    int   layer       = -1;    // Document-layer index (document.layers[N]) the
                                // hit face belongs to (NIT-3; resolved from the
                                // bgSrc-order slot via
                                // snap.backgroundSourceLayerIndices() at publish
                                // time — falls back to the bgSrc-order slot
                                // itself if that mapping is unavailable)
    int   face        = -1;
    int   nearestVert = -1;
    int   nearestEdge = -1;
    float t           = float.infinity;

    // --- topology-pen P1 additions (doc/topopen_p1_plan.md) ----------------
    // World positions of the `nearestVert`/`nearestEdge` candidates, filled
    // by the CONS stage's raycastBackground alongside the indices above
    // (same guard: only meaningful when the paired index is >= 0). Carrying
    // the positions on the packet keeps `resolveHoverTarget` (constraint.d)
    // a PURE function of `(ConstrainHitPacket, Viewport, thresholdPx)` — it
    // never reaches back into a Mesh to re-resolve a world position.
    Vec3 nearestVertPos = Vec3(0, 0, 0);  // world pos of vertices[nearestVert]
    Vec3 nearestEdgeA   = Vec3(0, 0, 0);  // world pos of edges[nearestEdge][0]
    Vec3 nearestEdgeB   = Vec3(0, 0, 0);  // world pos of edges[nearestEdge][1]
}

/// The hover's resolved place-target — what a click at the current
/// background-surface hit would snap to. `None` means no surface hit at
/// all (mirrors `ConstrainHitPacket.hit == false`); `Face` means a surface
/// hit that did not resolve to a nearby vertex/edge (a free place-point).
/// Pure data — the resolution logic lives in `constraint.d` per the
/// codebase's pure-math-layer convention (see `resolveHoverTarget`).
enum HoverTargetKind { None, Vertex, Edge, Face }

/// `vert`/`edge` are indices into the WINNING background layer's own mesh
/// (`ConstrainHitPacket.layer`/`.nearestVert`/`.nearestEdge`) — meaningful
/// only for the matching `kind` (e.g. `vert` is -1 whenever `kind !=
/// Vertex`).
struct HoverTarget {
    HoverTargetKind kind = HoverTargetKind.None;
    int             vert = -1;
    int             edge = -1;
}

/// Geometry-snap candidate-type bitmask. Multiple types can be enabled
/// simultaneously; the closest screen-pixel candidate across all
/// enabled types wins. Covers the snap-element-mode types plus grid /
/// workplane variants — see doc/snap_plan.md.
enum SnapType : uint {
    None         = 0,
    Vertex       = 1 << 0,   // 7.3a
    Edge         = 1 << 1,   // 7.3b
    EdgeCenter   = 1 << 2,   // 7.3b
    Polygon      = 1 << 3,   // 7.3b
    PolyCenter   = 1 << 4,   // 7.3b
    Grid         = 1 << 5,   // 7.3c
    Workplane    = 1 << 6,   // 7.3c
    // Stage 1: six new constraint-target + item-scope types.
    // Bits 7-12; must not collide with the existing ≤bit6 types.
    Pivot        = 1 << 7,   // item pivot world point (Stage 3)
    Intersection = 1 << 8,   // screen-space edge crossing (Stage 6)
    WorldAxis    = 1 << 9,   // LINE constraint along X/Y/Z through origin (Stage 2)
    StraightLine = 1 << 10,  // LINE constraint along active axis (Stage 7, unwired)
    RightAngle   = 1 << 11,  // PLANE constraint normal = active axis (Stage 7, unwired)
    Box          = 1 << 12,  // AABB corners (discrete) + face planes (constraint) (Stage 4)
}

/// Snap scope — filters which enabled types are consulted in a query.
/// `Global`    = all enabled types (modeless default).
/// `Component` = only mesh-geometry types (Vertex/Edge/EdgeCenter/Polygon/
///               PolyCenter/Intersection) + scope-independent guides.
/// `Item`      = only item-frame types (Pivot/Box) + scope-independent guides.
/// Guide/grid/constraint types (Grid/Workplane/WorldAxis/StraightLine/
/// RightAngle) are scope-independent — they pass in every mode.
/// See snap.d `typeEligible` for the authoritative predicate.
enum SnapMode { Global, Component, Item }

/// Snap configuration — published by SNAP stage in 7.3. The actual
/// snap math runs in `source/snap.d`'s `snapCursor()` (called on every
/// motion event by tools that consume snap), since snap candidates
/// depend on the live cursor position and can't be precomputed once
/// per pipeline.evaluate.
///
/// 7.3c: also caches the upstream WORK stage's workplane state +
/// the resolved grid step, so snap.d's Grid / Workplane candidate
/// generators don't need to walk the pipeline themselves.
/// The SNAP stage's user-facing CONFIG — the seven fields a panel, an
/// argstring, a preset or an undo step can set, split out of `SnapPacket` by
/// task 0705 (audit 4, P8) on the `FalloffConfig` pattern.
///
/// It exists so that "the snap config" is ONE declaration instead of two.
/// `SnapPacket` and `SnapStage` each used to declare all seven, with their own
/// initialisers, and the two sets HAD already diverged once: the packet
/// carried inner 8 / outer 40 against the stage's 24 / 40, so the four call
/// sites that serve `SnapPacket.init` as a fallback snapped with a 3x narrower
/// acceptance and a 1.67x narrower gather, silently. That was patched with a
/// unittest comparing the two sets field by field and a comment in each
/// declaration telling the reader to "change them THERE and here in one edit".
/// Now there is no second place to change: one struct, one set of
/// initialisers, and the compiler's `==` for the comparison.
///
/// Five bodies collapse with it — `evaluate`'s seven assignments,
/// `reset`, `snapshotConfigToPacket`, `restoreConfigFromPacket` and
/// `snapPacketsEqual` were each a hand-written enumeration of the same seven
/// names, so a new config field cost eleven edits. It now costs one
/// declaration plus its wire rows (`listAttrs` / `applySetAttr` / `params`),
/// which is the same bill `FalloffConfig` leaves.
struct SnapConfig {
    bool     enabled       = false;     // master on/off (X key)
    // ONE TYPE ON BY DEFAULT, AND IT IS VERTEX. The reference ships a
    // per-type boolean SET exactly like this mask (twelve types x three
    // scopes, each independently togglable), so the SHAPE here is right and
    // must stay a set — what was wrong was the factory contents. Its shipped
    // factory set is `{vertex}` alone, and the three extra bits we used to
    // light up were not a richer default but a broken one, because candidates
    // compete on raw screen distance with no per-type priority (`snap.d`'s
    // `consider`: strict `d < bestDist`, nothing else). Grid is the fatal one
    // — it is a continuous lattice projected onto the workplane, so a grid
    // point sits within half a cell of the cursor ALWAYS and wins almost
    // every contest. The user-visible result was that dragging a vertex
    // appeared not to stick to nearby geometry at all: the vertex candidate
    // was generated, highlighted, and then silently outranked by a grid point
    // nobody asked for. EdgeCenter / PolyCenter lost less often but lost the
    // same way, stealing a snap from the real vertex beside them.
    //
    // THE CENTRE HALF OF THAT SENTENCE IS FIXED, and Grid's is not. A centre
    // is no longer a candidate at all — it refines the point on an element the
    // cross-type cascade has already elected (`snap.d`, `refineElectedLeg`),
    // so it cannot out-rank a vertex and cannot be reached from an element
    // that lost. Grid remains exactly as described, which is why it remains
    // the reason this default is one bit and not three.
    //
    // The CHANGE here is a default: every bit remains reachable from the Snap
    // panel and from `snap.toggleType`, and turning Grid back on restores the
    // old behaviour exactly.
    //
    // BUT DO NOT READ THAT AS "THE MODEL IS FINE" — it is not, and this
    // default CONCEALS the model gap rather than closing it. The reference's
    // own guide interface ranks candidates by (priority, distance); we rank by
    // distance alone, with no priority term anywhere. Narrowing the default to
    // one class simply removes the contests in which that difference shows.
    //
    // The proof that it is only concealed: our Edge candidate is the closest
    // point on the projected segment, so for ANY edge incident to a target
    // vertex its pixel distance is <= that vertex's, with equality only when
    // the cursor sits exactly on the vertex pixel. Vertex is enumerated first
    // and later candidates use strict `d < bestDist`, so ties go to Vertex and
    // everything else goes to Edge. Tick Edge — which is one click, and is
    // what the reference profile this was read from actually has ticked
    // alongside Vertex — and a point partway along the neighbour's edge wins
    // over the vertex again. Closing that needs the priority term, and what
    // the priorities ARE is not known from any document we hold.
    uint     enabledTypes  = SnapType.Vertex;
    // Stage 1: snap scope (Global/Component/Item). Named `snapScope` because
    // `scope` is a D reserved keyword. Default Global = all types eligible.
    SnapMode snapScope     = SnapMode.Global;
    // THE ONE PAIR — and since task 0705 there is genuinely only one pair.
    // These initialisers are the stage's too: `SnapStage` embeds this struct
    // rather than redeclaring the fields, and four call sites serve
    // `SnapPacket.init` as a silent fallback when the pipeline has no packet
    // (`tools/create/create_common.d`, `tools/transform/transform.d`). The two
    // sets used to be written twice and disagreed (8 / 24 here against 24 / 40
    // there), so a fallback got a 3x narrower acceptance and a 1.67x narrower
    // gather with no diagnostic — and the 8 was not even an acceptance radius,
    // it was the unrelated press-pick reach sitting in that slot by
    // coincidence.
    float  innerRangePx  = 24.0f;      // snap fires when cursor within this
    float  outerRangePx  = 40.0f;      // candidate highlights when within this
    bool   fixedGrid     = false;      // grid uses fixedGridSize, not dynamic
    float  fixedGridSize = 1.0f;       // world units per grid step (when fixedGrid)
}

struct SnapPacket {
    /// The seven config fields, embedded. `alias this` so every existing
    /// `pkt.enabled` / `pkt.innerRangePx` reader is untouched by the split.
    SnapConfig config;
    alias config this;

    // Workplane snapshot (mirrors WorkplanePacket fields). Used by
    // SnapType.Grid (grid lies on the workplane) and SnapType.Workplane
    // (cursor ray ∩ workplane plane).
    Vec3   workplaneCenter = Vec3(0, 0, 0);
    Vec3   workplaneNormal = Vec3(0, 1, 0);
    Vec3   workplaneAxis1  = Vec3(1, 0, 0);
    Vec3   workplaneAxis2  = Vec3(0, 0, 1);
    // Grid step in world units. fixedGrid=true ⇒ fixedGridSize. Else
    // matches the visible grid (vibe3d's grid is hard-coded at 1.0).
    float  gridStep        = 1.0f;
}

/// The RESULT of the snap query at the current cursor — the producer /
/// consumer channel between the SNAP stage and downstream tools. Distinct
/// from `SnapPacket`, which is the stage's CONFIG (always published while
/// the stage is enabled): this packet carries what the query at THIS
/// cursor pixel actually found.
///
/// It is the exact sibling of `ConstrainHitPacket` above — same producer
/// shape (a stage publishing a per-cursor result), same publication gate
/// (`SubjectPacket.cursorValid`, so the query runs once per real
/// main-thread input event and never on an HTTP thread), same field
/// convention (every field carries an explicit default, and a field is
/// meaningful only when the flag / index it is paired with says so).
///
/// Field-by-field this is `snap.SnapResult` — same names, same meanings —
/// plus the screen point and pixel distance of the winner, the
/// Document-layer index behind `targetSource`, and the query's guide
/// provenance. Nothing here is computed that the snap query did not
/// already compute.
///
/// WHY IT CARRIES ALL OF `SnapResult` and not the subset S2 first proposed
/// (plan §F5, "how far do we take the field list?"): the first attempt to
/// migrate a consumer measured the answer. `highlightPos` and
/// `constraintType` were omitted as header-derived fields nothing was known
/// to need — and every one of the existing consumers needs at least one of
/// them. `highlightPos` alone has two live readers today
/// (`snap_render.drawCursorMarker`, which projects it to place the pre-snap
/// ring, and `/api/snap/last`, which reports it), so a packet without it
/// cannot serve a single consumer byte-identically. The omission was a
/// guess; this is the measurement that replaced it.
///
/// What a consumer must know before reading it:
///
/// * `worldPos` / `screenX` / `screenY` / `distPx` are meaningful ONLY when
///   `snapped`. On a miss the query's pass-through position is the seed the
///   producer supplied, which is not a measurement of anything, so the
///   producer leaves all four at their defaults instead of publishing it.
/// * `targetType` / `targetIndex` / `targetSource` / `layer` name the
///   discrete ELEMENT that won, and are meaningful whenever `highlighted`
///   — an element can highlight without snapping (inside the outer gather
///   range, outside the inner acceptance range).
/// * When a LINE / PLANE constraint supplied the position while a discrete
///   element only highlighted, `worldPos` is the constrained point,
///   `constraintType` names what constrained it, and `highlightPos` /
///   `targetIndex` are the discrete element's — the same split
///   `SnapResult` itself carries between `worldPos` and `highlightPos`.
/// * `highlightPos` is meaningful ONLY when `highlighted`, on the same terms
///   as `worldPos` is paired with `snapped`.
/// * The query behind this packet has NO moving set: the stage has no
///   gesture and cannot know which vertices are being dragged, so nothing
///   is excluded. A consumer that drags geometry must still keep its own
///   exclusion (else it can read a snap onto the very element it moves).
/// * `guideCount` is the packet's PROVENANCE, not a result. It says how many
///   S4 guides re-ranked the walk that produced this answer. Zero means the
///   ranking is the historical "nearest pixel wins" — the same ranking a
///   tool-side `snapCursor` (which passes no registry) would have produced.
///   Non-zero means it is NOT, and a consumer migrating off its own query
///   under S2 phase (b) must refuse the packet there rather than silently
///   inherit a different winner. Migrating a consumer ONTO guide-aware
///   ranking is a declared behaviour change and belongs to S4 phase (b).
struct SnapHitPacket {
    bool     snapped      = false;
    bool     highlighted  = false;   // a candidate inside the OUTER range
    Vec3     worldPos     = Vec3(0, 0, 0);
    Vec3     highlightPos = Vec3(0, 0, 0);   // the highlighted candidate's point
    float    screenX      = 0, screenY = 0;   // the snapped point's own pixel
    float    distPx       = float.infinity;   // its distance from the cursor
    SnapType targetType   = SnapType.None;
    SnapType constraintType = SnapType.None; // the LINE/PLANE that placed
                                     // `worldPos`, when the discrete tier did
                                     // not snap; None when it did
    int      targetIndex  = -1;      // element index within the source's mesh
    int      targetSource = 0;       // 0 = active mesh, 1..N = background slot
    int      layer        = -1;      // Document-layer index, as ConstrainHitPacket;
                                     // -1 when the winner came from the active
                                     // mesh (whose layer the snap service does
                                     // not hold) or from no source at all
    int      guideCount   = 0;       // S4 guides that re-ranked this walk; 0 ==
                                     // the historical nearest-wins ranking
}

/// Path packet — published by the PATH stage. Carries the resolved
/// world-space polyline knots so a downstream consumer (curve-extrude,
/// clone, sweep) can sweep geometry along the path without needing its
/// own mesh access.
///
/// Fields mirror the PATH stage attrs: `start`/`end` clamp the active
/// sub-range of t ∈ [0, 1]; `slide` adds a phase offset (clamped in
/// the foundation, no wrap). `knots` are world-space positions resolved
/// at evaluate() time from the stage's vertex-index source.
struct PathPacket {
    bool   enabled = false;
    Vec3[] knots;
    bool   closed  = false;
    float  start   = 0.0f;
    float  end     = 1.0f;
    float  slide   = 0.0f;
}

// ---------------------------------------------------------------------------
// S3(a) — the cooked 2D event. These pin the two halves of the neutrality
// claim that can be pinned in a unittest:
//
//   * what a NON-mouse call site publishes (the default argument), and
//   * what the mouse call sites publish (GestureTrack's stamping rule).
//
// The half that cannot be pinned here is "nothing reads it" — that is a grep
// over `source/` and `tests/` for `get!GesturePacket` / `has!GesturePacket`,
// and it belongs in the commit message, not in an assert.
// ---------------------------------------------------------------------------
