module mesh;

import std.math : sqrt;
import std.parallelism : parallel;
import std.range : iota;
import math;
import editmode : EditMode;
import mesh_edit_delta : MeshEditTracker, MeshEditScope;
import change_bus : SelDomain;
import mesh_ops.cut : MeshCutOps;
import mesh_ops.bridge : MeshBridgeOps;
import mesh_ops.loop_slice : MeshLoopSliceOps;
import mesh_ops.decimate : MeshDecimateOps;
import mesh_ops.revolve : MeshRevolveOps;
import mesh_ops.cleanup : MeshCleanupOps;
import mesh_ops.bevel : MeshBevelOps;
import mesh_ops.extrude : MeshExtrudeOps;
import mesh_ops.connected_mask : MeshConnectedMaskOps;
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

/// Rounded-hub allocation backstop for `bevelEdgesByMask`'s N-way junction
/// ring (task 0454): a full-ring hub emits `valence · (2^L)²` quad faces, so a
/// crafted high-valence full hub is an attacker-scalable allocation vector.
/// Valence is mesh-derived (not a user Param), so this is a kernel-only cap —
/// an over-cap full hub falls back to the flat N-gon cap, staying sound. No
/// Param/UI layer (there is no user-facing valence knob to clamp).
enum int MAX_JUNCTION_VALENCE = 64;

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

    // Task 0447 (vertex-fan-walk-returns-foreign-edge, KEEP-TWIN redesign):
    // `buildLoops`'s twin pairing (Pass 3) links two darts by undirected-edge
    // identity WITHOUT checking direction, so on inconsistently-wound faces a
    // SAME-direction dart pair sharing an edge is paired as "twins". A proper
    // twin is antiparallel; a same-direction pair has EQUAL tails
    // (`loops[tw].vert == loops[li].vert`). We do NOT erase such a twin — the
    // winding-repair tool (`mesh_ops/cleanup.d computeOrientationFlipMask`,
    // behind `mesh.fixOrientation` / `mesh_analysis.inconsistentWindingFaces`)
    // reads exactly that same-direction twin to DETECT the defect, so erasing
    // it would blind the repair (see doc/vertex_fan_walk_foreign_edge_plan.md
    // §1.2). Instead every vertex incident to a same-direction edge is marked
    // NOT `vertexFanOrdered`: the fan walk stops there as at a boundary and
    // slot-position consumers (`bevelEdgesByMask`,
    // `symmetry.rebuildPairingTopological`) decline. Keyed STRICTLY on
    // same-directionness, NOT on `twin==~0u` — a genuine non-manifold ("book")
    // edge (3+ faces, `twin==~0u` under treatment A) leaves its endpoints
    // fan-ordered, so meaning-2 (non-manifold) and meaning-3 (same-direction)
    // stay distinct. Always sized to vertices.length (same class as
    // `vertLoop`) so `vertexFanOrdered` is an O(1) read.
    private bool[] vertFanOrdered_;

    // CSR vertex→dart adjacency for the fan-walk fallback on unordered
    // vertices: for vertex v, `vertDartAdj[vertDartStart[v] .. vertDartStart[v
    // + 1]]` lists every dart `li` with `loops[li].vert == v` — one entry per
    // face incident to v, built directly from `loops[]` (NOT via the twin
    // graph), correct regardless of winding. Built ONLY when `buildLoops`
    // finds at least one same-direction edge (Risk #1: no per-edge allocation
    // on the clean corpus) — empty on every consistently-wound mesh, so the
    // fast path pays nothing.
    private uint[] vertDartStart;
    private uint[] vertDartAdj;

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
        Hide     = 1 << 2, // per-element hide (task 0613) — see refreshHiddenDerived()
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
    // --- Hide (Marks.Hide, task 0613) --------------------------------------
    // The polygon plane is the ONLY stored authority (§1.2 of
    // doc/hide_geometry_plan.md, measured — not the "conservative" guess the
    // plan's own pre-capture fallback made, which the capture refuted).
    // Vertex and edge are DERIVED and cached in place by
    // refreshHiddenDerived(): a vertex is hidden iff it has at least one
    // incident face and EVERY one of them is hidden (a loose vertex — no
    // incident face — keeps its own settable bit, untouched by the
    // derivation); an edge is hidden iff AT LEAST ONE endpoint vertex is
    // hidden (derived from VERTICES, not polygons — measured: two adjacent
    // hidden polygons do NOT hide the edge they share, because both
    // endpoints still touch a third, visible face). These three scalar
    // readers are non-allocating, same bounds-check-and-return-false
    // contract as isFaceSubpatch above.
    bool isVertexHidden(size_t i) const {
        return i < vertexMarks.length && (vertexMarks[i] & Marks.Hide) != 0;
    }
    bool isEdgeHidden(size_t i) const {
        return i < edgeMarks.length && (edgeMarks[i] & Marks.Hide) != 0;
    }
    bool isFaceHidden(size_t i) const {
        return i < faceMarks.length && (faceMarks[i] & Marks.Hide) != 0;
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
    // Recomputing accessor (never a guard — see refreshHiddenDerived()'s own
    // early-out, which is self-computed and caches no count). A UI readout
    // for "N hidden" (R9 — the isolate trap must never be invisible).
    int countHiddenFaces() const {
        int n = 0;
        foreach (m; faceMarks) if (m & Marks.Hide) n++;
        return n;
    }
    // The vertex/edge twins (S4). All three planes are reported, not just the
    // stored one, because the readout has to answer "why is my geometry
    // missing" in whichever selection type the user is in — a vertex-mode
    // user who hid three faces around a corner sees one vertex vanish, and a
    // face count of 3 does not explain it. Same recomputing contract as
    // above: no cached counter anywhere (R13).
    int countHiddenVertices() const {
        int n = 0;
        foreach (m; vertexMarks) if (m & Marks.Hide) n++;
        return n;
    }
    int countHiddenEdges() const {
        int n = 0;
        foreach (m; edgeMarks) if (m & Marks.Hide) n++;
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
    // read sites must defend with `faceAttrOr(faceMaterial, fi)`
    // so the default-surface fallback works on freshly-built meshes that
    // never had explicit material assignments. See
    // doc/material_groups_plan.md for the data-model rationale.
    Surface[] surfaces;
    uint[]    faceMaterial;
    uint[]    facePart;     /// per-face "part" id (parallel to faceMaterial; read sites defend fi<len?:0)

    // Defensive per-face attribute read for the lazy-resize arrays above
    // (faceMaterial / facePart / faceSelectionOrder): an index past the
    // array's current length yields the default (T.init), not a RangeError.
    private static T faceAttrOr(T)(in T[] attr, size_t fi) { return fi < attr.length ? attr[fi] : T.init; }

    // Combine two face-marks words for a NEW face created FROM multiple
    // source faces — bevel's chamfer strip/cap, loop-slice's section cap
    // (task 0613 §4.2, code review S5). The two bits this mixes are NOT
    // symmetric:
    //  * Subpatch keeps the pre-existing ANY-source OR — a bridging/blended
    //    face inherits smoothness if any of its sources asked for it. This is
    //    cosmetic and unions safely.
    //  * Hide instead uses ALL-source AND — the same law §1.2 of
    //    doc/hide_geometry_plan.md already uses to derive a VERTEX's hidden
    //    state from its incident faces (hidden iff EVERY incident face is
    //    hidden), applied here to a face born from several sources instead of
    //    a vertex born from several incident faces. OR-ing Hide instead would
    //    make newly-created geometry straddling a hide boundary disappear on
    //    creation — a chamfer strip or section cap the user just built in the
    //    visible part of the mesh would read hidden even though no command
    //    ever asked to hide it.
    // `Marks.Hide` alone (every other bit 0) is this operator's identity
    // element: `combineFaceMarksWords(Marks.Hide, w) == w` for any `w` — so a
    // fold over N sources can seed its accumulator with `Marks.Hide` and get
    // the correct "vacuously all-hidden" value if it ever folds zero sources,
    // exactly like `&&`'s identity is `true`.
    private static uint combineFaceMarksWords(uint a, uint b) {
        return ((a | b) & ~Marks.Hide) | (a & b & Marks.Hide);
    }
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
        if (flags & MeshEditScope.Geometry) {
            ++topologyVersion;
            // Hide (task 0613, §1.2): the derived vertex/edge planes ride
            // EVERY geometry-mutating commit through this one funnel, so a
            // topology edit can never leave them stale. refreshHiddenDerived
            // owns its own early-out (a three-plane word-OR) and costs
            // nothing when nothing is hidden anywhere.
            refreshHiddenDerived();
        }
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

    // --- Edge-delete touched region (task 0474) ---------------------------
    // POSITIONS of the endpoints of the edges last handed to removeEdgesByMask
    // (the SELECTION the user asked to delete). Captured before any mutation,
    // so — since compaction never moves a vertex — a surviving endpoint keeps a
    // bit-identical position and can be re-found afterwards. `dissolveDegree2Verts`
    // uses this as its scoping region so the post-remove 2-valent cleanup only
    // touches verts the edge-delete actually reduced, never a distant pre-existing
    // 2-valent vertex (e.g. a 90° corner). Vertex positions, not indices, because
    // removeEdgesByMask reindexes verts through compactUnreferenced. Overwritten
    // on every removeEdgesByMask call; only the edge-delete/remove commands read it.
    private Vec3[] lastEdgeDeleteRegion_;

    /// The touched-region positions captured by the most recent
    /// `removeEdgesByMask` (see `lastEdgeDeleteRegion_`). Consumed by the
    /// edge-mode delete/remove commands to scope `dissolveDegree2Verts`.
    Vec3[] edgeDeleteRegion() const { return lastEdgeDeleteRegion_.dup; }

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
    /// `average` (opt-in, default off): position each surviving vertex at
    /// the CENTROID of its own weld cluster's original member positions
    /// (per-cluster — a single call may collapse several independent
    /// clusters). Default (false) keeps the merge-to-first behavior: the
    /// survivor stays at the lowest-index member's position. Only `vert.merge`
    /// opts in; collapse / vert.join / decimate / drag-weld rely on the
    /// merge-to-first placement and pass the default.
    size_t weldVerticesByMask(in bool[] maskIn, double epsSq, bool average = false) {
        const mask = maskMinusHiddenVertices(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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

        // Opt-in: relocate each surviving vertex to its cluster's centroid.
        // remap is at most one level deep (a member points straight at its
        // lowest-index survivor), so keying sums by remap[i] buckets each
        // cluster exactly. Read original positions before overwriting.
        if (average) {
            Vec3[]   clusterSum   = new Vec3[](vertices.length);
            size_t[] clusterCount = new size_t[](vertices.length);
            clusterSum[] = Vec3(0, 0, 0);   // Vec3.init is NaN — zero it first
            foreach (i; 0 .. vertices.length) {
                int s = remap[i];
                clusterSum[s] = clusterSum[s] + vertices[i];
                ++clusterCount[s];
            }
            foreach (i; 0 .. vertices.length) {
                if (remap[i] != cast(int)i) continue;   // survivors only
                if (clusterCount[i] < 2)     continue;   // singletons unchanged
                double c = cast(double)clusterCount[i];
                vertices[i] = Vec3(cast(float)(clusterSum[i].x / c),
                                   cast(float)(clusterSum[i].y / c),
                                   cast(float)(clusterSum[i].z / c));
            }
        }

        applyVertexRemapAndRebuild(remap);
        return welded;
    }

    /// Rewrite every face through `remap`, drop the corners and faces the
    /// rewrite collapses, and rebuild the derived arrays. The shared tail of
    /// `weldVerticesByMask` and `weldVertexPairs` — extracted verbatim from
    /// the former so both spellings of "these vertices are now that vertex"
    /// produce the identical mesh, and so a future weld producer cannot
    /// forget one of the six things that must follow a corner rewrite.
    ///
    /// `remap` is indexed by vertex id and must be AT MOST ONE LEVEL DEEP
    /// (`remap[remap[i]] == remap[i]` for every i): the face rewrite reads it
    /// once per corner and does not chase chains, so a two-level entry would
    /// leave a corner pointing at a vertex that is itself dead. Both callers
    /// guarantee that — `weldVerticesByMask` by never re-targeting an
    /// already-remapped index, `weldVertexPairs` by rejecting any pair whose
    /// keep is another pair's drop.
    ///
    /// Consecutive duplicates that arise post-remap are dropped (so a quad
    /// whose two adjacent corners merged becomes a triangle); faces left with
    /// fewer than 3 distinct corners are removed entirely.
    private void applyVertexRemapAndRebuild(in int[] remap) {
        uint[][] newFaces;
        uint[]   newWord;   // whole faceMarks word per survivor (task 0613 §4.2)
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
                newWord     ~= faceAttrOr(faceMarks, fi);
                newOrder    ~= faceAttrOr(faceSelectionOrder, fi);
                newMaterial ~= faceAttrOr(faceMaterial, fi);
                newPart     ~= faceAttrOr(facePart, fi);
            }
        }
        faces              = newFaces;
        setFaceMarksFrom(newWord, ~Marks.Select);
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

    /// Weld SEVERAL `[keep, drop]` vertex pairs in ONE pass: every `drop` is
    /// absorbed into its OWN `keep`, independently, and the mesh is rebuilt
    /// once at the end. Returns the number of pairs actually welded.
    ///
    /// WHY THIS EXISTS RATHER THAN A LOOP OVER `weldVertexPair`: that function
    /// rebuilds and COMPACTS the mesh, so every index the caller is holding is
    /// stale the moment it returns. A caller with N independent absorptions to
    /// perform (dragging a whole edge or a whole loop onto other geometry, one
    /// target per grabbed vertex) cannot express that as N calls without
    /// re-deriving its indices between each one. It also collapses N geometry
    /// rebuilds and N `commitChange` notifications into one.
    ///
    /// POSITION RULE, and it differs from `weldVertexPair` deliberately: the
    /// survivor is `keep` itself and stays exactly where `keep` was — the drop
    /// is absorbed INTO the target, the target does not move to meet it.
    /// `weldVertexPair` reaches the same geometry by snapping drop onto keep
    /// and letting the mask pass pick the lower index as survivor; expressing
    /// the remap directly here means no position is written before the rewrite
    /// and no coincidence test can pull in a bystander vertex that happens to
    /// sit on the target.
    ///
    /// A pair is REFUSED (skipped, the rest still weld) when:
    ///  - `keep == drop`, or either index is out of range;
    ///  - `drop` appears as the drop of an earlier pair (a vertex can only be
    ///    absorbed once) or as the keep of any pair, or `keep` appears as the
    ///    drop of any pair — either would build a two-level remap, which
    ///    `applyVertexRemapAndRebuild` does not chase;
    ///  - `keep` and `drop` are NON-ADJACENT corners of one face: that leaves
    ///    `[keep,A,keep,B]`, a self-touching polygon the rewrite cannot
    ///    collapse cleanly. Adjacent same-face pairs (consecutive corners,
    ///    including the head/tail wrap) are the ordinary edge-collapse case and
    ///    ARE allowed — the quad becomes a triangle.
    ///  - neither `keep` nor `drop` is referenced by any face: `compactUnreferenced`
    ///    would drop both as orphans, a net vanish rather than a weld.
    /// The first, third and fourth are `weldVertexPair`'s own rules evaluated
    /// per pair; the second is the one only a LIST can pose.
    ///
    /// COST: one sweep of the mesh, whatever the pair count. The two rules that
    /// need face data are settled for EVERY pair in that single sweep rather
    /// than by re-scanning `faces` per pair — a whole-loop weld on a dense mesh
    /// is hundreds of pairs against tens of thousands of faces, and the naive
    /// shape would put a visible pause on the release that fires it.
    size_t weldVertexPairs(in uint[2][] pairs) {
        if (pairs.length == 0) return 0;
        if (vertices.length < 2) return 0;

        // --- Pass 1: the rejects that need no face data.
        //
        // `isKeep`/`isDrop` are read for the CHAIN test, so they must describe
        // every pair that was asked for, including ones later rejected: a pair
        // whose target is another pair's casualty is refused whichever of the
        // two is examined first, which is what makes the outcome independent of
        // input order.
        bool[] isKeep = new bool[](vertices.length);
        bool[] isDrop = new bool[](vertices.length);
        foreach (p; pairs) {
            if (p[0] == p[1]) continue;
            if (p[0] >= vertices.length || p[1] >= vertices.length) continue;
            isKeep[p[0]] = true;
            isDrop[p[1]] = true;
        }

        // The survivors, in input order. `claimOf[drop]` is the 1-based index
        // of the candidate that claims that drop, so the face sweep below can
        // go from a corner straight to its candidate without searching. A drop
        // is claimed at most once, which is what makes that map single-valued.
        uint[2][] cand;
        int[] claimOf = new int[](vertices.length);
        foreach (p; pairs) {
            immutable uint keep = p[0], drop = p[1];
            if (keep == drop) continue;
            if (keep >= vertices.length || drop >= vertices.length) continue;
            if (claimOf[drop] != 0) continue;             // already claimed
            if (isDrop[keep] || isKeep[drop]) continue;   // would chain
            cand ~= [keep, drop];
            claimOf[drop] = cast(int)cand.length;
        }
        if (cand.length == 0) return 0;

        // --- Pass 2: ONE sweep of the faces settles both face-shaped rules.
        //
        // `cornerPos` is scratch that holds, for the face being examined, where
        // each involved vertex sits in its winding; it is cleared over that
        // face's own corners on the way out, so the whole pass stays O(corners)
        // and never O(vertices) per face.
        bool[] rejected   = new bool[](cand.length);
        bool[] referenced = new bool[](vertices.length);
        int[]  cornerPos  = new int[](vertices.length);
        cornerPos[] = -1;
        foreach (ref face; faces) {
            foreach (i, vid; face) {
                if (vid >= vertices.length) continue;
                referenced[vid] = true;
                if (isKeep[vid] || isDrop[vid]) cornerPos[vid] = cast(int)i;
            }
            foreach (i, vid; face) {
                if (vid >= vertices.length) continue;
                immutable int c = claimOf[vid];
                if (c == 0) continue;                      // not a claimed drop
                immutable int pk = cornerPos[cand[c - 1][0]];
                if (pk < 0) continue;                      // keep not in this face
                immutable int pd = cast(int)i;
                immutable int diff = pk > pd ? pk - pd : pd - pk;
                if (!(diff == 1 || diff == cast(int)face.length - 1))
                    rejected[c - 1] = true;                // non-adjacent same face
            }
            foreach (vid; face) if (vid < vertices.length) cornerPos[vid] = -1;
        }

        int[] remap = new int[](vertices.length);
        foreach (i; 0 .. vertices.length) remap[i] = cast(int)i;

        size_t welded = 0;
        foreach (ci, c; cand) {
            if (rejected[ci]) continue;
            if (!referenced[c[0]] && !referenced[c[1]]) continue;   // both faceless
            remap[c[1]] = cast(int)c[0];
            ++welded;
        }
        if (welded == 0) return 0;

        applyVertexRemapAndRebuild(remap);
        return welded;
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
    size_t splitVerticesByMask(in bool[] maskIn) {
        const mask = maskMinusHiddenVertices(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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
    void collapseVerticesByMask(in bool[] maskIn, Vec3 target) {
        const mask = maskMinusHiddenVertices(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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
    size_t collapseEdgesByMask(in bool[] edgeMaskIn) {
        const edgeMask = maskMinusHiddenEdges(edgeMaskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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
    size_t collapseFacesByMask(in bool[] faceMaskIn) {
        const faceMask = maskMinusHiddenFaces(faceMaskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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
    size_t alignFacesByMask(in bool[] faceMaskIn) {
        const faceMask = maskMinusHiddenFaces(faceMaskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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

        applyVertexRemap(remap);

        // Geometry-class: coincident verts merged, faces/edges rebuilt.
        commitChange(MeshEditScope.Geometry);
        return welded;
    }

    /// Applies a precomputed vertex remap (`remap[i]` = the surviving vertex
    /// index `i` collapses into, or `i` itself if it survives unchanged) to
    /// `faces`: collapses each face's corner list (drop consecutive dups,
    /// drop the wrap-around dup, drop the whole face once it falls below 3
    /// distinct corners), remaps PolyVertex maps, rebuilds edges, and
    /// resizes the parallel per-face arrays. Does **not** call
    /// `commitChange` — the caller owns that. Split out of
    /// `weldCoincidentVertices` (task 0436, pure refactor — zero behavior
    /// change for that function's own 8 call sites) so `bevelEdgesByMask`
    /// can reuse the APPLY half of the weld machinery under its own,
    /// differently-scoped merge predicate without inheriting
    /// `computeWeldRemap`'s all-pairs spatial SEARCH, which that predicate
    /// does not use (it derives its remap from rebuilt-face co-membership,
    /// not from a coincidence scan).
    ///
    /// Returns `faceRemap`: for each OLD face index, the NEW index it lands
    /// at after collapse, or `-1` if the face was dropped entirely. Callers
    /// that carry face-indexed state across the call (e.g. a selection) MUST
    /// re-derive it through this map — a dropped face that is not at the
    /// array tail shifts every face after it.
    private int[] applyVertexRemap(const int[] remap) {
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
        int[] faceRemap = new int[](faces.length);
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
                faceRemap[fi] = cast(int)newFaces.length;
                newFaces ~= f;
                if (remapUv)
                    foreach (sc; srcCorner)
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, sc);
            } else {
                faceRemap[fi] = -1;
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

        return faceRemap;
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

    /// `pinned` vertices are KEPT even when no face references them. Callers
    /// that pass a non-empty list: edge.bevel's valence-4 full-hub free-end
    /// cap, which deliberately retains the reference's orphan cap slide (see
    /// `bevelPinnedOrphans_`); `dissolveVerticesByMask(keepOrphans)`; and the
    /// loose-geometry preservation in the dissolve kernels (task 0502 — see
    /// `captureLooseGeometry`).
    ///
    /// `remapOut`, when non-null, receives the old→new vertex index table this
    /// compaction applied (`~0u` for a dropped vertex). It is written even on
    /// the `removed == 0` early-out, where it is the identity — so a caller may
    /// rely on it unconditionally. It is the ONLY way to carry a vertex
    /// identity across this call by index; positions work too but carry a
    /// coincident-position caveat this does not.
    size_t compactUnreferenced(const(uint)[] pinned = null, uint[]* remapOut = null) {
        bool[] referenced = computeReferencedVertexMask();
        foreach (pi; pinned)
            if (pi < referenced.length) referenced[pi] = true;
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
        // Published BEFORE the early-out so `remapOut` is filled on every path
        // (identity when nothing was dropped).
        if (remapOut !is null) *remapOut = remap;
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

    /// Shared tail of a topology edit: rebuild edges + loops, compact orphan
    /// vertices, rebuild loops again. The second buildLoops() is MANDATORY —
    /// half-edge loops carry face/vert indices that compaction just
    /// invalidated; rebuild so adjacentFaces / verticesAroundVertex / friends
    /// return live indices. (Without this, the next consumer of `loops` walks
    /// stale data and either reports wrong adjacency or indexes out of
    /// bounds.)
    private void finalizeTopologyEdit() {
        rebuildEdges();
        buildLoops();
        compactUnreferenced();
        buildLoops();
    }

    /// Drop the faces marked true in `mask`. Edges are rebuilt from the
    /// surviving faces; orphan vertices (no longer referenced by any
    /// remaining face) are removed via compactUnreferenced() UNLESS
    /// `keepOrphans` is set. Selection arrays are resized and cleared
    /// (re-selecting after a delete is the caller's responsibility — index
    /// validity is unstable across a compact). Returns the number of faces
    /// removed.
    ///
    /// This is the unified delete primitive: Tier 1.1 mesh.delete dispatches
    /// here for every edit mode by translating its selection into a face
    /// mask (verts → faces incident; edges → faces incident; polys
    /// directly).
    ///
    /// `keepOrphans` distinguishes the two topological operations that share
    /// this primitive: Delete (default, `keepOrphans=false`) drops the faces
    /// AND compacts every now-unreferenced vertex, while Remove
    /// (`keepOrphans=true`) drops ONLY the faces and leaves the orphaned
    /// vertices floating in place — matching the reference editor's
    /// polygon-Remove semantic (Delete removes points, Remove keeps them;
    /// task 0465). With `keepOrphans` the `vertices` array is untouched, so
    /// vertex indices/positions stay stable and no vertex reindex is recorded
    /// into an open edit batch (the RemoveFaces entry alone reverts the op).
    ///
    /// `keepFloatingEdges` (task 0477, topology-pen P3): the unconditional
    /// `rebuildEdges()` this primitive otherwise runs re-derives `edges[]`
    /// PURELY by walking the surviving `faces[]` (mesh.d rebuildEdges), so
    /// any edge that borders NO surviving face — an orphaned diagonal left
    /// behind by a triangle→quad splice, or an unrelated bare floating edge
    /// elsewhere in the mesh — is silently wiped even with `keepOrphans` (that
    /// flag only protects floating VERTICES, not floating EDGES). Set
    /// `keepFloatingEdges:true` to skip that rebuild entirely: `edges[]` /
    /// `edgeIndexMap` are left exactly as they were, and the tail
    /// `buildLoops()` (which never assigns `edges[]`, only rebuilds
    /// `edgeIndexMap` FROM it) re-syncs loops around the untouched edge set —
    /// so every floating edge, related or not, survives. Default `false`
    /// (byte-identical to every pre-task-0477 caller).
    size_t deleteFacesByMask(in bool[] maskIn, bool keepOrphans = false,
                             bool keepFloatingEdges = false) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != faces.length) return 0;
        uint[][] keptFaces;
        uint[]   keptWord;   // whole faceMarks word per survivor (task 0613 §4.2)
        int[]    keptOrder;
        uint[]   keptMaterial;
        uint[]   keptPart;
        size_t   removed = 0;
        keptFaces.reserve(faces.length);
        keptWord.reserve(faces.length);
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
                    droppedFaceMat   ~= faceAttrOr(faceMaterial, i);
                    droppedFacePart  ~= faceAttrOr(facePart, i);
                    droppedFaceSub   ~= (isFaceSubpatch(i) ? 1u : 0u);
                }
                continue;
            }
            keptFaces ~= f;
            // faceAttrOr(faceMarks, i), NOT isFaceSubpatch/isSubpatch[i]:
            // carries the WHOLE marks word (Subpatch + Hide + reserved Lock),
            // not just one bit (task 0613 §4.2 — this is the fix for the GAP
            // that used to be documented right here: `setFaceSubpatchFrom`
            // only patched in the Subpatch bit at each NEW index, leaving
            // whatever Hide bit already sat there from truncation, so a
            // deleted face's Hide bit would silently MOVE onto whichever
            // face slides into its vacated slot instead of following its own
            // face or vanishing with it). `keptWord` below re-establishes the
            // word at its captured OLD index `i`, so `setFaceMarksFrom`
            // writes each survivor's OWN word at its new position — same
            // O(F²) trap avoided as the old isFaceSubpatch comment noted
            // (task 0396: a `@property` read here would rebuild a fresh
            // array every iteration; `faceAttrOr` is O(1) non-allocating).
            keptWord     ~= faceAttrOr(faceMarks, i);
            keptOrder    ~= faceAttrOr(faceSelectionOrder, i);
            keptMaterial ~= faceAttrOr(faceMaterial, i);
            keptPart     ~= faceAttrOr(facePart, i);
            if (remapUv)
                foreach (c; 0 .. f.length)
                    oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)i, cast(uint)c);
        }
        if (removed == 0) return 0;
        if (recDelete)
            editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                            droppedFaceMat, droppedFacePart, droppedFaceSub);
        faces              = keptFaces;
        // Select is still dropped deliberately (~Marks.Select) — the
        // subsequent clearFaceSelectionResize() below relied on that being
        // true regardless, so this stays behaviourally identical for Select;
        // Subpatch and Hide now BOTH ride along in the same word, at the
        // survivor's own captured index, not whatever slot they land in.
        setFaceMarksFrom(keptWord, ~Marks.Select);
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
        //
        // `keepFloatingEdges` (task 0477, KILLER-2 fix): skip this rebuild
        // when the caller wants floating edges (bordering no surviving
        // face) to survive instead of being wiped — see the ctor doc above.
        if (!keepFloatingEdges) rebuildEdges();
        clearEdgeSelectionResize();
        // Compact orphan vertices (no-op if all verts still referenced).
        // Skipped for Remove (keepOrphans): the faces go, the now-unused
        // points stay floating in place (task 0465 — reference-editor
        // poly-Remove keeps points; only Delete removes them).
        if (!keepOrphans) compactUnreferenced();
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
    size_t flipFacesByMask(in bool[] maskIn) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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
    /// `keepOrphans` (reference-editor parity for delete/remove): dissolving the
    /// masked verts removes EXACTLY them. Any OTHER vertex left unreferenced
    /// because its faces degenerated away stays as a loose point instead of
    /// being swept. Measured: vertex delete AND vertex remove both keep such
    /// collateral orphans (a prism whose three surviving corners lose every face
    /// keeps those three points, 0 faces); only polygon-Delete compacts orphans.
    /// The masked verts are dropped from every face → always unreferenced → the
    /// compact removes them regardless; pinning the non-masked verts spares the
    /// collateral orphans. Default false preserves the compact-all behaviour for
    /// every other caller (edge_join, the cleanup hygiene sweep).
    ///
    /// Independent of `keepOrphans`: face-less geometry that was ALREADY
    /// face-less before this call — loose points, bare wire edges, anywhere in
    /// the mesh — survives (task 0502, see `captureLooseGeometry`). A MASKED
    /// vertex is never spared by that, because the mask is the caller naming
    /// it. `keepOrphans` remains the knob for the different question of what to
    /// do with verts THIS call newly orphaned.
    size_t dissolveVerticesByMask(in bool[] maskIn, bool keepOrphans = false) {
        const mask = maskMinusHiddenVertices(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != vertices.length) return 0;
        size_t dissolved = 0;
        foreach (vi; 0 .. mask.length) if (mask[vi]) ++dissolved;
        if (dissolved == 0) return 0;

        // Before anything rewrites `faces[]`: what is face-less right NOW is
        // pre-existing, and nothing this call does can make it collateral.
        const loose = captureLooseGeometry();

        // Rebuild faces array, dropping each masked vert from every face's
        // boundary. Faces shrunk below 3 verts (degenerate) are dropped.
        uint[][] newFaces;
        uint[]   newWord;   // whole faceMarks word per survivor (task 0613 §4.2)
        int[]    newOrder;
        uint[]   newMaterial;
        uint[]   newPart;
        newFaces.reserve(faces.length);
        newWord.reserve(faces.length);
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
                newWord     ~= faceAttrOr(faceMarks, fi);
                newOrder    ~= faceAttrOr(faceSelectionOrder, fi);
                newMaterial ~= faceAttrOr(faceMaterial, fi);
                newPart     ~= faceAttrOr(facePart, fi);
                if (remapUv)
                    foreach (kc; keptCorner)
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, kc);
            } else if (recDis) {
                // Degenerate face dropped — reconstruct it on revert at its
                // post-shrink position in the new face array.
                removedFaceIdx   ~= cast(uint)newFaces.length;
                removedFaceLists ~= f.dup;
                removedFaceMat   ~= faceAttrOr(faceMaterial, fi);
                removedFacePart  ~= faceAttrOr(facePart, fi);
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
        setFaceMarksFrom(newWord, ~Marks.Select);
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
        uint[] pinned;
        if (keepOrphans) {
            // Pin every non-masked vert so the compact removes ONLY the
            // dissolved (masked, now unreferenced) verts, sparing collateral
            // orphans (see the keepOrphans note on the signature).
            foreach (i; 0 .. mask.length) if (!mask[i]) pinned ~= cast(uint)i;
        } else {
            // Pin only the PRE-EXISTING loose points (task 0502) — collateral
            // orphans this call created still go, which is what !keepOrphans
            // means.
            pinned = looseVertPins(loose, mask);
        }
        uint[] vremap;
        compactUnreferenced(pinned, &vremap);
        restoreLooseWires(loose, vremap);
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
    ///
    /// `region` (task 0474): when non-null, ONLY verts whose position matches
    /// an entry are eligible — the touched region of an edge delete (the
    /// endpoints of the deleted edges, from `edgeDeleteRegion`). This scopes the
    /// cleanup to the verts the edit actually reduced to 2-valent, matching the
    /// reference editor's edge-delete: a pre-existing 2-valent vertex NOT touched
    /// by the removed edges (a 90° corner, a straight-through midpoint elsewhere)
    /// is left in place. Passing null keeps the legacy mesh-wide behavior (the
    /// opt-in `dissolve2Valent` hygiene sweep in cleanupMesh). NB the eligibility
    /// is purely region membership — there is deliberately NO collinearity /
    /// angle test: the reference editor dissolves a touched endpoint regardless
    /// of the angle its two survivors make (a 135° bent endpoint of a removed
    /// edge is dissolved just like a straight one; only being outside the region
    /// spares a vertex — measured against the reference editor, task 0474).
    /// Returns the number of verts dissolved.
    /// `keepOrphans` is forwarded to `dissolveVerticesByMask`: the edge
    /// delete/remove cleanup keeps collateral orphans (verts whose faces
    /// degenerated to < 3 while their own valence stayed > 2) as loose points,
    /// matching the reference editor. The opt-in cleanup hygiene sweep keeps the
    /// default (compact-all) behaviour.
    size_t dissolveDegree2Verts(in Vec3[] region = null, bool keepOrphans = false) {
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
            if (d != 2) continue;
            if (region !is null && !positionInRegion(vertices[i], region)) continue;
            mask[i] = true; ++cnt;
        }
        if (cnt == 0) return 0;
        return dissolveVerticesByMask(mask, keepOrphans);
    }

    /// True iff `p` coincides (within a tight epsilon) with any position in
    /// `region`. Used by `dissolveDegree2Verts` to scope its cleanup. The
    /// positions flow through unchanged (compaction copies verts by value, never
    /// recomputes), so an exact match would suffice; the small epsilon only
    /// guards against future float re-derivation. Linear scan — both the region
    /// (deleted-edge endpoints) and the 2-valent candidate set are tiny.
    private static bool positionInRegion(in Vec3 p, in Vec3[] region) {
        enum float epsSq = 1e-12f;
        foreach (ref r; region) {
            immutable dx = p.x - r.x, dy = p.y - r.y, dz = p.z - r.z;
            if (dx*dx + dy*dy + dz*dz <= epsSq) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Loose (face-less) geometry preservation — task 0502
    //
    // Every dissolve kernel below ends in `rebuildEdges()` + `compactUnreferenced()`.
    // BOTH re-derive from `faces[]`, MESH-WIDE: the first rebuilds `edges[]` by
    // walking the surviving faces, so an edge that borders NO polygon vanishes;
    // the second drops every vertex no polygon references. Neither looks at
    // which part of the mesh the caller actually edited, so dissolving ONE
    // interior edge used to take every bare wire edge and every loose point in
    // the mesh with it, arbitrarily far from the edit.
    //
    // That is pure collateral damage, not a behaviour: vibe3d builds both as
    // ordinary intermediate retopo state (a placed point; a chain drawn before
    // any polygon closes over it), so the loss is silent destruction of work in
    // progress. `deleteFacesByMask` already carries `keepFloatingEdges` for
    // exactly this reason; the dissolves cannot take that route because they
    // REINDEX vertices, so the edge array cannot simply be left alone.
    //
    // The fix is therefore capture-and-replay, and it is the KERNEL's job
    // rather than each caller's: no caller of a dissolve can plausibly want
    // mesh-wide destruction of geometry it did not name, and an opt-in flag
    // would leave the trap armed for the next caller. Explicit orphan removal
    // remains available and untouched — `compactUnreferenced()` direct, or
    // Cleanup's `removeOrphans` — so nothing loses the ability to sweep.
    //
    // What is deliberately NOT preserved: geometry the edit itself consumed. A
    // wire edge whose endpoint the dissolve legitimately removed stays gone
    // (its endpoint's remap entry is `~0u`, and the replay skips it). This
    // restores UNRELATED geometry; it does not resurrect the edit.
    // -----------------------------------------------------------------------

    /// The mesh's FACE-LESS geometry — vertices no polygon references, and
    /// edges no polygon borders — in the CURRENT vertex-index space.
    private static struct LooseGeometry {
        uint[]    verts;   // vertex indices referenced by no face
        uint[2][] wires;   // edges bordering no face, by endpoint vertex index
        bool empty() const { return verts.length == 0 && wires.length == 0; }
    }

    /// Snapshot the face-less geometry BEFORE a dissolve rewrites `faces[]`.
    /// Indices are valid until the tail `compactUnreferenced` reindexes — every
    /// dissolve leaves `vertices[]` untouched until then, which is what makes
    /// the index-keyed (rather than position-keyed) capture sound here.
    private LooseGeometry captureLooseGeometry() const {
        LooseGeometry g;
        auto referenced = computeReferencedVertexMask();
        foreach (i, r; referenced)
            if (!r) g.verts ~= cast(uint)i;
        // Zero incident polygons ⇒ a bare wire. Counted off `faces[]` via
        // `edgePolygonCounts`, the counter that cannot undercount.
        auto polyCount = edgePolygonCounts();
        foreach (ei; 0 .. edges.length)
            if (polyCount[ei] == 0)
                g.wires ~= [edges[ei][0], edges[ei][1]];
        return g;
    }

    /// The vertices of `g` that must be PINNED through the tail compaction,
    /// minus anything `excluded` (a dissolve's own target mask) names: a loose
    /// vertex the caller explicitly asked to remove is not collateral damage.
    /// `excluded` may be empty.
    private static uint[] looseVertPins(in LooseGeometry g, in bool[] excluded) {
        uint[] pins;
        foreach (v; g.verts)
            if (v >= excluded.length || !excluded[v]) pins ~= v;
        return pins;
    }

    /// Re-add the bare wire edges of `g` that the rebuild wiped, through the
    /// `remap` the tail `compactUnreferenced` published. Call AFTER that
    /// compaction and BEFORE the terminal `buildLoops()`. A wire is skipped
    /// when either endpoint was dropped (the edit took it), when the rebuild
    /// already re-derived it from a surviving face, or when it degenerated.
    private void restoreLooseWires(in LooseGeometry g, in uint[] remap) {
        if (g.wires.length == 0) return;
        bool added = false;
        foreach (ref w; g.wires) {
            if (w[0] >= remap.length || w[1] >= remap.length) continue;
            immutable uint a = remap[w[0]], b = remap[w[1]];
            if (a == cast(uint)~0u || b == cast(uint)~0u || a == b) continue;
            if (edgeIndex(a, b) != cast(uint)~0u) continue;
            addEdge(a, b);
            added = true;
        }
        // `addEdge` appends past the length the enclosing kernel's
        // `clearEdgeSelectionResize()` just settled on.
        if (added) clearEdgeSelectionResize();
    }

    /// Which vertices an edge dissolve of `mask` consumes ENTIRELY — the
    /// companion query to `removeEdgesByMask(mask, keepConsumedVerts:false)`.
    ///
    /// The rule, in full (task 0494, recovered from the reference editor's own
    /// removal primitive and reproduced here directly rather than approximated):
    ///
    ///   a vertex disappears **iff** it is an endpoint of a dissolving edge
    ///   AND every polygon of its incident fan is itself incident to some
    ///   dissolving edge.
    ///
    /// Read the two halves separately, because BOTH are load-bearing:
    ///
    ///   * The CANDIDATE set is the endpoints of the dissolving edges, never
    ///     "every vertex the merge touched". On a 4x4 grid dissolving the
    ///     3-edge column {(1,5),(5,9),(9,13)}, vertex 4's whole fan {f00,f10}
    ///     IS consumed — but 4 is nobody's dissolving endpoint, so it stays.
    ///   * The TEST is fan completeness, not valence. `dissolveDegree2Verts`
    ///     (this file's other cleanup pass) is the valence rule, and the two
    ///     DIVERGE IN BOTH DIRECTIONS — see this method's unittests, which pin
    ///     the two constructed masks that separate them. On a plain quad grid
    ///     dissolving a whole loop they happen to coincide, so a green test on
    ///     that fixture alone proves nothing about which rule is implemented.
    ///
    /// Only mask entries that will ACTUALLY dissolve count: an edge with other
    /// than exactly two incident polygons is skipped, matching
    /// `removeEdgesByMask`'s own boundary-edge skip, so a border edge in the
    /// mask neither marks its single polygon nor nominates its endpoints.
    ///
    /// Pure query — indexes and answers in the CURRENT (pre-dissolve) vertex
    /// index space. Returns an all-false mask when `mask` is the wrong length.
    bool[] consumedFanVertexMask(in bool[] mask) const {
        bool[] result;
        result.length = vertices.length;
        if (mask.length != edges.length || faces.length == 0) return result;

        // How many polygons each undirected edge borders. Counted straight off
        // `faces` (not `buildEdgeFaces`, whose two-slot int[2] cannot witness a
        // third incident polygon) so "exactly two" really means exactly two.
        int[ulong] polyCount;
        foreach (ref f; faces)
            foreach (k; 0 .. f.length)
                ++polyCount[edgeKey(f[k], f[(k + 1) % f.length])];

        // The edges that will dissolve, as undirected keys.
        bool[ulong] doomed;
        foreach (i; 0 .. edges.length) {
            if (!mask[i]) continue;
            immutable ulong key = edgeKey(edges[i][0], edges[i][1]);
            auto pc = key in polyCount;
            if (pc is null || *pc != 2) continue;
            doomed[key] = true;
        }
        if (doomed.length == 0) return result;

        // Candidates: the endpoints of those edges, and nothing else.
        bool[] candidate;
        candidate.length = vertices.length;
        foreach (i; 0 .. edges.length) {
            if (!mask[i]) continue;
            if (edgeKey(edges[i][0], edges[i][1]) !in doomed) continue;
            foreach (v; edges[i])
                if (v < candidate.length) candidate[v] = true;
        }

        // A polygon is CONSUMED when it borders a dissolving edge.
        bool[] consumedFace;
        consumedFace.length = faces.length;
        foreach (fi, ref f; faces)
            foreach (k; 0 .. f.length)
                if (edgeKey(f[k], f[(k + 1) % f.length]) in doomed) {
                    consumedFace[fi] = true;
                    break;
                }

        // A vertex is SPARED as soon as one polygon of its fan survives; a
        // vertex with no fan at all is spared too (an empty fan is not a
        // consumed one).
        bool[] spared, hasFan;
        spared.length = hasFan.length = vertices.length;
        foreach (fi, ref f; faces)
            foreach (v; f) {
                if (v >= vertices.length) continue;
                hasFan[v] = true;
                if (!consumedFace[fi]) spared[v] = true;
            }

        foreach (i; 0 .. vertices.length)
            result[i] = candidate[i] && hasFan[i] && !spared[i];
        return result;
    }

    /// `removeEdgesByMask`, then DROP the vertices the dissolve consumed
    /// entirely (`consumedFanVertexMask`) — re-stitching the survivors around
    /// them. Task 0494: the reference editor's edge removal runs this purge
    /// unless its "keep vertex" option is on, and that option defaults OFF, so
    /// THIS overload is the reference default and the one-argument form above
    /// is its "keep vertex ON" branch.
    ///
    /// `keepConsumedVerts: true` forwards verbatim to the one-argument overload
    /// (so a caller can pass the flag straight through without branching); every
    /// pre-existing caller keeps the one-argument form and is byte-unchanged.
    ///
    /// The consumed set is resolved BEFORE the dissolve and carried across it by
    /// POSITION — the dissolve reindexes vertices (`compactUnreferenced`), and
    /// positions flow through compaction by value. Same technique, and the same
    /// coincident-position caveat, as `lastEdgeDeleteRegion_`.
    ///
    /// Returns the number of edges dissolved, exactly as the one-argument form.
    size_t removeEdgesByMask(in bool[] maskIn, bool keepConsumedVerts) {
        const mask = maskMinusHiddenEdges(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (keepConsumedVerts) return removeEdgesByMask(mask);

        Vec3[] consumedPos;
        foreach (i, c; consumedFanVertexMask(mask))
            if (c) consumedPos ~= vertices[i];

        immutable size_t dissolved = removeEdgesByMask(mask);
        if (dissolved == 0 || consumedPos.length == 0) return dissolved;

        // A consumed vertex that the merge already left face-unreferenced is
        // gone (the dissolve's own tail compaction took it); the rest are still
        // corners of a merged polygon and are dropped from it here.
        bool[] vmask;
        vmask.length = vertices.length;
        size_t hit = 0;
        foreach (i; 0 .. vertices.length)
            if (positionInRegion(vertices[i], consumedPos)) { vmask[i] = true; ++hit; }
        if (hit > 0) dissolveVerticesByMask(vmask, /*keepOrphans*/true);
        return dissolved;
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
    ///
    /// This overload KEEPS every vertex the merge consumed, as a corner of the
    /// merged polygon. The two-argument overload above drops them instead.
    ///
    /// Face-less geometry elsewhere in the mesh (loose points, bare wire edges)
    /// SURVIVES — see the `captureLooseGeometry` block above for why the tail
    /// used to wipe it mesh-wide and why the fix lives here rather than in each
    /// caller.
    size_t removeEdgesByMask(in bool[] maskIn) {
        const mask = maskMinusHiddenEdges(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != edges.length) return 0;
        // Before anything rewrites `faces[]`: what is face-less right NOW is
        // pre-existing, and nothing this call does can make it collateral.
        const loose = captureLooseGeometry();

        // Touched-region capture (task 0474): remember the POSITIONS of the
        // endpoints of the edges the caller asked to delete, BEFORE any mutation.
        // The edge-mode delete/remove commands use this to scope the follow-up
        // dissolveDegree2Verts so pre-existing 2-valent verts elsewhere (90°
        // corners, straight-through midpoints far from the edit) are left alone.
        // Positions (not indices) survive removeEdgesByMask's vert reindexing.
        lastEdgeDeleteRegion_ = null;

        // Snapshot selected edges as undirected keys; edge-array indices
        // are unstable across compactUnreferenced.
        bool[ulong] selectedEdgeKeys;
        bool[uint]  regionSeen;
        foreach (i; 0 .. edges.length)
            if (mask[i]) {
                uint a = edges[i][0], b = edges[i][1];
                selectedEdgeKeys[edgeKey(a, b)] = true;
                if (a < vertices.length && a !in regionSeen) {
                    regionSeen[a] = true; lastEdgeDeleteRegion_ ~= vertices[a];
                }
                if (b < vertices.length && b !in regionSeen) {
                    regionSeen[b] = true; lastEdgeDeleteRegion_ ~= vertices[b];
                }
            }
        if (selectedEdgeKeys.length == 0) { lastEdgeDeleteRegion_ = null; return 0; }

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
        uint[]   newPolyWord;   // whole faceMarks word, task 0613 §4.2
        int[]    newPolyOrder;
        uint[]   newPolyMaterial;
        uint[]   newPolyPart;
        // Parallel to newPolyList: the OLD loop index that produced each merged
        // corner (mechanism b). `~0u` ⇒ no traceable source ⇒ zero-fill.
        uint[][] newPolySrcLoop;
        foreach (root, comp; componentFaces) {
            if (comp.length < 2) continue;

            // Every edge INTERNAL to this merged component vanishes from the
            // union boundary — not only the explicitly-selected edges. An edge
            // shared by two of the component's faces is interior once those
            // faces merge, even if the caller did not select it: it got
            // internalised because its two faces were joined through OTHER
            // selected edges. Dropping only the selected edges leaves such an
            // edge as an antenna spike with a dangling vertex, which the
            // reference editor does not keep (measured on non-cube prism
            // geometry: the merged polygon is the boundary of the face union,
            // with no interior stubs). Tally per-component edge multiplicity;
            // an edge appearing >= 2 times among the component's faces is
            // interior and dissolves. On a clean merge where every interior
            // edge WAS selected (e.g. the cube-corner fan) this is identical to
            // the selected-only drop, so those results stay byte-for-byte.
            int[ulong] compEdgeCount;
            foreach (fi; comp) {
                auto f = faces[fi];
                foreach (k; 0 .. f.length)
                    ++compEdgeCount[edgeKey(f[k], f[(k + 1) % f.length])];
            }

            // Gather directed half-edges from the component, dropping
            // half-edges whose edge is interior to the component (appears in two
            // of its faces); boundary edges — including selected edges with only
            // one adjacent face in the component — survive on the merged
            // boundary. `outSrc` carries the OLD loop index of the half-edge's
            // START corner, parallel to `outAt`.
            uint[][uint] outAt;  // outAt[u] = list of `v` for each surviving u→v
            uint[][uint] outSrc; // outSrc[u][i] = old loop index of u→v's start
            foreach (fi; comp) {
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    uint a = f[k], b = f[(k + 1) % f.length];
                    if (compEdgeCount[edgeKey(a, b)] >= 2) continue;
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

            // Inherit the whole marks word (Subpatch + Hide + reserved Lock,
            // task 0613 §4.2 — was Subpatch-only) and selection-order from the
            // FIRST face in the component (arbitrary but deterministic).
            int firstFi = cast(int)comp[0];
            newPolyList      ~= poly;
            newPolyWord      ~= faceAttrOr(faceMarks, cast(size_t)firstFi);
            newPolyOrder     ~= faceAttrOr(faceSelectionOrder, firstFi);
            newPolyMaterial  ~= faceAttrOr(faceMaterial, firstFi);
            newPolyPart      ~= faceAttrOr(facePart, firstFi);
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
        uint[]   keptWord;   // whole faceMarks word per face (task 0613 §4.2)
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
                    droppedFaceMat   ~= faceAttrOr(faceMaterial, fi);
                    droppedFacePart  ~= faceAttrOr(facePart, fi);
                    droppedFaceSub   ~= (isFaceSubpatch(cast(uint)fi) ? 1u : 0u);
                }
                continue;
            }
            keptFaces ~= faces[fi];
            keptWord     ~= faceAttrOr(faceMarks, fi);
            keptOrder    ~= faceAttrOr(faceSelectionOrder, fi);
            keptMaterial ~= faceAttrOr(faceMaterial, fi);
            keptPart     ~= faceAttrOr(facePart, fi);
            // Kept faces preserve arity → corner c maps to old loop fi/c (a).
            if (remapUv)
                foreach (c; 0 .. faces[fi].length)
                    oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, cast(uint)c);
        }
        // Tail range start = number of kept (non-dropped) faces.
        const size_t firstMerged = keptFaces.length;
        foreach (i; 0 .. newPolyList.length) {
            keptFaces    ~= newPolyList[i];
            keptWord     ~= newPolyWord[i];
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
        setFaceMarksFrom(keptWord, ~Marks.Select);
        faceSelectionOrder = keptOrder;
        faceMaterial       = keptMaterial;
        facePart           = keptPart;
        // PolyVertex relocate (b): per-corner values follow the merged/kept
        // corners. Before the tail buildLoops (which then no-ops the resize).
        if (remapUv) remapPolyVertexMaps(oldLoopOfNewLoop);
        clearFaceSelectionResize();

        // Rebuild edges + compact orphan verts. The pre-existing loose verts
        // are PINNED so the compaction takes only what this dissolve consumed,
        // and the bare wires are replayed through its remap (task 0502).
        rebuildEdges();
        clearEdgeSelectionResize();
        uint[] vremap;
        compactUnreferenced(loose.verts, &vremap);
        restoreLooseWires(loose, vremap);
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
    size_t triangulateFacesByMask(in bool[] maskIn, uint[]* faceOriginOut = null) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != faces.length) return 0;

        // PolyVertex remap, mechanism (b): triangulation changes arity — each
        // n-gon splits into (n-2) triangles; each triangle corner comes from a
        // specific OLD face corner.
        const bool remapUv = hasPolyVertexMap();
        const uint[] oldFaceLoop = remapUv ? captureFaceLoop() : null;
        uint[] oldLoopOfNewLoop;

        uint[][] newFaces;
        uint[]   newWord;   // whole faceMarks word per emitted face (task 0613 §4.2)
        int[]    newOrder;
        uint[]   newMaterial;
        uint[]   newPart;
        uint[]   faceOrigin;   // faceOrigin[new_fi] = original fi

        size_t changed = 0;

        foreach (fi; 0 .. faces.length) {
            auto f    = faces[fi];
            uint word = faceAttrOr(faceMarks, fi);
            int  ord = faceAttrOr(faceSelectionOrder, fi);
            uint mat = faceAttrOr(faceMaterial, fi);
            uint prt = faceAttrOr(facePart, fi);

            if (!mask[fi] || f.length <= 3) {
                // Pass through untouched.
                newFaces    ~= f.dup;
                newWord     ~= word;
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
                // Every triangle of the fan inherits the source face's WHOLE
                // marks word (Subpatch + Hide), same "each piece keeps the
                // parent's word" rule as every other 1-to-many split above.
                ++changed;
                for (uint i = 1; i + 1 < f.length; ++i) {
                    newFaces    ~= [f[0], f[i], f[i + 1]];
                    newWord     ~= word;
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
        setFaceMarksFrom(newWord, ~Marks.Select);
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
            ulong key = edgeKey(edges[ei][0], edges[ei][1]);
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
    size_t quadrupleFacesByMask(in bool[] maskIn) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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
    size_t detriangulateFacesByMask(in bool[] maskIn) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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
    size_t mergeFacesByMask(in bool[] maskIn) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != faces.length) return 0;
        bool acceptAll(uint, uint, uint) { return true; }
        bool[] edgeMask = selectMergeEdges(mask, &acceptAll, false /* region */);
        return removeEdgesByMask(edgeMask);
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
            faceMaterial[idx] = faceAttrOr(faceMaterial, srcFi);
            facePart[idx]     = faceAttrOr(facePart, srcFi);
            selectFace(cast(int)idx);
        }
        resizeVertexSelection();
        clearVertexSelection();
        resizeEdgeSelection();
        clearEdgeSelection();

        // FULL PARITY (weld coincident-face convention): weld merges coincident
        // VERTS only — no face fingerprint-dedup. When the rotation maps a copy
        // onto itself or onto the source (e.g. a 180° radial of a symmetric
        // solid about its own axis, or a closed 360° ring whose first/last steps
        // abut), the reference editor KEEPS the doubled coincident faces
        // (opposite-wound shell). So we fold coincident verts and drop only the
        // orphaned welded-away vert slots — matching arrayFaces / mirrorFaces.
        if (weld > 0.0f) {
            double epsSq = cast(double)weld * cast(double)weld;
            if (weldCoincidentVertices(epsSq) > 0) {
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
    /// `detachSubsetSource` selects the reference editor's poly.array copy
    /// model for a PARTIAL selection. The reference REPLACES each selected
    /// source polygon with `count` fresh copies rather than keeping the
    /// source and appending `count-1` — so a copy landing at the source
    /// position gets its OWN duplicated verts instead of sharing the seam
    /// verts with the unselected neighbours it was welded to. When the flag
    /// is set AND the selection is a strict subset (`selCount < faces.length`)
    /// the source faces are detached first (their verts duplicated at
    /// offset 0, the faces repointed to the duplicates) so the total is
    /// `count` independent instances. For a WHOLE-MESH array there are no
    /// unselected neighbours to share with, so keep+`count-1` and
    /// replace-with-`count` are geometrically identical and the detach is
    /// skipped, leaving that path byte-for-byte unchanged. The flag defaults
    /// off so the interactive Clone tool / clone command keep their exact
    /// original (source-preserving) behaviour.
    ///
    /// Selection ends on the resulting copies (all `count` instances for a
    /// detached subset — the repointed source is copy 0; otherwise the
    /// `count-1` marched copies with originals deselected). Vert / edge
    /// selections are cleared. Returns the number of new faces inserted.
    ///
    /// Rotate / scale per-step variants are deferred to a follow-up —
    /// per-step rotation pivot semantics overlap with Radial Array
    /// (which has its own pivot/axis schema) so they live in that
    /// command's surface, not here.
    size_t arrayFaces(in bool[] mask, int count, Vec3 offset, float weld,
                      bool detachSubsetSource = false) {
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

        // FULL-PARITY sub-face copy model (reference poly.array): for a
        // strict subset the selected source polygons are REPLACED by `count`
        // fresh copies, so the copy that lands at the source position must
        // own duplicated verts rather than share the seam verts it was
        // welded to. Realise that by DETACHING the source: duplicate its
        // verts at offset 0 and repoint the source faces to the duplicates.
        // The `count-1` marched copies below then bring the total to `count`
        // independent instances (e.g. arraying one top face 3× → 8 cube +
        // 3×4 = 20 verts / 8 faces, matching the reference, instead of the
        // 16 verts a shared seam produced). Whole-mesh arrays have no
        // unselected neighbour to share with, so this is a no-op there and
        // the existing keep+`count-1` path is left untouched (whole-cube
        // array cases stay byte-for-byte exact).
        bool detachSource = detachSubsetSource && (selCount < faces.length);
        if (detachSource) {
            uint[uint] seamMap;
            foreach (fi; sourceFaces) {
                foreach (vid; faces[fi]) {
                    if (vid !in seamMap) {
                        seamMap[vid] = cast(uint)vertices.length;
                        Vec3 p = vertices[vid];   // offset 0 ⇒ same position
                        vertices ~= p;
                    }
                }
            }
            foreach (fi; sourceFaces)
                foreach (k, vid; faces[fi])
                    faces[fi][k] = seamMap[vid];
        }

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
            faceMaterial[idx] = faceAttrOr(faceMaterial, srcFi);
            facePart[idx]     = faceAttrOr(facePart, srcFi);
            selectFace(cast(int)idx);
        }
        // For a detached subset the repointed source faces are copy 0 of the
        // array, so they join the marched copies in the resulting selection
        // (all `count` instances end selected — the source is no longer the
        // shared original, it now owns its duplicated verts).
        if (detachSource) {
            foreach (fi; sourceFaces) selectFace(cast(int)fi);
        }
        resizeVertexSelection();
        clearVertexSelection();
        resizeEdgeSelection();
        clearEdgeSelection();

        // Optional vertex weld — FULL PARITY: the reference editor's linear
        // array KEEPS the doubled coincident seam FACE that a cap-to-cap
        // weld produces (e.g. a 2× cube whose copy's -X face lands exactly
        // on the source's +X face). So we weld coincident VERTS between
        // consecutive copies (via weldCoincidentVertices, which also
        // rebuilds edges + collapses degenerate face corners) and then drop
        // the now-unreferenced welded-away verts with compactUnreferenced —
        // but we deliberately do NOT fingerprint-dedup faces, so the doubled
        // seam face survives (11f → 12f for the 2× cube). This differs from
        // mirrorFaces / arrayFacesGrid, which still dedup coincident faces;
        // this line-array path matches the reference's face count instead.
        if (weld > 0.0f) {
            double epsSq = cast(double)weld * cast(double)weld;
            if (weldCoincidentVertices(epsSq) > 0) {
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
            faceMaterial[idx] = faceAttrOr(faceMaterial, srcFi);
            facePart[idx]     = faceAttrOr(facePart, srcFi);
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
                uint[]   keptWord;   // whole faceMarks word (task 0613 §4.2)
                int[]    keptOrder;
                bool[]   keptSelected;
                uint[]   keptMaterial;
                uint[]   keptPart;
                keptFaces   .reserve(faces.length);
                keptWord    .reserve(faces.length);
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
                    keptWord     ~= faceAttrOr(faceMarks, fi);
                    keptOrder    ~= faceAttrOr(faceSelectionOrder, fi);
                    keptSelected ~= (fi < selectedFaces.length      ? selectedFaces[fi]      : false);
                    keptMaterial ~= faceAttrOr(faceMaterial, fi);
                    keptPart     ~= faceAttrOr(facePart, fi);
                }
                faces              = keptFaces;
                // keptSelected is applied right after via setFacesSelectedFrom,
                // so Select's bit in keptWord is irrelevant either way; drop it
                // here anyway to match every other compaction site's convention.
                setFaceMarksFrom(keptWord, ~Marks.Select);
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
            faceMaterial[newFi] = faceAttrOr(faceMaterial, fi);
            facePart[newFi]     = faceAttrOr(facePart, fi);
            selectFace(cast(int)newFi);
        }

        // Resize selection arrays (verts/edges) to current sizes; both
        // selections are invalidated by the topology changes.
        resizeVertexSelection();
        clearVertexSelection();
        resizeEdgeSelection();
        clearEdgeSelection();

        // Optional weld pass: verts on the mirror plane reflected to
        // themselves are coincident with their originals, as are all verts of
        // a symmetric object mirrored about its own centre plane. weld>0 folds
        // those coincident VERTS (full-parity: faces are NOT deduped — the
        // doubled coincident faces are kept as an opposite-wound shell/membrane;
        // see the convention note at the weld call below).
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

            double epsSq = cast(double)weld * cast(double)weld;
            // Bug B fix: `protectBelow=origVertexCount` keeps this weld
            // LOCAL to the seam — two PRE-EXISTING (pre-mirror) vertices
            // never merge with each other regardless of how large `weld`
            // is; only pairs touching at least one freshly-cloned vertex
            // are eligible. Without this, a large `weld` folds arbitrary
            // far-apart original vertices together across the whole mesh.
            //
            // FULL PARITY (weld coincident-face convention): the weld merges
            // coincident VERTS only — it does NOT fingerprint-dedup faces. When
            // the mirror maps geometry onto itself — a symmetric object
            // mirrored about its own centre plane, or an on-plane seam membrane
            // — the reference editor KEEPS the doubled coincident faces (the
            // original + its winding-reversed clone form an opposite-wound
            // shell / membrane), even though that leaves each shared edge
            // incident to more than two faces: a deliberate non-manifold
            // artifact of Mirror+Merge. So we weld verts, rebuild edges from
            // the (now vertex-merged) faces, and drop only the orphaned
            // welded-away vert slots via compactUnreferenced — the same
            // keep-doubled convention as arrayFaces / radialArrayFaces.
            if (weldCoincidentVertices(epsSq, origVertexCount) > 0) {
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
            faceMaterial[newFi] = faceAttrOr(faceMaterial, fi);
            facePart[newFi]     = faceAttrOr(facePart, fi);
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
    bool hasAnyHiddenVertices() const {
        foreach (m; vertexMarks) if (m & Marks.Hide) return true;
        return false;
    }
    bool hasAnyHiddenEdges() const {
        foreach (m; edgeMarks) if (m & Marks.Hide) return true;
        return false;
    }
    bool hasAnyHiddenFaces() const {
        foreach (m; faceMarks) if (m & Marks.Hide) return true;
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
    /// L1 funnel (doc/hide_geometry_plan.md §3.2) — the single home the "empty
    /// selection ⇒ whole mesh" convention collapses into once hidden geometry
    /// exists. NOT wired into any caller yet (that is Stage 1/3 work); added
    /// now so the derivation law and the fallback subtraction live in one
    /// place from the start.
    ///
    /// Returns the vertices touched by `mode`'s current selection — vertex
    /// selection directly, or the vertices touched by the selected edges /
    /// faces, exactly the modal fan-in every open-coded copy of this idiom
    /// already performs (smooth/quantize/jitter/magnet/the align family, and
    /// the three `selectedVertexIndices{Vertices,Edges,Faces}` accessors).
    /// When `mode` has no selection, returns every VISIBLE vertex instead of
    /// every vertex. A real selection can never contain a hidden element
    /// (§3.1's `Select ∧ Hide = ∅` invariant, enforced in the select*
    /// writers below), so only the fallback branch needs the subtraction.
    bool[] operandVertexMask(EditMode mode) const {
        auto vmask = new bool[](vertices.length);
        bool any = false;
        // Bound every scan loop by vmask.length (== vertices.length), not by
        // the marks array's own length (code review, task 0613): the marks
        // arrays only grow-and-keep, so clearing the mesh (Mesh.clear())
        // empties vertices/edges/faces without shrinking vertexMarks /
        // edgeMarks / faceMarks — a loop bound by the (now stale, longer)
        // marks length would write vmask[i] out of range.
        final switch (mode) {
            case EditMode.Vertices:
                foreach (i; 0 .. vertexMarks.length) {
                    if (i >= vmask.length) break;
                    if (isVertexSelected(i)) { vmask[i] = true; any = true; }
                }
                break;
            case EditMode.Edges:
                foreach (i; 0 .. edgeMarks.length) {
                    if (i >= edges.length) break;
                    if (isEdgeSelected(i))
                        foreach (vi; edges[i]) if (vi < vmask.length) { vmask[vi] = true; any = true; }
                }
                break;
            case EditMode.Polygons:
                foreach (i; 0 .. faceMarks.length) {
                    if (i >= faces.length) break;
                    if (isFaceSelected(i))
                        foreach (vi; faces[i]) if (vi < vmask.length) { vmask[vi] = true; any = true; }
                }
                break;
        }
        if (!any) vmask = visibleVertexMask();
        return vmask;
    }
    // The fallback branch of the L1 funnel, factored out so "the whole mesh
    // means the VISIBLE mesh" has exactly one body per plane (task 0613, S5).
    //
    // Called directly by the handful of whole-mesh fallbacks whose gate is NOT
    // the plain `nothingSelected(mode)` convention and so CANNOT be routed
    // through operand*Mask without a behaviour change — the four
    // mode-gated face commands (`triple`, `quadruple`, `detriangulate`,
    // `subdivide_faceted`) fall back to the whole mesh when the active mode is
    // not Polygons EVEN IF a face selection exists. Substituting
    // operandFaceMask() there would make them start honouring that stale face
    // selection, which is a real semantic change wearing a refactor's clothes.
    // They get the hide subtraction; they keep their own gate.
    bool[] visibleVertexMask() const {
        auto m = new bool[](vertices.length);
        foreach (i; 0 .. vertices.length) if (!isVertexHidden(i)) m[i] = true;
        return m;
    }
    bool[] visibleEdgeMask() const {
        auto m = new bool[](edges.length);
        foreach (i; 0 .. edges.length) if (!isEdgeHidden(i)) m[i] = true;
        return m;
    }
    bool[] visibleFaceMask() const {
        auto m = new bool[](faces.length);
        foreach (i; 0 .. faces.length) if (!isFaceHidden(i)) m[i] = true;
        return m;
    }
    /// L1 funnel, edge plane: the selected edges when any are selected, else
    /// every VISIBLE edge. No modal fan-in — the edge-flavoured copies of
    /// this idiom always key off the edge selection itself.
    bool[] operandEdgeMask() const {
        auto emask = new bool[](edges.length);
        bool any = false;
        // Bound by emask.length, not edgeMarks.length — same stale-marks-
        // after-clear() hazard as operandVertexMask above.
        foreach (i; 0 .. edgeMarks.length) {
            if (i >= emask.length) break;
            if (isEdgeSelected(i)) { emask[i] = true; any = true; }
        }
        if (!any) emask = visibleEdgeMask();
        return emask;
    }
    /// L1 funnel, face plane: the selected faces when any are selected, else
    /// every VISIBLE face (shapes B/C's face-flavoured fallback).
    bool[] operandFaceMask() const {
        auto fmask = new bool[](faces.length);
        bool any = false;
        // Bound by fmask.length, not faceMarks.length — same stale-marks-
        // after-clear() hazard as operandVertexMask above.
        foreach (i; 0 .. faceMarks.length) {
            if (i >= fmask.length) break;
            if (isFaceSelected(i)) { fmask[i] = true; any = true; }
        }
        if (!any) fmask = visibleFaceMask();
        return fmask;
    }
    // --- §3.3 backstop: the mask-taking kernels subtract hidden themselves --
    // L1 (operand*Mask) closes the "empty selection ⇒ whole mesh" fallback at
    // the point the operand set is BUILT. L3's substitution of the 25
    // open-coded builders is mechanical, not compiler-enforced, so these three
    // close the same hole at the point the operand set is CONSUMED: every
    // `*ByMask` kernel funnels its incoming mask through the matching one
    // before it does anything. A hand-built mask that reached a hidden element
    // — through an L3 miss, or through a caller nobody has written yet — still
    // cannot act on it.
    //
    // Returns the caller's own slice UNCHANGED when nothing on that plane is
    // hidden, which is the overwhelmingly common case (and every existing
    // unittest): no allocation, no copy, so 25 kernels pay one popcount-free
    // word scan each. Only a mesh that genuinely has hidden geometry pays a
    // `.dup`.
    //
    // NOT private: these are reached from the kernel bodies in
    // `mesh_ops/{extrude,bevel}.d`, which are mixin templates whose bodies are
    // analysed in THEIR module, so D's module-scoped `private` would hide them.
    const(bool)[] maskMinusHiddenVertices(const(bool)[] mask) const {
        if (!hasAnyHiddenVertices()) return mask;
        auto outMask = mask.dup;
        foreach (i; 0 .. outMask.length) if (isVertexHidden(i)) outMask[i] = false;
        return outMask;
    }
    const(bool)[] maskMinusHiddenEdges(const(bool)[] mask) const {
        if (!hasAnyHiddenEdges()) return mask;
        auto outMask = mask.dup;
        foreach (i; 0 .. outMask.length) if (isEdgeHidden(i)) outMask[i] = false;
        return outMask;
    }
    const(bool)[] maskMinusHiddenFaces(const(bool)[] mask) const {
        if (!hasAnyHiddenFaces()) return mask;
        auto outMask = mask.dup;
        foreach (i; 0 .. outMask.length) if (isFaceHidden(i)) outMask[i] = false;
        return outMask;
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

    // --- Hide writers (Marks.Hide, task 0613) — authoritative plane only ---
    //
    // THE topologyVersion BUMP, and why all three writers below carry it (S3).
    // Hide is a Marks-class flip, so `commitChange(Marks)` alone would leave
    // topologyVersion alone. That is wrong for the same reason it is wrong for
    // Subpatch (setSubpatch / clearSubpatch above keep an explicit bump), and
    // the reason is NOT the limit surface — R5 still holds, the OSD *input* is
    // untouched and the subdivided positions do not move. It is that
    // topologyVersion is what two consumers use as the preview + GPU LAYOUT
    // key, and a hide changes the layout:
    //
    //   * SubpatchPreview.rebuildIfStale (mesh.d) takes its position-only fast
    //     path whenever `sourceTopologyVersion == source.topologyVersion`. That
    //     path re-evaluates positions and NEVER re-runs buildPreview, so the
    //     preview mesh's Hide marks (stamped from the cage in subpatch_osd.d)
    //     would stay at their pre-hide values for as long as the preview lives.
    //   * app.d's upload block picks refreshPositions over a full gpu.upload on
    //     `gpuUploadedPreviewTopVersion == subpatchPreview.sourceTopologyVersion`.
    //     refreshPositions cannot change a buffer's SIZE — only a full upload
    //     re-derives faceTriCount / edgeVertCount / vertCount under the new
    //     skip predicate.
    //
    // So without the bump, hiding a face while the subpatch preview is live is
    // a no-op on screen. With it, both consumers rebuild exactly as they do for
    // a Tab toggle. Guarded on an actual bit flip in every writer, so a
    // no-op hide still costs nothing.
    //
    // Single-index face write, same shape as setSubpatch above.
    void setFaceHidden(size_t idx, bool on) {
        if (idx >= faceMarks.length) return;
        bool cur = (faceMarks[idx] & Marks.Hide) != 0;
        if (cur != on) {
            if (on) {
                faceMarks[idx] |= Marks.Hide;
                // §3.1 Select ∧ Hide = ∅ (BLOCKER, code review task 0613) —
                // this writer sets the Hide bit directly, not through
                // refreshHiddenDerived(), so it owes the invariant too: a
                // face that just became hidden cannot stay selected. Same
                // word write, order stamp zeroed alongside, bus note only if
                // it actually flipped.
                if (faceMarks[idx] & Marks.Select) {
                    faceMarks[idx] &= ~Marks.Select;
                    if (idx < faceSelectionOrder.length) faceSelectionOrder[idx] = 0;
                    noteSelectionChange(SelDomain.Face);
                }
            } else {
                faceMarks[idx] &= ~Marks.Hide;
            }
            commitChange(MeshEditScope.Marks | MeshEditScope.Visibility);
            ++topologyVersion;   // preview + GPU layout key — see the header above
            // S5 (code review) — a Marks-class commit does not reach
            // refreshHiddenDerived (commitChange only calls it for a
            // Geometry-class commit, above), so the derived vertex/edge
            // planes would otherwise read stale between this hide and the
            // next geometry-mutating commit. Its own early-out keeps this
            // free when nothing is hidden anywhere.
            refreshHiddenDerived();
        }
    }
    // True iff vertex `vi` is referenced by at least one face. O(1): the
    // same vertLoop-based "isolated vertex" test the fan-walk accessors
    // above (verticesAroundVertex / edgesAroundVertex / facesAroundVertex)
    // already rely on — vertLoop[vi] == ~0u means no dart starts at vi, i.e.
    // no incident face-corner, after buildLoops(); out-of-range reads the
    // same "no loop" answer, which is also the right answer for a vertex
    // added since the last build (code review, task 0613: was an O(faces ×
    // corners) scan — this replaces it, not merely a second copy).
    private bool hasIncidentFace(size_t vi) const {
        return vi < vertLoop.length && vertLoop[vi] != ~0u;
    }
    // Loose points ONLY. A vertex with at least one incident face has its
    // Hide bit fully DERIVED by refreshHiddenDerived() — offering a writer
    // for that case would let a caller fight the derivation and reintroduce
    // exactly the derived-from-polygons mistake the capture refuted (§1.2).
    // Returns whether the write landed (code review, task 0613: a debug
    // assert here crashed an ordinary developer build on a legal user
    // action — hiding a loose vertex in a mesh that also has face-bound
    // vertices — while release silently dropped it; `hasIncidentFace` is
    // private, so the caller had no way to test the precondition itself).
    // Same silent-refusal contract in both builds now: false means "this
    // vertex has a face — its Hide bit is derived, not directly settable".
    bool setVertexHidden(size_t idx, bool on) {
        if (idx >= vertexMarks.length) return false;
        if (hasIncidentFace(idx)) return false;
        bool cur = (vertexMarks[idx] & Marks.Hide) != 0;
        if (cur != on) {
            if (on) {
                vertexMarks[idx] |=  Marks.Hide;
                // §3.1 Select ∧ Hide = ∅ — owed by EVERY writer of the Hide
                // plane, this one included (task 0628). It was missing here
                // and inert while nothing in production ever set a loose
                // point's bit: refreshHiddenDerived() upholds the invariant
                // for face-bound vertices, but it steps OVER loose points by
                // design, so this writer is the only place that can uphold it
                // for them. mesh.hideInvert in Vertices/Edges mode is the
                // first production caller that sets the bit — a selected
                // loose point that the invert hides would otherwise end up
                // both selected and hidden, with no derivation anywhere able
                // to heal it. Same shape as setFaceHidden above: cleared in
                // the SAME word write, order stamp zeroed alongside, bus note
                // only if it actually flipped.
                if (vertexMarks[idx] & Marks.Select) {
                    vertexMarks[idx] &= ~Marks.Select;
                    if (idx < vertexSelectionOrder.length) vertexSelectionOrder[idx] = 0;
                    noteSelectionChange(SelDomain.Vertex);
                }
            } else {
                vertexMarks[idx] &= ~Marks.Hide;
            }
            commitChange(MeshEditScope.Marks);
        }
        return true;
    }
    // Masked clear, same shape as clearSubpatch: `&= ~Marks.Hide`, never
    // `= 0` (Select and Subpatch share these words).
    //
    // Scope is EVERY plane, not just the authoritative face one. Stage 0
    // left the loose-vertex half of this open — a vertex with no incident
    // face has a settable Hide bit that refreshHiddenDerived deliberately
    // steps over, so no derivation can ever clear it — and deferred the call
    // to Stage 2. Stage 2 has now made it (see commands/mesh/hide.d,
    // MeshUnhideAll): an unhide clears loose bits too, because this is the
    // only writer that could, and a bit nothing can clear is a one-way trap.
    // So this clears the face plane AND the vertex plane directly. The
    // face-bound half of the vertex plane is redundant with the refresh
    // below (no face hidden ⇒ no face-bound vertex hidden), which is fine:
    // one masked pass is cheaper than deciding per vertex which half it is
    // in, and the answer is the same either way.
    void clearHidden() {
        uint anyHide = 0;
        foreach (w; faceMarks)   anyHide |= w;
        foreach (w; vertexMarks) anyHide |= w;
        foreach (w; edgeMarks)   anyHide |= w;
        if (!(anyHide & Marks.Hide)) return;   // nothing hidden anywhere
        foreach (ref m; faceMarks)   m &= ~Marks.Hide;
        foreach (ref m; vertexMarks) m &= ~Marks.Hide;
        foreach (ref m; edgeMarks)   m &= ~Marks.Hide;
        commitChange(MeshEditScope.Marks | MeshEditScope.Visibility);
        ++topologyVersion;   // preview + GPU layout key — see the header above
                             // setFaceHidden. Reached only past the early-out,
                             // i.e. only when something really was hidden.
        // S5 (code review) — same reasoning as setFaceHidden above: a
        // Marks-only commit never reaches refreshHiddenDerived, so an unhide
        // must call it directly or the derived vertex/edge planes stay
        // hidden until the next geometry-mutating commit. With all three
        // planes masked above this call now early-outs by construction; it
        // stays because it is the funnel that OWNS the derived planes — a
        // plane added later is the refresh's job to recompute, not this
        // function's job to remember to mask. Clearing can only ever DROP
        // Hide bits, never set one, so there is no new Select ∧ Hide
        // collision for it to fix either way.
        refreshHiddenDerived();
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

    // Single-index HIDE write in the same raw shape as setFaceSubpatch above:
    // bounds-guarded, no commitChange, no version bump, NO refreshHiddenDerived
    // — deliberately, because it exists for one caller shape, the bulk
    // face-plane stamps in subpatch_osd.d (task 0613 S3), which write every
    // face of a freshly built preview and then call refreshHiddenDerived()
    // ONCE. Routing those through the user-facing `setFaceHidden` instead would
    // pay a commitChange + a full O(V+E+F) derivation PER FACE, i.e. O(F²) on a
    // 400 K-face preview.
    //
    // Both branches are written, never a bare `|=`: the preview mesh is a
    // long-lived reused struct whose faceMarks survive a rebuild, so a
    // set-only stamp would leave a previously-hidden face hidden forever.
    //
    // NOT a general-purpose hide writer. Anything user-facing wants
    // setFaceHidden / setFaceHiddenFrom, which own the Select ∧ Hide = ∅
    // invariant, the change publish and the layout-key bump.
    void setFaceHiddenBit(size_t fi, bool flag) {
        if (fi >= faceMarks.length) return;
        if (flag) faceMarks[fi] |=  Marks.Hide;
        else      faceMarks[fi] &= ~Marks.Hide;
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
    // Grow-before-index: the order array must reach src.length before the
    // loop below can write to it, or a shorter order array (e.g. right
    // after a geometry-growing op that hasn't synced order yet) would
    // RangeError. Growing never shrinks, so trailing order[i >= old
    // length] entries default to 0 (int.init) — consistent with "not
    // manually selected". If a future caller ever passes a SHORTER src
    // than the current order array, the extra trailing order[i >=
    // src.length] slots are simply left untouched (harmless stale data,
    // matching the array's pre-existing grow-only behavior elsewhere).
    private void applySelectedFrom_(ref uint[] marks, ref int[] order, const bool[] src, SelDomain dom) {
        bool changed = (marks.length != src.length);
        marks.length = src.length;
        if (order.length < src.length)
            order.length = src.length;
        foreach (i, s; src) {
            // Invariant (doc/hide_geometry_plan.md §3.1): Select ∧ Hide = ∅,
            // enforced in the WRITER so it holds for every caller — including
            // undo/redo snapshot replay, which is exactly the path a
            // per-caller guard would miss. A hidden element simply cannot be
            // asked to select; it is not an error, it is a silent refusal.
            const bool want = s && (marks[i] & Marks.Hide) == 0;
            const cur = (marks[i] & Marks.Select) != 0;
            if (cur != want) changed = true;
            if (want) marks[i] |=  Marks.Select;
            else { marks[i] &= ~Marks.Select; order[i] = 0; }
        }
        if (changed) noteSelectionChange(dom);
    }
    void setVerticesSelectedFrom(const bool[] src) {
        applySelectedFrom_(vertexMarks, vertexSelectionOrder, src, SelDomain.Vertex);
    }
    void setEdgesSelectedFrom(const bool[] src) {
        applySelectedFrom_(edgeMarks, edgeSelectionOrder, src, SelDomain.Edge);
    }
    void setFacesSelectedFrom(const bool[] src) {
        // Resize once, then touch ONLY the Select bit so this stays
        // order-independent with setFaceMarksFrom (B4 — snapshot restore
        // writes Select and Subpatch/Hide as two separate assigns). Resizing
        // preserves the other bits of any pre-existing entries.
        applySelectedFrom_(faceMarks, faceSelectionOrder, src, SelDomain.Face);
    }
    // RETIRED (task 0613, Stage 1 — doc/hide_geometry_plan.md §4.2): this used
    // to be `setFaceSubpatchFrom(const bool[] src)`, a masked single-bit
    // writer. Every one of its ~13 call sites resized `faceMarks` to a NEW
    // (usually shorter, always re-indexed) length and then patched in ONLY
    // the Subpatch bit — leaving whatever raw word already sat at the new
    // index (D array-shrink does not clear truncated tail slots, and a
    // compaction's "new index i" is generally a DIFFERENT face than "old
    // index i"). Select survived that unnoticed because every compaction site
    // separately force-clears it afterward (`clearFaceSelectionResize` /
    // `setFacesSelectedFrom`); Hide has no such second pass, so it would have
    // silently MOVED onto whichever face slides into a deleted face's slot —
    // documented in-place at `deleteFacesByMask` below before this fix.
    // `setFaceMarksFrom` replaces it: the caller supplies the FULL new word
    // per new index (typically the old face's whole `faceMarks` entry,
    // captured in the same walk that used to capture just `isFaceSubpatch`),
    // and `keepMask` says which of ITS bits survive — `~Marks.Select` at
    // every compaction/wipe site (Select is still dropped, byte-identical to
    // today), `uint.max` at a same-length restore that must preserve
    // everything not explicitly overwritten by the caller. Raw (no
    // commitChange), same "bulk/internal writer, caller commits" contract
    // setFaceSubpatchFrom had.
    void setFaceMarksFrom(const uint[] src, uint keepMask) {
        faceMarks.length = src.length;
        foreach (i, w; src) faceMarks[i] = w & keepMask;
    }
    unittest { // setFaceMarksFrom mask contract (code review NIT, task
        // 0613): pin BOTH halves directly on the primitive, unmediated by
        // any caller's OWN Select backstop. Every production call site
        // (deleteFacesByMask's clearFaceSelectionResize, loop-slice's
        // resetSelection, etc.) clears or restores Select unconditionally
        // right afterward, so a keepMask regression AT THE CALL SITE is
        // invisible from the outside — only a direct test of the primitive
        // itself can discriminate it.
        Mesh m;
        m.setFaceMarksFrom([Marks.Select | Marks.Hide, Marks.Subpatch], ~Marks.Select);
        assert(m.faceMarks[0] == Marks.Hide,
            "setFaceMarksFrom: keepMask must drop the Select bit — a slip "
            ~ "to uint.max would let it survive");
        assert(m.faceMarks[1] == Marks.Subpatch,
            "setFaceMarksFrom: keepMask must NOT drop bits outside itself — "
            ~ "a slip to 0 (or to ~uint.max) would silently wipe "
            ~ "Subpatch/Hide too");
    }
    // Bulk face-plane write, same shape as setFaceMarksFrom above (raw —
    // no commitChange, used by bulk/internal writers; a user-facing bulk
    // hide command calls this then refreshHiddenDerived() itself, exactly
    // the two-step S2 will use). Resize once, touch ONLY the Hide bit, so
    // this stays order-independent with setFacesSelectedFrom /
    // setFaceMarksFrom (all three share the same word).
    void setFaceHiddenFrom(const bool[] src) {
        faceMarks.length = src.length;
        // §3.1 Select ∧ Hide = ∅ (BLOCKER, code review task 0613) — same
        // invariant as the scalar setFaceHidden above, owed by every writer
        // of the Hide plane, not only the single-index one. Raw shape (no
        // commitChange — the caller does that, same as setFaceMarksFrom),
        // but a Select-domain change is still noted here if one happens, so
        // it is never silently lost regardless of what the caller does next.
        bool selChanged  = false;
        bool hideChanged = false;
        foreach (i, s; src) {
            immutable bool cur = (faceMarks[i] & Marks.Hide) != 0;
            if (cur != s) hideChanged = true;
            if (s) {
                faceMarks[i] |= Marks.Hide;
                if (faceMarks[i] & Marks.Select) {
                    faceMarks[i] &= ~Marks.Select;
                    if (i < faceSelectionOrder.length) faceSelectionOrder[i] = 0;
                    selChanged = true;
                }
            } else {
                faceMarks[i] &= ~Marks.Hide;
            }
        }
        if (selChanged) noteSelectionChange(SelDomain.Face);
        // Two obligations of a Hide-plane write, both parked HERE in the
        // writer rather than in the four hide commands — a raw
        // topologyVersion bump and a bare noteChange are both orthogonal to
        // commitChange (mesh_edit_delta.d does the same), so keeping them with
        // the plane's writer means a fifth command cannot forget one and ship
        // a hide that does nothing on screen:
        //
        //   * ++topologyVersion — the preview + GPU LAYOUT key. See the header
        //     above setFaceHidden.
        //   * noteChange(Visibility) — the DISPLAY-REFRESH class. The caller's
        //     commitChange(Marks) ORs into the same pending set, and Marks is
        //     deliberately NOT in display_sync.DisplayRefreshMask (it would
        //     re-upload on every selection click), so a hide published as
        //     Marks alone never reaches app.d's bus-driven cage upload and
        //     never reaches the screen. MEASURED, not reasoned: with the
        //     Marks-only publish, hiding a cube face left /api/gpu/face-vbo's
        //     faceVertCount at 36.
        if (hideChanged) {
            noteChange(MeshEditScope.Visibility);
            ++topologyVersion;
        }
    }

    // --- The derivation (doc/hide_geometry_plan.md §1.2) --------------------
    // Recompute the DERIVED hidden planes (vertexMarks / edgeMarks) from the
    // AUTHORITATIVE one (faceMarks) — the measured law:
    //   * a vertex is hidden iff it has >= 1 incident face and EVERY one of
    //     them is hidden (a loose vertex — no incident face — keeps its own
    //     settable bit, untouched here — see setVertexHidden above);
    //   * an edge is hidden iff AT LEAST ONE endpoint vertex is hidden —
    //     derived from VERTICES, not polygons (measured: two adjacent hidden
    //     polygons do NOT hide the edge they share, because both endpoints
    //     still touch a third, visible face — T-S0a's discriminator).
    //
    // Self-guarding and deliberately owns NO cached field (REV2/objection 5
    // — a `hiddenFaceCount_`-style counter has no snapshot-restore path: a
    // wholesale `faceMarks = faceMarks.dup` + commitChange bypasses any
    // writer-maintained counter, so undo/redo INTO a hidden state would skip
    // the refresh while `faceMarks` says otherwise). Instead: a three-plane
    // word-OR computed fresh from the arrays about to be read. A mesh with
    // nothing hidden anywhere — the overwhelmingly common case — pays three
    // tight scans (one load + one OR per element, no branch, no allocation)
    // and returns.
    //
    // Called from every geometry-mutating commitChange (mesh.d, the single
    // geometry-mutation funnel — see commitChange() below), so a topology
    // edit can never leave these planes stale; also called directly by the
    // hide commands (Stage 2) right after they write the face plane, and by
    // setFaceHidden/clearHidden above (S5 — a Marks-only commit does not
    // reach here through commitChange, so those two call it explicitly).
    //
    // Reused scratch buffers (S6 — code review, task 0613): grow-only,
    // mirroring mesh_gpu.d's upload() scratch pattern, so a mesh of stable
    // size pays the allocation only the first time it grows, not on every
    // call — this matters because this function is reachable from an
    // interactive drag (a preview tool restores a snapshot and re-runs its
    // kernel per mouse-move, both of which commit geometry). Confirmed
    // unreachable from any per-frame draw/pick path — those commit a
    // Position-only scope, which carries no Geometry class and never reaches
    // commitChange's refreshHiddenDerived() call.
    private bool[] hiddenDerivedHasFaceScratch_;
    private bool[] hiddenDerivedAllHiddenScratch_;

    void refreshHiddenDerived() {
        uint anyHide = 0;
        foreach (w; faceMarks)   anyHide |= w;
        foreach (w; vertexMarks) anyHide |= w;
        foreach (w; edgeMarks)   anyHide |= w;
        if (!(anyHide & Marks.Hide)) return;   // nothing hidden anywhere ⇒ nothing to derive

        if (hiddenDerivedHasFaceScratch_.length < vertexMarks.length)
            hiddenDerivedHasFaceScratch_.length = vertexMarks.length;
        if (hiddenDerivedAllHiddenScratch_.length < vertexMarks.length)
            hiddenDerivedAllHiddenScratch_.length = vertexMarks.length;
        auto hasFace   = hiddenDerivedHasFaceScratch_[0 .. vertexMarks.length];
        auto allHidden = hiddenDerivedAllHiddenScratch_[0 .. vertexMarks.length];
        hasFace[]   = false;  // reused buffer: a prior call's data must not leak in
        allHidden[] = true;   // AND-reduced below; a vertex with no incident
                               // face never flips this, so hasFace gates it.

        foreach (fi, face; faces) {
            const bool faceHidden = fi < faceMarks.length && (faceMarks[fi] & Marks.Hide) != 0;
            foreach (vi; face) {
                if (vi >= hasFace.length) continue;   // transient desync (mid-grow) — self-heals next refresh
                hasFace[vi] = true;
                if (!faceHidden) allHidden[vi] = false;
            }
        }

        // §3.1 Select ∧ Hide = ∅ — this derivation is ITSELF a Hide writer
        // (BLOCKER, code review task 0613): a vertex/edge that transitions to
        // hidden here cannot stay selected, or the invariant is breakable
        // with Stage 0 code alone — select a vertex, hide the faces around
        // it, let this funnel run, and (before this fix) it ends up both
        // selected and hidden, with no hide COMMAND anywhere in the call
        // stack for a later stage to guard. Cleared in the SAME word write
        // that sets Hide; the order stamp is zeroed alongside (a stale
        // nonzero order on a non-selected element is the corruption fixed
        // elsewhere in this stage); the selection-change bus note fires only
        // if something actually flipped.
        bool vertSelChanged = false;
        foreach (vi; 0 .. vertexMarks.length) {
            if (!hasFace[vi]) continue;   // loose point: own bit stays, untouched
            if (allHidden[vi]) {
                if (vertexMarks[vi] & Marks.Select) {
                    vertexMarks[vi] &= ~Marks.Select;
                    if (vi < vertexSelectionOrder.length) vertexSelectionOrder[vi] = 0;
                    vertSelChanged = true;
                }
                vertexMarks[vi] |= Marks.Hide;
            } else {
                vertexMarks[vi] &= ~Marks.Hide;
            }
        }
        if (vertSelChanged) noteSelectionChange(SelDomain.Vertex);

        bool edgeSelChanged = false;
        foreach (ei; 0 .. edgeMarks.length) {
            if (ei >= edges.length) continue;
            const e = edges[ei];
            const bool hidden =
                (e[0] < vertexMarks.length && (vertexMarks[e[0]] & Marks.Hide) != 0) ||
                (e[1] < vertexMarks.length && (vertexMarks[e[1]] & Marks.Hide) != 0);
            if (hidden) {
                if (edgeMarks[ei] & Marks.Select) {
                    edgeMarks[ei] &= ~Marks.Select;
                    if (ei < edgeSelectionOrder.length) edgeSelectionOrder[ei] = 0;
                    edgeSelChanged = true;
                }
                edgeMarks[ei] |= Marks.Hide;
            } else {
                edgeMarks[ei] &= ~Marks.Hide;
            }
        }
        if (edgeSelChanged) noteSelectionChange(SelDomain.Edge);
    }

    // === Tests: the measured hide/derivation law (doc/hide_geometry_plan.md
    // §1.2/§5, Stage 0's own T-S0a/b/c/d — each case is chosen so a WRONG
    // law reads a DIFFERENT number, not merely "nothing happened", per the
    // plan's own testing gate, §7). makeCube()'s faces (defined further down
    // this module): f0=[0,3,2,1], f1=[4,5,6,7], f2=[0,4,7,3], f3=[1,2,6,5],
    // f4=[3,7,6,2], f5=[0,1,5,4] — so vertex 0's three incident faces are
    // exactly {f0, f2, f5}.
    unittest { // T-S0a — the edge rule derives from VERTICES, not polygons
        auto m = makeCube();
        m.syncSelection();   // makeCube() does not size the marks arrays itself
        // f0 and f2 share edge (0,3). Hiding both is exactly the case the
        // plan's pre-capture "conservative" guess got wrong: a
        // derived-FROM-POLYGONS rule would hide edge (0,3), because both of
        // its incident faces are hidden. The measured rule does not,
        // because vertex 0 still touches f5 and vertex 3 still touches f4,
        // and NEITHER of those is hidden.
        m.setFaceHidden(0, true);
        m.setFaceHidden(2, true);
        m.refreshHiddenDerived();
        const uint e03 = m.edgeIndex(0, 3);
        assert(e03 != ~0u, "cube must have an edge (0,3)");
        assert(!m.isEdgeHidden(e03),
            "edge (0,3) must stay visible — both endpoints still touch a third, visible face");
        // The discriminator only means something if f0/f2 really are edge
        // (0,3)'s ONLY incident faces (not merely that f0/f2 themselves are
        // hidden, which says nothing about which edge they border) — confirm
        // the incidence itself, via facesAroundEdge, or a stray third
        // incident face (visible or not) would make this assertion pass for
        // the wrong reason (code review, task 0613).
        uint[] incident;
        foreach (fi; m.facesAroundEdge(e03)) incident ~= fi;
        import std.algorithm.sorting : sort;
        incident.sort();
        assert(incident == [0u, 2u], "edge (0,3)'s incident faces must be exactly {f0, f2}");
        assert(m.isFaceHidden(0) && m.isFaceHidden(2));
    }
    unittest { // T-S0b — the vertex rule is ALL-incident, not ANY
        auto m = makeCube();
        m.syncSelection();   // makeCube() does not size the marks arrays itself
        // (i) hide two ADJACENT faces (f0, f2 — share vertices 0 and 3): an
        // ANY-incident rule would read 6 hidden vertices (4 + 4 - 2
        // shared); the measured ALL-incident rule reads 0, because every
        // vertex of f0/f2 still touches a third, visible face.
        m.setFaceHidden(0, true);
        m.setFaceHidden(2, true);
        m.refreshHiddenDerived();
        foreach (vi; 0 .. m.vertices.length)
            assert(!m.isVertexHidden(vi),
                "two adjacent hidden faces must hide ZERO vertices (ALL-incident, not ANY)");

        // (ii) hide the THIRD face meeting vertex 0 (f0, f2, f5 are exactly
        // vertex 0's incident faces) — vertex 0 must become hidden, and it
        // must be the ONLY one: no other vertex has all of ITS incident
        // faces hidden yet.
        m.setFaceHidden(5, true);
        m.refreshHiddenDerived();
        assert(m.isVertexHidden(0), "vertex 0's incident faces (f0, f2, f5) are all hidden now");
        foreach (vi; 1 .. m.vertices.length)
            assert(!m.isVertexHidden(vi), "no OTHER vertex has all of its incident faces hidden yet");
    }
    unittest { // T-S0c — the two per-component cases that pin the model
        // (i) A lone quad: hiding its only polygon hides all 4 of its
        // vertices AND all 4 of its edges. A purely-stored implementation
        // (no vertex/edge derivation at all) fails this half.
        {
            Mesh m;
            m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
            m.addFace([0, 1, 2, 3]);
            m.buildLoops();
            m.syncSelection();
            m.setFaceHidden(0, true);
            m.refreshHiddenDerived();
            foreach (vi; 0 .. 4)
                assert(m.isVertexHidden(vi), "the quad's only face is hidden — every vertex must derive hidden");
            foreach (ei; 0 .. m.edges.length)
                assert(m.isEdgeHidden(ei), "the quad's only face is hidden — every edge must derive hidden");
        }
        // (ii) A loose vertex (no incident face): hiding EVERY polygon in
        // the mesh must NOT touch it — it keeps its own, independently
        // settable bit. A purely-derived implementation (no own-bit
        // concept) fails this half.
        {
            auto m = makeCube();
            const uint loose = m.addVertex(Vec3(10, 10, 10));
            m.syncSelection();   // grow vertexMarks to include the new vertex
            foreach (fi; 0 .. m.faces.length) m.setFaceHidden(fi, true);
            m.refreshHiddenDerived();
            foreach (vi; 0 .. 8)
                assert(m.isVertexHidden(vi), "every cube vertex's incident faces are all hidden");
            assert(!m.isVertexHidden(loose),
                "a loose vertex has no incident face — a polygon hide must not touch it");
            m.setVertexHidden(loose, true);
            assert(m.isVertexHidden(loose), "a loose vertex's own bit is directly settable");
            m.refreshHiddenDerived();   // must NOT clear the own bit — hasFace[loose] is false
            assert(m.isVertexHidden(loose), "refreshHiddenDerived must not touch a loose vertex's own bit");
        }
        // (iii) §3.1 Select ∧ Hide = ∅ on the LOOSE half (task 0628).
        // refreshHiddenDerived upholds the invariant for face-bound vertices
        // and steps OVER loose points by design, so `setVertexHidden` is the
        // only place that can uphold it for them. mesh.hideInvert in
        // Vertices/Edges mode is the first production caller that sets a
        // loose point's bit, and a selected loose point it hides would
        // otherwise stay both selected and hidden with nothing able to heal
        // it. The order STAMP is asserted alongside the Select bit: a fix
        // that dropped Select but left the stamp leaves "selected with order
        // 0" state that every order-consuming command silently ignores.
        {
            auto m = makeCube();
            const uint loose = m.addVertex(Vec3(10, 10, 10));
            m.syncSelection();
            m.selectVertex(cast(int)loose);
            assert(m.isVertexSelected(loose), "premise: the loose point is selected");
            assert(m.vertexSelectionOrder[loose] != 0,
                   "premise: a selected element carries a nonzero order stamp");
            m.setVertexHidden(loose, true);
            assert(m.isVertexHidden(loose), "the loose point's own bit is settable");
            assert(!m.isVertexSelected(loose),
                   "Select ∧ Hide = ∅: a loose point that just became hidden "
                   ~ "cannot stay selected — refreshHiddenDerived steps over "
                   ~ "loose points, so nothing downstream would ever fix it");
            assert(m.vertexSelectionOrder[loose] == 0,
                   "the order stamp must be zeroed in the same write as the "
                   ~ "Select bit; a live stamp on a non-selected element is "
                   ~ "exactly the corruption the stamps exist to prevent");
            // The reverse direction must NOT invent a selection: un-hiding
            // restores visibility only.
            m.setVertexHidden(loose, false);
            assert(!m.isVertexHidden(loose) && !m.isVertexSelected(loose),
                   "un-hiding a loose point restores visibility, not selection");
        }
    }
    unittest { // S4 — the three hidden popcounts the "N hidden" readout reads
        // (R9). One fixture, chosen so the three planes carry THREE DIFFERENT
        // numbers: a cube with all three faces around vertex 0 hidden.
        //
        //   faces    3 — the ones hidden
        //   vertices 1 — only v0 has ALL of its incident faces hidden
        //   edges    3 — every edge with v0 as an endpoint
        //
        // The distinctness is the assertion. A readout wired to
        // countHiddenFaces three times reads 3/3/3; one that returns the
        // whole plane length reads 6/8/12; one that swaps the derived planes
        // reads 3/3/1. All three differ from 3/1/3, and none of them would
        // differ from it on a fixture where the counts happened to coincide
        // (e.g. a lone quad, where all three are 1/4/4 — still fine — but a
        // cube with ONE face hidden reads 1/0/0 and cannot separate a
        // vert/edge swap at all).
        auto m = makeCube();
        m.syncSelection();
        uint[] around;
        foreach (fi; m.facesAroundVertex(0)) around ~= fi;
        assert(around.length == 3, "a cube corner touches exactly three faces");
        foreach (fi; around) m.setFaceHidden(fi, true);
        m.refreshHiddenDerived();
        import std.conv : to;
        assert(m.countHiddenFaces()    == 3,
            "three faces hidden, got " ~ m.countHiddenFaces().to!string);
        assert(m.countHiddenVertices() == 1,
            "exactly the corner derives hidden, got " ~ m.countHiddenVertices().to!string);
        assert(m.countHiddenEdges()    == 3,
            "exactly the corner's three edges derive hidden, got "
            ~ m.countHiddenEdges().to!string);
        // And zero is really zero — the readout's "print nothing" branch.
        foreach (fi; around) m.setFaceHidden(fi, false);
        m.refreshHiddenDerived();
        assert(m.countHiddenFaces()    == 0);
        assert(m.countHiddenVertices() == 0);
        assert(m.countHiddenEdges()    == 0);
    }
    unittest { // T-S0d — refreshHiddenDerived() self-heals after a topology
        // change, with NO hide command running: the whole point of routing
        // it through commitChange rather than only the (not-yet-built,
        // Stage 2) hide commands.
        //
        // A 3-face fan around vertex 0 (an open tetrahedron corner):
        // f0=[0,1,2], f1=[0,2,3], f2=[0,3,1]. Vertex 0 touches all three;
        // vertices 1/2/3 each touch exactly two. f2 is hidden LAST
        // (highest index) deliberately: deleteFacesByMask's compaction does
        // not yet carry marks through an index shift (that is Stage 1's own
        // cost centre, T-S1, out of scope here) — deleting the
        // HIGHEST-indexed face is a stable-filter no-op for every surviving
        // index, so this case isolates the S0 claim under test (the funnel
        // refreshes on ANY geometry commit) from the S1 claim (a shift
        // preserves the bit on the right face), which this test does not
        // exercise.
        Mesh m;
        m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(-1,0,0)];
        m.addFace([0, 1, 2]);  // f0
        m.addFace([0, 2, 3]);  // f1
        m.addFace([0, 3, 1]);  // f2 — the last visible face touching vertex 0
        m.buildLoops();
        m.syncSelection();

        m.setFaceHidden(0, true);
        m.setFaceHidden(1, true);
        m.refreshHiddenDerived();
        assert(!m.isVertexHidden(0), "vertex 0 still touches the visible f2");

        // Delete f2 — no hide command runs. deleteFacesByMask ends in
        // commitChange(MeshEditScope.Geometry), which must call
        // refreshHiddenDerived() on our behalf. No vertex is orphaned by
        // this delete (1, 2 and 3 each still belong to a surviving face),
        // so compaction does not renumber anything either.
        bool[] mask = [false, false, true];
        const removed = m.deleteFacesByMask(mask);
        assert(removed == 1);
        assert(m.faces.length == 2, "f0 and f1 survive, unshifted — f2 was the last index");

        assert(m.isVertexHidden(0),
            "vertex 0's only surviving incident faces (f0, f1) are both hidden, and " ~
            "nothing called refreshHiddenDerived() explicitly after the delete");
    }

    // §3.1 — the marks invariant Select ∧ Hide = ∅, enforced in the WRITERS
    // (not the callers), so it holds on paths nobody thought to guard —
    // including undo/redo snapshot replay, which is exactly the path a
    // per-caller guard would miss.
    unittest { // face plane: the scalar writer, the bulk restore writer, and
        // the bulk SELECT writer's order-stamping side effect.
        auto m = makeCube();
        m.syncSelection();   // makeCube() does not size the marks arrays itself
        m.setFaceHidden(2, true);

        // Direct scalar writer. Both a hidden AND a visible face in the same
        // sequence, so "refused" reads differently from "did nothing".
        m.selectFace(2);
        m.selectFace(3);
        assert(!m.isFaceSelected(2), "selectFace must refuse a hidden face");
        assert(m.isFaceSelected(3),  "selectFace must still select a visible one");

        // Bulk restore writer (setFacesSelectedFrom / applySelectedFrom_ —
        // undo/redo snapshot replay's own primitive). One mask naming BOTH
        // faces at once.
        m.clearFaceSelection();
        auto want = new bool[](m.faces.length);
        want[2] = true; want[3] = true;
        m.setFacesSelectedFrom(want);
        assert(m.countSelectedFaces() == 1,
            "the mask asked for 2 faces; the hidden one must be refused — not both, not neither");
        assert(!m.isFaceSelected(2) && m.isFaceSelected(3));

        // Bulk SELECT writer (selectFacesFrom) must not stamp an order entry
        // for the refused face — a stale nonzero order on a
        // never-actually-selected element would corrupt select.more/less
        // and click-order-derived face winding.
        m.clearFaceSelection();
        m.selectFacesFrom(want);
        assert(m.faceSelectionOrder[2] == 0, "a refused (hidden) face must not receive an order stamp");
        assert(m.faceSelectionOrder[3] != 0, "the visible face must still be stamped");
    }
    unittest { // vertex and edge planes — same invariant, the other two
        // scalar writers.
        auto m = makeCube();
        m.syncSelection();   // makeCube() does not size the marks arrays itself
        // Direct poke, not setVertexHidden: vertex 0 has incident faces, so
        // the production writer would refuse it (§1.2 — derived, not
        // settable). This test is only about the SELECT-side guard, so it
        // stamps the bit the way refreshHiddenDerived() itself would.
        m.vertexMarks[0] |= Marks.Hide;
        const uint e01 = m.edgeIndex(0, 1);
        m.edgeMarks[e01] |= Marks.Hide;

        m.selectVertex(0);
        m.selectVertex(1);
        assert(!m.isVertexSelected(0), "selectVertex must refuse a hidden vertex");
        assert(m.isVertexSelected(1));

        const uint e12 = m.edgeIndex(1, 2);
        m.selectEdge(e01);
        m.selectEdge(e12);
        assert(!m.isEdgeSelected(e01), "selectEdge must refuse a hidden edge");
        assert(m.isEdgeSelected(e12));
    }
    unittest { // T-S0e — the DERIVATION ITSELF owes Select ∧ Hide = ∅
        // (BLOCKER, code review task 0613). T-S0d already proves
        // refreshHiddenDerived() sets the Hide bit on vertices/edges with NO
        // hide command anywhere in the call stack (it rides every geometry
        // commit). If it does not ALSO clear a pre-existing Select bit in
        // that same word write, §3.1 is breakable with Stage 0 code alone:
        // select an element while it is visible, hide it by a route that
        // never calls a hide command (any geometry-mutating commit that
        // happens to remove its last visible incident face), and it ends up
        // both selected and hidden — exactly what the review flagged.
        //
        // Direct marks pokes (not setFaceHidden) so this isolates
        // refreshHiddenDerived()'s OWN obligation from setFaceHidden's
        // (already covered by its own unittest above).
        auto m = makeCube();
        m.syncSelection();

        // Select vertex 0 and the edge (0,1) it anchors WHILE both are still
        // visible — a legal selection at this point.
        m.selectVertex(0);
        const uint e01 = m.edgeIndex(0, 1);
        m.selectEdge(e01);
        assert(m.isVertexSelected(0) && m.isEdgeSelected(e01));

        // Hide vertex 0's three incident faces (f0, f2, f5 — see the comment
        // at the top of the T-S0 block above) directly on faceMarks, then run
        // ONLY the derivation — no hide command, matching T-S0d's own shape.
        m.faceMarks[0] |= Marks.Hide;
        m.faceMarks[2] |= Marks.Hide;
        m.faceMarks[5] |= Marks.Hide;
        m.refreshHiddenDerived();

        assert(m.isVertexHidden(0), "vertex 0's incident faces (f0, f2, f5) are all hidden");
        assert(!m.isVertexSelected(0),
            "a vertex the derivation just hid must not stay selected — no hide command ran");
        assert(m.vertexSelectionOrder[0] == 0, "its order stamp must be cleared too");

        assert(m.isEdgeHidden(e01), "edge (0,1) derives hidden through its now-hidden endpoint");
        assert(!m.isEdgeSelected(e01),
            "an edge the derivation just hid must not stay selected — no hide command ran");
        assert(m.edgeSelectionOrder[e01] == 0, "its order stamp must be cleared too");
    }

    // §3.2 — the L1 operand-mask funnel: the fallback branch ("nothing
    // selected ⇒ the whole mesh") must mean "every VISIBLE element", not
    // "every element". A real selection can never contain a hidden element
    // (§3.1, just above), so only the fallback branch needs checking.
    unittest {
        auto m = makeCube();
        m.syncSelection();   // makeCube() does not size the marks arrays itself
        m.setFaceHidden(0, true);
        m.setFaceHidden(4, true);   // non-adjacent, and index 0 is the low-index trap

        auto fmask = m.operandFaceMask();
        assert(fmask.length == 6);
        foreach (fi; 0 .. 6)
            assert(fmask[fi] == (fi != 0 && fi != 4),
                "operandFaceMask must select every VISIBLE face when nothing is selected");

        // A real selection must be returned as-is — the fallback must NOT
        // fire once something is selected.
        m.selectFace(1);
        auto fmask2 = m.operandFaceMask();
        assert(fmask2[1] && !fmask2[2], "a real selection must win over the whole-mesh fallback");

        // Vertex/edge fallbacks. Faces 0/4 alone hide no vertex (T-S0b), so
        // hide vertex 0's whole corner to get a discriminating case.
        auto m2 = makeCube();
        m2.syncSelection();
        m2.setFaceHidden(0, true);
        m2.setFaceHidden(2, true);
        m2.setFaceHidden(5, true);   // vertex 0's three incident faces
        m2.refreshHiddenDerived();
        assert(m2.isVertexHidden(0));

        auto vmask = m2.operandVertexMask(EditMode.Vertices);
        assert(!vmask[0], "operandVertexMask must exclude a hidden vertex from the whole-mesh fallback");
        assert(vmask[1],  "a visible vertex must still be included");

        auto emask = m2.operandEdgeMask();
        const uint e01 = m2.edgeIndex(0, 1);
        assert(!emask[e01], "operandEdgeMask must exclude an edge derived-hidden through its hidden endpoint");
    }

    // === S5 ==================================================================

    // §3.2 shape A — the three `selectedVertexIndices*` accessors. These are
    // the only shape whose fallback returns an INDEX LIST rather than a mask,
    // and their live consumers are the transform drag (tools/transform) and
    // the magnet deform, i.e. every whole-mesh gizmo move. All three share one
    // fallback ("nothing selected ⇒ every vertex"), so all three are asserted.
    unittest {
        import std.conv : to;
        // C8d/C8e, the measured per-component law, is what makes this pair
        // discriminating: hiding two POLYGONS hides no vertex, so the vertex
        // operand set is still all 8 — an implementation that propagated the
        // face hide down to its corners reads 4 here. Hiding a whole corner's
        // faces derives exactly ONE hidden vertex, so it reads 7 — an
        // implementation that ignored hiding entirely reads 8, and one that
        // froze every vertex of a hidden face reads 4.
        auto a = makeCube();
        a.syncSelection();
        a.setFaceHidden(0, true);
        a.setFaceHidden(4, true);          // two polygons, opposite-ish
        assert(a.countHiddenVertices() == 0,
            "fixture: two polygon hides must derive NO hidden vertex (C8d)");
        assert(a.selectedVertexIndicesVertices().length == 8,
            "C8d: a polygon hide must not shrink the VERTEX operand set");
        assert(a.selectedVertexIndicesEdges().length    == 8, "C8d (edge accessor)");
        assert(a.selectedVertexIndicesFaces().length    == 8, "C8d (face accessor)");

        auto b = makeCube();
        b.syncSelection();
        b.setFaceHidden(0, true);
        b.setFaceHidden(2, true);
        b.setFaceHidden(5, true);          // vertex 0's three incident faces
        assert(b.isVertexHidden(0) && b.countHiddenVertices() == 1,
            "fixture: exactly vertex 0 derives hidden (C8e)");
        foreach (name, idx; ["Vertices": 0, "Edges": 1, "Faces": 2]) {
            auto got = idx == 0 ? b.selectedVertexIndicesVertices()
                     : idx == 1 ? b.selectedVertexIndicesEdges()
                                : b.selectedVertexIndicesFaces();
            assert(got.length == 7,
                "C8e / shape A (" ~ name ~ "): the whole-mesh fallback must return "
                ~ "7 VISIBLE vertices, got " ~ got.length.to!string);
            foreach (v; got)
                assert(v != 0, "C8e / shape A (" ~ name ~ "): vertex 0 is hidden and "
                    ~ "must not be in the whole-mesh operand set");
        }
    }

    // §3.3 — the backstop. A hand-built mask that reaches a `*ByMask` kernel
    // still cannot act on hidden geometry, even when no L1/L3 site is
    // involved: this calls the kernel DIRECTLY with an all-true mask, which is
    // precisely the shape an un-migrated caller (or a caller nobody has
    // written yet) produces.
    unittest {
        import std.conv : to;
        // flipFacesByMask is chosen because its effect is per-face and
        // readable WITHOUT any topology change: winding. So "4 of 6 flipped"
        // is checkable face by face, and the two hidden faces are asserted
        // bit-identical rather than merely counted.
        auto m = makeCube();
        m.syncSelection();
        m.setFaceHidden(1, true);
        m.setFaceHidden(3, true);

        auto before = new uint[][](m.faces.length);
        foreach (fi; 0 .. m.faces.length) before[fi] = m.faces[fi].dup;

        auto allTrueMask = new bool[](m.faces.length);
        allTrueMask[] = true;               // the un-migrated caller's mask
        const size_t n = m.flipFacesByMask(allTrueMask);

        assert(n == 4, "backstop: an all-true mask must flip the 4 VISIBLE faces, got "
            ~ n.to!string ~ " (unfiltered reads 6, a blanket refusal reads 0)");
        foreach (fi; 0 .. m.faces.length) {
            const hidden = (fi == 1 || fi == 3);
            const same   = m.faces[fi] == before[fi];
            assert(same == hidden,
                "backstop: face " ~ fi.to!string ~ (hidden ? " is hidden and must be "
                    ~ "bit-identical" : " is visible and must have been flipped"));
        }
    }

    // T-S6b / R6 — selectionSignature must react to a hide. Once the
    // whole-mesh fallback means "all VISIBLE", hiding an element changes the
    // operand set of an empty-selection op without changing its selection, so
    // a Select-only signature leaves the falloff / action-centre caches stale.
    unittest {
        auto base = makeCube();
        base.syncSelection();
        const ulong sig0 = base.selectionSignature(EditMode.Polygons);

        auto hid = makeCube();
        hid.syncSelection();
        hid.setFaceHidden(2, true);
        const ulong sigHide = hid.selectionSignature(EditMode.Polygons);
        assert(sigHide != sig0, "hiding a face must change the polygon signature");

        // The discriminator: hiding element i and SELECTING element i must
        // produce DIFFERENT signatures. A naive `mix(i+1)` for both collides,
        // and that collision is exactly what would serve a stale cache to an
        // operation whose operand set changed.
        auto sel = makeCube();
        sel.syncSelection();
        sel.selectFace(2);
        const ulong sigSel = sel.selectionSignature(EditMode.Polygons);
        assert(sigSel != sig0,  "selecting a face must change the signature");
        assert(sigSel != sigHide,
            "hiding element i and selecting element i must not collide");
    }

    // === T-S1 — Hide rides topology edits (doc/hide_geometry_plan.md §6 S1,
    // §7) ======================================================================
    //
    // Fixture: a 2×2 grid of 4 coplanar quads at four distinct centroids —
    //
    //   v6--v7--v8        f2 = [3,4,7,6]  centroid (0.5, 1.5, 0)
    //   |f2 |f3 |          f3 = [4,5,8,7]  centroid (1.5, 1.5, 0)
    //   v3--v4--v5        f0 = [0,1,4,3]  centroid (0.5, 0.5, 0)
    //   |f0 |f1 |          f1 = [1,2,5,4]  centroid (1.5, 0.5, 0)
    //   v0--v1--v2
    //
    // Every row: hide f3 (its own vertices/edges are never touched by the op
    // under test — verified per-op below — so its centroid stays exactly
    // (1.5,1.5,0) after the op), run a topology op that removes/reshapes
    // something else, then find the survivor BY CENTROID (not by index) and
    // assert IT — and only it — is hidden. A missing carry-through either
    // drops the bit (reads not-hidden at the right centroid) or plants it on
    // a neighbour (a DIFFERENT face reads hidden) — both are caught, because
    // the assertion checks both "the right face is hidden" AND "no other
    // face is."
    //
    // Every row targets something OTHER than the highest index (mask.d/
    // op-specific — see each case) — the HARD REQUIREMENT this task was
    // briefed with: "a highest-index delete cannot tell truncation from
    // compaction" (a last-element removal needs no shift, so truncating the
    // marks array from the tail would coincidentally read correct).
    version (unittest) {
    private static Vec3 t_s1_centroid(ref Mesh m, size_t fi) {
        Vec3 c = Vec3(0, 0, 0);
        auto f = m.faces[fi];
        foreach (vi; f) c = c + m.vertices[vi];
        return Vec3(c.x / f.length, c.y / f.length, c.z / f.length);
    }
    private static size_t t_s1_findByCentroid(ref Mesh m, Vec3 target) {
        foreach (fi; 0 .. m.faces.length)
            if ((t_s1_centroid(m, fi) - target).length < 1e-4) return fi;
        assert(false, "T-S1 fixture broke: no face survived at the expected centroid");
    }
    private static void t_s1_assertOnlyThatSurvivorHidden(ref Mesh m, Vec3 targetCentroid,
                                                           string label) {
        immutable size_t survivor = t_s1_findByCentroid(m, targetCentroid);
        assert(m.isFaceHidden(survivor),
            label ~ ": the face at f3's original centroid must still be hidden");
        foreach (fi; 0 .. m.faces.length)
            if (fi != survivor)
                assert(!m.isFaceHidden(fi),
                    label ~ ": no OTHER face may have picked up the bit");
    }
    private static Mesh t_s1_grid() {
        Vec3[] verts = [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0),
            Vec3(0, 1, 0), Vec3(1, 1, 0), Vec3(2, 1, 0),
            Vec3(0, 2, 0), Vec3(1, 2, 0), Vec3(2, 2, 0),
        ];
        uint[][] faceList = [
            [0, 1, 4, 3],   // f0, centroid (0.5, 0.5, 0)
            [1, 2, 5, 4],   // f1, centroid (1.5, 0.5, 0)
            [3, 4, 7, 6],   // f2, centroid (0.5, 1.5, 0)
            [4, 5, 8, 7],   // f3, centroid (1.5, 1.5, 0) — the one we hide
        ];
        return buildRawMesh(verts, faceList);
    }
    private enum Vec3 t_s1_f3Centroid = Vec3(1.5f, 1.5f, 0);
    }

    unittest { // T-S1 (delete) — deleteFacesByMask, mesh.d's own compaction.
        // Deletes f0 (index 0 — NOT the highest). Survivors [f1,f2,f3] shift
        // down one slot each; f3 lands at NEW index 2, not its original 3.
        auto m = t_s1_grid();
        m.setFaceHidden(3, true);
        m.selectFace(1);   // survivor, distinct from the hidden f3. NOTE
                            // (code review NIT): this pins deleteFacesByMask's
                            // OBSERVABLE contract ("Select does not survive a
                            // delete"), but is NOT the discriminator for a
                            // keepMask regression at its own
                            // `setFaceMarksFrom(keptWord, ~Marks.Select)` call
                            // — the very next line in deleteFacesByMask is an
                            // unconditional clearFaceSelectionResize(), which
                            // would mask a slip to an all-ones keepMask here
                            // too (verified: break-testing that call site's
                            // mask alone left this assertion green). The
                            // actual discriminator for that mask argument is
                            // setFaceMarksFrom's OWN direct unittest, next to
                            // its definition above.
        assert(m.isFaceSelected(1));
        assert(m.faces.length == 4);
        bool[] mask = new bool[](4);
        mask[0] = true;
        immutable size_t removed = m.deleteFacesByMask(mask);
        assert(removed == 1);
        assert(m.faces.length == 3, "T-S1 delete: one face removed");
        immutable size_t f1New = t_s1_findByCentroid(m, Vec3(1.5f, 0.5f, 0));
        assert(!m.isFaceSelected(f1New),
            "T-S1 delete: Select must NOT survive the compaction");
        t_s1_assertOnlyThatSurvivorHidden(m, t_s1_f3Centroid, "T-S1 delete");
    }

    unittest { // T-S1 (dissolve) — dissolveVerticesByMask. Dissolving v0 AND
        // v1 collapses f0=[0,1,4,3] below 3 corners (DROPPED); f1 reshapes to
        // a triangle but survives. f3 never references v0/v1 — untouched.
        auto m = t_s1_grid();
        m.setFaceHidden(3, true);
        bool[] mask = new bool[](m.vertices.length);
        mask[0] = true;
        mask[1] = true;
        immutable size_t dissolved = m.dissolveVerticesByMask(mask);
        assert(dissolved == 2);
        assert(m.faces.length == 3, "T-S1 dissolve: f0 degenerated and was dropped");
        t_s1_assertOnlyThatSurvivorHidden(m, t_s1_f3Centroid, "T-S1 dissolve");
    }

    unittest { // T-S1 (triangulate) — triangulateFacesByMask. Triangulating
        // f0 GROWS the array (one quad -> two triangles): everything after f0
        // shifts UP by one instead of down — the complementary shift
        // direction to delete/dissolve/weld's shrink. f3 ends at index 4, not 3.
        auto m = t_s1_grid();
        m.setFaceHidden(3, true);
        bool[] mask = new bool[](4);
        mask[0] = true;
        immutable size_t changed = m.triangulateFacesByMask(mask);
        assert(changed == 1);
        assert(m.faces.length == 5, "T-S1 triangulate: f0 became 2 triangles");
        t_s1_assertOnlyThatSurvivorHidden(m, t_s1_f3Centroid, "T-S1 triangulate");
    }

    unittest { // T-S1 (removeEdges) — removeEdgesByMask, the MERGED-POLYGON
        // path (§4.2's newPolyWord — a distinct code shape from the plain
        // keptWord compaction the other rows exercise). Dissolving the
        // f0/f1 shared edge (1,4) merges them into one hexagon, appended at
        // the TAIL; f2, f3 are kept faces, shifting down two slots. f3 never
        // references vertex 1 or the (1,4) edge — untouched.
        auto m = t_s1_grid();
        m.setFaceHidden(3, true);
        const uint e14 = m.edgeIndex(1, 4);
        bool[] emask = new bool[](m.edges.length);
        emask[e14] = true;
        immutable size_t n = m.removeEdgesByMask(emask);
        assert(n == 1);
        assert(m.faces.length == 3, "T-S1 removeEdges: f0+f1 merged into one polygon");
        t_s1_assertOnlyThatSurvivorHidden(m, t_s1_f3Centroid, "T-S1 removeEdges");
    }

    unittest { // T-S1 (weld) — weldVertexPairs -> applyVertexRemapAndRebuild.
        // Welding v0 into v1 AND v3 into v4 (both adjacent-corner pairs of
        // f0=[0,1,4,3]) collapses f0 to 2 distinct corners — DROPPED. f2
        // references v3, so it reshapes to a triangle but survives. f3
        // references v4 (kept, stays in place) but not v3 or v0 — untouched.
        auto m = t_s1_grid();
        m.setFaceHidden(3, true);
        immutable size_t welded = m.weldVertexPairs([[1u, 0u], [4u, 3u]]);
        assert(welded == 2);
        assert(m.faces.length == 3, "T-S1 weld: f0 collapsed below 3 corners and was dropped");
        t_s1_assertOnlyThatSurvivorHidden(m, t_s1_f3Centroid, "T-S1 weld");
    }

    unittest { // T-S1 (extrude) — mesh_ops/extrude.d's extrudeFacesByMask, a
        // WHOLESALE-WIPE site (§4.1a — `faceMarks[] = 0` + Subpatch-only
        // rebuild before this fix), not a plain compaction. Extruding f0
        // moves it to a cap face APPENDED at the tail (behind new wall
        // quads); the "kept, non-selected" originals f1,f2,f3 are re-emitted
        // FIRST, in relative order — f3 lands at new index 2. f3's own verts
        // (4,5,8,7) are never part of f0's boundary — untouched.
        auto m = t_s1_grid();
        m.setFaceHidden(3, true);
        bool[] mask = new bool[](4);
        mask[0] = true;
        immutable size_t affected = m.extrudeFacesByMask(mask, 1.0f);
        assert(affected == 1);
        assert(m.faces.length > 4, "T-S1 extrude: cap + wall quads appended");
        t_s1_assertOnlyThatSurvivorHidden(m, t_s1_f3Centroid, "T-S1 extrude");
    }

    // --- Bulk SELECT (as opposed to bulk RESTORE) --------------------------
    // `setXSelectedFrom` above is a state-RESTORE setter: it writes the Select
    // bit and NOTHING else, which is exactly right for undo/redo snapshot
    // replay and for the post-topology re-selects that carry a rebuilt
    // `XSelectionOrder` array alongside the new Select bits.
    //
    // It is the WRONG primitive for a command that COMPUTES a new selection
    // (a loop walk, a flood fill, a region fill). Such a command is selecting
    // elements on the user's behalf, and every consumer of selection history
    // — select.loop's seed scan, select.more / select.less / select.between,
    // and mesh.makePolygon, which derives face WINDING from vertex click order
    // — reads `XSelectionOrder` with the convention "0 = not manually
    // selected, sorts last". An element committed through the restore setter
    // lands with order 0, so it sorts behind anything clicked afterwards even
    // though it was selected first.
    //
    // `selectXFrom` is that missing primitive: commit the selection AND stamp
    // the elements it newly selects, reproducing `selectX`'s own contract
    // (an element that was not already selected takes the next counter value;
    // an already-selected one keeps the order it had; a dropped one is
    // cleared by the setter). The `bool[]` carries no traversal order, so the
    // stamp runs in ascending index order — which is also the tie-break the
    // consumers' sorts already apply among equal-order elements.
    //
    // Rule of thumb: restoring remembered state -> `setXSelectedFrom`;
    // selecting on the user's behalf -> `selectXFrom`.
    void selectVerticesFrom(const bool[] src) {
        bool[] added = new bool[](src.length);
        foreach (i, s; src) added[i] = s && !isVertexSelected(i);
        setVerticesSelectedFrom(src);   // also grows vertexSelectionOrder
        // Re-check isVertexSelected AFTER the call: `added` was computed from
        // the request, but setVerticesSelectedFrom's Select ∧ Hide = ∅ guard
        // may have silently refused a hidden element — stamping its order
        // anyway would leave a nonzero order entry for something that was
        // never actually selected.
        foreach (i, a; added)
            if (a && isVertexSelected(i)) vertexSelectionOrder[i] = ++vertexSelectionOrderCounter;
    }
    void selectEdgesFrom(const bool[] src) {
        bool[] added = new bool[](src.length);
        foreach (i, s; src) added[i] = s && !isEdgeSelected(i);
        setEdgesSelectedFrom(src);      // also grows edgeSelectionOrder
        foreach (i, a; added)
            if (a && isEdgeSelected(i)) edgeSelectionOrder[i] = ++edgeSelectionOrderCounter;
    }
    void selectFacesFrom(const bool[] src) {
        bool[] added = new bool[](src.length);
        foreach (i, s; src) added[i] = s && !isFaceSelected(i);
        setFacesSelectedFrom(src);      // also grows faceSelectionOrder
        foreach (i, a; added)
            if (a && isFaceSelected(i)) faceSelectionOrder[i] = ++faceSelectionOrderCounter;
    }

    // selectVertex / selectEdge / selectFace: the direct scalar writers.
    // Same invariant as applySelectedFrom_ above (§3.1) — refuse to select a
    // hidden element. Checked first so a refusal touches neither the order
    // counter nor the bus publish.
    void selectVertex(int idx) {
        if (vertexMarks[idx] & Marks.Hide) return;
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
        if (edgeMarks[idx] & Marks.Hide) return;
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
        if (faceMarks[idx] & Marks.Hide) return;
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
    size_t insetFacesByMask(const bool[] maskIn, float inset) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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

    /// Per-corner unit normal at vertex `v` within face `fi`: the cross
    /// product of the face's OWN two edges meeting at that corner
    /// (`cross(next-cur, prev-cur)`), NOT `faceNormal()`'s whole-face
    /// Newell average. Identical to `faceNormal()` for a planar face (any
    /// corner of a flat polygon shares the same normal direction), but
    /// diverges on a non-planar n-gon — task 0458's recovered
    /// the reference's group-average-normal law is only bit-exact against this
    /// PER-CORNER form (rr/gdb + geometry, `toolcards/poly.bevel/
    /// findings.md` §1: the reference's per-corner vertex normal). Returns (0,1,0)
    /// for a degenerate/tiny corner (matches `faceNormal`'s own fallback).
    private Vec3 cornerNormalAt(uint fi, uint v) const {
        const uint[] f = faces[fi];
        const int N = cast(int)f.length;
        int k = -1;
        foreach (i; 0 .. N) if (f[i] == v) { k = i; break; }
        assert(k >= 0, "cornerNormalAt: vertex not incident to face");
        const Vec3 prevV = vertices[f[(k + N - 1) % N]];
        const Vec3 curV  = vertices[f[k]];
        const Vec3 nextV = vertices[f[(k + 1) % N]];
        Vec3 n = cross(nextV - curV, prevV - curV);
        float len = n.length;
        return len > 1e-9f ? n * (1.0f / len) : Vec3(0, 1, 0);
    }

    /// `AVE_N(v) = k·N/|N|²` (task 0458, the reference's group-average-normal recovered
    /// via rr/gdb — `toolcards/poly.bevel/findings.md` §1): `nSum` = Σ of
    /// the `count` incident selected-face CORNER unit normals (see
    /// `cornerNormalAt`), amplified by their own count and re-normalized
    /// against their squared magnitude. Reduces to the naive `Σ(unit
    /// normal)` EXACTLY when the `count` corner normals are mutually
    /// ORTHOGONAL (there `|N|²==count`) — every group fixture before 0458
    /// happened to be an axis-aligned cube corner, so the naive sum
    /// (`vibe3d-bug`, pre-0458) passed every prior test: a symmetry trap,
    /// not correctness (the same class as 0453). Falls back to the raw
    /// (un-amplified) sum when `|N|²` is too small to safely invert — a
    /// degenerate selection (near-antiparallel corner normals) no known
    /// case exercises; returning the un-scaled sum avoids a NaN/Inf blowup
    /// rather than asserting.
    private static Vec3 aveNormal(Vec3 nSum, uint count) {
        immutable float mag2 = dot(nSum, nSum);
        if (mag2 < 1e-12f) return nSum;
        return nSum * (cast(float)count / mag2);
    }

    /// Locates vertex `v`'s two GROUP-BOUNDARY-CONTOUR edges — the outer
    /// silhouette of the selected-face region at `v`, task 0458
    /// findings.md §1/§5's `e_a`/`e_b` — for the recovered `bevGenInset`
    /// mitered-corner offset (`boundaryContourInset` below). Any THIRD
    /// edge incident to `v` that is INTERNAL (shared by two selected
    /// faces — e.g. G2's spoke to the fully-enclosed apex, or G3's two
    /// spokes to its other interior neighbors) is excluded entirely, per
    /// the reference's construction. `eB` is the boundary neighbor
    /// reached via each incident selected face's PREVIOUS-index direction
    /// (`f[k-1]`), `eA` via its NEXT-index direction (`f[k+1]`) — this
    /// pairing (not its mirror) is the one empirically confirmed
    /// bit-exact against the G2-ring/G3-partial dump-oracles (the
    /// mirrored pairing negates the mitered offset, since `U` — and hence
    /// the sign of `boundaryInset` — is built from `eB` alone). Returns
    /// false unless exactly one of each is found, the only topology (two
    /// group-boundary edges at `v`) this construction covers.
    private bool findGroupBoundaryContour(uint v, const bool[] mask,
            bool[ulong] internalEdgeSet, out uint eA, out uint eB) const {
        bool foundA = false, foundB = false;
        foreach (fi; facesAroundVertex(v)) {
            if (fi >= mask.length || !mask[fi]) continue;
            const uint[] f = faces[fi];
            immutable int N = cast(int)f.length;
            int k = -1;
            foreach (i; 0 .. N) if (f[i] == v) { k = i; break; }
            if (k < 0) continue;
            immutable uint nxt = f[(k + 1) % N];
            immutable uint prv = f[(k + N - 1) % N];
            if (auto ip = edgeKey(v, nxt) in internalEdgeSet) {
                if (!*ip) { eA = nxt; foundA = true; }
            }
            if (auto ip = edgeKey(v, prv) in internalEdgeSet) {
                if (!*ip) { eB = prv; foundB = true; }
            }
        }
        return foundA && foundB;
    }

    /// Recovered `bevGenInset` mitered-corner offset (task 0458
    /// findings.md §1/§5, rr/gdb-traced): `boundaryInset = D · inset /
    /// (D·U)`, a textbook mitered-polygon-corner offset generalized off
    /// the true per-vertex shift normal `aveN` (`AVE_N`) instead of a flat
    /// 2D plane. `D = unit(perp(eaVec,aveN)) + unit(perp(ebVec,aveN))` is
    /// the tangent-plane (⟂ `aveN`) bisector sum of the two
    /// group-boundary-contour edges; `U = unit(cross(ebVec,aveN))` is the
    /// tangent-plane perpendicular of `ebVec`; `perp(e,n) = e −
    /// (e·n/n·n)·n` projects an edge vector into the plane ⟂ `n`. Returns
    /// false (and leaves `result` zeroed) when `|D·U|` is below `GATE_EPS`
    /// — a genuine 0/0 singularity in the formula, NOT a code bug, that
    /// occurs exactly when `eaVec`/`ebVec` project anti-parallel onto the
    /// tangent plane: G1's coplanar ridge-tent measures `D·U` at machine
    /// epsilon (both its boundary-contour edges and `aveN` are coplanar),
    /// while G2-ring/G3-partial measure `|D·U|` in `[0.368, 0.974]` on
    /// their dump-oracles — a clean separation (task 0458, verified
    /// against all three case families before wiring this gate). The
    /// caller falls back to the existing 3-plane-meet law in that case.
    private static bool boundaryContourInset(Vec3 eaVec, Vec3 ebVec,
            Vec3 aveN, float inset, out Vec3 result) {
        import std.math : abs;
        static Vec3 perp(Vec3 e, Vec3 n) {
            immutable float nn = dot(n, n);
            return nn > 1e-12f ? e - n * (dot(e, n) / nn) : e;
        }
        // NIT (task 0467, reviewer follow-up): gate the U-degeneracy at its
        // SOURCE. When `ebVec` is parallel to `aveN`, `cross(ebVec,aveN)`
        // collapses to ~0 and `safeNormalize` would fabricate a finite bogus
        // (0,1,0) for both `U` and `perp(ebVec,aveN)` — yielding a
        // finite-but-meaningless miter that the downstream `|D·U|` gate can
        // MISS (D·U stays non-tiny because it is built from the fake
        // directions). Test the true sine of the eb/aveN angle directly
        // (`|cross(ebVec,aveN)| / (|ebVec|·|aveN|)`) so `e_b ∥ aveN` falls to
        // the caller's 3-plane / per-face fallback instead of returning
        // bogus geometry. This is strictly ADDITIVE to the existing `|D·U|`
        // gate (which still catches G1's coplanar-ridge `D→0` anti-parallel
        // case, where `ebVec` is NOT parallel to `aveN`).
        immutable Vec3  crossEbN = cross(ebVec, aveN);
        immutable float ebLen  = ebVec.length;
        immutable float aveLen = aveN.length;
        enum float SIN_EPS = 1e-4f;
        if (ebLen < 1e-9f || aveLen < 1e-9f ||
            crossEbN.length < SIN_EPS * ebLen * aveLen) {
            result = Vec3(0, 0, 0); return false;
        }
        immutable Vec3 D = safeNormalize(perp(eaVec, aveN)) + safeNormalize(perp(ebVec, aveN));
        immutable Vec3 U = safeNormalize(crossEbN);
        immutable float dDotU = dot(D, U);
        enum float GATE_EPS = 1e-4f;
        if (abs(dDotU) < GATE_EPS) { result = Vec3(0, 0, 0); return false; }
        result = D * (inset / dDotU);
        return true;
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
    /// centroid, an elongated face collapses pairwise onto a line. The
    /// reference KEEPS that collapse as a DEGENERATE QUAD RING (fuzz D3):
    /// the coincident cap corners stay distinct referenced verts, so the
    /// cap and each ring quad remain 4-vertex zero-area faces. The clamped
    /// pass therefore does NOT weld — welding + the resulting fan-to-triangle
    /// topology was a `vibe3d-divergence` (task 0304), corrected here to the
    /// reference's coincident-corner quad ring. (Overshoot clamping is NOT
    /// applied to `group`'s shared corners below — untested combination,
    /// documented gap.)
    ///
    /// `group` (task 0391 Phase 4, `capture-verified` default TRUE at the
    /// command/tool layer — see `commands/mesh/bevel.d`): when true and ≥2
    /// selected faces are mutually adjacent, their SHARED corners collapse
    /// to ONE new vertex instead of each face computing its own independent
    /// corner there, and the ring quad for any EDGE shared by 2 selected
    /// faces ("internal") is suppressed entirely (no bridge — it dissolves
    /// into the merged interior). Shift accumulates via `aveNormal()`'s
    /// `AVE_N = k·N/|N|²` (task 0458, the reference's group-average-normal recovered
    /// rr/gdb — see that function's doc comment and
    /// `toolcards/poly.bevel/findings.md`), not a plain `Σ(unit normal)` —
    /// the two coincide only when the incident corner normals are mutually
    /// orthogonal, which is why every pre-0458 cube-corner fixture passed
    /// regardless (a 0453-class symmetry trap). Three corner laws
    /// (`internalCnt`/`anyBoundary` from the vertex's own incident-edge
    /// classification):
    ///   - EXACTLY 1 internal edge ("half-shared", on the group's own outer
    ///     boundary but shared by the 2 faces either side of that internal
    ///     edge): `orig + shift·AVE_N + boundaryInset`, where `boundaryInset`
    ///     is the recovered `bevGenInset` mitered-corner offset
    ///     (`boundaryContourInset`, task 0458 follow-up — findings.md
    ///     §1/§5) built from `v`'s own two group-boundary-contour edges
    ///     (`findGroupBoundaryContour`), NOT the internal edge. That
    ///     construction is singular (`|D·U|→0`) exactly on a coplanar
    ///     ridge — a gate falls back to `inset·dir(orig → the internal
    ///     edge's other endpoint)` there, the original 3-plane-meet law,
    ///     bit-exact against `poly_bevel_G1_halfshared_tent` (6e-9,
    ///     including on non-90°/unequal-edge-length asymmetric geometry).
    ///     Off the gate, bit-exact against `poly_bevel_G2_apex_v3`'s ring
    ///     vertices (1.2e-8 to 6.4e-8) — a ring vertex whose sole internal
    ///     edge runs to a fully-enclosed apex is the SAME `internalCnt==1`
    ///     case, just clear of the gate.
    ///   - EVERY incident edge internal (fully enclosed by the group, no
    ///     boundary edge left — the group's own analog of edge-bevel's
    ///     N-way junction hub): `orig + shift·AVE_N`, no inset term (no
    ///     boundary edge left to inset against) — bit-exact against
    ///     `poly_bevel_G2_apex_v3`'s apex vertex (2.6e-8).
    ///   - 0 internal edges (standalone — touched by only ONE selected face)
    ///     on a face that is itself ISOLATED (no group-internal edge, i.e.
    ///     `!faceGrouped` — always so when `group=false`, or a single/
    ///     non-adjacent selected face): task 0467. The reference's
    ///     `bevGenInset` places the inset corner by a mitered offset that
    ///     stays in the
    ///     TANGENT PLANE ⟂ the WHOLE-FACE Newell normal —
    ///     `orig + faceNormal·shift + boundaryContourInset(eNext,ePrev,
    ///     faceNormal,inset)`. The pre-0467 `insetCorner`/`offsetMeet`
    ///     instead intersected the two offset lines along the corner's actual
    ///     TILTED edge directions, so on a non-planar quad the meet slid off
    ///     the tangent plane and gained a spurious normal-direction component
    ///     (the reported ~0.005–0.05 residual, e.g. a beveled subdivided-cube
    ///     face). Bit-exact (rr/gdb + fresh capture) against
    ///     `poly_bevel_{W1,W2,W3}_warped_standalone*` (findings.md §6). The
    ///     per-face path below (the `else` branch of the final-corner loop)
    ///     gates this on an isolated face (a GROUPED face's standalone
    ///     corners are the SEPARATE per-corner-AVE_N regime `poly_bevel_
    ///     {G2,G3}` pin — left untouched, out of scope here) AND a genuinely
    ///     non-planar corner (a planar corner keeps `offsetMeet`, so every
    ///     flat-face bevel is BYTE-IDENTICAL to pre-0467) AND a
    ///     well-conditioned miter.
    ///   - ≥2 internal edges AND ≥1 remaining boundary edge (a partial,
    ///     "some but not all" enclosure — task 0458 finding G3): SHARES one
    ///     vertex (topology matches the reference; the pre-0458 stub fell
    ///     through to the per-face formula, splitting it into one vertex
    ///     PER incident face) at `orig + shift·AVE_N + boundaryInset` — the
    ///     SAME recovered mitered-corner offset as the half-shared branch
    ///     above, using `v`'s two group-boundary-contour edges (its
    ///     internal spokes excluded entirely) — bit-exact against
    ///     `poly_bevel_G3_partial_fan`'s shared apex vertex (1.1e-8, task
    ///     0458 follow-up).
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
    /// at a group-shared corner are memoized PER RING LEVEL (task 0458
    /// +S1 — `sharedVertIdxByLevel`), same as the t=Nseg final corner —
    /// a standalone corner (touched by only one selected face) always got
    /// a fresh per-face vertex either way, so this only changes shared
    /// corners. Before 0458 the intermediate rings were created per-face
    /// unconditionally, leaving two COINCIDENT-position vertices at a
    /// shared corner's every non-final ring level — a topology divergence
    /// `poly_bevel_S1_group_segs2` exposed (12 new verts / 20 total
    /// expected, 14 new / 22 total pre-fix — 2 grouped cube faces, segs=2).
    /// `group=true && segments>1`: bit-exact against that dump (task
    /// 0458 Phase 1) — the shared corner IS segmented the same equal-lerp
    /// way as every other boundary vertex, orig→group-final (the middle
    /// ring lands at exactly
    /// half-inset/half-shift, including at the grouped shared corner).
    ///
    /// `square` (task 0458 Phase 3, recovered square-cap boundary-mark +
    /// rebuild callback post-pass — `toolcards/poly.bevel/findings.md`
    /// §0/§3): composition order is `square( group_xor_notgroup( segments
    /// ) )` — square wraps whatever the (group|non-group)+segments solve
    /// above already produced, touching ONLY the outermost ring (the
    /// original boundary → `ringVerts[1]` bridge); any deeper segment
    /// rings (`ringVerts[1..Nseg]`) are untouched plain quads, unchanged.
    /// For each boundary-contour vertex `V` of a selected face:
    ///   - STANDALONE (not a group-shared corner, i.e. not in
    ///     `sharedCornerPos` — every corner when `group=false`, since
    ///     square is a pure per-face op there, task 0458 Q2 finding):
    ///     `V` is RETAINED at its original position, and TWO new split
    ///     points are inserted on `V`'s own two original boundary edges,
    ///     each at distance `effInset/Nseg` from `V` (the OUTERMOST
    ///     ring's own inset — Q3 finding: with segments, the split
    ///     distance is `inset/segs`, not the full inset). A quad CAP
    ///     replaces `V`'s corner: `[V, splitToward-next, ringVerts[1][V],
    ///     splitToward-prev]`.
    ///   - RIDGE (a group-shared corner, `internalCnt>=1` —
    ///     `sharedCornerPos`, task 0458 Q4 finding): NEITHER of its two
    ///     boundary edges gets a split near it, and NO cap is built — its
    ///     neighbourhood is already closed by the two edge-panels
    ///     (below) meeting directly at the original vertex, connected by
    ///     the radial edge to its own `ringVerts[1]` position (its group-
    ///     solved final/segment-ring position, computed above,
    ///     unaffected by square).
    /// Every surviving boundary edge (i.e. not group-dissolved — the
    /// existing `internalEdgeSet` skip above already excludes internal
    /// edges from ever reaching this code) gets an edge-panel quad:
    /// `[pointNear-i, pointNear-next, ringVerts[1][next], ringVerts[1][i]]`
    /// where `pointNear-*` is the new split (standalone) or the raw
    /// original vertex (ridge). The UNSELECTED face sharing that same
    /// original edge (there is always exactly one on a 2-manifold mesh)
    /// absorbs whichever split point(s) were created, splicing them into
    /// its own vertex loop between the two shared corners so the mesh
    /// stays watertight (no T-junction) — becoming an n-gon (hexagon in
    /// Q1/Q4, octagon in Q2 where a side face borders TWO independently-
    /// squared faces). Reproduced bit-exact (topology + position) against
    /// all four dump-oracles (`poly_bevel_{Q1_single_square,
    /// Q2_nonadjacent_square,Q3_square_segs2}.json` +
    /// `poly_bevel_two_faces_grouped_square1.json` = Q4). `square=false`
    /// (default) touches none of this code — byte-identical to the
    /// pre-0458-Phase-3 kernel.
    ///
    /// KNOWN LIMITATION (not exercised by any of the four dump-oracles,
    /// flagged rather than guessed): the split distance `effInset/Nseg`
    /// is not clamped against the boundary edge's own length the way the
    /// mitered final-ring inset is (`maxSafeUniformInset`) — an
    /// exceptionally large inset relative to a short edge could produce
    /// an overlapping/self-intersecting cap+panel pair. Left unclamped
    /// pending a captured case that actually exercises it.

    /// Two-layer DoS clamp: `segments` is hard-capped to
    /// `MAX_BEVEL_SEGMENTS` HERE (kernel-side, authoritative for any
    /// caller) since it scales ring-quad allocation linearly per selected
    /// face; the command/tool Param's `.min(0).max(MAX_BEVEL_SEGMENTS)
    /// .enforceBounds()` hint is a shallower UI/HTTP-only second line of
    /// defense.
    size_t bevelFacesByMask(const bool[] maskIn, float inset, float shift,
                             bool group = false, int segments = 0,
                             bool square = false) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        import std.math : abs;
        // Parity (fuzz D6): inset==0 && shift==0 is NOT a no-op — the
        // reference still builds a ZERO-WIDTH bevel ring (the inset cap
        // ring lands exactly on the original boundary, giving coincident
        // inner=outer corners + zero-area ring quads + a degenerate cap).
        // We therefore let a masked face through even at 0/0 and let the
        // per-face loop decide: an EMPTY mask still returns 0 (processed
        // stays 0 below → no commit), so a genuine "nothing selected"
        // call is unaffected. `shift==0` alone (inset>0) and `inset==0`
        // alone (shift!=0) already built a ring before this change.

        int segN = segments;
        if (segN < 0) segN = 0;
        if (segN > MAX_BEVEL_SEGMENTS) segN = MAX_BEVEL_SEGMENTS;
        immutable int Nseg = (segN < 1) ? 1 : segN; // segs=0 == segs=1 == flat

        size_t processed = 0;
        bool anyClamped = false;
        const size_t nFaces = faces.length;

        // Task 0467: `faceGrouped[fi]` = does selected face `fi` share a
        // group-internal edge with another selected face (i.e. is it part of
        // an ADJACENT group). Its STANDALONE corners then keep the
        // per-corner-AVE_N group regime (`poly_bevel_{G2,G3}`); an ISOLATED
        // face (no internal edge — always so when `group=false`) uses the
        // whole-face tangent-plane inset instead. Default false → every face
        // isolated unless the group pre-pass proves otherwise.
        bool[] faceGrouped = new bool[](nFaces);

        // --- group=true pre-pass: classify edges internal/boundary and
        // pre-compute each shared-corner vertex's target position. ---
        bool[ulong] internalEdgeSet;  // edgeKey → true(internal)/false(boundary), only for edges bordering >=1 selected face
        Vec3[uint]  sharedCornerPos;  // orig vertex idx → shared new position (half-shared or apex)
        if (group) {
            auto edgeFacesMap = buildEdgeFaces();
            foreach (fi; 0 .. nFaces) {
                if (fi >= mask.length || !mask[fi]) continue;
                auto f = faces[fi];
                immutable int Nf = cast(int)f.length;
                foreach (k; 0 .. Nf) {
                    uint a = f[k], b = f[(k + 1) % Nf];
                    immutable ulong key = edgeKey(a, b);
                    if (key in internalEdgeSet) continue;
                    auto fp = key in edgeFacesMap;
                    bool internal = false;
                    if (fp !is null && (*fp)[0] >= 0 && (*fp)[1] >= 0) {
                        immutable uint fa = cast(uint)(*fp)[0], fb = cast(uint)(*fp)[1];
                        internal = (fa < mask.length && mask[fa]) && (fb < mask.length && mask[fb]);
                        if (internal) { faceGrouped[fa] = true; faceGrouped[fb] = true; }
                    }
                    internalEdgeSet[key] = internal;
                }
            }

            // Per-vertex CORNER-NORMAL accumulator: once per (vertex,
            // selected face it corners) pair, regardless of how many of its
            // edges are internal — used only for vertices that end up
            // shared. Accumulates the RAW per-corner unit normal (task
            // 0458's `cornerNormalAt`, NOT yet shift-scaled) plus a count,
            // so `aveNormal()` below can apply the reference's `k·N/|N|²`
            // amplification — a plain `Σ(unit normal)*shift` (pre-0458)
            // only coincides with that when the corner normals are
            // mutually orthogonal (see `aveNormal`'s doc comment).
            Vec3[uint] normalSum;
            uint[uint] normalCount;
            foreach (fi; 0 .. nFaces) {
                if (fi >= mask.length || !mask[fi]) continue;
                foreach (v; faces[fi]) {
                    immutable Vec3 cn = cornerNormalAt(cast(uint)fi, v);
                    if (auto p = v in normalSum) *p = *p + cn;
                    else normalSum[v] = cn;
                    if (auto c = v in normalCount) ++(*c);
                    else normalCount[v] = 1;
                }
            }

            foreach (v, nSum; normalSum) {
                uint internalCnt = 0, lastInternalOther = uint.max;
                bool anyBoundary = false;
                foreach (ei; edgesAroundVertex(v)) {
                    immutable uint w = edgeOtherVertex(ei, v);
                    immutable ulong key = edgeKey(v, w);
                    auto ip = key in internalEdgeSet;
                    if (ip is null) continue; // doesn't border any selected face — irrelevant
                    if (*ip) { ++internalCnt; lastInternalOther = w; }
                    else     { anyBoundary = true; }
                }
                if (internalCnt == 0) continue; // standalone — default formula below
                immutable Vec3 aveN = aveNormal(nSum, normalCount[v]);
                immutable Vec3 sSum = aveN * shift;
                if (internalCnt == 1) {
                    // Half-shared (task 0458 finding G1) OR a ring vertex
                    // whose sole internal edge runs to a fully-enclosed
                    // apex (finding G2's OTHER, internalCnt>=2 vertex) —
                    // findings.md §1/§5: BOTH are governed by the SAME
                    // recovered mitered-corner offset built from `v`'s own
                    // two group-boundary-contour edges (NOT the internal
                    // edge). That construction is singular exactly on G1's
                    // coplanar-ridge topology (`boundaryContourInset`'s
                    // `|D·U|` gate) — there we fall back to the original
                    // 3-plane-meet law (along the internal edge itself),
                    // bit-exact against `poly_bevel_G1_halfshared_tent`
                    // (6e-9, incl. on non-90°/unequal-length asymmetric
                    // geometry). Off the gate, bit-exact against
                    // `poly_bevel_G2_apex_v3`'s ring vertices (1.2e-8 to
                    // 6.4e-8, task 0458 follow-up).
                    uint eA, eB;
                    Vec3 offset;
                    if (findGroupBoundaryContour(v, mask, internalEdgeSet, eA, eB) &&
                        boundaryContourInset(vertices[eA] - vertices[v],
                                              vertices[eB] - vertices[v], aveN, inset, offset)) {
                        sharedCornerPos[v] = vertices[v] + sSum + offset;
                    } else {
                        sharedCornerPos[v] = vertices[v] + sSum +
                            safeNormalize(vertices[lastInternalOther] - vertices[v]) * inset;
                    }
                } else if (!anyBoundary) {
                    // Fully-enclosed apex (finding G2): bit-exact against
                    // `poly_bevel_G2_apex_v3` (2.6e-8), no inset term (no
                    // boundary edge to inset against).
                    sharedCornerPos[v] = vertices[v] + sSum;
                } else {
                    // Partial — internalCnt>=2 with a remaining boundary
                    // edge (finding G3). Reference SHARES one vertex at
                    // `orig + shift·AVE_N + boundaryInset` — the SAME
                    // recovered mitered-corner offset as the half-shared
                    // branch above, using `v`'s two group-boundary-contour
                    // edges (excluding its internal spokes entirely) —
                    // bit-exact against `poly_bevel_G3_partial_fan`'s
                    // shared apex vertex (1.1e-8, task 0458 follow-up,
                    // `findings.md` §1/§5). The topology divergence the
                    // pre-0458 stub had (3 split per-face verts instead of
                    // 1) stays fixed regardless. Falls back to the plain
                    // `orig + shift·AVE_N` term (no documented case
                    // exercises this — the gate is only known to trigger
                    // on G1's coplanar-ridge topology, which cannot arise
                    // here since G3 always has a strict remaining
                    // boundary distinct from any coplanar internal ridge).
                    uint eA, eB;
                    Vec3 offset;
                    if (findGroupBoundaryContour(v, mask, internalEdgeSet, eA, eB) &&
                        boundaryContourInset(vertices[eA] - vertices[v],
                                              vertices[eB] - vertices[v], aveN, inset, offset)) {
                        sharedCornerPos[v] = vertices[v] + sSum + offset;
                    } else {
                        sharedCornerPos[v] = vertices[v] + sSum;
                    }
                }
            }
        }
        // orig vertex idx → already-created shared mesh vertex, memoized
        // PER RING LEVEL (index 0 unused — t=0 is always the untouched
        // original vertex, already naturally shared). `sharedVertIdxByLevel
        // [Nseg]` is the final ring's memo (pre-existing); task 0458 Phase 1
        // +S1 extends the SAME memoization to every intermediate ring
        // 1..Nseg-1 — `poly_bevel_S1_group_segs2` showed the reference
        // shares a group corner's intermediate-ring vertex too (one vertex
        // per distinct corner per ring, 12 new verts for 2 grouped
        // cube faces at segs=2), where the pre-0458 per-face-only
        // intermediate-ring code created TWO coincident-position vertices
        // (one per incident face) at every non-final ring level for a
        // shared corner — a topology divergence `group=true &&
        // segments>1` never had a fixture to catch (doc'd as
        // "KNOWN-UNTESTED" until this task).
        uint[uint][] sharedVertIdxByLevel = new uint[uint][](Nseg + 1);

        // task 0458 Phase 3 (square): per ORIGINAL boundary edge, the split
        // point (if any) created near each of its two endpoints, keyed by
        // an ORDERED pair `(fromVertex<<32)|towardVertex` (NOT
        // `edgeKey`'s canonical min/max — a single edge has two
        // independent split points, one per direction, and this key
        // disambiguates which). Populated while a selected face builds its
        // own splits below; consumed afterward by the unselected-neighbour
        // absorption pass so the mesh stays watertight (findings.md §3).
        uint[ulong] squareSplitAt;

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
                    if (auto p = origV in sharedVertIdxByLevel[Nseg]) finalVerts[i] = *p;
                    else {
                        immutable uint nv = addVertex(finalPos[i]);
                        sharedVertIdxByLevel[Nseg][origV] = nv;
                        finalVerts[i] = nv;
                    }
                } else {
                    // Standalone (non-group-shared) corner: touched by only
                    // ONE selected face (`internalCnt==0`, so it never got a
                    // `sharedCornerPos` entry above) — also every corner when
                    // `group=false`.
                    //
                    // Task 0467 — WARPED-quad inset on an ISOLATED face. For a
                    // face with no group-internal edge (a single selected
                    // face, or any non-adjacent selected face — the regime the
                    // reported ~0.005–0.05 residual lives in, e.g. a beveled
                    // subdivided-cube face), the reference's `bevGenInset`
                    // places the inset corner by a mitered offset that stays
                    // IN THE TANGENT PLANE (⟂ the whole-face Newell normal) —
                    // `boundaryContourInset(eNext,ePrev, faceNormal, inset)`,
                    // plus `faceNormal·shift`. The pre-0467 `insetCorner`
                    // (`offsetMeet`) instead intersects the two offset lines
                    // along the corner's ACTUAL (tilted) edge directions, so
                    // on a non-planar quad the meet point slides OFF the
                    // tangent plane and picks up a spurious normal-direction
                    // component (the residual). rr/gdb + fresh capture
                    // (`poly_bevel_{W1,W2,W3}_warped_standalone*`, findings.md
                    // §6): `bevGenInset` fires per face-corner and its AVE_N
                    // here is the WHOLE-FACE normal, NOT a per-corner
                    // cross-product — bit-exact on all three warped oracles.
                    //
                    // Gated to (a) an ISOLATED face (`!faceGrouped[fi]`) —
                    // uses the WHOLE-FACE Newell normal for both the tangent
                    // plane and the shift. A GROUPED face's standalone corners
                    // are a DIFFERENT regime (`poly_bevel_{G2,G3}`): the same
                    // mitered offset but built around the corner's own
                    // per-corner normal `cn`, handled by the `faceGrouped[fi]`
                    // branch just below; (b) a genuinely non-planar corner
                    // (`cornerNormal != faceNormal`) so every FLAT-face bevel
                    // stays BYTE-IDENTICAL to the pre-0467 `offsetMeet` law;
                    // and (c) a well-conditioned miter (`boundaryContourInset`
                    // non-degenerate). Off any gate it is the unchanged old
                    // law.
                    immutable Vec3 cn = cornerNormalAt(cast(uint)fi, origV);
                    Vec3 bcOffset;
                    if (!faceGrouped[fi] && dot(cn, n) < 1.0f - 1e-6f &&
                        boundaryContourInset(origPos[(i + 1) % Nc]      - origPos[i],
                                             origPos[(i + Nc - 1) % Nc] - origPos[i],
                                             n, effInset, bcOffset)) {
                        finalPos[i] = origPos[i] + n * shift + bcOffset;
                    } else if (faceGrouped[fi] && dot(cn, n) < 1.0f - 1e-6f &&
                        boundaryContourInset(origPos[(i + 1) % Nc]      - origPos[i],
                                             origPos[(i + Nc - 1) % Nc] - origPos[i],
                                             cn, effInset, bcOffset)) {
                        // GROUPED-STANDALONE corner (parity task): a standalone
                        // corner (internalCnt==0) of a face that IS part of an
                        // adjacent group (`faceGrouped[fi]`). Measured against
                        // the reference dumps (`poly_bevel_{G2,G3}`), this
                        // regime uses the SAME mitered-corner offset as the
                        // isolated branch above, but built around the corner's
                        // OWN (per-corner) shift normal `cn` — NOT the
                        // whole-face Newell normal `n`. Both the tangent plane
                        // fed to `boundaryContourInset` and the shift direction
                        // use `cn`. Bit-exact (< 1e-6) against every diverging
                        // standalone vertex in both dumps (G2 orig 1/3/5;
                        // G3 orig 0/1/3/5/6); the whole-face-`n` variant of
                        // this same offset is measurably worse there, so the
                        // per-corner normal is the discriminated law. Gated on
                        // a genuinely non-planar corner (`dot(cn,n) < 1-eps`)
                        // so every FLAT grouped face (cube corner, tent, square,
                        // segments) where `cn==n` stays BYTE-IDENTICAL to the
                        // old `offsetMeet` law, and on a well-conditioned miter.
                        finalPos[i] = origPos[i] + cn * shift + bcOffset;
                    } else {
                        finalPos[i] = insetCorner(origPos, i, n, effInset) + n * shift;
                    }
                    finalVerts[i] = addVertex(finalPos[i]);
                }
            }

            // Intermediate segment rings: t=0 is the original boundary,
            // t=Nseg is finalVerts; t=1..Nseg-1 are new equal-lerp rings.
            // A group-shared corner (origV has a sharedCornerPos entry) is
            // memoized per ring level too — `poly_bevel_S1_group_segs2`
            // (task 0458 +S1): the reference shares the SAME intermediate
            // vertex across both faces at a grouped corner, not just the
            // final one. A standalone corner (no sharedCornerPos entry) is
            // touched by only one face anyway, so "per-face" and "shared"
            // coincide there — unchanged, always a fresh vertex per ring.
            uint[][] ringVerts = new uint[][](Nseg + 1);
            ringVerts[0]    = origFaceVerts.dup;
            ringVerts[Nseg] = finalVerts;
            foreach (t; 1 .. Nseg) {
                uint[] ring = new uint[](Nc);
                immutable float f = cast(float)t / cast(float)Nseg;
                foreach (i; 0 .. Nc) {
                    immutable uint origV = origFaceVerts[i];
                    if (group && (origV in sharedCornerPos) !is null) {
                        if (auto p = origV in sharedVertIdxByLevel[t]) ring[i] = *p;
                        else {
                            immutable uint nv = addVertex(origPos[i] + (finalPos[i] - origPos[i]) * f);
                            sharedVertIdxByLevel[t][origV] = nv;
                            ring[i] = nv;
                        }
                    } else {
                        ring[i] = addVertex(origPos[i] + (finalPos[i] - origPos[i]) * f);
                    }
                }
                ringVerts[t] = ring;
            }

            // task 0458 Phase 3 (square): per-corner classification + the
            // two new split points on a STANDALONE corner's own two
            // original boundary edges (findings.md §3). A RIDGE corner
            // (group-shared, `sharedCornerPos`) gets neither — see the
            // function's own doc comment above for the full rule.
            uint[] splitToNext, splitToPrev;
            bool[] isRidgeCorner;
            // 0458 Phase-3 hardening (reviewer SHOULD-FIX): a zero effective
            // inset (inset=0 with shift>0 — reachable via the square UI toggle)
            // gives splitStep=0, collapsing the split points onto the corner →
            // degenerate zero-area caps + duplicate-vertex n-gons. Gate the WHOLE
            // square path on a non-degenerate inset so it falls back to the plain
            // (square=false) ring treatment there.
            immutable bool doSquare = square && effInset > 1e-6f;
            if (doSquare) {
                splitToNext   = new uint[](Nc);
                splitToPrev   = new uint[](Nc);
                isRidgeCorner = new bool[](Nc);
                immutable float splitStep = effInset / cast(float)Nseg;
                foreach (i; 0 .. Nc) {
                    immutable uint origV = origFaceVerts[i];
                    isRidgeCorner[i] = group && (origV in sharedCornerPos) !is null;
                    if (isRidgeCorner[i]) continue;
                    immutable int nxt = (i + 1) % Nc;
                    immutable int prv = (i + Nc - 1) % Nc;
                    immutable Vec3 dirNext = safeNormalize(origPos[nxt] - origPos[i]);
                    immutable Vec3 dirPrev = safeNormalize(origPos[prv] - origPos[i]);
                    splitToNext[i] = addVertex(origPos[i] + dirNext * splitStep);
                    splitToPrev[i] = addVertex(origPos[i] + dirPrev * splitStep);
                    squareSplitAt[(cast(ulong)origV << 32) | origFaceVerts[nxt]] = splitToNext[i];
                    squareSplitAt[(cast(ulong)origV << 32) | origFaceVerts[prv]] = splitToPrev[i];
                }
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
                    immutable ulong key = edgeKey(origFaceVerts[i], origFaceVerts[next]);
                    if (internalEdgeSet.get(key, false)) continue; // internal — dissolves, no bridge
                }
                if (doSquare) {
                    // Outermost (t=0) bridge is replaced by the square
                    // edge-panel; deeper segment rings (t=1..Nseg-1) stay
                    // plain, unchanged (Q3 finding — square wraps only the
                    // outermost ring).
                    immutable uint pointAtI    = isRidgeCorner[i]
                        ? origFaceVerts[i] : splitToNext[i];
                    immutable uint pointAtNext = isRidgeCorner[next]
                        ? origFaceVerts[next] : splitToPrev[next];
                    addFace([pointAtI, pointAtNext, ringVerts[1][next], ringVerts[1][i]]);
                    foreach (t; 1 .. Nseg)
                        addFace([ringVerts[t][i],     ringVerts[t][next],
                                 ringVerts[t+1][next], ringVerts[t+1][i]]);
                } else {
                    foreach (t; 0 .. Nseg)
                        addFace([ringVerts[t][i],     ringVerts[t][next],
                                 ringVerts[t+1][next], ringVerts[t+1][i]]);
                }
            }
            if (doSquare) {
                // Quad cap per STANDALONE corner only — a ridge corner's
                // neighbourhood is already closed by the two edge-panels
                // above meeting at the original vertex (Q4 finding).
                foreach (i; 0 .. Nc)
                    if (!isRidgeCorner[i])
                        addFace([origFaceVerts[i], splitToNext[i],
                                 ringVerts[1][i],   splitToPrev[i]]);
            }
            // Ring quads inherit Subpatch from the beveled source face.
            resizeSubpatch();
            foreach (rfi; ringStart .. faces.length) setFaceSubpatch(rfi, srcSub);
            ++processed;
        }
        if (processed == 0) return 0;
        if (square && squareSplitAt.length > 0) {
            // Splice each surviving split point into the UNSELECTED face
            // sharing that original edge, so the mesh stays watertight (no
            // T-junction) — task 0458 Phase 3, findings.md §3. Only
            // ORIGINAL (pre-op) faces can need this; a face already
            // rebuilt above (`mask[fi]`) holds its own new ring/final
            // verts already, not the original boundary, and is skipped.
            foreach (fi; 0 .. nFaces) {
                if (fi < mask.length && mask[fi]) continue;
                const uint[] cur = faces[fi];
                immutable int N = cast(int)cur.length;
                if (N < 3) continue;
                uint[] rebuilt;
                foreach (k; 0 .. N) {
                    immutable uint a = cur[k], b = cur[(k + 1) % N];
                    rebuilt ~= a;
                    if (auto p = ((cast(ulong)a << 32) | b) in squareSplitAt) rebuilt ~= *p;
                    if (auto p2 = ((cast(ulong)b << 32) | a) in squareSplitAt) rebuilt ~= *p2;
                }
                faces[fi] = rebuilt;
            }
        }
        // Parity (fuzz D3): a positive inset clamped to `maxSafeUniformInset`
        // lands the cap ring AT the collapse point — several (or all) cap
        // corners coincide (a square face → all four onto the centroid). The
        // reference KEEPS that as a degenerate quad ring: the coincident
        // corners stay DISTINCT referenced verts, so the cap and every ring
        // quad remain 4-vertex (zero-area) faces rather than being welded
        // down + fan-triangulated. We therefore do NOT weld the clamped
        // pass — the ring quads/cap the loop already emitted are exactly the
        // reference topology (byte-verified against the fuzz repro's
        // 12v/10f all-quad dump). A non-clamped bevel never reaches here
        // (`anyClamped` stays false), so normal poly-bevel is byte-identical.
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
    size_t spikeFacesByMask(const bool[] maskIn, float amount) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
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

    /// True when vertex `vi`'s dart fan enumerates in a meaningful cyclic
    /// ORDER and the twin-walk visits it completely (task 0447:
    /// doc/vertex_fan_walk_foreign_edge_plan.md). False when the fan rests on
    /// a same-direction shared edge (inconsistent winding) — such a vertex is
    /// served by the CSR fallback (complete, arbitrary order), and
    /// slot-position consumers (`bevelEdgesByMask`,
    /// `symmetry.rebuildPairingTopological`) must check this and decline
    /// rather than trust slot k. Keyed STRICTLY on same-directionness, NOT on
    /// the overloaded `twin==~0u` sentinel: a genuine non-manifold ("book")
    /// vertex (meaning-2) stays ordered, so its twin-walk still truncates at
    /// the boundary-like edge under treatment A (it does NOT trip the CSR
    /// fallback). Backed by a persistent per-vertex bool array rebuilt in
    /// `buildLoops` — O(1).
    bool vertexFanOrdered(uint vi) const {
        return vi >= vertFanOrdered_.length || vertFanOrdered_[vi];
    }

    /// Return a range over all vertices directly connected to vertex `vi` by an edge.
    VertexNeighborRange verticesAroundVertex(uint vi) const {
        uint first = (vi < vertLoop.length) ? vertLoop[vi] : ~0u;
        // Task 0447: an unordered fan (rests on a same-direction edge) cannot
        // be trusted to the twin-walk — enumerate it completely from the CSR.
        if (vi < vertices.length && !vertexFanOrdered(vi))
            return VertexNeighborRange.fromCsr(loops, vertDartStart, vertDartAdj, vi);
        return VertexNeighborRange(loops, first);
    }

    /// Return a range over all edge indices incident to vertex `vi`.
    /// Correctly handles boundary vertices: emits the extra boundary edge at the end.
    /// Requires buildLoops() to have been called (uses vertLoop and loopEdge).
    VertexEdgeRange edgesAroundVertex(uint vi) const {
        uint first = (vi < vertLoop.length) ? vertLoop[vi] : ~0u;
        if (vi < vertices.length && !vertexFanOrdered(vi))
            return VertexEdgeRange.fromCsr(loops, loopEdge, vertDartStart, vertDartAdj, vi);
        return VertexEdgeRange(loops, loopEdge, first);
    }

    /// Return a range over all faces incident to vertex `vi`.
    VertexFaceRange facesAroundVertex(uint vi) const {
        uint first = (vi < vertLoop.length) ? vertLoop[vi] : ~0u;
        if (vi < vertices.length && !vertexFanOrdered(vi))
            return VertexFaceRange.fromCsr(loops, vertDartStart, vertDartAdj, vi);
        return VertexFaceRange(loops, first);
    }

    /// Return a range over the 1–2 faces incident to edge `ei`.
    ///
    /// MANIFOLD ONLY, and the "1–2" above is a hard ceiling, not a typical
    /// case: this walks the half-edge rings, which have no representation for
    /// a NON-MANIFOLD fan. Probed on three quads sharing one edge, the range
    /// yields ONE face — not three, and not even two. So `n >= 2` over this
    /// range is NOT "is this edge interior": a non-manifold edge reads as a
    /// border edge, silently and with no diagnostic.
    ///
    /// Repairing the rings is a `buildLoops`/dart-representation change and is
    /// deliberately not attempted here. Any caller that needs a COUNT — rather
    /// than "give me a neighbouring face" — must use `edgePolygonCounts`
    /// below, which counts straight off `faces[]` and cannot undercount.
    EdgeFaceRange facesAroundEdge(uint ei) const {
        return EdgeFaceRange(loops, edges, vertLoop, vertFanOrdered_,
                             vertDartStart, vertDartAdj, ei);
    }

    /// How many polygons border each edge, BY EDGE INDEX — counted straight
    /// off `faces[]`, so a non-manifold fan is reported at its true size (3
    /// quads sharing an edge give 3) and a bare wire edge gives 0.
    ///
    /// The truthful counterpart to `facesAroundEdge` (whose ring walk cannot
    /// witness a third incident polygon — see its note) and to
    /// `buildEdgeFaces` (whose two-slot `int[2]` cannot even store one). Use
    /// this whenever the QUESTION is a count or a threshold — "exactly two",
    /// "at least two", "zero" — and reserve the ring walk for "hand me a
    /// neighbouring face".
    ///
    /// O(E + Σ face arity), one pass, and independent of `edgeIndexMap`'s
    /// validity stamp: the key→index table is built from `edges[]` right here,
    /// so this is safe to call mid-op, before a `buildLoops()` has re-stamped
    /// the map. Returns a zero-filled `int[edges.length]` when there are no
    /// faces (every edge is then a wire, and 0 is the true answer).
    int[] edgePolygonCounts() const {
        auto n = new int[](edges.length);
        if (edges.length == 0 || faces.length == 0) return n;
        uint[ulong] idx;
        foreach (i; 0 .. edges.length)
            idx[edgeKey(edges[i][0], edges[i][1])] = cast(uint)i;
        foreach (ref f; faces)
            foreach (k; 0 .. f.length)
                if (auto p = edgeKey(f[k], f[(k + 1) % f.length]) in idx)
                    ++n[*p];
        return n;
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
        foreach (i, mk; marks) {
            if (mk & Marks.Select) mix(cast(ulong)i + 1);
            // R6 (task 0613). Once the whole-mesh fallback means "all VISIBLE"
            // (§3.2), hiding element i changes the operand set of an
            // empty-selection op WITHOUT changing its selection — so a
            // Select-only signature leaves the falloff / action-centre caches
            // stale. Folded with a DISTINCT mix value so hiding i and
            // selecting i cannot collide: selecting mixes (i+1), hiding mixes
            // (i+1) | (1UL << 63), a bit no index can reach.
            if (mk & Marks.Hide)   mix((cast(ulong)i + 1) | (1UL << 63));
        }
        return h;
    }

    /// Return the vertex indices touched by the current vertex selection.
    /// If nothing is selected, returns every VISIBLE vertex index (§3.2 shape
    /// A, task 0613 — the whole-mesh fallback means "all visible", never "all";
    /// the selected branch needs no filter because §3.1's Select ∧ Hide = ∅
    /// invariant makes a hidden vertex unselectable).
    int[] selectedVertexIndicesVertices() const {
        int[] idx;
        if (hasAnySelectedVertices()) {
            foreach (i; 0 .. vertices.length)
                if (isVertexSelected(i)) idx ~= cast(int)i;
        } else {
            foreach (i; 0 .. vertices.length)
                if (!isVertexHidden(i)) idx ~= cast(int)i;
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
                ulong key = edgeKey(f[k], f[(k+1) % f.length]);
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
                ulong key = edgeKey(f[k], f[(k + 1) % f.length]);
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

    /// Opposite endpoints of every edge in `edges[]` incident to `v` — a raw
    /// scan of the flat edge array (task 0477, topology-pen P3 KILLER-1),
    /// UNLIKE `edgesAroundVertex`/`vertexValence` above, which walk the
    /// half-edge fan seeded from `vertLoop[v]`. `vertLoop` is populated ONLY
    /// from `faces[]` (`buildLoops`'s vert-loop seed pass walks face
    /// corners), so a vertex that sits on a bare floating edge but no face at
    /// all keeps `vertLoop[v] == ~0u` and every loop-fan helper reads it as
    /// isolated/degree-0 — even though `edges[]` genuinely lists an edge
    /// touching it. This is the ONLY correct way to test "does this vertex
    /// have an incident edge" when floating (non-face-bounded) edges are in
    /// play — e.g. topology-pen's bare `addEdge` build case, which the
    /// loop-fan helpers cannot see. O(E); fine for an interactive retopo
    /// cage, not intended for hot per-frame loops over large meshes.
    uint[] edgeNeighbors(uint v) const {
        uint[] r;
        foreach (e; edges) {
            if (e[0] == v) r ~= e[1];
            else if (e[1] == v) r ~= e[0];
        }
        return r;
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
                    const ulong key = edgeKey(face[k], face[(k + 1) % n]);
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
    /// If nothing is selected, returns every VISIBLE vertex index (§3.2 shape
    /// A, task 0613 — see selectedVertexIndicesVertices above).
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
            foreach (i; 0 .. vertices.length)
                if (!isVertexHidden(i)) idx ~= cast(int)i;
        }
        return idx;
    }

    /// Return the vertex indices touched by the current face selection.
    /// Each vertex is included at most once.
    /// If nothing is selected, returns every VISIBLE vertex index (§3.2 shape
    /// A, task 0613 — see selectedVertexIndicesVertices above).
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
            foreach (i; 0 .. vertices.length)
                if (!isVertexHidden(i)) idx ~= cast(int)i;
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
    /// polygon strictly nearer the eye than the vertex, the vertex is hidden
    /// behind that face — unless it sits ON the crossing, within a tolerance
    /// relative to its own coordinates. The exact clauses, and which of them
    /// is a static read, are spelled out at the depth gate in pass 2 below.
    /// Used by the snap service so it never cements to elements behind opaque
    /// geometry — including disjoint mesh components in the same Mesh struct
    /// (cube + cube, cube + cylinder, etc.).
    ///
    /// `vp` is used to prune occluder candidates by screen-space bbox: a face
    /// can occlude a vertex only if the vertex's projected pixel falls inside
    /// the face's screen bounding rectangle. For scenes with non-overlapping
    /// components (the common case) this drops the cost from O(V·F) toward
    /// O(V + F). Inside the bbox, point-in-polygon and the depth check are
    /// done in screen space (using already-projected face corners), avoiding
    /// the per-iteration 3D-to-2D dominant-axis projection of the original
    /// implementation.
    // Task 0617 Stage 4: `ms` is the caller's `ModelSpace` for THIS mesh
    // (identity for a plain call). `vertices[]` stays local/unchanged
    // throughout — cheaper than transforming every vertex to world, and
    // correct because every quantity this function actually COMPARES is
    // either a pure forward projection (exact under composition, §3.3) or
    // a ray/plane intersection PARAMETER `t` along a single eye->candidate
    // ray, which an invertible affine map preserves exactly (the same
    // reason `bvh_pick` leaves a ray's `t` alone, §3.4 of the plan) — so
    // running pass 2's occlusion depth-gate entirely in LOCAL space (local
    // eye, local vertices, local plane normals) reaches the same cull
    // decisions as running it in world space would. Pass 1's front-facing
    // SIGN test at the cull below needs no `ms.mirrored` correction either:
    // `localEye` is already `M⁻¹·eye`, which alone answers "is the eye on
    // the outward side" correctly for any invertible `M` — see
    // `ModelSpace.mirrored`'s doc comment in math.d for the identity.
    bool[] visibleVertices(Vec3 eye, const ref Viewport vp, const ModelSpace ms) const {
        import math : pointInPolygon2D, projectToWindowFull, projectionSpace, ModelSpace;
        import std.math : abs, sqrt;

        bool[] vis = new bool[](vertices.length);
        if (vertices.length == 0 || faces.length == 0) return vis;

        const Viewport vpLocal = projectionSpace(vp, ms);
        const Vec3 localEye = ms.isIdentity ? eye : ms.toLocalPoint(eye);

        // Project every vertex once. Behind-camera verts get vsValid=false
        // and skip both candidate selection and occluder polygon membership.
        auto vsx     = new float[](vertices.length);
        auto vsy     = new float[](vertices.length);
        auto vsZ     = new float[](vertices.length);
        auto vsValid = new bool [](vertices.length);
        foreach (vi, q; vertices) {
            float sx, sy, ndcZ;
            if (projectToWindowFull(q, vpLocal, sx, sy, ndcZ)) {
                vsx[vi] = sx; vsy[vi] = sy; vsZ[vi] = ndcZ;
                vsValid[vi] = true;
            }
        }

        // Pass 1: collect front-facing faces with cached screen polygons +
        // bboxes, and seed the visibility mask.
        // The plane normal and the front-facing dot are carried in DOUBLE.
        // The depth half of this gate compares against a coincidence tolerance
        // of ~2.98e-7 RELATIVE to the candidate's largest coordinate (see
        // below) — about 2.5 float32 ulps. In float arithmetic the ray-plane
        // solve's own rounding is the same size as that tolerance, so the
        // exemption would be decided by noise; positions stay float (the
        // reference's candidate positions arrive on a float32 grid too), only
        // the arithmetic is widened.
        struct FrontFace {
            uint      fi;
            double[3] n;           // face plane normal (un-normalised, fine for ray-plane)
            float     minX, maxX, minY, maxY;
            float[]   sxs, sys;    // screen-space corner positions
        }
        static double[3] planeNormal(Vec3 a, Vec3 b, Vec3 c) {
            const double ux = cast(double)b.x - a.x, uy = cast(double)b.y - a.y,
                         uz = cast(double)b.z - a.z;
            const double vx = cast(double)c.x - a.x, vy = cast(double)c.y - a.y,
                         vz = cast(double)c.z - a.z;
            return [uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx];
        }
        static double dotD(const double[3] n, double x, double y, double z) {
            return n[0] * x + n[1] * y + n[2] * z;
        }
        FrontFace[] front;
        front.reserve(faces.length);
        foreach (fi, ref face; faces) {
            if (face.length < 3) continue;
            // Hide (task 0613 S4) — a hidden face is not drawn, so it must
            // neither SEED visibility for its corners (the `vis[vi] = true`
            // below) nor OCCLUDE anything behind it (pass 2 walks `front`).
            // One `continue` delivers both, and it is the only Hide read this
            // function needs:
            //   * a vertex whose incident faces are ALL hidden is exactly the
            //     derived-hidden rule (§1.2), and none of them seeds it, so it
            //     comes out false without a separate `isVertexHidden` sweep —
            //     a sweep here would be inert, and an inert guard is a guard
            //     nobody can test;
            //   * a hidden EDGE has a hidden endpoint by the same rule, so
            //     `edgeVisible` in snap.d falls out too;
            //   * a loose vertex is in no face, so it is never seeded true.
            // A hidden face's corners that ALSO touch a visible face stay
            // visible, which is right: they are on screen, drawn by that face.
            if (isFaceHidden(fi)) continue;
            double[3] fn = planeNormal(vertices[face[0]], vertices[face[1]],
                                       vertices[face[2]]);
            {
                Vec3 p0 = vertices[face[0]];
                bool backFacing = dotD(fn, cast(double)p0.x - localEye.x,
                                           cast(double)p0.y - localEye.y,
                                           cast(double)p0.z - localEye.z) >= 0;
                if (backFacing) continue;
            }
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
        // point-in-polygon, then the depth gate below. Faces that own the
        // vertex are skipped — their plane passes through it.
        //
        // ---------------------------------------------------------------
        // The depth gate. Ported from the reference, which was measured
        // bit-exactly over 501 candidate evaluations with zero violations
        // (task 0534). Naming the three clauses in its own terms:
        //
        //   O = the eye, C = the candidate, H = where the pick ray meets the
        //   occluder's surface.
        //
        //   1. COINCIDENCE EXEMPTION — keep when |H - C| <= tol(C), where
        //      tol(C) = max(maxabs(C) / 3_360_000, 1e-10). The tolerance is
        //      RELATIVE to the candidate's own largest coordinate (≈ 2.976e-7
        //      of it, ≈ 2.5 float32 ulps) — NOT to the camera distance — and
        //      it SHORT-CIRCUITS the depth compare. It answers "is this
        //      candidate the very point the ray hit", nothing else.
        //   2. DEPTH COMPARE — cull iff |O - C| > |O - H|, strictly. Euclidean
        //      along the ray, with NO epsilon of its own.
        //   3. Equality keeps: at |O - C| == |O - H| the candidate is offered.
        //
        // Clause 3 is the ONE clause with no live confirmation, and that is a
        // property of the measurement rather than a gap to close: the
        // reference's candidate positions arrive on a float32 grid 1.4e6
        // times coarser than the ulp of the double they are compared against,
        // so an exact tie cannot be constructed by placing geometry at all.
        // The DIRECTION is confirmed (501 evaluations, 0 violations); only the
        // last ulp is a static read. Here it is doubly unobservable: our ray
        // is cast THROUGH the candidate, so |O - C| == |O - H| implies H == C
        // and clause 1 always fires first. It is written as `>= 0` anyway, so
        // the boundary sits where the reference puts it.
        //
        // What this replaced: a `1e-4` relative epsilon ON THE DEPTH COMPARE
        // ITSELF (`t >= 1 - OCCL_EPS` kept). That was the wrong quantity — the
        // reference puts no tolerance on the compare — and, read even as a
        // relative tolerance, ~300x looser than the coincidence constant.
        //
        // NOT ported here, and deliberately: the occluder SET. This walk still
        // occludes only within one mesh, and skips per-FACE ownership; the
        // reference occludes across every visible non-marked item and exempts
        // per-ITEM. That is a separate and much wider behaviour change (it
        // moves what every snap client sees); see task 0539.
        // ---------------------------------------------------------------
        enum double COINCIDENCE_DIVISOR = 3_360_000.0;
        enum double COINCIDENCE_FLOOR   = 1e-10;
        foreach (vi; 0 .. vertices.length) {
            if (!vis[vi] || !vsValid[vi]) continue;
            float vsxi = vsx[vi], vsyi = vsy[vi];
            Vec3  vpos = vertices[vi];
            const double cx = vpos.x, cy = vpos.y, cz = vpos.z;
            const double dirX = cx - localEye.x, dirY = cy - localEye.y, dirZ = cz - localEye.z;
            const double lenDir = sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ);

            // tol(C) = max(maxabs(C) / 3_360_000, 1e-10) — relative to the
            // CANDIDATE's largest coordinate, so it is a constant of this
            // vertex and is hoisted out of the occluder walk.
            double maxAbsC = abs(cx);
            if (abs(cy) > maxAbsC) maxAbsC = abs(cy);
            if (abs(cz) > maxAbsC) maxAbsC = abs(cz);
            double tol = maxAbsC / COINCIDENCE_DIVISOR;
            if (tol < COINCIDENCE_FLOOR) tol = COINCIDENCE_FLOOR;

            foreach (ref ff; front) {
                if (vsxi < ff.minX || vsxi > ff.maxX ||
                    vsyi < ff.minY || vsyi > ff.maxY) continue;

                const(uint)[] face = faces[ff.fi];
                bool ownsVi = false;
                foreach (v; face) if (v == vi) { ownsVi = true; break; }
                if (ownsVi) continue;

                if (!pointInPolygon2D(vsxi, vsyi, ff.sxs, ff.sys)) continue;

                const double denom = dotD(ff.n, dirX, dirY, dirZ);
                if (abs(denom) < 1e-9) continue;   // ray parallel to the plane
                Vec3 p0 = vertices[face[0]];
                const double t = dotD(ff.n, cast(double)p0.x - localEye.x,
                                            cast(double)p0.y - localEye.y,
                                            cast(double)p0.z - localEye.z) / denom;
                if (t <= 0.0) continue;            // no hit in front of the eye

                // t - 1, formed as dot(n, p0 - C)/denom rather than by
                // subtracting 1 from t: the subtraction cancels catastrophically
                // exactly where the exemption is decided (t within 1e-8 of 1).
                const double tm1 = dotD(ff.n, cast(double)p0.x - cx,
                                              cast(double)p0.y - cy,
                                              cast(double)p0.z - cz) / denom;

                // |H - C| = |t - 1| * |C - O|, since H = O + t*(C - O).
                if (abs(tm1) * lenDir <= tol) continue;   // clause 1
                if (tm1 >= 0.0) continue;                 // clauses 2 + 3

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

    // -----------------------------------------------------------------------
    // select.loop (edge) — recovered-algorithm helper (task 0457)
    // -----------------------------------------------------------------------
    // The bare "select.loop" edge command reproduces the reference tool's
    // recovered behavior, which is a strictly richer superset of the plain
    // quad edge-strip walk above (`walkEdgeLoop`): for a REGULAR seed edge
    // (both incident faces are quads, and neither hop lands on a valence
    // irregularity or a boundary-adjacent vertex) it degenerates to exactly
    // that walk run from each incident face and combined — so the two are
    // deliberately layered rather than merged: `walkEdgeLoop` stays untouched
    // for its other ordered-walk consumers (`select.more`, `select.between`,
    // support-loop candidate generation), and `selectLoopEdges` composes it
    // with the extra branches below. Provenance/validation:
    // `toolcards/select.loop/findings.md` (private).

    /// True if edge `ei` sits on an open boundary of the CURRENT face set —
    /// exactly one incident face. Purely topological (face-count), matching
    /// the recovered border predicate; deliberately NOT a material/UV-seam
    /// classifier (a distinct, unrelated family ruled out during recovery).
    bool isEdgeBorder(uint ei) const {
        uint n = 0;
        foreach (fi; facesAroundEdge(ei)) { ++n; if (n > 1) break; }
        return n == 1;
    }

    /// True if vertex `vi` touches at least one border edge (`isEdgeBorder`).
    bool isVertexBorder(uint vi) const {
        foreach (ei; edgesAroundVertex(vi))
            if (isEdgeBorder(ei)) return true;
        return false;
    }

    /// Count of border edges (`isEdgeBorder`) incident to vertex `vi`.
    uint borderEdgeCountAtVertex(uint vi) const {
        uint n = 0;
        foreach (ei; edgesAroundVertex(vi))
            if (isEdgeBorder(ei)) ++n;
        return n;
    }

    /// Return the OTHER edge of triangle `tri` that touches vertex `pivot`,
    /// excluding the edge with key `excludeKey` (the one just arrived on /
    /// the seed) — a triangle vertex touches exactly 2 of the triangle's 3
    /// edges, so this is unambiguous. Returns `~0u` if not found (defensive;
    /// shouldn't happen for a well-formed triangle touching `pivot`).
    private uint triangleOtherEdgeAt(const(uint)[] tri, uint pivot, ulong excludeKey) const {
        foreach (j; 0 .. 3) {
            uint va = tri[j], vb = tri[(j + 1) % 3];
            if (va != pivot && vb != pivot) continue;
            ulong k = edgeKey(va, vb);
            if (k == excludeKey) continue;
            uint ei = edgeIndexByKey(k);
            if (ei != ~0u) return ei;
        }
        return ~0u;
    }

    /// One direction of the recovered edge-loop walk: `seedEdge` combined
    /// with one of its (up to two) incident faces, `startFace`. Returns the
    /// ADDITIONAL edges this direction contributes (never includes the seed
    /// itself; empty means "this direction dead-ends at the seed").
    ///
    /// Gates mirror the recovered per-hop dispatch (findings.md
    /// the reference's loop next-edge dispatch), evaluated once using the seed's own hop pivot:
    ///   1. ANY odd valence at the pivot vertex while the seed is an
    ///      interior edge (2 incident faces) dead-ends this direction
    ///      outright — no floor. This fires just as readily on a plain
    ///      valence-3 vertex (every corner of an ordinary closed cube/box
    ///      is one) as on a valence-5 pole centre: a stock cube's edge-loop
    ///      is genuinely the 4-edge fallback face below, not a 7-edge union
    ///      of two adjacent perimeters — confirmed by a dedicated closed-
    ///      mesh capture (`cube_corner_edge0`) plus an rr/gdb trace of
    ///      the reference's loop next-edge dispatch reaching this exact bail with vcount=3,
    ///      incident-face-count==2 (see findings.md's Gate-1 section; an
    ///      earlier `>=5`-floor calibration here was an un-traced
    ///      hypothesis, since ruled out).
    ///   2. an even (>=4) valence pivot touching more than 2 border edges
    ///      also dead-ends (spec-complete; not exercised by the 11 cases).
    ///   3. a non-border seed whose pivot vertex is itself boundary-adjacent
    ///      dead-ends too — the rim-vertex direction of the same pole case.
    /// Past the gates, this steps quad-to-quad exactly like `walkEdgeLoop`
    /// (kept as a separate stepper, not a shared call, precisely so that
    /// helper stays byte-identical for its other ordered-walk consumers) —
    /// but reacts differently at a crossing that lands on an irregular face,
    /// wherever along the chain it occurs (rule 5 is not always the very
    /// first face touching the seed — a triangle can sit several quads in):
    ///   * a triangle succeeds exactly that ONE hop (the triangle's other
    ///     edge touching the current pivot) and stops — no further chaining,
    ///     no fallback.
    ///   * an n-gon (>=5 sides) fails outright from that point — whatever
    ///     was accumulated before it stands as this direction's result.
    int[] selectLoopDirectionEdges(uint seedEdge, uint startFace) const {
        if (startFace >= faces.length) return [];
        const sfv0 = faces[startFace];
        if (sfv0.length < 3) return [];
        int si = findEdgeInFace(startFace, edgeKeyOf(seedEdge));
        if (si < 0) return [];
        uint pivot0 = sfv0[(cast(uint)si + 1) % sfv0.length];

        uint vcount = vertexValence(pivot0);
        if ((vcount & 1) != 0) return [];                                // gate 1
        if (vcount >= 4 && borderEdgeCountAtVertex(pivot0) > 2) return [];// gate 2
        if (isVertexBorder(pivot0)) return [];                          // gate 3

        if (sfv0.length == 3) {
            uint ei = triangleOtherEdgeAt(sfv0, pivot0, edgeKeyOf(seedEdge));
            return ei != ~0u ? [cast(int)ei] : [];
        }
        if (sfv0.length != 4) return []; // n-gon immediately across the seed

        uint a = sfv0[si], b = pivot0;
        int curFace = cast(int)startFace;
        int[] res;
        bool[ulong] vis; vis[edgeKeyOf(seedEdge)] = true;
        while (true) {
            const face = faces[curFace];
            if (face.length != 4) break; // reached via `nf` below; already a quad here
            int jb = -1;
            foreach (j; 0 .. 4) if (face[j] == b) { jb = j; break; }
            if (jb < 0) break;
            uint prev = face[(jb - 1 + 4) % 4], next = face[(jb + 1) % 4], c;
            if      (prev == a) c = next;
            else if (next == a) c = prev;
            else break;
            uint sei = edgeIndex(b, c);
            if (sei == ~0u) break;
            int nf = adjacentFaceThrough(sei, cast(uint)curFace);
            if (nf < 0) break; // open boundary — natural terminating chain
            const nface = faces[nf];
            if (nface.length == 3) {
                uint ei = triangleOtherEdgeAt(nface, b, edgeKey(b, c));
                if (ei != ~0u) res ~= cast(int)ei;
                break;
            }
            if (nface.length != 4) break; // n-gon: fails outright from here
            int jb2 = -1;
            foreach (j; 0 .. 4) if (nface[j] == b) { jb2 = j; break; }
            if (jb2 < 0) break;
            uint p2 = nface[(jb2 - 1 + 4) % 4], n2 = nface[(jb2 + 1) % 4], d;
            if      (p2 == c) d = n2;
            else if (n2 == c) d = p2;
            else break;
            uint bd_ei = edgeIndex(b, d);
            if (bd_ei == ~0u) break;
            ulong ck = edgeKey(b, d);
            if (ck in vis) break; // closure
            vis[ck] = true;
            res ~= cast(int)bd_ei;
            a = b; b = d; curFace = nf;
        }
        return res;
    }

    /// Fallback shared by the two "both directions dead-ended at the seed"
    /// rules (an n-gon or a valence pole immediately across the seed): select
    /// every edge of the seed's own largest-vertex-count incident face, ties
    /// broken by whichever face is found first (i.e. `incFaces`' own order).
    int[] selectLoopFallbackFace(const(uint)[] incFaces) const {
        uint best = incFaces[0];
        foreach (fi; incFaces[1 .. $])
            if (faces[fi].length > faces[best].length) best = fi;
        const fv = faces[best];
        int[] result;
        bool[ulong] seen;
        foreach (j; 0 .. fv.length) {
            ulong k = edgeKey(fv[j], fv[(j + 1) % fv.length]);
            uint ei = edgeIndexByKey(k);
            if (ei == ~0u || (k in seen)) continue;
            seen[k] = true;
            result ~= cast(int)ei;
        }
        return result;
    }

    /// Rule 7: `seedEdge` is itself on an open boundary — chain along the
    /// boundary loop instead of the regular quad-opposite walk. From each
    /// endpoint in turn, repeatedly hop to another border edge at the far
    /// vertex (excluding the edge just arrived on) until either a dead end
    /// (no other border edge there) or closure (the far vertex lands back on
    /// one of the seed's own two endpoints — the boundary loop is closed).
    /// Closure stops the walk immediately and skips the second endpoint
    /// entirely, matching the recovered algorithm's "combine, don't restart"
    /// closure behavior (also used by the plain quad walk above).
    int[] selectLoopBorderChain(uint seedEdge) const {
        uint u = edges[seedEdge][0], v = edges[seedEdge][1];

        struct ChainResult { int[] edges; bool closed; }
        ChainResult chainFrom(uint from) {
            int[] res;
            bool[ulong] vis; vis[edgeKeyOf(seedEdge)] = true;
            uint cur = from;
            uint lastEdge = seedEdge;
            while (true) {
                int next = -1;
                foreach (ei; edgesAroundVertex(cur)) {
                    if (ei == lastEdge) continue;
                    ulong k = edgeKeyOf(ei);
                    if (k in vis) continue;
                    if (!isEdgeBorder(ei)) continue;
                    next = cast(int)ei;
                    break;
                }
                if (next < 0) return ChainResult(res, false);
                vis[edgeKeyOf(cast(uint)next)] = true;
                res ~= next;
                uint a = edges[next][0], b = edges[next][1];
                uint far = (a == cur) ? b : a;
                if (far == u || far == v) return ChainResult(res, true);
                cur = far;
                lastEdge = cast(uint)next;
            }
        }

        auto dirV = chainFrom(v);
        int[] result = [cast(int)seedEdge] ~ dirV.edges;
        if (dirV.closed) return result;

        auto dirU = chainFrom(u);
        bool[ulong] seen;
        foreach (ei; result) seen[edgeKeyOf(cast(uint)ei)] = true;
        foreach (ei; dirU.edges) {
            ulong k = edgeKeyOf(cast(uint)ei);
            if (k in seen) continue;
            seen[k] = true;
            result ~= ei;
        }
        return result;
    }

    /// Recovered `select.loop` (edge) algorithm — the single entry point
    /// `commands/select/loop.d`'s edge branch calls per initially-selected
    /// seed edge. See findings.md (private) for the full per-rule provenance
    /// and the 11-case validation this reproduces bit-exact.
    int[] selectLoopEdges(uint seedEdge) const {
        if (seedEdge >= edges.length) return [];

        uint[] incFaces;
        foreach (fi; facesAroundEdge(seedEdge)) incFaces ~= fi;

        if (incFaces.length == 0) return [cast(int)seedEdge]; // stray/degenerate edge
        if (incFaces.length == 1) return selectLoopBorderChain(seedEdge); // rule 7

        bool anyHops = false;
        int[][] dirResults = new int[][](incFaces.length);
        foreach (i, fi; incFaces) {
            dirResults[i] = selectLoopDirectionEdges(seedEdge, fi);
            if (dirResults[i].length > 0) anyHops = true;
        }

        if (!anyHops) return selectLoopFallbackFace(incFaces); // rules 4 & 6

        bool[ulong] seen;
        int[] result;
        void add(int ei) {
            ulong k = edgeKeyOf(cast(uint)ei);
            if (k in seen) return;
            seen[k] = true;
            result ~= ei;
        }
        add(cast(int)seedEdge);
        foreach (dr; dirResults) foreach (ei; dr) add(ei);
        return result;
    }

    // -----------------------------------------------------------------------
    // select.loop (vertex) — recovered-algorithm helper (task 0390)
    // -----------------------------------------------------------------------
    // The bare "select.loop" vertex command reproduces the reference's
    // recovered behavior (toolcards/select.loop/findings_fv.md, private —
    // rr/gdb live-validated). It shares edge mode's per-hop
    // dispatch (odd-valence gate, quad fan step, triangle special case,
    // n-gon failure) but with the two context flags the vertex path zeroes:
    // there is NO boundary-adjacent-vertex early-exit (boundary endpoints
    // are INCLUDED in the loop), and a hop whose current edge is a border
    // edge routes into a border-chain continuation instead of the regular
    // fan walk. The seed must be an adjacent selected vertex PAIR; a lone
    // selected vertex (or none, or no adjacent pair) yields an empty
    // result — the command REPLACES the selection wholesale (the reference
    // purges unconditionally, then commits), which is exactly how "single
    // vertex clears the selection" falls out. There is no fallback face in
    // vertex mode (unlike edge mode). Hidden/locked elements are
    // unmodelled (Marks.Hide/Lock are reserved/unused). Layered next to —
    // not merged into — `walkVertexLoop`, which stays untouched for its
    // ordered-walk consumers.

    /// Full per-edge / per-vertex incidence for the select.loop recovered
    /// algorithms (reference incidence-list semantics). Deliberately NOT
    /// the half-edge
    /// fan-walk helpers (`facesAroundVertex`/`edgesAroundVertex`/
    /// `facesAroundEdge`): those truncate at non-manifold ("bowtie")
    /// vertices and non-manifold edges, while the reference's incidence
    /// cache always returns the complete star. Fuzz repro
    /// fz_sloop_v_pole_tri2_hole2_0021 (a bowtie seed vertex) pinned this.
    /// `wantVertexStars = false` builds ONLY `edgeFaces` and leaves the two
    /// per-vertex stars null — the polygon walk reads neither, and they are
    /// the larger two thirds of the build (one appended slice per vertex of
    /// every face, plus one per edge endpoint). Use `buildLoopEdgeFaces`.
    private void buildLoopIncidence(out uint[][] vertEdges, out uint[][] edgeFaces,
                                    out uint[][] vertFaces,
                                    bool wantVertexStars = true) const {
        if (wantVertexStars) {
            vertEdges = new uint[][](vertices.length);
            foreach (ei; 0 .. edges.length) {
                vertEdges[edges[ei][0]] ~= cast(uint)ei;
                vertEdges[edges[ei][1]] ~= cast(uint)ei;
            }
            vertFaces = new uint[][](vertices.length);
        }
        edgeFaces = new uint[][](edges.length);
        foreach (fi; 0 .. faces.length) {
            const f = faces[fi];
            if (wantVertexStars)
                foreach (fv; f)
                    if (fv < vertices.length) vertFaces[fv] ~= cast(uint)fi;
            foreach (j; 0 .. f.length) {
                uint ei = edgeIndex(f[j], f[(j + 1) % f.length]);
                if (ei == ~0u) continue;
                if (edgeFaces[ei].length == 0 || edgeFaces[ei][$ - 1] != fi)
                    edgeFaces[ei] ~= cast(uint)fi;
            }
        }
    }

    /// The edge→faces half of `buildLoopIncidence` — all the polygon
    /// select.loop walk consumes.
    private void buildLoopEdgeFaces(out uint[][] edgeFaces) const {
        uint[][] ve, vf;
        buildLoopIncidence(ve, edgeFaces, vf, /*wantVertexStars*/ false);
    }

    /// Return a face from `edgeFaces[ei]` whose winding contains the
    /// directed edge `a`→`b` consecutively, or -1. Used to re-derive the
    /// walking face after a border-chain/trivial hop (the reference
    /// re-picks the face per hop from (edge, side) by winding).
    private int windingFaceFor(const(uint)[] incFaces, uint a, uint b) const {
        foreach (fi; incFaces) {
            const f = faces[fi];
            foreach (j; 0 .. f.length)
                if (f[j] == a && f[(j + 1) % f.length] == b) return cast(int)fi;
        }
        return -1;
    }

    /// Fan walk around pivot `b` starting in `startFace`: each step takes
    /// the spoke to the next (fwd) / previous vert of `b` in the current
    /// face's winding, then crosses to the candidate's other flanking face.
    /// An open fan (no face across) stops early keeping the last candidate.
    /// Returns false (cand = ~0u) when the walk breaks structurally — pivot
    /// missing from the face or no such edge; the reference fails the whole
    /// hop in that case. (The reference picks the cross face by directed
    /// winding — into the pivot when walking forward, out of it backward;
    /// for consistently wound meshes that is simply the other flanking
    /// face.)
    private bool loopFanWalk(uint b, int startFace, bool fwd, uint iters,
                             const(uint[][]) edgeFaces, out uint cand) const {
        cand = ~0u;
        int face = startFace;
        foreach (_; 0 .. iters) {
            const f = faces[face];
            uint x = ~0u;
            foreach (j; 0 .. f.length) {
                if (f[j] != b) continue;
                x = fwd ? f[(j + 1) % f.length]
                        : f[(j + f.length - 1) % f.length];
                break;
            }
            const ce = x == ~0u ? ~0u : edgeIndex(b, x);
            if (ce == ~0u) { cand = ~0u; return false; }
            cand = ce;
            int nf = -1;
            foreach (fi; edgeFaces[ce])
                if (fi != face) { nf = cast(int)fi; break; }
            if (nf < 0) return true; // open fan — keep the last candidate
            face = nf;
        }
        return true;
    }

    /// One direction of the recovered vertex-loop walk: directed current
    /// edge `a0`→`b0` (pivot `b0`). The hop is stateless — everything is
    /// re-derived per step from (directed edge, pivot).
    /// `eMark` is the invocation-shared visited-edge set: a candidate
    /// already marked terminates the walk (this is ring closure; the seed
    /// edge is pre-marked, and marks are shared across both directions and
    /// all seed pairs). Accepted edges are marked and their endpoints added
    /// to `resultV`. `vertEdges`/`edgeFaces` are the full incidence star
    /// (see buildLoopIncidence).
    private void selectLoopVertexWalk(uint a0, uint b0,
                                      bool[] eMark, bool[] resultV,
                                      const(uint[][]) vertEdges,
                                      const(uint[][]) edgeFaces) const {
        uint a = a0, b = b0;
        while (true) {
            uint curE = edgeIndex(a, b);
            if (curE == ~0u) break;
            const nPolys = edgeFaces[curE].length;
            const vcount = cast(uint)vertEdges[b].length;
            // gate: an odd-valence pivot is passable only along a border edge
            if ((vcount & 1) != 0 && nPolys > 1) break;
            // gate: more than two border edges at the pivot is a dead end
            if (vcount > 3) {
                uint nb = 0;
                foreach (ei; vertEdges[b])
                    if (edgeFaces[ei].length <= 1) ++nb;
                if (nb > 2) break;
            }
            if (vcount < 2) break;

            uint cand = ~0u;
            bool angleGate = false;
            if (vcount == 2) {
                // trivial path: the OTHER edge at the pivot
                cand = vertEdges[b][0] != curE ? vertEdges[b][0] : vertEdges[b][1];
            } else {
                if (nPolys <= 1) {
                    // border-chain: the first OTHER border edge at the pivot
                    foreach (ei; vertEdges[b]) {
                        if (ei == curE) continue;
                        if (edgeFaces[ei].length > 1) continue;
                        cand = ei;
                        break;
                    }
                }
                if (cand == ~0u) {
                    // winding faces of the directed current edge: F winds
                    // INTO the pivot (contains a→b), G winds OUT (b→a)
                    const int inF = windingFaceFor(edgeFaces[curE], a, b);
                    const int outG = windingFaceFor(edgeFaces[curE], b, a);
                    if (inF >= 0 && outG >= 0) {
                        // regular fan: the spoke floor(V/2) steps away;
                        // forward from F when G is not larger than F,
                        // backward from G otherwise
                        const bool fwd = faces[outG].length <= faces[inF].length;
                        if (!loopFanWalk(b, fwd ? inF : outG, fwd, vcount / 2,
                                         edgeFaces, cand)) break;
                    } else if (inF >= 0) {
                        // no out-face (border edge / inconsistent winding):
                        // forward fan from F of V-1 steps + the angle gate
                        if (!loopFanWalk(b, inF, true, vcount - 1,
                                         edgeFaces, cand)) break;
                        angleGate = true;
                    } else if (outG >= 0) {
                        // no in-face: a single backward step from G + gate
                        const f = faces[outG];
                        uint x = ~0u;
                        foreach (j; 0 .. f.length) {
                            if (f[j] != b) continue;
                            x = f[(j + f.length - 1) % f.length];
                            break;
                        }
                        cand = x == ~0u ? ~0u : edgeIndex(b, x);
                        if (cand == ~0u) break;
                        angleGate = true;
                    } else break;
                }
            }

            // Angle gate (paths without both winding faces): the
            // candidate must bend away from the incoming direction by more
            // than 90° at the pivot
            if (angleGate) {
                import std.math : acos, PI_2;
                const d0 = edges[cand][0] == b ? edges[cand][1] : edges[cand][0];
                const va = vertices[a] - vertices[b];
                const vc = vertices[d0] - vertices[b];
                const la = va.length, lc = vc.length;
                if (la <= 0 || lc <= 0) break;
                float cosA = dot(va, vc) / (la * lc);
                cosA = cosA < -1 ? -1 : cosA > 1 ? 1 : cosA;
                if (acos(cosA) <= PI_2) break;
            }

            // final validation: closure / revisit stops the walk
            if (eMark[cand]) break;
            eMark[cand] = true;
            const d = edges[cand][0] == b ? edges[cand][1] : edges[cand][0];
            resultV[b] = true;
            resultV[d] = true;
            a = b; b = d;
        }
    }

    /// Recovered `select.loop` (vertex) algorithm — returns the NEW vertex
    /// selection (purge-then-commit semantics: the reference clears the
    /// previous vertex selection unconditionally and commits only the loop
    /// result, so a lone selected vertex clears the selection). See
    //  findings_fv.md (private) for per-rule provenance and validation.
    bool[] selectLoopVertices() const {
        bool[] resultV = new bool[](vertices.length);
        bool[] vMark   = new bool[](vertices.length); // consumed as seed/in a loop
        bool[] eMark   = new bool[](edges.length);    // walked/consumed edges

        // Selected vertices in selection-history order (0/absent order
        // falls back to index order among themselves).
        uint[] selVerts;
        foreach (i; 0 .. vertices.length)
            if (i < vertexMarks.length && (vertexMarks[i] & Marks.Select) != 0)
                selVerts ~= cast(uint)i;
        static int vOrderOf(const int[] ord, size_t i) {
            return (i < ord.length && ord[i] > 0) ? ord[i] : int.max;
        }
        import std.algorithm.sorting : sort;
        selVerts.sort!((x, y) {
            int ox = vOrderOf(vertexSelectionOrder, x), oy = vOrderOf(vertexSelectionOrder, y);
            return ox != oy ? ox < oy : x < y;
        });

        // Full incidence star (reference semantics — complete star,
        // not the truncated half-edge fan walk).
        uint[][] vertEdges, edgeFaces, vertFaces;
        buildLoopIncidence(vertEdges, edgeFaces, vertFaces);

        // Multi-pair seed scan (the reference re-scans from the head after
        // each consumed pair; marks make that monotone). Two devices keep the
        // pass sequence from being O(passes x selected) — which is O(V^2) once
        // the mesh has many small components, one pass each:
        //
        //  * `sCur`, a forward-only cursor over the LEADING run of consumed
        //    vertices. `vMark` is only ever set, never cleared, so a vertex
        //    the scan once skipped for that reason can never seed later.
        //
        //  * `burns`, a memo of the pass prefix past that cursor. A pass that
        //    reaches an already-consumed EDGE drops its `vA` and resumes after
        //    the partner (`vA = vB = ~0u` below) — a "burn". Replaying a
        //    recorded burn is exact while BOTH its endpoints are still
        //    unconsumed: everything the scan skipped between them was either
        //    already `vMark`ed (monotone) or rejected on topology (fixed), and
        //    the blocking edge's `eMark` is monotone too, so the pass would
        //    make the identical decisions again. So the next pass starts right
        //    after the last replayable burn instead of at the head. Marking a
        //    burn endpoint (only the seed pair and the extra-seed block do
        //    that) invalidates that burn and every burn after it, and the scan
        //    falls back to the cursor for the rest — `markVert` records the
        //    earliest such index.
        size_t sCur = 0;
        static struct SeedBurn { uint t, u; size_t uPos; }
        SeedBurn[] burns;
        size_t[] burnOf = new size_t[](vertices.length); // vertex → burn index
        burnOf[] = size_t.max;
        size_t minInvalid = size_t.max;

        void markVert(uint v) {
            vMark[v] = true;
            const b = burnOf[v];
            if (b < minInvalid) minInvalid = b;
        }

        while (true) {
            if (minInvalid < burns.length) {
                foreach (ref b; burns[minInvalid .. $]) {
                    burnOf[b.t] = size_t.max;
                    burnOf[b.u] = size_t.max;
                }
                burns.length = minInvalid;
            }
            minInvalid = size_t.max;

            while (sCur < selVerts.length && vMark[selVerts[sCur]]) ++sCur;
            uint vA = ~0u, vB = ~0u, seedE = ~0u;
            for (size_t k = burns.length ? burns[$ - 1].uPos + 1 : sCur;
                 k < selVerts.length; ++k) {
                version (unittest) ++gSelectLoopSeedScanSteps;
                const v = selVerts[k];
                if (vMark[v]) continue;
                if (vA == ~0u) { vA = v; continue; }
                vB = v;
                bool adj = false;
                foreach (fi; vertFaces[vA]) {
                    const f = faces[fi];
                    foreach (fv; f) if (fv == vB) { adj = true; break; }
                    if (adj) break;
                }
                if (!adj) { vB = ~0u; continue; }
                uint e = edgeIndex(vA, vB);
                if (e == ~0u) { vB = ~0u; continue; }
                if (eMark[e]) {                                // consumed edge: reset pair
                    burnOf[vA] = burnOf[vB] = burns.length;
                    burns ~= SeedBurn(vA, vB, k);
                    vA = ~0u; vB = ~0u; continue;
                }
                seedE = e;
                break;
            }
            if (seedE == ~0u) break;

            markVert(vA); markVert(vB);
            eMark[seedE] = true;
            resultV[vA] = resultV[vB] = true;

            // "Extra seed vertices" block: with >2 vertices selected and an
            // interior (2-face) seed edge, any further selected vertex
            // sitting next to a seed endpoint in one of the seed's faces
            // pulls in that WHOLE face's vertices.
            if (selVerts.length > 2 && edgeFaces[seedE].length == 2) {
                foreach (w; selVerts) {
                    if (w == vA || w == vB || vMark[w]) continue;
                    bool pulled = false;
                    foreach (fi; edgeFaces[seedE]) {
                        const f = faces[fi];
                        foreach (j; 0 .. f.length) {
                            if (f[j] != w) continue;
                            uint pv = f[(j + f.length - 1) % f.length];
                            uint nx = f[(j + 1) % f.length];
                            if (pv == vA || pv == vB || nx == vA || nx == vB) {
                                foreach (fv; f) { markVert(fv); resultV[fv] = true; }
                                pulled = true;
                            }
                            break;
                        }
                        if (pulled) break;
                    }
                }
            }

            // Two-direction walk: one chain per seed endpoint (the reference
            // calls the hop with side=0/1 on the seed edge; every hop then
            // re-derives its winding faces from the directed current edge,
            // so no per-face routing is needed at the seed either).
            selectLoopVertexWalk(edges[seedE][0], edges[seedE][1], eMark, resultV,
                                 vertEdges, edgeFaces);
            selectLoopVertexWalk(edges[seedE][1], edges[seedE][0], eMark, resultV,
                                 vertEdges, edgeFaces);
        }
        return resultV;
    }

    // -----------------------------------------------------------------------
    // select.loop (polygon/face) — recovered-algorithm helper (task 0390)
    // -----------------------------------------------------------------------
    // The bare "select.loop" polygon command reproduces the reference's
    // recovered band algorithm (findings_fv.md, private —
    // rr/gdb live-validated): pure topology, no geometry anywhere.
    //   * seeds are consumed in selection-history order, possibly several
    //     disjoint groups per invocation (multi-group rescan);
    //   * a seed A pairs with the first selected, unvisited, EVEN-sided
    //     polygon sharing a directed (winding-reversed) edge with A; the
    //     band axis is then perpendicular to the shared edge — each seed
    //     exits through the edge nverts/2 away from it. Without a partner,
    //     A walks alone across its own edges 0 and floor(nverts/2), the
    //     axis dictated purely by the polygon's vertex order. A itself may
    //     be odd-sided (only nverts>2 is required of it);
    //   * each hop crosses the current directed exit edge into the polygon
    //     on the other side, provided that polygon is even-sided, not
    //     degenerate (nverts>2), and contains the exit edge's endpoints
    //     consecutively in the reversed winding (covers open boundaries,
    //     T-junctions where the neighbour's edge is subdivided, and
    //     non-manifold gaps); an odd-sided neighbour is SKIPPED (never
    //     entered, never selected); landing on an already-visited polygon
    //     STOPS the walk (ring closure — seeds are pre-marked);
    //   * visited marks are shared across both directions and all groups.
    // The command REPLACES the face selection (purge-then-commit, same as
    // vertex mode). Hidden/locked unmodelled (reserved/unused marks).
    // `walkFaceLoop` stays untouched for its ordered-walk consumers.

    /// Seed-scan step counter for the select.loop seed loops (both modes) —
    /// the gate that keeps those scans linear in the selected-element count.
    /// Unittest-only: the scans are hot and this must not cost a thing in a
    /// release build. Reset it, run the walk, read it; see the scaling
    /// unittests at the bottom of this module.
    version (unittest) static size_t gSelectLoopSeedScanSteps;

    /// One band-trace loop: repeatedly cross the directed exit edge
    /// (`vA`→`vB` in the current polygon's winding, i.e. the reversed
    /// winding `vB`,`vA` is what the candidate must contain) into the
    /// even-sided polygon on the far side; stop on boundary, T-junction,
    /// odd-only neighbours, or a visited polygon (closure). Accepted
    /// polygons are marked and added to `resultF`.
    private void selectBandTrace(uint vB0, uint vA0, ubyte[] mark, bool[] resultF,
                                 const(uint[][]) edgeFaces) const {
        uint vB = vB0, vA = vA0;
        while (true) {
            uint ei = edgeIndex(vA, vB);
            if (ei == ~0u) break;
            bool advanced = false, stop = false;
            foreach (q; edgeFaces[ei]) {
                const qf = faces[q];
                immutable m = qf.length;
                if (m <= 2 || (m & 1) != 0) continue;     // degenerate / odd-sided skip
                uint j = ~0u;
                foreach (jj; 0 .. m)
                    if (qf[jj] == vB && qf[(jj + 1) % m] == vA) { j = cast(uint)jj; break; }
                if (j == ~0u) continue;                    // directed-consecutive miss
                if ((mark[q] & 1) != 0) { stop = true; break; } // visited → closure stop
                mark[q] |= 1;
                resultF[q] = true;
                uint nvA = qf[(j + m / 2) % m];
                uint nvB = qf[(j + m / 2 + 1) % m];
                vA = nvA; vB = nvB;
                advanced = true;
                break;
            }
            if (stop || !advanced) break;
        }
    }

    /// The band partner for seed polygon `A`: among the selected, unvisited,
    /// even-sided polygons that contain one of A's edges in the REVERSED
    /// winding, the one that comes first in `partnerRank` order (= selection
    /// order restricted to the static partner filter). Returns -1 when there
    /// is none, else the polygon index with `pi` = the index of A's edge and
    /// `pj` = the partner's matching corner.
    ///
    /// Equivalent to scanning the whole selection in order and taking the
    /// first entry that shares such an edge, but bounded by A's own valence:
    /// only a face incident to one of A's edges can ever match, and a strict
    /// `rank < best` keeps the FIRST (i, j) found for the winner, which is
    /// what the selection-order-outer / A's-edges-inner scan produced. The
    /// `mark & 1` test also covers `q == A` (the caller seeds `mark[A] = 3`
    /// before calling).
    private int findLoopPartner(uint A, const(ubyte[]) mark,
                                const(uint[][]) edgeFaces,
                                const(size_t[]) partnerRank,
                                out size_t pi, out size_t pj) const {
        const af = faces[A];
        immutable n = af.length;
        int P = -1;
        size_t best = size_t.max;
        pi = 0; pj = 0;
        foreach (i; 0 .. n) {
            uint va = af[i], vb = af[(i + 1) % n];
            uint ei = edgeIndex(va, vb);
            if (ei == ~0u) continue;
            foreach (q; edgeFaces[ei]) {
                version (unittest) ++gSelectLoopSeedScanSteps;
                const rank = partnerRank[q];
                if (rank >= best) continue;      // not a candidate, or already beaten
                if ((mark[q] & 1) != 0) continue; // visited (covers q == A)
                const qf = faces[q];
                foreach (j; 0 .. qf.length) {
                    if (qf[j] == vb && qf[(j + 1) % qf.length] == va) {
                        P = cast(int)q; best = rank; pi = i; pj = j;
                        break;
                    }
                }
            }
        }
        return P;
    }

    /// Recovered `select.loop` (polygon) algorithm — returns the NEW face
    /// selection (purge-then-commit semantics). See findings_fv.md
    /// (private) for per-rule provenance and validation.
    bool[] selectLoopFaces() const {
        bool[] resultF = new bool[](faces.length);
        // bit0 = visited (in a band result this invocation, commit filter);
        // bit1 = seeded (consumed as a group seed).
        ubyte[] mark = new ubyte[](faces.length);

        // Selected faces in selection-history order (0/absent order falls
        // back to index order among themselves).
        uint[] selFaces;
        foreach (i; 0 .. faces.length)
            if (i < faceMarks.length && (faceMarks[i] & Marks.Select) != 0)
                selFaces ~= cast(uint)i;
        static int fOrderOf(const int[] ord, size_t i) {
            return (i < ord.length && ord[i] > 0) ? ord[i] : int.max;
        }
        import std.algorithm.sorting : sort;
        selFaces.sort!((x, y) {
            int ox = fOrderOf(faceSelectionOrder, x), oy = fOrderOf(faceSelectionOrder, y);
            return ox != oy ? ox < oy : x < y;
        });

        // Only the edge→faces incidence is read below (the partner scan and
        // every band hop cross an EDGE); the two per-vertex stars used to be
        // built here and never read.
        uint[][] edgeFaces;
        buildLoopEdgeFaces(edgeFaces);

        // Rank of each polygon in the partner-candidate order: the selection
        // order restricted to the STATIC half of the partner filter
        // (even-sided, nverts>2). `size_t.max` = not a candidate. Lifting
        // that filter out of the group loop is what lets the scan below run
        // outward from A's edges instead of over the whole selection.
        size_t[] partnerRank = new size_t[](faces.length);
        partnerRank[] = size_t.max;
        {
            size_t rank = 0;
            foreach (fi; selFaces) {
                immutable L = faces[fi].length;
                if (L <= 2 || (L & 1) != 0) continue;
                partnerRank[fi] = rank++;
            }
        }

        // Multi-group loop: each pass consumes one seed group; visited and
        // seeded marks are shared across groups and make this monotone.
        // `gCur` is a forward-only cursor into `selFaces`: BOTH reasons the
        // scan below skips an entry are permanent — a polygon's vertex count
        // never changes here, and marks are only ever set, never cleared — so
        // an entry the scan once walked past can never become a seed later.
        // Restarting from the head instead made the pass sequence O(groups x
        // selected), and the group count equals the selected count on a
        // triangulated mesh (selectBandTrace skips odd-sided neighbours, so a
        // triangle never advances and is always a group of one).
        size_t gCur = 0;
        while (true) {
            // NEXT_GROUP: first selected, unconsumed polygon with nverts>2.
            int A = -1;
            for (; gCur < selFaces.length; ++gCur) {
                version (unittest) ++gSelectLoopSeedScanSteps;
                const fi = selFaces[gCur];
                if (faces[fi].length <= 2) continue;
                if ((mark[fi] & 3) != 0) continue;
                A = cast(int)fi;
                break;
            }
            if (A < 0) break;
            mark[A] = 3;
            resultF[A] = true;
            const af = faces[A];
            immutable n = af.length;

            // Partner: the selected, unvisited, EVEN-sided polygon sharing a
            // winding-reversed edge with A that comes FIRST in selection
            // order. Only a face incident to one of A's edges can qualify, so
            // this walks A's edges and ranks the hits instead of walking the
            // whole selection per group — same winner, same `pi`/`pj`.
            size_t pi, pj;
            const int P = findLoopPartner(A, mark, edgeFaces, partnerRank, pi, pj);

            uint vB0, vA0, vB1, vA1; // B-side exit, A-side exit
            if (P >= 0) {
                mark[P] |= 1;
                resultF[P] = true;
                const pf = faces[P];
                immutable half  = n / 2, halfP = pf.length / 2;
                vB0 = pf[(pj + halfP + 1) % pf.length]; vA0 = pf[(pj + halfP) % pf.length];
                vB1 = af[(pi + half + 1) % n];          vA1 = af[(pi + half) % n];
                selectBandTrace(vB0, vA0, mark, resultF, edgeFaces); // B-side from P
                selectBandTrace(vB1, vA1, mark, resultF, edgeFaces); // A-side from A
            } else {
                immutable half = n / 2;
                vB0 = af[1];                vA0 = af[0];         // edge 0, reversed
                vB1 = af[(half + 1) % n];   vA1 = af[half % n];  // edge n/2, reversed
                selectBandTrace(vB0, vA0, mark, resultF, edgeFaces);
                selectBandTrace(vB1, vA1, mark, resultF, edgeFaces);
            }
        }
        return resultF;
    }

    // -----------------------------------------------------------------------
    // Head-restart ORACLES for the select.loop seed scans (unittest only)
    // -----------------------------------------------------------------------
    // Frozen copies of the seed-scan shape the two walks above had before the
    // scans were made forward-only: every pass re-scans the selected list from
    // the HEAD, and the polygon partner is found by walking the whole
    // selection in order (outer) against A's edges (inner). They are the
    // oracle the differential unittest at the bottom of this module measures
    // the fast paths against — the claim being that skipping provably-dead
    // work and ranking the partner candidates from A's edges outward changes
    // only the cost, never the answer.
    //
    // DO NOT "fix" these to track the fast paths. If a future change to
    // select.loop makes the differential test fail, either the fast path
    // diverged (a bug) or the semantics changed deliberately — in which case
    // update BOTH, and the golden capture fixtures with them.
    version (unittest) {
        bool[] selectLoopFacesHeadRestart() const {
            bool[] resultF = new bool[](faces.length);
            ubyte[] mark   = new ubyte[](faces.length);

            uint[] selFaces;
            foreach (i; 0 .. faces.length)
                if (i < faceMarks.length && (faceMarks[i] & Marks.Select) != 0)
                    selFaces ~= cast(uint)i;
            static int fOrderOf(const int[] ord, size_t i) {
                return (i < ord.length && ord[i] > 0) ? ord[i] : int.max;
            }
            import std.algorithm.sorting : sort;
            selFaces.sort!((x, y) {
                int ox = fOrderOf(faceSelectionOrder, x), oy = fOrderOf(faceSelectionOrder, y);
                return ox != oy ? ox < oy : x < y;
            });

            uint[][] vertEdges, edgeFaces, vertFaces;
            buildLoopIncidence(vertEdges, edgeFaces, vertFaces);

            while (true) {
                int A = -1;
                foreach (fi; selFaces) {                  // <- restarts at the head
                    if (faces[fi].length <= 2) continue;
                    if ((mark[fi] & 3) != 0) continue;
                    A = cast(int)fi;
                    break;
                }
                if (A < 0) break;
                mark[A] = 3;
                resultF[A] = true;
                const af = faces[A];
                immutable n = af.length;

                int P = -1;
                size_t pi, pj;
            partnerScan:
                foreach (pfi; selFaces) {                 // <- and so does this
                    if (pfi == A) continue;
                    if ((mark[pfi] & 1) != 0) continue;
                    const pf = faces[pfi];
                    if (pf.length <= 2 || (pf.length & 1) != 0) continue;
                    foreach (i; 0 .. n) {
                        uint va = af[i], vb = af[(i + 1) % n];
                        uint ei = edgeIndex(va, vb);
                        if (ei == ~0u) continue;
                        foreach (q; edgeFaces[ei]) {
                            if (q != pfi) continue;
                            foreach (j; 0 .. pf.length) {
                                if (pf[j] == vb && pf[(j + 1) % pf.length] == va) {
                                    P = cast(int)pfi; pi = i; pj = j;
                                    break partnerScan;
                                }
                            }
                        }
                    }
                }

                uint vB0, vA0, vB1, vA1;
                if (P >= 0) {
                    mark[P] |= 1;
                    resultF[P] = true;
                    const pf = faces[P];
                    immutable half  = n / 2, halfP = pf.length / 2;
                    vB0 = pf[(pj + halfP + 1) % pf.length]; vA0 = pf[(pj + halfP) % pf.length];
                    vB1 = af[(pi + half + 1) % n];          vA1 = af[(pi + half) % n];
                    selectBandTrace(vB0, vA0, mark, resultF, edgeFaces);
                    selectBandTrace(vB1, vA1, mark, resultF, edgeFaces);
                } else {
                    immutable half = n / 2;
                    vB0 = af[1];                vA0 = af[0];
                    vB1 = af[(half + 1) % n];   vA1 = af[half % n];
                    selectBandTrace(vB0, vA0, mark, resultF, edgeFaces);
                    selectBandTrace(vB1, vA1, mark, resultF, edgeFaces);
                }
            }
            return resultF;
        }

        bool[] selectLoopVerticesHeadRestart() const {
            bool[] resultV = new bool[](vertices.length);
            bool[] vMark   = new bool[](vertices.length);
            bool[] eMark   = new bool[](edges.length);

            uint[] selVerts;
            foreach (i; 0 .. vertices.length)
                if (i < vertexMarks.length && (vertexMarks[i] & Marks.Select) != 0)
                    selVerts ~= cast(uint)i;
            static int vOrderOf(const int[] ord, size_t i) {
                return (i < ord.length && ord[i] > 0) ? ord[i] : int.max;
            }
            import std.algorithm.sorting : sort;
            selVerts.sort!((x, y) {
                int ox = vOrderOf(vertexSelectionOrder, x), oy = vOrderOf(vertexSelectionOrder, y);
                return ox != oy ? ox < oy : x < y;
            });

            uint[][] vertEdges, edgeFaces, vertFaces;
            buildLoopIncidence(vertEdges, edgeFaces, vertFaces);

            while (true) {
                uint vA = ~0u, vB = ~0u, seedE = ~0u;
                foreach (v; selVerts) {                   // <- restarts at the head
                    if (vMark[v]) continue;
                    if (vA == ~0u) { vA = v; continue; }
                    vB = v;
                    bool adj = false;
                    foreach (fi; vertFaces[vA]) {
                        const f = faces[fi];
                        foreach (fv; f) if (fv == vB) { adj = true; break; }
                        if (adj) break;
                    }
                    if (!adj) { vB = ~0u; continue; }
                    uint e = edgeIndex(vA, vB);
                    if (e == ~0u) { vB = ~0u; continue; }
                    if (eMark[e]) { vA = ~0u; vB = ~0u; continue; }
                    seedE = e;
                    break;
                }
                if (seedE == ~0u) break;

                vMark[vA] = vMark[vB] = true;
                eMark[seedE] = true;
                resultV[vA] = resultV[vB] = true;

                if (selVerts.length > 2 && edgeFaces[seedE].length == 2) {
                    foreach (w; selVerts) {
                        if (w == vA || w == vB || vMark[w]) continue;
                        bool pulled = false;
                        foreach (fi; edgeFaces[seedE]) {
                            const f = faces[fi];
                            foreach (j; 0 .. f.length) {
                                if (f[j] != w) continue;
                                uint pv = f[(j + f.length - 1) % f.length];
                                uint nx = f[(j + 1) % f.length];
                                if (pv == vA || pv == vB || nx == vA || nx == vB) {
                                    foreach (fv; f) { vMark[fv] = true; resultV[fv] = true; }
                                    pulled = true;
                                }
                                break;
                            }
                            if (pulled) break;
                        }
                    }
                }

                selectLoopVertexWalk(edges[seedE][0], edges[seedE][1], eMark, resultV,
                                     vertEdges, edgeFaces);
                selectLoopVertexWalk(edges[seedE][1], edges[seedE][0], eMark, resultV,
                                     vertEdges, edgeFaces);
            }
            return resultV;
        }
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
    /// CONTRACT (task 0447 §7): this re-syncs `loops`/`loopEdge`/`vertLoop`
    /// against the CURRENT `edges[]` — it does NOT rebuild the edge set. A
    /// caller that assigns `faces` directly (bypassing `addFace`, which grows
    /// `edges` incrementally) must call `rebuildEdges()` /
    /// `rebuildEdgesFromFaces()` BEFORE this, or every `loopEdge` stays `~0u`
    /// and the vertex-fan edge walk yields garbage edge indices.
    /// `scene.loadMesh` follows the correct order (rebuildEdgesFromFaces then
    /// buildLoops); `/api/model` never reads edges, so a live instance is
    /// unaffected. Semantics are otherwise unchanged.
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

        // Task 0447 (KEEP-TWIN): per-vertex fan-order tracking. Pass 3 above
        // leaves same-direction twins POPULATED (byte-identical to before);
        // here we DETECT them straight from `loops[]` — a same-direction pair
        // (li, tw) of one edge has EQUAL tails `loops[tw].vert ==
        // loops[li].vert` (an antiparallel twin gives different tails; a
        // boundary / non-manifold edge gives `twin==~0u` and never enters
        // here). Both endpoints of every such edge are marked NOT fan-ordered.
        // Always (re)size `vertFanOrdered_` (cheap, same class as `vertLoop`);
        // the single `foreach` over loops has no per-edge allocation (Risk #1).
        vertFanOrdered_.length = vertices.length;
        vertFanOrdered_[] = true;
        bool anySameDir = false;
        foreach (li; 0 .. total) {
            uint tw = loops[li].twin;
            if (tw != ~0u && loops[tw].vert == loops[li].vert) {
                vertFanOrdered_[loops[li].vert] = false;
                vertFanOrdered_[loops[loops[li].next].vert] = false;
                anySameDir = true;
            }
        }
        if (anySameDir) {
            // CSR vertex→dart adjacency (template: buildLoopsEdgesAdjStart /
            // buildLoopsEdgesAdj above — same count / prefix-sum / fill shape,
            // keyed by `loops[idx].vert` instead of an edge's two endpoints,
            // one entry per dart since each dart has exactly one tail vertex).
            // Built ONLY here (some edge is same-direction), so the
            // consistently-wound fast path never allocates it (Risk #1). The
            // fan-walk ranges use it to enumerate the WHOLE fan of an
            // unordered vertex, complete and winding-independent (but in
            // arbitrary order — only consumers tolerant of any order reach it,
            // since slot-position consumers decline on !vertexFanOrdered).
            vertDartStart.length = vertices.length + 1;
            vertDartStart[] = 0;
            foreach (idx; 0 .. total) ++vertDartStart[loops[idx].vert + 1];
            foreach (i; 1 .. vertDartStart.length)
                vertDartStart[i] += vertDartStart[i - 1];
            vertDartAdj.length = total;
            auto vertDartCursor = new uint[](vertices.length);
            vertDartCursor[] = 0;
            foreach (idx; 0 .. total) {
                uint v = loops[idx].vert;
                vertDartAdj[vertDartStart[v] + vertDartCursor[v]++] = cast(uint)idx;
            }

            import log : logWarnOnce;
            logWarnOnce("mesh", "sameDirTwin",
                "buildLoops: inconsistently-wound faces detected (a shared "
                ~ "edge traversed the same direction by both faces) — the "
                ~ "affected vertex fans are unordered/incomplete for "
                ~ "slot-position consumers. Run mesh.fixOrientation to repair "
                ~ "winding.");
        } else {
            // Keep the CSR arrays empty on the clean fast path (the ranges
            // only ever read them when !vertexFanOrdered, which never happens
            // when anySameDir is false).
            vertDartStart.length = 0;
            vertDartAdj.length   = 0;
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
                    // Task 0447 (KEEP-TWIN): a same-direction ("meaning-3")
                    // twin has the SAME tail as `cur`; crossing it would jump
                    // to the OTHER endpoint's fan. Treat it as a boundary.
                    if (loops[loops[cur].twin].vert == loops[cur].vert) break;
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
    ///
    /// `autoOrient` (task 0477, topology-pen P3): when true (default, every
    /// pre-task-0477 caller), the majority-vote `orientFaceConsistent` below
    /// may reverse `idx` to stay winding-consistent with existing neighbors
    /// (task 0394 parity). Set `false` to bypass that and emit `orderedIdx`
    /// (post-`flip`) VERBATIM — for a caller building a fixed
    /// construction-order convention (e.g. topology-pen's captured
    /// `[hub, newest, older-neighbor]` triangle winding) that must not be
    /// re-derived from adjacency. Every other guard (dedup, Newell zero-area,
    /// duplicate-face, ≤2-per-edge manifold) still runs unconditionally.
    int makePolygonFromVerts(const(uint)[] orderedIdx, bool flip, bool autoOrient = true) {
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
        // same invariant. `autoOrient:false` (task 0477) bypasses this
        // entirely so the caller's own construction-order winding survives
        // verbatim — every guard below still runs regardless.
        if (autoOrient) orientFaceConsistent(idx, edgeFaces);

        // --- 5.7. manifold-safety guard: reject if any boundary edge of the
        // new face is already shared by 2 existing faces — adding a 3rd
        // would exceed the ≤2-faces-per-edge manifold invariant (e.g. a new
        // face reusing an edge already shared by two faces of a closed
        // solid). Fuzz-found: task 0316. (Orientation-independent — reject
        // check is unaffected by the auto-orient reversal above.)
        foreach (i; 0 .. idx.length) {
            ulong key = edgeKey(idx[i], idx[(i + 1) % idx.length]);
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
            auto p = edgeKey(u, v) in edgeFaces;
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
            ulong key = edgeKey(idx[i], idx[(i + 1) % idx.length]);
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
                ulong key = edgeKey(a, b);
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

    // Edge/vertex bevel kernel family (bevelEdgesByMask / bevelVerticesByMask /
    // bevelIsolatedFinBundleSpine / bevelFinBundleSpineMultiEdge /
    // centerNormalProject + the valence-4 free-end cap parity fields) — see
    // source/mesh_ops/bevel.d (0407 §B.V2).
    mixin MeshBevelOps;

    // Extrude kernel family (extrudeEdgesByMask / extrudeVerticesByMask /
    // extendEdgesByMask / extrudeFacesByMask / smoothShiftFacesByMask) — see
    // source/mesh_ops/extrude.d (0407 §B.V2).
    mixin MeshExtrudeOps;

    // Connected-component vertex mask (connectedComponentMask BFS) +
    // edgeCentroid — extracted from xfrm_transform.d (xfrm Phase B); see
    // source/mesh_ops/connected_mask.d.
    mixin MeshConnectedMaskOps;

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
        uint[]   newWord;   // whole faceMarks word per emitted face (task 0613 §4.2)
        int[]    newOrder;
        uint[]   newMaterial;
        uint[]   newPart;
        bool[]   newSelected;
        newFacesArr.reserve(origFaceCount + origFaceCount / 2);

        size_t nSplit = 0;
        foreach (fi; 0 .. origFaceCount) {
            uint[] face = faces[fi];
            uint  word = faceAttrOr(faceMarks, fi);
            int   ord = faceAttrOr(faceSelectionOrder, fi);
            uint  mat = faceAttrOr(faceMaterial, fi);
            uint  prt = faceAttrOr(facePart, fi);
            bool  seld = isFaceSelected(fi);

            // Faces not in the mask are copied whole (never split).
            bool eligible = (splitFaceMask.length == 0) ||
                            (fi < splitFaceMask.length && splitFaceMask[fi]);
            if (!eligible) {
                newFacesArr ~= face.dup;
                newWord     ~= word;
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
                newWord     ~= word;
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
                newWord     ~= word;
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
                newWord     ~= word;
                newOrder    ~= ord;
                newMaterial ~= mat;
                newPart     ~= prt;
                newSelected ~= seld;
                continue;
            }

            // f1 (replaces parent slot)
            newFacesArr ~= f1;
            newWord     ~= word;
            newOrder    ~= ord;
            newMaterial ~= mat;
            newPart     ~= prt;
            newSelected ~= seld;

            // f2 (appended slot) — BOTH halves carry parent attrs, including
            // the Select bit: a selected parent yields two selected halves
            // (reference-pinned behavior). Same for Hide (task 0613): a
            // hidden parent yields two hidden halves — `word` carries it.
            newFacesArr ~= f2;
            newWord     ~= word;
            newOrder    ~= ord;
            newMaterial ~= mat;
            newPart     ~= prt;
            newSelected ~= seld;

            nSplit++;
        }

        if (nSplit == 0) return 0;

        // Apply new face arrays (mirrors weldVerticesByMask pattern).
        faces._store = newFacesArr;
        setFaceMarksFrom(newWord, ~Marks.Select);
        faceSelectionOrder = newOrder;
        faceMaterial       = newMaterial;
        facePart           = newPart;
        // Inherit each parent's Select bit onto its emitted slot(s) instead of
        // clearing — a selected parent's split halves stay selected, an
        // unselected parent stays unselected, nothing-in ⇒ nothing-out.
        // Writes ONLY the Select bit (Subpatch/Hide already written above).
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
// visibleVertices under a mirrored ModelSpace (task 0617 follow-up).
//
// The previous version of this fixture used a single flat quad centred on
// the origin: mirroring across X maps that quad's vertex SET to itself (same
// world pixels, same depth, only winding reversed), so the only thing the
// old assertion could measure was "did the flip line run" — not whether its
// answer was geometrically correct. It asserted visible-at-identity flips to
// hidden-when-mirrored, which is wrong on its face: a quad that is drawn at
// the literal same world position and orientation cannot become invisible
// just because its LOCAL vertex order changed.
//
// This fixture uses a cube translated off the mirror axis (local x in
// [1.5, 2.5], not straddling x=0), so the mirrored WORLD cube actually sits
// somewhere else (x in [-2.5, -1.5]) — mirroring is no longer a no-op on the
// drawn geometry. With the eye off-axis too (not on the mirror plane), the
// two per-vertex corner classifications below are independently verifiable
// by hand: at each pose, the cube corner nearest the eye must read visible,
// and the corner farthest from the eye — occluded by the cube itself on
// every side — must read hidden.
// ---------------------------------------------------------------------------
unittest {
    import math : lookAt, perspectiveMatrix, ModelSpace;
    import std.math : PI;

    Mesh m;
    // makeCube()'s layout, translated +2 along local X so the cube does not
    // straddle x=0 (the mirror axis used below).
    m.vertices = [
        Vec3( 1.5f, -0.5f, -0.5f), // 0
        Vec3( 2.5f, -0.5f, -0.5f), // 1
        Vec3( 2.5f,  0.5f, -0.5f), // 2
        Vec3( 1.5f,  0.5f, -0.5f), // 3
        Vec3( 1.5f, -0.5f,  0.5f), // 4
        Vec3( 2.5f, -0.5f,  0.5f), // 5
        Vec3( 2.5f,  0.5f,  0.5f), // 6
        Vec3( 1.5f,  0.5f,  0.5f), // 7
    ];
    m.faces = [
        [0u, 3u, 2u, 1u], // z = -0.5 (-Z)
        [4u, 5u, 6u, 7u], // z = +0.5 (+Z)
        [0u, 4u, 7u, 3u], // x = +1.5 (min-X face of this cube)
        [1u, 2u, 6u, 5u], // x = +2.5 (max-X face of this cube)
        [3u, 7u, 6u, 2u], // y = +0.5 (+Y)
        [0u, 1u, 5u, 4u], // y = -0.5 (-Y)
    ];

    Viewport vp;
    vp.eye  = Vec3(5, 5, 5); // off both the mirror plane (x=0) and the cube
    vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width = 400; vp.height = 400;

    // Fixture premise at IDENTITY: corner 6 (2.5,0.5,0.5) is the cube's
    // nearest corner to the eye — it sits on all three eye-facing faces
    // (+X, +Y, +Z) and nothing occludes it — so it must read visible.
    // Corner 0 (1.5,-0.5,-0.5) is the farthest corner, sitting on all three
    // AWAY-facing faces (min-X, -Y, -Z), so every face it belongs to is
    // back-facing and it must read hidden.
    bool[] visIdentity = m.visibleVertices(vp.eye, vp, ModelSpace.world());
    assert(visIdentity[6] == true,
        "fixture: at identity the cube corner nearest the eye must be visible");
    assert(visIdentity[0] == false,
        "fixture: at identity the cube corner farthest from the eye must be hidden");

    // Mirror across X: m = diag(-1,1,1), self-inverse, det < 0. Drawn world
    // cube now spans x in [-2.5, -1.5] — a different place than the local
    // cube, not a no-op.
    ModelSpace ms;
    ms.m          = [-1,0,0,0,  0,1,0,0,  0,0,1,0,  0,0,0,1];
    ms.mInv       = ms.m;               // diag(-1,1,1) is its own inverse
    ms.isIdentity = false;
    ms.invertible = true;
    ms.mirrored   = true;

    // Under the mirror, local corner 7 (1.5,0.5,0.5) is drawn at world
    // (-1.5,0.5,0.5) — the corner of the mirrored cube nearest eye (5,5,5)
    // (nearest in x among [-2.5,-1.5] is -1.5; nearest in y,z among
    // [-0.5,0.5] is 0.5) — so it must read visible. Local corner 1
    // (2.5,-0.5,-0.5) is drawn at world (-2.5,-0.5,-0.5), the farthest
    // corner from the eye, and must read hidden. A cull that reintroduces
    // the old `ms.mirrored` XOR gets this exactly backwards (see
    // `ModelSpace.mirrored`'s doc comment in math.d): it would report
    // corner 1 visible and corner 7 hidden instead.
    bool[] visMirrored = m.visibleVertices(vp.eye, vp, ms);
    assert(visMirrored[7] == true,
        "a mirrored ModelSpace's nearest-to-eye drawn corner must read visible");
    assert(visMirrored[1] == false,
        "a mirrored ModelSpace's farthest-from-eye drawn corner must read hidden");
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
        // Task 0447 (KEEP-TWIN): a same-direction ("meaning-3") twin shares
        // the tail of `prevLi` instead of reversing it — following it would
        // yield a dart based at the OTHER endpoint (a foreign element). Stop
        // as at a boundary. On a consistently-wound mesh the twin is always
        // antiparallel, so this never fires and the walk is byte-identical.
        if (_loops[twinPrev].vert == _loops[prevLi].vert) { _done = true; return; }
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
    private const(uint)[] _csr;    // task 0447: materialized CSR fallback (see fromCsr)
    private uint   _csrI;
    private bool   _useCsr;

    this(const(Loop)[] loops, uint startLi) {
        _loops = loops;
        _inner = VertexDartRange(loops, startLi);
    }

    /// Task 0447: complete (but arbitrarily ordered) face enumeration for a
    /// vertex whose fan is not `vertexFanOrdered`, built from the CSR
    /// vertex→dart adjacency (`vertDartStart`/`vertDartAdj`), NOT the twin
    /// graph, so it is correct regardless of winding. Exactly one CSR entry
    /// per face incident to `vi` (`loops[li].vert == vi`) — no dedup needed
    /// short of a self-touching degenerate polygon.
    static VertexFaceRange fromCsr(const(Loop)[] loops,
                                    const(uint)[] vertDartStart,
                                    const(uint)[] vertDartAdj,
                                    uint vi)
    {
        VertexFaceRange r;
        r._loops  = loops;
        r._useCsr = true;
        uint[] csr;
        if (vi + 1 < vertDartStart.length)
            foreach (i; vertDartStart[vi] .. vertDartStart[vi + 1])
                csr ~= loops[vertDartAdj[i]].face;
        r._csr = csr;
        return r;
    }

    @property bool empty() const { return _useCsr ? _csrI >= _csr.length : _inner.empty; }
    @property uint front() const { return _useCsr ? _csr[_csrI] : _loops[_inner.front].face; }
    void popFront() { if (_useCsr) ++_csrI; else _inner.popFront(); }
    @property VertexFaceRange save() const { return this; }
}

/// Task 0447 CSR-fallback helper: append `v` to `arr` unless already present.
/// Valence is single-digit to low tens on every real mesh, so a linear scan
/// is cheaper than a set and keeps this dependency-free.
private void csrAddUnique(ref uint[] arr, uint v) nothrow @safe {
    foreach (x; arr) if (x == v) return;
    arr ~= v;
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

    private const(uint)[] _csr;    // task 0447: materialized CSR fallback (see fromCsr)
    private uint   _csrI;
    private bool   _useCsr;

    this(const(Loop)[] loops, uint startLi) {
        _loops   = loops;
        _start   = startLi;
        _cur     = startLi;
        _done    = (startLi == ~0u);
        _atExtra = false;
        _steps   = 0;
    }

    /// Task 0447: complete (but arbitrarily ordered) neighbour enumeration for
    /// a vertex whose fan is not `vertexFanOrdered`. For every CSR dart `li`
    /// at `vi` (one per incident face), BOTH face-local edges touching `vi`
    /// contribute a neighbour — the succ side (`next(li).vert`) and the pred
    /// side (`prev(li).vert`) — deduped, since a shared edge is normally
    /// reached from two faces. This recovers the neighbour whose only darts
    /// are based at the OTHER endpoint (e.g. the hinge's inconsistently-wound
    /// spine), which a dart-succ-only projection would miss.
    static VertexNeighborRange fromCsr(const(Loop)[] loops,
                                        const(uint)[] vertDartStart,
                                        const(uint)[] vertDartAdj,
                                        uint vi)
    {
        VertexNeighborRange r;
        r._loops  = loops;
        r._useCsr = true;
        uint[] csr;
        if (vi + 1 < vertDartStart.length) {
            foreach (i; vertDartStart[vi] .. vertDartStart[vi + 1]) {
                uint li = vertDartAdj[i];
                csrAddUnique(csr, loops[loops[li].next].vert);
                csrAddUnique(csr, loops[loops[li].prev].vert);
            }
        }
        r._csr = csr;
        return r;
    }

    @property bool empty() const { return _useCsr ? _csrI >= _csr.length : _done; }

    @property uint front() const
    in (!empty)
    {
        if (_useCsr) return _csr[_csrI];
        // Main darts: neighbour is the next vertex in the dart.
        // Extra boundary dart: the open-end vertex is prev(cur).vert.
        return _atExtra ? _loops[_loops[_cur].prev].vert
                        : _loops[_loops[_cur].next].vert;
    }

    void popFront()
    in (!empty)
    {
        if (_useCsr) { ++_csrI; return; }
        if (_atExtra) { _done = true; return; }
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _atExtra = true; return; }
        // Task 0447 (KEEP-TWIN): same-direction ("meaning-3") twin — see
        // VertexDartRange.popFront. Stop as at a boundary (emit the extra
        // open-end neighbour). Never fires on consistent winding.
        if (_loops[twinPrev].vert == _loops[prevLi].vert) { _atExtra = true; return; }
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

    private const(uint)[] _csr;    // task 0447: materialized CSR fallback (see fromCsr)
    private uint   _csrI;
    private bool   _useCsr;

    this(const(Loop)[] loops, const(uint)[] loopEdge, uint startLi) {
        _loops    = loops;
        _loopEdge = loopEdge;
        _start    = startLi;
        _cur      = startLi;
        _done     = (startLi == ~0u);
        _atExtra  = false;
        _steps    = 0;
    }

    /// Task 0447: complete (but arbitrarily ordered) edge enumeration for a
    /// vertex whose fan is not `vertexFanOrdered`. For every CSR dart `li` at
    /// `vi` (one per incident face), BOTH face-local edges touching `vi`
    /// contribute — the succ edge (`loopEdge[li]`) and the pred edge
    /// (`loopEdge[prev(li)]`) — deduped, since a shared edge is normally
    /// reached from two faces (this is precisely how the hinge's marked spine
    /// edge shows up from BOTH its incident faces as a pred-edge, with neither
    /// face contributing it as a succ-edge).
    static VertexEdgeRange fromCsr(const(Loop)[] loops, const(uint)[] loopEdge,
                                    const(uint)[] vertDartStart,
                                    const(uint)[] vertDartAdj,
                                    uint vi)
    {
        VertexEdgeRange r;
        r._loops    = loops;
        r._loopEdge = loopEdge;
        r._useCsr   = true;
        uint[] csr;
        if (vi + 1 < vertDartStart.length) {
            foreach (i; vertDartStart[vi] .. vertDartStart[vi + 1]) {
                uint li = vertDartAdj[i];
                csrAddUnique(csr, loopEdge[li]);
                csrAddUnique(csr, loopEdge[loops[li].prev]);
            }
        }
        r._csr = csr;
        return r;
    }

    @property bool empty() const { return _useCsr ? _csrI >= _csr.length : _done; }

    @property uint front() const
    in (!empty)
    {
        if (_useCsr) return _csr[_csrI];
        return _atExtra ? _loopEdge[_loops[_cur].prev] : _loopEdge[_cur];
    }

    void popFront()
    in (!empty)
    {
        if (_useCsr) { ++_csrI; return; }
        if (_atExtra) { _done = true; return; }
        uint prevLi   = _loops[_cur].prev;
        uint twinPrev = _loops[prevLi].twin;
        if (twinPrev == ~0u) { _atExtra = true; return; }  // boundary: emit extra next
        // Task 0447 (KEEP-TWIN): same-direction ("meaning-3") twin — see
        // VertexDartRange.popFront. Stop as at a boundary (emit the extra
        // open-end edge). Never fires on consistent winding.
        if (_loops[twinPrev].vert == _loops[prevLi].vert) { _atExtra = true; return; }
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
         const(uint)[] vertLoop, const(bool)[] vertFanOrdered,
         const(uint)[] vertDartStart, const(uint)[] vertDartAdj,
         uint ei)
    {
        _count = 0; _i = 0;
        if (ei >= edges.length) return;
        uint va = edges[ei][0], vb = edges[ei][1];

        // Task 0447 §5/§5.1: gate on the ENDPOINTS' fan-order status, NOT a
        // flag on the edge itself. A same-direction edge leaves BOTH its
        // endpoints' fans unordered; but a single-face boundary edge sitting
        // on an endpoint whose fan is broken elsewhere would carry no flag of
        // its own — the endpoint-status gate catches that case too (measured:
        // 0 undercounts / 0 overcounts on every topology). `_tryFrom` routes
        // through the now-guarded VertexDartRange, which stops early at a
        // same-direction edge and can miss the dart va→vb, so collect the
        // incident faces straight from the CSR (never via `.twin`) instead.
        bool gate = (va >= vertFanOrdered.length || !vertFanOrdered[va])
                 || (vb >= vertFanOrdered.length || !vertFanOrdered[vb]);
        if (gate) {
            _collectViaCsr(loops, vertDartStart, vertDartAdj, va, vb);
            return;
        }

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

    /// Task 0447 §5: SDK-faithful remediation for the endpoints-gated path —
    /// collect the faces of the darts INCIDENT to the edge from BOTH endpoints
    /// via the CSR vertex→dart adjacency, never through `.twin` (which is
    /// exactly what is undefined-in-meaning on these edges). A dart at `from`
    /// is incident to this edge when its next vertex is `to`. `_faces` stays
    /// `uint[2]` (documented 1-2-face contract) — capped defensively so a
    /// non-manifold (3+ face) edge can never write past it; enumerating all
    /// 3+ faces there is out of scope (§5.2), not overflowing is the contract.
    private void _collectViaCsr(const(Loop)[] loops,
                                 const(uint)[] vertDartStart,
                                 const(uint)[] vertDartAdj,
                                 uint va, uint vb)
    {
        void scanFrom(uint from, uint to) {
            if (from + 1 >= vertDartStart.length) return;
            foreach (i; vertDartStart[from] .. vertDartStart[from + 1]) {
                uint li = vertDartAdj[i];
                if (loops[loops[li].next].vert != to) continue;
                uint fi = loops[li].face;
                bool dup = false;
                foreach (k; 0 .. _count) if (_faces[k] == fi) { dup = true; break; }
                if (!dup && _count < 2) _faces[_count++] = fi;
            }
        }
        scanFrom(va, vb);
        scanFrom(vb, va);
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
    // Hide (task 0632): the cage face every output face came from, recorded as
    // the faces are emitted. `addFaceFast` appends EXACTLY one face per call
    // (`faces ~= idx.dup`), so this array stays index-parallel with
    // `result.faces` without a second walk.
    uint[] outFaceOrigin;
    outFaceOrigin.reserve(m.faces.length);
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
                outFaceOrigin ~= cast(uint)fi;
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
            outFaceOrigin ~= cast(uint)fi;
        }
    }

    result.buildLoops();

    // Hide (task 0632): the rebuild used to DROP the Hide bit outright — the
    // result is a freshly constructed Mesh and nothing copied `faceMarks`
    // across — so a hidden face came back visible. That is the "dropped"
    // reading the measured law rules out; a hidden face must survive the
    // operation as exactly one hidden face. Each output face inherits its cage
    // face's bit, mirroring the same stamp in `catmullClarkOsd`
    // (subpatch_osd.d): a split face hands it to every child, an un-split face
    // carries its own across whole.
    //
    // Whether a hidden face is in the operand AT ALL is the caller's decision,
    // not this kernel's — the command layer passes `visibleFaceMask()`, so the
    // "hands it to every child" arm is unreachable from there. Keeping the
    // stamp unconditional means a caller that DOES refine a hidden face still
    // gets a defined answer instead of a silently cleared mark.
    result.resizeVertexSelection();
    result.resizeEdgeSelection();
    result.resizeFaceSelection();
    foreach (k, parentFi; outFaceOrigin)
        result.setFaceHiddenBit(k, m.isFaceHidden(parentFi));
    // Derived vertex/edge planes, computed on the OUTPUT topology. Must come
    // AFTER the three resizes — refreshHiddenDerived writes vertexMarks /
    // edgeMarks in place — and it early-outs to three word-OR scans when
    // nothing is hidden, so the common path pays nothing.
    result.refreshHiddenDerived();
    return result;
}

unittest { // facetedSubdivide: a hidden cage face comes through as exactly ONE
           // hidden face — the mark is neither dropped nor split (task 0632).
    import std.math : fabs;
    import std.conv : to;

    // Vacuity guard. With nothing hidden this same kernel is the wholesale
    // 24-quad refine, so the 21 below is a measurement of the exclusion and
    // not merely the number this kernel always produces.
    {
        Mesh all = makeCube();
        bool[] allMask = new bool[](all.faces.length);
        allMask[] = true;
        assert(facetedSubdivide(all, allMask).faces.length == 24,
            "vacuity: an unrestricted faceted subdivide of the cube is 24 faces");
    }

    Mesh m = makeCube();
    m.syncSelection();   // makeCube() does not size the marks arrays itself
    // Hide a MIDDLE face, never the last one. With the hidden face at f5 an
    // operand mask that was one element SHORT would exclude it for entirely
    // the wrong reason (an out-of-range read counts as unmarked), and the row
    // could not tell that implementation from the intended one.
    // makeCube's f2 = [0,4,7,3] is the x = -0.5 side.
    m.setFaceHidden(2, true);
    m.refreshHiddenDerived();

    Mesh sub = facetedSubdivide(m, m.visibleFaceMask());

    // 5 visible quads × 4 children + the hidden one carried through whole.
    assert(sub.faces.length == 21,
        "hidden face excluded from the operand: 5*4 + 1 = 21 faces");

    size_t nHidden = 0, hi = size_t.max;
    foreach (fi; 0 .. sub.faces.length)
        if (sub.isFaceHidden(fi)) { ++nHidden; hi = fi; }
    // Three readings, three different numbers: 0 = the rebuild dropped the
    // mark, 4 = the hidden face was refined and every child inherited the bit,
    // 1 = it was kept out of the operation. Only the last is the measured law,
    // and a test that asserted merely "hiding was not lost" would pass on two
    // of the three.
    assert(nHidden == 1,
        "exactly one hidden face must survive, got "
        ~ nHidden.to!string ~ " (0 = the rebuild dropped the mark, "
        ~ "4 = the hidden face was refined and every child inherited it)");

    // ...and it must be THE face that was hidden, not merely SOME face. The
    // survivor is the -X side carried across whole: eight corners (its four
    // originals plus the four edge points its refined neighbours spliced in),
    // every one of them at x = -0.5. Any other cube side spans x from -0.5 to
    // +0.5, and a refined CHILD of the hidden face would have four corners.
    assert(sub.faces[hi].length == 8,
        "the survivor is the widened cage face, not a refined child of it — "
        ~ "got " ~ sub.faces[hi].length.to!string ~ " corners, want 8");
    foreach (vi; sub.faces[hi])
        assert(fabs(sub.vertices[vi].x + 0.5f) < 1e-6f,
            "the survivor must be the x = -0.5 side — the face that was hidden");
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
        // Hide (task 0613, R4). This is the Tab-toggle REUSE key: preview off,
        // preview on again, and if the key matches we resurrect the cached
        // preview mesh WITHOUT re-running buildPreview. That cached mesh
        // carries the Hide marks stamped from the cage at build time
        // (subpatch_osd.d), so a hide performed while the preview was off must
        // land in this key or the resurrected preview draws the pre-hide set.
        // Folded as its own per-face term rather than OR-ed into the Subpatch
        // one, so "face i subpatch" and "face i hidden" cannot cancel.
        foreach (fi; 0 .. source.faces.length)
            h = hashOf(source.isFaceHidden(fi), h);
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
    m.resizeSubpatch();       // ensure faceMarks exists (was setFaceSubpatchFrom's job)
    m.setSubpatch(0, true);
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

    // Parity (fuzz D6): inset==0 && shift==0 is NOT a no-op — the reference
    // still builds a ZERO-WIDTH bevel ring (the inset cap coincides with the
    // original boundary). 8 orig + 4 coincident cap verts = 12; 6-1+1+4 = 10
    // all-quad faces. An EMPTY mask remains a genuine no-op.
    {
        auto mz = makeCube();
        bool[] mzmask; mzmask.length = mz.faces.length; mzmask[] = false; mzmask[4] = true;
        assert(mz.bevelFacesByMask(mzmask, 0.0f, 0.0f) == 1,
            "inset=0, shift=0 must build a zero-width ring (fuzz D6 parity)");
        assert(mz.vertices.length == 12, "zero-width ring: expected 12 verts");
        assert(mz.faces.length    == 10, "zero-width ring: expected 10 faces");
        int[int] fvd;
        foreach (f; mz.faces) fvd[cast(int)f.length]++;
        assert(fvd.get(4, 0) == 10, "zero-width ring: all faces must stay quads");

        auto me = makeCube();
        bool[] emptyMask; emptyMask.length = me.faces.length; emptyMask[] = false;
        assert(me.bevelFacesByMask(emptyMask, 0.0f, 0.0f) == 0,
            "empty mask must remain a no-op even at inset=0/shift=0");
        assert(me.vertices.length == 8);
        assert(me.faces.length    == 6);
    }

    // inset=0.1, shift=0.2 (m is still a pristine cube — the D6 block used
    // its own fresh meshes).
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

unittest { // bevelFacesByMask: exact-collapse ring (fuzz D3 parity) — an
           // inset at/beyond a face's inradius clamps to the collapse point.
           // The reference KEEPS that as a DEGENERATE QUAD RING (coincident
           // cap corners, zero-area cap + ring quads all stay 4-vertex), NOT
           // a welded + fan-triangulated cap. This is the corrected behaviour
           // of the former task-0304 overshoot guard, which welded the
           // collapse away (a `vibe3d-divergence`).
    import std.conv : to;

    // The top face (index 4 = [3,7,6,2]) is a unit square at y=0.5, normal
    // +Y, centroid (0,0.5,0). At/over inradius the four cap corners all land
    // on the shifted centroid → 12 verts (8 orig + 4 coincident cap), 10
    // all-quad faces (5 cube + 1 cap + 4 ring), with exactly 4 verts stacked
    // at the collapse point.
    void assertCollapseRing(ref Mesh m, string tag, float shift) {
        assert(m.vertices.length == 12,
            tag ~ ": expected 12 verts, got " ~ m.vertices.length.to!string);
        assert(m.faces.length == 10,
            tag ~ ": expected 10 faces, got " ~ m.faces.length.to!string);
        int quads = 0, tris = 0;
        foreach (f; m.faces) {
            if      (f.length == 4) ++quads;
            else if (f.length == 3) ++tris;
        }
        assert(quads == 10 && tris == 0,
            tag ~ ": expected 10 quads / 0 tris (degenerate quad ring, not a "
            ~ "fan), got " ~ quads.to!string ~ " quads / " ~ tris.to!string ~ " tris");
        immutable Vec3 collapse = Vec3(0, 0.5f + shift, 0);
        int atCollapse = 0;
        foreach (v; m.vertices)
            if ((v - collapse).length < 1e-5f) ++atCollapse;
        assert(atCollapse == 4,
            tag ~ ": expected 4 coincident cap corners at the collapse point, got "
            ~ atCollapse.to!string);
    }

    // inset==inradius (0.5 on a unit face) — the primary D3 repro.
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
        size_t n = m.bevelFacesByMask(mask, 0.5f, 0.0f);
        assert(n == 1, "inset==inradius should still process (clamped)");
        assertCollapseRing(m, "inset==inradius", 0.0f);
    }

    // inset==2x inradius clamps to the SAME collapse point → same ring.
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
        size_t n = m.bevelFacesByMask(mask, 1.0f, 0.0f);
        assert(n == 1, "inset==2x inradius should still process (clamped)");
        assertCollapseRing(m, "inset==2x inradius", 0.0f);
    }

    // Sanity: a normal small inset does NOT reach the collapse path — 12v/10f
    // with all four cap corners still DISTINCT (none stacked on the centroid).
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false; mask[4] = true;
        assert(m.bevelFacesByMask(mask, 0.1f, 0.0f) == 1);
        assert(m.vertices.length == 12, "normal inset must be unaffected by the collapse path");
        assert(m.faces.length    == 10);
        int atCentroid = 0;
        foreach (v; m.vertices)
            if ((v - Vec3(0, 0.5f, 0)).length < 1e-5f) ++atCentroid;
        assert(atCentroid == 0, "normal inset must not collapse any cap corner onto the centroid");
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

version (unittest) private Mesh buildRawMesh(Vec3[] verts, uint[][] faceList) {
    Mesh m;
    m.vertices = verts;
    m.faces    = faceList;
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

unittest { // bevelFacesByMask: GROUP accumulator on ASYMMETRIC geometry —
           // task 0458 Phase 1, finding G1 (internalCnt==1, half-shared).
           // poly_bevel_corner.json's 3-face cube corner is axis-aligned —
           // its incident normals are mutually orthogonal, where the
           // reference's AVE_N=k·N/|N|² degenerates to the naive
           // Σ(unit normal) sum (the SAME 0453-class symmetry trap this
           // task's brief warns about). This raw mesh is a deliberately
           // asymmetric "tent" (non-90° dihedral, unequal adjacent-edge
           // lengths) — a naive-sum accumulator FAILS it; bit-exact
           // against the frozen reference dump (`poly_bevel_
           // G1_halfshared_tent`, 6.2e-9 on the reference side) is the
           // discriminator. See tests/fixtures/poly_bevel_G1_halfshared_
           // tent.json for the same case run through the HTTP fixture path.
    auto m = buildRawMesh(
        [Vec3(0.0f, 0.0f, 0.0f), Vec3(0.0f, 0.0f, 2.0f), Vec3(1.5f, 0.8f, 2.0f),
         Vec3(1.5f, 0.8f, 0.0f), Vec3(-0.7f, 1.0f, 0.0f), Vec3(-0.7f, 1.0f, 2.0f)],
        [[0u,1,2,3], [1u,0,4,5]]);
    bool[] mask = [true, true];
    size_t n = m.bevelFacesByMask(mask, 0.1f, 0.1f, true, 0);
    assert(n == 2);
    assert(m.vertices.length == 12, "6 orig (unchanged) + 2 shared ridge + 4 standalone");
    assert(m.faces.length    == 8,  "2 final quads + 2 faces x 3 remaining boundary bridges");

    bool foundA = false, foundB = false;
    foreach (v; m.vertices) {
        if ((v - Vec3(0.03111569f, 0.12992836f, 0.1f)).length < 1e-4f) foundA = true;
        if ((v - Vec3(0.03111569f, 0.12992836f, 1.9f)).length < 1e-4f) foundB = true;
    }
    assert(foundA, "shared ridge endpoint A should land at the AVE_N-amplified shift + inset-along-ridge position");
    assert(foundB, "shared ridge endpoint B (same accumulator, mirrored) should match too");
}

unittest { // bevelFacesByMask: GROUP accumulator, finding G2 (fully-enclosed
           // apex, internalCnt>=2 && !anyBoundary) — task 0458 Phase 1
           // (+ follow-up). Valence-3 apex surrounded by 3 irregular
           // NON-planar, non-orthogonal quads (all selected); the apex has
           // 3 internal edges and no boundary edge. `orig + shift·AVE_N`
           // (no inset term) is bit-exact against the reference dump
           // (`poly_bevel_G2_apex_v3`, 2.6e-8) for the apex vertex itself.
           // The SAME dump's ring vertices (each internalCnt==1, shared
           // between 2 of the 3 faces) are now ALSO bit-exact via the
           // recovered `bevGenInset` mitered-corner offset
           // (`boundaryContourInset`/`findGroupBoundaryContour`, task 0458
           // follow-up, findings.md §1/§5) — the position gap this
           // unittest used to document is closed.
    auto m = buildRawMesh(
        [Vec3(1.0f, 0.0f, 0.0f), Vec3(0.6f, -0.1f, 1.1f), Vec3(-0.5f, 0.05f, 1.3f),
         Vec3(-1.2f, -0.05f, 0.2f), Vec3(-0.7f, 0.1f, -1.0f), Vec3(0.5f, -0.2f, -0.9f),
         Vec3(0.1f, 1.0f, 0.05f)],
        // reference dump used reverse_winding=true for +Y outward normals —
        // pre-reversed here so vibe3d's own faceNormal() convention matches.
        [[2u,1,0,6], [4u,3,2,6], [0u,5,4,6]]);
    bool[] mask = [true, true, true];
    size_t n = m.bevelFacesByMask(mask, 0.1f, 0.1f, true, 0);
    assert(n == 3);
    bool foundApex = false;
    foreach (v; m.vertices)
        if ((v - Vec3(0.13126321f, 1.18738139f, 0.04756028f)).length < 1e-4f) foundApex = true;
    assert(foundApex, "fully-enclosed apex should sit at orig + shift*AVE_N (bit-exact against poly_bevel_G2_apex_v3)");

    // Ring vertices (dump[7]/[9]/[11], near orig-vert 0/2/4): bit-exact
    // against `poly_bevel_G2_apex_v3` via the recovered mitered-corner
    // offset (task 0458 follow-up).
    bool foundRing0 = false, foundRing2 = false, foundRing4 = false;
    foreach (v; m.vertices) {
        if ((v - Vec3(1.01231349f, 0.14855729f, -0.00942456f)).length < 1e-4f) foundRing0 = true;
        if ((v - Vec3(-0.48344547f, 0.20435742f, 1.27598262f)).length < 1e-4f) foundRing2 = true;
        if ((v - Vec3(-0.67538124f, 0.25805962f, -0.98621768f)).length < 1e-4f) foundRing4 = true;
    }
    assert(foundRing0, "ring vertex near orig-vert 0 should be bit-exact against poly_bevel_G2_apex_v3's dump[7]");
    assert(foundRing2, "ring vertex near orig-vert 2 should be bit-exact against poly_bevel_G2_apex_v3's dump[9]");
    assert(foundRing4, "ring vertex near orig-vert 4 should be bit-exact against poly_bevel_G2_apex_v3's dump[11]");
    // STANDALONE ring vertices (dump[8]/[10]/[12], near orig-vert 1/3/5 —
    // each touches only ONE selected face, internalCnt==0). These sit in the
    // grouped-standalone per-corner-AVE_N regime: `orig + shift*cn +
    // boundaryContourInset(eNext,ePrev, cn)` with `cn` the corner's own shift
    // normal (NOT the whole-face Newell normal, which is measurably worse).
    // Bit-exact against poly_bevel_G2_apex_v3's dump[8]/[10]/[12] (parity task).
    bool foundStd1 = false, foundStd3 = false, foundStd5 = false;
    foreach (v; m.vertices) {
        if ((v - Vec3(0.54333192f, 0.02258310f, 1.02778912f)).length < 1e-4f) foundStd1 = true;
        if ((v - Vec3(-1.10951495f, 0.07091790f, 0.19473825f)).length < 1e-4f) foundStd3 = true;
        if ((v - Vec3(0.46943665f, -0.06014295f, -0.84538692f)).length < 1e-4f) foundStd5 = true;
    }
    assert(foundStd1, "grouped-standalone vertex near orig-vert 1 should be bit-exact against poly_bevel_G2_apex_v3's dump[8]");
    assert(foundStd3, "grouped-standalone vertex near orig-vert 3 should be bit-exact against poly_bevel_G2_apex_v3's dump[10]");
    assert(foundStd5, "grouped-standalone vertex near orig-vert 5 should be bit-exact against poly_bevel_G2_apex_v3's dump[12]");
}

unittest { // bevelFacesByMask: GROUP accumulator, finding G3 (partial,
           // internalCnt>=2 && anyBoundary) — task 0458 Phase 1 (+
           // follow-up). Before Phase 1 the branch fell through entirely,
           // so a partial vertex got the STANDALONE per-face formula
           // applied once per incident face — 3 SEPARATE vertices instead
           // of the reference's ONE shared vertex (a topology divergence,
           // not just numeric). Valence-4 fan, only 3 of 4 quads selected,
           // so the shared apex has 2 internal + 2 boundary edges.
           //
           // This asserts BOTH the topology fix (one shared vertex,
           // referenced by every incident new face, matching the
           // reference's vertex/face counts) AND — since the follow-up —
           // the exact position via the recovered `bevGenInset`
           // mitered-corner offset (`boundaryContourInset`/
           // `findGroupBoundaryContour`, findings.md §1/§5): `orig +
           // shift·AVE_N + boundaryInset`, bit-exact against
           // `poly_bevel_G3_partial_fan`'s shared apex vertex (1.1e-8).
    import std.conv : to;
    auto m = buildRawMesh(
        [Vec3(1.0f, 0.0f, 0.0f), Vec3(0.7f, -0.1f, 0.8f), Vec3(0.0f, 0.05f, 1.2f),
         Vec3(-0.9f, -0.05f, 0.7f), Vec3(-1.1f, 0.1f, -0.1f), Vec3(-0.6f, -0.15f, -0.9f),
         Vec3(0.2f, 0.05f, -1.1f), Vec3(0.8f, -0.2f, -0.7f), Vec3(0.05f, 0.9f, 0.0f)],
        // reference dump used reverse_winding=true — pre-reversed.
        [[2u,1,0,8], [4u,3,2,8], [6u,5,4,8], [0u,7,6,8]]);
    bool[] mask = [true, true, true, false]; // only 3 of 4 quads selected
    size_t n = m.bevelFacesByMask(mask, 0.1f, 0.1f, true, 0);
    assert(n == 3);
    // Reference: 9 orig + 8 new = 17 verts; 12 faces (3 final quads + the
    // 4th untouched quad + bridges over the 4 remaining boundary edges of
    // the 3-face selection — matches poly_bevel_G3_partial_fan's 17v/12f).
    assert(m.vertices.length == 17, "partial-fan topology should match the reference vertex count (shared, not split)");
    assert(m.faces.length    == 12);

    // The shared partial vertex must sit at the bit-exact recovered
    // position (poly_bevel_G3_partial_fan's dump[16]) AND be referenced by
    // every incident new face exactly once (not duplicated into 3 separate
    // vertices, one per selected face, the pre-0458 fallback's behavior).
    immutable Vec3 expectedShared = Vec3(-0.07055401f, 1.00857651f, 0.10307505f);
    uint sharedIdx = uint.max;
    foreach (i, v; m.vertices)
        if ((v - expectedShared).length < 1e-4f) { sharedIdx = cast(uint)i; break; }
    assert(sharedIdx != uint.max,
        "expected the shared partial vertex bit-exact at orig + shift*AVE_N + boundaryInset (poly_bevel_G3_partial_fan's dump[16])");
    size_t refCount = 0;
    foreach (f; m.faces)
        foreach (v; f)
            if (v == sharedIdx) { ++refCount; break; }
    assert(refCount == 5, "the shared partial vertex should be referenced by all 5 incident faces (3 final + 2 bridges), got " ~ refCount.to!string);

    // STANDALONE corners (orig 0/1/3/5/6 — each internalCnt==0, touching one
    // selected face). Grouped-standalone per-corner-AVE_N regime: bit-exact
    // against poly_bevel_G3_partial_fan's dump[9]/[10]/[12]/[14]/[15]
    // (parity task).
    bool fStd0=false, fStd1=false, fStd3=false, fStd5=false, fStd6=false;
    foreach (v; m.vertices) {
        if ((v - Vec3(0.95582151f, 0.12657540f, 0.12734687f)).length < 1e-4f) fStd0 = true;
        if ((v - Vec3(0.65931493f, 0.03504139f, 0.75914669f)).length < 1e-4f) fStd1 = true;
        if ((v - Vec3(-0.84032083f, 0.08062109f, 0.66145885f)).length < 1e-4f) fStd3 = true;
        if ((v - Vec3(-0.57754570f, -0.00480662f, -0.87185556f)).length < 1e-4f) fStd5 = true;
        if ((v - Vec3(0.06068159f, 0.16000065f, -1.05715966f)).length < 1e-4f) fStd6 = true;
    }
    assert(fStd0, "grouped-standalone vertex near orig-vert 0 should be bit-exact against poly_bevel_G3_partial_fan's dump[9]");
    assert(fStd1, "grouped-standalone vertex near orig-vert 1 should be bit-exact against poly_bevel_G3_partial_fan's dump[10]");
    assert(fStd3, "grouped-standalone vertex near orig-vert 3 should be bit-exact against poly_bevel_G3_partial_fan's dump[12]");
    assert(fStd5, "grouped-standalone vertex near orig-vert 5 should be bit-exact against poly_bevel_G3_partial_fan's dump[14]");
    assert(fStd6, "grouped-standalone vertex near orig-vert 6 should be bit-exact against poly_bevel_G3_partial_fan's dump[15]");
}

unittest { // bevelFacesByMask: WARPED single quad, ISOLATED-face inset law —
           // captured-reference parity (task 0467). A symmetric saddle quad
           // (z alternates ±0.2 around the ring → strongly non-planar; its
           // whole-face Newell normal is exactly +Z) beveled as a SINGLE
           // face. This is the `poly_bevel_W1_warped_standalone` oracle,
           // rr/gdb-grounded (findings.md §6): the reference places each inset
           // corner by a mitered offset in the tangent plane ⟂ the WHOLE-FACE
           // normal (`boundaryContourInset(faceNormal)`) plus `faceNormal·
           // shift`, NOT by the old `offsetMeet` line-intersection (which
           // slides off the tilted edges and lands ~0.06 off in the normal
           // direction). The captured reference output (v4..v7) is bit-exact.
    auto m = buildRawMesh(
        [Vec3(-0.5f,-0.5f, 0.2f), Vec3(0.5f,-0.5f,-0.2f),
         Vec3( 0.5f, 0.5f, 0.2f), Vec3(-0.5f, 0.5f,-0.2f)],
        [[0u,1,2,3]]);
    immutable float inset = 0.15f, shift = 0.1f;
    const Vec3 n = m.faceNormal(0);
    assert((n - Vec3(0, 0, 1)).length < 1e-6f, "saddle quad's Newell normal must be +Z");
    size_t nb = m.bevelFacesByMask([true], inset, shift, false, 0);
    assert(nb == 1);
    // Captured reference (poly_bevel_W1_warped_standalone_group): the 4 inset
    // cap corners. XY = the in-tangent-plane 90° miter (±0.35); Z = orig ±0.2
    // shifted by +0.1 along the whole-face +Z normal (→ 0.30 / -0.10).
    immutable Vec3[4] refCap = [
        Vec3(-0.35f, -0.35f,  0.30f), Vec3( 0.35f, -0.35f, -0.10f),
        Vec3( 0.35f,  0.35f,  0.30f), Vec3(-0.35f,  0.35f, -0.10f)];
    // The old off-plane `offsetMeet` law (what the corner would get without
    // the fix): same XY, but Z = orig ± (inset-slide) + shift — lands ~0.06
    // off in Z. Assert the mesh is on the reference value and NOT the old one.
    foreach (mc; refCap) {
        bool found = false;
        foreach (v; m.vertices) if ((v - mc).length < 1e-4f) { found = true; break; }
        assert(found, "warped isolated-face cap corner must be bit-exact to the captured reference (poly_bevel_W1)");
    }
    // Guard the fix is actually engaged (not accidentally the old law): the
    // old whole-face `offsetMeet` corner for v0 would sit at z≈0.24, absent.
    bool foundOld = false;
    foreach (v; m.vertices)
        if ((v - Vec3(-0.35f, -0.35f, 0.24f)).length < 1e-3f) foundOld = true;
    assert(!foundOld, "the pre-0467 off-plane offsetMeet corner (z≈0.24) must be gone");
}

unittest { // bevelFacesByMask: FLAT quad stays on the OLD whole-face law
           // (task 0467 planarity gate — flat-face byte-identity guard). A
           // planar quad's per-corner normal equals its face normal, so the
           // gate (`dot(cn,n) >= 1-1e-6`) keeps the exact pre-0467
           // `insetCorner + n·shift` expression — every flat-face bevel
           // fixture is unaffected.
    auto m = buildRawMesh(
        [Vec3(-0.5f,-0.5f, 0.0f), Vec3(0.5f,-0.5f, 0.0f),
         Vec3( 0.5f, 0.5f, 0.0f), Vec3(-0.5f, 0.5f, 0.0f)],
        [[0u,1,2,3]]);
    immutable float inset = 0.2f, shift = 0.13f;
    Vec3[] origPos = [m.vertices[0], m.vertices[1], m.vertices[2], m.vertices[3]];
    const Vec3 n = m.faceNormal(0);
    Vec3[4] expOld;
    foreach (i; 0 .. 4) {
        immutable Vec3 cn = m.cornerNormalAt(0, cast(uint)i);
        assert(dot(cn, n) >= 1.0f - 1e-6f, "flat quad corner normal must equal the face normal");
        expOld[i] = m.insetCorner(origPos, cast(int)i, n, inset) + n * shift;
    }
    assert(m.bevelFacesByMask([true], inset, shift, false, 0) == 1);
    foreach (i; 0 .. 4) {
        bool exact = false;
        foreach (v; m.vertices) if (v == expOld[i]) { exact = true; break; } // byte-exact
        assert(exact, "flat cap corner must be BYTE-IDENTICAL to the pre-0467 insetCorner+n*shift law");
    }
}

unittest { // boundaryContourInset degeneracy gate (task 0467 reviewer NIT):
           // when e_b is PARALLEL to aveN the U-direction is undefined and
           // safeNormalize would fabricate a bogus finite (0,1,0); the
           // source-level |cross(e_b,aveN)| gate must reject it (return
           // false) so the caller falls back — NOT return bogus geometry.
    Vec3 res;
    // e_b ∥ aveN (both along +Y, different magnitudes): must gate out.
    assert(!Mesh.boundaryContourInset(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,2,0), 0.1f, res),
        "e_b ∥ aveN must fall to the fallback (degenerate U)");
    // Anti-parallel projection (G1-style D→0): D sums to ~zero, |D·U| gate.
    assert(!Mesh.boundaryContourInset(Vec3(1,0,0), Vec3(-1,0,0), Vec3(0,0,1), 0.1f, res),
        "anti-parallel tangent-plane edges (D→0) must fall to the fallback");
    // A well-conditioned 90° corner in a plane returns a finite miter.
    assert(Mesh.boundaryContourInset(Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), 0.1f, res),
        "a well-conditioned corner should yield a finite mitered offset");
}

unittest { // bevelFacesByMask: GROUP x SEGMENTS — task 0458 Phase 1 (+S1),
           // finding S1. mesh.d's own doc comment marked this combination
           // "KNOWN-UNTESTED" before this task. Orthogonal 2-face cube
           // selection (AVE_N coincides with the naive sum here — see the
           // asymmetric G1 unittest above for the discriminator) isolates
           // the segments x group interaction: the shared ridge corner
           // must be segmented the same equal-lerp way as every other
           // boundary vertex, AND its intermediate (non-final) ring vertex
           // must be shared across both faces (not duplicated per face —
           // the pre-0458 kernel created 22 verts here; the reference/
           // fixed kernel produces 20, matching poly_bevel_S1_group_segs2).
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    mask[1] = true; // +Z = [4,5,6,7]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, true, 2);
    assert(n == 2);
    assert(m.vertices.length == 20, "expected 20 verts (8 orig + 6 intermediate-ring + 6 final-ring, shared corner not duplicated)");
    assert(m.faces.length    == 18);
    bool foundMidShared = false;
    foreach (v; m.vertices)
        if ((v - Vec3(0.375f, 0.575f, 0.575f)).length < 1e-4f) foundMidShared = true;
    assert(foundMidShared, "the group-shared corner's t=1-of-2 intermediate ring vertex should land at exactly half inset/half shift (0.375,0.575,0.575)");
}

unittest { // bevelFacesByMask: SQUARE CORNER, finding Q1 (single-face, no
           // group) — task 0458 Phase 3. See `poly_bevel_Q1_single_square`
           // (toolcards/poly.bevel/findings.md §3): one cube top face,
           // inset=0.25, shift=0.15, square=true → 20v/14f. Every corner is
           // STANDALONE (no group): 8 orig (retained) + 4 final inset/shift
           // corners + 8 split points (2 per original top-face edge, at
           // distance=inset from each endpoint) = 20. 1 bottom quad + 4
           // side hexagons (absorb the 2 splits on their shared edge) + 1
           // inner quad + 4 edge-panel quads + 4 corner-cap quads = 14.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, false, 0, true);
    assert(n == 1);
    assert(m.vertices.length == 20, "8 orig + 4 final corners + 8 split points");
    assert(m.faces.length    == 14, "1 bottom + 4 side hexagons + 1 inner + 4 panels + 4 caps");

    // Original top-face corners MUST be retained (square keeps them, unlike
    // the non-square kernel which replaces them outright).
    foreach (orig; [Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,0.5f,0.5f),
                    Vec3(0.5f,0.5f,0.5f),   Vec3(0.5f,0.5f,-0.5f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - orig).length < 1e-5f) found = true;
        assert(found, "original top-face corner should be retained by square");
    }
    // The 4 final inset+shift corners (same law as the non-square kernel,
    // just now a SEPARATE vertex from the retained original corner).
    foreach (fc; [Vec3(-0.25f,0.65f,-0.25f), Vec3(-0.25f,0.65f,0.25f),
                  Vec3(0.25f,0.65f,0.25f),   Vec3(0.25f,0.65f,-0.25f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - fc).length < 1e-4f) found = true;
        assert(found, "expected final inset+shift corner missing");
    }
    // Split points: distance=inset (0.25) from each original corner along
    // the ORIGINAL (un-shifted) top-face edges.
    foreach (sp; [Vec3(-0.25f,0.5f,-0.5f), Vec3(-0.5f,0.5f,-0.25f),
                  Vec3(-0.5f,0.5f,0.25f),  Vec3(-0.25f,0.5f,0.5f),
                  Vec3(0.25f,0.5f,0.5f),   Vec3(0.5f,0.5f,0.25f),
                  Vec3(0.5f,0.5f,-0.25f),  Vec3(0.25f,0.5f,-0.5f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - sp).length < 1e-4f) found = true;
        assert(found, "expected split point missing");
    }
}

unittest { // bevelFacesByMask: SQUARE CORNER, finding Q2 (two NON-adjacent
           // faces) — task 0458 Phase 3. `poly_bevel_Q2_nonadjacent_square`
           // (findings.md §3): cube top (+Y) AND bottom (-Y), group=true
           // (inert — no shared edge, so square is pure per-face), inset=
           // 0.25, shift=0.15 → 32v/22f: two INDEPENDENT Q1 patterns, and
           // the 4 side faces (each bordering BOTH squares) become
           // OCTAGONS (absorb 2 splits from top + 2 from bottom).
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    mask[5] = true; // -Y = [0,1,5,4]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, true, 0, true);
    assert(n == 2);
    assert(m.vertices.length == 32, "8 orig + 2x(4 final + 8 splits) = 32");
    assert(m.faces.length    == 22, "2 inner + 2x(4 panels+4 caps) + 4 octagon sides = 22");

    size_t octagons = 0, quads = 0;
    foreach (f; m.faces) {
        if (f.length == 8) ++octagons;
        else if (f.length == 4) ++quads;
    }
    assert(octagons == 4, "the 4 side faces should each become an octagon");
    // 2 inner (final) quads + 2x4 panel quads + 2x4 cap quads = 18 quads.
    assert(quads == 18, "expected 18 remaining quads (2 inner + 8 panels + 8 caps)");
}

unittest { // bevelFacesByMask: SQUARE CORNER, finding Q3 (square + segments
           // together) — task 0458 Phase 3. `poly_bevel_Q3_square_segs2`
           // (findings.md §3): one cube top face, inset=0.25, shift=0.15,
           // segments=2, square=true → 24v/18f. Square treatment applies
           // ONLY at the outermost ring (original boundary → ring[1]),
           // split distance = inset/segs = 0.125; the remaining ring
           // (ring[1] → ring[2]=final) interpolates via plain (unsquared)
           // quads, unchanged from the ordinary segments path.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, false, 2, true);
    assert(n == 1);
    assert(m.vertices.length == 24, "8 orig + 4 ring1(half-step) + 4 final(full-step) + 8 splits(at inset/segs=0.125)");
    assert(m.faces.length    == 18, "1 bottom + 4 side hexagons + 1 final-inner + 4 square-panels + 4 square-caps + 4 plain ring1->final panels");

    // Splits at HALF the full inset (0.125, the outermost ring's own step),
    // NOT the full 0.25 — the Q3-specific finding.
    foreach (sp; [Vec3(-0.375f,0.5f,-0.5f), Vec3(-0.5f,0.5f,-0.375f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - sp).length < 1e-4f) found = true;
        assert(found, "expected split point at inset/segs=0.125, not the full inset");
    }
    // ring1 (half-step) corner and the true final corner both present.
    bool foundRing1 = false, foundFinal = false;
    foreach (v; m.vertices) {
        if ((v - Vec3(-0.375f,0.575f,-0.375f)).length < 1e-4f) foundRing1 = true;
        if ((v - Vec3(-0.25f,0.65f,-0.25f)).length   < 1e-4f) foundFinal = true;
    }
    assert(foundRing1, "expected ring1 (half-step) corner");
    assert(foundFinal, "expected the true final (full-step) corner");
}

unittest { // bevelFacesByMask: SQUARE CORNER, finding Q4 (grouped, 2
           // adjacent faces) — task 0458 Phase 3. `poly_bevel_two_faces_
           // grouped_square1` (findings.md §3): the SAME 2-face selection
           // as the GROUPxSEGMENTS unittest above (+Y, +Z sharing one
           // ridge edge), inset=0.25, shift=0.15, group=true, square=true,
           // segments=0 → 22v/16f (a full topology rewrite, re-verified
           // bit-exact against the reference dump). The two RIDGE corners
           // (the shared edge's endpoints) get NEITHER split NOR cap —
           // they stay at their ORIGINAL position, connected directly into
           // the two edge-panels meeting there.
    auto m = makeCube();
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[4] = true; // +Y = [3,7,6,2]
    mask[1] = true; // +Z = [4,5,6,7]
    size_t n = m.bevelFacesByMask(mask, 0.25f, 0.15f, true, 0, true);
    assert(n == 2);
    assert(m.vertices.length == 22, "8 orig + 6 final ring corners (4 standalone + 2 shared ridge) + 8 splits (4 standalone corners x 2, ridge corners get none)");
    assert(m.faces.length    == 16, "4 unselected hexagons + 2 inner quads + 6 panels (one per boundary-contour edge) + 4 caps (standalone corners only)");

    // The ridge (shared) corner — the top-front edge's own two endpoints,
    // (-0.5,0.5,0.5) and (0.5,0.5,0.5) — must be RETAINED at their exact
    // original position (no split, no cap moves them).
    foreach (orig; [Vec3(-0.5f,0.5f,0.5f), Vec3(0.5f,0.5f,0.5f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - orig).length < 1e-5f) found = true;
        assert(found, "ridge corner should be retained at its original position");
    }
    // The ridge corners' shared FINAL positions (bit-exact against the
    // non-square group law, poly_bevel_two_faces_grouped.json's own ridge
    // verts — same formula, square just wraps it).
    foreach (fc; [Vec3(0.25f,0.65f,0.65f), Vec3(-0.25f,0.65f,0.65f)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - fc).length < 1e-4f) found = true;
        assert(found, "expected ridge corner's shared final (group-solved) position");
    }
    size_t hexagons = 0;
    foreach (f; m.faces) if (f.length == 6) ++hexagons;
    assert(hexagons == 4, "the 4 unselected side/bottom faces bordering the group's boundary contour should become hexagons");
}

unittest { // bevelFacesByMask: square=false is byte-identical to the
           // pre-Phase-3 kernel — task 0458 Phase 3 regression guard. Same
           // selection/params as the Q1 unittest above, just without the
           // trailing `square` arg (defaults false) vs. explicitly false.
    auto m0 = makeCube();
    auto m1 = makeCube();
    bool[] mask; mask.length = m0.faces.length; mask[] = false;
    mask[4] = true;
    size_t n0 = m0.bevelFacesByMask(mask, 0.25f, 0.15f); // pre-0458-Phase-3 call site (5 args)
    size_t n1 = m1.bevelFacesByMask(mask, 0.25f, 0.15f, false, 0, false); // explicit square=false
    assert(n0 == 1 && n1 == 1);
    assert(m0.vertices.length == m1.vertices.length);
    assert(m0.faces.length    == m1.faces.length);
    assert(m0.vertices.length == 12, "square=false: 8 orig + 4 final — no split points, no retained-original-plus-final duplication");
    foreach (i; 0 .. m0.vertices.length)
        assert((m0.vertices[i] - m1.vertices[i]).length < 1e-9f, "square=false must be byte-identical regardless of how it's spelled");
}

unittest { // bevelFacesByMask: 0458 Phase-3 hardening — square with a ZERO
           // effective inset (inset=0, shift>0, square=true — reachable via the
           // square UI toggle) must NOT produce degenerate zero-area caps or
           // duplicate verts. The `doSquare = square && effInset>eps` gate makes
           // it fall back to the plain (square=false) shift bevel.
    auto m0 = makeCube();
    auto m1 = makeCube();
    bool[] mask; mask.length = m0.faces.length; mask[] = false;
    mask[4] = true;
    m0.bevelFacesByMask(mask, 0.0f, 0.15f, false, 0, true);  // inset=0, square ON
    m1.bevelFacesByMask(mask, 0.0f, 0.15f, false, 0, false); // inset=0, square OFF
    assert(m0.vertices.length == m1.vertices.length,
        "square+inset=0 must fall back to the plain bevel — no extra split/cap verts");
    assert(m0.faces.length == m1.faces.length,
        "square+inset=0 must fall back to the plain bevel — no extra cap/panel faces");
    foreach (i; 0 .. m0.vertices.length)
        assert((m0.vertices[i] - m1.vertices[i]).length < 1e-9f,
            "square+inset=0 must be byte-identical to square=false (doSquare gate)");
    foreach (i; 0 .. m0.vertices.length)
        foreach (j; i + 1 .. m0.vertices.length)
            assert((m0.vertices[i] - m0.vertices[j]).length > 1e-7f,
                "square+inset=0 must not introduce coincident/duplicate vertices");
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
version (unittest) private int[] naiveWeldRemap_(const Vec3[] verts, double epsSq, size_t protectBelow) {
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
            ulong key = edgeKey(f[k], f[(k + 1) % f.length]);
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
version (unittest) private size_t countOpenEdges(ref Mesh m) {
    int[2][ulong] ef;
    foreach (i, f; m.faces)
        foreach (k; 0 .. f.length) {
            ulong key = edgeKey(f[k], f[(k+1)%f.length]);
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

// ---------------------------------------------------------------------------
// weldVertexPairs (task 0555) — N independent absorptions in one pass.
//
// The rig is a two-quad strip, which is the shape the reference measurement
// was taken on and the smallest mesh where the interesting deltas appear:
//
//     3 ---- 4 ---- 5          F0 = [0,1,4,3]   F1 = [1,2,5,4]
//     |  F0  |  F1  |          V=6  E=7  F=2
//     0 ---- 1 ---- 2
// ---------------------------------------------------------------------------
version (unittest) private Mesh makeWeldPairStrip() {
    Mesh m;
    m.addVertex(Vec3(-1, 0, 0)); m.addVertex(Vec3(0, 0, 0)); m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(-1, 1, 0)); m.addVertex(Vec3(0, 1, 0)); m.addVertex(Vec3(1, 1, 0));
    m.addFace([0u, 1u, 4u, 3u]);
    m.addFace([1u, 2u, 5u, 4u]);
    m.rebuildEdges();
    m.buildLoops();
    return m;
}

unittest { // the EDGE-grab cell: two pairs, welded independently, in ONE call
    import std.conv : to;
    import std.math : abs;
    Mesh m = makeWeldPairStrip();
    assert(m.vertices.length == 6 && m.edges.length == 7 && m.faces.length == 2,
        "strip rig: expected V=6 E=7 F=2, got V=" ~ m.vertices.length.to!string
        ~ " E=" ~ m.edges.length.to!string ~ " F=" ~ m.faces.length.to!string);

    // Drag the middle edge 1-4 onto the right edge 2-5: vertex 1 is absorbed
    // by 2 and vertex 4 by 5, each into its OWN target. This is the measured
    // delta (task 0545): dV -2, dE -3, dF -1.
    uint[2][] pairs = [[2u, 1u], [5u, 4u]];
    assert(m.weldVertexPairs(pairs) == 2,
        "both endpoints must be absorbed, independently — one call, two welds");

    assert(m.vertices.length == 4,
        "edge-grab weld: expected V=4 (dV -2), got " ~ m.vertices.length.to!string);
    assert(m.edges.length == 4,
        "edge-grab weld: expected E=4 (dE -3), got " ~ m.edges.length.to!string);
    assert(m.faces.length == 1,
        "edge-grab weld: expected F=1 (dF -1) — the quad the grabbed edge was "
        ~ "dragged across collapses; got " ~ m.faces.length.to!string);

    // The survivors sit where the TARGETS were, never at a midpoint: the grab
    // is absorbed INTO the target, the target does not move to meet it.
    bool at10 = false, at11 = false;
    foreach (v; m.vertices) {
        if (abs(v.x - 1.0f) < 1e-6f && abs(v.y)        < 1e-6f) at10 = true;
        if (abs(v.x - 1.0f) < 1e-6f && abs(v.y - 1.0f) < 1e-6f) at11 = true;
    }
    assert(at10 && at11, "both weld targets must survive at their own positions");
    foreach (v; m.vertices)
        assert(abs(v.x) > 1e-6f,
            "no survivor may sit at x=0 — that is where the absorbed grab was");
}

unittest { // the VERTEX-grab cell: one pair, and BOTH quads become triangles
    import std.conv : to;
    Mesh m = makeWeldPairStrip();
    uint[2][] pairs = [[4u, 1u]];      // vertex 1 dragged onto vertex 4
    assert(m.weldVertexPairs(pairs) == 1, "the single grab must be absorbed");
    assert(m.vertices.length == 5,
        "vertex-grab weld: expected V=5 (dV -1), got " ~ m.vertices.length.to!string);
    assert(m.faces.length == 2,
        "vertex-grab weld: both faces survive, got " ~ m.faces.length.to!string);
    foreach (i, ref f; m.faces)
        assert(f.length == 3,
            "vertex-grab weld: face " ~ i.to!string ~ " must be a TRIANGLE (the "
            ~ "measured 'two quads become triangles'), got length " ~ f.length.to!string);
}

unittest { // a CHAIN is refused whole, not silently followed one link deep
    import std.conv : to;
    Mesh m = makeWeldPairStrip();
    // [4,1] absorbs 1 into 4 while [1,0] absorbs 0 into 1 — vertex 1 is both a
    // target and a casualty. BOTH links are refused rather than one being
    // applied and the other left pointing at a dead vertex: the rewrite reads
    // the remap once per corner and does not chase, so a surviving link would
    // be silent corruption. Order-independent by construction.
    uint[2][] pairs = [[4u, 1u], [1u, 0u]];
    immutable size_t welded = m.weldVertexPairs(pairs);
    assert(welded == 0,
        "a chain must be refused whole — expected 0 welds, got " ~ welded.to!string);
    assert(m.vertices.length == 6 && m.faces.length == 2,
        "chain reject: the mesh must be untouched, got V="
        ~ m.vertices.length.to!string ~ " F=" ~ m.faces.length.to!string);
}

unittest { // non-adjacent same-face pairs are refused, exactly as weldVertexPair
    import std.conv : to;
    Mesh m = makeWeldPairStrip();
    // 0 and 4 are the diagonal of F0 = [0,1,4,3] — welding them would leave a
    // self-touching polygon.
    uint[2][] pairs = [[4u, 0u]];
    assert(m.weldVertexPairs(pairs) == 0,
        "a non-adjacent same-face pair must be refused");
    assert(m.vertices.length == 6 && m.faces.length == 2,
        "non-adjacent reject: the mesh must be untouched, got V="
        ~ m.vertices.length.to!string ~ " F=" ~ m.faces.length.to!string);
}

unittest { // a pair spanning two DISJOINT faces welds — the adjacency rule is
           // about corners of ONE face and must not leak across the sweep
    import std.conv : to;
    // Two quads that share nothing. The keep sits at corner 0 of the first,
    // the drop at corner 2 of the second: a distance of 2, which is neither
    // adjacent nor the head/tail wrap. If the face sweep's scratch survives
    // from one face into the next, the second face reads the keep's position
    // in the FIRST one, computes that distance, and refuses a pair that shares
    // no face at all. Positions chosen for exactly that reason.
    Mesh m;
    m.addVertex(Vec3(0, 0, 0)); m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 0, 1)); m.addVertex(Vec3(0, 0, 1));
    m.addVertex(Vec3(3, 0, 0)); m.addVertex(Vec3(4, 0, 0));
    m.addVertex(Vec3(4, 0, 1)); m.addVertex(Vec3(3, 0, 1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.rebuildEdges();
    m.buildLoops();

    uint[2][] pairs = [[0u, 6u]];   // keep at corner 0 of face 0, drop at corner 2 of face 1
    assert(m.weldVertexPairs(pairs) == 1,
        "a pair whose two ends live in DIFFERENT faces shares no winding and must weld");
    assert(m.vertices.length == 7,
        "cross-face weld: expected V=7, got " ~ m.vertices.length.to!string);
    assert(m.faces.length == 2,
        "cross-face weld: both quads survive, got F=" ~ m.faces.length.to!string);
    foreach (i, ref f; m.faces)
        assert(f.length == 4,
            "cross-face weld: face " ~ i.to!string ~ " must still be a quad, got length "
            ~ f.length.to!string);
}

unittest { // two faceless vertices cannot weld — that is a vanish, not a weld
    import std.conv : to;
    Mesh m;
    m.addVertex(Vec3(0, 0, 0)); m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 0, 1)); m.addVertex(Vec3(0, 0, 1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.addVertex(Vec3(5, 0, 0));      // 4 — isolated
    m.addVertex(Vec3(5.001f, 0, 0)); // 5 — isolated
    m.rebuildEdges();
    m.buildLoops();

    uint[2][] pairs = [[4u, 5u]];
    assert(m.weldVertexPairs(pairs) == 0,
        "a pair with no incident face anywhere must be refused");
    assert(m.vertices.length == 6,
        "faceless reject: BOTH isolated vertices must survive — honouring the pair would "
        ~ "have run the rebuild, and compactUnreferenced would then have taken them both; "
        ~ "got V=" ~ m.vertices.length.to!string);
}

unittest { // one vertex cannot be absorbed twice; the first pair wins
    import std.conv : to;
    Mesh m = makeWeldPairStrip();
    uint[2][] pairs = [[4u, 1u], [2u, 1u]];
    assert(m.weldVertexPairs(pairs) == 1,
        "a second claim on the same drop must be refused — expected 1 weld");
    assert(m.vertices.length == 5,
        "double-absorb reject: expected V=5, got " ~ m.vertices.length.to!string);
}

// The extracted tail (`applyVertexRemapAndRebuild`) deliberately gets no test
// of its own: it is `weldVerticesByMask`'s own body, unchanged, and the
// collapse/weld tests already in this file are its net. Verified by mutation —
// dropping the post-remap consecutive-duplicate strip, and dropping the
// head/tail wrap strip, each break `collapseFacesByMask` (mesh.d:1477 and
// mesh.d:1500) before any weld test is reached.

unittest { // weldVerticesByMask average flag: survivor at cluster centroid
    import std.math : abs;
    import std.conv : to;
    // Two nearby verts (0.4,-0.5,-0.5) & (0.5,-0.5,-0.5) plus two far corners
    // form a quad; welding the pair (dist 0.2 → epsSq 0.04, gap² 0.01) collapses
    // the quad to a triangle whose surviving corner is the merged vertex.
    Mesh makeQuad() {
        Mesh m;
        m.addVertex(Vec3(0.4f, -0.5f, -0.5f));  // v0  (mask)
        m.addVertex(Vec3(0.5f, -0.5f, -0.5f));  // v1  (mask)
        m.addVertex(Vec3(0.5f,  0.5f, -0.5f));  // v2
        m.addVertex(Vec3(0.4f,  0.5f, -0.5f));  // v3
        m.addFace([0u, 1u, 2u, 3u]);
        m.buildLoops();
        return m;
    }
    bool[] mask = [true, true, false, false];
    double epsSq = 0.2 * 0.2;

    // average:true — survivor lands at the pair's centroid x = 0.45.
    Mesh ma = makeQuad();
    assert(ma.weldVerticesByMask(mask, epsSq, true) == 1,
        "average-weld: expected 1 weld");
    float sx = float.nan;
    foreach (v; ma.vertices)
        if (abs(v.y + 0.5f) < 1e-4f && abs(v.z + 0.5f) < 1e-4f) sx = v.x;
    assert(abs(sx - 0.45f) < 1e-4f,
        "average-weld: survivor x expected 0.45, got " ~ sx.to!string);

    // Default (average omitted) keeps merge-to-first: survivor stays at 0.4.
    Mesh md = makeQuad();
    assert(md.weldVerticesByMask(mask, epsSq) == 1, "first-weld: expected 1 weld");
    float dx = float.nan;
    foreach (v; md.vertices)
        if (abs(v.y + 0.5f) < 1e-4f && abs(v.z + 0.5f) < 1e-4f) dx = v.x;
    assert(abs(dx - 0.4f) < 1e-4f,
        "first-weld: survivor x expected 0.4 (lowest-index), got " ~ dx.to!string);
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

    ulong keyAC = edgeKey(1, 2);

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
    ulong keyC89 = edgeKey(8, 9);
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

// ===========================================================================
// Topology Pen P3 (task 0477) — the three additive kernel-seam witnesses:
// edgeNeighbors (KILLER-1), deleteFacesByMask(keepFloatingEdges) (KILLER-2),
// makePolygonFromVerts(autoOrient). See doc/topopen_p3_plan.md.
// ===========================================================================

unittest { // KILLER-1 RED/GREEN witness: a vertex on a bare (face-less) edge
           // classifies as degree-1 via edgeNeighbors, NOT degree-0 as the
           // loop-fan helpers (vertexValence/edgesAroundVertex) would report.
    Mesh m;
    m.addVertex(Vec3(0,0,0));   // 0 — carries a bare edge, no face at all
    m.addVertex(Vec3(1,0,0));   // 1
    m.addEdge(0, 1);
    m.buildLoops();

    // RED-witness precondition: the loop-fan helper is blind to a bare edge
    // (vertLoop is seeded ONLY from face corners in buildLoops) — this
    // documents the exact blind spot edgeNeighbors exists to fix, so a
    // regression that made vertexValence "just see it too" would be a sign
    // this witness needs re-checking, not silently pass either way.
    assert(m.vertexValence(0) == 0,
        "loop-fan vertexValence must NOT see the bare edge (documents the "
        ~ "blind spot edgeNeighbors below fixes)");

    // GREEN: the raw edges[] scan sees it correctly.
    auto en = m.edgeNeighbors(0);
    assert(en.length == 1, "edgeNeighbors must report exactly 1 neighbor for a bare-edge vertex");
    assert(en[0] == 1, "edgeNeighbors must report vertex 1 as 0's neighbor");
    assert(m.edgeNeighbors(1).length == 1 && m.edgeNeighbors(1)[0] == 0,
        "edgeNeighbors must be symmetric for the same bare edge");
}

unittest { // KILLER-2 witness: deleteFacesByMask(keepOrphans:true,
           // keepFloatingEdges:true) keeps EVERY former edge of the deleted
           // face (now bordering no face) AND an unrelated floating edge
           // elsewhere in the mesh, untouched.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(5,5,5), Vec3(6,5,5)];
    m.addFace([0u, 1u, 2u]);   // the face to delete
    m.addEdge(3, 4);           // an UNRELATED floating edge elsewhere
    m.buildLoops();

    assert(m.edgeIndex(0,1) != ~0u && m.edgeIndex(1,2) != ~0u && m.edgeIndex(0,2) != ~0u);
    assert(m.edgeIndex(3,4) != ~0u);
    assert(m.edges.length == 4);

    bool[] mask = new bool[](m.faces.length);
    mask[0] = true;
    size_t removed = m.deleteFacesByMask(mask, /*keepOrphans*/true, /*keepFloatingEdges*/true);
    assert(removed == 1);
    assert(m.faces.length == 0, "the triangle face must be gone");

    // Every one of the triangle's 3 edges — now bordering NO face — must
    // survive as a floating orphan, exactly like the unrelated edge.
    assert(m.edgeIndex(0,1) != ~0u, "former triangle edge (0,1) must survive");
    assert(m.edgeIndex(1,2) != ~0u, "former triangle edge (1,2) must survive");
    assert(m.edgeIndex(0,2) != ~0u, "former triangle edge (0,2) must survive");
    assert(m.edgeIndex(3,4) != ~0u, "unrelated floating edge must survive untouched");
    assert(m.edges.length == 4, "no edge must be lost mesh-wide (would happen "
        ~ "under the OLD unconditional rebuildEdges())");
    assert(m.vertices.length == 5, "keepOrphans must leave every vertex in place");
}

unittest { // KILLER-2 end-to-end: reproduces the SESSION-3 CASE-QUAD dump
           // bit-for-bit — triangle [0,5,4] (edges (0,4),(0,5),(4,5)) spliced
           // into quad [5,0,4,6], the old (4,5) edge surviving as a
           // non-bounding orphan diagonal.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),   // 0
        Vec3(9,9,9),   // 1 (unused filler, keeps indices matching the capture)
        Vec3(9,9,9),   // 2
        Vec3(9,9,9),   // 3
        Vec3(1,0,0),   // 4
        Vec3(0,1,0),   // 5
        Vec3(1,1,0),   // 6
    ];

    int triFi = m.makePolygonFromVerts([0u, 5u, 4u], false);
    assert(triFi == 0, "seed triangle must build");
    assert(m.faces[triFi] == [0u, 5u, 4u]);
    assert(m.edges.length == 3);
    assert(m.edgeIndex(0,4) != ~0u && m.edgeIndex(0,5) != ~0u && m.edgeIndex(4,5) != ~0u);

    // Delete the triangle, keeping BOTH the orphan verts and every edge —
    // the ONLY way to remove a face without a rebuildEdges (plan's load
    // -bearing rule).
    bool[] mask = new bool[](m.faces.length);
    mask[triFi] = true;
    size_t removed = m.deleteFacesByMask(mask, /*keepOrphans*/true, /*keepFloatingEdges*/true);
    assert(removed == 1);
    assert(m.faces.length == 0);
    assert(m.edges.length == 3, "all 3 former triangle edges must survive as orphans");

    // Splice the quad in the prescribed verbatim construction order —
    // winding is a fixed convention, not adjacency-derived (autoOrient:false).
    int quadFi = m.makePolygonFromVerts([5u, 0u, 4u, 6u], false, /*autoOrient*/false);
    assert(quadFi == 0, "quad must build");
    assert(m.faces[quadFi] == [5u, 0u, 4u, 6u],
        "quad winding must be emitted VERBATIM in construction order");

    // Exact SESSION-3 edge-set match: (0,4),(0,5),(4,5),(4,6),(5,6) — 5 edges,
    // the old (4,5) diagonal now bounding NO face.
    assert(m.edges.length == 5, "expected 5 edges total (3 old + 2 new)");
    assert(m.edgeIndex(0,4) != ~0u);
    assert(m.edgeIndex(0,5) != ~0u);
    assert(m.edgeIndex(4,5) != ~0u, "the old diagonal must survive, unbounded by any face");
    assert(m.edgeIndex(4,6) != ~0u, "new boundary edge (4,6)");
    assert(m.edgeIndex(5,6) != ~0u, "new boundary edge (5,6)");

    auto ef = m.buildEdgeFaces();
    assert((edgeKey(4, 5) in ef) is null,
        "diagonal (4,5) must border zero faces post-splice");
}

unittest { // makePolygonFromVerts(autoOrient:false) — the winding bypass
           // emits the caller's index order VERBATIM (no majority-vote
           // reversal against an existing same-direction neighbor), while
           // every other guard (degenerate, duplicate-face) still runs.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),   // 0
        Vec3(1,0,0),   // 1
        Vec3(1,1,0),   // 2
        Vec3(0,1,0),   // 3
        Vec3(1,0,-1),  // 4
        Vec3(0,0,-1),  // 5
        Vec3(2,0,0),   // 6 — collinear with 0,1 for the degenerate-guard check
    ];

    // fi0 traverses shared edge (0,1) in the 0->1 direction.
    int fi0 = m.makePolygonFromVerts([0u, 1u, 2u, 3u], false);
    assert(fi0 == 0);

    // fi1 ALSO traverses (0,1) in the SAME 0->1 direction — a same-direction
    // share the default autoOrient:true path would flip (task 0394
    // majority-vote). autoOrient:false must NOT flip it.
    int fi1 = m.makePolygonFromVerts([0u, 1u, 4u, 5u], false, /*autoOrient*/false);
    assert(fi1 != -1, "must still build despite the bypass");
    assert(m.faces[fi1] == [0u, 1u, 4u, 5u],
        "autoOrient:false must emit the caller's order verbatim, even where "
        ~ "the default auto-orient would reverse it");

    // Control: the IDENTICAL index order and same-direction share, under the
    // DEFAULT (autoOrient:true) path, DOES get reversed — proves the two
    // modes genuinely differ, not just that the bypass never fires.
    Mesh m2;
    m2.vertices = m.vertices.dup;
    m2.makePolygonFromVerts([0u, 1u, 2u, 3u], false);
    int fi1Default = m2.makePolygonFromVerts([0u, 1u, 4u, 5u], false);
    assert(fi1Default != -1);
    assert(m2.faces[fi1Default] != [0u, 1u, 4u, 5u],
        "control: the default (autoOrient:true) path DOES reverse a "
        ~ "same-direction shared edge — otherwise this witness proves nothing");

    // The bypass must not defeat any other guard.
    assert(m.makePolygonFromVerts([0u, 1u], false, false) == -1,
        "<3 verts must still reject with autoOrient:false");
    assert(m.makePolygonFromVerts([0u, 0u, 0u], false, false) == -1,
        "all-same verts must still reject with autoOrient:false");
    assert(m.makePolygonFromVerts([0u, 1u, 6u], false, false) == -1,
        "collinear must still reject with autoOrient:false");
    assert(m.makePolygonFromVerts([0u, 1u, 2u, 3u], false, false) == -1,
        "duplicate face (same unordered vertex set as fi0) must still reject "
        ~ "with autoOrient:false");
}


// ---------------------------------------------------------------------------
// consumedFanVertexMask / removeEdgesByMask(mask, keepConsumedVerts) — task
// 0494, the recovered "a vertex disappears iff its WHOLE polygon fan was
// consumed" purge rule.
//
// The fixture is `makeGridPlane(3)` — a 4x4 planar grid, 16v/24e/9f, vertex
// index 4*row + col, one quad per cell — which is exactly the rig the
// behaviour was captured on, so the numbers below are comparable to the
// capture row by row.
//
// READ THIS BEFORE TOUCHING THESE TESTS: on a plain quad grid dissolving a
// whole edge loop, the fan rule and this file's OTHER cleanup pass
// (`dissolveDegree2Verts`, a VALENCE rule) predict the identical post-mesh. A
// green loop test therefore proves nothing about which of the two is
// implemented, which is why the fourth block below is a two-armed witness on a
// CONSTRUCTED mask where they disagree — delete that block and the rest of
// this file no longer pins the rule at all.
// ---------------------------------------------------------------------------
unittest { // single interior edge: the purge RUNS and deletes NOTHING
    Mesh m = makeGridPlane(3);
    assert(m.vertices.length == 16 && m.edges.length == 24 && m.faces.length == 9,
        "setup: makeGridPlane(3) must be the 4x4 grid the capture used");

    auto mask = new bool[](m.edges.length);
    mask[m.edgeIndex(5, 9)] = true;

    // Vertices 5 and 9 each carry a fan of FOUR quads of which the dissolve
    // consumes TWO — partial fans, so nothing is purged even with the purge
    // enabled. This is the cheap regression anchor for the rule: a valence
    // test would be equally quiet here, but a "drop every touched endpoint"
    // implementation would wrongly take both.
    foreach (i, c; m.consumedFanVertexMask(mask))
        assert(!c, "a partially consumed fan must never be purged");

    assert(m.removeEdgesByMask(mask, /*keepConsumedVerts*/false) == 1);
    assert(m.vertices.length == 16 && m.edges.length == 23 && m.faces.length == 8,
        "an interior edge dissolve merges its two quads into one hexagon and "
        ~ "loses nothing else");
    assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
}

unittest { // an edge LOOP, both ways round the keep-vertex flag
    // The vertical 3-edge run through the middle column of the grid.
    static bool[] loopMask(ref Mesh m) {
        auto mask = new bool[](m.edges.length);
        mask[m.edgeIndex(1, 5)]  = true;
        mask[m.edgeIndex(5, 9)]  = true;
        mask[m.edgeIndex(9, 13)] = true;
        return mask;
    }

    // KEEP the consumed vertices: the merged hexagons carry them as corners.
    {
        Mesh m = makeGridPlane(3);
        assert(m.removeEdgesByMask(loopMask(m)) == 3);
        assert(m.vertices.length == 16 && m.edges.length == 21 && m.faces.length == 6);
        assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
    }

    // DROP them (the reference default): each hexagon collapses back to a
    // quad, and the four re-stitching edges appear.
    {
        Mesh m = makeGridPlane(3);
        auto pre  = m.vertices.dup;
        auto mask = loopMask(m);

        auto consumed = m.consumedFanVertexMask(mask);
        uint[] taken;
        foreach (i, c; consumed) if (c) taken ~= cast(uint)i;
        assert(taken == [1u, 5u, 9u, 13u],
            "exactly the loop's own endpoints, whose fans the dissolve eats whole "
            ~ "— NOT vertex 4, whose fan is also eaten but which is nobody's "
            ~ "dissolving endpoint");

        assert(m.removeEdgesByMask(mask, /*keepConsumedVerts*/false) == 3);
        assert(m.vertices.length == 12 && m.edges.length == 17 && m.faces.length == 6,
            "dropping the four consumed vertices re-stitches the survivors");
        assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");

        // Positions, not indices: the dissolve reindexes.
        int idxOf(Vec3 p) {
            foreach (i, ref v; m.vertices)
                if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
            return -1;
        }
        foreach (gone; [1, 5, 9, 13])
            assert(idxOf(pre[gone]) < 0, "a consumed vertex must be gone");
        foreach (pair; [[0, 2], [4, 6], [8, 10], [12, 14]]) {
            immutable int a = idxOf(pre[pair[0]]), b = idxOf(pre[pair[1]]);
            assert(a >= 0 && b >= 0 && m.edgeIndex(cast(uint)a, cast(uint)b) != ~0u,
                "the survivors must be re-stitched across the gap");
        }
    }
}

unittest { // a BORDER edge in the mask neither dissolves nor nominates anything
    Mesh m = makeGridPlane(3);
    auto mask = new bool[](m.edges.length);
    mask[m.edgeIndex(0, 1)] = true;   // top-left border edge, ONE incident quad

    foreach (c; m.consumedFanVertexMask(mask))
        assert(!c, "a one-polygon edge cannot consume a fan");
    assert(m.removeEdgesByMask(mask, /*keepConsumedVerts*/false) == 0);
    assert(m.vertices.length == 16 && m.edges.length == 24 && m.faces.length == 9,
        "border seed must be a total no-op");
}

unittest { // THE KERNEL TRAP, both arms — "whole fan consumed" is NOT "2-valent"
    // Two dissolving edges meeting at interior vertex 5, whose fourth quad
    // [5,6,10,9] is NOT consumed. The fan rule spares 5; the valence rule
    // takes it (after the dissolve 5 has exactly two edges left) and mangles
    // that surviving quad into a triangle.
    static bool[] trapMask(ref Mesh m) {
        auto mask = new bool[](m.edges.length);
        mask[m.edgeIndex(1, 5)] = true;
        mask[m.edgeIndex(4, 5)] = true;
        return mask;
    }
    static int idxOf(ref Mesh m, Vec3 p) {
        foreach (i, ref v; m.vertices)
            if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
        return -1;
    }

    // Arm 1 — the implemented rule.
    {
        Mesh m = makeGridPlane(3);
        auto pre = m.vertices.dup;

        uint[] taken;
        foreach (i, c; m.consumedFanVertexMask(trapMask(m))) if (c) taken ~= cast(uint)i;
        assert(taken == [1u, 4u],
            "only the endpoints whose fan is eaten WHOLE — vertex 5 keeps one quad");

        assert(m.removeEdgesByMask(trapMask(m), /*keepConsumedVerts*/false) == 2);
        assert(m.vertices.length == 14 && m.edges.length == 20 && m.faces.length == 7);
        assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
        assert(idxOf(m, pre[5]) >= 0, "vertex 5 must SURVIVE — its fan was not eaten");
        assert(idxOf(m, pre[1]) < 0 && idxOf(m, pre[4]) < 0);
        foreach (ref f; m.faces)
            assert(f.length >= 4, "no surviving quad may be reduced to a triangle");
    }

    // Arm 2 — the valence rule on the SAME input, to prove the two genuinely
    // disagree here rather than that the first arm merely passed.
    {
        Mesh m = makeGridPlane(3);
        auto pre = m.vertices.dup;
        assert(m.removeEdgesByMask(trapMask(m)) == 2);
        m.dissolveDegree2Verts(m.edgeDeleteRegion(), /*keepOrphans*/true);
        assert(m.vertices.length == 13 && m.edges.length == 19 && m.faces.length == 7,
            "control: the valence rule takes one vertex more");
        assert(idxOf(m, pre[5]) < 0, "control: the valence rule DELETES vertex 5");
        bool anyTri = false;
        foreach (ref f; m.faces) if (f.length == 3) anyTri = true;
        assert(anyTri, "control: and mangles the unconsumed quad into a triangle");
    }
}

unittest { // a WHOLE fan in the mask: the shared vertex goes, its neighbours
           // go, the untouched ring stays — and here the two rules COINCIDE,
           // recorded so nobody reads this block as a second discriminator.
    Mesh m = makeGridPlane(3);
    auto pre = m.vertices.dup;
    auto mask = new bool[](m.edges.length);
    foreach (pair; [[1, 5], [4, 5], [5, 6], [5, 9]])
        mask[m.edgeIndex(cast(uint)pair[0], cast(uint)pair[1])] = true;

    uint[] taken;
    foreach (i, c; m.consumedFanVertexMask(mask)) if (c) taken ~= cast(uint)i;
    assert(taken == [1u, 4u, 5u],
        "5 (whole fan), plus 1 and 4 whose two-quad fans are also eaten whole; "
        ~ "6 and 9 keep an outer quad each");

    assert(m.removeEdgesByMask(mask, /*keepConsumedVerts*/false) == 4);
    assert(m.vertices.length == 13 && m.edges.length == 18 && m.faces.length == 6);
    assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
    int idxOf(Vec3 p) {
        foreach (i, ref v; m.vertices)
            if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
        return -1;
    }
    assert(idxOf(pre[5]) < 0 && idxOf(pre[1]) < 0 && idxOf(pre[4]) < 0);
}


// ---------------------------------------------------------------------------
// Task 0502 — LOOSE (face-less) GEOMETRY SURVIVES A DISSOLVE.
//
// Every dissolve tail is `rebuildEdges()` + `compactUnreferenced()`, and both
// re-derive from `faces[]` MESH-WIDE. Before this task one edge dissolve
// therefore took every bare wire edge and every loose point in the mesh with
// it, arbitrarily far from the edit — silent destruction of ordinary
// intermediate retopo state (a placed point; a chain drawn before any polygon
// closes over it).
//
// Every fixture below puts the loose geometry AT A DISTANCE — coordinates 10
// and 20 against a unit grid — and never lets it touch the edited region, so a
// green result cannot come from the edit happening to spare a neighbour. The
// shared helpers address it by POSITION, because a fix that preserves the
// geometry is still free to renumber it.
// ---------------------------------------------------------------------------
version (unittest) private int looseTestVertAt(in Mesh m, Vec3 p) {
    foreach (i, ref v; m.vertices)
        if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
    return -1;
}

version (unittest) private bool looseTestHasWire(in Mesh m, Vec3 a, Vec3 b) {
    immutable int ia = looseTestVertAt(m, a), ib = looseTestVertAt(m, b);
    if (ia < 0 || ib < 0) return false;
    // Scanned straight off `edges[]` — never through `edgeIndexMap`, so the
    // assertion cannot pass on a stale lookup table alone.
    foreach (ref e; m.edges)
        if ((e[0] == ia && e[1] == ib) || (e[0] == ib && e[1] == ia)) return true;
    return false;
}

private enum Vec3 kLoosePoint = Vec3(10, 10, 10);
private enum Vec3 kLooseWireA = Vec3(20, 0, 0);
private enum Vec3 kLooseWireB = Vec3(21, 0, 0);

/// `makeGridPlane(n)` plus, FAR from it, one loose point and one bare wire
/// edge — neither referenced by any polygon.
version (unittest) private Mesh makeGridWithLooseGeometry(int n) {
    Mesh m = makeGridPlane(n);
    m.addVertex(kLoosePoint);
    immutable uint w0 = m.addVertex(kLooseWireA);
    immutable uint w1 = m.addVertex(kLooseWireB);
    m.addEdge(w0, w1);
    m.buildLoops();
    m.syncSelection();
    // The fixture must actually contain what the tests are about.
    assert(looseTestVertAt(m, kLoosePoint) >= 0, "fixture: the loose point");
    assert(looseTestHasWire(m, kLooseWireA, kLooseWireB), "fixture: the bare wire edge");
    return m;
}

unittest { // removeEdgesByMask: one interior dissolve, loose geometry untouched
    Mesh m = makeGridWithLooseGeometry(2);   // 3x3 verts / 4 quads + 3 loose verts
    immutable size_t vBefore = m.vertices.length;

    auto mask = new bool[](m.edges.length);
    mask[m.edgeIndex(1, 4)] = true;          // an INTERIOR grid edge, nowhere near
    assert(m.removeEdgesByMask(mask) == 1, "setup: the interior edge must dissolve");

    assert(m.faces.length == 3, "the two quads either side merged into one");
    assert(looseTestVertAt(m, kLoosePoint) >= 0,
        "FAILS ON THE OLD BEHAVIOUR: the tail compactUnreferenced dropped every "
      ~ "face-less vertex in the mesh, including this one 10 units away");
    assert(looseTestHasWire(m, kLooseWireA, kLooseWireB),
        "FAILS ON THE OLD BEHAVIOUR: the tail rebuildEdges re-derived edges[] from "
      ~ "faces[] alone, so a bare wire edge anywhere in the mesh vanished");
    assert(m.vertices.length == vBefore,
        "the dissolve consumed no vertex, so none may go — not the grid's, not the loose ones");
}

unittest { // …and the same through the EDGE-REMOVE COMMAND's exact kernel pair
    // `MeshRemove`/`MeshDelete` in Edges mode run removeEdgesByMask and then
    // dissolveDegree2Verts over the touched region (commands/mesh/{remove,delete}.d).
    // The second call is its own dissolve with its own mesh-wide tail, so the
    // pair has to be pinned together — fixing only the first one leaves the
    // shipped commands still wiping the wire.
    Mesh m = makeGridWithLooseGeometry(2);

    auto mask = new bool[](m.edges.length);
    mask[m.edgeIndex(1, 4)] = true;
    immutable size_t n = m.removeEdgesByMask(mask);
    assert(n == 1, "setup");
    m.dissolveDegree2Verts(m.edgeDeleteRegion(), /*keepOrphans*/true);

    assert(looseTestVertAt(m, kLoosePoint) >= 0,
        "the loose point must survive the command's SECOND dissolve too");
    assert(looseTestHasWire(m, kLooseWireA, kLooseWireB),
        "FAILS ON THE OLD BEHAVIOUR at dissolveVerticesByMask's own rebuildEdges: "
      ~ "the wire survives the edge dissolve only to be wiped by the 2-valent cleanup");
}

unittest { // dissolveVerticesByMask, BOTH keepOrphans arms
    foreach (keepOrphans; [false, true]) {
        Mesh m = makeGridWithLooseGeometry(2);
        auto vmask = new bool[](m.vertices.length);
        vmask[4] = true;                     // the grid's centre vertex
        assert(m.dissolveVerticesByMask(vmask, keepOrphans) == 1, "setup");

        assert(m.faces.length == 4, "the four quads reshaped to triangles");
        assert(looseTestVertAt(m, kLoosePoint) >= 0,
            "a pre-existing loose point is not this call's collateral, at either keepOrphans");
        assert(looseTestHasWire(m, kLooseWireA, kLooseWireB),
            "FAILS ON THE OLD BEHAVIOUR (both arms): keepOrphans only ever protected "
          ~ "floating VERTICES; the rebuildEdges above it wiped floating EDGES regardless");
    }
}

unittest { // keepOrphans:false still sweeps the orphans THIS call created
    // The preservation is scoped to what was face-less BEFORE the call — it is
    // not a blanket "never compact". Without this pin, a fix that simply
    // pinned every vertex would pass every block above.
    Mesh m;
    foreach (p; [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)]) m.addVertex(p);
    m.addFace([0u, 1u, 2u]);
    m.addVertex(kLoosePoint);
    m.buildLoops();
    m.syncSelection();

    auto vmask = new bool[](m.vertices.length);
    vmask[0] = true;                         // the triangle degenerates away
    assert(m.dissolveVerticesByMask(vmask, /*keepOrphans*/false) == 1);
    assert(m.faces.length == 0, "setup: the only face dropped below 3 corners");
    assert(looseTestVertAt(m, Vec3(1, 0, 0)) < 0 && looseTestVertAt(m, Vec3(0, 1, 0)) < 0,
        "verts THIS call orphaned still go — that is what keepOrphans:false means");
    assert(looseTestVertAt(m, kLoosePoint) >= 0,
        "…but the point that was already loose before the call is not its collateral");
}

unittest { // a wire the edit ITSELF consumed stays gone — no resurrection
    // A wire hanging off the grid's centre vertex, which the dissolve then
    // removes. Preservation restores UNRELATED geometry; it must not put back
    // an edge whose endpoint the caller deliberately deleted.
    Mesh m = makeGridPlane(2);
    immutable uint tip = m.addVertex(Vec3(0, 5, 0));
    m.addEdge(4, tip);                        // wire off the centre vertex
    m.buildLoops();
    m.syncSelection();
    assert(looseTestHasWire(m, m.vertices[4], Vec3(0, 5, 0)), "fixture");
    immutable Vec3 centre = m.vertices[4];

    auto vmask = new bool[](m.vertices.length);
    vmask[4] = true;
    assert(m.dissolveVerticesByMask(vmask, /*keepOrphans*/true) == 1);

    assert(looseTestVertAt(m, centre) < 0, "the masked vertex is gone");
    assert(looseTestVertAt(m, Vec3(0, 5, 0)) >= 0,
        "its far tip was already face-less, so it stays as a loose point");
    assert(!looseTestHasWire(m, centre, Vec3(0, 5, 0)),
        "but the wire itself cannot come back — one of its endpoints was deleted");
}

// ---------------------------------------------------------------------------
// Task 0502 — `edgePolygonCounts` sees a NON-MANIFOLD fan; `facesAroundEdge`
// cannot. Three quads share edge 0-1 here. The ring walk reports ONE face —
// not three, and not even two — because the half-edge rings have no
// representation for the fan; the direct face scan reports 3.
//
// This is the fixture that separates a real count from an undercount, and it
// is why every "how many polygons border this edge" test in the repo must run
// on it rather than on a grid (where the two agree).
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(1,1,0),
                 Vec3(0,0,1), Vec3(1,0,1), Vec3(0,-1,0), Vec3(1,-1,0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 3u, 2u]);
    m.addFace([0u, 1u, 5u, 4u]);
    m.addFace([0u, 1u, 7u, 6u]);
    m.buildLoops();

    immutable uint shared_ = m.edgeIndex(0, 1);
    auto counts = m.edgePolygonCounts();
    assert(counts[shared_] == 3, "three quads border this edge, and the count says so");

    uint viaRings = 0;
    foreach (_; m.facesAroundEdge(shared_)) ++viaRings;
    assert(viaRings < 3,
        "the documented blind spot: if the rings ever learn to enumerate a "
      ~ "non-manifold fan, delete this line — but do NOT weaken edgePolygonCounts to match");

    // The other two answers the counter has to get right on the same mesh.
    assert(counts[m.edgeIndex(1, 3)] == 1, "a border edge of one quad");
    m.addVertex(Vec3(9, 9, 9));
    m.addVertex(Vec3(9, 9, 8));
    m.addEdge(8, 9);
    assert(m.edgePolygonCounts()[m.edgeIndex(8, 9)] == 0, "a bare wire edge borders nothing");
}

// ---------------------------------------------------------------------------
// select.loop seed scans: cost and equivalence
// ---------------------------------------------------------------------------
// The recovered face/vertex walks consume seeds one group at a time. Every
// pass used to re-scan the whole selected list from the head, so the pass
// sequence cost O(passes x selected) — quadratic, and the pass count EQUALS
// the selected count on the two shapes an importer and the array tools
// actually produce: a triangulated mesh in polygon mode (selectBandTrace skips
// odd-sided neighbours, so a triangle never advances and is always a group of
// one) and many small components in vertex mode. Command.apply() runs on the
// main thread, so that is a frozen UI.
//
// The scans are now forward-only. The tests below hold that down from both
// sides: the cost is asserted in SEED-SCAN STEPS (deterministic — a wall-clock
// threshold would flake on a loaded machine), and the ANSWER is asserted
// against a frozen head-restart oracle over a corpus, because a cursor that
// skipped one element too many would be a silent selection bug.
// ---------------------------------------------------------------------------

version (unittest) private {
    // Deterministic xorshift — std.random's global generator is shared state.
    struct SlRng {
        uint s = 0x2545F491;
        uint next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
        uint upto(uint n) { return n ? next() % n : 0; }
    }

    /// n x n quad grid; `tri` splits every cell into two triangles.
    Mesh slGrid(int n, bool tri) {
        Mesh m;
        foreach (r; 0 .. n + 1)
            foreach (c; 0 .. n + 1) m.addVertex(Vec3(c, 0, r));
        uint vid(int r, int c) { return cast(uint)(r * (n + 1) + c); }
        foreach (r; 0 .. n)
            foreach (c; 0 .. n) {
                if (tri) {
                    m.addFace([vid(r,c),   vid(r,c+1),   vid(r+1,c+1)]);
                    m.addFace([vid(r,c),   vid(r+1,c+1), vid(r+1,c)]);
                } else {
                    m.addFace([vid(r,c), vid(r,c+1), vid(r+1,c+1), vid(r+1,c)]);
                }
            }
        m.buildLoops();
        return m;
    }

    /// `k` components that share no vertex — `sides`-gons side by side.
    Mesh slDisjoint(int k, int sides) {
        Mesh m;
        foreach (i; 0 .. k) {
            uint base = cast(uint)m.vertices.length;
            uint[] f;
            foreach (o; 0 .. sides) {
                import std.math : cos, sin, PI;
                const a = 2 * PI * o / sides;
                m.addVertex(Vec3(i * 4 + cos(a), 0, sin(a)));
                f ~= base + cast(uint)o;
            }
            m.addFace(f);
        }
        m.buildLoops();
        return m;
    }

    /// Quad grid where a random third of the cells is split into two triangles
    /// — mixed parity, so partner pairing and the odd-sided skip both fire.
    Mesh slMixedGrid(int n, ref SlRng rng) {
        Mesh m;
        foreach (r; 0 .. n + 1)
            foreach (c; 0 .. n + 1) m.addVertex(Vec3(c, 0, r));
        uint vid(int r, int c) { return cast(uint)(r * (n + 1) + c); }
        foreach (r; 0 .. n)
            foreach (c; 0 .. n) {
                if (rng.upto(3) == 0) {
                    m.addFace([vid(r,c),   vid(r,c+1),   vid(r+1,c+1)]);
                    m.addFace([vid(r,c),   vid(r+1,c+1), vid(r+1,c)]);
                } else {
                    m.addFace([vid(r,c), vid(r,c+1), vid(r+1,c+1), vid(r+1,c)]);
                }
            }
        m.buildLoops();
        return m;
    }

    /// `k` quads all hinged on the SAME edge — a non-manifold fan, so
    /// edgeFaces[e] holds more than two faces.
    Mesh slNonManifoldFan(int k) {
        Mesh m;
        m.addVertex(Vec3(0, 0, 0));
        m.addVertex(Vec3(1, 0, 0));
        foreach (i; 0 .. k) {
            uint base = cast(uint)m.vertices.length;
            m.addVertex(Vec3(1, i + 1, 0));
            m.addVertex(Vec3(0, i + 1, 0));
            m.addFace([0u, 1u, base, base + 1]);
        }
        m.buildLoops();
        return m;
    }

    /// Random face soup over a sliding vertex window: shared edges, bowties,
    /// duplicate faces, 3..6 sides, and the occasional isolated island.
    Mesh slSoup(int nv, int nf, ref SlRng rng) {
        Mesh m;
        foreach (i; 0 .. nv)
            m.addVertex(Vec3(rng.upto(20), rng.upto(20), rng.upto(20)));
        foreach (_; 0 .. nf) {
            const sides = 3 + rng.upto(4);
            const win   = rng.upto(cast(uint)nv);
            uint[] f;
            foreach (__; 0 .. sides) {
                uint v = (win + rng.upto(8)) % nv;
                bool dup = false;
                foreach (x; f) if (x == v) { dup = true; break; }
                if (!dup) f ~= v;
            }
            if (f.length >= 3) m.addFace(f);
        }
        m.buildLoops();
        return m;
    }

    /// Select `frac`/16 of the elements in a scrambled order, so the
    /// selection-history order the scans sort by is NOT the index order.
    void slSelectFaces(ref Mesh m, ref SlRng rng, uint frac) {
        m.resizeFaceSelection();
        m.faceSelectionOrder.length = m.faces.length;
        uint[] idx;
        foreach (i; 0 .. m.faces.length) idx ~= cast(uint)i;
        foreach_reverse (i; 1 .. idx.length) {
            const j = rng.upto(cast(uint)i + 1);
            const t = idx[i]; idx[i] = idx[j]; idx[j] = t;
        }
        foreach (i; idx) if (rng.upto(16) < frac) m.selectFace(cast(int)i);
    }

    void slSelectVerts(ref Mesh m, ref SlRng rng, uint frac) {
        m.resizeVertexSelection();
        uint[] idx;
        foreach (i; 0 .. m.vertices.length) idx ~= cast(uint)i;
        foreach_reverse (i; 1 .. idx.length) {
            const j = rng.upto(cast(uint)i + 1);
            const t = idx[i]; idx[i] = idx[j]; idx[j] = t;
        }
        foreach (i; idx) if (rng.upto(16) < frac) m.selectVertex(cast(int)i);
    }

    string slDiff(const bool[] got, const bool[] want) {
        import std.format : format;
        foreach (i; 0 .. want.length) {
            if (i >= got.length) return format("truncated at %d", i);
            if (got[i] != want[i])
                return format("first divergence at element %d: fast=%s oracle=%s",
                              i, got[i], want[i]);
        }
        return got.length != want.length ? "length mismatch" : "identical";
    }
}

unittest { // the forward-only seed scans answer EXACTLY what head-restart did
    SlRng rng;
    size_t cases = 0;

    void check(string shape, ref Mesh m, uint frac) {
        import std.format : format;
        slSelectFaces(m, rng, frac);
        auto gotF  = m.selectLoopFaces();
        auto wantF = m.selectLoopFacesHeadRestart();
        assert(gotF == wantF,
            format("%s (frac %d/16), polygon mode: %s", shape, frac, slDiff(gotF, wantF)));

        slSelectVerts(m, rng, frac);
        auto gotV  = m.selectLoopVertices();
        auto wantV = m.selectLoopVerticesHeadRestart();
        assert(gotV == wantV,
            format("%s (frac %d/16), vertex mode: %s", shape, frac, slDiff(gotV, wantV)));
        ++cases;
    }

    foreach (frac; [16u, 12u, 8u, 4u, 2u]) {
        auto a = slGrid(6, false);       check("quad grid 6",        a, frac);
        auto b = slGrid(6, true);        check("tri grid 6",         b, frac);
        auto c = slDisjoint(9, 4);       check("9 disjoint quads",   c, frac);
        auto d = slDisjoint(9, 3);       check("9 disjoint tris",    d, frac);
        auto e = slDisjoint(6, 6);       check("6 disjoint hexes",   e, frac);
        auto f = slMixedGrid(6, rng);    check("mixed-parity grid",  f, frac);
        auto g = slNonManifoldFan(5);    check("non-manifold fan",   g, frac);
        foreach (s; 0 .. 12) {
            auto h = slSoup(24, 20, rng);
            check("random soup", h, frac);
        }
    }
    assert(cases == 5 * 19, "the corpus ran end to end");
}

unittest { // …and they cost O(selected), not O(selected^2)
    import std.format : format;

    // Both shapes below are measured at two sizes, the second with FOUR TIMES
    // the selected elements of the first. A linear scan grows ~4x; a scan that
    // restarts at the head grows ~16x. The gate is 6x — comfortably above the
    // real ratio and far below the quadratic one, so it does not depend on the
    // per-element constant and cannot flake (the counter is deterministic; a
    // wall-clock threshold would not be).
    enum RATIO_GATE = 6;

    // Polygon mode on a triangulated grid: selectBandTrace skips odd-sided
    // neighbours, so a triangle never advances and every one of them is a
    // group of its own — head-restart walked the whole selection once PER
    // SELECTED FACE, twice (NEXT_GROUP and the partner scan).
    size_t polySteps(int n) {
        auto m = slGrid(n, true);
        m.resizeFaceSelection();
        m.faceSelectionOrder.length = m.faces.length;
        foreach (i; 0 .. m.faces.length) m.selectFace(cast(int)i);
        Mesh.gSelectLoopSeedScanSteps = 0;
        m.selectLoopFaces();
        return Mesh.gSelectLoopSeedScanSteps;
    }
    const p1 = polySteps(20);   //   800 triangles
    const p2 = polySteps(40);   //  3200 triangles
    assert(p2 <= RATIO_GATE * p1,
        format("polygon seed scan is superlinear: 4x the selected polygons cost "
             ~ "%.1fx the seed-scan steps (%d -> %d). Head-restart scored ~16x. "
             ~ "Something reintroduced a scan that does not start where the last "
             ~ "one stopped.", cast(double)p2 / p1, p1, p2));

    // Vertex mode with many small components: one pass per component, and each
    // pass used to re-walk every vertex ahead of it. Note the dead-end pairs a
    // consumed edge leaves behind are NOT marked, so the leading-run cursor
    // alone does not save this shape — the burn memo does.
    size_t vertSteps(int k) {
        auto m = slDisjoint(k, 4);
        m.resizeVertexSelection();
        foreach (i; 0 .. m.vertices.length) m.selectVertex(cast(int)i);
        Mesh.gSelectLoopSeedScanSteps = 0;
        m.selectLoopVertices();
        return Mesh.gSelectLoopSeedScanSteps;
    }
    const v1 = vertSteps(250);   // 1000 vertices
    const v2 = vertSteps(1000);  // 4000 vertices
    assert(v2 <= RATIO_GATE * v1,
        format("vertex seed scan is superlinear: 4x the selected vertices cost "
             ~ "%.1fx the seed-scan steps (%d -> %d). Head-restart scored ~16x.",
               cast(double)v2 / v1, v1, v2));

    // A per-element ceiling as well, so a linear-but-absurd scan is caught too.
    // Measured: ~8 steps/polygon (cursor + A's edges x their face degree) and
    // ~3 steps/vertex.
    assert(p2 <= 24 * 3200, format("polygon seed scan: %d steps for 3200 polygons", p2));
    assert(v2 <= 24 * 4000, format("vertex seed scan: %d steps for 4000 vertices", v2));
}
