// test_gizmo_handle_alpha.d — the gizmo's LINES must reach the framebuffer
// opaque, not just correctly coloured.
//
// WHY THIS FILE EXISTS, AND WHY test_gizmo_handle_colours.d COULD NOT COVER IT.
// That test pins the constant on the constructed handle: `arrowX.color` is the
// X-axis red, `ring.color` is the ring's own. It passed throughout the bug.
// What it cannot see is everything BETWEEN the constant and the pixel — and
// that is where this defect lived: the arm shafts and the rotate rings reached
// the cell's framebuffer with the RIGHT rgb and an alpha of ZERO, because the
// thick-line program never seeded the `u_alpha` uniform that was later added to
// the fragment shader it shares with the regular one. The cell's colour texture
// is composited with SRC_ALPHA blending, so a zero-coverage line is blended
// away and the panel behind it shows through — the lines read as grey while the
// arrowheads, drawn by the other program, kept their colour.
//
// So the assertion has to be made on the FRAMEBUFFER, and specifically on the
// ALPHA CHANNEL, which no other test in the suite reads. `/api/viewport/probe`
// already returns it (task 0559); nothing had ever asserted on it.
//
// WHAT MAKES THIS NOT A SCREENSHOT TEST. It never looks at an image and never
// compares one. It asks the renderer for the handle's own reported screen
// position, reads the four channel VALUES at that position, and asserts them
// against the scheme colour restated as a literal plus a categorical alpha of
// 255. A mismatch names the channel and the handle.
//
// Flow A — Move bank: an arm's SHAFT (thick-line program) is opaque, and so is
//          the centre BOX (regular program). The box is the control: it was
//          always opaque, so its passing next to a failing shaft is what says
//          "the probe is reading a live frame and only one program is wrong".
// Flow B — Rotate bank: EVERY ring pixel found is opaque. This is the bank the
//          user saw entirely grey, because it is drawn entirely from lines.
//
// VERIFIED TO FAIL BEFORE THE FIX: on the unfixed binary both flows fail with
// "alpha 0, expected 255" at the same pixels this passes at afterwards.

import std.stdio      : writeln, writefln;
import std.net.curl   : HTTP;
import std.json       : parseJSON, JSONValue, JSONType;
import std.exception  : enforce;
import std.conv       : to;
import std.format     : format;
import std.math       : abs, sqrt, round;
import core.thread    : Thread;
import core.time      : msecs;

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

// `tool.set` is an argstring command, not a JSON one — /api/script is the
// endpoint that takes it (same route the ACEN tests use to arm a tool).
void script(string line) {
    string resp = httpPost("/api/script", line);
    enforce(parseJSON(resp)["status"].str == "ok",
            "script `" ~ line ~ "` failed: " ~ resp);
}

// The probe reads the last COMPLETED frame (the HTTP bridge is serviced before
// the scene render), so anything that changes the scene needs a frame to land
// before it is visible to a probe.
void settle() { Thread.sleep(400.msecs); }

void resetApp() {
    httpPost("/api/reset", "{}");
    settle();
}

double jsonNum(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    switch (cur.type) {
        case JSONType.float_:   return cur.floating;
        case JSONType.integer:  return cast(double)cur.integer;
        case JSONType.uinteger: return cast(double)cur.uinteger;
        default: throw new Exception("not a number at ." ~ path[$ - 1]);
    }
}

struct Px { int x, y, r, g, b, a; bool valid; }

// One probe request over a list of FBO points (top-left origin). The cell is
// left to the endpoint's default, which is the ACTIVE cell — the only one
// --test renders, and the one the gizmo is drawn into.
Px[] probe(int[2][] pts) {
    string q = "/api/viewport/probe?points=";
    foreach (i, p; pts) {
        if (i) q ~= ";";
        q ~= format("%d,%d", p[0], p[1]);
    }
    auto j = parseJSON(httpGet(q));
    enforce("error" !in j, "probe failed: " ~ j.toString);
    // The --test single-rendered-cell trap: a probe at a never-filled FBO
    // reads zeros and every alpha assertion below would fail for the WRONG
    // reason. Assert the flag rather than trusting the default.
    enforce(j["renders"].type == JSONType.TRUE,
            "the probed cell is not rendered under --test; the reading is void");
    Px[] outp;
    foreach (e; j["points"].array) {
        Px p;
        p.x = cast(int)jsonNum(e, "x");
        p.y = cast(int)jsonNum(e, "y");
        if ("error" in e) { p.valid = false; outp ~= p; continue; }
        p.r = cast(int)jsonNum(e, "r");
        p.g = cast(int)jsonNum(e, "g");
        p.b = cast(int)jsonNum(e, "b");
        p.a = cast(int)jsonNum(e, "a");
        p.valid = true;
        outp ~= p;
    }
    return outp;
}

