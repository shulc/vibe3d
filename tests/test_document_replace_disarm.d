// Document-replacing file loads must cross the shared tool-disarm seam after
// validation and before the live document is replaced. The first cell is the
// positive control: the same gesture really commits while its mesh survives.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, remove, write;
import std.format : format;
import std.json;
import std.net.curl : get, post;
import std.stdio : writeln;
import core.thread : Thread;
import core.time : msecs;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "mesh.mirrorTool";

struct Counts {
    size_t v, e, f;
    string toString() const {
        return v.to!string ~ "v/" ~ e.to!string ~ "e/" ~ f.to!string ~ "f";
    }
}

enum Counts kCube = Counts(8, 12, 6);
enum Counts kMirror = Counts(16, 24, 12);


JSONValue command(string id, string params = null) {
    const body_ = params.length
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : id;
    return postJson("/api/command", body_);
}

void cmd(string id, string params = null) {
    auto r = command(id, params);
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
}

void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

Counts counts(string suffix = null) {
    auto j = getJson("/api/model" ~ suffix);
    return Counts(cast(size_t)j["vertexCount"].integer,
                  cast(size_t)j["edgeCount"].integer,
                  cast(size_t)j["faceCount"].integer);
}

string[] editUndoLabels() {
    enum long toolLifecycleFlag = 1L << 10;
    string[] labels;
    foreach (e; getJson("/api/history")["undo"].array)
        if ((e["flags"].integer & toolLifecycleFlag) == 0)
            labels ~= e["label"].str;
    return labels;
}

void armEngagedMirror() {
    cmd("tool.set", `{"_positional":["` ~ TOOL ~ `"]}`);
    cmd("tool.attr", `{"_positional":["` ~ TOOL ~ `","mergeVerts","false"]}`);
    auto probe = postJson("/api/command",
        "tool.attr " ~ TOOL ~ " mergeVerts ?");
    assert(probe["status"].str == "ok",
        "the mirror fixture must have an active tool before judging disarm: "
        ~ probe.toString);
}

void dropMirror() {
    cmd("tool.set", `{"_positional":["` ~ TOOL ~ `","off"]}`);
}

/// A broken load leaves the tool active. End that surviving session so its
/// wrongly-rebound commit becomes observable in the loaded mesh; a fixed load
/// already dropped it, and the same request is the expected harmless refusal.
void exposeSurvivingLoadGesture() {
    postJson("/api/command", "tool.set " ~ TOOL ~ " off");
}

bool mirrorIsActive() {
    auto probe = postJson("/api/command",
        "tool.attr " ~ TOOL ~ " mergeVerts ?");
    return probe["status"].str == "ok";
}

void setupTwoCubeLayers() {
    resetCube();
    cmd("layer.duplicate");
    cmd("layer.select", `{"index":0,"mode":"set"}`);
    cmd("history.clear");
    assert(counts("?layer=0") == kCube,
        "layer fixture requires a cube at index 0");
    assert(counts("?layer=1") == kCube,
        "layer fixture requires a cube at index 1");
}

ulong crossings() {
    return cast(ulong)getJson("/api/tool/disarm")["crossings"].integer;
}

string nativeSeed() {
    enum path = "/tmp/vibe3d_3930_document_replace_seed.v3d";
    if (exists(path)) remove(path);
    resetCube();
    cmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "file.save did not create the native seed");
    return path;
}

string objSeed() {
    enum path = "/tmp/vibe3d_3930_document_replace_seed.obj";
    if (exists(path)) remove(path);
    resetCube();
    cmd("file.export.obj", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "file.export.obj did not create the interchange seed");
    return path;
}

// K1: positive control. A broken arm must fail here before any negative cell.
unittest {
    resetCube();
    cmd("history.clear");
    armEngagedMirror();
    dropMirror();
    const c = counts();
    assert(c == kMirror,
        "POSITIVE CONTROL FAILED: an intact-mesh mirror drop must produce "
        ~ kMirror.toString ~ ", got " ~ c.toString);
    assert(editUndoLabels() == ["Mirror"],
        "the intact-mesh mirror drop must record exactly one Mirror edit, got "
        ~ editUndoLabels().to!string);
}

// K2: a successful native load cancels and drops before replacing Document.
unittest {
    const path = nativeSeed();
    resetCube();
    cmd("history.clear");
    const C0 = crossings();
    armEngagedMirror();
    assert(crossings() == C0,
        "arming the native-load fixture must not itself cross the seam");

    cmd("file.load", `{"path":"` ~ path ~ `"}`);
    exposeSurvivingLoadGesture();
    const c = counts();
    assert(c == kCube,
        "a native .v3d load under a live mesh.mirrorTool gesture must hand "
        ~ "back exactly the loaded document (8v/12e/6f), got " ~ c.toString);
    assert(!editUndoLabels().canFind("Mirror"),
        "a native load must not commit the abandoned Mirror edit: "
        ~ editUndoLabels().to!string);
    assert(crossings() == C0 + 1,
        "a successful native load must cross the disarm seam exactly once");
    assert(getJson("/api/tool/disarm")["hadTool"].boolean,
        "the native-load crossing must report the armed tool");
}

