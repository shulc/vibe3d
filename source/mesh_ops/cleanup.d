module mesh_ops.cleanup;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshCleanupOps — mesh hygiene + orientation-repair kernel family
// (computeDuplicateFaceMask / unifyFaces / CollapsedFace_ /
// computeCollapsedFace_ / isFaceDegenerate / cleanDegenerateFaces /
// cleanupMesh / fixFaceOrientation / computeOrientationFlipMask (both
// overloads) / faceAreaApprox_), mixed into struct Mesh (source/mesh.d) via
// `mixin MeshCleanupOps;`. `cleanupMesh`'s parameter/return types,
// `CleanupOptions`/`CleanupResult`, stay in mesh.d (core) rather than moving
// here: they are constructed directly by an EXTERNAL file,
// `source/commands/mesh/cleanup.d` (`CleanupOptions opts;`), so moving them
// would force an import change in that file — out of scope for a
// pure-internal mixin refactor, and the same "leave genuinely external-
// facing symbols in core" call already made for a handful of low-level
// helpers in the task-0412 pilot. `cleanupMesh`'s own calls to
// `weldCoincidentVertices`/`dissolveDegree2Verts`/`compactUnreferenced`
// resolve normally — all three are core methods shared by several other,
// not-yet-extracted families.
//
// Two mesh.d symbols were widened from `private` to module-visible so the
// unittest blocks below (module-level code, NOT inside the mixin template —
// unlike kernel method bodies, they get no instantiation-site transparency
// into Mesh's private members) can still reach them: `uintToStr` (a shared
// assert-message formatter also used by a weld-family test that stays in
// mesh.d) and `Mesh.makePolyVertexSetMatch_` (the unifyFaces hash-bucket
// test's O(F²) reference oracle, owned by the not-yet-extracted
// makePolygonFromVerts family). Both are documented at their mesh.d
// definitions.
//
// Split out of mesh.d as part of the mesh.d decomposition campaign (0407
// §B.V2, task 0417 — continuation of the task-0412 plane-cut pilot and this
// same task's bridge/loop-slice/decimate/revolve extractions; see task
// 0412's doc for the architectural decision: mixin template over a package
// move or UFCS free-functions). Method bodies below are verbatim cut/paste
// from mesh.d (only the extraction boundary is new).
// ---------------------------------------------------------------------------
mixin template MeshCleanupOps() {
    // ---------------------------------------------------------------------------
    // Mesh hygiene kernels
    // ---------------------------------------------------------------------------

    /// Drop faces whose unordered vertex set equals an earlier face (duplicate
    /// faces). The first occurrence (lowest face index) is kept; all later
    /// duplicates are removed. Winding order is ignored — two faces with the same
    /// vertices in reversed order are considered duplicates. Returns the number of
    /// faces removed, or 0 if the mesh had no duplicate faces.
    /// Read-only: which faces are a LATER occurrence of an earlier face's
    /// unordered vertex set (see `unifyFaces`'s doc comment for the
    /// canonical-key / "first occurrence kept" contract). Shared by the
    /// mutating dedup pass and the read-only Cleanup detector
    /// (`mesh_analysis.duplicateFaceIndices`, task 0402 Phase 4 risk #2).
    bool[] computeDuplicateFaceMask() const {
        import std.algorithm.sorting : sort;
        bool[] mask;
        mask.length = faces.length;
        bool[immutable(uint)[]] seen;
        foreach (i; 0 .. faces.length) {
            uint[] key = faces[i][].dup;
            sort(key);
            immutable(uint)[] ikey = key.idup;
            if (ikey in seen) {
                mask[i] = true;  // later occurrence of an already-seen vertex set
            } else {
                seen[ikey] = true;
            }
        }
        return mask;
    }

    size_t unifyFaces() {
        if (faces.length < 2) return 0;
        // Canonical key = the face's vertex indices sorted ascending. Two
        // faces are duplicates iff they carry the same UNORDERED vertex
        // multiset — sorting captures that regardless of winding direction
        // (reversed order) or starting corner, matching
        // makePolyVertexSetMatch_'s semantics exactly (same idiom as the
        // `bool[immutable(uint)[]]` sorted-key dedup used by
        // collectEdgeRing's seenRingKey above). Faces are grouped by key in
        // one O(F log k) pass (k = per-face arity) instead of the former
        // O(F²) pairwise makePolyVertexSetMatch_ scan — task 0396, a 50k-face
        // ai3d-import mesh hung here. Visiting faces in ascending index order
        // means the first occurrence of a key is always the lowest index,
        // preserving the documented "first occurrence kept" contract.
        bool[] mask = computeDuplicateFaceMask();
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
    /// Result of collapsing face `fi`'s consecutive-duplicate (+ wrap-around
    /// dup) vertex indices, and testing whether the collapsed face would be
    /// DROPPED by `cleanDegenerateFaces` (fewer than 3 distinct entries, or
    /// a near-zero Newell-normal magnitude < 1e-6). `srcCorner[k]` is the
    /// ORIGINAL corner index that produced `collapsed[k]` (needed by the
    /// mutating pass's PolyVertex/UV remap).
    private struct CollapsedFace_ {
        uint[] collapsed;
        uint[] srcCorner;
        bool   degenerate;
    }

    /// Shared by the mutating `cleanDegenerateFaces` and the read-only
    /// Cleanup detector (`mesh_analysis.degenerateFaceIndices`, task 0402
    /// Phase 4 risk #2) so the two can never drift apart — this is exactly
    /// the per-face collapse + degenerate test `cleanDegenerateFaces` used
    /// to inline, unchanged.
    private CollapsedFace_ computeCollapsedFace_(uint fi) const {
        const uint[] face = faces[fi];
        uint[] f;
        uint[] srcCorner;
        f.reserve(face.length);
        srcCorner.reserve(face.length);
        foreach (k, vid; face) {
            if (f.length == 0 || f[$ - 1] != vid) {
                f ~= vid;
                srcCorner ~= cast(uint)k;
            }
        }
        while (f.length >= 2 && f[$ - 1] == f[0]) {
            f = f[0 .. $ - 1];
            if (srcCorner.length > 0) srcCorner = srcCorner[0 .. $ - 1];
        }

        if (f.length < 3) return CollapsedFace_(f, srcCorner, true);

        // Newell normal magnitude test (identical to makePolygonFromVerts
        // step 4 — NOT faceNormal(), which normalizes and can't distinguish
        // zero-area from finite-area faces).
        float nx = 0, ny = 0, nz = 0;
        foreach (i; 0 .. f.length) {
            Vec3 a = vertices[f[i]];
            Vec3 b = vertices[f[(i + 1) % f.length]];
            nx += (a.y - b.y) * (a.z + b.z);
            ny += (a.z - b.z) * (a.x + b.x);
            nz += (a.x - b.x) * (a.y + b.y);
        }
        float len = sqrt(nx*nx + ny*ny + nz*nz);
        return CollapsedFace_(f, srcCorner, len < 1e-6f);
    }

    /// Read-only: true when face `fi` would be DROPPED by
    /// `cleanDegenerateFaces` — fewer than 3 distinct vertices after
    /// consecutive-duplicate collapse, or a near-zero Newell-normal area.
    /// Does not mutate the mesh.
    bool isFaceDegenerate(uint fi) const {
        return computeCollapsedFace_(fi).degenerate;
    }

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
            // Collapse consecutive duplicate vertex indices (+ wrap-around
            // dup) and test degeneracy via the shared helper (task 0402
            // Phase 4 risk #2 — the read-only Cleanup detector calls the
            // SAME `computeCollapsedFace_`/`isFaceDegenerate`, so this
            // mutating pass and that detector can never drift apart).
            auto cf = computeCollapsedFace_(cast(uint)fi);
            uint[] f         = cf.collapsed;
            uint[] srcCorner = cf.srcCorner;  // original corner index for each kept entry

            if (cf.degenerate) {
                ++removed;
                continue;
            }

            // Face is kept; count it as fixed if its arity changed.
            if (f.length != face.length) ++fixed;
            newFaces    ~= f;
            // isFaceSubpatch(fi), not the allocating `isSubpatch` @property —
            // same O(F²)-in-a-loop trap as deleteFacesByMask above (task 0396).
            newSubpatch ~= isFaceSubpatch(fi);
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
    // Fix Orientation — winding-consistency repair (task 0394 Part B)
    // -----------------------------------------------------------------------

    /// Heal inconsistently-wound faces (already-corrupt imports/old saves, or
    /// hand-built geometry from before `makePolygonFromVerts`' adjacency
    /// auto-orient) by making every manifold-adjacent face pair traverse their
    /// shared edge in OPPOSITE directions, propagated outward from a
    /// per-component seed — the same connected-component / BFS-propagation
    /// shape reference-editor "Recalculate Normals" repairs use:
    ///
    ///   1. Partition faces into connected components, crossing ONLY manifold
    ///      edges (an edge with exactly 2 incident faces — `twin != ~0u`
    ///      after `buildLoops`, which also excludes non-manifold ≥3-face
    ///      edges via the existing Treatment-A boundary-like reset).
    ///      Boundary and non-manifold edges are hard component borders —
    ///      never crossed, so a locally-inconsistent OTHER component can't
    ///      poison this one.
    ///   2. Seed each component outward: area-weighted centroid over the
    ///      component's faces; the CORNER (not just vertex — a specific
    ///      face's loop) farthest from that centroid anchors the seed face.
    ///      Using the outermost corner rather than a face centroid survives
    ///      thin spikes / concave components. `loopNormal = cross(edge to
    ///      next corner, edge to prev corner)`; the seed is flagged
    ///      already-inverted when that local normal points back toward the
    ///      centroid (`dot(corner − centroid, loopNormal) < 0`).
    ///   3. BFS outward from the seed across manifold edges. For a shared
    ///      edge between the current face and a neighbor, `sameDirShared`
    ///      is true when the two faces' loops on that edge start at the SAME
    ///      vertex (`loops[twin(li)].vert == loops[li].vert`) — the exact
    ///      corruption signature from the `makePolygonFromVerts` bug and the
    ///      `EdgeFaceRange` consumer-hardening fix above. The neighbor's flip
    ///      bit is `sameDirShared XOR currentFlip`: reversing exactly one of
    ///      two same-direction-sharing faces restores the opposite-direction
    ///      manifold invariant; reversing neither or both leaves it as-is.
    ///   4. Apply via `flipFacesByMask`, which already reverses each flagged
    ///      face's vertex cycle AND remaps any PolyVertex (UV) per-corner
    ///      data to follow the new corner order, then rebuilds loops. Face
    ///      SLOTS are never added/removed/reordered — only `faces[fi]`'s
    ///      internal vertex order changes — so `faceMarks` (subpatch/select),
    ///      `faceMaterial`, and `facePart`, all indexed by face slot, stay
    ///      correctly aligned across the flip with no remapping needed.
    ///
    /// If any face is currently selected, only the components CONTAINING a
    /// selected face are processed — components with no selected face are
    /// left completely untouched — the same selection-restricted behavior
    /// reference-editor Recalculate Normals repairs use. With no selection
    /// anywhere, every component in the mesh is processed.
    ///
    /// Returns the number of faces whose winding was reversed (0 = no-op).
    /// A well-formed mesh (every manifold pair already opposite-direction,
    /// every seed already outward-facing) returns 0; `flipFacesByMask`
    /// short-circuits before its own `buildLoops()`/`commitChange()` in that
    /// case, so the mesh is left byte-identical, not just semantically equal.
    size_t fixFaceOrientation() {
        buildLoops();   // ensure loops/twin/faceLoop reflect the current faces[]
        if (faces.length == 0) return 0;
        return flipFacesByMask(computeOrientationFlipMask());
    }

    /// Read-only: passes 1-3 of `fixFaceOrientation` — connected-component
    /// (manifold-BFS) partition, area-weighted-centroid/farthest-corner
    /// seed, and BFS-propagated flip parity — WITHOUT applying the flip.
    /// Returns a per-face mask: `true` at `fi` means `fixFaceOrientation`
    /// would reverse that face's winding. Shared by the mutating fix and the
    /// read-only Topology detector (`mesh_analysis.inconsistentWindingFaces`,
    /// task 0402 Phase 4 risk #2) so the two can never drift apart. See
    /// `fixFaceOrientation`'s doc comment for the full algorithm rationale.
    /// PRECONDITION: `loops`/`faceLoop`/`vertLoop` must already reflect the
    /// current `faces` (i.e. `buildLoops()` has been called since the last
    /// topology edit) — same precondition as `computeEdgeSharpness`/
    /// `boundaryLoops`/`buildEdgeFaces`. Does NOT call `buildLoops()` itself
    /// (that would require a non-`const` `this`); `fixFaceOrientation` calls
    /// it explicitly before reaching here.
    bool[] computeOrientationFlipMask() const {
        // Mutating fixFaceOrientation() historically restricts to the selection
        // when faces are selected. The read-only Topology detector wants the
        // WHOLE mesh regardless of selection, so it calls the bool overload
        // with restrictToSelection=false (task 0402 Phase 4, review S2).
        return computeOrientationFlipMask(hasAnySelectedFaces());
    }

    /// ditto, with an explicit selection-restriction flag: `fixFaceOrientation`
    /// passes `hasAnySelectedFaces()` (its historical behavior); the Phase-4
    /// Topology detector passes `false` so an analyze under an active selection
    /// still reports winding problems in unselected components.
    bool[] computeOrientationFlipMask(bool restrictToSelection) const {
        const size_t nf = faces.length;
        bool[] flipMask = new bool[](nf); // final flip decision
        if (nf == 0) return flipMask;

        bool[] partitioned   = new bool[](nf); // assigned to a component yet?
        bool[] flipComputed  = new bool[](nf); // flip parity decided?

        uint[] compQueue, bfsQueue;

        foreach (startFi; 0 .. nf) {
            if (partitioned[cast(uint)startFi]) continue;

            // --- Pass 1: discover the connected component (manifold BFS). ---
            uint[] component;
            compQueue.length = 0;
            compQueue ~= cast(uint)startFi;
            partitioned[cast(uint)startFi] = true;
            size_t compQi = 0;
            while (compQi < compQueue.length) {
                uint fi = compQueue[compQi++];
                component ~= fi;
                const uint base = faceLoop[fi];
                const uint n    = cast(uint)faces[fi].length;
                foreach (k; 0 .. n) {
                    uint tw = loops[base + k].twin;
                    if (tw == ~0u) continue;          // boundary/non-manifold: hard border
                    uint nfi = loops[tw].face;
                    if (partitioned[nfi]) continue;
                    partitioned[nfi] = true;
                    compQueue ~= nfi;
                }
            }

            if (restrictToSelection) {
                bool anySel = false;
                foreach (fi; component) if (isFaceSelected(fi)) { anySel = true; break; }
                if (!anySel) continue;   // untouched: flipComputed/flipMask stay false
            }

            // --- Pass 2: seed — area-weighted centroid, farthest corner. ---
            Vec3   wCentroid = Vec3(0, 0, 0);
            double wSum      = 0;
            foreach (fi; component) {
                float area = faceAreaApprox_(fi);
                wCentroid  = wCentroid + faceCentroid(fi) * area;
                wSum      += area;
            }
            Vec3 centroid = wSum > 1e-12
                ? wCentroid * cast(float)(1.0 / wSum)
                : faceCentroid(component[0]);

            uint  seedFi = component[0], seedK = 0;
            float bestSq = -1;
            foreach (fi; component) {
                const uint[] f = faces[fi];
                foreach (k; 0 .. f.length) {
                    Vec3  d  = vertices[f[k]] - centroid;
                    float sq = d.x*d.x + d.y*d.y + d.z*d.z;
                    if (sq > bestSq) { bestSq = sq; seedFi = fi; seedK = cast(uint)k; }
                }
            }

            bool seedFlip;
            {
                const uint[] sf = faces[seedFi];
                const uint   sn = cast(uint)sf.length;
                Vec3 pCur  = vertices[sf[seedK]];
                Vec3 pNext = vertices[sf[(seedK + 1) % sn]];
                Vec3 pPrev = vertices[sf[(seedK + sn - 1) % sn]];
                Vec3 loopNormal = cross(pNext - pCur, pPrev - pCur);
                seedFlip = dot(pCur - centroid, loopNormal) < 0;
            }

            // --- Pass 3: BFS-propagate flip parity across manifold edges. ---
            flipComputed[seedFi] = true;
            flipMask[seedFi]     = seedFlip;
            bfsQueue.length = 0;
            bfsQueue ~= seedFi;
            size_t bfsQi = 0;
            while (bfsQi < bfsQueue.length) {
                uint fi      = bfsQueue[bfsQi++];
                bool curFlip = flipMask[fi];
                const uint base = faceLoop[fi];
                const uint n    = cast(uint)faces[fi].length;
                foreach (k; 0 .. n) {
                    uint li = base + k;
                    uint tw = loops[li].twin;
                    if (tw == ~0u) continue;
                    uint nfi = loops[tw].face;
                    if (flipComputed[nfi]) continue;
                    bool sameDirShared = (loops[tw].vert == loops[li].vert);
                    flipComputed[nfi] = true;
                    flipMask[nfi]     = sameDirShared ^ curFlip;
                    bfsQueue ~= nfi;
                }
            }
        }

        return flipMask;
    }

    // Newell-method face area (magnitude of the Newell normal sum halved).
    // `faceNormal()` normalizes this away, so it can't be reused directly;
    // kept private — only `computeOrientationFlipMask` (and transitively
    // `fixFaceOrientation`) consumes it.
    private float faceAreaApprox_(uint fi) const {
        const uint[] face = faces[fi];
        if (face.length < 3) return 0;
        float nx = 0, ny = 0, nz = 0;
        foreach (i; 0 .. face.length) {
            Vec3 a = vertices[face[i]];
            Vec3 b = vertices[face[(i + 1) % face.length]];
            nx += (a.y - b.y) * (a.z + b.z);
            ny += (a.z - b.z) * (a.x + b.x);
            nz += (a.x - b.x) * (a.y + b.y);
        }
        return 0.5f * sqrt(nx*nx + ny*ny + nz*nz);
    }
}

// ---------------------------------------------------------------------------
// Unit tests — co-located with the family they exercise (moved verbatim
// from mesh.d alongside the kernels above). NOTE: `uintToStr` (the test
// assert-message formatter these blocks call) stays in mesh.d — task 0417
// widened it from `private` to module-visible (it is ALSO used by a
// weld-family test that is not part of this move) rather than duplicating
// it here; see mesh.d's own comment at its definition.
// ---------------------------------------------------------------------------
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

unittest { // O(F) hash-bucket rewrite matches the naive O(F²) makePolyVertexSetMatch_
    // pairwise scan: plain duplicate + reversed-winding duplicate + a
    // non-duplicate that merely shares some vertices with the kept face
    // (task 0396). Reference mask computed inline via the same
    // makePolyVertexSetMatch_ helper the old implementation used.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0), Vec3(2,0,0)];
    m.faces = [
        [0u,1u,2u,3u],  // F0: kept (first occurrence)
        [3u,2u,1u,0u],  // F1: reversed-winding duplicate of F0 → removed
        [1u,2u,4u],     // F2: shares verts 1,2 with F0 but is NOT a duplicate (arity 3 vs 4) → kept
        [0u,1u,2u,3u],  // F3: plain duplicate of F0 → removed
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    // Reference: naive O(F²) pairwise mask via the retained helper.
    bool[] refMask;
    refMask.length = m.faces.length;
    foreach (i; 0 .. m.faces.length) {
        if (refMask[i]) continue;
        foreach (j; i + 1 .. m.faces.length) {
            if (refMask[j]) continue;
            if (Mesh.makePolyVertexSetMatch_(m.faces[i][], m.faces[j][]))
                refMask[j] = true;
        }
    }
    size_t refRemoved = 0;
    foreach (b; refMask) if (b) ++refRemoved;
    assert(refMask == [false, true, false, true],
        "reference mask sanity: F1 and F3 are duplicates of F0, F2 is not");

    size_t removed = m.unifyFaces();
    assert(removed == refRemoved,
        "hash-bucket unifyFaces must remove the same count as the naive scan, got "
        ~ uintToStr(removed) ~ " vs " ~ uintToStr(refRemoved));
    assert(m.faces.length == 2, "expected F0 and F2 to survive, got " ~ uintToStr(m.faces.length));
    assert(m.faces[0][] == [0u,1u,2u,3u], "lowest-index face (F0) must be kept");
    assert(m.faces[1][] == [1u,2u,4u], "non-duplicate F2 (shares verts but different arity) must survive");
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
// fixFaceOrientation unittests (task 0394 Part B — Fix Orientation repair op)
// ---------------------------------------------------------------------------

unittest { // well-formed mesh: no-op, byte-identical
    import std.algorithm : map;
    import std.array : array;
    Mesh m = makeCube();
    m.buildLoops();
    auto before = m.faces.dup.map!(f => f.dup).array;
    const verBefore = m.topologyVersion;
    size_t n = m.fixFaceOrientation();
    assert(n == 0, "consistently-wound cube must report 0 flips");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi][] == before[fi][], "well-formed mesh: face " ~ uintToStr(fi) ~ " must be unchanged");
    assert(m.topologyVersion == verBefore,
        "well-formed mesh: topologyVersion must not change (flipFacesByMask short-circuits on an all-false mask)");
}

unittest { // single corrupted face on a closed cube: exactly 1 flip, restores
           // the original (outward-consistent) winding exactly
    import std.algorithm : map;
    import std.array : array;
    Mesh m = makeCube();
    m.buildLoops();
    auto original = m.faces.dup.map!(f => f.dup).array;

    bool[] mask = new bool[](m.faces.length);
    mask[2] = true;
    size_t nFlipped = m.flipFacesByMask(mask);
    assert(nFlipped == 1, "sanity: corrupting setup must flip exactly face 2");
    assert(m.faces[2][] != original[2][], "sanity: face 2 must now differ from its original winding");

    size_t n = m.fixFaceOrientation();
    assert(n == 1, "exactly 1 face (the corrupted one) must be flipped back");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi][] == original[fi][],
            "fixFaceOrientation must restore the cube's original outward-consistent winding exactly, face "
            ~ uintToStr(fi) ~ " differs");

    // No same-direction shared edge remains anywhere in the mesh.
    foreach (fi; 0 .. m.faces.length) {
        const uint[] f = m.faces[fi];
        foreach (k; 0 .. f.length) {
            uint u = f[k], v = f[(k + 1) % f.length];
            foreach (fj; 0 .. m.faces.length) {
                if (fj == fi) continue;
                const uint[] g = m.faces[fj];
                foreach (kk; 0 .. g.length) {
                    if (g[kk] == u && g[(kk + 1) % g.length] == v)
                        assert(false, "same-direction shared edge (" ~ uintToStr(u) ~ "," ~ uintToStr(v)
                            ~ ") remains between faces " ~ uintToStr(fi) ~ " and " ~ uintToStr(fj));
                }
            }
        }
    }
}

