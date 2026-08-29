module mesh_edge_slice;

// The EDGE-SLICE FAMILY — eleven names extracted from the body of
// `struct Mesh` (task 3240, step 3 of `doc/tasks/work/2910-mesh-struct-seams.md`):
//
//   insertEdgePoint  addEdgePoint  rebuildFacesWithChordSplits
//   edgeIndexOfVerts  edgeIndexOf  EdgeSliceResult  findChordPath
//   edgeSliceReachable  edgeSliceEx  edgeSlice  splitFaceByVertices
//
// WHY THIS GROUP, and the argument is coupling, not tidiness. Measured on the
// tree this move started from (2026-08-29, public `f961b9f1`), by grepping the
// range against the COMPLETE list of `Mesh`'s 56 private members rather than
// from memory: the family reads ZERO of them, and leaks ZERO of its own —
// `findChordPath` was the range's only `private` member and its callers
// (`edgeSliceEx`, `edgeSliceReachable`) travel with it, so it stays `private`
// here and the `Widening` tape in `tests/unit/commit_seam_census_test.d` does
// not grow by a line. That is the whole coupling cost of this seam.
//
// THE ONE THING THE MOVE ITSELF CHANGES, said plainly. A member function has
// an implicit receiver; a free function does not. So unlike step 2's probe,
// whose bodies moved untouched, every body here gains a receiver name: the
// diff against the extracted original is EXACTLY 11 signature lines plus 106
// mechanical `m.` qualifications (`Marks` → `Mesh.Marks`, `this` → `m` at the
// single `rewriteFaces` site), and not one comment, string literal or
// statement besides. The qualification was applied by script, not by hand,
// precisely so that claim is checkable rather than asserted — a retyped body
// is where a "pure move" stops being pure. The rewrite table and the review
// diff are in the card's §Метод.
//
// WHY IT CANNOT SILENTLY LOSE WRITES. `Mesh` is a copyable struct, so a free
// function that took it BY VALUE would compile at every call site and drop
// every write that changes a slice's LENGTH or a field, while writes through
// existing slice elements still landed — the failure mode no behavioural test
// catches reliably (plan 2910 §2.1, trap 1). `tests/unit/mesh_edge_slice_gate_test.d`
// refuses that at compile time over this whole module; the anchor it targets
// is at the foot of this file.
//
// Re-exported unchanged by `public import mesh_edge_slice;` in `mesh.d`, the
// same home template `mesh_topo` / `mesh_corner_maps` / `mesh_visibility` /
// `mesh_gpu` already use, so `m.edgeSlice(...)` and friends keep resolving
// through UFCS (plan 2910 §1.6 П3). Two caveats measured at step 2 and
// re-confirmed here, both of which DID need caller edits: a caller whose
// `import mesh : …` is SELECTIVE does not see a re-exported free function
// unless it names it, and `Mesh.EdgeSliceResult` stops resolving once the
// type is no longer a member of `Mesh`. Both are compile errors, so the step
// catches itself; the sites are counted in the card.

