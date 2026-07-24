// Shared helpers for the Topology Pen placement tests
// (test_topopen_place_*.d). Mirrors drag_helpers.d's standalone-compile
// convention (test binaries pull no app source, so the small bits of
// camera/projection math this needs are duplicated here) plus
// test_acen_auto_relocate.d's precedent of adding a private screenRay
// reimplementation on top of drag_helpers' Vec3/Viewport/fetchCamera/
// viewportFromCamera.
//
// Placement seed = camera-ray∩bg-surface hit (CONFIRMED by a live
// cross-engine differential against the reference editor —
// toolcards/topology_pen/cross_engine_differential.md — superseding the P2
// work-plane-cursor derivation this file originally used; see
// source/toolpipe/stages/constrain.d's `pointNearestFootBackground` for the
// full finding). Every
// expected placement position in the test files that import this module is
// computed by the functions below — an INDEPENDENT reimplementation of
// screenRay / ray-sphere / ray-AABB intersection, not a call into
// source/constraint.d or source/toolpipe/stages/constrain.d (the code under
// test). Server responses are compared against these independently-computed
// values, never against each other.

module topopen_place_helpers;

import std.json;
import std.math    : sqrt, sin, cos, PI, abs;
import std.format  : format;
import std.net.curl : get, post;
import core.thread  : Thread;
import core.time    : dur;

public import drag_helpers : Vec3, Viewport, CameraState, dot, cross, normalize,
    lookAt, perspectiveMatrix, fetchCamera, viewportFromCamera, projectToWindow;

// ---------------------------------------------------------------------------
// HTTP plumbing (mirrors every other topology-pen test file's local idiom).
// ---------------------------------------------------------------------------

enum string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

/// Post-`/api/play-events` settle: `/status` reports `finished` once events
/// are POSTED to the SDL queue, not yet PROCESSED (CLAUDE.md flake note #3)
/// — a fixed settle after "finished" avoids reading 1-2-frame-stale state.
void waitPlayerIdle() {
    for (int i = 0; i < 200; ++i) {
        auto s = parseJSON(cast(string) get(baseUrl ~ "/api/play-events/status"));
        auto f = "finished" in s;
        if (f is null || f.type != JSONType.FALSE) {
            Thread.sleep(dur!"msecs"(120));
            return;
        }
        Thread.sleep(dur!"msecs"(10));
    }
    assert(false, "play-events did not finish within ~2s");
}

// ---------------------------------------------------------------------------
// screenRay — duplicated from source/math.d (same precedent as
// test_acen_auto_relocate.d's testScreenRay; test binaries compile
// standalone, so this stays a small, independent copy rather than pulling
// app sources into the test binary).
// ---------------------------------------------------------------------------

Vec3 screenRay(float sx, float sy, const ref Viewport vp) {
    float nx = ((sx - vp.x) / vp.width)  * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;
    float vx = nx / vp.proj[0];
    float vy = ny / vp.proj[5];
    const ref float[16] v = vp.view;
    Vec3 d = Vec3(v[0]*vx + v[1]*vy + v[2]*(-1.0f),
                  v[4]*vx + v[5]*vy + v[6]*(-1.0f),
                  v[8]*vx + v[9]*vy + v[10]*(-1.0f));
    float len = sqrt(dot(d, d));
    return len > 1e-9f ? d / len : Vec3(0, 0, -1);
}

/// Nearest (smallest positive `t`) intersection of the ray `origin + t*dir`
/// (`dir` assumed unit-length) with a sphere of radius `R` centred at
/// `center`. `false` on a miss (ray passes outside the sphere entirely —
/// discriminant < 0 — or both roots are behind the ray origin). This is
/// the independent reimplementation backing every sphere place-test's
/// "expected" value: the placement seed the tool now uses (CONFIRMED by a
/// live cross-engine differential against the reference editor,
/// source/toolpipe/stages/constrain.d's `pointNearestFootBackground`) IS
/// this camera-ray hit.
bool raySphereIntersect(Vec3 origin, Vec3 dir, Vec3 center, float R, out Vec3 hit) {
    Vec3 oc = origin - center;
    float b    = dot(oc, dir);
    float c    = dot(oc, oc) - R * R;
    float disc = b * b - c;
    if (disc < 0) return false;
    float sq = sqrt(disc);
    float t0 = -b - sq;
    float t1 = -b + sq;
    float t  = t0 >= 0 ? t0 : t1;
    if (t < 0) return false;
    hit = origin + dir * t;
    return true;
}

/// The camera-ray hit for pixel (px,py) under live camera state `c` against
/// a sphere of radius `R` centred at the world origin — the expected value
/// for every place_* sphere fixture below. `false` when the ray misses the
/// sphere (the camera/pixel choice must aim at the sphere; unlike the old
/// work-plane-cursor magnet, a miss here is a REAL miss, not a computation
/// failure).
bool expectedRayHitOnSphere(CameraState c, float px, float py, float R,
                            out Vec3 expected) {
    auto vp  = viewportFromCamera(c);
    Vec3 dir = screenRay(px, py, vp);
    return raySphereIntersect(vp.eye, dir, Vec3(0, 0, 0), R, expected);
}

