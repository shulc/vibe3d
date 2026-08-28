module commands.mesh.bevel;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;
import selection_product : repointToFaceBorder;

/// One-shot Bevel command: dispatches by edit mode.
///   Polygons → bevelFacesByMask(mask, inset, shift, group, segments)
///              [params: inset, shift, group, segments]
///   Edges    → bevelEdgesByMask(mask, width, roundLevel, widthMode)
///              [params: width, roundLevel, widthMode]
/// Empty face-selection ⇒ whole VISIBLE mesh; empty edge-selection likewise
/// (Mesh.operand{Face,Edge}Mask — the L1 funnel, per sibling convention).
/// |inset|<1e-6 && |shift|<1e-6 (polygon) or width<1e-6 (edge) → status:error.
/// The POLYGON path is ring-order dependent since task 1230 (ledger rows
/// 41/47/49): a face whose ring starts at a REFLEX corner bevels the other
/// way, and one whose ring starts at a COLLINEAR corner still builds its ring
/// but moves it nowhere. Deliberate — see `math.ringStartCornerSign`.
///
/// Neutral param names (task 0391 — NEVER the reference-editor's own names
/// in source/tests/config — repo neutrality convention):
///   edge: `width` (== reference Value; with `widthMode` false the value
///         maps 1:1 to the reference's inset-mode Value), `roundLevel`
///         (== reference Round Level `level` — TRUE circular arc),
///         `widthMode` (== reference `mode` inset|width selector; false =
///         inset, the default, byte-identical to the pre-change path; true =
///         perpendicular width, slide = width/sin(dihedral/2)).
///   poly: `inset`, `shift` (unchanged), `group` (== reference `group`,
///         default TRUE at this command layer — reference default;
///         `bevelFacesByMask`'s own kernel default stays `false` so the
///         pre-0391 per-face-independent unittests are unaffected),
///         `segments` (== reference `segs` — LINEAR staircase, a
///         DIFFERENT law from edge's Round Level arc).
/// TASK 1903 STAGE L7-b — THE POLYGON ARM'S UNDO IS THE OPERATION-LOG DELTA;
/// THE EDGE ARM'S IS STILL A `MeshSnapshot`, AND THAT IS A STATED REFUSAL
/// rather than an omission (plan §6.6: a declined class is recorded at its
/// declaration, with the measurement). One class, two arms, two undo paths,
/// selected by `editMode` exactly as the two kernels are.
///
/// There is no `undoTrackerEnabled()` fork to select between — grep it, this
/// file never carried one — so the polygon arm's recording batch is
/// unconditional, in `commands/mesh/delete.d`'s shape after Stage L3-b.
///
/// ---------------------------------------------------------------------------
/// WHAT THE POLYGON ARM NEEDED, because the row said "an arming" and it was
/// something else entirely. `bevelFacesByMask` installed its CAP
/// (`ed.faces[fi] = finalVerts`) and its SQUARE SPLICE into an UNSELECTED
/// neighbour (`ed.faces[fi] = rebuilt`) with raw indexed writes that reached
/// no record primitive. Measured before Stage L7-P2, at the kernel, under a
/// RECORDING batch: the op-log was `[AddVerts, AddFaces]` per processed face
/// with NO face entry at all, and `revert()` THREW
/// (`index [16] is out of bounds for array of length 16`). Both installs now
/// go through `Mesh.setFaceWindings` — TWO bulk calls, not one, because the
/// splice changes ARITY and its payload must describe the corner space as it
/// is AFTER the cap call has run. Armed with nothing: neither kernel reaches
/// `rewriteFaces` at all, so `Kind.FaceReindex` was never the answer here.
///
/// ---------------------------------------------------------------------------
/// WHY THE EDGE ARM IS DECLINED, MEASURED AND NOT ASSUMED.
///
/// `bevelEdgesByMask` rewrites `faces` TWICE under ONE `beginCornerRewrite`
/// handle and declares only after the second, so between them the per-corner
/// map describes the PRE-op corner space while `faces` describes the
/// post-first-rewrite one, `polyVertexMapsInStepWithFaces()` is false and
/// `recordPolyVertexPayload` DECLINES SILENTLY. Unarmed, its op-log is
/// `[AddVerts, RemoveVerts, Reindex]` — nothing names the face change — and
/// `revert()` THROWS (`index [17] is out of bounds for array of length 16`).
/// Three candidate shapes were measured, and all three are refused today:
///
///   (a) route rewrite #1 through `Mesh.setFaceWindings` — INADMISSIBLE. That
///       primitive cannot add faces, and rewrite #1 GROWS the face count:
///       measured 9 -> 11 for one interior edge and 9 -> 12 for two on
///       `makeTaggedGridFull(3)`.
///   (b) two `beginCornerRewrite` handles, one per rewrite, declaring
///       `carriedPerFace` between them — UNSOUND. The merge pass can leave a
///       corner standing on a vertex its source face does not contain, and the
///       instrumented pooling that would expose it fires ZERO times on the
///       stands available, so a green under (b) stands over a cell that cannot
///       exhibit the defect.
///   (c) arm both rewrites as they are — REFUSED on the §5.3 rule that an
///       armed op losing a VALUE is declined, not fudged. The armed residual
///       carries a Point-domain map VALUE: the vertices the chamfer consumes
///       come back with their point-map values ZEROED, because
///       `removeVertsReverse` re-inserts a dropped vertex and zeroes its
///       Point-domain map values by its own documented convention. Closing
///       that is a PAYLOAD FIELD on `MeshOpEntry`, which belongs to the stage
///       that sizes it for all thirteen of its consumers at once.
///
/// So `face_reindex_arming_test.d`'s roster stays at NINE sites BECAUSE of
/// this, and the edge arm keeps `snap`. A future stage that lands the
/// point-domain payload retires this whole paragraph together with the
/// `MeshSnapshot` field.
///
/// ---------------------------------------------------------------------------
/// THE POLYGON ARM'S TWO BELTS, and neither is copied from the neighbouring
/// file — both were chosen from a measurement:
///
///   * `DenseSelectionUndo`, because the kernel's tail re-derives the face
///     selection and the op-log has nothing that puts the pre-op bits back.
///   * `preMaps_`, because the GROUP path ends in `compactUnreferenced`
///     (measured: `[.., RemoveVerts, Reindex]` on a grouped full-mask bevel),
///     and `removeVertsReverse` zeroes a re-inserted vertex's Point-domain map
///     VALUES — Stage L5-b's payload deliberately covers the SET MASKS only
///     (§L5.3 says so in as many words). `MeshDelete` and `MeshCleanup` carry
///     exactly this belt for exactly this residual.
///
/// `commands/mesh/poly_inset.d` next door carries NEITHER belt, because its
/// measured residual is EMPTY — it reaches no compaction and its tail only
/// resizes the selection. The difference is per command and is not a style.
///
/// NO MARKS PUBLISHER IS BUILT. `Kind.SelectionDelta` cannot carry the plane —
/// its restore mints a FRESH order stamp off the counter and no delta kind
/// carries a selection-order stamp — so a publisher would be a second, lossy
/// writer over a plane the dense image already owns. See
/// `commands/mesh/selection_undo.d`'s header.
class MeshBevel : Command, Operator {
    mixin OperatorActrCommon;
    /// THE EDGE ARM'S undo, and the ONLY thing left holding one — see the
    /// class doc comment for the three measured candidates that refuse it a
    /// delta.
    private MeshSnapshot       snap;
    /// THE POLYGON ARM'S undo.
    private MeshEditDelta      delta_;
    /// The pre-op selection of all three domains, their order stamps and all
    /// three counters — see the class doc comment for the two writers it is
    /// the answer to. Captured on the RECORDING arm only: a second capture on
    /// redo would image the POST-op selection.
    private DenseSelectionUndo preSel_;
    /// The whole mesh-map set, BY VALUE, pre-op — `MeshDelete`'s and
    /// `MeshCleanup`'s belt, for the residual named at the class doc comment.
    private MeshMap[]          preMaps_;
    /// See `commands/mesh/poly_inset.d`'s `recorded_`.
    private bool               recorded_;
    private float            inset_      = 0.1f;
    private float            shift_      = 0.0f;
    private bool             group_      = true;
    private int              segments_   = 0;
    private bool             square_     = false;
    private float            width_      = 0.1f;
    private int              roundLevel_ = 0;
    private bool             widthMode_  = false;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.bevel"; }
    override string label() const { return "Bevel"; }

