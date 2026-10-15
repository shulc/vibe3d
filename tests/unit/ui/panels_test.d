// Module unittests for `ui.panels`, moved verbatim out of source/ui/panels.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ui.panels_test;

import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv;
import std.json : JSONValue, JSONType;
import http_server;
import log : logInfo, logWarn, logError;
import perf_probe : g_fc, DrawPass;  // always-on per-frame work counters
import prefs;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import d_imgui.imgui_demo;
import imgui_impl_sdl2;
import imgui_impl_opengl3;
import nfde;
import math;
import mesh;
import eventlog;
import handler;
import pipe_gizmo_host : PipeGizmoHost;
import tool;
import editmode;
import seltype;
import toolpipe;
import operator         : VectorStack;
import toolpipe.packets : SubjectPacket;
import toolpipe.pipeline : g_pipeCtx;
import gizmo;
import view;
import viewgrid : g_viewGrid, viewGridSizeFor, viewGridFadeRadius;
import shader;
import perf_probe : g_perf, Cat, g_frames, Phase, FrameRec, FrameStatsSnapshot;
import io.assimp_runtime : initAssimp, shutdownAssimp, isAssimpAvailable;
import ui.availability : actionRefusal, recordDrawnButton;
import symmetry_pick : symmetricSelectVertex, symmetricSelectEdge, symmetricSelectFace;
import bvh_pick : BvhPick;
import tools.transform.transform;
import tools.transform.move;
import tools.deform.push;
import tools.deform.bend;
import tools.alignment.linear_align_tool;
import tools.alignment.radial_align_tool;
import tools.transform.scale;
import tools.transform.rotate;
import tools.create.box;
import tools.alignment.mirror;
import tools.alignment.radial_sweep_tool;
import tools.create.sphere;
import tools.create.cylinder;
import tools.create.cone;
import tools.create.capsule;
import tools.create.torus;
import tools.create.arc;
import tools.create.tube;
import tools.create.pen;
import tools.create.vertex_place : VertexTool;
import tools.edit.edge_extrude : EdgeExtrudeTool;
import tools.edit.edge_extend : EdgeExtendTool;
import tools.slice.edge_slide : EdgeSlideTool;
import tools.edit.poly_extrude : PolyExtrudeTool;
import tools.alignment.radial_array_tool : RadialArrayTool;
import tools.edit.poly_bevel : PolyBevelTool;
import tools.edit.poly_inset_tool : PolyInsetTool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.deform.magnet : MagnetTool;
import tools.edit.edge_bevel : EdgeBevelTool;
import tools.slice.loop_slice_tool : LoopSliceTool;
import tools.slice.slice_tool : SliceTool;
import tools.slice.edge_slice_tool : EdgeSliceTool;
import tools.edit.reduce : ReductionTool;
import tools.alignment.clone_tool : CloneTool;
import tools.alignment.array_tool : ArrayTool;
import tools.edit.tack : TackTool;
import tools.edit.bridge_tool : BridgeTool;
import tools.edit.vert_merge_tool : VertexMergeTool;
import tools.edit.vertex_bevel_tool : VertexBevelTool;
import tools.edit.vertex_extrude_tool : VertexExtrudeTool;
import tools.deform.stroke_extrude_tool : StrokeExtrudeTool;
import tools.common.command_wrapper : XfrmSmoothTool, XfrmJitterTool, XfrmQuantizeTool;
import commands.select.connect;
import commands.select.expand;
import commands.select.contract;
import commands.select.loop;
import commands.select.ring;
import commands.select.invert;
import commands.select.more;
import commands.select.less;
import commands.select.between;
import commands.select.type_from : SelectTypeFromCommand;
import commands.select.drop     : SelectDropCommand;
import commands.select.element  : SelectElementCommand;
import commands.select.convert  : SelectConvertCommand;
import commands.select.fill     : SelectFillHoles, SelectFillInsideLoop;
import commands.viewport.fit_selected;
import commands.viewport.fit;
import commands.file.load;
import commands.file.save;
import commands.mesh.subdivide;
import commands.mesh.subdivide_faceted;
import commands.mesh.triple      : MeshTriple;
import commands.mesh.quadruple   : MeshQuadruple;
import commands.mesh.detriangulate : MeshDetriangulate;
import commands.mesh.merge         : MeshMergeFaces;
import commands.mesh.subpatch_toggle;
import commands.mesh.set_material;
import commands.mesh.set_part;
import commands.tool.headless : ToolHeadlessCommand;
import commands.mesh.split_edge;
import commands.mesh.add_point : MeshAddPoint;
import commands.mesh.split_face  : MeshSplitFace;
import commands.mesh.edge_join : MeshEdgeJoin;
import commands.mesh.spin_edge;
import commands.mesh.loop_slice : MeshAddLoop, MeshLoopSlice;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.edge_extrude : MeshEdgeExtrude;
import commands.mesh.vertex_extrude : MeshVertexExtrude;
import commands.mesh.vertex_bevel   : MeshVertexBevel;
import commands.mesh.poly_inset : MeshPolygonInset;
import commands.mesh.spikey : MeshSpikey;
import commands.mesh.bevel : MeshBevel;
import commands.mesh.face_extrude : MeshFaceExtrude;
import commands.mesh.bridge : MeshBridge;
import commands.mesh.thicken : MeshThicken;
import commands.mesh.smooth_shift : MeshSmoothShift;
import commands.mesh.edge_extend : MeshEdgeExtend;
import commands.mesh.move_vertex;
import commands.mesh.vertex_new    : MeshVertexNew;
import commands.mesh.vertex_center : MeshCenterVertices;
import commands.mesh.vertex_set    : MeshSetPosition;
import commands.mesh.delete_ : MeshDelete;
import commands.mesh.remove_ : MeshRemove;
import commands.mesh.flip    : MeshFlip;
import commands.mesh.duplicate_ : MeshDuplicate;
import commands.mesh.copy_      : MeshCopy;
import commands.mesh.paste_     : MeshPaste;
import commands.mesh.cut_       : MeshCut;
import commands.mesh.mirror_      : MeshMirror;
import commands.mesh.symmetrize   : MeshSymmetrize;
import commands.mesh.array_       : MeshArray;
import commands.mesh.clone_       : MeshClone;
import commands.mesh.radial_array_ : MeshRadialArray;
import commands.mesh.sweep         : MeshSweep;
import commands.mesh.stroke_extrude      : MeshStrokeExtrude;
import commands.mesh.vert_merge        : MeshVertMerge;
import commands.mesh.weld_vertex_pair  : MeshWeldVertexPair;
import commands.mesh.vert_join         : MeshVertJoin;
import commands.mesh.axis_slice    : MeshAxisSlice, MeshJulienne;
import commands.mesh.screen_slice  : MeshScreenSlice;
import commands.mesh.edge_slice    : MeshEdgeSlice;
import commands.mesh.collapse      : MeshCollapse;
import commands.mesh.vertex_split  : MeshVertexSplit;
import commands.mesh.reduce        : MeshReduce;
import commands.mesh.unify         : MeshUnify;
import commands.mesh.cleanup       : MeshCleanup;
import commands.mesh.fix_orientation : MeshFixOrientation;
import commands.mesh.make_polygon  : MeshMakePolygon;
import commands.mesh.select;
import commands.mesh.selection_edit : MeshSelectionEdit;
import commands.mesh.transform;
import commands.mesh.quantize;
import commands.mesh.jitter;
import commands.mesh.magnet : MeshMagnet;
import commands.mesh.smooth;
import commands.mesh.weightmap;
import commands.mesh.uv_transform;
import commands.mesh.uv_project  : UvProject;
import commands.mesh.uv_pack     : UvFit, UvPack;
import commands.mesh.uv_map_util;
import commands.mesh.uv_relax  : UvRelax;
import commands.mesh.uv_unwrap : UvUnwrap;
import commands.mesh.edge_slide;
import commands.mesh.linear_align;
import commands.mesh.polygon_align;
import commands.mesh.radial_align;
import commands.mesh.vertex_edit;
import commands.scene.reset;
import commands.scene.load_mesh;
import commands.history.undo : HistoryUndo;
import commands.history.redo : HistoryRedo;
import commands.history.show : HistoryShow;
import commands.history.clear : HistoryClear;
import commands.test_undo_flags : UndoSuppressNoop, UndoForceNoop;
import commands.history.save_as_script : HistorySaveAsScript;
import commands.macros.record : MacroRecord;
import commands.macros.save_recorded : MacroSaveRecorded;
import macro_recorder : MacroRecorder;
import snapshot : SelectionSnapshot;
import commands.tool.host     : ToolHost;
import commands.tool.set      : ToolSetCommand;
import commands.tool.attr     : ToolAttrCommand;
import commands.layer.commands : LayerAttr, layerDeleteButtonState;
import ui.image_rows : ImageRow, imageRowsInto, imageRemoveTarget,
                       elidedPathText, kNoImagesText;
