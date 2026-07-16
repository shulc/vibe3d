module commands.mesh.bevel;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// One-shot Bevel command: dispatches by edit mode.
///   Polygons → bevelFacesByMask(mask, inset, shift, group, segments)
///              [params: inset, shift, group, segments]
///   Edges    → bevelEdgesByMask(mask, width, roundLevel)
///              [params: width, roundLevel]
/// Empty face-selection ⇒ whole mesh (allTrue mask, per sibling convention).
/// Empty edge-selection ⇒ allTrue mask.
/// |inset|<1e-6 && |shift|<1e-6 (polygon) or width<1e-6 (edge) → status:error.
///
/// Neutral param names (task 0391 — NEVER the reference-editor's own names
/// in source/tests/config — repo neutrality convention):
///   edge: `width` (== reference Value, inset-mode 1:1), `roundLevel`
///         (== reference Round Level `level` — TRUE circular arc).
///   poly: `inset`, `shift` (unchanged), `group` (== reference `group`,
///         default TRUE at this command layer — reference default;
///         `bevelFacesByMask`'s own kernel default stays `false` so the
///         pre-0391 per-face-independent unittests are unaffected),
///         `segments` (== reference `segs` — LINEAR staircase, a
///         DIFFERENT law from edge's Round Level arc).
class MeshBevel : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            inset_      = 0.1f;
    private float            shift_      = 0.0f;
    private bool             group_      = true;
    private int              segments_   = 0;
    private float            width_      = 0.1f;
    private int              roundLevel_ = 0;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.bevel"; }
    override string label() const { return "Bevel"; }

    override Param[] params() {
        if (editMode == EditMode.Edges)
            return [
                Param.float_("width", "Width", &width_, 0.1f),
                Param.int_("roundLevel", "Round Level", &roundLevel_, 0)
                    .min(0).max(MAX_ROUND_LEVEL).enforceBounds(),
            ];
        return [
            Param.float_("inset", "Inset", &inset_, 0.1f),
            Param.float_("shift", "Shift", &shift_, 0.0f),
            Param.bool_("group", "Group Polygons", &group_, true),
            Param.int_("segments", "Segments", &segments_, 0)
                .min(0).max(MAX_BEVEL_SEGMENTS).enforceBounds(),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t n = 0;

        if (editMode == EditMode.Polygons) {
            const all  = mesh.nothingSelected(EditMode.Polygons);
            auto  mask = all ? allTrue(mesh.faces.length) : mesh.selectedFaces;
            n = mesh.bevelFacesByMask(mask, inset_, shift_, group_, segments_);
        } else if (editMode == EditMode.Edges) {
            const all  = mesh.nothingSelected(EditMode.Edges);
            auto  mask = all ? allTrue(mesh.edges.length) : mesh.selectedEdges;
            n = mesh.bevelEdgesByMask(mask, width_, roundLevel_);
        }

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
