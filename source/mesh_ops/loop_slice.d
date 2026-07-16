module mesh_ops.loop_slice;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshLoopSliceOps — Loop Slice ring-walk + insertion kernel family
// (loopSliceRingEdges / collectEdgeRing / insertEdgeLoops / insertEdgeLoopsMulti,
// plus the private ring-walk/rail helpers they alone use: EdgeRingEntry,
// ngonExitEdge, curvatureSplinePoint, railContinuation, walkRingSide), mixed
// into struct Mesh (source/mesh.d) via `mixin MeshLoopSliceOps;`. Also carries
// `capShellCycles` (the shared Cap Sections boundary-loop geometry), relocated
// here from its own separate spot in mesh.d since Loop Slice is its primary
// owner — cut.d's `splitAlongCutLoop` (mesh_ops/cut.d) still calls it bare,
// unqualified, from a DIFFERENT mixin template; this is safe (empirically
// confirmed: a member introduced by one mixin template is visible, with no
// qualification, to another mixin template mixed into the same struct — both
// ultimately resolve through struct Mesh's own member scope).
//
// Split out of mesh.d as part of the mesh.d decomposition campaign (0407
// §B.V2, task 0417 — continuation of the task-0412 plane-cut pilot and the
// task-0417 bridge-family extraction earlier in this same task; see
// task 0412's doc for the architectural decision: mixin template over a
// package move or UFCS free-functions). Method bodies below are verbatim
// cut/paste from mesh.d (only the extraction boundary is new).
// ---------------------------------------------------------------------------
mixin template MeshLoopSliceOps() {
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
        // N-gon traversal (task 0250 "Slice N-gon"). For a QUAD `ngon` is false
        // and (a,b,c,d) fully describe the split (byte-for-byte unchanged path).
        // For a non-quad face the ring is allowed to CROSS under the `ngon`
        // option: (a,b,c,d) then hold the entry/exit DARTS but the face has more
        // than 4 corners, so the split needs the whole face — `entryJ`/`exitJ`
        // are the local CCW edge indices (edge k = face[k]→face[(k+1)%N]) of the
        // entry and exit edges, and `ngon` marks the face for the general
        // polygon split (`emitNgonRingSplit`). Unused (`-1`/`false`) for quads.
        int  entryJ = -1, exitJ = -1;
        bool ngon = false;
        // Task 0398: true for every entry collected on the SECOND walk
        // (`collectEdgeRing`'s `sideB`) of an OPEN ring. The seed edge has
        // opposite darts in its two incident faces (a manifold invariant), so
        // side B's local (a,b)/(d,c) rail senses run consistently OPPOSITE to
        // side A's for the whole of side B's chain — a FRESHLY created rail
        // there would land at `1-t` instead of `t` relative to side A's
        // convention. `getMids` uses this flag to mirror a fresh rail's
        // interpolation fraction (`1-t`) so side B's rails land in side A's
        // convention instead of the reversed one, fixing the one-vertex
        // off-plane bug without touching face winding (a shared/cached rail
        // ignores this flag — its position was already fixed by whichever
        // request created it first). Always false for a CLOSED ring
        // (`walkRingSide` returns via `closedA` before side B ever runs) and
        // for a single-sided (boundary-seed) ring (side B is never walked).
        bool mirror = false;
    }

    /// Exit-edge rule for a loop slice crossing an N-sided face (task 0250).
    /// The ring enters via local edge `entryJ` (edge k = face[k]→face[k+1]) and
    /// leaves via the edge "most opposite" to it: `entryJ + N/2` (mod N). For an
    /// even N this is the diametrically opposite edge; for an odd N it is one of
    /// the two edges flanking the far vertex (deterministic floor choice). The
    /// chord from the entry-edge midpoint to the exit-edge midpoint continues
    /// the loop across the face. Only ever consulted for N >= 5 (triangles never
    /// traverse — see `walkRingSide`).
    private static int ngonExitEdge(uint n, int entryJ) {
        return cast(int)((cast(uint)entryJ + n / 2) % n);
    }

    /// Preserve-Curvature spline point (task 0254; curve LIVE-corrected task 0263).
    /// Places a new loop vertex on the segment `p1→p2` at parameter `t`, curved to
    /// follow the surrounding cage via a NON-UNIFORM (chord-weighted) Catmull-Rom
    /// spline through the four points `p0, p1, p2, p3` (`p0`/`p3` = the cage
    /// vertices continuing the rail past `p1`/`p2`). The return blends the spline
    /// against the plain chord by `tension`:
    ///   `result = lerp(p1,p2,t) + tension · (catmullRom − lerp)`
    /// so `tension = 1` is the full spline, `tension = 0` is exactly the linear
    /// chord (byte-for-byte the non-curvature path), and intermediate / >1 /
    /// negative values scale the bulge (the hook task 0255 "Tension" drives). When
    /// `p0,p1,p2,p3` are collinear the spline coincides with the chord for every
    /// `tension`, so a flat cage is unaffected.
    ///
    /// Tangents (task 0263): the reference does NOT use the classic uniform scale
    /// `½(p2−p0)`. Live capture of the reference Preserve Curvature (headless
    /// command-port arm + interactive commit — see toolcards/mesh.loopSlice/capture)
    /// pins each endpoint's tangent to the uniform Catmull-Rom secant RESCALED by
    /// the fraction the CUT edge length `|p1p2|` contributes to that endpoint's two
    /// incident cage-edge lengths:
    ///   `m1 = (p2−p0) · |p1p2|/(|p0p1|+|p1p2|)`,  `m2 = (p3−p1) · |p1p2|/(|p2p3|+|p1p2|)`.
    /// (The classic `½` is the special case of three equal-length cage edges.)
    /// Verified bit-exact on two discriminating cages: heights [0,1,1,0] give
    /// y = 1 + (√2−1)/4 = 1.1035534 (uniform gave 1.125); heights [0,2,2,0] give
    /// y = 2.1545086 (uniform gave 2.25). A collinear (flat) cage still yields the
    /// chord for every tension.
    private static Vec3 curvatureSplinePoint(Vec3 p0, Vec3 p1, Vec3 p2, Vec3 p3,
                                             float t, float tension) {
        Vec3  lin = p1 + (p2 - p1) * t;
        if (tension == 0.0f) return lin;               // exact linear (no float drift)
        float L01 = (p1 - p0).length();
        float L12 = (p2 - p1).length();
        float L23 = (p3 - p2).length();
        float w1  = (L01 + L12) > 1e-8f ? L12 / (L01 + L12) : 0.5f;
        float w2  = (L23 + L12) > 1e-8f ? L12 / (L23 + L12) : 0.5f;
        Vec3  m1  = (p2 - p0) * w1;                    // chord-weighted tangent at p1
        Vec3  m2  = (p3 - p1) * w2;                    // chord-weighted tangent at p2
        float t2  = t * t, t3 = t2 * t;
        Vec3  crom = p1 * (2.0f*t3 - 3.0f*t2 + 1.0f)
                   + m1 * (t3 - 2.0f*t2 + t)
                   + p2 * (-2.0f*t3 + 3.0f*t2)
                   + m2 * (t3 - t2);
        return lin + (crom - lin) * tension;
    }

    /// The cage vertex position that continues the rail edge past `pivot`, on the
    /// side AWAY from `other` — the Catmull-Rom end control point for Preserve
    /// Curvature (task 0254). Among `pivot`'s edge-neighbours (excluding `other`),
    /// picks the one whose direction from `pivot` best continues the rail direction
    /// (`pivot` moving away from `other`). When no forward-ish neighbour exists
    /// (a boundary or a sharp corner — nothing continues the rail), returns the
    /// reflection `2·pivot − other`; that choice makes the Catmull-Rom tangent at
    /// that end equal the chord, so the spline degrades gracefully to linear where
    /// the surface simply stops (and to exactly linear when BOTH ends reflect).
    private Vec3 railContinuation(uint pivot, uint other) const {
        Vec3  dir  = normalize(vertices[pivot] - vertices[other]);
        float best = 0.0f;                 // require a genuinely forward neighbour
        uint  bestV = uint.max;
        foreach (nb; verticesAroundVertex(pivot)) {
            if (nb == other) continue;
            Vec3  d  = normalize(vertices[nb] - vertices[pivot]);
            float al = dot(d, dir);
            if (al > best) { best = al; bestV = nb; }
        }
        if (bestV != uint.max) return vertices[bestV];
        return vertices[pivot] * 2.0f - vertices[other];   // reflect ⇒ linear tangent
    }

    /// Walk one side of the ring from startFace, following the exit edge of each
    /// quad until: the exit key equals seedKey (closed — sets closed=true), a
    /// boundary is hit, the face is not a quad, or a face is revisited.
    /// Does NOT include the initial seed edge itself in the entries.
    ///
    /// `ngon` (task 0250 "Slice N-gon"): when true the ring is allowed to CROSS
    /// a non-quad face with MORE than 4 sides (N >= 5) instead of terminating at
    /// it — it enters via the current edge and leaves via `ngonExitEdge` (the
    /// opposite edge), recording an `ngon`-flagged entry that `splitFace` then
    /// slices with `emitNgonRingSplit`. Triangles (N < 4) still ALWAYS stop the
    /// ring (a tri has no clean opposite edge). With `ngon` false (default) the
    /// walk is byte-for-byte the original quad-only walk (any non-quad stops it).
    /// The seed face itself must still be a quad (guaranteed by `collectEdgeRing`).
    private EdgeRingEntry[] walkRingSide(uint seedEdge, uint startFace,
                                         out bool closed, bool ngon = false) const {
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
            uint N = cast(uint)f.length;

            uint exitEi;
            ulong exitKey;
            if (N == 4) {
                // Quad — the original record (byte-for-byte). Exit = opposite edge.
                uint a = f[curJ],       b = f[(curJ+1)%4],
                     c = f[(curJ+2)%4], d = f[(curJ+3)%4];
                result ~= EdgeRingEntry(a, b, c, d, curFi);
                vis[curFi] = true;
                exitEi = edgeIndex(c, d);
                if (exitEi == ~0u) break;                   // no exit edge
                exitKey = edgeKeyOf(exitEi);
            } else {
                // N-gon crossing (only reached under `ngon`, and only for N >= 5
                // — the step below never advances the walk onto a triangle). Exit
                // = ngonExitEdge(N, entryJ); record the full-face split intent.
                int exitJ = ngonExitEdge(N, curJ);
                uint a = f[curJ],  b = f[(curJ + 1) % N],
                     c = f[exitJ], d = f[(exitJ + 1) % N];
                auto ent = EdgeRingEntry(a, b, c, d, curFi);
                ent.entryJ = curJ;
                ent.exitJ  = exitJ;
                ent.ngon   = true;
                result ~= ent;
                vis[curFi] = true;
                exitEi = edgeIndex(c, d);
                if (exitEi == ~0u) break;
                exitKey = edgeKeyOf(exitEi);
            }

            if (exitKey == seedKey) { closed = true; break; } // closed ring

            int nf = adjacentFaceThrough(exitEi, curFi);
            if (nf < 0) break;                              // open boundary
            uint nN = cast(uint)faces[nf].length;
            // Advance only onto a quad, or (under `ngon`) an N >= 5 face.
            // A triangle always stops the ring, `ngon` or not.
            if (!(nN == 4 || (ngon && nN > 4))) break;

            int j2 = findEdgeInFace(cast(uint)nf, exitKey);
            if (j2 < 0) break;

            curFi = cast(uint)nf;
            curJ  = j2;
        }
        return result;
    }

    /// The set of EXISTING cage-edge indices a loop-slice at `seedEdge` would
    /// split: the seed edge itself plus every quad-ring exit rail crossed by
    /// `collectEdgeRing`. This is the ring the cut actually lands on — it runs
    /// PERPENDICULAR to the classic edge LOOP (`edgeLoopRing`), so a hover
    /// preview for the Loop Slice tool must use THIS, not the edge loop, or the
    /// highlighted ring won't match where the cut appears. Returns just
    /// `[seedEdge]` on a non-quad / boundary seed (no ring); empty is never
    /// returned for a valid seed index.
    int[] loopSliceRingEdges(uint seedEdge) const {
        if (seedEdge >= edges.length) return [];
        bool closed;
        auto ring = collectEdgeRing(seedEdge, closed);
        int[] res = [cast(int)seedEdge];
        foreach (ent; ring) {
            uint ei = edgeIndex(ent.c, ent.d);
            if (ei != ~0u) res ~= cast(int)ei;
        }
        return res;
    }

    /// Collect the ordered quad ring crossed by a loop insert at seedEdge.
    /// Each entry carries the ring-edge direction (p-rail a→b, q-rail d→c)
    /// and face index.  closed==true when the ring wraps (e.g. a cube belt).
    /// Returns an empty slice if no quad face is incident on seedEdge.
    /// `ngon` (task 0250): forwarded to `walkRingSide` so the ring may CROSS
    /// non-quad (N >= 5) faces mid-walk instead of terminating at them. The SEED
    /// edge's own two incident faces must still be quads either way (the seed
    /// receives its p-rail from a quad frame); only faces reached DURING the walk
    /// are traversed. `ngon` false (default) is the unchanged quad-only ring.
    EdgeRingEntry[] collectEdgeRing(uint seedEdge, out bool closed,
                                    bool ngon = false) const {
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
        auto sideA = walkRingSide(seedEdge, incFaces[0], closedA, ngon);
        if (closedA) { closed = true; return sideA; }  // one pass hit closure

        if (nFaces == 1) return sideA;                 // boundary edge, open

        bool closedB;
        auto sideB = walkRingSide(seedEdge, incFaces[1], closedB, ngon);
        // Task 0398: side B's rail senses run opposite to side A's (the seed
        // edge carries opposite darts in its two incident faces) — mark every
        // side-B entry so `getMids` mirrors a FRESH rail's fraction and lands
        // it in side A's convention (see `EdgeRingEntry.mirror`).
        foreach (ref e; sideB) e.mirror = true;
        return sideA ~ sideB;
    }

    /// Insert `positions.length` parallel edge loops at parametric offsets
    /// along the quad ring crossing seedEdge.  Positions must be in (0,1);
    /// the call is a no-op (returns false) if the ring is empty or positions
    /// is empty.  Rebuilds edges + half-edge loops; clears all selection.
    /// Thin forwarder over the 3-arg overload below — existing callers that
    /// don't need the created-face indices are unaffected.
    bool insertEdgeLoops(uint seedEdge, const(float)[] positions) {
        uint[] unused;
        return insertEdgeLoops(seedEdge, positions, unused);
    }

    /// Same as the 2-arg `insertEdgeLoops`, but also reports the indices of
    /// every sub-quad face this call created (e.g. for a Select-New-Polygons
    /// affordance). `newFaceIndices` is cleared and repopulated; left empty
    /// on a no-op (false return). Does NOT select the faces itself — the
    /// caller decides whether/how to apply the returned indices to the
    /// selection (`resetSelection()` below always clears it first).
    ///
    /// Thin forwarder over `insertEdgeLoopsMulti([seedEdge], positions, ...)`
    /// (task 0239 M1) — single-seed callers (`mesh.addLoop`/`mesh.loopSlice`,
    /// the interactive tool's single-ring path) are unaffected: with exactly
    /// one seed, `insertEdgeLoopsMulti` never enters its dedup or grid-split
    /// branches, so this produces byte-identical geometry to the pre-0239
    /// implementation (guarded by the existing unittests just below, which
    /// assert exact V/E/F/vertex-position/newFaceIndices shape and are
    /// unchanged by this refactor).
    bool insertEdgeLoops(uint seedEdge, const(float)[] positions,
                          out uint[] newFaceIndices) {
        return insertEdgeLoopsMulti([seedEdge], positions, newFaceIndices);
    }

    /// Insert `positions.length` parallel edge loops on the DISTINCT quad
    /// rings crossed by each seed in `seeds`, in ONE topology-rebuild pass
    /// (task 0239 M1 — the Loop Slice v2 multi-seed backend). Positions must
    /// be in (0,1). Returns false (no mutation) if `seeds`/`positions` is
    /// empty or every seed's ring collect is empty.
    ///
    /// — Rings are collected from the ORIGINAL (unmutated) mesh, one
    ///   `collectEdgeRing` per seed; a seed whose ring is empty (non-quad /
    ///   boundary-adjacent / invalid index) is silently skipped — it never
    ///   blocks the OTHER seeds' rings from being cut.
    /// — DEDUP by canonical ring identity (the sorted set of face indices the
    ///   ring's walk touches): two selected edges that land on the SAME ring
    ///   contribute only ONE cut, never a doubled one — this is what keeps
    ///   "Count loops per DISTINCT ring" true under an over-selected edge set
    ///   (task 0239 owner-decision D1 / risk 2).
    /// — A face crossed by exactly ONE distinct ring gets the ORIGINAL
    ///   single-ring split (P+1 sub-quads, lifted unchanged from the pre-
    ///   0239 body). A face crossed by TWO PERPENDICULAR distinct rings gets
    ///   a GRID split: (P+1)×(P+1) sub-quads, with the 4 boundary rails
    ///   rail-shared (same `railByKey` cache the single-ring path uses — so
    ///   a grid face's boundary midpoints are the SAME vertices its 1-ring
    ///   neighbours reference) and the interior grid vertices bilinearly
    ///   interpolated from the face's 4 original corners at each
    ///   `(positions[i], positions[j])`.
    ///
    ///   The grid's bilerp is PROVABLY equal to applying the two rings'
    ///   single-ring inserts SEQUENTIALLY (ring A first, then ring B on the
    ///   already-cut mesh): expanding the sequential construction's second
    ///   cut — which linearly interpolates between the untouched opposite
    ///   rail and the FIRST cut's new rail-vertex-to-rail-vertex segment —
    ///   algebraically collapses to the exact 4-corner bilinear weights
    ///   `(1-u)(1-v)·A + u(1-v)·B + u·v·C + (1-u)·v·D` this function computes
    ///   directly. (Verified in the M1 grid-equivalence unittest below by
    ///   literally comparing this function's output mesh, position-for-
    ///   position, against a two-call sequential `insertEdgeLoops` run.)
    ///
    ///   A THIRD distinct ring touching the same face is defensively
    ///   SKIPPED for that face (not expected on a well-formed quad mesh — any
    ///   single quad has only 2 independent ring directions — but degenerate
    ///   topology should degrade gracefully rather than corrupt geometry).
    ///   Likewise, if a 2nd ring's entry edge doesn't align with either of
    ///   the base ring's two OTHER sides (should be topologically
    ///   impossible for two truly distinct rings on a manifold quad face —
    ///   see the orientation-reconciliation comment inline), the face falls
    ///   back to a single-ring split on the first ring only.
    ///
    /// `restrictFaces` (optional) — when non-null, the cut is RESTRICTED to
    ///   only the faces in this set: a ring face NOT listed is left uncut, so
    ///   the inserted loop spans only the run of listed faces crossed by each
    ///   ring rather than the whole ring around the mesh. To keep the result
    ///   watertight the boundary rails (where a listed, split face meets an
    ///   unlisted, uncut neighbour) are still midpoint-split, and the unlisted
    ///   neighbour ABSORBS those midpoints into its own boundary (becoming an
    ///   n-gon) — the "respecting corners" termination at the selection edge.
    ///   Passing `null` (the default) removes the restriction (whole ring). The
    ///   absorb happens through the SAME two-pass branch as the default open-ring
    ///   path (`twoPass`, below); a CLOSED belt ring with no restriction takes the
    ///   byte-for-byte single-pass path instead. `newFaceIndices` still reports only the sub-quads the
    ///   slice CREATED (the absorbed n-gon neighbours are modified originals,
    ///   not new, so they are excluded — matching the Select-New-Polygons law).
    ///
    /// `keepQuads` (optional, default false) — the Loop Slice "Keep Quads"
    ///   guard. As of the watertight-by-default change this is a GEOMETRIC
    ///   NO-OP and is retained only for panel/attribute parity. The behaviour it
    ///   used to gate — ABSORBING the terminating midpoint at a non-quad boundary
    ///   into that neighbour (turning it into an n-gon) so the cut stays watertight
    ///   AND every newly created sub-face is a quad — now happens BY DEFAULT for
    ///   every open (terminating) ring, because the reference's default keeps the
    ///   cut watertight there (Keep Quads on == off on every capturable mesh). The
    ///   quad ring already propagates ONLY through quads and terminates at any
    ///   non-quad face (`collectEdgeRing`/`walkRingSide`), so every sub-face the
    ///   slice CREATES is a quad regardless of this flag. Passing `keepQuads=true`
    ///   therefore produces geometry IDENTICAL to `keepQuads=false`; the absorb
    ///   machinery it once triggered is now the default open-ring path (see
    ///   `twoPass`). `newFaceIndices` still reports only the created sub-quads (an
    ///   absorbed non-quad neighbour is a modified original, excluded).
    ///
    /// `ngon` (optional, default false) — the Loop Slice "Slice N-gon" guard
    ///   (task 0250). Off (default) the ring terminates at ANY non-quad face
    ///   (`collectEdgeRing`/`walkRingSide` stop there), byte-for-byte unchanged.
    ///   On, the ring is allowed to CONTINUE THROUGH a non-quad face with more
    ///   than four sides (N >= 5): it enters via its current edge, leaves via the
    ///   opposite edge (`ngonExitEdge`), and the n-gon is sliced by the chord
    ///   between the two edge midpoints (`emitNgonRingSplit`) — so the cut spans
    ///   the n-gon and reaches the faces beyond. Triangles still stop the ring
    ///   (no clean opposite edge). The n-gon's two rail midpoints are shared with
    ///   its ring neighbours through the SAME rail cache, so the crossing is
    ///   watertight WITHOUT needing the absorb pass. The chord split leaves the
    ///   two n-gon sub-faces as whatever arity the side chains dictate (a quad
    ///   plus an (N-1)-gon for a single cut) — matching a plain "slice n-gon"
    ///   (NOT a quad-only decomposition). Composes with `keepQuads`: when both
    ///   are on the n-gon is still TRAVERSED (it is a ring face, so it is split,
    ///   never absorbed), and `keepQuads` continues to absorb the terminating
    ///   midpoint at any REMAINING non-quad border the ring still stops at (e.g.
    ///   a triangle). Forcing the n-gon's OWN sub-faces to be all-quad — the
    ///   deeper "keep quads inside a sliced n-gon" facet — is an unknowable
    ///   reference heuristic (closed source, not headlessly capturable) and is
    ///   deliberately NOT attempted here; see the task notes. Composes with
    ///   `restrictFaces` orthogonally (which rings/faces are cut vs which faces
    ///   the ring is allowed to traverse are independent axes).
    /// `split` (optional, default false) — the Loop Slice "Split" guard (task
    ///   0251). Off (default) the inserted loop is a SINGLE connected edge loop:
    ///   the midpoint verts on each rail are SHARED between the sub-face on the
    ///   "toward-first-corner" side of the loop and the one on the
    ///   "toward-second-corner" side, so the surface stays watertight across the
    ///   cut (byte-for-byte unchanged). On, each rail midpoint is DUPLICATED into
    ///   two coincident verts — a "lo" copy (toward the rail's first/`va` corner,
    ///   == the original connected vert) used by every sub-face on that side of
    ///   the loop, and a fresh "hi" copy (toward the `vb` corner) used by every
    ///   sub-face on the other side. Because the lo copies stay shared around the
    ///   ring (and the hi copies likewise), the one connected loop becomes TWO
    ///   distinct boundary edge-loops overlapping in space, and the two sides of
    ///   the cut are topologically DISCONNECTED along it (each shared interior
    ///   loop edge becomes two separate boundary edges). This is the foundation
    ///   for Cap Sections (fill each boundary) + Gap (push the two loops apart).
    ///   The split is applied to the single-ring split (`emitSingleRingSplit`)
    ///   and the n-gon crossing (`emitNgonRingSplit`); the rare two-ring GRID
    ///   split and the two-pass ABSORB neighbour (select/quad) attach to the lo
    ///   (connected) side, so split composes with select/quad/ngon without
    ///   special-casing (the absorbed neighbour stays joined to the lo loop; the
    ///   hi loop is a free boundary). On an all-quad mesh with `split` off the
    ///   output is byte-identical to before.
    ///
    /// `caps` (optional, default false) — the Loop Slice "Cap Sections" guard
    ///   (task 0252; geometry corrected by LIVE reference capture, task 0261).
    ///   Only meaningful when `split` is on (a no-op otherwise). When on, each
    ///   section opened by Split is SEALED with a SINGLE cap polygon that fills that
    ///   section's OWN boundary loop, in the loop's own plane — NOT a strip of quads
    ///   bridging the lo loop to the hi loop. Both split shells are capped
    ///   independently: the lo (`midsVa`) shell's boundary loop becomes one cap
    ///   face, the hi (`midsVb`) shell's boundary loop another. Each shell's
    ///   boundary is the cycle of face-incidence-1 edges whose two ends are both in
    ///   that shell's midpoint set; the cycle is emitted REVERSED (opposing the
    ///   shell's side faces) so it seals. This closes each boundary loop
    ///   (boundary-edge count drops to 0) yet leaves the two shells DISCONNECTED
    ///   (two independent closed solids), so a `gap` opens a REAL visible band
    ///   between them (bridging quads would fill it coplanar with the side faces —
    ///   an invisible cut, the pre-0261 bug). The cap faces add NO new vertices and
    ///   NO new edges (every cap edge is an existing shell boundary edge); they are
    ///   appended to `newFaceIndices` (new polys, so Select-New selects them).
    ///   `split` off (or no rail duplicated) ⇒ no caps, byte-for-byte.
    ///
    /// `splitPairsOut` (optional) — when non-null AND `split` is on, receives one
    ///   `[loVert, hiVert]` pair per duplicated rail midpoint: `loVert` sits on
    ///   the lo boundary loop, `hiVert` its coincident duplicate on the hi loop.
    ///   This is the seam data Cap Sections (0252) / Gap (0253) consume: Gap moves
    ///   each pair's two verts apart along the rail direction; Cap (built in-kernel
    ///   via `caps`) reads the pairs to identify each shell's boundary-loop vert set
    ///   (lo vs hi) so it fills each loop with one cap. Empty when `split` is off or
    ///   no rail was duplicated.
    ///
    /// `gap` (task 0253, distance) — only meaningful when `split` is on. `0` (the
    ///   default) keeps every `[lo, hi]` seam pair COINCIDENT, so the geometry is
    ///   byte-for-byte the 0251/0252 result. Non-zero OPENS a gap of the given
    ///   width between the two split boundary loops: each seam pair's two verts are
    ///   pushed apart along the rail (cut) direction by `gap` total — `lo` moves
    ///   `gap/2` toward its own corner (the canonical `va` side of the loop) and
    ///   `hi` moves `gap/2` toward the opposite corner (the canonical `vb` side).
    ///   The displacement is SYMMETRIC about the split line ("a width around the
    ///   split line, thickening the cut"), so the two boundary loops end up `gap`
    ///   apart, centred on the original cut. The direction follows each rail edge
    ///   `va→vb`, which lies ON the surface and runs perpendicular to the inserted
    ///   loop, so the gap opens the way the two sides pull apart. Because each seam
    ///   vert is pushed toward the corner on ITS OWN side of the loop, every vert
    ///   of one shell moves the same way (consistent per rail even though the
    ///   canonical `va` corner varies), and any cap quads built by `caps` gain real
    ///   area (they were zero-area walls while lo/hi coincided). Topology is
    ///   UNCHANGED — Gap only relocates the duplicated verts.
    ///
    /// - `curvature` (Preserve Curvature, task 0254): when false (default) each
    ///   new loop vertex sits at the LINEAR interpolation `lerp(va, vb, t)` on the
    ///   rail chord (byte-for-byte unchanged). When true the vertex is instead
    ///   placed on a uniform Catmull-Rom (Cardinal) spline that follows the cage's
    ///   curvature ALONG the rail, so a cut across a curved cage keeps the rounded
    ///   profile instead of flattening onto the chord. The spline runs through four
    ///   points — `P0, va, vb, P3` — where `P0`/`P3` are the neighbouring cage
    ///   vertices continuing the rail past `va`/`vb` (found geometrically by
    ///   `railContinuation`); the result is `lerp + curveTension·(catmullRom −
    ///   lerp)`, so `curveTension` (task 0255 "Tension") scales the curvature
    ///   contribution: 1.0 (default) = full standard Catmull-Rom, 0.0 = linear
    ///   (identical to `curvature` off), and it may exceed 1 / go negative. On a
    ///   FLAT (locally collinear) cage the four points are collinear so the spline
    ///   equals the chord — `curvature` on is then a no-op there.
    ///
    /// - `profileHeights` / `profileDepth` (1D profile cutter, task 0256): when
    ///   `profileHeights` is null (default) every inserted loop lies ON the surface
    ///   (byte-for-byte the flat behaviour above). When non-null it MUST be parallel
    ///   to `positions` (one height per loop, height normalized 0..1) — the caller
    ///   drives an arbitrary 1D profile by choosing `positions` = the profile's
    ///   along-cut sample fractions and `profileHeights` = the profile's height at
    ///   each. After all faces/verts are built, EACH inserted loop `i` is displaced
    ///   OFF the surface along the local surface normal by `profileHeights[i] *
    ///   profileDepth`, so the sequence of loops presses the profile's cross-section
    ///   into the surface ("Inset" = `profileDepth`). The surface normal per rail is
    ///   the average of the rail edge's incident face normals in the ORIGINAL mesh
    ///   (a single consistent value per physical rail, so a rail shared by two ring
    ///   faces is displaced ONCE, watertight). Both the connected (`midsVa`) and the
    ///   Split-duplicated (`midsVb`) copies of a rail midpoint receive the SAME
    ///   normal displacement, so profile composes with Split/Gap (Gap then separates
    ///   the pair ALONG the rail, orthogonal to the profile normal). Grid-interior
    ///   verts of a rare two-ring crossing are NOT displaced (documented limitation;
    ///   profiles are a single-ring cutter). `profileDepth == 0` (the reference's
    ///   default Inset) leaves every loop on the surface even for a non-flat profile.
    ///   The built-in profile CURVES themselves are vibe3d-defined stand-ins (the
    ///   reference profile preset library is closed-source and not headlessly
    ///   capturable); only the MECHANISM (sample→loop→normal-inset) is
    ///   reference-faithful. See `LoopSliceTool.profileSamples` (source/tools/
    ///   loop_slice_tool.d) for the built-in set and the reversex/reversey/aspect
    ///   hook points (tasks 0257/0258/0259).
    bool insertEdgeLoopsMulti(const(uint)[] seeds, const(float)[] positionsIn,
                              out uint[] newFaceIndices,
                              const(uint)[] restrictFaces = null,
                              bool keepQuads = false,
                              bool ngon = false,
                              bool split = false,
                              bool caps = false,
                              uint[2][]* splitPairsOut = null,
                              float gap = 0.0f,
                              bool curvature = false,
                              float curveTension = 1.0f,
                              const(float)[] profileHeightsIn = null,
                              float profileDepth = 0.0f) {
        newFaceIndices = [];
        if (seeds.length == 0 || positionsIn.length == 0) return false;

        // DoS backstop (task 0365 P1): `positionsIn.length` scales the
        // per-position ring/vertex work below (one `addVertex` + one ring
        // split per entry); Param `.min()` hints (loop_slice's `count`) are
        // UI-only and do not clamp a direct/scripted caller reaching this
        // shared kernel. Truncate rather than reject so a legitimate large
        // request degrades to a bounded cut instead of failing outright.
        enum size_t MAX_LOOP_SLICE_COUNT = 256;
        if (positionsIn.length > MAX_LOOP_SLICE_COUNT)
            positionsIn = positionsIn[0 .. MAX_LOOP_SLICE_COUNT];

        // Dedup coincident cut positions (task 0308, fuzz-found): Free mode's
        // `insertAt`/`count` bookkeeping does not enforce distinct slice
        // fractions (two `insertAt 0.5` calls, or a fresh `count`-grown slot
        // that defaults to the same 0.5 as an existing one, both reach here
        // unchanged). Every entry in `positions` independently spawns its own
        // `addVertex` per rail in `getMids` below — two equal (or
        // near-equal, within `posEps`) fractions therefore create TWO
        // distinct vertex indices sitting at the SAME world position, and
        // the sub-quad chain `emitSingleRingSplit`/`emitNgonRingSplit` builds
        // between consecutive positions degenerates into a zero-area face
        // for that pair. Collapse duplicates (keeping the FIRST occurrence,
        // and its matching `profileHeights` entry so a profile-cutter caller
        // stays parallel) BEFORE any ring/vertex work starts, so a duplicate
        // cut position yields one clean cut — never coincident verts or
        // zero-area faces. Mirrors the 0303 `edgeSliceEx` atomicity fix's
        // "no-op must not corrupt the mesh" contract for this kernel's own
        // failure mode (a degenerate INPUT rather than a Pass-1/Pass-2 split).
        import std.math : abs;
        float[] positions;
        float[] profileHeightsBuf;
        immutable float posEps = 1e-4f;
        positions.reserve(positionsIn.length);
        foreach (i, t; positionsIn) {
            bool dup = false;
            foreach (kept; positions) {
                if (abs(kept - t) < posEps) { dup = true; break; }
            }
            if (dup) continue;
            positions ~= t;
            if (profileHeightsIn !is null && i < profileHeightsIn.length)
                profileHeightsBuf ~= profileHeightsIn[i];
        }
        if (positions.length == 0) return false;   // defensive; unreachable (positionsIn non-empty)
        const(float)[] profileHeights = (profileHeightsIn is null) ? null : profileHeightsBuf;

        // 1. Collect + dedup rings from the ORIGINAL (unmutated) mesh.
        import std.algorithm : sort;
        EdgeRingEntry[][] rings;
        bool[immutable(uint)[]] seenRingKey;
        // `anyOpenRing` — set when at least one KEPT ring is OPEN (it TERMINATES
        // at a non-quad / mesh-boundary face rather than wrapping back on itself).
        // An open ring has terminating rails shared with a non-ring neighbour, so
        // its cut must ABSORB the terminating midpoint into that neighbour to stay
        // watertight (the reference default). A CLOSED belt ring has no terminating
        // face, so it never needs the absorb pass and keeps the byte-for-byte
        // single-pass emission (see `twoPass` below).
        bool anyOpenRing = false;
        foreach (seed; seeds) {
            if (seed >= edges.length) continue;
            bool closed;
            auto ring = collectEdgeRing(seed, closed, ngon);
            if (ring.length == 0) continue;   // degenerate/no-op seed — skip

            uint[] faceIds;
            faceIds.reserve(ring.length);
            foreach (e; ring) faceIds ~= e.fi;
            faceIds.sort();
            auto key = faceIds.idup;
            if (key in seenRingKey) continue;   // same ring as an earlier seed
            seenRingKey[key] = true;
            rings ~= ring;
            if (!closed) anyOpenRing = true;    // terminating ring → absorb pass
        }
        if (rings.length == 0) return false;

        // 2. Per-face ring map — at most 2 entries/face for a well-formed
        //    quad mesh; a 3rd+ is dropped (documented above).
        EdgeRingEntry[][uint] perFaceRings;
        foreach (ref ring; rings)
            foreach (e; ring) {
                auto p = e.fi in perFaceRings;
                if (p is null) perFaceRings[e.fi] = [e];
                else if (p.length < 2) (*p) ~= e;
            }

        // Slice-Selected restriction: keep only ring faces in `restrictFaces`
        // as SPLIT faces; dropped ring faces fall through to the absorb pass
        // (they take the boundary midpoints of their split neighbours as an
        // n-gon). `restrictFaces is null` ⇒ no restriction (whole ring).
        immutable bool restricting = restrictFaces !is null;
        if (restricting) {
            bool[uint] allowSet;
            foreach (f; restrictFaces) allowSet[f] = true;
            uint[] toDrop;
            foreach (fi, _; perFaceRings) if (fi !in allowSet) toDrop ~= fi;
            foreach (fi; toDrop) perFaceRings.remove(fi);
            if (perFaceRings.length == 0) return false;  // nothing selected to cut
        }

        // Rail cache — SHARED across every face and both grid axes: a
        // directed edge key is only ever midpoint-split once, however many
        // rings/faces reference it (identical caching to the pre-0239
        // single-ring body).
        // `midsVa` = the interpolated rail midpoints (the CONNECTED verts, used
        // by the default path byte-for-byte). `midsVb` = the split "hi"-side
        // duplicates (task 0251), created lazily by `railMids` only when the
        // Split option requests the toward-`vb` side; stays null otherwise so no
        // orphan verts appear for rails a split face never references on its hi
        // side (grid / absorb rails).
        // `normal` (task 0256 profile cutter): the surface normal along which this
        // rail's loop midpoints are displaced by the 1D profile. Computed once per
        // rail (see below) ONLY when profile displacement is requested; a benign
        // default (+Y) otherwise so the flat path pays nothing.
        struct Rail { uint va; uint[] midsVa; uint[] midsVb; Vec3 normal = Vec3(0,1,0); }
        Rail[]      rails;
        uint[ulong] railByKey;
        uint[2][]   splitSeams;   // [loVert, hiVert] per duplicated midpoint (0251)
        Vec3[]      splitSeamDirs; // unit lo→hi rail (cut) direction per seam (0253 Gap)
        // Profile cutter (task 0256): displace each inserted loop off the surface
        // by `profileHeights[i] * profileDepth` along the rail's surface normal.
        // Only active when the caller supplies a per-loop height array.
        immutable bool profileOn = profileHeights !is null;

        static void reverseInPlace(uint[] a) {
            size_t i = 0, j = a.length - 1;
            while (i < j) { uint t = a[i]; a[i] = a[j]; a[j] = t; ++i; --j; }
        }

        // Surface normal at a rail edge (task 0256): the average of the incident
        // face normals of edge va→vb in the ORIGINAL mesh (faces/loops are still
        // untouched during the emit phase — only `newFaces` is being built, and
        // addVertex merely appends). One consistent value per physical rail keyed
        // to the edge, so a rail shared by two ring faces is displaced ONCE and the
        // cut stays watertight. Falls back to +Y on a degenerate/missing edge.
        Vec3 railNormal(uint va, uint vb) {
            uint ei = edgeIndex(va, vb);
            if (ei == ~0u) return Vec3(0, 1, 0);
            Vec3 sum = Vec3(0, 0, 0);
            foreach (fi; facesAroundEdge(ei)) sum = sum + faceNormal(fi);
            float len = sqrt(dot(sum, sum));
            return len > 1e-6f ? sum * (1.0f / len) : Vec3(0, 1, 0);
        }

        // `mirror` (task 0398): true when this request originates from a
        // side-B (`EdgeRingEntry.mirror`) entry of an OPEN ring. Only affects
        // a FRESH creation (the `else` branch below, when the physical rail
        // doesn't exist in `railByKey` yet) — a cache hit returns whatever
        // was already created, unaffected by this call's own mirror value
        // (its position was fixed by whichever request created it first).
        // On fresh creation the fraction is flipped to `1-t`: this is an
        // EXACT algebraic identity for the linear branch
        // (`va+(vb-va)*(1-t) == vb+(va-vb)*t`, i.e. "t measured from vb")
        // and, less obviously, also exact for the curvature spline
        // (`curvatureSplinePoint(p0,p1,p2,p3,t) ==
        //   curvatureSplinePoint(p3,p2,p1,p0,1-t)`, the standard Hermite
        // reversal identity) — so mirroring `t` alone, without swapping
        // va/vb or p0/p3, reproduces exactly what a canonical (vb,va)
        // creation would have produced, regardless of which side's request
        // happens to reach this rail first.
        uint[] getMids(uint va, uint vb, bool mirror = false) {
            ulong k = edgeKey(va, vb);
            if (auto rp = k in railByKey) {
                if (rails[*rp].va == va) return rails[*rp].midsVa;
                // Anti-parallel: reversed copy.
                auto rev = rails[*rp].midsVa.dup;
                reverseInPlace(rev);
                return rev;
            }
            uint[] mids;
            Vec3 va3 = vertices[va], vb3 = vertices[vb];
            if (curvature) {
                // Preserve Curvature (task 0254): place each midpoint on the
                // Catmull-Rom spline through the rail's cage neighbours instead of
                // the straight chord. `p0`/`p3` continue the rail past va/vb; they
                // are read from the ORIGINAL topology (verticesAroundVertex is valid
                // here — addVertex only appends, never rebuilds the loops) and
                // captured as VALUES so subsequent addVertex reallocations are safe.
                Vec3 p0 = railContinuation(va, vb);
                Vec3 p3 = railContinuation(vb, va);
                foreach (float t; positions) {
                    float tt = mirror ? 1.0f - t : t;
                    mids ~= addVertex(curvatureSplinePoint(p0, va3, vb3, p3, tt, curveTension));
                }
            } else {
                foreach (float t; positions) {
                    float tt = mirror ? 1.0f - t : t;
                    mids ~= addVertex(va3 + (vb3 - va3) * tt);
                }
            }
            railByKey[k] = cast(uint)rails.length;
            Vec3 nrm = profileOn ? railNormal(va, vb) : Vec3(0, 1, 0);
            rails ~= Rail(va, mids, null, nrm);
            return mids;
        }

        // Loop-Slice Split (task 0251): the rail midpoints on edge va→vb, ORIENTED
        // va→vb, on the side of the loop toward the FIRST corner (`towardFirst` =
        // true → toward `va`; false → toward `vb`). With `split` off both sides
        // resolve to the same shared `midsVa` verts, so this is exactly `getMids`
        // (byte-for-byte). With `split` on the toward-`va` side is the original
        // connected verts (`midsVa`) and the toward-`vb` side is a distinct set of
        // coincident duplicates (`midsVb`, made once per rail). The lo/hi choice is
        // keyed to the rail's CANONICAL `va`, so the same physical rail always
        // resolves the same duplicate for a given loop side regardless of which
        // face (or traversal direction) asks — that is what keeps each side's loop
        // connected around the ring while the two sides stay disconnected.
        uint[] railMids(uint va, uint vb, bool towardFirst, bool mirror = false) {
            uint[] base = getMids(va, vb, mirror); // midsVa oriented va→vb
            if (!split) return base;
            ulong k = edgeKey(va, vb);
            uint rp = railByKey[k];
            bool forward = (rails[rp].va == va);
            // Which stored side does "toward the caller's first corner" map to?
            //   forward  (va == canonical va): toward va == midsVa side
            //   !forward (va == canonical vb): toward va == midsVb side
            bool wantVaSide = towardFirst ? forward : !forward;
            if (wantVaSide) return base;          // midsVa side, already oriented
            // Toward the canonical `vb` corner — the duplicated (hi) side.
            if (rails[rp].midsVb is null) {
                // Cut (gap-opening) direction for this rail: the unit vector from
                // the canonical `va` corner (lo side) to the canonical `vb` corner
                // (hi side). Caller's (va,vb) already gives the two endpoints;
                // orient it canonical va→vb so lo (midsVa) is the `-dir` end and
                // hi (midsVb) the `+dir` end (task 0253 Gap). Constant per rail.
                uint cva = rails[rp].va;         // canonical va (lo-side corner)
                uint cvb = forward ? vb : va;    // canonical vb (hi-side corner)
                Vec3 dir = normalize(vertices[cvb] - vertices[cva]);
                uint[] dup;
                foreach (v; rails[rp].midsVa) {
                    uint nv = addVertex(vertices[v]);
                    dup ~= nv;
                    splitSeams ~= cast(uint[2])[v, nv];
                    splitSeamDirs ~= dir;
                }
                rails[rp].midsVb = dup;
            }
            uint[] side = rails[rp].midsVb;
            if (!forward) { side = side.dup; reverseInPlace(side); }
            return side;
        }

        // Emit the standard (P+1)-subquad single-ring split of one face,
        // given its (a,b,c,d) CCW frame — shared by the 1-ring path and the
        // 2-ring fallback below.
        void emitSingleRingSplit(uint a, uint b, uint c, uint d,
                                  ref uint[][] newFaces, bool mirror = false) {
            // pLo/qLo = toward the a/d corners (the loop's "first" side); pHi/qHi
            // = toward b/c. With Split off all four are the same shared rail verts
            // (byte-for-byte `getMids`); with Split on the hi verts are distinct
            // duplicates so the two sides of the loop are disconnected (task 0251).
            // `mirror` (task 0398): the source EdgeRingEntry's side-B flag, forwarded
            // to both this face's rails so a freshly-created p/q rail lands in side
            // A's convention (see `EdgeRingEntry.mirror` / `getMids`).
            uint[] pLo = railMids(a, b, true, mirror),  pHi = railMids(a, b, false, mirror);
            uint[] qLo = railMids(d, c, true, mirror),  qHi = railMids(d, c, false, mirror);
            newFaces ~= [a, pLo[0], qLo[0], d];               // toward-a/d cap
            newFaceIndices ~= cast(uint)(newFaces.length - 1);
            foreach (k; 1 .. positions.length) {
                newFaces ~= [pHi[k-1], pLo[k], qLo[k], qHi[k-1]];
                newFaceIndices ~= cast(uint)(newFaces.length - 1);
            }
            newFaces ~= [pHi[$-1], b, c, qHi[$-1]];           // toward-b/c cap
            newFaceIndices ~= cast(uint)(newFaces.length - 1);
        }

        uint[][] newFaces;
        newFaces.reserve(faces.length + rings.length * positions.length * 4);
        // Parallel to `newFaces` (task 0389): every entry pushed to `newFaces`
        // gets a matching Subpatch bit pushed here in lock-step, so `faceMarks`
        // can be rebuilt (Template A) once `faces = newFaces` lands below.
        // `faces = newFaces` is a whole-array rebuild — without this,
        // `faceMarks` would stay aligned to the OLD `faces` slot indices and
        // every bit would land on the wrong (or a nonexistent) face.
        bool[] newSub;
        newSub.reserve(faces.length + rings.length * positions.length * 4);

        // Slice ONE non-quad ring-crossed face (task 0250 "Slice N-gon"). The
        // chord runs from the entry-edge rail to the exit-edge rail, splitting
        // the polygon into two sub-faces plus (P-1) middle quads between rails.
        // Generalises `emitSingleRingSplit`: with P positions and the two side
        // chains S1 (entry→exit) / S2 (exit→entry), the end caps carry the
        // chains and the rails pair up exactly as in the quad case (a quad's S1
        // = [b,c], S2 = [d,a] collapse this to `emitSingleRingSplit` verbatim).
        void emitNgonRingSplit(EdgeRingEntry e) {
            auto f = faces[e.fi];
            uint N = cast(uint)f.length;
            int  ej = e.entryJ, xj = e.exitJ;
            uint a = f[ej], b = f[(ej + 1) % N];   // entry edge a→b
            uint c = f[xj], d = f[(xj + 1) % N];   // exit  edge c→d
            // Side-aware rails (task 0251 Split): lo = toward a/d (the S2 cap
            // side), hi = toward b/c (the S1 cap side). Split off ⇒ lo==hi==getMids.
            // `e.mirror` (task 0398): forwarded so a freshly-created rail lands in
            // side A's convention (see `EdgeRingEntry.mirror` / `getMids`).
            uint[] pLo = railMids(a, b, true, e.mirror),  pHi = railMids(a, b, false, e.mirror);
            uint[] qLo = railMids(d, c, true, e.mirror),  qHi = railMids(d, c, false, e.mirror);

            // S1 = the boundary chain from b (entry-edge far vertex) forward to
            // c (exit-edge near vertex); S2 = from d forward to a.
            uint[] s1, s2;
            for (uint k = cast(uint)((ej + 1) % N); ; k = (k + 1) % N) {
                s1 ~= f[k];
                if (k == cast(uint)xj) break;
            }
            for (uint k = cast(uint)((xj + 1) % N); ; k = (k + 1) % N) {
                s2 ~= f[k];
                if (k == cast(uint)ej) break;
            }

            // Start cap (S2 side, toward a/d): [pLo0, qLo0] ~ S2.
            uint[] capB = [pLo[0], qLo[0]] ~ s2;
            newFaces ~= capB;
            newFaceIndices ~= cast(uint)(newFaces.length - 1);
            // Middle quads between consecutive rails.
            foreach (k; 1 .. positions.length) {
                newFaces ~= [pHi[k-1], pLo[k], qLo[k], qHi[k-1]];
                newFaceIndices ~= cast(uint)(newFaces.length - 1);
            }
            // End cap (S1 side, toward b/c): [pHi_last] ~ S1 ~ [qHi_last].
            uint[] capA = [pHi[$-1]] ~ s1 ~ [qHi[$-1]];
            newFaces ~= capA;
            newFaceIndices ~= cast(uint)(newFaces.length - 1);
        }

        // Split ONE ring-crossed face (single-ring or grid). Precondition:
        // `fi in perFaceRings`. Factored out so the whole-ring path and the
        // Slice-Selected restrict path share IDENTICAL split geometry.
        void splitFace(uint fi) {
            auto entries = perFaceRings[fi];

            // A non-quad face crossed under `ngon`: all its entries describe the
            // SAME polygon, so the first ngon entry fully determines the cut (a
            // 2nd distinct ring through the same n-gon is rare/degenerate and
            // defensively ignored — the chord split is single-ring).
            if (entries[0].ngon) {
                emitNgonRingSplit(entries[0]);
                return;
            }

            if (entries.length == 1) {
                auto e = entries[0];
                emitSingleRingSplit(e.a, e.b, e.c, e.d, newFaces, e.mirror);
                return;
            }

            // Two distinct rings cross this quad. Reconcile both entries'
            // local (a,b,c,d) framing into ONE consistent orientation using
            // entries[0] as the base CCW frame (A,B,C,D around the quad).
            // entries[1]'s ENTRY edge must be one of the base frame's other
            // two sides — (B,C) or (D,A) — walked in either direction (a
            // ring can approach from either end); this is a pure identity
            // check, entries[1]'s own field values are never used for
            // geometry (the base frame alone fully describes the quad).
            auto e0 = entries[0];
            uint A = e0.a, B = e0.b, C = e0.c, D = e0.d;
            auto e1 = entries[1];
            static bool matchesUndirected(uint x, uint y, uint p, uint q) {
                return (x == p && y == q) || (x == q && y == p);
            }
            bool aligned = matchesUndirected(e1.a, e1.b, B, C)
                        || matchesUndirected(e1.a, e1.b, D, A);
            if (!aligned) {
                // Should not happen on a well-formed quad mesh (two truly
                // distinct rings can only cross via the two non-entry sides)
                // — fall back to a single-ring split on the base ring only,
                // rather than emit an inconsistent grid.
                emitSingleRingSplit(A, B, C, D, newFaces, e0.mirror);
                return;
            }

            // Grid split. u runs A→B (bottom) / D→C (top); v runs B→C
            // (right) / A→D (left) — see the doc comment above for the
            // bilerp-equals-sequential-inserts derivation.
            // `e0.mirror`/`e1.mirror` (task 0398): each ring's own side-B flag,
            // forwarded so a freshly-created rail lands in side A's convention.
            uint[] pU = getMids(A, B, e0.mirror);   // bottom rail, u-direction
            uint[] qU = getMids(D, C, e0.mirror);   // top rail, u-direction
            uint[] pV = getMids(B, C, e1.mirror);   // right rail, v-direction
            uint[] qV = getMids(A, D, e1.mirror);   // left rail, v-direction

            size_t Pu = positions.length, Pv = positions.length;
            uint[][] grid = new uint[][](Pu + 2, Pv + 2);
            grid[0][0]       = A;
            grid[Pu+1][0]    = B;
            grid[Pu+1][Pv+1] = C;
            grid[0][Pv+1]    = D;
            foreach (i; 0 .. Pu) {
                grid[i+1][0]    = pU[i];
                grid[i+1][Pv+1] = qU[i];
            }
            foreach (j; 0 .. Pv) {
                grid[0][j+1]    = qV[j];
                grid[Pu+1][j+1] = pV[j];
            }
            // Interior vertices are strictly per-face (never shared with a
            // neighbour) — fresh bilerp'd verts every time.
            foreach (i; 0 .. Pu)
                foreach (j; 0 .. Pv) {
                    float u = positions[i], v = positions[j];
                    Vec3 pt = vertices[A] * ((1.0f - u) * (1.0f - v))
                            + vertices[B] * (u * (1.0f - v))
                            + vertices[C] * (u * v)
                            + vertices[D] * ((1.0f - u) * v);
                    grid[i+1][j+1] = addVertex(pt);
                }

            foreach (i; 0 .. Pu + 1)
                foreach (j; 0 .. Pv + 1) {
                    newFaces ~= [grid[i][j], grid[i+1][j],
                                 grid[i+1][j+1], grid[i][j+1]];
                    newFaceIndices ~= cast(uint)(newFaces.length - 1);
                }
        }

        // Subpatch-tracking wrapper around `splitFace` (task 0389): every
        // sub-face `splitFace(fi)` emits — single-ring, n-gon, or a 2-ring
        // grid — inherits the SOURCE ring face `fi`'s Subpatch bit. Rather
        // than threading `fi` through emitSingleRingSplit/emitNgonRingSplit/
        // the grid-split branch individually, record `newFaces.length`
        // before/after the call and backfill `newSub` for whatever range
        // `splitFace` just appended.
        void splitFaceTracked(uint fi) {
            immutable size_t before = newFaces.length;
            splitFace(fi);
            immutable bool sub = isFaceSubpatch(fi);
            foreach (i; before .. newFaces.length) newSub ~= sub;
        }

        // Read-only rail lookup for the absorb pass — returns the existing
        // midpoints on edge va→vb (in that direction) if it was split by a
        // neighbouring face, else null. NEVER creates a rail (unlike getMids).
        uint[] absorbMids(uint va, uint vb) {
            ulong k = edgeKey(va, vb);
            auto rp = k in railByKey;
            if (rp is null) return null;
            // Absorb attaches to the lo (connected) side (`midsVa`) — under Split
            // the neighbour stays joined to the lo loop; the hi loop is free.
            if (rails[*rp].va == va) return rails[*rp].midsVa;
            auto rev = rails[*rp].midsVa.dup;
            reverseInPlace(rev);
            return rev;
        }

        // Two passes are needed whenever some non-split face must ABSORB a
        // terminating midpoint. This is now the DEFAULT for any OPEN (terminating)
        // ring: when the ring stops at a non-quad face or a mesh boundary the
        // neighbour absorbs the terminating midpoint into its own boundary (an
        // n-gon), so the cut stays WATERTIGHT with no T-junction — the reference's
        // default behaviour. The Slice-Selected restriction (`restricting`) also
        // needs it (absorb at the selection border, even for a closed belt ring).
        // A CLOSED all-quad belt ring (the common full-ring cut) has NO terminating
        // face — `anyOpenRing` is false and it is not restricting — so it takes the
        // byte-for-byte single-pass whole-ring path below, unchanged. `keepQuads`
        // (Keep Quads) is now a GEOMETRIC NO-OP: the terminating absorb it used to
        // gate happens by default, matching the reference (Keep Quads on == off on
        // every capturable mesh); the param is kept only for panel parity.
        immutable bool twoPass = restricting || anyOpenRing;
        if (!twoPass) {
            // Whole-ring path — UNCHANGED (byte-for-byte): one pass in face
            // index order, dup non-ring faces, split ring faces.
            foreach (uint fi; 0 .. cast(uint)faces.length) {
                if (fi in perFaceRings) splitFaceTracked(fi);
                else { newFaces ~= faces[fi].dup; newSub ~= isFaceSubpatch(fi); }
            }
        } else {
            // Slice-Selected / Keep-Quads path — TWO passes. Pass 1 splits the
            // ring faces (populating the rail cache, including the boundary
            // rails shared with unlisted / non-quad neighbours). Pass 2 emits
            // every non-split face, ABSORBING any boundary midpoints on its
            // edges so the cut terminates watertight at the selection border /
            // non-quad border (that neighbour becomes an n-gon; a face
            // untouched by the cut re-emits identically).
            foreach (uint fi; 0 .. cast(uint)faces.length)
                if (fi in perFaceRings) splitFaceTracked(fi);
            foreach (uint fi; 0 .. cast(uint)faces.length) {
                if (fi in perFaceRings) continue;   // already split in pass 1
                auto f = faces[fi];
                uint[] nf;
                foreach (k; 0 .. f.length) {
                    uint va = f[k], vb = f[(k + 1) % f.length];
                    nf ~= va;
                    foreach (m; absorbMids(va, vb)) nf ~= m;
                }
                newFaces ~= nf;
                newSub ~= isFaceSubpatch(fi);
            }
        }

        // Cap Sections (task 0252, geometry corrected by LIVE reference capture
        // task 0261): with Split on, seal each opened SECTION with a SINGLE cap
        // polygon that fills that section's own boundary loop — NOT a strip of
        // quads bridging the lo loop to the hi loop. The reference (captured on the
        // unit cube belt: split+caps ⇒ +2 faces, one per shell, each a flat n-gon
        // in the loop's plane) leaves the two split shells DISCONNECTED and closes
        // each into an independent solid, so a Gap opens a REAL visible band
        // between them. The old bridging caps instead filled that band coplanar
        // with the side faces — a geometrically invisible cut on flat surfaces.
        //
        // Each split shell's boundary loop is the ring of face-incidence-1 edges
        // whose BOTH endpoints belong to that shell's midpoint set (lo = `midsVa`,
        // hi = `midsVb`). We chain those directed boundary edges into ordered
        // cycles and emit each cycle REVERSED (so the cap opposes the shell's side
        // faces and seals it). Interior lo–lo / hi–hi edges (shared by two
        // sub-faces of a multi-position split) have incidence 2 and are skipped.
        // The cap faces add NO new edges (every cap edge is an existing boundary
        // edge) and NO new verts; Gap (0253) later separates the lo cap from the
        // hi cap along the rail, opening the band.
        if (split && caps && splitSeams.length > 0) {
            bool[uint] loSet, hiSet;
            foreach (pr; splitSeams) { loSet[pr[0]] = true; hiSet[pr[1]] = true; }

            // Subpatch for a cap face (task 0389): a cap seals a WHOLE shell's
            // boundary loop, which can be stitched together from more than one
            // original ring face — there is no single "source face" the way
            // there is for a split sub-quad. Fall back to the OR-across-sources
            // rule used elsewhere for multi-source new faces (chamfer/bridge):
            // the cap is Subpatch if ANY ring face this cut passed through was.
            bool anyRingSubpatch = false;
            foreach (fi, _; perFaceRings)
                if (isFaceSubpatch(fi)) { anyRingSubpatch = true; break; }

            // Chain each shell's incidence-1 boundary edges into reversed cap
            // polygons via the shared `capShellCycles` helper (same geometry the
            // Slice split-caps path uses — task 0274). Interior lo–lo / hi–hi
            // edges (incidence 2) are skipped; each cap reuses existing boundary
            // verts (no new verts/edges).
            void capBoundaryLoops(ref bool[uint] set) {
                foreach (cyc; capShellCycles(newFaces, set)) {
                    newFaces ~= cyc;
                    newFaceIndices ~= cast(uint)(newFaces.length - 1);
                    newSub ~= anyRingSubpatch;
                }
            }
            capBoundaryLoops(loSet);
            capBoundaryLoops(hiSet);
        }

        // Gap (task 0253): open a gap of width `gap` between the two split
        // boundary loops by pushing each coincident seam pair apart along its rail
        // (cut) direction — `lo` by `gap/2` toward the canonical `va` corner,
        // `hi` by `gap/2` toward the canonical `vb` corner, symmetric about the
        // split line. `gap == 0` (or `split` off, so `splitSeams` is empty) leaves
        // every vert coincident, byte-for-byte with 0251/0252. Positions only — no
        // topology change; any `caps` quads gain real area as a side effect. Each
        // seam vert is unique to one pair (lo = a distinct rail midpoint, hi its
        // sole duplicate), so no vert is displaced twice.
        if (split && gap != 0.0f && splitSeams.length > 0) {
            immutable float half = gap * 0.5f;
            foreach (i, pr; splitSeams) {
                Vec3 d = splitSeamDirs[i];
                vertices[pr[0]] = vertices[pr[0]] - d * half;   // lo → toward va
                vertices[pr[1]] = vertices[pr[1]] + d * half;   // hi → toward vb
            }
        }

        // 1D profile cutter (task 0256): press the profile's cross-section into the
        // surface by displacing each inserted loop `i` along its rail's surface
        // normal by `profileHeights[i] * profileDepth`. Positions only — topology is
        // UNCHANGED (the loops were already inserted at the profile's along-cut
        // sample fractions via `positions`). Both the connected (`midsVa`) and the
        // Split hi-duplicate (`midsVb`) copies of a midpoint move by the SAME normal
        // offset, so profile composes with Split (Gap then separates the pair along
        // the rail, orthogonal to this normal). A rail is displaced ONCE regardless
        // of how many faces reference it (the cache is per physical rail), keeping
        // the cut watertight. `profileHeights is null` OR `profileDepth == 0` leaves
        // every loop on the surface, byte-for-byte with the flat path. Grid-interior
        // verts of a two-ring crossing are intentionally NOT displaced (profiles are
        // a single-ring cutter — documented limitation).
        if (profileOn && profileDepth != 0.0f) {
            foreach (ref r; rails) {
                foreach (i; 0 .. r.midsVa.length) {
                    if (i >= profileHeights.length) break;
                    Vec3 disp = r.normal * (profileHeights[i] * profileDepth);
                    vertices[r.midsVa[i]] = vertices[r.midsVa[i]] + disp;
                    if (r.midsVb !is null && i < r.midsVb.length)
                        vertices[r.midsVb[i]] = vertices[r.midsVb[i]] + disp;
                }
            }
        }

        if (splitPairsOut !is null) *splitPairsOut = splitSeams;

        faces = newFaces;
        // Rebuild faceMarks in lock-step with the just-replaced `faces`
        // (task 0389 — Template A, mirrors bevelEdgesByMask): `newSub` was
        // populated 1:1 with every `newFaces` append above (dup'd untouched
        // faces keep their own bit; ring-split sub-faces and section caps
        // inherit from their source ring face(s)). resetSelection() below no
        // longer clears subpatch on its own, so this is the only place the
        // new mesh's Subpatch bits get set — without it every face would
        // silently default to non-subpatch (faceMarks zero-fills on resize).
        assert(newSub.length == faces.length,
               "insertEdgeLoopsMulti: newSub/newFaces length mismatch");
        faceMarks.length = faces.length;
        faceMarks[]      = 0;
        foreach (fi, s; newSub)
            if (s) faceMarks[fi] |= Marks.Subpatch;
        rebuildEdges();
        buildLoops();
        resetSelection();   // resizes + clears all selection; calls commitChange
        return true;
    }

    // -----------------------------------------------------------------------
    // capShellCycles — the shared Cap Sections boundary-loop geometry (Loop
    // Slice task 0252/0261 + Slice S8 task 0274). Given a face list and the
    // vertex `set` of ONE split shell, collect that shell's boundary edges
    // (face-incidence 1, both endpoints in `set`), chain them into ordered
    // cycles, and return each cycle REVERSED so a cap face opposes the shell's
    // side faces and seals it. Interior lo–lo / hi–hi edges (incidence 2, shared
    // by two sub-faces of a multi-position split) are skipped. Adds no verts /
    // no edges — every returned polygon reuses existing boundary verts. Pure
    // read of `faceList`; both the Loop Slice caps path (insertEdgeLoopsMulti,
    // fed its local `newFaces`) and the Slice split-caps path (splitAlongCutLoop,
    // fed `faces`) call it, so the two produce byte-identical cap topology.
    // -----------------------------------------------------------------------
    static uint[][] capShellCycles(const(uint[])[] faceList, const bool[uint] set) {
        import std.algorithm : sort, reverse;
        uint[ulong]    cnt;
        uint[2][ulong] dir;
        foreach (ref f; faceList)
            foreach (k; 0 .. f.length) {
                uint u = f[k], v = f[(k + 1) % f.length];
                if (u in set && v in set) {
                    ulong kk = edgeKey(u, v);
                    if (kk !in cnt) dir[kk] = cast(uint[2])[u, v];
                    cnt[kk]++;
                }
            }
        uint[uint] next;
        foreach (kk, c; cnt) if (c == 1) { auto e = dir[kk]; next[e[0]] = e[1]; }
        uint[] starts;
        foreach (u, nxt; next) starts ~= u;
        starts.sort();
        bool[uint] used;
        uint[][] cycles;
        foreach (s; starts) {
            if (s in used) continue;
            uint[] cyc; uint cur = s;
            while (cur !in used) {
                used[cur] = true; cyc ~= cur;
                auto nx = cur in next;
                if (nx is null) break;
                cur = *nx;
            }
            if (cyc.length >= 3) {
                reverse(cyc);   // oppose the shell's side faces → seal
                cycles ~= cyc;
            }
        }
        return cycles;
    }
}

