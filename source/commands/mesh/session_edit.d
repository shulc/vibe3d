module commands.mesh.session_edit;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditScope;

/// Generic record-flavor command for an interactive mesh-editing session
/// (see e.g. BevelTool, EdgeExtrudeTool, ArrayTool, LoopSliceTool, ...). The
/// tool captures a full MeshSnapshot at the moment its topology/geometry is
/// first built, mutates the mesh freely while the user drags the gizmo and
/// tweaks Tool Properties (intermediate revert+reapply cycles within the
/// tool itself), and on deactivation records this command holding (before,
/// after) snapshots so the entire gesture is a single undo step.
///
/// apply() = restore `after`; revert() = restore `before`. A
/// topology-creating tool cannot use the vertex-position-delta
/// MeshVertexEdit undo, so it records a full before/after snapshot pair —
/// one undo step per session.
///
/// This is the single generic class behind what used to be twelve
/// hand-cloned per-tool subclasses (MeshArrayEdit, MeshBevelEdit,
/// MeshCloneEdit, MeshEdgeExtendEdit, MeshEdgeExtrudeEdit,
/// MeshFaceExtrudeEdit, MeshLoopSliceEdit, MeshRadialArrayEdit,
/// MeshReduceEdit, MeshSmoothShiftEdit, MeshStrokeExtrudeEdit) that
/// differed only in their wire name, default label, change-scope bits, and
/// whether an operation-log MeshEditDelta was wired (task 0408, campaign
/// 0407 §A.D1). Each caller supplies its own `(wireName, defaultLabel,
/// editScope)` at construction. `name()` returns `wireName` verbatim —
/// undo history, event-log replay, and macros dispatch on it, so callers
/// MUST pass the exact string the old per-class `name()` used to return
/// (e.g. "mesh.bevel_edit", "mesh.array_edit"; see each factory site in
/// app.d for the frozen list, including the irregular
/// "mesh.strokeExtrude_edit").
///
/// `MeshSelectionEdit` (selection state, not mesh geometry — a different
/// snapshot type, no gpu/caches, its own compareOp/mergeFrom coalescing and
/// promote-hook) and `MeshVertexEdit` (per-vertex position delta, its own
/// coalescing/merge/run-consolidation machinery) are NOT instances of this
/// shape and intentionally stay as their own classes.
class MeshSessionEdit : Command, Operator {
    mixin OperatorActrCommon;

    private MeshSnapshot before;
    private MeshSnapshot after;
    private string editLabel;

    private string       wireName_;
    private string       defaultLabel_;
    private MeshEditScope editScope_;

    // Optional operation-log delta (doc/undo_change_tracker_plan.md Phase 2).
    // When `useDelta_` is set (via setDelta), apply()/revert() replay the
    // delta (O(delta)) instead of restoring the whole-mesh snapshot pair.
    // The snapshot path stays intact as the fallback (VIBE3D_UNDO_TRACKER=off
    // / degenerate delta / callers — the majority — that never call setDelta
    // at all).
    private MeshEditDelta delta_;
    private bool          useDelta_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         string wireName, string defaultLabel,
         MeshEditScope editScope = MeshEditScope.None) {
        super(mesh, view, editMode);
        this.wireName_     = wireName;
        this.defaultLabel_ = defaultLabel;
        this.editScope_    = editScope;
    }

    override string name()  const { return wireName_; }
    override string label() const {
        return editLabel.length ? editLabel : defaultLabel_;
    }

    // Change-scope metadata (Phase 4 §b). Callers that append/reshape
    // geometry pass MeshEditScope.Geometry | MeshEditScope.Marks; plain
    // callers leave the ctor default (None), matching every pre-merge
    // class that never overrode editScope().
    override MeshEditScope editScope() const { return editScope_; }
    // True iff this instance is delta-backed (setDelta was called). The
    // snapshot path (setSnapshots / the escape hatch) reports false honestly.
    override bool isOperationInverse() const { return useDelta_; }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "") {
        this.before    = before_;
        this.after     = after_;
        this.editLabel = label_;
        this.useDelta_ = false;
    }

    // Install an operation-log delta. The tool builds this by re-running its
    // kernel once inside a Mesh edit batch. `before` is still kept so a
    // degenerate (empty) delta could fall back to the snapshot path, but
    // with a real delta the snapshot pair is never touched at apply/revert.
    void setDelta(MeshEditDelta delta_, string label_ = "") {
        this.delta_    = delta_;
        this.useDelta_ = true;
        this.editLabel = label_;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (useDelta_) delta_.apply(*mesh);   // forward replay (redo)
        else           after.restore(*mesh);
        return true;
    }

    override bool revert() {
        if (useDelta_) delta_.revert(*mesh);  // LIFO inverse replay (undo)
        else           before.restore(*mesh);
        return true;
    }
}

