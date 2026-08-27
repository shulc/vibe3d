module commands.mesh.transform;

import std.json;

import command;
import mesh;
import view;
import editmode;
import math : Vec3, Vec4, mulMV, pivotRotationMatrix, pivotScaleMatrix;
import change_bus : MeshEditScope;
import mesh_edit_delta   : undoTrackerEnabled;
import commands.mesh.position_undo : PositionUndo;
import toolpipe.packets  : SubjectPacket, SymmetryPacket;
import symmetry          : applySymmetryMirror, applySymmetryMirrorDelta, projectOnPlane;
import symmetry_pick     : captureLiveSymmetry;
import operator          : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
// GpuMesh lives in mesh.d, already imported above.

/// Transform the selected vertices by translate / rotate / scale. Replaces
/// the legacy /api/transform direct handler. Selection-aware: in Vertices
/// mode transforms selected verts; in Edges/Polygons modes transforms the
/// verts of the selected edges/faces.
///
/// Revert: snapshots the affected vertex positions before mutation.
class MeshTransform : Command, Operator {
    // Phase 5 of doc/operator_refactor_plan.md.
    mixin OperatorActrCommon;


    private string kind;          // "translate" / "rotate" / "scale"
    private Vec3   delta;         // for translate
    private Vec3   axis;          // for rotate
    private float  angle;         // for rotate
    private Vec3   factor;        // for scale
    private Vec3   pivot;

    // Snapshot for revert: indices + their pre-apply positions. Kept after
    // task 1903 §L0-b as the TRACKER-OFF ORACLE, not as the default undo —
    // `undo_` below serves the default path and this array is what the parity
    // cell measures it against.
    private uint[] touchedIdx;
    private Vec3[] touchedPrev;
    private bool   captured;

    // Recorded `Kind.SetPos` undo (task 1903 §L0-b).
    private PositionUndo undo_;
    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (task 1903 §L0-b,
        /// witness W-b1). The op-log SHAPE is not derivable from the outside:
        /// this command's legacy `touchedIdx`/`touchedPrev` capture ALREADY
        /// covers the mirror partner, so a build that records nothing still
        /// reverts correctly and every result-shaped assertion is green. Only
        /// reading the log itself is not. `version (unittest)`, so this is not
        /// a door in a shipped build; both gate lanes compile with `-unittest`.
        /// `public` on the declaration and NOT a `public:` section — a section
        /// marker here would silently change the protection of every member
        /// below it.
        public ref const(PositionUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
        this.delta  = Vec3(0, 0, 0);
        this.axis   = Vec3(0, 1, 0);
        this.factor = Vec3(1, 1, 1);
        this.pivot  = Vec3(0, 0, 0);
        this.angle  = 0.0f;
    }

    override string name() const { return "mesh.transform"; }
    override string label() const { return "Transform " ~ kind; }

    void setKind(string k)    { kind   = k; }
    void setDelta(Vec3 d)     { delta  = d; }
    void setAxis(Vec3 a)      { axis   = a; }
    void setAngle(float a)    { angle  = a; }
    void setFactor(Vec3 f)    { factor = f; }
    void setPivot(Vec3 p)     { pivot  = p; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // §2.4 — EVERY GUARD AND EVERY THROW RESOLVES BEFORE A BATCH OPENS.
        // This `throw` used to sit in the kind-switch's `default:` arm, i.e.
        // INSIDE the edit. `MeshEditBatch.~this` must never assert, so an
        // exception thrown out of an open batch takes the destructor's LEAK
        // path — the frame is popped and `changeBus.batchLeaks` moves, which
        // the suite asserts is 0. Hoisting it is a pure move: nothing had been
        // written before the switch, and `captureLiveSymmetry` below was
        // already gated on the same three names, so an invalid kind never
        // reached the pipeline either. It is `vertex_set`'s hoisted axis throw
        // in this file's shape.
        if (kind != "translate" && kind != "rotate" && kind != "scale")
            throw new Exception("invalid kind '" ~ kind ~
                                "', expected translate/rotate/scale");

        // REDO (CommandHistory.redo): re-run the kernel UNRECORDED and keep
        // the first delta. The kernel is a function of the params, the
        // restored pre-op mesh, the selection and the live symmetry packet, so
        // the replay lands where the first run landed and the delta's
        // `posBefore` still inverts it exactly.
        if (undo_.armed()) {
            auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed);
            ed.close();
            return ok;
        }
        if (undoTrackerEnabled()) {
            auto ed = MeshEditBatch(*mesh, MeshEditScope.Position);
            const ok = applyKernel(ed);
            undo_.arm(ed.close());
            if (!ok) { undo_.disarm(); return false; }
            return true;
        }
        // Legacy path (VIBE3D_UNDO_TRACKER=off). The SAME kernel through an
        // UNRECORDED batch, so this file's raw-write census row is 0 on BOTH
        // paths rather than only on the one the default happens to take.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        const ok = applyKernel(ed);
        ed.close();
        return ok;
    }

