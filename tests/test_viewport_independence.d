// test_viewport_independence.d — Phase-5 per-cell independence follow + commands.
//
// Flow A: Quad linked defaults — the ortho cells' center+scale follow their
//         group's store, cell 1 (gap 219, task 7139: the perspective cell is
//         its own link group).
// Flow B: Explicit viewport.master + viewport.indCenter commands.
// Regression: default GET/POST /api/camera (no query) unchanged.
module test_viewport_independence;


import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.math      : isClose;
import std.conv      : to;
import std.format    : format;
import core.thread   : Thread;
import core.time     : msecs;

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

string baseUrl;

string httpGet(string path) {
    import std.net.curl : get;
    return cast(string)get(baseUrl ~ path);
}

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

void postCommand(string cmd, string params = "") {
    JSONValue j;
    j["id"] = cmd;
    if (params.length) j["params"] = params;
    string resp = httpPost("/api/command", j.toString);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " failed: " ~ resp);
}

void resetApp() {
    httpPost("/api/command", commandBody("scene.reset", "{}"));
}

double getField(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    switch (cur.type) {
        case JSONType.float_:   return cur.floating;
        case JSONType.integer:  return cast(double)cur.integer;
        case JSONType.uinteger: return cast(double)cur.uinteger;
        default: throw new Exception("not a number at " ~ path[$-1]);
    }
}

// --------------------------------------------------------------------------
// Drag-injection helpers (task 0217 — coupled pan/zoom via a real gesture,
// not a direct POST /api/camera, since the bug/fix lives in the input-router
// write-target, not the resolved-read path).
// --------------------------------------------------------------------------

// SDL_Keymod bit values (bindbc-sdl keycode.d) — Pan = Alt+Shift, Zoom = Ctrl+Alt,
// Orbit = Alt alone (task 0224: Orbit in an ortho cell resolves to a pan).
enum uint MOD_PAN   = 0x0100 | 0x0001;  // KMOD_LALT | KMOD_LSHIFT
enum uint MOD_ZOOM  = 0x0040 | 0x0100;  // KMOD_LCTRL | KMOD_LALT
enum uint MOD_ORBIT = 0x0100;           // KMOD_LALT

// One button-down/motion/button-up gesture at (x0,y0) -> (x1,y1) with the
// given modifier held throughout. No VIEWPORT meta line — the coordinates
// are already computed against the CURRENT cell rects (via /api/camera?
// viewport=N), so remapPixel/remapDelta must stay inert (no recorded
// viewport => no-op), not distort them a second time.
string dragLog(int x0, int y0, int x1, int y1, uint mod) {
    string log = format(
        `{"t":0.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}` ~ "\n",
        x0, y0, mod);
    log ~= format(
        `{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":%d}` ~ "\n",
        x1, y1, x1 - x0, y1 - y0, mod);
    log ~= format(
        `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}` ~ "\n",
        x1, y1, mod);
    return log;
}