/// Nearest (smallest positive `t`) ENTRY intersection of the ray
/// `origin + t*dir` with an axis-aligned box centred at the origin with
/// half-extent `he` (e.g. 0.5 for the standard unit cube) — the ray-AABB
/// analogue of `raySphereIntersect`, backing place_cube_flat's box
/// background. A plain 3-axis slab scan; `false` on a miss.
bool rayAabbIntersect(Vec3 origin, Vec3 dir, float he, out Vec3 hit) {
    float bestT = float.infinity;
    bool  found = false;

    void consider(float t, Vec3 p, float a, float b) {
        if (t < 0 || t >= bestT) return;
        if (a < -he - 1e-6f || a > he + 1e-6f) return;
        if (b < -he - 1e-6f || b > he + 1e-6f) return;
        bestT = t;
        hit   = p;
        found = true;
    }

    if (abs(dir.x) > 1e-9f) {
        foreach (sx; [-he, he]) {
            float t = (sx - origin.x) / dir.x;
            Vec3 p = origin + dir * t;
            consider(t, p, p.y, p.z);
        }
    }
    if (abs(dir.y) > 1e-9f) {
        foreach (sy; [-he, he]) {
            float t = (sy - origin.y) / dir.y;
            Vec3 p = origin + dir * t;
            consider(t, p, p.x, p.z);
        }
    }
    if (abs(dir.z) > 1e-9f) {
        foreach (sz; [-he, he]) {
            float t = (sz - origin.z) / dir.z;
            Vec3 p = origin + dir * t;
            consider(t, p, p.x, p.y);
        }
    }
    return found;
}

/// The camera-ray hit for pixel (px,py) under live camera state `c` against
/// an axis-aligned box centred at the origin with half-extent `he` — the
/// expected value for place_cube_flat.
bool expectedRayHitOnAabb(CameraState c, float px, float py, float he,
                         out Vec3 expected) {
    auto vp  = viewportFromCamera(c);
    Vec3 dir = screenRay(px, py, vp);
    return rayAabbIntersect(vp.eye, dir, he, expected);
}

// ---------------------------------------------------------------------------
// Sphere background mesh generator — parametric UV sphere at the world
// origin.
//
// Resolution note (empirically calibrated when this suite still compared
// against a work-plane-cursor nearest-foot; kept unchanged and still safe
// under the current camera-ray model): the place tests' "ground truth" is
// `raySphereIntersect` — the mathematically exact ray intersection against
// the IDEALIZED sphere — compared against the server's BVH ray-triangle
// pick over the FACETED approximation. A ray-hit's error source is the
// facet's own mid-face sagitta (the facet is a flat chord of the true
// sphere) — smaller, per-facet, and bounded independently of which
// direction the ray approaches from; it does NOT depend on the
// DISCRETE-vertex-spacing effect a *nearest-point* search (the old
// work-plane-cursor magnet) was vulnerable to, since a ray-triangle hit
// always lands somewhere ON the struck facet, never snapped toward a
// neighbouring sample direction. lon=96/lat=72 (used by every place test
// below, kept at its previously-calibrated resolution rather than relaxed
// now that the error model shrank) keeps the facet sagitta comfortably
// under 2% of R, safely inside the tests' tolerance band.
// ---------------------------------------------------------------------------

/// Vertex count a `sphereMeshBody(R, lon, lat)` call will produce — lets a
/// test assert the background layer's vertex count is UNCHANGED by a
/// placement click without re-deriving the arithmetic inline.
int sphereVertexCount(int lon, int lat) { return (lat - 1) * lon + 2; }

string sphereMeshBody(float R, int lon = 32, int lat = 24) {
    assert(lon >= 3 && lat >= 2, "degenerate sphere resolution");

    Vec3[] verts;
    verts ~= Vec3(0, R, 0);   // 0: top pole

    foreach (i; 1 .. lat) {
        float theta  = PI * i / lat;          // (0, pi), excludes both poles
        float y      = R * cos(theta);
        float ringR  = R * sin(theta);
        foreach (j; 0 .. lon) {
            float phi = 2.0f * PI * j / lon;
            verts ~= Vec3(ringR * cos(phi), y, ringR * sin(phi));
        }
    }
    int bottomIdx = cast(int) verts.length;
    verts ~= Vec3(0, -R, 0);  // bottom pole

    int ringStart(int ring) { return 1 + (ring - 1) * lon; }  // ring in [1, lat-1]

    int[][] faces;

    // Top cap: triangles pole(0) -> ring 1.
    {
        int r0 = ringStart(1);
        foreach (j; 0 .. lon) {
            int a = r0 + j;
            int b = r0 + (j + 1) % lon;
            faces ~= [0, a, b];
        }
    }
    // Middle bands: quads between ring i and ring i+1.
    foreach (i; 1 .. lat - 1) {
        int r0 = ringStart(i);
        int r1 = ringStart(i + 1);
        foreach (j; 0 .. lon) {
            int a0 = r0 + j, a1 = r0 + (j + 1) % lon;
            int b0 = r1 + j, b1 = r1 + (j + 1) % lon;
            faces ~= [a0, b0, b1, a1];
        }
    }
    // Bottom cap: triangles last ring -> pole(bottomIdx).
    {
        int r0 = ringStart(lat - 1);
        foreach (j; 0 .. lon) {
            int a = r0 + j;
            int b = r0 + (j + 1) % lon;
            faces ~= [bottomIdx, b, a];
        }
    }

    JSONValue[] vArr;
    foreach (v; verts)
        vArr ~= JSONValue([cast(double)v.x, cast(double)v.y, cast(double)v.z]);
    JSONValue[] fArr;
    foreach (f; faces) {
        JSONValue[] fi;
        foreach (idx; f) fi ~= JSONValue(idx);
        fArr ~= JSONValue(fi);
    }
    JSONValue j = JSONValue.emptyObject;
    j["vertices"] = JSONValue(vArr);
    j["faces"]    = JSONValue(fArr);
    return j.toString();
}

