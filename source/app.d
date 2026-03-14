import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln;
import std.math : tan, sin, cos, sqrt, PI, abs;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import imgui_impl_sdl2;
import imgui_impl_opengl3;

// ---------------------------------------------------------------------------
// Shaders
// ---------------------------------------------------------------------------

immutable string vertexShaderSrc = q{
    #version 330 core
    layout(location = 0) in vec3 aPos;
    uniform mat4 u_view;
    uniform mat4 u_proj;
    void main() {
        gl_Position = u_proj * u_view * vec4(aPos, 1.0);
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

// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

struct Vec3 { float x, y, z; }
struct Vec4 { float x, y, z, w; }

Vec3 vec3Add  (Vec3 a, Vec3 b)  { return Vec3(a.x+b.x, a.y+b.y, a.z+b.z); }
Vec3 vec3Sub  (Vec3 a, Vec3 b)  { return Vec3(a.x-b.x, a.y-b.y, a.z-b.z); }
Vec3 vec3Scale(Vec3 v, float s) { return Vec3(v.x*s, v.y*s, v.z*s); }

Vec3 normalize(Vec3 v) {
    float len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
    return Vec3(v.x/len, v.y/len, v.z/len);
}
Vec3 cross(Vec3 a, Vec3 b) {
    return Vec3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
float dot(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }

// Column-major 4x4 * Vec4
Vec4 mulMV(const ref float[16] m, Vec4 v) {
    return Vec4(
        m[0]*v.x + m[4]*v.y + m[ 8]*v.z + m[12]*v.w,
        m[1]*v.x + m[5]*v.y + m[ 9]*v.z + m[13]*v.w,
        m[2]*v.x + m[6]*v.y + m[10]*v.z + m[14]*v.w,
        m[3]*v.x + m[7]*v.y + m[11]*v.z + m[15]*v.w,
    );
}

float[16] lookAt(Vec3 eye, Vec3 center, Vec3 worldUp) {
    Vec3 f = normalize(vec3Sub(center, eye));
    Vec3 r = normalize(cross(f, worldUp));
    Vec3 u = cross(r, f);
    return [
         r.x,  u.x, -f.x, 0,
         r.y,  u.y, -f.y, 0,
         r.z,  u.z, -f.z, 0,
        -dot(r,eye), -dot(u,eye), dot(f,eye), 1,
    ];
}

float[16] perspectiveMatrix(float fovY, float aspect, float near, float far) {
    float f  = 1.0f / tan(fovY * 0.5f);
    float nf = near - far;
    return [
        f / aspect, 0,                    0,  0,
        0,          f,                    0,  0,
        0,          0,   (far + near) / nf, -1,
        0,          0, 2*far*near / nf,      0,
    ];
}

Vec3 sphericalToCartesian(float az, float el, float dist) {
    return Vec3(dist * cos(el) * sin(az),
                dist * sin(el),
                dist * cos(el) * cos(az));
}

// Project world point to window pixel coords.
// Returns false if behind camera or outside frustum.
// px, py  — window-space pixels (Y down)
// ndcZ    — NDC depth in [-1, 1]
bool projectToWindow(Vec3 world,
                     const ref float[16] view, const ref float[16] proj,
                     int winW, int winH,
                     out float px, out float py, out float ndcZ) {
    Vec4 vp = mulMV(view, Vec4(world.x, world.y, world.z, 1.0f));
    Vec4 cp = mulMV(proj, vp);
    if (cp.w <= 0.0f) return false;
    float nx = cp.x / cp.w;
    float ny = cp.y / cp.w;
    ndcZ     = cp.z / cp.w;
    if (nx < -1 || nx > 1 || ny < -1 || ny > 1 || ndcZ < -1 || ndcZ > 1)
        return false;
    px = (nx * 0.5f + 0.5f)        * winW;
    py = (1.0f - (ny * 0.5f + 0.5f)) * winH;
    return true;
}

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

// 2D point-in-polygon test (ray casting, works for convex and concave polygons).
bool pointInPolygon2D(float px, float py, float[] xs, float[] ys) {
    int n = cast(int)xs.length;
    bool inside = false;
    for (int i = 0, j = n - 1; i < n; j = i++) {
        if (((ys[i] > py) != (ys[j] > py)) &&
            (px < (xs[j] - xs[i]) * (py - ys[i]) / (ys[j] - ys[i]) + xs[i]))
            inside = !inside;
    }
    return inside;
}

// Closest distance from point (px,py) to segment (ax,ay)-(bx,by).
// t is the interpolation parameter [0..1] of the closest point on segment.
float closestOnSegment2D(float px, float py,
                          float ax, float ay, float bx, float by,
                          out float t) {
    float dx = bx - ax, dy = by - ay;
    float len2 = dx*dx + dy*dy;
    if (len2 < 1e-6f) { t = 0.0f; return sqrt((px-ax)*(px-ax)+(py-ay)*(py-ay)); }
    t = ((px-ax)*dx + (py-ay)*dy) / len2;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    float cx = ax + t*dx, cy = ay + t*dy;
    return sqrt((px-cx)*(px-cx) + (py-cy)*(py-cy));
}

// ---------------------------------------------------------------------------
// Mesh
// ---------------------------------------------------------------------------

struct Mesh {
    Vec3[]    vertices;
    uint[2][] edges;
    uint[][]  faces;

    uint addVertex(Vec3 v) {
        vertices ~= v;
        return cast(uint)(vertices.length - 1);
    }
    void addEdge(uint a, uint b) {
        foreach (e; edges)
            if ((e[0]==a && e[1]==b) || (e[0]==b && e[1]==a)) return;
        edges ~= [a, b];
    }
    void addFace(uint[] idx) {
        faces ~= idx.dup;
        for (uint i = 0; i < idx.length; i++)
            addEdge(idx[i], idx[(i+1) % idx.length]);
    }
    void clear() { vertices = []; edges = []; faces = []; }
}

Mesh makeCube() {
    Mesh m;
    m.vertices = [
        Vec3(-0.5f, -0.5f, -0.5f), // 0
        Vec3( 0.5f, -0.5f, -0.5f), // 1
        Vec3( 0.5f,  0.5f, -0.5f), // 2
        Vec3(-0.5f,  0.5f, -0.5f), // 3
        Vec3(-0.5f, -0.5f,  0.5f), // 4
        Vec3( 0.5f, -0.5f,  0.5f), // 5
        Vec3( 0.5f,  0.5f,  0.5f), // 6
        Vec3(-0.5f,  0.5f,  0.5f), // 7
    ];
    m.addFace([0, 3, 2, 1]);
    m.addFace([4, 5, 6, 7]);
    m.addFace([0, 4, 7, 3]);
    m.addFace([1, 2, 6, 5]);
    m.addFace([3, 7, 6, 2]);
    m.addFace([0, 1, 5, 4]);
    return m;
}

// ---------------------------------------------------------------------------
// GpuMesh
// ---------------------------------------------------------------------------

struct GpuMesh {
    GLuint faceVao, faceVbo;
    GLuint edgeVao, edgeVbo;
    GLuint vertVao, vertVbo;   // vertex points
    int    faceVertCount;
    int    edgeVertCount;
    int    vertCount;
    int[]  faceTriStart;   // first vertex index in faceVbo for each face
    int[]  faceTriCount;   // vertex count for each face

    void init() {
        glGenVertexArrays(1, &faceVao); glGenBuffers(1, &faceVbo);
        glGenVertexArrays(1, &edgeVao); glGenBuffers(1, &edgeVbo);
        glGenVertexArrays(1, &vertVao); glGenBuffers(1, &vertVbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &faceVao); glDeleteBuffers(1, &faceVbo);
        glDeleteVertexArrays(1, &edgeVao); glDeleteBuffers(1, &edgeVbo);
        glDeleteVertexArrays(1, &vertVao); glDeleteBuffers(1, &vertVbo);
    }

    void upload(ref const Mesh mesh) {
        // Faces (fan triangulation) — track per-face offsets
        float[] faceData;
        faceTriStart.length = 0;
        faceTriCount.length = 0;
        foreach (face; mesh.faces) {
            int start = cast(int)(faceData.length / 3);
            if (face.length >= 3) {
                for (uint i = 1; i + 1 < face.length; i++) {
                    foreach (idx; [face[0], face[i], face[i+1]]) {
                        Vec3 v = mesh.vertices[idx];
                        faceData ~= [v.x, v.y, v.z];
                    }
                }
            }
            int count = cast(int)(faceData.length / 3) - start;
            faceTriStart ~= start;
            faceTriCount  ~= count;
        }
        faceVertCount = cast(int)(faceData.length / 3);
        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
        glBufferData(GL_ARRAY_BUFFER, faceData.length * float.sizeof, faceData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        // Edges
        float[] edgeData;
        foreach (edge; mesh.edges) {
            Vec3 a = mesh.vertices[edge[0]], b = mesh.vertices[edge[1]];
            edgeData ~= [a.x, a.y, a.z, b.x, b.y, b.z];
        }
        edgeVertCount = cast(int)(edgeData.length / 3);
        glBindVertexArray(edgeVao);
        glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
        glBufferData(GL_ARRAY_BUFFER, edgeData.length * float.sizeof, edgeData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        // Vertex points
        float[] vertData;
        foreach (v; mesh.vertices)
            vertData ~= [v.x, v.y, v.z];
        vertCount = cast(int)mesh.vertices.length;
        glBindVertexArray(vertVao);
        glBindBuffer(GL_ARRAY_BUFFER, vertVbo);
        glBufferData(GL_ARRAY_BUFFER, vertData.length * float.sizeof, vertData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    // Draw faces only (writes depth buffer)
    void drawFaces(GLuint program, GLint locColor) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glUniform3f(locColor, 0.25f, 0.45f, 0.75f);
        glBindVertexArray(faceVao);
        glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
        glDisable(GL_POLYGON_OFFSET_FILL);
        glBindVertexArray(0);
    }

    // Draw faces with per-face hover/selection highlights (Polygons mode).
    void drawFacesHighlighted(GLuint program, GLint locColor,
                               int hoveredFace, const bool[] selectedFaces) {
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glBindVertexArray(faceVao);
        foreach (i; 0 .. cast(int)faceTriStart.length) {
            bool sel = i < cast(int)selectedFaces.length && selectedFaces[i];
            bool hov = (i == hoveredFace);
            if (hov)
                glUniform3f(locColor, 1.0f, 0.95f, 0.15f);   // yellow
            else if (sel)
                glUniform3f(locColor, 1.0f, 0.5f, 0.1f);     // orange
            else
                glUniform3f(locColor, 0.25f, 0.45f, 0.75f);  // default blue
            glDrawArrays(GL_TRIANGLES, faceTriStart[i], faceTriCount[i]);
        }
        glDisable(GL_POLYGON_OFFSET_FILL);
        glBindVertexArray(0);
    }

    // Draw edges with optional hover/selection highlights.
    // hoveredEdge = -1 means no hover; selectedEdges may be shorter than edgeCount.
    void drawEdges(GLint locColor, int hoveredEdge, const bool[] selectedEdges) {
        int edgeCount = edgeVertCount / 2;
        glBindVertexArray(edgeVao);

        // Default gray edges (skip hovered and selected)
        glUniform3f(locColor, 0.9f, 0.9f, 0.9f);
        foreach (i; 0 .. edgeCount) {
            if (i == hoveredEdge) continue;
            if (i < cast(int)selectedEdges.length && selectedEdges[i]) continue;
            glDrawArrays(GL_LINES, i * 2, 2);
        }

        // Selected edges — orange
        glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
        foreach (i; 0 .. cast(int)selectedEdges.length)
            if (selectedEdges[i] && i != hoveredEdge)
                glDrawArrays(GL_LINES, i * 2, 2);

        // Hovered edge — yellow (drawn last = on top)
        if (hoveredEdge >= 0 && hoveredEdge < edgeCount) {
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            glDrawArrays(GL_LINES, hoveredEdge * 2, 2);
        }

        glBindVertexArray(0);
    }

    // Draw vertex dots (call AFTER picking so hovered/selected state is current)
    void drawVertices(GLint locColor, int hovered, const bool[] selected) {
        glBindVertexArray(vertVao);

        // All vertices — small gray dots
        glPointSize(5.0f);
        glUniform3f(locColor, 0.6f, 0.6f, 0.6f);
        glDrawArrays(GL_POINTS, 0, vertCount);

        // Selected — larger orange
        glPointSize(10.0f);
        glUniform3f(locColor, 1.0f, 0.5f, 0.1f);
        foreach (i; 0 .. selected.length)
            if (selected[i]) glDrawArrays(GL_POINTS, cast(int)i, 1);

        // Hovered — bright yellow (drawn last = on top)
        if (hovered >= 0 && hovered < vertCount) {
            glPointSize(10.0f);
            glUniform3f(locColor, 1.0f, 0.95f, 0.15f);
            glDrawArrays(GL_POINTS, hovered, 1);
        }

        glPointSize(1.0f);
        glBindVertexArray(0);
    }
}

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

GLuint createProgram() {
    GLuint vert = compileShader(GL_VERTEX_SHADER,   vertexShaderSrc);
    GLuint frag = compileShader(GL_FRAGMENT_SHADER, fragmentShaderSrc);
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

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() {
    if (loadSDL() != sdlSupport) { writeln("Failed to load SDL2"); return; }
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { writefln("SDL_Init: %s", SDL_GetError()); return; }
    scope(exit) SDL_Quit();

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);

    immutable int WIN_W = 800, WIN_H = 600;
    SDL_Window* window = SDL_CreateWindow(
        "OpenGL Mesh  |  Alt+drag=orbit  Alt+Shift=pan  Ctrl+Alt=zoom  LMB=select",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIN_W, WIN_H,
        SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN
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
    GLint locView  = glGetUniformLocation(program, "u_view");
    GLint locProj  = glGetUniformLocation(program, "u_proj");
    GLint locColor = glGetUniformLocation(program, "u_color");

    Mesh mesh = makeCube();
    writefln("Mesh: %d verts, %d edges, %d faces",
             mesh.vertices.length, mesh.edges.length, mesh.faces.length);

    GpuMesh gpu;
    gpu.init();
    scope(exit) gpu.destroy();
    gpu.upload(mesh);

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

    enum DragMode { None, Orbit, Zoom, Pan, Select, SelectAdd, SelectRemove }
    DragMode dragMode = DragMode.None;

    enum EditMode { Vertices, Edges, Polygons }
    EditMode editMode = EditMode.Vertices;
    int lastMouseX, lastMouseY;

    bool running = true;
    SDL_Event event;

    while (running) {
        // ---- Events ----
        while (SDL_PollEvent(&event)) {
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

                case SDL_KEYDOWN:
                    switch (event.key.keysym.sym) {
                        case SDLK_ESCAPE: running = false;              break;
                        case SDLK_1:      editMode = EditMode.Vertices;  break;
                        case SDLK_2:      editMode = EditMode.Edges;     break;
                        case SDLK_3:      editMode = EditMode.Polygons;  break;
                        case SDLK_SPACE:
                            editMode = cast(EditMode)((cast(int)editMode + 1) % 3);
                            break;
                        default: break;
                    }
                    break;

                case SDL_MOUSEBUTTONDOWN:
                    if (event.button.button == SDL_BUTTON_LEFT) {
                        SDL_Keymod mods = SDL_GetModState();
                        bool ctrl  = (mods & KMOD_CTRL)  != 0;
                        bool alt   = (mods & KMOD_ALT)   != 0;
                        bool shift = (mods & KMOD_SHIFT)  != 0;

                        if      (ctrl && alt)  dragMode = DragMode.Zoom;
                        else if (alt && shift) dragMode = DragMode.Pan;
                        else if (alt)          dragMode = DragMode.Orbit;
                        else if (ctrl)         dragMode = DragMode.SelectRemove;
                        else if (shift)        dragMode = DragMode.SelectAdd;
                        else {
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
                    if (event.button.button == SDL_BUTTON_LEFT)
                        dragMode = DragMode.None;
                    break;

                case SDL_MOUSEMOTION:
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

        // ---- Build matrices ----
        Vec3 offset = sphericalToCartesian(azimuth, elevation, distance);
        Vec3 eye    = vec3Add(focus, offset);
        auto view   = lookAt(eye, focus, Vec3(0, 1, 0));
        auto proj   = perspectiveMatrix(45.0f * PI / 180.0f,
                                        cast(float)WIN_W / WIN_H, 0.1f, 100.0f);

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

        ImGui.SetNextWindowPos(ImVec2(10, 10), ImGuiCond.Always);
        ImGui.SetNextWindowSize(ImVec2(230, 0), ImGuiCond.Always);
        if (ImGui.Begin("Mesh Info", null,
                        ImGuiWindowFlags.NoResize |
                        ImGuiWindowFlags.NoMove   |
                        ImGuiWindowFlags.NoCollapse))
        {
            // Edit mode selector
            ImGui.Text("Edit Mode");
            int em = cast(int)editMode;
            if (ImGui.RadioButton("Vertices [1]",  &em, 0)) editMode = EditMode.Vertices;
            if (ImGui.RadioButton("Edges [2]",     &em, 1)) editMode = EditMode.Edges;
            if (ImGui.RadioButton("Polygons [3]",  &em, 2)) editMode = EditMode.Polygons;

            ImGui.Separator();
            ImGui.LabelText("Vertices", "%d", cast(int)mesh.vertices.length);
            ImGui.LabelText("Edges",    "%d", cast(int)mesh.edges.length);
            ImGui.LabelText("Faces",    "%d", cast(int)mesh.faces.length);

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
        ImGui.Render();

        // ---- 3D render ----
        glClearColor(0.12f, 0.12f, 0.12f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        glUseProgram(program);
        glUniformMatrix4fv(locView, 1, GL_FALSE, view.ptr);
        glUniformMatrix4fv(locProj, 1, GL_FALSE, proj.ptr);

        // Draw faces — writes depth buffer (with per-face highlights in Polygons mode)
        if (editMode == EditMode.Polygons)
            gpu.drawFacesHighlighted(program, locColor, hoveredFace, selectedFaces);
        else
            gpu.drawFaces(program, locColor);

        bool doingCameraDrag = (dragMode == DragMode.Orbit ||
                                dragMode == DragMode.Zoom  ||
                                dragMode == DragMode.Pan);

        // ---- Vertex picking (EditMode.Vertices only) ----
        hoveredVertex = -1;
        if (!io.WantCaptureMouse && !doingCameraDrag &&
            editMode == EditMode.Vertices)
        {
            int mx, my;
            SDL_GetMouseState(&mx, &my);
            float closest = 3.0f;  // pixel radius

            foreach (i; 0 .. mesh.vertices.length) {
                float sx, sy, ndcZ;
                if (!projectToWindow(mesh.vertices[i], view, proj, WIN_W, WIN_H,
                                     sx, sy, ndcZ))
                    continue;

                float expectedDepth = ndcZ * 0.5f + 0.5f;
                float bufDepth      = readDepth(WIN_W, WIN_H, fbW, fbH, sx, sy);
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
            editMode == EditMode.Edges)
        {
            int mx, my;
            SDL_GetMouseState(&mx, &my);
            float closest = 4.0f;  // pixel radius for edges

            foreach (i; 0 .. mesh.edges.length) {
                uint a = mesh.edges[i][0], b = mesh.edges[i][1];
                float sax, say, ndcZa, sbx, sby, ndcZb;
                if (!projectToWindow(mesh.vertices[a], view, proj, WIN_W, WIN_H,
                                     sax, say, ndcZa))
                    continue;
                if (!projectToWindow(mesh.vertices[b], view, proj, WIN_W, WIN_H,
                                     sbx, sby, ndcZb))
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
                float bufDepth = readDepth(WIN_W, WIN_H, fbW, fbH, cpx, cpy);
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
            editMode == EditMode.Polygons)
        {
            int mx, my;
            SDL_GetMouseState(&mx, &my);
            float bestZ = float.infinity;

            foreach (fi; 0 .. mesh.faces.length) {
                uint[] face = mesh.faces[fi];
                if (face.length < 3) continue;

                float[] sxs, sys, ndcZs;
                bool allOk = true;
                foreach (vi; face) {
                    float sx, sy, ndcZ;
                    if (!projectToWindow(mesh.vertices[vi], view, proj, WIN_W, WIN_H,
                                        sx, sy, ndcZ)) { allOk = false; break; }
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
                float bufDepth = readDepth(WIN_W, WIN_H, fbW, fbH, cx, cy);
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

        // ---- ImGui draw ----
        ImGui_ImplOpenGL3_RenderDrawData(ImGui.GetDrawData());

        SDL_GL_SwapWindow(window);
    }
}
