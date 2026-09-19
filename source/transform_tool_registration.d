module transform_tool_registration;

import command_history : CommandHistory;
import commands.layer.xform_edit : LayerXformEdit;
import commands.mesh.morph_edit : MeshMorphEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import document : Layer;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import mesh_gpu : GpuMesh;
import pipe_gizmo_host : PipeGizmoHost;
import registry : Registry, typedToolFactory;
import tools.alignment.linear_align_tool : LinearAlignTool;
import tools.alignment.radial_align_tool : RadialAlignTool;
import tools.common.command_wrapper : XfrmJitterTool, XfrmQuantizeTool,
    XfrmSmoothTool;
import tools.deform.bend : BendTool;
import tools.deform.push : PushTool;
import tools.slice.edge_slide : EdgeSlideTool;
import tools.transform.xfrm_transform : XfrmTransformTool;

/// Narrow collaborators owned by transform-family registration. Task 6506;
/// the exact roster and access paths are pinned by the boundary census.
struct TransformToolDeps {
private:
    GpuMesh* gpu_;
    CommandHistory history_;
    MeshVertexEdit delegate() vertexEditFactory_;
    MeshMorphEdit delegate() morphEditFactory_;
    LayerXformEdit delegate() itemEditFactory_;
    PipeGizmoHost pipeGizmoHost_;
    bool delegate() exploreSilentHover_;

public:
    @disable this();

    this(GpuMesh* gpu, CommandHistory history,
            MeshVertexEdit delegate() vertexEditFactory,
            MeshMorphEdit delegate() morphEditFactory,
            LayerXformEdit delegate() itemEditFactory,
            PipeGizmoHost pipeGizmoHost,
            bool delegate() exploreSilentHover) {
        assert(gpu !is null, "transform registration requires a GPU mesh");
        assert(history !is null, "transform registration requires command history");
        assert(vertexEditFactory !is null,
            "transform registration requires a vertex-edit factory");
        assert(morphEditFactory !is null,
            "transform registration requires a morph-edit factory");
        assert(itemEditFactory !is null,
            "transform registration requires an item-edit factory");
        assert(pipeGizmoHost !is null,
            "transform registration requires a pipe-gizmo host");
        assert(exploreSilentHover !is null,
            "transform registration requires a silent-hover policy");
        gpu_ = gpu;
        history_ = history;
        vertexEditFactory_ = vertexEditFactory;
        morphEditFactory_ = morphEditFactory;
        itemEditFactory_ = itemEditFactory;
        pipeGizmoHost_ = pipeGizmoHost;
        exploreSilentHover_ = exploreSilentHover;
    }

    GpuMesh* gpu() nothrow @nogc { return gpu_; }
    CommandHistory history() nothrow @nogc { return history_; }
    MeshVertexEdit delegate() vertexEditFactory() nothrow @nogc {
        return vertexEditFactory_;
    }
    MeshMorphEdit delegate() morphEditFactory() nothrow @nogc {
        return morphEditFactory_;
    }
    LayerXformEdit delegate() itemEditFactory() nothrow @nogc {
        return itemEditFactory_;
    }
    PipeGizmoHost pipeGizmoHost() nothrow @nogc { return pipeGizmoHost_; }
    bool delegate() exploreSilentHover() nothrow @nogc {
        return exploreSilentHover_;
    }
}

/// The four unified-transform ids share this construction recipe; each row
/// supplies only T/R/S and the handle family/presentation. Task 6351.
private struct TransformFactoryDefaults {
    bool flagT, flagR, flagS;
    int handleFamily;
    string handlePresentation;

    enum move      = TransformFactoryDefaults(true,  false, false, 0, "full");
    enum rotate    = TransformFactoryDefaults(false, true,  false, 1, "full");
    enum scale     = TransformFactoryDefaults(false, false, true,  2, "full");
    // Equal to the XfrmTransformTool constructor defaults by contract, not by
    // omission: presets on this base that set no handle fields inherit it.
    enum transform = TransformFactoryDefaults(true,  true,  true,  0, "compact");
}

