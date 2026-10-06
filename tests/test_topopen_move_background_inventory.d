// 9504: background inventory alone must not constrain a free movement preset.
import drag_helpers : Vec3, buildDragLog, fetchCamera, playAndWait;
import pen_rig_helpers : penSceneEmpty, penCommand, penCameraAt, worldPixel, readVerts;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.math : abs;
import std.format : format;
import std.process : environment;

void main() {}

private void load(string body) {
    auto r = postJson("/api/command", commandBody("scene.loadMesh", body));
    assert(r["status"].str == "ok", "inventory fixture must load: " ~ r.toString);
}
private void freeMove(bool edge, bool background, bool explicitConstraint = false, bool handle = true, bool enabled = true) {
    penSceneEmpty("Front");
    JSONValue backgroundBefore;
    if (background) {
        load(`{"vertices":[[-0.5,0,-0.2],[0.5,0,-0.2],[0.5,1,-0.2],[-0.5,1,-0.2],[-0.5,0,0.2],[0.5,0,0.2],[0.5,1,0.2],[-0.5,1,0.2]],"faces":[[0,3,2,1],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7]]}`);
        backgroundBefore = getJson("/api/model");
        penCommand("layer.add name:Edit");
    }
    load(`{"vertices":[[-0.8,0.2,0.5],[-1.4,0.2,0.5],[-1.4,0.8,0.5],[-0.8,0.8,0.5]],"faces":[[0,1,2,3]]}`);
    penCommand("viewport.view Front");
    penCameraAt(Vec3(0,0,0), 100);
    penCommand("tool.set mesh.dragWeld on");
    penCommand("tool.attr mesh.dragWeld backFace true");
    penCommand(`tool.pipe.attr snap types ""`);
    if (explicitConstraint) {
        penCommand("tool.pipe.attr constrain enabled " ~ (enabled ? "true" : "false"));
        penCommand("tool.pipe.attr constrain handle " ~ (handle ? "true" : "false"));
        penCommand("tool.pipe.attr constrain geometry off");
    }
    auto before = getJson("/api/model");
    assert(before["vertices"].array.length == 4 && before["faces"].array.length == 1,
        "free move population: four foreground vertices and one polygon");
    const from = worldPixel(Vec3(-0.8f, edge ? 0.5f : 0.2f, 0.5f));
    auto cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        from[0], from[1], from[0] + 100, from[1], 20, 0, 1));
    auto vs = readVerts();
    assert(vs.length == 4 && getJson("/api/model")["faces"] == before["faces"],
        "free move must preserve foreground topology");
    foreach (i, v; vs) {
        const moved = i == 0 || edge && i == 3;
        const x = i == 0 || i == 3 ? -0.8f : -1.4f;
        assert(abs(v.x - (x + (moved ? 1.0f : 0))) < 1e-5f
            && abs(v.z - (explicitConstraint && enabled && handle && moved ? 0.2f : 0.5f)) < 1e-5f,
            format("free move %s background=%s vertex=%s must retain element depth: %s",
                edge ? "edge" : "vertex", background, i, v));
        assert(abs(v.y - (i < 2 ? 0.2f : 0.8f)) < 1e-5f,
            "free move must retain every vertical coordinate");
    }
    penCommand("tool.set mesh.dragWeld off");
    if (background) {
        penCommand("layer.select index:0");
        auto after = getJson("/api/model");
        assert(after["vertices"] == backgroundBefore["vertices"]
            && after["faces"] == backgroundBefore["faces"],
            "free move must retain the entire background cube");
    }
}
private bool runs(string cell) {
    auto chosen = environment.get("VIBE3D_CELL", "all");
    return chosen == "all" || chosen == cell;
}
unittest { if (runs("vertex")) { freeMove(false, false); freeMove(false, true); } }
unittest { if (runs("edge")) { freeMove(true, false); freeMove(true, true); } }
// Explicit handle constraints are independent of inventory. Their analytic
// cube-front control detects a guard which simply disables every recast.
unittest { if (runs("explicit")) freeMove(false, true, true); }
unittest { if (runs("handle_off")) freeMove(false, true, true, false); }
unittest { if (runs("disabled")) freeMove(false, true, true, true, false); }
