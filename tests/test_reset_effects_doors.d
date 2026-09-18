// Tasks 6020/6480: file.new and scene.reset run the full reset-effects
// capability, while scene.loadMesh gets only the narrow tool drop. All three
// doors are driven through the real registry and `/api/command` route.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json;
import core.thread : Thread;
import core.time : msecs;

void main() {}

void cmd(string script) {
    auto r = postJson("/api/command", script);
    assert(r["status"].str == "ok", "/api/command " ~ script ~ " failed: " ~ r.toString);
}

struct Preview { bool active, pending; long created, retired; }

Preview preview() {
    auto j = getJson("/api/subpatch/preview");
    return Preview(j["active"].type == JSONType.true_,
                   j["pending"].type == JSONType.true_,
                   j["topologiesCreated"].integer,
                   j["topologiesRetired"].integer);
}

void waitPreviewSettled() {
    foreach (_; 0 .. 1500) {
        if (!preview().pending) { Thread.sleep(80.msecs); return; }
        Thread.sleep(20.msecs);
    }
    assert(false, "6020 fixture: subpatch preview build did not settle");
}

long cellCount() { return getJson("/api/viewport/display")["cellCount"].integer; }
bool toolArmed() { return getJson("/api/tool/handles")["handles"].type != JSONType.null_; }
long vertexCount() { return getJson("/api/model")["vertices"].array.length; }

string falloffType() {
    foreach (stage; getJson("/api/toolpipe")["stages"].array)
        if (stage["id"].str == "falloff") return stage["attrs"]["type"].str;
    assert(false, "6480 fixture: falloff stage is missing");
}

void subpatchAllCubeFaces() {
    cmd("select.typeFrom polygon");
    cmd(commandBody("mesh.select", `{"mode":"polygons","indices":[0,1,2,3,4,5]}`));
    cmd(`{"id":"mesh.subpatch_toggle"}`);
    cmd(commandBody("mesh.select", `{"mode":"polygons","indices":[]}`));
    waitPreviewSettled();
}

struct DoorReading {
    string door;
    long liveBefore;
    long retiredByDoor;
    bool previewActiveAfter;
    long cellsAfter;
    bool toolAfter;
    long verticesAfter;
    string lastCommand;
    string lastLabel;
    string falloffAfter;
    long createdByNextBuild;   // -1 when the door leaves nothing to rebuild
}

DoorReading driveDoor(string door) {
    cmd(commandBody("scene.reset"));
    subpatchAllCubeFaces();
    cmd("viewport.layout Quad");
    cmd("falloff.linear");
    cmd("tool.set move on");

    const before = preview();
    DoorReading r;
    r.door = door;
    r.liveBefore = before.created - before.retired;
    // Population floors: every effect the door owes has something to undo.
    assert(before.active, "6020 floor: " ~ door ~ " fixture has no live preview");
    assert(r.liveBefore >= 1,
        "6020 floor: " ~ door ~ " fixture holds no cached topology, created "
        ~ before.created.to!string ~ " retired " ~ before.retired.to!string);
    assert(cellCount() == 4, "6020 floor: " ~ door ~ " fixture is not a four-cell layout");
    assert(toolArmed(), "6020 floor: " ~ door ~ " fixture has no armed tool");
    assert(falloffType() == "linear",
        "6020 floor: " ~ door ~ " fixture has no user-selected falloff");

    cmd(`{"id":"` ~ door ~ `"}`);
    const after = preview();
    r.retiredByDoor = after.retired - before.retired;
    r.previewActiveAfter = after.active;
    r.cellsAfter = cellCount();
    r.toolAfter = toolArmed();
    r.verticesAfter = vertexCount();
    r.falloffAfter = falloffType();
    auto undo = getJson("/api/history")["undo"].array;
    r.lastCommand = undo.length ? undo[$ - 1]["command"].str : "";
    r.lastLabel = undo.length ? undo[$ - 1]["label"].str : "";

    r.createdByNextBuild = -1;
    if (r.verticesAfter == 8) {
        // Same cube topology as the fixture: without the cache drop the next
        // build is a hit and creates nothing.
        subpatchAllCubeFaces();
        r.createdByNextBuild = preview().created - after.created;
    }
    return r;
}