unittest { // multiple same-direction shared edges (several faces wound
           // backwards, mimicking a corrupted import) are ALL healed in one pass
    import std.algorithm : map;
    import std.array : array;
    Mesh m = makeCube();
    m.buildLoops();
    auto original = m.faces.dup.map!(f => f.dup).array;

    bool[] mask = new bool[](m.faces.length);
    mask[0] = true; mask[3] = true; mask[5] = true; // flip 3 of 6 faces
    m.flipFacesByMask(mask);

    size_t n = m.fixFaceOrientation();
    assert(n > 0, "expected at least 1 corrective flip");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi][] == original[fi][],
            "fixFaceOrientation must restore the original winding for face " ~ uintToStr(fi)
            ~ " even when multiple faces started corrupted");
}

unittest { // subpatch + material survive the flip -- reversing a face's
           // vertex cycle is index-order only; the face SLOT is never
           // added/removed/reordered, so faceMarks/faceMaterial (both
           // indexed by face slot) must stay aligned across the flip.
    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();
    m.faceMarks[2] |= Mesh.Marks.Subpatch;
    m.faceMaterial.length = m.faces.length;
    m.faceMaterial[2] = 7;

    bool[] mask = new bool[](m.faces.length);
    mask[2] = true;
    m.flipFacesByMask(mask);

    size_t n = m.fixFaceOrientation();
    assert(n == 1, "expected exactly 1 corrective flip");
    assert(m.isFaceSubpatch(2), "face 2's subpatch flag must survive the flip");
    assert(m.faceMaterial[2] == 7, "face 2's material index must survive the flip");
}

