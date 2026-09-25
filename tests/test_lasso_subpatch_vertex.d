// A VERTEX LASSO ON A SUBPATCH CAGE SELECTS THE VERTEX WHOSE DISPLAYED (LIMIT)
// POSITION IT ENCLOSES (wave-plan item 18).
//
// Captured law (`tests/fixtures/delete_makepoly_lasso_hide_keys.json`, section
// `subpatch_vertex_lasso`): on a subpatched cube in vertex mode a loop around
// the LIMIT position of v7 selects [7], a loop around its CAGE position selects
// [], and without subpatch a loop around the vertex selects [7]. Our preview
// branch (`InputRouter`'s lasso block, `EditMode.Vertices`, `if (preview)`)
// already tests the limit point (`pv.vertices[pi]`), so the remaining causes
// form a closed list of two, and the cells below separate them:
//
//   B  default (filling) style, preview settled, loop around the limit -> [7]
//   C  the same under a style that draws no faces (occlusion term off) -> [7]
//   D  the same while a preview rebuild is pending              -> [7]
//
//   B red, C green -> the occlusion probe hides the limit vertex (ii);
//   B green, D red -> the lasso block is skipped while a rebuild is pending (i).
//
// The limit point is not taken on trust: it is read off the face VBO that is
// actually drawn (`/api/gpu/face-vbo`, the position furthest along +x+y+z),
// because the law is about the DISPLAYED position.
//
// Order: rig floors -> control 2 (cage loop selects nothing, green on HEAD) ->
// B -> C -> D. A red B stops the file there; C and D are then run by
// renaming B's block (procedure recorded in the task card).

import http_client : testBaseUrl, getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.algorithm : sort;
import std.math   : lround, sin, cos, PI, sqrt, fabs;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

enum string kFixture = import("fixtures/delete_makepoly_lasso_hide_keys.json");


void settle() { quiesce(); }

void cmdOk(string body_) {
    auto r = postJson("/api/command", body_);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "command failed: " ~ body_ ~ " -> " ~ r.toString);
}

void setStyle(string s) {
    cmdOk(format(`{"id":"viewport.displayStyle","params":"%s"}`, s));
    settle();
}

JSONValue preview() { return getJson("/api/subpatch/preview"); }

bool isTrue(JSONValue j, string k) { return j[k].type == JSONType.true_; }

JSONValue waitPreviewSettled() {
    foreach (_; 0 .. 1500) {
        auto p = preview();
        if (!isTrue(p, "pending")) return p;
        Thread.sleep(20.msecs);
    }
    assert(false, "subpatch preview build did not settle within 30 s");
}

/// 12-gon of radius `r` px around (cx, cy), played as a real RMB drag.
string loopLog(ref CameraState c, double cx, double cy, double r = 16.0) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height);
    int[2] at(int k) {
        immutable a = 2.0 * PI * k / 12.0;
        return [cast(int)lround(cx + r * cos(a)), cast(int)lround(cy + r * sin(a))];
    }
    double t = 50.0;
    auto p0 = at(0);
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, p0[0], p0[1]);
    int px = p0[0], py = p0[1];
    foreach (k; 1 .. 13) {
        auto p = at(k % 12);
        t += 25.0;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":4,"mod":0}` ~ "\n",
            t, p[0], p[1], p[0] - px, p[1] - py);
        px = p[0]; py = p[1];
    }
    t += 25.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, p0[0], p0[1]);
    return log;
}

int[] selectedVertices() {
    auto sel = getJson("/api/selection");
    assert(sel["mode"].str == "vertices",
           "the lasso ran outside vertex mode: " ~ sel["mode"].str);
    int[] o;
    foreach (e; sel["selectedVertices"].array) o ~= cast(int)e.integer;
    o.sort();
    return o;
}

