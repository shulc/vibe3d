// Desktop pixel witnesses for the WebGL2-compatible thick-line body.
//
// These cells deliberately drive the public draw funnel against a real GL 3.3
// context.  The edge cell compares equal-depth and 2:1 clip-w lines at the
// same five-pixel width: their antialiasing profiles must coincide only when
// the vertex/fragment d*w compensation preserves screen-linear distance.
// Separate cells pin dense stride-zero GL_LINES pairing, LINE_LOOP's closing
// segment, caller binding restoration, and the required position layout.

import bindbc.opengl;
import bindbc.sdl;
import core.exception : AssertError;
import handles.gl_util : drawThickLinesExt, initThickLineProgram,
    setThickLineScreenSize, shutdownThickLineProgram;
import math : Vec3, Viewport, identityMatrix, perspectiveMatrix;
import shader : createProgram, thickLineFragSrc, thickLineVertexSrc;
import std.conv : to;
import std.format : format;
import std.math : PI;
import std.process : environment;
import std.stdio : writefln;

void main() {}

private enum int kWidth = 256;
private enum int kHeight = 128;
private enum float kLineWidthPx = 5.0f;
private enum float kClipWRatio = 2.0f;

private struct VaoBuffer {
    GLuint vao;
    GLuint vbo;

    void destroy() {
        if (vbo) glDeleteBuffers(1, &vbo);
        if (vao) glDeleteVertexArrays(1, &vao);
        vao = vbo = 0;
    }
}

private VaoBuffer makeVao(const(float)[] xyz, GLint size = 3,
                          GLenum type = GL_FLOAT, GLsizei stride = 0,
                          size_t offset = 0) {
    VaoBuffer result;
    glGenVertexArrays(1, &result.vao);
    glGenBuffers(1, &result.vbo);
    glBindVertexArray(result.vao);
    glBindBuffer(GL_ARRAY_BUFFER, result.vbo);
    glBufferData(GL_ARRAY_BUFFER, xyz.length * float.sizeof, xyz.ptr,
                 GL_STATIC_DRAW);
    glVertexAttribPointer(0, size, type, GL_FALSE, stride,
                          cast(void*)offset);
    glEnableVertexAttribArray(0);
    return result;
}

private ubyte redAt(int x, int y) {
    ubyte[4] rgba;
    glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba.ptr);
    return rgba[0];
}

private void clearTarget() {
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
}

private Vec3 atNdc(float ndcX, float ndcY, float clipW,
                   const ref Viewport vp) {
    return Vec3(ndcX * clipW / vp.proj[0],
                ndcY * clipW / vp.proj[5], -clipW);
}

private void draw(VaoBuffer vb, int count, GLenum mode,
                  const ref Viewport vp, bool smooth = true) {
    float[16] model = identityMatrix;
    drawThickLinesExt(vb.vao, count, mode, model, vp,
                      Vec3(1, 1, 1), kLineWidthPx, 0, 1.0f, smooth);
}

private void edgeAndRestoreCell(const ref Viewport vp) {
    // Both centre lines land on integer framebuffer coordinates, so their
    // vertical profiles have the same pixel phase as well as the same width.
    enum float yControl = 0.375f;  // framebuffer y = 88
    enum float yPerspective = -0.375f; // framebuffer y = 40
    auto points = [
        atNdc(-0.65f, yControl, 3.0f, vp),
        atNdc( 0.65f, yControl, 3.0f, vp),
        atNdc(-0.65f, yPerspective, 2.0f, vp),
        atNdc( 0.65f, yPerspective, 2.0f * kClipWRatio, vp),
    ];
    auto vb = makeVao(cast(float[])points);
    scope(exit) vb.destroy();

    GLuint sentinel;
    glGenBuffers(1, &sentinel);
    scope(exit) glDeleteBuffers(1, &sentinel);
    glBindVertexArray(vb.vao);
    glBindBuffer(GL_ARRAY_BUFFER, sentinel);

    clearTarget();
    draw(vb, 4, GL_LINES, vp);

    GLint actualVao, actualBuffer;
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &actualVao);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &actualBuffer);
    assert(actualVao == vb.vao,
        format("BINDING RESTORE: caller VAO=%s, actual=%s", vb.vao, actualVao));
    assert(actualBuffer == sentinel,
        format("BINDING RESTORE: caller ARRAY_BUFFER=%s, actual=%s",
               sentinel, actualBuffer));

    int partial;
    int maximumDelta;
    foreach (dy; -5 .. 6) {
        immutable int control = redAt(kWidth / 2, 88 + dy);
        immutable int perspective = redAt(kWidth / 2, 40 + dy);
        immutable int delta = control > perspective
            ? control - perspective : perspective - control;
        if (delta > maximumDelta) maximumDelta = delta;
        if ((control > 0 && control < 255)
            || (perspective > 0 && perspective < 255)) ++partial;
    }
    assert(maximumDelta <= 4,
        format("EDGE PROFILE: width=%.1f px, clip-w ratio=%.1f: equal-depth "
             ~ "and perspective profiles differ by %s levels (limit 4)",
               kLineWidthPx, kClipWRatio, maximumDelta));
    assert(partial > 0,
        format("EDGE PROFILE FLOOR: width=%.1f px, clip-w ratio=%.1f: no "
             ~ "antialiasing fringe", kLineWidthPx, kClipWRatio));
}

