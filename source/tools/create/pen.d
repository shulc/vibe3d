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
import toolpipe.packets : SnapType;
import editmode : EditMode;
import snap : SnapResult;
import snap_render : drawSnapOverlay, publishLastSnap, clearLastSnap;
import tools.transform.relocate_plane : vectorSnap, withAxisComp, axisComp;
import viewgrid : g_viewGrid, viewWorldPerPixel, viewGridSize, viewGridSubStep;

import std.math : abs;
// The one stroke builder and the pen's param schema (PenParams, PenStroke).
import tools.create.pen_geometry;
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

version(unittest) unittest {
    import record_observer_hub : RecordObserverHub;
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
        uiDepth == 0 && commitPen.state == PenState.Idle &&
        commitPen.vertices_.length == 0 && commitPen.vertHandlers.length == 0 &&
        commitPen.params_.currentPoint == -1 && commitPen.meshChanged &&
        commitContext.installTraceForTest() == [3,4,2,1,2,2,7,2,2]);

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
    assert(positionPen.vertices_[1] == Vec3(2,3,4) &&
        positionPen.previewMesh.vertices == positionPen.vertices_ &&
        positionContext.installTraceForTest() == [7,2,8]);
    assert(positionPen.params_.flip, "a prepared Position edit re-decided flip");

    auto stalePen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    stalePen.state = PenState.Drawing; stalePen.vertices_ = [Vec3(1,1,1)];
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
    // install. Strip [0,1,2,3] → quad [1,3,2,0] (flip off).
    auto quadPen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    quadPen.state = PenState.Drawing;
    quadPen.frame.toWorld = [1,0,0,0, 0,1,0,0, 0,0,1,0, 10,20,30,1];
    quadPen.vertices_ = [Vec3(0,0,0), Vec3(0,1,0), Vec3(1,0,0), Vec3(1,1,0)];
    quadPen.params_.makeQuads = true;     // the panel writes before the hook
    auto quadImage = quadPen.buildPreparedParamImage("makeQuads");
    assert(quadImage.kind == PreparedPenParamKind.Preview && quadImage.upload,
        "makeQuads edit must prepare a preview rebuild");
    assert(quadImage.nextPreview.faces.length == 1 &&
        quadImage.nextPreview.faces[0] == [1u, 3, 2, 0],
        "makeQuads preview is not the builder's strip quad");
    assert(quadPen.buildPreparedParamImage("flip").kind ==
        PreparedPenParamKind.Preview, "flip edit must prepare a preview rebuild");
    auto quadContext = new PreparedRecordContext(null, new RecordObserverHub());
    quadContext.setResourceIdentity(7, 11);
    auto quadEffect = quadPen.prepareParamChanged(quadContext, "makeQuads",
        GpuUploadOwner.fakeForTest(quadPen.preparedPreviewGpu()));
    assert(quadEffect.accepted && quadEffect.kind == PreparedPenParamKind.Preview
        && quadPen.previewMesh.vertices.length == 0 && quadContext.validate(),
        "makeQuads preparation refused or touched the live preview");
    quadContext.install();
    assert(quadPen.previewMesh.faces == [[1u, 3, 2, 0]] &&
        quadPen.vertices_.length == 4 && quadContext.installTraceForTest() ==
        [7,2,8], "makeQuads install did not land the rebuilt preview");

    // The legacy hook (scripted `tool.attr`) rebuilds the same preview. The
    // suppressed cage upload stands in for GL, which the module gate lacks.
    auto hookPen = new PenTool(() => &mesh, &sceneGpu, LitShader.init);
    hookPen.state = PenState.Drawing; hookPen.previewGpu.suppressCageUpload = true;
    hookPen.frame.toWorld = quadPen.frame.toWorld;
    hookPen.vertices_ = quadPen.vertices_.dup;
    foreach (v; hookPen.vertices_) hookPen.vertHandlers ~= hookPen.vertMarker(v);
    hookPen.onParamChanged("flip");
    assert(hookPen.previewMesh.faces == [[1u, 2, 3, 0]],
        "legacy flip hook did not rebuild the preview (penRingOrder ring)");
    hookPen.params_.makeQuads = true; hookPen.onParamChanged("makeQuads");
    assert(hookPen.previewMesh.faces == [[1u, 3, 2, 0]],
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
    assert(dropFace(quadPen.vertices_.dup, false, true, null) == [1u, 3, 2, 0],
        "drop ignored the image's makeQuads");
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
//   Drawing ── double-click / Enter ─→ commit a face from 3+ points; Idle
//   Drawing ── Backspace ─→ pop last vertex; ─→ Idle if buffer empties
//   Drawing ── tool drop (n ≥ 2) ─→ commit; back to Idle
//   Drawing ── Ctrl+Z (n ≥ 2) ─→ cancel points and drop tool; back to Idle
//   Drawing ── Ctrl+Z (n = 1) ─→ undo the entry below; keep stroke and tool
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
    Mesh previewClear;
    float[16] toWorld;
    size_t expectedHandlerCount;
    SnapResult expectedLastSnap;
    bool expectedMeshChanged;
    void clear() nothrow @nogc {
        vertices = null; previewClear = Mesh.init;
        this = PreparedPenDeactivateImage.init;
    }
}

