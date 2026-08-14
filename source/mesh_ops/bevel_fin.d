module mesh_ops.bevel_fin;

// ---------------------------------------------------------------------------
// MeshBevelFinOps — the two NON-MANIFOLD fin-bundle spine kernels
// (`bevelIsolatedFinBundleSpine`, `bevelFinBundleSpineMultiEdge`), mixed into
// struct Mesh (source/mesh.d) via `mixin MeshBevelFinOps;`.
//
// Split out of source/mesh_ops/edge_bevel.d (task 0717, audit 0678 §2B-M2 step B).
// They are a separate family from the manifold edge bevel that calls them:
// `bevelEdgesByMask` detects the fin-bundle shape and hands the whole edit
// over (the call sites are its only two early returns of that kind), and
// nothing else in the family shares a line with them. Bodies are a verbatim
// cut/paste — a member introduced by one mixin template is visible, with no
// qualification, to another mixin template mixed into the same struct (the
// property mesh_ops/loop_slice.d documents), so the two call sites in
// bevelEdgesByMask are untouched.
// ---------------------------------------------------------------------------
mixin template MeshBevelFinOps() {
    /// Bevel ONE non-manifold "spine" edge shared by N≥3 incident faces, for the
    /// single measured topology: an ISOLATED fin bundle (task 0438). Both spine
    /// endpoints must touch NOTHING but the N incident fins — a spine embedded in
    /// a larger mesh (an endpoint carrying any other face) is refused. Reference
    /// law, captured bit-exact for N=3 and N=4 (`edge_bevel_0438_{A3face,B4face}_*`):
    ///   * each fin is inset in place — its two spine corners (a, b) are each
    ///     replaced by a rail point `p + width·û_perp`, where û_perp is the
    ///     in-plane direction at that corner perpendicular to the spine, toward
    ///     the fin's interior (the identical per-face formula ordinary two-face
    ///     edges use); the fin keeps its arity and its winding.
    ///   * exactly one new N-gon cap is added at EACH spine end, fanning that
    ///     end's N rail points in incident-face order. BOTH caps use the same
    ///     order, so their winding is emergent-consistent with the reference's.
    /// `sharp` is not a parameter here and Round Level does not round this cap —
    /// both measured inert, so this takes neither. Returns 1 on success, or 0
    /// (leaving the mesh byte-identical) when the isolated-bundle precondition
    /// fails — honoring `bevelEdgesByMask`'s "return 0 ⇒ no-op" contract, so all
    /// precondition checks run BEFORE the first mutation.
    size_t bevelIsolatedFinBundleSpine(uint spineEdge, float width) {
        if (spineEdge >= edges.length) return 0;
        immutable uint a = edges[spineEdge][0];
        immutable uint b = edges[spineEdge][1];
        if (a == b) return 0;

        // Incident fins in FACE-INDEX order (reproduces the reference's incident-
        // polygon fan order; the winding check is rotation-invariant so the
        // starting offset is immaterial). Scanning faces directly is non-
        // manifold-safe, unlike a fan walk around a non-manifold vertex.
        uint[] fins;
        foreach (fi; 0 .. cast(uint)faces.length) {
            auto f = faces[fi];
            immutable L = f.length;
            foreach (k; 0 .. L) {
                immutable uint u = f[k], w = f[(k + 1) % L];
                if ((u == a && w == b) || (u == b && w == a)) { fins ~= fi; break; }
            }
        }
        immutable size_t N = fins.length;
        if (N < 3) return 0;

        // Isolated-bundle precondition: neither endpoint may touch any face that
        // is NOT one of the N fins. Every fin already contains both a and b, so
        // "incident-face count == N" at each endpoint is exactly that condition.
        size_t facesWith(uint v) {
            size_t c = 0;
            foreach (f; faces) foreach (vv; f) if (vv == v) { ++c; break; }
            return c;
        }
        if (facesWith(a) != N || facesWith(b) != N) return 0;

        // --- Phase A: compute everything, mutate nothing (no-op contract). ---
        Vec3 railPos(uint p, uint q, uint nbr, out bool ok) {
            immutable Vec3 P = vertices[p];
            Vec3 uu = vertices[q] - P;
            immutable float ul = uu.length;
            if (ul > 1e-12f) uu = uu / ul;
            immutable Vec3 e = vertices[nbr] - P;
            immutable Vec3 perp = e - uu * dot(e, uu);
            immutable float pl = perp.length;
            if (pl < 1e-9f) { ok = false; return P; }
            ok = true;
            return P + perp / pl * width;
        }
        Vec3[] railAPos; railAPos.reserve(N);
        Vec3[] railBPos; railBPos.reserve(N);
        auto finPa = new int[](N);
        auto finPb = new int[](N);
        foreach (idx, fi; fins) {
            auto f = faces[fi];
            immutable L = f.length;
            int pa = -1, pb = -1;
            foreach (k; 0 .. L) { if (f[k] == a) pa = cast(int)k; if (f[k] == b) pb = cast(int)k; }
            if (pa < 0 || pb < 0) return 0;
            immutable uint aOther = (f[(pa + 1) % L] == b) ? f[(pa + L - 1) % L] : f[(pa + 1) % L];
            immutable uint bOther = (f[(pb + 1) % L] == a) ? f[(pb + L - 1) % L] : f[(pb + 1) % L];
            bool okA, okB;
            immutable Vec3 ra = railPos(a, b, aOther, okA);
            immutable Vec3 rb = railPos(b, a, bOther, okB);
            if (!okA || !okB) return 0;
            railAPos ~= ra; railBPos ~= rb;
            finPa[idx] = pa; finPb[idx] = pb;
        }

        // --- Phase B: mutate. Add rails, rewrite each fin in place, add caps. ---
        uint[] railA; railA.reserve(N);
        uint[] railB; railB.reserve(N);
        foreach (idx, fi; fins) {
            immutable uint ia = addVertex(railAPos[idx]);
            immutable uint ib = addVertex(railBPos[idx]);
            railA ~= ia; railB ~= ib;
            uint[] nf = faces[fi].dup;
            nf[finPa[idx]] = ia;
            nf[finPb[idx]] = ib;
            faces[fi] = nf;
        }
        // One N-gon fan cap per spine end, both in incident-face order.
        immutable uint capA = cast(uint)faces.length; addFace(railA);
        immutable uint capB = cast(uint)faces.length; addFace(railB);

        // The original spine verts a, b are now unreferenced; the tail
        // compaction drops them (net: −2 spine verts, +2N rails; +2 cap faces).
        syncSelection();
        clearFaceSelection();
        foreach (fi; fins) selectFace(cast(int)fi);
        selectFace(cast(int)capA);
        selectFace(cast(int)capB);
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();
        finalizeTopologyEdit();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return 1;
    }

    /// Bevel an isolated fin-bundle spine (edge shared by N≥3 fins whose two
    /// endpoints touch NOTHING but those fins) together with a set of "extra"
    /// selected edges — the measured law for a multi-edge selection *through* the
    /// non-manifold spine (parity task, fuzz divergence D2). Generalizes the
    /// single-spine `bevelIsolatedFinBundleSpine`; each extra edge must be a
    /// fin's OUTER boundary edge (a rim edge, one incident face = a fin) that is
    /// incident to a spine endpoint. Captured bit-exact for N=3 across a
    /// rectangular AND a skewed fin (the skew disambiguates the corner law from
    /// the rectangle's 90° degeneracy).
    ///
    /// Per fin, at each spine endpoint p (outer neighbour W = p's fin neighbour
    /// that is not the other spine endpoint):
    ///   * If the outer edge (p, W) is NOT selected: p's spine corner insets to
    ///     the spine rail `p + width·û_perp` exactly as the single-spine case.
    ///     The cap at that end fans this rail.
    ///   * If (p, W) IS selected: p's corner becomes a MITER — the intersection
    ///     of the spine-chamfer inset line and the (p, W)-chamfer inset line
    ///     (both in the fin plane, each offset `width` from its edge). The cap
    ///     fans this miter. The far endpoint W is corner-cut into TWO vertices:
    ///     a perpendicular inset of the fin's NEXT edge (W, Wnext) at W, and a
    ///     slide along (W, Wnext) by `width`; so the fin gains one ring vertex
    ///     per extra edge.
    /// One N-gon fan cap is added at EACH spine end (incident-face order, same
    /// winding convention as the single-spine sibling).
    ///
    /// Returns the number of selected edges consumed (spine + extras) on success,
    /// or 0 (mesh byte-identical) when any precondition fails — every check runs
    /// BEFORE the first mutation, honouring `bevelEdgesByMask`'s no-op contract.
    /// Anything past the measured shape refuses: >1 spine, an extra that is not a
    /// fin's rim edge at a spine endpoint, an extra whose far vertex is the other
    /// spine endpoint, a fin carrying extras at BOTH ends (their corner-cuts can
    /// collide on a quad), or a degenerate miter / perpendicular.
    size_t bevelFinBundleSpineMultiEdge(uint spineEdge, const uint[] extraEdges, float width) {
        if (spineEdge >= edges.length) return 0;
        immutable uint a = edges[spineEdge][0];
        immutable uint b = edges[spineEdge][1];
        if (a == b) return 0;

        // Incident fins in FACE-INDEX order (scan faces directly — non-manifold-
        // safe, unlike a fan walk around a non-manifold vertex; see the single-
        // spine sibling).
        uint[] fins;
        foreach (fi; 0 .. cast(uint)faces.length) {
            auto f = faces[fi];
            immutable L = f.length;
            foreach (k; 0 .. L) {
                immutable uint u = f[k], w = f[(k + 1) % L];
                if ((u == a && w == b) || (u == b && w == a)) { fins ~= fi; break; }
            }
        }
        immutable size_t N = fins.length;
        if (N < 3) return 0;

        // Isolated-bundle precondition (identical to the single-spine sibling):
        // neither endpoint may touch any face that is not one of the N fins.
        size_t facesWith(uint v) {
            size_t c = 0;
            foreach (f; faces) foreach (vv; f) if (vv == v) { ++c; break; }
            return c;
        }
        if (facesWith(a) != N || facesWith(b) != N) return 0;

        int finPos(uint fi) { foreach (idx, ff; fins) if (ff == fi) return cast(int)idx; return -1; }

        // Classify each extra edge → (fin, spine endpoint slot, far vertex W).
        // extraFar[finIdx][0] = W for an extra at `a`, [1] = W for an extra at
        // `b`; ~0u = none. Reject anything outside the measured shape here,
        // before any mutation.
        auto extraFar = new uint[2][](N);
        foreach (ref e; extraFar) { e[0] = ~0u; e[1] = ~0u; }
        foreach (ee; extraEdges) {
            if (ee >= edges.length) return 0;
            immutable uint u = edges[ee][0], v = edges[ee][1];
            uint incFace = ~0u; size_t incCount = 0;
            foreach (fi; 0 .. cast(uint)faces.length) {
                auto f = faces[fi]; immutable L = f.length;
                foreach (k; 0 .. L) {
                    immutable uint x = f[k], y = f[(k + 1) % L];
                    if ((x == u && y == v) || (x == v && y == u)) { incFace = fi; ++incCount; break; }
                }
            }
            if (incCount != 1) return 0;             // not a rim edge
            immutable int fp = finPos(incFace);
            if (fp < 0) return 0;                     // rim edge not on a fin
            uint p, W;
            if (u == a || u == b) { p = u; W = v; }
            else if (v == a || v == b) { p = v; W = u; }
            else return 0;                            // extra not at a spine endpoint
            if (W == a || W == b) return 0;           // far vertex is the other spine endpoint
            immutable int slot = (p == a) ? 0 : 1;
            if (extraFar[fp][slot] != ~0u) return 0;  // two extras same fin+endpoint
            extraFar[fp][slot] = W;
        }
        foreach (fp; 0 .. N)
            if (extraFar[fp][0] != ~0u && extraFar[fp][1] != ~0u) return 0; // extras both ends

        // --- Phase A: compute everything, mutate nothing (no-op contract). ---
        // p slid `width` along the in-plane perpendicular to edge (p→q), toward
        // `nbr` (the identical rail idiom the single-spine path and two-face
        // edges use).
        Vec3 railFrom(uint p, uint q, uint nbr, out bool ok) {
            immutable Vec3 P = vertices[p];
            Vec3 uu = vertices[q] - P;
            immutable float ul = uu.length;
            if (ul > 1e-12f) uu = uu / ul;
            immutable Vec3 e = vertices[nbr] - P;
            immutable Vec3 perp = e - uu * dot(e, uu);
            immutable float pl = perp.length;
            if (pl < 1e-9f) { ok = false; return P; }
            ok = true;
            return P + perp / pl * width;
        }
        // Miter at spine endpoint p (outer neighbour W): intersection of the
        // spine-chamfer inset line (through the spine rail, along the spine) and
        // the (p,W)-chamfer inset line (through (p,W)'s inset rail, along (p,W)).
        Vec3 miterAt(uint p, uint other, uint W, out bool ok) {
            bool o1, o2;
            immutable Vec3 R  = railFrom(p, other, W, o1);   // on the spine inset line
            immutable Vec3 Rp = railFrom(p, W, other, o2);   // on the (p,W) inset line
            if (!o1 || !o2) { ok = false; return vertices[p]; }
            immutable Vec3 dS = safeNormalize(vertices[other] - vertices[p]);
            immutable Vec3 dO = safeNormalize(vertices[W] - vertices[p]);
            immutable Vec3 nrm = cross(dS, dO);
            immutable float nn = dot(nrm, nrm);
            if (nn < 1e-12f) { ok = false; return vertices[p]; }  // parallel ⇒ degenerate
            immutable Vec3 r = Rp - R;
            immutable float s = dot(cross(r, dO), nrm) / nn;
            ok = true;
            return R + dS * s;
        }

        // Per-fin plan: new-vertex positions + a ring template (≥0 ⇒ existing
        // vertex index, <0 ⇒ −(local+1) into `np`), plus which local slot is the
        // a-end / b-end cap point.
        struct FinPlan { Vec3[] np; int[] ring; int aCapL; int bCapL; }
        FinPlan[] plans; plans.reserve(N);

        foreach (fp, fi; fins) {
            auto f = faces[fi]; immutable L = f.length;
            int ia = -1, ib = -1;
            foreach (k; 0 .. L) { if (f[k] == a) ia = cast(int)k; if (f[k] == b) ib = cast(int)k; }
            if (ia < 0 || ib < 0) return 0;
            immutable uint aN = (f[(ia + 1) % L] == b) ? f[(ia + L - 1) % L] : f[(ia + 1) % L];
            immutable uint bN = (f[(ib + 1) % L] == a) ? f[(ib + L - 1) % L] : f[(ib + 1) % L];
            immutable uint aFar = extraFar[fp][0];
            immutable uint bFar = extraFar[fp][1];

            bool ok;
            Vec3 aCornerPos = (aFar != ~0u) ? miterAt(a, b, aN, ok) : railFrom(a, b, aN, ok);
            if (!ok) return 0;
            Vec3 bCornerPos = (bFar != ~0u) ? miterAt(b, a, bN, ok) : railFrom(b, a, bN, ok);
            if (!ok) return 0;

            FinPlan pl; pl.aCapL = -1; pl.bCapL = -1;
            foreach (k; 0 .. L) {
                immutable uint v = f[k];
                if (v == a) {
                    pl.np ~= aCornerPos; pl.aCapL = cast(int)(pl.np.length - 1);
                    pl.ring ~= -(cast(int)pl.np.length);
                } else if (v == b) {
                    pl.np ~= bCornerPos; pl.bCapL = cast(int)(pl.np.length - 1);
                    pl.ring ~= -(cast(int)pl.np.length);
                } else if (aFar != ~0u && v == aN) {
                    // Corner-cut aN (far end of the extra edge at `a`).
                    immutable bool fwd = (f[(k + 1) % L] != a);   // walk goes a → aN → Wnext
                    immutable uint Wnext = fwd ? f[(k + 1) % L] : f[(k + L - 1) % L];
                    if (Wnext == a || Wnext == b) return 0;
                    bool okp;
                    immutable Vec3 Vperp = railFrom(aN, Wnext, a, okp);        // perp inset of (aN,Wnext)
                    if (!okp) return 0;
                    immutable Vec3 Valong = vertices[aN] + safeNormalize(vertices[Wnext] - vertices[aN]) * width;
                    if (fwd) { pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length);
                               pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length); }
                    else     { pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length);
                               pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length); }
                } else if (bFar != ~0u && v == bN) {
                    immutable bool fwd = (f[(k + 1) % L] != b);   // walk goes b → bN → Wnext
                    immutable uint Wnext = fwd ? f[(k + 1) % L] : f[(k + L - 1) % L];
                    if (Wnext == a || Wnext == b) return 0;
                    bool okp;
                    immutable Vec3 Vperp = railFrom(bN, Wnext, b, okp);
                    if (!okp) return 0;
                    immutable Vec3 Valong = vertices[bN] + safeNormalize(vertices[Wnext] - vertices[bN]) * width;
                    if (fwd) { pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length);
                               pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length); }
                    else     { pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length);
                               pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length); }
                } else {
                    pl.ring ~= cast(int)v;
                }
            }
            if (pl.aCapL < 0 || pl.bCapL < 0) return 0;
            plans ~= pl;
        }

        // --- Phase B: mutate. Add rails/miters/cuts, rewrite fins, add caps. ---
        uint[] aCapG; aCapG.reserve(N);
        uint[] bCapG; bCapG.reserve(N);
        foreach (fp, fi; fins) {
            auto pl = plans[fp];
            uint[] gnew; gnew.reserve(pl.np.length);
            foreach (p; pl.np) gnew ~= addVertex(p);
            uint[] nf; nf.reserve(pl.ring.length);
            foreach (r; pl.ring) nf ~= (r >= 0) ? cast(uint)r : gnew[-(r) - 1];
            faces[fi] = nf;
            aCapG ~= gnew[pl.aCapL];
            bCapG ~= gnew[pl.bCapL];
        }
        // One N-gon fan cap per spine end, both in incident-face order (matching
        // the single-spine sibling's emergent-consistent winding).
        immutable uint capA = cast(uint)faces.length; addFace(aCapG);
        immutable uint capB = cast(uint)faces.length; addFace(bCapG);

        // The original spine verts a, b (and any corner-cut'd outer verts) are
        // now unreferenced; the tail compaction drops them.
        syncSelection();
        clearFaceSelection();
        foreach (fi; fins) selectFace(cast(int)fi);
        selectFace(cast(int)capA);
        selectFace(cast(int)capB);
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();
        finalizeTopologyEdit();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return 1 + extraEdges.length;
    }
}
