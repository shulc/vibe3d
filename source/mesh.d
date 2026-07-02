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
    void resetSelection() {
        resizeVertexSelection();
        resizeEdgeSelection();
        resizeFaceSelection();
        // resizeFaceSelection only touches the bit array; resetSelection also
        // brings the per-face pick-order / subpatch / material arrays in sync
        // (e.g. after an import grew `faces`).
        faceSelectionOrder.length   = faces.length;
        resizeSubpatch();
        faceMaterial.length         = faces.length;
        facePart.length             = faces.length;
        clearVertexSelection();
        clearEdgeSelection();
        clearFaceSelection();
        clearSubpatch();
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
    /// is below `epsSq`. Verts outside the mask are not candidates for
    /// either side of a weld pair. Faces that collapse to fewer than 3
    /// unique verts are dropped (degenerate). Edge list rebuilt; selection
    /// arrays cleared. Returns the number of verts welded into another.
    ///
    /// Equivalent to `vert.merge range:fixed dist:eps keep:false` on
    /// the selected verts. epsSq=1e-12 + all-true mask matches the
    /// existing weldCoincidentVertices() behavior (used by edge bevel).
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
                if (d.x * d.x + d.y * d.y + d.z * d.z < epsSq)
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
                newSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
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

    size_t weldCoincidentVertices(double epsSq = 1e-12) {
        if (vertices.length < 2) return 0;
        int[] remap;
        remap.length = vertices.length;
        foreach (i; 0 .. vertices.length) remap[i] = cast(int)i;
        foreach (i; 0 .. vertices.length) {
            if (remap[i] != cast(int)i) continue;
            foreach (j; i + 1 .. vertices.length) {
                if (remap[j] != cast(int)j) continue;
                Vec3 d = vertices[i] - vertices[j];
                if (d.x * d.x + d.y * d.y + d.z * d.z < epsSq)
                    remap[j] = cast(int)i;
            }
        }
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
    size_t compactUnreferenced() {
        bool[] referenced;
        referenced.length = vertices.length;
        foreach (ref face; faces)
            foreach (vid; face)
                if (vid < referenced.length) referenced[vid] = true;
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
            keptSubpatch ~= (i < isSubpatch.length        ? isSubpatch[i]        : false);
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
                newSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
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
            newPolySubpatch  ~= (firstFi < cast(int)isSubpatch.length        ? isSubpatch[firstFi]        : false);
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
            keptSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
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
        import std.math : acos, sin;
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
        void accumInset(uint v, int fi, Vec3 d) {
            ulong k = (cast(ulong)v << 32) | cast(uint)fi;
            insetAccum.update(k, () => d, (ref Vec3 acc) { acc = acc + d; });
        }
        void recordClamp(uint v, int fi, float len) {
            ulong k = (cast(ulong)v << 32) | cast(uint)fi;
            insetClampLen.update(k, () => len, (ref float c) { if (len < c) c = len; });
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
        Vec3 boundaryEdgeDir(uint v, uint other, int fi, out float farLen) {
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
        bool capMiterInset(uint v, int fi, out Vec3 pos) {
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
                    Vec3 mp;
                    if (capMiterInset(v, fi, mp)) {
                        ulong k = (cast(ulong)v << 32) | cast(uint)fi;
                        insetPosOverride[k] = mp;
                        if (sharedOnly) sharedFaceAwareInset[k] = true;
                        // Direction is irrelevant (overridden); return a unit dir
                        // so accumInset stays well-formed.
                        return inwardDir(va, vb, fi);
                    }
                    // capMiter degenerate → fall through to perpendicular.
                } else {
                    float farLen;
                    Vec3 d = boundaryEdgeDir(v, other, fi, farLen);
                    if (d.length >= 1e-6f) {
                        // Clamp the inset so it stops at (never passes) the far
                        // vertex of this incident non-selected edge.
                        recordClamp(v, fi, farLen);
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
        foreach (k, acc; insetAccum) {
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
            import std.format : format;
            string wk = format("%u|%d|%d|%d", v,
                cast(long)(p.x * 1e5f + (p.x >= 0 ? 0.5f : -0.5f)),
                cast(long)(p.y * 1e5f + (p.y >= 0 ? 0.5f : -0.5f)),
                cast(long)(p.z * 1e5f + (p.z >= 0 ? 0.5f : -0.5f)));
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
                if (auto fp = v in alongFar) {
                    t = vertices[*fp] - vertices[v];
                    float farLen = t.length;
                    if (width > farLen) offLen = farLen;   // land at most on far vert
                } else if (auto op = v in freeEndOther) {
                    t = vertices[v] - vertices[*op];   // fallback: extruded tangent
                } else continue;
                if (t.length < 1e-6f) continue;
                t = normalize(t);
                freeEndAlongVert[v] = addVertex(vertices[v] + t * offLen);
            }
        }
        bool needsAlongAt(uint v) { return (v in needsAlong) !is null; }

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
        foreach (fi; firstBridge .. faces.length)
            setFaceSubpatch(fi, false);

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

    /// Vertex Extrude: additive, faceless. For each vertex selected in `mask`,
    /// spawns a duplicate vertex offset along the averaged face-normal (or
    /// (0,1,0) when the vertex has no incident faces) and connects
    /// original→duplicate with a new wire edge. Selection moves to the new
    /// vertices on return. Calls buildLoops (NOT rebuildEdges — wire edges must
    /// survive). Returns the number of new vertices added (0 on no-op).
    ///
    /// Ordering invariant: selected indices are gathered from `mask` BEFORE any
    /// addVertex / resize call that would grow or corrupt the arrays.
    size_t extrudeVerticesByMask(in bool[] mask, float offset)
    {
        if (mask.length != vertices.length) return 0;
        if (offset == 0.0f) return 0;

        // Snapshot selected indices before any mutation.
        uint[] sel;
        foreach (i; 0 .. mask.length)
            if (mask[i]) sel ~= cast(uint)i;
        if (sel.length == 0) return 0;

        uint[] newVerts;
        newVerts.reserve(sel.length);
        foreach (v; sel)
        {
            // Averaged vertex normal over incident faces.
            Vec3 dir = Vec3(0, 0, 0);
            foreach (fi; facesAroundVertex(v))
                dir = dir + faceNormal(cast(uint)fi);
            float len = dir.length;
            dir = (len > 1e-6f) ? dir * (1.0f / len) : Vec3(0, 1, 0);

            uint nv = addVertex(vertices[v] + dir * offset);
            addEdge(v, nv);
            newVerts ~= nv;
        }

        resizeVertexSelection();
        resizeEdgeSelection();
        buildLoops();

        // Move selection to the extruded (new) vertices.
        clearVertexSelection();
        foreach (nv; newVerts)
            selectVertex(cast(int)nv);

        return newVerts.length;
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
        foreach (fi; firstBridge .. faces.length)
            setFaceSubpatch(fi, false);

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
    /// Returns the number of new faces inserted.
    size_t radialArrayFaces(in bool[] mask, int count, char axis, Vec3 center,
                            float totalAngle, Vec3 extraShift, float weld) {
        import math : mulMV, pivotRotationMatrix;
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
            setFaceSubpatch(idx, (srcFi < isSubpatch.length ? isSubpatch[srcFi] : false));
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
                    keptSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
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
            setFaceSubpatch(idx, (srcFi < isSubpatch.length ? isSubpatch[srcFi] : false));
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
                    keptSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
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

    /// Mirror the faces marked true in `mask` across the plane defined
    /// by axis ∈ {'X','Y','Z'} passing through `center`. Verts are
    /// cloned and reflected (`v' = reflect(v, plane)`); when
    /// `flipNormals` is true the winding of each cloned face is
    /// reversed so the mirrored surface has outward-facing normals.
    /// When `weld > 0`, coincident verts (seam verts that lie on the
    /// mirror plane, plus any pre-existing coincidences) are welded
    /// via `weldCoincidentVertices(weld*weld)` and orphan verts are
    /// compacted.
    ///
    /// Selection ends on the newly created mirrored faces (plus any
    /// originals not in the mirror mask). Returns the number of new
    /// faces actually inserted; 0 = noop (empty mask).
    size_t mirrorFaces(in bool[] mask, char axis, Vec3 center, float weld, bool flipNormals) {
        if (mask.length != faces.length) return 0;
        if (axis != 'X' && axis != 'Y' && axis != 'Z') return 0;
        size_t toMirror = 0;
        foreach (b; mask) if (b) ++toMirror;
        if (toMirror == 0) return 0;

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
        // the new range without disturbing the originals.
        foreach (oldVid, newVid; vertMap) {
            Vec3 v = vertices[newVid];
            if      (axis == 'X') v.x = 2.0f * center.x - v.x;
            else if (axis == 'Y') v.y = 2.0f * center.y - v.y;
            else                  v.z = 2.0f * center.z - v.z;
            vertices[newVid] = v;
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
            setFaceSubpatch(newFi, (fi < isSubpatch.length ? isSubpatch[fi] : false));
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
            double epsSq = cast(double)weld * cast(double)weld;
            if (weldCoincidentVertices(epsSq) > 0) {
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
                    keptSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
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
        }

        buildLoops();
        commitChange(MeshEditScope.Geometry);
        return toClone.length;
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
            setFaceSubpatch(newFi, (fi < isSubpatch.length ? isSubpatch[fi] : false));
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
    /// Phase 5 (delta-path undo) is deferred: the drop+compact step makes the
    /// append-only recordAddFaces revert insufficient, so only snapshot undo
    /// (MeshFaceExtrudeEdit) is wired for Phases 1-4.
    size_t extrudeFacesByMask(in bool[] mask, float distance, bool smooth = false) {
        if (mask.length != faces.length) return 0;
        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0) return 0;
        if (distance == 0.0f) return 0;

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

        // Per-vertex offset table — FULLY built BEFORE the dedup clone loop.
        // The clone loop visits each vid only once (on first sight), so any
        // accumulation inside it would drop every face's contribution after
        // the first for shared/ridge verts.  We pre-build here to guarantee
        // the complete sum.
        //
        // Smooth (smooth=true): accumulate the unit normals of all selected
        // incident faces for each vid, then normalize.  Fallback chain:
        //   avg-normal degenerate → regionNormal → Vec3(0,1,0).
        // vibe3d-divergence: UNIFORM weighting (each face's unit normal
        // contributes equally).  Area- or angle-weighted averaging would be a
        // one-line change to the accumulation; deferred as a documented
        // divergence — the geometry-reference harness is absent from this
        // checkout so empirical capture is infeasible.
        //
        // Rigid (smooth=false, default): every vid gets regionNormal*distance,
        // byte-identical to the pre-refactor behaviour.
        Vec3[uint] vertOffset;
        if (smooth) {
            Vec3[uint] vNormSum;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                Vec3 fn = faceNormal(cast(uint)fi);
                foreach (vid; faces[fi]) {
                    auto p = vid in vNormSum;
                    if (p is null) vNormSum[vid] = fn;
                    else          *p = *p + fn;
                }
            }
            foreach (vid, nsum; vNormSum) {
                float nlen = sqrt(nsum.x*nsum.x + nsum.y*nsum.y + nsum.z*nsum.z);
                Vec3 dir = (nlen > 1e-6f) ? nsum * (1.0f / nlen) : regionNormal;
                vertOffset[vid] = dir * distance;
            }
        } else {
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                foreach (vid; faces[fi])
                    if (vid !in vertOffset)
                        vertOffset[vid] = regionNormal * distance;
            }
        }

        // Edge → (≤2 incident faces) adjacency, one pass.
        auto edgeFaces = buildEdgeFaces();

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

        // Clone each vertex used by a selected face (once per vertex).
        // Offset comes from the pre-built vertOffset table, not computed here.
        uint[uint] vertMap;
        foreach (fi; 0 .. faces.length) {
            if (!mask[fi]) continue;
            foreach (vid; faces[fi]) {
                if (vid !in vertMap)
                    vertMap[vid] = addVertex(vertices[vid] + vertOffset[vid]);
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
            foreach (k, vid; src) cloned[k] = vertMap[vid];
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
            uint cloneA = vertMap[a], cloneB = vertMap[b];
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
            newSub  ~= false;
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

    private static ulong edgeKeyOrdered(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32) | b : (cast(ulong)b << 32) | a;
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

    /// Per-face polygon inset: for each face flagged true in `mask`, shrink
    /// the face inward by `inset` units (perpendicular-offset meeting at each
    /// corner via `offsetMeet`) and bridge the original boundary to the new
    /// inner boundary with N ring quads. The original face slot is replaced
    /// by the inner face so its selection mark is preserved.
    ///
    /// `|inset| < 1e-6` is a whole-operation no-op (returns 0).
    /// Returns the number of faces processed (>0 on success, 0 on no-op).
    size_t insetFacesByMask(const bool[] mask, float inset) {
        import std.math : abs;
        if (abs(inset) < 1e-6f) return 0;
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
            // Newell face normal (robust to collinear leading triples).
            const Vec3 n = faceNormal(cast(uint)fi);
            // Add one inset vertex per corner.
            uint[] newVerts = new uint[](N);
            foreach (i; 0 .. N)
                newVerts[i] = addVertex(insetCorner(origPos, i, n, inset));
            // Replace the original face with the inner (inset) face.
            // The face slot index is unchanged, so faceMarks[fi] (select mark)
            // carries over to the inner face automatically.
            faces[fi] = newVerts.dup;
            // Emit N ring quads bridging original boundary to inner boundary.
            foreach (i; 0 .. N) {
                const int next = (i + 1) % N;
                addFace([origFaceVerts[i], origFaceVerts[next],
                         newVerts[next],   newVerts[i]]);
            }
            ++processed;
        }
        if (processed == 0) return 0;
        rebuildEdges();
        buildLoops();
        syncSelection();
        return processed;
    }

    /// Polygon bevel: for each selected face, inset each corner by `inset`
    /// AND displace the inset cap by `+faceNormal*shift` along the face normal,
    /// bridging the original boundary to the offset cap with N ring quads.
    /// Produces ONE slanted ring (not inset∘extrude, which would produce two rings).
    /// inset=0, shift>0 degenerates to a one-ring face-extrude along the normal.
    /// Returns 0 (no-op) when |inset|<1e-6 AND |shift|<1e-6.
    size_t bevelFacesByMask(const bool[] mask, float inset, float shift) {
        import std.math : abs;
        if (abs(inset) < 1e-6f && abs(shift) < 1e-6f) return 0;
        size_t processed = 0;
        const size_t nFaces = faces.length;
        foreach (fi; 0 .. nFaces) {
            if (fi >= mask.length || !mask[fi]) continue;
            const uint[] origFaceVerts = faces[fi].dup;
            const int    N             = cast(int)origFaceVerts.length;
            if (N < 3) continue;
            Vec3[] origPos = new Vec3[](N);
            foreach (i; 0 .. N) origPos[i] = vertices[origFaceVerts[i]];
            const Vec3 n = faceNormal(cast(uint)fi);
            uint[] newVerts = new uint[](N);
            foreach (i; 0 .. N)
                newVerts[i] = addVertex(insetCorner(origPos, i, n, inset) + n * shift);
            faces[fi] = newVerts.dup;
            foreach (i; 0 .. N) {
                const int next = (i + 1) % N;
                addFace([origFaceVerts[i], origFaceVerts[next],
                         newVerts[next],   newVerts[i]]);
            }
            ++processed;
        }
        if (processed == 0) return 0;
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

    /// Edge bevel (Candidate A — slide-along-adjacent-edge): replace each
    /// qualifying selected edge with a flat 4-vertex chamfer strip.
    ///
    /// v1 scope (face-disjoint): a selected edge is processed only when ALL
    /// hold: interior (exactly 2 incident faces); each endpoint valence-3;
    /// no other selected edge at either endpoint (endpoint-disjoint); none
    /// of its incident faces claimed by another selected edge (face-disjoint);
    /// and the two endpoints' third faces are distinct. Conflicting edges are
    /// silently skipped.
    ///
    /// Returns the count of edges actually processed (0 ⇒ no-op, all skipped).
    size_t bevelEdgesByMask(const bool[] mask, float width) {
        if (width < 1e-6f) return 0;
        if (mask.length != edges.length) return 0;

        // Edge→(≤2 faces) adjacency, one pass (same idiom as extrudeEdgesByMask).
        auto edgeFaces = buildEdgeFaces();

        // Per-endpoint: count of selected edges incident at that vertex.
        int[uint] selEndpt;
        foreach (i; 0 .. edges.length) {
            if (i < mask.length && mask[i]) {
                selEndpt.update(edges[i][0], () => 1, (ref int c) { ++c; });
                selEndpt.update(edges[i][1], () => 1, (ref int c) { ++c; });
            }
        }

        // Utility: count faces around vertex (for valence-3 guard).
        uint vertexFaceCount(uint vi) const {
            uint n = 0;
            foreach (_; facesAroundVertex(vi)) ++n;
            return n;
        }

        // Utility: find face ring successor of v in face fi.
        uint succInFace(uint fi, uint v) const {
            auto f = faces[fi];
            foreach (k; 0..f.length)
                if (f[k] == v) return f[(k+1)%f.length];
            return uint.max;
        }

        // Utility: find face ring predecessor of v in face fi.
        uint predInFace(uint fi, uint v) const {
            auto f = faces[fi];
            foreach (k; 0..f.length)
                if (f[k] == v) return f[(k + f.length - 1)%f.length];
            return uint.max;
        }

        // Utility: does face fi contain vertex v?
        bool faceHasVert(uint fi, uint v) const {
            foreach (w; faces[fi]) if (w == v) return true;
            return false;
        }

        // Collect qualified edges.
        struct QEdge {
            uint v0, v1;     // endpoints (v0 as-stored in edges[])
            uint fL, fR;     // fL traverses v1→v0; fR traverses v0→v1
            uint g0, g1;     // third face at v0, third face at v1
            uint ipLv0, ipRv0, ipLv1, ipRv1; // new corner vert indices (filled later)
        }
        QEdge[] qEdges;

        foreach (i; 0 .. edges.length) {
            if (!mask[i]) continue;
            uint v0 = edges[i][0], v1 = edges[i][1];

            // Interior edge (exactly 2 incident faces).
            auto fp = edgeKeyOrdered(v0, v1) in edgeFaces;
            if (fp is null) continue;
            int fa = (*fp)[0], fb = (*fp)[1];
            if (fa < 0 || fb < 0) continue;

            // Each endpoint valence-3.
            if (vertexFaceCount(v0) != 3) continue;
            if (vertexFaceCount(v1) != 3) continue;

            // Endpoint-disjoint: no other selected edge at either endpoint.
            { auto cp = v0 in selEndpt; if (cp is null || *cp != 1) continue; }
            { auto cp = v1 in selEndpt; if (cp is null || *cp != 1) continue; }

            // Determine fL (traverses v1→v0) and fR (traverses v0→v1).
            uint fL, fR;
            bool found = false;
            foreach (k; 0..faces[fa].length) {
                uint u = faces[fa][k], w = faces[fa][(k+1)%faces[fa].length];
                if (u == v1 && w == v0) { fL = fa; fR = fb; found = true; break; }
                if (u == v0 && w == v1) { fR = fa; fL = fb; found = true; break; }
            }
            if (!found) continue;

            // Third face at v0 (not fL, not fR, valence-3 so exactly one).
            uint g0 = uint.max;
            foreach (fi; facesAroundVertex(v0))
                if (fi != fL && fi != fR) { g0 = fi; break; }
            if (g0 == uint.max) continue;

            // Third face at v1 (not fL, not fR).
            uint g1 = uint.max;
            foreach (fi; facesAroundVertex(v1))
                if (fi != fL && fi != fR) { g1 = fi; break; }
            if (g1 == uint.max) continue;

            // Distinct third faces.
            if (g0 == g1) continue;

            qEdges ~= QEdge(v0, v1, fL, fR, g0, g1);
        }

        if (qEdges.length == 0) return 0;

        // Face-disjoint guard (greedy first-come-first-served).
        // An ok edge's four incident faces (fL, fR, g0, g1) must not be
        // claimed by any previously accepted ok edge.
        bool[] faceUsed = new bool[](faces.length);
        bool[] edgeOk   = new bool[](qEdges.length);
        foreach (qi; 0 .. qEdges.length) {
            auto q = qEdges[qi];
            if (faceUsed[q.fL] || faceUsed[q.fR] ||
                faceUsed[q.g0] || faceUsed[q.g1]) {
                edgeOk[qi] = false;
            } else {
                edgeOk[qi] = true;
                faceUsed[q.fL] = faceUsed[q.fR] =
                faceUsed[q.g0] = faceUsed[q.g1] = true;
            }
        }

        size_t processed = 0;
        foreach (qi; 0 .. qEdges.length) if (edgeOk[qi]) ++processed;
        if (processed == 0) return 0;

        // Add the four corner verts for each ok edge.
        // Candidate A: p[face][v] = v + width * normalize(w - v)
        //   where w is v's neighbor in `face` OTHER than the bevel-edge partner.
        foreach (qi; 0 .. qEdges.length) {
            if (!edgeOk[qi]) continue;
            auto ref q = qEdges[qi];
            uint v0 = q.v0, v1 = q.v1;

            // Neighbor of v0 in fL along the non-bevel edge (fL traverses v1→v0,
            // so the edge at v0 in fL is v0→succInFace(fL,v0) — that successor
            // is the non-bevel neighbor).
            // In fL (traverses v1→v0→w), the non-bevel neighbor of v0 is
            // succInFace(fL, v0) (the vert after v0 in fL's ring). In fR
            // (traverses ...→v0→v1→...), the vert after v0 is v1 (the bevel
            // partner), so the non-bevel neighbor is predInFace(fR, v0).
            uint wLv0 = succInFace(q.fL, v0);  // fL: v1→v0→wLv0
            uint wRv0 = predInFace(q.fR, v0);  // fR: wRv0→v0→v1

            uint wLv1 = predInFace(q.fL, v1);  // fL: wLv1→v1→v0
            uint wRv1 = succInFace(q.fR, v1);  // fR: v0→v1→wRv1

            Vec3 pLv0 = vertices[v0] + width * safeNormalize(vertices[wLv0] - vertices[v0]);
            Vec3 pRv0 = vertices[v0] + width * safeNormalize(vertices[wRv0] - vertices[v0]);
            Vec3 pLv1 = vertices[v1] + width * safeNormalize(vertices[wLv1] - vertices[v1]);
            Vec3 pRv1 = vertices[v1] + width * safeNormalize(vertices[wRv1] - vertices[v1]);

            q.ipLv0 = addVertex(pLv0);
            q.ipRv0 = addVertex(pRv0);
            q.ipLv1 = addVertex(pLv1);
            q.ipRv1 = addVertex(pRv1);
        }

        // Build vertex-substitution map: face_index → (old_vert → new_verts[]).
        // Each face can be touched by at most one ok edge (face-disjoint guard).
        struct VertSub { uint oldV; uint[] newVs; }
        VertSub[][uint] faceSubs;

        foreach (qi; 0 .. qEdges.length) {
            if (!edgeOk[qi]) continue;
            auto q = qEdges[qi];
            uint v0 = q.v0, v1 = q.v1;

            // fL: single replacement for both v0 and v1.
            faceSubs.require(q.fL) ~= VertSub(v0, [q.ipLv0]);
            faceSubs.require(q.fL) ~= VertSub(v1, [q.ipLv1]);

            // fR: single replacement for both v0 and v1.
            faceSubs.require(q.fR) ~= VertSub(v0, [q.ipRv0]);
            faceSubs.require(q.fR) ~= VertSub(v1, [q.ipRv1]);

            // g0: split-into-two at v0. Insertion order depends on predecessor.
            // If pred of v0 in g0 is in fL → insert [ipLv0, ipRv0]; else [ipRv0, ipLv0].
            {
                uint pred = predInFace(q.g0, v0);
                bool predInFL = faceHasVert(q.fL, pred);
                uint[] order = predInFL ? [q.ipLv0, q.ipRv0] : [q.ipRv0, q.ipLv0];
                faceSubs.require(q.g0) ~= VertSub(v0, order);
            }

            // g1: split-into-two at v1.
            {
                uint pred = predInFace(q.g1, v1);
                bool predInFL = faceHasVert(q.fL, pred);
                uint[] order = predInFL ? [q.ipLv1, q.ipRv1] : [q.ipRv1, q.ipLv1];
                faceSubs.require(q.g1) ~= VertSub(v1, order);
            }
        }

        // Apply substitutions per face, then collect chamfer faces.
        // Rebuild face arrays using the extrudeFacesByMask idiom.
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        bool[]   newSub;

        foreach (fi; 0 .. faces.length) {
            auto orig = faces[fi];
            auto subsP = cast(uint)fi in faceSubs;
            if (subsP is null) {
                // Face untouched by any ok edge — copy as-is.
                newFaces ~= orig.dup;
            } else {
                // Build a lookup: old vert → replacement list.
                uint[][uint] repl;
                foreach (s; *subsP) repl[s.oldV] = s.newVs;
                uint[] rebuilt;
                foreach (v; orig) {
                    auto rp = v in repl;
                    if (rp is null) rebuilt ~= v;
                    else           rebuilt ~= *rp;
                }
                newFaces ~= rebuilt;
            }
            newMat  ~= fi < faceMaterial.length       ? faceMaterial[fi]       : 0u;
            newPart ~= fi < facePart.length           ? facePart[fi]           : 0u;
            newOrd  ~= fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0;
            newSub  ~= isFaceSubpatch(fi);
        }

        // Emit one chamfer quad per ok edge.
        size_t chamferStart = newFaces.length;
        foreach (qi; 0 .. qEdges.length) {
            if (!edgeOk[qi]) continue;
            auto q = qEdges[qi];
            newFaces ~= [q.ipLv0, q.ipLv1, q.ipRv1, q.ipRv0];
            newMat   ~= 0u;
            newPart  ~= 0u;
            newOrd   ~= 0;
            newSub   ~= false;
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

        // New selection = chamfer faces; clear vertex + edge selections.
        faceSelectionOrderCounter = 0;
        foreach (fi; chamferStart .. faces.length)
            selectFace(cast(int)fi);
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        // Tail: rebuild topology + compact orphaned original endpoints.
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

    // -------------------------------------------------------------------------
    // Loop-slice ring walk + insertion
    // -------------------------------------------------------------------------

    /// Per-face record from a ring walk: (a,b) = entry edge dart (p-rail
    /// direction); (c,d) = exit edge in the quad's CCW winding; q-rail = d→c.
    /// fi = face index at collection time (stable — we only append vertices).
    private struct EdgeRingEntry {
        uint a, b;  // entry edge: p-rail direction a→b
        uint c, d;  // exit edge in CCW order (q-rail = lerp(d,c,t))
        uint fi;    // face index at collection time
    }

    /// Walk one side of the ring from startFace, following the exit edge of each
    /// quad until: the exit key equals seedKey (closed — sets closed=true), a
    /// boundary is hit, the face is not a quad, or a face is revisited.
    /// Does NOT include the initial seed edge itself in the entries.
    private EdgeRingEntry[] walkRingSide(uint seedEdge, uint startFace,
                                         out bool closed) const {
        EdgeRingEntry[] result;
        closed = false;
        if (startFace >= faces.length) return result;
        if (faces[startFace].length != 4) return result;

        ulong seedKey = edgeKeyOf(seedEdge);
        int j0 = findEdgeInFace(startFace, seedKey);
        if (j0 < 0) return result;

        uint curFi = startFace;
        int  curJ  = j0;
        bool[uint] vis;

        for (;;) {
            if (curFi in vis) break;
            const f = faces[curFi];
            if (f.length != 4) break;

            uint a = f[curJ],       b = f[(curJ+1)%4],
                 c = f[(curJ+2)%4], d = f[(curJ+3)%4];
            result ~= EdgeRingEntry(a, b, c, d, curFi);
            vis[curFi] = true;

            uint exitEi = edgeIndex(c, d);
            if (exitEi == ~0u) break;                       // no exit edge

            ulong exitKey = edgeKeyOf(exitEi);
            if (exitKey == seedKey) { closed = true; break; } // closed ring

            int nf = adjacentFaceThrough(exitEi, curFi);
            if (nf < 0) break;                              // open boundary
            if (faces[nf].length != 4) break;               // non-quad stop

            int j2 = findEdgeInFace(cast(uint)nf, exitKey);
            if (j2 < 0) break;

            curFi = cast(uint)nf;
            curJ  = j2;
        }
        return result;
    }

    /// Collect the ordered quad ring crossed by a loop insert at seedEdge.
    /// Each entry carries the ring-edge direction (p-rail a→b, q-rail d→c)
    /// and face index.  closed==true when the ring wraps (e.g. a cube belt).
    /// Returns an empty slice if no quad face is incident on seedEdge.
    EdgeRingEntry[] collectEdgeRing(uint seedEdge, out bool closed) const {
        closed = false;
        if (seedEdge >= edges.length) return [];

        uint[2] incFaces; uint nFaces = 0;
        foreach (fi; facesAroundEdge(seedEdge))
            if (nFaces < 2) incFaces[nFaces++] = fi;
        if (nFaces == 0) return [];
        // Both seed-incident faces must be quads.  If either is a non-quad the
        // seed edge would still receive a midpoint vertex while the non-quad
        // face stays unsplit → T-junction (non-manifold).  Return empty so the
        // caller treats the op as a no-op / error.
        foreach (i; 0 .. nFaces)
            if (faces[incFaces[i]].length != 4) return [];

        bool closedA;
        auto sideA = walkRingSide(seedEdge, incFaces[0], closedA);
        if (closedA) { closed = true; return sideA; }  // one pass hit closure

        if (nFaces == 1) return sideA;                 // boundary edge, open

        bool closedB;
        auto sideB = walkRingSide(seedEdge, incFaces[1], closedB);
        return sideA ~ sideB;
    }

    /// Insert `positions.length` parallel edge loops at parametric offsets
    /// along the quad ring crossing seedEdge.  Positions must be in (0,1);
    /// the call is a no-op (returns false) if the ring is empty or positions
    /// is empty.  Rebuilds edges + half-edge loops; clears all selection.
    bool insertEdgeLoops(uint seedEdge, const(float)[] positions) {
        if (positions.length == 0) return false;
        if (seedEdge >= edges.length) return false;

        bool closed;
        auto ring = collectEdgeRing(seedEdge, closed);
        if (ring.length == 0) return false;

        // Rail map: canonical edge key → (stored va direction, midpoint verts)
        struct Rail { uint va; uint[] mids; }
        Rail[]      rails;
        uint[ulong] railByKey;

        // Return (or create) the midpoint vertex list for directed edge va→vb.
        // Handles anti-parallel reuse via reversal.
        uint[] getMids(uint va, uint vb) {
            ulong k = edgeKey(va, vb);
            if (auto rp = k in railByKey) {
                if (rails[*rp].va == va) return rails[*rp].mids;
                // Anti-parallel: reversed copy.
                auto rev = rails[*rp].mids.dup;
                size_t i = 0, j = rev.length - 1;
                while (i < j) { uint t = rev[i]; rev[i] = rev[j]; rev[j] = t; ++i; --j; }
                return rev;
            }
            uint[] mids;
            Vec3 va3 = vertices[va], vb3 = vertices[vb];
            foreach (float t; positions)
                mids ~= addVertex(va3 + (vb3 - va3) * t);
            railByKey[k] = cast(uint)rails.length;
            rails ~= Rail(va, mids);
            return mids;
        }

        bool[uint]        ringSet;
        EdgeRingEntry[uint] ringByFi;
        foreach (ref e; ring) { ringSet[e.fi] = true; ringByFi[e.fi] = e; }

        uint[][] newFaces;
        newFaces.reserve(faces.length + ring.length * positions.length);

        foreach (uint fi; 0 .. cast(uint)faces.length) {
            if (fi !in ringSet) { newFaces ~= faces[fi].dup; continue; }

            auto e = ringByFi[fi];
            uint a = e.a, b = e.b, c = e.c, d = e.d;
            uint[] p = getMids(a, b);  // p-rail: midpoints on a→b
            uint[] q = getMids(d, c);  // q-rail: midpoints on d→c

            // First sub-quad: [a, p0, q0, d]
            newFaces ~= [a, p[0], q[0], d];
            // Middle sub-quads (N>1 loops only)
            foreach (k; 1 .. positions.length)
                newFaces ~= [p[k-1], p[k], q[k], q[k-1]];
            // Last sub-quad: [p_last, b, c, q_last]
            newFaces ~= [p[$-1], b, c, q[$-1]];
        }

        faces = newFaces;
        rebuildEdges();
        buildLoops();
        resetSelection();   // resizes + clears all selection; calls commitChange
        return true;
    }

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

        // --- 6. append face + rebuild ---
        addFace(idx);
        buildLoops();
        syncSelection();
        return cast(int)(faces.length - 1);
    }

    // Helper: true iff `a` and `b` contain the same multiset of vertex indices.
    // O(n²) but n is typically small (poly arities ≤ 64 in practice).
    private static bool makePolyVertexSetMatch_(const uint[] a, const uint[] b) {
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

    /// Emit N quads [A[i], A[(i+1)%N], B[(i+1)%N], B[i]] where B is already
    /// paired 1:1 with A (no heuristic — exact correspondence assumed).
    /// Returns N on success, 0 if lengths differ or loop is too short.
    /// Does NOT call buildLoops — the caller must do so after all mutations.
    size_t bridgeLoopsPaired(const(uint)[] loopA, const(uint)[] pairedB) {
        if (loopA.length != pairedB.length || loopA.length < 3) return 0;
        const N = loopA.length;
        foreach (i; 0 .. N)
            addFace([cast(uint)loopA[i], cast(uint)loopA[(i + 1) % N],
                     cast(uint)pairedB[(i + 1) % N], cast(uint)pairedB[i]]);
        return N;
    }

    /// Stitch two equal-length closed vertex loops into a ring of N quad faces.
    /// Returns N (faces added) on success, 0 if loops are unequal or too short.
    ///
    /// Pairing rule: anchor B at the vertex nearest A[0]; pick forward vs.
    /// reversed direction by minimum total paired Euclidean distance; `flip`
    /// overrides the auto choice.  Quads wound [A[i], A[(i+1)%N], P[(i+1)%N], P[i]].
    ///
    /// Does NOT call buildLoops() — the caller must do so after all mutations.
    ///
    /// No empty-selection fallback: bridge requires exactly two loops.
    /// Do NOT add a whole-mesh fallback here.
    size_t bridgeLoops(const(uint)[] loopA, const(uint)[] loopB, bool flip = false) {
        if (loopA.length != loopB.length || loopA.length < 3) return 0;
        const size_t N = loopA.length;

        // Step 1 — anchor: B-vertex nearest A[0].
        Vec3   pa0    = vertices[loopA[0]];
        size_t k      = 0;
        float  bestSq = float.max;
        foreach (i; 0 .. N) {
            Vec3  d  = vertices[loopB[i]] - pa0;
            float sq = d.x*d.x + d.y*d.y + d.z*d.z;
            if (sq < bestSq) { bestSq = sq; k = i; }
        }

        // Step 2 — pick direction by minimum total paired distance.
        float fwdSum = 0.0f, revSum = 0.0f;
        foreach (i; 0 .. N) {
            Vec3 ai   = vertices[loopA[i]];
            Vec3 bFwd = vertices[loopB[(k + i)     % N]];
            Vec3 bRev = vertices[loopB[(k + N - i) % N]];
            fwdSum += (bFwd - ai).length;
            revSum += (bRev - ai).length;
        }
        immutable bool useForward = (fwdSum <= revSum) != flip;

        // Step 3 — build pairing array P[0..N).
        uint[] P = new uint[](N);
        foreach (i; 0 .. N)
            P[i] = useForward ? cast(uint)loopB[(k + i)     % N]
                              : cast(uint)loopB[(k + N - i) % N];

        return bridgeLoopsPaired(loopA, P);
    }

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
        foreach (fi; 0 .. F0) {
            uint[] of = new uint[](faces[fi].length);
            foreach (k; 0 .. faces[fi].length)
                of[k] = off[faces[fi][k]];
            reverse(of);
            addFace(of);
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

    /// Sweep a vertex chain (profile) around a principal axis to form a
    /// surface of revolution.
    ///
    /// `profile`       — ordered vertex indices in this mesh.
    /// `profileClosed` — true: treat as a closed ring (M quads/step via
    ///                   `bridgeLoopsPaired`; profile.length >= 3 required);
    ///                   false: open strip (M-1 quads/step).
    /// `count`         — total profile copies including the original (>= 2).
    /// `axis`          — 'X', 'Y', or 'Z'.
    /// `center`        — rotation pivot point.
    /// `angle`         — total sweep angle in radians (nonzero).
    ///
    /// Closed sweep (|angle − 2π| < 1e-3 or angle >= 2π):
    ///   stepAngle = angle/count; last bridge reuses ring[0]'s original verts
    ///   (no seam duplicate — mirrors `radialArrayFaces` steps 1..count-1).
    ///
    /// Open arc (angle < 2π − 1e-3):
    ///   stepAngle = angle/(count-1); endpoints land exactly at 0 and `angle`.
    ///   Intentional divergence from `radialArrayFaces` (which excludes the
    ///   copy at the total angle); an arc sweep wants inclusive endpoints.
    ///
    /// Selection finalise: deselects pre-existing faces, selects swept faces,
    /// clears vertex and edge selection (mirrors `radialArrayFaces` :3807-3810).
    ///
    /// Winding: profile walk direction is arbitrary (vibe3d-divergence, v1);
    /// global in-vs-out orientation is unspecified. The uniform quad formula
    /// guarantees globally consistent winding per step. Pinning outward-vs-
    /// inward is deferred (doc/radial_sweep_plan.md Phase 4).
    ///
    /// Open-profile sweeps leave boundary loops at the profile endpoints;
    /// end-cap generation is deferred (doc/radial_sweep_plan.md Phase 4).
    ///
    /// Returns faces added (> 0) on success, 0 on guard failure or no-op.
    size_t revolveProfile(const(uint)[] profile, bool profileClosed,
                          int count, char axis, Vec3 center, float angle) {
        import math : mulMV, pivotRotationMatrix;
        import std.math : abs;

        // Guards.
        if (profile.length < 2) return 0;
        if (profileClosed && profile.length < 3) return 0;
        if (count < 2) return 0;
        if (axis != 'X' && axis != 'Y' && axis != 'Z') return 0;
        if (abs(angle) < 1e-6f) return 0;

        Vec3 axisVec;
        if      (axis == 'X') axisVec = Vec3(1, 0, 0);
        else if (axis == 'Y') axisVec = Vec3(0, 1, 0);
        else                  axisVec = Vec3(0, 0, 1);

        // Closed-sweep detection: |angle − 2π| < 1e-3 or angle >= 2π.
        immutable float tau         = 6.283185307f;   // 2π
        immutable bool  sweepClosed = abs(angle - tau) < 1e-3f || angle >= tau;
        immutable float stepAngle   = sweepClosed
            ? angle / cast(float)count
            : angle / cast(float)(count - 1);

        // Snapshot pre-mutation face count for selection finalise.
        const size_t origFaceCount = faces.length;

        // Build per-step rings.
        // ring[0] = existing profile verts (no copy);
        // ring[k] (k >= 1) = new rotated copies appended to vertices[].
        uint[][] rings;
        rings.length = count;
        rings[0] = profile.dup;

        foreach (step; 1 .. count) {
            float ang  = stepAngle * cast(float)step;
            auto  rotM = pivotRotationMatrix(center, axisVec, ang);
            uint[] ring;
            ring.length = profile.length;
            foreach (k, vid; profile) {
                Vec3 p  = vertices[vid];
                auto v4 = Vec4(p.x, p.y, p.z, 1.0f);
                auto r4 = mulMV(rotM, v4);
                ring[k] = addVertex(Vec3(r4.x, r4.y, r4.z));
            }
            rings[step] = ring;
        }

        // Bridge consecutive rings into quad faces.
        size_t facesAdded = 0;
        immutable int lastBridge = sweepClosed ? count - 1 : count - 2;
        foreach (i; 0 .. lastBridge + 1) {
            int           nextIdx = sweepClosed ? (i + 1) % count : i + 1;
            const(uint)[] ringA   = rings[i];
            const(uint)[] ringB   = rings[nextIdx];

            if (profileClosed) {
                // bridgeLoopsPaired: M quads with closed wrap [A[i],A[i+1],B[i+1],B[i]].
                facesAdded += bridgeLoopsPaired(ringA, ringB);
            } else {
                // Open strip: M-1 quads, no wrap; same winding as bridgeLoopsPaired.
                const size_t M = profile.length;
                foreach (j; 0 .. M - 1) {
                    addFace([ringA[j], ringA[j + 1], ringB[j + 1], ringB[j]]);
                    ++facesAdded;
                }
            }
        }

        if (facesAdded == 0) return 0;

        // Finalise: rebuild half-edge maps and grow selection arrays.
        buildLoops();
        syncSelection();

        // Deselect pre-existing faces; select only the newly swept faces.
        foreach (fi; 0 .. origFaceCount)
            deselectFace(cast(int)fi);
        faceSelectionOrderCounter = 0;
        foreach (fi; origFaceCount .. faces.length)
            selectFace(cast(int)fi);

        // Clear vertex and edge selection (mirrors radialArrayFaces :3807-3810).
        clearVertexSelection();
        clearEdgeSelection();

        return facesAdded;
    }

    // ---------------------------------------------------------------------------
    // Mesh hygiene kernels
    // ---------------------------------------------------------------------------

    /// Drop faces whose unordered vertex set equals an earlier face (duplicate
    /// faces). The first occurrence (lowest face index) is kept; all later
    /// duplicates are removed. Winding order is ignored — two faces with the same
    /// vertices in reversed order are considered duplicates. Returns the number of
    /// faces removed, or 0 if the mesh had no duplicate faces.
    size_t unifyFaces() {
        if (faces.length < 2) return 0;
        // TODO perf: use a hash-bucket (Set of sorted vertex keys) for O(F) instead of
        // O(F²) per-pair scan — fine at editor scale, expensive for large bulk imports.
        bool[] mask;
        mask.length = faces.length;
        foreach (i; 0 .. faces.length) {
            if (mask[i]) continue;  // already slated for removal
            foreach (j; i + 1 .. faces.length) {
                if (mask[j]) continue;
                if (makePolyVertexSetMatch_(faces[i][], faces[j][]))
                    mask[j] = true;
            }
        }
        bool anyMarked = false;
        foreach (b; mask) if (b) { anyMarked = true; break; }
        if (!anyMarked) return 0;
        return deleteFacesByMask(mask);
    }

    /// Collapse consecutive duplicate vertex indices within each face (including
    /// the wrap-around position), then drop any face that has fewer than 3 distinct
    /// vertex entries or a zero Newell normal magnitude (< 1e-6). The Newell test
    /// uses the raw cross-product-sum magnitude — NOT faceNormal(), which returns
    /// a unit vector and cannot distinguish zero-area from finite-area faces.
    ///
    /// If no face is changed or removed the function returns 0 WITHOUT calling
    /// commitChange — no spurious topology version bump on a clean mesh.
    /// Otherwise rebuilds edges/loops/selection and issues a Geometry commit.
    /// Returns: faces removed + faces rewritten (both count as affected).
    size_t cleanDegenerateFaces() {
        if (faces.length == 0) return 0;

        const bool remapUv = hasPolyVertexMap();
        const uint[] oldFaceLoop = remapUv ? captureFaceLoop() : null;
        uint[] oldLoopOfNewLoop;

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

        size_t removed = 0;
        size_t fixed   = 0;

        foreach (fi, ref face; faces) {
            // Collapse consecutive duplicate vertex indices (+ wrap-around dup).
            uint[] f;
            uint[] srcCorner;  // original corner index for each kept entry
            f.reserve(face.length);
            if (remapUv) srcCorner.reserve(face.length);
            foreach (k, vid; face) {
                if (f.length == 0 || f[$ - 1] != vid) {
                    f ~= vid;
                    if (remapUv) srcCorner ~= cast(uint)k;
                }
            }
            // Wrap-around dup: last vertex equals first.
            while (f.length >= 2 && f[$ - 1] == f[0]) {
                f = f[0 .. $ - 1];
                if (remapUv && srcCorner.length > 0)
                    srcCorner = srcCorner[0 .. $ - 1];
            }

            // Drop: fewer than 3 distinct vertex entries after dedup.
            if (f.length < 3) {
                ++removed;
                continue;
            }

            // Drop zero-area faces: raw Newell normal magnitude test
            // (identical to makePolygonFromVerts step 4 — NOT faceNormal()).
            {
                float nx = 0, ny = 0, nz = 0;
                foreach (i; 0 .. f.length) {
                    Vec3 a = vertices[f[i]];
                    Vec3 b = vertices[f[(i + 1) % f.length]];
                    nx += (a.y - b.y) * (a.z + b.z);
                    ny += (a.z - b.z) * (a.x + b.x);
                    nz += (a.x - b.x) * (a.y + b.y);
                }
                float len = sqrt(nx*nx + ny*ny + nz*nz);
                if (len < 1e-6f) {
                    ++removed;
                    continue;
                }
            }

            // Face is kept; count it as fixed if its arity changed.
            if (f.length != face.length) ++fixed;
            newFaces    ~= f;
            newSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
            newOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
            newMaterial ~= (fi < faceMaterial.length      ? faceMaterial[fi]      : 0u);
            newPart     ~= (fi < facePart.length          ? facePart[fi]          : 0u);
            if (remapUv)
                foreach (sc; srcCorner)
                    oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, sc);
        }

        // Early return: nothing changed — no commitChange, no version bump.
        if (removed == 0 && fixed == 0) return 0;

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
        return removed + fixed;
    }

    /// Sequential mesh hygiene sweep. Stage order ensures weld-created degenerate
    /// and duplicate faces are caught by later stages:
    ///   1. weldCoincidentVertices  (if mergeVerts)   — must run first
    ///   2. cleanDegenerateFaces    (if dropDegenerate)
    ///   3. unifyFaces              (if unify)
    ///   4. compactUnreferenced     (if removeOrphans — intermediate)
    ///   5. dissolveDegree2Verts    (if dissolve2Valent — opt-in, default OFF)
    ///   6. compactUnreferenced     (if removeOrphans — final)
    ///
    /// Note: cleanDegenerateFaces and unifyFaces call compactUnreferenced
    /// internally when they do work, so those stages imply orphan removal as a
    /// side effect when they fire.  removeOrphans:false only fully preserves
    /// floating vertices when none of the other active stages fires either.
    ///
    /// Returns per-stage counts. All-zero means nothing changed (true no-op;
    /// a nominal all-off run with a pre-existing orphan does NOT mutate).
    CleanupResult cleanupMesh(CleanupOptions o = CleanupOptions.init) {
        CleanupResult r;
        if (o.mergeVerts)      r.welded       = weldCoincidentVertices(o.weldEpsSq);
        if (o.dropDegenerate)  r.degenerate   = cleanDegenerateFaces();
        if (o.unify)           r.unified      = unifyFaces();
        if (o.removeOrphans)   r.orphans      = compactUnreferenced();
        if (o.dissolve2Valent) r.dissolved    = dissolveDegree2Verts();
        if (o.removeOrphans)   r.finalOrphans = compactUnreferenced();
        return r;
    }

    // -----------------------------------------------------------------------
    // Polygon decimation kernel
    // -----------------------------------------------------------------------

    /// Iterative edge-collapse decimator. Collapses edges greedily in order of
    /// increasing cost = length * (1 + curvature) until `targetFaces` alive
    /// faces remain or no valid collapse is left. Uses a lazy-deletion binary
    /// min-heap with per-vertex generation stamps; guards reject non-manifold,
    /// inverting, degenerate, and (when preserveBoundary) boundary collapses.
    /// Finalizes via weldVerticesByMask with an all-true mask. Returns the
    /// number of collapses applied (0 = no-op, caller must not commit).
    size_t reduceToTarget(size_t targetFaces, bool preserveBoundary) {
        import std.algorithm : sort;

        if (faces.length == 0 || targetFaces >= faces.length) return 0;

        immutable V = vertices.length;
        immutable F = faces.length;

        // Working positions (indexed by original vertex index).
        Vec3[] pos  = vertices.dup;

        // Union-find: rep[vi] = representative of vi's cluster.
        int[] rep; rep.length = V;
        foreach (i; 0 .. V) rep[i] = cast(int)i;

        bool[] vAlive; vAlive.length = V; vAlive[] = true;
        bool[] fAlive; fAlive.length = F; fAlive[] = true;
        uint[] gen;   gen.length   = V;   // generation stamps (all 0)

        // vf[vi] = incident alive face indices for representative vi.
        uint[][] vf; vf.length = V;
        foreach (fi; 0 .. F)
            foreach (c; faces[fi])
                if (c < V) vf[c] ~= cast(uint)fi;

        // ---- Nested helpers ----

        // Path-halving find with compression.
        int find(int x) {
            while (rep[x] != x) { rep[x] = rep[rep[x]]; x = rep[x]; }
            return x;
        }

        // Newell normal of alive face fi using working positions mapped via find().
        Vec3 faceNW(uint fi) {
            const uint[] f = faces[fi];
            if (f.length < 3) return Vec3(0, 1, 0);
            float nx = 0, ny = 0, nz = 0;
            foreach (i; 0 .. f.length) {
                Vec3 a = pos[find(cast(int)f[i])];
                Vec3 b = pos[find(cast(int)f[(i + 1) % f.length])];
                nx += (a.y - b.y) * (a.z + b.z);
                ny += (a.z - b.z) * (a.x + b.x);
                nz += (a.x - b.x) * (a.y + b.y);
            }
            float len = sqrt(nx*nx + ny*ny + nz*nz);
            return len > 1e-6f ? Vec3(nx/len, ny/len, nz/len) : Vec3(0, 1, 0);
        }

        // Newell normal from an explicit mapped corner list (indices into pos[]).
        Vec3 newellNW(const uint[] corners) {
            if (corners.length < 3) return Vec3(0, 1, 0);
            float nx = 0, ny = 0, nz = 0;
            foreach (i; 0 .. corners.length) {
                Vec3 a = pos[corners[i]];
                Vec3 b = pos[corners[(i + 1) % corners.length]];
                nx += (a.y - b.y) * (a.z + b.z);
                ny += (a.z - b.z) * (a.x + b.x);
                nz += (a.x - b.x) * (a.y + b.y);
            }
            float len = sqrt(nx*nx + ny*ny + nz*nz);
            return len > 1e-6f ? Vec3(nx/len, ny/len, nz/len) : Vec3(0, 1, 0);
        }

        // Newell area magnitude from a mapped corner list.
        float newellArea(const uint[] corners) {
            if (corners.length < 3) return 0;
            float nx = 0, ny = 0, nz = 0;
            foreach (i; 0 .. corners.length) {
                Vec3 a = pos[corners[i]];
                Vec3 b = pos[corners[(i + 1) % corners.length]];
                nx += (a.y - b.y) * (a.z + b.z);
                ny += (a.z - b.z) * (a.x + b.x);
                nz += (a.x - b.x) * (a.y + b.y);
            }
            return sqrt(nx*nx + ny*ny + nz*nz);
        }

        // mappedCorners: apply find() + v→u substitution + consecutive+wraparound dedup.
        // Mirrors weldVerticesByMask face-rewrite logic (mesh.d:543-547).
        uint[] mappedCorners(const uint[] faceCorners, uint u, uint v) {
            uint[] f;
            foreach (c; faceCorners) {
                uint r = cast(uint)find(cast(int)c);
                uint mapped = (r == v) ? u : r;
                if (f.length == 0 || f[$ - 1] != mapped) f ~= mapped;
            }
            if (f.length > 1 && f[$ - 1] == f[0]) f = f[0 .. $ - 1];
            return f;
        }

        // Count alive faces incident to both representative a and b,
        // excluding any face with fStamp[fi] == excludeStamp.
        // Used for edge-boundary and post-collapse manifold counting.
        int sharedFaceCount(uint a, uint b, bool[] excluded) {
            int cnt = 0;
            foreach (fi; vf[a]) {
                if (!fAlive[fi] || excluded[fi]) continue;
                foreach (c; faces[fi]) {
                    if (cast(uint)find(cast(int)c) == b) { ++cnt; break; }
                }
            }
            return cnt;
        }

        // Edge cost: length * (1 + curvature).  Boundary edge → curvature=0.
        float edgeCost(uint u, uint v) {
            Vec3 du = pos[u], dv = pos[v];
            float dx = du.x - dv.x, dy = du.y - dv.y, dz = du.z - dv.z;
            float length = sqrt(dx*dx + dy*dy + dz*dz);
            if (length < 1e-9f) return 0;

            // Find the (up to 2) alive faces shared by u and v.
            uint[2] sf; int nSf = 0;
            foreach (fi; vf[u]) {
                if (!fAlive[fi] || nSf >= 2) continue;
                foreach (c; faces[fi]) {
                    if (cast(uint)find(cast(int)c) == v) { sf[nSf++] = fi; break; }
                }
            }
            float curvature = 0;
            if (nSf == 2) {
                Vec3 nA = faceNW(sf[0]), nB = faceNW(sf[1]);
                float d = nA.x*nB.x + nA.y*nB.y + nA.z*nB.z;
                curvature = (1.0f - d) * 0.5f;
            }
            return length * (1.0f + curvature);
        }

        // Is edge (u,v) a boundary edge (fewer than 2 alive incident faces)?
        bool isEdgeBoundary(uint u, uint v) {
            int cnt = 0;
            foreach (fi; vf[u]) {
                if (!fAlive[fi]) continue;
                foreach (c; faces[fi]) {
                    if (cast(uint)find(cast(int)c) == v) { if (++cnt >= 2) return false; break; }
                }
            }
            return cnt < 2;
        }

        // Is vertex u a boundary vertex (any incident alive edge is boundary)?
        bool isVertexBoundary(uint u) {
            bool[uint] seen;
            foreach (fi; vf[u]) {
                if (!fAlive[fi]) continue;
                foreach (c; faces[fi]) {
                    uint w = cast(uint)find(cast(int)c);
                    if (w != u && !(w in seen)) {
                        seen[w] = true;
                        if (isEdgeBoundary(u, w)) return true;
                    }
                }
            }
            return false;
        }

        // ---- Min-heap ----
        struct HeapEntry { float cost; uint u, v, genU, genV; }
        HeapEntry[] heap;

        void heapPush(HeapEntry e) {
            heap ~= e;
            size_t i = heap.length - 1;
            while (i > 0) {
                size_t p = (i - 1) / 2;
                if (heap[i].cost < heap[p].cost) {
                    auto t = heap[i]; heap[i] = heap[p]; heap[p] = t; i = p;
                } else break;
            }
        }

        HeapEntry heapPop() {
            auto top = heap[0];
            heap[0] = heap[$ - 1];
            heap.length--;
            size_t i = 0, n = heap.length;
            while (true) {
                size_t l = 2*i+1, r = 2*i+2, s = i;
                if (l < n && heap[l].cost < heap[s].cost) s = l;
                if (r < n && heap[r].cost < heap[s].cost) s = r;
                if (s == i) break;
                auto t = heap[i]; heap[i] = heap[s]; heap[s] = t; i = s;
            }
            return top;
        }

        // ---- Build initial heap from mesh edges ----
        heap.reserve(edges.length);
        foreach (ei; 0 .. edges.length) {
            uint u = edges[ei][0], v = edges[ei][1];
            if (u >= V || v >= V) continue;
            heapPush(HeapEntry(edgeCost(u, v), u, v, gen[u], gen[v]));
        }

        // Per-face exclusion scratch buffer (avoids O(F) allocation per candidate).
        bool[] excluded; excluded.length = F;

        // ---- Main collapse loop ----
        size_t aliveFaces = F;
        size_t collapses  = 0;

        while (aliveFaces > targetFaces && heap.length > 0) {
            auto e = heapPop();
            uint u = e.u, v = e.v;

            // Validate gen stamps and alive status.
            if (e.genU != gen[u] || e.genV != gen[v]) continue;
            if (!vAlive[u] || !vAlive[v]) continue;
            if (cast(uint)find(cast(int)u) != u) continue;
            if (cast(uint)find(cast(int)v) != v) continue;

            // Verify edge still exists (at least one alive shared face).
            {
                bool ok = false;
                foreach (fi; vf[u]) {
                    if (!fAlive[fi]) continue;
                    foreach (c; faces[fi]) {
                        if (cast(uint)find(cast(int)c) == v) { ok = true; break; }
                    }
                    if (ok) break;
                }
                if (!ok) continue;
            }

            // ---- Guard 1: boundary ----
            if (preserveBoundary) {
                if (isEdgeBoundary(u, v)) continue;
                if (isVertexBoundary(u) || isVertexBoundary(v)) continue;
            }

            // ---- Collect affected face set (alive faces touching u or v) ----
            // Mark affected faces using the excluded[] scratch (reused, zeroed below).
            uint[] affFaces;
            foreach (fi; vf[u]) if (fAlive[fi]) { excluded[fi] = true; affFaces ~= fi; }
            foreach (fi; vf[v]) if (fAlive[fi] && !excluded[fi]) { excluded[fi] = true; affFaces ~= fi; }

            // Compute mappedCorners for each affected face; classify DROP vs SURVIVE.
            struct FaceSim { uint fi; uint[] mc; }
            FaceSim[] surv;
            size_t dropCnt = 0;
            bool rejected  = false;

            foreach (fi; affFaces) {
                auto mc = mappedCorners(faces[fi], u, v);
                if (mc.length < 3) {
                    ++dropCnt;
                } else {
                    // Guard 2a: no non-consecutive repeated vertex in mappedCorners.
                    bool[uint] seen2a;
                    foreach (vi; mc) {
                        if (vi in seen2a) { rejected = true; break; }
                        seen2a[vi] = true;
                    }
                    if (rejected) break;
                    surv ~= FaceSim(fi, mc);
                }
            }

            // Reset excluded[] for affected faces before any continue.
            scope(exit) { foreach (fi; affFaces) excluded[fi] = false; affFaces.length = 0; }

            if (rejected) continue;

            // Guard 2b: surviving mapped edges must not land on >2 alive faces.
            // Also detect duplicate surviving mapped corner sets (link violation).
            uint[][] canonSurv;
            foreach (ref fs; surv) {
                uint[] ca = fs.mc.dup; sort(ca);
                // Check for duplicate surviving corner set.
                foreach (ref cb; canonSurv) {
                    if (ca == cb) { rejected = true; break; }
                }
                if (rejected) break;
                canonSurv ~= ca;

                foreach (j; 0 .. fs.mc.length) {
                    uint a = fs.mc[j], b = fs.mc[(j + 1) % fs.mc.length];
                    // Count from surviving affected faces.
                    int fromSurv = 0;
                    foreach (ref fs2; surv) {
                        foreach (k; 0 .. fs2.mc.length) {
                            uint x = fs2.mc[k], y = fs2.mc[(k + 1) % fs2.mc.length];
                            if ((x==a && y==b) || (x==b && y==a)) { ++fromSurv; break; }
                        }
                    }
                    // Count from unaffected alive faces.
                    // If a==u or b==u: all faces with that vert are in affected → fromUnaffected=0.
                    int fromUnaffected = 0;
                    if (a != u && b != u) {
                        foreach (fi2; vf[a]) {
                            if (!fAlive[fi2] || excluded[fi2]) continue;
                            foreach (c; faces[fi2]) {
                                if (cast(uint)find(cast(int)c) == b) { ++fromUnaffected; break; }
                            }
                        }
                    }
                    if (fromSurv + fromUnaffected > 2) { rejected = true; break; }
                }
                if (rejected) break;
            }
            if (rejected) continue;

            // Guards 3 + 4: inversion + area, evaluated at the ACTUAL midpoint.
            // 1. Capture 'before' normals at current positions.
            // 2. Move u and v to midpoint (the real post-collapse location).
            // 3. Test 'after' normals and area against the midpoint geometry.
            // 4. Restore pos[u]/pos[v] on any rejection; keep midpoint on success.
            {
                Vec3 savedU = pos[u], savedV = pos[v];
                Vec3 midpt  = Vec3((savedU.x + savedV.x) * 0.5f,
                                   (savedU.y + savedV.y) * 0.5f,
                                   (savedU.z + savedV.z) * 0.5f);

                Vec3[] beforeNW;
                beforeNW.length = surv.length;
                foreach (i, ref fs; surv) beforeNW[i] = faceNW(fs.fi);

                pos[u] = midpt;
                pos[v] = midpt;  // v→u already mapped in fs.mc; coincide for weld

                foreach (i, ref fs; surv) {
                    Vec3 after = newellNW(fs.mc);
                    float dot = beforeNW[i].x*after.x + beforeNW[i].y*after.y + beforeNW[i].z*after.z;
                    if (dot < 0) { rejected = true; break; }
                    if (newellArea(fs.mc) < 1e-6f) { rejected = true; break; }
                }

                if (rejected) {
                    pos[u] = savedU;
                    pos[v] = savedV;
                    continue;
                }
                // pos[u] == pos[v] == midpt; fall through to apply.
            }

            // ---- Apply collapse: u = survivor, v = dead ----
            // pos[u] and pos[v] are already the midpoint (set in the guard block).

            rep[v]    = u;
            vAlive[v] = false;
            gen[u]++;          // invalidate stale heap entries for u

            // Mark DROP faces dead; count face reduction.
            foreach (fi; affFaces) {
                if (!fAlive[fi]) continue;
                auto mc = mappedCorners(faces[fi], u, v);
                if (mc.length < 3) { fAlive[fi] = false; }
            }
            aliveFaces -= dropCnt;

            // Merge v's face list into u's, deduplicate, remove dead faces.
            vf[u] ~= vf[v];
            vf[v].length = 0;
            {
                bool[uint] seen3;
                uint[] fresh;
                fresh.reserve(vf[u].length);
                foreach (fi; vf[u]) {
                    if (fi in seen3 || !fAlive[fi]) continue;
                    seen3[fi] = true;
                    fresh ~= fi;
                }
                vf[u] = fresh;
            }

            // Push fresh cost entries for u's new 1-ring.
            {
                bool[uint] neighbors;
                foreach (fi; vf[u]) {
                    if (!fAlive[fi]) continue;
                    foreach (c; faces[fi]) {
                        uint w = cast(uint)find(cast(int)c);
                        if (w != u && vAlive[w] && !(w in neighbors)) {
                            neighbors[w] = true;
                        }
                    }
                }
                foreach (w, _; neighbors)
                    heapPush(HeapEntry(edgeCost(u, w), u, w, gen[u], gen[w]));
            }

            ++collapses;
        }

        if (collapses == 0) return 0;

        // ---- Finalize: coincide all cluster members then weld ----
        foreach (i; 0 .. V) vertices[i] = pos[find(cast(int)i)];
        auto mask = new bool[](vertices.length);
        mask[] = true;
        weldVerticesByMask(mask, 1e-12);

        return collapses;
    }

    /// Cut the whole mesh with the infinite plane {x : dot(n, x-p) == 0}.
    ///
    /// Pass 1: for each straddling edge, insert one shared crossing vertex into
    /// every incident face's winding (one addVertex per edge, keyed on edge
    /// identity — same dedup convention as MeshSplitEdge; guarantees no T-junctions).
    /// On-plane existing vertices (|d| <= eps) are crossing points with no new vertex.
    ///
    /// Pass 2: for each face with exactly 2 non-adjacent cut points, split into
    /// two sub-faces along the chord. Adjacent-hit guard: when the two cut positions
    /// are consecutive in the winding (chord == existing edge), the split is skipped.
    ///
    /// Per-face attributes (faceMaterial, Subpatch bit, faceSelectionOrder) are
    /// copied to both sub-faces (mirrors weldVerticesByMask bookkeeping). faceLoop
    /// arrays are rebuilt wholesale by buildLoops in finalize.
    ///
    /// Returns the number of faces actually split; 0 = no effective cut.
    /// Caller owns snapshot/undo — this method does NOT capture a snapshot.
    size_t cutByPlane(Vec3 p, Vec3 n, float eps = 1e-5f) {
        if (vertices.length == 0 || faces.length == 0 || edges.length == 0)
            return 0;

        // Signed distances: d[v] = dot(n, v - p)
        float[] dv;
        dv.length = vertices.length;
        bool[] onPlane;
        onPlane.length = vertices.length;
        foreach (vi; 0 .. vertices.length) {
            Vec3 v = vertices[vi];
            dv[vi] = n.x * (v.x - p.x) + n.y * (v.y - p.y) + n.z * (v.z - p.z);
            onPlane[vi] = (dv[vi] >= -eps && dv[vi] <= eps);
        }

        // Pre-check: determine whether any face will actually be split.
        // Avoids touching the mesh (no addVertex calls) when the plane misses.
        // Simulates the post-insertion winding positions to test adjacency.
        {
            bool anyWillSplit = false;
            foreach (fi; 0 .. faces.length) {
                auto face = faces[fi];
                size_t insertsBefore = 0; // cumulative insertions tracking winding shifts
                size_t[] hitPos;
                foreach (k; 0 .. face.length) {
                    uint a = face[k];
                    uint b = face[(k + 1) % face.length];
                    if (onPlane[a])
                        hitPos ~= k + insertsBefore;
                    if (!onPlane[a] && !onPlane[b]) {
                        float da = dv[a], db = dv[b];
                        if ((da > 0 && db < 0) || (da < 0 && db > 0)) {
                            // straddle — new vert inserted after position k
                            insertsBefore++;
                            hitPos ~= k + insertsBefore;
                        }
                    }
                }
                if (hitPos.length != 2) continue;
                size_t i = hitPos[0], j = hitPos[1];
                size_t newLen = face.length + insertsBefore;
                bool adj = (j == i + 1) || (i == 0 && j == newLen - 1);
                if (!adj) { anyWillSplit = true; break; }
            }
            if (!anyWillSplit) return 0;
        }

        // Pass 1 — edge subdivide: for each straddling edge insert one crossing
        // vertex into every incident face winding (T-junction prevention).
        bool[] isCutVert;
        isCutVert.length = vertices.length;
        foreach (vi; 0 .. vertices.length)
            isCutVert[vi] = onPlane[vi];

        size_t origEdgeCount = edges.length;
        foreach (ei; 0 .. origEdgeCount) {
            uint a = edges[ei][0], b = edges[ei][1];
            if (a >= dv.length || b >= dv.length) continue;
            if (onPlane[a] || onPlane[b]) continue; // endpoint on-plane: skip new vert
            float da = dv[a], db = dv[b];
            if (!((da > 0 && db < 0) || (da < 0 && db > 0))) continue; // same side

            insertEdgePoint(cast(uint)ei, da / (da - db), isCutVert);
        }

        // Pass 2 + finalize: split all eligible faces (all-true mask = empty).
        return rebuildFacesWithChordSplits([], isCutVert);
    }

    // -----------------------------------------------------------------------
    // insertEdgePoint — factored from cutByPlane Pass-1.
    //
    // Adds a lerp vertex at parameter t along edge ei (t ∈ [0,1]: 0 = edges[ei][0],
    // 1 = edges[ei][1]) and splices it between the two endpoints in every face
    // winding that contains the pair.  Grows isCutVert as needed and marks the
    // new vertex.  Returns the new vertex index.
    //
    // Non-manifold edges (3+ incident faces) are out of scope for v1; the splice
    // scans all face windings and inserts into every face that contains the pair.
    // -----------------------------------------------------------------------
    private uint insertEdgePoint(uint ei, float t, ref bool[] isCutVert) {
        uint a = edges[ei][0], b = edges[ei][1];
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
        newFacesArr.reserve(origFaceCount + origFaceCount / 2);

        size_t nSplit = 0;
        foreach (fi; 0 .. origFaceCount) {
            uint[] face = faces[fi];
            bool  sub = isFaceSubpatch(fi);
            int   ord = (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
            uint  mat = (fi < faceMaterial.length       ? faceMaterial[fi]       : 0u);
            uint  prt = (fi < facePart.length           ? facePart[fi]           : 0u);

            // Faces not in the mask are copied whole (never split).
            bool eligible = (splitFaceMask.length == 0) ||
                            (fi < splitFaceMask.length && splitFaceMask[fi]);
            if (!eligible) {
                newFacesArr ~= face.dup;
                newSubpatch ~= sub;
                newOrder    ~= ord;
                newMaterial ~= mat;
                newPart     ~= prt;
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
                continue;
            }

            // f1 (replaces parent slot)
            newFacesArr ~= f1;
            newSubpatch ~= sub;
            newOrder    ~= ord;
            newMaterial ~= mat;
            newPart     ~= prt;

            // f2 (appended slot) — BOTH halves carry parent attrs.
            newFacesArr ~= f2;
            newSubpatch ~= sub;
            newOrder    ~= ord;
            newMaterial ~= mat;
            newPart     ~= prt;

            nSplit++;
        }

        if (nSplit == 0) return 0;

        // Apply new face arrays (mirrors weldVerticesByMask pattern).
        faces._store = newFacesArr;
        setFaceSubpatchFrom(newSubpatch);
        faceSelectionOrder = newOrder;
        faceMaterial       = newMaterial;
        facePart           = newPart;
        clearFaceSelectionResize();

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

    // -----------------------------------------------------------------------
    // edgeSlice — cut a strip from edge edgeA to edge edgeB.
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
    //
    // Returns the number of faces split; 0 = no-op (dead-end / same edge / OOB).
    // Caller owns snapshot/undo — this method does NOT capture a snapshot.
    //
    // Non-manifold meshes (edges shared by 3+ faces) are out of scope for v1.
    // -----------------------------------------------------------------------
    size_t edgeSlice(uint edgeA, uint edgeB,
                     float tA = 0.5f, float tB = 0.5f, float eps = 1e-5f)
    {
        if (vertices.length == 0 || faces.length == 0 || edges.length == 0)
            return 0;
        if (edgeA >= edges.length || edgeB >= edges.length) return 0;
        if (edgeA == edgeB) return 0;

        // Clamp t-params so cut points are always interior to the edge.
        if (tA < eps)          tA = eps;
        if (tA > 1.0f - eps)   tA = 1.0f - eps;
        if (tB < eps)          tB = eps;
        if (tB > 1.0f - eps)   tB = 1.0f - eps;

        // Collect faces incident to each edge (1-2 faces on a manifold mesh).
        uint[] facesAArr, facesBArr;
        foreach (f; facesAroundEdge(edgeA)) facesAArr ~= f;
        foreach (f; facesAroundEdge(edgeB)) facesBArr ~= f;
        if (facesAArr.length == 0) return 0;

        // Sort ascending for deterministic lowest-index preference.
        import std.algorithm : sort;
        sort(facesAArr);
        sort(facesBArr);

        // Fast-lookup set for facesB.
        bool[uint] facesBSet;
        foreach (f; facesBArr) facesBSet[f] = true;

        uint[] pathFaces;
        uint[] interiorEdges;

        // Case (a): edgeA and edgeB already share a face → single split.
        uint sharedFace = ~0u;
        foreach (f; facesAArr) {
            if (f in facesBSet) { sharedFace = f; break; }
        }

        if (sharedFace != ~0u) {
            pathFaces     = [sharedFace];
            interiorEdges = [];
        } else {
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

            if (goal == ~0u) return 0; // no path (disconnected or boundary blocks)

            // Reconstruct ordered face path by walking parentFace back to a root.
            uint cur = goal;
            while (cur in parentFace) {
                interiorEdges = [parentEdge[cur]] ~ interiorEdges;
                pathFaces     = [parentFace[cur]] ~ pathFaces;
                cur = parentFace[cur];
            }
            pathFaces ~= [goal];
        }

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
        // face count (faces.length) is stable across Pass-1.
        bool[] isCutVert;
        isCutVert.length = vertices.length;
        foreach (i, ei; cutEdges)
            insertEdgePoint(ei, cutT[i], isCutVert);

        // --- Pass 2: split only the path faces ---
        size_t origFaceCount = faces.length; // stable across Pass-1
        bool[] splitMask;
        splitMask.length = origFaceCount;
        foreach (f; pathFaces)
            if (f < origFaceCount) splitMask[f] = true;

        return rebuildFacesWithChordSplits(splitMask, isCutVert);
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
        if (va >= vertLoop.length || vertLoop[va] == ~0u) return;
        // Walk darts from va; find the one whose next vertex is vb.
        foreach (li; VertexDartRange(loops, vertLoop[va])) {
            if (loops[loops[li].next].vert == vb) {
                _faces[_count++] = loops[li].face;
                uint twin = loops[li].twin;
                if (twin != ~0u)
                    _faces[_count++] = loops[twin].face;
                break;
            }
        }
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
    void rebuildIfStale(ref const Mesh source, int d,
                         const(GpuFanOutTargets)* targets = null) {
        lastRefreshFannedOut    = false;
        lastRefreshSkipNonFace  = false;
        const srcAddr = cast(size_t)&source;
        if (sourceMeshAddr == srcAddr
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

unittest { // insetFacesByMask: single flat quad — no-op guard + inner corners at ±0.4
    import std.math : abs;
    // 1×1 quad at y=0, corners (±0.5, 0, ±0.5), winding [0,1,2,3].
    Mesh m;
    m.vertices = [
        Vec3(-0.5f, 0f, -0.5f), // 0
        Vec3( 0.5f, 0f, -0.5f), // 1
        Vec3( 0.5f, 0f,  0.5f), // 2
        Vec3(-0.5f, 0f,  0.5f), // 3
    ];
    m.addFace([0, 1, 2, 3]);
    m.buildLoops();

    // inset=0 must be a no-op (no-op guard).
    bool[] allOne = [true];
    assert(m.insetFacesByMask(allOne, 0.0f) == 0, "inset=0 must return 0");
    assert(m.vertices.length == 4, "no-op must not add verts");
    assert(m.faces.length    == 1, "no-op must not add faces");

    // inset=0.1: 4 new verts, 4 ring quads + 1 inner face = 5 faces total.
    assert(m.insetFacesByMask(allOne, 0.1f) == 1, "inset=0.1 must process 1 face");
    assert(m.vertices.length == 8, "expected 8 verts after single-face inset");
    assert(m.faces.length    == 5, "expected 5 faces (1 inner + 4 ring quads)");

    // Inner corners must be at (±0.4, 0, ±0.4) — NOT ±0.6 (which would be outset).
    bool hasVert(float x, float z) {
        foreach (v; m.vertices)
            if (abs(v.x - x) < 1e-4f && abs(v.z - z) < 1e-4f) return true;
        return false;
    }
    assert(hasVert(-0.4f, -0.4f), "inner corner (-0.4,0,-0.4) missing");
    assert(hasVert( 0.4f, -0.4f), "inner corner ( 0.4,0,-0.4) missing");
    assert(hasVert( 0.4f,  0.4f), "inner corner ( 0.4,0, 0.4) missing");
    assert(hasVert(-0.4f,  0.4f), "inner corner (-0.4,0, 0.4) missing");
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

unittest { // bridgeLoops: two parallel square rings → 4 quads, no new verts
    // Two coaxial unit squares: A at z=0, B at z=1, both CCW.
    // A: 0(0,0,0), 1(1,0,0), 2(1,1,0), 3(0,1,0)
    // B: 4(0,0,1), 5(1,0,1), 6(1,1,1), 7(0,1,1)
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    assert(m.vertices.length == 8);
    assert(m.faces.length == 0);

    size_t added = m.bridgeLoops([0u,1u,2u,3u], [4u,5u,6u,7u]);
    assert(added == 4, "expected 4 quads");
    assert(m.faces.length == 4, "face count");
    assert(m.vertices.length == 8, "no new verts");

    // All faces must be quads.
    foreach (f; m.faces) assert(f.length == 4, "all quads");

    // Every new face's vertices are within the original 8.
    foreach (f; m.faces)
        foreach (vi; f) assert(vi < 8, "vertex index in range");
}

unittest { // bridgeLoops: mismatch rejection + too-short rejection
    Mesh m;
    foreach (i; 0 .. 8) m.addVertex(Vec3(cast(float)i, 0, 0));

    // Unequal lengths → 0 faces added.
    size_t r1 = m.bridgeLoops([0u,1u,2u,3u], [4u,5u,6u]);
    assert(r1 == 0, "unequal length must be rejected");
    assert(m.faces.length == 0, "no faces added on mismatch");

    // Length 2 → too short → 0.
    size_t r2 = m.bridgeLoops([0u,1u], [4u,5u]);
    assert(r2 == 0, "length<3 must be rejected");
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
// GpuMesh
// ---------------------------------------------------------------------------

struct GpuMesh {
    GLuint faceVao, faceVbo;
    GLuint edgeVao, edgeVbo;
    GLuint vertVao, vertVbo;   // vertex points
    int    faceVertCount;
    int    edgeVertCount;
    int    vertCount;
    int[]  faceTriStart;   // first vertex index in faceVbo for each face
    int[]  faceTriCount;   // vertex count for each face
    // When true the main loop owns GPU uploads (because a subpatch preview
    // is currently displayed). Tool-side cage uploads become no-ops that
    // only bump the mesh's mutation version so the preview is rebuilt.
    bool   suppressCageUpload;
    // Maps each VBO line-segment to a source (cage) edge index when a
    // subpatch preview was uploaded. Empty for cage uploads, in which case
    // drawEdges assumes VBO segment i == cage edge i.
    uint[] edgeOriginGpu;
    // Maps each VBO face (position in faceTriStart/Count) to its cage face
    // index. Populated for subpatch uploads; empty in cage mode.
    uint[] faceOriginGpu;
    // Maps each vertex VBO entry to a source (cage) vertex index. In cage
    // mode VBO index == cage vertex index. In subpatch mode entries with
    // `vertOrigin[vi] == uint.max` were skipped during upload, so this
    // map translates back. Used by gpu_select.d for vertex picking.
    uint[] vertOriginGpu;
    // Per-triangle-vertex source face index, parallel to faceVbo (one
    // uint per face-VBO vertex). All three corners of a face's triangle
    // fan get the same face index. Drives gpu_select.d's face-ID pass.
    GLuint faceIdVbo;
    // Material Groups (MG3): per-triangle-vertex material index, parallel
    // to faceVbo. All three corners of a face's triangle fan get
    // mesh.faceMaterial[fi] (with a defensive 0 fallback). The lit
    // shader binds this at attrib location 2 with `flat in uint` so the
    // provoking-vertex value applies to the whole triangle.
    GLuint matIdVbo;

    // Bumps on every VBO write (full upload, refreshPositions, partial
    // uploadSelectedVertices). Distinct from Mesh.mutationVersion: the
    // transform tools (Move / Rotate / Scale) mutate `mesh.vertices`
    // directly during drag WITHOUT bumping mutationVersion, on purpose
    // (symmetry pair-table / falloff caches must stay stable mid-drag,
    // see TransformTool.captureSymmetryForDrag). That leaves the picker
    // FBO cache stale w.r.t. the actual GPU buffers — gpu_select.d
    // keys on `uploadVersion` instead so it re-renders whenever the
    // VBO contents change, regardless of whether the structural mesh
    // version moved.
    ulong  uploadVersion;

    // P3: scratch buffers re-used across upload() calls. Pre-sized to
    // the exact final length via a counting pre-pass, then filled by
    // index write — kills the per-face / per-corner `~=` cascades
    // (was ~2.4 M float appends + 393 K uint appends on a 24 K cage
    // / depth-2 preview, dominated by literal-array allocations).
    private float[] scratchFaceData;
    private uint[]  scratchFaceIdData;
    private uint[]  scratchMatIdData;
    private float[] scratchEdgeData;
    private float[] scratchVertData;

    void init() {
        glGenVertexArrays(1, &faceVao); glGenBuffers(1, &faceVbo);
        glGenVertexArrays(1, &edgeVao); glGenBuffers(1, &edgeVbo);
        glGenVertexArrays(1, &vertVao); glGenBuffers(1, &vertVbo);
        glGenBuffers(1, &faceIdVbo);
        glGenBuffers(1, &matIdVbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &faceVao); glDeleteBuffers(1, &faceVbo);
        glDeleteVertexArrays(1, &edgeVao); glDeleteBuffers(1, &edgeVbo);
        glDeleteVertexArrays(1, &vertVao); glDeleteBuffers(1, &vertVbo);
        glDeleteBuffers(1, &faceIdVbo);
        glDeleteBuffers(1, &matIdVbo);
    }

    // When `edgeOrigin`/`vertOrigin` are provided (same length as the mesh's
    // edges/vertices) entries equal to `uint.max` are skipped. This is how
    // the subpatch preview hides derived edges/points while still uploading
    // the full subdivided face surface. `faceOrigin` does not filter (every
    // preview face is rendered) but when supplied is cached in
    // `faceOriginGpu` so selection/hover can translate cage indices.
    void upload(ref const Mesh mesh,
                const uint[] edgeOrigin = null,
                const uint[] vertOrigin = null,
                const uint[] faceOrigin = null) {
        // Redirect tool-side cage refreshes: the GPU buffers currently hold
        // the preview, and main loop owns re-uploads. Bumping the mutation
        // version ensures the preview is rebuilt on the next frame against
        // the latest cage positions.
        if (suppressCageUpload && edgeOrigin.length == 0 && vertOrigin.length == 0) {
            ++(cast(Mesh*)&mesh).mutationVersion;
            return;
        }
        ++uploadVersion;
        enum FACE_STRIDE = 6;

        // P3 counting pre-pass: derive exact final sizes for the four
        // scratch buffers so the fill phase can index-write instead
        // of `~=`.
        size_t totalFaceCorners = 0;
        foreach (face; mesh.faces)
            if (face.length >= 3) totalFaceCorners += (face.length - 2) * 3;
        size_t totalEdgeKeep = 0;
        foreach (ei; 0 .. mesh.edges.length) {
            if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max) continue;
            ++totalEdgeKeep;
        }
        size_t totalVertKeep = 0;
        foreach (vi; 0 .. mesh.vertices.length) {
            if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max) continue;
            ++totalVertKeep;
        }

        // ── Faces — interleaved [pos(3)+normal(3)], flat shading. ──
        // P5: only call setLength when we need to grow on the float
        // buffers (D runtime's `_d_arraysetlength` was 7.88 % of CPU
        // after P3 — every call consults GC block metadata even when
        // capacity is sufficient). The 30-tab harness alternates
        // small (cage tear-down) and large (preview-on) uploads;
        // pinning the high-water capacity avoids the per-call
        // metadata round-trip. Writers index up to the exact required
        // length via the `*VertCount` fields below; GL upload sizes
        // are derived from those counts, not from `scratch*.length`.
        immutable size_t needFaceFloats = totalFaceCorners * FACE_STRIDE;
        if (scratchFaceData  .length < needFaceFloats)
            scratchFaceData  .length = needFaceFloats;
        if (scratchFaceIdData.length < totalFaceCorners)
            scratchFaceIdData.length = totalFaceCorners;
        if (scratchMatIdData.length < totalFaceCorners)
            scratchMatIdData.length = totalFaceCorners;
        faceTriStart.length = mesh.faces.length;
        faceTriCount.length = mesh.faces.length;
        faceOriginGpu    .length = 0;
        if (faceOrigin.length > 0) {
            faceOriginGpu.length = faceOrigin.length;
            faceOriginGpu[] = faceOrigin[];
        }
        {
            size_t fw = 0;
            foreach (fi, face; mesh.faces) {
                faceTriStart[fi] = cast(int)fw;
                if (face.length < 3) {
                    faceTriCount[fi] = 0;
                    continue;
                }
                Vec3 v0 = mesh.vertices[face[0]];
                Vec3 v1 = mesh.vertices[face[1]];
                Vec3 v2 = mesh.vertices[face[2]];
                float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
                float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
                float cx = ay*bz - az*by;
                float cy = az*bx - ax*bz;
                float cz = ax*by - ay*bx;
                float nlen = sqrt(cx*cx + cy*cy + cz*cz);
                float nx, ny, nz;
                if (nlen > 1e-6f) {
                    float inv = 1.0f / nlen;
                    nx = cx*inv; ny = cy*inv; nz = cz*inv;
                } else {
                    nx = 0; ny = 1; nz = 0;
                }
                immutable uint i0 = face[0];
                for (uint i = 1; i + 1 < face.length; i++) {
                    immutable uint ia = i0;
                    immutable uint ib = face[i];
                    immutable uint ic = face[i + 1];
                    Vec3 va = mesh.vertices[ia];
                    Vec3 vb = mesh.vertices[ib];
                    Vec3 vc = mesh.vertices[ic];
                    size_t k = fw * FACE_STRIDE;
                    scratchFaceData[k +  0] = va.x;
                    scratchFaceData[k +  1] = va.y;
                    scratchFaceData[k +  2] = va.z;
                    scratchFaceData[k +  3] = nx;
                    scratchFaceData[k +  4] = ny;
                    scratchFaceData[k +  5] = nz;
                    scratchFaceData[k +  6] = vb.x;
                    scratchFaceData[k +  7] = vb.y;
                    scratchFaceData[k +  8] = vb.z;
                    scratchFaceData[k +  9] = nx;
                    scratchFaceData[k + 10] = ny;
                    scratchFaceData[k + 11] = nz;
                    scratchFaceData[k + 12] = vc.x;
                    scratchFaceData[k + 13] = vc.y;
                    scratchFaceData[k + 14] = vc.z;
                    scratchFaceData[k + 15] = nx;
                    scratchFaceData[k + 16] = ny;
                    scratchFaceData[k + 17] = nz;
                    scratchFaceIdData[fw + 0] = cast(uint)fi;
                    scratchFaceIdData[fw + 1] = cast(uint)fi;
                    scratchFaceIdData[fw + 2] = cast(uint)fi;
                    // Material Groups (MG3): one matId per VBO vertex.
                    // Defaults to 0 (Default surface) for faces not yet
                    // assigned an entry in mesh.faceMaterial.
                    const uint mid = (fi < mesh.faceMaterial.length)
                        ? mesh.faceMaterial[fi] : 0u;
                    scratchMatIdData[fw + 0] = mid;
                    scratchMatIdData[fw + 1] = mid;
                    scratchMatIdData[fw + 2] = mid;
                    fw += 3;
                }
                faceTriCount[fi] = cast(int)(fw - faceTriStart[fi]);
            }
            faceVertCount = cast(int)fw;
        }
        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
        glBufferData(GL_ARRAY_BUFFER,
            cast(GLsizeiptr)(faceVertCount * FACE_STRIDE * float.sizeof),
            scratchFaceData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              FACE_STRIDE * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE,
                              FACE_STRIDE * float.sizeof,
                              cast(void*)(3 * float.sizeof));
        glEnableVertexAttribArray(1);

        // Parallel face-ID VBO. Always upload at least one sentinel
        // uint so the buffer is non-zero-sized even for empty meshes.
        glBindBuffer(GL_ARRAY_BUFFER, faceIdVbo);
        if (faceVertCount > 0) {
            glBufferData(GL_ARRAY_BUFFER,
                cast(GLsizeiptr)(faceVertCount * uint.sizeof),
                scratchFaceIdData.ptr, GL_DYNAMIC_DRAW);
        } else {
            uint zero = 0;
            glBufferData(GL_ARRAY_BUFFER, uint.sizeof, &zero, GL_DYNAMIC_DRAW);
        }

        // Material Groups (MG3): parallel matId VBO. Bound into the
        // faceVao at attrib location 2 with the integer pointer variant
        // so the lit shader reads it as `flat in uint aMatId`. Bind
        // happens here so the VAO state is captured alongside the
        // position + normal pointers.
        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, matIdVbo);
        if (faceVertCount > 0) {
            glBufferData(GL_ARRAY_BUFFER,
                cast(GLsizeiptr)(faceVertCount * uint.sizeof),
                scratchMatIdData.ptr, GL_DYNAMIC_DRAW);
        } else {
            uint zero = 0;
            glBufferData(GL_ARRAY_BUFFER, uint.sizeof, &zero, GL_DYNAMIC_DRAW);
        }
        glVertexAttribIPointer(2, 1, GL_UNSIGNED_INT,
                               cast(GLsizei)uint.sizeof, cast(void*)0);
        glEnableVertexAttribArray(2);
        glBindVertexArray(0);

        // ── Edges ─────────────────────────────────────────────────
        immutable size_t needEdgeFloats = totalEdgeKeep * 6;
        if (scratchEdgeData.length < needEdgeFloats)
            scratchEdgeData.length = needEdgeFloats;
        edgeOriginGpu  .length = (edgeOrigin.length > 0)
                                  ? totalEdgeKeep : 0;
        {
            size_t ew = 0;
            size_t oc = 0;
            foreach (ei, edge; mesh.edges) {
                if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max) continue;
                if (edgeOrigin.length > 0)
                    edgeOriginGpu[oc++] = edgeOrigin[ei];
                Vec3 a = mesh.vertices[edge[0]];
                Vec3 b = mesh.vertices[edge[1]];
                scratchEdgeData[ew + 0] = a.x;
                scratchEdgeData[ew + 1] = a.y;
                scratchEdgeData[ew + 2] = a.z;
                scratchEdgeData[ew + 3] = b.x;
                scratchEdgeData[ew + 4] = b.y;
                scratchEdgeData[ew + 5] = b.z;
                ew += 6;
            }
            edgeVertCount = cast(int)(ew / 3);
        }
        glBindVertexArray(edgeVao);
        glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
        glBufferData(GL_ARRAY_BUFFER,
            cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
            scratchEdgeData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        // ── Vertex points ─────────────────────────────────────────
        immutable size_t needVertFloats = totalVertKeep * 3;
        if (scratchVertData.length < needVertFloats)
            scratchVertData.length = needVertFloats;
        vertOriginGpu  .length = totalVertKeep;
        {
            size_t vw = 0;
            size_t oc = 0;
            foreach (vi, v; mesh.vertices) {
                if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max) continue;
                scratchVertData[vw + 0] = v.x;
                scratchVertData[vw + 1] = v.y;
                scratchVertData[vw + 2] = v.z;
                vertOriginGpu[oc++] = (vertOrigin.length > 0)
                                       ? vertOrigin[vi]
                                       : cast(uint)vi;
                vw += 3;
            }
            vertCount = cast(int)oc;
        }
        glBindVertexArray(vertVao);
        glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
        glBufferData(GL_ARRAY_BUFFER,
            cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
            scratchVertData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    /// Refresh vertex POSITIONS only — assumes the face / edge / vert
    /// VBO layouts (vertex count, face triangulation, faceTriStart
    /// offsets, faceIdVbo, edgeOriginGpu, …) all match what the last
    /// full `upload()` produced. Walks the mesh and writes new
    /// pos + (face) normal into the existing buffers via glMapBuffer
    /// — zero array `~=`, zero CPU-side reallocation, zero topology
    /// metadata churn.
    ///
    /// Used by the subpatch preview path: when topologyVersion is
    /// unchanged (mesh moved but didn't change topology), the
    /// SubpatchPreview re-evaluates OpenSubdiv's stencil table into
    /// preview.vertices, and these GPU buffers can be refreshed the
    /// same way instead of rebuilding faceData / edgeData / vertData
    /// arrays from scratch. On the user's 6 K-vert cage sphere drag
    /// (~393 K preview verts) this drops the `upload` hot path from
    /// ~16 % of CPU + ~12 % memmove + ~10 % GC expandArrayUsed to a
    /// single mapped-buffer write per VBO.
    void refreshPositions(ref const Mesh mesh,
                          const uint[] edgeOrigin = null,
                          const uint[] vertOrigin = null) {
        if (faceTriStart.length != mesh.faces.length)
            return;   // layout mismatch — caller should fall back to upload().
        ++uploadVersion;

        enum FACE_STRIDE = 6;

        // Face VBO: re-fan each face's triangles from its first three
        // verts. Normal recomputed per face (one cross + one sqrt).
        // faceTriStart already maps fi → first vertex in the VBO.
        //
        // Map with INVALIDATE_BUFFER_BIT — explicit driver-side orphan,
        // we'll fill the entire buffer below. The two skipped-face
        // patterns (face.length < 3) still write zero into those slots
        // implicitly: we don't touch them, but the orphaned allocation
        // starts as uninitialised garbage. That's tolerable because the
        // skipped faces have faceTriCount[fi] == 0, so drawFaces never
        // dereferences those bytes — they're not referenced by any draw
        // call.
        if (faceVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
            float* fp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(faceVertCount * FACE_STRIDE * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (fp) {
                foreach (fi, face; mesh.faces) {
                    if (face.length < 3) continue;
                    immutable uint i0 = face[0];
                    Vec3 v0 = mesh.vertices[i0];
                    Vec3 v1 = mesh.vertices[face[1]];
                    Vec3 v2 = mesh.vertices[face[2]];
                    float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
                    float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
                    float cx = ay*bz - az*by;
                    float cy = az*bx - ax*bz;
                    float cz = ax*by - ay*bx;
                    float nlen = sqrt(cx*cx + cy*cy + cz*cz);
                    float nx, ny, nz;
                    if (nlen > 1e-6f) { float inv = 1.0f/nlen; nx=cx*inv; ny=cy*inv; nz=cz*inv; }
                    else              { nx=0; ny=1; nz=0; }
                    int k = faceTriStart[fi] * FACE_STRIDE;
                    // Fan-triangulate around face[0]; write [pos, normal]
                    // per vertex with hand-rolled inner loop — avoids the
                    // `foreach (idx; [..])` literal-array GC alloc and the
                    // Vec3 operator-overload temporaries that dominated
                    // an earlier profile.
                    for (size_t i = 1; i + 1 < face.length; i++) {
                        immutable uint ia = i0;
                        immutable uint ib = face[i];
                        immutable uint ic = face[i+1];
                        Vec3 va = mesh.vertices[ia];
                        Vec3 vb = mesh.vertices[ib];
                        Vec3 vc = mesh.vertices[ic];
                        fp[k++] = va.x; fp[k++] = va.y; fp[k++] = va.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vb.x; fp[k++] = vb.y; fp[k++] = vb.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vc.x; fp[k++] = vc.y; fp[k++] = vc.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                    }
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Edge VBO: subpatch mode filters out edges whose
        // edgeOrigin[ei] == uint.max (derived edges that aren't shown).
        // VBO segment order matches the kept-edge walk in `upload`.
        if (edgeVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (ep) {
                int seg = 0;
                foreach (ei, edge; mesh.edges) {
                    if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max)
                        continue;
                    Vec3 a = mesh.vertices[edge[0]];
                    Vec3 b = mesh.vertices[edge[1]];
                    int k = seg * 6;
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Vertex VBO: subpatch mode filters out verts whose
        // vertOrigin[vi] == uint.max (edge mids / face centroids).
        // VBO order matches the kept-vert walk in `upload`.
        if (vertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
            float* vp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (vp) {
                int seg = 0;
                foreach (vi, v; mesh.vertices) {
                    if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max)
                        continue;
                    int k = seg * 3;
                    vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }
        glBindVertexArray(0);
    }

    /// Edge + vertex VBO position refresh — the subset of
    /// `refreshPositions` that skips the face VBO. Used by Phase 3b's
    /// OSD GPU fan-out path, which writes the face VBO itself; the
    /// edge / vert VBOs still come from CPU `mesh.vertices` because
    /// OSD's stencil output is per-limit-vert only and vibe3d's
    /// edge / vert VBOs need their own layout.
    void refreshNonFacePositions(ref const Mesh mesh,
                                  const uint[] edgeOrigin = null,
                                  const uint[] vertOrigin = null) {
        if (edgeVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (ep) {
                int seg = 0;
                foreach (ei, edge; mesh.edges) {
                    if (edgeOrigin.length > 0 && edgeOrigin[ei] == uint.max)
                        continue;
                    Vec3 a = mesh.vertices[edge[0]];
                    Vec3 b = mesh.vertices[edge[1]];
                    int k = seg * 6;
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }
        if (vertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
            float* vp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (vp) {
                int seg = 0;
                foreach (vi, v; mesh.vertices) {
                    if (vertOrigin.length > 0 && vertOrigin[vi] == uint.max)
                        continue;
                    int k = seg * 3;
                    vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
                    seg++;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }

    // Drag-fast path: re-upload every VBO in full, but skip the GC churn
    // that the array-growth `~=` loops in `upload()` impose. Despite the
    // name + `toUpdate` mask, this no longer takes a partial-write
    // shortcut — `glMapBufferRange + GL_MAP_WRITE_BIT` alone (no invalidate)
    // sounds spec-safe but Mesa orphans the backing store anyway, leaving
    // un-touched faces as garbage. The map-with-invalidate path orphans
    // EXPLICITLY (the driver hands us a fresh allocation) and we fill it
    // from scratch — so every byte in the buffer ends up well-defined.
    //
    // `toUpdate` is retained in the signature for caller compatibility but
    // ignored here; the drag tools always pass the same mesh ref through
    // and we touch the full topology either way.
    void uploadSelectedVertices(ref const Mesh mesh, const bool[] toUpdate) {
        // Preview is currently displayed; cage-indexed scatter writes would
        // corrupt the VBO. Signal a mutation and let the main loop rebuild
        // the preview instead.
        if (suppressCageUpload) {
            ++(cast(Mesh*)&mesh).mutationVersion;
            return;
        }
        ++uploadVersion;
        enum FACE_STRIDE = 6;

        // Face VBO — flat-shaded fan triangulation, one normal per face.
        if (faceVertCount > 0 && faceTriStart.length == mesh.faces.length) {
            glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
            float* fp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(faceVertCount * FACE_STRIDE * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (fp) {
                foreach (fi, face; mesh.faces) {
                    if (face.length < 3) continue;
                    immutable uint i0 = face[0];
                    Vec3 v0 = mesh.vertices[i0];
                    Vec3 v1 = mesh.vertices[face[1]];
                    Vec3 v2 = mesh.vertices[face[2]];
                    float ax = v1.x - v0.x, ay = v1.y - v0.y, az = v1.z - v0.z;
                    float bx = v2.x - v0.x, by = v2.y - v0.y, bz = v2.z - v0.z;
                    float cx = ay*bz - az*by;
                    float cy = az*bx - ax*bz;
                    float cz = ax*by - ay*bx;
                    float nlen = sqrt(cx*cx + cy*cy + cz*cz);
                    float nx, ny, nz;
                    if (nlen > 1e-6f) { float inv = 1.0f/nlen; nx=cx*inv; ny=cy*inv; nz=cz*inv; }
                    else              { nx=0; ny=1; nz=0; }
                    int k = faceTriStart[fi] * FACE_STRIDE;
                    for (size_t i = 1; i + 1 < face.length; i++) {
                        Vec3 va = mesh.vertices[i0];
                        Vec3 vb = mesh.vertices[face[i]];
                        Vec3 vc = mesh.vertices[face[i+1]];
                        fp[k++] = va.x; fp[k++] = va.y; fp[k++] = va.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vb.x; fp[k++] = vb.y; fp[k++] = vb.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                        fp[k++] = vc.x; fp[k++] = vc.y; fp[k++] = vc.z;
                        fp[k++] = nx;   fp[k++] = ny;   fp[k++] = nz;
                    }
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Edge VBO — VBO segment index == cage edge index in cage mode
        // (subpatch upload would have populated edgeOriginGpu and gone
        // through the suppressCageUpload early-return above, so we're
        // guaranteed unfiltered here).
        if (edgeVertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
            float* ep = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(edgeVertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (ep) {
                int k = 0;
                foreach (ei, edge; mesh.edges) {
                    Vec3 a = mesh.vertices[edge[0]], b = mesh.vertices[edge[1]];
                    ep[k++] = a.x; ep[k++] = a.y; ep[k++] = a.z;
                    ep[k++] = b.x; ep[k++] = b.y; ep[k++] = b.z;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        // Vertex VBO — same invariant: cage upload places vi at vbo slot vi.
        if (vertCount > 0) {
            glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
            float* vp = cast(float*)glMapBufferRange(
                GL_ARRAY_BUFFER, 0,
                cast(GLsizeiptr)(vertCount * 3 * float.sizeof),
                GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            if (vp) {
                foreach (vi, v; mesh.vertices) {
                    int k = cast(int)vi * 3;
                    vp[k] = v.x; vp[k+1] = v.y; vp[k+2] = v.z;
                }
                glUnmapBuffer(GL_ARRAY_BUFFER);
            }
        }

        glBindVertexArray(0);
    }

    // Draw faces only (writes depth buffer). Material colour comes from
    // the Materials UBO (LitShader.setSurfaces); u_overrideMix is left
    // at its useProgram default of 0 so the shader uses mat_base[matId].
    void drawFaces(const ref LitShader shader) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glBindVertexArray(faceVao);
        glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
        glDisable(GL_POLYGON_OFFSET_FILL);
        glBindVertexArray(0);
    }

    // Draw faces with per-face hover highlights (Polygons mode). When the
    // subpatch preview is uploaded, `faceOriginGpu` maps each VBO face to
    // its cage face so every preview child of a hovered cage face is tinted.
    // The "hover" branches flip u_overrideMix=1 + u_color=light-blue so the
    // hovered face shows the legacy highlight even on multi-material LWO
    // meshes; the non-hover branches restore u_overrideMix=0 so the rest
    // of the mesh keeps its surface colours.
    void drawFacesHighlighted(const ref LitShader shader,
                               int hoveredFace, const bool[] selectedFaces) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glBindVertexArray(faceVao);
        scope(exit) {
            glDisable(GL_POLYGON_OFFSET_FILL);
            glBindVertexArray(0);
            // Always leave overrideMix at the useProgram default so the
            // next caller doesn't inherit a hover-tint state.
            glUniform1f(shader.locOverrideMix, 0.0f);
        }

        int vboFaceCount = cast(int)faceTriStart.length;

        if (hoveredFace < 0) {
            glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
            return;
        }

        bool preview = faceOriginGpu.length > 0;
        int cageOf(int fi) {
            return preview ? cast(int)faceOriginGpu[fi] : fi;
        }

        // Cage-mode single-face fast path.
        if (!preview) {
            if (hoveredFace >= vboFaceCount) {
                glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
                return;
            }
            int hs = faceTriStart[hoveredFace];
            int hc = faceTriCount[hoveredFace];
            // Surrounding non-hover faces: material colour.
            if (hs > 0) glDrawArrays(GL_TRIANGLES, 0, hs);
            if (hs + hc < faceVertCount)
                glDrawArrays(GL_TRIANGLES, hs + hc, faceVertCount - hs - hc);
            // Hover face: hard override to the legacy highlight blue.
            if (hc > 0) {
                glUniform1f(shader.locOverrideMix, 1.0f);
                glUniform3f(shader.locColor, 0.5f, 0.71f, 0.79f);
                glDrawArrays(GL_TRIANGLES, hs, hc);
            }
            return;
        }

        // Preview: batch contiguous VBO-face runs of the same hover state.
        void batchRun(bool hoverState) {
            int batchStart = -1;
            for (int i = 0; i < vboFaceCount; i++) {
                bool isHover = cageOf(i) == hoveredFace;
                if (isHover == hoverState) {
                    if (batchStart < 0) batchStart = i;
                } else if (batchStart >= 0) {
                    int s = faceTriStart[batchStart];
                    int e = faceTriStart[i];
                    if (e > s) glDrawArrays(GL_TRIANGLES, s, e - s);
                    batchStart = -1;
                }
            }
            if (batchStart >= 0) {
                int s = faceTriStart[batchStart];
                if (faceVertCount > s) glDrawArrays(GL_TRIANGLES, s, faceVertCount - s);
            }
        }
        // Non-hover preview triangles: material colour.
        batchRun(false);
        // Hover preview triangles: legacy highlight blue.
        glUniform1f(shader.locOverrideMix, 1.0f);
        glUniform3f(shader.locColor, 0.5f, 0.71f, 0.79f);
        batchRun(true);
    }

    // Draw only the selected faces geometry (no color set — caller sets up shader).
    // Optimized: batch selected faces to minimize draw calls. In subpatch
    // mode each VBO face is mapped through `faceOriginGpu` so all children
    // of a selected cage face are included.
    void drawSelectedFacesOverlay(const bool[] selectedFaces) {
        glBindVertexArray(faceVao);

        bool preview = faceOriginGpu.length > 0;
        bool isSelected(int i) {
            int cage = preview ? cast(int)faceOriginGpu[i] : i;
            return cage >= 0 && cage < cast(int)selectedFaces.length && selectedFaces[cage];
        }

        int batchStart = -1;
        int vboFaceCount = cast(int)faceTriStart.length;
        for (int i = 0; i < vboFaceCount; i++) {
            if (!isSelected(i)) {
                if (batchStart >= 0) {
                    int startIdx = faceTriStart[batchStart];
                    int endIdx   = faceTriStart[i];
                    glDrawArrays(GL_TRIANGLES, startIdx, endIdx - startIdx);
                    batchStart = -1;
                }
            } else if (batchStart < 0) {
                batchStart = i;
            }
        }

        // Draw final batch if exists
        if (batchStart >= 0) {
            int startIdx = faceTriStart[batchStart];
            glDrawArrays(GL_TRIANGLES, startIdx, faceVertCount - startIdx);
        }

        glBindVertexArray(0);
    }

    // Draw edges with optional hover/selection highlights.
    // `selectedEdges` and `hoveredEdge` are indexed by CAGE edges. When a
    // subpatch preview is uploaded, `edgeOriginGpu` maps each VBO segment
    // back to its cage edge so highlights propagate across every segment of
    // the corresponding original edge.
    //
    // `hoveredEdges` is an OPTIONAL cage-indexed hover SET (default empty).
    // A segment is hovered when its cage edge equals `hoveredEdge` OR its cage
    // edge is set in `hoveredEdges`. This lets a caller pre-highlight a whole
    // edge loop in the hover colour (ElementMove + falloff EdgeLoops): pass the
    // loop's edge mask and the single hovered edge index. With the default
    // empty mask the behaviour is identical to the single-edge form, so every
    // existing call site is unchanged.
    void drawEdges(GLint locColor, int hoveredEdge, const bool[] selectedEdges,
                   const bool[] hoveredEdges = []) {
        int edgeCount = edgeVertCount / 2;
        glBindVertexArray(edgeVao);

        bool preview = edgeOriginGpu.length > 0;
        int  cageOf(int segIdx) {
            return preview ? cast(int)edgeOriginGpu[segIdx] : segIdx;
        }
        bool segSelected(int segIdx) {
            int c = cageOf(segIdx);
            return c >= 0 && c < cast(int)selectedEdges.length && selectedEdges[c];
        }
        bool segHovered(int segIdx) {
            int c = cageOf(segIdx);
            if (hoveredEdge >= 0 && c == hoveredEdge) return true;
            return c >= 0 && c < cast(int)hoveredEdges.length && hoveredEdges[c];
        }

        // Is ANY segment in the hover colour? (single hovered edge OR any
        // loop-mask edge). Drives the gray-pass fast path + the all-selected
        // shortcut so a loop mask with hoveredEdge < 0 still skips its segments.
        bool anyHover = hoveredEdge >= 0;
        if (!anyHover)
            foreach (h; hoveredEdges) if (h) { anyHover = true; break; }

        // "All selected" shortcut is only safe when VBO segments are 1:1 with
        // cage edges (cage mode). Skip it in preview mode.
        bool allEdgesSelected = !preview
            && selectedEdges.length >= edgeCount
            && !anyHover;
        if (allEdgesSelected)
            foreach (s; selectedEdges[0 .. edgeCount]) if (!s) { allEdgesSelected = false; break; }

        // Gray pass — depth-tested, skip hovered/selected segments.
        glUniform3f(locColor, 0.9f, 0.9f, 0.9f);
        if (!anyHover && selectedEdges.length == 0) {
            glDrawArrays(GL_LINES, 0, edgeVertCount);
        } else if (!allEdgesSelected) {
            int batchStart = -1;
            for (int i = 0; i < edgeCount; i++) {
                bool skip = segHovered(i) || segSelected(i);
                if (!skip) {
                    if (batchStart < 0) batchStart = i;
                } else if (batchStart >= 0) {
                    glDrawArrays(GL_LINES, batchStart * 2, (i - batchStart) * 2);
                    batchStart = -1;
                }
            }
            if (batchStart >= 0)
                glDrawArrays(GL_LINES, batchStart * 2, (edgeCount - batchStart) * 2);
        }

        // Highlight pass — draw without depth so selection shows through.
        glDisable(GL_DEPTH_TEST);

        if (allEdgesSelected && hoveredEdge < 0) {
            glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
            glDrawArrays(GL_LINES, 0, edgeVertCount);
        } else if (selectedEdges.length > 0) {
            glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
            int batchStart = -1;
            for (int i = 0; i < edgeCount; i++) {
                if (segSelected(i) && !segHovered(i)) {
                    if (batchStart < 0) batchStart = i;
                } else if (batchStart >= 0) {
                    glDrawArrays(GL_LINES, batchStart * 2, (i - batchStart) * 2);
                    batchStart = -1;
                }
            }
            if (batchStart >= 0)
                glDrawArrays(GL_LINES, batchStart * 2, (edgeCount - batchStart) * 2);
        }

        if (anyHover) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            // Draw EVERY hovered segment (single hovered edge + any loop-mask
            // edges). In preview mode a cage edge fans out to several VBO
            // segments; in cage mode it is 1:1 — segHovered() handles both and
            // also folds in the hoveredEdges loop mask, so a single scan covers
            // the single-edge case and the whole-loop case uniformly.
            for (int i = 0; i < edgeCount; i++)
                if (segHovered(i))
                    glDrawArrays(GL_LINES, i * 2, 2);
        }

        glEnable(GL_DEPTH_TEST);
        glBindVertexArray(0);
    }

    // Draw vertex dots (call AFTER picking so hovered/selected state is current)
    /// `hovered` and `selected` are CAGE-indexed. In cage mode the VBO
    /// is also cage-indexed (vertOriginGpu is the identity), so a slot
    /// lookup is direct. In subpatch mode the VBO holds only "vert-
    /// point" preview verts (cage origin recorded in vertOriginGpu)
    /// and most cage-vert indices have no VBO slot — translate
    /// through vertOriginGpu the same way drawEdges does. Without
    /// this, hovering on the subdivided surface highlighted the wrong
    /// preview vert because the cage index from picking was being
    /// used as a raw glDrawArrays offset.
    void drawVertices(GLint locColor, int hovered, const bool[] selected) {
        glBindVertexArray(vertVao);

        // All vertices — small gray dots, with depth test
        glPointSize(5.0f);
        glUniform3f(locColor, 0.6f, 0.6f, 0.6f);
        glDrawArrays(GL_POINTS, 0, vertCount);

        // Selected and hovered — drawn without depth test so they show through faces.
        glDisable(GL_DEPTH_TEST);

        int cageOf(int vboIdx) {
            if (vboIdx >= cast(int)vertOriginGpu.length) return -1;
            uint c = vertOriginGpu[vboIdx];
            return (c == uint.max) ? -1 : cast(int)c;
        }

        glPointSize(10.0f);
        glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
        for (int i = 0; i < vertCount; i++) {
            int c = cageOf(i);
            if (c < 0) continue;
            if (c < cast(int)selected.length && selected[c])
                glDrawArrays(GL_POINTS, i, 1);
        }

        if (hovered >= 0) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            for (int i = 0; i < vertCount; i++) {
                if (cageOf(i) == hovered)
                    glDrawArrays(GL_POINTS, i, 1);
            }
        }

        glEnable(GL_DEPTH_TEST);
        glPointSize(1.0f);
        glBindVertexArray(0);
    }
}

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
// unifyFaces unittests
// ---------------------------------------------------------------------------

unittest { // duplicate face (reversed winding) removed; lowest-index kept
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    // Install both faces directly — makePolygonFromVerts would reject the dup.
    m.faces = [[0u,1u,2u,3u], [3u,2u,1u,0u]]; // same vertex set, reversed winding
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t removed = m.unifyFaces();
    assert(removed == 1, "expected 1 face removed, got " ~ uintToStr(removed));
    assert(m.faces.length == 1, "expected 1 face remaining");
    // First occurrence (index 0) must be the survivor.
    assert(m.faces[0][] == [0u,1u,2u,3u], "lowest-index face must be kept");
}

unittest { // no duplicate faces → no-op, version unchanged
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    m.buildLoops();
    m.faces = [[0u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    const verBefore = m.topologyVersion;
    size_t removed = m.unifyFaces();
    assert(removed == 0, "single face: no dup to remove");
    assert(m.topologyVersion == verBefore, "no-op must not bump topology version");
}

// ---------------------------------------------------------------------------
// cleanDegenerateFaces unittests
// ---------------------------------------------------------------------------

unittest { // literal 2-vertex face removed (only exercisable via direct assignment)
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    // 2-vertex face: bypasses makePolygonFromVerts guard (which requires ≥3 entries).
    m.faces = [[0u, 1u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t n = m.cleanDegenerateFaces();
    assert(n >= 1, "2-vertex face must be removed");
    assert(m.faces.length == 0, "no faces should remain");
}

unittest { // face [0,1,1]: 3 entries, <3 distinct → removed
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    m.faces = [[0u, 1u, 1u]];  // repeated vert 1 → collapses to [0,1] → dropped
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t n = m.cleanDegenerateFaces();
    assert(n >= 1, "[0,1,1] must be removed (<3 distinct after dedup)");
    assert(m.faces.length == 0);
}

unittest { // consecutive-dup rewritten: [0,1,1,2,3] → [0,1,2,3], face kept
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    // Face with a consecutively duplicated vert; after collapse → valid quad.
    m.faces = [[0u, 1u, 1u, 2u, 3u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t n = m.cleanDegenerateFaces();
    assert(n == 1, "rewritten face counts as 1 affected");
    assert(m.faces.length == 1, "face must be kept after rewrite");
    assert(m.faces[0].length == 4, "expect 4 verts after removing consecutive dup");
}

unittest { // zero-area collinear triangle removed
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0)]; // three points on x-axis
    m.faces = [[0u, 1u, 2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t n = m.cleanDegenerateFaces();
    assert(n >= 1, "zero-area (collinear) face must be removed");
    assert(m.faces.length == 0);
}

unittest { // clean triangle → no-op, no commitChange (topology version unchanged)
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    m.faces = [[0u, 1u, 2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    const verBefore = m.topologyVersion;
    size_t n = m.cleanDegenerateFaces();
    assert(n == 0, "clean mesh: expected no changes");
    assert(m.topologyVersion == verBefore, "no version bump on clean mesh (early-return)");
}

// ---------------------------------------------------------------------------
// cleanupMesh unittests
// ---------------------------------------------------------------------------

// Helper: convert size_t to string for assert messages.
private string uintToStr(size_t v) {
    if (v == 0) return "0";
    char[20] buf;
    size_t i = buf.length;
    do { buf[--i] = cast(char)('0' + v % 10); v /= 10; } while (v);
    return buf[i .. $].idup;
}

unittest { // all-dirty mesh: each stage fires correctly
    // Layout:
    //   verts 0-3: quad [0,1,2,3]              positions (0,0,0)-(1,0,0)-(1,1,0)-(0,1,0)
    //   vert 4:    (0.5,0,0) — used in zero-area triangle [0,4,1] (collinear)
    //   vert 5:    (0,0,0)   — coincident with vert 0; used in face [5,6,7]
    //   verts 6-7: (2,0,0),(2,1,0) — for valid triangle [5,6,7] → [0,6,7] after weld
    //   vert 8:    (9,9,9)   — pure orphan (not in any face)
    //   face [0,1,2,3]: valid quad
    //   face [0,1,2,3]: duplicate of above
    //   face [0,4,1]:   zero-area (collinear on x-axis) → cleanDegenerateFaces drops it
    //   face [5,6,7]:   valid, becomes [0,6,7] after weld of 5→0
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),   // 0-3
        Vec3(0.5f,0,0),                                          // 4 (collinear)
        Vec3(0,0,0),                                             // 5 (coincident with 0)
        Vec3(2,0,0), Vec3(2,1,0),                               // 6-7
        Vec3(9,9,9),                                             // 8 (orphan)
    ];
    m.faces = [
        [0u,1u,2u,3u],
        [0u,1u,2u,3u],  // duplicate
        [0u,4u,1u],     // zero-area (0, 0.5, 1 on x-axis)
        [5u,6u,7u],     // valid triangle (5 coincident with 0)
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    auto r = m.cleanupMesh();

    // Stage counts — each stage that fired must be non-zero.
    assert(r.welded     >= 1, "weld: vert 5→0 expected; got " ~ uintToStr(r.welded));
    assert(r.degenerate >= 1, "degenerate: zero-area [0,4,1] expected; got " ~ uintToStr(r.degenerate));
    assert(r.unified    >= 1, "unified: duplicate [0,1,2,3] expected; got " ~ uintToStr(r.unified));
    assert(r.dissolved  == 0, "dissolve2Valent is off by default");
    // Note: r.orphans may be 0 even though orphan verts were removed, because
    // cleanDegenerateFaces() / unifyFaces() each call compactUnreferenced()
    // internally — by the time cleanupMesh's own intermediate compact runs,
    // the orphans are already gone. The geometry counts below verify correctness.

    // Final geometry: verts {0,1,2,3,6,7} only; faces [0,1,2,3] and [0,6,7]
    assert(m.faces.length == 2, "expected 2 faces, got " ~ uintToStr(m.faces.length));
    assert(m.vertices.length == 6, "expected 6 verts, got " ~ uintToStr(m.vertices.length));
    assert(r.anyAffected(), "anyAffected must be true");
}

unittest { // weld-creates-a-duplicate order guard (regression)
    // Two coincident verts A(0)=B(3) + faces [A,1,2] and [B,1,2].
    // Correct order: weld B→A first, then unifyFaces removes the dup.
    // Wrong order (unify-before-weld): dup survives because they look distinct pre-weld.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0),  // 0,1,2
        Vec3(0,0,0),                              // 3 = coincident with 0
    ];
    m.faces = [[0u,1u,2u], [3u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    auto r = m.cleanupMesh();

    assert(r.welded >= 1, "weld: vert 3→0 expected");
    assert(r.unified >= 1, "unify: weld-created dup must be caught");
    assert(m.faces.length == 1, "expected 1 face; weld-dup must be removed");
    assert(m.vertices.length == 3, "expected 3 verts after compact");
}

unittest { // removeOrphans:false: orphan vert preserved; no stage fires → no-op
    // Triangle + one floating vert (orphan).  No dirty geometry → all other stages
    // are no-ops.  With removeOrphans:false the orphan must survive untouched.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(9,9,9)]; // vert 3 = orphan
    m.faces = [[0u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    CleanupOptions o;
    o.removeOrphans = false;
    auto r = m.cleanupMesh(o);

    assert(!r.anyAffected(), "clean mesh + removeOrphans:false: no stage should fire");
    assert(m.vertices.length == 4, "orphan must survive when removeOrphans is false");
}

unittest { // all-stages-off + orphan: true no-op, topology version unchanged
    // This is the contract test: before the fix, the unconditional final
    // compactUnreferenced would mutate the mesh and bump the topology version
    // even with every stage disabled.  With the fix this is a genuine no-op.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(9,9,9)]; // vert 3 = orphan
    m.faces = [[0u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    const verBefore = m.topologyVersion;

    CleanupOptions o;
    o.mergeVerts      = false;
    o.dropDegenerate  = false;
    o.unify           = false;
    o.removeOrphans   = false;
    o.dissolve2Valent = false;
    auto r = m.cleanupMesh(o);

    assert(!r.anyAffected(), "all-stages-off must return no-op result");
    assert(m.vertices.length == 4, "orphan must not be removed with all stages off");
    assert(m.topologyVersion == verBefore,
        "topology version must not change on a true no-op (no-op contract)");
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
/// (graceful degradation — no crash).
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
// insertEdgeLoops — connectivity correctness (Risk 2: orientation)
// ---------------------------------------------------------------------------
//
// Tests two shapes:
//   A) Closed ring: unit cube, seed = edge 0-1.
//      Ring crosses four equatorial quad faces.  One loop at t=0.5.
//      Expected: V=12, E=20, F=10, Euler=2.
//      Must assert: rung edges by endpoint pair, one sub-quad by vertex set,
//      midpoint position — counts/Euler alone cannot catch a twisted loop.
//
//   B) Open ring: 1×3 quad strip.
//      Ring terminates at both strip boundaries.  One loop at t=0.5.
//      Expected: V=12, E=17, F=6, Euler=1 (disk topology).
//      Must assert: rung edges at the seed edge's midpoint on both sides.

unittest {
    import std.math : abs;

    // Helper: true if any face in m has exactly the vertices in vs (order-independent).
    static bool hasFace(const Mesh m, uint[] vs) {
        outer: foreach (const f; m.faces) {
            if (f.length != vs.length) continue;
            foreach (v; vs) {
                bool found = false;
                foreach (fv; f) if (fv == v) { found = true; break; }
                if (!found) continue outer;
            }
            return true;
        }
        return false;
    }

    // Helper: find a vertex near the given position; returns ~0u if none within eps.
    static uint findVertNear(const Mesh m, float x, float y, float z,
                             float eps = 1e-4f) {
        foreach (uint i; 0 .. cast(uint)m.vertices.length) {
            auto v = m.vertices[i];
            if (abs(v.x - x) < eps && abs(v.y - y) < eps && abs(v.z - z) < eps)
                return i;
        }
        return ~0u;
    }

    // ------------------------------------------------------------------
    // A) Closed ring on the default cube — seed edge 0-1.
    // Cube: v0=(-0.5,-0.5,-0.5) v1=(0.5,-0.5,-0.5)  edge 0-1 = bottom-front.
    // ------------------------------------------------------------------
    {
        Mesh m = makeCube();
        m.buildLoops();

        uint eiSeed = m.edgeIndex(0, 1);
        assert(eiSeed != ~0u, "seed edge 0-1 must exist in cube");

        bool ok = m.insertEdgeLoops(eiSeed, [0.5f]);
        assert(ok, "insertEdgeLoops must succeed on cube");

        // Counts + Euler (V-E+F=2 for closed manifold).
        assert(m.vertices.length == 12, "V must be 12 after one loop on cube");
        assert(m.edges.length    == 20, "E must be 20 after one loop on cube");
        assert(m.faces.length    == 10, "F must be 10 after one loop on cube");
        assert(cast(int)m.vertices.length - cast(int)m.edges.length
               + cast(int)m.faces.length == 2, "Euler must be 2 (closed manifold)");

        // All faces must still be quads.
        foreach (const f; m.faces)
            assert(f.length == 4, "all faces must be quads after loop insert");

        // Midpoint position: new vertex on edge 0-1 must be at x=0 (midpoint
        // of v0.x=-0.5 and v1.x=0.5), y=-0.5, z=-0.5.
        // The walk processes faces in fi order; fi=0 is F0=[0,3,2,1] which
        // contains edge 0-1, so the first new vertex (index 8) is the midpoint
        // of the edge traversed a→b in F0, which equals lerp(v1,v0,0.5) or
        // lerp(v0,v1,0.5) — either way, x=0, y=-0.5, z=-0.5.
        uint mA = findVertNear(m, 0.0f, -0.5f, -0.5f);
        assert(mA != ~0u, "midpoint of edge 0-1 must exist at (0,-0.5,-0.5)");

        // Corresponding midpoints on the three other belt edges.
        uint mB = findVertNear(m,  0.0f,  0.5f, -0.5f); // midpoint of edge 2-3
        uint mC = findVertNear(m,  0.0f,  0.5f,  0.5f); // midpoint of edge 6-7
        uint mD = findVertNear(m,  0.0f, -0.5f,  0.5f); // midpoint of edge 4-5
        assert(mB != ~0u, "midpoint of edge 2-3 must exist at (0,0.5,-0.5)");
        assert(mC != ~0u, "midpoint of edge 6-7 must exist at (0,0.5,0.5)");
        assert(mD != ~0u, "midpoint of edge 4-5 must exist at (0,-0.5,0.5)");

        // Rung edges — these are the new loop edges connecting the midpoints.
        // They form a closed belt: mA–mB–mC–mD–mA.
        assert(m.edgeIndex(mA, mB) != ~0u, "rung edge mA-mB must exist");
        assert(m.edgeIndex(mB, mC) != ~0u, "rung edge mB-mC must exist");
        assert(m.edgeIndex(mC, mD) != ~0u, "rung edge mC-mD must exist");
        assert(m.edgeIndex(mD, mA) != ~0u, "rung edge mD-mA must exist (closure)");

        // One sub-quad by vertex set — orientation sanity.
        // F0=[0,3,2,1] is split into [0,mA,mB,3] (or permutation) and [mA,1,2,mB].
        // We accept either sub-quad of F0 to allow for orientation variants.
        bool subQuadOk = hasFace(m, [0u, mA, mB, 3u]) || hasFace(m, [mA, 1u, 2u, mB]);
        assert(subQuadOk, "at least one sub-quad of the F0 split must exist by vertex set");
    }

    // ------------------------------------------------------------------
    // B) Open ring: 1×3 quad strip — seed = interior edge 1-5.
    // Strip: F0=[0,1,5,4], F1=[1,2,6,5], F2=[2,3,7,6]
    // Ring from seed 1-5: both sides stop at strip boundaries.
    // ------------------------------------------------------------------
    {
        Mesh m;
        m.vertices = [
            Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0), Vec3(3,0,0),
            Vec3(0,0,1), Vec3(1,0,1), Vec3(2,0,1), Vec3(3,0,1),
        ];
        m.addFace([0u, 1u, 5u, 4u]);  // F0
        m.addFace([1u, 2u, 6u, 5u]);  // F1
        m.addFace([2u, 3u, 7u, 6u]);  // F2
        m.buildLoops();

        uint eiSeed = m.edgeIndex(1, 5);
        assert(eiSeed != ~0u, "seed edge 1-5 must exist in strip");

        bool ok = m.insertEdgeLoops(eiSeed, [0.5f]);
        assert(ok, "insertEdgeLoops must succeed on open strip");

        // V=12, E=17, F=6, Euler=1 (disk topology).
        assert(m.vertices.length == 12, "V must be 12 after open-ring loop");
        assert(m.edges.length    == 17, "E must be 17 after open-ring loop");
        assert(m.faces.length    ==  6, "F must be 6 after open-ring loop");
        assert(cast(int)m.vertices.length - cast(int)m.edges.length
               + cast(int)m.faces.length == 1, "Euler must be 1 (disk topology)");

        // All faces must still be quads.
        foreach (const f; m.faces)
            assert(f.length == 4, "all strip faces must be quads after loop insert");

        // Midpoint on the seed edge 1-5.
        uint mSeed = findVertNear(m, 1.0f, 0.0f, 0.5f);
        assert(mSeed != ~0u, "midpoint of edge 1-5 must exist at (1,0,0.5)");

        // The midpoint is shared between F0 and F1 ring entries, so it must
        // appear as a vertex in a rung edge on EACH side of the seed.
        // Left side (F0): rung connects mSeed to midpoint of 0-4.
        // Right side (F1): rung connects mSeed to midpoint of 2-6.
        uint mLeft  = findVertNear(m, 0.0f, 0.0f, 0.5f); // midpoint of 0-4
        uint mRight = findVertNear(m, 2.0f, 0.0f, 0.5f); // midpoint of 2-6
        assert(mLeft  != ~0u, "midpoint of edge 0-4 must exist at (0,0,0.5)");
        assert(mRight != ~0u, "midpoint of edge 2-6 must exist at (2,0,0.5)");

        assert(m.edgeIndex(mSeed, mLeft)  != ~0u,
               "rung edge mSeed-mLeft must exist (F0 rung)");
        assert(m.edgeIndex(mSeed, mRight) != ~0u,
               "rung edge mSeed-mRight must exist (F1 rung)");

        // mLeft and mRight must NOT be directly connected (open ring — not a closed loop).
        assert(m.edgeIndex(mLeft, mRight) == ~0u,
               "mLeft and mRight must NOT be directly connected (open ring)");
    }
}

// ---------------------------------------------------------------------------
// collectEdgeRing — non-quad guard (SHOULD-FIX: mixed tri/quad seed)
// ---------------------------------------------------------------------------
//
// If EITHER seed-incident face is a non-quad, collectEdgeRing must return []
// so that insertEdgeLoops never introduces a T-junction.
//
// Mesh: quad [0,1,2,3] + triangle [2,1,4] sharing edge 1-2.
//
//   v4=(0.5,2,0)
//      |
//   v3=(0,1,0)--v2=(1,1,0)
//   |            |
//   v0=(0,0,0)--v1=(1,0,0)
//
// Seed edge = 1-2 (shared by quad on one side, triangle on the other).
// Expected: collectEdgeRing returns [], insertEdgeLoops returns false,
//           vertex / edge / face counts unchanged.

unittest {
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0), Vec3(0.5f,2,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);   // quad
    m.addFace([2u, 1u, 4u]);       // triangle — shares edge 1-2 with the quad
    m.buildLoops();

    uint eiSeed = m.edgeIndex(1, 2);
    assert(eiSeed != ~0u, "edge 1-2 must exist in the mixed-valence mesh");

    // collectEdgeRing must return empty: the triangle makes the seed non-manifold-safe.
    bool closed;
    auto ring = m.collectEdgeRing(eiSeed, closed);
    assert(ring.length == 0,
           "collectEdgeRing must return [] when a non-quad is incident on the seed");

    // insertEdgeLoops must propagate the no-op.
    uint vBefore = cast(uint)m.vertices.length;
    uint eBefore = cast(uint)m.edges.length;
    uint fBefore = cast(uint)m.faces.length;

    bool ok = m.insertEdgeLoops(eiSeed, [0.5f]);
    assert(!ok, "insertEdgeLoops must return false for a triangle-adjacent seed");
    assert(m.vertices.length == vBefore, "vertex count must not change");
    assert(m.edges.length    == eBefore, "edge count must not change");
    assert(m.faces.length    == fBefore, "face count must not change");
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

// ---------------------------------------------------------------------------
// reduceToTarget kernel unittests (dub test --config=modeling gate)
// ---------------------------------------------------------------------------

unittest { // reduceToTarget no-op: target >= current face count
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto triMask = new bool[](m.faces.length); triMask[] = true;
    m.triangulateFacesByMask(triMask); // 12 tris
    assert(m.faces.length == 12);
    size_t n = m.reduceToTarget(12, true);
    assert(n == 0, "target==current must return 0, got " ~ n.to!string);
    assert(m.faces.length == 12, "mesh must be unchanged");
}

unittest { // reduceToTarget: tri cube → ~50% faces, manifold, no degenerate
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto triMask = new bool[](m.faces.length); triMask[] = true;
    m.triangulateFacesByMask(triMask);
    assert(m.faces.length == 12);

    size_t f0 = 12;
    size_t target = 6;
    size_t n = m.reduceToTarget(target, false);
    assert(n > 0, "expected at least 1 collapse");
    assert(m.faces.length <= f0, "face count must not increase");
    assert(m.vertices.length < 8, "vertex count must decrease");

    // No degenerate face: every face must have >= 3 distinct corners,
    // and Newell area > 0.
    import std.math : sqrt;
    foreach (fi; 0 .. m.faces.length) {
        const uint[] f = m.faces[fi];
        assert(f.length >= 3, "face " ~ fi.to!string ~ " has fewer than 3 corners");
        bool[uint] seen;
        foreach (vi; f) {
            assert(!(vi in seen), "face " ~ fi.to!string ~ " has duplicate corner");
            seen[vi] = true;
        }
        // Newell area.
        float nx = 0, ny = 0, nz = 0;
        foreach (i; 0 .. f.length) {
            Vec3 a = m.vertices[f[i]];
            Vec3 b = m.vertices[f[(i+1)%f.length]];
            nx += (a.y-b.y)*(a.z+b.z);
            ny += (a.z-b.z)*(a.x+b.x);
            nz += (a.x-b.x)*(a.y+b.y);
        }
        assert(sqrt(nx*nx+ny*ny+nz*nz) > 1e-6f,
               "face " ~ fi.to!string ~ " has near-zero area");
    }

    // Manifold check: every edge appears on at most 2 faces.
    int[ulong] edgeFaceCnt;
    foreach (fi; 0 .. m.faces.length) {
        const uint[] f = m.faces[fi];
        foreach (i; 0 .. f.length) {
            uint a = f[i], b = f[(i+1)%f.length];
            ulong key = a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
            edgeFaceCnt[key]++;
        }
    }
    foreach (key, cnt; edgeFaceCnt)
        assert(cnt <= 2, "edge 0x" ~ key.to!string(16) ~ " on " ~ cnt.to!string ~ " faces");
}

unittest { // reduceToTarget preserveBoundary=true: boundary positions kept, interior collapses happen
    import std.conv : to;
    import std.math : sqrt;

    // Build a denser open mesh so interior (non-boundary) edges are available for
    // collapse.  facetedSubdivide turns 6 quads → 24 quads (26 verts); triangulate
    // → 48 tris; removing the last tri opens a 3-edge boundary → 47 tris, 3 boundary
    // verts, 23 interior verts with many collapsible interior edges between them.
    Mesh m = makeCube();
    {
        bool[] allF; allF.length = m.faces.length; allF[] = true;
        m = facetedSubdivide(m, allF);   // 26 verts, 24 quads; buildLoops already called
    }
    {
        auto triMask = new bool[](m.faces.length); triMask[] = true;
        m.triangulateFacesByMask(triMask);   // 48 tris
    }
    // Remove the last triangle to open the mesh.
    {
        uint[][] newFaces;
        foreach (fi; 0 .. m.faces.length - 1) newFaces ~= m.faces[fi].dup;
        m.faces = FaceList.init;
        foreach (f; newFaces) m.addFace(f);
        m.buildLoops();
    }
    assert(m.faces.length == 47, "expected 47 tris after removing one from 48");

    // Capture boundary vertex positions before reduce.
    Vec3[] bpos;
    {
        bool[] isBV; isBV.length = m.vertices.length;
        foreach (uint ei; 0 .. cast(uint)m.edges.length) {
            uint va = m.edges[ei][0], vb = m.edges[ei][1];
            auto efr = EdgeFaceRange(m.loops, m.edges[], m.vertLoop, ei);
            int cnt = 0; foreach (_; efr) ++cnt;
            if (cnt < 2) { isBV[va] = true; isBV[vb] = true; }
        }
        foreach (vi, b; isBV) if (b) bpos ~= m.vertices[vi];
    }
    assert(bpos.length > 0, "open mesh must have boundary verts");

    // Reduce; the dense interior gives plenty of collapsible non-boundary edges.
    size_t n = m.reduceToTarget(40, true);
    assert(n > 0, "expected >0 interior collapses on denser mesh; got 0 -- "
                ~ "preserveBoundary guard may be over-rejecting or fixture is degenerate");

    // Every original boundary position must still exist in the post-reduce mesh.
    foreach (bp; bpos) {
        bool found = false;
        foreach (vp; m.vertices) {
            float dx = vp.x - bp.x, dy = vp.y - bp.y, dz = vp.z - bp.z;
            if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-5f) { found = true; break; }
        }
        assert(found, "boundary position (" ~ bp.x.to!string ~ ","
                    ~ bp.y.to!string ~ "," ~ bp.z.to!string ~ ") lost after reduce");
    }

    // Structural sanity.
    assert(m.faces.length <= 47, "face count must not increase");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length >= 3, "degenerate face after reduce");
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
// cutByPlane unittests
// ---------------------------------------------------------------------------

unittest { // cutByPlane: single quad split at x=0.5 — T-junction (index-share) + attr carry-over
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();

    // Set non-default material on face 0 and enable subpatch.
    m.surfaces ~= Surface("TestMat", Vec3(1,0,0));
    m.faceMaterial[0] = 1;
    m.setSubpatch(0, true);

    // Cut at x=0.5 (normal along X).
    size_t nSplit = m.cutByPlane(Vec3(0.5f, 0, 0), Vec3(1, 0, 0));

    assert(nSplit == 1, "single quad should produce 1 split");
    assert(m.faces.length == 2, "2 sub-faces after cut");
    // Edge (0,1): d[0]=-0.5, d[1]=0.5 → new vert v4 at (0.5,0,0)
    // Edge (3,2): d[3]=-0.5, d[2]=0.5 → new vert v5 at (0.5,1,0)
    assert(m.vertices.length == 6, "4 original + 2 crossing verts");

    // T-junction check: both sub-faces must share the SAME vertex index at
    // each cut point (same index = same addVertex call, no T-junction).
    uint[] f0 = m.faces[0];
    uint[] f1 = m.faces[1];
    // Find vertex indices at x=0.5 in each face.
    uint[] cuts0, cuts1;
    foreach (vi; f0) if (m.vertices[vi].x > 0.49f && m.vertices[vi].x < 0.51f) cuts0 ~= vi;
    foreach (vi; f1) if (m.vertices[vi].x > 0.49f && m.vertices[vi].x < 0.51f) cuts1 ~= vi;
    assert(cuts0.length == 2, "f0 must have 2 cut verts");
    assert(cuts1.length == 2, "f1 must have 2 cut verts");
    import std.algorithm : canFind;
    foreach (vi; cuts0)
        assert(cuts1.canFind(vi), "cut vert index must be shared between both sub-faces (T-junction check)");

    // Per-face attr carry-over (OBJ2): both sub-faces inherit material 1 and subpatch.
    assert(m.faceMaterial.length >= 2, "faceMaterial must cover both sub-faces");
    assert(m.faceMaterial[0] == 1, "f0 must inherit parent material 1");
    assert(m.faceMaterial[1] == 1, "f1 must inherit parent material 1");
    assert(m.isFaceSubpatch(0), "f0 must inherit subpatch bit");
    assert(m.isFaceSubpatch(1), "f1 must inherit subpatch bit");

    // Topology sanity.
    assert(m.edges.length > 0, "edges must be rebuilt");
    assert(m.loops.length == m.faces[0].length + m.faces[1].length, "loops must match arity sum");
}

unittest { // cutByPlane: adjacent-hit guard — plane at y=0.5 on cube (on-vertex row, no degenerate 2-gons)
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();

    // Plane at y=0.5 snaps top-row verts on-plane; side faces have adjacent hits → no splits.
    size_t nSplit = m.cutByPlane(Vec3(0, 0.5f, 0), Vec3(0, 1, 0));

    assert(nSplit == 0, "plane at top-vertex row must produce 0 splits (adjacent-hit guard)");
    assert(m.faces.length == 6, "face count must stay 6 (cube)");
    assert(m.vertices.length == 8, "vertex count must stay 8 (no new verts)");
    // No 2-vertex faces.
    foreach (fi, face; m.faces)
        assert(face.length >= 3, "no degenerate 2-vertex faces must exist");
}

unittest { // cutByPlane: cube mid-plane cut — correct face/vert counts and 0 orphans
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();

    // Cut at y=0 through the cube middle; 4 side faces straddle, 2 caps don't.
    size_t nSplit = m.cutByPlane(Vec3(0, 0, 0), Vec3(0, 1, 0));

    assert(nSplit == 4, "4 side faces split by mid-plane cut");
    assert(m.faces.length == 10, "6 faces → 4 split (×2) + 2 unchanged = 10");
    assert(m.vertices.length == 12, "8 original + 4 crossing verts = 12");
    // No orphan vertices.
    import std.conv : to;
    bool[] refd = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd[vi] = true;
    foreach (i, r; refd) assert(r, "vertex " ~ i.to!string ~ " is orphaned after cut");
    // No degenerate faces.
    foreach (face; m.faces) assert(face.length >= 3, "no degenerate sub-faces");
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

unittest { // bridgeLoopsPaired: exact-correspondence quad emission
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t n = m.bridgeLoopsPaired([0u,1u,2u,3u], [4u,5u,6u,7u]);
    assert(n == 4, "bridgeLoopsPaired: expected 4 quads");
    assert(m.faces.length == 4, "bridgeLoopsPaired: face count");
    foreach (f; m.faces) assert(f.length == 4, "bridgeLoopsPaired: all quads");

    // bridgeLoops still produces the same count (its tail now calls bridgeLoopsPaired).
    Mesh m2;
    m2.addVertex(Vec3(0,0,0)); m2.addVertex(Vec3(1,0,0));
    m2.addVertex(Vec3(1,1,0)); m2.addVertex(Vec3(0,1,0));
    m2.addVertex(Vec3(0,0,1)); m2.addVertex(Vec3(1,0,1));
    m2.addVertex(Vec3(1,1,1)); m2.addVertex(Vec3(0,1,1));
    size_t n2 = m2.bridgeLoops([0u,1u,2u,3u], [4u,5u,6u,7u]);
    assert(n2 == 4, "bridgeLoops via bridgeLoopsPaired: expected 4 quads");
    assert(m2.faces.length == 4, "bridgeLoops: face count unchanged after refactor");
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

// extrudeVerticesByMask: cube corner 0 at (-0.5,-0.5,-0.5).
// Corner 0 is incident to 3 faces whose normals are (0,0,-1)+(-1,0,0)+(0,-1,0)
// = (-1,-1,-1), normalized → direction = normalize(-1,-1,-1).
// Expected: +1 vertex, +1 edge; new vertex at corner + dir*0.5; selection
// moves to new vertex only.
unittest {
    import std.math : abs, sqrt;
    auto m = makeCube();
    const size_t oldV = m.vertices.length; // 8
    const size_t oldE = m.edges.length;    // 12

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;  // corner (-0.5,-0.5,-0.5)
    size_t added = m.extrudeVerticesByMask(mask, 0.5f);

    assert(added == 1,                    "extrudeVerticesByMask: should add 1 vertex");
    assert(m.vertices.length == oldV + 1, "extrudeVerticesByMask: vertex count +1");
    assert(m.edges.length    == oldE + 1, "extrudeVerticesByMask: edge count +1");

    // New vertex is at index oldV.
    const float inv3 = 1.0f / sqrt(3.0f);
    Vec3 expected = Vec3(-0.5f, -0.5f, -0.5f) + Vec3(-inv3, -inv3, -inv3) * 0.5f;
    Vec3 got = m.vertices[oldV];
    assert(abs(got.x - expected.x) < 1e-5f, "extrudeVerticesByMask: x mismatch");
    assert(abs(got.y - expected.y) < 1e-5f, "extrudeVerticesByMask: y mismatch");
    assert(abs(got.z - expected.z) < 1e-5f, "extrudeVerticesByMask: z mismatch");

    // Wire edge (0 → oldV) must exist.
    bool edgeFound = false;
    foreach (e; m.edges)
        if ((e[0] == 0 && e[1] == cast(uint)oldV) ||
            (e[1] == 0 && e[0] == cast(uint)oldV))
            edgeFound = true;
    assert(edgeFound, "extrudeVerticesByMask: wire edge not found");

    // Selection must have moved: only the new vertex selected.
    assert( m.isVertexSelected(oldV), "extrudeVerticesByMask: new vertex not selected");
    assert(!m.isVertexSelected(0),    "extrudeVerticesByMask: original vertex still selected");
}

// extrudeVerticesByMask: offset=0 is a no-op.
unittest {
    auto m = makeCube();
    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;
    size_t added = m.extrudeVerticesByMask(mask, 0.0f);
    assert(added == 0,                     "extrudeVerticesByMask: offset=0 must be no-op");
    assert(m.vertices.length == 8,         "extrudeVerticesByMask: offset=0 must not add verts");
    assert(m.edges.length    == 12,        "extrudeVerticesByMask: offset=0 must not add edges");
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

// ---------------------------------------------------------------------------
// revolveProfile unittests
// ---------------------------------------------------------------------------

unittest { // revolveProfile (a): closed ring 360° — 16 quads, 16 verts, manifold, 0 boundary loops
    import std.math : PI;
    import std.conv : to;

    // Square closed cross-section at x=2 from the Y axis.
    // Closing edges complete the ring (needed for bridgeLoopsPaired topology but
    // not structurally required — revolveProfile only reads vertex positions via
    // the vertex index array, not edge topology).
    Mesh m;
    m.addVertex(Vec3(2, 0, 0));  // v0
    m.addVertex(Vec3(2, 1, 0));  // v1
    m.addVertex(Vec3(2, 1, 1));  // v2
    m.addVertex(Vec3(2, 0, 1));  // v3
    m.addEdge(0, 1); m.addEdge(1, 2); m.addEdge(2, 3); m.addEdge(3, 0);
    m.buildLoops();

    // Revolve 360°, 4 steps.
    // Closed sweep: 4 rings × 4 bridge steps × 4 quads/step = 16 faces.
    // Vertex count: ring[0]=4 original + rings[1..3]=3×4 = 4+12 = 16 (no seam dup).
    size_t added = m.revolveProfile([0u, 1u, 2u, 3u], /*profileClosed*/true,
                                    /*count*/4, 'Y', Vec3(0, 0, 0),
                                    cast(float)(2 * PI));
    assert(added == 16,
        "closed 360°: revolveProfile returned " ~ added.to!string ~ ", expected 16");
    assert(m.faces.length == 16,
        "closed 360°: faces.length == " ~ m.faces.length.to!string ~ ", expected 16");
    assert(m.vertices.length == 16,
        "closed 360°: vertices.length == " ~ m.vertices.length.to!string
        ~ " (expected 16, no seam dup)");

    // Manifold: every face-edge must appear exactly twice across all faces.
    int[ulong] edgeInc;
    foreach (fi; 0 .. m.faces.length) {
        const f = m.faces[fi];
        foreach (k; 0 .. f.length) {
            uint a = f[k], b = f[(k + 1) % f.length];
            ulong key = a < b ? (cast(ulong)a << 32) | b
                              : (cast(ulong)b << 32) | a;
            edgeInc[key]++;
        }
    }
    foreach (key, cnt; edgeInc)
        assert(cnt == 2,
            "closed 360°: edge " ~ key.to!string ~ " has incidence " ~ cnt.to!string
            ~ " (expected exactly 2 — surface must be manifold)");

    // Watertight: zero boundary loops.
    auto bLoops = m.boundaryLoops();
    assert(bLoops.length == 0,
        "closed 360°: expected 0 boundary loops, got " ~ bLoops.length.to!string);
}

unittest { // revolveProfile (b): open strip, partial arc — 4 quads, 9 verts, 1 boundary loop
    import std.math : PI;
    import std.conv : to;

    // 3-vert polyline along the X axis; open-strip profile (profileClosed=false).
    // Verts in the y=0 plane: all rotated verts also remain in y=0 (Y-axis rotation
    // preserves y).  Face normals all point in +Y (verified analytically).
    Mesh m;
    m.addVertex(Vec3(1, 0, 0));  // v0
    m.addVertex(Vec3(2, 0, 0));  // v1
    m.addVertex(Vec3(3, 0, 0));  // v2
    m.addEdge(0, 1); m.addEdge(1, 2);
    m.buildLoops();

    // Open 90° arc, 3 copies.
    // stepAngle = (π/2)/(3-1) = π/4.
    // Bridges: (0→1), (1→2).  Each step: M-1 = 2 quads.  Total = 4 quads.
    // Vertex count: 3 original + 2 new rings × 3 = 9.
    size_t added = m.revolveProfile([0u, 1u, 2u], /*profileClosed*/false,
                                    /*count*/3, 'Y', Vec3(0, 0, 0),
                                    cast(float)(PI * 0.5));
    assert(added == 4,
        "open arc 90°: revolveProfile returned " ~ added.to!string ~ ", expected 4");
    assert(m.faces.length == 4,
        "open arc 90°: faces.length == " ~ m.faces.length.to!string ~ ", expected 4");
    assert(m.vertices.length == 9,
        "open arc 90°: vertices.length == " ~ m.vertices.length.to!string
        ~ ", expected 9");

    // All new faces must be quads with globally consistent winding.
    Vec3 refN = m.faceNormal(0);
    foreach (fi; 0 .. m.faces.length) {
        assert(m.faces[fi].length == 4,
            "open arc 90°: face " ~ fi.to!string ~ " is not a quad");
        Vec3 fn = m.faceNormal(cast(uint)fi);
        float dt = fn.x * refN.x + fn.y * refN.y + fn.z * refN.z;
        assert(dt > 0.0f,
            "open arc 90°: face " ~ fi.to!string ~ " has inconsistent winding");
    }

    // Open partial arc: one boundary loop (the rectangular perimeter).
    auto bLoops = m.boundaryLoops();
    assert(bLoops.length == 1,
        "open arc 90°: expected 1 boundary loop (perimeter), got "
        ~ bLoops.length.to!string);
}

unittest { // revolveProfile (c): guard rejections — all must return 0, mesh unchanged
    import std.math : PI;
    import std.conv : to;

    Mesh m;
    m.addVertex(Vec3(1, 0, 0));  // v0
    m.addVertex(Vec3(2, 0, 0));  // v1
    m.addVertex(Vec3(3, 0, 0));  // v2

    immutable float tau = cast(float)(2 * PI);
    uint[] p3 = [0u, 1u, 2u];

    // count < 2
    assert(m.revolveProfile(p3, false, 1, 'Y', Vec3(0,0,0), tau) == 0,
        "guard count<2: expected 0");
    assert(m.faces.length == 0, "guard count<2: mesh must be unchanged");

    // bad axis character
    assert(m.revolveProfile(p3, false, 4, 'W', Vec3(0,0,0), tau) == 0,
        "guard bad axis: expected 0");
    assert(m.faces.length == 0, "guard bad axis: mesh must be unchanged");

    // zero angle
    assert(m.revolveProfile(p3, false, 4, 'Y', Vec3(0,0,0), 0.0f) == 0,
        "guard zero angle: expected 0");
    assert(m.faces.length == 0, "guard zero angle: mesh must be unchanged");

    // profile.length < 2
    assert(m.revolveProfile([0u], false, 4, 'Y', Vec3(0,0,0), tau) == 0,
        "guard profile<2: expected 0");
    assert(m.faces.length == 0, "guard profile<2: mesh must be unchanged");

    // closed profile with < 3 verts
    assert(m.revolveProfile([0u, 1u], true, 4, 'Y', Vec3(0,0,0), tau) == 0,
        "guard closed<3: expected 0");
    assert(m.faces.length == 0, "guard closed<3: mesh must be unchanged");

    // Vertex count must also be untouched: only the 3 verts we added.
    assert(m.vertices.length == 3,
        "guards: vertices.length must remain 3, got " ~ m.vertices.length.to!string);
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
