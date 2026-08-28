module commands.mesh.smooth;

import std.array : uninitializedArray;
import command;
import mesh;
import view;
import editmode;
import math : Vec3, Viewport, AimViewport, aimSpace;
import document : primaryModelSpace;
import params : Param;
import change_bus : MeshEditScope;
import commands.mesh.position_undo : PositionUndo;
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
    private float            sharpThresholdRad_ = -1.0f; // `sharpThreshold`,
    // RADIANS. Wire-native alias for the sharp-edge threshold used by the
    // parity harness / scripting callers whose schema carries the angle in
    // radians (the interactive UI exposes `sharpAngle` in DEGREES instead).
    // Same normal-deviation convention as `sharpAngle`: an interior edge is
    // sharp when the angle between adjacent face normals EXCEEDS the
    // threshold. Sentinel < 0 ⇒ "not supplied", fall back to sharpAngleDeg_;
    // a supplied value (≥ 0) OVERRIDES the degrees field. Kept out of the
    // Tool Properties form (config/forms/smooth.yaml) so it stays a
    // wire-only input and the visible panel is unchanged.
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
    // Recorded `Kind.SetPos` undo (task 1903 L0-d3). ONE entry, from
    // `touchedPrev` — see `applyKernel`'s tail for why the three passes record
    // once rather than three times.
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-d,
        /// witness W-d3a). The op-log SHAPE is not derivable from the outside:
        /// a command that records nothing falls back to its legacy revert and
        /// restores the right positions anyway, so every result-shaped
        /// assertion — the plane diff, the redo cell, the parity cell — is
        /// GREEN over a deleted recorder. Only reading the log itself is not.
        /// `version (unittest)`, so this is not a door in a shipped build; both
        /// gate lanes compile the sources with `-unittest`. `public` on the
        /// declaration and NOT a `public:` section — a section marker here
        /// would silently change the protection of every member below it.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

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
            // Radians alias — wire/scripting callers (e.g. the parity
            // harness) may pass the sharp threshold in radians under this
            // name; overrides `sharpAngle` when supplied (≥ 0). Not surfaced
            // in the UI form.
            Param.float_("sharpThreshold", "Sharp Threshold (rad)", &sharpThresholdRad_, -1.0f),
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
    void setSharpThreshold(float rad) { sharpThresholdRad_ = rad; }
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
        // Task 0619: the real viewport is right here on the subject
        // packet. This command can be handed the LIVE falloff packet
        // below, which may be a Screen/Lasso type, so it needs a real
        // aim space — it used to declare an empty `Viewport` instead.
        const auto aim = aimSpace(subj.viewport, primaryModelSpace());

        // §2.4 — the guard is resolved BEFORE the batch is opened; a `return`
        // out of an open batch leaves `~MeshEditBatch` to pop the frame and
        // tick `changeBus.batchLeaks`, which the suite asserts is 0.
        //
        // It answers TRUE, and that is task 2110's ruling, not a shortcut:
        // `mesh.smooth {iter:0}` answers `ok` and records a history entry, so a
        // `false` from the matching `revert()` would make `CommandHistory.undo`
        // discard that entry AND the whole trailing suffix (regression 0099).
        // The entry it leaves is unarmed, and `revert()`'s legacy arm below
        // answers true for it.
        if (iter_ <= 0 || strn_ <= 0.0f) return true;  // no-op apply

        // REDO: re-run the kernel UNRECORDED and keep the first delta. The
        // laplacian, the falloff blend and the preserve projection are pure
        // functions of the params and the restored pre-op mesh.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed, aim);
            ed.close();
            return ok;
        }
        auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed, aim);
        undo_.arm(ed.close());
        if (!ok) { undo_.disarm(); return false; }
        return true;
    }

    private bool applyKernel(ref MeshEditBatch ed, const ref AimViewport aim) {
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
        // L1 funnel (task 0613, S5): the modal fan-in this used to open-code,
        // with the whole-mesh fallback narrowed to the VISIBLE vertices.
        bool[] vmask = mesh.operandVertexMask(editMode);

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
            // Resolve the effective threshold in DEGREES. A wire-supplied
            // radians `sharpThreshold` (≥ 0) overrides the degrees field;
            // otherwise use `sharpAngle`. computeEdgeSharpness re-applies
            // PI/180 internally, so converting radians→degrees here yields
            // exactly cos(radians) — bit-identical to the reference's
            // cos(sharpThreshold) sharp test.
            import std.math : PI;
            immutable float effSharpDeg = (sharpThresholdRad_ >= 0.0f)
                ? sharpThresholdRad_ * cast(float)(180.0 / PI)
                : sharpAngleDeg_;
            auto sharpness = mesh.computeEdgeSharpness(effSharpDeg);
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
        //
        // TASK 1903 L0-d3 — `mesh.vertices = prev;` USED TO BE HERE, and its
        // retirement is what takes this file to `countRawPositionWrites == 0`.
        // The two passes below now read and write `prev` instead of the live
        // array, and ONE `ed.setVertexPositions` at the tail publishes the
        // composed result. Byte-identical by construction: `prev` and `cur`
        // both start as `mesh.vertices.dup` and are written only at masked
        // indices, so at every swap their UNMASKED entries still hold the
        // original values; `origPos` and `vertNormal` were captured before pass
        // 1; and pass 2 reads its origin from `touchedPrev`, not from the live
        // array. The per-index write also removes the ARRAY-IDENTITY change
        // this line made — nothing holds a slice of `mesh.vertices` today, and
        // the per-index form makes that irrelevant rather than merely true.

        // Falloff blend: lerp each touched vert from its pre-smooth
        // position toward the post-smooth position by per-vert weight.
        // Same way the transform × falloff stage attenuates any
        // deformation — weight 1.0 keeps the full smooth, weight
        // 0.0 leaves the vert at its original. No-op when falloff is
        // disabled. Task 0619: the empty `Viewport` that used to be declared
        // here is gone — see jitter.d for why "cursorless" was wrong. The aim
        // space arrives as a parameter. Falloff is applied BEFORE the
        // preserve-volume pass so the tangent-plane projection sees the
        // weighted result.
        if (falloff_.enabled) {
            foreach (i, vi; touchedIdx) {
                if (vi >= prev.length) continue;
                Vec3 sm = prev[vi];
                Vec3 orig = touchedPrev[i];
                // Evaluate at the ORIGINAL position — the falloff
                // describes "which verts are affected based on input
                // shape", not the moving target. The transform×falloff
                // convention evaluates at the pre-smooth snapshot
                // positions[].
                float w = evaluateFalloff(falloff_, orig, cast(int)vi, aim);
                prev[vi].x = orig.x + (sm.x - orig.x) * w;
                prev[vi].y = orig.y + (sm.y - orig.y) * w;
                prev[vi].z = orig.z + (sm.z - orig.z) * w;
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
            foreach (vi; 0 .. prev.length) {
                if (!vmask[vi]) continue;
                Vec3 n  = vertNormal[vi];
                Vec3 o  = origPos[vi];
                Vec3 s  = prev[vi];
                Vec3 d  = Vec3(s.x - o.x, s.y - o.y, s.z - o.z);
                float dn = d.x * n.x + d.y * n.y + d.z * n.z;
                // s' = s - (d · n) n  =  o + (d − (d · n) n)
                prev[vi].x = s.x - dn * n.x;
                prev[vi].y = s.y - dn * n.y;
                prev[vi].z = s.z - dn * n.z;
            }
        }

        // ONE `SetPos` entry, from the PRE-OP image — task 1903 §2.1's ruling,
        // and the argument is that it is byte-identical to the shipped revert
        // BY CONSTRUCTION: that revert was `vertices[touchedIdx] = touchedPrev`
        // and this entry's `posBefore` IS `touchedPrev`. So nothing has to be
        // argued about how the three passes compose. Per-pass recording (three
        // entries) is also correct under LIFO, but it would write the live mesh
        // three times and triple the log for no observable gain — the batch
        // defers every `commitChange`, so no intermediate state is observable.
        //
        // `touchedIdx` is repeat-free by its own construction loop above (one
        // append per masked index), so the single entry carries no duplicated
        // index and its reverse is unambiguous.
        // PRE-SIZED, NOT `reserve` + append (task 2160): `reserve` removes
        // the reallocation, not the per-element runtime call, and this is an
        // exact-length map — one output per `touchedIdx` entry.
        auto finalPos = uninitializedArray!(Vec3[])(touchedIdx.length);
        foreach (k, vi; touchedIdx) finalPos[k] = prev[vi];
        ed.setVertexPositions(touchedIdx, finalPos);

        ed.commitChange(MeshEditScope.Position);
        return true;
    }

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // THE EMPTY-DELTA ARM. `RecordedUndo.arm` leaves the holder DISARMED
        // when the batch came back with an empty log, so this is the live
        // answer for a forward that succeeded and moved nothing a bitwise diff
        // could see — not dead code, and not a fallback for a path that no
        // longer exists. Until task 1903 Stage N it was also the tracker-off
        // ORACLE the plane-diff cells measured the recorded revert against
        // (W-d3c); that reading died with the hatch, this one did not.
        //
        // It is also the 0099 arm (task 2110): a no-op smooth must answer
        // TRUE, or `CommandHistory.undo` discards this entry and every older
        // one.
        if (touchedIdx.length == 0) return true;   // no-op smooth: positions unchanged, revert succeeds
        // TASK 1903 L0-d — THE LEGACY REVERT WRITES THROUGH THE BATCH TOO.
        // The plan's §2.5 template left this loop "untouched"; that is
        // incompatible with its own §1/§3/W-d1, which require this file to read
        // `countRawPositionWrites == 0` — §1's measured table counts THIS LOOP
        // among the file's raw writes. Resolved the way §2.5 already resolved
        // the forward: the same write, through the same primitive, on an
        // UNRECORDED batch. It stays a genuine oracle for W-d3c because it
        // restores from the command's own stored pre-op array while the delta
        // path replays the op-log's `posBefore` — two independent data paths
        // that share only the write primitive, which is what a mutation of the
        // RECORDING has to be measured against. Byte-identical to the loop it
        // replaces: `setVertexPositions` skips only writes whose new value is
        // BIT-identical to the current one, and writing identical bits back was
        // what the loop did there; the bounds guard is the same `continue`.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        ed.setVertexPositions(touchedIdx, touchedPrev);
        ed.commitChange(MeshEditScope.Position);
        ed.close();
        return true;
    }
}
