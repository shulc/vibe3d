module tools.create.pen;
import display_state : DrawPlan;

import bindbc.opengl;
import operator : VectorStack;
import bindbc.sdl;

import tool;
import mesh;
import mesh_gpu : GpuMesh;
import math;
import params : Param;
import handler : BoxHandler, gizmoSize, ToolHandles;
import viewport_scheme : schemeColor, SchemeColor;
import eventlog : queryMouse;
import shader : Shader, LitShader, previewFacePass;
import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot : MeshSnapshot;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import prepared_record_context : PreparedToolParamDoorClient,
    PreparedPenParamDoorClient;
import prepared_private_state : PreparedPrivateStateOwner;
import prepared_tool_effect : PreparedSessionActivateEffect, PreparedActivateKind,
    PreparedDeactivateEffect, PreparedDeactivateKind, PreparedPenParamEffect,
    PreparedPenParamKind;
import mesh_gpu : GpuCreateOwner, GpuUploadOwner, GpuResourceOwner;
import command_history : PreparedHistoryKind;
import document : Layer;
import handler : BoxHandlerBatchResourceOwner;
import snap_render : SnapOverlayOwner;
import mesh : beginPreparedShadow, drainPreparedShadowDelivery;
import display_sync : refreshDisplay;
import tools.create.create_common : pickWorkplane, BuildPlane,
                              primitivePlacementFrame, WorkplaneFrame,
                              mostFacingAxis,
                              transformPoint, transformDir, snapLocalHit,
                              currentSnapPacket,
                              workplaneCursorRay, workplaneCursorPlaneHit;
import toolpipe.packets : SnapType, SnapPacket, SymmetryPacket;
import toolpipe.stages.symmetry : liveSymmetryStage;
import symmetry : mirrorPosition, symmetryMirrorsEqual, symmetryPacketsEqual;
import editmode : EditMode;
import seltype : SelType;
import snap : SnapResult, snapCursor, cascadeClassWins, kAbsentClassDist,
    kCascadeVertex, kCascadeEdge, kCandidateToleranceBasePx, kVertexToleranceScale;
import document : primaryModelSpace;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;
import tools.transform.relocate_plane : vectorSnap, withAxisComp, axisComp, niceOrigin;
import viewgrid : g_viewGrid, viewWorldPerPixel, viewGridSize, viewGridSubStep,
    relocateQuantum;

import std.math : abs, fmin, lround;
// The one stroke builder and the pen's param schema (PenParams, PenStroke).
import tools.create.pen_geometry;
import tools.common.session_mesh_key : SessionMeshKey;
import core.stdc.string : memcmp;

private bool sameValueBytes(T)(ref const T a, ref const T b) nothrow @nogc {
    return memcmp(&a, &b, T.sizeof) == 0;
}
private bool sameSliceBytes(T)(const(T)[] a, const(T)[] b) nothrow @nogc {
    return a.length == b.length && (a.length == 0 ||
        memcmp(a.ptr, b.ptr, a.length * T.sizeof) == 0);
}

// Snap-type bits that PenTool handles via applyPenGuide (Pen-local guide
// constraints). These bits are excluded from snapLocalHit at all Pen call
// sites so the shared snap pipeline never applies the transform-scoped
// WorldAxis-through-origin on top of the Pen-scoped prior-vertex variants.
private enum uint guideBits =
    SnapType.WorldAxis | SnapType.StraightLine | SnapType.RightAngle;

// Merge after an ELEMENT snap (wave plan S5 A3, fixture pen_merge.json
// `cells_k_b3`): screen radii, bracket midpoints — the snapped edge's own ends
// link within (15.4, 19.5] px, any other vertex within (2.2, 3.5] px. Any
// other placement merges within `SnapPacket.init.innerRangePx` (24 px).
private enum float kMergeSnappedEdgeEndPx = 17.5f;
private enum float kMergeAfterSnapPx = 2.85f;
private enum uint kElementSnapBits = SnapType.Vertex | SnapType.Edge |
    SnapType.EdgeCenter | SnapType.Polygon | SnapType.PolyCenter;