// K3: reader refusal is before the seam and leaves the gesture live.
unittest {
    enum path = "/tmp/vibe3d_3930_invalid_document.v3d";
    write(path, `{"formatVersion":1,"layers":[]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    cmd("history.clear");
    armEngagedMirror();
    const C0 = crossings();
    auto r = command("file.load", `{"path":"` ~ path ~ `"}`);
    assert(r["status"].str == "error" && r["message"].str.canFind(path),
        "the invalid existing file must be refused by the reader and name its "
        ~ "path, got " ~ r.toString);
    assert(crossings() == C0,
        "a load that REFUSED must leave the gesture armed: crossings moved "
        ~ C0.to!string ~ " -> " ~ crossings().to!string);
    auto probe = postJson("/api/command",
        "tool.attr " ~ TOOL ~ " mergeVerts ?");
    assert(probe["status"].str == "ok",
        "a refused load must leave the mirror tool active: " ~ probe.toString);
    dropMirror();
    assert(counts() == kMirror,
        "the gesture surviving a refused load must still commit to 16v");
    resetCube();
}

// K5: the single-part interchange branch has the same seam ordering.
unittest {
    const path = objSeed();
    resetCube();
    cmd("history.clear");
    const C0 = crossings();
    armEngagedMirror();
    assert(crossings() == C0,
        "arming the interchange fixture must not itself cross the seam");

    cmd("file.import.obj", `{"path":"` ~ path ~ `"}`);
    exposeSurvivingLoadGesture();
    const c = counts();
    assert(c == kCube,
        "an interchange load under a live mesh.mirrorTool gesture must hand "
        ~ "back exactly the imported document (8v/12e/6f), got " ~ c.toString);
    assert(!editUndoLabels().canFind("Mirror"),
        "an interchange load must not commit the abandoned Mirror edit: "
        ~ editUndoLabels().to!string);
    assert(crossings() == C0 + 1,
        "a successful interchange load must cross the disarm seam exactly once");
    assert(getJson("/api/tool/disarm")["hadTool"].boolean,
        "the interchange crossing must report the armed tool");
}

// K6: a primary move drops first, so the outgoing edit commits to layer 0.
unittest {
    setupTwoCubeLayers();
    armEngagedMirror();
    const C0 = crossings();
    cmd("layer.select", `{"index":1,"mode":"set"}`);

    const own = counts("?layer=0");
    const other = counts("?layer=1");
    assert(own == kMirror,
        "the outgoing gesture must commit into the layer it was armed on: "
        ~ "layer 0 reads " ~ own.toString ~ " and layer 1 reads "
        ~ other.toString ~ " — it landed in the layer that was just selected");
    assert(other == kCube,
        "the primary move must not commit the outgoing gesture into layer 1: "
        ~ other.toString);
    auto d = getJson("/api/tool/disarm");
    assert(crossings() == C0 + 1 && d["hadTool"].boolean,
        "a genuine primary move must cross dropOnly exactly once with a tool");
    const labels = editUndoLabels();
    assert(labels == ["Mirror", "Select Layer"],
        "the tool commit must precede the layer-selection entry, got "
        ~ labels.to!string);
}

// K6b: an additive selection that keeps the primary must keep the tool live.
unittest {
    setupTwoCubeLayers();
    armEngagedMirror();
    const C0 = crossings();
    cmd("layer.select", `{"index":1,"mode":"add"}`);
    assert(mirrorIsActive(),
        "an item-selection expansion that keeps the primary must not drop "
        ~ "the armed tool");
    assert(crossings() == C0,
        "a selection expansion that keeps the primary must not cross the seam");
    dropMirror();
    assert(counts("?layer=0") == kMirror,
        "the gesture kept through an additive selection must remain live and "
        ~ "commit to its original layer");
}

// K6c: the range branch's no-anchor fallback is a guarded primary move.
unittest {
    setupTwoCubeLayers();
    armEngagedMirror();
    const C0 = crossings();
    cmd("layer.select", `{"mode":"clear"}`);
    assert(mirrorIsActive(),
        "clearing item selection keeps the latched primary and must keep the tool");
    assert(crossings() == C0,
        "the clear branch kept the primary but crossed the seam");
    cmd("history.clear");
    cmd("layer.select", `{"index":1,"mode":"range"}`);

    const own = counts("?layer=0");
    const other = counts("?layer=1");
    assert(own == kMirror,
        "the range branch must drop before its primary move: layer 0 reads "
        ~ own.toString ~ " and layer 1 reads " ~ other.toString);
    assert(other == kCube,
        "the range branch committed into the newly selected layer: "
        ~ other.toString);
    assert(crossings() == C0 + 1,
        "the range branch must cross the seam exactly once");
    assert(editUndoLabels() == ["Mirror", "Select Layer"],
        "the range branch must record Mirror before Select Layer, got "
        ~ editUndoLabels().to!string);
}

// Loop-slice helpers used only by K6e. Selection-seeded activation makes the
// replay independent of an exact GPU hover result.
struct V3 { double x, y, z; }

V3 vertexAt(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int findVertex(JSONValue m, V3 p) {
    import std.math : sqrt;
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vertexAt(m, i);
        const dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx * dx + dy * dy + dz * dz) < 1e-4) return cast(int)i;
    }
    return -1;
}

int loopSeedEdge() {
    auto m = getJson("/api/model");
    const a = findVertex(m, V3(-0.5, -0.5, -0.5));
    const b = findVertex(m, V3( 0.5, -0.5, -0.5));
    assert(a >= 0 && b >= 0, "loop-slice cube seed vertices are missing");
    foreach (i, e; m["edges"].array) {
        const x = cast(int)e.array[0].integer;
        const y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    assert(false, "loop-slice cube seed edge is missing");
    return -1;
}

void selectEdge(int index) {
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[` ~ index.to!string ~ `]}`));
    assert(r["status"].str == "ok", "edge selection failed: " ~ r.toString);
}

