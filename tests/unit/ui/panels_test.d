// Module unittests for `ui.panels`, moved verbatim out of source/ui/panels.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ui.panels_test;

import tests.unit.census_symbols : wave19MathPhysicalPath;

import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz, indexOf;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv;
import std.json : JSONValue, JSONType;
import vibe3d.runtime.http.http_server;
import vibe3d.util.log.log : logInfo, logWarn, logError;
import vibe3d.util.profiling.perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import vibe3d.apps.desktop.prefs;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import d_imgui.imgui_demo;
import imgui_impl_sdl2;
import imgui_impl_opengl3;
import nfde;
import vibe3d.util.math.math;
import vibe3d.mesh.core.mesh;
import vibe3d.platform.input.eventlog;
import vibe3d.editing.tools.interactive.handler;
import vibe3d.editing.tools.interactive.pipe_gizmo_host : PipeGizmoHost;
import vibe3d.editing.tools.interactive.tool;
import vibe3d.editing.contracts.editmode;
import vibe3d.editing.contracts.seltype;
import vibe3d.editing.pipeline.evaluation.toolpipe;
import vibe3d.editing.pipeline.contracts.operator         : VectorStack;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : SubjectPacket;
import vibe3d.editing.pipeline.runtime.toolpipe.pipeline : g_pipeCtx;
import vibe3d.editing.tools.interactive.gizmo;
import vibe3d.viewport.camera.view;
import vibe3d.editing.selection.query.viewgrid : g_viewGrid, viewGridSizeFor, viewGridFadeRadius;
import vibe3d.viewport.gpu.shader;
import vibe3d.util.profiling.perf_probe : g_perf, Cat, g_frames, Phase, FrameRec, FrameStatsSnapshot;
import vibe3d.documents.interchange.io.assimp_runtime : initAssimp, shutdownAssimp, isAssimpAvailable;
import vibe3d.ui.editor.ui.availability : actionRefusal, recordDrawnButton;
import vibe3d.editing.selection.scene_query.symmetry_pick : symmetricSelectVertex, symmetricSelectEdge, symmetricSelectFace;
import vibe3d.editing.selection.scene_query.bvh_pick : BvhPick;
import vibe3d.editing.tools.interactive.tools.transform.transform;
import vibe3d.editing.tools.interactive.tools.transform.move;
import vibe3d.editing.tools.interactive.tools.deform.push;
import vibe3d.editing.tools.interactive.tools.deform.bend;
import vibe3d.editing.tools.interactive.tools.alignment.linear_align_tool;
import vibe3d.editing.tools.interactive.tools.alignment.radial_align_tool;
import vibe3d.editing.tools.interactive.tools.transform.scale;
import vibe3d.editing.tools.interactive.tools.transform.rotate;
import vibe3d.editing.tools.interactive.tools.create.box;
import vibe3d.editing.tools.interactive.tools.alignment.mirror;
import vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool;
import vibe3d.editing.tools.interactive.tools.create.sphere;
import vibe3d.editing.tools.interactive.tools.create.cylinder;
import vibe3d.editing.tools.interactive.tools.create.cone;
import vibe3d.editing.tools.interactive.tools.create.capsule;
import vibe3d.editing.tools.interactive.tools.create.torus;
import vibe3d.editing.tools.interactive.tools.create.arc;
import vibe3d.editing.tools.interactive.tools.create.tube;
import vibe3d.editing.tools.interactive.tools.create.pen;
import vibe3d.editing.tools.interactive.tools.create.vertex_place : VertexTool;
import vibe3d.editing.tools.interactive.tools.edit.edge_extrude : EdgeExtrudeTool;
import vibe3d.editing.tools.interactive.tools.edit.edge_extend : EdgeExtendTool;
import vibe3d.editing.tools.interactive.tools.slice.edge_slide : EdgeSlideTool;
import vibe3d.editing.tools.interactive.tools.edit.poly_extrude : PolyExtrudeTool;
import vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool : RadialArrayTool;
import vibe3d.editing.tools.interactive.tools.edit.poly_bevel : PolyBevelTool;
import vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool : PolyInsetTool;
import vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool : SmoothShiftTool;
import vibe3d.editing.tools.interactive.tools.deform.magnet : MagnetTool;
import vibe3d.editing.tools.interactive.tools.edit.edge_bevel : EdgeBevelTool;
import vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool : LoopSliceTool;
import vibe3d.editing.tools.interactive.tools.slice.slice_tool : SliceTool;
import vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool : EdgeSliceTool;
import vibe3d.editing.tools.interactive.tools.edit.reduce : ReductionTool;
import vibe3d.editing.tools.interactive.tools.alignment.clone_tool : CloneTool;
import vibe3d.editing.tools.interactive.tools.alignment.array_tool : ArrayTool;
import vibe3d.editing.tools.interactive.tools.edit.tack : TackTool;
import vibe3d.editing.tools.interactive.tools.edit.bridge_tool : BridgeTool;
import vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool : VertexMergeTool;
import vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool : VertexBevelTool;
import vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool : VertexExtrudeTool;
import vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool : StrokeExtrudeTool;
import vibe3d.editing.tools.interactive.tools.common.command_wrapper : XfrmSmoothTool, XfrmJitterTool, XfrmQuantizeTool;
import vibe3d.editing.commands.editor.commands.select.connect;
import vibe3d.editing.commands.editor.commands.select.expand;
import vibe3d.editing.commands.editor.commands.select.contract;
import vibe3d.editing.commands.editor.commands.select.loop;
import vibe3d.editing.commands.editor.commands.select.ring;
import vibe3d.editing.commands.runtime.commands.select.invert;
import vibe3d.editing.commands.editor.commands.select.more;
import vibe3d.editing.commands.editor.commands.select.less;
import vibe3d.editing.commands.editor.commands.select.between;
import vibe3d.editing.commands.editor.commands.select.type_from : SelectTypeFromCommand;
import vibe3d.editing.commands.runtime.commands.select.drop     : SelectDropCommand;
import vibe3d.editing.commands.runtime.commands.select.element  : SelectElementCommand;
import vibe3d.editing.commands.editor.commands.select.convert  : SelectConvertCommand;
import vibe3d.editing.commands.editor.commands.select.fill     : SelectFillHoles, SelectFillInsideLoop;
import vibe3d.apps.desktop.commands.viewport.fit_selected;
import vibe3d.apps.desktop.commands.viewport.fit;
import vibe3d.apps.desktop.commands.file.load;
import vibe3d.apps.desktop.commands.file.save;
import vibe3d.editing.commands.editor.commands.mesh.subdivide;
import vibe3d.editing.commands.editor.commands.mesh.subdivide_faceted;
import vibe3d.editing.commands.editor.commands.mesh.triple      : MeshTriple;
import vibe3d.editing.commands.editor.commands.mesh.quadruple   : MeshQuadruple;
import vibe3d.editing.commands.editor.commands.mesh.detriangulate : MeshDetriangulate;
import vibe3d.editing.commands.editor.commands.mesh.merge         : MeshMergeFaces;
import vibe3d.editing.commands.editor.commands.mesh.subpatch_toggle;
import vibe3d.editing.commands.editor.commands.mesh.set_material;
import vibe3d.editing.commands.editor.commands.mesh.set_part;
import vibe3d.editing.tools.interactive.commands.tool.headless : ToolHeadlessCommand;
import vibe3d.editing.commands.editor.commands.mesh.split_edge;
import vibe3d.editing.commands.editor.commands.mesh.add_point : MeshAddPoint;
import vibe3d.editing.commands.editor.commands.mesh.split_face  : MeshSplitFace;
import vibe3d.editing.commands.editor.commands.mesh.edge_join : MeshEdgeJoin;
import vibe3d.editing.commands.editor.commands.mesh.spin_edge;
import vibe3d.editing.commands.editor.commands.mesh.loop_slice : MeshAddLoop, MeshLoopSlice;
import vibe3d.editing.commands.editor.commands.mesh.session_edit : MeshSessionEdit;
import vibe3d.editing.commands.editor.commands.mesh.edge_extrude : MeshEdgeExtrude;
import vibe3d.editing.commands.editor.commands.mesh.vertex_extrude : MeshVertexExtrude;
import vibe3d.editing.commands.editor.commands.mesh.vertex_bevel   : MeshVertexBevel;
import vibe3d.editing.commands.editor.commands.mesh.poly_inset : MeshPolygonInset;
import vibe3d.editing.commands.editor.commands.mesh.spikey : MeshSpikey;
import vibe3d.editing.commands.editor.commands.mesh.bevel : MeshBevel;
import vibe3d.editing.commands.editor.commands.mesh.face_extrude : MeshFaceExtrude;
import vibe3d.editing.commands.editor.commands.mesh.bridge : MeshBridge;
import vibe3d.editing.commands.editor.commands.mesh.thicken : MeshThicken;
import vibe3d.editing.commands.editor.commands.mesh.smooth_shift : MeshSmoothShift;
import vibe3d.editing.commands.editor.commands.mesh.edge_extend : MeshEdgeExtend;
import vibe3d.editing.commands.editor.commands.mesh.move_vertex;
import vibe3d.editing.commands.editor.commands.mesh.vertex_new    : MeshVertexNew;
import vibe3d.editing.commands.editor.commands.mesh.vertex_center : MeshCenterVertices;
import vibe3d.editing.commands.editor.commands.mesh.vertex_set    : MeshSetPosition;
import vibe3d.editing.commands.editor.commands.mesh.delete_ : MeshDelete;
import vibe3d.editing.commands.editor.commands.mesh.remove_ : MeshRemove;
import vibe3d.editing.commands.editor.commands.mesh.flip    : MeshFlip;
import vibe3d.editing.commands.editor.commands.mesh.duplicate_ : MeshDuplicate;
import vibe3d.editing.commands.editor.commands.mesh.copy_      : MeshCopy;
import vibe3d.editing.commands.editor.commands.mesh.paste_     : MeshPaste;
import vibe3d.editing.commands.editor.commands.mesh.cut_       : MeshCut;
import vibe3d.editing.commands.editor.commands.mesh.mirror_      : MeshMirror;
import vibe3d.editing.commands.editor.commands.mesh.symmetrize   : MeshSymmetrize;
import vibe3d.editing.commands.editor.commands.mesh.array_       : MeshArray;
import vibe3d.editing.commands.editor.commands.mesh.clone_       : MeshClone;
import vibe3d.editing.commands.editor.commands.mesh.radial_array_ : MeshRadialArray;
import vibe3d.editing.commands.editor.commands.mesh.sweep         : MeshSweep;
import vibe3d.editing.commands.editor.commands.mesh.stroke_extrude      : MeshStrokeExtrude;
import vibe3d.editing.commands.editor.commands.mesh.vert_merge        : MeshVertMerge;
import vibe3d.editing.commands.editor.commands.mesh.weld_vertex_pair  : MeshWeldVertexPair;
import vibe3d.editing.commands.editor.commands.mesh.vert_join         : MeshVertJoin;
import vibe3d.editing.commands.editor.commands.mesh.axis_slice    : MeshAxisSlice, MeshJulienne;
import vibe3d.editing.commands.editor.commands.mesh.screen_slice  : MeshScreenSlice;
import vibe3d.editing.commands.editor.commands.mesh.edge_slice    : MeshEdgeSlice;
import vibe3d.editing.commands.editor.commands.mesh.collapse      : MeshCollapse;
import vibe3d.editing.commands.editor.commands.mesh.vertex_split  : MeshVertexSplit;
import vibe3d.editing.commands.editor.commands.mesh.reduce        : MeshReduce;
import vibe3d.editing.commands.editor.commands.mesh.unify         : MeshUnify;
import vibe3d.editing.commands.editor.commands.mesh.cleanup       : MeshCleanup;
import vibe3d.editing.commands.editor.commands.mesh.fix_orientation : MeshFixOrientation;
import vibe3d.editing.commands.editor.commands.mesh.make_polygon  : MeshMakePolygon;
import vibe3d.editing.commands.editor.commands.mesh.select;
import vibe3d.editing.commands.editor.commands.mesh.selection_edit : MeshSelectionEdit;
import vibe3d.editing.commands.editor.commands.mesh.transform;
import vibe3d.editing.commands.editor.commands.mesh.quantize;
import vibe3d.editing.commands.editor.commands.mesh.jitter;
import vibe3d.editing.commands.editor.commands.mesh.magnet : MeshMagnet;
import vibe3d.editing.commands.editor.commands.mesh.smooth;
import vibe3d.editing.commands.editor.commands.mesh.weightmap;
import vibe3d.editing.commands.editor.commands.mesh.uv_transform;
import vibe3d.editing.commands.editor.commands.mesh.uv_project  : UvProject;
import vibe3d.editing.commands.editor.commands.mesh.uv_pack     : UvFit, UvPack;
import vibe3d.editing.commands.editor.commands.mesh.uv_map_util;
import vibe3d.editing.commands.editor.commands.mesh.uv_relax  : UvRelax;
import vibe3d.editing.commands.editor.commands.mesh.uv_unwrap : UvUnwrap;
import vibe3d.editing.commands.editor.commands.mesh.edge_slide;
import vibe3d.editing.commands.editor.commands.mesh.linear_align;
import vibe3d.editing.commands.editor.commands.mesh.polygon_align;
import vibe3d.editing.commands.editor.commands.mesh.radial_align;
import vibe3d.editing.commands.editor.commands.mesh.vertex_edit;
import vibe3d.runtime.document_actions.commands.scene.reset;
import vibe3d.runtime.document_actions.commands.scene.load_mesh;
import vibe3d.editing.commands.runtime.commands.history.undo : HistoryUndo;
import vibe3d.editing.commands.runtime.commands.history.redo : HistoryRedo;
import vibe3d.editing.commands.editor.commands.history.show : HistoryShow;
import vibe3d.editing.commands.editor.commands.history.clear : HistoryClear;
import vibe3d.apps.desktop.commands.test_undo_flags : UndoSuppressNoop, UndoForceNoop;
import vibe3d.editing.commands.editor.commands.history.save_as_script : HistorySaveAsScript;
import vibe3d.editing.commands.editor.commands.macros.record : MacroRecord;
import vibe3d.editing.commands.editor.commands.macros.save_recorded : MacroSaveRecorded;
import vibe3d.editing.commands.editor.macro_recorder : MacroRecorder;
import vibe3d.mesh.snapshot.snapshot : SelectionSnapshot;
import vibe3d.editing.tools.interactive.commands.tool.host     : ToolHost;
import vibe3d.editing.tools.interactive.commands.tool.set      : ToolSetCommand;
import vibe3d.editing.tools.interactive.commands.tool.attr     : ToolAttrCommand;
import vibe3d.runtime.document_actions.commands.layer.commands : LayerAttr, layerDeleteButtonState;
import vibe3d.ui.editor.ui.image_rows : ImageRow, imageRowsInto, imageRemoveTarget,
                       elidedPathText, kNoImagesText;
