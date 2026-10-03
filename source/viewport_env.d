// The Reflection style's images (wave plan S4b, task 9250): three equirect
// environments and eight two-layer MatCaps, vendored as 16-bit PNGs under
// `assets/shading/` (CC0; `SOURCES.md`, `MANIFEST.tsv`) and string-imported.
//
// One decode path for both kinds: `decodePng16` → linear float RGBA
// (`v / 65535 · kShadingImageLinearScale`), kept as the CPU copy that the
// test route `/api/viewport/env-sample` samples, and uploaded once as an
// RGBA16F `GL_TEXTURE_2D` from the same array (`GL_FLOAT` data: filterable in
// GL 3.3 and ES 3.0; never rendered to). Both happen lazily, on first use of
// a source, on the main (GL) thread only.
//
// The lookups are `envUv` / `matcapUv`; the lit fragment shader's Reflection
// arm mirrors them line for line (`shader.d`, `envUv` / `matcapUv`), the same
// split as `litTerm` / `lineShade`. Equirect, not a cube map: one texture
// type, no seamless-cube enum (absent on WebGL2), no mipmaps so no LOD jump
// at the `atan` wrap, which sits at R = (0,0,-1), away from the viewer.
module viewport_env;

import bindbc.opengl;
import std.math : atan2, acos, PI, floor;

import math : Vec3;
import display_state : ReflectionKind, ReflectionSource;
import io.image_decode : decodePng16;

/// The one linear scale of every shading image: stored = linear / 16
/// (`tools/convert_shading_images.py`, `MANIFEST.tsv` column `linear_scale`).
enum float kShadingImageLinearScale = 16.0f;

/// One environment: its name (the command/prefs spelling) and PNG bytes.
struct EnvAsset {
    string name;
    immutable(ubyte)[] png;
}

/// One MatCap: its name and the two layers (diffuse × base, specular added).
struct MatcapAsset {
    string name;
    immutable(ubyte)[] diffuse;
    immutable(ubyte)[] specular;
}

private EnvAsset env(string n)() {
    return EnvAsset(n, cast(immutable(ubyte)[]) import("env_" ~ n ~ ".png"));
}

private MatcapAsset matcap(string n)() {
    return MatcapAsset(n,
        cast(immutable(ubyte)[]) import("matcap_" ~ n ~ "_diffuse.png"),
        cast(immutable(ubyte)[]) import("matcap_" ~ n ~ "_specular.png"));
}

/// The environments, in offer order; index 0 is the default source — the
/// outdoor sky, not the studio, whose dark walls turn flat faces near-black
/// (owner decision 2026-10-03, task 9250).
immutable EnvAsset[3] kEnvAssets = [
    env!"kloofendal_48d_partly_cloudy_puresky",
    env!"studio_small_09",
    env!"courtyard",
];

/// The MatCaps, in offer order.
immutable MatcapAsset[8] kMatcapAssets = [
    matcap!"basic_grey",
    matcap!"basic_side",
    matcap!"clay_studio",
    matcap!"ceramic_lightbulb",
    matcap!"hard_surface_grey",
    matcap!"metal_carpaint",
    matcap!"toon_light",
    matcap!"check_rim_light",
];

static assert(kEnvAssets[ReflectionSource.init.index].name == "kloofendal_48d_partly_cloudy_puresky"
    && ReflectionSource.init.kind == ReflectionKind.Env,
    "the default reflection source is the outdoor sky environment");

// ---- the lookups (mirrored by the GLSL arm) ---------------------------------

/// Equirect texture coordinate of the unit direction `r` (eye space):
/// `u = 0.5 + atan2(r.x, r.z) / 2π` (R = +Z, toward the viewer, at the image
/// centre; the wrap at R = −Z), `v = acos(r.y) / π` (v = 0 = the image's
/// first row = +Y). Pole guard: at r.x = r.z = 0 `atan2` is undefined in GLSL,
/// so both sides take u = 0.5 there with the same expression.
float[2] envUv(Vec3 r) pure nothrow @safe @nogc {
    immutable float u = (r.x * r.x + r.z * r.z < 1e-12f)
        ? 0.5f : 0.5f + atan2(r.x, r.z) / (2.0f * cast(float) PI);
    immutable float y = r.y < -1.0f ? -1.0f : (r.y > 1.0f ? 1.0f : r.y);
    return [u, acos(y) / cast(float) PI];
}

/// MatCap texture coordinate of the unit eye-space normal `n`:
/// `(0.5 + 0.5 n.x, 0.5 − 0.5 n.y)` (v = 0 = the first row = up).
float[2] matcapUv(Vec3 n) pure nothrow @safe @nogc {
    return [0.5f + 0.5f * n.x, 0.5f - 0.5f * n.y];
}

