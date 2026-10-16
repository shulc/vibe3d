module vibe3d.apps.desktop.mesh_command_registration;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.util.spatial.spatial : Viewport;
import vibe3d.editing.tools.interactive.registry : Registry;
import vibe3d.runtime.remesh.remesh.remesh_job : RemeshJob;
import vibe3d.editing.commands.editor.commands.mesh.subdivide;
import vibe3d.editing.commands.editor.commands.mesh.subdivide_faceted;
import vibe3d.runtime.application_core.pilot_command_registration : PilotCommandDeps, registerTripleCommand,
    registerMeshSelectionCommand;
import vibe3d.editing.commands.editor.commands.mesh.quadruple   : MeshQuadruple;
import vibe3d.editing.commands.editor.commands.mesh.detriangulate : MeshDetriangulate;
import vibe3d.editing.commands.editor.commands.mesh.merge         : MeshMergeFaces;
import vibe3d.editing.commands.editor.commands.mesh.subpatch_toggle;
import vibe3d.editing.commands.editor.commands.mesh.hide;
import vibe3d.editing.commands.editor.commands.mesh.set_material;
import vibe3d.editing.commands.editor.commands.mesh.surface_attr : MeshSurfaceAttr;
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
import vibe3d.editing.commands.editor.commands.mesh.transform;
import vibe3d.editing.commands.editor.commands.mesh.quantize;
import vibe3d.editing.commands.editor.commands.mesh.jitter;
import vibe3d.editing.commands.editor.commands.mesh.magnet : MeshMagnet;
import vibe3d.editing.commands.editor.commands.mesh.smooth;
import vibe3d.editing.commands.editor.commands.mesh.weightmap;
import vibe3d.editing.commands.editor.commands.mesh.morph;
import vibe3d.editing.commands.editor.commands.mesh.edge_crease;
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
import vibe3d.editing.commands.editor.commands.mesh.remesh : Remesh, RemeshOpen, RemeshStart;

struct MeshCommandDeps {
private:
    void delegate() meshRebuildDrop_;
    Viewport delegate() originSnapshot_;
    RemeshJob remeshJob_;
    void delegate() requestRemeshOpen_;
    void delegate(EditMode) promoteGeometryType_;

public:
    @disable this();

    this(void delegate() meshRebuildDrop, Viewport delegate() originSnapshot,
            RemeshJob remeshJob, void delegate() requestRemeshOpen,
            void delegate(EditMode) promoteGeometryType) {
        assert(meshRebuildDrop !is null,
            "6509 mesh registration requires a rebuild drop door");
        assert(originSnapshot !is null,
            "6509 mesh registration requires a resolved viewport provider");
        assert(promoteGeometryType !is null,
            "6509 mesh registration requires the geometry promote door");
        assert(remeshJob !is null,
            "6509 mesh registration requires the remesh job");
        assert(requestRemeshOpen !is null,
            "6509 mesh registration requires the remesh open door");
        remeshJob_ = remeshJob;
        requestRemeshOpen_ = requestRemeshOpen;
        meshRebuildDrop_ = meshRebuildDrop;
        originSnapshot_ = originSnapshot;
        promoteGeometryType_ = promoteGeometryType;
    }

    void delegate() meshRebuildDrop() nothrow @nogc {
        return meshRebuildDrop_;
    }

    Viewport delegate() originSnapshot() nothrow @nogc {
        return originSnapshot_;
    }

    RemeshJob remeshJob() nothrow @nogc {
        return remeshJob_;
    }

    void delegate() requestRemeshOpen() nothrow @nogc {
        return requestRemeshOpen_;
    }

    void delegate(EditMode) promoteGeometryType() nothrow @nogc {
        return promoteGeometryType_;
    }
}