import vibe3d.editing.tools.interactive.commands.tool.do_apply : ToolDoApplyCommand;
import vibe3d.editing.tools.interactive.commands.tool.reset    : ToolResetCommand;
import vibe3d.editing.tools.interactive.commands.tool.pipe     : ToolPipeAttrCommand;
import vibe3d.editing.tools.interactive.commands.tool.begin_session : ToolBeginSessionCommand;
import vibe3d.apps.desktop.commands.ui.tool_properties : UiToolPropertiesCommand, g_toolPropertiesShown;
import vibe3d.apps.desktop.commands.ui.layer_list      : UiLayerListCommand, g_layerListShown;
import vibe3d.apps.desktop.commands.ui.viewport_props  : UiViewportPropsCommand, g_viewportPropsShown;
import vibe3d.editing.tools.interactive.commands.tool.panel_edit    : ToolPanelEditCommand;
import vibe3d.apps.desktop.commands.snap.toggle_type : SnapToggleTypeCommand;
import vibe3d.apps.desktop.commands.snap.mode        : SnapModeCommand;
import vibe3d.apps.desktop.commands.ai.toggle    : AiToggleCommand, AiToggleAction;
import vibe3d.editing.tools.interactive.commands.falloff        : FalloffAddCommand, FalloffRemoveCommand,
                                  FalloffAutoSizeCommand;
