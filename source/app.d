import bindbc.sdl;
import bindbc.opengl;
import std.string : toStringz;
import std.stdio : writeln, writefln, File, stderr;
import std.math : tan, sin, cos, sqrt, PI, abs;
import std.conv;
import std.json : JSONValue, JSONType;

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

import tools.transform;
import tools.move;
import tools.scale;
import tools.rotate;
import tools.box;
import tools.bevel;

import commands.select.connect;
import commands.select.expand;
import commands.select.contract;
import commands.select.loop;
import commands.select.ring;
import commands.select.invert;
import commands.select.more;
import commands.select.less;
import commands.select.between;
import commands.viewport.fit_selected;
import commands.viewport.fit;
import commands.file.load;
import commands.file.save;
import commands.mesh.subdivide;
import commands.mesh.subdivide_faceted;
import commands.mesh.subpatch_toggle;
import commands.mesh.bevel;
import commands.mesh.poly_bevel;
import commands.mesh.split_edge;
import commands.mesh.move_vertex;
import commands.mesh.bevel_edit : MeshBevelEdit;
import commands.mesh.select;
import commands.mesh.selection_edit : MeshSelectionEdit;
import commands.mesh.transform;
import commands.mesh.vertex_edit;
import commands.scene.reset;
import commands.history.undo : HistoryUndo;
import commands.history.redo : HistoryRedo;
import commands.history.show : HistoryShow;
import snapshot : SelectionSnapshot;

import command;
import registry;
import shortcuts;
import buttonset;

