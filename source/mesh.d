module mesh;

import bindbc.opengl;
import std.math : sqrt;
import std.parallelism : parallel;
import std.range : iota;
import math;
import shader;
import editmode : EditMode;
import mesh_edit_delta : MeshEditTracker, MeshEditScope;
import change_bus : SelDomain;
import mesh_ops.cut : MeshCutOps;
import mesh_ops.bridge : MeshBridgeOps;
import mesh_ops.loop_slice : MeshLoopSliceOps;
import mesh_ops.decimate : MeshDecimateOps;
import mesh_ops.revolve : MeshRevolveOps;
import mesh_ops.cleanup : MeshCleanupOps;
// ---------------------------------------------------------------------------
// Mesh
// ---------------------------------------------------------------------------

/// Face vertex-index list, wrapping the underlying `uint[][]`
/// storage. Stage A of doc/mesh_faces_flat_refactor_plan.md —
/// `alias this` forwards every operation to the inner array, so this
/// commit changes types in declarations only; every read/write/append/
/// foreach call site keeps working unchanged. Later stages (C, D)
/// will replace `_store` with CSR-style flat storage + an explicit
/// API surface.
///
/// **Mutation contract** for stages C+: slices returned by `[fi]`
/// will become read-only views into shared storage and will be
/// invalidated by any FaceList mutator. Today the wrapper is
/// transparent — callers still get a mutable `uint[]`. The audit pass
/// for Stage B is documented in the plan doc.
struct FaceList {
    uint[][] _store;
    alias _store this;

    /// Underlying `uint[][]` view. Stage A's `alias this` covers the
    /// common operator forms (length, [], ~=, foreach), but doesn't
    /// always carry const-ness through templates like
    /// `std.algorithm.map`. Use `.range` for those call sites — Stage
    /// C / D will hold the CSR-backed equivalent stable here.
    inout(uint[][]) range() inout return { return _store; }
}

/// Flat per-mesh surface (a "material"). One face references
/// exactly one Surface by index into `Mesh.surfaces`. Designed to absorb
/// the LWO `SURF` chunk fields verbatim and to act as the compile target
/// for Phase 3+ ShaderTree IR — see `doc/material_groups_plan.md`.
///
/// Fields with explicit defaults render as a neutral grey if a caller
/// reads `Surface()` (the value returned by the defensive-read pattern
/// when `faceMaterial[fi]` points outside `surfaces`).
struct Surface {
    string name           = "Default";
    Vec3   baseColor      = Vec3(0.7f, 0.7f, 0.7f);
    float  diffuseAmount  = 1.0f;    // LWO DIFF
    float  specularAmount = 0.0f;    // LWO SPEC
    float  glossiness     = 0.4f;    // LWO GLOS; roughness ≈ 1 - glossiness
    float  opacity        = 1.0f;    // 1 - LWO TRAN
    // Forward-compat hook: when a ShaderTree compiles to this Surface,
    // points back to the source graph id so subsequent edits don't lose
    // node-graph state. Empty for surfaces sourced directly from LWO or
    // hand-edited.
    string compiledFromTreeId;
}

/// Domain a `MeshMap` channel is attached to — which element array its
/// per-element values run parallel to.
///
///   Point      — one value-tuple per vertex (`data.length == vertices.length * dim`).
///   Edge       — one value-tuple per deduplicated edge (`data.length == edges.length * dim`).
///   PolyVertex — one value-tuple per face-corner (per-loop). The discontinuous
///                per-corner domain (UV seams, per-corner color). Corner `c` of
///                face `fi` is loop index `faceLoop[fi] + c` (CSR layout — see
///                `faceCornerLoop`), so `data.length == loops.length * dim`. The
///                loop index space is rebuilt wholesale by `buildLoops`, so the
///                per-corner values must be RELOCATED across face-mutating edits
///                (not merely length-resized): see the two-mechanism lifecycle on
///                `remapPolyVertexMaps` (arity-preserving) and
///                `rebuildPolyVertexAtFace` (arity-changing).
enum MapDomain {
    Point,
    Edge,
    PolyVertex,
}

/// Conventional name of the per-corner (PolyVertex-domain) UV map. Centralised
/// here so import / export / `.v3d` codec all key on the same literal. v1 scope
/// is a SINGLE UV set under this name; additional sets later are additional named
/// PolyVertex maps ("uv2", …) — the registry already supports N named maps, so
/// nothing here forecloses multi-set.
///
/// This domain is LIVE end-to-end as of the UV-maps milestone: assimp import
/// captures per-corner UV (pre-weld, so seams survive the positional weld), the
/// `.v3d` v4 codec round-trips it losslessly, and assimp export re-splits at UV
/// seams. LWO UV import + export remain pending follow-ups (they require
/// extending the out-of-tree LWO writer dependency; see the `meshMaps` field
/// comment and doc/uv_maps_plan.md Stage 6).
enum string kUvMapName = "uv";

/// Upper bound on radial-sweep ring count (`RevolveParams.count`, after the
/// tool's Count→ring-count translation). Shared by TWO callers: this
/// module's own `revolveProfileEx` kernel-level backstop (its durable
/// defense against a direct/scripted caller — Param `.min()/.max()` hints
/// are UI-only and do not clamp the headless write path) and
/// `tools.alignment.radial_sweep_tool`'s Param `.max()`/`toKernelParams` clamp.
/// Lives here — not in the tool module it originally shipped in — because
/// `mesh.d` is a core module that must not import `tools/*`; this is the
/// one definition both sides read (task 0365 P1 relocation).
enum int MAX_SWEEP_SIDES = 1024;

/// DoS backstops for `bevelEdgesByMask`'s Round Level (`2^L+1` arc points,
/// exponential) and `bevelFacesByMask`'s Segments (`N` linear rings) —
/// shared between the kernel (authoritative, clamps any caller including a
/// direct/scripted one) and the command/tool layer's Param `.max()` hint
/// (shallower, UI/HTTP-only). Same relocation rationale as
/// `MAX_SWEEP_SIDES` above (task 0365 P1) — `mesh.d` must not import
/// `commands/*`/`tools/*`, so this is the one definition both sides read.
enum int MAX_ROUND_LEVEL     = 10;  // 2·10 = 20 arc segments/endpoint
enum int MAX_BEVEL_SEGMENTS  = 64;

/// A generic named, typed per-element float attribute channel — the single
/// reusable home for continuous per-element data (UV, vertex weight, edge
/// crease, vertex color, …) so each such attribute does NOT become a bespoke
/// parallel array on `Mesh`.
///
/// **Layout** is element-major: element `i`'s `dim` components occupy
/// `data[i*dim .. i*dim + dim]`. So a dim-2 UV map stores `[u0,v0, u1,v1, …]`.
/// The invariant `data.length == elementCount(domain) * dim` is maintained in
/// lock-step with topology by the mesh resize path (see `Mesh.resizeMeshMaps`).
///
/// `dim` is the number of float components per element (1 = weight/crease,
/// 2 = UV, 3 = color, …). `name` is the lookup key in the registry and must be
/// unique per mesh.
struct MeshMap {
    string    name;
    ubyte     dim;
    MapDomain domain;
    float[]   data;

    MeshMap dup() const {
        return MeshMap(name, dim, domain, data.dup);
    }
}

/// Half-edge dart: represents the directed edge vert → next(vert) inside one face.
struct Loop {
    uint vert;   // start vertex of this dart
    uint face;   // face this loop belongs to
    uint next;   // index of the next loop in the same face (CCW)
    uint prev;   // index of the previous loop in the same face
    uint twin;   // dart in the adjacent face (reverse direction); ~0u if boundary
}

/// Cache-validity key for a version-keyed cache that lives OUTSIDE the
/// `Mesh` it was built from (e.g. a toolpipe stage's per-drag cluster or
/// selection-weight cache). `mutationVersion` alone is not enough for such a
/// cache: `Mesh` is a value struct whose owning `Layer` can retarget the
/// stage's `mesh_` delegate to a different primary mid-session, and two
/// different `Mesh`es can legitimately carry an equal `mutationVersion`
/// (both default-initialize to 0, or two same-op-count histories collide).
/// Folding `cast(size_t)&m` in — the same address-key convention already
/// used by `visibility_cache.d` / `snap.d` / `bvh_pick.d` — closes that hole:
/// two distinct `Mesh` instances can never satisfy `matches()` for the same
/// key, no matter how their `mutationVersion`s line up. (A cache that is
/// itself co-located ON the `Mesh`, like `vertexAdjacencyCSR` above, needs
/// no such key — the address IS the object.)
struct MeshCacheKey {
    size_t addr   = size_t.max;
    ulong  mutVer = ulong.max;

    bool matches(ref Mesh m) const {
        return addr == cast(size_t)&m && mutVer == m.mutationVersion;
    }
    void stamp(ref Mesh m) {
        addr   = cast(size_t)&m;
        mutVer = m.mutationVersion;
    }
    void invalidate() {
        addr   = size_t.max;
        mutVer = ulong.max;
    }
}

/// Hermite ease-in/ease-out, `3t²-2t³` — the Bridge Twist per-ring blend
/// curve (task 0357, see `Mesh.bridgeTwistedVertex`). `t` is assumed in
/// [0,1]; not clamped since every call site already guarantees that range.
private float smoothstep01(float t) pure nothrow @nogc @safe {
    return t * t * (3.0f - 2.0f * t);
}

/// Per-edge dihedral result, indexed like `Mesh.edges[]`. Returned by
/// `Mesh.computeEdgeSharpness` — the shared sharp-edge test used by both
/// `MeshSmooth.lockSharp` (`commands/mesh/smooth.d`) and the AI support-loop
/// candidate generator (`ai.support_loop_candidates`). Boundary edges (only
/// one adjacent face) are left at `.init` (`interior = false`).
struct EdgeSharpness {
    bool  interior = false;  // false for boundary edges (dihedral undefined)
    float angleDeg = 0.0f;   // dihedral angle between the two adjacent faces
    bool  sharp    = false;  // angleDeg exceeds the threshold passed in
    uint  faceA    = uint.max;
    uint  faceB    = uint.max;
}

struct Mesh {
    Vec3[]    vertices;
    uint[2][] edges;
    // Faces are stored through a FaceList wrapper to enable a staged
    // migration toward flat (CSR-style) storage. See
    // doc/mesh_faces_flat_refactor_plan.md for the multi-commit
    // refactor; this commit (Stage A) introduces only the wrapper
    // type with `alias this` to the underlying `uint[][]`, so every
    // existing read/write/foreach call site keeps working unchanged.
    FaceList faces;

    Loop[]     loops;        // all half-edge loops
    uint[]     faceLoop;     // faceLoop[fi] = index of first loop of face fi
    uint[]     vertLoop;     // vertLoop[vi] = loop starting at vi (anchored to fan start for boundary verts)
    uint[]     loopEdge;     // loopEdge[li] = index in edges[] of the undirected edge for loop li
    uint[ulong] edgeIndexMap; // edgeKey(a,b) → index in edges[]; populated by buildLoops + addEdge
    // P2: CSR-style vertex→edge adjacency scratch for buildLoops's
    // loopEdge fill on the subpatch preview mesh (caller passes
    // `rebuildEdgeIndexMap=false`). For each vertex `u`,
    // edgesAdj[edgesAdjStart[u] .. edgesAdjStart[u+1]] is the list of
    // edge indices incident to u — typically 4-6 entries on quad
    // meshes, which fit in one cache line. Sequential scan over that
    // list beats a binary-search into a 9 MB sorted array for the
    // 786K preview-edge case (random access vs sequential touches the
    // hot cache line once per lookup).
    private size_t[] buildLoopsEdgesAdjStart;
    private uint[]   buildLoopsEdgesAdj;
    private size_t[] buildLoopsEdgesAdjCursor; // scratch during fill

    // Shared CSR vertex→neighbor adjacency (flattened neighbor list + a
    // per-vertex [offset, offset+1] bounds pair). Lazily rebuilt on read
    // whenever `mutationVersion` moves — mirrors the lazy-invalidation
    // discipline the toolpipe stages used to keep as private per-stage
    // copies (`ensureVertexAdjacency` in FalloffStage / ActionCenterStage)
    // before this provider replaced them. Co-locating the cache on `Mesh`
    // itself dissolves the layer-aliasing hazard those copies had: a
    // Mesh-owned cache can never be shared across two different Mesh
    // instances the way a stage-owned cache (keyed only on mutationVersion,
    // silently retargeted to a new primary layer) could.
    // INVARIANT: these slices must never be shared live across a
    // mutating value copy of a Mesh. The rebuild writes in place when the
    // vertex count is unchanged, so a copy that keeps the source's slice
    // headers alive AND matches its version would be corrupted silently.
    // Safe today because every live Mesh copy is source-dies / fresh-local
    // / snapshot-.dup + a mutationVersion bump (which forces a rebuild).
    private ulong    _adjCsrVer = ulong.max;
    private size_t[] _adjCsrOffset;
    private uint[]   _adjCsrNeighbors;

    // Return the CSR vertex→neighbor adjacency for this mesh: `offset` has
    // length `vertices.length + 1`; the neighbors of vertex `v` are
    // `neighbors[offset[v] .. offset[v + 1]]`. Rebuilt only when
    // `mutationVersion` has moved since the last call (or the vertex count
    // changed), so repeated calls within one topology/selection-frozen drag
    // are O(1) after the first. Out-of-range edge endpoints (defensive —
    // should not occur post-buildLoops) are skipped rather than indexing
    // out of bounds.
    void vertexAdjacencyCSR(out const(size_t)[] offset, out const(uint)[] neighbors) {
        const size_t nV = vertices.length;
        if (_adjCsrVer != mutationVersion || _adjCsrOffset.length != nV + 1) {
            // Counting pass → per-vertex degree, then prefix-sum into offsets.
            _adjCsrOffset.length = nV + 1;
            _adjCsrOffset[] = 0;
            foreach (e; edges) {
                if (e[0] >= nV || e[1] >= nV) continue;
                _adjCsrOffset[e[0] + 1]++;
                _adjCsrOffset[e[1] + 1]++;
            }
            foreach (i; 1 .. nV + 1) _adjCsrOffset[i] += _adjCsrOffset[i - 1];
            _adjCsrNeighbors.length = _adjCsrOffset[nV];
            // Fill pass with a temporary cursor per vertex.
            auto cursor = new size_t[](nV);
            foreach (i; 0 .. nV) cursor[i] = _adjCsrOffset[i];
            foreach (e; edges) {
                if (e[0] >= nV || e[1] >= nV) continue;
                _adjCsrNeighbors[cursor[e[0]]++] = e[1];
                _adjCsrNeighbors[cursor[e[1]]++] = e[0];
            }
            _adjCsrVer = mutationVersion;
        }
        offset    = _adjCsrOffset;
        neighbors = _adjCsrNeighbors;
    }

    // --- Per-element marks (single source of truth) ----------------------
    // Bitfield per element folding the per-element flags into one word.
    // These marks arrays are the AUTHORITATIVE storage for per-element
    // selection (and per-face subpatch) state. The `selectedVertices /
    // selectedEdges / selectedFaces / isSubpatch` names below are `@property`
    // read accessors that materialize a fresh `bool[]` view from the matching
    // marks array on demand — they are NOT stored. Lengths are maintained in
    // lock-step with the matching geometry array (vertexMarks↔vertices,
    // edgeMarks↔edges, faceMarks↔faces; faceMarks folds both Select and
    // Subpatch for faces).
    enum Marks : uint {
        Select   = 1 << 0,
        Subpatch = 1 << 1,
        Hide     = 1 << 2, // reserved, unused
        Lock     = 1 << 3, // reserved, unused
    }
    uint[]    vertexMarks;
    uint[]    edgeMarks;
    uint[]    faceMarks;

    // --- Materialized bool[] read views over the marks arrays -------------
    // Back-compat accessors: every external READ site (`mesh.selectedX[i]`,
    // `.length`, `.dup`, `foreach`) keeps compiling unchanged. Each call
    // allocates a fresh `bool[]` snapshot of the relevant mark bit, so these
    // are read-only — a `mesh.selectedX[i] = …` write would mutate a throwaway
    // temporary, which is why all writes go through the setter/helper methods
    // below. `const` so they remain callable from const methods.
    @property bool[] selectedVertices() const {
        auto r = new bool[](vertexMarks.length);
        foreach (i, m; vertexMarks) r[i] = (m & Marks.Select) != 0;
        return r;
    }
    @property bool[] selectedEdges() const {
        auto r = new bool[](edgeMarks.length);
        foreach (i, m; edgeMarks) r[i] = (m & Marks.Select) != 0;
        return r;
    }
    @property bool[] selectedFaces() const {
        auto r = new bool[](faceMarks.length);
        foreach (i, m; faceMarks) r[i] = (m & Marks.Select) != 0;
        return r;
    }
    @property bool[] isSubpatch() const {
        auto r = new bool[](faceMarks.length);
        foreach (i, m; faceMarks) r[i] = (m & Marks.Subpatch) != 0;
        return r;
    }

    // --- Non-allocating scalar accessors ---------------------------------
    // Hot-path counterparts to the materialized `bool[]` views above: a
    // single mark-bit test instead of allocating a whole snapshot array per
    // read. Each bounds-checks internally and returns false when out of
    // range, so they drop straight into the common
    // `if (i >= sel.length || !sel[i])` guard pattern.
    bool isVertexSelected(size_t i) const {
        return i < vertexMarks.length && (vertexMarks[i] & Marks.Select) != 0;
    }
    bool isEdgeSelected(size_t i) const {
        return i < edgeMarks.length && (edgeMarks[i] & Marks.Select) != 0;
    }
    bool isFaceSelected(size_t i) const {
        return i < faceMarks.length && (faceMarks[i] & Marks.Select) != 0;
    }
    bool isFaceSubpatch(size_t i) const {
        return i < faceMarks.length && (faceMarks[i] & Marks.Subpatch) != 0;
    }
    // Non-allocating selection popcounts: scan the Select bit directly over
    // the marks arrays instead of materializing a `bool[]` snapshot to count.
    int countSelectedVertices() const {
        int n = 0;
        foreach (m; vertexMarks) if (m & Marks.Select) n++;
        return n;
    }
    int countSelectedEdges() const {
        int n = 0;
        foreach (m; edgeMarks) if (m & Marks.Select) n++;
        return n;
    }
    int countSelectedFaces() const {
        int n = 0;
        foreach (m; faceMarks) if (m & Marks.Select) n++;
        return n;
    }
    int[]     vertexSelectionOrder;  // 1-based counter; 0 = not manually selected
    int[]     edgeSelectionOrder;    // 1-based counter; 0 = not manually selected
    int[]     faceSelectionOrder;    // 1-based counter; 0 = not manually selected
    int       vertexSelectionOrderCounter;
    int       edgeSelectionOrderCounter;
    int       faceSelectionOrderCounter;
    // Persistent per-face subpatch flag (Tab toggle), stored as the Subpatch
    // bit in `faceMarks` and surfaced via the `isSubpatch` @property above.
    // Faces with the bit set are displayed through a subdivided preview while
    // the cage geometry remains authoritative.

    // Material Groups (LWO-style surfaces). `surfaces[]` is the per-mesh
    // material registry; `faceMaterial[fi]` indexes into it. Both follow
    // the same lazy-resize convention as `isSubpatch` / `selectedFaces`:
    // read sites must defend with `(fi < faceMaterial.length ? ... : 0)`
    // so the default-surface fallback works on freshly-built meshes that
    // never had explicit material assignments. See
    // doc/material_groups_plan.md for the data-model rationale.
    Surface[] surfaces;
    uint[]    faceMaterial;
    uint[]    facePart;     /// per-face "part" id (parallel to faceMaterial; read sites defend fi<len?:0)
    // Monotonic counter bumped on any topology or vertex-position change that
    // invalidates the subpatch preview. Mutators that touch geometry should
    // increment this so cached previews can detect the change.
    ulong     mutationVersion;
    /// Counter for TOPOLOGY-only changes — bumped when faces / edges /
    /// vertices are added or removed, when isSubpatch changes (which
    /// changes subpatch preview output topology), or when a snapshot
    /// restore brings in new geometry. NOT bumped on pure vertex-
    /// position writes (move drag, undo of move, etc.) — that's what
    /// `mutationVersion` is for. Callers that cache topology-derived
    /// data (e.g. SubpatchPreview's per-level adjacency) compare this
    /// to know whether the cache is still valid, vs. just refreshing
    /// positions.
    ulong     topologyVersion;

    /// Connectivity (edge/face structure) sub-version. Bumped ONLY by the
    /// edge/face structural primitives (addEdge/addFace/addFaceFast/
    /// rebuildEdgesFromFaces, and transitively rebuildEdges). NOT bumped by
    /// vertex-add/position/marks/isSubpatch changes. The loops family
    /// (loops/faceLoop/vertLoop/loopEdge) and edgeIndexMap are functions of
    /// this, so their validity stamps compare against it — NOT
    /// topologyVersion, which conflates Points|Polygons and would falsely
    /// invalidate on a Points-only change (e.g. a bare addVertex). Orthogonal
    /// to commitChange — commitChange never touches it, so there is no
    /// build-before-commit ordering hazard and no ride-along pending flag:
    /// buildLoops stamps `loopsStamp = structVersion` directly, and nothing
    /// re-bumps structVersion until the next real structural mutation.
    ulong     structVersion;

    /// Validity state for a structVersion-derived structure (the loops
    /// family or edgeIndexMap). `Stale` = built for an older structVersion,
    /// or never built at all (the fresh-`Mesh.init` case — the state starts
    /// `Stale` so a never-built mesh does not read as valid by the `0==0`
    /// coincidence). `Valid` = built for the current structVersion.
    /// `DeliberatelyEmpty` = intentionally left empty by a caller that knows
    /// it will not be read through the loops helpers (e.g. a subpatch
    /// preview mesh whose consumers only read vertices/edges/faces) —
    /// distinct from `Stale` so a future assert can tell "forgot to rebuild"
    /// from "deliberately skipped".
    enum DerivedState : ubyte { Stale, Valid, DeliberatelyEmpty }
    private ulong loopsStamp;    // structVersion the loops family was built for
    private ulong edgeMapStamp;  // structVersion edgeIndexMap was built for
    private DerivedState loopsState_   = DerivedState.Stale;
    private DerivedState edgeMapState_ = DerivedState.Stale;

    /// O(1): true iff the loops family (loops/faceLoop/vertLoop/loopEdge)
    /// was built for the CURRENT structVersion.
    bool loopsValid() const {
        return loopsState_ == DerivedState.Valid && loopsStamp == structVersion;
    }
    /// O(1): true iff edgeIndexMap is populated AND in sync with the current
    /// structVersion (false while deliberately deferred — e.g. between
    /// addFaceFast calls and the caller's terminal buildLoops()).
    bool edgeMapUsable() const {
        return edgeMapState_ == DerivedState.Valid && edgeMapStamp == structVersion;
    }
    /// Explicitly mark the loops family + edgeIndexMap DeliberatelyEmpty —
    /// for meshes (e.g. subpatch preview output) whose consumers never read
    /// through the loops helpers, so a stray reader sees an explicit
    /// "not built, on purpose" state rather than stale data from a previous
    /// rebuild. Keeps the state fields `private` while giving external
    /// modules an intent-named way to record the contract.
    void markDerivedEmpty() {
        loopsState_   = DerivedState.DeliberatelyEmpty;
        edgeMapState_ = DerivedState.DeliberatelyEmpty;
    }
    /// Debug-only (stripped from release builds — byte-stable): assert the
    /// loops family is valid at a provably-settled read entry point. See
    /// call sites for the settledness proof; never place in a mid-op reader.
    pragma(inline, true) void assertLoopsValid() const {
        debug assert(loopsValid(),
            "loops family read while stale — a topology mutator skipped buildLoops()");
    }
    /// Debug-only (stripped from release builds — byte-stable): assert
    /// edgeIndexMap is valid at a provably-settled read entry point.
    pragma(inline, true) void assertEdgeMapValid() const {
        debug assert(edgeMapUsable(),
            "edgeIndexMap read while stale/empty — a topology mutator skipped rebuildEdges()/buildLoops()");
    }

    // --- Change-notification accumulation (doc/change_notification_bus_plan) -
    // OR-accumulated change-class flags (MeshEditScope bits) and selection
    // domains (change_bus.SelDomain bits) since the last per-frame flush. The
    // main loop drains these into changeBus.flush(...) once per frame and then
    // zeroes them. Pending state lives HERE (not on the bus) so that, when the
    // layer/document model lands, each Layer.mesh can accumulate independently.
    // Stage 0: populated by commitChange() at the converted version-bump sites;
    // no subscribers consume it yet.
    uint      pendingChanges_;     // MeshEditScope bits
    uint      pendingSelDomains_;  // change_bus.SelDomain bits

    // Accumulate-only: OR the given MeshEditScope flags into the pending set.
    // Does NOT bump the version counters, so it is safe inside loops and safe
    // mid-drag (where the intentional version-stability invariant must hold).
    void noteChange(uint flags) {
        pendingChanges_ |= flags;
    }

    // Accumulate + bump the version counters, reproducing EXACTLY the existing
    // bump behaviour: mutationVersion always advances; topologyVersion advances
    // only when the change carries a Geometry class (Points | Polygons). This
    // is the drop-in replacement for the raw `++mutationVersion;
    // ++topologyVersion;` lines at the internal mutation sites.
    void commitChange(uint flags) {
        noteChange(flags);
        ++mutationVersion;
        if (flags & MeshEditScope.Geometry) ++topologyVersion;
    }

    // Accumulate a SELECTION change (Stage 5): OR `Marks` into the mesh-class
    // pending set AND the given selection-domain bit into pendingSelDomains_.
    // Deliberately does NOT bump mutationVersion — selection is a Marks-class
    // change, not a version-bumping geometry change, and the marks setters have
    // always been version-stable (a property other systems rely on; e.g. the
    // pick-cache geometry key and mid-drag version stability must not move when
    // only the highlight changes). Safe inside loops (pure OR) — the bulk
    // lasso/paint setters call it once after a compare-before-set guard so a
    // no-op restore does not spuriously publish.
    void noteSelectionChange(SelDomain domain) {
        pendingChanges_     |= MeshEditScope.Marks;
        pendingSelDomains_  |= cast(uint)domain;
    }

    // --- Mesh maps (generic per-element float attribute channels) ----------
    // Named, typed per-element float channels (UV, vertex weight, edge crease,
    // vertex color, …). ONE reusable home so each new continuous per-element
    // attribute does not become a bespoke parallel array. Each `MeshMap`'s
    // `data` runs parallel to the element array named by its `domain` (Point ↔
    // vertices, Edge ↔ edges, PolyVertex ↔ loops/face-corners) and is kept
    // length-correct in lock-step with topology by `resizeMeshMaps` (Point/Edge,
    // hooked into `resizeVertexSelection` / `resizeEdgeSelection`) and
    // `resizePolyVertexMaps` (PolyVertex, hooked into `buildLoops`).
    //
    // Point/Edge maps are RESIZED (not value-remapped) across destructive edits
    // that renumber those elements: length stays correct so reads never go out
    // of bounds, but values do not follow elements to new indices.
    //
    // PolyVertex (per-corner) UV is now LIVE end-to-end: assimp import populates
    // the "uv" map (per-corner, captured pre-weld so seams survive), the `.v3d`
    // v4 codec round-trips it, and assimp export re-splits at UV seams. v1 scope
    // is a SINGLE UV set (kUvMapName == "uv"); the registry already supports N
    // named PolyVertex maps, so multi-set is a later additive change. LWO UV
    // import + export are pending follow-ups (they need the out-of-tree LWO
    // writer dependency to learn VMAP/VMAD UV channels — see doc/uv_maps_plan.md
    // Stage 6); LWO geometry imports/exports today WITHOUT its UV.
    //
    // PolyVertex (per-corner) maps additionally have a value-RELOCATE lifecycle
    // — corner identity is not positional, so the per-corner values are made to
    // follow their corners across face-mutating edits via two mechanisms:
    //   (a) arity-PRESERVING relocate funnel `remapPolyVertexMaps` — wired in
    //       `deleteFacesByMask`; `compactUnreferenced` preserves face order +
    //       arity so it is identity-on-corners (no relocation needed).
    //   (b) arity-CHANGING per-face rewrite (build `oldLoopOfNewLoop` at the
    //       rewrite site, then call the same funnel) — wired in
    //       `dissolveVerticesByMask`, `weldCoincidentVertices` (which does NOT
    //       call buildLoops), and `removeEdgesByMask`/edge-dissolve-merge. The
    //       short-edge-weld callers ride `weldCoincidentVertices`.
    //   append — `addFace`/`addFaceFast` grow+zero-fill the new corners
    //       ATOMICALLY (GAP-3, no element-count window).
    //   snapshot restore — values come back via the captured map `dup`.
    // v1 DROP set (write-once-then-lose tail — length-correct resize, values
    // ZEROED, a documented limitation, each covered by a "dropped, no crash"
    // test): subdivide (Catmull-Clark UV interpolation is a non-goal), every
    // primitive factory rebuild, `extrudeEdgesByMask`, edge-extend, bridge,
    // subpatch cage build, and any future bevel-family op. These end in
    // `buildLoops`, so `resizePolyVertexMaps` makes them length-correct + zeroed.
    // (See doc/uv_maps_plan.md D5 for the full per-mutator classification.)
    //
    // Discrete polygon tags (`faceMaterial`, a per-face surface INDEX) are
    // deliberately NOT mesh maps: a float channel cannot represent an integer
    // surface id without precision/semantic abuse, so `faceMaterial` stays its
    // own `uint[]`. Mesh maps are for CONTINUOUS float attributes only.
    MeshMap[] meshMaps;

    // --- Mesh-edit change tracker (mesh_edit_delta) -----------------------
    // Nullable recorder. NULL unless an edit batch is open (the common case —
    // it is opened only around a committed topology op, never per drag frame).
    // While non-null, the hooked mutation primitives (addVertex, addFace,
    // compactUnreferenced, deleteFacesByMask, dissolveVerticesByMask,
    // removeEdgesByMask, extrudeEdgesByMask, …) append an operation-log entry.
    // Every hook's FIRST line is
    // `if (editRecorder_ is null) return;` — a single predictable branch — so
    // when no batch is open (always, in Phase 1) the tracker adds zero cost and
    // every existing behavior is byte-for-byte unchanged. See
    // doc/undo_change_tracker_plan.md.
    private MeshEditTracker* editRecorder_;

    // Open an edit batch: install the recorder so the mutation hooks start
    // logging. `declared` is the advisory change scope. The pointer must
    // out-live the batch (callers stack-allocate a MeshEditTracker and pass its
    // address, then call endEditBatch before it leaves scope).
    void beginEditBatch(MeshEditTracker* rec, MeshEditScope declared) {
        editRecorder_ = rec;
        if (rec !is null) rec.declare(declared);
    }

    // Close the batch and return the finished, invertible delta. Detaches the
    // recorder so subsequent mutations are untracked again.
    import mesh_edit_delta : MeshEditDelta;
    MeshEditDelta endEditBatch() {
        MeshEditDelta d;
        if (editRecorder_ !is null) {
            d = editRecorder_.finish();
            editRecorder_ = null;
        }
        return d;
    }

    // True while a batch is open (test/introspection helper).
    bool isRecordingEdits() const { return editRecorder_ !is null; }

    // Resize selection arrays to match geometry and clear them.
    // Call after catmullClark / importLWO / reset.
    //
    // Deliberately does NOT clear subpatch (task 0389): this is a
    // SELECTION reset, not a subpatch reset — a topology-editing command
    // that rebuilds `faces` and then calls resetSelection() to re-sync the
    // selection arrays should not, as a side effect, revert every
    // untouched face back to plain polygons. Callers that DO want the
    // result to start non-subpatch (e.g. subdivide's Catmull-Clark bake,
    // which deliberately extinguishes the flag on its baked geometry) call
    // `clearSubpatch()` explicitly at their own call site.
    void resetSelection() {
        resizeVertexSelection();
        resizeEdgeSelection();
        resizeFaceSelection();
        // resizeFaceSelection only touches the bit array; resetSelection also
        // brings the per-face pick-order / subpatch / material arrays in sync
        // (e.g. after an import grew `faces`). resizeSubpatch is grow/shrink
        // ONLY (zero-fill on grow) — it does not clear pre-existing bits.
        faceSelectionOrder.length   = faces.length;
        resizeSubpatch();
        faceMaterial.length         = faces.length;
        facePart.length             = faces.length;
        clearVertexSelection();
        clearEdgeSelection();
        clearFaceSelection();
        // NOTE: do not wipe `faceMaterial`. resetSelection is also called
        // after LWO import to bring selection arrays in sync with the
        // imported geometry; the import populates `faceMaterial` before
        // calling us, and zeroing it here would undo that work. New
        // entries default to 0 (Default surface) which is the same
        // result the existing growth-and-don't-clear semantics gives
        // for `isSubpatch` after a non-importing geometry growth.
        // Geometry-class: array lengths re-sync to the (possibly new) geometry
        // and selection marks are cleared. Bumps both counters as before.
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
    }

    // Grow selection arrays to match geometry without clearing.
    // Call after BoxTool or any in-place geometry growth.
    void syncSelection() {
        if (selectedVertices.length < vertices.length) resizeVertexSelection();
        if (selectedEdges.length    < edges.length)    resizeEdgeSelection();
        if (selectedFaces.length    < faces.length)    resizeFaceSelection();
        if (vertexSelectionOrder.length < vertices.length) vertexSelectionOrder.length = vertices.length;
        if (edgeSelectionOrder.length   < edges.length)    edgeSelectionOrder.length   = edges.length;
        if (faceSelectionOrder.length   < faces.length)    faceSelectionOrder.length   = faces.length;
        if (isSubpatch.length           < faces.length)    resizeSubpatch();
        if (faceMaterial.length         < faces.length)    faceMaterial.length         = faces.length;
        if (facePart.length             < faces.length)    facePart.length             = faces.length;
    }

    // Rebuild the deduplicated `edges` array from the current `faces`.
    // Call after any topology op that adds/removes faces (poly bevel, edge
    // bevel) so the edge list stays in sync. Selection arrays are resized
    // afterward via syncSelection.
    void rebuildEdgesFromFaces() {
        edges = [];
        bool[ulong] seen;
        foreach (face; faces) {
            foreach (i, _; face) {
                uint u = face[i];
                uint w = face[(i + 1) % face.length];
                ulong key = edgeKey(u, w);
                if (key !in seen) {
                    seen[key] = true;
                    edges ~= [u, w];
                }
            }
        }
        // Structural change: `edges` reassigned directly (no addEdge), so
        // bump once. Contract preserved: edgeIndexMap is intentionally left
        // untouched by this function (see doc comment above) — mark it
        // Stale rather than re-stamping it Valid. Loops are untouched too;
        // loopsState_/loopsStamp are left as-is (stale relative to the new
        // structVersion).
        ++structVersion;
        edgeMapState_ = DerivedState.Stale;
    }

    uint addVertex(Vec3 v) {
        vertices ~= v;
        // Points-class: one vertex added. Bumps both counters (Points is a
        // Geometry bit) exactly as the raw double-bump did.
        commitChange(MeshEditScope.Points);
        const idx = cast(uint)(vertices.length - 1);
        // Class P tracker hook — inert unless a batch is open.
        if (editRecorder_ !is null) editRecorder_.recordAddVert(idx, v);
        return idx;
    }

    /// True once a weld/merge/reduce pass has left the mesh with no
    /// vertices or no faces. The `weldVerticesByMask` family
    /// (`weldVertexPair`, `reduce`, and `mirrorFacesPlane`'s weld pass) can
    /// all cascade to this on an aggressive enough input/threshold and,
    /// left unchecked, would report `status: ok` over a silently-emptied
    /// document (task 0306). A pure query, not a rollback mechanism —
    /// callers decide whether to revert to a pre-pass snapshot or fail
    /// outright. `mirrorFacesPlane` is the first wired-up caller; task 0309
    /// reuses this same predicate for EdgeSliceTool's guard.
    bool isEmpty() const {
        return vertices.length == 0 || faces.length == 0;
    }

    /// Merge coincident vertices (within `epsSq` squared distance) by
    /// remapping each later-indexed coincident vert onto the lowest-indexed
    /// vert at that position. Face vertex references are rewritten;
    /// consecutive duplicates that arise post-remap are dropped (so a quad
    /// whose two adjacent corners merged becomes a triangle); faces that
    /// fall below 3 distinct verts are removed entirely. The edge array is
    /// rebuilt; edge selection is cleared. Welded vertices are left in
    /// `vertices` (call `compactUnreferenced` afterwards to compact).
    /// Returns the number of vertex remaps performed.
    /// Used by edge bevel after `updateEdgeBevelPositions` to fold cap
    /// vertices that two BoundVerts (in possibly different BevVerts)
    /// happen to slide onto the same world-space point — the natural
    /// outcome when re-beveling on top of an already-overshot cap.
    /// Weld vertices marked true in `mask` whose pairwise squared distance
    /// is at most `epsSq` (inclusive boundary — see task 0360 toolcard
    /// evidence below). Verts outside the mask are not candidates for
    /// either side of a weld pair. Faces that collapse to fewer than 3
    /// unique verts are dropped (degenerate). Edge list rebuilt; selection
    /// arrays cleared. Returns the number of verts welded into another.
    ///
    /// Equivalent to `vert.merge range:fixed dist:eps keep:false` on
    /// the selected verts. epsSq=1e-12 + all-true mask matches the
    /// existing weldCoincidentVertices() behavior (used by edge bevel).
    ///
    /// Boundary law (task 0360, captured toolcard): the reference weld
    /// threshold is CONFIRMED inclusive (`<=`, not `<`) — a discriminating
    /// capture on a segments=2 grid cube (edge length 0.5) found NO merge
    /// at dist=0.49 but a mass collapse at dist=0.5 (exactly the edge
    /// length). This kernel used to compare with strict `<`, which missed
    /// that exact-equality boundary case entirely (verified independently
    /// this task: re-simulating the pre-fix `<` comparison against the
    /// captured base geometry at dist=0.5 produced ZERO merges, vs the
    /// captured reference's real collapse) — fixed to `<=` here.
    ///
    /// Open TODO (not resolved this task, do not assume a fix): the
    /// reference's full-mesh, dist-at-exact-boundary case also implies a
    /// TRANSITIVE/connected-component clustering algorithm (a chain of
    /// vertices each within `dist` of the next all merge to one cluster,
    /// even where the endpoints of the chain are individually farther
    /// apart than `dist`). This kernel's algorithm is a single left-to-
    /// right PAIRWISE pass (each vertex is only ever compared against
    /// vertices with a LOWER, not-yet-remapped index, using each vertex's
    /// ORIGINAL position — not a full graph-transitive-closure and not an
    /// iterative re-centering pass). Independently re-deriving the
    /// reference's exact clustering algorithm from the captured whole-mesh
    /// case (task 0360) found that NEITHER this pairwise algorithm NOR a
    /// naive full pairwise-Euclidean transitive closure reproduces the
    /// reference's exact cluster count on that case — the reference's real
    /// clustering/placement rule remains uncharacterized. Left as-is
    /// (existing, well-tested pairwise behavior) rather than guessed; the
    /// interactive Vertex Merge tool and its fixtures (task 0360) only
    /// exercise the CONFIRMED boundary law on isolated pairs, not the
    /// disputed whole-mesh transitive case.
    size_t weldVerticesByMask(in bool[] mask, double epsSq) {
        if (vertices.length < 2) return 0;
        if (mask.length != vertices.length) return 0;
        int[] remap;
        remap.length = vertices.length;
        foreach (i; 0 .. vertices.length) remap[i] = cast(int)i;
        foreach (i; 0 .. vertices.length) {
            if (!mask[i]) continue;
            if (remap[i] != cast(int)i) continue;
            foreach (j; i + 1 .. vertices.length) {
                if (!mask[j]) continue;
                if (remap[j] != cast(int)j) continue;
                Vec3 d = vertices[i] - vertices[j];
                if (d.x * d.x + d.y * d.y + d.z * d.z <= epsSq)
                    remap[j] = cast(int)i;
            }
        }
        size_t welded = 0;
        foreach (i; 0 .. vertices.length)
            if (remap[i] != cast(int)i) ++welded;
        if (welded == 0) return 0;

        uint[][] newFaces;
        bool[]   newSubpatch;
        int[]    newOrder;
        uint[]   newMaterial;
        uint[]   newPart;
        newFaces.reserve(faces.length);
        foreach (fi, ref face; faces) {
            uint[] f;
            f.reserve(face.length);
            foreach (vid; face) {
                uint mapped = (vid < remap.length) ? cast(uint)remap[vid] : vid;
                if (f.length == 0 || f[$ - 1] != mapped) f ~= mapped;
            }
            if (f.length > 1 && f[$ - 1] == f[0]) f = f[0 .. $ - 1];
            if (f.length >= 3) {
                newFaces    ~= f;
                newSubpatch ~= isFaceSubpatch(fi);
                newOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
                newMaterial ~= (fi < faceMaterial.length      ? faceMaterial[fi]      : 0u);
                newPart     ~= (fi < facePart.length          ? facePart[fi]          : 0u);
            }
        }
        faces              = newFaces;
        setFaceSubpatchFrom(newSubpatch);
        faceSelectionOrder = newOrder;
        faceMaterial       = newMaterial;
        facePart           = newPart;
        clearFaceSelectionResize();

        rebuildEdges();
        clearEdgeSelectionResize();
        compactUnreferenced();
        // See deleteFacesByMask: loops carry stale indices after face/vert
        // compaction.
        buildLoops();
        // Geometry-class: faces rewritten, edges + loops rebuilt.
        commitChange(MeshEditScope.Geometry);
        return welded;
    }

    /// Weld vertex `drop` into vertex `keep`. `drop`'s incident faces are
    /// rewritten to reference `keep`; `drop` is then removed; the surviving
    /// vertex sits at `keep`'s position (target-position rule: snap source→target).
    /// Reuses weldVerticesByMask — snaps the two coincident, then mask-welds.
    ///
    /// Shared-face rule (adjacency-aware):
    ///  - ADJACENT same-face welds (keep & drop are consecutive corners in a face,
    ///    including the head/tail wrap) are ALLOWED: weldVerticesByMask collapses
    ///    the repeated adjacent corner cleanly, yielding a triangle. This is the
    ///    standard edge-collapse case and is handled correctly by the kernel.
    ///  - NON-ADJACENT same-face welds (keep & drop both appear in a face but are
    ///    NOT consecutive) are REJECTED: they would leave [keep,A,keep,B] — a
    ///    self-touching polygon that the kernel cannot collapse cleanly.
    ///  - Two FACELESS verts cannot be welded: with no incident face,
    ///    compactUnreferenced removes both as unreferenced (net vanish). If
    ///    NEITHER keep NOR drop is referenced by any face, returns 0 (no-op).
    ///    (If only one is faceless the other's faces absorb the merge normally.)
    /// Returns 1 on success, 0 on no-op (same index / OOB / non-adjacent same-face /
    /// both-faceless).
    size_t weldVertexPair(uint keep, uint drop) {
        if (keep == drop) return 0;
        if (keep >= vertices.length || drop >= vertices.length) return 0;
        // Shared-face adjacency guard + faceless check (one pass over faces).
        // Adjacent same-face welds (consecutive corners including head/tail wrap)
        // are ALLOWED: weldVerticesByMask strips the repeated adjacent corner to
        // produce a clean triangle.  Non-adjacent same-face welds would leave
        // [keep,A,keep,B] — a self-touching polygon — and are REJECTED.
        bool keepRef = false, dropRef = false;
        foreach (ref face; faces) {
            int posKeep = -1, posDrop = -1;
            foreach (i, vid; face) {
                if (vid == keep) { posKeep = cast(int)i; keepRef = true; }
                if (vid == drop) { posDrop = cast(int)i; dropRef = true; }
            }
            if (posKeep >= 0 && posDrop >= 0) {
                // Both vertices appear in this face — check adjacency.
                int diff = posKeep > posDrop ? posKeep - posDrop : posDrop - posKeep;
                bool adjacent = (diff == 1) || (diff == cast(int)face.length - 1);
                if (!adjacent) return 0;  // non-adjacent same-face: reject
            }
        }
        // Faceless guard: both unreferenced → compactUnreferenced would remove
        // both as orphans, giving a net vanish rather than a weld.
        if (!keepRef && !dropRef) return 0;
        // Snap drop to keep's position so weldVerticesByMask treats them as
        // coincident. The surviving index is min(keep,drop); the surviving
        // position is keep's (both positions are identical at this point).
        vertices[drop] = vertices[keep];
        bool[] mask;
        mask.length = vertices.length;
        mask[keep] = true;
        mask[drop] = true;
        return weldVerticesByMask(mask, 1e-12);
    }

    /// Inverse of weldVerticesByMask: unweld each masked vertex so every
    /// incident face gets its own coincident copy. The vertex is kept in
    /// its lowest-indexed incident face; every later incident face (in
    /// face-index order) gets a fresh addVertex(pos) and its corner
    /// rewritten. Returns the number of copies created.
    ///
    /// Granularity: one copy per incident face (v1). Per-fan grouping
    /// (splitting only at topological seams on non-manifold vertices) is
    /// a documented non-goal for v1.
    ///
    /// Point-domain MeshMap values (e.g. weight maps) are propagated to
    /// every coincident copy in the tail, AFTER resizeVertexSelection()
    /// has grown and zero-filled the new map rows. Copying map values
    /// inside the corner loop would be OOB once any weight map exists
    /// (addVertex does not resize MeshMap data). PolyVertex maps are
    /// untouched: the op preserves face/corner count and order, so
    /// loop-indexed UV values relocate correctly through buildLoops.
    size_t splitVerticesByMask(in bool[] mask) {
        if (mask.length != vertices.length) return 0;

        // Per-vertex "first incident face already claimed" flag.
        bool[] claimed;
        claimed.length = vertices.length;

        // Deferred (src, dst) pairs for Point-map value propagation.
        // MUST NOT copy map values here: addVertex appends to vertices[]
        // but does NOT resize MeshMap.data — writing data[nv*dim..] would
        // be OOB the instant any weight map is registered. The copy
        // happens in the tail, after resizeVertexSelection() below.
        uint[2][] copyPairs;
        size_t copies = 0;

        foreach (fi; 0 .. faces.length) {
            foreach (ref corner; faces[fi]) {
                const uint v = corner;
                if (v >= mask.length || !mask[v]) continue;
                if (!claimed[v]) {
                    claimed[v] = true;  // first incident face keeps original
                    continue;
                }
                // Later incident face: add a coincident copy and rewrite corner.
                const Vec3 p = vertices[v];  // read position before addVertex
                const uint nv = addVertex(p);
                corner = nv;
                copyPairs ~= [v, nv];
                ++copies;
            }
        }

        if (copies == 0) return 0;

        rebuildEdges();
        // Grow vertexMarks, vertexSelectionOrder, and Point-domain MeshMap
        // data arrays to cover the newly appended vertices (zero-filled).
        resizeVertexSelection();

        // Propagate Point-domain map values from source to each copy.
        // Runs AFTER resizeVertexSelection() — the destination rows exist
        // only once the resize above has extended data[].
        foreach (ref m; meshMaps) {
            if (m.domain != MapDomain.Point) continue;
            const ubyte d = m.dim;
            foreach (pair; copyPairs) {
                const size_t src = pair[0] * d;
                const size_t dst = pair[1] * d;
                m.data[dst .. dst + d] = m.data[src .. src + d];
            }
        }

        buildLoops();
        commitChange(MeshEditScope.Geometry);
        return copies;
    }

    /// Move every vertex marked true in `mask` to `target`. No welding
    /// happens here; the verts merely coincide in space. Combine with
    /// weldVerticesByMask() to collapse them into one. Used by
    /// `vert.join` (set target = centroid or first-selected) before the
    /// weld pass.
    void collapseVerticesByMask(in bool[] mask, Vec3 target) {
        if (mask.length != vertices.length) return;
        bool any = false;
        foreach (i; 0 .. mask.length) {
            if (!mask[i]) continue;
            vertices[i] = target;
            any = true;
        }
        // Positions only move here, but the original double-bumped BOTH
        // counters; preserve that EXACTLY by carrying a Geometry bit so
        // commitChange still advances topologyVersion. (Semantic class is
        // Position; the Geometry bit exists solely to reproduce the prior
        // topology bump — see plan Stage 0 step 2.)
        if (any) commitChange(MeshEditScope.Position | MeshEditScope.Geometry);
    }

    /// Collapse each connected island of selected edges to a single point
    /// (the centroid of the island's endpoint set — a single selected edge
    /// collapses to its two-endpoint midpoint). Each island is processed
    /// with a pass-1 `collapseVerticesByMask` (move only, no compaction),
    /// then a single `weldVerticesByMask` over the union of all
    /// selected-edge vertices. The move-all-then-weld-once order is
    /// essential: per-island welding would compact after each island and
    /// stale the remaining islands' index masks.
    /// Returns the number of vertices welded; 0 means nothing changed.
    size_t collapseEdgesByMask(in bool[] edgeMask) {
        if (edgeMask.length != edges.length) return 0;

        // Union-find over vertex indices: vertices connected through a
        // chain of selected edges share an island.
        int[] parent;
        parent.length = vertices.length;
        foreach (i; 0 .. vertices.length) parent[i] = cast(int)i;

        int findRoot(int x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void unite(int a, int b) {
            a = findRoot(a); b = findRoot(b);
            if (a != b) parent[b] = a;
        }

        // Mark selected-edge verts and build connectivity.
        bool[] inSelection;
        inSelection.length = vertices.length;
        bool anySelected = false;
        foreach (i; 0 .. edges.length) {
            if (!edgeMask[i]) continue;
            uint a = edges[i][0], b = edges[i][1];
            if (a >= vertices.length || b >= vertices.length) continue;
            inSelection[a] = true;
            inSelection[b] = true;
            unite(cast(int)a, cast(int)b);
            anySelected = true;
        }
        if (!anySelected) return 0;

        // Accumulate per-island centroid (root → sum / count).
        Vec3[int] islandSum;
        int[int]  islandCount;
        foreach (vi; 0 .. vertices.length) {
            if (!inSelection[vi]) continue;
            int root = findRoot(cast(int)vi);
            if (root in islandSum) {
                islandSum[root] = islandSum[root] + vertices[vi];
                ++islandCount[root];
            } else {
                islandSum[root]   = vertices[vi];
                islandCount[root] = 1;
            }
        }

        // Pass 1 — move every island's verts to its centroid (no compaction).
        foreach (root, cnt; islandCount) {
            Vec3 s = islandSum[root];
            Vec3 centroid = Vec3(s.x / cnt, s.y / cnt, s.z / cnt);
            bool[] islandMask;
            islandMask.length = vertices.length;
            foreach (vi; 0 .. vertices.length) {
                if (inSelection[vi] && findRoot(cast(int)vi) == root)
                    islandMask[vi] = true;
            }
            collapseVerticesByMask(islandMask, centroid);
        }

        // Pass 2 — one weld over the union of all selected-edge verts.
        // epsSq = 1e-12: welds only exactly-coincident verts (collapse
        // set exact equality); distinct island centroids cannot cross-weld.
        return weldVerticesByMask(inSelection, 1e-12);
    }

    /// Collapse each connected island of selected faces to a single point
    /// (the centroid of the island's corner vertices). Two selected faces
    /// sharing any vertex are in the same island. Uses the same
    /// move-all-then-weld-once structure as `collapseEdgesByMask`.
    /// Returns the number of vertices welded; 0 means nothing changed.
    size_t collapseFacesByMask(in bool[] faceMask) {
        if (faceMask.length != faces.length) return 0;

        bool anySelected = false;
        foreach (b; faceMask) if (b) { anySelected = true; break; }
        if (!anySelected) return 0;

        // Union-find over face indices: two selected faces sharing a vertex
        // belong to the same island.
        int[] parent;
        parent.length = faces.length;
        foreach (i; 0 .. faces.length) parent[i] = cast(int)i;

        int findRoot(int x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void unite(int a, int b) {
            a = findRoot(a); b = findRoot(b);
            if (a != b) parent[b] = a;
        }

        // Map each vertex to the first selected face that contains it.
        // When a second selected face shares that vertex, unite the two faces.
        int[] vertToFace;
        vertToFace.length = vertices.length;
        vertToFace[] = -1;
        foreach (fi; 0 .. faces.length) {
            if (!faceMask[fi]) continue;
            foreach (v; faces[fi]) {
                if (v >= vertices.length) continue;
                if (vertToFace[v] == -1)
                    vertToFace[v] = cast(int)fi;
                else
                    unite(cast(int)fi, vertToFace[v]);
            }
        }

        // Collect all verts touched by selected faces.
        bool[] inSelection;
        inSelection.length = vertices.length;
        foreach (i; 0 .. vertices.length)
            if (vertToFace[i] >= 0) inSelection[i] = true;

        // Accumulate per-island centroid (face-root → sum / count).
        Vec3[int] islandSum;
        int[int]  islandCount;
        foreach (vi; 0 .. vertices.length) {
            if (!inSelection[vi]) continue;
            int root = findRoot(vertToFace[vi]);
            if (root in islandSum) {
                islandSum[root] = islandSum[root] + vertices[vi];
                ++islandCount[root];
            } else {
                islandSum[root]   = vertices[vi];
                islandCount[root] = 1;
            }
        }

        // Pass 1 — move every island's verts to its centroid (no compaction).
        foreach (root, cnt; islandCount) {
            Vec3 s = islandSum[root];
            Vec3 centroid = Vec3(s.x / cnt, s.y / cnt, s.z / cnt);
            bool[] islandMask;
            islandMask.length = vertices.length;
            foreach (vi; 0 .. vertices.length) {
                if (inSelection[vi] && findRoot(vertToFace[vi]) == root)
                    islandMask[vi] = true;
            }
            collapseVerticesByMask(islandMask, centroid);
        }

        // Pass 2 — one weld over the union of all selected-face verts.
        return weldVerticesByMask(inSelection, 1e-12);
    }

    /// Return a bool mask (indexed by vertex index) marking every vertex in
    /// the CONNECTED COMPONENT (island) reachable from face `faceIndex` —
    /// i.e. the transitive closure of "shares a face with" over every face
    /// in the mesh. Two faces are unioned whenever they share ANY vertex; a
    /// face's own corners are unioned to each other first so a face is
    /// always wholly inside one island even before any cross-face union
    /// happens. Same union-find shape as `collapseEdgesByMask`
    /// (mesh.d:877) / `collapseFacesByMask` (mesh.d:956) — parent[] +
    /// findRoot + unite — but this walks EVERY face in the mesh (not just a
    /// masked subset), since island membership isn't selection-driven here.
    ///
    /// Used by TackTool's moving-set rule (task 0126, capture-verified):
    /// a rigid polygon-align moves the picked polygon "and all connected
    /// vertices" — the whole geometric island the picked face belongs to,
    /// not just its own 4 corners and not the whole mesh. On a mesh built
    /// from disjoint parts (e.g. two separate cubes), this returns exactly
    /// the picked cube's 8 vertices; the other cube's mask stays false.
    ///
    /// Returns an all-false mask when `faceIndex` is out of range.
    bool[] connectedComponentVertices(uint faceIndex) const {
        bool[] mask = new bool[](vertices.length);
        if (faceIndex >= faces.length) return mask;

        int[] parent;
        parent.length = vertices.length;
        foreach (i; 0 .. vertices.length) parent[i] = cast(int)i;

        int findRoot(int x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void unite(int a, int b) {
            a = findRoot(a); b = findRoot(b);
            if (a != b) parent[b] = a;
        }

        foreach (fi; 0 .. faces.length) {
            const uint[] f = faces[fi];
            if (f.length < 2) continue;
            foreach (i; 1 .. f.length) {
                if (f[0] >= vertices.length || f[i] >= vertices.length) continue;
                unite(cast(int)f[0], cast(int)f[i]);
            }
        }

        const uint[] srcFace = faces[faceIndex];
        if (srcFace.length == 0) return mask;
        int root = findRoot(cast(int)srcFace[0]);
        foreach (vi; 0 .. vertices.length) {
            if (findRoot(cast(int)vi) == root) mask[vi] = true;
        }
        return mask;
    }

    unittest { // connectedComponentVertices: two disjoint cubes — island is
               // exactly the picked cube's 8 verts, not the other cube's.
        import std.conv : to;
        Mesh m = makeCube();
        Mesh other = makeCube();
        foreach (v; other.vertices) m.vertices ~= Vec3(v.x + 3.0f, v.y, v.z);
        foreach (f; other.faces) {
            uint[] shifted;
            foreach (vi; f) shifted ~= vi + 8;
            m.addFace(shifted);
        }
        m.buildLoops();
        assert(m.vertices.length == 16 && m.faces.length == 12);

        bool[] mask = m.connectedComponentVertices(0);   // a face of the first cube
        size_t count = 0;
        foreach (i, b; mask) { if (b) { assert(i < 8, "leaked into second cube's verts"); ++count; } }
        assert(count == 8, "expected exactly the first cube's 8 verts, got " ~ count.to!string);

        bool[] mask2 = m.connectedComponentVertices(8);  // a face of the second cube
        size_t count2 = 0;
        foreach (i, b; mask2) { if (b) { assert(i >= 8, "leaked into first cube's verts"); ++count2; } }
        assert(count2 == 8, "expected exactly the second cube's 8 verts, got " ~ count2.to!string);
    }

    unittest {
        import std.math : abs;

        // collapseEdgesByMask: collapse edge 0 ([v0,v3]) of a cube.
        // Edge 0 is the back-left vertical; midpoint = (-0.5, 0, -0.5).
        // Two of the six faces lose a corner and become triangles.
        {
            auto m = makeCube();
            bool[] mask = new bool[](m.edges.length);
            mask[0] = true;
            size_t n = m.collapseEdgesByMask(mask);
            assert(n > 0, "collapseEdgesByMask single: expected weld");
            assert(m.vertices.length == 7,
                "collapseEdgesByMask single: expected 7 verts");
            assert(m.faces.length == 6,
                "collapseEdgesByMask single: expected 6 faces");
            bool foundMid = false;
            foreach (v; m.vertices) {
                if (abs(v.x - (-0.5f)) < 1e-5f
                 && abs(v.y -   0.0f ) < 1e-5f
                 && abs(v.z - (-0.5f)) < 1e-5f) { foundMid = true; break; }
            }
            assert(foundMid, "collapseEdgesByMask single: midpoint absent");
        }

        // collapseEdgesByMask: two disjoint edges (0=[v0,v3], 6=[v6,v7])
        // — no shared vertex, two independent islands. Both must collapse
        // (if only the first collapsed, vertices.length would be 7 not 6).
        {
            auto m = makeCube();
            bool[] mask = new bool[](m.edges.length);
            mask[0] = true;   // [v0, v3]
            mask[6] = true;   // [v6, v7]
            size_t n = m.collapseEdgesByMask(mask);
            assert(n > 0, "collapseEdgesByMask disjoint: expected weld");
            assert(m.vertices.length == 6,
                "collapseEdgesByMask disjoint: both islands must collapse");
        }

        // collapseFacesByMask: collapse front face (fi=1, [4,5,6,7]).
        // Centroid = (0, 0, 0.5). Front face dropped; 4 neighbours → tris;
        // back face untouched. Result: 5 verts, 5 faces.
        {
            auto m = makeCube();
            bool[] mask = new bool[](m.faces.length);
            mask[1] = true;   // front face [4,5,6,7]
            size_t n = m.collapseFacesByMask(mask);
            assert(n > 0, "collapseFacesByMask single: expected weld");
            assert(m.vertices.length == 5,
                "collapseFacesByMask single: expected 5 verts");
            assert(m.faces.length == 5,
                "collapseFacesByMask single: expected 5 faces");
            bool foundCenter = false;
            foreach (v; m.vertices) {
                if (abs(v.x - 0.0f) < 1e-5f
                 && abs(v.y - 0.0f) < 1e-5f
                 && abs(v.z - 0.5f) < 1e-5f) { foundCenter = true; break; }
            }
            assert(foundCenter, "collapseFacesByMask single: centroid absent");
        }

        // collapseFacesByMask: two disjoint faces (fi=0=back, fi=1=front)
        // — each collapses to its own centroid. All 6 faces degenerate and
        // are dropped (every intermediate face has 2 verts from each island,
        // which reduces to a 2-corner degenerate). Result: empty mesh.
        // If only one island collapsed, we would get 5 verts / 5 faces.
        {
            auto m = makeCube();
            bool[] mask = new bool[](m.faces.length);
            mask[0] = true;   // back  face [0,3,2,1]
            mask[1] = true;   // front face [4,5,6,7]
            size_t n = m.collapseFacesByMask(mask);
            assert(n > 0, "collapseFacesByMask disjoint: expected weld");
            assert(m.vertices.length == 0,
                "collapseFacesByMask disjoint: both islands must collapse");
            assert(m.faces.length == 0,
                "collapseFacesByMask disjoint: all faces must degenerate");
        }
    }

    /// For each connected island of selected faces, computes the island's
    /// area-weighted average plane (centroid + normal via raw Newell sum)
    /// and orthogonally projects every vertex touched by that island onto
    /// the plane.  Position-only; no topology change.
    ///
    /// Degenerate island (areaSum < 1e-12 or |normalSum| < 1e-6): skipped.
    ///
    /// **Shared-vertex semantic**: every vertex referenced by a selected face
    /// is projected, including verts also used by unselected faces.
    /// Adjacent unselected faces are therefore deformed.  Use topologically
    /// isolated test fixtures to get unambiguous residuals.
    ///
    /// **Compute-before-write with coordinate-scaled eps**: displacements are
    /// computed first; only verts whose |displacement| >= eps are written,
    /// where eps = 1e-6 * max(1, maxAbsCoord).  An already-planar (even
    /// tilted) selection returns 0 without a version bump — clean no-op.
    ///
    /// Returns: number of vertices moved; 0 means nothing changed.
    size_t alignFacesByMask(in bool[] faceMask) {
        import std.math : sqrt, abs;

        if (faceMask.length != faces.length) return 0;

        bool anySelected = false;
        foreach (b; faceMask) if (b) { anySelected = true; break; }
        if (!anySelected) return 0;

        // Union-find over face indices: two selected faces sharing a vertex
        // belong to the same island (identical pattern to collapseFacesByMask).
        int[] parent;
        parent.length = faces.length;
        foreach (i; 0 .. faces.length) parent[i] = cast(int)i;

        int findRoot(int x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void unite(int a, int b) {
            a = findRoot(a); b = findRoot(b);
            if (a != b) parent[b] = a;
        }

        // Map each vertex to the first selected face that contains it.
        // When a second selected face shares that vertex, unite the two faces.
        int[] vertToFace;
        vertToFace.length = vertices.length;
        vertToFace[] = -1;
        foreach (fi; 0 .. faces.length) {
            if (!faceMask[fi]) continue;
            foreach (v; faces[fi]) {
                if (v >= vertices.length) continue;
                if (vertToFace[v] == -1)
                    vertToFace[v] = cast(int)fi;
                else
                    unite(cast(int)fi, vertToFace[v]);
            }
        }

        // Collect all verts touched by selected faces.
        bool[] inSelection;
        inSelection.length = vertices.length;
        foreach (i; 0 .. vertices.length)
            if (vertToFace[i] >= 0) inSelection[i] = true;

        // Per-island: accumulate raw Newell sum (area-weighted normal) and
        // area-weighted centroid.  The raw Newell vector has magnitude 2*area,
        // so summing gives an area-weighted normal without a separate divide.
        Vec3[int]  normalSum;
        float[int] areaSum;
        Vec3[int]  centroidSum;

        foreach (fi; 0 .. faces.length) {
            if (!faceMask[fi]) continue;
            int root = findRoot(cast(int)fi);
            const uint[] face = faces[fi];

            // Raw Newell sum for this face (same loop as faceNormal, no divide).
            float nx = 0, ny = 0, nz = 0;
            foreach (i; 0 .. face.length) {
                Vec3 a = vertices[face[i]];
                Vec3 b = vertices[face[(i + 1) % face.length]];
                nx += (a.y - b.y) * (a.z + b.z);
                ny += (a.z - b.z) * (a.x + b.x);
                nz += (a.x - b.x) * (a.y + b.y);
            }
            float rawLen = sqrt(nx*nx + ny*ny + nz*nz);
            float area   = 0.5f * rawLen;            // area of this face
            Vec3  centF  = faceCentroid(cast(uint)fi);

            if (root in normalSum) {
                normalSum[root]   += Vec3(nx, ny, nz);
                areaSum[root]     += area;
                centroidSum[root] += centF * area;
            } else {
                normalSum[root]   = Vec3(nx, ny, nz);
                areaSum[root]     = area;
                centroidSum[root] = centF * area;
            }
        }

        // Build per-island plane (C, n) from the accumulators.
        struct IslandPlane { Vec3 C; Vec3 n; }
        IslandPlane[int] planes;
        foreach (root, ns; normalSum) {
            float as_ = areaSum[root];
            if (as_ < 1e-12f) continue;
            float nlen = sqrt(ns.x*ns.x + ns.y*ns.y + ns.z*ns.z);
            if (nlen < 1e-6f) continue;
            Vec3 n  = Vec3(ns.x / nlen, ns.y / nlen, ns.z / nlen);
            Vec3 cs = centroidSum[root];
            planes[root] = IslandPlane(Vec3(cs.x / as_, cs.y / as_, cs.z / as_), n);
        }

        // Compute-before-write: signed distance from each touched vertex to
        // its island's plane.  Explicitly zero-initialised (float.init = NaN).
        float[] dScalar;
        dScalar.length = vertices.length;
        foreach (ref f; dScalar) f = 0.0f;

        foreach (vi; 0 .. vertices.length) {
            if (!inSelection[vi]) continue;
            int root = findRoot(vertToFace[vi]);
            if (!(root in planes)) continue;
            auto pl = planes[root];
            Vec3 v = vertices[vi];
            dScalar[vi] = (v.x - pl.C.x) * pl.n.x
                        + (v.y - pl.C.y) * pl.n.y
                        + (v.z - pl.C.z) * pl.n.z;
        }

        // Coordinate-scaled epsilon: max absolute coordinate over touched verts.
        float maxAbsCoord = 1.0f;
        foreach (vi; 0 .. vertices.length) {
            if (!inSelection[vi]) continue;
            Vec3 v = vertices[vi];
            if (abs(v.x) > maxAbsCoord) maxAbsCoord = abs(v.x);
            if (abs(v.y) > maxAbsCoord) maxAbsCoord = abs(v.y);
            if (abs(v.z) > maxAbsCoord) maxAbsCoord = abs(v.z);
        }
        float eps = 1e-6f * maxAbsCoord;

        // Write only verts whose |displacement| >= eps.
        size_t moved = 0;
        foreach (vi; 0 .. vertices.length) {
            if (!inSelection[vi]) continue;
            float d = dScalar[vi];
            if (abs(d) < eps) continue;
            int root = findRoot(vertToFace[vi]);
            auto pl = planes[root];
            vertices[vi].x -= d * pl.n.x;
            vertices[vi].y -= d * pl.n.y;
            vertices[vi].z -= d * pl.n.z;
            ++moved;
        }

        if (moved == 0) return 0;
        commitChange(MeshEditScope.Position);
        return moved;
    }

    unittest {
        import std.math : abs, sqrt;
        import std.conv : to;

        // (a) Warped quad: the two z=+1 corners are pushed opposite in y,
        //     making the face genuinely non-planar.  After alignFacesByMask
        //     all 4 verts must be coplanar to within 1e-5.
        {
            Mesh m;
            m.vertices = [
                Vec3(-1.0f,  0.0f, -1.0f),   // v0
                Vec3( 1.0f,  0.0f, -1.0f),   // v1
                Vec3( 1.0f,  0.5f,  1.0f),   // v2 — pushed +y
                Vec3(-1.0f, -0.5f,  1.0f),   // v3 — pushed −y
            ];
            m.addFace([0u, 1u, 2u, 3u]);
            m.buildLoops();

            bool[] mask = [true];
            size_t n = m.alignFacesByMask(mask);
            assert(n > 0, "alignFacesByMask warped: expected moves");

            // Recompute plane from 3 post-align verts; check the 4th.
            Vec3 a = m.vertices[0], b = m.vertices[1], c = m.vertices[2];
            Vec3 ab = b - a, ac = c - a;
            Vec3 pn = Vec3(ab.y*ac.z - ab.z*ac.y,
                           ab.z*ac.x - ab.x*ac.z,
                           ab.x*ac.y - ab.y*ac.x);
            float pnlen = sqrt(pn.x*pn.x + pn.y*pn.y + pn.z*pn.z);
            assert(pnlen > 1e-6f, "alignFacesByMask warped: degenerate post-align plane");
            pn = Vec3(pn.x / pnlen, pn.y / pnlen, pn.z / pnlen);
            Vec3 d3 = m.vertices[3] - a;
            float dist = abs(d3.x * pn.x + d3.y * pn.y + d3.z * pn.z);
            assert(dist < 1e-5f,
                "alignFacesByMask warped: 4th vert not coplanar, dist=" ~ dist.to!string);
        }

        // (b) Already-planar but TILTED quad: z = 0.3*x + 0.2*y.
        //     Kernel must return 0 and leave every vertex byte-for-byte
        //     unchanged, proving the coordinate-scaled eps absorbs the ~1e-7
        //     float residual that a naive 1e-9 threshold would mis-read as motion.
        {
            Mesh m;
            m.vertices = [
                Vec3(0.0f, 0.0f, 0.0f),    // z = 0.0
                Vec3(1.0f, 0.0f, 0.3f),    // z = 0.3
                Vec3(1.0f, 1.0f, 0.5f),    // z = 0.5
                Vec3(0.0f, 1.0f, 0.2f),    // z = 0.2
            ];
            Vec3[4] orig;
            foreach (i; 0 .. 4) orig[i] = m.vertices[i];
            m.addFace([0u, 1u, 2u, 3u]);
            m.buildLoops();

            bool[] mask = [true];
            size_t n = m.alignFacesByMask(mask);
            assert(n == 0,
                "alignFacesByMask planar-tilted: expected no-op, got " ~ n.to!string);
            foreach (i; 0 .. 4)
                assert(m.vertices[i].x == orig[i].x
                    && m.vertices[i].y == orig[i].y
                    && m.vertices[i].z == orig[i].z,
                    "alignFacesByMask planar-tilted: vert " ~ i.to!string ~ " changed");
        }
    }

    /// Read-only: the "lowest surviving index wins" grid-based coincidence
    /// search `weldCoincidentVertices` uses to decide which vertices would
    /// merge into which, WITHOUT applying it. `remap[i] == i` means vertex
    /// `i` survives as a representative (or has no coincident partner);
    /// `remap[i] == r` (`r != i`) means `i` would be welded into
    /// representative `r`. By construction every representative satisfies
    /// `remap[r] == r` and every follower's remap points directly at its
    /// representative — no multi-hop chains form (the scan only ever claims
    /// an unclaimed root), so grouping vertices by `remap[]` value alone is
    /// enough to recover clusters. Shared by the mutating weld and the
    /// read-only Cleanup detector (`mesh_analysis.coincidentVertexClusters`,
    /// task 0402 Phase 4 risk #2) so the two can never drift apart — see
    /// `weldCoincidentVertices`'s doc comment for the full search rationale
    /// and `epsSq`/`protectBelow` semantics.
    int[] computeWeldRemap(double epsSq = 1e-12, size_t protectBelow = 0) const {
        int[] remap;
        remap.length = vertices.length;
        foreach (i; 0 .. vertices.length) remap[i] = cast(int)i;
        if (vertices.length < 2 || epsSq <= 0.0) return remap;

        import std.math : floor, isFinite;
        immutable double cellFloor = 1e-6;
        double cellSize = sqrt(epsSq);
        if (!isFinite(cellSize) || cellSize < cellFloor) cellSize = cellFloor;
        immutable double invCell = 1.0 / cellSize;

        long[] cx, cy, cz;
        cx.length = vertices.length;
        cy.length = vertices.length;
        cz.length = vertices.length;
        size_t[][long[3]] buckets;
        foreach (i, ref v; vertices) {
            cx[i] = cast(long)floor(cast(double)v.x * invCell);
            cy[i] = cast(long)floor(cast(double)v.y * invCell);
            cz[i] = cast(long)floor(cast(double)v.z * invCell);
            long[3] key = [cx[i], cy[i], cz[i]];
            buckets[key] ~= i;
        }

        foreach (i; 0 .. vertices.length) {
            if (remap[i] != cast(int)i) continue;
            foreach (dx; -1 .. 2) foreach (dy; -1 .. 2) foreach (dz; -1 .. 2) {
                long[3] key = [cx[i] + dx, cy[i] + dy, cz[i] + dz];
                auto bucket = key in buckets;
                if (bucket is null) continue;
                foreach (j; *bucket) {
                    if (j <= i) continue;
                    if (remap[j] != cast(int)j) continue;
                    if (i < protectBelow && j < protectBelow) continue;
                    Vec3 d = vertices[i] - vertices[j];
                    if (d.x * d.x + d.y * d.y + d.z * d.z < epsSq)
                        remap[j] = cast(int)i;
                }
            }
        }
        return remap;
    }

    /// `protectBelow`: vertex-index pairs where BOTH indices are strictly
    /// less than this bound are never merged with each other, no matter how
    /// large `epsSq` is. Default 0 disables the guard (every existing caller
    /// gets the original all-pairs-eligible behavior unchanged). Callers
    /// that append new (e.g. cloned) vertices after the pre-existing ones —
    /// `mirrorFacesPlane`'s weld pass is the first user — pass the
    /// pre-existing vertex count here so a large weld threshold can't fold
    /// together two unrelated, pre-existing vertices that merely happen to
    /// be within `epsSq` of each other (task 0306 bug B: a big `weld` was
    /// welding the whole mesh globally instead of just the mirror seam).
    /// Vertex pairs touching at least one newly-appended vertex remain fully
    /// eligible, which is exactly the seam-pair semantics a mirror weld
    /// needs (a clone landing back on ITS OWN or on some OTHER pre-existing
    /// vertex is the legitimate case; two pre-existing vertices merging
    /// with each other is not).
    size_t weldCoincidentVertices(double epsSq = 1e-12, size_t protectBelow = 0) {
        if (vertices.length < 2) return 0;
        int[] remap = computeWeldRemap(epsSq, protectBelow);

        size_t welded = 0;
        foreach (i; 0 .. vertices.length)
            if (remap[i] != cast(int)i) ++welded;
        if (welded == 0) return 0;

        // PolyVertex remap, mechanism (b): the corner-collapse below rewrites
        // each face's corner LIST (consecutive-dup drop + wrap-around-dup drop +
        // sub-3 face drop). Track which OLD corner each surviving NEW corner came
        // from so per-corner values follow the survivors. This mutator does NOT
        // call buildLoops, so the relocate cannot ride a tail funnel — it is done
        // here from `oldFaceLoop` captured before `faces` is rewritten. (This is
        // the same corner-drop logic the positional import-weld uses; getting it
        // right here is exactly the GAP-4 keying.)
        const bool remapUv = hasPolyVertexMap();
        const uint[] oldFaceLoop = remapUv ? captureFaceLoop() : null;
        uint[] oldLoopOfNewLoop;

        uint[][] newFaces;
        newFaces.reserve(faces.length);
        foreach (fi, ref face; faces) {
            uint[] f;
            uint[] srcCorner; // old corner index that produced each kept corner
            f.reserve(face.length);
            foreach (k, vid; face) {
                uint mapped = (vid < remap.length) ? cast(uint)remap[vid] : vid;
                if (f.length == 0 || f[$ - 1] != mapped) {
                    f ~= mapped;
                    if (remapUv) srcCorner ~= cast(uint)k;
                }
            }
            // Wrap-around dup: last == first means the face cycles back to
            // its start through a remapped corner.
            if (f.length > 1 && f[$ - 1] == f[0]) {
                f = f[0 .. $ - 1];
                if (remapUv) srcCorner = srcCorner[0 .. $ - 1];
            }
            if (f.length >= 3) {
                newFaces ~= f;
                if (remapUv)
                    foreach (sc; srcCorner)
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, sc);
            }
        }
        faces = newFaces;
        if (remapUv) remapPolyVertexMaps(oldLoopOfNewLoop);

        rebuildEdges();

        clearEdgeSelectionResize();
        // Face selection is potentially invalidated (face indices changed
        // since collapsed faces are removed). Caller may re-derive.
        if (selectedFaces.length > faces.length) resizeFaceSelection();
        if (faceSelectionOrder.length > faces.length) faceSelectionOrder.length = faces.length;
        if (isSubpatch.length > faces.length) resizeSubpatch();
        if (faceMaterial.length > faces.length) faceMaterial.length = faces.length;
        if (facePart.length     > faces.length) facePart.length     = faces.length;

        // Geometry-class: coincident verts merged, faces/edges rebuilt.
        commitChange(MeshEditScope.Geometry);
        return welded;
    }

    /// Remove vertices not referenced by any face. Updates all face vertex
    /// references via a remap table and re-derives the edges array. Returns
    /// the number of vertices removed.
    /// Useful after topology mutations (e.g. bevel arc miter) that leave
    /// stale BoundVerts or cap mids unreferenced.
    /// Read-only: which vertices are referenced by at least one face — the
    /// exact test `compactUnreferenced` uses to decide which vertices
    /// survive. Shared with the read-only Cleanup detector
    /// (`mesh_analysis.orphanVertexIndices`, task 0402 Phase 4 risk #2).
    bool[] computeReferencedVertexMask() const {
        bool[] referenced;
        referenced.length = vertices.length;
        foreach (ref face; faces)
            foreach (vid; face)
                if (vid < referenced.length) referenced[vid] = true;
        return referenced;
    }

    size_t compactUnreferenced() {
        bool[] referenced = computeReferencedVertexMask();
        // Build old→new index map
        uint[] remap;
        remap.length = vertices.length;
        Vec3[] newVerts;
        newVerts.reserve(vertices.length);
        size_t removed = 0;
        foreach (i, ref v; vertices) {
            if (referenced[i]) {
                remap[i] = cast(uint)newVerts.length;
                newVerts ~= v;
            } else {
                remap[i] = cast(uint)~0u;
                ++removed;
            }
        }
        if (removed == 0) return 0;
        // Class R tracker hook — inert unless a batch is open. Record the
        // dropped verts (their pre-compaction indices + positions) THEN the
        // index permutation, in drop-before-permute order. LIFO revert inverts
        // permute-before-undrop (doc §2.3 steps 2–3): Reindex^-1 restores the
        // pre-compaction index space, then RemoveVerts^-1 re-inserts the
        // dropped verts into the re-opened gaps. Captured here, BEFORE
        // `vertices = newVerts`, so the dropped positions are still live.
        if (editRecorder_ !is null) {
            uint[] droppedIdx;
            Vec3[] droppedPos;
            foreach (i, p; remap) {
                if (p == cast(uint)~0u) {
                    droppedIdx ~= cast(uint)i;
                    droppedPos ~= vertices[i];
                }
            }
            editRecorder_.recordRemoveVerts(droppedIdx, droppedPos);
            editRecorder_.recordReindex(remap);
        }
        // Rewrite face vertex IDs
        foreach (ref face; faces)
            foreach (ref vid; face)
                if (vid < remap.length) vid = remap[vid];
        vertices = newVerts;
        // Re-derive edges from faces (remap can break edge endpoints).
        rebuildEdges();
        // Selection arrays follow vertices length; truncate / repack the
        // simple cases (selected vertices: re-built bool array).
        resizeVertexSelection();
        // Edges have changed — clear edge selection for safety.
        clearEdgeSelectionResize();
        // Points-class: orphan verts removed + reindexed (Geometry bit keeps
        // the topology bump).
        commitChange(MeshEditScope.Points);
        return removed;
    }
    /// Drop the faces marked true in `mask`. Edges are rebuilt from the
    /// surviving faces; orphan vertices (no longer referenced by any
    /// remaining face) are removed via compactUnreferenced(). Selection
    /// arrays are resized and cleared (re-selecting after a delete is
    /// the caller's responsibility — index validity is unstable across
    /// a compact). Returns the number of faces removed.
    ///
    /// This is the unified delete primitive: Tier 1.1 mesh.delete dispatches
    /// here for every edit mode by translating its selection into a face
    /// mask (verts → faces incident; edges → faces incident; polys
    /// directly).
    size_t deleteFacesByMask(in bool[] mask) {
        if (mask.length != faces.length) return 0;
        uint[][] keptFaces;
        bool[]   keptSubpatch;
        int[]    keptOrder;
        uint[]   keptMaterial;
        uint[]   keptPart;
        size_t   removed = 0;
        keptFaces.reserve(faces.length);
        keptSubpatch.reserve(faces.length);
        keptOrder.reserve(faces.length);
        keptMaterial.reserve(faces.length);
        keptPart.reserve(faces.length);
        // Class B tracker hook — accumulate the dropped (filtered-out) faces so
        // a RemoveFaces entry can re-insert them on revert. Inert unless a batch
        // is open. Indices are the PRE-filter face indices (the space the entry
        // is inverted in, before the tail compactUnreferenced reindexes verts).
        uint[]   droppedFaceIdx;
        uint[][] droppedFaceLists;
        uint[]   droppedFaceMat;
        uint[]   droppedFacePart;
        uint[]   droppedFaceSub;
        const bool recDelete = editRecorder_ !is null;
        // PolyVertex remap, mechanism (a): surviving faces keep their corner
        // count, so corner `c` of a kept face maps to old loop
        // oldFaceLoop[oldFi]+c. Build `oldLoopOfNewLoop` in NEW-face/new-corner
        // (CSR) order while filtering, then relocate before the tail buildLoops.
        const bool remapUv = hasPolyVertexMap();
        const uint[] oldFaceLoop = remapUv ? captureFaceLoop() : null;
        uint[] oldLoopOfNewLoop;
        foreach (i, ref f; faces) {
            if (mask[i]) {
                ++removed;
                if (recDelete) {
                    droppedFaceIdx   ~= cast(uint)i;
                    droppedFaceLists ~= f.dup;
                    droppedFaceMat   ~= (i < faceMaterial.length ? faceMaterial[i] : 0u);
                    droppedFacePart  ~= (i < facePart.length    ? facePart[i]    : 0u);
                    droppedFaceSub   ~= (isFaceSubpatch(i) ? 1u : 0u);
                }
                continue;
            }
            keptFaces ~= f;
            // isFaceSubpatch(i), NOT `isSubpatch[i]`: `isSubpatch` is a
            // `@property` that materializes a fresh `bool[faces.length]` on
            // EVERY read (see its definition above) — indexing it inside this
            // per-face loop was an O(F²) trap (task 0396: this loop runs once
            // per surviving face, and until this fix each iteration re-built
            // the whole array just to read one bit). `isFaceSubpatch` is the
            // established O(1) non-allocating counterpart (already used two
            // lines up for `droppedFaceSub`), same fix class as the
            // `selectedX`-@property-in-loop sweep (commits c1d9526/4acf93b).
            keptSubpatch ~= isFaceSubpatch(i);
            keptOrder    ~= (i < faceSelectionOrder.length ? faceSelectionOrder[i] : 0);
            keptMaterial ~= (i < faceMaterial.length      ? faceMaterial[i]      : 0u);
            keptPart     ~= (i < facePart.length          ? facePart[i]          : 0u);
            if (remapUv)
                foreach (c; 0 .. f.length)
                    oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)i, cast(uint)c);
        }
        if (removed == 0) return 0;
        if (recDelete)
            editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                            droppedFaceMat, droppedFacePart, droppedFaceSub);
        faces              = keptFaces;
        setFaceSubpatchFrom(keptSubpatch);
        faceSelectionOrder = keptOrder;
        faceMaterial       = keptMaterial;
        facePart           = keptPart;
        // PolyVertex relocate (a): per-corner values follow their surviving
        // corners. Done now (before the tail buildLoops); the loop layout this
        // produces is exactly what buildLoops rebuilds from the new `faces`, so
        // its resizePolyVertexMaps is then a length-correct no-op.
        if (remapUv) remapPolyVertexMaps(oldLoopOfNewLoop);
        // Selection bits don't survive index changes; clear and let caller
        // restore as needed.
        clearFaceSelectionResize();
        // Re-derive edges from the surviving faces. Some edges may be gone
        // entirely (only-touched the deleted faces); others stay. Always
        // do this even if no verts were orphaned — compactUnreferenced
        // skips the rebuild when removed==0.
        rebuildEdges();
        clearEdgeSelectionResize();
        // Compact orphan vertices (no-op if all verts still referenced).
        compactUnreferenced();
        // Half-edge loops carry face/vert indices that compaction just
        // invalidated; rebuild so adjacentFaces / verticesAroundVertex /
        // friends return live indices. (Without this, the next consumer
        // of `loops` walks stale data and either reports wrong adjacency
        // or indexes out of bounds.)
        buildLoops();
        // Geometry-class: faces removed, orphan verts compacted, edges/loops
        // rebuilt.
        commitChange(MeshEditScope.Geometry);
        return removed;
    }

    /// Reverse the winding (vertex order) of every face selected by `mask`,
    /// inverting its normal. The undirected edge set is invariant under a
    /// winding flip (consecutive pairs are the same undirected set after
    /// reversal), so edges[] and edgeIndexMap are left intact; only the
    /// half-edge loops are re-synced via buildLoops() — NOT rebuildEdges().
    /// PolyVertex (per-corner UV / color) maps are RELOCATED to follow the
    /// reversed corner order so UVs stay glued to their corners (R5): for
    /// each flipped face, new loop faceLoop[fi]+j maps to old loop
    /// faceLoop[fi]+(N-1-j); non-flipped faces use the identity mapping.
    /// Empty mask (all-false) is a no-op that returns 0.
    size_t flipFacesByMask(in bool[] mask) {
        import std.algorithm.mutation : reverse;
        if (mask.length != faces.length) return 0;
        const bool needUV = hasPolyVertexMap();
        size_t flipped = 0;
        foreach (fi; 0 .. faces.length) {
            if (!mask[fi]) continue;
            if (faces[fi].length < 3) continue;   // degenerate guard
            reverse(faces[fi]);                    // reverse vertex list in-place
            ++flipped;
        }
        if (flipped == 0) return 0;
        if (needUV) {
            // Build oldLoopOfNewLoop BEFORE buildLoops.  faceLoop[] is still
            // the pre-flip CSR (arity is preserved ⇒ offsets are identical):
            //   new loop faceLoop[fi]+j  ←  old loop faceLoop[fi]+(N-1-j)
            // Non-flipped and degenerate faces use the identity mapping.
            auto oldLoopOfNewLoop = new uint[](loops.length);
            foreach (fi; 0 .. faces.length) {
                const uint base = faceLoop[fi];
                const uint n    = cast(uint) faces[fi].length;
                if (mask[fi] && n >= 3)
                    foreach (j; 0 .. n) oldLoopOfNewLoop[base + j] = base + (n - 1 - j);
                else
                    foreach (j; 0 .. n) oldLoopOfNewLoop[base + j] = base + j;
            }
            remapPolyVertexMaps(oldLoopOfNewLoop); // BEFORE buildLoops ⇒ resize no-ops
        }
        buildLoops();   // re-sync loops/loopEdge; NOT rebuildEdges (edge set invariant)
        commitChange(MeshEditScope.Geometry);
        return flipped;
    }

    /// Dissolve the vertices marked true in `mask`: each selected vert
    /// is dropped from every face's boundary list (a quad becomes a
    /// triangle, a triangle becomes degenerate and the face is dropped).
    /// Edges are rebuilt and orphan verts compacted out.
    ///
    /// This is `delete vertex` semantics — it preserves the
    /// surrounding faces by re-shaping them, rather than killing every
    /// incident face like a naive "delete incident topology" would.
    size_t dissolveVerticesByMask(in bool[] mask) {
        if (mask.length != vertices.length) return 0;
        size_t dissolved = 0;
        foreach (vi; 0 .. mask.length) if (mask[vi]) ++dissolved;
        if (dissolved == 0) return 0;

        // Rebuild faces array, dropping each masked vert from every face's
        // boundary. Faces shrunk below 3 verts (degenerate) are dropped.
        uint[][] newFaces;
        bool[]   newSubpatch;
        int[]    newOrder;
        uint[]   newMaterial;
        uint[]   newPart;
        newFaces.reserve(faces.length);
        newSubpatch.reserve(faces.length);
        newOrder.reserve(faces.length);
        newMaterial.reserve(faces.length);
        newPart.reserve(faces.length);
        // Class B tracker hook accumulators — inert unless a batch is open.
        // A face whose boundary shrinks (but stays >= 3) is a ReshapeFaces; a
        // face that becomes degenerate (< 3) and is dropped is a RemoveFaces.
        // Both index in the NEW (post-rebuild) face-index space so they invert
        // before the tail compactUnreferenced's vert reindex (LIFO).
        const bool recDis = editRecorder_ !is null;
        uint[]   reshapeIdx;
        uint[][] reshapeBefore;
        uint[][] reshapeAfter;
        uint[]   removedFaceIdx;
        uint[][] removedFaceLists;
        uint[]   removedFaceMat;
        uint[]   removedFacePart;
        uint[]   removedFaceSub;
        // PolyVertex remap, mechanism (b): a masked corner is dropped from its
        // face's corner LIST, so new corner `j` of a surviving face came from a
        // specific OLD corner `k` (its position in the old face). Build
        // `oldLoopOfNewLoop` in NEW-face/new-corner (CSR) order so a planted UV
        // follows the surviving corner even as the face changes arity.
        const bool remapUv = hasPolyVertexMap();
        const uint[] oldFaceLoop = remapUv ? captureFaceLoop() : null;
        uint[] oldLoopOfNewLoop;
        foreach (fi, ref f; faces) {
            uint[] kept;
            uint[] keptCorner; // old corner index of each kept corner (mech b)
            foreach (k, vid; f) {
                if (vid < mask.length && mask[vid]) continue;
                kept ~= vid;
                if (remapUv) keptCorner ~= cast(uint)k;
            }
            if (kept.length >= 3) {
                if (recDis && kept.length != f.length) {
                    reshapeIdx    ~= cast(uint)newFaces.length;
                    reshapeBefore ~= f.dup;
                    reshapeAfter  ~= kept.dup;
                }
                newFaces    ~= kept;
                newSubpatch ~= isFaceSubpatch(fi);
                newOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
                newMaterial ~= (fi < faceMaterial.length      ? faceMaterial[fi]      : 0u);
                newPart     ~= (fi < facePart.length          ? facePart[fi]          : 0u);
                if (remapUv)
                    foreach (kc; keptCorner)
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, kc);
            } else if (recDis) {
                // Degenerate face dropped — reconstruct it on revert at its
                // post-shrink position in the new face array.
                removedFaceIdx   ~= cast(uint)newFaces.length;
                removedFaceLists ~= f.dup;
                removedFaceMat   ~= (fi < faceMaterial.length ? faceMaterial[fi] : 0u);
                removedFacePart  ~= (fi < facePart.length    ? facePart[fi]    : 0u);
                removedFaceSub   ~= (isFaceSubpatch(fi) ? 1u : 0u);
            }
        }
        if (recDis) {
            // Reshape first, then RemoveFaces — on revert (LIFO) the dropped
            // faces are re-inserted FIRST, then the reshape lists are restored,
            // matching the post-shrink index space both were recorded in.
            editRecorder_.recordReshapeFaces(reshapeIdx, reshapeBefore, reshapeAfter);
            editRecorder_.recordRemoveFaces(removedFaceIdx, removedFaceLists,
                                            removedFaceMat, removedFacePart, removedFaceSub);
        }
        faces              = newFaces;
        setFaceSubpatchFrom(newSubpatch);
        faceSelectionOrder = newOrder;
        faceMaterial       = newMaterial;
        facePart           = newPart;
        // PolyVertex relocate (b): per-corner values follow surviving corners
        // through the arity change. Before the tail buildLoops/compact.
        if (remapUv) remapPolyVertexMaps(oldLoopOfNewLoop);
        clearFaceSelectionResize();

        // Rebuild edges from the new faces (some edges are gone, some
        // boundaries are shorter). compactUnreferenced then removes the
        // dissolved (now-orphan) verts and re-derives edges yet again.
        rebuildEdges();
        clearEdgeSelectionResize();
        compactUnreferenced();
        // See deleteFacesByMask: loops carry stale indices after face/vert
        // compaction.
        buildLoops();
        // Geometry-class: verts dissolved out of faces, geometry rebuilt.
        commitChange(MeshEditScope.Geometry);
        return dissolved;
    }

    /// Dissolve every vertex that is incident to exactly 2 edges. Such
    /// verts are pinch-points along a chain of edges in the surrounding
    /// faces — collapsing them merges the two adjacent boundary edges
    /// into one. Used as a cleanup pass after removeEdgesByMask: the
    /// `delete` / `remove` behavior on edge selections dissolves the
    /// edge AND drops the now-orphaned 2-valent endpoints.
    /// Returns the number of verts dissolved.
    size_t dissolveDegree2Verts() {
        // Tally the number of edges incident to each vertex.
        int[] degree;
        degree.length = vertices.length;
        foreach (e; edges) {
            uint a = e[0], b = e[1];
            if (a < degree.length) ++degree[a];
            if (b < degree.length) ++degree[b];
        }
        bool[] mask;
        mask.length = vertices.length;
        size_t cnt = 0;
        foreach (i, d; degree) {
            if (d == 2) { mask[i] = true; ++cnt; }
        }
        if (cnt == 0) return 0;
        return dissolveVerticesByMask(mask);
    }

    /// Dissolve the edges marked true in `mask`: each selected edge is
    /// removed, and any group of faces transitively connected through
    /// selected edges is merged into a single polygon along the union's
    /// outer boundary.
    ///
    /// Algorithm: union-find over faces, edges within a component drop
    /// out, the remaining directed half-edges of the component form a
    /// closed walk = the merged polygon boundary. Handles fans (multiple
    /// selected edges sharing a vertex) cleanly — pairwise-merge would
    /// produce a bowtie polygon in that case. Boundary edges (only one
    /// adjacent face) are skipped. Returns the number of selected edges
    /// actually dissolved.
    size_t removeEdgesByMask(in bool[] mask) {
        if (mask.length != edges.length) return 0;

        // Snapshot selected edges as undirected keys; edge-array indices
        // are unstable across compactUnreferenced.
        bool[ulong] selectedEdgeKeys;
        foreach (i; 0 .. edges.length)
            if (mask[i])
                selectedEdgeKeys[edgeKeyOrdered(edges[i][0], edges[i][1])] = true;
        if (selectedEdgeKeys.length == 0) return 0;

        // PolyVertex remap, mechanism (b): merging faces rewrites the corner
        // LIST (the merged poly is a boundary walk). Capture the OLD CSR corner
        // offsets so each merged-poly corner — and each kept face's corner — can
        // be traced to an old loop index. Built into `oldLoopOfNewLoop` in the
        // final [kept ++ merged] face order below.
        const bool remapUv = hasPolyVertexMap();
        const uint[] oldFaceLoop = remapUv ? captureFaceLoop() : null;

        // Build face → face union-find via selected edges.
        size_t nFaces = faces.length;
        int[] parent;  parent.length = nFaces;
        int[] rank_;   rank_.length  = nFaces;
        foreach (i; 0 .. nFaces) parent[i] = cast(int)i;
        int find(int x) { while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; } return x; }
        void unite(int a, int b) {
            a = find(a); b = find(b); if (a == b) return;
            if (rank_[a] < rank_[b]) { int t = a; a = b; b = t; }
            parent[b] = a;
            if (rank_[a] == rank_[b]) ++rank_[a];
        }

        // One-pass adjacency: map each edge key → up to its first two DISTINCT
        // adjacent faces (by ascending face index). Reproduces the original
        // "first two distinct faces" semantics: first occurrence → slot 0,
        // second distinct face → slot 1; a 3rd+ face and a face that contains
        // the edge twice are ignored.
        auto edgeFaces = buildEdgeFaces();

        // For each selected edge, look up both adjacent faces and unite them.
        // Boundary edges (only 1 adjacent face) leave their face alone and are
        // NOT recorded as dissolved.
        size_t dissolved = 0;
        bool[ulong] dissolvedEdgeKeys;   // edges ACTUALLY merged (interior, both faces)
        foreach (key; selectedEdgeKeys.byKey) {
            auto p = key in edgeFaces;
            if (p is null) continue;
            int fA = (*p)[0], fB = (*p)[1];
            if (fA != -1 && fB != -1) {
                unite(fA, fB);
                dissolvedEdgeKeys[key] = true;
                ++dissolved;
            }
        }
        if (dissolved == 0) return 0;

        // Group faces by component root.
        size_t[][int] componentFaces;
        foreach (fi; 0 .. nFaces) {
            int r = find(cast(int)fi);
            componentFaces[r] ~= fi;
        }

        // For each multi-face component: walk the boundary and produce the
        // merged polygon. Single-face components are untouched.
        bool[] dropFace      = new bool[](nFaces);
        uint[][] newPolyList;
        bool[]   newPolySubpatch;
        int[]    newPolyOrder;
        uint[]   newPolyMaterial;
        uint[]   newPolyPart;
        // Parallel to newPolyList: the OLD loop index that produced each merged
        // corner (mechanism b). `~0u` ⇒ no traceable source ⇒ zero-fill.
        uint[][] newPolySrcLoop;
        foreach (root, comp; componentFaces) {
            if (comp.length < 2) continue;

            // Gather directed half-edges from the component, dropping
            // half-edges whose edge was actually dissolved (interior); selected
            // boundary edges survive on the merged boundary. `outSrc` carries the
            // OLD loop index of the half-edge's START corner, parallel to `outAt`.
            uint[][uint] outAt;  // outAt[u] = list of `v` for each surviving u→v
            uint[][uint] outSrc; // outSrc[u][i] = old loop index of u→v's start
            foreach (fi; comp) {
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    uint a = f[k], b = f[(k + 1) % f.length];
                    if (edgeKeyOrdered(a, b) in dissolvedEdgeKeys) continue;
                    outAt[a] ~= b;
                    if (remapUv)
                        outSrc[a] ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, cast(uint)k);
                }
            }

            // Walk: start at any vertex with an outgoing half-edge, follow
            // until back to start. A simple connected face fan produces one
            // closed loop; degenerate inputs may leave half-edges behind
            // (we accept the first walk).
            if (outAt.length == 0) continue;
            uint startV = uint.max;
            foreach (k; outAt.byKey) { startV = k; break; }

            uint[] poly;
            uint[] polySrc; // old loop index per poly corner (mechanism b)
            uint cur = startV;
            while (true) {
                poly ~= cur;
                auto p = cur in outAt;
                if (p is null || (*p).length == 0) {
                    if (remapUv) polySrc ~= ~0u; // dangling start ⇒ zero-fill
                    break;
                }
                uint nxt = (*p)[0];
                *p = (*p)[1 .. $];
                if (remapUv) {
                    // Consume the parallel source entry. The corner just pushed
                    // (`cur`) is the START of this consumed half-edge, so its old
                    // loop index is the source for this poly corner.
                    auto ps = cur in outSrc;
                    if (ps !is null && (*ps).length > 0) {
                        polySrc ~= (*ps)[0];
                        *ps = (*ps)[1 .. $];
                    } else {
                        polySrc ~= ~0u;
                    }
                }
                if (nxt == startV) break;
                cur = nxt;
            }

            if (poly.length < 3) continue;

            // Mark every face in the component for removal; the new
            // merged polygon will replace them.
            foreach (fi; comp) dropFace[fi] = true;

            // Inherit subpatch flag and selection-order from the FIRST
            // face in the component (arbitrary but deterministic).
            int firstFi = cast(int)comp[0];
            newPolyList      ~= poly;
            newPolySubpatch  ~= isFaceSubpatch(firstFi);
            newPolyOrder     ~= (firstFi < cast(int)faceSelectionOrder.length ? faceSelectionOrder[firstFi] : 0);
            newPolyMaterial  ~= (firstFi < cast(int)faceMaterial.length      ? faceMaterial[firstFi]      : 0u);
            newPolyPart      ~= (firstFi < cast(int)facePart.length          ? facePart[firstFi]          : 0u);
            if (remapUv) newPolySrcLoop ~= polySrc;
        }

        // Compact: drop faces, append merged polygons.
        //
        // Class B tracker hook (Phase 3) — inert unless a batch is open. The
        // face array is rebuilt as [kept faces, in original relative order]
        // ++ [merged boundary polygons]. That is exactly a keep-filter drop
        // (closing the gaps the dropped component faces leave) followed by a
        // tail append, so the delta is a RemoveFaces (the dropped component
        // faces, recorded in the POST-DROP face-index space — the same
        // convention dissolveVerticesByMask uses, so RemoveFaces⁻¹ insertInPlace
        // ascending reconstructs them) plus an AddFaces (the appended merged
        // polys, a tail range). The tail compactUnreferenced then self-logs
        // RemoveVerts + Reindex via the Class-R hook. Forward log for an edge
        // dissolve = [RemoveFaces, AddFaces, RemoveVerts, Reindex].
        const bool recRemoveEdges = editRecorder_ !is null;
        uint[]   droppedFaceIdx;
        uint[][] droppedFaceLists;
        uint[]   droppedFaceMat;
        uint[]   droppedFacePart;
        uint[]   droppedFaceSub;
        uint[][] keptFaces;
        bool[]   keptSubpatch;
        int[]    keptOrder;
        uint[]   keptMaterial;
        uint[]   keptPart;
        // PolyVertex relocate accumulator, in final [kept ++ merged] CSR order.
        uint[] oldLoopOfNewLoop;
        foreach (fi; 0 .. nFaces) {
            if (dropFace[fi]) {
                if (recRemoveEdges) {
                    // Position in the POST-DROP array = current keptFaces.length
                    // (the slot this face would occupy if it had survived; on
                    // revert RemoveFaces⁻¹ re-inserts ascending into exactly
                    // these positions, restoring the original relative order).
                    droppedFaceIdx   ~= cast(uint)keptFaces.length;
                    droppedFaceLists ~= faces[fi].dup;
                    droppedFaceMat   ~= (fi < faceMaterial.length ? faceMaterial[fi] : 0u);
                    droppedFacePart  ~= (fi < facePart.length    ? facePart[fi]    : 0u);
                    droppedFaceSub   ~= (isFaceSubpatch(cast(uint)fi) ? 1u : 0u);
                }
                continue;
            }
            keptFaces ~= faces[fi];
            keptSubpatch ~= isFaceSubpatch(fi);
            keptOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
            keptMaterial ~= (fi < faceMaterial.length      ? faceMaterial[fi]      : 0u);
            keptPart     ~= (fi < facePart.length          ? facePart[fi]          : 0u);
            // Kept faces preserve arity → corner c maps to old loop fi/c (a).
            if (remapUv)
                foreach (c; 0 .. faces[fi].length)
                    oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, cast(uint)c);
        }
        // Tail range start = number of kept (non-dropped) faces.
        const size_t firstMerged = keptFaces.length;
        foreach (i; 0 .. newPolyList.length) {
            keptFaces    ~= newPolyList[i];
            keptSubpatch ~= newPolySubpatch[i];
            keptOrder    ~= newPolyOrder[i];
            keptMaterial ~= newPolyMaterial[i];
            keptPart     ~= newPolyPart[i];
            // Merged poly corners → the old loop traced during the boundary
            // walk (~0u where the walk could not trace a source) (b).
            if (remapUv) oldLoopOfNewLoop ~= newPolySrcLoop[i];
        }
        if (recRemoveEdges) {
            // RemoveFaces FIRST, then AddFaces — on revert (LIFO) the appended
            // merged polys truncate FIRST (restoring the kept-only array), then
            // the dropped component faces re-insert into the post-drop space.
            editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                            droppedFaceMat, droppedFacePart, droppedFaceSub);
            uint[][] mergedLists;
            mergedLists.length = newPolyList.length;
            foreach (i; 0 .. newPolyList.length) mergedLists[i] = newPolyList[i].dup;
            editRecorder_.recordAddFaces(cast(uint)firstMerged,
                                         cast(uint)keptFaces.length, mergedLists);
        }
        faces              = keptFaces;
        setFaceSubpatchFrom(keptSubpatch);
        faceSelectionOrder = keptOrder;
        faceMaterial       = keptMaterial;
        facePart           = keptPart;
        // PolyVertex relocate (b): per-corner values follow the merged/kept
        // corners. Before the tail buildLoops (which then no-ops the resize).
        if (remapUv) remapPolyVertexMaps(oldLoopOfNewLoop);
        clearFaceSelectionResize();

        // Rebuild edges + compact orphan verts.
        rebuildEdges();
        clearEdgeSelectionResize();
        compactUnreferenced();
        // See deleteFacesByMask: loops carry stale indices after face/vert
        // compaction.
        buildLoops();
        // Geometry-class: edge dissolve merged faces, geometry rebuilt.
        commitChange(MeshEditScope.Geometry);
        return dissolved;
    }

    // -----------------------------------------------------------------------
    // Triangulation family: Triple / Quadruple / Detriangulate
    // -----------------------------------------------------------------------

    /// Split each masked face (n-gon, n > 3) into (n−2) triangles by fanning
    /// from the first vertex: [f[0],f[i],f[i+1]] for i = 1 .. n−2. Already-
    /// triangles (length ≤ 3) pass through untouched regardless of the mask.
    /// Returns the number of faces changed.
    ///
    /// `faceOriginOut` (optional): receives a mapping new_fi → original_fi,
    /// useful for re-selecting children of previously-selected parents after
    /// the topology swap.
    ///
    /// v1 restriction: fan triangulation is correct for convex polygons (every
    /// quad and convex n-gon). Concave polygons may produce inverted triangles;
    /// ear-clipping is the planned follow-up upgrade (same API, no test changes).
    size_t triangulateFacesByMask(in bool[] mask, uint[]* faceOriginOut = null) {
        if (mask.length != faces.length) return 0;

        // PolyVertex remap, mechanism (b): triangulation changes arity — each
        // n-gon splits into (n-2) triangles; each triangle corner comes from a
        // specific OLD face corner.
        const bool remapUv = hasPolyVertexMap();
        const uint[] oldFaceLoop = remapUv ? captureFaceLoop() : null;
        uint[] oldLoopOfNewLoop;

        uint[][] newFaces;
        bool[]   newSubpatch;
        int[]    newOrder;
        uint[]   newMaterial;
        uint[]   newPart;
        uint[]   faceOrigin;   // faceOrigin[new_fi] = original fi

        size_t changed = 0;

        foreach (fi; 0 .. faces.length) {
            auto f   = faces[fi];
            bool sub = isFaceSubpatch(fi);
            int  ord = (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
            uint mat = (fi < faceMaterial.length       ? faceMaterial[fi]       : 0u);
            uint prt = (fi < facePart.length           ? facePart[fi]           : 0u);

            if (!mask[fi] || f.length <= 3) {
                // Pass through untouched.
                newFaces    ~= f.dup;
                newSubpatch ~= sub;
                newOrder    ~= ord;
                newMaterial ~= mat;
                newPart     ~= prt;
                faceOrigin  ~= cast(uint)fi;
                if (remapUv)
                    foreach (c; 0 .. f.length)
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop,
                                                             cast(uint)fi,
                                                             cast(uint)c);
            } else {
                // Fan from vertex 0: [f[0], f[i], f[i+1]] for i = 1 .. n-2.
                ++changed;
                for (uint i = 1; i + 1 < f.length; ++i) {
                    newFaces    ~= [f[0], f[i], f[i + 1]];
                    newSubpatch ~= sub;
                    newOrder    ~= ord;
                    newMaterial ~= mat;
                    newPart     ~= prt;
                    faceOrigin  ~= cast(uint)fi;
                    if (remapUv) {
                        // Triangle corners map to old corners 0, i, i+1 of fi.
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, 0u);
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, i);
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, i + 1);
                    }
                }
            }
        }

        if (changed == 0) return 0;

        faces              = newFaces;
        setFaceSubpatchFrom(newSubpatch);
        faceSelectionOrder = newOrder;
        faceMaterial       = newMaterial;
        facePart           = newPart;
        if (remapUv) remapPolyVertexMaps(oldLoopOfNewLoop);
        clearFaceSelectionResize();
        rebuildEdges();
        clearEdgeSelectionResize();
        compactUnreferenced();
        buildLoops();
        commitChange(MeshEditScope.Geometry);

        if (faceOriginOut !is null) *faceOriginOut = faceOrigin;
        return changed;
    }

    /// Return the vertex in `face` that is neither `va` nor `vb`.
    /// Returns `uint.max` on a degenerate face (both shared verts absent or
    /// the face has fewer than 3 corners).
    private static uint findNonSharedVertex(const uint[] face,
                                            uint va, uint vb) pure nothrow {
        foreach (v; face)
            if (v != va && v != vb) return v;
        return uint.max;
    }

    /// Build the edge-dissolve mask for `removeEdgesByMask` by scanning
    /// interior edges between masked faces and applying `accept`.
    ///
    /// When `matching` is true, uses a greedy matching (ascending edge index):
    /// once both faces of an accepted edge are consumed no further edge
    /// touching either face is accepted. This guarantees `removeEdgesByMask`
    /// never fuses more than two faces per component (safe for Quadruple).
    ///
    /// When `matching` is false, selects ALL interior edges satisfying the
    /// predicate, allowing multi-face coplanar-region merges (Detriangulate).
    private bool[] selectMergeEdges(in bool[] faceMask,
            bool delegate(uint edgeIdx, uint fA, uint fB) accept,
            bool matching) {
        // Build edge → up-to-2 adjacent MASKED faces. An edge whose second
        // slot stays -1 is a boundary of the masked region and is skipped.
        auto edgeFaces = buildEdgeFaces(faceMask);

        bool[] edgeMask = new bool[](edges.length);
        bool[] consumed = matching ? new bool[](faces.length) : null;

        foreach (ei; 0 .. edges.length) {
            ulong key = edgeKeyOrdered(edges[ei][0], edges[ei][1]);
            auto p = key in edgeFaces;
            if (p is null) continue;
            int fA = (*p)[0], fB = (*p)[1];
            if (fA < 0 || fB < 0) continue;               // boundary
            if (!accept(cast(uint)ei, cast(uint)fA, cast(uint)fB)) continue;
            if (matching && (consumed[fA] || consumed[fB])) continue;
            edgeMask[ei] = true;
            if (matching) { consumed[fA] = true; consumed[fB] = true; }
        }

        return edgeMask;
    }

    /// Pair adjacent triangles in the mask into convex coplanar quads where
    /// possible. The accept predicate requires BOTH:
    ///   1. Coplanarity: dot(normalA, normalB) > 0.999  (in-repo threshold)
    ///   2. Convexity: the merged 4-corner polygon projects convex in the
    ///      face-normal plane (all consecutive cross-products same-sign).
    /// Uses a greedy matching so each triangle is consumed at most once.
    /// Unmatchable or non-convex/non-coplanar triangles stay as-is.
    /// Returns the number of edges dissolved.
    size_t quadrupleFacesByMask(in bool[] mask) {
        if (mask.length != faces.length) return 0;
        import math : cross, dot, normalize;

        bool accept(uint edgeIdx, uint fA, uint fB) {
            if (faces[fA].length != 3 || faces[fB].length != 3) return false;
            Vec3 nA = faceNormal(fA);
            Vec3 nB = faceNormal(fB);
            if (dot(nA, nB) <= 0.999f) return false;       // not coplanar

            // Find the 4 corners of the merged quad in boundary-walk order.
            uint va = edges[edgeIdx][0], vb = edges[edgeIdx][1];
            uint vp = findNonSharedVertex(faces[fA], va, vb);
            uint vq = findNonSharedVertex(faces[fB], va, vb);
            if (vp == uint.max || vq == uint.max) return false;

            // Quad in removeEdgesByMask walk order: [vp, va, vq, vb].
            Vec3 p0 = vertices[vp], p1 = vertices[va],
                 p2 = vertices[vq], p3 = vertices[vb];
            Vec3 n  = normalize(nA + nB);

            // Reject degenerate edges.
            Vec3 e0 = p1 - p0, e1 = p2 - p1, e2 = p3 - p2, e3 = p0 - p3;
            if (e0.length < 1e-6f || e1.length < 1e-6f ||
                e2.length < 1e-6f || e3.length < 1e-6f) return false;

            // All four consecutive cross-products must align with n (convexity).
            float c0 = dot(cross(e0, e1), n);
            float c1 = dot(cross(e1, e2), n);
            float c2 = dot(cross(e2, e3), n);
            float c3 = dot(cross(e3, e0), n);
            const float eps = 1e-5f;
            return (c0 > -eps && c1 > -eps && c2 > -eps && c3 > -eps) ||
                   (c0 <  eps && c1 <  eps && c2 <  eps && c3 <  eps);
        }

        bool[] edgeMask = selectMergeEdges(mask, &accept, true /* matching */);
        return removeEdgesByMask(edgeMask);
    }

    /// Merge adjacent coplanar faces in the mask into n-gons by dissolving
    /// every interior edge whose two incident faces satisfy
    /// dot(normalA, normalB) > 0.999 (the in-repo ExEdge.coplanar threshold).
    /// Non-coplanar neighbours and boundary edges are left untouched.
    /// Returns the number of edges dissolved.
    ///
    /// v1 restriction: `removeEdgesByMask` does not dissolve 2-valent /
    /// collinear boundary vertices that may survive on the merged n-gon when
    /// a coplanar region is only partially dissolved. Tested cases (cube /
    /// quad round-trips) have no such interior verts; the `dissolveDegree2Verts`
    /// cleanup is a documented follow-up.
    size_t detriangulateFacesByMask(in bool[] mask) {
        if (mask.length != faces.length) return 0;
        import math : dot;

        bool accept(uint /*edgeIdx*/, uint fA, uint fB) {
            return dot(faceNormal(fA), faceNormal(fB)) > 0.999f;
        }

        bool[] edgeMask = selectMergeEdges(mask, &accept, false /* region */);
        return removeEdgesByMask(edgeMask);
    }

    /// Merge the masked faces into one polygon per connected group by dissolving
    /// EVERY interior edge shared by two masked faces, regardless of coplanarity
    /// (selection is the only criterion). Boundary edges (one masked neighbour) are
    /// kept. Disjoint masked groups each collapse to their own boundary n-gon.
    /// Returns the number of edges dissolved.
    ///
    /// Unlike `detriangulateFacesByMask`, no coplanarity criterion is applied and
    /// there is NO whole-mesh fallback: an empty mask dissolves nothing and
    /// returns 0.
    ///
    /// v1 restrictions (inherited from `removeEdgesByMask`): collinear 2-valent
    /// boundary vertices on the merged n-gon are NOT removed (e.g. merging two
    /// coplanar quads sharing one edge yields a 6-corner n-gon, not a 4-corner
    /// rectangle); concave / non-coplanar / non-simply-connected (holed) selections
    /// produce a single boundary walk that may be non-planar or self-intersecting.
    size_t mergeFacesByMask(in bool[] mask) {
        if (mask.length != faces.length) return 0;
        bool acceptAll(uint, uint, uint) { return true; }
        bool[] edgeMask = selectMergeEdges(mask, &acceptAll, false /* region */);
        return removeEdgesByMask(edgeMask);
    }

    /// Edge Extrude: shift each selected edge outward along the average normal
    /// of its neighbor polygon(s) by `extrude`, inset the neighbor polygon(s) by
    /// `width` within their planes, and bridge with new faces. Boundary edges use
    /// the single neighbor normal. Endpoints shared by multiple selected edges are
    /// welded into one ridge vertex. Returns the number of edges extruded.
    /// Caller must refresh GPU + caches afterward. `mask.length == edges.length`.
    ///
    /// Face-centric construction (see doc/edge_extrude_plan.md §1.4): build the
    /// final ridgeVert[v] and insetVert[(v,f)] maps FIRST (averaging shared-corner
    /// in-plane directions), then do ONE rewrite pass per affected face so two
    /// selected edges that share a corner cannot race on faces[fi].
    size_t extrudeEdgesByMask(in bool[] mask, float extrude, float width) {
        import math : Vec3, cross, dot, normalize;
        import std.math : acos, sin, abs;
        import std.algorithm : clamp;
        static float clampf(float x, float lo, float hi) { return clamp(x, lo, hi); }
        if (mask.length != edges.length) return 0;
        // (Near-)zero inset width ⇒ NO-OP for the whole operation, regardless of
        // extrude: with no inset there is no shrink room for the bridge faces, so
        // the inset vertices would coincide with the original endpoints and the
        // kernel would emit degenerate faces (repeated/duplicate verts, zero-area
        // sides). The reference modeler no-ops here. Guard EARLY, before any
        // vertex/face construction, so nothing degenerate is ever emitted.
        // (Subsumes the old extrude==0 && width==0 identity no-op.)
        if (width < 1e-6f) return 0;

        // --- Mesh-edit tracker (mesh_edit_delta) — Phase 2 capture. Inert unless
        //     a batch is open (commitEdit opens one around the committed re-run;
        //     the interactive preview drag runs batchless ⇒ zero cost). The
        //     addVertex appends (ridge/inset/chamfer/along) self-log AddVerts via
        //     the Class-P hook, and the tail compactUnreferenced self-logs
        //     RemoveVerts+Reindex via the Class-R hook. This kernel records the
        //     parts NOT covered by those primitive hooks:
        //       * the in-place ReshapeFaces of pre-existing neighbour/side faces
        //         (the `faces[fi] = …` rewrites repoint corners at new insets),
        //       * the bridge/cap AddFaces (appended via `faces ~=`, NOT addFace,
        //         so not auto-logged),
        //       * the edge-selection delta (endpoint-keyed): the kernel clears
        //         edge selection in compaction and re-derives the ridge, so revert
        //         must restore the ORIGINAL selected edges.
        const bool recExtrude = editRecorder_ !is null;
        // Pre-extrude selected edges captured BY VERTEX-INDEX ENDPOINT PAIR (edge
        // indices are unstable across the rebuild; endpoints in pre-extrude space
        // are what revert restores). Flat [a0,b0, a1,b1, …].
        uint[] preEdgeSelEnds;
        if (recExtrude) {
            foreach (i; 0 .. edges.length) {
                if (i < edgeMarks.length && (edgeMarks[i] & Marks.Select)) {
                    preEdgeSelEnds ~= edges[i][0];
                    preEdgeSelEnds ~= edges[i][1];
                }
            }
        }

        // --- Edge → (≤2 faces) adjacency, one pass (no O(E×F) scan). Same idiom
        //     as removeEdgesByMask: first occurrence → slot 0, second distinct
        //     face → slot 1; a 3rd+ face / self-doubled edge is ignored.
        auto edgeFaces = buildEdgeFaces();

        // --- Mesh-boundary vertices: a vertex incident to ANY edge with only one
        //     adjacent face sits on the open boundary of the surface. A free end
        //     that lands on the open boundary is NOT fully surrounded by faces, so
        //     its corner gap is already closed by the ridge bridge meeting the
        //     boundary — it needs NO triangle cap (the reference emits none there).
        //     A fully-interior free end (e.g. a cube corner, or a plane center) is
        //     ringed by faces and DOES need its corner capped.
        bool[uint] onMeshBoundary;
        foreach (key, fp; edgeFaces) {
            if (fp[1] != -1) continue;        // interior edge — both verts unflagged here
            uint a = cast(uint)(key >> 32);
            uint b = cast(uint)(key & 0xffffffffUL);
            onMeshBoundary[a] = true;
            onMeshBoundary[b] = true;
        }
        bool isOnMeshBoundary(uint v) { return (v in onMeshBoundary) !is null; }

        // --- Gather the selected, extrudable edges (≥1 adjacent face). Snapshot
        //     their endpoints + neighbor faces NOW (original index space) — the
        //     kernel finishes all geometry before any rebuildEdges.
        struct ExEdge { uint va, vb; int fA, fB; Vec3 ne; bool coplanar; }
        ExEdge[] exEdges;
        foreach (i; 0 .. edges.length) {
            if (!mask[i]) continue;
            uint va = edges[i][0], vb = edges[i][1];
            auto p = edgeKeyOrdered(va, vb) in edgeFaces;
            if (p is null) continue;
            int fA = (*p)[0], fB = (*p)[1];
            if (fA == -1) continue;   // unreferenced edge — not extrudable

            // §1.1 per-edge averaged normal (the Extrude direction).
            //     `coplanar` records whether the two neighbour faces are flat
            //     (their normals point the same way, dot ≈ 1). A flat-embedded
            //     selected edge — one whose surrounding region is a single plane
            //     (e.g. a loop edge lying inside a cap face) — must NOT spawn a
            //     perpendicular in-plane inset band; the reference lifts it
            //     straight to the ridge and fans the flat region in. This flag
            //     is consumed at SHARED (welded) corners to switch their inset
            //     direction from perpendicular to face-aware (boundary-edge),
            //     so the corner insets only along its incident NON-selected
            //     edges — matching the reference's cap re-tessellation. (Free
            //     ends already use the face-aware path unconditionally.)
            Vec3 ne;
            bool coplanar = false;
            if (fB == -1) {
                ne = faceNormal(cast(uint)fA);                 // boundary edge
            } else {
                Vec3 nA = faceNormal(cast(uint)fA);
                Vec3 nB = faceNormal(cast(uint)fB);
                Vec3 sum = nA + nB;
                if (sum.length < 1e-6f)
                    ne = faceNormal(cast(uint)(fA < fB ? fA : fB)); // opposed → lower-index fallback
                else
                    ne = normalize(sum);
                coplanar = dot(nA, nB) > 0.999f;
            }
            exEdges ~= ExEdge(va, vb, fA, fB, ne, coplanar);
        }
        if (exEdges.length == 0) return 0;

        // --- Per-endpoint selected-edge incidence (needed below to choose the
        //     weld vs per-face behavior at shared corners). An endpoint incident
        //     to exactly ONE selected edge is a *free end*; ≥2 is a shared corner
        //     (chain joint / fan / loop) where the reference welds geometry.
        int[uint] selEdgeCount;
        foreach (ref e; exEdges) {
            selEdgeCount.update(e.va, () => 1, (ref int c) { ++c; });
            selEdgeCount.update(e.vb, () => 1, (ref int c) { ++c; });
        }
        bool isFreeEnd(uint v) { auto p = v in selEdgeCount; return p !is null && *p == 1; }
        bool isShared(uint v) { auto p = v in selEdgeCount; return p !is null && *p >= 2; }

        // --- Boundary chamfer ends. The reference treats a BOUNDARY edge (exactly
        //     one adjacent face F) entirely differently from an interior edge: it
        //     IGNORES the extrude amount (no outward lift, no ridge, no bridge) and
        //     emits a width-only CHAMFER. Each endpoint v of such an edge is
        //     DISSOLVED into TWO inset verts:
        //       topInset       = v + width · (in-plane inward dir of F)   [§1.3]
        //       antiNormalInset = v − width · faceNormal(F)
        //     F replaces the dissolved edge with the topInset edge (stays a quad —
        //     handled by the affected-face rewrite below). Every OTHER face
        //     incident to v replaces its dissolved corner with BOTH insets in
        //     winding order (quad → 5-gon). The chamfer edge topInset–antiNormalInset
        //     lies on the open boundary; no bridge / cap is emitted.
        //
        //     A *boundary chamfer end* is a FREE end (one selected edge) whose
        //     single selected edge is a boundary edge. Shared / chain corners on a
        //     boundary edge are out of scope (handled best-effort by the existing
        //     welded-ridge path). We record per end its neighbour face F and the
        //     anti-normal inset vert; the in-plane topInset reuses insetVert[(v,F)]
        //     materialised in Pass 2.
        int[uint] chamferNeighborFace;     // boundary chamfer end v → its sole face F
        foreach (ref e; exEdges) {
            if (e.fB != -1) continue;       // interior edge — not a boundary chamfer
            if (isFreeEnd(e.va)) chamferNeighborFace[e.va] = e.fA;
            if (isFreeEnd(e.vb)) chamferNeighborFace[e.vb] = e.fA;
        }
        bool isChamferEnd(uint v) { return (v in chamferNeighborFace) !is null; }

        // --- Pass 1: welded ridge vertex per original endpoint. The ridge is
        //     displaced along the average of the DISTINCT neighbour-face normals
        //     of every selected edge incident to v (§1.4.1). Deduping by face id
        //     matters at shared corners: two co-incident selected edges that
        //     border the SAME neighbour face must count that face once, otherwise
        //     it is double-weighted and skews the direction. For a free end the
        //     single edge's two neighbour faces are already distinct, so this is
        //     identical to summing the per-edge averaged normal there (no
        //     single-edge regression).
        Vec3[uint] ridgeAccum;            // Σ distinct neighbour-face normals
        bool[ulong] ridgeFaceSeen;        // (v<<32|fi) → already counted at v
        void accumRidgeFace(uint v, int fi) {
            if (fi < 0) return;
            ulong fk = (cast(ulong)v << 32) | cast(uint)fi;
            if (fk in ridgeFaceSeen) return;
            ridgeFaceSeen[fk] = true;
            Vec3 nf = faceNormal(cast(uint)fi);
            ridgeAccum.update(v, () => nf, (ref Vec3 acc) { acc = acc + nf; });
        }
        foreach (ref e; exEdges) {
            accumRidgeFace(e.va, e.fA); accumRidgeFace(e.va, e.fB);
            accumRidgeFace(e.vb, e.fA); accumRidgeFace(e.vb, e.fB);
        }
        uint[uint] ridgeVert;
        foreach (v, acc; ridgeAccum) {
            // Boundary chamfer ends are NOT lifted — they get no ridge vert (the
            // chamfer ignores extrude). Their bridge/cap geometry is skipped below.
            if (isChamferEnd(v)) continue;
            // Mesh-robustness fix (fuzz-found): at extrude≈0 the ridge vertex
            // lands EXACTLY on `vertices[v]` regardless of `dir` — minting a
            // fresh vertex there would be a coincident duplicate at the
            // original corner position (only reachable for a SHARED/interior
            // endpoint whose side faces still reference it elsewhere once
            // dissolved-and-rewritten, since a free end's original vertex is
            // otherwise fully orphaned and dropped by compaction). REUSE the
            // original vertex id instead of appending a new one; every
            // downstream reader goes through `ridgeVert[v]`, so this is
            // transparent to the bridge/cap construction below.
            if (abs(extrude) < 1e-6f) { ridgeVert[v] = v; continue; }
            Vec3 dir = (acc.length < 1e-6f) ? Vec3(0, 1, 0) : normalize(acc);
            ridgeVert[v] = addVertex(vertices[v] + dir * extrude);
        }

        // --- Pass 2: inset vertex per (endpoint v, incident neighbor face f).
        //     §1.3 in-plane inward direction; when several selected edges meet at
        //     v and border the SAME face, average their inward dirs (renormalize)
        //     so the shared corner stays continuous and only ONE inset vert is
        //     made in that face (§1.4.2).
        Vec3[ulong] insetAccum;           // key = (v<<32)|fi → Σ inward dir
        // Face-aware (along-incident-edge) insets clamp their offset so the inset
        //     can never travel PAST the far vertex of the incident non-selected
        //     edge — when `width` ≥ that edge's length the reference bumps the
        //     inset into the far vertex and stops (it does NOT overshoot and
        //     self-intersect). We record, per (v,fi) inset key, the smallest
        //     incident-edge length contributing a face-aware direction there; the
        //     offset length is clamped to it at materialisation time. Keys with no
        //     face-aware contribution (the perpendicular `inwardDir` path, which
        //     has no well-defined far vertex along its direction) carry no cap and
        //     are left unclamped.
        float[ulong] insetClampLen;       // key = (v<<32)|fi → min face-aware far dist
        // Task 0313: alongside the clamp LENGTH, remember WHICH existing vertex
        //     sits at that far distance. When the clamp actually saturates, the
        //     landing position is (up to fp rounding) exactly that vertex's own
        //     position — materialisation reuses its id instead of minting a
        //     coincident duplicate (see the weld pass below). A key that
        //     receives a SECOND clamp contribution (two selected edges folding
        //     their face-aware direction into the same shared corner) is marked
        //     ambiguous: the accumulated direction is then a blend of two
        //     distinct far vertices' directions, so the clamped landing is not
        //     guaranteed to coincide with either one — that key keeps the
        //     general (unwelded) addVertex path.
        uint[ulong]  insetClampFarVert;   // key → vertex id at the min far dist
        bool[ulong]  insetClampAmbiguous; // key → ≥2 clamp contributions folded in
        void accumInset(uint v, int fi, Vec3 d) {
            ulong k = (cast(ulong)v << 32) | cast(uint)fi;
            insetAccum.update(k, () => d, (ref Vec3 acc) { acc = acc + d; });
        }
        void recordClamp(uint v, int fi, float len, uint farVert) {
            ulong k = (cast(ulong)v << 32) | cast(uint)fi;
            if (auto p = k in insetClampLen) {
                insetClampAmbiguous[k] = true;
                if (len < *p) { *p = len; insetClampFarVert[k] = farVert; }
            } else {
                insetClampLen[k] = len;
                insetClampFarVert[k] = farVert;
            }
        }
        // In-plane inward direction at endpoint v of edge (va,vb) within face fi.
        Vec3 inwardDir(uint va, uint vb, int fi) {
            Vec3 t  = normalize(vertices[vb] - vertices[va]);
            Vec3 nf = faceNormal(cast(uint)fi);
            Vec3 d  = cross(nf, t);
            if (d.length < 1e-6f) return Vec3(0, 0, 0);
            d = normalize(d);
            // Flip toward the face centroid.
            auto f = faces[fi];
            Vec3 c = Vec3(0, 0, 0);
            foreach (vid; f) c = c + vertices[vid];
            c = c * (1.0f / cast(float)f.length);
            Vec3 mid = (vertices[va] + vertices[vb]) * 0.5f;
            if (dot(d, c - mid) < 0.0f) d = -d;
            return d;
        }
        // Face-aware inset direction at a single endpoint `v` (one endpoint of the
        //     extruded edge whose OTHER endpoint is `other`) within neighbour face
        //     fi. The reference modeler insets a dissolved free-end corner along the
        //     incident NON-EXTRUDED boundary edge of that face — i.e. toward the
        //     face's other vertex sharing a boundary edge at v — IN THAT FACE'S OWN
        //     PLANE. When the surrounding faces are coplanar with the neighbour face
        //     this boundary edge is perpendicular to the extruded edge inside the
        //     plane, so it reduces to the old cross-product inset (one shared point,
        //     no regression). When they are NOT coplanar (e.g. vertical side faces
        //     around a cut corner) the boundary edge dives out of the neighbour
        //     plane, folding the inset onto the side face — exactly what the
        //     reference does. Returns Vec3(0) if no distinct boundary edge is found
        //     (caller falls back to the perpendicular inwardDir).
        Vec3 boundaryEdgeDir(uint v, uint other, int fi, out float farLen, out uint farVert) {
            farLen = 0;
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                if (f[k] != v) continue;
                uint prev = f[(k + f.length - 1) % f.length];
                uint next = f[(k + 1) % f.length];
                // The non-extruded boundary edge is the one whose far endpoint is
                // NOT the extruded edge's other endpoint.
                uint far = (prev == other) ? next : prev;
                Vec3 d = vertices[far] - vertices[v];
                if (d.length < 1e-6f) return Vec3(0, 0, 0);
                farLen = d.length;
                farVert = far;
                return normalize(d);
            }
            return Vec3(0, 0, 0);
        }
        // Set of SELECTED edges (the extrude loop) as ordered keys, so the
        //     shared-corner inset can tell whether a face's boundary edge at v is
        //     itself part of the loop. When BOTH of a neighbour face's boundary
        //     edges at v are selected — a *cap corner* (the face is an interior
        //     region wholly ringed by the loop at v, e.g. the sharp triangular
        //     top face at an acute loop corner, or the square top face of a
        //     top-loop) — there is no non-selected boundary edge to inset along;
        //     the reference offsets BOTH cap edges inward by `width` and lands the
        //     inset at the mitered intersection (offset along the inward bisector
        //     by width/sin(θ/2)). For a 90° cap corner this equals the sum of the
        //     two perpendicular `width` insets, so the cube top-loop stays
        //     byte-identical; only sharp/obtuse cap corners (where perpendicular
        //     summing overshoots) differ.
        bool[ulong] selEdgeKeys;
        foreach (i; 0 .. edges.length)
            if (mask[i]) selEdgeKeys[edgeKeyOrdered(edges[i][0], edges[i][1])] = true;
        bool isSelEdge(uint a, uint b) {
            return (edgeKeyOrdered(a, b) in selEdgeKeys) !is null;
        }
        // Mitered cap-corner inset at endpoint v inside face fi: offset both of
        //     fi's boundary edges at v inward (in-plane) by `width` and intersect.
        //     Returns the inset POSITION (not a direction) so the caller can use it
        //     directly. Geometrically this is v plus the inward bisector scaled by
        //     width/sin(half angle); it reduces to v + width·e1⊥ + width·e2⊥ at a
        //     right angle. Returns false if the corner is degenerate (collinear).
        //     Task 0321: on a QUAD, also reports the diagonally opposite corner
        //     (`farVert`) and its distance from `v` (`farLen`) — the natural
        //     stopping point of the mitered bisector, mirroring the far-vertex
        //     `boundaryEdgeDir` clamp below. The caller uses this to detect/weld
        //     an overshoot instead of letting the inset overshoot an existing
        //     vertex undetected (see the cap-miter convergence pass after Pass 1).
        //     Left at their `out` defaults (farVert=0, farLen=NaN — D zero-inits
        //     `out uint` but NOT `out float`) for non-quad faces (no well-defined
        //     single opposite corner); callers gate on `farLen > 1e-6f`, which is
        //     false for NaN, so the uninitialised farVert is never read.
        bool capMiterInset(uint v, int fi, out Vec3 pos, out uint farVert, out float farLen) {
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                if (f[k] != v) continue;
                uint prev = f[(k + f.length - 1) % f.length];
                uint next = f[(k + 1) % f.length];
                Vec3 e1 = vertices[prev] - vertices[v];
                Vec3 e2 = vertices[next] - vertices[v];
                if (e1.length < 1e-6f || e2.length < 1e-6f) return false;
                e1 = normalize(e1);
                e2 = normalize(e2);
                Vec3 bis = e1 + e2;
                if (bis.length < 1e-6f) return false;   // 180° — collinear
                bis = normalize(bis);
                float cosT = dot(e1, e2);
                float halfT = acos(clampf(cosT, -1.0f, 1.0f)) * 0.5f;
                float s = sin(halfT);
                if (s < 1e-6f) return false;
                pos = vertices[v] + bis * (width / s);
                if (f.length == 4) {
                    farVert = f[(k + 2) % 4];
                    farLen = (vertices[farVert] - vertices[v]).length;
                }
                return true;
            }
            return false;
        }
        // Inset direction at endpoint `v` of the extruded edge (va,vb) within
        //     neighbour face fi. A FREE END is dissolved corner-by-corner along its
        //     incident edges (face-aware, see boundaryEdgeDir). A SHARED corner on
        //     a FLAT-EMBEDDED edge (`coplanar`: its two neighbour faces are the same
        //     plane, so a perpendicular inset would carve an in-plane band the
        //     reference never makes) is ALSO dissolved face-aware — it insets only
        //     along its incident NON-selected boundary edges, so two coplanar
        //     neighbour faces sharing the same non-selected edge produce ONE inset
        //     (the (endpoint,position) weld below collapses them), and the flat
        //     region fans to the ridge. Any other endpoint (shared corner on a
        //     NON-coplanar edge — chain/fan/loop where the two neighbour faces bend)
        //     keeps the original perpendicular inset, so corner_fan/corner3/top_loop
        //     stay byte-identical.
        // Absolute inset positions for cap-miter corners (keyed (v<<32|fi)); when
        //     set, they OVERRIDE the direction-accumulated position at
        //     materialisation. Used at shared cap corners whose surrounding face is
        //     ringed by selected edges (no non-selected boundary edge to inset
        //     along) — there the inset is the mitered offset of the cap polygon.
        Vec3[ulong] insetPosOverride;
        // (v<<32|fi) keys whose inset took the NEW shared-corner face-aware or
        //     cap-miter path (NOT free-end / not coplanar, which kept their prior
        //     routing). A bridge touching such a key on a side is wound by
        //     orientability (emitBridgeFromFace) rather than the `ne` dot test,
        //     because the face-aware/mitered inset folds the inset edge enough to
        //     make the averaged-normal heuristic unreliable.
        bool[ulong] sharedFaceAwareInset;
        // Task 0321: (v<<32|fi) → diagonally-opposite far vertex / its distance,
        //     for cap-miter keys on a QUAD face only (see capMiterInset). Consumed
        //     by the cap-miter convergence pass after Pass 1 to clamp/weld an
        //     overshooting mitered inset instead of leaving it unclamped.
        uint[ulong]  capMiterFarVert;
        float[ulong] capMiterFarLen;
        Vec3 insetDirAt(uint v, uint va, uint vb, int fi, bool coplanar) {
            uint other = (v == va) ? vb : va;
            bool sharedOnly = isShared(v) && !isFreeEnd(v) && !coplanar;
            // SHARED corner extension: the reference dissolves a shared (welded)
            //     loop corner face-aware, the same way it does free ends — inset
            //     along the face's NON-selected boundary edge at v. When BOTH of
            //     the face's boundary edges at v are selected (a cap corner), there
            //     is no non-selected edge; record the mitered cap offset instead.
            //     A right-angle cap corner's miter equals the perpendicular sum, so
            //     axis-aligned cube cases (corner_fan/corner3/top_loop) are
            //     unchanged; only sharp/obtuse cap corners shift.
            if (isFreeEnd(v) || coplanar || isShared(v)) {
                auto f = faces[fi];
                // Identify the two boundary edges of fi at v.
                bool prevSel = false, nextSel = false, found = false;
                uint prev, next;
                foreach (k; 0 .. f.length) {
                    if (f[k] != v) continue;
                    prev = f[(k + f.length - 1) % f.length];
                    next = f[(k + 1) % f.length];
                    prevSel = isSelEdge(prev, v);
                    nextSel = isSelEdge(v, next);
                    found = true;
                    break;
                }
                if (found && prevSel && nextSel) {
                    // Cap corner — no non-selected boundary edge. Use the mitered
                    // cap-polygon offset (position override). Only meaningful for
                    // shared corners; free ends never have both boundary edges
                    // selected (their single edge is the only selected one).
                    Vec3 mp; uint capFar; float capFarLen;
                    if (capMiterInset(v, fi, mp, capFar, capFarLen)) {
                        ulong k = (cast(ulong)v << 32) | cast(uint)fi;
                        insetPosOverride[k] = mp;
                        if (sharedOnly) sharedFaceAwareInset[k] = true;
                        if (capFarLen > 1e-6f) {
                            capMiterFarVert[k] = capFar;
                            capMiterFarLen[k] = capFarLen;
                        }
                        // Direction is irrelevant (overridden); return a unit dir
                        // so accumInset stays well-formed.
                        return inwardDir(va, vb, fi);
                    }
                    // capMiter degenerate → fall through to perpendicular.
                } else {
                    float farLen; uint farVert;
                    Vec3 d = boundaryEdgeDir(v, other, fi, farLen, farVert);
                    if (d.length >= 1e-6f) {
                        // Clamp the inset so it stops at (never passes) the far
                        // vertex of this incident non-selected edge.
                        recordClamp(v, fi, farLen, farVert);
                        if (sharedOnly)
                            sharedFaceAwareInset[(cast(ulong)v << 32) | cast(uint)fi] = true;
                        return d;
                    }
                }
            }
            return inwardDir(va, vb, fi);
        }
        foreach (ref e; exEdges) {
            accumInset(e.va, e.fA, insetDirAt(e.va, e.va, e.vb, e.fA, e.coplanar));
            accumInset(e.vb, e.fA, insetDirAt(e.vb, e.va, e.vb, e.fA, e.coplanar));
            if (e.fB != -1) {
                accumInset(e.va, e.fB, insetDirAt(e.va, e.va, e.vb, e.fB, e.coplanar));
                accumInset(e.vb, e.fB, insetDirAt(e.vb, e.va, e.vb, e.fB, e.coplanar));
            }
        }
        // Per (v,face) inset vert, with a (endpoint, position) weld so that two
        //     selected edges meeting at a shared corner that inset that corner in
        //     the SAME direction (e.g. the two side faces flanking a vertical edge
        //     on a closed loop both push their shared top corner straight down the
        //     edge) collapse onto ONE vertex instead of emitting coincident
        //     duplicates. The weld key is (endpoint, quantised position); distinct
        //     in-plane insets at the same corner (e.g. the top-face inset vs the
        //     side-weld inset) stay separate because their positions differ.
        uint[ulong] insetVert;            // (v<<32|fi) → vertex id
        uint[string] insetPosWeld;        // "v|qx|qy|qz" → vertex id (coincident weld)
        import std.format : format;
        string weldKeyOf(uint v, Vec3 p) {
            return format("%u|%d|%d|%d", v,
                cast(long)(p.x * 1e5f + (p.x >= 0 ? 0.5f : -0.5f)),
                cast(long)(p.y * 1e5f + (p.y >= 0 ? 0.5f : -0.5f)),
                cast(long)(p.z * 1e5f + (p.z >= 0 ? 0.5f : -0.5f)));
        }
        // Task 0317: MUTUAL free-end overshoot guard. The far-vertex weld
        //     below (and its along-edge-inset sibling further down) is safe
        //     only when `farVertId` is a STABLE vertex that survives the op
        //     untouched (e.g. a cube's other corner). When TWO SELECTED EDGES
        //     each dissolve a free end that faces the OTHER edge's free end
        //     across one shared non-selected boundary edge of a common face
        //     (e.g. two OPPOSITE edges of one interior quad both selected —
        //     each free end's `boundaryEdgeDir` far vertex resolves to the
        //     OTHER edge's free end), an overshoot `width` makes BOTH corners
        //     weld onto EACH OTHER's original vertex. That is a MUTUAL swap,
        //     not a one-sided clamp: the two insets cross past one another,
        //     producing a self-intersecting "bowtie" face with 4 DISTINCT
        //     corners but zero net area (not caught by the <3-distinct-corner
        //     drop, since nothing repeats). Detect it up front — `farVertId`
        //     is itself a free end being dissolved by a DIFFERENT selected
        //     edge — and reroute BOTH directions through one shared MIDPOINT
        //     vertex instead of letting either reach the other's original
        //     position. Keyed by the unordered (v,far) pair so both corners'
        //     welds resolve to the identical id (no crossing, no coincident
        //     duplicate). Free ends of the SAME edge never collide here
        //     (`boundaryEdgeDir` already excludes the edge's own other
        //     endpoint), and shared/chain corners are not dissolved via this
        //     path, so single-edge cases (cube, octahedron, width_clamp) never
        //     see `isFreeEnd(farVertId)` true — byte-identical there.
        uint[ulong] mutualMeet;   // unordered (loV<<32|hiV) → shared meeting vert
        // Task 0321: positional twin of `mutualMeet`, keyed by the quantised
        //     midpoint itself rather than the (a,b) pair. A single face can
        //     produce more than one converging PAIR that geometrically meets at
        //     the SAME point — e.g. a quad's two diagonal cap-corner pairs
        //     (v0,v2) and (v1,v3) both cross at the face center — so a pure
        //     pair-keyed cache would mint two coincident "meeting" vertices for
        //     what is really one point. Check position first; only mint (and
        //     register both caches) when this exact point hasn't been produced
        //     by a different pair yet.
        uint[string] mutualMeetPos;
        uint mutualMeetVert(uint a, uint b) {
            uint lo = a < b ? a : b, hi = a < b ? b : a;
            ulong mk = (cast(ulong)lo << 32) | hi;
            if (auto p = mk in mutualMeet) return *p;
            Vec3 mid = (vertices[lo] + vertices[hi]) * 0.5f;
            string pk = weldKeyOf(uint.max, mid);   // sentinel v — position-only key
            if (auto pp = pk in mutualMeetPos) { mutualMeet[mk] = *pp; return *pp; }
            uint nv = addVertex(mid);
            mutualMeet[mk] = nv;
            mutualMeetPos[pk] = nv;
            return nv;
        }
        // Task fuzz-0321b: the shared meeting point for a converging QUAD's
        //     cap-miter corners (see `mutualMeetVertAt` below) is this face's
        //     own centroid (the existing `Mesh.faceCentroid` member, reused
        //     here rather than re-derived) instead of a per-diagonal
        //     midpoint. For a parallelogram (incl. the axis-aligned
        //     cube/square case) the two diagonals bisect each other AT the
        //     centroid, so this is bit-identical to the old per-diagonal
        //     midpoint there. For a non-parallelogram convex quad the two
        //     diagonal midpoints DIFFER — using either alone left the OTHER
        //     diagonal's pair converging to a second, distinct point, producing
        //     an `[a,b,a,b]` folded face (two non-adjacent corners coincident,
        //     not caught by the consecutive-only degenerate-face cleanup). The
        //     centroid is one point shared by both diagonals' corners, so all 4
        //     corners collapse onto the SAME vertex regardless of quad shape.
        // Positional twin of `mutualMeetVert` that lands at an explicit
        //     `meetPos` (rather than computing the (a,b) midpoint itself), so a
        //     caller can supply a face-level meeting point (see `faceCentroid`)
        //     shared by more than one pairwise `(a,b)` key. Shares the same
        //     `mutualMeet`/`mutualMeetPos` caches as `mutualMeetVert`, so two
        //     different diagonal pairs of one face that both resolve to the
        //     identical `meetPos` (bit-identical — both derive it via the same
        //     `faceCentroid(fi)` call) collapse onto ONE vertex.
        uint mutualMeetVertAt(uint a, uint b, Vec3 meetPos) {
            uint lo = a < b ? a : b, hi = a < b ? b : a;
            ulong mk = (cast(ulong)lo << 32) | hi;
            if (auto p = mk in mutualMeet) return *p;
            string pk = weldKeyOf(uint.max, meetPos);
            if (auto pp = pk in mutualMeetPos) { mutualMeet[mk] = *pp; return *pp; }
            uint nv = addVertex(meetPos);
            mutualMeet[mk] = nv;
            mutualMeetPos[pk] = nv;
            return nv;
        }
        // Pass 1 (task 0313): far-vertex-clamp welds. When the face-aware clamp
        //     above actually saturates (offset would otherwise overshoot) AND
        //     exactly one contribution defined this corner's far vertex (no
        //     shared-corner blend of two different far vertices), the clamped
        //     landing is — up to fp rounding — EXACTLY that existing vertex's
        //     position. Reuse its id directly instead of minting a coincident
        //     duplicate (the prior bug: same position, new index → a
        //     zero-area face + a winding flip once neighbouring faces are
        //     rewound around it). Registered BEFORE pass 2 so a coincidental
        //     unclamped inset that lands at the same quantised position welds
        //     onto this id too, rather than racing to mint its own duplicate
        //     (AA iteration order is unspecified).
        bool[ulong] weldedToFar;
        // Perf nit: whether ANY far-vertex overshoot clamp (this pass or its
        //     along-edge sibling further below) actually saturated. The
        //     winding-consistency safety net (task 0317, below) exists solely
        //     to reconcile faces whose local winding heuristic disagreed
        //     because of a saturating clamp/weld; when this stays false (the
        //     overwhelming common case — a batchless preview frame with a
        //     modest width/extrude) that pass's O(F) edgeUsers build + BFS is
        //     unconditionally a no-op and is skipped entirely (see gate below).
        bool anyOvershootSaturated = false;
        foreach (k, acc; insetAccum) {
            if (k in insetPosOverride) continue;     // cap-miter — absolute, no clamp
            auto cap = k in insetClampLen;
            if (cap is null) continue;
            if (k in insetClampAmbiguous) continue;   // blended direction — no single target
            float len = (acc * width).length;
            if (len <= *cap || len <= 1e-9f) continue; // did not actually saturate
            anyOvershootSaturated = true;
            uint v = cast(uint)(k >> 32);
            uint farVertId = insetClampFarVert[k];
            if (isFreeEnd(farVertId)) {
                // Task 0317: mutual dissolve — reroute both directions onto
                // one shared midpoint vertex (see guard comment above).
                uint mv = mutualMeetVert(v, farVertId);
                insetVert[k] = mv;
                insetPosWeld[weldKeyOf(v, (vertices[v] + vertices[farVertId]) * 0.5f)] = mv;
                weldedToFar[k] = true;
                continue;
            }
            Vec3 p = vertices[v] + normalize(acc) * (*cap);
            insetVert[k] = farVertId;
            insetPosWeld[weldKeyOf(v, p)] = farVertId;
            weldedToFar[k] = true;
        }
        // Pass 1b (task 0321): cap-miter convergence weld. The cap-miter path
        //     (a shared corner whose face is fully ringed by selected edges — no
        //     non-selected boundary edge to inset along, e.g. every corner of
        //     every face when ALL edges of a closed mesh are selected) carries an
        //     ABSOLUTE position override and, until now, no overshoot clamp at
        //     all: an aggressive `width` can push the mitered inset straight
        //     through — or exactly onto — the face's diagonally opposite corner
        //     with no weld, minting a coincident duplicate. Worse, on a QUAD
        //     whose every corner is a cap corner (the fully-selected-loop case),
        //     that opposite corner is ITSELF converging back along the same
        //     diagonal, not a fixed target — the identical "mutual dissolve"
        //     hazard task 0317 fixed for face-aware free-end insets, here
        //     triggered by full-loop selection instead of two opposing free ends.
        //
        //     `farVert` (the diagonally opposite corner, from capMiterInset) is
        //     itself ALSO a cap-miter key of the SAME face exactly when it has
        //     its own entry in `insetPosOverride` for (farVert, fi) — i.e. both
        //     diagonal corners are converging toward each other. Detect that and
        //     reroute BOTH directions through the shared midpoint vertex
        //     (`mutualMeetVert`), using the SUM of both corners' own offsets
        //     against the shared distance so an asymmetric pair (uneven corner
        //     angles) is still caught the moment their reaches would meet or
        //     cross — not only once either one alone reaches the far corner.
        //     When `farVert` is NOT itself converging (a stable vertex, or a
        //     boundary-edge-dissolved corner in a partially-selected face), fall
        //     back to the plain one-sided task-0313 clamp: stop at — and reuse —
        //     `farVert`'s own id once this corner's own offset alone reaches it.
        //
        //     Non-quad cap corners (no `capMiterFarVert` entry) and any width
        //     modest enough that neither branch triggers keep the prior
        //     unclamped `insetPosOverride` position untouched in Pass 2 below —
        //     byte-identical there.
        foreach (k, farVertId; capMiterFarVert) {
            float farLen = capMiterFarLen[k];
            if (farLen <= 1e-6f) continue;
            uint v  = cast(uint)(k >> 32);
            uint fi = cast(uint)(k & 0xffffffffUL);
            float offLen = (insetPosOverride[k] - vertices[v]).length;
            ulong farKey = (cast(ulong)farVertId << 32) | fi;
            if (auto farOverride = farKey in insetPosOverride) {
                // Mutual: farVert is also a cap corner of this same face,
                // converging back along the same diagonal. Meet at the face's
                // OWN centroid (see faceCentroid) rather than this diagonal's
                // midpoint, so the OTHER diagonal pair — if it converges too —
                // collapses onto the identical vertex instead of a second,
                // distinct one (fuzz-0321b).
                float farOffLen = (*farOverride - vertices[farVertId]).length;
                if (offLen + farOffLen < farLen - 1e-6f) continue;   // not yet meeting
                anyOvershootSaturated = true;
                Vec3 meetPos = faceCentroid(fi);
                uint mv = mutualMeetVertAt(v, farVertId, meetPos);
                insetVert[k] = mv;
                insetPosWeld[weldKeyOf(v, meetPos)] = mv;
                weldedToFar[k] = true;
            } else {
                // One-sided: farVert is a stable/independently-handled corner.
                if (offLen < farLen - 1e-6f) continue;   // did not reach it
                anyOvershootSaturated = true;
                insetVert[k] = farVertId;
                insetPosWeld[weldKeyOf(v, vertices[farVertId])] = farVertId;
                weldedToFar[k] = true;
            }
        }
        // TODO(fuzz): n-GON (n>=5) cap-miter corners carry NO overshoot clamp
        //     at all (`capMiterInset` only reports a diagonally-opposite far
        //     vertex for QUADS, n==4, handled by Pass 1b above); their
        //     `insetPosOverride` position flows unclamped straight to Pass 2.
        //     TRIANGLES need no clamp — with only 3 corners in a cyclic face,
        //     any two that end up coincident are, by construction, ADJACENT
        //     (a 3-cycle has no non-adjacent pair), so the plain
        //     consecutive-duplicate degenerate-face cleanup below already
        //     catches a fully- or partially-collapsed triangle cleanly
        //     (confirmed empirically: a regular AND a heavily scalene/100:1
        //     octahedron, all edges selected, stay valid up to width=50 on a
        //     unit-scale mesh — see test 19 in test_edge_extrude.d).
        //
        //     n>=5 DOES have non-adjacent corner pairs (e.g. a pentagon's
        //     corners 0 and 2), so an `[...,a,...,a,...]` fold the
        //     consecutive-only cleanup misses is theoretically reachable —
        //     but INVESTIGATED AND NOT YET REPRODUCED via realistic
        //     (irregular, non-symmetric) geometry: two DISTINCT corners'
        //     raw mitered rays are fixed lines whose parametrisation is
        //     LOCKED to the same single `width` value (position(width) =
        //     v + (width/sin(halfAngle))·bisector), so for them to land at
        //     the exact same point at the SAME width is a 2-equations/
        //     1-unknown system — generically UNSATISFIABLE except at an
        //     exact/near-symmetric critical width (unlike the quad bug this
        //     mirrors, which was FORCED by Pass 1b's own approximate
        //     trigger-and-weld formula, not by raw rays naturally crossing).
        //     Confirmed empirically: an irregular pentagon AND an irregular
        //     hexagon (interior faces of a tall open prism, isolating this
        //     path from the far-vertex clamp above — see the "tall prism"
        //     construction tried during this investigation) stayed
        //     coincidence-free at width 0.9 through 50 (three orders of
        //     magnitude past their ~unit-scale critical radius). A regular
        //     (or near-regular) n>=5 primitive at OR VERY NEAR its exact
        //     critical width remains an unproven but plausible latent gap.
        //
        //     A real fix needs a per-FACE (not per-pair, since n>=5 has no
        //     single natural "opposite corner") convergence test — e.g. weld
        //     every cap-miter corner of a face onto that face's own centroid
        //     once the polygon's inward offset has collapsed — plus a
        //     regression fixture that actually demonstrates the fold (a
        //     regular pentagon/hexagon at its exact analytic critical width
        //     is the most promising unexplored angle; every irregular
        //     construction tried here passed even without any clamp). Given
        //     that, this is left as a follow-up rather than shipped as an
        //     unverified change.
        //
        //     Separately (mesh-robustness batch, fuzz-found): a standalone
        //     open n-gon (e.g. a lone pentagon face, or any mesh boundary
        //     loop) whose corners are SHARED (>=2 selected edges, not free
        //     ends/chamfer) rather than interior, run through an overshoot
        //     width, used to mint coincident duplicate vertices at the
        //     ORIGINAL corner positions at extrude≈0. Fixed above (Pass 1):
        //     the ridge-vertex construction now REUSES the original vertex
        //     id at extrude≈0 instead of appending a coincident one — see
        //     `ridgeVert[v] = v` in Pass 1. Unrelated to the cap-miter gap
        //     described above (that one is `insetPosOverride`/
        //     `capMiterInset`-specific and still open).
        // Pass 2: the general accumulated-direction inset (unclamped, or
        //     clamped-but-ambiguous, or cap-miter override), same
        //     (endpoint, quantised position) weld as before so two selected
        //     edges meeting at a shared corner that inset it in the SAME
        //     direction collapse onto ONE vertex instead of emitting
        //     coincident duplicates.
        foreach (k, acc; insetAccum) {
            if (k in weldedToFar) continue;
            uint v  = cast(uint)(k >> 32);
            // Each contributing selected edge insets this corner by `width` along
            //     its own unit inward dir; when several edges share (v,face) the
            //     offsets ADD (they do NOT average-and-renormalize). For a single
            //     contribution `acc` is already a unit vector ⇒ width*acc, i.e.
            //     identical to the single-edge inset (no single-edge regression).
            Vec3 off = acc * width;
            // Face-aware insets clamp so they cannot pass the far vertex of their
            //     incident non-selected edge (offset length ≤ that edge length).
            //     Keys with no face-aware contribution carry no cap (unclamped).
            if (auto cap = k in insetClampLen) {
                float len = off.length;
                if (len > *cap && len > 1e-9f) off = off * (*cap / len);
            }
            // Cap-miter corners carry an ABSOLUTE position override (the mitered
            //     offset of the cap polygon); it supersedes the direction-based
            //     offset entirely.
            Vec3 p = (k in insetPosOverride) ? insetPosOverride[k] : vertices[v] + off;
            string wk = weldKeyOf(v, p);
            if (auto wp = wk in insetPosWeld) { insetVert[k] = *wp; continue; }
            uint nv = addVertex(p);
            insetPosWeld[wk] = nv;
            insetVert[k] = nv;
        }

        // --- Per-edge chamfer inset verts. A boundary chamfer end v is DISSOLVED
        //     into ONE inset per incident face, but the insets live on the EDGES of
        //     v's fan: every boundary fan edge (v,far) — i.e. every edge at v EXCEPT
        //     the extruded edge (v,other) — gets a single inset vert
        //         v + width · normalize(vertices[far] − vertices[v])
        //     shared by the (≤2) faces flanking that edge. Each incident face then
        //     replaces its v corner with the two insets of ITS two boundary fan
        //     edges (winding order); the sole extruded-edge face F has only one
        //     boundary fan edge per endpoint, so it stays a quad (that single inset
        //     is F's topInset, already materialised as insetVert[(v,F)] in Pass 2 —
        //     we reuse it so F's edge weld is byte-stable). This generalises the old
        //     fixed topInset+antiNormal pair: on a flat axis-aligned chamfer the side
        //     face's outer fan edge runs along −normal(F), so its inset coincides
        //     with the former anti-normal vert and that case stays byte-identical;
        //     on a curved / multi-incident-face corner each face folds onto its own
        //     fan edge instead of all welding to one anti-normal point.
        //     Key = (v<<32)|far → inset vert id.
        uint[uint] chamferEndOther;        // chamfer end v → its extruded edge's other endpoint
        foreach (ref e; exEdges) {
            if (e.fB != -1) continue;
            if (isFreeEnd(e.va)) chamferEndOther[e.va] = e.vb;
            if (isFreeEnd(e.vb)) chamferEndOther[e.vb] = e.va;
        }
        uint[ulong] chamferEdgeInset;      // (v<<32)|far → inset vert
        foreach (v, fF; chamferNeighborFace) {
            uint other = chamferEndOther[v];
            // SEED the F-edge inset FIRST: F's single non-extruded boundary edge at v
            // already has its topInset materialised in Pass 2 (insetVert[(v,F)]). The
            // far vertex of that edge is the one boundaryEdgeDir used. Map it now so
            // the seam edge shared by F and a flanking side face reuses the topInset
            // (one vert, byte-stable weld) instead of spawning a coincident duplicate.
            {
                auto f = faces[fF];
                foreach (k; 0 .. f.length) {
                    if (f[k] != v) continue;
                    uint prev = f[(k + f.length - 1) % f.length];
                    uint next = f[(k + 1) % f.length];
                    uint farF = (prev == other) ? next : prev;
                    ulong fk = (cast(ulong)v << 32) | cast(uint)fF;
                    if (fk in insetVert)
                        chamferEdgeInset[(cast(ulong)v << 32) | farF] = insetVert[fk];
                    break;
                }
            }
            // Gather the distinct boundary fan edges at v (far ≠ other), across all
            // incident faces; the seam edge between two adjacent fan faces appears
            // twice but maps to one far vertex ⇒ one inset. The F seam edge is
            // already seeded above, so it is skipped here.
            foreach (fi; 0 .. faces.length) {
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    if (f[k] != v) continue;
                    uint prev = f[(k + f.length - 1) % f.length];
                    uint next = f[(k + 1) % f.length];
                    foreach (far; [prev, next]) {
                        if (far == other) continue;       // the extruded edge — no inset
                        ulong ek = (cast(ulong)v << 32) | far;
                        if (ek in chamferEdgeInset) continue;
                        Vec3 dir = vertices[far] - vertices[v];
                        if (dir.length < 1e-6f) continue;
                        chamferEdgeInset[ek] = addVertex(vertices[v] + normalize(dir) * width);
                    }
                }
            }
        }

        // --- Free-end classification (§5). selEdgeCount / isFreeEnd / isShared
        //     were computed above (needed for the ridge dedupe + inset weld).
        // An *interior* free end has two neighbor faces (its single selected edge
        // is interior). Only interior free ends split their side-face corner into
        // two insets + a triangle cap; a BOUNDARY free end (one neighbor face)
        // has only one inset, so it keeps its other faces intact (no split, no
        // cap) — the inset-gap quad already closes the geometry.
        bool[uint] interiorFreeEnd;
        foreach (ref e; exEdges) {
            if (e.fB == -1) continue;        // boundary edge — endpoints not interior
            if (isFreeEnd(e.va)) interiorFreeEnd[e.va] = true;
            if (isFreeEnd(e.vb)) interiorFreeEnd[e.vb] = true;
        }
        bool isInteriorFreeEnd(uint v) { return (v in interiorFreeEnd) !is null; }

        // --- Single face-centric rewrite pass over the NEIGHBOR faces. For each
        //     affected neighbor face, walk its corners once and replace each
        //     corner c that has an insetVert[(c,fi)] key. Race-free even when
        //     va,vb,vc all live in fi.
        bool[int] affectedFaces;
        foreach (ref e; exEdges) {
            affectedFaces[e.fA] = true;
            if (e.fB != -1) affectedFaces[e.fB] = true;
        }
        // Tracker: capture the BEFORE-image of every neighbour face this loop is
        // about to rewrite in place, then the AFTER-image once rewritten. The
        // affected-face set is computed here, inside the body (doc §2.1(c)); the
        // capture is O(faces-touched). Recorded as a ReshapeFaces entry.
        uint[]   nbrReshapeIdx;
        uint[][] nbrReshapeBefore;
        if (recExtrude) {
            foreach (fi, _; affectedFaces) {
                nbrReshapeIdx    ~= cast(uint)fi;
                nbrReshapeBefore ~= faces[fi].dup;
            }
        }
        foreach (fi, _; affectedFaces) {
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                ulong key = (cast(ulong)f[k] << 32) | cast(uint)fi;
                if (auto p = key in insetVert)
                    faces[fi][k] = *p;
            }
        }
        if (recExtrude && nbrReshapeIdx.length) {
            uint[][] nbrReshapeAfter;
            foreach (fi; nbrReshapeIdx) nbrReshapeAfter ~= faces[fi].dup;
            editRecorder_.recordReshapeFaces(nbrReshapeIdx, nbrReshapeBefore, nbrReshapeAfter);
        }

        // --- Free-end side-corner rewrite (§5.a/§5.b — the fix). Each free-end
        //     endpoint `v` must be removed from EVERY face that is NOT one of its
        //     extruded edge's neighbor faces (those non-neighbor "side" faces
        //     each have `v` as a single corner). the reference modeler replaces that corner with
        //     the endpoint's two inset verts so the side quad becomes a 5-gon,
        //     closing the gap that a bare dissolve would open.
        //
        //     We resolve the two insets from the two edges of the side face that
        //     meet at `v`: the incoming edge (prev,v) and outgoing edge (v,next)
        //     each coincide with one of the extruded edge's neighbor faces, so we
        //     look up which neighbor face shares that boundary edge and take its
        //     inset. The pair is then ordered to PRESERVE the side face's
        //     original winding (faceNormal backstop swaps the pair if it flips).
        //
        //     For each free end, record the per-neighbor-face inset vertex keyed
        //     by (v, neighborFace); the side-face rewrite below resolves which
        //     neighbor face shares a given boundary edge of the side face.
        uint[ulong] freeEndInsetByVF; // (v<<32|neighborFace) → inset vert
        uint[uint]  freeEndAlongVert; // free-end v → its along-edge inset vert (valence>3 only)
        foreach (ref e; exEdges) {
            void rec(uint v) {
                if (!isInteriorFreeEnd(v)) return;
                ulong kA = (cast(ulong)v << 32) | cast(uint)e.fA;
                freeEndInsetByVF[(cast(ulong)v << 32) | cast(uint)e.fA] = insetVert[kA];
                ulong kB = (cast(ulong)v << 32) | cast(uint)e.fB;
                freeEndInsetByVF[(cast(ulong)v << 32) | cast(uint)e.fB] = insetVert[kB];
            }
            rec(e.va);
            rec(e.vb);
        }
        // Set of (interior free-end vertex) → its 2 neighbor-face ids, for "is
        // this face a neighbor of v?" tests during the side-face scan.
        bool[ulong] isNeighborOf; // (v<<32|fi) → true
        foreach (ref e; exEdges) {
            void mark(uint v) {
                if (!isInteriorFreeEnd(v)) return;
                isNeighborOf[(cast(ulong)v << 32) | cast(uint)e.fA] = true;
                isNeighborOf[(cast(ulong)v << 32) | cast(uint)e.fB] = true;
            }
            mark(e.va);
            mark(e.vb);
        }
        // --- Along-edge inset for VALENCE>3 interior free ends (the back-fan
        //     closure). A valence-3 interior free end (e.g. a cube corner) has a
        //     SINGLE back face whose two boundary edges at v are BOTH the
        //     extruded edge's neighbor-face edges — the two perpendicular insets
        //     already span the gap, so a 5-gon + one triangle cap closes it (the
        //     valence-3 path, kept byte-identical below). A higher-valence
        //     interior free end (e.g. the center of a flat 2×2 plane) has back
        //     faces separated by INNER RIM edges that meet at v but are NOT
        //     neighbor-face edges; the two perpendicular insets do not reach
        //     those rim edges, leaving a gap. The reference closes it by
        //     dissolving v into a THIRD point — an inset along the edge axis,
        //     v + width·t̂ (t̂ = unit edge tangent pointing AWAY from the edge into
        //     the back fan) — used in place of v on every inner-rim boundary edge,
        //     plus a fan of triangles up to the ridge.
        //
        //     `needsAlong[v]` is true exactly when some back face of v has a
        //     boundary edge at v that is NOT a neighbor-face edge (i.e. v has an
        //     inner rim edge). For valence-3 free ends this is always false ⇒ no
        //     along-edge vert, no extra triangles ⇒ the cube path is unchanged.
        bool[uint] needsAlong;
        {
            // Map each interior free end to its single extruded edge's OTHER
            // endpoint so we can build the away-pointing tangent.
            uint[uint] freeEndOther;
            foreach (ref e; exEdges) {
                if (e.fB == -1) continue;
                if (isFreeEnd(e.va)) freeEndOther[e.va] = e.vb;
                if (isFreeEnd(e.vb)) freeEndOther[e.vb] = e.va;
            }
            bool isNeighborEdgeAt(uint v, uint a, uint b) {
                auto p = edgeKeyOrdered(a, b) in edgeFaces;
                if (p is null) return false;
                foreach (cand; [(*p)[0], (*p)[1]]) {
                    if (cand < 0) continue;
                    if ((cast(ulong)v << 32 | cast(uint)cand) in isNeighborOf)
                        return true;
                }
                return false;
            }
            // For each qualifying free end we also remember the FAR endpoint of its
            //     inner rim edge so the along-inset can be placed along that ACTUAL
            //     edge (face-aware fold), not merely along the extruded-edge tangent.
            uint[uint] alongFar;          // free-end v → inner-rim edge's far vertex
            foreach (fi; 0 .. faces.length) {
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    uint c = f[k];
                    if (!isInteriorFreeEnd(c)) continue;
                    if ((cast(ulong)c << 32 | cast(uint)fi) in isNeighborOf) continue; // not a back face
                    uint prev = f[(k + f.length - 1) % f.length];
                    uint next = f[(k + 1) % f.length];
                    // An inner rim edge at c is a boundary edge of this back face
                    // that is NOT one of the extruded edge's neighbor faces.
                    if (!isNeighborEdgeAt(c, prev, c)) {
                        needsAlong[c] = true;
                        if (c !in alongFar) alongFar[c] = prev;
                    }
                    if (!isNeighborEdgeAt(c, c, next)) {
                        needsAlong[c] = true;
                        if (c !in alongFar) alongFar[c] = next;
                    }
                }
            }
            // Materialize one along-edge inset vert per qualifying free end, placed
            //     `width` ALONG the inner rim edge (v → far). This folds the inset
            //     onto whatever face that edge bounds: when the rim edge lies in the
            //     neighbour plane (coplanar surroundings) the fold direction equals
            //     the extruded-edge tangent (no change); when it dives onto a
            //     non-coplanar side face the inset folds onto that side face — the
            //     reference's face-aware free-end inset.
            foreach (v, _; needsAlong) {
                Vec3 t;
                // Clamp the along-edge offset so it can never travel PAST the far
                //     vertex of the inner rim edge it folds along — identical to
                //     the face-aware boundaryEdgeDir clamp (recordClamp): when
                //     `width` ≥ that rim edge's length the reference bumps the
                //     inset into the far vertex and stops rather than overshooting
                //     and self-intersecting. The clamp length is the rim edge's
                //     own length, |alongFar − v|. The fallback extruded-tangent
                //     direction has no well-defined far vertex along it, so (like
                //     the perpendicular inwardDir path) it carries no cap.
                float offLen = width;
                bool weldToFar = false;
                uint farVertId;
                if (auto fp = v in alongFar) {
                    t = vertices[*fp] - vertices[v];
                    float farLen = t.length;
                    if (width > farLen) {
                        // Task 0313: the clamp saturated — `alongFar[v]` is a
                        // single, unambiguous far vertex (first-rim-edge-found,
                        // never overwritten — see the population loop above), so
                        // the landing coincides exactly with it. Reuse its id
                        // instead of minting a coincident duplicate.
                        offLen = farLen;
                        weldToFar = true;
                        farVertId = *fp;
                        anyOvershootSaturated = true;
                    }
                } else if (auto op = v in freeEndOther) {
                    t = vertices[v] - vertices[*op];   // fallback: extruded tangent
                } else continue;
                if (t.length < 1e-6f) continue;
                if (weldToFar) {
                    // Task 0317: the same mutual-dissolve hazard as the Pass 1
                    // face-aware clamp above can occur here too — guard it the
                    // same way (reroute to the shared midpoint vertex instead
                    // of welding onto another dissolving free end).
                    freeEndAlongVert[v] = isFreeEnd(farVertId)
                        ? mutualMeetVert(v, farVertId) : farVertId;
                    continue;
                }
                t = normalize(t);
                freeEndAlongVert[v] = addVertex(vertices[v] + t * offLen);
            }
        }
        // NOTE: gated on `freeEndAlongVert` (the MATERIALIZED map), not the
        //     `needsAlong` intent map above. The materialization loop has bail-out
        //     paths (`v` present in neither `alongFar` nor `freeEndOther`; or a
        //     degenerate near-zero tangent — e.g. an overshoot `width` clamped
        //     an unrelated inset vertex exactly onto `v`'s own position, via the
        //     face-corner-rewrite ordering: the back-face scan above can read a
        //     PRE-REWRITTEN face corner as an already-rewritten inset id from an
        //     earlier neighbour-face pass, spuriously flagging `needsAlong[v]`)
        //     that leave `needsAlong[v]` true with no corresponding
        //     `freeEndAlongVert[v]` entry. Reading `freeEndAlongVert` directly
        //     makes "no materialized along-vert" gracefully degrade to the
        //     plain (valence-3-style) fallback at both call sites below instead
        //     of a RangeError (task 0311). A genuine valence>3 free end whose
        //     along-vert materialized successfully is unaffected.
        bool needsAlongAt(uint v) { return (v in freeEndAlongVert) !is null; }

        // Rewrite each side face: any face containing a free-end vertex that is
        // NOT a neighbor face of that vertex. Replace the v corner with the two
        // insets ordered to preserve the face's original normal.
        // Tracker: this loop ALSO rewrites pre-existing faces in place. Capture
        // each touched face's before-image (the loop-top `f` dup, which is the
        // exact pre-rewrite list) + after-image into a second ReshapeFaces entry,
        // recorded AFTER the neighbour-face entry so LIFO revert undoes this loop
        // first, then the neighbour loop (each `before` is the true pre-loop
        // state, so the two compose even if a face is touched by both).
        uint[]   sideReshapeIdx;
        uint[][] sideReshapeBefore;
        uint[][] sideReshapeAfter;
        // Task 0317: unconditional twin of `sideReshapeIdx` (that one is only
        //     populated when the mesh-edit tracker has an open batch — inert
        //     for the common one-shot command path). The winding-consistency
        //     safety net below needs the touched-face set on EVERY call, not
        //     just tracked ones.
        bool[uint] sideTouched;
        foreach (fi; 0 .. faces.length) {
            auto f = faces[fi].dup;
            // Snapshot the pre-rewrite normal so we can preserve orientation.
            bool touched = false;
            uint[] rebuilt;
            rebuilt.reserve(f.length + 2);
            Vec3 origNormal = faceNormal(cast(uint)fi);
            foreach (k; 0 .. f.length) {
                uint c = f[k];
                // Boundary chamfer end in a SIDE face (any face that is not its
                // sole neighbour face F): dissolve the corner into the two per-edge
                // insets of THIS face's two boundary fan edges at c (the edges
                // toward prevB and nextB). Each fan edge owns one shared inset
                // (chamferEdgeInset), so adjacent fan faces meet seamlessly on their
                // common seam edge's inset; F (handled by the affected-face rewrite)
                // keeps just its single fan-edge inset → stays a quad. The pair is
                // emitted [prev-side inset, next-side inset] to preserve winding (a
                // faceNormal backstop below flips the whole face if it inverted).
                if (isChamferEnd(c) && chamferNeighborFace[c] != cast(int)fi) {
                    uint prevB = f[(k + f.length - 1) % f.length];
                    uint nextB = f[(k + 1) % f.length];
                    ulong ekPrev = (cast(ulong)c << 32) | prevB;
                    ulong ekNext = (cast(ulong)c << 32) | nextB;
                    auto ip = ekPrev in chamferEdgeInset;
                    auto iq = ekNext in chamferEdgeInset;
                    // Defensive: a fan edge with no inset (degenerate / the extruded
                    // edge itself) keeps the original corner on that side.
                    rebuilt ~= (ip !is null) ? *ip : c;
                    rebuilt ~= (iq !is null) ? *iq : c;
                    touched = true;
                    continue;
                }
                bool freeHere = isInteriorFreeEnd(c)
                    && ((cast(ulong)c << 32 | cast(uint)fi) !in isNeighborOf);
                if (!freeHere) { rebuilt ~= c; continue; }
                // c is a free-end endpoint sitting in a side face. Resolve the
                // two neighbor-face insets via the boundary edges (prev,c)/(c,next).
                uint prev = f[(k + f.length - 1) % f.length];
                uint next = f[(k + 1) % f.length];
                // Which neighbor face shares boundary edge (prev,c)? (the edge
                // belongs to one of c's extruded-edge neighbor faces.)
                int faceOfEdge(uint a, uint b) {
                    auto p = edgeKeyOrdered(a, b) in edgeFaces;
                    if (p is null) return -1;
                    // return whichever of the (≤2) faces is a neighbor of c.
                    foreach (cand; [(*p)[0], (*p)[1]]) {
                        if (cand < 0) continue;
                        if ((cast(ulong)c << 32 | cast(uint)cand) in isNeighborOf)
                            return cand;
                    }
                    return -1;
                }
                int fPrev = faceOfEdge(prev, c); // neighbor sharing incoming edge
                int fNext = faceOfEdge(c, next);  // neighbor sharing outgoing edge
                // For a neighbor-face boundary edge, use that face's perpendicular
                // inset. For an INNER RIM edge (no neighbor face), use the
                // along-edge inset when this free end is valence>3; otherwise
                // (valence-3 cube path) keep c, leaving the pair to be the two
                // perpendicular insets exactly as before.
                uint fallback = needsAlongAt(c) ? freeEndAlongVert[c] : c;
                uint iArrive = (fPrev >= 0)
                    ? freeEndInsetByVF[(cast(ulong)c << 32) | cast(uint)fPrev]
                    : fallback;
                uint iLeave  = (fNext >= 0)
                    ? freeEndInsetByVF[(cast(ulong)c << 32) | cast(uint)fNext]
                    : fallback;
                rebuilt ~= iArrive;
                rebuilt ~= iLeave;
                touched = true;
            }
            if (touched) {
                faces[fi] = rebuilt;
                // Preserve original winding: flip the whole face if the rewrite
                // inverted the normal (only the inserted-pair order is ambiguous).
                if (dot(faceNormal(cast(uint)fi), origNormal) < 0.0f) {
                    auto r = faces[fi].dup;
                    foreach (j, vid; r) faces[fi][r.length - 1 - j] = vid;
                }
                sideTouched[cast(uint)fi] = true;
                if (recExtrude) {
                    sideReshapeIdx    ~= cast(uint)fi;
                    sideReshapeBefore ~= f;            // loop-top dup = pre-rewrite list
                    sideReshapeAfter  ~= faces[fi].dup; // post-rewrite (incl. flip)
                }
            }
        }
        if (recExtrude && sideReshapeIdx.length)
            editRecorder_.recordReshapeFaces(sideReshapeIdx, sideReshapeBefore, sideReshapeAfter);

        // --- Bridge faces. Helper: emit a quad, fixing winding so its normal
        //     points away from the neighbor-face interior (positive dot with ne).
        size_t firstBridge = faces.length;
        uint[] bridgeMaterialSrc;   // neighbor face id each bridge inherits from
        void emitBridge(uint[4] corners, Vec3 ne, int srcFace) {
            uint bfi = cast(uint)faces.length;
            faces ~= [corners[0], corners[1], corners[2], corners[3]];
            if (dot(faceNormal(bfi), ne) < 0.0f) {
                // reverse to make the bridge consistently wound
                faces[bfi] = [corners[3], corners[2], corners[1], corners[0]];
            }
            bridgeMaterialSrc ~= cast(uint)srcFace;
        }
        // Bridge winding derived from the neighbour face's OWN traversal of the
        //     shared inset edge (iA,iB), used for FLAT-EMBEDDED edges where the two
        //     neighbour faces are coplanar so the `ne` dot test cannot orient the
        //     two opposing bridges (their geometric normals point sideways, nearly
        //     orthogonal to the cap-plane ne). The bridge quad [iA,iB,ridgeB,ridgeA]
        //     shares the inset edge (iA,iB) with the rewritten neighbour face fi and
        //     must traverse it OPPOSITE to fi (orientability), exactly the rule the
        //     boundary branch already uses. If fi walks iA→iB, the bridge must walk
        //     iB→iA, i.e. start [iB,iA,ridgeA,ridgeB]; otherwise [iA,iB,ridgeB,ridgeA].
        void emitBridgeFromFace(uint iA, uint iB, uint ridgeA, uint ridgeB,
                                int fi, int srcFace) {
            bool fiAtoB = false;
            auto fa = faces[fi];
            foreach (k; 0 .. fa.length) {
                uint u = fa[k], w = fa[(k + 1) % fa.length];
                if (u == iA && w == iB) { fiAtoB = true;  break; }
                if (u == iB && w == iA) { fiAtoB = false; break; }
            }
            uint bfi = cast(uint)faces.length;
            if (fiAtoB) faces ~= [iB, iA, ridgeA, ridgeB];
            else        faces ~= [iA, iB, ridgeB, ridgeA];
            bridgeMaterialSrc ~= cast(uint)srcFace;
        }
        // Emit a triangle cap, fixing winding so its normal points OUTWARD along
        // the edge axis (positive dot with `outward` = the edge direction that
        // exits the span at this free end). The cap closes the corner gap at the
        // free end, so its normal runs along the edge axis — NOT the extrude
        // direction ne (using ne mis-orients caps whose end face points sideways).
        void emitCap(uint[3] corners, Vec3 outward, int srcFace) {
            uint cfi = cast(uint)faces.length;
            faces ~= [corners[0], corners[1], corners[2]];
            if (dot(faceNormal(cfi), outward) < 0.0f)
                faces[cfi] = [corners[2], corners[1], corners[0]];
            bridgeMaterialSrc ~= cast(uint)srcFace;
        }
        // Bridge corner order is derived from the neighbor face's own corner
        // sequence; the faceNormal check is the backstop for any leftover
        // ambiguity.
        foreach (ref e; exEdges) {
            ulong kIA = (cast(ulong)e.va << 32) | cast(uint)e.fA;
            ulong kIB = (cast(ulong)e.vb << 32) | cast(uint)e.fA;
            if (e.fB != -1) {
                // Interior edge: one bridge quad per neighbor side, from each
                // face's inset edge up to the welded ridge edge. A FLAT-EMBEDDED
                // (coplanar) edge cannot use the `ne` dot test — both its neighbour
                // faces share the same plane, so its two opposing bridges' normals
                // point sideways and ne can't tell them apart. Derive their winding
                // from each neighbour face's own traversal of the shared inset edge
                // instead. Non-coplanar edges keep the original ne-dot path
                // byte-identical (corner_fan/corner3/top_loop/interior unaffected).
                ulong kIA2 = (cast(ulong)e.va << 32) | cast(uint)e.fB;
                ulong kIB2 = (cast(ulong)e.vb << 32) | cast(uint)e.fB;
                // A bridge whose neighbour-face side touches a CAP-MITER inset
                //     (an endpoint whose inset position was overridden) cannot rely
                //     on the `ne` dot test either: the cap-miter pulls the inset
                //     deep inward, so the bridge quad becomes strongly non-planar
                //     and its averaged normal can point opposite `ne`, flipping the
                //     winding. Such a side is wound the orientable way — from the
                //     neighbour face's own traversal of the shared inset edge —
                //     exactly like the coplanar case. A side touching no override
                //     keeps the byte-identical `ne` path.
                bool capSideA = ((kIA in sharedFaceAwareInset) !is null)
                             || ((kIB in sharedFaceAwareInset) !is null);
                bool capSideB = ((kIA2 in sharedFaceAwareInset) !is null)
                             || ((kIB2 in sharedFaceAwareInset) !is null);
                if (e.coplanar || capSideA) {
                    emitBridgeFromFace(insetVert[kIA], insetVert[kIB],
                                       ridgeVert[e.va], ridgeVert[e.vb], e.fA, e.fA);
                } else {
                    emitBridge([insetVert[kIA], insetVert[kIB],
                                ridgeVert[e.vb], ridgeVert[e.va]], e.ne, e.fA);
                }
                if (e.coplanar || capSideB) {
                    emitBridgeFromFace(insetVert[kIA2], insetVert[kIB2],
                                       ridgeVert[e.va], ridgeVert[e.vb], e.fB, e.fB);
                } else {
                    emitBridge([insetVert[kIA2], insetVert[kIB2],
                                ridgeVert[e.vb], ridgeVert[e.va]], e.ne, e.fB);
                }
                // §5.c: triangle cap closing each FREE-END corner gap between the
                // two neighbor insets and the ridge vert. Interior chain joints
                // (shared endpoints) get NO cap — the neighboring extruded edge
                // closes that side.
                // The cap lies in the plane of (insetA, insetB, ridge). Its
                // geometric normal flips with the EXTRUDE SIGN because the ridge
                // vertex moves to the opposite side of the inset edge when the
                // ridge goes from outward (extrude>0) to inward (extrude<0). The
                // edge axis alone is sign-independent, so we fold the extrude sign
                // into the outward reference — exactly as the bridge quads stay
                // sign-correct (their ridge position carries the sign while they
                // validate against the fixed `ne`). Without the sign the caps wind
                // correctly for positive extrude but reverse for negative.
                float es = (extrude < 0.0f) ? -1.0f : 1.0f;
                Vec3 axis = (vertices[e.vb] - vertices[e.va]) * es; // va → vb, sign-aware
                // Cap the corner gap between the two perpendicular insets and the
                // ridge. A valence-3 free end uses ONE triangle [insetA,insetB,
                // ridge] (the cube path, unchanged). A valence>3 free end has its
                // gap split by the along-edge inset, so the cap becomes a small
                // fan of TWO triangles [insetA,vAlong,ridge] + [vAlong,insetB,
                // ridge] (vAlong is geometrically between insetA and insetB along
                // the edge axis, so both triangles tile the same corner with no
                // overlap). emitCap fixes each triangle's winding independently.
                void capFreeEnd(uint v, uint iA, uint iB, Vec3 outward) {
                    if (!isInteriorFreeEnd(v)) return;
                    // A free end on the OPEN mesh boundary needs no cap — the
                    // ridge bridge already closes its corner against the boundary.
                    // (A fully-interior free end is ringed by faces and is capped.)
                    if (isOnMeshBoundary(v)) return;
                    if (needsAlongAt(v)) {
                        uint va2 = freeEndAlongVert[v];
                        emitCap([iA, va2, ridgeVert[v]], outward, e.fA);
                        emitCap([va2, iB, ridgeVert[v]], outward, e.fA);
                    } else {
                        emitCap([iA, iB, ridgeVert[v]], outward, e.fA);
                    }
                }
                capFreeEnd(e.va, insetVert[kIA], insetVert[kIA2], -axis); // va exits −axis
                capFreeEnd(e.vb, insetVert[kIB], insetVert[kIB2],  axis); // vb exits +axis
            } else if (isChamferEnd(e.va) && isChamferEnd(e.vb)) {
                // Boundary CHAMFER (the in-scope single-edge case). The reference
                // IGNORES extrude on a boundary edge and emits a width-only chamfer:
                // both endpoints are dissolved into a topInset (in F) + an
                // antiNormalInset (off the boundary). F keeps the topInset edge (it
                // stays a quad), each side face absorbs both insets (→ 5-gon), and
                // the chamfer edge topInset–antiNormalInset lies on the OPEN
                // boundary. All of that was emitted by the affected-face + side-face
                // rewrites above — NO ridge, NO bridge quad, NO cap here.
            } else {
                // Out-of-scope boundary topology (a shared / chain corner on a
                // boundary edge): fall back to the legacy gap + ridge-bridge shell
                // so we never crash. Requires ridge verts on both endpoints; if a
                // ridge vert is missing (a free chamfer end mixed with a shared
                // corner) we best-effort skip the bridge for this edge.
                auto rpa = e.va in ridgeVert;
                auto rpb = e.vb in ridgeVert;
                if (rpa is null || rpb is null) continue;
                // The shell shares two edges that must be traversed OPPOSITELY by
                // their two incident faces (orientability): the inset edge
                // (insetA,insetB) is shared by the rewritten neighbor face fA and
                // the gap quad; the original edge (va,vb) is shared by the gap quad
                // and the ridge bridge. We derive the gap quad's winding straight
                // from fA's actual traversal of the inset edge so the result is
                // consistently wound regardless of fA's orientation.
                uint iA = insetVert[kIA], iB = insetVert[kIB];
                bool faAtoB = false;
                {
                    auto fa = faces[e.fA];
                    foreach (k; 0 .. fa.length) {
                        uint u = fa[k], w = fa[(k + 1) % fa.length];
                        if (u == iA && w == iB) { faAtoB = true;  break; }
                        if (u == iB && w == iA) { faAtoB = false; break; }
                    }
                }
                if (faAtoB)
                    faces ~= [iB, iA, e.va, e.vb];
                else
                    faces ~= [iA, iB, e.vb, e.va];
                bridgeMaterialSrc ~= cast(uint)e.fA;
                if (faAtoB)
                    faces ~= [e.vb, e.va, *rpa, *rpb];
                else
                    faces ~= [e.va, e.vb, *rpb, *rpa];
                bridgeMaterialSrc ~= cast(uint)e.fA;
            }
        }

        // --- Hand-extend the parallel per-face arrays in lock-step (pure-add op:
        //     neither addVertex nor compactUnreferenced sizes these for us).
        foreach (bi; 0 .. faces.length - firstBridge) {
            uint srcFace = bridgeMaterialSrc[bi];
            faceMaterial       ~= (srcFace < faceMaterial.length ? faceMaterial[srcFace] : 0u);
            facePart           ~= (srcFace < facePart.length     ? facePart[srcFace]     : 0u);
            faceSelectionOrder ~= 0;
        }
        resizeSubpatch();
        // Task 0389: each bridge/cap wall inherits Subpatch from the same
        // neighbour face `bridgeMaterialSrc` already resolves its material
        // from, instead of a blanket false — a subdiv model stays subdiv
        // after an edge extrude.
        foreach (bi; 0 .. faces.length - firstBridge) {
            uint fi = cast(uint)(firstBridge + bi);
            setFaceSubpatch(fi, isFaceSubpatch(bridgeMaterialSrc[bi]));
        }

        // Tracker: the bridge/cap faces were appended via `faces ~=` (NOT addFace),
        // so they are NOT auto-logged. Record them as one AddFaces([F0..F1)) entry
        // now that the parallel arrays are sized and the appends are complete.
        // (These index in the PRE-compaction face space; compaction touches only
        // vertex indices inside faces — no face is dropped/reordered here — so the
        // appended block stays the tail [F0..F1) and reverts by truncation.)
        if (recExtrude && faces.length > firstBridge) {
            uint[][] bridgeLists;
            foreach (fi; firstBridge .. faces.length) bridgeLists ~= faces[fi].dup;
            editRecorder_.recordAddFaces(cast(uint)firstBridge, cast(uint)faces.length, bridgeLists);
        }

        // --- Record the ridge endpoints BY POSITION for each extruded edge so we
        //     can re-find the ridge edges AFTER compaction remaps vertex indices.
        //     Free-end endpoints are now wholly dissolved (no face references
        //     them), so compactUnreferenced drops them — making vertexCount match
        //     the reference's (no orphans). But compaction renumbers every surviving vert,
        //     invalidating ridgeVert[] — hence the position round-trip.
        Vec3[2][] ridgeEdgePos;
        ridgeEdgePos.reserve(exEdges.length);
        foreach (ref e; exEdges) {
            if (e.fB == -1 && isChamferEnd(e.va) && isChamferEnd(e.vb)) {
                // Boundary chamfer: the surviving edge is the topInset edge in F
                // (no ridge). Select it so a follow-up op chains off the chamfer.
                uint ta = insetVert[(cast(ulong)e.va << 32) | cast(uint)e.fA];
                uint tb = insetVert[(cast(ulong)e.vb << 32) | cast(uint)e.fA];
                ridgeEdgePos ~= [vertices[ta], vertices[tb]];
            } else {
                // Interior edges always have both ridge verts. A mixed boundary
                // edge (one chamfer end + one shared/ridge end — out of scope) may
                // be missing a ridge vert for the chamfer end; skip recording a
                // ridge edge there rather than range-erroring.
                auto ra = e.va in ridgeVert;
                auto rb = e.vb in ridgeVert;
                if (ra is null || rb is null) continue;
                ridgeEdgePos ~= [vertices[*ra], vertices[*rb]];
            }
        }

        // --- Degenerate-face cleanup (task 0313). The far-vertex overshoot
        //     clamps above now REUSE an existing vertex id when the clamped
        //     landing coincides with it, instead of minting a coincident
        //     duplicate. Reusing an id that is already one of a face's OTHER
        //     corners (always true here: `far` is by construction the
        //     immediate winding-order neighbour of the corner being replaced)
        //     collapses that corner onto its neighbour, leaving an adjacent
        //     repeated corner (a zero-length edge) in the rewritten face —
        //     or, when BOTH of a triangle's non-fixed corners saturate onto
        //     the SAME third corner (e.g. an extreme overshoot on a small
        //     triangular neighbour face), the whole face collapses to a
        //     single point. This pass runs once over every face — the
        //     rewritten neighbour/side faces AND the freshly emitted
        //     bridge/cap faces alike, since a bridge quad can equally
        //     inherit a doubled corner from a saturated clamp (its two
        //     inset corners are independently resolved and can coincide) —
        //     collapsing any consecutive (cyclically-adjacent) duplicate
        //     corners, and dropping any face that reduces to fewer than 3
        //     distinct corners. Nothing downstream still depends on
        //     original face indices/slots (the bridge/cap loop above was
        //     the last reader of `e.fA`/`e.fB`; the ridge edges were just
        //     captured BY POSITION), so faces can be safely removed here
        //     with a full reindex. A well-formed extrude (no clamp ever
        //     saturates, or saturates only onto a vertex that ISN'T already
        //     a face-adjacent corner) never triggers a duplicate here, so
        //     this pass is a no-op — byte-identical to the pre-fix output.
        // Task 0317: old→new face-index remap produced by this cleanup pass
        //     (old index → new index, or -1 if dropped). Populated below
        //     regardless of whether any face actually dropped (identity map
        //     in that case) so the winding-consistency pass right after can
        //     translate its pre-cleanup candidate indices forward.
        size_t facesLenBeforeCleanup = faces.length;
        int[] faceRemap = new int[](facesLenBeforeCleanup);
        {
            bool[] dropFace = new bool[](faces.length);
            bool anyDrop = false;
            // Tracker: a face whose consecutive-duplicate corners collapse here
            // but that SURVIVES (still >=3 corners after collapsing) is mutated
            // IN PLACE with no corresponding record — the drop path below records
            // RemoveFaces, but a mere SHRINK was invisible to the edit-delta.
            // Forward replay (redo) would then leave the face at its earlier,
            // duplicate-corner shape (whatever an upstream ReshapeFaces/AddFaces
            // entry last recorded), since nothing in the log ever re-applies the
            // collapse. Record it as one more ReshapeFaces entry, keyed by the
            // SAME pre-cleanup index space `droppedFaceIdx`/the nbr/side entries
            // already use — before = the pre-collapse corner list, after = the
            // collapsed one. A face that also ends up dropped needs no entry
            // here (RemoveFaces^-1 only needs to preserve the slot; a face that
            // survives to the tail of LIFO revert is always fully overwritten by
            // an earlier ReshapeFaces^-1/AddFaces^-1 truncation regardless of
            // this intermediate content).
            uint[]   reduceReshapeIdx;
            uint[][] reduceReshapeBefore;
            uint[][] reduceReshapeAfter;
            foreach (fi; 0 .. faces.length) {
                auto f = faces[fi];
                if (f.length < 3) continue;   // pre-existing invalid face — not ours to fix
                uint[] reduced;
                reduced.reserve(f.length);
                foreach (c; f)
                    if (reduced.length == 0 || reduced[$ - 1] != c) reduced ~= c;
                // Cyclic wrap: the first and last surviving corners may also
                // coincide (e.g. a triangle collapsed to [a,a,a] reduces
                // linearly to [a], already caught below; a quad collapsed to
                // [a,b,b,a] reduces linearly to [a,b,a] — first==last too).
                while (reduced.length > 1 && reduced[0] == reduced[$ - 1])
                    reduced = reduced[0 .. $ - 1];
                if (reduced.length != f.length) {
                    if (recExtrude && reduced.length >= 3) {
                        reduceReshapeIdx    ~= cast(uint)fi;
                        reduceReshapeBefore ~= f.dup;
                        reduceReshapeAfter  ~= reduced.dup;
                    }
                    faces[fi] = reduced;
                }
                if (faces[fi].length < 3) { dropFace[fi] = true; anyDrop = true; }
            }
            if (recExtrude && reduceReshapeIdx.length)
                editRecorder_.recordReshapeFaces(reduceReshapeIdx, reduceReshapeBefore, reduceReshapeAfter);
            if (anyDrop) {
                uint[][] keptFaces;
                bool[]   keptSubpatch;
                int[]    keptOrder;
                uint[]   keptMaterial;
                uint[]   keptPart;
                keptFaces.reserve(faces.length);
                keptSubpatch.reserve(faces.length);
                keptOrder.reserve(faces.length);
                keptMaterial.reserve(faces.length);
                keptPart.reserve(faces.length);
                uint[]   droppedFaceIdx;
                uint[][] droppedFaceLists;
                uint[]   droppedFaceMat;
                uint[]   droppedFacePart;
                uint[]   droppedFaceSub;
                size_t newIdx = 0;
                foreach (fi, ref f; faces) {
                    if (dropFace[fi]) {
                        faceRemap[fi] = -1;
                        if (recExtrude) {
                            droppedFaceIdx   ~= cast(uint)fi;
                            droppedFaceLists ~= f.dup;
                            droppedFaceMat   ~= (fi < faceMaterial.length ? faceMaterial[fi] : 0u);
                            droppedFacePart  ~= (fi < facePart.length     ? facePart[fi]     : 0u);
                            droppedFaceSub   ~= (isFaceSubpatch(fi) ? 1u : 0u);
                        }
                        continue;
                    }
                    faceRemap[fi] = cast(int)newIdx;
                    ++newIdx;
                    keptFaces    ~= f;
                    keptSubpatch ~= isFaceSubpatch(fi);
                    keptOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
                    keptMaterial ~= (fi < faceMaterial.length      ? faceMaterial[fi]      : 0u);
                    keptPart     ~= (fi < facePart.length          ? facePart[fi]          : 0u);
                }
                if (recExtrude && droppedFaceIdx.length)
                    editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                                    droppedFaceMat, droppedFacePart, droppedFaceSub);
                faces              = keptFaces;
                setFaceSubpatchFrom(keptSubpatch);
                faceSelectionOrder = keptOrder;
                faceMaterial       = keptMaterial;
                facePart           = keptPart;
            } else {
                foreach (fi; 0 .. facesLenBeforeCleanup) faceRemap[fi] = cast(int)fi;
            }
        }

        // --- Winding-consistency safety net (task 0317). Every rewritten
        //     neighbour/side face and every freshly emitted bridge/cap picks
        //     its own winding from a LOCAL heuristic (the "preserve original
        //     normal" flip for rewrites, the neighbour-averaged `ne` dot-test
        //     for bridges, the edge-axis dot-test for caps). Each heuristic is
        //     individually sound for the small-inset geometry it was designed
        //     around, but an extreme overshoot can collapse an inset onto a
        //     vertex shared with ANOTHER independently-wound face — a stable
        //     far vertex reused by a bridge/cap AND still incident to its own
        //     ORIGINAL, untouched neighbour elsewhere in the mesh, or two
        //     bridges of the same (or, pre task-0317-fix, two mutually facing)
        //     selected edge(s) sharing one collapsed inset edge. The
        //     independent heuristics can then disagree about which way two
        //     faces should traverse the edge they end up sharing, folding the
        //     surface even though neither face is individually degenerate,
        //     and a single forward sweep is not always enough to resolve it
        //     (face A may need to flip to satisfy face B, but B was already
        //     accepted before A's conflict with it was even discovered).
        //
        //     This is a two-colouring problem: every UNTOUCHED, pre-existing
        //     face's winding is fixed ground truth (the original mesh was a
        //     valid manifold, so any edge shared by two untouched faces is
        //     already consistent); every touched/created face this op
        //     touched or emitted (rewritten neighbour/side faces + the
        //     freshly emitted bridge/cap tail — translated through the
        //     degenerate-cleanup remap above) gets EXACTLY one bit of freedom
        //     — keep its current corner order, or reverse the whole face —
        //     and adjacent faces sharing an edge must pick opposite
        //     canonical directions along it. Solve by propagating from every
        //     touched face directly adjacent to a fixed face (its required
        //     state is forced), then flooding that decision across the
        //     touched-face adjacency graph; any touched-face island with no
        //     fixed anchor at all gets an arbitrary (but internally
        //     consistent) root. A topology where every heuristic already
        //     agrees (the overwhelming common case — no clamp ever saturates
        //     onto another dissolving vertex) finds every touched face
        //     already satisfying its neighbours, so nothing flips.
        //
        //     Perf nit: the whole pass (in particular the full-mesh
        //     `edgeUsers` build, which is O(F) over every face in the mesh —
        //     not just the ones this op touched) is gated on
        //     `anyOvershootSaturated`. Every heuristic above already agrees
        //     whenever no clamp/weld actually saturated (see the invariant
        //     above), so this pass is PROVABLY a no-op in that case — safe to
        //     skip outright rather than run it and discover nothing flips.
        //     This is the common case for every batchless preview frame
        //     (`rebuildPreview()` re-runs this kernel every frame of an
        //     interactive drag with a modest width/extrude), so the gate
        //     avoids doing O(F) work per frame for a result that never
        //     changes anything.
        if (anyOvershootSaturated) {
            bool[uint] windingCandidate;
            void addCandidate(size_t oldFi) {
                if (oldFi >= faceRemap.length) return;
                int nfi = faceRemap[oldFi];
                if (nfi >= 0) windingCandidate[cast(uint)nfi] = true;
            }
            foreach (fi, _; affectedFaces) addCandidate(cast(size_t)fi);
            foreach (fi, _; sideTouched) addCandidate(fi);
            foreach (fi; firstBridge .. facesLenBeforeCleanup) addCandidate(fi);

            // canonical(a,b) directed-edge sign: +1 if this face reads
            // lo→hi, -1 if hi→lo. Two faces sharing an undirected edge are
            // consistently wound iff their EFFECTIVE signs (own sign, times
            // -1 if flipped) multiply to -1.
            static struct EdgeUse { uint fi; int sign; }
            EdgeUse[][ulong] edgeUsers;
            foreach (fi; 0 .. faces.length) {
                auto f = faces[fi];
                if (f.length < 3) continue;
                foreach (k; 0 .. f.length) {
                    uint a = f[k], b = f[(k + 1) % f.length];
                    uint lo = a < b ? a : b, hi = a < b ? b : a;
                    ulong ek = (cast(ulong)lo << 32) | hi;
                    edgeUsers[ek] ~= EdgeUse(cast(uint)fi, (a == lo) ? 1 : -1);
                }
            }

            int[uint] state;     // 0 = keep, 1 = flip — only ever set for candidates
            uint[] queue;
            void seed(uint fi, int st) {
                if (fi in state) return;
                state[fi] = st;
                queue ~= fi;
            }
            // needed multiplier so that signA * (signB*mul) == -1.
            static int neededMul(int signA, int signB) { return -(signA * signB); }

            // Seed every candidate directly adjacent (via a 2-user edge) to a
            // fixed (non-candidate) face: its state is fully determined.
            foreach (ek, users; edgeUsers) {
                if (users.length != 2) continue;
                auto u0 = users[0], u1 = users[1];
                bool c0 = (u0.fi in windingCandidate) !is null;
                bool c1 = (u1.fi in windingCandidate) !is null;
                if (c0 == c1) continue;   // both fixed (nothing to do) or both candidate (flood below)
                auto fixedU = c0 ? u1 : u0;
                auto candU  = c0 ? u0 : u1;
                int mul = neededMul(fixedU.sign, candU.sign);
                seed(candU.fi, (mul == -1) ? 1 : 0);
            }

            // Flood the decision across candidate-candidate adjacency; once
            // the initial fixed-seeded fronts are drained, root any
            // remaining unassigned candidate arbitrarily (state = keep) and
            // keep draining — this reaches every candidate exactly once.
            size_t qi = 0;
            while (true) {
                while (qi < queue.length) {
                    uint cur = queue[qi++];
                    int curState = state[cur];
                    auto f = faces[cur];
                    foreach (k; 0 .. f.length) {
                        uint a = f[k], b = f[(k + 1) % f.length];
                        uint lo = a < b ? a : b, hi = a < b ? b : a;
                        ulong ek = (cast(ulong)lo << 32) | hi;
                        auto users = edgeUsers[ek];
                        if (users.length != 2) continue;
                        int curSign = 0;
                        foreach (u; users) if (u.fi == cur) curSign = u.sign;
                        int curEff = curSign * (curState == 1 ? -1 : 1);
                        foreach (u; users) {
                            if (u.fi == cur) continue;
                            if ((u.fi in windingCandidate) is null) continue;   // fixed — already ground truth
                            if (u.fi in state) continue;                       // already assigned
                            int mul = neededMul(curEff, u.sign);
                            seed(u.fi, (mul == -1) ? 1 : 0);
                        }
                    }
                }
                bool addedRoot = false;
                foreach (fi, _; windingCandidate) {
                    if (fi in state) continue;
                    seed(fi, 0);
                    addedRoot = true;
                    break;
                }
                if (!addedRoot) break;
            }

            // Tracker: this pass runs AFTER every recordReshapeFaces/recordAddFaces
            // call above captured its own after-image, so a flip applied here is
            // otherwise INVISIBLE to the edit-delta — redo (MeshEditDelta.apply,
            // which replays faceListsAfter/faceLists verbatim) would silently
            // restore the pre-flip (folded) winding even though undo (which
            // restores the pre-op faces wholesale) is unaffected. Record exactly
            // the faces this loop actually flips as one more ReshapeFaces entry,
            // keyed by the POST-cleanup index `fi` — the same index space
            // `removeFacesForward` reproduces on redo (it repacks kept faces in
            // order, byte-identical to how `keptFaces` was built above), so this
            // entry composes correctly after the cleanup pass's RemoveFaces entry
            // on both forward replay and LIFO reverse. A call with an empty index
            // list (the common no-flip case) is a guaranteed no-op inside
            // recordReshapeFaces, so this adds nothing when nothing flipped.
            uint[]   windReshapeIdx;
            uint[][] windReshapeBefore;
            uint[][] windReshapeAfter;
            foreach (fi, st; state) {
                if (st != 1) continue;
                auto r = faces[fi].dup;
                foreach (j, vid; r) faces[fi][r.length - 1 - j] = vid;
                if (recExtrude) {
                    windReshapeIdx    ~= fi;
                    windReshapeBefore ~= r;
                    windReshapeAfter  ~= faces[fi].dup;
                }
            }
            if (recExtrude && windReshapeIdx.length)
                editRecorder_.recordReshapeFaces(windReshapeIdx, windReshapeBefore, windReshapeAfter);
        }

        // --- Rebuild edges + loops; size selection arrays explicitly. Then drop
        //     dissolved free-end endpoints (and any other orphan) so the vertex
        //     count matches the reference exactly.
        rebuildEdges();
        buildLoops();
        compactUnreferenced();   // remaps verts; rebuilds edges + edgeIndexMap
        buildLoops();
        resizeVertexSelection();
        resizeFaceSelection();
        clearEdgeSelectionResize();   // resize edge marks + drop all edge selection

        // --- New selection = the ridge edges (so a follow-up move/extrude
        //     chains). Re-find each ridge endpoint by its (post-compaction)
        //     position, then look the edge up via edgeKey on the new indices.
        int findVertByPos(Vec3 p) {
            foreach (i, ref v; vertices)
                if ((v - p).length < 1e-5f) return cast(int)i;
            return -1;
        }
        foreach (ref pr; ridgeEdgePos) {
            int a = findVertByPos(pr[0]);
            int b = findVertByPos(pr[1]);
            if (a < 0 || b < 0) continue;
            ulong rk = edgeKey(cast(uint)a, cast(uint)b);
            if (auto p = rk in edgeIndexMap)
                selectEdge(cast(int)*p);
        }
        clearVertexSelection();
        clearFaceSelection();

        // Tracker: record the edge-selection delta. `before` = the pre-extrude
        // selected edges (captured up top, pre-extrude vertex space, restored by
        // revert); `after` = the post-extrude RIDGE selection (post-compaction
        // vertex space, restored by apply/redo). Both keyed by endpoint pair —
        // edge indices are unstable across the rebuild (doc §1.3 / §2.3 step 1).
        if (recExtrude) {
            uint[] postEdgeSelEnds;
            foreach (i; 0 .. edges.length) {
                if (i < edgeMarks.length && (edgeMarks[i] & Marks.Select)) {
                    postEdgeSelEnds ~= edges[i][0];
                    postEdgeSelEnds ~= edges[i][1];
                }
            }
            editRecorder_.recordEdgeSelByEnds(preEdgeSelEnds, postEdgeSelEnds);
        }

        commitChange(MeshEditScope.Geometry);
        return exEdges.length;
    }

    // Mesh-robustness batch (fuzz-found): a standalone open n-gon (single
    // face, open boundary loop) whose corners are all SHARED (>=2 selected
    // boundary edges per corner) run through an overshoot `width` at
    // `extrude=0` used to mint a coincident duplicate vertex at each original
    // corner position — the Pass-1 ridge vertex always minted a NEW vertex
    // via addVertex(v + dir*extrude) even when extrude=0 (where dir*extrude
    // is exactly the zero vector). Fixed: Pass 1 reuses the original vertex
    // id at extrude≈0 instead. Confirmed by an HTTP-level before/after probe:
    // a regular pentagon, all 5 boundary edges selected, extrude=0/width=0.3
    // produced V=15 (5 coincident pairs) before the fix, V=10 (none) after.
    unittest {
        import std.conv : to;

        // Regular pentagon: single open-boundary face, every corner shared
        // by exactly 2 boundary edges (a chain-joint corner, not a free end).
        Mesh m;
        import std.math : PI, cos, sin;
        uint[] pent;
        foreach (k; 0 .. 5) {
            double ang = 2 * PI * k / 5 - PI / 2;
            pent ~= m.addVertex(Vec3(cast(float)cos(ang), 0, cast(float)sin(ang)));
        }
        m.addFace(pent);

        bool[] mask; mask.length = m.edges.length; mask[] = true;
        size_t n = m.extrudeEdgesByMask(mask, 0.0f, 0.3f);
        assert(n == 5, "pentagon shared-corner extrude=0: expected 5 edges extruded, got " ~ n.to!string);

        // No coincident duplicate vertices.
        foreach (i; 0 .. m.vertices.length) {
            foreach (j; i + 1 .. m.vertices.length) {
                Vec3 d = m.vertices[i] - m.vertices[j];
                float d2 = d.x*d.x + d.y*d.y + d.z*d.z;
                assert(d2 > 1e-8f,
                    "pentagon shared-corner extrude=0: verts " ~ i.to!string ~
                    " and " ~ j.to!string ~ " are coincident");
            }
        }

        // Edge-manifold: every undirected edge used by at most 2 faces.
        size_t[ulong] edgeUseCount;
        foreach (fi; 0 .. m.faces.length) {
            auto f = m.faces[fi];
            foreach (k; 0 .. f.length) {
                ulong key = edgeKeyOrdered(f[k], f[(k + 1) % f.length]);
                auto p = key in edgeUseCount;
                if (p is null) edgeUseCount[key] = 1;
                else           ++(*p);
            }
        }
        foreach (key, count; edgeUseCount)
            assert(count <= 2,
                "pentagon shared-corner extrude=0: non-manifold edge used by " ~
                count.to!string ~ " faces");
    }

    /// Vertex Extrude (Cone): additive. For each vertex selected in `mask`
    /// that is interior-manifold (valence ≥ 3, every incident edge shared
    /// by exactly 2 faces — same acceptance test `bevelVerticesByMask`
    /// uses), builds an N-gon ring of new vertices around it from its
    /// incident edges. UNLIKE `bevelVerticesByMask`, there is no vertex-
    /// disjoint gating: `vi` is never removed here, so two mutually-
    /// adjacent selected vertices process independently without conflict
    /// (confirmed against the captured 4-mutually-adjacent-corner parity
    /// case below — each vertex's own split points are private to it, even
    /// on a shared edge).
    ///
    /// DERIVED LAWS (task 0360, fitted byte-exact to the frozen reference
    /// fixtures — not just the summary prose):
    ///  - `width == 0` (any `shift`, either sign) is a COMPLETE no-op —
    ///    position-diffed byte-identical to the input, zero topology
    ///    change. (fully confirmed)
    ///  - `width != 0`, `shift == 0`: `vi`'s position is UNCHANGED
    ///    (stationary apex). Each incident edge e=(vi,other) spawns TWO
    ///    new vertices at the SAME position `vi + width·normalize(other −
    ///    vi)`:
    ///      * a "rim" vertex, private to `vi` but shared between the (≤2)
    ///        ORIGINAL faces incident to `vi` across `e` — substituted
    ///        into those faces in place of `vi`, exactly like
    ///        `bevelVerticesByMask`'s split ring;
    ///      * a "fan" vertex, ALSO private to `vi`, used only to close
    ///        `vi`'s own local wall+cap structure (never shared with the
    ///        original faces).
    ///    Per ORIGINAL face F incident at `vi` (bounded there by predEdge/
    ///    succEdge, in F's own winding), TWO new faces are appended:
    ///      bridgeQuad(F) = [rim_succ, rim_pred, fan_pred, fan_succ]
    ///      fanTri(F)     = [fan_succ, fan_pred, vi]
    ///    (`vi` itself is the fan's apex — never removed/duplicated).
    ///    This exactly reproduces the captured 4-corner cube case (8v/6f →
    ///    32v/30f, apex stationary — 6 new verts + 6 new faces per
    ///    accepted valence-3 vertex; see the golden fixture in
    ///    tests/test_vertex_extrude_tool.d).
    ///  - `width != 0` AND `shift != 0` (TENTATIVE — a SINGLE captured
    ///    data point, task 0360 toolcard `behavior.shift_and_width_together`):
    ///    the apex moves by `(shift + width) · vertexNormal(vi)` (confirmed
    ///    magnitude + direction for exactly one case — a cube corner,
    ///    shift=width=0.2 → 0.4 total displacement along the corner's
    ///    (1,1,1)-type outward normal, vertexNormal being the SAME
    ///    averaged-incident-face-normal formula the legacy single-vertex
    ///    kernel used). The rim/fan ring positions in the captured
    ///    combined case are NEITHER coincident with the shift==0 ring NOR
    ///    a simple lerp toward the moved apex — no general law was
    ///    derivable from one sample, so this kernel deliberately keeps
    ///    rim/fan at the SAME width-offset-from-`vi` formula as the
    ///    shift==0 case and only displaces the apex. This is a clearly-
    ///    flagged APPROXIMATION, not a verified reference match — do not
    ///    treat combined-case (shift!=0 && width!=0) geometry as
    ///    reference-accurate; only the no-op and width-alone laws above
    ///    are byte-exact.
    ///
    /// Selection is left untouched: `vi` is never removed or re-indexed,
    /// so whatever was selected stays selected — matches the captured
    /// post-apply selection (the apex vertices, at their original
    /// indices, NOT the new ring — unlike `bevelVerticesByMask`, which
    /// selects the new cap faces).
    ///
    /// Returns the number of accepted (processed) vertices, 0 on no-op.
    size_t extrudeVerticesByMask(in bool[] mask, float shift, float width)
    {
        if (mask.length != vertices.length) return 0;
        if (width == 0.0f) return 0;

        uint succInFace_(uint fi, uint v) const {
            auto f = faces[fi];
            foreach (k; 0 .. f.length)
                if (f[k] == v) return f[(k+1)%f.length];
            return uint.max;
        }
        uint predInFace_(uint fi, uint v) const {
            auto f = faces[fi];
            foreach (k; 0 .. f.length)
                if (f[k] == v) return f[(k + f.length - 1)%f.length];
            return uint.max;
        }

        auto edgeFacesMap = buildEdgeFaces();

        bool[] accepted = new bool[](vertices.length);
        size_t processed = 0;
        foreach (vi; 0 .. cast(uint)vertices.length) {
            if (vi >= mask.length || !mask[vi]) continue;

            uint[] incEdges;
            foreach (ei; edgesAroundVertex(vi)) incEdges ~= ei;
            if (incEdges.length < 3) continue;

            bool manifold = true;
            foreach (ei; incEdges) {
                ulong key = edgeKeyOrdered(edges[ei][0], edges[ei][1]);
                auto fp = key in edgeFacesMap;
                if (fp is null || (*fp)[0] < 0 || (*fp)[1] < 0) {
                    manifold = false; break;
                }
            }
            if (!manifold) continue;

            accepted[vi] = true;
            ++processed;
        }
        if (processed == 0) return 0;

        // Freeze original counts before addVertex grows the array.
        const uint origVertCount = cast(uint)vertices.length;
        const uint origFaceCount = cast(uint)faces.length;

        // rim/fan lookup, keyed by (vi << 32 | incidentEdgeIndex) — PRIVATE
        // per accepted vertex (unlike bevelVerticesByMask's splitByKey,
        // which is keyed by the raw edge alone: that dedup is only valid
        // there because bevel's vertex-disjoint gating guarantees at most
        // one accepted endpoint per edge; here BOTH endpoints of an edge
        // may independently be accepted, and each gets its OWN split point
        // — confirmed by the captured 4-mutually-adjacent-corner case,
        // where the shared edge between two selected corners carries TWO
        // distinct rim points, one near each end, not one shared midpoint
        // point).
        uint[ulong] rimOf;
        uint[ulong] fanOf;

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;
            Vec3 vpos = vertices[vi];
            foreach (ei; edgesAroundVertex(vi)) {
                uint other = edgeOtherVertex(cast(uint)ei, vi);
                Vec3 sp = vpos + width * safeNormalize(vertices[other] - vpos);
                ulong k = (cast(ulong)vi << 32) | cast(uint)ei;
                rimOf[k] = addVertex(sp);
                fanOf[k] = addVertex(sp);
            }
        }

        // Tentative shift+width apex law (see doc-comment above). Computed
        // AFTER rim/fan creation (which reads vi's ORIGINAL position) but
        // BEFORE the face rebuild below (faceNormal here still reads the
        // untouched `faces` array).
        if (shift != 0.0f) {
            foreach (vi; 0 .. origVertCount) {
                if (!accepted[vi]) continue;
                Vec3 n = Vec3(0, 0, 0);
                foreach (fi; facesAroundVertex(vi)) n = n + faceNormal(cast(uint)fi);
                float len = n.length;
                n = (len > 1e-6f) ? n * (1.0f / len) : Vec3(0, 1, 0);
                vertices[vi] = vertices[vi] + n * (shift + width);
            }
        }

        struct VertSub { uint oldV; uint[] newVs; }
        VertSub[][uint] faceSubs;
        struct NewFaceSpec { uint[] verts; uint srcFi; }
        NewFaceSpec[] extraFaces;

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;
            foreach (fi; facesAroundVertex(vi)) {
                uint p = predInFace_(cast(uint)fi, vi);
                uint s = succInFace_(cast(uint)fi, vi);
                uint peIdx = edgeIndexMap[edgeKey(p, vi)];
                uint seIdx = edgeIndexMap[edgeKey(vi, s)];
                ulong pk = (cast(ulong)vi << 32) | peIdx;
                ulong sk = (cast(ulong)vi << 32) | seIdx;
                uint rimPred = rimOf[pk], rimSucc = rimOf[sk];
                uint fanPred = fanOf[pk], fanSucc = fanOf[sk];

                faceSubs.require(cast(uint)fi) ~= VertSub(vi, [rimPred, rimSucc]);
                extraFaces ~= NewFaceSpec([rimSucc, rimPred, fanPred, fanSucc], cast(uint)fi);
                extraFaces ~= NewFaceSpec([fanSucc, fanPred, vi], cast(uint)fi);
            }
        }

        // single rebuild pass: substituted/surviving faces then new faces
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        bool[]   newSub;

        foreach (fi; 0 .. origFaceCount) {
            auto orig  = faces[fi];
            auto subsP = fi in faceSubs;
            if (subsP is null) {
                newFaces ~= orig.dup;
            } else {
                uint[][uint] repl;
                foreach (s; *subsP) repl[s.oldV] = s.newVs;
                uint[] rebuilt;
                foreach (v; orig) {
                    auto rp = v in repl;
                    if (rp is null) rebuilt ~= v;
                    else            rebuilt ~= *rp;
                }
                newFaces ~= rebuilt;
            }
            newMat  ~= fi < faceMaterial.length       ? faceMaterial[fi]       : 0u;
            newPart ~= fi < facePart.length           ? facePart[fi]           : 0u;
            newOrd  ~= fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0;
            newSub  ~= isFaceSubpatch(fi);
        }

        foreach (nf; extraFaces) {
            newFaces ~= nf.verts;
            newMat   ~= nf.srcFi < faceMaterial.length ? faceMaterial[nf.srcFi] : 0u;
            newPart  ~= nf.srcFi < facePart.length     ? facePart[nf.srcFi]     : 0u;
            newOrd   ~= 0;
            newSub   ~= isFaceSubpatch(nf.srcFi);
        }

        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;

        faceMarks.length = faces.length;
        faceMarks[]      = 0;
        foreach (fi, s; newSub)
            if (s) faceMarks[fi] |= Marks.Subpatch;

        resizeVertexSelection();
        clearEdgeSelectionResize();

        rebuildEdges();
        buildLoops();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }

    /// Edge Extend: ADDITIVE, non-manifold. Per selected edge (with ≥1 adjacent
    /// face) adds 2 ridge verts + 1 bridge quad; the source mesh is NOT modified
    /// (the source edge becomes 3-face non-manifold; ring adjacency at that edge is
    /// known-degraded — see doc/non_manifold_buildloops_fix.md). Vertices shared by
    /// multiple selected edges WELD to ONE new vert (chains/loops/star junctions),
    /// placed by the minimum-norm offset-meet of all distinct adjacent face planes.
    /// Wire edges (0 adjacent faces) are SKIPPED. Each new vert =
    ///   (k/segments)·offset + insetShiftDelta(v) + scale(rotate(E_src(v) about origin))
    /// (see doc/edge_extend_plan.md §"verified reference model"). rotateDeg in
    /// degrees; rotate then scale, both about the WORLD ORIGIN; inset/shift in the
    /// world frame from ORIGINAL geometry (shift inert on interior edges). Selects
    /// the new ridge edge(s) on exit. Does NOT touch GpuMesh or caches (command/
    /// tool layer's job). `mask.length == edges.length`. NOT a fork of
    /// extrudeEdgesByMask — fresh additive topology.
    ///
    /// `insetShiftDelta` composition — ONE unified law for every new vert, free
    /// end / welded corner / interior / boundary alike (verified against the
    /// reference dumps to ~1e-7):
    ///  * INSET: the min-norm offset-meet of `delta·n_f = −inset` over ALL DISTINCT
    ///    face planes incident at the source vertex v (every face that contains v,
    ///    NOT just the faces adjacent to the selected edges). There is NO separate
    ///    axial term: on a cube the corner's THIRD perpendicular face supplies the
    ///    edge-axis component that earlier looked axial (vert (0.5,0.5,0.5) ∈
    ///    top+front+right ⇒ meet (−0.1,−0.1,−0.1)); a tent free end has only its 2
    ///    incident faces, giving the genuine two-plane drop; a vertex on a single
    ///    flat face reduces to −inset·n (the boundary one-plane case). This folds
    ///    the old free-end/weld branch distinction into a single accumulator.
    ///  * SHIFT: each incident BOUNDARY edge adds `shift·inPlaneOutwardPerp` on top
    ///    (inert on interior edges).
    ///
    /// Rotation composition: Rx then Ry then Rz applied in that order.
    /// Single-axis rotations are capture-verified; the multi-axis Rx→Ry→Rz order
    /// is confirmed by the parity harness (rotX+rotY case). For segments>1 each
    /// axis angle is independently scaled by k/N before the same Rx→Ry→Rz
    /// composition — only single-axis fractional rotation is capture-verified;
    /// the fractional MULTI-axis euler (per-axis k/N scaling then Rx→Ry→Rz) is
    /// the natural model, assumed here (no reference dump pins it).
    ///
    /// SEGMENTS (rings). For `segments = N` (N ≥ 1) each selected edge spawns N
    /// stacked ring levels (each level welds per-corner exactly like N=1) + N
    /// stacked bridge quads (src→ring1, ring1→ring2, …, ring(N−1)→ringN). Per
    /// ring k (k = 1..N) for source vertex v (E_src = original position):
    ///   ringVert_k(v) = (k/N)·offset + insetShiftDelta(v)
    ///                 + Scale_k( Rotate_k( E_src(v) ) )
    ///   Rotate_k = rotate by (k/N)·rotateDeg (about world origin)
    ///   Scale_k  = componentwise LINEAR lerp 1 + (k/N)·(scale − 1) (about origin)
    ///   insetShiftDelta applied FULLY on every ring (NOT fractional).
    /// The geometric scale s^(k/N) is RULED OUT by capture (linear lerp wins).
    /// Ring N's formula coincides with the N=1 law (continuity): rotate/offset
    /// are exact IEEE identities at t=1; scale goes through the lerp
    /// 1+(s−1), exact for the golden values and within a sub-ulp rounding of
    /// the direct multiply for arbitrary s. Topology/order are identical. The
    /// OUTERMOST ring (k=N) supplies the post-op edge selection. Identity TRS ⇒
    /// all rings coincide (stacked coincident verts — faithful to the reference;
    /// rings are NOT deduped/welded to each other).
    /// PIVOT (Phase 4a). Rotate/Scale apply about `pivot` (default = world
    /// origin ⇒ every existing call site / golden output is BYTE-UNCHANGED: the
    /// conjugation `pivot + RS(p − pivot)` reduces to `RS(p)` at pivot=origin).
    /// The interactive tool passes the ActionCenterStage center so the live
    /// gizmo pivots at the selection/action center (the conjugated law); Offset
    /// and inset/shift are pivot-AGNOSTIC (world-axis / world-frame, unaffected).
    /// With a non-origin pivot the per-ring law becomes
    ///   ringVert_k(v) = (k/N)·offset + insetShiftDelta(v)
    ///                 + pivot + Scale_k( Rotate_k( E_src(v) − pivot ) ).
    size_t extendEdgesByMask(in bool[] mask,
                             float inset, float shift,
                             Vec3 offset, Vec3 rotateDeg, Vec3 scale,
                             int segments, Vec3 pivot = Vec3(0, 0, 0)) {
        import math : Vec3, cross, dot, normalize;
        import std.math : sin, cos, abs, PI;
        if (mask.length != edges.length) return 0;
        if (segments < 1) segments = 1;    // clamp: N≥1. N=1 is the base ring of
                                           // the general loop (same topology/
                                           // order as pre-Phase-3; see doc above).
        // DoS backstop (task 0365 P1): `segments` allocates one new ring of
        // verts + bridge faces per step; Param `.min()/.max()` hints are
        // UI-only and do not clamp a direct/scripted caller reaching this
        // shared kernel.
        enum int MAX_EXTEND_SEGMENTS = 1024;
        if (segments > MAX_EXTEND_SEGMENTS) segments = MAX_EXTEND_SEGMENTS;

        // --- Mesh-edit tracker (mesh_edit_delta). Inert unless a batch is open
        //     (the interactive preview drag runs batchless ⇒ zero cost). This op
        //     is PURE-ADD: addVertex self-logs AddVerts via the Class-P hook; the
        //     appended bridge faces (via `faces ~=`, NOT addFace) need an explicit
        //     recordAddFaces; and the new ridge-edge selection needs a
        //     recordEdgeSelByEnds (endpoint-keyed — edge indices are unstable
        //     across rebuildEdges). NO compactUnreferenced runs (nothing is
        //     removed — pure add), so there is no Reindex/RemoveVerts to compose
        //     and new-vert indices are stable; revert is a tail truncation.
        const bool recExtend = editRecorder_ !is null;
        uint[] preEdgeSelEnds;
        if (recExtend) {
            foreach (i; 0 .. edges.length) {
                if (i < edgeMarks.length && (edgeMarks[i] & Marks.Select)) {
                    preEdgeSelEnds ~= edges[i][0];
                    preEdgeSelEnds ~= edges[i][1];
                }
            }
        }

        // --- Edge → (≤2 faces) adjacency, one pass (no O(E×F) scan). Same idiom
        //     as extrudeEdgesByMask/removeEdgesByMask.
        auto edgeFaces = buildEdgeFaces();

        // --- Gather the selected, extendable edges (≥1 adjacent face). Snapshot
        //     their endpoints + neighbour faces NOW (original index space). Wire
        //     edges (0 adjacent faces) are SKIPPED — the winding rule needs an
        //     adjacent face to orient the bridge quad.
        struct ExtEdge { uint va, vb; int fA, fB; }
        ExtEdge[] exEdges;
        foreach (i; 0 .. edges.length) {
            if (!mask[i]) continue;
            uint va = edges[i][0], vb = edges[i][1];
            auto p = edgeKeyOrdered(va, vb) in edgeFaces;
            if (p is null) continue;
            int fA = (*p)[0], fB = (*p)[1];
            if (fA == -1) continue;     // wire edge — skipped
            exEdges ~= ExtEdge(va, vb, fA, fB);
        }
        if (exEdges.length == 0) return 0;

        // The inset law no longer branches on free-end vs welded corner — every
        // new vert takes the min-norm offset-meet over ALL its incident face
        // planes (see INSET LAW below), so no selected-edge-incidence count is
        // needed here.

        // --- N-plane minimum-norm offset-meet. Solve for the vector `v` of
        //     smallest norm satisfying v·nₖ = dₖ for each (unit normal nₖ, target
        //     dₖ). The min-norm solution lies in span{nₖ}: v = Σ cⱼ nⱼ with the
        //     Gram system G·c = d, Gᵢⱼ = nᵢ·nⱼ. Solved via Gaussian elimination
        //     with partial pivoting + a rank guard (degenerate / parallel planes
        //     drop out, yielding the lower-rank min-norm answer). Written fresh
        //     from the math — `math.offsetMeet` is the 2-plane reference idiom;
        //     this generalises it to the k-plane welded-corner accumulator
        //     (doc/edge_extend_plan.md §Phase-0c; ⊥ cube case reduces to
        //     −inset·Σnₖ). k is small (≤ a handful of distinct faces per corner).
        static Vec3 minNormMeet(in Vec3[] normals, in float[] targets) {
            size_t k = normals.length;
            if (k == 0) return Vec3(0, 0, 0);
            // Gram matrix G (k×k) and rhs d, augmented for Gaussian elimination.
            // k is tiny; use a fixed upper bound to stay @nogc-friendly.
            enum int MAXK = 16;
            // A corner with >16 distinct constraint planes is pathological (a
            // real mesh corner has a handful). Loud in debug; in -release (where
            // asserts strip) truncate rather than overflow the fixed buffers —
            // a truncated weld beats an out-of-bounds write.
            assert(k <= MAXK, "minNormMeet: >16 constraint planes at one corner");
            if (k > MAXK) k = MAXK;
            double[MAXK][MAXK] G;
            double[MAXK]       d;
            foreach (i; 0 .. k) {
                d[i] = targets[i];
                foreach (j; 0 .. k)
                    G[i][j] = cast(double)dot(normals[i], normals[j]);
            }
            // Gaussian elimination with partial pivoting + rank guard. A pivot
            // below tol means that row is (numerically) a linear combination of
            // earlier normals — its constraint is already represented, so we zero
            // its coefficient (min-norm: add nothing along a redundant direction).
            enum double TOL = 1e-9;
            int[MAXK] pivRow;
            foreach (i; 0 .. k) pivRow[i] = -1;
            foreach (col; 0 .. k) {
                // find the best pivot among unused rows in this column
                int best = -1; double bestAbs = TOL;
                foreach (r; 0 .. k) {
                    bool used = false;
                    foreach (c; 0 .. col) if (pivRow[c] == r) { used = true; break; }
                    if (used) continue;
                    double a = G[r][col] < 0 ? -G[r][col] : G[r][col];
                    if (a > bestAbs) { bestAbs = a; best = cast(int)r; }
                }
                if (best < 0) continue;         // rank-deficient column → skip
                pivRow[col] = best;
                double pv = G[best][col];
                foreach (r; 0 .. k) {
                    if (cast(int)r == best) continue;
                    double f = G[r][col] / pv;
                    if (f == 0) continue;
                    foreach (c; 0 .. k) G[r][c] -= f * G[best][c];
                    d[r] -= f * d[best];
                }
            }
            // Back-substitute coefficients c (one per pivoted column).
            double[MAXK] c;
            foreach (i; 0 .. k) c[i] = 0;
            foreach (col; 0 .. k) {
                int r = pivRow[col];
                if (r < 0) continue;            // redundant direction → c=0
                c[col] = d[r] / G[r][col];
            }
            Vec3 v = Vec3(0, 0, 0);
            foreach (j; 0 .. k) v = v + normals[j] * cast(float)c[j];
            return v;
        }

        // --- Per-corner accumulation of constraint planes / boundary shift terms.
        //     Keyed by source vertex. Built from ORIGINAL geometry only (face
        //     normals + edge axes captured before any geometry is appended).
        //
        //     INSET LAW (parity-verified): the perpendicular drop at EVERY new
        //     vert — free end, welded corner, boundary, all the same — is the
        //     min-norm offset-meet `delta·n_f = −inset` over ALL DISTINCT face
        //     planes incident at the source vertex `v` (every face that contains
        //     `v`, NOT just the faces adjacent to the selected edges). There is NO
        //     separate axial term: on a cube the vertex's THIRD perpendicular face
        //     contributes the `−inset` component along the edge axis that earlier
        //     looked like an axial shortening (corner (0.5,0.5,0.5) ∈ top+front+
        //     right ⇒ meet (−0.1,−0.1,−0.1)). A tent free end has only 2 incident
        //     faces, so its meet is the genuine two-plane drop (no spurious axial
        //     pull). A vertex on a single flat face → meet = −inset·n (the boundary
        //     one-plane case). The free-end/weld branch distinction for inset thus
        //     disappears — one law for all corners.
        // Distinct face planes per corner (deduped by face id).
        Vec3[][uint] cornerNormals;          // v → distinct incident face normals
        bool[ulong]  cornerFaceSeen;         // (v<<32|fi) → already counted at v
        Vec3[uint]   cornerShiftTerm;        // v → Σ boundary shift·in-plane-perp
        void addCornerFace(uint v, int fi) {
            if (fi < 0) return;
            ulong fk = (cast(ulong)v << 32) | cast(uint)fi;
            if (fk in cornerFaceSeen) return;
            // Dedup near-parallel planes the way the original corner code deduped
            // distinct faces: skip a face whose normal is (anti-)parallel to one
            // already counted at this corner (the min-norm rank guard would absorb
            // it anyway, but pre-dropping keeps the Gram system small + well-posed).
            Vec3 nf = faceNormal(cast(uint)fi);
            if (auto acc = v in cornerNormals)
                foreach (ref e0; *acc)
                    if (abs(dot(e0, nf)) > 0.999999f) { cornerFaceSeen[fk] = true; return; }
            cornerFaceSeen[fk] = true;
            cornerNormals.update(v,
                () => [nf],
                (ref Vec3[] acc) { acc ~= nf; });
        }
        // Vertex → incident faces, one pass (same idiom as the edge→faces map).
        // Drives the inset meet over ALL faces at the corner. Built only for the
        // source vertices that actually spawn a new vert (the selected edges'
        // endpoints), so the scan touches every face once but records nothing for
        // vertices we never weld.
        bool[uint] needsCorner;
        foreach (ref e; exEdges) { needsCorner[e.va] = true; needsCorner[e.vb] = true; }
        foreach (fi; 0 .. faces.length) {
            auto f = faces[fi];
            foreach (vid; f)
                if (vid in needsCorner) addCornerFace(vid, cast(int)fi);
        }
        // In-plane outward perpendicular of the boundary face at edge (va,vb):
        //     the in-plane direction ⊥ to the edge, pointing AWAY from the face
        //     interior (the free-boundary slide direction `shift` rides on).
        Vec3 boundaryOutwardPerp(uint va, uint vb, int fi) {
            Vec3 t  = normalize(vertices[vb] - vertices[va]);
            Vec3 nf = faceNormal(cast(uint)fi);
            Vec3 d  = cross(nf, t);
            if (d.length < 1e-6f) return Vec3(0, 0, 0);
            d = normalize(d);
            // Point AWAY from the face centroid (outward off the open boundary).
            auto f = faces[fi];
            Vec3 ctr = Vec3(0, 0, 0);
            foreach (vid; f) ctr = ctr + vertices[vid];
            ctr = ctr * (1.0f / cast(float)f.length);
            Vec3 mid = (vertices[va] + vertices[vb]) * 0.5f;
            if (dot(d, ctr - mid) > 0.0f) d = -d;   // outward = away from centroid
            return d;
        }
        void addCornerShift(uint v, Vec3 term) {
            cornerShiftTerm.update(v, () => term, (ref Vec3 acc) { acc = acc + term; });
        }
        // Corner face planes are gathered above over ALL incident faces. Here we
        // only fold in each BOUNDARY edge's `shift·in-plane-outward-perp` term
        // (the free-boundary slide); inset is fully subsumed by the incident-face
        // meet.
        foreach (ref e; exEdges) {
            if (e.fB == -1 && shift != 0.0f) {
                Vec3 perp = boundaryOutwardPerp(e.va, e.vb, e.fA);
                addCornerShift(e.va, perp * shift);
                addCornerShift(e.vb, perp * shift);
            }
        }

        // --- Rotate(E_src about origin) then Scale(about origin), world frame,
        //     parameterised by the ring fraction t = k/N (t=1 = full TRS = the
        //     N=1 law). Rx then Ry then Rz applied in that order to the ORIGINAL
        //     position; each axis angle scaled by t. Scale is the componentwise
        //     LINEAR lerp 1 + t·(scale−1) (geometric s^t ruled out by capture).
        float rxFull = rotateDeg.x * cast(float)(PI / 180.0);
        float ryFull = rotateDeg.y * cast(float)(PI / 180.0);
        float rzFull = rotateDeg.z * cast(float)(PI / 180.0);
        Vec3 applyRS(Vec3 p, float t) {
            float rx = rxFull * t, ry = ryFull * t, rz = rzFull * t;
            // Rx
            {
                float c = cos(rx), s = sin(rx);
                p = Vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
            }
            // Ry
            {
                float c = cos(ry), s = sin(ry);
                p = Vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
            }
            // Rz
            {
                float c = cos(rz), s = sin(rz);
                p = Vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z);
            }
            // Scale (linear lerp toward `scale`) about origin.
            float sx = 1.0f + t * (scale.x - 1.0f);
            float sy = 1.0f + t * (scale.y - 1.0f);
            float sz = 1.0f + t * (scale.z - 1.0f);
            return Vec3(p.x * sx, p.y * sy, p.z * sz);
        }

        // --- Per-source-vertex inset/shift displacement (ring-independent: full
        //     on every ring). Computed once from ORIGINAL geometry, keyed by
        //     source vertex. INSET = min-norm offset-meet over ALL distinct faces
        //     incident at v (free end, weld, interior, boundary alike — see INSET
        //     LAW above). One law, no axial term. SHIFT = each incident boundary
        //     edge's in-plane slide, already accumulated into cornerShiftTerm.
        Vec3[uint] insetShiftOf;
        void computeDelta(uint v) {
            if (v in insetShiftOf) return;
            Vec3 delta = Vec3(0, 0, 0);
            if (auto np = v in cornerNormals) {
                Vec3[] norms = *np;
                float[] tgts;
                tgts.length = norms.length;
                foreach (i; 0 .. norms.length) tgts[i] = -inset;
                delta = minNormMeet(norms, tgts);
            }
            if (auto sp = v in cornerShiftTerm) delta = delta + *sp;
            insetShiftOf[v] = delta;
        }
        foreach (ref e; exEdges) { computeDelta(e.va); computeDelta(e.vb); }

        // --- Per-ring weld maps: ONE new vert per (ring level k, unique source
        //     vertex) incident to ≥1 selected edge (welds chains/loops/star
        //     junctions per ring level). ring 0 is the SOURCE vertex itself (the
        //     inner side of the first bridge); rings 1..N are the new verts.
        //     ringVert_k(v) = (k/N)·offset + insetShiftDelta(v) + applyRS(E_src,k/N).
        //     N=1 ⇒ one ring, t=1, fully reproducing the pre-segments law.
        const int N = segments;
        // ringVertOf[k] maps source vertex → its index in `vertices` for ring k.
        // ring 0 = identity map onto the source vertex (no new geometry); rings
        // 1..N hold the appended new verts.
        uint[uint][] ringVertOf;
        ringVertOf.length = N + 1;
        foreach (k; 1 .. N + 1) {
            float t = cast(float)k / cast(float)N;
            void makeRingVert(uint v) {
                if (v in ringVertOf[k]) return;
                // Pivot-conjugated R/S: pivot + RS(E_src − pivot). At pivot=origin
                // (the default / command path) this is exactly applyRS(E_src) —
                // byte-unchanged. Offset + inset/shift are pivot-agnostic.
                Vec3 pos = pivot + applyRS(vertices[v] - pivot, t)
                         + insetShiftOf[v] + offset * t;
                ringVertOf[k][v] = addVertex(pos);
            }
            foreach (ref e; exEdges) { makeRingVert(e.va); makeRingVert(e.vb); }
        }
        // ring 0 maps each source vertex to itself (the inner side of bridge 1).
        foreach (ref e; exEdges) { ringVertOf[0][e.va] = e.va; ringVertOf[0][e.vb] = e.vb; }

        // --- Orienting-face selection for the bridge winding.
        //
        //     The bridge is `[srcA, newA, newB, srcB]` where srcA→srcB is the
        //     source edge's DIRECTED traversal order WITHIN the orienting face (so
        //     the bridge is manifold-consistent with that face — NOT the raw
        //     edges[] tuple, which would flip ~half the bridges).
        //
        //     Which adjacent face orients a 2-face interior edge is GEOMETRICALLY
        //     UNDER-DETERMINED at a welded fan: the bridge quad is edge-on to the
        //     corner axis, so its normal is ⊥ to that axis and every rotation-
        //     invariant "point outward / sum-of-normals / displacement" test ties
        //     between the two candidate faces (verified numerically against the
        //     golden fan dumps — both faces give identical dot products). The
        //     reference engine's choice tracks its internal face-storage order,
        //     which is not portable. We therefore pick the orienting face by a
        //     two-tier DETERMINISTIC rule:
        //       1. When the two candidate face normals DIFFER, take the one whose
        //          unit normal sorts first under the key (n.y, −n.x, −n.z). This
        //          fixes the star3 fan: the −Y bridge competes between two DISTINCT
        //          (+X vs +Z) faces, and a naive lower-array-index rule orients it
        //          backwards ([2,11,9,6] instead of [6,9,11,2]).
        //       2. When the normals are (near-)EQUAL (the two faces are coplanar —
        //          chain2_asym/chain2_mixed, where every rotation-invariant test
        //          AND the normal comparator tie exactly), fall back to the LOWER
        //          FACE INDEX. On these fixtures vibe3d's face-array order matches
        //          the reference's input order, so lower-index reproduces the
        //          reference choice.
        //     This pair reproduces EVERY golden bridge tuple — cube interior
        //     [6,8,9,7], boundary [3,6,7,0], chain2 [5,8,9,6]/[6,9,10,7], loop4 ×4,
        //     star3 ×3 (incl. the [6,9,11,2] third bridge), and the coplanar
        //     chain2_asym/chain2_mixed bridges. The normal comparator is a
        //     tie-break calibrated to the axis-aligned golden fixtures, not a
        //     derived geometric law: a future non-axis-aligned fan with DISTINCT
        //     competing normals should be re-checked against a fresh capture rather
        //     than silently trusted.
        static double[3] orientKey(Vec3 n) {
            return [cast(double)n.y, cast(double)(-n.x), cast(double)(-n.z)];
        }
        int orientFaceOf(ref ExtEdge e) {
            if (e.fB == -1) return e.fA;          // boundary: the sole face
            auto ka = orientKey(faceNormal(cast(uint)e.fA));
            auto kb = orientKey(faceNormal(cast(uint)e.fB));
            // Lexicographic compare with an epsilon dead-band. Within the band the
            // two normals are (near-)coplanar → tie → lower face index decides.
            foreach (i; 0 .. 3) {
                if (ka[i] < kb[i] - 1e-6) return e.fA;
                if (ka[i] > kb[i] + 1e-6) return e.fB;
            }
            return e.fA < e.fB ? e.fA : e.fB;     // coplanar tie → lower index
        }

        // --- Bridge quads. N stacked quads per edge: src→ring1, ring1→ring2, …,
        //     ring(N−1)→ringN. Each stacked quad keeps the SAME orientation as
        //     the single N=1 bridge: [innerA, outerA, outerB, innerB] where
        //     inner = ring k−1's pair, outer = ring k's pair, and A/B follow the
        //     source edge's DIRECTED traversal order within the orienting face.
        size_t firstBridge = faces.length;
        foreach (ref e; exEdges) {
            int orientFace = orientFaceOf(e);
            // Directed order of the source edge within orientFace.
            uint srcA = e.va, srcB = e.vb;
            auto f = faces[orientFace];
            foreach (k; 0 .. f.length) {
                uint u = f[k], w = f[(k + 1) % f.length];
                if (u == e.va && w == e.vb) { srcA = e.va; srcB = e.vb; break; }
                if (u == e.vb && w == e.va) { srcA = e.vb; srcB = e.va; break; }
            }
            foreach (k; 1 .. N + 1) {
                uint innerA = ringVertOf[k - 1][srcA];
                uint innerB = ringVertOf[k - 1][srcB];
                uint outerA = ringVertOf[k][srcA];
                uint outerB = ringVertOf[k][srcB];
                faces ~= [innerA, outerA, outerB, innerB];
            }
        }

        // --- Hand-extend the parallel per-face arrays (pure-add trap: neither
        //     addVertex nor compactUnreferenced sizes these). Each bridge inherits
        //     the material of its orienting (adjacent) face. N stacked bridges per
        //     edge, all inheriting the same orienting-face material.
        foreach (bi, ref e; exEdges) {
            int orientFace = orientFaceOf(e);
            uint mat  = (orientFace < faceMaterial.length ? faceMaterial[orientFace] : 0u);
            uint part = (orientFace < facePart.length     ? facePart[orientFace]     : 0u);
            foreach (k; 1 .. N + 1) {
                faceMaterial       ~= mat;
                facePart           ~= part;
                faceSelectionOrder ~= 0;
            }
        }
        resizeSubpatch();
        // Task 0389: each stacked bridge inherits Subpatch from the SAME
        // orienting face the material/part loop above already resolves from
        // — same nested iteration order as the face-emission loop, so a
        // running cursor maps 1:1 onto the just-appended bridge tail
        // [firstBridge .. $).
        {
            size_t cursor = firstBridge;
            foreach (bi, ref e; exEdges) {
                int orientFace = orientFaceOf(e);
                bool sub = isFaceSubpatch(orientFace);
                foreach (k; 1 .. N + 1) {
                    setFaceSubpatch(cursor, sub);
                    ++cursor;
                }
            }
        }

        // Tracker: the bridge faces were appended via `faces ~=` (NOT addFace), so
        // they are NOT auto-logged. Record them as one AddFaces([F0..F1)) entry.
        // No compaction runs (pure add) → the appended block stays the tail and
        // reverts by truncation.
        if (recExtend && faces.length > firstBridge) {
            uint[][] bridgeLists;
            foreach (fi; firstBridge .. faces.length) bridgeLists ~= faces[fi].dup;
            editRecorder_.recordAddFaces(cast(uint)firstBridge,
                                         cast(uint)faces.length, bridgeLists);
        }

        // --- Record the new OUTER ridge edges (the outermost ring k=N vert pair
        //     per bridge) BY INDEX so we can reselect them after rebuildEdges. No
        //     compaction runs (pure add), so vert indices are STABLE; recording
        //     indices (not positions) avoids the stacked-coincident-ring ambiguity
        //     under identity TRS (where every ring shares a position and a
        //     position lookup would land on an inner ring). rebuildEdges renumbers
        //     the EDGE array, so the edgeKey→index lookup via edgeIndexMap is the
        //     stable path.
        uint[2][] ridgeEdgeIdx;
        ridgeEdgeIdx.reserve(exEdges.length);
        foreach (ref e; exEdges) {
            uint na = ringVertOf[N][e.va], nb = ringVertOf[N][e.vb];
            ridgeEdgeIdx ~= [na, nb];
        }

        // --- Tail: rebuild edges + loops, size selections. NO compactUnreferenced
        //     (pure add — nothing is removed; new-vert indices stay stable). The
        //     source edge now has 3 adjacent faces (its 2 cube faces + the bridge);
        //     buildLoops emits a one-time non-manifold stderr warning and ring
        //     adjacency near that edge is known-degraded (acceptable v1).
        rebuildEdges();
        buildLoops();
        resizeVertexSelection();
        resizeFaceSelection();
        clearEdgeSelectionResize();    // resize edge marks + drop all edge selection

        // New selection = the new OUTERMOST-ring ridge edges (so a follow-up op
        // chains off the outer ridge).
        foreach (ref pr; ridgeEdgeIdx) {
            ulong rk = edgeKey(pr[0], pr[1]);
            if (auto p = rk in edgeIndexMap)
                selectEdge(cast(int)*p);
        }
        clearVertexSelection();
        clearFaceSelection();

        // Tracker: record the edge-selection delta (endpoint-keyed). before = the
        // pre-extend selected edges (restored by revert); after = the new ridge
        // selection (restored by apply/redo).
        if (recExtend) {
            uint[] postEdgeSelEnds;
            foreach (i; 0 .. edges.length) {
                if (i < edgeMarks.length && (edgeMarks[i] & Marks.Select)) {
                    postEdgeSelEnds ~= edges[i][0];
                    postEdgeSelEnds ~= edges[i][1];
                }
            }
            editRecorder_.recordEdgeSelByEnds(preEdgeSelEnds, postEdgeSelEnds);
        }

        commitChange(MeshEditScope.Geometry);
        return exEdges.length;
    }

    /// Radial-array the faces marked true in `mask`: insert `count-1`
    /// new copies, each rotated around the axis (`axis` ∈ {'X','Y','Z'})
    /// through `center` by `i * totalAngle / count` (i = 1..count-1),
    /// and optionally translated by `i * extraShift` (for helices /
    /// spirals). `count` ≤ 1 ⇒ no-op (count includes the original).
    /// `weld > 0` folds coincident verts between
    /// adjacent copies and drops duplicate faces — primarily useful
    /// for closed 360° rings where the first and last steps abut.
    ///
    /// `count` is clamped to `MAX_RADIAL_ARRAY_COUNT` internally — this is
    /// the durable safety net for BOTH callers that reach this shared
    /// kernel (the one-shot `mesh.radial_array` command and the
    /// interactive `mesh.radialArrayTool`): an unbounded `count` (e.g. a
    /// scripted `tool.attr ... count 100000000`) would otherwise allocate
    /// `count * selectedFaceCount` new faces/verts synchronously — an easy
    /// DoS/OOM. UI-level Param hints (`.max().enforceBounds()`) are a
    /// second, shallower line of defense that keeps the common interactive
    /// path from ever reaching this clamp in practice.
    ///
    /// Returns the number of new faces inserted.
    size_t radialArrayFaces(in bool[] mask, int count, char axis, Vec3 center,
                            float totalAngle, Vec3 extraShift, float weld) {
        import math : mulMV, pivotRotationMatrix;
        enum int MAX_RADIAL_ARRAY_COUNT = 256;
        if (count > MAX_RADIAL_ARRAY_COUNT) count = MAX_RADIAL_ARRAY_COUNT;
        if (mask.length != faces.length) return 0;
        if (count <= 1) return 0;
        if (axis != 'X' && axis != 'Y' && axis != 'Z') return 0;
        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0) return 0;

        size_t[] sourceFaces;
        sourceFaces.reserve(selCount);
        foreach (fi, ref f; faces)
            if (mask[fi]) sourceFaces ~= fi;
        size_t origFaceCount = faces.length;
        size_t[] newFaceIndices;

        Vec3 axisVec;
        if      (axis == 'X') axisVec = Vec3(1, 0, 0);
        else if (axis == 'Y') axisVec = Vec3(0, 1, 0);
        else                  axisVec = Vec3(0, 0, 1);

        float stepAngle = totalAngle / cast(float)count;

        foreach (step; 1 .. count) {
            float ang = stepAngle * step;
            Vec3  shift = Vec3(extraShift.x * step,
                               extraShift.y * step,
                               extraShift.z * step);
            auto rotM = pivotRotationMatrix(center, axisVec, ang);

            uint[uint] vertMap;
            foreach (fi; sourceFaces) {
                foreach (vid; faces[fi]) {
                    if (vid !in vertMap) {
                        vertMap[vid] = cast(uint)vertices.length;
                        Vec3 p = vertices[vid];
                        auto v4 = Vec4(p.x, p.y, p.z, 1.0f);
                        auto r4 = mulMV(rotM, v4);
                        vertices ~= Vec3(r4.x + shift.x,
                                         r4.y + shift.y,
                                         r4.z + shift.z);
                    }
                }
            }
            foreach (fi; sourceFaces) {
                auto src = faces[fi];
                uint[] cloned;
                cloned.length = src.length;
                foreach (k, vid; src) cloned[k] = vertMap[vid];
                newFaceIndices ~= faces.length;
                faces ~= cloned;
            }
        }

        // Re-derive edges from the new face list.
        rebuildEdges();

        resizeSubpatch();
        faceSelectionOrder.length = faces.length;
        resizeFaceSelection();
        faceMaterial.length       = faces.length;
        facePart.length           = faces.length;
        foreach (fi; 0 .. origFaceCount) {
            deselectFace(cast(int)fi);
        }
        faceSelectionOrderCounter = 0;
        foreach (idx; newFaceIndices) {
            size_t srcFi = sourceFaces[(idx - origFaceCount) % selCount];
            setFaceSubpatch(idx, isFaceSubpatch(srcFi));
            faceMaterial[idx] = (srcFi < faceMaterial.length ? faceMaterial[srcFi] : 0u);
            facePart[idx]     = (srcFi < facePart.length     ? facePart[srcFi]     : 0u);
            selectFace(cast(int)idx);
        }
        resizeVertexSelection();
        clearVertexSelection();
        resizeEdgeSelection();
        clearEdgeSelection();

        if (weld > 0.0f) {
            double epsSq = cast(double)weld * cast(double)weld;
            if (weldCoincidentVertices(epsSq) > 0) {
                import std.algorithm.sorting : sort;
                import std.format : format;
                bool[string] seenFp;
                uint[][] keptFaces;
                bool[]   keptSubpatch;
                int[]    keptOrder;
                bool[]   keptSelected;
                uint[]   keptMaterial;
                uint[]   keptPart;
                keptFaces   .reserve(faces.length);
                keptSubpatch.reserve(faces.length);
                keptOrder   .reserve(faces.length);
                keptSelected.reserve(faces.length);
                keptMaterial.reserve(faces.length);
                keptPart    .reserve(faces.length);
                foreach (fi, ref f; faces) {
                    auto sorted = f.dup;
                    sort(sorted);
                    string fp = format("%(%d,%)", sorted);
                    if (fp in seenFp) continue;
                    seenFp[fp] = true;
                    keptFaces    ~= f;
                    keptSubpatch ~= isFaceSubpatch(fi);
                    keptOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
                    keptSelected ~= (fi < selectedFaces.length      ? selectedFaces[fi]      : false);
                    keptMaterial ~= (fi < faceMaterial.length       ? faceMaterial[fi]       : 0u);
                    keptPart     ~= (fi < facePart.length           ? facePart[fi]           : 0u);
                }
                faces              = keptFaces;
                setFaceSubpatchFrom(keptSubpatch);
                faceSelectionOrder = keptOrder;
                setFacesSelectedFrom(keptSelected);
                faceMaterial       = keptMaterial;
                facePart           = keptPart;
                rebuildEdges();
                clearEdgeSelectionResize();
                compactUnreferenced();
            }
        }

        buildLoops();
        commitChange(MeshEditScope.Geometry);
        return newFaceIndices.length;
    }

    /// Linear-array the faces marked true in `mask`: insert `count-1`
    /// new copies, each shifted from the original by `i * offset`
    /// (i = 1..count-1). `count` ≤ 1 ⇒ no-op (the count includes the
    /// original). When `weld > 0`, coincident verts
    /// between consecutive copies are welded and identical seam faces
    /// dropped (same dedup pass as `mirrorFaces`).
    ///
    /// Selection ends on the newly created copies (originals deselected
    /// for face selection, vert / edge selections cleared).
    /// Returns the number of new faces inserted.
    ///
    /// Rotate / scale per-step variants are deferred to a follow-up —
    /// per-step rotation pivot semantics overlap with Radial Array
    /// (which has its own pivot/axis schema) so they live in that
    /// command's surface, not here.
    size_t arrayFaces(in bool[] mask, int count, Vec3 offset, float weld) {
        if (mask.length != faces.length) return 0;
        if (count <= 1) return 0;
        // DoS backstop (task 0365 P1): `count` allocates `count-1` new
        // copies of every masked face; Param `.min()` hints are UI-only and
        // do not clamp a direct/scripted caller reaching this shared kernel.
        enum int MAX_ARRAY_COUNT = 256;
        if (count > MAX_ARRAY_COUNT) count = MAX_ARRAY_COUNT;
        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0) return 0;

        // Snapshot face indices to clone BEFORE any appending starts —
        // we need to clone the originals N-1 times, not the already-
        // appended copies.
        size_t[] sourceFaces;
        sourceFaces.reserve(selCount);
        foreach (fi, ref f; faces)
            if (mask[fi]) sourceFaces ~= fi;
        size_t origFaceCount = faces.length;
        size_t[] newFaceIndices;

        // For each step i ∈ [1..count-1], clone the original masked
        // verts at offset i*step and emit cloned faces referencing them.
        // vertMap is rebuilt per step so each copy gets a fresh set of
        // verts (no accidental sharing between copies).
        foreach (step; 1 .. count) {
            uint[uint] vertMap;
            Vec3 shift = Vec3(offset.x * step, offset.y * step, offset.z * step);
            foreach (fi; sourceFaces) {
                foreach (vid; faces[fi]) {
                    if (vid !in vertMap) {
                        vertMap[vid] = cast(uint)vertices.length;
                        Vec3 p = vertices[vid];
                        vertices ~= Vec3(p.x + shift.x, p.y + shift.y, p.z + shift.z);
                    }
                }
            }
            foreach (fi; sourceFaces) {
                auto src = faces[fi];
                uint[] cloned;
                cloned.length = src.length;
                foreach (k, vid; src) cloned[k] = vertMap[vid];
                newFaceIndices ~= faces.length;
                faces ~= cloned;
            }
        }

        // Re-derive edges from the new face list.
        rebuildEdges();

        // Subpatch + face-order arrays follow the new face count. New
        // faces inherit subpatch from their source; selection switches
        // to the new copies.
        resizeSubpatch();
        faceSelectionOrder.length = faces.length;
        resizeFaceSelection();
        faceMaterial.length       = faces.length;
        facePart.length           = faces.length;
        foreach (fi; 0 .. origFaceCount) {
            deselectFace(cast(int)fi);
        }
        faceSelectionOrderCounter = 0;
        // Map each new face index back to its source face for subpatch
        // inheritance. The cloning loop pushes (count-1)*selCount faces
        // in [source, source, ..., source] order per step, so we can
        // recover the source via modulo.
        foreach (idx; newFaceIndices) {
            size_t srcFi = sourceFaces[(idx - origFaceCount) % selCount];
            setFaceSubpatch(idx, isFaceSubpatch(srcFi));
            faceMaterial[idx] = (srcFi < faceMaterial.length ? faceMaterial[srcFi] : 0u);
            facePart[idx]     = (srcFi < facePart.length     ? facePart[srcFi]     : 0u);
            selectFace(cast(int)idx);
        }
        resizeVertexSelection();
        clearVertexSelection();
        resizeEdgeSelection();
        clearEdgeSelection();

        // Optional weld + face-fingerprint dedup — identical to the
        // mirrorFaces tail. Welds coincident verts between consecutive
        // copies (e.g. cap-to-cap arrays where step magnitude equals
        // the source's extent along one axis) and removes any face
        // collapsed to a duplicate of an earlier face.
        if (weld > 0.0f) {
            double epsSq = cast(double)weld * cast(double)weld;
            if (weldCoincidentVertices(epsSq) > 0) {
                import std.algorithm.sorting : sort;
                import std.format : format;
                bool[string] seenFp;
                uint[][] keptFaces;
                bool[]   keptSubpatch;
                int[]    keptOrder;
                bool[]   keptSelected;
                uint[]   keptMaterial;
                uint[]   keptPart;
                keptFaces   .reserve(faces.length);
                keptSubpatch.reserve(faces.length);
                keptOrder   .reserve(faces.length);
                keptSelected.reserve(faces.length);
                keptMaterial.reserve(faces.length);
                keptPart    .reserve(faces.length);
                foreach (fi, ref f; faces) {
                    auto sorted = f.dup;
                    sort(sorted);
                    string fp = format("%(%d,%)", sorted);
                    if (fp in seenFp) continue;
                    seenFp[fp] = true;
                    keptFaces    ~= f;
                    keptSubpatch ~= isFaceSubpatch(fi);
                    keptOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
                    keptSelected ~= (fi < selectedFaces.length      ? selectedFaces[fi]      : false);
                    keptMaterial ~= (fi < faceMaterial.length       ? faceMaterial[fi]       : 0u);
                    keptPart     ~= (fi < facePart.length           ? facePart[fi]           : 0u);
                }
                faces              = keptFaces;
                setFaceSubpatchFrom(keptSubpatch);
                faceSelectionOrder = keptOrder;
                setFacesSelectedFrom(keptSelected);
                faceMaterial       = keptMaterial;
                facePart           = keptPart;
                rebuildEdges();
                clearEdgeSelectionResize();
                compactUnreferenced();
            }
        }

        buildLoops();
        commitChange(MeshEditScope.Geometry);
        return newFaceIndices.length;
    }

    /// 3-axis GRID array — generalizes `arrayFaces` above to independent
    /// Count/Offset per axis (`numX × numY × numZ` total instances,
    /// INCLUDING the source at grid index (0,0,0)), plus per-clone
    /// Jitter/Scale/Rotate/Replace-Source/Invert-Polygons/Merge-Vertices.
    /// Backs the interactive Array tool (`tools/array_tool.d`,
    /// `mesh.arrayTool`, task 0355) — grounded in the captured reference
    /// toolcard's 23-attribute "Array Generator" + "Clone Effector" panel
    /// (see `doc/tasks/*/0355-array-tool.md`). `arrayFaces` above is left
    /// byte-for-byte UNTOUCHED — its callers (`mesh.array` one-shot command,
    /// `CloneTool`) keep their exact 1D-line behaviour; this is an
    /// ADDITIVE sibling, not a replacement.
    ///
    /// Grid layout: for step index (i,j,k) ∈ [0,numX)×[0,numY)×[0,numZ),
    /// the per-axis translation is `i*stepX, j*stepY, k*stepZ`, where
    /// `stepX/Y/Z` is `offset.x/y/z` directly (per-STEP spacing) unless
    /// `between` is set, in which case it is re-derived so `offset` reads
    /// as the total span from the FIRST to the LAST clone along that axis
    /// (`offset.x/(numX-1)` when numX>1, else 0 — a single-count axis has
    /// no span to divide).
    ///
    /// Scale (`scale`, 1.0 = 100%) and Rotate (`rotateDeg`, ZYX euler
    /// degrees via `matrixFromEulerZYX` — the SAME convention the
    /// transform tools use) are applied UNIFORMLY to every clone (not
    /// accumulated/stepped by grid index — matches the captured "All
    /// cloned elements receive the same amount of scaling" semantics),
    /// about a PIVOT = the mask's own vertex centroid, captured once
    /// before any mutation. NOTE: the reference capture did not confirm
    /// an exact scale/rotate pivot for the interactive tool (not exercised
    /// by the captured parity case, which uses the flat 100%/0° defaults)
    /// — the mask centroid is this port's documented choice, not a
    /// verified-live value; see the task's Лог for this gap.
    ///
    /// Jitter (`jitter`) is ONE random per-CLONE offset (not per-vertex —
    /// "Max random per-clone offset variation" per the captured spec),
    /// drawn from a FIXED-seed `Mt19937` (deterministic across runs and
    /// platforms — same convention as `commands.mesh.jitter.MeshJitter`),
    /// so the interactive tool and any parity fixture stay byte-
    /// reproducible. Default 0/0/0 is a pure no-op.
    ///
    /// `replaceSource` (captured default OFF): when true, the ORIGINAL
    /// selected faces' vertices are ALSO transformed IN PLACE by the
    /// (0,0,0) slot's scale/rotate/jitter (shift is always zero for that
    /// slot) instead of being left byte-untouched — "the source is
    /// removed and replaced by a clone" (Jitter/Scale/Rotate now apply to
    /// what was the source). When false (default), grid slot (0,0,0) IS
    /// the untouched original: no new geometry is built for it.
    ///
    /// `invertPolygons`: reverses winding on every NEWLY BUILT clone face
    /// (and on the in-place-mutated originals too, when `replaceSource` is
    /// on — they count as "cloned geometry" in that mode). The untouched
    /// (0,0,0) original is never flipped while `replaceSource` is off.
    ///
    /// `mergeVertices`/`mergeDistance`: the reference's boolean+threshold
    /// pair (captured default OFF) — a real default-semantics divergence
    /// from `arrayFaces`'s always-on `weld` epsilon (default 0.001). When
    /// on, reuses the identical weld + face-fingerprint-dedup tail as
    /// `arrayFaces`/`mirrorFaces`.
    ///
    /// DoS guard (code review B1): `numX/numY/numZ` are each UI-clamped by
    /// `ArrayTool.params()`, but this is a public Mesh method any caller can
    /// drive directly, and 3 independently-bounded axes still multiply into
    /// a huge product. `totalSlots` is capped at `MAX_ARRAY_GRID_SLOTS`
    /// (10,000) — over that, the call is a clean no-op (returns 0) rather
    /// than building an unbounded number of clones.
    ///
    /// Ordering guard (code review S1): every clone — including the
    /// (0,0,0) slot when `replaceSource` mutates it IN PLACE — reads from
    /// `origPos`/`origFaceVerts`, a snapshot taken ONCE before the grid
    /// loop starts. Without this, since (0,0,0) is always visited first,
    /// later clones would read the ALREADY-transformed source position/
    /// winding and compound the transform (position) or cancel it out
    /// (winding, under `invertPolygons`) instead of each being the
    /// original transformed exactly once.
    ///
    /// Returns the number of NEW faces inserted (0 ⇒ no grid geometry was
    /// added; note this can be 0 while `replaceSource` still mutated the
    /// originals in place at a 1×1×1 count).
    size_t arrayFacesGrid(in bool[] mask, int numX, int numY, int numZ,
                          Vec3 offset, Vec3 jitter, Vec3 scale, Vec3 rotateDeg,
                          bool between, bool replaceSource, bool invertPolygons,
                          bool mergeVertices, float mergeDistance) {
        import std.random : Mt19937, uniform01;
        import std.algorithm.mutation : reverse;

        if (mask.length != faces.length) return 0;
        if (numX < 1) numX = 1;
        if (numY < 1) numY = 1;
        if (numZ < 1) numZ = 1;
        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0) return 0;
        size_t totalSlots = cast(size_t)numX * cast(size_t)numY * cast(size_t)numZ;
        // 1×1×1 with replaceSource=false is a true no-op (nothing to add,
        // nothing to replace). 1×1×1 with replaceSource=true still falls
        // through — it transforms the originals in place (null shift).
        if (totalSlots <= 1 && !replaceSource) return 0;
        // Defense-in-depth DoS cap (review B1): the per-axis Count params are
        // UI-clamped to a sane max each (see ArrayTool.params()), but this is
        // a public Mesh method any caller can drive directly, and 3
        // independently-bounded axes still multiply into a huge product
        // (e.g. 64×64×64 ≈ 262k). Reject outright rather than silently
        // reshape the requested grid down to something smaller — the caller
        // asked for a specific Count X/Y/Z and a partial/rescaled grid would
        // be a worse surprise than a clean no-op.
        enum size_t MAX_ARRAY_GRID_SLOTS = 10_000;
        if (totalSlots > MAX_ARRAY_GRID_SLOTS) return 0;

        size_t[] sourceFaces;
        sourceFaces.reserve(selCount);
        foreach (fi, ref f; faces)
            if (mask[fi]) sourceFaces ~= fi;

        // Pivot for scale/rotate: the mask's own vertex centroid. Captured
        // ONCE from the ORIGINAL (pre-mutation) positions, alongside a
        // snapshot of every mask vertex's original position (`origPos`) —
        // review S1: with `replaceSource` on, the (0,0,0) slot is always
        // visited FIRST (the grid loop starts at i=j=k=0) and mutates
        // `vertices[vid]` IN PLACE; every subsequent clone must still read
        // the PRE-mutation position, not the already-transformed one, or
        // the transform compounds across clones. `cloneVertex` below is fed
        // exclusively from `origPos`, never a live `vertices[vid]` read.
        // Same rationale extends to face WINDING: `origFaceVerts` snapshots
        // each source face's untouched vertex-id order. Without it, a
        // replaceSource+invertPolygons(count>1) combo has the same
        // order-dependency bug as S1 one level up — the (0,0,0) slot
        // reverses `faces[fi]` IN PLACE, and every later clone that read
        // `faces[fi]` directly would clone the ALREADY-reversed order and
        // then reverse it AGAIN, net cancelling back to the original
        // winding for every clone after the first.
        Vec3 pivot = Vec3(0, 0, 0);
        Vec3[uint] origPos;
        uint[][size_t] origFaceVerts;
        {
            size_t n = 0;
            foreach (fi; sourceFaces) {
                origFaceVerts[fi] = faces[fi].dup;
                foreach (vid; faces[fi])
                    if (vid !in origPos) {
                        origPos[vid] = vertices[vid];
                        pivot = pivot + vertices[vid];
                        ++n;
                    }
            }
            if (n > 0) pivot = pivot * (1.0f / n);
        }

        float stepX = between ? (numX > 1 ? offset.x / (numX - 1) : 0.0f) : offset.x;
        float stepY = between ? (numY > 1 ? offset.y / (numY - 1) : 0.0f) : offset.y;
        float stepZ = between ? (numZ > 1 ? offset.z / (numZ - 1) : 0.0f) : offset.z;

        bool anyRotate = (rotateDeg.x != 0.0f || rotateDeg.y != 0.0f || rotateDeg.z != 0.0f);
        float[16] rotMat = anyRotate ? matrixFromEulerZYX(rotateDeg) : identityMatrix;

        // Deterministic per-clone jitter — fixed seed, same convention as
        // commands.mesh.jitter.MeshJitter. Drained once per grid slot
        // (including the skipped/untouched source slot) so the sequence
        // never depends on replaceSource/invertPolygons, only on the grid
        // shape — same "drain regardless" rationale as MeshJitter.
        Mt19937 rng;
        rng.seed(0u);
        Vec3 jitterFor() {
            float ju = uniform01!float(rng) * 2.0f - 1.0f;
            float jv = uniform01!float(rng) * 2.0f - 1.0f;
            float jw = uniform01!float(rng) * 2.0f - 1.0f;
            return Vec3(ju * jitter.x, jv * jitter.y, jw * jitter.z);
        }

        // Transform one ORIGINAL vertex position into a clone's local
        // position: de-pivot -> scale -> rotate -> re-pivot -> translate.
        Vec3 cloneVertex(Vec3 p, Vec3 shift, Vec3 jit) {
            Vec3 local = p - pivot;
            local = Vec3(local.x * scale.x, local.y * scale.y, local.z * scale.z);
            if (anyRotate) local = transformPoint(rotMat, local);
            return pivot + local + shift + jit;
        }

        size_t origFaceCount = faces.length;
        size_t[] newFaceIndices;

        foreach (i; 0 .. numX) {
            foreach (j; 0 .. numY) {
                foreach (k; 0 .. numZ) {
                    bool isSourceSlot = (i == 0 && j == 0 && k == 0);
                    Vec3 shift = isSourceSlot ? Vec3(0, 0, 0)
                                              : Vec3(i * stepX, j * stepY, k * stepZ);
                    Vec3 jit = jitterFor();

                    if (isSourceSlot) {
                        if (!replaceSource) continue;   // untouched original stays as-is
                        // replaceSource: mutate the ORIGINAL verts in place
                        // (shift is always (0,0,0) here), no new verts/faces.
                        // Reads from `origPos` (the PRE-mutation snapshot),
                        // never the live `vertices[vid]` — see the S1 fix
                        // note above the pivot computation.
                        bool[uint] doneV;
                        foreach (fi; sourceFaces) {
                            foreach (vid; origFaceVerts[fi])
                                if (vid !in doneV) {
                                    doneV[vid] = true;
                                    vertices[vid] = cloneVertex(origPos[vid], shift, jit);
                                }
                        }
                        if (invertPolygons)
                            foreach (fi; sourceFaces) {
                                faces[fi] = origFaceVerts[fi].dup;
                                reverse(faces[fi]);
                            }
                        continue;
                    }

                    uint[uint] vertMap;
                    foreach (fi; sourceFaces) {
                        foreach (vid; origFaceVerts[fi]) {
                            if (vid !in vertMap) {
                                vertMap[vid] = cast(uint)vertices.length;
                                vertices ~= cloneVertex(origPos[vid], shift, jit);
                            }
                        }
                    }
                    foreach (fi; sourceFaces) {
                        auto src = origFaceVerts[fi];
                        uint[] cloned;
                        cloned.length = src.length;
                        foreach (m, vid; src) cloned[m] = vertMap[vid];
                        if (invertPolygons) reverse(cloned);
                        newFaceIndices ~= faces.length;
                        faces ~= cloned;
                    }
                }
            }
        }

        rebuildEdges();

        resizeSubpatch();
        faceSelectionOrder.length = faces.length;
        resizeFaceSelection();
        faceMaterial.length       = faces.length;
        facePart.length           = faces.length;
        foreach (fi; 0 .. origFaceCount) {
            deselectFace(cast(int)fi);
        }
        faceSelectionOrderCounter = 0;
        foreach (idx; newFaceIndices) {
            size_t srcFi = sourceFaces[(idx - origFaceCount) % selCount];
            setFaceSubpatch(idx, isFaceSubpatch(srcFi));
            faceMaterial[idx] = (srcFi < faceMaterial.length ? faceMaterial[srcFi] : 0u);
            facePart[idx]     = (srcFi < facePart.length     ? facePart[srcFi]     : 0u);
            selectFace(cast(int)idx);
        }
        // replaceSource re-selects the (mutated) originals too — they are
        // now part of the array's output geometry, not leftover source.
        if (replaceSource)
            foreach (fi; sourceFaces) selectFace(cast(int)fi);

        resizeVertexSelection();
        clearVertexSelection();
        resizeEdgeSelection();
        clearEdgeSelection();

        // Merge Vertices (boolean) + Distance (threshold) — default OFF,
        // unlike arrayFaces's always-on weld epsilon. Identical weld +
        // face-fingerprint-dedup tail as arrayFaces/mirrorFaces.
        if (mergeVertices && mergeDistance > 0.0f) {
            double epsSq = cast(double)mergeDistance * cast(double)mergeDistance;
            if (weldCoincidentVertices(epsSq) > 0) {
                import std.algorithm.sorting : sort;
                import std.format : format;
                bool[string] seenFp;
                uint[][] keptFaces;
                bool[]   keptSubpatch;
                int[]    keptOrder;
                bool[]   keptSelected;
                uint[]   keptMaterial;
                uint[]   keptPart;
                keptFaces   .reserve(faces.length);
                keptSubpatch.reserve(faces.length);
                keptOrder   .reserve(faces.length);
                keptSelected.reserve(faces.length);
                keptMaterial.reserve(faces.length);
                keptPart    .reserve(faces.length);
                foreach (fi, ref f; faces) {
                    auto sorted = f.dup;
                    sort(sorted);
                    string fp = format("%(%d,%)", sorted);
                    if (fp in seenFp) continue;
                    seenFp[fp] = true;
                    keptFaces    ~= f;
                    keptSubpatch ~= isFaceSubpatch(fi);
                    keptOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
                    keptSelected ~= (fi < selectedFaces.length      ? selectedFaces[fi]      : false);
                    keptMaterial ~= (fi < faceMaterial.length       ? faceMaterial[fi]       : 0u);
                    keptPart     ~= (fi < facePart.length           ? facePart[fi]           : 0u);
                }
                faces              = keptFaces;
                setFaceSubpatchFrom(keptSubpatch);
                faceSelectionOrder = keptOrder;
                setFacesSelectedFrom(keptSelected);
                faceMaterial       = keptMaterial;
                facePart           = keptPart;
                rebuildEdges();
                clearEdgeSelectionResize();
                compactUnreferenced();
            }
        }

        buildLoops();
        commitChange(MeshEditScope.Geometry);
        return newFaceIndices.length;
    }

    /// Mirror the faces marked true in `mask` across the plane defined by
    /// `center` + (unit or non-unit) `normal` — the general, arbitrarily-
    /// oriented form of `mirrorFaces` below (which delegates here). Verts
    /// are cloned and reflected via the same formula as `mirrorPosition`
    /// (symmetry.d:41): `v' = v - normal*(2*dot(v-center, normal))`. When
    /// `flipNormals` is true the winding of each cloned face is reversed so
    /// the mirrored surface has outward-facing normals — a reflection is
    /// orientation-reversing for ANY plane, so this pass is plane-independent
    /// and identical to the axis-aligned path. When `weld > 0`, coincident
    /// verts (seam verts that lie on the mirror plane, plus any pre-existing
    /// coincidences) are welded via `weldCoincidentVertices(weld*weld)` and
    /// orphan verts are compacted.
    ///
    /// Selection ends on the newly created mirrored faces (plus any
    /// originals not in the mirror mask). Returns the number of new faces
    /// actually inserted; 0 = noop (empty mask or near-zero-length normal).
    size_t mirrorFacesPlane(in bool[] mask, Vec3 center, Vec3 normal, float weld, bool flipNormals) {
        if (mask.length != faces.length) return 0;
        float nlen = normal.length;
        if (nlen < 1e-9f) return 0;
        normal = normal / nlen;
        size_t toMirror = 0;
        foreach (b; mask) if (b) ++toMirror;
        if (toMirror == 0) return 0;

        // Vertex indices below this bound are PRE-EXISTING (captured before
        // any clone is appended below) — see the weld pass's use of
        // `weldCoincidentVertices`'s `protectBelow` param further down.
        const size_t origVertexCount = vertices.length;

        // Clone each unique vert referenced by a masked face exactly once.
        uint[uint] vertMap;
        foreach (fi, ref f; faces) {
            if (!mask[fi]) continue;
            foreach (vid; f) {
                if (vid !in vertMap) {
                    vertMap[vid] = cast(uint)vertices.length;
                    vertices ~= vertices[vid];
                }
            }
        }
        // Snapshot face indices to mirror BEFORE we start appending —
        // see duplicateSelectedFaces for the same reason.
        size_t[] toClone;
        toClone.reserve(toMirror);
        foreach (fi, ref f; faces)
            if (mask[fi]) toClone ~= fi;

        size_t origFaceCount = faces.length;
        foreach (fi; toClone) {
            auto src = faces[fi];
            uint[] cloned;
            cloned.length = src.length;
            if (flipNormals) {
                // Reverse winding so the reflected face has its normal
                // pointing outward instead of into the cloned solid.
                foreach (k, vid; src) cloned[src.length - 1 - k] = vertMap[vid];
            } else {
                foreach (k, vid; src) cloned[k] = vertMap[vid];
            }
            faces ~= cloned;
        }

        // Reflect every cloned vert across the mirror plane. `vertMap`
        // values are the new vert indices (≥ original vertices.length
        // at the time the clone began), so iterating it covers exactly
        // the new range without disturbing the originals. Same formula as
        // symmetry.d's mirrorPosition; for a unit axis normal this is
        // TOLERANCE-identical (not bit-for-bit, see the mirrorFaces wrapper's
        // doc comment) to the prior per-component axis-aligned formula.
        foreach (oldVid, newVid; vertMap) {
            Vec3 v = vertices[newVid];
            float d = dot(v - center, normal);
            vertices[newVid] = v - normal * (2.0f * d);
        }

        // Re-derive edges from the (now larger) face list.
        rebuildEdges();

        // Subpatch + face-order arrays follow the new face count.
        resizeSubpatch();
        faceSelectionOrder.length = faces.length;
        resizeFaceSelection();
        faceMaterial.length       = faces.length;
        facePart.length           = faces.length;
        // Mark the new mirrored faces as the active selection; clear
        // the originals' face-selection bits (they keep their geometry
        // unchanged but lose the "this is selected" tag, matching
        // duplicateSelectedFaces semantics).
        foreach (fi; 0 .. origFaceCount) {
            deselectFace(cast(int)fi);
        }
        faceSelectionOrderCounter = 0;
        foreach (k, fi; toClone) {
            size_t newFi = origFaceCount + k;
            setFaceSubpatch(newFi, isFaceSubpatch(fi));
            faceMaterial[newFi] = (fi < faceMaterial.length ? faceMaterial[fi] : 0u);
            facePart[newFi]     = (fi < facePart.length     ? facePart[fi]     : 0u);
            selectFace(cast(int)newFi);
        }

        // Resize selection arrays (verts/edges) to current sizes; both
        // selections are invalidated by the topology changes.
        resizeVertexSelection();
        clearVertexSelection();
        resizeEdgeSelection();
        clearEdgeSelection();

        // Optional weld pass: verts on the mirror plane reflected to
        // themselves are coincident with their originals. weld>0 folds
        // them, then a face-fingerprint dedup pass drops any face whose
        // vertex SET matches another face's (winding-agnostic) — that's
        // what removes the doubled seam polygon (original's seam face +
        // its winding-reversed mirror copy) so the user doesn't get a
        // z-fighting partition wall after Mirror+Merge.
        if (weld > 0.0f) {
            // Empty-mesh guard (task 0306): snapshot everything this pass
            // can touch BEFORE running it, so an aggressive weld/dedup that
            // would collapse the WHOLE document can be rolled back to the
            // un-welded (but valid, non-empty) mirror result instead of
            // silently committing `status: ok` over an empty mesh. See
            // `isEmpty()`. Includes vertexSelectionOrder/edgeSelectionOrder
            // (SHOULD-FIX review of 0306): compactUnreferenced() and
            // clearEdgeSelectionResize() truncate those two parallel arrays
            // in lock-step with vertices/edges during the collapse, so
            // omitting them here would leave a length mismatch after
            // rollback (vertices.length == N but vertexSelectionOrder.length
            // == 0) — the very next selectVertex()/selectEdge() indexes them
            // unguarded and RangeErrors.
            Vec3[]    rbVertices = vertices.dup;
            uint[2][] rbEdges    = edges.dup;
            uint[][]  rbFaces;
            rbFaces.reserve(faces.length);
            foreach (f; faces) rbFaces ~= f.dup;
            uint[]    rbVertexMarks          = vertexMarks.dup;
            uint[]    rbEdgeMarks            = edgeMarks.dup;
            uint[]    rbFaceMarks            = faceMarks.dup;
            int[]     rbVertexSelectionOrder = vertexSelectionOrder.dup;
            int[]     rbEdgeSelectionOrder   = edgeSelectionOrder.dup;
            int[]     rbFaceSelectionOrder   = faceSelectionOrder.dup;
            uint[]    rbFaceMaterial         = faceMaterial.dup;
            uint[]    rbFacePart             = facePart.dup;
            MeshMap[] rbMeshMaps;
            rbMeshMaps.reserve(meshMaps.length);
            foreach (mm; meshMaps) rbMeshMaps ~= mm.dup;

            // Bug A fix: a masked face whose vertices ALL lie (near-)exactly
            // ON the mirror plane doesn't move under reflection — every one
            // of its verts maps to itself (dot(v-center,normal) ≈ 0), so its
            // "clone" is a winding-reversed exact duplicate at the SAME
            // location: a degenerate internal membrane, not new geometry.
            // Drop BOTH instances before the seam-fingerprint dedup below
            // runs — keeping either one leaves every one of its boundary
            // edges shared by 3 faces (itself + the two genuine side faces
            // that already close the seam on their own). This is distinct
            // from a face whose clone merely lands on a DIFFERENT face's
            // vertex set (e.g. mirroring a whole symmetric object about its
            // own center-plane, where e.g. left/right or top/bottom faces
            // legitimately fold onto ONE surviving copy) — that case is
            // still handled correctly by the ordinary fingerprint dedup
            // just below, unmodified.
            //
            // Tolerance: `min(weld, onPlaneEpsMax)`, NOT `weld` directly.
            // "Lies on the mirror plane" is a geometric-degeneracy test —
            // unrelated to how large a gap the user wants the SEAM-MERGE
            // pass (below) to fold. Using `weld` unclamped here misfires on
            // a large `weld` (task 0306 bug B's weld=100 repro): every
            // vertex of every face is trivially "within 100" of the plane,
            // so EVERY masked face would be wrongly flagged as on-plane and
            // dropped, before the seam weld even runs.
            enum float onPlaneEpsMax = 1e-5f;
            const float onPlaneEps = (weld < onPlaneEpsMax) ? weld : onPlaneEpsMax;
            bool[] dropFace;
            dropFace.length = faces.length;
            bool anyOnPlaneDropped = false;
            foreach (k, fi; toClone) {
                bool onPlane = true;
                foreach (vid; faces[fi]) {
                    float d = dot(vertices[vid] - center, normal);
                    if (d < 0.0f) d = -d;
                    if (d > onPlaneEps) { onPlane = false; break; }
                }
                if (onPlane) {
                    dropFace[fi]                 = true;
                    dropFace[origFaceCount + k]  = true;
                    anyOnPlaneDropped = true;
                }
            }
            if (anyOnPlaneDropped) {
                uint[][] keptFaces;
                bool[]   keptSubpatch;
                int[]    keptOrder;
                bool[]   keptSelected;
                uint[]   keptMaterial;
                uint[]   keptPart;
                keptFaces   .reserve(faces.length);
                keptSubpatch.reserve(faces.length);
                keptOrder   .reserve(faces.length);
                keptSelected.reserve(faces.length);
                keptMaterial.reserve(faces.length);
                keptPart    .reserve(faces.length);
                foreach (fi, ref f; faces) {
                    if (dropFace[fi]) continue;
                    keptFaces    ~= f;
                    keptSubpatch ~= isFaceSubpatch(fi);
                    keptOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
                    keptSelected ~= (fi < selectedFaces.length      ? selectedFaces[fi]      : false);
                    keptMaterial ~= (fi < faceMaterial.length       ? faceMaterial[fi]       : 0u);
                    keptPart     ~= (fi < facePart.length           ? facePart[fi]           : 0u);
                }
                faces              = keptFaces;
                setFaceSubpatchFrom(keptSubpatch);
                faceSelectionOrder = keptOrder;
                setFacesSelectedFrom(keptSelected);
                faceMaterial       = keptMaterial;
                facePart           = keptPart;

                // The dropped faces' own edges are otherwise left dangling
                // (still recorded in `edges`, no longer referenced by any
                // surviving face) whenever the weld pass below returns 0 —
                // e.g. `weld` too small to actually merge the seam verts,
                // or a caller reusing this on-plane-drop path in isolation.
                // Re-derive `edges` from the surviving `faces` right away so
                // the mesh is never left with phantom edges regardless of
                // what the (possibly skipped) weld dedup below does.
                // Deliberately NOT compactUnreferenced() here — that would
                // shift vertex indices and invalidate `origVertexCount` as
                // the `protectBelow` bound for the weld pass right below.
                rebuildEdges();
                clearEdgeSelectionResize();
            }

            double epsSq = cast(double)weld * cast(double)weld;
            // Bug B fix: `protectBelow=origVertexCount` keeps this weld
            // LOCAL to the seam — two PRE-EXISTING (pre-mirror) vertices
            // never merge with each other regardless of how large `weld`
            // is; only pairs touching at least one freshly-cloned vertex
            // are eligible. Without this, a large `weld` folds arbitrary
            // far-apart original vertices together across the whole mesh.
            if (weldCoincidentVertices(epsSq, origVertexCount) > 0) {
                // Drop faces with identical vert sets. Linear scan over
                // `faces`: cube-scale meshes don't justify a hash here.
                import std.algorithm.sorting : sort;
                import std.format : format;
                bool[string] seenFp;
                uint[][] keptFaces;
                bool[]   keptSubpatch;
                int[]    keptOrder;
                bool[]   keptSelected;
                uint[]   keptMaterial;
                uint[]   keptPart;
                keptFaces   .reserve(faces.length);
                keptSubpatch.reserve(faces.length);
                keptOrder   .reserve(faces.length);
                keptSelected.reserve(faces.length);
                keptMaterial.reserve(faces.length);
                keptPart    .reserve(faces.length);
                foreach (fi, ref f; faces) {
                    auto sorted = f.dup;
                    sort(sorted);
                    string fp = format("%(%d,%)", sorted);
                    if (fp in seenFp) continue;
                    seenFp[fp] = true;
                    keptFaces    ~= f;
                    keptSubpatch ~= isFaceSubpatch(fi);
                    keptOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
                    keptSelected ~= (fi < selectedFaces.length      ? selectedFaces[fi]      : false);
                    keptMaterial ~= (fi < faceMaterial.length       ? faceMaterial[fi]       : 0u);
                    keptPart     ~= (fi < facePart.length           ? facePart[fi]           : 0u);
                }
                faces              = keptFaces;
                setFaceSubpatchFrom(keptSubpatch);
                faceSelectionOrder = keptOrder;
                setFacesSelectedFrom(keptSelected);
                faceMaterial       = keptMaterial;
                facePart           = keptPart;

                // Edges may now reference verts that were welded but
                // are still recorded as endpoints; re-derive from the
                // surviving faces.
                rebuildEdges();
                clearEdgeSelectionResize();
                compactUnreferenced();
            }

            if (isEmpty()) {
                // The weld/dedup pass emptied the whole document — not a
                // legitimate "merge the seam" outcome, just a destructive
                // collapse driven by a threshold too large for this mesh's
                // scale. Roll back to the un-welded (but valid, non-empty)
                // mirror clone rather than commit an empty mesh.
                vertices             = rbVertices;
                edges                = rbEdges;
                faces                = rbFaces;
                vertexMarks          = rbVertexMarks;
                edgeMarks            = rbEdgeMarks;
                faceMarks            = rbFaceMarks;
                vertexSelectionOrder = rbVertexSelectionOrder;
                edgeSelectionOrder   = rbEdgeSelectionOrder;
                faceSelectionOrder   = rbFaceSelectionOrder;
                faceMaterial         = rbFaceMaterial;
                facePart             = rbFacePart;
                meshMaps             = rbMeshMaps;
            }
        }

        buildLoops();
        commitChange(MeshEditScope.Geometry);
        return toClone.length;
    }

    /// Mirror the faces marked true in `mask` across the plane defined by
    /// axis ∈ {'X','Y','Z'} passing through `center` — thin wrapper over
    /// `mirrorFacesPlane` kept for existing callers (commands/mesh/mirror.d,
    /// MirrorTool). Computes the unit-axis normal and delegates.
    ///
    /// TOLERANCE-identical (not bit-for-bit) to the pre-refactor axis-only
    /// implementation: the general formula `v - normal*(2*dot(v-center,
    /// normal))` with `normal=(1,0,0)` reduces to `v.x - 2*(v.x-center.x)` =
    /// `2*center.x - v.x` on the x component (y/z: dot term is 0, so they
    /// pass through EXACTLY) — algebraically identical to the prior
    /// `2.0f*center.x - v.x`, but computed via an extra subtract/multiply
    /// step that can differ by ~1 ULP for non-dyadic inputs. `weld`/`flip`/
    /// selection passes are untouched. Returns 0 for an invalid axis char
    /// (mirrors the prior guard).
    size_t mirrorFaces(in bool[] mask, char axis, Vec3 center, float weld, bool flipNormals) {
        Vec3 normal;
        if      (axis == 'X') normal = Vec3(1, 0, 0);
        else if (axis == 'Y') normal = Vec3(0, 1, 0);
        else if (axis == 'Z') normal = Vec3(0, 0, 1);
        else return 0;
        return mirrorFacesPlane(mask, center, normal, weld, flipNormals);
    }

    /// Duplicate the currently selected faces in place: every vertex used
    /// by a selected face is cloned (shared verts cloned once), each
    /// selected face is re-emitted referencing the cloned verts, edges
    /// are derived from the new faces. Selection is switched to the
    /// newly created faces (originals deselected). Edge and vertex
    /// selections are cleared.
    ///
    /// Primitive used by Tier-1 `mesh.duplicate` and the future
    /// Mirror / Array / Radial Array tools. Polygons-mode-only: vertex
    /// and edge selections produce no useful standalone topology in
    /// vibe3d's face-derived edge model, so the command should reject
    /// non-Polygons modes upstream.
    ///
    /// Returns the number of faces duplicated (0 = nothing selected).
    size_t duplicateSelectedFaces() {
        if (selectedFaces.length != faces.length) return 0;
        size_t selCount = 0;
        foreach (b; selectedFaces) if (b) ++selCount;
        if (selCount == 0) return 0;

        // Map old vert index → cloned vert index. Built lazily as we
        // iterate selected faces; shared verts between two selected
        // faces get cloned once.
        uint[uint] vertMap;
        foreach (fi, ref f; faces) {
            if (!selectedFaces[fi]) continue;
            foreach (vid; f) {
                if (vid !in vertMap) {
                    vertMap[vid] = cast(uint)vertices.length;
                    vertices ~= vertices[vid];
                }
            }
        }
        // Snapshot the indices of faces to duplicate before we start
        // appending — appending grows `faces` and would otherwise turn
        // the new faces into duplicates of themselves.
        size_t[] toClone;
        toClone.reserve(selCount);
        foreach (fi, ref f; faces)
            if (selectedFaces[fi]) toClone ~= fi;

        size_t origFaceCount = faces.length;
        foreach (fi; toClone) {
            auto src = faces[fi];
            uint[] cloned;
            cloned.length = src.length;
            foreach (k, vid; src) cloned[k] = vertMap[vid];
            faces ~= cloned;
        }

        // Re-derive edges from the (now larger) face list. Doing this
        // wholesale is simpler and faster than tracking which edges are
        // new — and stays consistent with the dedup'd-edge invariant
        // used by delete / dissolve.
        rebuildEdges();

        // Subpatch + face-order arrays follow the new face count.
        // New faces inherit subpatch flag from their source and start
        // with a fresh selection order (1-based) so they are picked up
        // as the active selection.
        resizeSubpatch();
        faceSelectionOrder.length = faces.length;
        resizeFaceSelection();
        faceMaterial.length       = faces.length;
        facePart.length           = faces.length;
        // Clear old face selection first; only new duplicates remain selected.
        foreach (fi; 0 .. origFaceCount) {
            deselectFace(cast(int)fi);
        }
        faceSelectionOrderCounter = 0;
        foreach (k, fi; toClone) {
            size_t newFi = origFaceCount + k;
            setFaceSubpatch(newFi, isFaceSubpatch(fi));
            faceMaterial[newFi] = (fi < faceMaterial.length ? faceMaterial[fi] : 0u);
            facePart[newFi]     = (fi < facePart.length     ? facePart[fi]     : 0u);
            selectFace(cast(int)newFi);
        }

        // Vertex / edge selections are invalidated by the edge rebuild
        // and the new verts respectively; clear them out.
        resizeVertexSelection();
        clearVertexSelection();
        resizeEdgeSelection();
        clearEdgeSelection();

        buildLoops();
        commitChange(MeshEditScope.Geometry);
        return toClone.length;
    }

    /// Append externally-provided geometry (clipboard paste) to this mesh.
    ///
    /// `clipVerts` are appended to `vertices`. Each face in `clipFaces`
    /// stores 0-based indices into `clipVerts`; they are remapped by
    /// `+vertexBase` (the pre-append vertex count) before being added to
    /// `faces`. `clipSubpatch`, `clipMaterial`, and `clipPart` are per-face
    /// parallel arrays sourced from the clipboard.
    ///
    /// After appending, selection switches to the new faces only: all
    /// pre-existing faces are deselected; each new face is selected in
    /// insertion order. Vertex and edge selections are cleared.
    ///
    /// Single `rebuildEdges()` + `buildLoops()` + `commitChange(Geometry)`
    /// at the end — no per-face hooks or addFace calls (which would each
    /// fire commitChange). Returns the number of faces appended; 0 = no-op.
    size_t appendGeometry(in Vec3[] clipVerts, in uint[][] clipFaces,
                          in bool[] clipSubpatch, in uint[] clipMaterial,
                          in uint[] clipPart = null) {
        if (clipFaces.length == 0) return 0;

        const size_t vertBase      = vertices.length;
        const size_t origFaceCount = faces.length;

        // Append clip verts verbatim.
        foreach (ref v; clipVerts) vertices ~= v;

        // Append remapped faces: each clip-local index shifts by vertBase.
        foreach (ref f; clipFaces) {
            uint[] remapped;
            remapped.length = f.length;
            foreach (k, vid; f) remapped[k] = cast(uint)(vid + vertBase);
            faces ~= remapped;
        }

        // Re-derive edges from the (now larger) face list.
        rebuildEdges();

        // Grow subpatch / selection-order / face-selection / material arrays
        // to the new face count. Mirroring duplicateSelectedFaces order.
        resizeSubpatch();
        faceSelectionOrder.length = faces.length;
        resizeFaceSelection();
        faceMaterial.length       = faces.length;
        facePart.length           = faces.length;

        // Deselect all pre-existing faces; only pasted faces end up selected.
        foreach (fi; 0 .. origFaceCount) deselectFace(cast(int)fi);
        faceSelectionOrderCounter = 0;

        // Assign clip metadata and select each new face.
        foreach (k; 0 .. clipFaces.length) {
            size_t newFi = origFaceCount + k;
            setFaceSubpatch(newFi, (k < clipSubpatch.length ? clipSubpatch[k] : false));
            faceMaterial[newFi] = (k < clipMaterial.length ? clipMaterial[k] : 0u);
            facePart[newFi]     = (k < clipPart.length     ? clipPart[k]     : 0u);
            selectFace(cast(int)newFi);
        }

        // Vertex/edge selections are invalidated by the edge rebuild and the
        // new verts; clear them out.
        resizeVertexSelection();
        clearVertexSelection();
        resizeEdgeSelection();
        clearEdgeSelection();

        buildLoops();
        commitChange(MeshEditScope.Geometry);
        return clipFaces.length;
    }

    /// Face Extrude: duplicate the selected polygon region as a lifted cap, bridge
    /// the region boundary with side quads, and offset the cap by `distance` along
    /// the averaged region normal. Region boundary = edges where exactly one
    /// incident face is selected (including mesh-boundary edges whose single
    /// incident face is selected). Internal edges shared by two selected faces
    /// produce no wall, so contiguous multi-face selections extrude as one region.
    ///
    /// Returns the number of faces extruded (0 = no-op: distance==0, nothing
    /// selected, mask length mismatch, or a closed island with no boundary edges).
    ///
    /// Winding of wall quads: each wall traverses the shared cap edge in the
    /// OPPOSITE direction to the cap face (orientability rule), determined from the
    /// original face traversal — the cap has the same winding as the original since
    /// we only substitute vertex indices. No region-normal dot backstop (a wall's
    /// normal is ⊥ to the region normal, so the dot ≈ 0 and would flip a
    /// correctly-wound quad).
    ///
    /// Closed-island pin: a selection with no boundary edges (e.g. all 6 faces of
    /// a closed cube) returns 0 BEFORE any geometry is emitted. This prevents a
    /// degenerate-normal silent translation when the whole mesh is selected.
    ///
    /// Multi-island selections: selected faces are grouped into connected
    /// components ("islands") via edge adjacency (two faces are in the same
    /// island only if they share a full EDGE, not merely a vertex). Each
    /// island gets its own inset/clone vertices, even at a corner shared with
    /// another island (e.g. a diagonal/checkerboard face pair touching at one
    /// vertex) — otherwise a single merged clone at that corner would have
    /// its cap-side vertical edge walled by both islands at once, producing
    /// an edge used by 4 faces (non-manifold; task 0312).
    ///
    /// Phase 5 (delta-path undo) is deferred: the drop+compact step makes the
    /// append-only recordAddFaces revert insufficient, so only snapshot undo
    /// (MeshFaceExtrudeEdit) is wired for Phases 1-4.
    ///
    /// Non-manifold-region reject (fuzz-found): if the selected region touches
    /// a "book" edge (an undirected edge already shared by more than 2 faces
    /// total), the whole call is a clean no-op (returns 0) rather than risk
    /// winding/coincident corruption from extruding into an already-invalid
    /// neighborhood.
    size_t extrudeFacesByMask(in bool[] mask, float distance, bool smooth = false) {
        if (mask.length != faces.length) return 0;
        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0) return 0;
        if (distance == 0.0f) return 0;

        // Non-manifold-region reject (fuzz-found): reject the whole operation
        // if any edge of a SELECTED face is already shared by more than 2
        // faces total (a "book" edge — e.g. 3+ pages hinged on one edge).
        // Counts incidences directly with an edgeKeyOrdered map over ALL
        // faces — NOT via buildEdgeFaces(), whose int[2] slot can't witness a
        // 3rd/4th incident face (see its own comment below) — mirroring the
        // 0312 unittest's edgeUseCount idiom. Matches the 0316 saturated-edge
        // reject idiom. "Operate-per-2-manifold-island" was considered and
        // rejected: the island BFS below itself rides buildEdgeFaces, which is
        // blind to the same extra faces, so it can't reliably partition a
        // book edge either — reject is the minimal, house-consistent choice.
        {
            size_t[ulong] edgeUseCountAll;
            foreach (fi; 0 .. faces.length) {
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    ulong key = edgeKeyOrdered(f[k], f[(k + 1) % f.length]);
                    auto p = key in edgeUseCountAll;
                    if (p is null) edgeUseCountAll[key] = 1;
                    else           ++(*p);
                }
            }
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    ulong key = edgeKeyOrdered(f[k], f[(k + 1) % f.length]);
                    if (edgeUseCountAll[key] > 2) return 0;
                }
            }
        }

        // Region normal: normalized average of selected face normals.
        Vec3 normSum = Vec3(0, 0, 0);
        foreach (fi; 0 .. faces.length)
            if (mask[fi]) normSum = normSum + faceNormal(cast(uint)fi);
        {
            float rlen = sqrt(normSum.x * normSum.x +
                              normSum.y * normSum.y +
                              normSum.z * normSum.z);
            normSum = (rlen > 1e-6f) ? normSum * (1.0f / rlen) : Vec3(0, 1, 0);
        }
        immutable Vec3 regionNormal = normSum;

        // Edge → (≤2 incident faces) adjacency, one pass.
        auto edgeFaces = buildEdgeFaces();

        // Connected-component ("island") id per selected face, via adjacency
        // through a FULLY shared edge (both incident faces selected). Two
        // selected faces that only touch at a single vertex (no shared edge
        // — e.g. a diagonal/checkerboard pair) are DIFFERENT islands: each
        // must get its own inset vertex at that shared corner. Without this,
        // a single merged clone at the corner would have its cap-side
        // vertical edge walled by BOTH islands at once — an edge used by 4
        // faces (non-manifold). Fuzz-found: task 0312.
        int[size_t] islandOf;
        {
            size_t[][size_t] adj;
            foreach (key, fp; edgeFaces) {
                if (fp[0] < 0 || fp[1] < 0) continue;
                if (fp[0] >= cast(int)mask.length || fp[1] >= cast(int)mask.length) continue;
                if (!mask[fp[0]] || !mask[fp[1]]) continue;
                adj[cast(size_t)fp[0]] ~= cast(size_t)fp[1];
                adj[cast(size_t)fp[1]] ~= cast(size_t)fp[0];
            }
            int nextIsland = 0;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                if (fi in islandOf) continue;
                size_t[] stack = [fi];
                islandOf[fi] = nextIsland;
                while (stack.length) {
                    size_t cur = stack[$ - 1];
                    stack = stack[0 .. $ - 1];
                    if (auto nbrs = cur in adj)
                        foreach (nb; *nbrs)
                            if (nb !in islandOf) {
                                islandOf[nb] = nextIsland;
                                stack ~= nb;
                            }
                }
                ++nextIsland;
            }
        }
        // Combined (island, vertex) key: an inset/clone vertex is scoped to
        // one island, so the same original vertex shared by two islands
        // (touching only at that corner) gets one clone PER island instead
        // of one merged clone.
        static ulong ivKey(int island, uint vid) {
            return (cast(ulong)cast(uint)island << 32) | vid;
        }

        // Per-(island,vertex) offset table — FULLY built BEFORE the dedup
        // clone loop. The clone loop visits each (island,vid) only once (on
        // first sight), so any accumulation inside it would drop every
        // face's contribution after the first for shared/ridge verts. We
        // pre-build here to guarantee the complete sum.
        //
        // Smooth (smooth=true): accumulate the unit normals of the selected
        // incident faces IN THE SAME ISLAND for each (island,vid), then
        // normalize. Fallback chain:
        //   avg-normal degenerate → regionNormal → Vec3(0,1,0).
        // vibe3d-divergence: UNIFORM weighting (each face's unit normal
        // contributes equally).  Area- or angle-weighted averaging would be a
        // one-line change to the accumulation; deferred as a documented
        // divergence — the geometry-reference harness is absent from this
        // checkout so empirical capture is infeasible.
        //
        // Rigid (smooth=false, default): every (island,vid) gets
        // regionNormal*distance, byte-identical to the pre-refactor
        // per-vertex behaviour (regionNormal is one global value shared by
        // every island — only the CLONE identity is separated per island,
        // not the offset direction).
        Vec3[ulong] vertOffset;
        if (smooth) {
            Vec3[ulong] vNormSum;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                Vec3 fn = faceNormal(cast(uint)fi);
                int island = islandOf[fi];
                foreach (vid; faces[fi]) {
                    ulong k = ivKey(island, vid);
                    auto p = k in vNormSum;
                    if (p is null) vNormSum[k] = fn;
                    else          *p = *p + fn;
                }
            }
            foreach (k, nsum; vNormSum) {
                float nlen = sqrt(nsum.x*nsum.x + nsum.y*nsum.y + nsum.z*nsum.z);
                Vec3 dir = (nlen > 1e-6f) ? nsum * (1.0f / nlen) : regionNormal;
                vertOffset[k] = dir * distance;
            }
        } else {
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                int island = islandOf[fi];
                foreach (vid; faces[fi]) {
                    ulong k = ivKey(island, vid);
                    if (k !in vertOffset)
                        vertOffset[k] = regionNormal * distance;
                }
            }
        }

        // Boundary edges: exactly one incident face is selected.
        struct BEdge { uint va, vb; int selFi; }
        BEdge[] bEdges;
        foreach (key, fp; edgeFaces) {
            bool s0 = fp[0] >= 0 && fp[0] < cast(int)mask.length && mask[fp[0]];
            bool s1 = fp[1] >= 0 && fp[1] < cast(int)mask.length && mask[fp[1]];
            if (s0 == s1) continue;   // both selected (internal) or neither
            uint va = cast(uint)(key >> 32);
            uint vb = cast(uint)(key & 0xffffffffUL);
            bEdges ~= BEdge(va, vb, s0 ? fp[0] : fp[1]);
        }

        // Empty-boundary pin: closed island → clean no-op BEFORE any geometry.
        // Without this, the degenerate-normal fallback (+Y) would silently
        // translate the whole mesh.
        if (bEdges.length == 0) return 0;

        // Clone each (island,vertex) used by a selected face (once per
        // island,vertex pair — see the ivKey comment above for why a corner
        // shared between two islands needs two separate clones). Offset
        // comes from the pre-built vertOffset table, not computed here.
        uint[ulong] vertMap;
        foreach (fi; 0 .. faces.length) {
            if (!mask[fi]) continue;
            int island = islandOf[fi];
            foreach (vid; faces[fi]) {
                ulong k = ivKey(island, vid);
                if (k !in vertMap)
                    vertMap[k] = addVertex(vertices[vid] + vertOffset[k]);
            }
        }

        // Snapshot which face indices to clone before growing the array.
        size_t[] toCloneFace;
        foreach (fi; 0 .. faces.length) if (mask[fi]) toCloneFace ~= fi;

        // Reconstruct faces + parallel arrays (deleteFacesByMask rebuild idiom).
        // Order: [non-selected originals] + [cap clones] + [wall quads].
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        bool[]   newSub;

        // Non-selected originals, kept as-is.
        foreach (fi; 0 .. faces.length) {
            if (mask[fi]) continue;
            newFaces ~= faces[fi];
            newMat   ~= fi < faceMaterial.length       ? faceMaterial[fi]       : 0u;
            newPart  ~= fi < facePart.length           ? facePart[fi]           : 0u;
            newOrd   ~= fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0;
            newSub   ~= isFaceSubpatch(fi);
        }
        immutable size_t capStart = newFaces.length;   // first cap index in newFaces

        // Cap clones: re-emit each selected face with cloned (offset) verts.
        foreach (fi; toCloneFace) {
            auto src = faces[fi];
            uint[] cloned;
            cloned.length = src.length;
            int island = islandOf[fi];
            foreach (k, vid; src) cloned[k] = vertMap[ivKey(island, vid)];
            newFaces ~= cloned;
            newMat   ~= fi < faceMaterial.length ? faceMaterial[fi] : 0u;
            newPart  ~= fi < facePart.length     ? facePart[fi]     : 0u;
            newOrd   ~= 0;
            newSub   ~= isFaceSubpatch(fi);
        }

        // Wall quads: one per boundary edge, oriented by the orientability rule.
        // The cap face traverses (cloneA, cloneB) in the SAME direction as the
        // original selected face traverses (a, b), since we only substituted indices.
        // The wall must share the cap's top edge in the OPPOSITE direction.
        foreach (ref be; bEdges) {
            uint a = be.va, b = be.vb;
            int island = islandOf[be.selFi];
            uint cloneA = vertMap[ivKey(island, a)], cloneB = vertMap[ivKey(island, b)];
            // Determine direction (a → b) in the original selected face.
            bool origAtoB = false;
            auto orig = faces[be.selFi];
            foreach (k; 0 .. orig.length) {
                uint u = orig[k], w = orig[(k + 1) % orig.length];
                if (u == a && w == b) { origAtoB = true;  break; }
                if (u == b && w == a) { origAtoB = false; break; }
            }
            // Cap walks cloneA→cloneB iff orig walks a→b.
            // Wall traverses the shared top edge in the opposite direction.
            if (origAtoB) newFaces ~= [cloneB, cloneA, a, b];
            else          newFaces ~= [cloneA, cloneB, b, a];
            newMat  ~= be.selFi < faceMaterial.length ? faceMaterial[be.selFi] : 0u;
            newPart ~= be.selFi < facePart.length     ? facePart[be.selFi]     : 0u;
            newOrd  ~= 0;
            // Task 0389: side wall inherits Subpatch from the extruded source
            // face it skirts, same as its material/part above.
            newSub  ~= isFaceSubpatch(be.selFi);
        }

        // Assign reconstructed arrays.
        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;
        // Rebuild faceMarks from scratch: resize+zero ALL bits (clears both
        // Select and stale Subpatch from the old ordering), then set Subpatch.
        faceMarks.length = faces.length;
        faceMarks[]      = 0;
        foreach (fi, s; newSub)
            if (s) faceMarks[fi] |= Marks.Subpatch;

        // New selection = cap faces (so a follow-up op chains off the top).
        faceSelectionOrderCounter = 0;
        foreach (fi; capStart .. capStart + selCount)
            selectFace(cast(int)fi);

        // Clear vertex + edge selections.
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        // Tail: rebuild topology, drop orphaned original interior verts.
        rebuildEdges();
        buildLoops();
        compactUnreferenced();   // removes original selected-face verts not kept by walls
        buildLoops();

        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return selCount;
    }

    unittest {
        import std.math : abs;

        // Single-face extrude: cube face 0, distance 0.5.
        // Cube: 6 faces, 8 verts. After extruding one quad face:
        // 5 orig + 1 cap + 4 walls = 10 faces; 8 orig + 4 clones = 12 verts.
        {
            auto m = makeCube();
            bool[] mask; mask.length = m.faces.length; mask[] = false; mask[0] = true;
            Vec3 origC = m.faceCentroid(0);
            Vec3 origN = m.faceNormal(0);
            size_t n = m.extrudeFacesByMask(mask, 0.5f);
            assert(n > 0,
                "extrudeFacesByMask: returned 0 on valid single-face selection");
            assert(m.faces.length == 10,
                "extrudeFacesByMask: expected 10 faces after single-face extrude");
            assert(m.vertices.length == 12,
                "extrudeFacesByMask: expected 12 verts after single-face extrude");
            // Cap face is selected after the op; find it.
            int capFi = -1;
            foreach (fi; 0 .. m.faces.length)
                if (m.isFaceSelected(fi)) { capFi = cast(int)fi; break; }
            assert(capFi >= 0, "extrudeFacesByMask: no cap face selected after op");
            Vec3 capC = m.faceCentroid(cast(uint)capFi);
            Vec3 exp  = origC + origN * 0.5f;
            assert(abs(capC.x - exp.x) < 1e-4f &&
                   abs(capC.y - exp.y) < 1e-4f &&
                   abs(capC.z - exp.z) < 1e-4f,
                "extrudeFacesByMask: cap centroid not offset by 0.5 along face normal");
        }

        // distance == 0 → no-op (topology and vert count unchanged).
        {
            auto m = makeCube();
            bool[] mask; mask.length = m.faces.length; mask[] = false; mask[0] = true;
            size_t n = m.extrudeFacesByMask(mask, 0.0f);
            assert(n == 0,
                "extrudeFacesByMask: distance==0 must return 0");
            assert(m.faces.length == 6,
                "extrudeFacesByMask: distance==0 changed face count");
            assert(m.vertices.length == 8,
                "extrudeFacesByMask: distance==0 changed vert count");
        }

        // Closed island (all 6 cube faces) → no boundary edges → no-op.
        {
            auto m = makeCube();
            bool[] mask; mask.length = m.faces.length; mask[] = true;
            size_t n = m.extrudeFacesByMask(mask, 0.5f);
            assert(n == 0,
                "extrudeFacesByMask: closed island must return 0");
            assert(m.faces.length == 6,
                "extrudeFacesByMask: closed island changed face count");
            assert(m.vertices.length == 8,
                "extrudeFacesByMask: closed island changed vert count");
        }

        // ── Smooth-shift discriminator: symmetric two-quad tent ──────────────
        // Geometry:
        //   v0=(-1,0,0)  v1=(-1,0,1)   — outer left
        //   v2=( 0,1,0)  v3=( 0,1,1)   — ridge (shared by both faces)
        //   v4=( 1,0,0)  v5=( 1,0,1)   — outer right
        //   face 0: [0,1,3,2]   face 1: [2,3,5,4]
        //
        // Face normals (Newell):
        //   n0 = (-1/√2,  1/√2, 0)
        //   n1 = ( 1/√2,  1/√2, 0)
        //   regionNormal = (0, 1, 0)          (normalized n0+n1)
        //   smooth-ridge avg = normalize(n0+n1) = (0, 1, 0)  ← same as rigid
        //   smooth-outer-left  = n0            ← differs from rigid
        //   smooth-outer-right = n1            ← differs from rigid
        //
        // The RIDGE assertion is the ordering-bug discriminator: if the
        // vertOffset were accumulated inside the clone loop, the ridge vert
        // would be offset by only the FIRST face's normal (n0 or n1),
        // placing it at (~±0.354, ~1.354, *) instead of (0, 1.5, *).

        // Test A: smooth=true — verify ridge AND outer-vert positions.
        {
            import std.math : abs, sqrt;
            Mesh m;
            m.vertices = [
                Vec3(-1, 0, 0), Vec3(-1, 0, 1),   // 0,1 outer-left
                Vec3( 0, 1, 0), Vec3( 0, 1, 1),   // 2,3 ridge
                Vec3( 1, 0, 0), Vec3( 1, 0, 1),   // 4,5 outer-right
            ];
            m.addFace([0u, 1u, 3u, 2u]);  // left face
            m.addFace([2u, 3u, 5u, 4u]);  // right face
            m.buildLoops();

            bool[] mask; mask.length = 2; mask[] = true;
            size_t n = m.extrudeFacesByMask(mask, 0.5f, true);
            assert(n > 0, "smooth tent: returned 0");

            // Ridge cap verts: v2=(0,1,0) and v3=(0,1,1) offset by (0,1,0)*0.5
            //   → clone at (0, 1.5, 0) and (0, 1.5, 1).
            // If ordering-bug present: ridge offset by n0 only → (≈-0.354, ≈1.354, *)
            bool ridgeFront = false, ridgeBack = false;
            // Outer-left cap: v0=(-1,0,0) offset by n0*0.5 → x ≈ -1-0.5/√2 ≈ -1.354
            bool outerLeft = false;
            // Outer-right cap: v4=(1,0,0) offset by n1*0.5 → x ≈ 1+0.5/√2 ≈ 1.354
            bool outerRight = false;
            immutable float halfOverSqrt2 = 0.5f / sqrt(2.0f);
            foreach (v; m.vertices) {
                // Ridge front clone
                if (abs(v.x) < 1e-4f && abs(v.y - 1.5f) < 1e-4f &&
                    abs(v.z) < 1e-4f)
                    ridgeFront = true;
                // Ridge back clone
                if (abs(v.x) < 1e-4f && abs(v.y - 1.5f) < 1e-4f &&
                    abs(v.z - 1.0f) < 1e-4f)
                    ridgeBack = true;
                // Outer-left clone (x < -1, y ≈ halfOverSqrt2)
                if (abs(v.x - (-1.0f - halfOverSqrt2)) < 1e-4f &&
                    abs(v.y - halfOverSqrt2) < 1e-4f)
                    outerLeft = true;
                // Outer-right clone (x > 1, y ≈ halfOverSqrt2)
                if (abs(v.x - (1.0f + halfOverSqrt2)) < 1e-4f &&
                    abs(v.y - halfOverSqrt2) < 1e-4f)
                    outerRight = true;
            }
            assert(ridgeFront,
                "smooth tent: ridge front clone not at (0,1.5,0) — " ~
                "ordering bug? (in-loop accum offsets ridge by first-face normal only)");
            assert(ridgeBack,
                "smooth tent: ridge back clone not at (0,1.5,1)");
            assert(outerLeft,
                "smooth tent: outer-left clone not offset along face-0 normal");
            assert(outerRight,
                "smooth tent: outer-right clone not offset along face-1 normal");
        }

        // Test B: smooth=true on a single flat face == smooth=false (rigid).
        // With one selected face, faceNormal IS the regionNormal, so every
        // cap vertex gets the same offset regardless of mode.
        {
            import std.math : abs;
            auto m = makeCube();
            bool[] mask; mask.length = m.faces.length; mask[] = false;
            mask[0] = true;
            Vec3 origC = m.faceCentroid(0);
            Vec3 origN = m.faceNormal(0);
            size_t n = m.extrudeFacesByMask(mask, 0.5f, true);
            assert(n > 0, "smooth flat single-face: returned 0");
            // Find cap face (selected after the op).
            int capFi = -1;
            foreach (fi; 0 .. m.faces.length)
                if (m.isFaceSelected(fi)) { capFi = cast(int)fi; break; }
            assert(capFi >= 0, "smooth flat single-face: no cap selected");
            Vec3 capC = m.faceCentroid(cast(uint)capFi);
            Vec3 exp  = origC + origN * 0.5f;
            assert(abs(capC.x - exp.x) < 1e-4f &&
                   abs(capC.y - exp.y) < 1e-4f &&
                   abs(capC.z - exp.z) < 1e-4f,
                "smooth flat single-face: cap centroid differs from rigid extrude");
        }
    }

    // Task 0312 (fuzz-found): a diagonal/checkerboard face pair that shares
    // only a single vertex (no shared edge) must extrude as TWO independent
    // islands, each with its own inset vertex at the shared corner. Before
    // the fix, a single merged clone at that corner had its cap-side
    // vertical edge walled by both islands at once — an edge used by 4
    // faces. Assert the post-extrude mesh is edge-manifold (every undirected
    // edge used by ≤2 faces), matching the HTTP repro:
    //   /api/reset?type=grid&n=2; select polygons [1,2]; poly.extrude 1.0
    unittest {
        import std.conv : to;

        auto m = makeGridPlane(2);
        // 2x2 grid: faces 1 and 2 (row0/col1 and row1/col0) touch only at
        // the shared center vertex — the diagonal/checkerboard pair.
        bool[] mask; mask.length = m.faces.length; mask[] = false;
        mask[1] = true;
        mask[2] = true;
        size_t n = m.extrudeFacesByMask(mask, 1.0f);
        assert(n == 2, "diagonal pair: expected 2 faces extruded");

        // Recount every undirected edge across ALL faces directly (NOT via
        // buildEdgeFaces — its 2-slot [int;2] silently drops a 3rd/4th
        // incident face instead of flagging it, so it can't witness this
        // bug). A count > 2 anywhere means a non-manifold edge.
        size_t[ulong] edgeUseCount;
        foreach (fi; 0 .. m.faces.length) {
            auto f = m.faces[fi];
            foreach (k; 0 .. f.length) {
                ulong key = edgeKeyOrdered(f[k], f[(k + 1) % f.length]);
                auto p = key in edgeUseCount;
                if (p is null) edgeUseCount[key] = 1;
                else           ++(*p);
            }
        }
        foreach (key, count; edgeUseCount)
            assert(count <= 2,
                "diagonal pair extrude: non-manifold edge used by " ~
                count.to!string ~ " faces (task 0312 regression)");
    }

    // Mesh-robustness batch (fuzz-found): a "book" edge — one undirected edge
    // shared by 3 faces (non-manifold input) — must reject the whole extrude
    // as a clean no-op, not attempt to extrude into the already-invalid
    // neighborhood. A normal disjoint 2-face pair (no book edge) must still
    // extrude as before (no over-reject).
    unittest {
        import std.conv : to;
        // Book mesh: 3 quad "pages" all hinged on the shared edge (v0,v1).
        //   page A: v0,v1,v2,v3   (in the XY... here XZ-ish plane, x>0)
        //   page B: v0,v1,v4,v5   (rotated: z>0)
        //   page C: v0,v1,v6,v7   (rotated: x<0)
        // Undirected edge (0,1) is used by all 3 pages => incidence count 3.
        Mesh m;
        uint v0 = m.addVertex(Vec3(0, 0, 0));
        uint v1 = m.addVertex(Vec3(0, 1, 0));
        uint v2 = m.addVertex(Vec3(1, 1, 0));
        uint v3 = m.addVertex(Vec3(1, 0, 0));
        uint v4 = m.addVertex(Vec3(0, 1, 1));
        uint v5 = m.addVertex(Vec3(0, 0, 1));
        uint v6 = m.addVertex(Vec3(-1, 1, 0));
        uint v7 = m.addVertex(Vec3(-1, 0, 0));
        m.addFace([v0, v1, v2, v3]);
        m.addFace([v0, v1, v4, v5]);
        m.addFace([v0, v1, v6, v7]);

        size_t vertsBefore = m.vertices.length;
        size_t facesBefore = m.faces.length;
        bool[] mask; mask.length = m.faces.length; mask[] = false;
        mask[0] = true; // select page A, which touches the book edge (0,1)
        size_t n = m.extrudeFacesByMask(mask, 1.0f);
        assert(n == 0, "book-edge extrude: expected reject (0), got " ~ n.to!string);
        assert(m.vertices.length == vertsBefore,
            "book-edge extrude: reject must not add verts");
        assert(m.faces.length == facesBefore,
            "book-edge extrude: reject must not add faces");

        // A normal disjoint 2-face pair (not touching the book edge) must
        // still extrude normally — the guard must not over-reject.
        Mesh gm = makeGridPlane(2);
        bool[] gmask; gmask.length = gm.faces.length; gmask[] = false;
        gmask[0] = true; gmask[1] = true; // adjacent quads, shared edge used by only 2 faces
        size_t gn = gm.extrudeFacesByMask(gmask, 1.0f);
        assert(gn == 2, "disjoint pair extrude: expected 2 faces extruded, got " ~ gn.to!string);
    }

    private static ulong edgeKeyOrdered(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32) | b : (cast(ulong)b << 32) | a;
    }

    // -------------------------------------------------------------------
    // Smooth Shift + Thicken kernel (task 0358). A deliberately SEPARATE
    // function from extrudeFacesByMask — it is NOT a drop-in replacement
    // and does not share its call sites (face_extrude.d, poly_extrude.d,
    // smooth_shift.d's existing one-shot command all keep calling
    // extrudeFacesByMask, untouched). Backs the interactive Smooth Shift
    // tool (tools.deform.smooth_shift_tool.SmoothShiftTool).
    //
    // Per-(island,vertex) cap law, fitted to the frozen reference fixture
    // (see tests/fixtures/smooth_shift.json):
    //     capPos = islandCentroid + scale * ((origPos + shift*smoothN) - islandCentroid)
    // i.e. a standard per-vertex-smoothed-normal shift-extrude (the same
    // "smooth=true" normal-averaging extrudeFacesByMask already does),
    // followed by scaling the resulting cap footprint about the ISLAND'S
    // ORIGINAL (pre-offset) cloned-vertex centroid. scale==1 collapses to
    // a plain shift-extrude (matches the captured shift03 combo); the
    // shift03_scale05 combo (shift=0.3, scale=0.5) pins this exact law —
    // e.g. corner (-0.5,0.5,-0.5) → (-0.25, 0.65, -0.25), not (…, 0.8, …).
    //
    // UNLIKE extrudeFacesByMask, shift==0 is NOT special-cased as a no-op:
    // the reference always builds the full (possibly-degenerate,
    // coincident-vertex) extrude topology at shift=0 — confirmed live
    // (combo "base_noop": a plain cube's top face still comes out 12v/10f).
    // The caller (the interactive tool) decides whether a fully-identity
    // gesture (nothing dragged) is worth an undo entry — see
    // SmoothShiftTool's session lifecycle.
    //
    // `thicken`: when true, each cloned face's ORIGINAL vertices are
    // additionally re-emitted, winding-REVERSED, as an extra "retained"
    // polygon — a selection-scoped, symmetric double-walled protrusion
    // (confirmed live: combo "thicken_top_only", 11 faces vs. 10 for the
    // non-thicken case, the 11th being the original 4 verts unmoved; the
    // winding reversal itself is independently derivable from the
    // captured index order via the right-hand-rule face normal, not just
    // taken from the reference help text). Deliberately distinct from
    // Mesh.thickenSurface, which shells the WHOLE mesh unconditionally —
    // a different, valid, unrelated feature (task 0358 finding).
    //
    // `maxAngle` (crease-gated normal splitting) and `sharp` (crease-corner
    // rounding) are NOT parameters of this kernel and are NOT implemented —
    // the same simplification smooth_shift.d's own doc comment already
    // flags for the one-shot command (uniform, unweighted per-vertex normal
    // averaging, no angle-gated splitting). SmoothShiftTool still stores/
    // exposes both as panel attrs (for field-order parity with the
    // reference panel), but their values do not affect geometry yet.
    //
    // Polygons-mode only (checked by the caller); empty selection ⇒ whole
    // mesh (per the caller's mask convention, matching extrudeFacesByMask).
    // Returns the number of faces cloned (0 on any no-op condition:
    // mismatched mask, nothing selected, or a closed island with no
    // boundary edges to wall).
    size_t smoothShiftFacesByMask(in bool[] mask, float shift, float scale, bool thicken) {
        if (mask.length != faces.length) return 0;
        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0) return 0;

        // Region-normal fallback for a degenerate (near-zero-length)
        // per-vertex smoothed normal — same rule as extrudeFacesByMask.
        Vec3 normSum = Vec3(0, 0, 0);
        foreach (fi; 0 .. faces.length)
            if (mask[fi]) normSum = normSum + faceNormal(cast(uint)fi);
        {
            float rlen = sqrt(normSum.x * normSum.x +
                              normSum.y * normSum.y +
                              normSum.z * normSum.z);
            normSum = (rlen > 1e-6f) ? normSum * (1.0f / rlen) : Vec3(0, 1, 0);
        }
        immutable Vec3 regionNormal = normSum;

        auto edgeFaces = buildEdgeFaces();

        // Island id per selected face — adjacency via a FULLY shared edge
        // (both incident faces selected). Mirrors extrudeFacesByMask's
        // task-0312 fix: two selected faces touching only at a vertex are
        // different islands, each getting its own clone at that corner.
        int[size_t] islandOf;
        {
            size_t[][size_t] adj;
            foreach (key, fp; edgeFaces) {
                if (fp[0] < 0 || fp[1] < 0) continue;
                if (fp[0] >= cast(int)mask.length || fp[1] >= cast(int)mask.length) continue;
                if (!mask[fp[0]] || !mask[fp[1]]) continue;
                adj[cast(size_t)fp[0]] ~= cast(size_t)fp[1];
                adj[cast(size_t)fp[1]] ~= cast(size_t)fp[0];
            }
            int nextIsland = 0;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                if (fi in islandOf) continue;
                size_t[] stack = [fi];
                islandOf[fi] = nextIsland;
                while (stack.length) {
                    size_t cur = stack[$ - 1];
                    stack = stack[0 .. $ - 1];
                    if (auto nbrs = cur in adj)
                        foreach (nb; *nbrs)
                            if (nb !in islandOf) {
                                islandOf[nb] = nextIsland;
                                stack ~= nb;
                            }
                }
                ++nextIsland;
            }
        }
        static ulong ivKey(int island, uint vid) {
            return (cast(ulong)cast(uint)island << 32) | vid;
        }

        // Per-(island,vertex) smoothed normal: uniform average of incident
        // selected-face normals within the island; degenerate → regionNormal.
        Vec3[ulong] vNorm;
        {
            Vec3[ulong] vNormSum;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                Vec3 fn = faceNormal(cast(uint)fi);
                int island = islandOf[fi];
                foreach (vid; faces[fi]) {
                    ulong k = ivKey(island, vid);
                    auto p = k in vNormSum;
                    if (p is null) vNormSum[k] = fn;
                    else          *p = *p + fn;
                }
            }
            foreach (k, nsum; vNormSum) {
                float nlen = sqrt(nsum.x*nsum.x + nsum.y*nsum.y + nsum.z*nsum.z);
                vNorm[k] = (nlen > 1e-6f) ? nsum * (1.0f / nlen) : regionNormal;
            }
        }

        // Per-island centroid of the ORIGINAL (pre-offset) cloned-vertex
        // positions — the scale pivot. Each (island,vertex) counts ONCE
        // (a shared ridge vertex must not be over-weighted by its incident
        // selected-face count).
        Vec3[int] islandCentroid;
        {
            Vec3[int] sum;
            int[int]  cnt;
            bool[ulong] seen;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                int island = islandOf[fi];
                foreach (vid; faces[fi]) {
                    ulong k = ivKey(island, vid);
                    if (k in seen) continue;
                    seen[k] = true;
                    auto p = island in sum;
                    if (p is null) { sum[island] = vertices[vid]; cnt[island] = 1; }
                    else           { *p = *p + vertices[vid]; cnt[island] = cnt[island] + 1; }
                }
            }
            foreach (isl, s; sum)
                islandCentroid[isl] = s * (1.0f / cast(float)cnt[isl]);
        }

        // Boundary edges: exactly one incident face is selected.
        struct BEdge { uint va, vb; int selFi; }
        BEdge[] bEdges;
        foreach (key, fp; edgeFaces) {
            bool s0 = fp[0] >= 0 && fp[0] < cast(int)mask.length && mask[fp[0]];
            bool s1 = fp[1] >= 0 && fp[1] < cast(int)mask.length && mask[fp[1]];
            if (s0 == s1) continue;   // both selected (internal) or neither
            uint va = cast(uint)(key >> 32);
            uint vb = cast(uint)(key & 0xffffffffUL);
            bEdges ~= BEdge(va, vb, s0 ? fp[0] : fp[1]);
        }
        if (bEdges.length == 0) return 0;   // closed island → nothing to wall

        // Clone each (island,vertex) used by a selected face, once per
        // (island,vertex) pair, at the scaled cap position.
        uint[ulong] vertMap;
        foreach (fi; 0 .. faces.length) {
            if (!mask[fi]) continue;
            int island = islandOf[fi];
            Vec3 cen = islandCentroid[island];
            foreach (vid; faces[fi]) {
                ulong k = ivKey(island, vid);
                if (k in vertMap) continue;
                Vec3 orig    = vertices[vid];
                Vec3 shifted = orig + vNorm[k] * shift;
                Vec3 capPos  = cen + (shifted - cen) * scale;
                vertMap[k] = addVertex(capPos);
            }
        }

        size_t[] toCloneFace;
        foreach (fi; 0 .. faces.length) if (mask[fi]) toCloneFace ~= fi;

        // Reconstruct faces + parallel arrays (deleteFacesByMask rebuild
        // idiom). Order: [non-selected originals] + [cap clones] +
        // [thicken-retained originals, if any] + [wall quads].
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        bool[]   newSub;

        foreach (fi; 0 .. faces.length) {
            if (mask[fi]) continue;
            newFaces ~= faces[fi];
            newMat   ~= fi < faceMaterial.length       ? faceMaterial[fi]       : 0u;
            newPart  ~= fi < facePart.length           ? facePart[fi]           : 0u;
            newOrd   ~= fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0;
            newSub   ~= isFaceSubpatch(fi);
        }
        immutable size_t capStart = newFaces.length;

        // Cap clones: re-emit each selected face with cloned (offset+scaled)
        // verts, same per-corner order as the original (index substitution
        // only), same convention extrudeFacesByMask uses.
        foreach (fi; toCloneFace) {
            auto src = faces[fi];
            uint[] cloned;
            cloned.length = src.length;
            int island = islandOf[fi];
            foreach (k, vid; src) cloned[k] = vertMap[ivKey(island, vid)];
            newFaces ~= cloned;
            newMat   ~= fi < faceMaterial.length ? faceMaterial[fi] : 0u;
            newPart  ~= fi < facePart.length     ? facePart[fi]     : 0u;
            newOrd   ~= 0;
            newSub   ~= isFaceSubpatch(fi);
        }

        // Thicken: retain the ORIGINAL (unmoved) face verts, winding
        // REVERSED, as an extra inner-skin polygon per cloned face.
        if (thicken) {
            foreach (fi; toCloneFace) {
                auto src = faces[fi];
                uint[] reversed;
                reversed.length = src.length;
                foreach (k, vid; src) reversed[$ - 1 - k] = vid;
                newFaces ~= reversed;
                newMat   ~= fi < faceMaterial.length ? faceMaterial[fi] : 0u;
                newPart  ~= fi < facePart.length     ? facePart[fi]     : 0u;
                newOrd   ~= 0;
                // Task 0389: the retained skin is a reversed duplicate of the
                // source face at its ORIGINAL position — inherit its Subpatch
                // bit rather than always dropping it, so a Thicken on a
                // subdiv-marked face keeps both shells subdiv.
                newSub   ~= isFaceSubpatch(fi);
            }
        }

        // Wall quads: one per boundary edge (same orientability rule as
        // extrudeFacesByMask — the cap walks cloneA→cloneB iff the original
        // face walked a→b; the wall shares that top edge in the opposite
        // direction).
        foreach (ref be; bEdges) {
            uint a = be.va, b = be.vb;
            int island = islandOf[be.selFi];
            uint cloneA = vertMap[ivKey(island, a)], cloneB = vertMap[ivKey(island, b)];
            bool origAtoB = false;
            auto orig = faces[be.selFi];
            foreach (k; 0 .. orig.length) {
                uint u = orig[k], w = orig[(k + 1) % orig.length];
                if (u == a && w == b) { origAtoB = true;  break; }
                if (u == b && w == a) { origAtoB = false; break; }
            }
            if (origAtoB) newFaces ~= [cloneB, cloneA, a, b];
            else          newFaces ~= [cloneA, cloneB, b, a];
            newMat  ~= be.selFi < faceMaterial.length ? faceMaterial[be.selFi] : 0u;
            newPart ~= be.selFi < facePart.length     ? facePart[be.selFi]     : 0u;
            newOrd  ~= 0;
            // Task 0389: skin wall inherits Subpatch from the source face it
            // skirts, same as its material/part above.
            newSub  ~= isFaceSubpatch(be.selFi);
        }

        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;
        faceMarks.length = faces.length;
        faceMarks[]      = 0;
        foreach (fi, s; newSub)
            if (s) faceMarks[fi] |= Marks.Subpatch;

        // New selection = cap faces (chains a follow-up op off the top, same
        // as extrudeFacesByMask). The retained thicken skin is NOT selected.
        faceSelectionOrderCounter = 0;
        foreach (fi; capStart .. capStart + selCount)
            selectFace(cast(int)fi);

        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        rebuildEdges();
        buildLoops();
        compactUnreferenced();
        buildLoops();

        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return selCount;
    }

    unittest {
        import std.math : abs;
        import std.conv : to;

        // base_noop: shift=0, scale=1, thicken=false, single top-face
        // selection on a stock cube. Matches the frozen reference capture
        // (tests/fixtures/smooth_shift.json "base_noop") — 12v/10f, NOT a
        // no-op (see the kernel doc comment on the shift==0 divergence).
        {
            auto m = makeCube();
            bool[] mask; mask.length = m.faces.length; mask[] = false;
            // Find the top face (all 4 verts at y ≈ +0.5).
            int topFi = -1;
            foreach (fi; 0 .. m.faces.length) {
                bool allTop = true;
                foreach (vid; m.faces[fi]) if (m.vertices[vid].y < 0.4f) { allTop = false; break; }
                if (allTop) { topFi = cast(int)fi; break; }
            }
            assert(topFi >= 0, "smoothShiftFacesByMask test: no top face found");
            mask[topFi] = true;
            size_t n = m.smoothShiftFacesByMask(mask, 0.0f, 1.0f, false);
            assert(n == 1, "smoothShiftFacesByMask base_noop: expected 1 face cloned");
            assert(m.faces.length == 10,
                "smoothShiftFacesByMask base_noop: expected 10 faces, got " ~ m.faces.length.to!string);
            assert(m.vertices.length == 12,
                "smoothShiftFacesByMask base_noop: expected 12 verts, got " ~ m.vertices.length.to!string);
        }

        // shift03_scale05: shift=0.3, scale=0.5 — pins the scale-about-
        // island-centroid law exactly (frozen capture "shift03_scale05").
        {
            auto m = makeCube();
            bool[] mask; mask.length = m.faces.length; mask[] = false;
            int topFi = -1;
            foreach (fi; 0 .. m.faces.length) {
                bool allTop = true;
                foreach (vid; m.faces[fi]) if (m.vertices[vid].y < 0.4f) { allTop = false; break; }
                if (allTop) { topFi = cast(int)fi; break; }
            }
            mask[topFi] = true;
            size_t n = m.smoothShiftFacesByMask(mask, 0.3f, 0.5f, false);
            assert(n == 1, "smoothShiftFacesByMask shift03_scale05: expected 1 face cloned");
            // Expect a new vertex at (-0.25, 0.65, -0.25) (corner (-0.5,0.5,-0.5)
            // shifted+scaled about the top face's centroid (0,0.5,0)).
            bool found = false;
            foreach (v; m.vertices) {
                if (abs(v.x - (-0.25f)) < 1e-3f && abs(v.y - 0.65f) < 1e-3f &&
                    abs(v.z - (-0.25f)) < 1e-3f) { found = true; break; }
            }
            assert(found, "smoothShiftFacesByMask shift03_scale05: no cap vert at (-0.25,0.65,-0.25)");
        }

        // thicken_top_only: shift=0.3, thicken=true — retains the original
        // top face as an 11th polygon (frozen capture "thicken_top_only").
        {
            auto m = makeCube();
            bool[] mask; mask.length = m.faces.length; mask[] = false;
            int topFi = -1;
            foreach (fi; 0 .. m.faces.length) {
                bool allTop = true;
                foreach (vid; m.faces[fi]) if (m.vertices[vid].y < 0.4f) { allTop = false; break; }
                if (allTop) { topFi = cast(int)fi; break; }
            }
            mask[topFi] = true;
            size_t n = m.smoothShiftFacesByMask(mask, 0.3f, 1.0f, true);
            assert(n == 1, "smoothShiftFacesByMask thicken_top_only: expected 1 face cloned");
            assert(m.faces.length == 11,
                "smoothShiftFacesByMask thicken_top_only: expected 11 faces, got " ~ m.faces.length.to!string);
            assert(m.vertices.length == 12,
                "smoothShiftFacesByMask thicken_top_only: expected 12 verts, got " ~ m.vertices.length.to!string);
            // The retained face's 4 verts must all still be at y ≈ 0.5 (unmoved).
            int retainedCount = 0;
            foreach (fi; 0 .. m.faces.length) {
                if (m.faces[fi].length != 4) continue;
                bool allOrigTop = true;
                foreach (vid; m.faces[fi])
                    if (abs(m.vertices[vid].y - 0.5f) > 1e-3f) { allOrigTop = false; break; }
                if (allOrigTop) ++retainedCount;
            }
            assert(retainedCount >= 1,
                "smoothShiftFacesByMask thicken_top_only: no retained (unmoved) top face found");
        }
    }

    // Deduplicated edge insert: append (a,b) + record its index in `lookup`
    // unless an edge with the same undirected key is already present. The
    // stored index is `edges.length` BEFORE the append — identical to
    // `edges.length - 1` taken AFTER the append (the shape the former
    // addFaceFast inner loop used), so callers written either way observe
    // the same value. Returns whether an edge was actually inserted (false
    // on a duplicate), so callers that only want to commit/bump on a real
    // insert (addEdge) can gate on the result.
    private bool insertEdgeDedup(ref uint[ulong] lookup, uint a, uint b) {
        ulong key = edgeKey(a, b);
        if (key in lookup) return false;
        lookup[key] = cast(uint)edges.length;
        edges ~= [a, b];
        return true;
    }

    void addEdge(uint a, uint b) {
        if (insertEdgeDedup(edgeIndexMap, a, b)) {
            // Structural change: one edge appended, and edgeIndexMap (the
            // map we just inserted into) stays fully in sync.
            ++structVersion;
            edgeMapStamp  = structVersion;
            edgeMapState_ = DerivedState.Valid;
            commitChange(MeshEditScope.Polygons);
        }
    }
    /// Re-derive the deduplicated edge list AND `edgeIndexMap` from the
    /// current `faces` via `addEdge` (which also bumps the version
    /// counters). Mutating ops that rewrite `faces` call this to keep
    /// edges + the lookup map consistent. Iteration order over faces/loop
    /// corners is fixed, so the resulting edge indices are deterministic —
    /// callers rely on this when resizing the edge-selection arrays
    /// afterwards. This helper does NOT touch selection arrays; the caller
    /// owns those. (Distinct from `rebuildEdgesFromFaces`, which rebuilds
    /// `edges` only and leaves `edgeIndexMap` / the version counters alone.)
    // Re-derive the deduplicated edge array (+ edgeIndexMap) from faces. Used
    // internally by every topology mutator and by mesh_edit_delta's replay
    // finalize so a delta apply/revert produces the same canonical edge order
    // the kernels do.
    void rebuildEdges() {
        edges.length = 0;
        edgeIndexMap.clear();
        foreach (ref f; faces)
            foreach (k; 0 .. f.length)
                addEdge(f[k], f[(k + 1) % f.length]);
    }
    void addFace(uint[] idx) {
        faces ~= idx.dup;
        for (uint i = 0; i < idx.length; i++)
            addEdge(idx[i], idx[(i+1) % idx.length]);
        // GAP-3 atomic append: addFace does NOT call buildLoops, so without
        // this the PolyVertex element count (loops.length) would lag the new
        // face's corners until some later buildLoops. The new face's corners are
        // appended LAST in CSR loop order, so growing each PolyVertex map by
        // `idx.length * dim` zeros at the END keeps element-major alignment and
        // the invariant `data.length == Σ face-arities * dim` holds immediately.
        growPolyVertexMapsForAppendedCorners(idx.length);
        // The face itself is a structural change beyond whatever the addEdge
        // loop above already bumped (covers a face whose edges ALL pre-exist,
        // where that loop bumps nothing at all). edgeIndexMap stays fully in
        // sync — every edge above went through addEdge, which maintains it —
        // so re-stamp it Valid at the new structVersion. Loops are NOT
        // rebuilt here, so loopsState_/loopsStamp are left as-is (correctly
        // stale relative to the bumped structVersion, until the caller's
        // terminal buildLoops()).
        ++structVersion;
        edgeMapStamp  = structVersion;
        edgeMapState_ = DerivedState.Valid;
        commitChange(MeshEditScope.Geometry);
        // Class P tracker hook — inert unless a batch is open.
        if (editRecorder_ !is null)
            editRecorder_.recordAddFace(cast(uint)(faces.length - 1), idx);
    }
    // Fast version using hash lookup for duplicate checking
    void addFaceFast(ref uint[ulong] edgeLookup, uint[] idx) {
        faces ~= idx.dup;
        for (uint i = 0; i < idx.length; i++)
            insertEdgeDedup(edgeLookup, idx[i], idx[(i+1) % idx.length]);
        // GAP-3 atomic append — see addFace.
        growPolyVertexMapsForAppendedCorners(idx.length);
        // Structural change (face + external-lookup edges appended) — bump
        // once. This primitive does NOT touch `this.edgeIndexMap` (the
        // caller supplies its own scratch `edgeLookup` and defers the
        // canonical map to a terminal buildLoops()), so mark edgeMapState_
        // Stale — edgeMapUsable() must report false until that buildLoops()
        // runs. Loops are deferred too; leave loopsState_/loopsStamp as-is.
        ++structVersion;
        edgeMapState_ = DerivedState.Stale;
        commitChange(MeshEditScope.Geometry);
        // Class P tracker hook — inert unless a batch is open.
        if (editRecorder_ !is null)
            editRecorder_.recordAddFace(cast(uint)(faces.length - 1), idx);
    }

    // Grow every PolyVertex map by `nCorners` zero-filled elements at the END —
    // the corners an appended face contributes (which are last in CSR loop
    // order). Keeps `data.length == Σ face-arities * dim` true with NO window,
    // even though `addFace`/`addFaceFast` defer the loops rebuild. No-op when no
    // PolyVertex map is registered.
    private void growPolyVertexMapsForAppendedCorners(size_t nCorners) {
        foreach (ref m; meshMaps) {
            if (m.domain != MapDomain.PolyVertex) continue;
            const size_t old = m.data.length;
            m.data.length = old + nCorners * m.dim;
            m.data[old .. $] = 0.0f; // float.init is NaN
        }
    }
    // Non-allocating "any bit set?" scans straight over the marks arrays.
    // These run per-frame / per-drag-event from the toolpipe stages and
    // render path, so they avoid materializing a `bool[]` snapshot first.
    bool hasAnySelectedVertices() const {
        foreach (m; vertexMarks) if (m & Marks.Select) return true;
        return false;
    }
    bool hasAnySelectedEdges() const {
        foreach (m; edgeMarks) if (m & Marks.Select) return true;
        return false;
    }
    bool hasAnySelectedFaces() const {
        foreach (m; faceMarks) if (m & Marks.Select) return true;
        return false;
    }
    bool hasAnySubpatch() const {
        foreach (m; faceMarks) if (m & Marks.Subpatch) return true;
        return false;
    }
    /// True when the given edit mode has no active selection. By
    /// convention an empty selection means "operate on the whole mesh",
    /// so commands and tools treat this as "everything is selected"
    /// (cf. selectedVertexIndices*, which return all indices when nothing
    /// is selected). The check is per-element-type because selections are
    /// kept independent across modes.
    bool nothingSelected(EditMode mode) const {
        final switch (mode) {
            case EditMode.Vertices: return !hasAnySelectedVertices();
            case EditMode.Edges:    return !hasAnySelectedEdges();
            case EditMode.Polygons: return !hasAnySelectedFaces();
        }
    }
    /// The geometry type that mesh.delete / mesh.remove should operate on.
    ///
    /// Normally the same as `current` (the caller's active edit mode). But
    /// when `current` has NO selection while another geometry type DOES hold a
    /// selection, return that type instead. Without this redirect the
    /// "empty selection ⇒ whole mesh" convention (see nothingSelected) fires
    /// against the active mode and wipes the mesh even though a selection
    /// exists in a different element type (task 0110).
    ///
    /// Priority when the active mode is empty and more than one other type
    /// holds a selection: Polygons > Edges > Vertices. This order is a
    /// deterministic vibe3d-internal convention; any fixed order is safe
    /// because the sole objective is to avoid the whole-mesh path.
    ///
    /// Returns `current` unchanged when (a) the active mode already holds a
    /// selection, or (b) no geometry type holds any selection (truly empty
    /// everywhere — the whole-mesh convention is intentional in that case).
    EditMode effectiveDeleteMode(EditMode current) const {
        if (!nothingSelected(current)) return current;  // active mode has a selection
        if (hasAnySelectedFaces())     return EditMode.Polygons;
        if (hasAnySelectedEdges())     return EditMode.Edges;
        if (hasAnySelectedVertices())  return EditMode.Vertices;
        return current;  // truly nothing selected anywhere → whole-mesh convention
    }
    /// Loop-Slice activation from a POLYGON selection (task 0245): the
    /// "interior" cage edges of the selected face region — every existing edge
    /// incident to TWO OR MORE selected faces, i.e. the edges that lie
    /// *between* the selected polygons. For two adjacent selected quads this is
    /// exactly their single shared edge; a lone selected face, or two
    /// non-adjacent faces, yields an empty result. The set is deduplicated and
    /// returned in ascending edge-index order. Reads only the current face
    /// selection + topology (`edgeIndexMap`); never mutates.
    ///
    /// This backs the Loop Slice tool's "act on the edge BETWEEN the selected
    /// polygons" activation rule: a polygon selection PICKS the loop the same
    /// way an edge selection names its seed edge(s) — the ring crossing each
    /// seed edge is what the cut lands on (see `loopSliceRingEdges` /
    /// `collectEdgeRing`).
    uint[] interiorEdgesOfSelectedFaces() const {
        uint[uint] incident;   // edge index → count of selected faces touching it
        foreach (fi; 0 .. faces.length) {
            if (!isFaceSelected(fi)) continue;
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                uint ei = edgeIndex(f[k], f[(k + 1) % f.length]);
                if (ei == ~0u) continue;
                incident[ei] = (ei in incident ? incident[ei] : 0u) + 1u;
            }
        }
        uint[] res;
        foreach (ei, c; incident) if (c >= 2) res ~= ei;
        import std.algorithm : sort;
        res.sort();
        return res;
    }
    unittest {
        // interiorEdgesOfSelectedFaces — Loop Slice polygon-activation rule.
        // Cube faces (makeCube): 0=z-0.5, 1=z+0.5, 2=x-0.5, 3=x+0.5,
        // 4=y+0.5, 5=y-0.5.
        bool[] mask(size_t[] on...) {
            auto m = new bool[](6);
            foreach (i; on) m[i] = true;
            return m;
        }

        // Two ADJACENT faces (front z=-0.5 & bottom y=-0.5) share edge (0,1)
        // → exactly one interior edge = that shared edge.
        auto m = makeCube();
        m.setFacesSelectedFrom(mask(0, 5));
        auto sharedEdges = m.interiorEdgesOfSelectedFaces();
        assert(sharedEdges.length == 1,
            "2 adjacent faces must yield exactly 1 shared edge");
        assert(sharedEdges[0] == m.edgeIndex(0, 1),
            "shared edge of front+bottom must be edge (0,1)");

        // Two NON-adjacent (opposite) faces (front z=-0.5 & back z=+0.5) share
        // no edge → empty.
        auto m2 = makeCube();
        m2.setFacesSelectedFrom(mask(0, 1));
        assert(m2.interiorEdgesOfSelectedFaces().length == 0,
            "2 opposite faces share no edge → no seed");

        // A single face has no interior edge (every edge touches only it).
        auto m3 = makeCube();
        m3.setFacesSelectedFrom(mask(0));
        assert(m3.interiorEdgesOfSelectedFaces().length == 0,
            "a lone selected face yields no seed");
    }
    /// True iff every face is subpatch-marked AND there's at least one
    /// face. Gates the OSD-accelerated SubpatchPreview fast path:
    /// OpenSubdiv subdivides the WHOLE mesh, so selective subpatch
    /// (some faces marked, others not) keeps the existing vibe3d
    /// catmullClarkSelected path.
    bool allSubpatch() const {
        if (faces.length == 0) return false;
        if (faceMarks.length < faces.length) return false;
        foreach (i; 0 .. faces.length)
            if ((faceMarks[i] & Marks.Subpatch) == 0) return false;
        return true;
    }

    void setSubpatch(size_t idx, bool on) {
        if (idx >= faceMarks.length) return;
        bool cur = (faceMarks[idx] & Marks.Subpatch) != 0;
        if (cur != on) {
            if (on) faceMarks[idx] |=  Marks.Subpatch;
            else    faceMarks[idx] &= ~Marks.Subpatch;
            // Subpatch is a Marks-class flip, but it also changes the subpatch
            // preview's OUTPUT topology, so we keep the topologyVersion bump the
            // old line carried (commitChange(Marks) alone would not, since Marks
            // is not a Geometry class). Counters end identical to the raw line.
            commitChange(MeshEditScope.Marks);
            ++topologyVersion;
        }
    }
    void clearSubpatch() {
        bool any = false;
        foreach (m; faceMarks) if (m & Marks.Subpatch) { any = true; break; }
        // Mask ONLY the Subpatch bit — Select shares this word.
        foreach (ref m; faceMarks) m &= ~Marks.Subpatch;
        // Same as setSubpatch: Marks-class flip that also invalidates subpatch
        // preview output topology — keep the topologyVersion bump explicitly.
        if (any) { commitChange(MeshEditScope.Marks); ++topologyVersion; }
    }

    // The clear* setters compare-before-set too: only publish if at least one
    // Select bit was actually set (clearing an already-empty selection is a
    // no-op and must not publish — e.g. the unconditional clearVertex/Face
    // calls topology mutators run on edge-only edits).
    void clearVertexSelection() {
        bool any = false;
        foreach (m; vertexMarks) if (m & Marks.Select) { any = true; break; }
        foreach (ref m; vertexMarks) m &= ~Marks.Select;
        vertexSelectionOrder[] = 0;
        vertexSelectionOrderCounter = 0;
        if (any) noteSelectionChange(SelDomain.Vertex);
    }
    void clearEdgeSelection() {
        bool any = false;
        foreach (m; edgeMarks) if (m & Marks.Select) { any = true; break; }
        foreach (ref m; edgeMarks) m &= ~Marks.Select;
        edgeSelectionOrder[] = 0;
        edgeSelectionOrderCounter = 0;
        if (any) noteSelectionChange(SelDomain.Edge);
    }
    void clearFaceSelection() {
        // Mask ONLY the Select bit — Subpatch shares this word and must
        // survive a selection clear.
        bool any = false;
        foreach (m; faceMarks) if (m & Marks.Select) { any = true; break; }
        foreach (ref m; faceMarks) m &= ~Marks.Select;
        faceSelectionOrder[] = 0;
        faceSelectionOrderCounter = 0;
        if (any) noteSelectionChange(SelDomain.Face);
    }

    // --- Per-element selection-array resize primitives ---------------------
    // Grow/shrink the parallel selection-bit + pick-order arrays to match the
    // current geometry length WITHOUT clearing them. Topology mutators call
    // one of these (then a clear*, when the bits are no longer valid) instead
    // of writing the `.length = ...` lines by hand — the boilerplate was
    // duplicated across resetSelection, weld, compact, delete/dissolve and the
    // create-style mutators. New per-element flags (hide/lock/…) would only
    // need to extend the relevant primitive here, not every call site.
    void resizeVertexSelection() {
        vertexMarks.length          = vertices.length;
        vertexSelectionOrder.length = vertices.length;
        resizeMeshMaps(MapDomain.Point);
    }
    void resizeEdgeSelection() {
        edgeMarks.length          = edges.length;
        edgeSelectionOrder.length = edges.length;
        resizeMeshMaps(MapDomain.Edge);
    }
    void resizeFaceSelection() {
        // Only the per-face marks array (folding Select + Subpatch). The
        // pick-order / subpatch / material arrays are rebuilt in lock-step with
        // `faces` by the calling mutator.
        faceMarks.length = faces.length;
    }

    // --- Mesh-map registry + lifecycle ------------------------------------
    // Number of elements in a given domain — the per-domain length a map's
    // `data` is `dim`-times larger than.
    size_t elementCount(MapDomain domain) const {
        final switch (domain) {
            case MapDomain.Point:      return vertices.length;
            case MapDomain.Edge:       return edges.length;
            case MapDomain.PolyVertex: return loops.length;
        }
    }

    // Address a face-corner as a PolyVertex element (loop) index. `buildLoops`
    // lays loops out CSR-style — `faceLoop[fi]` is the first loop of face `fi`,
    // and corner `c` is at `faceLoop[fi] + c`. This is the canonical
    // `(face, corner) → element` mapping for the PolyVertex domain; import /
    // export / codec address corners through this helper rather than
    // hard-coding the CSR formula. Bounds-guarded: returns `~0u` (size_t.max)
    // for an out-of-range face or corner so callers can detect it instead of
    // indexing past `loops`.
    size_t faceCornerLoop(uint fi, uint corner) const {
        if (fi >= faceLoop.length) return size_t.max;
        const size_t base = faceLoop[fi];
        // The face's corner count is the gap to the next face's first loop
        // (or to `loops.length` for the last face).
        const size_t end = (fi + 1 < faceLoop.length) ? faceLoop[fi + 1] : loops.length;
        if (base + corner >= end) return size_t.max;
        return base + corner;
    }

    // Grow/shrink every registered map of `domain` so its `data.length`
    // matches `elementCount(domain) * dim`. New trailing slots default to 0.
    // Same grow-and-keep discipline as the selection/marks resize primitives:
    // values are length-correct but NOT remapped across destructive edits.
    // Called from resizeVertexSelection (Point) / resizeEdgeSelection (Edge)
    // so it cannot be forgotten by a topology mutator.
    void resizeMeshMaps(MapDomain domain) {
        foreach (ref m; meshMaps) {
            if (m.domain != domain) continue;
            resizeMeshMapData(m);
        }
    }

    // Resize all registered maps across every domain (used by snapshot restore
    // and any caller that replaced multiple element arrays at once).
    void resizeAllMeshMaps() {
        foreach (ref m; meshMaps)
            resizeMeshMapData(m);
    }

    // Bring every PolyVertex map's `data` in step with the current loop layout,
    // called from `buildLoops` AFTER `loops` is rebuilt. The rule distinguishes
    // a relocate/append (values already placed) from a topology REWRITE (drop):
    //
    //   * If `data.length` ALREADY equals `loops.length * dim`, the values were
    //     placed deliberately just before this `buildLoops` — by
    //     `remapPolyVertexMaps` (mechanism a/b) or the atomic `addFace` append,
    //     or are simply unchanged across a benign rebuild — so KEEP them.
    //   * Otherwise the face/loop topology was rewritten WITHOUT a relocate (the
    //     DROP class: primitive rebuilds, subdivide, extrude, edge-extend,
    //     bridge, subpatch cage). The old per-corner values are meaningless in
    //     the new corner space, so ZERO the whole map at the new length. This is
    //     the conscious, length-correct, value-dropped behaviour (D5 drop set);
    //     leaving stale leading values in new corner slots would be silent
    //     corruption.
    //
    // No-op when no PolyVertex map is registered.
    void resizePolyVertexMaps() {
        foreach (ref m; meshMaps) {
            if (m.domain != MapDomain.PolyVertex) continue;
            const size_t want = loops.length * m.dim;
            if (m.data.length == want) continue; // relocate/append/unchanged → keep
            // Topology rewritten without a relocate ⇒ drop (length-correct, zeroed).
            m.data.length = want;
            m.data[] = 0.0f;
        }
    }

    // --- PolyVertex remap lifecycle (the two mechanisms) ------------------
    // Mechanism (a) — arity-PRESERVING relocate funnel. For mutators that drop /
    // compact / reorder whole faces but KEEP each surviving face's corner count.
    // `oldLoopOfNewLoop[newLoopIdx] = oldLoopIdx` (or `~0u` ⇒ a brand-new corner,
    // zero-filled). Each PolyVertex map's `data` is rebuilt to the new
    // `oldLoopOfNewLoop.length * dim` by gathering `old.data[oldIdx*dim .. ]`
    // (or zeros on `~0u`). Call this BEFORE the tail `buildLoops` (which then
    // sees a length-correct map and no-ops in `resizePolyVertexMaps`).
    //
    // The caller builds `oldLoopOfNewLoop` from `oldFaceLoop` (the CSR offsets
    // captured at mutator entry, before `faces` is rewritten): for each surviving
    // new face whose old face index is `oldFi`, corner `c` came from old loop
    // `oldFaceLoop[oldFi] + c`.
    void remapPolyVertexMaps(const uint[] oldLoopOfNewLoop) {
        foreach (ref m; meshMaps) {
            if (m.domain != MapDomain.PolyVertex) continue;
            const ubyte dim = m.dim;
            float[] nd;
            nd.length = oldLoopOfNewLoop.length * dim;
            nd[] = 0.0f;
            foreach (newIdx, oldIdx; oldLoopOfNewLoop) {
                if (oldIdx == ~0u) continue; // brand-new corner ⇒ zero
                const size_t ob = cast(size_t)oldIdx * dim;
                if (ob + dim > m.data.length) continue; // defensive
                nd[newIdx * dim .. newIdx * dim + dim] = m.data[ob .. ob + dim];
            }
            m.data = nd;
        }
    }

    // Mechanism (b) — arity-CHANGING per-face rewrite. For mutators that rewrite
    // a face's corner LIST (weld / dissolve / edge-merge), new corner `j` of a
    // rewritten face came from old corner `k` of the SAME old face (or is brand
    // new). The only place that knows the old→new corner correspondence is the
    // loop that builds the new face, so each such mutator builds an
    // `oldLoopOfNewLoop` array IN NEW-FACE / NEW-CORNER ORDER (the same CSR order
    // `buildLoops` will lay down): for new corner `j` of a new face whose old
    // face index is `oldFi`, push `oldFaceLoopIndex(oldFi, k)` for the kept old
    // corner `k`, or `~0u` for a brand-new corner. It then calls
    // `remapPolyVertexMaps(oldLoopOfNewLoop)` — the SAME funnel as (a); the two
    // mechanisms differ only in how `oldLoopOfNewLoop` is constructed, not in the
    // relocate step. `oldFaceLoopIndex` resolves (oldFi, corner) against the
    // OLD CSR offsets captured at mutator entry.
    static uint oldFaceLoopIndex(const uint[] oldFaceLoop, uint oldFi, uint corner) {
        if (oldFi >= oldFaceLoop.length) return ~0u;
        return oldFaceLoop[oldFi] + corner;
    }

    // True iff at least one PolyVertex map is registered. Mutators take the
    // remap path only when this is true — otherwise the (cheap) capture +
    // funnel work is skipped entirely (the common case: no UV map). The drop
    // class needs no guard: `resizePolyVertexMaps` inside `buildLoops` is itself
    // a no-op when no PolyVertex map exists.
    bool hasPolyVertexMap() const {
        foreach (ref m; meshMaps)
            if (m.domain == MapDomain.PolyVertex) return true;
        return false;
    }

    // Capture the CSR corner offsets for the CURRENT faces, to be consulted by
    // `oldFaceLoopIndex` while rebuilding `oldLoopOfNewLoop`. The live `faceLoop`
    // is valid at any topology-mutator entry (the prior op left it in step with
    // `faces` via `buildLoops`), so this is just a defensive `.dup`.
    uint[] captureFaceLoop() const {
        return faceLoop.dup;
    }

    // Grow/shrink one map's data to `elementCount(domain) * dim`, zero-filling
    // any newly grown slots. `float.init` is NaN in D, so an explicit zero is
    // required for new entries to read back as 0 (the documented default).
    private void resizeMeshMapData(ref MeshMap m) {
        const size_t want = elementCount(m.domain) * m.dim;
        const size_t old  = m.data.length;
        m.data.length = want;
        if (want > old) m.data[old .. $] = 0.0f;
    }

    // Register a new per-element float channel. `dim` must be >= 1; `name`
    // must be non-empty and not already registered; PolyVertex is reserved.
    // Returns a pointer to the stored map (data zero-initialised to the right
    // length), or null on rejection. Defensive, like the rest of mesh.d.
    MeshMap* addMeshMap(string name, ubyte dim, MapDomain domain) {
        if (name.length == 0) return null;
        if (dim == 0) return null;
        // PolyVertex (per-corner) is live: sized to `loops.length * dim` via
        // `elementCount` below, same as Point/Edge. Its values are relocated
        // across face-mutating edits by the two-mechanism lifecycle
        // (remapPolyVertexMaps / rebuildPolyVertexAtFace); see the meshMaps
        // field comment for the wired vs drop sets.
        if (meshMap(name) !is null) return null; // names are unique per mesh
        MeshMap m;
        m.name   = name;
        m.dim    = dim;
        m.domain = domain;
        m.data.length = elementCount(domain) * dim;
        m.data[] = 0.0f; // float.init is NaN; default mesh-map value is 0
        meshMaps ~= m;
        return &meshMaps[$ - 1];
    }

    // Lookup by name → pointer to the stored map, or null if absent.
    MeshMap* meshMap(string name) return {
        foreach (ref m; meshMaps)
            if (m.name == name) return &m;
        return null;
    }

    // const overload for read-only call sites.
    const(MeshMap)* meshMap(string name) const return {
        foreach (ref m; meshMaps)
            if (m.name == name) return &m;
        return null;
    }

    // Remove a registered map by name. Returns true if one was removed.
    bool removeMeshMap(string name) {
        foreach (i, ref m; meshMaps) {
            if (m.name == name) {
                meshMaps = meshMaps[0 .. i] ~ meshMaps[i + 1 .. $];
                return true;
            }
        }
        return false;
    }

    // Read element `elemIdx`'s components from map `name`. Returns an empty
    // slice if the map is missing or the index is out of range (defensive).
    // The returned slice is a fresh copy (`dup`), safe to hold across edits.
    float[] meshMapValue(string name, size_t elemIdx) const {
        auto m = meshMap(name);
        if (m is null) return [];
        const size_t base = elemIdx * m.dim;
        if (base + m.dim > m.data.length) return [];
        return m.data[base .. base + m.dim].dup;
    }

    // Write element `elemIdx`'s components into map `name`. `values.length`
    // must equal the map's `dim`. No-op (returns false) on a missing map,
    // out-of-range index, or dim mismatch. Bumps `mutationVersion` on a real
    // write so caches that depend on map values can detect the change.
    bool setMeshMapValue(string name, size_t elemIdx, const float[] values) {
        auto m = meshMap(name);
        if (m is null) return false;
        if (values.length != m.dim) return false;
        const size_t base = elemIdx * m.dim;
        if (base + m.dim > m.data.length) return false;
        m.data[base .. base + m.dim] = values[];
        // Mesh-map value write (UV / weight / crease — continuous per-element
        // data). No dedicated Maps class exists yet (reserved until #5 UV work),
        // and this is NOT a topology change, so we classify it as Material —
        // the only non-Geometry tag-class flag — to preserve the version parity
        // (mutationVersion bumps, topologyVersion does not). Reclassify to Maps
        // when that flag lands. (See report: ambiguous site.)
        commitChange(MeshEditScope.Material);
        return true;
    }

    /// Return names of all registered `MapDomain.Point, dim==1` weight maps.
    string[] weightMapNames() const {
        string[] names;
        foreach (ref m; meshMaps)
            if (m.domain == MapDomain.Point && m.dim == 1)
                names ~= m.name;
        return names;
    }

    /// Convenience: add a Point dim-1 weight map. Delegates to addMeshMap.
    MeshMap* addWeightMap(string name) {
        return addMeshMap(name, 1, MapDomain.Point);
    }

    /// Per-vertex weight read. Returns 0.0 on missing map or out-of-range index.
    float vertexWeight(string name, size_t vi) const {
        auto m = meshMap(name);
        if (m is null) return 0.0f;
        if (m.domain != MapDomain.Point || m.dim != 1) return 0.0f;
        if (vi >= m.data.length) return 0.0f;
        return m.data[vi];
    }

    /// Per-vertex weight write. Returns true on success.
    bool setVertexWeight(string name, size_t vi, float w) {
        return setMeshMapValue(name, vi, [w]);
    }

    // Resize the per-edge arrays to `edges` length and drop every edge
    // selection bit. The pick-order array is resized but NOT zeroed and the
    // counter is left alone (callers that reach here have already replaced the
    // topology, so surviving order values are stale-but-harmless) — this is
    // the exact triplet the topology mutators ran after a `rebuildEdges()`.
    void clearEdgeSelectionResize() {
        resizeEdgeSelection();
        bool any = false;
        foreach (m; edgeMarks) if (m & Marks.Select) { any = true; break; }
        foreach (ref m; edgeMarks) m &= ~Marks.Select;
        // Publishes the Edge domain when a topology edit drops a live edge
        // selection. The enclosing mutator already publishes Geometry; the
        // selection-domain bit rides the same per-frame flush.
        if (any) noteSelectionChange(SelDomain.Edge);
    }

    // Resize the per-face selection-bit array to `faces` length and drop every
    // face selection bit. The pick-order / subpatch / material arrays are
    // managed by the caller. Extracted from the identical pair the topology
    // mutators ran after assigning a freshly filtered `faces` array.
    void clearFaceSelectionResize() {
        resizeFaceSelection();
        // Mask ONLY the Select bit — Subpatch shares this word and the
        // calling mutator has already written it (B3 ordering).
        bool any = false;
        foreach (m; faceMarks) if (m & Marks.Select) { any = true; break; }
        foreach (ref m; faceMarks) m &= ~Marks.Select;
        if (any) noteSelectionChange(SelDomain.Face);
    }

    // --- Subpatch resize / write surface ----------------------------------
    // Grow/shrink the per-face subpatch-flag array to match `faces` length
    // WITHOUT clearing it (same grow-and-keep convention as the selection
    // resize primitives). The parallel pick-order / material arrays are
    // managed separately by the calling mutator.
    void resizeSubpatch() {
        // faceMarks folds both Select and Subpatch for faces; keep its length
        // in lock-step with `faces` (resizeFaceSelection may not have been
        // called on the subpatch-only resize path).
        faceMarks.length = faces.length;
    }

    // Single-index subpatch write. Bounds-guarded; does NOT bump the
    // mutation/topology version (callers that need a version bump on a
    // user-facing toggle use `setSubpatch`). Used by bulk/internal writers.
    void setFaceSubpatch(size_t fi, bool flag) {
        if (fi >= faceMarks.length) return;
        if (flag) faceMarks[fi] |=  Marks.Subpatch;
        else      faceMarks[fi] &= ~Marks.Subpatch;
    }

    // --- Whole-array selection/subpatch replace (resize-then-copy) ---------
    // Each setter touches ONLY its own concept (Select bit for vertices /
    // edges / faces, or the Subpatch flag) so the two face concepts stay
    // order-independent. `src` is treated as the new authoritative array;
    // the backing array is resized to `src.length`, then copied.
    // The bulk setters COMPARE-BEFORE-SET for the bus publish (Stage 5): they
    // already iterate, so detecting "did any Select bit actually flip" is free,
    // and it stops a no-op restore (re-applying an identical selection — common
    // on undo/redo snapshot replay) from spuriously publishing a selection
    // change. A length change is itself a change. The Marks WRITE stays
    // unconditional (cheap, and keeps the array length correct even on a
    // value-identical-but-length-changed src).
    void setVerticesSelectedFrom(const bool[] src) {
        bool changed = (vertexMarks.length != src.length);
        vertexMarks.length = src.length;
        // Grow-before-index: the order array must reach src.length before the
        // loop below can write to it, or a shorter order array (e.g. right
        // after a geometry-growing op that hasn't synced order yet) would
        // RangeError. Growing never shrinks, so trailing order[i >= old
        // length] entries default to 0 (int.init) — consistent with "not
        // manually selected". If a future caller ever passes a SHORTER src
        // than the current order array, the extra trailing order[i >=
        // src.length] slots are simply left untouched (harmless stale data,
        // matching the array's pre-existing grow-only behavior elsewhere).
        if (vertexSelectionOrder.length < src.length)
            vertexSelectionOrder.length = src.length;
        foreach (i, s; src) {
            const cur = (vertexMarks[i] & Marks.Select) != 0;
            if (cur != s) changed = true;
            if (s) vertexMarks[i] |=  Marks.Select;
            else { vertexMarks[i] &= ~Marks.Select; vertexSelectionOrder[i] = 0; }
        }
        if (changed) noteSelectionChange(SelDomain.Vertex);
    }
    void setEdgesSelectedFrom(const bool[] src) {
        bool changed = (edgeMarks.length != src.length);
        edgeMarks.length = src.length;
        // See setVerticesSelectedFrom for the grow-before-index rationale.
        if (edgeSelectionOrder.length < src.length)
            edgeSelectionOrder.length = src.length;
        foreach (i, s; src) {
            const cur = (edgeMarks[i] & Marks.Select) != 0;
            if (cur != s) changed = true;
            if (s) edgeMarks[i] |=  Marks.Select;
            else { edgeMarks[i] &= ~Marks.Select; edgeSelectionOrder[i] = 0; }
        }
        if (changed) noteSelectionChange(SelDomain.Edge);
    }
    void setFacesSelectedFrom(const bool[] src) {
        // Resize once, then touch ONLY the Select bit so this stays
        // order-independent with setFaceSubpatchFrom (B4 — snapshot restore
        // writes Select and Subpatch as two separate assigns). Resizing
        // preserves the Subpatch bit of any pre-existing entries.
        bool changed = (faceMarks.length != src.length);
        faceMarks.length = src.length;
        // See setVerticesSelectedFrom for the grow-before-index rationale.
        if (faceSelectionOrder.length < src.length)
            faceSelectionOrder.length = src.length;
        foreach (i, s; src) {
            const cur = (faceMarks[i] & Marks.Select) != 0;
            if (cur != s) changed = true;
            if (s) faceMarks[i] |=  Marks.Select;
            else { faceMarks[i] &= ~Marks.Select; faceSelectionOrder[i] = 0; }
        }
        if (changed) noteSelectionChange(SelDomain.Face);
    }
    void setFaceSubpatchFrom(const bool[] src) {
        // Resize once, then touch ONLY the Subpatch bit (order-independent
        // with setFacesSelectedFrom). Preserves the Select bit of existing
        // entries.
        faceMarks.length = src.length;
        foreach (i, s; src) {
            if (s) faceMarks[i] |=  Marks.Subpatch;
            else   faceMarks[i] &= ~Marks.Subpatch;
        }
    }

    void selectVertex(int idx) {
        if ((vertexMarks[idx] & Marks.Select) == 0)
            vertexSelectionOrder[idx] = ++vertexSelectionOrderCounter;
        vertexMarks[idx] |= Marks.Select;
        noteSelectionChange(SelDomain.Vertex);
    }
    void deselectVertex(int idx) {
        vertexMarks[idx] &= ~Marks.Select;
        vertexSelectionOrder[idx] = 0;
        noteSelectionChange(SelDomain.Vertex);
    }

    void selectEdge(int idx) {
        if ((edgeMarks[idx] & Marks.Select) == 0)
            edgeSelectionOrder[idx] = ++edgeSelectionOrderCounter;
        edgeMarks[idx] |= Marks.Select;
        noteSelectionChange(SelDomain.Edge);
    }
    void deselectEdge(int idx) {
        edgeMarks[idx] &= ~Marks.Select;
        edgeSelectionOrder[idx] = 0;
        noteSelectionChange(SelDomain.Edge);
    }

    void selectFace(int idx) {
        if ((faceMarks[idx] & Marks.Select) == 0)
            faceSelectionOrder[idx] = ++faceSelectionOrderCounter;
        faceMarks[idx] |= Marks.Select;
        noteSelectionChange(SelDomain.Face);
    }
    void deselectFace(int idx) {
        faceMarks[idx] &= ~Marks.Select;
        faceSelectionOrder[idx] = 0;
        noteSelectionChange(SelDomain.Face);
    }

    void clear() {
        vertices = []; edges = []; faces = [];
        loops = []; faceLoop = []; vertLoop = [];
        edgeIndexMap.clear();   // stale keys would shadow new addEdge calls
        // Reused-buffer guard: a prior Valid stamp over the now-empty loops/
        // edgeMap would read valid without a rebuild. Same class markDerivedEmpty
        // closes for the subpatch preview mesh; keep it consistent here.
        markDerivedEmpty();
    }

    /// Compute the unit normal of face fi using the first triangle (v0, v1, v2).
    /// Returns (0,1,0) for degenerate or tiny faces.
    Vec3 faceNormal(uint fi) const {
        // Newell's method: sums signed cross-product contributions from every
        // consecutive vertex pair. Robust to (a) collinear leading triples
        // (e.g. after splitting an edge — the inserted midpoint sits on the
        // line through its two original neighbors) and (b) slightly non-planar
        // n-gons. The naive "cross of the first two edges" fails on (a) and
        // produces a poor approximation on (b).
        const uint[] face = faces[fi];
        if (face.length < 3) return Vec3(0, 1, 0);
        float nx = 0, ny = 0, nz = 0;
        foreach (i; 0 .. face.length) {
            Vec3 a = vertices[face[i]];
            Vec3 b = vertices[face[(i + 1) % face.length]];
            nx += (a.y - b.y) * (a.z + b.z);
            ny += (a.z - b.z) * (a.x + b.x);
            nz += (a.x - b.x) * (a.y + b.y);
        }
        float len = sqrt(nx*nx + ny*ny + nz*nz);
        return len > 1e-6f ? Vec3(nx / len, ny / len, nz / len) : Vec3(0, 1, 0);
    }

    /// Per-face normal approximation used by `MeshSmooth`'s `lockSharp`
    /// dihedral test and the AI support-loop candidate generator
    /// (`ai.support_loop_candidates`): cross of a face's first 3 vertices,
    /// normalized. Deliberately NOT `faceNormal()` (Newell's method, used
    /// everywhere else in this file) — kept as its own smaller function so
    /// extracting the dihedral test out of `commands/mesh/smooth.d`'s inline
    /// computation does not change `MeshSmooth`'s existing numeric behavior
    /// (it always used this simpler 3-vertex-cross approximation — "exact
    /// for planar quads/triangles, a non-averaged approximation for
    /// non-planar n-gons").
    Vec3 faceNormalTri3(uint fi) const {
        const uint[] f = faces[fi];
        if (f.length < 3) return Vec3(0, 1, 0);
        Vec3 a = vertices[f[0]];
        Vec3 b = vertices[f[1]];
        Vec3 c = vertices[f[2]];
        Vec3 n = cross(b - a, c - a);
        float len = n.length;
        return len > 1e-9f ? n * (1.0f / len) : Vec3(0, 1, 0);
    }

    /// Per-edge dihedral sharpness, indexed like `edges[]`. Shared by
    /// `MeshSmooth.lockSharp` (`commands/mesh/smooth.d`) and the AI
    /// support-loop candidate generator (`ai.support_loop_candidates`) so the
    /// definition of "sharp edge" can never drift between the two call
    /// sites. Walks the half-edge loops exactly once per undirected INTERIOR
    /// edge (`li < twin` dedup — identical to the original inline
    /// `lockSharp` loop this replaces) and compares `faceNormalTri3` normals
    /// via the monotone `dot < cos(threshold)` test (cos is
    /// decreasing on [0, π], so this avoids an `acos` per edge and is
    /// numerically identical to the pre-extraction code). Boundary edges
    /// (`twin == uint.max`) are left at `EdgeSharpness.init`.
    EdgeSharpness[] computeEdgeSharpness(float thresholdDeg) const {
        import std.math : cos, acos, PI;

        auto result = new EdgeSharpness[](edges.length);
        auto fn = new Vec3[](faces.length);
        foreach (fi; 0 .. faces.length) fn[fi] = faceNormalTri3(cast(uint)fi);

        immutable cosThreshold = cos(thresholdDeg * (PI / 180.0f));
        foreach (li, ref l; loops) {
            if (l.twin == uint.max) continue;
            if (cast(uint)li > l.twin) continue;
            if (li >= loopEdge.length) continue;
            immutable ei = loopEdge[li];
            if (ei >= result.length) continue;

            immutable faceB = loops[l.twin].face;
            Vec3 n1 = fn[l.face];
            Vec3 n2 = fn[faceB];
            float dot = n1.x * n2.x + n1.y * n2.y + n1.z * n2.z;
            immutable dotClamped = dot < -1.0f ? -1.0f : (dot > 1.0f ? 1.0f : dot);

            result[ei].interior = true;
            result[ei].angleDeg = acos(dotClamped) * (180.0f / PI);
            result[ei].sharp    = dot < cosThreshold;
            result[ei].faceA    = l.face;
            result[ei].faceB    = faceB;
        }
        return result;
    }

    unittest { // computeEdgeSharpness: cube — every one of the 12 edges is a
               // 90° dihedral, all interior, all sharp at a 30° threshold.
        Mesh m = makeCube();
        auto sharp = m.computeEdgeSharpness(30.0f);
        assert(sharp.length == m.edges.length);
        assert(sharp.length == 12);
        foreach (i, ref s; sharp) {
            assert(s.interior, "cube edge should have two adjacent faces");
            assert(s.sharp, "cube edge should be sharp at 30deg threshold");
            assert(s.angleDeg > 85.0f && s.angleDeg < 95.0f,
                   "cube dihedral should be ~90deg");
        }
        // A very permissive threshold makes every edge fall below it.
        auto notSharp = m.computeEdgeSharpness(120.0f);
        foreach (ref s; notSharp) assert(!s.sharp);
    }

    // Per-corner inset helper: given the origPos ring and corner index i,
    // return the inset position using the perpendicular-offset meeting
    // formula (offsetMeet from math.d). ePrev/eNext are unit directions from
    // origPos[i] toward the previous and next corners respectively.
    private Vec3 insetCorner(const Vec3[] origPos, int i, Vec3 n, float inset) {
        const int  N     = cast(int)origPos.length;
        const int  prevI = (i + N - 1) % N;
        const int  nextI = (i + 1)     % N;
        const Vec3 ePrev = safeNormalize(origPos[prevI] - origPos[i]);
        const Vec3 eNext = safeNormalize(origPos[nextI] - origPos[i]);
        return offsetMeet(origPos[i], ePrev, eNext, n, inset, inset);
    }

    // Per-corner constant-distance-toward-centroid helper for
    // insetFacesByMask (poly.inset). Deliberately SEPARATE from insetCorner/
    // offsetMeet above (used by bevelFacesByMask / poly.bevel's per-edge
    // perpendicular-offset miter law) — task 0359's toolcard capture showed
    // poly.inset uses a DIFFERENT per-vertex law (a constant absolute
    // displacement toward the polygon centroid, NOT a per-edge miter
    // offset), so sharing insetCorner would have silently changed
    // poly.bevel's already-verified geometry.
    //
    // Reference-captured law (toolcard `behavior.per_vertex_law` /
    // `sign_law`): each new boundary vertex sits at `orig` moved toward the
    // polygon centroid by an ABSOLUTE distance of exactly `inset` world
    // units. Positive inset shrinks (toward centroid); negative grows
    // (moves away — the duplicate scales larger), which falls out of this
    // formula automatically via the signed `inset` multiply.
    //
    // OPEN AMBIGUITY (documented in the toolcard, not resolved by capture):
    // the only parity case captured is a perfect square, where "move by a
    // constant absolute distance" and "scale proportionally toward the
    // centroid" are numerically indistinguishable (every corner starts
    // equidistant from the centroid). This implementation picks the
    // constant-distance law per the captured wording; unverified on a
    // non-regular (asymmetric) selected polygon.
    private Vec3 insetCornerCentroid(Vec3 orig, Vec3 centroid, float inset) {
        Vec3 toCenter = centroid - orig;
        const float len = toCenter.length;
        if (len < 1e-9f) return orig;   // corner already at the centroid — no direction to move
        return orig + (toCenter / len) * inset;
    }

    /// Per-face polygon inset: for each face flagged true in `mask`, move
    /// each corner toward the polygon centroid by an absolute distance of
    /// `inset` world units (see insetCornerCentroid) and bridge the original
    /// boundary to the new inner boundary with N ring quads. The original
    /// face slot is replaced by the inner face so its selection mark is
    /// preserved.
    ///
    /// `inset == 0` is NOT a no-op (reference-matched, task 0359): it still
    /// performs the full topology split, landing the new corners exactly on
    /// the original ones (a degenerate zero-width ring) — the reference tool
    /// does not skip the split at its default value either.
    ///
    /// Returns the number of faces processed (0 only when `mask` selects no
    /// face, e.g. an empty/undersized mask).
    size_t insetFacesByMask(const bool[] mask, float inset) {
        size_t processed = 0;
        const size_t nFaces = faces.length; // snapshot before appending ring quads
        foreach (fi; 0 .. nFaces) {
            if (fi >= mask.length || !mask[fi]) continue;
            const uint[] origFaceVerts = faces[fi].dup;
            const int    N             = cast(int)origFaceVerts.length;
            if (N < 3) continue;
            // Build per-corner position slice.
            Vec3[] origPos = new Vec3[](N);
            foreach (i; 0 .. N) origPos[i] = vertices[origFaceVerts[i]];
            // Polygon centroid (plain average of corners — matches the
            // reference's "toward the centroid" wording; N-gon area-weighted
            // centroids are not what was captured).
            Vec3 centroid = Vec3(0, 0, 0);
            foreach (p; origPos) centroid = centroid + p;
            centroid = centroid * (1.0f / cast(float)N);
            // Add one inset vertex per corner.
            uint[] newVerts = new uint[](N);
            foreach (i; 0 .. N)
                newVerts[i] = addVertex(insetCornerCentroid(origPos[i], centroid, inset));
            // Replace the original face with the inner (inset) face.
            // The face slot index is unchanged, so faceMarks[fi] (select mark
            // AND subpatch mark) carries over to the inner face automatically.
            faces[fi] = newVerts.dup;
            // Task 0389: read the source face's Subpatch bit BEFORE the ring
            // quads below grow `faceMarks` (addFace does not grow it itself —
            // `fi`'s own bit is unaffected by the in-place replace above).
            immutable bool srcSub  = isFaceSubpatch(fi);
            immutable size_t ringStart = faces.length;
            // Emit N ring quads bridging original boundary to inner boundary.
            foreach (i; 0 .. N) {
                const int next = (i + 1) % N;
                addFace([origFaceVerts[i], origFaceVerts[next],
                         newVerts[next],   newVerts[i]]);
            }
            // Ring quads inherit Subpatch from the inset source face.
            resizeSubpatch();
            foreach (rfi; ringStart .. faces.length) setFaceSubpatch(rfi, srcSub);
            ++processed;
        }
        if (processed == 0) return 0;
        rebuildEdges();
        buildLoops();
        syncSelection();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }

    // Per-face safe upper bound for a uniform (all-corners-equal-inset)
    // polygon inset. Mirrors the "does NOT overshoot and self-intersect"
    // guard the edge-extrude face-aware inset already applies (mesh.d
    // ~2520), generalized from "clamp to the far vertex of an edge" to
    // "clamp to the point where a ring edge would collapse to zero
    // length": `probe[i]` is each corner's per-unit-inset offset direction
    // (`insetCorner(...,1)` — offsetMeet is affine in its width args, so
    // the offset at any `inset` is `origPos[i] + probe[i]*inset` exactly).
    // Ring edge (i, i+1)'s length is therefore an affine function of
    // `inset` that reaches zero at
    //     t = edgeLen / -dot(probe[next] - probe[i], edgeDir)
    // The smallest positive such `t` across all ring edges is the largest
    // inset that keeps every edge non-negative-length; beyond it the ring
    // folds back on itself (self-intersects, corners overshoot past their
    // neighbours). Returns +infinity when no edge would ever collapse.
    private float maxSafeUniformInset(const Vec3[] origPos, const Vec3[] probe) {
        const int N = cast(int)origPos.length;
        float safe = float.infinity;
        foreach (i; 0 .. N) {
            const int next = (i + 1) % N;
            Vec3 edge = origPos[next] - origPos[i];
            const float edgeLen = edge.length;
            if (edgeLen < 1e-9f) continue;
            Vec3 edgeDir = edge / edgeLen;
            Vec3 p = probe[next] - probe[i];
            const float denom = -dot(p, edgeDir);
            if (denom > 1e-9f) {
                const float t = edgeLen / denom;
                if (t < safe) safe = t;
            }
        }
        return safe;
    }

    /// Polygon bevel: for each selected face, inset each corner by `inset`
    /// AND displace the inset cap by `+faceNormal*shift` along the face normal,
    /// bridging the original boundary to the offset cap with N ring quads.
    /// Produces ONE slanted ring (not inset∘extrude, which would produce two rings).
    /// inset=0, shift>0 degenerates to a one-ring face-extrude along the normal.
    /// Returns 0 (no-op) when |inset|<1e-6 AND |shift|<1e-6.
    ///
    /// Overshoot guard: a positive `inset` is clamped per-face to
    /// `maxSafeUniformInset` so the offset ring cannot fold past itself
    /// (mirrors the edge-extrude face-aware inset clamp, ~2520 — "the
    /// reference bumps the inset ... and stops"). Clamping can still land
    /// several corners on (or very near) the same position — e.g. a square
    /// face clamped to its inradius collapses every corner onto the
    /// centroid, an elongated face collapses pairwise onto a line — so a
    /// clamped pass finishes with `weldCoincidentVertices`, which merges
    /// the coincident corners and drops any face that falls below 3
    /// distinct vertices (the fully-collapsed cap), leaving the ring
    /// quads as valid triangles instead of coincident-vertex / zero-area
    /// geometry. (Overshoot clamping is NOT applied to `group`'s shared
    /// corners below — untested combination, documented gap.)
    ///
    /// `group` (task 0391 Phase 4, `capture-verified` default TRUE at the
    /// command/tool layer — see `commands/mesh/bevel.d`): when true and ≥2
    /// selected faces are mutually adjacent, their SHARED corners collapse
    /// to ONE new vertex instead of each face computing its own independent
    /// corner there, and the ring quad for any EDGE shared by 2 selected
    /// faces ("internal") is suppressed entirely (no bridge — it dissolves
    /// into the merged interior). Two corner laws, both `capture-verified`
    /// against `poly_bevel_corner.json`'s 3-face cube-corner case:
    ///   - a vertex with EXACTLY 1 internal edge touching it ("half-shared",
    ///     on the group's own outer boundary but shared by the 2 faces
    ///     either side of that internal edge): `orig + Σ(shift·faceNormal
    ///     over every selected face incident to it) + inset·dir(orig → the
    ///     internal edge's other endpoint)`.
    ///   - a vertex with EVERY incident edge internal (fully enclosed by
    ///     the group, no boundary edge left — the group's own analog of
    ///     edge-bevel's N-way junction hub): `orig + Σ(shift·faceNormal)`,
    ///     no inset term (there is no boundary edge left to inset against).
    ///   - a vertex with 0 internal edges (standalone) uses today's
    ///     unshared per-face formula unchanged.
    ///   - a vertex with ≥2 internal edges AND ≥1 remaining boundary edge
    ///     (a partial, "some but not all" enclosure) is NOT fixture-tested;
    ///     falls back to the standalone per-face formula (documented gap,
    ///     not silent — a cube's faces never exercise this shape).
    /// `group=false` (default) is byte-identical to the pre-0391 kernel.
    ///
    /// `segments` (task 0391 Phase 5, `capture-verified` LINEAR staircase —
    /// `vibe3d-divergence` from edge.bevel's Round Level, which is a TRUE
    /// circular arc, see `bevelEdgesByMask`'s own doc comment): `N ≥ 1`
    /// interpolates `N` EQUAL linear steps from the original boundary to
    /// the final (inset+shift, or group-shared) corner, emitting `N` ring
    /// quads per boundary edge instead of 1 (`N-1` new intermediate rings).
    /// `segments<=1` (the default 0, or 1) is byte-identical to the flat
    /// single-ring result above. Intermediate (non-endpoint) ring vertices
    /// are computed PER-FACE even under `group` (only the t=0 original and
    /// t=N final corners are shared) — the captured segments law is
    /// verified only on single-face selections, where grouping is moot.
    /// KNOWN-UNTESTED: `group=true && segments>1` together (the combined
    /// code path compiles and each half is independently verified, but no
    /// fixture/unittest exercises the combination) — a cube face selection
    /// large enough to test both simultaneously wasn't captured.
    ///
    /// Two-layer DoS clamp: `segments` is hard-capped to
    /// `MAX_BEVEL_SEGMENTS` HERE (kernel-side, authoritative for any
    /// caller) since it scales ring-quad allocation linearly per selected
    /// face; the command/tool Param's `.min(0).max(MAX_BEVEL_SEGMENTS)
    /// .enforceBounds()` hint is a shallower UI/HTTP-only second line of
    /// defense.
    size_t bevelFacesByMask(const bool[] mask, float inset, float shift,
                             bool group = false, int segments = 0) {
        import std.math : abs;
        if (abs(inset) < 1e-6f && abs(shift) < 1e-6f) return 0;

        int segN = segments;
        if (segN < 0) segN = 0;
        if (segN > MAX_BEVEL_SEGMENTS) segN = MAX_BEVEL_SEGMENTS;
        immutable int Nseg = (segN < 1) ? 1 : segN; // segs=0 == segs=1 == flat

        size_t processed = 0;
        bool anyClamped = false;
        const size_t nFaces = faces.length;

        // --- group=true pre-pass: classify edges internal/boundary and
        // pre-compute each shared-corner vertex's target position. ---
        bool[ulong] internalEdgeSet;  // edgeKeyOrdered → true(internal)/false(boundary), only for edges bordering >=1 selected face
        Vec3[uint]  sharedCornerPos;  // orig vertex idx → shared new position (half-shared or apex)
        if (group) {
            auto edgeFacesMap = buildEdgeFaces();
            foreach (fi; 0 .. nFaces) {
                if (fi >= mask.length || !mask[fi]) continue;
                auto f = faces[fi];
                immutable int Nf = cast(int)f.length;
                foreach (k; 0 .. Nf) {
                    uint a = f[k], b = f[(k + 1) % Nf];
                    immutable ulong key = edgeKeyOrdered(a, b);
                    if (key in internalEdgeSet) continue;
                    auto fp = key in edgeFacesMap;
                    bool internal = false;
                    if (fp !is null && (*fp)[0] >= 0 && (*fp)[1] >= 0) {
                        immutable uint fa = cast(uint)(*fp)[0], fb = cast(uint)(*fp)[1];
                        internal = (fa < mask.length && mask[fa]) && (fb < mask.length && mask[fb]);
                    }
                    internalEdgeSet[key] = internal;
                }
            }

            // Per-vertex shift accumulator: once per (vertex, selected face
            // it corners) pair, regardless of how many of its edges are
            // internal — used only for vertices that end up shared.
            Vec3[uint] shiftSum;
            foreach (fi; 0 .. nFaces) {
                if (fi >= mask.length || !mask[fi]) continue;
                immutable Vec3 fn = faceNormal(cast(uint)fi);
                foreach (v; faces[fi]) {
                    if (auto p = v in shiftSum) *p = *p + fn * shift;
                    else shiftSum[v] = fn * shift;
                }
            }

            foreach (v, sSum; shiftSum) {
                uint internalCnt = 0, lastInternalOther = uint.max;
                bool anyBoundary = false;
                foreach (ei; edgesAroundVertex(v)) {
                    immutable uint w = edgeOtherVertex(ei, v);
                    immutable ulong key = edgeKeyOrdered(v, w);
                    auto ip = key in internalEdgeSet;
                    if (ip is null) continue; // doesn't border any selected face — irrelevant
                    if (*ip) { ++internalCnt; lastInternalOther = w; }
                    else     { anyBoundary = true; }
                }
                if (internalCnt == 0) continue; // standalone — default formula below
                if (internalCnt == 1) {
                    sharedCornerPos[v] = vertices[v] + sSum +
                        safeNormalize(vertices[lastInternalOther] - vertices[v]) * inset;
                } else if (!anyBoundary) {
                    sharedCornerPos[v] = vertices[v] + sSum; // fully-enclosed apex, no inset term
                }
                // else: partial (>=2 internal, boundary remains) — deferred, falls through.
            }
        }
        uint[uint] sharedVertIdx; // orig vertex idx → already-created shared mesh vertex (memoized once)

        foreach (fi; 0 .. nFaces) {
            if (fi >= mask.length || !mask[fi]) continue;
            const uint[] origFaceVerts = faces[fi].dup;
            const int    Nc            = cast(int)origFaceVerts.length;
            if (Nc < 3) continue;
            Vec3[] origPos = new Vec3[](Nc);
            foreach (i; 0 .. Nc) origPos[i] = vertices[origFaceVerts[i]];
            const Vec3 n = faceNormal(cast(uint)fi);

            float effInset = inset;
            if (inset > 0) {
                Vec3[] probe = new Vec3[](Nc);
                foreach (i; 0 .. Nc) probe[i] = insetCorner(origPos, i, n, 1.0f) - origPos[i];
                const float capT = maxSafeUniformInset(origPos, probe);
                // Landing AT the cap exactly (inset == capT) already collapses a
                // ring edge to zero length (its two corners coincide) — trigger
                // the weld cleanup below even when effInset doesn't need to move.
                if (capT <= effInset) { effInset = capT; anyClamped = true; }
            }

            // Final (t=Nseg) corner per index — group-aware: a shared
            // corner is created ONCE and reused across every face it touches.
            uint[] finalVerts = new uint[](Nc);
            Vec3[] finalPos   = new Vec3[](Nc);
            foreach (i; 0 .. Nc) {
                immutable uint origV = origFaceVerts[i];
                auto shP = group ? (origV in sharedCornerPos) : null;
                if (shP !is null) {
                    finalPos[i] = *shP;
                    if (auto p = origV in sharedVertIdx) finalVerts[i] = *p;
                    else {
                        immutable uint nv = addVertex(finalPos[i]);
                        sharedVertIdx[origV] = nv;
                        finalVerts[i] = nv;
                    }
                } else {
                    finalPos[i]  = insetCorner(origPos, i, n, effInset) + n * shift;
                    finalVerts[i] = addVertex(finalPos[i]);
                }
            }

            // Intermediate segment rings: t=0 is the original boundary,
            // t=Nseg is finalVerts; t=1..Nseg-1 are new equal-lerp rings
            // (computed per-face even for a shared corner — see doc comment).
            uint[][] ringVerts = new uint[][](Nseg + 1);
            ringVerts[0]    = origFaceVerts.dup;
            ringVerts[Nseg] = finalVerts;
            foreach (t; 1 .. Nseg) {
                uint[] ring = new uint[](Nc);
                immutable float f = cast(float)t / cast(float)Nseg;
                foreach (i; 0 .. Nc)
                    ring[i] = addVertex(origPos[i] + (finalPos[i] - origPos[i]) * f);
                ringVerts[t] = ring;
            }

            faces[fi] = finalVerts.dup;
            // Task 0389: read the source face's Subpatch bit BEFORE the ring
            // quads below grow `faceMarks` (addFace does not grow it itself —
            // `fi`'s own bit is unaffected by the in-place replace above).
            immutable bool srcSub  = isFaceSubpatch(fi);
            immutable size_t ringStart = faces.length;
            foreach (i; 0 .. Nc) {
                const int next = (i + 1) % Nc;
                if (group) {
                    immutable ulong key = edgeKeyOrdered(origFaceVerts[i], origFaceVerts[next]);
                    if (internalEdgeSet.get(key, false)) continue; // internal — dissolves, no bridge
                }
                foreach (t; 0 .. Nseg)
                    addFace([ringVerts[t][i],     ringVerts[t][next],
                             ringVerts[t+1][next], ringVerts[t+1][i]]);
            }
            // Ring quads inherit Subpatch from the beveled source face.
            resizeSubpatch();
            foreach (rfi; ringStart .. faces.length) setFaceSubpatch(rfi, srcSub);
            ++processed;
        }
        if (processed == 0) return 0;
        if (anyClamped) {
            // weldCoincidentVertices only remaps FACE references to the kept
            // vertex — the welded-away vertex slots (e.g. 3 of 4 cap corners
            // that all clamped onto the same centroid) stay in `vertices[]`
            // as now-unreferenced orphans unless compacted away here too.
            weldCoincidentVertices(1e-10);
        }
        if (anyClamped || group) {
            // group's fully-enclosed apex vertices (every incident edge
            // internal) are never referenced by any surviving face or ring
            // quad once every incident face's corner has moved to the
            // shared apex — compact them away.
            compactUnreferenced();
        }
        rebuildEdges();
        buildLoops();
        syncSelection();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }

    /// Per-face spikey: for each face flagged true in `mask`, add a new apex
    /// vertex at the face centroid displaced along the face normal, then replace
    /// the face with a triangle fan to that apex (one tri per original edge).
    ///
    /// Displacement formula (D1-B, SDK-faithful): `disp = amount * (perimeter/N)`
    /// where perimeter = sum of edge lengths and N = vertex count. On a unit-edge
    /// face (N=4, perimeter=4) `disp == amount`. `amount == 0` is NOT a no-op —
    /// it produces an in-place fan-triangulate (apex at centroid, zero offset).
    ///
    /// The original face slot `fi` is replaced in-place with the first fan tri
    /// `[v0, v1, apex]`, preserving `faceMarks[fi]` (select + subpatch flag) and
    /// `faceMaterial[fi]`. The remaining N-1 fan tris are appended via `addFace`
    /// with the parent face's material and subpatch flag carried over. All
    /// appended fan tris are also selected (D3: select whole spike).
    ///
    /// Returns the number of faces processed (> 0 on success; 0 means nothing in
    /// `mask` had ≥ 3 verts — caller should discard snapshot).
    size_t spikeFacesByMask(const bool[] mask, float amount) {
        size_t processed = 0;
        const size_t nFaces = faces.length; // snapshot before appending fan tris

        // Parallel lists: for each appended fan tri, record its face index
        // (captured at addFace time = faces.length-1) and its source face fi.
        uint[] appendedFi;
        uint[] fanSrc;

        foreach (fi; 0 .. nFaces) {
            if (fi >= mask.length || !mask[fi]) continue;
            const uint[] origFaceVerts = faces[fi].dup;
            const int    N             = cast(int)origFaceVerts.length;
            if (N < 3) continue;

            // Compute centroid and normal BEFORE mutating faces[fi].
            const Vec3 c = faceCentroid(cast(uint)fi);
            const Vec3 n = faceNormal(cast(uint)fi);

            // Perimeter = sum of edge lengths around the face ring.
            float perimeter = 0f;
            foreach (i; 0 .. N) {
                Vec3  a  = vertices[origFaceVerts[i]];
                Vec3  b  = vertices[origFaceVerts[(i + 1) % N]];
                float dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z;
                perimeter += sqrt(dx*dx + dy*dy + dz*dz);
            }

            // D1-B: displacement = amount * average edge length.
            float disp = amount * (perimeter / cast(float)N);
            uint apex = addVertex(c + n * disp);

            // In-place replace: first fan tri [v0, v1, apex] stays in slot fi,
            // automatically preserving faceMarks[fi] (Select + Subpatch bits)
            // and faceMaterial[fi].
            faces[fi] = [origFaceVerts[0], origFaceVerts[1], apex];

            // Append the remaining N-1 fan tris [vi, vi+1, apex] for i=1..N-1.
            foreach (i; 1 .. N) {
                uint newFi = cast(uint)faces.length; // capture BEFORE addFace grows
                addFace([origFaceVerts[i], origFaceVerts[(i + 1) % N], apex]);
                appendedFi ~= newFi;
                fanSrc     ~= cast(uint)fi;
            }

            ++processed;
        }

        if (processed == 0) return 0;

        // Attribute carry-over for appended fan tris.
        // addFace grows PolyVertex maps but NOT faceMaterial/facePart/faceMarks.
        // Save original array lengths for the source-read guard, then
        // grow all arrays (D zero-fills new slots).
        const size_t origMatLen  = faceMaterial.length;
        const size_t origPartLen = facePart.length;
        resizeSubpatch();               // grows faceMarks to faces.length
        faceMaterial.length = faces.length;
        facePart.length     = faces.length;
        foreach (k; 0 .. appendedFi.length) {
            const uint newFi = appendedFi[k];
            const uint srcFi  = fanSrc[k];
            faceMaterial[newFi] = (srcFi < origMatLen  ? faceMaterial[srcFi] : 0u);
            facePart[newFi]     = (srcFi < origPartLen ? facePart[srcFi]     : 0u);
            setFaceSubpatch(newFi, isFaceSubpatch(srcFi));
        }

        // Tail — correct order: syncSelection BEFORE selectFace so that
        // faceSelectionOrder (grown by syncSelection) is in bounds for appended
        // indices. buildLoops also calls resizePolyVertexMaps which zeroes UV maps
        // when the arity change produces a length mismatch (per-corner UV carry is
        // out of scope for v1, consistent with inset/bevel).
        rebuildEdges();
        buildLoops();
        syncSelection();  // grows faceSelectionOrder et al. to faces.length

        // D3: select all appended fan tris (slot fi stays selected via in-place).
        foreach (newFi; appendedFi) selectFace(cast(int)newFi);

        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }

    /// Edge bevel (Candidate A — slide-along-adjacent-edge, generalized).
    ///
    /// Replaces every qualifying selected edge with a chamfer strip (a flat
    /// quad at `roundLevel==0`, or `2^roundLevel` rings at `roundLevel>0`.
    /// The isolated K1 SLIDE profile and the K2 shared-vertex miter rails are
    /// both capture-verified (bit-exact convex round-over / hub arc); a K3+
    /// junction's per-pair rails use the same verified law, but its central
    /// hub vertex + fan topology is an unresolved reference gap). Unlike the v1
    /// kernel, selected edges may share endpoints: the per-VERTEX cap
    /// topology (bare end / loop-turn miter / N-way junction hub-fill) is
    /// derived generically from the half-edge ring around each touched
    /// vertex, not hardcoded per case. See doc/bevel_full_plan.md Phases 1-3
    /// and the private algorithm-grounding reference distilled there
    /// (clean-room design, NOT ported GPL code — see the bevel clean-room
    /// rewrite history for provenance).
    ///
    /// **Algorithm** (per affected vertex V, walking `facesAroundVertex(V)` /
    /// `edgesAroundVertex(V)` in their proven-lockstep half-edge ring order —
    /// face `f_k` borders edge `e_k` (V's SUCCESSOR side within `f_k`) and
    /// edge `e_(k+1)` (V's PREDECESSOR side within `f_k`)):
    ///   - `f_k` bordered by 2 SELECTED edges → MITER: one new vertex via
    ///     `offsetMeet` (both-bevel meet, matches `insetCorner`'s convention).
    ///     If ALL of V's edges are selected (K == valence), the per-face
    ///     miters trace a closed K-gon boundary (each selected edge's own
    ///     chamfer quad already threads a rail between 2 consecutive miters)
    ///     that needs exactly ONE new cap face to fill — the "hub" cap.
    ///   - `f_k` bordered by exactly 1 selected edge → SLIDE: one new vertex
    ///     = V + width·dir(the OTHER, unselected edge) — identical formula
    ///     to the original v1 kernel's per-endpoint corner, so a lone
    ///     selected edge (K==1 at both ends) reproduces v1's output exactly.
    ///   - `f_k` bordered by 2 UNSELECTED edges: if BOTH are "active" (each
    ///     itself borders a selected edge via its OTHER incident face) →
    ///     SPLIT into the 2 already-computed slide vertices (the classic
    ///     bare-end pentagon); if exactly one is active → SPLIT into
    ///     [that slide vertex, V] (V retained on the inactive side — a
    ///     partial notch, not fixture-tested but topologically sound for
    ///     valence > 3); if neither is active → untouched.
    /// A selected edge's own chamfer strip always bridges the per-(vertex,
    /// face) corner already resolved above for its 2 bordering faces at
    /// each endpoint — so the strip is well-defined for EVERY case (bare
    /// end, loop turn, junction) without per-case branching at the edge
    /// level.
    ///
    /// v1's guards this generalizes away (task 0391 Phase 1/2): the blanket
    /// endpoint-disjoint guard and the valence-3-both-endpoints guard are
    /// GONE — a vertex may have any number of selected edges (K) at any
    /// valence. STILL required: each selected edge must be interior
    /// (exactly 2 incident faces) — boundary edges are silently skipped
    /// (open-boundary bevel is task 0391 Phase 6, deferred/XFAIL).
    ///
    /// `roundLevel` subdivides every eligible cross-section into `2^L`
    /// segments.  A rail is owned by its two already-resolved L0 endpoint
    /// vertices, not by an individual strip: the same interior indices are
    /// threaded through both of its consumers (support face, neighbouring
    /// strip, or hub cap).  ALL rails — clean slide, bare-end, and miter —
    /// use the ONE reference-captured law documented beside `railInterior`:
    /// a TRUE circular fillet tangent to the two adjacent faces, whose radius
    /// (`width·tan(φ/2)`) AND sweep (`180°−φ`) are set by the ACTUAL dihedral φ
    /// — reconstructed from the reference's two-tangent-line-intersection +
    /// angular-SLERP builders, verified bit-exact across dihedrals 45°–150° and
    /// on the 90° cube (K1 / bare end / K2 miter).  The 90° cube is a special
    /// case (a coincidental quarter-turn about `E_A+E_B−V`), not the whole law.
    /// A 3-way junction reproduces the reference's rounded corner bit-exact at
    /// EVERY Round Level: one general L×L rational-Gregory ring (Gregory 1974 /
    /// Chiyokura–Kimura) per sub-quad — HUB + R→HUB spoke points + rational
    /// interior points — whose u=0/v=0 boundary reuses the true-arc pairwise
    /// rail interiors. The pairwise arcs are geodesics on the corner-rounding
    /// sphere (centre `V−width·Σn̂`, not the per-vertex fillet — that degenerates
    /// for near-antipodal hub poles), and the whole junction (rails + ring) is
    /// subdivided into `2·roundLevel` equal-angle segments (the isolated K1
    /// convention is the same law; `2·L` only equals `2^L` at L≤2, which is why
    /// the old `1<<roundLevel` matched there but over-subdivided at L≥3). Still
    /// open (XFAIL): N>3 junctions (a different reference N-sided path) keep the
    /// flat N-gon cap.  `roundLevel==0` takes the old flat path without a
    /// registry.
    ///
    /// Two-layer DoS clamp (`doc/param_bounds_plan.md` convention):
    /// `roundLevel` is hard-capped to `MAX_ROUND_LEVEL` HERE (kernel-side,
    /// authoritative for any caller including a direct/scripted one) since
    /// it scales allocation exponentially (`2^L` quad rings per rounded
    /// endpoint); the command/tool Param's `.min(0).max(MAX_ROUND_LEVEL)
    /// .enforceBounds()` hint is a shallower, UI/HTTP-only second line of
    /// defense.
    ///
    /// Returns the count of edges actually processed (0 ⇒ no-op, all skipped).
    size_t bevelEdgesByMask(const bool[] mask, float width, int roundLevel = 0) {
        if (width < 1e-6f) return 0;
        if (mask.length != edges.length) return 0;

        if (roundLevel < 0) roundLevel = 0;
        if (roundLevel > MAX_ROUND_LEVEL) roundLevel = MAX_ROUND_LEVEL;

        // A "return 0 ⇒ no-op" contract callers rely on (they discard their
        // pre-op snapshot on failure WITHOUT restoring it into the mesh —
        // see commands/mesh/bevel.d's evaluate()). The per-vertex corner
        // pass below can call addVertex for a vertex whose chamfer span is
        // later discarded (e.g. a boundary-adjacent asymmetric endpoint,
        // see the regression unittest above) — truncate back to this
        // snapshot on every post-corner-pass 0-return so a "no-op" never
        // leaks orphaned vertices into the mesh.
        immutable size_t savedVertCount = vertices.length;

        // Edge→(≤2 faces) adjacency, one pass (same idiom as extrudeEdgesByMask).
        auto edgeFaces = buildEdgeFaces();

        // Step 1: qualifying selected edges. An edge with TWO incident faces
        // gets the ordinary chamfer (two rails plus a bridge quad between
        // them). An edge with exactly ONE incident face is a RIM edge, and
        // the reference bevels it too — but differently: the lone face's
        // border simply insets by `width` and NO bridge quad is created
        // (reference captures `edge_bevel_open_{rimedge,bothends}_w015`; the
        // cap rule is "+1 bridge quad iff 2 incident faces, 0 new faces iff
        // 1", orthogonal to whether the endpoints are on a rim). Both kinds
        // count as "selected" for the per-vertex fan logic below; only the
        // 2-face kind becomes a ChamferSpan.
        bool[] qualifies = new bool[](edges.length);
        bool[] rimOnly   = new bool[](edges.length);
        size_t nQual = 0;
        foreach (i; 0 .. edges.length) {
            if (!mask[i]) continue;
            uint v0 = edges[i][0], v1 = edges[i][1];
            auto fp = edgeKeyOrdered(v0, v1) in edgeFaces;
            if (fp is null) continue;
            if ((*fp)[0] < 0) continue;          // no incident face at all
            qualifies[i] = true;
            rimOnly[i]   = ((*fp)[1] < 0);       // exactly one incident face
            ++nQual;
        }
        if (nQual == 0) return 0;

        // Step 2: affected vertices = endpoints of any qualifying edge.
        bool[] affected = new bool[](vertices.length);
        foreach (i; 0 .. edges.length) {
            if (!qualifies[i]) continue;
            affected[edges[i][0]] = true;
            affected[edges[i][1]] = true;
        }

        // Safety preflight. Two supported fan shapes reach the per-vertex pass
        // below: CLOSED (interior vertex, nE == d) and OPEN (boundary vertex,
        // nE == d + 1 — `VertexEdgeRange` anchors at the open start of the fan
        // and emits one extra rim edge). In both, face f_k is bordered by edge
        // slots k and k+1; only the closed fan wraps.
        foreach (V; 0 .. cast(uint)vertices.length) {
            if (V >= affected.length || !affected[V]) continue;
            size_t d = 0;
            foreach (fi; facesAroundVertex(V)) ++d;
            bool[] fanSelected;
            foreach (ei; edgesAroundVertex(V))
                fanSelected ~= (ei < qualifies.length && qualifies[ei]);
            immutable bool openFan = (fanSelected.length == d + 1);
            // Malformed fan stays on the existing per-span silent-skip path
            // below; the tests here need a well-formed closed or open fan.
            if (!openFan && fanSelected.length != d) continue;
            size_t K = 0;
            foreach (s; fanSelected) if (s) ++K;
            if (K == 0 || (!openFan && K == d)) continue; // untouched, or a full hub

            // The ROUNDED profile at a rim vertex — where the arc terminates
            // against the open edge rather than against another chamfer — has
            // no reference capture yet. The L0 chamfer there IS supported (see
            // the open-fan walk in the per-vertex pass). Refuse rather than
            // ship a guessed boundary arc: that exact shortcut is one this
            // task already had to walk back once.
            if (openFan && roundLevel > 0) return 0;

            // The one unsupported shape is the partial-notch `keep V` branch
            // below: a face whose BOTH bordering edges are unselected but only
            // ONE side is active. It retains V with no free-end cap and leaves
            // a hole, at EVERY Round Level including L0. Its sibling — BOTH
            // sides active — fully cuts the corner and is fine (it is exactly
            // what the reference does at a beveled rim edge).
            //
            // So mirror the `active` relation used by the per-vertex pass and
            // reject only on the single-active case. Slots are fan-adjacent
            // when they bound a common face (cyclic closed / linear open),
            // plus the open fan's two rim ends, which the boundary joins.
            immutable size_t nSlots = fanSelected.length;
            bool[] fanActive = new bool[](nSlots);
            foreach (k; 0 .. nSlots) {
                if (fanSelected[k]) continue;
                if (openFan) {
                    fanActive[k] = (k > 0 && fanSelected[k - 1]) ||
                                   (k + 1 < nSlots && fanSelected[k + 1]);
                    if (!fanActive[k] && (k == 0 || k == nSlots - 1))
                        fanActive[k] = fanSelected[k == 0 ? nSlots - 1 : 0];
                } else {
                    fanActive[k] = fanSelected[(k + nSlots - 1) % nSlots] ||
                                   fanSelected[(k + 1) % nSlots];
                }
            }
            foreach (k; 0 .. d) {
                immutable size_t kr = (k + 1) % nSlots;
                if (fanSelected[k] || fanSelected[kr]) continue;
                if (fanActive[k] != fanActive[kr]) return 0;   // the `keep V` notch
            }
        }

        // Overshoot guard (mirrors the edge-extrude face-aware inset clamp,
        // mesh.d ~2520 — "the reference bumps the inset into the far vertex
        // and stops... does NOT overshoot and self-intersect"): a SLIDE
        // corner cannot travel past the far end of its non-bevel neighbor
        // edge, so `width` is capped per-direction to that edge's own
        // length. Landing exactly on the far vertex makes the new corner
        // coincide with an EXISTING mesh vertex — `anyClamped` gates a
        // `weldCoincidentVertices` pass after the topology rebuild below.
        bool anyClamped = false;
        float clampedWidth(uint from, uint to) {
            const float farLen = (vertices[to] - vertices[from]).length;
            if (farLen > 1e-9f && width >= farLen) { anyClamped = true; return farLen; }
            return width;
        }

        pragma(inline, true) static ulong vfKey(uint v, uint f) {
            return (cast(ulong)v << 32) | cast(ulong)f;
        }

        // Per-(vertex,face) corner resolution.  Keep the construction
        // provenance with the L0 vertex: round-profile selection must not
        // rediscover it from a floating-point radius heuristic.
        enum CornerKind : ubyte { Slide, Miter }
        struct CornerInfo {
            uint vert;
            CornerKind kind;
            bool clamped;
            uint selectedDegree; // K at this source vertex, before rebuilding
            Vec3 dir;
        }
        CornerInfo[ulong] cornerAtVF;

        // face_index → (old_vert → new_verts[]), same substitution-table
        // idiom as bevelVerticesByMask / extrudeFacesByMask. A face can now
        // legitimately receive substitution entries for MULTIPLE distinct
        // vertices (e.g. a loop's shared "inside" face gets one per corner).
        struct VertSub { uint oldV; uint[] newVs; }
        VertSub[][uint] faceSubs;

        // Full-ring ("hub cap") bookkeeping: vertex → ordered miter-corner
        // ring (only populated when K == valence, i.e. every incident edge
        // of V is selected — Phase 2's N-way junction).
        uint[][uint] hubCapRing;
        uint[uint]   hubCapSrc;

        // Round Level rail registry.  Identity is the unordered pair of L0
        // endpoints; callers receive the stored chain in their own winding.
        // A RailSpec still records its corner-construction class (below), but
        // that is now used only for the shared-endpoint provenance assert in
        // `registerRail` — NOT to pick a profile: every rail materializes
        // through the ONE reference-captured law in `railInterior` (K1 / bare
        // end / K2 miter all verified bit-exact; a K3+ junction's central hub
        // vertex + fan remains the sole unresolved reference gap).
        enum RailProfile : ubyte { VerifiedK1Arc, LocalAnalyticUnverified }
        struct RailSpec {
            uint a, b; // canonical a < b
            Vec3 center;
            CornerKind aKind, bKind;
            bool aClamped, bClamped;
            uint aSelectedDegree, bSelectedDegree;
            RailProfile profile;
            uint supportConsumers;
            uint stripConsumers;
            bool approved;
            Vec3 arcCenter;      // explicit fillet centre for a junction rail
            bool hasArcCenter;   // ↑ valid (else use the per-vertex fillet centre)
        }
        RailSpec[ulong] railSpecs;
        uint[][ulong] railInteriorMemo; // canonical pairKey(a,b), a<b → interiors in a→b order
        static ulong pairKey(uint a, uint b) {
            return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
        }
        void registerRail(CornerInfo left, CornerInfo right, Vec3 center, uint centerVert) {
            immutable ulong key = pairKey(left.vert, right.vert);
            immutable bool forward = left.vert < right.vert;
            // Junction pairwise rail (both corners MITER at a K==valence
            // junction, selectedDegree≥3): the boundary arc between two hub
            // poles is NOT the per-vertex fillet — that degenerates (the two
            // poles are ~antipodal about the fillet centre, so Ω→180° collapses
            // to a straight chord, e.g. the (0.45,…) linear midpoint instead of
            // the reference (0.4707,…) bisector). The reference arc is a geodesic
            // on the corner-rounding sphere centred at V − width·Σn̂ (Σ of the
            // junction's unit face normals) — verified bit-exact on the cube
            // (task 0435). Bare-end / K1 / K2 rails keep the per-vertex fillet.
            immutable bool useHub =
                left.kind == CornerKind.Miter && right.kind == CornerKind.Miter &&
                left.selectedDegree >= 3 && right.selectedDegree >= 3;
            Vec3 hubC = Vec3(0, 0, 0);
            if (useHub) {
                Vec3 sn = Vec3(0, 0, 0);
                foreach (fi; facesAroundVertex(centerVert))
                    sn = sn + safeNormalize(faceNormal(cast(uint)fi));
                hubC = center - sn * width;
            }
            RailSpec spec = RailSpec(
                forward ? left.vert : right.vert, forward ? right.vert : left.vert,
                center,
                forward ? left.kind : right.kind, forward ? right.kind : left.kind,
                forward ? left.clamped : right.clamped, forward ? right.clamped : left.clamped,
                forward ? left.selectedDegree : right.selectedDegree,
                forward ? right.selectedDegree : left.selectedDegree,
                (left.kind == CornerKind.Slide && right.kind == CornerKind.Slide &&
                 !left.clamped && !right.clamped &&
                 left.selectedDegree == 1 && right.selectedDegree == 1)
                    ? RailProfile.VerifiedK1Arc : RailProfile.LocalAnalyticUnverified,
                0, 0, false,
                hubC, useHub);
            if (auto prior = key in railSpecs) {
                assert((prior.center - center).length < 1e-5f &&
                    prior.profile == spec.profile &&
                    prior.aKind == spec.aKind && prior.bKind == spec.bKind &&
                    prior.aClamped == spec.aClamped && prior.bClamped == spec.bClamped &&
                    prior.aSelectedDegree == spec.aSelectedDegree &&
                    prior.bSelectedDegree == spec.bSelectedDegree,
                    "edge bevel rail endpoint pair has incompatible provenance");
            } else {
                railSpecs[key] = spec;
            }
        }
        void addRailSupportConsumer(uint a, uint b) {
            immutable ulong key = pairKey(a, b);
            if (auto spec = key in railSpecs) ++spec.supportConsumers;
        }
        uint[] railInterior(uint a, uint b) {
            import std.algorithm : reverse;
            import std.math : sin, acos, abs;
            immutable ulong key = pairKey(a, b);
            uint[] stored;
            if (auto p = key in railInteriorMemo) {
                stored = *p;
            } else {
                auto specP = key in railSpecs;
                assert(specP !is null && specP.approved,
                    "rounded edge bevel rail must be approved before materialization");
                immutable RailSpec spec = *specP;
                // Reference subdivides a rounded arc into 2·roundLevel equal-
                // angle segments (verified: isolated K1 at Round Level 3 has 5
                // interior points, not 7 — task 0435). 2·L equals 2^L only at
                // L≤2, which is why the old 1<<roundLevel matched there but
                // over-subdivided at L≥3.
                immutable int n = 2 * roundLevel;
                immutable uint lo = a < b ? a : b;
                immutable uint hi = a < b ? b : a;
                // Reference-captured round-rail law (task 0435, edge.bevel spec
                // behavior.miter_rail_law + generalization_findings). The rounded
                // cross-section is a TRUE circular fillet tangent to the two
                // adjacent faces, whose radius AND sweep are set by the ACTUAL
                // dihedral — not a fixed 90° quarter-turn (that was a cube-only
                // degeneracy). Reconstructed from the reference's own builders
                // (RoundCenter = two-tangent-line intersection; RoundPos =
                // angular SLERP):
                //   dA = V - E_A,  dB = V - E_B
                //   k  = width² / (width² + dA·dB)      // = 1 at a 90° corner
                //   C  = V - k·(dA + dB)                // fillet center
                //   Ω  = angle(E_A - C, E_B - C) = 180° - dihedral
                //   Q(f) = C + slerp(E_A - C, E_B - C, f),  f = t/n
                // f=0 → E_A and f=1 → E_B exactly (endpoints bit-exact, manifold
                // safe). At a 90° dihedral (dA·dB=0 ⇒ k=1, Ω=90°) this reduces
                // EXACTLY to the earlier V - dA(1-sinθ) - dB(1-cosθ) form, so the
                // axis-aligned cube stays bit-exact while non-90° edges now round
                // correctly. Swapping lo/hi mirrors the sweep, which the a<b
                // reversal below undoes, so the emitted point set is orientation-
                // independent. (K3+ junction hub magnitude / Gregory-patch ring
                // remain a separate reference gap — see the doc comment above.)
                immutable Vec3 EA = vertices[lo];
                immutable Vec3 EB = vertices[hi];
                immutable Vec3 dA = spec.center - EA;   // V - E_A
                immutable Vec3 dB = spec.center - EB;   // V - E_B
                immutable float w2    = width * width;
                immutable float denom = w2 + dot(dA, dB);
                immutable float k     = (abs(denom) > 1e-12f) ? (w2 / denom) : 1.0f;
                // Junction pairwise rail: geodesic on the corner-rounding sphere
                // (centre V − width·Σn̂, set at registerRail) — the per-vertex
                // fillet centre degenerates for near-antipodal hub poles.
                immutable Vec3  C     = spec.hasArcCenter
                    ? spec.arcCenter : (spec.center - (dA + dB) * k);
                immutable Vec3  sA    = EA - C;         // spoke to E_A
                immutable Vec3  sB    = EB - C;         // spoke to E_B
                immutable float lenA  = sA.length, lenB = sB.length;
                float cosO = (lenA > 1e-12f && lenB > 1e-12f)
                    ? dot(sA, sB) / (lenA * lenB) : 1.0f;
                if (cosO >  1.0f) cosO =  1.0f;
                if (cosO < -1.0f) cosO = -1.0f;
                immutable float Omega = acos(cosO);
                immutable float sinO  = sin(Omega);
                Vec3[] pts = new Vec3[](n + 1);
                foreach (t; 0 .. n + 1) {
                    immutable float f = cast(float)t / cast(float)n;
                    if (sinO < 1e-6f) {
                        // Degenerate (collinear / 180° sweep): straight chord.
                        pts[t] = EA * (1.0f - f) + EB * f;
                    } else {
                        immutable float wa = sin((1.0f - f) * Omega) / sinO;
                        immutable float wb = sin(f * Omega) / sinO;
                        pts[t] = C + sA * wa + sB * wb;
                    }
                }
                uint[] interior = new uint[](n - 1);
                foreach (t; 1 .. n) interior[t - 1] = addVertex(pts[t]);
                railInteriorMemo[key] = interior;
                stored = interior;
            }
            if (a < b) return stored;
            auto rev = stored.dup;
            reverse(rev);
            return rev;
        }

        foreach (V; 0 .. cast(uint)vertices.length) {
            if (V >= affected.length || !affected[V]) continue;

            uint[] vFaces, vEdges, vNbrs;
            foreach (fi; facesAroundVertex(V)) vFaces ~= fi;
            foreach (ei; edgesAroundVertex(V)) vEdges ~= ei;
            immutable int d  = cast(int)vFaces.length;
            immutable int nE = cast(int)vEdges.length;
            // Two supported fan shapes, both walked by the SAME convention:
            // face f_k is bordered by edge slots k and k+1.
            //   CLOSED (interior vertex): nE == d, slot d wraps to slot 0.
            //   OPEN   (boundary vertex): nE == d + 1 — `VertexEdgeRange`
            //     anchors at the open start of the fan and emits one extra
            //     edge at the end, so the slots run e_0 .. e_d with NO wrap
            //     (e_0 and e_d are the two rim edges).
            // Anything else is a malformed / non-manifold fan and is skipped.
            immutable bool openFan = (nE == d + 1);
            if (d < 2 || (nE != d && !openFan)) continue;
            vNbrs.length = nE;
            foreach (k; 0 .. nE) vNbrs[k] = edgeOtherVertex(vEdges[k], V);

            bool[] selE = new bool[](nE);
            int K = 0;
            foreach (k; 0 .. nE) {
                selE[k] = (vEdges[k] < qualifies.length) && qualifies[vEdges[k]];
                if (selE[k]) ++K;
            }
            if (K == 0) continue;

            // An unselected edge is "active" iff it is immediately adjacent
            // to a selected edge — i.e. it needs its own slide vertex (shared
            // by both faces bordering it). Two edge slots are adjacent exactly
            // when they bound a common face, so the relation is cyclic on a
            // closed fan and LINEAR on an open one (slot 0 and slot d share no
            // face there — wrapping them would invent an adjacency).
            bool[] active = new bool[](nE);
            foreach (k; 0 .. nE) {
                if (selE[k]) continue;
                if (openFan) {
                    active[k] = (k > 0 && selE[k - 1]) || (k + 1 < nE && selE[k + 1]);
                    // The two END slots of an open fan are the rim edges. They
                    // share no FACE, but the boundary itself joins them — so a
                    // selected RIM edge has to cut the corner on the far side
                    // too, otherwise the re-routed boundary has nowhere to go.
                    // Reference: `edge_bevel_open_rimedge_w015` cuts V into a
                    // slide on EACH remaining edge (V is not retained).
                    if (!active[k] && (k == 0 || k == nE - 1))
                        active[k] = selE[k == 0 ? nE - 1 : 0];
                } else {
                    active[k] = selE[(k - 1 + d) % d] || selE[(k + 1) % d];
                }
            }

            immutable Vec3 vpos = vertices[V];
            uint[int] slideVert;    // local edge-slot k → new vertex (memoized per V)
            bool[int] slideClamped; // local edge-slot k → did the overshoot guard clamp it?
            uint getSlide(int k) {
                if (auto p = k in slideVert) return *p;
                Vec3 dir = safeNormalize(vertices[vNbrs[k]] - vpos);
                immutable float w = clampedWidth(V, vNbrs[k]);
                uint nv = addVertex(vpos + dir * w);
                slideVert[k]    = nv;
                slideClamped[k] = (w < width);
                return nv;
            }
            Vec3 slideDir(int k) { return safeNormalize(vertices[vNbrs[k]] - vpos); }

            foreach (k; 0 .. d) {
                // face f_k's PRED-side edge slot. On an open fan k+1 never
                // exceeds d < nE, so the modulus is a no-op there and only
                // the closed fan actually wraps.
                immutable int kr = (k + 1) % nE;
                immutable uint fi = vFaces[k];
                immutable bool selSucc = selE[k];   // edge k: V's succ-side in f_k
                immutable bool selPred = selE[kr];  // edge kr: V's pred-side in f_k

                if (selSucc && selPred) {
                    // MITER: both bordering edges selected (loop turn, or one
                    // face of an N-way junction). ePrev/eNext match
                    // insetCorner's own prev/next-in-face convention.
                    Vec3 ePrev = safeNormalize(vertices[vNbrs[kr]] - vpos);
                    Vec3 eNext = safeNormalize(vertices[vNbrs[k]]  - vpos);
                    Vec3 m = offsetMeet(vpos, ePrev, eNext, faceNormal(fi), width, width);
                    uint nv = addVertex(m);
                    cornerAtVF[vfKey(V, fi)] = CornerInfo(
                        nv, CornerKind.Miter, false, cast(uint)K, Vec3(0,0,0));
                    faceSubs.require(fi) ~= VertSub(V, [nv]);
                } else if (selSucc != selPred) {
                    // SLIDE: exactly one bordering edge selected — corner
                    // slides along the OTHER (unselected) one.
                    immutable int unselK = selSucc ? kr : k;
                    uint nv = getSlide(unselK);
                    cornerAtVF[vfKey(V, fi)] = CornerInfo(
                        nv, CornerKind.Slide, slideClamped[unselK], cast(uint)K, slideDir(unselK));
                    faceSubs.require(fi) ~= VertSub(V, [nv]);
                } else {
                    // Neither bordering edge selected — split iff at least
                    // one side is "active" (touches a selected edge via its
                    // OTHER face). Order is [pred-side, succ-side] to match
                    // f_k's own ring-traversal direction at V.
                    immutable bool activeSucc = active[k];
                    immutable bool activePred = active[kr];
                    if (activeSucc && activePred) {
                        uint predSide = getSlide(kr);
                        uint succSide = getSlide(k);
                        // Keep the L0 chord here.  Once every span has
                        // registered its rails, boundary threading below
                        // replaces this edge with the shared chain.
                        faceSubs.require(fi) ~= VertSub(V, [predSide, succSide]);
                    } else if (activeSucc) {
                        // KNOWN-UNTESTED partial notch (valence>3 only — a
                        // cube corner is always valence 3, so no fixture
                        // exercises this branch): V retained on the
                        // inactive side, a single slide vertex on the
                        // active side. No arc/rounding is ever attempted
                        // here (the old bare-only rounding gate required
                        // d==3, which this branch structurally cannot reach — d==3 with a
                        // single active side would already be the
                        // `activeSucc && activePred` case above).
                        faceSubs.require(fi) ~= VertSub(V, [V, getSlide(k)]);
                    } else if (activePred) {
                        faceSubs.require(fi) ~= VertSub(V, [getSlide(kr), V]);
                    }
                    // else: untouched — this face doesn't reach V's bevel.
                }
            }

            if (!openFan && K == d && d >= 3) {
                // Full ring: every face at V is a MITER — its per-face
                // corners trace a closed K-gon needing exactly one cap face.
                // An OPEN fan can never form one: its corner chain terminates
                // on the two rim edges instead of closing, so it takes the
                // ordinary per-face SLIDE/MITER path with no hub cap.
                // KNOWN-UNTESTED: only d==3 (the cube-corner junction, K=3)
                // is fixture/unittest-covered; d>3 (a higher-valence full
                // hub, e.g. from a subdivided mesh) exercises this same
                // general N-gon-fill code path but has no golden or
                // manifold-check coverage of its own.
                uint[] ring = new uint[](d);
                foreach (k; 0 .. d) ring[k] = cornerAtVF[vfKey(V, vFaces[k])].vert;
                hubCapRing[V] = ring;
                hubCapSrc[V]  = vFaces[0];
            }
        }

        if (cornerAtVF.length == 0) {
            vertices.length = savedVertCount; // undo any addVertex from the per-vertex pass
            return 0;
        }

        // Pre-rebuild pass: for each qualifying selected edge, resolve its
        // fL (traverses v1→v0)/fR (traverses v0→v1) faces from the ORIGINAL
        // (pre-substitution) face array, and its 4 chamfer/arc-rail corners.
        struct ChamferSpan { uint v0, v1, fL, fR; }
        ChamferSpan[] spans;
        // RIM edges (one incident face) never become spans: there is no second
        // rail to bridge to, so the reference adds no face for them. Their
        // whole effect — the lone face's border insetting by `width`, and the
        // neighbouring faces absorbing the corner cut — is already produced by
        // the per-vertex substitution pass. They still count as processed.
        size_t rimProcessed = 0;
        foreach (i; 0 .. edges.length) {
            if (!qualifies[i]) continue;
            uint v0 = edges[i][0], v1 = edges[i][1];
            auto fp = edgeKeyOrdered(v0, v1) in edgeFaces;
            if (rimOnly[i]) {
                immutable uint fOnly = cast(uint)(*fp)[0];
                if (vfKey(v0, fOnly) in cornerAtVF && vfKey(v1, fOnly) in cornerAtVF)
                    ++rimProcessed;
                continue;
            }
            int fa = (*fp)[0], fb = (*fp)[1];
            uint fL = uint.max, fR = uint.max;
            foreach (k; 0 .. faces[fa].length) {
                uint u = faces[fa][k], w = faces[fa][(k + 1) % faces[fa].length];
                if (u == v1 && w == v0) { fL = fa; fR = fb; break; }
                if (u == v0 && w == v1) { fR = fa; fL = fb; break; }
            }
            if (fL == uint.max) continue;
            // Defensive: both endpoints must have a resolved corner at BOTH
            // fL and fR. A BOUNDARY endpoint no longer lands here — the
            // per-vertex pass above now walks the OPEN fan (nE == d + 1) and
            // populates its `cornerAtVF` entries, so a chain whose ends sit
            // on a rim bevels instead of being dropped. What remains
            // unresolved is a genuinely malformed / non-manifold fan, which
            // still fails the shape check above. Rather than crash on a
            // missing-key AA lookup, skip just this span — the same
            // "silently skipped" contract as v1's guards.
            if (vfKey(v0, fL) !in cornerAtVF || vfKey(v1, fL) !in cornerAtVF ||
                vfKey(v0, fR) !in cornerAtVF || vfKey(v1, fR) !in cornerAtVF)
                continue;
            spans ~= ChamferSpan(v0, v1, fL, fR);
        }
        if (spans.length == 0 && rimProcessed == 0) {
            vertices.length = savedVertCount; // undo any addVertex from the per-vertex pass
            return 0;
        }
        immutable size_t processed = spans.length + rimProcessed;

        // Resolve every original face to its L0 boundary before rounded
        // vertices exist.  This is also the authoritative support-consumer
        // inventory, rather than an optimistic post-materialization guess.
        uint[][] baseFaces;
        foreach (fi; 0 .. faces.length) {
            auto orig = faces[fi];
            auto subsP = cast(uint)fi in faceSubs;
            if (subsP is null) {
                baseFaces ~= orig.dup;
            } else {
                uint[][uint] repl;
                foreach (s; *subsP) repl[s.oldV] = s.newVs;
                uint[] rebuilt;
                foreach (v; orig) {
                    auto rp = v in repl;
                    if (rp is null) rebuilt ~= v;
                    else            rebuilt ~= *rp;
                }
                baseFaces ~= rebuilt;
            }
        }

        // Inventory rail consumers symbolically before allocating a single
        // interior vertex.  A strip can round only when BOTH of its endpoint
        // rails have exactly two consumers.  Prune that relation to a fixed
        // point: disabling one strip removes its consumer from both rails,
        // which can disable a neighbouring strip too.  Any rail that cannot
        // meet the invariant stays locally L0; the base bevel still commits.
        // K2/K3 external profile parity remains XFAIL, not inferred here.
        bool[] roundedSpan;
        if (roundLevel > 0) {
            foreach (ref sp; spans) {
                auto cV0L = cornerAtVF[vfKey(sp.v0, sp.fL)];
                auto cV0R = cornerAtVF[vfKey(sp.v0, sp.fR)];
                auto cV1L = cornerAtVF[vfKey(sp.v1, sp.fL)];
                auto cV1R = cornerAtVF[vfKey(sp.v1, sp.fR)];
                registerRail(cV0L, cV0R, vertices[sp.v0], sp.v0);
                registerRail(cV1L, cV1R, vertices[sp.v1], sp.v1);
            }
            foreach (ring; baseFaces)
                foreach (k; 0 .. ring.length)
                    addRailSupportConsumer(ring[k], ring[(k + 1) % ring.length]);
            foreach (V, ring; hubCapRing)
                foreach (k; 0 .. ring.length)
                    addRailSupportConsumer(ring[k], ring[(k + 1) % ring.length]);

            roundedSpan.length = spans.length;
            roundedSpan[] = true;
            bool changed;
            do {
                foreach (ref spec; railSpecs) {
                    spec.stripConsumers = 0;
                    spec.approved = false;
                }
                foreach (si, ref sp; spans) if (roundedSpan[si]) {
                    auto cV0L = cornerAtVF[vfKey(sp.v0, sp.fL)];
                    auto cV0R = cornerAtVF[vfKey(sp.v0, sp.fR)];
                    auto cV1L = cornerAtVF[vfKey(sp.v1, sp.fL)];
                    auto cV1R = cornerAtVF[vfKey(sp.v1, sp.fR)];
                    ++railSpecs[pairKey(cV0L.vert, cV0R.vert)].stripConsumers;
                    ++railSpecs[pairKey(cV1L.vert, cV1R.vert)].stripConsumers;
                }
                foreach (ref spec; railSpecs)
                    spec.approved = spec.stripConsumers > 0 &&
                        spec.supportConsumers + spec.stripConsumers == 2;

                changed = false;
                foreach (si, ref sp; spans) if (roundedSpan[si]) {
                    auto cV0L = cornerAtVF[vfKey(sp.v0, sp.fL)];
                    auto cV0R = cornerAtVF[vfKey(sp.v0, sp.fR)];
                    auto cV1L = cornerAtVF[vfKey(sp.v1, sp.fL)];
                    auto cV1R = cornerAtVF[vfKey(sp.v1, sp.fR)];
                    if (!railSpecs[pairKey(cV0L.vert, cV0R.vert)].approved ||
                        !railSpecs[pairKey(cV1L.vert, cV1R.vert)].approved) {
                        roundedSpan[si] = false;
                        changed = true;
                    }
                }
            } while (changed);

            // Materialize only the fixed-point-approved rails.  No later
            // rollback can strand them because all remaining consumers are
            // already known symbolically.
            foreach (key, spec; railSpecs)
                if (spec.approved) railInterior(spec.a, spec.b);
        }

        // Thread only L0 boundaries.  Rounded strip faces are emitted below
        // directly from the same registry and therefore cannot be threaded a
        // second time.
        uint[] threadRails(const uint[] ring) {
            import std.algorithm : reverse;
            if (roundLevel == 0 || ring.length < 2) return ring.dup;
            uint[] threaded;
            foreach (k; 0 .. ring.length) {
                uint a = ring[k], b = ring[(k + 1) % ring.length];
                threaded ~= a;
                immutable ulong key = pairKey(a, b);
                if (auto p = key in railInteriorMemo) {
                    uint[] interior = *p;
                    if (a > b) {
                        interior = interior.dup;
                        reverse(interior);
                    }
                    threaded ~= interior;
                }
            }
            return threaded;
        }

        // Thread the pre-resolved support boundaries through the materialized
        // rails.  Rounded strip faces are emitted directly below and are not
        // threaded a second time.
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        bool[]   newSub;

        foreach (fi; 0 .. baseFaces.length) {
            newFaces ~= threadRails(baseFaces[fi]);
            newMat  ~= fi < faceMaterial.length       ? faceMaterial[fi]       : 0u;
            newPart ~= fi < facePart.length           ? facePart[fi]           : 0u;
            newOrd  ~= fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0;
            newSub  ~= isFaceSubpatch(fi);
        }

        // Emit the chamfer strip per qualifying edge.  At L>0 every endpoint
        // draws from the pre-materialized rail registry; all support
        // consumers use those exact same indices.
        size_t chamferStart = newFaces.length;
        foreach (si, ref sp; spans) {
            auto cV0L = cornerAtVF[vfKey(sp.v0, sp.fL)];
            auto cV1L = cornerAtVF[vfKey(sp.v1, sp.fL)];
            auto cV1R = cornerAtVF[vfKey(sp.v1, sp.fR)];
            auto cV0R = cornerAtVF[vfKey(sp.v0, sp.fR)];
            immutable bool sub = isFaceSubpatch(sp.fL) || isFaceSubpatch(sp.fR);

            if (roundLevel == 0 || !roundedSpan[si]) {
                newFaces ~= [cV0L.vert, cV1L.vert, cV1R.vert, cV0R.vert];
                newMat ~= 0u; newPart ~= 0u; newOrd ~= 0; newSub ~= sub;
                continue;
            }

            immutable int n = 2 * roundLevel;   // 2·L segments (matches railInterior)
            // r0/r1 both walk fL→fR, using the stored orientation of their
            // source-centred rail chains.
            uint[] r0Interior = railInterior(cV0L.vert, cV0R.vert);
            uint[] r1Interior = railInterior(cV1L.vert, cV1R.vert);

            uint[] r0 = new uint[](n + 1), r1 = new uint[](n + 1);
            r0[0] = cV0L.vert; r0[n] = cV0R.vert;
            r1[0] = cV1L.vert; r1[n] = cV1R.vert;
            foreach (t; 1 .. n) r0[t] = r0Interior[t - 1];
            foreach (t; 1 .. n) r1[t] = r1Interior[t - 1];

            foreach (t; 0 .. n) {
                newFaces ~= [r0[t], r1[t], r1[t + 1], r0[t + 1]];
                newMat ~= 0u; newPart ~= 0u; newOrd ~= 0; newSub ~= sub;
            }
        }

        // Full N=3 junction Gregory ring, GENERAL Round Level (task 0435,
        // gregory_evaluator_findings + twist_reduction_findings). Each side is a
        // standard rational bicubic Gregory patch (Gregory 1974 / Chiyokura–
        // Kimura) whose entire 20-cell control net — the 12 boundary/spoke cells
        // AND the 4 rational twist cells — is closed-form in the boundary Béziers
        // + the R/Q/newC/HUB laws (all from the 3 poles). Samples it on the
        // level-L grid ((u,v) ∈ {0,1/L,…,1}², the ref subdivides an arc into 2·L
        // equal segments so the sub-quad boundary reuses the true-arc rail
        // interiors 1:1). Outputs:
        //   spokePts[i*(L-1)+(k-1)]              = R_i→HUB spoke point at t=k/L
        //     (patch boundary, plain cubic Bézier — shared with the neighbour);
        //   interiorPts[i*(L-1)^2+(b-1)*(L-1)+(a-1)] = rational eval at (a/L,b/L).
        // Validated bit-exact vs the reference from raw geometry
        // (k3_ring_raw_geometry_ref.py). N=3 only.
        static bool junctionRing(const(Vec3)[] poles, const(Vec3)[] bis, int L,
                                 out Vec3 hub, out Vec3[] spokePts, out Vec3[] interiorPts) {
            import std.math : tan, acos;
            if (poles.length != 3 || bis.length != 3 || L < 1) return false;
            Vec3[3] P1, P2, Q, newC;
            foreach (i; 0 .. 3) {   // boundary Bézier P1/P2 (circumcircle pole,R,pole)
                immutable Vec3 A = poles[i], M = bis[i], B = poles[(i + 1) % 3];
                immutable Vec3 ab = M - A, ac = B - A;
                immutable Vec3 abXac = cross(ab, ac);
                immutable float d = 2.0f * dot(abXac, abXac);
                if (d < 1e-18f) return false;
                immutable Vec3 O = A + (cross(abXac, ab) * dot(ac, ac)
                                      + cross(ac, abXac) * dot(ab, ab)) / d;
                immutable Vec3 sA = A - O, sB = B - O;
                immutable float r = sA.length;
                if (r < 1e-9f) return false;
                float cosO = dot(sA, sB) / (r * r);
                if (cosO >  1.0f) cosO =  1.0f;
                if (cosO < -1.0f) cosO = -1.0f;
                immutable float Om = acos(cosO);
                if (Om < 1e-6f) return false;
                Vec3 tA = sB - sA * cosO;  tA = tA / tA.length;
                Vec3 tB = sA - sB * cosO;  tB = tB / tB.length;
                immutable float arm = (4.0f / 3.0f) * tan(Om / 4.0f) * r;
                P1[i] = A + tA * arm;
                P2[i] = B + tB * arm;
            }
            Vec3 hsum = Vec3(0, 0, 0);
            foreach (i; 0 .. 3) {
                Q[i] = bis[i] + ((P2[(i + 2) % 3] - poles[i])
                               + (P1[(i + 1) % 3] - poles[(i + 1) % 3])) * 0.25f;
                hsum = hsum + (Q[i] * 1.5f - bis[i] * 0.5f);
            }
            hub = hsum / 3.0f;
            foreach (i; 0 .. 3) newC[i] = (Q[i] * 1.5f - bis[i] * 0.5f) * (2.0f / 3.0f) + hub / 3.0f;
            // Per-side twist cells (closed-form) + the 12 fixed cells.
            Vec3[3] p10, p20, p01, p02, F16, F17, F5, F9, F6, F18, F10;
            foreach (i; 0 .. 3) {
                immutable int pv = (i + 2) % 3, nx = (i + 1) % 3;
                immutable Vec3 P0i = poles[i];
                immutable Vec3 DA = P2[pv] - P0i,             DB  = P1[nx] - poles[nx];
                immutable Vec3 DAp = P2[(pv + 2) % 3] - poles[pv], DBp = P1[i] - P0i;
                immutable Vec3 DT  = DA * (2.0f / 3.0f) + DB * (1.0f / 3.0f);
                immutable Vec3 DU  = DA * (1.0f / 3.0f) + DB * (2.0f / 3.0f);
                immutable Vec3 DTp = DAp * (2.0f / 3.0f) + DBp * (1.0f / 3.0f);
                immutable Vec3 DUp = DAp * (1.0f / 3.0f) + DBp * (2.0f / 3.0f);
                p10[i] = (P0i + P1[i]) * 0.5f;
                p20[i] = (P0i + P1[i] * 2.0f + P2[i]) * 0.25f;
                p01[i] = (P2[pv] + P0i) * 0.5f;
                p02[i] = (P1[pv] + P2[pv] * 2.0f + P0i) * 0.25f;
                F16[i] = p10[i] + (DA + DT) * 0.25f;
                F17[i] = p20[i] + (DA + DU) * 0.125f + DT * 0.25f;
                F5[i]  = p01[i] + (DBp + DUp) * 0.25f;
                F9[i]  = p02[i] + (DTp + DBp) * 0.125f + DUp * 0.25f;
                F6[i]  = F17[i] + (Q[i]  - bis[i])  * (1.0f / 6.0f);
                F18[i] = F9[i]  + (Q[pv] - bis[pv]) * (1.0f / 6.0f);
                F10[i] = (newC[i] + newC[pv] - newC[nx]) * 4.0f / 3.0f
                       + (Q[nx] - Q[i] - Q[pv]) / 3.0f;
            }
            static float[4] bern(float t) {
                immutable float s = 1.0f - t;
                return [s*s*s, 3.0f*t*s*s, 3.0f*t*t*s, t*t*t];
            }
            // Rational bicubic Gregory eval of sub-quad i at (u,v).
            Vec3 evalSub(int i, float u, float v) {
                immutable int pv = (i + 2) % 3;
                Vec3 blend(Vec3 a, Vec3 b, float wa, float wb) {
                    immutable float den = wa + wb;
                    return den > 1e-9f ? (a * wa + b * wb) / den : (a + b) * 0.5f;
                }
                immutable Vec3 p11 = blend(F16[i], F5[i],  u, v);
                immutable Vec3 p12 = blend(F18[i], F9[i],  u, 1.0f - v);
                immutable Vec3 p21 = blend(F17[i], F6[i],  1.0f - u, v);
                // g[a][b] = grid[(a,b)], a=u-index, b=v-index.  v=0 edge (b=0) is
                // pole→R_i; u=0 edge (a=0) is pole→R_prev; u=1 (a=3) is the
                // R_i→HUB spoke; v=1 (b=3) is the R_prev→HUB spoke.
                immutable Vec3[4][4] g = [
                    [poles[i], p01[i],  p02[i],   bis[pv] ],
                    [p10[i],   p11,     p12,      Q[pv]   ],
                    [p20[i],   p21,     F10[i],   newC[pv]],
                    [bis[i],   Q[i],    newC[i],  hub     ],
                ];
                immutable float[4] Bu = bern(u), Bv = bern(v);
                Vec3 acc = Vec3(0, 0, 0);
                foreach (a; 0 .. 4) foreach (b; 0 .. 4) acc = acc + g[a][b] * (Bu[a] * Bv[b]);
                return acc;
            }
            immutable int m = L - 1;                    // interior samples per axis
            spokePts.length    = 3 * m;
            interiorPts.length = 3 * m * m;
            immutable float inv = 1.0f / cast(float) L;
            foreach (i; 0 .. 3) {
                foreach (k; 1 .. L)                     // R_i→HUB spoke at u=1
                    spokePts[i * m + (k - 1)] = evalSub(i, 1.0f, k * inv);
                foreach (b; 1 .. L) foreach (a; 1 .. L)
                    interiorPts[i * m * m + (b - 1) * m + (a - 1)] = evalSub(i, a * inv, b * inv);
            }
            return true;
        }

        // Emit one hub cap per full-ring (K==valence) vertex — Phase 2.
        // Outward-winding check via Newell's formula vs the averaged
        // ORIGINAL incident-face normal, same idiom as bevelVerticesByMask.
        size_t capStart = newFaces.length;
        foreach (V, ring_; hubCapRing) {
            uint[] ring = threadRails(ring_);
            immutable int Ncap = cast(int)ring.length;
            Vec3 newellN = Vec3(0, 0, 0);
            foreach (k; 0 .. Ncap) {
                Vec3 a = vertices[ring[k]];
                Vec3 b = vertices[ring[(k + 1) % Ncap]];
                newellN.x += (a.y - b.y) * (a.z + b.z);
                newellN.y += (a.z - b.z) * (a.x + b.x);
                newellN.z += (a.x - b.x) * (a.y + b.y);
            }
            Vec3 avgFaceN = Vec3(0, 0, 0);
            foreach (fi; facesAroundVertex(V)) {
                Vec3 fn = faceNormal(cast(uint)fi);
                avgFaceN.x += fn.x; avgFaceN.y += fn.y; avgFaceN.z += fn.z;
            }
            if (dot(newellN, avgFaceN) < 0) {
                for (int lo = 0, hi = Ncap - 1; lo < hi; ++lo, --hi) {
                    uint tmp = ring[lo]; ring[lo] = ring[hi]; ring[hi] = tmp;
                }
            }
            immutable uint srcFi = hubCapSrc[V];

            // 3-way junction Gregory ring, GENERAL Round Level (task 0435).
            // Unifies the L1 fan (1×1 grid → [pole,R,HUB,R]) and the L≥2 interior
            // ring (L×L grid): HUB + R→HUB spoke points + rational interior points
            // woven into an L×L quad grid per sub-quad whose u=0/v=0 boundary
            // REUSES the true-arc pairwise rail interiors (the reference rail is
            // the arc, not the patch's internal Bézier). Bit-exact vs the
            // reference at L1/L2/L3 (20v/15f, 38v/30f, 62v/51f). N>3 junctions
            // use a different reference (N-sided) path and keep the flat cap.
            if (ring_.length == 3 && roundLevel >= 1) {
                immutable int L = roundLevel;
                immutable int m = L - 1;
                uint[3] poleI; int np = 0;
                foreach (v; ring) {
                    bool isP = false; foreach (p; ring_) if (v == p) { isP = true; break; }
                    if (isP && np < 3) poleI[np++] = v;
                }
                bool ok = (np == 3);
                uint[][3] railI;
                Vec3[3] poleP, RP;
                if (ok) foreach (i; 0 .. 3) {
                    railI[i] = railInterior(poleI[i], poleI[(i + 1) % 3]);
                    if (railI[i].length != 2 * L - 1) { ok = false; break; }
                    poleP[i] = vertices[poleI[i]];
                    RP[i]    = vertices[railI[i][L - 1]];       // R_i = middle interior
                }
                Vec3 hubPos; Vec3[] spokeP, interiorP;
                if (ok && junctionRing(poleP[], RP[], L, hubPos, spokeP, interiorP)) {
                    immutable uint hubIdx = addVertex(hubPos);
                    uint[][3] spokeIdx, interiorIdx;
                    foreach (i; 0 .. 3) {
                        spokeIdx[i].length = m;
                        foreach (k; 0 .. m) spokeIdx[i][k] = addVertex(spokeP[i * m + k]);
                        interiorIdx[i].length = m * m;
                        foreach (k; 0 .. m * m) interiorIdx[i][k] = addVertex(interiorP[i * m * m + k]);
                    }
                    // Grid vertex of sub-quad i at (a,b), a,b ∈ 0..L. u=0/v=0 edges
                    // reuse the rail interiors; u=1/v=1 edges are the R→HUB spokes
                    // (shared with the neighbour sub-quad); interior = Gregory eval.
                    uint gv(int i, int a, int b) {
                        immutable int pv = (i + 2) % 3;
                        if (a == 0 && b == 0) return poleI[i];
                        if (a == L && b == 0) return railI[i][L - 1];        // R_i
                        if (a == 0 && b == L) return railI[pv][L - 1];       // R_prev
                        if (a == L && b == L) return hubIdx;
                        if (b == 0)           return railI[i][a - 1];        // pole_i→R_i
                        if (a == 0)           return railI[pv][2 * L - 1 - b]; // pole_i→R_prev
                        if (a == L)           return spokeIdx[i][b - 1];     // R_i→HUB
                        if (b == L)           return spokeIdx[pv][a - 1];    // R_prev→HUB
                        return interiorIdx[i][(b - 1) * m + (a - 1)];
                    }
                    foreach (i; 0 .. 3)
                        foreach (b; 0 .. L) foreach (a; 0 .. L) {
                            newFaces ~= [gv(i, a, b), gv(i, a + 1, b),
                                         gv(i, a + 1, b + 1), gv(i, a, b + 1)];
                            newMat  ~= srcFi < faceMaterial.length ? faceMaterial[srcFi] : 0u;
                            newPart ~= srcFi < facePart.length     ? facePart[srcFi]     : 0u;
                            newOrd  ~= 0;
                            newSub  ~= isFaceSubpatch(srcFi);
                        }
                    continue;
                }
            }

            newFaces ~= ring;
            newMat  ~= srcFi < faceMaterial.length ? faceMaterial[srcFi] : 0u;
            newPart ~= srcFi < facePart.length     ? facePart[srcFi]     : 0u;
            newOrd  ~= 0;
            newSub  ~= isFaceSubpatch(srcFi);
        }

        // Assign reconstructed arrays.
        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;

        // Rebuild faceMarks: zero all, then restore subpatch bits.
        faceMarks.length = faces.length;
        faceMarks[]      = 0;
        foreach (fi, s; newSub)
            if (s) faceMarks[fi] |= Marks.Subpatch;

        // New selection = chamfer + hub-cap faces; clear vertex/edge selections.
        faceSelectionOrderCounter = 0;
        foreach (fi; chamferStart .. faces.length)
            selectFace(cast(int)fi);
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        // Overshoot clamping (`clampedWidth` above) can land a SLIDE corner
        // exactly on an EXISTING mesh vertex — weld it in and collapse the
        // resulting duplicate corner instead of leaving a coincident-vertex
        // / zero-area mesh behind. Safe here: new faces occupy the array
        // tail, so a fully-collapsed one only shortens the tail.
        if (anyClamped) weldCoincidentVertices(1e-10);

        // Tail: rebuild topology + compact orphaned original vertices.
        rebuildEdges();
        buildLoops();
        compactUnreferenced();
        buildLoops();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }

    /// Vertex bevel: for each selected interior-manifold vertex v, split each
    /// incident edge at v + amount*normalize(other−v) (one new vertex per edge,
    /// shared by the two adjacent faces), rewrite every incident face to replace
    /// v with its two split points in face-ring order, and append an
    /// outward-wound cap N-gon through those split points.
    ///
    /// Interior-manifold guard: every incident edge of v must be shared by
    /// exactly 2 faces and valence must be ≥ 3. Boundary and wire-edge vertices
    /// are silently skipped. Adjacent selected vertices are handled via a greedy
    /// vertex-disjoint selection so no two accepted vertices share an edge.
    ///
    /// Cap material/subpatch are carried from one incident face of v — NOT the
    /// chamfer-literal 0u. Rewritten-face attributes are 1:1 from the original
    /// slot.
    ///
    /// Returns the count of vertices actually processed (0 ⇒ no-op, caller
    /// should discard snapshot).
    size_t bevelVerticesByMask(const bool[] mask, float amount) {
        if (mask.length != vertices.length) return 0;
        if (amount < 1e-6f) return 0;

        // local helpers
        uint succInFace_(uint fi, uint v) const {
            auto f = faces[fi];
            foreach (k; 0 .. f.length)
                if (f[k] == v) return f[(k+1)%f.length];
            return uint.max;
        }
        uint predInFace_(uint fi, uint v) const {
            auto f = faces[fi];
            foreach (k; 0 .. f.length)
                if (f[k] == v) return f[(k + f.length - 1)%f.length];
            return uint.max;
        }

        // edge→(≤2 faces) adjacency, one pass
        auto edgeFacesMap = buildEdgeFaces();

        // greedy vertex-disjoint acceptance
        bool[] accepted           = new bool[](vertices.length);
        bool[] neighborOfAccepted = new bool[](vertices.length);
        size_t processed          = 0;

        foreach (vi; 0 .. cast(uint)vertices.length) {
            if (vi >= mask.length || !mask[vi]) continue;
            if (neighborOfAccepted[vi]) continue;

            // incident edges in half-edge ring order
            uint[] incEdges;
            foreach (ei; edgesAroundVertex(vi)) incEdges ~= ei;
            if (incEdges.length < 3) continue;

            // interior-manifold: every incident edge shared by exactly 2 faces
            bool manifold = true;
            foreach (ei; incEdges) {
                ulong key = edgeKeyOrdered(edges[ei][0], edges[ei][1]);
                auto fp = key in edgeFacesMap;
                if (fp is null || (*fp)[0] < 0 || (*fp)[1] < 0) {
                    manifold = false; break;
                }
            }
            if (!manifold) continue;

            accepted[vi] = true;
            ++processed;
            foreach (ei; incEdges) {
                uint other = edgeOtherVertex(cast(uint)ei, vi);
                if (other < neighborOfAccepted.length)
                    neighborOfAccepted[other] = true;
            }
        }
        if (processed == 0) return 0;

        // Freeze original count before addVertex grows the array.
        const uint origVertCount = cast(uint)vertices.length;

        // one split vertex per incident edge of each accepted v
        uint[ulong]  splitByKey;  // edgeKeyOrdered(a,b) → new vertex index
        uint[][uint] capRings;    // vi → ordered split-vert indices for cap
        uint[uint]   capSrc;      // vi → one incident fi (attr carry)

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;

            uint[] ring;
            foreach (ei; edgesAroundVertex(vi)) {
                ulong key = edgeKeyOrdered(edges[ei][0], edges[ei][1]);
                if (key !in splitByKey) {
                    uint other = edgeOtherVertex(cast(uint)ei, vi);
                    Vec3 sp = vertices[vi] +
                              amount * safeNormalize(vertices[other] - vertices[vi]);
                    splitByKey[key] = addVertex(sp);
                }
                ring ~= splitByKey[key];
            }
            capRings[vi] = ring;

            foreach (fi; facesAroundVertex(vi)) { capSrc[vi] = cast(uint)fi; break; }
        }

        // per-face substitution map: accepted vi → [sp_pred, sp_succ]
        struct VertSub { uint oldV; uint[] newVs; }
        VertSub[][uint] faceSubs;

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;
            foreach (fi; facesAroundVertex(vi)) {
                uint p    = predInFace_(cast(uint)fi, vi);
                uint s    = succInFace_(cast(uint)fi, vi);
                uint spPV = splitByKey[edgeKeyOrdered(p, vi)];
                uint spVS = splitByKey[edgeKeyOrdered(vi, s)];
                faceSubs.require(cast(uint)fi) ~= VertSub(vi, [spPV, spVS]);
            }
        }

        // single rebuild pass: rewritten faces then cap faces
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        bool[]   newSub;

        // (a) surviving / substituted faces
        foreach (fi; 0 .. faces.length) {
            auto orig  = faces[fi];
            auto subsP = cast(uint)fi in faceSubs;
            if (subsP is null) {
                newFaces ~= orig.dup;
            } else {
                uint[][uint] repl;
                foreach (s; *subsP) repl[s.oldV] = s.newVs;
                uint[] rebuilt;
                foreach (v; orig) {
                    auto rp = v in repl;
                    if (rp is null) rebuilt ~= v;
                    else            rebuilt ~= *rp;
                }
                newFaces ~= rebuilt;
            }
            newMat  ~= fi < faceMaterial.length       ? faceMaterial[fi]       : 0u;
            newPart ~= fi < facePart.length           ? facePart[fi]           : 0u;
            newOrd  ~= fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0;
            newSub  ~= isFaceSubpatch(cast(uint)fi);
        }

        // (b) cap faces — attrs carried from capSrc, not the chamfer 0u literal
        size_t capStart = newFaces.length;
        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;

            uint[] capRing = capRings[vi].dup;
            int    Ncap    = cast(int)capRing.length;

            // outward-winding check: Newell normal vs averaged incident-face normal
            Vec3 newellN = Vec3(0, 0, 0);
            foreach (k; 0 .. Ncap) {
                Vec3 a = vertices[capRing[k]];
                Vec3 b = vertices[capRing[(k+1)%Ncap]];
                newellN.x += (a.y - b.y) * (a.z + b.z);
                newellN.y += (a.z - b.z) * (a.x + b.x);
                newellN.z += (a.x - b.x) * (a.y + b.y);
            }
            Vec3 avgFaceN = Vec3(0, 0, 0);
            foreach (fi; facesAroundVertex(vi)) {
                Vec3 fn = faceNormal(cast(uint)fi);
                avgFaceN.x += fn.x; avgFaceN.y += fn.y; avgFaceN.z += fn.z;
            }
            float dot = newellN.x*avgFaceN.x +
                        newellN.y*avgFaceN.y +
                        newellN.z*avgFaceN.z;
            if (dot < 0) {
                for (int lo = 0, hi = Ncap - 1; lo < hi; ++lo, --hi) {
                    uint tmp = capRing[lo]; capRing[lo] = capRing[hi]; capRing[hi] = tmp;
                }
            }

            uint srcFi = capSrc[vi];
            newFaces ~= capRing;
            newMat   ~= srcFi < faceMaterial.length ? faceMaterial[srcFi] : 0u;
            newPart  ~= srcFi < facePart.length     ? facePart[srcFi]     : 0u;
            newOrd   ~= 0;
            newSub   ~= isFaceSubpatch(srcFi);
        }

        // (c) commit arrays
        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;

        faceMarks.length = faces.length;
        faceMarks[]      = 0;
        foreach (fi, s; newSub)
            if (s) faceMarks[fi] |= Marks.Subpatch;

        faceSelectionOrderCounter = 0;
        foreach (fi; capStart .. faces.length)
            selectFace(cast(int)fi);
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        rebuildEdges();
        buildLoops();
        compactUnreferenced();
        buildLoops();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }

    /// Return the other endpoint of edge `ei` given one of its vertices `vi`.
    /// In debug builds, asserts that `vi` is actually one of the edge's endpoints.
    pragma(inline, true)
    uint edgeOtherVertex(uint ei, uint vi) const {
        uint a = edges[ei][0];
        uint b = edges[ei][1];
        debug assert(vi == a || vi == b,
                     "edgeOtherVertex: vi does not belong to edge ei");
        return (vi == a) ? b : a;
    }

    /// Return a range over all consecutive vertex pairs (directed edges) of face `fi`.
    FaceEdgeRange faceEdges(uint fi) const { return FaceEdgeRange(faces[fi]); }

    /// Return a range over all vertices directly connected to vertex `vi` by an edge.
    VertexNeighborRange verticesAroundVertex(uint vi) const {
        uint first = (vi < vertLoop.length) ? vertLoop[vi] : ~0u;
        return VertexNeighborRange(loops, first);
    }

    /// Return a range over all edge indices incident to vertex `vi`.
    /// Correctly handles boundary vertices: emits the extra boundary edge at the end.
    /// Requires buildLoops() to have been called (uses vertLoop and loopEdge).
    VertexEdgeRange edgesAroundVertex(uint vi) const {
        uint first = (vi < vertLoop.length) ? vertLoop[vi] : ~0u;
        return VertexEdgeRange(loops, loopEdge, first);
    }

    /// Return a range over all faces incident to vertex `vi`.
    VertexFaceRange facesAroundVertex(uint vi) const {
        uint first = (vi < vertLoop.length) ? vertLoop[vi] : ~0u;
        return VertexFaceRange(loops, first);
    }

    /// Return a range over the 1–2 faces incident to edge `ei`.
    EdgeFaceRange facesAroundEdge(uint ei) const {
        return EdgeFaceRange(loops, edges, vertLoop, ei);
    }

    /// Return a range over all faces that share an edge with face `fi`.
    /// Uses twin links from the half-edge structure — no hash map needed.
    AdjacentFaceRange adjacentFaces(uint fi) const {
        uint start = (fi < faceLoop.length) ? faceLoop[fi] : ~0u;
        return AdjacentFaceRange(loops, start);
    }

    /// Return a rolling FNV-1a hash of the Select bit across the marks array
    /// for edit mode `m` (vertexMarks / edgeMarks / faceMarks). A cheap
    /// per-run change-detector: selection writes bump no version counter, so
    /// callers that need to know "did the selection change since I last
    /// looked" fold this into a cache key alongside `mutationVersion`. Folds
    /// in `marks.length` then one bit per selected index, so both WHICH
    /// elements are selected and HOW MANY are captured. A collision would
    /// only ever produce a stale same-run cache hit — never wrong output —
    /// so this is safe for cache-key use but must never be persisted or
    /// compared across runs. The single canonical replacement for the
    /// formerly-duplicated per-stage `selectionSignature()` copies in
    /// FalloffStage / ActionCenterStage and the older `selectionHash{V,E,F}`
    /// family (a different, weaker `h*31` hash over the same selection).
    ulong selectionSignature(EditMode m) const {
        ulong h = 1469598103934665603UL; // FNV-1a offset basis
        void mix(ulong x) { h ^= x; h *= 1099511628211UL; }
        const(uint)[] marks;
        final switch (m) {
            case EditMode.Vertices: marks = vertexMarks; break;
            case EditMode.Edges:    marks = edgeMarks;   break;
            case EditMode.Polygons: marks = faceMarks;   break;
        }
        mix(marks.length);
        foreach (i, mk; marks)
            if (mk & 1 /*Marks.Select*/) mix(cast(ulong)i + 1);
        return h;
    }

    /// Return the vertex indices touched by the current vertex selection.
    /// If nothing is selected, returns all vertex indices.
    int[] selectedVertexIndicesVertices() const {
        int[] idx;
        if (hasAnySelectedVertices()) {
            foreach (i; 0 .. vertices.length)
                if (isVertexSelected(i)) idx ~= cast(int)i;
        } else {
            foreach (i; 0 .. vertices.length) idx ~= cast(int)i;
        }
        return idx;
    }

    /// Edge (ordered key) → up to 2 incident faces; slot [1] == -1 means the
    /// edge is on the boundary of the CONSIDERED face set. A 3rd+ incident
    /// face and an edge a single face lists twice are ignored (matches the
    /// inline idiom every *ByMask op used before this helper existed).
    ///
    /// Face-set selection (mutually usable):
    ///   * faceLimit — consider only faces [0 .. min(faceLimit, faces.length));
    ///                 default size_t.max = all faces. Reproduces
    ///                 boundaryLoops's prefix limit so an edge shared with a
    ///                 face BEYOND the limit stays correctly "open" within
    ///                 the prefix.
    ///   * faceMask  — when non-empty, additionally require faceMask[fi]; a
    ///                 face with fi >= faceMask.length is skipped.
    ///
    /// PRECONDITION: a length-0 faceMask means "no mask" (all faces), NOT
    /// "select nothing." This is safe for the only masked caller
    /// (selectMergeEdges, reached only when mask.length == faces.length —
    /// its callers guard `mask.length != faces.length` before calling in),
    /// so a length-0 mask reaches here only when faces.length == 0. A future
    /// caller wanting a genuine empty selection must NOT pass a length-0
    /// mask expecting an empty result — it would consider all faces.
    int[2][ulong] buildEdgeFaces(in bool[] faceMask = null,
                                 size_t faceLimit = size_t.max) const {
        int[2][ulong] m;
        const size_t nf = faceLimit < faces.length ? faceLimit : faces.length;
        foreach (fi; 0 .. nf) {
            if (faceMask.length && (fi >= faceMask.length || !faceMask[fi])) continue;
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                ulong key = edgeKeyOrdered(f[k], f[(k+1) % f.length]);
                auto p = key in m;
                if (p is null) m[key] = [cast(int)fi, -1];
                else if ((*p)[1] == -1 && (*p)[0] != cast(int)fi) (*p)[1] = cast(int)fi;
            }
        }
        return m;
    }

    /// Full per-edge incident-face count, indexed like `edges[]` — NOT
    /// capped at 2, unlike `buildEdgeFaces`'s `int[2]` slots which silently
    /// cannot witness a 3rd+ incident face (task 0402 Phase 4 risk #3: a
    /// non-manifold edge shared by ≥3 faces must be detectable, not just
    /// "has a 2nd face"). O(F) using the already-built `edgeIndexMap`.
    /// PRECONDITION: `edgeIndexMap` must already reflect the current
    /// `faces` (i.e. `buildLoops()` has been called since the last topology
    /// edit) — same precondition as `buildEdgeFaces`/`boundaryLoops`. A face
    /// edge whose key is absent from `edgeIndexMap` (stale precondition) is
    /// silently skipped rather than indexing out of bounds.
    uint[] edgeFaceUseCounts() const {
        auto counts = new uint[](edges.length);
        foreach (fi; 0 .. faces.length) {
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                ulong key = edgeKeyOrdered(f[k], f[(k + 1) % f.length]);
                if (auto p = key in edgeIndexMap)
                    if (*p < counts.length) counts[*p]++;
            }
        }
        return counts;
    }

    /// Vertex degree — the number of edges incident on `vi`. O(degree(vi))
    /// via the half-edge ring (`edgesAroundVertex`), so summing this over
    /// every vertex costs O(V + E) total, not O(V²) (task 0402 Phase 4 risk
    /// #1). No existing API exposed this directly before task 0402.
    /// PRECONDITION: same as `edgesAroundVertex` — `buildLoops()` must have
    /// been called since the last topology edit.
    uint vertexValence(uint vi) const {
        uint n = 0;
        foreach (ei; edgesAroundVertex(vi)) ++n;
        return n;
    }

    /// Return, for each edge, the indices of every OTHER edge that shares one
    /// of its two endpoint vertices (relation A: edge→edges-sharing-a-vertex).
    /// Result length == `edges.length`. No dedup pass — two distinct edges
    /// can share at most one vertex, so an edge can never appear twice in
    /// another edge's neighbor list. Order is whatever `edgesAroundVertex`
    /// yields (order-independent for every current consumer — set-building
    /// / BFS reachability). Verbatim body of the private builder formerly
    /// duplicated in `commands/select/expand.d`, `contract.d` and
    /// `connect.d` (all three Edges-mode adjacency loops) — see
    /// `doc/tasks/work/0190-select-adjacency-provider.md`.
    int[][] edgeAdjacencySharingVertex() const {
        int[][] edgeAdj = new int[][](edges.length);
        foreach (i; 0 .. edges.length)
            foreach (vi; edges[i])
                foreach (ni; edgesAroundVertex(vi))
                    if (ni != i) edgeAdj[i] ~= cast(int)ni;
        return edgeAdj;
    }

    /// Return, for each face, the indices of every OTHER face that shares
    /// ≥1 vertex with it (relation C: face→faces-sharing-a-vertex — this
    /// INCLUDES diagonal neighbours, which makes it a different relation
    /// from `adjacentFaces` (edge-adjacent only); do not conflate the two).
    /// Result length == `faces.length`. Verbatim body of the private
    /// builder formerly duplicated in `commands/select/expand.d` and
    /// `contract.d` (Polygons-mode adjacency loops) — see
    /// `doc/tasks/work/0190-select-adjacency-provider.md`.
    int[][] faceAdjacencySharingVertex() const {
        uint[][] vertFaces = new uint[][](vertices.length);
        foreach (fi, face; faces)
            foreach (vi; face)
                vertFaces[vi] ~= cast(uint)fi;

        int[][] faceAdj = new int[][](faces.length);
        foreach (fi, face; faces) {
            bool[int] seen;
            foreach (vi; face)
                foreach (adjFi; vertFaces[vi])
                    if (adjFi != cast(uint)fi && (cast(int)adjFi) !in seen) {
                        seen[cast(int)adjFi] = true;
                        faceAdj[fi] ~= cast(int)adjFi;
                    }
        }
        return faceAdj;
    }

    unittest { // Stage-0 parity golden (0190): providers == old inline builders;
               // CSR order == inline edge-based order (bit-stability guard for
               // smooth.d / smoothSubdivide / updateConnectMask, Stage 3).
        Mesh m = makeCube();

        // --- relation A: edge→edges-sharing-a-vertex, element-wise + per-edge order.
        int[][] edgeAdjInline = new int[][](m.edges.length);
        foreach (i; 0 .. m.edges.length)
            foreach (vi; m.edges[i])
                foreach (ni; m.edgesAroundVertex(vi))
                    if (ni != i) edgeAdjInline[i] ~= cast(int)ni;
        assert(m.edgeAdjacencySharingVertex() == edgeAdjInline,
            "edgeAdjacencySharingVertex must match the inline edge-adjacency "
            ~ "builder element-wise (including per-edge order)");

        // --- relation C: face→faces-sharing-a-vertex, element-wise + per-face order.
        uint[][] vertFacesInline = new uint[][](m.vertices.length);
        foreach (fi, face; m.faces)
            foreach (vi; face)
                vertFacesInline[vi] ~= cast(uint)fi;
        int[][] faceAdjInline = new int[][](m.faces.length);
        foreach (fi, face; m.faces) {
            bool[int] seen;
            foreach (vi; face)
                foreach (adjFi; vertFacesInline[vi])
                    if (adjFi != cast(uint)fi && (cast(int)adjFi) !in seen) {
                        seen[cast(int)adjFi] = true;
                        faceAdjInline[fi] ~= cast(int)adjFi;
                    }
        }
        assert(m.faceAdjacencySharingVertex() == faceAdjInline,
            "faceAdjacencySharingVertex must match the inline face-adjacency "
            ~ "builder element-wise");

        // --- relation D order-equality: CSR neighbor order == the inline
        // `foreach (e; edges) { neighbors[e0]~=e1; neighbors[e1]~=e0; }`
        // order, PER VERTEX. This is the SOLE runtime guarantee (not just a
        // proof-by-inspection) that Stage 3's swap of smooth.d /
        // smoothSubdivide / updateConnectMask's inline vert-neighbor build
        // for `vertexAdjacencyCSR` is bit-identical: float sums accumulate
        // in iteration order, so ORDER (not merely the neighbor SET) must
        // match exactly, or the smoothed positions diverge in the last bit.
        // Checked on two topologies (uniform-valence cube + a subdivided
        // mesh with non-uniform valence) so this is not a single-valence
        // coincidence that a reorder elsewhere in the file could sneak past.
        import std.conv : text;
        static void checkOrderEquality(ref Mesh mm) {
            uint[][] neighborsInline = new uint[][](mm.vertices.length);
            foreach (e; mm.edges) {
                neighborsInline[e[0]] ~= e[1];
                neighborsInline[e[1]] ~= e[0];
            }
            const(size_t)[] off;
            const(uint)[] nbrs;
            mm.vertexAdjacencyCSR(off, nbrs);
            assert(off.length == mm.vertices.length + 1,
                "CSR offset array length must be vertices.length + 1");
            foreach (vi; 0 .. mm.vertices.length) {
                auto csrSlice = nbrs[off[vi] .. off[vi + 1]];
                assert(csrSlice.length == neighborsInline[vi].length,
                    text("CSR neighbor COUNT must match inline edge-based count at vertex ", vi));
                foreach (k; 0 .. csrSlice.length)
                    assert(csrSlice[k] == neighborsInline[vi][k],
                        text("CSR neighbor ORDER must match inline edge-based order at vertex ", vi,
                             " position ", k, " (bit-stability for smooth.d/smoothSubdivide float sums)"));
            }
        }
        checkOrderEquality(m);

        bool[] allMask = new bool[](m.faces.length);
        allMask[] = true;
        Mesh sub = facetedSubdivide(m, allMask);
        checkOrderEquality(sub);
    }

    /// Connected components of every face `fi` where `want[fi]` is true,
    /// via the shared-vertex adjacency relation `faceAdj` (see
    /// `faceAdjacencySharingVertex` above — this deliberately INCLUDES
    /// diagonal-only touches, unlike the shared-EDGE island BFS used by
    /// e.g. `extrudeFacesByMask`; callers that need edge-only islands must
    /// build their own adjacency instead of reusing this one).
    /// `faceAdj.length` must equal `want.length`. Each returned component is
    /// a non-empty, arbitrary-order list of face indices; every face with
    /// `want[fi]==true` appears in exactly one component. A small, generic,
    /// reusable BFS idiom — shared by `fillSelectionHoles` below and (task
    /// 0386) `remesh.remesh_job`'s per-component region split.
    static uint[][] faceComponentsOf(const(bool)[] want, const(int[][]) faceAdj) {
        auto compId = new int[](want.length);
        compId[] = -1;
        uint[][] components;
        foreach (start; 0 .. want.length) {
            if (!want[start] || compId[start] != -1) continue;
            const int cid = cast(int) components.length;
            uint[] comp;
            uint[] stack = [cast(uint) start];
            compId[start] = cid;
            while (stack.length) {
                const uint cur = stack[$ - 1];
                stack = stack[0 .. $ - 1];
                comp ~= cur;
                foreach (nb; faceAdj[cur]) {
                    if (nb < 0 || !want[nb] || compId[nb] != -1) continue;
                    compId[nb] = cid;
                    stack ~= cast(uint) nb;
                }
            }
            components ~= comp;
        }
        return components;
    }

    /// Auto-fill small, fully-enclosed holes in a face selection mask (task
    /// 0386, follow-up to the local quad-remesh's boundary-pinned stitch —
    /// see `remesh.region_stitch`; also planned reuse for a `select.fill.holes`
    /// command, task 0387 — do NOT fork this logic per caller): a user
    /// selecting a CONNECTED patch but missing a few interior faces leaves
    /// those faces as tiny unselected "holes" — extra internal boundary
    /// loops that break downstream region operations expecting a single
    /// outer boundary (region_stitch failed with "patch has fewer boundary
    /// loops than the region" on exactly this shape of selection).
    ///
    /// An unselected connected component (shared-VERTEX flood fill via
    /// `faceComponentsOf`/`faceAdjacencySharingVertex`) is folded INTO the
    /// selection iff:
    ///   (a) it is fully enclosed — every one of its boundary edges borders
    ///       a SELECTED face, never the mesh's own open boundary; and
    ///   (b) its face count is strictly less than the number of originally
    ///       selected faces, so the "rest of the model" component can never
    ///       be swallowed by an inverted/near-total selection.
    /// Returns a NEW mask (same length as `faces`); `selectedFaceMask` is
    /// read-only. A folded-in hole is real mesh geometry reclassified from
    /// keep to region — nothing is synthesized.
    bool[] fillSelectionHoles(const(bool)[] selectedFaceMask) const {
        const size_t nf = faces.length;
        auto mask = new bool[](nf);
        foreach (fi; 0 .. nf) mask[fi] = fi < selectedFaceMask.length && selectedFaceMask[fi];

        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0 || selCount >= nf) return mask; // nothing to fill

        auto faceAdj   = faceAdjacencySharingVertex();
        auto edgeFaces = buildEdgeFaces();

        auto unselected = new bool[](nf);
        foreach (fi; 0 .. nf) unselected[fi] = !mask[fi];
        auto holes = faceComponentsOf(unselected, faceAdj);

        const(uint[])[] allFaces = faces.range;
        foreach (comp; holes) {
            if (comp.length >= selCount) continue; // would swallow the rest of the model

            bool enclosed = true;
            outer: foreach (fi; comp) {
                auto face = allFaces[fi];
                const size_t n = face.length;
                foreach (k; 0 .. n) {
                    const ulong key = edgeKeyOrdered(face[k], face[(k + 1) % n]);
                    auto p = key in edgeFaces;
                    if (p is null) continue; // shouldn't happen — defensive
                    const int other = (*p)[0] == cast(int) fi ? (*p)[1] : (*p)[0];
                    // -1 = the mesh's own open boundary. A same-component
                    // unselected neighbour can never appear here: sharing a
                    // full EDGE implies sharing a vertex, so it would
                    // already be part of THIS component (shared-vertex
                    // flood fill), not a different one.
                    if (other == -1 || !mask[other]) { enclosed = false; break outer; }
                }
            }
            if (enclosed) foreach (fi; comp) mask[fi] = true;
        }

        return mask;
    }

    unittest {
        // fillSelectionHoles: a CONNECTED 4x4 block selection missing ONE
        // interior face leaves a single-face "hole" -- fully enclosed by
        // the selection, far smaller than it -- which must be folded back
        // in, collapsing the selection to a single connected component.
        auto m = makeGridPlane(6);
        assert(m.faces.length == 36);

        bool[] mask = new bool[](36);
        foreach (i; 1 .. 5) foreach (j; 1 .. 5)
            if (!(i == 2 && j == 3)) mask[i * 6 + j] = true;
        assert(!mask[2 * 6 + 3]);

        size_t selBefore = 0;
        foreach (b; mask) if (b) ++selBefore;
        assert(selBefore == 15);

        auto filled = m.fillSelectionHoles(mask);
        assert(filled[2 * 6 + 3], "the fully-enclosed single-face hole must be filled");

        size_t selAfter = 0;
        foreach (b; filled) if (b) ++selAfter;
        assert(selAfter == 16, "exactly the one missing face should be added back");

        auto faceAdj = m.faceAdjacencySharingVertex();
        auto comps = Mesh.faceComponentsOf(filled, faceAdj);
        assert(comps.length == 1, "the filled 4x4 block must be a single connected component");
    }

    unittest {
        // fillSelectionHoles: the "rest of the model" component (>= selCount)
        // must never be swallowed, even on a CLOSED mesh where it has no
        // open boundary at all (so the enclosure check alone would
        // otherwise pass).
        auto m = makeCube();
        bool[] mask = new bool[](m.faces.length);
        mask[0] = true; // select just 1 of the cube's 6 faces
        auto filled = m.fillSelectionHoles(mask);
        size_t selAfter = 0;
        foreach (b; filled) if (b) ++selAfter;
        assert(selAfter == 1, "a single selected face on a closed mesh must NOT swallow the other 5");
    }

    unittest {
        // fillSelectionHoles: two disjoint selected blocks separated by a
        // wide unselected gap (which also touches the mesh's own open
        // boundary -- not enclosed, and far larger than either block) must
        // be left completely alone, then split into 2 components.
        auto m = makeGridPlane(10);
        bool[] mask = new bool[](100);
        foreach (i; 1 .. 3) foreach (j; 1 .. 3) mask[i * 10 + j] = true; // block A, 2x2
        foreach (i; 6 .. 8) foreach (j; 6 .. 8) mask[i * 10 + j] = true; // block B, 2x2

        auto filled = m.fillSelectionHoles(mask);
        assert(filled == mask, "no small enclosed hole exists -- mask must be unchanged");

        auto faceAdj = m.faceAdjacencySharingVertex();
        auto comps = Mesh.faceComponentsOf(filled, faceAdj);
        assert(comps.length == 2, "two disjoint blocks must split into 2 connected components");
    }

    /// Return the vertex indices touched by the current edge selection.
    /// Each vertex is included at most once.
    /// If nothing is selected, returns all vertex indices.
    int[] selectedVertexIndicesEdges() const {
        int[] idx;
        if (hasAnySelectedEdges()) {
            bool[] added = new bool[](vertices.length);
            foreach (i, edge; edges) {
                if (!isEdgeSelected(i)) continue;
                if (!added[edge[0]]) { added[edge[0]] = true; idx ~= cast(int)edge[0]; }
                if (!added[edge[1]]) { added[edge[1]] = true; idx ~= cast(int)edge[1]; }
            }
        } else {
            foreach (i; 0 .. vertices.length) idx ~= cast(int)i;
        }
        return idx;
    }

    /// Return the vertex indices touched by the current face selection.
    /// Each vertex is included at most once.
    /// If nothing is selected, returns all vertex indices.
    int[] selectedVertexIndicesFaces() const {
        int[] idx;
        if (hasAnySelectedFaces()) {
            bool[] added = new bool[](vertices.length);
            foreach (i, face; faces) {
                if (!isFaceSelected(i)) continue;
                foreach (vi; face)
                    if (!added[vi]) { added[vi] = true; idx ~= cast(int)vi; }
            }
        } else {
            foreach (i; 0 .. vertices.length) idx ~= cast(int)i;
        }
        return idx;
    }

    /// Return the centroid of the current vertex selection (or all vertices if none selected).
    Vec3 selectionCentroidVertices() const {
        bool any = hasAnySelectedVertices();
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        foreach (i, v; vertices) {
            if (!any || isVertexSelected(i)) {
                sum += v;
                count++;
            }
        }
        return count > 0 ? sum / cast(float)count : Vec3(0, 0, 0);
    }

    /// Return the centroid of vertices belonging to the current edge selection
    /// (or all edge vertices if none selected).  Each vertex is counted once.
    Vec3 selectionCentroidEdges() const {
        bool any = hasAnySelectedEdges();
        bool[] vis = new bool[](vertices.length);
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        foreach (i, edge; edges) {
            if (any && !isEdgeSelected(i)) continue;
            foreach (vi; edge) {
                if (!vis[vi]) {
                    sum += vertices[vi];
                    count++;
                    vis[vi] = true;
                }
            }
        }
        return count > 0 ? sum / cast(float)count : Vec3(0, 0, 0);
    }

    /// Return the centroid of vertices belonging to the current face selection
    /// (or all face vertices if none selected).  Each vertex is counted once.
    Vec3 selectionCentroidFaces() const {
        bool any = hasAnySelectedFaces();
        bool[] vis = new bool[](vertices.length);
        Vec3 sum = Vec3(0, 0, 0);
        int  count = 0;
        foreach (i, face; faces) {
            if (any && !isFaceSelected(i)) continue;
            foreach (vi; face) {
                if (!vis[vi]) {
                    sum += vertices[vi];
                    count++;
                    vis[vi] = true;
                }
            }
        }
        return count > 0 ? sum / cast(float)count : Vec3(0, 0, 0);
    }

    // ---- BBOX CENTER variants ------------------------------------------
    //
    // Same selection logic as `selectionCentroid*` but return (min+max)/2
    // per axis instead of the vertex-position mean. Used by ACEN.Select /
    // .Border / .Auto for the empirical "selection-center" pivot, which
    // is the bounding-box midpoint of the selected verts (not the vertex
    // average). For symmetric selections the two coincide; only
    // asymmetric / clustered selections distinguish them. Phase 2 of the
    // action-center parity plan.

    Vec3 selectionBBoxCenterVertices() const {
        bool any = hasAnySelectedVertices();
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (i, v; vertices) {
            if (any && !isVertexSelected(i)) continue;
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            seen = true;
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    /// Selection bbox extent (min, max) along world axes. Falls back
    /// to the whole geometry when nothing is selected, mirroring the
    /// `selectionBBoxCenter*` family. `seen` is false only on an
    /// empty mesh — caller can synthesise a sensible default. Used by
    /// the FalloffStage's auto-size path (phase 7.5).
    void selectionBBoxMinMaxVertices(out Vec3 mn, out Vec3 mx, out bool seen) const {
        bool any = hasAnySelectedVertices();
        mn = Vec3(float.infinity, float.infinity, float.infinity);
        mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        seen = false;
        foreach (i, v; vertices) {
            if (any && !isVertexSelected(i)) continue;
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
            seen = true;
        }
    }

    void selectionBBoxMinMaxEdges(out Vec3 mn, out Vec3 mx, out bool seen) const {
        bool any = hasAnySelectedEdges();
        bool[] vis = new bool[](vertices.length);
        mn = Vec3(float.infinity, float.infinity, float.infinity);
        mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        seen = false;
        foreach (i, edge; edges) {
            if (any && !isEdgeSelected(i)) continue;
            foreach (vi; edge) {
                if (vis[vi]) continue;
                vis[vi] = true;
                Vec3 v = vertices[vi];
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
                seen = true;
            }
        }
    }

    void selectionBBoxMinMaxFaces(out Vec3 mn, out Vec3 mx, out bool seen) const {
        bool any = hasAnySelectedFaces();
        bool[] vis = new bool[](vertices.length);
        mn = Vec3(float.infinity, float.infinity, float.infinity);
        mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        seen = false;
        foreach (i, face; faces) {
            if (any && !isFaceSelected(i)) continue;
            foreach (vi; face) {
                if (vis[vi]) continue;
                vis[vi] = true;
                Vec3 v = vertices[vi];
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
                seen = true;
            }
        }
    }

    Vec3 selectionBBoxCenterEdges() const {
        bool any = hasAnySelectedEdges();
        bool[] vis = new bool[](vertices.length);
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (i, edge; edges) {
            if (any && !isEdgeSelected(i)) continue;
            foreach (vi; edge) {
                if (vis[vi]) continue;
                vis[vi] = true;
                Vec3 v = vertices[vi];
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
                seen = true;
            }
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    Vec3 selectionBBoxCenterFaces() const {
        bool any = hasAnySelectedFaces();
        bool[] vis = new bool[](vertices.length);
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (i, face; faces) {
            if (any && !isFaceSelected(i)) continue;
            foreach (vi; face) {
                if (vis[vi]) continue;
                vis[vi] = true;
                Vec3 v = vertices[vi];
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
                seen = true;
            }
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    /// Bounding-box center of the selection's BORDER vertices — verts on
    /// edges with exactly one selected adjacent face and at least one
    /// unselected adjacent face. For a cube top face this is the
    /// perimeter (same as `selectionBBoxCenterFaces`); for a sphere top
    /// hemisphere it's only the equator ring (the inner verts are NOT
    /// on a border edge). This is `actr.border` semantics.
    /// Falls back to `selectionBBoxCenterFaces` when there's no border
    /// edge (every selected face's edges are also adjacent to other
    /// selected faces — closed selection on a closed manifold).
    Vec3 selectionBorderBBoxCenterFaces() const {
        if (!hasAnySelectedFaces()) return Vec3(0, 0, 0);
        bool[] onBorder = new bool[](vertices.length);
        bool   any      = false;
        // For each edge, count selected and unselected adjacent faces.
        foreach (ei; 0 .. cast(uint)edges.length) {
            int sel = 0, unsel = 0;
            foreach (fi; facesAroundEdge(ei)) {
                if (isFaceSelected(fi)) sel++;
                else                    unsel++;
            }
            if (sel == 1 && unsel >= 1) {
                onBorder[edges[ei][0]] = true;
                onBorder[edges[ei][1]] = true;
                any = true;
            }
        }
        if (!any) return selectionBBoxCenterFaces();
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        foreach (vi, on; onBorder) if (on) {
            Vec3 v = vertices[vi];
            if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
            if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
            if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
        }
        return (mn + mx) * 0.5f;
    }

    /// Return the centroid (average position) of face `fi`.
    Vec3 faceCentroid(uint fi) const {
        const uint[] face = faces[fi];
        Vec3 s = Vec3(0, 0, 0);
        foreach (vi; face) s += vertices[vi];
        float inv = 1.0f / cast(float)face.length;
        return s * inv;
    }

    /// Return a bool mask (indexed by vertex index) where `true` means the vertex
    /// belongs to at least one front-facing face AND is not occluded by any
    /// other front-facing face along the eye→vertex ray.
    ///
    /// A face is front-facing when its normal points toward the camera
    /// (dot(normal, face[0] - eye) < 0). Occlusion is tested by ray-casting
    /// from the eye through each candidate vertex against every other
    /// front-facing face: if the ray crosses a face's plane inside its
    /// polygon at a smaller t than the vertex distance, the vertex is hidden
    /// behind that face. Used by pickVertices / pickEdges and the RMB lasso
    /// path so neither picks elements behind opaque geometry — including
    /// disjoint mesh components in the same Mesh struct (cube + cube,
    /// cube + cylinder, etc.).
    ///
    /// `vp` is used to prune occluder candidates by screen-space bbox: a face
    /// can occlude a vertex only if the vertex's projected pixel falls inside
    /// the face's screen bounding rectangle. For scenes with non-overlapping
    /// components (the common case) this drops the cost from O(V·F) toward
    /// O(V + F). Inside the bbox, point-in-polygon and the depth check are
    /// done in screen space (using already-projected face corners), avoiding
    /// the per-iteration 3D-to-2D dominant-axis projection of the original
    /// implementation.
    bool[] visibleVertices(Vec3 eye, const ref Viewport vp) const {
        import math : pointInPolygon2D, projectToWindowFull;
        import std.math : abs;

        bool[] vis = new bool[](vertices.length);
        if (vertices.length == 0 || faces.length == 0) return vis;

        // Project every vertex once. Behind-camera verts get vsValid=false
        // and skip both candidate selection and occluder polygon membership.
        auto vsx     = new float[](vertices.length);
        auto vsy     = new float[](vertices.length);
        auto vsZ     = new float[](vertices.length);
        auto vsValid = new bool [](vertices.length);
        foreach (vi, q; vertices) {
            float sx, sy, ndcZ;
            if (projectToWindowFull(q, vp, sx, sy, ndcZ)) {
                vsx[vi] = sx; vsy[vi] = sy; vsZ[vi] = ndcZ;
                vsValid[vi] = true;
            }
        }

        // Pass 1: collect front-facing faces with cached screen polygons +
        // bboxes, and seed the visibility mask.
        struct FrontFace {
            uint    fi;
            Vec3    n;             // face plane normal (un-normalised, fine for ray-plane)
            float   minX, maxX, minY, maxY;
            float[] sxs, sys;      // screen-space corner positions
        }
        FrontFace[] front;
        front.reserve(faces.length);
        foreach (fi, ref face; faces) {
            if (face.length < 3) continue;
            Vec3 fn = cross(vertices[face[1]] - vertices[face[0]],
                            vertices[face[2]] - vertices[face[0]]);
            if (dot(fn, vertices[face[0]] - eye) >= 0) continue;
            foreach (vi; face) vis[vi] = true;

            float mnx = float.infinity, mxx = -float.infinity;
            float mny = float.infinity, mxy = -float.infinity;
            auto sxs = new float[](face.length);
            auto sys = new float[](face.length);
            bool anyValid = false;
            foreach (i, vk; face) {
                if (!vsValid[vk]) continue;
                anyValid = true;
                sxs[i] = vsx[vk]; sys[i] = vsy[vk];
                if (vsx[vk] < mnx) mnx = vsx[vk];
                if (vsx[vk] > mxx) mxx = vsx[vk];
                if (vsy[vk] < mny) mny = vsy[vk];
                if (vsy[vk] > mxy) mxy = vsy[vk];
            }
            // A face with any corner behind the camera can't reliably act as
            // an occluder via screen-space tests — skip it. Vertex-on-face
            // candidacy was already seeded above, so nothing is lost.
            if (!anyValid) continue;
            bool allValid = true;
            foreach (vk; face) if (!vsValid[vk]) { allValid = false; break; }
            if (!allValid) continue;

            front ~= FrontFace(cast(uint)fi, fn, mnx, mxx, mny, mxy, sxs, sys);
        }

        // Pass 2: per candidate vertex, walk only those front faces whose
        // screen bbox contains the vertex's projected pixel; do screen-space
        // point-in-polygon, then a 3D ray-plane depth test to confirm the
        // face is actually closer to the eye. Faces that own the vertex are
        // skipped (their plane passes through the vertex; FP noise near t=1
        // is also handled by the (1 - ε) cutoff).
        enum float OCCL_EPS = 1e-4f;
        foreach (vi; 0 .. vertices.length) {
            if (!vis[vi] || !vsValid[vi]) continue;
            float vsxi = vsx[vi], vsyi = vsy[vi];
            Vec3  vpos = vertices[vi];
            Vec3  dir  = vpos - eye;

            foreach (ref ff; front) {
                if (vsxi < ff.minX || vsxi > ff.maxX ||
                    vsyi < ff.minY || vsyi > ff.maxY) continue;

                const(uint)[] face = faces[ff.fi];
                bool ownsVi = false;
                foreach (v; face) if (v == vi) { ownsVi = true; break; }
                if (ownsVi) continue;

                if (!pointInPolygon2D(vsxi, vsyi, ff.sxs, ff.sys)) continue;

                float denom = dot(ff.n, dir);
                if (abs(denom) < 1e-9f) continue;
                float t = dot(ff.n, vertices[face[0]] - eye) / denom;
                if (t <= 0.0f || t >= 1.0f - OCCL_EPS) continue;

                vis[vi] = false;
                break;
            }
        }
        return vis;
    }

    /// Return the canonical edge key for edge `ei` (order-independent hash of its two vertices).
    pragma(inline, true)
    ulong edgeKeyOf(uint ei) const {
        return edgeKey(edges[ei][0], edges[ei][1]);
    }

    /// Return the index in `edges[]` of the edge connecting vertices `a` and `b`.
    /// Returns `~0u` if no such edge exists.  O(1) via `edgeIndexMap`.
    pragma(inline, true)
    uint edgeIndex(uint a, uint b) const {
        if (auto p = edgeKey(a, b) in edgeIndexMap) return *p;
        return ~0u;
    }

    /// Same as `edgeIndex` but accepts a pre-computed canonical key.
    pragma(inline, true)
    uint edgeIndexByKey(ulong key) const {
        if (auto p = key in edgeIndexMap) return *p;
        return ~0u;
    }

    // -----------------------------------------------------------------------
    // Quad-loop / ring helpers
    // -----------------------------------------------------------------------

    /// Given edge `ei` and one of its incident faces `fi`, return the index of
    /// the other face sharing `ei`.  Returns -1 if `ei` is a boundary edge.
    int adjacentFaceThrough(uint ei, uint fi) const {
        foreach (f; facesAroundEdge(ei))
            if (f != fi) return cast(int)f;
        return -1;
    }

    /// Find the winding-order position of the edge with canonical key `ek` in
    /// face `fi`.  Returns -1 if not found.
    int findEdgeInFace(uint fi, ulong ek) const {
        const face = faces[fi];
        for (int j = 0; j < cast(int)face.length; j++)
            if (edgeKey(face[j], face[(j+1) % face.length]) == ek) return j;
        return -1;
    }

    /// Reconnect the shared edge of two adjacent triangles or quads to the other
    /// diagonal of the combined boundary polygon.  Returns true iff the mesh was
    /// mutated.
    ///
    /// Supported pairs: tri–tri (n=3) and quad–quad (n=4).
    /// Quad direction: new diagonal = (c, e) where c = successor-of-b in f1 and
    ///   e = successor-of-a in f2.  This is the vibe3d default (vibe3d-divergence;
    ///   Phase-0 reference capture deferred — see doc/spin_quads_plan.md).
    ///   Period: 2 for tri pairs, 3 for quad pairs (a second spin advances to the
    ///   (d,f) diagonal, not back to the original).
    ///
    /// Guards (all → false, no crash):
    ///   - `ei` out of range.
    ///   - Edge not shared by exactly 2 faces (boundary or non-manifold).
    ///   - Faces have different lengths, or length ∉ {3, 4} (mixed or n-gon pair).
    ///   - Any two of the 2n boundary vertices coincide (covers fold-over and the
    ///     "two faces share two edges" non-manifold cases such as d==e or c==f).
    ///   - Prospective new diagonal c–e already exists in the mesh (fold-over guard).
    ///
    /// Vertex count never changes; only face vertex lists and the derived
    /// edge + half-edge structure are rewritten.
    bool spinEdge(uint ei) {
        if (ei >= edges.length) return false;

        // Collect at most 2 incident faces (EdgeFaceRange cap).
        uint[2] incFaces;
        uint nFaces = 0;
        foreach (fi; facesAroundEdge(ei)) incFaces[nFaces++] = fi;
        if (nFaces != 2) return false;   // boundary or non-manifold

        uint f1i = incFaces[0], f2i = incFaces[1];

        // Support n∈{3,4} pairs only; both faces must have equal length.
        uint n = cast(uint)faces[f1i].length;
        if (faces[f2i].length != n || (n != 3 && n != 4)) return false;

        uint a = edges[ei][0], b = edges[ei][1];
        ulong ek = edgeKey(a, b);

        int j1 = findEdgeInFace(f1i, ek);
        int j2 = findEdgeInFace(f2i, ek);
        if (j1 < 0 || j2 < 0) return false;  // shouldn't happen, defensive

        // Orient so f1i traverses a→b (faces[f1i][j1] == a).
        // findEdgeInFace guarantees faces[f1i][j1] ∈ {a, b}.
        if (faces[f1i][j1] == b) {
            uint tmp = f1i; f1i = f2i; f2i = tmp;
            int jtmp = j1; j1 = j2; j2 = jtmp;
        }
        // Invariant after possible swap:
        //   faces[f1i][j1]         == a   (a→b dart in f1)
        //   faces[f1i][(j1+1)%n]   == b
        //   faces[f2i][j2]         == b   (b→a dart in f2)
        //   faces[f2i][(j2+1)%n]   == a

        uint c = faces[f1i][(j1 + 2) % n];   // successor of b in f1  (= p for n=3)
        uint e = faces[f2i][(j2 + 2) % n];   // successor of a in f2  (= q for n=3)
        uint d  = (n == 4) ? faces[f1i][(j1 + 3) % n] : 0;  // pred of a in f1 (quad)
        uint f_ = (n == 4) ? faces[f2i][(j2 + 3) % n] : 0;  // pred of b in f2 (quad)

        // Guard: all 2n boundary vertices must be distinct.
        //   For n=3: reduces to c≠e (the only degenerate mode).
        //   For n=4: covers c==e AND the "two faces share two edges" cases such as
        //            d==e or c==f_ that pass nFaces==2 but build repeated-vertex faces.
        if (n == 3) {
            if (c == e) return false;
        } else {
            uint[6] bv = [a, b, c, d, e, f_];
            foreach (ii; 0 .. 6)
                foreach (jj; ii + 1 .. 6)
                    if (bv[ii] == bv[jj]) return false;
        }

        // Fold-over guard: prospective new diagonal c–e must not already exist.
        if (edgeIndex(c, e) != ~0u) return false;

        // Build new face pair; new shared diagonal = c–e.
        if (n == 3) {
            // Tri–tri: reproduces prior [p,a,q] / [q,b,p] with c=p, e=q.
            faces[f1i] = [c, a, e];
            faces[f2i] = [e, b, c];
        } else {
            // Quad–quad: hexagon boundary [a,e,f_,b,c,d]; split by diagonal c–e.
            // Direction: (c,e) is the vibe3d default (vibe3d-divergence;
            // Phase-0 reference capture deferred).
            faces[f1i] = [c, d, a, e];
            faces[f2i] = [e, f_, b, c];
        }

        rebuildEdges();
        buildLoops();
        commitChange(MeshEditScope.Geometry);
        return true;
    }

    /// Walk an edge loop starting from `startEdge` in the direction given by
    /// `startFace`.  Returns ordered edge indices; `startEdge` is first.
    /// Stops at non-quad faces, boundaries, or when the loop closes.
    int[] walkEdgeLoop(int startEdge, int startFace) const {
        if (startFace < 0 || startFace >= cast(int)faces.length) return [];
        const sfv = faces[startFace];
        if (sfv.length != 4) return [];
        int si = findEdgeInFace(cast(uint)startFace, edgeKeyOf(cast(uint)startEdge));
        if (si < 0) return [];
        uint a = sfv[si], b = sfv[(si+1)%4];
        int curEdge = startEdge, curFace = startFace;
        int[] res; bool[ulong] vis;
        while (true) {
            ulong ck = edgeKey(a, b);
            if (ck in vis) break;
            vis[ck] = true;
            res ~= curEdge;
            const face = faces[curFace];
            if (face.length != 4) break;
            int jb = -1;
            for (int j = 0; j < 4; j++) if (face[j] == b) { jb = j; break; }
            if (jb < 0) break;
            uint prev = face[(jb-1+4)%4], next = face[(jb+1)%4], c;
            if      (prev == a) c = next;
            else if (next == a) c = prev;
            else break;
            uint sei = edgeIndex(b, c); if (sei == ~0u) break;
            int nf = adjacentFaceThrough(sei, cast(uint)curFace); if (nf < 0) break;
            const nface = faces[nf];
            if (nface.length != 4) break;
            int jb2 = -1;
            for (int j = 0; j < 4; j++) if (nface[j] == b) { jb2 = j; break; }
            if (jb2 < 0) break;
            uint p2 = nface[(jb2-1+4)%4], n2 = nface[(jb2+1)%4], d;
            if      (p2 == c) d = n2;
            else if (n2 == c) d = p2;
            else break;
            uint bd_ei = edgeIndex(b, d); if (bd_ei == ~0u) break;
            a = b; b = d; curEdge = cast(int)bd_ei; curFace = nf;
        }
        return res;
    }

    /// Walk a vertex loop in the direction `startVert`→`nextVert`.
    /// Returns ordered vertex indices starting with `startVert`.
    /// Stops at non-quad faces, boundaries, or when the loop closes.
    uint[] walkVertexLoop(uint startVert, uint nextVert) const {
        uint sei = edgeIndex(startVert, nextVert);
        if (sei == ~0u) return [];
        int startFace = -1;
        foreach (fi; facesAroundEdge(sei)) {
            const fv = faces[fi];
            if (fv.length != 4) continue;
            for (int j = 0; j < 4; j++)
                if (fv[j] == startVert && fv[(j+1)%4] == nextVert) { startFace = cast(int)fi; break; }
            if (startFace >= 0) break;
        }
        if (startFace < 0) return [];
        uint a = startVert, b = nextVert;
        int curFace = startFace;
        uint[] res; bool[ulong] vis;
        while (true) {
            ulong ck = edgeKey(a, b);
            if (ck in vis) break;
            vis[ck] = true;
            res ~= a;
            const face = faces[curFace];
            if (face.length != 4) break;
            int jb = -1;
            for (int j = 0; j < 4; j++) if (face[j] == b) { jb = j; break; }
            if (jb < 0) break;
            uint prev = face[(jb-1+4)%4], next = face[(jb+1)%4], c;
            if      (prev == a) c = next;
            else if (next == a) c = prev;
            else break;
            uint seis = edgeIndex(b, c); if (seis == ~0u) break;
            int nf = adjacentFaceThrough(seis, cast(uint)curFace); if (nf < 0) break;
            const nface = faces[nf];
            if (nface.length != 4) break;
            int jb2 = -1;
            for (int j = 0; j < 4; j++) if (nface[j] == b) { jb2 = j; break; }
            if (jb2 < 0) break;
            uint p2 = nface[(jb2-1+4)%4], n2 = nface[(jb2+1)%4], d;
            if      (p2 == c) d = n2;
            else if (n2 == c) d = p2;
            else break;
            a = b; b = d; curFace = nf;
        }
        return res;
    }

    /// Walk a face loop entered via `entryKey` into `startFace`.
    /// Returns ordered face indices; `startFace` is first.
    int[] walkFaceLoop(int startFace, ulong entryKey) const {
        int[] res; bool[int] vis;
        int cur = startFace; ulong entry = entryKey;
        while (true) {
            if (cur in vis) break;
            vis[cur] = true;
            res ~= cur;
            const face = faces[cur];
            if (face.length != 4) break;
            int ei = findEdgeInFace(cast(uint)cur, entry);
            if (ei < 0) break;
            ulong oppKey = edgeKey(face[(ei+2)%4], face[(ei+3)%4]);
            uint opp_idx = edgeIndexByKey(oppKey);
            if (opp_idx == ~0u) break;
            int nf = adjacentFaceThrough(opp_idx, cast(uint)cur);
            if (nf < 0) break;
            cur = nf; entry = oppKey;
        }
        return res;
    }

    /// Walk an edge ring starting from `startEdge` in the direction given by
    /// `startFace`.  Returns the opposite edge indices encountered at each quad.
    /// The starting edge itself is NOT included — the caller handles it.
    int[] walkEdgeRing(int startEdge, int startFace) const {
        int[] res; bool[int] vis;
        int curFace = startFace;
        ulong curKey = edgeKeyOf(cast(uint)startEdge);
        while (true) {
            if (curFace in vis) break;
            const face = faces[curFace];
            if (face.length != 4) break;
            int j = findEdgeInFace(cast(uint)curFace, curKey);
            if (j < 0) break;
            vis[curFace] = true;
            int oppJ = (j+2)%4;
            ulong oppKey = edgeKey(face[oppJ], face[(oppJ+1)%4]);
            uint opp_ei = edgeIndexByKey(oppKey);
            if (opp_ei == ~0u) break;
            res ~= cast(int)opp_ei;
            int nf = adjacentFaceThrough(opp_ei, cast(uint)curFace);
            if (nf < 0) break;
            curFace = nf; curKey = oppKey;
        }
        return res;
    }

    // Loop-slice ring walk + insertion kernel family (loopSliceRingEdges /
    // collectEdgeRing / insertEdgeLoops / insertEdgeLoopsMulti) + capShellCycles
    // — see source/mesh_ops/loop_slice.d (task 0417, 0407 §B.V2).
    mixin MeshLoopSliceOps;

    /// Return an input range over all loop indices (darts) incident to vertex `vi`.
    /// Each yielded value is a uint loop index `li` with `loops[li].vert == vi`.
    /// Traversal follows twin(prev(li)); stops at a boundary or a full circle.
    /// If `startLi == ~0u`, uses `vertLoop[vi]` as the first dart.
    /// Returns an empty range when the vertex is isolated (vertLoop[vi] == ~0u).
    VertexDartRange dartsAroundVertex(uint vi, uint startLi = ~0u) const {
        uint first = (startLi != ~0u) ? startLi : vertLoop[vi];
        debug if (first != ~0u)
            assert(loops[first].vert == vi,
                   "dartsAroundVertex: startLi does not belong to vertex vi");
        return VertexDartRange(loops, first);
    }

    /// Rebuild the half-edge loop structure from the current faces/vertices.
    /// Must be called after any topology change (addFace, catmullClark, bevel, etc.).
    ///
    /// `rebuildEdgeIndexMap`: when true (default), repopulates the
    /// undirected edgeKey → edge index `edgeIndexMap` AA — required
    /// for callers that read `edgeIndexMap` directly or call
    /// `edgeIndex` / `edgeIndexByKey`. When false, leaves the AA
    /// empty and uses a one-shot sorted-array binary search for the
    /// internal `loopEdge[]` fill. Used by the subpatch preview
    /// build (subpatch_osd.OsdAccel.buildPreview) where nothing
    /// outside Mesh ever queries `edgeIndexMap` on the preview mesh
    /// — at 786K preview edges the AA build costs ~10% of CPU.
    void buildLoops(bool rebuildEdgeIndexMap = true) {

        // Pre-compute total loop count + per-face start offset in one
        // pass. Lets pass 1 below run in parallel — each face writes
        // to a disjoint loops[faceLoop[fi] .. faceLoop[fi]+N] slice.
        faceLoop.length = faces.length;
        size_t total = 0;
        foreach (fi, f; faces) {
            faceLoop[fi] = cast(uint)total;
            total += f.length;
        }

        loops.length    = total;
        vertLoop.length = vertices.length;
        loopEdge.length = total;

        // Initialise sentinels in bulk (the SIMD-friendly default is
        // ~0u, which is the boundary marker for `twin` and the
        // missing-edge marker for loopEdge).
        vertLoop[] = ~0u;
        loopEdge[] = ~0u;

        // Pass 1: fill vert, face, next, prev. Independent across
        // faces — each writes to its own slice of `loops`. Skip
        // vertLoop seeding inside the parallel body (it's a shared
        // write to the same vert from multiple faces, which races on
        // last-writer-wins; do it in a separate serial pass for
        // determinism).
        enum size_t PARALLEL_BUILD_MIN = 4096;
        void fillOneFace(size_t fi) {
            auto face = faces[fi];
            uint li = faceLoop[fi];
            uint N = cast(uint)face.length;
            foreach (i; 0 .. N) {
                loops[li + i].vert = face[i];
                loops[li + i].face = cast(uint)fi;
                loops[li + i].next = li + (i + 1) % N;
                loops[li + i].prev = li + (i + N - 1) % N;
                loops[li + i].twin = ~0u;
            }
        }
        if (faces.length >= PARALLEL_BUILD_MIN) {
            foreach (fi; parallel(iota(faces.length))) fillOneFace(fi);
        } else {
            foreach (fi; 0 .. faces.length) fillOneFace(fi);
        }

        // Serial vertLoop seed pass — every loop writes vertLoop[its vert].
        foreach (idx; 0 .. total) {
            vertLoop[loops[idx].vert] = cast(uint)idx;
        }


        // Pass 2: fill loopEdge[] for every half-edge by looking up
        // its undirected edge index.
        //
        // P2 (doc/subpatch_tab_perf_plan.md): the AA `edgeIndexMap`
        // was the dominant hot symbol at 786K preview edges (build +
        // parallel reads ≈ 14% of CPU). Two paths:
        //
        //   rebuildEdgeIndexMap=true (default, cage mesh ops):
        //       Same as before — rebuild AA, then parallel `in`
        //       reads. External callers (bevel, subpatch_osd's cage
        //       reads, edgeIndex/edgeIndexByKey) need the AA, so we
        //       still pay this on the cage. Cage edge count is
        //       small (≈12 for a cube, ≤ few K for typical meshes).
        //
        //   rebuildEdgeIndexMap=false (subpatch preview path):
        //       Build a one-shot sorted (key, idx) view, use
        //       parallel binary-search lookups, leave edgeIndexMap
        //       empty. At 786K edges binary search (≈20 cmps) is
        //       comparable to AA hash + open-addressing probes, but
        //       allocation-bounded — no per-entry GC hits.
        if (rebuildEdgeIndexMap) {
            edgeIndexMap = null;
            foreach (i, e; edges) edgeIndexMap[edgeKey(e[0], e[1])] = cast(uint)i;
            void fillLoopEdge(size_t idx) {
                uint u = loops[idx].vert;
                uint v = loops[loops[idx].next].vert;
                if (auto p = edgeKey(u, v) in edgeIndexMap)
                    loopEdge[idx] = *p;
            }
            if (total >= PARALLEL_BUILD_MIN) {
                foreach (idx; parallel(iota(total))) fillLoopEdge(idx);
            } else {
                foreach (idx; 0 .. total) fillLoopEdge(idx);
            }
        } else {
            // CSR-style vertex→edge adjacency. Two passes over edges,
            // both linear. Per-lookup cost: walk the (small, hot)
            // incidence list of one endpoint. On a quad mesh that's
            // ~4 candidate edges per vertex.
            buildLoopsEdgesAdjStart .length = vertices.length + 1;
            buildLoopsEdgesAdjStart[] = 0;
            foreach (e; edges) {
                ++buildLoopsEdgesAdjStart[e[0] + 1];
                ++buildLoopsEdgesAdjStart[e[1] + 1];
            }
            foreach (i; 1 .. buildLoopsEdgesAdjStart.length)
                buildLoopsEdgesAdjStart[i] += buildLoopsEdgesAdjStart[i - 1];
            buildLoopsEdgesAdj.length    = buildLoopsEdgesAdjStart[$ - 1];
            buildLoopsEdgesAdjCursor.length = vertices.length;
            buildLoopsEdgesAdjCursor[] = 0;
            foreach (ei, e; edges) {
                buildLoopsEdgesAdj[buildLoopsEdgesAdjStart[e[0]]
                    + buildLoopsEdgesAdjCursor[e[0]]++] = cast(uint)ei;
                buildLoopsEdgesAdj[buildLoopsEdgesAdjStart[e[1]]
                    + buildLoopsEdgesAdjCursor[e[1]]++] = cast(uint)ei;
            }

            // edgeIndexMap is intentionally left empty — see contract
            // comment in the function-level docstring.
            edgeIndexMap = null;

            // Const views shared into the parallel workers.
            auto adjStart = buildLoopsEdgesAdjStart;
            auto adj      = buildLoopsEdgesAdj;
            auto edgesV   = edges;
            void fillLoopEdge(size_t idx) {
                uint u = loops[idx].vert;
                uint v = loops[loops[idx].next].vert;
                size_t lo = adjStart[u];
                size_t hi = adjStart[u + 1];
                for (size_t i = lo; i < hi; i++) {
                    uint ei = adj[i];
                    auto e = edgesV[ei];
                    if ((e[0] == u && e[1] == v) ||
                        (e[0] == v && e[1] == u))
                    {
                        loopEdge[idx] = ei;
                        return;
                    }
                }
            }
            if (total >= PARALLEL_BUILD_MIN) {
                foreach (idx; parallel(iota(total))) fillLoopEdge(idx);
            } else {
                foreach (idx; 0 .. total) fillLoopEdge(idx);
            }
        }


        // Pass 3: twin pairing via (max 2) loops-per-edge. The slot
        // assignment (first → A, second → B) needs serial order to
        // avoid a race on the -1-sentinel comparison; the writeback
        // pass (twin from A/B) is parallelisable.
        //
        // Treatment A for non-manifold edges (3+ loops sharing one edge):
        // on the third loop for an edge, reset A=B=-1 and mark it in
        // edgeNonManifold so fillTwin's b==-1 short-circuit fires for ALL
        // its loops, leaving twin=~0u (boundary-like).  This makes the twin
        // graph consistent (involutive) on non-manifold input.  Manifold
        // edges (≤2 loops after addEdge dedup) never reach the third-loop
        // branch — byte-stable by construction.
        int[]  edgeLoopA        = new int[] (edges.length);
        int[]  edgeLoopB        = new int[] (edges.length);
        bool[] edgeNonManifold  = new bool[](edges.length);  // zero-inited
        edgeLoopA[] = -1;
        edgeLoopB[] = -1;
        foreach (idx; 0 .. total) {
            uint ei = loopEdge[idx];
            if (ei == ~0u) continue;
            if (edgeNonManifold[ei]) continue;          // already flagged — skip
            if (edgeLoopA[ei] == -1)      edgeLoopA[ei] = cast(int)idx;
            else if (edgeLoopB[ei] == -1) edgeLoopB[ei] = cast(int)idx;
            else {
                // Third (or later) loop for this edge: non-manifold.
                // Reset A/B so fillTwin's b==-1 guard fires → all loops
                // on this edge keep twin=~0u (indistinguishable from boundary).
                edgeNonManifold[ei] = true;
                edgeLoopA[ei] = -1;
                edgeLoopB[ei] = -1;
            }
        }
        void fillTwin(size_t idx) {
            uint ei = loopEdge[idx];
            if (ei == ~0u) return;
            int a = edgeLoopA[ei];
            int b = edgeLoopB[ei];
            if (b == -1) return;
            loops[idx].twin = (a == cast(int)idx) ? cast(uint)b : cast(uint)a;
        }
        if (total >= PARALLEL_BUILD_MIN) {
            foreach (idx; parallel(iota(total))) fillTwin(idx);
        } else {
            foreach (idx; 0 .. total) fillTwin(idx);
        }


        // Anchor walk — independent per vertex; for BOUNDARY verts,
        // walk back via next(twin(cur)) until the open start of the
        // fan. For closed meshes (every edge has both A and B loops)
        // the walk just re-traverses a closed ring and ends at `orig`
        // — the resulting vertLoop[vi] is some loop in the same ring
        // we started in, which is what we already had. Detect that
        // case ONCE and skip the per-vertex walk entirely — it's the
        // single biggest cost (~29% of CPU during a subpatch-mode
        // sphere drag profile) for closed-manifold inputs, which are
        // the common case in subpatch preview meshes.
        //
        // Non-manifold (treatment A) edges also set hasBoundary=true so
        // the anchor walk runs and gives each affected vertex a deterministic
        // start dart.  The walk still breaks on the first twin==~0u, so it
        // re-seeds only one fan — NOT a complete fan enumeration.
        bool hasBoundary = false;
        foreach (ei; 0 .. edges.length) {
            if (edgeNonManifold[ei] ||
                (edgeLoopA[ei] != -1 && edgeLoopB[ei] == -1)) {
                hasBoundary = true;
                break;
            }
        }
        if (hasBoundary) {
            void anchorOneVert(size_t vi) {
                if (vertLoop[vi] == ~0u) return;
                uint cur  = vertLoop[vi];
                uint orig = cur;
                foreach (_; 0 .. faces.length + 4) {
                    if (loops[cur].twin == ~0u) break;
                    uint back = loops[loops[cur].twin].next;
                    if (back == orig) break;
                    cur = back;
                }
                vertLoop[vi] = cur;
            }
            if (vertices.length >= PARALLEL_BUILD_MIN) {
                foreach (vi; parallel(iota(vertices.length))) anchorOneVert(vi);
            } else {
                foreach (vi; 0 .. vertices.length) anchorOneVert(vi);
            }
        }

        // PolyVertex (per-corner) maps run parallel to `loops`. Now that the
        // loop layout is rebuilt, bring every such map to `loops.length * dim`.
        // For mutators that already relocated values (remapPolyVertexMaps) this
        // is a length-correct no-op; for the DROP class (primitive rebuilds,
        // subdivide, extrude, …) this is the conscious length-correct,
        // value-zeroed behaviour. No-op when no PolyVertex map is registered.
        resizePolyVertexMaps();

        // Stamp validity at the current structVersion. The loops family is
        // fully rebuilt above in either branch, so it is always Valid here.
        // edgeIndexMap tracks which branch ran: the `rebuildEdgeIndexMap`
        // default rebuilds it (Valid); the CSR-adjacency branch leaves it
        // `null` by design (DeliberatelyEmpty, not Stale — this is an
        // intentional caller contract, not a forgotten rebuild).
        loopsStamp  = structVersion;
        loopsState_ = DerivedState.Valid;
        if (rebuildEdgeIndexMap) {
            edgeMapStamp  = structVersion;
            edgeMapState_ = DerivedState.Valid;
        } else {
            edgeMapState_ = DerivedState.DeliberatelyEmpty;
        }
    }

    // -----------------------------------------------------------------------
    // Make Polygon (mesh.makePolygon)
    // -----------------------------------------------------------------------

    /// Build one face from an ORDERED list of vertex indices.
    /// Winding follows `orderedIdx` order; `flip` reverses it.
    /// Generates missing deduped edges via addEdge. Returns the new face
    /// index, or -1 on rejection.
    ///
    /// Rejections:
    ///   - any index >= vertices.length
    ///   - fewer than 3 distinct vertices (after collapsing consecutive dupes)
    ///   - collinear / zero-area (Newell normal magnitude < 1e-6)
    ///   - duplicate of an existing face (same unordered vertex set)
    int makePolygonFromVerts(const(uint)[] orderedIdx, bool flip) {
        if (orderedIdx.length < 3) return -1;

        // --- 1. copy + optional winding reversal ---
        uint[] idx = orderedIdx.dup;
        if (flip) {
            foreach (i; 0 .. idx.length / 2) {
                uint tmp = idx[i]; idx[i] = idx[$ - 1 - i]; idx[$ - 1 - i] = tmp;
            }
        }

        // --- 2. bounds check ---
        foreach (vi; idx)
            if (vi >= vertices.length) return -1;

        // --- 3. collapse consecutive duplicates (including last→first wrap) ---
        // Build deduped list: skip a vertex if it equals its predecessor.
        uint[] deduped;
        deduped.reserve(idx.length);
        foreach (i; 0 .. idx.length) {
            uint prev = idx[(i + idx.length - 1) % idx.length];
            if (idx[i] != prev) deduped ~= idx[i];
        }
        // Also remove the last element if it equals the first (wrap-around dup).
        while (deduped.length >= 2 && deduped[$ - 1] == deduped[0])
            deduped = deduped[0 .. $ - 1];
        if (deduped.length < 3) return -1;
        idx = deduped;

        // --- 4. collinearity / zero-area via Newell normal ---
        {
            float nx = 0, ny = 0, nz = 0;
            foreach (i; 0 .. idx.length) {
                Vec3 a = vertices[idx[i]];
                Vec3 b = vertices[idx[(i + 1) % idx.length]];
                nx += (a.y - b.y) * (a.z + b.z);
                ny += (a.z - b.z) * (a.x + b.x);
                nz += (a.x - b.x) * (a.y + b.y);
            }
            float len = sqrt(nx*nx + ny*ny + nz*nz);
            if (len < 1e-6f) return -1;
        }

        // --- 5. duplicate-face guard (same unordered vertex set) ---
        foreach (const ref f; faces) {
            if (f.length != idx.length) continue;
            if (makePolyVertexSetMatch_(f[], idx[])) return -1;
        }

        // --- 5.5. adjacency-driven auto-orient + manifold-safety guard.
        // Build edge→incident-faces once; reused for both.
        auto edgeFaces = buildEdgeFaces();

        // --- 5.6. auto-orient by adjacency (task 0394; majority-vote refined
        // for reference-editor parity): a hand-picked vertex order (or
        // `flip`) can traverse a shared edge the SAME direction as an
        // already-existing neighbor face, corrupting the half-edge fan at
        // that edge's endpoints (facesAroundEdge / collectEdgeRing then see
        // nothing there — the bug this task fixes). Reference-editor parity
        // (owner): Make Polygon has no flip prompt at all — it just orients
        // correctly from context. Factored into `orientFaceConsistent` (task
        // 0395) so Bridge's new open-row strip/fan faces reuse the exact
        // same invariant.
        orientFaceConsistent(idx, edgeFaces);

        // --- 5.7. manifold-safety guard: reject if any boundary edge of the
        // new face is already shared by 2 existing faces — adding a 3rd
        // would exceed the ≤2-faces-per-edge manifold invariant (e.g. a new
        // face reusing an edge already shared by two faces of a closed
        // solid). Fuzz-found: task 0316. (Orientation-independent — reject
        // check is unaffected by the auto-orient reversal above.)
        foreach (i; 0 .. idx.length) {
            ulong key = edgeKeyOrdered(idx[i], idx[(i + 1) % idx.length]);
            auto p = key in edgeFaces;
            if (p !is null && (*p)[1] != -1) return -1;
        }

        // --- 6. append face + rebuild ---
        addFace(idx);
        buildLoops();
        syncSelection();
        return cast(int)(faces.length - 1);
    }

    /// Auto-orient a candidate face's vertex order to be winding-consistent
    /// with its EXISTING mesh neighbors (task 0394's `makePolygonFromVerts`
    /// auto-orient, factored out here so task 0395's Bridge open-row
    /// strip/fan faces reuse the identical invariant instead of a fixed
    /// convention). `edgeFaces` must be a `buildEdgeFaces()` snapshot taken
    /// BEFORE any of the caller's own new faces were added (same convention
    /// `makePolygonFromVerts` and `bridgeLoopsPaired`/`bridgeStripPaired`
    /// already use), so only PRE-EXISTING neighbors vote.
    ///
    /// Majority-vote over every edge of `idx` that already has an existing
    /// neighbor in `edgeFaces`: a manifold requires the two faces sharing an
    /// edge to traverse it in OPPOSITE directions, so a same-direction
    /// neighbor is a vote to flip. `idx` is reversed in place iff
    /// same-direction votes strictly outnumber opposite-direction votes — a
    /// TIE (including 0-0: no shared edge at all, e.g. a disconnected
    /// island) leaves `idx` untouched, which is the deliberate fallback for
    /// unconnected topology (task 0395 rr-capture: the neighbor-orientation
    /// rule only has a signal to act on when at least one boundary edge
    /// already borders existing geometry).
    private void orientFaceConsistent(uint[] idx, const int[2][ulong] edgeFaces) const {
        int sameDirVotes = 0, oppositeDirVotes = 0;
        foreach (i; 0 .. idx.length) {
            uint u = idx[i], v = idx[(i + 1) % idx.length];
            auto p = edgeKeyOrdered(u, v) in edgeFaces;
            if (p is null) continue;                 // brand-new edge, no neighbor yet
            int nbrFi = (*p)[0];
            if (nbrFi < 0 || nbrFi >= cast(int)faces.length) continue;
            auto nf = faces[nbrFi];
            foreach (k; 0 .. nf.length) {
                uint a = nf[k], b = nf[(k + 1) % nf.length];
                if (a == u && b == v) { ++sameDirVotes;     break; }
                if (a == v && b == u) { ++oppositeDirVotes; break; }
            }
        }
        if (sameDirVotes > oppositeDirVotes) {
            foreach (j; 0 .. idx.length / 2) {
                uint tmp = idx[j]; idx[j] = idx[$ - 1 - j]; idx[$ - 1 - j] = tmp;
            }
        }
    }

    /// Register a just-`addFace`d face's own edges into a LIVE (mutable,
    /// caller-owned) `edgeFaces`-shaped map, keyed the same way
    /// `buildEdgeFaces()` builds one. Incremental counterpart used by
    /// `bridgeStripPaired`/`bridgeFanRows` (task 0395 winding-consistency
    /// follow-up) so a LATER face in the SAME strip/fan loop's
    /// `orientFaceConsistent` vote sees its already-placed SIBLING bridge
    /// faces too — not just faces that existed before the bridge call
    /// started. Without this, a STATIC snapshot taken once at the top of
    /// the loop is blind to a strip's own internal rung edges: if one new
    /// face gets reversed (because it borders a pre-existing face) and its
    /// immediate neighbor in the same strip does not (a 0-0 tie, no
    /// pre-existing signal of its own), the two new faces can settle on
    /// the SAME direction for the rung edge they share — exactly the
    /// half-edge corruption `orientFaceConsistent` exists to prevent.
    /// `idx` must be the face's FINAL (post-orient) vertex order — call
    /// this only after `addFace(idx)`, so `faces[newFi]` already matches.
    private void registerNewFaceEdges(ref int[2][ulong] liveEdgeFaces, uint newFi,
                                      const(uint)[] idx) const {
        foreach (i; 0 .. idx.length) {
            ulong key = edgeKeyOrdered(idx[i], idx[(i + 1) % idx.length]);
            auto p = key in liveEdgeFaces;
            if (p is null)
                liveEdgeFaces[key] = [cast(int)newFi, -1];
            else if ((*p)[0] < 0)
                (*p)[0] = cast(int)newFi;
            else if ((*p)[1] < 0)
                (*p)[1] = cast(int)newFi;
            // else: edge already carries 2 registered faces (manifold slot
            // saturated) — leave untouched rather than overwrite.
        }
    }

    // Helper: true iff `a` and `b` contain the same multiset of vertex indices.
    // O(n²) but n is typically small (poly arities ≤ 64 in practice). Widened
    // from `private` (task 0417, mesh_ops.cleanup extraction): a unifyFaces
    // unittest (now in source/mesh_ops/cleanup.d) uses this as the O(F²)
    // reference oracle for its O(F) hash-bucket rewrite — that test is
    // module-level code in a different module, which a private struct member
    // is not visible to (unlike a mixin-template body, which is transparent
    // to Mesh's private members regardless of which module declares the
    // template). See mesh_ops/cleanup.d's own comment at the call site.
    static bool makePolyVertexSetMatch_(const uint[] a, const uint[] b) {
        if (a.length != b.length) return false;
        bool[] used = new bool[](b.length);
        outer: foreach (ai; a) {
            foreach (j; 0 .. b.length) {
                if (!used[j] && ai == b[j]) { used[j] = true; continue outer; }
            }
            return false;
        }
        return true;
    }

    // ------------------------------------------------------------------
    // Bridge (task 0100): stitch two equal-length closed vertex loops.
    // ------------------------------------------------------------------

    /// Return the ordered vertex cycle of face `fi` — the face's vertex
    /// list as a plain uint[].  Used by the bridge command (Polygon mode).
    uint[] faceVertexRing(uint fi) const {
        return faces[fi].dup;
    }

    /// Extract all disjoint simple closed vertex cycles from the currently
    /// selected edges.  Each cycle is an ordered uint[] with no repeated
    /// vertex (implied closed: last connects back to first).
    ///
    /// Returns [] if no edges are selected OR if any connected component
    /// is not a simple closed cycle (vertex degree ≠ 2).
    uint[][] extractSelectedEdgeCycles() const {
        // Build adjacency restricted to selected edges.
        uint[][uint] adj;
        foreach (ei; 0 .. edges.length) {
            if (ei >= edgeMarks.length) continue;
            if (!(edgeMarks[ei] & Marks.Select)) continue;
            uint a = edges[ei][0], b = edges[ei][1];
            adj[a] ~= b;
            adj[b] ~= a;
        }
        if (adj.length == 0) return [];

        // Every selected vertex must have exactly two selected-edge neighbors.
        foreach (v, nbrs; adj) {
            if (nbrs.length != 2) return [];
        }

        // Walk connected components into ordered cycles.
        bool[uint] visited;
        uint[][] cycles;
        foreach (startV; adj.byKey) {
            if (startV in visited) continue;
            uint[] cycle;
            uint cur  = startV;
            uint prev = uint.max;
            while (!(cur in visited)) {
                visited[cur] = true;
                cycle ~= cur;
                auto nbrs = adj[cur];
                uint next = (nbrs[0] != prev) ? nbrs[0] : nbrs[1];
                prev = cur;
                cur  = next;
            }
            if (cur != startV) return [];   // did not close
            if (cycle.length < 3) return [];
            cycles ~= cycle;
        }
        return cycles;
    }

    /// One connected component of `extractSelectedEdgeChains` — either an
    /// open row (`closed == false`, walked endpoint-to-endpoint) or a
    /// closed cycle (`closed == true`, implicit wrap, no repeated vertex).
    static struct EdgeChain {
        uint[] verts;
        bool   closed;
    }

    /// Extract ALL disjoint chains — open rows AND closed cycles — from the
    /// currently selected edges (task 0395: Bridge's edge mode generalizes
    /// from "exactly 2 closed cycles" to also accept 2 OPEN rows). This is
    /// the plural, multi-component sibling of `extractSelectedEdgeChain`
    /// (single component, open-or-closed) and `extractSelectedEdgeCycles`
    /// (multi-component, closed-only) — BOTH of those are left completely
    /// UNTOUCHED so their existing callers/unittests stay byte-identical;
    /// this is new, additive surface.
    ///
    /// Returns [] if: no edges selected, or any vertex has selected-edge
    /// degree > 2 (branching — a component that isn't a simple path/cycle).
    /// Each returned component's own malformed-walk case (defensive; should
    /// be unreachable once the degree<=2 guard holds, since a component
    /// with max degree 2 is necessarily a simple path or a simple cycle)
    /// also aborts the whole call with [].
    ///
    /// Component/walk-start order is arbitrary (AA key iteration order), so
    /// which chain comes first, and which of an open chain's two physical
    /// endpoints is `verts[0]`, are NOT pinned — callers that need a
    /// canonical correspondence between two chains must resolve it
    /// themselves by geometry (see `orientOpenChainB`), not by trusting
    /// this function's output order.
    EdgeChain[] extractSelectedEdgeChains() const {
        // Build adjacency restricted to selected edges.
        uint[][uint] adj;
        foreach (ei; 0 .. edges.length) {
            if (ei >= edgeMarks.length) continue;
            if (!(edgeMarks[ei] & Marks.Select)) continue;
            uint a = edges[ei][0], b = edges[ei][1];
            adj[a] ~= b;
            adj[b] ~= a;
        }
        if (adj.length == 0) return [];

        // Reject any branching vertex (degree > 2) — same gate as both
        // single-purpose extractors.
        foreach (v, nbrs; adj)
            if (nbrs.length > 2) return [];

        bool[uint] visited;
        EdgeChain[] chains;

        // Pass 1 — open rows: walk from every unvisited degree-1 vertex.
        // Walking from one endpoint necessarily visits the whole chain
        // (including its far endpoint), so that far endpoint is already
        // `visited` by the time this loop reaches it — no double-walk.
        foreach (v, nbrs; adj) {
            if (nbrs.length != 1) continue;
            if (v in visited) continue;

            uint[] chain;
            uint cur = v, prev = uint.max;
            while (cur !in visited) {
                visited[cur] = true;
                chain ~= cur;
                uint next = uint.max;
                foreach (n; adj[cur])
                    if (n != prev) { next = n; break; }
                if (next == uint.max) break;   // reached the far endpoint
                prev = cur;
                cur  = next;
            }
            if (chain.length < 2) return [];   // defensive; degree-1 start implies >=1 edge
            chains ~= EdgeChain(chain, false);
        }

        // Pass 2 — closed cycles: every vertex left unvisited here has
        // degree exactly 2 (pass 1 consumed every degree-1 vertex already).
        foreach (v, nbrs; adj) {
            if (v in visited) continue;
            uint[] cycle;
            uint cur = v, prev = uint.max;
            while (cur !in visited) {
                visited[cur] = true;
                cycle ~= cur;
                auto cnbrs = adj[cur];
                uint next = (cnbrs[0] != prev) ? cnbrs[0] : cnbrs[1];
                prev = cur;
                cur  = next;
            }
            if (cur != v) return [];            // did not close → malformed
            if (cycle.length < 3) return [];
            chains ~= EdgeChain(cycle, true);
        }

        return chains;
    }

    // Bridge kernel family (bridgeLoopsPaired / bridgeLoops / bridgeLoopsSpans /
    // bridgeStripPaired / bridgeOpenRows) — see source/mesh_ops/bridge.d
    // (task 0417, 0407 §B.V2, continuation of the task-0412 pilot).
    mixin MeshBridgeOps;

    /// Oriented open-boundary loops over faces 0..faceLimit.
    /// Each loop is an ordered uint[] of vertex indices along the directed
    /// boundary half-edge as it appears in its sole face.
    /// Returns [] for a closed surface (no boundary edges).
    /// Non-manifold boundary vertices (two outgoing boundary edges) are skipped.
    uint[][] boundaryLoops(size_t faceLimit = size_t.max) const {
        const size_t nf = faceLimit < faces.length ? faceLimit : faces.length;

        // Build edgeFaces map: open edge has slot [1] == -1. Pass the SAME
        // prefix limit (never a null-mask all-faces build) so an edge shared
        // with a face beyond `nf` stays correctly "open" within the prefix.
        auto edgeFaces = buildEdgeFaces(null, faceLimit);

        // Collect directed boundary half-edges into a next[] map.
        uint[uint] next;
        foreach (fi; 0 .. nf) {
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                uint a = f[k], b = f[(k + 1) % f.length];
                ulong key = edgeKeyOrdered(a, b);
                auto p = key in edgeFaces;
                if (p !is null && (*p)[1] == -1) {
                    if (a !in next)
                        next[a] = b;
                    // non-manifold: two outgoing boundary edges from one vert — skip
                }
            }
        }

        // Chain loops by following next[] until returning to start.
        bool[uint] visited;
        uint[][] loops;
        foreach (start, _; next) {
            if (start in visited) continue;
            uint[] loop;
            uint cur = start;
            while (cur !in visited) {
                if (cur !in next) break;
                visited[cur] = true;
                loop ~= cur;
                cur = next[cur];
            }
            if (loop.length >= 3)
                loops ~= loop;
        }
        return loops;
    }

    /// Build an offset copy of the surface (reversed winding), then stitch every
    /// open boundary loop original↔offset with a ring of quads → closed shell.
    /// Self-intersection on tight concavities is a known v1 limitation.
    /// Returns total faces added (>0) or 0 (no-op: zero thickness or closed input).
    size_t thickenSurface(float thickness, bool symmetric = false) {
        import std.math : abs;
        import std.algorithm : reverse;
        // Step 1 — pre-mutation gates (mutation-free).
        if (abs(thickness) < 1e-6f) return 0;
        const size_t V0 = vertices.length;
        const size_t F0 = faces.length;
        uint[][] loops = boundaryLoops(F0);
        if (loops.length == 0) return 0;

        // Step 2 — per-vertex averaged unit face normals.
        // Must zero-init: D's float.init is nan, which poisons accumulation.
        Vec3[] vn = new Vec3[](V0);
        vn[] = Vec3(0, 0, 0);
        foreach (fi; 0 .. F0) {
            Vec3 fn = faceNormal(cast(uint)fi);
            foreach (vi; faces[fi])
                vn[vi] = vn[vi] + fn;
        }
        foreach (i; 0 .. V0)
            vn[i] = safeNormalize(vn[i]);

        // Step 3 — create offset vertices (offset pushed toward −normal side).
        uint[] off = new uint[](V0);
        if (!symmetric) {
            foreach (i; 0 .. V0)
                off[i] = addVertex(vertices[i] - vn[i] * thickness);
        } else {
            Vec3[] orig = new Vec3[](V0);
            foreach (i; 0 .. V0) orig[i] = vertices[i];
            foreach (i; 0 .. V0)
                vertices[i] = orig[i] + vn[i] * (thickness * 0.5f);
            commitChange(MeshEditScope.Position);
            foreach (i; 0 .. V0)
                off[i] = addVertex(orig[i] - vn[i] * (thickness * 0.5f));
        }

        // Step 4 — inner faces with reversed winding (inner skin faces −normal).
        // Task 0389: each shell face mirrors exactly one front face `fi` — it
        // inherits that face's Subpatch bit (rim quads, bridged below, then
        // pick this up automatically via bridgeLoopsPaired's own adjacency
        // OR — the rim is bounded by one front edge and its mirrored shell
        // edge, so it ORs this same bit with the front face's).
        foreach (fi; 0 .. F0) {
            uint[] of = new uint[](faces[fi].length);
            foreach (k; 0 .. faces[fi].length)
                of[k] = off[faces[fi][k]];
            reverse(of);
            uint newFi = cast(uint)faces.length;
            addFace(of);
            resizeSubpatch();
            setFaceSubpatch(newFi, isFaceSubpatch(cast(uint)fi));
        }

        // Step 5 — bridge each stored boundary loop to its offset counterpart.
        // Outer boundary loops from boundaryLoops() are CCW (loop normal agrees
        // with face normal) → reverse for outward-facing rim quads.
        // Inner hole loops are CW (loop normal opposes face normal) → keep as-is.
        Vec3 avgN = Vec3(0, 0, 0);
        foreach (fi; 0 .. F0)
            avgN = avgN + faceNormal(cast(uint)fi);
        avgN = safeNormalize(avgN);

        size_t rimTotal = 0;
        foreach (ref loop; loops) {
            // Compute loop orientation via Newell's method.
            Vec3 ln = Vec3(0, 0, 0);
            const size_t LN = loop.length;
            foreach (k; 0 .. LN) {
                Vec3 a = vertices[loop[k]];
                Vec3 b = vertices[loop[(k + 1) % LN]];
                ln.x += (a.y - b.y) * (a.z + b.z);
                ln.y += (a.z - b.z) * (a.x + b.x);
                ln.z += (a.x - b.x) * (a.y + b.y);
            }
            if (ln.x * avgN.x + ln.y * avgN.y + ln.z * avgN.z > 0.0f)
                reverse(loop);

            uint[] pairedB = new uint[](LN);
            foreach (i; 0 .. LN)
                pairedB[i] = off[loop[i]];
            rimTotal += bridgeLoopsPaired(loop, pairedB);
        }

        // Step 6 — finalize.
        buildLoops();
        syncSelection();
        return F0 + rimTotal;
    }

    // ------------------------------------------------------------------
    // Profile extraction and revolve (surface of revolution)
    // ------------------------------------------------------------------

    /// Extract a single ordered vertex chain from the currently selected edges.
    /// Returns the ordered vertex list and sets `isClosed` accordingly.
    ///
    /// Closed cycle (all participating vertices degree 2):
    ///   `isClosed = true`; chain length >= 3.
    ///
    /// Open chain (exactly two degree-1 endpoints):
    ///   `isClosed = false`; chain walked endpoint-to-endpoint; length >= 2.
    ///
    /// Returns [] if: no edges selected, any vertex degree > 2 (branching),
    /// more than one connected component, or chain too short for its type.
    ///
    /// Note: walk start is arbitrary (AA iteration order), so chain direction
    /// — and hence the swept surface's in/out normal — is not pinned
    /// (vibe3d-divergence, v1; see doc/radial_sweep_plan.md Phase 4).
    uint[] extractSelectedEdgeChain(out bool isClosed) const {
        isClosed = false;

        // Build adjacency restricted to selected edges.
        uint[][uint] adj;
        foreach (ei; 0 .. edges.length) {
            if (ei >= edgeMarks.length) continue;
            if (!(edgeMarks[ei] & Marks.Select)) continue;
            uint a = edges[ei][0], b = edges[ei][1];
            adj[a] ~= b;
            adj[b] ~= a;
        }
        if (adj.length == 0) return [];

        // Reject any branching vertex (degree > 2).
        foreach (v, nbrs; adj)
            if (nbrs.length > 2) return [];

        // Find degree-1 endpoint vertices.
        uint startV        = uint.max;
        uint endpointCount = 0;
        foreach (v, nbrs; adj) {
            if (nbrs.length == 1) {
                ++endpointCount;
                if (startV == uint.max) startV = v;
            }
        }

        if (endpointCount == 0) {
            // All degree 2 → closed cycle; pick any start vertex.
            isClosed = true;
            foreach (v, nbrs; adj) { startV = v; break; }
        } else if (endpointCount == 2) {
            // Two endpoints → open chain; startV already set to one endpoint.
            isClosed = false;
        } else {
            return [];   // malformed degree combination
        }

        // Walk from startV, avoiding backtracking.
        bool[uint] visited;
        uint[] chain;
        uint cur  = startV;
        uint prev = uint.max;
        while (cur !in visited) {
            visited[cur] = true;
            chain ~= cur;
            // Pick the neighbor that is not the previous vertex.
            uint next = uint.max;
            foreach (n; adj[cur])
                if (n != prev) { next = n; break; }
            if (next == uint.max) break;   // reached far endpoint (degree 1)
            prev = cur;
            cur  = next;
        }

        // Validate closure / minimum chain length.
        if (isClosed) {
            if (cur != startV) return [];   // didn't close → multi-component
            if (chain.length < 3) return [];
        } else {
            if (chain.length < 2) return [];
        }

        // Single-component: every adj vertex must have been visited.
        foreach (v, nbrs; adj)
            if (v !in visited) { isClosed = false; return []; }

        return chain;
    }

    // Radial Sweep / Revolve + Path-follow extrude kernel family — see
    // source/mesh_ops/revolve.d (task 0417, 0407 §B.V2).
    mixin MeshRevolveOps;

    // Mesh hygiene + orientation-repair kernel family — see
    // source/mesh_ops/cleanup.d (task 0417, 0407 §B.V2).
    mixin MeshCleanupOps;

    // Polygon decimation kernel (reduceToTarget) — see
    // source/mesh_ops/decimate.d (task 0417, 0407 §B.V2).
    mixin MeshDecimateOps;

    // Plane-cut kernel family (cutByPlane / cutByPlaneRestricted / planeCutCore /
    // cutByPlaneClipped / PlaneCutLoops / cutByPlaneEx / deleteComponentsInSlab /
    // cutByPlaneSplitGap / extractCutLoops / splitAlongCutLoop) — see
    // source/mesh_ops/cut.d (task 0412, 0407 §B.V2 pilot).
    mixin MeshCutOps;

    // -----------------------------------------------------------------------
    // insertEdgePoint — factored from cutByPlane Pass-1.
    //
    // Adds a lerp vertex at parameter t along edge ei (t ∈ [0,1]: 0 = edges[ei][0],
    // 1 = edges[ei][1]) and splices it between the two endpoints in every face
    // winding that contains the pair.  Grows isCutVert as needed and marks the
    // new vertex.  Returns the new vertex index.
    //
    // Endpoint-reuse (F1, task 0295): when t lands within eps of either end,
    // the corner vertex (edges[ei][0] or edges[ei][1]) is REUSED instead of
    // inserting a coincident vertex — the corner is already present in every
    // incident winding, so no splice is needed. isCutVert must still grow to
    // cover it (BEFORE the mark — the reuse path skips addVertex, so
    // isCutVert may still be shorter than vertices.length) so
    // rebuildFacesWithChordSplits treats the corner as a chord endpoint.
    //
    // Non-manifold edges (3+ incident faces) are out of scope for v1; the splice
    // scans all face windings and inserts into every face that contains the pair.
    // -----------------------------------------------------------------------
    private uint insertEdgePoint(uint ei, float t, ref bool[] isCutVert, float eps = 1e-5f) {
        uint a = edges[ei][0], b = edges[ei][1];

        if (t <= eps) {
            if (isCutVert.length < vertices.length) isCutVert.length = vertices.length;
            isCutVert[a] = true;
            return a;
        }
        if (t >= 1.0f - eps) {
            if (isCutVert.length < vertices.length) isCutVert.length = vertices.length;
            isCutVert[b] = true;
            return b;
        }

        Vec3 vm = Vec3(
            vertices[a].x + t * (vertices[b].x - vertices[a].x),
            vertices[a].y + t * (vertices[b].y - vertices[a].y),
            vertices[a].z + t * (vertices[b].z - vertices[a].z));
        uint vi = addVertex(vm);
        if (isCutVert.length < vertices.length)
            isCutVert.length = vertices.length; // grow after addVertex
        isCutVert[vi] = true;

        // Splice vi between (a,b) or (b,a) in every incident face winding.
        foreach (ref face; faces) {
            for (size_t k = 0; k < face.length; k++) {
                uint fa = face[k];
                uint fb = face[(k + 1) % face.length];
                if ((fa == a && fb == b) || (fa == b && fb == a)) {
                    face = face[0 .. k + 1] ~ [vi] ~ face[k + 1 .. $];
                    break;
                }
            }
        }
        return vi;
    }

    // -----------------------------------------------------------------------
    // addEdgePoint — public entry point: insert one vertex at parameter t along
    // edge ei (open interval t ∈ (0,1)), re-derive edges from faces, and call
    // buildLoops().  Returns the new vertex index, or uint.max if guards fail.
    //
    // Unlike insertEdgeLoops (ring-walk, quad-only), this touches only the
    // seed edge's incident faces — no quad/ring restriction; triangle edges
    // work too.  Selection state is left unchanged; the caller owns that.
    // -----------------------------------------------------------------------
    uint addEdgePoint(uint ei, float t) {
        if (ei >= edges.length)        return uint.max;
        if (t <= 0.0f || t >= 1.0f)   return uint.max;
        bool[] isCutVert; // local throwaway — not used outside this call
        uint vi = insertEdgePoint(ei, t, isCutVert);
        // Re-derive edges from faces (deduped via edgeIndexMap).
        rebuildEdges();
        buildLoops();
        return vi;
    }

    // -----------------------------------------------------------------------
    // rebuildFacesWithChordSplits — factored from cutByPlane Pass-2 + finalize.
    //
    // For each face fi eligible by splitFaceMask (empty mask = all faces): if the
    // face has exactly 2 non-adjacent cut vertices, split it along the chord.
    // Copies non-eligible or non-qualifying faces whole.  Applies the new face
    // arrays, rebuilds edges/loops, syncs selection, commits the change.
    //
    // cutByPlane passes an empty mask so every face is eligible — preserving the
    // original behaviour exactly.  edgeSlice passes a path-only mask to avoid
    // splitting faces adjacent to the path but not on it.
    //
    // Returns the number of faces split; 0 = no-op (caller owns snapshot/undo).
    // -----------------------------------------------------------------------
    private size_t rebuildFacesWithChordSplits(
        const bool[] splitFaceMask, const bool[] isCutVert)
    {
        size_t origFaceCount = faces.length;
        uint[][] newFacesArr;
        bool[]   newSubpatch;
        int[]    newOrder;
        uint[]   newMaterial;
        uint[]   newPart;
        bool[]   newSelected;
        newFacesArr.reserve(origFaceCount + origFaceCount / 2);

        size_t nSplit = 0;
        foreach (fi; 0 .. origFaceCount) {
            uint[] face = faces[fi];
            bool  sub = isFaceSubpatch(fi);
            int   ord = (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
            uint  mat = (fi < faceMaterial.length       ? faceMaterial[fi]       : 0u);
            uint  prt = (fi < facePart.length           ? facePart[fi]           : 0u);
            bool  seld = isFaceSelected(fi);

            // Faces not in the mask are copied whole (never split).
            bool eligible = (splitFaceMask.length == 0) ||
                            (fi < splitFaceMask.length && splitFaceMask[fi]);
            if (!eligible) {
                newFacesArr ~= face.dup;
                newSubpatch ~= sub;
                newOrder    ~= ord;
                newMaterial ~= mat;
                newPart     ~= prt;
                newSelected ~= seld;
                continue;
            }

            // Collect winding positions of cut vertices.
            size_t[] hits;
            foreach (k; 0 .. face.length)
                if (face[k] < isCutVert.length && isCutVert[face[k]])
                    hits ~= k;

            if (hits.length != 2) {
                newFacesArr ~= face.dup;
                newSubpatch ~= sub;
                newOrder    ~= ord;
                newMaterial ~= mat;
                newPart     ~= prt;
                newSelected ~= seld;
                continue;
            }

            size_t i = hits[0], j = hits[1]; // i < j always (scanned in order)

            // Adjacent-hit guard: chord == existing edge → degenerate 2-gon, skip.
            bool adj = (j == i + 1) || (i == 0 && j == face.length - 1);
            if (adj) {
                newFacesArr ~= face.dup;
                newSubpatch ~= sub;
                newOrder    ~= ord;
                newMaterial ~= mat;
                newPart     ~= prt;
                newSelected ~= seld;
                continue;
            }

            // Split: f1 = face[i..j+1], f2 = face[j..] ~ face[0..i+1].
            uint[] f1 = face[i .. j + 1].dup;
            uint[] f2 = (face[j .. $] ~ face[0 .. i + 1]).dup;

            if (f1.length < 3 || f2.length < 3) {
                // Degenerate — guard above should prevent this; keep whole.
                newFacesArr ~= face.dup;
                newSubpatch ~= sub;
                newOrder    ~= ord;
                newMaterial ~= mat;
                newPart     ~= prt;
                newSelected ~= seld;
                continue;
            }

            // f1 (replaces parent slot)
            newFacesArr ~= f1;
            newSubpatch ~= sub;
            newOrder    ~= ord;
            newMaterial ~= mat;
            newPart     ~= prt;
            newSelected ~= seld;

            // f2 (appended slot) — BOTH halves carry parent attrs, including
            // the Select bit: a selected parent yields two selected halves
            // (reference-pinned behavior).
            newFacesArr ~= f2;
            newSubpatch ~= sub;
            newOrder    ~= ord;
            newMaterial ~= mat;
            newPart     ~= prt;
            newSelected ~= seld;

            nSplit++;
        }

        if (nSplit == 0) return 0;

        // Apply new face arrays (mirrors weldVerticesByMask pattern).
        faces._store = newFacesArr;
        setFaceSubpatchFrom(newSubpatch);
        faceSelectionOrder = newOrder;
        faceMaterial       = newMaterial;
        facePart           = newPart;
        // Inherit each parent's Select bit onto its emitted slot(s) instead of
        // clearing — a selected parent's split halves stay selected, an
        // unselected parent stays unselected, nothing-in ⇒ nothing-out.
        // Writes ONLY the Select bit (Subpatch already written above).
        setFacesSelectedFrom(newSelected);

        rebuildEdges();
        clearEdgeSelectionResize();
        buildLoops();
        syncSelection();
        commitChange(MeshEditScope.Geometry);

        return nSplit;
    }

    // -----------------------------------------------------------------------
    // edgeIndexOfVerts — look up an edge by its two endpoint indices.
    //
    // Returns the index in edges[] for the undirected edge {a, b}, or ~0u if
    // no such edge exists (requires buildLoops() to have been called).
    // -----------------------------------------------------------------------
    private uint edgeIndexOfVerts(uint a, uint b) {
        auto p = edgeKey(a, b) in edgeIndexMap;
        return p ? *p : ~0u;
    }

    // Public accessor over edgeIndexOfVerts (task 0295, F2) — the chain tool
    // lives in a separate module and needs to re-resolve a destination edge
    // by its stable vertex pair every frame (vertex pairs, unlike edge
    // indices, survive an intervening edgeSlice's rebuildEdges()).
    uint edgeIndexOf(uint a, uint b) {
        return edgeIndexOfVerts(a, b);
    }

    // -----------------------------------------------------------------------
    // EdgeSliceResult — edgeSliceEx's return value (task 0295, F2).
    //
    // cutVertA/cutVertB surface insertEdgePoint's already-computed return
    // index for the first (edgeA/tA) and last (edgeB/tB) cut, so a caller
    // chaining several edgeSliceEx calls into a strip-cut CHAIN can thread
    // the EXACT shared vertex into the next segment's seed instead of
    // scanning for a coincident world position (which fails outright for an
    // F1 endpoint-reuse cut, whose index is < the pre-cut vertex count).
    // ~0u means "no cut point inserted" (a guard-failure no-op).
    // -----------------------------------------------------------------------
    struct EdgeSliceResult {
        size_t facesSplit = 0;
        uint   cutVertA   = ~0u;
        uint   cutVertB   = ~0u;
        // Mesh-robustness batch (fuzz-found): true iff this call left the
        // mesh geometrically changed — a face split OR a KEPT vertex insert
        // (a legitimate interior cut that degenerated to a plain edge-split,
        // facesSplit==0, but a real vertex was spliced in and finalized).
        // Distinct from `facesSplit`, which counts ONLY face splits. Callers
        // MUST gate rollback/stop on `meshChanged`, never on `facesSplit==0`:
        // a kept degenerate-chain insert has `facesSplit==0` but
        // `meshChanged==true`.
        bool   meshChanged = false;
    }

    // -----------------------------------------------------------------------
    // edgeSliceEx — cut a strip from edge edgeA to edge edgeB; edgeSlice's
    // full engine, returning the cut-vertex indices alongside the face-split
    // count (task 0295, F2). edgeSlice (below) is a back-compat wrapper —
    // every existing caller keeps its byte-stable size_t-returning signature.
    //
    // Finds the shortest dual-graph path (BFS over face adjacency) from any face
    // incident to edgeA to any face incident to edgeB.  Inserts a cut point on
    // each edge of the path (tA on edgeA, 0.5 on interior edges, tB on edgeB),
    // then splits every crossed face along the chord between its two cut points.
    // Adjacent faces on the path share the cut vertex at their common edge by the
    // SAME index (index-share / no T-junctions), identical to cutByPlane.
    //
    // tA, tB: position along edgeA/edgeB measured from edges[][0] to edges[][1].
    // The internal endpoint ordering is opaque (dedup order); default 0.5 is
    // always safe and symmetric.  Non-0.5 values follow the stored edge order.
    // t == 0 / t == 1 (task 0295, F1) is a valid endpoint cut: insertEdgePoint
    // REUSES the corner vertex edges[e][0]/[1] instead of inserting a
    // coincident one, so the chord connects to the existing corner — the
    // closed-interval clamp below (unlike the pre-F1 open-interval clamp)
    // deliberately allows this.
    //
    // splitPolygons (default true): when false, only the two cut points are
    // inserted (on edgeA at tA, on edgeB at tB) — no chord, no path faces
    // touched at all. Byte-identical to the pre-existing behaviour when true
    // (the default), so every existing caller is unaffected.
    //
    // Returns facesSplit = the number of faces actually chord-split; 0 can
    // mean EITHER of two different outcomes distinguished by `meshChanged`
    // (mesh-robustness batch, fuzz-found — this is a deliberate reversal of
    // the earlier always-rollback behaviour):
    //   - meshChanged == false: a TRUE no-op (dead-end / same edge / OOB, or
    //     every cut point reused an existing corner with nothing spliced
    //     in) — cutVertA/cutVertB stay ~0u, the mesh is restored byte-
    //     identical to entry.
    //   - meshChanged == true: a legitimate chain that degenerated to a
    //     plain edge-split — Pass 1 spliced a REAL new vertex into the path
    //     faces' windings, but the adjacent-hit guard below then refused to
    //     chord-split any of them. This is KEPT and finalized (matches the
    //     reference: a chord chain reusing a corner mid-chain still inserts
    //     the other, genuinely interior, cut points). cutVertA/cutVertB are
    //     the real inserted/reused vertex indices, not sentinels.
    // With splitPolygons==false a successful two-point insert sets
    // facesSplit = 2 (a NONZERO SUCCESS MARKER, not a literal inserted-vertex
    // count — under F1 an endpoint insert reuses a corner and adds no vertex
    // at all; if BOTH tA and tB resolve to endpoints the points-only cut is a
    // geometric no-op yet still reports facesSplit = 2 with cutVertA/cutVertB
    // set to the two reused corners) rather than a face-split count, since no
    // face is split in that mode; meshChanged is always true here too (a
    // points-only success already counted as a change for the chain).
    // Caller owns snapshot/undo — this method does NOT capture a snapshot.
    // Callers MUST gate rollback/stop on `!meshChanged`, never on
    // `facesSplit == 0` — see EdgeSliceResult's own doc comment.
    //
    // Degenerate guard: if both cut points resolve to the SAME vertex (e.g.
    // an F1 endpoint cut on each edge lands on a shared corner),
    // rebuildFacesWithChordSplits sees hits.length == 1 (< 2) on the shared
    // face, copies it whole, and facesSplit stays 0. If Pass 1 spliced in a
    // real vertex before hitting this guard, that insert is KEPT (see
    // above); if both cuts were pure corner-reuse (no insert at all), this
    // is the TRUE no-op case and the whole call rolls back — already safe,
    // no new code needed beyond the meshChanged gate.
    //
    // Every insertEdgePoint vertex is a manifold-preserving edge-split (it
    // splices into all ≤2 faces incident to that edge), so keeping a partial
    // insert from a longer broken chain cannot introduce a non-manifold
    // edge — the self-oracle for this reversal.
    //
    // Non-manifold meshes (edges shared by 3+ faces) are out of scope for v1.
    // -----------------------------------------------------------------------
    // -----------------------------------------------------------------------
    // findChordPath — pure (read-only) face-incidence + dual-graph BFS shared
    // by edgeSliceEx (below) and edgeSliceReachable (task 0295, W1). Collects
    // the faces incident to edgeA/edgeB, prefers a single shared face, and
    // otherwise BFS's the face-adjacency dual graph for the shortest chord
    // path. Touches no mesh state — safe to call speculatively (e.g. to test
    // a candidate sub-edge's reachability) without a snapshot/restore
    // round-trip. Returns false (pathFaces/interiorEdges left empty) for an
    // out-of-range or identical edge pair, or when no path exists
    // (disconnected / boundary blocks) — mirroring edgeSliceEx's own
    // guard-failure no-op.
    // -----------------------------------------------------------------------
    private bool findChordPath(uint edgeA, uint edgeB,
                                out uint[] pathFaces, out uint[] interiorEdges) const
    {
        if (edgeA >= edges.length || edgeB >= edges.length) return false;
        if (edgeA == edgeB) return false;

        // Collect faces incident to each edge (1-2 faces on a manifold mesh).
        uint[] facesAArr, facesBArr;
        foreach (f; facesAroundEdge(edgeA)) facesAArr ~= f;
        foreach (f; facesAroundEdge(edgeB)) facesBArr ~= f;
        if (facesAArr.length == 0) return false;

        // Sort ascending for deterministic lowest-index preference.
        import std.algorithm : sort;
        sort(facesAArr);
        sort(facesBArr);

        // Fast-lookup set for facesB.
        bool[uint] facesBSet;
        foreach (f; facesBArr) facesBSet[f] = true;

        // Case (a): edgeA and edgeB already share a face → single split.
        uint sharedFace = ~0u;
        foreach (f; facesAArr) {
            if (f in facesBSet) { sharedFace = f; break; }
        }

        if (sharedFace != ~0u) {
            pathFaces     = [sharedFace];
            interiorEdges = [];
            return true;
        }

        // Case (b): BFS over the face dual graph.
        // Nodes = faces; arcs = shared edges between adjacent faces.
        // Multi-source from facesAArr; terminate at the first face in facesBSet.
        uint[]     queue;
        bool[uint] visited;
        uint[uint] parentFace;  // parentFace[g] = face we came from
        uint[uint] parentEdge;  // parentEdge[g] = shared edge we crossed

        foreach (f; facesAArr) {
            visited[f] = true;
            queue ~= f;
        }

        uint goal = ~0u;
        while (queue.length > 0) {
            uint f = queue[0];
            queue = queue[1 .. $];

            if (f in facesBSet) { goal = f; break; }

            // Walk the face's half-edge ring; cross each twin to an unvisited neighbour.
            uint startLi = (f < faceLoop.length) ? faceLoop[f] : ~0u;
            if (startLi == ~0u) continue;
            uint li = startLi;
            do {
                uint twin = loops[li].twin;
                if (twin != ~0u) {
                    uint g = loops[twin].face;
                    if (!(g in visited)) {
                        visited[g]    = true;
                        parentFace[g] = f;
                        parentEdge[g] = loopEdge[li];
                        queue ~= g;
                    }
                }
                li = loops[li].next;
            } while (li != startLi);
        }

        if (goal == ~0u) return false; // no path (disconnected or boundary blocks)

        // Reconstruct ordered face path by walking parentFace back to a root.
        uint cur = goal;
        while (cur in parentFace) {
            interiorEdges = [parentEdge[cur]] ~ interiorEdges;
            pathFaces     = [parentFace[cur]] ~ pathFaces;
            cur = parentFace[cur];
        }
        pathFaces ~= [goal];
        return true;
    }

    // Public, non-mutating reachability probe over the SAME dual-graph BFS
    // edgeSliceEx uses internally (task 0295, W1). Added so a caller that
    // only needs the boolean "is there a chord path from edgeA to edgeB" —
    // e.g. EdgeSliceTool.pickSeedSubEdge probing several candidate sub-edges
    // per chain segment — no longer has to snapshot/cut/restore the whole
    // mesh per candidate just to read `facesSplit > 0` back out. `const`: no
    // mutation, so it's safe to call from a hot per-frame preview rebuild.
    bool edgeSliceReachable(uint edgeA, uint edgeB) const {
        uint[] pathFaces, interiorEdges;
        return findChordPath(edgeA, edgeB, pathFaces, interiorEdges);
    }

    EdgeSliceResult edgeSliceEx(uint edgeA, uint edgeB,
                     float tA = 0.5f, float tB = 0.5f,
                     bool splitPolygons = true, float eps = 1e-5f)
    {
        EdgeSliceResult result;
        if (vertices.length == 0 || faces.length == 0 || edges.length == 0)
            return result;
        if (edgeA >= edges.length || edgeB >= edges.length) return result;
        if (edgeA == edgeB) return result;

        // Clamp t-params to the closed unit interval — t==0/1 (F1) is a
        // valid endpoint cut now that insertEdgePoint reuses the corner
        // instead of inserting a coincident vertex there; only genuinely
        // out-of-range input needs clamping. This is a deliberate semantics
        // change from the pre-F1 open-interval clamp — it also reaches the
        // `mesh.edgeSlice` command (below): its default-t (0.5/0.5) callers
        // never touch t==0/1, so they stay byte-identical.
        if (tA < 0.0f) tA = 0.0f;
        if (tA > 1.0f) tA = 1.0f;
        if (tB < 0.0f) tB = 0.0f;
        if (tB > 1.0f) tB = 1.0f;

        // Split-Polygons-OFF (points-only) branch: insert the two cut points
        // and run the SAME finalize tail rebuildFacesWithChordSplits would —
        // insertEdgePoint alone does NOT rebuild edges/edgeIndexMap/loops,
        // sync selection, or commit (see its own doc comment; the public
        // addEdgePoint wrapper has to call rebuildEdges()/buildLoops() itself
        // for exactly that reason). Skipping this tail would leave edge
        // picking wrong on the new edges, an unsynced selection, and stale
        // version-keyed caches.
        if (!splitPolygons) {
            bool[] isCutVert;
            isCutVert.length = vertices.length;
            result.cutVertA = insertEdgePoint(edgeA, tA, isCutVert, eps);
            result.cutVertB = insertEdgePoint(edgeB, tB, isCutVert, eps);
            clearFaceSelectionResize();
            rebuildEdges();
            clearEdgeSelectionResize();
            buildLoops();
            syncSelection();
            commitChange(MeshEditScope.Geometry);
            result.facesSplit = 2;
            result.meshChanged = true;
            return result;
        }

        // Face-incidence + dual-graph BFS factored out into findChordPath
        // (task 0295, W1) — shared with the read-only edgeSliceReachable
        // probe above. Same guard-failure no-op (return result unchanged,
        // facesSplit stays 0) when no path exists.
        uint[] pathFaces;
        uint[] interiorEdges;
        if (!findChordPath(edgeA, edgeB, pathFaces, interiorEdges)) return result;

        // Ordered cut-edge list: edgeA, interior..., edgeB.
        uint[] cutEdges = [edgeA] ~ interiorEdges ~ [edgeB];

        // t-params: tA first, tB last, 0.5 for each interior edge.
        float[] cutT;
        cutT.length  = cutEdges.length;
        cutT[0]      = tA;
        cutT[$ - 1]  = tB;
        foreach (i; 1 .. cutT.length - 1) cutT[i] = 0.5f;

        // --- Pass 1: insert cut points ---
        // Uses original edge indices; face windings are modified in-place but
        // face count (faces.length) is stable across Pass-1. Capture the
        // FIRST (edgeA/tA) and LAST (edgeB/tB) insert's returned vertex index.
        //
        // task 0303 (fuzz-found): Pass 1 mutates `vertices`/`faces`
        // UNCONDITIONALLY, before Pass 2 knows whether any face will actually
        // split — e.g. a genuine interior insert on edgeA landing immediately
        // adjacent (in the shared face's winding) to an F1 endpoint-reuse cut
        // on edgeB trips rebuildFacesWithChordSplits' adjacent-hit guard, so
        // Pass 2 legitimately splits nothing. Snapshot just enough to undo
        // Pass 1 (vertex count + a shallow dup of the faces array — cheap,
        // no vertices/edges/loops/selection touched) so that a Pass-2 no-op
        // (facesSplit == 0) leaves the mesh's GEOMETRY byte-identical to entry
        // (version counters still bump — as MeshSnapshot.restore also does —
        // but a version-keyed cache re-derives identical data from identical
        // geometry), matching the one-shot `mesh.edgeSlice` command's outer
        // snapshot/restore.
        size_t   vertsBeforePass1 = vertices.length;
        uint[][] facesBeforePass1 = faces._store.dup;

        bool[] isCutVert;
        isCutVert.length = vertices.length;
        foreach (i, ei; cutEdges) {
            uint vi = insertEdgePoint(ei, cutT[i], isCutVert, eps);
            if (i == 0)                   result.cutVertA = vi;
            if (i == cutEdges.length - 1) result.cutVertB = vi;
        }

        // --- Pass 2: split only the path faces ---
        size_t origFaceCount = faces.length; // stable across Pass-1
        bool[] splitMask;
        splitMask.length = origFaceCount;
        foreach (f; pathFaces)
            if (f < origFaceCount) splitMask[f] = true;

        result.facesSplit = rebuildFacesWithChordSplits(splitMask, isCutVert);
        // Mesh-robustness batch (fuzz-found, reversal of the 0303 over-
        // rollback): `facesSplit==0` alone no longer means "nothing
        // happened". Pass 1 (insertEdgePoint) may have already spliced a
        // REAL vertex into the incident faces' windings even though Pass 2's
        // adjacent-hit guard then refused to chord-split any face along the
        // path (rebuildFacesWithChordSplits' own nSplit==0 early return,
        // untouched). That is a legitimate degenerate-chain edge-split —
        // matching the reference behaviour — and must be KEPT, not rolled
        // back; only a TRUE no-op (every cut reused an existing corner, no
        // vertex spliced in at all) still rolls back to the pre-call state.
        result.meshChanged = (result.facesSplit > 0)
                           || (vertices.length > vertsBeforePass1);
        if (result.facesSplit == 0 && vertices.length > vertsBeforePass1) {
            // KEEP + FINALIZE: Pass 1 already spliced the new vertex into the
            // incident face windings in-place, but rebuildFacesWithChordSplits
            // early-returned at nSplit==0 WITHOUT rebuilding edges/loops. Run
            // the same finalize tail a successful split gets. Leave
            // cutVertA/cutVertB as insertEdgePoint returned them — a real
            // caller-visible result, not a no-op sentinel.
            rebuildEdges();
            clearEdgeSelectionResize();
            buildLoops();
            syncSelection();
            commitChange(MeshEditScope.Geometry);
        } else if (result.facesSplit == 0) {
            // TRUE no-op: every cut reused an existing corner (Pass 1 spliced
            // in nothing new), so vertices.length == vertsBeforePass1 exactly.
            // rebuildFacesWithChordSplits' own nSplit==0 branch returns
            // early WITHOUT touching edges/loops/selection (see its doc
            // comment), so those are still consistent with the PRE-Pass-1
            // vertex count — restoring vertices/faces alone fully undoes
            // Pass 1, no rebuildEdges()/buildLoops() call needed.
            faces._store = facesBeforePass1;
            vertices.length = vertsBeforePass1;
            result.cutVertA = ~0u;
            result.cutVertB = ~0u;
            // NB: Pass 1's addVertex also fires editRecorder_.recordAddVert when
            // a change-batch is open; this rollback does NOT un-record it. Safe
            // today because no caller wraps edgeSliceEx in beginEditBatch (batch
            // openers are delete/remove/edge_extrude/edge_extend). A future
            // batched caller must add a matching un-record here.
        }
        return result;
    }

    // Back-compat wrapper — existing callers keep the byte-stable
    // size_t-returning signature; edgeSliceEx (above) is the engine.
    size_t edgeSlice(uint edgeA, uint edgeB,
                     float tA = 0.5f, float tB = 0.5f,
                     bool splitPolygons = true, float eps = 1e-5f)
    {
        return edgeSliceEx(edgeA, edgeB, tA, tB, splitPolygons, eps).facesSplit;
    }

    // -----------------------------------------------------------------------
    // splitFaceByVertices — split a face along a chord between two of its
    // existing, non-adjacent winding vertices.
    //
    // Creates two child faces that together tile the parent area.  No new
    // vertices or edge-midpoints are inserted — the chord connects vA and vB
    // directly.  Per-face attributes (material, subpatch flag) are carried to
    // both halves automatically by rebuildFacesWithChordSplits.
    //
    // Mask scoping: vA/vB appear in other faces too; splitFaceMask limits the
    // eligible set to faceIdx alone so no other face is touched.
    //
    // Returns 1 on success, 0 for any no-op condition:
    //   - faces or vertices empty
    //   - faceIdx or vA/vB out of bounds
    //   - vA == vB
    //   - vA or vB absent from the face winding
    //   - vA and vB are adjacent in the winding (chord == existing edge)
    //
    // Caller owns snapshot/undo — this method does NOT capture a snapshot.
    // -----------------------------------------------------------------------
    public size_t splitFaceByVertices(uint faceIdx, uint vA, uint vB)
    {
        if (faces.length == 0 || vertices.length == 0) return 0;
        if (faceIdx >= faces.length) return 0;
        if (vA >= vertices.length || vB >= vertices.length) return 0;
        if (vA == vB) return 0;

        // Both vA and vB must appear in the face winding.
        bool foundA = false, foundB = false;
        foreach (v; faces[faceIdx]) {
            if (v == vA) foundA = true;
            if (v == vB) foundB = true;
        }
        if (!foundA || !foundB) return 0;

        // Build cut-vertex mask restricted to faceIdx only.
        bool[] isCutVert = new bool[](vertices.length);
        isCutVert[vA] = true;
        isCutVert[vB] = true;

        bool[] splitFaceMask = new bool[](faces.length);
        splitFaceMask[faceIdx] = true;

        return rebuildFacesWithChordSplits(splitFaceMask, isCutVert);
    }

}

// ---------------------------------------------------------------------------
// CleanupOptions / CleanupResult  (used by Mesh.cleanupMesh)
// ---------------------------------------------------------------------------

/// Options for Mesh.cleanupMesh(). All boolean stages default to their most
/// commonly useful values. `weldEpsSq` is the squared linear weld distance;
/// the default 1e-10 corresponds to a linear threshold of 1e-5, matching the
/// "auto" range of vert.merge.
struct CleanupOptions {
    bool   dropDegenerate  = true;   /// Remove degenerate / zero-area faces.
    bool   unify           = true;   /// Remove faces with a duplicate vertex set.
    bool   removeOrphans   = true;   /// Remove unreferenced (floating) vertices.
    bool   dissolve2Valent = false;  /// Dissolve 2-valent vertices (opt-in).
    bool   mergeVerts      = true;   /// Weld coincident vertices first.
    double weldEpsSq       = 1e-10;  /// Weld threshold in squared distance.
}

/// Per-stage counts returned by Mesh.cleanupMesh().
struct CleanupResult {
    size_t welded;       /// Vertices merged by weldCoincidentVertices.
    size_t degenerate;   /// Faces removed/rewritten by cleanDegenerateFaces.
    size_t unified;      /// Faces removed by unifyFaces.
    size_t orphans;      /// Vertices removed by the intermediate compactUnreferenced.
    size_t dissolved;    /// Vertices removed by dissolveDegree2Verts.
    size_t finalOrphans; /// Vertices removed by the final compactUnreferenced (only runs when removeOrphans is set).
    /// True if any stage reported work done.
    bool anyAffected() const {
        return welded + degenerate + unified + orphans + dissolved + finalOrphans > 0;
    }
}

// ---------------------------------------------------------------------------
// VertexDartRange
// ---------------------------------------------------------------------------

/// Input range (and forward range via .save) over all half-edge dart indices
/// incident to a given vertex.  Each element is a uint loop index `li` such
/// that `loops[li].vert` equals the start vertex.
///
/// Traversal rule: from the current dart `li`, the next dart around the vertex
/// is `twin(prev(li))`.  The range stops when:
///   - `twin == ~0u`  (boundary edge reached), or
///   - the dart wraps back to the starting dart (full circle), or
///   - the internal safety counter exceeds 1024 (degenerate mesh guard).
///
/// The range holds only a slice of `Loop[]`, not a reference to the whole
/// Mesh, so it is a lightweight value type with no cyclic dependency.
struct VertexDartRange {
    private const(Loop)[] _loops;
    private uint  _start;   // first dart (also the stop sentinel for cycles)
    private uint  _cur;     // current dart
    private bool  _done;
    private uint  _steps;

    private enum uint MAX_STEPS = 1024;

    /// Construct from a loops slice and a starting dart index.
    /// If `startLi == ~0u` the range is immediately empty (isolated vertex).
    this(const(Loop)[] loops, uint startLi) {
        _loops = loops;
        _start = startLi;
        _cur   = startLi;
        _done  = (startLi == ~0u);
        _steps = 0;
    }

    /// True when the range has been exhausted.
    @property bool empty() const { return _done; }

    /// The current dart index.
    @property uint front() const
    in (!_done)
    { return _cur; }

    /// Advance to the next dart around the vertex.
    void popFront()
    in (!_done)
    {
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _done = true; return; }
        if (++_steps >= MAX_STEPS) {
            warnMaxStepsExceeded("VertexDartRange");
            _done = true;
            return;
        }
        _cur = twinPrev;
        if (_cur == _start)
            _done = true;
    }

    /// Save a copy so the range can be used as a ForwardRange.
    @property VertexDartRange save() const { return this; }
}

/// One-time-per-session stderr warning shared by the three half-edge
/// vertex-walk ranges (Dart / Neighbor / Edge). Triggered when a walk
/// fails to return to its starting dart inside MAX_STEPS — typically
/// non-manifold edges in an imported mesh (LWO files commonly share
/// an edge across 3+ faces, which breaks the unique-twin invariant
/// the walk relies on).
///
/// Old behaviour was `debug assert(false, …)`, which crashed debug
/// builds on every degenerate walk; release builds were already
/// gracefully truncating via `_done = true`. The assert was hiding
/// the fact that the underlying topology problem deserves a fix at
/// build-loops time (treat non-manifold edges as boundaries so twins
/// stay well-defined) — log once so the issue stays visible without
/// being a hard stop.
private void warnMaxStepsExceeded(string rangeName) nothrow {
    import log : logWarnOnce;
    import std.format : format;
    try {
        logWarnOnce("mesh", "maxSteps", format(
            "%s: MAX_STEPS exceeded — non-manifold cage edges " ~
            "(walk truncated; selection / loop ops may be incomplete).",
            rangeName));
    } catch (Exception) {}
}

// ---------------------------------------------------------------------------
// FaceEdgeRange
// ---------------------------------------------------------------------------

/// One directed edge of a face: the consecutive vertex pair (a → b).
struct FaceEdge { uint a, b; }

/// Forward range over all consecutive vertex pairs of a face polygon.
/// Yields FaceEdge(face[j], face[(j+1) % N]) for j in 0..N.
struct FaceEdgeRange {
    private const(uint)[] _verts;
    private uint _j;

    this(const(uint)[] verts) { _verts = verts; _j = 0; }

    @property bool      empty() const { return _j >= _verts.length; }
    @property FaceEdge  front() const { return FaceEdge(_verts[_j], _verts[(_j + 1) % _verts.length]); }
    void popFront() { ++_j; }
    @property FaceEdgeRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// VertexFaceRange
// ---------------------------------------------------------------------------

/// Forward range over all faces incident to a vertex.
/// Wraps VertexDartRange and projects each dart to its face index.
struct VertexFaceRange {
    private const(Loop)[]  _loops;
    private VertexDartRange _inner;

    this(const(Loop)[] loops, uint startLi) {
        _loops = loops;
        _inner = VertexDartRange(loops, startLi);
    }

    @property bool empty() const { return _inner.empty; }
    @property uint front() const { return _loops[_inner.front].face; }
    void popFront() { _inner.popFront(); }
    @property VertexFaceRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// VertexNeighborRange
// ---------------------------------------------------------------------------

/// Forward range over all vertices directly connected to a vertex by an edge.
/// For boundary vertices emits the extra neighbour at the open end of the fan.
/// Requires buildLoops() (uses vertLoop anchored to the fan start).
struct VertexNeighborRange {
    private const(Loop)[] _loops;
    private uint _start;
    private uint _cur;
    private bool _done;
    private bool _atExtra;
    private uint _steps;
    private enum uint MAX_STEPS = 1024;

    this(const(Loop)[] loops, uint startLi) {
        _loops   = loops;
        _start   = startLi;
        _cur     = startLi;
        _done    = (startLi == ~0u);
        _atExtra = false;
        _steps   = 0;
    }

    @property bool empty() const { return _done; }

    @property uint front() const
    in (!_done)
    {
        // Main darts: neighbour is the next vertex in the dart.
        // Extra boundary dart: the open-end vertex is prev(cur).vert.
        return _atExtra ? _loops[_loops[_cur].prev].vert
                        : _loops[_loops[_cur].next].vert;
    }

    void popFront()
    in (!_done)
    {
        if (_atExtra) { _done = true; return; }
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _atExtra = true; return; }
        if (++_steps >= MAX_STEPS) {
            warnMaxStepsExceeded("VertexNeighborRange");
            _done = true;
            return;
        }
        _cur = twinPrev;
        if (_cur == _start) _done = true;
    }

    @property VertexNeighborRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// VertexEdgeRange
// ---------------------------------------------------------------------------

/// Forward range over all edge indices incident to a vertex.
///
/// Uses vertLoop[vi] (anchored to the open start of the fan by buildLoops) and
/// walks via twin(prev(li)).  For boundary vertices, emits one extra edge at the
/// end — the boundary edge represented by prev(lastDart) — so all incident edges
/// are always yielded, whether the vertex is interior or on a boundary.
struct VertexEdgeRange {
    private const(Loop)[] _loops;
    private const(uint)[] _loopEdge;
    private uint _start;
    private uint _cur;
    private bool _done;
    private bool _atExtra;   // true while emitting the boundary extra edge
    private uint _steps;
    private enum uint MAX_STEPS = 1024;

    this(const(Loop)[] loops, const(uint)[] loopEdge, uint startLi) {
        _loops    = loops;
        _loopEdge = loopEdge;
        _start    = startLi;
        _cur      = startLi;
        _done     = (startLi == ~0u);
        _atExtra  = false;
        _steps    = 0;
    }

    @property bool empty() const { return _done; }

    @property uint front() const
    in (!_done)
    {
        return _atExtra ? _loopEdge[_loops[_cur].prev] : _loopEdge[_cur];
    }

    void popFront()
    in (!_done)
    {
        if (_atExtra) { _done = true; return; }
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _atExtra = true; return; }  // boundary: emit extra next
        if (++_steps >= MAX_STEPS) {
            warnMaxStepsExceeded("VertexEdgeRange");
            _done = true;
            return;
        }
        _cur = twinPrev;
        if (_cur == _start) _done = true;
    }

    @property VertexEdgeRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// EdgeFaceRange
// ---------------------------------------------------------------------------

/// Forward range over the 1–2 faces incident to an edge.
/// Finds the dart va→vb by walking darts around va (O(valence)).
/// Yields the face of that dart, then the face of its twin (if not boundary).
struct EdgeFaceRange {
    private uint[2] _faces;
    private uint    _count;
    private uint    _i;

    this(const(Loop)[] loops, const(uint[2])[] edges,
         const(uint)[] vertLoop, uint ei)
    {
        _count = 0; _i = 0;
        if (ei >= edges.length) return;
        uint va = edges[ei][0], vb = edges[ei][1];
        if (_tryFrom(loops, vertLoop, va, vb)) return;
        // task 0394 (consumer hardening): an inconsistently-wound patch
        // elsewhere in the mesh (e.g. a same-direction shared edge — see the
        // `makePolygonFromVerts` auto-orient fix, which now prevents this
        // going forward, but does nothing for already-corrupt imports/old
        // saves) can corrupt the dart fan at ONE endpoint of an otherwise
        // perfectly fine edge while leaving the OTHER endpoint's fan clean.
        // Retrying from vb before giving up recovers the incident faces in
        // that case instead of silently reporting none (which made Loop
        // Slice's `collectEdgeRing` a silent no-op). On a well-formed mesh
        // the first attempt always succeeds, so this retry never fires
        // there — inert by construction.
        _tryFrom(loops, vertLoop, vb, va);
    }

    /// Walk darts from `from`, looking for the one whose next vertex is
    /// `to`; on a hit, fills `_faces`/`_count` and returns true.
    private bool _tryFrom(const(Loop)[] loops, const(uint)[] vertLoop,
                           uint from, uint to)
    {
        if (from >= vertLoop.length || vertLoop[from] == ~0u) return false;
        foreach (li; VertexDartRange(loops, vertLoop[from])) {
            if (loops[loops[li].next].vert == to) {
                _faces[_count++] = loops[li].face;
                uint twin = loops[li].twin;
                if (twin != ~0u)
                    _faces[_count++] = loops[twin].face;
                return true;
            }
        }
        return false;
    }

    @property bool empty() const { return _i >= _count; }
    @property uint front() const { return _faces[_i]; }
    void popFront() { ++_i; }
    @property EdgeFaceRange save() const { return this; }
}

// ---------------------------------------------------------------------------
// AdjacentFaceRange
// ---------------------------------------------------------------------------

/// Forward range over all faces that share an edge with a given face.
/// Uses the half-edge twin links directly — no hash map needed.
/// Boundary edges (twin == ~0u) are skipped silently.
/// Each adjacent face is yielded once per shared edge (normally once per face).
struct AdjacentFaceRange {
    private const(Loop)[] _loops;
    private uint _start;  // faceLoop[fi]: first loop of the face
    private uint _cur;    // loop currently pointing at an adjacent face
    private bool _done;

    this(const(Loop)[] loops, uint faceStart) {
        _loops    = loops;
        _start    = faceStart;
        _cur      = faceStart;
        _done     = (faceStart == ~0u);
        if (!_done) _skipInvalid();
    }

    @property bool empty() const { return _done; }

    /// Index of the adjacent face reached via the current loop's twin.
    @property uint front() const
    in (!_done)
    { return _loops[_loops[_cur].twin].face; }

    void popFront()
    in (!_done)
    {
        _cur = _loops[_cur].next;
        if (_cur == _start) { _done = true; return; }
        _skipInvalid();
    }

    @property AdjacentFaceRange save() const { return this; }

private:
    void _skipInvalid() {
        while (_loops[_cur].twin == ~0u) {
            _cur = _loops[_cur].next;
            if (_cur == _start) { _done = true; return; }
        }
    }
}

// ---------------------------------------------------------------------------
// edgeKey
// ---------------------------------------------------------------------------

// Canonical edge key: always (min, max) packed into a ulong.
ulong edgeKey(uint a, uint b) {
    return a < b ? (cast(ulong)a << 32 | cast(ulong)b)
                 : (cast(ulong)b << 32 | cast(ulong)a);
}

// ---------------------------------------------------------------------------
// MeshCacheKey.matches: address is the sole discriminator when
// mutationVersion collides across two distinct Mesh instances.
// ---------------------------------------------------------------------------
unittest {
    Mesh a, b;
    a.vertices = [Vec3(0, 0, 0)];
    b.vertices = [Vec3(0, 0, 0)];
    a.mutationVersion = 7;
    b.mutationVersion = 7;   // hand-forced equal version — the aliasing hazard

    MeshCacheKey key;
    key.stamp(a);
    assert(key.matches(a), "key stamped from a must match a");
    assert(!key.matches(b),
        "key stamped from a must NOT match b even when mutationVersion is equal — "
        ~ "address is the sole discriminator");

    key.invalidate();
    assert(!key.matches(a), "invalidate() must fail every match");
    assert(!key.matches(b), "invalidate() must fail every match");
}

// ---------------------------------------------------------------------------
// vertexAdjacencyCSR provider isolation: two Mesh values at an equal
// hand-forced mutationVersion but DIFFERENT connectivity must yield
// DIFFERENT adjacency — each Mesh owns its own cache, so there is no
// address term to get wrong (the cache lives ON the object).
// ---------------------------------------------------------------------------
unittest {
    // a: a 4-cycle 0-1-2-3-0 (every vertex has 2 neighbors).
    Mesh a;
    a.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    a.resetSelection();
    a.addEdge(0, 1); a.addEdge(1, 2); a.addEdge(2, 3); a.addEdge(3, 0);

    // b: two disjoint edges 0-1, 2-3 (every vertex has 1 neighbor).
    Mesh b;
    b.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)];
    b.resetSelection();
    b.addEdge(0, 1); b.addEdge(2, 3);

    a.mutationVersion = 7;
    b.mutationVersion = 7;   // hand-forced equal version, same vertex count

    const(size_t)[] offA, offB;
    const(uint)[]    nbA,  nbB;
    a.vertexAdjacencyCSR(offA, nbA);
    b.vertexAdjacencyCSR(offB, nbB);

    // Vertex 0's neighbor set differs: {1, 3} in the cycle vs {1} alone
    // in the disjoint-edges mesh.
    assert(offA[1] - offA[0] == 2, "cycle: vertex 0 must have 2 neighbors");
    assert(offB[1] - offB[0] == 1, "disjoint edges: vertex 0 must have 1 neighbor");
    assert(nbA[offA[0] .. offA[1]] != nbB[offB[0] .. offB[1]],
        "equal mutationVersion must NOT make two distinct Mesh instances "
        ~ "share adjacency — each Mesh owns its own CSR cache");
}

// ---------------------------------------------------------------------------
// Task 0401 — negative/regression check: a TOPOLOGY-keyed cache must NOT
// rebuild on a position-only edit. vertexAdjacencyCSR keys purely on
// `mutationVersion` by design (topology never changed by a vertex move) —
// unlike the 3 caches this task fixes (subpatch preview / symmetry pairing /
// snap grid), which needed a Position-bus-driven invalidation ON TOP of
// their existing mutationVersion key. This test proves the fix did not
// widen — the version-silent noteChange(Position) contract stays exactly as
// silent to mutationVersion as before, so vertexAdjacencyCSR provably does
// not thrash on every gizmo drag frame.
// ---------------------------------------------------------------------------
unittest {
    import change_bus : MeshEditScope;

    Mesh m = makeCube();
    const(size_t)[] offA;
    const(uint)[]    nbA;
    m.vertexAdjacencyCSR(offA, nbA);
    ulong csrVerAfterBuild = m._adjCsrVer;
    ulong mutVerBefore     = m.mutationVersion;

    // Version-silent edit — exactly what an interactive gizmo drag/commit
    // does: mutate a vertex, note the Position change class, never bump
    // mutationVersion.
    m.vertices[0] = m.vertices[0] + Vec3(0.5f, 0, 0);
    m.noteChange(MeshEditScope.Position);
    assert(m.mutationVersion == mutVerBefore,
        "test setup must stay version-silent to mirror the gizmo path");

    const(size_t)[] offB;
    const(uint)[]    nbB;
    m.vertexAdjacencyCSR(offB, nbB);
    assert(m._adjCsrVer == csrVerAfterBuild,
        "task 0401: a position-only edit must NOT force the adjacency CSR "
        ~ "to rebuild — it stays topology-keyed by design and must be "
        ~ "unaffected by the Position-bus invalidation this task adds to "
        ~ "the subpatch preview / symmetry pairing / snap grid caches");
    assert(offA is offB && nbA is nbB,
        "no rebuild occurred ⇒ vertexAdjacencyCSR must hand back the "
        ~ "exact same cached arrays, not freshly rebuilt ones");
}

Mesh makeCube() {
    Mesh m;
    m.vertices = [
        Vec3(-0.5f, -0.5f, -0.5f), // 0
        Vec3( 0.5f, -0.5f, -0.5f), // 1
        Vec3( 0.5f,  0.5f, -0.5f), // 2
        Vec3(-0.5f,  0.5f, -0.5f), // 3
        Vec3(-0.5f, -0.5f,  0.5f), // 4
        Vec3( 0.5f, -0.5f,  0.5f), // 5
        Vec3( 0.5f,  0.5f,  0.5f), // 6
        Vec3(-0.5f,  0.5f,  0.5f), // 7
    ];
    m.addFace([0, 3, 2, 1]);
    m.addFace([4, 5, 6, 7]);
    m.addFace([0, 4, 7, 3]);
    m.addFace([1, 2, 6, 5]);
    m.addFace([3, 7, 6, 2]);
    m.addFace([0, 1, 5, 4]);
    m.buildLoops();
    return m;
}

// Double-sided quad: 4 verts in a diamond pattern at slight ±Z offsets so
// the front and back quads have well-defined non-degenerate normals. Each
// vertex has valence=2 (only the two adjacent diamond-boundary edges) — a
// rare manifold configuration that exercises the weld case for bevels at
// non-collinear angles. Only realistic way to construct this in vibe3d.
Mesh makeDiamond() {
    Mesh m;
    m.vertices = [
        Vec3(-1.0f,  0.0f,  0.05f),  // 0  left
        Vec3( 0.0f, -1.0f, -0.05f),  // 1  bottom
        Vec3( 1.0f,  0.0f,  0.05f),  // 2  right
        Vec3( 0.0f,  1.0f, -0.05f),  // 3  top
    ];
    m.addFace([0, 1, 2, 3]);   // front quad (+Z-ish)
    m.addFace([0, 3, 2, 1]);   // back quad  (-Z-ish, opposite winding)
    m.buildLoops();
    return m;
}

// Regular octahedron centered at origin with verts on the unit axes. Every
// vertex has valence=4, every face is a triangle, and the 3 face normals
// meeting at any vertex are NON-perpendicular (the dihedral is ~109.47°).
// Useful for testing the cube-corner cap algorithm on non-orthogonal frame
// normals (the unit-cube affine map handles any linearly-independent normals).
Mesh makeOctahedron() {
    Mesh m;
    m.vertices = [
        Vec3( 1, 0, 0),  // 0  +X
        Vec3(-1, 0, 0),  // 1  -X
        Vec3( 0, 1, 0),  // 2  +Y
        Vec3( 0,-1, 0),  // 3  -Y
        Vec3( 0, 0, 1),  // 4  +Z
        Vec3( 0, 0,-1),  // 5  -Z
    ];
    // 8 triangular faces, one per octant. Winding is CCW from outside.
    m.addFace([4, 0, 2]);  // +X +Y +Z
    m.addFace([4, 2, 1]);  // -X +Y +Z
    m.addFace([4, 1, 3]);  // -X -Y +Z
    m.addFace([4, 3, 0]);  // +X -Y +Z
    m.addFace([5, 2, 0]);  // +X +Y -Z
    m.addFace([5, 1, 2]);  // -X +Y -Z
    m.addFace([5, 3, 1]);  // -X -Y -Z
    m.addFace([5, 0, 3]);  // +X -Y -Z
    m.buildLoops();
    return m;
}

// L-shaped extrusion in the XY plane, depth 1 along Z. Profile (CCW from +Z):
//   (-1,-1) → (1,-1) → (1,0) → (0,0) → (0,1) → (-1,1)
// The vertex at (0, 0, ±0.5) sits at a CONCAVE corner — its interior
// dihedral on the L's bulk side is 270° (reflex), so the vertical edge
// connecting the two reflex corners is the canonical reflex/miter test edge.
Mesh makeLShape() {
    Mesh m;
    m.vertices = [
        Vec3(-1.0f, -1.0f,  0.5f), //  0 front: bottom-left
        Vec3( 1.0f, -1.0f,  0.5f), //  1 front: bottom-right
        Vec3( 1.0f,  0.0f,  0.5f), //  2 front: inner-bottom
        Vec3( 0.0f,  0.0f,  0.5f), //  3 front: REFLEX corner
        Vec3( 0.0f,  1.0f,  0.5f), //  4 front: inner-top
        Vec3(-1.0f,  1.0f,  0.5f), //  5 front: top-left
        Vec3(-1.0f, -1.0f, -0.5f), //  6 back: bottom-left
        Vec3( 1.0f, -1.0f, -0.5f), //  7 back: bottom-right
        Vec3( 1.0f,  0.0f, -0.5f), //  8 back: inner-bottom
        Vec3( 0.0f,  0.0f, -0.5f), //  9 back: REFLEX corner
        Vec3( 0.0f,  1.0f, -0.5f), // 10 back: inner-top
        Vec3(-1.0f,  1.0f, -0.5f), // 11 back: top-left
    ];
    m.addFace([0, 1, 2, 3, 4, 5]);     // front cap (+Z)
    m.addFace([6, 11, 10, 9, 8, 7]);   // back cap  (-Z)
    m.addFace([0, 6, 7, 1]);           // bottom side (-Y)
    m.addFace([1, 7, 8, 2]);           // right side  (+X, lower half)
    m.addFace([2, 8, 9, 3]);           // inner-bottom side (+Y, inner)
    m.addFace([3, 9, 10, 4]);          // inner-side       (+X, inner)
    m.addFace([4, 10, 11, 5]);         // top side    (+Y)
    m.addFace([5, 11, 6, 0]);          // left side   (-X)
    m.buildLoops();
    return m;
}

// Dense flat grid of quads on the XZ plane (y = 0), centered at the origin
// and spanning [-1, 1] on both axes — a regression-friendly perf mesh
// (predictable poly count; a flat plane is clean for falloff radius and
// symmetry pairing). `n` is the number of quads per side, so the grid has
// (n+1)×(n+1) vertices and n×n quad faces. 316 → 100 K faces.
//
// Built the same way as makeCube/makeOctahedron: lay out the vertices, then
// `addFace` each quad (which deduplicates the shared interior edges) and call
// buildLoops() so the result is a fully valid editable Mesh — loops,
// faceLoop, vertLoop, loopEdge, marks and edge dedup all populated. Selection,
// picking and symmetry pairing all depend on that half-edge structure.
Mesh makeGridPlane(int n) {
    Mesh m;
    if (n < 1) n = 1;
    immutable int side = n + 1;            // verts per row/column

    // Row-major vertex grid: index(i, j) = i * side + j, with i along Z
    // and j along X. Span the fixed [-1, 1] extent on both axes.
    m.vertices.length = cast(size_t)side * side;
    foreach (i; 0 .. side) {
        immutable float z = -1.0f + 2.0f * cast(float)i / cast(float)n;
        foreach (j; 0 .. side) {
            immutable float x = -1.0f + 2.0f * cast(float)j / cast(float)n;
            m.vertices[cast(size_t)i * side + j] = Vec3(x, 0.0f, z);
        }
    }

    // One quad per cell. CCW winding when viewed from +Y (the up axis):
    // (i,j) → (i,j+1) → (i+1,j+1) → (i+1,j). addFace dedups the interior
    // edges shared between neighbouring cells.
    foreach (i; 0 .. n) {
        foreach (j; 0 .. n) {
            immutable uint v00 = cast(uint)(cast(size_t)i * side + j);
            immutable uint v01 = v00 + 1;
            immutable uint v10 = cast(uint)(cast(size_t)(i + 1) * side + j);
            immutable uint v11 = v10 + 1;
            m.addFace([v00, v01, v11, v10]);
        }
    }
    m.buildLoops();
    return m;
}

// Catmull-Clark subdivision of a cube, `levels` deep — a dense rounded perf
// mesh with smoothing (complements the flat makeGridPlane). 7 levels →
// ~98 K faces. Reuses the existing OpenSubdiv back-end (OsdAccel.buildPreview,
// the same uniform Catmull-Clark the subpatch preview runs) rather than
// reimplementing the subdivision: mark every cube face subpatch, build the
// limit mesh at depth `levels`, then re-add its faces into a fresh Mesh via
// addFace + buildLoops. The preview mesh OsdAccel emits is position/edge/face
// only (it skips buildLoops and aliases faces into scratch buffers for the
// real-time path), so we copy its geometry into a clean, fully valid Mesh.
Mesh subdivideCube(int levels) {
    import subpatch_osd : OsdAccel;

    Mesh cage = makeCube();
    if (levels < 1) return cage;   // depth 0 → unchanged cube

    // makeCube leaves the subpatch marks empty; grow them, then mark every
    // face so OSD runs uniform (whole-mesh) Catmull-Clark.
    cage.resizeSubpatch();
    foreach (fi; 0 .. cage.faces.length) cage.setSubpatch(fi, true);

    OsdAccel      accel;
    Mesh          preview;
    SubpatchTrace trace;
    if (!accel.buildPreview(cage, levels, preview, trace))
        return cage;   // degenerate / OSD failure → fall back to the cage

    // Rebuild a clean Mesh from the preview's vertices + faces. The
    // preview's vertices are freshly allocated (safe to take), but its
    // faces alias OsdAccel's scratch buffers and it carries no loops, so
    // we re-add each face through addFace (deduping edges) + buildLoops.
    Mesh m;
    m.vertices = preview.vertices.dup;
    foreach (ref f; preview.faces)
        m.addFace(f.dup);
    m.buildLoops();
    return m;
}

unittest { // makeGridPlane: vertex/face/edge counts + half-edge validity
    // n×n quads → (n+1)² verts, n² faces. Edges: each cell has 4 edges, but
    // interior edges are shared → dedup count is the closed-form
    // 2·n·(n+1) (n+1 lines each way, each split into n segments).
    foreach (n; [1, 2, 3, 4]) {
        Mesh m = makeGridPlane(n);
        immutable size_t side = n + 1;
        assert(m.vertices.length == side * side);
        assert(m.faces.length    == cast(size_t)n * n);
        assert(m.edges.length    == cast(size_t)2 * n * (n + 1));

        // Half-edge structure must be fully populated: buildLoops emits one
        // loop per face-corner, and every face's loops must resolve.
        size_t totalCorners = 0;
        foreach (ref f; m.faces) totalCorners += f.length;
        assert(m.loops.length    == totalCorners);
        assert(m.faceLoop.length == m.faces.length);
        assert(m.loopEdge.length == m.loops.length);

        // Every vertex index referenced by a face is in range, and every
        // face is a quad on the y = 0 plane.
        foreach (ref f; m.faces) {
            assert(f.length == 4);
            foreach (vi; f) {
                assert(vi < m.vertices.length);
                assert(m.vertices[vi].y == 0.0f);
            }
        }
    }
}

unittest { // subdivideCube: counts match uniform Catmull-Clark + valid loops
    // Cube → uniform CC. After L passes a quad-only mesh has
    //   F = 6 · 4^L faces, E = 2·F edges (every edge shared by 2 quads),
    //   V = E − F + 2 (Euler, genus 0).
    foreach (L; [1, 2]) {
        Mesh m = subdivideCube(L);
        immutable size_t F = 6 * (4UL ^^ L);
        immutable size_t E = 2 * F;
        immutable size_t V = E - F + 2;
        assert(m.faces.length    == F);
        assert(m.edges.length    == E);
        assert(m.vertices.length == V);

        // Fully valid editable mesh: loops resolve, all quads, indices in range.
        size_t totalCorners = 0;
        foreach (ref f; m.faces) {
            assert(f.length == 4);
            totalCorners += f.length;
            foreach (vi; f) assert(vi < m.vertices.length);
        }
        assert(m.loops.length    == totalCorners);
        assert(m.faceLoop.length == m.faces.length);
        assert(m.loopEdge.length == m.loops.length);
    }
}

// ===========================================================================
// extendEdgesByMask (Edge Extend, Phase 1v2) — direct-call kernel test.
//
// Asserts EXACT topology (face index tuples) + positions (±1e-5) against the
// reference-verified golden values (plain coordinates — no provenance, fine in
// public code). The golden new-vert numbers + bridge tuples are frozen in
// doc/edge_extend_plan.md ("verified reference model").
//
// vibe3d's makeCube() indexes corners so that vert 6 = (0.5,0.5,0.5) and
// vert 7 = (-0.5,0.5,0.5), matching the reference cube's layout — so the
// reference golden tuples ([6,8,9,7] etc.) reproduce directly.
// ===========================================================================
version (unittest) {
    private void selectEdgeByEnds_(ref Mesh m, Vec3 a, Vec3 b) {
        // makeCube() / hand-built meshes leave the selection arrays empty; size
        // them once so selectEdge can index edgeMarks/edgeSelectionOrder.
        if (m.edgeMarks.length < m.edges.length) m.resizeEdgeSelection();
        foreach (i; 0 .. m.edges.length) {
            auto va = m.vertices[m.edges[i][0]];
            auto vb = m.vertices[m.edges[i][1]];
            bool match = ((va - a).length < 1e-4f && (vb - b).length < 1e-4f) ||
                         ((va - b).length < 1e-4f && (vb - a).length < 1e-4f);
            if (match) m.selectEdge(cast(int)i);
        }
    }
    private bool[] selMask_(ref Mesh m) {
        bool[] mask; mask.length = m.edges.length;
        foreach (i; 0 .. m.edges.length) mask[i] = (m.edgeMarks[i] & Mesh.Marks.Select) != 0;
        return mask;
    }
    private bool near_(Vec3 a, Vec3 b, float tol = 1e-5f) { return (a - b).length < tol; }
    // Find the index of the (sole) face whose vertex set equals `want` (order-
    // independent), then assert its directed tuple matches `tuple` up to a cyclic
    // rotation in the SAME orientation (winding) — a flipped bridge fails.
    private long findFaceByVerts_(ref Mesh m, uint[] want) {
        import std.algorithm : sort;
        auto ws = want.dup; ws.sort();
        foreach (fi, ref f; m.faces) {
            if (f.length != want.length) continue;
            auto fs = f.dup; fs.sort();
            if (fs == ws) return cast(long)fi;
        }
        return -1;
    }
    private bool tupleMatchesWound_(uint[] face, uint[] tuple) {
        if (face.length != tuple.length) return false;
        size_t n = face.length;
        // try every cyclic rotation of `face` (same orientation only)
        foreach (off; 0 .. n) {
            bool ok = true;
            foreach (j; 0 .. n)
                if (face[(off + j) % n] != tuple[j]) { ok = false; break; }
            if (ok) return true;
        }
        return false;
    }
}

unittest { // noteSelectionChange / marks-setter accumulation (change-bus Stage 5)
    import change_bus : SelDomain;
    import mesh_edit_delta : MeshEditScope;

    // Single setters accumulate Marks + the matching domain bit, and stay
    // version-stable (selection is not a version-bumping geometry change).
    {
        Mesh m = makeCube();
        m.resetSelection();
        m.pendingChanges_ = 0; m.pendingSelDomains_ = 0;
        const ver0 = m.mutationVersion;
        const top0 = m.topologyVersion;

        m.selectVertex(0);
        assert(m.pendingChanges_ & MeshEditScope.Marks, "selectVertex notes Marks");
        assert(m.pendingSelDomains_ & SelDomain.Vertex, "selectVertex notes Vertex domain");

        m.selectEdge(0);
        assert(m.pendingSelDomains_ & SelDomain.Edge, "selectEdge notes Edge domain");

        m.selectFace(0);
        assert(m.pendingSelDomains_ & SelDomain.Face, "selectFace notes Face domain");

        // All three domains accumulate (OR), and NO version bump occurred —
        // marks setters must remain version-stable.
        assert(m.pendingSelDomains_ ==
            (SelDomain.Vertex | SelDomain.Edge | SelDomain.Face),
            "domains OR-accumulate");
        assert(m.mutationVersion == ver0, "selection must NOT bump mutationVersion");
        assert(m.topologyVersion == top0, "selection must NOT bump topologyVersion");
    }

    // Bulk setXSelectedFrom compares-before-set: a no-op re-apply of the SAME
    // selection does not publish; a real change does.
    {
        Mesh m = makeCube();
        m.resetSelection();
        m.pendingChanges_ = 0; m.pendingSelDomains_ = 0;
        bool[] sel; sel.length = m.vertices.length;
        sel[2] = true;

        m.setVerticesSelectedFrom(sel);           // real change
        assert(m.pendingSelDomains_ & SelDomain.Vertex, "first apply publishes");

        m.pendingChanges_ = 0; m.pendingSelDomains_ = 0;
        m.setVerticesSelectedFrom(sel);           // identical re-apply: no-op
        assert(m.pendingSelDomains_ == 0,
            "re-applying identical selection must NOT publish");
        assert((m.pendingChanges_ & MeshEditScope.Marks) == 0,
            "no-op restore must NOT note Marks");

        sel[2] = false; sel[5] = true;            // actual change
        m.setVerticesSelectedFrom(sel);
        assert(m.pendingSelDomains_ & SelDomain.Vertex,
            "a real selection change publishes again");
    }

    // Bulk setXSelectedFrom restores the "deselected => order==0" invariant
    // for elements it deselects, matching the per-element select*/deselect*
    // setters. Establishes rank via the per-element path FIRST (so the
    // deselected element carries a real nonzero order, unlike the no-op
    // test above where index 2's order was already 0 from init) then
    // bulk-deselects it and checks: (a) its order is zeroed, (b) the
    // surviving element's rank is untouched, and (c) the order-counter
    // itself is untouched by the bulk call (proving rank monotonicity
    // isn't reset — a later per-element select continues from the prior
    // high-water mark rather than restarting).
    {
        Mesh m = makeCube();
        m.resetSelection();

        m.selectFace(0);
        m.selectFace(1);
        assert(m.faceSelectionOrder[0] == 1, "face 0 gets rank 1");
        assert(m.faceSelectionOrder[1] == 2, "face 1 gets rank 2");
        assert(m.faceSelectionOrderCounter == 2, "counter at 2 after two selects");

        bool[] fsel; fsel.length = m.faces.length;
        fsel[0] = true;                            // keep face 0, drop face 1
        m.setFacesSelectedFrom(fsel);

        assert(m.faceSelectionOrder[1] == 0,
            "bulk-deselected face's order is zeroed (the invariant)");
        assert(m.faceSelectionOrder[0] == 1,
            "surviving face keeps its rank");
        assert(m.selectedFaces[0] == true && m.selectedFaces[1] == false,
            "marks reflect the bulk apply");
        assert(m.faceSelectionOrderCounter == 2,
            "bulk deselect must NOT touch the order counter");

        m.selectFace(2);
        assert(m.faceSelectionOrder[2] == 3,
            "next per-element select continues the rank sequence (counter wasn't reset)");
        assert(m.faceSelectionOrderCounter == 3);

        // Mirror for the other two domains (vertex + edge) so all three
        // bulk setters are covered directly.
        m.selectVertex(0);
        m.selectVertex(1);
        assert(m.vertexSelectionOrder[0] == 1 && m.vertexSelectionOrder[1] == 2);
        assert(m.vertexSelectionOrderCounter == 2);
        bool[] vsel; vsel.length = m.vertices.length;
        vsel[0] = true;
        m.setVerticesSelectedFrom(vsel);
        assert(m.vertexSelectionOrder[1] == 0, "bulk-deselected vertex order zeroed");
        assert(m.vertexSelectionOrder[0] == 1, "surviving vertex keeps rank");
        assert(m.vertexSelectionOrderCounter == 2, "vertex counter untouched by bulk deselect");

        m.selectEdge(0);
        m.selectEdge(1);
        assert(m.edgeSelectionOrder[0] == 1 && m.edgeSelectionOrder[1] == 2);
        assert(m.edgeSelectionOrderCounter == 2);
        bool[] esel; esel.length = m.edges.length;
        esel[0] = true;
        m.setEdgesSelectedFrom(esel);
        assert(m.edgeSelectionOrder[1] == 0, "bulk-deselected edge order zeroed");
        assert(m.edgeSelectionOrder[0] == 1, "surviving edge keeps rank");
        assert(m.edgeSelectionOrderCounter == 2, "edge counter untouched by bulk deselect");
    }

    // clear* compares-before-set: clearing an already-empty selection is inert.
    {
        Mesh m = makeCube();
        m.resetSelection();
        m.pendingChanges_ = 0; m.pendingSelDomains_ = 0;
        m.clearFaceSelection();                   // nothing selected → inert
        assert(m.pendingSelDomains_ == 0,
            "clearing empty face selection must NOT publish");

        m.selectFace(1);
        m.pendingChanges_ = 0; m.pendingSelDomains_ = 0;
        m.clearFaceSelection();                   // drops a live selection
        assert(m.pendingSelDomains_ & SelDomain.Face,
            "clearing a live face selection publishes Face");
    }
}

unittest { // extendEdgesByMask: cube interior edge — identity, offset, rotate, scale, combined
    import std.math : abs;
    // ---- identity (inset=0.1, shift=0.2, no TRS) → 10v/7f, bridge [6,8,9,7] ----
    {
        Mesh m = makeCube();
        selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
        auto n = m.extendEdgesByMask(selMask_(m), 0.1f, 0.2f,
                                     Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
        assert(n == 1);
        assert(m.vertices.length == 10, "interior: 10 verts");
        assert(m.faces.length == 7, "interior: 7 faces");
        // 8 cube corners UNCHANGED (indices 0..7).
        Mesh ref_ = makeCube();
        foreach (i; 0 .. 8) assert(near_(m.vertices[i], ref_.vertices[i]), "cube corner moved");
        // new verts (vert 6 endpoint → +0.4, vert 7 endpoint → −0.4).
        // newVertOf[6] and newVertOf[7] — find by position.
        assert(near_(m.vertices[8], Vec3(0.4f, 0.4f, 0.4f)) ||
               near_(m.vertices[9], Vec3(0.4f, 0.4f, 0.4f)), "new vert (0.4,0.4,0.4)");
        assert(near_(m.vertices[8], Vec3(-0.4f, 0.4f, 0.4f)) ||
               near_(m.vertices[9], Vec3(-0.4f, 0.4f, 0.4f)), "new vert (-0.4,0.4,0.4)");
        // bridge tuple [6,8,9,7]: srcA=6,newA=8,newB=9,srcB=7 (8 welds to 6, 9 to 7).
        // Resolve actual new-vert indices for 6 and 7 by position.
        uint n6 = near_(m.vertices[8], Vec3(0.4f, 0.4f, 0.4f)) ? 8 : 9;
        uint n7 = (n6 == 8) ? 9 : 8;
        long bf = findFaceByVerts_(m, [6u, n6, n7, 7u]);
        assert(bf >= 0, "bridge face [6,n6,n7,7] exists");
        assert(tupleMatchesWound_(m.faces[bf], [6u, n6, n7, 7u]),
               "bridge winding [6,8,9,7]");
    }
    // ---- offset=(0,0.3,0) → new verts (±0.4, 0.7, 0.4) ----
    {
        Mesh m = makeCube();
        selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
        m.extendEdgesByMask(selMask_(m), 0.1f, 0.2f,
                            Vec3(0, 0.3f, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
        assert(near_(m.vertices[8], Vec3(0.4f, 0.7f, 0.4f)) ||
               near_(m.vertices[9], Vec3(0.4f, 0.7f, 0.4f)));
        assert(near_(m.vertices[8], Vec3(-0.4f, 0.7f, 0.4f)) ||
               near_(m.vertices[9], Vec3(-0.4f, 0.7f, 0.4f)));
    }
    // ---- rotZ=30° → (0.083013,0.583013,0.4) / (−0.583013,0.083013,0.4) ----
    {
        Mesh m = makeCube();
        selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
        m.extendEdgesByMask(selMask_(m), 0.1f, 0.2f,
                            Vec3(0, 0, 0), Vec3(0, 0, 30.0f), Vec3(1, 1, 1), 1);
        assert(near_(m.vertices[8], Vec3(0.083013f, 0.583013f, 0.4f)) ||
               near_(m.vertices[9], Vec3(0.083013f, 0.583013f, 0.4f)));
        assert(near_(m.vertices[8], Vec3(-0.583013f, 0.083013f, 0.4f)) ||
               near_(m.vertices[9], Vec3(-0.583013f, 0.083013f, 0.4f)));
    }
    // ---- sclX=2 → (±0.9, 0.4, 0.4) ----
    {
        Mesh m = makeCube();
        selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
        m.extendEdgesByMask(selMask_(m), 0.1f, 0.2f,
                            Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(2, 1, 1), 1);
        assert(near_(m.vertices[8], Vec3(0.9f, 0.4f, 0.4f)) ||
               near_(m.vertices[9], Vec3(0.9f, 0.4f, 0.4f)));
        assert(near_(m.vertices[8], Vec3(-0.9f, 0.4f, 0.4f)) ||
               near_(m.vertices[9], Vec3(-0.9f, 0.4f, 0.4f)));
    }
    // ---- combined offY=0.3 + rotZ=30 + sclX=2 →
    //      (0.266025,0.883013,0.4) / (−1.266025,0.383013,0.4) ----
    {
        Mesh m = makeCube();
        selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
        m.extendEdgesByMask(selMask_(m), 0.1f, 0.2f,
                            Vec3(0, 0.3f, 0), Vec3(0, 0, 30.0f), Vec3(2, 1, 1), 1);
        assert(near_(m.vertices[8], Vec3(0.266025f, 0.883013f, 0.4f), 2e-5f) ||
               near_(m.vertices[9], Vec3(0.266025f, 0.883013f, 0.4f), 2e-5f));
        assert(near_(m.vertices[8], Vec3(-1.266025f, 0.383013f, 0.4f), 2e-5f) ||
               near_(m.vertices[9], Vec3(-1.266025f, 0.383013f, 0.4f), 2e-5f));
    }
}

unittest { // extendEdgesByMask: pivot arg — rotZ=30 about a NONZERO pivot equals
           // the manually-conjugated expectation pivot + Rz(E_src − pivot) + delta.
    import std.math : sin, cos, PI;
    // The interior-edge inset delta (inset=0.1, shift=0.2 inert on interior) is
    // the cube min-norm meet (−0.1,−0.1,−0.1) for BOTH endpoints — reused from the
    // identity case above. We conjugate Rz(30) about pivot P and compare.
    Vec3 P = Vec3(0.2f, 0.1f, 0.0f);
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    auto n = m.extendEdgesByMask(selMask_(m), 0.1f, 0.2f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 30.0f), Vec3(1, 1, 1),
                                 1, /*pivot=*/P);
    assert(n == 1);
    assert(m.vertices.length == 10 && m.faces.length == 7);

    // Manual conjugation: for E_src, expect P + Rz(E_src − P) + insetShiftDelta.
    // The insetShiftDelta is the min-norm meet over the corner's faces and is
    // PIVOT-INDEPENDENT (computed from original geometry). Read it off the
    // identity golden: endpoint 6 (0.5,0.5,0.5)→(0.4,0.4,0.4) ⇒ delta6 =
    // (−0.1,−0.1,−0.1); endpoint 7 (−0.5,0.5,0.5)→(−0.4,0.4,0.4) ⇒ delta7 =
    // (+0.1,−0.1,−0.1) (its X meet points the other way).
    float a = cast(float)(30.0 * PI / 180.0);
    float cs = cos(a), sn = sin(a);
    Vec3 rzAbout(Vec3 src, Vec3 delta) {
        Vec3 q = src - P;
        Vec3 r = Vec3(cs * q.x - sn * q.y, sn * q.x + cs * q.y, q.z);
        return P + r + delta;
    }
    Vec3 want6 = rzAbout(Vec3(0.5f, 0.5f, 0.5f),  Vec3(-0.1f, -0.1f, -0.1f));
    Vec3 want7 = rzAbout(Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.1f, -0.1f, -0.1f));
    assert(near_(m.vertices[8], want6, 2e-5f) || near_(m.vertices[9], want6, 2e-5f),
           "pivot: new vert matches Rz about P at endpoint 6");
    assert(near_(m.vertices[8], want7, 2e-5f) || near_(m.vertices[9], want7, 2e-5f),
           "pivot: new vert matches Rz about P at endpoint 7");

    // Pivot=origin must reproduce the world-origin golden (byte-compat witness).
    Mesh m0 = makeCube();
    selectEdgeByEnds_(m0, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    m0.extendEdgesByMask(selMask_(m0), 0.1f, 0.2f,
                         Vec3(0, 0, 0), Vec3(0, 0, 30.0f), Vec3(1, 1, 1),
                         1, /*pivot=*/Vec3(0, 0, 0));
    assert(near_(m0.vertices[8], Vec3(0.083013f, 0.583013f, 0.4f)) ||
           near_(m0.vertices[9], Vec3(0.083013f, 0.583013f, 0.4f)),
           "pivot=origin reproduces world-origin golden");
}

unittest { // extendEdgesByMask: shift inert on interior edge (inset=0, shift=0.4)
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    auto n = m.extendEdgesByMask(selMask_(m), 0.0f, 0.4f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    assert(n == 1);
    // inset=0 ⇒ no perp/axial drop; shift inert on interior ⇒ new verts land
    // exactly on the source endpoints. Bridge still created.
    assert(m.faces.length == 7);
    assert(near_(m.vertices[8], Vec3(0.5f, 0.5f, 0.5f)) ||
           near_(m.vertices[9], Vec3(0.5f, 0.5f, 0.5f)));
    assert(near_(m.vertices[8], Vec3(-0.5f, 0.5f, 0.5f)) ||
           near_(m.vertices[9], Vec3(-0.5f, 0.5f, 0.5f)));
}

unittest { // extendEdgesByMask: chain2 weld (two top edges sharing corner (0.5,0.5,0.5))
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f)); // along -X from corner6
    selectEdgeByEnds_(m, Vec3(0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, -0.5f)); // along -Z from corner6
    auto n = m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    assert(n == 2);
    assert(m.vertices.length == 11, "chain2: 8 cube + 3 new = 11");
    assert(m.faces.length == 8, "chain2: 6 cube + 2 bridges");
    // Shared corner (vert 6) welds to ONE new vert at (0.4,0.4,0.4).
    long welded = -1;
    foreach (i; 8 .. m.vertices.length)
        if (near_(m.vertices[i], Vec3(0.4f, 0.4f, 0.4f))) { welded = cast(long)i; break; }
    assert(welded >= 0, "welded corner (0.4,0.4,0.4)");
    // Free ends: vert 7=(-0.5,0.5,0.5) → (-0.4,0.4,0.4); vert 2=(0.5,0.5,-0.5) → (0.4,0.4,-0.4).
    bool fe7 = false, fe2 = false;
    foreach (i; 8 .. m.vertices.length) {
        if (near_(m.vertices[i], Vec3(-0.4f, 0.4f, 0.4f))) fe7 = true;
        if (near_(m.vertices[i], Vec3(0.4f, 0.4f, -0.4f))) fe2 = true;
    }
    assert(fe7 && fe2, "chain2 free ends");
    // Two bridge quads, both reusing the welded vert.
    size_t bridgesWithWeld = 0;
    foreach (ref f; m.faces) {
        if (f.length != 4) continue;
        bool hasWeld = false, hasNew = false;
        foreach (vid; f) {
            if (vid == welded) hasWeld = true;
            if (vid >= 8) hasNew = true;
        }
        // a bridge has 2 source + 2 new verts (incl. the weld)
        size_t newCount = 0; foreach (vid; f) if (vid >= 8) ++newCount;
        if (hasWeld && newCount == 2) ++bridgesWithWeld;
    }
    assert(bridgesWithWeld == 2, "two bridges share the welded vert");
    // Exact DIRECTED bridge tuples (winding). vibe3d makeCube: corner=6, -X
    // neighbour=7→free7(-0.4,0.4,0.4), -Z neighbour=2→free2(0.4,0.4,-0.4).
    int findNew(Vec3 p) {
        foreach (i; 8 .. m.vertices.length) if (near_(m.vertices[i], p)) return cast(int)i;
        return -1;
    }
    int f7 = findNew(Vec3(-0.4f, 0.4f, 0.4f));
    int f2 = findNew(Vec3(0.4f, 0.4f, -0.4f));
    assert(f7 >= 0 && f2 >= 0, "chain2 free ends found");
    uint cr = 6u;
    //   -X edge {6,7}: srcA=corner srcB=7 → [corner, weld, free7, 7]
    //   -Z edge {6,2}: srcA=2 srcB=corner → [2, free2, weld, corner]
    long bX = findFaceByVerts_(m, [cr, cast(uint)welded, cast(uint)f7, 7u]);
    long bZ = findFaceByVerts_(m, [2u, cast(uint)f2, cast(uint)welded, cr]);
    assert(bX >= 0 && tupleMatchesWound_(m.faces[bX], [cr, cast(uint)welded, cast(uint)f7, 7u]),
           "chain2 -X bridge winding [corner,weld,free7,7]");
    assert(bZ >= 0 && tupleMatchesWound_(m.faces[bZ], [2u, cast(uint)f2, cast(uint)welded, cr]),
           "chain2 -Z bridge winding [2,free2,weld,corner]");
}

unittest { // extendEdgesByMask: star3 weld (three cube edges meeting at corner (0.5,0.5,0.5))
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));  // -X
    selectEdgeByEnds_(m, Vec3(0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, -0.5f));  // -Z
    selectEdgeByEnds_(m, Vec3(0.5f, 0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f));  // -Y
    auto n = m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    assert(n == 3);
    assert(m.vertices.length == 12, "star3: 8 cube + 4 new = 12");
    assert(m.faces.length == 9, "star3: 6 cube + 3 bridges");
    // The welded corner + the three free-end ridge verts, resolved by position
    // (new-vert array order is implementation-defined; find each geometrically).
    //   corner   (0.5, 0.5, 0.5) → weld   (0.4, 0.4, 0.4)
    //   -X neigh (-0.5,0.5, 0.5) → free7  (-0.4,0.4, 0.4)
    //   -Z neigh (0.5, 0.5,-0.5) → free2  (0.4, 0.4,-0.4)
    //   -Y neigh (0.5,-0.5, 0.5) → free5  (0.4,-0.4, 0.4)
    int findNew(Vec3 p) {
        foreach (i; 8 .. m.vertices.length) if (near_(m.vertices[i], p)) return cast(int)i;
        return -1;
    }
    int weld = findNew(Vec3(0.4f, 0.4f, 0.4f));
    int f7   = findNew(Vec3(-0.4f, 0.4f, 0.4f));
    int f2   = findNew(Vec3(0.4f, 0.4f, -0.4f));
    int f5   = findNew(Vec3(0.4f, -0.4f, 0.4f));
    assert(weld >= 0 && f7 >= 0 && f2 >= 0 && f5 >= 0, "star3 welded corner + 3 free ends");
    size_t bridgesWithWeld = 0;
    foreach (ref f; m.faces) {
        if (f.length != 4) continue;
        foreach (vid; f) if (vid == weld) { ++bridgesWithWeld; break; }
    }
    assert(bridgesWithWeld == 3, "three bridges reuse the welded corner vert");
    // Exact DIRECTED bridge tuples (winding) — the third (-Y) bridge is the one
    // that lower-index-by-array got backwards; the normal-comparator orienting
    // rule produces the reference-matching orientation:
    //   -X edge {6,7}: srcA=corner srcB=7 → [corner, weld, free7, 7]
    //   -Z edge {6,2-geom=vert2}: srcA=2  srcB=corner → [2, free2, weld, corner]
    //   -Y edge {6,5-geom=vert5}: srcA=corner srcB=5 → [corner, weld, free5, 5]
    uint cr = 6u;          // corner vert in vibe3d makeCube indexing
    uint nX = 7u, nZ = 2u, nY = 5u;   // -X / -Z / -Y geometric neighbours
    long bX = findFaceByVerts_(m, [cr, cast(uint)weld, cast(uint)f7, nX]);
    long bZ = findFaceByVerts_(m, [nZ, cast(uint)f2, cast(uint)weld, cr]);
    long bY = findFaceByVerts_(m, [cr, cast(uint)weld, cast(uint)f5, nY]);
    assert(bX >= 0 && tupleMatchesWound_(m.faces[bX], [cr, cast(uint)weld, cast(uint)f7, nX]),
           "star3 -X bridge winding [corner,weld,free7,7]");
    assert(bZ >= 0 && tupleMatchesWound_(m.faces[bZ], [nZ, cast(uint)f2, cast(uint)weld, cr]),
           "star3 -Z bridge winding [2,free2,weld,corner]");
    assert(bY >= 0 && tupleMatchesWound_(m.faces[bY], [cr, cast(uint)weld, cast(uint)f5, nY]),
           "star3 -Y bridge winding [corner,weld,free5,5]");
}

unittest { // extendEdgesByMask: boundary edge — bridge tuple proof + shift slide + inset
    import std.math : abs;
    // Build a single open quad face in the XZ plane: verts (0,1,4,3) layout from
    // the reference, normal (0,-1,0). The reference boundary capture used edge
    // (3,0) traversing 3→0 inside face [0,1,4,3], giving bridge [3,6,7,0].
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),   // 0
        Vec3(1, 0, 0),   // 1
        Vec3(0, 0, 0),   // placeholder (unused index 2)
        Vec3(0, 0, 1),   // 3
        Vec3(1, 0, 1),   // 4
    ];
    // Face [0,1,4,3] — a CCW quad in XZ. Newell normal:
    m.addFace([0u, 1u, 4u, 3u]);
    m.buildLoops();
    m.resetSelection();   // size selection arrays for the hand-built mesh
    Vec3 fn = m.faceNormal(0);
    // Boundary edge (3,0): inset=0.1, shift=0.2.
    selectEdgeByEnds_(m, m.vertices[3], m.vertices[0]);
    auto n = m.extendEdgesByMask(selMask_(m), 0.1f, 0.2f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    assert(n == 1);
    // 5 verts + 2 new = 7 (index 2 is an orphan but never welded/removed: pure
    // add does NOT compact). Faces: 1 source + 1 bridge.
    assert(m.faces.length == 2, "boundary: source + 1 bridge");
    // The two new verts sit at: src + (-inset·faceNormal) + (shift·inPlanePerp),
    // no axial term on a boundary free end. fn = (0,-1,0) ⇒ -inset·fn = (0,0.1,0).
    // Source verts 3=(0,0,1) and 0=(0,0,0); the in-plane outward perp slides them
    // off the open boundary by shift=0.2. Assert both new verts have y=0.1.
    uint na = 0, nb = 0; size_t cnt = 0;
    foreach (i; 5 .. m.vertices.length) { if (cnt == 0) na = cast(uint)i; else nb = cast(uint)i; ++cnt; }
    assert(cnt == 2, "boundary: 2 new verts");
    assert(abs(m.vertices[na].y - 0.1f) < 1e-5f && abs(m.vertices[nb].y - 0.1f) < 1e-5f,
           "boundary inset = -inset·faceNormal (y=0.1)");
    // Bridge tuple [3, na, nb, 0] (3→0 directed order within face [0,1,4,3]):
    // find the new vert welded to src 3 and to src 0.
    long bf = findFaceByVerts_(m, [3u, na, nb, 0u]);
    if (bf < 0) bf = findFaceByVerts_(m, [3u, nb, na, 0u]);
    assert(bf >= 0, "boundary bridge face contains {3, new, new, 0}");
}

unittest { // extendEdgesByMask: wire-edge / no-op — mask selecting nothing returns 0
    Mesh m = makeCube();
    auto v0 = m.vertices.length;
    auto f0 = m.faces.length;
    auto mut0 = m.mutationVersion;
    bool[] empty; empty.length = m.edges.length;   // all false
    auto n = m.extendEdgesByMask(empty, 0.1f, 0.2f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    assert(n == 0, "no-op returns 0");
    assert(m.vertices.length == v0 && m.faces.length == f0, "no-op: mesh unchanged");
    assert(m.mutationVersion == mut0, "no-op: no version bump");
}

unittest { // extendEdgesByMask: consumer smoke — ring-walk + faceted subdivide no-crash
    import std.array : array;
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    m.extendEdgesByMask(selMask_(m), 0.1f, 0.2f,
                        Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    // Ring-walk from the source-edge endpoints (verts 6 and 7) across the now
    // 3-face non-manifold edge must not crash/hang (degraded adjacency is
    // acceptable v1 — we only require termination + no exception).
    foreach (vi; [6u, 7u]) {
        size_t guard = 0;
        foreach (nb; m.verticesAroundVertex(vi)) {
            assert(nb < m.vertices.length);
            if (++guard > 1000) break;   // safety: a corrupt loop must not hang
        }
    }
    // One pure-D faceted subdivision of the extended mesh must not crash. (OSD
    // Catmull-Clark needs a GL context, unavailable in the unittest; faceted
    // subdivide exercises the same loop/adjacency consumers headlessly.)
    bool[] allFaces; allFaces.length = m.faces.length;
    allFaces[] = true;
    Mesh sub = facetedSubdivide(m, allFaces);
    assert(sub.vertices.length > m.vertices.length, "subdivide produced geometry");
    assert(sub.loops.length == sub.faceLoop.length * 0 + sub.loops.length); // touch loops
}

// ===========================================================================
// extendEdgesByMask — SEGMENTS (Phase 3). N stacked ring levels + N stacked
// bridge quads per edge. Per-ring law (verified against the reference dumps to
// ~1e-7, frozen golden numbers — no provenance):
//   ringVert_k(v) = (k/N)·offset + insetShiftDelta(FULL) + Scale_k(Rotate_k(E_src))
//     Rotate_k = (k/N)·rotateDeg (about origin); Scale_k = 1+(k/N)·(scale−1)
// segments=1 = the N=1 case of the same loop (regression-covered by the
// non-segments unittests above, which stay byte-identical).
// ===========================================================================
version (unittest) {
    // Find the source-edge ridge ring verts on a cube interior-edge extend and
    // return them ordered [ring1+x, ring1−x, ring2+x, ring2−x, …]. The +x ring
    // vert welds source vert 6=(0.5,0.5,0.5); −x welds vert 7=(-0.5,0.5,0.5).
    // Rings appear in append order (ring1 first), so for the cube interior edge
    // new verts are laid out as pairs [8,9],[10,11],…
    private bool extSegStackedWinding_(ref Mesh m, int N) {
        // Verify the N stacked bridge quads exist with the [innerA,outerA,outerB,
        // innerB] winding: bridge k = [ringVert(k-1,6), ringVert(k,6),
        // ringVert(k,7), ringVert(k-1,7)] with ring0 = the source verts 6/7.
        // New verts are appended ring-major, +x then −x per ring → ring k's
        // +x vert = 8+2*(k-1), −x vert = 9+2*(k-1).
        uint ringPlusX(int k)  { return (k == 0) ? 6u : cast(uint)(8 + 2 * (k - 1)); }
        uint ringMinusX(int k) { return (k == 0) ? 7u : cast(uint)(9 + 2 * (k - 1)); }
        foreach (k; 1 .. N + 1) {
            uint inA = ringPlusX(k - 1), outA = ringPlusX(k);
            uint outB = ringMinusX(k), inB = ringMinusX(k - 1);
            long bf = findFaceByVerts_(m, [inA, outA, outB, inB]);
            if (bf < 0 || !tupleMatchesWound_(m.faces[bf], [inA, outA, outB, inB]))
                return false;
        }
        return true;
    }
}

unittest { // extendEdgesByMask seg3 IDENTITY — 14v/9f, 3 coincident ring pairs, stacked quads
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    auto n = m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 3);
    assert(n == 1);
    assert(m.vertices.length == 14, "seg3: 8 cube + 3 ring pairs = 14");
    assert(m.faces.length == 9, "seg3: 6 cube + 3 stacked bridges = 9");
    // Identity TRS ⇒ all 3 rings coincide at the full-inset ridge (±0.4,0.4,0.4).
    foreach (k; 0 .. 3) {
        assert(near_(m.vertices[8 + 2 * k], Vec3(0.4f, 0.4f, 0.4f)),
               "seg3 identity +x ring coincident at (0.4,0.4,0.4)");
        assert(near_(m.vertices[9 + 2 * k], Vec3(-0.4f, 0.4f, 0.4f)),
               "seg3 identity -x ring coincident at (-0.4,0.4,0.4)");
    }
    // 3 stacked quads with the correct winding (src→ring1→ring2→ring3).
    assert(extSegStackedWinding_(m, 3), "seg3 stacked quad winding");
}

unittest { // extendEdgesByMask seg3 offY=0.3 — ring Y = 0.4 + k/3·0.3 (0.5/0.6/0.7)
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                        Vec3(0, 0.3f, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 3);
    assert(m.vertices.length == 14 && m.faces.length == 9);
    // ring k: X/Z at ±0.4/0.4 (full inset every ring), Y = 0.4 + k/3·0.3.
    float[3] ringY = [0.5f, 0.6f, 0.7f];
    foreach (k; 0 .. 3) {
        assert(near_(m.vertices[8 + 2 * k], Vec3(0.4f, ringY[k], 0.4f)),
               "seg3 offY +x ring");
        assert(near_(m.vertices[9 + 2 * k], Vec3(-0.4f, ringY[k], 0.4f)),
               "seg3 offY -x ring");
    }
    assert(extSegStackedWinding_(m, 3), "seg3 offY stacked winding");
}

unittest { // extendEdgesByMask seg3 rotZ=30 — fractional rotation 10/20/30° (h_seg3_rotz30.json)
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                        Vec3(0, 0, 0), Vec3(0, 0, 30.0f), Vec3(1, 1, 1), 3);
    assert(m.vertices.length == 14 && m.faces.length == 9);
    // Golden ring verts (verbatim h_seg3_rotz30.json verts 8..13), +x then −x.
    Vec3[3] plusX = [Vec3(0.30557978f, 0.47922796f, 0.4f),
                     Vec3(0.19883624f, 0.54085636f, 0.4f),
                     Vec3(0.08301270f, 0.58301270f, 0.4f)];
    Vec3[3] minusX = [Vec3(-0.47922796f, 0.30557978f, 0.4f),
                      Vec3(-0.54085636f, 0.19883624f, 0.4f),
                      Vec3(-0.58301270f, 0.08301270f, 0.4f)];
    foreach (k; 0 .. 3) {
        assert(near_(m.vertices[8 + 2 * k], plusX[k], 2e-5f), "seg3 rotZ +x ring");
        assert(near_(m.vertices[9 + 2 * k], minusX[k], 2e-5f), "seg3 rotZ -x ring");
    }
    assert(extSegStackedWinding_(m, 3), "seg3 rotZ stacked winding");
}

unittest { // extendEdgesByMask seg3 sclX=2 — LINEAR-lerp scale 1.333/1.667/2.0 (h_seg3_sclx2.json)
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                        Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(2, 1, 1), 3);
    assert(m.vertices.length == 14 && m.faces.length == 9);
    // ring k scale = 1 + k/3·(2−1) = 1.333/1.667/2.0 → +x X = 0.5·scale − 0.1.
    // Golden verbatim (h_seg3_sclx2.json): ±0.5667 / ±0.7333 / ±0.9.
    float[3] plusXx  = [0.56666666f, 0.73333335f, 0.9f];
    foreach (k; 0 .. 3) {
        assert(near_(m.vertices[8 + 2 * k], Vec3(plusXx[k], 0.4f, 0.4f), 2e-5f),
               "seg3 sclX +x ring");
        assert(near_(m.vertices[9 + 2 * k], Vec3(-plusXx[k], 0.4f, 0.4f), 2e-5f),
               "seg3 sclX -x ring");
    }
    assert(extSegStackedWinding_(m, 3), "seg3 sclX stacked winding");
}

unittest { // extendEdgesByMask seg2 combined offY=0.3 + rotZ=30 (h_seg2_trs.json)
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                        Vec3(0, 0.3f, 0), Vec3(0, 0, 30.0f), Vec3(1, 1, 1), 2);
    assert(m.vertices.length == 12, "seg2: 8 cube + 2 ring pairs = 12");
    assert(m.faces.length == 8, "seg2: 6 cube + 2 stacked bridges = 8");
    // Golden verbatim (h_seg2_trs.json verts 8..11): +x then −x per ring.
    Vec3[2] plusX = [Vec3(0.25355339f, 0.66237241f, 0.4f),
                     Vec3(0.08301270f, 0.88301271f, 0.4f)];
    Vec3[2] minusX = [Vec3(-0.51237243f, 0.40355340f, 0.4f),
                      Vec3(-0.58301270f, 0.38301271f, 0.4f)];
    foreach (k; 0 .. 2) {
        assert(near_(m.vertices[8 + 2 * k], plusX[k], 2e-5f), "seg2 TRS +x ring");
        assert(near_(m.vertices[9 + 2 * k], minusX[k], 2e-5f), "seg2 TRS -x ring");
    }
    assert(extSegStackedWinding_(m, 2), "seg2 TRS stacked winding");
}

unittest { // extendEdgesByMask seg2 chain2 weld — 2 levels × 3 welded verts, 4 quads
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f)); // -X from corner6
    selectEdgeByEnds_(m, Vec3(0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, -0.5f)); // -Z from corner6
    auto n = m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 2);
    assert(n == 2);
    // 8 cube + 2 ring levels × 3 welded verts (shared corner welds per level) = 14.
    assert(m.vertices.length == 14, "chain2 seg2: 8 + 2×3 = 14");
    // 6 cube + 2 edges × 2 stacked bridges = 10 faces.
    assert(m.faces.length == 10, "chain2 seg2: 6 + 4 bridges = 10");
    // Identity TRS ⇒ both ring levels coincide at the welded/free positions.
    // Welded corner (0.4,0.4,0.4) appears once per level (2 stacked welds).
    size_t weldCount = 0, freeCount = 0;
    foreach (i; 8 .. m.vertices.length) {
        if (near_(m.vertices[i], Vec3(0.4f, 0.4f, 0.4f))) ++weldCount;
        if (near_(m.vertices[i], Vec3(-0.4f, 0.4f, 0.4f)) ||
            near_(m.vertices[i], Vec3(0.4f, 0.4f, -0.4f))) ++freeCount;
    }
    assert(weldCount == 2, "chain2 seg2: welded corner once per ring level");
    assert(freeCount == 4, "chain2 seg2: 2 free ends × 2 levels");
}

unittest { // extendEdgesByMask seg3 — outermost ring selected on exit
    Mesh m = makeCube();
    selectEdgeByEnds_(m, Vec3(-0.5f, 0.5f, 0.5f), Vec3(0.5f, 0.5f, 0.5f));
    // offY makes the rings DISTINCT so the outermost-ring edge is unambiguous.
    m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                        Vec3(0, 0.3f, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 3);
    // The post-op selection must be EXACTLY the outermost ring's edge: endpoints
    // (±0.4, 0.7, 0.4) (ring 3, Y=0.7). Exactly one edge selected.
    size_t sel = 0; long selIdx = -1;
    foreach (i; 0 .. m.edges.length)
        if (m.edgeMarks[i] & Mesh.Marks.Select) { ++sel; selIdx = cast(long)i; }
    assert(sel == 1, "seg3: exactly the outermost ridge edge selected");
    auto va = m.vertices[m.edges[selIdx][0]];
    auto vb = m.vertices[m.edges[selIdx][1]];
    bool isOuter = (near_(va, Vec3(0.4f, 0.7f, 0.4f)) && near_(vb, Vec3(-0.4f, 0.7f, 0.4f))) ||
                   (near_(va, Vec3(-0.4f, 0.7f, 0.4f)) && near_(vb, Vec3(0.4f, 0.7f, 0.4f)));
    assert(isOuter, "seg3: selected edge is the OUTERMOST ring (Y=0.7)");
}

// ===========================================================================
// Twin-graph invariant tests — cube control guard (R1) + non-manifold book.
//
// The cube-control test is the primary manifold byte-stability guard: no
// existing test asserted twin values or verticesAroundVertex multisets before
// this task.  The book test confirms treatment (A) — non-manifold spine loops
// get twin==~0u (boundary-like) — and that all ring walks terminate cleanly.
// ===========================================================================

unittest { // cube twin graph: involutive + complete + correct vertex ring (R1 guard)
    // A closed manifold cube has 24 loops (6 faces × 4 corners), 12 edges.
    // Every loop must have a valid twin (no boundary on a closed cube).
    Mesh m = makeCube();
    assert(m.loops.length == 24, "cube: 24 loops");
    assert(m.edges.length == 12, "cube: 12 edges");

    // Involutive: twin-of-twin == self for every loop.
    foreach (li; 0 .. m.loops.length) {
        uint t = m.loops[li].twin;
        assert(t != ~0u, "cube loop has no boundary twin");
        assert(m.loops[t].twin == cast(uint)li,
               "cube twin graph not involutive");
    }

    // verticesAroundVertex(0): cube vertex 0 is shared by 3 faces.
    // makeCube() defines faces [0,3,2,1], [0,4,7,3], [0,1,5,4]
    // → edges from 0: to 3, to 4, to 1 → neighbors {1, 3, 4}.
    import std.algorithm : sort;
    uint[] nb0;
    foreach (v; m.verticesAroundVertex(0)) nb0 ~= v;
    nb0.sort();
    assert(nb0 == [1u, 3u, 4u], "cube v0 neighbors must be {1,3,4}");
}

unittest { // non-manifold book: spine edge (3 faces) → all spine twins == ~0u (treatment A)
    // Three triangles sharing edge v0-v1 (the "spine"):
    //   face 0: [0,1,2],  face 1: [0,1,3],  face 2: [0,1,4]
    // After treatment A, the spine edge's 3 loops all get twin==~0u
    // (boundary-like).  Page edges (v0-v2, v0-v3, v0-v4, v1-v2, v1-v3,
    // v1-v4) are genuine boundary edges (one face each) → also twin==~0u.
    // Twin graph everywhere is trivially involutive (all boundary).
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),      // 0 — spine endpoint A
        Vec3(1, 0, 0),      // 1 — spine endpoint B
        Vec3(0.5f,  1, 0),  // 2 — page 0 tip
        Vec3(0.5f, -1, 0),  // 3 — page 1 tip
        Vec3(-0.5f, 0, 1),  // 4 — page 2 tip
    ];
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 1u, 3u]);
    m.addFace([0u, 1u, 4u]);
    m.buildLoops();

    // 3 triangles = 9 loops.  Spine + 6 page edges = 7 edges total.
    assert(m.loops.length == 9, "book: 9 loops");
    assert(m.edges.length == 7, "book: 7 edges (1 spine + 6 page)");

    // Find the spine edge index (shared by all 3 faces).
    uint spineEi = ~0u;
    foreach (ei; 0 .. m.edges.length) {
        uint va = m.edges[ei][0], vb = m.edges[ei][1];
        bool isSpine = (va == 0 && vb == 1) || (va == 1 && vb == 0);
        if (isSpine) { spineEi = cast(uint)ei; break; }
    }
    assert(spineEi != ~0u, "spine edge not found");

    // Under treatment A: all 3 spine loops must have twin==~0u.
    uint spineLoopCount = 0;
    foreach (li; 0 .. m.loops.length) {
        if (m.loopEdge[li] == spineEi) {
            assert(m.loops[li].twin == ~0u,
                   "spine loop twin must be ~0u under treatment A");
            ++spineLoopCount;
        }
    }
    assert(spineLoopCount == 3, "exactly 3 spine loops");

    // Twin graph is involutive everywhere (every non-~0u twin reciprocates).
    // On this all-boundary mesh every twin==~0u, so no pair violations.
    foreach (li; 0 .. m.loops.length) {
        uint t = m.loops[li].twin;
        if (t != ~0u)
            assert(m.loops[t].twin == cast(uint)li,
                   "twin graph not involutive at loop");
    }

    // Ring walks terminate (length is finite — no MAX_STEPS truncation needed).
    // verticesAroundVertex(0): all edges are boundary/non-manifold (twin==~0u).
    // The anchor walk starts at vertLoop[0] = dart from the last face that
    // wrote v0 in the serial seed pass.  With serial fill and faces in order
    // [0,1,2],[0,1,3],[0,1,4], the last face touching v0 is face 2 ([0,1,4]),
    // so vertLoop[0] = dart from face 2.  In face [0,1,4] the dart at v0 has
    // next=v1; prev-dart is the dart at v4, whose edge v0-v4 is boundary →
    // twin==~0u → _atExtra fires immediately.
    // Result: front=v1 (next of start dart), _atExtra front=v4.
    uint[] nb0;
    foreach (v; m.verticesAroundVertex(0)) nb0 ~= v;
    // Treatment A: walk truncates at first boundary/non-manifold edge.
    // Each spine vertex sees exactly 2 neighbors from its single anchored dart.
    assert(nb0.length == 2,
           "book v0: truncated to 2 neighbors under treatment A (boundary-like)");

    // Spine endpoint v1 is symmetric — also truncated to 2 neighbors.
    uint[] nb1;
    foreach (v; m.verticesAroundVertex(1)) nb1 ~= v;
    assert(nb1.length == 2, "book v1: truncated to 2 neighbors");

    // Page tip v2 has 2 incident edges (v0-v2 and v1-v2), both boundary → 2 neighbors.
    uint[] nb2;
    foreach (v; m.verticesAroundVertex(2)) nb2 ~= v;
    assert(nb2.length == 2, "book v2: exactly 2 neighbors");

    // adjacentFaces(face 0): all its edges are boundary/non-manifold (twin==~0u)
    // → AdjacentFaceRange skips them → 0 adjacent faces.
    uint adjCount = 0;
    foreach (_; m.adjacentFaces(0)) ++adjCount;
    assert(adjCount == 0,
           "book face 0: no adjacent faces (spine treated as boundary under A)");

    // edgesAroundVertex(0) terminates with a finite result.
    uint[] edgeRing0;
    foreach (e; m.edgesAroundVertex(0)) edgeRing0 ~= e;
    assert(edgeRing0.length > 0 && edgeRing0.length < 64,
           "book v0 edge ring terminates");

    // vertexAdjacencyCSR (relation D, edge-based) vs verticesAroundVertex(0)
    // (relation E, loop-based fan walk, already captured in nb0 above): on
    // this non-manifold vertex the two relations yield DIFFERENT neighbor
    // SETS. v0 has 4 incident edges (spine to v1, page edges to v2/v3/v4)
    // ⇒ CSR sees all 4 {1,2,3,4}; the loop-based fan walk truncates at the
    // first boundary/non-manifold dart and only ever sees 2 {1,4} (asserted
    // above). This is the concrete, runtime-checked reason `connect.d`'s
    // Vertices mode (loop-based, see `verticesAroundVertex` there) is left
    // unfolded onto `vertexAdjacencyCSR` in task 0190 — substituting CSR
    // there would silently change connected-component reachability on
    // non-manifold meshes. Guards against a future accidental fold.
    import std.algorithm : sort;
    const(size_t)[] csrOff;
    const(uint)[]   csrNbrs;
    m.vertexAdjacencyCSR(csrOff, csrNbrs);
    uint[] csrSet0 = csrNbrs[csrOff[0] .. csrOff[1]].dup;
    csrSet0.sort();
    uint[] loopSet0 = nb0.dup;
    loopSet0.sort();
    assert(csrSet0 != loopSet0,
        "book v0: CSR (edge-based, relation D) neighbor set must differ from "
        ~ "the loop-based verticesAroundVertex (relation E) set on this "
        ~ "non-manifold vertex — proves connect.d Vertices cannot be folded "
        ~ "onto vertexAdjacencyCSR without a behaviour change");
}

/// Faceted subdivide restricted to a face mask: each face where faceMask[fi]
/// is true is split into n quads using its centroid and edge midpoints — no
/// vertex smoothing, unlike Catmull-Clark. Non-selected faces sharing an edge
/// with a selected face are widened to include that edge's midpoint, keeping
/// the mesh manifold (no T-junctions). `faceMask` may be shorter than
/// m.faces.length — missing entries are treated as false. If no face is
/// selected the mesh is returned topologically unchanged.
Mesh facetedSubdivide(ref const Mesh m, const bool[] faceMask) {
    uint nV = cast(uint)m.vertices.length;
    uint nF = cast(uint)m.faces.length;
    uint nE = cast(uint)m.edges.length;

    bool isSelected(size_t fi) {
        return fi < faceMask.length && faceMask[fi];
    }

    // Map edge key → index in m.edges.
    uint[ulong] edgeLookup;
    foreach (i, e; m.edges)
        edgeLookup[edgeKey(e[0], e[1])] = cast(uint)i;

    // An edge is "active" (gets a midpoint) iff at least one adjacent face is
    // selected. Walking selected face perimeters is enough — an unselected
    // face by itself never activates its edges.
    bool[] edgeActive = new bool[](nE);
    foreach (fi, face; m.faces) {
        if (!isSelected(fi)) continue;
        uint len = cast(uint)face.length;
        foreach (i; 0 .. len) {
            uint ei = edgeLookup[edgeKey(face[i], face[(i + 1) % len])];
            edgeActive[ei] = true;
        }
    }

    // Output vertex layout: [original] [edge midpoints] [selected centroids].
    uint[] edgeMidIdx      = new uint[](nE);  edgeMidIdx[]      = uint.max;
    uint[] faceCentroidIdx = new uint[](nF);  faceCentroidIdx[] = uint.max;

    uint outVCount = nV;
    foreach (ei; 0 .. nE) if (edgeActive[ei]) {
        edgeMidIdx[ei] = outVCount++;
    }
    foreach (fi; 0 .. nF) if (isSelected(fi)) {
        faceCentroidIdx[fi] = outVCount++;
    }

    Mesh result;
    result.vertices.length = outVCount;
    foreach (vi; 0 .. nV) result.vertices[vi] = m.vertices[vi];
    foreach (ei; 0 .. nE) if (edgeActive[ei]) {
        Vec3 a = m.vertices[m.edges[ei][0]];
        Vec3 b = m.vertices[m.edges[ei][1]];
        result.vertices[edgeMidIdx[ei]] = (a + b) * 0.5f;
    }
    foreach (fi; 0 .. nF) if (isSelected(fi)) {
        result.vertices[faceCentroidIdx[fi]] = m.faceCentroid(cast(uint)fi);
    }

    uint[ulong] resultEdgeLookup;
    foreach (fi, face; m.faces) {
        uint len = cast(uint)face.length;
        if (isSelected(fi)) {
            uint cIdx = faceCentroidIdx[fi];
            foreach (i; 0 .. len) {
                uint vi0  = face[i];
                uint vi1  = face[(i + 1) % len];
                uint vim1 = face[(i + len - 1) % len];
                uint eFwd  = edgeLookup[edgeKey(vi0, vi1)];
                uint eBack = edgeLookup[edgeKey(vim1, vi0)];
                result.addFaceFast(resultEdgeLookup,
                    [vi0, edgeMidIdx[eFwd], cIdx, edgeMidIdx[eBack]]);
            }
        } else {
            // Keep shape but splice in midpoints of any edge that is shared
            // with a selected face.
            uint[] widened;
            foreach (i; 0 .. len) {
                uint v0 = face[i];
                uint v1 = face[(i + 1) % len];
                widened ~= v0;
                uint ei = edgeLookup[edgeKey(v0, v1)];
                if (edgeMidIdx[ei] != uint.max)
                    widened ~= edgeMidIdx[ei];
            }
            result.addFaceFast(resultEdgeLookup, widened);
        }
    }

    result.buildLoops();
    return result;
}

/// Smooth subdivide: faceted (linear) topology + one uniform-Laplacian relax
/// pass (λ = 0.5, 1 iteration, boundary-pinned). This is the "smooth" mode
/// of `mesh.subdivide` — it produces positions strictly between the flat
/// (faceted) limit and the Catmull-Clark limit.
///
/// Smoothing formula (Jacobi step): for each relaxable vert,
///   new[v] = old[v] + 0.5·(avg(edge-neighbors) − old[v])
/// where "old" is a snapshot taken before any updates (all updates are
/// simultaneous). This is the same convention as `mesh.smooth` (smooth.d).
///
/// In-scope divergence: this kernel uses a *uniform* Laplacian (all
/// edge-neighbors equally weighted). The reference smooth mode is
/// angle-weighted (driven by a max-smooth-angle parameter) — different math;
/// bit-parity with the reference is an explicit non-goal for this feature.
/// Boundary pinning is load-bearing for open meshes (prevents border collapse)
/// even though the unit-test cube is closed — do not remove as "dead code".
///
/// Partial-mask safety: only verts incident to ≥1 newly-created sub-face are
/// relaxed. Pre-existing cage verts that border only unrefined faces are
/// pinned, preventing silent corruption of faces the user never selected.
/// Under a full mask every vert is incident to a new sub-face, so the relax
/// set equals all non-boundary verts — reproduces the closed-cube analytic
/// golden: corner ≈ 5/12 ≈ 0.41667.
Mesh smoothSubdivide(ref const Mesh m, const bool[] faceMask)
{
    uint nFOrig = cast(uint)m.faces.length;

    bool isSelected(size_t fi) {
        return fi < faceMask.length && faceMask[fi];
    }

    // If nothing is selected, facetedSubdivide returns the mesh topologically
    // unchanged and the relax set is empty — return early.
    bool hadAny = false;
    foreach (fi; 0 .. nFOrig) if (isSelected(fi)) { hadAny = true; break; }
    if (!hadAny)
        return facetedSubdivide(m, faceMask);

    Mesh sub = facetedSubdivide(m, faceMask);

    // -----------------------------------------------------------------------
    // Build the relax set: verts incident to ≥1 newly-created sub-face.
    // A sub-face is "new" when it came from a *selected* input face.
    // Replay the same emit-cursor walk used by the selection rebuild so that
    // the "new" designation is derived the same way as in runFacetedFamily.
    // -----------------------------------------------------------------------
    bool[] faceIsNew = new bool[](sub.faces.length);
    {
        size_t cursor = 0;
        foreach (fi; 0 .. nFOrig) {
            bool sel      = isSelected(fi);
            size_t emitted = sel ? m.faces[fi].length : 1;
            foreach (j; 0 .. emitted) {
                if (sel && cursor < faceIsNew.length)
                    faceIsNew[cursor] = true;
                ++cursor;
            }
        }
    }

    bool[] relaxable = new bool[](sub.vertices.length);
    foreach (fi; 0 .. sub.faces.length) {
        if (!faceIsNew[fi]) continue;
        foreach (vi; sub.faces[fi])
            relaxable[vi] = true;
    }

    // Pin boundary verts (loop.twin == ~0u) to prevent border collapse on
    // open meshes. facetedSubdivide already called buildLoops() on sub.
    foreach (ref l; sub.loops) {
        if (l.twin == uint.max) {
            if (l.vert < relaxable.length)
                relaxable[l.vert] = false;
            uint nxt = sub.loops[l.next].vert;
            if (nxt < relaxable.length)
                relaxable[nxt] = false;
        }
    }

    // Neighbor lists — CSR vert→vert adjacency (relation D, edge-based, both
    // directions), same provider as smooth.d / updateConnectMask. Per-vertex
    // order is proven identical to the old inline
    // `foreach (e; sub.edges) { neighbors[e0]~=e1; neighbors[e1]~=e0; }`
    // build (Stage-0 parity unittest above), which the float-sum averaging
    // below depends on for bit-identical results. `sub` is a mutable local
    // (fresh from facetedSubdivide), so the non-const CSR call is legal.
    const(size_t)[] adjOff;
    const(uint)[]   adjNbrs;
    sub.vertexAdjacencyCSR(adjOff, adjNbrs);

    // One Jacobi Laplacian pass (λ = 0.5): read from `prev`, write to `cur`.
    Vec3[] prev = sub.vertices.dup;
    Vec3[] cur  = sub.vertices.dup;
    foreach (vi; 0 .. sub.vertices.length) {
        if (!relaxable[vi]) continue;
        auto nbrs = adjNbrs[adjOff[vi] .. adjOff[vi + 1]];
        if (nbrs.length == 0) continue;
        Vec3 sum = Vec3(0, 0, 0);
        foreach (nb; nbrs) sum = sum + prev[nb];
        Vec3 avg = sum * (1.0f / cast(float)nbrs.length);
        cur[vi].x = prev[vi].x + 0.5f * (avg.x - prev[vi].x);
        cur[vi].y = prev[vi].y + 0.5f * (avg.y - prev[vi].y);
        cur[vi].z = prev[vi].z + 0.5f * (avg.z - prev[vi].z);
    }
    sub.vertices = cur;

    return sub;
}

unittest { // smoothSubdivide: cube → same topology as faceted; corners ≈ 0.41667
    import std.math : fabs;
    Mesh m = makeCube();
    bool[] mask = new bool[](m.faces.length);
    mask[] = true;

    Mesh sm = smoothSubdivide(m, mask);

    // Topology: identical to facetedSubdivide (26 verts, 48 edges, 24 quads).
    assert(sm.vertices.length == 26,
        "smoothSubdivide: expected 26 verts, got " ~ sm.vertices.length.stringof);
    assert(sm.edges.length    == 48,
        "smoothSubdivide: expected 48 edges");
    assert(sm.faces.length    == 24,
        "smoothSubdivide: expected 24 faces");

    // Analytic golden for cube corners after one Laplacian pass (λ=0.5):
    // Original corner at (0.5, 0.5, 0.5) has exactly 3 edge-midpoint
    // neighbors after faceted split. avg = (1/3, 1/3, 1/3) (by symmetry).
    // new = 0.5 + 0.5*(1/3 - 0.5) = 0.5 - 1/12 = 5/12 ≈ 0.41667.
    // facetedSubdivide preserves original vert indices: first 8 are cage corners.
    foreach (vi; 0 .. 8) {
        Vec3 v = sm.vertices[vi];
        assert(fabs(fabs(v.x) - 5.0f/12.0f) < 1e-4f
            && fabs(fabs(v.y) - 5.0f/12.0f) < 1e-4f
            && fabs(fabs(v.z) - 5.0f/12.0f) < 1e-4f,
            "smoothSubdivide: cage corner should relax to ≈ ±5/12 ≈ ±0.41667");
    }
}

/// Back-references mapping a subdivided mesh's vertices/edges/faces to an
/// "ultimate source" mesh (typically the cage). Indices are into the source
/// mesh; `uint.max` means the element was introduced by subdivision and has
/// no direct counterpart in the source. `subpatch` is the per-face mask that
/// drives the next subdivision pass.
struct SubpatchTrace {
    uint[] vertOrigin;
    uint[] edgeOrigin;
    uint[] faceOrigin;
    bool[] subpatch;

    /// Identity trace for `m`: every vert/edge/face traces to itself.
    /// `initialSubpatch` is copied into `subpatch`; missing entries default false.
    static SubpatchTrace identity(ref const Mesh m, const bool[] initialSubpatch) {
        SubpatchTrace t;
        t.vertOrigin = new uint[](m.vertices.length);
        t.edgeOrigin = new uint[](m.edges.length);
        t.faceOrigin = new uint[](m.faces.length);
        t.subpatch   = new bool[](m.faces.length);
        foreach (i; 0 .. m.vertices.length) t.vertOrigin[i] = cast(uint)i;
        foreach (i; 0 .. m.edges.length)    t.edgeOrigin[i] = cast(uint)i;
        foreach (i; 0 .. m.faces.length)    t.faceOrigin[i] = cast(uint)i;
        foreach (i; 0 .. m.faces.length)
            t.subpatch[i] = (i < initialSubpatch.length) && initialSubpatch[i];
        return t;
    }
}

/// Cached subdivision preview of a source (cage) mesh. When `active`
/// is true, `mesh`/`trace` hold the OpenSubdiv-emitted limit geometry;
/// otherwise the cage should be rendered directly and this struct is
/// inert. The cache rebuilds lazily when `source.mutationVersion` or
/// `depth` changes; drag-frame position updates go through the cached
/// `osdAccel` stencil table without touching topology.
struct SubpatchPreview {
    Mesh          mesh;
    SubpatchTrace trace;
    bool          active;
    /// Source mesh ADDRESS this preview was last built against (layers Stage
    /// 2). Two layers' cages can share an equal (mutationVersion,
    /// topologyVersion) — e.g. a layer.select swaps the preview source with no
    /// intervening mutation — so the address is part of the staleness key.
    /// With one layer this is constant ⇒ invisible. `size_t.max` forces a
    /// rebuild on first call.
    size_t        sourceMeshAddr        = size_t.max;
    ulong         sourceVersion         = ulong.max;
    /// Last source.topologyVersion we built against. While
    /// `source.topologyVersion` is unchanged but mutationVersion
    /// bumped (move/rotate/scale drag), we skip the full rebuild and
    /// re-evaluate stencil positions via `osdAccel.refresh`.
    ulong         sourceTopologyVersion = ulong.max;
    int           depth                 = -1;

    /// Reverse-lookup: for each CAGE vertex index, the preview-mesh
    /// vertex that carries its smoothed position (`uint.max` if no
    /// preview vert traces back to this cage vert). Built alongside
    /// `trace.vertOrigin[]` so the picking pipeline can iterate the
    /// 8 K cage verts instead of the 500 K+ preview verts at
    /// `subpatchDepth=3` (saves a ~60× factor in the per-frame
    /// hover-pick inner loop on subpatch meshes).
    uint[] cageVertPreview;

    /// OpenSubdiv back-end. Owns the cached topology + stencil table
    /// and drives both full rebuilds (buildPreview) and per-drag-frame
    /// position refreshes (refresh).
    import subpatch_osd : OsdAccel;
    OsdAccel      osdAccel;

    /// Phase 3b — set by the most recent rebuildIfStale fast-path
    /// when the OSD GPU fan-out wrote vibe3d's face VBO directly.
    /// Main loop reads this to skip the duplicate face-VBO write
    /// inside its standard `gpu.refreshPositions` call (uses
    /// refreshNonFacePositions instead).
    bool lastRefreshFannedOut;

    /// Phase 3c — set when face AND edge AND vert VBOs were all
    /// written via the GPU fan-out. Main loop skips
    /// refreshNonFacePositions entirely when this is true; no CPU
    /// position upload happens at all on the drag-frame fast path.
    bool lastRefreshSkipNonFace;

    // Tab-toggle fast reactivation: when the user toggles subpatch OFF, keep the
    // last preview mesh/trace around. If the next ON sees the exact same cage
    // geometry + face topology + subpatch mask + depth, reuse it and pay only the
    // preview GPU upload. This is deliberately stricter than topologyVersion:
    // setSubpatch bumps topologyVersion on every toggle, so version equality
    // cannot identify a true back-and-forth Tab reuse.
    ulong reusablePreviewKey;
    bool  reusablePreviewReady;

    import subpatch_osd : GpuFanOutTargets;

    /// Force the preview OFF and invalidate the staleness keys.
    ///
    /// A scene reset replaces the source mesh IN PLACE (same heap address,
    /// fresh contents), so a still-`active` preview whose cached
    /// (sourceMeshAddr, sourceVersion, depth) key happens to match the
    /// replacement would be left live by `rebuildIfStale`'s early-out — a
    /// cross-reset state leak. While the preview is live,
    /// `GpuMesh.suppressCageUpload` turns a tool-side cage upload into a bare
    /// `++mesh.mutationVersion` (the main loop owns the real upload). Those
    /// spurious version bumps then trip the transform tool's mutation-boundary
    /// poll, which resets the run and silently cancels an in-session falloff
    /// re-grade in the NEXT edit. Clearing the keys here forces the next
    /// `rebuildIfStale` to re-derive from scratch (and stay OFF for a
    /// non-subpatch mesh), so no reset can carry the preview into a fresh scene.
    void deactivate() {
        active                = false;
        sourceMeshAddr        = size_t.max;
        sourceVersion         = ulong.max;
        sourceTopologyVersion = ulong.max;
        depth                 = -1;
        reusablePreviewReady  = false;
        reusablePreviewKey    = 0;
    }

    private ulong computeReusablePreviewKey(ref const Mesh source, int d) const {
        import core.internal.hash : hashOf;
        ulong h = hashOf(d);
        h = hashOf(source.vertices.length, h);
        h = hashOf(source.edges.length, h);
        h = hashOf(source.faces.length, h);
        h = hashOf(source.vertices, h);
        h = hashOf(source.edges, h);
        foreach (face; source.faces) {
            h = hashOf(face.length, h);
            h = hashOf(face, h);
        }
        foreach (fi; 0 .. source.faces.length)
            h = hashOf(source.isFaceSubpatch(fi), h);
        return h == 0 ? 1 : h;
    }

    /// `targets` (when non-null) wires the GPU fan-out path: the
    /// position-only fast path attempts face, edge, vert dispatches
    /// in order, only doing the CPU readback fallback for the
    /// pieces that didn't make it onto GPU. Caller (app.d main loop)
    /// supplies gpu.{face,edge,vert}Vbo + matching counts.
    ///
    /// `positionsDirty` (task 0401): set true when the caller's
    /// change-notification bus flush saw a Position edit since the last
    /// call. An interactive gizmo Move/Rotate/Scale updates
    /// `source.vertices` WITHOUT bumping `source.mutationVersion` — both on
    /// drag AND on commit (see the warning above `deactivate()`) — so the
    /// (address, mutationVersion, depth) key just below can be, and after a
    /// committed drag IS, unchanged even though the cage moved. Skipping
    /// that raw-version early-out on a dirty signal lets the call fall
    /// through to the position-only fast path a few lines down (still
    /// gated on an UNCHANGED `source.topologyVersion`, so it never masks a
    /// real topology change) or, failing that, a full `rebuild`. Defaults
    /// to `false` so a caller with no bus signal in scope (the IPR path)
    /// keeps the original version-only behaviour.
    void rebuildIfStale(ref const Mesh source, int d,
                         const(GpuFanOutTargets)* targets = null,
                         bool positionsDirty = false) {
        lastRefreshFannedOut    = false;
        lastRefreshSkipNonFace  = false;
        const srcAddr = cast(size_t)&source;
        if (!positionsDirty
            && sourceMeshAddr == srcAddr
            && sourceVersion == source.mutationVersion && depth == d)
            return;
        // Position-only fast path: SAME source mesh, cage topology + depth
        // unchanged → ask OSD's stencil table for new limit positions. A
        // different source address (layer switch) must NOT take this path — the
        // cached stencil table belongs to the prior layer's cage.
        if (active
            && sourceMeshAddr == srcAddr
            && depth == d
            && sourceTopologyVersion == source.topologyVersion
            && osdAccel.valid)
        {
            bool didFace  = false;
            bool didEdges = false;
            bool didVerts = false;
            if (targets !is null && osdAccel.canFanOut
                && targets.faceVbo != 0
                && osdAccel.refreshIntoFaceVbo(source,
                        targets.faceVbo, targets.faceVertCount))
            {
                didFace = true;
                // GPU eval already ran inside refreshIntoFaceVbo.
                // limitGlVbo is hot — try the edge / vert dispatches
                // off the same data.
                if (targets.edgeVbo != 0 && osdAccel.canFanOutEdges
                    && osdAccel.refreshEdgeVbo(targets.edgeVbo,
                                                targets.edgeSegCount))
                    didEdges = true;
                if (targets.vertVbo != 0 && osdAccel.canFanOutVerts
                    && osdAccel.refreshVertVbo(targets.vertVbo,
                                                targets.vertCount))
                    didVerts = true;
            }

            if (didFace) {
                lastRefreshFannedOut = true;
                if (didEdges && didVerts) {
                    // Phase 3c — all three VBOs written on GPU.
                    // preview.vertices stays stale (no CPU readback)
                    // since no consumer needs it on the drag-frame
                    // path. Lasso mouse-up reads it via a one-shot
                    // sync (handled at the lasso site).
                    lastRefreshSkipNonFace = true;
                } else {
                    // Face on GPU, but edge or vert needed the CPU
                    // path → readback so refreshNonFacePositions
                    // sees fresh data.
                    osdAccel.readLimitIntoPreview(mesh);
                }
            } else {
                // Fan-out unavailable / layout mismatch — full CPU
                // (or GPU-with-readback) eval path.
                osdAccel.refresh(source, mesh);
            }
            ++mesh.mutationVersion;
            sourceMeshAddr = srcAddr;
            sourceVersion = source.mutationVersion;
            return;
        }
        if (!active && d > 0 && source.hasAnySubpatch()
            && reusablePreviewReady
            && reusablePreviewKey == computeReusablePreviewKey(source, d)
            && mesh.vertices.length != 0)
        {
            depth                 = d;
            sourceMeshAddr        = srcAddr;
            sourceVersion         = source.mutationVersion;
            sourceTopologyVersion = source.topologyVersion;
            active                = true;
            ++mesh.mutationVersion;
            return;
        }
        rebuild(source, d);
    }

    void rebuild(ref const Mesh source, int d) {
        depth                 = d;
        sourceMeshAddr        = cast(size_t)&source;
        sourceVersion         = source.mutationVersion;
        sourceTopologyVersion = source.topologyVersion;
        if (d <= 0) {
            cageVertPreview.length = 0;
            osdAccel.clear();
            mesh   = Mesh.init;
            trace  = SubpatchTrace.init;
            active = false;
            reusablePreviewReady = false;
            reusablePreviewKey   = 0;
            return;
        }
        if (!source.hasAnySubpatch()) {
            active = false;
            return;
        }

        cageVertPreview.length = 0;
        osdAccel.clear();

        // OsdAccel.buildPreview extracts the subpatch-marked subset
        // (the whole cage when `allSubpatch`, just a slice otherwise),
        // feeds it to OpenSubdiv, and emits the limit Mesh + trace.
        // Non-subpatch faces of the cage do not appear in the preview
        // in the selective case — see OsdAccel.buildPreview for the
        // trade-off rationale.
        if (!osdAccel.buildPreview(source, d, mesh, trace)) {
            // OSD topology creation failed on a degenerate input —
            // leave the preview inert rather than rendering stale
            // geometry. Callers fall through to rendering the cage.
            mesh   = Mesh.init;
            trace  = SubpatchTrace.init;
            active = false;
            reusablePreviewReady = false;
            reusablePreviewKey   = 0;
            return;
        }

        active = true;
        reusablePreviewKey   = computeReusablePreviewKey(source, d);
        reusablePreviewReady = true;
        cageVertPreview = new uint[](source.vertices.length);
        cageVertPreview[] = uint.max;
        foreach (pi, origin; trace.vertOrigin) {
            if (origin == uint.max) continue;
            if (origin >= cageVertPreview.length) continue;
            // First preview vert that maps back wins; for the
            // smoothed-original verts there's only one such vert per
            // cage vert anyway.
            if (cageVertPreview[origin] == uint.max)
                cageVertPreview[origin] = cast(uint)pi;
        }
    }
}

// ---------------------------------------------------------------------------
// edgeLoopRing — ordered quad edge-LOOP walk
// ---------------------------------------------------------------------------
//
// Given a seed edge (v0, v1), walk the quad EDGE LOOP it belongs to and
// return the ORDERED ring of vertex indices the loop passes through.
//
// "Edge loop" here is the classic modeling edge loop (NOT the edge RING):
// from a directed edge (prev → cur), the loop continues at vertex `cur`
// across to the one edge of `cur` that shares NO face with the incoming
// edge. On a valence-4 quad vertex that is the edge "straight across" the
// vertex (the two faces of the incoming edge sit on either side of it), so
// the loop runs perpendicular to those faces — e.g. on a subdivided cube a
// loop seeded by any edge of the band where the x=c plane cuts the cube
// follows that whole planar perimeter, wrapping the four side faces.
//
// The walk goes in BOTH directions from the seed and splices: forward from
// (v0 → v1) and backward from (v1 → v0). It terminates when it closes back
// on v0 (a closed ring) or when a vertex offers zero or >1 continuation
// (a boundary / pole / non-quad fan — an open or ambiguous loop). On a
// closed quad manifold the forward half closes and the full ordered ring
// is returned.
//
// Falls back to `[v0, v1]` (the seed edge endpoints) when the loop cannot
// be walked (degenerate edge, or the seed edge is absent), so callers
// always get a usable ≥2-vert ring.
//
// Pure: reads only `m.faces`; allocates the adjacency tables and the
// result on the GC, mutates nothing.
uint[] edgeLoopRing(const ref Mesh m, uint v0, uint v1) {
    const size_t nV = m.vertices.length;
    const size_t nF = m.faces.length;
    if (v0 == v1 || v0 >= nV || v1 >= nV) return [v0, v1];

    // Undirected edge key packed into a ulong (min,max). Build, per edge:
    //   * the set of incident face indices (edgeFaces)
    //   * per-vertex list of incident undirected-edge keys (vertEdges)
    static ulong key(uint a, uint b) {
        return (a < b) ? ((cast(ulong)a << 32) | b)
                       : ((cast(ulong)b << 32) | a);
    }
    int[][ulong] edgeFaces;
    ulong[][uint] vertEdges;
    foreach (fi; 0 .. nF) {
        auto f = m.faces[fi];
        const size_t k = f.length;
        if (k < 2) continue;
        foreach (c; 0 .. k) {
            uint a = f[c];
            uint b = f[(c + 1) % k];
            if (a == b) continue;
            ulong ek = key(a, b);
            edgeFaces[ek] ~= cast(int)fi;
            // Track membership without duplicates (small valence).
            bool haveA = false, haveB = false;
            foreach (x; vertEdges.get(a, null)) if (x == ek) { haveA = true; break; }
            foreach (x; vertEdges.get(b, null)) if (x == ek) { haveB = true; break; }
            if (!haveA) vertEdges[a] ~= ek;
            if (!haveB) vertEdges[b] ~= ek;
        }
    }

    if (key(v0, v1) !in edgeFaces) return [v0, v1];

    static uint otherEnd(ulong ek, uint v) {
        uint a = cast(uint)(ek >> 32);
        uint b = cast(uint)(ek & 0xffffffff);
        return (a == v) ? b : a;
    }

    // From the directed edge (prev → cur), find the single continuation
    // vertex of the edge loop at `cur`: the neighbor across an edge that
    // shares NO face with the incoming edge (prev,cur). Returns uint.max
    // when there is not exactly one such candidate (boundary / pole /
    // ambiguous fan → loop stops).
    uint nextLoopVert(uint prev, uint cur) {
        ulong inEk = key(prev, cur);
        auto inFaces = edgeFaces.get(inEk, null);
        uint found = uint.max;
        int count = 0;
        foreach (ek; vertEdges.get(cur, null)) {
            if (ek == inEk) continue;
            // Reject edges that share a face with the incoming edge — those
            // are the "ring" / co-face edges, not the loop continuation.
            bool sharesFace = false;
            foreach (f1; edgeFaces.get(ek, null))
                foreach (f0; inFaces)
                    if (f1 == f0) { sharesFace = true; break; }
            if (sharesFace) continue;
            count++;
            found = otherEnd(ek, cur);
        }
        return (count == 1) ? found : uint.max;
    }

    // Forward walk from (v0 → v1).
    uint[] fwd;
    {
        uint prev = v0, cur = v1;
        uint guard = 0;
        const uint maxSteps = cast(uint)(nV + 4);
        while (guard < maxSteps) {
            guard++;
            uint nx = nextLoopVert(prev, cur);
            if (nx == uint.max) break;          // open end / ambiguous
            if (nx == v0) { fwd ~= uint.max; break; }   // closed marker
            // Stop on any unexpected revisit (degenerate topology).
            bool dup = (nx == v1);
            foreach (x; fwd) if (x == nx) { dup = true; break; }
            if (dup) break;
            fwd ~= nx;
            prev = cur; cur = nx;
        }
    }

    bool closed = (fwd.length > 0 && fwd[$ - 1] == uint.max);
    if (closed) {
        uint[] ring;
        ring ~= v0;
        ring ~= v1;
        foreach (x; fwd) if (x != uint.max) ring ~= x;
        if (ring.length >= 3) return ring;
    }

    // Open / failed-to-close: also walk backward (v1 → v0) and splice
    // [reversed-back] + v0 + v1 + [forward].
    uint[] back;
    {
        uint prev = v1, cur = v0;
        uint guard = 0;
        const uint maxSteps = cast(uint)(nV + 4);
        while (guard < maxSteps) {
            guard++;
            uint nx = nextLoopVert(prev, cur);
            if (nx == uint.max || nx == v1) break;
            bool dup = (nx == v0);
            foreach (x; back) if (x == nx) { dup = true; break; }
            if (dup) break;
            back ~= nx;
            prev = cur; cur = nx;
        }
    }

    uint[] ring;
    foreach_reverse (x; back) ring ~= x;
    ring ~= v0;
    ring ~= v1;
    foreach (x; fwd) if (x != uint.max) ring ~= x;
    if (ring.length >= 2) return ring;
    return [v0, v1];
}

unittest { // edgeLoopRing: valence-3 cube degenerates to the seed-edge fallback
    // A plain cube's 8 corners are all valence-3, so the loop walk has no
    // unambiguous "straight across" continuation at any vertex and bails to
    // the seed-edge fallback `[v0, v1]`. Pin that documented limitation so a
    // regression that silently changed the cube's loop behaviour is caught;
    // the REAL closed-loop walk is exercised on the valence-4 torus below
    // (and end-to-end by tests/fixtures/element_move.json
    // `element_move_edgeloops_lin_r0p5`).
    Mesh cube = makeCube();   // 6 quad faces, 12 edges, 8 valence-3 verts
    auto e = cube.edges[0];
    auto fb = edgeLoopRing(cube, e[0], e[1]);
    assert(fb.length == 2);
    assert(fb[0] == e[0] && fb[1] == e[1]);
}

unittest { // edgeLoopRing walks a REAL closed loop on a valence-4 quad torus
    // Build a quad torus: R major rings × S minor segments, BOTH directions
    // wrapping. Every vertex is valence-4 and every face is a quad, so the
    // edge-loop walk has a well-defined "straight across" continuation at
    // each vertex — exactly the topology edgeLoopRing is designed for (unlike
    // the valence-3 cube above, which falls back to the seed edge).
    //
    //   idx(r, s) = (r % R) * S + (s % S)
    //   face q(r, s) = [idx(r,s), idx(r,s+1), idx(r+1,s+1), idx(r+1,s)]
    //
    // A seed along the MAJOR direction (fixed minor column s, stepping r)
    // continues straight across each valence-4 vertex to the next major
    // neighbour, wrapping the whole major circle: idx(0,0) → idx(1,0) →
    // idx(2,0) → idx(3,0) → back to idx(0,0). So the ring is the ordered
    // major circle of exactly R verts and is CLOSED.
    enum int R = 4;          // major rings
    enum int S = 3;          // minor segments
    Mesh m;
    m.vertices.length = R * S;
    foreach (r; 0 .. R)
        foreach (s; 0 .. S)
            m.vertices[r * S + s] = Vec3(cast(float)r, cast(float)s, 0.0f);

    static uint idx(int r, int s) { return cast(uint)(((r % R) * S) + (s % S)); }
    foreach (r; 0 .. R)
        foreach (s; 0 .. S)
            m.addFace([idx(r, s), idx(r, s + 1), idx(r + 1, s + 1), idx(r + 1, s)]);
    m.buildLoops();

    assert(m.vertices.length == R * S);   // 12 verts
    assert(m.faces.length    == R * S);   // 12 quad faces (closed torus)

    // Major-direction seed (0,0) → (1,0): expect the closed major circle.
    auto ring = edgeLoopRing(m, idx(0, 0), idx(1, 0));

    // (a) A real loop ran, not the 2-vert fallback.
    assert(ring.length > 2);
    // (b) It is the full closed major circle of exactly R verts.
    assert(ring.length == R);
    // (c) All verts are unique.
    foreach (i; 0 .. ring.length)
        foreach (j; i + 1 .. ring.length)
            assert(ring[i] != ring[j]);

    // The ring is the ordered major circle through column s == 0, i.e. each
    // entry is a multiple of S (no minor offset), and the four entries are
    // exactly the four major-circle verts. This nails the loop's identity,
    // not just its length.
    bool[uint] seen;
    foreach (v; ring) {
        assert(v % S == 0);                 // on the s == 0 minor column
        seen[v] = true;
    }
    foreach (r; 0 .. R)
        assert(idx(r, 0) in seen);          // every major-ring vert present

    // It forms a cycle: consecutive ring verts (wrapping last→first) are
    // each one major step apart (a mesh edge exists between them).
    foreach (i; 0 .. ring.length) {
        uint a = ring[i];
        uint b = ring[(i + 1) % ring.length];
        bool adjacent = false;
        foreach (ed; m.edges)
            if ((ed[0] == a && ed[1] == b) || (ed[0] == b && ed[1] == a)) {
                adjacent = true;
                break;
            }
        assert(adjacent);
    }
}

unittest { // ring verts → cage-edge-index mask (the edge-loop HOVER mask path)
    // Mirrors app.d's rebuildLoopHoverMask: walk the loop ring through a
    // hovered edge, then map each consecutive ring vert pair (CLOSED:
    // last→first too) back to its cage edge via edgeKey + edgeIndexMap. On a
    // CLOSED loop the mask has exactly `ring.length` edges set (one per pair,
    // wrapping). Built on the same valence-4 quad torus as the ring walk above.
    enum int R = 4;          // major rings
    enum int S = 3;          // minor segments
    Mesh m;
    m.vertices.length = R * S;
    foreach (r; 0 .. R)
        foreach (s; 0 .. S)
            m.vertices[r * S + s] = Vec3(cast(float)r, cast(float)s, 0.0f);
    static uint idx(int r, int s) { return cast(uint)(((r % R) * S) + (s % S)); }
    foreach (r; 0 .. R)
        foreach (s; 0 .. S)
            m.addFace([idx(r, s), idx(r, s + 1), idx(r + 1, s + 1), idx(r + 1, s)]);
    m.buildLoops();

    // Closed major circle through column s == 0: ring length == R.
    auto ring = edgeLoopRing(m, idx(0, 0), idx(1, 0));
    assert(ring.length == R);

    // Build the loop-edge mask exactly as rebuildLoopHoverMask does.
    auto mask = new bool[](m.edges.length);
    foreach (i; 0 .. ring.length) {
        uint a = ring[i];
        uint b = ring[(i + 1) % ring.length];
        if (a == b) continue;
        if (auto p = edgeKey(a, b) in m.edgeIndexMap) {
            uint ei = *p;
            assert(ei < mask.length);
            mask[ei] = true;
        }
    }

    // (a) Exactly R edges are set — one per consecutive pair, closed.
    int set = 0;
    foreach (e; mask) if (e) set++;
    assert(set == R);

    // (b) Each set edge is precisely a major-circle edge idx(r,0)→idx(r+1,0)
    //     and EVERY such edge is present (the full closed ring, no stray
    //     minor-direction or cross-loop edges).
    bool[ulong] expected;
    foreach (r; 0 .. R)
        expected[edgeKey(idx(r, 0), idx(r + 1, 0))] = true;
    assert(expected.length == R);   // R distinct major edges
    foreach (ei, e; mask) {
        if (!e) continue;
        ulong k = edgeKey(m.edges[ei][0], m.edges[ei][1]);
        assert(k in expected);      // every set edge is a major-circle edge
        expected.remove(k);
    }
    assert(expected.length == 0);   // every major edge was covered

    // (c) The single hovered seed edge is among the masked edges (the hover
    //     preview always contains the edge under the cursor).
    auto seed = m.edges[0];
    auto seedRing = edgeLoopRing(m, seed[0], seed[1]);
    auto seedMask = new bool[](m.edges.length);
    foreach (i; 0 .. seedRing.length) {
        uint a = seedRing[i], b = seedRing[(i + 1) % seedRing.length];
        if (a == b) continue;
        if (auto p = edgeKey(a, b) in m.edgeIndexMap) seedMask[*p] = true;
    }
    assert(seedMask[0]);            // edge 0 (the hovered seed) is lit
}

unittest { // flipFacesByMask: winding reversed, normal negated, edge set invariant, self-inverse
    import std.algorithm : sort;
    import std.conv : to;
    import mesh_edit_delta : MeshEditScope;

    Mesh m = makeCube();
    Mesh ref_ = makeCube(); // pristine reference for other-face comparison

    // Capture pre-flip state for face 0.
    auto face0Before = m.faces[0].dup;
    Vec3 norm0Before = m.faceNormal(0);

    // Capture the edge multiset (sorted canonical keys, order-independent).
    ulong[] edgesBefore;
    foreach (e; m.edges) edgesBefore ~= edgeKey(e[0], e[1]);
    edgesBefore.sort();

    // Flip face 0 only.
    auto mask = new bool[](m.faces.length);
    mask[0] = true;
    const n = m.flipFacesByMask(mask);
    assert(n == 1, "flipFacesByMask should report 1 flipped face");

    // Winding must be reversed.
    auto face0After = m.faces[0].dup;
    assert(face0After.length == face0Before.length, "face 0 arity changed");
    foreach (i; 0 .. face0Before.length)
        assert(face0After[i] == face0Before[face0Before.length - 1 - i],
               "face 0 corner " ~ i.to!string ~ " not reversed");

    // Normal must be negated (dot product < -0.99).
    Vec3 norm0After = m.faceNormal(0);
    assert(dot(norm0After, norm0Before) < -0.99f,
           "face 0 normal not negated after flip");

    // Edge set must be invariant (R1 guard).
    ulong[] edgesAfter;
    foreach (e; m.edges) edgesAfter ~= edgeKey(e[0], e[1]);
    edgesAfter.sort();
    assert(edgesAfter == edgesBefore, "edge set changed after flip (R1 violated)");

    // Other faces must be unchanged.
    foreach (fi; 1 .. m.faces.length)
        assert(m.faces[fi][] == ref_.faces[fi][],
               "untouched face " ~ fi.to!string ~ " changed after flip");

    // Self-inverse: flip face 0 a second time must restore original winding.
    m.flipFacesByMask(mask);
    assert(m.faces[0][] == face0Before[], "flip∘flip ≠ identity for face winding");

    // Empty mask (all-false) must be a no-op that returns 0.
    auto zeroMask = new bool[](m.faces.length);
    const n2 = m.flipFacesByMask(zeroMask);
    assert(n2 == 0, "all-false mask must return 0");
    assert(m.faces[0][] == face0Before[], "all-false mask must not mutate faces");
}

unittest { // flipFacesByMask: PolyVertex (UV) map follows reversed winding (R5)
    import std.conv : to;

    // Build a 2-face mesh (two quads sharing one edge) and attach a UV map.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), // 0
        Vec3(1,0,0), // 1
        Vec3(1,1,0), // 2
        Vec3(0,1,0), // 3
        Vec3(2,0,0), // 4
        Vec3(2,1,0), // 5
    ];
    m.addFace([0u, 1u, 2u, 3u]);  // face 0: 4 corners at loops 0..3
    m.addFace([1u, 4u, 5u, 2u]);  // face 1: 4 corners at loops 4..7
    m.buildLoops();

    // Register a PolyVertex UV map (dim=2).
    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null, "failed to register UV map");

    // Assign distinct per-corner UV values so reversal is detectable.
    uvMap.data = [
        0.0f, 0.0f,   // loop 0: face0 corner 0
        1.0f, 0.0f,   // loop 1: face0 corner 1
        1.0f, 1.0f,   // loop 2: face0 corner 2
        0.0f, 1.0f,   // loop 3: face0 corner 3
        1.0f, 0.0f,   // loop 4: face1 corner 0
        2.0f, 0.0f,   // loop 5: face1 corner 1
        2.0f, 1.0f,   // loop 6: face1 corner 2
        1.0f, 1.0f,   // loop 7: face1 corner 3
    ];
    auto origData = uvMap.data.dup;

    // Flip face 0 only.
    auto mask = new bool[](m.faces.length);
    mask[0] = true;
    m.flipFacesByMask(mask);

    // After flip, face 0's new corner j must carry the UV that was at old
    // corner (N-1-j): new corner 0 ← old corner 3, etc.
    auto mapAfter = m.meshMap(kUvMapName);
    assert(mapAfter !is null, "UV map lost after flip");

    const uint base0 = m.faceLoop[0]; // = 0 (arity preserved, same CSR offsets)
    const uint n0    = cast(uint) m.faces[0].length; // = 4
    foreach (j; 0 .. n0) {
        const size_t newSlot = (base0 + j) * 2;
        const size_t oldSlot = (base0 + (n0 - 1 - j)) * 2;
        assert(mapAfter.data[newSlot]     == origData[oldSlot],
               "UV u at new corner " ~ j.to!string ~ " not relocated");
        assert(mapAfter.data[newSlot + 1] == origData[oldSlot + 1],
               "UV v at new corner " ~ j.to!string ~ " not relocated");
    }

    // Face 1 corners must be byte-identical (untouched face).
    const uint base1 = m.faceLoop[1]; // = 4
    const uint n1    = cast(uint) m.faces[1].length; // = 4
    foreach (j; 0 .. n1) {
        const size_t slot = (base1 + j) * 2;
        assert(mapAfter.data[slot]     == origData[slot],
               "face1 UV u changed unexpectedly at corner " ~ j.to!string);
        assert(mapAfter.data[slot + 1] == origData[slot + 1],
               "face1 UV v changed unexpectedly at corner " ~ j.to!string);
    }

    // Self-inverse for UVs: flipping face 0 again must restore every value.
    m.flipFacesByMask(mask);
    auto mapRestored = m.meshMap(kUvMapName);
    assert(mapRestored !is null, "UV map lost after second flip");
    assert(mapRestored.data == origData,
           "flip∘flip must restore all UV per-corner values exactly");

    // No-UV-map branch: kernel must not crash and must NOT call remapPolyVertexMaps.
    Mesh mNoUV = makeCube();
    assert(mNoUV.meshMap(kUvMapName) is null, "makeCube should register no UV map");
    auto noUVMask = new bool[](mNoUV.faces.length);
    noUVMask[0] = true;
    const nNoUV = mNoUV.flipFacesByMask(noUVMask);
    assert(nNoUV == 1, "no-UV mesh: should report 1 flipped");
    assert(mNoUV.meshMap(kUvMapName) is null, "no UV map should remain absent");
}

// ---------------------------------------------------------------------------
// Triangulation-family kernel unittests (dub test --config=modeling gate)
// ---------------------------------------------------------------------------

unittest { // triangulateFacesByMask: cube (6 quads) → 12 tris, same verts
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto mask = new bool[](m.faces.length);
    mask[] = true;
    size_t changed = m.triangulateFacesByMask(mask);
    assert(changed == 6, "triple: expected 6 changed faces, got " ~ changed.to!string);
    assert(m.faces.length == 12, "triple: expected 12 faces");
    assert(m.vertices.length == 8, "triple: expected 8 verts (no new verts)");
    assert(m.edges.length == 18,   "triple: expected 18 edges");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 3,
            "triple: face " ~ fi.to!string ~ " is not a triangle");
}

unittest { // triangulateFacesByMask: subpatch bit propagates to children
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    // Mark face 0 as subpatch before triangulating.
    m.setFaceSubpatchFrom(new bool[](m.faces.length));  // ensure array exists
    auto sp = m.isSubpatch.dup;
    sp[0] = true;
    m.setFaceSubpatchFrom(sp);
    auto mask = new bool[](m.faces.length);
    mask[0] = true;  // only face 0
    m.triangulateFacesByMask(mask);
    // faces 0..n-1 are now 2 tris from old face 0; the rest are the 5 old quads.
    // The first two faces (children of old face 0) should be subpatch.
    assert(m.isFaceSubpatch(0), "child tri 0 should inherit parent subpatch bit");
    assert(m.isFaceSubpatch(1), "child tri 1 should inherit parent subpatch bit");
    // The old untouched faces start at index 2; none should be subpatch.
    foreach (fi; 2 .. m.faces.length)
        assert(!m.isFaceSubpatch(fi),
            "non-child face " ~ fi.to!string ~ " should not be subpatch");
}

unittest { // triangulateFacesByMask: faceOrigin maps children → parent
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto mask = new bool[](m.faces.length);
    mask[] = true;
    uint[] faceOrigin;
    m.triangulateFacesByMask(mask, &faceOrigin);
    assert(faceOrigin.length == 12,
        "faceOrigin length should match new face count");
    // Each original face produced 2 children; children 0,1 → parent 0,
    // children 2,3 → parent 1, etc. (fan always produces 2 tris from a quad).
    foreach (fi; 0 .. 12)
        assert(faceOrigin[fi] == fi / 2,
            "faceOrigin[" ~ fi.to!string ~ "] = " ~ faceOrigin[fi].to!string
            ~ ", expected " ~ (fi / 2).to!string);
}

unittest { // quadrupleFacesByMask: triple → quadruple round-trips a cube
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    m.triangulateFacesByMask(allF);
    assert(m.faces.length == 12);
    auto allF2 = new bool[](m.faces.length);
    allF2[] = true;
    size_t dissolved = m.quadrupleFacesByMask(allF2);
    assert(dissolved == 6,
        "quadruple: expected 6 edges dissolved (one diagonal per cube face), got "
        ~ dissolved.to!string);
    assert(m.faces.length == 6,  "quadruple: expected 6 faces");
    assert(m.vertices.length == 8, "quadruple: expected 8 verts");
    assert(m.edges.length == 12,   "quadruple: expected 12 edges");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 4,
            "quadruple: face " ~ fi.to!string ~ " is not a quad");
}

unittest { // quadrupleFacesByMask: planarity — every result quad is flat
    import std.conv : to;
    import math : dot;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    m.triangulateFacesByMask(allF);
    auto allF2 = new bool[](m.faces.length);
    allF2[] = true;
    m.quadrupleFacesByMask(allF2);
    foreach (fi; 0 .. m.faces.length) {
        assert(m.faces[fi].length == 4);
        // Split quad [a,b,c,d] into tris (a,b,c) and (a,c,d).
        auto f  = m.faces[fi];
        Vec3 pa = m.vertices[f[0]], pb = m.vertices[f[1]],
             pc = m.vertices[f[2]], pd = m.vertices[f[3]];
        import math : cross, normalize;
        import std.math : sqrt;
        Vec3 n1 = normalize(cross(pb - pa, pc - pa));
        Vec3 n2 = normalize(cross(pc - pa, pd - pa));
        float d = dot(n1, n2);
        assert(d > 0.999f,
            "quadruple planarity: face " ~ fi.to!string
            ~ " bent-quad dot=" ~ d.to!string);
    }
}

unittest { // detriangulateFacesByMask: triple → detriangulate round-trips a cube
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    m.triangulateFacesByMask(allF);
    assert(m.faces.length == 12);
    auto allF2 = new bool[](m.faces.length);
    allF2[] = true;
    size_t dissolved = m.detriangulateFacesByMask(allF2);
    assert(dissolved == 6,
        "detriangulate: expected 6 edges dissolved, got " ~ dissolved.to!string);
    assert(m.faces.length == 6,   "detriangulate: expected 6 faces");
    assert(m.vertices.length == 8,"detriangulate: expected 8 verts");
    assert(m.edges.length == 12,  "detriangulate: expected 12 edges");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length == 4,
            "detriangulate: face " ~ fi.to!string ~ " not a quad");
}

unittest { // detriangulateFacesByMask: partial mask — only masked faces merge
    // Mask only 2 tris (children of cube face 0) → 1 merge; other tris untouched.
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto allF = new bool[](m.faces.length);
    allF[] = true;
    uint[] faceOrigin;
    m.triangulateFacesByMask(allF, &faceOrigin);  // 12 tris
    // Find the 2 children of original face 0.
    bool[] partMask = new bool[](m.faces.length);
    foreach (fi; 0 .. faceOrigin.length)
        if (faceOrigin[fi] == 0) partMask[fi] = true;
    m.detriangulateFacesByMask(partMask);
    // 1 merge: 12 - 2 + 1 = 11 faces.
    assert(m.faces.length == 11,
        "detriangulate partial: expected 11 faces, got " ~ m.faces.length.to!string);
}

unittest { // insetFacesByMask: single flat quad — inset=0 still splits (task 0359
           // reference parity) + constant-centroid-distance corner law
    import std.math : abs, sqrt;
    import std.conv : to;
    // 1×1 quad at y=0, corners (±0.5, 0, ±0.5), winding [0,1,2,3], centroid
    // (0,0,0). Every corner is equidistant from the centroid (a square), so
    // moving "toward the centroid by an absolute distance of `inset`" lands
    // each corner at distance inset/sqrt(2) closer along BOTH its x and z
    // components (the diagonal toward the centroid).
    Mesh m;
    m.vertices = [
        Vec3(-0.5f, 0f, -0.5f), // 0
        Vec3( 0.5f, 0f, -0.5f), // 1
        Vec3( 0.5f, 0f,  0.5f), // 2
        Vec3(-0.5f, 0f,  0.5f), // 3
    ];
    m.addFace([0, 1, 2, 3]);
    m.buildLoops();

    // inset=0 is NOT a no-op (reference-matched, task 0359 toolcard
    // `behavior.default_value_is_not_skipped`): the split still happens,
    // landing the 4 new corners exactly on the 4 original ones (a
    // degenerate zero-width ring — same topology delta as any other inset).
    bool[] allOne = [true];
    assert(m.insetFacesByMask(allOne, 0.0f) == 1, "inset=0 must still process 1 face");
    assert(m.vertices.length == 8, "expected 8 verts after inset=0 split");
    assert(m.faces.length    == 5, "expected 5 faces (1 inner + 4 ring quads) after inset=0 split");
    bool hasVertExact(float x, float z) {
        foreach (v; m.vertices)
            if (abs(v.x - x) < 1e-5f && abs(v.z - z) < 1e-5f) return true;
        return false;
    }
    // Degenerate ring: the 4 new corners are bit-coincident with the 4
    // originals (2 verts at each of the 4 corner positions).
    foreach (x; [-0.5f, 0.5f])
        foreach (z; [-0.5f, 0.5f])
            assert(hasVertExact(x, z), "inset=0: degenerate corner missing at ("
                ~ x.to!string ~ ",0," ~ z.to!string ~ ")");

    // Fresh mesh for the inset=0.1 case (the inset=0 split above already
    // mutated `m`'s topology).
    Mesh m2;
    m2.vertices = m.vertices[0 .. 4].dup;
    m2.addFace([0, 1, 2, 3]);
    m2.buildLoops();

    // inset=0.1: 4 new verts, 4 ring quads + 1 inner face = 5 faces total.
    assert(m2.insetFacesByMask(allOne, 0.1f) == 1, "inset=0.1 must process 1 face");
    assert(m2.vertices.length == 8, "expected 8 verts after single-face inset");
    assert(m2.faces.length    == 5, "expected 5 faces (1 inner + 4 ring quads)");

    // Inner corners must be at (±(0.5 - 0.1/sqrt(2)), 0, ±(0.5 - 0.1/sqrt(2)))
    // — constant-absolute-distance-toward-centroid (task 0359), NOT the old
    // per-edge-miter ±0.4 law (which moved 0.1 along EACH axis independently,
    // i.e. inset*sqrt(2) total displacement — ruled out by the reference
    // capture, see toolcard `behavior.per_vertex_law`).
    immutable float d = 0.1f / sqrt(2.0f);
    bool hasVert(float x, float z) {
        foreach (v; m2.vertices)
            if (abs(v.x - x) < 1e-4f && abs(v.z - z) < 1e-4f) return true;
        return false;
    }
    assert(hasVert(-(0.5f - d), -(0.5f - d)), "inner corner missing (-,-)");
    assert(hasVert( (0.5f - d), -(0.5f - d)), "inner corner missing (+,-)");
    assert(hasVert( (0.5f - d),  (0.5f - d)), "inner corner missing (+,+)");
    assert(hasVert(-(0.5f - d),  (0.5f - d)), "inner corner missing (-,+)");
}

unittest { // bevelFacesByMask: cube top face, inset=0.1 shift=0.2
    import std.math : abs, sqrt;
    // Cube top face is index 4: [3,7,6,2], normal +Y.
    // Verts: 3=(-0.5,0.5,-0.5) 7=(-0.5,0.5,0.5) 6=(0.5,0.5,0.5) 2=(0.5,0.5,-0.5)
    // inset=0.1, shift=0.2 → cap corners at (±0.4, 0.7, ±0.4), ring connects to
    // original corners at y=0.5.  Total: 8+4=12 verts, 6−1+1+4=10 faces.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;

    // no-op guard
    assert(m.bevelFacesByMask(mask, 0.0f, 0.0f) == 0, "inset=0, shift=0 must be no-op");
    assert(m.vertices.length == 8);
    assert(m.faces.length    == 6);

    // inset=0.1, shift=0.2
    assert(m.bevelFacesByMask(mask, 0.1f, 0.2f) == 1, "should process 1 face");
    assert(m.vertices.length == 12, "expected 12 verts");
    assert(m.faces.length    == 10, "expected 10 faces");

    bool hasV(float x, float y, float z) {
        foreach (v; m.vertices)
            if (abs(v.x-x)<1e-4f && abs(v.y-y)<1e-4f && abs(v.z-z)<1e-4f) return true;
        return false;
    }
    // inner cap corners at y=0.7 (shifted by 0.2 from y=0.5)
    assert(hasV(-0.4f, 0.7f, -0.4f), "inner corner (-0.4,0.7,-0.4) missing");
    assert(hasV( 0.4f, 0.7f, -0.4f), "inner corner ( 0.4,0.7,-0.4) missing");
    assert(hasV( 0.4f, 0.7f,  0.4f), "inner corner ( 0.4,0.7, 0.4) missing");
    assert(hasV(-0.4f, 0.7f,  0.4f), "inner corner (-0.4,0.7, 0.4) missing");

    // shift-only: inset=0, shift=0.2 → cap corners at (±0.5, 0.7, ±0.5)
    auto m2 = makeCube();
    bool[] mask2; mask2.length = m2.faces.length; mask2[] = false; mask2[4] = true;
    assert(m2.bevelFacesByMask(mask2, 0.0f, 0.2f) == 1, "shift-only: should process 1 face");
    assert(m2.vertices.length == 12);
    assert(m2.faces.length    == 10);
    bool hasV2(float x, float y, float z) {
        foreach (v; m2.vertices)
            if (abs(v.x-x)<1e-4f && abs(v.y-y)<1e-4f && abs(v.z-z)<1e-4f) return true;
        return false;
    }
    assert(hasV2(-0.5f, 0.7f, -0.5f), "shift-only inner corner (-0.5,0.7,-0.5) missing");
    assert(hasV2( 0.5f, 0.7f, -0.5f), "shift-only inner corner ( 0.5,0.7,-0.5) missing");
    assert(hasV2( 0.5f, 0.7f,  0.5f), "shift-only inner corner ( 0.5,0.7, 0.5) missing");
    assert(hasV2(-0.5f, 0.7f,  0.5f), "shift-only inner corner (-0.5,0.7, 0.5) missing");
}

unittest { // bevelFacesByMask: overshoot guard (task 0304, fuzz-found) —
           // inset at/beyond the top face's inradius must never leave
           // coincident vertices or degenerate (zero-area) faces behind.
    import std.math : abs;
    import std.conv : to;

    float newellArea(Mesh m, const uint[] f) {
        Vec3 nsum = Vec3(0, 0, 0);
        foreach (i; 0 .. f.length) {
            Vec3 a = m.vertices[f[i]];
            Vec3 b = m.vertices[f[(i + 1) % f.length]];
            nsum.x += (a.y - b.y) * (a.z + b.z);
            nsum.y += (a.z - b.z) * (a.x + b.x);
            nsum.z += (a.x - b.x) * (a.y + b.y);
        }
        return nsum.length * 0.5f;
    }

    void assertClean(Mesh m, string tag) {
        foreach (i; 0 .. m.vertices.length)
            foreach (j; i + 1 .. m.vertices.length)
                assert((m.vertices[i] - m.vertices[j]).length > 1e-6f,
                    tag ~ ": coincident verts " ~ i.to!string ~ "," ~ j.to!string);
        foreach (fi, f; m.faces) {
            bool[uint] distinct;
            foreach (v; f) distinct[v] = true;
            assert(distinct.length >= 3,
                tag ~ ": face " ~ fi.to!string ~ " has <3 distinct verts");
            assert(newellArea(m, f) > 1e-9f,
                tag ~ ": face " ~ fi.to!string ~ " is degenerate (zero-area)");
        }
    }

    // Top face (index 4) has side length 1 → inradius 0.5. inset==0.5 is the
    // primary repro (all 4 cap corners used to collapse onto the centroid).
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
        size_t n = m.bevelFacesByMask(mask, 0.5f, 0.0f);
        assert(n == 1, "inset==inradius should still process (clamped)");
        assertClean(m, "inset==inradius");
    }

    // inset==2x inradius is the "lands on the diagonal corner" repro.
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
        size_t n = m.bevelFacesByMask(mask, 1.0f, 0.0f);
        assert(n == 1, "inset==2x inradius should still process (clamped)");
        assertClean(m, "inset==2x inradius");
    }

    // Sanity: a normal small inset must be completely unaffected by the guard.
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
        assert(m.bevelFacesByMask(mask, 0.1f, 0.0f) == 1);
        assert(m.vertices.length == 12, "normal inset must be unaffected by the overshoot guard");
        assert(m.faces.length    == 10);
    }
}

unittest { // bevelFacesByMask: group=true shared-corner accumulator manifold
           // cleanliness backstop (task 0391 Phase 4) — the 3-face
           // cube-corner grouped case (topology-diff-golden-verified via
           // test_fixture_poly_bevel_corner.d; this adds the winding/
           // manifold check the fixture harness cannot see, plus an exact
           // apex-position law check).
    import std.conv : to;

    void assertClean(ref Mesh m, string tag) {
        foreach (i; 0 .. m.vertices.length)
            foreach (j; i + 1 .. m.vertices.length)
                assert((m.vertices[i] - m.vertices[j]).length > 1e-6f,
                    tag ~ ": coincident verts " ~ i.to!string ~ "," ~ j.to!string);
        int[ulong] edgeUse;
        static ulong ekey(uint a, uint b) {
            return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
        }
        foreach (f; m.faces) {
            bool[uint] distinct;
            foreach (v; f) distinct[v] = true;
            assert(distinct.length >= 3, tag ~ ": degenerate face");
            foreach (k; 0 .. f.length) edgeUse[ekey(f[k], f[(k + 1) % f.length])]++;
        }
        foreach (key, count; edgeUse)
            assert(count == 2, tag ~ ": non-manifold edge (used by " ~
                count.to!string ~ " faces, expected 2)");
    }

    // +X, +Y, +Z faces of makeCube() all share corner 6=(0.5,0.5,0.5).
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[3] = true; // +X = [1,2,6,5]
    mask[4] = true; // +Y = [3,7,6,2]
    mask[1] = true; // +Z = [4,5,6,7]
    size_t n = m.bevelFacesByMask(mask, 0.15f, 0.1f, true, 0);
    assert(n == 3, "should process all 3 grouped faces");
    assert(m.vertices.length == 14, "expected 14 verts (8-1 orphaned apex-source+7 new)");
    assert(m.faces.length    == 12, "expected 12 faces");
    int[int] fvd;
    foreach (f; m.faces) fvd[cast(int)f.length]++;
    assert(fvd.get(4, 0) == 12, "grouped cap should be ALL quads (no triangle/pentagon)");
    assertClean(m, "grouped poly-bevel corner");

    // Exact apex-position law: orig corner + shift along EACH of the 3
    // group faces' own normals (NOT the averaged/normalized diagonal) —
    // capture-verified (0.5,0.5,0.5) + (0.1,0.1,0.1) = (0.6,0.6,0.6).
    bool foundApex = false;
    foreach (v; m.vertices)
        if ((v - Vec3(0.6f, 0.6f, 0.6f)).length < 1e-4f) foundApex = true;
    assert(foundApex, "grouped shared apex should sit at orig + per-face shift sum (0.6,0.6,0.6)");
}

unittest { // bevelFacesByMask: group=false is byte-identical to the pre-0391
           // kernel on the SAME 3-face-corner selection — the shared-corner
           // accumulator is opt-in only (task 0391 Phase 4 back-compat gate).
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[3] = true; mask[4] = true; mask[1] = true;
    size_t n = m.bevelFacesByMask(mask, 0.15f, 0.1f); // group defaults false, segments 0
    assert(n == 3);
    // Ungrouped: each face computes its OWN 4 independent corners — no
    // vertex is shared, so no orphaning, and no ring quad is suppressed.
    assert(m.vertices.length == 8 + 3 * 4, "ungrouped should add 4 new verts per face, no sharing/orphaning");
    assert(m.faces.length    == 6 + 3 * 4, "ungrouped should add 4 ring quads per face, none suppressed");
}

unittest { // bevelFacesByMask: Segments — LINEAR staircase law (task 0391
           // Phase 5, `vibe3d-divergence` from edge.bevel's Round Level TRUE
           // ARC — plain equal-lerp rings, not a circle). N=3 on a lone
           // face's pure inset (no shift) should land intermediate rings at
           // EXACTLY 1/3 and 2/3 of the final inset.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true; // +Y top face
    size_t n = m.bevelFacesByMask(mask, 0.3f, 0.0f, false, 3);
    assert(n == 1);
    // +4 verts per extra segment (2 intermediate rings of 4 corners each) +
    // the final ring (4) = +12 total; +4 ring quads per segment (3 segs ×
    // 4 edges = 12) vs. the flat case's 4.
    assert(m.vertices.length == 8 + 12, "expected 8+12=20 verts at segments=3");
    assert(m.faces.length    == 6 + 12, "expected 6+12=18 faces at segments=3 (3 rings x 4 edges)");
    // Top face corners start at y=0.5, x/z=±0.5; pure inset (no shift) pulls
    // each corner toward the centroid by 0.3 total over 3 equal steps —
    // 0.1 per step along BOTH in-plane axes (a 90° corner's offsetMeet is
    // additive per axis, verified above). Ring 1 (t=1/3) should land a
    // corner near (0.4, 0.5, 0.4); ring 2 (t=2/3) near (0.3, 0.5, 0.3).
    bool foundStep1 = false, foundStep2 = false;
    foreach (v; m.vertices) {
        if ((v - Vec3(0.4f, 0.5f, 0.4f)).length < 1e-4f) foundStep1 = true;
        if ((v - Vec3(0.3f, 0.5f, 0.3f)).length < 1e-4f) foundStep2 = true;
    }
    assert(foundStep1, "segments=3 should land an intermediate ring at exactly 1/3 inset");
    assert(foundStep2, "segments=3 should land an intermediate ring at exactly 2/3 inset");
}

unittest { // bevelFacesByMask: segments<=1 is byte-identical to the flat
           // (pre-0391) single-ring result — segs=0 == segs=1 == today.
    auto m0 = makeCube();
    auto m1 = makeCube();
    auto mF = makeCube();
    bool[] mask; mask.length = m0.faces.length; mask[] = false; mask[4] = true;
    assert(m0.bevelFacesByMask(mask, 0.1f, 0.2f, false, 0) == 1);
    assert(m1.bevelFacesByMask(mask, 0.1f, 0.2f, false, 1) == 1);
    assert(mF.bevelFacesByMask(mask, 0.1f, 0.2f)            == 1); // pre-0391 2-arg call site
    assert(m0.vertices.length == m1.vertices.length && m1.vertices.length == mF.vertices.length);
    assert(m0.faces.length    == m1.faces.length    && m1.faces.length    == mF.faces.length);
    foreach (i; 0 .. m0.vertices.length) {
        assert((m0.vertices[i] - m1.vertices[i]).length < 1e-6f, "segments=0 must equal segments=1");
        assert((m0.vertices[i] - mF.vertices[i]).length < 1e-6f, "segments=0 must equal the pre-0391 2-arg call");
    }
}

unittest { // bevelFacesByMask: segments DoS clamp — an absurd segment count
           // must clamp to MAX_BEVEL_SEGMENTS, not allocate N linear rings
           // (task 0391 Phase 5). A direct/scripted caller can reach this
           // kernel without the command/tool Param's `.max()` hint, which
           // is UI/HTTP-only and does not clamp this path.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
    size_t n = m.bevelFacesByMask(mask, 0.1f, 0.0f, false, 1_000_000);
    assert(n == 1, "should still process (segments clamped, not rejected)");
    // MAX_BEVEL_SEGMENTS=64 → 64 rings x 4 edges = 256 ring quads for this
    // one face — bounded, not the 1,000,000 the raw request would imply.
    assert(m.faces.length > 10 && m.faces.length < 400,
        "ring-quad count should reflect the CLAMPED segment count, not the raw request");
}

unittest { // bevelEdgesByMask: cube edge (6,7) between +Y and +Z faces, width=0.1
    import std.math : abs, sqrt;
    // Cube verts: 6=(0.5,0.5,0.5), 7=(-0.5,0.5,0.5).
    // Edge (6,7) is shared by face1=[4,5,6,7](+Z) and face4=[3,7,6,2](+Y).
    // After bevel: 10 verts (8+4-2), 7 faces, fv-dist {4:5,5:2}.
    // Chamfer centroid (0, 0.45, 0.45), chamfer normal points in (+Y+Z) dir.
    auto m = makeCube();

    // Find edge (6,7)
    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a==6&&b==7)||(a==7&&b==6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "edge (6,7) not found in cube");

    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;

    // width=0 must be no-op
    assert(m.bevelEdgesByMask(mask, 0.0f) == 0, "width=0 must be no-op");
    assert(m.vertices.length == 8);
    assert(m.faces.length    == 6);

    assert(m.bevelEdgesByMask(mask, 0.1f) == 1, "should process 1 edge");
    assert(m.vertices.length == 10, "expected 10 verts");
    assert(m.faces.length    == 7,  "expected 7 faces");

    // fv-dist: 5 quads (4-gons) + 2 pentagons (5-gons)
    int[int] fvd;
    foreach (f; m.faces) { int n = cast(int)f.length; fvd[n]++; }
    assert(fvd.get(4,0)==5 && fvd.get(5,0)==2, "fv-dist should be {4:5,5:2}");

    // Chamfer centroid = (0, 0.45, 0.45)
    // The chamfer face is the newly-selected face.
    Vec3 cen = Vec3(0,0,0);
    int chamferCount = 0;
    foreach (fi; 0..m.faces.length) {
        if (!m.isFaceSelected(fi)) continue;
        foreach (vi; m.faces[fi]) cen = cen + m.vertices[vi];
        chamferCount = cast(int)m.faces[fi].length;
        cen = cen * (1.0f / cast(float)chamferCount);
        break;
    }
    assert(chamferCount == 4, "chamfer should be a quad");
    assert(abs(cen.x) < 1e-3f && abs(cen.y-0.45f)<1e-3f && abs(cen.z-0.45f)<1e-3f,
           "chamfer centroid should be near (0,0.45,0.45)");

    // Winding: chamfer normal should point outward (dot with (0,1,1)/sqrt(2) > 0.9)
    Vec3 n = m.faceNormal(cast(uint)(m.faces.length-1));
    // The chamfer is the last face added — or we find it by selection.
    // Use the selected face.
    foreach (fi; 0..m.faces.length) {
        if (!m.isFaceSelected(fi)) continue;
        n = m.faceNormal(cast(uint)fi);
        break;
    }
    float dot = n.y * (1.0f/sqrt(2.0f)) + n.z * (1.0f/sqrt(2.0f));
    assert(dot > 0.9f, "chamfer normal should point outward (+Y+Z direction)");
}

unittest { // bevelEdgesByMask: overshoot guard (task 0304, fuzz-found) —
           // width == the length of the adjacent (non-bevel) edge must not
           // slide the chamfer corner onto — and duplicate — an existing
           // neighbor vertex, nor leave a zero-area face behind.
    import std.math : abs;
    import std.conv : to;

    float newellArea(Mesh m, const uint[] f) {
        Vec3 nsum = Vec3(0, 0, 0);
        foreach (i; 0 .. f.length) {
            Vec3 a = m.vertices[f[i]];
            Vec3 b = m.vertices[f[(i + 1) % f.length]];
            nsum.x += (a.y - b.y) * (a.z + b.z);
            nsum.y += (a.z - b.z) * (a.x + b.x);
            nsum.z += (a.x - b.x) * (a.y + b.y);
        }
        return nsum.length * 0.5f;
    }

    void assertClean(Mesh m, string tag) {
        foreach (i; 0 .. m.vertices.length)
            foreach (j; i + 1 .. m.vertices.length)
                assert((m.vertices[i] - m.vertices[j]).length > 1e-6f,
                    tag ~ ": coincident verts " ~ i.to!string ~ "," ~ j.to!string);
        foreach (fi, f; m.faces) {
            bool[uint] distinct;
            foreach (v; f) distinct[v] = true;
            assert(distinct.length >= 3,
                tag ~ ": face " ~ fi.to!string ~ " has <3 distinct verts");
            assert(newellArea(m, f) > 1e-9f,
                tag ~ ": face " ~ fi.to!string ~ " is degenerate (zero-area)");
        }
    }

    auto m = makeCube();
    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "edge (6,7) not found in cube");
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;

    // width == 1.0 == length of every adjacent (non-bevel) edge on a unit cube.
    size_t n = m.bevelEdgesByMask(mask, 1.0f);
    assert(n == 1, "width==adjacent edge length should still process (clamped)");
    assertClean(m, "width==adjacent edge length");

    // Sanity: a normal small width must be completely unaffected by the guard.
    auto m2 = makeCube();
    int ei2 = -1;
    foreach (i; 0 .. m2.edges.length) {
        uint a = m2.edges[i][0], b = m2.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei2 = cast(int)i; break; }
    }
    bool[] mask2; mask2.length = m2.edges.length; mask2[] = false; mask2[ei2] = true;
    assert(m2.bevelEdgesByMask(mask2, 0.1f) == 1);
    assert(m2.vertices.length == 10, "normal width must be unaffected by the overshoot guard");
    assert(m2.faces.length    == 7);
}

// Task 0391 Phase 1/2 winding-backstop helper: `runTopologyDiffSuite` only
// checks vertex-SET + face-COUNT (fixture_helpers.d:890), NOT face-vertex
// correspondence — a topologically-broken but position-correct cap (e.g.
// the old edge-bevel branch's per-face-independent junction caps, which
// double-welded / left non-manifold edges at the shared corner — the exact
// defect that opened this task) could still pass the fixture. This asserts
// true manifold cleanliness: every edge shared by EXACTLY 2 faces (no
// cracks, no non-manifold fans), no coincident vertices, no degenerate
// (zero-area or <3-distinct-vertex) faces, and the Euler characteristic
// V-E+F==2 (closed genus-0 — bevel must not change the mesh's topological
// genus, only add detail).
private void assertBevelManifoldClean(ref Mesh m, string tag) {
    import std.conv : to;

    foreach (i; 0 .. m.vertices.length)
        foreach (j; i + 1 .. m.vertices.length)
            assert((m.vertices[i] - m.vertices[j]).length > 1e-6f,
                tag ~ ": coincident verts " ~ i.to!string ~ "," ~ j.to!string);

    foreach (fi, f; m.faces) {
        bool[uint] distinct;
        foreach (v; f) distinct[v] = true;
        assert(distinct.length >= 3,
            tag ~ ": face " ~ fi.to!string ~ " has <3 distinct verts");
        Vec3 nsum = Vec3(0, 0, 0);
        foreach (k; 0 .. f.length) {
            Vec3 a = m.vertices[f[k]], b = m.vertices[f[(k + 1) % f.length]];
            nsum.x += (a.y - b.y) * (a.z + b.z);
            nsum.y += (a.z - b.z) * (a.x + b.x);
            nsum.z += (a.x - b.x) * (a.y + b.y);
        }
        assert(nsum.length * 0.5f > 1e-9f,
            tag ~ ": face " ~ fi.to!string ~ " is degenerate (zero-area)");
    }

    // Every physical edge must border EXACTLY 2 faces — a non-manifold
    // (0/1/3+) count here is precisely the double-weld / cracked-junction
    // defect class this backstop exists to catch.
    int[ulong] edgeUse;
    int[ulong] edgeWinding;
    uint[] vertexUse; vertexUse.length = m.vertices.length;
    static ulong ekey(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
    }
    foreach (f; m.faces)
        foreach (k; 0 .. f.length) {
            uint a = f[k], b = f[(k + 1) % f.length];
            edgeUse[ekey(a, b)]++;
            edgeWinding[ekey(a, b)] += a < b ? 1 : -1;
            ++vertexUse[a];
        }
    foreach (vi, count; vertexUse)
        assert(count > 0, tag ~ ": orphan vertex " ~ vi.to!string);
    size_t edgeCount = 0;
    foreach (key, count; edgeUse) {
        assert(count == 2, tag ~ ": non-manifold edge (used by " ~
            count.to!string ~ " faces, expected 2)");
        assert(edgeWinding[key] == 0,
            tag ~ ": co-oriented edge winding (both incident faces use the same direction)");
        ++edgeCount;
    }

    // Euler characteristic: V - E + F == 2 for a closed genus-0 mesh (a
    // beveled cube stays genus-0 — bevel only adds detail, never a handle).
    immutable long V = cast(long)m.vertices.length;
    immutable long E = cast(long)edgeCount;
    immutable long F = cast(long)m.faces.length;
    assert(V - E + F == 2,
        tag ~ ": Euler characteristic V-E+F=" ~ (V - E + F).to!string ~ " != 2");
}

unittest { // bevelEdgesByMask: LOOP cap manifold-cleanliness backstop
           // (task 0391 Phase 1) — the 4-edge top-face-perimeter loop.
    auto m = makeCube();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    static int findEdge(ref Mesh mm, uint va, uint vb) {
        foreach (i; 0 .. mm.edges.length) {
            uint a = mm.edges[i][0], b = mm.edges[i][1];
            if ((a == va && b == vb) || (a == vb && b == va)) return cast(int)i;
        }
        return -1;
    }
    // The +Z face's own perimeter in makeCube()'s vertex numbering (verts
    // 4,5,6,7 all sit at z=0.5) — structurally the same "one face's own
    // 4-edge boundary, every corner a K==2 loop turn" shape as the public
    // edge_bevel_loop.json fixture (which uses the +Y face instead).
    foreach (pair; [[4u,7u], [7u,6u], [6u,5u], [5u,4u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0, "loop perimeter edge not found");
        mask[ei] = true;
    }
    size_t n = m.bevelEdgesByMask(mask, 0.1f);
    assert(n == 4, "should process all 4 loop edges");
    assert(m.vertices.length == 12, "expected 12 verts");
    assert(m.faces.length    == 10, "expected 10 faces");
    int[int] fvd;
    foreach (f; m.faces) fvd[cast(int)f.length]++;
    assert(fvd.get(4, 0) == 10, "loop cap should be ALL quads (no triangle/pentagon)");
    assertBevelManifoldClean(m, "loop cap");
}

unittest { // bevelEdgesByMask: 3-WAY JUNCTION cap manifold-cleanliness
           // backstop (task 0391 Phase 2, highest-risk) — all 3 edges at one
           // cube corner selected together (hub-fill + 3 independent
           // bare-end pentagons in the SAME case).
    auto m = makeCube();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    static int findEdge(ref Mesh mm, uint va, uint vb) {
        foreach (i; 0 .. mm.edges.length) {
            uint a = mm.edges[i][0], b = mm.edges[i][1];
            if ((a == va && b == vb) || (a == vb && b == va)) return cast(int)i;
        }
        return -1;
    }
    // Corner 6=(0.5,0.5,0.5); its 3 edges go to 5=(0.5,0.5,-0.5),
    // 2=(0.5,-0.5,0.5), 7=(-0.5,0.5,0.5).
    foreach (pair; [[6u,5u], [6u,2u], [6u,7u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0, "junction edge not found");
        mask[ei] = true;
    }
    size_t n = m.bevelEdgesByMask(mask, 0.1f);
    assert(n == 3, "should process all 3 junction edges");
    assert(m.vertices.length == 13, "expected 13 verts (3 hubs + 6 bare-end + 4 untouched)");
    assert(m.faces.length    == 10, "expected 10 faces");
    int[int] fvd;
    foreach (f; m.faces) fvd[cast(int)f.length]++;
    assert(fvd.get(4, 0) == 6 && fvd.get(5, 0) == 3 && fvd.get(3, 0) == 1,
        "fv-dist should be {quad:6, pentagon:3, triangle:1}");
    assertBevelManifoldClean(m, "junction cap");
}

unittest { // bevelEdgesByMask: roundLevel DoS clamp — an absurd roundLevel
           // must clamp to MAX_ROUND_LEVEL, not allocate 2^L points (task
           // 0391 Phase 3). A direct/scripted caller can reach this kernel
           // without going through the command/tool Param's `.max()` hint,
           // which is UI/HTTP-only and does not clamp this path.
    auto m = makeCube();
    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    size_t n = m.bevelEdgesByMask(mask, 0.1f, 1_000_000);
    assert(n == 1, "should still process (roundLevel clamped, not rejected)");
    // MAX_ROUND_LEVEL=10 → 2·10=20 quad rings for this one edge — bounded,
    // not the ~2000000 the unclamped 2·request would imply.
    assert(m.faces.length > 7 && m.faces.length < 2100,
        "chamfer ring count should reflect the CLAMPED level, not the raw request");
}

unittest { // bevelEdgesByMask: selected interior edge with ONE endpoint on an
           // open-mesh boundary must NOT crash. The boundary endpoint itself
           // is now supported (the per-vertex pass walks its OPEN fan), so the
           // reason this case still no-ops has MOVED: the other endpoint is
           // the grid's fully interior vertex 4, a valence-FOUR free end
           // (K == 1). One of its faces then has both bordering edges
           // unselected with exactly ONE side active — the partial-notch
           // `keep V` branch, which has no free-end cap at valence > 3 and
           // would leave holes. The preflight rejects that shape before any
           // mutation, at every Round Level.
           //
           // Verified: with the notch guard removed this very mesh produces a
           // 12-edge rim where 8 is correct — i.e. the no-op is load-bearing,
           // not incidental. A proper valence>3 free-end cap needs its own
           // reference capture and is tracked separately.
    //   0   1   2
    //   3   4   5     <- 2x2 quad grid; vertex 4 is fully interior (valence
    //   6   7   8        4); vertex 1 is a top-boundary vertex (valence 3,
    //                     only 2 faces) — selecting edge (1,4) is interior
    //                     (shared by the 2 top faces) but asymmetric.
    Mesh m;
    m.vertices = [
        Vec3(-1, 1, 0), Vec3(0, 1, 0), Vec3(1, 1, 0),
        Vec3(-1, 0, 0), Vec3(0, 0, 0), Vec3(1, 0, 0),
        Vec3(-1,-1, 0), Vec3(0,-1, 0), Vec3(1,-1, 0),
    ];
    m.addFace([0, 3, 4, 1]);
    m.addFace([1, 4, 5, 2]);
    m.addFace([3, 6, 7, 4]);
    m.addFace([4, 7, 8, 5]);
    m.buildLoops();

    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 1 && b == 4) || (a == 4 && b == 1)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "edge (1,4) not found");
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;

    // Must return gracefully (0, silently-skipped) — NOT throw RangeError.
    size_t n = m.bevelEdgesByMask(mask, 0.1f);
    assert(n == 0, "boundary-adjacent asymmetric span should silently skip, not crash");
    assert(m.vertices.length == 9, "no-op should leave the mesh untouched");
    assert(m.faces.length    == 4);
}

unittest { // bevelEdgesByMask: roundLevel=1 end-to-end arc geometry — the
           // single isolated-edge case rounded to a true circular arc
           // (reference-captured law, edge.bevel spec behavior.miter_rail_law).
           // Cross-checked analytically: at vertex 6=(0.5,0.5,0.5), edge (6,7)
           // width=0.1's 2 flat L0 corners are E_A=(0.5,0.5,0.4) and
           // E_B=(0.5,0.4,0.5) (existing L0 unittest above). The arc rounds
           // the corner CONVEXLY, centred at C = E_A + E_B - V6 = (0.5,0.4,0.4)
           // with radius=width, so the L=1 45° bisector bulges TOWARD the
           // original corner: C + 0.1*normalize((0,1,1)) =
           // (0.5, 0.4 + 0.1/sqrt(2), 0.4 + 0.1/sqrt(2)). (The old V-centred
           // arc bulged the WRONG way, to 0.5 - 0.1/sqrt(2) — a concave notch.)
    import std.math : SQRT1_2, abs;
    import std.conv : to;
    auto m = makeCube();
    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 1);
    // +1 new interior arc vertex per endpoint (t=1 of 2); the single flat
    // chamfer quad splits into 2 quad rings (+1 face).
    assert(m.vertices.length == 12, "expected 10+2=12 verts at roundLevel=1");
    assert(m.faces.length    == 8,  "expected 7+1=8 faces at roundLevel=1");
    immutable float off = 0.1f * SQRT1_2;
    immutable Vec3 wantV6 = Vec3(0.5f, 0.4f + off, 0.4f + off);
    immutable Vec3 wantV7 = Vec3(-0.5f, 0.4f + off, 0.4f + off);
    bool foundV6 = false, foundV7 = false;
    foreach (v; m.vertices) {
        if ((v - wantV6).length < 1e-4f) foundV6 = true;
        if ((v - wantV7).length < 1e-4f) foundV7 = true;
    }
    assert(foundV6, "L=1 arc midpoint at vertex 6's end not found");
    assert(foundV7, "L=1 arc midpoint at vertex 7's end not found");

    // MANDATORY manifold backstop (post-review hardening): a rounded
    // chamfer strip subdivides its cross-section rail at BOTH endpoints;
    // the "back face" at each bare end must thread that SAME arc (not a
    // stale straight chord) or the rail's edges border only one face — a
    // non-manifold hole. Positions/counts alone (asserted above) do NOT
    // catch this — see the sibling loop/junction tests' own manifold
    // checks above, which this test was previously missing.
    assertBevelManifoldClean(m, "round L1");
    int[int] fvd;
    foreach (f; m.faces) fvd[cast(int)f.length]++;
    // Each back face (g0 at v0, g1 at v1) had V replaced by [predSide, 1
    // shared interior arc vertex, succSide] (n-1=1 interior point at L=1)
    // instead of the flat [predSide, succSide] pair — a quad losing 1
    // corner but gaining 3 gains a net +2 sides: 4→6 (hexagon), not a
    // pentagon (that's the L=0/flat 2-vertex-split shape).
    assert(fvd.get(6, 0) == 2,
        "both back faces should now be hexagons (quad -1 corner +3: predSide/interior/succSide), got " ~
        fvd.to!string);
    assert(fvd.get(4, 0) == 6,
        "4 untouched/fL/fR quads + 2 rounded chamfer-strip quads, got " ~ fvd.to!string);
}

unittest { // bevelEdgesByMask: K=2 miter round profile GOLDEN — a 2-edge
           // shared-vertex miter at cube vertex 6, rounded, matches the
           // reference editor bit-for-bit (edge.bevel spec
           // behavior.miter_rail_law, task 0435 — closes the K2 external gap).
           // Two independent rail families are checked:
           //   • the shared-vertex HUB arc (unequal-radius miter hub);
           //   • the two BARE-END arcs (each a plain K1 corner fillet).
    import std.math : SQRT1_2;
    static int findEdge(ref Mesh mm, uint va, uint vb) {
        foreach (i; 0 .. mm.edges.length) {
            uint a = mm.edges[i][0], b = mm.edges[i][1];
            if ((a == va && b == vb) || (a == vb && b == va)) return cast(int)i;
        }
        return -1;
    }
    auto m = makeCube();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (pair; [[6u,7u], [2u,6u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0);
        mask[ei] = true;
    }
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 2);
    // Same topology as the reference: 8 corners survive minus vertex 6, plus
    // 6 flat miter/slide corners + 3 rounded interior points = 14v/10f.
    assert(m.vertices.length == 14 && m.faces.length == 10,
        "K2 miter L1 must be 14v/10f");
    immutable float off = 0.1f * SQRT1_2;   // 0.0707…
    immutable Vec3[] want = [
        Vec3( 0.4f + off, 0.4f + off, 0.4f + off),  // shared hub arc bisector
        Vec3(-0.5f,       0.4f + off, 0.4f + off),  // bare end at vertex 7
        Vec3( 0.4f + off, 0.4f + off, -0.5f),       // bare end at vertex 2
    ];
    foreach (w; want) {
        bool found = false;
        foreach (v; m.vertices) if ((v - w).length < 1e-4f) { found = true; break; }
        assert(found, "K2 miter L1 reference point not reproduced");
    }
    assertBevelManifoldClean(m, "K2 miter round golden");
}

unittest { // bevelEdgesByMask: NON-90° dihedral round arc is a TRUE circular
           // fillet — radius = width·tan(φ/2), swept 180°−φ (reference-captured
           // general law, edge.bevel generalization_findings, task 0435). The
           // cube's 90° corner is a DEGENERACY (tan45°=1, sweep=90°); a closed
           // equilateral triangular prism has 60°-corner vertical edges that
           // discriminate the general SLERP fillet from the old fixed-90° blend.
    import std.math : tan, abs, PI;
    immutable float h = 0.8660254f;   // sqrt(3)/2, equilateral side 1
    Mesh m;
    m.vertices = [
        Vec3(0, 0, -0.5f), Vec3(1, 0, -0.5f), Vec3(0.5f, h, -0.5f),  // bottom tri
        Vec3(0, 0,  0.5f), Vec3(1, 0,  0.5f), Vec3(0.5f, h,  0.5f),  // top tri
    ];
    m.addFace([0u, 2u, 1u]);          // bottom cap (−Z)
    m.addFace([3u, 4u, 5u]);          // top cap (+Z)
    m.addFace([0u, 1u, 4u, 3u]);      // side A
    m.addFace([1u, 2u, 5u, 4u]);      // side B
    m.addFace([2u, 0u, 3u, 5u]);      // side C
    m.buildLoops();
    m.syncSelection();
    int ei = -1;                      // vertical edge v0–v3 (60°-corner at v0/v3)
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 0 && b == 3) || (a == 3 && b == 0)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "prism vertical edge missing");
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 1, "prism edge bevel must apply");
    // At the z=-0.5 end (source V=(0,0,-0.5)) the L0 chamfer corners slide along
    // the two 60°-apart triangle edges: E_A=(0.1,0,-0.5), E_B=(0.05,0.0866,-0.5).
    // The true fillet (r=0.1·tan30°=0.057735, centre from the two-tangent-line
    // intersection, SLERP bisector) puts the level-1 interior point at
    // (0.05, 0.028868, -0.5); the OLD fixed-90° blend gives (0.0439, 0.0254).
    immutable Vec3 wantM = Vec3(0.05f, 0.0288675f, -0.5f);
    bool found = false;
    foreach (v; m.vertices) if ((v - wantM).length < 1e-4f) { found = true; break; }
    assert(found,
        "φ=60° round arc must land on the true fillet bisector (0.05,0.02887,-0.5); "
        ~ "the fixed-90° blend (0.0439,0.0254) is wrong off-cube");
    // Independent geometric check: E_A, M, E_B lie on one circle of radius
    // r=width·tan(φ/2) — the defining fillet property (fails for the old blend).
    immutable Vec3 EA = Vec3(0.1f, 0, -0.5f), EB = Vec3(0.05f, 0.0866025f, -0.5f);
    immutable float sa = (EB - wantM).length, sb = (EA - wantM).length, sc = (EA - EB).length;
    immutable float area = 0.5f * cross(EB - EA, wantM - EA).length;
    immutable float circumR = sa * sb * sc / (4.0f * area);
    immutable float wantR = 0.1f * tan(30.0f * (PI / 180.0f));  // 0.057735
    assert(abs(circumR - wantR) < 1e-4f,
        "fillet circumradius must equal width·tan(φ/2)=0.0577, not the 90° value");
    assertBevelManifoldClean(m, "non-90° prism fillet");
}

unittest { // bevelEdgesByMask: K=2 loop rails are shared at L1 and L2.
           // Rail POSITIONS follow the reference-captured miter law (verified
           // bit-exact on the 2-edge K2 golden above); this 4-turn loop case
           // asserts the shared-rail TOPOLOGY/manifoldness only.
    static int findEdge(ref Mesh mm, uint va, uint vb) {
        foreach (i; 0 .. mm.edges.length) {
            uint a = mm.edges[i][0], b = mm.edges[i][1];
            if ((a == va && b == vb) || (a == vb && b == va)) return cast(int)i;
        }
        return -1;
    }
    foreach (level; [1, 2]) {
        auto m = makeCube();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[4u,7u], [7u,6u], [6u,5u], [5u,4u]]) {
            int ei = findEdge(m, pair[0], pair[1]);
            assert(ei >= 0);
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 4);
        immutable int n = 1 << level;
        // L0 has 12 vertices/10 faces.  All four rounded strips gain n-1
        // quads, and the four shared rails own their interiors exactly once.
        assert(m.vertices.length == 12 + 4 * (n - 1));
        assert(m.faces.length == 10 + 4 * (n - 1));
        assertBevelManifoldClean(m, "loop shared rails");
    }
}

unittest { // bevelEdgesByMask: K=3 junction round cap, BIT-EXACT at every Round
           // Level (task 0435). One general L×L Gregory ring: L1=20v/15f (fan),
           // L2=38v/30f, L3=62v/51f. The central Gregory hub is level-independent;
           // the 3 pairwise boundary arcs are geodesics on the corner-rounding
           // sphere (centre V−width·Σn̂) subdivided into 2·L segments (not 2^L).
           // N>3 junctions still keep the flat N-gon cap (different reference).
    import std.math : SQRT1_2;
    static int findEdge(ref Mesh mm, uint va, uint vb) {
        foreach (i; 0 .. mm.edges.length) {
            uint a = mm.edges[i][0], b = mm.edges[i][1];
            if ((a == va && b == vb) || (a == vb && b == va)) return cast(int)i;
        }
        return -1;
    }
    foreach (level; [1, 2, 3]) {
        auto m = makeCube();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[6u,5u], [6u,2u], [6u,7u]]) {
            int ei = findEdge(m, pair[0], pair[1]);
            assert(ei >= 0);
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 3);
        // The central Gregory hub is level-independent; present at every level.
        immutable Vec3 wantHub = Vec3(0.460948f, 0.460948f, 0.460948f);
        bool foundHub = false;
        foreach (v; m.vertices) if ((v - wantHub).length < 1e-4f) foundHub = true;
        assert(foundHub, "K3 central Gregory hub (0.4609)³ not reproduced");
        int[int] fvd;
        foreach (f; m.faces) ++fvd[cast(int)f.length];
        if (level == 1) {
            // 13 L0 + 6 rail interiors + 1 HUB = 20v; 10 + 3 strips + 2 (3-quad
            // fan replaces the flat cap) = 15f. The pairwise arc must round to
            // (0.4,0.4707,0.4707), not the (0.4,0.45,0.45) degenerate midpoint.
            assert(m.vertices.length == 20 && m.faces.length == 15,
                "K3 L1 must be the reference 20v/15f hub-fan cap");
            immutable float off = 0.1f * SQRT1_2;
            bool foundBis = false;
            foreach (v; m.vertices)
                if ((v - Vec3(0.4f, 0.4f + off, 0.4f + off)).length < 1e-4f) foundBis = true;
            assert(foundBis, "K3 L1 pairwise arc must be the true-arc bisector");
        } else if (level == 2) {
            // Rational-Gregory interior ring over a 2×2-per-sub-quad grid.
            assert(m.vertices.length == 38 && m.faces.length == 30,
                "K3 L2 must be the reference 38v/30f Gregory-ring cap");
            bool fA = false, fB = false;
            foreach (v; m.vertices) {
                if ((v - Vec3(0.468270f, 0.468270f, 0.435948f)).length < 1e-4f) fA = true;
                if ((v - Vec3(0.439017f, 0.485392f, 0.439017f)).length < 1e-4f) fB = true;
            }
            assert(fA && fB, "K3 L2 Gregory ring must reproduce the typeA + typeB points");
            assert(fvd.get(8, 0) == 3, "K3 L2 must keep the 3 octagon absorber faces");
            // Topology guard: a specific reference cap quad must exist by
            // position — [pairwise-rail interior, typeB, typeA, R bisector].
            // Catches the g-transpose class of bug (the right vertex SET woven
            // with the WRONG connectivity, which a Hausdorff/count/manifold
            // check silently passes — the transpose leaves positions, edge
            // lengths and manifoldness identical, only re-weaving the ring onto
            // the neighbouring sub-quad's rails).
            immutable Vec3[4] wantQuad = [
                Vec3(0.43827f, 0.49239f, 0.4f),      // pairwise-rail interior
                Vec3(0.43902f, 0.48539f, 0.43902f),  // typeB
                Vec3(0.46827f, 0.46827f, 0.43595f),  // typeA
                Vec3(0.47071f, 0.47071f, 0.4f),      // R bisector
            ];
            bool foundQuad = false;
            foreach (f; m.faces) {
                if (f.length != 4) continue;
                int matched = 0;
                foreach (w; wantQuad)
                    foreach (vi; f) if ((m.vertices[vi] - w).length < 1e-4f) { ++matched; break; }
                if (matched == 4) { foundQuad = true; break; }
            }
            assert(foundQuad,
                "K3 L2 ring must weave the reference [rail,typeB,typeA,R] quad; a "
                ~ "count/manifold-clean pass with the wrong connectivity fails here");
        } else {
            // Round Level 3: general L×L Gregory ring — the arc is subdivided
            // into 2·L segments (5 rail interiors), not 2^L. 62v/51f {quad:48,
            // decagon:3}, bit-exact.
            assert(m.vertices.length == 62 && m.faces.length == 51,
                "K3 L3 must be the reference 62v/51f Gregory-ring cap");
            assert(fvd.get(10, 0) == 3, "K3 L3 must keep the 3 decagon absorber faces");
        }
        assertBevelManifoldClean(m, "junction shared rails");
    }
}

unittest { // bevelEdgesByMask: mixed adjacent K2 at a valence-4 octahedron
           // is rejected by the preflight BEFORE corner construction.  The
           // current L0 partial-fan cap is non-manifold, so a local rounded
           // fallback would not be safe.
    Mesh makeValence4Octahedron() {
        Mesh m;
        m.vertices = [
            Vec3( 0, 1, 0), Vec3( 1, 0, 0), Vec3(0, 0, 1),
            Vec3(-1, 0, 0), Vec3( 0, 0,-1), Vec3(0,-1, 0),
        ];
        // Closed, consistently wound octahedron.  Vertex 0 has valence four.
        m.addFace([0u, 2u, 1u]); m.addFace([0u, 3u, 2u]);
        m.addFace([0u, 4u, 3u]); m.addFace([0u, 1u, 4u]);
        m.addFace([5u, 1u, 2u]); m.addFace([5u, 2u, 3u]);
        m.addFace([5u, 3u, 4u]); m.addFace([5u, 4u, 1u]);
        m.buildLoops();
        m.syncSelection(); // grow parallel marks/material/part arrays after addFace
        m.faceMaterial[0] = 7u; m.facePart[0] = 23u;
        m.setFaceSubpatch(0, true);
        m.selectFace(0);
        return m;
    }
    bool[] selectPairs(ref Mesh m, uint[][] pairs) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; pairs) {
            int ei = -1;
            foreach (i; 0 .. m.edges.length) {
                uint a = m.edges[i][0], b = m.edges[i][1];
                if ((a == pair[0] && b == pair[1]) || (a == pair[1] && b == pair[0])) {
                    ei = cast(int)i;
                    break;
                }
            }
            assert(ei >= 0, "selected octahedron edge missing");
            mask[ei] = true;
        }
        return mask;
    }

    auto m = makeValence4Octahedron();
    auto mask = selectPairs(m, [[0u, 1u], [0u, 2u]]);
    auto vertsBefore = m.vertices.dup;
    auto facesBefore = m.faces._store.dup;
    immutable ulong mutationBefore = m.mutationVersion;
    immutable ulong topologyBefore = m.topologyVersion;
    immutable ulong structBefore = m.structVersion;
    immutable uint pendingBefore = m.pendingChanges_;
    immutable uint pendingSelBefore = m.pendingSelDomains_;
    MeshEditTracker recorder;
    m.beginEditBatch(&recorder, MeshEditScope.Geometry);
    assert(m.isRecordingEdits());
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 0,
        "unsupported mixed K2 must be rejected before any mutation");
    assert(m.vertices == vertsBefore && m.faces._store == facesBefore,
        "early K2 preflight must leave geometry byte-identical");
    assert(m.mutationVersion == mutationBefore && m.topologyVersion == topologyBefore &&
           m.structVersion == structBefore && m.pendingChanges_ == pendingBefore &&
           m.pendingSelDomains_ == pendingSelBefore,
        "early K2 preflight must not bump versions or pending changes");
    assert(recorder.isEmpty(), "early K2 preflight must not write an edit record");
    assert(m.endEditBatch().isEmpty(), "early K2 preflight must finish with an empty delta");
}

unittest { // bevelEdgesByMask: non-adjacent K2 at valence four is equally
           // preflighted and therefore can never enter VerifiedK1Arc.
    Mesh makeValence4Octahedron() {
        Mesh m;
        m.vertices = [
            Vec3( 0, 1, 0), Vec3( 1, 0, 0), Vec3(0, 0, 1),
            Vec3(-1, 0, 0), Vec3( 0, 0,-1), Vec3(0,-1, 0),
        ];
        m.addFace([0u, 2u, 1u]); m.addFace([0u, 3u, 2u]);
        m.addFace([0u, 4u, 3u]); m.addFace([0u, 1u, 4u]);
        m.addFace([5u, 1u, 2u]); m.addFace([5u, 2u, 3u]);
        m.addFace([5u, 3u, 4u]); m.addFace([5u, 4u, 1u]);
        m.buildLoops();
        m.syncSelection(); // grow parallel marks/material/part arrays after addFace
        m.faceMaterial[0] = 7u; m.facePart[0] = 23u;
        m.setFaceSubpatch(0, true);
        m.selectFace(0);
        return m;
    }
    bool[] selectPairs(ref Mesh m) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[0u, 1u], [0u, 3u]]) {
            int ei = -1;
            foreach (i; 0 .. m.edges.length) {
                uint a = m.edges[i][0], b = m.edges[i][1];
                if ((a == pair[0] && b == pair[1]) || (a == pair[1] && b == pair[0])) {
                    ei = cast(int)i;
                    break;
                }
            }
            assert(ei >= 0, "non-adjacent K2 octahedron edge missing");
            mask[ei] = true;
        }
        return mask;
    }
    auto m = makeValence4Octahedron();
    auto mask = selectPairs(m);
    auto vertsBefore = m.vertices.dup;
    auto edgesBefore = m.edges.dup;
    auto facesBefore = m.faces._store.dup;
    auto vertexMarksBefore = m.vertexMarks.dup;
    auto edgeMarksBefore = m.edgeMarks.dup;
    auto faceMarksBefore = m.faceMarks.dup;
    auto vertexSelectionOrderBefore = m.vertexSelectionOrder.dup;
    auto edgeSelectionOrderBefore = m.edgeSelectionOrder.dup;
    auto faceSelectionOrderBefore = m.faceSelectionOrder.dup;
    auto faceMaterialBefore = m.faceMaterial.dup;
    auto facePartBefore = m.facePart.dup;
    auto selectedVerticesBefore = m.selectedVertices;
    auto selectedEdgesBefore = m.selectedEdges;
    auto selectedFacesBefore = m.selectedFaces;
    immutable ulong mutationBefore = m.mutationVersion;
    immutable ulong topologyBefore = m.topologyVersion;
    immutable ulong structBefore = m.structVersion;
    immutable uint pendingBefore = m.pendingChanges_;
    immutable uint pendingSelBefore = m.pendingSelDomains_;
    MeshEditTracker recorder;
    m.beginEditBatch(&recorder, MeshEditScope.Geometry);
    assert(m.isRecordingEdits());
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 0,
        "non-adjacent K2 must be rejected before a false K1 profile is possible");
    assert(m.vertices == vertsBefore && m.edges == edgesBefore && m.faces._store == facesBefore,
        "non-adjacent K2 preflight must leave geometry byte-identical");
    assert(m.vertexMarks == vertexMarksBefore && m.edgeMarks == edgeMarksBefore &&
           m.faceMarks == faceMarksBefore &&
           m.vertexSelectionOrder == vertexSelectionOrderBefore &&
           m.edgeSelectionOrder == edgeSelectionOrderBefore &&
           m.faceSelectionOrder == faceSelectionOrderBefore &&
           m.faceMaterial == faceMaterialBefore && m.facePart == facePartBefore,
        "non-adjacent K2 preflight must leave parallel attributes byte-identical");
    assert(m.selectedVertices == selectedVerticesBefore && m.selectedEdges == selectedEdgesBefore &&
           m.selectedFaces == selectedFacesBefore,
        "non-adjacent K2 preflight must leave selection byte-identical");
    assert(m.mutationVersion == mutationBefore && m.topologyVersion == topologyBefore &&
           m.structVersion == structBefore && m.pendingChanges_ == pendingBefore &&
           m.pendingSelDomains_ == pendingSelBefore,
        "non-adjacent K2 preflight must not bump versions or pending changes");
    assert(recorder.isEmpty(), "non-adjacent K2 preflight must not write an edit record");
    assert(m.endEditBatch().isEmpty(), "non-adjacent K2 preflight must finish with an empty delta");
    assertBevelManifoldClean(m, "non-adjacent valence-4 K2 unchanged input");
}

unittest { // bevelEdgesByMask: OPEN-BOUNDARY support at Round Level 0 — a chain
           // whose end vertices sit on the rim of a hole must bevel every
           // selected edge, not just the interior ones.
           //
           // Before open-fan support the per-vertex pass rejected any vertex
           // whose edge ring was longer than its face ring (a boundary vertex
           // emits one extra "open" edge), so both end spans were silently
           // dropped and a 3-edge selection produced ONE chamfer.  The fan is
           // now walked as an open slot sequence e_0..e_d with no wrap.
           //
           // Every number below is reference-captured
           // (`edge_bevel_open_*_w015`, width 0.15) and reproduced bit-exactly.
    Mesh cubeMinusBottom() {
        // Unit cube with the y == -0.5 face removed: 8 verts, 5 faces, one
        // open rim of 4 edges. Rim vertices are 0, 1, 4, 7.
        Mesh m;
        m.vertices = [
            Vec3(-0.5f,-0.5f,-0.5f), Vec3(-0.5f,-0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f,-0.5f),
            Vec3( 0.5f,-0.5f,-0.5f), Vec3( 0.5f, 0.5f,-0.5f),
            Vec3( 0.5f, 0.5f, 0.5f), Vec3( 0.5f,-0.5f, 0.5f),
        ];
        m.addFace([0u, 1u, 2u, 3u]);   // -X
        m.addFace([4u, 5u, 6u, 7u]);   // +X
        m.addFace([3u, 2u, 6u, 5u]);   // +Y
        m.addFace([0u, 3u, 5u, 4u]);   // -Z
        m.addFace([1u, 7u, 6u, 2u]);   // +Z
        m.buildLoops();
        m.syncSelection();
        return m;
    }
    static ulong ekey(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
    }
    // Counts edges by how many faces use them: [rim (1 face), non-manifold (>2)].
    int[2] edgeUseProfile(ref Mesh m) {
        int[ulong] use;
        foreach (f; m.faces)
            foreach (k; 0 .. f.length) use[ekey(f[k], f[(k + 1) % f.length])]++;
        int[2] r = [0, 0];
        foreach (kv; use.byKeyValue) {
            if (kv.value == 1) ++r[0];
            else if (kv.value != 2) ++r[1];
        }
        return r;
    }
    bool hasVert(ref Mesh m, Vec3 want) {
        foreach (v; m.vertices) if ((v - want).length < 1e-5f) return true;
        return false;
    }
    bool[] selectPairs(ref Mesh m, uint[2][] pairs) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (p; pairs) {
            bool found = false;
            foreach (i; 0 .. m.edges.length) {
                uint a = m.edges[i][0], b = m.edges[i][1];
                if ((a == p[0] && b == p[1]) || (a == p[1] && b == p[0])) {
                    mask[i] = true; found = true; break;
                }
            }
            assert(found, "selected edge missing");
        }
        return mask;
    }

    // Premise: the chain's two end vertices really are on the rim (open fan),
    // i.e. edge-ring length == face-ring length + 1.
    {
        auto m = cubeMinusBottom();
        foreach (V; [4u, 7u]) {
            size_t d = 0, e = 0;
            foreach (fi; m.facesAroundVertex(V)) ++d;
            foreach (ei; m.edgesAroundVertex(V)) ++e;
            assert(e == d + 1, "rim vertex must present an OPEN fan");
        }
        foreach (V; [5u, 6u]) {
            size_t d = 0, e = 0;
            foreach (fi; m.facesAroundVertex(V)) ++d;
            foreach (ei; m.edgesAroundVertex(V)) ++e;
            assert(e == d, "interior chain vertex must present a CLOSED fan");
        }
        assert(edgeUseProfile(m) == [4, 0], "input must have a 4-edge rim and be otherwise manifold");
    }

    // `chain3`: all three edges bevel, including the two anchored on the rim.
    {
        auto m = cubeMinusBottom();
        auto mask = selectPairs(m, [[4u, 5u], [5u, 6u], [6u, 7u]]);
        assert(m.bevelEdgesByMask(mask, 0.15f, 0) == 3,
            "all three edges must bevel — the two rim-anchored ones included");
        assert(m.vertices.length == 12 && m.faces.length == 8,
            "open-boundary L0 chain bevel must be 12v/8f");
        // The bevel notches the rim at each end (one rim vertex becomes two),
        // so the hole grows from 4 to 6 edges — and NOTHING else may open.
        assert(edgeUseProfile(m) == [6, 0],
            "rim must grow 4 -> 6 edges with no new non-manifold edge");
        foreach (want; [Vec3(0.35f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.35f),
                        Vec3(0.5f, -0.5f,  0.35f), Vec3(0.35f, -0.5f, 0.5f)])
            assert(hasVert(m, want), "expected rim slide corner missing");
        foreach (v; m.vertices)
            assert(v.y >= -0.5f - 1e-6f, "bevel must not push geometry past the rim plane");
    }

    // Round Level > 0 at a rim vertex has NO reference capture yet, so it must
    // refuse as a clean no-op rather than ship a guessed boundary arc.
    foreach (level; [1, 2]) {
        auto mr = cubeMinusBottom();
        auto maskr = selectPairs(mr, [[4u, 5u], [5u, 6u], [6u, 7u]]);
        auto vertsBefore = mr.vertices.dup;
        auto facesBefore = mr.faces._store.dup;
        assert(mr.bevelEdgesByMask(maskr, 0.15f, level) == 0,
            "rounded open-boundary bevel is not captured yet and must no-op");
        assert(mr.vertices == vertsBefore && mr.faces._store == facesBefore,
            "the refusal must leave the mesh byte-identical");
    }

    // `rimedge`: a selected RIM edge (exactly ONE incident face) bevels too,
    // but adds NO face — its lone face's border insets by `width` and the
    // neighbours absorb the corner cut, becoming pentagons. 10v/5f.
    {
        auto m = cubeMinusBottom();
        auto mask = selectPairs(m, [[7u, 4u]]);
        assert(m.bevelEdgesByMask(mask, 0.15f, 0) == 1,
            "a rim edge with one incident face must still bevel");
        assert(m.vertices.length == 10 && m.faces.length == 5,
            "rim-edge bevel adds two verts and NO face");
        foreach (want; [Vec3(0.5f, -0.35f, -0.5f), Vec3(0.5f, -0.35f, 0.5f),
                        Vec3(0.35f, -0.5f, -0.5f), Vec3(0.35f, -0.5f,  0.5f)])
            assert(hasVert(m, want), "expected rim-edge bevel vertex missing");
        // The source endpoints are NOT retained — the corner is fully cut.
        foreach (gone; [Vec3(0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, 0.5f)])
            assert(!hasVert(m, gone), "rim-edge endpoint must be cut, not kept");
        assert(edgeUseProfile(m)[1] == 0, "rim-edge bevel must add no non-manifold edge");
    }

    // `bothends`: same law when BOTH endpoints are on a rim — an open tube
    // (both Y faces removed) beveled on F-G, which has one incident face.
    // 10v/4f.
    {
        Mesh tube;
        tube.vertices = [
            Vec3(-0.5f,-0.5f,-0.5f), Vec3(-0.5f,-0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f,-0.5f),
            Vec3( 0.5f,-0.5f,-0.5f), Vec3( 0.5f, 0.5f,-0.5f),
            Vec3( 0.5f, 0.5f, 0.5f), Vec3( 0.5f,-0.5f, 0.5f),
        ];
        tube.addFace([0u, 1u, 2u, 3u]);
        tube.addFace([4u, 5u, 6u, 7u]);
        tube.addFace([0u, 3u, 5u, 4u]);
        tube.addFace([1u, 7u, 6u, 2u]);
        tube.buildLoops();
        tube.syncSelection();
        auto mask = selectPairs(tube, [[5u, 6u]]);
        assert(tube.bevelEdgesByMask(mask, 0.15f, 0) == 1,
            "an edge with both endpoints on a rim must bevel");
        assert(tube.vertices.length == 10 && tube.faces.length == 4,
            "both-ends-on-rim bevel adds two verts and NO face");
        foreach (want; [Vec3(0.5f, 0.35f, -0.5f), Vec3(0.5f, 0.35f, 0.5f),
                        Vec3(0.35f, 0.5f, -0.5f), Vec3(0.35f, 0.5f,  0.5f)])
            assert(hasVert(tube, want), "expected both-ends-on-rim bevel vertex missing");
        assert(edgeUseProfile(tube)[1] == 0, "must add no non-manifold edge");
    }
}

unittest { // bevelEdgesByMask: a partial K2 fan at valence FOUR whose selected
           // edges alternate with the unselected ones (every fan gap == 1 edge)
           // is SUPPORTED at every Round Level — every face at such a vertex
           // borders a selected edge, so the fan resolves to MITER/SLIDE only
           // and never reaches the partial-notch branch.  The old preflight
           // rejected the whole family on a coarse `d>3 && K>=2 && K<d`
           // signature, silently turning Round Level > 0 into a no-op here.
           //
           // Provenance: this is a cube whose (+,+,+) corner was itself edge-
           // beveled (the reference-verified K3 junction), then the 3-edge
           // chain crossing that junction cap is beveled again.  The chain's
           // two shared vertices land at valence 4 with alternating K2; its
           // free ends stay valence 3.
    Mesh chainOnBeveledCorner() {
        auto m = makeCube();
        int corner = -1;
        foreach (i, v; m.vertices)
            if ((v - Vec3(0.5f, 0.5f, 0.5f)).length < 1e-6f) corner = cast(int)i;
        assert(corner >= 0, "cube corner (+,+,+) missing");
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (i; 0 .. m.edges.length)
            if (m.edges[i][0] == corner || m.edges[i][1] == corner) mask[i] = true;
        assert(m.bevelEdgesByMask(mask, 0.273983f, 0) == 3, "K3 corner setup must bevel 3 edges");
        assert(m.vertices.length == 13 && m.faces.length == 10, "K3 L0 setup must be 13v/10f");
        return m;
    }
    // The 3-edge chain: two junction-cap edges plus one rail edge, meeting at
    // the two valence-4 vertices (0.226017, 0.5, 0.226017) / (0.226017, 0.226017, 0.5).
    bool[] selectChain(ref Mesh m) {
        static immutable Vec3[2][3] pairs = [
            [Vec3(0.226017f, -0.5f, 0.5f),      Vec3(0.226017f, 0.226017f, 0.5f)],
            [Vec3(0.226017f, 0.5f, 0.226017f),  Vec3(0.226017f, 0.5f, -0.5f)],
            [Vec3(0.226017f, 0.226017f, 0.5f),  Vec3(0.226017f, 0.5f, 0.226017f)],
        ];
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (p; pairs) {
            bool found = false;
            foreach (i; 0 .. m.edges.length) {
                Vec3 a = m.vertices[m.edges[i][0]], b = m.vertices[m.edges[i][1]];
                if (((a - p[0]).length < 1e-5f && (b - p[1]).length < 1e-5f) ||
                    ((a - p[1]).length < 1e-5f && (b - p[0]).length < 1e-5f)) {
                    mask[i] = true; found = true; break;
                }
            }
            assert(found, "chain edge missing from the beveled-corner cube");
        }
        return mask;
    }

    // Guard premise: the two shared vertices really are valence-4 alternating
    // K2, i.e. the exact family the old signature rejected.
    {
        auto m = chainOnBeveledCorner();
        auto mask = selectChain(m);
        size_t alternatingK2 = 0;
        foreach (V; 0 .. cast(uint)m.vertices.length) {
            size_t d = 0;
            foreach (fi; m.facesAroundVertex(V)) ++d;
            bool[] fan;
            foreach (ei; m.edgesAroundVertex(V)) fan ~= mask[ei];
            if (fan.length != d || d != 4) continue;
            size_t K = 0;
            foreach (s; fan) if (s) ++K;
            if (K != 2) continue;
            bool gapOk = true;
            foreach (k; 0 .. d) if (!fan[k] && !fan[(k + 1) % d]) gapOk = false;
            if (gapOk) ++alternatingK2;
        }
        assert(alternatingK2 == 2, "setup must expose exactly two alternating-K2 valence-4 vertices");
    }

    // 2·L segments per rail × 4 rails (two K1 free ends + two K2 miters):
    // L0 17v/13f, then +4 verts and +2 faces per level step.
    static immutable size_t[4] wantVerts = [17, 21, 29, 37];
    static immutable size_t[4] wantFaces = [13, 16, 22, 28];
    foreach (level; 0 .. 4) {
        auto m = chainOnBeveledCorner();
        auto mask = selectChain(m);
        assert(m.bevelEdgesByMask(mask, 0.1f, cast(int)level) == 3,
            "alternating K2 at valence 4 must bevel all 3 chain edges at every Round Level");
        assert(m.vertices.length == wantVerts[level] && m.faces.length == wantFaces[level],
            "alternating-K2 chain vertex/face count regressed");
        assertBevelManifoldClean(m, "alternating K2 valence-4 chain");
    }
}

unittest { // bevelEdgesByMask: explicit L0 golden for an isolated cube edge.
           // Do not compare two calls through the same implementation: these
    // values are the pre-rounding topology/attribute contract.
    auto m = makeCube();
    m.syncSelection(); // initialize parallel marks/material/part arrays
    m.faceMaterial[1] = 7u; m.facePart[1] = 23u;
    m.setFaceSubpatch(1, true);
    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 1);
    assert(m.vertices.length == 10 && m.faces.length == 7);
    int[int] fvd;
    foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(4, 0) == 5 && fvd.get(5, 0) == 2,
        "L0 isolated-edge face golden must stay {quad:5,pentagon:2}");
    assert(m.faceMaterial[1] == 7u && m.facePart[1] == 23u && m.isFaceSubpatch(1),
        "L0 source material/part/subpatch must be preserved");
    assert(m.countSelectedFaces() == 1,
        "L0 selection policy must select the one new chamfer face");
    assertBevelManifoldClean(m, "L0 isolated-edge golden");
}

unittest { // spinEdge: tri–tri flip, boundary no-op, fold-over no-op
    // ---- case 1: successful tri–tri spin ----
    // Four vertices of a unit quad split along diagonal 0–2.
    //   v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1)
    //   f0=[0,1,2]  f1=[0,2,3]   shared edge: 0–2
    // After spin: new edge 1–3; faces become {0,1,3} and {1,2,3}.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)];
    m.addFace([0u, 1u, 2u]);
    m.addFace([0u, 2u, 3u]);
    m.buildLoops();

    uint ei02 = m.edgeIndex(0, 2);
    assert(ei02 != ~0u, "shared edge 0-2 must exist before spin");

    bool ok = m.spinEdge(ei02);
    assert(ok, "spinEdge must return true on a valid tri pair");

    // Old diagonal absent; new diagonal present.
    assert(m.edgeIndex(0, 2) == ~0u, "edge 0-2 must be absent after spin");
    assert(m.edgeIndex(1, 3) != ~0u, "edge 1-3 must exist after spin");

    // Counts unchanged: 4 verts, 5 edges, 2 faces.
    assert(m.vertices.length == 4, "vertex count unchanged");
    assert(m.edges.length    == 5, "edge count unchanged");
    assert(m.faces.length    == 2, "face count unchanged");

    // Face vertex sets must be {0,1,3} and {1,2,3} (order-independent).
    bool[uint] f0s, f1s;
    foreach (v; m.faces[0]) f0s[v] = true;
    foreach (v; m.faces[1]) f1s[v] = true;
    bool has013 = (0u in f0s && 1u in f0s && 3u in f0s)
               || (0u in f1s && 1u in f1s && 3u in f1s);
    bool has123 = (1u in f0s && 2u in f0s && 3u in f0s)
               || (1u in f1s && 2u in f1s && 3u in f1s);
    assert(has013, "one face must be {0,1,3}");
    assert(has123, "one face must be {1,2,3}");

    // ---- case 2: boundary edge → no-op ----
    Mesh m2;
    m2.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0.5f,0,1)];
    m2.addFace([0u, 1u, 2u]);
    m2.buildLoops();

    uint bEi = m2.edgeIndex(0, 1);
    assert(bEi != ~0u);
    assert(!m2.spinEdge(bEi), "spinEdge on boundary edge must return false");
    assert(m2.faces.length  == 1, "faces unchanged after boundary no-op");
    assert(m2.edges.length  == 3, "edges unchanged after boundary no-op");

    // ---- case 3: fold-over guard — prospective diagonal already exists ----
    // [0,1,2] + [0,2,3] share edge 0-2.  [1,2,3] adds edge 1-3 → spin blocked.
    Mesh m3;
    m3.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0.5f,0,1), Vec3(0.5f,0.5f,0.5f)];
    m3.addFace([0u, 1u, 2u]);
    m3.addFace([0u, 2u, 3u]);
    m3.addFace([1u, 2u, 3u]);
    m3.buildLoops();

    uint ei02m3 = m3.edgeIndex(0, 2);
    assert(ei02m3 != ~0u);
    assert(!m3.spinEdge(ei02m3),
           "spinEdge must be no-op when new diagonal already exists");
    assert(m3.edgeIndex(1, 3) != ~0u, "edge 1-3 still present after fold-over guard");
    assert(m3.edgeIndex(0, 2) != ~0u, "edge 0-2 still present (no spin happened)");
}

unittest { // spinEdge: quad–quad spin, mixed reject, quad fold-over, d==e degenerate
    // ---- case 4: quad–quad positive spin ----
    // Six vertices, two quads sharing edge 1–2.
    //   v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1) v4=(2,0,0) v5=(2,0,1)
    //   f0=[0,1,2,3]  f1=[1,4,5,2]   shared edge: 1–2
    // After spin (c=3, e=4): new diagonal 3–4; newFace1={0,1,3,4}, newFace2={2,3,4,5}.
    Mesh m4;
    m4.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1),
                   Vec3(2,0,0), Vec3(2,0,1)];
    m4.addFace([0u, 1u, 2u, 3u]);
    m4.addFace([1u, 4u, 5u, 2u]);
    m4.buildLoops();

    uint ei12 = m4.edgeIndex(1, 2);
    assert(ei12 != ~0u, "shared edge 1-2 must exist before quad spin");

    bool ok4 = m4.spinEdge(ei12);
    assert(ok4, "spinEdge must return true on a valid quad pair");

    // Old diagonal 1-2 gone; new diagonal 3-4 present.
    assert(m4.edgeIndex(1, 2) == ~0u, "edge 1-2 must be absent after quad spin");
    assert(m4.edgeIndex(3, 4) != ~0u, "edge 3-4 must exist after quad spin");

    // Counts unchanged: 6 verts, 7 edges, 2 faces.
    assert(m4.vertices.length == 6, "vertex count unchanged after quad spin");
    assert(m4.edges.length    == 7, "edge count unchanged after quad spin");
    assert(m4.faces.length    == 2, "face count unchanged after quad spin");

    // Face vertex sets: {0,1,3,4} and {2,3,4,5} (order-independent).
    bool[uint] q0s, q1s;
    foreach (v; m4.faces[0]) q0s[v] = true;
    foreach (v; m4.faces[1]) q1s[v] = true;
    bool has0134 = (0u in q0s && 1u in q0s && 3u in q0s && 4u in q0s)
                || (0u in q1s && 1u in q1s && 3u in q1s && 4u in q1s);
    bool has2345 = (2u in q0s && 3u in q0s && 4u in q0s && 5u in q0s)
                || (2u in q1s && 3u in q1s && 4u in q1s && 5u in q1s);
    assert(has0134, "one face must be {0,1,3,4} after quad spin");
    assert(has2345, "one face must be {2,3,4,5} after quad spin");
    // Both faces must remain quads.
    assert(m4.faces[0].length == 4, "face 0 must remain a quad");
    assert(m4.faces[1].length == 4, "face 1 must remain a quad");

    // ---- case 5: mixed tri–quad pair → no-op ----
    // f0=[0,1,2] (tri) and f1=[1,3,4,2] (quad) share edge 1–2.
    Mesh m5;
    m5.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(2,0,0), Vec3(2,0,1)];
    m5.addFace([0u, 1u, 2u]);
    m5.addFace([1u, 3u, 4u, 2u]);
    m5.buildLoops();

    uint ei12m5 = m5.edgeIndex(1, 2);
    assert(ei12m5 != ~0u, "shared edge 1-2 must exist for mixed case");
    assert(!m5.spinEdge(ei12m5), "mixed tri–quad must return false");
    assert(m5.faces[0].length == 3, "triangle unchanged after mixed no-op");
    assert(m5.faces[1].length == 4, "quad unchanged after mixed no-op");
    assert(m5.edgeIndex(1, 2) != ~0u, "edge 1-2 must survive mixed no-op");

    // ---- case 6: quad fold-over guard ----
    // Two quads sharing edge 1–2, plus a triangle [3,4,6] that pre-creates
    // edge 3–4 (the prospective diagonal c–e).  spinEdge must return false.
    Mesh m6;
    m6.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1),
                   Vec3(2,0,0), Vec3(2,0,1), Vec3(1,-1,0.5f)];
    m6.addFace([0u, 1u, 2u, 3u]);   // quad; dart 1→2 at j=1
    m6.addFace([1u, 4u, 5u, 2u]);   // quad; dart 2→1 at j=3
    m6.addFace([3u, 4u, 6u]);       // triangle; adds edge 3–4 (= c–e diagonal)
    m6.buildLoops();

    uint ei12m6 = m6.edgeIndex(1, 2);
    assert(ei12m6 != ~0u, "shared edge 1-2 must exist for quad fold-over case");
    assert(m6.edgeIndex(3, 4) != ~0u, "edge 3-4 must pre-exist (fold-over setup)");
    assert(!m6.spinEdge(ei12m6), "quad fold-over must return false");
    assert(m6.edgeIndex(1, 2) != ~0u, "edge 1-2 must survive quad fold-over guard");
    assert(m6.edgeIndex(3, 4) != ~0u, "edge 3-4 must still exist after guard");

    // ---- case 7: d==e degenerate case (Risk 3a) ----
    // Two quads sharing edge 1–2 where a boundary vertex coincides across faces.
    //   f0=[0,1,2,3]: dart 1→2 at j=1; c=3, d=0.
    //   f1=[2,1,0,4]: dart 2→1 at j=0; e=0, f_=4.
    //   → d==e==0; "two faces share two edges" non-manifold — all-distinct guard
    //     must fire and return false without mutating the mesh.
    Mesh m7;
    m7.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1), Vec3(2,0,1)];
    m7.addFace([0u, 1u, 2u, 3u]);   // dart 1→2 at j=1; c=3, d=0
    m7.addFace([2u, 1u, 0u, 4u]);   // dart 2→1 at j=0; e=0, f_=4 → d==e==0
    m7.buildLoops();

    uint ei12m7 = m7.edgeIndex(1, 2);
    assert(ei12m7 != ~0u, "shared edge 1-2 must exist for degenerate case");
    assert(!m7.spinEdge(ei12m7), "d==e degenerate case must return false");
    // Mesh must be completely unmutated.
    assert(m7.faces[0].length == 4, "face 0 unchanged after degenerate no-op");
    assert(m7.faces[1].length == 4, "face 1 unchanged after degenerate no-op");
    assert(m7.edgeIndex(1, 2) != ~0u, "edge 1-2 must still exist after degenerate no-op");

    // ---- case 8: c==e degenerate — all-distinct guard is the SOLE catch ----
    // Two quads sharing edge a–b (0–1) PLUS a third shared boundary vertex X=2,
    // producing c == e == 2.  No self-loop edge 2–2 can exist in any mesh, so
    // edgeIndex(2, 2) == ~0u and the fold-over guard is bypassed entirely.
    // Only the all-distinct guard (bv[2]==bv[4]) catches this degeneracy.
    //
    //   v0=(1,0,0)  v1=(1,0,1)  v2=(0.5,1,0.5)  v3=(0,0,1)  v4=(2,0,0)
    //   f0=[0,1,2,3]:  dart 0→1 at j=0; c = f0[(0+2)%4] = 2, d = f0[(0+3)%4] = 3
    //   f1=[1,0,2,4]:  dart 1→0 at j=0; e = f1[(0+2)%4] = 2, f_ = f1[(0+3)%4] = 4
    //   boundary verts = [a=0, b=1, c=2, d=3, e=2, f_=4] → bv[2]==bv[4].
    //   Without the all-distinct guard, spinEdge would build degenerate faces
    //   [2,3,0,2] and [2,4,1,2] (vertex 2 repeated) and return true — RED.
    Mesh m8;
    m8.vertices = [Vec3(1,0,0), Vec3(1,0,1), Vec3(0.5f,1,0.5f), Vec3(0,0,1), Vec3(2,0,0)];
    m8.addFace([0u, 1u, 2u, 3u]);   // dart 0→1 at j=0 → c=2, d=3
    m8.addFace([1u, 0u, 2u, 4u]);   // dart 1→0 at j=0 → e=2, f_=4 → c==e==2
    m8.buildLoops();

    uint ei01m8 = m8.edgeIndex(0, 1);
    assert(ei01m8 != ~0u, "shared edge 0-1 must exist for c==e case");
    // Confirm that the fold-over guard is bypassed: no self-loop edge 2–2 exists.
    assert(m8.edgeIndex(2, 2) == ~0u, "no self-loop edge 2-2 should exist (fold-over guard bypassed)");
    // Only the all-distinct guard blocks this; spinEdge must refuse.
    assert(!m8.spinEdge(ei01m8), "c==e degenerate: all-distinct guard must return false");
    // Mesh must be completely unmutated.
    assert(m8.faces[0].length == 4, "face 0 unchanged after c==e no-op");
    assert(m8.faces[1].length == 4, "face 1 unchanged after c==e no-op");
    assert(m8.edgeIndex(0, 1) != ~0u, "edge 0-1 must still exist after c==e no-op");
}

unittest { // extractSelectedEdgeChains: two open arcs, single open chain,
           // two closed cycles, degree-3 rejection, mixed open+closed
    import std.conv : to;

    void selectAll(ref Mesh m) {
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;
    }

    // (1) Two disjoint open arcs (2 edges each, 3 verts each).
    {
        Mesh m;
        foreach (i; 0 .. 6) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2);
        m.addEdge(3, 4); m.addEdge(4, 5);
        m.buildLoops();
        selectAll(m);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 2,
            "two open arcs: expected 2 chains, got " ~ chains.length.to!string);
        foreach (c; chains) {
            assert(!c.closed, "two open arcs: both chains must be open");
            assert(c.verts.length == 3,
                "two open arcs: expected 3 verts/chain, got " ~ c.verts.length.to!string);
        }
    }

    // (2) Single open chain alone — one component, no second group.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(2, 3);
        m.buildLoops();
        selectAll(m);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 1,
            "single chain: expected 1 chain, got " ~ chains.length.to!string);
        assert(!chains[0].closed, "single chain: must be open");
        assert(chains[0].verts.length == 4,
            "single chain: expected 4 verts, got " ~ chains[0].verts.length.to!string);
    }

    // (3) Two closed 4-cycles — must match extractSelectedEdgeCycles' own count.
    {
        Mesh m;
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
        m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
        m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
        m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
        m.addFace([0u,1u,2u,3u]);
        m.addFace([4u,5u,6u,7u]);
        m.buildLoops();
        m.syncSelection();
        foreach (ei; 0 .. m.edges.length) m.selectEdge(cast(int)ei);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 2,
            "two closed cycles: expected 2 chains, got " ~ chains.length.to!string);
        foreach (c; chains) {
            assert(c.closed, "two closed cycles: both must be closed");
            assert(c.verts.length == 4,
                "two closed cycles: expected 4 verts/cycle, got " ~ c.verts.length.to!string);
        }
        auto cycles = m.extractSelectedEdgeCycles();   // untouched extractor, same selection
        assert(cycles.length == chains.length,
            "extractSelectedEdgeChains must agree with extractSelectedEdgeCycles on an all-closed selection");
    }

    // (4) Branching vertex (degree 3) anywhere → whole call rejected.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(1, 3);
        m.buildLoops();
        selectAll(m);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 0,
            "degree-3 branching: expected rejection, got " ~ chains.length.to!string);
    }

    // (5) Mixed: one open chain + one closed cycle selected together.
    {
        Mesh m;
        // Open chain: verts 0-1-2.
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
        // Closed cycle: verts 3-4-5-6.
        m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(1,1,0));
        m.addVertex(Vec3(1,2,0)); m.addVertex(Vec3(0,2,0));
        m.addEdge(0, 1); m.addEdge(1, 2);
        m.addEdge(3, 4); m.addEdge(4, 5); m.addEdge(5, 6); m.addEdge(6, 3);
        m.buildLoops();
        selectAll(m);

        auto chains = m.extractSelectedEdgeChains();
        assert(chains.length == 2,
            "mixed open+closed: expected 2 chains, got " ~ chains.length.to!string);
        int openCount = 0, closedCount = 0;
        foreach (c; chains) { if (c.closed) ++closedCount; else ++openCount; }
        assert(openCount == 1 && closedCount == 1,
            "mixed open+closed: expected exactly 1 open + 1 closed chain");
    }
}

unittest { // extractSelectedEdgeCycles: two rings, figure-eight rejection
    // Build a tiny mesh with two isolated quad rings as boundary edges.
    // The mesh: two coaxial caps (faces 0 and 1), no other faces.
    Mesh m;
    // A cap: verts 0-3 at z=0
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    // B cap: verts 4-7 at z=1
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    m.addFace([0u,1u,2u,3u]);
    m.addFace([4u,5u,6u,7u]);
    m.buildLoops();
    m.syncSelection();   // resize edgeMarks to edges.length before selectEdge

    // Select all edges (each cap's 4-edge perimeter = 8 edges total).
    foreach (ei; 0 .. m.edges.length)
        m.selectEdge(cast(int)ei);

    auto cycles = m.extractSelectedEdgeCycles();
    assert(cycles.length == 2, "two disjoint cycles");
    assert(cycles[0].length == 4 || cycles[1].length == 4, "4-vertex cycles");

    // Figure-eight: vertex shared by both triangles → degree 4 → rejected.
    // Triangle A: [0,1,2], Triangle B: [2,3,4], vertex 2 is shared.
    Mesh m2;
    foreach (i; 0 .. 5) m2.addVertex(Vec3(cast(float)i, 0, 0));
    m2.addFace([0u,1u,2u]);
    m2.addFace([2u,3u,4u]);
    m2.buildLoops();
    m2.syncSelection();  // resize edgeMarks before selectEdge
    foreach (ei; 0 .. m2.edges.length) m2.selectEdge(cast(int)ei);
    auto c2 = m2.extractSelectedEdgeCycles();
    assert(c2.length == 0, "figure-eight (degree-4 vertex) must be rejected");
}

// ---------------------------------------------------------------------------
// GpuMesh  →  extracted to source/mesh_gpu.d (task 0425). Re-exported here so
// every `import mesh;` / `import mesh : GpuMesh;` call site resolves unchanged.
// ---------------------------------------------------------------------------
public import mesh_gpu;

// ===========================================================================
// makePolygonFromVerts unittests
// ===========================================================================

unittest { // happy-path quad: 4 free coplanar verts → 1 face, 4 edges, winding = click order
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    int fi = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fi == 0, "expected face index 0");
    assert(m.faces.length == 1, "expected 1 face");
    assert(m.edges.length == 4, "expected 4 edges");
    assert(m.faces[0][] == [0u, 1u, 2u, 3u], "winding mismatch");
}

unittest { // winding follows selection order exactly (different from ascending index)
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    int fi = m.makePolygonFromVerts([0, 3, 2, 1], false);
    assert(fi == 0, "expected face 0");
    assert(m.faces[0][] == [0u, 3u, 2u, 1u], "winding must follow click order, not index order");
}

unittest { // flip reverses winding
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    int fi = m.makePolygonFromVerts([0, 1, 2, 3], true);
    assert(fi == 0);
    assert(m.faces[0][] == [3u, 2u, 1u, 0u], "flip must reverse winding");
}

unittest { // <3 distinct verts → reject
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0)];
    m.buildLoops();
    assert(m.makePolygonFromVerts([0, 1], false) == -1, "<2 verts must reject");
    assert(m.makePolygonFromVerts([0, 0, 0], false) == -1, "all-same verts must reject");
    assert(m.faces.length == 0, "no face should be added on reject");
}

unittest { // collinear / zero-area → reject
    Mesh m;
    // Three collinear points on the x-axis
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0)];
    m.buildLoops();
    assert(m.makePolygonFromVerts([0, 1, 2], false) == -1, "collinear must reject");
    assert(m.faces.length == 0);
}

unittest { // duplicate face → no-op (returns -1, faceCount unchanged)
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    int fi1 = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fi1 == 0);
    // Re-run with same vertices in a different order (same unordered set)
    int fi2 = m.makePolygonFromVerts([2, 3, 0, 1], false);
    assert(fi2 == -1, "duplicate vertex set must be rejected");
    assert(m.faces.length == 1, "faceCount must stay 1 on dup reject");
}

unittest { // edge dedup: new face shares one edge with existing triangle → only 2 new edges
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
    ];
    m.buildLoops();
    // First triangle [0,1,2] creates 3 edges
    m.makePolygonFromVerts([0, 1, 2], false);
    size_t edgesAfterTri = m.edges.length;
    assert(edgesAfterTri == 3, "triangle should have 3 edges");
    // Second triangle [1,3,2] shares edge 1-2 with the first face
    m.makePolygonFromVerts([1, 3, 2], false);
    assert(m.edges.length == edgesAfterTri + 2,
        "expected exactly 2 new edges (shared edge reused)");
    assert(m.faces.length == 2);
}

unittest { // non-convex (concave) click order is ACCEPTED as-is (trust click order contract)
    // 5-vertex concave polygon: v3=(2,1,0) is a reflex vertex pushed inward from
    // the convex hull. Order [0,1,2,3,4] visits it in sequence and the kernel MUST
    // preserve that order (no silent convex-hull reordering). Newell area ≈ 20 → passes.
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(4, 0, 0), Vec3(4, 4, 0), Vec3(2, 1, 0), Vec3(0, 4, 0),
    ];
    m.buildLoops();
    int fi = m.makePolygonFromVerts([0, 1, 2, 3, 4], false);
    assert(fi == 0, "concave click order must be accepted");
    assert(m.faces[0][] == [0u, 1u, 2u, 3u, 4u], "concave order must not be reordered");
}

// ---------------------------------------------------------------------------
// makePolygonFromVerts — adjacency auto-orient (task 0394)
// ---------------------------------------------------------------------------

unittest { // adjacent polygon auto-orients to match a neighbor's winding, even
           // when the hand-picked vertex order would traverse the shared edge
           // in the SAME direction as the existing face (the exact corruption
           // that broke facesAroundEdge/collectEdgeRing/Loop Slice in task 0394).
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), // 0..3: quad A
        Vec3(2, 1, 0), Vec3(2, 0, 0),                               // 4,5: quad B's extra corners
    ];
    m.buildLoops();
    int fiA = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fiA == 0, "quad A must be created");
    // Quad A traverses the shared edge as 1→2. The correctly-wound neighbor
    // quad (the simple, non-self-intersecting square spanning x=1..2) is the
    // cycle [1,5,4,2] (or any rotation) — traversing the shared edge as 2→1,
    // opposite A. Entering it as [1,2,4,5] instead (a rotation of the
    // REVERSED cycle) is still the same simple quad shape, but now traverses
    // the shared edge 1→2 — same direction as A, which a manifold forbids.
    // The kernel must flip it back to a rotation of the correct cycle.
    int fiB = m.makePolygonFromVerts([1, 2, 4, 5], false);
    assert(fiB == 1, "adjacent quad B must be created");
    assert(m.faces[fiB][] == [5u, 4u, 2u, 1u],
        "B must be auto-flipped to [5,4,2,1] so the shared edge (1,2) is "
        ~ "traversed opposite A's direction, not left as the literal [1,2,4,5] click order");

    // No same-direction shared edge should exist between A and B afterward.
    auto fA = m.faces[fiA], fB = m.faces[fiB];
    bool sameDirFound = false;
    foreach (ka; 0 .. fA.length) {
        uint au = fA[ka], av = fA[(ka + 1) % fA.length];
        foreach (kb; 0 .. fB.length) {
            uint bu = fB[kb], bv = fB[(kb + 1) % fB.length];
            if (au == bu && av == bv) sameDirFound = true;
        }
    }
    assert(!sameDirFound,
        "adjacent faces must not traverse their shared edge in the same direction");
}

unittest { // free-floating polygon (no shared edge with ANY existing face) still
           // honors orderedIdx + flip exactly as before -- auto-orient only
           // engages when there's an adjacent face to key off of. A DISTANT,
           // unrelated face already exists in the mesh to prove the adjacency
           // scan correctly finds nothing relevant, not merely "mesh is empty".
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), // 0..3: unrelated distant tri lives elsewhere
        Vec3(10, 0, 0), Vec3(11, 0, 0), Vec3(11, 1, 0), Vec3(10, 1, 0), // 4..7: the free-floating quad
    ];
    m.buildLoops();
    int fiFar = m.makePolygonFromVerts([0, 1, 2], false);
    assert(fiFar == 0, "unrelated distant triangle must be created");

    // flip=false: winding must follow click order verbatim.
    int fi1 = m.makePolygonFromVerts([4, 5, 6, 7], false);
    assert(fi1 == 1);
    assert(m.faces[fi1][] == [4u, 5u, 6u, 7u], "free-floating: no-flip must follow click order exactly");

    // flip=true on a SECOND free-floating quad: must reverse exactly as before.
    m.vertices ~= [Vec3(20, 0, 0), Vec3(21, 0, 0), Vec3(21, 1, 0), Vec3(20, 1, 0)];
    m.buildLoops();
    int fi2 = m.makePolygonFromVerts([8, 9, 10, 11], true);
    assert(fi2 == 2);
    assert(m.faces[fi2][] == [11u, 10u, 9u, 8u], "free-floating: flip=true must reverse click order exactly");
}

unittest { // ONE-vs-ONE tie (pre-existing mesh corruption, out of scope for
           // this fix): equal same-direction / opposite-direction vote counts
           // keep `idx` exactly as entered, honoring `orderedIdx` + `flip`
           // rather than arbitrarily picking a side. Under the old "first
           // edge decides" rule this happened to match too (P is checked
           // first and wants no flip) -- this test now documents the TIE
           // rule specifically, since majority-vote (task 0394) no longer
           // cares about scan order, only the final tally.
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), // 0..3: the new quad F
        Vec3(2, -1, 0),   // 4: P's extra corner
        Vec3(2, 2, 0),    // 5: Q's extra corner
    ];
    m.buildLoops();
    // P traverses the shared edge (0,1) as 1→0 -- OPPOSITE of F's future [0,1,2,3]
    // (0→1) -- an "opposite" vote (no flip wanted).
    m.addFace([1, 0, 4]);
    // Q traverses the shared edge (2,3) as 2→3 -- the SAME direction F's
    // [0,1,2,3] would use (2→3) -- a "same-direction" vote (flip wanted).
    m.addFace([2, 3, 5]);

    int fiF = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fiF >= 0, "F must be created (neither shared edge is already 2-faced)");
    // 1 same-direction vote (Q) vs 1 opposite-direction vote (P) -- a tie.
    // Majority vote requires STRICTLY more same-direction votes to flip, so
    // a tie keeps the literal click order.
    assert(m.faces[fiF][] == [0u, 1u, 2u, 3u],
        "a 1-vs-1 vote tie must keep F's literal click order unflipped, not "
        ~ "flip just because SOME neighbor disagrees");
}

unittest { // genuine 2-vs-1 MAJORITY (reference-editor parity, task 0394): a clear
           // majority of same-direction votes must flip the new face even
           // though the FIRST boundary edge checked (in idx order) is an
           // opposite-direction vote that alone would want no flip -- this
           // is exactly where "first edge decides" and "majority vote" (this
           // fix) diverge.
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0), // 0..3: the new quad F
        Vec3(2, -1, 0),    // 4: P's extra corner (opposite-direction vote)
        Vec3(2, 0.5, 0),   // 5: Q1's extra corner (same-direction vote)
        Vec3(-1, 0.5, 0),  // 6: Q2's extra corner (same-direction vote)
    ];
    m.buildLoops();
    // P: shared edge (0,1) as 1→0 -- OPPOSITE of F's future (0→1) -- opposite vote.
    m.addFace([1, 0, 4]);
    // Q1: shared edge (1,2) as 1→2 -- SAME as F's future (1→2) -- same-direction vote.
    m.addFace([1, 2, 5]);
    // Q2: shared edge (2,3) as 2→3 -- SAME as F's future (2→3) -- same-direction vote.
    m.addFace([2, 3, 6]);

    int fiF = m.makePolygonFromVerts([0, 1, 2, 3], false);
    assert(fiF >= 0, "F must be created (no shared edge is already 2-faced)");
    // 2 same-direction votes (Q1, Q2) beat 1 opposite-direction vote (P) --
    // majority says flip, even though P (checked first, at i=0) wanted none.
    assert(m.faces[fiF][] == [3u, 2u, 1u, 0u],
        "2-vs-1 same-direction majority must flip F, overriding the "
        ~ "first-checked edge's opposite-direction vote");
}

// ---------------------------------------------------------------------------
// weldCoincidentVertices unittests (task 0396 — spatial-hash rewrite)
// ---------------------------------------------------------------------------

// Reference copy of the PRE-spatial-hash weldCoincidentVertices remap
// computation (naive O(V²) all-pairs scan). Kept ONLY so the unittests below
// can cross-check the spatial-hash rewrite's equivalence — this is not
// called from any production path.
private int[] naiveWeldRemap_(const Vec3[] verts, double epsSq, size_t protectBelow) {
    int[] remap;
    remap.length = verts.length;
    foreach (i; 0 .. verts.length) remap[i] = cast(int)i;
    foreach (i; 0 .. verts.length) {
        if (remap[i] != cast(int)i) continue;
        foreach (j; i + 1 .. verts.length) {
            if (remap[j] != cast(int)j) continue;
            if (i < protectBelow && j < protectBelow) continue;
            Vec3 d = verts[i] - verts[j];
            if (d.x * d.x + d.y * d.y + d.z * d.z < epsSq)
                remap[j] = cast(int)i;
        }
    }
    return remap;
}

unittest { // spatial-hash rewrite reproduces the naive remap exactly, incl.
    // cell-boundary crossings and the non-transitive chaining quirk.
    //
    // Layout (eps = 0.1, epsSq = 0.01, cellSize = 0.1):
    //   0,1: far anchors (A,B) — never welded, used to recover each cluster
    //        vertex's applied remap target via its face's 3rd corner.
    //   2:   v0 = (0,0,0)            — representative of a 3-cluster
    //   3:   v1 = (0.02,0,0)         — welds to v0 (dist 0.02 < eps)
    //   4:   v2 = (0.05,0,0)         — welds to v0 (dist 0.05 < eps)
    //   5:   b0 = (5.099,0,0)        — cell 50; welds b1 (adjacent-cell pair)
    //   6:   b1 = (5.101,0,0)        — cell 51; dist to b0 = 0.002 < eps
    //   7:   f0 = (20,0,0)           — independent (dist to f1 = 0.5 > eps)
    //   8:   f1 = (20.5,0,0)         — independent
    //   9:   P  = (50,0,0)           — claims Q; NOT within eps of R
    //   10:  Q  = (50.06,0,0)        — welds to P (dist 0.06 < eps)
    //   11:  R  = (50.12,0,0)        — dist to Q = 0.06 < eps, dist to P =
    //        0.12 >= eps; since Q is claimed (not a representative) by the
    //        time R is considered, R must stay UNWELDED — non-transitive.
    import std.conv : to;
    Mesh m;
    m.vertices = [
        Vec3(1000, 1000, 1000),   // 0: anchor A
        Vec3(1000, 1000, 1001),   // 1: anchor B
        Vec3(0, 0, 0),            // 2: v0
        Vec3(0.02f, 0, 0),        // 3: v1
        Vec3(0.05f, 0, 0),        // 4: v2
        Vec3(5.099f, 0, 0),       // 5: b0
        Vec3(5.101f, 0, 0),       // 6: b1
        Vec3(20, 0, 0),           // 7: f0
        Vec3(20.5f, 0, 0),        // 8: f1
        Vec3(50, 0, 0),           // 9: P
        Vec3(50.06f, 0, 0),       // 10: Q
        Vec3(50.12f, 0, 0),       // 11: R
    ];
    // One triangle per cluster vertex: [A, B, v]. A and B are never welded
    // and never coincide with any cluster vertex or each other, so the 3rd
    // corner after weld directly reveals remap[v] (no corner-collapse can
    // touch a 3-distinct-corner face).
    foreach (k; 2 .. m.vertices.length)
        m.faces ~= [0u, 1u, cast(uint)k];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    immutable double epsSq = 0.01; // eps = 0.1

    // Reference remap via the naive O(V²) scan, computed BEFORE any mutation.
    int[] refRemap = naiveWeldRemap_(m.vertices, epsSq, 0);
    int[] expected = [0,1, 2,2,2, 5,5, 7,8, 9,9,11];
    assert(refRemap == expected,
        "naive reference remap sanity check failed: " ~ refRemap.to!string
        ~ " vs " ~ expected.to!string);

    size_t refWelded = 0;
    foreach (i, r; refRemap) if (r != cast(int)i) ++refWelded;

    size_t welded = m.weldCoincidentVertices(epsSq);
    assert(welded == refWelded,
        "spatial-hash weld count must match naive: got " ~ uintToStr(welded)
        ~ " vs " ~ uintToStr(refWelded));
    assert(m.vertices.length == 12, "weldCoincidentVertices must not touch vertices[]");
    assert(m.faces.length == 10, "no face should be dropped (all corners stay distinct)");

    // Recover the APPLIED remap from each face's 3rd corner and compare to
    // the naive reference element-by-element — this catches a wrong
    // representative choice even when the welded COUNT happens to match.
    foreach (fi, ref f; m.faces) {
        uint origV = cast(uint)(fi + 2);
        uint appliedTarget = f[2];
        uint expectedTarget = cast(uint)refRemap[origV];
        assert(appliedTarget == expectedTarget,
            "face for orig vertex " ~ origV.to!string ~ ": applied remap target "
            ~ appliedTarget.to!string ~ " != naive " ~ expectedTarget.to!string);
    }
}

unittest { // protectBelow: both-below pair must NOT weld; below/above pair must
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),   // 0: below protectBelow
        Vec3(0, 0, 0),   // 1: below protectBelow, coincident with 0
        Vec3(0, 0, 0),   // 2: at/above protectBelow, coincident with 0 and 1
    ];
    m.faces = [[0u, 1u, 2u]];  // degenerate on purpose; weld doesn't care about area
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    immutable double epsSq = 0.01;
    immutable size_t protectBelow = 2;

    int[] refRemap = naiveWeldRemap_(m.vertices, epsSq, protectBelow);
    // 0,1 both < protectBelow → skip. 0,2: 0<protectBelow but 2>=protectBelow → eligible → weld.
    assert(refRemap == [0, 1, 0],
        "reference: vert 1 stays independent (protected pair), vert 2 welds to 0");

    size_t refWelded = 0;
    foreach (i, r; refRemap) if (r != cast(int)i) ++refWelded;

    size_t welded = m.weldCoincidentVertices(epsSq, protectBelow);
    assert(welded == refWelded, "protectBelow weld count must match naive reference");
    assert(welded == 1, "exactly one weld (2→0) expected under protectBelow=2");
}

unittest { // epsSq <= 0: never welds anything (matches naive: squared distance is never < 0)
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(0,0,0), Vec3(1,1,1)];
    m.faces = [[0u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t welded = m.weldCoincidentVertices(0.0);
    assert(welded == 0, "epsSq==0 must weld nothing, even for exactly-coincident verts");
}

// Helper: convert size_t to string for assert messages.
string uintToStr(size_t v) {
    if (v == 0) return "0";
    char[20] buf;
    size_t i = buf.length;
    do { buf[--i] = cast(char)('0' + v % 10); v /= 10; } while (v);
    return buf[i .. $].idup;
}

// ---------------------------------------------------------------------------
// Edge Slide kernel
// ---------------------------------------------------------------------------

/// BFS 2-colouring of faces relative to a selected-edge boundary.
/// Crossing a selected edge flips the colour (0 ↔ 1); crossing an
/// unselected edge preserves it.  Seeds from the first incident face of
/// the lowest-index selected edge (colour 0).  Faces unreachable from
/// the selection stay at -1.
/// Precondition: buildLoops() has been called.
private int[] colorFacesForSlide(const ref Mesh m, const bool[] edgeMask)
{
    int[] color = new int[](m.faces.length);
    color[] = -1;

    // Find seed: first incident face of the lowest-index selected edge.
    uint seedFace = ~0u;
    outer: foreach (ei; 0 .. (edgeMask.length < m.edges.length
                              ? edgeMask.length : m.edges.length)) {
        if (!edgeMask[ei]) continue;
        foreach (fi; m.facesAroundEdge(cast(uint)ei)) {
            seedFace = fi;
            break outer;
        }
    }
    if (seedFace == ~0u) return color;
    color[seedFace] = 0;

    uint[] queue;
    uint   head = 0;
    queue ~= seedFace;

    while (head < queue.length) {
        uint fi = queue[head++];
        foreach (fe; m.faceEdges(fi)) {
            uint ei = m.edgeIndex(fe.a, fe.b);
            if (ei == ~0u) continue;
            bool sel    = (ei < edgeMask.length) && edgeMask[ei];
            int  adjCol = sel ? (1 - color[fi]) : color[fi];
            foreach (adjFi; m.facesAroundEdge(ei)) {
                if (adjFi == fi) continue;
                if (adjFi >= m.faces.length) continue;
                if (color[adjFi] == -1) {
                    color[adjFi] = adjCol;
                    queue       ~= adjFi;
                }
                // Bipartite conflict → v1 fall-through (winner unchanged).
            }
        }
    }
    return color;
}

/// Compute new vertex positions for an edge-slide of magnitude `t ∈ [-1, 1]`.
///
/// Each endpoint of every selected edge (the "slid set") moves linearly
/// toward one of its two rail neighbours — the vertex at the far end of
/// the non-selected face-edge at that vertex inside a flanking face.
/// `sign(t)` chooses the side: face colour 1 when t > 0, colour 0 when
/// t < 0.  t = ±1 places the vertex exactly on the rail neighbour (clamped).
/// If no rail exists on the requested side the vertex is left unchanged
/// (graceful degradation — no crash). A candidate rail neighbour that is
/// itself an endpoint of a selected edge (i.e. also sliding this frame,
/// e.g. 3 of a quad's 4 edges selected) is likewise treated as no-rail —
/// otherwise the two mutually-railing vertices would walk toward each
/// other's original position and coincide at t = ±0.5 (task 0307).
///
/// Positional only: topology is unchanged.
/// Precondition: m.buildLoops() has been called.
Vec3[] edgeSlidePositions(const ref Mesh m, const bool[] edgeMask, float t)
{
    Vec3[] out_ = m.vertices.dup;

    if (t < -1.0f) t = -1.0f;
    if (t >  1.0f) t =  1.0f;
    if (t == 0.0f) return out_;   // identity — no work

    float absT    = t < 0.0f ? -t : t;
    bool  wantPos = t > 0.0f;     // true → use colour-1 rail

    // Build slid-vertex set from edge endpoints (snapshot edgeMask once).
    bool[] slidVert = new bool[](m.vertices.length);
    bool   anyEdge  = false;
    size_t minE     = edgeMask.length < m.edges.length
                      ? edgeMask.length : m.edges.length;
    foreach (ei; 0 .. minE) {
        if (!edgeMask[ei]) continue;
        slidVert[m.edges[ei][0]] = true;
        slidVert[m.edges[ei][1]] = true;
        anyEdge = true;
    }
    if (!anyEdge) return out_;

    int[] faceColor = colorFacesForSlide(m, edgeMask);

    foreach (size_t vi; 0 .. m.vertices.length) {
        if (!slidVert[vi]) continue;
        uint uvi     = cast(uint)vi;
        uint railPos = ~0u;   // colour-1 (positive) side rail neighbour
        uint railNeg = ~0u;   // colour-0 (negative) side rail neighbour

        foreach (fi; m.facesAroundVertex(uvi)) {
            if (fi >= m.faces.length) continue;
            int fc = (fi < faceColor.length) ? faceColor[fi] : -1;
            if (fc < 0) continue;  // face not reachable from selection

            // Collect the two face-edges at uvi in this face.
            uint selEdge  = ~0u;
            uint railEdge = ~0u;
            foreach (fe; m.faceEdges(fi)) {
                if (fe.a != uvi && fe.b != uvi) continue;
                uint ei = m.edgeIndex(fe.a, fe.b);
                if (ei == ~0u) continue;
                bool isSel = (ei < edgeMask.length) && edgeMask[ei];
                if (isSel) selEdge  = ei;
                else       railEdge = ei;
            }
            // Valid rail: exactly one selected face-edge and one unselected.
            if (selEdge == ~0u || railEdge == ~0u) continue;

            uint nb = m.edgeOtherVertex(railEdge, uvi);
            // Mutual-rail guard (task 0307): if the candidate rail neighbour
            // is itself an endpoint of a selected edge, it is also sliding
            // this frame rather than being a stable anchor. Using it would
            // move both vertices toward each other's *original* (pre-slide)
            // position — harmless at the documented t = ±1 (vi lands on a
            // stationary neighbour there), but at an ordinary t (e.g. 3 of a
            // quad's 4 edges selected, so the lone unselected edge's two
            // endpoints rail off each other) the pair walks toward one
            // another and coincides at t = ±0.5. Skip this face's candidate
            // — same graceful "no rail on this side" degradation already
            // used when a face offers no valid rail at all.
            if (slidVert[nb]) continue;
            if (fc == 1) { if (railPos == ~0u) railPos = nb; }
            else         { if (railNeg == ~0u) railNeg = nb; }
        }

        uint rail = wantPos ? railPos : railNeg;
        if (rail == ~0u) continue;   // no rail on this side → unchanged

        Vec3 orig = m.vertices[vi];
        Vec3 dest = m.vertices[rail];
        out_[vi]  = orig + absT * (dest - orig);
    }
    return out_;
}

unittest { // two-quad strip: edge slides toward positive rail at t=0.5
    // Layout (top view):
    //   v3---v2---v5
    //   |  f0 | f1 |
    //   v0---v1---v4
    // Selected edge: v1-v2.  Rails: v0/v3 (negative), v4/v5 (positive).
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),   // v0-v3
        Vec3(2,0,0), Vec3(2,1,0),                               // v4, v5
    ];
    m.makePolygonFromVerts([0, 1, 2, 3], false);
    m.makePolygonFromVerts([1, 4, 5, 2], false);
    m.buildLoops();

    uint selEi = m.edgeIndex(1, 2);
    assert(selEi != ~0u, "edge v1-v2 must exist");
    bool[] mask = new bool[](m.edges.length);
    mask[selEi] = true;

    // t=0: identity.
    auto pos0 = edgeSlidePositions(m, mask, 0.0f);
    foreach (i; 0 .. m.vertices.length)
        assert(pos0[i] == m.vertices[i], "t=0 must be identity");

    // t=0.5: both endpoints move halfway toward their same-side rails.
    auto pos05 = edgeSlidePositions(m, mask, 0.5f);
    // v1 moves from x=1 toward either v0(x=0) or v4(x=2) by 0.5.
    assert(pos05[1].x != 1.0f, "v1 must move at t=0.5");
    assert(pos05[2].x != 1.0f, "v2 must move at t=0.5");
    // Both must move the same direction (same Δx sign).
    float dv1 = pos05[1].x - 1.0f;
    float dv2 = pos05[2].x - 1.0f;
    assert((dv1 > 0) == (dv2 > 0), "v1 and v2 must slide the same direction");
    // Magnitude: 0.5 × rail distance = 0.5 × 1.0 = 0.5.
    assert(dv1 == 0.5f || dv1 == -0.5f, "magnitude must be 0.5");
    assert(dv2 == 0.5f || dv2 == -0.5f, "magnitude must be 0.5");
    // Non-slid vertices unchanged.
    assert(pos05[0] == m.vertices[0]); assert(pos05[3] == m.vertices[3]);
    assert(pos05[4] == m.vertices[4]); assert(pos05[5] == m.vertices[5]);

    // t=1: both endpoints land exactly on their rail neighbours.
    auto pos1 = edgeSlidePositions(m, mask, 1.0f);
    assert(pos1[1].x == 0.0f || pos1[1].x == 2.0f,
           "v1 at t=1 must coincide with v0 or v4");
    assert(pos1[2].x == 0.0f || pos1[2].x == 2.0f,
           "v2 at t=1 must coincide with v3 or v5");
    // Both land on the SAME side.
    assert(pos1[1].x == pos1[2].x, "v1 and v2 must land on the same-side rail");

    // t=-0.5: opposite direction from t=+0.5.
    auto posN = edgeSlidePositions(m, mask, -0.5f);
    float dvN1 = posN[1].x - 1.0f;
    assert((dv1 > 0) != (dvN1 > 0), "t and -t must slide opposite directions");
}

unittest { // degraded case: single quad, no positive-side rail → vertex unchanged
    // Only one face at the selected edge: no colour-1 face at either endpoint.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.makePolygonFromVerts([0, 1, 2, 3], false);
    m.buildLoops();

    uint selEi = m.edgeIndex(0, 1);
    assert(selEi != ~0u);
    bool[] mask = new bool[](m.edges.length);
    mask[selEi] = true;

    // t=+0.5 → positive side has no rail → both endpoints unchanged.
    // t=-0.5 → negative side has a rail → both endpoints move.
    auto posP = edgeSlidePositions(m, mask,  0.5f);
    auto posN = edgeSlidePositions(m, mask, -0.5f);
    // One of the two sides has no rail (the exposed boundary side).
    // At least one side must leave the endpoints unchanged.
    bool posUnchanged = (posP[0] == m.vertices[0] && posP[1] == m.vertices[1]);
    bool negUnchanged = (posN[0] == m.vertices[0] && posN[1] == m.vertices[1]);
    assert(posUnchanged || negUnchanged,
           "boundary vertex must be unchanged on at least one side");
}

unittest { // loop consistency: all loop verts slide the same direction
    // 3-ring tube (4 verts/ring, 2 rings of quads).
    // Ring 0 (top y=+1): v0..v3   Ring 1 (mid y=0): v4..v7
    // Ring 2 (bot y=-1): v8..v11
    Mesh m;
    m.vertices = [
        Vec3( 1, 1, 0), Vec3( 0, 1, 1), Vec3(-1, 1, 0), Vec3( 0, 1,-1),  // v0-v3
        Vec3( 1, 0, 0), Vec3( 0, 0, 1), Vec3(-1, 0, 0), Vec3( 0, 0,-1),  // v4-v7
        Vec3( 1,-1, 0), Vec3( 0,-1, 1), Vec3(-1,-1, 0), Vec3( 0,-1,-1),  // v8-v11
    ];
    // Upper quads (ring 0 → ring 1).
    m.makePolygonFromVerts([0, 1, 5, 4], false);
    m.makePolygonFromVerts([1, 2, 6, 5], false);
    m.makePolygonFromVerts([2, 3, 7, 6], false);
    m.makePolygonFromVerts([3, 0, 4, 7], false);
    // Lower quads (ring 1 → ring 2).
    m.makePolygonFromVerts([ 4,  5,  9,  8], false);
    m.makePolygonFromVerts([ 5,  6, 10,  9], false);
    m.makePolygonFromVerts([ 6,  7, 11, 10], false);
    m.makePolygonFromVerts([ 7,  4,  8, 11], false);
    m.buildLoops();

    // Select the middle ring (v4-v5, v5-v6, v6-v7, v7-v4).
    bool[] mask = new bool[](m.edges.length);
    foreach (pair; [[4u,5u],[5u,6u],[6u,7u],[7u,4u]]) {
        uint ei = m.edgeIndex(pair[0], pair[1]);
        assert(ei != ~0u, "middle-ring edge must exist");
        mask[ei] = true;
    }

    // t=0.5: all 4 middle verts move the same direction with the same |ΔY|.
    auto posP = edgeSlidePositions(m, mask, 0.5f);
    float[4] dyP;
    foreach (i; 0 .. 4) dyP[i] = posP[4 + i].y - m.vertices[4 + i].y;
    foreach (i; 0 .. 4)
        assert(dyP[i] != 0.0f, "middle vert must move with t=0.5");
    // All deltas must have the same sign (consistency).
    bool allPos = true, allNeg = true;
    foreach (d; dyP) { if (d <= 0) allPos = false; if (d >= 0) allNeg = false; }
    assert(allPos || allNeg, "all middle-ring verts must slide the same direction");
    // All |ΔY| must be equal.
    foreach (i; 1 .. 4)
        assert(dyP[i] == dyP[0], "all middle-ring verts must slide the same amount");

    // t=-0.5 must slide in the opposite direction.
    auto posN = edgeSlidePositions(m, mask, -0.5f);
    foreach (i; 0 .. 4) {
        float dyN = posN[4 + i].y - m.vertices[4 + i].y;
        assert((dyP[i] > 0) != (dyN > 0),
               "t=+0.5 and t=-0.5 must slide in opposite Y directions");
    }
}

unittest { // task 0307: 3-of-4 quad edges selected — mutual-rail must not collapse
    import std.conv : to;
    // Cube face [0,1,5,4] (y=-0.5 face): edges 0-1, 1-5, 5-4, 4-0.
    // Select 3 of its 4 edges (0-1, 1-5, 4-0), leaving 4-5 unselected. Verts
    // 4 and 5 are then each other's ONLY rail candidate on that face — the
    // pre-fix kernel slid both toward each other's *original* position and
    // they coincided exactly at t=0.5 (fuzz-found; fixed by the
    // slidVert(nb) mutual-rail guard above).
    Mesh m = makeCube();
    bool[] mask = new bool[](m.edges.length);
    foreach (pair; [[0u,1u],[1u,5u],[0u,4u]]) {
        uint ei = m.edgeIndex(pair[0], pair[1]);
        assert(ei != ~0u, "quad face-edge must exist");
        mask[ei] = true;
    }
    uint eUnsel = m.edgeIndex(4, 5);
    assert(eUnsel != ~0u && !mask[eUnsel],
        "edge 4-5 must be the lone unselected edge of the quad");

    auto pos = edgeSlidePositions(m, mask, 0.5f);

    // Regression: verts 4 and 5 must NOT coincide.
    float d45 = (pos[4] - pos[5]).length();
    assert(d45 > 0.05f,
        "task 0307 regression: mutual-rail verts 4/5 collapsed, dist=" ~ d45.to!string);

    // Graceful degradation: this is the ONLY face touching 4/5 with a
    // candidate rail, and that candidate is mutual — so both stay put
    // rather than sliding onto (or past) one another.
    assert((pos[4] - m.vertices[4]).length() < 1e-6f,
        "vert 4 has no valid (non-mutual) rail — must stay unchanged");
    assert((pos[5] - m.vertices[5]).length() < 1e-6f,
        "vert 5 has no valid (non-mutual) rail — must stay unchanged");

    // No face becomes degenerate: no two distinct vertices of any face
    // coincide after the slide.
    foreach (const f; m.faces) {
        foreach (ai; 0 .. f.length)
            foreach (bi; ai + 1 .. f.length)
                assert((pos[f[ai]] - pos[f[bi]]).length() > 1e-4f,
                    "task 0307 regression: face has coincident vertices after slide");
    }
}

// ---------------------------------------------------------------------------
// EdgeFaceRange — other-endpoint retry on a corrupted half-edge fan (task 0394)
// ---------------------------------------------------------------------------
//
// Reproduces the observed symptom (a real user model, see task 0394): a
// same-direction shared edge SOMEWHERE in a vertex's fan corrupts the
// half-edge rotation anchored at that vertex (vertLoop[v] can end up
// pointing at a dart that doesn't even belong to v — buildLoops' anchor
// walk follows twin(cur) directly instead of twin(prev(cur)), so a
// mispaired twin at the corrupted edge derails it). A perfectly ordinary,
// uncorrupted edge elsewhere in the SAME fan can then have its default
// (edges[ei][0]-first) facesAroundEdge lookup walk straight into the dead
// end and find nothing — exactly what turned Loop Slice into a silent
// no-op. The retry from the OTHER endpoint (whose own fan is untouched)
// recovers the correct, verified-against-ground-truth face set.

unittest { // corrupted fan elsewhere in the SAME hub vertex recovers a clean
           // bystander edge's incident faces via the other-endpoint retry
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,2,0), Vec3(-1,1,0), Vec3(-1,-1,0),
        Vec3(1,-1,0), Vec3(9,9,0),
    ];
    m.faces = [
        [0u,1u,2u],   // face0 -- query edge (0,1) lives here
        [0u,2u,3u],   // face1
        [0u,3u,4u],   // face2
        [0u,4u,5u],   // face3
        [0u,5u,6u],   // face4
        [0u,6u,1u],   // face5 -- closes the fan back to vertex1
        [3u,0u,7u],   // faceBad -- reuses spoke (0,3) in the SAME direction (3→0)
                      // as face1's (3,0): a genuine same-direction shared edge,
                      // corrupting the vertex-0 half-edge fan elsewhere.
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    uint ei01 = m.edgeIndex(0, 1);
    assert(ei01 != ~0u, "edge (0,1) must exist");
    assert(m.edges[ei01][] == [0u, 1u], "sanity: default direction is va=0, vb=1");

    // Non-vacuous: the OLD single-direction lookup (default endpoint only,
    // no retry) genuinely fails on this corrupted fan -- the bug this fixes.
    {
        EdgeFaceRange pOld;
        bool okOld = pOld._tryFrom(m.loops, m.vertLoop, m.edges[ei01][0], m.edges[ei01][1]);
        assert(!okOld, "sanity: single-direction lookup from the default endpoint "
            ~ "must fail on this corrupted fan -- otherwise this test proves nothing");
    }

    // The retry-equipped public API must recover both true incident faces.
    uint[] found;
    foreach (fi; m.facesAroundEdge(ei01)) found ~= fi;
    import std.algorithm : sort, canFind;
    sort(found);
    assert(found == [0u, 5u],
        "facesAroundEdge must recover both faces incident on edge (0,1) via the "
        ~ "other-endpoint retry, not silently report zero");

    // collectEdgeRing (the direct cause of the Loop Slice no-op) is a thin
    // wrapper over facesAroundEdge (mesh.d ~9949) -- it inherits this fix
    // automatically. Not separately re-derived here: constructing a corrupted
    // fan where the retry ALSO recovers a clean quad-quad ring (rather than
    // just triangle incidence) needs a larger fixture without adding coverage
    // over what's proven above; see the follow-up note in the task file.
}

unittest { // well-formed mesh: retry is inert (never fires; the default
           // single-direction lookup always succeeds on its own, so
           // facesAroundEdge's result is byte-identical to before this fix)
    Mesh m = makeCube();
    m.buildLoops();
    foreach (ei; 0 .. cast(uint)m.edges.length) {
        EdgeFaceRange direct;
        bool okDirect = direct._tryFrom(m.loops, m.vertLoop, m.edges[ei][0], m.edges[ei][1]);
        assert(okDirect, "well-formed mesh: default single-direction lookup must "
            ~ "already succeed on every edge -- the retry must never be needed here");

        uint[] viaPublicApi;
        foreach (fi; m.facesAroundEdge(ei)) viaPublicApi ~= fi;
        import std.algorithm : sort;
        auto direct2 = direct._faces[0 .. direct._count].dup;
        sort(direct2);
        auto viaSorted = viaPublicApi.dup;
        sort(viaSorted);
        assert(direct2 == viaSorted,
            "well-formed mesh: facesAroundEdge result must match the plain "
            ~ "single-direction lookup exactly -- the retry must not alter it");
    }
}

// effectiveDeleteMode unittests (task 0110)
unittest { // returns current when current mode has a selection
    Mesh m = makeCube();
    m.resetSelection();   // initialises faceMarks / edgeMarks / vertexMarks arrays
    m.selectFace(0);
    m.selectVertex(0);
    // Both polygons and vertices have selections.
    // When current == Polygons, active mode has a selection → return Polygons.
    assert(m.effectiveDeleteMode(EditMode.Polygons) == EditMode.Polygons,
        "active mode has face selection → must return Polygons");
    // When current == Vertices, active mode has a selection → return Vertices.
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Vertices,
        "active mode has vertex selection → must return Vertices");
}

unittest { // redirects to the type that holds a selection (task 0110 cross-mode case)
    Mesh m = makeCube();
    m.resetSelection();
    m.selectFace(0);   // face 0 selected; no verts or edges selected

    // Active mode = Vertices (has NO selection) → redirect to Polygons.
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Polygons,
        "vertices active + only face selected → must redirect to Polygons");
    // Active mode = Edges (has NO selection) → redirect to Polygons.
    assert(m.effectiveDeleteMode(EditMode.Edges) == EditMode.Polygons,
        "edges active + only face selected → must redirect to Polygons");
    // Active mode = Polygons → no redirect (has the selection).
    assert(m.effectiveDeleteMode(EditMode.Polygons) == EditMode.Polygons,
        "polygons active + face selected → no redirect");
}

unittest { // priority: Polygons > Edges > Vertices when multiple types are selected
    Mesh m = makeCube();
    m.resetSelection();
    m.selectFace(0);
    m.selectEdge(0);
    m.selectVertex(0);
    // Active mode = Vertices, but all three types have selections.
    // Vertices has a selection, so no redirect (returns Vertices).
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Vertices,
        "active mode has vertex selection → return Vertices (no redirect needed)");

    // Now clear vertex selection to test Polygons-priority redirect.
    m.deselectVertex(0);
    // Active mode = Vertices (empty), face+edge selected → Polygons wins.
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Polygons,
        "vertices empty, faces+edges selected → Polygons priority");

    // Edges > Vertices: deselect the face too; only edge 0 + vertex 0 remain.
    // Active mode = Polygons (empty, no face selected) → Edges wins over Vertices.
    m.deselectFace(0);
    assert(m.effectiveDeleteMode(EditMode.Polygons) == EditMode.Edges,
        "polygons empty, edges+verts selected → Edges priority over Vertices");
}

unittest { // truly empty (nothing selected anywhere) → return current (whole-mesh path)
    Mesh m = makeCube();
    m.resetSelection();
    // No selection in any mode → effectiveDeleteMode returns current unchanged.
    assert(m.effectiveDeleteMode(EditMode.Vertices) == EditMode.Vertices,
        "nothing selected → return current (whole-mesh convention)");
    assert(m.effectiveDeleteMode(EditMode.Edges) == EditMode.Edges,
        "nothing selected → return current (whole-mesh convention)");
    assert(m.effectiveDeleteMode(EditMode.Polygons) == EditMode.Polygons,
        "nothing selected → return current (whole-mesh convention)");
}

unittest { // weightMapNames + addWeightMap + vertexWeight + setVertexWeight
    auto m = makeCube();
    assert(m.weightMapNames().length == 0, "fresh cube has no weight maps");
    auto wm = m.addWeightMap("test");
    assert(wm !is null, "addWeightMap returned null");
    assert(m.weightMapNames() == ["test"]);
    assert(wm.data.length == m.vertices.length);
    assert(wm.domain == MapDomain.Point && wm.dim == 1);
    assert(m.vertexWeight("test", 0) == 0.0f, "fresh weight must be 0");
    assert(m.setVertexWeight("test", 0, 0.75f));
    import std.math : fabs;
    assert(fabs(m.vertexWeight("test", 0) - 0.75f) < 1e-6f);
    assert(m.addWeightMap("test") is null, "duplicate name must be rejected");
    assert(m.removeMeshMap("test"));
    assert(m.weightMapNames().length == 0);
    assert(m.vertexWeight("missing", 0) == 0.0f);
    assert(!m.setVertexWeight("missing", 0, 1.0f));
}

// ---------------------------------------------------------------------------
// rebuildFacesWithChordSplits: keep-selection unittests (cut-keep-split-faces
// -selected task) — the shared kernel now INHERITS each parent face's
// Marks.Select bit onto every emitted slot (whole-copy AND both split
// halves) instead of unconditionally clearing it. Asserted by GEOMETRY /
// count, not fixed index — a split appends the second half right after the
// first, shifting later face indices.
// ---------------------------------------------------------------------------

unittest { // splitFaceByVertices: selected parent → BOTH halves selected
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    m.selectFace(0);

    size_t n = m.splitFaceByVertices(0, 0, 2); // chord across the non-adjacent diagonal

    assert(n == 1, "quad splits along the 0-2 chord");
    assert(m.faces.length == 2, "2 sub-faces after the split");
    assert(m.isFaceSelected(0) && m.isFaceSelected(1),
           "splitFaceByVertices: both halves of a selected parent must stay selected");
}

unittest { // edgeSlice (splitPolygons=true path): selected parent → BOTH halves selected
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    m.selectFace(0);

    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(2, 3);
    assert(eA != ~0u && eB != ~0u, "both edges must exist on the quad");

    size_t n = m.edgeSlice(eA, eB, 0.5f, 0.5f, /*splitPolygons*/true);

    assert(n == 1, "single-face edgeSlice chords once");
    assert(m.faces.length == 2, "2 sub-faces after the slice");
    assert(m.isFaceSelected(0) && m.isFaceSelected(1),
           "edgeSlice split path: both halves of a selected parent must stay selected");
}

// ---------------------------------------------------------------------------
// edgeSlice unittests
// ---------------------------------------------------------------------------

unittest { // edgeSlice: 3×1 quad strip — index-share (no T-junction) + 6 faces / 12 verts
    // Grid:
    //  4--5--6--7
    //  |  |  |  |
    //  0--1--2--3
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0), Vec3(3,0,0),
        Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0), Vec3(3,1,0),
    ];
    m.addFace([0u,1u,5u,4u]);
    m.addFace([1u,2u,6u,5u]);
    m.addFace([2u,3u,7u,6u]);
    m.buildLoops();
    m.resetSelection();

    uint eLeft  = m.edgeIndexOfVerts(0, 4);
    uint eRight = m.edgeIndexOfVerts(3, 7);
    assert(eLeft  != ~0u, "edge(0,4) must exist");
    assert(eRight != ~0u, "edge(3,7) must exist");

    size_t nSplit = m.edgeSlice(eLeft, eRight);

    assert(nSplit == 3, "3 quads split → nSplit==3");
    assert(m.faces.length  == 6,  "3×2 = 6 faces after strip cut");
    assert(m.vertices.length == 12, "8 + 4 cut-points = 12 verts");

    // No orphan vertices.
    import std.conv : to;
    bool[] refd = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd[vi] = true;
    foreach (i, r; refd) assert(r, "vertex " ~ i.to!string ~ " is orphaned after edgeSlice");

    // No degenerate faces.
    foreach (face; m.faces) assert(face.length >= 3, "no degenerate face after edgeSlice");

    // Index-share: the cut point on interior edge (1,5) must be referenced
    // by exactly 2 sub-faces with the SAME vertex index (no T-junction).
    uint cutMid15 = ~0u;
    foreach (vi; 0 .. cast(uint)m.vertices.length) {
        auto v = m.vertices[vi];
        if (v.x > 0.99f && v.x < 1.01f &&
            v.y > 0.49f && v.y < 0.51f && v.z == 0)
            cutMid15 = vi;
    }
    assert(cutMid15 != ~0u, "cut point on edge(1,5) must exist");
    int cnt15 = 0;
    foreach (face; m.faces) foreach (vi; face) if (vi == cutMid15) cnt15++;
    // v9 is shared by both sub-faces of face0 AND both sub-faces of face1
    // (it is the entry point of one and exit point of the other across the
    // shared half-edge).  4 references = 1 unique index across all 4 users.
    assert(cnt15 == 4,
        "interior cut vertex (1,5 mid) must appear in exactly 4 sub-faces (index-share)");

    // Likewise for interior edge (2,6).
    uint cutMid26 = ~0u;
    foreach (vi; 0 .. cast(uint)m.vertices.length) {
        auto v = m.vertices[vi];
        if (v.x > 1.99f && v.x < 2.01f &&
            v.y > 0.49f && v.y < 0.51f && v.z == 0)
            cutMid26 = vi;
    }
    assert(cutMid26 != ~0u, "cut point on edge(2,6) must exist");
    int cnt26 = 0;
    foreach (face; m.faces) foreach (vi; face) if (vi == cutMid26) cnt26++;
    // Same reasoning: v10 is shared by both sub-faces of face1 AND face2.
    assert(cnt26 == 4,
        "interior cut vertex (2,6 mid) must appear in exactly 4 sub-faces (index-share)");
}

unittest { // edgeSlice: single shared face (cube bottom) — 7 faces, 10 verts
    auto m = makeCube();
    // Face 5 = [0,1,5,4] (bottom).  Edge(0,1) and edge(4,5) are both on it.
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(4, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(4,5) must exist on cube");

    size_t nSplit = m.edgeSlice(eA, eB);

    assert(nSplit == 1, "single shared face: 1 split");
    assert(m.faces.length  == 7,  "6 faces → 7 after single split");
    assert(m.vertices.length == 10, "8 + 2 cut-points = 10 verts");

    foreach (face; m.faces) assert(face.length >= 3, "no degenerate faces");

    import std.conv : to;
    bool[] refd2 = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd2[vi] = true;
    foreach (i, r; refd2) assert(r, "vertex " ~ i.to!string ~ " orphaned after single-face edgeSlice");
}

unittest { // edgeSlice: endpoint cut (t=0/1) reuses the corner, no new vertex — F1, task 0295
    auto m = makeCube();
    // Face 5 = [0,1,5,4] (bottom) — same face as the "single shared face"
    // unittest above. Edge(0,1) and edge(4,5) are non-adjacent on it; their
    // DIAGONAL corner combination is {0,5} (the other combination, {1,4}, is
    // also a valid diagonal — {0,4}/{1,5} are the two ADJACENT/existing-edge
    // pairs and would hit rebuildFacesWithChordSplits' adjacent-hit guard,
    // i.e. a no-op). Read the stored edge direction to pick tA/tB so the cut
    // lands on {0,5} regardless of edges[e][0]/[1]'s (opaque, dedup-order)
    // storage direction.
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(4, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(4,5) must exist on cube");

    size_t origVerts = m.vertices.length;
    size_t origEdges = m.edges.length;
    size_t origFaces = m.faces.length;

    float tA = (m.edges[eA][0] == 0) ? 0.0f : 1.0f; // lands on vertex 0
    float tB = (m.edges[eB][0] == 5) ? 0.0f : 1.0f; // lands on vertex 5

    size_t nSplit = m.edgeSlice(eA, eB, tA, tB, /*splitPolygons*/true);

    assert(nSplit == 1, "single shared face chorded once");
    assert(m.faces.length == origFaces + 1, "6 -> 7 faces (one chord split)");
    assert(m.vertices.length == origVerts,
        "endpoint cut reuses BOTH corners — vertex count UNCHANGED (the F1 discriminator)");
    assert(m.edges.length == origEdges + 1,
        "only the new chord is a new edge — neither named edge is itself split");

    foreach (face; m.faces) assert(face.length >= 3, "no degenerate face after endpoint edgeSlice");

    // No coincident-position duplicate vertices (the "insert-then-weld"
    // approach this stage deliberately avoids would leave one here).
    foreach (i; 0 .. m.vertices.length)
        foreach (j; i + 1 .. m.vertices.length)
            assert((m.vertices[i] - m.vertices[j]).length() > 1e-6f,
                "endpoint cut must not create a coincident duplicate vertex");

    // The chord connects the two REUSED corners (0, 5) directly.
    assert(m.edgeIndexOfVerts(0, 5) != ~0u, "chord edge (0,5) must exist after endpoint cut");
}

unittest { // edgeSliceEx: mixed endpoint (t=0, reuse) + interior (t=0.5, new vert) — F1, task 0295
    auto m = makeCube();
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(4, 5);
    assert(eA != ~0u); assert(eB != ~0u);

    size_t origVerts = m.vertices.length;
    float tA = (m.edges[eA][0] == 0) ? 0.0f : 1.0f; // reuse vertex 0

    auto r = m.edgeSliceEx(eA, eB, tA, 0.5f, /*splitPolygons*/true);

    assert(r.facesSplit == 1, "single shared face chorded once");
    assert(m.vertices.length == origVerts + 1,
        "one endpoint (reused) + one interior (new) => +1 vertex only");
    assert(r.cutVertA == 0, "cutVertA must be the REUSED corner (vertex 0), not a fresh index");
    assert(r.cutVertB == origVerts, "cutVertB must be the newly appended interior vertex");
}

unittest { // edgeSliceEx: KEPT degenerate-chain edge-split, RE-DERIVED
           // (mesh-robustness batch) — this is an INTENTIONAL REVERSAL of
           // the 0303 always-rollback fix, re-derived from a frozen
           // reference capture. It previously asserted the OLD (over-
           // rollback) behaviour as correct — that encoded the bug this
           // batch fixes. Do NOT read this as test-fitting.
    //
    // edge(0,1)@t=0.5 (genuine interior insert) chained to edge(1,5)@t=1.0
    // (F1 endpoint-reuse landing on the SHARED corner, vertex 1). Both edges
    // border face 5 ([0,1,5,4]); the interior cut vertex is spliced in
    // immediately next to the reused corner in that face's winding, so the
    // two cut positions are ADJACENT there — rebuildFacesWithChordSplits'
    // adjacent-hit guard correctly refuses to CHORD-SPLIT it (facesSplit ==
    // 0). But Pass 1 (insertEdgePoint) already spliced a REAL new vertex
    // into both faces incident to edge(0,1) (faces 0 and 5) — that is a
    // legitimate degenerate-chain edge-split (matches the reference: cube
    // V8/E12/F6 -> V9/E13/F6, chi stays 2), and must be KEPT + finalized,
    // not rolled back. Before this fix that insert was unconditionally
    // discarded (over-rollback, task 0303's own fix — too broad).
    import std.conv : to;
    auto m = makeCube();
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(1, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(1,5) must exist on cube");

    size_t origVerts = m.vertices.length;
    size_t origEdges = m.edges.length;
    size_t origFaces = m.faces.length;

    float tB = (m.edges[eB][0] == 1) ? 0.0f : 1.0f; // land on the shared corner, vertex 1

    auto r = m.edgeSliceEx(eA, eB, 0.5f, tB, /*splitPolygons*/true);

    assert(r.facesSplit == 0,
        "adjacent cut positions on the shared face must not CHORD-SPLIT any face");
    assert(r.meshChanged,
        "a kept degenerate-chain insert must report meshChanged == true");
    assert(r.cutVertA == cast(uint)origVerts,
        "cutVertA must be the newly inserted interior vertex on edge(0,1)");
    assert(r.cutVertB == 1,
        "cutVertB must be the REUSED shared corner (vertex 1), not a sentinel");

    assert(m.vertices.length == origVerts + 1,
        "kept insert: exactly one new vertex (the edge(0,1) interior cut)");
    assert(m.edges.length == origEdges + 1,
        "kept insert: edge(0,1) splits into two edges — net +1 edge");
    assert(m.faces.length == origFaces,
        "kept insert: no face is added or removed, only re-wound");
    assert(cast(long)m.vertices.length - cast(long)m.edges.length + cast(long)m.faces.length == 2,
        "Euler characteristic must stay 2 after a kept degenerate-chain insert");

    // edge(0,1) itself is gone; the two half-edges (0,newV) and (newV,1) exist.
    assert(m.edgeIndexOfVerts(0, 1) == ~0u,
        "edge(0,1) must no longer exist as a single edge after the split");
    assert(m.edgeIndexOfVerts(0, r.cutVertA) != ~0u,
        "half-edge (0, newVert) must exist after the kept split");
    assert(m.edgeIndexOfVerts(r.cutVertA, 1) != ~0u,
        "half-edge (newVert, 1) must exist after the kept split");

    // Manifold: every undirected edge used by at most 2 faces.
    size_t[ulong] edgeUseCount;
    foreach (fi; 0 .. m.faces.length) {
        auto f = m.faces[fi];
        foreach (k; 0 .. f.length) {
            ulong key = Mesh.edgeKeyOrdered(f[k], f[(k + 1) % f.length]);
            auto p = key in edgeUseCount;
            if (p is null) edgeUseCount[key] = 1;
            else           ++(*p);
        }
    }
    foreach (key, count; edgeUseCount)
        assert(count <= 2,
            "kept degenerate-chain insert: non-manifold edge used by " ~
            count.to!string ~ " faces");
}

unittest { // edgeSliceEx: TRUE no-op (both cuts reuse existing ADJACENT
           // corners, nothing spliced in) must still roll back byte-
           // identical — sibling of the KEPT-insert case above, guarding
           // the regression requirement (mesh-robustness batch).
    //
    // edge(0,1)@t=0 (reuse vertex 0) chained to edge(1,5)@t=1 (reuse vertex
    // 1). Both land on EXISTING corners that are already adjacent in face 5's
    // winding ([0,1,5,4]) — the adjacent-hit guard refuses to split, and
    // since NEITHER cut inserted anything new, vertices.length is untouched:
    // a genuinely empty operation.
    import std.conv : to;
    auto m = makeCube();
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(1, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(1,5) must exist on cube");

    size_t origVerts = m.vertices.length;
    size_t origEdges = m.edges.length;
    size_t origFaces = m.faces.length;
    uint[][] origFaceWindings = m.faces._store.dup;

    float tA = (m.edges[eA][0] == 0) ? 0.0f : 1.0f; // reuse vertex 0
    float tB = (m.edges[eB][0] == 1) ? 0.0f : 1.0f; // reuse vertex 1

    auto r = m.edgeSliceEx(eA, eB, tA, tB, /*splitPolygons*/true);

    assert(r.facesSplit == 0,
        "adjacent reused corners on the shared face must be a no-op (adjacent-hit guard)");
    assert(!r.meshChanged,
        "a true no-op (nothing spliced in) must report meshChanged == false");
    assert(r.cutVertA == ~0u && r.cutVertB == ~0u,
        "a true no-op result must not surface stale cut-vertex indices");
    assert(m.vertices.length == origVerts,
        "true no-op must not add any vertex — both cuts were pure corner reuse");
    assert(m.edges.length == origEdges, "true no-op must not touch edges[]");
    assert(m.faces.length == origFaces, "true no-op must not touch face count");
    foreach (fi; 0 .. origFaces)
        assert(m.faces[fi] == origFaceWindings[fi],
            "true no-op must not leave any winding change in face " ~ fi.to!string);
    assert(cast(long)m.vertices.length - cast(long)m.edges.length + cast(long)m.faces.length == 2,
        "Euler characteristic must stay 2 after a true no-op cut");
}

unittest { // edgeSlice: no-op guards — same edge, out-of-bounds index → returns 0
    auto m = makeCube();
    size_t origFaces = m.faces.length;
    size_t origVerts = m.vertices.length;

    uint e0 = m.edgeIndexOfVerts(0, 1);

    // Same edge: always a no-op.
    assert(m.edgeSlice(e0, e0) == 0, "same edge must return 0");
    assert(m.faces.length    == origFaces, "mesh unchanged after same-edge no-op");
    assert(m.vertices.length == origVerts, "mesh unchanged after same-edge no-op");

    // Out-of-bounds edge index: no-op.
    uint oob = cast(uint)m.edges.length;
    assert(m.edgeSlice(oob, e0) == 0, "oob edgeA must return 0");
    assert(m.edgeSlice(e0, oob) == 0, "oob edgeB must return 0");
    assert(m.faces.length    == origFaces, "mesh unchanged after oob no-op");
    assert(m.vertices.length == origVerts, "mesh unchanged after oob no-op");
}

unittest { // edgeSlice: splitPolygons=false — points only, no chord, no face split
    import std.conv : to;
    auto m = makeCube();
    // Face 5 = [0,1,5,4] (bottom).  Edge(0,1) and edge(4,5) are both on it,
    // but are NOT adjacent (mirrors the shared-face unittest above).
    uint eA = m.edgeIndexOfVerts(0, 1);
    uint eB = m.edgeIndexOfVerts(4, 5);
    assert(eA != ~0u, "edge(0,1) must exist on cube");
    assert(eB != ~0u, "edge(4,5) must exist on cube");

    size_t origEdges = m.edges.length;
    assert(origEdges == 12, "cube starts with 12 edges");

    size_t n = m.edgeSlice(eA, eB, 0.5f, 0.5f, /*splitPolygons*/false);

    assert(n == 2, "points-only branch returns 2 (nonzero success marker)");
    assert(m.faces.length == 6, "face count UNCHANGED with splitPolygons=false");
    assert(m.vertices.length == 10, "8 + 2 cut-points = 10 verts");
    // The discriminator for the finalize bug: a missing rebuildEdges() would
    // leave edges.length at 12 (the two new half-edges never registered) even
    // though face==6 / verts==10 / no-orphans / no-degenerate all still pass.
    assert(m.edges.length == 14,
        "edge count must be 12 -> 14 (two non-shared edges each split once); got "
        ~ m.edges.length.to!string);

    bool[] refd = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd[vi] = true;
    foreach (i, r; refd) assert(r, "vertex " ~ i.to!string ~ " orphaned after points-only edgeSlice");
    foreach (face; m.faces) assert(face.length >= 3, "no degenerate face after points-only edgeSlice");
}

unittest { // boundaryLoops: single open grid → 1 loop; closed cube → 0 loops
    Mesh g;
    g.addVertex(Vec3(0,0,0)); g.addVertex(Vec3(1,0,0)); g.addVertex(Vec3(2,0,0));
    g.addVertex(Vec3(0,1,0)); g.addVertex(Vec3(1,1,0)); g.addVertex(Vec3(2,1,0));
    g.addFace([0u,1u,4u,3u]);
    g.addFace([1u,2u,5u,4u]);
    g.buildLoops();
    auto loops = g.boundaryLoops();
    assert(loops.length == 1, "2×1 grid: expected 1 boundary loop");
    assert(loops[0].length == 6, "2×1 grid: boundary loop has 6 verts");

    Mesh c = makeCube();
    c.buildLoops();
    assert(c.boundaryLoops().length == 0, "closed cube: expected 0 boundary loops");
}

unittest { // boundaryLoops: 3×3 grid with center quad removed → 2 loops
    // 16 verts, 8 quads (3×3 minus center at face index 4).
    Mesh m;
    foreach (j; 0 .. 4)
        foreach (i; 0 .. 4)
            m.addVertex(Vec3(cast(float)i, cast(float)j, 0));
    size_t fi = 0;
    foreach (j; 0 .. 3)
        foreach (i; 0 .. 3) {
            uint a = cast(uint)(i     + 4 * j    );
            uint b = cast(uint)(i + 1 + 4 * j    );
            uint c = cast(uint)(i + 1 + 4 * (j+1));
            uint d = cast(uint)(i     + 4 * (j+1));
            if (fi != 4) m.addFace([a, b, c, d]); // skip center (fi==4)
            fi++;
        }
    m.buildLoops();
    auto loops = m.boundaryLoops();
    assert(loops.length == 2, "3×3 grid minus center: expected 2 boundary loops");
}

// Helper: count undirected edges shared by exactly one face.
private size_t countOpenEdges(ref Mesh m) {
    int[2][ulong] ef;
    foreach (i, f; m.faces)
        foreach (k; 0 .. f.length) {
            ulong key = Mesh.edgeKeyOrdered(f[k], f[(k+1)%f.length]);
            auto p = key in ef;
            if (p is null) ef[key] = [cast(int)i, -1];
            else if ((*p)[1] == -1 && (*p)[0] != cast(int)i) (*p)[1] = cast(int)i;
        }
    size_t cnt = 0;
    foreach (_, fp; ef) if (fp[1] == -1) cnt++;
    return cnt;
}

unittest { // thickenSurface: 2×2 grid → 16-face watertight shell
    Mesh m;
    foreach (j; 0 .. 3)
        foreach (i; 0 .. 3)
            m.addVertex(Vec3(cast(float)i, cast(float)j, 0));
    foreach (j; 0 .. 2)
        foreach (i; 0 .. 2) {
            uint a = cast(uint)(i     + 3 * j    );
            uint b = cast(uint)(i + 1 + 3 * j    );
            uint c = cast(uint)(i + 1 + 3 * (j+1));
            uint d = cast(uint)(i     + 3 * (j+1));
            m.addFace([a, b, c, d]);
        }
    m.buildLoops();

    const size_t r = m.thickenSurface(0.2f);
    assert(r > 0, "thicken 2×2: non-zero result");
    assert(m.vertices.length == 18, "thicken 2×2: 18 verts");
    assert(m.faces.length == 16, "thicken 2×2: 16 faces");
    assert(m.boundaryLoops().length == 0, "thicken 2×2: watertight");
    assert(countOpenEdges(m) == 0, "thicken 2×2: no open edges");
}

unittest { // thickenSurface: 3×3 holed grid → 32-face watertight shell
    // 16 verts, 8 quads (center quad skipped).
    Mesh m;
    foreach (j; 0 .. 4)
        foreach (i; 0 .. 4)
            m.addVertex(Vec3(cast(float)i, cast(float)j, 0));
    size_t fi = 0;
    foreach (j; 0 .. 3)
        foreach (i; 0 .. 3) {
            uint a = cast(uint)(i     + 4 * j    );
            uint b = cast(uint)(i + 1 + 4 * j    );
            uint c = cast(uint)(i + 1 + 4 * (j+1));
            uint d = cast(uint)(i     + 4 * (j+1));
            if (fi != 4) m.addFace([a, b, c, d]);
            fi++;
        }
    m.buildLoops();

    const size_t r = m.thickenSurface(0.2f);
    assert(r > 0, "thicken holed: non-zero result");
    assert(m.vertices.length == 32, "thicken holed: 32 verts");
    assert(m.faces.length == 32, "thicken holed: 32 faces (8+8+12+4)");
    assert(m.boundaryLoops().length == 0, "thicken holed: watertight");
    assert(countOpenEdges(m) == 0, "thicken holed: no open edges");
}

unittest { // thickenSurface: closed cube → no-op
    Mesh m = makeCube();
    m.buildLoops();
    const V0 = m.vertices.length, F0 = m.faces.length;
    assert(m.thickenSurface(0.1f) == 0, "thicken cube: no-op");
    assert(m.vertices.length == V0 && m.faces.length == F0, "thicken cube: unchanged");
}

unittest { // thickenSurface: zero thickness → no-op
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addFace([0u,1u,2u,3u]);
    m.buildLoops();
    assert(m.thickenSurface(0.0f) == 0, "zero thickness: no-op");
    assert(m.vertices.length == 4 && m.faces.length == 1, "zero thickness: unchanged");
}

unittest { // thickenSurface: symmetric mode places originals at ±t/2
    import std.math : abs;
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addFace([0u,1u,2u,3u]);
    m.buildLoops();
    m.thickenSurface(0.4f, true);
    foreach (i; 0 .. 4)
        assert(abs(m.vertices[i].z - 0.2f) < 1e-5f, "symmetric: outer vert at +0.2");
    foreach (i; 4 .. 8)
        assert(abs(m.vertices[i].z + 0.2f) < 1e-5f, "symmetric: inner vert at -0.2");
}

// extrudeVerticesByMask (task 0360 cone/ring kernel rewrite): cube corner 0
// at (-0.5,-0.5,-0.5), width=0.2, shift=0. Corner 0 (valence 3) gets a
// stationary apex + a 6-vertex/6-face ring (2 new verts + 2 new faces per
// incident edge — see the kernel's own doc-comment for the full law).
// Selection is untouched (still vertex 0 — the apex never moves or gets
// re-indexed).
unittest {
    import std.math : abs;
    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();
    m.selectVertex(0);
    const size_t oldV = m.vertices.length; // 8
    const size_t oldF = m.faces.length;    // 6

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;  // corner (-0.5,-0.5,-0.5)
    size_t processed = m.extrudeVerticesByMask(mask, 0.0f, 0.2f);

    assert(processed == 1,                "extrudeVerticesByMask: should process 1 vertex");
    assert(m.vertices.length == oldV + 6, "extrudeVerticesByMask: expected +6 verts");
    assert(m.faces.length    == oldF + 6, "extrudeVerticesByMask: expected +6 faces");

    // Apex (vertex 0) unmoved.
    Vec3 apex = m.vertices[0];
    assert(abs(apex.x - (-0.5f)) < 1e-5f &&
           abs(apex.y - (-0.5f)) < 1e-5f &&
           abs(apex.z - (-0.5f)) < 1e-5f,
           "extrudeVerticesByMask: apex must stay at its original position");

    // Three ring points at exactly width=0.2 along each incident edge.
    Vec3[3] expectedRing = [Vec3(-0.3f, -0.5f, -0.5f),
                            Vec3(-0.5f, -0.3f, -0.5f),
                            Vec3(-0.5f, -0.5f, -0.3f)];
    foreach (e; expectedRing) {
        bool found = false;
        foreach (v; m.vertices) {
            Vec3 d = v - e;
            if (d.x*d.x + d.y*d.y + d.z*d.z < 1e-8f) { found = true; break; }
        }
        assert(found, "extrudeVerticesByMask: ring point not found");
    }

    // Selection untouched: vertex 0 (the apex) is still the only selected vert.
    assert(m.isVertexSelected(0), "extrudeVerticesByMask: apex must remain selected");
}

// extrudeVerticesByMask: width=0 is a no-op regardless of shift (confirmed
// reference law, task 0360 — shift alone never moves anything).
unittest {
    auto m = makeCube();
    m.buildLoops();
    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;
    size_t processed = m.extrudeVerticesByMask(mask, 0.5f, 0.0f);
    assert(processed == 0,          "extrudeVerticesByMask: width=0 must be no-op");
    assert(m.vertices.length == 8,  "extrudeVerticesByMask: width=0 must not add verts");
    assert(m.faces.length    == 6,  "extrudeVerticesByMask: width=0 must not add faces");
}

// ---------------------------------------------------------------------------
// splitVerticesByMask unittests
// ---------------------------------------------------------------------------

unittest { // cube corner v6 (3 incident faces) → 2 copies, 10 verts, 6 faces
    // makeCube faces:
    //   fi=0: [0,3,2,1]  fi=1: [4,5,6,7]  fi=2: [0,4,7,3]
    //   fi=3: [1,2,6,5]  fi=4: [3,7,6,2]  fi=5: [0,1,5,4]
    // v6=(+0.5,+0.5,+0.5) appears in fi=1,3,4.
    // First encounter (fi=1) keeps original; fi=3 → v8; fi=4 → v9.
    auto m = makeCube();
    bool[] mask = new bool[](m.vertices.length);
    mask[6] = true;
    size_t copies = m.splitVerticesByMask(mask);
    assert(copies == 2,               "splitVerticesByMask: expected 2 copies for corner v6");
    assert(m.vertices.length == 10,   "splitVerticesByMask: expected 10 verts");
    assert(m.faces.length    == 6,    "splitVerticesByMask: face count must not change");

    // The 3 faces that originally contained v6 must now reference 3 distinct
    // indices, all at position (+0.5, +0.5, +0.5).
    import std.math : fabs;
    uint[3] splitIdxs = [6u, 8u, 9u];  // deterministic: fi=1 keeps 6, fi=3→8, fi=4→9
    foreach (si; splitIdxs) {
        assert(si < m.vertices.length, "splitVerticesByMask: split index out of range");
        Vec3 p = m.vertices[si];
        assert(fabs(p.x - 0.5f) < 1e-6f && fabs(p.y - 0.5f) < 1e-6f && fabs(p.z - 0.5f) < 1e-6f,
               "splitVerticesByMask: copy position mismatch");
    }
    assert(splitIdxs[0] != splitIdxs[1] && splitIdxs[1] != splitIdxs[2],
           "splitVerticesByMask: copies must be distinct indices");

    // The three faces that touch v6 now each hold a different index.
    // fi=1→v6, fi=3→v8, fi=4→v9.
    bool v6InF1, v8InF3, v9InF4;
    foreach (vid; m.faces[1]) if (vid == 6) v6InF1 = true;
    foreach (vid; m.faces[3]) if (vid == 8) v8InF3 = true;
    foreach (vid; m.faces[4]) if (vid == 9) v9InF4 = true;
    assert(v6InF1, "splitVerticesByMask: fi=1 must keep v6");
    assert(v8InF3, "splitVerticesByMask: fi=3 must get v8");
    assert(v9InF4, "splitVerticesByMask: fi=4 must get v9");

    // Faces that did not contain v6 are unchanged (no v8/v9 in them).
    foreach (vid; m.faces[0]) assert(vid != 8 && vid != 9, "splitVerticesByMask: fi=0 must be untouched");
    foreach (vid; m.faces[2]) assert(vid != 8 && vid != 9, "splitVerticesByMask: fi=2 must be untouched");
    foreach (vid; m.faces[5]) assert(vid != 8 && vid != 9, "splitVerticesByMask: fi=5 must be untouched");
}

unittest { // vertex with exactly 1 incident face → no-op, returns 0
    // Build a single triangle: v0, v1, v2.  v0 is in only 1 face.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u]);
    m.buildLoops();

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;  // v0 is in face 0 only
    size_t copies = m.splitVerticesByMask(mask);
    assert(copies == 0,              "splitVerticesByMask: single-incident vertex must be no-op");
    assert(m.vertices.length == 3,   "splitVerticesByMask: no-op must not add verts");
    assert(m.faces.length    == 1,   "splitVerticesByMask: no-op must not change face count");
}

unittest { // Point-domain map (weight map) values propagate to copies
    // This is the only assertion that exercises the deferred Point-map copy
    // path.  If map values were copied inside the corner loop (before
    // resizeVertexSelection), the write would be OOB → RangeError.
    auto m = makeCube();
    auto wm = m.addWeightMap("split_wt");
    assert(wm !is null);
    m.setVertexWeight("split_wt", 6, 0.75f);

    bool[] mask = new bool[](m.vertices.length);
    mask[6] = true;
    size_t copies = m.splitVerticesByMask(mask);
    assert(copies == 2, "splitVerticesByMask/Point-map: expected 2 copies");

    import std.math : fabs;
    // v6 (kept), v8 (copy 1), v9 (copy 2) must all carry 0.75.
    assert(fabs(m.vertexWeight("split_wt", 6) - 0.75f) < 1e-6f,
           "splitVerticesByMask/Point-map: original v6 weight must be preserved");
    assert(fabs(m.vertexWeight("split_wt", 8) - 0.75f) < 1e-6f,
           "splitVerticesByMask/Point-map: v8 copy must carry source weight");
    assert(fabs(m.vertexWeight("split_wt", 9) - 0.75f) < 1e-6f,
           "splitVerticesByMask/Point-map: v9 copy must carry source weight");
    // Unrelated vertices must remain at 0.
    assert(m.vertexWeight("split_wt", 0) == 0.0f,
           "splitVerticesByMask/Point-map: unrelated vertex must stay 0");
}

// addEdgePoint: midpoint t=0.5 on cube edge {0,1} → +1 vertex at (0,-0.5,-0.5),
// both incident faces share the new index (no T-junction), bare 0-1 adjacency gone.
unittest {
    import std.math : abs;
    auto m = makeCube();
    // Edge {0,1} is stored as [1,0] (first occurrence in addFace([0,3,2,1]) is
    // the 1→0 step at winding position k=3).  Midpoint is orientation-independent.
    uint ei = m.edgeIndexMap[edgeKey(0, 1)];
    uint vi = m.addEdgePoint(ei, 0.5f);
    assert(vi != uint.max,           "addEdgePoint: must succeed on valid cube edge");
    assert(m.vertices.length == 9,   "addEdgePoint: V must be 9 after midpoint split");
    // Midpoint of {0,1}: verts 0=(-0.5,-0.5,-0.5) and 1=(0.5,-0.5,-0.5) → (0,-0.5,-0.5).
    assert(abs(m.vertices[vi].x - 0.0f) < 1e-5f, "addEdgePoint: new vert x must be 0");
    assert(abs(m.vertices[vi].y + 0.5f) < 1e-5f, "addEdgePoint: new vert y must be -0.5");
    assert(abs(m.vertices[vi].z + 0.5f) < 1e-5f, "addEdgePoint: new vert z must be -0.5");
    // No face may still have a bare 0→1 or 1→0 adjacency (index-shared).
    foreach (face; m.faces) {
        for (size_t k = 0; k < face.length; k++) {
            uint fa = face[k], fb = face[(k + 1) % face.length];
            assert(!((fa == 0 && fb == 1) || (fa == 1 && fb == 0)),
                   "addEdgePoint: bare 0-1 edge must not remain in any face");
        }
    }
    // Exactly two faces contain the new vertex (the two former incident faces).
    int facesWithVi = 0;
    foreach (face; m.faces)
        foreach (v; face)
            if (v == vi) { facesWithVi++; break; }
    assert(facesWithVi == 2, "addEdgePoint: exactly 2 faces must contain the new vertex");
}

// addEdgePoint: open-interval guards reject t=0 and t=1 without mutation.
unittest {
    auto m = makeCube();
    uint ei = m.edgeIndexMap[edgeKey(0, 1)];
    assert(m.addEdgePoint(ei, 0.0f) == uint.max, "addEdgePoint: t=0 must fail");
    assert(m.addEdgePoint(ei, 1.0f) == uint.max, "addEdgePoint: t=1 must fail");
    assert(m.vertices.length == 8,               "addEdgePoint: guards must not mutate mesh");
    assert(m.edges.length    == 12,              "addEdgePoint: guards must not mutate edges");
}

// structVersion / loops-validity stamp: the Stage-2 trace table (M7 plan).
// A connectivity sub-version bumped ONLY by the edge/face structural
// primitives, so Points/Position/Marks/isSubpatch changes correctly leave
// loopsValid()/edgeMapUsable() true, while a forgotten buildLoops() after a
// structural change correctly reads invalid.
unittest {
    auto m = makeCube();
    // 1. face op (addFace, inside makeCube) → buildLoops → valid.
    assert(m.loopsValid(),    "trace: face op + buildLoops must be loopsValid");
    assert(m.edgeMapUsable(), "trace: face op + buildLoops must be edgeMapUsable");
    ulong afterBuild = m.structVersion;

    // 2. face op → (forgot buildLoops) → commit(Geometry): structVersion
    //    moves (addFace bumps it) but loopsStamp is left behind → INVALID.
    //    This is the target bug the stamp exists to catch.
    m.addFace([0u, 1u, 2u]); // degenerate w.r.t. real topology, fine for this probe
    assert(m.structVersion > afterBuild,
        "trace: addFace must bump structVersion");
    assert(!m.loopsValid(),
        "trace: addFace without a following buildLoops must read loops INVALID");
    m.buildLoops();
    assert(m.loopsValid(), "trace: buildLoops after the forgotten-rebuild case must re-validate");
}

unittest {
    // 3. bare addVertex (Points-only, wires nothing) must NOT bump
    //    structVersion and must leave loops/edgeMap valid.
    auto m = makeCube();
    assert(m.loopsValid() && m.edgeMapUsable());
    ulong sv0 = m.structVersion;
    m.addVertex(Vec3(9, 9, 9));
    assert(m.structVersion == sv0,
        "trace: Points-only addVertex must NOT bump structVersion");
    assert(m.loopsValid(),    "trace: addVertex must leave loops valid");
    assert(m.edgeMapUsable(), "trace: addVertex must leave edgeMap usable");
}

unittest {
    // 4. position-only commit must NOT bump structVersion and must leave
    //    loops/edgeMap valid.
    auto m = makeCube();
    ulong sv0 = m.structVersion;
    m.vertices[0].x += 1.0f;
    m.commitChange(MeshEditScope.Position);
    assert(m.structVersion == sv0,
        "trace: Position-only commit must NOT bump structVersion");
    assert(m.loopsValid(),    "trace: position commit must leave loops valid");
    assert(m.edgeMapUsable(), "trace: position commit must leave edgeMap usable");
}

unittest {
    // 5. isSubpatch toggle (Marks-class + explicit topologyVersion bump)
    //    must NOT bump structVersion and must leave loops/edgeMap valid.
    auto m = makeCube();
    ulong sv0 = m.structVersion;
    m.setSubpatch(0, true);
    assert(m.structVersion == sv0,
        "trace: isSubpatch toggle must NOT bump structVersion");
    assert(m.loopsValid(),    "trace: isSubpatch toggle must leave loops valid");
    assert(m.edgeMapUsable(), "trace: isSubpatch toggle must leave edgeMap usable");
}

unittest {
    // 6. addFaceFast (batch, external lookup) defers edgeIndexMap: bumps
    //    structVersion (edge/face structural change) but edgeMapUsable()
    //    reads false until the caller's terminal buildLoops(). Once that
    //    runs, both read valid.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    ulong sv0 = m.structVersion;
    uint[ulong] lookup;
    m.addFaceFast(lookup, [0u, 1u, 2u, 3u]);
    assert(m.structVersion > sv0,
        "trace: addFaceFast must bump structVersion");
    assert(!m.edgeMapUsable(),
        "trace: addFaceFast must leave this.edgeIndexMap Stale (deferred contract)");
    assert(!m.loopsValid(),
        "trace: addFaceFast must leave loops stale until the caller's buildLoops()");
    m.buildLoops();
    assert(m.loopsValid(),    "trace: buildLoops after addFaceFast must validate loops");
    assert(m.edgeMapUsable(), "trace: buildLoops after addFaceFast must validate edgeMap");
}

unittest {
    // A preview-style wipe (subpatch_osd's contract): markDerivedEmpty()
    // reads DeliberatelyEmpty, not Valid and not (bare) Stale.
    auto m = makeCube();
    m.markDerivedEmpty();
    assert(!m.loopsValid(),    "trace: markDerivedEmpty must read loops NOT valid");
    assert(!m.edgeMapUsable(), "trace: markDerivedEmpty must read edgeMap NOT usable");
    assert(m.loopsState_   == Mesh.DerivedState.DeliberatelyEmpty);
    assert(m.edgeMapState_ == Mesh.DerivedState.DeliberatelyEmpty);
}

unittest {
    // A never-built mesh (fresh Mesh.init) must NOT read as valid by the
    // `structVersion == loopsStamp == 0` coincidence — the enum state
    // starts Stale precisely to guard this off-by-one.
    Mesh m;
    assert(m.structVersion == 0 && m.loopsStamp == 0,
        "trace: fresh Mesh.init sanity — both stamps start at 0");
    assert(!m.loopsValid(),    "trace: fresh Mesh.init must NOT read loopsValid");
    assert(!m.edgeMapUsable(), "trace: fresh Mesh.init must NOT read edgeMapUsable");
}

unittest { // mergeFacesByMask: 2-quad strip → 1 six-corner n-gon; non-adjacent → no-op
    import std.algorithm : sort;
    import std.conv      : to;

    // Build a flat 2×1 quad grid:
    //   verts: 0=(0,0,0) 1=(1,0,0) 2=(2,0,0)
    //          3=(0,0,1) 4=(1,0,1) 5=(2,0,1)
    //   face 0 = [0,1,4,3], face 1 = [1,2,5,4]  (shared edge 1–4)
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1)); m.addVertex(Vec3(2,0,1));
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.buildLoops();

    // Merge both faces — 1 interior edge (1–4) dissolved.
    bool[] mask = [true, true];
    size_t dissolved = m.mergeFacesByMask(mask);
    assert(dissolved == 1, "expected 1 edge dissolved, got " ~ dissolved.to!string);
    assert(m.faces.length == 1, "expected 1 merged face");

    // The combined boundary has 6 corners (collinear midpoints 1 and 4 survive
    // — v1 restriction: removeEdgesByMask does not dissolve 2-valent verts).
    uint[] corners = m.faces[0].dup;
    assert(corners.length == 6,
           "merged face must have 6 corners (incl. collinear midpoints)");

    // Corner index SET must equal {0,1,2,3,4,5} — all verts lie on the boundary.
    sort(corners);
    assert(corners == [0u,1u,2u,3u,4u,5u],
           "merged face must reference all 6 verts");

    // Non-adjacent mask (only face 0): no shared interior edges → 0 dissolved.
    Mesh m2;
    m2.addVertex(Vec3(0,0,0)); m2.addVertex(Vec3(1,0,0)); m2.addVertex(Vec3(2,0,0));
    m2.addVertex(Vec3(0,0,1)); m2.addVertex(Vec3(1,0,1)); m2.addVertex(Vec3(2,0,1));
    m2.addFace([0u,1u,4u,3u]);
    m2.addFace([1u,2u,5u,4u]);
    m2.buildLoops();
    assert(m2.mergeFacesByMask([true, false]) == 0,
           "single-face mask must dissolve nothing");
    assert(m2.faces.length == 2, "face count unchanged on no-op");
}

// splitFaceByVertices unittests
// ---------------------------------------------------------------------------

unittest { // splitFaceByVertices: quad split along diagonal {0,2} → two tris + attr carry
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    // Set non-default attrs before the split to prove carry-over.
    m.surfaces ~= Surface("TestMat", Vec3(1, 0, 0));
    m.faceMaterial[0] = 1u;
    m.setSubpatch(0, true);

    size_t n = m.splitFaceByVertices(0, 0, 2);
    assert(n == 1,               "splitFaceByVertices: expected 1 split");
    assert(m.faces.length == 2,  "splitFaceByVertices: expected 2 faces");
    assert(m.edges.length == 5,  "splitFaceByVertices: expected 5 edges (4 boundary + 1 chord)");

    // Winding: i=0, j=2 in the scan → f1=[0,1,2], f2=[2,3,0].
    bool hasF1 = false, hasF2 = false;
    foreach (f; m.faces) {
        if (f[] == [0u,1u,2u]) hasF1 = true;
        if (f[] == [2u,3u,0u]) hasF2 = true;
    }
    assert(hasF1, "splitFaceByVertices: expected face [0,1,2]");
    assert(hasF2, "splitFaceByVertices: expected face [2,3,0]");

    // Attr carry: both halves must inherit material=1 and subpatch flag.
    assert(m.faceMaterial.length >= 2,       "splitFaceByVertices: faceMaterial must cover both halves");
    assert(m.faceMaterial[0] == 1u,          "splitFaceByVertices: f0 must carry parent material");
    assert(m.faceMaterial[1] == 1u,          "splitFaceByVertices: f1 must carry parent material");
    assert(m.isFaceSubpatch(0),              "splitFaceByVertices: f0 must carry parent subpatch flag");
    assert(m.isFaceSubpatch(1),              "splitFaceByVertices: f1 must carry parent subpatch flag");
}

unittest { // splitFaceByVertices: adjacent verts → no-op (returns 0, mesh unchanged)
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    // Standard-adjacent: 0→1 and wrap-adjacent: 3→0.
    assert(m.splitFaceByVertices(0, 0, 1) == 0, "adjacent: must return 0");
    assert(m.splitFaceByVertices(0, 3, 0) == 0, "wrap-adjacent: must return 0");
    assert(m.faces.length == 1,                 "adjacent no-op: face count unchanged");
    assert(m.edges.length == 4,                 "adjacent no-op: edge count unchanged");
}

unittest { // splitFaceByVertices: same-vert / OOB / not-in-face → all return 0
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    assert(m.splitFaceByVertices(0, 0,  0)  == 0, "same-vert: must return 0");
    assert(m.splitFaceByVertices(0, 0, 99)  == 0, "OOB vert: must return 0");
    assert(m.splitFaceByVertices(5, 0,  2)  == 0, "OOB face: must return 0");
    assert(m.faces.length == 1,                   "guards: face count unchanged");
}

// spikeFacesByMask unittests
// ---------------------------------------------------------------------------

// Basic: one quad → 4 tri fan, 1 apex at centroid + normal*disp.
unittest {
    import std.math : abs, sqrt, fabs;
    import std.conv : to;
    // Single 2×2 quad in the XZ plane (Y=0).
    // Winding (-1,0,-1),(-1,0,1),(1,0,1),(1,0,-1) gives +Y normal via Newell.
    // (Verified: ny = Σ(a.z-b.z)*(a.x+b.x) over the 4 edges = +8 > 0.)
    // Centroid = (0,0,0); perimeter = 4*2 = 8; N=4; disp = amount*(8/4) = amount*2
    // With amount=0.5: disp = 1.0 → apex at (0,1,0).
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1));
    m.addVertex(Vec3(-1, 0,  1));
    m.addVertex(Vec3( 1, 0,  1));
    m.addVertex(Vec3( 1, 0, -1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.syncSelection();

    // Assign non-default material + subpatch to the face before spiking.
    m.faceMaterial[0] = 7u;
    m.setFaceSubpatch(0, true);

    bool[] mask = [true];
    size_t n = m.spikeFacesByMask(mask, 0.5f);

    assert(n == 1,                 "spikey: expected 1 face processed");
    assert(m.faces.length  == 4,   "spikey: 1 quad → 4 fan tris");
    assert(m.vertices.length == 5, "spikey: 4 original + 1 apex");

    // Apex should be at (0, 0 + 1.0, 0) = (0, 1, 0).
    Vec3 apex;
    bool apexFound = false;
    foreach (v; m.vertices) {
        float dx = v.x - 0f, dy = v.y - 1.0f, dz = v.z - 0f;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-5f) { apex = v; apexFound = true; break; }
    }
    assert(apexFound, "spikey: apex not at expected position (0,1,0)");

    // All 4 fan tris must carry parent material (7) and subpatch flag.
    foreach (fi; 0 .. m.faces.length) {
        assert(m.faceMaterial.length > fi && m.faceMaterial[fi] == 7u,
               "spikey: material not carried to fan tri " ~ fi.to!string);
        assert(m.isFaceSubpatch(fi),
               "spikey: subpatch not carried to fan tri " ~ fi.to!string);
    }

    // Hole-free: every undirected edge shared by ≤ 2 faces.
    int[ulong] undirected;
    foreach (f; m.faces) {
        foreach (k; 0 .. f.length) {
            ulong a = f[k], b = f[(k + 1) % f.length];
            ulong lo = a < b ? a : b, hi = a < b ? b : a;
            undirected[(lo << 32) | hi]++;
        }
    }
    foreach (_, c; undirected) assert(c <= 2, "spikey: non-manifold edge found");
}

// No-op: mask with no face ≥3 verts → returns 0, mesh unchanged.
unittest {
    auto m = makeCube();
    bool[] mask = new bool[](m.faces.length); // all false
    size_t n = m.spikeFacesByMask(mask, 1.0f);
    assert(n == 0, "spikey no-op: expected 0 processed");
    assert(m.faces.length == 6, "spikey no-op: face count must not change");
    assert(m.vertices.length == 8, "spikey no-op: vertex count must not change");
}

// amount=0: fan-triangulate in place (apex at centroid, zero offset).
unittest {
    import std.math : sqrt;
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1));
    m.addVertex(Vec3( 1, 0, -1));
    m.addVertex(Vec3( 1, 0,  1));
    m.addVertex(Vec3(-1, 0,  1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask = [true];
    size_t n = m.spikeFacesByMask(mask, 0.0f);
    assert(n == 1,                "spikey amount=0: expected 1 processed");
    assert(m.faces.length  == 4,  "spikey amount=0: 1 quad → 4 tris");
    assert(m.vertices.length == 5,"spikey amount=0: 4 + 1 apex at centroid");
    // Apex at centroid = (0,0,0)
    bool found = false;
    foreach (v; m.vertices) {
        float d2 = v.x*v.x + v.y*v.y + v.z*v.z;
        if (d2 < 1e-10f) { found = true; break; }
    }
    assert(found, "spikey amount=0: apex must be at centroid (0,0,0)");
}

// bevelVerticesByMask unittests
// ---------------------------------------------------------------------------

// Basic: cube corner 0, amount=0.2 → 3 new verts (8→10), 1 cap tri + 3
// pentagons (6→7 faces). Material and subpatch carried from incident face.
unittest {
    import std.math : sqrt;
    import std.conv : to;

    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();

    // Assign non-default material + subpatch to one incident face of vertex 0.
    uint incFi = uint.max;
    foreach (fi; m.facesAroundVertex(0)) { incFi = fi; break; }
    assert(incFi != uint.max, "bevelVert: no incident face at vertex 0");
    m.faceMaterial[incFi] = 7u;
    m.setFaceSubpatch(incFi, true);

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;
    size_t n = m.bevelVerticesByMask(mask, 0.2f);

    assert(n == 1,
           "bevelVert: expected 1 processed, got " ~ n.to!string);
    assert(m.vertices.length == 10,
           "bevelVert: expected 10 verts, got " ~ m.vertices.length.to!string);
    assert(m.faces.length == 7,
           "bevelVert: expected 7 faces, got " ~ m.faces.length.to!string);

    // Tally arities: exactly 1 tri (cap) + 3 pentagons.
    int triCount = 0, pentCount = 0;
    bool capSubpatch = false;
    bool capMat7     = false;
    foreach (fi; 0 .. m.faces.length) {
        int arity = cast(int)m.faces[fi].length;
        if (arity == 3) {
            ++triCount;
            if (m.isFaceSubpatch(cast(uint)fi)) capSubpatch = true;
            if (m.faceMaterial[fi] == 7u)        capMat7     = true;
        } else if (arity == 5) {
            ++pentCount;
        }
    }
    assert(triCount  == 1, "bevelVert: expected 1 cap tri, got "    ~ triCount.to!string);
    assert(pentCount == 3, "bevelVert: expected 3 pentagons, got " ~ pentCount.to!string);
    assert(capSubpatch, "bevelVert: cap must carry subpatch from incident face");
    assert(capMat7,     "bevelVert: cap must carry material 7 from incident face");

    // Split verts at expected positions (amount=0.2, unit-cube edges).
    // Corner 0 = (-0.5,-0.5,-0.5); neighbours at (+0.5,-0.5,-0.5),
    // (-0.5,+0.5,-0.5), (-0.5,-0.5,+0.5).
    Vec3[3] expected = [Vec3(-0.3f,-0.5f,-0.5f),
                        Vec3(-0.5f,-0.3f,-0.5f),
                        Vec3(-0.5f,-0.5f,-0.3f)];
    bool[3] found;
    foreach (v; m.vertices) {
        foreach (j; 0 .. 3) {
            Vec3 e = expected[j];
            float d = sqrt((v.x-e.x)*(v.x-e.x) +
                           (v.y-e.y)*(v.y-e.y) +
                           (v.z-e.z)*(v.z-e.z));
            if (d < 1e-4f) found[j] = true;
        }
    }
    foreach (j; 0 .. 3)
        assert(found[j], "bevelVert: split vert " ~ j.to!string ~ " not found");

    // Original corner 0 must have been compacted away.
    bool origPresent = false;
    foreach (v; m.vertices) {
        float d = sqrt((v.x+0.5f)*(v.x+0.5f) +
                       (v.y+0.5f)*(v.y+0.5f) +
                       (v.z+0.5f)*(v.z+0.5f));
        if (d < 1e-4f) { origPresent = true; break; }
    }
    assert(!origPresent, "bevelVert: original corner 0 must be compacted away");
}

// No-op: amount=0 → returns 0, mesh unchanged.
unittest {
    auto m = makeCube();
    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;
    size_t n = m.bevelVerticesByMask(mask, 0.0f);
    assert(n == 0,                "bevelVert no-op: expected 0 processed");
    assert(m.vertices.length == 8, "bevelVert no-op: vertex count unchanged");
    assert(m.faces.length    == 6, "bevelVert no-op: face count unchanged");
}

// facePart inheritance unittests — parallel to the faceMaterial ones above.

unittest { // cutByPlane: facePart must carry over to both split halves
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    m.facePart.length = 1;
    m.facePart[0] = 5u;

    size_t nSplit = m.cutByPlane(Vec3(0.5f, 0, 0), Vec3(1, 0, 0));
    assert(nSplit == 1, "facePart/cutByPlane: expected 1 split");
    assert(m.faces.length == 2, "facePart/cutByPlane: expected 2 faces");
    assert(m.facePart.length >= 2, "facePart must cover both sub-faces");
    assert(m.facePart[0] == 5u, "f0 must inherit parent facePart 5");
    assert(m.facePart[1] == 5u, "f1 must inherit parent facePart 5");
}

unittest { // splitFaceByVertices: facePart must carry over to both halves
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    m.facePart.length = 1;
    m.facePart[0] = 3u;

    size_t n = m.splitFaceByVertices(0, 0, 2);
    assert(n == 1, "facePart/splitFaceByVertices: expected 1 split");
    assert(m.facePart.length >= 2, "facePart must cover both halves");
    assert(m.facePart[0] == 3u, "f0 must carry parent facePart 3");
    assert(m.facePart[1] == 3u, "f1 must carry parent facePart 3");
}

unittest { // spikeFacesByMask: facePart must carry to all fan tris
    import std.conv : to;
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1)); m.addVertex(Vec3(-1, 0,  1));
    m.addVertex(Vec3( 1, 0,  1)); m.addVertex(Vec3( 1, 0, -1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.syncSelection();

    m.facePart.length = 1;
    m.facePart[0] = 9u;

    bool[] mask = [true];
    size_t n = m.spikeFacesByMask(mask, 0.5f);
    assert(n == 1, "facePart/spike: expected 1 face processed");
    assert(m.faces.length == 4, "facePart/spike: expected 4 fan tris");
    foreach (fi; 0 .. m.faces.length)
        assert(m.facePart.length > fi && m.facePart[fi] == 9u,
               "facePart not carried to fan tri " ~ fi.to!string);
}

unittest { // extractSelectedEdgeChain: open chain, closed cycle, branching + multi-component rejections, empty
    import std.conv : to;

    // (1) Open chain: v0-v1-v2-v3 (3 edges, endpoints at v0 and v3).
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(2, 3);
        m.buildLoops();
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(!closed, "open chain: expected isClosed=false");
        assert(chain.length == 4,
            "open chain: expected 4 verts, got " ~ chain.length.to!string);
        assert((chain[0] == 0 && chain[$-1] == 3)
            || (chain[0] == 3 && chain[$-1] == 0),
            "open chain: endpoints must be v0 and v3");
    }

    // (2) Closed cycle: v0-v1-v2-v3-v0 (4 edges, all degree 2).
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(2, 3); m.addEdge(3, 0);
        m.buildLoops();
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(closed, "closed cycle: expected isClosed=true");
        assert(chain.length == 4,
            "closed cycle: expected 4 verts, got " ~ chain.length.to!string);
    }

    // (3) Branching vertex (degree 3): v0-v1, v1-v2, v1-v3 → must reject.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(1, 3);
        m.buildLoops();
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(chain.length == 0,
            "branching vertex: expected rejection (empty chain), got length "
            ~ chain.length.to!string);
    }

    // (4) Two disconnected edges (multi-component, 4 degree-1 endpoints) → must reject.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(2, 3);
        m.buildLoops();
        m.resizeEdgeSelection();
        foreach (ref mk; m.edgeMarks) mk |= Mesh.Marks.Select;

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(chain.length == 0,
            "multi-component: expected rejection, got length "
            ~ chain.length.to!string);
    }

    // (5) No edges selected → empty result.
    {
        Mesh m;
        foreach (i; 0 .. 4) m.addVertex(Vec3(cast(float)i, 0, 0));
        m.addEdge(0, 1); m.addEdge(1, 2);
        m.buildLoops();
        m.resizeEdgeSelection();
        // edgeMarks grown to cover 2 edges but Select bit NOT set.

        bool closed;
        auto chain = m.extractSelectedEdgeChain(closed);
        assert(chain.length == 0,
            "no selection: expected empty chain, got length "
            ~ chain.length.to!string);
    }
}

// weldVertexPair unittests
unittest { // basic weld: two separate quads, weld cross-quad → count drops exactly 1
    import std.math : abs;
    import std.conv : to;
    // Two separate quads with no shared vertices:
    //   quad A: v0=(0,0,0) v1=(1,0,0) v2=(1,0,1) v3=(0,0,1) → face [0,1,2,3]
    //   quad B: v4=(3,0,0) v5=(4,0,0) v6=(4,0,1) v7=(3,0,1) → face [4,5,6,7]
    // Weld keep=1, drop=5: v1=(1,0,0) ← v5=(4,0,0).
    // v1 and v5 share no face → weld must succeed (welded=1, 7 verts after).
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,0,1)); m.addVertex(Vec3(0,0,1));
    m.addVertex(Vec3(3,0,0)); m.addVertex(Vec3(4,0,0));
    m.addVertex(Vec3(4,0,1)); m.addVertex(Vec3(3,0,1));
    m.addFace([0u,1u,2u,3u]);
    m.addFace([4u,5u,6u,7u]);
    m.buildLoops();

    size_t welded = m.weldVertexPair(1, 5);
    assert(welded == 1,
        "weldVertexPair basic: expected welded=1, got " ~ welded.to!string);
    // Exactly 1 vertex removed (not more — orphan removal must not over-count).
    assert(m.vertices.length == 7,
        "weldVertexPair basic: expected 7 vertices, got " ~ m.vertices.length.to!string);
    // Survivor position = keep's (1,0,0).
    bool foundKeep = false;
    foreach (v; m.vertices) {
        if (abs(v.x - 1.0f) < 1e-6f && abs(v.y) < 1e-6f && abs(v.z) < 1e-6f)
            foundKeep = true;
    }
    assert(foundKeep, "weldVertexPair basic: no vertex at keep position (1,0,0)");
    // No face may have a repeated vertex index.
    foreach (fi, face; m.faces) {
        foreach (ai; 0 .. face.length) {
            foreach (bi; ai + 1 .. face.length) {
                assert(face[ai] != face[bi],
                    "weldVertexPair basic: face " ~ fi.to!string
                    ~ " has repeated index " ~ face[ai].to!string);
            }
        }
    }
    // Both faces must still be present (neither collapses to < 3 verts).
    assert(m.faces.length == 2,
        "weldVertexPair basic: expected 2 faces, got " ~ m.faces.length.to!string);
}

unittest { // non-adjacent same-face guard: opposite quad corners → 0 (no-op)
    import std.conv : to;
    // Single quad [0,1,2,3]; weld opposite corners 0 and 2 → shared-face guard.
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,0,1)); m.addVertex(Vec3(0,0,1));
    m.addFace([0u,1u,2u,3u]);
    m.buildLoops();

    size_t vBefore = m.vertices.length;
    size_t fBefore = m.faces.length;
    size_t welded = m.weldVertexPair(0, 2);
    assert(welded == 0,
        "weldVertexPair shared-face: expected 0 (no-op), got " ~ welded.to!string);
    assert(m.vertices.length == vBefore,
        "weldVertexPair shared-face: vertices must not change");
    assert(m.faces.length == fBefore,
        "weldVertexPair shared-face: faces must not change");
}

unittest { // faceless guard: two isolated verts with no faces → 0 (no-op)
    import std.conv : to;
    Mesh m;
    m.addVertex(Vec3(0,0,0));
    m.addVertex(Vec3(0.001f,0,0));
    // No faces — both verts are unreferenced.
    size_t welded = m.weldVertexPair(0, 1);
    assert(welded == 0,
        "weldVertexPair faceless: expected 0 (no-op), got " ~ welded.to!string);
    assert(m.vertices.length == 2,
        "weldVertexPair faceless: must not remove vertices");
}

unittest { // adjacent same-face weld: edge collapse → succeeds, quad collapses to triangle
    import std.math : abs;
    import std.conv : to;
    // Single quad [0,1,2,3]; weld adjacent corners keep=0 and drop=1.
    // weldVerticesByMask remaps 1→0: face becomes [0,0,2,3]; the adjacent
    // duplicate is stripped → [0,2,3], a valid triangle.
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,0,1)); m.addVertex(Vec3(0,0,1));
    m.addFace([0u,1u,2u,3u]);
    m.buildLoops();

    size_t welded = m.weldVertexPair(0, 1);
    assert(welded == 1,
        "adjacent-weld: expected welded=1, got " ~ welded.to!string);
    // One vertex removed: 4 → 3.
    assert(m.vertices.length == 3,
        "adjacent-weld: expected 3 vertices, got " ~ m.vertices.length.to!string);
    // Quad collapses to a single triangle.
    assert(m.faces.length == 1,
        "adjacent-weld: expected 1 face, got " ~ m.faces.length.to!string);
    assert(m.faces[0].length == 3,
        "adjacent-weld: face must be a triangle, got length "
        ~ m.faces[0].length.to!string);
    // No repeated index in the resulting face.
    foreach (ai; 0 .. m.faces[0].length)
        foreach (bi; ai + 1 .. m.faces[0].length)
            assert(m.faces[0][ai] != m.faces[0][bi],
                "adjacent-weld: face has repeated vertex index at "
                ~ ai.to!string ~ " and " ~ bi.to!string);
    // Survivor position = keep (0,0,0); drop's original (1,0,0) must be absent.
    bool foundKeep = false, foundDrop = false;
    foreach (v; m.vertices) {
        if (abs(v.x) < 1e-6f && abs(v.y) < 1e-6f && abs(v.z) < 1e-6f) foundKeep = true;
        if (abs(v.x - 1.0f) < 1e-6f && abs(v.y) < 1e-6f && abs(v.z) < 1e-6f) foundDrop = true;
    }
    assert(foundKeep, "adjacent-weld: survivor position (0,0,0) missing");
    assert(!foundDrop, "adjacent-weld: drop position (1,0,0) must be absent after weld");
}

unittest { // buildEdgeFaces: all-faces, masked, and faceLimit prefix +
           // open-edge-shared-with-a-face-beyond-the-limit correctness
    import std.conv : to;

    // Three quads: FaceA and FaceC share edge (1,2); FaceB (between them in
    // face-index order) is a disjoint quad that touches neither vertex.
    //   FaceA (idx0): [0,1,2,3]
    //   FaceB (idx1): [4,5,6,7]   -- unrelated filler
    //   FaceC (idx2): [2,1,8,9]   -- shares edge (1,2) with FaceA
    Mesh m;
    foreach (i; 0 .. 10) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.addFace([2u, 1u, 8u, 9u]);
    m.buildLoops();

    ulong keyAC = Mesh.edgeKeyOrdered(1, 2);

    // (1) All-faces (default): edge(1,2) sees BOTH FaceA(0) and FaceC(2) → interior.
    auto allEf = m.buildEdgeFaces();
    auto pAll = keyAC in allEf;
    assert(pAll !is null, "buildEdgeFaces all-faces: edge(1,2) missing");
    assert((*pAll)[0] == 0 && (*pAll)[1] == 2,
        "buildEdgeFaces all-faces: edge(1,2) expected faces [0,2], got ["
        ~ (*pAll)[0].to!string ~ "," ~ (*pAll)[1].to!string ~ "]");
    // Total distinct edges: FaceA(4) + FaceB(4) + FaceC(3 new, edge(1,2) shared) = 11.
    assert(allEf.length == 11,
        "buildEdgeFaces all-faces: expected 11 distinct edges, got "
        ~ allEf.length.to!string);

    // (2) Masked: exclude FaceC (idx2) → edge(1,2) only sees FaceA → open.
    bool[] maskNoC = [true, true, false];
    auto maskedEf = m.buildEdgeFaces(maskNoC);
    auto pMasked = keyAC in maskedEf;
    assert(pMasked !is null, "buildEdgeFaces masked: edge(1,2) missing");
    assert((*pMasked)[0] == 0 && (*pMasked)[1] == -1,
        "buildEdgeFaces masked (FaceC excluded): edge(1,2) expected open [0,-1], got ["
        ~ (*pMasked)[0].to!string ~ "," ~ (*pMasked)[1].to!string ~ "]");

    // (3) faceLimit prefix: consider only faces [0,2) (A, B) — FaceC (idx2) is
    // BEYOND the limit, so edge(1,2) must stay open WITHIN THE PREFIX. This is
    // exactly the boundaryLoops correctness case the plan called out: an edge
    // open within [0,nf) that is also shared with a face >= nf must NOT be
    // wrongly marked interior by an unbounded (or null-mask "all faces") build.
    auto prefixEf = m.buildEdgeFaces(null, 2);
    auto pPrefix = keyAC in prefixEf;
    assert(pPrefix !is null, "buildEdgeFaces faceLimit=2: edge(1,2) missing");
    assert((*pPrefix)[0] == 0 && (*pPrefix)[1] == -1,
        "buildEdgeFaces faceLimit=2: edge(1,2) must stay open (face 2 excluded "
        ~ "by the prefix), got [" ~ (*pPrefix)[0].to!string ~ ","
        ~ (*pPrefix)[1].to!string ~ "]");
    // The prefix build must not see FaceC's own edges at all (e.g. edge (8,9)).
    ulong keyC89 = Mesh.edgeKeyOrdered(8, 9);
    assert((keyC89 in prefixEf) is null,
        "buildEdgeFaces faceLimit=2: FaceC-only edge (8,9) must be absent "
        ~ "from the prefix build");
    // Prefix distinct-edge count: FaceA(4) + FaceB(4) = 8 (FaceC excluded entirely).
    assert(prefixEf.length == 8,
        "buildEdgeFaces faceLimit=2: expected 8 distinct edges, got "
        ~ prefixEf.length.to!string);
}

// ---------------------------------------------------------------------------
// mirrorFacesPlane / mirrorFaces (task 0230, oriented mirror-plane backend).
// ---------------------------------------------------------------------------

unittest { // mirrorFacesPlane: tilted 45° plane — reflected positions match
           // the general reflection formula directly (independent check of
           // the same math the implementation uses, on a non-axis-aligned
           // normal), and each cloned face's normal is the REFLECTION of its
           // source face's normal across the plane (with the extra winding-
           // flip negation) — proves the winding-reversal pass stays correct
           // for an arbitrary plane, not just "points away from center".
    import std.conv : to;

    auto m = makeCube();               // 8 verts, 6 faces
    bool[] mask = new bool[](m.faces.length);
    mask[] = true;                     // whole-mesh mirror

    Vec3 center = Vec3(0, 0, 0);
    // Unit normal at 45° between +X and +Z (NOT axis-aligned).
    Vec3 normal = normalize(Vec3(1, 0, 1));

    size_t origVertCount = m.vertices.length;
    size_t origFaceCount = m.faces.length;
    size_t inserted = m.mirrorFacesPlane(mask, center, normal, 0.0f, true);
    assert(inserted == origFaceCount, "mirrorFacesPlane: expected " ~
        origFaceCount.to!string ~ " new faces, got " ~ inserted.to!string);
    assert(m.faces.length == origFaceCount * 2,
        "mirrorFacesPlane: face count must double");

    // (a) Every cloned vert equals the general reflection formula applied
    // to its ORIGINAL position (verts 0..7 map to cloned 8..15 — whole-mesh
    // mirror with no pre-existing coincidences clones each vert exactly once
    // and appends in traversal order, so index i+8 corresponds to source i;
    // proved structurally by comparing SETS below instead of relying on
    // that order).
    bool[] matched = new bool[](origVertCount);
    foreach (i; 0 .. origVertCount) {
        Vec3 orig = m.vertices[i];
        float d = dot(orig - center, normal);
        Vec3 expectedReflected = orig - normal * (2.0f * d);
        bool found = false;
        foreach (j; origVertCount .. m.vertices.length) {
            Vec3 c = m.vertices[j];
            if ((c - expectedReflected).length < 1e-4f) { found = true; break; }
        }
        assert(found, "mirrorFacesPlane: no cloned vert matches the "
            ~ "reflection of original vert " ~ i.to!string);
    }

    // (b) Winding inversion is plane-independent: for a REFLECTION (an
    // orientation-reversing linear map, det = -1), reflecting a face's
    // vertices while keeping the SAME winding order yields normal
    // -R(srcNormal) (the standard A(u)×A(v) = det(A)·A(u×v) identity for an
    // orthogonal A). Reversing the winding order (flipNormals) negates the
    // normal again, so the net result is exactly R(srcNormal) — the plain
    // reflection of the source normal, no extra sign flip. This is the
    // "outward-facing" invariant flipNormals is meant to produce, verified
    // directly (not the weaker "points away from center" check) so the
    // proof holds for any plane orientation, not just axis-aligned ones.
    foreach (fi; 0 .. origFaceCount) {
        Vec3 srcN = m.faceNormal(cast(uint)fi);
        float dn = dot(srcN, normal);
        Vec3 expectedClonedN = srcN - normal * (2.0f * dn);
        Vec3 clonedN = m.faceNormal(cast(uint)(origFaceCount + fi));
        assert((clonedN - expectedClonedN).length < 1e-3f,
            "mirrorFacesPlane: cloned face " ~ fi.to!string ~ " normal does "
            ~ "not match the reflected source normal (flipNormals must "
            ~ "reproduce R(srcNormal), not its negation)");
    }
}
