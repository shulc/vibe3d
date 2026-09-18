// The behavior rig builds its own doors; S9 separately pins the production
// inputs and ordering so helper correctness cannot hide mis-wiring.
module tests.unit.commands.select.selection_command_registration_test;

import application_command_binding : CommandInvocationContext,
    CommandInvocationResult;
import command : Command, CommandOrigin;
import command_args : bindArgs;
import commands.select.between : SelectBetween;
import commands.select.boundary : SelectBoundary;
import commands.select.by_stat : SelectByStatEdge, SelectByStatPolygon,
    SelectByStatVertex;
import commands.select.by_tag : SelectByTag;
import commands.select.connect : SelectConnect;
import commands.select.contract : SelectionContract;
import commands.select.convert : SelectConvertCommand;
import commands.select.drop : SelectDropCommand;
import commands.select.element : SelectElementCommand;
import commands.select.expand : SelectionExpand;
import commands.select.fill : SelectFillHoles, SelectFillInsideLoop;
import commands.select.invert : SelectInvert;
import commands.select.less : SelectLess;
import commands.select.loop : SelectLoop;
import commands.select.more : SelectMore;
import commands.select.ring : SelectRing;
import commands.select.sets : SelectSetApply, SelectSetDelete, SelectSetEdit,
    SelectSetRename, SelectSetStore;
import commands.select.type_from : SelectTypeFromCommand;
import core.exception : AssertError;
import document : Layer;
import editmode : EditMode;
import mesh : Mesh, makeGridPlane;
import mesh_selsets : selSetOwnsPolygon;
import seltype : SelMode, SelType, currentSelType, geometryEditMode;
import selection_command_registration : SelectionTypeDoors,
    registerSelectionCommands;
import std.algorithm : count, sort;
import std.array : join, split;
import std.exception : assertThrown;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : baseName, buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import tool : Tool;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
    "..", "..", "..", "..");

private struct DoorCounts {
    size_t promote;
    size_t switchGeometry;
    size_t switchItem;
}

private struct ReachRow {
    string file;
    size_t count;
    string why;
}

/// Exact per-file mode-cell capability ledger. A listed file must exist and
/// remain populated; every unlisted registrar must stay at zero.
private static immutable ReachRow[] kModeCellReach = [
    ReachRow("scene_file_lifecycle_registration.d", 2,
        "6356: two declared lifecycle doors"),
    ReachRow("transform_tool_registration.d", 5,
        "6506: one unified helper plus four deform factories"),
];

/// No shallow registrar names editModePtr on this HEAD. The former selection
/// exception was empty and is intentionally replaced by an exact zero ledger.
private static immutable ReachRow[] kEditModePtrReach = [];

private SelectionTypeDoors rigDoors(LiveRegistrationRig rig, DoorCounts* n) {
    return SelectionTypeDoors(
        rig.session.editModePtr(),
        (EditMode m) {
            ++n.promote;
            rig.session.promoteGeometryType(m);
        },
        (EditMode m) {
            ++n.switchGeometry;
            if (rig.session.switchGeometryType(m)) rig.activeTool = null;
        },
        () {
            ++n.switchItem;
            if (rig.session.switchItemType()) rig.activeTool = null;
        });
}

private void register(LiveRegistrationRig rig, DoorCounts* n) {
    registerSelectionCommands(rig.registry, rig.liveSession(),
        rig.liveViewMode(), rigDoors(rig, n));
}

private CommandInvocationResult invoke(LiveRegistrationRig rig, string id,
                                       string json = "") {
    return rig.binding.invokeLine(id, json,
        CommandInvocationContext(CommandOrigin.script, false));
}

