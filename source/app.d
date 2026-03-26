import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File;
import std.math : tan, sin, cos, sqrt, PI, abs;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import d_imgui.imgui_demo;
import imgui_impl_sdl2;
import imgui_impl_opengl3;


import math;
import mesh;
import eventlog;
import handler;
import tool;
import editmode;
import gizmo;

// ---------------------------------------------------------------------------
// Shaders
// ---------------------------------------------------------------------------

immutable string vertexShaderSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    void main() {
        gl_Position = u_proj * u_view * u_model * vec4(aPos, 1.0);
    }
};

immutable string fragmentShaderSrc = q{
    #version 330 core
    uniform vec3 u_color;
    out vec4 fragColor;
    void main() {
        fragColor = vec4(u_color, 1.0);
    }
};

// Lit shaders — Blinn-Phong with flat per-face normals.
immutable string litVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    layout(location = 1) in vec3 aNormal;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    out vec3 vNormal;
    out vec3 vWorldPos;
    void main() {
        vec4 worldPos = u_model * vec4(aPos, 1.0);
        vWorldPos     = worldPos.xyz;
        vNormal       = mat3(u_model) * aNormal;
        gl_Position   = u_proj * u_view * worldPos;
    }
};

immutable string litFragSrc = q{
    #version 330 core
    in  vec3 vNormal;
    in  vec3 vWorldPos;
    uniform vec3  u_color;
    uniform vec3  u_lightDir;  // normalized, world space
    uniform vec3  u_eyePos;
    uniform float u_ambient;
    uniform float u_specStr;
    uniform float u_specPow;
    out vec4 fragColor;
    void main() {
        vec3 N    = normalize(vNormal);
        vec3 L    = u_lightDir;
        vec3 V    = normalize(u_eyePos - vWorldPos);
        vec3 H    = normalize(L + V);
        float dif = max(dot(N, L), 0.0);
        float spc = pow(max(dot(N, H), 0.0), u_specPow);
        vec3  col = u_color * (u_ambient + dif * (1.0 - u_ambient))
                  + vec3(1.0) * spc * u_specStr;
        fragColor = vec4(col, 1.0);
    }
};

// Grid shaders — vertex passes world pos, fragment computes fade alpha.
immutable string gridVertSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_model;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    out vec3 vWorldPos;
    void main() {
        vWorldPos   = (u_model * vec4(aPos, 1.0)).xyz;
        gl_Position = u_proj * u_view * vec4(vWorldPos, 1.0);
    }
};

immutable string gridFragSrc = q{
    #version 330 core
    uniform vec3  u_color;
    uniform float u_maxDist;     // world-space fade radius
    uniform vec2  u_screenSize;  // 3D viewport size in fb pixels
    uniform float u_vpOriginX;   // 3D viewport left edge in fb pixels
    uniform float u_vpOriginY;   // 3D viewport bottom edge in fb pixels
    in  vec3 vWorldPos;
    out vec4 fragColor;
    void main() {
        // Distance fade: full opacity at origin, zero at u_maxDist
        float dist      = length(vWorldPos.xz);
        float distAlpha = 1.0 - smoothstep(0.0, u_maxDist, dist);

        // Screen-edge fade (all four edges): min 20%
        float sx       = (gl_FragCoord.x - u_vpOriginX) / u_screenSize.x;
        float sy       = (gl_FragCoord.y - u_vpOriginY) / u_screenSize.y;
        float edgeFade = smoothstep(0.0, 0.15, sx) * smoothstep(1.0, 0.85, sx)
                       * smoothstep(0.0, 0.15, sy) * smoothstep(1.0, 0.85, sy);
        float edgeAlpha = mix(0.2, 1.0, edgeFade);

        fragColor = vec4(u_color, distAlpha * edgeAlpha);
    }
};


// Read depth buffer at window position (px, py),
// accounting for HiDPI framebuffer scale.
float readDepth(int winW, int winH, int fbW, int fbH, float px, float py) {
    int fbX = cast(int)(px * fbW / winW);
    int fbY = fbH - 1 - cast(int)(py * fbH / winH);  // OpenGL Y is bottom-up
    if (fbX < 0 || fbX >= fbW || fbY < 0 || fbY >= fbH) return 1.0f;
    float depth;
    glReadPixels(fbX, fbY, 1, 1, GL_DEPTH_COMPONENT, GL_FLOAT, &depth);
    return depth;
}


// ---------------------------------------------------------------------------
// Enums shared across tools and main
// ---------------------------------------------------------------------------

enum DragMode { None, Orbit, Zoom, Pan, Select, SelectAdd, SelectRemove }

// ---------------------------------------------------------------------------
// Shader helpers
// ---------------------------------------------------------------------------

GLuint compileShader(GLenum type, string src) {
    GLuint shader = glCreateShader(type);
    const(char)* p = src.toStringz();
    glShaderSource(shader, 1, &p, null);
    glCompileShader(shader);
    GLint ok;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetShaderInfoLog(shader, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Shader error: " ~ log[].to!string);
    }
    return shader;
}

GLuint createProgram(string vertSrc = vertexShaderSrc,
                     string fragSrc = fragmentShaderSrc) {
    GLuint vert = compileShader(GL_VERTEX_SHADER,   vertSrc);
    GLuint frag = compileShader(GL_FRAGMENT_SHADER, fragSrc);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vert);
    glAttachShader(prog, frag);
    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetProgramInfoLog(prog, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Link error: " ~ log[].to!string);
    }
    glDeleteShader(vert);
    glDeleteShader(frag);
    return prog;
}

