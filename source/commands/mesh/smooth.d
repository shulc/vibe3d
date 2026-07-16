module commands.mesh.smooth;

import display_sync : refreshDisplayActive;
import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport;
import params : Param;
import change_bus : MeshEditScope;
import toolpipe.packets : FalloffPacket, SubjectPacket;
import falloff : evaluateFalloff, IFalloffAware;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;

/// Laplacian vertex smoothing. Each iteration: new_pos = old_pos +
/// strength * (avg_of_edge_neighbors - old_pos). Selection-aware
/// (same mask as MeshTransform); empty selection ⇒ whole mesh.
///
/// A Laplacian smooth with `strn` (strength) and `iter` (iterations)
/// attrs, exposed as a one-shot command rather than a drag-tool.
/// Reference: a fixed cube + strn/iter pair converges toward the
/// centroid analytically (see tests/test_mesh_smooth.d), which is the
/// practical check.
class MeshSmooth : Command, Operator, IFalloffAware {
    private float            strn_ = 1.0f;   // `strn` (strength) attr — reference default 1.0
    private int              iter_ = 1;      // `iter` (iterations) attr
    private bool             lockBound_ = false;  // `lockBound` —
    // freezes verts on boundary edges (edges adjacent to only one face,
    // i.e. `loop.twin == uint.max` in our half-edge structure).
    private bool             lockCorner_ = false; // `lockCorner` —
    // freezes valence-2 boundary verts only (the actual "corners" of
    // an open mesh loop). Strict subset of lockBound; the two can be
    // toggled independently. A corner vertex is shared by a single
    // polygon and lies on the boundary.
    private bool             lockSharp_     = false; // `lockSharp`
    private float            sharpAngleDeg_ = 60.0f; // `sharpAngle`,
    // DEGREES (reference default 60°). Freezes verts on interior edges whose
    // dihedral angle exceeds this threshold; converted to radians at the
    // dihedral test below. Boundary edges aren't covered here — use
    // lockBound / lockCorner for those. Greyed out (paramEnabled) unless
    // lockSharp is on, matching the reference's disabled spinner.
    // Optional falloff packet — set via `setFalloff` from either the
    // wrapping tool (XfrmSmoothTool reads the toolpipe's FalloffStage)
    // or the HTTP injector (tests pass a `falloff` JSON alongside the
    // command params). When `falloff_.enabled` is true, `apply()` lerps
    // each touched vert toward its smoothed position by the per-vert
    // weight. weight=1 → full smooth; weight=0 → vert stays at original.
    // Same transform×falloff blend used elsewhere.
    private FalloffPacket    falloff_;
    private bool             preserve_      = false; // `preserve`
    // (Preserve Volume) — after the Laplacian iterations, project
    // each moved vert's delta onto its pre-smooth tangent plane
    // (perpendicular to its pre-smooth vertex normal). Cancels the
    // normal-direction component so verts can slide along the
    // surface but can't dive into / pop out of the original volume,
    // constraining the smoothed points to the original surface.
    private uint[] touchedIdx;
    private Vec3[] touchedPrev;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.smooth"; }
    override string label() const { return "Smooth"; }

    // Row order matches the reference Smooth tool properties top-to-bottom.
    override Param[] params() {
        return [
            Param.float_("strn",       "Strength",         &strn_,          1.0f).min(0.0f).max(1.0f),
            // `.max(256).enforceBounds()` matches the local `MAX_SMOOTH_ITER`
            // apply-loop cap below — the Param bound alone is a UI-only
            // hint and does not clamp a raw HTTP write.
            Param.int_  ("iter",       "Iterations",       &iter_,          1).min(0).max(256).enforceBounds(),
            Param.bool_ ("lockBound",  "Lock Boundary",    &lockBound_,     false),
            Param.bool_ ("lockCorner", "Lock Corner",      &lockCorner_,    false),
            Param.bool_ ("preserve",   "Preserve Volume",  &preserve_,      false),
            Param.bool_ ("lockSharp",  "Lock Sharp Edges", &lockSharp_,     false),
            Param.float_("sharpAngle", "Sharp Angle",      &sharpAngleDeg_, 60.0f).min(0.0f).max(180.0f),
        ];
    }

