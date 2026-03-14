/**
 * Dear ImGui — SDL2 platform backend for d_imgui.
 * Handles window/input events and per-frame state update.
 */
module imgui_impl_sdl2;


nothrow @nogc:

import ImGui = d_imgui;
import d_imgui.imgui_h;
import bindbc.sdl;

// -------------------------------------------------------------------------
// Internal state
// -------------------------------------------------------------------------

private struct Data {
    SDL_Window*  window;
    SDL_Cursor*[ImGuiMouseCursor.COUNT] mouseCursors;
    ulong        lastPerfCounter;
    ulong        perfFrequency;
}

private Data* bd;

// -------------------------------------------------------------------------
// Init / Shutdown
// -------------------------------------------------------------------------

bool ImGui_ImplSDL2_Init(SDL_Window* window) {
    ImGuiIO* io = &ImGui.GetIO();
    assert(io.BackendPlatformUserData == null,
           "Already initialized a platform backend!");

    bd = cast(Data*) ImGui.MemAlloc(Data.sizeof);
    *bd = Data.init;
    io.BackendPlatformUserData = bd;
    io.BackendPlatformName     = "imgui_impl_sdl2";

    bd.window        = window;
    bd.perfFrequency = SDL_GetPerformanceFrequency();
    bd.lastPerfCounter = SDL_GetPerformanceCounter();

    // Clipboard callbacks
    io.GetClipboardTextFn = &getClipboardText;
    io.SetClipboardTextFn = &setClipboardText;
    io.ClipboardUserData  = window;

    // Create SDL cursors
    bd.mouseCursors[ImGuiMouseCursor.Arrow]      = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_ARROW);
    bd.mouseCursors[ImGuiMouseCursor.TextInput]  = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_IBEAM);
    bd.mouseCursors[ImGuiMouseCursor.ResizeAll]  = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZEALL);
    bd.mouseCursors[ImGuiMouseCursor.ResizeNS]   = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENS);
    bd.mouseCursors[ImGuiMouseCursor.ResizeEW]   = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZEWE);
    bd.mouseCursors[ImGuiMouseCursor.ResizeNESW] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENESW);
    bd.mouseCursors[ImGuiMouseCursor.ResizeNWSE] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENWSE);
    bd.mouseCursors[ImGuiMouseCursor.Hand]       = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_HAND);
    bd.mouseCursors[ImGuiMouseCursor.NotAllowed] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_NO);

    return true;
}

void ImGui_ImplSDL2_Shutdown() {
    ImGuiIO* io = &ImGui.GetIO();
    foreach (ref c; bd.mouseCursors)
        if (c) SDL_FreeCursor(c);
    ImGui.MemFree(bd);
    bd = null;
    io.BackendPlatformUserData = null;
    io.BackendPlatformName     = null;
}

// -------------------------------------------------------------------------
// Process one SDL event — call before ImGui.NewFrame()
// -------------------------------------------------------------------------

