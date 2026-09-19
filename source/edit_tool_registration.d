module edit_tool_registration;

import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import mesh_gpu : GpuMesh;
import pipe_gizmo_host : PipeGizmoHost;
import registry : Registry, typedToolFactory;
import shader : LitShader;
import tools.alignment.array_tool : ArrayTool;
import tools.alignment.clone_tool : CloneTool;
import tools.alignment.radial_array_tool : RadialArrayTool;
import tools.deform.magnet : MagnetTool;
import tools.deform.smooth_shift_tool : SmoothShiftTool;
import tools.deform.stroke_extrude_tool : StrokeExtrudeTool;
import tools.edit.drag_weld : DragWeldTool;
import tools.edit.edge_bevel : EdgeBevelTool;
import tools.edit.edge_extend : EdgeExtendTool;
import tools.edit.edge_extrude : EdgeExtrudeTool;
import tools.edit.poly_bevel : PolyBevelTool;
import tools.edit.poly_extrude : PolyExtrudeTool;
import tools.edit.poly_inset_tool : PolyInsetTool;
import tools.edit.reduce : ReductionTool;
import tools.edit.vert_merge_tool : VertexMergeTool;
import tools.edit.vertex_bevel_tool : VertexBevelTool;
import tools.edit.vertex_extrude_tool : VertexExtrudeTool;
import tools.slice.edge_slice_tool : EdgeSliceTool;
import tools.slice.loop_slice_tool : LoopSliceTool;
import tools.slice.slice_tool : SliceTool;

import std.traits : FieldNameTuple;

/// The edit family's eleven snapshot factories. They deliberately retain the
/// EditorApp field names: every value has the same delegate type, so the
/// composition root binds them by name instead of by a fragile position
/// (task 6670).
struct EditSessionFactories {
    MeshSessionEdit delegate() bevelEditFactory;
    MeshSessionEdit delegate() loopSliceEditFactory;
    MeshSessionEdit delegate() reduceEditFactory;
    MeshSessionEdit delegate() cloneEditFactory;
    MeshSessionEdit delegate() arrayEditFactory;
    MeshSessionEdit delegate() edgeExtrudeEditFactory;
    MeshSessionEdit delegate() edgeExtendEditFactory;
    MeshSessionEdit delegate() polyExtrudeEditFactory;
    MeshSessionEdit delegate() radialArrayEditFactory;
    MeshSessionEdit delegate() smoothShiftEditFactory;
    MeshSessionEdit delegate() strokeExtrudeEditFactory;
}

/// Explicit collaborators owned by edit-tool registration.
struct EditToolDeps {
private:
    GpuMesh* gpu_;
    LitShader litShader_;
    CommandHistory history_;
    PipeGizmoHost pipeGizmoHost_;
    MeshVertexEdit delegate() vxEditFactory_;
    EditSessionFactories sessions_;

public:
    @disable this();

    this(GpuMesh* gpu, LitShader litShader, CommandHistory history,
            PipeGizmoHost pipeGizmoHost,
            MeshVertexEdit delegate() vxEditFactory,
            EditSessionFactories sessions) {
        assert(gpu !is null, "edit registration requires a GPU mesh");
        assert(history !is null, "edit registration requires command history");
        assert(vxEditFactory !is null,
            "edit registration requires a vertex-edit factory");
        static assert(FieldNameTuple!EditSessionFactories.length == 11);
        static foreach (field; FieldNameTuple!EditSessionFactories)
            assert(__traits(getMember, sessions, field) !is null,
                "6670 edit registration requires session factory " ~ field);
        gpu_ = gpu;
        litShader_ = litShader;
        history_ = history;
        pipeGizmoHost_ = pipeGizmoHost;
        vxEditFactory_ = vxEditFactory;
        sessions_ = sessions;
    }

