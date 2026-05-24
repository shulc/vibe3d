/// Headless render-diff entry point.
///
/// Drives one backend (Cycles or RPR) on a JSON-described scene, samples
/// the result N times, then writes the resolved framebuffer to a PPM
/// (8-bit RGB) file and exits. Used by `tools/render_diff/run.d` to
/// cross-validate the two backends pixel-for-pixel on the same scene.
///
/// Intentionally bypasses the IPR panel and the rest of vibe3d's UI:
/// no SDL, no GL, no ImGui. The two backends both run on CPU here (their
/// CPU paths don't need a GL context), so the executable can finish even
/// when launched headless / in CI / without an X server.
module render.render_diff;

version (WithRender):

import std.algorithm : min, max;
import std.array     : appender;
import std.conv      : to;
import std.file      : readText;
import std.format    : format;
import std.json;
import std.math      : PI;
import std.stdio     : File, stderr, writeln;
import core.thread   : Thread, msecs, seconds;
import core.time     : MonoTime, dur;

import render.backend;
import render.backend_bridge : BackendBridge;
import render.scene          : Scene;
import math : Vec3;

// ---------------------------------------------------------------------------
// Case schema
// ---------------------------------------------------------------------------

struct CameraCase
{
    Vec3  eye    = Vec3(3, 2, 3);
    Vec3  target = Vec3(0, 0, 0);
    Vec3  up     = Vec3(0, 1, 0);
    float fovVerticalDegrees = 45.0f;
}

struct LightCase
{
    string kind = "sun";          // "sun" | "point"
    Vec3   direction = Vec3(-1, -1, -1);  // sun: world-space direction
    Vec3   position  = Vec3(2, 3, 2);     // point only
    Vec3   color     = Vec3(1, 1, 1);
    float  intensity = 3.0f;
}

struct MeshCase
{
    string kind = "cube";        // "cube" only for v1
    float  size = 1.0f;
    Vec3   color = Vec3(0.7, 0.7, 0.7);
    // MG5 — per-face surface colours. When non-empty (and `kind ==
    // "cube"`), the loader emits 6 sub-meshes, one per cube face,
    // each assigned its own CompiledMaterial. Length must be 6 for
    // a cube; entries that fall outside the array reuse the scalar
    // `color`.
    Vec3[] surfaceColors;
}

struct RenderCase
{
    string    name;
    int       width  = 256;
    int       height = 256;
    int       samples = 64;
    float     tolerance = 0.05f;
    CameraCase camera;
    LightCase  light;
    MeshCase   mesh;
    Vec3       envColor = Vec3(0.05, 0.05, 0.08);
}

private Vec3 readVec3(JSONValue v, Vec3 fallback)
{
    if (v.type != JSONType.array || v.array.length != 3) return fallback;
    return Vec3(
        cast(float) v.array[0].floating,
        cast(float) v.array[1].floating,
        cast(float) v.array[2].floating);
}

private float readFloat(JSONValue v, float fallback)
{
    if (v.type == JSONType.float_)   return cast(float) v.floating;
    if (v.type == JSONType.integer) return cast(float) v.integer;
    if (v.type == JSONType.uinteger) return cast(float) v.uinteger;
    return fallback;
}

private int readInt(JSONValue v, int fallback)
{
    if (v.type == JSONType.integer)  return cast(int) v.integer;
    if (v.type == JSONType.uinteger) return cast(int) v.uinteger;
    if (v.type == JSONType.float_)   return cast(int) v.floating;
    return fallback;
}