    /// The declared scope follows the ARM: the two kernels declare different
    /// classes and `editMode` is what picks between them, exactly as the two
    /// undo paths below do.
    override MeshEditScope editScope() const {
        return editMode == EditMode.Edges
             ? cast(MeshEditScope) kEdgeBevelEditScope
             : cast(MeshEditScope) kPolyBevelEditScope;
    }

    /// Observable through `/api/history`'s `opInverse` field — and on THIS
    /// class it is genuinely per-instance rather than per-class, because the
    /// two arms undo differently. `recorded_` is set only on the polygon arm.
    override bool isOperationInverse() const { return recorded_; }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log — see
        /// `commands/mesh/poly_inset.d`'s accessor for why the cells assert a
        /// KIND SEQUENCE and never a length.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override Param[] params() {
        if (editMode == EditMode.Edges)
            return [
                Param.float_("width", "Width", &width_, 0.1f),
                Param.int_("roundLevel", "Round Level", &roundLevel_, 0)
                    .min(0).max(MAX_ROUND_LEVEL).enforceBounds(),
                // `widthMode` selects how `width` maps to the along-face corner
                // slide (see `bevelEdgesByMask`'s doc): false (default) = the
                // value IS the slide (inset), byte-identical to the pre-change
                // path; true = the value is the true PERPENDICULAR bevel width,
                // so the slide is `width / sin(dihedral/2)` per selected edge.
                Param.bool_("widthMode", "Width Mode", &widthMode_, false),
            ];
        return [
            Param.float_("inset", "Inset", &inset_, 0.1f),
            Param.float_("shift", "Shift", &shift_, 0.0f),
            Param.bool_("group", "Group Polygons", &group_, true),
            Param.int_("segments", "Segments", &segments_, 0)
                .min(0).max(MAX_BEVEL_SEGMENTS).enforceBounds(),
            // task 0458 Phase 3: recovered Square Corner topology rewrite
            // (`bevelFacesByMask`'s `square` — the reference's square-cap
            // boundary-mark + rebuild, findings.md §3), parity-fixture-verified
            // (Q1-Q4). Promoted out of Hidden alongside the interactive
            // `poly.bevel` tool's own Tool Properties toggle
            // (tools/edit/poly_bevel.d) now that the kernel + fixtures
            // are green.
            Param.bool_("square", "Square Corner", &square_, false),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // THE EDGE ARM IS STILL DENSE — see the class doc comment. It keeps
        // the pre-L7 body verbatim, including the snapshot-drop on refusal,
        // so that flipping it later is a self-contained change.
        if (editMode == EditMode.Edges) {
            snap = MeshSnapshot.capture(*mesh);
            immutable size_t nEdge = runKernel(false);   // UNRECORDED batch
            if (nEdge == 0) { snap = MeshSnapshot.init; return false; }
            return true;
        }

        // REDO: `CommandHistory.redo` re-runs `apply()` -> `evaluate`. Re-run
        // the polygon arm BATCHLESS and keep the FIRST delta.
        if (recorded_) return runKernel(false) != 0;

        // The belts, captured on the recording arm only — a second capture on
        // redo would image the POST-op state.
        preSel_.capture(*mesh);
        preMaps_ = new MeshMap[](mesh.meshMaps.length);
        foreach (i, ref mm; mesh.meshMaps) preMaps_[i] = mm.dup;

        immutable size_t n = runKernel(true);

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove` /
        // `mesh.cleanup` / `mesh.poly_inset` (Stage L3-a, ruling Q-K6).
        // `n == 0` is the kernel's own refusal — an empty/undersized mask, or
        // one emptied by `maskMinusHiddenFaces` — and `affected == 0` turns it
        // into this command's. `n > 0` over an EMPTY delta is the
        // contradiction: `acceptRecordedEdit` REFUSES it and ticks
        // `changeBus.emptyDeltaOverMutation`, rather than recording a history
        // entry whose undo would do nothing.
        //
        // `delta_.revert` on the refusal arm is a BELT: `bevelFacesByMask`
        // decides `processed == 0` only after its loop, and a face that
        // refused was `continue`d before any mutation of its own. It costs one
        // statement over an empty log and does not rely on that reading.
        if (!acceptRecordedEdit(n, delta_)) {
            delta_.revert(*mesh);
            delta_   = MeshEditDelta.init;
            preSel_  = DenseSelectionUndo.init;
            preMaps_ = null;
            return false;
        }
        recorded_ = true;
        return true;
    }

    /// The one mutating body, under whichever arm and whichever batch kind.
    /// `recording == false` is the REDO path AND the whole EDGE arm: an
    /// unrecorded batch makes every tracker hook take its
    /// `editRecorder_ is null` first line.
    private size_t runKernel(bool recording) {
        size_t n = 0;

        if (editMode == EditMode.Polygons) {
            auto mask = mesh.operandFaceMask();
            // Task 1903 Stage F2 — the batch opens at the command boundary
            // (§4.1) and is scoped to the POLYGON ARM ALONE. Not to
            // `evaluate`, and deliberately not around the `else` arm: each
            // arm calls a different family's kernel and each opens its own.
            // (Until Stage G the `else` arm had NO batch — `bevelEdgesByMask`
            // was still a mixin member — and the narrowing was what kept F2
            // from changing that path's publish shape; G gave it its own,
            // narrow, batch rather than widening this one.) RECORDING on the
            // first run, UNRECORDED on redo — Stage L7-b.
            //
            // `bevelFacesByMask` reaches no `rewriteFaces`, so nothing here is
            // ARMED; what makes the delta usable is Stage L7-P2's winding
            // publisher at its two indexed installs.
            if (recording) {
                auto ed = MeshEditBatch(*mesh, kPolyBevelEditScope);   // RECORDING
                n = ed.bevelFacesByMask(mask, inset_, shift_, group_, segments_, square_);
                delta_ = ed.close();
            } else {
                auto ed = MeshEditBatch.unrecorded(*mesh, kPolyBevelEditScope);
                n = ed.bevelFacesByMask(mask, inset_, shift_, group_, segments_, square_);
                ed.close();
            }
        } else if (editMode == EditMode.Edges) {
            auto mask = mesh.operandEdgeMask();
            // Task 1903 Stage G — the EDGE arm's batch, opened at the command
            // boundary (§4.1) and scoped to the kernel call ALONE, exactly as
            // the polygon arm above is. Until this stage the arm had none, and
            // the suite's `mesh.bevel` EDGE cell asserted
            // `unbatchedGeometryCommits > 0` as the NEGATIVE CONTROL that F2's
            // polygon batch had not spread across `evaluate`; that cell is
            // flipped to `== 0` in this commit, which is the only way it can
            // witness this open.
            //
            // STAYS UNRECORDED — `recording` is never true on this arm. That
            // is Stage L7's stated refusal, not an oversight; the three
            // measured candidates and what each one costs are at the class doc
            // comment, and `tests/unit/l7_bevel_inset_delta_test.d` asserts the
            // refusal is REAL (an op-log this command records here would mean
            // somebody flipped it without the point-domain payload).
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kEdgeBevelEditScope);
                n = ed.bevelEdgesByMask(mask, width_, roundLevel_, widthMode_);
                ed.close();
            }
            // Task 1180: the kernel leaves the new band's FACES selected —
            // that IS the product, and it is how the band is named without a
            // second pass. The reference selects the band ONE DIMENSION DOWN:
            // its edges and the vertices they span, and none of its faces. So
            // convert here, at the command layer, leaving the kernel (and the
            // other callers that read its face selection) untouched.
            if (n > 0) {
                uint[] band;
                foreach (fi, sel; mesh.selectedFaces)
                    if (sel) band ~= cast(uint) fi;
                repointToFaceBorder(mesh, band);
            }
        }
        return n;
    }

    override bool revert() {
        // THE EDGE ARM, still dense. `snap.filled` is false on the polygon arm
        // (nothing captures it there), so the two cannot be confused.
        if (snap.filled) { snap.restore(*mesh); return true; }

        // See `commands/mesh/poly_inset.d`'s guard — and it is NOT the
        // spelling for a command that DID record (regression 0099).
        if (!recorded_) return false;

        // ORDER IS LOAD-BEARING, and it is `delete.d`'s: replay -> maps ->
        // selection. `applyFaceReindexReverse` installs a WHOLE `faceMarks`
        // array and `MeshEditDelta.finalize` rebuilds `edges`, so a selection
        // restore running first would be overwritten by the one and would
        // have keyed on the wrong edge index space for the other. The maps go
        // between them: they are sized against the geometry the replay just
        // restored, and the selection restore does not touch them.
        delta_.revert(*mesh);
        if (preMaps_.length) {
            mesh.meshMaps.length = preMaps_.length;
            foreach (i, ref mm; preMaps_) mesh.meshMaps[i] = mm.dup;
        }
        preSel_.restore(*mesh);
        return true;
    }
}
