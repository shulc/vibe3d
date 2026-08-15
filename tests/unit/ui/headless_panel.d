// A Tool-Properties panel, submitted and DRIVEN with no window, no GL context
// and no display server (task 0870).
//
// WHY THIS EXISTS
//
// Until this module there was no automated path that could touch an ImGui
// widget at all, so every code path whose input BEGINS in a widget was
// unpinned. Task 0801 measured what that costs: a panel whose slider wrote a
// value the apply never read shipped for two months with both lanes green, and
// was found by a human driving a real binary under Xvfb with xdotool. The two
// lines that fixed it could not be pinned by the lane that wrote them.
//
// The three doors that were shut, and why each stays shut:
//   - `/api/play-events` synthesises SDL events with no `windowID`, and the
//     ImGui SDL2 backend resolves `windowID` to a viewport as its FIRST act on
//     every mouse event, dropping unknown ones. Adding one would hand ImGui the
//     cursor during every existing replay, changing `io.WantCaptureMouse` — and
//     with it viewport picking — under ~130 tests that never asked for it.
//   - `--test` drops real keyboard/mouse in the `SDL_PollEvent` loop, so an
//     xdotool pointer never reaches ImGui in the first place.
//   - `/api/toolprops/ids` records which rows exist, not what typing into one
//     does.
//
// WHAT THIS DOES INSTEAD
//
// Dear ImGui is platform-agnostic: a context, a display size and an input
// queue are the whole contract, and the backends exist only to fill them from
// SDL and to draw the vertex buffers afterwards. This harness fills them
// directly. `igRender()` still runs (so the layout, clipping and ID stack are
// the real ones); nothing consumes the draw data. The widget code under test is
// the SHIPPED code, submitted exactly as `app.d` submits it — no test-only seam
// is added to the panel, which is the whole point: a seam production does not
// use tests itself.
//
// ROW ADDRESSING
//
// The 2026-06 objection to a widget test (`tests/test_property_panel_drag.d`)
// was that the row's position "drifts with the panel's docked width, font
// metrics, and the active tool's widget order", so a pixel constant would rot.
// It would. So there is no pixel constant here: the harness reads the layout
// cursor (`GetCursorScreenPos`) at the exact point the panel body begins and
// the row pitch (`GetFrameHeightWithSpacing`) from ImGui itself, on the frame
// before the gesture. Rows are addressed by INDEX in submission order. Change
// the font, the window width or the style and the numbers move together; the
// index does not.
//
// The predicted centre was verified against `GetItemRectMin/Max` of three
// consecutive `DragFloat` rows before this was written: exact, not approximate.
// `pressRow`/`editRow` additionally assert that SOME item went active, so a
// gesture that lands between rows fails loudly instead of asserting nothing.
module tests.unit.ui.headless_panel;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ── cimgui entry points the D shim does not re-export ────────────────────────
//
// The shim (`d_imgui/package.d`) wraps the drawing API vibe3d calls; the input
// QUEUE is normally filled by the SDL2 backend, so it has no D wrapper. These
// are the same `ImGuiIO::AddXxxEvent` methods that backend calls, declared
// against the static cimgui archive the editor already links.
private extern (C) nothrow @nogc {
    void ImGuiIO_AddMousePosEvent(void* self, float x, float y);
    void ImGuiIO_AddMouseButtonEvent(void* self, int button, bool down);
    void ImGuiIO_AddInputCharacter(void* self, uint c);
    void ImGuiIO_AddFocusEvent(void* self, bool focused);
}

// Key codes not present in the shim's partial `ImGuiKey` enum. Values are
// cimgui 1.92.8's (`extern/cimgui/cimgui.h`); `AddKeyEvent` takes the enum, so
// they are cast at the call site.
private enum int KEY_LEFT_CTRL = 527;   // ImGuiKey_LeftCtrl
private enum int MOD_CTRL      = 1 << 12; // ImGuiMod_Ctrl — `io.KeyCtrl` is
                                          // derived from the MOD key's data,
                                          // not from LeftCtrl, so a backend
                                          // must send both. Sending only
                                          // LeftCtrl leaves KeyCtrl false and
                                          // ctrl+click never enters text mode.