// The scheme, restated as 8-bit literals — the same independent-restatement
// convention test_gizmo_handle_colours.d uses. These are `round(255 * c)` of
// the Vec3 entries that test pins.
enum int[3] RGB_AXIS_X = [229,  51,  51];   // 0.9, 0.2, 0.2
enum int[3] RGB_AXIS_Y = [ 51, 204,  51];   // 0.2, 0.8, 0.2
enum int[3] RGB_AXIS_Z = [ 51, 102, 255];   // 0.2, 0.4, 1.0
enum int[3] RGB_HANDLE = [102, 255, 255];   // 0.4, 1.0, 1.0  (centre box)

// Software GL rounds the last bit differently across drivers; 3/255 is byte
// slop, not a shading tolerance. These are UNBLENDED writes (blending is off
// for the handle passes), so the value is the uniform, not a mix.
bool isColor(Px p, const int[3] want) {
    return p.valid && abs(p.r - want[0]) <= 3
                   && abs(p.g - want[1]) <= 3
                   && abs(p.b - want[2]) <= 3;
}

// The handle registry, with the cell rectangle it was measured in.
struct Handles {
    double[2][int] screen;      // part id -> window-space position
    int vx, vy, vw, vh;         // the cell's rectangle in window space
}

Handles handles() {
    auto j = parseJSON(httpGet("/api/tool/handles"));
    enforce(j["handles"].type != JSONType.null_,
            "/api/tool/handles reports no handles — no tool is armed");
    auto h = j["handles"];
    Handles outh;
    outh.vx = cast(int)jsonNum(h, "viewport", "x");
    outh.vy = cast(int)jsonNum(h, "viewport", "y");
    outh.vw = cast(int)jsonNum(h, "viewport", "width");
    outh.vh = cast(int)jsonNum(h, "viewport", "height");
    foreach (e; h["parts"].array) {
        int id = cast(int)jsonNum(e, "part");
        outh.screen[id] = [e["screen"].array[0].floating,
                           e["screen"].array[1].floating];
    }
    return outh;
}

// Window coordinates -> the probe's FBO coordinates. Both are top-left origin;
// the cell's own corner is the only difference.
int[2] toFbo(const ref Handles h, double sx, double sy) {
    return [cast(int)round(sx - h.vx), cast(int)round(sy - h.vy)];
}

// --------------------------------------------------------------------------
// Flow A — the Move bank: shaft and box must BOTH be opaque
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] Move bank — arm shaft and centre box alpha...");
    resetApp();
    script("tool.set move");
    settle();
    scope(exit) { script("tool.set move off"); settle(); }

    auto h = handles();
    enforce(3 in h.screen && 0 in h.screen,
            "the move bank must publish a centre (part 3) and an X arm (part 0)");
    immutable double cx = h.screen[3][0], cy = h.screen[3][1];
    immutable double tx = h.screen[0][0], ty = h.screen[0][1];

    // --- A1: the centre BOX. Drawn as triangles on the regular program, which
    // has always seeded its uniforms. It is the CONTROL: it must be opaque on
    // the broken build too, which is what proves a failing A2 is about one
    // program rather than about the probe, the frame, or the camera.
    {
        auto pts = [toFbo(h, cx, cy)];
        auto got = probe(pts)[0];
        enforce(isColor(got, RGB_HANDLE),
            format("centre box: expected rgb(%d,%d,%d), got rgb(%d,%d,%d) — "
                   ~ "the probe is not looking at the gizmo centre",
                   RGB_HANDLE[0], RGB_HANDLE[1], RGB_HANDLE[2],
                   got.r, got.g, got.b));
        enforce(got.a == 255,
            format("centre box alpha %d, expected 255", got.a));
        writeln("    A1 PASS: centre box rgb + alpha 255 (control)");
    }

    // --- A2: the arm SHAFT. Drawn through the thick-line program. Sample the
    // segment centre->tip well inside the shaft (past the 1/5 inset, short of
    // the cone) and sweep perpendicular, because the drawn line is only a few
    // pixels wide and its exact row depends on the camera.
    {
        immutable double dx = tx - cx, dy = ty - cy;
        immutable double len = sqrt(dx*dx + dy*dy);
        enforce(len > 20, "the X arm projects to under 20 px; nothing to sample");
        immutable double ux = dx / len,  uy = dy / len;
        immutable double px = -uy,       py = ux;      // screen-space perpendicular

        int[2][] pts;
        foreach (ti; 0 .. 3) {
            immutable double t = 0.40 + 0.10 * ti;
            foreach (d; -5 .. 6)
                pts ~= toFbo(h, cx + dx*t + px*d, cy + dy*t + py*d);
        }
        auto got = probe(pts);

        Px[] onShaft;
        foreach (p; got) if (isColor(p, RGB_AXIS_X)) onShaft ~= p;
        enforce(onShaft.length > 0,
            format("no pixel of the X arm's own colour rgb(%d,%d,%d) found along "
                   ~ "the centre->tip segment — the arm was not drawn, or the "
                   ~ "scheme colour changed without this test",
                   RGB_AXIS_X[0], RGB_AXIS_X[1], RGB_AXIS_X[2]));

        foreach (p; onShaft)
            enforce(p.a == 255,
                format("X arm shaft at (%d,%d): rgb is right but alpha is %d, "
                       ~ "expected 255. A zero-coverage line is composited away "
                       ~ "and reads as the panel behind it — check that every "
                       ~ "program built from the shared fragment source seeds "
                       ~ "u_alpha (shader.seedSharedFragUniforms)",
                       p.x, p.y, p.a));
        writefln("    A2 PASS: %d shaft pixels, all rgb %s and alpha 255",
                 onShaft.length, RGB_AXIS_X);
    }
    return true;
}

