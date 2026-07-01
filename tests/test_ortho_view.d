module test_ortho_view;

// Acceptance test: click on an off-center vertex in ortho Top view and
// confirm the correct vertex is selected (parallel ray, not perspective ray).
//
// The target pixel is computed test-side from /api/camera data and the
// orthographic transform.  If the ortho path is broken the wrong vertex
// (or none) would be selected.

import std.net.curl;
import std.json;
import std.math  : tan, abs, PI;
import std.stdio : writeln, writefln;
import std.conv  : to;
import std.format : format;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}

void runCmd(string line) {
    auto j = postJson("/api/command", line);
    assert(j["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ j.toString);
}

void waitPlayback() {
    import core.thread : Thread;
    import core.time   : dur;
    foreach (i; 0 .. 200) {
        auto s = getJson("/api/play-events/status");
        if (s["finished"].type == JSONType.TRUE) {
            Thread.sleep(dur!"msecs"(120));
            return;
        }
        Thread.sleep(dur!"msecs"(20));
    }
    assert(false, "play-events did not finish within 4 s");
}

unittest { // ortho Top: click on off-center vertex selects the correct vertex
    postJson("/api/reset", "{}");
    runCmd("prim.cube");

    // Switch to ortho Top via the viewport.view argstring command.
    runCmd("viewport.view Top");

    // Read camera state.
    auto cam = getJson("/api/camera");
    float dist   = cast(float)cam["distance"].floating;
    int   vpW    = cast(int)cam["width"].integer;
    int   vpH    = cast(int)cam["height"].integer;
    int   vpX    = cast(int)cam["vpX"].integer;
    int   vpY    = cast(int)cam["vpY"].integer;
    float focusX = cast(float)cam["focus"]["x"].floating;
    float focusZ = cast(float)cam["focus"]["z"].floating;

    // halfH = distance * tan(22.5°) — same formula used in view.d viewport().
    float halfH  = dist * tan(cast(float)(PI / 8.0));
    float aspect = cast(float)vpW / vpH;

    // Target: cube vertex at world (0.5, +0.5, -0.5).
    // In ortho Top (right=+X, up_screen=-Z):
    //   NDC_X = (worldX - focusX) / (halfH * aspect)
    //   NDC_Y = -(worldZ - focusZ) / halfH      (–Z maps to +screen-Y)
    float ndcX = (focusX + 0.5f) / (halfH * aspect);
    float ndcY = -(focusZ - 0.5f) / halfH;  // focusZ=0 + worldZ=-0.5 → -(-0.5)/halfH
    int   px   = cast(int)((ndcX * 0.5f + 0.5f) * vpW + vpX);
    int   py   = cast(int)((1.0f - (ndcY * 0.5f + 0.5f)) * vpH + vpY);

    writefln("ortho Top pick: dist=%f halfH=%f ndcX=%f ndcY=%f → screen(%d,%d)",
             dist, halfH, ndcX, ndcY, px, py);

    // Switch to vertex edit mode.
    runCmd("select.typeFrom vertex");

    // Build a JSON-Lines event log (same format the event player expects):
    //   line 0: VIEWPORT header
    //   line 1: mouse button down
    //   line 2: mouse button up
    string events =
        format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
               vpX, vpY, vpW, vpH) ~ "\n" ~
        format(`{"t":10.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
               px, py) ~ "\n" ~
        format(`{"t":20.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
               px, py) ~ "\n";

    auto pr = postJson("/api/play-events", events);
    assert(pr["status"].str == "success",
        "play-events failed: " ~ pr.toString);
    waitPlayback();

    // At least one vertex should be selected (the targeted one).
    auto sel  = getJson("/api/selection");
    auto vsel = sel["selectedVertices"].array;
    assert(vsel.length >= 1,
        "Expected at least 1 vertex selected in ortho Top click, got "
        ~ to!string(vsel.length));

    // Discriminator: the selected vertex must be the OFF-CENTER corner
    // (0.5, +0.5, -0.5). A perspective ray/projection through the same
    // (ortho-computed) pixel would foreshorten and land on a different
    // vertex, so a length>=1 check alone would not prove the ortho path.
    auto model = getJson("/api/model");
    auto verts = model["vertices"].array;
    bool foundTarget = false;
    foreach (jv; vsel) {
        int vi = cast(int)jv.integer;
        assert(vi >= 0 && vi < cast(int)verts.length,
            "selected vertex index out of range: " ~ to!string(vi));
        auto p = verts[vi].array;
        float vx = cast(float)p[0].floating;
        float vy = cast(float)p[1].floating;
        float vz = cast(float)p[2].floating;
        if (abs(vx - 0.5f) < 1e-3f && abs(vy - 0.5f) < 1e-3f
                && abs(vz + 0.5f) < 1e-3f) {
            foundTarget = true;
            break;
        }
    }
    assert(foundTarget,
        "ortho Top click must select the off-center corner (0.5, 0.5, -0.5); "
        ~ "selected indices = " ~ to!string(vsel));

    writeln("test_ortho_view PASS: ortho Top click selected the off-center corner (0.5,0.5,-0.5)");

    // Restore perspective mode so any follow-on tests on this worker see
    // the normal camera (belt-and-suspenders; /api/reset also does this now).
    runCmd("viewport.view Perspective");
}
