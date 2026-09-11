module sdl_error;

import bindbc.sdl : SDL_GetError;
import std.string : fromStringz;

/// Expose SDL's error buffer as a D slice for immediate diagnostics.
/// Task 5503: every caller goes through this conversion; see sdl_error_test.d.
const(char)[] sdlError() nothrow @nogc
{
    return SDL_GetError().fromStringz;
}