private immutable string[] kIds = [
    "select.expand", "select.contract", "select.more", "select.less",
    "select.loop", "select.ring", "select.invert", "select.connect",
    "select.between", "select.fill.holes", "select.fill.insideLoop",
    "select.boundary", "select.typeFrom", "select.vertex", "select.edge",
    "select.polygon", "select.item", "select.byTag", "select.byStat.vertex",
    "select.byStat.edge", "select.byStat.polygon", "select.drop",
    "select.element", "select.convert", "select.set.store", "select.set.edit",
    "select.set.apply", "select.set.rename", "select.set.delete",
];

private size_t selectedEdges(ref Mesh mesh) {
    size_t result;
    foreach (i; 0 .. mesh.edges.length)
        if (mesh.isEdgeSelected(i)) ++result;
    return result;
}

private bool lockstep(LiveRegistrationRig rig) {
    return rig.session.editMode
        == geometryEditMode(rig.session.selTypeOrder.mostRecentGeometry());
}

unittest { // S1: every id still builds its original concrete class
    auto rig = new LiveRegistrationRig;
    DoorCounts n;
    register(rig, &n);
    assert(rig.registry.commandFactories.length == 29,
        format("6000 population: expected 29 selection ids, got %d",
               rig.registry.commandFactories.length));
    TypeInfo_Class[] expected = [
        typeid(SelectionExpand), typeid(SelectionContract), typeid(SelectMore),
        typeid(SelectLess), typeid(SelectLoop), typeid(SelectRing),
        typeid(SelectInvert), typeid(SelectConnect), typeid(SelectBetween),
        typeid(SelectFillHoles), typeid(SelectFillInsideLoop),
        typeid(SelectBoundary), typeid(SelectTypeFromCommand),
        typeid(SelectTypeFromCommand), typeid(SelectTypeFromCommand),
        typeid(SelectTypeFromCommand), typeid(SelectTypeFromCommand),
        typeid(SelectByTag), typeid(SelectByStatVertex), typeid(SelectByStatEdge),
        typeid(SelectByStatPolygon), typeid(SelectDropCommand),
        typeid(SelectElementCommand), typeid(SelectConvertCommand),
        typeid(SelectSetStore), typeid(SelectSetEdit), typeid(SelectSetApply),
        typeid(SelectSetRename), typeid(SelectSetDelete),
    ];
    assert(expected.length == kIds.length, "6000 id/class table out of step");
    size_t checked;
    foreach (i, id; kIds) {
        auto command = rig.registry.commandFactories[id]();
        assert(typeid(command) is expected[i],
            "6000 id->class witness: " ~ id ~ " built " ~ typeid(command).name);
        ++checked;
    }
    assert(checked == 29, "6000 id->class population floor");
}

unittest { // S2: primary, View and mode resolve when the command is created
    auto rig = new LiveRegistrationRig;
    DoorCounts n;
    register(rig, &n);
    auto meshA = &rig.layerA.meshRef();
    auto meshB = &rig.layerB.meshRef();
    assert(rig.session.document.layers.length == 2
        && meshA !is meshB && meshA.vertices.length == 8
        && meshB.vertices.length == 6,
        "6000 rig floor: F's registration-time A/B must have 8 != 6 vertices");

    size_t early;
    foreach (id; kIds) {
        auto command = rig.registry.commandFactories[id]();
        assert(command.meshPtr is meshA && command.viewRef is rig.cells[0]
            && command.editModeVal == EditMode.Vertices,
            "6000 pre-switch floor: " ~ id ~ " did not see A/cell0/Vertices");
        ++early;
    }
    assert(early == 29, "6000 pre-switch population floor");

    rig.switchToB();
    assert(rig.session.editMode == EditMode.Polygons && rig.activeCell == 1,
        "6000 switch floor: B/cell1/Polygons not reached");
    Command[] late;
    foreach (id; kIds) late ~= rig.registry.commandFactories[id]();
    assert(late.length == 29, "6000 post-switch population floor");
    foreach (i, command; late)
        assert(command.meshPtr is meshB,
            "6000 live mesh witness: " ~ kIds[i]
          ~ " captured the registration-time primary");
    foreach (i, command; late)
        assert(command.viewRef is rig.cells[1],
            "6000 live view witness: " ~ kIds[i]
          ~ " captured the registration-time cell");
    foreach (i, command; late)
        assert(command.editModeVal == EditMode.Polygons,
            "6000 live mode witness: " ~ kIds[i]
          ~ " captured the registration-time mode");
}

