module commands.mesh.linear_align;

import display_sync : refreshDisplayActive;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math : Vec3;
import params : Param;
import change_bus : MeshEditScope;
import tools.align_kernels : extractAlignChain, linearAlignTargets, lerp3;

/// Align a selected vertex CHAIN between its two fixed endpoints (task
/// 0361 — replaces the previous bbox-collapse-to-centroid-line algorithm,
/// which did not match the reference "Linear Align" tool at all). See
/// `tools/align_kernels.d`'s module doc comment for the full captured
/// law: the chain is extracted via edge-connectivity (falling back to
/// selection order), its two endpoints never move, and every interior
/// vertex lands on the line between them — either by its own spatial
/// projection (`uniform=false`) or by equal chain-index spacing
/// (`uniform=true`).
///
/// This one-shot Command has no falloff plumbing (that lives in the
/// interactive `xfrm.linearAlignTool`, tools/linear_align_tool.d, which
/// shares this same kernel) — `weight` here is a plain uniform blend.
class MeshLinearAlign : Command, Operator {
    mixin OperatorActrCommon;
    private uint[] touchedIdx;
    private Vec3[] touchedPrev;

    // `mode=curve` isn't captured/implemented — see
    // align_kernels.linearAlignTargets's doc comment; both modes route
    // through the same line-interpolation.
    private string mode_    = "line";
    private bool   uniform_ = false;
    private float  weight_  = 1.0f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.linear_align"; }
    override string label() const { return "Linear Align"; }

    override Param[] params() {
        return [
            Param.enum_("mode", "Mode", &mode_,
                [["line", "Line"], ["curve", "Curve"]], "line"),
            Param.bool_("uniform", "Uniform", &uniform_, false),
            Param.float_("weight", "Weight", &weight_, 1.0f)
                .min(0.0f).max(1.0f).enforceBounds(),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        auto chain = extractAlignChain(mesh, editMode);
        if (chain.verts.length < 2) return false;

        Vec3[] source = new Vec3[](chain.verts.length);
        foreach (i, vi; chain.verts) source[i] = mesh.vertices[vi];

        // `mode=curve` falls back to the same line-interpolation — see
        // this class's doc comment.
        auto aligned = linearAlignTargets(source, uniform_);

        touchedIdx.length  = 0;
        touchedPrev.length = 0;
        foreach (i, vi; chain.verts) {
            touchedIdx  ~= vi;
            touchedPrev ~= mesh.vertices[vi];
            mesh.vertices[vi] = lerp3(source[i], aligned[i], weight_);
        }

        mesh.commitChange(MeshEditScope.Position);
        refreshDisplayActive(mesh);
        return true;
    }

    override bool revert() {
        if (touchedIdx.length == 0) return false;
        foreach (i, vi; touchedIdx)
            if (vi < mesh.vertices.length) mesh.vertices[vi] = touchedPrev[i];
        mesh.commitChange(MeshEditScope.Position);
        refreshDisplayActive(mesh);
        return true;
    }
}
