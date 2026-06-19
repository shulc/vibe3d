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

    // Bring each *SelectionOrderCounter up to the maximum value in its order array.
    // Needed after commands that write *SelectionOrder via a slice on a struct copy
    // (the scalar counters do not propagate back through ref-less copies).
    void syncSelectionCounter() {
        foreach (ord; vertexSelectionOrder)
            if (ord > vertexSelectionOrderCounter) vertexSelectionOrderCounter = ord;
        foreach (ord; edgeSelectionOrder)
            if (ord > edgeSelectionOrderCounter) edgeSelectionOrderCounter = ord;
        foreach (ord; faceSelectionOrder)
            if (ord > faceSelectionOrderCounter) faceSelectionOrderCounter = ord;
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
            }
        }
        faces              = newFaces;
        setFaceSubpatchFrom(newSubpatch);
        faceSelectionOrder = newOrder;
        faceMaterial       = newMaterial;
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
        size_t   removed = 0;
        keptFaces.reserve(faces.length);
        keptSubpatch.reserve(faces.length);
        keptOrder.reserve(faces.length);
        keptMaterial.reserve(faces.length);
        // Class B tracker hook — accumulate the dropped (filtered-out) faces so
        // a RemoveFaces entry can re-insert them on revert. Inert unless a batch
        // is open. Indices are the PRE-filter face indices (the space the entry
        // is inverted in, before the tail compactUnreferenced reindexes verts).
        uint[]   droppedFaceIdx;
        uint[][] droppedFaceLists;
        uint[]   droppedFaceMat;
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
                    droppedFaceSub   ~= (isFaceSubpatch(i) ? 1u : 0u);
                }
                continue;
            }
            keptFaces ~= f;
            keptSubpatch ~= (i < isSubpatch.length        ? isSubpatch[i]        : false);
            keptOrder    ~= (i < faceSelectionOrder.length ? faceSelectionOrder[i] : 0);
            keptMaterial ~= (i < faceMaterial.length      ? faceMaterial[i]      : 0u);
            if (remapUv)
                foreach (c; 0 .. f.length)
                    oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)i, cast(uint)c);
        }
        if (removed == 0) return 0;
        if (recDelete)
            editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                            droppedFaceMat, droppedFaceSub);
        faces              = keptFaces;
        setFaceSubpatchFrom(keptSubpatch);
        faceSelectionOrder = keptOrder;
        faceMaterial       = keptMaterial;
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
        newFaces.reserve(faces.length);
        newSubpatch.reserve(faces.length);
        newOrder.reserve(faces.length);
        newMaterial.reserve(faces.length);
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
                if (remapUv)
                    foreach (kc; keptCorner)
                        oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, kc);
            } else if (recDis) {
                // Degenerate face dropped — reconstruct it on revert at its
                // post-shrink position in the new face array.
                removedFaceIdx   ~= cast(uint)newFaces.length;
                removedFaceLists ~= f.dup;
                removedFaceMat   ~= (fi < faceMaterial.length ? faceMaterial[fi] : 0u);
                removedFaceSub   ~= (isFaceSubpatch(fi) ? 1u : 0u);
            }
        }
        if (recDis) {
            // Reshape first, then RemoveFaces — on revert (LIFO) the dropped
            // faces are re-inserted FIRST, then the reshape lists are restored,
            // matching the post-shrink index space both were recorded in.
            editRecorder_.recordReshapeFaces(reshapeIdx, reshapeBefore, reshapeAfter);
            editRecorder_.recordRemoveFaces(removedFaceIdx, removedFaceLists,
                                            removedFaceMat, removedFaceSub);
        }
        faces              = newFaces;
        setFaceSubpatchFrom(newSubpatch);
        faceSelectionOrder = newOrder;
        faceMaterial       = newMaterial;
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
        int[2][ulong] edgeFaces;   // -1 = empty slot
        foreach (fi; 0 .. nFaces) {
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                ulong key = edgeKeyOrdered(f[k], f[(k + 1) % f.length]);
                auto p = key in edgeFaces;
                if (p is null)
                    edgeFaces[key] = [cast(int)fi, -1];
                else if ((*p)[1] == -1 && (*p)[0] != cast(int)fi)
                    (*p)[1] = cast(int)fi;
            }
        }

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
        uint[]   droppedFaceSub;
        uint[][] keptFaces;
        bool[]   keptSubpatch;
        int[]    keptOrder;
        uint[]   keptMaterial;
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
                    droppedFaceSub   ~= (isFaceSubpatch(cast(uint)fi) ? 1u : 0u);
                }
                continue;
            }
            keptFaces ~= faces[fi];
            keptSubpatch ~= (fi < isSubpatch.length        ? isSubpatch[fi]        : false);
            keptOrder    ~= (fi < faceSelectionOrder.length ? faceSelectionOrder[fi] : 0);
            keptMaterial ~= (fi < faceMaterial.length      ? faceMaterial[fi]      : 0u);
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
            // Merged poly corners → the old loop traced during the boundary
            // walk (~0u where the walk could not trace a source) (b).
            if (remapUv) oldLoopOfNewLoop ~= newPolySrcLoop[i];
        }
        if (recRemoveEdges) {
            // RemoveFaces FIRST, then AddFaces — on revert (LIFO) the appended
            // merged polys truncate FIRST (restoring the kept-only array), then
            // the dropped component faces re-insert into the post-drop space.
            editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                            droppedFaceMat, droppedFaceSub);
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
        int[2][ulong] edgeFaces;
        foreach (fi; 0 .. faces.length) {
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                ulong key = edgeKeyOrdered(f[k], f[(k + 1) % f.length]);
                auto p = key in edgeFaces;
                if (p is null)
                    edgeFaces[key] = [cast(int)fi, -1];
                else if ((*p)[1] == -1 && (*p)[0] != cast(int)fi)
                    (*p)[1] = cast(int)fi;
            }
        }

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
        int[2][ulong] edgeFaces;
        foreach (fi; 0 .. faces.length) {
            auto f = faces[fi];
            foreach (k; 0 .. f.length) {
                ulong key = edgeKeyOrdered(f[k], f[(k + 1) % f.length]);
                auto p = key in edgeFaces;
                if (p is null)
                    edgeFaces[key] = [cast(int)fi, -1];
                else if ((*p)[1] == -1 && (*p)[0] != cast(int)fi)
                    (*p)[1] = cast(int)fi;
            }
        }

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
            uint mat = (orientFace < faceMaterial.length
                        ? faceMaterial[orientFace] : 0u);
            foreach (k; 1 .. N + 1) {
                faceMaterial       ~= mat;
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
        foreach (fi; 0 .. origFaceCount) {
            deselectFace(cast(int)fi);
        }
        faceSelectionOrderCounter = 0;
        foreach (idx; newFaceIndices) {
            size_t srcFi = sourceFaces[(idx - origFaceCount) % selCount];
            setFaceSubpatch(idx, (srcFi < isSubpatch.length ? isSubpatch[srcFi] : false));
            faceMaterial[idx] = (srcFi < faceMaterial.length ? faceMaterial[srcFi] : 0u);
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
                keptFaces   .reserve(faces.length);
                keptSubpatch.reserve(faces.length);
                keptOrder   .reserve(faces.length);
                keptSelected.reserve(faces.length);
                keptMaterial.reserve(faces.length);
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
                }
                faces              = keptFaces;
                setFaceSubpatchFrom(keptSubpatch);
                faceSelectionOrder = keptOrder;
                setFacesSelectedFrom(keptSelected);
                faceMaterial       = keptMaterial;
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
                keptFaces   .reserve(faces.length);
                keptSubpatch.reserve(faces.length);
                keptOrder   .reserve(faces.length);
                keptSelected.reserve(faces.length);
                keptMaterial.reserve(faces.length);
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
                }
                faces              = keptFaces;
                setFaceSubpatchFrom(keptSubpatch);
                faceSelectionOrder = keptOrder;
                setFacesSelectedFrom(keptSelected);
                faceMaterial       = keptMaterial;
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
                keptFaces   .reserve(faces.length);
                keptSubpatch.reserve(faces.length);
                keptOrder   .reserve(faces.length);
                keptSelected.reserve(faces.length);
                keptMaterial.reserve(faces.length);
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
                }
                faces              = keptFaces;
                setFaceSubpatchFrom(keptSubpatch);
                faceSelectionOrder = keptOrder;
                setFacesSelectedFrom(keptSelected);
                faceMaterial       = keptMaterial;

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
        // Clear old face selection first; only new duplicates remain selected.
        foreach (fi; 0 .. origFaceCount) {
            deselectFace(cast(int)fi);
        }
        faceSelectionOrderCounter = 0;
        foreach (k, fi; toClone) {
            size_t newFi = origFaceCount + k;
            setFaceSubpatch(newFi, (fi < isSubpatch.length ? isSubpatch[fi] : false));
            faceMaterial[newFi] = (fi < faceMaterial.length ? faceMaterial[fi] : 0u);
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

    private static ulong edgeKeyOrdered(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32) | b : (cast(ulong)b << 32) | a;
    }

    void addEdge(uint a, uint b) {
        ulong key = edgeKey(a, b);
        if (key in edgeIndexMap) return;
        edgeIndexMap[key] = cast(uint)edges.length;
        edges ~= [a, b];
        commitChange(MeshEditScope.Polygons);
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
        commitChange(MeshEditScope.Geometry);
        // Class P tracker hook — inert unless a batch is open.
        if (editRecorder_ !is null)
            editRecorder_.recordAddFace(cast(uint)(faces.length - 1), idx);
    }
    // Fast version using hash lookup for duplicate checking
    void addFaceFast(ref uint[ulong] edgeLookup, uint[] idx) {
        faces ~= idx.dup;
        for (uint i = 0; i < idx.length; i++) {
            uint a = idx[i];
            uint b = idx[(i+1) % idx.length];
            ulong key = edgeKey(a, b);
            if (key !in edgeLookup) {
                edges ~= [a, b];
                edgeLookup[key] = cast(uint)(edges.length - 1);
            }
        }
        // GAP-3 atomic append — see addFace.
        growPolyVertexMapsForAppendedCorners(idx.length);
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
        foreach (i, s; src) {
            const cur = (vertexMarks[i] & Marks.Select) != 0;
            if (cur != s) changed = true;
            if (s) vertexMarks[i] |=  Marks.Select;
            else   vertexMarks[i] &= ~Marks.Select;
        }
        if (changed) noteSelectionChange(SelDomain.Vertex);
    }
    void setEdgesSelectedFrom(const bool[] src) {
        bool changed = (edgeMarks.length != src.length);
        edgeMarks.length = src.length;
        foreach (i, s; src) {
            const cur = (edgeMarks[i] & Marks.Select) != 0;
            if (cur != s) changed = true;
            if (s) edgeMarks[i] |=  Marks.Select;
            else   edgeMarks[i] &= ~Marks.Select;
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
        foreach (i, s; src) {
            const cur = (faceMarks[i] & Marks.Select) != 0;
            if (cur != s) changed = true;
            if (s) faceMarks[i] |=  Marks.Select;
            else   faceMarks[i] &= ~Marks.Select;
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

    /// Return a hash of the current vertex selection state (seed = 0).
    /// Useful for detecting selection changes between frames.
    uint selectionHashVertices() const {
        uint h = 0;
        foreach (i, s; selectedVertices) if (s) h = h * 31 + cast(uint)i;
        return h;
    }

    /// Return a hash of the current edge selection state (seed = 1).
    uint selectionHashEdges() const {
        uint h = 1;
        foreach (i, s; selectedEdges) if (s) h = h * 31 + cast(uint)i;
        return h;
    }

    /// Return a hash of the current face selection state (seed = 2).
    uint selectionHashFaces() const {
        uint h = 2;
        foreach (i, s; selectedFaces) if (s) h = h * 31 + cast(uint)i;
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
        int[] edgeLoopA = new int[](edges.length);
        int[] edgeLoopB = new int[](edges.length);
        edgeLoopA[] = -1;
        edgeLoopB[] = -1;
        foreach (idx; 0 .. total) {
            uint ei = loopEdge[idx];
            if (ei == ~0u) continue;
            if (edgeLoopA[ei] == -1) edgeLoopA[ei] = cast(int)idx;
            else                     edgeLoopB[ei] = cast(int)idx;
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
        bool hasBoundary = false;
        foreach (ei; 0 .. edges.length) {
            if (edgeLoopA[ei] != -1 && edgeLoopB[ei] == -1) {
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
    void drawEdges(GLint locColor, int hoveredEdge, const bool[] selectedEdges) {
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
            return hoveredEdge >= 0 && cageOf(segIdx) == hoveredEdge;
        }

        // "All selected" shortcut is only safe when VBO segments are 1:1 with
        // cage edges (cage mode). Skip it in preview mode.
        bool allEdgesSelected = !preview
            && selectedEdges.length >= edgeCount
            && hoveredEdge < 0;
        if (allEdgesSelected)
            foreach (s; selectedEdges[0 .. edgeCount]) if (!s) { allEdgesSelected = false; break; }

        // Gray pass — depth-tested, skip hovered/selected segments.
        glUniform3f(locColor, 0.9f, 0.9f, 0.9f);
        if (hoveredEdge < 0 && selectedEdges.length == 0) {
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

        if (hoveredEdge >= 0) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            if (preview) {
                // A hovered cage edge fans out to every VBO segment tracing
                // back to it.
                for (int i = 0; i < edgeCount; i++)
                    if (segHovered(i))
                        glDrawArrays(GL_LINES, i * 2, 2);
            } else if (hoveredEdge < edgeCount) {
                glDrawArrays(GL_LINES, hoveredEdge * 2, 2);
            }
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
