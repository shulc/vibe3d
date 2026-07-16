module mesh_ops.cut;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshCutOps — plane-cut kernel family, mixed into struct Mesh (source/mesh.d)
// via `mixin MeshCutOps;`. Split out of mesh.d as the pilot of the mesh.d
// decomposition campaign (0407 §B.V2, task 0412) — see that task/doc for the
// architectural decision (mixin template over a package move or UFCS
// free-functions) and the full symbol inventory. Method bodies below are
// verbatim cut/paste from mesh.d (only the extraction boundary is new).
// ---------------------------------------------------------------------------
mixin template MeshCutOps() {
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
        bool[] cv;
        Vec3[] ed;
        return planeCutCore(p, n, /*clipped*/false, Vec3(0, 0, 0), Vec3(0, 0, 0),
                            /*restrictFaces*/null, cv, eps, ed);
    }

    // Same as cutByPlane, but RESTRICTED to a face set (`restrictFaces`). Only
    // faces in the set are chord-split, and crossing verts are inserted only on
    // THEIR edges (a shared edge with an unselected neighbour still gets the
    // vert, which the neighbour absorbs as an n-gon so the cut stays watertight)
    // — the interactive Slice tool's "cut only the selected polygons" behavior
    // (mirrors Loop Slice's Slice Selected). An empty/null set ⇒ whole-mesh cut.
    size_t cutByPlaneRestricted(Vec3 p, Vec3 n, const uint[] restrictFaces,
                                float eps = 1e-5f) {
        bool[] cv;
        Vec3[] ed;
        return planeCutCore(p, n, /*clipped*/false, Vec3(0, 0, 0), Vec3(0, 0, 0),
                            restrictFaces, cv, eps, ed);
    }

    // -----------------------------------------------------------------------
    // isConcaveFace (task 0310) — true iff polygon fi has at least one reflex
    // (non-convex) vertex: a sign flip in cross(edgeIn, edgeOut)·n across the
    // winding (n = faceNormal, Newell's method — tolerant of slightly
    // non-planar n-gons). Triangles are always convex (fast return). Used by
    // planeCutCore's terminus/keyhole guard below — the technique's "chord
    // clipped at one band boundary" assumption doesn't reliably generalize
    // once a concave polygon is involved (see that guard's comment).
    // -----------------------------------------------------------------------
    private bool isConcaveFace(uint fi) const {
        const uint[] face = faces[fi];
        if (face.length < 4) return false;
        Vec3 n = faceNormal(fi);
        bool sawPos = false, sawNeg = false;
        immutable float eps = 1e-7f;
        foreach (i; 0 .. face.length) {
            Vec3 prev = vertices[face[(i + face.length - 1) % face.length]];
            Vec3 cur  = vertices[face[i]];
            Vec3 next = vertices[face[(i + 1) % face.length]];
            float s = dot(cross(cur - prev, next - cur), n);
            if (s >  eps) sawPos = true;
            if (s < -eps) sawNeg = true;
        }
        return sawPos && sawNeg;
    }

    // -----------------------------------------------------------------------
    // planeCutCore — the shared cut body behind cutByPlane / cutByPlaneClipped
    // (and cutByPlaneEx). When `clipped` is false this is byte-for-byte the
    // original cutByPlane (the `bandOk*` predicates collapse to `true`); when
    // `clipped` is true it is byte-for-byte the original cutByPlaneClipped (the
    // in-band filter gates on the drawn [segStart,segEnd] span). Fills
    // `isCutVertOut` with the per-vertex cut mask AFTER the split so callers that
    // need the cut loop (cutByPlaneEx / S7 split) can walk it; returns the number
    // of faces split (0 = no effective cut, mesh untouched).
    // -----------------------------------------------------------------------
    private size_t planeCutCore(Vec3 p, Vec3 n, bool clipped,
                                Vec3 segStart, Vec3 segEnd,
                                const uint[] restrictFaces,
                                out bool[] isCutVertOut, float eps,
                                out Vec3[] cutEdgeDirOut) {
        isCutVertOut = null;
        cutEdgeDirOut = null;
        if (vertices.length == 0 || faces.length == 0 || edges.length == 0)
            return 0;

        // Selection restriction (task 0279): when `restrictFaces` is non-empty,
        // the cut is confined to those faces — the reference Slice cuts ONLY the
        // selected polygons, terminating watertight at the selection border. We
        // mark the restricted faces plus, for each, its winding vertices + edges
        // so Pass-1 inserts a crossing vertex ONLY on an edge that belongs to a
        // restricted face (a shared border edge still gets it, and the
        // unselected neighbour absorbs the vertex as an n-gon), Pass-2 splits
        // ONLY restricted faces, and an on-plane vertex counts as a cut vertex
        // only when it belongs to a restricted face. Empty ⇒ whole-mesh cut,
        // byte-for-byte the original (the `restricted` guard collapses out).
        bool restricted = restrictFaces.length > 0;
        bool[] faceInRestrict, vertInRestrict, edgeInRestrict;
        if (restricted) {
            faceInRestrict.length = faces.length;
            vertInRestrict.length = vertices.length;
            edgeInRestrict.length = edges.length;
            foreach (rf; restrictFaces) {
                if (rf >= faces.length) continue;
                faceInRestrict[rf] = true;
                auto face = faces[rf];
                foreach (k; 0 .. face.length) {
                    uint a = face[k], b = face[(k + 1) % face.length];
                    if (a < vertInRestrict.length) vertInRestrict[a] = true;
                    if (b < vertInRestrict.length) vertInRestrict[b] = true;
                    uint ei = edgeIndexOfVerts(a, b);
                    if (ei != ~0u && ei < edgeInRestrict.length)
                        edgeInRestrict[ei] = true;
                }
            }
        }

        // Segment (clipped only): a degenerate span has no direction to clip
        // along, so it cuts nothing — the infinite case never reaches here.
        Vec3 seg = Vec3(segEnd.x - segStart.x, segEnd.y - segStart.y,
                        segEnd.z - segStart.z);
        float segLen2 = seg.x * seg.x + seg.y * seg.y + seg.z * seg.z;
        if (clipped && segLen2 < eps * eps) return 0;

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

        // In-band predicates. With `clipped` off they are constant `true`, so the
        // whole body reduces to the infinite cut with no numeric change (and the
        // segLen2 division is never reached via short-circuit).
        bool inBand(Vec3 q) {
            float s = ((q.x - segStart.x) * seg.x + (q.y - segStart.y) * seg.y
                     + (q.z - segStart.z) * seg.z) / segLen2;
            return s >= -eps && s <= 1.0f + eps;
        }
        Vec3 crossPoint(uint a, uint b) {
            float da = dv[a], db = dv[b];
            float t = da / (da - db);
            Vec3 va = vertices[a], vb = vertices[b];
            return Vec3(va.x + t * (vb.x - va.x),
                        va.y + t * (vb.y - va.y),
                        va.z + t * (vb.z - va.z));
        }
        bool bandOkVert(uint a)          { return !clipped || inBand(vertices[a]); }
        bool bandOkCross(uint a, uint b) { return !clipped || inBand(crossPoint(a, b)); }

        // Pre-check: determine whether any face will actually be split.
        // Avoids touching the mesh (no addVertex calls) when the plane misses.
        // Simulates the post-insertion winding positions to test adjacency.
        {
            bool anyWillSplit = false;
            foreach (fi; 0 .. faces.length) {
                if (restricted && !faceInRestrict[fi]) continue; // only restricted faces split
                auto face = faces[fi];
                size_t insertsBefore = 0; // cumulative insertions tracking winding shifts
                size_t[] hitPos;
                foreach (k; 0 .. face.length) {
                    uint a = face[k];
                    uint b = face[(k + 1) % face.length];
                    if (onPlane[a] && bandOkVert(a))
                        hitPos ~= k + insertsBefore;
                    if (!onPlane[a] && !onPlane[b]) {
                        float da = dv[a], db = dv[b];
                        if ((da > 0 && db < 0) || (da < 0 && db > 0)) {
                            if (bandOkCross(a, b)) {
                                // straddle — new vert inserted after position k
                                insertsBefore++;
                                hitPos ~= k + insertsBefore;
                            }
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

        // Clipped-only terminus detection (task 0289). A drawn segment that
        // ENTERS a polygon through a boundary edge but STOPS inside it (the far
        // boundary crossing lies BEYOND the segment's end) leaves the plane∩poly
        // chord clipped at a band boundary. The reference inserts an interior
        // vertex at that clip point + a SLIT edge back to the entry crossing
        // (keyhole winding, face NOT split). Computed here on the ORIGINAL
        // windings (before Pass-1 splices crossing verts) and spliced in after
        // Pass-1, once the entry crossing vertex exists. Empty for the infinite
        // cut (clipped == false), so that path is byte-for-byte unchanged.
        //
        // Concave guard (task 0310): the "exactly 2 boundary crossings ⇒ a
        // single valid chord, clip whichever end sticks out of the band"
        // assumption is convex-only. Near a concave (reflex) polygon it can
        // misfire even when each individual face's own 2-crossing scan looks
        // "simple": e.g. two faces sharing a crossing edge can each
        // independently keyhole off the SAME entry vertex toward OPPOSITE
        // band boundaries, leaving that vertex visited twice in one face's
        // winding (repeated index — task 0310's fuzz-found corruption on a
        // concave `lshape` cut). Precompute which edges border a concave
        // face and decline a would-be terminus whenever either of its two
        // crossing edges is one of them — the crossing vertex still gets
        // spliced in by Pass-1 (the face is simply left un-keyholed/whole,
        // or cleanly chord-split if its other crossing also lands in-band),
        // never duplicated. A convex-only mesh (the original task 0289 cube)
        // never sets any bit here — byte-for-byte unchanged.
        bool[] edgeTouchesConcaveFace;
        if (clipped) {
            edgeTouchesConcaveFace.length = edges.length;
            foreach (fi; 0 .. faces.length) {
                if (!isConcaveFace(cast(uint)fi)) continue;
                auto cface = faces[fi];
                foreach (k; 0 .. cface.length) {
                    uint a = cface[k], b = cface[(k + 1) % cface.length];
                    uint cei = edgeIndexOfVerts(a, b);
                    if (cei != ~0u && cei < edgeTouchesConcaveFace.length)
                        edgeTouchesConcaveFace[cei] = true;
                }
            }
        }

        struct TermRec { size_t faceIdx; Vec3 point; }
        TermRec[] termini;
        if (clipped) {
            foreach (fi; 0 .. faces.length) {
                if (restricted && !faceInRestrict[fi]) continue;
                auto face = faces[fi];
                // Gather the face's plane-straddle boundary crossings with their
                // segment param s (+ the crossed edge index, for the concave
                // guard below). An on-plane winding vertex makes the chord
                // ambiguous (v1: skip such faces).
                bool hasOnPlane = false;
                Vec3[2] cxPt;
                float[2] cxS;
                uint[2] cxEdge;
                size_t nCx = 0;
                foreach (k; 0 .. face.length) {
                    uint a = face[k], b = face[(k + 1) % face.length];
                    if (onPlane[a]) { hasOnPlane = true; break; }
                    float da = dv[a], db = dv[b];
                    if ((da > 0 && db < 0) || (da < 0 && db > 0)) {
                        if (nCx >= 2) { nCx = 3; break; }   // >2 crossings: not a simple chord
                        Vec3 q = crossPoint(a, b);
                        cxPt[nCx] = q;
                        cxS[nCx] = ((q.x - segStart.x) * seg.x
                                  + (q.y - segStart.y) * seg.y
                                  + (q.z - segStart.z) * seg.z) / segLen2;
                        cxEdge[nCx] = edgeIndexOfVerts(a, b);
                        nCx++;
                    }
                }
                if (hasOnPlane || nCx != 2) continue;       // need a clean 2-crossing chord
                // Order the two crossings by s (s0 <= s1).
                size_t lo = (cxS[0] <= cxS[1]) ? 0 : 1, hi = 1 - lo;
                float s0 = cxS[lo], s1 = cxS[hi];
                // Terminus only when EXACTLY one crossing is in band [0,1] and the
                // other is out on the opposite side (chord clipped at a band edge).
                float clip;
                bool isTerm = false;
                if (s0 >= -eps && s0 <= 1.0f + eps && s1 > 1.0f + eps) {
                    clip = 1.0f; isTerm = true;             // clip high, terminus at s=1
                } else if (s1 >= -eps && s1 <= 1.0f + eps && s0 < -eps) {
                    clip = 0.0f; isTerm = true;             // clip low, terminus at s=0
                }
                if (!isTerm) continue;
                // Concave guard (task 0310): decline if either crossing edge
                // borders a concave face (see edgeTouchesConcaveFace above).
                uint eLo = cxEdge[lo], eHi = cxEdge[hi];
                if ((eLo != ~0u && eLo < edgeTouchesConcaveFace.length && edgeTouchesConcaveFace[eLo]) ||
                    (eHi != ~0u && eHi < edgeTouchesConcaveFace.length && edgeTouchesConcaveFace[eHi]))
                    continue;
                // Interpolate the chord to the clip param (strictly inside the poly).
                float f = (clip - s0) / (s1 - s0);
                Vec3 A = cxPt[lo], Bp = cxPt[hi];
                termini ~= TermRec(fi, Vec3(A.x + f * (Bp.x - A.x),
                                            A.y + f * (Bp.y - A.y),
                                            A.z + f * (Bp.z - A.z)));
            }
        }

        // Pass 1 — edge subdivide: for each straddling edge insert one crossing
        // vertex into every incident face winding (T-junction prevention).
        bool[] isCutVert;
        isCutVert.length = vertices.length;
        foreach (vi; 0 .. vertices.length)
            isCutVert[vi] = onPlane[vi] && bandOkVert(cast(uint)vi)
                          && (!restricted || vertInRestrict[vi]);

        // Per-cut-vertex CROSSED-EDGE direction (task 0290). For every vertex the
        // cut inserts on a straddling edge [a,b], record the UNIT direction of
        // that original edge, ORIENTED toward the plane's POSITIVE-side endpoint
        // (the one with dv > 0, the same side the plane normal `n` points to). The
        // Slice `gap` pass (splitAlongCutLoop) separates each [lo,hi] seam pair
        // ALONG this edge direction instead of along the plane normal, so both
        // half-edges of a split edge stay COLLINEAR with the original edge. On-plane
        // original cut verts have no single crossed edge — their entry stays zero,
        // which the gap pass reads as "fall back to the plane normal".
        Vec3[uint] edgeDirOf;
        size_t origEdgeCount = edges.length;
        foreach (ei; 0 .. origEdgeCount) {
            uint a = edges[ei][0], b = edges[ei][1];
            if (a >= dv.length || b >= dv.length) continue;
            if (restricted && !edgeInRestrict[ei]) continue; // outside the selection region
            if (onPlane[a] || onPlane[b]) continue; // endpoint on-plane: skip new vert
            float da = dv[a], db = dv[b];
            if (!((da > 0 && db < 0) || (da < 0 && db > 0))) continue; // same side
            if (!bandOkCross(a, b)) continue;                          // CLIP to drawn span

            uint vi = insertEdgePoint(cast(uint)ei, da / (da - db), isCutVert);
            // Unit edge direction toward the +n-side endpoint (positive dv). `da`
            // and `db` are opposite-signed here (straddle), so exactly one is > 0.
            uint posEnd = (da > 0) ? a : b;
            uint negEnd = (da > 0) ? b : a;
            edgeDirOf[vi] = normalize(vertices[posEnd] - vertices[negEnd]);
        }

        // Splice each terminus keyhole (task 0289): add the interior vertex T at
        // the clip point and connect it to the entry crossing B (the face's lone
        // in-band cut vert) as [.., B, T, B, ..]. T is NOT marked a cut vert, so
        // the face still carries a single cut vert and is copied whole by Pass-2;
        // it is also excluded from the split mask so the doubled B never triggers
        // a chord split.
        bool[] termFace;
        if (termini.length) {
            termFace.length = faces.length;
            foreach (rec; termini) {
                if (rec.faceIdx >= faces.length) continue;
                auto face = faces[rec.faceIdx];
                // Locate the lone in-band cut vertex B in this winding.
                size_t bk = size_t.max;
                foreach (k; 0 .. face.length)
                    if (face[k] < isCutVert.length && isCutVert[face[k]]) { bk = k; break; }
                if (bk == size_t.max) continue;             // no entry crossing — skip
                uint bVert = face[bk];
                uint tVert = addVertex(rec.point);
                if (isCutVert.length < vertices.length)
                    isCutVert.length = vertices.length;     // grow; T stays non-cut (false)
                faces[rec.faceIdx] = face[0 .. bk + 1] ~ [tVert, bVert] ~ face[bk + 1 .. $];
                termFace[rec.faceIdx] = true;
            }
        }

        // Pass 2 + finalize: split eligible faces (empty mask = all faces; a
        // restricted cut splits ONLY the selected faces — unselected neighbours
        // that received a shared crossing vertex are copied whole as n-gons). When
        // termini exist, pass an explicit all-eligible-except-terminus mask so the
        // keyhole faces are copied whole (byte-for-byte unchanged when none exist).
        bool[] effMask;
        if (termini.length) {
            effMask.length = faces.length;
            foreach (fi; 0 .. faces.length)
                effMask[fi] = (!restricted || faceInRestrict[fi]) && !termFace[fi];
        } else if (restricted) {
            effMask = faceInRestrict;
        }
        size_t nSplit = rebuildFacesWithChordSplits(effMask, isCutVert);
        isCutVertOut = isCutVert;
        // Materialise the per-vertex edge-direction map into a dense array indexed
        // by vertex (zero where no straddled edge was recorded).
        cutEdgeDirOut.length = vertices.length;
        foreach (vi, dir; edgeDirOf)
            if (vi < cutEdgeDirOut.length) cutEdgeDirOut[vi] = dir;
        return nSplit;
    }

    // -----------------------------------------------------------------------
    // cutByPlaneClipped — like cutByPlane, but the cut is CLIPPED to a drawn
    // segment's extent instead of extending across the whole mesh. Only faces
    // whose plane-crossing chord lies within the [segStart, segEnd] band
    // (measured by projection ALONG the segment direction) are split; geometry
    // outside the drawn span is left whole.
    //
    // This is the interactive Slice tool's `infinite = off` path (mesh.slice-
    // Tool): "only the region under the drawn Start→End line gets cut", vs
    // cutByPlane's whole-mesh infinite plane (`infinite = on`, the current
    // behavior). On a mesh whose cross-section fits WITHIN the drawn line the
    // two agree (every crossing is in-band); they diverge only when the line is
    // shorter than the mesh, where clipped cuts just the spanned faces.
    //
    // Extent rule (in-band ⟺ normalized projection s = dot(q−segStart, seg) /
    // |seg|² ∈ [−eps, 1+eps], seg = segEnd−segStart): a straddle crossing is
    // subdivided ONLY when in-band, and a face is chord-split ONLY when it ends
    // up with exactly two cut vertices (both its crossings in-band). A face
    // sitting on the extent BOUNDARY (one crossing in, one out) keeps the single
    // shared crossing vertex spliced onto its edge and stays whole — it becomes
    // an n-gon (colinear vertex, shared with the split neighbour, so the cut
    // stays watertight with NO T-junction), mirroring how the cut simply "stops"
    // partway. On-plane vertices count as cut vertices only when in-band.
    //
    // A degenerate (zero-length) segment returns 0 — there is no direction to
    // clip along; the infinite case must call cutByPlane. Shares insertEdgePoint
    // + rebuildFacesWithChordSplits with cutByPlane, so the produced topology
    // (index-share crossing verts, chord split) is identical for the in-band
    // faces. Pure data (no GPU / GL), unit-testable under `dub test`.
    // -----------------------------------------------------------------------
    size_t cutByPlaneClipped(Vec3 p, Vec3 n, Vec3 segStart, Vec3 segEnd,
                             float eps = 1e-5f, const uint[] restrictFaces = null) {
        bool[] cv;
        Vec3[] ed;
        return planeCutCore(p, n, /*clipped*/true, segStart, segEnd,
                            restrictFaces, cv, eps, ed);
    }

    // -----------------------------------------------------------------------
    // PlaneCutLoops — the ORDERED cut result the interactive Slice tool consumes
    // for its Split / Cap / Gap options (tasks S7–S9). `loops` is the crossing-
    // vertex ring(s) in connected order (a closed ring for a full mid-plane cut;
    // an open chain for a clipped cut that stops partway). `seamPairs` is the
    // `[lo, hi]` duplicate list produced by the Split option — the SAME shape as
    // the Loop Slice split machinery emits (insertEdgeLoopsMulti's splitPairsOut),
    // so S8 (caps) / S9 (gap) can drive the two sides off it exactly as they do
    // for an edge-ring loop. Empty `seamPairs` ⇒ Split was off (connected cut).
    // -----------------------------------------------------------------------
    struct PlaneCutLoops {
        uint[][]  loops;      // ordered crossing-vertex ring(s) / chain(s)
        uint[2][] seamPairs;  // [lo, hi] per duplicated cut vertex (Split only)
    }

    // -----------------------------------------------------------------------
    // cutByPlaneEx — cutByPlane / cutByPlaneClipped PLUS the ordered cut loop and
    // (optionally) the Split duplication. `clipped` selects the infinite vs
    // drawn-span kernel exactly as the two public wrappers do; with `split` off
    // this is byte-for-byte the corresponding wrapper (it only ALSO walks out the
    // ordered loop into `result.loops`). With `split` on the connected cut loop
    // is DUPLICATED into two coincident boundary loops via `splitAlongCutLoop`
    // (the same lo/hi seam-pair model as the Loop Slice `split` option), opening
    // the surface into two disconnected sections along the cut. Returns the number
    // of faces split (0 = no cut; `result` left empty). Caller owns snapshot/undo.
    // -----------------------------------------------------------------------
    // `gap` (S9, task 0275, distance) + `gapSide` (Offset Side: 0=center,
    // 1=positive, 2=negative) — only meaningful WITH `split`. `gap == 0` (the
    // default) leaves the two duplicated boundary loops COINCIDENT, byte-for-byte
    // the S7/S8 result. Non-zero pushes the two split shells APART along each cut
    // vertex's ORIGINAL CROSSED EDGE (task 0290) so both halves of a split edge
    // stay collinear with the original — equal to the plane normal for an axis-
    // aligned cut, differing only on an oblique/sheared one; see splitAlongCutLoop
    // for the sign policy. Positions only — no topology change.
    size_t cutByPlaneEx(Vec3 p, Vec3 n, bool clipped, Vec3 segStart, Vec3 segEnd,
                        bool split, bool caps, out PlaneCutLoops result, float eps = 1e-5f,
                        const uint[] restrictFaces = null,
                        float gap = 0.0f, int gapSide = 0) {
        bool[] isCutVert;
        Vec3[] cutEdgeDir;
        size_t nSplit = planeCutCore(p, n, clipped, segStart, segEnd,
                                     restrictFaces, isCutVert, eps, cutEdgeDir);
        if (nSplit == 0) return 0;
        // Order the crossing verts into ring(s) from the connected cut BEFORE the
        // split duplicates them (the split rebuilds edges under us).
        result.loops = extractCutLoops(isCutVert);
        // `caps` (S8) is only meaningful WITH `split` — it seals each duplicated
        // boundary loop with a cap polygon (see splitAlongCutLoop / capShellCycles).
        // `gap`/`gapSide` (S9) then separate the two shells along `n`.
        if (split)
            splitAlongCutLoop(isCutVert, p, n, caps, result.seamPairs, eps,
                              gap, gapSide, cutEdgeDir);
        return nSplit;
    }

    // -----------------------------------------------------------------------
    // deleteComponentsInSlab (task 0291) — delete every connected component
    // (faces linked by shared vertices, the same notion `connectedComponentVertices`
    // uses, generalized here to walk every face rather than one island) whose
    // ENTIRE signed-distance range to plane (p,n) lies within
    // [loSigned − eps, hiSigned + eps]. Used by `cutByPlaneSplitGap` to remove
    // the slab a pair of parallel plane cuts opens between two shells.
    //
    // Classification is per-COMPONENT, not per-face (risk 2, task file): a
    // per-face `dv`-band mask would ALSO delete the kept shells' caps, which
    // sit exactly on the slab's own boundary planes. A component's dv-range
    // only collapses inside the slab when the WHOLE component (its cap AND
    // every side face reaching it) never leaves the band — true for the band
    // component alone; the shells above/below always reach past the slab on
    // their far side (their own untouched geometry), so their range's other
    // bound fails the containment test even though their near cap coincides
    // with a slab boundary.
    //
    // Returns the number of faces removed (0 = no component was fully inside
    // the slab — e.g. a partial cut that never fully separated the mesh).
    // -----------------------------------------------------------------------
    size_t deleteComponentsInSlab(Vec3 p, Vec3 n, float loSigned, float hiSigned, float eps) {
        if (faces.length == 0) return 0;

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

        // Per-root signed-distance range over every vertex belonging to that
        // component (vertices not referenced by any face just form their own
        // singleton root and never influence a face's classification below).
        float[int] rootMin, rootMax;
        foreach (vi; 0 .. vertices.length) {
            int r = findRoot(cast(int)vi);
            float dv = n.x * (vertices[vi].x - p.x)
                     + n.y * (vertices[vi].y - p.y)
                     + n.z * (vertices[vi].z - p.z);
            if (auto mn = r in rootMin) { if (dv < *mn) rootMin[r] = dv; } else rootMin[r] = dv;
            if (auto mx = r in rootMax) { if (dv > *mx) rootMax[r] = dv; } else rootMax[r] = dv;
        }

        bool[] mask = new bool[](faces.length);
        size_t nMasked = 0;
        foreach (fi; 0 .. faces.length) {
            if (faces[fi].length == 0) continue;
            uint v0 = faces[fi][0];
            if (v0 >= vertices.length) continue;
            int r = findRoot(cast(int)v0);
            if (rootMin[r] >= loSigned - eps && rootMax[r] <= hiSigned + eps) {
                mask[fi] = true;
                nMasked++;
            }
        }
        // Empty-mesh guard (task 0309): a slab wide enough to swallow the
        // WHOLE mesh (e.g. `gap` at or beyond the mesh's own extent along `n`,
        // where neither parallel cut actually crosses any geometry — the mesh
        // is then still ONE untouched component whose own bounding range
        // trivially satisfies the containment test above) would otherwise
        // delete every remaining face, silently emptying the document. Refuse
        // — leave the mesh untouched and report 0 removed, so the caller
        // (`cutByPlaneSplitGap`'s `separated` flag) sees "not separated" and
        // falls back to the legacy single-cut+slide path exactly as it already
        // does for a genuine partial (non-disconnecting) cut.
        if (nMasked == faces.length) return 0;
        return deleteFacesByMask(mask);
    }

    // -----------------------------------------------------------------------
    // cutByPlaneSplitGap (task 0291) — Split + Caps + Gap via TWO REAL parallel
    // plane cuts, replacing the single-cut + fixed along-edge slide
    // (`splitAlongCutLoop`'s gap block) for the unrestricted whole-mesh case.
    // The single-cut slide slides each seam vert a FIXED distance along its own
    // crossed edge; on dense/curved geometry a graze vert (dv≈0 at the plane)
    // overshoots past the edge's far endpoint for ANY gap>0, scattering the
    // seam off the cut plane and producing a self-intersecting cap (the
    // reported bug). Two REAL cuts cannot overshoot: each seam vert is placed
    // by `planeCutCore` at the exact intersection of a REAL edge with a REAL
    // plane — an edge that never reaches a plane is simply not crossed, no
    // phantom vertex is ever produced.
    //
    // Steps (verified algorithm, doc/slice_gap_two_cut_plan.md):
    //   1. Cut at `p + n·loAmt` (split+caps, gap=0) — splits the mesh into
    //      {above +offset} and {below +offset}, each already capped there.
    //   2. Cut at `p − n·hiAmt` (split+caps, gap=0) on the WHOLE mesh — only
    //      {below +offset} straddles −offset; it re-splits into {band} (its
    //      OTHER cap is cut 1's +offset cap, inherited whole since none of its
    //      verts cross −offset) and {below −offset}, both now capped at
    //      −offset. {above +offset} is untouched (never reaches −offset).
    //   3. `deleteComponentsInSlab` removes the one component whose entire
    //      dv-range sits inside `[−hiAmt, +loAmt]` — the band.
    //
    // `separated` is TRUE iff a band component was found and removed (the two
    // cuts fully disconnected the mesh). FALSE means a PARTIAL cut (e.g. a
    // short clipped line that doesn't span the whole shape) left the shells
    // stitched together — `deleteComponentsInSlab` then finds nothing to
    // remove. The CALLER (slice_tool.sliceSplitGap) must roll back and fall
    // back to the legacy single-cut+slide in that case, so today's partial-cut
    // gap behaviour is not silently dropped.
    //
    // `restrictFaces` is accepted for interface symmetry with `cutByPlaneEx`
    // but is expected empty here: the two cuts shift face indices between
    // calls, so a restrict set captured before cut 1 would be stale for cut 2.
    // A restricted split-gap keeps its own single-cut path (the caller gates
    // on `restrictFaces.length == 0` before routing here at all).
    // -----------------------------------------------------------------------
    size_t cutByPlaneSplitGap(Vec3 p, Vec3 n, bool clipped, Vec3 segStart, Vec3 segEnd,
                              bool caps, float gap, int gapSide, out bool separated,
                              const uint[] restrictFaces = null, float eps = 1e-5f) {
        float loAmt, hiAmt;
        switch (gapSide) {
            case 1:  loAmt = gap;        hiAmt = 0.0f;       break;  // positive
            case 2:  loAmt = 0.0f;       hiAmt = gap;        break;  // negative
            default: loAmt = gap * 0.5f; hiAmt = gap * 0.5f; break;  // center
        }
        PlaneCutLoops r1, r2;
        size_t n1 = cutByPlaneEx(p + n * loAmt, n, clipped, segStart, segEnd,
                                 /*split*/true, caps, r1, eps, restrictFaces, 0.0f, 0);
        size_t n2 = cutByPlaneEx(p - n * hiAmt, n, clipped, segStart, segEnd,
                                 /*split*/true, caps, r2, eps, restrictFaces, 0.0f, 0);
        size_t removed = deleteComponentsInSlab(p, n, -hiAmt, +loAmt, 1e-4f);
        separated = (removed > 0);
        return n1 + n2;
    }

    // -----------------------------------------------------------------------
    // extractCutLoops — walk the crossing verts of a completed plane cut into
    // ordered ring(s). A "chord edge" of the cut is an edge whose BOTH endpoints
    // are cut verts (the chord each split face contributes); those edges chain
    // the crossing verts into a closed ring (full cut) or an open path (clipped
    // cut that stops partway). Degree-1 endpoints (open chains) are emitted first,
    // then any remaining closed cycles. Pure read of edges/isCutVert.
    // -----------------------------------------------------------------------
    private uint[][] extractCutLoops(const bool[] isCutVert) {
        import std.algorithm : sort;
        bool cut(uint v) { return v < isCutVert.length && isCutVert[v]; }
        uint[][uint] adj;
        foreach (e; edges) {
            uint a = e[0], b = e[1];
            if (cut(a) && cut(b)) { adj[a] ~= b; adj[b] ~= a; }
        }
        bool[uint] visited;
        uint[][] loops;
        void walk(uint s) {
            if (s in visited) return;
            uint[] chain;
            uint cur = s, prev = ~0u;
            while (true) {
                chain ~= cur;
                visited[cur] = true;
                uint next = ~0u;
                foreach (w; adj[cur])
                    if (w != prev && (w !in visited)) { next = w; break; }
                if (next == ~0u) break;
                prev = cur;
                cur  = next;
            }
            if (chain.length > 0) loops ~= chain;
        }
        // Deterministic order: open-chain endpoints (degree 1) first, then the
        // rest (closed cycles), each started at its lowest-index vertex.
        uint[] ends, all;
        foreach (v, nb; adj) { all ~= v; if (nb.length == 1) ends ~= v; }
        sort(ends);
        sort(all);
        foreach (v; ends) walk(v);
        foreach (v; all)  walk(v);
        return loops;
    }

    // -----------------------------------------------------------------------
    // splitAlongCutLoop — the Slice `split` option (S7). Given a completed plane
    // cut (isCutVert marks the crossing verts) it DUPLICATES each crossing vertex
    // into a coincident lo/hi pair and re-points every face on the plane's
    // NEGATIVE side at the duplicate, so the single connected cut becomes two
    // disconnected boundary loops — the identical lo/hi seam-pair model the Loop
    // Slice `split` option uses (insertEdgeLoopsMulti's railMids/splitSeams), just
    // fed a plane-cut loop instead of an edge-ring loop. Duplicates are made
    // LAZILY (only when a negative-side face actually references a crossing vert)
    // so no orphan verts appear; a face whose non-cut verts STRADDLE the plane (a
    // boundary "cut stops here" face in the clipped-open case) is left stitched so
    // the two sides stay joined there. `seamPairs` receives one [lo, hi] entry per
    // duplicated crossing vertex — the data S8 (caps) / S9 (gap) act on.
    // -----------------------------------------------------------------------
    private void splitAlongCutLoop(const bool[] isCutVert, Vec3 planeP, Vec3 planeN,
                                   bool caps, out uint[2][] seamPairs, float eps,
                                   float gap = 0.0f, int gapSide = 0,
                                   const Vec3[] cutEdgeDir = null) {
        bool cut(uint v) { return v < isCutVert.length && isCutVert[v]; }
        uint[uint] dupOf;
        uint getDup(uint vi) {
            if (auto d = vi in dupOf) return *d;
            uint nv = addVertex(vertices[vi]);
            dupOf[vi] = nv;
            seamPairs ~= cast(uint[2])[vi, nv];
            return nv;
        }
        foreach (fi; 0 .. faces.length) {
            int pos = 0, neg = 0;
            foreach (v; faces[fi]) {
                if (cut(v)) continue;
                float d = planeN.x * (vertices[v].x - planeP.x)
                        + planeN.y * (vertices[v].y - planeP.y)
                        + planeN.z * (vertices[v].z - planeP.z);
                if      (d >  eps) ++pos;
                else if (d < -eps) ++neg;
            }
            // Remap only faces wholly on the negative side (pos == 0); a
            // straddling boundary face keeps the shared originals (stays stitched).
            if (neg > 0 && pos == 0) {
                auto f = faces[fi].dup;
                bool changed = false;
                foreach (ref v; f)
                    if (cut(v)) { v = getDup(v); changed = true; }
                if (changed) faces[fi] = f;
            }
        }
        if (seamPairs.length == 0) return;   // nothing duplicated — no-op
        // Gap / Offset Side (S9, task 0275; DIRECTION fix task 0290): open a band of
        // width `gap` between the two split shells by pushing each coincident
        // [lo,hi] seam pair apart ALONG THE ORIGINAL CROSSED EDGE (`cutEdgeDir`,
        // per cut vertex, unit, oriented toward the plane's +n side), NOT along the
        // plane normal. A cut vertex sits on a specific original edge; separating
        // the pair along that edge's own line keeps BOTH half-edges of a split edge
        // COLLINEAR with the original (the reference behavior — the split edge does
        // not bend). For an AXIS-ALIGNED cube whose crossed edges are parallel to
        // `n` (e.g. the slice_gap golden: line ‖Z ⇒ n = −X, crossed edges ‖X) the
        // edge direction EQUALS ±n, so this is byte-for-byte the old normal push;
        // it only differs on a SHEARED / oblique cut where edge ≠ normal.
        //
        // WHICH SHELL IS WHICH: `lo` (pr[0], the ORIGINAL crossing vert) is kept
        // by faces wholly on the plane's POSITIVE side (n·(v−p) > 0); `hi` (pr[1],
        // the DUPLICATE) is referenced by the NEGATIVE-side faces (the remap above).
        // So lo belongs to the +n shell, hi to the −n shell. `cutEdgeDir` points
        // toward the edge's +n-side endpoint, so `lo += dir·loAmt` slides lo toward
        // its own (+n) endpoint and `hi −= dir·hiAmt` slides hi toward the −n one —
        // separating them by exactly `gap` measured ALONG the edge.
        //
        // OFFSET SIDE sign policy (total separation along the edge is always `gap`):
        //   center   (0): symmetric — lo += dir·gap/2, hi −= dir·gap/2.
        //   positive (1): the +n-side shell (lo) takes the FULL gap; hi stays put.
        //   negative (2): the −n-side shell (hi) takes the FULL gap; lo stays put.
        // On-plane original cut verts (no straddled edge) have a zero `cutEdgeDir`
        // entry ⇒ fall back to the plane normal `planeN` for that pair.
        // `gap == 0` leaves every pair coincident (byte-for-byte S7/S8). Positions
        // only — no topology change; any `caps` quads gain real (nonzero) area.
        // Each seam vert is unique to one pair, so no vert is displaced twice.
        if (gap != 0.0f) {
            float loAmt, hiAmt;
            switch (gapSide) {
                case 1:  loAmt = gap;        hiAmt = 0.0f;       break;  // positive
                case 2:  loAmt = 0.0f;       hiAmt = gap;        break;  // negative
                default: loAmt = gap * 0.5f; hiAmt = gap * 0.5f; break;  // center
            }
            foreach (pr; seamPairs) {
                // Separation direction = the ORIGINAL crossed edge (toward +n side);
                // fall back to the plane normal for on-plane cut verts (zero dir).
                Vec3 dir = (pr[0] < cutEdgeDir.length) ? cutEdgeDir[pr[0]] : Vec3(0, 0, 0);
                if (dir.x == 0.0f && dir.y == 0.0f && dir.z == 0.0f) dir = planeN;
                vertices[pr[0]] = vertices[pr[0]] + dir * loAmt;   // lo → toward +n endpoint
                vertices[pr[1]] = vertices[pr[1]] - dir * hiAmt;   // hi → toward −n endpoint
            }
        }
        // Cap Sections (S8, task 0274): seal each opened section with ONE cap
        // polygon that fills that section's own boundary loop — the SAME geometry
        // as the Loop Slice Cap Sections option (shared `capShellCycles`, task
        // 0252/0261): the positive shell's boundary is the `lo` originals, the
        // negative shell's the `hi` duplicates. Each shell's boundary loop is
        // filled by one polygon (reversed to oppose that shell's side faces),
        // adding NO verts and NO edges (every cap edge reuses an existing shell
        // boundary edge). `caps` is only meaningful once `split` duplicated the
        // loop; the two shells stay disconnected so a Gap (S9) opens a real band.
        if (caps) {
            bool[uint] loSet, hiSet;
            foreach (pr; seamPairs) { loSet[pr[0]] = true; hiSet[pr[1]] = true; }
            foreach (cyc; capShellCycles(faces, loSet)) faces ~= cyc;
            foreach (cyc; capShellCycles(faces, hiSet)) faces ~= cyc;
        }
        rebuildEdges();
        clearEdgeSelectionResize();
        buildLoops();
        syncSelection();
        commitChange(MeshEditScope.Geometry);
    }
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

unittest { // cutByPlaneRestricted (task 0279): cut confined to the selected faces
    import std.math : abs;
    // The Slice tool cuts ONLY the selected polygons. An x=0 plane (normal +X)
    // crosses the cube's 4 X-spanning faces; restricting to the two Z-facing
    // faces (front z=-0.5, back z=+0.5) must split ONLY those two — 12v/8f — with
    // the two unselected crossed neighbours (top/bottom) absorbing their shared
    // crossing vertex as a watertight n-gon. Reference-captured: 12v/8f (task
    // 0279).
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    uint[] restrict;
    foreach (fi; 0 .. m.faces.length) {
        bool allFront = true, allBack = true;
        foreach (vi; m.faces[fi]) {
            if (m.vertices[vi].z > -0.49f) allFront = false;
            if (m.vertices[vi].z <  0.49f) allBack  = false;
        }
        if (allFront || allBack) restrict ~= cast(uint)fi;
    }
    assert(restrict.length == 2, "cube has exactly two Z-facing faces");
    size_t nSplit = m.cutByPlaneRestricted(Vec3(0, 0, 0), Vec3(1, 0, 0), restrict);
    assert(nSplit == 2, "only the 2 selected faces split");
    assert(m.faces.length == 8, "6 → 8 (each selected face → 2; neighbours stay whole)");
    assert(m.vertices.length == 12, "4 crossing verts at the selected faces' spanning edges");
    // Watertight: no orphan verts, no degenerate faces.
    bool[] refd = new bool[](m.vertices.length);
    foreach (face; m.faces) foreach (vi; face) refd[vi] = true;
    foreach (r; refd) assert(r, "no orphan vertex after a restricted cut");
    foreach (face; m.faces) assert(face.length >= 3, "no degenerate sub-face");
}

unittest { // cutByPlaneRestricted: 1 selected face → only it splits (10v/7f)
    import std.math : abs;
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    uint[] restrict;
    foreach (fi; 0 .. m.faces.length) {
        bool allFront = true;
        foreach (vi; m.faces[fi]) if (m.vertices[vi].z > -0.49f) allFront = false;
        if (allFront) restrict ~= cast(uint)fi;
    }
    assert(restrict.length == 1, "exactly one front (z=-0.5) face");
    size_t nSplit = m.cutByPlaneRestricted(Vec3(0, 0, 0), Vec3(1, 0, 0), restrict);
    assert(nSplit == 1, "only the front face splits");
    assert(m.faces.length == 7, "6 → 7");
    assert(m.vertices.length == 10, "only 2 crossing verts on the front face's spanning edges");
    // The whole-cut-only crossing verts on the UNSELECTED back face (0, ±0.5, +0.5)
    // must be ABSENT — proof the cut stopped at the selection.
    foreach (v; m.vertices)
        assert(!(abs(v.x) < 1e-4f && abs(v.z - 0.5f) < 1e-4f),
               "no crossing vertex may land on the unselected back face");
}

unittest { // cutByPlaneRestricted: empty/null set == whole cut, byte-for-byte
    auto a = makeCube(); a.buildLoops(); a.resetSelection();
    auto b = makeCube(); b.buildLoops(); b.resetSelection();
    size_t na = a.cutByPlaneRestricted(Vec3(0, 0, 0), Vec3(1, 0, 0), null);
    size_t nb = b.cutByPlane(Vec3(0, 0, 0), Vec3(1, 0, 0));
    assert(na == nb, "empty restrict set cuts identically to the whole cut");
    assert(a.faces.length == b.faces.length && a.faces.length == 10);
    assert(a.vertices.length == b.vertices.length && a.vertices.length == 12);
}

unittest { // cutByPlaneClipped: a full-span segment agrees with cutByPlane (infinite)
    // The cube's cross-section fits within the drawn line (Z from -1 to 1, cube
    // spans ±0.5), so the clip is a no-op — every crossing is in-band and the
    // clipped cut reproduces the whole-belt topology exactly (12v/10f).
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    // Plane x=0 (normal X); segment along Z spanning the cube.
    size_t nSplit = m.cutByPlaneClipped(Vec3(0, 0, 0), Vec3(1, 0, 0),
                                        Vec3(0, 0, -1), Vec3(0, 0, 1));
    assert(nSplit == 4, "full-span clip == infinite: 4 side faces split");
    assert(m.faces.length == 10, "full-span clip: 6 → 10 faces");
    assert(m.vertices.length == 12, "full-span clip: 8 + 4 crossing verts");
}

unittest { // cutByPlaneClipped: a short segment cuts ONLY the spanned faces
    // Two disjoint co-planar quad strips (left x∈[-3,-1], right x∈[1,3]) in the
    // y=0 plane, each 2 quads. The plane z=0 (normal Z) straddles all 4 quads;
    // the drawn segment [(-4,0,0)→(0,0,0)] spans ONLY the left strip (its x∈
    // [-3,-1] crossings are in-band; the right strip's x∈[1,3] are out-of-band).
    static Mesh twoStrips() {
        Mesh m;
        m.vertices = [
            // left strip: bottom row z=-0.5, top row z=+0.5
            Vec3(-3, 0, -0.5f), Vec3(-2, 0, -0.5f), Vec3(-1, 0, -0.5f),
            Vec3(-3, 0,  0.5f), Vec3(-2, 0,  0.5f), Vec3(-1, 0,  0.5f),
            // right strip
            Vec3( 1, 0, -0.5f), Vec3( 2, 0, -0.5f), Vec3( 3, 0, -0.5f),
            Vec3( 1, 0,  0.5f), Vec3( 2, 0,  0.5f), Vec3( 3, 0,  0.5f),
        ];
        m.addFace([0u, 1u, 4u, 3u]);   m.addFace([1u, 2u, 5u, 4u]);   // left
        m.addFace([6u, 7u, 10u, 9u]);  m.addFace([7u, 8u, 11u, 10u]); // right
        m.buildLoops();
        m.resetSelection();
        return m;
    }

    // infinite plane (cutByPlane) cuts ALL 4 quads: +6 crossing verts, 4 → 8 faces.
    Mesh inf = twoStrips();
    size_t nInf = inf.cutByPlane(Vec3(0, 0, 0), Vec3(0, 0, 1));
    assert(nInf == 4, "infinite: all 4 quads split");
    assert(inf.vertices.length == 18 && inf.faces.length == 8,
           "infinite: 12+6 verts / 4→8 faces");

    // clipped to the left strip: only the 2 left quads split (+3 verts, 4 → 6).
    Mesh clip = twoStrips();
    size_t nClip = clip.cutByPlaneClipped(Vec3(0, 0, 0), Vec3(0, 0, 1),
                                          Vec3(-4, 0, 0), Vec3(0, 0, 0));
    assert(nClip == 2, "clipped: only the 2 in-band (left) quads split");
    assert(clip.vertices.length == 15, "clipped: 12 + 3 left crossing verts");
    assert(clip.faces.length == 6, "clipped: 2 split (×2) + 2 whole = 6");
    // The right strip is untouched — no crossing vertex at x>0, z≈0.
    foreach (v; clip.vertices)
        assert(!(v.x > 0.5f && v.z > -0.4f && v.z < 0.4f),
               "clipped: right strip must have no z≈0 crossing vertex");
}

unittest { // cutByPlaneClipped: segment terminating INSIDE a face — interior
    // vertex + slit edge to the entry boundary (task 0289, reference-captured).
    //
    // Plane y=0 (normal +Y); drawn segment (-0.9,0,0)→(0,0,0) enters the back
    // (z=-0.5) and front (z=+0.5) faces through their x=-0.5 edge but STOPS at
    // x=0 (interior). The reference (captured single-interior-point case):
    //   • the LEFT face (both crossings in band) splits cleanly along its chord;
    //   • back & front get a KEYHOLE — an interior terminus vertex at the clip
    //     point (0,0,∓0.5), connected by a slit edge back to the entry crossing
    //     (-0.5,0,∓0.5), spliced as [.., B, T, B, ..] in ONE unsplit face.
    // Result: 8+4 verts, 6+1 faces (only the left clean split adds a face).
    import std.math : abs;
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    assert(m.vertices.length == 8 && m.faces.length == 6);

    size_t nSplit = m.cutByPlaneClipped(Vec3(0, 0, 0), Vec3(0, 1, 0),
                                        Vec3(-0.9f, 0, 0), Vec3(0, 0, 0));
    assert(nSplit >= 1, "the in-band left face must still split cleanly");

    int findVert(float x, float y, float z) {
        foreach (i, v; m.vertices)
            if (abs(v.x - x) < 1e-4f && abs(v.y - y) < 1e-4f && abs(v.z - z) < 1e-4f)
                return cast(int) i;
        return -1;
    }
    int tBack  = findVert(0, 0, -0.5f);   // interior terminus (segment-end clip)
    int tFront = findVert(0, 0,  0.5f);
    int bBack  = findVert(-0.5f, 0, -0.5f); // entry crossing on the x=-0.5 edge
    int bFront = findVert(-0.5f, 0,  0.5f);
    assert(tBack  >= 0 && tFront >= 0, "interior terminus vertices missing");
    assert(bBack  >= 0 && bFront >= 0, "entry boundary crossings missing");

    bool hasEdge(int a, int b) {
        foreach (e; m.edges)
            if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) return true;
        return false;
    }
    assert(hasEdge(tBack, bBack),   "slit edge interior→boundary (back) missing");
    assert(hasEdge(tFront, bFront), "slit edge interior→boundary (front) missing");

    // Keyhole: the terminus is flanked on BOTH sides by its entry crossing in a
    // SINGLE (unsplit) face — never split into two along a degenerate B..B chord.
    bool keyhole(int t, int b) {
        foreach (fi; 0 .. m.faces.length) {
            auto f = m.faces[fi];
            foreach (k; 0 .. f.length)
                if (f[k] == t) {
                    uint prev = f[(k + f.length - 1) % f.length];
                    uint next = f[(k + 1) % f.length];
                    if (prev == b && next == b) return true;
                }
        }
        return false;
    }
    assert(keyhole(tBack, bBack),   "back keyhole winding [..,B,T,B,..] missing");
    assert(keyhole(tFront, bFront), "front keyhole winding [..,B,T,B,..] missing");

    assert(m.vertices.length == 12, "8 + 2 entry + 2 terminus verts");
    assert(m.faces.length == 7, "only the left clean split adds a face (6 → 7)");
}

unittest { // cutByPlaneEx: Slice `split` (S7) — the plane-cut loop reuses the
    // Loop Slice lo/hi seam-pair split model. A cube mid-plane cut (x=0) with
    // split OFF is the connected cut (byte-for-byte cutByPlane: closed shell, 0
    // boundary edges, 1 component); with split ON each of the 4 crossing verts is
    // DUPLICATED into a coincident lo/hi pair, so the single loop becomes TWO
    // boundary loops → +4 verts, +4 edges, SAME faces, 8 boundary edges, 2
    // disconnected shells — the identical topological signature as the Loop Slice
    // split guard (see the insertEdgeLoopsMulti Split unittest).
    import std.math : abs;
    static size_t boundaryEdgeCount(ref Mesh m) {
        size_t n = 0;
        foreach (ei; 0 .. m.edges.length) {
            size_t nf = 0;
            foreach (fi; m.facesAroundEdge(cast(uint)ei)) ++nf;
            if (nf == 1) ++n;
        }
        return n;
    }
    static size_t componentCount(ref Mesh m) {
        auto nf = m.faces.length;
        if (nf == 0) return 0;
        auto parent = new size_t[](nf);
        foreach (i; 0 .. nf) parent[i] = i;
        size_t find(size_t x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void uni(size_t a, size_t b) { parent[find(a)] = find(b); }
        uint[][uint] vFaces;
        foreach (fi, f; m.faces) foreach (v; f) vFaces[v] ~= cast(uint)fi;
        foreach (v, fs; vFaces) foreach (k; 1 .. fs.length) uni(fs[0], fs[k]);
        bool[size_t] roots;
        foreach (i; 0 .. nf) roots[find(i)] = true;
        return roots.length;
    }

    // Split OFF — connected cut, closed manifold cube (byte-for-byte cutByPlane).
    Mesh off = makeCube();
    off.buildLoops();
    off.resetSelection();
    Mesh.PlaneCutLoops offR;
    size_t nOff = off.cutByPlaneEx(Vec3(0, 0, 0), Vec3(1, 0, 0),
                                   /*clipped*/false, Vec3(0, 0, 0), Vec3(0, 0, 0),
                                   /*split*/false, /*caps*/false, offR);
    assert(nOff == 4, "split off: 4 side faces split by the mid-plane cut");
    immutable offV = off.vertices.length, offE = off.edges.length, offF = off.faces.length;
    assert(offV == 12 && offF == 10, "split off: 12v/10f connected cut");
    assert(boundaryEdgeCount(off) == 0, "split off: closed cube, no boundary edges");
    assert(componentCount(off) == 1, "split off: one connected shell");
    assert(offR.seamPairs.length == 0, "split off: no seam pairs");
    // The ordered loop is the 4 crossing verts as one closed ring.
    assert(offR.loops.length == 1 && offR.loops[0].length == 4,
           "split off: one 4-vertex crossing ring");

    // Split ON — each crossing vert duplicated → two disconnected boundary loops.
    Mesh on = makeCube();
    on.buildLoops();
    on.resetSelection();
    Mesh.PlaneCutLoops onR;
    size_t nOn = on.cutByPlaneEx(Vec3(0, 0, 0), Vec3(1, 0, 0),
                                 /*clipped*/false, Vec3(0, 0, 0), Vec3(0, 0, 0),
                                 /*split*/true, /*caps*/false, onR);
    assert(nOn == 4, "split on: same 4 side faces split");
    assert(on.vertices.length == offV + 4, "split on: 4 crossing verts duplicated");
    assert(on.edges.length    == offE + 4, "split on: 4 loop edges doubled into boundaries");
    assert(on.faces.length    == offF,     "split on: splitting duplicates verts, not faces");
    assert(boundaryEdgeCount(on) == 8, "split on: two 4-edge boundary loops (8 boundary edges)");
    assert(componentCount(on) == 2, "split on: two disconnected shells");
    // Seam pairs: one coincident [lo,hi] per crossing vert (same shape as Loop Slice).
    assert(onR.seamPairs.length == 4, "split on: 4 seam pairs (one per crossing vert)");
    foreach (pr; onR.seamPairs) {
        assert(pr[0] != pr[1], "seam lo/hi must be distinct verts");
        Vec3 a = on.vertices[pr[0]], b = on.vertices[pr[1]];
        assert(abs(a.x - b.x) < 1e-6f && abs(a.y - b.y) < 1e-6f && abs(a.z - b.z) < 1e-6f,
               "seam lo/hi coincide (zero gap — Gap/S9 moves them apart later)");
    }
    // No orphan vertices after the split.
    import std.conv : to;
    bool[] refd = new bool[](on.vertices.length);
    foreach (face; on.faces) foreach (vi; face) refd[vi] = true;
    foreach (i, r; refd) assert(r, "split on: vertex " ~ i.to!string ~ " orphaned");

    // Split ON + Cap Sections ON (S8, task 0274) — each of the two boundary loops
    // is sealed by ONE cap polygon (the shared capShellCycles geometry, same as
    // Loop Slice Cap Sections). +2 faces, NO new verts, NO new edges (each cap
    // edge reuses an existing shell boundary edge); both loops close (0 boundary
    // edges) yet the two shells stay DISCONNECTED (each cap seals its own shell).
    Mesh cap = makeCube();
    cap.buildLoops();
    cap.resetSelection();
    Mesh.PlaneCutLoops capR;
    size_t nCap = cap.cutByPlaneEx(Vec3(0, 0, 0), Vec3(1, 0, 0),
                                   /*clipped*/false, Vec3(0, 0, 0), Vec3(0, 0, 0),
                                   /*split*/true, /*caps*/true, capR);
    assert(nCap == 4, "split+caps: same 4 side faces split");
    assert(cap.vertices.length == on.vertices.length, "caps add no verts");
    assert(cap.edges.length    == on.edges.length,    "caps add no edges (reuse boundary edges)");
    assert(cap.faces.length    == on.faces.length + 2, "caps add exactly 2 faces (one per shell)");
    assert(boundaryEdgeCount(cap) == 0, "split+caps: both boundary loops sealed");
    assert(componentCount(cap) == 2, "split+caps: two shells stay disconnected");
    assert(capR.seamPairs.length == 4, "split+caps: still 4 seam pairs for Gap (S9)");
}

unittest { // cutByPlaneEx: Slice `gap` + `gapSide` (S9, task 0275) — the two
    // split shells separate ALONG THE PLANE NORMAL by exactly `gap`, offset per
    // gapSide. Mid-plane cut of a cube with n = +X through X=0: lo (originals) is
    // the +n (x>0) shell, hi (dups) the −n (x<0) shell.
    import std.math : abs;
    enum float G = 0.4f;
    Vec3 P = Vec3(0, 0, 0), N = Vec3(1, 0, 0);

    // gap=0 baseline: 4 coincident pairs (byte-for-byte S7/S8) — proven above.

    // center (0): symmetric — lo at x=+G/2, hi at x=−G/2, separation = G.
    Mesh c = makeCube(); c.buildLoops(); c.resetSelection();
    Mesh.PlaneCutLoops cR;
    c.cutByPlaneEx(P, N, false, P, P, /*split*/true, /*caps*/true, cR,
                   1e-5f, null, /*gap*/G, /*gapSide*/0);
    assert(cR.seamPairs.length == 4);
    foreach (pr; cR.seamPairs) {
        Vec3 lo = c.vertices[pr[0]], hi = c.vertices[pr[1]];
        assert(abs(lo.x - (+G * 0.5f)) < 1e-6f, "center: lo shell at +gap/2");
        assert(abs(hi.x - (-G * 0.5f)) < 1e-6f, "center: hi shell at −gap/2");
        assert(abs((lo.x - hi.x) - G) < 1e-6f, "center: shells separated by exactly gap");
        assert(abs(lo.y - hi.y) < 1e-6f && abs(lo.z - hi.z) < 1e-6f,
               "gap displaces ONLY along the plane normal");
    }

    // positive (1): +n shell (lo) takes the full gap along +n; hi stays on plane.
    Mesh pMesh = makeCube(); pMesh.buildLoops(); pMesh.resetSelection();
    Mesh.PlaneCutLoops pR;
    pMesh.cutByPlaneEx(P, N, false, P, P, true, true, pR, 1e-5f, null, G, 1);
    foreach (pr; pR.seamPairs) {
        assert(abs(pMesh.vertices[pr[0]].x - G)    < 1e-6f, "positive: lo at +gap");
        assert(abs(pMesh.vertices[pr[1]].x - 0.0f) < 1e-6f, "positive: hi stays on plane");
    }

    // negative (2): −n shell (hi) takes the full gap along −n; lo stays on plane.
    Mesh nMesh = makeCube(); nMesh.buildLoops(); nMesh.resetSelection();
    Mesh.PlaneCutLoops nR;
    nMesh.cutByPlaneEx(P, N, false, P, P, true, true, nR, 1e-5f, null, G, 2);
    foreach (pr; nR.seamPairs) {
        assert(abs(nMesh.vertices[pr[0]].x - 0.0f) < 1e-6f, "negative: lo stays on plane");
        assert(abs(nMesh.vertices[pr[1]].x - (-G)) < 1e-6f, "negative: hi at −gap");
    }
}

unittest { // cutByPlaneEx: Slice `gap` on a SHEARED cube — split edges stay
    // COLLINEAR (task 0290). On an OBLIQUE cut the crossed edge is NOT parallel to
    // the plane normal, so pushing the [lo,hi] pair along the normal would BEND the
    // split edge (the pre-0290 bug). The reference separates each pair ALONG THE
    // ORIGINAL EDGE, so both halves stay on the edge's line. Assert exactly that:
    // every seam pair is collinear with one original crossed edge, separated by the
    // gap measured along the edge.
    //
    // NOTE (task 0291, DQ5 — KEEP option): this direct `cutByPlaneEx` call still
    // produces the pre-0291 along-edge SLIDE — that is CORRECT here, because the
    // UNRESTRICTED Slice split+caps+gap tool path no longer reaches this code at
    // all (it routes through `cutByPlaneSplitGap`'s two REAL parallel cuts, whose
    // seam sits at edge∩offset-plane instead). The slide survives only for (a)
    // the restricted split-gap branch, (b) the partial-cut fallback in
    // `slice_tool.sliceSplitGap`, and (c) this direct kernel call — same input,
    // two valid answers depending on the code path that reaches it.
    import std.math : abs, sqrt;
    // Sheared cube: top face displaced +X (repro from the task file).
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,     -0.5f, -0.5f), Vec3( 0.5f,     -0.5f, -0.5f),
        Vec3( 1.146581f,  0.5f, -0.5f), Vec3( 0.146581f, 0.5f, -0.5f),
        Vec3(-0.5f,     -0.5f,  0.5f), Vec3( 0.5f,     -0.5f,  0.5f),
        Vec3( 1.146581f,  0.5f,  0.5f), Vec3( 0.146581f, 0.5f,  0.5f),
    ];
    m.addFace([0u,3u,2u,1u]); m.addFace([4u,5u,6u,7u]);
    m.addFace([0u,4u,7u,3u]); m.addFace([1u,2u,6u,5u]);
    m.addFace([3u,7u,6u,2u]); m.addFace([0u,1u,5u,4u]);
    m.buildLoops(); m.resetSelection();

    // Slice line in xy extruded along Z (axis=z): n = normalize(cross(end-start, +Z)).
    Vec3 s = Vec3(-0.285f, -0.168f, 0.0f), e = Vec3(0.969f, 0.225f, 0.0f);
    Vec3 N = normalize(cross(e - s, Vec3(0, 0, 1)));  // ≈ (0.2991, -0.9542, 0)
    Vec3 P = s;
    enum float G = 0.175f;

    // Original crossed edges (top/bottom face edges the vertical plane cuts).
    static immutable uint[2][4] crossed = [[0,3],[1,2],[5,6],[4,7]];

    Mesh.PlaneCutLoops R;
    // infinite (clipped=false) so the whole cross-section is cut (owner's 16v result).
    size_t nS = m.cutByPlaneEx(P, N, /*clipped*/false, P, P,
                               /*split*/true, /*caps*/true, R, 1e-5f, null,
                               /*gap*/G, /*gapSide*/0);
    assert(nS > 0, "sheared cube: the oblique plane must cut faces");
    assert(R.seamPairs.length == 4, "sheared cube: 4 crossing verts duplicated");

    foreach (pr; R.seamPairs) {
        Vec3 lo = m.vertices[pr[0]], hi = m.vertices[pr[1]];
        // Find the original edge this pair sits on (the one both endpoints are
        // collinear with) and assert perpendicular offset ≈ 0 for BOTH.
        bool matched = false;
        foreach (ce; crossed) {
            Vec3 A = m.vertices[ce[0]], B = m.vertices[ce[1]];
            Vec3 dir = B - A;
            float len = dir.length;
            float perpLo = cross(lo - A, dir).length / len;
            float perpHi = cross(hi - A, dir).length / len;
            if (perpLo < 1e-4f && perpHi < 1e-4f) {
                matched = true;
                // Separation measured along the edge == gap (both halves on the line).
                float sep = sqrt((lo.x-hi.x)*(lo.x-hi.x) + (lo.y-hi.y)*(lo.y-hi.y)
                               + (lo.z-hi.z)*(lo.z-hi.z));
                assert(abs(sep - G) < 1e-4f,
                       "sheared: split-edge pair separated by exactly gap along the edge");
                break;
            }
        }
        assert(matched, "sheared: both halves of every split edge stay COLLINEAR "
                        ~ "with the original edge (not bent along the plane normal)");
    }
}

unittest { // cutByPlane: selected parent → BOTH split halves stay selected
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    m.selectFace(0);

    size_t nSplit = m.cutByPlane(Vec3(0.5f, 0, 0), Vec3(1, 0, 0));

    assert(nSplit == 1, "single quad should produce 1 split");
    assert(m.faces.length == 2, "2 sub-faces after cut");
    assert(m.isFaceSelected(0) && m.isFaceSelected(1),
           "both halves of a selected parent must stay selected");
}

unittest { // cutByPlane: unselected parent → BOTH split halves stay unselected (control)
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    // Deliberately no selectFace() call.

    size_t nSplit = m.cutByPlane(Vec3(0.5f, 0, 0), Vec3(1, 0, 0));

    assert(nSplit == 1, "single quad should produce 1 split");
    assert(m.faces.length == 2, "2 sub-faces after cut");
    assert(!m.isFaceSelected(0) && !m.isFaceSelected(1),
           "an unselected parent's split halves must stay unselected");
}

unittest { // cutByPlaneRestricted: only the selected+masked parents' halves stay selected
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();
    uint[] restrict;
    foreach (fi; 0 .. m.faces.length) {
        bool allFront = true, allBack = true;
        foreach (vi; m.faces[fi]) {
            if (m.vertices[vi].z > -0.49f) allFront = false;
            if (m.vertices[vi].z <  0.49f) allBack  = false;
        }
        if (allFront || allBack) {
            restrict ~= cast(uint)fi;
            m.selectFace(cast(int)fi); // select both Z-facing faces before the cut
        }
    }
    assert(restrict.length == 2, "cube has exactly two Z-facing faces");

    size_t nSplit = m.cutByPlaneRestricted(Vec3(0, 0, 0), Vec3(1, 0, 0), restrict);

    assert(nSplit == 2, "only the 2 selected faces split");
    assert(m.faces.length == 8, "6 → 8 (each selected face → 2; neighbours stay whole)");

    import std.math : abs;
    int nSel = 0;
    foreach (fi; 0 .. m.faces.length) {
        if (!m.isFaceSelected(fi)) continue;
        nSel++;
        // A selected split half is one of the front/back halves: every vertex
        // shares the SAME z (±0.5) — the top/bottom n-gons that merely
        // absorbed a shared crossing vertex are copied whole and unselected.
        float z0 = m.vertices[m.faces[fi][0]].z;
        foreach (vi; m.faces[fi])
            assert(abs(m.vertices[vi].z - z0) < 1e-4f,
                   "a selected face after a restricted cut must be a front/back half");
    }
    assert(nSel == 4, "exactly 4 selected faces: both halves of each of the 2 selected parents");
}

unittest { // cutByPlane: nothing selected before ⇒ nothing selected after (nothing-in ⇒ nothing-out)
    auto m = makeCube();
    m.buildLoops();
    m.resetSelection();

    size_t nSplit = m.cutByPlane(Vec3(0, 0, 0), Vec3(0, 1, 0));

    assert(nSplit == 4, "4 side faces split by mid-plane cut");
    assert(m.faces.length == 10, "6 faces → 4 split (×2) + 2 unchanged = 10");
    assert(m.countSelectedFaces() == 0,
           "nothing selected before the cut ⇒ nothing selected after");
}

// ---------------------------------------------------------------------------
// cutByPlaneSplitGap unittests (task 0291) — shared predicates + the two
// kernel regression gates (Phase 1 axis-cube composition, Phase 3 CC×2
// oblique sliver). See doc/slice_gap_two_cut_plan.md.
// ---------------------------------------------------------------------------
version (unittest) {
    import std.math : abs;

    // Component count via the same DSU-over-shared-vertices idiom as the
    // `boundaryEdgeCount`/`componentCount` locals in the cutByPlaneEx `split`
    // unittest above — walks every face (not just one island).
    private size_t sliceCapComponentCount(ref Mesh m) {
        auto nf = m.faces.length;
        if (nf == 0) return 0;
        auto parent = new size_t[](nf);
        foreach (i; 0 .. nf) parent[i] = i;
        size_t find(size_t x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void uni(size_t a, size_t b) { parent[find(a)] = find(b); }
        uint[][uint] vFaces;
        foreach (fi, f; m.faces) foreach (v; f) vFaces[v] ~= cast(uint)fi;
        foreach (v, fs; vFaces) foreach (k; 1 .. fs.length) uni(fs[0], fs[k]);
        bool[size_t] roots;
        foreach (i; 0 .. nf) roots[find(i)] = true;
        return roots.length;
    }

    // A "cap" face (for these tests) is one whose EVERY corner lies on ONE of
    // the two offset planes (`p + n*loAmt` or `p - n*hiAmt`), within `tol`. By
    // construction (capShellCycles seals exactly the loSet/hiSet crossing
    // verts) this is precise for both an axis-aligned cap (a quad, same
    // corner count as a side face — so a degree heuristic would not
    // discriminate it) and a curved oblique cap (a big N-gon).
    private uint[] sliceCapFaces(ref Mesh m, Vec3 p, Vec3 n, float loAmt, float hiAmt,
                                 float tol) {
        uint[] caps;
        foreach (fi, ref f; m.faces) {
            if (f.length == 0) continue;
            bool onLo = true, onHi = true;
            foreach (vi; f) {
                float dv = dot(n, m.vertices[vi] - p);
                if (abs(dv - loAmt) >= tol) onLo = false;
                if (abs(dv - (-hiAmt)) >= tol) onHi = false;
            }
            if (onLo || onHi) caps ~= cast(uint)fi;
        }
        return caps;
    }

    // Newell's method: a robust normal for a (possibly non-planar) polygon.
    private Vec3 sliceCapNewellNormal(ref Mesh m, uint fi) {
        Vec3 n = Vec3(0, 0, 0);
        const uint[] f = m.faces[fi];
        foreach (i; 0 .. f.length) {
            Vec3 a = m.vertices[f[i]];
            Vec3 b = m.vertices[f[(i + 1) % f.length]];
            n.x += (a.y - b.y) * (a.z + b.z);
            n.y += (a.z - b.z) * (a.x + b.x);
            n.z += (a.x - b.x) * (a.y + b.y);
        }
        return normalize(n);
    }

    private Vec3 sliceCapCentroid(ref Mesh m, uint fi) {
        Vec3 c = Vec3(0, 0, 0);
        const uint[] f = m.faces[fi];
        foreach (vi; f) c = c + m.vertices[vi];
        return c * (1.0f / cast(float) f.length);
    }

    // Max distance of any corner to the face's own best-fit plane (Newell
    // normal through the centroid). ~0 for a truly planar polygon — every
    // corner of a two-cut cap sits on a REAL edge∩plane intersection, so this
    // should be near machine precision on the fixed model.
    private float sliceCapPlanarityDev(ref Mesh m, uint fi) {
        Vec3 n = sliceCapNewellNormal(m, fi);
        Vec3 c = sliceCapCentroid(m, fi);
        float dev = 0.0f;
        foreach (vi; m.faces[fi]) {
            float d = abs(dot(n, m.vertices[vi] - c));
            if (d > dev) dev = d;
        }
        return dev;
    }

    // O(k^2) count of non-adjacent edge-pair crossings of the polygon
    // projected onto its own best-fit plane (an arbitrary in-plane basis ⟂ the
    // Newell normal) — a self-intersecting ("bowtie") n-gon has >=1. This is
    // exactly the sliver-cap symptom the task fixes (task file: 6
    // self-intersections per cap on the pre-fix single-cut+slide).
    private size_t sliceCapSelfX(ref Mesh m, uint fi) {
        const uint[] f = m.faces[fi];
        size_t k = f.length;
        if (k < 4) return 0;
        Vec3 n = sliceCapNewellNormal(m, fi);
        Vec3 arbitrary = (abs(n.x) < 0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        Vec3 u = normalize(cross(n, arbitrary));
        Vec3 v = cross(n, u);
        auto pts = new double[2][](k);
        foreach (i; 0 .. k) {
            Vec3 p = m.vertices[f[i]];
            pts[i] = [cast(double) dot(p, u), cast(double) dot(p, v)];
        }
        static bool segCross(double[2] a, double[2] b, double[2] c, double[2] d) {
            double d1 = (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0]);
            double d2 = (b[0]-a[0])*(d[1]-a[1]) - (b[1]-a[1])*(d[0]-a[0]);
            double d3 = (d[0]-c[0])*(a[1]-c[1]) - (d[1]-c[1])*(a[0]-c[0]);
            double d4 = (d[0]-c[0])*(b[1]-c[1]) - (d[1]-c[1])*(b[0]-c[0]);
            return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
        }
        size_t crossings = 0;
        foreach (i; 0 .. k) {
            size_t i2 = (i + 1) % k;
            foreach (j; i + 1 .. k) {
                size_t j2 = (j + 1) % k;
                // Skip adjacent (and identical) edges — they legitimately
                // share an endpoint, which is not a crossing.
                if (j == i || j2 == i || j == i2) continue;
                if (segCross(pts[i], pts[i2], pts[j], pts[j2])) ++crossings;
            }
        }
        return crossings;
    }
}

unittest { // cutByPlaneSplitGap: axis-cube two-cut COMPOSITION gate (task 0291,
    // Phase 1) — proves cut 2 correctly re-splits cut 1's shell BEFORE trusting
    // the model on curved geometry (the crux, risk 1). Mid-plane cut (n=+X
    // through x=0) of a plain cube, gap 0.2 center (offset ±0.1).
    //
    // PRIMARY (structural): the two cuts fully SEPARATE the mesh (separated
    // == true, a band component was found and removed), leaving exactly 2
    // disconnected capped shells — componentCount==2, 12 faces / 16 verts
    // total (2 shells × [4 side quads + 1 original end face + 1 new cap]),
    // exactly 2 cap faces, and every surviving vertex is either an untouched
    // original corner (|dv| ≈ 0.5) or a seam vert exactly on ±0.1.
    //
    // SECONDARY (slab, with an eps margin so seam verts sitting exactly on
    // ±0.1 don't trip it): no vertex remains strictly INSIDE the removed
    // [-0.1,+0.1] band.
    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();

    Vec3 P = Vec3(0, 0, 0), N = Vec3(1, 0, 0);
    enum float G   = 0.2f;
    enum float OFF = G * 0.5f;   // 0.1

    bool separated;
    size_t n = m.cutByPlaneSplitGap(P, N, /*clipped*/false, P, P,
                                    /*caps*/true, G, /*gapSide*/0, separated);
    assert(n > 0, "the mid-plane must cut the 4 side faces (both cuts)");
    assert(separated, "a full mid-plane cut must fully separate the mesh");

    assert(sliceCapComponentCount(m) == 2, "band removed: exactly 2 shells left");
    assert(m.faces.length    == 12, "2 shells x (4 side + 1 original + 1 cap)");
    assert(m.vertices.length == 16, "2 shells x 8 verts (4 original + 4 cap-ring)");

    auto caps = sliceCapFaces(m, P, N, OFF, OFF, 1e-4f);
    assert(caps.length == 2, "exactly 2 cap faces (one per shell)");

    // Every surviving vertex is either an untouched original corner (dv≈±0.5)
    // or a seam vert exactly on one of the two offset planes (dv≈±0.1) — no
    // vertex should exist at any OTHER distance.
    foreach (v; m.vertices) {
        float dv = dot(N, v - P);
        bool isOriginalCorner = abs(abs(dv) - 0.5f) < 1e-4f;
        bool isSeam           = abs(abs(dv) - OFF)  < 1e-4f;
        assert(isOriginalCorner || isSeam,
               "every surviving vertex must be an untouched original corner "
               ~ "or a seam vert exactly on ±offset");
    }

    enum float EPS_S = 1e-4f;
    foreach (v; m.vertices) {
        float dv = dot(N, v - P);
        assert(!(dv > -OFF + EPS_S && dv < OFF - EPS_S),
               "band must be fully removed — no vertex left strictly inside the slab");
    }
}

unittest { // cutByPlaneSplitGap: CC×2 OBLIQUE sliver regression (task 0291,
    // Phase 3) — the reported bug: a single-cut + fixed along-edge slide grazes
    // existing verts on dense/curved geometry (a sliver), scattering the seam
    // off the cut plane and producing a self-intersecting cap (reference
    // capture toolcards/poly.knife/capture/subdiv_gap/: owner case, gap 0.415
    // center, TWO clean planar/simple caps). The two-cut model is
    // overshoot-immune (every seam sits on a REAL edge∩plane intersection), so
    // this is GREEN where the equivalent direct single-cut+slide call (the
    // characterization proven at Phase 0) is RED.
    //
    // PRIMARY (structural, robust to vibe3d's OSD connectivity not being
    // byte-identical to the reference's CC base — risk 5, so this does NOT
    // assert the reference's exact 40-seam/2-cap COUNTS): separated==true;
    // exactly 2 cap faces; each cap planarityDev≈0 AND selfX==0 (simple); the
    // band component is gone (componentCount==2).
    //
    // SECONDARY (with an eps margin so seam/graze verts sitting exactly on
    // ±offset don't trip it): no vertex remains strictly INSIDE the removed
    // slab.
    Mesh m = subdivideCube(2);
    m.resetSelection();

    Vec3 P = Vec3(0.0f, 0.4f, 0.61f);
    Vec3 N = normalize(Vec3(0.0f, -0.85142f, 0.52448f));
    enum float G   = 0.415f;
    enum float OFF = G * 0.5f;   // 0.2075

    bool separated;
    size_t n = m.cutByPlaneSplitGap(P, N, /*clipped*/false, P, P,
                                    /*caps*/true, G, /*gapSide*/0, separated);
    assert(n > 0, "the oblique plane must cut faces");
    assert(separated, "a full-span oblique cut must fully separate the mesh");
    assert(sliceCapComponentCount(m) == 2, "band removed: exactly 2 shells left");

    auto caps = sliceCapFaces(m, P, N, OFF, OFF, 1e-3f);
    assert(caps.length == 2, "exactly 2 cap faces (one per shell)");
    foreach (fi; caps) {
        assert(sliceCapPlanarityDev(m, fi) < 1e-3f,
               "two-cut cap must be planar (every corner is a real edge∩plane point)");
        assert(sliceCapSelfX(m, fi) == 0,
               "two-cut cap must be simple (no self-intersections) — the bug this fixes");
    }

    enum float EPS_S = 1e-4f;
    foreach (v; m.vertices) {
        float dv = dot(N, v - P);
        assert(!(dv > -OFF + EPS_S && dv < OFF - EPS_S),
               "band must be fully removed — no vertex left strictly inside the slab");
    }
}
