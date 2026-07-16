module commands.mesh.poly_inset;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

/// All-true selection mask of length `n`, used when nothing is selected
/// (empty selection ⇒ whole mesh). Mirrors the helper in edge_extrude.d.
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Polygon Inset (one-shot, undoable): for each selected face, move each
/// corner toward the polygon centroid by an absolute distance of `inset`
/// world units (see mesh.insetFacesByMask / insetCornerCentroid) and connect
/// the original boundary to the inset boundary with N ring quads.
/// Polygons-mode only; empty selection ⇒ whole mesh. `inset == 0` is NOT a
/// no-op (task 0359, reference-matched: the split always happens, landing a
/// degenerate zero-width ring at inset=0) — the only remaining no-op case is
/// an empty/undersized selection mask (evaluate returns false, snapshot
/// discarded).
///
/// Default is deliberately NON-zero (task 0359 review): the reference tool's
/// own default is bit-exact 0.0, but that value is a degenerate zero-area
/// ring (coincident-position boundary verts — a NaN Newell-normal hazard if
/// the result is later subdivided/lit without an intervening edit). The
/// scriptable one-shot command keeps a safe non-zero default so a bare
/// `mesh.poly_inset` invocation never manufactures degenerate geometry by
/// accident; the interactive PolyInsetTool (tools/poly_inset_tool.d) still
/// starts at the reference-matched 0.0 (its activate() does not build a
/// preview, so 0.0 is only ever a transient starting value, never silently
/// applied — see PolyInsetTool's class doc-comment).
class MeshPolygonInset : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            inset_ = 0.1f;   // safe non-zero default (task 0359 review)

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.poly_inset"; }
    override string label() const { return "Inset"; }

    override Param[] params() {
        return [
            Param.float_("inset", "Inset", &inset_, 0.1f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const all = mesh.nothingSelected(EditMode.Polygons);
        auto mask = all ? allTrue(mesh.faces.length) : mesh.selectedFaces;
        size_t n = mesh.insetFacesByMask(mask, inset_);
        if (n == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplayActive(mesh);
    }
}