    // -----------------------------------------------------------------------
    // THE RECORDING STRATEGY IS PER PASS, AND THE TWO PASSES ARE NOT THE SAME
    // SHAPE (plan §L0.2's arity note, §L0.3's (A) and (D)).
    //
    //   pass 1, the kind switch — shape (A). It writes only vertices this
    //     command chose, so it accumulates into a local and makes ONE
    //     `ed.setVertexPositions` after the loop. Its before-image is
    //     `touchedPrev`, captured immediately above it.
    //   pass 2, the symmetry mirror — shape (D). It writes through
    //     `source/symmetry.d`, which this command may not change (its other
    //     callers are `source/tools/transform/**`, task 1905/T2's zone) and
    //     which writes `mesh.vertices[…]` RAW — under a recording batch that
    //     produces NO op-log entry, because `alias mesh this` makes the raw
    //     spelling compile. Its before-image is the mesh AFTER pass 1, dup'd
    //     just before the call, and it is recorded by DIFF.
    //
    // §L0.2 forbids MIXING the two strategies, and this is not a mix: "mixed"
    // means one pass recorded per-pass while another is recorded from the
    // WHOLE-op pre-image, so one vertex's `posBefore` is claimed twice for the
    // same value. Here each pass is recorded against ITS OWN before-image, so
    // a vertex both passes touch (an on-plane selected vertex: translated,
    // then projected back onto the plane) carries two entries that chain —
    // entry 2 reverts it to the post-pass-1 value, entry 1 to the pre-op one.
    // Both index sets are repeat-free, which is памятка 30's condition:
    // pass 1's is the vmask enumeration, pass 2's is a diff over the array.
    // -----------------------------------------------------------------------
    private bool applyKernel(ref MeshEditBatch ed) {
        // Build affected-vertex mask from selection + edit mode (matches
        // the original transformHandler in app.d).
        //
        // Perf (task 0388): `mesh.selectedX` is a @property that rebuilds a
        // whole `bool[]` per read — indexing it inside these loops was
        // O(mesh²). Iterate the lock-step `*Marks.length` and test via the
        // non-allocating `isXSelected(i)` scalar accessor instead.
        bool[] vmask = new bool[](mesh.vertices.length);
        if (editMode == EditMode.Vertices) {
            foreach (i; 0 .. mesh.vertexMarks.length)
                if (mesh.isVertexSelected(i)) vmask[i] = true;
        } else if (editMode == EditMode.Edges) {
            foreach (i; 0 .. mesh.edgeMarks.length)
                if (mesh.isEdgeSelected(i))
                    foreach (vi; mesh.edges[i]) vmask[vi] = true;
        } else if (editMode == EditMode.Polygons) {
            foreach (i; 0 .. mesh.faceMarks.length)
                if (mesh.isFaceSelected(i))
                    foreach (vi; mesh.faces[i]) vmask[vi] = true;
        }

        // Phase 7.6b: snapshot the symmetry packet BEFORE the transform
        // mutates the mesh — the pair table is built from
        // `mesh.vertices`, so the moment we touch a selected vertex the
        // SymmetryStage's cache would get invalidated against a
        // half-mutated mesh and rebuild against the wrong positions.
        // Capturing the slice header here keeps `pairOf` / `onPlane`
        // anchored to the symmetric pre-mutation mesh.
        //
        // We only fire pipeline.evaluate when the SymmetryStage is
        // actually enabled — pipeline.evaluate has cross-stage side
        // effects (FalloffStage caches the upstream workplane normal
        // every evaluate; firing it from a transform path that never
        // touched symmetry would leak workplane state into the
        // falloff stage's auto-size cache, breaking subsequent
        // auto-size operations that expect a freshly-set workplane).
        // That gate now lives once in `symmetry_pick.d ::
        // captureLiveSymmetry` (task 1904 Stage 2), shared with
        // `MeshSelect` and the interactive symmetric*Select* helpers
        // instead of being copied a third time here. selType stays left
        // at its default (Vertex) inside that shared function: this is
        // the legacy vertex/edge/polygon transform command (the item
        // path is XfrmTransformTool, not MeshTransform), and this class
        // has no SelType/SelTypeOrder reference to read.
        // `symm` may end up holding a disabled (default `.init`) packet
        // copy — `captureLiveSymmetry`'s `out` parameter is reset on every
        // call, including its early-return gates — so every read of `symm`
        // below is guarded by `symmActive`, never by `symm` alone.
        //
        // The kind gate this call used to carry is gone: `evaluate` now
        // throws on any kind but the three, ABOVE the batch (§2.4), so by
        // here `kind` is one of them by construction.
        SymmetryPacket symm;
        bool           symmActive = false;
        {
            import toolpipe.stages.symmetry : SymmetryStage;
            SymmetryStage symStageUnused;
            captureLiveSymmetry(mesh, effectiveViewport(), editMode,
                                symm, symStageUnused);
            symmActive = symm.enabled
                      && symm.pairOf.length == mesh.vertices.length;
        }

        // Snapshot the touched verts only. The TRACKER-OFF `revert()` restores
        // them. With symmetry active we also capture each selected vert's
        // mirror counterpart so that revert undoes the mirror write too.
        //
        // NOTE FOR ANYONE MEASURING THIS FILE: that partner capture is why a
        // migration of this command is invisible to every result-shaped check.
        // The legacy path was already complete over both passes, so deleting
        // the pass-2 recorder leaves the forward correct, the census row at 0,
        // and the undo correct WHENEVER the tracker is off. Only the op-log
        // and the ARMED revert can see it (task 1903 §L0-b, W-b1).
        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i; 0 .. mesh.vertices.length) {
            if (vmask[i]) {
                touchedIdx  ~= cast(uint)i;
                touchedPrev ~= mesh.vertices[i];
            }
        }
        // The prefix of `touchedIdx` that pass 1 writes: everything appended
        // by the loop above, i.e. exactly the vmask set, in enumeration order.
        // Read BEFORE the partner append below extends the array.
        const size_t nSel = touchedIdx.length;
        if (symmActive) {
            foreach (vi; 0 .. mesh.vertices.length) {
                if (!vmask[vi]) continue;
                if (symm.onPlane[vi]) continue;
                int mi = symm.pairOf[vi];
                if (mi < 0 || mi == cast(int)vi) continue;
                if (vmask[mi]) continue;
                touchedIdx  ~= cast(uint)mi;
                touchedPrev ~= mesh.vertices[mi];
            }
        }
        captured = true;