import vibe3d.apps.desktop.commands.path.define    : PathDefineCommand;
import vibe3d.apps.desktop.commands.workplane     : WorkplaneResetCommand, WorkplaneEditCommand,
                                WorkplaneRotateCommand, WorkplaneOffsetCommand,
                                WorkplaneAlignToSelectionCommand;
import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.tools.interactive.registry;
import vibe3d.platform.input.shortcuts;
import vibe3d.ui.editor.buttonset;
import vibe3d.editing.interaction.data.ai.debug_trace : latestHandleDebugTraceJson;
import vibe3d.runtime.ai_advisor.ai.element_candidates : publishElementCandidates,
    collectElementCandidates, resolveElementCandidateDecision;
import vibe3d.editing.interaction.data.ai.interaction : AiAdvisorDecision, AiCandidate, AiInteractionContext,
    AiInteractionPhase, AiIntent;
import vibe3d.runtime.ai_advisor.ai.interaction_log : AiInteractionLogRecord, makeAiInteractionLogRecord;
import vibe3d.runtime.ai_advisor.ai.interaction_log_writer : AiInteractionLogWriter, defaultLiveSource;
import vibe3d.runtime.ai_advisor.ai.exploration : AiExplorationController, buildCandidateKey,
    defaultExploreSource, OptionalGrab, Resolution, ResolutionKind;