unittest { // S3: select.convert uses the live mode cell and promote funnel
    auto rig = new LiveRegistrationRig;
    DoorCounts n;
    register(rig, &n);
    rig.switchToB();
    auto meshB = &rig.layerB.meshRef();
    meshB.syncSelection();
    meshB.selectFace(0);
    rig.activeTool = new Tool;
    assert(rig.activeTool !is null
        && rig.session.editMode == EditMode.Polygons
        && meshB.isFaceSelected(0),
        "6000 convert precondition: owner was not armed in polygon mode");

    auto result = invoke(rig, "select.convert", `{"type":"edge"}`);
    assert(result.applied, "6000 convert route: select.convert did not apply");
    assert(selectedEdges(*meshB) == 3,
        format("6000 mode-cell witness: polygon->edge from the LIVE mode must "
             ~ "select face 0's 3 edges, got %d", selectedEdges(*meshB)));
    assert(currentSelType(rig.session.selTypeOrder) == SelType.Edge
        && lockstep(rig),
        "6000 funnel witness: select.convert wrote EditMode outside the "
      ~ "selection-type order");
    assert(rig.activeTool !is null,
        "6000 promotion witness: select.convert dropped the active tool");
    assert(n.promote == 1 && n.switchGeometry == 0,
        format("6000 door witness: select.convert promote=%d switch=%d",
               n.promote, n.switchGeometry));
}

unittest { // S4: explicit geometry switches drop on a flip and only a flip
    auto rig = new LiveRegistrationRig;
    DoorCounts n;
    register(rig, &n);
    immutable ids = ["select.vertex", "select.edge", "select.polygon",
                     "select.typeFrom"];
    immutable targets = [EditMode.Vertices, EditMode.Edges,
                         EditMode.Polygons, EditMode.Vertices];
    immutable args = ["", "", "", `{"type":"vertex"}`];
    rig.session.switchGeometryType(EditMode.Polygons);
    size_t flips;
    foreach (i, id; ids) {
        rig.activeTool = new Tool;
        const before = n.switchGeometry;
        auto result = invoke(rig, id, args[i]);
        assert(result.applied, "6000 switch route: " ~ id ~ " did not apply");
        assert(rig.session.editMode == targets[i] && lockstep(rig),
            "6000 switch funnel witness: " ~ id);
        assert(n.switchGeometry == before + 1 && rig.activeTool is null,
            "6000 explicit-switch drop witness: " ~ id
          ~ " did not drop on a flip");
        ++flips;
    }
    assert(flips == 4 && n.promote == 0,
        "6000 switch population / no promote");
    rig.activeTool = new Tool;
    invoke(rig, "select.vertex");
    assert(rig.activeTool !is null,
        "6000 no-flip witness: same-type switch dropped the tool");
}

unittest { // S5: the Item door leaves EditMode alone
    auto rig = new LiveRegistrationRig;
    DoorCounts n;
    register(rig, &n);
    immutable ids = ["select.item", "select.typeFrom"];
    immutable args = ["", `{"type":"item"}`];
    size_t rows;
    foreach (i, id; ids) {
        rig.session.switchGeometryType(
            i == 0 ? EditMode.Polygons : EditMode.Edges);
        const mode = rig.session.editMode;
        const itemBefore = n.switchItem;
        auto result = invoke(rig, id, args[i]);
        assert(result.applied, "6000 item route: " ~ id);
        assert(currentSelType(rig.session.selTypeOrder) == SelType.Item,
            "6000 item door witness: " ~ id ~ " did not make Item current");
        assert(rig.session.editMode == mode,
            "6000 item EditMode witness: " ~ id ~ " rewrote EditMode");
        assert(n.switchItem == itemBefore + 1,
            "6000 item door identity: " ~ id);
        ++rows;
    }
    assert(rows == 2 && n.switchGeometry == 0, "6000 item population");
}