bool ImGui_ImplSDL2_ProcessEvent(const SDL_Event* event) {
    ImGuiIO* io = &ImGui.GetIO();
    switch (event.type) {
        case SDL_MOUSEMOTION:
            io.AddMousePosEvent(cast(float)event.motion.x,
                                cast(float)event.motion.y);
            return true;
        case SDL_MOUSEWHEEL:
            io.AddMouseWheelEvent(
                event.wheel.x > 0 ?  1.0f : event.wheel.x < 0 ? -1.0f : 0,
                event.wheel.y > 0 ?  1.0f : event.wheel.y < 0 ? -1.0f : 0);
            return true;
        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP: {
            int btn = -1;
            if      (event.button.button == SDL_BUTTON_LEFT)   btn = 0;
            else if (event.button.button == SDL_BUTTON_RIGHT)  btn = 1;
            else if (event.button.button == SDL_BUTTON_MIDDLE) btn = 2;
            else if (event.button.button == SDL_BUTTON_X1)     btn = 3;
            else if (event.button.button == SDL_BUTTON_X2)     btn = 4;
            if (btn == -1) break;
            io.AddMouseButtonEvent(btn, event.type == SDL_MOUSEBUTTONDOWN);
            return true;
        }
        case SDL_TEXTINPUT: {
            import core.stdc.string : strlen;
            const(char)* p = event.text.text[].ptr;
            io.AddInputCharactersUTF8(cast(string)(p[0 .. strlen(p)]));
            return true;
        }
        case SDL_KEYDOWN:
        case SDL_KEYUP: {
            updateKeyMods(io);
            ImGuiKey key = sdlScancodeToImGuiKey(event.key.keysym.scancode);
            if (key != ImGuiKey.None)
                io.AddKeyEvent(key, event.type == SDL_KEYDOWN);
            return true;
        }
        case SDL_WINDOWEVENT:
            if (event.window.event == SDL_WINDOWEVENT_FOCUS_GAINED)
                io.AddFocusEvent(true);
            else if (event.window.event == SDL_WINDOWEVENT_FOCUS_LOST)
                io.AddFocusEvent(false);
            return true;
        default:
            return false;
    }
    return false;
}

// -------------------------------------------------------------------------
// NewFrame — update per-frame state (display size, delta time, cursor)
// -------------------------------------------------------------------------

void ImGui_ImplSDL2_NewFrame() {
    ImGuiIO* io = &ImGui.GetIO();

    // Display size
    int w, h, fw, fh;
    SDL_GetWindowSize(bd.window, &w, &h);
    SDL_GL_GetDrawableSize(bd.window, &fw, &fh);
    io.DisplaySize = ImVec2(cast(float)w, cast(float)h);
    if (w > 0 && h > 0)
        io.DisplayFramebufferScale = ImVec2(cast(float)fw / w,
                                            cast(float)fh / h);
    // Delta time
    ulong now = SDL_GetPerformanceCounter();
    io.DeltaTime = (now - bd.lastPerfCounter) > 0
        ? cast(float)(now - bd.lastPerfCounter) / cast(float)bd.perfFrequency
        : 1.0f / 60.0f;
    bd.lastPerfCounter = now;

    // Mouse cursor
    if (!(io.ConfigFlags & ImGuiConfigFlags.NoMouseCursorChange)) {
        ImGuiMouseCursor cur = ImGui.GetMouseCursor();
        if (io.MouseDrawCursor || cur == ImGuiMouseCursor.None) {
            SDL_ShowCursor(SDL_DISABLE);
        } else {
            SDL_Cursor* c = bd.mouseCursors[cur]
                          ? bd.mouseCursors[cur]
                          : bd.mouseCursors[ImGuiMouseCursor.Arrow];
            SDL_SetCursor(c);
            SDL_ShowCursor(SDL_ENABLE);
        }
    }
}

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

private static string getClipboardText(void* ud) nothrow @nogc {
    return ImGui.ImCstring(SDL_GetClipboardText());
}

private static void setClipboardText(void* ud, string text) nothrow @nogc {
    SDL_SetClipboardText(text.ptr);
}

private static void updateKeyMods(ImGuiIO* io) nothrow @nogc {
    SDL_Keymod mods = SDL_GetModState();
    io.AddKeyEvent(ImGuiMod.Ctrl,  (mods & KMOD_CTRL)  != 0);
    io.AddKeyEvent(ImGuiMod.Shift, (mods & KMOD_SHIFT) != 0);
    io.AddKeyEvent(ImGuiMod.Alt,   (mods & KMOD_ALT)   != 0);
    io.AddKeyEvent(ImGuiMod.Super, (mods & KMOD_GUI)   != 0);
}