import vibe3d.runtime.ai_advisor.ai.state      : EditorAiState;
import vibe3d.editing.interaction.data.ai.advisor    : AiAdvisor;
import vibe3d.runtime.ai_advisor.ai.copilot_gate : kCopilotEnabled;
import vibe3d.runtime.ai_advisor.ai.model_adapter : AiModelAdapter, AiModelAdapterConfig,
    AiModelAvailability, AiModelStatus, AiModelFallbackMode,
    aiModelAdapterMinConfidence;
import vibe3d.ui.editor.args_dialog    : ArgsDialog;
import vibe3d.runtime.ai3d.ai3d.job_controller       : Ai3dJobController, Ai3dClientJoinTimeoutMs;
import vibe3d.runtime.ai3d.ai3d.job_events           : Ai3dEvent, Ai3dEventKind;
import vibe3d.runtime.ai3d.ai3d.stage_artifact       : Ai3dDefaultRequestedFaces, Ai3dMaxGenerationDeadlineMs;
import vibe3d.runtime.ai3d.ai3d.scene_validator      : Ai3dMaxTotalFaces;
import vibe3d.runtime.ai3d.ai3d.worker_manager       : Ai3dWorkerManager, Ai3dWorkerState,
    Ai3dInstallState, ai3dDefaultInstallLocation, ai3dDefaultWorkerUrl;
