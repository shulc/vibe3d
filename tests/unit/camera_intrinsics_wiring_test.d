module tests.unit.camera_intrinsics_wiring_test;
import std.file : readText;
import std.path : buildPath,dirName;
import std.algorithm : canFind;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode;
private enum root=dirName(dirName(dirName(__FILE_FULL_PATH__)));
unittest {
    auto app=blankNonCode(readText(buildPath(root,"source/app.d")));
    auto input=blankNonCode(readText(buildPath(root,"source/input_router.d")));
    auto providers=blankNonCode(readText(buildPath(root,"source/http_providers.d")));
    auto event=blankNonCode(readText(buildPath(root,"source/eventlog.d")));
    assert(app.indexOf("auto vpm = new ViewportManager")<app.indexOf("evLog.writeViewportMeta"),"LENS_METADATA_START_AFTER_CAMERA");
    foreach(consumer;["evPlay.tick();","httpServer.tickEventPlayer();"]) {
        assert(app.canFind("setReplayCurrentLens(recordingLens());\n                    "~consumer),"LENS_REFRESH_BEFORE_PLAYER: "~consumer);
    }
    assert(app.canFind("return cam.projKind == ProjKind.Ortho ? View.defaultFovY : cam.fovY;"),"LENS_METADATA_APP_VALUE");
    assert(input.canFind("return cam.projKind == ProjKind.Ortho ? View.defaultFovY : cam.fovY;"),"LENS_METADATA_INPUT_VALUE");
    assert(app.canFind("vpm.views[vpm.overlayOwnerId()].camera")&&input.canFind("app.vpm.views[app.vpm.overlayOwnerId()].camera"),"LENS_METADATA_INPUT_OWNER");
    assert(input.canFind("setReplayCurrentViewport(layout.vpX, layout.vpY,\n                                         layout.vpW, layout.vpH, recordingLens());"),"LENS_METADATA_RESIZE_COPY");
    assert(input.canFind("recLog.writeViewportMeta(layout.vpX, layout.vpY,\n                                             layout.vpW, layout.vpH, recordingLens());"),"LENS_METADATA_F1_HEADER");
    assert(providers.indexOf("lens = cameraLensParam(p[")<providers.indexOf("targetCam.setOrientation(o);"),"LENS_HTTP_PREFLIGHT_BEFORE_POSE");
    assert(providers.canFind("targetCam.setFovY(lens);"),"LENS_HTTP_COMMIT_FUNNEL");
    auto frame=blankNonCode(readText(buildPath(root,"source/input_frame_state.d")));
    auto subject=blankNonCode(readText(buildPath(root,"source/toolpipe/subject.d")));
    auto tool=blankNonCode(readText(buildPath(root,"source/tool.d")));
    assert(frame.canFind("app.vpm.inputSnapshot()")&&subject.canFind("subj.viewport    = src.viewport;")&&
           input.canFind("app.activeTool.syncEventViewport(subj.viewport);")&&tool.canFind("cachedVp = vp;"),"HTTP_EVENT_VIEWPORT_SUBJECT_TRANSPORT");
    assert(event.canFind("g_replayCurrentViewport.fovY = fovY;"),"LENS_REPLAY_COPY_WRITE");
}

// Owner selection is public viewport behavior; the eventlog module retains
// the private replay-copy assertions (task 10790).
unittest {
    import viewport : ViewportManager, LayoutPreset;
    import view : ProjKind;
    import eventlog : EventLogger, parseEventLog;
    import std.file : tempDir, remove;
    import std.process : thisProcessID;
    import std.conv : to;
    import std.stdio : File;
    const path = buildPath(tempDir(), "camera_lens_owner_" ~ thisProcessID().to!string ~ ".jsonl");
    scope(exit) remove(path);
    auto vpm = new ViewportManager(150, 28, 1152, 974);
    vpm.applyLayout(LayoutPreset.Quad);
    foreach (i, c; vpm.views) {
        c.camera.projKind = ProjKind.Perspective;
        c.camera.setFovY(.7 + i * .1);
    }
    assert(vpm.views.length == 4, "REPLAY_METADATA_OWNER_POPULATION");
    float recordedLens() {
        EventLogger logger;
        // Open owns the SDL clock; this fixture exercises the real metadata
        // producer using its public file/active state without an SDL session.
        logger.file = File(path, "w");
        logger.active = true;
        logger.writeViewportMeta(150, 28, 1152, 974,
            vpm.views[vpm.overlayOwnerId()].camera.fovY);
        logger.close();
        const decoded = parseEventLog(readText(path) ~ `{"t":1,"type":"SDL_QUIT"}` ~ "\n");
        assert(decoded.accepted && decoded.log.viewport.valid,
            "REPLAY_METADATA_OWNER_RECORD_REACHED");
        return decoded.log.viewport.fovY;
    }
    vpm.activeId = 0; vpm.hoveredId = 2; vpm.dragOriginId = -1;
    assert(recordedLens() == .9f, "REPLAY_METADATA_HOVER_OWNER");
    vpm.dragOriginId = 3;
    assert(recordedLens() == 1.0f, "REPLAY_METADATA_DRAG_OWNER");
    vpm.views[3].camera.setFovY(1.2);
    assert(recordedLens() == 1.2f, "REPLAY_METADATA_OWNER_LENS_CHANGED");
}