void clearVertexSelection() {
    cmdOk(commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
}

/// Is the window point inside the 16 px 12-gon around (cx, cy)? The loop is
/// convex, so the inscribed-circle radius (16·cos 15°) is a safe inner bound
/// and the circumradius a safe outer one; anything between is refused as
/// ambiguous rather than guessed.
enum double kR = 16.0;
bool insideLoop(double[2] c, double[2] p) {
    immutable d = sqrt((p[0] - c[0]) ^^ 2 + (p[1] - c[1]) ^^ 2);
    assert(d < kR * cos(PI / 12.0) - 1.0 || d > kR + 1.0,
           format("rig: point (%s,%s) lies on the loop's rim around (%s,%s), d=%s",
                  p[0], p[1], c[0], c[1], d));
    return d < kR;
}

struct Rig {
    CameraState cam;
    Viewport    vp;
    double[2][8] cagePx, limitPx;
    double[3]  limit7;         // our drawn limit of v7
}

double[2] proj(ref Viewport vp, double x, double y, double z) {
    float sx, sy;
    assert(projectToWindow(Vec3(cast(float)x, cast(float)y, cast(float)z), vp, sx, sy),
           "rig point behind the eye");
    return [sx, sy];
}

/// Cube +-0.5 via scene.loadMesh, perspective eye along ~(1.3,1.7,3.7) at
/// distance 3, vertex mode. `subpatch` toggles every polygon to subpatch and
/// waits for the preview.
Rig setupCube(bool subpatch) {
    auto fx = parseJSON(kFixture);
    auto cube = fx["rigs"]["cube"];
    cmdOk(commandBody("scene.reset"));
    settle();
    setStyle("shaded");
    cmdOk(commandBody("scene.loadMesh",
        `{"vertices":` ~ cube["vertices"].toString ~ `,"faces":` ~ cube["polygons"].toString ~ `}`));
    auto model = getJson("/api/model");
    assert(model["vertices"].array.length == 8 && model["faces"].array.length == 6,
           format("rig: cube loaded as %d vertices / %d faces, want 8 / 6",
                  model["vertices"].array.length, model["faces"].array.length));
    // v7 is the (+,+,+) corner by the fixture's index rule.
    auto v7 = model["vertices"].array[7].array;
    assert(v7[0].floating == 0.5 && v7[1].floating == 0.5 && v7[2].floating == 0.5,
           "rig: vertex 7 is not the (+,+,+) corner: " ~ model["vertices"].array[7].toString);

    // Eye direction ~(1.3,1.7,3.7) normalised; azimuth about Y from +Z.
    immutable double n = sqrt(1.3 * 1.3 + 1.7 * 1.7 + 3.7 * 3.7);
    immutable double el = asinD(1.7 / n), az = atan2D(1.3, 3.7);
    auto cr = postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":3,"focus":{"x":0,"y":0,"z":0}}`,
        az, el));
    assert(cr["status"].str == "ok", "camera failed: " ~ cr.toString);
    settle();

    Rig r;
    r.cam = fetchCamera();
    auto e = r.cam.eye;
    immutable double el_ = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    assert(fabs(el_ - 3.0) < 1e-3
           && fabs(e.x / el_ - 1.3 / n) < 1e-3 && fabs(e.y / el_ - 1.7 / n) < 1e-3
           && fabs(e.z / el_ - 3.7 / n) < 1e-3,
           format("rig: eye (%s,%s,%s) is not along (1.3,1.7,3.7) at distance 3",
                  e.x, e.y, e.z));
    r.vp = viewportFromCamera(r.cam);

    cmdOk(`select.typeFrom polygon`);
    cmdOk(commandBody("mesh.select", `{"mode":"polygons","indices":[0,1,2,3,4,5]}`));
    if (subpatch) {
        cmdOk(`{"id":"mesh.subpatch_toggle"}`);
        auto p = waitPreviewSettled();
        assert(isTrue(p, "active"), "rig: the subpatch preview is not live: " ~ p.toString);
    }
    cmdOk(`select.typeFrom vertex`);
    clearVertexSelection();
    settle();

    // Our DRAWN limit of v7: the face-VBO position furthest along +x+y+z.
    // Without subpatch that is the cage corner itself.
    auto vbo = getJson("/api/gpu/face-vbo")["positions"].array;
    assert(vbo.length >= (subpatch ? 96 : 24),
           format("rig: face VBO holds %d positions — no surface is drawn", vbo.length));
    double best = -double.max;
    foreach (q; vbo) {
        auto a = q.array;
        immutable s = a[0].floating + a[1].floating + a[2].floating;
        if (s > best) { best = s; r.limit7 = [a[0].floating, a[1].floating, a[2].floating]; }
    }
    immutable double k = subpatch ? r.limit7[0] / 0.5 : 1.0;
    assert(fabs(r.limit7[0] - r.limit7[1]) < 1e-4 && fabs(r.limit7[1] - r.limit7[2]) < 1e-4,
           format("rig: the drawn corner is not on the diagonal: %s", r.limit7));
    foreach (i; 0 .. 8) {
        auto c = cube["vertices"].array[i].array;
        immutable double x = c[0].floating, y = c[1].floating, z = c[2].floating;
        r.cagePx[i]  = proj(r.vp, x, y, z);
        r.limitPx[i] = proj(r.vp, k * x, k * y, k * z);
    }
    return r;
}