import core.time : MonoTime;  // phase-B drawAi3dModal: MonoTime.currTime health-poll throttle
import vibe3d.apps.desktop.commands.ai3d.import_result : Ai3dImportResult;
import vibe3d.runtime.remesh.remesh.remesh_job         : RemeshJob, RemeshParams,
    MAX_REMESH_TARGET_QUADS, MIN_REMESH_TARGET_QUADS;
import vibe3d.editing.commands.editor.commands.mesh.remesh      : Remesh, RemeshStart, RemeshOpen;
import vibe3d.editing.tools.interactive.property_panel : PropertyPanel;
import vibe3d.ui.editor.forms_render;
import vibe3d.documents.channels.layer_params   : LayerPropsProvider, itemPropsTarget;
import vibe3d.documents.model.document       : Layer, Document, kindInfo, tokenOf;
import vibe3d.editing.selection.query.snap           : ItemSnapFrame;
import vibe3d.viewport.host.viewport       : LayoutPreset, ViewportManager, Viewport3D;
import vibe3d.ui.editor.ui.panels;

unittest { // compiler capability shapes for the finite borrowed roles
    import vibe3d.ui.editor.ui.panel_host_roles;
    static assert([__traits(allMembers, TabLayoutBorrow)] == ["tabPosPtr", "tabSizePtr", "tabPos", "tabSize"]);
    static assert([__traits(allMembers, SideLayoutBorrow)] == ["sidePosPtr", "sideSizePtr", "sidePos", "sideSize"]);
    static assert([__traits(allMembers, StatusLayoutBorrow)] == ["statusPosPtr", "statusSizePtr", "statusPos", "statusSize"]);
    static assert([__traits(allMembers, TabPanelRole)] == ["layout", "panelsPtr", "activePanelIdxPtr", "panels", "activePanelIdx", "testMode"]);
    static assert([__traits(allMembers, SidePanelRole)] == ["layout", "panelsPtr", "activePanelIdxPtr", "activeToolIdPtr", "shortcutsPtr", "regPtr", "sessionOwner", "meshDg", "kGenerateAiAvailable", "panels", "activePanelIdx", "activeToolId", "shortcuts", "reg", "document", "editMode", "mesh", "testMode"]);
    static assert([__traits(allMembers, StatusPanelRole)] == ["layout", "statusLineGroupsPtr", "activeToolIdPtr", "shortcutsPtr", "regPtr", "sessionOwner", "meshDg", "kAiToggleAvailable", "kCopilotEnabled", "statusLineGroups", "activeToolId", "shortcuts", "reg", "document", "editMode", "selTypeOrder", "mesh", "testMode"]);
}

