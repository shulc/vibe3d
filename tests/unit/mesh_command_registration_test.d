module tests.unit.mesh_command_registration_test;

import command : Command;
import commands.mesh.remesh : Remesh;
import commands.mesh.select : MeshSelect;
import commands.tool.headless : ToolHeadlessCommand;
import editmode : EditMode;
import math : Vec3, Viewport;
import mesh : Mesh, makeCube;
import params : Param;
import registration : registerMeshCommandsForOwnershipTest;
import registry : ToolFactory;
import std.conv : to;
import std.file : readText;
import std.meta : AliasSeq;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;
import std.traits : BaseClassesTuple;
import tests.unit.census_symbols : blankNonCode;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import tool : Tool;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..",
    "..");

private enum string[] kMeshIds = [
    "mesh.subdivide", "mesh.remesh.start", "mesh.remesh", "mesh.remesh.open",
    "mesh.subdivide_faceted", "mesh.triple", "mesh.quadruple", "mesh.detriangulate",
    "mesh.mergeFaces", "mesh.subpatch_toggle", "mesh.hide", "mesh.hideUnselected",
    "mesh.hideInvert", "mesh.unhideAll", "mesh.setMaterial", "mesh.setPart",
    "mesh.split_edge", "mesh.addPoint", "mesh.splitFace", "mesh.edgeJoin",
    "mesh.spinEdge", "mesh.addLoop", "mesh.loopSlice", "mesh.edge_extrude",
    "mesh.vertexExtrude", "mesh.vertexBevel", "mesh.poly_inset", "mesh.spikey",
    "mesh.bevel", "poly.extrude", "mesh.bridge", "mesh.axisSlice",
    "mesh.julienne", "mesh.screenSlice", "mesh.edgeSlice", "mesh.thicken",
    "mesh.smooth_shift", "mesh.edge_extend", "mesh.move_vertex", "mesh.addVertex",
    "mesh.centerVertices", "mesh.setPosition", "mesh.delete", "mesh.remove",
    "mesh.flip", "mesh.duplicate", "mesh.copy", "mesh.paste",
    "mesh.cut", "mesh.mirror", "mesh.symmetrize", "mesh.array",
    "mesh.clone", "mesh.radial_array", "mesh.sweep", "mesh.strokeExtrude",
    "select.delete", "select.remove", "vert.merge", "mesh.weldVertexPair",
    "poly.unify", "mesh.cleanup", "mesh.fixOrientation", "vert.join",
    "mesh.collapse", "mesh.vertexSplit", "mesh.reduce", "mesh.makePolygon",
    "mesh.select", "mesh.transform", "mesh.quantize", "mesh.jitter",
    "mesh.magnet", "mesh.weightmap.create", "mesh.weightmap.remove", "mesh.weightmap.rename",
    "mesh.weightmap.set", "mesh.weightmap.select", "mesh.morph.create", "mesh.morph.remove",
    "mesh.morph.rename", "mesh.morph.select", "mesh.morph.set", "mesh.morph.clear",
    "mesh.morph.apply", "mesh.edgeCrease.set", "mesh.edgeCrease.clear", "uv.flip",
    "uv.mirror", "uv.rotate", "uv.project", "uv.fit",
    "uv.pack", "uv.delete", "uv.rename", "uv.copy",
    "uv.clear", "uv.relax", "uv.unwrap", "mesh.edge_slide",
    "mesh.smooth", "xfrm.smooth", "xfrm.jitter", "xfrm.quantize",
    "mesh.linear_align", "mesh.align", "mesh.radial_align", "mesh.vertex_edit",
    "mesh.bevel_edit",
];

private F fieldOf(F, T)(T obj, string name) {
    static foreach (C; AliasSeq!(T, BaseClassesTuple!T)) {
        foreach (i, ref f; (cast(C) obj).tupleof)
            if (__traits(identifier, C.tupleof[i]) == name)
                static if (is(typeof(f) : F)) return cast(F) f;
    }
    assert(0, "6509 reflection floor: no field named " ~ name
        ~ " convertible to " ~ F.stringof ~ " on " ~ T.stringof);
}

private void setField(F, T)(T obj, string name, F value) {
    static foreach (C; AliasSeq!(T, BaseClassesTuple!T)) {
        foreach (i, ref f; (cast(C) obj).tupleof)
            if (__traits(identifier, C.tupleof[i]) == name)
                static if (is(F : typeof(f))) {
                    f = value;
                    return;
                }
    }
    assert(0, "6509 reflection floor: no writable field named " ~ name
        ~ " on " ~ T.stringof);
}

