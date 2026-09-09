// Task 0782 wave 3E — the scene renderer consumes THIS cell's camera and
// display inputs. The oracle is the actual FBO hash, never the DrawPlan dump.
module test_scene_view_inputs;

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl : HTTP, get;
import std.json : JSONValue, JSONType, parseJSON;
import std.exception : enforce;
import std.format : format;
import std.math : abs;
import std.stdio : writeln, writefln;
import core.thread : Thread;
import core.time : msecs;

string baseUrl;

string httpGet(string path) { return cast(string)get(baseUrl ~ path); }

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) {
        result ~= cast(string)data;
        return data.length;
    };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

void command(string id, string params = "") {
    JSONValue j;
    j["id"] = id;
    if (params.length) j["params"] = params;
    auto r = parseJSON(httpPost("/api/command", j.toString));
    enforce("status" !in r || r["status"].str != "error",
            id ~ " failed: " ~ r.toString);
}

void commandRaw(string id, string params) {
    auto r = parseJSON(httpPost("/api/command",
        `{"id":"` ~ id ~ `","params":` ~ params ~ `}`));
    enforce("status" !in r || r["status"].str != "error",
            id ~ " failed: " ~ r.toString);
}

void script(string line) {
    auto r = parseJSON(httpPost("/api/script", line));
    enforce("status" !in r || r["status"].str != "error",
            line ~ " failed: " ~ r.toString);
}

void settle() { Thread.sleep(400.msecs); }

string cellHash(int cell) {
    auto j = parseJSON(httpGet(format(
        "/api/viewport/probe?cell=%d&hash=1", cell)));
    enforce(j["renders"].type == JSONType.true_,
            format("cell %d was not rendered; its pixels are no oracle", cell));
    enforce("hash" in j && j["hash"].str.length == 16,
            "missing FBO hash: " ~ j.toString);
    return j["hash"].str;
}

double number(JSONValue j, string field) {
    auto v = j[field];
    if (v.type == JSONType.float_) return v.floating;
    if (v.type == JSONType.integer) return cast(double)v.integer;
    return cast(double)v.uinteger;
}

void restoreSharedApp() {
    try script("tool.set move off"); catch (Exception) {}
    try script("tool.pipe.attr falloff type none"); catch (Exception) {}
    try script("tool.pipe.attr actionCenter mode auto"); catch (Exception) {}
    try command("viewport.layout", "Single"); catch (Exception) {}
    try command("viewport.displayStyle", "shaded"); catch (Exception) {}
    settle();
}

bool runSceneViewCell() {
    auto reset = parseJSON(httpPost("/api/command",
        commandBody("scene.reset", "{}")));
    enforce(reset["status"].str == "ok", "scene.reset failed");
    scope(exit) restoreSharedApp();

    command("viewport.layout", "Quad");
    commandRaw("viewport.displayStyle",
        `{"_positional":["wireframe"],"viewport":0}`);
    commandRaw("viewport.displayStyle",
        `{"_positional":["shaded"],"viewport":3}`);
    httpPost("/api/camera?viewport=0",
        `{"azimuth":0.15,"elevation":0.25,"distance":6.0}`);
    httpPost("/api/camera?viewport=3",
        `{"azimuth":0.95,"elevation":0.55,"distance":6.0}`);
    settle();

    auto dump = parseJSON(httpGet("/api/viewport/display"));
    enforce(dump["cellCount"].integer == 4,
            "Quad did not expose four rendered cells");
    auto cells = dump["cells"].array;
    enforce(cells[0]["state"]["active"]["style"].str == "Wireframe"
         && cells[3]["state"]["active"]["style"].str == "Shaded",
            "fixture requires two cells with different display styles");
    auto cam0 = parseJSON(httpGet("/api/camera?viewport=0"));
    auto cam3 = parseJSON(httpGet("/api/camera?viewport=3"));
    enforce(abs(number(cam0, "azimuth") - number(cam3, "azimuth")) > 0.4,
            "fixture requires two cells with different cameras");

    immutable string c0Before = cellHash(0);
    immutable string c3Before = cellHash(3);

    // Change only cell 3's camera. A renderer fed cell 0's snapshot for this
    // second cell leaves c3 byte-identical and reddens the first assertion.
    httpPost("/api/camera?viewport=3",
        `{"azimuth":1.50,"elevation":0.35,"distance":6.0}`);
    settle();
    immutable string c0AfterCamera = cellHash(0);
    immutable string c3AfterCamera = cellHash(3);
    enforce(c3AfterCamera != c3Before,
        format("CELL-3 CAMERA PIXELS: cell 3 stayed %s after its own camera "
             ~ "changed; a foreign cell camera reached the scene renderer",
               c3Before));
    enforce(c0AfterCamera == c0Before,
        "changing cell 3's camera changed cell 0's FBO too");

    // Then change only its display style. This proves the explicit display
    // inputs reach pixels independently of the camera input above.
    commandRaw("viewport.displayStyle",
        `{"_positional":["wireframe"],"viewport":3}`);
    settle();
    immutable string c0AfterStyle = cellHash(0);
    immutable string c3AfterStyle = cellHash(3);
    enforce(c3AfterStyle != c3AfterCamera,
        "CELL-3 STYLE PIXELS: shaded->wireframe did not change cell 3's FBO");
    enforce(c0AfterStyle == c0Before,
        "changing cell 3's display style changed cell 0's FBO too");

    writefln("[scene-view-inputs] cell0=%s; cell3 camera %s->%s; style ->%s",
             c0Before, c3Before, c3AfterCamera, c3AfterStyle);
    return true;
}

int main(string[] args) {
    import liveness_gate : scenario;
    baseUrl = testBaseUrl();
    writeln("=== test_scene_view_inputs ===");
    scenario("two cells consume their own camera and style in real FBO draws");
    return runSceneViewCell() ? 0 : 1;
}