        // Snapshot baseline for the topological-symmetry delta-mirror path.
        // Taken AFTER the touched-set capture (which reads mesh.vertices) so
        // the snapshot and the touched-prev array are consistent.
        Vec3[] baseAll;
        if (symmActive && symm.topology) baseAll = mesh.vertices.dup;

        // ---- PASS 1: the kind switch, shape (A) ---------------------------
        // `touchedPrev[k]` IS `mesh.vertices[touchedIdx[k]]` for k < nSel — it
        // was read from the unmutated mesh three statements ago and no vertex
        // is enumerated twice — so computing from it is byte-identical to the
        // in-place `mesh.vertices[i].x += …` this replaces.
        bool   wrote = false;
        Vec3[] newPos;
        switch (kind) {
            case "translate":
                newPos.reserve(nSel);
                foreach (k; 0 .. nSel) {
                    Vec3 p = touchedPrev[k];
                    p.x += delta.x;
                    p.y += delta.y;
                    p.z += delta.z;
                    newPos ~= p;
                }
                wrote = true;
                break;
            case "rotate":
                // pivotRotationMatrix requires a normalised axis (see its doc
                // comment in math.d) — the caller (HTTP /api/transform) may
                // pass any non-unit vector, which would otherwise bake a
                // scale into the "rotation" (diagonal terms pick up
                // axis-component^2). A near-zero axis has no well-defined
                // direction at all, so treat it as a no-op rather than
                // collapsing every touched vertex onto the pivot. `wrote`
                // stays false on that arm and NOTHING is written — same as
                // the skipped loop it replaces.
                float axisLen = axis.length;
                if (axisLen > 1e-6f) {
                    auto mrot = pivotRotationMatrix(pivot, axis / axisLen, angle);
                    newPos.reserve(nSel);
                    foreach (k; 0 .. nSel) {
                        auto v0 = Vec4(touchedPrev[k].x,
                                       touchedPrev[k].y,
                                       touchedPrev[k].z, 1.0f);
                        auto v1 = mulMV(mrot, v0);
                        newPos ~= Vec3(v1.x, v1.y, v1.z);
                    }
                    wrote = true;
                }
                break;
            case "scale":
                auto msc = pivotScaleMatrix(pivot, factor.x, factor.y, factor.z);
                newPos.reserve(nSel);
                foreach (k; 0 .. nSel) {
                    auto v0 = Vec4(touchedPrev[k].x,
                                   touchedPrev[k].y,
                                   touchedPrev[k].z, 1.0f);
                    auto v1 = mulMV(msc, v0);
                    newPos ~= Vec3(v1.x, v1.y, v1.z);
                }
                wrote = true;
                break;
            default:
                // UNREACHABLE: `evaluate` throws on every other kind BEFORE
                // this batch opened (§2.4). An `assert(false)` and not a
                // silent `break`, because the quiet direction here is a
                // command that answers `ok` having written nothing.
                assert(false, "MeshTransform.applyKernel: unreachable kind '"
                            ~ kind ~ "' — evaluate() rejects every kind but "
                            ~ "translate/rotate/scale above the batch");
        }
        if (wrote) ed.setVertexPositions(touchedIdx[0 .. nSel], newPos);

