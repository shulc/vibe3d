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

        // Per-corner map (UV) carry — task 0682. `faces = newFaces` below
        // renumbers every CORNER, and this kernel also INSERTS vertices, so the
        // arity-preserving funnel alone cannot describe the result: see
        // `Mesh.carryPolyVertexMaps` (mechanism (c)) for the law and why a
        // second, interpolating pass is needed. Two things are recorded as the
        // split runs: the ORIGINAL face each emitted face came from (`newSrc`,
        // pushed in lock-step with `newFaces`, `~0u` for a face with no single
        // source), and the blend of original vertices behind every inserted
        // vertex (`vertBlend`). Both are skipped entirely when no per-corner map
        // is registered — the common case pays nothing.
        immutable bool carryUv = hasPolyVertexMap();
        const uint[] oldFaceLoop = carryUv ? captureFaceLoop() : null;
        PolyVertexBlend[uint] vertBlend;

        static void reverseInPlace(uint[] a) {
            size_t i = 0, j = a.length - 1;
            while (i < j) { uint t = a[i]; a[i] = a[j]; a[j] = t; ++i; --j; }
        }

        // Per-corner map carry (task 0682): record that inserted vertex `nv`
        // sits at fraction `t` along `va`→`vb`, so its corner values are
        // interpolated exactly the way its position was. The sources are
        // ORIGINAL vertices and both are corners of every old face this rail
        // borders — that is what lets `carryPolyVertexMaps` resolve them
        // per-face and so keep the two sides of a UV seam in their own islands.
        void recordRailBlend(uint nv, uint va, uint vb, float t) {
            PolyVertexBlend b;
            b.add(va, 1.0f - t);
            b.add(vb, t);
            vertBlend[nv] = b;
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
                    uint nv = addVertex(curvatureSplinePoint(p0, va3, vb3, p3, tt, curveTension));
                    mids ~= nv;
                    // Per-corner carry (0682): the CURVATURE branch places the
                    // vertex off the chord, so there is no geometric fraction on
                    // the edge to read — the map takes the PARAMETRIC fraction
                    // `tt` instead, which is the same number the flat branch's
                    // geometric fraction equals and the same one the spline was
                    // evaluated at. (The reference capture only covers straight
                    // rails; this is the honest generalisation, not a measurement.)
                    if (carryUv) recordRailBlend(nv, va, vb, tt);
                }
            } else {
                foreach (float t; positions) {
                    float tt = mirror ? 1.0f - t : t;
                    uint nv = addVertex(va3 + (vb3 - va3) * tt);
                    mids ~= nv;
                    if (carryUv) recordRailBlend(nv, va, vb, tt);
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
                    // Per-corner carry (0682): a Split hi-side duplicate is a
                    // coincident copy of its lo-side midpoint, so it inherits
                    // that midpoint's blend verbatim — the two sides differ in
                    // POSITION (Gap pushes them apart afterwards), never in
                    // where their corner values come from.
                    if (carryUv)
                        if (auto b = v in vertBlend) vertBlend[nv] = *b;
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
        // Parallel to `newFaces` (task 0389, generalized task 0613 §4.2):
        // every entry pushed to `newFaces` gets a matching WHOLE marks word
        // (Subpatch + Hide, was Subpatch-only) pushed here in lock-step, so
        // `faceMarks` can be rebuilt (Template A) once `faces = newFaces`
        // lands below. `faces = newFaces` is a whole-array rebuild — without
        // this, `faceMarks` would stay aligned to the OLD `faces` slot
        // indices and every bit would land on the wrong (or a nonexistent)
        // face.
        // One estimate, named once, for all three lock-step arrays below — a
        // `reserve(newWord.capacity)` reads the NEIGHBOUR's already-grown
        // capacity, so merely moving these declarations apart would silently
        // reserve 0 (task 0685 T12).
        immutable size_t faceArrayEstimate =
            faces.length + rings.length * positions.length * 4;
        uint[] newWord;
        newWord.reserve(faceArrayEstimate);
        // Same lock-step law for the discrete polygon tags (task 0678 M1):
        // `faces = newFaces` renumbers every face (a split ring face emits
        // several sub-faces, shifting everything after it), so
        // `faceMaterial`/`facePart` must be rebuilt in the same pass or every
        // tag lands on the wrong face — resetSelection() only fixes the array
        // LENGTH, not the indexing. Mirrors bevelEdgesByMask's newMat/newPart.
        uint[] newMat, newPart;
        newMat.reserve(faceArrayEstimate);
        newPart.reserve(faceArrayEstimate);
        // Same lock-step law once more, for the CORNER-indexed planes (task
        // 0682): the ORIGINAL face each emitted face came from, `~0u` when
        // there is no single source (a section cap is stitched from a whole
        // shell's boundary, which can span several ring faces). Only populated
        // when a per-corner map exists; `carryPolyVertexMaps` reads it below.
        uint[] newSrc;
        if (carryUv) newSrc.reserve(faceArrayEstimate);

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
                    uint nv = addVertex(pt);
                    grid[i+1][j+1] = nv;
                    // Per-corner carry (0682): a grid-interior vertex is a
                    // BILERP of the quad's four corners, so its corner values
                    // take the same four weights its position took.
                    if (carryUv) {
                        PolyVertexBlend b;
                        b.add(A, (1.0f - u) * (1.0f - v));
                        b.add(B, u * (1.0f - v));
                        b.add(C, u * v);
                        b.add(D, (1.0f - u) * v);
                        vertBlend[nv] = b;
                    }
                }

            foreach (i; 0 .. Pu + 1)
                foreach (j; 0 .. Pv + 1) {
                    newFaces ~= [grid[i][j], grid[i+1][j],
                                 grid[i+1][j+1], grid[i][j+1]];
                    newFaceIndices ~= cast(uint)(newFaces.length - 1);
                }
        }

        // Marks-tracking wrapper around `splitFace` (task 0389, generalized
        // task 0613 §4.2): every sub-face `splitFace(fi)` emits — single-ring,
        // n-gon, or a 2-ring grid — inherits the SOURCE ring face `fi`'s WHOLE
        // marks word (Subpatch + Hide, was Subpatch-only). Rather than
        // threading `fi` through emitSingleRingSplit/emitNgonRingSplit/the
        // grid-split branch individually, record `newFaces.length`
        // before/after the call and backfill `newWord` for whatever range
        // `splitFace` just appended.
        void splitFaceTracked(uint fi) {
            immutable size_t before = newFaces.length;
            splitFace(fi);
            immutable uint word = faceAttrOr(faceMarks, fi);
            immutable uint mat  = faceAttrOr(faceMaterial, fi);
            immutable uint part = faceAttrOr(facePart, fi);
            foreach (i; before .. newFaces.length) {
                newWord ~= word;
                newMat  ~= mat;
                newPart ~= part;
                if (carryUv) newSrc ~= fi;   // every sub-face's UV island source
            }
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
                else {
                    newFaces ~= faces[fi].dup;
                    newWord  ~= faceAttrOr(faceMarks, fi);
                    newMat   ~= faceAttrOr(faceMaterial, fi);
                    newPart  ~= faceAttrOr(facePart, fi);
                    if (carryUv) newSrc ~= fi;
                }
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
                newWord  ~= faceAttrOr(faceMarks, fi);
                newMat   ~= faceAttrOr(faceMaterial, fi);
                newPart  ~= faceAttrOr(facePart, fi);
                if (carryUv) newSrc ~= fi;   // absorbed mids interpolate in THIS face
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

            // Marks word for a cap face (task 0389, generalized task 0613
            // §4.2, and combine rule revised by code review S5): a cap seals
            // a WHOLE shell's boundary loop, which can be stitched together
            // from more than one original ring face — there is no single
            // "source face" the way there is for a split sub-quad. Fold
            // every ring face's word through Mesh.combineFaceMarksWords:
            // Subpatch is still the ANY-source OR (cosmetic, unchanged from
            // task 0389), Hide is the ALL-source AND (the same law §1.2
            // uses to derive a vertex's hidden state from its incident
            // faces) — so a cap is hidden only when EVERY ring face this cut
            // passed through was, not merely one, matching bevel's chamfer
            // strip. `Marks.Hide` is the fold's identity element.
            uint capWord = Marks.Hide;
            foreach (fi, _; perFaceRings) {
                capWord = combineFaceMarksWords(capWord, faceAttrOr(faceMarks, fi));
                // Early exit (kept from the pre-0613 Subpatch-only bool
                // loop, which broke as soon as one subpatch source was
                // found): once Subpatch is latched ON and Hide is latched
                // OFF, neither the ALL-source AND nor the ANY-source OR can
                // move again, so further sources cannot change the result.
                if ((capWord & Marks.Subpatch) != 0 && (capWord & Marks.Hide) == 0)
                    break;
            }

            // Chain each shell's incidence-1 boundary edges into reversed cap
            // polygons via the shared `capShellCycles` helper (same geometry the
            // Slice split-caps path uses — task 0274). Interior lo–lo / hi–hi
            // edges (incidence 2) are skipped; each cap reuses existing boundary
            // verts (no new verts/edges).
            void capBoundaryLoops(ref bool[uint] set) {
                foreach (cyc; capShellCycles(newFaces, set)) {
                    newFaces ~= cyc;
                    newFaceIndices ~= cast(uint)(newFaces.length - 1);
                    newWord ~= capWord;
                    // Caps are NEW faces with no single source face (a shell
                    // loop can stitch several ring faces), so they take the
                    // default surface/part 0 — same as bevel's freshly created
                    // faces, and same as what the pre-fix zero-fill produced
                    // for the appended tail. Inheriting "some" ring face's
                    // material would be AA-iteration-order nondeterministic.
                    newMat  ~= 0u;
                    newPart ~= 0u;
                    // No single source face for a cap (its loop can stitch
                    // several ring faces), so its corners have no island to
                    // interpolate in and stay ZERO — the pre-0682 drop
                    // behaviour, kept deliberately rather than guessed at.
                    if (carryUv) newSrc ~= ~0u;
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

        // Carry the corner-indexed planes (UV) across the rebuild BEFORE
        // `faces` is replaced — the helper reads the OLD faces to find each
        // corner's island (task 0682). Leaves every map length-correct for the
        // new corner count, so the tail `buildLoops`'s `resizePolyVertexMaps`
        // sees a placed map and no-ops instead of zeroing it.
        if (carryUv) {
            assert(newSrc.length == newFaces.length,
                   "insertEdgeLoopsMulti: newSrc/newFaces length mismatch");
            carryPolyVertexMaps(newFaces, newSrc, faces.range, oldFaceLoop, vertBlend);
        }

        faces = newFaces;
        // Rebuild faceMarks in lock-step with the just-replaced `faces`
        // (task 0389 — Template A, mirrors bevelEdgesByMask; generalized to
        // the whole word by task 0613 §4.2): `newWord` was populated 1:1
        // with every `newFaces` append above (dup'd untouched faces keep
        // their own word; ring-split sub-faces and section caps inherit from
        // their source ring face(s)). resetSelection() below no longer
        // clears subpatch on its own, so this is the only place the new
        // mesh's Subpatch/Hide bits get set — without it every face would
        // silently default to non-subpatch/non-hidden (faceMarks zero-fills
        // on resize).
        assert(newWord.length == faces.length,
               "insertEdgeLoopsMulti: newWord/newFaces length mismatch");
        assert(newMat.length == faces.length && newPart.length == faces.length,
               "insertEdgeLoopsMulti: newMat/newPart/newFaces length mismatch");
        setFaceMarksFrom(newWord, ~Marks.Select);
        faceMaterial = newMat;
        facePart     = newPart;
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
