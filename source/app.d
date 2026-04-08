import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv;

// HTTP server module
import http_server;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import d_imgui.imgui_demo;
import imgui_impl_sdl2;
import imgui_impl_opengl3;
import nfde;

import math;
import mesh;
import eventlog;
import handler;
import tool;
import editmode;
import gizmo;
import view;
import shader;
import viewcache;
import lwo;

import tools.move;
import tools.scale;
import tools.rotate;
import tools.box;

import commands.select.connect;
import commands.select.expand;
import commands.select.contract;
import commands.select.loop;
import commands.viewport.fit_selected;
import commands.viewport.fit;


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
// Module-level helpers
// ---------------------------------------------------------------------------

private ulong edgeKey(uint a, uint b) {
    uint lo = a < b ? a : b, hi = a < b ? b : a;
    return (cast(ulong)lo << 32) | hi;
}

private int countSelected(bool[] sel) {
    int n = 0;
    foreach (s; sel) if (s) n++;
    return n;
}


private string buildJsonArray(bool[] sel) {
    import std.array : appender;
    import std.format : format;
    auto buf = appender!string();
    buf ~= "[";
    bool first = true;
    foreach (i, s; sel) {
        if (!s) continue;
        if (!first) buf ~= ",";
        buf ~= format("%d", i);
        first = false;
    }
    buf ~= "]";
    return buf.data;
}

private bool[] computeVisibleVertices(ref Mesh mesh, ref View cameraView) {
    bool[] vertexVisible = new bool[](mesh.vertices.length);
    foreach (face; mesh.faces) {
        if (face.length < 3) continue;
        Vec3 fv0 = mesh.vertices[face[0]];
        Vec3 fv1 = mesh.vertices[face[1]];
        Vec3 fv2 = mesh.vertices[face[2]];
        Vec3 fn = cross(vec3Sub(fv1, fv0), vec3Sub(fv2, fv0));
        if (dot(fn, vec3Sub(fv0, cameraView.eye)) >= 0) continue;
        foreach (vi; face) vertexVisible[vi] = true;
    }
    return vertexVisible;
}


// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main(string[] args) {
    // Parse --playback <file> flag
    string playbackFile;
    bool startHttpServer = true;  // Enable HTTP server by default
    bool testMode = false;
    ushort httpPort = 8080;       // Default port

    for (size_t i = 1; i < args.length; ++i) {
        if (args[i] == "--playback") {
            if (i + 1 >= args.length) {
                writeln("Error: --playback requires a file argument");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            playbackFile = args[++i];
        } else if (args[i] == "--test") {
            testMode = true;
        } else if (args[i] == "--no-http") {
            startHttpServer = false;
        } else if (args[i] == "--http-port") {
            if (i + 1 >= args.length) {
                writeln("Error: --http-port requires a port number");
                import core.stdc.stdlib : exit;
                exit(1);
            }
            httpPort = cast(ushort)args[++i].to!int;
        } else {
            writefln("Error: unknown argument '%s'", args[i]);
            import core.stdc.stdlib : exit;
            exit(1);
        }
    }
    bool playbackMode = playbackFile.length > 0;

    if (loadSDL() != sdlSupport) { writeln("Failed to load SDL2"); return; }
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { writefln("SDL_Init: %s", SDL_GetError()); return; }
    scope(exit) SDL_Quit();

    // Initialize HTTP server
    HttpServer httpServer;
    if (startHttpServer) {
        httpServer = new HttpServer(httpPort);
        if (testMode) {
            httpServer.setTestMode(true);
            mouseOverride();
        }
        httpServer.start();
        writeln("HTTP server starting on port ", httpPort);
    }
    scope(exit) {
        if (httpServer !is null && httpServer.running) {
            httpServer.stop();
        }
    }

    EventLogger evLog;
    if (!playbackMode) {
        evLog.open("events.log");
    }
    scope(exit) evLog.close();

    EventLogger recLog;   // F1/F2 recording for MCP tests
    scope(exit) recLog.close();

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

    version (OSX) {
        // Make the app appear in the Dock and Command-Tab switcher when launched from terminal.
        import core.attribute : selector;
        extern (Objective-C) interface NSApplication {
            static NSApplication sharedApplication() @selector("sharedApplication");
            void setActivationPolicy(int policy) @selector("setActivationPolicy:");
            void activateIgnoringOtherApps(bool flag) @selector("activateIgnoringOtherApps:");
        }
        NSApplication.sharedApplication.setActivationPolicy(0); // NSApplicationActivationPolicyRegular
        NSApplication.sharedApplication.activateIgnoringOtherApps(true);
    }

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

    Shader shader = new Shader();
    LitShader litShader = new LitShader();

    GLuint thickLineProgram = createProgramWithGeom(vertexShaderSrc, thickLineGeomSrc, fragmentShaderSrc);
    scope(exit) glDeleteProgram(thickLineProgram);
    initThickLineProgram(thickLineProgram, fbW, fbH);

    CheckerShader checkerShader = new CheckerShader();
    GridShader gridShader = new GridShader();

    Mesh mesh = makeCube();
    writefln("Mesh: %d verts, %d edges, %d faces",
             mesh.vertices.length, mesh.edges.length, mesh.faces.length);

    enum int PANEL_W  = 150;
    enum int STATUS_H = 38;

    // Camera
    View cameraView = new View(PANEL_W, 0, winW - PANEL_W, winH - STATUS_H);

    VertexCache vertexCache;
    vertexCache.resize(mesh.vertices.length);

    FaceBoundsCache faceCache;
    faceCache.resize(mesh.vertices.length, mesh.faces.length);

    EdgeCache edgeCache;
    edgeCache.resize(mesh.edges.length);

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

    // Selection state
    int hoveredVertex = -1;
    int hoveredEdge   = -1;
    int hoveredFace   = -1;
    mesh.resetSelection();

    // Cache: face→edge mask for Polygons mode edge highlighting.
    // Rebuilt only when selectedFaces changes (comparison is a fast memcmp).
    bool[] faceSelEdgesCache;
    bool[] faceSelEdgesPrevSel;  // snapshot of selectedFaces at last rebuild

    DragMode dragMode = DragMode.None;
    EditMode editMode = EditMode.Vertices;

    // Gizmo size: 9 levels linearly spaced from 0.1 to 1.0; default = middle (index 4).
    enum float[9] gizmoLevels = [0.10f, 0.2125f, 0.325f, 0.4375f, 0.55f,
                                  0.6625f, 0.775f, 0.8875f, 1.0f];
    int gizmoLevelIdx = 4;  // middle

    // Set up HTTP server model data provider
    if (httpServer !is null) {
        // Convert mesh vertices to flat float array for HTTP server
        float[] getMeshVertices() {
            float[] verts = new float[](mesh.vertices.length * 3);
            for (size_t i = 0; i < mesh.vertices.length; i++) {
                verts[i * 3] = mesh.vertices[i].x;
                verts[i * 3 + 1] = mesh.vertices[i].y;
                verts[i * 3 + 2] = mesh.vertices[i].z;
            }
            return verts;
        }

        httpServer.setDetailedModelDataProvider((float[] vertices, uint[][] faces) {
            return meshToJsonDetailed(mesh.vertices.length, mesh.edges.length, mesh.faces.length, vertices, faces);
        }, getMeshVertices(), mesh.faces);
        httpServer.setCameraDataProvider(() => cameraView.toJson());
        httpServer.setSelectionDataProvider(() {
            import std.format : format;
            string modeName;
            final switch (editMode) {
                case EditMode.Vertices: modeName = "vertices"; break;
                case EditMode.Edges:    modeName = "edges";    break;
                case EditMode.Polygons: modeName = "polygons"; break;
            }
            return format(`{"mode":"%s","selectedVertices":%s,"selectedEdges":%s,"selectedFaces":%s}`,
                modeName,
                buildJsonArray(mesh.selectedVertices),
                buildJsonArray(mesh.selectedEdges),
                buildJsonArray(mesh.selectedFaces));
        });
        httpServer.setRecordedEventsProvider(() {
            import std.file : exists, readText;
            if (!exists("recording.jsonl")) return null;
            return readText("recording.jsonl");
        });
        httpServer.setResetHandler(() {
            mesh = makeCube();
            cameraView.reset();
            mesh.resetSelection();
            gpu.upload(mesh);
            vertexCache.resize(mesh.vertices.length);
            vertexCache.invalidate();
            faceCache.resize(mesh.vertices.length, mesh.faces.length);
            faceCache.invalidate();
            edgeCache.resize(mesh.edges.length);
            edgeCache.invalidate();
        });
    }


    Tool activeTool = null;

    scope(exit) {
        if (activeTool) { activeTool.deactivate(); activeTool.destroy(); }
    }

    void setActiveTool(Tool t) {
        if (activeTool) { activeTool.deactivate(); activeTool.destroy(); }
        activeTool = t;
        if (activeTool) activeTool.activate();
        // deactivate() may have added geometry — sync selection arrays and caches.
        mesh.syncSelection();
        if (vertexCache.valid.length != mesh.vertices.length) {
            vertexCache.resize(mesh.vertices.length);
            vertexCache.invalidate();
            faceCache.resize(mesh.vertices.length, mesh.faces.length);
            faceCache.invalidate();
        }
        if (edgeCache.valid.length != mesh.edges.length) {
            edgeCache.resize(mesh.edges.length);
            edgeCache.invalidate();
        }
    }

    int lastMouseX, lastMouseY;

    bool running = true;
    SDL_Event event;

    // -------------------------------------------------------------------------
    // Nested helpers — closures over main's locals
    // -------------------------------------------------------------------------

    void handleWindowEvent(ref SDL_WindowEvent we) {
        if (we.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
            if (playbackMode)
                SDL_SetWindowSize(window, we.data1, we.data2);
            SDL_GetWindowSize(window, &winW, &winH);
            SDL_GL_GetDrawableSize(window, &fbW, &fbH);
            glViewport(0, 0, fbW, fbH);
            initThickLineProgram(thickLineProgram, fbW, fbH);
        }
    }

    void handleKeyDown(ref SDL_KeyboardEvent kev) {
        bool shift = (kev.keysym.mod & KMOD_SHIFT) != 0;
        switch (kev.keysym.sym) {
            case SDLK_F1:
                recLog.close();
                recLog.open("recording.jsonl");
                stderr.writeln("[REC] started → recording.jsonl");
                break;
            case SDLK_F2:
                recLog.close();
                stderr.writeln("[REC] stopped");
                break;
            case SDLK_ESCAPE: running = false;                             break;
            case SDLK_1:      setActiveTool(null); editMode = EditMode.Vertices; break;
            case SDLK_2:      setActiveTool(null); editMode = EditMode.Edges;    break;
            case SDLK_3:      setActiveTool(null); editMode = EditMode.Polygons; break;
            case SDLK_SPACE:
                if (activeTool) setActiveTool(null);
                else editMode = cast(EditMode)((cast(int)editMode + 1) % 3);
                break;
            case SDLK_w:
                setActiveTool(cast(MoveTool)activeTool ? null
                    : new MoveTool(&mesh, &gpu, &editMode));
                break;
            case SDLK_r:
                setActiveTool(cast(ScaleTool)activeTool ? null
                    : new ScaleTool(&mesh, &gpu, &editMode));
                break;
            case SDLK_e:
                setActiveTool(cast(RotateTool)activeTool ? null
                    : new RotateTool(&mesh, &gpu, &editMode));
                break;
            case SDLK_b:
                setActiveTool(cast(BoxTool)activeTool ? null
                    : new BoxTool(&mesh, &gpu, litShader));
                break;
            case SDLK_a: {
                if (shift) {
                    new FitSelected(mesh, cameraView, editMode).apply();
                } else {
                    new Fit(mesh, cameraView, editMode).apply();
                }
                break;
            }
            case SDLK_RIGHTBRACKET: {
                new SelectConnect(mesh, cameraView, editMode).apply();
                // run command: select.connect
                break;
            }
            case SDLK_UP: {
                if (shift) {
                    new SelectionExpand(mesh, cameraView, editMode).apply();
                    // run command: select.expand
                }
                break;
            }
            case SDLK_DOWN: {
                if (shift) {
                    new SelectionContract(mesh, cameraView, editMode).apply();
                    // run command: select.contract
                }
                break;
            }
            case SDLK_l: {
                new SelectLoop(mesh, cameraView, editMode).apply();
                // run command: select.loop
                break;
            }
            case SDLK_d: {
                if (shift) {
                    setActiveTool(null);
                    mesh = catmullClark(mesh);
                    mesh.resetSelection();
                    gpu.upload(mesh);
                    vertexCache.resize(mesh.vertices.length);
                    vertexCache.invalidate();
                    faceCache.resize(mesh.vertices.length, mesh.faces.length);
                    faceCache.invalidate();
                    edgeCache.resize(mesh.edges.length);
                    edgeCache.invalidate();
                }
                break;
            }
            case SDLK_MINUS:
                if (gizmoLevelIdx > 0) {
                    --gizmoLevelIdx;
                    setGizmoScreenFraction(gizmoLevels[gizmoLevelIdx]);
                }
                break;
            case SDLK_EQUALS:
                if (gizmoLevelIdx < cast(int)gizmoLevels.length - 1) {
                    ++gizmoLevelIdx;
                    setGizmoScreenFraction(gizmoLevels[gizmoLevelIdx]);
                }
                break;
            default: break;
        }
    }

    void handleMouseButtonDown(ref SDL_MouseButtonEvent btn) {
        if (activeTool && activeTool.onMouseButtonDown(btn)) return;
        if (btn.button == SDL_BUTTON_LEFT) {
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
                    mesh.selectedVertices[] = false;
                else if (editMode == EditMode.Edges)
                    mesh.selectedEdges[] = false;
                else if (editMode == EditMode.Polygons) {
                    mesh.selectedFaces[] = false;
                    mesh.faceSelectionOrder[] = 0;
                    mesh.selectionOrderCounter = 0;
                }
                dragMode = DragMode.Select;
            }
            lastMouseX = btn.x;
            lastMouseY = btn.y;
        }
    }

    void handleMouseButtonUp(ref SDL_MouseButtonEvent btn) {
        if (activeTool) activeTool.onMouseButtonUp(btn);
        // When BoxTool commits a new face, resize selection + caches.
        {
            BoxTool bt = cast(BoxTool)activeTool;
            if (bt !is null && bt.meshChanged) {
                bt.meshChanged = false;
                mesh.syncSelection();
                vertexCache.resize(mesh.vertices.length);
                vertexCache.invalidate();
                faceCache.resize(mesh.vertices.length, mesh.faces.length);
                faceCache.invalidate();
                edgeCache.resize(mesh.edges.length);
                edgeCache.invalidate();
            }
        }
        if (btn.button == SDL_BUTTON_LEFT)
            dragMode = DragMode.None;
    }

    void handleMouseMotion(ref SDL_MouseMotionEvent mot) {
        if (activeTool && activeTool.onMouseMotion(mot)) return;
        if (dragMode == DragMode.None) return;

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
        if (!modOk) { dragMode = DragMode.None; return; }

        int dx = mot.x - lastMouseX;
        int dy = mot.y - lastMouseY;

        if      (dragMode == DragMode.Orbit) cameraView.orbit(dx, dy);
        else if (dragMode == DragMode.Zoom)  cameraView.zoom(dx);
        else if (dragMode == DragMode.Pan)   cameraView.pan(dx, dy);

        lastMouseX = mot.x;
        lastMouseY = mot.y;
    }

    void pickVertices(ref Viewport vp, bool doingCameraDrag) {
        hoveredVertex = -1;
        if (io.WantCaptureMouse || doingCameraDrag ||
            editMode != EditMode.Vertices || activeTool !is null)
            return;

        int mx, my;
        queryMouse(mx, my);
        float closestSq = 9.0f;  // 3.0f^2
        int candidate = -1;

        // A vertex is visible if at least one adjacent face is front-facing.
        // Geometry-exact: replaces unreliable depth-buffer test (near=0.001).
        bool[] vertexVisible = computeVisibleVertices(mesh, cameraView);

        foreach_reverse (i; 0 .. mesh.vertices.length) {
            if (!vertexVisible[i]) continue;

            if (!vertexCache.valid[i]) {
                if (!projectToWindow(mesh.vertices[i], vp,
                                    vertexCache.sx[i], vertexCache.sy[i], vertexCache.ndcZ[i])) {
                    vertexCache.valid[i] = false;
                    continue;
                }
                vertexCache.valid[i] = true;
            }

            float dx = vertexCache.sx[i] - mx;
            float dy = vertexCache.sy[i] - my;
            float d2 = dx*dx + dy*dy;
            if (d2 >= closestSq) continue;

            closestSq = d2;
            candidate = cast(int)i;
        }

        if (candidate >= 0) {
            hoveredVertex = candidate;
            if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
                mesh.selectedVertices[hoveredVertex] = true;
            else if (dragMode == DragMode.SelectRemove)
                mesh.selectedVertices[hoveredVertex] = false;
        }
    }

    void pickEdges(ref Viewport vp, bool doingCameraDrag) {
        hoveredEdge = -1;
        if (io.WantCaptureMouse || doingCameraDrag ||
            editMode != EditMode.Edges || activeTool !is null)
            return;

        int mx, my;
        queryMouse(mx, my);
        float closest = 4.0f;  // pixel radius for edges
        float closestSq = closest * closest;

        // A vertex is visible if at least one adjacent face is front-facing.
        // Computed once here — O(faces), replaces unreliable depth-buffer test.
        bool[] vertexVisible = computeVisibleVertices(mesh, cameraView);

        foreach (i; 0 .. mesh.edges.length) {
            uint a = mesh.edges[i][0], b = mesh.edges[i][1];

            // Edge is selectable only if both endpoints are visible.
            if (!vertexVisible[a] || !vertexVisible[b]) continue;

            // Use vertex cache to avoid duplicate projections
            if (!vertexCache.valid[a]) {
                if (!projectToWindow(mesh.vertices[a], vp,
                                      vertexCache.sx[a], vertexCache.sy[a], vertexCache.ndcZ[a])) {
                    vertexCache.valid[a] = false;
                    continue;
                }
                vertexCache.valid[a] = true;
            }
            if (!vertexCache.valid[b]) {
                if (!projectToWindow(mesh.vertices[b], vp,
                                      vertexCache.sx[b], vertexCache.sy[b], vertexCache.ndcZ[b])) {
                    vertexCache.valid[b] = false;
                    continue;
                }
                vertexCache.valid[b] = true;
            }

            // Quick bounding rectangle check (O(1) vs O(1) for segment distance)
            float minX, maxX, minY, maxY;
            if (vertexCache.sx[a] < vertexCache.sx[b]) { minX = vertexCache.sx[a]; maxX = vertexCache.sx[b]; }
            else                                        { minX = vertexCache.sx[b]; maxX = vertexCache.sx[a]; }
            if (vertexCache.sy[a] < vertexCache.sy[b]) { minY = vertexCache.sy[a]; maxY = vertexCache.sy[b]; }
            else                                        { minY = vertexCache.sy[b]; maxY = vertexCache.sy[a]; }

            float boundsMargin = closest;
            if (mx < minX - boundsMargin || mx > maxX + boundsMargin ||
                my < minY - boundsMargin || my > maxY + boundsMargin)
                continue;  // mouse far from this edge's bounding box

            // Now check distance to line segment (expensive operation)
            float t;
            float d2 = closestOnSegment2DSquared(cast(float)mx, cast(float)my,
                                                  vertexCache.sx[a], vertexCache.sy[a],
                                                  vertexCache.sx[b], vertexCache.sy[b], t);
            if (d2 >= closestSq) continue;

            closestSq = d2;
            hoveredEdge = cast(int)i;
        }

        if (hoveredEdge >= 0) {
            if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
                mesh.selectedEdges[hoveredEdge] = true;
            else if (dragMode == DragMode.SelectRemove)
                mesh.selectedEdges[hoveredEdge] = false;
        }
    }

    void pickFaces(ref Viewport vp, bool doingCameraDrag) {
        hoveredFace = -1;
        if (io.WantCaptureMouse || doingCameraDrag ||
            editMode != EditMode.Polygons || activeTool !is null)
            return;

        int mx, my;
        queryMouse(mx, my);
        float bestZ = float.infinity;

        // Quick screen-space bounds check first (if cache available)
        bool useBoundsCache = faceCache.minX.length >= mesh.faces.length;

        foreach (fi; 0 .. mesh.faces.length) {
            uint[] face = mesh.faces[fi];
            if (face.length < 3) continue;

            // Back-face culling: skip faces whose normal points away from camera.
            {
                Vec3 v0 = mesh.vertices[face[0]];
                Vec3 v1 = mesh.vertices[face[1]];
                Vec3 v2 = mesh.vertices[face[2]];
                Vec3 n = cross(vec3Sub(v1, v0), vec3Sub(v2, v0));
                if (dot(n, vec3Sub(v0, cameraView.eye)) >= 0) continue;
            }

            // Quick bounds check if cached — avoids expensive projection.
            if (useBoundsCache && faceCache.valid[fi]) {
                if (mx < faceCache.minX[fi] || mx > faceCache.maxX[fi] ||
                    my < faceCache.minY[fi] || my > faceCache.maxY[fi])
                    continue;
            }

            // Project all vertices of this face (reuse vertex cache).
            int len = cast(int)face.length;
            float[] tempSx = new float[](len);
            float[] tempSy = new float[](len);
            bool allOk = true;
            for (int j = 0; j < len; j++) {
                uint vi = face[j];
                if (!vertexCache.valid[vi]) {
                    // Use projectToWindowFull so off-screen vertices are still
                    // projected; only vertices behind the camera (w<=0) are rejected.
                    float sx, sy, ndcZ;
                    if (!projectToWindowFull(mesh.vertices[vi], vp, sx, sy, ndcZ)) {
                        allOk = false;
                        break;
                    }
                    vertexCache.sx[vi] = sx;
                    vertexCache.sy[vi] = sy;
                    vertexCache.ndcZ[vi] = ndcZ;
                    vertexCache.valid[vi] = true;
                }
                tempSx[j] = vertexCache.sx[vi];
                tempSy[j] = vertexCache.sy[vi];
            }
            if (!allOk) continue;

            // Compute and cache bounds if not yet cached; re-check bounds.
            if (useBoundsCache && !faceCache.valid[fi]) {
                float localMinX = float.infinity, localMaxX = -float.infinity;
                float localMinY = float.infinity, localMaxY = -float.infinity;
                foreach (sx; tempSx) { if (sx < localMinX) localMinX = sx; if (sx > localMaxX) localMaxX = sx; }
                foreach (sy; tempSy) { if (sy < localMinY) localMinY = sy; if (sy > localMaxY) localMaxY = sy; }
                faceCache.minX[fi] = localMinX; faceCache.maxX[fi] = localMaxX;
                faceCache.minY[fi] = localMinY; faceCache.maxY[fi] = localMaxY;
                faceCache.valid[fi] = true;
                if (mx < localMinX || mx > localMaxX || my < localMinY || my > localMaxY)
                    continue;
            }

            if (!pointInPolygon2D(cast(float)mx, cast(float)my, tempSx, tempSy)) continue;

            // Use centroid NDC-Z for occlusion ordering.
            float cZ = 0;
            for (int j = 0; j < len; j++) cZ += vertexCache.ndcZ[face[j]];
            cZ /= len;
            if (cZ < bestZ) { bestZ = cZ; hoveredFace = cast(int)fi; }
        }

        if (hoveredFace >= 0) {
            if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd) {
                if (!mesh.selectedFaces[hoveredFace])
                    mesh.faceSelectionOrder[hoveredFace] = ++mesh.selectionOrderCounter;
                mesh.selectedFaces[hoveredFace] = true;
            } else if (dragMode == DragMode.SelectRemove) {
                mesh.selectedFaces[hoveredFace] = false;
                mesh.faceSelectionOrder[hoveredFace] = 0;
            }
        }
    }

    void drawSidePanel() {
        int selCount     = countSelected(mesh.selectedVertices);
        int selEdgeCount = countSelected(mesh.selectedEdges);
        int selFaceCount = countSelected(mesh.selectedFaces);

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
            ImGui.Text("File");
            if (ImGui.Button("Load              ")) {
                string path;
                version (Windows)
                    auto result = openDialog(path, [FilterItem(cast(const(ushort)*)"LWO"w.ptr, cast(const(ushort)*)"lwo"w.ptr)]);
                else
                    auto result = openDialog(path, [FilterItem("LWO", "lwo")]);
                assert(result != Result.error, getError());
                if (path !is null) {
                    if (importLWO(path, mesh)) {
                        mesh.resetSelection();
                        gpu.upload(mesh);
                        vertexCache.resize(mesh.vertices.length);
                        vertexCache.invalidate();
                        faceCache.resize(mesh.vertices.length, mesh.faces.length);
                        faceCache.invalidate();
                        edgeCache.resize(mesh.edges.length);
                        edgeCache.invalidate();
                    }
                }
            }

            if (ImGui.Button("Save              ")) {
                string path;
                version (Windows)
                    auto result = saveDialog(path, [FilterItem(cast(const(ushort)*)"LWO"w.ptr, cast(const(ushort)*)"lwo"w.ptr)], "Untitled.lwo");
                else
                    auto result = saveDialog(path, [FilterItem("LWO", "lwo")], "Untitled.lwo");
                assert(result != Result.error, getError());
                if (path !is null) {
                    exportLWO(mesh, path);
                }
            }

            ImGui.Separator();
            ImGui.Text("Tools");
            {
                bool on = cast(MoveTool)activeTool !is null;
                if (on) ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                if (ImGui.Button("Move             W"))
                    setActiveTool(on ? null : new MoveTool(&mesh, &gpu, &editMode));
                if (on) ImGui.PopStyleColor();
            }
            {
                bool on = cast(RotateTool)activeTool !is null;
                if (on) ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                if (ImGui.Button("Rotate           E"))
                    setActiveTool(on ? null : new RotateTool(&mesh, &gpu, &editMode));
                if (on) ImGui.PopStyleColor();
            }
            {
                bool on = cast(ScaleTool)activeTool !is null;
                if (on) ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                if (ImGui.Button("Scale            R"))
                    setActiveTool(on ? null : new ScaleTool(&mesh, &gpu, &editMode));
                if (on) ImGui.PopStyleColor();
            }
            {
                bool on = cast(BoxTool)activeTool !is null;
                if (on) ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                if (ImGui.Button("Box              B"))
                    setActiveTool(on ? null : new BoxTool(&mesh, &gpu, litShader));
                if (on) ImGui.PopStyleColor();
            }

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
                    foreach (i; 0 .. mesh.selectedVertices.length) {
                        if (!mesh.selectedVertices[i]) continue;
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
                    foreach (i; 0 .. mesh.selectedEdges.length) {
                        if (!mesh.selectedEdges[i]) continue;
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
                    foreach (i; 0 .. mesh.selectedFaces.length) {
                        if (!mesh.selectedFaces[i]) continue;
                        ImGui.Text("  f%d  (%d verts)",
                            cast(int)i,
                            cast(int)mesh.faces[i].length);
                    }
                }
            }

            ImGui.Separator();
            ImGui.Text("Camera");
            ImGui.LabelText("Dist",  "%.2f", cameraView.distance);
            ImGui.LabelText("Az",    "%.1f°", cast(double)(cameraView.azimuth   * 180.0 / PI));
            ImGui.LabelText("El",    "%.1f°", cast(double)(cameraView.elevation * 180.0 / PI));

            ImGui.Separator();
            ImGui.TextDisabled("Alt+drag        orbit");
            ImGui.TextDisabled("Alt+Shift+drag  pan");
            ImGui.TextDisabled("Ctrl+Alt+drag   zoom");
            ImGui.TextDisabled("LMB / drag       select");
            ImGui.TextDisabled("Shift+LMB/drag   add to select");
            ImGui.TextDisabled("Ctrl+LMB/drag    remove from select");
        }
        ImGui.End();
    }

    void drawStatusBar() {
        ImGui.SetNextWindowPos(ImVec2(PANEL_W, winH - STATUS_H), ImGuiCond.Always);
        ImGui.SetNextWindowSize(ImVec2(winW - PANEL_W, STATUS_H), ImGuiCond.Always);
        if (ImGui.Begin("Status line", null,
                        ImGuiWindowFlags.NoTitleBar |
                        ImGuiWindowFlags.NoResize |
                        ImGuiWindowFlags.NoMove   |
                        ImGuiWindowFlags.NoCollapse))
        {
            {
                bool active = (editMode == EditMode.Vertices);
                if (active) ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                if (ImGui.Button("Vertices  1"))
                    { setActiveTool(null); editMode = EditMode.Vertices; }
                if (active) ImGui.PopStyleColor();
                ImGui.SameLine();
            }
            {
                bool active = (editMode == EditMode.Edges);
                if (active) ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                if (ImGui.Button("Edges     2"))
                    { setActiveTool(null); editMode = EditMode.Edges; }
                if (active) ImGui.PopStyleColor();
                ImGui.SameLine();
            }
            {
                bool active = (editMode == EditMode.Polygons);
                if (active) ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(0.9f, 0.5f, 0.1f, 1.0f));
                if (ImGui.Button("Polygons  3"))
                    { setActiveTool(null); editMode = EditMode.Polygons; }
                if (active) ImGui.PopStyleColor();
                ImGui.SameLine();
            }
        }
        ImGui.End();
    }

    // -------------------------------------------------------------------------
    // Main loop
    // -------------------------------------------------------------------------

    while (running) {
        // ---- Playback: push due events before polling ----
        if (playbackMode) evPlay.tick();
        if (httpServer !is null) {
            httpServer.tickEventPlayer();
            httpServer.tickReset();
        }

        // ---- Events ----
        while (SDL_PollEvent(&event)) {
            // Log to always-on log; log to recording only when active and not F1/F2.
            evLog.log(event);
            bool isF1orF2 = event.type == SDL_KEYDOWN &&
                (event.key.keysym.sym == SDLK_F1 || event.key.keysym.sym == SDLK_F2);
            if (!isF1orF2) recLog.log(event);
            ImGui_ImplSDL2_ProcessEvent(&event);

            if (io.WantCaptureMouse &&
                (event.type == SDL_MOUSEBUTTONDOWN ||
                 event.type == SDL_MOUSEBUTTONUP   ||
                 event.type == SDL_MOUSEMOTION      ||
                 event.type == SDL_MOUSEWHEEL))
                continue;

            if (io.WantTextInput &&
                (event.type == SDL_KEYDOWN || event.type == SDL_KEYUP))
                continue;

            switch (event.type) {
                case SDL_QUIT:            running = false;                      break;
                case SDL_WINDOWEVENT:     handleWindowEvent(event.window);      break;
                case SDL_KEYDOWN:         handleKeyDown(event.key);             break;
                case SDL_MOUSEBUTTONDOWN: handleMouseButtonDown(event.button);  break;
                case SDL_MOUSEBUTTONUP:   handleMouseButtonUp(event.button);    break;
                case SDL_MOUSEMOTION:     handleMouseMotion(event.motion);      break;
                default: break;
            }
        }


        cameraView.setSize(winW - PANEL_W, winH - STATUS_H);

        Viewport vp = cameraView.viewport();

        // ---- ImGui ----
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui.NewFrame();

        drawSidePanel();
        drawStatusBar();

        // ---- Tool Properties (floating) ----
        if (activeTool !is null) {
            ImGui.SetNextWindowPos(ImVec2(PANEL_W + 10, 10), ImGuiCond.FirstUseEver);
            ImGui.SetNextWindowSize(ImVec2(220, 110), ImGuiCond.FirstUseEver);
            if (ImGui.Begin("Tool Properties"))
                activeTool.drawProperties();
            ImGui.End();
        }

        // ShowDemoWindow();


        // ---- Gizmo 3D (orientation indicator, bottom-right of 3D view) ----
        DrawGizmo(PANEL_W + 32.0f, cameraView.height - STATUS_H - 32.0f, cameraView.view);

        // ---- Playback cursor overlay ----
        {
            int cursorX, cursorY;
            bool cursorDown;
            bool showCursor = false;
            if (playbackMode) {
                cursorX = evPlay.mouseX; cursorY = evPlay.mouseY;
                cursorDown = evPlay.mouseDown;
                showCursor = true;
            } else if (testMode && httpServer !is null) {
                cursorX = httpServer.playerMouseX();
                cursorY = httpServer.playerMouseY();
                cursorDown = httpServer.playerMouseDown();
                showCursor = true;
            }
            if (showCursor) {
                ImDrawList* dl = ImGui.GetForegroundDrawList();
                ImVec2 pos = ImVec2(cast(float)cursorX, cast(float)cursorY);
                dl.AddCircle(pos, 12.0f, IM_COL32(255, 220, 0, 220), 24, 2.0f);
                uint dotColor = cursorDown
                    ? IM_COL32(255, 80, 80, 255)
                    : IM_COL32(255, 255, 255, 200);
                dl.AddCircleFilled(pos, 3.0f, dotColor, 12);
            }
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
                   cast(int)(cameraView.width  * scaleX),
                   cast(int)(cameraView.height * scaleY));

        // When a tool defers GPU uploads (whole-mesh drag), apply the accumulated
        // transform as u_model so the mesh appears correctly without re-uploading
        // vertex data every frame.
        float[16] meshModel = identityMatrix;
        {
            MoveTool mt = cast(MoveTool)activeTool;
            if (mt !is null) {
                Vec3 off = mt.gpuOffset;
                if (off.x != 0 || off.y != 0 || off.z != 0)
                    meshModel = translationMatrix(off);
            } else {
                RotateTool rt = cast(RotateTool)activeTool;
                if (rt !is null) {
                    meshModel = rt.gpuMatrix;
                } else {
                    ScaleTool st = cast(ScaleTool)activeTool;
                    if (st !is null)
                        meshModel = st.gpuMatrix;
                }
            }
        }

        shader.useProgram(meshModel, cameraView);

        // ---- Grid axis lines (alpha-blended, distance + edge fade) ----
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        // glDepthMask(GL_FALSE);

        gridShader.useProgram(identityMatrix, cameraView,
            cameraView.distance * 2.0f,
            cast(float)cameraView.width * scaleX, cast(float)cameraView.height * scaleY,
            cast(float)PANEL_W  * scaleX, cast(float)STATUS_H * scaleY);

        glBindVertexArray(gridVao);
        // Grid lines — gray
        glUniform3f(gridShader.locColor, 0.5f, 0.5f, 0.5f);
        glDrawArrays(GL_LINES, 0, gridOnlyVertCount);
        // X axis — pale red
        glUniform3f(gridShader.locColor, 0.5f, 0.15f, 0.15f);
        glDrawArrays(GL_LINES, gridOnlyVertCount, 2);
        // Z axis — pale blue
        glUniform3f(gridShader.locColor, 0.15f, 0.15f, 0.5f);
        glDrawArrays(GL_LINES, gridOnlyVertCount + 2, 2);
        glBindVertexArray(0);

        // glDepthMask(GL_TRUE);
        glDisable(GL_BLEND);

        // Draw faces with Blinn-Phong lighting
        {
            litShader.useProgram(meshModel, cameraView);
            if (editMode == EditMode.Polygons)
                gpu.drawFacesHighlighted(litShader, hoveredFace, mesh.selectedFaces);
            else
                gpu.drawFaces(litShader);
        }

        // Checkerboard overlay for selected faces (Polygons mode).
        if (editMode == EditMode.Polygons) {
            if (mesh.hasAnySelectedFaces()) {
                checkerShader.useProgram(meshModel, cameraView, 1.0f, 0.5f, 0.1f);  // orange
                glDisable(GL_DEPTH_TEST);
                gpu.drawSelectedFacesOverlay(mesh.selectedFaces);
                glEnable(GL_DEPTH_TEST);
            }
        }

        shader.useProgram(meshModel, cameraView);

        bool doingCameraDrag = (dragMode == DragMode.Orbit ||
                                dragMode == DragMode.Zoom  ||
                                dragMode == DragMode.Pan);

        // Invalidate caches when tools are active (they modify mesh)
        if (activeTool !is null && (vertexCache.valid.length > 0)) {
            vertexCache.invalidate();
            edgeCache.invalidate();
            faceCache.invalidate();
            vertexCache.update(vp);
        } else if (!doingCameraDrag && vertexCache.needsUpdate(vp)) {
            vertexCache.invalidate();
            vertexCache.update(vp);
        }

        pickVertices(vp, doingCameraDrag);

        // Check if edge cache needs update due to camera movement
        if (!doingCameraDrag && edgeCache.needsUpdate(vp)) {
            edgeCache.invalidate();
            edgeCache.update(vp);
        }

        pickEdges(vp, doingCameraDrag);

        // Check if face cache needs update due to camera movement
        if (!doingCameraDrag && faceCache.needsUpdate(vp)) {
            faceCache.invalidate();
            faceCache.update(vp);
        }

        pickFaces(vp, doingCameraDrag);

        // ---- Draw edges (with highlights in Edges / Polygons mode) ----
        if (editMode == EditMode.Edges) {
            gpu.drawEdges(shader.locColor, hoveredEdge, mesh.selectedEdges);
        } else if (editMode == EditMode.Polygons) {
            // Build selected-edge mask — rebuild only when selectedFaces changes.
            if (faceSelEdgesPrevSel != mesh.selectedFaces) {
                faceSelEdgesPrevSel = mesh.selectedFaces.dup;
                if (faceSelEdgesCache.length != mesh.edges.length)
                    faceSelEdgesCache = new bool[](mesh.edges.length);
                faceSelEdgesCache[] = false;

                // Fast path: all faces selected → all edges selected.
                bool allSel = (countSelected(mesh.selectedFaces) == cast(int)mesh.selectedFaces.length);
                if (allSel) {
                    faceSelEdgesCache[] = true;
                } else {
                    if (mesh.hasAnySelectedFaces()) {
                        bool[ulong] edgeSet;
                        foreach (fi, face; mesh.faces) {
                            if (fi >= mesh.selectedFaces.length || !mesh.selectedFaces[fi]) continue;
                            for (size_t j = 0; j < face.length; j++) {
                                uint a = face[j], b = face[(j + 1) % face.length];
                                edgeSet[edgeKey(a, b)] = true;
                            }
                        }
                        foreach (ei, edge; mesh.edges) {
                            if (edgeKey(edge[0], edge[1]) in edgeSet)
                                faceSelEdgesCache[ei] = true;
                        }
                    }
                }
            }
            gpu.drawEdges(shader.locColor, -1, faceSelEdgesCache);
        } else {
            gpu.drawEdges(shader.locColor, -1, []);
        }

        // ---- Vertex dots (EditMode.Vertices only) ----
        if (editMode == EditMode.Vertices)
            gpu.drawVertices(shader.locColor, hoveredVertex, mesh.selectedVertices);

        // ---- Active tool ----
        if (activeTool) {
            activeTool.update();
            activeTool.draw(shader, vp);
        }

        // ---- ImGui draw ----
        // Restore full viewport for ImGui rendering.
        glViewport(0, 0, fbW, fbH);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui.GetDrawData());

        SDL_GL_SwapWindow(window);
    }
}
