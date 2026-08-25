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
        uint[]   oldOfNew;   // newToOld correspondence — task 1902, mesh_planes.rewriteFaces
                              // carries faceMarks/faceMaterial/facePart/faceSelectionOrder/
                              // faceSetMask from this in one pass.
        newFaces.reserve(faces.length);
        oldOfNew.reserve(faces.length);

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
            newFaces ~= f;
            // Old index `fi` is this survivor's SOLE plane source, carried
            // by `rewriteFaces` below — the WHOLE faceMarks word (Subpatch +
            // Hide, not just Subpatch — task 0613 §4.2), not the allocating
            // `isSubpatch` @property (same O(F²)-in-a-loop trap as
            // deleteFacesByMask, task 0396).
            oldOfNew ~= cast(uint)fi;
            if (remapUv)
                foreach (sc; srcCorner)
                    oldLoopOfNewLoop ~= oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, sc);
        }

        // Early return: nothing changed — no commitChange, no version bump.
        if (removed == 0 && fixed == 0) return 0;

        // `rw` (this site's OWN beginCornerRelocate() handle) is NOT passed
        // to rewriteFaces: it declares through `.relocated()` on a per-CORNER
        // correspondence built above, a different shape from the primitive's
        // own per-NEW-FACE `rw.carriedPerFace()` call — same reasoning as
        // Mesh.deleteFacesByMask (Stage B site 3).
        rewriteFaces(this, newFaces, FaceSource(oldOfNew));
        // Re-mask the just-carried word in place — src here IS faceMarks
        // (self-aliasing; see Mesh.setFaceMarksFrom's own doc comment for
        // why that is safe).
        setFaceMarksFrom(faceMarks, ~Marks.Select);
        if (remapUv) declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));

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




// ---------------------------------------------------------------------------
// cleanDegenerateFaces unittests
// ---------------------------------------------------------------------------






// ---------------------------------------------------------------------------
// cleanupMesh unittests
// ---------------------------------------------------------------------------





// ---------------------------------------------------------------------------
// fixFaceOrientation unittests (task 0394 Part B — Fix Orientation repair op)
// ---------------------------------------------------------------------------