RenderCase parseCase(string path)
{
    auto data = parseJSON(readText(path));
    RenderCase rc;

    if ("name" in data)       rc.name = data["name"].str;
    if ("resolution" in data) {
        const r = data["resolution"];
        rc.width  = readInt(r.array[0], 256);
        rc.height = readInt(r.array[1], 256);
    }
    if ("samples" in data)   rc.samples   = readInt(data["samples"], 64);
    if ("tolerance" in data) rc.tolerance = readFloat(data["tolerance"], 0.05f);

    if ("camera" in data) {
        const c = data["camera"];
        if ("eye"    in c) rc.camera.eye    = readVec3(c["eye"],    rc.camera.eye);
        if ("target" in c) rc.camera.target = readVec3(c["target"], rc.camera.target);
        if ("up"     in c) rc.camera.up     = readVec3(c["up"],     rc.camera.up);
        if ("fov_vertical_degrees" in c)
            rc.camera.fovVerticalDegrees = readFloat(c["fov_vertical_degrees"], 45.0f);
    }

    if ("light" in data) {
        const l = data["light"];
        if ("kind"      in l) rc.light.kind      = l["kind"].str;
        if ("direction" in l) rc.light.direction = readVec3(l["direction"], rc.light.direction);
        if ("position"  in l) rc.light.position  = readVec3(l["position"],  rc.light.position);
        if ("color"     in l) rc.light.color     = readVec3(l["color"],     rc.light.color);
        if ("intensity" in l) rc.light.intensity = readFloat(l["intensity"], 3.0f);
    }

    if ("mesh" in data) {
        const m = data["mesh"];
        if ("kind"  in m) rc.mesh.kind  = m["kind"].str;
        if ("size"  in m) rc.mesh.size  = readFloat(m["size"], 1.0f);
        if ("color" in m) rc.mesh.color = readVec3(m["color"], rc.mesh.color);
        if ("surface_colors" in m && m["surface_colors"].type == JSONType.array) {
            foreach (sc; m["surface_colors"].array)
                rc.mesh.surfaceColors ~= readVec3(sc, Vec3(0.7f, 0.7f, 0.7f));
        }
    }

    if ("environment" in data) {
        const e = data["environment"];
        if ("color" in e) rc.envColor = readVec3(e["color"], rc.envColor);
    }

    return rc;
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

/// Build a unit-cube triangulation centered at the origin. Edge length =
/// `size`. Returns (xyz, tris). Triangulated faces only (no quads) — both
/// backends consume triangle indices.
private void buildCube(float size, out float[] xyz, out int[] tris)
{
    const float s = size * 0.5f;
    xyz = [
        -s, -s, -s,   s, -s, -s,   s,  s, -s,  -s,  s, -s,   // back face
        -s, -s,  s,   s, -s,  s,   s,  s,  s,  -s,  s,  s,   // front face
    ];
    tris = [
        // back  (-Z)
        0, 2, 1,  0, 3, 2,
        // front (+Z)
        4, 5, 6,  4, 6, 7,
        // left  (-X)
        0, 4, 7,  0, 7, 3,
        // right (+X)
        1, 2, 6,  1, 6, 5,
        // bottom(-Y)
        0, 1, 5,  0, 5, 4,
        // top   (+Y)
        3, 7, 6,  3, 6, 2,
    ];
}

/// Build a 4×4 row-major light transform from a Sun direction. Cycles +
/// RPR both derive direction from the local -Z axis after the rotation
/// portion of the transform; build a rotation so -Z (light's forward)
/// points along the world-space `dir`.
private float[16] sunTransformFromDirection(Vec3 dir)
{
    // Normalize and flip — we want -Z to align with dir.
    import std.math : sqrt, abs;
    const float len = sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z);
    const Vec3 forward = len > 0
        ? Vec3(dir.x / len, dir.y / len, dir.z / len)
        : Vec3(0, -1, 0);
    const Vec3 negFwd = Vec3(-forward.x, -forward.y, -forward.z);   // light local -Z

    // Build an orthonormal frame with z = negFwd (so its -Z = forward).
    Vec3 helper = (abs(negFwd.y) < 0.9f) ? Vec3(0, 1, 0) : Vec3(1, 0, 0);
    // x = normalize(helper × z)
    Vec3 right = Vec3(
        helper.y * negFwd.z - helper.z * negFwd.y,
        helper.z * negFwd.x - helper.x * negFwd.z,
        helper.x * negFwd.y - helper.y * negFwd.x);
    const float rlen = sqrt(right.x * right.x + right.y * right.y + right.z * right.z);
    if (rlen > 0) {
        right.x /= rlen; right.y /= rlen; right.z /= rlen;
    }
    // y = z × x
    const Vec3 upAxis = Vec3(
        negFwd.y * right.z - negFwd.z * right.y,
        negFwd.z * right.x - negFwd.x * right.z,
        negFwd.x * right.y - negFwd.y * right.x);

    // Row-major 4×4 with rotation in upper-left, translation = 0.
    return [
        right.x, upAxis.x, negFwd.x, 0,
        right.y, upAxis.y, negFwd.y, 0,
        right.z, upAxis.z, negFwd.z, 0,
        0,       0,        0,        1,
    ];
}