struct PreparedPenParamImage {
    bool valid, upload;
    PreparedPenParamKind kind;
    ubyte expectedState;
    PenParams expectedParams, nextParams;
    Vec3[] expectedVertices, nextVertices;
    BoxHandler[] expectedHandlers;
    Vec3[] expectedHandlerPositions, nextHandlerPositions;
    float[16] expectedToWorld;
    MeshSnapshot expectedPreview;
    Mesh nextPreview;
    void clear() nothrow @nogc {
        expectedVertices = nextVertices = null;
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
    GpuMesh*         gpu;
    LitShader        litShader;


    PenParams        params_;

    PenState         state;
    Vec3[]           vertices_;     // LOCAL workplane positions of the in-progress sequence
    BoxHandler[]     vertHandlers;  // one cyan marker per in-progress vertex (handler.pos in WORLD)
    ToolHandles      toolHandles;   // single-source hover arbiter (Test pass)

    Mesh             previewMesh;
    GpuMesh          previewGpu;

    // The stroke's plane normal, a LOCAL axis of `frame`, locked per stroke.
    Vec3 planeNormal;
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
    this(Mesh* delegate() meshSrc, GpuMesh* gpu, LitShader litShader) {
        this.meshSrc_ = meshSrc;
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
                [IntEnumEntry(0, "polygons", "Polygons")],
                0),
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
            // The stroke itself, for the session's undo image (hidden,
            // transient, refused on every wire door).
            Param.podArray_("points", "Points", &vertices_),
        ];
    }

    override bool paramEnabled(string name) const {
        if (name == "currentPoint" || name == "posX" || name == "posY" || name == "posZ")
            return state == PenState.Drawing && vertices_.length > 0;
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
            uploadPreview();
            return;
        }
        if (rebuildsPreview(name)) uploadPreview();
    }

    // Params that change the stroke's shape but not its points: an edit
    // mid-stroke rebuilds the preview (legacy hook and prepared door alike).
    private static bool rebuildsPreview(string name) nothrow @nogc {
        return name == "flip" || name == "makeQuads";
    }

    final PreparedPenParamImage buildPreparedParamImage(string name) const {
        PreparedPenParamImage image;
        image.valid = true; image.kind = PreparedPenParamKind.Noop;
        image.expectedState = cast(ubyte)state;
        image.expectedParams = params_; image.nextParams = params_;
        image.expectedVertices = vertices_.dup;
        image.nextVertices = vertices_.dup;
        image.expectedHandlers.length = vertHandlers.length;
        image.expectedHandlerPositions.length = vertHandlers.length;
        image.nextHandlerPositions.length = vertHandlers.length;
        foreach (i, handler; vertHandlers) {
            image.expectedHandlers[i] = cast(BoxHandler)handler;
            image.expectedHandlerPositions[i] = handler.pos;
            image.nextHandlerPositions[i] = handler.pos;
        }
        image.expectedToWorld = frame.toWorld;
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
        } else return image;
        auto shadow = beginPreparedShadow(image.nextPreview);
        appendPenGeometry(image.nextPreview, PenStroke.of(image.nextVertices,
            frame.toWorld, image.nextParams), PenBuildPurpose.Preview);
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
            !sameValueBytes(frame.toWorld, image.expectedToWorld) ||
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
        if (image.upload) installPreparedMeshImage(previewMesh, image.nextPreview);
        foreach (i, handler; vertHandlers)
            handler.pos = image.nextHandlerPositions[i];
        image.clear();
    }
    override void activate() {
        state = PenState.Idle;
        vertices_.length = 0;
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

    final void installPreparedPrivateActivation() nothrow @nogc {
        state = PenState.Idle; vertices_.length = 0; params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
        dragArmed = dragInitiated = false; dragVertIdx = -1;
    }

    final PreparedPenDeactivateImage buildPreparedDeactivateState() const {
        PreparedPenDeactivateImage image;
        image.valid = true; image.expectedState = cast(ubyte)state;
        image.params = params_; image.vertices = vertices_.dup;
        image.toWorld = frame.toWorld;
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
            vertHandlers.length == image.expectedHandlerCount &&
            lastSnap == image.expectedLastSnap &&
            meshChanged == image.expectedMeshChanged &&
            (!image.willCommit || frame.toWorld == image.toWorld);
    }
    final void installPreparedDeactivateState(
            ref PreparedPenDeactivateImage image) nothrow @nogc {
        state = PenState.Idle; vertHandlers = null; vertices_ = null;
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
            image.toWorld, image.params), PenBuildPurpose.Commit);
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
        // If a valid sequence is pending, commit it on deactivate.
        if (state == PenState.Drawing && vertices_.length >= minDropCommitVerts()) {
            commitPolygonWithUndo();
        } else {
            cancelPolygon();
        }
        previewGpu.destroy();
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
            Vec3 hit;
            if (!resolvePenPoint(e.x, e.y, clickAnchor(), hit)) return true;
            appendVertex(hit);
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
        if (!resolvePenPoint(e.x, e.y, clickAnchor(), hit)) return true;

        // The press adding the 3rd point decides the facing, once, from
        // (p0, p1, this click) in every arm below (wave plan §9.4).
        if (vertices_.length == 2)
            params_.flip = penFacingFlip(toWorldP(vertices_[0]),
                toWorldP(vertices_[1]), toWorldP(hit), cachedVp);

        // Make Quads strip extension: after 2 anchor verts, each click adds
        // user (cursor) + auto (parallelogram extension). Skips the insert
        // path and the current-point preservation since strip ordering is
        // a positional sequence rather than a polygon's free boundary.
        if (params_.makeQuads && vertices_.length >= 2) {
            appendQuadStripPair(hit);
            // Current point follows the user-placed vertex (the second-to-
            // last in the buffer; the very-last is the auto-corner). Lets
            // the user's intent — placing a top-row vert at the cursor —
            // remain selectable for numeric edits.
            params_.currentPoint = cast(int)vertices_.length - 2;
            syncPosFromCurrent();
            uploadPreview();
            return true;
        }

        // Default polygon mode: append at end OR insert after currentPoint
        // (the doc's "to insert a vertex between two existing ones, highlight
        // a previously created vertex and click away from it").
        int n   = cast(int)vertices_.length;
        int cur = params_.currentPoint;
        if (cur >= 0 && cur < n - 1) {
            insertVertexAfter(cur, hit);
            params_.currentPoint = cur + 1;
        } else {
            appendVertex(hit);
            params_.currentPoint = cast(int)vertices_.length - 1;
        }
        syncPosFromCurrent();
        uploadPreview();
        armDrag(e.x, e.y);
        return true;
    }

    override bool onMouseMotion(ref const SDL_MouseMotionEvent e, ref VectorStack vts) {
        // Live snap preview — runs whenever a click would place / move
        // a vertex, so the user sees the cyan target before committing.
        // Skipped only when the user is hovering an existing in-progress
        // vertex (next click selects it, doesn't place a new one).
        if (state == PenState.Drawing && findHoveredVert(e.x, e.y) >= 0) {
            lastSnap = SnapResult.init;
            clearLastSnap();
        } else {
            // Idle: the plane the first click would lock onto.
            if (state == PenState.Idle) choosePlane(cachedVp);
            Vec3 ignored;
            resolvePenPoint(e.x, e.y, clickAnchor(), ignored);
        }

        if (!dragArmed) return false;

        if (!dragInitiated) {
            int dx = e.x - dragStartMX;
            int dy = e.y - dragStartMY;
            if (dx * dx + dy * dy < DRAG_THRESHOLD_PX * DRAG_THRESHOLD_PX)
                return true;     // still under threshold — consume but no-op
            dragInitiated = true;
        }

        // Relocate the dragged vertex to the cursor's projected plane hit.
        if (dragVertIdx < 0 || dragVertIdx >= cast(int)vertices_.length)
            return true;
        Vec3 hit;
        if (resolvePenPoint(e.x, e.y, dragAnchor, hit)) {
            vertices_[dragVertIdx] = hit;
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

            case SDLK_BACKSPACE:
                if (state == PenState.Drawing && vertices_.length > 0) {
                    sessionStepBegins();   // interim: an undoable step
                    popVertex();
                    if (vertices_.length == 0) state = PenState.Idle;
                    uploadPreview();
                    sessionStepEnds();
                    return true;
                }
                return false;

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
            ImGui.TextDisabled("Click to add vertices • Enter / dbl-click to close • Ctrl+Z undoes the last action • Backspace removes the last vertex • RMB to cancel");
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
    }

    // Where a click lands (wave plan S3a, tests/fixtures/pen_placement.json):
    // on the plane through the CURRENT point, the new point going right after
    // it (append = the current point is the last); the first point on the
    // plane through the camera focus. A pinned plane keeps its own origin for
    // the first point until its law is captured.
    Vec3 clickAnchor() const {
        if (vertices_.length == 0)
            return frame.isAuto ? toLocalP(cachedVp.focus) : Vec3(0, 0, 0);
        int cur = params_.currentPoint;
        return cur >= 0 && cur < cast(int)vertices_.length ? vertices_[cur]
                                                          : vertices_[$ - 1];
    }

    // The one place a pixel becomes a stroke point (click, hover, drag): the
    // locked plane through `anchor`, its two in-plane channels rounded to the
    // view's grid sub-step (the vector snap relocate and extrude use; wave
    // plan S3q, fixture pen_placement.json `quantum`), then a discrete snap,
    // then the pen guides when no discrete target won (guideBits are the
    // pen's own).
    bool resolvePenPoint(int x, int y, Vec3 anchor, out Vec3 local) {
        if (!workplaneCursorPlaneHit(frame, cachedVp, cast(float)x,
                                     cast(float)y, anchor, planeNormal, local)) {
            lastSnap = SnapResult.init;
            clearLastSnap();
            return false;
        }
        immutable float px = viewWorldPerPixel(cachedVp);
        immutable float q = viewGridSubStep(px, viewGridSize(px, g_viewGrid), g_viewGrid);
        immutable int k = planeNormal.x != 0 ? 0 : (planeNormal.y != 0 ? 1 : 2);
        local = withAxisComp(vectorSnap(local, q), k, axisComp(local, k));
        lastSnap = snapLocalHit(local, frame, x, y, cachedVp,
                                *mesh, EditMode.Vertices, [], guideBits);
        if (!(lastSnap.snapped && lastSnap.constraintType == SnapType.None))
            applyPenGuide(local, x, y);
        publishLastSnap(lastSnap);
        return true;
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

    void appendVertex(Vec3 pos) {
        // pos is in LOCAL workplane coords; the vertex handler renders in
        // world, so hit-testing needs the world image of `pos`.
        vertices_ ~= pos;
        vertHandlers ~= vertMarker(pos);
    }

    // One cyan marker for a LOCAL stroke point (markers render in WORLD).
    BoxHandler vertMarker(Vec3 pos) {
        Vec3 worldPos = toWorldP(pos);
        auto h = new BoxHandler(worldPos, schemeColor(SchemeColor.handle));
        h.size = gizmoSize(worldPos, cachedVp, 0.04f);
        return h;
    }

    // 6.9.5: Make Quads — append the two vertices that complete the next
    // strip quad. The user-placed `cursorPos` becomes the new "top" vertex;
    // the auto-corner is computed by the parallelogram rule
    //
    //   newBottom = prevBottom + (cursorPos − prevTop)
    //
    // where prevTop / prevBottom are the LAST two vertices in the buffer
    // (the leading edge of the strip so far). After the call the buffer
    // grows by 2 and the new pair is the next leading edge.
    //
    // Caller must have already ensured vertices_.length >= 2 (the two
    // anchor clicks); for fewer than 2 verts the regular append path is
    // used so the strip can be seeded.
    void appendQuadStripPair(Vec3 cursorPos) {
        Vec3 prevTop = vertices_[$ - 2];
        Vec3 prevBot = vertices_[$ - 1];
        Vec3 newTop  = cursorPos;
        Vec3 newBot  = prevBot + (newTop - prevTop);
        appendVertex(newTop);
        appendVertex(newBot);
    }

    // Insert a new vertex (and matching handler) at position insertIdx in the
    // boundary list, shifting later elements right. Used by the "click-away
    // while a vertex is current" path to splice into the polygon.
    void insertVertexAfter(int afterIdx, Vec3 pos) {
        // pos in LOCAL; handler in WORLD.
        int insertIdx = afterIdx + 1;
        if (insertIdx < 0) insertIdx = 0;
        if (insertIdx > cast(int)vertices_.length) insertIdx = cast(int)vertices_.length;
        vertices_ = vertices_[0 .. insertIdx] ~ pos ~ vertices_[insertIdx .. $];
        vertHandlers = vertHandlers[0 .. insertIdx] ~ vertMarker(pos)
            ~ vertHandlers[insertIdx .. $];
    }

    void popVertex() {
        if (vertices_.length == 0) return;
        vertices_.length -= 1;
        if (vertHandlers.length > 0) {
            vertHandlers[$ - 1].destroy();
            vertHandlers.length -= 1;
        }
        // currentPoint may now be out of range — clamp.
        int n = cast(int)vertices_.length;
        if (params_.currentPoint >= n) params_.currentPoint = n - 1;
        syncPosFromCurrent();
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
        static immutable ToolSessionPolicy policy = {
            rollovers: Rollover.target, sessionSteps: true, paramWriteSteps: true,
            imageAttrs: ["type", "currentPoint", "posX", "posY", "posZ", "flip",
                         "makeQuads", "points"] };
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
    // the preview / vert handlers, records nothing).
    public override void cancelUncommittedEdit() { cancelPolygon(); }

    // resyncSession() (undo/redo P1) is intentionally a JUSTIFIED NO-OP here:
    // PenTool caches no scene-mesh baseline. Its only session state is the
    // in-progress `vertices_` buffer, which holds LOCAL workplane positions
    // (world coords, not mesh vertex/edge indices). A committed undo/redo that
    // moves geometry beneath the active tool changes neither those world points
    // nor anything Pen would re-derive from the mesh, so the default base no-op
    // leaves the tool coherent for the next click. No override needed.

    void cancelPolygon() {
        clearVertHandlers();
        vertices_.length = 0;
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
        vertHandlers = vertHandlers[0 .. dragIdx] ~ vertHandlers[dragIdx + 1 .. $];
    }

    void uploadPreview() {
        assert(vertHandlers.length == vertices_.length,
            "pen: one marker per stroke point");
        previewMesh.clear();
        appendPenGeometry(previewMesh, PenStroke.of(vertices_, frame.toWorld,
            params_), PenBuildPurpose.Preview);
        previewGpu.upload(previewMesh);
        // Keep marker positions in sync (vertices_ may have been mutated by
        // popVertex / future numeric edits). Handlers render in WORLD.
        foreach (i, ref h; vertHandlers) h.pos = toWorldP(vertices_[i]);
    }

    // Minimum vertex count for Enter. Default polygon
    // mode needs ≥3 (a triangle); Make Quads needs ≥4 (one full quad in the
    // strip; the first two anchor verts alone don't yet form a face). Tool
    // drop uses minDropCommitVerts() below.
    size_t minCommitVerts() const {
        return penFaceMinimum(params_.makeQuads);
    }

    // A drop keeps any sequence that already forms a polygon edge; Enter still
    // needs a closable face. Task 5911; fixture row E5pen2.
    size_t minDropCommitVerts() const {
        return params_.makeQuads ? 4 : 2;
    }

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

    void commitPolygonWithUndo() {
        if (state != PenState.Drawing || vertices_.length < minDropCommitVerts()) return;
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
        vertices_.length = 0;
        previewMesh.clear();
        previewGpu.upload(previewMesh);
        params_.currentPoint = -1;
        params_.posX = params_.posY = params_.posZ = 0.0f;
        meshChanged = true;
        sessionOperationEnded();   // the stroke's steps end with its one row
    }

    void commitPolygon() {
        // A pure tail append into the live scene mesh, declared as such for
        // the corner-append cross-check.
        appendPenGeometry(*mesh, PenStroke.of(vertices_, frame.toWorld,
            params_), PenBuildPurpose.Commit);
        mesh.declareCornerAppend();
        mesh.buildLoops();
        gpu.upload(*mesh);
    }
}
