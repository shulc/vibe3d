module mesh_ops.cleanup;

// ---------------------------------------------------------------------------
// The mesh-hygiene + orientation-repair kernel family: four mutating entry
// points (`unifyFaces`, `cleanDegenerateFaces`, `cleanupMesh`,
// `fixFaceOrientation`), three read-only detectors shared with
// `source/mesh_analysis.d` (`computeDuplicateFaceMask`, `isFaceDegenerate`,
// `computeOrientationFlipMask` — two overloads) and the two private helpers
// they alone use (`computeCollapsedFace_` with its result struct
// `CollapsedFace_`, and `faceAreaApprox_`). Split out of mesh.d as
// `mixin template MeshCleanupOps` by the mesh.d decomposition campaign
// (0407 §B.V2, task 0417 — continuation of the task-0412 plane-cut pilot).
//
// Converted to module-level FREE FUNCTIONS by task 1903 Stage E1
// (`doc/mesh_edit_seam_plan.md` §4, §5.2 row E1). Function BODIES are
// unchanged — every edit is an `ed.` / `m.` prefix — and the shapes C / D1 /
// D2 / D3 settled hold here verbatim: the receiver of a mutating kernel is the
// batch, the `mixin MeshCleanupOps;` line left `struct Mesh` in the SAME
// change, and the callers open an UNRECORDED batch at their own boundary.
// What E1 adds to that memo is below.
//
// TWO RECEIVERS, AND THE SPLIT IS THE `const` THE MEMBERS ALREADY CARRIED
// (§4.1 cells one and two):
//
//   * `ref MeshEditBatch ed` — `unifyFaces`, `cleanDegenerateFaces`,
//     `cleanupMesh`, `fixFaceOrientation`. All four drop or reshape faces and
//     compact vertices away.
//   * `ref const(Mesh) m` — `computeDuplicateFaceMask`, `isFaceDegenerate`,
//     `computeOrientationFlipMask` (both overloads) and the two private
//     helpers. All seven were `const` members; the const receiver is the same
//     statement in the new shape, and it is what keeps `mesh_analysis.d`'s
//     three call sites — which hold a `const ref Mesh` and could not call a
//     batch receiver at all — compiling verbatim.
//
// §4.1's THIRD cell (a query that touches a memo and therefore needs plain
// `ref Mesh`) does not occur in this family: nothing here memoizes.
//
// The mutating kernels reach the read-only ones by spelling `ed.mesh`
// explicitly at the call site (`computeOrientationFlipMask(ed.mesh)`), not by
// leaning on `alias mesh this`. Both compile; the explicit one is the one that
// SAYS the detector reads and does not write, which is the whole content of
// the two receivers being different inside one family (D3's convention).
//
// THE WIDENINGS E1 OWES: **NONE**, and that is a measured claim rather than an
// omission. §2.6 lists eleven `private` names of `mesh.d` that a converted ops
// file can no longer reach for free, and assigns each to the stage that
// converts ITS caller — none of the eleven is assigned to E1, and this file
// calls none of them. Everything it does reach on `Mesh` is already public and
// was already public before this commit: `deleteFacesByMask`,
// `flipFacesByMask`, `compactUnreferenced`, `weldCoincidentVertices`,
// `dissolveDegree2Verts`, `buildLoops`, `rebuildEdges`,
// `clearFaceSelectionResize`, `clearEdgeSelectionResize`, `setFaceMarksFrom`,
// `beginCornerRelocate`, `oldFaceLoopIndex`, `declareCornerProvenance`,
// `hasAnySelectedFaces`, `isFaceSelected`, `faceCentroid`, `commitChange`, and
// the `vertices` / `faces` / `loops` / `faceLoop` / `faceMarks` fields. The
// proof is not this list: it is that the module compiles as its own
// translation unit, with no mixin instantiation scope behind it. A widening
// this stage had missed would be a compile error, not a silent pass — which is
// the opposite of the position `mesh.smoothstep01` put D3 in.
//
// NO INTRA-`Mesh` CALLER, so no transitional batch (§4.4a). D3's fourth cell —
// a converted kernel called from inside `struct Mesh` or from a still-mixin
// sibling, where §4.1's "the boundary opens the batch" has nowhere to land —
// was checked for before converting, as §4.4a requires: `source/mesh.d` and
// the nine remaining `mesh_ops/*.d` name every entry of this family only in
// COMMENTS. Cited by NAME and by a reproducible predicate rather than by line
// number, deliberately: the first draft of this note cited six `mesh.d` lines
// and every one of them was stale by nine lines by the time review read it —
// one insertion above them was enough. Re-run the census with
//
//   grep -n 'unifyFaces\|cleanDegenerateFaces\|cleanupMesh\|fixFaceOrientation\
//   \|computeDuplicateFaceMask\|isFaceDegenerate\|computeOrientationFlipMask' \
//     source/mesh.d source/mesh_planes.d source/mesh_topo.d
//
// and the invariant is not a COUNT (a new comment mention is harmless) but a
// SHAPE: every hit must sit inside a comment. Today, in `mesh.d`: the
// file-header note announcing this very move; the half-edge twin-pairing note
// beside the `loops`/`faceLoop`/`loopEdge` fields; `applyVertexRemap`'
// list of face-compaction sites; `dissolveVerticesByMask`' doc comment on the
// opt-in `dissolve2Valent` sweep; the task-1290 twin-ambiguity note near
// `vertexFanOrdered`; `makePolyVertexSetMatch_`' task-0417 provenance note (the doc
// comment right after `registerNewFaceEdges`); and
// the `CleanupOptions`/`CleanupResult` block's header and doc comments. In
// `mesh_planes.d`: `rewriteFaces`' in-place-rewrite aside. In `mesh_topo.d`:
// the same component-wall note. A hit that is a CALL is the fourth D3 cell
// arriving:
// an intra-`Mesh` or still-mixin caller with nowhere to open a batch. Every
// real caller today is a command or a test, i.e. a boundary that can hold
// one. This family therefore carries no `nestedBatchOpens` debt and no
// removing stage.
//
// `CleanupOptions` / `CleanupResult` stay in `mesh.d`, where task 0417 left
// them: `source/commands/mesh/cleanup.d` constructs `CleanupOptions` directly,
// so moving them would be a second edit hiding inside a move (§4.4a's
// narrowing rule, applied to a type instead of a batch).
//
// `CollapsedFace_` DOES move here, to module scope. It was a `private` nested
// struct the mixin injected into `Mesh` (§2.7's rule for injected non-function
// members), it is the return type of a module-private helper, and nothing
// outside this file has ever named it — measured: `grep -rn CollapsedFace_`
// over `source/` and `tests/` finds it only here.
// ---------------------------------------------------------------------------
import mesh;
import math;
// `sqrt` — the 1902 rule ("free names in a mixin body bind in `mesh.d`")
// cashed out, and the same trap Stage D2 hit in `decimate.d`. `math` does NOT
// re-export `std.math.sqrt` (it imports it selectively and privately), while
// `source/mesh.d` opens with `import std.math : sqrt, isIdentical;` — so the
// two Newell-magnitude `sqrt` calls below resolved through mesh.d's import and
// not through this file's. Without this line the conversion is two
// `Error: sqrt is not defined` the moment the template wrapper comes off.
import std.math : sqrt;
// §4.3's per-file table: the two imports the instantiation scope used to
// supply. `MeshEditScope` for `cleanDegenerateFaces`'s tail commit and for the
// family's declared scope below; `rewriteFaces` / `FaceSource` for the single
// plane-carrying rewrite (task 1902 site 11).
import mesh_edit_delta : MeshEditScope;
import mesh_planes : rewriteFaces, FaceSource;