unittest { // desktop presentation bindings borrow each original live slot
    import vibe3d.apps.desktop.editor_app : EditorApp, Layout, bindPanelHostRoles, kGenerateAiAvailable,
        kAiToggleAvailable;
    import vibe3d.ui.editor.ui.panel_host_roles;
    import vibe3d.runtime.application_core.session_owner : Session;
    import vibe3d.apps.desktop.editor_app : Layout;
    import vibe3d.ui.editor.buttonset : Panel, Group;
    import vibe3d.editing.tools.interactive.registry : Registry;
    import vibe3d.platform.input.shortcuts : ShortcutTable;
    EditorApp app;
    Layout layout;
    Panel[] panels;
    Group[] groups;
    int activePanel;
    string toolId;
    ShortcutTable shortcuts;
    Registry registry;
    Session owner;
    Mesh firstMesh, secondMesh;
    Mesh* liveMesh = &firstMesh;
    ref Mesh currentMesh() nothrow @nogc { return *liveMesh; }
    app.layoutPtr = &layout;
    app.panelsPtr = &panels;
    app.statusLineGroupsPtr = &groups;
    app.activePanelIdxPtr = &activePanel;
    app.activeToolIdPtr = &toolId;
    app.shortcutsPtr = &shortcuts;
    app.regPtr = &registry;
    app.sessionOwner = &owner;
    app.meshDg = cast(typeof(app.meshDg)) &currentMesh;
    auto tab = bindPanelHostRoles!TabPanelRole(app);
    auto side = bindPanelHostRoles!SidePanelRole(app);
    auto status = bindPanelHostRoles!StatusPanelRole(app);
    assert(tab.panelsPtr == app.panelsPtr, "W18 tab panelsPtr borrowed identity");
    assert(tab.activePanelIdxPtr == app.activePanelIdxPtr, "W18 tab activePanelIdxPtr borrowed identity");
    assert(side.panelsPtr == app.panelsPtr, "W18 side panelsPtr borrowed identity");
    assert(side.activePanelIdxPtr == app.activePanelIdxPtr, "W18 side activePanelIdxPtr borrowed identity");
    assert(side.activeToolIdPtr == app.activeToolIdPtr, "W18 side activeToolIdPtr borrowed identity");
    assert(side.shortcutsPtr == app.shortcutsPtr, "W18 side shortcutsPtr borrowed identity");
    assert(side.regPtr == app.regPtr, "W18 side regPtr borrowed identity");
    assert(side.sessionOwner == app.sessionOwner, "W18 side sessionOwner borrowed identity");
    assert(side.meshDg == app.meshDg, "W18 side meshDg borrowed identity");
    assert(status.statusLineGroupsPtr == app.statusLineGroupsPtr, "W18 status statusLineGroupsPtr borrowed identity");
    assert(status.activeToolIdPtr == app.activeToolIdPtr, "W18 status activeToolIdPtr borrowed identity");
    assert(status.shortcutsPtr == app.shortcutsPtr, "W18 status shortcutsPtr borrowed identity");
    assert(status.regPtr == app.regPtr, "W18 status regPtr borrowed identity");
    assert(status.sessionOwner == app.sessionOwner, "W18 status sessionOwner borrowed identity");
    assert(status.meshDg == app.meshDg, "W18 status meshDg borrowed identity");
    assert(tab.layout.tabPosPtr == &layout.tabPos, "W18 tab layout Pos address");
    assert(tab.layout.tabSizePtr == &layout.tabSize, "W18 tab layout Size address");
    assert(side.layout.sidePosPtr == &layout.sidePos, "W18 side layout Pos address");
    assert(side.layout.sideSizePtr == &layout.sideSize, "W18 side layout Size address");
    assert(status.layout.statusPosPtr == &layout.statusPos, "W18 status layout Pos address");
    assert(status.layout.statusSizePtr == &layout.statusSize, "W18 status layout Size address");
    assert(side.kGenerateAiAvailable == kGenerateAiAvailable, "W18 side generate capability");
    assert(status.kAiToggleAvailable == kAiToggleAvailable, "W18 status toggle capability");
    assert(status.kCopilotEnabled == kCopilotEnabled, "W18 status copilot capability");
    liveMesh = &secondMesh;
    assert(&side.mesh() == &secondMesh, "W18 side late Mesh lookup");
    assert(&status.mesh() == &secondMesh, "W18 status late Mesh lookup");
    assert(&side.document() == &owner.document(), "W18 side sole Session Document");
    assert(&status.document() == &owner.document(), "W18 status sole Session Document");
    assert(&side.editMode() == &owner.editMode(), "W18 side sole Session EditMode");
    assert(&status.editMode() == &owner.editMode(), "W18 status sole Session EditMode");
    assert(&status.selTypeOrder() == &owner.selTypeOrder(), "W18 status sole Session selection order");
}

