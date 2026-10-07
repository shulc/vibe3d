// 9494: carried panel offset and the distinct script command boundary.
import drag_helpers : Vec3, fetchCamera, playAndWait, buildDragLog;
import pen_rig_helpers : penSceneEmpty, penCommand, penCameraAt, worldPixel, readVerts;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.math : abs;
import std.format : format;
void main() {}
private void run(bool panel) {
    penSceneEmpty("Front");
    const body=`{"vertices":[[0.1,0,0],[0.4,0,0],[0.4,0.4,0],[0.1,0.4,0],[-0.1,0.4,0],[-0.4,0.4,0],[-0.4,0,0],[-0.1,0,0]],"faces":[[0,1,2,3],[4,5,6,7]]}`;
    assert(postJson("/api/command",commandBody("scene.loadMesh",body))["status"].str=="ok");
    penCommand("viewport.view Front"); penCameraAt(Vec3(0,0,0),100);
    penCommand("tool.set mesh.topoPen on");
    penCommand("tool.attr mesh.topoPen mode move");
    penCommand("tool.attr mesh.topoPen backFace true");
    penCommand("tool.pipe.attr snap types \"\"");
    penCommand("tool.pipe.attr symmetry axis x");
    penCommand("tool.pipe.attr symmetry enabled true");
    auto before=getJson("/api/model");
    assert(before["vertices"].array.length==8 && before["faces"].array.length==2,"9494 rig population");
    auto from=worldPixel(Vec3(.4,0,0)); auto cam=fetchCamera();
    playAndWait(buildDragLog(cam.vpX,cam.vpY,cam.width,cam.height,from[0],from[1],from[0]+20,from[1],10,0,1));
    // No scripted query between the carried press and the write.
    auto r=postJson(panel ? "/api/script?interactive=true" : "/api/script", "tool.attr mesh.topoPen offsetX 0.3");
    assert(r["status"].str=="ok","9494 offset write accepted");
    auto vs=readVerts();
    const want=panel ? .7f : .6f;
    assert(vs.length==8,"9494 offset retains vertex population");
    assert(abs(vs[1].x-want)<1e-5,format("9494 source %s: expected %s got %s",panel,want,vs[1]));
    assert(abs(vs[6].x+want)<1e-5,format("9494 partner %s: expected %s got %s",panel,-want,vs[6]));
    assert(getJson("/api/model")["faces"]==before["faces"],"9494 exact corner rings retained");
    foreach(i;[0,2,3,4,5,7]) assert(getJson("/api/model")["vertices"][i]==before["vertices"][i],"9494 untouched corners retained");
}
unittest { run(false); }
unittest { run(true); }