version(unittest) unittest {
    import record_observer_hub : RecordObserverHub;
    import std.format : format;
    import view : View;

    Mesh mesh; GpuMesh sceneGpu;
    auto pen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    pen.state = PenState.Drawing; pen.vertices_ = [Vec3(1,2,3), Vec3(4,5,6)];
    pen.params_.currentPoint = 1;
    pen.params_.posX = 4; pen.params_.posY = 5; pen.params_.posZ = 6;
    pen.dragArmed = pen.dragInitiated = true; pen.dragVertIdx = 1;
    pen.previewGpu.faceVao = 51; pen.previewGpu.faceVbo = 52;
    auto gpuOwner = GpuCreateOwner.fakeForLegacyInitTest(pen.preparedPreviewGpu());
    auto context = new PreparedRecordContext(null, new RecordObserverHub());
    context.setResourceIdentity(7, 11);
    auto effect = pen.prepareActivate(context, gpuOwner);
    assert(effect.accepted && effect.kind == PreparedActivateKind.Pen &&
        effect.owner == pen.preparedOwnerForTest() &&
        pen.state == PenState.Drawing && pen.vertices_.length == 2 &&
        pen.previewGpu.faceVao == 51);
    assert(context.validate()); context.install(); context.install();
    assert(pen.state == PenState.Idle && pen.vertices_.length == 0 &&
        pen.params_.currentPoint == -1 && pen.params_.posX == 0 &&
        pen.params_.posY == 0 && pen.params_.posZ == 0 &&
        !pen.dragArmed && !pen.dragInitiated && pen.dragVertIdx == -1 &&
        pen.previewGpu.faceVao != 0 && pen.previewGpu.faceVao != 51 &&
        context.installTraceForTest() == [7, 5, 8]);

    auto nullContext = new PreparedRecordContext(null, new RecordObserverHub());
    auto nullEffect = pen.prepareActivate(nullContext, null);
    assert(!nullEffect.accepted && nullEffect.kind == PreparedActivateKind.Pen &&
        nullEffect.owner == pen.preparedOwnerForTest() && !nullContext.validate());

    auto fault = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    fault.state = PenState.Drawing; fault.vertices_ = [Vec3(9,8,7)];
    fault.dragArmed = true; fault.previewGpu.faceVao = 61;
    auto faultOwner = GpuCreateOwner.fakeForLegacyInitTest(fault.preparedPreviewGpu());
    auto faultContext = new PreparedRecordContext(null, new RecordObserverHub());
    faultContext.setResourceIdentity(99, 100);
    assert(fault.prepareActivate(faultContext, faultOwner).accepted &&
        !faultContext.validate() && faultOwner.fakeCleanupCountForTest() == 1 &&
        fault.state == PenState.Drawing && fault.vertices_.length == 1 &&
        fault.dragArmed && fault.previewGpu.faceVao == 61);
    auto retryOwner = GpuCreateOwner.fakeForLegacyInitTest(fault.preparedPreviewGpu());
    auto retry = new PreparedRecordContext(null, new RecordObserverHub());
    retry.setResourceIdentity(7, 11);
    assert(fault.prepareActivate(retry, retryOwner).accepted && retry.validate());
    retry.install();
    assert(retry.installTraceForTest() == [7, 5, 8] &&
        fault.state == PenState.Idle && fault.previewGpu.faceVao != 61);

    class DerivedPen : PenTool {
        this(Mesh* delegate() source, GpuMesh* gpu, LitShader shader) {
            super(source, gpu, shader);
        }
    }
    auto derived = new DerivedPen(() => &mesh, &sceneGpu, LitShader.init);
    auto derivedOwner = GpuCreateOwner.fakeForLegacyInitTest(
        derived.preparedPreviewGpu());
    auto derivedContext = new PreparedRecordContext(null, new RecordObserverHub());
    derivedContext.setResourceIdentity(7, 11);
    auto derivedEffect = derived.prepareActivate(derivedContext, derivedOwner);
    assert(!derivedEffect.accepted && derivedEffect.kind == PreparedActivateKind.Pen &&
        derivedEffect.owner == derived.preparedOwnerForTest() &&
        !derivedContext.validate());

    GpuMesh foreignGpu;
    auto foreignOwner = GpuCreateOwner.fakeForLegacyInitTest(&foreignGpu);
    auto foreignContext = new PreparedRecordContext(null, new RecordObserverHub());
    foreignContext.setResourceIdentity(7, 11);
    auto foreignEffect = pen.prepareActivate(foreignContext, foreignOwner);
    assert(!foreignEffect.accepted && foreignEffect.kind == PreparedActivateKind.Pen &&
        foreignEffect.owner == pen.preparedOwnerForTest() &&
        !foreignContext.validate());

    auto commitLayer = new Layer; GpuMesh commitGpu;
    auto commitPen = new PenTool(() => &commitLayer.meshRef(), &commitGpu,
        LitShader.init);
    commitPen.state = PenState.Drawing;
    commitPen.vertices_ = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    // p0 shares the layer's vertex 0 (merge): the commit appends 2 vertices.
    commitLayer.meshRef().addVertex(Vec3(0,0,0)); commitPen.refreshLinks();
    commitPen.links_ = [0, -1, -1];
    commitPen.params_.currentPoint = 2;
    commitPen.frame.toWorld = [1,0,0,0, 0,1,0,0,
                               0,0,1,0, 0,0,0,1];
    commitPen.previewGpu.faceVao = 71;
    auto commitHistory = new CommandHistory();
    auto commitView = new View(0,0,1,1);
    commitPen.setGestureBindings(commitHistory, () => new MeshSessionEdit(
        &commitLayer.meshRef(), commitView, EditMode.Vertices,
        "test.pen", "Pen Polygon"));
    auto commitContext = new PreparedRecordContext(commitHistory,
        new RecordObserverHub()); commitContext.setResourceIdentity(7,11);
    auto commitEffect = commitPen.prepareDeactivate(commitContext, commitLayer,
        GpuUploadOwner.fakeForTest(&commitGpu),
        GpuUploadOwner.fakeForTest(&commitGpu),
        GpuUploadOwner.fakeForTest(commitPen.preparedPreviewGpu()),
        GpuResourceOwner.fakeForTest(commitPen.preparedPreviewGpu()),
        new BoxHandlerBatchResourceOwner(commitPen.vertHandlers, 7, 11), null);
    assert(commitEffect.resourceAccepted && commitEffect.historyAccepted &&
        commitEffect.kind == PreparedDeactivateKind.Pen &&
        commitLayer.meshRef().faces.length == 0 && commitContext.validate());
    commitContext.install(); size_t modelDepth, uiDepth;
    commitHistory.undoDepthCounts(modelDepth, uiDepth);
    assert(commitLayer.meshRef().faces.length == 1 && modelDepth == 1 &&
        commitLayer.meshRef().vertices.length == 3 &&
        commitLayer.meshRef().faces[0] == [0u, 1, 2] &&
        uiDepth == 0 && commitPen.state == PenState.Idle &&
        commitPen.vertices_.length == 0 && commitPen.vertHandlers.length == 0 &&
        commitPen.params_.currentPoint == -1 && commitPen.meshChanged &&
        commitContext.installTraceForTest() == [3,4,2,1,2,2,7,2,2]);

    // F2: the mesh changed after p0's link was made, so the commit
    // image shares no index — three own vertices after the two the mesh holds.
    auto bumpLayer = new Layer; GpuMesh bumpGpu;
    auto bumpPen = new PenTool(() => &bumpLayer.meshRef(), &bumpGpu,
        LitShader.init); bumpPen.state = PenState.Drawing;
    bumpPen.vertices_ = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    bumpLayer.meshRef().addVertex(Vec3(0,0,0)); bumpPen.refreshLinks();
    bumpPen.links_ = [0, -1, -1];
    bumpLayer.meshRef().addVertex(Vec3(5,5,5));
    bumpPen.params_.currentPoint = 2; bumpPen.previewGpu.faceVao = 72;
    bumpPen.frame.toWorld = commitPen.frame.toWorld;
    auto bumpHistory = new CommandHistory();
    bumpPen.setGestureBindings(bumpHistory, () => new MeshSessionEdit(
        &bumpLayer.meshRef(), commitView, EditMode.Vertices,
        "test.pen", "Pen Polygon"));
    auto bumpContext = new PreparedRecordContext(bumpHistory,
        new RecordObserverHub()); bumpContext.setResourceIdentity(7,11);
    assert(bumpPen.prepareDeactivate(bumpContext, bumpLayer,
        GpuUploadOwner.fakeForTest(&bumpGpu), GpuUploadOwner.fakeForTest(&bumpGpu),
        GpuUploadOwner.fakeForTest(bumpPen.preparedPreviewGpu()),
        GpuResourceOwner.fakeForTest(bumpPen.preparedPreviewGpu()),
        new BoxHandlerBatchResourceOwner(bumpPen.vertHandlers, 7, 11), null)
        .historyAccepted && bumpContext.validate());
    bumpContext.install();
    assert(bumpLayer.meshRef().vertices.length == 5 &&
        bumpLayer.meshRef().faces.length == 1 &&
        bumpLayer.meshRef().faces[0] == [2u, 3, 4],
        "pen F2: a link made before the mesh changed reached the commit image");

    auto shortLayer = new Layer; GpuMesh shortGpu;
    auto shortPen = new PenTool(() => &shortLayer.meshRef(), &shortGpu,
        LitShader.init); shortPen.state = PenState.Drawing;
    shortPen.vertices_ = [Vec3(0,0,0)];
    shortPen.params_.currentPoint = 0; shortPen.previewGpu.faceVao = 81;
    SnapResult shortSnap; shortSnap.snapped = true; shortSnap.targetIndex = 8;
    shortPen.lastSnap = shortSnap; publishLastSnap(shortSnap);
    auto shortContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); shortContext.setResourceIdentity(7,11);
    auto shortEffect = shortPen.prepareDeactivate(shortContext, shortLayer,
        null, null, null,
        GpuResourceOwner.fakeForTest(shortPen.preparedPreviewGpu()),
        new BoxHandlerBatchResourceOwner(shortPen.vertHandlers, 7, 11),
        new SnapOverlayOwner());
    assert(shortEffect.resourceAccepted && !shortEffect.historyAccepted &&
        shortContext.validate()); shortContext.install();
    assert(shortLayer.meshRef().faces.length == 0 &&
        shortPen.state == PenState.Idle && shortPen.vertices_.length == 0 &&
        shortPen.lastSnap == SnapResult.init &&
        shortContext.installTraceForTest() == [8,2,7,6,2]);

    auto edgeLayer = new Layer; GpuMesh edgeGpu;
    auto edgePen = new PenTool(() => &edgeLayer.meshRef(), &edgeGpu,
        LitShader.init); edgePen.state = PenState.Drawing;
    edgePen.vertices_ = [Vec3(0,0,0), Vec3(1,0,0)];
    edgePen.params_.currentPoint = 1; edgePen.previewGpu.faceVao = 86;
    edgePen.frame.toWorld = [1,0,0,0, 0,1,0,0,
                             0,0,1,0, 0,0,0,1];
    auto edgeHistory = new CommandHistory();
    auto edgeView = new View(0,0,1,1);
    edgePen.setGestureBindings(edgeHistory, () => new MeshSessionEdit(
        &edgeLayer.meshRef(), edgeView, EditMode.Vertices,
        "test.pen", "Pen Polygon"));
    auto edgeContext = new PreparedRecordContext(edgeHistory,
        new RecordObserverHub()); edgeContext.setResourceIdentity(7,11);
    auto edgeEffect = edgePen.prepareDeactivate(edgeContext, edgeLayer,
        GpuUploadOwner.fakeForTest(&edgeGpu),
        GpuUploadOwner.fakeForTest(&edgeGpu),
        GpuUploadOwner.fakeForTest(edgePen.preparedPreviewGpu()),
        GpuResourceOwner.fakeForTest(edgePen.preparedPreviewGpu()),
        new BoxHandlerBatchResourceOwner(edgePen.vertHandlers, 7, 11), null);
    assert(edgeEffect.resourceAccepted && edgeEffect.historyAccepted &&
        edgeLayer.meshRef().faces.length == 0 && edgeContext.validate());
    edgeContext.install();
    edgeHistory.undoDepthCounts(modelDepth, uiDepth);
    assert(edgeLayer.meshRef().faces.length == 1 &&
        edgeLayer.meshRef().faces[0].length == 2 && modelDepth == 1);

    auto mutationLayer = new Layer; GpuMesh mutationGpu;
    auto mutationPen = new PenTool(() => &mutationLayer.meshRef(), &mutationGpu,
        LitShader.init); mutationPen.previewGpu.faceVao = 91;
    auto mutationContext = new PreparedRecordContext(new CommandHistory(),
        new RecordObserverHub()); mutationContext.setResourceIdentity(7,11);
    auto mutationEffect = mutationPen.prepareDeactivate(mutationContext,
        mutationLayer, null, null, null,
        GpuResourceOwner.fakeForTest(mutationPen.preparedPreviewGpu()),
        new BoxHandlerBatchResourceOwner(mutationPen.vertHandlers, 7, 11),
        new SnapOverlayOwner());
    assert(mutationEffect.resourceAccepted); mutationPen.state = PenState.Drawing;
    assert(!mutationContext.validate()); mutationContext.discard();

    auto pointPen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    pointPen.state = PenState.Drawing;
    pointPen.vertices_ = [Vec3(1,2,3), Vec3(4,5,6)];
    pointPen.params_.currentPoint = 9;
    auto pointImage = pointPen.buildPreparedParamImage("currentPoint");
    assert(pointImage.expectedState == cast(ubyte)pointPen.state);
    assert(pointImage.expectedParams == pointPen.params_);
    assert(pointImage.expectedVertices == pointPen.vertices_);
    assert(pointImage.expectedPreview.matches(pointPen.previewMesh),
        "captured preview mismatch");
    assert(pointPen.preparedParamMatches(pointImage));
    auto pointContext = new PreparedRecordContext(null, new RecordObserverHub());
    pointContext.setResourceIdentity(7, 11);
    auto pointEffect = pointPen.prepareParamChanged(pointContext,
        "currentPoint", null);
    assert(pointEffect.accepted, "currentPoint preparation refused");
    assert(pointEffect.kind == PreparedPenParamKind.CurrentPoint);
    assert(pointPen.params_.currentPoint == 9, "prepare mutated live params");
    assert(pointContext.validate(), "currentPoint validation refused");
    pointContext.install();
    assert(pointPen.params_.currentPoint == 1 && pointPen.params_.posX == 4 &&
        pointPen.params_.posY == 5 && pointPen.params_.posZ == 6 &&
        pointContext.installTraceForTest() == [7,8]);

    auto positionPen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    positionPen.state = PenState.Drawing;
    positionPen.frame.toWorld = [1,0,0,0, 0,1,0,0,
                                 0,0,1,0, 0,0,0,1];
    positionPen.vertices_ = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    positionPen.links_ = [-1, 4, -1];
    positionPen.params_.currentPoint = 1;
    positionPen.params_.posX = 2; positionPen.params_.posY = 3;
    positionPen.params_.posZ = 4;
    // A Position edit never re-decides the facing (wave plan S4, cell A4c):
    // under this front ortho view the edited triangle would decide false.
    positionPen.params_.flip = true;
    positionPen.cachedVp.view = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
    positionPen.cachedVp.proj = positionPen.cachedVp.view;
    auto positionContext = new PreparedRecordContext(null,
        new RecordObserverHub()); positionContext.setResourceIdentity(7, 11);
    auto positionEffect = positionPen.prepareParamChanged(positionContext,
        "posX", GpuUploadOwner.fakeForTest(positionPen.preparedPreviewGpu()));
    assert(positionEffect.accepted && positionEffect.kind ==
        PreparedPenParamKind.Position &&
        positionPen.vertices_[1] == Vec3(1,0,0) &&
        positionPen.previewMesh.vertices.length == 0 &&
        positionContext.validate());
    positionContext.install();
    assert(positionPen.vertices_[1] == Vec3(2,3,4) && positionPen.links_ == [-1,-1,-1] &&
        positionPen.previewMesh.vertices == positionPen.vertices_ &&
        positionContext.installTraceForTest() == [7,2,8]);
    assert(positionPen.params_.flip, "a prepared Position edit re-decided flip");

    auto stalePen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    stalePen.state = PenState.Drawing; stalePen.vertices_ = [Vec3(1,1,1)];
    stalePen.links_ = [-1];
    stalePen.params_.currentPoint = 0; stalePen.params_.posX = 8;
    auto staleContext = new PreparedRecordContext(null, new RecordObserverHub());
    staleContext.setResourceIdentity(7, 11);
    assert(stalePen.prepareParamChanged(staleContext, "posX",
        GpuUploadOwner.fakeForTest(stalePen.preparedPreviewGpu())).accepted);
    stalePen.params_.posX = 9;
    assert(!staleContext.validate() && stalePen.vertices_[0] == Vec3(1,1,1));

    GpuMesh wrongPreview;
    auto wrongContext = new PreparedRecordContext(null, new RecordObserverHub());
    wrongContext.setResourceIdentity(7, 11); stalePen.params_.posX = 8;
    auto wrongEffect = stalePen.prepareParamChanged(wrongContext, "posX",
        GpuUploadOwner.fakeForTest(&wrongPreview));
    assert(!wrongEffect.accepted && !wrongContext.validate() &&
        stalePen.vertices_[0] == Vec3(1,1,1));

    // A shape param edited mid-stroke rebuilds the preview through the one
    // builder (prepared door): kind Preview, live preview untouched until
    // install. Strip [0,1,2,3] → quad [0,1,2,3] (flip off; penStripQuad).
    auto quadPen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    quadPen.state = PenState.Drawing;
    quadPen.frame.toWorld = [1,0,0,0, 0,1,0,0, 0,0,1,0, 10,20,30,1];
    quadPen.vertices_ = [Vec3(0,0,0), Vec3(0,1,0), Vec3(1,0,0), Vec3(1,1,0)];
    quadPen.params_.makeQuads = true;     // the panel writes before the hook
    auto quadImage = quadPen.buildPreparedParamImage("makeQuads");
    assert(quadImage.kind == PreparedPenParamKind.Preview && quadImage.upload,
        "makeQuads edit must prepare a preview rebuild");
    assert(quadImage.nextPreview.faces.length == 1 &&
        quadImage.nextPreview.faces[0] == [0u, 1, 2, 3],
        "makeQuads preview is not the builder's strip quad");
    assert(quadPen.buildPreparedParamImage("flip").kind ==
        PreparedPenParamKind.Preview, "flip edit must prepare a preview rebuild");
    // S8: the type and close change the stroke's shape; selectNew does not.
    assert(quadPen.buildPreparedParamImage("type").kind == PreparedPenParamKind.Preview &&
        quadPen.buildPreparedParamImage("close").kind == PreparedPenParamKind.Preview &&
        quadPen.buildPreparedParamImage("selectNew").kind == PreparedPenParamKind.Noop,
        "pen S8: type / close / selectNew preview kinds");
    assert(quadPen.buildPreparedParamImage("wall").kind == PreparedPenParamKind.Preview &&
        quadPen.buildPreparedParamImage("offset").kind == PreparedPenParamKind.Preview,
        "pen S9: wall / offset preview kinds");
    auto quadContext = new PreparedRecordContext(null, new RecordObserverHub());
    quadContext.setResourceIdentity(7, 11);
    auto quadEffect = quadPen.prepareParamChanged(quadContext, "makeQuads",
        GpuUploadOwner.fakeForTest(quadPen.preparedPreviewGpu()));
    assert(quadEffect.accepted && quadEffect.kind == PreparedPenParamKind.Preview
        && quadPen.previewMesh.vertices.length == 0 && quadContext.validate(),
        "makeQuads preparation refused or touched the live preview");
    quadContext.install();
    assert(quadPen.previewMesh.faces == [[0u, 1, 2, 3]] &&
        quadPen.vertices_.length == 4 && quadContext.installTraceForTest() ==
        [7,2,8], "makeQuads install did not land the rebuilt preview");

    // The legacy hook (scripted `tool.attr`) rebuilds the same preview. The
    // suppressed cage upload stands in for GL, which the module gate lacks.
    auto hookPen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    hookPen.state = PenState.Drawing; hookPen.previewGpu.suppressCageUpload = true;
    hookPen.frame.toWorld = quadPen.frame.toWorld;
    hookPen.vertices_ = quadPen.vertices_.dup; hookPen.links_ = [-1,-1,-1,-1];
    foreach (v; hookPen.vertices_) hookPen.vertHandlers ~= hookPen.vertMarker(v);
    hookPen.onParamChanged("flip");
    assert(hookPen.previewMesh.faces == [[1u, 2, 3, 0]],
        "legacy flip hook did not rebuild the preview (penRingOrder ring)");
    hookPen.params_.makeQuads = true; hookPen.onParamChanged("makeQuads");
    assert(hookPen.previewMesh.faces == [[0u, 1, 2, 3]],
        "legacy makeQuads hook did not rebuild the preview");
    assert(hookPen.previewMesh.vertices[0] == Vec3(10,20,30),
        "legacy hook preview ignored the frame's toWorld");
    assert(quadImage.nextPreview.vertices == hookPen.previewMesh.vertices,
        "prepared preview vertices differ from the legacy hook's (toWorld)");

    // An undo / redo image re-derives the stroke from `points`: state, markers
    // and the preview; a stale preview must not survive the restore. (Empty
    // first: a marker's destroy needs GL, which the module gate lacks.)
    auto imagePen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    imagePen.previewGpu.suppressCageUpload = true;
    imagePen.frame.toWorld = quadPen.frame.toWorld;
    imagePen.state = PenState.Drawing; imagePen.previewMesh.addVertex(Vec3(5,5,5));
    imagePen.rebuildPreviewFromAttrs();
    assert(imagePen.state == PenState.Idle && imagePen.previewMesh.vertices.length == 0,
        "restored empty stroke: not Idle, or a stale preview survived");
    imagePen.vertices_ = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    imagePen.links_ = [-1,-1,-1];
    imagePen.rebuildPreviewFromAttrs();
    assert(imagePen.state == PenState.Drawing && imagePen.vertHandlers.length == 3,
        "restored stroke: not Drawing, or its markers did not come back");
    assert(imagePen.previewMesh.vertices.length == 3 &&
        imagePen.previewMesh.faces.length == 1 &&
        imagePen.previewMesh.vertices[1] == Vec3(11,20,30),
        "restored stroke: the preview was not rebuilt from the points");

    // A tool drop commits through the prepared candidate with the image's
    // params: flip reverses the winding, makeQuads lays out the strip quad.
    uint[] dropFace(Vec3[] points, bool flip, bool quads, Vec3[] existing) {
        auto layer = new Layer; GpuMesh gpu;
        foreach (v; existing) layer.meshRef().addVertex(v);
        auto pen = new PenTool(() => &layer.meshRef(), &gpu, LitShader.init);
        pen.state = PenState.Drawing; pen.vertices_ = points;
        pen.params_.flip = flip; pen.params_.makeQuads = quads;
        pen.frame.toWorld = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
        auto history = new CommandHistory(); auto view = new View(0,0,1,1);
        pen.setGestureBindings(history, () => new MeshSessionEdit(
            &layer.meshRef(), view, EditMode.Vertices, "test.pen", "Pen Polygon"));
        auto context = new PreparedRecordContext(history,
            new RecordObserverHub()); context.setResourceIdentity(7,11);
        auto effect = pen.prepareDeactivate(context, layer,
            GpuUploadOwner.fakeForTest(&gpu), GpuUploadOwner.fakeForTest(&gpu),
            GpuUploadOwner.fakeForTest(pen.preparedPreviewGpu()),
            GpuResourceOwner.fakeForTest(pen.preparedPreviewGpu()),
            new BoxHandlerBatchResourceOwner(pen.vertHandlers, 7, 11), null);
        assert(effect.historyAccepted && context.validate(), "drop refused");
        context.install();
        assert(layer.meshRef().faces.length == 1, "drop did not commit one face");
        return layer.meshRef().faces[0].dup;
    }
    assert(dropFace([Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)], true, false,
        [Vec3(5,5,5)]) == [1u, 3, 2], "drop ignored the image's flip");
    assert(dropFace(quadPen.vertices_.dup, false, true, null) == [0u, 1, 2, 3],
        "drop ignored the image's makeQuads");

    // S6: a prepared drop commits the stroke AND its mirror (plane x = 0) in
    // one history row; a symmetry change after the prepare refuses the image
    // (deactivate and param doors alike).
    PreparedRecordContext symDrop(PenTool pen, Layer layer, GpuMesh* gpu,
                                  CommandHistory history) {
        pen.setGestureBindings(history, () => new MeshSessionEdit(&layer.meshRef(),
            commitView, EditMode.Vertices, "test.pen", "Pen Polygon"));
        auto context = new PreparedRecordContext(history, new RecordObserverHub());
        context.setResourceIdentity(7,11);
        assert(pen.prepareDeactivate(context, layer, GpuUploadOwner.fakeForTest(gpu),
            GpuUploadOwner.fakeForTest(gpu),
            GpuUploadOwner.fakeForTest(pen.preparedPreviewGpu()),
            GpuResourceOwner.fakeForTest(pen.preparedPreviewGpu()),
            new BoxHandlerBatchResourceOwner(pen.vertHandlers, 7, 11), null)
            .historyAccepted, "mirror drop refused");
        return context;
    }
    PenTool symPen(Layer layer, GpuMesh* gpu) {
        auto pen = new PenTool(() => &layer.meshRef(), gpu, LitShader.init);
        pen.state = PenState.Drawing; pen.links_ = [-1, -1, -1];
        pen.vertices_ = [Vec3(1,0,0), Vec3(2,0,0), Vec3(1,1,0)];
        pen.frame.toWorld = commitPen.frame.toWorld; pen.mirror_.enabled = true;
        return pen;
    }
    auto symLayer = new Layer; GpuMesh symGpu;
    auto symHistory = new CommandHistory();
    auto symContext = symDrop(symPen(symLayer, &symGpu), symLayer, &symGpu, symHistory);
    assert(symContext.validate(), "pen S6: the mirror drop's prepare did not validate");
    symContext.install();
    symHistory.undoDepthCounts(modelDepth, uiDepth);
    assert(symLayer.meshRef().faces.length == 2 && modelDepth == 1 &&
        symLayer.meshRef().vertices.length == 6, "pen S6: the drop did not commit "
        ~ "the stroke and its mirror in one row");
    auto staleLayer = new Layer; GpuMesh staleGpu;
    auto staleSym = symPen(staleLayer, &staleGpu);
    auto staleDrop = symDrop(staleSym, staleLayer, &staleGpu, new CommandHistory());
    staleSym.mirror_.enabled = false;
    assert(!staleDrop.validate(), "pen S6: a symmetry change after the drop's "
        ~ "prepare was not refused");
    staleDrop.discard();
    auto okSym = symPen(staleLayer, &staleGpu);
    okSym.params_.currentPoint = 0; okSym.params_.posX = 3;
    auto okContext = new PreparedRecordContext(null, new RecordObserverHub());
    okContext.setResourceIdentity(7, 11);
    assert(okSym.prepareParamChanged(okContext, "posX",
        GpuUploadOwner.fakeForTest(okSym.preparedPreviewGpu())).accepted &&
        okContext.validate(), "pen S6: an unchanged mirrored Position prepare "
        ~ "did not validate");
    okContext.discard();
    auto paramSym = symPen(staleLayer, &staleGpu);
    paramSym.params_.currentPoint = 0; paramSym.params_.posX = 3;
    auto paramContext = new PreparedRecordContext(null, new RecordObserverHub());
    paramContext.setResourceIdentity(7, 11);
    assert(paramSym.prepareParamChanged(paramContext, "posX",
        GpuUploadOwner.fakeForTest(paramSym.preparedPreviewGpu())).accepted);
    paramSym.mirror_.planePoint = Vec3(0.5f, 0, 0);
    assert(!paramContext.validate(), "pen S6: a symmetry change after a Position "
        ~ "prepare was not refused");
    auto normalSym = symPen(staleLayer, &staleGpu);
    auto normalContext = new PreparedRecordContext(null, new RecordObserverHub());
    normalContext.setResourceIdentity(7, 11);
    assert(normalSym.prepareParamChanged(normalContext, "flip",
        GpuUploadOwner.fakeForTest(normalSym.preparedPreviewGpu())).accepted);
    normalSym.mirror_.planeNormal = Vec3(0, 1, 0);
    assert(!normalContext.validate(), "pen S6: a mirror-plane normal change after "
        ~ "a prepare was not refused");
    // Both preview doors build the mirror and drop scene links (a preview
    // holds no scene vertex): 3 own points + 3 images.
    auto previewSym = symPen(staleLayer, &staleGpu);
    previewSym.links_ = [-1, 0, -1];
    previewSym.params_.currentPoint = 0; previewSym.params_.posX = 3;
    const doorCount = previewSym.buildPreparedParamImage("posX")
        .nextPreview.vertices.length;
    previewSym.previewGpu.suppressCageUpload = true;
    foreach (v; previewSym.vertices_) previewSym.vertHandlers ~= previewSym.vertMarker(v);
    previewSym.onParamChanged("flip");
    assert(doorCount == 6 && previewSym.previewMesh.vertices.length == 6,
        format("pen S6: preview vertices %s (Position door) / %s (legacy hook); "
            ~ "expected 6, 6", doorCount, previewSym.previewMesh.vertices.length));
    // The self weld reads the latch's enabled flag: unlatched, `mirror_` is
    // `.init` (plane x = 0), so a point on x = 0 must stay its own. A drag
    // re-decides a self weld, so no suite gesture sees the term alone.
    auto offSym = symPen(staleLayer, &staleGpu);
    offSym.cachedVp = positionPen.cachedVp; offSym.cachedVp.height = 400;
    offSym.mirror_ = SymmetryPacket.init;
    const offLink = offSym.selfMirrorOr(-1, Vec3(0, 0, 0), 0);
    offSym.mirror_.enabled = true;
    const onLink = offSym.selfMirrorOr(-1, Vec3(0, 0, 0), 0);
    assert(offLink == -1 && onLink == -2, format("pen S6: a point on x = 0 self-welds "
        ~ "%s with symmetry off, %s on; expected -1, -2", offLink, onLink));

    // S8: the commit minimums per type (Enter / drop): polygons 3 / 2,
    // lines 2 / 2, vertices 1 / 1, subdiv 3 / 2.
    auto minPen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    size_t[2][] mins;
    foreach (t; [PenType.polygons, PenType.lines, PenType.vertices, PenType.subdiv]) {
        minPen.params_.type = t;
        mins ~= [minPen.minCommitVerts(), minPen.minDropCommitVerts()];
    }
    assert(mins == [[3, 2], [2, 2], [1, 1], [3, 2]], format("pen S8: minimums %s", mins));
    // S8: the selection mode is a commit-time value of the drop's image: a
    // mode change after the prepare refuses it.
    SelType mode = SelType.Polygon;
    auto modeLayer = new Layer; GpuMesh modeGpu;
    auto modePen = new PenTool(() => &modeLayer.meshRef(), &modeGpu, LitShader.init,
        () nothrow @nogc => mode);
    modePen.state = PenState.Drawing; modePen.links_ = [-1, -1, -1];
    modePen.vertices_ = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    modePen.frame.toWorld = commitPen.frame.toWorld;
    auto modeImage = modePen.buildPreparedDeactivateState();
    assert(modeImage.selMode == SelType.Polygon && modePen.preparedDeactivateStateMatches(
        modeImage), "pen S8: the drop image does not carry the live selection mode");
    mode = SelType.Edge;
    assert(!modePen.preparedDeactivateStateMatches(modeImage),
        "pen S8: a selection-mode change after the drop's prepare was not refused");

    // S8 (A4-rev): the session's cancel ends a Drawing stroke only; an idle
    // pen's operation is not ended (its in-stroke redo survives).
    auto guardPen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    size_t ended;
    ToolSessionLink link;
    link.operationEnded = (Tool) { ++ended; };
    guardPen.bindSession(link);
    guardPen.cancelUncommittedEdit();
    const idleEnded = ended;
    guardPen.state = PenState.Drawing; guardPen.vertices_ = [Vec3(1,2,3)];
    guardPen.links_ = [-1];
    guardPen.cancelUncommittedEdit();
    assert(idleEnded == 0 && ended == 1 && guardPen.vertices_.length == 0 &&
        guardPen.state == PenState.Idle, format("pen S8: cancel ended an idle pen %s "
        ~ "times, a Drawing one %s; expected 0, 1 and the stroke empty", idleEnded,
        ended - idleEnded));
}