private final class MarkerTool : Tool {
    int marker;
    this(int value) { marker = value; }
    override Param[] params() {
        return [Param.int_("meshMarker", "Mesh Marker", &marker, marker)];
    }
}

private LiveRegistrationRig wiredRig() {
    auto rig = new LiveRegistrationRig;
    rig.wireEditorApp();
    rig.wireMeshCommandDeps();
    foreach (id; ["xfrm.smooth", "xfrm.jitter", "xfrm.quantize"])
        rig.registry.toolFactories[id] = () => new MarkerTool(0);
    return rig;
}

private LiveRegistrationRig registeredRig() {
    auto rig = wiredRig();
    registerMeshCommandsForOwnershipTest(rig.app);
    return rig;
}

// B1: the production door owns the exact family and every factory reads the
// live edit target when the command is constructed.
unittest {
    static assert(kMeshIds.length == 109);
    auto rig = registeredRig();
    foreach (id; kMeshIds)
        assert(id in rig.registry.commandFactories,
            "6509 population: registry lacks mesh command " ~ id);
    assert(rig.registry.commandFactories["select.delete"]
            is rig.registry.commandFactories["mesh.delete"]
        && rig.registry.commandFactories["select.remove"]
            is rig.registry.commandFactories["mesh.remove"],
        "6509 alias ceiling: select.delete/remove stopped sharing their mesh delegates");
    rig.switchToB();
    foreach (id; kMeshIds) {
        auto command = rig.registry.commandFactories[id]();
        assert(command.meshPtr() is &rig.layerB.meshRef(),
            "6509 live command mesh: " ~ id ~ " retained layer A");
    }
}

// B2: only the three camera-plane consumers receive the follow-resolved,
// live provider rather than the raw cell camera or a registration snapshot.
unittest {
    auto rig = wiredRig();
    rig.vpm.activeId = 0;
    rig.vpm.dragOriginId = -1;
    rig.vpm.views[3].camera.focus = Vec3(37, 0, 0);
    const raw = rig.vpm.views[0].camera;
    const expected = rig.vpm.originSnapshot();
    assert(expected.focus.x == 37.0f && raw.focus.x != expected.focus.x,
        "6509 resolved viewport floor: raw and resolved cameras agree");
    registerMeshCommandsForOwnershipTest(rig.app);
    foreach (id; ["mesh.screenSlice", "mesh.select", "mesh.transform"]) {
        auto command = rig.registry.commandFactories[id]();
        auto provider = fieldOf!(Viewport delegate())(
            command, "resolvedVpProvider");
        assert(provider !is null && provider().focus.x == expected.focus.x,
            "6509 resolved viewport: " ~ id
          ~ " reads the active cell's own camera, not the follow-resolved snapshot");
        rig.vpm.views[3].camera.focus = Vec3(91, 0, 0);
        assert(provider().focus.x == 91.0f,
            "6509 resolved viewport: the provider froze the registration-time snapshot");
        rig.vpm.views[3].camera.focus = Vec3(37, 0, 0);
    }
    auto plain = rig.registry.commandFactories["mesh.subdivide"]();
    assert(fieldOf!(Viewport delegate())(plain, "resolvedVpProvider") is null,
        "6509 resolved viewport ceiling: provider escaped the three consumers");
}

// B3: the full production path wraps the mesh family only after registration.
// Live Item-vs-geometry authority is already distinguished by the shared rig.
unittest {
    const code = blankNonCode(readText(
        buildPath(repoRoot, "source", "registration.d")));
    const familyAt = code.indexOf("registerMeshFamily(app);");
    const wrapAt = code.indexOf(
        "auto selTypeSrc = () => currentSelType(selTypeOrder);");
    assert(familyAt >= 0 && wrapAt >= 0 && familyAt < wrapAt,
        "6509 selection authority: the mesh family no longer precedes the final wrap");
}