// ---- source ids (command, prefs, endpoint) -----------------------------------

/// `env:<name>` / `matcap:<name>`; "" for an index past the table.
string reflectionSourceId(ReflectionSource s) pure nothrow @safe {
    final switch (s.kind) {
        case ReflectionKind.Env:
            return s.index < kEnvAssets.length ? "env:" ~ kEnvAssets[s.index].name : "";
        case ReflectionKind.MatCap:
            return s.index < kMatcapAssets.length
                ? "matcap:" ~ kMatcapAssets[s.index].name : "";
    }
}

/// Parse an id written by `reflectionSourceId`; false (and `s` untouched) for
/// any other text — an unknown name is refused, never mapped to a default.
bool parseReflectionSource(string id, ref ReflectionSource s) pure nothrow @safe @nogc {
    foreach (i, a; kEnvAssets)
        if (id.length == 4 + a.name.length && id[0 .. 4] == "env:" && id[4 .. $] == a.name) {
            s = ReflectionSource(ReflectionKind.Env, cast(ubyte) i);
            return true;
        }
    foreach (i, a; kMatcapAssets)
        if (id.length == 7 + a.name.length && id[0 .. 7] == "matcap:" && id[7 .. $] == a.name) {
            s = ReflectionSource(ReflectionKind.MatCap, cast(ubyte) i);
            return true;
        }
    return false;
}

/// UI label of a source ("Environment: <name>" / "MatCap: <name>").
string reflectionSourceLabel(ReflectionSource s) pure nothrow @safe {
    immutable id = reflectionSourceId(s);
    if (id.length == 0) return "";
    return s.kind == ReflectionKind.Env ? "Environment: " ~ id[4 .. $]
                                        : "MatCap: " ~ id[7 .. $];
}

/// Every source in offer order: the environments, then the MatCaps.
ReflectionSource[] allReflectionSources() pure nothrow @safe {
    ReflectionSource[] r;
    foreach (i; 0 .. kEnvAssets.length)
        r ~= ReflectionSource(ReflectionKind.Env, cast(ubyte) i);
    foreach (i; 0 .. kMatcapAssets.length)
        r ~= ReflectionSource(ReflectionKind.MatCap, cast(ubyte) i);
    return r;
}

// ---- decoded images (CPU copy) ----------------------------------------------

/// A decoded image in linear float RGBA (row-major, first row = top).
struct LinearImage {
    int w, h;
    float[] rgba;
}

/// PNG bytes → linear RGBA, `v / 65535 · kShadingImageLinearScale`. An empty
/// image when the bytes do not decode as a 16-bit PNG.
LinearImage decodeShadingImage(const(ubyte)[] png) {
    int w, h;
    ushort[] px = decodePng16(png, w, h);
    if (px is null) return LinearImage.init;
    auto f = new float[px.length];
    foreach (i, v; px)
        f[i] = (i & 3) == 3 ? v / 65535.0f
                            : v / 65535.0f * kShadingImageLinearScale;
    return LinearImage(w, h, f);
}

// Main-thread state (the GL thread): decoded once per image, uploaded once.
private LinearImage[kEnvAssets.length]       envImg_;
private LinearImage[2][kMatcapAssets.length] matcapImg_;
private uint[kEnvAssets.length]              envTex_;
private uint[2][kMatcapAssets.length]        matcapTex_;

/// The decoded environment `i` (decoded on first use).
ref const(LinearImage) envImage(size_t i) {
    if (envImg_[i].rgba is null) envImg_[i] = decodeShadingImage(kEnvAssets[i].png);
    return envImg_[i];
}

/// The decoded MatCap `i`, `layer` 0 = diffuse, 1 = specular.
ref const(LinearImage) matcapImage(size_t i, size_t layer) {
    if (matcapImg_[i][layer].rgba is null)
        matcapImg_[i][layer] = decodeShadingImage(
            layer == 0 ? kMatcapAssets[i].diffuse : kMatcapAssets[i].specular);
    return matcapImg_[i][layer];
}