// ---------------------------------------------------------------------------
// Unit tests — co-located with the family they exercise (moved verbatim
// from mesh.d alongside the kernels above).
// ---------------------------------------------------------------------------
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
// insertEdgeLoops — task 0398 regression: OPEN-ring loop slice must land
// every ring vertex on a CONSISTENT (planar) cut, even on the side-B-
// exclusive rails of a two-sided open walk.
//
// Root cause: `collectEdgeRing` walks an OPEN ring from BOTH faces incident
// to the seed edge (`sideA` from `incFaces[0]`, `sideB` from `incFaces[1]`).
// The seed edge carries opposite darts in its two incident faces (a basic
// manifold invariant), so every rail `getMids` creates FRESH from a side-B
// entry lands at fraction `1-t` instead of `t` relative to side A's
// convention — one ring vertex ends up off-plane (owner repro: v19 landed at
// Y=0.4415 while the other three sat at Y=0.3085). The fix (`EdgeRingEntry.
// mirror` + `getMids`'s `mirror` param) mirrors a FRESH side-B rail's
// fraction so it lands in side A's convention. This test uses an asymmetric
// t (0.234, NOT 0.5 — 0.5 is a mirror fixed point and can't distinguish a
// mirrored result from a correct one) and checks planarity + winding
// directly, rather than depending on the owner's specific coordinates.
//
// Cage: a belt of 3 quads (LEFT, BACK, FRONT) around Y=[0.25,0.5] with the
// RIGHT quad DELETED — a quad belt sliced out of a cuboid with one side face
// missing, exactly the construction (and asymmetry) the validated repro
// used. Seeding from the INTERIOR rail (2,3), shared by LEFT and BACK, forces
// `collectEdgeRing` down the two-sided walk: side A = {LEFT, FRONT}
// (terminates at the deleted RIGHT via FRONT's own boundary rail), side B =
// {BACK} (also terminates at the deleted RIGHT via BACK's own boundary rail)
// — BACK's own rail is created FRESH exclusively by side B, exactly the
// failure mode task 0398 fixed.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;
    // Winding-consistency scan: a well-formed manifold quad mesh has each
    // interior undirected edge covered by at most ONE dart per direction; a
    // repeated same-direction dart across two faces means one is inverted.
    static int repeatedDirectionDarts(const Mesh m) {
        int[ulong] fwd;
        foreach (fi; 0 .. m.faces.length) {
            auto f = m.faces[fi];
            foreach (k; 0 .. f.length) {
                uint a = f[k], b = f[(k + 1) % f.length];
                ulong dkey = (cast(ulong)a << 32) | b;
                fwd[dkey] = (dkey in fwd ? fwd[dkey] : 0) + 1;
            }
        }
        int sameDir = 0;
        foreach (k, cnt; fwd) if (cnt > 1) ++sameDir;
        return sameDir;
    }

    // ------------------------------------------------------------------
    // A) OPEN ring, two-sided walk — the bug's exact failure mode.
    // ------------------------------------------------------------------
    {
        Mesh m;
        m.vertices = [
            Vec3(-0.5f, 0.25f,  0.5f),  // 0 L0 bottom-front
            Vec3(-0.5f, 0.5f,   0.5f),  // 1 L1 top-front
            Vec3(-0.5f, 0.5f,  -0.5f),  // 2 L2 top-back
            Vec3(-0.5f, 0.25f, -0.5f),  // 3 L3 bottom-back
            Vec3( 0.5f, 0.25f,  0.5f),  // 4 R0 bottom-front
            Vec3( 0.5f, 0.5f,   0.5f),  // 5 R1 top-front
            Vec3( 0.5f, 0.5f,  -0.5f),  // 6 R2 top-back
            Vec3( 0.5f, 0.25f, -0.5f),  // 7 R3 bottom-back
        ];
        m.addFace([0u, 1u, 2u, 3u]);   // LEFT
        m.addFace([3u, 2u, 6u, 7u]);   // BACK
        m.addFace([0u, 4u, 5u, 1u]);   // FRONT
        // RIGHT [4,7,6,5] intentionally OMITTED — the ring is OPEN.
        m.rebuildEdges();
        m.buildLoops();

        uint seed = m.edgeIndex(2, 3);   // interior rail shared by LEFT/BACK
        assert(seed != ~0u, "seed rail (2,3) must exist");

        bool closed;
        auto ring = m.collectEdgeRing(seed, closed);
        assert(!closed, "sanity: this belt's ring must be OPEN");
        assert(ring.length == 3, "sanity: ring crosses LEFT+FRONT (side A) + BACK (side B)");

        bool ok = m.insertEdgeLoops(seed, [0.234f]);
        assert(ok, "open-ring insertEdgeLoops must succeed");
        assert(m.vertices.length == 12, "4 distinct rails (seed + 3 exit rails) get one midpoint each");

        float ymin = 1e9f, ymax = -1e9f;
        foreach (vi; 8 .. m.vertices.length) {
            float y = m.vertices[vi].y;
            if (y < ymin) ymin = y;
            if (y > ymax) ymax = y;
        }
        assert(ymax - ymin < 1e-4f,
               "task 0398: all 4 ring vertices must be coplanar (one loop, one height)");
        assert(repeatedDirectionDarts(m) == 0,
               "task 0398 fix must not invert any face's winding");
    }

    // ------------------------------------------------------------------
    // B) CLOSED ring sanity — the mirror flag must NEVER fire here.
    // `walkRingSide` returns via `closedA` before side B is ever walked
    // (mesh.d, `collectEdgeRing`), so this must stay byte-for-byte with the
    // pre-0398 behaviour. Uses an ASYMMETRIC t (0.5 is a mirror fixed point
    // and can't tell a mirrored result from a correct one). Seed edge (0,1)
    // on `makeCube()` is the X-aligned belt seed the existing closed-ring
    // unittest (A, above) uses at t=0.5 — every one of the 4 belt rails
    // (0-1, 2-3, 6-7, 4-5) runs along X, so a CONSISTENT fraction must land
    // all 4 new vertices at the SAME X (not Y — this belt varies in Y/Z as
    // it goes around, only X is the cut-fraction axis).
    // ------------------------------------------------------------------
    {
        Mesh cube = makeCube();
        cube.buildLoops();
        uint eiSeed = cube.edgeIndex(0, 1);
        assert(eiSeed != ~0u, "cube seed edge 0-1 must exist");

        bool closed;
        auto ring = cube.collectEdgeRing(eiSeed, closed);
        assert(closed, "sanity: cube's equatorial ring must be CLOSED");

        bool ok = cube.insertEdgeLoops(eiSeed, [0.234f]);
        assert(ok, "closed-ring insertEdgeLoops must succeed");
        assert(cube.vertices.length == 12, "closed ring: 8 + 4 belt midpoints");

        float xmin = 1e9f, xmax = -1e9f;
        foreach (vi; 8 .. cube.vertices.length) {
            float x = cube.vertices[vi].x;
            if (x < xmin) xmin = x;
            if (x > xmax) xmax = x;
        }
        assert(xmax - xmin < 1e-4f,
               "closed-ring belt vertices must share one X (mirror flag never fires)");
        // Exact value (task 0398 fix must not touch this — closed rings
        // never mirror): the walk visits F0=[0,3,2,1] first, whose local
        // frame for edge (0,1) is the dart 1->0 (a=1,b=0), so the vertex
        // sits at v1 + (v0-v1)*t = 0.5 + (-1.0)*0.234 = 0.266. A mirrored
        // (1-t) result would instead land at -0.266.
        assert(abs(cube.vertices[8].x - 0.266f) < 1e-3f,
               "closed-ring belt X must be the UNMIRRORED t=0.234 fraction (byte-for-byte pre-0398)");
        assert(repeatedDirectionDarts(cube) == 0,
               "closed-ring cut must not invert any face winding");
    }
}

