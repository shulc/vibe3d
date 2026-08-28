module commands.mesh.stroke_extrude;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// One-shot, headlessly-testable path-follow extrude (task 0323 "Sketch
/// Extrude" port — basic/captured scope only; curved paths, the exact
/// screen-Precision→span-count law, and Scale/Spin per-band modulation are
/// explicit non-goals for this pass, TODO — not invented). Extrudes the
/// currently selected polygon set along an explicit WORLD-SPACE path-point
/// list.
///
/// The interactive tool (`tool.strokeExtrude`) samples this list live from
/// a drawn viewport stroke and feeds it through the generic record-flavor
/// `MeshSessionEdit` (wire name "mesh.strokeExtrude_edit") on commit; a
/// caller driving THIS command
/// directly (HTTP `/api/command`, `dub test`) supplies the path list
/// verbatim — decoupling the topology kernel from the drag/raycast
/// heuristics (see StrokeExtrudeTool's doc comment for what there is
/// captured-exact vs. a documented default).
///
/// Parameters:
///   - path        — Vec3Array. World-space path points, length >= 2.
///                    `path[0]` is the anchor (nominally the selection's
///                    own position when the stroke began); N =
///                    path.length-1 new bands are created.
///   - alignToPath — bool. Reference "Align to Path" default ON (captured
///                    toolcard spec default) — see
///                    `mesh_ops.revolve.extrudeAlongPath`'s doc comment for what this
///                    does and its curved-path TODO/unverified scope.
///
/// Undo: the OPERATION-LOG DELTA plus a dense selection image (task 1903
///       stage L8-c). It was snapshot-based until then, and the sentence that
///       stood here ("consistent with mesh.sweep / mesh.bridge /
///       mesh.radial_array") is now true of none of the three: all three
///       migrated at stages L10 and L6.
/// TASK 1903 STAGE L8-c — UNDO IS THE OPERATION-LOG DELTA; the whole-mesh
/// `MeshSnapshot` is gone. There is no `undoTrackerEnabled()` fork to select
/// between — grep it, this file never carried one; the two hatched
/// `edge_extend`/`edge_extrude` names CLAUDE.md lists are the interactive
/// TOOLS (`source/tools/edit/`), not the commands — so the recording batch is
/// unconditional, in `commands/mesh/poly_inset.d`'s shape after stage L7-a.
///
/// STAGE L8 BUILT NO PUBLISHER AND ARMED NOTHING, and it is the first family
/// of the track that needed neither. ``mesh_ops.revolve.extrudePathStep_`` was already armed
/// at stage K (`tests/unit/face_reindex_arming_test.d`'s `kArmedSites`), so
/// this command's op-log on the frozen stand was ``[AddVerts, MeshMapDelta, FaceReindex]` PER SPAN`
/// BEFORE the migration began — measured, not assumed. What the migration
/// adds is the `DenseSelectionUndo` below and the deletion of the snapshot.
///
/// THE `DenseSelectionUndo` IS NOT DECORATION — it is the WHOLE residual.
/// Measured plane-for-plane on `makeTaggedGridBent(3)`, reported BOTH ways,
/// an armed revert of this kernel leaves exactly SIX Select-class planes: `edgeMarks`, `faceMarks`, `faceSelectionOrder`,
/// `orderCounters`, `vertexMarks` and `vertexSelectionOrder`. Every other plane —
/// `map:uv`, `map:W`, `faceMaterial`, `facePart`, both set masks, the vertex
/// positions, the windings and all three counts — comes back BYTE-IDENTICAL,
/// and the Subpatch bit on face 1 and the Hide bit on face 5 come back INSIDE
/// `faceMarks`, which is how we know the residue is the SELECT bit and not
/// "the marks word is lost". That is also why this command carries no
/// `preMarksWord_` belt: there is nothing for one to catch.
class MeshStrokeExtrude : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta    delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` has recorded a delta. It discriminates FIRST RUN
    /// from REDO — `CommandHistory.redo` calls `apply()` again and a second
    /// recording run would lay a second delta over the first — and it is
    /// `revert()`'s guard: an instance whose `evaluate` refused holds an empty
    /// delta and must not replay it, which is what the deleted
    /// `if (!snap.filled) return false;` did.
    private bool             recorded_;

    private Vec3[] path_;
    private bool   alignToPath_ = true;

    // DoS backstop (same class as the Radial Array count clamp — a huge
    // JSON-supplied path list over HTTP must not explode geometry).
    // `extrudeAlongPath` also clamps internally at 4096 spans
    // (defense-in-depth for the shared kernel); this bound agrees with it
    // (4097 points = 4096 spans, the kernel's own cap).
    private enum size_t maxPathPoints = 4097;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.strokeExtrude"; }
    override string label() const { return "Stroke Extrude"; }

    override Param[] params() {
        return [
            Param.vec3Array_("path",        "Path",          &path_),
            Param.bool_     ("alignToPath", "Align to Path",  &alignToPath_, true),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        if (path_.length < 2 || path_.length > maxPathPoints) return false;

        // Reference precondition: "select a polygon, and then click the
        // tool" — the tool/command does not pick one for you.
        bool[] mask = new bool[](mesh.faces.length);
        bool   any  = false;
        foreach (i, b; mesh.selectedFaces) if (b) { mask[i] = true; any = true; }
        if (!any) return false;

        // REDO: `CommandHistory.redo` re-runs `apply()` -> `evaluate`. Re-run
        // the kernel BATCHLESS — an unrecorded batch makes every tracker hook
        // take its `editRecorder_ is null` first line — and KEEP the first
        // delta rather than record a second one over it.
        if (recorded_) {
            size_t nRedo;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kRevolveEditScope);
                nRedo = ed.extrudeAlongPath(mask, path_, alignToPath_);
                ed.close();
            }
            return nRedo != 0;
        }

        // The selection image is taken BEFORE the kernel and only on the
        // recording run — `DenseSelectionUndo.capture` is idempotent by CALLER
        // contract, not by construction, and a second capture on the redo arm
        // would image the POST-op selection.
        preSel_.capture(*mesh);

        // TASK 1903 Stage E2 — the kernel takes `ref MeshEditBatch`, so the
        // batch opens HERE, at the command boundary, and never inside the
        // kernel (plan §4.1). This is the family's biggest single win:
        // `extrudeAlongPath` runs `extrudePathStep_` once per PATH SPAN and
        // each step ends in its own `commitChange`, so an N-span stroke used
        // to stamp, re-derive hidden geometry and deliver N times. It now does
        // all three ONCE, at `close()`.
        //
        // TASK 1903 STAGE L8-c — and it is RECORDING now. Stage K armed
        // `extrudePathStep_`'s `rewriteFaces` (the arm this stage's plan note
        // called "L8's blocking PREREQUISITE"), so the op-log is one
        // `[AddVerts, MeshMapDelta, FaceReindex]` GROUP PER SPAN — three of
        // them for a 3-span path — and the spans' `AddVerts` entries
        // deliberately no longer coalesce, because a `FaceReindex` now sits
        // between consecutive appends and `recordAddVert`'s contiguity test
        // only looks at the LAST entry.
        //
        // No `scope(failure)`: `MeshEditBatch.~this` pops the frame during
        // unwinding without asserting and ticks `changeBus.batchLeaks`, which
        // the suite asserts stays 0 (§2.2c).
        size_t added;
        {
            auto ed = MeshEditBatch(*mesh, kRevolveEditScope);   // RECORDING
            added = ed.extrudeAlongPath(mask, path_, alignToPath_);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove` /
        // `mesh.poly_inset` (stage L3-a, ruling Q-K6). `added == 0` is the
        // kernel's own refusal — a path shorter than two points, a path whose
        // spans all clamp away, or a selection with no extrudable face — and
        // it is this command's too. `added > 0` over an EMPTY delta is the
        // contradiction: `acceptRecordedEdit` REFUSES it and ticks
        // `changeBus.emptyDeltaOverMutation`, rather than recording a history
        // entry whose undo would do nothing. On this command that second arm
        // is UNREACHABLE on today's tree and the belt is deliberate: it is the
        // arm that would catch stage K's arming being removed, which before
        // that arming made `revert()` THROW out of `buildLoops` and leave the
        // mesh HALF-REVERTED (plan §5.5's L8 note has the measurement).
        if (!acceptRecordedEdit(added, delta_)) {
            delta_.revert(*mesh);
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        recorded_ = true;
        return true;
    }

    /// Observable through `/api/history`'s `opInverse` field: an entry that
    /// restores from an op-log must not report itself as a whole-mesh
    /// snapshot. `recorded_` rather than a literal `true` — an instance whose
    /// `evaluate` refused holds no inverse at all.
    override bool isOperationInverse() const { return recorded_; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kRevolveEditScope;
    }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log, for the KIND
        /// SEQUENCE assertions in `tests/unit/l8_extrude_delta_test.d`.
        /// A LENGTH is satisfied by a broken log: the per-span GROUPING is the
        /// property that matters here and only a kind SEQUENCE can see it.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override bool revert() {
        // An instance whose `evaluate` refused holds an empty delta and a
        // nulled selection image; replaying it would run `preSel_` over a mesh
        // it was never sized against. NOT the spelling for a command that DID
        // record: a `false` there pops the entry off BOTH history stacks and
        // truncates the suffix after it (regression 0099).
        if (!recorded_) return false;
        delta_.revert(*mesh);     // LIFO inverse replay restores the geometry
        preSel_.restore(*mesh);   // …then the three selection domains
        return true;
    }
}
