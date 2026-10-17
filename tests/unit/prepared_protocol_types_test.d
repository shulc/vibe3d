// Compiler-owned prepared-protocol contracts (task 20263060).
module tests.unit.prepared_protocol_types_test;

import std.algorithm : canFind;
import std.traits : ReturnType, Parameters, ParameterStorageClassTuple, functionAttributes;
import vibe3d.editing.tools.interactive.tool : Tool;
import vibe3d.editing.params.params : Param;
import vibe3d.editing.pipeline.contracts.operator : VectorStack;

static import vibe3d.editing.commands.runtime.command_history;
static import vibe3d.editing.tools.interactive.tool;
static import vibe3d.editing.tools.interactive.tools.alignment.array_tool;
static import vibe3d.editing.tools.interactive.tools.alignment.clone_tool;
static import vibe3d.editing.tools.interactive.tools.alignment.linear_align_tool;
static import vibe3d.editing.tools.interactive.tools.alignment.mirror;
static import vibe3d.editing.tools.interactive.tools.alignment.radial_align_tool;
static import vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool;
static import vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool;
static import vibe3d.editing.tools.interactive.tools.common.command_wrapper;
static import vibe3d.editing.tools.interactive.tools.create.arc;
static import vibe3d.editing.tools.interactive.tools.create.box;
static import vibe3d.editing.tools.interactive.tools.create.capsule;
static import vibe3d.editing.tools.interactive.tools.create.cone;
static import vibe3d.editing.tools.interactive.tools.create.cylinder;
static import vibe3d.editing.tools.interactive.tools.create.pen;
static import vibe3d.editing.tools.interactive.tools.create.primitive_create_tool;
static import vibe3d.editing.tools.interactive.tools.create.sphere;
static import vibe3d.editing.tools.interactive.tools.create.torus;
static import vibe3d.editing.tools.interactive.tools.create.tube;
static import vibe3d.editing.tools.interactive.tools.create.vertex_place;
static import vibe3d.editing.tools.interactive.tools.deform.bend;
static import vibe3d.editing.tools.interactive.tools.deform.magnet;
static import vibe3d.editing.tools.interactive.tools.deform.push;
static import vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool;
static import vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool;
static import vibe3d.editing.tools.interactive.tools.edit.bridge_tool;
static import vibe3d.editing.tools.interactive.tools.edit.edge_bevel;
static import vibe3d.editing.tools.interactive.tools.edit.edge_extend;
static import vibe3d.editing.tools.interactive.tools.edit.edge_extrude;
static import vibe3d.editing.tools.interactive.tools.edit.poly_bevel;
static import vibe3d.editing.tools.interactive.tools.edit.poly_extrude;
static import vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool;
static import vibe3d.editing.tools.interactive.tools.edit.reduce;
static import vibe3d.editing.tools.interactive.tools.edit.tack;
static import vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool;
static import vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool;
static import vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool;
static import vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool;
static import vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool;
static import vibe3d.editing.tools.interactive.tools.slice.edge_slide;
static import vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool;
static import vibe3d.editing.tools.interactive.tools.slice.slice_tool;
static import vibe3d.editing.tools.interactive.tools.transform.move;
static import vibe3d.editing.tools.interactive.tools.transform.rotate;
static import vibe3d.editing.tools.interactive.tools.transform.scale;
static import vibe3d.editing.tools.interactive.tools.transform.transform;
static import vibe3d.editing.tools.interactive.tools.transform.xfrm_transform;

private void expectedVoid() {}
private void expectedString(string value) {}
private void expectedRef(ref VectorStack value) {}
private Param[] expectedParams() { return null; }

private template checkWriter(string mod, string owner, string member, string signature) {
    alias Aggregate = __traits(getMember, mixin(mod), owner);
    alias actual = __traits(getMember, Aggregate, member);
    static if (signature == "void()") alias expected = expectedVoid;
    else static if (signature == "void(string name)" || signature == "void(string pname)")
        alias expected = expectedString;
    else static if (signature == "void(ref VectorStack vts)") alias expected = expectedRef;
    else static if (signature == "Param[]()") alias expected = expectedParams;
    else static assert(false, "unknown prepared writer signature: " ~ signature);
    static assert(__traits(isSame, __traits(parent, actual), Aggregate),
        mod ~ "." ~ owner ~ "." ~ member ~ " lost its declared owner");
    static assert(is(ReturnType!actual == ReturnType!expected));
    static assert(is(Parameters!actual == Parameters!expected));
    static assert(ParameterStorageClassTuple!actual == ParameterStorageClassTuple!expected);
    static assert(functionAttributes!actual == functionAttributes!expected);
    enum checkWriter = true;
}