// ---------------------------------------------------------------------------
// insertEdgeLoops (3-arg, Select-New-Polygons affordance) — the returned
// `newFaceIndices` must name exactly the sub-quads this call created, and
// nothing else. On the cube fixture above the closed ring crosses 4
// equatorial quad faces (ringLen=4); one loop (count=1) replaces each ring
// face with exactly 2 sub-quads (first+last, no middle sub-quad) → the
// returned set must have length 2*ringLen == 8, and every referenced face
// index must still be a quad.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    m.buildLoops();

    uint eiSeed = m.edgeIndex(0, 1);
    assert(eiSeed != ~0u, "seed edge 0-1 must exist in cube");

    uint[] newFaceIndices;
    bool ok = m.insertEdgeLoops(eiSeed, [0.5f], newFaceIndices);
    assert(ok, "insertEdgeLoops(3-arg) must succeed on cube");

    enum ringLen = 4;   // the equatorial ring crosses 4 quad faces
    assert(newFaceIndices.length == 2 * ringLen,
           "count=1 must report 2 sub-quads per ring face (first+last, no middle)");

    // No duplicate indices, and every returned index names a real quad face.
    bool[uint] seen;
    foreach (fi; newFaceIndices) {
        assert(fi !in seen, "newFaceIndices must not repeat an index");
        seen[fi] = true;
        assert(fi < m.faces.length, "newFaceIndices must index into the rebuilt faces array");
        assert(m.faces[fi].length == 4, "every reported new face must be a quad");
    }

    // The 2-arg forwarder must be byte-identical to the 3-arg call (ignoring
    // the out-param) — same V/E/F on an independent mesh.
    Mesh m2 = makeCube();
    m2.buildLoops();
    uint eiSeed2 = m2.edgeIndex(0, 1);
    bool ok2 = m2.insertEdgeLoops(eiSeed2, [0.5f]);
    assert(ok2, "2-arg forwarder must still succeed");
    assert(m2.vertices.length == m.vertices.length
           && m2.edges.length == m.edges.length
           && m2.faces.length == m.faces.length,
           "2-arg forwarder must produce the same geometry as the 3-arg overload");
}