import mesh          : Mesh, FaceIdx, edgeKey;
import mesh_planes   : rewriteFaces, FaceSource;
import mesh_corner_maps : CornerDrop, PolyVertexBlend;
import mesh_edit_delta  : MeshEditScope;
import math          : Vec3;

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
//
// PUBLIC since task 1903 Stage E3 (plan §2.6). `mesh_ops/cut.d` stopped
// being a mixin body instantiated in this module's scope, so `planeCutCore`
// can no longer reach a `private` name here. The widening states the
// contract this helper already had; `tests/unit/commit_seam_census_test.d`
// carries the row that names cut.d as its caller and reddens both if the
// call goes away and if a SECOND file starts using the open door.
uint insertEdgePoint(ref Mesh m, uint ei, float t, ref bool[] isCutVert, float eps = 1e-5f) {
    uint a = m.edges[ei][0], b = m.edges[ei][1];

    if (t <= eps) {
        if (isCutVert.length < m.vertices.length) isCutVert.length = m.vertices.length;
        isCutVert[a] = true;
        return a;
    }
    if (t >= 1.0f - eps) {
        if (isCutVert.length < m.vertices.length) isCutVert.length = m.vertices.length;
        isCutVert[b] = true;
        return b;
    }

    Vec3 vm = Vec3(
        m.vertices[a].x + t * (m.vertices[b].x - m.vertices[a].x),
        m.vertices[a].y + t * (m.vertices[b].y - m.vertices[a].y),
        m.vertices[a].z + t * (m.vertices[b].z - m.vertices[a].z));
    uint vi = m.addVertex(vm);
    if (isCutVert.length < m.vertices.length)
        isCutVert.length = m.vertices.length; // grow after addVertex
    isCutVert[vi] = true;

    // --- TASK 1903 STAGE L2-c: THE SPLICE GOES THROUGH THE WINDING DOOR
    //
    // Until L2-c this was `face = face[0 .. k+1] ~ [vi] ~ face[k+1 .. $]`
    // written straight onto the live `faces` array, and it reached no hook
    // at all. A recording batch around `mesh.addPoint` / `mesh.split_edge`
    // therefore came back with `[AddVerts]` and NOTHING about the splices,
    // so `revert()` truncated the new vertex while every incident winding
    // still named it — the mesh then THREW out of `finalize`→`buildLoops`
    // with an `ArrayIndexError` and stayed half-reverted. Publisher P3 of
    // plan §L2.2, and it is SHARED with `mesh_ops/cut.d`'s `planeCutCore`
    // Pass 1, which is L4's open choice #1 discharged here.
    //
    // ONE BULK CALL, NOT ONE PER FACE, and that is correctness before it
    // is speed. `Mesh.setFaceWindings` pairs its `ReshapeFaces` entry with
    // a per-corner payload, and `recordPolyVertexPayload` DECLINES unless
    // the PolyVertex maps are in step with `faces`
    // (`polyVertexMapsInStepWithFaces`). A splice changes the mesh's TOTAL
    // corner count while the maps are still the pre-op ones, so the FIRST
    // per-face install would put them out of step and every later payload
    // in the same call would silently decline. Deferring all the installs
    // to one call keeps every read in the pre-op space. The per-element
    // door is also QUADRATIC (task 2260: 2.22 ms against 146 ms at ten
    // thousand faces), and a splice on an interior edge of a dense mesh
    // touches every incident face.
    //
    // TWO SCANS AND NO O(faces) SIDE ARRAY, on purpose: `planeCutCore`
    // calls this once per straddling edge, so a per-call array indexed by
    // face index would be a fresh O(F) allocation per cut edge. The result
    // arrays are pre-sized off the counting pass and the reversed windings
    // share ONE backing array sliced per face — three allocations for the
    // whole splice, and no `~=` anywhere (task 2160).
    size_t spliceAt(const uint[] face) {
        for (size_t k = 0; k < face.length; k++) {
            immutable uint fa = face[k];
            immutable uint fb = face[(k + 1) % face.length];
            if ((fa == a && fb == b) || (fa == b && fb == a)) return k + 1;
        }
        return size_t.max;
    }

    size_t nSpliced = 0, corners = 0;
    foreach (fi; 0 .. m.faces.length) {
        if (spliceAt(m.faces[fi]) == size_t.max) continue;
        ++nSpliced;
        corners += m.faces[fi].length + 1;
    }
    if (nSpliced == 0) return vi;

    {
        import std.array : uninitializedArray;
        auto backing = uninitializedArray!(uint[])(corners);
        auto newWind = uninitializedArray!(uint[][])(nSpliced);
        // `uninitializedArray` and not `new FaceIdx[](n)`: `FaceIdx`
        // `@disable`s default construction (a defaulted face index would
        // be face 0, and face 0 is a real face).
        auto idx = uninitializedArray!(FaceIdx[])(nSpliced);
        size_t w = 0, base = 0;
        foreach (fi; m.faceIndices) {          // the mint — never assumeFaceSpace
            const uint[] face = m.faces[fi];
            immutable size_t p = spliceAt(face);
            if (p == size_t.max) continue;
            auto dst = backing[base .. base + face.length + 1];
            dst[0 .. p]      = face[0 .. p];
            dst[p]           = vi;
            dst[p + 1 .. $]  = face[p .. $];
            idx[w]     = fi;
            newWind[w] = dst;
            base += face.length + 1;
            ++w;
        }
        assert(w == nSpliced, "Mesh.insertEdgePoint: the counting pass and "
                            ~ "the write pass disagree about how many "
                            ~ "windings the splice touches");
        // The return is not read: a spliced winding is strictly longer than
        // its source, so `setFaceWindings`' identity filter cannot drop one,
        // and an out-of-range index is unreachable from `faceIndices`.
        cast(void) m.setFaceWindings(idx, newWind);
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
uint addEdgePoint(ref Mesh m, uint ei, float t) {
    if (ei >= m.edges.length)        return uint.max;
    if (t <= 0.0f || t >= 1.0f)   return uint.max;

    // Open the corner rewrite (task 0830). The capture — old windings + old
    // CSR offsets — is what the correspondence below resolves against, and
    // its own precondition ("the map, `faces` and `loops` all describe one
    // corner space") is the guard this site used to spell out by hand.
    const uint ea = m.edges[ei][0], eb = m.edges[ei][1];
    auto rw = m.beginCornerRewrite();
    const bool carryUv = rw.active();

    bool[] isCutVert; // local throwaway — not used outside this call
    uint vi = m.insertEdgePoint(ei, t, isCutVert);

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
        srcFaceOfNewFace.length = m.faces.length;
        foreach (fi; 0 .. m.faces.length) srcFaceOfNewFace[fi] = cast(uint)fi;
        m.declareCornerProvenance(
            rw.carriedPerFace(m.faces.range, srcFaceOfNewFace, blend));
    } else if (carryUv) {
        // The parameter snapped to an existing endpoint: `insertEdgePoint`
        // spliced nothing, so every corner keeps its slot AND its meaning.
        // This branch is not decoration — an OPEN rewrite that reaches
        // `buildLoops` without a declaration drops the plane by design
        // (task 0830), so the no-op path has to say it is a no-op.
        m.declareCornerProvenance(rw.unchanged());
    }

    // Re-derive edges from faces (deduped via edgeIndexMap).
    m.rebuildEdges();
    m.buildLoops();
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
//
// PUBLIC since task 1903 Stage E3 (plan §2.6) — same reason as
// `insertEdgePoint` above: `mesh_ops/cut.d`'s `planeCutCore` calls it and is
// no longer a mixin body in this module's scope. Census row in
// tests/unit/commit_seam_census_test.d names its caller.
size_t rebuildFacesWithChordSplits(ref Mesh m,
    const bool[] splitFaceMask, const bool[] isCutVert)
{
    size_t origFaceCount = m.faces.length;
    uint[][] newFacesArr;
    // TASK 1903 STAGE L2-d — THE FIVE PER-FACE PLANES ARE NO LONGER GATHERED
    // HERE. `newWord` / `newOrder` / `newMaterial` / `newPart` /
    // `newSetMask` were five parallel arrays rebuilt by hand and installed
    // wholesale below; `mesh_planes.rewriteFaces` carries exactly those five
    // (`kFacePlanes`) through the same correspondence, so gathering them
    // twice is what the primitive exists to stop. What is kept is the
    // correspondence itself and the Select bit — see the install site.
    uint[]   oldOfNew;   // parent face of each emitted face (newToOld)
    bool[]   newSelected;
    newFacesArr.reserve(origFaceCount + origFaceCount / 2);
    oldOfNew.reserve(origFaceCount + origFaceCount / 2);
    newSelected.reserve(origFaceCount + origFaceCount / 2);

    size_t nSplit = 0;
    foreach (fi; 0 .. origFaceCount) {
        uint[] face = m.faces[fi];
        bool  seld = m.isFaceSelected(fi);

        // Faces not in the mask are copied whole (never split).
        bool eligible = (splitFaceMask.length == 0) ||
                        (fi < splitFaceMask.length && splitFaceMask[fi]);
        if (!eligible) {
            newFacesArr ~= face.dup;
            oldOfNew    ~= cast(uint) fi;
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
            oldOfNew    ~= cast(uint) fi;
            newSelected ~= seld;
            continue;
        }

        size_t i = hits[0], j = hits[1]; // i < j always (scanned in order)

        // Adjacent-hit guard: chord == existing edge → degenerate 2-gon, skip.
        bool adj = (j == i + 1) || (i == 0 && j == face.length - 1);
        if (adj) {
            newFacesArr ~= face.dup;
            oldOfNew    ~= cast(uint) fi;
            newSelected ~= seld;
            continue;
        }

        // Split: f1 = face[i..j+1], f2 = face[j..] ~ face[0..i+1].
        uint[] f1 = face[i .. j + 1].dup;
        uint[] f2 = (face[j .. $] ~ face[0 .. i + 1]).dup;

        // THIS WAS A SECOND `if` UNTIL TASK 3340, AND THAT IS WHY IT IS NOW AN
        // `assert` (backlog 3241 — "a second, unnamed guard refuses first").
        //
        // The two predicates are not "one subsumes the other", they are
        // EXACTLY EQUAL. Measured, not reasoned: over every ordered hit pair
        // `0 <= i < j < n` at every winding length `n` in 2..4096 —
        // 11 453 245 440 cells — `adj` and `f1.length < 3 || f2.length < 3`
        // agreed on all of them, each firing on the same 8 390 654. The
        // algebra closes the unbounded tail in two lines, both affine in `n`:
        //   adj  => `j == i+1` gives `f1.length == 2`; `i == 0 && j == n-1`
        //           gives `f2.length == (n-j) + (i+1) == 2`.
        //   !adj => `j >= i+2` gives `f1.length >= 3`; and `f2.length >= 3`
        //           because `i >= 1` contributes `i+1 >= 2` while `i == 0`
        //           forces `j <= n-2`, i.e. `n-j >= 2`.
        //
        // So as an `if` this line was a branch NO CHECK COULD REDDEN, and its
        // cost was not the dead statements: it SILENTLY REPAIRED every
        // weakening of the guard above. Measured on this branch, in both
        // directions: with the pre-task shape, `bool adj = false;` is GREEN at
        // 384/384 modules; with the `assert`, the same mutation reddens here
        // naming the face, the winding length and the hit pair. The cells that
        // catch it already existed — `splitFaceByVertices: adjacent verts →
        // no-op` in tests/unit/mesh_test.d drives BOTH arms (`j == i+1` and
        // `i == 0 && j == n-1`), and tests/unit/mesh_edge_slice_test.d's kept
        // degenerate-chain cell drives the guard through `edgeSliceEx`.
        //
        // ACCEPTED COST, stated rather than hidden: `assert` is dropped under
        // `-release`, where an `if` would still have copied the face whole. A
        // release binary can therefore only carry a weakened guard if the
        // module-unittest lane was skipped — which is the trade this project
        // makes everywhere else, and the reverse trade (a repair no test can
        // see) is what backlog 3241 was filed against.
        import std.format : format;   // compile-time only; the message below
                                      // is evaluated ONLY when the assert fails
        assert(f1.length >= 3 && f2.length >= 3,
            format("rebuildFacesWithChordSplits: the adjacent-hit guard let a "
                 ~ "DEGENERATE chord through — face %s, winding length %s, hits "
                 ~ "at %s/%s, halves of %s and %s vertices. That pair is "
                 ~ "unreachable while the guard reads "
                 ~ "`(j == i + 1) || (i == 0 && j == n - 1)`, so the guard was "
                 ~ "weakened. Restore it — do NOT re-add a second `if` here: as "
                 ~ "an `if` this line repaired every such weakening silently and "
                 ~ "made the guard's own mutation inert (backlog 3241).",
                   fi, face.length, i, j, f1.length, f2.length));

        // f1 (replaces parent slot)
        newFacesArr ~= f1;
        oldOfNew    ~= cast(uint) fi;
        newSelected ~= seld;

        // f2 (appended slot) — BOTH halves carry parent attrs, including
        // the Select bit: a selected parent yields two selected halves
        // (reference-pinned behavior). Same for Hide (task 0613): a
        // hidden parent yields two hidden halves — `word` carries it.
        newFacesArr ~= f2;
        oldOfNew    ~= cast(uint) fi;
        newSelected ~= seld;

        nSplit++;
    }

    if (nSplit == 0) return 0;

    // --- TASK 1903 STAGE L2-d: THE INSTALL GOES THROUGH `rewriteFaces` ---
    //
    // Until L2-d this was `faces._store = newFacesArr;` plus five
    // hand-rebuilt plane assignments. The raw store reaches NO hook, so a
    // recording batch around `mesh.splitFace` came back with an EMPTY
    // op-log and `MeshEditDelta.revert` answered `true` with the split
    // still in — the silent half of §5.3's two failure shapes, and the one
    // a face COUNT cannot see either, since the count is right in both the
    // broken and the fixed world only AFTER a revert that did nothing.
    //
    // ONE ROUTE, NOT TWO. Plan §L2.2 offered `recordAddFaces` +
    // `recordReshapeFaces` at the install as branch (b); it is not viable
    // here and the reason is in `mesh_planes.d`: three of the five planes
    // this function rewrites — `faceMaterial`, `facePart`, `faceSetMask` —
    // have NO restorer anywhere outside `Kind.RemoveFaces`
    // (`mesh_planes.d`'s carried/dropped lists, and `delete.d`'s side
    // capture covers only the maps and the marks word). A chord split
    // renumbers every face after the parent, so those three would come back
    // shifted by one and nothing in the tree would notice.
    // `Kind.FaceReindex` carries all five by construction.
    //
    // ARMED PER REWRITE, never batch-wide (Stage K's measured rule): with
    // the flag left set for the whole batch, a kernel that also reaches
    // `deleteFacesByMask` would have its drop described TWICE and the LIFO
    // revert would re-insert the face twice. The scope is one `rewriteFaces`
    // call. Precedent and spelling: `mesh_ops/cleanup.d`'s degenerate sweep.
    //
    // WHAT ARMING COSTS, stated because plan revision 2 got it wrong in my
    // own words and then corrected itself: it does NOT cost the `finalize`
    // fast path. `kindHoldsIndexSpace` classifies `AddVerts`, `AddFaces`
    // and `ReshapeFaces` as index-space-UNSTABLE alongside `FaceReindex`,
    // so every L2 log already took the slow path and this row had no fast
    // path to lose.
    { auto arm = m.faceReindexScope();
      rewriteFaces(m, newFacesArr, FaceSource(oldOfNew)); }
    // Re-mask the just-carried word IN PLACE — `src` here IS `faceMarks`
    // (self-aliasing; `Mesh.setFaceMarksFrom`'s own doc comment says why
    // that is safe for this body specifically). `rewriteFaces` carried the
    // WHOLE marks word including Select; the pre-L2-d code carried it with
    // Select already masked out, and `setFacesSelectedFrom` below puts the
    // parent's bit back under the Select ∧ Hide = ∅ invariant. Two steps,
    // exactly as before, so the FORWARD is unchanged.
    m.setFaceMarksFrom(m.faceMarks, ~Mesh.Marks.Select);
    // Inherit each parent's Select bit onto its emitted slot(s) instead of
    // clearing — a selected parent's split halves stay selected, an
    // unselected parent stays unselected, nothing-in ⇒ nothing-out.
    // Writes ONLY the Select bit (Subpatch/Hide already written above).
    m.setFacesSelectedFrom(newSelected);

    // Stated loss (task 0830): the chord fragments carry no record of the
    // old face each came from. The LAW is known — it is the same edge-split
    // lerp Loop Slice carries — so this reason marks available work, not an
    // unmeasured behaviour.
    m.dropCornerProvenance(CornerDrop.ChordSplitNoSource);
    m.rebuildEdges();
    m.clearEdgeSelectionResize();
    m.buildLoops();
    m.syncSelection();
    m.commitChange(MeshEditScope.Geometry);

    return nSplit;
}

// -----------------------------------------------------------------------
// edgeIndexOfVerts — look up an edge by its two endpoint indices.
//
// Returns the index in edges[] for the undirected edge {a, b}, or ~0u if
// no such edge exists (requires buildLoops() to have been called).
// -----------------------------------------------------------------------
//
// PUBLIC since task 1903 Stage E3 (plan §2.6): `mesh_ops/cut.d` calls it at
// three sites — the restrict-set edge marking, the concave-guard scan, and
// the clipped chord-crossing lookup — and stopped being a mixin body in
// this module's scope. (There is exactly ONE concave-guard scan:
// `isConcaveFace` has a single call site. An earlier draft of this comment
// said "the two concave-guard scans" and miscounted the third site.)
//
// NOT the same thing as `edgeIndexOf` below, which is the GUARDED public
// accessor this one already backed: `edgeIndexOf` is what an outside module
// should reach for, and it exists precisely so callers do not depend on the
// raw map lookup. `edgeIndexOfVerts` returns `~0u` for an absent edge and
// assumes `buildLoops()` has run — a caller that has not built loops gets
// `~0u` for EVERY pair, which reads as "no such edge" rather than as
// "index not built". cut.d's three sites all run after a build.
uint edgeIndexOfVerts(ref Mesh m, uint a, uint b) {
    auto p = edgeKey(a, b) in m.edgeIndexMap;
    return p ? *p : ~0u;
}

// Public accessor over edgeIndexOfVerts (task 0295, F2) — the chain tool
// lives in a separate module and needs to re-resolve a destination edge
// by its stable vertex pair every frame (vertex pairs, unlike edge
// indices, survive an intervening edgeSlice's rebuildEdges()).
uint edgeIndexOf(ref Mesh m, uint a, uint b) {
    return m.edgeIndexOfVerts(a, b);
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
private bool findChordPath(const ref Mesh m, uint edgeA, uint edgeB,
                           out uint[] pathFaces, out uint[] interiorEdges)
{
    if (edgeA >= m.edges.length || edgeB >= m.edges.length) return false;
    if (edgeA == edgeB) return false;

    // Collect faces incident to each edge (1-2 faces on a manifold mesh).
    uint[] facesAArr, facesBArr;
    foreach (f; m.facesAroundEdge(edgeA)) facesAArr ~= f;
    foreach (f; m.facesAroundEdge(edgeB)) facesBArr ~= f;
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
        uint startLi = (f < m.faceLoop.length) ? m.faceLoop[f] : ~0u;
        if (startLi == ~0u) continue;
        uint li = startLi;
        do {
            uint twin = m.loops[li].twin;
            if (twin != ~0u) {
                uint g = m.loops[twin].face;
                if (!(g in visited)) {
                    visited[g]    = true;
                    parentFace[g] = f;
                    parentEdge[g] = m.loopEdge[li];
                    queue ~= g;
                }
            }
            li = m.loops[li].next;
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
bool edgeSliceReachable(const ref Mesh m, uint edgeA, uint edgeB) {
    uint[] pathFaces, interiorEdges;
    return m.findChordPath(edgeA, edgeB, pathFaces, interiorEdges);
}

EdgeSliceResult edgeSliceEx(ref Mesh m, uint edgeA, uint edgeB,
                 float tA = 0.5f, float tB = 0.5f,
                 bool splitPolygons = true, float eps = 1e-5f)
{
    EdgeSliceResult result;
    if (m.vertices.length == 0 || m.faces.length == 0 || m.edges.length == 0)
        return result;
    if (edgeA >= m.edges.length || edgeB >= m.edges.length) return result;
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
        isCutVert.length = m.vertices.length;
        result.cutVertA = m.insertEdgePoint(edgeA, tA, isCutVert, eps);
        result.cutVertB = m.insertEdgePoint(edgeB, tB, isCutVert, eps);
        m.clearFaceSelectionResize();
        // Same corner declaration, same reason, as the KEEP+FINALIZE arm
        // below (task 1903 Stage L4-P1): two splices changed the corner
        // total and this branch runs the finalize tail by hand, so without
        // it `buildLoops` reaches `resizePolyVertexMaps`' undeclared
        // branch. Not reachable from the `mesh.edgeSlice` COMMAND (it
        // exposes no `splitPolygons` param) but it is a public kernel arm,
        // and the fix is one line in both places rather than one.
        m.dropCornerProvenance(CornerDrop.ChordSplitNoSource);
        m.rebuildEdges();
        m.clearEdgeSelectionResize();
        m.buildLoops();
        m.syncSelection();
        m.commitChange(MeshEditScope.Geometry);
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
    if (!m.findChordPath(edgeA, edgeB, pathFaces, interiorEdges)) return result;

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
    size_t   vertsBeforePass1 = m.vertices.length;
    uint[][] facesBeforePass1 = m.faces._store.dup;

    bool[] isCutVert;
    isCutVert.length = m.vertices.length;
    foreach (i, ei; cutEdges) {
        uint vi = m.insertEdgePoint(ei, cutT[i], isCutVert, eps);
        if (i == 0)                   result.cutVertA = vi;
        if (i == cutEdges.length - 1) result.cutVertB = vi;
    }

    // --- Pass 2: split only the path faces ---
    size_t origFaceCount = m.faces.length; // stable across Pass-1
    bool[] splitMask;
    splitMask.length = origFaceCount;
    foreach (f; pathFaces)
        if (f < origFaceCount) splitMask[f] = true;

    result.facesSplit = m.rebuildFacesWithChordSplits(splitMask, isCutVert);
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
                       || (m.vertices.length > vertsBeforePass1);
    if (result.facesSplit == 0 && m.vertices.length > vertsBeforePass1) {
        // KEEP + FINALIZE: Pass 1 already spliced the new vertex into the
        // incident face windings in-place, but rebuildFacesWithChordSplits
        // early-returned at nSplit==0 WITHOUT rebuilding edges/loops. Run
        // the same finalize tail a successful split gets. Leave
        // cutVertA/cutVertB as insertEdgePoint returned them — a real
        // caller-visible result, not a no-op sentinel.
        //
        // TASK 1903 STAGE L4-P1 — THE CORNER DECLARATION THIS TAIL OWED.
        //
        // Pass 1's splice changed the mesh's TOTAL corner count, and the
        // thing that CONSUMES a corner declaration is `buildLoops`. On the
        // split arm the declaration is made for us: `rebuildFacesWithChordSplits`
        // ends in `dropCornerProvenance(CornerDrop.ChordSplitNoSource)`.
        // This arm is the one path where that function early-returns at
        // `nSplit == 0` and the tail is run BY HAND, so nothing declared —
        // and `Mesh.resizePolyVertexMaps` then took its undeclared branch:
        // it repaired the plane (length-correct, zeroed) and fired its
        // `debug assert`. MEASURED on `makeTaggedGridFull(3)` (a stand that
        // carries a PolyVertex map): SIXTEEN operands over face 0's four
        // edges and a 3x3 t-grid reach this arm, and every one of them
        // aborted the unit lane. `tests/unit/mesh_ops/cut_test.d`'s cut
        // stand carries no map, which is why nothing had ever exercised it.
        //
        // THE DECLARATION IS THE DROP AND NOT A RELOCATE, deliberately.
        // `Mesh.addEdgePoint` relocates because it makes exactly ONE
        // `insertEdgePoint` call and can build the map; this arm sits after
        // a whole `cutEdges` loop and tracks no old-corner correspondence,
        // which is the same position `rebuildFacesWithChordSplits` is in.
        // Declaring a RICHER outcome here than the split arm manages would
        // make the degenerate tail carry UVs that a real chord split loses.
        //
        // THE SHIPPED FORWARD IS UNCHANGED OUTSIDE `-debug`: the undeclared
        // branch already zeroed a length-wrong plane and the assert compiles
        // out under `-release`. What changes is that the unit lane stops
        // aborting and the loss is now STATED at its site rather than
        // repaired by an insurance branch.
        m.dropCornerProvenance(CornerDrop.ChordSplitNoSource);
        m.rebuildEdges();
        m.clearEdgeSelectionResize();
        m.buildLoops();
        m.syncSelection();
        m.commitChange(MeshEditScope.Geometry);
    } else if (result.facesSplit == 0) {
        // TRUE no-op: every cut reused an existing corner (Pass 1 spliced
        // in nothing new), so vertices.length == vertsBeforePass1 exactly.
        // rebuildFacesWithChordSplits' own nSplit==0 branch returns
        // early WITHOUT touching edges/loops/selection (see its doc
        // comment), so those are still consistent with the PRE-Pass-1
        // vertex count — restoring vertices/faces alone fully undoes
        // Pass 1, no rebuildEdges()/buildLoops() call needed.
        m.faces._store = facesBeforePass1;
        m.vertices.length = vertsBeforePass1;
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
size_t edgeSlice(ref Mesh m, uint edgeA, uint edgeB,
                 float tA = 0.5f, float tB = 0.5f,
                 bool splitPolygons = true, float eps = 1e-5f)
{
    return m.edgeSliceEx(edgeA, edgeB, tA, tB, splitPolygons, eps).facesSplit;
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
public size_t splitFaceByVertices(ref Mesh m, uint faceIdx, uint vA, uint vB)
{
    if (m.faces.length == 0 || m.vertices.length == 0) return 0;
    if (faceIdx >= m.faces.length) return 0;
    if (vA >= m.vertices.length || vB >= m.vertices.length) return 0;
    if (vA == vB) return 0;

    // Both vA and vB must appear in the face winding.
    bool foundA = false, foundB = false;
    foreach (v; m.faces[faceIdx]) {
        if (v == vA) foundA = true;
        if (v == vB) foundB = true;
    }
    if (!foundA || !foundB) return 0;

    // Build cut-vertex mask restricted to faceIdx only.
    bool[] isCutVert = new bool[](m.vertices.length);
    isCutVert[vA] = true;
    isCutVert[vB] = true;

    bool[] splitFaceMask = new bool[](m.faces.length);
    splitFaceMask[faceIdx] = true;

    return m.rebuildFacesWithChordSplits(splitFaceMask, isCutVert);
}

// ---------------------------------------------------------------------------
// The by-value gate's ANCHOR (plan 2910 §2.1, trap 1).
//
// The anchor lives here; the `mixin MeshByValueGate!(mesh_edge_slice)` that
// enforces it lives in `tests/unit/mesh_edge_slice_gate_test.d`. That split is
// NOT style — it is task 3230's most expensive finding, inherited as a rule:
// a module under `source/` must never import anything under `tests/unit/`,
// even behind `version(unittest)`. `run_test.d`'s HTTP lane prebuilds all of
// `source/**` — the `modeling` configuration's own file list, which excludes
// `tests/unit/**` — into ONE `-unittest` static library that every per-test
// binary links, so such an import links clean under `dub test --config=tests`
// and dies under `./run_test.d` with `undefined reference to
// tests.unit.mesh_by_value_gate.__ModuleInfo`. Keep this file's imports to the
// five above.
version (unittest) private void byValueGateAnchor() {}

// ---------------------------------------------------------------------------
// THE SHADOWING TRIPWIRE (plan 2910 §2.1, trap 2; `doc/mesh_edit_seam_plan.md`
// Revision 2 caveat 1) — the same one every converted `mesh_ops/` family
// carries, and the reason it is not optional here.
//
// A MEMBER BEATS a same-name UFCS free function. So if any of these eleven
// names came back as a member of `Mesh` — or as an in-struct `alias` to the
// function below — every existing `m.edgeSlice(...)` call would resolve to the
// member again, both gates would stay green, and the step would have moved
// text and changed nothing. That is a check-that-cannot-fail in its purest
// form, and no behavioural test can see it: the two implementations would be
// identical. This one reddens at BUILD time, in every configuration, and it
// names the offender.
static assert(!__traits(hasMember, Mesh, "insertEdgePoint")
           && !__traits(hasMember, Mesh, "addEdgePoint")
           && !__traits(hasMember, Mesh, "rebuildFacesWithChordSplits")
           && !__traits(hasMember, Mesh, "edgeIndexOfVerts")
           && !__traits(hasMember, Mesh, "edgeIndexOf")
           && !__traits(hasMember, Mesh, "EdgeSliceResult")
           && !__traits(hasMember, Mesh, "findChordPath")
           && !__traits(hasMember, Mesh, "edgeSliceReachable")
           && !__traits(hasMember, Mesh, "edgeSliceEx")
           && !__traits(hasMember, Mesh, "edgeSlice")
           && !__traits(hasMember, Mesh, "splitFaceByVertices"),
    "One of the edge-slice family is a member of `Mesh` again. A member BEATS "
  ~ "a same-name UFCS free function, so every call site would silently resolve "
  ~ "back to it and task 3240 (plan 2910 step 3) would mean nothing. Delete "
  ~ "the member, or — if the family is deliberately coming home — delete this "
  ~ "module and its `public import` in the same change.");
