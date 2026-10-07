// 9504: perspective movement searches at the translated element, at the
// configured 15-pixel reach. Reciprocal targets distinguish it from the cursor.
import drag_helpers : Vec3, buildDragLog, fetchCamera, playAndWait;
import pen_rig_helpers : penSceneEmpty, penCommand, worldPixel, readVerts;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.math : abs, atan, PI;
import std.format : format;
import std.process : environment;

void main() {}
private bool runs(string cell) {
    return environment.get("VIBE3D_CELL", "all") == "all"
        || environment.get("VIBE3D_CELL", "all") == cell;
}
private void endpoint(string cell, bool snapping, bool hit) {
    penSceneEmpty("Top");
    const tx = hit ? -0.66 : -0.7237371401452577;
    const tz = hit ? 0.87 : 0.7259598449582685;
    auto body = format(`{"vertices":[[-1.2,0.5,-0.4],[-1.2,0.5,0.2],[-0.6,0.5,0.2],[-0.6,0.5,-0.4],[%.15f,0.5,%.15f],[%.15f,0.5,%.15f],[%.15f,0.5,%.15f]],"faces":[[0,1,2,3],[4,5,6]]}`,
        tx,tz,tx-0.8,tz+0.2,tx-0.8,tz-0.2);
    assert(postJson("/api/command", commandBody("scene.loadMesh", body))["status"].str == "ok");
    auto cam = fetchCamera();
    // Captured focal length and pose; only the principal point follows the
    // worker's pane. The camera API owns and validates its lens.
    const lens = 2 * atan(cam.height / (2 * 1004.754572603832));
    assert(postJson("/api/camera", format(`{"distance":5.02377286301916,"azimuth":0,"elevation":%.15f,"fovY":%.15f,"focus":{"x":0,"y":0,"z":0}}`, PI/3,lens))["status"].str == "ok");
    penCommand("tool.set mesh.dragWeld on");
    penCommand("tool.attr mesh.dragWeld backFace true");
    penCommand("tool.pipe.attr snap types vertex");
    penCommand("tool.pipe.attr snap innerRange 15");
    penCommand("tool.pipe.attr snap enabled " ~ (snapping ? "true" : "false"));
    auto before = getJson("/api/model");
    assert(before["vertices"].array.length == 7 && before["faces"].array.length == 2,
        "endpoint fixture population: seven vertices and two polygons");
    const from = worldPixel(Vec3(-1.2f,0.5f,-0.4f));
    cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX,cam.vpY,cam.width,cam.height,
        from[0],from[1],from[0]+80,from[1]+215,23,0,1));
    auto vs = readVerts();
    if (hit) {
        assert(vs.length == 6, format("%s: moved endpoint target must absorb 7 to 6, got %s",cell,vs.length));
        assert(abs(vs[3].x+0.66) < 1e-6 && abs(vs[3].y-0.5) < 1e-6 && abs(vs[3].z-0.87) < 1e-6,
            "endpoint target must survive on its exact position");
        auto faces = getJson("/api/model")["faces"].array;
        assert(faces.length == 2 && faces[0].array.length == 4 && faces[1].array.length == 3,
            "endpoint absorption preserves both polygon populations");
    } else {
        assert(vs.length == 7, format("%s: virtual cursor target must retain seven vertices",cell));
        assert(abs(vs[0].x+0.66) < 1e-6 && abs(vs[0].y-0.5) < 1e-6 && abs(vs[0].z-0.87) < 1e-6,
            format("%s: endpoint miss must retain captured translated position, got %s",cell,vs[0]));
        assert(getJson("/api/model")["faces"] == before["faces"], "endpoint miss retains connectivity");
        foreach(i;1..7) assert(getJson("/api/model")["vertices"][i] == before["vertices"][i],
            "endpoint miss retains every other vertex, including its target");
    }
}
unittest { if(runs("free")) endpoint("free",false,false); }
unittest { if(runs("miss")) endpoint("miss",true,false); }
unittest { if(runs("hit")) endpoint("hit",true,true); }