// ---------------------------------------------------------------------------
// insertEdgeLoopsMulti (task 0239 M1) — multi-seed backend.
//
// Two disconnected unit cubes (the second translated +3 on X) give two
// DISTINCT, NON-CROSSING closed rings with no shared faces at all — the
// simplest possible "Count loops per distinct ring" fixture (owner-decision
// D1). Cube A occupies vertex indices 0-7 exactly like `makeCube()`; cube B
// is the same 8 vertices offset by (+3,0,0), indices 8-15.
// ---------------------------------------------------------------------------

private Mesh makeTwoDisjointCubes() {
    Mesh m;
    m.vertices = [
        Vec3(-0.5f, -0.5f, -0.5f), Vec3( 0.5f, -0.5f, -0.5f),
        Vec3( 0.5f,  0.5f, -0.5f), Vec3(-0.5f,  0.5f, -0.5f),
        Vec3(-0.5f, -0.5f,  0.5f), Vec3( 0.5f, -0.5f,  0.5f),
        Vec3( 0.5f,  0.5f,  0.5f), Vec3(-0.5f,  0.5f,  0.5f),
        Vec3(2.5f, -0.5f, -0.5f), Vec3(3.5f, -0.5f, -0.5f),
        Vec3(3.5f,  0.5f, -0.5f), Vec3(2.5f,  0.5f, -0.5f),
        Vec3(2.5f, -0.5f,  0.5f), Vec3(3.5f, -0.5f,  0.5f),
        Vec3(3.5f,  0.5f,  0.5f), Vec3(2.5f,  0.5f,  0.5f),
    ];
    m.addFace([0, 3, 2, 1]);  m.addFace([4, 5, 6, 7]);
    m.addFace([0, 4, 7, 3]);  m.addFace([1, 2, 6, 5]);
    m.addFace([3, 7, 6, 2]);  m.addFace([0, 1, 5, 4]);
    m.addFace([8, 11, 10, 9]);   m.addFace([12, 13, 14, 15]);
    m.addFace([8, 12, 15, 11]);  m.addFace([9, 10, 14, 13]);
    m.addFace([11, 15, 14, 10]); m.addFace([8, 9, 13, 12]);
    m.buildLoops();
    return m;
}