// --------------------------------------------------------------------------
// Flow B — the Rotate bank: every ring is a line, so ALL of it was grey
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] Rotate bank — ring alpha...");
    resetApp();
    script("tool.set rotate");
    settle();
    scope(exit) { script("tool.set rotate off"); settle(); }

    auto h = handles();
    enforce(h.screen.length > 0, "the rotate bank must publish at least one handle");
    // NO part id is named here, deliberately: the banks have disjoint id bases
    // (the move arms start at 0, the rotate rings at 10) and hard-coding one
    // would make this test a hostage to that numbering. Every rotate part
    // reports the RING CENTRE as its screen position, so the centroid of
    // whatever was published is the centre to scan out from.
    double cx = 0, cy = 0;
    foreach (_, s; h.screen) { cx += s[0]; cy += s[1]; }
    cx /= h.screen.length;
    cy /= h.screen.length;

    // Scan a ray outward and collect every pixel wearing one of the three
    // saturated axis colours. Only the saturated ones: the view ring's grey is
    // close enough to the shaded mesh and the grid that matching it would risk
    // asserting alpha on a pixel that is not a ring at all.
    int[2][] pts;
    foreach (d; 0 .. 140) pts ~= toFbo(h, cx + d, cy);

    Px[] onRing;
    // Chunked so the request line stays short regardless of cell size.
    for (size_t i = 0; i < pts.length; i += 70) {
        auto slice = pts[i .. (i + 70 > pts.length ? pts.length : i + 70)];
        foreach (p; probe(slice))
            if (isColor(p, RGB_AXIS_X) || isColor(p, RGB_AXIS_Y)
                                       || isColor(p, RGB_AXIS_Z))
                onRing ~= p;
    }

    enforce(onRing.length > 0,
        "no ring pixel in an axis colour found on a ray out of the rotate "
        ~ "gizmo centre — the rings were not drawn");
    foreach (p; onRing)
        enforce(p.a == 255,
            format("rotate ring at (%d,%d): rgb(%d,%d,%d) is right but alpha is "
                   ~ "%d, expected 255. The whole rotate bank is drawn from "
                   ~ "lines, so an unseeded u_alpha greys ALL of it",
                   p.x, p.y, p.r, p.g, p.b, p.a));
    writefln("    B1 PASS: %d ring pixels, all alpha 255", onRing.length);
    return true;
}

// --------------------------------------------------------------------------

int main(string[] args) {
    // NOTE: keep the literal "http://localhost:8080" — run_test.d isolates
    // parallel workers by textually rewriting "localhost:8080" to the worker's
    // port in a scratch copy of the source.
    baseUrl = "http://localhost:8080";

    writeln("=== test_gizmo_handle_alpha ===");
    int passed = 0, failed = 0;

    void run(bool function() fn, string name) {
        try {
            if (fn()) { writeln("  PASS: ", name); passed++; }
            else      { writeln("  FAIL: ", name); failed++; }
        } catch (Exception e) {
            writefln("  FAIL: %s — %s", name, e.msg);
            failed++;
        }
    }

    run(&testFlowA, "Flow A — move arm shaft reaches the framebuffer opaque");
    run(&testFlowB, "Flow B — rotate rings reach the framebuffer opaque");

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
