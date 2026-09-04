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


public import http_client : getJson, postJson;
import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.json;
import std.math    : sqrt, sin, cos, PI, abs;
import std.format  : format;
import std.net.curl : get, post;
import core.thread  : Thread;
import core.time    : dur;

public import drag_helpers : Vec3, Viewport, CameraState, dot, cross, normalize,
    lookAt, perspectiveMatrix, fetchCamera, viewportFromCamera, projectToWindow,
    buildDragLog;

// ---------------------------------------------------------------------------
// HTTP plumbing shared by the topology-pen tests.
// ---------------------------------------------------------------------------

alias baseUrl = testBaseUrl;


void cmd(string argstring) {
    auto j = postJson("/api/command", argstring);
    assert(j["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

/// Split the surfaced strict-LIFO list into ordinary edit/state rows and
/// tool-lifecycle rows.  The latter are deliberately visible: the measured
/// surface in `toolcards/undo_surfaces/` has no hidden-but-counted arm state.
/// Tests for a no-op must therefore assert the two classes separately instead
/// of shifting one total-depth expectation and accidentally accepting a noisy
/// no-op.
struct HistorySurfaceCounts {
    size_t editRows;
    size_t lifecycleRows;
}

HistorySurfaceCounts classifyHistorySurfaceRows(JSONValue[] rows) {
    enum long toolLifecycleFlag = 1L << 10; // HistoryFlags.ToolLifecycle on the wire
    HistorySurfaceCounts result;
    foreach (entry; rows) {
        if ((entry["flags"].integer & toolLifecycleFlag) != 0)
            ++result.lifecycleRows;
        else
            ++result.editRows;
    }
    return result;
}

HistorySurfaceCounts historySurfaceCounts() {
    return classifyHistorySurfaceRows(getJson("/api/history")["undo"].array);
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
// TASK 0503 — the background RE-SNAP ground truth.
//
// The placement seed above is still a camera ray (a CLICK's CONS hit; that
// path is untouched). The per-vertex re-snap a DRAG applies is not: it is the
// NEAREST POINT on the background facet, clamped to that facet, measured on
// two gestures by two independently built rigs (see
// toolcards/topology_pen/dupedge_resnap_capture.md contract C-2 and
// addloop_bgresnap_undo_capture.md verdict V-1). The functions below are this
// suite's own reimplementation of that answer end to end: the drag's
// screen→world mapping, then a brute-force nearest-foot over the sphere the
// fixture actually posted.
//
// Against the FACETED sphere, deliberately, not the ideal one. A nearest foot
// taken from a query point |r - R| away from the surface lands off the ideal
// sphere by up to |r - R| * (facet half-angle) — 0.065 at this suite's
// resolution and radius, which is most of its whole tolerance band. A ray hit
// had no such term (it always lands ON the struck facet), which is why the
// resolution note further down was safe under the old law and is not under
// this one.
// ---------------------------------------------------------------------------

/// The world point a shared screen delta `(dx,dy)` moves `src` to under the
/// tool's mapping: shift `src`'s OWN projected pixel by the delta, then
/// unproject at CONSTANT view depth (the plane through `src` parallel to the
/// image plane). The `cast(int)` truncation and the `+0.5f` pixel centre
/// mirror the tool's own rounding, so the query point is reproduced exactly
/// rather than approximately. PERSPECTIVE viewports only — every fixture in
/// this suite posts a perspective camera.
bool shiftedWorldPoint(const ref Viewport vp, Vec3 src, int dx, int dy, out Vec3 q) {
    float sx, sy;
    if (!projectToWindow(src, vp, sx, sy)) return false;
    immutable int px = cast(int)(sx + cast(float)dx);
    immutable int py = cast(int)(sy + cast(float)dy);
    Vec3 dir = screenRay(cast(float)px + 0.5f, cast(float)py + 0.5f, vp);
    // View matrix third ROW = the camera-back direction; the plane through
    // `src` with that normal is the constant-view-depth plane.
    Vec3 camBack = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    float denom = dot(camBack, dir);
    if (abs(denom) < 1e-6f) return false;
    q = vp.eye + dir * (dot(camBack, src - vp.eye) / denom);
    return true;
}

/// Closest point of triangle (a,b,c) to `p`, clamped to the triangle —
/// the standard barycentric region walk, written out here so the expected
/// value never comes from a call into source/constraint.d.
Vec3 closestPointOnTri(Vec3 p, Vec3 a, Vec3 b, Vec3 c) {
    Vec3 ab = b - a, ac = c - a, ap = p - a;
    float d1 = dot(ab, ap), d2 = dot(ac, ap);
    if (d1 <= 0 && d2 <= 0) return a;

    Vec3 bp = p - b;
    float d3 = dot(ab, bp), d4 = dot(ac, bp);
    if (d3 >= 0 && d4 <= d3) return b;

    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0) return a + ab * (d1 / (d1 - d3));

    Vec3 cp = p - c;
    float d5 = dot(ab, cp), d6 = dot(ac, cp);
    if (d6 >= 0 && d5 <= d6) return c;

    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0) return a + ac * (d2 / (d2 - d6));

    float va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0)
        return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)));

    float denom = 1.0f / (va + vb + vc);
    return a + ab * (vb * denom) + ac * (vc * denom);
}