// (b)+(c) Two distinct non-crossing rings: Count==N gives exactly N loops
// per ring (total inserted == N × 2 rings); a 2nd seed edge landing on the
// SAME ring as a 1st dedups to one cut, not a doubled one.
unittest {
    // (b) — one seed per cube, N=2 loops each.
    {
        Mesh m = makeTwoDisjointCubes();
        uint eiA = m.edgeIndex(0, 1);   // cube A belt seed
        uint eiB = m.edgeIndex(8, 9);   // cube B belt seed (translated analog)
        assert(eiA != ~0u && eiB != ~0u, "both cube belt seeds must exist");

        uint[] newFaceIndices;
        bool ok = m.insertEdgeLoopsMulti([eiA, eiB], [0.3f, 0.7f], newFaceIndices);
        assert(ok, "insertEdgeLoopsMulti must succeed on two disjoint cubes");

        // Each cube independently: single-ring insert of count=2 gives
        // V:8->8+2*4=16(2 rails*... wait computed inline below), matched
        // against the SAME single-ring kernel run on one cube alone.
        Mesh ref1 = makeCube();
        uint eiRef = ref1.edgeIndex(0, 1);
        bool okRef = ref1.insertEdgeLoops(eiRef, [0.3f, 0.7f]);
        assert(okRef, "reference single-cube insert must succeed");

        assert(m.vertices.length == 2 * ref1.vertices.length,
               "two independent rings: total V must be 2x the single-cube result");
        assert(m.faces.length == 2 * ref1.faces.length,
               "two independent rings: total F must be 2x the single-cube result");
        assert(m.edges.length == 2 * ref1.edges.length,
               "two independent rings: total E must be 2x the single-cube result");

        // Count=2 (P=2 loops) → P+1=3 sub-quads per ring face; ringLen=4
        // faces per ring; 2 distinct (disjoint) rings.
        enum ringLen = 4;
        enum subQuadsPerFace = 3;   // positions.length + 1
        assert(newFaceIndices.length == 2 * (subQuadsPerFace * ringLen),
               "Count=2 per ring, 2 distinct rings: newFaceIndices must total "
               ~ "2 * (P+1) * ringLen");
    }

    // (c) — dedup: a 2nd seed edge on the SAME ring as the 1st must NOT
    // double the cut. Edge (0,1) and edge (2,3) are both members of cube A's
    // belt ring (see the closed-ring unittest above — rung mA-mB-mC-mD
    // includes both edge 0-1's and edge 2-3's midpoints).
    {
        Mesh m = makeTwoDisjointCubes();
        uint ei01 = m.edgeIndex(0, 1);
        uint ei23 = m.edgeIndex(2, 3);
        assert(ei01 != ~0u && ei23 != ~0u, "both same-ring seeds must exist");

        uint[] newFaceIndices;
        bool ok = m.insertEdgeLoopsMulti([ei01, ei23], [0.5f], newFaceIndices);
        assert(ok, "insertEdgeLoopsMulti must succeed with 2 same-ring seeds");

        Mesh single = makeTwoDisjointCubes();
        uint eiSingle = single.edgeIndex(0, 1);
        bool okSingle = single.insertEdgeLoops(eiSingle, [0.5f]);
        assert(okSingle, "single-seed reference insert must succeed");

        assert(m.vertices.length == single.vertices.length,
               "dedup: 2 seeds on the same ring must produce the SAME vertex count as 1 seed");
        assert(m.faces.length == single.faces.length,
               "dedup: 2 seeds on the same ring must produce the SAME face count as 1 seed");
        assert(m.edges.length == single.edges.length,
               "dedup: 2 seeds on the same ring must produce the SAME edge count as 1 seed");
    }
}

// insertEdgeLoopsMulti — duplicate CUT POSITION dedup (task 0308, fuzz-found).
//
// Definitive repro: select edge 0, tool.set mesh.loopSliceTool, mode Free,
// position 0.5, then insertAt 0.5 — Free mode does not enforce distinct
// slice fractions, so `positions_` ends up `[0.5, 0.5]` (two IDENTICAL cut
// fractions on the same seed ring) and reached the kernel unchanged.
// `getMids` independently `addVertex`'d once PER entry in `positions`, so
// each of the ring's 4 rails grew TWO coincident vertices (same world
// position, distinct indices) instead of one, and the sub-quad chain built
// a zero-area quad between each coincident pair — 16v/28e/14f instead of a
// clean single cut's 12v/20e/10f (4 exact-coincident vertex pairs + 4
// zero-area faces). This is a DIFFERENT failure mode than the 0303
// `edgeSliceEx` atomicity bug (that one was a Pass-1/Pass-2 rollback gap on
// a legitimate no-split outcome; this one is a degenerate INPUT — duplicate
// cut fractions — that the kernel must dedup before creating any vertex).
unittest {
    Mesh dup = makeCube();
    uint eiDup = dup.edgeIndex(0, 1);
    assert(eiDup != ~0u, "seed edge 0-1 must exist on cube");
    uint[] nfDup;
    bool okDup = dup.insertEdgeLoopsMulti([eiDup], [0.5f, 0.5f], nfDup);
    assert(okDup, "duplicate cut positions must still succeed (clean single cut)");

    Mesh clean = makeCube();
    uint eiClean = clean.edgeIndex(0, 1);
    uint[] nfClean;
    bool okClean = clean.insertEdgeLoopsMulti([eiClean], [0.5f], nfClean);
    assert(okClean, "single-position reference insert must succeed");

    assert(dup.vertices.length == clean.vertices.length,
           "a duplicate cut position must NOT add extra (coincident) vertices");
    assert(dup.faces.length == clean.faces.length,
           "a duplicate cut position must NOT add extra (zero-area) faces");
    assert(dup.edges.length == clean.edges.length,
           "a duplicate cut position must NOT add extra edges");
    assert(nfDup.length == nfClean.length,
           "newFaceIndices must report the same sub-quad count as the deduped single cut");

    // No two vertices may be exactly coincident (the concrete symptom: 4
    // coincident vertex PAIRS at the 4 rail midpoints).
    foreach (i; 0 .. dup.vertices.length)
        foreach (j; i + 1 .. dup.vertices.length)
            assert((dup.vertices[i] - dup.vertices[j]).length() > 1e-5f,
                   "no two vertices may sit at the exact same world position");

    // No zero-area faces (the concrete symptom: 4 degenerate quads spliced
    // between each coincident vertex pair).
    import std.conv : to;
    foreach (fi, f; dup.faces) {
        Vec3 centroid = Vec3(0, 0, 0);
        foreach (vi; f) centroid = centroid + dup.vertices[vi];
        centroid = centroid * (1.0f / f.length);
        float area = 0.0f;
        foreach (k; 0 .. f.length) {
            Vec3 a = dup.vertices[f[k]] - centroid;
            Vec3 b = dup.vertices[f[(k + 1) % f.length]] - centroid;
            area += cross(a, b).length();
        }
        area *= 0.5f;
        assert(area > 1e-6f, "face " ~ fi.to!string ~ " must not be zero-area");
    }

    // Euler characteristic must stay 2 (a closed watertight solid).
    assert(cast(long)dup.vertices.length - cast(long)dup.edges.length
           + cast(long)dup.faces.length == 2,
           "Euler characteristic must stay 2 after a deduped single cut");

    // count=N under Free mode: 3 slots defaulting to 0.5 (the mode-law
    // no-op path noted in the task) must collapse the SAME way as an
    // explicit [0.5, 0.5, 0.5].
    Mesh triple = makeCube();
    uint eiTriple = triple.edgeIndex(0, 1);
    uint[] nfTriple;
    bool okTriple = triple.insertEdgeLoopsMulti([eiTriple], [0.5f, 0.5f, 0.5f], nfTriple);
    assert(okTriple, "triple-duplicate cut positions must still succeed");
    assert(triple.vertices.length == clean.vertices.length
           && triple.faces.length == clean.faces.length
           && triple.edges.length == clean.edges.length,
           "N-way duplicate cut positions must collapse to the SAME clean single cut");
}

