/// IPR panel for vibe3d.
///
/// Owns the IPR ImGui controls and the per-frame orchestration:
/// (1) syncs the persistent `Scene` IR from current vibe3d modeling state
/// (Mesh + View), (2) hands the Scene to a `BackendBridge` which pushes
/// the diff into whatever backend is active, (3) pulls rendered pixels
/// and blits them as an ImGui::Image.
///
/// Panel knows nothing about Cycles or RPR -only about `Scene` +
/// `BackendBridge`. The bridge is what changes when a different backend
/// is selected (Phase 2).
module render.render_mvp;

version (WithRender):

import std.process : environment;
import std.conv    : to;
import std.format  : format;
import std.stdio   : stderr;
import std.math    : tan, atan, PI;
import core.time   : MonoTime, dur, Duration;

import bindbc.opengl;
import ImGui = d_imgui;
import d_imgui.imgui_h;

import mesh : Mesh, SubpatchPreview, Surface;
import view : View;
import math : Vec3;

import render.backend;
import render.scene;
import render.backend_bridge : BackendBridge;

// ---------------------------------------------------------------------------
// Diagnostics -opt-in via VIBE3D_IPR_TRACE=1.
// ---------------------------------------------------------------------------

private __gshared bool g_traceOn;
private __gshared bool g_traceCheckedEnv;
private void trace(string s)
{
    if (!g_traceCheckedEnv) {
        g_traceOn = environment.get("VIBE3D_IPR_TRACE") !is null;
        g_traceCheckedEnv = true;
    }
    if (g_traceOn) { stderr.writeln("[ipr] ", s); stderr.flush(); }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

private enum Phase {
    idle,        // no bridge -show "Start IPR"
    running,     // bridge active, ticking -show "Stop IPR"
    error,       // boot / sync failed -show "Retry"
}

private struct PanelState
{
    bool   panelOpen = true;
    Phase  phase = Phase.idle;
    string errorMsg;

    BackendBridge bridge;
    Scene         scene;

    /// Config the UI is editing. Copied into the bridge on Start and on
    /// any change while running (which triggers a `switchTo` re-init).
    BackendConfig pendingCfg = BackendConfig("cuda");

    /// Backend choice for the next IPR session: "cycles" or "rpr".
    /// Edited via the Backend dropdown. On change, applyCfgChangeIfRunning
    /// does a full `switchTo`. Initialized once from `VIBE3D_IPR_BACKEND`
    /// on the first panel frame so the env override survives the UI takeover.
    string selectedBackend = "cycles";
    bool   selectedBackendInitialized;

    // Scene-side ids (Scene's own counters, NOT backend handles).
    // Scene-side ids. After MG4 the IPR scene may carry N meshes +
    // N materials when the source mesh has multiple surfaces — one
    // bucket per used `mesh.faceMaterial` index. `sceneLightId` stays
    // singular (default scene = one sun).
    ulong[] sceneMeshIds;
    ulong[] sceneMaterialIds;
    ulong   sceneLightId;

    // Framebuffer / blit. Resolution is derived per-frame from the panel
    // content region (see updateFramebufferSizeFromPanel). Defaults are
    // for the first frame before that runs.
    int    fbW = 512;
    int    fbH = 384;
    GLuint glTex;
    int    glTexW;                   // texture dims of the last grabPixels
    int    glTexH;                   // upload — used to letterbox the
                                     // display while a backend resize is
                                     // catching up (Cycles destroy+recreate
                                     // takes ~200ms; would otherwise show
                                     // stretching during panel-drag).
    ulong  lastBlitVersion;          // last `bridge.frameVersion()` we uploaded

    // IPR-opt 3: when bridge.tryBindGLTexture returns true, Cycles writes
    // directly into a PBO on the device side and the backend's tick()
    // blits PBO→glTex. We skip the CPU readback path and flip the image
    // via UV in ImGui.Image (Cycles' PBO write is bottom-up).
    bool   interopActive;
    bool   interopProbed;            // probed once per session; reset on
                                     // teardown / device switch

    // Subpatch (Catmull-Clark) preview, IPR-owned. Independent of the
    // viewport's preview so IPR can render at higher depth without
    // tanking interactive performance.
    SubpatchPreview iprSubpatch;
    int             iprSubdivDepth = 3;

    // Per-frame "input is moving NOW" diff (updates every frame, drives debounce).
    //
    // Two signals are needed because vibe3d's mesh-mutation tracking has two
    // intentional gaps:
    //   - transform tools (Move/Rotate/Scale) write into mesh.vertices in
    //     place WITHOUT bumping mutationVersion (keeps symmetry pair-tables /
    //     falloff caches stable mid-drag; see mesh.d:2991-3000).
    //     Hash of vertex positions catches those.
    //   - topology-only changes (Tab → setSubpatch, face split, ...) bump
    //     mutationVersion but leave positions untouched. Hashing positions
    //     alone would miss those, so we also gate on mutationVersion.
    ulong  lastSeenVertsHash = ulong.max;
    ulong  lastSeenMutationVersion = ulong.max;
    float  lastSeenAzimuth = float.nan;
    float  lastSeenElevation;
    float  lastSeenDistance;
    Vec3   lastSeenFocus;
    int    lastSeenFbW;
    int    lastSeenFbH;

    // "What backend has" diff (updated when we actually sync to bridge)
    ulong  appliedVertsHash = ulong.max;
    ulong  appliedMutationVersion = ulong.max;
    float  appliedAzimuth = float.nan;
    float  appliedElevation;
    float  appliedDistance;
    Vec3   appliedFocus;
    int    appliedFbW;
    int    appliedFbH;

    MonoTime lastInputChange;
}

private __gshared PanelState g;

private enum Duration restartIdleThreshold = dur!"msecs"(50);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

bool isIPRPanelOpen() { return g.panelOpen; }
void setIPRPanelOpen(bool v) { g.panelOpen = v; }

/// Draw the panel + tick the backend if running. Call once per frame
/// after `ImGui.NewFrame`.
void drawIPRPanel(const(Mesh)* meshSnapshot, View viewSnapshot)
{
    if (!g.panelOpen) return;

    // Park the panel in the top-right corner on first appearance so it
    // doesn't blanket the 3D viewport -mouse events over the panel are
    // captured by ImGui (WantCaptureMouse) and never reach the viewport,
    // which would block camera orbit / picking. User can move/resize.
    {
        auto io = ImGui.GetIO();
        const float pad = 12.0f;
        ImGui.SetNextWindowPos(
            ImVec2(io.DisplaySize.x - pad, pad),
            ImGuiCond.FirstUseEver,
            ImVec2(1.0f, 0.0f));
        ImGui.SetNextWindowSize(
            ImVec2(560.0f, 600.0f),
            ImGuiCond.FirstUseEver);
    }

    if (ImGui.Begin("IPR Preview", &g.panelOpen)) {
        // VIBE3D_IPR_AUTOSTART=1 -diagnostic: trigger Start IPR on the
        // first frame the panel renders. Avoids needing a manual click
        // when smoke-testing backend boot from a shell.
        if (g.phase == Phase.idle && !g_iprAutostartChecked) {
            g_iprAutostartChecked = true;
            if (environment.get("VIBE3D_IPR_AUTOSTART") !is null)
                startIPR(meshSnapshot, viewSnapshot);
        }

        // We draw controls first, then take whatever content area is
        // left for the image. That gives us a stable per-frame target
        // resolution; existing inputMoving/needsApply debouncing
        // smooths out continuous resize-drag (only resyncs when stable).
        drawControls(meshSnapshot, viewSnapshot);
        updateFramebufferSizeFromPanel();
        if (g.phase == Phase.running)
            tick(meshSnapshot, viewSnapshot);
        drawImage();
    }
    ImGui.End();
}

private __gshared bool g_iprAutostartChecked;

/// Match `fbW`/`fbH` to the panel's content region (image area), clamped
/// to sane bounds. Aspect ratio left free -IPR fills whatever space is
/// available.
private void updateFramebufferSizeFromPanel()
{
    // Diagnostic: VIBE3D_IPR_FIXED_RES=320 → 320x240,  =512x442 → 512x442
    // (explicit WxH supported). Bypasses panel-derived dynamic sizing.
    if (auto fixed = environment.get("VIBE3D_IPR_FIXED_RES")) {
        import std.conv : to;
        import std.algorithm : findSplit;
        if (auto parts = fixed.findSplit("x")) {
            try {
                g.fbW = parts[0].to!int;
                g.fbH = parts[2].to!int;
                return;
            } catch (Exception) {}
        }
        try {
            const int w = fixed.to!int;
            g.fbW = w;
            g.fbH = w * 3 / 4;
            return;
        } catch (Exception) {}
        g.fbW = 320;
        g.fbH = 240;
        return;
    }
    auto avail = ImGui.GetContentRegionAvail();
    int w = cast(int)avail.x;
    int h = cast(int)avail.y;
    if (w < 64)   w = 64;
    if (h < 48)   h = 48;
    if (w > 2048) w = 2048;
    if (h > 2048) h = 2048;
    // Round down to even so GL formats that need 2-byte alignment are happy.
    w &= ~1;
    h &= ~1;
    g.fbW = w;
    g.fbH = h;
}

/// Tear down. Safe to call multiple times. Run on app exit while the
/// GL context is still alive (for glDeleteTextures).
void shutdownIPR() nothrow
{
    teardownBridge();
    if (g.glTex != 0) {
        try { glDeleteTextures(1, &g.glTex); } catch (Exception) {}
        g.glTex = 0;
    }
    g.phase = Phase.idle;
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

// Flat list of (backend, device) pairs shown in the single IPR dropdown.
// Each entry maps to a concrete `(backendName, cfg.device)` combination
// the bridge knows how to construct. Two gating layers:
//
//   1. `platforms` — host OS filter. NVIDIA-only paths (CUDA, OPTIX,
//      Auto) hide on macOS because Apple dropped CUDA; the "Auto"
//      device-chain on macOS would degenerate to plain CPU anyway.
//      A platform-aware filter avoids shipping dropdown entries that
//      can't possibly succeed on the host — see
//      doc/render_support_matrix.md for the full grid.
//   2. `VIBE3D_RPR_ALLOW_GPU=1` env — opt-in for RPR's HIP / OpenCL
//      device flags. Northstar's GPU init segfaults inside
//      `adl::DeviceHIP::initialize` on NVIDIA hosts (doc/
//      renderer_choice_plan.md Phase 0 status); a dropdown entry that
//      kills the process is worse than no entry. AMD or HIP-on-CUDA
//      hosts can opt in. Recoverable RPR init failures (HybridPro
//      returning RPR_ERROR_INTERNAL on NVIDIA) fall back to CPU via
//      RPRBackend.init's soft-fallback path.
private enum PlatBit : uint {
    LINUX   = 1 << 0,
    OSX     = 1 << 1,
    WIN     = 1 << 2,
    ALL     = LINUX | OSX | WIN,
    NO_OSX  = LINUX | WIN,
}

private struct BackendDeviceOption
{
    string backend;
    string device;
    string label;
    uint   platforms;   // bitmask of PlatBit values
}

private __gshared BackendDeviceOption[] BACKEND_OPTIONS_BASE = [
    BackendDeviceOption("cycles", "cpu",   "Cycles - CPU",                  PlatBit.ALL),
    // CUDA / OPTIX / Auto are NVIDIA-only paths. macOS has no CUDA;
    // hide them so the user doesn't pick a guaranteed-to-fall-back
    // entry. Linux + Windows keep all four Cycles entries.
    BackendDeviceOption("cycles", "cuda",  "Cycles - CUDA",                  PlatBit.NO_OSX),
    BackendDeviceOption("cycles", "optix", "Cycles - OPTIX",                 PlatBit.NO_OSX),
    BackendDeviceOption("cycles", "auto",  "Cycles - Auto (CUDA -> CPU)",    PlatBit.NO_OSX),
    BackendDeviceOption("rpr",    "cpu",   "RPR - CPU",                      PlatBit.ALL),
];

private __gshared BackendDeviceOption[] BACKEND_OPTIONS_GPU = [
    // HIP + OpenCL require AMD / HIP-on-CUDA on Linux or Windows.
    // macOS has neither (Apple dropped OpenCL deprecation + no HIP
    // runtime). The future RPR-Metal entry would live alongside but
    // isn't wired in `rpr_backend.d` yet.
    BackendDeviceOption("rpr", "gpu",    "RPR - GPU (HIP)", PlatBit.NO_OSX),
    BackendDeviceOption("rpr", "opencl", "RPR - OpenCL",     PlatBit.NO_OSX),
];

// Cycles GPU entries gated on a SEPARATE env var
// (VIBE3D_CYCLES_ALLOW_GPU) from the RPR ones — different backends,
// different crash modes. Metal on Apple Silicon is the only entry
// here today; Linux/Windows CUDA + OPTIX are in BASE because they're
// proven stable. Once Metal IPR has burned in across Start/Stop/
// switch/restart cycles, this entry should move to BASE too.
private __gshared BackendDeviceOption[] BACKEND_OPTIONS_GPU_CYCLES = [
    BackendDeviceOption("cycles", "metal", "Cycles - Metal", PlatBit.OSX),
];

private __gshared BackendDeviceOption[] BACKEND_OPTIONS;
private __gshared string[]              BACKEND_OPTION_LABELS;

/// Bitmask matching the host platform at build time. Filter logic
/// reads this once.
private enum uint HOST_PLATFORM = {
    version (linux)        return PlatBit.LINUX;
    else version (OSX)     return PlatBit.OSX;
    else version (Windows) return PlatBit.WIN;
    else                   return PlatBit.LINUX;
}();

/// Build the dropdown's flat option list. Filters entries by host
/// platform (NVIDIA-only Cycles paths hide on macOS, HIP/OpenCL hide
/// universally on macOS), then appends opt-in GPU entries when their
/// gate env var is set:
///   * `VIBE3D_RPR_ALLOW_GPU=1`    — RPR HIP / OpenCL
///   * `VIBE3D_CYCLES_ALLOW_GPU=1` — Cycles Metal
/// Idempotent — only the first call does real work.
private void initBackendOptions()
{
    if (BACKEND_OPTIONS.length > 0) return;

    foreach (ref opt; BACKEND_OPTIONS_BASE)
        if (opt.platforms & HOST_PLATFORM)
            BACKEND_OPTIONS ~= opt;

    bool gateOpen(string envVar)
    {
        auto v = environment.get(envVar);
        return v !is null && v != "0";
    }

    if (gateOpen("VIBE3D_RPR_ALLOW_GPU")) {
        foreach (ref opt; BACKEND_OPTIONS_GPU)
            if (opt.platforms & HOST_PLATFORM)
                BACKEND_OPTIONS ~= opt;
    }

    if (gateOpen("VIBE3D_CYCLES_ALLOW_GPU")) {
        foreach (ref opt; BACKEND_OPTIONS_GPU_CYCLES)
            if (opt.platforms & HOST_PLATFORM)
                BACKEND_OPTIONS ~= opt;
    }

    BACKEND_OPTION_LABELS.length = BACKEND_OPTIONS.length;
    foreach (i, ref opt; BACKEND_OPTIONS)
        BACKEND_OPTION_LABELS[i] = opt.label;
}

/// Resolve which backend the next IPR session should use. UI choice is
/// authoritative; `VIBE3D_IPR_BACKEND` env var seeds the initial value
/// once per process so smoke-test scripts keep working unchanged. When
/// env forces RPR, also reset the device to "cpu" since the default
/// "cuda" only makes sense for Cycles.
private string selectedBackendName()
{
    if (!g.selectedBackendInitialized) {
        auto v = environment.get("VIBE3D_IPR_BACKEND");
        if (v !is null && (v == "rpr" || v == "RPR")) {
            g.selectedBackend   = "rpr";
            g.pendingCfg.device = "cpu";
        } else if (v !is null && (v == "cycles" || v == "Cycles")) {
            g.selectedBackend = "cycles";
        }
        g.selectedBackendInitialized = true;
    }
    return g.selectedBackend;
}

private void drawControls(const(Mesh)* m, View v)
{
    final switch (g.phase) {
        case Phase.idle:
            if (ImGui.Button("Start IPR"))
                startIPR(m, v);
            ImGui.SameLine();
            ImGui.TextDisabled("(progressive, snapshots mesh + view)");
            drawCfgControls();
            break;

        case Phase.running:
            if (ImGui.Button("Stop IPR"))
                stopIPR();
            ImGui.SameLine();
            ImGui.TextDisabled("backend: %s",
                               g.bridge !is null ? g.bridge.activeName() : "—");
            drawCfgControls();
            const float p = g.bridge !is null ? g.bridge.progress() : 0.0f;
            auto overlay = format("%d%%", cast(int)(p * 100.0f));
            ImGui.ProgressBar(p, ImVec2(-1, 0), overlay);
            break;

        case Phase.error:
            if (ImGui.Button("Retry")) {
                teardownBridge();
                g.phase = Phase.idle;
            }
            ImGui.SameLine();
            ImGui.TextColored(ImVec4(1.0f, 0.4f, 0.4f, 1.0f), "%s", g.errorMsg);
            break;
    }
}

/// Unified backend+device dropdown plus a samples slider. Editing the
/// dropdown picks a `(backend, device)` pair and triggers
/// `applyCfgChangeIfRunning` (full `switchTo` if either changed,
/// live `setSamples` otherwise).
private void drawCfgControls()
{
    // Make sure selectedBackend has been seeded from env (idempotent).
    selectedBackendName();

    // Lazy-init the dropdown's flat option list (includes opt-in GPU
    // entries when VIBE3D_RPR_ALLOW_GPU=1 / VIBE3D_CYCLES_ALLOW_GPU=1).
    initBackendOptions();

    int idx = 0;
    foreach (i, ref opt; BACKEND_OPTIONS) {
        if (opt.backend == g.selectedBackend && opt.device == g.pendingCfg.device) {
            idx = cast(int)i;
            break;
        }
    }
    if (ImGui.Combo("Backend", &idx, BACKEND_OPTION_LABELS)) {
        g.selectedBackend   = BACKEND_OPTIONS[idx].backend;
        g.pendingCfg.device = BACKEND_OPTIONS[idx].device;
        applyCfgChangeIfRunning();
    }

    // Samples slider -log scale; applies on slider release.
    int samples = g.pendingCfg.samples;
    ImGui.SliderInt("Samples", &samples, 100, 10_000_000, "%d",
                    ImGuiSliderFlags.Logarithmic);
    g.pendingCfg.samples = samples;
    if (ImGui.IsItemDeactivatedAfterEdit())
        applyCfgChangeIfRunning();
}

/// Apply pending config change to the live bridge -only meaningful in
/// `running` phase (idle picks up cfg on Start). Distinguishes:
///   - samples-only change: live ccl::Session::set_samples, NO destroy
///     and NO scene resync. Avoids tearing down CUDA-GL interop (which
///     occasionally got stuck after rapid Samples-slider commits, with
///     the new session's progress freezing partway through).
///   - device change: full switchTo (destroy+recreate backend, fresh
///     Scene upload, fresh interop bind).
private void applyCfgChangeIfRunning()
{
    if (g.phase != Phase.running) return;
    if (g.bridge is null || g.scene is null) return;

    const bool backendChanged = g.selectedBackend != g.bridge.activeName();
    const bool deviceChanged  = g.pendingCfg.device != g.bridge.config.device;

    // Sample-only edits go through the live setSamples fast path -no
    // teardown, no scene resync. Backend or device changes require a
    // full switchTo (different RPR/Cycles context altogether).
    if (!backendChanged && !deviceChanged) {
        trace("applyCfgChange: samples="
              ~ g.pendingCfg.samples.to!string ~ " (live)");
        if (!g.bridge.setSamples(g.pendingCfg.samples)) {
            // Backend can't do it live -fall back to full switchTo.
            trace("applyCfgChange: setSamples not supported, falling back");
        } else {
            return;
        }
    }

    trace("applyCfgChange: switchTo " ~ g.selectedBackend ~ "/" ~ g.pendingCfg.device
          ~ " samples=" ~ g.pendingCfg.samples.to!string);

    if (!g.bridge.switchTo(selectedBackendName(), g.pendingCfg, g.scene)) {
        setError("switchTo: " ~ g.bridge.lastError());
        return;
    }

    // Clear the texture before the new session starts producing -the
    // previous session may have left bottom-up interop content in
    // there, and the new session (especially if it falls to CPU) takes
    // hundreds of ms to deliver its first sample. Without this the
    // user sees stale flipped content during that gap.
    clearGlTex();
    g.lastBlitVersion = 0;

    g.bridge.resize(g.fbW, g.fbH);

    // Re-record interop intent before the new session boots
    // (see startIPR for rationale).
    g.interopActive = g.bridge.tryBindGLTexture(g.glTex, g.fbW, g.fbH);

    if (!g.bridge.resetAccumulation()) {
        setError("bridge.resetAccumulation: " ~ g.bridge.lastError());
        return;
    }

    trace(g.interopActive ? "switchTo: GL interop bound"
                          : "switchTo: CPU readback path");
}

private void drawImage()
{
    if (g.phase == Phase.running && g.glTex != 0) {
        // CPU path: copy_pixels flips bottom-up → top-down in C shim, so
        // UV = (0,0)..(1,1).
        // Interop path: PBO contains raw Cycles half4, bottom-up -flip
        // vertically via UV = (0,1)..(1,0).
        const bool flip = g.bridge !is null && g.bridge.usingInterop();
        ImVec2 uv0 = flip ? ImVec2(0, 1) : ImVec2(0, 0);
        ImVec2 uv1 = flip ? ImVec2(1, 0) : ImVec2(1, 1);

        // Letterbox the texture inside the panel so a render lagging
        // behind a panel resize doesn't get stretched. Cycles' destroy+
        // recreate path takes ~200 ms; during a fast resize the texture
        // sits at the previous aspect until the new session catches up.
        // Showing the actual texture aspect (with black bars) keeps the
        // image undistorted; once the backend resyncs the new render
        // fills the panel exactly.
        float displayW = cast(float)g.fbW;
        float displayH = cast(float)g.fbH;
        if (g.glTexW > 0 && g.glTexH > 0) {
            const float panelAspect = displayW / displayH;
            const float texAspect   = cast(float)g.glTexW / cast(float)g.glTexH;
            if (texAspect > panelAspect) {
                // Texture wider than panel — fit horizontally.
                displayH = displayW / texAspect;
            } else {
                // Texture taller (or equal) — fit vertically.
                displayW = displayH * texAspect;
            }
        }

        // Center the image inside the panel's content area for letterbox.
        const float padX = (cast(float)g.fbW - displayW) * 0.5f;
        const float padY = (cast(float)g.fbH - displayH) * 0.5f;
        auto cur = ImGui.GetCursorPos();
        ImGui.SetCursorPos(ImVec2(cur.x + padX, cur.y + padY));

        ImGui.Image(cast(ImTextureID) g.glTex,
                    ImVec2(displayW, displayH),
                    uv0, uv1);
    } else {
        ImGui.Dummy(ImVec2(cast(float)g.fbW, cast(float)g.fbH));
    }
}

/// Lazily allocate or resize `g.glTex` so it can hold the current
/// fbW×fbH render. Idempotent -safe to call every frame; only the
/// initial create is non-trivial, glTexImage2D from the CPU or PBO
/// paths handles per-frame contents.
private void ensureGlTex()
{
    if (g.glTex != 0) return;
    glGenTextures(1, &g.glTex);
    glBindTexture(GL_TEXTURE_2D, g.glTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);
}

/// Wipe the IPR texture to opaque black. Used on backend switchTo so
/// the user doesn't see stale (often wrong-orientation) content during
/// the gap between the old session shutting down and the new one
/// producing its first sample.
private void clearGlTex()
{
    if (g.glTex == 0) return;
    glBindTexture(GL_TEXTURE_2D, g.glTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, g.fbW, g.fbH, 0,
                 GL_RGBA, GL_FLOAT, null);
    glBindTexture(GL_TEXTURE_2D, 0);
}

// ---------------------------------------------------------------------------
// Start / Stop
// ---------------------------------------------------------------------------

private void startIPR(const(Mesh)* m, View v)
{
    trace("startIPR");

    teardownBridge();
    g.bridge = new BackendBridge();
    g.scene  = new Scene();

    if (!g.bridge.init(selectedBackendName(), g.pendingCfg)) {
        setError("bridge.init: " ~ g.bridge.lastError());
        return;
    }

    if (!updateSceneFromVibe3D(m, v)) return;
    if (!g.bridge.sync(g.scene)) {
        setError("bridge.sync: " ~ g.bridge.lastError());
        return;
    }
    g.bridge.resize(g.fbW, g.fbH);

    // Record interop intent BEFORE resetAccumulation so the backend can
    // bind the PBO + interop callbacks inside its first bootLiveSession
    // (between cyc_session_create and cyc_session_start) -Cycles' render
    // worker checks should_use_graphics_interop on its first display
    // tick and caches the result; if our callback isn't registered by
    // then it falls back to naive permanently.
    ensureGlTex();
    g.interopActive = g.bridge.tryBindGLTexture(g.glTex, g.fbW, g.fbH);
    g.interopProbed = true;

    if (!g.bridge.resetAccumulation()) {
        setError("bridge.resetAccumulation: " ~ g.bridge.lastError());
        return;
    }
    trace(g.interopActive
        ? "startIPR: GL interop bound (zero-copy)"
        : "startIPR: CPU readback path");

    cacheAppliedState(m, v);
    g.phase = Phase.running;
    trace("startIPR: running on " ~ g.bridge.activeName());
}

private void stopIPR()
{
    trace("stopIPR");
    teardownBridge();
    g.phase = Phase.idle;
}

private void teardownBridge() nothrow
{
    if (g.bridge !is null) {
        try { g.bridge.shutdown(); } catch (Exception) {}
        g.bridge = null;
    }
    g.scene = null;
    g.sceneMeshIds      = null;
    g.sceneMaterialIds  = null;
    g.sceneLightId      = 0;
    g.lastSeenVertsHash       = ulong.max;
    g.lastSeenMutationVersion = ulong.max;
    g.lastSeenAzimuth         = float.nan;
    g.appliedVertsHash        = ulong.max;
    g.appliedMutationVersion  = ulong.max;
    g.appliedAzimuth          = float.nan;
    g.lastBlitVersion         = 0;
    g.interopActive           = false;
    g.interopProbed           = false;
}

// ---------------------------------------------------------------------------
// Per-frame tick
// ---------------------------------------------------------------------------

private void tick(const(Mesh)* m, View v)
{
    if (g.bridge is null) return;

    auto now = MonoTime.currTime;
    v.viewport();   // refresh derived eye/view/proj on the View

    const moving = inputMoving(m, v);
    const apply  = needsApply(m, v);
    const idleMs = (now - g.lastInputChange).total!"msecs";

    // Phase 1: detect input movement (vs lastSeen) → bumps lastInputChange
    if (moving) {
        captureLastSeen(m, v);
        g.lastInputChange = now;
    }

    // DEBUG: state heartbeat (rate-limited to every ~250ms).
    static MonoTime lastStateTrace;
    if ((now - lastStateTrace).total!"msecs" >= 250) {
        import std.format : format;
        trace(format("state: moving=%s apply=%s idleMs=%d "
                     ~ "az=%.3f/%.3f el=%.3f/%.3f dist=%.3f/%.3f "
                     ~ "focus=(%.2f,%.2f,%.2f)/(%.2f,%.2f,%.2f) "
                     ~ "fb=%dx%d/%dx%d  vhash=%x/%x",
                     moving, apply, idleMs,
                     v.azimuth, g.appliedAzimuth,
                     v.elevation, g.appliedElevation,
                     v.distance, g.appliedDistance,
                     v.focus.x, v.focus.y, v.focus.z,
                     g.appliedFocus.x, g.appliedFocus.y, g.appliedFocus.z,
                     g.fbW, g.fbH, g.appliedFbW, g.appliedFbH,
                     vertsHash(m), g.appliedVertsHash));
        lastStateTrace = now;
    }

    // Phase 2: if backend is behind AND input has been stable, restart
    if (apply && (now - g.lastInputChange) >= restartIdleThreshold) {
        if (!updateSceneFromVibe3D(m, v)) return;
        if (!g.bridge.sync(g.scene)) {
            setError("bridge.sync: " ~ g.bridge.lastError());
            return;
        }
        g.bridge.resize(g.fbW, g.fbH);
        // resetAccumulation may return false on soft fail (scene mutex
        // held by worker mid-update). Don't cache applied state -the
        // next tick will re-trigger and try_lock should succeed then.
        // Hard errors flip the phase to error via setError on the
        // backend side; we'd see that on subsequent tick().
        if (g.bridge.resetAccumulation()) {
            cacheAppliedState(m, v);
            trace("tick: synced scene + reset");
        } else {
            trace("tick: try_lock missed, retrying next tick");
        }
    }

    // Backend.tick() handles its own interop-side PBO→glTex blit
    // (no-op on CPU path or fallback).  Always poll grabPixels —
    // it returns false when interop is providing pixels directly.
    g.bridge.tick();

    float[] buf;
    int rw, rh;
    bool grabbed = g.bridge.grabPixels(buf, rw, rh);
    if (grabbed) {
        uploadFramebufferToGL(buf, rw, rh);
        g.lastBlitVersion = g.bridge.frameVersion();
    } else if (g.bridge.usingInterop()) {
        // Interop is live; tick() already wrote into glTex.
        g.lastBlitVersion = g.bridge.frameVersion();
        grabbed = g.lastBlitVersion != 0;
    }

    // DEBUG: grab/blit heartbeat (rate-limited to every ~500ms).
    static MonoTime lastGrabTrace;
    if ((now - lastGrabTrace).total!"msecs" >= 500) {
        import std.format : format;
        trace(format("grab: ok=%s ver=%d progress=%.2f",
                     grabbed, g.bridge.frameVersion(), g.bridge.progress()));
        lastGrabTrace = now;
    }
}

/// Cheap FNV-1a-flavoured fingerprint over the mesh's vertex positions.
/// O(N) per frame but the inner loop is 3 XOR+rotate per vertex -well
/// under a millisecond for cages up to ~50k verts. Catches mid-drag
/// position changes that mesh.mutationVersion doesn't.
private ulong vertsHash(const(Mesh)* m)
{
    ulong h = m.vertices.length;
    foreach (ref const vert; m.vertices) {
        h ^= *cast(const(uint)*)&vert.x;  h = (h << 7) | (h >> 57);
        h ^= *cast(const(uint)*)&vert.y;  h = (h << 7) | (h >> 57);
        h ^= *cast(const(uint)*)&vert.z;  h = (h << 7) | (h >> 57);
    }
    return h;
}

private bool inputMoving(const(Mesh)* m, View v)
{
    return vertsHash(m)     != g.lastSeenVertsHash ||
           m.mutationVersion != g.lastSeenMutationVersion ||
           v.azimuth   != g.lastSeenAzimuth   ||
           v.elevation != g.lastSeenElevation ||
           v.distance  != g.lastSeenDistance  ||
           v.focus     != g.lastSeenFocus     ||
           g.fbW != g.lastSeenFbW || g.fbH != g.lastSeenFbH;
}

private bool needsApply(const(Mesh)* m, View v)
{
    return vertsHash(m)     != g.appliedVertsHash ||
           m.mutationVersion != g.appliedMutationVersion ||
           v.azimuth   != g.appliedAzimuth   ||
           v.elevation != g.appliedElevation ||
           v.distance  != g.appliedDistance  ||
           v.focus     != g.appliedFocus     ||
           g.fbW != g.appliedFbW || g.fbH != g.appliedFbH;
}

private void captureLastSeen(const(Mesh)* m, View v)
{
    g.lastSeenVertsHash       = vertsHash(m);
    g.lastSeenMutationVersion = m.mutationVersion;
    g.lastSeenAzimuth   = v.azimuth;
    g.lastSeenElevation = v.elevation;
    g.lastSeenDistance  = v.distance;
    g.lastSeenFocus     = v.focus;
    g.lastSeenFbW       = g.fbW;
    g.lastSeenFbH       = g.fbH;
}

private void cacheAppliedState(const(Mesh)* m, View v)
{
    g.appliedVertsHash       = vertsHash(m);
    g.appliedMutationVersion = m.mutationVersion;
    g.appliedAzimuth   = v.azimuth;
    g.appliedElevation = v.elevation;
    g.appliedDistance  = v.distance;
    g.appliedFocus     = v.focus;
    g.appliedFbW       = g.fbW;
    g.appliedFbH       = g.fbH;

    // Mirror into lastSeen so the next tick doesn't see a stale diff
    // immediately after we just pushed.
    captureLastSeen(m, v);
    g.lastInputChange = MonoTime.currTime;
}

// ---------------------------------------------------------------------------
// Scene update -vibe3d state → Scene IR diff
// ---------------------------------------------------------------------------

/// Patch the persistent Scene from current vibe3d modeling state.
/// On first call (empty Scene), seeds mesh-buckets + light + camera +
/// environment. On subsequent calls, drops + re-adds the mesh-buckets
/// whenever geometry/surfaces change, and always updates the camera
/// (cheap; upstream debounce gates on stable input).
///
/// MG4 — Material Groups multi-material split. The source mesh is
/// partitioned into one (CompiledMaterial, sub-mesh) bucket per used
/// `faceMaterial` index. Each bucket emits the FULL `xyz` array plus
/// the subset of triangles whose owning face indexes into that
/// surface, with `assignMaterial` wiring them together. Backends see
/// N mesh handles + N material handles instead of one of each — but
/// the existing RenderBackend interface stays unchanged.
private bool updateSceneFromVibe3D(const(Mesh)* m, View v)
{
    const bool firstTime   = (g.sceneLightId == 0);
    const bool meshChanged = !firstTime
        && (vertsHash(m)     != g.appliedVertsHash
         || m.mutationVersion != g.appliedMutationVersion);

    // Pick the source mesh -subdivided when any face is flagged subpatch,
    // raw cage otherwise. IPR-owned SubpatchPreview rebuilds lazily; it
    // returns early if cage version + depth match its cached state.
    const(Mesh)* sourceMesh = m;
    bool anySubpatch = m.hasAnySubpatch();
    if (anySubpatch) {
        g.iprSubpatch.rebuildIfStale(*m, g.iprSubdivDepth, null);
        sourceMesh = &g.iprSubpatch.mesh;
    }

    if (firstTime) {
        // Sun light ~5 units up.
        LightDesc ld;
        ld.kind      = LightDesc.Kind.Sun;
        ld.transform = [
            1, 0, 0, 0,
            0, 1, 0, 5,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ];
        ld.color     = Vec3(1, 1, 1);
        ld.intensity = 3.0f;
        ld.sunAngle  = 0.009f;
        g.sceneLightId = g.scene.addLight(ld);

        if (!rebuildSceneMaterialBuckets(sourceMesh)) return false;

        // Environment -default Solid (black). Backend may apply own default
        // (Cycles uses grey).
        EnvDesc ed;
        ed.kind  = EnvDesc.Kind.Solid;
        ed.color = Vec3(0);
        g.scene.setEnvironment(ed);
    } else if (meshChanged) {
        if (!rebuildSceneMaterialBuckets(sourceMesh)) return false;
    }

    // Camera -always patched when this function runs (we only run after
    // debounce caught a real change anyway).
    CameraDesc cd;
    cd.kind   = CameraDesc.Kind.Perspective;
    cd.eye    = v.eye;
    cd.target = v.focus;
    cd.up     = Vec3(0, 1, 0);
    cd.aspect              = cast(float)g.fbW / cast(float)g.fbH;
    cd.fovRadiansVertical  = 45.0f * cast(float)(PI / 180.0);
    cd.nearClip = 0.001f;
    cd.farClip  = 100.0f;
    g.scene.setCamera(cd);

    return true;
}

/// MG4 — split the source mesh into N (CompiledMaterial, sub-mesh)
/// buckets keyed by `mesh.faceMaterial[fi]`, removing any prior
/// scene-side mesh/material handles. Each bucket emits the full
/// vertex array (shared, lets us avoid remapping) and the subset of
/// triangles whose owning face indexes that surface. A bucket with
/// zero matching triangles is skipped — RPR rejects empty meshes.
private bool rebuildSceneMaterialBuckets(const(Mesh)* sourceMesh)
{
    if (sourceMesh is null || sourceMesh.vertices.length == 0) {
        setError("rebuildSceneMaterialBuckets: empty mesh");
        return false;
    }

    // Drop any existing buckets so backend sees a fresh upload chain.
    foreach (id; g.sceneMeshIds)     g.scene.removeMesh(id);
    foreach (id; g.sceneMaterialIds) g.scene.removeMaterial(id);
    g.sceneMeshIds      = null;
    g.sceneMaterialIds  = null;

    // Shared vertex array — same xyz uploaded for every bucket so we
    // don't have to remap indices. Wasteful (N copies on the backend)
    // but trivial and correct; a future MG-perf pass can introduce
    // per-bucket vert subsetting if a profile shows it matters.
    float[] xyz;
    xyz.length = sourceMesh.vertices.length * 3;
    foreach (i, ref vert; sourceMesh.vertices) {
        xyz[i * 3 + 0] = vert.x;
        xyz[i * 3 + 1] = vert.y;
        xyz[i * 3 + 2] = vert.z;
    }

    // Bucket face indices by surface index, preserving first-seen
    // order so the bucket list is stable across rebuilds (helps the
    // bridge avoid spurious destroy+upload churn on Cycles).
    size_t[]            usedMatIdx;
    size_t[][size_t]    facesByMat;
    foreach (fi, face; sourceMesh.faces) {
        if (face.length < 3) continue;
        const uint mi = (fi < sourceMesh.faceMaterial.length)
            ? sourceMesh.faceMaterial[fi] : 0u;
        if (mi !in facesByMat) usedMatIdx ~= mi;
        facesByMat[mi] ~= fi;
    }

    if (usedMatIdx.length == 0) {
        setError("rebuildSceneMaterialBuckets: no faces");
        return false;
    }

    // One CompiledMaterial + one Scene mesh per used surface.
    foreach (mi; usedMatIdx) {
        Surface s;
        if (mi < sourceMesh.surfaces.length) s = sourceMesh.surfaces[mi];
        const ulong sceneMatId = g.scene.addMaterial(surfaceToCompiledMaterial(s));

        // Fan-triangulate only this bucket's faces.
        size_t total = 0;
        foreach (fi; facesByMat[mi])
            total += sourceMesh.faces[fi].length - 2;
        int[] tris;
        tris.length = total * 3;
        size_t ti = 0;
        foreach (fi; facesByMat[mi]) {
            auto face = sourceMesh.faces[fi];
            for (size_t i = 1; i + 1 < face.length; i++) {
                tris[ti++] = cast(int) face[0];
                tris[ti++] = cast(int) face[i];
                tris[ti++] = cast(int) face[i + 1];
            }
        }

        const ulong sceneMeshId = g.scene.addMesh(xyz, /*normals*/[], /*uv*/[], tris);
        g.scene.assignMaterial(sceneMeshId, sceneMatId);
        g.sceneMeshIds     ~= sceneMeshId;
        g.sceneMaterialIds ~= sceneMatId;
    }
    return true;
}

/// MG4 — Surface → CompiledMaterial mapping. Diffuse-only for now:
/// `glossiness` modulates both diffuse and specular roughness equally,
/// `opacity` drives transmission as its complement. Specular amount
/// and metallic are captured upstream but not yet routed into the
/// Principled BRDF — that lands when ShaderTree IR (Phase 3) compiles
/// directly to UberV2 / Cycles Principled.
private CompiledMaterial surfaceToCompiledMaterial(in Surface s)
{
    import std.algorithm : clamp;
    CompiledMaterial cm;
    const float rough     = 1.0f - clamp(s.glossiness, 0.0f, 1.0f);
    cm.baseColor          = s.baseColor;
    cm.diffuseRoughness   = rough;
    cm.specularRoughness  = rough;
    cm.metallic           = 0.0f;
    cm.specularIOR        = 1.45f;
    cm.opacity            = s.opacity;
    cm.transmission       = 1.0f - s.opacity;
    return cm;
}

// ---------------------------------------------------------------------------
// GL framebuffer blit
// ---------------------------------------------------------------------------

private void uploadFramebufferToGL(in float[] pixels, int w, int h)
{
    if (g.glTex == 0) {
        glGenTextures(1, &g.glTex);
        glBindTexture(GL_TEXTURE_2D, g.glTex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    } else {
        glBindTexture(GL_TEXTURE_2D, g.glTex);
    }
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, w, h, 0, GL_RGBA, GL_FLOAT, pixels.ptr);
    glBindTexture(GL_TEXTURE_2D, 0);
    g.glTexW = w;
    g.glTexH = h;
}

// ---------------------------------------------------------------------------
// Error helper
// ---------------------------------------------------------------------------

private void setError(string msg)
{
    g.errorMsg = msg;
    g.phase = Phase.error;
    teardownBridge();
    trace("ERROR: " ~ msg);
}