private XfrmTransformTool buildUnifiedTransform(LiveSessionRole owner,
        LiveViewModeRole live, TransformToolDeps deps,
        TransformFactoryDefaults defaults) {
    auto t = new XfrmTransformTool(() => &owner.activeMesh(), deps.gpu(),
        live.modeCell(), () => owner.subjectType(),
        // The moving target-narrowed set, not only the primary layer.
        (ref Layer[] buf) => owner.document().itemTransformTargets(buf));
    t.flagT = defaults.flagT;
    t.flagR = defaults.flagR;
    t.flagS = defaults.flagS;
    t.handleFamily = defaults.handleFamily;
    t.handlePresentation = defaults.handlePresentation;
    t.setUndoBindings(deps.history(), deps.vertexEditFactory(),
        deps.morphEditFactory());
    t.setItemUndoFactory(deps.itemEditFactory());
    t.setPipeGizmoHost(deps.pipeGizmoHost());
    if (deps.exploreSilentHover()())
        t.setAiExploreSilentHover(true);
    return t;
}

/// Register the transform/deform/convolve factory family through live roles.
/// Convolve products intentionally retain their gesture-specific bindings.
void registerTransformToolCommands(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, TransformToolDeps deps) {
    reg.registerTool("move", typedToolFactory!XfrmTransformTool(
        () => buildUnifiedTransform(owner, live, deps, TransformFactoryDefaults.move)));
    reg.registerTool("rotate", typedToolFactory!XfrmTransformTool(
        () => buildUnifiedTransform(owner, live, deps, TransformFactoryDefaults.rotate)));
    reg.registerTool("scale", typedToolFactory!XfrmTransformTool(
        () => buildUnifiedTransform(owner, live, deps, TransformFactoryDefaults.scale)));
    reg.registerTool("xfrm.transform", typedToolFactory!XfrmTransformTool(
        () => buildUnifiedTransform(owner, live, deps, TransformFactoryDefaults.transform)));
    reg.registerTool("xfrm.push", typedToolFactory!PushTool(() {
        auto t = new PushTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell());
        t.setUndoBindings(deps.history(), deps.vertexEditFactory());
        return t;
    }));
    reg.registerTool("xfrm.bend", typedToolFactory!BendTool(() {
        auto t = new BendTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell());
        t.setUndoBindings(deps.history(), deps.vertexEditFactory());
        return t;
    }));
    // Align deform tools are headless-attribute driven; they have no gizmo
    // drag and intentionally receive no morph-edit factory.
    reg.registerTool("xfrm.linearAlignTool", typedToolFactory!LinearAlignTool(() {
        auto t = new LinearAlignTool(
            () => &owner.activeMesh(), deps.gpu(), live.modeCell());
        t.setUndoBindings(deps.history(), deps.vertexEditFactory());
        return t;
    }));
    reg.registerTool("xfrm.radialAlignTool", typedToolFactory!RadialAlignTool(() {
        auto t = new RadialAlignTool(
            () => &owner.activeMesh(), deps.gpu(), live.modeCell());
        t.setUndoBindings(deps.history(), deps.vertexEditFactory());
        return t;
    }));
    // These remain command-wrapper tools with gesture bindings, not members of
    // the paired headless-tool recipe.
    reg.registerTool("xfrm.smooth", typedToolFactory!XfrmSmoothTool(() {
        auto t = new XfrmSmoothTool(
            &owner.activeMesh(), live.view(), live.mode(), deps.gpu());
        t.setGestureBindings(deps.history(), deps.vertexEditFactory());
        t.setPipeGizmoHost(deps.pipeGizmoHost());
        return t;
    }));
    reg.registerTool("xfrm.jitter", typedToolFactory!XfrmJitterTool(() {
        auto t = new XfrmJitterTool(
            &owner.activeMesh(), live.view(), live.mode(), deps.gpu());
        t.setGestureBindings(deps.history(), deps.vertexEditFactory());
        t.setPipeGizmoHost(deps.pipeGizmoHost());
        return t;
    }));
    reg.registerTool("edge.slide", typedToolFactory!EdgeSlideTool(() {
        auto t = new EdgeSlideTool(
            &owner.activeMesh(), live.view(), live.mode(), deps.gpu());
        t.setGestureBindings(deps.history(), deps.vertexEditFactory());
        t.setPipeGizmoHost(deps.pipeGizmoHost());
        return t;
    }));
    reg.registerTool("xfrm.quantize", typedToolFactory!XfrmQuantizeTool(() {
        auto t = new XfrmQuantizeTool(
            &owner.activeMesh(), live.view(), live.mode(), deps.gpu());
        t.setGestureBindings(deps.history(), deps.vertexEditFactory());
        t.setPipeGizmoHost(deps.pipeGizmoHost());
        return t;
    }));
}
