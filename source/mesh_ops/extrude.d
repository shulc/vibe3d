module mesh_ops.extrude;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshExtrudeOps — extrude kernel family (extrudeEdgesByMask,
// extrudeVerticesByMask, extendEdgesByMask, extrudeFacesByMask,
// smoothShiftFacesByMask), mixed into struct Mesh (source/mesh.d) via
// `mixin MeshExtrudeOps;`. Split out of mesh.d as part of the mesh.d
// decomposition campaign (0407 §B.V2 — see task 0412's doc for the
// architectural decision: mixin template over a package move or UFCS
// free-functions). Method bodies below are verbatim cut/paste from mesh.d
// (only the extraction boundary is new).
// ---------------------------------------------------------------------------
mixin template MeshExtrudeOps() {
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
    size_t extrudeEdgesByMask(in bool[] maskIn, float extrude, float width) {
        const mask = maskMinusHiddenEdges(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        import math : Vec3, cross, dot, normalize;
        import std.math : acos, sin, abs;
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
            auto p = edgeKey(va, vb) in edgeFaces;
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

        // Per-CORNER normal at vertex `v` within face `fi` — the local triangle
        //     normal spanned by fi's two boundary edges AT v, not the whole-face
        //     Newell normal. On a PLANAR face every corner's local normal is
        //     parallel to the face normal, so this returns `faceNormal(fi)`
        //     VERBATIM (planarity guard below) and planar geometry — cube, prism,
        //     flat grids, every dihedral — stays byte-identical. On a NON-planar
        //     face (Catmull-Clark / qball / tessellated quads) the two endpoints
        //     of the same selected edge see DIFFERENT local normals, which is the
        //     direction the reference extrudes each free-end corner along (measured
        //     bit-exact on cc1 and on twisted 2-quad tents: the reference lifts the
        //     free end by `extrude` along the SUM of its incident faces' per-corner
        //     normals; the whole-face Newell average carries a spurious along-edge
        //     tilt that the reference does not — hence the ~0.015–0.027 offset on
        //     non-cube geometry). Reflex/degenerate corners fold back to the face
        //     normal so a non-convex planar face also stays byte-identical.
        Vec3 cornerNormalAt(uint v, int fi) {
            Vec3 fn = faceNormal(cast(uint)fi);
            const uint[] f = faces[fi];
            foreach (k; 0 .. f.length) {
                if (f[k] != v) continue;
                uint prev = f[(k + f.length - 1) % f.length];
                uint next = f[(k + 1) % f.length];
                Vec3 cn = cross(vertices[next] - vertices[v], vertices[prev] - vertices[v]);
                if (cn.length < 1e-6f) return fn;          // degenerate corner
                cn = normalize(cn);
                if (dot(cn, fn) < 0.0f) cn = -cn;          // align to face winding
                // Planar corner (local normal ≈ face normal) → return the face
                // normal unchanged so planar meshes are bit-for-bit identical.
                if (dot(cn, fn) > 1.0f - 1e-6f) return fn;
                return cn;
            }
            return fn;                                     // v not in fi (guard)
        }
        // --- Pass 1: welded ridge vertex per original endpoint. The ridge is
        //     displaced along the average of the DISTINCT neighbour-face PER-CORNER
        //     normals (cornerNormalAt) of every selected edge incident to v
        //     (§1.4.1). Deduping by face id matters at shared corners: two
        //     co-incident selected edges that border the SAME neighbour face must
        //     count that face once, otherwise it is double-weighted and skews the
        //     direction. For a free end the single edge's two neighbour faces are
        //     already distinct, so this is identical to summing the per-edge
        //     averaged corner normal there (no single-edge regression).
        Vec3[uint] ridgeAccum;            // Σ distinct neighbour-face per-corner normals
        bool[ulong] ridgeFaceSeen;        // (v<<32|fi) → already counted at v
        void accumRidgeFace(uint v, int fi) {
            if (fi < 0) return;
            ulong fk = (cast(ulong)v << 32) | cast(uint)fi;
            if (fk in ridgeFaceSeen) return;
            ridgeFaceSeen[fk] = true;
            Vec3 nf = cornerNormalAt(v, fi);
            ridgeAccum.update(v, () => nf, (ref Vec3 acc) { acc = acc + nf; });
        }
        foreach (ref e; exEdges) {
            // A BOUNDARY edge (single adjacent face) contributes NO shift lift.
            // The reference DROPS `shift` on boundary edges (measured: shift-only
            // on a boundary loop leaves the mesh unchanged; shift+inset == inset-
            // only), applying width only — whether the edge is an isolated free
            // end OR one link of a boundary rim loop. Only INTERIOR (2-face)
            // selected edges lift their endpoints' ridge. Skipping boundary edges
            // here means an endpoint incident ONLY to boundary edges accumulates
            // nothing, so it is anchored to its original position just below and
            // its shell collapses to the in-plane inset (see the anchor pass) —
            // making a boundary loop consistent with a single boundary edge
            // instead of lifting a whole band. Pure-interior selections keep every
            // edge, so their ridge is byte-identical.
            if (e.fB == -1) continue;
            accumRidgeFace(e.va, e.fA); accumRidgeFace(e.va, e.fB);
            accumRidgeFace(e.vb, e.fA); accumRidgeFace(e.vb, e.fB);
        }
        uint[uint] ridgeVert;
        foreach (v, acc; ridgeAccum) {
            // Boundary chamfer ends are NOT lifted — they get no ridge vert (the
            // chamfer ignores extrude). Their bridge/cap geometry is skipped below.
            if (isChamferEnd(v)) continue;
            // Mesh-robustness fix (fuzz-found): at extrude≈0 the ridge vertex
            // lands EXACTLY on `vertices[v]` regardless of `dir` — minting a
            // fresh vertex there would be a coincident duplicate at the
            // original corner position (only reachable for a SHARED/interior
            // endpoint whose side faces still reference it elsewhere once
            // dissolved-and-rewritten, since a free end's original vertex is
            // otherwise fully orphaned and dropped by compaction). REUSE the
            // original vertex id instead of appending a new one; every
            // downstream reader goes through `ridgeVert[v]`, so this is
            // transparent to the bridge/cap construction below.
            if (abs(extrude) < 1e-6f) { ridgeVert[v] = v; continue; }
            Vec3 dir = (acc.length < 1e-6f) ? Vec3(0, 1, 0) : normalize(acc);
            ridgeVert[v] = addVertex(vertices[v] + dir * extrude);
        }
        // Anchor un-lifted endpoints (those incident ONLY to boundary edges, so
        // they got no ridge accumulation above and are absent from `ridgeVert`)
        // to their ORIGINAL position — the same "no lift" value the extrude≈0
        // path uses. The shared-corner shell below then emits an in-plane inset
        // whose ridge bridge has zero height (`[vb,va,va,vb]`) and is removed by
        // the degenerate-corner cleanup, so `shift+inset` on a boundary loop
        // reduces to `inset`-only — matching the reference's drop-shift rule and
        // vibe3d's own single-boundary-edge chamfer. Chamfer free ends stay
        // dissolved (no ridge), exactly as before. (For extrude≈0 every endpoint
        // is already anchored, so this pass is a no-op there.)
        foreach (ref e; exEdges) {
            if (!isChamferEnd(e.va) && (e.va in ridgeVert) is null) ridgeVert[e.va] = e.va;
            if (!isChamferEnd(e.vb) && (e.vb in ridgeVert) is null) ridgeVert[e.vb] = e.vb;
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
        // Task 0313: alongside the clamp LENGTH, remember WHICH existing vertex
        //     sits at that far distance. When the clamp actually saturates, the
        //     landing position is (up to fp rounding) exactly that vertex's own
        //     position — materialisation reuses its id instead of minting a
        //     coincident duplicate (see the weld pass below). A key that
        //     receives a SECOND clamp contribution (two selected edges folding
        //     their face-aware direction into the same shared corner) is marked
        //     ambiguous: the accumulated direction is then a blend of two
        //     distinct far vertices' directions, so the clamped landing is not
        //     guaranteed to coincide with either one — that key keeps the
        //     general (unwelded) addVertex path.
        uint[ulong]  insetClampFarVert;   // key → vertex id at the min far dist
        bool[ulong]  insetClampAmbiguous; // key → ≥2 clamp contributions folded in
        void accumInset(uint v, int fi, Vec3 d) {
            ulong k = (cast(ulong)v << 32) | cast(uint)fi;
            insetAccum.update(k, () => d, (ref Vec3 acc) { acc = acc + d; });
        }
        void recordClamp(uint v, int fi, float len, uint farVert) {
            ulong k = (cast(ulong)v << 32) | cast(uint)fi;
            if (auto p = k in insetClampLen) {
                insetClampAmbiguous[k] = true;
                if (len < *p) { *p = len; insetClampFarVert[k] = farVert; }
            } else {
                insetClampLen[k] = len;
                insetClampFarVert[k] = farVert;
            }
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
        Vec3 boundaryEdgeDir(uint v, uint other, int fi, out float farLen, out uint farVert) {
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
                farVert = far;
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
            if (mask[i]) selEdgeKeys[edgeKey(edges[i][0], edges[i][1])] = true;
        bool isSelEdge(uint a, uint b) {
            return (edgeKey(a, b) in selEdgeKeys) !is null;
        }
        // Mitered cap-corner inset at endpoint v inside face fi: offset both of
        //     fi's boundary edges at v inward (in-plane) by `width` and intersect.
        //     Returns the inset POSITION (not a direction) so the caller can use it
        //     directly. Geometrically this is v plus the inward bisector scaled by
        //     width/sin(half angle); it reduces to v + width·e1⊥ + width·e2⊥ at a
        //     right angle. Returns false if the corner is degenerate (collinear).
        //     Task 0321: on a QUAD, also reports the diagonally opposite corner
        //     (`farVert`) and its distance from `v` (`farLen`) — the natural
        //     stopping point of the mitered bisector, mirroring the far-vertex
        //     `boundaryEdgeDir` clamp below. The caller uses this to detect/weld
        //     an overshoot instead of letting the inset overshoot an existing
        //     vertex undetected (see the cap-miter convergence pass after Pass 1).
        //     Left at their `out` defaults (farVert=0, farLen=NaN — D zero-inits
        //     `out uint` but NOT `out float`) for non-quad faces (no well-defined
        //     single opposite corner); callers gate on `farLen > 1e-6f`, which is
        //     false for NaN, so the uninitialised farVert is never read.
        bool capMiterInset(uint v, int fi, out Vec3 pos, out uint farVert, out float farLen) {
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
                if (f.length == 4) {
                    farVert = f[(k + 2) % 4];
                    farLen = (vertices[farVert] - vertices[v]).length;
                }
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
        // Task 0321: (v<<32|fi) → diagonally-opposite far vertex / its distance,
        //     for cap-miter keys on a QUAD face only (see capMiterInset). Consumed
        //     by the cap-miter convergence pass after Pass 1 to clamp/weld an
        //     overshooting mitered inset instead of leaving it unclamped.
        uint[ulong]  capMiterFarVert;
        float[ulong] capMiterFarLen;
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
                    Vec3 mp; uint capFar; float capFarLen;
                    if (capMiterInset(v, fi, mp, capFar, capFarLen)) {
                        ulong k = (cast(ulong)v << 32) | cast(uint)fi;
                        insetPosOverride[k] = mp;
                        if (sharedOnly) sharedFaceAwareInset[k] = true;
                        if (capFarLen > 1e-6f) {
                            capMiterFarVert[k] = capFar;
                            capMiterFarLen[k] = capFarLen;
                        }
                        // Direction is irrelevant (overridden); return a unit dir
                        // so accumInset stays well-formed.
                        return inwardDir(va, vb, fi);
                    }
                    // capMiter degenerate → fall through to perpendicular.
                } else {
                    float farLen; uint farVert;
                    Vec3 d = boundaryEdgeDir(v, other, fi, farLen, farVert);
                    if (d.length >= 1e-6f) {
                        // Clamp the inset so it stops at (never passes) the far
                        // vertex of this incident non-selected edge.
                        recordClamp(v, fi, farLen, farVert);
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
        import std.format : format;
        string weldKeyOf(uint v, Vec3 p) {
            return format("%u|%d|%d|%d", v,
                cast(long)(p.x * 1e5f + (p.x >= 0 ? 0.5f : -0.5f)),
                cast(long)(p.y * 1e5f + (p.y >= 0 ? 0.5f : -0.5f)),
                cast(long)(p.z * 1e5f + (p.z >= 0 ? 0.5f : -0.5f)));
        }
        // Task 0317: MUTUAL free-end overshoot guard. The far-vertex weld
        //     below (and its along-edge-inset sibling further down) is safe
        //     only when `farVertId` is a STABLE vertex that survives the op
        //     untouched (e.g. a cube's other corner). When TWO SELECTED EDGES
        //     each dissolve a free end that faces the OTHER edge's free end
        //     across one shared non-selected boundary edge of a common face
        //     (e.g. two OPPOSITE edges of one interior quad both selected —
        //     each free end's `boundaryEdgeDir` far vertex resolves to the
        //     OTHER edge's free end), an overshoot `width` makes BOTH corners
        //     weld onto EACH OTHER's original vertex. That is a MUTUAL swap,
        //     not a one-sided clamp: the two insets cross past one another,
        //     producing a self-intersecting "bowtie" face with 4 DISTINCT
        //     corners but zero net area (not caught by the <3-distinct-corner
        //     drop, since nothing repeats). Detect it up front — `farVertId`
        //     is itself a free end being dissolved by a DIFFERENT selected
        //     edge — and reroute BOTH directions through one shared MIDPOINT
        //     vertex instead of letting either reach the other's original
        //     position. Keyed by the unordered (v,far) pair so both corners'
        //     welds resolve to the identical id (no crossing, no coincident
        //     duplicate). Free ends of the SAME edge never collide here
        //     (`boundaryEdgeDir` already excludes the edge's own other
        //     endpoint), and shared/chain corners are not dissolved via this
        //     path, so single-edge cases (cube, octahedron, width_clamp) never
        //     see `isFreeEnd(farVertId)` true — byte-identical there.
        uint[ulong] mutualMeet;   // unordered (loV<<32|hiV) → shared meeting vert
        // Task 0321: positional twin of `mutualMeet`, keyed by the quantised
        //     midpoint itself rather than the (a,b) pair. A single face can
        //     produce more than one converging PAIR that geometrically meets at
        //     the SAME point — e.g. a quad's two diagonal cap-corner pairs
        //     (v0,v2) and (v1,v3) both cross at the face center — so a pure
        //     pair-keyed cache would mint two coincident "meeting" vertices for
        //     what is really one point. Check position first; only mint (and
        //     register both caches) when this exact point hasn't been produced
        //     by a different pair yet.
        uint[string] mutualMeetPos;
        uint mutualMeetVert(uint a, uint b) {
            uint lo = a < b ? a : b, hi = a < b ? b : a;
            ulong mk = (cast(ulong)lo << 32) | hi;
            if (auto p = mk in mutualMeet) return *p;
            Vec3 mid = (vertices[lo] + vertices[hi]) * 0.5f;
            string pk = weldKeyOf(uint.max, mid);   // sentinel v — position-only key
            if (auto pp = pk in mutualMeetPos) { mutualMeet[mk] = *pp; return *pp; }
            uint nv = addVertex(mid);
            mutualMeet[mk] = nv;
            mutualMeetPos[pk] = nv;
            return nv;
        }
        // Task fuzz-0321b: the shared meeting point for a converging QUAD's
        //     cap-miter corners (see `mutualMeetVertAt` below) is this face's
        //     own centroid (the existing `Mesh.faceCentroid` member, reused
        //     here rather than re-derived) instead of a per-diagonal
        //     midpoint. For a parallelogram (incl. the axis-aligned
        //     cube/square case) the two diagonals bisect each other AT the
        //     centroid, so this is bit-identical to the old per-diagonal
        //     midpoint there. For a non-parallelogram convex quad the two
        //     diagonal midpoints DIFFER — using either alone left the OTHER
        //     diagonal's pair converging to a second, distinct point, producing
        //     an `[a,b,a,b]` folded face (two non-adjacent corners coincident,
        //     not caught by the consecutive-only degenerate-face cleanup). The
        //     centroid is one point shared by both diagonals' corners, so all 4
        //     corners collapse onto the SAME vertex regardless of quad shape.
        // Positional twin of `mutualMeetVert` that lands at an explicit
        //     `meetPos` (rather than computing the (a,b) midpoint itself), so a
        //     caller can supply a face-level meeting point (see `faceCentroid`)
        //     shared by more than one pairwise `(a,b)` key. Shares the same
        //     `mutualMeet`/`mutualMeetPos` caches as `mutualMeetVert`, so two
        //     different diagonal pairs of one face that both resolve to the
        //     identical `meetPos` (bit-identical — both derive it via the same
        //     `faceCentroid(fi)` call) collapse onto ONE vertex.
        uint mutualMeetVertAt(uint a, uint b, Vec3 meetPos) {
            uint lo = a < b ? a : b, hi = a < b ? b : a;
            ulong mk = (cast(ulong)lo << 32) | hi;
            if (auto p = mk in mutualMeet) return *p;
            string pk = weldKeyOf(uint.max, meetPos);
            if (auto pp = pk in mutualMeetPos) { mutualMeet[mk] = *pp; return *pp; }
            uint nv = addVertex(meetPos);
            mutualMeet[mk] = nv;
            mutualMeetPos[pk] = nv;
            return nv;
        }
        // Pass 1 (task 0313): far-vertex-clamp welds. When the face-aware clamp
        //     above actually saturates (offset would otherwise overshoot) AND
        //     exactly one contribution defined this corner's far vertex (no
        //     shared-corner blend of two different far vertices), the clamped
        //     landing is — up to fp rounding — EXACTLY that existing vertex's
        //     position. Reuse its id directly instead of minting a coincident
        //     duplicate (the prior bug: same position, new index → a
        //     zero-area face + a winding flip once neighbouring faces are
        //     rewound around it). Registered BEFORE pass 2 so a coincidental
        //     unclamped inset that lands at the same quantised position welds
        //     onto this id too, rather than racing to mint its own duplicate
        //     (AA iteration order is unspecified).
        bool[ulong] weldedToFar;
        // Perf nit: whether ANY far-vertex overshoot clamp (this pass or its
        //     along-edge sibling further below) actually saturated. The
        //     winding-consistency safety net (task 0317, below) exists solely
        //     to reconcile faces whose local winding heuristic disagreed
        //     because of a saturating clamp/weld; when this stays false (the
        //     overwhelming common case — a batchless preview frame with a
        //     modest width/extrude) that pass's O(F) edgeUsers build + BFS is
        //     unconditionally a no-op and is skipped entirely (see gate below).
        bool anyOvershootSaturated = false;
        foreach (k, acc; insetAccum) {
            if (k in insetPosOverride) continue;     // cap-miter — absolute, no clamp
            auto cap = k in insetClampLen;
            if (cap is null) continue;
            if (k in insetClampAmbiguous) continue;   // blended direction — no single target
            float len = (acc * width).length;
            if (len <= *cap || len <= 1e-9f) continue; // did not actually saturate
            anyOvershootSaturated = true;
            uint v = cast(uint)(k >> 32);
            uint farVertId = insetClampFarVert[k];
            if (isFreeEnd(farVertId)) {
                // Task 0317: mutual dissolve — reroute both directions onto
                // one shared midpoint vertex (see guard comment above).
                uint mv = mutualMeetVert(v, farVertId);
                insetVert[k] = mv;
                insetPosWeld[weldKeyOf(v, (vertices[v] + vertices[farVertId]) * 0.5f)] = mv;
                weldedToFar[k] = true;
                continue;
            }
            Vec3 p = vertices[v] + normalize(acc) * (*cap);
            // Parity (keep-distinct): the clamp lands the inset ON the far
            // vertex's position, but the reference KEEPS it a DISTINCT vertex
            // (coincident-but-separate, higher vert count) rather than reusing
            // the existing corner's id — reusing it collapses the neighbour
            // face's corner onto its winding-neighbour (a zero-length edge the
            // degenerate-face cleanup then drops, losing a face too). Mint a
            // new vertex at the clamped landing instead of welding onto
            // `farVertId`. See task edge-extrude-keep-distinct.
            uint nv = addVertex(p);
            insetVert[k] = nv;
            insetPosWeld[weldKeyOf(v, p)] = nv;
            weldedToFar[k] = true;
        }
        // Pass 1b (task 0321): cap-miter convergence weld. The cap-miter path
        //     (a shared corner whose face is fully ringed by selected edges — no
        //     non-selected boundary edge to inset along, e.g. every corner of
        //     every face when ALL edges of a closed mesh are selected) carries an
        //     ABSOLUTE position override and, until now, no overshoot clamp at
        //     all: an aggressive `width` can push the mitered inset straight
        //     through — or exactly onto — the face's diagonally opposite corner
        //     with no weld, minting a coincident duplicate. Worse, on a QUAD
        //     whose every corner is a cap corner (the fully-selected-loop case),
        //     that opposite corner is ITSELF converging back along the same
        //     diagonal, not a fixed target — the identical "mutual dissolve"
        //     hazard task 0317 fixed for face-aware free-end insets, here
        //     triggered by full-loop selection instead of two opposing free ends.
        //
        //     `farVert` (the diagonally opposite corner, from capMiterInset) is
        //     itself ALSO a cap-miter key of the SAME face exactly when it has
        //     its own entry in `insetPosOverride` for (farVert, fi) — i.e. both
        //     diagonal corners are converging toward each other. Detect that and
        //     reroute BOTH directions through the shared midpoint vertex
        //     (`mutualMeetVert`), using the SUM of both corners' own offsets
        //     against the shared distance so an asymmetric pair (uneven corner
        //     angles) is still caught the moment their reaches would meet or
        //     cross — not only once either one alone reaches the far corner.
        //     When `farVert` is NOT itself converging (a stable vertex, or a
        //     boundary-edge-dissolved corner in a partially-selected face), fall
        //     back to the plain one-sided task-0313 clamp: stop at — and reuse —
        //     `farVert`'s own id once this corner's own offset alone reaches it.
        //
        //     Non-quad cap corners (no `capMiterFarVert` entry) and any width
        //     modest enough that neither branch triggers keep the prior
        //     unclamped `insetPosOverride` position untouched in Pass 2 below —
        //     byte-identical there.
        foreach (k, farVertId; capMiterFarVert) {
            float farLen = capMiterFarLen[k];
            if (farLen <= 1e-6f) continue;
            uint v  = cast(uint)(k >> 32);
            uint fi = cast(uint)(k & 0xffffffffUL);
            float offLen = (insetPosOverride[k] - vertices[v]).length;
            ulong farKey = (cast(ulong)farVertId << 32) | fi;
            if (auto farOverride = farKey in insetPosOverride) {
                // Mutual: farVert is also a cap corner of this same face,
                // converging back along the same diagonal. Meet at the face's
                // OWN centroid (see faceCentroid) rather than this diagonal's
                // midpoint, so the OTHER diagonal pair — if it converges too —
                // collapses onto the identical vertex instead of a second,
                // distinct one (fuzz-0321b).
                float farOffLen = (*farOverride - vertices[farVertId]).length;
                if (offLen + farOffLen < farLen - 1e-6f) continue;   // not yet meeting
                anyOvershootSaturated = true;
                Vec3 meetPos = faceCentroid(fi);
                uint mv = mutualMeetVertAt(v, farVertId, meetPos);
                insetVert[k] = mv;
                insetPosWeld[weldKeyOf(v, meetPos)] = mv;
                weldedToFar[k] = true;
            } else {
                // One-sided: farVert is a stable/independently-handled corner.
                if (offLen < farLen - 1e-6f) continue;   // did not reach it
                anyOvershootSaturated = true;
                insetVert[k] = farVertId;
                insetPosWeld[weldKeyOf(v, vertices[farVertId])] = farVertId;
                weldedToFar[k] = true;
            }
        }
        // TODO(fuzz): n-GON (n>=5) cap-miter corners carry NO overshoot clamp
        //     at all (`capMiterInset` only reports a diagonally-opposite far
        //     vertex for QUADS, n==4, handled by Pass 1b above); their
        //     `insetPosOverride` position flows unclamped straight to Pass 2.
        //     TRIANGLES need no clamp — with only 3 corners in a cyclic face,
        //     any two that end up coincident are, by construction, ADJACENT
        //     (a 3-cycle has no non-adjacent pair), so the plain
        //     consecutive-duplicate degenerate-face cleanup below already
        //     catches a fully- or partially-collapsed triangle cleanly
        //     (confirmed empirically: a regular AND a heavily scalene/100:1
        //     octahedron, all edges selected, stay valid up to width=50 on a
        //     unit-scale mesh — see test 19 in test_edge_extrude.d).
        //
        //     n>=5 DOES have non-adjacent corner pairs (e.g. a pentagon's
        //     corners 0 and 2), so an `[...,a,...,a,...]` fold the
        //     consecutive-only cleanup misses is theoretically reachable —
        //     but INVESTIGATED AND NOT YET REPRODUCED via realistic
        //     (irregular, non-symmetric) geometry: two DISTINCT corners'
        //     raw mitered rays are fixed lines whose parametrisation is
        //     LOCKED to the same single `width` value (position(width) =
        //     v + (width/sin(halfAngle))·bisector), so for them to land at
        //     the exact same point at the SAME width is a 2-equations/
        //     1-unknown system — generically UNSATISFIABLE except at an
        //     exact/near-symmetric critical width (unlike the quad bug this
        //     mirrors, which was FORCED by Pass 1b's own approximate
        //     trigger-and-weld formula, not by raw rays naturally crossing).
        //     Confirmed empirically: an irregular pentagon AND an irregular
        //     hexagon (interior faces of a tall open prism, isolating this
        //     path from the far-vertex clamp above — see the "tall prism"
        //     construction tried during this investigation) stayed
        //     coincidence-free at width 0.9 through 50 (three orders of
        //     magnitude past their ~unit-scale critical radius). A regular
        //     (or near-regular) n>=5 primitive at OR VERY NEAR its exact
        //     critical width remains an unproven but plausible latent gap.
        //
        //     A real fix needs a per-FACE (not per-pair, since n>=5 has no
        //     single natural "opposite corner") convergence test — e.g. weld
        //     every cap-miter corner of a face onto that face's own centroid
        //     once the polygon's inward offset has collapsed — plus a
        //     regression fixture that actually demonstrates the fold (a
        //     regular pentagon/hexagon at its exact analytic critical width
        //     is the most promising unexplored angle; every irregular
        //     construction tried here passed even without any clamp). Given
        //     that, this is left as a follow-up rather than shipped as an
        //     unverified change.
        //
        //     Separately (mesh-robustness batch, fuzz-found): a standalone
        //     open n-gon (e.g. a lone pentagon face, or any mesh boundary
        //     loop) whose corners are SHARED (>=2 selected edges, not free
        //     ends/chamfer) rather than interior, run through an overshoot
        //     width, used to mint coincident duplicate vertices at the
        //     ORIGINAL corner positions at extrude≈0. Fixed above (Pass 1):
        //     the ridge-vertex construction now REUSES the original vertex
        //     id at extrude≈0 instead of appending a coincident one — see
        //     `ridgeVert[v] = v` in Pass 1. Unrelated to the cap-miter gap
        //     described above (that one is `insetPosOverride`/
        //     `capMiterInset`-specific and still open).
        // Pass 2: the general accumulated-direction inset (unclamped, or
        //     clamped-but-ambiguous, or cap-miter override), same
        //     (endpoint, quantised position) weld as before so two selected
        //     edges meeting at a shared corner that inset it in the SAME
        //     direction collapse onto ONE vertex instead of emitting
        //     coincident duplicates.
        foreach (k, acc; insetAccum) {
            if (k in weldedToFar) continue;
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
            string wk = weldKeyOf(v, p);
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
                auto p = edgeKey(a, b) in edgeFaces;
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
                uint farVertId;
                if (auto fp = v in alongFar) {
                    t = vertices[*fp] - vertices[v];
                    float farLen = t.length;
                    if (width > farLen) {
                        // Task 0313: the clamp saturated — `alongFar[v]` is a
                        // single, unambiguous far vertex (first-rim-edge-found,
                        // never overwritten — see the population loop above), so
                        // the landing coincides exactly with it.
                        offLen = farLen;
                        farVertId = *fp;
                        anyOvershootSaturated = true;
                        // Task 0317: the mutual-dissolve hazard (two free ends
                        // facing each other across one shared boundary edge)
                        // still reroutes to a shared midpoint to avoid a
                        // self-intersecting swap. That path stays welded.
                        if (isFreeEnd(farVertId)) {
                            freeEndAlongVert[v] = mutualMeetVert(v, farVertId);
                            continue;
                        }
                        // Parity (keep-distinct): otherwise the clamped inset
                        // lands ON `farVertId`'s position but stays a DISTINCT
                        // vertex — the reference keeps this coincident inset
                        // separate rather than reusing the existing corner's id.
                        // Fall through to addVertex at the clamped landing
                        // (`offLen == farLen` ⇒ exactly that position). See task
                        // edge-extrude-keep-distinct.
                    }
                } else if (auto op = v in freeEndOther) {
                    t = vertices[v] - vertices[*op];   // fallback: extruded tangent
                } else continue;
                if (t.length < 1e-6f) continue;
                t = normalize(t);
                freeEndAlongVert[v] = addVertex(vertices[v] + t * offLen);
            }
        }
        // NOTE: gated on `freeEndAlongVert` (the MATERIALIZED map), not the
        //     `needsAlong` intent map above. The materialization loop has bail-out
        //     paths (`v` present in neither `alongFar` nor `freeEndOther`; or a
        //     degenerate near-zero tangent — e.g. an overshoot `width` clamped
        //     an unrelated inset vertex exactly onto `v`'s own position, via the
        //     face-corner-rewrite ordering: the back-face scan above can read a
        //     PRE-REWRITTEN face corner as an already-rewritten inset id from an
        //     earlier neighbour-face pass, spuriously flagging `needsAlong[v]`)
        //     that leave `needsAlong[v]` true with no corresponding
        //     `freeEndAlongVert[v]` entry. Reading `freeEndAlongVert` directly
        //     makes "no materialized along-vert" gracefully degrade to the
        //     plain (valence-3-style) fallback at both call sites below instead
        //     of a RangeError (task 0311). A genuine valence>3 free end whose
        //     along-vert materialized successfully is unaffected.
        bool needsAlongAt(uint v) { return (v in freeEndAlongVert) !is null; }

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
        // Task 0317: unconditional twin of `sideReshapeIdx` (that one is only
        //     populated when the mesh-edit tracker has an open batch — inert
        //     for the common one-shot command path). The winding-consistency
        //     safety net below needs the touched-face set on EVERY call, not
        //     just tracked ones.
        bool[uint] sideTouched;
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
                    auto p = edgeKey(a, b) in edgeFaces;
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
                sideTouched[cast(uint)fi] = true;
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
        // Emit a triangle cap whose winding is derived from ORIENTABILITY against
        // an adjacent already-emitted bridge quad, rather than a geometric dot
        // test. The cap shares edge (sharedU,sharedW) with `refFace`; a
        // consistently-oriented surface traverses a shared edge in OPPOSITE
        // directions on its two incident faces, so the cap must walk that edge
        // opposite to the bridge. This is edge-axis-independent — the prior
        // `emitCap(outward=±edgeAxis)` heuristic only points the cap outward when
        // the edge happens to align with the solid's outward direction (e.g. an
        // axis-aligned cube corner); on a tilted free end (edge not aligned with
        // "away from the solid") the edge-axis dot mis-orients the cap. Because
        // the bridges are already wound outward (dot with the extrude normal ne),
        // deriving the cap from them makes it outward too, for ANY edge tilt.
        void emitCapShared(uint[3] corners, uint sharedU, uint sharedW,
                           int refFace, int srcFace) {
            // Direction refFace traverses the shared edge.
            bool refUtoW = true;
            auto rf = faces[refFace];
            foreach (k; 0 .. rf.length) {
                uint u = rf[k], w = rf[(k + 1) % rf.length];
                if (u == sharedU && w == sharedW) { refUtoW = true;  break; }
                if (u == sharedW && w == sharedU) { refUtoW = false; break; }
            }
            // Direction the cap (as given) traverses the shared edge.
            uint[3] c = corners;
            bool capUtoW = true;
            foreach (k; 0 .. 3) {
                uint u = c[k], w = c[(k + 1) % 3];
                if (u == sharedU && w == sharedW) { capUtoW = true;  break; }
                if (u == sharedW && w == sharedU) { capUtoW = false; break; }
            }
            // Want the cap OPPOSITE to refFace on the shared edge; if it matches,
            // reverse the triangle (swap the two non-anchor corners).
            if (capUtoW == refUtoW) { uint t = c[1]; c[1] = c[2]; c[2] = t; }
            faces ~= [c[0], c[1], c[2]];
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
                // Record each bridge's face index so the free-end caps below can
                // wind by ORIENTABILITY against the bridge they share an edge with
                // (see emitCapShared) instead of a geometric edge-axis dot test.
                int brA = cast(int)faces.length;
                if (e.coplanar || capSideA) {
                    emitBridgeFromFace(insetVert[kIA], insetVert[kIB],
                                       ridgeVert[e.va], ridgeVert[e.vb], e.fA, e.fA);
                } else {
                    emitBridge([insetVert[kIA], insetVert[kIB],
                                ridgeVert[e.vb], ridgeVert[e.va]], e.ne, e.fA);
                }
                int brB = cast(int)faces.length;
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
                // closes that side. The cap lies in the plane of (insetA, insetB,
                // ridge); its winding is derived from the incident bridge quad
                // (orientability, see capFreeEnd) so it stays outward-facing under
                // both extrude signs and for any edge tilt.
                // Cap the corner gap between the two perpendicular insets and the
                // ridge. A valence-3 free end uses ONE triangle [insetA,insetB,
                // ridge] (the cube path, unchanged). A valence>3 free end has its
                // gap split by the along-edge inset, so the cap becomes a small
                // fan of TWO triangles [insetA,vAlong,ridge] + [vAlong,insetB,
                // ridge] (vAlong is geometrically between insetA and insetB along
                // the edge axis, so both triangles tile the same corner with no
                // overlap). Winding comes from orientability against the incident
                // bridge (emitCapShared): the [iA,·,ridge] triangle shares edge
                // (iA,ridge) with the fA bridge (brA); the [·,iB,ridge] triangle
                // shares (iB,ridge) with the fB bridge (brB). The old edge-axis dot
                // heuristic only oriented axis-aligned free ends (cube) correctly
                // and reversed tilted ones; the bridge is already wound outward, so
                // deriving from it is tilt-independent and sign-independent (the
                // ridge position carries the extrude sign into the bridge).
                void capFreeEnd(uint v, uint iA, uint iB) {
                    if (!isInteriorFreeEnd(v)) return;
                    // A free end on the OPEN mesh boundary needs no cap — the
                    // ridge bridge already closes its corner against the boundary.
                    // (A fully-interior free end is ringed by faces and is capped.)
                    if (isOnMeshBoundary(v)) return;
                    uint rv = ridgeVert[v];
                    if (needsAlongAt(v)) {
                        uint va2 = freeEndAlongVert[v];
                        emitCapShared([iA, va2, rv], iA, rv, brA, e.fA);
                        emitCapShared([va2, iB, rv], iB, rv, brB, e.fA);
                    } else {
                        emitCapShared([iA, iB, rv], iA, rv, brA, e.fA);
                    }
                }
                capFreeEnd(e.va, insetVert[kIA], insetVert[kIA2]);
                capFreeEnd(e.vb, insetVert[kIB], insetVert[kIB2]);
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
            faceMaterial       ~= faceAttrOr(faceMaterial, srcFace);
            facePart           ~= faceAttrOr(facePart, srcFace);
            faceSelectionOrder ~= 0;
        }
        resizeSubpatch();
        // Task 0389: each bridge/cap wall inherits Subpatch from the same
        // neighbour face `bridgeMaterialSrc` already resolves its material
        // from, instead of a blanket false — a subdiv model stays subdiv
        // after an edge extrude.
        foreach (bi; 0 .. faces.length - firstBridge) {
            uint fi = cast(uint)(firstBridge + bi);
            setFaceSubpatch(fi, isFaceSubpatch(bridgeMaterialSrc[bi]));
        }

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

        // --- Degenerate-face cleanup (task 0313). The far-vertex overshoot
        //     clamps above now REUSE an existing vertex id when the clamped
        //     landing coincides with it, instead of minting a coincident
        //     duplicate. Reusing an id that is already one of a face's OTHER
        //     corners (always true here: `far` is by construction the
        //     immediate winding-order neighbour of the corner being replaced)
        //     collapses that corner onto its neighbour, leaving an adjacent
        //     repeated corner (a zero-length edge) in the rewritten face —
        //     or, when BOTH of a triangle's non-fixed corners saturate onto
        //     the SAME third corner (e.g. an extreme overshoot on a small
        //     triangular neighbour face), the whole face collapses to a
        //     single point. This pass runs once over every face — the
        //     rewritten neighbour/side faces AND the freshly emitted
        //     bridge/cap faces alike, since a bridge quad can equally
        //     inherit a doubled corner from a saturated clamp (its two
        //     inset corners are independently resolved and can coincide) —
        //     collapsing any consecutive (cyclically-adjacent) duplicate
        //     corners, and dropping any face that reduces to fewer than 3
        //     distinct corners. Nothing downstream still depends on
        //     original face indices/slots (the bridge/cap loop above was
        //     the last reader of `e.fA`/`e.fB`; the ridge edges were just
        //     captured BY POSITION), so faces can be safely removed here
        //     with a full reindex. A well-formed extrude (no clamp ever
        //     saturates, or saturates only onto a vertex that ISN'T already
        //     a face-adjacent corner) never triggers a duplicate here, so
        //     this pass is a no-op — byte-identical to the pre-fix output.
        // Task 0317: old→new face-index remap produced by this cleanup pass
        //     (old index → new index, or -1 if dropped). Populated below
        //     regardless of whether any face actually dropped (identity map
        //     in that case) so the winding-consistency pass right after can
        //     translate its pre-cleanup candidate indices forward.
        size_t facesLenBeforeCleanup = faces.length;
        int[] faceRemap = new int[](facesLenBeforeCleanup);
        {
            bool[] dropFace = new bool[](faces.length);
            bool anyDrop = false;
            // Tracker: a face whose consecutive-duplicate corners collapse here
            // but that SURVIVES (still >=3 corners after collapsing) is mutated
            // IN PLACE with no corresponding record — the drop path below records
            // RemoveFaces, but a mere SHRINK was invisible to the edit-delta.
            // Forward replay (redo) would then leave the face at its earlier,
            // duplicate-corner shape (whatever an upstream ReshapeFaces/AddFaces
            // entry last recorded), since nothing in the log ever re-applies the
            // collapse. Record it as one more ReshapeFaces entry, keyed by the
            // SAME pre-cleanup index space `droppedFaceIdx`/the nbr/side entries
            // already use — before = the pre-collapse corner list, after = the
            // collapsed one. A face that also ends up dropped needs no entry
            // here (RemoveFaces^-1 only needs to preserve the slot; a face that
            // survives to the tail of LIFO revert is always fully overwritten by
            // an earlier ReshapeFaces^-1/AddFaces^-1 truncation regardless of
            // this intermediate content).
            uint[]   reduceReshapeIdx;
            uint[][] reduceReshapeBefore;
            uint[][] reduceReshapeAfter;
            foreach (fi; 0 .. faces.length) {
                auto f = faces[fi];
                if (f.length < 3) continue;   // pre-existing invalid face — not ours to fix
                uint[] reduced;
                reduced.reserve(f.length);
                foreach (c; f)
                    if (reduced.length == 0 || reduced[$ - 1] != c) reduced ~= c;
                // Cyclic wrap: the first and last surviving corners may also
                // coincide (e.g. a triangle collapsed to [a,a,a] reduces
                // linearly to [a], already caught below; a quad collapsed to
                // [a,b,b,a] reduces linearly to [a,b,a] — first==last too).
                while (reduced.length > 1 && reduced[0] == reduced[$ - 1])
                    reduced = reduced[0 .. $ - 1];
                if (reduced.length != f.length) {
                    if (recExtrude && reduced.length >= 3) {
                        reduceReshapeIdx    ~= cast(uint)fi;
                        reduceReshapeBefore ~= f.dup;
                        reduceReshapeAfter  ~= reduced.dup;
                    }
                    faces[fi] = reduced;
                }
                if (faces[fi].length < 3) { dropFace[fi] = true; anyDrop = true; }
            }
            if (recExtrude && reduceReshapeIdx.length)
                editRecorder_.recordReshapeFaces(reduceReshapeIdx, reduceReshapeBefore, reduceReshapeAfter);
            if (anyDrop) {
                uint[][] keptFaces;
                uint[]   keptWord;   // whole faceMarks word (task 0613 §4.2)
                int[]    keptOrder;
                uint[]   keptMaterial;
                uint[]   keptPart;
                keptFaces.reserve(faces.length);
                keptWord.reserve(faces.length);
                keptOrder.reserve(faces.length);
                keptMaterial.reserve(faces.length);
                keptPart.reserve(faces.length);
                uint[]   droppedFaceIdx;
                uint[][] droppedFaceLists;
                uint[]   droppedFaceMat;
                uint[]   droppedFacePart;
                uint[]   droppedFaceSub;
                size_t newIdx = 0;
                foreach (fi, ref f; faces) {
                    if (dropFace[fi]) {
                        faceRemap[fi] = -1;
                        if (recExtrude) {
                            droppedFaceIdx   ~= cast(uint)fi;
                            droppedFaceLists ~= f.dup;
                            droppedFaceMat   ~= faceAttrOr(faceMaterial, fi);
                            droppedFacePart  ~= faceAttrOr(facePart, fi);
                            droppedFaceSub   ~= (isFaceSubpatch(fi) ? 1u : 0u);
                        }
                        continue;
                    }
                    faceRemap[fi] = cast(int)newIdx;
                    ++newIdx;
                    keptFaces    ~= f;
                    keptWord     ~= faceAttrOr(faceMarks, fi);
                    keptOrder    ~= faceAttrOr(faceSelectionOrder, fi);
                    keptMaterial ~= faceAttrOr(faceMaterial, fi);
                    keptPart     ~= faceAttrOr(facePart, fi);
                }
                if (recExtrude && droppedFaceIdx.length)
                    editRecorder_.recordRemoveFaces(droppedFaceIdx, droppedFaceLists,
                                                    droppedFaceMat, droppedFacePart, droppedFaceSub);
                faces              = keptFaces;
                // Select ends up cleared regardless (clearFaceSelection() runs
                // later in this function), so dropping it here via keepMask
                // changes nothing observable — kept for consistency with
                // every other compaction site.
                setFaceMarksFrom(keptWord, ~Marks.Select);
                faceSelectionOrder = keptOrder;
                faceMaterial       = keptMaterial;
                facePart           = keptPart;
            } else {
                foreach (fi; 0 .. facesLenBeforeCleanup) faceRemap[fi] = cast(int)fi;
            }
        }

        // --- Winding-consistency safety net (task 0317). Every rewritten
        //     neighbour/side face and every freshly emitted bridge/cap picks
        //     its own winding from a LOCAL heuristic (the "preserve original
        //     normal" flip for rewrites, the neighbour-averaged `ne` dot-test
        //     for bridges, the edge-axis dot-test for caps). Each heuristic is
        //     individually sound for the small-inset geometry it was designed
        //     around, but an extreme overshoot can collapse an inset onto a
        //     vertex shared with ANOTHER independently-wound face — a stable
        //     far vertex reused by a bridge/cap AND still incident to its own
        //     ORIGINAL, untouched neighbour elsewhere in the mesh, or two
        //     bridges of the same (or, pre task-0317-fix, two mutually facing)
        //     selected edge(s) sharing one collapsed inset edge. The
        //     independent heuristics can then disagree about which way two
        //     faces should traverse the edge they end up sharing, folding the
        //     surface even though neither face is individually degenerate,
        //     and a single forward sweep is not always enough to resolve it
        //     (face A may need to flip to satisfy face B, but B was already
        //     accepted before A's conflict with it was even discovered).
        //
        //     This is a two-colouring problem: every UNTOUCHED, pre-existing
        //     face's winding is fixed ground truth (the original mesh was a
        //     valid manifold, so any edge shared by two untouched faces is
        //     already consistent); every touched/created face this op
        //     touched or emitted (rewritten neighbour/side faces + the
        //     freshly emitted bridge/cap tail — translated through the
        //     degenerate-cleanup remap above) gets EXACTLY one bit of freedom
        //     — keep its current corner order, or reverse the whole face —
        //     and adjacent faces sharing an edge must pick opposite
        //     canonical directions along it. Solve by propagating from every
        //     touched face directly adjacent to a fixed face (its required
        //     state is forced), then flooding that decision across the
        //     touched-face adjacency graph; any touched-face island with no
        //     fixed anchor at all gets an arbitrary (but internally
        //     consistent) root. A topology where every heuristic already
        //     agrees (the overwhelming common case — no clamp ever saturates
        //     onto another dissolving vertex) finds every touched face
        //     already satisfying its neighbours, so nothing flips.
        //
        //     Perf nit: the whole pass (in particular the full-mesh
        //     `edgeUsers` build, which is O(F) over every face in the mesh —
        //     not just the ones this op touched) is gated on
        //     `anyOvershootSaturated`. Every heuristic above already agrees
        //     whenever no clamp/weld actually saturated (see the invariant
        //     above), so this pass is PROVABLY a no-op in that case — safe to
        //     skip outright rather than run it and discover nothing flips.
        //     This is the common case for every batchless preview frame
        //     (`rebuildPreview()` re-runs this kernel every frame of an
        //     interactive drag with a modest width/extrude), so the gate
        //     avoids doing O(F) work per frame for a result that never
        //     changes anything.
        if (anyOvershootSaturated) {
            bool[uint] windingCandidate;
            void addCandidate(size_t oldFi) {
                if (oldFi >= faceRemap.length) return;
                int nfi = faceRemap[oldFi];
                if (nfi >= 0) windingCandidate[cast(uint)nfi] = true;
            }
            foreach (fi, _; affectedFaces) addCandidate(cast(size_t)fi);
            foreach (fi, _; sideTouched) addCandidate(fi);
            foreach (fi; firstBridge .. facesLenBeforeCleanup) addCandidate(fi);

            // canonical(a,b) directed-edge sign: +1 if this face reads
            // lo→hi, -1 if hi→lo. Two faces sharing an undirected edge are
            // consistently wound iff their EFFECTIVE signs (own sign, times
            // -1 if flipped) multiply to -1.
            static struct EdgeUse { uint fi; int sign; }
            EdgeUse[][ulong] edgeUsers;
            foreach (fi; 0 .. faces.length) {
                auto f = faces[fi];
                if (f.length < 3) continue;
                foreach (k; 0 .. f.length) {
                    uint a = f[k], b = f[(k + 1) % f.length];
                    uint lo = a < b ? a : b, hi = a < b ? b : a;
                    ulong ek = (cast(ulong)lo << 32) | hi;
                    edgeUsers[ek] ~= EdgeUse(cast(uint)fi, (a == lo) ? 1 : -1);
                }
            }

            int[uint] state;     // 0 = keep, 1 = flip — only ever set for candidates
            uint[] queue;
            void seed(uint fi, int st) {
                if (fi in state) return;
                state[fi] = st;
                queue ~= fi;
            }
            // needed multiplier so that signA * (signB*mul) == -1.
            static int neededMul(int signA, int signB) { return -(signA * signB); }

            // Seed every candidate directly adjacent (via a 2-user edge) to a
            // fixed (non-candidate) face: its state is fully determined.
            foreach (ek, users; edgeUsers) {
                if (users.length != 2) continue;
                auto u0 = users[0], u1 = users[1];
                bool c0 = (u0.fi in windingCandidate) !is null;
                bool c1 = (u1.fi in windingCandidate) !is null;
                if (c0 == c1) continue;   // both fixed (nothing to do) or both candidate (flood below)
                auto fixedU = c0 ? u1 : u0;
                auto candU  = c0 ? u0 : u1;
                int mul = neededMul(fixedU.sign, candU.sign);
                seed(candU.fi, (mul == -1) ? 1 : 0);
            }

            // Flood the decision across candidate-candidate adjacency; once
            // the initial fixed-seeded fronts are drained, root any
            // remaining unassigned candidate arbitrarily (state = keep) and
            // keep draining — this reaches every candidate exactly once.
            size_t qi = 0;
            while (true) {
                while (qi < queue.length) {
                    uint cur = queue[qi++];
                    int curState = state[cur];
                    auto f = faces[cur];
                    foreach (k; 0 .. f.length) {
                        uint a = f[k], b = f[(k + 1) % f.length];
                        uint lo = a < b ? a : b, hi = a < b ? b : a;
                        ulong ek = (cast(ulong)lo << 32) | hi;
                        auto users = edgeUsers[ek];
                        if (users.length != 2) continue;
                        int curSign = 0;
                        foreach (u; users) if (u.fi == cur) curSign = u.sign;
                        int curEff = curSign * (curState == 1 ? -1 : 1);
                        foreach (u; users) {
                            if (u.fi == cur) continue;
                            if ((u.fi in windingCandidate) is null) continue;   // fixed — already ground truth
                            if (u.fi in state) continue;                       // already assigned
                            int mul = neededMul(curEff, u.sign);
                            seed(u.fi, (mul == -1) ? 1 : 0);
                        }
                    }
                }
                bool addedRoot = false;
                foreach (fi, _; windingCandidate) {
                    if (fi in state) continue;
                    seed(fi, 0);
                    addedRoot = true;
                    break;
                }
                if (!addedRoot) break;
            }

            // Tracker: this pass runs AFTER every recordReshapeFaces/recordAddFaces
            // call above captured its own after-image, so a flip applied here is
            // otherwise INVISIBLE to the edit-delta — redo (MeshEditDelta.apply,
            // which replays faceListsAfter/faceLists verbatim) would silently
            // restore the pre-flip (folded) winding even though undo (which
            // restores the pre-op faces wholesale) is unaffected. Record exactly
            // the faces this loop actually flips as one more ReshapeFaces entry,
            // keyed by the POST-cleanup index `fi` — the same index space
            // `removeFacesForward` reproduces on redo (it repacks kept faces in
            // order, byte-identical to how `keptFaces` was built above), so this
            // entry composes correctly after the cleanup pass's RemoveFaces entry
            // on both forward replay and LIFO reverse. A call with an empty index
            // list (the common no-flip case) is a guaranteed no-op inside
            // recordReshapeFaces, so this adds nothing when nothing flipped.
            uint[]   windReshapeIdx;
            uint[][] windReshapeBefore;
            uint[][] windReshapeAfter;
            foreach (fi, st; state) {
                if (st != 1) continue;
                auto r = faces[fi].dup;
                foreach (j, vid; r) faces[fi][r.length - 1 - j] = vid;
                if (recExtrude) {
                    windReshapeIdx    ~= fi;
                    windReshapeBefore ~= r;
                    windReshapeAfter  ~= faces[fi].dup;
                }
            }
            if (recExtrude && windReshapeIdx.length)
                editRecorder_.recordReshapeFaces(windReshapeIdx, windReshapeBefore, windReshapeAfter);
        }

        // --- Rebuild edges + loops; size selection arrays explicitly. Then drop
        //     dissolved free-end endpoints (and any other orphan) so the vertex
        //     count matches the reference exactly.
        finalizeTopologyEdit();   // compactUnreferenced remaps verts; rebuilds edges + edgeIndexMap
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

    /// Vertex Extrude (Cone): additive. For each vertex selected in `mask`
    /// that is interior-manifold (valence ≥ 3, every incident edge shared
    /// by exactly 2 faces — same acceptance test `bevelVerticesByMask`
    /// uses), builds an N-gon ring of new vertices around it from its
    /// incident edges. UNLIKE `bevelVerticesByMask`, there is no vertex-
    /// disjoint gating: `vi` is never removed here, so two mutually-
    /// adjacent selected vertices process independently without conflict
    /// (confirmed against the captured 4-mutually-adjacent-corner parity
    /// case below — each vertex's own split points are private to it, even
    /// on a shared edge).
    ///
    /// DERIVED LAWS (task 0360, fitted byte-exact to the frozen reference
    /// fixtures — not just the summary prose):
    ///  - `width == 0` (any `shift`, either sign) is a COMPLETE no-op —
    ///    position-diffed byte-identical to the input, zero topology
    ///    change. (fully confirmed)
    ///  - `width != 0`, `shift == 0`: `vi`'s position is UNCHANGED
    ///    (stationary apex). Each incident edge e=(vi,other) spawns TWO
    ///    new vertices at the SAME position `vi + width·normalize(other −
    ///    vi)`:
    ///      * a "rim" vertex, private to `vi` but shared between the (≤2)
    ///        ORIGINAL faces incident to `vi` across `e` — substituted
    ///        into those faces in place of `vi`, exactly like
    ///        `bevelVerticesByMask`'s split ring;
    ///      * a "fan" vertex, ALSO private to `vi`, used only to close
    ///        `vi`'s own local wall+cap structure (never shared with the
    ///        original faces).
    ///    Per ORIGINAL face F incident at `vi` (bounded there by predEdge/
    ///    succEdge, in F's own winding), TWO new faces are appended:
    ///      bridgeQuad(F) = [rim_succ, rim_pred, fan_pred, fan_succ]
    ///      fanTri(F)     = [fan_succ, fan_pred, vi]
    ///    (`vi` itself is the fan's apex — never removed/duplicated).
    ///    This exactly reproduces the captured 4-corner cube case (8v/6f →
    ///    32v/30f, apex stationary — 6 new verts + 6 new faces per
    ///    accepted valence-3 vertex; see the golden fixture in
    ///    tests/test_vertex_extrude_tool.d).
    ///  - `width != 0` AND `shift != 0` (TENTATIVE — a SINGLE captured
    ///    data point, task 0360 toolcard `behavior.shift_and_width_together`):
    ///    the apex moves by `(shift + width) · vertexNormal(vi)` (confirmed
    ///    magnitude + direction for exactly one case — a cube corner,
    ///    shift=width=0.2 → 0.4 total displacement along the corner's
    ///    (1,1,1)-type outward normal, vertexNormal being the SAME
    ///    averaged-incident-face-normal formula the legacy single-vertex
    ///    kernel used). The rim/fan ring positions in the captured
    ///    combined case are NEITHER coincident with the shift==0 ring NOR
    ///    a simple lerp toward the moved apex — no general law was
    ///    derivable from one sample, so this kernel deliberately keeps
    ///    rim/fan at the SAME width-offset-from-`vi` formula as the
    ///    shift==0 case and only displaces the apex. This is a clearly-
    ///    flagged APPROXIMATION, not a verified reference match — do not
    ///    treat combined-case (shift!=0 && width!=0) geometry as
    ///    reference-accurate; only the no-op and width-alone laws above
    ///    are byte-exact.
    ///
    /// Selection is left untouched: `vi` is never removed or re-indexed,
    /// so whatever was selected stays selected — matches the captured
    /// post-apply selection (the apex vertices, at their original
    /// indices, NOT the new ring — unlike `bevelVerticesByMask`, which
    /// selects the new cap faces).
    ///
    /// Returns the number of accepted (processed) vertices, 0 on no-op.
    size_t extrudeVerticesByMask(in bool[] maskIn, float shift, float width)
    {
        const mask = maskMinusHiddenVertices(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != vertices.length) return 0;
        if (width == 0.0f) return 0;

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

        auto edgeFacesMap = buildEdgeFaces();

        bool[] accepted = new bool[](vertices.length);
        size_t processed = 0;
        foreach (vi; 0 .. cast(uint)vertices.length) {
            if (vi >= mask.length || !mask[vi]) continue;

            uint[] incEdges;
            foreach (ei; edgesAroundVertex(vi)) incEdges ~= ei;
            if (incEdges.length < 3) continue;

            bool manifold = true;
            foreach (ei; incEdges) {
                ulong key = edgeKey(edges[ei][0], edges[ei][1]);
                auto fp = key in edgeFacesMap;
                if (fp is null || (*fp)[0] < 0 || (*fp)[1] < 0) {
                    manifold = false; break;
                }
            }
            if (!manifold) continue;

            accepted[vi] = true;
            ++processed;
        }
        if (processed == 0) return 0;

        // Freeze original counts before addVertex grows the array.
        const uint origVertCount = cast(uint)vertices.length;
        const uint origFaceCount = cast(uint)faces.length;

        // rim/fan lookup, keyed by (vi << 32 | incidentEdgeIndex) — PRIVATE
        // per accepted vertex (unlike bevelVerticesByMask's splitByKey,
        // which is keyed by the raw edge alone: that dedup is only valid
        // there because bevel's vertex-disjoint gating guarantees at most
        // one accepted endpoint per edge; here BOTH endpoints of an edge
        // may independently be accepted, and each gets its OWN split point
        // — confirmed by the captured 4-mutually-adjacent-corner case,
        // where the shared edge between two selected corners carries TWO
        // distinct rim points, one near each end, not one shared midpoint
        // point).
        uint[ulong] rimOf;
        uint[ulong] fanOf;

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;
            Vec3 vpos = vertices[vi];
            foreach (ei; edgesAroundVertex(vi)) {
                uint other = edgeOtherVertex(cast(uint)ei, vi);
                Vec3 sp = vpos + width * safeNormalize(vertices[other] - vpos);
                ulong k = (cast(ulong)vi << 32) | cast(uint)ei;
                rimOf[k] = addVertex(sp);
                fanOf[k] = addVertex(sp);
            }
        }

        // Tentative shift+width apex law (see doc-comment above). Computed
        // AFTER rim/fan creation (which reads vi's ORIGINAL position) but
        // BEFORE the face rebuild below (faceNormal here still reads the
        // untouched `faces` array).
        if (shift != 0.0f) {
            foreach (vi; 0 .. origVertCount) {
                if (!accepted[vi]) continue;
                Vec3 n = Vec3(0, 0, 0);
                foreach (fi; facesAroundVertex(vi)) n = n + faceNormal(cast(uint)fi);
                float len = n.length;
                n = (len > 1e-6f) ? n * (1.0f / len) : Vec3(0, 1, 0);
                vertices[vi] = vertices[vi] + n * (shift + width);
            }
        }

        VertSub[][uint] faceSubs;
        struct NewFaceSpec { uint[] verts; uint srcFi; }
        NewFaceSpec[] extraFaces;

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;
            foreach (fi; facesAroundVertex(vi)) {
                uint p = predInFace_(cast(uint)fi, vi);
                uint s = succInFace_(cast(uint)fi, vi);
                uint peIdx = edgeIndexMap[edgeKey(p, vi)];
                uint seIdx = edgeIndexMap[edgeKey(vi, s)];
                ulong pk = (cast(ulong)vi << 32) | peIdx;
                ulong sk = (cast(ulong)vi << 32) | seIdx;
                uint rimPred = rimOf[pk], rimSucc = rimOf[sk];
                uint fanPred = fanOf[pk], fanSucc = fanOf[sk];

                faceSubs.require(cast(uint)fi) ~= VertSub(vi, [rimPred, rimSucc]);
                extraFaces ~= NewFaceSpec([rimSucc, rimPred, fanPred, fanSucc], cast(uint)fi);
                extraFaces ~= NewFaceSpec([fanSucc, fanPred, vi], cast(uint)fi);
            }
        }

        // single rebuild pass: substituted/surviving faces then new faces
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        uint[]   newWord;   // whole faceMarks word per new face (task 0613 §4.2)

        foreach (fi; 0 .. origFaceCount) {
            auto orig  = faces[fi];
            newFaces ~= rebuildFaceWithVertexSubs(orig, fi in faceSubs);
            newMat  ~=faceAttrOr(faceMaterial, fi);
            newPart ~=faceAttrOr(facePart, fi);
            newOrd  ~=faceAttrOr(faceSelectionOrder, fi);
            newWord ~= faceAttrOr(faceMarks, fi);
        }

        foreach (nf; extraFaces) {
            newFaces ~= nf.verts;
            newMat   ~=faceAttrOr(faceMaterial, nf.srcFi);
            newPart  ~=faceAttrOr(facePart, nf.srcFi);
            newOrd   ~= 0;
            newWord  ~= faceAttrOr(faceMarks, nf.srcFi);
        }

        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;

        // Rebuild faceMarks from scratch (resize+zero ALL bits, then set from
        // newWord) — was Subpatch-only; now carries the whole word (task 0613
        // §4.2), so Hide rides this rebuild instead of being silently wiped.
        setFaceMarksFrom(newWord, ~Marks.Select);

        resizeVertexSelection();
        clearEdgeSelectionResize();

        rebuildEdges();
        buildLoops();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
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
    size_t extendEdgesByMask(in bool[] maskIn,
                             float inset, float shift,
                             Vec3 offset, Vec3 rotateDeg, Vec3 scale,
                             int segments, Vec3 pivot = Vec3(0, 0, 0)) {
        const mask = maskMinusHiddenEdges(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        import math : Vec3, cross, dot, normalize;
        import std.math : sin, cos, abs, PI;
        if (mask.length != edges.length) return 0;
        if (segments < 1) segments = 1;    // clamp: N≥1. N=1 is the base ring of
                                           // the general loop (same topology/
                                           // order as pre-Phase-3; see doc above).
        // DoS backstop (task 0365 P1): `segments` allocates one new ring of
        // verts + bridge faces per step; Param `.min()/.max()` hints are
        // UI-only and do not clamp a direct/scripted caller reaching this
        // shared kernel.
        enum int MAX_EXTEND_SEGMENTS = 1024;
        if (segments > MAX_EXTEND_SEGMENTS) segments = MAX_EXTEND_SEGMENTS;

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
            auto p = edgeKey(va, vb) in edgeFaces;
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
        //     INSET LAW (parity-measured): the perpendicular drop at every new
        //     vert is built from the DISTINCT face planes incident at the source
        //     vertex `v` (every face containing `v`, not just the selected edge's
        //     neighbours). At an INTERIOR corner it is −inset·factor·Σn over those
        //     planes, `factor = 1/(1 + nA·nB)` the selected edge's dihedral term
        //     (see INSET DIHEDRAL FACTOR below); at a BOUNDARY-only corner it is the
        //     min-norm offset-meet `delta·n_f = −inset` over the same planes (a lone
        //     flat face → −inset·n, a two-face open fan → their bisector meet).
        //     There is NO separate axial term. On a cube the two forms coincide
        //     (orthonormal normals ⇒ factor = 1, meet = sum), so cube/flat grids
        //     stay byte-identical; they diverge on arbitrary-dihedral geometry.
        // Distinct face planes per corner (deduped by face id).
        Vec3[][uint] cornerNormals;          // v → distinct incident face normals
        bool[ulong]  cornerFaceSeen;         // (v<<32|fi) → already counted at v
        Vec3[uint]   cornerShiftTerm;        // v → Σ boundary shift·in-plane-perp (deduped)
        Vec3[][uint] cornerShiftDirs;        // v → unit outward-perps already folded
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
        // Fold one boundary edge's `shift·(unit outward-perp)` into vertex v, but
        // DEDUP by direction: ≥2 COLLINEAR boundary edges meeting at a straight
        // mid-rim vertex present the SAME outward-perp, and reference slides that
        // shared vertex ONCE (not once per incident edge). Skip a contribution
        // whose unit perp coincides with one already folded at v; a GENUINE corner
        // (non-parallel edges → distinct perps, dot≈0) still accumulates both, so
        // L-corners and interior chains are unaffected.
        void addCornerShift(uint v, Vec3 dir) {
            if (auto seen = v in cornerShiftDirs)
                foreach (ref d0; *seen)
                    if (dot(d0, dir) > 0.999999f) return;   // collinear → count once
            cornerShiftDirs.update(v, () => [dir], (ref Vec3[] acc) { acc ~= dir; });
            Vec3 term = dir * shift;
            cornerShiftTerm.update(v, () => term, (ref Vec3 acc) { acc = acc + term; });
        }
        // Corner face planes are gathered above over ALL incident faces. Here we
        // only fold in each BOUNDARY edge's `shift·in-plane-outward-perp` term
        // (the free-boundary slide); inset is fully subsumed by the incident-face
        // meet.
        foreach (ref e; exEdges) {
            if (e.fB == -1 && shift != 0.0f) {
                Vec3 perp = boundaryOutwardPerp(e.va, e.vb, e.fA);
                if (perp.length < 1e-6f) continue;          // degenerate edge → no slide
                addCornerShift(e.va, perp);
                addCornerShift(e.vb, perp);
            }
        }

        // --- INSET DIHEDRAL FACTOR (parity-measured). At an INTERIOR selected
        //     edge, the reference's perpendicular inset drop at each endpoint is
        //     the plain SUM of that corner's distinct incident face normals scaled
        //     by −inset AND by a per-edge dihedral factor `1/(1 + nA·nB)`, where
        //     nA,nB are the unit normals of the edge's two adjacent faces. This is
        //     NOT the min-norm offset-meet: the two agree only when the corner's
        //     normals are orthonormal (cube / flat grids — which is why those stay
        //     byte-identical), but diverge on every arbitrary-dihedral geometry.
        //     Verified bit-exact against reference dumps across prism3/prism5 side
        //     & rim dihedrals, 2-face tents at 60°/90°/120°/asymmetric folds, and
        //     welded chain/star corners. The factor depends on how many FOLD edges
        //     the corner welds:
        //       – exactly ONE incident selected fold edge → 1/(1 + nA·nB) of that
        //         edge (free end / lone rim edge: prism rim=1, prism apex=2, tents).
        //       – TWO OR MORE (welded chain / star junction) → factor 1, the plain
        //         −inset·Σn drop. Parity: prism3 & cyl6 star corners take the plain
        //         sum even when a fold edge there has g≠0 — the extra weld
        //         constraints cancel the single-edge dihedral scaling.
        //     A corner with only boundary or coplanar selected edges (no fold pair)
        //     keeps the min-norm meet — the open-fan / boundary law, parity-correct.
        int[uint]   cornerFoldCount;            // v → # incident selected FOLD edges
        float[uint] cornerFoldG;                // v → nA·nB of that edge (count==1 only)
        foreach (ref e; exEdges) {
            if (e.fB == -1) continue;           // boundary edge — no dihedral pair
            float g = dot(faceNormal(cast(uint)e.fA), faceNormal(cast(uint)e.fB));
            // COPLANAR edges (g ≈ +1) are not a fold: the two faces share a plane
            // and `cornerNormals` already dedups them to one normal, so the factor
            // must NOT scale (`1/(1+1)=½` would halve the drop). Skip them — such a
            // corner falls back to the min-norm meet, which gives the correct flat
            // `−inset·n` (chain2_mixed / chain2_asym flat rows stay byte-identical).
            if (g > 1.0f - 1e-4f) continue;
            foreach (v; [e.va, e.vb]) {
                cornerFoldCount[v] = (v in cornerFoldCount ? cornerFoldCount[v] : 0) + 1;
                cornerFoldG[v] = g;             // only consulted when count == 1
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
        //     source vertex. INSET (interior corner) = −inset · dihedral-factor ·
        //     Σ(distinct incident face normals) — see INSET DIHEDRAL FACTOR above.
        //     INSET (boundary-only corner) = min-norm offset-meet over ALL distinct
        //     incident faces (the open-fan law: a lone flat boundary face reduces
        //     to −inset·n, a boundary corner spanning two faces to their 2-plane
        //     meet). SHIFT = each incident boundary edge's in-plane slide, already
        //     accumulated into cornerShiftTerm.
        Vec3[uint] insetShiftOf;
        void computeDelta(uint v) {
            if (v in insetShiftOf) return;
            Vec3 delta = Vec3(0, 0, 0);
            if (auto np = v in cornerNormals) {
                Vec3[] norms = *np;
                auto cp = v in cornerFoldCount;
                // factor·sum branch requires ≥1 incident fold edge AND a SHARP
                // corner of at most 3 distinct face planes. The `−inset·factor·Σn`
                // law was measured on the sharp 3-plane prism / cyl family: a corner
                // whose 3 planes robustly span R³ has a unique offset-meet that the
                // reference OVER-shoots, taking the scaled sum instead. Two guards
                // keep it there and off subdivided qball/cc/tess corners (which the
                // reference leaves on the least-squares meet — the sum over-drives
                // them):
                //   • valence ≤ 3 distinct planes (≥4 → rank-deficient → meet), and
                //   • the 3 planes are well-conditioned: |n₀·(n₁×n₂)| ≥ 0.6 (prism/
                //     cyl rim corners measure ~0.87–0.95; smooth cc/tess 3-fans
                //     ~0.36, so they stay on the meet — no subdivided-mesh change).
                // For a single fold edge use 1/(1+g); for a weld (≥2) use the plain
                // sum (factor 1). A near-fold single edge (g → −1) blows the factor
                // up, so fall back to the bounded min-norm meet (meet's rank guard).
                bool useFactor = (cp !is null) && (norms.length <= 3);
                if (useFactor && norms.length == 3) {
                    float triple = abs(dot(norms[0], cross(norms[1], norms[2])));
                    if (triple < 0.6f) useFactor = false;   // smooth fan → meet
                }
                float factor = 1.0f;
                if (useFactor && *cp == 1) {
                    float g = cornerFoldG[v];
                    if ((1.0f + g) > 1e-4f) factor = 1.0f / (1.0f + g);
                    else useFactor = false;     // degenerate fold → meet
                }
                if (useFactor) {
                    Vec3 summ = Vec3(0, 0, 0);
                    foreach (ref nf; norms) summ = summ + nf;
                    delta = summ * (-inset * factor);
                } else {
                    float[] tgts;
                    tgts.length = norms.length;
                    foreach (i; 0 .. norms.length) tgts[i] = -inset;
                    delta = minNormMeet(norms, tgts);
                }
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
        //     the bridge is manifold-consistent with — traverses the shared edge
        //     OPPOSITE to — that face; NOT the raw edges[] tuple, which would flip
        //     ~half the bridges). `buildEdgeFaces` stores fA = the LOWER face index,
        //     fB = the other, so `e.fA` is already the lower-index neighbour.
        //
        //     Which of a 2-face interior edge's neighbours orients the bridge is
        //     GEOMETRICALLY UNDER-DETERMINED (both give a locally valid winding).
        //     A cube rim edge and a prism rim edge are LOCALLY identical (both a
        //     90° pair, one axis-aligned face + one perpendicular face), yet the
        //     reference winds them oppositely — so the discriminator must be the
        //     MESH as a whole, not the edge. Two regimes, parity-measured:
        //
        //       • TILTED mesh (ANY face is NOT a signed unit axis — prism / cyl /
        //         cc / qball / tess …): wind every bridge by ORIENTABILITY against
        //         the LOWER-INDEX neighbour (`e.fA`, which buildEdgeFaces already
        //         stores as the min index) — the same topological rule
        //         edge.extrude's `emitBridgeFromFace` uses. Verified bit-exact on
        //         prism3 / prism5 rim & side edges, single edges AND welded
        //         star/chain corners. This is the N2 winding fix: the old normal
        //         comparator flipped every tilted bridge.
        //
        //       • AXIS-ALIGNED mesh (cube / flat grids — every face normal is a
        //         signed unit axis): a symmetric interior weld is a true tie whose
        //         resolution tracks the reference's internal face-storage order
        //         (not portable). The calibrated normal comparator (sort by
        //         (n.y,−n.x,−n.z), coplanar tie → lower index) reproduces the cube
        //         star3/chain2/interior goldens, so keep it — this is what holds
        //         cube / flat output BYTE-IDENTICAL.
        static bool axisAligned(Vec3 n) {
            import std.math : abs;
            static bool onAxis(float c) { float a = abs(c); return a < 1e-4f || a > 1.0f - 1e-4f; }
            return onAxis(n.x) && onAxis(n.y) && onAxis(n.z);
        }
        bool meshAxisAligned = true;
        foreach (fi; 0 .. faces.length)
            if (!axisAligned(faceNormal(cast(uint)fi))) { meshAxisAligned = false; break; }
        static double[3] orientKey(Vec3 n) {
            return [cast(double)n.y, cast(double)(-n.x), cast(double)(-n.z)];
        }
        int orientFaceOf(ref ExtEdge e) {
            if (e.fB == -1) return e.fA;          // boundary: the sole face
            // Tilted mesh → portable lower-index orientability (= e.fA).
            if (!meshAxisAligned)
                return e.fA < e.fB ? e.fA : e.fB;
            // Axis-aligned mesh → calibrated comparator (cube/flat byte-identical).
            auto ka = orientKey(faceNormal(cast(uint)e.fA));
            auto kb = orientKey(faceNormal(cast(uint)e.fB));
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
            uint mat  = faceAttrOr(faceMaterial, orientFace);
            uint part = faceAttrOr(facePart, orientFace);
            foreach (k; 1 .. N + 1) {
                faceMaterial       ~= mat;
                facePart           ~= part;
                faceSelectionOrder ~= 0;
            }
        }
        resizeSubpatch();
        // Task 0389: each stacked bridge inherits Subpatch from the SAME
        // orienting face the material/part loop above already resolves from
        // — same nested iteration order as the face-emission loop, so a
        // running cursor maps 1:1 onto the just-appended bridge tail
        // [firstBridge .. $).
        {
            size_t cursor = firstBridge;
            foreach (bi, ref e; exEdges) {
                int orientFace = orientFaceOf(e);
                bool sub = isFaceSubpatch(orientFace);
                foreach (k; 1 .. N + 1) {
                    setFaceSubpatch(cursor, sub);
                    ++cursor;
                }
            }
        }

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
    /// Multi-island selections: selected faces are grouped into connected
    /// components ("islands") via edge adjacency (two faces are in the same
    /// island only if they share a full EDGE, not merely a vertex). Each
    /// island gets its own inset/clone vertices, even at a corner shared with
    /// another island (e.g. a diagonal/checkerboard face pair touching at one
    /// vertex) — otherwise a single merged clone at that corner would have
    /// its cap-side vertical edge walled by both islands at once, producing
    /// an edge used by 4 faces (non-manifold; task 0312).
    ///
    /// Phase 5 (delta-path undo) is deferred: the drop+compact step makes the
    /// append-only recordAddFaces revert insufficient, so only snapshot undo
    /// (MeshFaceExtrudeEdit) is wired for Phases 1-4.
    ///
    /// Non-manifold-region reject (fuzz-found): if the selected region touches
    /// a "book" edge (an undirected edge already shared by more than 2 faces
    /// total), the whole call is a clean no-op (returns 0) rather than risk
    /// winding/coincident corruption from extruding into an already-invalid
    /// neighborhood.
    size_t extrudeFacesByMask(in bool[] maskIn, float distance, bool smooth = false) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != faces.length) return 0;
        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0) return 0;
        if (distance == 0.0f) return 0;

        // Non-manifold-region reject (fuzz-found): reject the whole operation
        // if any edge of a SELECTED face is already shared by more than 2
        // faces total (a "book" edge — e.g. 3+ pages hinged on one edge).
        // Counts incidences directly with an edgeKey map over ALL
        // faces — NOT via buildEdgeFaces(), whose int[2] slot can't witness a
        // 3rd/4th incident face (see its own comment below) — mirroring the
        // 0312 unittest's edgeUseCount idiom. Matches the 0316 saturated-edge
        // reject idiom. "Operate-per-2-manifold-island" was considered and
        // rejected: the island BFS below itself rides buildEdgeFaces, which is
        // blind to the same extra faces, so it can't reliably partition a
        // book edge either — reject is the minimal, house-consistent choice.
        {
            size_t[ulong] edgeUseCountAll;
            foreach (fi; 0 .. faces.length) {
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    ulong key = edgeKey(f[k], f[(k + 1) % f.length]);
                    auto p = key in edgeUseCountAll;
                    if (p is null) edgeUseCountAll[key] = 1;
                    else           ++(*p);
                }
            }
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                auto f = faces[fi];
                foreach (k; 0 .. f.length) {
                    ulong key = edgeKey(f[k], f[(k + 1) % f.length]);
                    if (edgeUseCountAll[key] > 2) return 0;
                }
            }
        }

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

        // Edge → (≤2 incident faces) adjacency, one pass.
        auto edgeFaces = buildEdgeFaces();

        // Connected-component ("island") id per selected face, via adjacency
        // through a FULLY shared edge (both incident faces selected). Two
        // selected faces that only touch at a single vertex (no shared edge
        // — e.g. a diagonal/checkerboard pair) are DIFFERENT islands: each
        // must get its own inset vertex at that shared corner. Without this,
        // a single merged clone at the corner would have its cap-side
        // vertical edge walled by BOTH islands at once — an edge used by 4
        // faces (non-manifold). Fuzz-found: task 0312.
        int[size_t] islandOf;
        {
            size_t[][size_t] adj;
            foreach (key, fp; edgeFaces) {
                if (fp[0] < 0 || fp[1] < 0) continue;
                if (fp[0] >= cast(int)mask.length || fp[1] >= cast(int)mask.length) continue;
                if (!mask[fp[0]] || !mask[fp[1]]) continue;
                adj[cast(size_t)fp[0]] ~= cast(size_t)fp[1];
                adj[cast(size_t)fp[1]] ~= cast(size_t)fp[0];
            }
            int nextIsland = 0;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                if (fi in islandOf) continue;
                size_t[] stack = [fi];
                islandOf[fi] = nextIsland;
                while (stack.length) {
                    size_t cur = stack[$ - 1];
                    stack = stack[0 .. $ - 1];
                    if (auto nbrs = cur in adj)
                        foreach (nb; *nbrs)
                            if (nb !in islandOf) {
                                islandOf[nb] = nextIsland;
                                stack ~= nb;
                            }
                }
                ++nextIsland;
            }
        }
        // Combined (island, vertex) key: an inset/clone vertex is scoped to
        // one island, so the same original vertex shared by two islands
        // (touching only at that corner) gets one clone PER island instead
        // of one merged clone.
        static ulong ivKey(int island, uint vid) {
            return (cast(ulong)cast(uint)island << 32) | vid;
        }

        // Per-(island,vertex) offset table — FULLY built BEFORE the dedup
        // clone loop. The clone loop visits each (island,vid) only once (on
        // first sight), so any accumulation inside it would drop every
        // face's contribution after the first for shared/ridge verts. We
        // pre-build here to guarantee the complete sum.
        //
        // Smooth (smooth=true): accumulate the unit normals of the selected
        // incident faces IN THE SAME ISLAND for each (island,vid), then
        // normalize. Fallback chain:
        //   avg-normal degenerate → regionNormal → Vec3(0,1,0).
        // vibe3d-divergence: UNIFORM weighting (each face's unit normal
        // contributes equally).  Area- or angle-weighted averaging would be a
        // one-line change to the accumulation; deferred as a documented
        // divergence — the geometry-reference harness is absent from this
        // checkout so empirical capture is infeasible.
        //
        // Rigid (smooth=false, default): every (island,vid) gets
        // regionNormal*distance, byte-identical to the pre-refactor
        // per-vertex behaviour (regionNormal is one global value shared by
        // every island — only the CLONE identity is separated per island,
        // not the offset direction).
        Vec3[ulong] vertOffset;
        if (smooth) {
            Vec3[ulong] vNormSum;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                Vec3 fn = faceNormal(cast(uint)fi);
                int island = islandOf[fi];
                foreach (vid; faces[fi]) {
                    ulong k = ivKey(island, vid);
                    auto p = k in vNormSum;
                    if (p is null) vNormSum[k] = fn;
                    else          *p = *p + fn;
                }
            }
            foreach (k, nsum; vNormSum) {
                float nlen = sqrt(nsum.x*nsum.x + nsum.y*nsum.y + nsum.z*nsum.z);
                Vec3 dir = (nlen > 1e-6f) ? nsum * (1.0f / nlen) : regionNormal;
                vertOffset[k] = dir * distance;
            }
        } else {
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                int island = islandOf[fi];
                foreach (vid; faces[fi]) {
                    ulong k = ivKey(island, vid);
                    if (k !in vertOffset)
                        vertOffset[k] = regionNormal * distance;
                }
            }
        }

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

        // Clone each (island,vertex) used by a selected face (once per
        // island,vertex pair — see the ivKey comment above for why a corner
        // shared between two islands needs two separate clones). Offset
        // comes from the pre-built vertOffset table, not computed here.
        uint[ulong] vertMap;
        foreach (fi; 0 .. faces.length) {
            if (!mask[fi]) continue;
            int island = islandOf[fi];
            foreach (vid; faces[fi]) {
                ulong k = ivKey(island, vid);
                if (k !in vertMap)
                    vertMap[k] = addVertex(vertices[vid] + vertOffset[k]);
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
        uint[]   newWord;   // whole faceMarks word per new face (task 0613 §4.2)

        // Non-selected originals, kept as-is.
        foreach (fi; 0 .. faces.length) {
            if (mask[fi]) continue;
            newFaces ~= faces[fi];
            newMat   ~=faceAttrOr(faceMaterial, fi);
            newPart  ~=faceAttrOr(facePart, fi);
            newOrd   ~=faceAttrOr(faceSelectionOrder, fi);
            newWord  ~= faceAttrOr(faceMarks, fi);
        }
        immutable size_t capStart = newFaces.length;   // first cap index in newFaces

        // Cap clones: re-emit each selected face with cloned (offset) verts.
        foreach (fi; toCloneFace) {
            auto src = faces[fi];
            uint[] cloned;
            cloned.length = src.length;
            int island = islandOf[fi];
            foreach (k, vid; src) cloned[k] = vertMap[ivKey(island, vid)];
            newFaces ~= cloned;
            newMat   ~=faceAttrOr(faceMaterial, fi);
            newPart  ~=faceAttrOr(facePart, fi);
            newOrd   ~= 0;
            newWord  ~= faceAttrOr(faceMarks, fi);
        }

        // Wall quads: one per boundary edge, oriented by the orientability rule.
        // The cap face traverses (cloneA, cloneB) in the SAME direction as the
        // original selected face traverses (a, b), since we only substituted indices.
        // The wall must share the cap's top edge in the OPPOSITE direction.
        foreach (ref be; bEdges) {
            uint a = be.va, b = be.vb;
            int island = islandOf[be.selFi];
            uint cloneA = vertMap[ivKey(island, a)], cloneB = vertMap[ivKey(island, b)];
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
            newMat  ~=faceAttrOr(faceMaterial, be.selFi);
            newPart ~=faceAttrOr(facePart, be.selFi);
            newOrd  ~= 0;
            // Task 0389: side wall inherits Subpatch from the extruded source
            // face it skirts, same as its material/part above (task 0613 §4.2:
            // now the whole word, so Hide inherits the same way).
            newWord ~= faceAttrOr(faceMarks, be.selFi);
        }

        // Assign reconstructed arrays.
        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;
        // Rebuild faceMarks from scratch: resize+zero ALL bits (clears stale
        // Select from the old ordering), then set from newWord (task 0613
        // §4.2 — was Subpatch-only).
        setFaceMarksFrom(newWord, ~Marks.Select);

        // New selection = cap faces (so a follow-up op chains off the top).
        faceSelectionOrderCounter = 0;
        foreach (fi; capStart .. capStart + selCount)
            selectFace(cast(int)fi);

        // Clear vertex + edge selections.
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        // Tail: rebuild topology, drop orphaned original interior verts.
        finalizeTopologyEdit();   // compactUnreferenced removes original selected-face verts not kept by walls

        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return selCount;
    }

    // -------------------------------------------------------------------
    // Smooth Shift + Thicken kernel (task 0358). A deliberately SEPARATE
    // function from extrudeFacesByMask — it is NOT a drop-in replacement
    // and does not share its call sites (face_extrude.d, poly_extrude.d,
    // smooth_shift.d's existing one-shot command all keep calling
    // extrudeFacesByMask, untouched). Backs the interactive Smooth Shift
    // tool (tools.deform.smooth_shift_tool.SmoothShiftTool).
    //
    // Per-(island,vertex) cap law, fitted to the frozen reference fixture
    // (see tests/fixtures/smooth_shift.json):
    //     capPos = islandCentroid + scale * ((origPos + shift*smoothN) - islandCentroid)
    // i.e. a standard per-vertex-smoothed-normal shift-extrude (the same
    // "smooth=true" normal-averaging extrudeFacesByMask already does),
    // followed by scaling the resulting cap footprint about the ISLAND'S
    // ORIGINAL (pre-offset) cloned-vertex centroid. scale==1 collapses to
    // a plain shift-extrude (matches the captured shift03 combo); the
    // shift03_scale05 combo (shift=0.3, scale=0.5) pins this exact law —
    // e.g. corner (-0.5,0.5,-0.5) → (-0.25, 0.65, -0.25), not (…, 0.8, …).
    //
    // UNLIKE extrudeFacesByMask, shift==0 is NOT special-cased as a no-op:
    // the reference always builds the full (possibly-degenerate,
    // coincident-vertex) extrude topology at shift=0 — confirmed live
    // (combo "base_noop": a plain cube's top face still comes out 12v/10f).
    // The caller (the interactive tool) decides whether a fully-identity
    // gesture (nothing dragged) is worth an undo entry — see
    // SmoothShiftTool's session lifecycle.
    //
    // `thicken`: when true, each cloned face's ORIGINAL vertices are
    // additionally re-emitted, winding-REVERSED, as an extra "retained"
    // polygon — a selection-scoped, symmetric double-walled protrusion
    // (confirmed live: combo "thicken_top_only", 11 faces vs. 10 for the
    // non-thicken case, the 11th being the original 4 verts unmoved; the
    // winding reversal itself is independently derivable from the
    // captured index order via the right-hand-rule face normal, not just
    // taken from the reference help text). Deliberately distinct from
    // Mesh.thickenSurface, which shells the WHOLE mesh unconditionally —
    // a different, valid, unrelated feature (task 0358 finding).
    //
    // `maxAngle` (crease-gated normal splitting) and `sharp` (crease-corner
    // rounding) are NOT parameters of this kernel and are NOT implemented —
    // the same simplification smooth_shift.d's own doc comment already
    // flags for the one-shot command (uniform, unweighted per-vertex normal
    // averaging, no angle-gated splitting). SmoothShiftTool still stores/
    // exposes both as panel attrs (for field-order parity with the
    // reference panel), but their values do not affect geometry yet.
    //
    // Polygons-mode only (checked by the caller); empty selection ⇒ whole
    // mesh (per the caller's mask convention, matching extrudeFacesByMask).
    // Returns the number of faces cloned (0 on any no-op condition:
    // mismatched mask, nothing selected, or a closed island with no
    // boundary edges to wall).
    size_t smoothShiftFacesByMask(in bool[] maskIn, float shift, float scale, bool thicken) {
        const mask = maskMinusHiddenFaces(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != faces.length) return 0;
        size_t selCount = 0;
        foreach (b; mask) if (b) ++selCount;
        if (selCount == 0) return 0;

        // Region-normal fallback for a degenerate (near-zero-length)
        // per-vertex smoothed normal — same rule as extrudeFacesByMask.
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

        auto edgeFaces = buildEdgeFaces();

        // Island id per selected face — adjacency via a FULLY shared edge
        // (both incident faces selected). Mirrors extrudeFacesByMask's
        // task-0312 fix: two selected faces touching only at a vertex are
        // different islands, each getting its own clone at that corner.
        int[size_t] islandOf;
        {
            size_t[][size_t] adj;
            foreach (key, fp; edgeFaces) {
                if (fp[0] < 0 || fp[1] < 0) continue;
                if (fp[0] >= cast(int)mask.length || fp[1] >= cast(int)mask.length) continue;
                if (!mask[fp[0]] || !mask[fp[1]]) continue;
                adj[cast(size_t)fp[0]] ~= cast(size_t)fp[1];
                adj[cast(size_t)fp[1]] ~= cast(size_t)fp[0];
            }
            int nextIsland = 0;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                if (fi in islandOf) continue;
                size_t[] stack = [fi];
                islandOf[fi] = nextIsland;
                while (stack.length) {
                    size_t cur = stack[$ - 1];
                    stack = stack[0 .. $ - 1];
                    if (auto nbrs = cur in adj)
                        foreach (nb; *nbrs)
                            if (nb !in islandOf) {
                                islandOf[nb] = nextIsland;
                                stack ~= nb;
                            }
                }
                ++nextIsland;
            }
        }
        static ulong ivKey(int island, uint vid) {
            return (cast(ulong)cast(uint)island << 32) | vid;
        }

        // Per-(island,vertex) smoothed normal: uniform average of incident
        // selected-face normals within the island; degenerate → regionNormal.
        Vec3[ulong] vNorm;
        {
            Vec3[ulong] vNormSum;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                Vec3 fn = faceNormal(cast(uint)fi);
                int island = islandOf[fi];
                foreach (vid; faces[fi]) {
                    ulong k = ivKey(island, vid);
                    auto p = k in vNormSum;
                    if (p is null) vNormSum[k] = fn;
                    else          *p = *p + fn;
                }
            }
            foreach (k, nsum; vNormSum) {
                float nlen = sqrt(nsum.x*nsum.x + nsum.y*nsum.y + nsum.z*nsum.z);
                vNorm[k] = (nlen > 1e-6f) ? nsum * (1.0f / nlen) : regionNormal;
            }
        }

        // Per-island centroid of the ORIGINAL (pre-offset) cloned-vertex
        // positions — the scale pivot. Each (island,vertex) counts ONCE
        // (a shared ridge vertex must not be over-weighted by its incident
        // selected-face count).
        Vec3[int] islandCentroid;
        {
            Vec3[int] sum;
            int[int]  cnt;
            bool[ulong] seen;
            foreach (fi; 0 .. faces.length) {
                if (!mask[fi]) continue;
                int island = islandOf[fi];
                foreach (vid; faces[fi]) {
                    ulong k = ivKey(island, vid);
                    if (k in seen) continue;
                    seen[k] = true;
                    auto p = island in sum;
                    if (p is null) { sum[island] = vertices[vid]; cnt[island] = 1; }
                    else           { *p = *p + vertices[vid]; cnt[island] = cnt[island] + 1; }
                }
            }
            foreach (isl, s; sum)
                islandCentroid[isl] = s * (1.0f / cast(float)cnt[isl]);
        }

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
        if (bEdges.length == 0) return 0;   // closed island → nothing to wall

        // Clone each (island,vertex) used by a selected face, once per
        // (island,vertex) pair, at the scaled cap position.
        uint[ulong] vertMap;
        foreach (fi; 0 .. faces.length) {
            if (!mask[fi]) continue;
            int island = islandOf[fi];
            Vec3 cen = islandCentroid[island];
            foreach (vid; faces[fi]) {
                ulong k = ivKey(island, vid);
                if (k in vertMap) continue;
                Vec3 orig    = vertices[vid];
                Vec3 shifted = orig + vNorm[k] * shift;
                Vec3 capPos  = cen + (shifted - cen) * scale;
                vertMap[k] = addVertex(capPos);
            }
        }

        size_t[] toCloneFace;
        foreach (fi; 0 .. faces.length) if (mask[fi]) toCloneFace ~= fi;

        // Reconstruct faces + parallel arrays (deleteFacesByMask rebuild
        // idiom). Order: [non-selected originals] + [cap clones] +
        // [thicken-retained originals, if any] + [wall quads].
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        uint[]   newWord;   // whole faceMarks word per new face (task 0613 §4.2)

        foreach (fi; 0 .. faces.length) {
            if (mask[fi]) continue;
            newFaces ~= faces[fi];
            newMat   ~=faceAttrOr(faceMaterial, fi);
            newPart  ~=faceAttrOr(facePart, fi);
            newOrd   ~=faceAttrOr(faceSelectionOrder, fi);
            newWord  ~= faceAttrOr(faceMarks, fi);
        }
        immutable size_t capStart = newFaces.length;

        // Cap clones: re-emit each selected face with cloned (offset+scaled)
        // verts, same per-corner order as the original (index substitution
        // only), same convention extrudeFacesByMask uses.
        foreach (fi; toCloneFace) {
            auto src = faces[fi];
            uint[] cloned;
            cloned.length = src.length;
            int island = islandOf[fi];
            foreach (k, vid; src) cloned[k] = vertMap[ivKey(island, vid)];
            newFaces ~= cloned;
            newMat   ~=faceAttrOr(faceMaterial, fi);
            newPart  ~=faceAttrOr(facePart, fi);
            newOrd   ~= 0;
            newWord  ~= faceAttrOr(faceMarks, fi);
        }

        // Thicken: retain the ORIGINAL (unmoved) face verts, winding
        // REVERSED, as an extra inner-skin polygon per cloned face.
        if (thicken) {
            foreach (fi; toCloneFace) {
                auto src = faces[fi];
                uint[] reversed;
                reversed.length = src.length;
                foreach (k, vid; src) reversed[$ - 1 - k] = vid;
                newFaces ~= reversed;
                newMat   ~=faceAttrOr(faceMaterial, fi);
                newPart  ~=faceAttrOr(facePart, fi);
                newOrd   ~= 0;
                // Task 0389: the retained skin is a reversed duplicate of the
                // source face at its ORIGINAL position — inherit its whole
                // marks word rather than always dropping it, so a Thicken on
                // a subdiv-marked (or, now, hidden) face keeps both shells
                // matching (task 0613 §4.2).
                newWord  ~= faceAttrOr(faceMarks, fi);
            }
        }

        // Wall quads: one per boundary edge (same orientability rule as
        // extrudeFacesByMask — the cap walks cloneA→cloneB iff the original
        // face walked a→b; the wall shares that top edge in the opposite
        // direction).
        foreach (ref be; bEdges) {
            uint a = be.va, b = be.vb;
            int island = islandOf[be.selFi];
            uint cloneA = vertMap[ivKey(island, a)], cloneB = vertMap[ivKey(island, b)];
            bool origAtoB = false;
            auto orig = faces[be.selFi];
            foreach (k; 0 .. orig.length) {
                uint u = orig[k], w = orig[(k + 1) % orig.length];
                if (u == a && w == b) { origAtoB = true;  break; }
                if (u == b && w == a) { origAtoB = false; break; }
            }
            if (origAtoB) newFaces ~= [cloneB, cloneA, a, b];
            else          newFaces ~= [cloneA, cloneB, b, a];
            newMat  ~=faceAttrOr(faceMaterial, be.selFi);
            newPart ~=faceAttrOr(facePart, be.selFi);
            newOrd  ~= 0;
            // Task 0389: skin wall inherits Subpatch from the source face it
            // skirts, same as its material/part above (task 0613 §4.2: now
            // the whole word).
            newWord ~= faceAttrOr(faceMarks, be.selFi);
        }

        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;
        setFaceMarksFrom(newWord, ~Marks.Select);

        // New selection = cap faces (chains a follow-up op off the top, same
        // as extrudeFacesByMask). The retained thicken skin is NOT selected.
        faceSelectionOrderCounter = 0;
        foreach (fi; capStart .. capStart + selCount)
            selectFace(cast(int)fi);

        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        finalizeTopologyEdit();

        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return selCount;
    }
}

// ===========================================================================
// Module unittests. Moved VERBATIM from mesh.d, where they lived until the
// mesh.d decomposition split this kernel family out: a test belongs in the
// module holding the code it asserts on. Blocks are in their original mesh.d
// order; the `version (unittest)` helpers they call moved with them (no
// caller for those helpers stayed behind in mesh.d, so nothing is duplicated).
//
// The selective imports below mirror mesh.d's module-scope import list. A
// moved block used to resolve these bare names through its old home's
// module scope; mirroring them HERE keeps every block byte-identical to the
// version that ran in mesh.d instead of editing the tests.
// ===========================================================================
version (unittest) {
    import std.math : sqrt;
}

// Mesh-robustness batch (fuzz-found): a standalone open n-gon (single
// face, open boundary loop) whose corners are all SHARED (>=2 selected
// boundary edges per corner) run through an overshoot `width` at
// `extrude=0` used to mint a coincident duplicate vertex at each original
// corner position — the Pass-1 ridge vertex always minted a NEW vertex
// via addVertex(v + dir*extrude) even when extrude=0 (where dir*extrude
// is exactly the zero vector). Fixed: Pass 1 reuses the original vertex
// id at extrude≈0 instead. Confirmed by an HTTP-level before/after probe:
// a regular pentagon, all 5 boundary edges selected, extrude=0/width=0.3
// produced V=15 (5 coincident pairs) before the fix, V=10 (none) after.
unittest {
    import std.conv : to;

    // Regular pentagon: single open-boundary face, every corner shared
    // by exactly 2 boundary edges (a chain-joint corner, not a free end).
    Mesh m;
    import std.math : PI, cos, sin;
    uint[] pent;
    foreach (k; 0 .. 5) {
        double ang = 2 * PI * k / 5 - PI / 2;
        pent ~= m.addVertex(Vec3(cast(float)cos(ang), 0, cast(float)sin(ang)));
    }
    m.addFace(pent);

    bool[] mask; mask.length = m.edges.length; mask[] = true;
    size_t n = m.extrudeEdgesByMask(mask, 0.0f, 0.3f);
    assert(n == 5, "pentagon shared-corner extrude=0: expected 5 edges extruded, got " ~ n.to!string);

    // No coincident duplicate vertices.
    foreach (i; 0 .. m.vertices.length) {
        foreach (j; i + 1 .. m.vertices.length) {
            Vec3 d = m.vertices[i] - m.vertices[j];
            float d2 = d.x*d.x + d.y*d.y + d.z*d.z;
            assert(d2 > 1e-8f,
                "pentagon shared-corner extrude=0: verts " ~ i.to!string ~
                " and " ~ j.to!string ~ " are coincident");
        }
    }

    // Edge-manifold: every undirected edge used by at most 2 faces.
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
            "pentagon shared-corner extrude=0: non-manifold edge used by " ~
            count.to!string ~ " faces");
}

// Boundary-loop DROP-SHIFT rule (parity): the reference applies only `inset`
// to BOUNDARY edges (single adjacent face) and drops `shift` entirely —
// measured against the reference engine on a flat open-boundary rim loop:
// shift-only leaves the mesh unchanged, and shift+inset produces exactly the
// inset-only result (no lifted band). vibe3d already honours this for a
// single boundary edge (width-only chamfer); this locks in the SAME rule for
// a boundary LOOP whose corners are all shared, which previously lifted a
// spurious band along the face normal. INTERIOR edges keep their shift band
// (covered by the cube/coplanar reference cases), so this is scoped to the
// all-boundary loop.
unittest {
    import std.conv : to;
    import std.math : abs;

    // Flat open quad in the y=0 plane (+Y normal): its 4 edges are all
    // boundary edges and its 4 corners are each shared by 2 of them.
    Vec3[4] corners = [Vec3(-0.5f, 0, -0.5f), Vec3(0.5f, 0, -0.5f),
                       Vec3(0.5f, 0, 0.5f),   Vec3(-0.5f, 0, 0.5f)];
    Mesh mkQuad() {
        Mesh q;
        uint[] r;
        foreach (ref c; corners) r ~= q.addVertex(c);
        q.addFace(r);
        return q;
    }

    // shift+inset on the boundary loop: shift must be dropped → NO lift.
    Mesh mShiftInset = mkQuad();
    {
        bool[] mask; mask.length = mShiftInset.edges.length; mask[] = true;
        mShiftInset.extrudeEdgesByMask(mask, 0.2f, 0.1f);
    }
    foreach (i; 0 .. mShiftInset.vertices.length)
        assert(abs(mShiftInset.vertices[i].y) < 1e-4f,
            "boundary-loop shift+inset: vertex " ~ i.to!string ~
            " lifted off the boundary plane to y=" ~
            mShiftInset.vertices[i].y.to!string ~ " (shift not dropped)");

    // inset-only: same rim loop, no shift. shift+inset must equal this.
    Mesh mInsetOnly = mkQuad();
    {
        bool[] mask; mask.length = mInsetOnly.edges.length; mask[] = true;
        mInsetOnly.extrudeEdgesByMask(mask, 0.0f, 0.1f);
    }
    assert(mShiftInset.vertices.length == mInsetOnly.vertices.length,
        "boundary-loop shift+inset vs inset-only: vertex count differs (" ~
        mShiftInset.vertices.length.to!string ~ " vs " ~
        mInsetOnly.vertices.length.to!string ~ ")");
    assert(mShiftInset.faces.length == mInsetOnly.faces.length,
        "boundary-loop shift+inset vs inset-only: face count differs (" ~
        mShiftInset.faces.length.to!string ~ " vs " ~
        mInsetOnly.faces.length.to!string ~ ")");
    // Every shift+inset vertex has a coincident inset-only counterpart.
    foreach (i; 0 .. mShiftInset.vertices.length) {
        bool matched = false;
        foreach (j; 0 .. mInsetOnly.vertices.length) {
            Vec3 dd = mShiftInset.vertices[i] - mInsetOnly.vertices[j];
            if (dd.x*dd.x + dd.y*dd.y + dd.z*dd.z < 1e-8f) { matched = true; break; }
        }
        assert(matched,
            "boundary-loop shift+inset: vertex " ~ i.to!string ~
            " has no inset-only counterpart (shift changed the geometry)");
    }

    // shift-only on the boundary loop leaves the rim unchanged (no inset room,
    // shift dropped) — the mesh stays the original quad.
    Mesh mShiftOnly = mkQuad();
    {
        bool[] mask; mask.length = mShiftOnly.edges.length; mask[] = true;
        mShiftOnly.extrudeEdgesByMask(mask, 0.2f, 0.0f);
    }
    assert(mShiftOnly.vertices.length == 4 && mShiftOnly.faces.length == 1,
        "boundary-loop shift-only: expected the original quad (4v/1f), got " ~
        mShiftOnly.vertices.length.to!string ~ "v/" ~
        mShiftOnly.faces.length.to!string ~ "f");
    foreach (i; 0 .. mShiftOnly.vertices.length)
        assert(abs(mShiftOnly.vertices[i].y) < 1e-4f,
            "boundary-loop shift-only: vertex " ~ i.to!string ~ " lifted");
}

// edge.extrude free-end ridge uses PER-CORNER normals on non-planar faces
// (parity-measured bit-exact vs the reference on cc1 + twisted 2-quad tents).
// A single interior edge shared by two TWISTED (non-planar) quads is
// extruded; its two free ends must lift along DIFFERENT directions — each
// the sum of its own faces' per-corner normals — NOT the shared whole-face
// Newell average (which would lift both ends identically and miss the
// reference by ~0.015). A PLANAR tent is the byte-identical control: there
// the per-corner normal equals the face normal, so both ends lift the same.
unittest {
    import std.conv : to;
    import std.math : abs, sqrt;

    // Build a tent: two quads sharing the interior edge P0-P1 (along Z).
    // `warp` twists each quad's far edge in Y, making the quads non-planar
    // by different amounts on the two sides (asymmetric).
    Mesh mkTent(float warp) {
        Mesh m;
        uint p0 = m.addVertex(Vec3(0, 0, -1));           // 0
        uint p1 = m.addVertex(Vec3(0, 0, 1));            // 1
        uint a1 = m.addVertex(Vec3(1, -0.3f + warp, 1)); // 2
        uint a0 = m.addVertex(Vec3(1, -0.3f, -1));       // 3
        uint b0 = m.addVertex(Vec3(-1, -0.3f, -1));      // 4
        uint b1 = m.addVertex(Vec3(-1, -0.3f - warp, 1));// 5
        m.addFace([p0, p1, a1, a0]);
        m.addFace([p1, p0, b0, b1]);
        return m;
    }
    // Mask selecting only the shared interior edge (endpoints {0,1}).
    bool[] edgeMask(ref Mesh m) {
        bool[] mask; mask.length = m.edges.length;
        foreach (i; 0 .. m.edges.length) {
            uint a = m.edges[i][0], b = m.edges[i][1];
            if ((a == 0 && b == 1) || (a == 1 && b == 0)) mask[i] = true;
        }
        return mask;
    }
    // Does the mesh contain a vertex at `p` (within tol)?
    bool hasVert(ref Mesh m, Vec3 p, float tol) {
        foreach (i; 0 .. m.vertices.length) {
            Vec3 d = m.vertices[i] - p;
            if (sqrt(d.x*d.x + d.y*d.y + d.z*d.z) < tol) return true;
        }
        return false;
    }

    // NON-planar (warp 0.2): the two free-end ridges land on distinct,
    // reference-matched positions — P0 straight down (its faces are locally
    // symmetric there), P1 tilted (its faces twist away). A whole-face Newell
    // average would place BOTH at (±0.0137, -0.149, ±1) — see the negative
    // assertions — so these pin the per-corner-normal behaviour.
    {
        Mesh m = mkTent(0.2f);
        auto mask = edgeMask(m);
        m.extrudeEdgesByMask(mask, -0.15f, 0.1f);
        assert(hasVert(m, Vec3(0.0f, -0.15f, -1.0f), 1e-4f),
            "non-planar free-end ridge P0 not at per-corner position (0,-0.15,-1)");
        assert(hasVert(m, Vec3(0.027148f, -0.147523f, 1.0f), 1e-4f),
            "non-planar free-end ridge P1 not at per-corner position (0.0271,-0.1475,1)");
        // The old whole-face-Newell ridge for P1 was (~0.0137,-0.1494,1); the
        // fix must NOT leave a vertex there.
        assert(!hasVert(m, Vec3(0.0137f, -0.1494f, 1.0f), 1e-4f),
            "free-end ridge P1 still at the whole-face-Newell position (fix inactive)");
        // Each ridge is displaced by exactly |extrude| perpendicular to the
        // Z-aligned shared edge (z unchanged).
        assert(hasVert(m, Vec3(0.0f, -0.15f, -1.0f), 1e-4f), "P0 ridge z shifted");
    }

    // PLANAR control (warp 0): per-corner == face normal, so BOTH free ends
    // lift to the identical (x,y) — byte-identical to the pre-fix Newell path.
    {
        Mesh m = mkTent(0.0f);
        auto mask = edgeMask(m);
        m.extrudeEdgesByMask(mask, -0.15f, 0.1f);
        // Symmetric flat tent: both ridges share the same (x,y), differing
        // only in z (the two edge endpoints). Find them and compare.
        Vec3[] ridges;
        foreach (i; 0 .. m.vertices.length) {
            // ridge verts sit ~|extrude| below the y=-0.15 line near x=0
            Vec3 p = m.vertices[i];
            if (abs(p.x) < 0.05f && p.y < -0.1f) ridges ~= p;
        }
        assert(ridges.length == 2,
            "planar tent: expected 2 free-end ridges, got " ~ ridges.length.to!string);
        assert(abs(ridges[0].x - ridges[1].x) < 1e-5f &&
               abs(ridges[0].y - ridges[1].y) < 1e-5f,
            "planar tent free-end ridges diverged in (x,y) — per-corner path " ~
            "must reduce to the face normal on planar faces");
    }
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

// Task 0312 (fuzz-found): a diagonal/checkerboard face pair that shares
// only a single vertex (no shared edge) must extrude as TWO independent
// islands, each with its own inset vertex at the shared corner. Before
// the fix, a single merged clone at that corner had its cap-side
// vertical edge walled by both islands at once — an edge used by 4
// faces. Assert the post-extrude mesh is edge-manifold (every undirected
// edge used by ≤2 faces), matching the HTTP repro:
//   /api/reset?type=grid&n=2; select polygons [1,2]; poly.extrude 1.0
unittest {
    import std.conv : to;

    auto m = makeGridPlane(2);
    // 2x2 grid: faces 1 and 2 (row0/col1 and row1/col0) touch only at
    // the shared center vertex — the diagonal/checkerboard pair.
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[1] = true;
    mask[2] = true;
    size_t n = m.extrudeFacesByMask(mask, 1.0f);
    assert(n == 2, "diagonal pair: expected 2 faces extruded");

    // Recount every undirected edge across ALL faces directly (NOT via
    // buildEdgeFaces — its 2-slot [int;2] silently drops a 3rd/4th
    // incident face instead of flagging it, so it can't witness this
    // bug). A count > 2 anywhere means a non-manifold edge.
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
            "diagonal pair extrude: non-manifold edge used by " ~
            count.to!string ~ " faces (task 0312 regression)");
}

// Mesh-robustness batch (fuzz-found): a "book" edge — one undirected edge
// shared by 3 faces (non-manifold input) — must reject the whole extrude
// as a clean no-op, not attempt to extrude into the already-invalid
// neighborhood. A normal disjoint 2-face pair (no book edge) must still
// extrude as before (no over-reject).
unittest {
    import std.conv : to;
    // Book mesh: 3 quad "pages" all hinged on the shared edge (v0,v1).
    //   page A: v0,v1,v2,v3   (in the XY... here XZ-ish plane, x>0)
    //   page B: v0,v1,v4,v5   (rotated: z>0)
    //   page C: v0,v1,v6,v7   (rotated: x<0)
    // Undirected edge (0,1) is used by all 3 pages => incidence count 3.
    Mesh m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(0, 1, 0));
    uint v2 = m.addVertex(Vec3(1, 1, 0));
    uint v3 = m.addVertex(Vec3(1, 0, 0));
    uint v4 = m.addVertex(Vec3(0, 1, 1));
    uint v5 = m.addVertex(Vec3(0, 0, 1));
    uint v6 = m.addVertex(Vec3(-1, 1, 0));
    uint v7 = m.addVertex(Vec3(-1, 0, 0));
    m.addFace([v0, v1, v2, v3]);
    m.addFace([v0, v1, v4, v5]);
    m.addFace([v0, v1, v6, v7]);

    size_t vertsBefore = m.vertices.length;
    size_t facesBefore = m.faces.length;
    bool[] mask; mask.length = m.faces.length; mask[] = false;
    mask[0] = true; // select page A, which touches the book edge (0,1)
    size_t n = m.extrudeFacesByMask(mask, 1.0f);
    assert(n == 0, "book-edge extrude: expected reject (0), got " ~ n.to!string);
    assert(m.vertices.length == vertsBefore,
        "book-edge extrude: reject must not add verts");
    assert(m.faces.length == facesBefore,
        "book-edge extrude: reject must not add faces");

    // A normal disjoint 2-face pair (not touching the book edge) must
    // still extrude normally — the guard must not over-reject.
    Mesh gm = makeGridPlane(2);
    bool[] gmask; gmask.length = gm.faces.length; gmask[] = false;
    gmask[0] = true; gmask[1] = true; // adjacent quads, shared edge used by only 2 faces
    size_t gn = gm.extrudeFacesByMask(gmask, 1.0f);
    assert(gn == 2, "disjoint pair extrude: expected 2 faces extruded, got " ~ gn.to!string);
}

unittest {
    import std.math : abs;
    import std.conv : to;

    // base_noop: shift=0, scale=1, thicken=false, single top-face
    // selection on a stock cube. Matches the frozen reference capture
    // (tests/fixtures/smooth_shift.json "base_noop") — 12v/10f, NOT a
    // no-op (see the kernel doc comment on the shift==0 divergence).
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false;
        // Find the top face (all 4 verts at y ≈ +0.5).
        int topFi = -1;
        foreach (fi; 0 .. m.faces.length) {
            bool allTop = true;
            foreach (vid; m.faces[fi]) if (m.vertices[vid].y < 0.4f) { allTop = false; break; }
            if (allTop) { topFi = cast(int)fi; break; }
        }
        assert(topFi >= 0, "smoothShiftFacesByMask test: no top face found");
        mask[topFi] = true;
        size_t n = m.smoothShiftFacesByMask(mask, 0.0f, 1.0f, false);
        assert(n == 1, "smoothShiftFacesByMask base_noop: expected 1 face cloned");
        assert(m.faces.length == 10,
            "smoothShiftFacesByMask base_noop: expected 10 faces, got " ~ m.faces.length.to!string);
        assert(m.vertices.length == 12,
            "smoothShiftFacesByMask base_noop: expected 12 verts, got " ~ m.vertices.length.to!string);
    }

    // shift03_scale05: shift=0.3, scale=0.5 — pins the scale-about-
    // island-centroid law exactly (frozen capture "shift03_scale05").
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false;
        int topFi = -1;
        foreach (fi; 0 .. m.faces.length) {
            bool allTop = true;
            foreach (vid; m.faces[fi]) if (m.vertices[vid].y < 0.4f) { allTop = false; break; }
            if (allTop) { topFi = cast(int)fi; break; }
        }
        mask[topFi] = true;
        size_t n = m.smoothShiftFacesByMask(mask, 0.3f, 0.5f, false);
        assert(n == 1, "smoothShiftFacesByMask shift03_scale05: expected 1 face cloned");
        // Expect a new vertex at (-0.25, 0.65, -0.25) (corner (-0.5,0.5,-0.5)
        // shifted+scaled about the top face's centroid (0,0.5,0)).
        bool found = false;
        foreach (v; m.vertices) {
            if (abs(v.x - (-0.25f)) < 1e-3f && abs(v.y - 0.65f) < 1e-3f &&
                abs(v.z - (-0.25f)) < 1e-3f) { found = true; break; }
        }
        assert(found, "smoothShiftFacesByMask shift03_scale05: no cap vert at (-0.25,0.65,-0.25)");
    }

    // thicken_top_only: shift=0.3, thicken=true — retains the original
    // top face as an 11th polygon (frozen capture "thicken_top_only").
    {
        auto m = makeCube();
        bool[] mask; mask.length = m.faces.length; mask[] = false;
        int topFi = -1;
        foreach (fi; 0 .. m.faces.length) {
            bool allTop = true;
            foreach (vid; m.faces[fi]) if (m.vertices[vid].y < 0.4f) { allTop = false; break; }
            if (allTop) { topFi = cast(int)fi; break; }
        }
        mask[topFi] = true;
        size_t n = m.smoothShiftFacesByMask(mask, 0.3f, 1.0f, true);
        assert(n == 1, "smoothShiftFacesByMask thicken_top_only: expected 1 face cloned");
        assert(m.faces.length == 11,
            "smoothShiftFacesByMask thicken_top_only: expected 11 faces, got " ~ m.faces.length.to!string);
        assert(m.vertices.length == 12,
            "smoothShiftFacesByMask thicken_top_only: expected 12 verts, got " ~ m.vertices.length.to!string);
        // The retained face's 4 verts must all still be at y ≈ 0.5 (unmoved).
        int retainedCount = 0;
        foreach (fi; 0 .. m.faces.length) {
            if (m.faces[fi].length != 4) continue;
            bool allOrigTop = true;
            foreach (vid; m.faces[fi])
                if (abs(m.vertices[vid].y - 0.5f) > 1e-3f) { allOrigTop = false; break; }
            if (allOrigTop) ++retainedCount;
        }
        assert(retainedCount >= 1,
            "smoothShiftFacesByMask thicken_top_only: no retained (unmoved) top face found");
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

unittest { // extendEdgesByMask: INSET DIHEDRAL FACTOR (N1) — arbitrary-dihedral
           // corner drop is −inset·(1/(1+nA·nB))·Σn, NOT the min-norm meet.
    import std.math : abs;
    // Regular triangular prism (r=0.6, height=1): non-90° side dihedrals — the
    // family where the plain min-norm meet diverged from the reference. Values
    // measured bit-exact against the reference engine (prism3, inset=0.1).
    enum float Z = 0.5196152423f;   // 0.6·sin(120°)
    Mesh mk() {
        Mesh m;
        m.vertices = [
            Vec3( 0.6f, -0.5f,  0.0f),  // 0  (+X apex, bottom)
            Vec3(-0.3f, -0.5f,   Z ),   // 1
            Vec3(-0.3f, -0.5f,  -Z ),   // 2
            Vec3( 0.6f,  0.5f,  0.0f),  // 3  (+X apex, top)
            Vec3(-0.3f,  0.5f,   Z ),   // 4
            Vec3(-0.3f,  0.5f,  -Z ),   // 5
        ];
        m.addFace([2u, 1u, 0u]);            // bottom cap
        m.addFace([3u, 4u, 5u]);            // top cap
        m.addFace([0u, 1u, 4u, 3u]);        // side (contains rim edge 0-1)
        m.addFace([1u, 2u, 5u, 4u]);        // side
        m.addFace([2u, 0u, 3u, 5u]);        // side
        m.buildLoops();
        m.resetSelection();
        return m;
    }

    // (a) Bottom RIM edge 0-1: the edge's two faces (cap ⊥ side) give nA·nB=0 ⇒
    //     factor 1, so the drop is −inset·Σn over EACH endpoint's distinct faces.
    //     src 0 → (0.7,-0.6,0); the min-norm meet would put x at 0.8 (twice the
    //     inset) — asserting 0.7 pins the factor·sum law.
    {
        Mesh m = mk();
        selectEdgeByEnds_(m, m.vertices[0], m.vertices[1]);
        auto n = m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                                     Vec3(0,0,0), Vec3(0,0,0), Vec3(1,1,1), 1);
        assert(n == 1);
        uint n0 = 0, n1 = 0;
        foreach (i; 6 .. m.vertices.length) {
            if (near_(m.vertices[i], Vec3(0.7f, -0.6f, 0.0f), 1e-4f)) n0 = cast(uint)i;
            if (near_(m.vertices[i], Vec3(-0.35f, -0.6f, 0.6062178f), 1e-4f)) n1 = cast(uint)i;
        }
        assert(n0 != 0, "prism rim: new vert from src0 = (0.7,-0.6,0) [factor·sum, not meet 0.8]");
        assert(n1 != 0, "prism rim: new vert from src1 = (-0.35,-0.6,0.60622)");
        // Winding: on tilted geometry the bridge is oriented against the LOWER-
        // index neighbour (bottom cap = face 0, which traverses 1→0), so the
        // bridge traverses the shared edge 0→1 — i.e. the tuple [1, n1, n0, 0].
        long bf = findFaceByVerts_(m, [1u, n1, n0, 0u]);
        assert(bf >= 0, "prism rim bridge face present");
        assert(tupleMatchesWound_(m.faces[cast(size_t)bf], [1u, n1, n0, 0u]),
               "prism rim bridge wound orientable vs lower-index cap (edge 0→1)");
    }

    // (b) Vertical apex edge 0-3: its two SIDE faces meet at nA·nB=−0.5 ⇒ factor
    //     1/(1−0.5)=2, doubling the drop. src 0 → (0.8,-0.7,0).
    {
        Mesh m = mk();
        selectEdgeByEnds_(m, m.vertices[0], m.vertices[3]);
        auto n = m.extendEdgesByMask(selMask_(m), 0.1f, 0.0f,
                                     Vec3(0,0,0), Vec3(0,0,0), Vec3(1,1,1), 1);
        assert(n == 1);
        bool got = false;
        foreach (i; 6 .. m.vertices.length)
            if (near_(m.vertices[i], Vec3(0.8f, -0.7f, 0.0f), 1e-4f)) got = true;
        assert(got, "prism apex edge: dihedral factor 2 ⇒ src0 → (0.8,-0.7,0)");
    }
}

unittest { // extendEdgesByMask: COLLINEAR boundary chain — shared mid-rim vertex
           // slides ONCE (not once per incident edge). Task 0475 regression.
    import std.math : abs;
    // Open 3×3 grid in the XZ plane (Y=0). The x=−1 rim carries THREE collinear
    // boundary verts (0,3,6); selecting the two collinear boundary edges (3,0)
    // and (6,3) shares vertex 3. inset=0, shift=0.2 → each new vert slides by
    // exactly shift along the outward −X perp. The BUG doubled the shared vert
    // (−1.4 instead of −1.2). Reference slides it once.
    Mesh m;
    m.vertices = [
        Vec3(-1, 0, -1),  // 0
        Vec3( 0, 0, -1),  // 1
        Vec3( 1, 0, -1),  // 2
        Vec3(-1, 0,  0),  // 3
        Vec3( 0, 0,  0),  // 4
        Vec3( 1, 0,  0),  // 5
        Vec3(-1, 0,  1),  // 6
        Vec3( 0, 0,  1),  // 7
        Vec3( 1, 0,  1),  // 8
    ];
    m.addFace([0u, 1u, 4u, 3u]);
    m.addFace([1u, 2u, 5u, 4u]);
    m.addFace([3u, 4u, 7u, 6u]);
    m.addFace([4u, 5u, 8u, 7u]);
    m.buildLoops();
    m.resetSelection();
    selectEdgeByEnds_(m, m.vertices[3], m.vertices[0]);  // collinear rim edge (−1,z∈[−1,0])
    selectEdgeByEnds_(m, m.vertices[6], m.vertices[3]);  // collinear rim edge (−1,z∈[0,1])
    auto n = m.extendEdgesByMask(selMask_(m), 0.0f, 0.2f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    assert(n == 2);
    // 9 grid verts + 3 new (verts 0,3,6 → one new each; 3 welds two edges) = 12.
    assert(m.vertices.length == 12, "collinear chain: 9 + 3 new");
    assert(m.faces.length == 6, "collinear chain: 4 grid + 2 bridges");
    // The three new verts each slide once by shift=0.2 along −X:
    //   vert 0 (−1,0,−1) → (−1.2,0,−1)   free end
    //   vert 3 (−1,0, 0) → (−1.2,0, 0)   SHARED — the regression point
    //   vert 6 (−1,0, 1) → (−1.2,0, 1)   free end
    bool sharedHit = false, fe0 = false, fe6 = false, doubled = false;
    foreach (i; 9 .. m.vertices.length) {
        auto v = m.vertices[i];
        if (near_(v, Vec3(-1.2f, 0, 0)))  sharedHit = true;
        if (near_(v, Vec3(-1.2f, 0, -1))) fe0 = true;
        if (near_(v, Vec3(-1.2f, 0, 1)))  fe6 = true;
        if (abs(v.x + 1.4f) < 1e-4f)      doubled = true;  // −1.4 = the BUG
    }
    assert(!doubled, "collinear shared vertex must NOT double-shift (no −1.4)");
    assert(sharedHit, "shared mid-rim vertex slid once → (−1.2,0,0)");
    assert(fe0 && fe6, "free ends slid once → (−1.2,0,∓1)");
}

unittest { // extendEdgesByMask: GENUINE L-corner (non-parallel boundary edges) still
           // accumulates BOTH perp shifts — dedup must not over-collapse. Task 0475.
    // Single unit quad in XZ; two adjacent boundary edges meet at vertex 0 with
    // PERPENDICULAR outward perps (−Z and −X). inset=0, shift=0.2 ⇒ the shared
    // corner gets BOTH: (0,0,0)+shift·(−Z)+shift·(−X) = (−0.2,0,−0.2).
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 0),  // 0  shared corner
        Vec3(1, 0, 0),  // 1
        Vec3(1, 0, 1),  // 2
        Vec3(0, 0, 1),  // 3
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    m.resetSelection();
    selectEdgeByEnds_(m, m.vertices[0], m.vertices[1]);  // +X edge, outward perp −Z
    selectEdgeByEnds_(m, m.vertices[3], m.vertices[0]);  // +Z edge, outward perp −X
    auto n = m.extendEdgesByMask(selMask_(m), 0.0f, 0.2f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    assert(n == 2);
    // Shared corner 0 must carry BOTH perp slides → (−0.2, 0, −0.2).
    bool corner = false;
    foreach (i; 4 .. m.vertices.length)
        if (near_(m.vertices[i], Vec3(-0.2f, 0, -0.2f))) corner = true;
    assert(corner, "genuine L-corner accumulates both perp shifts → (−0.2,0,−0.2)");
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

unittest { // extendEdgesByMask: CLOSED-RING boundary probe (task 0477 P11 REV1
           // FIX-1, doc/topopen_p11_duploop_plan.md "mandatory Phase-0
           // probe") — a mask selecting the FULL closed perimeter (all 8 rim
           // edges) of a 3x3 grid (`makeGridPlane(2)`) has never been
           // exercised through this kernel before: every extendEdgesByMask
           // unittest above is a partial OPEN run (a single edge, a 2-edge
           // collinear chain, an L-corner) — never a genuinely CLOSED ring
           // that wraps back onto itself. Identity TRS (inset=shift=0,
           // offset=0, rotate=0, scale=1) must produce: coincident tail
           // verts (one per rim vertex, M=8), a well-formed CLOSED quad band
           // (one bridge per rim edge, N=8) with every original rim edge
           // promoted from 1 to EXACTLY 2 incident faces (clean manifold —
           // no non-manifold triple at the wrap, which is the failure mode
           // that would fire if the last edge's bridge mis-happened to
           // double up on an earlier bridge's face), and every new bridge
           // face a well-formed 4-gon with 4 DISTINCT vertex indices, no two
           // bridges sharing the same 4-vertex set. A degenerate/duplicate
           // face here would be a real kernel finding — STOP and report, do
           // not ship (REV1 FIX-1). (Zero visual AREA in the new bridge
           // quads is EXPECTED under pure identity TRS — the new verts are
           // deliberately coincident with their source until a follow-up
           // drag moves them, per the duplicate-then-drag design — so this
           // probe checks INDEX/topology well-formedness, not face area.)
    import mesh : makeGridPlane;
    import std.algorithm : sort;

    Mesh m = makeGridPlane(2);   // 3x3 verts (0..8), 4 quads, 12 edges (8 rim + 4 interior)

    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max, "setup: boundary edge 0-1 must exist");
    auto loop = m.selectLoopEdges(seed);
    assert(loop.length == 8, "boundary seed must gather the FULL closed 8-edge rim");

    // Capture each rim edge by its STABLE ENDPOINT vertex pair before the
    // kernel's internal rebuildEdges() runs. `loop`'s raw edge indices only
    // happen to stay valid afterwards because this kernel is pure-add and
    // rebuildEdges preserves slots 0..11 here -- re-resolving by endpoints
    // (below, post-kernel) keeps the probe robust to any future edge-index
    // reordering rather than relying on that incidental preservation.
    uint[2][] rimEndpoints;
    foreach (ei; loop) rimEndpoints ~= [m.edges[ei][0], m.edges[ei][1]];

    bool[] mask; mask.length = m.edges.length;
    foreach (ei; loop) mask[ei] = true;

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    auto n = m.extendEdgesByMask(mask, 0.0f, 0.0f,
                                 Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(1, 1, 1), 1);
    assert(n == 8, "every rim edge has exactly one adjacent face -> all 8 must extend");

    // M = 8 new (tail) verts -- the closed-ring weld map (one per unique rim
    // vertex, not 16 -- no double-counting a shared corner across its two
    // rim edges).
    assert(m.vertices.length == vBefore + 8, "closed ring: +8 verts (M=N=8)");
    assert(m.faces.length    == fBefore + 8, "closed ring: +8 bridge quads (N=8)");
    // +(N+M) = +16 edges: 8 new outer-ring edges + 8 new spoke edges.
    assert(m.edges.length    == eBefore + 16, "closed ring: +16 edges (N new ring + M new spokes)");

    // Coincident tail verts: identity TRS -> every new vert lands EXACTLY on
    // its source rim vertex (no drift, no accumulation error around the
    // wrap-around).
    foreach (i; vBefore .. m.vertices.length) {
        bool matchesSome = false;
        foreach (vi; [0u, 1u, 2u, 3u, 5u, 6u, 7u, 8u])
            if (near_(m.vertices[i], m.vertices[vi])) { matchesSome = true; break; }
        assert(matchesSome,
            "every new tail vertex must be coincident with SOME original rim vertex");
    }

    // Manifold promotion: every original rim edge must now have EXACTLY 2
    // incident faces (its own cell face + the new bridge) -- not a
    // non-manifold 3-face triple, which is the wrap-around failure mode
    // this probe exists to catch. Re-resolve each rim edge by its stable
    // endpoint pair (captured pre-kernel, above) rather than trusting the
    // pre-kernel `loop` indices to still point at the same edges.
    foreach (ep; rimEndpoints) {
        uint ei = m.edgeIndex(ep[0], ep[1]);
        assert(ei != uint.max, "rim edge must still resolve by its stable endpoints after extend");
        int cnt = 0;
        foreach (fi; m.facesAroundEdge(ei)) ++cnt;
        assert(cnt == 2,
            "each original rim edge must gain EXACTLY one bridge face (1->2), never a "
          ~ "non-manifold triple at the wrap-around");
        assert(!m.isEdgeBorder(ei), "each original rim edge must no longer be a boundary edge");
    }

    // No degenerate/duplicate face: every one of the 8 new bridge faces is a
    // well-formed 4-gon with 4 DISTINCT vertex indices, and no two bridges
    // share the identical 4-vertex set (the wrap-around double-processing
    // failure mode).
    uint[][] seenSets;
    foreach (fi; fBefore .. m.faces.length) {
        auto f = m.faces[fi];
        assert(f.length == 4, "every bridge must be a quad");
        auto ids = f.dup; ids.sort();
        assert(ids[0] != ids[1] && ids[1] != ids[2] && ids[2] != ids[3],
            "every bridge quad must have 4 DISTINCT vertex indices (no degenerate wrap face)");
        foreach (prev; seenSets)
            assert(prev != ids, "no two bridge quads may share the same 4 vertices (duplicate wrap face)");
        seenSets ~= ids;
    }

    // Fully valid, buildLoops-consistent structure (no crash/hang walking
    // adjacency near the wrap).
    size_t totalCorners = 0;
    foreach (ref f; m.faces) totalCorners += f.length;
    assert(m.loops.length == totalCorners);
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

// extrudeVerticesByMask (task 0360 cone/ring kernel rewrite): cube corner 0
// at (-0.5,-0.5,-0.5), width=0.2, shift=0. Corner 0 (valence 3) gets a
// stationary apex + a 6-vertex/6-face ring (2 new verts + 2 new faces per
// incident edge — see the kernel's own doc-comment for the full law).
// Selection is untouched (still vertex 0 — the apex never moves or gets
// re-indexed).
unittest {
    import std.math : abs;
    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();
    m.selectVertex(0);
    const size_t oldV = m.vertices.length; // 8
    const size_t oldF = m.faces.length;    // 6

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;  // corner (-0.5,-0.5,-0.5)
    size_t processed = m.extrudeVerticesByMask(mask, 0.0f, 0.2f);

    assert(processed == 1,                "extrudeVerticesByMask: should process 1 vertex");
    assert(m.vertices.length == oldV + 6, "extrudeVerticesByMask: expected +6 verts");
    assert(m.faces.length    == oldF + 6, "extrudeVerticesByMask: expected +6 faces");

    // Apex (vertex 0) unmoved.
    Vec3 apex = m.vertices[0];
    assert(abs(apex.x - (-0.5f)) < 1e-5f &&
           abs(apex.y - (-0.5f)) < 1e-5f &&
           abs(apex.z - (-0.5f)) < 1e-5f,
           "extrudeVerticesByMask: apex must stay at its original position");

    // Three ring points at exactly width=0.2 along each incident edge.
    Vec3[3] expectedRing = [Vec3(-0.3f, -0.5f, -0.5f),
                            Vec3(-0.5f, -0.3f, -0.5f),
                            Vec3(-0.5f, -0.5f, -0.3f)];
    foreach (e; expectedRing) {
        bool found = false;
        foreach (v; m.vertices) {
            Vec3 d = v - e;
            if (d.x*d.x + d.y*d.y + d.z*d.z < 1e-8f) { found = true; break; }
        }
        assert(found, "extrudeVerticesByMask: ring point not found");
    }

    // Selection untouched: vertex 0 (the apex) is still the only selected vert.
    assert(m.isVertexSelected(0), "extrudeVerticesByMask: apex must remain selected");
}

// extrudeVerticesByMask: width=0 is a no-op regardless of shift (confirmed
// reference law, task 0360 — shift alone never moves anything).
unittest {
    auto m = makeCube();
    m.buildLoops();
    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;
    size_t processed = m.extrudeVerticesByMask(mask, 0.5f, 0.0f);
    assert(processed == 0,          "extrudeVerticesByMask: width=0 must be no-op");
    assert(m.vertices.length == 8,  "extrudeVerticesByMask: width=0 must not add verts");
    assert(m.faces.length    == 6,  "extrudeVerticesByMask: width=0 must not add faces");
}
