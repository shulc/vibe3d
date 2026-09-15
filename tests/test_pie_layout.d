module test_pie_layout;

import core.thread : Thread;
import core.time : dur;
import http_client : getJson, postJson;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.math : floor;

void main() {}

enum HEADER = `{"t":0,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}`;

int iv(JSONValue v) { return cast(int)v.integer; }
ulong publishes() { return cast(ulong)getJson("/api/pie")["publishes"].integer; }

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "command failed: " ~ line ~ " -> " ~ r.toString);
}

void awaitFrames(ulong before) {
    for (int i; i < 200; ++i) {
        auto status = getJson("/api/play-events/status");
        if (status["finished"].type == JSONType.TRUE && publishes() >= before + 2)
            return;
        Thread.sleep(dur!"msecs"(10));
    }
    assert(false, "pie record did not publish two fresh frames");
}

void play(string[] events) {
    immutable before = publishes();
    string log = HEADER ~ "\n";
    foreach (e; events) log ~= e ~ "\n";
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", r.toString);
    awaitFrames(before);
}

string motion(int x, int y, int t = 1) {
    return format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`,
                  t, x, y);
}

void openAt(int x, int y) {
    play([motion(x, y),
          format(`{"t":2,"type":"SDL_KEYDOWN","sym":32,"scan":44,"mod":64,"repeat":0,"ts":1000}`)]);
}

void closePie() {
    cmd("ui.pie close");
    Thread.sleep(dur!"msecs"(30));
}

JSONValue boxAt(JSONValue pie, int slot) {
    foreach (box; pie["boxes"].array)
        if (iv(box["slot"]) == slot) return box;
    assert(false, "pie box slot missing: " ~ slot.to!string);
}

JSONValue pixelAt(int x, int y) {
    auto p = getJson(format("/api/viewport/probe?target=frame&points=%d,%d", x, y));
    assert(p["target"].str == "frame" && p["points"].array.length == 1);
    return p["points"].array[0];
}

void assertRgb(JSONValue p, int r, int g, int b, string why) {
    assert(iv(p["r"]) == r && iv(p["g"]) == g && iv(p["b"]) == b,
        why ~ ": " ~ p.toString);
}

unittest { // L0/L1/L1b: population, fixed layout, and no edge clamp
    closePie();
    assert(!getJson("/api/pie")["open"].boolean, "L0 closed frames must publish");
    openAt(475, 330);
    auto pie = getJson("/api/pie");
    assert(pie["open"].boolean && pie["menu"].str == "viewport");
    assert(iv(pie["cx"]) == 475 && iv(pie["cy"]) == 330 && iv(pie["hover"]) == -1);
    immutable h = iv(pie["unitH"]), w = iv(pie["boxW"]);
    assert(h == 23, "L0 panel button height changed: " ~ h.to!string);
    assert(pie["boxes"].array.length == 7, "L0 holes must not draw boxes");
    string[] labels;
    foreach (box; pie["boxes"].array) labels ~= box["label"].str;
    assert(labels == ["Top", "Perspective", "Right", "Front", "Bottom", "Back", "Left"]);
    foreach (box; pie["boxes"].array) {
        immutable k = iv(box["slot"]);
        int x, y;
        immutable r = 2 * h;
        immutable neX = (r / 2 - w / 2) > cast(int)floor(r / 3.5)
            ? r / 2 - w / 2 : cast(int)floor(r / 3.5);
        immutable neY = cast(int)floor(-r / 2.0 - 0.75 * h);
        immutable seY = cast(int)floor(r / 2 - h / 2 + 0.25 * h);
        int swX = -r / 2 - w / 2;
        if (swX + w > -r / 3.5) swX = cast(int)floor(-r / 3.5 - w);
        switch (k) {
            case 0: x = -w / 2; y = -r - h; break;
            case 1: x = neX; y = neY; break;
            case 2: x = r; y = -h / 2; break;
            case 3: x = neX; y = seY; break;
            case 4: x = -w / 2; y = r; break;
            case 5: x = swX; y = seY; break;
            case 6: x = -r - w; y = -h / 2; break;
            default: assert(false);
        }
        assert(iv(box["x"]) == x && iv(box["y"]) == y
            && iv(box["w"]) == w && iv(box["h"]) == h, "L1 box law differs");
    }
    closePie();
    play([motion(10, 10)]);
    cmd("ui.pie viewport");
    Thread.sleep(dur!"msecs"(30));
    pie = getJson("/api/pie");
    assert(iv(pie["cx"]) == 10 && iv(pie["cy"]) == 10);
    assert(iv(boxAt(pie, 0)["y"]) == -3 * iv(pie["unitH"]), "L1b pie was edge-clamped");
    closePie();
}

unittest { // L2/L2b/L2c: angular hover, hub state, face pixels, no outer bound
    openAt(475, 330);
    auto pie = getJson("/api/pie");
    immutable h = iv(pie["unitH"]);
    assertRgb(pixelAt(480, 330), 178, 191, 207, "L2 idle hub fill");
    play([motion(475, 330 - (h - 1))]);
    pie = getJson("/api/pie");
    assert(iv(pie["hover"]) == -1 && pie["hub"]["state"].str == "idle");
    play([motion(475, 330 - h)]);
    pie = getJson("/api/pie");
    assert(iv(pie["hover"]) == 0 && pie["hub"]["state"].str == "aimed"
           && iv(pie["hub"]["tickSlot"]) == 0);
    assert(boxAt(pie, 0)["face"].str == "hover" && boxAt(pie, 2)["face"].str == "normal");
    auto b0 = boxAt(pie, 0), b2 = boxAt(pie, 2);
    assertRgb(pixelAt(475 + iv(b0["x"]) + 4, 330 + iv(b0["y"]) + h / 2),
              178, 191, 207, "L2 hovered button fill");
    assertRgb(pixelAt(475 + iv(b2["x"]) + 4, 330 + iv(b2["y"]) + h / 2),
              162, 175, 191, "L2 normal button fill");
    assertRgb(pixelAt(480, 330), 162, 175, 191, "L2 aimed hub fill");
    immutable tickD = (21 * h + 32) / 64;
    auto tick = pixelAt(475, 330 - tickD);
    assert(iv(tick["r"]) < 32 && iv(tick["g"]) < 32 && iv(tick["b"]) < 32,
           "L2 hovered north tick points in the selected direction: "
           ~ tick.toString);
    assertRgb(pixelAt(475 + tickD, 330), 162, 175, 191,
              "L2 hovered north tick must not point east");
    assertRgb(pixelAt(488, 330), 0, 0, 0, "L2 black outer hub");
    auto ne = boxAt(pie, 1);
    immutable px = 475 + iv(ne["x"]) + iv(ne["w"]) - 2;
    immutable py = 330 + iv(ne["y"]) + iv(ne["h"]) - 2;
    assert(px >= 475 + iv(ne["x"]) && px < 475 + iv(ne["x"]) + iv(ne["w"]));
    play([motion(px, py)]);
    assert(iv(getJson("/api/pie")["hover"]) == 2, "L2b hover followed a box, not angle");
    play([motion(475, 30)]);
    assert(iv(getJson("/api/pie")["hover"]) == 0, "L2c north hover gained outer bound");
    play([motion(775, 333)]);
    assert(iv(getJson("/api/pie")["hover"]) == 2, "L2c east hover gained outer bound");
    closePie();
}

unittest { // L3: the fixed NW hole is idle and fires nothing
    cmd("viewport.view Perspective");
    immutable before = getJson("/api/history")["undo"].array.length;
    openAt(475, 330);
    play([motion(419, 274)]);
    auto pie = getJson("/api/pie");
    assert(iv(pie["hover"]) == -1 && pie["hub"]["state"].str == "idle");
    play([
        `{"t":1,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":419,"y":274,"clicks":1,"mod":0}`,
        `{"t":2,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":419,"y":274,"clicks":1,"mod":0}`]);
    pie = getJson("/api/pie");
    assert(!pie["open"].boolean && getJson("/api/camera?viewport=0")["viewPreset"].str == "Perspective");
    assert(getJson("/api/history")["undo"].array.length == before);
}

unittest { // L26: short menus retain their fixed indices
    play([motion(475, 330)]);
    cmd("ui.pie layers");
    Thread.sleep(dur!"msecs"(30));
    play([motion(555, 330)]);
    auto pie = getJson("/api/pie");
    assert(iv(pie["hover"]) == 2 && boxAt(pie, 2)["label"].str == "Delete");
    closePie();
}
