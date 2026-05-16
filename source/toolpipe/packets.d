module toolpipe.packets;

import math : Vec3;
import mesh : Mesh;
import editmode : EditMode;

// ---------------------------------------------------------------------------
// Packet types — the wire format between Tool Pipe stages.
//
// Names mirror MODO's LXsP_TOOL_* string IDs (lxtool.h) so future SDK /
// Python bridging is direct: `LXsP_TOOL_SUBJECT` → `SubjectPacket`,
// `LXsP_TOOL_ACTCENTER` → `ActionCenterPacket`, etc.
//
// Phase 7.0 ships only the SubjectPacket (constructed at pipe entry from
// the current scene state). The remaining packet types are stubbed here
// with the fields each later subphase needs, so the ToolState struct
// shape is stable and 7.1+ subphases just populate values without
// rearranging the layout.
// ---------------------------------------------------------------------------

/// LXsP_TOOL_SUBJECT — mesh + selection + edit mode at pipe entry.
/// Read-only snapshot; stages must not mutate the scene mesh through this
/// pointer (use the regular Mesh* path with snapshot/undo as elsewhere).
struct SubjectPacket {
    Mesh*      mesh;
    EditMode   editMode;
    // Snapshot of selection-bit arrays at evaluation time. Useful for
    // stages that compute selection-derived values (Action Center
    // "selection center", Falloff "lasso") without re-reading the mesh's
    // arrays mid-pipe.
    bool[]     selectedVertices;
    bool[]     selectedEdges;
    bool[]     selectedFaces;
}

/// LXsP_TOOL_ACTCENTER — the action origin produced by ACEN stage in 7.2.
/// Default = world origin so 7.0 callers see a sane value if they read
/// it before any ACEN stage is registered.
struct ActionCenterPacket {
    Vec3 center = Vec3(0, 0, 0);
    // Whether this center is "auto" (recomputes on selection change) or
    // "manual" / preset-driven (sticky until user moves it). Maps to
    // MODO's A column in the Tool Pipe panel.
    bool isAuto = true;
    // Mode enum (mirrors MODO `actr.<mode>`). 0 = Auto, see
    // toolpipe.stages.actcenter.ActionCenterStage.Mode for full list.
    int  type   = 0;
    // Per-element pivots (Phase 3 of doc/acen_modo_parity_plan.md).
    // Populated by `actr.local` when the selection has multiple disjoint
    // clusters: each cluster scales/rotates around its own centroid.
    // `clusterCenters[clusterOf[vi]]` is the per-vertex pivot.
    // `clusterOf[vi] == -1` means vertex `vi` is not in the selection
    // (tools must skip it). When `clusterCenters.length == 0` the packet
    // is in single-pivot mode and tools fall back to `center`.
    // Mirrors MODO's `LXpToolElementCenter` packet semantics.
    Vec3[] clusterCenters;
    int [] clusterOf;
}

/// LXsP_TOOL_AXIS — orientation produced by AXIS stage in 7.2.
/// Default = world axes (right=+X, up=+Y, fwd=+Z).
struct AxisPacket {
    Vec3 right = Vec3(1, 0, 0);
    Vec3 up    = Vec3(0, 1, 0);
    Vec3 fwd   = Vec3(0, 0, 1);
    // Hint for axis-aligned consumers: 0/1/2 = principal world axis,
    // -1 = arbitrary basis (matches MODO LXpToolAxis.axIndex semantics).
    int  axIndex = -1;
    // Mode enum (mirrors MODO `axis.<mode>`). 0 = Auto, see
    // toolpipe.stages.axis.AxisStage.Mode for full list.
    int  type    = 0;
    bool isAuto  = true;
    // Per-cluster basis (Phase 4 of doc/acen_modo_parity_plan.md).
    // Mirrors ActionCenterPacket.clusterCenters / clusterOf semantics:
    // when `clusterRight.length >= 2` the packet is in multi-cluster
    // mode and tools must use `clusterRight[clusterId]` /
    // `clusterUp[clusterId]` / `clusterFwd[clusterId]`. Cluster ids
    // come from ActionCenterPacket.clusterOf so the two packets stay
    // in lockstep. Lengths match ActionCenterPacket.clusterCenters.
    Vec3[] clusterRight;
    Vec3[] clusterUp;
    Vec3[] clusterFwd;
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

/// Falloff type — published by WGHT stage in phase 7.5. Single active
/// type at a time (no Mix Mode in the MVP). Mirrors MODO's `tool.set
/// falloff.<type> on` selection except we stash the choice on the
/// stage instead of using one tool per type.
enum FalloffType : uint {
    None     = 0,   // 7.5a — packet present but `enabled = false`
    Linear   = 1,   // 7.5b
    Radial   = 2,   // 7.5c
    Screen   = 3,   // 7.5d
    Lasso    = 4,   // 7.5e
    Cylinder = 5,   // Stage 12 — radial-perpendicular-to-axis (xfrm.vortex)
    Element  = 6,   // Stage 14.1 — sphere around picked element centroid (ElementMove)
}

/// Element-falloff connectivity gate (Stage 14.4). Mirrors MODO's
/// `falloff.element` `connect` attr. `Off` disables the gate; any
/// other value restricts the sphere to verts in the same connected
/// component as the picked element. Vertex/Edge/Polygon distinguish
/// the connectivity definition but reduce to the same BFS over
/// mesh.edges for the single-mesh case vibe3d targets today; we
/// keep them separate for forwards-compat with future per-face
/// material partitioning.
enum ElementConnect : ubyte {
    Off      = 0,
    Vertex   = 1,
    Edge     = 2,
    Polygon  = 3,
    Material = 4,
}

/// Element-falloff pick mode (Stage 14.8). Mirrors MODO's interface
/// for `falloff.element` (the `element-mode` enum surfaced in the UI
/// dropdown). Controls TWO axes at once:
///
///   * Type restriction: `auto*` accept vert / edge / face (priority
///     vert → edge → face); `vertex`/`edge`/`polygon` restrict to
///     that single component type regardless of the global edit-mode.
///   * Pivot policy: bare (`auto`, `edge`, `polygon`) put the
///     `pickedCenter` at the cursor's projection onto the picked
///     element; `*Cent` variants put it at the element's geometric
///     centre (vertex pos, edge midpoint, face centroid).
///
/// vibe3d's MVP collapses bare / Cent variants for edge / polygon
/// onto the same centroid (ray-onto-edge / ray-onto-face projection
/// is non-trivial without the cached cursor ray; defer until a user
/// surfaces the need). `auto` and `autoCent` are likewise identical
/// in vibe3d today.
enum ElementMode : ubyte {
    Auto     = 0,
    AutoCent = 1,
    Vertex   = 2,
    Edge     = 3,
    EdgeCent = 4,
    Polygon  = 5,
    PolyCent = 6,
}

/// Per-shape attenuation curve. `t ∈ [0, 1]` is the normalised
/// distance from full-influence to no-influence; the curve maps it
/// to a weight ∈ [0, 1].
///
///   Linear  → 1 - t                    even attenuation
///   EaseIn  → 1 - t²                   stronger near full-influence
///   EaseOut → (1 - t)²                 stronger near zero-influence
///   Smooth  → 1 - smoothstep(t)        S-curve (default)
///   Custom  → cubic Hermite via in_/out_ tangents
enum FalloffShape : ubyte {
    Linear  = 0,
    EaseIn  = 1,
    EaseOut = 2,
    Smooth  = 3,
    Custom  = 4,
}

/// Lasso shape — the "Style" property in MODO's lasso falloff panel.
/// Freehand stores an arbitrary polygon in `lassoPolyX/Y`; the other
/// three styles are 2-corner shapes computed on the fly.
enum LassoStyle : ubyte {
    Freehand  = 0,
    Rectangle = 1,
    Circle    = 2,
    Ellipse   = 3,
}

/// LXsP_TOOL_FALLOFF — soft-selection weight, populated by WGHT stage
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
    // axis = +Y matches MODO's xfrm.vortex preset (axisY=1.0).
    Vec3         normal      = Vec3(0, 1, 0);

