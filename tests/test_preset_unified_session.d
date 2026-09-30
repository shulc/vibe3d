// Task 8560: a preset axis gesture keeps its center and selected subject while
// session navigation peels live steps, consolidates a closed run and branches.
// Evidence: doc/transform_8560_unified_capture.md and the measured fixture.
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

private void gesture(string bank, int dx, int dy) {
    double x, y; bool found;
    fetchHandlePart(bank == "T" ? 0 : bank == "R" ? 11 : 20, x, y, found);
    assert(found, "unified bank handle missing: " ~ bank);
    if (bank == "R") { x -= 1; y -= 119; }
    auto camera = getJson("/api/camera");
    int px = cast(int)round(x), py = cast(int)round(y);
    playAndWait(buildDragLog(cast(int)camera["vpX"].integer,
        cast(int)camera["vpY"].integer, cast(int)camera["width"].integer,
        cast(int)camera["height"].integer, px, py, px + dx, py + dy));
}

unittest {
    auto fixture = parseJSON(import("fixtures/preset_unified_session.json"));
    foreach (bank; ["T", "R", "S"]) foreach (branch; ["R", "C"]) {
        invoke("tool.set Transform off");
        invoke("scene.reset", false);
        invoke(`{"id":"scene.loadMesh","params":{"vertices":[[-0.5,0,0.1],[1,-0.25,0.2],[0.2,1.1,-0.3],[1.4,0.6,0.75]],"faces":[[0,1,2]]}}`, false);
        invoke("select.typeFrom vertex", false);
        invoke(`{"id":"mesh.select","params":{"mode":"vertices","indices":[0,1,2]}}`, false);
        invoke("viewport.view Top");
        invoke("history.clear");
        void check(string cp, size_t undo, size_t redo, bool active) {
            auto vertices = getJson("/api/model")["vertices"].array;
            auto expected = fixture["banks"][bank][branch][cp].array;
            assert(vertices.length == 4 && expected.length == 4, "unified subject population");
            foreach (i; 0 .. 4) {
                double squared = 0;
                foreach (axis; 0 .. 3) {
                    double delta = vertices[i].array[axis].floating - expected[i].array[axis].floating;
                    squared += delta * delta;
                }
                assert(sqrt(squared) <= (i == 3 ? 1e-5 : fixture["tolerance"].floating),
                    format("unified %s/%s vertex %s moved differently: %s", branch, cp, i, vertices[i]));
            }
            auto history = getJson("/api/history");
            assert(history["undo"].array.length == undo && history["redo"].array.length == redo,
                format("unified %s/%s history cursor mismatch: %s", branch, cp, history));
            auto tool = getJson("/api/tool/state");
            assert((("tool" in tool) !is null && tool["tool"].str == "xfrm") == active, "unified session ownership: " ~ cp);
            if (active) assert(tool["session"]["armed"].boolean, "unified postmode lost: " ~ cp);
            auto selected = getJson("/api/selection")["selectedVertices"].array;
            assert(selected.length == 3 && selected[0].integer == 0 &&
                selected[1].integer == 1 && selected[2].integer == 2, "unified selection changed");
        }
        check("prearm", 0, 0, false);
        invoke("tool.set Transform on"); check("arm", 1, 0, true);
        gesture(bank, bank == "T" ? 14 : 30, 0); check("positive1", 2, 0, true);
        gesture(bank, bank == "T" ? 10 : 19, bank == "R" ? 11 : 0); check("positive2", 3, 0, true);
        navigate(false); check("undo1", 2, 1, true);
        navigate(false); check("undo2", 1, 2, true);
        navigate(true); check("redo1", 2, 1, true);
        navigate(true); check("redo2", 3, 0, true);
        invoke("tool.set Transform off"); check("close", 3, 0, false);
        navigate(false); check("outside_undo", 1, 2, true);
        if (branch == "R") {
            navigate(true); check("outside_redo", 3, 0, true);
        } else {
            invoke("tool.set Transform on"); check("branch_rearm", 2, 0, true);
            gesture(bank, 0, 0); check("zero_delta", 2, 0, true);
            gesture(bank, bank == "T" ? 10 : 19, 0); check("branch_positive", 3, 0, true);
        }
    }
}