void playEvents(string log) {
    auto r = parseJSON(httpPost("/api/play-events", log));
    enforce(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (_; 0 .. 200) {
        auto j = parseJSON(httpGet("/api/play-events/status"));
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    enforce(false, "playback didn't finish within 10s");
}

// Cell rect + resolved focus/distance in one shot.
struct CamState { double vpX, vpY, w, h, fx, fy, fz, distance, azimuth, elevation; }

CamState getCam(int id) {
    auto j = parseJSON(httpGet("/api/camera?viewport=" ~ to!string(id)));
    CamState c;
    c.vpX = getField(j, "vpX");   c.vpY = getField(j, "vpY");
    c.w   = getField(j, "width"); c.h   = getField(j, "height");
    c.fx  = getField(j, "focus", "x");
    c.fy  = getField(j, "focus", "y");
    c.fz  = getField(j, "focus", "z");
    c.distance  = getField(j, "distance");
    c.azimuth   = getField(j, "azimuth");
    c.elevation = getField(j, "elevation");
    return c;
}

// --------------------------------------------------------------------------
// Flow C — coupled PAN, by LINK GROUP (task 7139, gap 219; C4-quad): the three
// ortho cells of the shipped Quad are ONE group, the perspective cell is its
// own. A drag in cell 0 (Top) (a) uses ITS OWN ortho basis for the screen
// delta (focus.y stays put) and (b) moves cells 0, 1 and 2 together while the
// perspective cell 3 stays where it was.
// --------------------------------------------------------------------------

bool testFlowC() {
    writeln("  [C] Coupled pan: a Quad ortho cell drags its ortho group only...");
    resetApp();
    postCommand("viewport.layout", "Quad");

    auto cam0 = getCam(0);
    CamState[4] before;
    foreach (id; 0 .. 4) before[id] = getCam(id);

    int cx = cast(int)(cam0.vpX + cam0.w * 0.5);
    int cy = cast(int)(cam0.vpY + cam0.h * 0.5);
    // dx=+50 (rightward), dy=-30 (upward) — nonzero on both drag axes so a
    // basis mismatch (another cell's basis vs. cell 0's own Top basis) would
    // show up as an unexpected focus.y move.
    playEvents(dragLog(cx, cy, cx + 50, cy - 30, MOD_PAN));

    double speed = cam0.distance * 0.001;
    double expDx = -50.0 * speed;         // right=(1,0,0): focus.x += -dx*speed
    double expDz =  30.0 * speed;         // up=(0,0,-1):  focus.z += dy*speed*(-1), dy=-30

    foreach (id; [0, 1, 2]) {
        auto c = getCam(id);
        enforce(isClose(c.fx - before[id].fx, expDx, 1e-2, 1e-4)
             && isClose(c.fz - before[id].fz, expDz, 1e-2, 1e-4)
             && isClose(c.fy, before[id].fy, 1e-4, 1e-4),
            format("Flow C: ortho cell %d focus moved by (%.6f, %.6f, %.6f), expected " ~
                   "(%.6f, 0, %.6f) from cell 0's own Top-basis drag", id,
                   c.fx - before[id].fx, c.fy - before[id].fy, c.fz - before[id].fz,
                   expDx, expDz));
    }
    writeln("    C1 PASS: cells 0/1/2 moved together by cell 0's Top-basis delta");

    auto after3 = getCam(3);
    enforce(isClose(after3.fx, before[3].fx, 1e-4, 1e-4)
         && isClose(after3.fy, before[3].fy, 1e-4, 1e-4)
         && isClose(after3.fz, before[3].fz, 1e-4, 1e-4),
        format("Flow C: ortho pan moved the perspective cell (reference link groups: " ~
               "ortho cells linked among themselves, gap 219): cell 3 (%.4f, %.4f, %.4f) " ~
               "-> (%.4f, %.4f, %.4f)", before[3].fx, before[3].fy, before[3].fz,
               after3.fx, after3.fy, after3.fz));
    writeln("    C2 PASS: the perspective cell 3 did not move");

    return true;
}

// --------------------------------------------------------------------------
// Flow D — coupled ZOOM: a wheel/drag-zoom in a default-follower cell must
// write the group master's distance (the field `resolveFollow` reads for
// indScale=false), not its own dead-end distance.
// --------------------------------------------------------------------------

bool testFlowD() {
    writeln("  [D] Coupled zoom: Quad ortho follower zooms the group...");
    resetApp();
    postCommand("viewport.layout", "Quad");

    auto before3 = getCam(3);
    auto cam1 = getCam(1);   // Front ortho cell — a different cell than C

    int cx = cast(int)(cam1.vpX + cam1.w * 0.5);
    int cy = cast(int)(cam1.vpY + cam1.h * 0.5);
    playEvents(dragLog(cx, cy, cx + 40, cy, MOD_ZOOM));   // dx=+40

    auto after1 = getCam(1);
    double expected = cam1.distance * (1.0 - 0.01 * 40.0);   // View.zoom(dx)
    enforce(isClose(after1.distance, expected, 1e-2),
        format("Flow D: ortho group distance = %.6f, expected %.6f (zoom not coupled)",
               after1.distance, expected));
    writefln("    D1 PASS: ortho group distance %.4f -> %.4f from cell 1's zoom drag",
        cam1.distance, after1.distance);

    foreach (id; [0, 1, 2]) {
        auto c = getCam(id);
        enforce(isClose(c.distance, after1.distance, 1e-3),
            format("Flow D: ortho cell %d must track the new group distance " ~
                   "(group=%.4f, cell %d=%.4f)", id, after1.distance, id, c.distance));
    }
    enforce(isClose(getCam(3).distance, before3.distance, 1e-4),
        "Flow D: an ortho zoom changed the perspective cell's distance (gap 219)");
    writeln("    D2 PASS: cells 0/1/2 resolve to the new group distance, cell 3 untouched");

    return true;
}

// --------------------------------------------------------------------------
// Flow E — `viewport.indScale yes` OVERRIDE: a zoom-drag in the ortho group's
// store (cell 1) must still couple to every default ortho cell EXCEPT the one
// opted out via indScale (keeps its own distance); pan stays coupled
// regardless (gap 219, task 7139: the perspective cell is not in this group).
// --------------------------------------------------------------------------

bool testFlowE() {
    writeln("  [E] indScale=yes keeps own distance under a group zoom (pan still coupled)...");
    resetApp();
    postCommand("viewport.layout", "Quad");

    // Cell 0 is active by default right after Quad — flip it to own-scale.
    postCommand("viewport.indScale", "yes");

    auto dist0Baseline = getCam(0).distance;
    auto cam1 = getCam(1);   // the ortho group's store

    int cx = cast(int)(cam1.vpX + cam1.w * 0.5);
    int cy = cast(int)(cam1.vpY + cam1.h * 0.5);
    playEvents(dragLog(cx, cy, cx + 40, cy, MOD_ZOOM));   // zoom-drag IN the store

    auto after0 = getCam(0);
    auto after1 = getCam(2);   // default ortho cell — must track
    auto after3 = getCam(1);

    enforce(isClose(after0.distance, dist0Baseline, 1e-3),
        format("Flow E: cell 0 (indScale=yes) distance must stay own (expected %.4f, got %.4f)",
               dist0Baseline, after0.distance));
    enforce(!isClose(after3.distance, dist0Baseline, 1e-3),
        "Flow E: master distance must actually have changed (test setup sanity)");
    enforce(isClose(after1.distance, after3.distance, 1e-3),
        format("Flow E: default ortho cell 2 must track the group's new distance " ~
               "(group=%.4f, cell2=%.4f)", after3.distance, after1.distance));
    writefln("    E1 PASS: cell 0 kept its own distance (%.4f) while cell 2 tracked the group (%.4f)",
        after0.distance, after1.distance);

    // Pan must still couple even with indScale=yes on cell 0 (indCenter still
    // false by default — only Scale was opted out).
    auto before3Focus = getCam(1);
    playEvents(dragLog(cx, cy, cx + 30, cy, MOD_PAN));
    auto after3Focus = getCam(1);
    enforce(!isClose(after3Focus.fx, before3Focus.fx, 1e-4),
        "Flow E: pan must still couple to the master even with indScale=yes on cell 0");
    auto after0Focus = getCam(0);
    enforce(isClose(after0Focus.fx, after3Focus.fx, 1e-3),
        "Flow E: cell 0 must still resolve the coupled focus (indCenter untouched)");
    writeln("    E2 PASS: pan stayed coupled after the indScale override");

    return true;
}

// --------------------------------------------------------------------------
// Flow F — task 0224: Alt+LMB (no Shift) in an ORTHO cell resolves to the
// same coupled PAN as Alt+Shift+LMB — orbit is meaningless in an axis-locked
// ortho view. Mirrors Flow C's math/assertions but drags with MOD_ORBIT.
// --------------------------------------------------------------------------

bool testFlowF() {
    writeln("  [F] Alt+LMB in an ortho follower cell pans (task 0224)...");
    resetApp();
    postCommand("viewport.layout", "Quad");

    auto cam0 = getCam(0);        // Top ortho cell
    auto before3 = getCam(1);     // the ortho group's store (gap 219)
    auto persp = getCam(3);

    int cx = cast(int)(cam0.vpX + cam0.w * 0.5);
    int cy = cast(int)(cam0.vpY + cam0.h * 0.5);
    playEvents(dragLog(cx, cy, cx + 50, cy - 30, MOD_ORBIT));

    auto after3 = getCam(1);
    enforce(isClose(getCam(3).fx, persp.fx, 1e-4, 1e-4) && isClose(getCam(3).fz, persp.fz, 1e-4, 1e-4),
        "Flow F: an ortho Alt+LMB pan moved the perspective cell (gap 219)");
    double speed = cam0.distance * 0.001;
    double expDx = -50.0 * speed;
    double expDz =  30.0 * speed;

    enforce(isClose(after3.fx - before3.fx, expDx, 1e-2, 1e-4),
        format("Flow F: master focus.x delta = %.6f, expected %.6f (ortho Alt+LMB not coupled-panning)",
               after3.fx - before3.fx, expDx));
    enforce(isClose(after3.fz - before3.fz, expDz, 1e-2, 1e-4),
        format("Flow F: master focus.z delta = %.6f, expected %.6f",
               after3.fz - before3.fz, expDz));
    enforce(isClose(after3.azimuth, before3.azimuth, 1e-4, 1e-4) &&
            isClose(after3.elevation, before3.elevation, 1e-4, 1e-4),
        "Flow F: master azimuth/elevation must NOT change — this must be a pan, not an orbit");
    writefln("    F1 PASS: master (cell 3) focus moved by (%.4f, ~0, %.4f) from cell 0's Alt+LMB drag, azimuth/elevation untouched",
        after3.fx - before3.fx, after3.fz - before3.fz);

    foreach (id; [0, 1, 2]) {
        auto c = getCam(id);
        enforce(isClose(c.fx, after3.fx, 1e-3) && isClose(c.fz, after3.fz, 1e-3),
            format("Flow F: follower cell %d must track the new group center " ~
                   "(master=(%.4f,%.4f), cell %d=(%.4f,%.4f))",
                   id, after3.fx, after3.fz, id, c.fx, c.fz));
    }
    writeln("    F2 PASS: cells 0/1/2 all resolve to the new group center");

    return true;
}

// --------------------------------------------------------------------------
// Flow G — regression: Alt+LMB in the PERSPECTIVE master cell still orbits
// (azimuth/elevation change, focus untouched) — task 0224 only remaps the
// gesture inside an ortho cell.
// --------------------------------------------------------------------------

bool testFlowG() {
    writeln("  [G] Alt+LMB in the perspective master cell still orbits...");
    resetApp();
    postCommand("viewport.layout", "Quad");

    auto before3 = getCam(3);   // perspective master

    int cx = cast(int)(before3.vpX + before3.w * 0.5);
    int cy = cast(int)(before3.vpY + before3.h * 0.5);
    playEvents(dragLog(cx, cy, cx + 50, cy - 10, MOD_ORBIT));

    auto after3 = getCam(3);
    double expAz = before3.azimuth   - 50.0 * 0.005;
    double expEl = before3.elevation + (-10.0) * 0.005;

    enforce(isClose(after3.azimuth, expAz, 1e-3, 1e-4),
        format("Flow G: master azimuth = %.6f, expected %.6f (perspective Alt+LMB must still orbit)",
               after3.azimuth, expAz));
    enforce(isClose(after3.elevation, expEl, 1e-3, 1e-4),
        format("Flow G: master elevation = %.6f, expected %.6f",
               after3.elevation, expEl));
    enforce(isClose(after3.fx, before3.fx, 1e-4, 1e-4) &&
            isClose(after3.fz, before3.fz, 1e-4, 1e-4),
        "Flow G: master focus must NOT change — this must be an orbit, not a pan");
    writefln("    G1 PASS: master orbited (az %.4f -> %.4f, el %.4f -> %.4f), focus untouched",
        before3.azimuth, after3.azimuth, before3.elevation, after3.elevation);

    return true;
}

// --------------------------------------------------------------------------
// Flow A — Quad linked defaults
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] Quad linked defaults...");
    resetApp();

    // Switch to Quad layout: cells 0-2 get indCenter=false, indScale=false;
    // their link group's store is cell 1 (masterId=1); the perspective cell 3
    // is its own group (gap 219, task 7139).
    postCommand("viewport.layout", "Quad");

    // Record cell 0's own distance before touching the master.
    auto cam0before = parseJSON(httpGet("/api/camera?viewport=0"));
    double ownDist = getField(cam0before, "distance");

    // POST-pan the group's store (cell 1) to focus.x = 5.
    string resp3 = httpPost("/api/camera?viewport=1", `{"focus":{"x":5,"y":0,"z":0}}`);
    auto r3 = parseJSON(resp3);
    enforce(r3["status"].str == "ok", "POST camera?viewport=1 failed: " ~ resp3);

    // GET follower (cell 0) resolved camera — focus.x must track master.
    auto cam0 = parseJSON(httpGet("/api/camera?viewport=0"));
    double fx = getField(cam0, "focus", "x");
    enforce(isClose(fx, 5.0, 1e-3), "Flow A: follower focus.x must track master (got " ~ to!string(fx) ~ ")");
    writeln("    A1 PASS: follower focus.x tracks master (", fx, ")");

    // Flip cell 0 indScale to yes (own) via viewport.indScale command.
    // Cell 0 is the active cell after Quad (activeId defaults to 0).
    postCommand("viewport.indScale", "yes");

    // POST-zoom the group's distance.
    string respb = httpPost("/api/camera?viewport=1", `{"distance":10}`);
    enforce(parseJSON(respb)["status"].str == "ok", "POST camera distance failed");

    // GET cell 0 resolved — distance must be OWN (not 10); focus.x still follows.
    auto cam0b = parseJSON(httpGet("/api/camera?viewport=0"));
    double dist0 = getField(cam0b, "distance");
    enforce(isClose(dist0, ownDist, 1e-3),
        "Flow A: indScale=yes must keep own distance (expected " ~
        to!string(ownDist) ~ ", got " ~ to!string(dist0) ~ ")");
    double fx2 = getField(cam0b, "focus", "x");
    enforce(isClose(fx2, 5.0, 1e-3), "Flow A: focus.x must still track master after indScale flip");
    writeln("    A2 PASS: own distance preserved (", dist0, "), center still follows (", fx2, ")");

    return true;
}

