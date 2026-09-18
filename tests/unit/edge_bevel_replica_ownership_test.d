// Task 6512 — an EdgeBevel visual replica may draw, but only the owner cell
// may publish the interaction frame and register the hit-test handle.
module tests.unit.edge_bevel_replica_ownership_test;

import bindbc.opengl;
import bindbc.sdl;
import display_state : DrawPlan;
import editmode : EditMode;
import eventlog : parkOverrideMouse, setOverrideMouse;
import handler : getGizmoPixels, setGizmoPixels;
import math : Vec3, Viewport, isOrtho, lookAt, orthographicMatrix,
    projectToWindowFull;
import mesh : Mesh;
import mesh_gpu : GpuMesh;
import operator : VectorStack;
import overlay_space : OverlaySpace;
import perf_probe : g_fc;
import shader : LitShader, Shader;
import std.conv : to;
import std.format : format;
import std.math : abs;
import std.process : environment;
import tool : Tool;
import toolpipe.packets : SubjectPacket;
import tools.edit.edge_bevel : EdgeBevelTool;
import ui.viewport_render : ToolOverlayInputs, ViewportSceneRenderer;
import viewport_overlay_mode : OverlayMode;

private immutable float[16] kView = [
     0, 0,  1, 0,
     0, 1,  0, 0,
    -1, 0,  0, 0,
     0,-3,-10, 1,
];