// ---------------------------------------------------------------------------
// PenTool — interactive polygon-by-vertex creation.
//
// Phase 6.9.0 (skeleton + polygons mode):
//   Idle ── LMB-click ─→ Drawing (first vertex placed on the camera-most-
//                                  facing plane through the focus; plane
//                                  axis locked for the stroke)
//   Drawing ── LMB-click ─→ Drawing (vertex after the current point, on the
//                                     plane through the current point)
//   Drawing ── double-click / Enter ─→ commit the stroke's shape; Idle
//   Drawing ── tool drop (n ≥ 2) ─→ commit; back to Idle
//   Drawing ── a UI command (Backspace = the global delete) ─→ commit from
//              the drop minimum (else end with nothing), then the command
//              runs; the tool stays (wave plan S8, BD-sel / UC-close / UC1-end)
//   Drawing ── Ctrl+Z ─→ the stroke before its last event (S12)
//   Drawing ── RMB ─→ cancel points when no active falloff owns RMB; tool stays
//
// In-progress vertex markers render in cyan (Vec3(0, 0.9, 0.9)); the central
// ToolHandles arbiter (Test pass) flips the single cursor-over vertex to
// yellow ("they'll turn yellow when the mouse is directly over them").
// Edges between consecutive in-progress vertices preview as the standard
// wireframe (open polyline — closing happens at commit).
//
// On commit, the in-progress vertex sequence is appended to the scene
// mesh and a face is added in `penRingOrder` (flip decided at point 3).
// A snapshot pair is captured around the commit for undo.
//
// Unlike Box / Sphere / Cylinder / etc., Pen does NOT auto-deactivate
// after a single commit — the user can keep drawing more polygons until
// they switch tools or hit a different shortcut. Cache refresh is called
// from inside commitPolygonWithUndo (the commit fires on key / mouse
// events, not just deactivate, so the tool-drop path can't cover it).
// ---------------------------------------------------------------------------

private enum PenState { Idle, Drawing }