// --------------------------------------------------------------------------
// Flow B — explicit viewport.master + viewport.indCenter
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] Explicit viewport.master + indCenter...");
    resetApp();

    // SplitH: 2 cells, fully-independent, group master=0; active=0.
    postCommand("viewport.layout", "SplitH");

    // Give cell 1 a distinct focus.
    string respSet1 = httpPost("/api/camera?viewport=1", `{"focus":{"x":7,"y":0,"z":0}}`);
    enforce(parseJSON(respSet1)["status"].str == "ok", "POST camera cell 1 failed");

    // Record cell 0's own distance.
    auto cam0base = parseJSON(httpGet("/api/camera?viewport=0"));
    double ownDist = getField(cam0base, "distance");

    // Cell 0 is active: set masterId=1 (follow cell 1's center).
    postCommand("viewport.master", "1");
    postCommand("viewport.indCenter", "no");

    // GET resolved cell 0 — focus.x must be 7.
    auto cam0res = parseJSON(httpGet("/api/camera?viewport=0"));
    double fx = getField(cam0res, "focus", "x");
    enforce(isClose(fx, 7.0, 1e-3),
        "Flow B: cell 0 focus.x must follow cell 1 (got " ~ to!string(fx) ~ ")");
    writeln("    B1 PASS: indCenter=no follows master focus.x (", fx, ")");

    // Scale still own (indScale=true by default after SplitH).
    double dist0 = getField(cam0res, "distance");
    enforce(isClose(dist0, ownDist, 1e-3),
        "Flow B: distance must remain own (expected " ~
        to!string(ownDist) ~ ", got " ~ to!string(dist0) ~ ")");
    writeln("    B2 PASS: distance still own (", dist0, ")");

    return true;
}

