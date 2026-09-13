// Test-only access to BindBC-SDL's package-visible loader pointers. The public
// wrappers call these pointers, so replacing them observes the real wrapper
// invocation. Both observers forward to the loaded SDL implementation, but
// only delay has a portable external effect witness; swap forwarding is not
// claimed by this rig.
module sdl.vibe3d_frame_finish_witness;

import core.time : Duration, MonoTime;

import sdl.timer;
import sdl.video;

/// Counts and last arguments observed below the public BindBC-SDL wrappers.
struct FrameFinishSdlCallSnapshot {
    size_t swapCallbackCalls;
    SDL_Window* swapWindow;
    bool swapWindowMismatch;
    size_t delayCallbackCalls;
    uint delayMilliseconds;
    /// Wall time spent INSIDE the forwarded `SDL_Delay`, measured around that
    /// one call and nothing else. See `observeDelay` for why the measurement
    /// has to sit here rather than around the frame.
    Duration delayForwardElapsed;
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
    // The forwarded sleep is timed HERE, around this single call, because the
    // error of a sleep is ONE-SIDED: the OS may overrun the requested delay,
    // never undercut it. So "elapsed >= requested" holds under any scheduling
    // load, and dropping the forward below leaves ~0.
    //
    // The first version of this cell instead subtracted two whole-frame
    // timings (hidden minus normal). That threw the one-sided property away:
    // both terms carry their own frame work, and on a loaded CI runner the
    // NORMAL row measured 8.355 ms against the hidden row's 4.289 ms, so the
    // difference went NEGATIVE and the gate failed on a correct tree. A
    // difference of two noisy measurements cannot judge a quantity smaller
    // than that noise.
    const started = MonoTime.currTime;
    g_originalDelay(milliseconds);
    g_snapshot.delayForwardElapsed = MonoTime.currTime - started;
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
