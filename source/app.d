import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln;
import std.math : tan, sin, cos, sqrt, PI;

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

Vec3 vec3Add(Vec3 a, Vec3 b) { return Vec3(a.x+b.x, a.y+b.y, a.z+b.z); }
Vec3 vec3Sub(Vec3 a, Vec3 b) { return Vec3(a.x-b.x, a.y-b.y, a.z-b.z); }
Vec3 vec3Scale(Vec3 v, float s) { return Vec3(v.x*s, v.y*s, v.z*s); }

Vec3 normalize(Vec3 v) {
    float len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z);
    return Vec3(v.x/len, v.y/len, v.z/len);
}

Vec3 cross(Vec3 a, Vec3 b) {
    return Vec3(a.y*b.z - a.z*b.y,
                a.z*b.x - a.x*b.z,
                a.x*b.y - a.y*b.x);
}

float dot(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }

float[16] lookAt(Vec3 eye, Vec3 center, Vec3 worldUp) {
    Vec3 f = normalize(vec3Sub(center, eye));
    Vec3 r = normalize(cross(f, worldUp));
    Vec3 u = cross(r, f);
    return [
         r.x,  u.x, -f.x, 0,
         r.y,  u.y, -f.y, 0,
         r.z,  u.z, -f.z, 0,
        -dot(r, eye), -dot(u, eye), dot(f, eye), 1,
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

Vec3 sphericalToCartesian(float azimuth, float elevation, float distance) {
    return Vec3(
        distance * cos(elevation) * sin(azimuth),
        distance * sin(elevation),
        distance * cos(elevation) * cos(azimuth),
    );
}

// ---------------------------------------------------------------------------
// Mesh — хранит геометрию в терминах точек, рёбер и полигонов
// ---------------------------------------------------------------------------

struct Mesh {
    Vec3[]    vertices;   // позиции вершин
    uint[2][] edges;      // рёбра: пары индексов вершин
    uint[][]  faces;      // полигоны: список индексов вершин (convex)

    // Добавить вершину, вернуть её индекс
    uint addVertex(Vec3 v) {
        vertices ~= v;
        return cast(uint)(vertices.length - 1);
    }

    // Добавить ребро (без дублирования)
    void addEdge(uint a, uint b) {
        foreach (e; edges)
            if ((e[0]==a && e[1]==b) || (e[0]==b && e[1]==a)) return;
        edges ~= [a, b];
    }

    // Добавить полигон и автоматически создать все рёбра по периметру
    void addFace(uint[] indices) {
        faces ~= indices.dup;
        for (uint i = 0; i < indices.length; i++)
            addEdge(indices[i], indices[(i+1) % indices.length]);
    }

    void clear() {
        vertices = [];
        edges    = [];
        faces    = [];
    }
}

// Заполнить меш единичным кубом (8 вершин, 12 рёбер, 6 quad-граней)
Mesh makeCube() {
    Mesh m;
    //        7----6
    //       /|   /|
    //      4----5 |
    //      | 3--|-2
    //      |/   |/
    //      0----1
    m.vertices = [
        Vec3(-0.5f, -0.5f, -0.5f), // 0  bottom-back-left
        Vec3( 0.5f, -0.5f, -0.5f), // 1  bottom-back-right
        Vec3( 0.5f,  0.5f, -0.5f), // 2  top-back-right
        Vec3(-0.5f,  0.5f, -0.5f), // 3  top-back-left
        Vec3(-0.5f, -0.5f,  0.5f), // 4  bottom-front-left
        Vec3( 0.5f, -0.5f,  0.5f), // 5  bottom-front-right
        Vec3( 0.5f,  0.5f,  0.5f), // 6  top-front-right
        Vec3(-0.5f,  0.5f,  0.5f), // 7  top-front-left
    ];
    // 6 граней куба (обход против часовой стрелки снаружи)
    m.addFace([0, 3, 2, 1]); // back
    m.addFace([4, 5, 6, 7]); // front
    m.addFace([0, 4, 7, 3]); // left
    m.addFace([1, 2, 6, 5]); // right
    m.addFace([3, 7, 6, 2]); // top
    m.addFace([0, 1, 5, 4]); // bottom
    return m;
}

// ---------------------------------------------------------------------------
// GpuMesh — загружает Mesh на GPU в два VAO/VBO (грани + рёбра)
// ---------------------------------------------------------------------------

struct GpuMesh {
    GLuint faceVao, faceVbo;
    GLuint edgeVao, edgeVbo;
    int    faceVertCount;
    int    edgeVertCount;

    void init() {
        glGenVertexArrays(1, &faceVao);
        glGenBuffers(1, &faceVbo);
        glGenVertexArrays(1, &edgeVao);
        glGenBuffers(1, &edgeVbo);
    }

    void destroy() {
        glDeleteVertexArrays(1, &faceVao);
        glDeleteBuffers(1, &faceVbo);
        glDeleteVertexArrays(1, &edgeVao);
        glDeleteBuffers(1, &edgeVbo);
    }

    // Перезалить данные из Mesh (вызывать при изменении меша)
    void upload(ref const Mesh mesh) {
        // --- Грани: fan-триангуляция каждого полигона ---
        float[] faceData;
        foreach (face; mesh.faces) {
            if (face.length < 3) continue;
            for (uint i = 1; i + 1 < face.length; i++) {
                Vec3 v0 = mesh.vertices[face[0]];
                Vec3 v1 = mesh.vertices[face[i]];
                Vec3 v2 = mesh.vertices[face[i + 1]];
                faceData ~= [v0.x, v0.y, v0.z,
                             v1.x, v1.y, v1.z,
                             v2.x, v2.y, v2.z];
            }
        }
        faceVertCount = cast(int)(faceData.length / 3);

        glBindVertexArray(faceVao);
        glBindBuffer(GL_ARRAY_BUFFER, faceVbo);
        glBufferData(GL_ARRAY_BUFFER, faceData.length * float.sizeof,
                     faceData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        // --- Рёбра ---
        float[] edgeData;
        foreach (edge; mesh.edges) {
            Vec3 v0 = mesh.vertices[edge[0]];
            Vec3 v1 = mesh.vertices[edge[1]];
            edgeData ~= [v0.x, v0.y, v0.z,
                         v1.x, v1.y, v1.z];
        }
        edgeVertCount = cast(int)(edgeData.length / 3);

        glBindVertexArray(edgeVao);
        glBindBuffer(GL_ARRAY_BUFFER, edgeVbo);
        glBufferData(GL_ARRAY_BUFFER, edgeData.length * float.sizeof,
                     edgeData.ptr, GL_DYNAMIC_DRAW);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
                              3 * float.sizeof, cast(void*)0);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
    }

    void draw(GLuint program, GLint locColor) {
        // Грани — сдвиг назад чтобы рёбра не z-fighting
        glEnable(GL_POLYGON_OFFSET_FILL);
        glPolygonOffset(1.0f, 1.0f);
        glUniform3f(locColor, 0.25f, 0.45f, 0.75f); // синеватые грани
        glBindVertexArray(faceVao);
        glDrawArrays(GL_TRIANGLES, 0, faceVertCount);
        glDisable(GL_POLYGON_OFFSET_FILL);

        // Рёбра поверх
        glUniform3f(locColor, 0.9f, 0.9f, 0.9f); // светло-серые рёбра
        glBindVertexArray(edgeVao);
        glDrawArrays(GL_LINES, 0, edgeVertCount);

        glBindVertexArray(0);
    }
}

// ---------------------------------------------------------------------------
// Shader helpers
// ---------------------------------------------------------------------------

GLuint compileShader(GLenum type, string src) {
    GLuint shader = glCreateShader(type);
    const(char)* srcPtr = src.toStringz();
    glShaderSource(shader, 1, &srcPtr, null);
    glCompileShader(shader);
    GLint ok;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char[512] log;
        glGetShaderInfoLog(shader, 512, null, log.ptr);
        import std.conv : to;
        throw new Exception("Shader compile error: " ~ log[].to!string);
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
        throw new Exception("Program link error: " ~ log[].to!string);
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

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        writefln("SDL_Init error: %s", SDL_GetError()); return;
    }
    scope(exit) SDL_Quit();

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);

    SDL_Window* window = SDL_CreateWindow(
        "OpenGL Mesh  |  Alt+drag=orbit  Alt+Shift+drag=pan  Ctrl+Alt+drag=zoom",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 800, 600,
        SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN
    );
    if (!window) { writefln("SDL_CreateWindow error: %s", SDL_GetError()); return; }
    scope(exit) SDL_DestroyWindow(window);

    SDL_GLContext ctx = SDL_GL_CreateContext(window);
    if (!ctx) { writefln("SDL_GL_CreateContext error: %s", SDL_GetError()); return; }
    scope(exit) SDL_GL_DeleteContext(ctx);

    if (loadOpenGL() < glSupport) { writeln("Failed to load OpenGL 3.3"); return; }
    writefln("OpenGL version: %s", glGetString(GL_VERSION));

    SDL_GL_SetSwapInterval(1);
    glEnable(GL_DEPTH_TEST);

    GLuint program  = createProgram();
    scope(exit) glDeleteProgram(program);

    GLint locView  = glGetUniformLocation(program, "u_view");
    GLint locProj  = glGetUniformLocation(program, "u_proj");
    GLint locColor = glGetUniformLocation(program, "u_color");

    // Меш — куб при старте
    Mesh mesh = makeCube();
    writefln("Mesh: %d vertices, %d edges, %d faces",
             mesh.vertices.length, mesh.edges.length, mesh.faces.length);

    GpuMesh gpu;
    gpu.init();
    scope(exit) gpu.destroy();
    gpu.upload(mesh);

    // Camera
    float azimuth   =  0.5f;
    float elevation =  0.4f;
    float distance  =  3.0f;
    Vec3  focus     = Vec3(0, 0, 0);
    immutable float minDist = 0.5f;
    immutable float maxDist = 50.0f;
    immutable float maxElev = cast(float)(89.0f * PI / 180.0f);

    enum DragMode { None, Orbit, Zoom, Pan }
    DragMode dragMode = DragMode.None;
    int lastMouseX, lastMouseY;

    bool running = true;
    SDL_Event event;

    while (running) {
        while (SDL_PollEvent(&event)) {
            switch (event.type) {
                case SDL_QUIT:
                    running = false;
                    break;

                case SDL_KEYDOWN:
                    if (event.key.keysym.sym == SDLK_ESCAPE)
                        running = false;
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
                        SDL_Keymod mods  = SDL_GetModState();
                        bool ctrl  = (mods & KMOD_CTRL)  != 0;
                        bool alt   = (mods & KMOD_ALT)   != 0;
                        bool shift = (mods & KMOD_SHIFT)  != 0;

                        bool modOk = (dragMode == DragMode.Zoom)  ? (ctrl && alt)
                                   : (dragMode == DragMode.Pan)   ? (alt && shift)
                                   : (dragMode == DragMode.Orbit) ? (alt && !shift)
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
                        } else { // Pan
                            Vec3 offset  = sphericalToCartesian(azimuth, elevation, distance);
                            Vec3 forward = normalize(Vec3(-offset.x, -offset.y, -offset.z));
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

        glClearColor(0.12f, 0.12f, 0.12f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        glUseProgram(program);

        Vec3 offset = sphericalToCartesian(azimuth, elevation, distance);
        Vec3 eye    = vec3Add(focus, offset);
        auto view   = lookAt(eye, focus, Vec3(0, 1, 0));
        auto proj   = perspectiveMatrix(45.0f * PI / 180.0f, 800.0f / 600.0f, 0.1f, 100.0f);
        glUniformMatrix4fv(locView, 1, GL_FALSE, view.ptr);
        glUniformMatrix4fv(locProj, 1, GL_FALSE, proj.ptr);

        gpu.draw(program, locColor);

        SDL_GL_SwapWindow(window);
    }
}
