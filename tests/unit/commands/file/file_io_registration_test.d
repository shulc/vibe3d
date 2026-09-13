// The file-I/O registrar is tested through its real factories, then its
// production call is pinned separately because this rig builds its own roles.
module commands.file.file_io_registration_test;

import std.algorithm : count;
import std.file : exists, readText, remove;
import std.path : buildPath, buildNormalizedPath, dirName;
import std.string : indexOf;

import command_history : CommandHistory;
import commands.file.load : FileLoad, FileLoadMode;
import commands.file.save : FileSave, FileSaveMode;
import document : Document, Layer;
import editmode : EditMode;
import file_io_registration : FileIoSessionRole, LiveFileView,
    LiveFileViewModeRole, registerFileIoCommands;
import mesh : makeCube, makeDiamond, makeGridPlane;
import registry : Registry;
import session_owner : Session;
import view : View;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..", "..");

unittest { // every format factory retains its own configure argument
    auto session = Session.bootstrap(makeCube());
    auto camera = new View(0, 0, 800, 600);
    ref View liveView() { return camera; }

    Registry reg;
    registerFileIoCommands(reg, FileIoSessionRole(session),
        LiveFileViewModeRole(cast(LiveFileView)&liveView,
                             session.editModePtr()));

    assert(reg.commandFactories.length == 12,
        "5790 configure witness population: expected 12 file-I/O ids");
    assert(reg.commandFactories["file.open"] ==
           reg.commandFactories["file.load"],
        "file.open must remain the file.load factory alias");

    immutable importIds = ["file.import.lwo", "file.import.obj"];
    immutable importExts = [".lwo", ".obj"];
    assert(importIds.length == 2 && importExts.length == 2,
        "5790 import configure population must be exactly two witnesses");
    foreach (i, id; importIds) {
        auto c = cast(FileLoad)reg.commandFactories[id]();
        assert(c !is null && c.configuredMode == FileLoadMode.importSingle,
            "5790 import configure witness did not build importSingle");
        assert(c.configuredExtension == importExts[i],
            "5790 shared extension capture witness: import " ~ id
            ~ " configured " ~ c.configuredExtension);
    }

    immutable exportIds = ["file.export.gltf", "file.export.obj"];
    immutable exportExts = [".gltf", ".obj"];
    assert(exportIds.length == 2 && exportExts.length == 2,
        "5790 export configure population must be exactly two witnesses");
    foreach (i, id; exportIds) {
        auto c = cast(FileSave)reg.commandFactories[id]();
        assert(c !is null && c.configuredMode == FileSaveMode.exportSingle,
            "5790 export configure witness did not build exportSingle");
        assert(c.configuredExtension == exportExts[i],
            "5790 shared extension capture witness: export " ~ id
            ~ " configured " ~ c.configuredExtension);
    }
}

unittest { // a history-held command stays on A while new factories resolve B
    import io.doc_state : clearCurrentDoc, requestDocRebaseline;

    auto session = Session.bootstrap(makeCube());
    auto layerA = session.document.layers[0];

    auto cameraA = new View(0, 0, 800, 600);
    auto cameraB = new View(0, 0, 640, 480);
    View camera = cameraA;
    ref View liveView() { return camera; }

    Registry reg;
    registerFileIoCommands(reg, FileIoSessionRole(session),
        LiveFileViewModeRole(cast(LiveFileView)&liveView,
                             session.editModePtr()));

    const path = buildPath("/var/tmp", "vibe3d-5790-file-io-history.lwo");
    if (exists(path)) remove(path);
    scope(exit) {
        if (exists(path)) remove(path);
        clearCurrentDoc();
        requestDocRebaseline();
    }

    auto save = cast(FileSave)reg.commandFactories["file.save"]();
    save.setPath(path);
    assert(save.apply(), "setup: write the A cube fixture");

    auto layerB = new Layer;
    layerB.name = "B";
    layerB.meshRef() = makeDiamond();
    session.document.layers ~= layerB;
    layerA.meshRef() = makeGridPlane(1);
    assert(layerA.meshRef().vertices.length == 4,
        "setup: A starts as a four-vertex grid before import");
    auto oldCommand = cast(FileLoad)reg.commandFactories["file.import.lwo"]();
    auto meshA = &layerA.meshRef();
    assert(oldCommand.meshPtr is meshA,
        "setup: the history command was created against A");
    oldCommand.setPath(path);
    auto history = new CommandHistory;
    assert(history.fire(oldCommand), "setup: import into A must enter history");
    assert(layerA.meshRef().vertices.length == 8,
        "setup: imported cube replaced A before the active-layer switch");

    session.document.setPrimary(layerB);
    session.switchGeometryType(EditMode.Polygons);
    camera = cameraB;
    auto newCommand = cast(FileLoad)reg.commandFactories["file.import.lwo"]();
    auto meshB = &layerB.meshRef();

    assert(history.undo(), "old history command must remain undoable after A to B");
    assert(layerA.meshRef().vertices.length == 4
        && layerB.meshRef().vertices.length == makeDiamond().vertices.length,
        "5790 old history command witness: undo restored A and did not touch B");

    assert(newCommand.meshPtr is meshB,
        "5790 live mesh resolution witness: a command created after A to B "
        ~ "still captured A");
    assert(newCommand.viewRef is cameraB
        && newCommand.editModeVal == EditMode.Polygons,
        "5790 live View/Mode witness: command creation used registration-time state");
}

unittest { // production wiring and LAST-wrapper ordering
    const registrationPath = buildPath(repoRoot, "source", "registration.d");
    const fileIoPath = buildPath(repoRoot, "source", "file_io_registration.d");
    const registration = readText(registrationPath);
    const fileIo = readText(fileIoPath);

    assert(fileIo.length > 2_000,
        "5790 production census population: file_io_registration.d is too small");
    assert(fileIo.count("EditorApp") == 0
        && fileIo.count("editor_app") == 0,
        "5790 no-EditorApp witness: narrow registrar imports or names EditorApp");
    assert(fileIo.count("file.new") == 0
        && registration.count("commandFactories[\"file.new\"]") == 1,
        "5790 scope fence: file.new left its application lifecycle family");

    enum productionCall =
        "registerFileIoCommands(app.reg(), FileIoSessionRole(app.sessionOwner),";
    assert(registration.count(productionCall) == 1,
        "5790 production wiring witness: registerCommands no longer calls the "
        ~ "narrow file-I/O registrar with the real Session");

    const callAt = registration.indexOf(productionCall);
    const wrapperAt = registration.indexOf(
        "auto selTypeSrc = () => currentSelType(selTypeOrder);");
    assert(callAt >= 0 && wrapperAt >= 0 && callAt < wrapperAt,
        "5790 selection wrapper ordering witness: file-I/O registration moved "
        ~ "after the LAST selection-type wrapper");
}