version (OSX) {
    import core.attribute : selector;
    extern (Objective-C) interface NSApplicationClass {
        NSApplication sharedApplication() @selector("sharedApplication");
    }
    extern (Objective-C) interface NSApplication {
        void setActivationPolicy(int policy) @selector("setActivationPolicy:");
        void activateIgnoringOtherApps(bool flag) @selector("activateIgnoringOtherApps:");
    }
    extern (C) NSApplicationClass objc_getClass(const(char)* name) nothrow @nogc;
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


// ---------------------------------------------------------------------------
// Panel layout
// ---------------------------------------------------------------------------

struct Layout {
    int sideW   = 150;
    int statusH = 28;

    ImVec2 sidePos;
    ImVec2 sideSize;
    ImVec2 tabPos;
    ImVec2 tabSize;
    ImVec2 statusPos;
    ImVec2 statusSize;

    int vpX, vpY, vpGlY, vpW, vpH;

    void resize(int winW, int winH) {
        sidePos    = ImVec2(0, 0);
        sideSize   = ImVec2(sideW, winH);
        tabPos     = ImVec2(sideW, 0);
        tabSize    = ImVec2(winW - sideW, statusH);
        statusPos  = ImVec2(sideW, winH - statusH);
        statusSize = ImVec2(winW - sideW, statusH);

        vpX   = sideW;
        vpY   = statusH;  // screen-space top edge (Y down), below tab bar
        vpGlY = statusH;  // OpenGL bottom edge (Y up), above status bar
        vpW   = winW - sideW;
        vpH   = winH - 2 * statusH;
    }
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
        "Vibe3d",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, winW, winH,
        SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE
    );
    if (!window) { writefln("SDL_CreateWindow: %s", SDL_GetError()); return; }
    scope(exit) SDL_DestroyWindow(window);

    version (OSX) {
        // Make the app appear in the Dock and Command-Tab switcher when launched from terminal.
        // Use metaclass interface + objc_getClass instead of static interface methods:
        // LDC2 dispatches static ObjC interface calls to the Protocol object, not the class.
        NSApplication app = objc_getClass("NSApplication").sharedApplication();
        app.setActivationPolicy(0); // NSApplicationActivationPolicyRegular
        app.activateIgnoringOtherApps(true);
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

    // Subpatch preview: cached subdivision of the cage mesh, rebuilt lazily
    // when mesh.mutationVersion or depth changes. Depth is user-adjustable;
    // 3 matches LightWave default. Consumed by rendering and picking in
    // subsequent steps.
    SubpatchPreview subpatchPreview;
    int             subpatchDepth = 3;

    // Tracks what is currently uploaded to the GPU so the main loop can
    // re-upload when the preview toggles on/off or when the cage changes
    // while the preview is active.
    ulong gpuUploadedVersion = ulong.max;
    bool  gpuUploadedPreview;

    Layout layout;
    layout.resize(winW, winH);

    // The editor uses a fixed fovY=45° everywhere (see source/view.d).
    enum float kFovY = 45.0f * 3.14159265358979f / 180.0f;

    // Now that the viewport is known, attach metadata to the always-on log
    // so it stays layout/aspect-independent on replay, and tell the player
    // what the current viewport looks like.
    if (evLog.active)
        evLog.writeViewportMeta(layout.vpX, layout.vpY, layout.vpW, layout.vpH, kFovY);
    setReplayCurrentViewport(layout.vpX, layout.vpY, layout.vpW, layout.vpH, kFovY);

    // Camera
    View cameraView = new View(layout.vpX, layout.vpY, layout.vpW, layout.vpH);

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
        foreach (x; -N .. N + 1) {
        // Lines parallel to Z axis (constant X), skip X=0 (that's the Z axis)
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
    int activePanelIdx = 0;

    // RMB path trail
    bool    rmbDragging = false;
    ImVec2[] rmbPath;

    // Phase C.x: interactive selection edit session. handleMouseButtonDown
    // captures the selection-snapshot before any picking/lasso/clear happens;
    // handleMouseButtonUp captures after, builds a MeshSelectionEdit, and
    // records on history if anything actually changed.
    SelectionSnapshot pendingSelBefore;
    EditMode          pendingSelBeforeMode;
    bool              pendingSelOpen = false;

    // Gizmo size: 9 levels linearly spaced from 0.1 to 1.0; default = middle (index 4).
    enum float[9] gizmoLevels = [0.10f, 0.2125f, 0.325f, 0.4375f, 0.55f,
                                  0.6625f, 0.775f, 0.8875f, 1.0f];
    int gizmoLevelIdx = 4;  // middle

    Tool   activeTool   = null;
    string activeToolId = "";

    scope(exit) {
        if (activeTool) { activeTool.deactivate(); activeTool.destroy(); }
    }
    void setActiveTool(Tool t) {
        if (activeTool) { activeTool.deactivate(); activeTool.destroy(); }
        activeTool   = t;
        activeToolId = "";
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

    // -------------------------------------------------------------------------
    // Registry + YAML config
    // -------------------------------------------------------------------------

    import command_history : CommandHistory;
    auto history = new CommandHistory();

    // Visibility of the floating Command-History panel (drawn in the main
    // render loop). Toggled by the history.show command, wired below.
    bool showHistoryPanel = false;

    // Phase C.2: every transform tool gets the same undo plumbing — the
    // history stack + a factory that builds a MeshVertexEdit pre-wired to
    // the same gpu/caches the tool mutates. Tools call beginEdit() at drag
    // start and commitEdit() at drag end; one undo entry per drag.
    auto vxEditFactory = () => new MeshVertexEdit(&mesh, cameraView, editMode,
                                                   &gpu, &vertexCache, &edgeCache, &faceCache);
    auto bevelEditFactory = () => new MeshBevelEdit(&mesh, cameraView, editMode,
                                                     &gpu, &vertexCache, &edgeCache, &faceCache);

    Registry reg;
    reg.toolFactories["move"]   = () {
        auto t = new MoveTool(&mesh, &gpu, &editMode);
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };
    reg.toolFactories["rotate"] = () {
        auto t = new RotateTool(&mesh, &gpu, &editMode);
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };
    reg.toolFactories["scale"]  = () {
        auto t = new ScaleTool(&mesh, &gpu, &editMode);
        t.setUndoBindings(history, vxEditFactory);
        return cast(Tool)t;
    };
    reg.toolFactories["bevel"]  = () {
        auto t = new BevelTool(&mesh, &gpu, &editMode);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };
    reg.toolFactories["box"]    = () {
        auto t = new BoxTool(&mesh, &gpu, litShader);
        t.setUndoBindings(history, bevelEditFactory);
        return cast(Tool)t;
    };

    reg.commandFactories["select.expand"]         = () => cast(Command) new SelectionExpand(&mesh, cameraView, editMode);
    reg.commandFactories["select.contract"]       = () => cast(Command) new SelectionContract(&mesh, cameraView, editMode);
    reg.commandFactories["select.more"]           = () => cast(Command) new SelectMore(&mesh, cameraView, editMode);
    reg.commandFactories["select.less"]           = () => cast(Command) new SelectLess(&mesh, cameraView, editMode);
    reg.commandFactories["select.loop"]           = () => cast(Command) new SelectLoop(&mesh, cameraView, editMode);
    reg.commandFactories["select.ring"]           = () => cast(Command) new SelectRing(&mesh, cameraView, editMode);
    reg.commandFactories["select.invert"]         = () => cast(Command) new SelectInvert(&mesh, cameraView, editMode);
    reg.commandFactories["select.connect"]        = () => cast(Command) new SelectConnect(&mesh, cameraView, editMode);
    reg.commandFactories["select.between"]        = () => cast(Command) new SelectBetween(&mesh, cameraView, editMode);
    reg.commandFactories["viewport.fit"]          = () => cast(Command) new Fit(&mesh, cameraView, editMode);
    reg.commandFactories["viewport.fit_selected"] = () => cast(Command) new FitSelected(&mesh, cameraView, editMode);
    reg.commandFactories["file.load"] = () => cast(Command)
        new FileLoad(&mesh, cameraView, editMode, &gpu, &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["file.save"] = () => cast(Command)
        new FileSave(&mesh, cameraView, editMode);
    reg.commandFactories["mesh.subdivide"] = () => cast(Command)
        new Subdivide(&mesh, cameraView, editMode,
                      &gpu, &vertexCache, &edgeCache, &faceCache,
                      () => setActiveTool(null));
    reg.commandFactories["mesh.subdivide_faceted"] = () => cast(Command)
        new SubdivideFaceted(&mesh, cameraView, editMode,
                             &gpu, &vertexCache, &edgeCache, &faceCache,
                             () => setActiveTool(null));
    reg.commandFactories["mesh.subpatch_toggle"] = () => cast(Command)
        new SubpatchToggle(&mesh, cameraView, editMode);
    reg.commandFactories["mesh.bevel"] = () => cast(Command)
        new MeshBevel(&mesh, cameraView, editMode, &gpu,
                      &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.poly_bevel"] = () => cast(Command)
        new MeshPolyBevel(&mesh, cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.split_edge"] = () => cast(Command)
        new MeshSplitEdge(&mesh, cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.move_vertex"] = () => cast(Command)
        new MeshMoveVertex(&mesh, cameraView, editMode, &gpu,
                           &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.select"] = () => cast(Command)
        new MeshSelect(&mesh, cameraView, editMode, &editMode);
    reg.commandFactories["mesh.transform"] = () => cast(Command)
        new MeshTransform(&mesh, cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.vertex_edit"] = () => cast(Command)
        new MeshVertexEdit(&mesh, cameraView, editMode, &gpu,
                           &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["mesh.bevel_edit"] = () => cast(Command)
        new MeshBevelEdit(&mesh, cameraView, editMode, &gpu,
                          &vertexCache, &edgeCache, &faceCache);
    reg.commandFactories["scene.reset"] = () => cast(Command)
        new SceneReset(&mesh, cameraView, editMode, &gpu,
                       &vertexCache, &edgeCache, &faceCache,
                       &editMode, &cameraView, () => setActiveTool(null));
    reg.commandFactories["history.undo"] = () => cast(Command)
        new HistoryUndo(&mesh, cameraView, editMode, history);
    reg.commandFactories["history.redo"] = () => cast(Command)
        new HistoryRedo(&mesh, cameraView, editMode, history);
    reg.commandFactories["history.show"] = () => cast(Command)
        new HistoryShow(&mesh, cameraView, editMode,
                        () { showHistoryPanel = !showHistoryPanel; });

    Panel[]       panels    = loadButtons("config/buttons.yaml");
    ShortcutTable shortcuts = loadShortcuts("config/shortcuts.yaml");

    // Validate: every action id in panels must exist in the registry.
    {
        import std.array : appender;
        auto missing = appender!string();
        foreach (ref p; panels) {
            foreach (ref btn; allButtons(p)) {
                if (btn.action.kind == ActionKind.tool) {
                    if ((btn.action.id in reg.toolFactories) is null)
                        missing ~= " tool:" ~ btn.action.id;
                } else {
                    if ((btn.action.id in reg.commandFactories) is null)
                        missing ~= " command:" ~ btn.action.id;
                }
            }
        }
        if (missing.data.length > 0)
            throw new Exception("buttons.yaml references unknown ids:" ~ missing.data);
    }
    // Validate shortcut tool/command ids.
    {
        import std.array : appender;
        auto missing = appender!string();
        foreach (id, sc; shortcuts.byToolId)
            if ((id in reg.toolFactories) is null)
                missing ~= " tool:" ~ id;
        foreach (id, sc; shortcuts.byCommandId)
            if ((id in reg.commandFactories) is null)
                missing ~= " command:" ~ id;
        if (missing.data.length > 0)
            throw new Exception("shortcuts.yaml references unknown ids:" ~ missing.data);
    }

    void activateToolById(string id) {
        if (activeToolId == id) { setActiveTool(null); activeToolId = ""; }
        else {
            setActiveTool(reg.toolFactories[id]());
            activeToolId = id;
        }
    }

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

        httpServer.setDetailedModelDataProvider(() {
            // Создаём свежий массив вершин при КАЖДОМ запросе
            float[] verts = new float[](mesh.vertices.length * 3);
            for (size_t i = 0; i < mesh.vertices.length; i++) {
                verts[i * 3] = mesh.vertices[i].x;
                verts[i * 3 + 1] = mesh.vertices[i].y;
                verts[i * 3 + 2] = mesh.vertices[i].z;
            }

            // Копируем edges, faces и subpatch-флаги (свежие копии)
            uint[2][] edgesCopy = new uint[2][](mesh.edges.length);
            for (size_t i = 0; i < mesh.edges.length; i++) {
                edgesCopy[i] = mesh.edges[i];
            }
            uint[][] facesCopy = new uint[][](mesh.faces.length);
            for (size_t i = 0; i < mesh.faces.length; i++) {
                facesCopy[i] = mesh.faces[i].dup;
            }
            // isSubpatch parallel to faces — pad with false if shorter.
            bool[] subCopy = new bool[](mesh.faces.length);
            for (size_t i = 0; i < mesh.faces.length; i++)
                subCopy[i] = i < mesh.isSubpatch.length && mesh.isSubpatch[i];

            return meshToJsonDetailed(
                mesh.vertices.length,
                mesh.edges.length,
                mesh.faces.length,
                verts,
                edgesCopy,
                facesCopy,
                subCopy
            );
        });
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
        httpServer.setBevvertProvider((int vert) {
            import bevel : buildBevVert, populateBoundVerts, BevVert;
            import std.format : format;
            import std.array  : appender;
            if (vert < 0 || vert >= cast(int)mesh.vertices.length)
                throw new Exception("vert out of range");
            mesh.buildLoops();
            BevVert bv = buildBevVert(&mesh, cast(uint)vert,
                                      mesh.selectedEdges);
            populateBoundVerts(&mesh, bv);
            auto json = appender!string();
            json ~= format(`{"vert":%d,"selCount":%d,"bevEdgeIdx":%d,"origPos":[%f,%f,%f],"edges":[`,
                           bv.vert, bv.selCount, bv.bevEdgeIdx,
                           bv.origPos.x, bv.origPos.y, bv.origPos.z);
            foreach (i, eh; bv.edges) {
                if (i > 0) json ~= ",";
                json ~= format(`{"edgeIdx":%d,"isBev":%s,"fnext":%d,"fprev":%d`
                               ~ `,"leftBV":%d,"rightBV":%d}`,
                               cast(int)eh.edgeIdx,
                               eh.isBev ? "true" : "false",
                               cast(int)eh.fnext,
                               cast(int)eh.fprev,
                               eh.leftBV, eh.rightBV);
            }
            json ~= `],"boundVerts":[`;
            foreach (i, bnd; bv.boundVerts) {
                if (i > 0) json ~= ",";
                json ~= format(`{"ehFromIdx":%d,"ehToIdx":%d,"face":%d,`
                               ~ `"isOnEdge":%s,"reusesOrig":%s,`
                               ~ `"pos":[%f,%f,%f],`
                               ~ `"slideDir":[%f,%f,%f],`
                               ~ `"profile":{"superR":%f,"sample":[`,
                               bnd.ehFromIdx, bnd.ehToIdx, cast(int)bnd.face,
                               bnd.isOnEdge   ? "true" : "false",
                               bnd.reusesOrig ? "true" : "false",
                               bnd.pos.x, bnd.pos.y, bnd.pos.z,
                               bnd.slideDir.x, bnd.slideDir.y, bnd.slideDir.z,
                               bnd.profile.superR);
                foreach (j, s; bnd.profile.sample) {
                    if (j > 0) json ~= ",";
                    json ~= format(`[%f,%f,%f]`, s.x, s.y, s.z);
                }
                json ~= "]}}";
            }
            json ~= "]}";
            return json.data;
        });
        httpServer.setCommandHandler((string id, string paramsJson) {
            import std.json : parseJSON, JSONType;
            import commands.file.load : FileLoad;
            import commands.file.save : FileSave;

            auto factory = id in reg.commandFactories;
            if (factory is null)
                throw new Exception("unknown command id '" ~ id ~ "'");
            auto cmd = (*factory)();

            // Inject params into commands that accept them. Currently only
            // file.load/file.save use the `path` field — extend here as
            // more commands grow JSON-driven inputs.
            if (paramsJson.length > 0) {
                auto pj = parseJSON(paramsJson);
                if (pj.type == JSONType.object) {
                    if ("path" in pj && pj["path"].type == JSONType.string) {
                        string path = pj["path"].str;
                        if (auto fl = cast(FileLoad)cmd) fl.setPath(path);
                        else if (auto fs = cast(FileSave)cmd) fs.setPath(path);
                    }
                    float jsonNumber(JSONValue v) {
                        if (v.type == JSONType.integer)  return cast(float)v.integer;
                        if (v.type == JSONType.uinteger) return cast(float)v.uinteger;
                        if (v.type == JSONType.float_)   return cast(float)v.floating;
                        return 0.0f;
                    }
                    if (auto mv = cast(MeshMoveVertex)cmd) {
                        if ("from" in pj && pj["from"].type == JSONType.array) {
                            auto a = pj["from"].array;
                            mv.setFrom(jsonNumber(a[0]), jsonNumber(a[1]), jsonNumber(a[2]));
                        }
                        if ("to" in pj && pj["to"].type == JSONType.array) {
                            auto a = pj["to"].array;
                            mv.setTo(jsonNumber(a[0]), jsonNumber(a[1]), jsonNumber(a[2]));
                        }
                    }
                    if (auto mb = cast(MeshBevel)cmd) {
                        if ("width"  in pj) mb.setWidth (jsonNumber(pj["width"]));
                        if ("widthR" in pj) mb.setWidthR(jsonNumber(pj["widthR"]));
                        if ("mode"   in pj && pj["mode"].type == JSONType.string)
                            mb.setMode(pj["mode"].str);
                        if ("seg"    in pj) mb.setSeg(cast(int)jsonNumber(pj["seg"]));
                        if ("superR" in pj) mb.setSuperR(jsonNumber(pj["superR"]));
                        if ("limit"  in pj && pj["limit"].type == JSONType.false_)
                            mb.setLimit(false);
                        if ("miter_inner" in pj
                            && pj["miter_inner"].type == JSONType.string)
                            mb.setMiterInner(pj["miter_inner"].str);
                    }
                    if (auto mpb = cast(MeshPolyBevel)cmd) {
                        if ("insert" in pj) mpb.setInsert(jsonNumber(pj["insert"]));
                        if ("shift"  in pj) mpb.setShift (jsonNumber(pj["shift"]));
                        if ("group"  in pj && pj["group"].type == JSONType.true_)
                            mpb.setGroup(true);
                    }
                    // mesh.vertex_edit: indices + before + after arrays
                    // (each Vec3 as [x,y,z]). Used by tests; tools call
                    // setEdit() directly.
                    if (auto vxe = cast(MeshVertexEdit)cmd) {
                        if ("indices" !in pj || "before" !in pj || "after" !in pj)
                            throw new Exception(
                                "mesh.vertex_edit needs indices/before/after");
                        auto idxA = pj["indices"].array;
                        auto befA = pj["before"].array;
                        auto aftA = pj["after"].array;
                        if (befA.length != idxA.length || aftA.length != idxA.length)
                            throw new Exception(
                                "mesh.vertex_edit: indices/before/after length mismatch");
                        uint[] ids; ids.length = idxA.length;
                        Vec3[] bef; bef.length = idxA.length;
                        Vec3[] aft; aft.length = idxA.length;
                        foreach (i; 0 .. idxA.length) {
                            ids[i] = cast(uint)jsonNumber(idxA[i]);
                            auto b = befA[i].array;
                            auto a = aftA[i].array;
                            bef[i] = Vec3(jsonNumber(b[0]), jsonNumber(b[1]), jsonNumber(b[2]));
                            aft[i] = Vec3(jsonNumber(a[0]), jsonNumber(a[1]), jsonNumber(a[2]));
                        }
                        vxe.setEdit(ids, bef, aft, "Edit");
                    }
                }
            }

            // Phase C: while a refire block is open, fire() reverts the
            // previous live command before applying the new one — net stack
            // effect = 1 entry per drag/edit cycle. Outside refire, fire()
            // falls through to plain apply()+record(), preserving Phase A
            // semantics.
            if (history.refireActive) {
                if (!history.fire(cmd))
                    throw new Exception("command '" ~ id ~ "' did not apply");
            } else {
                if (!cmd.apply())
                    throw new Exception("command '" ~ id ~ "' did not apply");
                history.record(cmd);
            }
        });

        httpServer.setUndoHandler(() {
            return history.undo();
        });
        httpServer.setRedoHandler(() {
            return history.redo();
        });
        httpServer.setHistoryProvider(() {
            // JSON: { "undo": ["label1", ...], "redo": [...] }
            import std.array : appender;
            auto buf = appender!string();
            buf.put(`{"undo":[`);
            foreach (i, l; history.undoLabels) {
                if (i > 0) buf.put(",");
                buf.put(`"`);
                foreach (c; l) {
                    if (c == '"' || c == '\\') buf.put('\\');
                    buf.put(c);
                }
                buf.put(`"`);
            }
            buf.put(`],"redo":[`);
            foreach (i, l; history.redoLabels) {
                if (i > 0) buf.put(",");
                buf.put(`"`);
                foreach (c; l) {
                    if (c == '"' || c == '\\') buf.put('\\');
                    buf.put(c);
                }
                buf.put(`"`);
            }
            buf.put(`]}`);
            return buf.data;
        });

        // Phase C: /api/refire opens/closes a refire block on the history.
        // Tools call refireBegin/refireEnd directly; this endpoint exists
        // for HTTP-driven tests that want to verify the refire-coalescing
        // behavior without going through SDL.
        httpServer.setRefireHandler((string action) {
            if (action == "begin")     history.refireBegin();
            else if (action == "end")  history.refireEnd();
            else throw new Exception("invalid refire action '" ~ action ~ "'");
        });

        // Phase A.5: dispatch /api/select through the unified Command path
        // (MeshSelect) so selection changes land on the undo stack and
        // share the same snapshot/revert mechanism as everything else.
        httpServer.setSelectionHandler((string mode, int[] indices) {
            auto cmd = cast(MeshSelect)reg.commandFactories["mesh.select"]();
            cmd.setMode(mode);
            cmd.setIndices(indices);
            if (history.refireActive) {
                if (!history.fire(cmd))
                    throw new Exception("mesh.select did not apply");
            } else {
                if (!cmd.apply())
                    throw new Exception("mesh.select did not apply");
                history.record(cmd);
            }
        });

        // Phase A.5: dispatch /api/transform through MeshTransform command.
        httpServer.setTransformHandler((string kind, JSONValue params) {
            import math : Vec3;

            // Helper to read a 3-vector field with default value.
            Vec3 vec3From(string field, Vec3 def) {
                if (field !in params) return def;
                auto a = params[field].array;
                if (a.length != 3) throw new Exception("'" ~ field ~ "' must be [x,y,z]");
                Vec3 r;
                foreach (i, n; a) {
                    double v;
                    switch (n.type) {
                        case JSONType.integer:  v = cast(double)n.integer;  break;
                        case JSONType.uinteger: v = cast(double)n.uinteger; break;
                        case JSONType.float_:   v = n.floating;             break;
                        default: throw new Exception("'" ~ field ~ "' components must be numbers");
                    }
                    if (i == 0) r.x = cast(float)v;
                    if (i == 1) r.y = cast(float)v;
                    if (i == 2) r.z = cast(float)v;
                }
                return r;
            }
            float floatFrom(string field, float def) {
                if (field !in params) return def;
                auto n = params[field];
                switch (n.type) {
                    case JSONType.integer:  return cast(float)n.integer;
                    case JSONType.uinteger: return cast(float)n.uinteger;
                    case JSONType.float_:   return cast(float)n.floating;
                    default: throw new Exception("'" ~ field ~ "' must be a number");
                }
            }

            auto cmd = cast(MeshTransform)reg.commandFactories["mesh.transform"]();
            cmd.setKind(kind);
            cmd.setDelta (vec3From("delta",  Vec3(0, 0, 0)));
            cmd.setAxis  (vec3From("axis",   Vec3(0, 1, 0)));
            cmd.setAngle (floatFrom("angle", 0.0f));
            cmd.setFactor(vec3From("factor", Vec3(1, 1, 1)));
            cmd.setPivot (vec3From("pivot",  Vec3(0, 0, 0)));
            if (history.refireActive) {
                if (!history.fire(cmd))
                    throw new Exception("mesh.transform did not apply");
            } else {
                if (!cmd.apply())
                    throw new Exception("mesh.transform did not apply");
                history.record(cmd);
            }
        });

        // Phase A.5: dispatch /api/reset through SceneReset command.
        // Note: scene.reset is undoable but since /api/reset is also used
        // by tests to bring vibe3d to a fresh state, we may want a way
        // to NOT push it onto the stack — handled via cmd.isUndoable in
        // future if needed.
        httpServer.setResetHandler((string primitiveType) {
            auto cmd = cast(SceneReset)reg.commandFactories["scene.reset"]();
            cmd.setPrimitive(primitiveType);
            if (!cmd.apply())
                throw new Exception("scene.reset did not apply");
            history.record(cmd);
        });
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
            layout.resize(winW, winH);
            glViewport(0, 0, fbW, fbH);
            initThickLineProgram(thickLineProgram, fbW, fbH);
            // Keep replay-time pixel remapping calibrated to the new layout.
            setReplayCurrentViewport(layout.vpX, layout.vpY,
                                     layout.vpW, layout.vpH, kFovY);
        }
    }

    // Run a Command through the same dispatch the HTTP /api/command path
    // uses: refire-aware apply, history.record on success. Used by both
    // keyboard shortcut and UI-button click sites so they're uniformly
    // undoable. Silently no-ops on null / apply()-failure (e.g. file.load
    // when the user cancels the native dialog).
    void runCommand(Command cmd) {
        if (cmd is null) return;
        if (history.refireActive) {
            history.fire(cmd);
        } else {
            if (cmd.apply())
                history.record(cmd);
        }
    }

    void handleKeyDown(ref SDL_KeyboardEvent kev) {
        // YAML-driven shortcut lookup (tool, command, editmode).
        string canon = canonFromEvent(kev.keysym.sym, cast(SDL_Keymod)kev.keysym.mod);
        if (canon.length > 0) {
            if (auto id = canon in shortcuts.toolIdByCanon) {
                activateToolById(*id);
                return;
            }
            if (auto id = canon in shortcuts.commandIdByCanon) {
                runCommand(reg.commandFactories[*id]());
                return;
            }
            if (auto id = canon in shortcuts.editModeByCanon) {
                setActiveTool(null);
                final switch (*id) {
                    case "vertices": editMode = EditMode.Vertices; break;
                    case "edges":    editMode = EditMode.Edges;    break;
                    case "polygons": editMode = EditMode.Polygons; break;
                }
                return;
            }
        }

        // Ctrl+Z / Ctrl+Shift+Z are dispatched via shortcuts.yaml as the
        // history.undo / history.redo commands (registered in commandFactories
        // above) — see config/shortcuts.yaml.

        switch (kev.keysym.sym) {
            case SDLK_F1:
                recLog.close();
                recLog.open("recording.jsonl");
                recLog.writeViewportMeta(layout.vpX, layout.vpY,
                                         layout.vpW, layout.vpH, kFovY);
                stderr.writeln("[REC] started → recording.jsonl");
                break;
            case SDLK_F2:
                recLog.close();
                stderr.writeln("[REC] stopped");
                break;
            case SDLK_ESCAPE: running = false; break;
            case SDLK_SPACE:
                if (activeTool) setActiveTool(null);
                else editMode = cast(EditMode)((cast(int)editMode + 1) % 3);
                break;
            case SDLK_TAB: {
                // Toggle subpatch flag on selected faces; if nothing is
                // selected, invert the flag globally. The preview rebuilds
                // next frame via mutationVersion bumped inside setSubpatch.
                mesh.syncSelection();
                bool any = mesh.hasAnySelectedFaces();
                foreach (fi; 0 .. mesh.faces.length) {
                    if (any && !(fi < mesh.selectedFaces.length && mesh.selectedFaces[fi]))
                        continue;
                    bool cur = fi < mesh.isSubpatch.length && mesh.isSubpatch[fi];
                    mesh.setSubpatch(fi, !cur);
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

    // Open an interactive selection edit session. Idempotent — repeated
    // calls before commitInteractiveSelEdit() are no-ops. Snapshot must be
    // captured BEFORE any pick/lasso/clear mutates the selection.
    void beginInteractiveSelEdit() {
        if (pendingSelOpen) return;
        mesh.syncSelection();
        pendingSelBefore     = SelectionSnapshot.capture(mesh);
        pendingSelBeforeMode = editMode;
        pendingSelOpen       = true;
    }

    // Close the session: capture post-state, build a MeshSelectionEdit and
    // record it if anything actually changed (selection arrays differ or
    // edit mode flipped). No-op when no session is open.
    void commitInteractiveSelEdit() {
        if (!pendingSelOpen) return;
        scope(exit) pendingSelOpen = false;

        mesh.syncSelection();
        auto after = SelectionSnapshot.capture(mesh);

        bool changed = (editMode != pendingSelBeforeMode)
                    || pendingSelBefore.selectedVertices != after.selectedVertices
                    || pendingSelBefore.selectedEdges    != after.selectedEdges
                    || pendingSelBefore.selectedFaces    != after.selectedFaces;
        if (!changed) return;

        auto cmd = new MeshSelectionEdit(&mesh, cameraView, editMode, &editMode);
        cmd.setBefore(pendingSelBefore, pendingSelBeforeMode);
        cmd.setAfter (after,            editMode);
        history.record(cmd);
    }

    void handleMouseButtonDown(ref SDL_MouseButtonEvent btn) {
        if (btn.button == SDL_BUTTON_RIGHT) {
            rmbDragging = true;
            rmbPath = [ImVec2(cast(float)btn.x, cast(float)btn.y)];
            // RMB lasso mutates selection on mouseUp; snapshot now.
            beginInteractiveSelEdit();
            return;
        }
        if (activeTool && activeTool.onMouseButtonDown(btn)) return;
        if (btn.button == SDL_BUTTON_LEFT && btn.clicks == 2 && activeTool is null) {
            // Double-click loop / connect — these mutate selection. Wrap as
            // an interactive edit so undo restores the prior selection.
            beginInteractiveSelEdit();
            if (editMode == EditMode.Edges)
                new SelectLoop(&mesh, cameraView, editMode).apply();
            else
                new SelectConnect(&mesh, cameraView, editMode).apply();
            commitInteractiveSelEdit();
            return;
        }
        if (btn.button == SDL_BUTTON_LEFT) {
            SDL_Keymod mods = SDL_GetModState();
            bool ctrl  = (mods & KMOD_CTRL)  != 0;
            bool alt   = (mods & KMOD_ALT)   != 0;
            bool shift = (mods & KMOD_SHIFT)  != 0;
            bool anyToolActive = activeTool !is null;

            // Capture pre-LMB selection snapshot now — BEFORE the bare-LMB
            // clear-selection branch below could mutate. If LMB ends up
            // being a camera drag (Alt / Ctrl+Alt / Alt+Shift), commit will
            // see no change and skip recording. Tool-driven LMB doesn't
            // need it (tools own their own undo plumbing).
            if (!anyToolActive && !alt)
                beginInteractiveSelEdit();

            if      (ctrl && alt)  dragMode = DragMode.Zoom;
            else if (alt && shift) dragMode = DragMode.Pan;
            else if (alt)          dragMode = DragMode.Orbit;
            else if (ctrl && !anyToolActive)  dragMode = DragMode.SelectRemove;
            else if (shift && !anyToolActive) dragMode = DragMode.SelectAdd;
            else if (!anyToolActive) {
                // No modifiers: clear selection for current mode
                if (editMode == EditMode.Vertices)
                    mesh.clearVertexSelection();
                else if (editMode == EditMode.Edges)
                    mesh.clearEdgeSelection();
                else if (editMode == EditMode.Polygons)
                    mesh.clearFaceSelection();
                dragMode = DragMode.Select;
            }
            lastMouseX = btn.x;
            lastMouseY = btn.y;
        }
    }

    void handleMouseButtonUp(ref SDL_MouseButtonEvent btn) {
        if (btn.button == SDL_BUTTON_RIGHT) {
            if (rmbPath.length >= 3) {
                SDL_Keymod mods = SDL_GetModState();
                bool shift = (mods & KMOD_SHIFT) != 0;
                bool ctrl  = (mods & KMOD_CTRL)  != 0;
                Viewport vp2 = cameraView.viewport();
                float[] pxs = new float[](rmbPath.length);
                float[] pys = new float[](rmbPath.length);
                foreach (i, p; rmbPath) { pxs[i] = p.x; pys[i] = p.y; }
                bool[] visible = mesh.visibleVertices(cameraView.eye);

                // In subpatch mode iterate preview geometry and translate
                // hits back to cage indices via the trace. A cage element is
                // considered lasso-hit only when every one of its preview
                // children is fully inside (strict semantics matching the
                // cage behavior).
                bool preview = subpatchPreview.active;
                const pv = preview ? &subpatchPreview.mesh : null;
                bool[] pvVisible = preview ? pv.visibleVertices(cameraView.eye) : null;

                if (editMode == EditMode.Polygons) {
                    if (!shift && !ctrl)
                        mesh.clearFaceSelection();
                    if (preview) {
                        // Per cage face: every preview child must have all
                        // visible verts inside the lasso.
                        bool[] cageAllInside = new bool[](mesh.faces.length);
                        bool[] cageVisited   = new bool[](mesh.faces.length);
                        cageAllInside[] = true;
                        foreach (fi; 0 .. pv.faces.length) {
                            uint cage = subpatchPreview.trace.faceOrigin[fi];
                            if (cage == uint.max || cage >= mesh.faces.length) continue;
                            auto face = pv.faces[fi];
                            if (face.length < 3) { cageAllInside[cage] = false; continue; }
                            Vec3 fn = pv.faceNormal(cast(uint)fi);
                            if (dot(fn, pv.vertices[face[0]] - vp2.eye) >= 0) continue;
                            cageVisited[cage] = true;
                            foreach (vi; face) {
                                float sx, sy, ndcZ;
                                if (!projectToWindow(pv.vertices[vi], vp2, sx, sy, ndcZ) ||
                                    !pointInPolygon2D(sx, sy, pxs, pys)) {
                                    cageAllInside[cage] = false;
                                    break;
                                }
                            }
                        }
                        foreach (fi; 0 .. mesh.faces.length) {
                            if (!cageVisited[fi] || !cageAllInside[fi]) continue;
                            if (ctrl) mesh.deselectFace(cast(int)fi);
                            else      mesh.selectFace(cast(int)fi);
                        }
                    } else {
                        foreach (fi; 0 .. mesh.faces.length) {
                            uint[] face = mesh.faces[fi];
                            if (face.length < 3) continue;
                            Vec3 fn = mesh.faceNormal(cast(uint)fi);
                            if (dot(fn, mesh.vertices[face[0]] - vp2.eye) >= 0) continue;
                            bool allInside = true;
                            foreach (vi; face) {
                                float sx, sy, ndcZ;
                                if (!projectToWindow(mesh.vertices[vi], vp2, sx, sy, ndcZ) ||
                                    !pointInPolygon2D(sx, sy, pxs, pys)) {
                                    allInside = false;
                                    break;
                                }
                            }
                            if (allInside) {
                                if (ctrl) mesh.deselectFace(cast(int)fi);
                                else      mesh.selectFace(cast(int)fi);
                            }
                        }
                    }
                } else if (editMode == EditMode.Vertices) {
                    if (!shift && !ctrl)
                        mesh.clearVertexSelection();
                    if (preview) {
                        foreach (pi; 0 .. pv.vertices.length) {
                            uint cage = subpatchPreview.trace.vertOrigin[pi];
                            if (cage == uint.max) continue;
                            if (!pvVisible[pi]) continue;
                            float sx, sy, ndcZ;
                            if (!projectToWindow(pv.vertices[pi], vp2, sx, sy, ndcZ)) continue;
                            if (pointInPolygon2D(sx, sy, pxs, pys)) {
                                if (ctrl) mesh.deselectVertex(cast(int)cage);
                                else      mesh.selectVertex(cast(int)cage);
                            }
                        }
                    } else {
                        foreach (vi; 0 .. mesh.vertices.length) {
                            if (!visible[vi]) continue;
                            float sx, sy, ndcZ;
                            if (!projectToWindow(mesh.vertices[vi], vp2, sx, sy, ndcZ)) continue;
                            if (pointInPolygon2D(sx, sy, pxs, pys)) {
                                if (ctrl) mesh.deselectVertex(cast(int)vi);
                                else      mesh.selectVertex(cast(int)vi);
                            }
                        }
                    }
                } else if (editMode == EditMode.Edges) {
                    if (!shift && !ctrl)
                        mesh.clearEdgeSelection();
                    if (preview) {
                        // Cage edge selected only if every visible preview
                        // segment tracing back to it is fully inside lasso.
                        bool[] cageAllInside = new bool[](mesh.edges.length);
                        bool[] cageVisited   = new bool[](mesh.edges.length);
                        cageAllInside[] = true;
                        foreach (pei; 0 .. pv.edges.length) {
                            uint cage = subpatchPreview.trace.edgeOrigin[pei];
                            if (cage == uint.max || cage >= mesh.edges.length) continue;
                            uint a = pv.edges[pei][0], b = pv.edges[pei][1];
                            if (!pvVisible[a] || !pvVisible[b]) continue;
                            cageVisited[cage] = true;
                            float sxa, sya, ndcZa, sxb, syb, ndcZb;
                            if (!projectToWindow(pv.vertices[a], vp2, sxa, sya, ndcZa) ||
                                !projectToWindow(pv.vertices[b], vp2, sxb, syb, ndcZb) ||
                                !pointInPolygon2D(sxa, sya, pxs, pys) ||
                                !pointInPolygon2D(sxb, syb, pxs, pys)) {
                                cageAllInside[cage] = false;
                            }
                        }
                        foreach (ei; 0 .. mesh.edges.length) {
                            if (!cageVisited[ei] || !cageAllInside[ei]) continue;
                            if (ctrl) mesh.deselectEdge(cast(int)ei);
                            else      mesh.selectEdge(cast(int)ei);
                        }
                    } else {
                        foreach (ei; 0 .. mesh.edges.length) {
                            uint a = mesh.edges[ei][0], b = mesh.edges[ei][1];
                            if (!visible[a] || !visible[b]) continue;
                            float sxa, sya, ndcZa, sxb, syb, ndcZb;
                            if (!projectToWindow(mesh.vertices[a], vp2, sxa, sya, ndcZa)) continue;
                            if (!projectToWindow(mesh.vertices[b], vp2, sxb, syb, ndcZb)) continue;
                            if (pointInPolygon2D(sxa, sya, pxs, pys) &&
                                pointInPolygon2D(sxb, syb, pxs, pys)) {
                                if (ctrl) mesh.deselectEdge(cast(int)ei);
                                else      mesh.selectEdge(cast(int)ei);
                            }
                        }
                    }
                }
            }
            rmbDragging = false;
            rmbPath = null;
            // RMB lasso commit — close the selection edit session.
            commitInteractiveSelEdit();
            return;
        }
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
        if (btn.button == SDL_BUTTON_LEFT) {
            dragMode = DragMode.None;
            // LMB up — close any open selection edit session. If the LMB
            // was a camera drag (no selection touched), commit is a no-op.
            commitInteractiveSelEdit();
        }
    }

    // Delegate is forward-declared here and assigned after pickVertices /
    // pickEdges / pickFaces are defined further down. handleMouseMotion
    // captures it by reference; at call time the delegate is bound.
    void delegate(int mx, int my) doSelectPickAt;

    void handleMouseMotion(ref SDL_MouseMotionEvent mot) {
        if (rmbDragging)
            rmbPath ~= ImVec2(cast(float)mot.x, cast(float)mot.y);
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

        // Select-drag: run the appropriate picker on EVERY motion event.
        // Without this, picks only happen once per render frame; in fast
        // event-playback scenarios (and any rapid drag) intermediate cursor
        // positions get skipped, missing verts/edges the cursor passed over.
        // The delegate is bound after the pickers are declared (see below).
        if ((dragMode == DragMode.Select
          || dragMode == DragMode.SelectAdd
          || dragMode == DragMode.SelectRemove)
            && doSelectPickAt !is null) {
            doSelectPickAt(mot.x, mot.y);
        }

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

        // In subpatch mode, cage positions differ from what the user sees.
        // Project the preview's original-derived verts (which carry smoothed
        // positions) and translate hits back to cage indices via the trace.
        if (subpatchPreview.active) {
            const pv = &subpatchPreview.mesh;
            bool[] visible = pv.visibleVertices(cameraView.eye);
            float closestSqS = 16.0f;
            int   best      = -1;
            foreach_reverse (pi; 0 .. pv.vertices.length) {
                uint origin = subpatchPreview.trace.vertOrigin[pi];
                if (origin == uint.max) continue;
                if (!visible[pi]) continue;
                float sx, sy, ndcZ;
                if (!projectToWindow(pv.vertices[pi], vp, sx, sy, ndcZ)) continue;
                float ddx = sx - mx, ddy = sy - my;
                float d2  = ddx*ddx + ddy*ddy;
                if (d2 >= closestSqS) continue;
                closestSqS = d2;
                best       = cast(int)origin;
            }
            if (best >= 0) {
                hoveredVertex = best;
                if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
                    mesh.selectVertex(hoveredVertex);
                else if (dragMode == DragMode.SelectRemove)
                    mesh.deselectVertex(hoveredVertex);
            }
            return;
        }

        float closestSq = 16.0f;  // 4.0f^2
        int candidate = -1;

        // A vertex is visible if at least one adjacent face is front-facing.
        // Geometry-exact: replaces unreliable depth-buffer test (near=0.001).
        bool[] vertexVisible = mesh.visibleVertices(cameraView.eye);

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
                mesh.selectVertex(hoveredVertex);
            else if (dragMode == DragMode.SelectRemove)
                mesh.deselectVertex(hoveredVertex);
        }
    }

    void pickEdges(ref Viewport vp, bool doingCameraDrag) {
        hoveredEdge = -1;
        if (io.WantCaptureMouse || doingCameraDrag ||
            editMode != EditMode.Edges || activeTool !is null)
            return;

        int mx, my;
        queryMouse(mx, my);
        float closest   = 6.0f;
        float closestSq = closest * closest;

        // In subpatch mode, iterate preview segments that trace back to cage
        // edges; any hit promotes to the cage index via the trace so the
        // whole polyline of that cage edge is treated as a single edge.
        if (subpatchPreview.active) {
            const pv = &subpatchPreview.mesh;
            bool[] visible = pv.visibleVertices(cameraView.eye);
            int bestCage = -1;
            foreach (i; 0 .. pv.edges.length) {
                uint cageEi = subpatchPreview.trace.edgeOrigin[i];
                if (cageEi == uint.max) continue;
                uint a = pv.edges[i][0], b = pv.edges[i][1];
                if (!visible[a] || !visible[b]) continue;

                float ax, ay, aZ, bx, by, bZ;
                if (!projectToWindow(pv.vertices[a], vp, ax, ay, aZ)) continue;
                if (!projectToWindow(pv.vertices[b], vp, bx, by, bZ)) continue;

                float minX = ax < bx ? ax : bx, maxX = ax < bx ? bx : ax;
                float minY = ay < by ? ay : by, maxY = ay < by ? by : ay;
                if (mx < minX - closest || mx > maxX + closest ||
                    my < minY - closest || my > maxY + closest)
                    continue;

                float t;
                float d2 = closestOnSegment2DSquared(cast(float)mx, cast(float)my,
                                                    ax, ay, bx, by, t);
                if (d2 >= closestSq) continue;
                closestSq = d2;
                bestCage  = cast(int)cageEi;
            }
            if (bestCage >= 0) {
                hoveredEdge = bestCage;
                if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
                    mesh.selectEdge(hoveredEdge);
                else if (dragMode == DragMode.SelectRemove)
                    mesh.deselectEdge(hoveredEdge);
            }
            return;
        }

        // A vertex is visible if at least one adjacent face is front-facing.
        // Computed once here — O(faces), replaces unreliable depth-buffer test.
        bool[] vertexVisible = mesh.visibleVertices(cameraView.eye);

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
                mesh.selectEdge(hoveredEdge);
            else if (dragMode == DragMode.SelectRemove)
                mesh.deselectEdge(hoveredEdge);
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

        // Subpatch mode: project preview faces, translate hit to cage.
        if (subpatchPreview.active) {
            const pv = &subpatchPreview.mesh;
            int bestCage = -1;
            foreach (fi; 0 .. pv.faces.length) {
                const(uint)[] face = pv.faces[fi];
                if (face.length < 3) continue;
                Vec3 n = pv.faceNormal(cast(uint)fi);
                if (dot(n, pv.vertices[face[0]] - cameraView.eye) >= 0) continue;

                int len = cast(int)face.length;
                auto sx  = new float[](len);
                auto sy  = new float[](len);
                auto ndz = new float[](len);
                bool ok = true;
                for (int j = 0; j < len; j++) {
                    if (!projectToWindowFull(pv.vertices[face[j]], vp,
                                             sx[j], sy[j], ndz[j])) { ok = false; break; }
                }
                if (!ok) continue;
                if (!pointInPolygon2D(cast(float)mx, cast(float)my, sx, sy)) continue;

                float cZ = 0;
                foreach (z; ndz) cZ += z;
                cZ /= len;
                if (cZ < bestZ) {
                    bestZ    = cZ;
                    bestCage = cast(int)subpatchPreview.trace.faceOrigin[fi];
                }
            }
            if (bestCage >= 0) {
                hoveredFace = bestCage;
                if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
                    mesh.selectFace(hoveredFace);
                else if (dragMode == DragMode.SelectRemove)
                    mesh.deselectFace(hoveredFace);
            }
            return;
        }

        // Quick screen-space bounds check first (if cache available)
        bool useBoundsCache = faceCache.minX.length >= mesh.faces.length;

        foreach (fi; 0 .. mesh.faces.length) {
            uint[] face = mesh.faces[fi];
            if (face.length < 3) continue;

            // Back-face culling: skip faces whose normal points away from camera.
            {
                Vec3 n = mesh.faceNormal(cast(uint)fi);
                if (dot(n, mesh.vertices[face[0]] - cameraView.eye) >= 0) continue;
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
            if (dragMode == DragMode.Select || dragMode == DragMode.SelectAdd)
                mesh.selectFace(hoveredFace);
            else if (dragMode == DragMode.SelectRemove)
                mesh.deselectFace(hoveredFace);
        }
    }

    // Bind the picker delegate forward-declared at handleMouseMotion's
    // scope. queryMouse() pulls from the global override which the event
    // player updates in batch (per tickEventPlayer call); the override is
    // already at the LAST event's position by the time this delegate runs
    // for the FIRST event in the batch — so reset the override to (mx, my)
    // before each pick so the picker sees the right cursor.
    doSelectPickAt = (int mx, int my) {
        setOverrideMouse(mx, my);
        Viewport vp = cameraView.viewport();
        if (editMode == EditMode.Vertices)      pickVertices(vp, false);
        else if (editMode == EditMode.Edges)    pickEdges   (vp, false);
        else if (editMode == EditMode.Polygons) pickFaces   (vp, false);
    };

    // 1-px black outline around the last ImGui item.
    // Right and bottom edges are drawn ON rmax so adjacent buttons' top/left
    // (drawn at their own rmin) land on the SAME pixel, producing a 1-pixel
    // shared border rather than two abutting lines.
    void drawButtonOutline() {
        auto dl = ImGui.GetWindowDrawList();
        ImVec2 rmin = ImGui.GetItemRectMin();
        ImVec2 rmax = ImGui.GetItemRectMax();
        uint c = IM_COL32(0, 0, 0, 255);
        dl.AddLine(ImVec2(rmin.x, rmin.y), ImVec2(rmax.x, rmin.y), c);  // top
        dl.AddLine(ImVec2(rmin.x, rmin.y), ImVec2(rmin.x, rmax.y), c);  // left
        dl.AddLine(ImVec2(rmin.x, rmax.y), ImVec2(rmax.x, rmax.y), c);  // bottom
        dl.AddLine(ImVec2(rmax.x, rmin.y), ImVec2(rmax.x, rmax.y), c);  // right
    }

    // LightWave-style raised bevel drawn as `thickness` concentric rings just
    // inside the 1-pixel outline.
    void drawRaisedBevel(uint light, uint dark, bool pressed = false,
                         int thickness = 2) {
        auto dl = ImGui.GetWindowDrawList();
        ImVec2 rmin = ImGui.GetItemRectMin();
        ImVec2 rmax = ImGui.GetItemRectMax();
        uint tl = pressed ? dark  : light;
        uint br = pressed ? light : dark;
        foreach (i; 0 .. thickness) {
            float x0 = rmin.x + 1.0f + i, y0 = rmin.y + 1.0f + i;
            float x1 = rmax.x - 2.0f - i, y1 = rmax.y - 2.0f - i;
            dl.AddLine(ImVec2(x0, y0), ImVec2(x1, y0), tl);
            dl.AddLine(ImVec2(x0, y0), ImVec2(x0, y1), tl);
            dl.AddLine(ImVec2(x0, y1), ImVec2(x1, y1), br);
            dl.AddLine(ImVec2(x1, y0), ImVec2(x1, y1), br);
        }
    }

    // LightWave-style button: beige palette for tools, pale blue for commands;
    // renders as pure white when `on` (active) or `held` (mouse down).
    // Returns true when the button is clicked this frame.
    bool renderStyledButton(string label, string shortcut, bool on, bool isCommand,
                            ImVec2 size) {
        ImVec4 bgNormal, bgHover;
        uint   bevelLightN, bevelDarkN, bevelLightH, bevelDarkH;
        if (isCommand) {
            bgNormal    = ImVec4(0.635f, 0.686f, 0.749f, 1.0f);  // (162,175,191)
            bgHover     = ImVec4(0.698f, 0.749f, 0.812f, 1.0f);  // (178,191,207)
            bevelLightN = IM_COL32(206, 219, 235, 255);
            bevelDarkN  = IM_COL32(143, 156, 172, 255);
            bevelLightH = IM_COL32(222, 235, 251, 255);
            bevelDarkH  = IM_COL32(159, 172, 188, 255);
        } else {
            bgNormal    = ImVec4(0.710f, 0.710f, 0.655f, 1.0f);  // (181,181,167)
            bgHover     = ImVec4(0.773f, 0.773f, 0.718f, 1.0f);  // (197,197,183)
            bevelLightN = IM_COL32(225, 225, 211, 255);
            bevelDarkN  = IM_COL32(162, 162, 148, 255);
            bevelLightH = IM_COL32(241, 241, 227, 255);
            bevelDarkH  = IM_COL32(178, 178, 164, 255);
        }

        ImVec4 white = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
        ImGui.PushStyleColor(ImGuiCol.Button,        on ? white : bgNormal);
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, on ? white : bgHover);
        ImGui.PushStyleColor(ImGuiCol.ButtonActive,  white);
        ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, ImVec2(0.0f, 0.5f));
        bool clicked = ImGui.Button(label, size);
        ImGui.PopStyleVar();
        ImGui.PopStyleColor(3);

        bool held = ImGui.IsItemActive();
        drawButtonOutline();
        if (!on && !held) {
            bool hov = ImGui.IsItemHovered();
            drawRaisedBevel(hov ? bevelLightH : bevelLightN,
                            hov ? bevelDarkH  : bevelDarkN,
                            false);
        }

        if (shortcut.length > 0) {
            ImVec2 rmin = ImGui.GetItemRectMin();
            ImVec2 rmax = ImGui.GetItemRectMax();
            ImVec2 ts   = ImGui.CalcTextSize(shortcut);
            ImVec2 tp   = ImVec2(rmax.x - ts.x - 6.0f,
                                 rmin.y + (rmax.y - rmin.y - ts.y) * 0.5f);
            uint scCol = (on || held) ? IM_COL32(0, 0, 0, 255)
                                      : IM_COL32(245, 245, 231, 255);
            ImGui.GetWindowDrawList().AddText(tp, scCol, shortcut);
        }
        return clicked;
    }

    // LightWave-style section header: dark slate-blue band with centered white
    // text, framed by a 1-pixel black outline matching button edges.
    void drawSectionHeader(string title) {
        auto dl = ImGui.GetWindowDrawList();
        ImVec2 pos = ImGui.GetCursorScreenPos();
        // Match full-width buttons rendered with ImVec2(-1, 0) — ImGui resolves
        // that to avail.x - 1, so subtract one here to keep right edges flush.
        float  w   = ImGui.GetContentRegionAvail().x - 1.0f;
        ImVec2 ts  = ImGui.CalcTextSize(title);
        float  h   = ts.y + 4.0f;
        ImVec2 rmax = ImVec2(pos.x + w, pos.y + h);
        dl.AddRectFilled(pos, rmax, IM_COL32(84, 84, 94, 255));
        uint c = IM_COL32(0, 0, 0, 255);
        dl.AddLine(ImVec2(pos.x, pos.y),  ImVec2(rmax.x, pos.y),  c);  // top
        dl.AddLine(ImVec2(pos.x, pos.y),  ImVec2(pos.x, rmax.y),  c);  // left
        dl.AddLine(ImVec2(pos.x, rmax.y), ImVec2(rmax.x, rmax.y), c);  // bottom
        dl.AddLine(ImVec2(rmax.x, pos.y), ImVec2(rmax.x, rmax.y), c);  // right
        float tx = pos.x + (w - ts.x) * 0.5f;
        float ty = pos.y + 2.0f;
        dl.AddText(ImVec2(tx, ty), IM_COL32(255, 255, 255, 255), title);
        ImGui.Dummy(ImVec2(w, h));
    }

    // LightWave-style panel chrome: grey bg, black border, beige/blue button
    // palette, black text, flat frames. Call BEFORE `ImGui.Begin` and pair with
    // popPanelChromeStyle() AFTER `ImGui.End`.
    void pushPanelChromeStyle() {
        ImVec4 winBg   = ImVec4(0.561f, 0.561f, 0.561f, 1.0f);   // (143,143,143)
        ImVec4 border  = ImVec4(0.0f,   0.0f,   0.0f,   1.0f);
        ImVec4 btnBg   = ImVec4(0.710f, 0.710f, 0.655f, 1.0f);   // tool beige
        ImVec4 btnHov  = ImVec4(0.773f, 0.773f, 0.718f, 1.0f);
        ImVec4 btnAct  = ImVec4(1.0f,   1.0f,   1.0f,   1.0f);
        ImVec4 black   = ImVec4(0.0f,   0.0f,   0.0f,   1.0f);
        ImVec4 grabLo  = ImVec4(0.45f,  0.45f,  0.45f,  1.0f);
        ImVec4 grabHi  = ImVec4(0.20f,  0.20f,  0.20f,  1.0f);

        ImGui.PushStyleColor(ImGuiCol.WindowBg,         winBg);
        ImGui.PushStyleColor(ImGuiCol.Border,           border);
        ImGui.PushStyleColor(ImGuiCol.TitleBg,          winBg);
        ImGui.PushStyleColor(ImGuiCol.TitleBgActive,    winBg);
        ImGui.PushStyleColor(ImGuiCol.TitleBgCollapsed, winBg);
        ImGui.PushStyleColor(ImGuiCol.Text,             black);
        ImGui.PushStyleColor(ImGuiCol.Button,           btnBg);
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered,    btnHov);
        ImGui.PushStyleColor(ImGuiCol.ButtonActive,     btnAct);
        ImGui.PushStyleColor(ImGuiCol.FrameBg,          btnBg);
        ImGui.PushStyleColor(ImGuiCol.FrameBgHovered,   btnHov);
        ImGui.PushStyleColor(ImGuiCol.FrameBgActive,    btnAct);
        ImGui.PushStyleColor(ImGuiCol.SliderGrab,       grabLo);
        ImGui.PushStyleColor(ImGuiCol.SliderGrabActive, grabHi);
        ImGui.PushStyleColor(ImGuiCol.CheckMark,        black);

        ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding,    ImVec2(3, 3));
        ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 1.0f);
        ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding,    0.0f);
    }
    void popPanelChromeStyle() {
        ImGui.PopStyleVar(3);
        ImGui.PopStyleColor(15);
    }

    // Packed-button-row layout (large FramePadding, zero ItemSpacing). Use inside
    // Begin for button-only panels; skip for Tool Properties so inputs keep
    // normal spacing. Pair with popButtonBarStyle().
    void pushButtonBarStyle() {
        ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, ImVec2(6, 5));
        ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing,  ImVec2(0, 0));
    }
    void popButtonBarStyle() {
        ImGui.PopStyleVar(2);
    }

    void drawSidePanel() {
        int selCount     = countSelected(mesh.selectedVertices);
        int selEdgeCount = countSelected(mesh.selectedEdges);
        int selFaceCount = countSelected(mesh.selectedFaces);

        pushPanelChromeStyle();
        ImGui.SetNextWindowPos(layout.sidePos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.sideSize, ImGuiCond.Always);
        if (ImGui.Begin("Mesh Info", null,
                        ImGuiWindowFlags.NoTitleBar |
                        ImGuiWindowFlags.NoResize |
                        ImGuiWindowFlags.NoMove   |
                        ImGuiWindowFlags.NoCollapse))
        {
            pushButtonBarStyle();
            scope(exit) popButtonBarStyle();
            void renderButton(ref Button btn) {
                string sc;
                if (btn.action.kind == ActionKind.tool) {
                    if (auto sp = btn.action.id in shortcuts.byToolId)
                        sc = sp.display();
                } else {
                    if (auto sp = btn.action.id in shortcuts.byCommandId)
                        sc = sp.display();
                }
                bool on = (btn.action.kind == ActionKind.tool &&
                           activeToolId == btn.action.id);
                bool isCommand = btn.action.kind == ActionKind.command;
                if (renderStyledButton(btn.label, sc, on, isCommand, ImVec2(-1, 0))) {
                    if (btn.action.kind == ActionKind.tool)
                        activateToolById(btn.action.id);
                    else
                        runCommand(reg.commandFactories[btn.action.id]());
                }
            }

            if (activePanelIdx >= 0 && activePanelIdx < cast(int)panels.length) {
                Panel* p = &panels[activePanelIdx];
                bool prevWasGroup = false;
                bool first        = true;
                foreach (ref item; p.items) {
                    bool curIsGroup = item.isGroup;
                    if (!first && (prevWasGroup || curIsGroup))
                        ImGui.Dummy(ImVec2(0, 10));  // LW inter-group gap = 10px
                    if (curIsGroup) {
                        if (item.group.title.length > 0)
                            drawSectionHeader(item.group.title);
                        foreach (ref b; item.group.buttons)
                            renderButton(b);
                    } else {
                        renderButton(item.button);
                    }
                    prevWasGroup = curIsGroup;
                    first = false;
                }
            }

            ImGui.Separator();
            ImGui.Text("Camera");
            ImGui.LabelText("Dist",  "%.2f", cameraView.distance);
            ImGui.LabelText("Az",    "%.1f°", cast(double)(cameraView.azimuth   * 180.0 / PI));
            ImGui.LabelText("El",    "%.1f°", cast(double)(cameraView.elevation * 180.0 / PI));

            ImGui.Separator();
            ImGui.Text("Info");
            ImGui.LabelText("Verts", "%d/%d", mesh.vertexSelectionOrderCounter, cast(int)mesh.vertices.length);
            ImGui.LabelText("Edges", "%d/%d", mesh.edgeSelectionOrderCounter, cast(int)mesh.edges.length);
            ImGui.LabelText("Faces", "%d/%d", mesh.faceSelectionOrderCounter, cast(int)mesh.faces.length);
        }
        ImGui.End();
        popPanelChromeStyle();
    }

    void drawStatusBar() {
        pushPanelChromeStyle();
        ImGui.SetNextWindowPos(layout.statusPos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.statusSize, ImGuiCond.Always);
        if (ImGui.Begin("Status line", null,
                        ImGuiWindowFlags.NoTitleBar |
                        ImGuiWindowFlags.NoResize |
                        ImGuiWindowFlags.NoMove   |
                        ImGuiWindowFlags.NoCollapse))
        {
            pushButtonBarStyle();
            scope(exit) popButtonBarStyle();

            void renderModeButton(string label, string modeId, EditMode mode, float w) {
                auto sp = modeId in shortcuts.byEditMode;
                string sc = sp ? sp.display() : "";
                bool on = (editMode == mode);
                if (renderStyledButton(label, sc, on, /*isCommand=*/true, ImVec2(w, 0))) {
                    setActiveTool(null);
                    editMode = mode;
                }
            }

            enum float btnW = 85.0f;
            renderModeButton("Vertices", "vertices", EditMode.Vertices, btnW);
            ImGui.SameLine();
            renderModeButton("Edges",    "edges",    EditMode.Edges,    btnW);
            ImGui.SameLine();
            renderModeButton("Polygons", "polygons", EditMode.Polygons, btnW);
        }
        ImGui.End();
        popPanelChromeStyle();
    }

    void drawTabPanel() {
        pushPanelChromeStyle();
        ImGui.SetNextWindowPos(layout.tabPos, ImGuiCond.Always);
        ImGui.SetNextWindowSize(layout.tabSize, ImGuiCond.Always);
        if (ImGui.Begin("Tab bar", null,
                        ImGuiWindowFlags.NoTitleBar |
                        ImGuiWindowFlags.NoResize   |
                        ImGuiWindowFlags.NoMove     |
                        ImGuiWindowFlags.NoCollapse))
        {
            pushButtonBarStyle();
            scope(exit) popButtonBarStyle();

            enum float btnW = 90.0f;
            foreach (i, ref p; panels) {
                bool on = (cast(int)i == activePanelIdx);
                if (renderStyledButton(p.title, "", on, /*isCommand=*/true,
                                       ImVec2(btnW, 0)))
                    activePanelIdx = cast(int)i;
                if (i + 1 < panels.length)
                    ImGui.SameLine();
            }
        }
        ImGui.End();
        popPanelChromeStyle();
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
            httpServer.tickCommand();
            httpServer.tickSelection();
            httpServer.tickTransform();
            httpServer.tickRefire();
            httpServer.tickUndo();
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


        cameraView.setSize(layout.vpW, layout.vpH);

        Viewport vp = cameraView.viewport();

        // ---- ImGui ----
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplSDL2_NewFrame();
        ImGui.NewFrame();

        drawSidePanel();
        drawTabPanel();
        drawStatusBar();

        // ---- Tool Properties (floating) ----
        if (activeTool !is null) {
            pushPanelChromeStyle();
            ImGui.SetNextWindowPos(ImVec2(layout.sideW + 10, 10), ImGuiCond.FirstUseEver);
            ImGui.SetNextWindowSize(ImVec2(220, 110), ImGuiCond.FirstUseEver);
            if (ImGui.Begin("Tool Properties"))
                activeTool.drawProperties();
            ImGui.End();
            popPanelChromeStyle();
        }

        // ---- Command History (floating) ----
        // Toggled by the history.show command. Lists undo entries (top
        // = most recent) and redo entries below a separator. Read-only
        // for now; click-to-jump is an obvious follow-up.
        if (showHistoryPanel) {
            pushPanelChromeStyle();
            ImGui.SetNextWindowPos(ImVec2(layout.sideW + 10, 130), ImGuiCond.FirstUseEver);
            ImGui.SetNextWindowSize(ImVec2(240, 320), ImGuiCond.FirstUseEver);
            bool open = showHistoryPanel;
            if (ImGui.Begin("Command History", &open)) {
                auto undos = history.undoLabels;
                auto redos = history.redoLabels;
                ImGui.TextDisabled("Undo (%d)", cast(int)undos.length);
                // Most-recent first — iterate in reverse so the top of the
                // stack is at the top of the list.
                foreach_reverse (l; undos)
                    ImGui.BulletText("%s", l);
                ImGui.Separator();
                ImGui.TextDisabled("Redo (%d)", cast(int)redos.length);
                foreach_reverse (l; redos)
                    ImGui.BulletText("%s", l);
            }
            ImGui.End();
            // Honor the [x] close button on the window.
            if (!open) showHistoryPanel = false;
            popPanelChromeStyle();
        }

        // ShowDemoWindow();


        // ---- Gizmo 3D (orientation indicator, bottom-right of 3D view) ----
        DrawGizmo(layout.sideW + 32.0f, cameraView.height - layout.statusH - 32.0f, cameraView.view);

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

        // ---- RMB path trail ----
        if (rmbPath.length >= 2) {
            ImDrawList* dl = ImGui.GetForegroundDrawList();
            for (size_t i = 1; i < rmbPath.length; i++)
                dl.AddLine(rmbPath[i - 1], rmbPath[i], IM_COL32(0, 255, 255, 220), 1.0f);
            // Closing line: start → end
            dl.AddLine(rmbPath[0], rmbPath[$ - 1], IM_COL32(0, 255, 255, 220), 1.0f);
        }

        ImGui.Render();

        // Refresh subpatch preview if the cage or depth changed since last
        // frame.
        subpatchPreview.rebuildIfStale(mesh, subpatchDepth);

        // Re-upload GPU buffers when transitioning between cage/preview view
        // or when the cage changed during an active preview. While the
        // preview is active, tool-side gpu.upload calls are redirected to
        // bump mutationVersion (see GpuMesh.suppressCageUpload) so this main
        // loop owns the actual upload.
        {
            bool wantPreview = subpatchPreview.active;
            gpu.suppressCageUpload = wantPreview;
            bool versionChanged = gpuUploadedVersion != mesh.mutationVersion;
            bool stateChanged   = gpuUploadedPreview != wantPreview;
            if ((wantPreview && (versionChanged || stateChanged)) ||
                (!wantPreview && stateChanged))
            {
                if (wantPreview)
                    gpu.upload(subpatchPreview.mesh,
                               subpatchPreview.trace.edgeOrigin,
                               subpatchPreview.trace.vertOrigin,
                               subpatchPreview.trace.faceOrigin);
                else
                    gpu.upload(mesh);
                gpuUploadedVersion = mesh.mutationVersion;
                gpuUploadedPreview = wantPreview;
            }
        }

        // ---- 3D render ----
        glClearColor(0.36f, 0.40f, 0.42f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Restrict rendering to the 3D viewport area (exclude panels).
        float scaleX = cast(float)fbW / winW;
        float scaleY = cast(float)fbH / winH;
        glViewport(cast(int)(layout.vpX   * scaleX),
                   cast(int)(layout.vpGlY * scaleY),
                   cast(int)(cameraView.width  * scaleX),
                   cast(int)(cameraView.height * scaleY));

        // When a tool defers GPU uploads (whole-mesh drag), apply the accumulated
        // transform as u_model so the mesh appears correctly without re-uploading
        // vertex data every frame.
        float[16] meshModel = identityMatrix;
        {
            TransformTool tt = cast(TransformTool)activeTool;
            if (tt !is null)
                meshModel = tt.gpuMatrix;
        }

        shader.useProgram(meshModel, cameraView);

        // ---- Grid axis lines (alpha-blended, distance + edge fade) ----
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        // glDepthMask(GL_FALSE);

        gridShader.useProgram(identityMatrix, cameraView,
            cameraView.distance * 2.0f,
            cast(float)cameraView.width * scaleX, cast(float)cameraView.height * scaleY,
            cast(float)layout.vpX * scaleX, cast(float)layout.vpGlY * scaleY);

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
                            foreach (e; mesh.faceEdges(cast(uint)fi))
                                edgeSet[edgeKey(e.a, e.b)] = true;
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