// insertEdgeLoopsMulti — Slice Selected restriction (task 0248). Seed edge
// (0,1) crosses the belt ring {front(0), top(4), back(1), bottom(5)} of the
// default cube. Restricting the cut to faces {0,5} (front + bottom) must slice
// ONLY those two, absorbing the terminating midpoints into their unsliced belt
// neighbours (top, back) as n-gons — a watertight partial cut.
unittest {
    import std.math : abs;
    static bool hasVertNear(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x - p.x) < eps && abs(v.y - p.y) < eps && abs(v.z - p.z) < eps)
                return true;
        return false;
    }

    // Whole-ring baseline (restrictFaces = null) — 4 belt faces sliced.
    Mesh whole = makeCube();
    uint eiW = whole.edgeIndex(0, 1);
    uint[] nfW;
    assert(whole.insertEdgeLoopsMulti([eiW], [0.5f], nfW),
           "whole-ring insert must succeed");
    assert(whole.vertices.length == 12,
           "whole ring: 8 + 4 belt midpoints = 12 verts");
    assert(whole.faces.length == 10,
           "whole ring: 4 sliced belt faces (×2) + 2 caps = 10 faces");

    // Restricted to {front=0, bottom=5}: only those two are sliced; top+back
    // absorb the boundary midpoints → 3 new verts, 8 faces.
    Mesh restr = makeCube();
    uint eiR = restr.edgeIndex(0, 1);
    uint[] nfR;
    assert(restr.insertEdgeLoopsMulti([eiR], [0.5f], nfR, [0u, 5u]),
           "restricted insert must succeed");
    assert(restr.vertices.length == 11,
           "restricted: 8 + 3 (two boundary + one shared seed) midpoints = 11 verts");
    assert(restr.faces.length == 8,
           "restricted: front+bottom sliced (4 quads) + top/back n-gons + left/right = 8");

    // The three midpoints that MUST exist (seed + two selection-border rails).
    assert(hasVertNear(restr, Vec3( 0.0f, -0.5f, -0.5f)), "seed midpoint present");
    assert(hasVertNear(restr, Vec3( 0.0f,  0.5f, -0.5f)), "front→top border midpoint present");
    assert(hasVertNear(restr, Vec3( 0.0f, -0.5f,  0.5f)), "bottom→back border midpoint present");
    // The whole-ring-only midpoint on the top-back edge must be ABSENT — the
    // cut never reached that edge because neither incident face was selected.
    assert(!hasVertNear(restr, Vec3(0.0f, 0.5f, 0.5f)),
           "top-back midpoint must NOT appear under Slice Selected");

    // newFaceIndices reports only the CREATED sub-quads (front+bottom = 4),
    // not the absorbed n-gon neighbours (modified originals).
    assert(nfR.length == 4,
           "restricted newFaceIndices = 4 sliced sub-quads (2 faces × 2 each)");
}

// insertEdgeLoopsMulti — Keep Quads is a NO-OP under watertight-by-default. A
// planar strip of two quads Q0=[0,1,4,3], Q1=[1,2,5,4] capped by a triangle
// T=[2,6,5]. The seed edge (1,4) makes the quad ring walk {Q0,Q1} and TERMINATE
// at the non-quad T — an OPEN ring. Since the default now absorbs the terminating
// midpoint at that non-quad neighbour, BOTH Keep Quads OFF and ON produce the
// SAME watertight all-quad result (10 verts / 5 faces / 14 edges; T absorbs the
// midpoint → the quad [2,6,5,mid]; the full edge (2,5) is gone). This matches the
// reference (Keep Quads on == off). `quad` is retained only for panel parity.
unittest {
    static Mesh makeStrip() {
        Mesh m;
        m.vertices = [
            Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),      // v0 v1 v2
            Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0),      // v3 v4 v5
            Vec3(3,0.5f,0),                             // v6 triangle apex
        ];
        m.addFace([0u,1u,4u,3u]);   // Q0
        m.addFace([1u,2u,5u,4u]);   // Q1
        m.addFace([2u,6u,5u]);      // T (triangle)
        m.rebuildEdges();
        m.buildLoops();
        return m;
    }

    // Keep Quads OFF (default) — the open ring absorbs the terminating midpoint
    // by default → T becomes the quad [2,6,5,mid], watertight, no T-junction.
    Mesh off = makeStrip();
    uint eiOff = off.edgeIndex(1, 4);
    assert(eiOff != ~0u, "seed edge (1,4) must exist");
    uint[] nfOff;
    assert(off.insertEdgeLoopsMulti([eiOff], [0.5f], nfOff, null, /*keepQuads*/false),
           "keep-quads-off insert must succeed");
    assert(off.vertices.length == 10, "off: 7 + 3 midpoints = 10 verts");
    assert(off.faces.length == 5,     "off: Q0×2 + Q1×2 + T(now quad) = 5 faces");
    assert(off.edges.length == 14,    "off: 14 edges (default absorbs the midpoint — watertight)");
    // The full seed-exit edge (v2..v5) is GONE — T absorbed the midpoint by default.
    assert(off.edgeIndex(2, 5) == ~0u,
           "off: full exit edge (2,5) removed (non-quad T absorbed the midpoint by default)");

    // Keep Quads ON — geometric no-op: identical watertight result.
    Mesh on = makeStrip();
    uint eiOn = on.edgeIndex(1, 4);
    uint[] nfOn;
    assert(on.insertEdgeLoopsMulti([eiOn], [0.5f], nfOn, null, /*keepQuads*/true),
           "keep-quads-on insert must succeed");
    assert(on.vertices.length == 10, "on: identical vertex set (10 verts)");
    assert(on.faces.length == 5,     "on: same 5 faces (T is a quad)");
    assert(on.edges.length == 14,    "on: 14 edges (no-op — same as OFF)");
    // The full exit edge (2,5) is GONE — T references (2,mid) and (mid,5).
    assert(on.edgeIndex(2, 5) == ~0u,
           "on: full exit edge (2,5) removed (identical to OFF)");
    // Both created only the 4 sub-quads of Q0+Q1; the absorbed T is excluded.
    assert(nfOn.length == 4,  "on: newFaceIndices = 4 created sub-quads (T excluded)");
    assert(nfOff.length == 4, "off: newFaceIndices = 4 created sub-quads (T excluded)");
}

// insertEdgeLoopsMulti — Slice N-gon guard (task 0250). A planar horizontal
// strip Q0=[0,1,6,5], Q1=[1,2,7,6], a HEXAGON H=[2,10,3,8,11,7] (top+bottom
// split at x=2.5), Q2=[3,4,9,8]. Seed = the vertical edge (1,6) between the two
// left quads. The quad ring walks left to the boundary (via Q0) and right into
// H. With ngon OFF (default) the ring TERMINATES at the hexagon → only {Q0,Q1}
// are sliced (H, Q2 untouched; the exit rail leaves a T-junction against H).
// With ngon ON the ring CROSSES the hexagon (chord between its two vertical-edge
// midpoints) and reaches Q2 → {Q0,Q1,H,Q2} all sliced. Countable proof: OFF =
// 15 verts / 20 edges / 6 faces (watertight-by-default: the terminating midpoint
// is absorbed into the hexagon → 7-gon, no T-junction); ON = 17 verts / 24 edges
// / 8 faces.
unittest {
    import std.math : abs;
    static bool hasV(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x-p.x) < eps && abs(v.y-p.y) < eps && abs(v.z-p.z) < eps)
                return true;
        return false;
    }
    static Mesh makeStrip() {
        Mesh m;
        m.vertices = [
            Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0), Vec3(3,0,0), Vec3(4,0,0), // v0..v4
            Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0), Vec3(3,1,0), Vec3(4,1,0), // v5..v9
            Vec3(2.5f,0,0), Vec3(2.5f,1,0),                                  // v10 BM, v11 TM
        ];
        m.addFace([0u,1u,6u,5u]);         // Q0
        m.addFace([1u,2u,7u,6u]);         // Q1
        m.addFace([2u,10u,3u,8u,11u,7u]); // H (hexagon)
        m.addFace([3u,4u,9u,8u]);         // Q2
        m.rebuildEdges();
        m.buildLoops();
        return m;
    }

    // ngon OFF (default) — ring terminates at the hexagon; only Q0,Q1 sliced, but
    // the hexagon ABSORBS the terminating midpoint by default (7-gon, watertight).
    Mesh off = makeStrip();
    uint eiOff = off.edgeIndex(1, 6);
    assert(eiOff != ~0u, "seed edge (1,6) must exist");
    uint[] nfOff;
    assert(off.insertEdgeLoopsMulti([eiOff], [0.5f], nfOff, null, false, /*ngon*/false),
           "ngon-off insert must succeed");
    assert(off.vertices.length == 15, "off: 12 + 3 midpoints = 15 verts");
    assert(off.edges.length    == 20, "off: 20 edges (hexagon absorbs the terminating midpoint — watertight)");
    assert(off.faces.length    == 6,  "off: Q0×2 + Q1×2 + H(7-gon) + Q2 = 6 faces");
    // The hexagon + Q2 rails were never traversed — no midpoints there.
    assert(!hasV(off, Vec3(3,0.5f,0)), "off: hexagon exit rail NOT cut");
    assert(!hasV(off, Vec3(4,0.5f,0)), "off: Q2 rail NOT cut (ring stopped at hexagon)");
    // The exit edge into the hexagon is GONE — the hexagon absorbed the midpoint
    // (its boundary edge (2,7) split into (2,mid),(mid,7)), so the cut is watertight.
    assert(off.edgeIndex(2, 7) == ~0u, "off: full edge (2,7) removed (hexagon absorbed the midpoint)");
    assert(nfOff.length == 4, "off: 4 created sub-quads (Q0+Q1); absorbed hexagon excluded");

    // ngon ON — ring crosses the hexagon and reaches Q2; all four faces sliced.
    Mesh on = makeStrip();
    uint eiOn = on.edgeIndex(1, 6);
    uint[] nfOn;
    assert(on.insertEdgeLoopsMulti([eiOn], [0.5f], nfOn, null, false, /*ngon*/true),
           "ngon-on insert must succeed");
    assert(on.vertices.length == 17, "on: 12 + 5 midpoints = 17 verts");
    assert(on.edges.length    == 24, "on: 24 edges (watertight crossing, no T-junction)");
    assert(on.faces.length    == 8,  "on: Q0×2 + Q1×2 + H×2 + Q2×2 = 8 faces");
    // The hexagon was traversed: its two vertical-edge midpoints now exist and
    // the exit-into-hexagon edge is gone (replaced by the two half-edges).
    assert(hasV(on, Vec3(3,0.5f,0)), "on: hexagon exit rail midpoint present");
    assert(hasV(on, Vec3(4,0.5f,0)), "on: Q2 rail cut (ring reached past hexagon)");
    assert(on.edgeIndex(2, 7) == ~0u, "on: full edge (2,7) gone (hexagon sliced)");
    assert(on.edgeIndex(3, 8) == ~0u, "on: full edge (3,8) gone (hexagon+Q2 sliced)");
    // Hexagon chord split emits 2 sub-faces; Q0,Q1,Q2 emit 2 each = 8 total.
    assert(nfOn.length == 8, "on: 8 created sub-faces across the 4 ring faces");
}

// insertEdgeLoopsMulti — Split guard (task 0251). A unit cube, seed = the
// equatorial belt edge (0,1); the ring cuts a horizontal loop around the 4 side
// faces (4 rails → 4 midpoints). Split OFF keeps ONE connected loop (watertight
// closed cube: 0 boundary edges, 1 component). Split ON DUPLICATES each rail
// midpoint (+4 verts, +4 edges, SAME face count) so the single loop becomes TWO
// boundary edge-loops → 8 boundary edges + 2 disconnected shells. The seam pairs
// (splitPairsOut) list each coincident [lo,hi] duplicate for Cap/Gap (0252/0253).
unittest {
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
    // Connected-component count over faces joined by any shared vertex.
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

    // Split OFF (default) — one connected loop, closed manifold cube.
    Mesh off = makeCube();
    uint eiOff = off.edgeIndex(0, 1);
    assert(eiOff != ~0u, "cube seed edge (0,1) must exist");
    uint[] nfOff;
    assert(off.insertEdgeLoopsMulti([eiOff], [0.5f], nfOff, null, false, false, /*split*/false),
           "split-off insert must succeed");
    immutable offV = off.vertices.length, offE = off.edges.length, offF = off.faces.length;
    assert(boundaryEdgeCount(off) == 0, "split off: closed cube, no boundary edges");
    assert(componentCount(off) == 1, "split off: one connected shell");

    // Split ON — each rail midpoint duplicated → two disconnected boundary loops.
    Mesh on = makeCube();
    uint eiOn = on.edgeIndex(0, 1);
    uint[] nfOn;
    uint[2][] pairs;
    assert(on.insertEdgeLoopsMulti([eiOn], [0.5f], nfOn, null, false, false, /*split*/true, /*caps*/false, &pairs),
           "split-on insert must succeed");
    assert(on.vertices.length == offV + 4, "split on: 4 rail midpoints duplicated");
    assert(on.edges.length    == offE + 4, "split on: 4 loop edges doubled into boundaries");
    assert(on.faces.length    == offF,     "split on: splitting duplicates verts, not faces");
    assert(boundaryEdgeCount(on) == 8, "split on: two 4-edge boundary loops (8 boundary edges)");
    assert(componentCount(on) == 2, "split on: two disconnected shells");
    assert(nfOn.length == nfOff.length, "split on: same created sub-face count as off");

    // Seam pairs: one [lo,hi] per duplicated rail midpoint, coincident + distinct.
    assert(pairs.length == 4, "split on: 4 seam pairs (one per rail midpoint)");
    foreach (pr; pairs) {
        assert(pr[0] != pr[1], "seam lo/hi must be distinct verts");
        Vec3 a = on.vertices[pr[0]], b = on.vertices[pr[1]];
        assert(abs(a.x-b.x) < 1e-6f && abs(a.y-b.y) < 1e-6f && abs(a.z-b.z) < 1e-6f,
               "seam lo/hi coincide (zero gap — Gap/0253 moves them apart later)");
    }

    // Split OFF emits no seam pairs even when a splitPairsOut sink is given.
    Mesh off2 = makeCube();
    uint[] nf2;
    uint[2][] pairs2;
    off2.insertEdgeLoopsMulti([off2.edgeIndex(0, 1)], [0.5f], nf2, null, false, false, false, /*caps*/false, &pairs2);
    assert(pairs2.length == 0, "split off: no seam pairs emitted");
}

// insertEdgeLoopsMulti — Cap Sections guard (task 0252, geometry corrected by the
// LIVE reference capture in task 0261). Same unit cube + equatorial seed (0,1); the
// ring cuts a belt around the 4 side faces (4 rails → 4 duplicated lo/hi pairs under
// Split). Split ON + caps OFF is exactly 0251's result: 8 boundary edges, 2
// disconnected shells. Split ON + caps ON seals EACH shell's boundary loop with ONE
// cap polygon (the reference-captured behaviour: the cube belt yields +2 faces, one
// per shell — NOT the pre-0261 ring of 4 bridging quads). Each cap closes its loop
// (boundary edges 8→0) but the two shells stay DISCONNECTED (each becomes an
// independent closed solid): +2 faces, NO new edges (cap edges reuse the shell
// boundary edges), NO new verts. caps is a no-op when Split is off (byte-for-byte).
unittest {
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

    // Split ON, caps OFF — open sections (0251's split-on topology).
    Mesh open = makeCube();
    uint eiO = open.edgeIndex(0, 1);
    assert(eiO != ~0u, "cube seed edge (0,1) must exist");
    uint[] nfOpen;
    assert(open.insertEdgeLoopsMulti([eiO], [0.5f], nfOpen, null, false, false, /*split*/true, /*caps*/false),
           "split-on caps-off insert must succeed");
    immutable openV = open.vertices.length, openE = open.edges.length, openF = open.faces.length;
    assert(boundaryEdgeCount(open) == 8, "caps off: two 4-edge boundary loops (8 boundary edges)");
    assert(componentCount(open) == 2, "caps off: two disconnected shells");

    // Split ON, caps ON — cap ring closes both boundary loops.
    Mesh capped = makeCube();
    uint eiC = capped.edgeIndex(0, 1);
    uint[] nfCap;
    assert(capped.insertEdgeLoopsMulti([eiC], [0.5f], nfCap, null, false, false, /*split*/true, /*caps*/true),
           "split-on caps-on insert must succeed");
    assert(capped.vertices.length == openV,     "caps on: adds NO new vertices");
    assert(capped.faces.length    == openF + 2, "caps on: +2 cap polys (one per shell loop)");
    assert(capped.edges.length    == openE,     "caps on: cap edges reuse the boundary edges (no new edges)");
    assert(boundaryEdgeCount(capped) == 0, "caps on: both boundary loops closed (0 boundary edges)");
    assert(componentCount(capped) == 2, "caps on: caps seal each shell — two shells stay disconnected");
    // Two closed genus-0 shells → V-E+F = 2 per shell = 4 total.
    assert(cast(long)capped.vertices.length - cast(long)capped.edges.length
           + cast(long)capped.faces.length == 4, "caps on: two closed manifolds, V-E+F = 4");
    // The 2 cap polys are reported as new polys (Select-New selects them).
    assert(nfCap.length == nfOpen.length + 2, "caps on: 2 extra new faces vs caps-off");

    // caps is a no-op when Split is off (byte-for-byte the connected loop).
    Mesh nosplit = makeCube();
    uint[] nfNo;
    assert(nosplit.insertEdgeLoopsMulti([nosplit.edgeIndex(0, 1)], [0.5f], nfNo, null, false, false, /*split*/false, /*caps*/true),
           "caps-on split-off insert must succeed");
    assert(boundaryEdgeCount(nosplit) == 0 && componentCount(nosplit) == 1,
           "caps no-op with Split off: still the closed connected cube");
    assert(nosplit.faces.length == openF, "caps no-op with Split off: no cap faces added");
}