        // ---- PASS 2: the symmetry mirror, shape (D) -----------------------
        // Uses the pair table captured BEFORE the switch above; mirrors each
        // selected vertex's new position into its plane-counterpart, and
        // projects on-plane selected verts back onto the plane.
        if (symmActive) {
            // The `.dup` is guarded, not unconditional: on the redo and
            // tracker-off arms the batch records nothing and this whole image
            // would be built only to be discarded (`recordPositionDiff`
            // early-outs before the compare, but the caller owns the copy).
            Vec3[] preMirror;
            if (ed.recording()) preMirror = mesh.vertices.dup;

            auto alsoTouched = new bool[](mesh.vertices.length);
            if (symm.topology)
                applySymmetryMirrorDelta(mesh, symm, baseAll, vmask, alsoTouched);
            else
                applySymmetryMirror(mesh, symm, vmask, alsoTouched);

            // NOT `alsoTouched`, and that is a measured choice, not taste:
            // the array under-reports (an on-plane projection writes
            // `vertices[i]` and sets no bit) and over-reports (a mirror write
            // landing on the value already there sets one). Under-reporting is
            // fatal for a delta — the missing partner comes back at its
            // POST-op position on undo. `commands/mesh/symmetrize.d` had
            // already written that down at its own movement gate.
            ed.recordPositionDiff(preMirror);
        }

        ed.commitChange(MeshEditScope.Position);
        return true;
    }

    override bool revert() {
        if (undo_.armed()) return undo_.revert(*mesh);
        // THE TRACKER-OFF ORACLE. Kept, not deleted: the parity cell runs the
        // same sequence with the tracker off and diffs the two post-revert
        // dumps against each other, so this is the reference the recorded
        // revert is measured against (W-b4).
        if (!captured) return false;
        // TASK 1903 §L0-b — THE LEGACY REVERT WRITES THROUGH THE BATCH TOO,
        // for the reason L0-d recorded at the same line in nine other files:
        // §2.5's "leave the loop untouched" is incompatible with §1/§3/W-d1's
        // `countRawPositionWrites == 0` for this file, because that count
        // includes this loop. Resolved as §2.5 already resolved the forward —
        // the same write, through the same primitive, on an UNRECORDED batch.
        // It stays a genuine oracle: it restores from this command's own
        // stored pre-op array while the delta path replays the op-log's
        // `posBefore`, two independent data paths sharing only the write
        // primitive. Byte-identical to the loop it replaces —
        // `setVertexPositions` skips only writes whose new value is
        // BIT-identical to the current one (writing identical bits back was
        // what the loop did there), and its out-of-range `continue` is the
        // same guard as the old `vid < mesh.vertices.length`.
        auto ed = MeshEditBatch.unrecorded(*mesh, MeshEditScope.Position);
        ed.setVertexPositions(touchedIdx, touchedPrev);
        ed.commitChange(MeshEditScope.Position);
        ed.close();
        return true;
    }
}
