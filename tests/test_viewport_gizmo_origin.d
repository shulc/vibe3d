// Gizmo-origin invariant — the HEADLINE acceptance test for viewport Phase 4.
//
// A transform (move) drag begun in cell K must keep using cell K's camera for
// its whole lifetime, EVEN when the cursor crosses a splitter into another
// cell.  The freeze is carried by `dragOriginId` (latched at MOUSEBUTTONDOWN,
// cleared at UP): it pins each tool's `cachedVp` (via the one-cell overlay-draw
// gate) and every `originCamera()` read.
//
// Headless mechanism:
//   * `viewport.layout Quad` works in --test; the input router uses the
//     analytic cell rects (cellRectsFor) because winX/Y/W/H are stamped by
//     applyLayout from the layout rect.
//   * Quad assigns cell0 = Top (ortho), cell1 = Front, cell2 = Left, cell3 =
//     Perspective — distinct camera bases by construction.
//   * A center-box (screen-plane) move drag begun in cell0 (Top) maps screen
//     motion into the world XZ plane (Top looks down +Y → right = world X,
//     up = world −Z), so world Y stays constant.
//   * We start the drag at the Top cell's centre (the ACEN.Auto pivot for the
//     whole cube = origin = the Top camera's focus → projects to the cell
//     centre) and move the cursor DIAGONALLY across the splitter into cell3
//     (BR / Perspective).
//   * If the origin freeze works, the geometry moves as the Top camera dictates
//     → world Y unchanged, world X and Z change.  If the freeze had leaked to
//     the cell the cursor ended in (Front/Left/Persp all have a non-zero Y
//     component in their screen plane), world Y WOULD change → the assert fails.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

import drag_helpers;

void main() {}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

// GET /api/camera?viewport=N as raw JSON.
JSONValue camAt(int n) {
    return parseJSON(cast(string)get(
        "http://localhost:8080/api/camera?viewport=" ~ n.to!string));
}

unittest {
    // ---- 1. Reset (Single layout) + capture the full 3D-area rect. ----
    auto resetResp = parseJSON(cast(string)post("http://localhost:8080/api/reset", "{}"));
    assert(resetResp["status"].str == "ok", "reset failed");

    // Full viewport rect BEFORE switching to Quad (GET default = active cell 0,
    // which in Single covers the whole 3D area).
    auto full = fetchCamera();
    int fullX = full.vpX, fullY = full.vpY;
    int fullW = full.width, fullH = full.height;
    assert(fullW > 8 && fullH > 8, "implausible viewport size");

    // ---- 2. Quad layout. ----
    auto lay = parseJSON(cast(string)post("http://localhost:8080/api/command",
                         `{"id":"viewport.layout","params":"Quad"}`));
    assert(lay["status"].str == "ok" || lay["status"].str == "success",
        "viewport.layout Quad failed: " ~ lay.toString);

    // Per-cell cameras are reachable via ?viewport=N.  NOTE: View.toJson only
    // serialises the spherical members (azimuth/elevation/eye/focus); the Quad
    // per-cell view *preset* (Top/Front/Left/Persp) drives the view MATRIX, not
    // those members, so the JSON looks alike across the ortho cells.  The real
    // per-cell-basis proof is the geometry assertion below, not this JSON.
    auto c0 = camAt(0), c3 = camAt(3);
    assert("elevation" in c0 && "elevation" in c3, "camera json missing fields");

    // Top cell must focus the origin so the pivot projects to the cell centre.
    assert(approx(c0["focus"]["x"].floating, 0.0) &&
           approx(c0["focus"]["y"].floating, 0.0) &&
           approx(c0["focus"]["z"].floating, 0.0),
           "cell0 (Top) focus must be world origin for the centre-grab to land");

    // ---- 3. Select the whole cube + activate the move tool. ----
    auto selResp = parseJSON(cast(string)post("http://localhost:8080/api/select",
                             `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`));
    assert(selResp["status"].str == "ok", "select failed: " ~ selResp.toString);
    auto setResp = parseJSON(cast(string)post("http://localhost:8080/api/script", "tool.set move"));
    assert(setResp["status"].str == "ok", "tool.set move failed: " ~ setResp.toString);

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    // ---- 4. Analytic Quad cell rects (mirrors ViewportManager.cellRectsFor). ----
    int hw = fullW / 2, hh = fullH / 2;
    // cell0 (TL / Top):  (fullX,        fullY,        hw,        hh)
    // cell3 (BR / Persp):(fullX+hw,     fullY+hh,     fullW-hw,  fullH-hh)
    int cell0cx = fullX + hw / 2;
    int cell0cy = fullY + hh / 2;
    int cell3cx = fullX + hw + (fullW - hw) / 2;
    int cell3cy = fullY + hh + (fullH - hh) / 2;

    // ---- 5. Drag: DOWN at the Top cell centre (grabs the centre box),
    //         MOTION diagonally across the splitter into the BR cell, UP. ----
    string log = buildDragLog(fullX, fullY, fullW, fullH,
                              cell0cx, cell0cy, cell3cx, cell3cy, 24);
    playAndWait(log);

    // ---- 6. Assert the move used the ORIGIN (Top) camera. ----
    double maxDY = 0, maxDX = 0, maxDZ = 0;
    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        maxDX = fabs(p[0] - pre[i][0]) > maxDX ? fabs(p[0] - pre[i][0]) : maxDX;
        maxDY = fabs(p[1] - pre[i][1]) > maxDY ? fabs(p[1] - pre[i][1]) : maxDY;
        maxDZ = fabs(p[2] - pre[i][2]) > maxDZ ? fabs(p[2] - pre[i][2]) : maxDZ;
    }

    // (a) Something actually moved — the centre-box grab landed & the drag ran.
    assert(maxDX > 0.02 || maxDZ > 0.02,
        "no in-plane movement — centre-box grab missed in the Top cell "
        ~ "(dx=" ~ maxDX.to!string ~ " dz=" ~ maxDZ.to!string ~ ")");

    // (b) THE INVARIANT: world Y is untouched.  The Top camera's screen plane is
    //     XZ; any other cell the cursor crossed into (Front/Left/Persp) would
    //     have injected a world-Y component.  Y ≈ 0 ⇒ the drag stayed frozen to
    //     the origin (Top) cell across the splitter.
    assert(maxDY < 1e-3,
        "world Y moved (" ~ maxDY.to!string ~ ") — the drag basis leaked to a "
        ~ "non-origin cell across the splitter (dragOriginId freeze broken)");

    // (c) Vertical screen motion mapped to world Z (Top up = world -Z), further
    //     pinning that the Top (not Front, whose plane is XY with no Z) camera
    //     drove the move.
    assert(maxDZ > 0.02,
        "world Z did not move (" ~ maxDZ.to!string ~ ") — expected the Top "
        ~ "camera's XZ screen plane to drive the diagonal drag");

    // ---- 7. Back to Single: byte-identity guard (cell 0 still reachable). ----
    auto back = parseJSON(cast(string)post("http://localhost:8080/api/command",
                          `{"id":"viewport.layout","params":"Single"}`));
    assert(back["status"].str == "ok" || back["status"].str == "success",
        "viewport.layout Single failed: " ~ back.toString);
    auto s0 = camAt(0);
    assert("azimuth" in s0, "GET /api/camera?viewport=0 broken after Single");
}