// `ImGuiIO`'s first three fields, in C declaration order (cimgui.h):
//   int ConfigFlags; int BackendFlags; ImVec2 DisplaySize; ...
// The shim exposes ConfigFlags and DisplaySize but not BackendFlags, and there
// is no setter for DisplaySize at all — a headless caller has to write them.
// `openPanel` writes through this view and then reads BOTH bracketing fields
// back through the shim's own accessors, so a layout change upstream fails the
// assertion instead of corrupting the struct silently.
private struct IoHeader {
    int      configFlags;
    int      backendFlags;
    float    displayW;
    float    displayH;
}

private enum int BACKEND_RENDERER_HAS_TEXTURES = 1 << 4;  // ImGuiBackendFlags_
// Without it, 1.92's font atlas takes the legacy path, which requires the
// renderer backend to have uploaded a texture and dereferences null when it
// has not. Measured: omitting this flag segfaults on the first `NewFrame`.

/// A live headless ImGui context wrapped around ONE panel body.
///
/// `body_` is submitted between `Begin`/`End` on every frame the harness runs,
/// which is what makes a multi-frame gesture (press → type → commit) address
/// the same widget id each time, exactly as the editor's main loop does.
struct HeadlessPanel {
    private void delegate() body_;
    private string   windowName;
    private void*    io;
    private ImGuiContext* ctx;
    private ImVec2   origin;      // layout cursor where the body begins
    private float    stride = 0;  // row pitch  (frame height + item spacing)
    private float    rowH   = 0;  // row height (frame height)
    private bool     anyActive;   // did SOME item hold ActiveId this frame

    /// Frames run so far — the harness's cost in the one unit that matters.
    int frames;

    @disable this(this);

    /// Submit one frame: NewFrame → Begin → body → End → Render.
    void frame() {
        ImGui.NewFrame();
        ImGui.SetNextWindowPos(ImVec2(0, 0));
        ImGui.SetNextWindowSize(ImVec2(360, 640));
        ImGui.Begin(windowName);
        origin = ImGui.GetCursorScreenPos();
        rowH   = ImGui.GetFrameHeightWithSpacing() - ImGui.GetStyle().ItemSpacing.y;
        stride = ImGui.GetFrameHeightWithSpacing();
        body_();
        anyActive = ImGui.IsAnyItemActive();
        ImGui.End();
        ImGui.Render();
        frames++;
    }

    /// Screen point at the centre of row `row` (0-based, submission order),
    /// inside the widget itself — the labels sit to the RIGHT of the widget in
    /// this panel, so a small inset from the left edge is always on the widget.
    ImVec2 rowPoint(size_t row) const {
        assert(stride > 0, "rowPoint() before the first frame()");
        return ImVec2(origin.x + 6.0f,
                      origin.y + cast(float) row * stride + rowH * 0.5f);
    }

    /// Move the pointer onto a row and settle one frame (ImGui needs the
    /// position a frame before the click to compute `HoveredId`).
    void hoverRow(size_t row) {
        auto p = rowPoint(row);
        ImGuiIO_AddMousePosEvent(io, p.x, p.y);
        frame();
    }

    /// Press and hold the left button on a row. Asserts the press landed on an
    /// item: a gesture that hits the gap between rows must fail here, not
    /// silently assert nothing later.
    void pressRow(size_t row) {
        hoverRow(row);
        ImGuiIO_AddMouseButtonEvent(io, 0, true);
        frame();
        assert(anyActive,
               "pressRow: no item took ActiveId — the point missed every widget");
    }

    /// Release the left button.
    void release() {
        ImGuiIO_AddMouseButtonEvent(io, 0, false);
        frame();
    }

    /// Drag a row horizontally by `dx` screen pixels, in `steps` motions.
    /// A `DragFloat` accumulates `MouseDelta.x * v_speed`, so the value moves
    /// by `dx * v_speed` regardless of how the pixels are split.
    void dragRow(size_t row, float dx, int steps = 2) {
        auto p = rowPoint(row);
        pressRow(row);
        foreach (i; 1 .. steps + 1) {
            ImGuiIO_AddMousePosEvent(io, p.x + dx * i / steps, p.y);
            frame();
        }
        release();
    }