// B4: the three Convolve wrappers resolve the tool slot when the command is
// built, after registration, rather than retaining the original factory.
unittest {
    auto rig = registeredRig();
    foreach (i, id; ["xfrm.smooth", "xfrm.jitter", "xfrm.quantize"]) {
        immutable marker = 6509 + cast(int) i;
        ToolFactory probe = () => new MarkerTool(marker);
        rig.registry.toolFactories[id] = probe;
        auto command = cast(ToolHeadlessCommand)
            rig.registry.commandFactories[id]();
        assert(command !is null,
            "6509 late lookup floor: wrapper type changed for " ~ id);
        auto held = fieldOf!ToolFactory(command, "factory");
        assert(held is probe,
            "6509 late lookup: " ~ id ~ " wrapper holds the registration-time "
          ~ "factory, not the one in the registry at fire");
    }
}

// B5/B6: every topology-rebuild command owns the same drop door, while the
// remesh-open command owns the distinct modal door. The remesh result is
// seeded into the command because the external worker is outside a unit lane.
unittest {
    auto rig = registeredRig();
    assert(rig.meshRebuildDrops == 0 && !rig.remeshModalState.open,
        "6509 rebuild-drop floor: doors fired before any command");
    foreach (id; ["mesh.subdivide", "mesh.subdivide_faceted", "mesh.triple",
                  "mesh.quadruple", "mesh.detriangulate", "mesh.mergeFaces",
                  "mesh.remesh"]) {
        rig.session.editMesh() = makeCube();
        rig.session.switchGeometryType(EditMode.Polygons);
        ref Mesh m = rig.session.editMesh();
        if (id == "mesh.quadruple" || id == "mesh.detriangulate"
                || id == "mesh.mergeFaces") {
            auto mask = m.visibleFaceMask();
            assert(m.triangulateFacesByMask(mask) > 0,
                "6509 rebuild-drop fixture: cube did not triangulate for " ~ id);
        }
        if (id == "mesh.mergeFaces") {
            m.resetSelection();
            m.selectFace(0);
            m.selectFace(1);
        }
        auto command = rig.registry.commandFactories[id]();
        if (id == "mesh.remesh") {
            auto remesh = cast(Remesh) command;
            assert(remesh !is null, "6509 remesh fixture: factory type changed");
            setField(remesh, "captured_", true);
            setField(remesh, "cachedVertices_", [
                Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)]);
            setField(remesh, "cachedFaces_", [[0u, 1u, 2u]]);
        }
        const before = rig.meshRebuildDrops;
        command.apply();
        assert(rig.meshRebuildDrops == before + 1,
            "6509 rebuild drop: " ~ id ~ " did not reach the drop door ("
          ~ (rig.meshRebuildDrops - before).to!string ~ " of 1)");
    }
    assert(rig.meshRebuildDrops == 7,
        "6509 rebuild drop: the seven commands did not reach the drop door");
    assert(!rig.remeshModalState.open,
        "6509 rebuild drop: a rebuild command opened the remesh modal");

    assert(!rig.remeshModalState.open && !rig.remeshModalState.pendingOpen
        && rig.meshRebuildDrops == 7,
        "6509 remesh-door floor: state changed before mesh.remesh.open");
    auto open = rig.registry.commandFactories["mesh.remesh.open"]();
    open.apply();
    assert(rig.remeshModalState.open && rig.remeshModalState.pendingOpen,
        "6509 remesh door: mesh.remesh.open did not open the shared modal state");
    assert(rig.meshRebuildDrops == 7,
        "6509 remesh door: mesh.remesh.open reached the rebuild-drop door");
}

// B7: the two selection-type producers receive the promote door and an
// unrelated mesh command does not.
unittest {
    auto rig = registeredRig();
    assert(rig.promotions.length == 0,
        "6509 promote floor: the door fired during registration");
    ref Mesh m = rig.session.editMesh();
    m.resetSelection();
    m.selectVertex(0);
    m.selectVertex(1);
    m.selectVertex(2);
    rig.registry.commandFactories["mesh.makePolygon"]().apply();
    assert(rig.promotions == [EditMode.Polygons],
        "6509 promote door: mesh.makePolygon did not promote to polygons");

    auto select = cast(MeshSelect) rig.registry.commandFactories["mesh.select"]();
    assert(select !is null, "6509 promote fixture: mesh.select type changed");
    select.setMode("edges");
    select.setIndices([0]);
    select.apply();
    assert(rig.promotions == [EditMode.Polygons, EditMode.Edges],
        "6509 promote door: mesh.select did not promote to edges");

    const before = rig.promotions.length;
    rig.registry.commandFactories["mesh.subdivide"]().apply();
    assert(rig.promotions.length == before,
        "6509 promote ceiling: mesh.subdivide reached the promote door");
}