    // Sharp Angle is meaningful only while Lock Sharp Edges is on —
    // grey it out otherwise, matching the reference's disabled spinner.
    override bool paramEnabled(string name) const {
        if (name == "sharpAngle") return lockSharp_;
        return true;
    }

    // Setters for XfrmSmoothTool's drag-modulates-attrs path.
    void setStrn(float v)             { strn_ = v; }
    void setIter(int   v)             { iter_ = v; }
    void setLockBound(bool v)         { lockBound_ = v; }
    void setLockCorner(bool v)        { lockCorner_ = v; }
    void setLockSharp(bool v)         { lockSharp_ = v; }
    void setSharpAngle(float v)       { sharpAngleDeg_ = v; }
    void setPreserve(bool v)          { preserve_ = v; }
    void setFalloff(FalloffPacket fp) { falloff_ = fp; }

    // Operator interface. Common stubs from the mixin; evaluate(vts)
    // pulls the optional FalloffPacket into the legacy `falloff_` field
    // before invoking the kernel (which lives in the apply() override
    // below for now — Phase 7 inlines it).
    mixin OperatorActrCommon;
    bool evaluate(ref VectorStack vts) {
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (auto fp = vts.get!FalloffPacket())
            this.falloff_ = *fp;
        return this.applyKernel();
    }