/// The change classes one hygiene sweep actually commits, for the batch its
/// callers open. It lives HERE, beside the kernels, and not spelled out at
/// each of the four call sites, for the reason Stage D2 gave for
/// `kReduceEditScope`: N copies is N chances to drift, and the one that drifts
/// is the one that stops matching the op-log's declared scope when track 2
/// turns this family's undo into a delta (`MeshEditTracker.declare` is what
/// ends up in `MeshEditDelta.scope_`).
///
/// `Polygons` : every mutating entry drops or reshapes faces —
///              `deleteFacesByMask` (unify), `rewriteFaces` (degenerate),
///              `flipFacesByMask` (orientation).
/// `Points`   : `compactUnreferenced` removes the vertices those drops orphan,
///              and `weldCoincidentVertices` / `dissolveDegree2Verts` remove
///              more. `fixFaceOrientation` alone never removes one — declared
///              for the FAMILY, not per call, exactly as `kBridgeEditScope`
///              declares `Points` for a bridge that may or may not create an
///              interior ring. Over-declaring makes a revert bump and rebuild
///              more than it must; under-declaring makes it rebuild less, and
///              that is the direction that loses a plane.
/// `Marks`    : `cleanDegenerateFaces` re-masks the whole `faceMarks` word
///              through `setFaceMarksFrom`, which is the raw non-committing
///              writer and publishes NOTHING on its own — which is exactly why
///              the class has to be DECLARED: on a revert `MeshEditDelta`
///              reads `scope_` back to decide what to bump and rebuild, and a
///              faceMarks plane that moved without the bit set is a stale
///              subpatch cache.
///
/// NOT `Position`: no kernel in this family moves an EXISTING vertex. A weld
/// keeps the survivor's own coordinates (`average = false`), a dissolve and a
/// compaction only drop vertices, and the degenerate pass touches `vertices`
/// not at all. That is also why this family adds no `setVertexPos` call and
/// why its §5.7 position-write count is 0 rather than a retired allow-entry.
/// The behavioural twin of that claim is the `Kind.SetPos == 0` assertion in
/// `tests/unit/mesh_ops/cleanup_test.d`'s recording block.
///
/// NOT `Material`: `rewriteFaces` CARRIES `faceMaterial` alongside the marks
/// planes, but carrying a value onto the face that already owned it is not a
/// material change — same call D2 made for `reduceToTarget`, whose weld runs
/// the same primitive.
enum uint kCleanupEditScope = MeshEditScope.Geometry | MeshEditScope.Marks;

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
bool[] computeDuplicateFaceMask(ref const(Mesh) m) {
    import std.algorithm.sorting : sort;
    bool[] mask;
    mask.length = m.faces.length;
    bool[immutable(uint)[]] seen;
    foreach (i; 0 .. m.faces.length) {
        uint[] key = m.faces[i][].dup;
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

size_t unifyFaces(ref MeshEditBatch ed) {
    if (ed.faces.length < 2) return 0;
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
    bool[] mask = computeDuplicateFaceMask(ed.mesh);
    bool anyMarked = false;
    foreach (b; mask) if (b) { anyMarked = true; break; }
    if (!anyMarked) return 0;
    return ed.deleteFacesByMask(mask);
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
private CollapsedFace_ computeCollapsedFace_(ref const(Mesh) m, uint fi) {
    const uint[] face = m.faces[fi];
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
        Vec3 a = m.vertices[f[i]];
        Vec3 b = m.vertices[f[(i + 1) % f.length]];
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
bool isFaceDegenerate(ref const(Mesh) m, uint fi) {
    return computeCollapsedFace_(m, fi).degenerate;
}

size_t cleanDegenerateFaces(ref MeshEditBatch ed) {
    if (ed.faces.length == 0) return 0;

    // Task 0830: this capture is the obligation handle. `beginCornerRelocate`
    // takes the OFFSETS only — a relocation names each source corner by
    // index and never looks a vertex up in an old winding — and it ARMS the
    // drop: a path out of here that rewrites `faces` without declaring loses
    // the plane rather than keeping values on foreign corners.
    auto rw = ed.beginCornerRelocate();
    const bool remapUv = rw.active();
    const(uint)[] oldFaceLoop = rw.oldFaceLoop();
    uint[] oldLoopOfNewLoop;

    uint[][] newFaces;
    uint[]   oldOfNew;   // newToOld correspondence — task 1902, mesh_planes.rewriteFaces
                          // carries faceMarks/faceMaterial/facePart/faceSelectionOrder/
                          // faceSetMask from this in one pass.
    newFaces.reserve(ed.faces.length);
    oldOfNew.reserve(ed.faces.length);

    size_t removed = 0;
    size_t fixed   = 0;

    foreach (fi, ref face; ed.faces) {
        // Collapse consecutive duplicate vertex indices (+ wrap-around
        // dup) and test degeneracy via the shared helper (task 0402
        // Phase 4 risk #2 — the read-only Cleanup detector calls the
        // SAME `computeCollapsedFace_`/`isFaceDegenerate`, so this
        // mutating pass and that detector can never drift apart).
        auto cf = computeCollapsedFace_(ed.mesh, cast(uint)fi);
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
                oldLoopOfNewLoop ~= Mesh.oldFaceLoopIndex(oldFaceLoop, cast(uint)fi, sc);
    }

    // Early return: nothing changed — no commitChange, no version bump.
    if (removed == 0 && fixed == 0) return 0;

    // `rw` (this site's OWN beginCornerRelocate() handle) is NOT passed
    // to rewriteFaces: it declares through `.relocated()` on a per-CORNER
    // correspondence built above, a different shape from the primitive's
    // own per-NEW-FACE `rw.carriedPerFace()` call — same reasoning as
    // Mesh.deleteFacesByMask (Stage B site 3).
    // Task 1903 Stage K — ARMED, per rewrite. The degenerate sweep both DROPS
    // a face (zero Newell area) and RESHAPES another (a repeated index) by
    // handing one new array to the primitive; neither goes through
    // `deleteFacesByMask`, so a disarmed op-log carries no face entry at all
    // and its revert restores the vertices over a mesh that has lost a face.
    // The scope, not a batch-wide flag: `ed.compactUnreferenced()` below
    // records the vertex side through the other hooked path.
    { auto arm = ed.faceReindexScope();
      rewriteFaces(ed, newFaces, FaceSource(oldOfNew)); }
    // Re-mask the just-carried word in place — src here IS faceMarks
    // (self-aliasing; see Mesh.setFaceMarksFrom's own doc comment for
    // why that is safe).
    ed.setFaceMarksFrom(ed.faceMarks, ~Mesh.Marks.Select);
    if (remapUv) ed.declareCornerProvenance(rw.relocated(oldLoopOfNewLoop));

    ed.clearFaceSelectionResize();
    ed.rebuildEdges();
    ed.clearEdgeSelectionResize();
    ed.compactUnreferenced();
    ed.buildLoops();
    ed.commitChange(MeshEditScope.Geometry);
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
CleanupResult cleanupMesh(ref MeshEditBatch ed, CleanupOptions o = CleanupOptions.init) {
    CleanupResult r;
    if (o.mergeVerts)      r.welded       = ed.weldCoincidentVertices(o.weldEpsSq);
    if (o.dropDegenerate)  r.degenerate   = cleanDegenerateFaces(ed);
    if (o.unify)           r.unified      = unifyFaces(ed);
    if (o.removeOrphans)   r.orphans      = ed.compactUnreferenced();
    if (o.dissolve2Valent) r.dissolved    = ed.dissolveDegree2Verts();
    if (o.removeOrphans)   r.finalOrphans = ed.compactUnreferenced();
    // TASK 1903 STAGE L5-P0 — THE SWEEP CLOSES ITS OWN CORNER-PROVENANCE
    // DECLARATION, and this is a FORWARD defect the L5 fixture found rather
    // than a tidy-up.
    //
    // `Mesh.applyVertexRemap` (the weld's apply half) opens
    // `beginCornerRelocate()` and closes it with `declareCornerProvenance`,
    // but it rebuilds EDGES only — never loops. The thing that CONSUMES a
    // pending declaration is `buildLoops` (inside `resizePolyVertexMaps`).
    // Stage 2 `cleanDegenerateFaces` ends with one, so on the DEFAULT sweep
    // the declaration was consumed by accident; on any sweep where stage 2
    // does not fire (`dropDegenerate:false`, or nothing degenerate to drop —
    // both reachable from `mesh.cleanup`'s own parameters) it was left
    // OUTSTANDING ACROSS THE COMMAND BOUNDARY. Two consequences, measured on
    // `makeTaggedGridDirty(3)` with the weld alone enabled: the per-corner
    // relocation the weld declared is never applied, so the UV values stay in
    // the pre-weld corner space; and the next delta replay on that mesh trips
    // `mesh_edit_delta`'s always-on "a corner-provenance declaration was
    // already pending when a fast-path replay began" assert — which is
    // exactly the assert's stated job ("find the kernel that declared and did
    // not rebuild").
    //
    // Guarded on `anyAffected()` so a no-op sweep still costs nothing, and
    // idempotent against stage 2's own rebuild: `buildLoops` on an already
    // -rebuilt mesh re-derives the same arrays and finds no declaration
    // pending. ONE rebuild per SWEEP, never one per stage or per element.
    if (r.anyAffected()) ed.buildLoops();
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
size_t fixFaceOrientation(ref MeshEditBatch ed) {
    ed.buildLoops();   // ensure loops/twin/faceLoop reflect the current faces[]
    if (ed.faces.length == 0) return 0;
    return ed.flipFacesByMask(computeOrientationFlipMask(ed.mesh));
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
/// (that would require a non-`const` receiver); `fixFaceOrientation` calls
/// it explicitly before reaching here.
bool[] computeOrientationFlipMask(ref const(Mesh) m) {
    // Mutating fixFaceOrientation() historically restricts to the selection
    // when faces are selected. The read-only Topology detector wants the
    // WHOLE mesh regardless of selection, so it calls the bool overload
    // with restrictToSelection=false (task 0402 Phase 4, review S2).
    return computeOrientationFlipMask(m, m.hasAnySelectedFaces());
}

/// ditto, with an explicit selection-restriction flag: `fixFaceOrientation`
/// passes `hasAnySelectedFaces()` (its historical behavior); the Phase-4
/// Topology detector passes `false` so an analyze under an active selection
/// still reports winding problems in unselected components.
bool[] computeOrientationFlipMask(ref const(Mesh) m, bool restrictToSelection) {
    const size_t nf = m.faces.length;
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
            const uint base = m.faceLoop[fi];
            const uint n    = cast(uint)m.faces[fi].length;
            foreach (k; 0 .. n) {
                uint tw = m.loops[base + k].twin;
                if (tw == ~0u) continue;          // boundary/non-manifold: hard border
                uint nfi = m.loops[tw].face;
                if (partitioned[nfi]) continue;
                partitioned[nfi] = true;
                compQueue ~= nfi;
            }
        }

        if (restrictToSelection) {
            bool anySel = false;
            foreach (fi; component) if (m.isFaceSelected(fi)) { anySel = true; break; }
            if (!anySel) continue;   // untouched: flipComputed/flipMask stay false
        }

        // --- Pass 2: seed — area-weighted centroid, farthest corner. ---
        Vec3   wCentroid = Vec3(0, 0, 0);
        double wSum      = 0;
        foreach (fi; component) {
            float area = faceAreaApprox_(m, fi);
            wCentroid  = wCentroid + m.faceCentroid(fi) * area;
            wSum      += area;
        }
        Vec3 centroid = wSum > 1e-12
            ? wCentroid * cast(float)(1.0 / wSum)
            : m.faceCentroid(component[0]);

        uint  seedFi = component[0], seedK = 0;
        float bestSq = -1;
        foreach (fi; component) {
            const uint[] f = m.faces[fi];
            foreach (k; 0 .. f.length) {
                Vec3  d  = m.vertices[f[k]] - centroid;
                float sq = d.x*d.x + d.y*d.y + d.z*d.z;
                if (sq > bestSq) { bestSq = sq; seedFi = fi; seedK = cast(uint)k; }
            }
        }

        bool seedFlip;
        {
            const uint[] sf = m.faces[seedFi];
            const uint   sn = cast(uint)sf.length;
            Vec3 pCur  = m.vertices[sf[seedK]];
            Vec3 pNext = m.vertices[sf[(seedK + 1) % sn]];
            Vec3 pPrev = m.vertices[sf[(seedK + sn - 1) % sn]];
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
            const uint base = m.faceLoop[fi];
            const uint n    = cast(uint)m.faces[fi].length;
            foreach (k; 0 .. n) {
                uint li = base + k;
                uint tw = m.loops[li].twin;
                if (tw == ~0u) continue;
                uint nfi = m.loops[tw].face;
                if (flipComputed[nfi]) continue;
                bool sameDirShared = (m.loops[tw].vert == m.loops[li].vert);
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
private float faceAreaApprox_(ref const(Mesh) m, uint fi) {
    const uint[] face = m.faces[fi];
    if (face.length < 3) return 0;
    float nx = 0, ny = 0, nz = 0;
    foreach (i; 0 .. face.length) {
        Vec3 a = m.vertices[face[i]];
        Vec3 b = m.vertices[face[(i + 1) % face.length]];
        nx += (a.y - b.y) * (a.z + b.z);
        ny += (a.z - b.z) * (a.x + b.x);
        nz += (a.x - b.x) * (a.y + b.y);
    }
    return 0.5f * sqrt(nx*nx + ny*ny + nz*nz);
}

// ===========================================================================
// Module unittests.
// ===========================================================================
// (None here — task 0706 moved this family's blocks to
// tests/unit/mesh_ops/cleanup_test.d, and they stayed there through the E1
// conversion. The empty section headers this file used to carry for them are
// gone with the mixin template that framed them.)

// ---------------------------------------------------------------------------
// The gate that outlives the text census (task 1903 Stage C review, MAJOR-1 —
// compile-time, not a unittest). A member of `Mesh` BEATS a same-name UFCS free
// function silently — no ambiguity, no warning — so anything that puts one of
// these names back on the struct (`mixin MeshCleanupOps;`, `mixin ...!();`, a
// named mixin, a hand-written method with the old body) rebinds every call site
// to it and this module becomes dead code. The regex census in
// tests/unit/commit_seam_census_test.d sees only the literal `mixin Mesh*Ops;`
// spelling; this sees the fact, and at `dub build` time rather than only under
// --config=tests.
//
// It is ALSO the check that a mutating receiver did not quietly widen back: a
// `Mesh.unifyFaces` member could only exist by taking the mesh directly, i.e.
// by dropping the batch this stage exists to require.
//
// EVERY family name is listed, including the two receiver-less-in-the-census
// private helpers and the injected result struct: the mixin put all of them
// into `Mesh` (plan §2.7), so a partial revert that reinstates only
// `faceAreaApprox_` is exactly the silent half this list is here to catch.
// ---------------------------------------------------------------------------
static foreach (n; ["computeDuplicateFaceMask", "unifyFaces", "CollapsedFace_",
                    "computeCollapsedFace_", "isFaceDegenerate",
                    "cleanDegenerateFaces", "cleanupMesh", "fixFaceOrientation",
                    "computeOrientationFlipMask", "faceAreaApprox_"])
    static assert(!__traits(hasMember, Mesh, n),
        "`Mesh." ~ n ~ "` is a MEMBER again. A member BEATS a same-name UFCS free "
      ~ "function silently, so every call site binds back to it, the batch the "
      ~ "mutating kernels take as their receiver goes away with it, and task 1903 "
      ~ "Stage E1 means nothing. Whatever re-added it — `mixin MeshCleanupOps;`, "
      ~ "`mixin ...!();`, a named mixin, or a hand-written method — must go.");