    /// The full keyboard edit a user performs on a numeric row: ctrl+click to
    /// enter text mode, type an absolute value, commit with Enter. This is the
    /// gesture task 0801 was reproduced by hand with (xdotool, under Xvfb).
    ///
    /// Ctrl is pressed on its own frame BEFORE the button: ImGui's input queue
    /// trickles mouse and key events separately, so a modifier submitted in the
    /// same batch as the click is not yet down when the click is processed —
    /// and `DragFloat` reads `KeyCtrl` at click time to decide text mode.
    void editRow(size_t row, string text) {
        hoverRow(row);
        keyDown(KEY_LEFT_CTRL);
        keyDown(MOD_CTRL);
        frame();
        ImGuiIO_AddMouseButtonEvent(io, 0, true);
        frame();
        assert(anyActive,
               "editRow: no item took ActiveId — the point missed every widget");
        ImGuiIO_AddMouseButtonEvent(io, 0, false);
        keyUp(KEY_LEFT_CTRL);
        keyUp(MOD_CTRL);
        frame();
        // Ctrl+click pre-selects the field's whole text, so typing replaces it.
        foreach (ch; text) ImGuiIO_AddInputCharacter(io, cast(uint) ch);
        frame();
        keyDown(cast(int) ImGuiKey.Enter);
        frame();
        keyUp(cast(int) ImGuiKey.Enter);
        frame();
        // One idle frame so the panel sees IsItemDeactivatedAfterEdit and,
        // where it re-seeds its display field from the truth, does so.
        frame();
    }

    private void keyDown(int key) { ImGui.GetIO().AddKeyEvent(cast(ImGuiKey) key, true); }
    private void keyUp(int key)   { ImGui.GetIO().AddKeyEvent(cast(ImGuiKey) key, false); }

    /// Tear the context down. Safe to call twice.
    void close() {
        if (ctx !is null) { ImGui.DestroyContext(ctx); ctx = null; }
    }
}

/// Build a headless context around `body_` and leave it ready for `frame()`.
/// Call `close()` (or `scope (exit) ui.close();`) when done — the context is a
/// process-global in ImGui, and unittest modules share one process.
HeadlessPanel openPanel(void delegate() body_,
                        string windowName = "Tool Properties",
                        float displayW = 1280.0f, float displayH = 720.0f) {
    HeadlessPanel p;
    p.body_ = body_;
    p.windowName = windowName;
    p.ctx = ImGui.CreateContext();
    p.io  = cast(void*) &ImGui.GetIO();

    auto hdr = cast(IoHeader*) p.io;
    hdr.displayW = displayW;
    hdr.displayH = displayH;
    hdr.backendFlags |= BACKEND_RENDERER_HAS_TEXTURES;

    // Bracket the unchecked write. BackendFlags has no accessor, but the fields
    // on either side of it do — so write through THIS view and read back through
    // the shim's own accessor, for both. A layout change upstream then fails
    // here, loudly, instead of corrupting the struct silently.
    //
    // The ConfigFlags probe uses a bit no ImGuiConfigFlags value occupies, and
    // is cleared again immediately: comparing the two reads without writing one
    // of them would pass on a moved layout whenever the field that took offset 0
    // also happened to be zero — which, at context creation, most of them are.
    enum int LAYOUT_PROBE_BIT = 1 << 30;
    hdr.configFlags |= LAYOUT_PROBE_BIT;
    assert((ImGui.GetIO().ConfigFlags & LAYOUT_PROBE_BIT) != 0,
           "ImGuiIO layout moved: ConfigFlags is no longer the first field");
    hdr.configFlags &= ~LAYOUT_PROBE_BIT;
    assert(ImGui.GetIO().DisplaySize.x == displayW
        && ImGui.GetIO().DisplaySize.y == displayH,
           "ImGuiIO layout moved: DisplaySize is no longer at offset 8");

    ImGui.GetIO().IniFilename = null;   // never touch imgui.ini from a test
    ImGui.StyleColorsDark();
    ImGuiIO_AddFocusEvent(p.io, true);
    return p;
}