struct PreparedPenDeactivateImage {
    bool valid, willCommit;
    ubyte expectedState;
    PenParams params;
    Vec3[] vertices;
    int[] links;
    SessionMeshKey[] linkKey;   // the mesh `links` index; read at the candidate build
    SymmetryPacket mirror;
    SelType selMode;            // read at the candidate build (selectNew)
    Mesh previewClear;
    float[16] toWorld;
    Vec3 wallNormal;
    size_t expectedHandlerCount;
    SnapResult expectedLastSnap;
    bool expectedMeshChanged;
    void clear() nothrow @nogc {
        vertices = null; links = null; linkKey = null; previewClear = Mesh.init;
        this = PreparedPenDeactivateImage.init;
    }
}

struct PreparedPenParamImage {
    bool valid, upload;
    PreparedPenParamKind kind;
    ubyte expectedState;
    PenParams expectedParams, nextParams;
    Vec3[] expectedVertices, nextVertices;
    int[] expectedLinks, nextLinks;
    BoxHandler[] expectedHandlers;
    Vec3[] expectedHandlerPositions, nextHandlerPositions;
    float[16] expectedToWorld;
    Vec3 expectedWallNormal;
    SymmetryPacket expectedMirror;
    MeshSnapshot expectedPreview;
    Mesh nextPreview;
    void clear() nothrow @nogc {
        expectedVertices = nextVertices = null;
        expectedLinks = nextLinks = null;
        expectedHandlers = null;
        expectedHandlerPositions = nextHandlerPositions = null;
        expectedPreview = MeshSnapshot.init; nextPreview = Mesh.init;
        valid = upload = false; kind = PreparedPenParamKind.None;
    }
}

class PenTool : Tool, PreparedToolDoorClient, PreparedToolParamDoorClient {
    mixin PreparedPenParamDoorClient;
private:
    Mesh* delegate() meshSrc_;
    @property Mesh* mesh() const { return meshSrc_(); }
    // The selection mode a commit reads (selectNew); Vertex when unwired.
    SelType delegate() nothrow @nogc selTypeSrc_;
    SelType selMode() const nothrow @nogc { return selTypeSrc_ ? selTypeSrc_() : SelType.Vertex; }
    GpuMesh*         gpu;
    LitShader        litShader;


    PenParams        params_;

    PenState         state;
    Vec3[]           vertices_;     // LOCAL workplane positions of the in-progress sequence
    int[]            links_;        // per point: the edited-mesh vertex it shares, or -1
    // The mesh `links_` index (0 or 1 element). An image attribute beside
    // `links_`, so a session restore brings back the key its links were made
    // under; links are read only while it matches (`liveLinks`, below).
    SessionMeshKey[] strokeKey_;
    BoxHandler[]     vertHandlers;  // one cyan marker per in-progress vertex (handler.pos in WORLD)
    ToolHandles      toolHandles;   // single-source hover arbiter (Test pass)

    Mesh             previewMesh;
    GpuMesh          previewGpu;

    // The stroke's plane normal, a LOCAL axis of `frame`, locked per stroke,
    // and in WORLD signed toward the camera (wall mode's "left", S9).
    Vec3 planeNormal, wallNormal;
    // The stroke's symmetry, latched at its first click (`latchMirror`).
    SymmetryPacket mirror_;
    /// Storage frame captured at choosePlane(). All in-progress vertices live
    /// in this frame's local space.
    WorkplaneFrame frame;

    Viewport cachedVp;
    bool     meshChanged;

    // 6.9.1 vertex-edit state. dragArmed = true between LMB-down on a
    // vertex and the matching LMB-up; flips dragInitiated once the cursor
    // moves more than DRAG_THRESHOLD_PX pixels (so a press-and-release on a
    // vertex *selects* it rather than moving anything).
    bool dragArmed;
    bool dragInitiated;
    int  dragVertIdx = -1;
    int  dragStartMX, dragStartMY;
    Vec3 dragAnchor;    // the dragged point's pre-drag position (its plane)

    enum int DRAG_THRESHOLD_PX = 4;

