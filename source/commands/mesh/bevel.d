module commands.mesh.bevel;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;
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
class MeshBevel : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
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

        snap = MeshSnapshot.capture(*mesh);
        size_t n = 0;

        if (editMode == EditMode.Polygons) {
            auto mask = mesh.operandFaceMask();
            n = mesh.bevelFacesByMask(mask, inset_, shift_, group_, segments_, square_);
        } else if (editMode == EditMode.Edges) {
            auto mask = mesh.operandEdgeMask();
            n = mesh.bevelEdgesByMask(mask, width_, roundLevel_, widthMode_);
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

        if (n == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