unittest { // S6: side-effect type moves use the promotion door
    auto rig = new LiveRegistrationRig;
    DoorCounts n;
    register(rig, &n);
    rig.switchToB();
    auto meshB = &rig.layerB.meshRef();
    meshB.syncSelection();
    meshB.selectFace(0);
    struct Row { string id; EditMode from; EditMode to; }
    immutable Row[] rows = [
        Row("select.boundary", EditMode.Polygons, EditMode.Edges),
        Row("select.byStat.vertex", EditMode.Edges, EditMode.Vertices),
        Row("select.byStat.edge", EditMode.Vertices, EditMode.Edges),
        Row("select.byStat.polygon", EditMode.Edges, EditMode.Polygons),
    ];
    size_t promoted;
    foreach (row; rows) {
        rig.session.switchGeometryType(row.from);
        const promoteBefore = n.promote;
        const switchBefore = n.switchGeometry;
        auto result = invoke(rig, row.id);
        assert(result.applied, "6000 promote route: " ~ row.id);
        assert(rig.session.editMode == row.to && lockstep(rig),
            "6000 promote funnel witness: " ~ row.id);
        assert(n.promote == promoteBefore + 1
            && n.switchGeometry == switchBefore,
            "6000 promote door identity: " ~ row.id);
        ++promoted;
    }

    rig.session.switchGeometryType(EditMode.Edges);
    meshB.clearFaceSelection();
    meshB.clearEdgeSelection();
    const face = meshB.faces[0];
    foreach (k; 0 .. face.length) {
        const a = face[k];
        const b = face[(k + 1) % face.length];
        foreach (ei, edge; meshB.edges)
            if ((edge[0] == a && edge[1] == b)
                || (edge[0] == b && edge[1] == a))
                meshB.selectEdge(cast(int) ei);
    }
    assert(selectedEdges(*meshB) == 3, "6000 fill barrier floor");
    const promoteBefore = n.promote;
    auto result = invoke(rig, "select.fill.insideLoop");
    assert(result.applied, "6000 promote route: select.fill.insideLoop");
    assert(rig.session.editMode == EditMode.Polygons && lockstep(rig),
        "6000 promote funnel witness: select.fill.insideLoop");
    assert(n.promote == promoteBefore + 1,
        "6000 promote door identity: select.fill.insideLoop");
    ++promoted;
    assert(promoted == 5 && n.switchGeometry == 0,
        "6000 promote population");
}

unittest { // S7: select.set.apply walks the live Document foreground
    auto rig = new LiveRegistrationRig;
    DoorCounts n;
    register(rig, &n);

    auto layerC = new Layer;
    layerC.name = "C";
    layerC.meshRef() = makeGridPlane(1);
    rig.session.document.layers ~= layerC;
    rig.session.document.selectItem(layerC, SelMode.Add);
    rig.session.document.selectItem(rig.layerA, SelMode.Add);
    assert(&rig.session.editMesh() is &rig.layerA.meshRef()
        && layerC.selected && layerC.visible,
        "6000 set floor: A must stay primary while C is foreground");
    assert(!selSetOwnsPolygon(rig.layerA.meshRef(), "M")
        && !selSetOwnsPolygon(rig.layerB.meshRef(), "M"),
        "6000 set floor: registration-time layers unexpectedly own M");

    rig.session.switchGeometryType(EditMode.Polygons);
    auto meshC = &layerC.meshRef();
    meshC.syncSelection();
    meshC.selectFace(0);
    auto store = new SelectSetStore(meshC, rig.cells[0], EditMode.Polygons);
    store.setSelTypeProvider(() => SelType.Polygon);
    bindArgs(store, `{"name":"M"}`);
    assert(store.apply(), "6000 set floor: storing M on C");
    meshC.clearFaceSelection();
    assert(!meshC.isFaceSelected(0),
        "6000 set floor: C face 0 cleared before apply");

    auto result = invoke(rig, "select.set.apply",
                         `{"name":"M","mode":"select"}`);
    assert(result.applied,
        "6000 multi-layer witness: select.set.apply refused a set owned by "
      ~ "a non-primary foreground layer added after registration");
    assert(meshC.isFaceSelected(0),
        "6000 multi-layer witness: C face 0 not selected");
}