private static ImGuiKey sdlScancodeToImGuiKey(SDL_Scancode sc) nothrow @nogc {
    switch (sc) {
        case SDL_SCANCODE_TAB:          return ImGuiKey.Tab;
        case SDL_SCANCODE_LEFT:         return ImGuiKey.LeftArrow;
        case SDL_SCANCODE_RIGHT:        return ImGuiKey.RightArrow;
        case SDL_SCANCODE_UP:           return ImGuiKey.UpArrow;
        case SDL_SCANCODE_DOWN:         return ImGuiKey.DownArrow;
        case SDL_SCANCODE_PAGEUP:       return ImGuiKey.PageUp;
        case SDL_SCANCODE_PAGEDOWN:     return ImGuiKey.PageDown;
        case SDL_SCANCODE_HOME:         return ImGuiKey.Home;
        case SDL_SCANCODE_END:          return ImGuiKey.End;
        case SDL_SCANCODE_INSERT:       return ImGuiKey.Insert;
        case SDL_SCANCODE_DELETE:       return ImGuiKey.Delete;
        case SDL_SCANCODE_BACKSPACE:    return ImGuiKey.Backspace;
        case SDL_SCANCODE_SPACE:        return ImGuiKey.Space;
        case SDL_SCANCODE_RETURN:       return ImGuiKey.Enter;
        case SDL_SCANCODE_ESCAPE:       return ImGuiKey.Escape;
        case SDL_SCANCODE_APOSTROPHE:   return ImGuiKey.Apostrophe;
        case SDL_SCANCODE_COMMA:        return ImGuiKey.Comma;
        case SDL_SCANCODE_MINUS:        return ImGuiKey.Minus;
        case SDL_SCANCODE_PERIOD:       return ImGuiKey.Period;
        case SDL_SCANCODE_SLASH:        return ImGuiKey.Slash;
        case SDL_SCANCODE_SEMICOLON:    return ImGuiKey.Semicolon;
        case SDL_SCANCODE_EQUALS:       return ImGuiKey.Equal;
        case SDL_SCANCODE_LEFTBRACKET:  return ImGuiKey.LeftBracket;
        case SDL_SCANCODE_BACKSLASH:    return ImGuiKey.Backslash;
        case SDL_SCANCODE_RIGHTBRACKET: return ImGuiKey.RightBracket;
        case SDL_SCANCODE_GRAVE:        return ImGuiKey.GraveAccent;
        case SDL_SCANCODE_CAPSLOCK:     return ImGuiKey.CapsLock;
        case SDL_SCANCODE_SCROLLLOCK:   return ImGuiKey.ScrollLock;
        case SDL_SCANCODE_NUMLOCKCLEAR: return ImGuiKey.NumLock;
        case SDL_SCANCODE_PRINTSCREEN:  return ImGuiKey.PrintScreen;
        case SDL_SCANCODE_PAUSE:        return ImGuiKey.Pause;
        case SDL_SCANCODE_KP_0:         return ImGuiKey.Keypad0;
        case SDL_SCANCODE_KP_1:         return ImGuiKey.Keypad1;
        case SDL_SCANCODE_KP_2:         return ImGuiKey.Keypad2;
        case SDL_SCANCODE_KP_3:         return ImGuiKey.Keypad3;
        case SDL_SCANCODE_KP_4:         return ImGuiKey.Keypad4;
        case SDL_SCANCODE_KP_5:         return ImGuiKey.Keypad5;
        case SDL_SCANCODE_KP_6:         return ImGuiKey.Keypad6;
        case SDL_SCANCODE_KP_7:         return ImGuiKey.Keypad7;
        case SDL_SCANCODE_KP_8:         return ImGuiKey.Keypad8;
        case SDL_SCANCODE_KP_9:         return ImGuiKey.Keypad9;
        case SDL_SCANCODE_KP_PERIOD:    return ImGuiKey.KeypadDecimal;
        case SDL_SCANCODE_KP_DIVIDE:    return ImGuiKey.KeypadDivide;
        case SDL_SCANCODE_KP_MULTIPLY:  return ImGuiKey.KeypadMultiply;
        case SDL_SCANCODE_KP_MINUS:     return ImGuiKey.KeypadSubtract;
        case SDL_SCANCODE_KP_PLUS:      return ImGuiKey.KeypadAdd;
        case SDL_SCANCODE_KP_ENTER:     return ImGuiKey.KeypadEnter;
        case SDL_SCANCODE_KP_EQUALS:    return ImGuiKey.KeypadEqual;
        case SDL_SCANCODE_LCTRL:        return ImGuiKey.LeftCtrl;
        case SDL_SCANCODE_LSHIFT:       return ImGuiKey.LeftShift;
        case SDL_SCANCODE_LALT:         return ImGuiKey.LeftAlt;
        case SDL_SCANCODE_LGUI:         return ImGuiKey.LeftSuper;
        case SDL_SCANCODE_RCTRL:        return ImGuiKey.RightCtrl;
        case SDL_SCANCODE_RSHIFT:       return ImGuiKey.RightShift;
        case SDL_SCANCODE_RALT:         return ImGuiKey.RightAlt;
        case SDL_SCANCODE_RGUI:         return ImGuiKey.RightSuper;
        case SDL_SCANCODE_A:            return ImGuiKey.A;
        case SDL_SCANCODE_B:            return ImGuiKey.B;
        case SDL_SCANCODE_C:            return ImGuiKey.C;
        case SDL_SCANCODE_D:            return ImGuiKey.D;
        case SDL_SCANCODE_E:            return ImGuiKey.E;
        case SDL_SCANCODE_F:            return ImGuiKey.F;
        case SDL_SCANCODE_G:            return ImGuiKey.G;
        case SDL_SCANCODE_H:            return ImGuiKey.H;
        case SDL_SCANCODE_I:            return ImGuiKey.I;
        case SDL_SCANCODE_J:            return ImGuiKey.J;
        case SDL_SCANCODE_K:            return ImGuiKey.K;
        case SDL_SCANCODE_L:            return ImGuiKey.L;
        case SDL_SCANCODE_M:            return ImGuiKey.M;
        case SDL_SCANCODE_N:            return ImGuiKey.N;
        case SDL_SCANCODE_O:            return ImGuiKey.O;
        case SDL_SCANCODE_P:            return ImGuiKey.P;
        case SDL_SCANCODE_Q:            return ImGuiKey.Q;
        case SDL_SCANCODE_R:            return ImGuiKey.R;
        case SDL_SCANCODE_S:            return ImGuiKey.S;
        case SDL_SCANCODE_T:            return ImGuiKey.T;
        case SDL_SCANCODE_U:            return ImGuiKey.U;
        case SDL_SCANCODE_V:            return ImGuiKey.V;
        case SDL_SCANCODE_W:            return ImGuiKey.W;
        case SDL_SCANCODE_X:            return ImGuiKey.X;
        case SDL_SCANCODE_Y:            return ImGuiKey.Y;
        case SDL_SCANCODE_Z:            return ImGuiKey.Z;
        case SDL_SCANCODE_F1:           return ImGuiKey.F1;
        case SDL_SCANCODE_F2:           return ImGuiKey.F2;
        case SDL_SCANCODE_F3:           return ImGuiKey.F3;
        case SDL_SCANCODE_F4:           return ImGuiKey.F4;
        case SDL_SCANCODE_F5:           return ImGuiKey.F5;
        case SDL_SCANCODE_F6:           return ImGuiKey.F6;
        case SDL_SCANCODE_F7:           return ImGuiKey.F7;
        case SDL_SCANCODE_F8:           return ImGuiKey.F8;
        case SDL_SCANCODE_F9:           return ImGuiKey.F9;
        case SDL_SCANCODE_F10:          return ImGuiKey.F10;
        case SDL_SCANCODE_F11:          return ImGuiKey.F11;
        case SDL_SCANCODE_F12:          return ImGuiKey.F12;
        default:                        return ImGuiKey.None;
    }
}