// insertEdgeLoopsMulti — Gap guard (task 0253; direction confirmed by the LIVE
// reference capture in task 0261). Same unit cube + equatorial seed (0,1); Split ON
// duplicates each rail midpoint into a coincident lo/hi pair and Caps ON seals each
// shell's loop with one cap polygon. Gap pushes each seam pair apart by `gap`
// (±gap/2, symmetric) ALONG THE RAIL — the reference does exactly this: the two
// shells separate along the loop rail (±Y on the cube), opening a real visible band
// between the two caps. gap=0 leaves the pairs COINCIDENT (byte-for-byte 0251/0252);
// gap=G separates every [lo,hi] pair by EXACTLY G and pulls the two caps G apart.
// Topology is identical to the gap=0 caps-on case either way (Gap only moves verts).
unittest {
    import std.math : abs, sqrt;
    static Vec3 faceCentroid(ref Mesh m, uint fi) {
        auto f = m.faces[fi];
        Vec3 c = Vec3(0, 0, 0);
        foreach (vi; f) c = c + m.vertices[vi];
        return c * (1.0f / cast(float)f.length);
    }

    enum float G = 0.2f;

    // gap=0 baseline (== the caps-on result): 4 seam pairs still coincident.
    Mesh z = makeCube();
    uint eiZ = z.edgeIndex(0, 1);
    assert(eiZ != ~0u, "cube seed edge (0,1) must exist");
    uint[] nfZ; uint[2][] prZ;
    assert(z.insertEdgeLoopsMulti([eiZ], [0.5f], nfZ, null, false, false,
                                  /*split*/true, /*caps*/true, &prZ, /*gap*/0.0f),
           "split+caps, gap=0 insert must succeed");
    immutable zV = z.vertices.length, zE = z.edges.length, zF = z.faces.length;
    assert(prZ.length == 4, "gap=0: 4 seam pairs");
    foreach (pr; prZ) {
        Vec3 a = z.vertices[pr[0]], b = z.vertices[pr[1]];
        assert(abs(a.x-b.x) < 1e-6f && abs(a.y-b.y) < 1e-6f && abs(a.z-b.z) < 1e-6f,
               "gap=0: seam lo/hi still coincide");
    }

    // gap=G opens the pairs: same topology, each pair separated by EXACTLY G.
    Mesh g = makeCube();
    uint eiG = g.edgeIndex(0, 1);
    uint[] nfG; uint[2][] prG;
    assert(g.insertEdgeLoopsMulti([eiG], [0.5f], nfG, null, false, false,
                                  /*split*/true, /*caps*/true, &prG, /*gap*/G),
           "split+caps, gap>0 insert must succeed");
    // Topology unchanged by Gap (positions only).
    assert(g.vertices.length == zV && g.edges.length == zE && g.faces.length == zF,
           "gap>0: topology identical to gap=0 (Gap relocates verts only)");
    assert(prG.length == 4, "gap>0: 4 seam pairs");
    foreach (pr; prG) {
        Vec3 a = g.vertices[pr[0]], b = g.vertices[pr[1]];
        float d = sqrt((a.x-b.x)*(a.x-b.x) + (a.y-b.y)*(a.y-b.y) + (a.z-b.z)*(a.z-b.z));
        assert(abs(d - G) < 1e-5f, "gap>0: seam lo/hi separated by exactly G");
    }
    // The two cap polys (the last 2 created faces) are full-area quads in the
    // loop's plane in BOTH cases (unlike the pre-0261 zero-area bridging quads).
    // At gap=0 the two caps are COINCIDENT (same centroid); at gap=G they are pulled
    // exactly G apart along the rail — the real visible band the reference opens.
    assert(nfG.length >= 2, "gap>0: cap faces reported as new polys");
    uint capA = nfG[$ - 2], capB = nfG[$ - 1];
    Vec3 zc0 = faceCentroid(z, capA), zc1 = faceCentroid(z, capB);
    float dZero = (zc0 - zc1).length;
    assert(dZero < 1e-6f, "gap=0: the two shell caps are coincident");
    Vec3 gc0 = faceCentroid(g, capA), gc1 = faceCentroid(g, capB);
    float dGap = (gc0 - gc1).length;
    assert(abs(dGap - G) < 1e-5f, "gap>0: the two shell caps pulled exactly G apart");
}

// insertEdgeLoopsMulti — Preserve Curvature guard (task 0254). A CURVED open strip
// of 3 quads whose column heights arc h=[0,1,1,0]; seed = the middle quad's top
// long edge (2,4), giving a 1-face open ring that cuts Q1's two long rails (both at
// y=1, but curved — their cage neighbours drop to y=0 on each side). With curvature
// OFF (default) each new loop vert is the LINEAR chord midpoint (y=1.0 exactly).
// With curvature ON it is placed on the chord-weighted Catmull-Rom spline through the
// four cage points P0=(0,0,*),va,vb,P3=(3,0,*): at t=0.5 the spline bulges the flat
// chord UP to y=1+(√2−1)/4=1.1035534 (LIVE-corrected, task 0263; x/z unchanged) —
// measurably off the chord. Topology is identical
// either way (Curvature relocates the new verts only). A FLAT strip (heights all 0)
// proves ON is a no-op there: the four spline points are collinear ⇒ spline == chord.
unittest {
    import std.math : abs;
    static bool hasV(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x-p.x) < eps && abs(v.y-p.y) < eps && abs(v.z-p.z) < eps)
                return true;
        return false;
    }
    static Mesh makeArcStrip(float h1, float h2) {
        // Columns at x=0..3, rows z=0/1, column heights [0, h1, h2, 0].
        Mesh m;
        m.vertices = [
            Vec3(0,0,0),  Vec3(0,0,1),
            Vec3(1,h1,0), Vec3(1,h1,1),
            Vec3(2,h2,0), Vec3(2,h2,1),
            Vec3(3,0,0),  Vec3(3,0,1),
        ];
        m.addFace([0u,2u,3u,1u]);   // Q0 (cols 0-1)
        m.addFace([2u,4u,5u,3u]);   // Q1 (cols 1-2) — the cut face
        m.addFace([4u,6u,7u,5u]);   // Q2 (cols 2-3)
        m.rebuildEdges();
        m.buildLoops();
        return m;
    }

    // curvature OFF (default) — linear chord midpoints at y=1.0.
    Mesh off = makeArcStrip(1.0f, 1.0f);
    uint eiOff = off.edgeIndex(2, 4);
    assert(eiOff != ~0u, "seed edge (2,4) must exist");
    uint[] nfOff;
    assert(off.insertEdgeLoopsMulti([eiOff], [0.5f], nfOff, null, false, false,
                                    false, false, null, 0.0f, /*curvature*/false),
           "curvature-off insert must succeed");
    assert(off.vertices.length == 10, "off: 8 + 2 midpoints = 10 verts");
    assert(off.edges.length    == 13, "off: 13 edges");
    assert(off.faces.length    == 4,  "off: Q0 + Q1×2 + Q2 = 4 faces");
    assert(hasV(off, Vec3(1.5f, 1.0f, 0)), "off: rail (2,4) midpoint on the flat chord (y=1)");
    assert(hasV(off, Vec3(1.5f, 1.0f, 1)), "off: rail (3,5) midpoint on the flat chord (y=1)");
    assert(!hasV(off, Vec3(1.5f, 1.1035534f, 0)), "off: no bulged vert (linear placement)");

    // curvature ON — chord-weighted Catmull-Rom spline bulges the midpoints to
    // y=1+(√2−1)/4=1.1035534 (LIVE-captured reference value, task 0263).
    Mesh on = makeArcStrip(1.0f, 1.0f);
    uint eiOn = on.edgeIndex(2, 4);
    uint[] nfOn;
    assert(on.insertEdgeLoopsMulti([eiOn], [0.5f], nfOn, null, false, false,
                                   false, false, null, 0.0f, /*curvature*/true),
           "curvature-on insert must succeed");
    // Topology IDENTICAL to the off case (curvature relocates verts only).
    assert(on.vertices.length == 10 && on.edges.length == 13 && on.faces.length == 4,
           "on: topology identical to curvature-off (positions only)");
    assert(hasV(on, Vec3(1.5f, 1.1035534f, 0)), "on: rail (2,4) midpoint bulged off the chord to y=1.1035534");
    assert(hasV(on, Vec3(1.5f, 1.1035534f, 1)), "on: rail (3,5) midpoint bulged off the chord to y=1.1035534");
    assert(!hasV(on, Vec3(1.5f, 1.0f, 0)), "on: chord midpoint replaced by the bulged spline point");

    // Tension (task 0255) scales the bulge: result = lerp + tension·(spline − lerp).
    // At tension=1.0 the bulge is the full 1.1035534 (above); at tension=0.5 it is
    // halfway between the flat chord (1.0) and the full spline ⇒ y=1.0517767; at
    // tension=0.0 it collapses to the linear chord (y=1.0) — byte-for-byte the
    // curvature-OFF placement even though `curvature` is ON.
    Mesh half = makeArcStrip(1.0f, 1.0f);
    uint eiHalf = half.edgeIndex(2, 4);
    uint[] nfHalf;
    assert(half.insertEdgeLoopsMulti([eiHalf], [0.5f], nfHalf, null, false, false,
                                     false, false, null, 0.0f, /*curvature*/true,
                                     /*curveTension*/0.5f),
           "curvature-on tension=0.5 insert must succeed");
    assert(hasV(half, Vec3(1.5f, 1.0517767f, 0)), "tension=0.5: rail (2,4) midpoint at the half bulge (y=1.0517767)");
    assert(hasV(half, Vec3(1.5f, 1.0517767f, 1)), "tension=0.5: rail (3,5) midpoint at the half bulge (y=1.0517767)");

    Mesh zero = makeArcStrip(1.0f, 1.0f);
    uint eiZero = zero.edgeIndex(2, 4);
    uint[] nfZero;
    assert(zero.insertEdgeLoopsMulti([eiZero], [0.5f], nfZero, null, false, false,
                                     false, false, null, 0.0f, /*curvature*/true,
                                     /*curveTension*/0.0f),
           "curvature-on tension=0.0 insert must succeed");
    assert(hasV(zero, Vec3(1.5f, 1.0f, 0)) && hasV(zero, Vec3(1.5f, 1.0f, 1)),
           "tension=0.0: curvature ON collapses to the linear chord (y=1.0)");
    assert(!hasV(zero, Vec3(1.5f, 1.1035534f, 0)), "tension=0.0: no bulge");

    // curvature ON on a FLAT cage (all heights 0) — the four spline points are
    // collinear, so the spline equals the linear chord: no-op vs off.
    Mesh flat = makeArcStrip(0.0f, 0.0f);
    uint eiFlat = flat.edgeIndex(2, 4);
    uint[] nfFlat;
    assert(flat.insertEdgeLoopsMulti([eiFlat], [0.5f], nfFlat, null, false, false,
                                     false, false, null, 0.0f, /*curvature*/true),
           "curvature-on flat-cage insert must succeed");
    assert(hasV(flat, Vec3(1.5f, 0, 0)) && hasV(flat, Vec3(1.5f, 0, 1)),
           "flat cage: curvature ON leaves the midpoints on the (straight) chord");
}

// insertEdgeLoopsMulti — 1D profile cutter (task 0256). A FLAT strip of 3 quads
// in the XZ plane (all normal +Y); seed = the middle quad's rail edge (2,4).
// Feeding a Vee profile (3 loops at along-cut fractions t=[0.25,0.5,0.75] with
// normalized heights h=[0.5,1.0,0.5]) and Inset depth D presses a V into the
// surface: each rail midpoint at fraction t is lifted along +Y by h·D. With
// profileHeights=null (flat, default) the same 3 positions stay ON the surface
// (byte-for-byte the multi-loop flat cut). With depth=0 a non-flat profile is
// ALSO a no-op (loops stay on the surface). Topology is identical in every case
// (3 loops ⇒ same vert/edge/face counts) — profile relocates verts only.
unittest {
    import std.math : abs;
    static bool hasV(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x-p.x) < eps && abs(v.y-p.y) < eps && abs(v.z-p.z) < eps)
                return true;
        return false;
    }
    static Mesh makeFlatStrip() {
        // Columns x=0..3, rows z=0/1, all y=0 (planar, normal +Y).
        Mesh m;
        m.vertices = [
            Vec3(0,0,0), Vec3(0,0,1),
            Vec3(1,0,0), Vec3(1,0,1),
            Vec3(2,0,0), Vec3(2,0,1),
            Vec3(3,0,0), Vec3(3,0,1),
        ];
        m.addFace([0u,2u,3u,1u]);   // Q0
        m.addFace([2u,4u,5u,3u]);   // Q1 — the cut face
        m.addFace([4u,6u,7u,5u]);   // Q2
        m.rebuildEdges();
        m.buildLoops();
        return m;
    }
    immutable float[] posV = [0.25f, 0.5f, 0.75f];   // along-cut sample fractions
    immutable float[] hV   = [0.5f, 1.0f, 0.5f];     // Vee heights (normalized)

    // Baseline: same 3 loops, NO profile (flat) — every loop on the surface (y=0).
    Mesh flat = makeFlatStrip();
    uint eiF = flat.edgeIndex(2, 4);
    assert(eiF != ~0u, "seed edge (2,4) must exist");
    uint[] nfF;
    assert(flat.insertEdgeLoopsMulti([eiF], posV, nfF, null, false, false,
                                     false, false, null, 0.0f, false, 1.0f,
                                     /*profileHeights*/null, /*depth*/0.0f),
           "flat profile (null heights) insert must succeed");
    immutable fV = flat.vertices.length, fE = flat.edges.length, fF = flat.faces.length;
    // Q1's rail (2,4) runs x=1→2 at z=0; three loops at x=1.25/1.5/1.75, all y=0.
    assert(hasV(flat, Vec3(1.25f, 0, 0)) && hasV(flat, Vec3(1.5f, 0, 0)) && hasV(flat, Vec3(1.75f, 0, 0)),
           "flat: 3 loops sit on the surface (y=0)");

    // Vee profile, depth D=2. Q1's geometric normal is -Y (the strip is wound so
    // faceNormal([2,4,5,3]) = (0,-1,0)), so heights [0.5,1,0.5]·D press the loops
    // DOWN by y = [-1,-2,-1] along that surface normal. The MECHANISM uses the true
    // per-rail normal — the sign follows the winding, not an assumed "up".
    Mesh vee = makeFlatStrip();
    uint eiV = vee.edgeIndex(2, 4);
    uint[] nfV;
    assert(vee.insertEdgeLoopsMulti([eiV], posV, nfV, null, false, false,
                                    false, false, null, 0.0f, false, 1.0f,
                                    /*profileHeights*/hV, /*depth*/2.0f),
           "vee profile insert must succeed");
    // Topology IDENTICAL to the flat baseline (profile relocates verts only).
    assert(vee.vertices.length == fV && vee.edges.length == fE && vee.faces.length == fF,
           "vee: topology identical to the flat baseline (positions only)");
    // Rail (2,4) at z=0: x=1.25→y=-1, x=1.5→y=-2 (the vee apex), x=1.75→y=-1.
    assert(hasV(vee, Vec3(1.25f, -1.0f, 0)), "vee: t=0.25 loop inset h·D = 0.5·2 = 1 (along -Y normal)");
    assert(hasV(vee, Vec3(1.5f,  -2.0f, 0)), "vee: t=0.50 apex inset h·D = 1.0·2 = 2");
    assert(hasV(vee, Vec3(1.75f, -1.0f, 0)), "vee: t=0.75 loop inset h·D = 0.5·2 = 1");
    assert(hasV(vee, Vec3(1.25f, -1.0f, 1)), "vee: the z=1 rail (3,5) insets identically");
    assert(!hasV(vee, Vec3(1.5f, 0, 0)), "vee: the apex loop is no longer on the surface");

    // depth=0 with a non-flat profile is a no-op (loops stay on the surface).
    Mesh d0 = makeFlatStrip();
    uint eiD = d0.edgeIndex(2, 4);
    uint[] nfD;
    assert(d0.insertEdgeLoopsMulti([eiD], posV, nfD, null, false, false,
                                   false, false, null, 0.0f, false, 1.0f,
                                   /*profileHeights*/hV, /*depth*/0.0f),
           "depth=0 profile insert must succeed");
    assert(hasV(d0, Vec3(1.5f, 0, 0)) && !hasV(d0, Vec3(1.5f, -2.0f, 0)),
           "depth=0: non-flat profile leaves every loop on the surface");
}