unittest { // S8: the door struct refuses every missing collaborator
    EditMode mode;
    void delegate(EditMode) ok = delegate(EditMode m) {};
    void delegate() okItem = delegate() {};
    assertThrown!AssertError(SelectionTypeDoors(null, ok, ok, okItem));
    assertThrown!AssertError(SelectionTypeDoors(&mode, null, ok, okItem));
    assertThrown!AssertError(SelectionTypeDoors(&mode, ok, null, okItem));
    assertThrown!AssertError(SelectionTypeDoors(&mode, ok, ok, null));
}

private string squash(string code) {
    return code.split().join(" ");
}

unittest { // S9: production call, ordering and old-path census
    const regSrc = readText(buildPath(repoRoot, "source", "registration.d"));
    const selSrc = readText(buildPath(
        repoRoot, "source", "selection_command_registration.d"));
    const appSrc = readText(buildPath(repoRoot, "source", "app.d"));
    const reg = squash(blankNonCode(regSrc));
    const sel = blankNonCode(selSrc);
    const app = squash(blankNonCode(appSrc));
    assert(regSrc.length > 50_000 && selSrc.length > 4_000
        && appSrc.length > 100_000,
        "6000 census population: a source file is implausibly small");

    foreach (needle; ["EditorApp", "editor_app", "Ai3dModalRefs",
                      "RemeshModalRefs", "with (", "app."])
        assert(sel.count(needle) == 0,
            "6000 no-app witness: selection registrar names " ~ needle);
    assert(sel.count("reg.commandFactories[") == 29,
        "6000 census: 29 factory rows");
    assert(sel.count("doors.editMode_") == 11
        && sel.count("owner.document()") == 1
        && sel.count("doors.promoteGeometry_") == 6
        && sel.count("doors.switchGeometry_") == 5
        && sel.count("doors.switchItem_") == 5,
        format("6000 census: mode/document/door reads %d/%d/%d/%d/%d",
            sel.count("doors.editMode_"), sel.count("owner.document()"),
            sel.count("doors.promoteGeometry_"),
            sel.count("doors.switchGeometry_"),
            sel.count("doors.switchItem_")));

    string[] regFiles;
    foreach (de; dirEntries(buildPath(repoRoot, "source"),
                            "*_registration.d", SpanMode.shallow))
        regFiles ~= baseName(de.name);
    regFiles.sort;
    size_t modeRowsSeen, editModePtrRowsSeen;
    foreach (file; regFiles) {
        const code = blankNonCode(readText(buildPath(repoRoot, "source", file)));
        size_t expectedModeCells;
        bool modeRecorded;
        foreach (row; kModeCellReach) {
            if (row.file != file) continue;
            expectedModeCells = row.count;
            modeRecorded = true;
            ++modeRowsSeen;
        }
        const actualModeCells = code.count("modeCell");
        assert(actualModeCells == (modeRecorded ? expectedModeCells : 0),
            format("6000 mode-cell reach: %s reads modeCell %d time(s), ledger says %d",
                file, actualModeCells, modeRecorded ? expectedModeCells : 0));
        if (modeRecorded)
            assert(expectedModeCells > 0,
                "6000 mode-cell reach: a recorded modeCell row became empty: " ~ file);

        size_t expectedEditModePtrs;
        bool editModePtrRecorded;
        foreach (row; kEditModePtrReach) {
            if (row.file != file) continue;
            expectedEditModePtrs = row.count;
            editModePtrRecorded = true;
            ++editModePtrRowsSeen;
        }
        const actualEditModePtrs = code.count("editModePtr");
        assert(actualEditModePtrs ==
                (editModePtrRecorded ? expectedEditModePtrs : 0),
            format("6000 mode-cell reach: %s reads editModePtr %d time(s), ledger says %d",
                file, actualEditModePtrs,
                editModePtrRecorded ? expectedEditModePtrs : 0));
        if (editModePtrRecorded)
            assert(expectedEditModePtrs > 0,
                "6000 mode-cell reach: a recorded editModePtr row became empty: " ~ file);
    }
    assert(regFiles.length >= 13 && kModeCellReach.length == 2
        && modeRowsSeen == kModeCellReach.length
        && editModePtrRowsSeen == kEditModePtrReach.length,
        format("6000 mode-cell reach population: files=%d mode rows=%d/%d "
            ~ "editModePtr rows=%d/%d", regFiles.length, modeRowsSeen,
            kModeCellReach.length, editModePtrRowsSeen,
            kEditModePtrReach.length));

    assert(reg.count("void registerSelectionCommands(") == 0,
        "6000 old path: registration.d still defines the selection family");
    immutable retiredClasses = [
        "SelectionExpand", "SelectionContract", "SelectMore", "SelectLess",
        "SelectLoop", "SelectRing", "SelectInvert", "SelectConnect",
        "SelectBetween", "SelectFillHoles", "SelectFillInsideLoop",
        "SelectBoundary", "SelectTypeFromCommand", "SelectByTag",
        "SelectByStatVertex", "SelectByStatEdge", "SelectByStatPolygon",
        "SelectDropCommand", "SelectElementCommand", "SelectConvertCommand",
        "SelectSetStore", "SelectSetEdit", "SelectSetApply",
        "SelectSetRename", "SelectSetDelete",
    ];
    assert(retiredClasses.length == 25,
        "6000 retired-class census must name exactly 25 classes");
    foreach (cls; retiredClasses)
        assert(reg.count(cls) == 0,
            "6000 old path: registration.d still names " ~ cls);

    enum call = "registerSelectionCommands(app.reg(), "
        ~ "LiveSessionRole(app.sessionOwner), "
        ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
        ~ "SelectionTypeDoors(app.sessionOwner.editModePtr(), "
        ~ "app.promoteGeometryType, app.switchGeometryType, "
        ~ "app.switchItemType));";
    assert(reg.count(call) == 1,
        "6000 production wiring witness: registerCommands does not call the "
      ~ "selection registrar with the real Session, mode cell and three doors");
    const callAt = reg.indexOf(call);
    const wrapAt = reg.indexOf(
        "auto selTypeSrc = () => currentSelType(selTypeOrder);");
    assert(callAt >= 0 && wrapAt > callAt,
        "6000 ordering witness: selection registration moved after the "
      ~ "selection-type wrapper");

    immutable assigns = [
        "app.promoteGeometryType = cast(void delegate(EditMode))&promoteGeometryType;",
        "app.switchGeometryType = cast(void delegate(EditMode))&switchGeometryType;",
        "app.switchItemType = cast(void delegate())&switchItemType;",
    ];
    const registerAt = app.indexOf("registerCommands(app);");
    assert(app.count("registerCommands(app);") == 1 && registerAt > 0,
        "6000 census: app.d registerCommands call population");
    foreach (assignment; assigns) {
        assert(app.count(assignment) == 1,
            "6000 door assignment witness: " ~ assignment);
        assert(app.indexOf(assignment) < registerAt,
            "6000 door order witness: assigned after registerCommands: "
          ~ assignment);
    }
}
