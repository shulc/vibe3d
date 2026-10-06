// Polygon stroke merge: release keeps points separate; adding the next point
// rebuilds using the frozen source map. Literal mesh cells: pen_rebuild_merge.json.
import pen_rig_helpers;
import drag_helpers : Vec3, buildDragLog, fetchCamera, playAndWait, kPaceLine;
import http_client : getJson;
import std.json : JSONValue, JSONType, parseJSON;
import std.format : format;
import std.math : abs;
import std.process : environment;

void main() {}
private double num(JSONValue v) { return v.type == JSONType.integer ? v.integer : v.floating; }
private Vec3 point(JSONValue v) { return Vec3(cast(float)num(v[0]),cast(float)num(v[1]),cast(float)num(v[2])); }
private Vec3[] square() { return [Vec3(-.2,1,-.2),Vec3(.2,1,-.2),Vec3(.2,1,.2),Vec3(-.2,1,.2)]; }
private void start(bool merge) {
    penSceneEmpty("Top"); penCameraAt(Vec3(0,1,.05),440);
    penCommand("tool.pipe.attr snap enabled true");
    penCommand(`tool.pipe.attr snap types ""`);
    penCommand("tool.pipe.attr constrain enabled false");
    penCommand("tool.set pen on");
    penCommand("tool.attr pen merge " ~ (merge ? "true" : "false"));
    clickWorld(square());
}
private void drag(size_t i, Vec3 target) {
    auto cam = fetchCamera(); const a = worldPixel(square()[i]), b = worldPixel(target);
    playAndWait(buildDragLog(cam.vpX,cam.vpY,cam.width,cam.height,a[0],a[1],b[0],b[1],20));
}
private void compare(string id, JSONValue vertices, JSONValue faces) {
    const m = getJson("/api/model");
    assert(m["vertices"].array.length == vertices.array.length,
        format("%s: vertices %s expected %s",id,m["vertices"].array.length,vertices.array.length));
    assert(m["faces"] == faces,format("%s: faces %s expected %s",id,m["faces"],faces));
    foreach (i,v; m["vertices"].array) {
        const a = point(v), b = point(vertices[i]);
        assert(abs(a.x-b.x) < .003 && abs(a.y-b.y) < .0001 && abs(a.z-b.z) < .003,
            format("%s: vertex %s at %s expected %s",id,i,a,b));
    }
}
unittest {
    auto fx = parseJSON(import("fixtures/pen_rebuild_merge.json"));
    const only = environment.get("VIBE3D_CELL", ""); size_t ran;
    foreach (c; fx["rows"].array) foreach (enter; [false,true]) {
        const id = c["id"].str ~ (enter ? "-return" : ""); if (only.length && only != id) continue;
        start(num(c["merge"]) != 0);
        drag(c["dragged"].integer, Vec3(cast(float)num(c["landing"][0]),1,cast(float)num(c["landing"][1])));
        clickWorld(Vec3(0,1,.44));
        if (enter)
            playAndWait(kPaceLine ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":13,"mod":0}` ~ "\n");
        else penCommand("tool.set pen off");
        compare(id,c["vertices"],c["faces"]); ++ran;
    }
    foreach (outside; [false, true]) foreach (ending; ["script","return","q"]) {
        const id = (outside ? "outside-release-" : "release-") ~ ending; if (only.length && only != id) continue;
        start(true); const target = Vec3(outside ? -.185 : -.195,1,.2); drag(1,target);
        assert(penAttrValue("currentPoint") == 1, id ~ ": release changed current point");
        if (ending == "script") penCommand("tool.set pen off");
        else {
            const key = ending == "q" ? 113 : 13;
            playAndWait(kPaceLine ~ format(`{"t":50.000,"type":"SDL_KEYDOWN","sym":%s,"mod":0}` ~ "\n",key));
        }
        auto points = square(); points[1] = target;
        JSONValue[] vs; foreach (p; points) vs ~= JSONValue([JSONValue(p.x),JSONValue(p.y),JSONValue(p.z)]);
        compare(id,JSONValue(vs),parseJSON("[[1,0,3,2]]")); ++ran;
    }
    foreach (kind; ["lines", "vertices"]) foreach (ending; ["script", "return"]) {
        const id = "type-roundtrip-" ~ kind ~ "-" ~ ending;
        if (only.length && only != id) continue;
        start(false);
        penCommand("tool.attr pen type " ~ kind);
        clickWorld(Vec3(0,1,.44));
        penCommand("tool.attr pen type polygons");
        if (ending == "script") penCommand("tool.set pen off");
        else playAndWait(kPaceLine ~ `{"t":50.000,"type":"SDL_KEYDOWN","sym":13,"mod":0}` ~ "\n");
        const m = getJson("/api/model");
        assert(m["vertices"].array.length == 5, id ~ ": five clicked points");
        assert(m["faces"] == parseJSON("[[1,0,4,3,2]]"),
            id ~ ": type round-trip lost a clicked stroke corner: " ~ m["faces"].toString);
        ++ran;
    }
    if (!only.length) assert(ran == 24,format("merge cell population %s expected 24",ran));
    else assert(ran == 1, "requested merge cell missing");
}
