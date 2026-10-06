// Global vertex placement during a real Move drag, followed by a separate weld client (9454).
import drag_helpers : Vec3, buildDragLog, fetchCamera, playAndWait;
import pen_rig_helpers : penSceneEmpty, penCommand, penCameraAt, worldPixel, readVerts;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.json;
import std.format : format;
import std.math : abs;
import std.process : environment;
import std.stdio : writeln;

void main() {}

private void load(string body) {
    assert(postJson("/api/command", commandBody("scene.loadMesh", body))["status"].str == "ok");
}
private void drag(bool foreground, bool renumberSource = false) {
    penSceneEmpty("Top");
    enum a = `{"vertices":[[0.3,1,0.3],[0.3,1,0.8],[0.8,1,0.8],[0.8,1,0.3]],"faces":[[0,1,2,3]]}`;
    enum c = `{"vertices":[[1.2,1,-0.6],[1.2,1,-0.4],[1.4,1,-0.4],[1.4,1,-0.6]],"faces":[[0,1,2,3]]}`;
    enum b = `{"vertices":[[-0.33043,1,-0.19794],[-0.33043,1,-0.49794],[-0.63043,1,-0.49794],[-0.63043,1,-0.19794],[1.2,1,-0.6],[1.2,1,-0.4],[1.4,1,-0.4],[1.4,1,-0.6]],"faces":[[0,1,2,3],[4,5,6,7]]}`;
    enum ab = `{"vertices":[[0.3,1,0.3],[0.3,1,0.8],[0.8,1,0.8],[0.8,1,0.3],[-0.33043,1,-0.19794],[-0.33043,1,-0.49794],[-0.63043,1,-0.49794],[-0.63043,1,-0.19794]],"faces":[[0,1,2,3],[4,5,6,7]]}`;
    enum permuted = `{"vertices":[[0.3,1,0.8],[0.8,1,0.8],[0.8,1,0.3],[0.3,1,0.3]],"faces":[[3,0,1,2]]}`;
    load(foreground ? c : renumberSource ? permuted : a);
    penCommand("layer.add name:Edit");
    enum ba = `{"vertices":[[-0.33043,1,-0.19794],[-0.33043,1,-0.49794],[-0.63043,1,-0.49794],[-0.63043,1,-0.19794],[0.3,1,0.3],[0.3,1,0.8],[0.8,1,0.8],[0.8,1,0.3]],"faces":[[0,1,2,3],[4,5,6,7]]}`;
    load(foreground ? renumberSource ? ba : ab : b);
    penCommand("viewport.view Top");
    penCameraAt(Vec3(0.07f, 1, 0), 439.52);
    penCommand("tool.set mesh.topoPen on");
    penCommand("tool.attr mesh.topoPen mode move");
    penCommand("tool.attr mesh.topoPen backFace true");
    penCommand("tool.pipe.attr constrain enabled true");
    penCommand("tool.pipe.attr constrain handle false");
    penCommand("tool.pipe.attr snap enabled true");
    penCommand("tool.pipe.attr snap types vertex");
    auto before = getJson("/api/model");
    const from = worldPixel(Vec3(-0.33043f, 1, -0.19794f));
    const to = worldPixel(Vec3(0.3f, 1, 0.3f));
    auto cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        from[0], from[1], to[0] - 6, to[1], 16, 0, 1));
    auto after = getJson("/api/model");
    auto vs = readVerts();
    auto hover = getJson("/api/tool/state")["hover"];
    writeln(format("GLOBAL-DRAG foreground=%s renumber=%s vertices=%s first=%s target=%s",
        foreground, renumberSource, vs.length, vs[0], hover.toString));
    if (foreground) {
        assert(vs.length == 7, format("foreground landing must weld 8 to 7, got %s: %s", vs.length, getJson("/api/tool/state").toString));
        assert(after["faces"].array.length == 2, "foreground weld retains both polygons");
        assert(hover["targetSource"].integer == 0 && hover["targetVert"].integer == (renumberSource ? 3 : 0),
            "foreground marker/readout must name the surviving elected vertex after compaction");
    } else {
        assert(vs.length == 8 && after["faces"] == before["faces"],
            "background landing must retain exact topology and eight vertices");
        assert(abs(vs[0].x - 0.3f) < 1e-6 && abs(vs[0].y - 1) < 1e-6
            && abs(vs[0].z - 0.3f) < 1e-6,
            format("background election must land exactly on (0.3,1,0.3), got %s", vs[0]));
        assert(hover["targetSource"].integer == 1 && hover["targetVert"].integer == (renumberSource ? 3 : 0),
            "background marker/readout must preserve the elected source and element id");
        foreach (i; 1 .. 8) assert(after["vertices"][i] == before["vertices"][i],
            "background placement must leave every other foreground vertex unchanged");
    }
}
unittest { if (environment.get("VIBE3D_CELL", "background") != "foreground") drag(false); }
unittest { if (environment.get("VIBE3D_CELL", "foreground") != "background") drag(true); }

// The same background polygon with rotated numbering separates a background
// element id from the dragged foreground id; accidental cross-source welds cannot hide as self-pairs.
unittest { if (environment.get("VIBE3D_CELL", "source") == "source") drag(false, true); }

unittest { if (environment.get("VIBE3D_CELL", "compaction") == "compaction") drag(true, true); }
