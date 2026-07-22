module commands.mesh.subpatch_toggle;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import change_bus : MeshEditScope;

/// Mirror of the Tab-key handler in app.d: toggles isSubpatch on selected
/// faces; if nothing is selected, inverts the flag on every face. Exposed as
/// a Command so it can be invoked through /api/command in tests and through
/// future UI buttons without duplicating the logic.
class SubpatchToggle : Command, Operator {
    mixin OperatorActrCommon;
    private bool[] origSubpatch;     // pre-apply isSubpatch[] snapshot
    private bool   captured;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "mesh.subpatch_toggle"; }

    // No supportedModes() override → inherits the default (all geometry
    // modes). Subpatch conversion is meaningful in every edit mode: the
    // face selection is only HONORED in Polygons mode; in edge/vertex mode
    // the toggle applies to the whole model (see evaluate()), so the UI
    // button must not grey out there.

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // Snapshot just isSubpatch[] — only field we mutate.
        origSubpatch = mesh.isSubpatch.dup;
        captured     = true;

        mesh.syncSelection();
        // MODE-AWARE scope (parity): the persisted face selection is honored
        // ONLY while the current selection type is Polygons. In edge/vertex
        // mode a stale face selection is ignored and the toggle applies to
        // the WHOLE model (matches the reference editor, which drops the
        // polygon selection's authority outside polygon mode). Whole-model
        // also when nothing is face-selected in polygon mode. `editMode` is
        // the geometry-type view captured at fire time, so it is Edges /
        // Vertices in those modes and the guard falls through to whole-model.
        bool scoped = editMode == EditMode.Polygons
                      && mesh.hasAnySelectedFaces();
        // Materialize the views once (each access allocates).
        auto selView = mesh.selectedFaces;
        auto subView = mesh.isSubpatch;
        foreach (fi; 0 .. mesh.faces.length) {
            if (scoped && !(fi < selView.length && selView[fi]))
                continue;
            bool cur = fi < subView.length && subView[fi];
            mesh.setSubpatch(fi, !cur);
        }
        return true;
    }

    override bool revert() {
        if (!captured) return false;
        mesh.setFaceSubpatchFrom(origSubpatch);
        // Marks-class flip (subpatch bit). isSubpatch[] drives subpatch preview
        // OUTPUT topology, so we keep the topologyVersion bump explicitly
        // (commitChange(Marks) alone bumps only mutationVersion). Counters end
        // identical to the prior two raw lines.
        mesh.commitChange(MeshEditScope.Marks);
        ++mesh.topologyVersion;
        return true;
    }
}
