module mesh;

import bindbc.opengl;
import std.math : sqrt;
import std.parallelism : parallel;
import std.range : iota;
import math;
import shader;
import editmode : EditMode;
import mesh_edit_delta : MeshEditTracker, MeshEditScope;
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

/// Flat per-mesh surface (LightWave-style "material"). One face references
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
///   PolyVertex — one value-tuple per face-corner (per-loop). RESERVED: not
///                implemented in v1. Corner-domain channels need a stable
///                corner enumeration that survives topology edits (loops are
///                rebuilt wholesale by `buildLoops`), so `addMeshMap` rejects
///                this domain with a clear message rather than half-wiring it.
enum MapDomain {
    Point,
    Edge,
    PolyVertex,
}

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

    // --- Mesh maps (generic per-element float attribute channels) ----------
    // Named, typed per-element float channels (UV, vertex weight, edge crease,
    // vertex color, …). ONE reusable home so each new continuous per-element
    // attribute does not become a bespoke parallel array. Each `MeshMap`'s
    // `data` runs parallel to the element array named by its `domain` (Point ↔
    // vertices, Edge ↔ edges) and is kept length-correct in lock-step with
    // topology by `resizeMeshMaps`, hooked into the same resize primitives the
    // selection/marks arrays use (`resizeVertexSelection` / `resizeEdgeSelection`).
    //
    // NOTE: maps are RESIZED (not value-remapped) across destructive edits that
    // renumber elements (weld / delete / dissolve). Length stays correct so
    // reads never go out of bounds, but values do not follow vertices to their
    // new indices — full value-remapping is out of scope for v1.
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
        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
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
        if (any) { ++mutationVersion; ++topologyVersion; }
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

        uint[][] newFaces;
        newFaces.reserve(faces.length);
        foreach (ref face; faces) {
            uint[] f;
            f.reserve(face.length);
            foreach (vid; face) {
                uint mapped = (vid < remap.length) ? cast(uint)remap[vid] : vid;
                if (f.length == 0 || f[$ - 1] != mapped) f ~= mapped;
            }
            // Wrap-around dup: last == first means the face cycles back to
            // its start through a remapped corner.
            if (f.length > 1 && f[$ - 1] == f[0]) f = f[0 .. $ - 1];
            if (f.length >= 3) newFaces ~= f;
        }
        faces = newFaces;

        rebuildEdges();

        clearEdgeSelectionResize();
        // Face selection is potentially invalidated (face indices changed
        // since collapsed faces are removed). Caller may re-derive.
        if (selectedFaces.length > faces.length) resizeFaceSelection();
        if (faceSelectionOrder.length > faces.length) faceSelectionOrder.length = faces.length;
        if (isSubpatch.length > faces.length) resizeSubpatch();
        if (faceMaterial.length > faces.length) faceMaterial.length = faces.length;

        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
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
        }
        if (removed == 0) return 0;
        if (recDelete)
            editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                            droppedFaceMat, droppedFaceSub);
        faces              = keptFaces;
        setFaceSubpatchFrom(keptSubpatch);
        faceSelectionOrder = keptOrder;
        faceMaterial       = keptMaterial;
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
        ++mutationVersion; ++topologyVersion;
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
        foreach (fi, ref f; faces) {
            uint[] kept;
            foreach (vid; f) {
                if (vid < mask.length && mask[vid]) continue;
                kept ~= vid;
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
        ++mutationVersion; ++topologyVersion;
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
        foreach (root, comp; componentFaces) {
            if (comp.length < 2) continue;

            // Gather directed half-edges from the component, dropping
            // half-edges whose edge was actually dissolved (interior); selected
            // boundary edges survive on the merged boundary.
            uint[][uint] outAt;  // outAt[u] = list of `v` for each surviving u→v
            foreach (fi; comp) {
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    uint a = f[k], b = f[(k + 1) % f.length];
                    if (edgeKeyOrdered(a, b) in dissolvedEdgeKeys) continue;
                    outAt[a] ~= b;
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
            uint cur = startV;
            while (true) {
                poly ~= cur;
                auto p = cur in outAt;
                if (p is null || (*p).length == 0) break;
                uint nxt = (*p)[0];
                *p = (*p)[1 .. $];
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
        }
        // Tail range start = number of kept (non-dropped) faces.
        const size_t firstMerged = keptFaces.length;
        foreach (i; 0 .. newPolyList.length) {
            keptFaces    ~= newPolyList[i];
            keptSubpatch ~= newPolySubpatch[i];
            keptOrder    ~= newPolyOrder[i];
            keptMaterial ~= newPolyMaterial[i];
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
        clearFaceSelectionResize();

        // Rebuild edges + compact orphan verts.
        rebuildEdges();
        clearEdgeSelectionResize();
        compactUnreferenced();
        // See deleteFacesByMask: loops carry stale indices after face/vert
        // compaction.
        buildLoops();
        ++mutationVersion; ++topologyVersion;
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

        // --- Anti-normal inset vert per boundary chamfer end. The second chamfer
        //     inset is the endpoint pushed back along the NEGATIVE face normal of
        //     its sole neighbour face F by `width`. (The in-plane topInset is
        //     insetVert[(v,F)], already made above.) This vert sits on the open
        //     boundary; the side-face rewrite below pairs it with the topInset.
        uint[uint] chamferAntiInset;       // boundary chamfer end v → anti-normal inset vert
        foreach (v, fF; chamferNeighborFace) {
            Vec3 nf = faceNormal(cast(uint)fF);
            chamferAntiInset[v] = addVertex(vertices[v] - nf * width);
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
                // sole neighbour face F): dissolve the corner into its two chamfer
                // insets [topInset, antiNormalInset]. The incident edge that is
                // ALSO an edge of F carries the in-plane topInset; the open-boundary
                // edge carries the anti-normal inset, so the pair is ordered to keep
                // F's inset adjacent to the F-shared edge. F itself keeps just the
                // topInset (the affected-face rewrite handled that above) → quad.
                if (isChamferEnd(c) && chamferNeighborFace[c] != cast(int)fi) {
                    uint prevB = f[(k + f.length - 1) % f.length];
                    uint nextB = f[(k + 1) % f.length];
                    int fF = chamferNeighborFace[c];
                    bool edgeInF(uint a, uint b) {
                        auto p = edgeKeyOrdered(a, b) in edgeFaces;
                        if (p is null) return false;
                        return (*p)[0] == fF || (*p)[1] == fF;
                    }
                    uint top  = insetVert[(cast(ulong)c << 32) | cast(uint)fF];
                    uint anti = chamferAntiInset[c];
                    // If the incoming edge (prev,c) is shared with F, top goes
                    // first (adjacent to prev); otherwise the outgoing edge is the
                    // F-shared one and top goes last (adjacent to next).
                    if (edgeInF(prevB, c)) { rebuilt ~= top; rebuilt ~= anti; }
                    else                    { rebuilt ~= anti; rebuilt ~= top; }
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

        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
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
        ++mutationVersion; ++topologyVersion;
        // Class P tracker hook — inert unless a batch is open.
        if (editRecorder_ !is null)
            editRecorder_.recordAddFace(cast(uint)(faces.length - 1), idx);
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
            ++mutationVersion; ++topologyVersion;
        }
    }
    void clearSubpatch() {
        bool any = false;
        foreach (m; faceMarks) if (m & Marks.Subpatch) { any = true; break; }
        // Mask ONLY the Subpatch bit — Select shares this word.
        foreach (ref m; faceMarks) m &= ~Marks.Subpatch;
        if (any) { ++mutationVersion; ++topologyVersion; }
    }

    void clearVertexSelection() {
        foreach (ref m; vertexMarks) m &= ~Marks.Select;
        vertexSelectionOrder[] = 0;
        vertexSelectionOrderCounter = 0;
    }
    void clearEdgeSelection() {
        foreach (ref m; edgeMarks) m &= ~Marks.Select;
        edgeSelectionOrder[] = 0;
        edgeSelectionOrderCounter = 0;
    }
    void clearFaceSelection() {
        // Mask ONLY the Select bit — Subpatch shares this word and must
        // survive a selection clear.
        foreach (ref m; faceMarks) m &= ~Marks.Select;
        faceSelectionOrder[] = 0;
        faceSelectionOrderCounter = 0;
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
        if (domain == MapDomain.PolyVertex) {
            // RESERVED — see MapDomain.PolyVertex. Corner-domain channels are
            // not implemented in v1; reject rather than half-wire them.
            return null;
        }
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
        ++mutationVersion;
        return true;
    }

    // Resize the per-edge arrays to `edges` length and drop every edge
    // selection bit. The pick-order array is resized but NOT zeroed and the
    // counter is left alone (callers that reach here have already replaced the
    // topology, so surviving order values are stale-but-harmless) — this is
    // the exact triplet the topology mutators ran after a `rebuildEdges()`.
    void clearEdgeSelectionResize() {
        resizeEdgeSelection();
        foreach (ref m; edgeMarks) m &= ~Marks.Select;
    }

    // Resize the per-face selection-bit array to `faces` length and drop every
    // face selection bit. The pick-order / subpatch / material arrays are
    // managed by the caller. Extracted from the identical pair the topology
    // mutators ran after assigning a freshly filtered `faces` array.
    void clearFaceSelectionResize() {
        resizeFaceSelection();
        // Mask ONLY the Select bit — Subpatch shares this word and the
        // calling mutator has already written it (B3 ordering).
        foreach (ref m; faceMarks) m &= ~Marks.Select;
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
    void setVerticesSelectedFrom(const bool[] src) {
        vertexMarks.length = src.length;
        foreach (i, s; src) {
            if (s) vertexMarks[i] |=  Marks.Select;
            else   vertexMarks[i] &= ~Marks.Select;
        }
    }
    void setEdgesSelectedFrom(const bool[] src) {
        edgeMarks.length = src.length;
        foreach (i, s; src) {
            if (s) edgeMarks[i] |=  Marks.Select;
            else   edgeMarks[i] &= ~Marks.Select;
        }
    }
    void setFacesSelectedFrom(const bool[] src) {
        // Resize once, then touch ONLY the Select bit so this stays
        // order-independent with setFaceSubpatchFrom (B4 — snapshot restore
        // writes Select and Subpatch as two separate assigns). Resizing
        // preserves the Subpatch bit of any pre-existing entries.
        faceMarks.length = src.length;
        foreach (i, s; src) {
            if (s) faceMarks[i] |=  Marks.Select;
            else   faceMarks[i] &= ~Marks.Select;
        }
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
    }
    void deselectVertex(int idx) {
        vertexMarks[idx] &= ~Marks.Select;
        vertexSelectionOrder[idx] = 0;
    }

    void selectEdge(int idx) {
        if ((edgeMarks[idx] & Marks.Select) == 0)
            edgeSelectionOrder[idx] = ++edgeSelectionOrderCounter;
        edgeMarks[idx] |= Marks.Select;
    }
    void deselectEdge(int idx) {
        edgeMarks[idx] &= ~Marks.Select;
        edgeSelectionOrder[idx] = 0;
    }

    void selectFace(int idx) {
        if ((faceMarks[idx] & Marks.Select) == 0)
            faceSelectionOrder[idx] = ++faceSelectionOrderCounter;
        faceMarks[idx] |= Marks.Select;
    }
    void deselectFace(int idx) {
        faceMarks[idx] &= ~Marks.Select;
        faceSelectionOrder[idx] = 0;
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
private __gshared bool maxStepsWarned = false;
private void warnMaxStepsExceeded(string rangeName) nothrow {
    if (maxStepsWarned) return;
    maxStepsWarned = true;
    try {
        import std.stdio : stderr;
        stderr.writefln(
            "[mesh] %s: MAX_STEPS exceeded — non-manifold cage edges " ~
            "(walk truncated; selection / loop ops may be incomplete).",
            rangeName);
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

    import subpatch_osd : GpuFanOutTargets;

    /// `targets` (when non-null) wires the GPU fan-out path: the
    /// position-only fast path attempts face, edge, vert dispatches
    /// in order, only doing the CPU readback fallback for the
    /// pieces that didn't make it onto GPU. Caller (app.d main loop)
    /// supplies gpu.{face,edge,vert}Vbo + matching counts.
    void rebuildIfStale(ref const Mesh source, int d,
                         const(GpuFanOutTargets)* targets = null) {
        lastRefreshFannedOut    = false;
        lastRefreshSkipNonFace  = false;
        if (sourceVersion == source.mutationVersion && depth == d)
            return;
        // Position-only fast path: cage topology + depth unchanged →
        // ask OSD's stencil table for new limit positions.
        if (active
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
            sourceVersion = source.mutationVersion;
            return;
        }
        rebuild(source, d);
    }

    void rebuild(ref const Mesh source, int d) {
        depth                 = d;
        sourceVersion         = source.mutationVersion;
        sourceTopologyVersion = source.topologyVersion;
        cageVertPreview.length = 0;
        osdAccel.clear();
        if (d <= 0 || !source.hasAnySubpatch()) {
            mesh   = Mesh.init;
            trace  = SubpatchTrace.init;
            active = false;
            return;
        }

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
            return;
        }

        active = true;
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