// (d) Grid equivalence oracle (task 0239 owner objection #2): a plain unit
// cube has exactly 2 perpendicular closed rings crossing at 2 shared faces —
// seed edge (0,1) (the horizontal "equatorial" belt, established above) and
// seed edge (0,4) (the vertical belt) share faces F4=[3,7,6,2] (Top) and
// F5=[0,1,5,4] (Bottom). insertEdgeLoopsMulti must GRID-split those two
// shared faces. The oracle: compare against applying the SAME two single-
// ring inserts SEQUENTIALLY (ring A via insertEdgeLoops, then re-finding the
// vertical seed on the mutated mesh and inserting ring B) — this is a
// stronger check than a count-only comparison because a winding/corner-
// reconciliation flip could preserve counts while producing the WRONG
// sub-quad shapes; comparing actual VERTEX POSITIONS (order-independent)
// catches that.
unittest {
    import std.math : abs;

    static bool hasVertNear(const Mesh m, Vec3 p, float eps = 1e-4f) {
        foreach (v; m.vertices)
            if (abs(v.x - p.x) < eps && abs(v.y - p.y) < eps && abs(v.z - p.z) < eps)
                return true;
        return false;
    }

    // --- Grid path: one insertEdgeLoopsMulti call, both seeds together.
    Mesh grid = makeCube();
    uint eiHoriz = grid.edgeIndex(0, 1);
    uint eiVert  = grid.edgeIndex(0, 4);
    assert(eiHoriz != ~0u && eiVert != ~0u, "both cube seeds must exist");
    uint[] gridNewFaces;
    bool okGrid = grid.insertEdgeLoopsMulti([eiHoriz, eiVert], [0.3f, 0.7f], gridNewFaces);
    assert(okGrid, "grid insertEdgeLoopsMulti must succeed on the cube");

    // --- Sequential path: ring A alone, then re-find ring B's seed (the
    //     vertical edges are never touched by ring A's rails — see the
    //     kernel doc comment — so edgeIndex(0,4) is still valid post-cut).
    Mesh seq = makeCube();
    uint eiHoriz2 = seq.edgeIndex(0, 1);
    bool okA = seq.insertEdgeLoops(eiHoriz2, [0.3f, 0.7f]);
    assert(okA, "sequential ring-A insert must succeed");
    uint eiVert2 = seq.edgeIndex(0, 4);
    assert(eiVert2 != ~0u, "vertical seed edge 0-4 must survive ring-A's cut");
    bool okB = seq.insertEdgeLoops(eiVert2, [0.3f, 0.7f]);
    assert(okB, "sequential ring-B insert must succeed");

    // Equivalence: identical V/E/F counts...
    assert(grid.vertices.length == seq.vertices.length,
           "grid vs sequential: vertex counts differ");
    assert(grid.edges.length == seq.edges.length,
           "grid vs sequential: edge counts differ");
    assert(grid.faces.length == seq.faces.length,
           "grid vs sequential: face counts differ");

    // ...and every vertex position in the grid result has a coincident
    // match in the sequential result (order-independent) — proves the grid
    // split lands vertices at EXACTLY the same points a sequential two-pass
    // insert would, catching a winding/reconciliation flip that a count-only
    // check would miss.
    foreach (v; grid.vertices)
        assert(hasVertNear(seq, v),
               "grid vertex has no coincident match in the sequential result");

    // No degenerate sub-quad: every face must be a quad with 4 DISTINCT
    // vertex indices, and the mesh must still be a closed manifold (Euler
    // V-E+F=2) — `rebuildEdges`/`buildLoops` would otherwise have silently
    // produced a non-manifold mess.
    foreach (const f; grid.faces) {
        assert(f.length == 4, "grid split must only ever produce quads");
        assert(f[0] != f[1] && f[1] != f[2] && f[2] != f[3] && f[3] != f[0]
               && f[0] != f[2] && f[1] != f[3],
               "grid split must not produce a degenerate (repeated-vertex) sub-quad");
    }
    assert(cast(int)grid.vertices.length - cast(int)grid.edges.length
           + cast(int)grid.faces.length == 2,
           "grid-split result must still satisfy Euler's formula (closed manifold)");
}

// Task 0389: insertEdgeLoopsMulti (loop_slice's kernel) must not drop the
// per-face Subpatch bit — neither on faces it dups untouched nor on the new
// sub-quads a ring split emits. Uses the SAME closed-ring cube fixture as
// unittest (A) above (seed edge 0-1), but this time with ONE ring face
// marked Subpatch and its immediate ring neighbour left plain, so the test
// proves per-source INHERITANCE (not just a blanket true/false leak).
unittest {
    import std.math : abs;

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
    static uint findFaceIndexBySet(const Mesh m, uint[] vs) {
        outer: foreach (fi, const f; m.faces) {
            if (f.length != vs.length) continue;
            foreach (v; vs) {
                bool found = false;
                foreach (fv; f) if (fv == v) { found = true; break; }
                if (!found) continue outer;
            }
            return cast(uint)fi;
        }
        return ~0u;
    }
    static uint findVertNear(const Mesh m, float x, float y, float z,
                             float eps = 1e-4f) {
        foreach (uint i; 0 .. cast(uint)m.vertices.length) {
            auto v = m.vertices[i];
            if (abs(v.x - x) < eps && abs(v.y - y) < eps && abs(v.z - z) < eps)
                return i;
        }
        return ~0u;
    }

    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();   // size faceMarks — makeCube/addFace leave it empty

    // F0 = faces[0] = [0,3,2,1] (bottom) marked Subpatch; every other face
    // (including its ring neighbour F5 = faces[5] = [0,1,5,4], sharing the
    // seed edge 0-1) is left plain.
    m.setFaceSubpatch(0, true);
    assert(m.isFaceSubpatch(0), "F0 must be marked Subpatch before the cut");
    assert(!m.isFaceSubpatch(5), "F5 must start plain");

    uint eiSeed = m.edgeIndex(0, 1);
    assert(eiSeed != ~0u, "seed edge 0-1 must exist in cube");
    bool ok = m.insertEdgeLoops(eiSeed, [0.5f]);
    assert(ok, "insertEdgeLoops must succeed on cube");
    assert(m.faces.length == 10, "cube ring cut must still produce 10 faces");

    // Untouched cap faces F2=[0,4,7,3] and F3=[1,2,6,5] (outside the ring,
    // dup'd as-is) must keep their own (unset) bit.
    uint f2i = findFaceIndexBySet(m, [0u, 4u, 7u, 3u]);
    uint f3i = findFaceIndexBySet(m, [1u, 2u, 6u, 5u]);
    assert(f2i != ~0u && f3i != ~0u, "cap faces F2/F3 must survive the cut unchanged");
    assert(!m.isFaceSubpatch(f2i), "untouched cap face F2 must stay non-subpatch");
    assert(!m.isFaceSubpatch(f3i), "untouched cap face F3 must stay non-subpatch");

    // Rail midpoints — same geometry as unittest (A) above.
    uint mA = findVertNear(m, 0.0f, -0.5f, -0.5f); // mid of edge 0-1 (shared F0/F5 rail)
    uint mB = findVertNear(m, 0.0f,  0.5f, -0.5f); // mid of edge 2-3 (F0's other rail)
    uint mD = findVertNear(m, 0.0f, -0.5f,  0.5f); // mid of edge 4-5 (F5's other rail)
    assert(mA != ~0u && mB != ~0u && mD != ~0u, "rail midpoints must exist");

    // F0's two sub-quads must BOTH inherit F0's Subpatch=true.
    assert(hasFace(m, [0u, mA, mB, 3u]) && hasFace(m, [mA, 1u, 2u, mB]),
           "F0 must split into its two expected sub-quads");
    uint f0aI = findFaceIndexBySet(m, [0u, mA, mB, 3u]);
    uint f0bI = findFaceIndexBySet(m, [mA, 1u, 2u, mB]);
    assert(m.isFaceSubpatch(f0aI) && m.isFaceSubpatch(f0bI),
           "both of F0's new sub-quads must inherit Subpatch=true from F0");

    // F5's two sub-quads (its neighbour across the shared rail, plain) must
    // BOTH stay Subpatch=false — proves inheritance is per-SOURCE-face, not
    // a blanket flip from the one marked ring face.
    assert(hasFace(m, [0u, mA, mD, 4u]) && hasFace(m, [mA, 1u, 5u, mD]),
           "F5 must split into its two expected sub-quads");
    uint f5aI = findFaceIndexBySet(m, [0u, mA, mD, 4u]);
    uint f5bI = findFaceIndexBySet(m, [mA, 1u, 5u, mD]);
    assert(!m.isFaceSubpatch(f5aI) && !m.isFaceSubpatch(f5bI),
           "both of F5's new sub-quads must stay Subpatch=false (F5 was plain)");
}

// Task 0389: bevelEdgesByMask — the chamfer quad inherits Subpatch via OR
// of the TWO faces adjacent to the beveled edge. Same cube-edge (6,7)
// fixture as the bevelEdgesByMask cube-edge unittest elsewhere in this file:
// edge (6,7) is shared by faces[1]=[4,5,6,7] (+Z) and faces[4]=[3,7,6,2] (+Y).
unittest {
    static int findEdge(ref Mesh m, uint va, uint vb) {
        foreach (i; 0 .. m.edges.length) {
            uint a = m.edges[i][0], b = m.edges[i][1];
            if ((a == va && b == vb) || (a == vb && b == va)) return cast(int)i;
        }
        return -1;
    }
    static uint firstSelectedFace(ref Mesh m) {
        foreach (fi; 0 .. m.faces.length) if (m.isFaceSelected(fi)) return cast(uint)fi;
        return uint.max;
    }

    // Neither adjacent face marked ⇒ the chamfer must stay non-subpatch.
    {
        Mesh m = makeCube();
        m.buildLoops();
        m.resetSelection();
        int ei = findEdge(m, 6, 7);
        assert(ei >= 0, "edge (6,7) must exist");
        bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
        assert(m.bevelEdgesByMask(mask, 0.1f) == 1, "should process 1 edge");
        uint chamferFi = firstSelectedFace(m);
        assert(chamferFi != uint.max, "chamfer face must be selected after bevel");
        assert(!m.isFaceSubpatch(chamferFi),
               "chamfer must stay non-subpatch when neither neighbour was marked");
    }

    // Exactly ONE adjacent face marked (faces[1] = [4,5,6,7], the +Z
    // neighbour) ⇒ OR still produces a Subpatch chamfer, proving inheritance
    // is per-source (not requiring both sides marked).
    {
        Mesh m = makeCube();
        m.buildLoops();
        m.resetSelection();
        m.setFaceSubpatch(1, true);   // faces[1] = [4,5,6,7], the +Z neighbour
        assert(!m.isFaceSubpatch(4), "faces[4] (+Y neighbour) must start plain");
        int ei = findEdge(m, 6, 7);
        assert(ei >= 0, "edge (6,7) must exist");
        bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
        assert(m.bevelEdgesByMask(mask, 0.1f) == 1, "should process 1 edge");
        uint chamferFi = firstSelectedFace(m);
        assert(chamferFi != uint.max, "chamfer face must be selected after bevel");
        assert(m.isFaceSubpatch(chamferFi),
               "chamfer must inherit Subpatch via OR when only ONE neighbour was marked");
    }
}

// Task 0389: insetFacesByMask — the inner face already kept its bit
// in-place (faces[fi] reassigned, not the marks word); the new ring quads
// must ALSO inherit Subpatch from the inset source face, in both directions
// (not a blanket true/false leak).
unittest {
    static Mesh makeFlatQuad() {
        Mesh m;
        m.vertices = [
            Vec3(-0.5f, 0f, -0.5f), Vec3(0.5f, 0f, -0.5f),
            Vec3(0.5f, 0f,  0.5f),  Vec3(-0.5f, 0f, 0.5f),
        ];
        m.addFace([0, 1, 2, 3]);
        m.buildLoops();
        return m;
    }
    bool[] allOne = [true];

    // Source marked Subpatch=true ⇒ inner AND all 4 ring quads inherit true.
    {
        Mesh m = makeFlatQuad();
        m.resetSelection();
        m.setFaceSubpatch(0, true);
        assert(m.insetFacesByMask(allOne, 0.1f) == 1, "must process 1 face");
        assert(m.faces.length == 5, "expected 1 inner + 4 ring quads");
        foreach (fi; 0 .. m.faces.length)
            assert(m.isFaceSubpatch(fi),
                   "every face (inner + ring) must be Subpatch when the source was");
    }

    // Source left plain ⇒ inner AND ring quads all stay non-subpatch.
    {
        Mesh m = makeFlatQuad();
        m.resetSelection();
        assert(m.insetFacesByMask(allOne, 0.1f) == 1, "must process 1 face");
        assert(m.faces.length == 5, "expected 1 inner + 4 ring quads");
        foreach (fi; 0 .. m.faces.length)
            assert(!m.isFaceSubpatch(fi),
                   "no face should be Subpatch when the source was plain");
    }
}

// Task 0389: extrudeFacesByMask — the cap already inherited (pre-existing);
// the 4 side walls must ALSO inherit Subpatch from the extruded source face.
// Same single-face-extrude fixture as the extrudeFacesByMask unittest
// elsewhere in this file (cube face 0, distance 0.5 → 5 orig + 1 cap + 4
// walls = 10 faces).
unittest {
    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();
    m.setFaceSubpatch(0, true);
    bool[] mask; mask.length = m.faces.length; mask[] = false; mask[0] = true;
    size_t n = m.extrudeFacesByMask(mask, 0.5f);
    assert(n > 0, "extrudeFacesByMask must succeed");
    assert(m.faces.length == 10, "expected 10 faces after single-face extrude");

    size_t subCount = 0, plainCount = 0;
    foreach (fi; 0 .. m.faces.length) {
        if (m.isFaceSubpatch(fi)) ++subCount; else ++plainCount;
    }
    // 5 non-selected originals stay plain; cap + 4 walls (all derived from
    // the ONE Subpatch-marked source face) all become Subpatch.
    assert(subCount == 5, "cap + 4 walls (5 faces) must all inherit Subpatch");
    assert(plainCount == 5, "the 5 untouched original faces must stay plain");
}

// (e) Degenerate seed among valid ones: a seed whose collectEdgeRing is
// empty (non-quad-adjacent) must be silently skipped, WITHOUT blocking the
// other valid seed's ring from being cut; if EVERY seed is degenerate, the
// call is a no-op (false, no mutation).
unittest {
    // One valid cube seed + one triangle-adjacent (non-quad) seed sharing
    // NO faces with the cube — the mixed-valence fixture from the
    // `collectEdgeRing` non-quad-guard unittest just below, merged with a
    // disjoint cube.
    Mesh m = makeCube();
    // Triangulate F2=[0,4,7,3] (Left face — NOT part of the (0,1) BeltX
    // ring) by hand: split it into two triangles sharing diagonal 0-7.
    uint[][] withTri = m.faces.dup;
    withTri[2] = [0u, 4u, 7u];          // shrink F2 to a triangle
    withTri ~= [0u, 7u, 3u];            // the other half as a 2nd triangle
    m.faces = withTri;
    m.rebuildEdges();
    m.buildLoops();

    uint eiValid = m.edgeIndex(0, 1);          // still a valid BeltX seed
    uint eiDegenerate = m.edgeIndex(0, 7);     // now triangle-adjacent
    assert(eiValid != ~0u, "valid seed edge must exist");
    assert(eiDegenerate != ~0u, "degenerate seed edge must exist");

    bool closedDegenerate;
    assert(m.collectEdgeRing(eiDegenerate, closedDegenerate).length == 0,
           "sanity: the degenerate seed's ring must indeed be empty");

    uint[] newFaceIndices;
    bool ok = m.insertEdgeLoopsMulti([eiValid, eiDegenerate], [0.5f], newFaceIndices);
    assert(ok, "one valid + one degenerate seed must still succeed (valid seed's ring cut)");
    assert(m.vertices.length == 12, "valid seed's ring must still be cut (V=12, as single-seed)");
    // F=11: the base cube's single-seed cut gives F=10 (see the closed-ring
    // unittest above); triangulating F2 into 2 triangles (replacing 1 quad)
    // adds exactly 1 extra face on top of that, and F2/its 2 triangles sit
    // OUTSIDE the BeltX ring so they pass through untouched.
    assert(m.faces.length == 11, "valid seed's ring must still be cut (F=11 = 10 + 1 extra tri)");

    // All-degenerate: no-op.
    Mesh m2 = makeCube();
    uint[][] withTri2 = m2.faces.dup;
    withTri2[2] = [0u, 4u, 7u];
    withTri2 ~= [0u, 7u, 3u];
    m2.faces = withTri2;
    m2.rebuildEdges();
    m2.buildLoops();
    uint eiDeg2 = m2.edgeIndex(0, 7);
    assert(eiDeg2 != ~0u);
    uint vBefore = cast(uint)m2.vertices.length;
    uint eBefore = cast(uint)m2.edges.length;
    uint fBefore = cast(uint)m2.faces.length;
    uint[] unused;
    bool okAll = m2.insertEdgeLoopsMulti([eiDeg2], [0.5f], unused);
    assert(!okAll, "all-degenerate seed set must return false");
    assert(m2.vertices.length == vBefore && m2.edges.length == eBefore
           && m2.faces.length == fBefore, "all-degenerate call must not mutate the mesh");
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