// Geometry shader that expands GL_LINES into screen-aligned quads
// to produce thick lines on macOS Core Profile (where glLineWidth > 1 is unsupported).
immutable string thickLineGeomSrc = q{
    #version 330 core
    layout(lines) in;
    layout(triangle_strip, max_vertices = 4) out;
    uniform float u_lineWidth;   // desired line width in pixels
    uniform vec2  u_screenSize;  // framebuffer size in pixels
    void main() {
        vec4 p0 = gl_in[0].gl_Position;
        vec4 p1 = gl_in[1].gl_Position;
        // Convert to screen space
        vec2 s0 = p0.xy / p0.w * u_screenSize;
        vec2 s1 = p1.xy / p1.w * u_screenSize;
        vec2 dir = s1 - s0;
        float len = length(dir);
        if (len < 0.001) return;
        // Perpendicular in screen space, half-width
        vec2 perp = vec2(-dir.y, dir.x) / len * (u_lineWidth * 0.5);
        // Back to NDC offsets (un-divide by w)
        vec2 off0 = perp / u_screenSize * p0.w;
        vec2 off1 = perp / u_screenSize * p1.w;
        gl_Position = vec4(p0.xy + off0, p0.zw); EmitVertex();
        gl_Position = vec4(p0.xy - off0, p0.zw); EmitVertex();
        gl_Position = vec4(p1.xy + off1, p1.zw); EmitVertex();
        gl_Position = vec4(p1.xy - off1, p1.zw); EmitVertex();
        EndPrimitive();
    }
};

GLuint createProgramWithGeom(string vertSrc, string geomSrc, string fragSrc) {
    GLuint vert = compileShader(GL_VERTEX_SHADER,   vertSrc);
    GLuint geom = compileShader(GL_GEOMETRY_SHADER, geomSrc);
    GLuint frag = compileShader(GL_FRAGMENT_SHADER, fragSrc);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vert);
    glAttachShader(prog, geom);
    glAttachShader(prog, frag);
    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetProgramInfoLog(prog, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Link error: " ~ log[].to!string);
    }
    glDeleteShader(vert);
    glDeleteShader(geom);
    glDeleteShader(frag);
    return prog;
}

// ---------------------------------------------------------------------------
// Frame-to-fit helper
// ---------------------------------------------------------------------------