DoorReading driveLoadMesh() {
    enum cube = `{"vertices":[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],`
        ~ `[0.5,0.5,-0.5],[-0.5,0.5,-0.5],[-0.5,-0.5,0.5],`
        ~ `[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]],`
        ~ `"faces":[[0,3,2,1],[4,5,6,7],[0,1,5,4],[3,7,6,2],`
        ~ `[1,2,6,5],[0,4,7,3]]}`;
    cmd(commandBody("scene.reset"));
    subpatchAllCubeFaces();
    cmd("viewport.layout Quad");
    cmd("falloff.linear");
    cmd("tool.set move on");

    const before = preview();
    DoorReading r;
    r.door = "scene.loadMesh";
    r.liveBefore = before.created - before.retired;
    assert(before.active && r.liveBefore >= 1,
        "6480 floor: scene.loadMesh fixture holds no live cached topology");
    assert(cellCount() == 4 && toolArmed() && falloffType() == "linear",
        "6480 floor: scene.loadMesh lacks Quad/tool/falloff state");

    cmd(commandBody("scene.loadMesh", cube));
    const after = preview();
    r.retiredByDoor = after.retired - before.retired;
    r.previewActiveAfter = after.active;
    r.cellsAfter = cellCount();
    r.toolAfter = toolArmed();
    r.verticesAfter = vertexCount();
    r.falloffAfter = falloffType();
    auto undo = getJson("/api/history")["undo"].array;
    r.lastCommand = undo.length ? undo[$ - 1]["command"].str : "";
    r.lastLabel = undo.length ? undo[$ - 1]["label"].str : "";

    // The loaded Mesh has a fresh identity/key, so its first preview build is
    // a miss even though the old topology allocation was not explicitly
    // retired. The direct retirement delta is the discriminating observable.
    r.createdByNextBuild = -1;
    return r;
}

unittest {
    const fileNew = driveDoor("file.new");
    const sceneReset = driveDoor("scene.reset");
    const sceneLoad = driveLoadMesh();
    cmd(commandBody("scene.reset"));

    const summary = format("file.new %s | scene.reset %s | scene.loadMesh %s",
                           fileNew, sceneReset, sceneLoad);
    assert(fileNew.lastCommand == "scene.reset" && sceneReset.lastCommand == "scene.reset"
            && fileNew.lastLabel == "Reset to empty" && sceneReset.lastLabel == "Reset to ",
        "6020 identity: both doors must record the reset command and its label; " ~ summary);
    assert(fileNew.verticesAfter == 0 && sceneReset.verticesAfter == 8,
        "6020 empty mode belongs to file.new only; " ~ summary);
    assert(!fileNew.toolAfter && !sceneReset.toolAfter,
        "6020 tool: a reset door left the tool armed; " ~ summary);
    assert(fileNew.cellsAfter == 1 && sceneReset.cellsAfter == 1,
        "6020 viewport effect: a reset door kept a multi-cell layout; " ~ summary);
    assert(!fileNew.previewActiveAfter && !sceneReset.previewActiveAfter,
        "6020 preview floor (not J's witness; R1/R2 are): a reset door left "
        ~ "the subpatch preview active; " ~ summary);
    assert(fileNew.falloffAfter == "none" && sceneReset.falloffAfter == "none",
        "6020 pipe-stage effect: a reset door kept a user-selected falloff; "
        ~ summary);
    assert(fileNew.retiredByDoor == fileNew.liveBefore
            && sceneReset.retiredByDoor == sceneReset.liveBefore,
        "6020 topology-cache effect: a reset door did not retire every cached "
        ~ "topology; " ~ summary);
    assert(sceneReset.createdByNextBuild == 1,
        "6020 topology-cache effect: the first build after scene.reset was not a "
        ~ "miss; " ~ summary);
    assert(sceneLoad.lastCommand == "scene.loadMesh"
            && sceneLoad.lastLabel == "Load mesh" && sceneLoad.verticesAfter == 8,
        "6480 scene.loadMesh identity/geometry changed; " ~ summary);
    assert(!sceneLoad.toolAfter && sceneLoad.cellsAfter == 4,
        "6480 scene.loadMesh must drop the tool without resetting layout; " ~ summary);
    assert(!sceneLoad.previewActiveAfter,
        "6480 measured load invalidation: the replaced mesh kept preview active; "
        ~ summary);
    assert(sceneLoad.falloffAfter == "linear",
        "6480 narrow load drop reset the user-selected falloff; " ~ summary);
    assert(sceneLoad.retiredByDoor == 0,
        "6480 narrow load drop explicitly retired the topology cache; " ~ summary);
}
