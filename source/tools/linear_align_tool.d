module tools.linear_align_tool;

import operator : VectorStack;

import tools.transform;
import tools.align_kernels : extractAlignChain, linearAlignTargets, lerp3;
import mesh;
import editmode;
import math : Vec3, Viewport;
import shader;
import params : Param;
import change_bus : MeshEditScope;

/// Linear Align tool (`xfrm.linearAlignTool`) — falloff-aware deform
/// tool, same structural family as Bend/Push (tools/bend.d, tools/push.d):
/// `params()` + `applyHeadless()` only, driven via
/// `tool.attr xfrm.linearAlignTool <attr> <v>; tool.doApply` from the
/// panel (Post-Mode auto-apply). No interactive gizmo drag — the
/// reference tool's own handle layout was never captured (task 0361
/// toolcard: "no handles.png/gizmo screenshot taken this round"), so this
/// mirrors Bend/Push's existing headless-attr-driven precedent rather
/// than inventing an undocumented drag gesture.
///
/// Algorithm (measured by live reference-editor capture, task 0361 — see
/// `tools/align_kernels.d`'s module doc comment for the full law):
/// extracts an ordered vertex CHAIN from the current selection via
/// edge-connectivity (falling back to click order), then interpolates
/// every interior vertex between the chain's two fixed endpoints —
/// either by its own line projection (`uniform=false`) or by equal
/// chain-index spacing (`uniform=true`). `weight` blends
/// `lerp(source, aligned, weight * falloff)`, matching the rest of the
/// deform-tool family's WGHT integration (Bend/Push).
class LinearAlignTool : TransformTool {
private:
    // Only `mode=line` is implemented — see align_kernels.linearAlignTargets's
    // doc comment for why `curve` ("tries to fit a curve to the selected
    // edges") isn't: it was never captured/measured, so this falls back
    // to the same line-interpolation rather than guessing a spline fit.
    string headlessMode    = "line";
    bool   headlessUniform = false;
    float  headlessWeight  = 1.0f;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        super(meshSrc, gpu, editMode);
    }

    override string name() const { return "Linear Align"; }

    override void activate() {
        super.activate();
        headlessMode    = "line";
        headlessUniform = false;
        headlessWeight  = 1.0f;
    }

    override Param[] params() {
        return [
            Param.enum_("mode", "Mode", &headlessMode,
                [["line", "Line"], ["curve", "Curve"]], "line"),
            Param.bool_("uniform", "Uniform", &headlessUniform, false),
            Param.float_("weight", "Weight", &headlessWeight, 1.0f)
                .min(0.0f).max(1.0f).enforceBounds(),
        ];
    }

    // No gizmo — see class doc comment. draw() only refreshes cachedVp so
    // the falloff overlay (rendered separately by app.d's per-viewport
    // loop) reads the correct projection.
    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts, bool visualOnly = false) {
        cachedVp = vp;
    }

    /// Headless apply — see class doc comment for the full law.
    override bool applyHeadless() {
        import toolpipe.packets : SubjectPacket;
        SubjectPacket subj;
        VectorStack vts;
        buildLocalVts(subj, vts);
        captureFalloffForDrag(vts);
        captureSymmetryForDrag(vts);

        auto chain = extractAlignChain(mesh, *editMode);
        if (chain.verts.length < 2) return false;

        Vec3[] source = new Vec3[](chain.verts.length);
        foreach (i, vi; chain.verts) source[i] = mesh.vertices[vi];

        // `mode=curve` isn't captured/implemented — see the field's doc
        // comment; both modes route through the same line-interpolation.
        auto aligned = linearAlignTargets(source, headlessUniform);

        if (toProcess.length != mesh.vertices.length)
            toProcess.length = mesh.vertices.length;
        toProcess[] = false;

        bool any = false;
        foreach (i, vi; chain.verts) {
            float w = headlessWeight * falloffWeight(cast(int)vi);
            if (w == 0.0f) continue;
            mesh.vertices[vi] = lerp3(source[i], aligned[i], w);
            toProcess[vi] = true;
            any = true;
        }
        if (!any) return false;

        applySymmetryToDrag();
        // ToolDoApplyCommand's snapshot/restore owns undo; this bumps
        // mutationVersion for the change-notification bus (subpatch
        // preview / snap grids / etc.) — matching the one-shot Command's
        // existing convention (commands/mesh/linear_align.d).
        mesh.commitChange(MeshEditScope.Position);
        return true;
    }
}