// Adjusts `focus` and `distance` so the bounding sphere of `verts` fills
// 90 % of the viewport (keeping the current orbit azimuth/elevation).
void frameToVertices(Vec3[] verts,
                     ref Vec3  focus,
                     ref float distance,
                     float fovY,
                     int vpW, int vpH,
                     float minDist, float maxDist)
{
    if (verts.length == 0) return;

    Vec3 mn = verts[0], mx = verts[0];
    foreach (ref v; verts) {
        if (v.x < mn.x) mn.x = v.x;
        if (v.y < mn.y) mn.y = v.y;
        if (v.z < mn.z) mn.z = v.z;
        if (v.x > mx.x) mx.x = v.x;
        if (v.y > mx.y) mx.y = v.y;
        if (v.z > mx.z) mx.z = v.z;
    }

    focus = Vec3((mn.x + mx.x) * 0.5f,
                 (mn.y + mx.y) * 0.5f,
                 (mn.z + mx.z) * 0.5f);

    float dx = mx.x - mn.x, dy = mx.y - mn.y, dz = mx.z - mn.z;
    float radius = sqrt(dx*dx + dy*dy + dz*dz) * 0.5f;
    if (radius < 1e-6f) radius = 1e-6f;

    // Use the tighter field-of-view (Y or X) so the shape fits in both axes.
    float aspect    = cast(float)vpW / vpH;
    float halfTanY  = tan(fovY * 0.5f);
    float halfTanX  = halfTanY * aspect;
    float halfTanMin = halfTanY < halfTanX ? halfTanY : halfTanX;

    distance = radius / (0.9f * halfTanMin);
    if (distance < minDist) distance = minDist;
    if (distance > maxDist) distance = maxDist;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main(string[] args) {
    // Parse --playback <file> flag
    string playbackFile;
    for (size_t i = 1; i < args.length; ++i) {
        if (args[i] == "--playback" && i + 1 < args.length)
            playbackFile = args[++i];
    }
    bool playbackMode = playbackFile.length > 0;

    if (loadSDL() != sdlSupport) { writeln("Failed to load SDL2"); return; }
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { writefln("SDL_Init: %s", SDL_GetError()); return; }
    scope(exit) SDL_Quit();

    EventLogger evLog;
    if (!playbackMode) {
        evLog.open("events.log");
    }
    scope(exit) evLog.close();

    EventPlayer evPlay;
    if (playbackMode && !evPlay.open(playbackFile)) return;
    if (playbackMode) mouseOverride();

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);

    int winW = 800, winH = 600;
    SDL_Window* window = SDL_CreateWindow(
        "OpenGL Mesh  |  Alt+drag=orbit  Alt+Shift=pan  Ctrl+Alt=zoom  LMB=select",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, winW, winH,
        SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE
    );
    if (!window) { writefln("SDL_CreateWindow: %s", SDL_GetError()); return; }
    scope(exit) SDL_DestroyWindow(window);

    SDL_GLContext ctx = SDL_GL_CreateContext(window);
    if (!ctx) { writefln("SDL_GL_CreateContext: %s", SDL_GetError()); return; }
    scope(exit) SDL_GL_DeleteContext(ctx);

    if (loadOpenGL() < glSupport) { writeln("Failed to load OpenGL 3.3"); return; }
    writefln("OpenGL: %s", glGetString(GL_VERSION));

    // Framebuffer size (may differ on HiDPI / Retina)
    int fbW, fbH;
    SDL_GL_GetDrawableSize(window, &fbW, &fbH);

    SDL_GL_SetSwapInterval(1);
    glEnable(GL_DEPTH_TEST);
    glViewport(0, 0, fbW, fbH);

    // ImGui
    IMGUI_CHECKVERSION();
    ImGui.CreateContext();
    ImGuiIO* io = &ImGui.GetIO();
    io.ConfigFlags |= ImGuiConfigFlags.NavEnableKeyboard;
    ImGui.StyleColorsDark();
    ImGui_ImplSDL2_Init(window);
    ImGui_ImplOpenGL3_Init("#version 330 core");
    scope(exit) {
        ImGui_ImplOpenGL3_Shutdown();
        ImGui_ImplSDL2_Shutdown();
        ImGui.DestroyContext();
    }

    GLuint program = createProgram();
    scope(exit) glDeleteProgram(program);
    GLint locModel = glGetUniformLocation(program, "u_model");
    GLint locView  = glGetUniformLocation(program, "u_view");
    GLint locProj  = glGetUniformLocation(program, "u_proj");
    GLint locColor = glGetUniformLocation(program, "u_color");

    GLuint litProgram = createProgram(litVertSrc, litFragSrc);
    scope(exit) glDeleteProgram(litProgram);
    GLint litLocModel    = glGetUniformLocation(litProgram, "u_model");
    GLint litLocView     = glGetUniformLocation(litProgram, "u_view");
    GLint litLocProj     = glGetUniformLocation(litProgram, "u_proj");
    GLint litLocColor    = glGetUniformLocation(litProgram, "u_color");
    GLint litLocLightDir = glGetUniformLocation(litProgram, "u_lightDir");
    GLint litLocEyePos   = glGetUniformLocation(litProgram, "u_eyePos");
    GLint litLocAmbient  = glGetUniformLocation(litProgram, "u_ambient");
    GLint litLocSpecStr  = glGetUniformLocation(litProgram, "u_specStr");
    GLint litLocSpecPow  = glGetUniformLocation(litProgram, "u_specPow");

    GLuint thickLineProgram = createProgramWithGeom(vertexShaderSrc, thickLineGeomSrc, fragmentShaderSrc);
    scope(exit) glDeleteProgram(thickLineProgram);
    initThickLineProgram(thickLineProgram, fbW, fbH);

    GLuint gridProgram = createProgram(gridVertSrc, gridFragSrc);
    scope(exit) glDeleteProgram(gridProgram);
    GLint gridLocModel      = glGetUniformLocation(gridProgram, "u_model");
    GLint gridLocView       = glGetUniformLocation(gridProgram, "u_view");
    GLint gridLocProj       = glGetUniformLocation(gridProgram, "u_proj");
    GLint gridLocColor      = glGetUniformLocation(gridProgram, "u_color");
    GLint gridLocMaxDist    = glGetUniformLocation(gridProgram, "u_maxDist");
    GLint gridLocScreenSize  = glGetUniformLocation(gridProgram, "u_screenSize");
    GLint gridLocVpOriginX   = glGetUniformLocation(gridProgram, "u_vpOriginX");
    GLint gridLocVpOriginY   = glGetUniformLocation(gridProgram, "u_vpOriginY");

    Mesh mesh = makeCube();
    writefln("Mesh: %d verts, %d edges, %d faces",
             mesh.vertices.length, mesh.edges.length, mesh.faces.length);

    GpuMesh gpu;
    gpu.init();
    scope(exit) gpu.destroy();
    gpu.upload(mesh);

    // Grid: lines on XZ plane + axis lines
    GLuint gridVao, gridVbo;
    int    gridOnlyVertCount; // vertex count of plain grid lines (before axes)
    glGenVertexArrays(1, &gridVao);
    glGenBuffers(1, &gridVbo);
    scope(exit) { glDeleteVertexArrays(1, &gridVao); glDeleteBuffers(1, &gridVbo); }
    {
        immutable int   N = 50;   // grid half-extent in cells
        immutable float F = cast(float)N;
        float[] verts;

        // Lines parallel to X axis (constant Z), skip Z=0 (that's the X axis)
        foreach (z; -N .. N + 1) {
            if (z == 0) continue;
            float fz = cast(float)z;
            verts ~= [-F, 0, fz,   F, 0, fz];
        }
        // Lines parallel to Z axis (constant X), skip X=0 (that's the Z axis)
        foreach (x; -N .. N + 1) {
            if (x == 0) continue;
            float fx = cast(float)x;
            verts ~= [fx, 0, -F,   fx, 0,  F];
        }
        gridOnlyVertCount = cast(int)(verts.length / 3);

        // Axis lines appended last so they draw on top
        verts ~= [-F, 0, 0,   F, 0, 0];   // X axis
        verts ~= [ 0, 0,-F,   0, 0,  F];  // Z axis

        glBindVertexArray(gridVao);
        glBindBuffer(GL_ARRAY_BUFFER, gridVbo);
        glBufferData(GL_ARRAY_BUFFER, verts.length * float.sizeof, verts.ptr, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3*float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);
        glBindVertexArray(0);
    }

    // Selection state — vertices
    int    hoveredVertex = -1;
    bool[] selected;
    selected.length = mesh.vertices.length;

    // Selection state — edges
    int    hoveredEdge = -1;
    bool[] selectedEdges;
    selectedEdges.length = mesh.edges.length;

    // Selection state — faces
    int    hoveredFace = -1;
    bool[] selectedFaces;
    selectedFaces.length = mesh.faces.length;

    // Camera
    float azimuth   =  0.5f;
    float elevation =  0.4f;
    float distance  =  3.0f;
    Vec3  focus     = Vec3(0, 0, 0);
    immutable float minDist = 0.5f;
    immutable float maxDist = 50.0f;
    immutable float maxElev = cast(float)(89.0f * PI / 180.0f);

    DragMode dragMode = DragMode.None;
    EditMode editMode = EditMode.Vertices;

    // Tools are created lazily on first activation and kept alive until exit.
    MoveTool   moveTool   = null;
    ScaleTool  scaleTool  = null;
    RotateTool rotateTool = null;
    Tool       activeTool = null;

    scope(exit) {
        if (moveTool)   moveTool.destroy();
        if (scaleTool)  scaleTool.destroy();
        if (rotateTool) rotateTool.destroy();
    }

    void setActiveTool(Tool t) {
        if (activeTool) activeTool.deactivate();
        activeTool = t;
        if (activeTool) activeTool.activate();
    }

    MoveTool getMoveTool() {
        if (!moveTool)
            moveTool = new MoveTool(&mesh, &selected, &selectedEdges, &selectedFaces, &gpu, &editMode);
        return moveTool;
    }
    ScaleTool getScaleTool() {
        if (!scaleTool)
            scaleTool = new ScaleTool(&mesh, &selected, &selectedEdges, &selectedFaces, &gpu, &editMode);
        return scaleTool;
    }
    RotateTool getRotateTool() {
        if (!rotateTool)
            rotateTool = new RotateTool(&mesh, &selected, &selectedEdges, &selectedFaces, &gpu, &editMode);
        return rotateTool;
    }

    int lastMouseX, lastMouseY;

    // ---- Build matrices ----
    enum int PANEL_W  = 150;
    enum int STATUS_H = 38;


    bool running = true;
    SDL_Event event;

    while (running) {
        // ---- Playback: push due events before polling ----
        if (playbackMode) evPlay.tick();

        // ---- Events ----
        while (SDL_PollEvent(&event)) {
            evLog.log(event);
            ImGui_ImplSDL2_ProcessEvent(&event);

            if (io.WantCaptureMouse &&
                (event.type == SDL_MOUSEBUTTONDOWN ||
                 event.type == SDL_MOUSEBUTTONUP   ||
                 event.type == SDL_MOUSEMOTION      ||
                 event.type == SDL_MOUSEWHEEL))
                continue;

            switch (event.type) {
                case SDL_QUIT:
                    running = false;
                    break;

                case SDL_WINDOWEVENT:
                    if (event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
                        if (playbackMode)
                            SDL_SetWindowSize(window, event.window.data1, event.window.data2);
                        SDL_GetWindowSize(window, &winW, &winH);
                        SDL_GL_GetDrawableSize(window, &fbW, &fbH);
                        glViewport(0, 0, fbW, fbH);
                        initThickLineProgram(thickLineProgram, fbW, fbH);
                    }
                    break;

                case SDL_KEYDOWN:
                    switch (event.key.keysym.sym) {
                        case SDLK_ESCAPE: running = false;              break;
                        case SDLK_1:      editMode = EditMode.Vertices;  break;
                        case SDLK_2:      editMode = EditMode.Edges;     break;
                        case SDLK_3:      editMode = EditMode.Polygons;  break;
                        case SDLK_SPACE:
                            if (activeTool) setActiveTool(null);
                            else editMode = cast(EditMode)((cast(int)editMode + 1) % 3);
                            break;
                        case SDLK_w:
                            setActiveTool(cast(MoveTool)activeTool ? null : getMoveTool());
                            break;
                        case SDLK_r:
                            setActiveTool(cast(ScaleTool)activeTool ? null : getScaleTool());
                            break;
                        case SDLK_e:
                            setActiveTool(cast(RotateTool)activeTool ? null : getRotateTool());
                            break;
                        case SDLK_a: {
                            bool shift = (event.key.keysym.mod & KMOD_SHIFT) != 0;
                            if (shift) {
                                // Frame selected (or whole mesh if nothing selected).
                                Vec3[] verts;
                                if (editMode == EditMode.Vertices) {
                                    bool any = false;
                                    foreach (s; selected) if (s) { any = true; break; }
                                    foreach (i; 0 .. mesh.vertices.length)
                                        if (!any || selected[i]) verts ~= mesh.vertices[i];
                                } else if (editMode == EditMode.Edges) {
                                    bool any = false;
                                    foreach (s; selectedEdges) if (s) { any = true; break; }
                                    bool[] vis = new bool[](mesh.vertices.length);
                                    foreach (i; 0 .. mesh.edges.length) {
                                        if (any && !selectedEdges[i]) continue;
                                        foreach (vi; mesh.edges[i])
                                            if (!vis[vi]) { verts ~= mesh.vertices[vi]; vis[vi] = true; }
                                    }
                                } else if (editMode == EditMode.Polygons) {
                                    bool any = false;
                                    foreach (s; selectedFaces) if (s) { any = true; break; }
                                    bool[] vis = new bool[](mesh.vertices.length);
                                    foreach (i; 0 .. mesh.faces.length) {
                                        if (any && !selectedFaces[i]) continue;
                                        foreach (vi; mesh.faces[i])
                                            if (!vis[vi]) { verts ~= mesh.vertices[vi]; vis[vi] = true; }
                                    }
                                }
                                frameToVertices(verts, focus, distance,
                                                45.0f * PI / 180.0f,
                                                winW - PANEL_W, winH - STATUS_H,
                                                minDist, maxDist);
                            } else {
                                frameToVertices(mesh.vertices, focus, distance,
                                                45.0f * PI / 180.0f,
                                                winW - PANEL_W, winH - STATUS_H,
                                                minDist, maxDist);

                            }
                            break;
                        }

                        case SDLK_d: {
                                bool shift = (event.key.keysym.mod & KMOD_SHIFT) != 0;
                                if (shift) {
                                    setActiveTool(null);
                                    mesh = catmullClark(mesh);
                                    selected.length      = mesh.vertices.length; selected[]      = false;
                                    selectedEdges.length = mesh.edges.length;    selectedEdges[] = false;
                                    selectedFaces.length = mesh.faces.length;    selectedFaces[] = false;
                                    gpu.upload(mesh);
                                }
                            }
                            break;

                        default: break;
                    }
                    break;

                case SDL_MOUSEBUTTONDOWN:
                    if (activeTool && activeTool.onMouseButtonDown(event.button)) break;
                    if (event.button.button == SDL_BUTTON_LEFT) {
                        SDL_Keymod mods = SDL_GetModState();
                        bool ctrl  = (mods & KMOD_CTRL)  != 0;
                        bool alt   = (mods & KMOD_ALT)   != 0;
                        bool shift = (mods & KMOD_SHIFT)  != 0;
                        bool anyToolActive = activeTool !is null;

                        if      (ctrl && alt)  dragMode = DragMode.Zoom;
                        else if (alt && shift) dragMode = DragMode.Pan;
                        else if (alt)          dragMode = DragMode.Orbit;
                        else if (ctrl && !anyToolActive)  dragMode = DragMode.SelectRemove;
                        else if (shift && !anyToolActive) dragMode = DragMode.SelectAdd;
                        else if (!anyToolActive) {
                            // No modifiers: clear selection for current mode
                            if (editMode == EditMode.Vertices)
                                selected[] = false;
                            else if (editMode == EditMode.Edges)
                                selectedEdges[] = false;
                            else if (editMode == EditMode.Polygons)
                                selectedFaces[] = false;
                            dragMode = DragMode.Select;
                        }
                        lastMouseX = event.button.x;
                        lastMouseY = event.button.y;
                    }
                    break;

                case SDL_MOUSEBUTTONUP:
                    if (activeTool) activeTool.onMouseButtonUp(event.button);
                    if (event.button.button == SDL_BUTTON_LEFT)
                        dragMode = DragMode.None;
                    break;

                case SDL_MOUSEMOTION:
                    if (activeTool && activeTool.onMouseMotion(event.motion)) break;
                    if (dragMode == DragMode.None) break;
                    {
                        SDL_Keymod mods = SDL_GetModState();
                        bool ctrl  = (mods & KMOD_CTRL)  != 0;
                        bool alt   = (mods & KMOD_ALT)   != 0;
                        bool shift = (mods & KMOD_SHIFT)  != 0;

                        bool modOk = (dragMode == DragMode.Zoom)      ? (ctrl && alt)
                                   : (dragMode == DragMode.Pan)       ? (alt && shift)
                                   : (dragMode == DragMode.Orbit)     ? (alt && !shift)
                                   : (dragMode == DragMode.Select    ||
                                      dragMode == DragMode.SelectAdd  ||
                                      dragMode == DragMode.SelectRemove) ? true
                                   : false;
                        if (!modOk) { dragMode = DragMode.None; break; }

                        int dx = event.motion.x - lastMouseX;
                        int dy = event.motion.y - lastMouseY;

                        if (dragMode == DragMode.Orbit) {
                            azimuth   -= dx * 0.005f;
                            elevation += dy * 0.005f;
                            if (elevation >  maxElev) elevation =  maxElev;
                            if (elevation < -maxElev) elevation = -maxElev;
                        } else if (dragMode == DragMode.Zoom) {
                            distance -= dx * 0.01f * distance;
                            if (distance < minDist) distance = minDist;
                            if (distance > maxDist) distance = maxDist;
                        } else if (dragMode == DragMode.Pan) {
                            Vec3 off     = sphericalToCartesian(azimuth, elevation, distance);
                            Vec3 forward = normalize(Vec3(-off.x, -off.y, -off.z));
                            Vec3 right   = normalize(cross(forward, Vec3(0, 1, 0)));
                            Vec3 up      = cross(right, forward);
                            float speed  = distance * 0.001f;
                            focus = vec3Add(focus, vec3Scale(right, -dx * speed));
                            focus = vec3Add(focus, vec3Scale(up,     dy * speed));
                        }
                        lastMouseX = event.motion.x;
                        lastMouseY = event.motion.y;
                    }
                    break;

                default: break;
            }
        }

        int vp3dW = winW - PANEL_W;
        int vp3dH = winH - STATUS_H;

        Vec3 offset = sphericalToCartesian(azimuth, elevation, distance);
        Vec3 eye    = vec3Add(focus, offset);
        auto view   = lookAt(eye, focus, Vec3(0, 1, 0));
        auto proj   = perspectiveMatrix(45.0f * PI / 180.0f,
                                        cast(float)vp3dW / vp3dH, 0.1f, 100.0f);
        Viewport vp = Viewport(view, proj, vp3dW, vp3dH, PANEL_W, 0);

        // ---- ImGui ----
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui.NewFrame();

        int selCount;
        foreach (s; selected) if (s) selCount++;
        int selEdgeCount;
        foreach (s; selectedEdges) if (s) selEdgeCount++;
        int selFaceCount;
        foreach (s; selectedFaces) if (s) selFaceCount++;

        ImGui.SetNextWindowPos(ImVec2(0, 0), ImGuiCond.Always);
        ImGui.SetNextWindowSize(ImVec2(PANEL_W, winH), ImGuiCond.Always);
        if (ImGui.Begin("Mesh Info", null,
                        ImGuiWindowFlags.NoTitleBar |
                        ImGuiWindowFlags.NoResize |
                        ImGuiWindowFlags.NoMove   |
                        ImGuiWindowFlags.NoCollapse))
        {
            ImGui.LabelText("Vertices", "%d", cast(int)mesh.vertices.length);
            ImGui.LabelText("Edges",    "%d", cast(int)mesh.edges.length);
            ImGui.LabelText("Faces",    "%d", cast(int)mesh.faces.length);

            ImGui.Separator();
            ImGui.Text("Tools");
            if (getMoveTool().drawImGui())
                setActiveTool(cast(MoveTool)activeTool ? null : getMoveTool());
            if (getRotateTool().drawImGui())
                setActiveTool(cast(RotateTool)activeTool ? null : getRotateTool());
            if (getScaleTool().drawImGui())
                setActiveTool(cast(ScaleTool)activeTool ? null : getScaleTool());

            ImGui.Separator();
            ImGui.Text("Selection");

            if (editMode == EditMode.Vertices) {
                if (hoveredVertex >= 0)
                    ImGui.LabelText("Hover", "v%d  (%.2f, %.2f, %.2f)",
                        hoveredVertex,
                        cast(double)mesh.vertices[hoveredVertex].x,
                        cast(double)mesh.vertices[hoveredVertex].y,
                        cast(double)mesh.vertices[hoveredVertex].z);
                else
                    ImGui.LabelText("Hover", "—");
                ImGui.LabelText("Selected", "%d", selCount);
                if (selCount > 0) {
                    foreach (i; 0 .. selected.length) {
                        if (!selected[i]) continue;
                        ImGui.Text("  v%d  (%.2f, %.2f, %.2f)",
                            cast(int)i,
                            cast(double)mesh.vertices[i].x,
                            cast(double)mesh.vertices[i].y,
                            cast(double)mesh.vertices[i].z);
                    }
                }
            } else if (editMode == EditMode.Edges) {
                if (hoveredEdge >= 0)
                    ImGui.LabelText("Hover", "e%d  v%d-v%d",
                        hoveredEdge,
                        cast(int)mesh.edges[hoveredEdge][0],
                        cast(int)mesh.edges[hoveredEdge][1]);
                else
                    ImGui.LabelText("Hover", "—");
                ImGui.LabelText("Selected", "%d", selEdgeCount);
                if (selEdgeCount > 0) {
                    foreach (i; 0 .. selectedEdges.length) {
                        if (!selectedEdges[i]) continue;
                        ImGui.Text("  e%d  v%d-v%d",
                            cast(int)i,
                            cast(int)mesh.edges[i][0],
                            cast(int)mesh.edges[i][1]);
                    }
                }
            } else if (editMode == EditMode.Polygons) {
                if (hoveredFace >= 0)
                    ImGui.LabelText("Hover", "f%d  (%d verts)",
                        hoveredFace,
                        cast(int)mesh.faces[hoveredFace].length);
                else
                    ImGui.LabelText("Hover", "—");
                ImGui.LabelText("Selected", "%d", selFaceCount);
                if (selFaceCount > 0) {
                    foreach (i; 0 .. selectedFaces.length) {
                        if (!selectedFaces[i]) continue;
                        ImGui.Text("  f%d  (%d verts)",
                            cast(int)i,
                            cast(int)mesh.faces[i].length);
                    }
                }
            }

            ImGui.Separator();
            ImGui.Text("Camera");
            ImGui.LabelText("Dist",  "%.2f", distance);
            ImGui.LabelText("Az",    "%.1f°", cast(double)(azimuth   * 180.0 / PI));
            ImGui.LabelText("El",    "%.1f°", cast(double)(elevation * 180.0 / PI));

            ImGui.Separator();
            ImGui.TextDisabled("Alt+drag        orbit");
            ImGui.TextDisabled("Alt+Shift+drag  pan");
            ImGui.TextDisabled("Ctrl+Alt+drag   zoom");
            ImGui.TextDisabled("LMB / drag       select");
            ImGui.TextDisabled("Shift+LMB/drag   add to select");
            ImGui.TextDisabled("Ctrl+LMB/drag    remove from select");
        }
        ImGui.End();

        ImGui.SetNextWindowPos(ImVec2(PANEL_W, winH - STATUS_H), ImGuiCond.Always);
        ImGui.SetNextWindowSize(ImVec2(winW - PANEL_W, STATUS_H), ImGuiCond.Always);
        if (ImGui.Begin("Status line", null,
                        ImGuiWindowFlags.NoTitleBar |
                        ImGuiWindowFlags.NoResize |
                        ImGuiWindowFlags.NoMove   |
                        ImGuiWindowFlags.NoCollapse))
        {
            {
                bool active = false;
                if (editMode == EditMode.Vertices) {
                    ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                    active = true;
                }
                bool clicked = ImGui.Button("Vertices  1");
                if (clicked)
                    editMode = EditMode.Vertices;
                if (active)
                    ImGui.PopStyleColor();
                ImGui.SameLine();
            }
            {
                bool active = false;
                if (editMode == EditMode.Edges) {
                    ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                    active = true;
                }
                bool clicked = ImGui.Button("Edges     2");
                if (clicked)
                    editMode = EditMode.Edges;
                if (active)
                    ImGui.PopStyleColor();
                ImGui.SameLine();
            }
            {
                bool active = false;
                if (editMode == EditMode.Polygons) {
                    ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                    active = true;
                }
                bool clicked = ImGui.Button("Polygons  3");
                if (clicked)
                    editMode = EditMode.Polygons;
                if (active)
                    ImGui.PopStyleColor();
                ImGui.SameLine();
            }
        }
        ImGui.End();
        ShowDemoWindow();


        // ---- Gizmo 3D (orientation indicator, bottom-right of 3D view) ----
        DrawGizmo(PANEL_W + 32.0f, winH - STATUS_H - 32.0f, view);

        // ---- Playback cursor overlay ----
        if (playbackMode) {
            ImDrawList* dl = ImGui.GetForegroundDrawList();
            ImVec2 pos = ImVec2(cast(float)evPlay.mouseX, cast(float)evPlay.mouseY);
            // Outer ring
            dl.AddCircle(pos, 12.0f, IM_COL32(255, 220, 0, 220), 24, 2.0f);
            // Inner dot — filled red when button is pressed, white otherwise
            uint dotColor = evPlay.mouseDown
                ? IM_COL32(255, 80, 80, 255)
                : IM_COL32(255, 255, 255, 200);
            dl.AddCircleFilled(pos, 3.0f, dotColor, 12);
        }

        ImGui.Render();

        // ---- 3D render ----
        glClearColor(0.36f, 0.40f, 0.42f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Restrict rendering to the 3D viewport area (exclude panels).
        float scaleX = cast(float)fbW / winW;
        float scaleY = cast(float)fbH / winH;
        glViewport(cast(int)(PANEL_W  * scaleX),
                   cast(int)(STATUS_H * scaleY),
                   cast(int)(vp3dW   * scaleX),
                   cast(int)(vp3dH   * scaleY));

        glUseProgram(program);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, identityMatrix.ptr);
        glUniformMatrix4fv(locView,  1, GL_FALSE, view.ptr);
        glUniformMatrix4fv(locProj,  1, GL_FALSE, proj.ptr);

        // ---- Grid axis lines (alpha-blended, distance + edge fade) ----
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        // glDepthMask(GL_FALSE);

        glUseProgram(gridProgram);
        glUniformMatrix4fv(gridLocModel, 1, GL_FALSE, identityMatrix.ptr);
        glUniformMatrix4fv(gridLocView,  1, GL_FALSE, view.ptr);
        glUniformMatrix4fv(gridLocProj,  1, GL_FALSE, proj.ptr);
        glUniform1f(gridLocMaxDist,    distance * 2.0f);
        glUniform2f(gridLocScreenSize, cast(float)vp3dW * scaleX, cast(float)vp3dH * scaleY);
        glUniform1f(gridLocVpOriginX,  cast(float)PANEL_W  * scaleX);
        glUniform1f(gridLocVpOriginY,  cast(float)STATUS_H * scaleY);

        glBindVertexArray(gridVao);
        // Grid lines — gray
        glUniform3f(gridLocColor, 0.5f, 0.5f, 0.5f);
        glDrawArrays(GL_LINES, 0, gridOnlyVertCount);
        // X axis — pale red
        glUniform3f(gridLocColor, 0.5f, 0.15f, 0.15f);
        glDrawArrays(GL_LINES, gridOnlyVertCount, 2);
        // Z axis — pale blue
        glUniform3f(gridLocColor, 0.15f, 0.15f, 0.5f);
        glDrawArrays(GL_LINES, gridOnlyVertCount + 2, 2);
        glBindVertexArray(0);

        // glDepthMask(GL_TRUE);
        glDisable(GL_BLEND);

        // Draw faces with Blinn-Phong lighting
        {
            Vec3 lightDir = normalize(Vec3(0.6f, 1.0f, 0.5f));
            glUseProgram(litProgram);
            glUniformMatrix4fv(litLocModel, 1, GL_FALSE, identityMatrix.ptr);
            glUniformMatrix4fv(litLocView,  1, GL_FALSE, view.ptr);
            glUniformMatrix4fv(litLocProj,  1, GL_FALSE, proj.ptr);
            glUniform3f(litLocLightDir, lightDir.x, lightDir.y, lightDir.z);
            glUniform3f(litLocEyePos,   eye.x, eye.y, eye.z);
            glUniform1f(litLocAmbient,  0.20f);
            glUniform1f(litLocSpecStr,  0.25f);
            glUniform1f(litLocSpecPow,  32.0f);
            if (editMode == EditMode.Polygons)
                gpu.drawFacesHighlighted(litProgram, litLocColor, hoveredFace, selectedFaces);
            else
                gpu.drawFaces(litProgram, litLocColor);
        }

        glUseProgram(program);
        glUniformMatrix4fv(locModel, 1, GL_FALSE, identityMatrix.ptr);
        glUniformMatrix4fv(locView,  1, GL_FALSE, view.ptr);
        glUniformMatrix4fv(locProj,  1, GL_FALSE, proj.ptr);

        bool doingCameraDrag = (dragMode == DragMode.Orbit ||
                                dragMode == DragMode.Zoom  ||
                                dragMode == DragMode.Pan);

        // ---- Vertex picking (EditMode.Vertices only) ----
        hoveredVertex = -1;
        if (!io.WantCaptureMouse && !doingCameraDrag &&
            editMode == EditMode.Vertices && activeTool is null)
        {
            int mx, my;
            queryMouse(mx, my);
            float closest = 3.0f;  // pixel radius

            foreach (i; 0 .. mesh.vertices.length) {
                float sx, sy, ndcZ;
                if (!projectToWindow(mesh.vertices[i], vp, sx, sy, ndcZ))
                    continue;

                float expectedDepth = ndcZ * 0.5f + 0.5f;
                float bufDepth      = readDepth(winW, winH, fbW, fbH, sx, sy);
                if (expectedDepth > bufDepth + 0.01f)
                    continue;  // occluded

                float dx = sx - mx;
                float dy = sy - my;
                float d  = sqrt(dx*dx + dy*dy);
                if (d < closest) {
                    closest       = d;
                    hoveredVertex = cast(int)i;
                }
            }

            if (hoveredVertex >= 0) {
                if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
                    selected[hoveredVertex] = true;
                else if (dragMode == DragMode.SelectRemove)
                    selected[hoveredVertex] = false;
            }
        }

        // ---- Edge picking (EditMode.Edges only) ----
        hoveredEdge = -1;
        if (!io.WantCaptureMouse && !doingCameraDrag &&
            editMode == EditMode.Edges && activeTool is null)
        {
            int mx, my;
            queryMouse(mx, my);
            float closest = 4.0f;  // pixel radius for edges

            foreach (i; 0 .. mesh.edges.length) {
                uint a = mesh.edges[i][0], b = mesh.edges[i][1];
                float sax, say, ndcZa, sbx, sby, ndcZb;
                if (!projectToWindow(mesh.vertices[a], vp, sax, say, ndcZa))
                    continue;
                if (!projectToWindow(mesh.vertices[b], vp, sbx, sby, ndcZb))
                    continue;

                float t;
                float d = closestOnSegment2D(cast(float)mx, cast(float)my,
                                             sax, say, sbx, sby, t);
                if (d >= closest) continue;

                // Check occlusion at the closest point on the projected segment
                float cpx = sax + t * (sbx - sax);
                float cpy = say + t * (sby - say);
                float ndcZ = ndcZa + t * (ndcZb - ndcZa);
                float expectedDepth = ndcZ * 0.5f + 0.5f;
                float bufDepth = readDepth(winW, winH, fbW, fbH, cpx, cpy);
                if (expectedDepth > bufDepth + 0.01f)
                    continue;  // occluded by a face

                closest    = d;
                hoveredEdge = cast(int)i;
            }

            if (hoveredEdge >= 0) {
                if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
                    selectedEdges[hoveredEdge] = true;
                else if (dragMode == DragMode.SelectRemove)
                    selectedEdges[hoveredEdge] = false;
            }
        }

        // ---- Face picking (EditMode.Polygons only) ----
        hoveredFace = -1;
        if (!io.WantCaptureMouse && !doingCameraDrag &&
            editMode == EditMode.Polygons && activeTool is null)
        {
            int mx, my;
            queryMouse(mx, my);
            float bestZ = float.infinity;

            foreach (fi; 0 .. mesh.faces.length) {
                uint[] face = mesh.faces[fi];
                if (face.length < 3) continue;

                float[] sxs, sys, ndcZs;
                bool allOk = true;
                foreach (vi; face) {
                    float sx, sy, ndcZ;
                    if (!projectToWindow(mesh.vertices[vi], vp, sx, sy, ndcZ)) { allOk = false; break; }
                    sxs ~= sx; sys ~= sy; ndcZs ~= ndcZ;
                }
                if (!allOk) continue;
                if (!pointInPolygon2D(cast(float)mx, cast(float)my, sxs, sys)) continue;

                // Occlusion check at screen centroid
                float cx = 0, cy = 0, cZ = 0;
                foreach (k; 0 .. sxs.length) { cx += sxs[k]; cy += sys[k]; cZ += ndcZs[k]; }
                int n = cast(int)sxs.length;
                cx /= n; cy /= n; cZ /= n;
                float expectedDepth = cZ * 0.5f + 0.5f;
                float bufDepth = readDepth(winW, winH, fbW, fbH, cx, cy);
                if (expectedDepth > bufDepth + 0.02f) continue;

                // Pick face closest to camera
                if (cZ < bestZ) { bestZ = cZ; hoveredFace = cast(int)fi; }
            }

            if (hoveredFace >= 0) {
                if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
                    selectedFaces[hoveredFace] = true;
                else if (dragMode == DragMode.SelectRemove)
                    selectedFaces[hoveredFace] = false;
            }
        }

        // ---- Draw edges (with highlights in Edges mode) ----
        if (editMode == EditMode.Edges)
            gpu.drawEdges(locColor, hoveredEdge, selectedEdges);
        else
            gpu.drawEdges(locColor, -1, []);

        // ---- Vertex dots (EditMode.Vertices only) ----
        if (editMode == EditMode.Vertices)
            gpu.drawVertices(locColor, hoveredVertex, selected);

        // ---- Active tool ----
        if (activeTool) {
            activeTool.update();
            activeTool.draw(program, locColor, vp);
        }

        // ---- ImGui draw ----
        // Restore full viewport for ImGui rendering.
        glViewport(0, 0, fbW, fbH);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui.GetDrawData());

        SDL_GL_SwapWindow(window);
    }
}