    GpuMesh* gpu() nothrow @nogc { return gpu_; }
    LitShader litShader() nothrow @nogc { return litShader_; }
    CommandHistory history() nothrow @nogc { return history_; }
    PipeGizmoHost pipeGizmoHost() nothrow @nogc { return pipeGizmoHost_; }
    MeshVertexEdit delegate() vxEditFactory() nothrow @nogc {
        return vxEditFactory_;
    }
    MeshSessionEdit delegate() bevelEditFactory() nothrow @nogc {
        return sessions_.bevelEditFactory;
    }
    MeshSessionEdit delegate() loopSliceEditFactory() nothrow @nogc {
        return sessions_.loopSliceEditFactory;
    }
    MeshSessionEdit delegate() reduceEditFactory() nothrow @nogc {
        return sessions_.reduceEditFactory;
    }
    MeshSessionEdit delegate() cloneEditFactory() nothrow @nogc {
        return sessions_.cloneEditFactory;
    }
    MeshSessionEdit delegate() arrayEditFactory() nothrow @nogc {
        return sessions_.arrayEditFactory;
    }
    MeshSessionEdit delegate() edgeExtrudeEditFactory() nothrow @nogc {
        return sessions_.edgeExtrudeEditFactory;
    }
    MeshSessionEdit delegate() edgeExtendEditFactory() nothrow @nogc {
        return sessions_.edgeExtendEditFactory;
    }
    MeshSessionEdit delegate() polyExtrudeEditFactory() nothrow @nogc {
        return sessions_.polyExtrudeEditFactory;
    }
    MeshSessionEdit delegate() radialArrayEditFactory() nothrow @nogc {
        return sessions_.radialArrayEditFactory;
    }
    MeshSessionEdit delegate() smoothShiftEditFactory() nothrow @nogc {
        return sessions_.smoothShiftEditFactory;
    }
    MeshSessionEdit delegate() strokeExtrudeEditFactory() nothrow @nogc {
        return sessions_.strokeExtrudeEditFactory;
    }
}

