module toolpipe.packets;

import math : Vec3, Viewport;
import mesh : Mesh;
import editmode : EditMode;

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
    Selection = 7,   // D.7 — `falloff.selection`; selected=1.0, unselected decays by BFS hop distance from selection (xfrm.flex preset)
    Composite = 8,   // multi-falloff — weight = Mix-Mode accumulation of `contributors` (each sub-packet carries its own `mix`)
    VertexMap = 9,   // per-vertex weight read from a named Point dim-1 MeshMap; defaults to 1.0 for unregistered / out-of-range vertices
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
///   Linear  → 1 - t                    even attenuation
///   EaseIn  → 1 - t²                   stronger near full-influence
///   EaseOut → (1 - t)²                 stronger near zero-influence
///   Smooth  → 1 - smoothstep(t)        S-curve (default)
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

/// Falloff packet — soft-selection weight, populated by WGHT stage
/// in 7.5. Value-typed (no `Object`-derived state), matching
/// SnapPacket's pattern; `evaluateFalloff(packet, pos, vi, vp)` in
/// `source/falloff.d` does the actual weight math, dispatched on
/// `type`. Returns 1.0 for every vertex when `enabled == false`, so
/// transform tools can blindly multiply by the weight without
/// short-circuiting.
struct FalloffPacket {
    bool         enabled;
    FalloffType  type        = FalloffType.None;
    FalloffShape shape       = FalloffShape.Smooth;

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

    // Element: spherical falloff around `pickedCenter`, radius
    // `pickedRadius`. The centre is the centroid of the clicked
    // component; radius is the `dist`/Range attr. Default centre at
    // origin, radius 1.0 —
    // gets relocated by XfrmTransformTool's click-to-pick (when falloff.element is active) or by the
    // user via `tool.pipe.attr falloff pickedCenter "x,y,z"`.
    Vec3         pickedCenter  = Vec3(0, 0, 0);
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
    // Anchor ring — vertex indices that get weight=1.0 regardless
    // of the sphere math. Click-pick populates with the clicked
    // element's vert ring (single vert / edge endpoints / face vert
    // ring). Together with the sphere around `pickedCenter`, they
    // form a hybrid "anchor + attenuation" weight function. Empty
    // when no pick.
    const(uint)[]  anchorRing;
    // Anchor positions — the WORLD positions of the picked element's
    // verts, parallel to `anchorRing` (anchorPos[i] is the world
    // position of vertex anchorRing[i]). This is the GEOMETRY the
    // Element falloff attenuates from: `elementWeight` measures the
    // distance from each vert to this geometry (point / segment /
    // polygon) rather than to the single `pickedCenter` centroid, so
    // an edge / polygon pick attenuates by distance to the SEGMENT /
    // FACE — matching the reference editor (a centroid-only sphere
    // diverges for non-vertex picks). Empty when no pick (or for a
    // non-pick scripted falloff): `elementWeight` then falls back to
    // the `pickedCenter` point distance.
    const(Vec3)[]  anchorPos;

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

    // Selection (D.7, xfrm.flex): pre-baked per-vert weights ∈
    // [0, 1] from a Dijkstra geodesic + applyShape curve.
    // Selected verts on the boundary → 0 (anchor); deep interior
    // → 1; unselected → 0. Empty slice degenerates to "no
    // falloff" (caller multiplies by 1.0 for every vert).
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

    // --- Multi-falloff stacking (Composite) ---
    //
    // This sub-packet's OWN Mix Mode — how its weight combines with the
    // accumulator when it is contributor i≥1 inside a Composite (the
    // first contributor's `mix` is unused; it seeds the accumulator).
    // For a stand-alone (non-Composite) packet this field is irrelevant
    // and stays at the default.
    FalloffMix mix = FalloffMix.Multiply;

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
    bool         topology     = false;        // reserved; v1 = false
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
struct SnapPacket {
    bool     enabled       = false;     // master on/off (X key)
    uint     enabledTypes  = SnapType.Vertex
                           | SnapType.EdgeCenter
                           | SnapType.PolyCenter
                           | SnapType.Grid;
    // Stage 1: snap scope (Global/Component/Item). Named `snapScope` because
    // `scope` is a D reserved keyword. Default Global = all types eligible.
    SnapMode snapScope     = SnapMode.Global;
    float  innerRangePx  = 8.0f;       // snap fires when cursor within this
    float  outerRangePx  = 24.0f;      // candidate highlights when within this
    bool   fixedGrid     = false;      // grid uses fixedGridSize, not dynamic
    float  fixedGridSize = 1.0f;       // world units per grid step (when fixedGrid)
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
