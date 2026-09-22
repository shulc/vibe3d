module web_gl_loader;

import gl = bindbc.opengl;

/// WebGL2 / ES 3 entry points called by the browser closure. The three
/// desktop-only calls below are populated when a driver exposes them, but are
/// deliberately outside the readiness threshold: later wave-16 slices remove
/// their browser paths (point size, OSD TBO fan-out, diagnostic buffer reads).
/// The executable call-site census is tests/unit/web_gl_loader_test.d.
enum string[] requiredWebGlSymbols = [
    "glActiveTexture", "glAttachShader", "glBeginTransformFeedback",
    "glBindBuffer", "glBindBufferBase", "glBindFramebuffer",
    "glBindRenderbuffer", "glBindTexture", "glBindVertexArray",
    "glBlendFunc", "glBlendFuncSeparate", "glBlitFramebuffer",
    "glBufferData", "glBufferSubData", "glCheckFramebufferStatus",
    "glClear", "glClearBufferuiv", "glClearColor", "glCompileShader",
    "glCreateProgram", "glCreateShader", "glCullFace", "glDeleteBuffers",
    "glDeleteFramebuffers", "glDeleteProgram", "glDeleteRenderbuffers",
    "glDeleteShader", "glDeleteTextures", "glDeleteVertexArrays",
    "glDepthFunc", "glDepthMask", "glDisable", "glDisableVertexAttribArray",
    "glDrawArrays", "glEnable", "glEnableVertexAttribArray",
    "glEndTransformFeedback", "glFlush", "glFramebufferRenderbuffer",
    "glFramebufferTexture2D", "glGenBuffers", "glGenFramebuffers",
    "glGenRenderbuffers", "glGenTextures", "glGenVertexArrays",
    "glGetIntegerv", "glGetProgramInfoLog", "glGetProgramiv",
    "glGetShaderInfoLog", "glGetShaderiv", "glGetString",
    "glGetUniformBlockIndex", "glGetUniformLocation", "glIsBuffer",
    "glIsEnabled", "glIsVertexArray", "glLinkProgram", "glMapBufferRange",
    "glPixelStorei", "glPolygonOffset", "glReadBuffer", "glReadPixels",
    "glRenderbufferStorage", "glShaderSource", "glTexImage2D",
    "glTexParameteri", "glTransformFeedbackVaryings", "glUniform1f",
    "glUniform1i", "glUniform2f", "glUniform3f", "glUniformBlockBinding",
    "glUniformMatrix4fv", "glUnmapBuffer", "glUseProgram",
    "glVertexAttrib3f", "glVertexAttribIPointer", "glVertexAttribPointer",
    "glViewport",
];

enum string[] optionalDesktopGlSymbols = [
    "glGetBufferSubData", "glPointSize", "glTexBuffer",
];

enum string[] webClosureGlSymbols =
    requiredWebGlSymbols ~ optionalDesktopGlSymbols;

alias WebGlProcLookup = extern(C) void* function(const(char)*) nothrow @nogc;

private enum hasBindbcMember(string name) =
    __traits(compiles, __traits(getMember, gl, name));

private enum isRequiredWebGlSymbol(string name) = () {
    foreach (required; requiredWebGlSymbols)
        if (required == name) return true;
    return false;
}();

/// Populate BindBC's existing function-pointer variables. Returns the first
/// required ES3 symbol that the active context cannot provide, or null on
/// success. Optional desktop-only slots are still populated when available so
/// native --config=web keeps exercising today's full rendering path.
const(char)[] loadWebOpenGL(WebGlProcLookup lookup) nothrow @nogc
{
    static foreach (name; webClosureGlSymbols)
    {
        {
            static assert(hasBindbcMember!name,
                "web GL roster names no BindBC member: " ~ name);
            enum cName = name ~ "\0";
            alias slot = __traits(getMember, gl, name);
            slot = cast(typeof(slot)) lookup(cName.ptr);
            static if (isRequiredWebGlSymbol!name)
            {
                if (slot is null) return name;
            }
        }
    }
    return null;
}

version (web)
{
    import bindbc.sdl : SDL_GL_GetProcAddress;

    const(char)[] loadWebOpenGL() nothrow @nogc
    {
        return loadWebOpenGL(&SDL_GL_GetProcAddress);
    }
}