version (web) {} else unittest { // scalar modal refs and live worker slots keep desktop custody
    import vibe3d.apps.desktop.editor_app : EditorApp, Ai3dModalState, bindPanelHostRoles;
    import vibe3d.ui.editor.ui.panel_host_roles : Ai3dPanelRole;
    import core.time : MonoTime;
    import vibe3d.runtime.ai3d.ai3d.job_controller : Ai3dJobController;
    import vibe3d.runtime.ai3d.ai3d.worker_manager : Ai3dWorkerManager;
    EditorApp app;
    Ai3dModalState modal;
    bool open, pending, starting, installOpen, installPending;
    string image;
    char[256] url;
    MonoTime deadline, nextProbe;
    int maxFaces;
    app.ai3dRefs.ai3dModalPtr = &modal;
    app.ai3dRefs.ai3dModalOpenPtr = &open;
    app.ai3dRefs.ai3dModalPendingOpenPtr = &pending;
    app.ai3dRefs.ai3dPickedImagePathPtr = &image;
    app.ai3dRefs.ai3dWorkerUrlBufPtr = &url;
    app.ai3dWorkerStartingPtr = &starting;
    app.ai3dWorkerStartDeadlinePtr = &deadline;
    app.ai3dWorkerNextHealthProbePtr = &nextProbe;
    app.ai3dInstallConfirmOpenPtr = &installOpen;
    app.ai3dInstallConfirmPendingOpenPtr = &installPending;
    app.ai3dMaxFacesPtr = &maxFaces;
    app.ai3dController = new Ai3dJobController;
    app.ai3dWorkerManager = new Ai3dWorkerManager("/dev/null");
    auto role = bindPanelHostRoles!Ai3dPanelRole(app);
    assert(role.ai3dModal.healthCheckedPtr == &modal.healthChecked, "W18 AI3D healthChecked original scalar address");
    assert(role.ai3dModal.healthOkPtr == &modal.healthOk, "W18 AI3D healthOk original scalar address");
    assert(role.ai3dModal.healthProtocolPtr == &modal.healthProtocol, "W18 AI3D healthProtocol original scalar address");
    assert(role.ai3dModal.healthBackendPtr == &modal.healthBackend, "W18 AI3D healthBackend original scalar address");
    assert(role.ai3dModal.healthObjCapablePtr == &modal.healthObjCapable, "W18 AI3D healthObjCapable original scalar address");
    assert(role.ai3dModal.healthMessagePtr == &modal.healthMessage, "W18 AI3D healthMessage original scalar address");
    assert(role.ai3dModal.jobIdPtr == &modal.jobId, "W18 AI3D jobId original scalar address");
    assert(role.ai3dModal.statePtr == &modal.state, "W18 AI3D state original scalar address");
    assert(role.ai3dModal.stagePtr == &modal.stage, "W18 AI3D stage original scalar address");
    assert(role.ai3dModal.progressPtr == &modal.progress, "W18 AI3D progress original scalar address");
    assert(role.ai3dModal.errorCodePtr == &modal.errorCode, "W18 AI3D errorCode original scalar address");
    assert(role.ai3dModal.errorMessagePtr == &modal.errorMessage, "W18 AI3D errorMessage original scalar address");
    assert(role.ai3dModalOpenPtr == &open, "W18 AI3D ai3dModalOpenPtr original identity");
    assert(role.ai3dModalPendingOpenPtr == &pending, "W18 AI3D ai3dModalPendingOpenPtr original identity");
    assert(role.ai3dPickedImagePathPtr == &image, "W18 AI3D ai3dPickedImagePathPtr original identity");
    assert(role.ai3dWorkerUrlBufPtr == &url, "W18 AI3D ai3dWorkerUrlBufPtr original identity");
    assert(role.ai3dWorkerStartingPtr == &starting, "W18 AI3D ai3dWorkerStartingPtr original identity");
    assert(role.ai3dWorkerStartDeadlinePtr == &deadline, "W18 AI3D ai3dWorkerStartDeadlinePtr original identity");
    assert(role.ai3dWorkerNextHealthProbePtr == &nextProbe, "W18 AI3D ai3dWorkerNextHealthProbePtr original identity");
    assert(role.ai3dInstallConfirmOpenPtr == &installOpen, "W18 AI3D ai3dInstallConfirmOpenPtr original identity");
    assert(role.ai3dInstallConfirmPendingOpenPtr == &installPending, "W18 AI3D ai3dInstallConfirmPendingOpenPtr original identity");
    assert(role.ai3dMaxFacesPtr == &maxFaces, "W18 AI3D ai3dMaxFacesPtr original identity");
    assert(role.ai3dController == app.ai3dController, "W18 AI3D ai3dController original identity");
    assert(role.ai3dWorkerManager == app.ai3dWorkerManager, "W18 AI3D ai3dWorkerManager original identity");
}