void playAndSettle(string log) {
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    bool finished;
    foreach (_; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.true_) { finished = true; break; }
        Thread.sleep(50.msecs);
    }
    assert(finished, "loop-slice replay did not finish within 10 seconds");
    Thread.sleep(150.msecs);
}

void buildLoopSlicePreview() {
    enum VPX = 150, VPY = 28, VPW = 650, VPH = 544;
    enum CX = VPX + VPW / 2, CY = VPY + VPH / 2;
    const log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n" ~
        `{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
        ~ "\n" ~
        `{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
        ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
        VPX, VPY, VPW, VPH, CX, CY, CX, CY, CX, CY);
    playAndSettle(log);
}

// K6e: a built standing preview becomes a recorded, undoable edit in layer 0.
unittest {
    setupTwoCubeLayers();
    selectEdge(loopSeedEdge());
    cmd("tool.set", `{"_positional":["mesh.loopSliceTool","on"]}`);
    buildLoopSlicePreview();

    auto st = getJson("/api/tool/state");
    assert(st["armed"].boolean && st["built"].boolean,
        "K6e requires an armed AND built loop-slice preview: " ~ st.toString);
    assert(!editUndoLabels().canFind("Loop Slice"),
        "the standing preview must not be committed before the layer switch");
    assert(counts("?layer=0") == Counts(12, 20, 10),
        "K6e requires the 12v/20e/10f standing cut in layer 0, got "
        ~ counts("?layer=0").toString);
    assert(counts("?layer=1") == kCube,
        "K6e requires an untouched cube in layer 1");
    const C0 = crossings();

    cmd("layer.select", `{"index":1,"mode":"set"}`);
    // S-1 evidence must survive the first red assertion in both the pre-fix
    // world and the alternative drop-preview mutation.
    writeln("K6e /api/history: ", getJson("/api/history").toString);
    writeln("K6e /api/model?layer=0: ",
            getJson("/api/model?layer=0").toString);

    auto d = getJson("/api/tool/disarm");
    assert(crossings() == C0 + 1 && d["hadTool"].boolean,
        "K6e primary move must cross the seam exactly once with the live tool");
    assert(counts("?layer=1") == kCube,
        "the loop-slice commit must not touch the newly selected layer");
    const labels = editUndoLabels();
    assert(labels.canFind("Loop Slice") && labels[$ - 1] != "Loop Slice",
        "an armed+built loop-slice preview must COMMIT into its own layer on "
        ~ "a layer switch: the undo stack carries no \"Loop Slice\" entry, "
        ~ "so the cut standing in layer 0 is unrecorded and cannot be undone; "
        ~ "got " ~ labels.to!string);
    assert(getJson("/api/tool/state").object.length == 0,
        "the layer switch must have dropped the loop-slice tool");

    auto u1 = postJson("/api/undo", "");
    auto u2 = postJson("/api/undo", "");
    assert(u1["status"].str == "ok" && u2["status"].str == "ok",
        "undoing Select Layer and Loop Slice must both succeed");
    assert(counts("?layer=0") == kCube,
        "two strict-LIFO undos must restore layer 0 to 8v/12e/6f, got "
        ~ counts("?layer=0").toString);
    resetCube();
}