/// Register the edit, slice, and duplication tool family with explicit live
/// roles and narrow collaborators.
void registerEditToolCommands(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, EditToolDeps deps) {
    // Drag Weld — drag a source vertex onto a target vertex to weld them.
    // LMB-down picks the source; LMB-up picks the target; one snapshot-undo
    // entry per completed gesture. Gated to Vertices mode.
    reg.registerTool("mesh.dragWeld", typedToolFactory!DragWeldTool(() {
        auto t = new DragWeldTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }));

    // Edge Extrude — interactive (drag → extrude/width) + headless
    // (tool.attr edge.extrude extrude/width; tool.doApply). Topology-creating
    // tool: own typed edit factory (MeshSessionEdit, not vxEditFactory),
    // wired via the prim.cube registration template. Gated to Edges mode by
    // EdgeExtrudeTool.supportedModes().
    reg.registerTool("edge.extrude", typedToolFactory!EdgeExtrudeTool(() {
        auto t = new EdgeExtrudeTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.edgeExtrudeEditFactory());
        return t;
    }));

    // Face Extrude — interactive (drag → distance along region normal) + headless
    // (tool.attr poly.extrude distance <v>; tool.doApply). Topology-creating
    // tool: own typed edit factory (MeshSessionEdit, snapshot-only undo).
    // Gated to Polygons mode by PolyExtrudeTool.supportedModes().
    reg.registerTool("poly.extrude", typedToolFactory!PolyExtrudeTool(() {
        auto t = new PolyExtrudeTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.polyExtrudeEditFactory());
        return t;
    }));

    // Radial Array — interactive (angle-cube haul → End Angle; axis-arrow haul
    // → Offset; off-handle click → reposition Center) + headless (tool.attr
    // mesh.radialArrayTool count/axis/center/angle/offset/weld; tool.doApply).
    // Reuses the shared Mesh.radialArrayFaces kernel (same-mesh clone
    // insertion, no new layers) already exercised by the one-shot
    // mesh.radial_array command. Topology-creating tool: own typed edit
    // factory (MeshSessionEdit, snapshot-only undo).
    reg.registerTool("mesh.radialArrayTool", typedToolFactory!RadialArrayTool(() {
        auto t = new RadialArrayTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.radialArrayEditFactory());
        return t;
    }));

    // Stroke Extrude — interactive (click-drag draws a camera-raycast
    // world-space path, selected polygons extrude along it in bands) +
    // headless via the separate one-shot mesh.strokeExtrude command
    // (explicit path-point param — the interactive tool itself has NO
    // headless path, matching the captured reference finding). Task 0323,
    // basic/captured scope. Topology-creating tool: own typed edit factory
    // (MeshSessionEdit, snapshot-only undo). Gated to Polygons mode
    // by StrokeExtrudeTool.supportedModes().
    reg.registerTool("tool.strokeExtrude", typedToolFactory!StrokeExtrudeTool(() {
        auto t = new StrokeExtrudeTool(() => &owner.activeMesh(), deps.gpu(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.strokeExtrudeEditFactory());
        return t;
    }));

    // Edge Extend — interactive (drag → world-axis Offset via the embedded
    // transform gizmo's Move bank) + headless (tool.attr edge.extend offsetX...;
    // tool.doApply). Topology-creating tool: own typed edit factory
    // (MeshSessionEdit). Gated to Edges mode by EdgeExtendTool.supportedModes().
    reg.registerTool("edge.extend", typedToolFactory!EdgeExtendTool(() {
        auto t = new EdgeExtendTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.edgeExtendEditFactory());
        t.setPipeGizmoHost(deps.pipeGizmoHost());
        return t;
    }));

    // Poly Bevel — interactive + headless (inset, shift params). Topology-creating
    // tool: reuses bevelEditFactory (MeshSessionEdit snapshot undo). Gated to Polygons.
    reg.registerTool("poly.bevel", typedToolFactory!PolyBevelTool(() {
        auto t = new PolyBevelTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }));
    // Polygon Inset — interactive (task 0359 promotion of the one-shot
    // mesh.poly_inset command). One attribute (inset), always per-polygon,
    // no drawn gizmo (toolcard-confirmed) — a generic viewport click+drag
    // hauls the value. Reuses the generic MeshSessionEdit/bevelEditFactory
    // before/after-snapshot undo path, same as mesh.mirrorTool/mesh.tack
    // above. Gated to Polygons.
    reg.registerTool("mesh.polyInsetTool", typedToolFactory!PolyInsetTool(() {
        auto t = new PolyInsetTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }));

    // Smooth Shift + Thicken — interactive (2 handles: Offset, Scale) + headless
    // (tool.attr mesh.smoothShiftTool shift/scale/maxAngle/thicken/sharp <v>;
    // tool.doApply). Topology-creating tool: own typed edit factory
    // (MeshSessionEdit, snapshot-only undo). Gated to Polygons mode by
    // SmoothShiftTool.supportedModes(). The reference editor's Thicken toolbar
    // button is confirmed (task 0358) to be THIS SAME tool with thicken=1
    // forced, not a separate tool — see config/buttons.yaml.
    reg.registerTool("mesh.smoothShiftTool", typedToolFactory!SmoothShiftTool(() {
        auto t = new SmoothShiftTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.smoothShiftEditFactory());
        return t;
    }));
    // TASK 1905 — `vxEditFactory` is spent at TEN sites across the registrar
    // family: nine in transform_tool_registration.d and this xfrm.magnet
    // gesture binding. The census keeps the per-file split explicit.
    //
    // THE G1 NOTE HERE SAID "FOURTEEN … the other thirteen", AND SAID THE
    // SPLIT WOULD BE RESOLVED WHEN THE APP-LEVEL CLOSURES COLLAPSED IN GROUP
    // G8. Both halves were wrong and group G8 re-measured them (2026-08-29).
    // The count was thirteen before phase B — twelve transform sites plus this
    // one. The unified-transform recipe collapsed four of those sites to one,
    // but changes nothing about which binder the transform tools DECLARE.
    //
    // WHAT G8 DID SETTLE. The temptation the note warned about was "unify the
    // factory alias", and what made it dangerous was that `VertexEditFactory`
    // named TWO different delegate types in this tree (`MeshSessionEdit
    // delegate()` in `vertex_place.d` / `drag_weld.d`, `MeshVertexEdit
    // delegate()` in `transform.d` / `xfrm_transform.d`), so a swap re-typed
    // two tools and both kept compiling. Phases B and C deleted both
    // `MeshSessionEdit` spellings along with the binders that used them: two
    // declarations remain and both name `MeshVertexEdit delegate()`. There is
    // nothing left to unify — and nothing in the compiler keeps it that way,
    // so member 4 of `tests/unit/tool_commit_seam_census_g8_test.d` does: a
    // third alias naming a different type reddens there by file and line.
    //
    // WHAT IS LEFT IS NOT THIS TASK'S. Transform-zone bindings stay on
    // `setUndoBindings` because that zone is OUT of task 1905's scope by
    // decision D1. Member 6 of the same census pins the ten-site 9/1 split,
    // and member 5 pins the surviving binder declarations.
    reg.registerTool("xfrm.magnet", typedToolFactory!MagnetTool(() {
        auto t = new MagnetTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell());
        t.setGestureBindings(deps.history(), deps.vxEditFactory());
        return t;
    }));

    // Edge Bevel — interactive + headless (width param). Topology-creating tool:
    // reuses bevelEditFactory (MeshSessionEdit snapshot undo). Gated to Edges mode.
    reg.registerTool("edge.bevel", typedToolFactory!EdgeBevelTool(() {
        auto t = new EdgeBevelTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }));

    // Vertex Bevel — interactive (task 0360 promotion of the one-shot
    // mesh.vertexBevel command). Single-handle Inset, ACTR-anchored,
    // mirrors EdgeBevelTool one element type down. Reuses bevelEditFactory
    // (MeshSessionEdit snapshot undo) and the SAME id as the pre-existing
    // one-shot command (`mesh.vertexBevel` below,
    // untouched) — separate registries, same precedent as poly.extrude/
    // mesh.mirrorTool elsewhere in this file. Gated to Vertices mode.
    reg.registerTool("mesh.vertexBevel", typedToolFactory!VertexBevelTool(() {
        auto t = new VertexBevelTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }));

    // Vertex Extrude — interactive (task 0360 promotion of the one-shot
    // mesh.vertexExtrude command). Two independent handles (Extrude/shift,
    // Width) mirroring PolyBevelTool's Shift/Inset pair. Reuses
    // bevelEditFactory (MeshSessionEdit snapshot undo); same id as the
    // pre-existing one-shot command, separate registries (see
    // mesh.vertexBevel above). Gated to Vertices mode.
    reg.registerTool("mesh.vertexExtrude", typedToolFactory!VertexExtrudeTool(() {
        auto t = new VertexExtrudeTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }));

    // Vertex Merge — interactive (task 0360 promotion of the one-shot
    // vert.merge command). No drawn handle — a generic viewport haul, same
    // family as mesh.polyInsetTool. Reuses bevelEditFactory (MeshSessionEdit
    // snapshot undo); same id as the pre-existing one-shot command (which
    // keeps its own range/keep/morph params, untouched — see
    // tools/vert_merge_tool.d's doc-comment). Gated to Vertices mode.
    reg.registerTool("vert.merge", typedToolFactory!VertexMergeTool(() {
        auto t = new VertexMergeTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }));

    // Loop Slice — hover-seeded interactive edge-loop cut. Topology-creating
    // tool: reuses the SAME collectEdgeRing/insertEdgeLoops kernel as the
    // mesh.loopSlice/mesh.addLoop commands (untouched); mutate/revert preview,
    // one MeshSessionEdit undo entry PER committed cut. Gated to Edges mode.
    reg.registerTool("mesh.loopSliceTool", typedToolFactory!LoopSliceTool(() {
        auto t = new LoopSliceTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.loopSliceEditFactory());
        return t;
    }));

    // Slice (plane/line) — interactive Start→End line cut with a plane
    // PERPENDICULAR to the work plane (mesh.sliceTool, task 0266 S0). Reuses
    // mesh_ops.cut.cutByPlane; one MeshSnapshot undo entry per committed slice
    // (reuses the generic bevelEditFactory snapshot command, labelled "Slice").
    // Distinct from the camera-plane one-shot mesh.screenSlice command.
    reg.registerTool("mesh.sliceTool", typedToolFactory!SliceTool(() {
        auto t = new SliceTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        // TASK 1905 — `bevelEditFactory` is spent at TWENTY-FOUR sites across
        // registrar modules: fifteen create-family uses and nine edit-family
        // uses here. All twenty-four are on the base seam; zero are left on a
        // tool's own `setUndoBindings` overload. G8 pins the 15/9 split.
        //
        // THE LOAD-BEARING HALF IS UNCHANGED: all twenty-four record under the
        // SAME wire name `mesh.bevel_edit`, so the two wire ids below are
        // indistinguishable in undo history and in a replay, which is why G5's
        // "exactly one cell reddens" mutations key on the plane dumps rather
        // than on `entryNames` for this pair. The count is pinned by member 6
        // of `tests/unit/tool_commit_seam_census_g8_test.d`.
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }));

    // Edge Slice — interactive two-edge strip cut (mesh.edgeSliceTool):
    // hover an edge -> click latches edge A + tA -> drag scrubs tA -> click a
    // second edge latches edge B + tB and previews the cut live -> commit on
    // Enter / tool-drop / a third click. Reuses the EXISTING
    // Mesh.edgeSlice(edgeA, edgeB, tA, tB, splitPolygons) kernel; one
    // MeshSessionEdit undo entry per committed cut (reuses the generic
    // bevelEditFactory snapshot command, labelled "Edge Slice"). The one-shot
    // mesh.edgeSlice command stays registered below for headless/scripting.
    // Gated to Edges mode.
    reg.registerTool("mesh.edgeSliceTool", typedToolFactory!EdgeSliceTool(() {
        auto t = new EdgeSliceTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.bevelEditFactory());
        return t;
    }));

    // Mesh Reduction — interactive + headless (ratio, preserveBoundary params).
    // Whole-mesh decimation via reduceToTarget; snapshot undo via MeshSessionEdit.
    // Gated to Polygons mode (whole-mesh op, but surfaced in polygon mode).
    reg.registerTool("mesh.reduceTool", typedToolFactory!ReductionTool(() {
        auto t = new ReductionTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell(), deps.litShader());
        t.setGestureBindings(deps.history(), deps.reduceEditFactory());
        return t;
    }));

    // Clone — interactive drag-place a single copy of the selection (offset
    // by the drag delta on the most-facing screen plane).  Snapshot undo via
    // MeshSessionEdit; gated to Polygons mode.  Drag→offset feel is a
    // vibe3d-divergence (no reference tool-model; uses planeDragDelta).
    reg.registerTool("mesh.clone", typedToolFactory!CloneTool(() {
        auto t = new CloneTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell());
        t.setGestureBindings(deps.history(), deps.cloneEditFactory());
        return t;
    }));

    // Array — interactive 3-axis grid array (task 0355), promoting the
    // one-shot mesh.array command's 1D line kernel to Mesh.arrayFacesGrid.
    // Snapshot undo via MeshSessionEdit; edit-mode-orthogonal (same face-
    // selection-or-whole-mesh convention as mesh.array/mesh.mirror).
    reg.registerTool("mesh.arrayTool", typedToolFactory!ArrayTool(() {
        auto t = new ArrayTool(() => &owner.activeMesh(), deps.gpu(), live.modeCell());
        t.setGestureBindings(deps.history(), deps.arrayEditFactory());
        return t;
    }));
}
