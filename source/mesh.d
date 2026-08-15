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
import mesh_ops.edge_bevel : MeshEdgeBevelOps;
import mesh_ops.bevel_fin : MeshBevelFinOps;
import mesh_ops.bevel_vertex : MeshBevelVertexOps;
import mesh_ops.extrude : MeshExtrudeOps;
import mesh_ops.connected_mask : MeshConnectedMaskOps;
import mesh_ops.select_loop : MeshSelectLoopOps;
import mesh_ops.poly_bevel : MeshPolyBevelOps;

// Half-edge dart type + the topology ranges → extracted to source/mesh_topo.d
// (task 0717). Re-exported so every `import mesh : Loop;` / `mesh.EdgeFaceRange`
// call site resolves unchanged.
public import mesh_topo;

// The per-CORNER map vocabulary — `PolyVertexBlend` / `PolyVertexGen` /
// `UvWallLaw`, and since task 0830 the obligation type `CornerProvenance` +
// its reason enum `CornerDrop` → extracted to source/mesh_corner_maps.d.
// Re-exported for the same reason `mesh_topo` is: every existing
// `import mesh : PolyVertexBlend;` / `import mesh : UvWallLaw;` resolves
// unchanged. The Mesh-COUPLED half of the obligation (`CornerRewrite`, which
// captures the old corner space and arms the drop) stays here — it holds a
// `Mesh*`, so it cannot live in a module Mesh imports.
public import mesh_corner_maps;
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

/// A face index that is known to have been read out of a LIVE `faces` array —
/// task 0831, the type that replaces the rule task 0703 could only write in a
/// comment.
///
/// WHAT WENT WRONG WITHOUT IT. Every recorded index in a `MeshOpEntry` is in
/// the space of the mesh immediately before that entry runs forward (see "THE
/// INDEX SPACE OF AN ENTRY" in `mesh_edit_delta.d`). Two kernels recorded the
/// position a dropped face would have held in the array being BUILT instead —
/// `keptFaces.length` / `newFaces.length` rather than the live `fi`. Both
/// expressions are a `uint`, both compiled, and the two spaces read IDENTICALLY
/// whenever exactly one face is dropped, so every test in the suite was green
/// while an edge dissolve returned its faces reversed on undo.
///
/// WHAT THE TYPE ACTUALLY BUYS, stated narrowly so it is not mistaken for more.
/// There is NO implicit `uint` → `FaceIdx`, so a scratch array's `.length` (or
/// any other computed integer) cannot be appended to a `FaceIdx[]` — that is a
/// compile error, and it is exactly the shape of the 0703 defect. The only
/// unremarkable way to obtain one is `Mesh.faceIndices` / `Mesh.faceAppendBase`,
/// both of which read the live array. Anything else has to say
/// `assumeFaceSpace`, which is greppable and reads as the assertion it is.
///
/// WHAT IT DOES NOT BUY. The tag says "minted from a live `faces`", NOT "minted
/// from the RIGHT live `faces`": iterating the array again AFTER the kernel's
/// own rewrite yields indices this type cannot tell from the pre-rewrite ones.
/// That residue is a lifetime question, not a mint question, and no newtype
/// closes it — see the task-0831 census note in `doc/tasks/`.
///
/// Reads are deliberately free. `alias raw this` forwards to `uint`, so
/// `faces[fi]`, `fi < faces.length`, `insertInPlace(fi, …)` and every existing
/// `uint`/`size_t` parameter keep working with no `.raw` at the call site — the
/// same one-way-conversion trick `FaceList` above uses, for the same reason.
struct FaceIdx {
    private uint _v;
    uint raw() const { return _v; }
    alias raw this;

    /// No default: a `FaceIdx` that nobody minted would be face 0, and face 0
    /// is a real face. (Costs `FaceIdx[].length = n`, which nothing needs.)
    @disable this();
    private this(uint v) { _v = v; }

    /// The named escape, for the one caller that genuinely has a raw index and
    /// can justify the space it is in — a test fixture hand-building a delta,
    /// or a decoder reading indices off disk. Deliberately verbose: an
    /// `assumeFaceSpace` in a kernel is a review question, not a conversion.
    static FaceIdx assumeFaceSpace(size_t v) { return FaceIdx(cast(uint)v); }
}

/// The live face-index space of a mesh, as a range — the ordinary mint for
/// `FaceIdx`. `foreach (fi; m.faceIndices)` replaces `foreach (fi; 0 .. n)` /
/// `foreach (fi, ref f; faces)` in the kernels that record a delta, and is what
/// makes the recorded index un-fakeable from a scratch array's length.
struct FaceIdxRange {
    private uint i, n;
    bool empty() const { return i >= n; }
    FaceIdx front() const { return FaceIdx(i); }
    void popFront() { ++i; }
    size_t length() const { return n - i; }
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
    //
    // Deliberately NOT carried by the `.v3d` codec — see `kSurfaceFields` in
    // io/native.d for why, and its paired unittest for the reproduction
    // (task 0762). Nothing in the tree writes this field today.
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

    /// The live face-index space (task 0831). Every kernel that records a
    /// `RemoveFaces` / `ReshapeFaces` entry iterates THIS instead of
    /// `0 .. faces.length`, so the index it records is one the type can vouch
    /// came off the live array — `FaceIdx`'s doc comment has the full argument.
    FaceIdxRange faceIndices() const { return FaceIdxRange(0, cast(uint)faces.length); }

    /// The index the NEXT appended face will hold — the mint for an `AddFaces`
    /// entry's `[F0,F1)` tail range, which is the one recorded index that is
    /// deliberately NOT a live face yet. Read it BEFORE the append.
    FaceIdx faceAppendBase() const { return FaceIdx.assumeFaceSpace(faces.length); }

    Loop[]     loops;        // all half-edge loops
    uint[]     faceLoop;     // faceLoop[fi] = index of first loop of face fi
    uint[]     vertLoop;     // vertLoop[vi] = loop starting at vi (anchored to fan start for boundary verts)
    uint[]     loopEdge;     // loopEdge[li] = index in edges[] of the undirected edge for loop li
    uint[ulong] edgeIndexMap; // edgeKey(a,b) → index in edges[]; populated by buildLoops + addEdge

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

    /// One face-local vertex substitution: wherever `oldV` appears in a face's
    /// vertex list, it is replaced IN PLACE by the whole `newVs` run (one
    /// vertex for a plain slide, two when a corner splits into a predecessor
    /// and a successor). Accumulated per face id as `VertSub[][uint]` by every
    /// operator that rims a face without re-deriving its winding.
    static struct VertSub { uint oldV; uint[] newVs; }

    /// Apply the substitutions recorded for ONE face. `subsP` is the raw
    /// `fi in faceSubs` lookup, so the untouched-face case (null) stays a
    /// single `.dup` with no map built.
    ///
    /// Singular, not the `rebuildFacesWithVertexSubs` the audit named: the
    /// three call sites this replaced (edge bevel's L0 boundary resolve,
    /// vertex bevel's rebuild pass, extrude's rebuild pass) share the inner
    /// substitution exactly, but each wraps it in its OWN loop with its own
    /// bound and its own per-face attribute carry. Hoisting the loop too
    /// would have had to invent a policy for the attrs; hoisting the
    /// substitution alone is the part that was byte-identical.
    ///
    /// Order-sensitive detail worth keeping visible: a repeated `oldV` in
    /// `subs` means LAST wins (AA assignment), and an `oldV` appearing twice
    /// in the face is substituted at BOTH positions. Both were true of all
    /// three copies.
    private static uint[] rebuildFaceWithVertexSubs(const(uint)[] face, VertSub[]* subsP) {
        if (subsP is null) return face.dup;
        uint[][uint] repl;
        foreach (s; *subsP) repl[s.oldV] = s.newVs;
        uint[] rebuilt;
        foreach (v; face) {
            auto rp = v in repl;
            if (rp is null) rebuilt ~= v;
            else            rebuilt ~= *rp;
        }
        return rebuilt;
    }

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
    //   (c) arity-changing rewrite that also INSERTS vertices — build the same
    //       `oldLoopOfNewLoop` PLUS a `PolyVertexBlend` per inserted vertex, and
    //       call `carryPolyVertexMaps` (which runs the funnel and then a second,
    //       interpolating pass). Wired in `insertEdgeLoopsMulti` (Loop Slice,
    //       task 0682), `addEdgePoint` (the `mesh.addPoint` command — one
    //       corner spliced into each incident winding, blended by the same
    //       edge-split law) and `spikeFacesByMask` (task 0690; no blends — the
    //       rim corners copy, the apex is left at the honest zero). The law is
    //       frozen in tests/fixtures/uv_corner_transfer.json.
    //       (c') PER-CORNER source — `carryPolyVertexMapsByCorner` (task 0697).
    //       The same mechanism with the source old face given per NEW CORNER
    //       instead of per new face, because a chamfer strip's two sides come
    //       from the two faces the beveled edge separated: one source per face
    //       would put one side in the wrong island. The per-face entry above is
    //       now a wrapper that expands its array and delegates, so Loop Slice
    //       cannot drift from it. Wired in `bevelEdgesByMask`,
    //       `bevelFacesByMask` and `extrudeFacesByMask`.
    //   (e) GENERATED corner values — `PolyVertexGen`, applied by the same call
    //       (task 0697). Two measured laws are not a weighted sum of any
    //       existing corner and cannot ride (c): a face bevel's inset ring is
    //       the source face's UV POLYGON inset by
    //       `inset * uvPerimeter / geomPerimeter` (`InsetRing`), and an extrude
    //       wall's swept coordinate is a fresh 0→1 parameterisation
    //       (`SweepU`, selected by `UvWallLaw` — the other measured wall law,
    //       `Copy`, needs no gen at all). Both are anchored in a source face +
    //       corner, so they stay per-island; both apply to 2-D maps only.
    //   append — `addFace`/`addFaceFast` grow+zero-fill the new corners
    //       ATOMICALLY (GAP-3, no element-count window). Bulk kernels that
    //       cannot use `addFace` (they rebuild edges once and commit one
    //       change) MUST append through `appendFaceRaw`, which does the same
    //       growth: a bare `faces ~= …` leaves the map short and the tail
    //       `buildLoops` then zeroes it WHOLE — losing the UV of faces the
    //       operation never touched, which is strictly worse than the drop
    //       below. Wired in array (linear / radial / grid), mirror, duplicate,
    //       clipboard paste (`appendGeometry`) and the cut's cap polygons
    //       (task 0690).
    //   snapshot restore — values come back via the captured map `dup`.
    //   (d) undo/redo delta replay — `MeshEditDelta.apply`/`revert` carry the
    //       plane themselves (task 0689). A replay cannot write a corner while
    //       it runs (`faceLoop` is only rebuilt by the tail `buildLoops`), so
    //       `mesh_edit_delta.CornerCarry` tracks each face's PROVENANCE
    //       through the entry walk and relocates once, before that rebuild,
    //       through the same `remapPolyVertexMaps` funnel — plus a second pass
    //       for the corners of faces the replay RE-CREATES, whose values are
    //       gone from the mesh and live only in the delta. Those are captured
    //       by `recordPolyVertexPayload` below (a `MeshOpEntry.Kind.MeshMapDelta`
    //       entry, no longer a stub) at the three kernels that destroy corners
    //       under a batch: `deleteFacesByMask`, `dissolveVerticesByMask`,
    //       `removeEdgesByMask`. A new corner with no source in either state
    //       is left at zero. `dropPolyVertexMaps` remains the FALLBACK for the
    //       replays the carry declines — see task 0689 and the note there.
    // v1 DROP set — since task 0830 this is no longer a LIST kept here. Each
    // kernel that cannot state a correspondence says so where it runs, by type:
    // `dropCornerProvenance(CornerDrop.…)`, and the reason enum in
    // source/mesh_corner_maps.d carries the explanation. Grep `CornerDrop.` for
    // the current membership; a family cannot enter or leave the set by an edit
    // to this comment any more, which was the point.
    //
    // What the reasons MEAN, since that is what a comment is still good for:
    //   * `SweptSurfaceNoLaw` — edge extrude, vertex extrude, edge extend,
    //     smooth shift, path-extrude (revolve). A fresh surface whose
    //     parameterisation no capture measures. (A FACE extrude's two wall laws
    //     ARE frozen, task 0697, which is exactly why that sibling carries.)
    //   * `VertexBevelNoCase` — `bevelVerticesByMask`. Its two siblings left the
    //     set against frozen cases; this one has no frozen case at all.
    //   * `ChordSplitNoSource` / `WeldTailNoSource` — the plane-cut / edge-slice
    //     chord split and the vertex-merge tail. These are MACHINERY gaps, not
    //     law gaps: the law is the same edge-split lerp Loop Slice already
    //     carries, and what is missing is the record of which old face each
    //     fragment came from.
    //   * `SubdivideNoLaw` / `PrimitiveRebuild` / `SubpatchCage` /
    //     `ForeignTopology` — kernels that REPLACE the mesh rather than edit it.
    //     Declared for completeness of the vocabulary; a replaced mesh has no
    //     old corner space at all, so most of them have nothing to declare.
    //     Task 0901 walked every site the vocabulary names for these four and
    //     found none live: `commands/mesh/subdivide.d` and
    //     `commands/mesh/remesh.d` both do `*mesh = result` (a fresh `Mesh`
    //     that never had a map — see `resizePolyVertexMaps`'s note above),
    //     `io/scene_ir.d`/`io/scene_import.d`/`commands/scene/load_mesh.d`
    //     build-then-swap the same way, `subpatch_osd.d`'s preview mesh never
    //     registers a PolyVertex map, and `remesh/region_stitch.d`'s
    //     intermediate `Mesh` scratch values are the same. `PrimitiveRebuild`,
    //     `SubpatchCage` and `ForeignTopology` are therefore reserved, unused
    //     vocabulary today — see each reason's own doc comment in
    //     `mesh_corner_maps.d` for the specific site it was checked against.
    // (The delta undo/redo replay LEFT this set in task 0689 — see mechanism (d)
    // above; what remains there is a fallback, `DeltaReplayDeclined`.)
    //
    // `bevelEdgesByMask`, `bevelFacesByMask` and `extrudeFacesByMask` LEFT the
    // set in task 0697 via (c') + (e); their laws are frozen in the same
    // fixture (`edge_bevel_*` / `face_bevel_*` / `face_extrude_*`) and asserted
    // by tests/test_uv_carry_bevel_extrude.d. What is still zero inside those
    // three, deliberately and locally rather than mesh-wide:
    //   * an edge bevel's MITER corner (both bordering edges beveled) — it sits
    //     inside the face, on no original edge, and no capture measures it. A
    //     bevel of a TURNING edge chain would settle it;
    //   * a rounded profile's arc points and the junction/Gregory patches, for
    //     the same reason (every frozen case is Round Level 0);
    //   * a face bevel's SQUARE cap ring and grouped-corner sharing beyond what
    //     `sharedCornerPos` registers first.
    // Those are the honest zero of mechanism (c), not a whole-mesh drop: the
    // faces the operation never touched keep their values byte for byte.
    // See doc/uv_maps_plan.md D5.
    //
    // The drop set is deliberately about NEW corners. A kernel whose corner
    // count changes drops the map for the WHOLE mesh, so the two are only the
    // same thing for a kernel that rewrites every face; anything more local
    // (append a face, splice one corner) must carry or grow instead, or the
    // untouched half of the mesh pays for the edit (task 0690).
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
    // Call after any wholesale geometry replacement — `catmullClarkOsd`,
    // an importer building a fresh Mesh, `reset`.
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
        // Stated loss (task 0830). The remap rewrote every winding from a VERTEX
        // map and kept no record of which old corner each survivor was — the
        // machinery gap task 0690 named, not a law gap. Declared rather than
        // left to the length test, which reached the same zeroing by accident.
        dropCornerProvenance(CornerDrop.WeldTailNoSource);
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