// --------------------------------------------------------------------------
// Regression — default GET/POST /api/camera (no query) unchanged
// --------------------------------------------------------------------------

bool testRegression() {
    writeln("  [R] Default GET/POST /api/camera regression...");
    resetApp();

    // GET without ?viewport param (Single layout, cell 0, self-master).
    auto cam = parseJSON(httpGet("/api/camera"));
    enforce("azimuth" in cam, "Regression: GET /api/camera must return azimuth");
    enforce("focus"   in cam, "Regression: GET /api/camera must return focus");
    enforce("eye"     in cam, "Regression: GET /api/camera must return eye");
    writeln("    R1 PASS: GET /api/camera fields present");

    // POST without ?viewport param — moves active camera.
    string resp = httpPost("/api/camera", `{"azimuth":1.23}`);
    enforce(parseJSON(resp)["status"].str == "ok", "Regression: POST /api/camera failed");
    auto cam2 = parseJSON(httpGet("/api/camera"));
    enforce(isClose(getField(cam2, "azimuth"), 1.23, 1e-3),
        "Regression: POST /api/camera must update active camera azimuth");
    writeln("    R2 PASS: POST /api/camera updates active camera");

    return true;
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------

int main(string[] args) {
    // Resolve the port assigned to this worker by run_test.d.
    baseUrl = testBaseUrl();

    writeln("=== test_viewport_independence ===");
    int passed = 0, failed = 0;

    void run(bool function() fn, string name) {
        // Task 1111: report the ATTEMPT to the liveness gate before the case
        // can throw. A binary that reaches its exit having executed neither a
        // unittest of its own nor one counted scenario dies with code 3
        // instead of printing a pass over nothing — see tests/liveness_gate.d.
        import liveness_gate : scenario;
        scenario(name);
        try {
            if (fn()) { writeln("  PASS: ", name); passed++; }
            else       { writeln("  FAIL: ", name); failed++; }
        } catch (Exception e) {
            writefln("  FAIL: %s — %s", name, e.msg);
            failed++;
        }
    }

    run(&testFlowA,      "Flow A — Quad linked-center+scale follow");
    run(&testFlowB,      "Flow B — explicit master + indCenter");
    run(&testFlowC,      "Flow C — coupled pan (ortho follower drags group center)");
    run(&testFlowD,      "Flow D — coupled zoom (ortho follower zooms group)");
    run(&testFlowE,      "Flow E — indScale=yes keeps own distance under group zoom");
    run(&testFlowF,      "Flow F — Alt+LMB in an ortho cell pans (task 0224)");
    run(&testFlowG,      "Flow G — Alt+LMB in the perspective master still orbits");
    run(&testRegression, "Regression — default GET/POST /api/camera");

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