import commands.tool.do_apply : ToolDoApplyCommand;
import commands.tool.reset    : ToolResetCommand;
import commands.tool.pipe     : ToolPipeAttrCommand;
import commands.tool.begin_session : ToolBeginSessionCommand;
import commands.ui.tool_properties : UiToolPropertiesCommand, g_toolPropertiesShown;
import commands.ui.layer_list      : UiLayerListCommand, g_layerListShown;
import commands.ui.viewport_props  : UiViewportPropsCommand, g_viewportPropsShown;
import commands.tool.panel_edit    : ToolPanelEditCommand;
import commands.snap.toggle_type : SnapToggleTypeCommand;
import commands.snap.mode        : SnapModeCommand;
import commands.ai.toggle    : AiToggleCommand, AiToggleAction;
import commands.falloff        : FalloffAddCommand, FalloffRemoveCommand,
                                  FalloffAutoSizeCommand;
import commands.path.define    : PathDefineCommand;
import commands.workplane     : WorkplaneResetCommand, WorkplaneEditCommand,
                                WorkplaneRotateCommand, WorkplaneOffsetCommand,
                                WorkplaneAlignToSelectionCommand;
import command;
import registry;
import shortcuts;
import buttonset;
import ai.debug_trace : latestHandleDebugTraceJson;
import ai.element_candidates : publishElementCandidates,
    collectElementCandidates, resolveElementCandidateDecision;
