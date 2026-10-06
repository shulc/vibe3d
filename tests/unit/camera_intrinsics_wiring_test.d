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
