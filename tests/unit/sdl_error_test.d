module tests.unit.sdl_error_test;

import bindbc.sdl : SDL_ClearError, SDL_SetError, loadSDL, sdlSupport;
import sdl_error : sdlError;

unittest
{
    assert(loadSDL() == sdlSupport, "SDL error-text test could not load SDL2");
    scope (exit) SDL_ClearError();

    SDL_SetError("readable SDL error sentinel");
    assert(sdlError() == "readable SDL error sentinel",
        "sdlError must convert SDL's C string instead of formatting its address");
}
