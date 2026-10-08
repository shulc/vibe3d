// Bridge publication through production clicks, keys and inactive dirty cells.
module test_bridge_live_lifecycle;

import http_client : getJson, postJson, frameFence, quiesce;
import http_command_helpers : commandBody;
import drag_helpers : fetchCamera, buildDragLog, buildDragDownLog, buildDragMotionLog,
    buildDragUpLog, playAndWait;
import viewport_lattice_helpers : fillLattice, kFillNX, kFillNY;
import std.exception : enforce, collectException;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.math : abs;
import std.stdio : writeln, writefln, File, stdin;
import std.conv : to;
import std.file : getcwd, tempDir, exists, mkdirRecurse, rmdirRecurse, symlink;
import std.path : buildPath;
import std.process : Config, Pid, environment, spawnProcess, tryWait, kill, thisProcessID;
import std.socket : Socket, AddressFamily, SocketType, ProtocolType, InternetAddress,
    SocketOptionLevel, SocketOption;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;

private enum kTool = "mesh.bridgeTool";
private enum kPopulation = kFillNX * kFillNY;
private enum string kBlocks = `{"vertices":[
    [-1,-0.8,-2],[1,-0.8,-2],[1,0.8,-2],[-1,0.8,-2],
    [-1,-0.8,-0.7],[1,-0.8,-0.7],[1,0.8,-0.7],[-1,0.8,-0.7],
    [-0.45,-0.45,0.8],[1.15,-0.45,0.8],[1.15,0.95,0.8],[-0.45,0.95,0.8],
    [-0.45,-0.45,2.1],[1.15,-0.45,2.1],[1.15,0.95,2.1],[-0.45,0.95,2.1]],
    "faces":[[3,2,1,0],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7],
    [11,10,9,8],[12,13,14,15],[8,9,13,12],[9,10,14,13],[10,11,15,14],[11,8,12,15]]}`;
