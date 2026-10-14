/// Backend-agnostic interface for IPR-capable renderers (Cycles, RPR, ...).
///
/// One implementation per backend lives in `source/render/<name>_backend.d`.
/// Host code (IPR panel) consumes only this interface — backend swap is
/// transparent. The IPR display API is the "final" dual-paradigm form
/// (see doc/shader_framework_plan.md → "IPR display API"):
///   - `tryBindGLTexture` for push backends with GPU interop
///   - `grabPixels` + `frameVersion` for pull / CPU fallback
///   - `tick` for engines that need a per-frame nudge (RPR)
///
/// In Phase 1b implementations may return `false` from `tryBindGLTexture`
/// unconditionally — the panel falls back to grabPixels + glTexImage2D.
/// Interop becomes useful in IPR-opt 3/4.
module render.backend;

version (WithRender):

import math : Vec3;

// ---------------------------------------------------------------------------
// Opaque handles. Backend-owned; host stores and refers back to them but
// never dereferences. Wrapped in structs so different ID kinds don't
// implicitly convert.
// ---------------------------------------------------------------------------

struct MeshId     { ulong id; }
struct MaterialId { ulong id; }
struct LightId    { ulong id; }

// ---------------------------------------------------------------------------
// Scene primitives — intersection of Cycles ∩ RPR (see plan doc).
// ---------------------------------------------------------------------------

struct LightDesc
{
    enum Kind : ubyte { Point, Sun, Spot, Area, Mesh, Environment }
    Kind      kind          = Kind.Sun;
    float[16] transform     = [1,0,0,0,  0,1,0,0,  0,0,1,0,  0,0,0,1];
    Vec3      color         = Vec3(1);
    float     intensity     = 1.0f;

    // Spot only
    float     spotAngle     = 0.0f;
    float     spotBlend     = 0.0f;

    // Area only
    float     areaSizeX     = 1.0f;
    float     areaSizeY     = 1.0f;

    // Sun only — apparent angular size (radians). Real sun ≈ 0.009.
    float     sunAngle      = 0.009f;
}

struct CameraDesc
{
    enum Kind : ubyte { Perspective, Orthographic }
    Kind  kind                = Kind.Perspective;
    Vec3  eye                 = Vec3(0, 0, 3);
    Vec3  target              = Vec3(0, 0, 0);
    Vec3  up                  = Vec3(0, 1, 0);
    float fovRadiansVertical  = 0.785398f;   // ≈ 45°. Both Cycles (whose
                                              // `fov` socket is vertical FOV)
                                              // and RPR (which derives focal
                                              // length from this + sensorH)
                                              // consume the same value.
    float aspect              = 1.0f;
    float nearClip            = 0.001f;
    float farClip             = 100.0f;

    // Depth-of-field (zero aperture = pinhole)
    float dofFocalDistance    = 0.0f;
    float dofAperture         = 0.0f;
}

struct EnvDesc
{
    enum Kind : ubyte { Solid, HDRI }
    Kind   kind     = Kind.Solid;
    Vec3   color    = Vec3(0);   // black sky by default
    string hdriPath;             // for HDRI kind
}

/// Compiled material — for Phase 1b just a Principled subset.
/// Grows in Phase 3 when ShaderTree IR compilation kicks in; backend-specific
/// payload (UberV2 node graph / Cycles shader graph) is built inside the
/// backend from this descriptor.
struct CompiledMaterial
{
    Vec3  baseColor          = Vec3(0.7, 0.7, 0.7);   /* not Vec3(0.7) — D
        positional initializer fills only x and leaves y/z=0 → pure red */
    float diffuseRoughness   = 0.0f;
    float specularRoughness  = 0.5f;
    float metallic           = 0.0f;
    float specularIOR        = 1.45f;
    Vec3  emissionColor      = Vec3(0);
    float emissionStrength   = 0.0f;
    float transmission       = 0.0f;
    float refractionIOR      = 1.45f;
    float opacity            = 1.0f;