    private bool applyKernel() {
        if (iter_ <= 0 || strn_ <= 0.0f) return true;  // no-op apply

        // DoS backstop (task 0365 P1): `iter` scales the Laplacian pass
        // count below; Param `.min()` hints are UI-only and do not clamp a
        // direct/scripted `tool.attr`/command write.
        enum int MAX_SMOOTH_ITER = 256;
        int iterCapped = iter_ > MAX_SMOOTH_ITER ? MAX_SMOOTH_ITER : iter_;

        // Affected-vertex mask (selection-aware).
        //
        // Perf (task 0388): `mesh.selectedX` is a @property that rebuilds a
        // whole `bool[]` per read — indexing it inside these loops was
        // O(mesh²). Iterate the lock-step `*Marks.length` and test via the
        // non-allocating `isXSelected(i)` scalar accessor instead.
        bool[] vmask = new bool[](mesh.vertices.length);
        bool any = false;
        if (editMode == EditMode.Vertices) {
            foreach (i; 0 .. mesh.vertexMarks.length)
                if (mesh.isVertexSelected(i)) { vmask[i] = true; any = true; }
        } else if (editMode == EditMode.Edges) {
            foreach (i; 0 .. mesh.edgeMarks.length)
                if (mesh.isEdgeSelected(i))
                    foreach (vi; mesh.edges[i]) { vmask[vi] = true; any = true; }
        } else {
            foreach (i; 0 .. mesh.faceMarks.length)
                if (mesh.isFaceSelected(i))
                    foreach (vi; mesh.faces[i]) { vmask[vi] = true; any = true; }
        }
        if (!any)
            foreach (i; 0 .. mesh.vertices.length) vmask[i] = true;

        // Pre-smooth per-face normals — only needed by `preserve` (the
        // per-vert normal that defines each vert's tangent plane). The
        // `lockSharp` dihedral test below no longer builds its own copy;
        // it shares `Mesh.computeEdgeSharpness` with the AI support-loop
        // candidate generator (`ai.support_loop_candidates`) so the
        // definition of "sharp edge" can't drift between the two call
        // sites.
        Vec3[] faceNormal;
        if (preserve_) {
            faceNormal.length = mesh.faces.length;
            foreach (fi; 0 .. mesh.faces.length)
                faceNormal[fi] = mesh.faceNormalTri3(cast(uint)fi);
        }

        // `lockSharp`: pin verts on interior edges whose dihedral angle
        // exceeds sharpAngleDeg_. `computeEdgeSharpness` walks each
        // interior half-edge ONCE (li < twin dedup) using the exact same
        // 3-vertex-cross face-normal approximation this block always
        // used inline — extracting it into `Mesh` does not change the
        // numeric result (see mesh.d's computeEdgeSharpness unittest).
        if (lockSharp_) {
            auto sharpness = mesh.computeEdgeSharpness(sharpAngleDeg_);
            foreach (ei, ref s; sharpness) {
                if (!s.sharp) continue;
                uint a = mesh.edges[ei][0];
                uint b = mesh.edges[ei][1];
                if (a < vmask.length) vmask[a] = false;
                if (b < vmask.length) vmask[b] = false;
            }
        }

        // `preserve` (Preserve Volume) — capture pre-smooth
        // vertex normals as the average of incident face normals.
        // The post-iter projection pass below uses these to slide
        // each smoothed vert back onto its pre-smooth tangent plane.
        Vec3[] vertNormal;
        Vec3[] origPos;
        if (preserve_) {
            vertNormal.length = mesh.vertices.length;
            foreach (i; 0 .. vertNormal.length) vertNormal[i] = Vec3(0, 0, 0);
            foreach (fi, ref f; mesh.faces) {
                auto nf = faceNormal[fi];
                foreach (vid; f) {
                    if (vid >= vertNormal.length) continue;
                    vertNormal[vid] = vertNormal[vid] + nf;
                }
            }
            foreach (i; 0 .. vertNormal.length) {
                float len = vertNormal[i].length;
                vertNormal[i] = (len > 1e-9f)
                    ? vertNormal[i] * (1.0f / len)
                    : Vec3(0, 1, 0);
            }
            origPos = mesh.vertices.dup;
        }

        // `lockBound` / `lockCorner`: pin selected boundary
        // verts before the Laplacian iteration. Both flags walk the
        // same boundary half-edges (`loop.twin == uint.max`) — bound
        // pins ALL endpoint verts, corner additionally filters by
        // valence == 2 (a true open-mesh corner — sits on exactly
        // two boundary edges + one face). Pre-compute valence once
        // when corner is on; cheap O(edges) walk.
        if (lockBound_ || lockCorner_) {
            int[] valence;
            if (lockCorner_) {
                valence.length = mesh.vertices.length;
                foreach (e; mesh.edges) {
                    if (e[0] < valence.length) ++valence[e[0]];
                    if (e[1] < valence.length) ++valence[e[1]];
                }
            }
            foreach (ref l; mesh.loops) {
                if (l.twin != uint.max) continue;
                uint a = l.vert;
                uint b = mesh.loops[l.next].vert;
                if (a < vmask.length
                 && (lockBound_ || (lockCorner_ && valence[a] == 2)))
                    vmask[a] = false;
                if (b < vmask.length
                 && (lockBound_ || (lockCorner_ && valence[b] == 2)))
                    vmask[b] = false;
            }
        }

        // Neighbour lists — CSR vert→vert adjacency (relation D, edge-based,
        // both directions), shared with smoothSubdivide / updateConnectMask.
        // Per-vertex order is proven identical to the old inline
        // `foreach (e; mesh.edges) { neighbors[e0]~=e1; neighbors[e1]~=e0; }`
        // build (mesh.d Stage-0 parity unittest), which the float-sum
        // averaging below depends on for bit-identical results.
        const(size_t)[] adjOff;
        const(uint)[]   adjNbrs;
        mesh.vertexAdjacencyCSR(adjOff, adjNbrs);

        // Snapshot pre-apply positions of every vert we plan to touch.
        // We touch ALL masked verts (even those without neighbors —
        // their Laplacian contribution is zero, but we still snapshot
        // them so revert can restore unconditionally).
        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i; 0 .. mesh.vertices.length) {
            if (!vmask[i]) continue;
            touchedIdx  ~= cast(uint)i;
            touchedPrev ~= mesh.vertices[i];
        }

