// Test-only access to BindBC-SDL's package-visible loader pointers. The public
// wrappers call these pointers, so replacing them observes the real wrapper
// invocation. Both observers forward to the loaded SDL implementation, but
// only delay has a portable external effect witness; swap forwarding is not
// claimed by this rig.
module sdl.vibe3d_frame_finish_witness;

import sdl.timer;
import sdl.video;

/// Counts and last arguments observed below the public BindBC-SDL wrappers.
struct FrameFinishSdlCallSnapshot {
    size_t swapCallbackCalls;
    SDL_Window* swapWindow;
    bool swapWindowMismatch;
    size_t delayCallbackCalls;
    uint delayMilliseconds;
}

private alias SwapPointer = typeof(_SDL_GL_SwapWindow);
private alias DelayPointer = typeof(_SDL_Delay);

private __gshared SwapPointer g_originalSwap;
private __gshared DelayPointer g_originalDelay;
private __gshared FrameFinishSdlCallSnapshot g_snapshot;
private __gshared bool g_installed;

private extern(C) void observeSwap(SDL_Window* window) nothrow @nogc {
    if (g_snapshot.swapCallbackCalls == 0)
        g_snapshot.swapWindow = window;
    else if (g_snapshot.swapWindow !is window)
        g_snapshot.swapWindowMismatch = true;
    ++g_snapshot.swapCallbackCalls;
    g_originalSwap(window);
}

private extern(C) void observeDelay(uint milliseconds) nothrow @nogc {
    ++g_snapshot.delayCallbackCalls;
    g_snapshot.delayMilliseconds = milliseconds;
    g_originalDelay(milliseconds);
}

/// Install after loadSDL, while both real loader pointers are populated.
bool installFrameFinishSdlCallWitness() nothrow @nogc {
    if (g_installed || _SDL_GL_SwapWindow is null || _SDL_Delay is null)
        return false;

    g_originalSwap = _SDL_GL_SwapWindow;
    g_originalDelay = _SDL_Delay;
    g_snapshot = FrameFinishSdlCallSnapshot.init;
    _SDL_GL_SwapWindow = &observeSwap;
    _SDL_Delay = &observeDelay;
    g_installed = true;
    return true;
}

/// Restore before the SDL window/context teardown registered by the caller.
void restoreFrameFinishSdlCallWitness() nothrow @nogc {
    if (!g_installed)
        return;
    _SDL_GL_SwapWindow = g_originalSwap;
    _SDL_Delay = g_originalDelay;
    g_originalSwap = null;
    g_originalDelay = null;
    g_installed = false;
}

FrameFinishSdlCallSnapshot frameFinishSdlCallSnapshot() nothrow @nogc {
    return g_snapshot;
}

unittest {
    assert(!g_installed,
        "frame finish SDL call witness must start uninstalled");
}