/// Register mesh, polygon, vertex and UV commands against explicit live roles
/// and the five narrow capabilities that the family consumes.
/// Sliced CONTIGUOUSLY, so the order in which keys are written is exactly what
/// it was; and every key in the table is written exactly once, so order is not
/// load-bearing between families.
void registerMeshCommands(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, MeshCommandDeps deps) {
    auto regPtr = &reg;
    import vibe3d.mesh.core.mesh : Mesh;
    import vibe3d.viewport.camera.view : View;
    ref Mesh pilotMesh() { return owner.activeMesh(); }
    ref View pilotView() { return live.view(); }
    auto pilot = PilotCommandDeps(&pilotMesh, &pilotView, live.modeCell(),
        deps.originSnapshot(), deps.promoteGeometryType(), deps.meshRebuildDrop());
    reg.registerCommand("mesh.subdivide", () => cast(Command)
        new Subdivide(&owner.activeMesh(), live.view(), live.mode(),
                      deps.meshRebuildDrop()));
    {
        // Quad Remesh (source/remesh/remesh_job.d): `mesh.remesh.start` kicks off
        // the async helper (HTTP/menu-triggerable — see remeshJob.poll() near
        // the ai3d drain for how the result lands); `mesh.remesh` is the
        // undoable apply that a successful job's result is fired through.
        reg.registerCommand("mesh.remesh.start", () => cast(Command)
            new RemeshStart(&owner.activeMesh(), live.view(), live.mode(), deps.remeshJob()));
        reg.registerCommand("mesh.remesh", () => cast(Command)
            new Remesh(&owner.activeMesh(), live.view(), live.mode(),
                       deps.meshRebuildDrop(), deps.remeshJob()));
        reg.registerCommand("mesh.remesh.open", () => cast(Command)
            new RemeshOpen(&owner.activeMesh(), live.view(), live.mode(), deps.requestRemeshOpen()));
    }
    reg.registerCommand("mesh.subdivide_faceted", () => cast(Command)
        new SubdivideFaceted(&owner.activeMesh(), live.view(), live.mode(),
                             deps.meshRebuildDrop()));
    registerTripleCommand(reg, pilot);
    reg.registerCommand("mesh.quadruple", () => cast(Command)
        new MeshQuadruple(&owner.activeMesh(), live.view(), live.mode(),
                          deps.meshRebuildDrop()));
    reg.registerCommand("mesh.detriangulate", () => cast(Command)
        new MeshDetriangulate(&owner.activeMesh(), live.view(), live.mode(),
                              deps.meshRebuildDrop()));
    reg.registerCommand("mesh.mergeFaces", () => cast(Command)
        new MeshMergeFaces(&owner.activeMesh(), live.view(), live.mode(),
                           deps.meshRebuildDrop()));
    reg.registerCommand("mesh.subpatch_toggle", () => cast(Command)
        new SubpatchToggle(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.hide", () => cast(Command)
        new MeshHide(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.hideUnselected", () => cast(Command)
        new MeshHideUnselected(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.hideInvert", () => cast(Command)
        new MeshHideInvert(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.unhideAll", () => cast(Command)
        new MeshUnhideAll(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.setMaterial", () => cast(Command)
        new MeshSetMaterial(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.surfaceAttr", () => cast(Command)
        new MeshSurfaceAttr(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.setPart", () => cast(Command)
        new MeshSetPart(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.split_edge", () => cast(Command)
        new MeshSplitEdge(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.addPoint", () => cast(Command)
        new MeshAddPoint(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.splitFace", () => cast(Command)
        new MeshSplitFace(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.edgeJoin", () => cast(Command)
        new MeshEdgeJoin(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.spinEdge", () => cast(Command)
        new MeshSpinEdge(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.addLoop", () => cast(Command)
        new MeshAddLoop(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.loopSlice", () => cast(Command)
        new MeshLoopSlice(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.edge_extrude", () => cast(Command)
        new MeshEdgeExtrude(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.vertexExtrude", () => cast(Command)
        new MeshVertexExtrude(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.vertexBevel", () => cast(Command)
        new MeshVertexBevel(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.poly_inset", () => cast(Command)
        new MeshPolygonInset(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.spikey", () => cast(Command)
        new MeshSpikey(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.bevel", () => cast(Command)
        new MeshBevel(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("poly.extrude", () => cast(Command)
        new MeshFaceExtrude(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.bridge", () => cast(Command)
        new MeshBridge(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.axisSlice", () => cast(Command)
        new MeshAxisSlice(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.julienne", () => cast(Command)
        new MeshJulienne(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.screenSlice", () {
        auto c = new MeshScreenSlice(&owner.activeMesh(), live.view(), live.mode());
        // Viewport camera single-source (0181): resolve the camera-plane cut
        // through the follow-aware snapshot instead of the cell's raw own
        // transform — see command.d's effectiveViewport() for the fallback
        // hazard note.
        c.setResolvedVpProvider(deps.originSnapshot());
        return cast(Command) c;
    });
    reg.registerCommand("mesh.edgeSlice", () => cast(Command)
        new MeshEdgeSlice(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.thicken", () => cast(Command)
        new MeshThicken(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.smooth_shift", () => cast(Command)
        new MeshSmoothShift(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.edge_extend", () => cast(Command)
        new MeshEdgeExtend(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.move_vertex", () => cast(Command)
        new MeshMoveVertex(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.addVertex", () => cast(Command)
        new MeshVertexNew(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.centerVertices", () => cast(Command)
        new MeshCenterVertices(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.setPosition", () => cast(Command)
        new MeshSetPosition(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.delete", () => cast(Command)
        new MeshDelete(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.remove", () => cast(Command)
        new MeshRemove(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.flip", () => cast(Command)
        new MeshFlip(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.duplicate", () => cast(Command)
        new MeshDuplicate(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.copy", () => cast(Command)
        new MeshCopy(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.paste", () => cast(Command)
        new MeshPaste(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.cut", () => cast(Command)
        new MeshCut(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.mirror", () => cast(Command)
        new MeshMirror(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.symmetrize", () => cast(Command)
        new MeshSymmetrize(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.array", () => cast(Command)
        new MeshArray(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.clone", () => cast(Command)
        new MeshClone(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.radial_array", () => cast(Command)
        new MeshRadialArray(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.sweep", () => cast(Command)
        new MeshSweep(&owner.activeMesh(), live.view(), live.mode()));
    // One-shot, headlessly-testable path-follow extrude (task 0323 —
    // explicit world-space path-point param; see MeshStrokeExtrude's doc
    // comment). The interactive tool.strokeExtrude drives its own commit
    // through the separate record-flavor MeshSessionEdit instead of
    // this factory.
    reg.registerCommand("mesh.strokeExtrude", () => cast(Command)
        new MeshStrokeExtrude(&owner.activeMesh(), live.view(), live.mode()));
    // Aliases — select.delete and select.remove delegate to the
    // same factory delegates as mesh.delete / mesh.remove respectively.
    reg.aliasCommand("mesh.delete", "select.delete");
    reg.aliasCommand("mesh.remove", "select.remove");
    reg.registerCommand("vert.merge", () => cast(Command)
        new MeshVertMerge(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.weldVertexPair", () => cast(Command)
        new MeshWeldVertexPair(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("poly.unify", () => cast(Command)
        new MeshUnify(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.cleanup", () => cast(Command)
        new MeshCleanup(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.fixOrientation", () => cast(Command)
        new MeshFixOrientation(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("vert.join", () => cast(Command)
        new MeshVertJoin(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.collapse", () => cast(Command)
        new MeshCollapse(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.vertexSplit", () => cast(Command)
        new MeshVertexSplit(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.reduce", () => cast(Command)
        new MeshReduce(&owner.activeMesh(), live.view(), live.mode()));
    // No promote hook: Make Polygon leaves the selection type alone (task 7132).
    reg.registerCommand("mesh.makePolygon", () => cast(Command)
        new MeshMakePolygon(&owner.activeMesh(), live.view(), live.mode()));
    registerMeshSelectionCommand(reg, pilot);
    reg.registerCommand("mesh.transform", () {
        auto c = new MeshTransform(&owner.activeMesh(), live.view(), live.mode());
        // Viewport camera single-source (0181): see mesh.screenSlice above.
        c.setResolvedVpProvider(deps.originSnapshot());
        return cast(Command) c;
    });
    reg.registerCommand("mesh.quantize", () => cast(Command)
        new MeshQuantize(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.jitter", () => cast(Command)
        new MeshJitter(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.magnet", () => cast(Command)
        new MeshMagnet(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.weightmap.create", () => cast(Command)
        new WeightmapCreate(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.weightmap.remove", () => cast(Command)
        new WeightmapRemove(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.weightmap.rename", () => cast(Command)
        new WeightmapRename(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.weightmap.set", () => cast(Command)
        new WeightmapSet(&owner.activeMesh(), live.view(), live.mode()));
    // Task 1090. The odd sibling of the four above: it writes the SESSION's
    // current-map name, not the mesh, so it is `CmdFlags.UI` and records no
    // undo entry. Registered here anyway — the map selection belongs to the
    // weight-map family, not to the viewport family, because it is global
    // state about a MESH channel and only its consumer is per-cell.
    reg.registerCommand("mesh.weightmap.select", () => cast(Command)
        new WeightmapSelect(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.morph.create", () => cast(Command)
        new MorphCreate(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.morph.remove", () => cast(Command)
        new MorphRemove(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.morph.rename", () => cast(Command)
        new MorphRename(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.morph.select", () => cast(Command)
        new MorphSelect(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.morph.set", () => cast(Command)
        new MorphSet(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.morph.clear", () => cast(Command)
        new MorphClear(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.morph.apply", () => cast(Command)
        new MorphApplyCmd(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.edgeCrease.set", () => cast(Command)
        new EdgeCreaseSet(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.edgeCrease.clear", () => cast(Command)
        new EdgeCreaseClear(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.flip", () => cast(Command)
        new UvFlip(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.mirror", () => cast(Command)
        new UvMirror(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.rotate", () => cast(Command)
        new UvRotate(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.project", () => cast(Command)
        new UvProject(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.fit", () => cast(Command)
        new UvFit(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.pack", () => cast(Command)
        new UvPack(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.delete", () => cast(Command)
        new UvDelete(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.rename", () => cast(Command)
        new UvRename(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.copy", () => cast(Command)
        new UvCopy(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.clear", () => cast(Command)
        new UvClear(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.relax", () => cast(Command)
        new UvRelax(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("uv.unwrap", () => cast(Command)
        new UvUnwrap(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.edge_slide", () => cast(Command)
        new MeshEdgeSlide(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.smooth", () => cast(Command)
        new MeshSmooth(&owner.activeMesh(), live.view(), live.mode()));
    // Headless aliases for the Convolve tools — same shape
    // as prim.cube above: tool.set <id> on; tool.attr <id> ...;
    // tool.doApply. The command form bundles the activation pair so
    // headless callers don't have to manage the tool lifecycle.
    reg.registerCommand("xfrm.smooth", () => cast(Command)
        new ToolHeadlessCommand(&owner.activeMesh(), live.view(), live.mode(),
                                "xfrm.smooth", regPtr.toolFactory("xfrm.smooth")));
    reg.registerCommand("xfrm.jitter", () => cast(Command)
        new ToolHeadlessCommand(&owner.activeMesh(), live.view(), live.mode(),
                                "xfrm.jitter", regPtr.toolFactory("xfrm.jitter")));
    reg.registerCommand("xfrm.quantize", () => cast(Command)
        new ToolHeadlessCommand(&owner.activeMesh(), live.view(), live.mode(),
                                "xfrm.quantize", regPtr.toolFactory("xfrm.quantize")));
    reg.registerCommand("mesh.linear_align", () => cast(Command)
        new MeshLinearAlign(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.align", () => cast(Command)
        new MeshAlign(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.radial_align", () => cast(Command)
        new MeshRadialAlign(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.vertex_edit", () => cast(Command)
        new MeshVertexEdit(&owner.activeMesh(), live.view(), live.mode()));
    reg.registerCommand("mesh.bevel_edit", () => cast(Command)
        new MeshSessionEdit(&owner.activeMesh(), live.view(), live.mode(),
                          "mesh.bevel_edit", "Bevel"));
}