unittest { // All visible banks share the preset session's recorded navigation.
    auto fixture = parseJSON(import("fixtures/preset_unified_session.json"));
    foreach (branch; ["R", "C"]) {
    invoke("tool.set Transform off");
    invoke("scene.reset", false);
    invoke(`{"id":"scene.loadMesh","params":{"vertices":[[-0.5,0,0.1],[1,-0.25,0.2],[0.2,1.1,-0.3],[1.4,0.6,0.75]],"faces":[[0,1,2]]}}`, false);
    invoke("select.typeFrom vertex", false);
    invoke(`{"id":"mesh.select","params":{"mode":"vertices","indices":[0,1,2]}}`, false);
    invoke("viewport.view Top");
    invoke("history.clear");
    void check(string cp, size_t undo, size_t redo) {
        auto actual = getJson("/api/model")["vertices"].array;
        auto expected = fixture["mixed"][branch][cp].array;
        assert(actual.length == 4 && expected.length == 4, "mixed subject population");
        foreach (i; 0 .. 4) {
            double squared = 0;
            foreach (axis; 0 .. 3) {
                double delta = actual[i].array[axis].floating - expected[i].array[axis].floating;
                squared += delta * delta;
            }
            assert(sqrt(squared) <= (i == 3 ? 1e-5 : .02),
                format("mixed %s vertex %s diverged: %s", cp, i, actual[i]));
        }
        auto history = getJson("/api/history");
        assert(history["undo"].array.length == undo && history["redo"].array.length == redo,
            format("mixed %s history cursor mismatch: %s", cp, history));
        auto selected = getJson("/api/selection")["selectedVertices"].array;
        assert(selected.length == 3 && selected[0].integer == 0 &&
            selected[1].integer == 1 && selected[2].integer == 2, "mixed selection changed");
        auto tool = getJson("/api/tool/state");
        bool active = cp != "prearm" && cp != "close";
        assert((("tool" in tool) !is null && tool["tool"].str == "xfrm") == active,
            "mixed session ownership: " ~ cp);
        if (active) assert(tool["session"]["armed"].boolean, "mixed session disarmed: " ~ cp);
    }
    check("prearm", 0, 0);
    invoke("tool.set Transform on"); check("arm", 1, 0);
    gesture("T", -14, 0); check("positive1", 2, 0);
    gesture("T", -10, 0); check("positive2", 3, 0);
    gesture("R", 30, 0); check("positive3", 4, 0);
    gesture("T", -10, 0); check("positive4", 5, 0);
    gesture("S", 30, 0); check("positive5", 6, 0);
    auto mixedRows = getJson("/api/history")["undo"].array;
    assert(mixedRows[1]["runId"].integer == mixedRows[2]["runId"].integer,
        "mixed same-bank gestures unexpectedly advanced history run");
    foreach (i; 3 .. 6)
        assert(mixedRows[i]["runId"].integer == mixedRows[i - 1]["runId"].integer + 1,
            "mixed bank boundary did not advance history run exactly once");
    foreach (i; 1 .. 6) { navigate(false); check(format("undo%s", i), 6 - i, i); }
    foreach (i; 1 .. 6) { navigate(true); check(format("redo%s", i), 1 + i, 5 - i); }
    invoke("tool.set Transform off"); check("close", 6, 0);
    navigate(false); check("outside_undo", 1, 5);
    if (branch == "R") {
        navigate(true); check("outside_redo", 6, 0);
    } else {
        invoke("tool.set Transform on"); check("branch_rearm", 2, 0);
        gesture("T", 0, 0); check("zero_delta", 2, 0);
        gesture("T", -10, 0); check("branch_positive", 3, 0);
        invoke("tool.set Transform off");
        navigate(false); check("zero_delta", 2, 1);
        navigate(true); check("branch_positive", 3, 0);
    }
    }
}