    unittest { // one vertex cannot be absorbed twice; the first pair wins
        import std.conv : to;
        Mesh m = makeWeldPairStrip();
        uint[2][] pairs = [[4u, 1u], [2u, 1u]];
        assert(m.weldVertexPairs(pairs) == 1,
            "a second claim on the same drop must be refused — expected 1 weld");
        assert(m.vertices.length == 5,
            "double-absorb reject: expected V=5, got " ~ m.vertices.length.to!string);
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
    /// / `collapseFacesByMask` (both in this file) — parent[] +
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
        // Task 0830: this capture is the obligation handle. `beginCornerRelocate`
        // takes the OFFSETS only — a relocation names each source corner by
        // index and never looks a vertex up in an old winding — and it ARMS the
        // drop: a path out of here that rewrites `faces` without declaring loses
        // the plane rather than keeping values on foreign corners.
        auto rw = beginCornerRelocate();
        const bool remapUv = rw.active();
        const(uint)[] oldFaceLoop = rw.oldFaceLoop();
        uint[] oldLoopOfNewLoop;

        uint[][] newFaces;
        // Task 0921: gathered in survivor order, keyed by each face's OLD
        // index `fi` — the same shape the per-corner (UV) relocate just below
        // already uses for this exact drop, and byte-identical to the weld
        // sibling `applyVertexRemapAndRebuild`'s own gather above in this
        // file. Without this, a face dropped anywhere but the array's tail
        // left every survivor after it wearing a FRONT-TRUNCATED slice of the
        // pre-collapse material/part/marks arrays instead of its own values.
        uint[]   newWord;   // whole faceMarks word per survivor (Select dropped below)
        int[]    newOrder;
        uint[]   newMaterial;
        uint[]   newPart;
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
                newFaces    ~= f;
                newWord     ~= faceAttrOr(faceMarks, fi);
                newOrder    ~= faceAttrOr(faceSelectionOrder, fi);
                newMaterial ~= faceAttrOr(faceMaterial, fi);
                newPart     ~= faceAttrOr(facePart, fi);
                if (remapUv)
                    foreach (sc; srcCorner)
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, sc);
            } else {
                faceRemap[fi] = -1;
            }
        }
        faces              = newFaces;
        setFaceMarksFrom(newWord, ~Marks.Select);
        faceSelectionOrder = newOrder;
        faceMaterial       = newMaterial;
        facePart           = newPart;
        if (remapUv) declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));

        rebuildEdges();

        clearEdgeSelectionResize();
        // Face selection: setFaceMarksFrom above already dropped Select;
        // this both re-asserts that and publishes the selection-domain
        // change notification, same as every other face-compaction site
        // (deleteFacesByMask, applyVertexRemapAndRebuild, cleanDegenerateFaces).
        clearFaceSelectionResize();

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
        // Task 0920: `vertexMarks` / `vertexSelectionOrder` / every
        // Point-domain MeshMap (vertex weight, vertex color) must ride the
        // SAME `remap` as `vertices` itself. The tail `resizeVertexSelection()`
        // below only grows/shrinks these arrays by LENGTH — it does not move a
        // value between slots — so leaving it to do the work alone is exactly
        // the truncate-from-the-tail bug: a vertex dropped from the middle of
        // the array left every survivor after it wearing the mark/weight that
        // used to sit at ITS new index, not its own. Gather each survivor's own
        // value from its OLD index into its NEW slot here, BEFORE `vertices` is
        // overwritten — the same gather `applyReindexForward` (mesh_edit_delta.d)
        // already runs for `vertexMarks`/`vertexSelectionOrder` on the undo/redo
        // side of this exact compaction; this is that shape, extended to the
        // Point-domain map registry it does not reach.
        uint[] newMarks;
        newMarks.length = newVerts.length;
        int[] newOrder;
        newOrder.length = newVerts.length;
        foreach (old, p; remap) {
            if (p == cast(uint)~0u) continue;
            if (old < vertexMarks.length) newMarks[p] = vertexMarks[old];
            if (old < vertexSelectionOrder.length) newOrder[p] = vertexSelectionOrder[old];
        }
        vertexMarks          = newMarks;
        vertexSelectionOrder = newOrder;
        foreach (ref mm; meshMaps) {
            if (mm.domain != MapDomain.Point) continue;
            const ubyte dim = mm.dim;
            float[] nd;
            nd.length = newVerts.length * dim;
            foreach (old, p; remap) {
                if (p == cast(uint)~0u) continue;
                const size_t ob = cast(size_t)old * dim;
                if (ob + dim > mm.data.length) continue; // defensive
                nd[p * dim .. p * dim + dim] = mm.data[ob .. ob + dim];
            }
            mm.data = nd;
        }
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
        // is inverted in, before the tail compactUnreferenced reindexes verts) —
        // and since task 0831 that is the TYPE, not just this comment: a
        // `FaceIdx` can only come off the live `faces` array (`faceIndices`
        // below), so the scratch-array position the sibling kernels used to
        // record here no longer type-checks.
        FaceIdx[] droppedFaceIdx;
        uint[][] droppedFaceLists;
        uint[]   droppedFaceMat;
        uint[]   droppedFacePart;
        uint[]   droppedFaceSub;
        const bool recDelete = editRecorder_ !is null;
        // Task 0680 — the delta for a bulk face removal used to cost TWO GC
        // allocations per removed face: `f.dup` here, then a second copy of
        // every list inside recordRemoveFaces. On a whole-mesh remove
        // (99 856 faces) that is ~200 000 allocations to record ONE entry, and
        // the collector work behind them is what made the operation itself
        // read +612% against the perf baseline.
        //
        // Now: one pass over the mask sizes everything exactly, the vertex
        // lists live in ONE flat buffer, and each entry in `droppedFaceLists`
        // is a SLICE of it. Two allocations for the geometry instead of one
        // per face. The buffer is sized up front and never appended to, so the
        // slices stay valid; the recorder takes ownership and only ever reads
        // them (its revert path dups before inserting).
        uint[] droppedFlat;
        size_t flatFill = 0;
        if (recDelete) {
            size_t willDrop = 0, corners = 0;
            foreach (i, ref f; faces)
                if (i < mask.length && mask[i]) { ++willDrop; corners += f.length; }
            droppedFaceIdx.reserve(willDrop);
            droppedFaceLists.reserve(willDrop);
            droppedFaceMat.reserve(willDrop);
            droppedFacePart.reserve(willDrop);
            droppedFaceSub.reserve(willDrop);
            droppedFlat.length = corners;
        }
        // PolyVertex remap, mechanism (a): surviving faces keep their corner
        // count, so corner `c` of a kept face maps to old loop
        // oldFaceLoop[oldFi]+c. Build `oldLoopOfNewLoop` in NEW-face/new-corner
        // (CSR) order while filtering, then relocate before the tail buildLoops.
        // Task 0830: this capture is the obligation handle. `beginCornerRelocate`
        // takes the OFFSETS only — a relocation names each source corner by
        // index and never looks a vertex up in an old winding — and it ARMS the
        // drop: a path out of here that rewrites `faces` without declaring loses
        // the plane rather than keeping values on foreign corners.
        auto rw = beginCornerRelocate();
        const bool remapUv = rw.active();
        const(uint)[] oldFaceLoop = rw.oldFaceLoop();
        uint[] oldLoopOfNewLoop;
        foreach (i; faceIndices) {
            auto f = faces[i];
            if (mask[i]) {
                ++removed;
                if (recDelete) {
                    droppedFaceIdx   ~= i;
                    droppedFlat[flatFill .. flatFill + f.length] = f[];
                    droppedFaceLists ~= droppedFlat[flatFill .. flatFill + f.length];
                    flatFill += f.length;
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
        if (recDelete) {
            // Per-corner payload FIRST (task 0689): the dropped faces' UV is
            // still readable here — `faces` and the maps are both untouched —
            // and in two statements it will not be. `droppedFaceIdx` is in the
            // live (pre-drop) index space, which is what the capture wants.
            recordPolyVertexPayload(droppedFaceIdx);
            editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                            droppedFaceMat, droppedFacePart, droppedFaceSub);
        }
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
        if (remapUv) declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));
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
        // Task 0830: a winding flip is a corner PERMUTATION — the one shape
        // that leaves the corner total untouched, so the length test has
        // nothing to say about it and every value would be kept, each on the
        // corner that used to be its mirror. Open the rewrite before the first
        // `reverse` so that silence here costs the plane instead.
        auto rw = beginCornerRelocate();
        const bool needUV = rw.active();
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
                // The capture's offsets, not `faceLoop` — same numbers here
                // (arity is preserved, so the pre- and post-flip CSR agree),
                // but sourced from the windings the correspondence is about
                // rather than from a cache that a different kernel could leave
                // stale.
                const uint base = rw.oldFaceLoop()[fi];
                const uint n    = cast(uint) faces[fi].length;
                if (mask[fi] && n >= 3)
                    foreach (j; 0 .. n) oldLoopOfNewLoop[base + j] = base + (n - 1 - j);
                else
                    foreach (j; 0 .. n) oldLoopOfNewLoop[base + j] = base + j;
            }
            declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));
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
        // Both index in the OLD (pre-rewrite) face-index space — the live index
        // `fi` — which is the one every entry uses (MeshOpEntry, "THE INDEX
        // SPACE OF AN ENTRY") and, being the space the maps are still in, also
        // the one the per-corner payload capture wants (task 0689). Both entries
        // invert before the tail compactUnreferenced's vert reindex (LIFO).
        //
        // Task 0703: these used to be recorded in the POST-shrink space
        // (`newFaces.length` at the moment each face was appended/dropped),
        // which is wrong twice over. Two faces dropped from the head both read
        // 0, so `RemoveFaces⁻¹`'s ascending insertInPlace returned them
        // reversed; and the reshape index is consumed AFTER that inverse has
        // already re-inserted the dropped faces — i.e. against an array that is
        // back in the pre-op space — so it landed on a re-inserted face and
        // overwrote it. Pinned by tests/test_mesh_edit_delta.d (g).
        //
        // Task 0831: both accumulators are `FaceIdx[]`, so the exact expression
        // that caused it — `newFaces.length`, a position in the array being
        // BUILT — is now a compile error here rather than a number that agrees
        // with the right answer whenever only one face is dropped.
        const bool recDis = editRecorder_ !is null;
        FaceIdx[] reshapeIdx;
        uint[][] reshapeBefore;
        uint[][] reshapeAfter;
        FaceIdx[] removedFaceIdx;
        uint[][] removedFaceLists;
        uint[]   removedFaceMat;
        uint[]   removedFacePart;
        uint[]   removedFaceSub;
        // PolyVertex remap, mechanism (b): a masked corner is dropped from its
        // face's corner LIST, so new corner `j` of a surviving face came from a
        // specific OLD corner `k` (its position in the old face). Build
        // `oldLoopOfNewLoop` in NEW-face/new-corner (CSR) order so a planted UV
        // follows the surviving corner even as the face changes arity.
        // Task 0830: this capture is the obligation handle. `beginCornerRelocate`
        // takes the OFFSETS only — a relocation names each source corner by
        // index and never looks a vertex up in an old winding — and it ARMS the
        // drop: a path out of here that rewrites `faces` without declaring loses
        // the plane rather than keeping values on foreign corners.
        auto rw = beginCornerRelocate();
        const bool remapUv = rw.active();
        const(uint)[] oldFaceLoop = rw.oldFaceLoop();
        uint[] oldLoopOfNewLoop;
        foreach (fi; faceIndices) {
            auto f = faces[fi];
            uint[] kept;
            uint[] keptCorner; // old corner index of each kept corner (mech b)
            foreach (k, vid; f) {
                if (vid < mask.length && mask[vid]) continue;
                kept ~= vid;
                if (remapUv) keptCorner ~= cast(uint)k;
            }
            if (kept.length >= 3) {
                if (recDis && kept.length != f.length) {
                    reshapeIdx    ~= fi;
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
                // Degenerate face dropped — reconstruct it on revert at the
                // index it holds RIGHT NOW, in the pre-rewrite array.
                removedFaceIdx   ~= fi;
                removedFaceLists ~= f.dup;
                removedFaceMat   ~= faceAttrOr(faceMaterial, fi);
                removedFacePart  ~= faceAttrOr(facePart, fi);
                removedFaceSub   ~= (isFaceSubpatch(fi) ? 1u : 0u);
            }
        }
        if (recDis) {
            // Reshape first, then RemoveFaces — on revert (LIFO) the dropped
            // faces are re-inserted FIRST, which restores the pre-rewrite
            // length and ORDER, and only then are the reshape lists restored,
            // at the pre-rewrite indices both entries were recorded in.
            // Each face entry is preceded by its own per-corner payload (task
            // 0689): the reshape's payload holds the PRE-shrink corner values
            // of the faces it shortens (the dissolved corner among them), the
            // removal's holds the degenerate faces' corners. `faces` is still
            // the pre-rewrite array here, so both reads are in the live space —
            // the same space the entries' own indices are in.
            recordPolyVertexPayload(reshapeIdx);
            editRecorder_.recordReshapeFaces(reshapeIdx, reshapeBefore, reshapeAfter);
            recordPolyVertexPayload(removedFaceIdx);
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
        if (remapUv) declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));
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
        // Flat, not hashed (task 0688): both of these used to be associative
        // arrays walked once per selected edge — ~200 000 hashed inserts for
        // the keys and ~100 000 more for the seen-set on the perf lane's grid,
        // paid before the merge even starts. The keys are needed ONLY by the
        // stale-loops fallback below, so they are built there, lazily; the
        // seen-set is a plain bool[] indexed by vertex.
        bool[] regionSeen;
        regionSeen.length = vertices.length;
        size_t selectedEdgeCount = 0;
        foreach (i; 0 .. edges.length)
            if (mask[i]) {
                uint a = edges[i][0], b = edges[i][1];
                ++selectedEdgeCount;
                if (a < vertices.length && !regionSeen[a]) {
                    regionSeen[a] = true; lastEdgeDeleteRegion_ ~= vertices[a];
                }
                if (b < vertices.length && !regionSeen[b]) {
                    regionSeen[b] = true; lastEdgeDeleteRegion_ ~= vertices[b];
                }
            }
        if (selectedEdgeCount == 0) { lastEdgeDeleteRegion_ = null; return 0; }

        // PolyVertex remap, mechanism (b): merging faces rewrites the corner
        // LIST (the merged poly is a boundary walk). Capture the OLD CSR corner
        // offsets so each merged-poly corner — and each kept face's corner — can
        // be traced to an old loop index. Built into `oldLoopOfNewLoop` in the
        // final [kept ++ merged] face order below.
        // Task 0830: this capture is the obligation handle. `beginCornerRelocate`
        // takes the OFFSETS only — a relocation names each source corner by
        // index and never looks a vertex up in an old winding — and it ARMS the
        // drop: a path out of here that rewrites `faces` without declaring loses
        // the plane rather than keeping values on foreign corners.
        auto rw = beginCornerRelocate();
        const bool remapUv = rw.active();
        const(uint)[] oldFaceLoop = rw.oldFaceLoop();

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
        // Edge → its (up to two) adjacent faces. `buildEdgeFaces` answers this
        // from `faces` alone — correct under ANY loop state, and the reason it
        // exists — but it hashes every corner of every face: on the perf lane's
        // 99 856-face grid that one call, plus the keyed walk below, measured
        // 90 ms of the kernel's 157 ms (task 0688).
        //
        // The half-edge structure already holds the same fact positionally:
        // `loopEdge[li]` is the edge of dart `li` and `loops[li].face` its face.
        // When it is VALID (the stamp `loopsValid()` — task 0678 M6 — not a
        // guess), the incidence can be read off flat, indexed by edge, with no
        // hashing at all; the walk below then iterates edge INDICES straight
        // off `mask` instead of re-deriving keys. Same "first two DISTINCT
        // faces, ascending" semantics: darts are visited in face order.
        //
        // Stale loops fall back to the hashed path, so the contract that made
        // `buildEdgeFaces` the safe answer is preserved, not traded away.
        size_t dissolved = 0;
        bool[ulong] dissolvedEdgeKeys;   // edges ACTUALLY merged (interior, both faces)
        if (loopsValid() && loopEdge.length == loops.length) {
            auto ef = new int[2][](edges.length);
            foreach (ref slot; ef) slot = [-1, -1];
            foreach (li, ref lp; loops) {
                if (li >= loopEdge.length) break;
                immutable uint e = loopEdge[li];
                if (e >= ef.length) continue;
                immutable int fi = cast(int) lp.face;
                if (ef[e][0] == -1) ef[e][0] = fi;
                else if (ef[e][1] == -1 && ef[e][0] != fi) ef[e][1] = fi;
            }
            foreach (i; 0 .. edges.length) {
                if (!mask[i]) continue;
                immutable int fA = ef[i][0], fB = ef[i][1];
                if (fA != -1 && fB != -1) {
                    unite(fA, fB);
                    dissolvedEdgeKeys[edgeKey(edges[i][0], edges[i][1])] = true;
                    ++dissolved;
                }
            }
        } else {
            auto edgeFaces = buildEdgeFaces();
            bool[ulong] selectedEdgeKeys;
            foreach (i; 0 .. edges.length)
                if (mask[i]) selectedEdgeKeys[edgeKey(edges[i][0], edges[i][1])] = true;
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
        // faces, recorded in the PRE-DROP face-index space — the space every
        // entry uses, see MeshOpEntry's "THE INDEX SPACE OF AN ENTRY", and the
        // only one RemoveFaces⁻¹'s ascending insertInPlace reconstructs) plus
        // an AddFaces (the appended merged polys, a tail range). The tail
        // compactUnreferenced then self-logs RemoveVerts + Reindex via the
        // Class-R hook. Forward log for an edge dissolve =
        // [RemoveFaces, AddFaces, RemoveVerts, Reindex].
        //
        // Task 0703: this used to record the POST-drop slot
        // (`keptFaces.length` at the moment of the drop). An edge dissolve
        // drops the WHOLE component — two faces for an ordinary interior edge —
        // so the two spaces never coincided here: both component faces of a
        // head-of-array pair recorded index 0 and undo returned them reversed,
        // silently moving selection / faceMaterial / facePart / the per-corner
        // maps onto the other face. Pinned by tests/test_mesh_edit_delta.d (f).
        const bool recRemoveEdges = editRecorder_ !is null;
        // PRE-drop = the live index `fi`, so this doubles as the live-space
        // index list the per-corner payload capture needs (task 0689).
        FaceIdx[] droppedFaceIdx;
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
        foreach (fi; faceIndices) {
            if (dropFace[fi]) {
                if (recRemoveEdges) {
                    // PRE-drop position = the live index `fi`. On revert
                    // RemoveFaces⁻¹ re-inserts ascending at exactly these
                    // indices, re-opening the slot each face vacated and so
                    // restoring the original ORDER, not merely the set.
                    //
                    // THE TASK-0831 MUTATION LIVES HERE, and it is the reason
                    // the accumulator is a `FaceIdx[]`. The arm below is the
                    // 0703 defect restored verbatim — `keptFaces.length`, the
                    // slot this face WOULD have occupied in the array being
                    // built. It compiled for months, agreed with the line above
                    // on every fixture that dropped one face, and returned an
                    // edge dissolve's faces reversed on undo. It no longer
                    // compiles: there is no implicit `uint` → `FaceIdx`. Prove
                    // it with
                    //     dub build --config=modeling --d-version=MutateIndexSpace0831
                    // which must FAIL, and fail on THIS line. (Same negative-
                    // control convention as `UndoNegControlRemoveFaces` et al.
                    // in mesh_edit_delta.d — compiled only under its own
                    // version, so a normal build carries none of it.)
                    version (MutateIndexSpace0831)
                        droppedFaceIdx ~= cast(uint)keptFaces.length;
                    else
                        droppedFaceIdx ~= fi;
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
            // the dropped component faces re-insert at their pre-drop indices.
            // The removal's per-corner payload (task 0689) goes ahead of it;
            // the AddFaces needs none, since a merged polygon is a brand-new
            // face on the way FORWARD (its corners come back on revert with
            // the component faces they were merged from). `droppedFaceIdx` is
            // the live (pre-drop) space, which is what the capture wants.
            recordPolyVertexPayload(droppedFaceIdx);
            editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                            droppedFaceMat, droppedFacePart, droppedFaceSub);
            uint[][] mergedLists;
            mergedLists.length = newPolyList.length;
            foreach (i; 0 .. newPolyList.length) mergedLists[i] = newPolyList[i].dup;
            // `assumeFaceSpace`, and this is the one call in the kernel that
            // earns it (task 0831). An AddFaces' `[F0,F1)` is NOT a live face
            // index — it is the tail base in the array `faces` is ABOUT to
            // become, i.e. precisely the scratch-array length the mutation arm
            // above is forbidden from recording. The two entry kinds carry
            // genuinely different spaces in the same field, and the type cannot
            // tell them apart; naming the conversion here is what keeps that
            // visible instead of implicit.
            editRecorder_.recordAddFaces(FaceIdx.assumeFaceSpace(firstMerged),
                                         cast(uint)keptFaces.length, mergedLists);
        }
        faces              = keptFaces;
        setFaceMarksFrom(keptWord, ~Marks.Select);
        faceSelectionOrder = keptOrder;
        faceMaterial       = keptMaterial;
        facePart           = keptPart;
        // PolyVertex relocate (b): per-corner values follow the merged/kept
        // corners. Before the tail buildLoops (which then no-ops the resize).
        if (remapUv) declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));
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
        // Task 0830: this capture is the obligation handle. `beginCornerRelocate`
        // takes the OFFSETS only — a relocation names each source corner by
        // index and never looks a vertex up in an old winding — and it ARMS the
        // drop: a path out of here that rewrites `faces` without declaring loses
        // the plane rather than keeping values on foreign corners.
        auto rw = beginCornerRelocate();
        const bool remapUv = rw.active();
        const(uint)[] oldFaceLoop = rw.oldFaceLoop();
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
        if (remapUv) declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));
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
                appendFaceRaw(cloned);   // grows per-corner maps (task 0690)
            }
        }

        // Task 0830: a tail append, stated. `appendFaceRaw` already grew the
        // per-corner plane face by face; this states the resulting TOTAL so the
        // rebuild can check it against the corner space it actually lays down.
        declareCornerAppend();

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
            const size_t cornersBeforeWeld = cornerCount();
            if (weldCoincidentVertices(epsSq) > 0) {
                rebuildEdges();
                clearEdgeSelectionResize();
                compactUnreferenced();
                // What the weld did to the CORNERS is decided by the only
                // thing it leaves behind — the total (task 0830).
                declareCornerWeld(cornersBeforeWeld);
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
                appendFaceRaw(cloned);   // grows per-corner maps (task 0690)
            }
        }

        declareCornerAppend();   // tail append, stated (task 0830)

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
            const size_t cornersBeforeWeld = cornerCount();
            if (weldCoincidentVertices(epsSq) > 0) {
                compactUnreferenced();
                // What the weld did to the CORNERS is decided by the only
                // thing it leaves behind — the total (task 0830).
                declareCornerWeld(cornersBeforeWeld);
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
                        appendFaceRaw(cloned);   // grows per-corner maps (task 0690)
                    }
                }
            }
        }

        // Tail append, stated (task 0830). When Merge Vertices is on, the dedup
        // pass further down opens its own rewrite and REPLACES this declaration
        // with the relocation that describes it — which is the right order:
        // each declaration describes the corner space as it stands when it is
        // made, and the last one before the rebuild is the one that holds.
        declareCornerAppend();

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
                // Per-corner (UV) relocate — mechanism (a). This rebuild drops
                // whole DUPLICATE faces but keeps every survivor's corner
                // count, so each kept corner has exactly one old corner. Without
                // the relocate the tail `buildLoops` would find a wrong-length
                // map and zero it WHOLE — undoing, for the entire mesh, the
                // append-time growth the clone loop above just did (task 0690).
                //
                // The CSR offsets are recomputed here rather than read from
                // `faceLoop`: `weldCoincidentVertices` just above rewrites face
                // windings WITHOUT a `buildLoops`, so the cached offsets are
                // stale by this point. Task 0830: that recomputation IS what
                // `beginCornerRelocate` does — prefix-sum the live windings —
                // so the hand-rolled `dedupFaceLoop` is now the handle's own
                // offsets, and opening the rewrite here arms the drop for the
                // dedup pass below.
                auto rw = beginCornerRelocate();
                const bool remapUv = rw.active();
                uint[] oldLoopOfNewLoop;
                if (remapUv && faces.length > 0)
                    oldLoopOfNewLoop.reserve(rw.oldFaceLoop()[$ - 1]
                                             + faces[$ - 1].length);
                foreach (fi, ref f; faces) {
                    auto sorted = f.dup;
                    sort(sorted);
                    string fp = format("%(%d,%)", sorted);
                    if (fp in seenFp) continue;
                    seenFp[fp] = true;
                    if (remapUv)
                        foreach (c; 0 .. f.length)
                            oldLoopOfNewLoop ~= rw.oldFaceLoop()[fi] + cast(uint)c;
                    keptFaces    ~= f;
                    keptWord     ~= faceAttrOr(faceMarks, fi);
                    keptOrder    ~= faceAttrOr(faceSelectionOrder, fi);
                    keptSelected ~= (fi < selectedFaces.length      ? selectedFaces[fi]      : false);
                    keptMaterial ~= faceAttrOr(faceMaterial, fi);
                    keptPart     ~= faceAttrOr(facePart, fi);
                }
                faces              = keptFaces;
                if (remapUv) declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));
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
            appendFaceRaw(cloned);   // grows per-corner maps (task 0690)
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

        declareCornerAppend();   // tail append, stated (task 0830)

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
            const size_t cornersBeforeWeld = cornerCount();
            if (weldCoincidentVertices(epsSq, origVertexCount) > 0) {
                rebuildEdges();
                clearEdgeSelectionResize();
                compactUnreferenced();
                // What the weld did to the CORNERS is decided by the only
                // thing it leaves behind — the total (task 0830).
                declareCornerWeld(cornersBeforeWeld);
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
                // The rollback put back the very maps that describe the
                // restored windings, so the corner space this rebuild will
                // lay down is the un-welded one and nothing moved in it.
                // Without this the weld's drop above would still be pending
                // and would zero maps that are already correct.
                declareCornerProvenance(CornerProvenance.unchanged());
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
            appendFaceRaw(cloned);   // grows per-corner maps (task 0690)
        }

        // Re-derive edges from the (now larger) face list. Doing this
        // wholesale is simpler and faster than tracking which edges are
        // new — and stays consistent with the dedup'd-edge invariant
        // used by delete / dissolve.
        declareCornerAppend();   // tail append, stated (task 0830)
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
            // Pasted corners have no UV to carry (the clipboard has no
            // per-corner channel) — but the mesh they land in may, and it must
            // survive the paste. task 0690.
            appendFaceRaw(remapped);
        }

        declareCornerAppend();   // tail append, stated (task 0830)

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
        // Task 0831: read the append base BEFORE the append. The tracker hook
        // at the bottom used to say `faces.length - 1`, which is the same
        // number read the other way round; taking it here is what makes it a
        // `FaceIdx` without an `assumeFaceSpace`, and it is also how
        // `MeshOpEntry`'s own comment describes an AddFaces range ("F0 is the
        // length of `faces` before the append").
        const appendBase = faceAppendBase();
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
            editRecorder_.recordAddFace(appendBase, idx);
    }
    // Fast version using hash lookup for duplicate checking
    void addFaceFast(ref uint[ulong] edgeLookup, uint[] idx) {
        const appendBase = faceAppendBase();   // see addFace (task 0831)
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
            editRecorder_.recordAddFace(appendBase, idx);
    }

    /// Append one face to `faces` WITHOUT any of `addFace`'s bookkeeping —
    /// no edge insert, no version bump, no tracker hook — but WITH the one
    /// step a bare `faces ~= idx` silently skips: growing every PolyVertex
    /// (per-corner) map by this face's corners.
    ///
    /// That step is not a nicety. `resizePolyVertexMaps` (hanging off the tail
    /// `buildLoops` every kernel ends with) keeps a map only when its length
    /// already matches the new corner count; otherwise it makes it
    /// length-correct by ZEROING IT WHOLE. So a bulk kernel that appends
    /// faces with `faces ~= …` does not merely leave the NEW corners without
    /// UV — it wipes the UV of every face it never touched (task 0690).
    /// Bulk kernels (array / mirror / duplicate / paste / cut caps) cannot use
    /// `addFace` — they rebuild edges once at the end and commit one change —
    /// so this is their append primitive. Use it instead of `faces ~=`
    /// whenever a face is appended to a mesh that may outlive the call with
    /// its maps intact.
    ///
    /// Only valid for a TAIL append: the appended corners are last in CSR loop
    /// order, which is what makes zero-filling at the end of the map the right
    /// relocation. A kernel that also changes an EXISTING face's arity has
    /// re-laid the corner space and needs a remap (`remapPolyVertexMaps` /
    /// `carryPolyVertexMaps`), not this.
    void appendFaceRaw(uint[] idx) {
        faces ~= idx;
        growPolyVertexMapsForAppendedCorners(idx.length);
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

    // The same growth stated as a DESTINATION rather than a delta — how the
    // `Appended` declaration is applied (task 0830). Idempotent by
    // construction: a kernel that already grew face-by-face through
    // `appendFaceRaw` is already at (or past) `totalCorners` and this does
    // nothing, while a kernel that appended with a bare `faces ~= …` and states
    // the growth ONCE at the end gets it here, in one pass instead of n.
    private void growPolyVertexMapsTo(size_t totalCorners) {
        foreach (ref m; meshMaps) {
            if (m.domain != MapDomain.PolyVertex) continue;
            const size_t want = totalCorners * m.dim;
            if (m.data.length >= want) continue;
            const size_t old = m.data.length;
            m.data.length = want;
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
    // `allSubpatch()` lived here: "true iff every face is subpatch-marked".
    // Removed (audit №4) — zero callers, and its doc gated a fast path against
    // a `catmullClarkSelected` CPU function that no longer exists. OsdAccel
    // takes the marked SUBSET either way; whether that subset happens to be
    // the whole cage is not a case anyone branches on.

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
    //     DROP class: EDGE extrude, edge-extend, vertex extrude, smooth shift,
    //     path-extrude — every declared `CornerDrop.SweptSurfaceNoLaw` site).
    //     The old per-corner values are meaningless in the new corner space, so
    //     ZERO the whole map at the new length. This is the conscious,
    //     length-correct, value-dropped behaviour (D5 drop set); leaving stale
    //     leading values in new corner slots would be silent corruption.
    //
    //     Corrected (task 0901): this list used to also name primitive
    //     rebuilds, subdivide and bridge. It shouldn't have —
    //       * subdivide (`commands/mesh/subdivide.d`, all three modes) and
    //         remesh (`commands/mesh/remesh.d`) REPLACE the whole `Mesh` value
    //         (`*mesh = result`). The map is not zeroed by this rule at all;
    //         it disappears WITH the old mesh, because `result` never had one.
    //         Calling that a "drop" is the inaccuracy task 0682 introduced.
    //       * primitive create-tools (`tools/create/*`, `mesh_ops/box_geom.d`)
    //         only ever APPEND via `addFace` into the live scene mesh — see
    //         `CornerDrop.PrimitiveRebuild`'s doc comment.
    //       * bridge (`mesh_ops/bridge.d`) is the same shape — append-only via
    //         `addFace` — see `CornerDrop.SweptSurfaceNoLaw`'s doc comment.
    //       * the subpatch cage/preview (`subpatch_osd.d`) builds a disposable
    //         `out Mesh`/`ref Mesh preview` that never registers a PolyVertex
    //         map in the first place (its hot `refresh()` path only ever
    //         writes `preview.vertices`, never `preview.faces`), so this rule
    //         is never reached for it either.
    //
    // No-op when no PolyVertex map is registered.
    void resizePolyVertexMaps() {
        // --- the DECLARATION is the arbiter (task 0830) -------------------
        // Consume exactly once: a declaration describes ONE `faces` rewrite,
        // and a second `buildLoops` must not re-apply it.
        const CornerProvenance decl = pendingCornerProvenance_;
        const bool wasArmed         = cornerRewriteArmed_;
        pendingCornerProvenance_    = CornerProvenance.init;
        cornerRewriteArmed_         = false;

        if (decl.kind() == CornerProvenance.Kind.Dropped) {
            // Stated loss. Deferred to here rather than applied at declaration
            // time because the length it must come out at is the NEW
            // `loops.length`, which only exists once this rebuild has run.
            dropPolyVertexMaps();
            return;
        }
        if (decl.declared() && decl.corners() != size_t.max
                            && decl.corners() != loops.length) {
            // The kernel described a corner space it did not end in — it
            // relocated N corners and then changed the corner total again
            // before the rebuild. Its correspondence addresses corners that do
            // not exist, so the honest end state is the stated drop (which is
            // also, exactly, what the length insurance below would have
            // produced).
            //
            // The drop runs FIRST and the shout second, deliberately: a
            // diagnostic that pre-empts the repair leaves the mesh holding a
            // length-wrong map, which is a worse state than the one being
            // reported. Under `-release` the shout is gone and the repair is
            // all that is left, which is the correct behaviour either way.
            dropPolyVertexMaps();
            debug {
                import std.conv : to;
                assert(decl.corners() == loops.length,
                    "corner provenance: declared for a different corner space than "
                    ~ "the one buildLoops rebuilt (kind "
                    ~ to!string(decl.kind()) ~ ": declared "
                    ~ to!string(decl.corners()) ~ " corners, rebuilt "
                    ~ to!string(loops.length) ~ ")");
            }
            return;
        }
        if (wasArmed && !decl.declared()) {
            // A kernel OPENED a corner rewrite and never said what became of
            // the corners. This is the 0697 failure with its teeth pulled: a
            // corner-count-NEUTRAL rewrite lands here with the length still
            // matching, and the insurance below would KEEP every value — each
            // one now sitting on a foreign corner. Silence is a drop.
            dropPolyVertexMaps();
            debug assert(!wasArmed,
                "corner provenance: a face rewrite reached buildLoops without "
                ~ "declaring what became of the corners");
            return;
        }

        // --- length: the INSURANCE, no longer the arbiter ------------------
        // Reached by a `buildLoops` that follows no declared rewrite at all —
        // the overwhelming majority (a rebuild after a vertex move, a fresh
        // mesh, a snapshot restore). It keeps a length-correct map and zeroes a
        // length-wrong one, exactly as before task 0830. Every kernel converted
        // to declare passes through the branches above and never reaches here.
        foreach (ref m; meshMaps) {
            if (m.domain != MapDomain.PolyVertex) continue;
            const size_t want = loops.length * m.dim;
            if (m.data.length == want) continue; // relocate/append/unchanged → keep
            // Topology rewritten without a relocate ⇒ drop (length-correct, zeroed).
            // The repair runs FIRST and the diagnostic second, same ordering
            // rule as the two asserts above: a mesh must never be left holding
            // a wrong-length map, in either build type.
            m.data.length = want;
            m.data[] = 0.0f;
            // A per-corner plane really did exist and really was thrown away,
            // and nobody said so — the census 0830 left open (bridge, the
            // primitive-create commit paths, the subpatch cage build, the
            // remesh / import paths) is now closed by task 0901: every one of
            // those either declares (bridge, primitives — Appended) or is
            // verified NOT APPLICABLE (subpatch cage, remesh, import, load-
            // mesh, subdivide, topology pen — none of them rewrites a `Mesh`
            // that still owns a live PolyVertex map). This was a one-time
            // `fprintf` warning through task 0900; promoted to a `debug
            // assert` here now that reaching this branch at all is the
            // failure, not an expected, uncatalogued gap. Under `-release`
            // this compiles out and the repair above is all that runs — the
            // correct behaviour either way, matching the two asserts above.
            debug assert(false,
                "corner provenance: a face rewrite reached buildLoops without "
                ~ "declaring what became of the corners, and without arming "
                ~ "beginCornerRewrite()/beginCornerRelocate() either — a "
                ~ "kernel outside the task 0830/0901 census. Open a "
                ~ "beginCornerRewrite()/beginCornerRelocate() capture at the "
                ~ "site and declare what happened to the corners "
                ~ "(Unchanged/Appended/Relocated/Carried/Dropped(reason)).");
        }
    }

    // --- The corner-provenance obligation (task 0830) ---------------------
    // The declaration a kernel owes, and the capture it is resolved against.
    //
    // THE SHAPE. A kernel that is about to renumber corners opens the rewrite:
    //
    //     auto rw = beginCornerRewrite();      // captures the OLD corner space
    //     …rebuild `faces`…
    //     declareCornerProvenance(rw.carried(newFaces, srcOfCorner, blends));
    //     rebuildEdges();
    //     buildLoops();                        // consumes the declaration
    //
    // `beginCornerRewrite` is not ceremony: it returns the two things every
    // correspondence is resolved against — the old windings and the old CSR
    // offsets — which five kernels used to capture by hand, five times, with
    // five different guards. The kernel calls it because it NEEDS the capture;
    // the obligation rides along.
    //
    // WHAT THE ARMING BUYS. From the moment the capture is taken until the
    // declaration lands, the per-corner plane is IN FLIGHT and its default
    // outcome is the DROP — not the length test. That is the half of the class
    // a length check can never see (task 0697): a rewrite that leaves the corner
    // TOTAL unchanged has a length-correct map at the end, so the insurance
    // keeps every value, and every value is now on a foreign corner. Under the
    // arming, saying nothing loses the values instead of scrambling them.
    //
    // WHY THE HANDLE HAS A DESTRUCTOR. A kernel may bail after the capture and
    // before it rewrites anything (an empty mask, a degenerate input). The
    // destructor disarms, so an abandoned rewrite leaves the plane exactly as it
    // found it. The two failure directions are deliberately asymmetric:
    // disarming too EARLY falls back to the length insurance (the pre-0830
    // behaviour), disarming too LATE drops a plane and goes loudly red in the
    // UV lanes. Neither can silently keep a wrong value.
    //
    // INERT WITHOUT A MAP. With no PolyVertex map registered the capture is
    // skipped, nothing is armed, and every declaration is a no-op — the same
    // "don't pay for what isn't there" rule the carry sites already applied by
    // hand with `if (hasPolyVertexMap())`.
    struct CornerRewrite {
        private Mesh*    mesh_;
        private bool     active_;
        private bool     haveWindings_;
        private uint[][] oldFaces_;
        private uint[]   oldFaceLoop_;

        // One owner. A copied handle would disarm the mesh when the copy died,
        // leaving the original's declaration to be judged by length again.
        @disable this(this);

        ~this() {
            if (mesh_ !is null) mesh_.disarmCornerRewrite();
        }

        /// True iff there is a per-corner plane to owe anything to AND the
        /// capture describes it. False makes every builder below produce
        /// `unchanged()` — a declaration that costs nothing and claims nothing.
        bool active() const { return active_; }

        /// The windings as they were at capture time. Every correspondence
        /// resolves its source corners against THESE, never against the live
        /// `faces` (which the kernel is in the middle of rewriting).
        const(uint[])[] oldFaces() const { return oldFaces_; }

        /// CSR offsets for `oldFaces`, computed by prefix sum over the captured
        /// windings rather than copied from `faceLoop`. That is deliberate:
        /// `weldCoincidentVertices` rewrites windings WITHOUT a `buildLoops`, so
        /// `faceLoop` can be stale exactly where a kernel needs offsets, and a
        /// prefix sum over what was captured cannot be (task 0690's stale
        /// `faceLoop` trap).
        const(uint)[] oldFaceLoop() const { return oldFaceLoop_; }

        // --- the declarations, bound to this capture ----------------------

        /// Mechanism (c') — per-CORNER source, plus blends for corners standing
        /// on inserted vertices and `gens` for corners the kernel computes.
        CornerProvenance carried(const(uint[])[] newFaces,
                                 const(uint)[]   srcFaceOfNewCorner,
                                 PolyVertexBlend[uint] blendOfNewVertex,
                                 const(PolyVertexGen)[] gens = null) {
            if (!active_) return CornerProvenance.unchanged();
            assert(haveWindings_,
                   "a carry resolves its sources by looking a VERTEX up in an "
                   ~ "old face — open it with beginCornerRewrite(), not "
                   ~ "beginCornerRelocate()");
            CornerProvenance.Carry c;
            c.newFaces           = newFaces;
            c.srcFaceOfNewCorner = srcFaceOfNewCorner;
            c.oldFaces           = oldFaces_;
            c.oldFaceLoop        = oldFaceLoop_;
            c.blendOfNewVertex   = blendOfNewVertex;
            c.gens               = gens;
            return CornerProvenance.carried(c);
        }

        /// Mechanism (c) — the same, with ONE source face per new FACE. Expands
        /// to the per-corner form here so the two entries can never drift: what
        /// the per-corner path does IS what this does, with a constant source
        /// across each face's corners.
        CornerProvenance carriedPerFace(const(uint[])[] newFaces,
                                        const(uint)[]   srcFaceOfNewFace,
                                        PolyVertexBlend[uint] blendOfNewVertex,
                                        const(PolyVertexGen)[] gens = null) {
            if (!active_) return CornerProvenance.unchanged();
            size_t total = 0;
            foreach (nf; newFaces) total += nf.length;
            uint[] srcFaceOfNewCorner = new uint[](total);
            size_t at = 0;
            foreach (nfi, nf; newFaces) {
                const uint sf = (nfi < srcFaceOfNewFace.length)
                              ? srcFaceOfNewFace[nfi] : ~0u;
                foreach (_; nf) srcFaceOfNewCorner[at++] = sf;
            }
            return carried(newFaces, srcFaceOfNewCorner, blendOfNewVertex, gens);
        }

        /// Mechanisms (a)/(b) — one old corner per new corner, `~0u` for new.
        CornerProvenance relocated(const(uint)[] oldLoopOfNewLoop) {
            if (!active_) return CornerProvenance.unchanged();
            return CornerProvenance.relocated(oldLoopOfNewLoop);
        }

        /// The corner space was not renumbered after all.
        CornerProvenance unchanged() { return CornerProvenance.unchanged(); }

        /// No correspondence can be stated, and here is why.
        CornerProvenance dropped(CornerDrop why) {
            return CornerProvenance.dropped(why);
        }
    }

    // The declaration the next `buildLoops` will consume, and whether a rewrite
    // is open. Both are TRANSIENT — they live for the span of one kernel, are
    // cleared by `resizePolyVertexMaps`, and mean nothing across a copy of the
    // `Mesh` value (a copy taken mid-kernel is already pathological).
    private CornerProvenance pendingCornerProvenance_;
    private bool             cornerRewriteArmed_;

    /// Open a corner rewrite: capture the old corner space and arm the drop.
    /// See the block comment above for what the arming means.
    CornerRewrite beginCornerRewrite() {
        return openCornerRewrite(true);
    }

    /// Open a rewrite that will be described by a RELOCATION rather than a
    /// carry. Captures the old CSR offsets and arms the drop, but NOT the old
    /// windings — and that is a statement about the mechanism, not a saving:
    /// a relocation names each source corner BY INDEX, so it never looks a
    /// vertex up in an old face, while a carry does exactly that (which is what
    /// lets it resolve a corner standing on an inserted vertex). Asking for a
    /// `carried()` declaration off this handle trips an assert rather than
    /// resolving every corner against an empty winding list.
    ///
    /// The saving is real too: the windings dup is O(corners) and the delete /
    /// dissolve / remove-edges family runs on whole-mesh selections.
    CornerRewrite beginCornerRelocate() {
        return openCornerRewrite(false);
    }

    private CornerRewrite openCornerRewrite(bool captureWindings) {
        CornerRewrite rw;
        rw.mesh_ = &this;
        // Nothing to carry, nothing to lose: skip the capture entirely.
        if (!hasPolyVertexMap()) return rw;
        // The map is ALREADY out of step with `faces` (a kernel caught mid-
        // rewrite). Offsets captured now would address a corner space no map
        // is in, so decline to arm and let the length insurance state the loss.
        if (!polyVertexMapsInStepWithFaces()) return rw;

        // Note what is deliberately NOT a precondition: that `loops` describes
        // the same space. `addEdgePoint` used to require it (`acc !=
        // loops.length ⇒ do not carry`) and hoisting that guard here turned
        // `arrayFacesGrid`'s dedup pass red — measured, task 0830. `loops` is a
        // cache rebuilt only by `buildLoops`, so a MID-kernel capture routinely
        // runs while it still describes the previous corner space (that kernel
        // has already appended faces through `appendFaceRaw`, which grows the
        // map but does not rebuild loops). What the capture's offsets have to
        // agree with is the MAP, and that is exactly what
        // `polyVertexMapsInStepWithFaces` asks — the same reasoning its own doc
        // comment gives for not consulting `loops`.
        rw.active_       = true;
        rw.haveWindings_ = captureWindings;
        if (captureWindings) {
            rw.oldFaces_.reserve(faces.length);
            foreach (ref f; faces) rw.oldFaces_ ~= f.dup;
        }
        rw.oldFaceLoop_.length = faces.length;
        uint acc = 0;
        foreach (fi, ref f; faces) {
            rw.oldFaceLoop_[fi] = acc;
            acc += cast(uint)f.length;
        }
        cornerRewriteArmed_ = true;
        return rw;
    }

    /// State what became of the corners. Applies the correspondence to every
    /// PolyVertex map NOW (it reads the OLD map data and the OLD windings, both
    /// of which the tail `buildLoops` would have moved on from) and records the
    /// declaration for that rebuild to consume.
    ///
    /// The one shape applied LATER is `Dropped`: its end state is a zeroed map
    /// at the NEW `loops.length`, a number that does not exist yet.
    void declareCornerProvenance(CornerProvenance p) {
        assert(p.declared(),
               "declareCornerProvenance: Undeclared is not a declaration — "
               ~ "name one of the five shapes");
        cornerRewriteArmed_ = false;
        // No per-corner plane ⇒ no obligation, and nothing to record. Without
        // this the mechanism stops being inert on the common path: a bulk
        // append would leave a corner TOTAL pending on a mesh with no map, a
        // later pass would legitimately change that total, and the rebuild
        // would report a mismatch about a plane that does not exist. Measured
        // — `arrayFacesGrid` on a map-less mesh, 48 declared vs 44 rebuilt.
        if (!hasPolyVertexMap()) return;
        final switch (p.kind()) {
            case CornerProvenance.Kind.Undeclared:
                break;                                   // refused by the assert
            case CornerProvenance.Kind.Unchanged:
                break;                                   // nothing moves
            case CornerProvenance.Kind.Appended:
                growPolyVertexMapsTo(p.corners());
                break;
            case CornerProvenance.Kind.Relocated:
                remapPolyVertexMaps(p.oldLoopOfNewLoop());
                break;
            case CornerProvenance.Kind.Carried:
                auto c = p.carry();
                carryPolyVertexMapsByCorner(c.newFaces, c.srcFaceOfNewCorner,
                                            c.oldFaces, c.oldFaceLoop,
                                            c.blendOfNewVertex, c.gens);
                break;
            case CornerProvenance.Kind.Dropped:
                break;                                   // applied at the rebuild
        }
        pendingCornerProvenance_ = p;
    }

    /// Declare the stated loss without opening a rewrite — the shape a kernel in
    /// the drop set uses. It needs no capture (there is nothing to resolve
    /// against), so it must not pay for one.
    void dropCornerProvenance(CornerDrop why) {
        declareCornerProvenance(CornerProvenance.dropped(why));
    }

    /// Declare a TAIL append, measuring the resulting corner total off `faces`.
    /// The bulk-append kernels (array ×3, mirror, duplicate, clipboard paste,
    /// cut caps) already grew the plane face-by-face through `appendFaceRaw`,
    /// so this applies nothing — its work is the CROSS-CHECK it earns them.
    /// `resizePolyVertexMaps` now compares the stated total against the
    /// `loops.length` the rebuild produced, so a kernel that appends some faces
    /// through `appendFaceRaw` and others through a bare `faces ~= …` — the
    /// exact shape of task 0690 — trips a diagnostic instead of silently zeroing
    /// the UV of every face it never touched.
    ///
    /// No capture, no arming: a tail append does not renumber anything.
    void declareCornerAppend() {
        declareCornerProvenance(CornerProvenance.appended(cornerCount()));
    }

    /// Σ face arity — the size of the corner space `faces` currently describes,
    /// and the number `loops.length` will be after the next `buildLoops`.
    /// Derived from `faces` on purpose: `loops` is rebuilt only by
    /// `buildLoops`, so mid-kernel it answers about the PREVIOUS space.
    size_t cornerCount() const {
        size_t total = 0;
        foreach (fi; 0 .. faces.length) total += faces[fi].length;
        return total;
    }

    /// State what a WELD pass did to the corners. A weld rewrites windings in
    /// place and only ever REMOVES a corner (a winding that named the same
    /// vertex twice after the merge), so the corner TOTAL decides it and
    /// nothing else has to be tracked:
    ///
    ///   * unchanged ⇒ no winding lost a corner, so every corner is still at
    ///     its own slot. The vertex a corner NAMES may have changed, which is
    ///     not a corner move — per-corner values are addressed by (face,
    ///     corner). `Unchanged`.
    ///   * changed ⇒ the space after the first removal is re-laid, and the weld
    ///     keeps no record of where each corner went. The stated drop — which
    ///     is also exactly what the length test produced here before task 0830.
    ///
    /// This is measured, not assumed: it was written the other way first (a
    /// blanket drop after any weld) and turned `test_uv_untouched_faces`'s
    /// `mirrorFaces+weld` case red, because that weld merges verts BETWEEN the
    /// original and its mirror image and removes no corner at all.
    void declareCornerWeld(size_t cornersBeforeWeld) {
        if (cornerCount() == cornersBeforeWeld)
            declareCornerProvenance(CornerProvenance.unchanged());
        else
            dropCornerProvenance(CornerDrop.WeldTailNoSource);
    }

    // Called by `CornerRewrite`'s destructor. Clears ONLY the arming: a
    // declaration already made stands, and clearing it here would undo the very
    // thing the handle exists to obtain.
    private void disarmCornerRewrite() { cornerRewriteArmed_ = false; }

    // STATED drop of every PolyVertex map: length-correct for the current
    // loops, values zeroed (task 0689). The same END STATE `resizePolyVertexMaps`
    // reaches for the drop class — but reached because the caller SAYS the
    // corner space was renumbered, not inferred from a length mismatch.
    //
    // The distinction is the whole point. `resizePolyVertexMaps` KEEPS a map
    // whose length already matches, on the reasoning that a matching length
    // means the values were placed deliberately. A caller that renumbers
    // corners WITHOUT changing their TOTAL breaks that reasoning: the length
    // still matches, so every value is kept — sitting on a foreign corner.
    // That is silent corruption rather than a documented drop, and no length
    // check can catch it. Such a caller must call THIS instead (or relocate
    // properly through `remapPolyVertexMaps` / `carryPolyVertexMaps`).
    //
    // Its one caller today is the delta replay's FALLBACK (task 0689): the
    // replay normally carries the plane (`mesh_edit_delta.CornerCarry`) and
    // only reaches here when the carry declines — no map, maps out of step
    // with `faces` at replay entry, or its own provenance self-check fired.
    //
    // No-op when no PolyVertex map is registered.
    void dropPolyVertexMaps() {
        foreach (ref m; meshMaps) {
            if (m.domain != MapDomain.PolyVertex) continue;
            m.data.length = loops.length * m.dim;
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

    // Index of `vertex` in a face's corner list, or `~0u`. First occurrence
    // wins — a well-formed face lists each vertex once, and a degenerate one
    // (the same vertex twice) has no better answer to give.
    static uint cornerOfVertexInFace(const(uint)[] face, uint vertex) {
        foreach (k, v; face)
            if (v == vertex) return cast(uint)k;
        return ~0u;
    }

    // Mechanism (c) — arity-CHANGING rebuild that also INSERTS vertices
    // (task 0682). Loop Slice, the bevel family and extrude rebuild `faces`
    // wholesale AND create vertices that did not exist before (rail midpoints,
    // chamfer strips, grid interiors). Mechanism (b) cannot describe them: the
    // funnel copies ONE old corner into ONE new corner, so a corner standing on
    // a brand-new vertex has no old corner to copy and can only come out `~0u`
    // ⇒ zero. That is exactly why those ops sat in the v1 DROP set.
    //
    // The measured law (tests/fixtures/uv_corner_transfer.json, frozen from the
    // reference editor) is an INTERPOLATION inside the source face's own UV
    // island: a vertex inserted at fraction t along edge a→b takes
    // `lerp(uv(a), uv(b), t)`, where `uv(a)`/`uv(b)` are the corner values OF
    // THE FACE BEING REBUILT — not of some canonical per-vertex value. That is
    // what makes a UV seam survive a cut: the two faces meeting at the split
    // edge each interpolate their own corners and each lands in its own island.
    //
    // So the caller supplies, per NEW face, the OLD face it came from
    // (`srcFaceOfNewFace`, `~0u` for a face with no single source), and per
    // INSERTED vertex, the blend of ORIGINAL vertices that produced it
    // (`blendOfNewVertex`). Every new corner is then resolved against the
    // SOURCE OLD FACE's corner list:
    //   * its vertex is one the old face already had ⇒ a plain copy, routed
    //     through the shared `remapPolyVertexMaps` funnel (mechanism (a)/(b));
    //   * its vertex is a blend of vertices the old face had ⇒ a weighted sum
    //     of those corners' values, applied in a SECOND pass straight over the
    //     map data.
    //
    // WHY THE SECOND PASS EXISTS: the funnel's contract is one old corner per
    // new corner. A weighted sum of two or four corners is not expressible in
    // it without changing the signature every existing caller passes, and it is
    // a VALUE operation on one map's floats rather than a relocation of corner
    // identity — the two belong in different passes. The funnel still does all
    // the relocation; this only fills the corners it had to zero.
    //
    // Blend sources are looked up in the OLD face, NOT the new one, so a rail
    // midpoint whose far endpoint is no longer a corner of the sub-face it
    // landed in (every ring-split cap face) still interpolates correctly.
    //
    // Anything unresolvable is left ZERO — precisely the pre-0682 drop
    // behaviour, never a guess: a face with no source (a cap polygon stitched
    // from several ring faces has no single old face to read an island from), a
    // blend source the old face never had, or an over-wide blend.
    //
    // Call BEFORE the tail `buildLoops` and BEFORE `faces` is replaced (it
    // reads the old `faces` through `oldFaces`); the map is left length-correct
    // for the new corner count, so `resizePolyVertexMaps` then no-ops.
    //
    // PER-FACE ENTRY. A new face reads ONE old face's island, which is true of
    // every op that only SUBDIVIDES existing faces (Loop Slice, addEdgePoint,
    // spike). It is not true of a chamfer strip, whose two sides come from the
    // two faces the beveled edge separated — that caller takes the per-CORNER
    // entry below. This one expands its per-face array into the per-corner form
    // and delegates, so the two can never drift apart: whatever the per-corner
    // implementation does, this is exactly it with a constant source per face.
    void carryPolyVertexMaps(const(uint[])[] newFaces,
                             const(uint)[]   srcFaceOfNewFace,
                             const(uint[])[] oldFaces,
                             const(uint)[]   oldFaceLoop,
                             const PolyVertexBlend[uint] blendOfNewVertex) {
        if (!hasPolyVertexMap()) return;
        size_t total = 0;
        foreach (nf; newFaces) total += nf.length;
        uint[] srcFaceOfNewCorner = new uint[](total);
        size_t at = 0;
        foreach (nfi, nf; newFaces) {
            const uint sf = (nfi < srcFaceOfNewFace.length)
                          ? srcFaceOfNewFace[nfi] : ~0u;
            foreach (_; nf) srcFaceOfNewCorner[at++] = sf;
        }
        carryPolyVertexMapsByCorner(newFaces, srcFaceOfNewCorner, oldFaces,
                                    oldFaceLoop, blendOfNewVertex);
    }

    // Mechanism (c), PER-CORNER entry (task 0697). Same contract as the per-face
    // form above, except that the source old face is given for each NEW CORNER
    // (flat, in new-face/new-corner order — the order `buildLoops` will lay
    // down), so different corners of one new face may read different islands.
    // `~0u` for a corner with no source ⇒ the honest zero.
    //
    // Two callers need that: the edge bevel's chamfer strip takes its two sides
    // from the two faces the beveled edge separated, and its corner cap takes
    // each corner from the face whose slide produced it. Resolving such a face
    // against ONE source would put one side of the strip in the wrong island —
    // silent corruption on a seam, invisible on a mesh without one.
    //
    // `gens` is mechanism (e): corners whose value the KERNEL computes from its
    // source face's polygon rather than inheriting (see `PolyVertexGen`). The
    // gen pass runs LAST and OVERWRITES whatever the copy/blend passes wrote at
    // that corner — an extrude wall's base corner is a corner of its source face
    // (so the funnel copies it) and is then swept to u=0, and the sweep is the
    // measured answer.
    void carryPolyVertexMapsByCorner(const(uint[])[] newFaces,
                                     const(uint)[]   srcFaceOfNewCorner,
                                     const(uint[])[] oldFaces,
                                     const(uint)[]   oldFaceLoop,
                                     const PolyVertexBlend[uint] blendOfNewVertex,
                                     const(PolyVertexGen)[] gens = null) {
        if (!hasPolyVertexMap()) return;
        import std.math : fabs;

        // One resolved interpolation: which NEW corner, from which OLD corners,
        // at which weights. Built in the same pass as `oldLoopOfNewLoop` so the
        // face/corner walk happens once.
        struct LoopBlend {
            size_t   newLoop;
            uint[4]  oldLoop;
            float[4] w;
            ubyte    n;
        }

        uint[]      oldLoopOfNewLoop;
        LoopBlend[] blends;
        size_t      newLoop = 0;
        oldLoopOfNewLoop.reserve(newFaces.length * 4);

        foreach (nfi, nf; newFaces) {
            foreach (v; nf) {
                const uint oldFi = (newLoop < srcFaceOfNewCorner.length)
                                 ? srcFaceOfNewCorner[newLoop] : ~0u;
                const(uint)[] of = (oldFi < oldFaces.length) ? oldFaces[oldFi] : null;
                uint copyFrom = ~0u;
                if (of !is null) {
                    const uint c = cornerOfVertexInFace(of, v);
                    if (c != ~0u) {
                        copyFrom = oldFaceLoopIndex(oldFaceLoop, oldFi, c);
                    } else if (auto b = v in blendOfNewVertex) {
                        LoopBlend lb;
                        lb.newLoop = newLoop;
                        bool ok = !b.overflow && b.n > 0;
                        foreach (i; 0 .. b.n) {
                            const uint sc = cornerOfVertexInFace(of, b.src[i]);
                            if (sc == ~0u) { ok = false; break; }
                            lb.oldLoop[i] = oldFaceLoopIndex(oldFaceLoop, oldFi, sc);
                            lb.w[i]       = b.w[i];
                            if (lb.oldLoop[i] == ~0u) { ok = false; break; }
                        }
                        if (ok) { lb.n = b.n; blends ~= lb; }
                    }
                }
                oldLoopOfNewLoop ~= copyFrom;
                ++newLoop;
            }
        }

        // The funnel REPLACES each map's `data`, and the blend pass reads its
        // sources in the OLD corner space — so snapshot first.
        float[][] oldData;
        oldData.reserve(meshMaps.length);
        foreach (ref m; meshMaps)
            oldData ~= (m.domain == MapDomain.PolyVertex) ? m.data : null;

        remapPolyVertexMaps(oldLoopOfNewLoop);

        size_t mi = 0;
        foreach (ref m; meshMaps) {
            const float[] src = oldData[mi++];
            if (m.domain != MapDomain.PolyVertex) continue;
            const ubyte dim = m.dim;
            foreach (ref b; blends) {
                const size_t dst = b.newLoop * dim;
                if (dst + dim > m.data.length) continue;  // defensive
                foreach (d; 0 .. dim) m.data[dst + d] = 0.0f;
                bool complete = true;
                foreach (i; 0 .. b.n) {
                    const size_t ob = cast(size_t)b.oldLoop[i] * dim;
                    if (ob + dim > src.length) { complete = false; break; }
                    foreach (d; 0 .. dim)
                        m.data[dst + d] += src[ob + d] * b.w[i];
                }
                if (!complete)
                    foreach (d; 0 .. dim) m.data[dst + d] = 0.0f;
            }

            // Mechanism (e) — GENERATED corners, last so they win over a copy
            // (see the doc comment). Plane laws only: a map that is not 2-D has
            // no polygon to inset and no second component to keep, so its
            // corners stay whatever the copy/blend passes left.
            if (dim != 2) continue;
            foreach (ref g; gens) {
                const size_t dst = g.newLoop * 2;
                if (dst + 2 > m.data.length) continue;              // defensive
                if (g.srcFace >= oldFaces.length) continue;
                const(uint)[] of = oldFaces[g.srcFace];
                const size_t N = of.length;
                if (N < 3 || g.srcCorner >= N) continue;
                const uint base = (g.srcFace < oldFaceLoop.length)
                                ? oldFaceLoop[g.srcFace] : ~0u;
                if (base == ~0u || (cast(size_t)base + N) * 2 > src.length) continue;
                float[2] uvAt(size_t k) {
                    const size_t o = (cast(size_t)base + k) * 2;
                    float[2] r;
                    r[0] = src[o]; r[1] = src[o + 1];
                    return r;
                }
                if (g.law == PolyVertexGen.Law.SweepU) {
                    m.data[dst]     = g.amount;
                    m.data[dst + 1] = uvAt(g.srcCorner)[1];
                    continue;
                }
                // InsetRing: offset every UV edge inward by `d` and take the
                // vertex at `srcCorner`. `d` is the kernel's geometric ratio
                // times THIS map's own perimeter — the measured
                // `inset * uvPerimeter / geomPerimeter`.
                float perim = 0.0f, area2 = 0.0f;
                foreach (k; 0 .. N) {
                    const float[2] p = uvAt(k), q = uvAt((k + 1) % N);
                    const float dx = q[0] - p[0], dy = q[1] - p[1];
                    perim += sqrt(dx * dx + dy * dy);
                    area2 += p[0] * q[1] - q[0] * p[1];
                }
                const float d  = g.amount * perim;
                const float wd = (area2 >= 0.0f) ? 1.0f : -1.0f;  // polygon winding
                const float[2] P  = uvAt(g.srcCorner);
                const float[2] Pn = uvAt((g.srcCorner + 1) % N);
                const float[2] Pp = uvAt((g.srcCorner + N - 1) % N);
                float e1x = Pn[0] - P[0], e1y = Pn[1] - P[1];
                float e2x = Pp[0] - P[0], e2y = Pp[1] - P[1];
                const float l1 = sqrt(e1x * e1x + e1y * e1y);
                const float l2 = sqrt(e2x * e2x + e2y * e2y);
                if (l1 < 1e-9f || l2 < 1e-9f) continue;  // degenerate UV edge
                e1x /= l1; e1y /= l1; e2x /= l2; e2y /= l2;
                const float crs = e1x * e2y - e1y * e2x;   // sin of the corner angle
                if (fabs(crs) > 1e-6f) {
                    // Q = P + (d·w/sinθ)·(ê1 + ê2): the meet of the two offset
                    // edges. The SIGNED sine carries convexity, `w` the winding,
                    // so one expression covers convex and reflex corners in both
                    // windings. A needle-sharp UV corner sends 1/sinθ to
                    // infinity and would throw the ring corner across the map,
                    // so the factor is miter-LIMITED — the measured cases are
                    // right angles (1/sinθ == 1) and never approach it.
                    enum float kUvMiterLimit = 8.0f;
                    float inv = 1.0f / crs;
                    if (inv >  kUvMiterLimit) inv =  kUvMiterLimit;
                    if (inv < -kUvMiterLimit) inv = -kUvMiterLimit;
                    const float s = d * wd * inv;
                    m.data[dst]     = P[0] + s * (e1x + e2x);
                    m.data[dst + 1] = P[1] + s * (e1y + e2y);
                } else {
                    // Straight-through corner: the bisector is undefined, the
                    // offset is the edge's own inward normal.
                    m.data[dst]     = P[0] + d * wd * (-e1y);
                    m.data[dst + 1] = P[1] + d * wd * ( e1x);
                }
            }
        }
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

    // True iff every registered PolyVertex map's `data` is length-correct for
    // the CURRENT `faces` array — i.e. the corner reached by walking the faces
    // in order (`Σ|faces[0 .. fi]| + c`) really does address corner `c` of face
    // `fi` in every map.
    //
    // `loops`/`faceLoop` are NOT consulted: they are rebuilt only by
    // `buildLoops`, so mid-kernel (after `faces` has been rewritten but before
    // the tail rebuild) they describe the PREVIOUS corner space while the maps
    // still describe the one this predicate is asked about. Deriving the corner
    // total from `faces` itself is the question actually being asked.
    //
    // This is the precondition of the per-corner payload capture below and of
    // the delta replay's corner carry (`mesh_edit_delta`): both address corners
    // by that walk, and both must decline rather than guess when the mesh is
    // caught mid-rewrite (every DROP-set kernel spends most of its body there).
    // No PolyVertex map registered ⇒ vacuously true.
    bool polyVertexMapsInStepWithFaces() const {
        size_t corners = 0;
        foreach (fi; 0 .. faces.length) corners += faces[fi].length;
        foreach (ref m; meshMaps) {
            if (m.domain != MapDomain.PolyVertex) continue;
            if (m.data.length != corners * m.dim) return false;
        }
        return true;
    }

    // --- Per-corner payload for the edit tracker (task 0689) --------------
    // Record the per-corner (PolyVertex) values of the faces named by
    // `oldFaceIdx` — indices into the CURRENT `faces` — as a `MeshMapDelta`
    // entry in the open edit batch.
    //
    // WHY THIS EXISTS. A delta replay can RELOCATE the values of corners that
    // survive it (their values are still in the live map), but a face the
    // FORWARD op destroyed takes its corner values with it: on the way back,
    // `RemoveFaces⁻¹` re-inserts the face and there is nothing left in the mesh
    // to read its UV from. The only place that still holds those values is the
    // moment just before the kernel drops them — here. This is the whole
    // O(Δ) map channel: `Δ` corners, not the mesh's.
    //
    // PAIRING is by ADJACENCY: the caller records this IMMEDIATELY BEFORE the
    // face entry the values belong to (`recordRemoveFaces` / `recordReshapeFaces`),
    // and `mapArity` runs positionally parallel to that entry's `fIdx`. The
    // payload carries no face indices of its own, and since task 0703 that is a
    // pure de-duplication rather than a workaround: every face entry is now
    // recorded in the LIVE (pre-op) index space this capture reads in, so
    // `oldFaceIdx` and the following entry's `fIdx` are the same list. Before
    // 0703 two kernels (`dissolveVerticesByMask`, `removeEdgesByMask`) recorded
    // faces in a POST-op space, `oldFaceIdx` was in neither, and position was
    // the only thing all three agreed on — which is also how the wrong space
    // stayed invisible for as long as it did.
    //
    // Declines (records nothing, so the replay falls back to zero-filling those
    // corners) when there is no PolyVertex map, when the maps are not in step
    // with `faces` — see `polyVertexMapsInStepWithFaces` — or when `oldFaceIdx`
    // is not ascending (the corner-base walk below is a single ordered sweep;
    // all three callers filter `faces` front-to-back, so ascending is what they
    // produce).
    /// Task 0831: `in FaceIdx[]`, matching the entry it is paired with — the
    /// pairing is BY ADJACENCY and the two lists must be the same indices in
    /// the same space, so they must be the same type.
    void recordPolyVertexPayload(in FaceIdx[] oldFaceIdx) {
        if (editRecorder_ is null) return;
        if (oldFaceIdx.length == 0) return;
        if (!hasPolyVertexMap()) return;
        if (!polyVertexMapsInStepWithFaces()) return;

        ubyte[] dims;
        foreach (ref m; meshMaps)
            if (m.domain == MapDomain.PolyVertex) dims ~= m.dim;
        size_t stride = 0;
        foreach (d; dims) stride += d;
        if (stride == 0) return;

        // Corner base of each requested face, by ONE ordered sweep over `faces`
        // (no O(faces) prefix array: task 0680 established that a bulk removal's
        // record path is allocation-sensitive).
        uint[] arity;  arity.length  = oldFaceIdx.length;
        size_t[] base; base.length   = oldFaceIdx.length;
        size_t run = 0, k = 0, totalCorners = 0;
        foreach (fi; 0 .. faces.length) {
            while (k < oldFaceIdx.length && oldFaceIdx[k] == fi) {
                base[k]  = run;
                arity[k] = cast(uint)faces[fi].length;
                totalCorners += arity[k];
                ++k;
            }
            run += faces[fi].length;
        }
        if (k != oldFaceIdx.length) return;   // out of range or not ascending

        float[] vals;
        vals.length = totalCorners * stride;
        vals[] = 0.0f;
        size_t w = 0;
        foreach (i; 0 .. oldFaceIdx.length) {
            foreach (c; 0 .. arity[i]) {
                const size_t corner = base[i] + c;
                size_t off = 0;
                foreach (ref m; meshMaps) {
                    if (m.domain != MapDomain.PolyVertex) continue;
                    const size_t s = corner * m.dim;
                    if (s + m.dim <= m.data.length)
                        vals[w + off .. w + off + m.dim] = m.data[s .. s + m.dim];
                    off += m.dim;
                }
                w += stride;
            }
        }
        editRecorder_.recordPolyVertexValues(dims, arity, vals);
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


    // === S5 ==================================================================




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

    /// Compute the unit normal of face fi by NEWELL's method over the whole
    /// polygon (the summary line here used to say "using the first triangle
    /// (v0, v1, v2)", contradicting its own body two lines down — and that is
    /// the distinction the picking/snap divergence turns on, see CLAUDE.md's
    /// Picking Strategy). Returns (0,1,0) for degenerate or tiny faces.
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
    ///
    /// The count is the same one either arm below produces; only the way the
    /// corner→edge mapping is obtained differs (task 0694):
    ///
    ///   VALID loops — `loopEdge[li]` already IS "the edge of the corner that
    ///   dart `li` starts", filled by `buildLoops` from this same `edges[]`
    ///   through this same last-wins key table, and `loops.length` is exactly
    ///   Σ face arity. So one dart is one corner: tallying `++n[loopEdge[li]]`
    ///   over the darts visits every corner exactly once and lands on the same
    ///   edge index, with no hashing at all. `~0u` (buildLoops' missing-edge
    ///   sentinel) fails the bounds guard, matching the `in idx` miss below.
    ///
    ///   STALE loops — the hashed path, unchanged. It is the reason this
    ///   function exists (it answers off `faces[]` alone, mid-op, before any
    ///   rebuild has run), so it stays the fallback rather than being traded
    ///   away: `captureLooseGeometry` calls this at the TOP of a dissolve, and
    ///   the Topology Pen calls it between its own edits.
    ///
    /// `faceLoop.length == faces.length` is part of the gate, not decoration:
    /// `appendFaceRaw` grows `faces[]` with NO version bump by design, so the
    /// stamp alone would still read Valid while the darts no longer cover
    /// every face. That check is O(1) and rejects exactly that window.
    ///
    /// Measured on the perf lane's 99 856-face / 200 344-edge grid: the hashed
    /// arm costs ~12-17 ms per call (200 344 keyed inserts + 399 424 lookups)
    /// and was 47% of `dissolveVerticesByMask`; the dart arm is ~0.5 ms.
    int[] edgePolygonCounts() const {
        auto n = new int[](edges.length);
        if (edges.length == 0 || faces.length == 0) return n;
        if (loopsValid() && loopEdge.length == loops.length
                         && faceLoop.length == faces.length) {
            foreach (li; 0 .. loopEdge.length) {
                immutable uint e = loopEdge[li];
                if (e < n.length) ++n[e];
            }
            return n;
        }
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

    // SPACE (task 0649). `ms` is the layer's item transform, and every point
    // is carried THROUGH it BEFORE the min/max. The order is the finding, not
    // a detail: the reference takes the box of the transformed vertices, and
    // the box of transformed points is NOT the transform of the box —
    // measured 0.85 apart on a rotated stand (0648 D2). So a caller that
    // wants a world-space answer must hand the space in HERE; transforming
    // the returned point afterwards answers a different question.
    //
    // Defaulted to the identity, where every arm is byte-identical to the
    // pre-0649 body (the `isIdentity` early-out in `toWorldPoint`'s caller
    // below is not even needed — `applyAffine(identity, v) == v` exactly —
    // but the branch is kept so the common path does no matrix work at all).
    Vec3 selectionBBoxCenterVertices(ModelSpace ms = ModelSpace.init) const {
        bool any = hasAnySelectedVertices();
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        bool seen = false;
        foreach (i, v0; vertices) {
            if (any && !isVertexSelected(i)) continue;
            Vec3 v = ms.isIdentity ? v0 : ms.toWorldPoint(v0);
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

    /// `ms` — see `selectionBBoxCenterVertices` for why the space is applied
    /// per point rather than to the result.
    Vec3 selectionBBoxCenterEdges(ModelSpace ms = ModelSpace.init) const {
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
                Vec3 v = ms.isIdentity ? vertices[vi]
                                       : ms.toWorldPoint(vertices[vi]);
                if (v.x < mn.x) mn.x = v.x; if (v.x > mx.x) mx.x = v.x;
                if (v.y < mn.y) mn.y = v.y; if (v.y > mx.y) mx.y = v.y;
                if (v.z < mn.z) mn.z = v.z; if (v.z > mx.z) mx.z = v.z;
                seen = true;
            }
        }
        return seen ? (mn + mx) * 0.5f : Vec3(0, 0, 0);
    }

    /// `ms` — see `selectionBBoxCenterVertices` for why the space is applied
    /// per point rather than to the result.
    Vec3 selectionBBoxCenterFaces(ModelSpace ms = ModelSpace.init) const {
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
                Vec3 v = ms.isIdentity ? vertices[vi]
                                       : ms.toWorldPoint(vertices[vi]);
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
    /// `ms` — see `selectionBBoxCenterVertices` for why the space is applied
    /// per point rather than to the result.
    Vec3 selectionBorderBBoxCenterFaces(ModelSpace ms = ModelSpace.init) const {
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
        if (!any) return selectionBBoxCenterFaces(ms);
        Vec3 mn = Vec3(float.infinity, float.infinity, float.infinity);
        Vec3 mx = Vec3(-float.infinity, -float.infinity, -float.infinity);
        foreach (vi, on; onBorder) if (on) {
            Vec3 v = ms.isIdentity ? vertices[vi] : ms.toWorldPoint(vertices[vi]);
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
    /// Front-facing is decided by `math.frontFacingLocal` — the ONE home of
    /// that predicate since task 0832, carrying the reference editor's rule
    /// (the corner triangle at the ring's first vertex, culled strictly at
    /// `dot(N, v0 - eye) > 0`). Occlusion is tested by ray-casting
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
        import math : pointInPolygon2D, projectToWindowFull, projectionSpace, ModelSpace,
                      frontFacingLocal;
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
        // The plane normal is carried in DOUBLE (the facing dot moved out to
        // `math.frontFacingLocal`, which carries its own in double too).
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
            // FACING — task 0832. This used to be its own copy of the rule
            // (the plane of the first triangle, culled at `>= 0`); it is now
            // `math.frontFacingLocal`, the one home, and the rule it applies
            // is the reference's, adopted for parity. Read that function's
            // comment before changing anything here — in particular, snap is
            // the ONLY consumer of this mask, and the reference's snap gesture
            // was never measured, so applying the rule here is a named
            // ASSUMPTION rather than a measurement.
            if (!frontFacingLocal(vertices, face, localEye)) continue;
            // `fn` is now ONLY the ray-plane's plane for the depth gate in
            // pass 2 — it no longer decides facing, and the two are separate
            // questions: a face this predicate keeps can still have a
            // degenerate first-triangle plane (that is exactly the split-face
            // shape), which pass 2's `abs(denom) < 1e-9` guard already answers
            // by declining to occlude through it.
            double[3] fn = planeNormal(vertices[face[0]], vertices[face[1]],
                                       vertices[face[2]]);
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


    // Loop-slice ring walk + insertion kernel family (loopSliceRingEdges /
    // collectEdgeRing / insertEdgeLoops / insertEdgeLoopsMulti) + capShellCycles
    // — see source/mesh_ops/loop_slice.d (task 0417, 0407 §B.V2).
    // select.loop family (border predicates / selectLoopEdges / selectLoopVertices
    // / selectLoopFaces + the head-restart oracles) — see
    // source/mesh_ops/select_loop.d (task 0717, 0678 §2B-M3).
    mixin MeshSelectLoopOps;

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
    /// Must be called after any topology change (addFace, catmullClarkOsd,
    /// bevel, etc.).
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
    /// Always repopulates the undirected edgeKey → edge index `edgeIndexMap`
    /// AA alongside the loops family (task 0790 — the `rebuildEdgeIndexMap`
    /// opt-out this doc used to describe had zero callers from the day a
    /// faster path replaced its only caller, `subpatch_osd.OsdAccel.buildPreview`,
    /// which now skips `buildLoops` on the preview mesh entirely rather than
    /// calling it with the map suppressed).
    void buildLoops() {

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
        // its undirected edge index, rebuilding the AA `edgeIndexMap`
        // along the way. External callers (bevel, subpatch_osd's cage
        // reads, edgeIndex/edgeIndexByKey) need the AA, so this always
        // runs — task 0790 removed the CSR-adjacency / binary-search
        // opt-out that used to skip it (`rebuildEdgeIndexMap=false`);
        // its only caller was replaced same-day by a faster path that
        // skips `buildLoops` on the preview mesh entirely (see the
        // function doc comment above).
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
            // CSR vertex→dart adjacency: same count / prefix-sum / fill shape
            // as the edgeIndexMap build above, keyed by `loops[idx].vert`
            // instead of an edge's two endpoints, one entry per dart since
            // each dart has exactly one tail vertex. Built ONLY here (some
            // edge is same-direction), so the
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

        // Stamp validity at the current structVersion. The loops family and
        // edgeIndexMap are both fully rebuilt above, so both are always
        // Valid here (task 0790 removed the branch that could leave
        // edgeIndexMap `DeliberatelyEmpty` while loops read Valid — the only
        // remaining producer of `DeliberatelyEmpty` is `markDerivedEmpty()`,
        // which drops both states together).
        loopsStamp    = structVersion;
        loopsState_   = DerivedState.Valid;
        edgeMapStamp  = structVersion;
        edgeMapState_ = DerivedState.Valid;
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

    // The four bevel families. Until task 0717 the word "bevel" named one
    // module plus a thousand lines in the middle of THIS file, which is the
    // search trap audit 0678 §2B-M4 recorded; each family now has one home:
    //
    //   edge_bevel.d   bevelEdgesByMask + the valence-4 free-end cap parity
    //                  fields it owns (0407 §B.V2 — this is the old bevel.d)
    //   poly_bevel.d   bevelFacesByMask / insetFacesByMask / spikeFacesByMask
    //                  + their corner, normal and boundary-contour helpers
    //   bevel_fin.d    the two non-manifold fin-bundle spine kernels
    //                  bevelEdgesByMask hands a fin bundle over to
    //   bevel_vertex.d bevelVerticesByMask
    //
    // (the curve math they share — boundary Béziers, the fillet-rail law, the
    // two junction Gregory-ring evaluators — is plain functions in
    // source/mesh_ops/bevel_curves.d, not a mixin)
    mixin MeshEdgeBevelOps;
    mixin MeshPolyBevelOps;
    mixin MeshBevelFinOps;
    mixin MeshBevelVertexOps;

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
    //
    // Per-corner (UV) maps are CARRIED here — mechanism (c), task 0690.
    // `insertEdgePoint` splices the new corner into the MIDDLE of each incident
    // winding, so every corner after it renumbers; a tail grow cannot express
    // that, and with no relocate at all the tail `buildLoops` zeroes the map
    // WHOLE — a point added to one edge would cost the entire mesh its UV.
    // The relocate is done at THIS level, not inside `insertEdgePoint`, because
    // the plane-cut kernels call that primitive once per straddling edge in a
    // loop and then rebuild `faces` wholesale anyway (they are in the documented
    // drop set); paying an O(faces) capture per edge there would be pure cost.
    // -----------------------------------------------------------------------
    uint addEdgePoint(uint ei, float t) {
        if (ei >= edges.length)        return uint.max;
        if (t <= 0.0f || t >= 1.0f)   return uint.max;

        // Open the corner rewrite (task 0830). The capture — old windings + old
        // CSR offsets — is what the correspondence below resolves against, and
        // its own precondition ("the map, `faces` and `loops` all describe one
        // corner space") is the guard this site used to spell out by hand.
        const uint ea = edges[ei][0], eb = edges[ei][1];
        auto rw = beginCornerRewrite();
        const bool carryUv = rw.active();

        bool[] isCutVert; // local throwaway — not used outside this call
        uint vi = insertEdgePoint(ei, t, isCutVert);

        // `vi == ea || vi == eb` means the parameter snapped to an existing
        // endpoint: no vertex, no corner, nothing to relocate.
        if (carryUv && vi != ea && vi != eb) {
            // The new vertex is `lerp(a, b, t)` in POSITION, so its corner takes
            // the same weighted combination of the source face's corner VALUES —
            // the law frozen in tests/fixtures/uv_corner_transfer.json (0682),
            // resolved PER FACE, which is what keeps a UV seam across the split
            // edge a seam instead of averaging the two islands together.
            PolyVertexBlend pb;
            pb.add(ea, 1.0f - t);
            pb.add(eb, t);
            PolyVertexBlend[uint] blend;
            blend[vi] = pb;
            // The splice neither adds nor reorders faces, so each face's source
            // is itself.
            uint[] srcFaceOfNewFace;
            srcFaceOfNewFace.length = faces.length;
            foreach (fi; 0 .. faces.length) srcFaceOfNewFace[fi] = cast(uint)fi;
            declareCornerProvenance(
                rw.carriedPerFace(faces.range, srcFaceOfNewFace, blend));
        } else if (carryUv) {
            // The parameter snapped to an existing endpoint: `insertEdgePoint`
            // spliced nothing, so every corner keeps its slot AND its meaning.
            // This branch is not decoration — an OPEN rewrite that reaches
            // `buildLoops` without a declaration drops the plane by design
            // (task 0830), so the no-op path has to say it is a no-op.
            declareCornerProvenance(rw.unchanged());
        }

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

        // Stated loss (task 0830): the chord fragments carry no record of the
        // old face each came from. The LAW is known — it is the same edge-split
        // lerp Loop Slice carries — so this reason marks available work, not an
        // unmeasured behaviour.
        dropCornerProvenance(CornerDrop.ChordSplitNoSource);
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

    // ---------------------------------------------------------------------------
    // rebuildFacesWithChordSplits: keep-selection unittests (cut-keep-split-faces
    // -selected task) — the shared kernel now INHERITS each parent face's
    // Marks.Select bit onto every emitted slot (whole-copy AND both split
    // halves) instead of unconditionally clearing it. Asserted by GEOMETRY /
    // count, not fixed index — a split appends the second half right after the
    // first, shifting later face indices.
    // ---------------------------------------------------------------------------


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
// edgeKey
// ---------------------------------------------------------------------------

// Canonical edge key: always (min, max) packed into a ulong.
ulong edgeKey(uint a, uint b) {
    return a < b ? (cast(ulong)a << 32 | cast(ulong)b)
                 : (cast(ulong)b << 32 | cast(ulong)a);
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





// ===========================================================================
// Twin-graph invariant tests — cube control guard (R1) + non-manifold book.
//
// The cube-control test is the primary manifold byte-stability guard: no
// existing test asserted twin values or verticesAroundVertex multisets before
// this task.  The book test confirms treatment (A) — non-manifold spine loops
// get twin==~0u (boundary-like) — and that all ring walks terminate cleanly.
// ===========================================================================



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

        // OsdAccel.buildPreview extracts the subpatch-marked subset (which is
        // the whole cage when every face is marked, a slice otherwise),
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

// ---------------------------------------------------------------------------
// version (unittest) fixture helpers, module scope.
// ---------------------------------------------------------------------------
// Task 0717 (M5) moved the blocks that use these next to the kernels they
// pin, inside `struct Mesh`. The helpers stayed behind: a struct cannot host
// a free function, and changing a free function into a static member would
// have made that move an edit. Each says below which blocks it serves.

// The raw builder behind the five bevelFacesByMask blocks and the
// makePolygonFromVerts adjacency cases.
version (unittest) private Mesh buildRawMesh(Vec3[] verts, uint[][] faceList) {
    Mesh m;
    m.vertices = verts;
    m.faces    = faceList;
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}


















// ---------------------------------------------------------------------------
// GpuMesh  →  extracted to source/mesh_gpu.d (task 0425). Re-exported here so
// every `import mesh;` / `import mesh : GpuMesh;` call site resolves unchanged.
// ---------------------------------------------------------------------------
public import mesh_gpu;

// ---------------------------------------------------------------------------
// weldCoincidentVertices — reference fixture (task 0396, spatial-hash rewrite)
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

// computation (naive O(V²) all-pairs scan). Kept ONLY so the two blocks next

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


// The extracted tail (`applyVertexRemapAndRebuild`) deliberately gets no test
// of its own: it is `weldVerticesByMask`'s own body, unchanged, and the
// collapse/weld tests already in this file are its net. Verified by mutation —
// dropping the post-remap consecutive-duplicate strip, and dropping the
// head/tail wrap strip — both inside `applyVertexRemapAndRebuild` — each break
// `collapseFacesByMask` before any weld test is reached. (Cited by symbol, not
// by line: the two line numbers this note carried had already rotted.)

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