private int[4] replayViewport;
void play(string log) {
    import std.string : indexOf;
    auto newline = log.indexOf('\n');
    if (newline >= 0 && log[0..newline].indexOf("VIEWPORT") >= 0) log = log[newline+1..$];
    playAndWait(format(`{"t":0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        replayViewport[0], replayViewport[1], replayViewport[2], replayViewport[3]) ~ log);
    fence();
}
long number(JSONValue j) { return j.type == JSONType.uinteger ? cast(long)j.uinteger : j.integer; }
private struct PixelInstance { ushort port; string root; Pid pid; }
private PixelInstance launchPixelInstance() {
    PixelInstance child;
    foreach (port; 8590 .. 8600) {
        auto socket = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
        scope(exit) socket.close();
        try {
            socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort)port));
            child.port = cast(ushort)port; break;
        } catch (Exception) {}
    }
    enforce(child.port >= 8590 && child.port <= 8599, "no free assigned child port");
    child.root = buildPath(tempDir(), format("vibe3d-bridge-lifecycle-%d-%d", thisProcessID(), child.port));
    enforce(!exists(child.root), "private child scratch path already exists");
    mkdirRecurse(child.root); scope(failure) stopPixelInstance(child);
    auto repo = getcwd();
    symlink(buildPath(repo, "config"), buildPath(child.root, "config"));
    symlink(buildPath(repo, "assets"), buildPath(child.root, "assets"));
    auto childEnv = environment.toAA();
    childEnv["VIBE3D_CONFIG_DIR"] = child.root; childEnv["VIBE3D_TEST_DIRTY_KEY"] = "1";
    childEnv["LIBGL_ALWAYS_SOFTWARE"] = "1";
    childEnv["VIBE3D_TEST_LAYOUT_INI"] = buildPath(child.root, "layout.ini");
    auto log = File(buildPath(child.root, "editor.log"), "wb");
    child.pid = spawnProcess([buildPath(repo, "vibe3d"), "--test", "--viewport", "1024x544", "--http-port", child.port.to!string],
        stdin, log, log, childEnv, Config.none, child.root);
    const deadline = MonoTime.currTime + 6.seconds;
    while (MonoTime.currTime < deadline && !tryWait(child.pid).terminated) {
        try {
            auto ready = getJson("/api/camera", "http://127.0.0.1:" ~ child.port.to!string);
            if (number(ready["width"]) > 64) return child;
        } catch (Exception) {}
        Thread.sleep(25.msecs);
    }
    enforce(false, "private dirty-key pixel editor did not become ready");
    return child;
}
private void stopPixelInstance(ref PixelInstance child) {
    scope(exit) if (child.root.length && exists(child.root)) rmdirRecurse(child.root);
    if (child.pid !is null) {
        if (!tryWait(child.pid).terminated) {
            kill(child.pid);
            auto deadline = MonoTime.currTime + 1.seconds;
            while (!tryWait(child.pid).terminated && MonoTime.currTime < deadline) Thread.sleep(25.msecs);
            if (!tryWait(child.pid).terminated) kill(child.pid, 9);
        }
        auto deadline = MonoTime.currTime + 2.seconds;
        while (!tryWait(child.pid).terminated && MonoTime.currTime < deadline) Thread.sleep(25.msecs);
        enforce(tryWait(child.pid).terminated, "private pixel editor PID survived teardown");
        child.pid = null;
    }
    if (child.port) {
        auto socket = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
        scope(exit) socket.close();
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        socket.bind(new InternetAddress(InternetAddress.ADDR_ANY, child.port));
        socket.listen(1);
    }
}

void cmd(string line, bool ui = false) {
    auto r = postJson(ui ? "/api/command?origin=ui" : "/api/command", line);
    enforce(r["status"].str == "ok" || r["status"].str == "success", "command failed: " ~ line ~ " => " ~ r.toString);
}
void command(string id, string args = "{}") { cmd(commandBody(id, args)); }
void fence() { quiesce(); frameFence(null, 2); }
string planes() { return getJson("/api/mesh/planes").toString; }
JSONValue rows() { return getJson("/api/history"); }
JSONValue state() { return getJson("/api/tool/state"); }
bool activeBridge() { auto s=state(); return "tool" in s && s["tool"].str == kTool; }
void cleanup() {
    collectException(cmd("tool.release"));
    collectException(command("viewport.layout", `{"preset":"Single"}`));
}
void key(int sym, uint mod = 0) {
    play(format(`{"t":0,"type":"PACE","mode":"frames"}` ~ "\n" ~
        `{"t":50,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%u,"repeat":0}` ~ "\n" ~
        `{"t":100,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":0,"repeat":0}` ~ "\n", sym, mod, sym));
}
void undo() { key(122, 64); }
void redo() { key(122, 65); }
void space() { key(32); }
void gesture(int dx = 0) {
    auto c = fetchCamera();
    auto x = c.vpX + 24, y = c.vpY + c.height - 24;
    play(buildDragLog(c.vpX, c.vpY, c.width, c.height, x, y, x+dx, y, dx ? 3 : 0));
}
void select(string indices) {
    command("mesh.select", `{"mode":"polygons","indices":` ~ indices ~ `}`);
    fence();
}
struct Seed { string one, both; JSONValue oneRows, bothRows; }
Seed setup() {
    cleanup();
    command("scene.reset", `{"empty":true}`);
    command("scene.loadMesh", kBlocks);
    command("viewport.displayStyle", `{"value":"shaded"}`);
    command("viewport.wireOverlay", `{"value":"none"}`);
    command("viewport.cavityParams", `{"screenRidge":0,"screenValley":0}`);
    command("viewport.cavity", `{"value":"screen"}`);
    command("viewport.smooth", `{"value":"off"}`);
    enforce(postJson("/api/camera", `{"azimuth":0.85,"elevation":0.38,"distance":8.5,"focus":{"x":0.1,"y":0.1,"z":0.05}}`)["status"].str == "ok", "calibrated source camera");
    // Record genuine, distinct selection rows AFTER clearing load history.
    cmd("history.clear");
    select("[1]"); Seed seed; seed.one = planes(); seed.oneRows = rows();
    select("[1,6]"); seed.both = planes(); seed.bothRows = rows();
    enforce(seed.one != seed.both && seed.oneRows["undo"].array.length == 1 &&
        seed.bothRows["undo"].array.length == 2 && seed.bothRows["redo"].array.length == 0,
        "SEEDED_SELECTION_POPULATION: distinct one/two-cap planes and two recorded rows");
    auto model = getJson("/api/model");
    enforce(model["vertices"].array.length == 16 && model["faces"].array.length == 12,
        "SOURCE_TOPOLOGY_FLOOR: asymmetric two-block fixture");
    park(); return seed;
}
void park() {
    auto c = fetchCamera();
    play(format(`{"t":0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
        c.vpX+24, c.vpY+c.height-24));
}
void arm(bool ui = false) {
    cmd("tool.set " ~ kTool ~ " on", ui); fence();
    auto s = state();
    enforce(s["tool"].str == kTool && s["valid"].boolean && !s["engaged"].boolean,
        "ARM_STATE: Bridge starts valid and unengaged");
}
struct Pixel { int r,g,b; }
struct Geometry { long id, flags, nx, ny; }
struct Image { int w,h; Pixel[] color; Geometry[] geometry; }
Image probe(int cell = 0) {
    auto dims = getJson(format("/api/viewport/probe?cell=%d", cell));
    Image im; im.w = cast(int)number(dims["w"]); im.h = cast(int)number(dims["h"]);
    enforce(im.w >= 360 && im.h >= 300, "PROBE_ENVELOPE: lattice must fit");
    auto pts = fillLattice(im.w,im.h);
    auto color = getJson(format("/api/viewport/probe?cell=%d&points=",cell) ~ pts);
    auto geometry = getJson(format("/api/viewport/probe?cell=%d&buffer=gbuf&points=",cell) ~ pts);
    enforce("error" !in color && "error" !in geometry, "PROBE_BUFFERS: " ~ color.toString[0..30] ~ " / " ~ geometry.toString);
    enforce(color["renders"].boolean && geometry["renders"].boolean, "PROBE_RENDERED: allocated production buffers");
    foreach (p; color["points"].array) {
        enforce("error" !in p, "valid color probe");
        im.color ~= Pixel(cast(int)number(p["r"]),cast(int)number(p["g"]),cast(int)number(p["b"]));
    }
    foreach (p; geometry["points"].array) {
        enforce("error" !in p && p["gbuf"].array.length == 6, "valid geometry probe");
        auto a = p["gbuf"].array;
        im.geometry ~= Geometry(number(a[2]),number(a[3]),number(a[4]),number(a[5]));
    }
    enforce(im.color.length == 3000 && im.geometry.length == 3000, "PROBE_POPULATION: 3000 samples per channel");
    return im;
}
bool same(Pixel a, Pixel b) { return abs(a.r-b.r)<=2 && abs(a.g-b.g)<=2 && abs(a.b-b.b)<=2; }
void matches(in Image a, in Image b, string id) {
    enforce(a.w == b.w && a.h == b.h && a.color.length == kPopulation && b.color.length == kPopulation,
        "MATCH_POPULATION: equal camera cells and complete lattice");
    size_t different, colors, geometries;
    foreach (i; 0..kPopulation) {
        bool equalGeometry = a.geometry[i].id == 0 && b.geometry[i].id == 0 || a.geometry[i] == b.geometry[i];
        if (!same(a.color[i],b.color[i])) ++colors;
        if (!equalGeometry) { if (geometries == 0) writefln("  GEOMETRY_DIFF %s index=%d before=%s after=%s",id,i,a.geometry[i],b.geometry[i]); ++geometries; }
        if (!same(a.color[i], b.color[i]) || !equalGeometry) ++different;
    }
    enforce(different == 0, format("%s: %d changed samples (color=%d geometry=%d)",id,different,colors,geometries));
}
void connector(in Image source, in Image live, string id) {
    enforce(source.color.length == kPopulation && live.color.length == kPopulation, "CONNECTOR_POPULATION: complete source and result lattice");
    size_t sourceCount, added, changed;
    foreach (i; 0..kPopulation) {
        if (source.geometry[i].id != 0) ++sourceCount;
        if (source.geometry[i].id == 0 && live.geometry[i].id != 0) {
            ++added;
            if (!same(source.color[i], live.color[i])) ++changed;
        }
    }
    enforce(sourceCount >= 80 && added >= 20 && changed >= 20,
        format("%s: source=%d connector=%d colored=%d",id,sourceCount,added,changed));
    writefln("  %s source=%d connector=%d colored=%d",id,sourceCount,added,changed);
}
void intact(Seed seed, JSONValue history, string id) {
    enforce(planes() == seed.both && rows() == history, id ~ ": exact source/selection/rows changed");
}
void priorUndo(Seed seed) {
    undo(); enforce(planes() == seed.one && rows()["undo"] == seed.oneRows["undo"], "PRIOR_UNDO: next key must move exactly last selection row");
    redo(); enforce(planes() == seed.both && rows() == seed.bothRows, "PRIOR_REDO: key restores seeded selection and rows");
}
void armedCell() {
    foreach (ui; [false,true]) {
        auto seed = setup(); auto original = probe(); arm(ui);
        auto armedRows = rows();
        enforce(planes() == seed.both && armedRows == seed.bothRows, "A_ARM_ROWS: measured script/UI arm records no activation row");
        matches(original,probe(),"A_ARM_SOURCE_DISPLAY");
        writefln("  A arm origin=%s undo=%d redo=%d",ui ? "ui":"script",armedRows["undo"].array.length,armedRows["redo"].array.length);
        space(); intact(seed,armedRows,"A_SPACE");
        enforce(!activeBridge(),"A_SPACE_DROP: real Space drops unengaged Bridge");
        matches(original,probe(),"A_SPACE_SOURCE_DISPLAY");
    }
    auto seed = setup(); auto original = probe(); arm(); undo();
    enforce(planes() == seed.one && rows()["undo"] == seed.oneRows["undo"],"A_UNDO: unengaged key navigates prior selection");
    redo(); enforce(planes() == seed.both && rows() == seed.bothRows,"A_REDO: restore prior selection");
    matches(original,probe(),"A_REDO_SOURCE_DISPLAY");
}
void engage(string kind) {
    if (kind == "attr") { cmd("tool.attr " ~ kTool ~ " segments 3"); fence(); }
    else gesture(kind == "drag" ? 60 : 0);
    enforce(state()["tool"].str == kTool && state()["engaged"].boolean, "ENGAGEMENT: accepted production door keeps Bridge live");
    enforce(state()["segments"].integer == (kind == "drag" ? 4 : kind == "attr" ? 3 : 1),"SEGMENTS: existing 20px haul and attribute values");
}
void committedCell(string kind) {
    auto seed = setup(); auto original = probe(); arm(); auto before = state(); engage(kind);
    auto live = probe(); connector(original,live,"C_" ~ kind ~ "_PREVIEW");
    intact(seed,seed.bothRows,"C_LIVE");
    if (kind == "click") {
        foreach (name; ["segments","twist","mode","tension","connect","remove","flip","orient","uvs","autoStep","steps","continuous"])
            enforce(state()[name] == before[name],"CLICK_PARAMETERS: no-motion click changes no attributes");
    }
    space(); auto saved = planes(); auto savedRows = rows();
    enforce(!activeBridge() && saved != seed.both && savedRows["undo"].array.length == 3 &&
        savedRows["undo"].array[0..2] == seed.bothRows["undo"].array,
        "C_SPACE_ONE_EDIT: Space commits one Bridge edit after both selection rows");
    auto expectedFaces = kind == "drag" ? 26 : kind == "attr" ? 22 : 14;
    enforce(getJson("/api/model")["faces"].array.length == expectedFaces,"C_COMMITTED_TOPOLOGY: exact Bridge result");
    matches(live,probe(),"C_DISPLAY_MATCH");
    cmd("tool.release"); intactAfterRelease(saved,savedRows);
    undo();
    enforce(planes() == seed.both && rows()["undo"] == seed.bothRows["undo"] && rows()["redo"].array.length == 1,
        "C_KEY_UNDO: exact source/selection and both prior rows retained");
    park(); matches(original,probe(),"C_UNDO_SOURCE_DISPLAY");
    redo(); enforce(planes() == saved && rows() == savedRows,"C_KEY_REDO: exact committed result and rows");
    matches(live,probe(),"C_REDO_DISPLAY");
}
void intactAfterRelease(string saved, JSONValue history) {
    enforce(planes() == saved && rows() == history,"DOUBLE_RELEASE: repeated release cannot commit twice");
}
void cancelCell(string kind) {
    auto seed = setup(); auto original = probe(); auto cameraBefore=getJson("/api/camera"); arm(); engage(kind);
    connector(original,probe(),"U_" ~ kind ~ "_PREVIEW"); intact(seed,seed.bothRows,"U_BEFORE");
    undo(); intact(seed,seed.bothRows,"U_CANCEL_PRIORITY");
    enforce(!activeBridge(),"U_CANCEL_DROP: current Bridge cancel lifetime drops tool");
    park(); enforce(getJson("/api/camera") == cameraBefore,"U_CAMERA_STABLE");
    matches(original,probe(),"U_CANCEL_SOURCE_DISPLAY");
    dirtyWitness("U_CANCEL_SETTLED_SKIP");
    cmd("tool.release"); intact(seed,seed.bothRows,"U_RELEASE_NO_COMMIT");
    priorUndo(seed);
}
void heldCell() {
    foreach (button; [1,3]) {
        auto seed = setup(); arm(); gesture(); intact(seed,seed.bothRows,"H_BEFORE");
        auto c = fetchCamera(); auto x=c.vpX+24, y=c.vpY+c.height-24;
        play(buildDragDownLog(c.vpX,c.vpY,c.width,c.height,x,y,0,cast(ubyte)button));
        scope(exit) collectException(play(buildDragUpLog(c.vpX,c.vpY,c.width,c.height,x,y,0,cast(ubyte)button)));
        if (button == 1) play(buildDragMotionLog(c.vpX,c.vpY,c.width,c.height,x,y,x+20,y,1));
        auto held = state(); undo(); space();
        intact(seed,seed.bothRows,"H_HELD_KEYS");
        enforce(state() == held && state()["engaged"].boolean,"H_KEY_REFUSAL: held Undo/Space preserve live state");
        play(buildDragUpLog(c.vpX,c.vpY,c.width,c.height,x+20,y,0,cast(ubyte)button));
        intact(seed,seed.bothRows,"H_RELEASE_NO_REPLAY");
        enforce(state()["tool"].str == kTool && state()["engaged"].boolean,"H_RELEASE_LIVE: discarded keys stay discarded");
        undo(); intact(seed,seed.bothRows,"H_UNHELD_CANCEL");
        enforce(!activeBridge(),"H_UNHELD_DROP"); priorUndo(seed);
    }
}
void dirtyWitness(string id) {
    auto before = getJson("/api/frames/counts")["totals"]; frameFence(null,4);
    auto after = getJson("/api/frames/counts")["totals"];
    auto considered=number(after["cellsConsidered"])-number(before["cellsConsidered"]);
    auto rendered=number(after["cellsRendered"])-number(before["cellsRendered"]);
    enforce(considered >= 4 && rendered < considered,id ~ ": settled production dirty gate must skip cells");
    writefln("  %s considered=%d rendered=%d",id,considered,rendered);
}
void dirtyCell(bool publicationOnly = false) {
    auto seed = setup(); command("viewport.layout",`{"preset":"SplitH"}`); fence();
    foreach (cell; 0..2) {
        enforce(postJson(format("/api/camera?viewport=%d",cell),`{"azimuth":0.85,"elevation":0.38,"distance":8.5,"focus":{"x":0.1,"y":0.1,"z":0.05}}`)["status"].str == "ok","SPLIT_CAMERA");
        command("viewport.displayStyle",format(`{"value":"shaded","viewport":%d}`,cell));
        command("viewport.wireOverlay",format(`{"value":"none","viewport":%d}`,cell));
        command("viewport.cavityParams",format(`{"screenRidge":0,"screenValley":0,"viewport":%d}`,cell));
        command("viewport.cavity",format(`{"value":"screen","viewport":%d}`,cell));
        command("viewport.smooth",format(`{"value":"off","viewport":%d}`,cell));
    }
    park(); fence(); auto display = getJson("/api/viewport/display");
    enforce(display["cells"].array.length == 2 && number(display["activeId"]) == 0,"SPLIT_OWNER: two cells with pointer parked in cell0");
    auto camera0=getJson("/api/camera?viewport=0"), camera1=getJson("/api/camera?viewport=1");
    Image[2] original,live;
    foreach (cell; 0..2) original[cell]=probe(cell);
    arm(); foreach (cell; 0..2) matches(original[cell],probe(cell),"DIRTY_ARM_SOURCE");
    dirtyWitness("DIRTY_ARM_SKIP"); auto armed=state(); gesture();
    enforce(state()["segments"] == armed["segments"] && state()["engaged"].boolean,"DIRTY_ZERO_MOTION: click must publish without an upload");
    foreach (cell; 0..2) { live[cell]=probe(cell); connector(original[cell],live[cell],format("DIRTY_CLICK_CELL_%d",cell)); }
    enforce(number(getJson("/api/viewport/display")["activeId"]) == 0 && getJson("/api/camera?viewport=0") == camera0 && getJson("/api/camera?viewport=1") == camera1,"DIRTY_INACTIVE_OWNER: cell1 remains inactive under unchanged camera");
    dirtyWitness("DIRTY_LIVE_SKIP"); intact(seed,seed.bothRows,"DIRTY_LIVE_SOURCE");
    if (publicationOnly) return;
    undo(); intact(seed,seed.bothRows,"DIRTY_CANCEL_PRIORITY");
    foreach (cell; 0..2) matches(original[cell],probe(cell),"DIRTY_CANCEL_SOURCE");
    dirtyWitness("DIRTY_CANCEL_SETTLED_SKIP");
    // Restore and engage again, then compare each inactive readback to its
    // ordinary committed model without any camera/style invalidation.
    arm(); gesture(); space();
    foreach (cell; 0..2) matches(live[cell],probe(cell),"DIRTY_COMMITTED_MATCH");
    enforce(number(getJson("/api/viewport/display")["activeId"]) == 0,"DIRTY_FINAL_OWNER");
}
JSONValue documentModel() {
    auto model = getJson("/api/model"); model.object.remove("timestamp"); return model;
}
JSONValue moveHandles() {
    auto handles = getJson("/api/tool/handles")["handles"];
    size_t visible;
    foreach (part; handles["parts"].array)
        if (part["visible"].boolean && part["screen"].type == JSONType.array) ++visible;
    enforce(visible >= 4,"MOVE_HANDLE_POPULATION: four visible anchored handles");
    return handles;
}
string handlePoints(JSONValue handles) {
    string points; size_t samples; auto camera = fetchCamera();
    foreach (part; handles["parts"].array) {
        if (!part["visible"].boolean || part["screen"].type != JSONType.array) continue;
        auto screen = part["screen"].array;
        auto x = cast(int)screen[0].floating - camera.vpX, y = cast(int)screen[1].floating - camera.vpY;
        foreach (dy; -6 .. 7) foreach (dx; -6 .. 7) {
            ++samples; points ~= format("%d,%d;",x+dx,y+dy);
        }
    }
    enforce(samples >= 676,"MOVE_SAMPLE_POPULATION: 169 samples around each visible anchor");
    return points;
}
Pixel[] colorsAt(string points) {
    auto reply = getJson("/api/viewport/probe?cell=0&points=" ~ points);
    enforce("error" !in reply,"MOVE_COLOR_PROBE: allocated source buffer");
    Pixel[] result;
    foreach (p; reply["points"].array) {
        enforce("error" !in p,"MOVE_COLOR_SAMPLE: sample inside cell");
        result ~= Pixel(cast(int)number(p["r"]),cast(int)number(p["g"]),cast(int)number(p["b"]));
    }
    enforce(result.length >= 676,"MOVE_COLOR_POPULATION: all anchor samples read");
    return result;
}
void moveCell() {
    // Calibrate only the readback locations, then rebuild the identical source
    // before freezing the scored source. No projected handle model is duplicated.
    setup(); cmd("tool.set move on"); fence(); auto anchors = moveHandles();
    auto points = handlePoints(anchors); cmd("tool.release"); fence();
    auto seed = setup(); auto original = probe(); auto sourceColors = colorsAt(points);
    auto model = documentModel(), selection = getJson("/api/selection");
    auto camera = getJson("/api/camera"), beforeDisplay = getJson("/api/viewport/display");
    enforce(number(beforeDisplay["cells"].array[0]["toolPreviewKey"]) == 0,"MOVE_SOURCE_STAMP_ZERO");
    cmd("tool.set move on"); fence(); auto liveHandles = moveHandles();
    enforce(handlePoints(liveHandles) == points,"MOVE_ANCHORS_STABLE: scored arm has calibrated handles");
    auto liveColors = colorsAt(points); size_t changed;
    enforce(liveColors.length == sourceColors.length,"MOVE_SAMPLES_EQUAL: complete paired anchor populations");
    foreach (i; 0 .. liveColors.length) if (!same(liveColors[i],sourceColors[i])) ++changed;
    enforce(changed >= 20,format("MOVE_VISIBLE_IMAGE: colored handle floor20, measured%d",changed));
    auto armedRows=rows(); auto armedDisplay=getJson("/api/viewport/display");
    enforce(planes() == seed.both,"MOVE_ARM_PLANES");
    enforce(documentModel() == model,"MOVE_ARM_MODEL");
    enforce(getJson("/api/selection") == selection,"MOVE_ARM_SELECTION");
    enforce(getJson("/api/camera") == camera,"MOVE_ARM_CAMERA");
    cmd("tool.release"); fence();
    auto dropped=state(); enforce("tool" !in dropped || dropped["tool"].str == "none" || dropped["tool"].str == "","MOVE_RELEASE_DROP: tool absent");
    enforce(planes() == seed.both && documentModel() == model && getJson("/api/selection") == selection && getJson("/api/camera") == camera,"MOVE_RELEASE_SOURCE: frozen document and camera restored");
    auto droppedDisplay=getJson("/api/viewport/display");
    enforce(number(droppedDisplay["cells"].array[0]["toolPreviewKey"]) == 0,"MOVE_RELEASE_STAMP_ZERO");
    matches(original,probe(),"MOVE_RELEASE_SOURCE_DISPLAY");
    auto restored=colorsAt(points);
    foreach (i; 0 .. restored.length) enforce(same(restored[i],sourceColors[i]),"MOVE_RELEASE_HANDLE_PIXELS: source colors restored at handle anchors");
    dirtyWitness("MOVE_RELEASE_SETTLED_SKIP");
    writefln("  MOVE_CONTROL colored=%d armRows=%s releaseRows=%s sourceDisplay=%s armedDisplay=%s releaseDisplay=%s",changed,armedRows,rows(),beforeDisplay,armedDisplay,droppedDisplay);
}
int main() {
    import liveness_gate : scenario;
    const hadPort = ("VIBE3D_TEST_PORT" in environment.toAA()) !is null;
    const priorPort = environment.get("VIBE3D_TEST_PORT","");
    scope(exit) { if (hadPort) environment["VIBE3D_TEST_PORT"] = priorPort; else environment.remove("VIBE3D_TEST_PORT"); }
    auto child=launchPixelInstance(); scope(exit) stopPixelInstance(child);
    environment["VIBE3D_TEST_PORT"]=child.port.to!string;
    scope(exit) cleanup(); fence();
    auto full=fetchCamera(); replayViewport=[full.vpX,full.vpY,full.width,full.height];
    dirtyWitness("CHILD_DIRTY_KEY_CONTROL");
    auto filter=environment.get("VIBE3D_CELL",""); int passed,failed; string[] errors;
    void run(string id, void delegate() fn) {
        if (filter.length && filter != id) return;
        scenario(id);
        try { fn(); ++passed; writeln("  PASS: ",id); }
        catch (Exception e) { ++failed; errors ~= id ~ " — " ~ e.msg; writeln("  FAIL: ",id," — ",e.msg); cleanup(); }
    }
    run("arm",{armedCell();});
    foreach (kind; ["click","drag","attr"]) {
        run("commit-" ~ kind,{committedCell(kind);});
        run("cancel-" ~ kind,{cancelCell(kind);});
    }
    run("held",{heldCell();}); run("dirty",{dirtyCell();}); run("move",{moveCell();});
    if (filter == "dirty-publish") run("dirty-publish",{dirtyCell(true);});
    enforce(passed+failed == (filter.length ? 1 : 10),"SCENARIO_POPULATION: ten independent cells or one selected cell");
    cleanup(); stopPixelInstance(child);
    writefln("  CHILD_TERMINAL: PID stopped; assigned port %d bindable",child.port);
    if (errors.length) { import std.array : join; writeln("FAILURES: ",errors.join(" | ")); }
    writefln("%d passed, %d failed",passed,failed); return failed ? 1 : 0;
}