    // Element: spherical falloff around `pickedCenter`, radius
    // `pickedRadius`. Mirrors MODO's `falloff.element` (the centre
    // is the centroid of the clicked component; radius = MODO's
    // `dist`/Range attr). Default centre at origin, radius 1.0 —
    // gets relocated by ElementMoveTool's click-to-pick or by the
    // user via `tool.pipe.attr falloff pickedCenter "x,y,z"`.
    Vec3         pickedCenter  = Vec3(0, 0, 0);
    float        pickedRadius  = 1.0f;
    // Element connectivity gate (Stage 14.4). When != Off, the
    // sphere weight is multiplied by 0 for verts that aren't in the
    // same connected component as the picked element (compared via
    // mesh.edges BFS). Mirrors MODO's `falloff.element` `connect`
    // attr: Off / Vertex / Edge / Polygon / Material. We only
    // distinguish Off vs anything-else for now (BFS over mesh.edges
    // covers Vertex / Edge / Polygon equivalently for the
    // single-mesh case; Material partitioning would need per-face
    // material ids which aren't tracked).
    ElementConnect connect    = ElementConnect.Off;
    // Element pick mode (Stage 14.8). ElementMoveTool reads this to
    // restrict which element types LMB-pick will hit and where the
    // pickedCenter lands on the picked element. Default Auto =
    // vert→edge→face priority, centred on the natural pick point.
    ElementMode    elementMode = ElementMode.Auto;
    // BFS-precomputed component mask for the picked element: index
    // into the same vert array, `true` for verts in the component.
    // ElementMoveTool fills it on pick; consumers reading the packet
    // see an empty mask when no pick has happened yet (in that case
    // `elementWeight` falls through to the unrestricted sphere).
    const(bool)[] connectMask;

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
    // Hermite tangents at t=0 (in_) and t=1 (out_). Both ∈ [0, 1].
    float        in_         = 0.5f;
    float        out_        = 0.5f;
}

/// LXsP_TOOL_SYMMETRY — populated by SYMM stage in 7.6. Mirrors MODO's
/// `ILxSymmetryPacket` (LXSDK_661446/include/lxtool.h:526). v1 ships
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

    // MODO's `BaseSide` (lxtool.h:562) — which side of the plane the
    // user last anchored on. Drives the mirror loop's choice of
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

/// Geometry-snap candidate-type bitmask. Multiple types can be enabled
/// simultaneously; the closest screen-pixel candidate across all
/// enabled types wins. Mirrors MODO `snap-element-mode` enum + grid /
/// workplane variants — see doc/snap_plan.md.
enum SnapType : uint {
    None       = 0,
    Vertex     = 1 << 0,   // 7.3a
    Edge       = 1 << 1,   // 7.3b
    EdgeCenter = 1 << 2,   // 7.3b
    Polygon    = 1 << 3,   // 7.3b
    PolyCenter = 1 << 4,   // 7.3b
    Grid       = 1 << 5,   // 7.3c
    Workplane  = 1 << 6,   // 7.3c
}

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
    bool   enabled       = false;     // master on/off (X key)
    uint   enabledTypes  = SnapType.Vertex
                         | SnapType.EdgeCenter
                         | SnapType.PolyCenter
                         | SnapType.Grid;
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
