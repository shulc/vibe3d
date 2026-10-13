module tools.transform.transform_source_cells;

import tools.transform.transform;
import toolpipe.guide : SnapQueryPolicy, SnapPurpose, SnapGuideScope;
import tool;
static import tools.transform.cluster_values;
import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedDeactivateEffect, PreparedDeactivateKind;
import mesh_gpu : GpuUploadOwner;
import command_history : PreparedHistoryKind;
import operator : VectorStack;
import mesh;
import mesh_gpu : GpuMesh;
import editmode;
import seltype : SelType;
import math : Vec3;
import spatial : Viewport, AimViewport, aimSpace;
import change_bus : MeshEditScope, changeBus;
import command : Command;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import commands.mesh.morph_edit  : MeshMorphEdit;
import snap : SnapResult, snapPacketOf;
import snap_render : publishLastSnap, clearLastSnap;
import toolpipe.packets : FalloffPacket, FalloffType, SymmetryPacket, SnapPacket, SubjectPacket;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.stages.snap : liveSnapGuides;
import toolpipe.stages.symmetry : SymmetryStage;
import falloff : evaluateFalloff;
import symmetry : applySymmetryMirror;
import pipe_gizmo_host : PipeGizmoHost;
import document : primaryModelSpace, Layer;

unittest {
    import record_observer_hub : RecordObserverHub;
    import command : Command, CmdFlags;
    import view : View;
    final class PreparedProbeCommand : Command {
        private Mesh owned;
        private View probeView = new View(0, 0, 1, 1);
        this() { super(&owned, probeView, EditMode.Vertices); }
        override string name() const { return "transform.prepared.probe"; }
        override string label() const { return "probe"; }
        override CmdFlags cmdFlags() const { return CmdFlags.Model; }
        protected override bool applyImpl() { return true; }
    }
    Mesh m = makeCube();
    GpuMesh gpu;
    gpu.faceVao = 11; gpu.faceVbo = 12; gpu.edgeVao = 13; gpu.edgeVbo = 14;
    gpu.vertVao = 15; gpu.vertVbo = 16; gpu.faceIdVbo = 17;
    gpu.matIdVbo = 18; gpu.weightColorVbo = 19;
    EditMode mode = EditMode.Vertices;
    auto tool = new TransformTool(() => &m, &gpu, &mode);

    auto idle = tool.prepareDeactivateGpu(null, null);
    assert(idle.resourceAccepted && gpu.uploadVersion == 0);

    tool.needsGpuUpdate = true;
    GpuMesh wrongGpu;
    auto wrongOwner = GpuUploadOwner.fakeForTest(&wrongGpu);
    auto wrongHistory = new CommandHistory();
    auto wrongHub = new RecordObserverHub(); wrongHub.setMacroActive(true);
    auto wrongContext = new PreparedRecordContext(wrongHistory, wrongHub);
    assert(wrongContext.prepare(new PreparedProbeCommand(),
                                PreparedHistoryKind.Plain).accepted);
    auto wrong = tool.prepareDeactivateGpu(wrongContext, wrongOwner);
    assert(!wrong.resourceAccepted && gpu.uploadVersion == 0);
    assert(!wrongContext.validate()); // terminal discard, not retryable
    size_t models, ui;
    wrongContext.installedDepths(models, ui);
    assert(models == 0 && ui == 0 && wrongHub.macroLength == 0);
    assert(wrongOwner.fakeCallsForTest().length == 0);

    gpu.suppressCageUpload = true;
    auto suppressOwner = GpuUploadOwner.fakeForTest(&gpu);
    auto suppressHistory = new CommandHistory();
    auto suppressHub = new RecordObserverHub(); suppressHub.setMacroActive(true);
    auto suppressContext = new PreparedRecordContext(suppressHistory, suppressHub);
    assert(suppressContext.prepare(new PreparedProbeCommand(),
                                   PreparedHistoryKind.Plain).accepted);
    auto suppressed = tool.prepareDeactivateGpu(suppressContext, suppressOwner);
    assert(!suppressed.resourceAccepted && gpu.uploadVersion == 0);
    assert(!suppressContext.validate());
    suppressContext.installedDepths(models, ui);
    assert(models == 0 && ui == 0 && suppressHub.macroLength == 0);
    assert(suppressOwner.fakeCallsForTest().length == 0);
    assert(gpu.faceVao == 11 && gpu.weightColorVbo == 19 &&
           gpu.faceVertCount == 0 && gpu.uploadVersion == 0);

    // The prepared suppression branch evolves only the detached Layer image,
    // then installs mesh before publishing its stable live subject.
    auto layer = new Layer();
    layer.meshRef() = makeCube();
    GpuMesh suppressedGpu;
    suppressedGpu.suppressCageUpload = true;
    auto suppressTool = new TransformTool(() => &layer.meshRef(),
                                          &suppressedGpu, &mode);
    suppressTool.needsGpuUpdate = true;
    auto preparedSuppressHistory = new CommandHistory();
    auto preparedSuppressHub = new RecordObserverHub();
    preparedSuppressHub.setMacroActive(true);
    auto preparedSuppressContext = new PreparedRecordContext(
        preparedSuppressHistory, preparedSuppressHub);
    assert(preparedSuppressContext.prepare(new PreparedProbeCommand(),
        PreparedHistoryKind.Plain).accepted);
    const liveVersion = layer.meshRef().mutationVersion;
    const deliveryCount = changeBus.deliveryCount;
    const subscriberCheckpoint = changeBus.meshSubscriberCheckpointForTest();
    scope (exit) changeBus.restoreMeshSubscribersForTest(subscriberCheckpoint);
    bool exactSubjectSeen;
    ulong deliveredVersion;
    size_t deliveredVertexCount;
    Vec3 deliveredFirstVertex;
    Mesh* deliveredMesh = &layer.meshRef();
    changeBus.onMeshChanged((size_t subject, uint) nothrow {
        if (subject != cast(size_t)deliveredMesh) return;
        exactSubjectSeen = true;
        deliveredVersion = deliveredMesh.mutationVersion;
        deliveredVertexCount = deliveredMesh.vertices.length;
        deliveredFirstVertex = deliveredMesh.vertices[0];
    });
    auto preparedSuppress = suppressTool.prepareDeactivateGpu(
        preparedSuppressContext, null, layer);
    assert(preparedSuppress.resourceAccepted);
    assert(layer.meshRef().mutationVersion == liveVersion);
    assert(changeBus.deliveryCount == deliveryCount);
    assert(preparedSuppressContext.validate());
    preparedSuppressContext.install();
    assert(layer.meshRef().mutationVersion == liveVersion + 1);
    assert(changeBus.deliveryCount == deliveryCount + 1);
    assert(changeBus.lastDeliverySubject == cast(size_t)&layer.meshRef());
    assert(changeBus.lastDeliveryFlags == MeshEditScope.Position);
    assert(changeBus.lastDeliverySelDomains == 0);
    assert(exactSubjectSeen && deliveredVersion == liveVersion + 1);
    assert(deliveredVertexCount == layer.meshRef().vertices.length);
    assert(deliveredFirstVertex == layer.meshRef().vertices[0]);
    assert(preparedSuppressContext.installTraceForTest() == [1,3,4]);
    preparedSuppressContext.installedDepths(models, ui);
    assert(models == 1 && ui == 0 && preparedSuppressHub.macroLength == 1);
    preparedSuppressContext.install();
    assert(layer.meshRef().mutationVersion == liveVersion + 1);
    assert(changeBus.deliveryCount == deliveryCount + 1);

    gpu.suppressCageUpload = false;
    auto owner = GpuUploadOwner.fakeForTest(&gpu);
    auto history = new CommandHistory();
    auto hub = new RecordObserverHub(); hub.setMacroActive(true);
    auto context = new PreparedRecordContext(history, hub);
    assert(context.prepare(new PreparedProbeCommand(),
                           PreparedHistoryKind.Plain).accepted);
    context.setResourceIdentity(7, 11);
    auto prepared = tool.prepareDeactivateGpu(context, owner);
    assert(prepared.resourceAccepted && gpu.uploadVersion == 0);
    assert(context.validate());
    context.install();
    assert(gpu.uploadVersion == 1);
    assert(gpu.faceVao == 11 && gpu.weightColorVbo == 19);
    assert(context.installTraceForTest() == [1,2]);
    assert(owner.fakeCallsForTest() == [1,2,3,4,5,6,7]);
    context.installedDepths(models, ui);
    assert(models == 1 && ui == 0 && hub.macroLength == 1);
    context.install();
    assert(gpu.uploadVersion == 1);
}