private void denseStrideLinesCell(const ref Viewport vp) {
    auto points = [
        atNdc(-0.85f, 0.0f, 3.0f, vp), atNdc(-0.45f, 0.0f, 3.0f, vp),
        atNdc( 0.45f, 0.0f, 3.0f, vp), atNdc( 0.85f, 0.0f, 3.0f, vp),
    ];
    auto vb = makeVao(cast(float[])points); // stride 0 is load-bearing
    scope(exit) vb.destroy();
    clearTarget();
    draw(vb, 4, GL_LINES, vp, false);
    assert(redAt(45, 64) > 240 && redAt(211, 64) > 240,
        "STRIDE ZERO: the two independent GL_LINES segments were not both drawn");
    assert(redAt(128, 64) < 10,
        "STRIDE ZERO: GL_LINES instances were paired as an overlapping strip");
}

private void interleavedOffsetCell() {
    Viewport vp;
    vp.view = identityMatrix;
    vp.proj = identityMatrix;
    vp.width = kWidth;
    vp.height = kHeight;
    // Attribute 0 follows an unrelated vec3: stride 24, offset 12. The decoy
    // values are coincident and offscreen, so forcing the queried offset to 0
    // cannot accidentally draw the expected centre line.
    float[] interleaved = [
        4.0f, 4.0f, 0.0f,  -0.60f, 0.0f, 0.0f,
        4.0f, 4.0f, 0.0f,   0.60f, 0.0f, 0.0f,
    ];
    auto vb = makeVao(interleaved, 3, GL_FLOAT,
                      cast(GLsizei)(6 * float.sizeof), 3 * float.sizeof);
    scope(exit) vb.destroy();
    clearTarget();
    draw(vb, 2, GL_LINES, vp, false);
    assert(redAt(kWidth / 2, kHeight / 2) > 240,
        "ATTRIBUTE OFFSET: stride 24 / offset 12 position was not drawn");
}

private void reinitAfterShutdownCell(GLuint program) {
    Viewport vp;
    vp.view = identityMatrix;
    vp.proj = identityMatrix;
    vp.width = kWidth;
    vp.height = kHeight;
    float[] points = [-0.60f, 0.0f, 0.0f, 0.60f, 0.0f, 0.0f];
    auto vb = makeVao(points);
    scope(exit) vb.destroy();

    // Allocate the source VAO before teardown so the driver cannot reuse the
    // deleted scratch name for this fixture and hide a missing state reset.
    shutdownThickLineProgram();
    initThickLineProgram(program, kWidth, kHeight);
    clearTarget();
    while (glGetError() != GL_NO_ERROR) {}
    draw(vb, 2, GL_LINES, vp, false);
    immutable GLenum drawError = glGetError();
    assert(drawError == GL_NO_ERROR,
        format("THICK-LINE REINIT: stale scratch VAO caused GL error %s",
               drawError));
    assert(redAt(kWidth / 2, kHeight / 2) > 240,
        "THICK-LINE REINIT: draw failed after scratch VAO teardown");
}

private void loopClosingCell() {
    Viewport vp;
    vp.view = identityMatrix;
    vp.proj = identityMatrix;
    vp.width = kWidth;
    vp.height = kHeight;
    float[] points = [
        -0.55f, -0.45f, 0,  0.55f, -0.45f, 0,
         0.55f,  0.45f, 0, -0.55f,  0.45f, 0,
    ];
    auto vb = makeVao(points);
    scope(exit) vb.destroy();
    clearTarget();
    draw(vb, 4, GL_LINE_LOOP, vp, false);

    immutable int leftX = cast(int)((-0.55f + 1.0f) * 0.5f * kWidth);
    assert(redAt(leftX, kHeight / 2) > 240,
        "LINE_LOOP CLOSURE: the last-to-first segment is absent");
    assert(redAt(kWidth / 2, kHeight / 2) < 10,
        "LINE_LOOP FLOOR: the square fixture unexpectedly filled its centre");
}

