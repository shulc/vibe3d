// Transform history ownership witness (task 1905).
//
// This is deliberately a runtime state census. The bank population is derived
// from the live XfrmTransformTool object's TransformTool-typed fields, then
// every bank is asked whether history/factory capability reached it. Receiver
// spelling, loops, helpers, and neighboring mixins are therefore all observed
// through the state they produce instead of guessed from source text.
module tests.unit.transform_history_ownership_census_test;

import command_history : CommandHistory;
import commands.layer.xform_edit : LayerXformEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import document : Document;
import editor_app : EditorApp;
import editmode : EditMode;
import mesh : Mesh, GpuMesh, makeCube;
import pipe_gizmo_host : PipeGizmoHost;
import registration : buildRegisteredXfrmTransformForOwnershipTest;
import registry : Registry;
import seltype : SelTypeOrder;
import operator : VectorStack;
import std.conv : to;
import ai.exploration : AiExplorationController;
import ai.interaction_log_writer : AiInteractionLogWriter;
import tools.transform.xfrm_transform : XfrmTransformTool;

unittest // executes in the module-unittest gate, before any HTTP driver starts
{
    Mesh mesh = makeCube();
    GpuMesh gpu;
    EditMode mode = EditMode.Vertices;
    Document document;
    Registry registry;
    SelTypeOrder selTypeOrder;
    ref Mesh currentMesh() nothrow @nogc { return mesh; }

    EditorApp app;
    app.meshDg = cast(typeof(app.meshDg)) &currentMesh;
    app.gpuPtr = &gpu;
    app.editModePtr = &mode;
    app.documentPtr = &document;
    app.regPtr = &registry;
    app.selTypeOrderPtr = &selTypeOrder;
    app.history = new CommandHistory();
    app.vxEditFactory = () => cast(MeshVertexEdit) null;
    app.layerXformEditFactory = () => cast(LayerXformEdit) null;
    app.pipeGizmoHost = new PipeGizmoHost();
    app.aiExplore = new AiExplorationController(0, 42);
    app.aiLogWriter = new AiInteractionLogWriter("");

    auto tool = cast(XfrmTransformTool)
        buildRegisteredXfrmTransformForOwnershipTest(app);
    assert(tool !is null,
        "transform history ownership census: production factory returned "
        ~ "the wrong tool type");

    assert(tool.hasUndoBindings(),
        "transform history ownership census: production factory omitted "
        ~ "wrapper history binding");
    assert(tool.hasItemUndoFactory(),
        "transform history ownership census: production factory omitted "
        ~ "wrapper item-undo binding");
    assert(tool.hasPipeGizmoHost(),
        "transform history ownership census: production factory omitted "
        ~ "wrapper pipe-gizmo host");
    auto state = tool.embeddedHistoryBindingState();

    // NON-DEGENERACY FIRST: the three canonical bank identities must be
    // distinct, and every other live TransformTool-typed field (activeDrag)
    // must be an alias of one of them rather than a fourth bank.
    assert(state.canonicalIdentity,
        "transform history ownership census: embedded bank identity changed");
    assert(state.historyBound == 0,
        "transform history ownership census: embedded banks with history/undo "
        ~ "capability=" ~ state.historyBound.to!string);
    assert(state.pipeHostBound == 0,
        "transform history ownership census: embedded banks with pipe-gizmo "
        ~ "host=" ~ state.pipeHostBound.to!string);

    // Activation and the first update tick are both production wiring
    // boundaries. Re-query only after both have run.
    tool.activate();
    VectorStack vts;
    tool.update(vts);
    state = tool.embeddedHistoryBindingState();
    assert(state.canonicalIdentity,
        "transform history ownership census: activation/update changed "
        ~ "embedded bank identity");
    assert(state.historyBound == 0,
        "transform history ownership census: activation/update propagated "
        ~ "history into " ~ state.historyBound.to!string ~ " banks");
    assert(state.pipeHostBound == 0,
        "transform history ownership census: activation/update propagated "
        ~ "the pipe-gizmo host into " ~ state.pipeHostBound.to!string
        ~ " banks");
}