    // Last snap query — drives the cyan/yellow overlay. Refreshed on
    // every motion event when the cursor is over the construction
    // plane; consumed by clicks (which snap the placed vertex to the
    // target's world position).
    SnapResult lastSnap;

public:
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader,
         SelType delegate() nothrow @nogc selTypeSrc = null) {
        this.meshSrc_ = meshSrc;
        this.selTypeSrc_ = selTypeSrc;
        this.gpu       = gpu;
        this.litShader = litShader;
        toolHandles    = new ToolHandles();
    }

    void destroy() {
        clearVertHandlers();
    }

    override string name() const { return "Pen"; }

    override ulong previewUploadVersion() const nothrow @nogc {
        return previewGpu.uploadVersion;
    }
    override int previewHotPart() const nothrow @nogc {
        return toolHandles.hot;
    }

    override Param[] params() {
        import params : IntEnumEntry;
        return [
            Param.intEnum_("type", "Type", &params_.type,
                [IntEnumEntry(PenType.polygons, "polygons", "Polygons"),
                 IntEnumEntry(PenType.lines, "lines", "Lines"),
                 IntEnumEntry(PenType.vertices, "vertices", "Vertices"),
                 IntEnumEntry(PenType.subdiv, "subdiv", "Subdiv")],
                PenType.polygons),
            // currentPoint/posX/Y/Z: per-gesture point-edit proxies
            // (onParamChanged mutates vertices_[currentPoint] while
            // Drawing) — not a remembered setting. Excluded from
            // sticky-tool-defaults capture via .transient().
            // .enforceBounds() (task 1410): the hand-written clamp in
            // onParamChanged (`< -1 -> -1`, `>= n -> n-1`, below) is NOT on
            // the `tool.attr` path -- measured, `tool.attr pen currentPoint
            // 1e39` read back -2147483648, straight from the unclamped
            // float->int cast at params.d:809. -1 is this param's "no current
            // point" sentinel, so clamping to [-1,1024] lands on the sentinel
            // rather than on a bogus index. Pinned by
            // tests/test_param_cast_overflow.d.
            Param.int_("currentPoint", "Current Point", &params_.currentPoint, -1)
                .min(-1).max(1024).enforceBounds().transient(),
            Param.float_("posX", "Position X", &params_.posX, 0.0f).transient(),
            Param.float_("posY", "Position Y", &params_.posY, 0.0f).transient(),
            Param.float_("posZ", "Position Z", &params_.posZ, 0.0f).transient(),
            Param.bool_("flip", "Flip Polygon", &params_.flip, false),
            Param.bool_("makeQuads", "Make Quads", &params_.makeQuads, false),
            Param.bool_("merge", "Merge", &params_.merge, true),
            Param.bool_("close", "Close", &params_.close, false),
            Param.bool_("selectNew", "Select New", &params_.selectNew, true),
            // Wall mode (wave plan S9): a negative offset clamps to 0.
            Param.intEnum_("wall", "Wall", &params_.wall,
                [IntEnumEntry(PenWall.off, "off", "Off"),
                 IntEnumEntry(PenWall.inner, "inner", "Inner"),
                 IntEnumEntry(PenWall.outer, "outer", "Outer"),
                 IntEnumEntry(PenWall.both, "both", "Both")],
                PenWall.off),
            Param.float_("offset", "Offset", &params_.offset, 0.0f).min(0.0f).enforceBounds(),
            // The stroke itself, for the session's undo image (hidden,
            // transient, refused on every wire door).
            Param.podArray_("points", "Points", &vertices_),
            Param.podArray_("link", "Links", &links_),
            Param.podArray_("linkKey", "Link Key", &strokeKey_),
        ];
    }

    // A disabled param's write is refused at the `tool.attr` door, for
    // every tool. Make Quads is locked from 3 points
    // (wave plan S7, fixture pen_quads.json lock_3_points); the point fields
    // stay enabled at idle, as captured (K-A3).
    override bool paramEnabled(string name) const {
        if (name == "makeQuads") return vertices_.length < 3;   // Idle holds none
        if (name == "close")
            return params_.type == PenType.lines || params_.wall != PenWall.off;
        return true;
    }

    override void onParamChanged(string name) {
        // Numeric edit via the property panel — write back into the buffer
        // and re-render. The panel writes through the typed pointer first,
        // so params_.* already holds the new value when this fires.
        if (state != PenState.Drawing) return;

        if (name == "currentPoint") {
            // Clamp to a valid index range and refresh posX/Y/Z to mirror the
            // newly selected vertex. -1 is the legitimate "nothing current"
            // sentinel.
            int n = cast(int)vertices_.length;
            if (params_.currentPoint < -1) params_.currentPoint = -1;
            if (params_.currentPoint >= n) params_.currentPoint = n - 1;
            syncPosFromCurrent();
            return;
        }
        if (name == "posX" || name == "posY" || name == "posZ") {
            int idx = params_.currentPoint;
            if (idx < 0 || idx >= cast(int)vertices_.length) return;
            vertices_[idx] = Vec3(params_.posX, params_.posY, params_.posZ);
            links_[idx] = -1;    // a typed point never shares a vertex (S5)
            uploadPreview();
            return;
        }
        if (rebuildsPreview(name)) uploadPreview();
    }

    // Params that change the stroke's shape but not its points: an edit
    // mid-stroke rebuilds the preview (legacy hook and prepared door alike).
    private static bool rebuildsPreview(string name) nothrow @nogc {
        return name == "flip" || name == "makeQuads" || name == "type" ||
            name == "close" || name == "wall" || name == "offset";
    }

    final PreparedPenParamImage buildPreparedParamImage(string name) const {
        PreparedPenParamImage image;
        image.valid = true; image.kind = PreparedPenParamKind.Noop;
        image.expectedState = cast(ubyte)state;
        image.expectedParams = params_; image.nextParams = params_;
        image.expectedVertices = vertices_.dup;
        image.nextVertices = vertices_.dup;
        image.expectedLinks = links_.dup; image.nextLinks = links_.dup;
        image.expectedHandlers.length = vertHandlers.length;
        image.expectedHandlerPositions.length = vertHandlers.length;
        image.nextHandlerPositions.length = vertHandlers.length;
        foreach (i, handler; vertHandlers) {
            image.expectedHandlers[i] = cast(BoxHandler)handler;
            image.expectedHandlerPositions[i] = handler.pos;
            image.nextHandlerPositions[i] = handler.pos;
        }
        image.expectedToWorld = frame.toWorld;
        image.expectedWallNormal = wallNormal;
        image.expectedMirror = penMirror(mirror_);
        image.expectedPreview = MeshSnapshot.capture(previewMesh);
        if (state != PenState.Drawing) return image;
        if (name == "currentPoint") {
            image.kind = PreparedPenParamKind.CurrentPoint;
            int n = cast(int)image.nextVertices.length;
            if (image.nextParams.currentPoint < -1)
                image.nextParams.currentPoint = -1;
            if (image.nextParams.currentPoint >= n)
                image.nextParams.currentPoint = n - 1;
            int idx = image.nextParams.currentPoint;
            if (idx < 0 || idx >= n)
                image.nextParams.posX = image.nextParams.posY =
                    image.nextParams.posZ = 0;
            else {
                auto p = image.nextVertices[idx];
                image.nextParams.posX = p.x; image.nextParams.posY = p.y;
                image.nextParams.posZ = p.z;
            }
            return image;
        }
        if (rebuildsPreview(name)) {
            image.kind = PreparedPenParamKind.Preview; image.upload = true;
        } else if (name == "posX" || name == "posY" || name == "posZ") {
            int idx = image.nextParams.currentPoint;
            if (idx < 0 || idx >= cast(int)image.nextVertices.length)
                return image;
            image.kind = PreparedPenParamKind.Position; image.upload = true;
            image.nextVertices[idx] = Vec3(image.nextParams.posX,
                image.nextParams.posY, image.nextParams.posZ);
            image.nextLinks[idx] = -1;
        } else return image;
        auto shadow = beginPreparedShadow(image.nextPreview);
        appendPenGeometry(image.nextPreview, PenStroke.of(image.nextVertices,
            frame.toWorld, image.nextParams, withoutSceneLinks(image.nextLinks),
            mirror_, wallNormal: wallNormal), PenBuildPurpose.Preview);
        foreach (i, v; image.nextVertices)
            if (i < image.nextHandlerPositions.length)
                image.nextHandlerPositions[i] = transformPoint(frame.toWorld, v);
        uint ignoredFlags, ignoredDomains;
        drainPreparedShadowDelivery(image.nextPreview, ignoredFlags, ignoredDomains);
        shadow.close();
        return image;
    }
    final bool preparedParamMatches(in PreparedPenParamImage image)
            const nothrow @nogc {
        if (!image.valid || cast(ubyte)state != image.expectedState ||
            !sameValueBytes(params_, image.expectedParams) ||
            !sameSliceBytes(vertices_, image.expectedVertices) ||
            !sameSliceBytes(links_, image.expectedLinks) ||
            !sameValueBytes(frame.toWorld, image.expectedToWorld) ||
            !sameValueBytes(wallNormal, image.expectedWallNormal) ||
            !symmetryMirrorsEqual(mirror_, image.expectedMirror) ||
            !image.expectedPreview.matches(previewMesh) ||
            vertHandlers.length != image.expectedHandlers.length) return false;
        foreach (i, handler; vertHandlers)
            if (handler !is image.expectedHandlers[i] ||
                !sameValueBytes(handler.pos,
                    image.expectedHandlerPositions[i])) return false;
        return true;
    }
    final void installPreparedParam(ref PreparedPenParamImage image)
            nothrow @nogc {
        if (!image.valid) return;
        params_ = image.nextParams;
        vertices_ = image.nextVertices; image.nextVertices = null;
        links_ = image.nextLinks; image.nextLinks = null;
        if (image.upload) installPreparedMeshImage(previewMesh, image.nextPreview);
        foreach (i, handler; vertHandlers)
            handler.pos = image.nextHandlerPositions[i];
        image.clear();
    }
    override void activate() {
        state = PenState.Idle;
        clearStroke();
        params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
        dragArmed     = false;
        dragInitiated = false;
        dragVertIdx   = -1;
        previewGpu.init();
    }

    final PreparedSessionActivateEffect prepareActivate(
            PreparedRecordContext context, GpuCreateOwner gpuOwner) {
        if (context is null) return PreparedSessionActivateEffect(
            preparedToolStateOwner, PreparedActivateKind.Pen, false);
        scope(failure) context.discard();
        auto stateOwner = PreparedPrivateStateOwner.pen(this);
        bool ok = stateOwner !is null && gpuOwner !is null &&
            gpuOwner.replacesLikeLegacyInit() && gpuOwner.owns(&previewGpu) &&
            context.preparePrivateState(stateOwner) &&
            context.prepareCreate(gpuOwner) && context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedSessionActivateEffect(preparedToolStateOwner,
            PreparedActivateKind.Pen, ok);
    }
    override bool prepareDoorActivate(PreparedRecordContext context, Layer,
            ulong threadIdentity, ulong contextIdentity) {
        auto owner = new GpuCreateOwner(&previewGpu, threadIdentity,
            contextIdentity, true);
        return prepareActivate(context, owner).accepted;
    }

    final GpuMesh* preparedPreviewGpu() nothrow @nogc { return &previewGpu; }
    final PreparedPenParamEffect prepareParamChanged(PreparedRecordContext context,
            string name, GpuUploadOwner previewUpload) {
        if (context is null) return PreparedPenParamEffect(
            preparedToolStateOwner, PreparedPenParamKind.None, false);
        scope(failure) context.discard();
        auto stateOwner = PreparedPrivateStateOwner.penParam(this, name);
        auto kind = stateOwner is null ? PreparedPenParamKind.None :
            stateOwner.penParamKind;
        bool ok = stateOwner !is null && context.preparePrivateState(stateOwner);
        if (ok && stateOwner.penParamUploads)
            ok = ownsPreparedPreviewUpload(previewUpload) &&
                context.prepareUpload(previewUpload, stateOwner.penParamPreview);
        if (ok) ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return PreparedPenParamEffect(preparedToolStateOwner, kind, ok);
    }
    version(unittest) final auto preparedOwnerForTest() const nothrow @nogc {
        return preparedToolStateOwner;
    }
    // The viewport `draw` caches, for a GL-context rig that drives the mouse.
    version(unittest) final void setViewportForTest(Viewport vp) nothrow @nogc {
        cachedVp = vp;
    }

    final void installPreparedPrivateActivation() nothrow @nogc {
        state = PenState.Idle; clearStroke(); params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
        dragArmed = dragInitiated = false; dragVertIdx = -1;
    }

    final PreparedPenDeactivateImage buildPreparedDeactivateState() const {
        PreparedPenDeactivateImage image;
        image.valid = true; image.expectedState = cast(ubyte)state;
        image.params = params_; image.vertices = vertices_.dup;
        image.links = links_.dup; image.linkKey = strokeKey_.dup;
        image.toWorld = frame.toWorld; image.mirror = penMirror(mirror_);
        image.wallNormal = wallNormal; image.selMode = selMode();
        image.expectedHandlerCount = vertHandlers.length;
        image.expectedLastSnap = lastSnap;
        image.expectedMeshChanged = meshChanged;
        image.willCommit = state == PenState.Drawing &&
            vertices_.length >= minDropCommitVerts();
        return image;
    }
    final bool preparedDeactivateStateMatches(
            in PreparedPenDeactivateImage image) const nothrow @nogc {
        return image.valid && cast(ubyte)state == image.expectedState &&
            params_ == image.params && vertices_ == image.vertices &&
            links_ == image.links && symmetryMirrorsEqual(mirror_, image.mirror) &&
            vertHandlers.length == image.expectedHandlerCount &&
            lastSnap == image.expectedLastSnap &&
            meshChanged == image.expectedMeshChanged &&
            (!image.willCommit || (frame.toWorld == image.toWorld &&
                                   sameValueBytes(wallNormal, image.wallNormal) &&
                                   selMode() == image.selMode));
    }
    final void installPreparedDeactivateState(
            ref PreparedPenDeactivateImage image) nothrow @nogc {
        state = PenState.Idle; vertHandlers = null; clearStroke();
        installPreparedMeshImage(previewMesh, image.previewClear);
        params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
        if (image.willCommit) meshChanged = true;
        else lastSnap = SnapResult.init;
        image.clear();
    }
    final bool ownsPreparedMainUpload(GpuUploadOwner owner) nothrow @nogc {
        return owner !is null && owner.owns(gpu);
    }
    final bool ownsPreparedPreviewUpload(GpuUploadOwner owner) nothrow @nogc {
        return owner !is null && owner.owns(&previewGpu);
    }
    final bool ownsPreparedPreviewDestroy(GpuResourceOwner owner) nothrow @nogc {
        return owner !is null && owner.owns(&previewGpu);
    }
    final bool ownsPreparedHandlers(BoxHandlerBatchResourceOwner owner)
            const nothrow @nogc {
        return owner !is null && owner.owns(vertHandlers);
    }
    private bool buildPreparedDeactivateCandidate(
            in PreparedPenDeactivateImage image, out Mesh candidate,
            out MeshSnapshot pre, out uint deliveryFlags,
            out uint deliveryDomains) {
        if (!image.willCommit) return true;
        pre = MeshSnapshot.capture(*mesh); pre.restore(candidate);
        auto shadow = beginPreparedShadow(candidate);
        appendPenGeometry(candidate, PenStroke.of(image.vertices,
            image.toWorld, image.params,
            linksUnder(image.linkKey, image.links, *mesh), image.mirror,
            image.selMode, image.wallNormal), PenBuildPurpose.Commit);
        candidate.declareCornerAppend(); candidate.buildLoops();
        candidate.syncSelection();
        drainPreparedShadowDelivery(candidate, deliveryFlags, deliveryDomains);
        shadow.close(); return true;
    }

    final PreparedDeactivateEffect prepareDeactivate(PreparedRecordContext context,
            Layer layer, GpuUploadOwner mainCommitUpload,
            GpuUploadOwner mainRefreshUpload, GpuUploadOwner previewEmptyUpload,
            GpuResourceOwner previewDestroy,
            BoxHandlerBatchResourceOwner handlerDestroy,
            SnapOverlayOwner snapOwner) {
        if (context is null) return PreparedDeactivateEffect(
            preparedToolStateOwner, PreparedDeactivateKind.Pen, false, false);
        scope(failure) context.discard();
        auto probe = buildPreparedDeactivateState();
        bool ok = layer !is null && &layer.meshRef() is mesh &&
            ownsPreparedPreviewDestroy(previewDestroy) &&
            ownsPreparedHandlers(handlerDestroy);
        Mesh candidate, emptyPreview; MeshSnapshot pre;
        uint deliveryFlags, deliveryDomains;
        if (ok) ok = buildPreparedDeactivateCandidate(probe, candidate, pre,
            deliveryFlags, deliveryDomains);
        if (ok && probe.willCommit)
            ok = ownsPreparedMainUpload(mainCommitUpload) &&
                ownsPreparedMainUpload(mainRefreshUpload) &&
                ownsPreparedPreviewUpload(previewEmptyUpload) &&
                context.prepareStampedMeshImage(layer, candidate,
                    deliveryFlags, deliveryDomains) &&
                context.prepareUpload(mainCommitUpload, candidate);
        bool historyPrepared;
        if (ok && probe.willCommit && history !is null && gestureFactory !is null) {
            auto cmd = cast(MeshSessionEdit)gestureFactory();
            if (cmd !is null) {
                cmd.setSnapshots(pre, MeshSnapshot.capture(candidate), "Pen Polygon");
                historyPrepared = context.prepare(cmd,
                    PreparedHistoryKind.Plain).accepted;
                ok = historyPrepared;
            } else ok = context.prepareGestureCarrierMismatch();
        }
        if (ok) ok = historyPrepared ? context.markHistoryInstall()
                                     : context.markNoHistoryInstall();
        if (ok && probe.willCommit)
            ok = context.prepareUpload(mainRefreshUpload, candidate);
        if (ok) ok = context.prepareDestroy(handlerDestroy);
        auto stateOwner = ok ? PreparedPrivateStateOwner.penDeactivate(this) : null;
        if (ok) ok = context.preparePrivateState(stateOwner);
        if (ok && probe.willCommit)
            ok = context.prepareUpload(previewEmptyUpload, emptyPreview);
        if (ok && !probe.willCommit)
            ok = snapOwner !is null && context.prepareSnapClear(snapOwner);
        if (ok) ok = context.prepareDestroy(previewDestroy);
        if (!ok) context.discard();
        return PreparedDeactivateEffect(preparedToolStateOwner,
            PreparedDeactivateKind.Pen, historyPrepared, ok);
    }
    override bool prepareDoorDeactivate(PreparedRecordContext context, Layer layer,
            ulong threadIdentity, ulong contextIdentity) {
        auto commitUpload = new GpuUploadOwner(gpu, threadIdentity, contextIdentity);
        auto refreshUpload = new GpuUploadOwner(gpu, threadIdentity, contextIdentity);
        auto emptyUpload = new GpuUploadOwner(&previewGpu, threadIdentity,
            contextIdentity);
        auto destroy = new GpuResourceOwner(&previewGpu, threadIdentity,
            contextIdentity);
        auto handlers = new BoxHandlerBatchResourceOwner(vertHandlers,
            threadIdentity, contextIdentity);
        return prepareDeactivate(context, layer, commitUpload, refreshUpload,
            emptyUpload, destroy, handlers, new SnapOverlayOwner()).resourceAccepted;
    }

    override void deactivate() {
        dropStroke();
        previewGpu.destroy();
    }

    // A symmetry change during a stroke closes it, by the drop rule, on the
    // frame after the change (wave plan S6, cells A6 / A6b: the reference's
    // toggle commits the stroke) — never under a held drag (§17.1).
    override void update(ref VectorStack vts) {
        if (state != PenState.Drawing || dragArmed) return;
        auto live = liveMirror(vts);
        if (!symmetryPacketsEqual(live, mirror_)) dropStroke();
    }

    override bool onMouseButtonDown(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button == SDL_BUTTON_RIGHT) {
            if (state == PenState.Drawing) cancelPolygon();
            return true;
        }
        if (e.button != SDL_BUTTON_LEFT) return false;
        SDL_Keymod mods = SDL_GetModState();
        // Alt is reserved for camera. Ctrl / Shift slated for later
        // subphases (Shift+click new polygon, Ctrl in Make Quads).
        if (mods & KMOD_ALT) return false;
        if (mods & (KMOD_CTRL | KMOD_SHIFT)) return false;
        sessionStepBegins();   // every consumed press is one undo step

        // Double-click semantics (vibe3d convention from doc/pen_plan.md):
        // every LMB-down adds a vertex, then on the SECOND click of a
        // double-click the polygon also commits if it now has ≥3 verts.
        // We can't rely on `clicks==2` to mean "no vertex added" — SDL may
        // auto-promote clicks=1 events that arrive within the double-click
        // window (default 500 ms) to clicks=2, which would silently swallow
        // rapid normal clicks. Instead the behaviour is "always add, also
        // commit on double-click".

        if (state == PenState.Idle) {
            choosePlane(cachedVp);
            latchMirror(vts);
            Vec3 hit;
            int link;
            if (!resolvePenPoint(e.x, e.y, clickAnchor(), hit, link)) return true;
            appendVertex(hit, link);
            params_.currentPoint = cast(int)vertices_.length - 1;
            syncPosFromCurrent();
            state = PenState.Drawing;
            uploadPreview();
            armDrag(e.x, e.y);
            return true;
        }

        // 6.9.1: hit-test against existing in-progress vertices first. Press
        // on a vertex selects it as currentPoint and arms a potential drag —
        // the drag only "initiates" once the cursor moves > DRAG_THRESHOLD_PX
        // pixels (a release without motion just leaves the vertex selected).
        int hitIdx = findHoveredVert(e.x, e.y);
        if (hitIdx >= 0) {
            params_.currentPoint = hitIdx;
            syncPosFromCurrent();
            armDrag(e.x, e.y);
            return true;
        }

        // Click on empty plane.
        Vec3 hit;
        int link;
        if (!resolvePenPoint(e.x, e.y, clickAnchor(), hit, link)) return true;

        // The press adding the 3rd point decides the facing, once, from
        // (p0, p1, this click) in every arm below (wave plan §9.4); a wall
        // faces the camera by its template and writes 0 (S9, pen_wall.json D7).
        if (vertices_.length == 2)
            params_.flip = params_.wall == PenWall.off && penFacingFlip(
                toWorldP(vertices_[0]), toWorldP(vertices_[1]), toWorldP(hit), cachedVp);

        // Make Quads (wave plan S7, fixture pen_quads.json): the click, then
        // the automatic corner a = L1 + (c - L0) of the strip quad it
        // completes; the click is current. The arm always appends (an insert
        // and an odd count left by a drag weld are not captured: gap row 550;
        // there is no in-stroke pop). A typed edit does not recompute the corner
        // (row 551). The corner shares a stroke point's mirror image only
        // within the captured mirror-weld `dist`, 3 px at the focus (B5 sym is
        // an exact coincidence; C1-m4): a wider radius would move the click at
        // commit. Its scene merge and any wider radius: gap row 549.
        if (params_.makeQuads && vertices_.length >= 2) {
            const q = penStripQuad((vertices_.length - 2) / 2);
            const Vec3 corner = vertices_[q[0]] + (hit - vertices_[q[1]]);
            appendVertex(hit, link);
            float best = float.infinity;
            const image = params_.merge ? strokeImageNear(toWorldP(corner),
                3, best) : -1;
            appendVertex(corner, image >= 0 ? -2 - image : -1);
            params_.currentPoint = cast(int)vertices_.length - 2;
            syncPosFromCurrent();
            uploadPreview();
            return true;
        }

        // Default polygon mode: append at end OR insert after currentPoint
        // (the doc's "to insert a vertex between two existing ones, highlight
        // a previously created vertex and click away from it"); with merge on,
        // a press near a stroke edge inserts between its ends instead (the
        // closing edge's slot is the append), at the ordinary placed point
        // (wave plan S5 A3 block 5, pen_merge.json `edge_press`).
        int n   = cast(int)vertices_.length;
        const edge = params_.merge
            ? findHoveredStrokeEdge(e.x, e.y, SnapPacket.init.innerRangePx) : -1;
        int cur = edge >= 0 ? edge : params_.currentPoint;
        if (cur >= 0 && cur < n - 1) {
            insertVertexAfter(cur, hit, link);
            params_.currentPoint = cur + 1;
        } else {
            appendVertex(hit, link);
            params_.currentPoint = cast(int)vertices_.length - 1;
        }
        syncPosFromCurrent();
        uploadPreview();
        armDrag(e.x, e.y);
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        // A drag that is (or on this event becomes) initiated resolves its
        // point once, below; the hover resolve would be overwritten on the
        // same event (one resolve per motion; wave plan A5 s3).
        if (dragArmed && !dragInitiated) {
            int dx = e.x - dragStartMX;
            int dy = e.y - dragStartMY;
            dragInitiated = dx * dx + dy * dy >= DRAG_THRESHOLD_PX * DRAG_THRESHOLD_PX;
        }
        // Live snap preview — runs whenever a click would place / move
        // a vertex, so the user sees the cyan target before committing.
        // Skipped only when the user is hovering an existing in-progress
        // vertex (next click selects it, doesn't place a new one).
        if (!(dragArmed && dragInitiated)) {
            if (state == PenState.Drawing && findHoveredVert(e.x, e.y) >= 0) {
                lastSnap = SnapResult.init;
                clearLastSnap();
            } else {
                // Idle: the plane the first click would lock onto.
                if (state == PenState.Idle) choosePlane(cachedVp);
                Vec3 ignored;
                int ignoredLink;
                resolvePenPoint(e.x, e.y, clickAnchor(), ignored, ignoredLink);
            }
        }

        if (!dragArmed) return false;
        if (!dragInitiated) return true;   // still under threshold — consume but no-op

        // Relocate the dragged vertex to the cursor's projected plane hit; the
        // last motion decides its link (a drag away unlinks, S5 LK-break).
        if (dragVertIdx < 0 || dragVertIdx >= cast(int)vertices_.length)
            return true;
        Vec3 hit;
        int link;
        if (resolvePenPoint(e.x, e.y, dragAnchor, hit, link)) {
            vertices_[dragVertIdx] = hit;
            refreshLinks();
            // A cross mirror link stays with the dragged point (A7: the weld
            // holds); a scene link or the point's own self weld is re-decided
            // from the final position (K-C2 LK-break).
            immutable int l = links_[dragVertIdx];
            if (l > -2 || l == -2 - dragVertIdx)
                links_[dragVertIdx] = selfMirrorOr(link, hit, dragVertIdx);
            if (params_.currentPoint == dragVertIdx) syncPosFromCurrent();
            uploadPreview();
        }
        return true;
    }

    override bool onMouseButtonUp(ref const SDL_MouseButtonEvent e, ref VectorStack vts) {
        if (e.button != SDL_BUTTON_LEFT) return false;
        sessionStepEnds();     // before the return: a press arming no drag ends too
        if (!dragArmed) return false;
        scope(exit) {
            dragArmed     = false;
            dragInitiated = false;
            dragVertIdx   = -1;
        }

        if (!dragInitiated) {
            // Press-without-drag: vertex stays selected (currentPoint already
            // updated in onMouseButtonDown). Nothing more to do.
            return true;
        }

        // Drag completed — check if the dragged vertex was dropped onto
        // *another* in-progress vertex; if so, weld (drop the dragged one
        // from the boundary list, the target stays put).
        int target = findHoveredVertExcept(e.x, e.y, dragVertIdx);
        if (target >= 0) {
            weldVertex(dragVertIdx, target);
            // After weld, currentPoint should refer to the target (post-shift).
            int newCur = (target > dragVertIdx) ? (target - 1) : target;
            params_.currentPoint = newCur;
            syncPosFromCurrent();
            uploadPreview();
        }
        return true;
    }

    override bool onKeyDown(ref const SDL_KeyboardEvent e, ref VectorStack vts) {
        switch (e.keysym.sym) {
            case SDLK_RETURN:
            case SDLK_KP_ENTER:
                if (state == PenState.Drawing && vertices_.length >= minCommitVerts()) {
                    commitPolygonWithUndo();
                    return true;
                }
                // Consume Enter while pen is active even if not committable
                // (no point letting it leak to other handlers).
                return true;

            default:
                return false;
        }
    }

    override void draw(const ref Shader shader, const ref Viewport vp, ref VectorStack vts,
                       const ref DrawPlan plan, bool visualOnly = false) {
        cachedVp = vp;
        // Snap overlay (cyan element + yellow cursor marker) renders
        // even in Idle so the user sees where the FIRST vertex would
        // land if they clicked. Populated by onMouseMotion.
        drawSnapOverlay(lastSnap, vp, *mesh);
        if (state == PenState.Idle) return;

        immutable float[16] identity = identityMatrix;

        // Filled face preview (shaded). The builder emits faces only once the
        // stroke reaches its face minimum, so below it this pass draws nothing.
        if (plan.drawFaces) {
            litShader.useProgram(identity, vp);
            litShader.applyPreviewPlan(plan);
            previewGpu.drawFaces(litShader, previewFacePass(plan));
        }

        glUseProgram(shader.program);
        glUniformMatrix4fv(shader.locModel, 1, GL_FALSE, identity.ptr);
        glUniformMatrix4fv(shader.locView,  1, GL_FALSE, vp.view.ptr);
        glUniformMatrix4fv(shader.locProj,  1, GL_FALSE, vp.proj.ptr);

        // Wireframe preview — shows the open polyline before the first
        // face is closed, and the boundary edges of the in-progress face(s)
        // afterwards (drawn on top of the lit fill).
        if (vertices_.length >= 2)
            previewGpu.drawEdges(shader.locColor, -1, MarkView.init);

        // Vertex markers — three-state colour, by BoxHandler.draw precedence
        // from the arbiter-assigned HandleState:
        //   Rollover  → yellow (single hot part, set by ToolHandles.update)
        //   selected (not hot) → orange — used for the current point
        //   default → cyan
        // Single-source hover (Test pass): register every vertex
        // marker, resolve ONE hot part so overlapping markers can't both
        // highlight. A live vertex drag (dragArmed) keeps its marker hot.
        toolHandles.begin();
        foreach (i, h; vertHandlers) {
            h.size = gizmoSize(h.pos, vp, 0.04f);
            toolHandles.add(h, cast(int)i);
        }
        toolHandles.setHaul(dragArmed ? dragVertIdx : -1);
        int hmx, hmy;
        queryMouse(hmx, hmy);
        toolHandles.update(hmx, hmy, vp);
        foreach (i, h; vertHandlers) {
            h.selected = (cast(int)i == params_.currentPoint);
            h.draw(shader, vp);
        }
    }

    override void drawProperties() {
        import ImGui = d_imgui;
        if (state == PenState.Idle)
            ImGui.TextDisabled("Click in viewport to start a polygon.");
        else
            ImGui.TextDisabled("Click to add vertices • Enter / dbl-click to close • Ctrl+Z undoes the last action • RMB to cancel");
    }