private void layoutGuardCell() {
    Viewport vp;
    vp.view = identityMatrix;
    vp.proj = identityMatrix;
    vp.width = kWidth;
    vp.height = kHeight;
    float[] points = [-0.5f, 0, 0, 0.5f, 0, 0];

    auto badSize = makeVao(points, 2, GL_FLOAT);
    scope(exit) badSize.destroy();
    bool sizeRejected;
    try draw(badSize, 2, GL_LINES, vp);
    catch (AssertError) sizeRejected = true;
    assert(sizeRejected, "LAYOUT GUARD: attribute size 2 was accepted");

    auto badType = makeVao(points, 3, GL_SHORT);
    scope(exit) badType.destroy();
    bool typeRejected;
    try draw(badType, 2, GL_LINES, vp);
    catch (AssertError) typeRejected = true;
    assert(typeRejected, "LAYOUT GUARD: GL_SHORT position attribute was accepted");
}

private void runThickLineWitness() {
    const hadDriver = "SDL_VIDEODRIVER" in environment;
    const oldDriver = environment.get("SDL_VIDEODRIVER", "");
    const hadDisplay = "DISPLAY" in environment;
    const oldDisplay = environment.get("DISPLAY", "");
    scope(exit) {
        if (hadDriver) environment["SDL_VIDEODRIVER"] = oldDriver;
        else environment.remove("SDL_VIDEODRIVER");
        if (hadDisplay) environment["DISPLAY"] = oldDisplay;
        else environment.remove("DISPLAY");
    }
    const requestedDisplay = environment.get("VIBE3D_TEST_DISPLAY", "");
    if (requestedDisplay.length) {
        environment["DISPLAY"] = requestedDisplay;
        environment["SDL_VIDEODRIVER"] = "x11";
    } else {
        environment.remove("DISPLAY");
        environment["SDL_VIDEODRIVER"] = "offscreen";
    }

    assert(loadSDL() == sdlSupport, "thick-line rig could not load SDL");
    assert(SDL_Init(SDL_INIT_VIDEO) == 0,
        "thick-line rig could not initialize SDL: " ~ SDL_GetError().to!string);
    scope(exit) SDL_Quit();
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    auto window = SDL_CreateWindow("thick-line-instancing-witness",
        SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, kWidth, kHeight,
        SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    assert(window !is null,
        "thick-line rig could not create window: " ~ SDL_GetError().to!string);
    scope(exit) SDL_DestroyWindow(window);
    auto context = SDL_GL_CreateContext(window);
    assert(context !is null,
        "thick-line rig could not create context: " ~ SDL_GetError().to!string);
    scope(exit) SDL_GL_DeleteContext(context);
    assert(loadOpenGL() >= glSupport,
        "thick-line rig could not load OpenGL 3.3");

    GLuint texture, fbo;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kWidth, kHeight, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, null);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, texture, 0);
    assert(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
        "thick-line rig framebuffer is incomplete");
    scope(exit) {
        glDeleteFramebuffers(1, &fbo);
        glDeleteTextures(1, &texture);
    }
    glViewport(0, 0, kWidth, kHeight);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_MULTISAMPLE);

    GLuint program = createProgram(thickLineVertexSrc, thickLineFragSrc);
    scope(exit) glDeleteProgram(program);
    initThickLineProgram(program, kWidth, kHeight);
    scope(exit) shutdownThickLineProgram();
    setThickLineScreenSize(kWidth, kHeight);

    Viewport perspective;
    perspective.view = identityMatrix;
    perspective.proj = perspectiveMatrix(PI / 2, 2.0f, 0.1f, 20.0f);
    perspective.width = kWidth;
    perspective.height = kHeight;

    denseStrideLinesCell(perspective);
    writefln("  PASS: stride-zero GL_LINES pairing");
    interleavedOffsetCell();
    writefln("  PASS: interleaved attribute offset");
    reinitAfterShutdownCell(program);
    writefln("  PASS: scratch VAO teardown and reinit");
    edgeAndRestoreCell(perspective);
    writefln("  PASS: edge width %.1f px at clip-w ratio %.1f and bindings",
             kLineWidthPx, kClipWRatio);
    loopClosingCell();
    writefln("  PASS: LINE_LOOP closing segment");
    layoutGuardCell();
    writefln("  PASS: attribute layout guards");
}

unittest {
    runThickLineWitness();
}