/// Bilinear sample of `img` at (u, v) with GL_LINEAR's texel-centre
/// convention (texel k covers [k, k+1)/size, centre at k + 0.5); `wrapU`
/// repeats u (GL_REPEAT), otherwise both axes clamp to the edge texels.
float[3] sampleBilinear(ref const(LinearImage) img, float u, float v, bool wrapU)
    pure nothrow @safe @nogc
{
    float[3] o = 0;
    if (img.w <= 0 || img.h <= 0) return o;
    immutable float x = u * img.w - 0.5f, y = v * img.h - 0.5f;
    immutable float fx = floor(x), fy = floor(y);
    immutable float ax = x - fx, ay = y - fy;
    int col(long c) {
        if (wrapU) { long m = c % img.w; return cast(int)(m < 0 ? m + img.w : m); }
        return cast(int)(c < 0 ? 0 : (c >= img.w ? img.w - 1 : c));
    }
    int row(long r) { return cast(int)(r < 0 ? 0 : (r >= img.h ? img.h - 1 : r)); }
    immutable int x0 = col(cast(long) fx), x1 = col(cast(long) fx + 1);
    immutable int y0 = row(cast(long) fy), y1 = row(cast(long) fy + 1);
    foreach (c; 0 .. 3) {
        float at(int xx, int yy) { return img.rgba[(cast(size_t) yy * img.w + xx) * 4 + c]; }
        o[c] = (at(x0, y0) * (1 - ax) + at(x1, y0) * ax) * (1 - ay)
             + (at(x0, y1) * (1 - ax) + at(x1, y1) * ax) * ay;
    }
    return o;
}

/// The environment `i` at the eye-space direction `dir` (normalised here).
float[3] envSample(size_t i, Vec3 dir) {
    import math : normalize;
    immutable uv = envUv(normalize(dir));
    return sampleBilinear(envImage(i), uv[0], uv[1], true);
}

/// The MatCap `i` at the eye-space normal `n`: `[diffuse, specular]`.
float[3][2] matcapSample(size_t i, Vec3 n) {
    import math : normalize;
    immutable uv = matcapUv(normalize(n));
    return [sampleBilinear(matcapImage(i, 0), uv[0], uv[1], false),
            sampleBilinear(matcapImage(i, 1), uv[0], uv[1], false)];
}

// ---- GL ----------------------------------------------------------------------

/// Texture units the Reflection arm samples (`litFragSrc`): env, MatCap
/// diffuse, MatCap specular. Read by no other program of the lit pass.
enum int kEnvTextureUnit            = 4;
enum int kMatcapDiffuseTextureUnit  = 5;
enum int kMatcapSpecularTextureUnit = 6;

private uint uploadImage(ref const(LinearImage) img, bool wrapU) {
    version (web) {
    } else {
        import gl_thread_guard : glThreadGuard;
        glThreadGuard("viewportEnv.upload");
    }
    uint tex = 0;
    glGenTextures(1, &tex);
    if (tex == 0 || img.rgba is null) return tex;
    glBindTexture(GL_TEXTURE_2D, tex);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, img.w, img.h, 0,
                 GL_RGBA, GL_FLOAT, img.rgba.ptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapU ? GL_REPEAT : GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    return tex;
}

/// Delete every uploaded Reflection texture and forget it (a later bind
/// uploads again); the lit shader's teardown calls it on the GL thread.
void releaseReflectionTextures() {
    foreach (ref t; envTex_)
        if (t != 0) { glDeleteTextures(1, &t); t = 0; }
    foreach (ref pair; matcapTex_)
        foreach (ref t; pair)
            if (t != 0) { glDeleteTextures(1, &t); t = 0; }
}

/// Bind the textures of `s` to the Reflection units (uploading on first
/// use); the active unit is `GL_TEXTURE0` again on return. An index past
/// the table binds nothing.
void bindReflectionSource(ReflectionSource s) {
    final switch (s.kind) {
        case ReflectionKind.Env:
            if (s.index >= kEnvAssets.length) return;
            if (envTex_[s.index] == 0)
                envTex_[s.index] = uploadImage(envImage(s.index), true);
            glActiveTexture(GL_TEXTURE0 + kEnvTextureUnit);
            glBindTexture(GL_TEXTURE_2D, envTex_[s.index]);
            break;
        case ReflectionKind.MatCap:
            if (s.index >= kMatcapAssets.length) return;
            foreach (layer; 0 .. 2)
                if (matcapTex_[s.index][layer] == 0)
                    matcapTex_[s.index][layer] =
                        uploadImage(matcapImage(s.index, layer), false);
            glActiveTexture(GL_TEXTURE0 + kMatcapDiffuseTextureUnit);
            glBindTexture(GL_TEXTURE_2D, matcapTex_[s.index][0]);
            glActiveTexture(GL_TEXTURE0 + kMatcapSpecularTextureUnit);
            glBindTexture(GL_TEXTURE_2D, matcapTex_[s.index][1]);
            break;
    }
    glActiveTexture(GL_TEXTURE0);
}