import ai.interaction : AiAdvisorDecision, AiCandidate, AiInteractionContext,
    AiInteractionPhase, AiIntent;
import ai.interaction_log : AiInteractionLogRecord, makeAiInteractionLogRecord;
import ai.interaction_log_writer : AiInteractionLogWriter, defaultLiveSource;
import ai.exploration : AiExplorationController, buildCandidateKey,
    defaultExploreSource, OptionalGrab, Resolution, ResolutionKind;
import ai.state      : EditorAiState;
import ai.advisor    : AiAdvisor;
import ai.copilot_gate : kCopilotEnabled;
import ai.model_adapter : AiModelAdapter, AiModelAdapterConfig,
    AiModelAvailability, AiModelStatus, AiModelFallbackMode,
    aiModelAdapterMinConfidence;
import args_dialog    : ArgsDialog;
import ai3d.job_controller       : Ai3dJobController, Ai3dClientJoinTimeoutMs;
import ai3d.job_events           : Ai3dEvent, Ai3dEventKind;
import ai3d.stage_artifact       : Ai3dDefaultRequestedFaces, Ai3dMaxGenerationDeadlineMs;
import ai3d.scene_validator      : Ai3dMaxTotalFaces;
import ai3d.worker_manager       : Ai3dWorkerManager, Ai3dWorkerState,
    Ai3dInstallState, ai3dDefaultInstallLocation, ai3dDefaultWorkerUrl;