unittest { // selection-restricted: with an active face selection, only the
           // connected COMPONENT containing a selected face is healed;
           // components with no selected face are left completely untouched
           // (matches reference-editor selection-restricted Recalculate
           // Normals behavior)
    import std.algorithm : map;
    import std.array : array;
    Mesh a = makeCube();
    Mesh b = makeCube();
    foreach (ref v; b.vertices) v = v + Vec3(10, 0, 0); // disjoint component, far away

    Mesh m;
    m.vertices = a.vertices.dup ~ b.vertices.dup;
    foreach (f; a.faces) m.addFace(f.dup);
    const uint offset = cast(uint)a.vertices.length;
    foreach (f; b.faces) {
        uint[] nf;
        foreach (vi; f) nf ~= vi + offset;
        m.addFace(nf);
    }
    m.buildLoops();
    m.resetSelection();
    auto originalA = m.faces[0 .. a.faces.length].dup.map!(f => f.dup).array;
    auto originalB = m.faces[a.faces.length .. $].dup.map!(f => f.dup).array;

    bool[] mask = new bool[](m.faces.length);
    mask[1]                     = true; // corrupt a face in component A
    mask[a.faces.length + 1]    = true; // corrupt a face in component B
    m.flipFacesByMask(mask);

    m.faceMarks[0] |= Mesh.Marks.Select; // select a face ONLY in component A

    size_t n = m.fixFaceOrientation();
    assert(n == 1, "only component A's single corrupted face should be flipped back");
    foreach (fi; 0 .. a.faces.length)
        assert(m.faces[fi][] == originalA[fi][], "component A (selected) must be fully healed, face " ~ uintToStr(fi));
    bool bStillCorrupt = false;
    foreach (fi; 0 .. b.faces.length)
        if (m.faces[a.faces.length + fi][] != originalB[fi][]) bStillCorrupt = true;
    assert(bStillCorrupt, "component B (not selected) must be left untouched -- still corrupted");
}