        // Laplacian iteration. Each pass reads from a `prev` snapshot
        // (so neighbour averaging sees the previous iteration's
        // positions, not partially updated ones), then commits.
        Vec3[] prev = mesh.vertices.dup;
        Vec3[] cur  = mesh.vertices.dup;
        foreach (_; 0 .. iterCapped) {
            foreach (vi; 0 .. mesh.vertices.length) {
                if (!vmask[vi]) continue;
                auto nbrs = adjNbrs[adjOff[vi] .. adjOff[vi + 1]];
                if (nbrs.length == 0) continue;
                Vec3 sum = Vec3(0, 0, 0);
                foreach (nb; nbrs) sum = sum + prev[nb];
                Vec3 avg = sum * (1.0f / cast(float)nbrs.length);
                cur[vi].x = prev[vi].x + strn_ * (avg.x - prev[vi].x);
                cur[vi].y = prev[vi].y + strn_ * (avg.y - prev[vi].y);
                cur[vi].z = prev[vi].z + strn_ * (avg.z - prev[vi].z);
            }
            // Promote `cur` → `prev` for the next iteration via swap;
            // copying would alloc each pass at large mesh sizes.
            auto tmp = prev; prev = cur; cur = tmp;
        }
        // After the loop, `prev` holds the final state (last swap).
        mesh.vertices = prev;

        // Falloff blend: lerp each touched vert from its pre-smooth
        // position toward the post-smooth position by per-vert weight.
        // Same way the transform × falloff stage attenuates any
        // deformation — weight 1.0 keeps the full smooth, weight
        // 0.0 leaves the vert at its original. No-op when falloff is
        // disabled. `Viewport` is unused for non-screen falloff types
        // (linear / radial / cylinder / element) — pass an empty one
        // so the same call site works headlessly. Falloff is applied
        // BEFORE the preserve-volume pass so the tangent-plane
        // projection sees the weighted result.
        if (falloff_.enabled) {
            Viewport vp;
            foreach (i, vi; touchedIdx) {
                if (vi >= mesh.vertices.length) continue;
                Vec3 sm = mesh.vertices[vi];
                Vec3 orig = touchedPrev[i];
                // Evaluate at the ORIGINAL position — the falloff
                // describes "which verts are affected based on input
                // shape", not the moving target. The transform×falloff
                // convention evaluates at the pre-smooth snapshot
                // positions[].
                float w = evaluateFalloff(falloff_, orig, cast(int)vi, vp);
                mesh.vertices[vi].x = orig.x + (sm.x - orig.x) * w;
                mesh.vertices[vi].y = orig.y + (sm.y - orig.y) * w;
                mesh.vertices[vi].z = orig.z + (sm.z - orig.z) * w;
            }
        }

        // `preserve` (Preserve Volume) projection pass — for
        // every touched vert, remove the component of its motion
        // that goes along its pre-smooth normal. The vert can slide
        // tangentially (laterally on the surface) but can't pop in
        // or out along the normal direction. Net effect on radially-
        // symmetric meshes (e.g. cube smoothed toward centroid is
        // pure normal-direction motion): preserve cancels everything
        // → smooth no-op.
        if (preserve_) {
            foreach (vi; 0 .. mesh.vertices.length) {
                if (!vmask[vi]) continue;
                Vec3 n  = vertNormal[vi];
                Vec3 o  = origPos[vi];
                Vec3 s  = mesh.vertices[vi];
                Vec3 d  = Vec3(s.x - o.x, s.y - o.y, s.z - o.z);
                float dn = d.x * n.x + d.y * n.y + d.z * n.z;
                // s' = s - (d · n) n  =  o + (d − (d · n) n)
                mesh.vertices[vi].x = s.x - dn * n.x;
                mesh.vertices[vi].y = s.y - dn * n.y;
                mesh.vertices[vi].z = s.z - dn * n.z;
            }
        }

        mesh.commitChange(MeshEditScope.Position);
        refreshDisplayActive(mesh);
        return true;
    }

    override bool revert() {
        if (touchedIdx.length == 0) return false;
        foreach (i, vi; touchedIdx)
            if (vi < mesh.vertices.length) mesh.vertices[vi] = touchedPrev[i];
        mesh.commitChange(MeshEditScope.Position);
        refreshDisplayActive(mesh);
        return true;
    }
}