import core.time : MonoTime;  // phase-B drawAi3dModal: MonoTime.currTime health-poll throttle
import commands.ai3d.import_result : Ai3dImportResult;
import remesh.remesh_job         : RemeshJob, RemeshParams,
    MAX_REMESH_TARGET_QUADS, MIN_REMESH_TARGET_QUADS;
import commands.mesh.remesh      : Remesh, RemeshStart, RemeshOpen;
import property_panel : PropertyPanel;
import forms_render;
import layer_params   : LayerPropsProvider, itemPropsTarget;
import document       : Layer, Document, kindInfo, tokenOf;
import snap           : ItemSnapFrame;
import viewport       : LayoutPreset, ViewportManager, Viewport3D;
import ui.panels;

unittest { // compiler capability shapes for the finite borrowed roles
    import ui.panel_host_roles;
    static assert([__traits(allMembers, TabLayoutBorrow)] == ["tabPosPtr", "tabSizePtr", "tabPos", "tabSize"]);
    static assert([__traits(allMembers, SideLayoutBorrow)] == ["sidePosPtr", "sideSizePtr", "sidePos", "sideSize"]);
    static assert([__traits(allMembers, StatusLayoutBorrow)] == ["statusPosPtr", "statusSizePtr", "statusPos", "statusSize"]);
    static assert([__traits(allMembers, TabPanelRole)] == ["layout", "panelsPtr", "activePanelIdxPtr", "panels", "activePanelIdx", "testMode"]);
    static assert([__traits(allMembers, SidePanelRole)] == ["layout", "panelsPtr", "activePanelIdxPtr", "activeToolIdPtr", "shortcutsPtr", "regPtr", "sessionOwner", "meshDg", "kGenerateAiAvailable", "panels", "activePanelIdx", "activeToolId", "shortcuts", "reg", "document", "editMode", "mesh", "testMode"]);
    static assert([__traits(allMembers, StatusPanelRole)] == ["layout", "statusLineGroupsPtr", "activeToolIdPtr", "shortcutsPtr", "regPtr", "sessionOwner", "meshDg", "kAiToggleAvailable", "kCopilotEnabled", "statusLineGroups", "activeToolId", "shortcuts", "reg", "document", "editMode", "selTypeOrder", "mesh", "testMode"]);
}

unittest { // desktop presentation bindings borrow each original live slot
    import editor_app : EditorApp, Layout, bindPanelHostRoles, kGenerateAiAvailable,
        kAiToggleAvailable;
    import ui.panel_host_roles;
    import session_owner : Session;
    import editor_app : Layout;
    import buttonset : Panel, Group;
    import registry : Registry;
    import shortcuts : ShortcutTable;
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
    app.meshDg = &currentMesh;
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
    assert(&side.mesh == &secondMesh, "W18 side late Mesh lookup");
    assert(&status.mesh == &secondMesh, "W18 status late Mesh lookup");
    assert(&side.document == &owner.document, "W18 side sole Session Document");
    assert(&status.document == &owner.document, "W18 status sole Session Document");
    assert(&side.editMode == &owner.editMode, "W18 side sole Session EditMode");
    assert(&status.editMode == &owner.editMode, "W18 status sole Session EditMode");
    assert(&status.selTypeOrder == &owner.selTypeOrder, "W18 status sole Session selection order");
}

version (web) {} else unittest { // scalar modal refs and live worker slots keep desktop custody
    import editor_app : EditorApp, Ai3dModalState, bindPanelHostRoles;
    import ui.panel_host_roles : Ai3dPanelRole;
    import core.time : MonoTime;
    import ai3d.job_controller : Ai3dJobController;
    import ai3d.worker_manager : Ai3dWorkerManager;
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
    const factory = blankNonCode(readText(buildPath(root, "source/editor_app.d")));
    const app = blankNonCode(readText(buildPath(root, "source/app.d")));
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