    string sourceHash;   // for change detection on hot-swap rebuild
}

// ---------------------------------------------------------------------------
// Capabilities & config
// ---------------------------------------------------------------------------

struct BackendCaps
{
    bool supportsGLInterop;   // tryBindGLTexture can return true
    bool supportsOSL;         // Cycles only
    bool supportsMDL;         // RPR only
    bool supportsAreaLight;
    bool supportsSunLight;
    bool supportsHDRI;
    int  maxLights;
}

struct BackendConfig
{
    /// "cpu" | "cuda" | "optix" | "hip" | "metal" | "auto"
    /// "auto" — try OPTIX → CUDA → CPU fallback chain.
    string device      = "cpu";
    int    deviceIndex = 0;

    /// Effective sample cap — backends may use lower for IPR.
    /// Should be high enough that progress doesn't saturate to 1.0
    /// (Cycles interactive quirk — see render_mvp.d notes).
    int    samples     = 1_000_000;

    bool   useDenoiser = false;
}

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------

interface RenderBackend
{
    // --- Identity ---
    string      name();          // "cycles" | "rpr"
    BackendCaps caps();
    string      lastError();     // human-readable, set by any failed call

    // --- Lifecycle ---
    bool init(in BackendConfig cfg);
    void shutdown();

    // --- Scene (incremental) ---
    MeshId uploadTriMesh(in float[] xyz, in float[] normals,
                          in float[] uv, in int[] tris);
    void   destroyMesh(MeshId);

    MaterialId uploadMaterial(in CompiledMaterial cm);
    void       assignMaterial(MeshId, MaterialId);

    LightId    uploadLight(in LightDesc ld);
    void       destroyLight(LightId);

    void setEnvironment(in EnvDesc ed);
    void setCamera(in CameraDesc cd);

    // --- IPR display (see doc/shader_framework_plan.md) ---
    void  resize(int w, int h);

    /// Push pending scene mutations into the backend and restart sample
    /// accumulation. Returns:
    ///   true  — reset succeeded (or worker thread will pick it up
    ///           — Cycles' async semantics).
    ///   false — soft fail (e.g. scene mutex held by worker — caller
    ///           should retry next tick) OR hard fail (`lastError`
    ///           populated). Caller distinguishes by checking the
    ///           backend's error state if needed.
    bool  resetAccumulation();

    /// Per-frame nudge. RPR runs one sample here. Cycles' async worker
    /// renders independently — `tick` is a no-op.
    void  tick();

    /// Opt-in: backend writes directly into this GL texture (zero-copy).
    /// Returns true if the binding was accepted. In Phase 1b all
    /// implementations may return false; host falls back to grabPixels.
    bool  tryBindGLTexture(uint glTex, int w, int h);

    /// True when the backend is *actively* writing to the texture bound
    /// via `tryBindGLTexture` (vs accepting the bind but silently
    /// rendering via CPU readback). Host uses this to pick the
    /// rendering convention (e.g. UV flip for bottom-up GPU writes)
    /// and to skip CPU readback when the backend already updated the
    /// texture itself. False when interop wasn't bound or fell back.
    bool  usingInterop();

    /// Pull fallback. Returns false if there's nothing new since last
    /// call (host can skip its upload).
    bool  grabPixels(ref float[] out_, out int w, out int h);

    /// Monotonic counter — bumped on every backend-side progress event
    /// that produces visible pixel change. Host compares to its cached
    /// value to detect when to re-blit.
    ulong frameVersion();

    /// 0..1 progress for UI indicator (RPR samples / cap; Cycles is
    /// progressive so this is approximate).
    float progress();

    /// Live-session samples adjustment (no scene/render restart).
    /// Returns false if the backend can't apply it without a full
    /// switchTo (e.g. RPR's UberV2 doesn't expose this).
    bool  setSamples(int samples);
}
