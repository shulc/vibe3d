module mesh_command_registration;

import command : Command;
import editmode : EditMode;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import math : Viewport;
import registry : Registry;
version (web) {
} else {
    import remesh.remesh_job : RemeshJob;
}
import commands.mesh.subdivide;
import commands.mesh.subdivide_faceted;
import commands.mesh.triple      : MeshTriple;
import commands.mesh.quadruple   : MeshQuadruple;
import commands.mesh.detriangulate : MeshDetriangulate;
import commands.mesh.merge         : MeshMergeFaces;
import commands.mesh.subpatch_toggle;
import commands.mesh.hide;
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
import commands.mesh.transform;
import commands.mesh.quantize;
import commands.mesh.jitter;
import commands.mesh.magnet : MeshMagnet;
import commands.mesh.smooth;
import commands.mesh.weightmap;
import commands.mesh.morph;
import commands.mesh.edge_crease;
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
version (web) {
} else {
    import commands.mesh.remesh : Remesh, RemeshOpen, RemeshStart;
}

version (web)
    private alias RemeshJobRef = void*;
else
    private alias RemeshJobRef = RemeshJob;

struct MeshCommandDeps {
private:
    void delegate() meshRebuildDrop_;
    Viewport delegate() originSnapshot_;
    version (web) {
    } else {
        RemeshJob remeshJob_;
        void delegate() requestRemeshOpen_;
    }
    void delegate(EditMode) promoteGeometryType_;

public:
    @disable this();

    this(void delegate() meshRebuildDrop, Viewport delegate() originSnapshot,
            RemeshJobRef remeshJob, void delegate() requestRemeshOpen,
            void delegate(EditMode) promoteGeometryType) {
        assert(meshRebuildDrop !is null,
            "6509 mesh registration requires a rebuild drop door");
        assert(originSnapshot !is null,
            "6509 mesh registration requires a resolved viewport provider");
        assert(promoteGeometryType !is null,
            "6509 mesh registration requires the geometry promote door");
        version (web) {
        } else {
            assert(remeshJob !is null,
                "6509 mesh registration requires the remesh job");
            assert(requestRemeshOpen !is null,
                "6509 mesh registration requires the remesh open door");
            remeshJob_ = remeshJob;
            requestRemeshOpen_ = requestRemeshOpen;
        }
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

    version (web) {
    } else {
        RemeshJob remeshJob() nothrow @nogc {
            return remeshJob_;
        }

        void delegate() requestRemeshOpen() nothrow @nogc {
            return requestRemeshOpen_;
        }
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
    reg.registerCommand("mesh.subdivide", () => cast(Command)
        new Subdivide(&owner.activeMesh(), live.view(), live.mode(),
                      deps.meshRebuildDrop()));
    version (web) {
    } else {
        // Quad Remesh (source/remesh/remesh_job.d): `mesh.remesh.start` kicks off
        // the async subprocess (HTTP/menu-triggerable — see remeshJob.poll() near
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
    reg.registerCommand("mesh.triple", () => cast(Command)
        new MeshTriple(&owner.activeMesh(), live.view(), live.mode(),
                       deps.meshRebuildDrop()));
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
    reg.registerCommand("mesh.select", () {
        auto c = new MeshSelect(&owner.activeMesh(), live.view(), live.mode(), live.modeCell());
        c.setPromoteHook(deps.promoteGeometryType());
        // Viewport camera single-source (0181): see mesh.screenSlice above.
        c.setResolvedVpProvider(deps.originSnapshot());
        return cast(Command) c;
    });
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