private Mesh twoQuadsFixture() {
    Mesh m;
    m.vertices = [
        Vec3(0, 0,  0), Vec3(4, 0,  0),
        Vec3(4, 2,  0), Vec3(0, 2,  0),
        Vec3(0, 6,  0), Vec3(0, 6, -2),
        Vec3(3, 6, -2), Vec3(3, 6,  0),
    ];
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 7u, 6u, 5u]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private int findEdge(ref Mesh m, uint a, uint b) {
    foreach (i; 0 .. m.edges.length) {
        immutable uint x = m.edges[i][0];
        immutable uint y = m.edges[i][1];
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

private Viewport testViewport(int width, int height, float halfHeight) {
    Viewport vp;
    vp.view[] = kView[];
    vp.proj = orthographicMatrix(halfHeight,
        cast(float)width / cast(float)height, 0.1f, 100.0f);
    vp.width = width;
    vp.height = height;
    vp.eye = Vec3(10, 3, 0);
    vp.focus = Vec3(0, 3, 0);
    return vp;
}

private ToolOverlayInputs overlayInputs(Tool tool) {
    ToolOverlayInputs inputs;
    inputs.activeTool = tool;
    inputs.gizmoHost = null;
    inputs.buildSubject = (out SubjectPacket subject, ref VectorStack vts) {};
    inputs.plan = DrawPlan.init;
    inputs.falloffActive = false;
    return inputs;
}

private void drawOverlay(ViewportSceneRenderer renderer, Tool tool,
                         OverlayMode mode, ref Viewport vp, Shader shader) {
    g_fc.reset();
    g_fc.beginFrame();
    renderer.drawToolOverlaysForTest(overlayInputs(tool), mode, vp, shader);
}

private void assertNear(float actual, float expected, float tolerance,
                        string label) {
    immutable float delta = abs(actual - expected);
    assert(delta <= tolerance, format(
        "%s: expected %.6f got %.6f delta %.6f (tol %.6f)",
        label, expected, actual, delta, tolerance));
}

private void assertVecNear(Vec3 actual, Vec3 expected, float tolerance,
                           string label) {
    assertNear(actual.x, expected.x, tolerance, label ~ ".x");
    assertNear(actual.y, expected.y, tolerance, label ~ ".y");
    assertNear(actual.z, expected.z, tolerance, label ~ ".z");
}

private void assertProjected(Vec3 world, ref const Viewport vp,
                             float expectedX, float expectedY,
                             string label) {
    float px, py, depth;
    assert(projectToWindowFull(world, vp, px, py, depth), format(
        "%s: expected projection (%.2f,%.2f), got an unprojectable point %s",
        label, expectedX, expectedY, world));
    assertNear(px, expectedX, 0.01f, label ~ " px");
    assertNear(py, expectedY, 0.01f, label ~ " py");
}

private void assertStateEqual(const ubyte[] expected, const ubyte[] actual,
                              string label) {
    assert(actual.length == expected.length, format(
        "%s length: expected %s got %s (tol 0)",
        label, expected.length, actual.length));
    foreach (i; 0 .. expected.length)
        assert(actual[i] == expected[i], format(
            "%s at byte %s: expected %s got %s (tol 0)",
            label, i, expected[i], actual[i]));
}

private void selectA(ref Mesh mesh) {
    immutable int edge = findEdge(mesh, 0, 1);
    assert(edge >= 0, "FIXTURE EDGE A: expected edge (0,1), got none");
    mesh.selectEdge(edge);
}

private ulong selectionA(ref Mesh mesh) {
    selectA(mesh);
    return mesh.selectionSignature(EditMode.Edges);
}

private void assertOwnerA(EdgeBevelTool tool, ref Viewport ownerVp) {
    Vec3 start, end;
    size_t drawId;
    tool.widthArrowForTest(start, end, drawId);
    assertVecNear(start, Vec3(2, 0, 2), 1e-4f, "OWNER WORLD START");
    assertVecNear(end, Vec3(2, 0, 12), 1e-4f, "OWNER WORLD END");
    assertProjected(start, ownerVp, 380.0f, 230.0f, "OWNER PROJECTED START");
    assertProjected(end, ownerVp, 280.0f, 230.0f, "OWNER PROJECTED END");
    const read = tool.readInteractionForTest();
    assert(read.cachedWidth == 800, format(
        "OWNER CACHED VIEWPORT WIDTH: expected 800 got %s (tol 0)",
        read.cachedWidth));
    const pass = g_fc.lastHandlePass();
    assert(pass.submitted == 1, format(
        "OWNER HANDLE SUBMISSIONS: expected 1 got %s (tol 0)",
        pass.submitted));
    assert(pass.ids[0] == drawId, format(
        "OWNER HANDLE ID: expected %s got %s (tol 0)",
        drawId, pass.ids[0]));
}

private void premiseFloors(ref Viewport replicaVp, ref Viewport ownerVp) {
    assert(getGizmoPixels() == 120.0f, format(
        "F1 GIZMO PIXELS: expected 120 got %.6f (tol 0)",
        getGizmoPixels()));
    assert(isOrtho(replicaVp) && isOrtho(ownerVp),
        "F2 ORTHOGRAPHIC VIEWPORTS: expected both true, got false");
    assert(!OverlaySpace.ofPrimary().active,
        "F3 OVERLAY SPACE: expected inactive identity space, got active");
    immutable expectedView = lookAt(Vec3(10, 3, 0), Vec3(0, 3, 0),
                                    Vec3(0, 1, 0));
    assert(kView[] == expectedView[], format(
        "F4 VIEW MATRIX: expected %s got %s (tol 0)",
        expectedView, kView));

    auto mesh = twoQuadsFixture();
    assert(mesh.vertices.length == 8 && mesh.faces.length == 2
           && mesh.edges.length == 8, format(
        "F5 FIXTURE POPULATION: expected v=8 f=2 e=8 got v=%s f=%s e=%s",
        mesh.vertices.length, mesh.faces.length, mesh.edges.length));
    assertVecNear(mesh.faceNormal(0), Vec3(0, 0, 1), 0,
                  "F6 FACE P NORMAL");
    assertVecNear(mesh.faceNormal(1), Vec3(0, 1, 0), 0,
                  "F6 FACE Q NORMAL");
    immutable int edgeA = findEdge(mesh, 0, 1);
    immutable int edgeB = findEdge(mesh, 4, 7);
    assert(edgeA >= 0 && edgeB >= 0, format(
        "F7 FIXTURE EDGES: expected A>=0 and B>=0 got A=%s B=%s",
        edgeA, edgeB));
    mesh.selectEdge(edgeA);
    immutable ulong sigA = mesh.selectionSignature(EditMode.Edges);
    mesh.deselectEdge(edgeA);
    mesh.selectEdge(edgeB);
    immutable ulong sigB = mesh.selectionSignature(EditMode.Edges);
    assert(sigA != sigB && sigB != 0, format(
        "F8 SELECTION SIGNATURES: expected sigA!=sigB and sigB!=0 got A=%s B=%s",
        sigA, sigB));
}

private void cellC1_ownerOnly(ViewportSceneRenderer renderer, Shader shader,
                              ref GpuMesh gpu, ref Viewport ownerVp) {
    auto live = twoQuadsFixture();
    immutable ulong sigA = selectionA(live);
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    tool.activate();
    setOverrideMouse(330, 230);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    assertOwnerA(tool, ownerVp);
    const read = tool.readInteractionForTest();
    assert(read.gizmoSelHash == sigA, format(
        "OWNER SELECTION SIGNATURE: expected %s got %s (tol 0)",
        sigA, read.gizmoSelHash));
}

private void cellC2_replicaThenOwner(ViewportSceneRenderer renderer,
                                     Shader shader, ref GpuMesh gpu,
                                     ref Viewport replicaVp,
                                     ref Viewport ownerVp) {
    auto live = twoQuadsFixture();
    selectionA(live);
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    tool.activate();
    setOverrideMouse(330, 230);

    // Establish the byte baseline on this instance: the snapshot includes the
    // registered Handler address, so cross-instance bytes are intentionally
    // not comparable.
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    const baselineOwnerA = tool.interactionStateBytesForTest();

    drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    assertOwnerA(tool, ownerVp);
    assertStateEqual(baselineOwnerA, tool.interactionStateBytesForTest(),
                     "C2 OWNER STATE AFTER REPLICA");
}

unittest { runReplicaOwnershipWitness(); }

private void runReplicaOwnershipWitness() {
    const hadDriver = "SDL_VIDEODRIVER" in environment;
    const oldDriver = environment.get("SDL_VIDEODRIVER", "");
    environment["SDL_VIDEODRIVER"] =
        environment.get("DISPLAY", "").length != 0 ? "x11" : "offscreen";
    scope(exit) {
        if (hadDriver) environment["SDL_VIDEODRIVER"] = oldDriver;
        else environment.remove("SDL_VIDEODRIVER");
    }

    assert(loadSDL() == sdlSupport,
        "replica ownership rig could not load SDL");
    assert(SDL_Init(SDL_INIT_VIDEO) == 0,
        "replica ownership rig could not initialize SDL: "
        ~ SDL_GetError().to!string);
    scope(exit) SDL_Quit();

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    auto window = SDL_CreateWindow("edge-bevel-replica-ownership-witness",
        SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, 96, 64,
        SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    assert(window !is null,
        "replica ownership rig could not create a hidden SDL window: "
        ~ SDL_GetError().to!string);
    scope(exit) SDL_DestroyWindow(window);

    auto context = SDL_GL_CreateContext(window);
    assert(context !is null,
        "replica ownership rig could not create an OpenGL context: "
        ~ SDL_GetError().to!string);
    scope(exit) SDL_GL_DeleteContext(context);
    SDL_GL_SetSwapInterval(0);
    assert(loadOpenGL() >= glSupport,
        "replica ownership rig could not load OpenGL 3.3");

    scope(exit) parkOverrideMouse();
    scope(exit) g_fc.reset();
    immutable float oldGizmoPixels = getGizmoPixels();
    scope(exit) setGizmoPixels(oldGizmoPixels);

    auto shader = new Shader();
    scope(exit) destroy(shader);
    GpuMesh gpu;
    gpu.init();
    scope(exit) gpu.destroy();
    auto renderer = new ViewportSceneRenderer();
    auto replicaVp = testViewport(1200, 600, 15.0f);
    auto ownerVp = testViewport(800, 400, 20.0f);

    premiseFloors(replicaVp, ownerVp);
    cellC1_ownerOnly(renderer, shader, gpu, ownerVp);
    cellC2_replicaThenOwner(renderer, shader, gpu, replicaVp, ownerVp);
}