// Function bodies and source coordinates are free to change.
static assert(checkWriter!("vibe3d.editing.tools.interactive.tool", "Tool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tool", "Tool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tool", "Tool", "update", "void(ref VectorStack vts)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tool", "Tool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.array_tool", "ArrayTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.array_tool", "ArrayTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.array_tool", "ArrayTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.clone_tool", "CloneTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.clone_tool", "CloneTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.clone_tool", "CloneTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.linear_align_tool", "LinearAlignTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.mirror", "MirrorTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.mirror", "MirrorTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.mirror", "MirrorTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_align_tool", "RadialAlignTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool", "RadialArrayTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool", "RadialArrayTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool", "RadialArrayTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool", "RadialSweepTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool", "RadialSweepTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool", "RadialSweepTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.common.command_wrapper", "CommandWrapperTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.common.command_wrapper", "CommandWrapperTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.common.command_wrapper", "CommandWrapperTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.arc", "ArcTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.arc", "ArcTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.box", "BoxTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.box", "BoxTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.box", "BoxTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.pen", "PenTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.pen", "PenTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.pen", "PenTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.pen", "PenTool", "update", "void(ref VectorStack vts)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.primitive_create_tool", "PrimitiveCreateTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.primitive_create_tool", "PrimitiveCreateTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.sphere", "SphereTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.vertex_place", "VertexTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.bend", "BendTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.magnet", "MagnetTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.magnet", "MagnetTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.magnet", "MagnetTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.push", "PushTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool", "SmoothShiftTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool", "SmoothShiftTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool", "SmoothShiftTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool", "StrokeExtrudeTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool", "StrokeExtrudeTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.bridge_tool", "BridgeTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.bridge_tool", "BridgeTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.bridge_tool", "BridgeTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_bevel", "EdgeBevelTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_bevel", "EdgeBevelTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_bevel", "EdgeBevelTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_extend", "EdgeExtendTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_extend", "EdgeExtendTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_extend", "EdgeExtendTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_extend", "EdgeExtendTool", "update", "void(ref VectorStack vts)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_extrude", "EdgeExtrudeTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_extrude", "EdgeExtrudeTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_extrude", "EdgeExtrudeTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_bevel", "PolyBevelTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_bevel", "PolyBevelTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_bevel", "PolyBevelTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_extrude", "PolyExtrudeTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_extrude", "PolyExtrudeTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_extrude", "PolyExtrudeTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool", "PolyInsetTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool", "PolyInsetTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool", "PolyInsetTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.reduce", "ReductionTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.reduce", "ReductionTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.reduce", "ReductionTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.tack", "TackTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.tack", "TackTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool", "TopologyPenTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool", "TopologyPenTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool", "TopologyPenTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool", "TopologyPenTool", "update", "void(ref VectorStack vts)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool", "VertexMergeTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool", "VertexMergeTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool", "VertexMergeTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool", "VertexBevelTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool", "VertexBevelTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool", "VertexBevelTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool", "VertexExtrudeTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool", "VertexExtrudeTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool", "VertexExtrudeTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool", "EdgeSliceTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool", "EdgeSliceTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool", "EdgeSliceTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool", "LoopSliceTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool", "LoopSliceTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool", "LoopSliceTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.slice_tool", "SliceTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.slice_tool", "SliceTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.slice_tool", "SliceTool", "onParamChanged", "void(string pname)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.move", "MoveTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.move", "MoveTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.rotate", "RotateTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.rotate", "RotateTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.scale", "ScaleTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.scale", "ScaleTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.transform", "TransformTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.transform", "TransformTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.xfrm_transform", "XfrmTransformTool", "activate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.xfrm_transform", "XfrmTransformTool", "deactivate", "void()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.xfrm_transform", "XfrmTransformTool", "update", "void(ref VectorStack vts)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.xfrm_transform", "XfrmTransformTool", "onParamChanged", "void(string name)"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tool", "Tool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.array_tool", "ArrayTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.clone_tool", "CloneTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.linear_align_tool", "LinearAlignTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.mirror", "MirrorTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_align_tool", "RadialAlignTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool", "RadialArrayTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool", "RadialSweepTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.common.command_wrapper", "CommandWrapperTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.arc", "ArcTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.box", "BoxTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.capsule", "CapsuleTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.cone", "ConeTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.cylinder", "CylinderTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.pen", "PenTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.sphere", "SphereTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.torus", "TorusTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.tube", "TubeTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.create.vertex_place", "VertexTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.bend", "BendTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.magnet", "MagnetTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.push", "PushTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool", "SmoothShiftTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool", "StrokeExtrudeTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.bridge_tool", "BridgeTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_bevel", "EdgeBevelTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_extend", "EdgeExtendTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.edge_extrude", "EdgeExtrudeTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_bevel", "PolyBevelTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_extrude", "PolyExtrudeTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool", "PolyInsetTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.reduce", "ReductionTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.tack", "TackTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool", "TopologyPenTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool", "VertexMergeTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool", "VertexBevelTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool", "VertexExtrudeTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool", "EdgeSliceTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool", "LoopSliceTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.slice.slice_tool", "SliceTool", "params", "Param[]()"));
static assert(checkWriter!("vibe3d.editing.tools.interactive.tools.transform.xfrm_transform", "XfrmTransformTool", "params", "Param[]()"));

// Products that intentionally inherit Tool's no-op lifecycle hook.
private enum string[] baseActivate = ["VertexTool"];
private enum string[] baseDeactivate = [];
private enum string[] baseUpdate = ["ArcTool", "ArrayTool", "BendTool", "BoxTool", "BridgeTool", "CapsuleTool", "CloneTool", "ConeTool", "CylinderTool", "EdgeBevelTool", "EdgeExtrudeTool", "EdgeSliceTool", "EdgeSlideTool", "LinearAlignTool", "LoopSliceTool", "MagnetTool", "MirrorTool", "PolyBevelTool", "PolyExtrudeTool", "PolyInsetTool", "PushTool", "RadialAlignTool", "RadialArrayTool", "RadialSweepTool", "ReductionTool", "SliceTool", "SmoothShiftTool", "SphereTool", "StrokeExtrudeTool", "TackTool", "TorusTool", "TubeTool", "VertexBevelTool", "VertexExtrudeTool", "VertexMergeTool", "VertexTool", "XfrmJitterTool", "XfrmQuantizeTool", "XfrmSmoothTool"];

private template checkProduct(string mod, string name) {
    alias Product = __traits(getMember, mixin(mod), name);
    static assert(is(Product == class));
    static foreach (hook; ["activate", "deactivate", "update"]) {
        static assert(__traits(isSame,
            __traits(parent, __traits(getMember, Product, hook)), Tool) ==
            (hook == "activate" ? baseActivate.canFind(name) :
             hook == "deactivate" ? baseDeactivate.canFind(name) : baseUpdate.canFind(name)),
            name ~ "." ~ hook ~ " changed its inherited no-op contract");
    }
    enum checkProduct = true;
}

static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.arc", "ArcTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.alignment.array_tool", "ArrayTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.deform.bend", "BendTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.box", "BoxTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.bridge_tool", "BridgeTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.capsule", "CapsuleTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.alignment.clone_tool", "CloneTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.cone", "ConeTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.cylinder", "CylinderTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.edge_bevel", "EdgeBevelTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.edge_extend", "EdgeExtendTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.edge_extrude", "EdgeExtrudeTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool", "EdgeSliceTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.slice.edge_slide", "EdgeSlideTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.alignment.linear_align_tool", "LinearAlignTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool", "LoopSliceTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.deform.magnet", "MagnetTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.alignment.mirror", "MirrorTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.pen", "PenTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.poly_bevel", "PolyBevelTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.poly_extrude", "PolyExtrudeTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.poly_inset_tool", "PolyInsetTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.deform.push", "PushTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.alignment.radial_align_tool", "RadialAlignTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.alignment.radial_array_tool", "RadialArrayTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool", "RadialSweepTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.reduce", "ReductionTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.slice.slice_tool", "SliceTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.deform.smooth_shift_tool", "SmoothShiftTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.sphere", "SphereTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.deform.stroke_extrude_tool", "StrokeExtrudeTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.tack", "TackTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.topology_pen.tool", "TopologyPenTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.torus", "TorusTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.tube", "TubeTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.vertex_bevel_tool", "VertexBevelTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.vertex_extrude_tool", "VertexExtrudeTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.edit.vert_merge_tool", "VertexMergeTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.create.vertex_place", "VertexTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.common.command_wrapper", "XfrmJitterTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.common.command_wrapper", "XfrmQuantizeTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.common.command_wrapper", "XfrmSmoothTool"));
static assert(checkProduct!("vibe3d.editing.tools.interactive.tools.transform.xfrm_transform", "XfrmTransformTool"));

// getMember names the private type without exporting it or modifying production.
static assert(!__traits(isCopyable, __traits(getMember,
    vibe3d.editing.commands.runtime.command_history, "PreparedHistoryBatch")));
