module tests.unit.edit_tool_registration_test;

import command : Command;
import commands.mesh.session_edit : MeshSessionEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import editmode : EditMode;
import mesh : Mesh;
import registration : registerTools;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import tool : Tool;
import tools.slice.loop_slice_tool : LoopSliceTool;

import std.meta : AliasSeq;
import std.traits : BaseClassesTuple;

private struct ExpectedBinding {
    string id;
    string factory;
}

private enum ExpectedBinding[] kEditBindings = [
    ExpectedBinding("mesh.dragWeld", "bevelEditFactory"),
    ExpectedBinding("edge.extrude", "edgeExtrudeEditFactory"),
    ExpectedBinding("poly.extrude", "polyExtrudeEditFactory"),
    ExpectedBinding("mesh.radialArrayTool", "radialArrayEditFactory"),
    ExpectedBinding("tool.strokeExtrude", "strokeExtrudeEditFactory"),
    ExpectedBinding("edge.extend", "edgeExtendEditFactory"),
    ExpectedBinding("poly.bevel", "bevelEditFactory"),
    ExpectedBinding("mesh.polyInsetTool", "bevelEditFactory"),
    ExpectedBinding("mesh.smoothShiftTool", "smoothShiftEditFactory"),
    ExpectedBinding("xfrm.magnet", "vxEditFactory"),
    ExpectedBinding("edge.bevel", "bevelEditFactory"),
    ExpectedBinding("mesh.vertexBevel", "bevelEditFactory"),
    ExpectedBinding("mesh.vertexExtrude", "bevelEditFactory"),
    ExpectedBinding("vert.merge", "bevelEditFactory"),
    ExpectedBinding("mesh.loopSliceTool", "loopSliceEditFactory"),
    ExpectedBinding("mesh.sliceTool", "bevelEditFactory"),
    ExpectedBinding("mesh.edgeSliceTool", "bevelEditFactory"),
    ExpectedBinding("mesh.reduceTool", "reduceEditFactory"),
    ExpectedBinding("mesh.clone", "cloneEditFactory"),
    ExpectedBinding("mesh.arrayTool", "arrayEditFactory"),
];

private F fieldOf(F, T)(T obj, string name) {
    static foreach (C; AliasSeq!(T, BaseClassesTuple!T)) {
        foreach (i, ref f; (cast(C) obj).tupleof)
            if (__traits(identifier, C.tupleof[i]) == name)
                static if (is(typeof(f) : F)) return cast(F) f;
    }
    assert(0, "6670 reflection floor: no field named " ~ name
        ~ " convertible to " ~ F.stringof ~ " on " ~ T.stringof);
}

private LiveRegistrationRig registeredRig() {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    rig.wireEditToolDeps();
    registerTools(rig.app);
    return rig;
}

// The production composition root owns the complete edit-family population,
// and every retained gesture factory is its own named collaborator.
unittest {
    static assert(kEditBindings.length == 20);
    auto rig = registeredRig();
    foreach (binding; kEditBindings) {
        assert(rig.registry.hasTool(binding.id),
            "6670 population: registry lacks tool " ~ binding.id);
        Tool tool = rig.registry.toolFactory(binding.id)();
        auto gesture = fieldOf!(Command delegate())(tool, "gestureFactory");
        assert(gesture !is null,
            "6670 binding: " ~ binding.id ~ " retained a null gesture factory");
        auto product = gesture();
        assert(product !is null,
            "6670 binding: " ~ binding.id ~ " built a null command");
        if (binding.id == "xfrm.magnet") {
            assert(cast(MeshVertexEdit) product !is null,
                "6670 binding: xfrm.magnet did not retain vxEditFactory");
        } else {
            auto cmd = cast(MeshSessionEdit) product;
            assert(cmd !is null,
                "6670 binding: " ~ binding.id ~ " did not build MeshSessionEdit");
            assert(cmd.name() == "probe." ~ binding.factory,
                "6670 binding: " ~ binding.id ~ " built " ~ cmd.name()
                ~ ", expected probe." ~ binding.factory);
        }
    }
}

// A tool built before the primary-layer switch still samples the live mesh.
unittest {
    auto rig = registeredRig();
    auto tool = cast(LoopSliceTool)
        rig.registry.toolFactory("mesh.loopSliceTool")();
    auto meshSrc = fieldOf!(Mesh* delegate())(tool, "meshSrc_");
    assert(meshSrc() is &rig.layerA.meshRef(),
        "6670 live mesh floor: edit tool did not begin on layer A");
    rig.switchToB();
    assert(meshSrc() is &rig.layerB.meshRef(),
        "6670 live mesh: edit tool retained the registration-time Mesh");
}

// The mode collaborator is the session's live cell, not a copied value.
unittest {
    auto rig = registeredRig();
    auto tool = cast(LoopSliceTool)
        rig.registry.toolFactory("mesh.loopSliceTool")();
    auto mode = fieldOf!(EditMode*)(tool, "editMode");
    assert(*mode == EditMode.Vertices,
        "6670 live mode floor: edit tool did not begin in vertex mode");
    rig.switchToB();
    assert(*mode == EditMode.Polygons,
        "6670 live mode: edit tool retained the registration-time mode");
}
