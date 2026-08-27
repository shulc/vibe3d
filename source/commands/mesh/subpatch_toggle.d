module commands.mesh.subpatch_toggle;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import seltype : SelType;
import change_bus : MeshEditScope;

/// Mirror of the Tab-key handler in app.d: toggles isSubpatch on selected
/// faces; if nothing is selected, inverts the flag on every face. Exposed as
/// a Command so it can be invoked through /api/command in tests and through
/// future UI buttons without duplicating the logic.
/// PERMANENTLY DENSE — task 1903 Stage L0, owner's ruling of 2026-08-27.
///
/// THE DECISION. `origSubpatch` stays a whole-array `dup` of `isSubpatch[]`
/// for good, and `revert()` keeps patching the Subpatch bit index by index.
/// L0's content for this file is AXIS 0 ONLY — the commit seam, i.e. the
/// `commitChange` site and the bare `++topologyVersion` in `revert()` moving
/// into a batch. Axis 1 is vacuous (there is no `mesh_ops` kernel: the loop
/// calls `Mesh.setSubpatch` directly, a plain member and never a mixin), and
/// axis 2 — the undo migration — is what this ruling declines.
///
/// THE QUESTION IT ANSWERS. "Does L0 give `MeshOpEntry.Kind.SubpatchDelta`
/// its first production publisher?" No. The kind stays DORMANT after L0, and
/// says so at its own declaration in `source/mesh_edit_delta.d`.
///
/// THE REASON. It would be the same delta spelled twice, for a strictly worse
/// undo. This command already keeps a per-index bit capture and already writes
/// back exactly the indices it captured — it has been off the `MeshSnapshot`
/// path since task 0613. A `SubpatchDelta` log would carry the identical
/// (index, before, after) triple through a second encoding, a second dispatch
/// branch and a replay, and would restore the same bits at the same indices.
/// Nothing about what undo gives back changes; the only deltas are an extra
/// representation to keep correct and a kind that acquires its first caller
/// for no behavioural reason. The dense capture is ~1 byte per face
/// (`bool[]`), ~100 KB on a 100 000-face mesh, and it is transient.
///
/// The index-stability premise the sparse patch rests on is stated where it is
/// used, in `revert()` below: a toggle changes no topology, so nothing
/// compacts between capture and revert and index i still names face i. That
/// premise is the same one a `SubpatchDelta` replay would need, so migrating
/// would not buy safety there either.
///
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
        // TYPE-AWARE scope (parity): the persisted face selection is honored
        // ONLY while the CURRENT selection type is Polygon. In edge/vertex
        // mode a stale face selection is ignored and the toggle applies to
        // the WHOLE model (matches the reference editor, which drops the
        // polygon selection's authority outside polygon mode). Whole-model
        // also when nothing is face-selected in polygon mode.
        //
        // Task 0621: this asks `subj.selType` — the CURRENT type — and no
        // longer `editMode`. The two differ in exactly one state and it is a
        // reachable one: under `SelType.Item` the derived `editMode` RETAINS
        // the pre-switch geometry type, so with an item selected after a
        // polygon selection the old `editMode == Polygons` read scoped the
        // toggle to faces the user could no longer see selected. Reading the
        // current type makes this line agree with app.d's Tab handler, which
        // has always asked `currentSelType(selTypeOrder) == SelType.Polygon`
        // — the two spellings of the same toggle now answer identically in
        // every mode, item included.
        bool scoped = subj.selType == SelType.Polygon
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
        // Restore ONLY the Subpatch bit at each index — no compaction ran
        // between capture and revert (a toggle changes no topology), so index
        // i still names the same face. Merge the captured Subpatch value onto
        // the CURRENT word at that index (task 0613 §4.2 — setFaceSubpatchFrom
        // used to do exactly this internally) by mutating `mesh.faceMarks`
        // directly (code review NIT: the old call reused the captured array
        // with no intermediate allocation; going through setFaceMarksFrom
        // would need a full replacement-word array built just to throw away,
        // undo path only but still cheap to avoid) — Select and Hide,
        // whatever they are right now, ride through untouched.
        foreach (i, wasSubpatch; origSubpatch) {
            if (i >= mesh.faceMarks.length) continue;
            if (wasSubpatch) mesh.faceMarks[i] |= Mesh.Marks.Subpatch;
            else             mesh.faceMarks[i] &= ~Mesh.Marks.Subpatch;
        }
        // Marks-class flip (subpatch bit). isSubpatch[] drives subpatch preview
        // OUTPUT topology, so we keep the topologyVersion bump explicitly
        // (commitChange(Marks) alone bumps only mutationVersion). Counters end
        // identical to the prior two raw lines.
        mesh.commitChange(MeshEditScope.Marks);
        ++mesh.topologyVersion;
        return true;
    }
}