string cubeMeshBody() {
    return `{
        "vertices":[[-0.5,-0.5,-0.5],[0.5,-0.5,-0.5],[0.5,0.5,-0.5],[-0.5,0.5,-0.5],
                    [-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]],
        "faces":[[0,3,2,1],[4,5,6,7],[0,4,7,3],[1,2,6,5],[3,7,6,2],[0,1,5,4]]
    }`;
}

// ---------------------------------------------------------------------------
// Scene setup — background is layer 0 (loaded while it is still the
// reset-fresh primary), then `layer.add` appends an EMPTY layer 1 and makes
// IT primary. `LayerAdd.apply()` calls `Document.setActive()`, which is
// exclusive-SET (deselects every other layer) — so layer 0 (still visible,
// its default from creation) automatically becomes background (visible &&
// !selected) with NO separate `layer.setVisible`/`layer.select` call needed
// (commands/layer/commands.d).
// ---------------------------------------------------------------------------

void setupSphereBg(float R, int lon = 32, int lat = 24) {
    postJson("/api/reset", "");
    auto lr = postJson("/api/load-mesh", sphereMeshBody(R, lon, lat));
    assert(lr["status"].str == "ok", "load-mesh (sphere) failed: " ~ lr.toString);
    cmd("layer.add name:Edit");
}

void setupCubeBg() {
    postJson("/api/reset", "");
    auto lr = postJson("/api/load-mesh", cubeMeshBody());
    assert(lr["status"].str == "ok", "load-mesh (cube) failed: " ~ lr.toString);
    cmd("layer.add name:Edit");
}

// ---------------------------------------------------------------------------
// Event-log builders — a stationary LEFT click (down+up at the SAME pixel,
// no drag) fires `TopologyPenTool.onMouseButtonDown` exactly once per pair.
// The button-DOWN event alone carries its own x/y (app.d's handler builds
// the SubjectPacket from `btn.x/btn.y` directly), so no preceding
// MOUSEMOTION is required.
// ---------------------------------------------------------------------------

string viewportLog(int vpX, int vpY, int vpW, int vpH) {
    return format(`{"t":0.0,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`,
                  vpX, vpY, vpW, vpH);
}

string clickAt(double t0, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  t0, px, py) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  t0 + 10.0, px, py);
}

/// One click at (px,py).
string clickLog(int vpX, int vpY, int vpW, int vpH, int px, int py) {
    return viewportLog(vpX, vpY, vpW, vpH) ~ "\n" ~ clickAt(10.0, px, py) ~ "\n";
}

/// N clicks at distinct pixels, spaced 100ms apart so no two coalesce.
string multiClickLog(int vpX, int vpY, int vpW, int vpH, const int[2][] pts) {
    string log = viewportLog(vpX, vpY, vpW, vpH) ~ "\n";
    double t = 10.0;
    foreach (p; pts) {
        log ~= clickAt(t, p[0], p[1]) ~ "\n";
        t += 100.0;
    }
    return log;
}

// ---------------------------------------------------------------------------
// Model readers.
// ---------------------------------------------------------------------------

JSONValue modelForLayer(int layer) {
    return getJson(format("/api/model?layer=%d", layer));
}

int vertexCountLayer(int layer) {
    return cast(int) modelForLayer(layer)["vertexCount"].integer;
}

double[3][] readVerticesLayer(int layer) {
    auto m = modelForLayer(layer);
    auto arr = m["vertices"].array;
    auto outv = new double[3][](arr.length);
    foreach (i, v; arr) {
        auto c = v.array;
        outv[i] = [c[0].floating, c[1].floating, c[2].floating];
    }
    return outv;
}

bool approxVec(Vec3 a, double[3] b, double eps) {
    return abs(a.x - b[0]) < eps && abs(a.y - b[1]) < eps && abs(a.z - b[2]) < eps;
}

/// True iff SOME vertex in layer `layer` lies within `eps` of `expected`.
bool hasVertexNear(int layer, Vec3 expected, double eps) {
    foreach (v; readVerticesLayer(layer))
        if (approxVec(expected, v, eps)) return true;
    return false;
}