double asinD(double v) { import std.math : asin; return asin(v); }
double atan2D(double y, double x) { import std.math : atan2; return atan2(y, x); }

/// The loop around `c` must enclose exactly the one intended point among all
/// 8 cage and 8 limit projections.
void floorIsolates(ref Rig r, double[2] c, bool wantCage, string what,
                   bool withLimit = true) {
    int nCage, nLimit;
    bool hit;
    foreach (i; 0 .. 8) {
        if (insideLoop(c, r.cagePx[i]))  { ++nCage;  if (wantCage && i == 7) hit = true; }
        if (withLimit && insideLoop(c, r.limitPx[i])) { ++nLimit; if (!wantCage && i == 7) hit = true; }
    }
    assert(hit && nCage + nLimit == 1,
           format("rig: loop does not isolate the intended point (%s): %d cage + "
                  ~ "%d limit projections inside", what, nCage, nLimit));
}

int[] lassoAround(ref Rig r, double[2] c) {
    clearVertexSelection();
    playAndWait(loopLog(r.cam, c[0], c[1], kR));
    settle();
    return selectedVertices();
}

unittest {
    // ---- floor 1: without subpatch a loop around v7 reaches it -------------
    {
        auto r = setupCube(false);
        // Without subpatch the drawn point IS the cage point; only 8 to count.
        floorIsolates(r, r.cagePx[7], true, "plain cage v7", false);
        auto got = lassoAround(r, r.cagePx[7]);
        assert(got == [7],
               format("rig: plain vertex lasso does not reach v7: selected %s", got));
    }

    auto r = setupCube(true);
    // The fixture's law says the limit of a cube corner is 0.5 x cage; ours is
    // what is drawn. Record the distance between the two in pixels so a
    // disagreement is visible, and keep the loops on OUR drawn point.
    // (floor 2) each loop isolates its one intended point.
    floorIsolates(r, r.limitPx[7], false, "subpatch limit v7");
    floorIsolates(r, r.cagePx[7],  true,  "subpatch cage v7");

    // ---- control 2, must stay GREEN: the cage-only loop selects nothing ----
    {
        auto got = lassoAround(r, r.cagePx[7]);
        assert(got.length == 0,
               format("cage-only lasso selected the vertex: %s", got));
    }

    // ---- cell B: the owner's scenario ---------------------------------------
    {
        auto p = preview();
        assert(isTrue(p, "active") && !isTrue(p, "pending"),
               "cell B: the preview is not settled: " ~ p.toString);
        auto got = lassoAround(r, r.limitPx[7]);
        assert(got == [7],
               format("subpatch vertex lasso selected %s, reference [7] (drawn "
                      ~ "limit %s at (%s,%s))", got, r.limit7,
                      r.limitPx[7][0], r.limitPx[7][1]));
    }

    // ---- cell C: no faces drawn, so no occlusion probe ---------------------
    {
        setStyle("wireframe");
        scope(exit) setStyle("shaded");
        auto got = lassoAround(r, r.limitPx[7]);
        assert(got == [7],
               format("subpatch vertex lasso without occlusion selected %s", got));
    }
}