private:
    // Storage frame = the create family's placement frame: the identity under
    // the automatic plane, so stroke positions (and posX/Y/Z) are world (§10).
    // The plane normal is the local axis the camera faces most.
    void choosePlane(const ref Viewport vp) {
        frame = primitivePlacementFrame();
        Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
        int axis = mostFacingAxis(camBack, frame.axis1, frame.normal, frame.axis2);
        planeNormal = Vec3(axis == 0 ? 1 : 0, axis == 1 ? 1 : 0, axis == 2 ? 1 : 0);
        wallNormal = normalize(transformDir(frame.toWorld, planeNormal));
        if (dot(wallNormal, eyeVectorAt(vp, vp.focus)) > 0) wallNormal = -wallNormal;
    }

    // The live symmetry without its per-vertex pairing (the builder reads the
    // plane only); off when the stage publishes none.
    static SymmetryPacket liveMirror(ref VectorStack vts) {
        auto sp = vts.get!SymmetryPacket();
        return sp is null ? SymmetryPacket.init : penMirror(*sp);
    }
    // The stroke's mirror, latched at its first click (after `choosePlane`):
    // under the work plane the captured double transform of the STAGE's axis
    // (the packet's reads -1 there; a published packet implies the stage),
    // wave plan S6.
    void latchMirror(ref VectorStack vts) {
        mirror_ = liveMirror(vts);
        if (mirror_.enabled && mirror_.useWorkplane)
            penWorkplaneMirrorPlane(liveSymmetryStage().axisIndex, mirror_.offset,
                                    frame, mirror_.planePoint, mirror_.planeNormal);
    }

    // Where a click lands (wave plan S3a / S3c, tests/fixtures/pen_placement.json
    // `cells` / `plane_rule`): on the plane through the CURRENT point, the new
    // point going right after it (append = the current point is the last); the
    // first point on the view's work plane through the plane-local focus, in
    // perspective rounded as relocate's plane origin is (`niceOrigin`: every
    // channel to the sub-step, the normal channel to ten grid steps). The
    // anchor is vector-snapped, so a click's plane-normal channel is quantised;
    // a drag anchors on the raw point and a typed value is never rounded.
    Vec3 clickAnchor() const {
        immutable float q = placementQuantum();
        if (vertices_.length == 0) {
            Vec3 f = toLocalP(cachedVp.focus);
            if (!isOrtho(cachedVp))
                f = niceOrigin(f, planeAxis(),
                               relocateQuantum(viewWorldPerPixel(cachedVp), g_viewGrid), q);
            return vectorSnap(f, q);
        }
        int cur = params_.currentPoint;
        return vectorSnap(cur >= 0 && cur < cast(int)vertices_.length ? vertices_[cur]
                                                                     : vertices_[$ - 1], q);
    }

    // The view's vector-snap step (the grid sub-step) and the plane normal's
    // axis index, read by the click anchor and the resolver.
    float placementQuantum() const {
        immutable float px = viewWorldPerPixel(cachedVp);
        return viewGridSubStep(px, viewGridSize(px, g_viewGrid), g_viewGrid);
    }
    int planeAxis() const { return planeNormal.x != 0 ? 0 : (planeNormal.y != 0 ? 1 : 2); }

    // The one place a pixel becomes a stroke point (click, hover, drag): the
    // locked plane through `anchor`, its two in-plane channels rounded to the
    // view's grid sub-step (the vector snap relocate and extrude use; wave
    // plan S3q, fixture pen_placement.json `quantum`), then a discrete snap
    // (an edge snap takes the QUANTISED point's foot on the edge, S5 Q-edge),
    // then the pen guides when no discrete target won (guideBits are the
    // pen's own), then the merge from the placed point; `link` is the
    // edited-mesh vertex the point shares, or -1.
    bool resolvePenPoint(int x, int y, Vec3 anchor, out Vec3 local, out int link) {
        link = -1;
        if (!workplaneCursorPlaneHit(frame, cachedVp, cast(float)x,
                                     cast(float)y, anchor, planeNormal, local)) {
            lastSnap = SnapResult.init;
            clearLastSnap();
            return false;
        }
        immutable int k = planeAxis();
        local = withAxisComp(vectorSnap(local, placementQuantum()), k, axisComp(local, k));
        immutable Vec3 quantised = local;
        lastSnap = snapLocalHit(local, frame, x, y, cachedVp,
                                *mesh, EditMode.Vertices, [], guideBits);
        if (elementPlaced() && lastSnap.targetType == SnapType.Edge)
            local = toLocalP(pointOnEdgeUnder(toWorldP(quantised), lastSnap.targetIndex));
        if (!discretePlaced()) applyPenGuide(local, x, y);
        if (params_.merge) link = mergeTarget(local);
        publishLastSnap(lastSnap);
        return true;
    }

    // A discrete snap target (not a constraint) placed the point; the guide
    // gate and the merge read this one spelling.
    bool discretePlaced() const {
        return lastSnap.snapped && lastSnap.constraintType == SnapType.None;
    }
    // ... and it was an element of the edited mesh: the merge's small radii.
    bool elementPlaced() const {
        return discretePlaced() && lastSnap.targetSource == 0 &&
            (lastSnap.targetType & kElementSnapBits) != 0;
    }

    // The merge (wave plan S5; fixture pen_merge.json): ONE search from the
    // PLACED point, after the snap, never part of its election. Screen radii
    // (one value per view): 24 px over the edited mesh's vertices and edges;
    // after an element snap the snapped edge's own ends within 17.5 px, else
    // any vertex within 2.85 px. Vertices and edges are asked in two
    // single-class queries (so the election's vertex veto never runs) and the
    // snap cascade's comparator picks between them: the vertex wins unless it
    // trails the edge by its 16 px tolerance (cells_k_b8, snap_off_isolated_v10).
    // A vertex hit moves the point onto it and is returned (the point shares
    // it); an edge hit moves the point onto the edge as its own vertex.
    // `snapCursor` takes an integer pixel, so it is the broad phase (r + 1)
    // and the float distance decides.
    static immutable SnapType[2] kMergeTypes = [SnapType.Vertex, SnapType.Edge];
    int mergeTarget(ref Vec3 local) {
        immutable Vec3 placed = toWorldP(local);
        float fx, fy, ndcZ;
        if (!projectToWindowFull(placed, cachedVp, fx, fy, ndcZ)) return -1;
        float pxFrom(Vec3 w) {
            float x, y, z;
            return projectToWindowFull(w, cachedVp, x, y, z)
                ? Vec3(x - fx, y - fy, 0).length : float.infinity;
        }
        immutable ms = primaryModelSpace();
        immutable bool small = elementPlaced();
        if (small && lastSnap.targetType == SnapType.Edge) {
            int end = -1;
            float best = kMergeSnappedEdgeEndPx;
            foreach (v; mesh.edges[lastSnap.targetIndex]) {
                immutable d = pxFrom(ms.toWorldPoint(mesh.vertices[v]));
                if (d <= best) { best = d; end = cast(int)v; }
            }
            if (end >= 0) {
                local = toLocalP(ms.toWorldPoint(mesh.vertices[end]));
                return end;
            }
        }
        immutable float r = small ? kMergeAfterSnapPx : SnapPacket.init.innerRangePx;
        SnapPacket pkt;
        pkt.enabled = true;
        pkt.innerRangePx = r + 1;
        SnapResult[2] hit;
        bool[3] has;
        float[3] d = kAbsentClassDist;
        foreach (i, t; kMergeTypes[0 .. small ? 1 : 2]) {
            pkt.enabledTypes = t;
            hit[i] = snapCursor(placed, cast(int)lround(fx), cast(int)lround(fy),
                cachedVp, *mesh, ms, pkt, null, (SnapType, int, int slot) => slot == 0);
            immutable px = hit[i].snapped ? pxFrom(hit[i].worldPos) : float.infinity;
            if (px <= r) { has[i] = true; d[i] = px; }
        }
        // The stroke's own mirror images are vertex candidates too, the scene
        // winning a tie (wave plan S6, B3 / A7).
        immutable int image = strokeImageNear(placed, r, d[kCascadeVertex]);
        if (image >= 0) has[kCascadeVertex] = true;
        immutable float tol = kVertexToleranceScale * fmin(r, kCandidateToleranceBasePx);
        if (cascadeClassWins(kCascadeVertex, has, d, tol)) {
            if (image >= 0) {
                local = toLocalP(mirrorPosition(mirror_, toWorldP(vertices_[image])));
                return -2 - image;
            }
            local = toLocalP(hit[kCascadeVertex].worldPos);
            return hit[kCascadeVertex].targetIndex;
        }
        if (has[kCascadeEdge])
            local = toLocalP(pointOnEdgeUnder(placed, hit[kCascadeEdge].targetIndex));
        return -1;
    }

    // The stroke point whose mirror image lies within `r` px of world point
    // `placed`, nearer than `best` (lowered to its distance); -1 if none. A
    // dragged point skips its own image.
    int strokeImageNear(Vec3 placed, float r, ref float best) const {
        float fx, fy, x, y, z;
        if (!mirror_.enabled || !projectToWindowFull(placed, cachedVp, fx, fy, z))
            return -1;
        int image = -1;
        foreach (j, v; vertices_) {
            if (dragInitiated && j == dragVertIdx) continue;
            if (!projectToWindowFull(mirrorPosition(mirror_, toWorldP(v)), cachedVp, x, y, z))
                continue;
            immutable px = Vec3(x - fx, y - fy, 0).length;
            if (px <= r && px < best) { best = px; image = cast(int)j; }
        }
        return image;
    }

    // The point of edited-mesh edge `edge` under world point `p`: the edge's
    // closest approach to the line through `p` along the view direction.
    Vec3 pointOnEdgeUnder(Vec3 p, int edge) const {
        assert(edge >= 0 && edge < cast(int)mesh.edges.length, "pen: edge index");
        immutable ms = primaryModelSpace();
        immutable Vec3 a = ms.toWorldPoint(mesh.vertices[mesh.edges[edge][0]]);
        immutable Vec3 b = ms.toWorldPoint(mesh.vertices[mesh.edges[edge][1]]);
        float t;
        closestOnSegmentToRay(p, eyeVectorAt(cachedVp, p), a, b, t);
        return a + (b - a) * t;
    }

    // ---- Local ↔ world helpers (workplane refactor) ---------------------
    /// The cursor ray at pixel (x, y) in LOCAL coords. Ortho-aware — see
    /// `create_common.workplaneCursorRay`. The old `localEye()`/`localRay()`
    /// pair this replaces was the perspective law (one apex, fanning
    /// direction) and produced hits scaled by the camera distance in an ortho
    /// cell (task 0661).
    void localCursor(int x, int y, out Vec3 org, out Vec3 dir) const {
        workplaneCursorRay(frame, cachedVp, cast(float)x, cast(float)y, org, dir);
    }
    Vec3 toWorldP(Vec3 p) const { return transformPoint(frame.toWorld, p); }
    Vec3 toLocalP(Vec3 p) const { return transformPoint(frame.toLocal, p); }

    // `link`: the edited-mesh vertex the point shares, or -1 (resolvePenPoint).
    void appendVertex(Vec3 pos, int link) {
        // pos is in LOCAL workplane coords; the vertex handler renders in
        // world, so hit-testing needs the world image of `pos`.
        refreshLinks();
        links_ ~= selfMirrorOr(link, pos, vertices_.length);
        vertices_ ~= pos;
        vertHandlers ~= vertMarker(pos);
    }

    // Rule 2 of the merge (wave plan S5 / S6, C1-m4): a placed point within
    // half the merge distance of the latched mirror plane, 2|d| < 3 px of world
    // at the focus, is its own mirror (link -2 - i for stroke index `i`). With
    // the latch off `mirror_` is `.init` (plane x = 0), so the enabled term is
    // live: without it a point near x = 0 self-welds and a drag cannot weld it
    // to the scene. A point holds one link: the scene's first.
    int selfMirrorOr(int link, Vec3 local, size_t i) const {
        if (link != -1 || !params_.merge || !mirror_.enabled) return link;
        immutable float gap = 2 * abs(dot(toWorldP(local) - mirror_.planePoint,
                                          mirror_.planeNormal));
        return gap < 3 * viewWorldPerPixel(cachedVp) ? -2 - cast(int)i : -1;
    }
    // A point inserted at `at` (delta +1) or removed from it (-1) renumbers the
    // mirror links (<= -2 name point -2 - l; any other l gives -2 - l < 0 <= at
    // and stays); a link to a removed point drops.
    static int shiftedLink(int l, int at, int delta) nothrow @nogc {
        if (-2 - l < at) return l;
        return delta < 0 && -2 - l == at ? -1 : l - delta;
    }

    // Empties every per-point stroke array together (the one reset site: an
    // array added beside `vertices_` / `links_` is cleared here once).
    void clearStroke() nothrow @nogc { vertices_.length = 0; links_.length = 0; }

    // One cyan marker for a LOCAL stroke point (markers render in WORLD).
    BoxHandler vertMarker(Vec3 pos) {
        Vec3 worldPos = toWorldP(pos);
        auto h = new BoxHandler(worldPos, schemeColor(SchemeColor.handle));
        h.size = gizmoSize(worldPos, cachedVp, 0.04f);
        return h;
    }

    // Insert a new vertex (and matching handler) at position insertIdx in the
    // boundary list, shifting later elements right. Used by the "click-away
    // while a vertex is current" path to splice into the polygon.
    void insertVertexAfter(int afterIdx, Vec3 pos, int link) {
        // pos in LOCAL; handler in WORLD.
        int insertIdx = afterIdx + 1;
        if (insertIdx < 0) insertIdx = 0;
        if (insertIdx > cast(int)vertices_.length) insertIdx = cast(int)vertices_.length;
        refreshLinks();
        foreach (ref l; links_) l = shiftedLink(l, insertIdx, 1);
        links_ = links_[0 .. insertIdx] ~
            selfMirrorOr(shiftedLink(link, insertIdx, 1), pos, insertIdx) ~
            links_[insertIdx .. $];
        vertices_ = vertices_[0 .. insertIdx] ~ pos ~ vertices_[insertIdx .. $];
        vertHandlers = vertHandlers[0 .. insertIdx] ~ vertMarker(pos)
            ~ vertHandlers[insertIdx .. $];
    }

    void clearVertHandlers() {
        foreach (h; vertHandlers) h.destroy();
        vertHandlers.length = 0;
    }

    // ----- History-coordination hooks (undo/redo migration P0) -------------
    // A pending sequence is drop-committable once it forms an edge; this same
    // predicate also hides the live edge overlay. Task 5911; fixture P1/P2/P3.
    public override bool hasUncommittedEdit() const {
        return state == PenState.Drawing && vertices_.length >= minDropCommitVerts();
    }

    // H7 (slice M6): the flags table sets the rollover flag on this tool; it
    // picks no hover type yet (`wantsHoverForType`), so nothing is drawn.
    public override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        // A UI command mid-stroke commits the stroke (from the drop minimum)
        // or ends it below, and the pen stays (wave plan S8: BD-sel, UC-close,
        // UC1-end).
        static immutable ToolSessionPolicy policy = {
            commandClose: CommandClose.uiDoor, commandEndsOpenGesture: true,
            rollovers: Rollover.target, sessionSteps: true,
            imageAttrs: ["type", "currentPoint", "posX", "posY", "posZ", "flip",
                         "makeQuads", "merge", "close", "selectNew", "wall",
                         "offset", "points", "link", "linkKey"] };
        return policy;
    }
    // In-stroke undo / redo (fixture pen_instroke_undo.json): the
    // session restores the image before the last press, typed field or flag
    // write; the stroke is re-derived from it — never re-decided (flip).
    public override void rebuildPreviewFromAttrs() {
        state = vertices_.length ? PenState.Drawing : PenState.Idle;
        clearVertHandlers();
        foreach (v; vertices_) vertHandlers ~= vertMarker(v);
        uploadPreview();
    }
    // Cancel: drop the in-progress sequence (cancelPolygon resets state + clears
    // the preview / vert handlers, records nothing). An idle pen is left alone:
    // its session's in-stroke redo survives (wave plan S8 A4-rev).
    public override void cancelUncommittedEdit() {
        if (state == PenState.Drawing) cancelPolygon();
    }
    // The close before a UI command commits the stroke as the drop does. Not
    // `commitUncommittedEdit`: apply-and-continue (Shift+LMB) also reads that.
    public override bool commitOperation() { return commitPolygonWithUndo(); }

    // Links are edited-mesh indices, valid only on the mesh they were made on
    // (any undo door, a reset, a Marks bump may move it under a live stroke).
    // Each link WRITER refreshes first: a changed mesh drops every older link
    // (its point becomes its own vertex) and re-stamps, so the new link, just
    // resolved on the live mesh, is valid. Readers take `liveLinks`. Pen wave
    // plan A5 F2 (§24.4, §25.1 #1); not captured — gap row.
    void refreshLinks() {
        if (keyLive(strokeKey_, *mesh)) return;
        links_ = withoutSceneLinks(links_);
        SessionMeshKey k;
        k.stamp(*mesh);
        strokeKey_ = [k];
    }
    const(int)[] liveLinks() const { return linksUnder(strokeKey_, links_, *mesh); }
    static const(int)[] linksUnder(const(SessionMeshKey)[] key, const(int)[] links,
                                   ref const Mesh m) {
        return keyLive(key, m) ? links : withoutSceneLinks(links);
    }
    // `links` with every edited-mesh link dropped (mirror links kept): the
    // links a mesh without the scene's vertices (a preview) can take.
    static int[] withoutSceneLinks(const(int)[] links) {
        auto r = links.dup;
        foreach (ref l; r) if (l >= 0) l = -1;
        return r;
    }
    static bool keyLive(const(SessionMeshKey)[] key, ref const Mesh m) {
        return key.length == 1 && key[0].matches(m);
    }

    // The drop rule: a stroke that forms an edge commits, any other is cancelled.
    void dropStroke() {
        if (state == PenState.Drawing && vertices_.length >= minDropCommitVerts())
            commitPolygonWithUndo();
        else
            cancelPolygon();
    }

    void cancelPolygon() {
        clearVertHandlers();
        clearStroke();
        previewMesh.clear();
        // No upload needed: draw() short-circuits when state == Idle, so the
        // stale GPU buffers are simply not rendered until the next Drawing
        // session re-uploads.
        state = PenState.Idle;
        params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
        // Drop the snap overlay so it doesn't linger.
        lastSnap = SnapResult.init;
        clearLastSnap();
        sessionOperationEnded();
    }

    // Mirror vertices_[currentPoint] into the params_.posX/Y/Z fields so the
    // property panel reflects the live vertex position. Called whenever
    // currentPoint changes or the buffered vertex is moved.
    void syncPosFromCurrent() {
        int idx = params_.currentPoint;
        if (idx < 0 || idx >= cast(int)vertices_.length) {
            params_.posX = params_.posY = params_.posZ = 0.0f;
            return;
        }
        Vec3 p = vertices_[idx];
        params_.posX = p.x;
        params_.posY = p.y;
        params_.posZ = p.z;
    }

    // Arm a drag on the current point (just pressed, appended or inserted)
    // so motion-while-LMB-held relocates it on the plane through its pre-drag
    // position and LMB-up finalises (with optional weld). A pure click (LMB-up
    // without motion past DRAG_THRESHOLD_PX) leaves the point where it is.
    void armDrag(int mx, int my) {
        dragArmed     = true;
        dragInitiated = false;
        dragVertIdx   = params_.currentPoint;
        dragAnchor    = vertices_[dragVertIdx];
        dragStartMX   = mx;
        dragStartMY   = my;
    }

    // Hit-test in-progress vertex markers; returns the index of the first
    // marker whose screen-space bounding cube contains (mx, my), or -1.
    int findHoveredVert(int mx, int my) {
        foreach (i, h; vertHandlers) {
            if (h.hitTest(mx, my, cachedVp)) return cast(int)i;
        }
        return -1;
    }

    // The stroke edge (i, i + 1) — from three points also the closing edge
    // (n − 1, 0) — nearest the pointer in screen space within `r` px: its
    // first index i, or -1.
    int findHoveredStrokeEdge(int mx, int my, float r) {
        immutable size_t n = vertices_.length;
        int best = -1;
        foreach (i; 0 .. (n < 2 ? 0 : n == 2 ? 1 : n)) {
            float ax, ay, bx, by, z;
            if (!projectToWindowFull(toWorldP(vertices_[i]), cachedVp, ax, ay, z) ||
                !projectToWindowFull(toWorldP(vertices_[(i + 1) % n]), cachedVp, bx, by, z))
                continue;
            const Vec3 ab = Vec3(bx - ax, by - ay, 0), ap = Vec3(mx - ax, my - ay, 0);
            const float len2 = dot(ab, ab);
            float t = len2 > 0 ? dot(ap, ab) / len2 : 0;
            t = t < 0 ? 0 : t > 1 ? 1 : t;
            const float d = (ap - ab * t).length;
            if (d <= r) { r = d; best = cast(int)i; }
        }
        return best;
    }

    int findHoveredVertExcept(int mx, int my, int exclude) {
        foreach (i, h; vertHandlers) {
            if (cast(int)i == exclude) continue;
            if (h.hitTest(mx, my, cachedVp)) return cast(int)i;
        }
        return -1;
    }

    // Weld the dragged vertex (dragIdx) onto target. The dragged vertex
    // drops out of the boundary list entirely; the target's position stays
    // put (the user might have positioned it earlier and the weld shouldn't
    // teleport it). Boundary indices after dragIdx shift left by one.
    void weldVertex(int dragIdx, int targetIdx) {
        if (dragIdx < 0 || dragIdx >= cast(int)vertices_.length) return;
        if (targetIdx == dragIdx) return;
        vertHandlers[dragIdx].destroy();
        vertices_    = vertices_[0 .. dragIdx]    ~ vertices_[dragIdx + 1 .. $];
        links_       = links_[0 .. dragIdx]       ~ links_[dragIdx + 1 .. $];
        vertHandlers = vertHandlers[0 .. dragIdx] ~ vertHandlers[dragIdx + 1 .. $];
        foreach (ref l; links_) l = shiftedLink(l, dragIdx, -1);
    }

    void uploadPreview() {
        assert(vertHandlers.length == vertices_.length &&
            links_.length == vertices_.length,
            "pen: one marker and one link per stroke point");
        previewMesh.clear();
        appendPenGeometry(previewMesh, PenStroke.of(vertices_, frame.toWorld,
            params_, withoutSceneLinks(links_), mirror_, wallNormal: wallNormal),
            PenBuildPurpose.Preview);
        previewGpu.upload(previewMesh);
        // Keep marker positions in sync (vertices_ may have been mutated by
        // a drag or a typed edit). Handlers render in WORLD.
        foreach (i, ref h; vertHandlers) h.pos = toWorldP(vertices_[i]);
    }

    // Minimum point count for Enter / a tool drop, per type (pen_geometry).
    size_t minCommitVerts() const { return penEnterMinimum(params_); }
    size_t minDropCommitVerts() const { return penDropMinimum(params_); }

    // Apply Pen-local guide constraints: straightLine / worldAxis / rightAngle.
    //
    // Anchor = prior vertex (vertices_[$-1]), direction from the prior segment
    // for straightLine/rightAngle, world X/Y/Z through the prior vertex for
    // worldAxis (Pen-scoped, differs from snap.d's origin-based WorldAxis).
    //
    // All arithmetic in LOCAL workplane coordinates. Candidates are projected
    // to screen pixels to gate against cfg.innerRangePx. The nearest in-range
    // candidate wins; ties between guide types resolved by screen distance.
    //
    // Returns true and writes hitLocal to the guide point when a candidate is
    // within tolerance; returns false (hitLocal unchanged) otherwise.
    // Stateless beyond vertices_ / frame / cachedVp — no new persistent fields.
    private bool applyPenGuide(ref Vec3 hitLocal, int sx, int sy) {
        if (vertices_.length < 1) return false;

        auto cfg = currentSnapPacket(*mesh, EditMode.Vertices, cachedVp);
        if (!cfg.enabled) return false;

        Vec3  anchorL  = vertices_[$-1];
        float bestDist = cfg.innerRangePx;
        bool  found    = false;
        Vec3  bestP;

        // The cursor ray, built ONCE and ortho-aware. Every guide below is a
        // closest-approach between a local guide LINE and this ray, so an
        // ortho cell that handed them the perspective pencil put the guide
        // point at the wrong place along the line (task 0661).
        Vec3 curO, curD;
        localCursor(sx, sy, curO, curD);

        // Project a LOCAL candidate point to screen; return pixel distance to
        // (sx,sy). Returns float.infinity for behind-camera points.
        float screenDist(Vec3 pL) {
            Vec3  pW = toWorldP(pL);
            float px_, py_, ndcZ;
            if (!projectToWindowFull(pW, cachedVp, px_, py_, ndcZ))
                return float.infinity;
            float dx = px_ - cast(float)sx;
            float dy = py_ - cast(float)sy;
            return Vec3(dx, dy, 0).length;   // Vec3.length uses std.math.sqrt
        }

        void consider(Vec3 candL) {
            float d = screenDist(candL);
            if (d < bestDist) { bestDist = d; bestP = candL; found = true; }
        }

        // Segment direction in LOCAL (shared by straightLine + rightAngle).
        // Computed only when needed and guarded against degenerate segments
        // (nit 1: normalize has no zero-guard, a zero-length segment poisons
        // both candidate directions via NaN).
        Vec3 segL;
        bool segValid = false;
        if ((cfg.enabledTypes & (SnapType.StraightLine | SnapType.RightAngle))
                && vertices_.length >= 2)
        {
            Vec3 segVec = vertices_[$-1] - vertices_[$-2];
            if (segVec.length > 1e-6f) {
                segL     = normalize(segVec);
                segValid = true;
            }
        }

        // straightLine: lock new point to the infinite extension of the prior
        // segment (anchor = prior vertex, dir = prior-segment direction).
        // Requires ≥2 prior vertices.
        if ((cfg.enabledTypes & SnapType.StraightLine) && segValid)
            consider(closestPointOnLineToRay(anchorL, segL,
                                              curO, curD));

        // worldAxis (Pen-scoped): X/Y/Z axes through the PRIOR vertex.
        // Requires only ≥1 prior vertex (anchorL already set).
        // The in-plane filter drops any world axis nearly parallel to the
        // construction-plane normal (planeNormal, in LOCAL frame coords):
        // snapping to it would move the vertex off the plane, which is never
        // useful in Pen mode.  planeNormal is (1,0,0)/(0,1,0)/(0,0,1) in
        // local space depending on which frame axis choosePlane found most
        // face-on to the camera — it is NOT always local-Y.
        if (cfg.enabledTypes & SnapType.WorldAxis) {
            immutable Vec3[3] worldAxes = [Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)];
            foreach (ax; worldAxes) {
                Vec3 axL = transformDir(frame.toLocal, ax);
                if (abs(dot(axL, planeNormal)) > 0.9f) continue;   // skip the plane-normal axis
                consider(closestPointOnLineToRay(anchorL, axL,
                                                  curO, curD));
            }
        }

        // rightAngle: perpendicular to the prior segment, in the construction
        // plane. Direction = cross(planeNormal, segL) — both in LOCAL, result
        // also in LOCAL. A single infinite LINE covers both ±90° senses.
        // Requires ≥2 prior vertices.
        if ((cfg.enabledTypes & SnapType.RightAngle) && segValid) {
            Vec3 perpL = cross(planeNormal, segL);
            if (perpL.length > 1e-6f) {
                perpL = normalize(perpL);
                consider(closestPointOnLineToRay(anchorL, perpL,
                                                  curO, curD));
            }
        }

        if (found) { hitLocal = bestP; return true; }
        return false;
    }

    bool commitPolygonWithUndo() {
        if (state != PenState.Drawing || vertices_.length < minDropCommitVerts()) return false;
        MeshSnapshot pre = MeshSnapshot.capture(*mesh);
        commitPolygon();
        if (history !is null && gestureFactory !is null && pre.filled) {
            auto cmd = cast(MeshSessionEdit) gestureFactory();
            if (cmd is null) noteGestureCarrierMismatch();
            else {
                auto post = MeshSnapshot.capture(*mesh);
                cmd.setSnapshots(pre, post, "Pen Polygon");
                recordGestureEdit(cmd, GestureRecordMode.Plain);
            }
        }
        // Refresh selection/picking caches so the new face is hover-pickable
        // and selection arrays match the grown geometry.
        mesh.syncSelection();
        refreshDisplay(mesh, gpu);
        // Drop in-progress state — tool stays active for the next polygon.
        state = PenState.Idle;
        clearVertHandlers();
        clearStroke();
        previewMesh.clear();
        previewGpu.upload(previewMesh);
        params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
        meshChanged = true;
        sessionOperationEnded();   // the stroke's steps end with its one row
        return true;
    }

    void commitPolygon() {
        // A pure tail append into the live scene mesh, declared as such for
        // the corner-append cross-check.
        appendPenGeometry(*mesh, PenStroke.of(vertices_, frame.toWorld,
            params_, liveLinks(), mirror_, selMode(), wallNormal), PenBuildPurpose.Commit);
        mesh.declareCornerAppend();
        mesh.buildLoops();
        gpu.upload(*mesh);
    }
}