/// Globally nearest point of a polygon soup to `p`. Fan-triangulates each
/// polygon on vertex 0, the same fan the server rasterizes and constrains
/// against, so the answer is exact for the non-planar quads a UV sphere is
/// made of rather than merely close.
bool closestPointOnPolySoup(Vec3 p, const Vec3[] verts, const int[][] faces,
                            out Vec3 hit) {
    bool  found  = false;
    float bestD2 = float.max;
    foreach (f; faces) {
        if (f.length < 3) continue;
        Vec3 a = verts[f[0]];
        for (size_t i = 1; i + 1 < f.length; ++i) {
            Vec3 cp = closestPointOnTri(p, a, verts[f[i]], verts[f[i + 1]]);
            Vec3 d  = cp - p;
            float d2 = dot(d, d);
            if (d2 < bestD2) { bestD2 = d2; hit = cp; found = true; }
        }
    }
    return found;
}

/// Where a vertex at `src` must land after a `(dx,dy)` pixel drag over the
/// sphere background this suite posts: the nearest point of that sphere's own
/// FACETS to the drag's constant-depth world point. `false` only when `src`
/// does not project (the sphere is closed, so the foot itself never misses —
/// which is the point: a camera ray could miss, a clamped nearest foot
/// cannot).
bool expectedNearestOnSphere(CameraState c, Vec3 src, int dx, int dy,
                             float R, int lon, int lat, out Vec3 expected) {
    auto vp = viewportFromCamera(c);
    Vec3 q;
    if (!shiftedWorldPoint(vp, src, dx, dy, q)) return false;
    Vec3[]  verts;
    int[][] faces;
    sphereMeshData(R, lon, lat, verts, faces);
    return closestPointOnPolySoup(q, verts, faces, expected);
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
//
// TASK 0503: that reasoning still covers the PLACEMENT tests, which are
// still a camera ray. It does NOT cover the re-snap a DRAG now applies —
// see `expectedNearestOnSphere` above, which is why the re-snap ground
// truth is taken against these facets rather than the ideal sphere.
// ---------------------------------------------------------------------------

/// Vertex count a `sphereMeshBody(R, lon, lat)` call will produce — lets a
/// test assert the background layer's vertex count is UNCHANGED by a
/// placement click without re-deriving the arithmetic inline.
int sphereVertexCount(int lon, int lat) { return (lat - 1) * lon + 2; }

/// The sphere background's own vertex/face arrays — the exact geometry
/// `sphereMeshBody` posts. Factored out (task 0503) so a test can compute a
/// nearest-foot ground truth against the FACETS the server actually holds,
/// not against an idealized sphere.
void sphereMeshData(float R, int lon, int lat, out Vec3[] verts, out int[][] faces) {
    assert(lon >= 3 && lat >= 2, "degenerate sphere resolution");

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
}

string sphereMeshBody(float R, int lon = 32, int lat = 24) {
    Vec3[]  verts;
    int[][] faces;
    sphereMeshData(R, lon, lat, verts, faces);

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
    postJson("/api/command", commandBody("scene.reset"));
    auto lr = postJson("/api/command", commandBody("scene.loadMesh", sphereMeshBody(R, lon, lat)));
    assert(lr["status"].str == "ok", "load-mesh (sphere) failed: " ~ lr.toString);
    cmd("layer.add name:Edit");
}

void setupCubeBg() {
    postJson("/api/command", commandBody("scene.reset"));
    auto lr = postJson("/api/command", commandBody("scene.loadMesh", cubeMeshBody()));
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

// ---------------------------------------------------------------------------
// P3 (doc/topopen_p3_plan.md) build-gesture readers — edges/faces, on top of
// the vertex readers above. Every value returned here is checked against an
// INDEPENDENTLY-computed expectation by the test, never compared against
// vibe3d's own prior output.
// ---------------------------------------------------------------------------

int edgeCountLayer(int layer) {
    return cast(int) modelForLayer(layer)["edgeCount"].integer;
}

int faceCountLayer(int layer) {
    return cast(int) modelForLayer(layer)["faceCount"].integer;
}

/// All edges of `layer` as unordered `[a,b]` index pairs (raw server order).
int[2][] readEdgesLayer(int layer) {
    auto m = modelForLayer(layer);
    auto arr = m["edges"].array;
    auto outE = new int[2][](arr.length);
    foreach (i, e; arr) {
        auto c = e.array;
        outE[i] = [cast(int)c[0].integer, cast(int)c[1].integer];
    }
    return outE;
}

/// All faces of `layer` as ordered vertex-index arrays (raw server order —
/// winding survives exactly as the tool emitted it).
int[][] readFacesLayer(int layer) {
    auto m = modelForLayer(layer);
    auto arr = m["faces"].array;
    auto outF = new int[][](arr.length);
    foreach (i, f; arr) {
        auto c = f.array;
        auto face = new int[](c.length);
        foreach (j, vi; c) face[j] = cast(int)vi.integer;
        outF[i] = face;
    }
    return outF;
}

/// True iff SOME edge in `layer` connects `a`/`b` (unordered).
bool hasEdgeLayer(int layer, int a, int b) {
    foreach (e; readEdgesLayer(layer))
        if ((e[0] == a && e[1] == b) || (e[0] == b && e[1] == a)) return true;
    return false;
}

/// True iff `layer` contains a face whose vertex-index array is EXACTLY
/// `expected` (same length, same order, same start — no rotation/reflection
/// tolerance) — for asserting a captured winding verbatim, not just the
/// unordered vertex set.
bool hasExactFace(int layer, const int[] expected) {
    foreach (f; readFacesLayer(layer))
        if (f == expected) return true;
    return false;
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