// ---------------------------------------------------------------------------
// PPM writer
// ---------------------------------------------------------------------------

/// Write an 8-bit RGB PPM. Float RGBA input is clamped to [0,1] then
/// quantized — no tone mapping (Cycles/RPR both apply display gamma 2.2
/// in our setup, so the pixels are roughly in sRGB-ish space already).
private void writePPM(string path, in float[] rgba, int w, int h)
{
    auto f = File(path, "wb");
    f.writef("P6\n%d %d\n255\n", w, h);
    auto buf = new ubyte[cast(size_t)w * h * 3];
    foreach (i; 0 .. cast(size_t)w * h) {
        float r = rgba[i * 4 + 0];
        float g = rgba[i * 4 + 1];
        float b = rgba[i * 4 + 2];
        if (r < 0) r = 0; else if (r > 1) r = 1;
        if (g < 0) g = 0; else if (g > 1) g = 1;
        if (b < 0) b = 0; else if (b > 1) b = 1;
        buf[i * 3 + 0] = cast(ubyte)(r * 255.0f + 0.5f);
        buf[i * 3 + 1] = cast(ubyte)(g * 255.0f + 0.5f);
        buf[i * 3 + 2] = cast(ubyte)(b * 255.0f + 0.5f);
    }
    f.rawWrite(buf);
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

/// Render the case via `backendName` and write the resolved framebuffer to
/// `outputPath` as PPM. Returns 0 on success, 1 on any failure. Used from
/// app.d's `--render-diff` CLI path; this function never returns to the
/// SDL/ImGui main loop.
int runRenderDiff(string casePath, string backendName, string outputPath)
{
    RenderCase rc;
    try {
        rc = parseCase(casePath);
    } catch (Exception e) {
        stderr.writeln("render_diff: failed to parse case: ", e.msg);
        return 1;
    }

    writeln(format("render_diff: case=%s backend=%s res=%dx%d samples=%d",
                   rc.name.length ? rc.name : casePath,
                   backendName, rc.width, rc.height, rc.samples));

    auto bridge = new BackendBridge();
    auto scene  = new Scene();

    BackendConfig cfg;
    cfg.device  = "cpu";
    cfg.samples = rc.samples;

    if (!bridge.init(backendName, cfg)) {
        stderr.writeln("render_diff: bridge.init failed: ", bridge.lastError);
        return 1;
    }

    // ---- Scene IR ----
    LightDesc ld;
    if (rc.light.kind == "point") {
        ld.kind = LightDesc.Kind.Point;
        ld.transform = [
            1, 0, 0, rc.light.position.x,
            0, 1, 0, rc.light.position.y,
            0, 0, 1, rc.light.position.z,
            0, 0, 0, 1,
        ];
    } else {
        ld.kind = LightDesc.Kind.Sun;
        ld.transform = sunTransformFromDirection(rc.light.direction);
    }
    ld.color     = rc.light.color;
    ld.intensity = rc.light.intensity;
    const ulong lightId = scene.addLight(ld);

    float[] xyz;
    int[]   tris;
    if (rc.mesh.kind == "cube") {
        buildCube(rc.mesh.size, xyz, tris);
    } else {
        stderr.writeln("render_diff: unsupported mesh kind: ", rc.mesh.kind);
        return 1;
    }

    // MG5 — multi-surface cubes split into 6 sub-meshes, one per face,
    // each carrying its own CompiledMaterial. The face-to-tri layout
    // emitted by buildCube is fixed at "two consecutive triangles per
    // face", indexed back→front→left→right→bottom→top, so the bucket
    // walk is a constant 6×2 slice across `tris`.
    if (rc.mesh.kind == "cube" && rc.mesh.surfaceColors.length >= 6) {
        foreach (face; 0 .. 6) {
            CompiledMaterial cm;
            cm.baseColor = rc.mesh.surfaceColors[face];
            const ulong sceneMatId  = scene.addMaterial(cm);
            // 6 indices per face = two triangles. tris[] is already flat.
            int[] faceTris = tris[face * 6 .. face * 6 + 6].dup;
            const ulong sceneMeshId = scene.addMesh(
                xyz, /*normals*/[], /*uv*/[], faceTris);
            scene.assignMaterial(sceneMeshId, sceneMatId);
        }
    } else {
        CompiledMaterial cm;
        cm.baseColor = rc.mesh.color;
        const ulong matId  = scene.addMaterial(cm);
        const ulong meshId = scene.addMesh(xyz, /*normals*/[], /*uv*/[], tris);
        scene.assignMaterial(meshId, matId);
    }

    EnvDesc ed;
    ed.kind  = EnvDesc.Kind.Solid;
    ed.color = rc.envColor;
    scene.setEnvironment(ed);

    CameraDesc cd;
    cd.kind   = CameraDesc.Kind.Perspective;
    cd.eye    = rc.camera.eye;
    cd.target = rc.camera.target;
    cd.up     = rc.camera.up;
    cd.aspect = cast(float)rc.width / cast(float)rc.height;
    cd.fovRadiansVertical = rc.camera.fovVerticalDegrees * cast(float)(PI / 180.0);
    scene.setCamera(cd);

    // ---- Render ----
    if (!bridge.sync(scene)) {
        stderr.writeln("render_diff: bridge.sync failed: ", bridge.lastError);
        bridge.shutdown();
        return 1;
    }
    bridge.resize(rc.width, rc.height);
    if (!bridge.resetAccumulation()) {
        stderr.writeln("render_diff: bridge.resetAccumulation failed: ", bridge.lastError);
        bridge.shutdown();
        return 1;
    }

    // Poll progress until done. Hard timeout = 5 minutes (very forgiving;
    // CPU Cycles cold-start on first launch can be slow).
    const auto deadline = MonoTime.currTime + dur!"minutes"(5);
    while (bridge.progress() < 1.0f) {
        if (MonoTime.currTime > deadline) {
            stderr.writeln("render_diff: render timed out");
            bridge.shutdown();
            return 1;
        }
        bridge.tick();
        Thread.sleep(50.msecs);
    }

    // One last tick + a brief settle so any async resolve flushes.
    bridge.tick();
    Thread.sleep(100.msecs);

    float[] pixels;
    int rw, rh;
    if (!bridge.grabPixels(pixels, rw, rh) || rw != rc.width || rh != rc.height) {
        stderr.writeln(format(
            "render_diff: grabPixels failed or dim mismatch (got %dx%d, expected %dx%d)",
            rw, rh, rc.width, rc.height));
        bridge.shutdown();
        return 1;
    }

    try {
        writePPM(outputPath, pixels, rw, rh);
    } catch (Exception e) {
        stderr.writeln("render_diff: PPM write failed: ", e.msg);
        bridge.shutdown();
        return 1;
    }
    writeln(format("render_diff: wrote %s (%dx%d)", outputPath, rw, rh));

    bridge.shutdown();
    return 0;
}
