module tests.unit.transform_tool_registration_test;

import command : Command;
import command_history : CommandHistory;
import commands.mesh.morph_edit : MeshMorphEdit;
import document : Layer;
import editmode : EditMode;
import mesh : Mesh;
import pipe_gizmo_host : PipeGizmoHost;
import seltype : SelMode;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import tool : Tool;
import tools.alignment.linear_align_tool : LinearAlignTool;
import tools.alignment.radial_align_tool : RadialAlignTool;
import tools.common.command_wrapper : CommandWrapperTool, XfrmJitterTool,
    XfrmQuantizeTool, XfrmSmoothTool;
import tools.deform.bend : BendTool;
import tools.deform.push : PushTool;
import tools.slice.edge_slide : EdgeSlideTool;
import tools.transform.xfrm_transform : XfrmTransformTool;
import tools.transform.transform : TransformTool;

import std.algorithm : canFind;
import std.file : readText;
import std.meta : AliasSeq;
import std.path : buildPath, dirName;
import std.string : indexOf, splitLines, startsWith, strip;
import std.traits : BaseClassesTuple;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private F fieldOf(F, T)(T obj, string name) {
    static foreach (C; AliasSeq!(T, BaseClassesTuple!T)) {
        foreach (i, ref f; (cast(C) obj).tupleof)
            if (__traits(identifier, C.tupleof[i]) == name)
                static if (is(typeof(f) : F)) return cast(F) f;
    }
    assert(0, "6506 reflection floor: no field named " ~ name
        ~ " convertible to " ~ F.stringof ~ " on " ~ T.stringof);
}

private bool expectedProduct(string id, Tool tool) {
    switch (id) {
        case "move", "rotate", "scale", "xfrm.transform":
            return cast(XfrmTransformTool) tool !is null;
        case "xfrm.push": return cast(PushTool) tool !is null;
        case "xfrm.bend": return cast(BendTool) tool !is null;
        case "xfrm.linearAlignTool": return cast(LinearAlignTool) tool !is null;
        case "xfrm.radialAlignTool": return cast(RadialAlignTool) tool !is null;
        case "xfrm.smooth": return cast(XfrmSmoothTool) tool !is null;
        case "xfrm.jitter": return cast(XfrmJitterTool) tool !is null;
        case "edge.slide": return cast(EdgeSlideTool) tool !is null;
        case "xfrm.quantize": return cast(XfrmQuantizeTool) tool !is null;
        default: return false;
    }
}

private immutable string[] kIds = [
    "move", "rotate", "scale", "xfrm.transform",
    "xfrm.push", "xfrm.bend", "xfrm.linearAlignTool",
    "xfrm.radialAlignTool", "xfrm.smooth", "xfrm.jitter",
    "edge.slide", "xfrm.quantize",
];

// Block 1: production population, concrete products, and the eight bindings
// that class identity alone cannot prove.
unittest {
    assert(kIds.length == 12, "6506 population floor: expected twelve ids");
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    auto first = rig.buildTransform(kIds[0]);
    assert(first !is null, "6506 population: first production build failed");

    foreach (id; kIds) {
        auto slot = id in rig.registry.toolFactories;
        assert(slot !is null, "6506 population: registry lacks " ~ id);
        auto a = (*slot)();
        auto b = (*slot)();
        assert(a !is null && b !is null && a !is b,
            "6506 population: factory must return fresh non-null products for " ~ id);
        assert(expectedProduct(id, a),
            "6506 product class changed for " ~ id);

        if (["xfrm.push", "xfrm.bend", "xfrm.linearAlignTool",
                "xfrm.radialAlignTool"].canFind(id)) {
            auto deform = cast(TransformTool) a;
            assert(fieldOf!CommandHistory(deform, "history") is rig.history,
                "6506 deform history binding changed for " ~ id);
            assert(fieldOf!(MeshMorphEdit delegate())(deform,
                    "morphEditFactory") is null,
                "6506 deform unexpectedly gained a morph carrier for " ~ id);
        }
        if (["xfrm.smooth", "xfrm.jitter", "edge.slide",
                "xfrm.quantize"].canFind(id)) {
            auto convolve = cast(CommandWrapperTool) a;
            assert(fieldOf!PipeGizmoHost(convolve, "pipeGizmoHost") !is null,
                "6506 convolve pipe-gizmo binding changed for " ~ id);
            assert(fieldOf!CommandHistory(convolve, "history") is rig.history,
                "6506 convolve history binding changed for " ~ id);
        }
    }
}

