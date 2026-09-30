// Task 8540: a preset axis gesture keeps its center and selected subject while
// session navigation peels live steps, consolidates a closed run and branches.
// Evidence: doc/transform_8540_scale_capture.md and the measured fixture.
import http_client : getJson, postJson, quiesce;
import drag_helpers : playAndWait, buildDragLog, fetchHandlePart;
import std.json : JSONValue, parseJSON;
import std.format : format;
import std.math : round, sqrt;

void main() {}

private void invoke(string line, bool ui = true) {
    auto response = postJson(ui ? "/api/command?origin=ui" : "/api/command", line);
    assert(response["status"].str == "ok", response.toString);
    quiesce();
}

private void navigate(bool redo) {
    uint mod = redo ? 65 : 64;
    playAndWait(format(`{"t":0,"type":"PACE","mode":"frames"}` ~ "\n" ~
        `{"t":30,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%s,"repeat":0}` ~ "\n" ~
        `{"t":60,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":%s,"repeat":0}` ~ "\n", mod, mod));
}

private void gesture(int dx, int dy) {
    double x, y; bool found;
    fetchHandlePart(20, x, y, found);
    assert(found, "preset scale X axis missing");
    auto camera = getJson("/api/camera");
    int px = cast(int)round(x), py = cast(int)round(y);
    playAndWait(buildDragLog(cast(int)camera["vpX"].integer,
        cast(int)camera["vpY"].integer, cast(int)camera["width"].integer,
        cast(int)camera["height"].integer, px, py, px + dx, py + dy));
}

unittest {
    auto fixture = parseJSON(import("fixtures/preset_scale_session.json"));
    foreach (branch; ["R", "C"]) {
        invoke("tool.set TransformScale off");
        invoke("scene.reset", false);
        invoke(`{"id":"scene.loadMesh","params":{"vertices":[[-0.5,0,0.1],[1,-0.25,0.2],[0.2,1.1,-0.3],[1.4,0.6,0.75]],"faces":[[0,1,2]]}}`, false);
        invoke("select.typeFrom vertex", false);
        invoke(`{"id":"mesh.select","params":{"mode":"vertices","indices":[0,1,2]}}`, false);
        invoke("viewport.view Top");
        invoke("history.clear");
        void check(string cp, size_t undo, size_t redo, bool active) {
            auto vertices = getJson("/api/model")["vertices"].array;
            auto expected = fixture["branches"][branch][cp].array;
            assert(vertices.length == 4 && expected.length == 4, "scale subject population");
            foreach (i; 0 .. 4) {
                double squared = 0;
                foreach (axis; 0 .. 3) {
                    double delta = vertices[i].array[axis].floating - expected[i].array[axis].floating;
                    squared += delta * delta;
                }
                assert(sqrt(squared) <= (i == 3 ? 1e-5 : fixture["tolerance"].floating),
                    format("scale %s/%s vertex %s moved differently: %s", branch, cp, i, vertices[i]));
            }
            auto history = getJson("/api/history");
            assert(history["undo"].array.length == undo && history["redo"].array.length == redo,
                format("scale %s/%s history cursor mismatch: %s", branch, cp, history));
            auto tool = getJson("/api/tool/state");
            assert((("tool" in tool) !is null && tool["tool"].str == "xfrm") == active, "scale session ownership: " ~ cp);
            if (active) assert(tool["session"]["armed"].boolean, "scale postmode lost: " ~ cp);
            auto selected = getJson("/api/selection")["selectedVertices"].array;
            assert(selected.length == 3 && selected[0].integer == 0 &&
                selected[1].integer == 1 && selected[2].integer == 2, "scale selection changed");
        }
        check("prearm", 0, 0, false);
        invoke("tool.set TransformScale on"); check("arm", 1, 0, true);
        gesture(30, 0); check("positive1", 2, 0, true);
        gesture(19, 0); check("positive2", 3, 0, true);
        navigate(false); check("undo1", 2, 1, true);
        navigate(false); check("undo2", 1, 2, true);
        navigate(true); check("redo1", 2, 1, true);
        navigate(true); check("redo2", 3, 0, true);
        invoke("tool.set TransformScale off"); check("close", 3, 0, false);
        navigate(false); check("outside_undo", 1, 2, true);
        if (branch == "R") {
            navigate(true); check("outside_redo", 3, 0, true);
        } else {
            invoke("tool.set TransformScale on"); check("branch_rearm", 2, 0, true);
            gesture(0, 0); check("zero_delta", 2, 0, true);
            gesture(19, 0); check("branch_positive", 3, 0, true);
        }
    }
}