// ---------------------------------------------------------------------------
// wireName / label / editScope round-trip — no snapshots involved (evaluate()
// / revert() need a real GL-backed GpuMesh to be meaningful and are exercised
// by the HTTP suite instead; this unit test only pins the per-caller metadata
// contract the ctor establishes).
// ---------------------------------------------------------------------------
unittest {
    import mesh      : Mesh;
    import view       : View;
    import editmode   : EditMode;

    Mesh mesh;
    View view = new View(0, 0, 1, 1);

    // Plain form (editScope omitted): matches array/bevel/clone/loop_slice/
    // reduce/smooth_shift — no override before the merge, so the base
    // Command.editScope() default (None) must still come through.
    auto plain = new MeshSessionEdit(&mesh, view, EditMode.Vertices,
                                      "mesh.bevel_edit", "Bevel");
    assert(plain.name()  == "mesh.bevel_edit");
    assert(plain.label() == "Bevel", "label falls back to defaultLabel before setSnapshots");
    assert(plain.editScope() == MeshEditScope.None);
    assert(plain.isOperationInverse() == false);

    // setSnapshots's own label argument overrides the ctor default, exactly
    // as the per-class `setSnapshots(before_, after_, string label_ = "X")`
    // did — every real caller passes an explicit label (grep confirms none
    // rely on the old per-class default), so only the override path matters.
    MeshSnapshot dummy;
    plain.setSnapshots(dummy, dummy, "Custom Label");
    assert(plain.label() == "Custom Label");

    // Union form (editScope supplied): matches edge_extrude/edge_extend/
    // face_extrude/radial_array/stroke_extrude.
    auto scoped = new MeshSessionEdit(&mesh, view, EditMode.Vertices,
                                       "mesh.edge_extrude_edit", "Edge Extrude",
                                       MeshEditScope.Geometry | MeshEditScope.Marks);
    assert(scoped.name()      == "mesh.edge_extrude_edit");
    assert(scoped.label()     == "Edge Extrude");
    assert(scoped.editScope() == (MeshEditScope.Geometry | MeshEditScope.Marks));
    assert(scoped.isOperationInverse() == false, "false until setDelta is called");

    // setDelta flips isOperationInverse() and (like setSnapshots) installs
    // its own label — mirrors edge_extrude_edit.d's original setDelta().
    MeshEditDelta delta;
    scoped.setDelta(delta, "Edge Extrude (delta)");
    assert(scoped.isOperationInverse() == true);
    assert(scoped.label() == "Edge Extrude (delta)");

    // The irregular stroke_extrude wire name is a real (if inconsistent)
    // pre-existing quirk — camelCase "strokeExtrude" instead of the
    // snake_case every sibling uses. Preserved byte-for-byte, not
    // normalized, since undo history / replay dispatch on it.
    auto stroke = new MeshSessionEdit(&mesh, view, EditMode.Vertices,
                                       "mesh.strokeExtrude_edit", "Stroke Extrude",
                                       MeshEditScope.Geometry | MeshEditScope.Marks);
    assert(stroke.name() == "mesh.strokeExtrude_edit");
}