unittest { // real desktop factories and draw calls remain wiring witnesses
    import std.file : readText;
    import std.path : buildPath, dirName;
    import tests.unit.census_symbols : blankNonCode, countIdent;
    const root = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));
    const factory = blankNonCode(readText(wave19MathPhysicalPath(buildPath(root, "source/editor_app.d"))));
    const app = blankNonCode(readText(wave19MathPhysicalPath(buildPath(root, "source/app.d"))));
    assert(countIdent(factory, "bindPanelHostRoles") == 1,
        "W18 desktop role factory declaration floor");
    assert(app.indexOf("drawTabPanel(editor_app.bindPanelHostRoles!(TabPanelRole)(app)") >= 0,
        "W18 TabPanelRole production draw uses the live factory");
    assert(app.indexOf("drawSidePanel(editor_app.bindPanelHostRoles!(SidePanelRole)(app)") >= 0,
        "W18 SidePanelRole production draw uses the live factory");
    assert(app.indexOf("drawStatusBar(editor_app.bindPanelHostRoles!(StatusPanelRole)(app)") >= 0,
        "W18 StatusPanelRole production draw uses the live factory");
    assert(app.indexOf("drawAi3dModal(editor_app.bindPanelHostRoles!(Ai3dPanelRole)(app)") >= 0,
        "W18 Ai3dPanelRole production draw uses the live factory");
}

unittest {
    // Each row picks numbers a wrong-but-plausible implementation reads
    // DIFFERENTLY, not merely a case where it produces nothing.
    //
    // 1. Nothing hidden ⇒ the empty signal. An implementation that always
    //    builds the line reads "Hidden:" here and the callers reserve a row
    //    for a mesh with nothing hidden.
    assert(hiddenReadout(0, 0, 0) == "",
        "nothing hidden must produce NO line at all, not an empty-valued one");

    // 2. Three DIFFERENT non-zero counts. This is the row that separates the
    //    plausible wrong implementations from each other: one that reads the
    //    FACE plane for all three reads "3 vert, 3 edge, 3 poly"; one that
    //    SUMS the planes reads "10 poly"; one that swaps vert/poly (the easy
    //    transposition, since faces are the stored plane and vertices the
    //    derived one) reads "3 vert, 5 edge, 2 poly". All three differ from
    //    the answer below, which is why the counts must be distinct AND the
    //    order asserted — equal counts would let the transposition through.
    assert(hiddenReadout(2, 5, 3) == "Hidden: 2 vert, 5 edge, 3 poly",
        "got: " ~ hiddenReadout(2, 5, 3));

    // 3. Only the face plane — the ordinary polygon-mode hide. An
    //    implementation that emits every plane unconditionally reads
    //    "Hidden: 0 vert, 0 edge, 3 poly".
    assert(hiddenReadout(0, 0, 3) == "Hidden: 3 poly",
        "got: " ~ hiddenReadout(0, 0, 3));

    // 4. Only the LEADING plane — pins the separator state machine. An
    //    implementation that joins with a leading ", " reads "Hidden: , 1 vert"
    //    and one that appends a trailing comma reads "Hidden: 1 vert,".
    assert(hiddenReadout(1, 0, 0) == "Hidden: 1 vert",
        "got: " ~ hiddenReadout(1, 0, 0));

    // 5. A gap in the middle — the separator must attach to the SECOND
    //    printed part, not to the second PLANE.
    assert(hiddenReadout(4, 0, 6) == "Hidden: 4 vert, 6 poly",
        "got: " ~ hiddenReadout(4, 0, 6));

    // 6. The compact spelling. Same "nothing hidden ⇒ no line" contract, and
    //    the same distinct-counts discriminator: a wrong wiring that fed it
    //    the face count three times reads "3/3/3" and a vert/poly
    //    transposition reads "3/5/2".
    assert(hiddenReadoutCompact(0, 0, 0) == "",
        "compact: nothing hidden must produce no line either");
    assert(hiddenReadoutCompact(2, 5, 3) == "2/5/3 hidden",
        "got: " ~ hiddenReadoutCompact(2, 5, 3));
    // 7. The compact form keeps the ZERO planes, unlike the prose form —
    //    deliberately, because its whole legibility rests on the reader
    //    matching the three slots to the V/E/F rows above it. Dropping a zero
    //    would slide "6" from the F slot into the V slot.
    assert(hiddenReadoutCompact(0, 0, 6) == "0/0/6 hidden",
        "got: " ~ hiddenReadoutCompact(0, 0, 6));

    // 8. The two spellings must never disagree about WHETHER to draw — that
    //    is the one property the side panel and the status bar share.
    foreach (v; 0 .. 2) foreach (e; 0 .. 2) foreach (f; 0 .. 2)
        assert((hiddenReadout(v, e, f).length > 0)
            == (hiddenReadoutCompact(v, e, f).length > 0),
            "the two readouts disagreed on emptiness");
}
