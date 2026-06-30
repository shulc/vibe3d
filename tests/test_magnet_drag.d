// Interactive drag test for the `xfrm.magnet` tool.
//
// Tests that:
//   1. Activating xfrm.magnet and hovering over vertex 6 sets the pick target.
//   2. An LMB-drag moves the anchor vertex toward the cursor (convergent pull).
//   3. Vertices outside the falloff sphere (dist=1.0, default) are unmoved.
//   4. Releasing commits a MeshVertexEdit undo entry — Ctrl+Z restores geometry.
//
// Hover-pick mechanism: a MOUSEMOTION event (state=0) at v6's screen position
// is injected 180 ms before the MOUSEBUTTONDOWN.  Within that gap several
// render frames run and pickVertices() updates g_hoveredVertex = 6.
// MagnetTool.onMouseButtonDown then reads g_hoveredVertex and starts the drag.
//
// dist=1.0 (default): adjacent verts sit exactly at the sphere boundary
// (distance from v6 = 1.0 = pickedRadius) → weight=0 → only v6 moves.
// This cleanly separates "anchor moved" from "neighbour attenuation".
//
// "localhost:8080" is rewritten to the per-worker port by run_test.d.

import drag_helpers;

import std.net.curl;
import std.json;
import std.math   : abs, sqrt;
import std.format : format;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

enum string BASE = "http://localhost:8080";

JSONValue jpost(string path, string body_) {
    return parseJSON(cast(string)post(BASE ~ path, body_));
}
JSONValue jget(string path) {
    return parseJSON(cast(string)get(BASE ~ path));
}
void mustOk(JSONValue r, string ctx) {
    assert(r["status"].str == "ok",
           ctx ~ ": " ~ r.toString());
}

struct V3 { double x, y, z; }
V3 vert(int idx) {
    auto a = jget("/api/model")["vertices"].array[idx].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
double dist3(V3 a, V3 b) {
    double dx = a.x-b.x, dy = a.y-b.y, dz = a.z-b.z;
    return sqrt(dx*dx + dy*dy + dz*dz);
}

// Build an event log: hover at (hx,hy) at t=20ms, then DOWN+motion+UP
// starting at t=200ms.  The 180ms gap gives the render loop time to run
// pickVertices() and update g_hoveredVertex before the button goes down.
string buildHoverDragLog(
    int vpX, int vpY, int vpW, int vpH,
    int hx, int hy, int x1, int y1,
    int steps = 20, uint mod = 0)
{
    string log = format(
        "{\"t\":0.000,\"type\":\"VIEWPORT\",\"vpX\":%d,\"vpY\":%d,"
        ~ "\"vpW\":%d,\"vpH\":%d,\"fovY\":0.785398}\n",
        vpX, vpY, vpW, vpH);

    // Hover (no button — state=0).
    log ~= format(
        "{\"t\":20.000,\"type\":\"SDL_MOUSEMOTION\","
        ~ "\"x\":%d,\"y\":%d,\"xrel\":0,\"yrel\":0,\"state\":0,\"mod\":%u}\n",
        hx, hy, mod);

    // DOWN 180 ms later — multiple render frames have run by now.
    log ~= format(
        "{\"t\":200.000,\"type\":\"SDL_MOUSEBUTTONDOWN\","
        ~ "\"btn\":1,\"x\":%d,\"y\":%d,\"clicks\":1,\"mod\":%u}\n",
        hx, hy, mod);

    // Motion events.
    int lastX = hx, lastY = hy;
    foreach (i; 1 .. steps + 1) {
        int x = hx + (x1 - hx) * i / steps;
        int y = hy + (y1 - hy) * i / steps;
        double t = 200.0 + i * 50.0;
        log ~= format(
            "{\"t\":%.3f,\"type\":\"SDL_MOUSEMOTION\","
            ~ "\"x\":%d,\"y\":%d,\"xrel\":%d,\"yrel\":%d,\"state\":1,\"mod\":%u}\n",
            t, x, y, x - lastX, y - lastY, mod);
        lastX = x; lastY = y;
    }

    // UP.
    double tUp = 200.0 + (steps + 1) * 50.0;
    log ~= format(
        "{\"t\":%.3f,\"type\":\"SDL_MOUSEBUTTONUP\","
        ~ "\"btn\":1,\"x\":%d,\"y\":%d,\"clicks\":1,\"mod\":%u}\n",
        tUp, x1, y1, mod);
    return log;
}

// ---------------------------------------------------------------------------
// Test — hover v6, drag right, check v6 moved + v5 unmoved + undo restores.
// ---------------------------------------------------------------------------
unittest {
    // Reset to cube.
    auto rr = jpost("/api/reset", `{"primitive":"cube"}`);
    // (reset may return ok or may use the cube primitive path; any 2xx is fine,
    //  just proceed; if cube isn't there we'll fail on geometry assertions.)

    // Activate xfrm.magnet.
    mustOk(jpost("/api/command", "tool.set xfrm.magnet"), "tool.set xfrm.magnet");

    // Fetch the live camera so our screen projection matches vibe3d's.
    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);

    // Project v6 = (0.5, 0.5, 0.5) to screen.
    float sx, sy;
    bool visible = projectToWindow(Vec3(0.5f, 0.5f, 0.5f), vp, sx, sy);
    assert(visible, "v6 must be visible from default camera");

    int x0 = cast(int)sx;
    int y0 = cast(int)sy;

    // Drag 100px to the right.
    // STRENGTH_PX=150 → strength ≈ 0.667 → v6 moves ~2/3 of the way to target.
    int x1 = x0 + 100;
    int y1 = y0;

    auto log = buildHoverDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                 x0, y0, x1, y1, 20);
    playAndWait(log, BASE);

    // After the UP event MagnetTool.onMouseButtonUp committed the edit.
    auto m = jget("/api/model");
    auto verts = m["vertices"].array;

    V3 v6Orig = V3(0.5, 0.5, 0.5);
    V3 v6Now  = V3(verts[6].array[0].floating,
                   verts[6].array[1].floating,
                   verts[6].array[2].floating);
    double d6 = dist3(v6Now, v6Orig);

    assert(d6 > 0.05,
           format("v6 should have moved (got %.4f units) — "
                  ~ "hover pick may have missed v6 at screen (%d,%d)",
                  d6, x0, y0));

    // v5 = (0.5, -0.5, 0.5) is at d=1.0 from v6.
    // With dist=1.0 (default), t=d/dist=1.0 → weight=0 → v5 must NOT move.
    double v5y = verts[5].array[1].floating;
    double v5z = verts[5].array[2].floating;
    assert(abs(v5y - (-0.5)) < 1e-3,
           format("v5.y must be unchanged (%.5f), dist=1.0 excludes boundary verts", v5y));
    assert(abs(v5z - 0.5) < 1e-3,
           format("v5.z must be unchanged (%.5f)", v5z));

    // Undo — MeshVertexEdit.revert() restores v6 to (0.5, 0.5, 0.5).
    jpost("/api/undo", "");

    auto m2     = jget("/api/model");
    auto verts2 = m2["vertices"].array;
    V3 v6After  = V3(verts2[6].array[0].floating,
                     verts2[6].array[1].floating,
                     verts2[6].array[2].floating);
    double d6Restored = dist3(v6After, v6Orig);
    assert(d6Restored < 1e-4,
           format("v6 must be restored to (0.5,0.5,0.5) after undo (dist=%.6f)",
                  d6Restored));

    // Deactivate tool so scene is clean for any subsequent tests.
    jpost("/api/command", "tool.set select");
}