// Block 2: mesh resolution has three distinct timing contracts.
unittest {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    assert(rig.layerA.meshRef().vertices.length == 8
        && rig.layerB.meshRef().vertices.length == 6,
        "6506 mesh floor: expected cube and octahedron");

    auto unified = cast(XfrmTransformTool) rig.buildTransform("move");
    auto deform = cast(PushTool) rig.buildTransform("xfrm.push");
    auto convolveA = cast(XfrmSmoothTool) rig.buildTransform("xfrm.smooth");
    auto oldMesh = convolveA.preparedActivationMesh();
    rig.switchToB();
    assert(unified.preparedMeshForUpdate() is &rig.session.editMesh(),
        "6506 unified mesh source froze before the primary switch");
    assert(fieldOf!(Mesh* delegate())(deform, "meshSrc_")()
            is &rig.session.editMesh(),
        "6506 deform mesh source froze before the primary switch");
    auto convolveB = cast(XfrmSmoothTool) rig.buildTransform("xfrm.smooth");
    assert(convolveB.preparedActivationMesh() is &rig.session.editMesh()
        && oldMesh is &rig.layerA.meshRef(),
        "6506 convolve: second factory call after primary switch returned old mesh");
}

// Block 3: pointer-backed unified mode stays live; value-backed convolve mode
// is sampled by each factory invocation.
unittest {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    assert(rig.session.editMode == EditMode.Vertices,
        "6506 mode floor: rig must begin in vertex mode");
    auto unified = cast(XfrmTransformTool) rig.buildTransform("move");
    auto before = cast(XfrmSmoothTool) rig.buildTransform("xfrm.smooth");
    rig.switchToB();
    auto after = cast(XfrmSmoothTool) rig.buildTransform("xfrm.smooth");
    assert(*fieldOf!(EditMode*)(unified, "editMode") == EditMode.Polygons,
        "6506 unified mode pointer froze before switchGeometryType");
    assert(fieldOf!Command(before, "inner").editModeVal() == EditMode.Vertices
        && fieldOf!Command(after, "inner").editModeVal() == EditMode.Polygons,
        "6506 convolve mode does not follow switchGeometryType");
}

// Block 4: each convolve construction samples the current view cell.
unittest {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    assert(rig.cells[0] !is rig.cells[1],
        "6506 view floor: expected distinct cells");
    auto a = cast(XfrmSmoothTool) rig.buildTransform("xfrm.smooth");
    rig.activeCell = 1;
    auto b = cast(XfrmSmoothTool) rig.buildTransform("xfrm.smooth");
    assert(fieldOf!(typeof(rig.cells[0]))(a, "viewRef") is rig.cells[0]
        && fieldOf!(typeof(rig.cells[0]))(b, "viewRef") is rig.cells[1],
        "6506 convolve viewRef does not follow the active cell");
}

// Block 5: the moved recipe retains all four declared defaults, and every
// preset base that enters this family resolves to one of those ids.
unittest {
    struct Row { string id; bool t, r, s; int family; string presentation; }
    immutable rows = [
        Row("move", true, false, false, 0, "full"),
        Row("rotate", false, true, false, 1, "full"),
        Row("scale", false, false, true, 2, "full"),
        Row("xfrm.transform", true, true, true, 0, "compact"),
    ];
    assert(rows.length == 4, "6506 defaults floor: expected four unified rows");
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    foreach (row; rows) {
        auto t = cast(XfrmTransformTool) rig.buildTransform(row.id);
        assert(t.flagT == row.t && t.flagR == row.r && t.flagS == row.s
            && t.handleFamily == row.family
            && t.handlePresentation == row.presentation,
            "6506 moved defaults changed for " ~ row.id);
    }

    foreach (line; readText(buildPath(repoRoot, "config", "tool_presets.yaml"))
            .splitLines()) {
        auto text = line.strip;
        if (!text.startsWith("base:")) continue;
        auto base = text["base:".length .. $].strip;
        if (kIds.canFind(base))
            assert((base in rig.registry.toolFactories) !is null,
                "6506 preset base does not resolve: " ~ base);
    }
}

// Block 6: item targets are resolved through the live document on every call.
unittest {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    auto t = cast(XfrmTransformTool) rig.buildTransform("move");
    auto targets = fieldOf!(void delegate(ref Layer[]))(t, "itemTargetsSrc_");
    Layer[] buf;
    targets(buf);
    assert(buf.length == 1 && buf[0] is rig.layerA,
        "6506 item targets floor: primary A was not resolved");
    // setPrimary is an ordering operation and deliberately preserves the
    // existing selected set; make B exclusive before moving it to the head.
    rig.session.document.selectItem(rig.layerB, SelMode.Set);
    rig.session.document.setPrimary(rig.layerB);
    targets(buf);
    assert(buf.length == 1 && buf[0] is rig.layerB,
        "6506 item targets froze primary A");
    rig.session.document.selectItem(rig.layerA, SelMode.Add);
    targets(buf);
    assert(buf.length == 2 && buf.canFind(rig.layerA) && buf.canFind(rig.layerB),
        "6506 item targets did not resolve the live selected set");
}
