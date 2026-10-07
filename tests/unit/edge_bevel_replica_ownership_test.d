// Task 6512 — an EdgeBevel visual replica may draw, but only the owner cell
// may publish the interaction frame and register the hit-test handle.
module tests.unit.edge_bevel_replica_ownership_test;

import bindbc.opengl;
import bindbc.sdl;
import display_state : DrawPlan;
import editmode : EditMode;
import eventlog : parkOverrideMouse, setOverrideMouse;
import handler : CubicArrow, gizmoPixelSize, gizmoBoxHalfPx, GIZMO_ALPHA_ARM,
    GIZMO_STROKE_SCALE_SHAFT_PX, HandleState, getGizmoPixels, setGizmoPixels;
import math : Vec3, Viewport, isOrtho, lookAt, orthographicMatrix,
    projectToWindowFull;
import mesh : Mesh, edgeKey;
import mesh_gpu : GpuMesh;
import operator : VectorStack;
import overlay_space : OverlaySpace;
import perf_probe : g_fc, DrawPass;
import shader : LitShader, Shader;
import std.conv : to;
import std.file : readText;
import std.format : format;
import std.math : abs;
import std.json : JSONValue, parseJSON;
import params : injectParamsInto;
import std.process : environment;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode, countOccurrences,
    enclosingSymbols, lineOf, symbolAt, symbolTokenHits;
import tool : Tool;
import toolpipe.packets : SubjectPacket;
import tools.edit.edge_bevel : EdgeBevelTool, EdgeBevelState, EdgeBevelProfile;
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
    g_fc.endFrame();
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

private bool identChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private size_t[] wordLinesInSymbol(string code, string word,
                                   string wantedSymbol) {
    size_t[] lines;
    const symbols = enclosingSymbols(code);
    size_t from;
    while (from + word.length <= code.length) {
        const rel = code[from .. $].indexOf(word);
        if (rel < 0) break;
        const at = from + cast(size_t)rel;
        const end = at + word.length;
        const before = at == 0 || !identChar(code[at - 1]);
        const after = end == code.length || !identChar(code[end]);
        if (before && after) {
            immutable size_t line = lineOf(code, at);
            if (symbolAt(symbols, line - 1) == wantedSymbol) lines ~= line;
        }
        from = at + word.length;
    }
    return lines;
}

private size_t[] assignmentLinesInSymbol(string code, string field,
                                         string wantedSymbol) {
    size_t[] lines;
    const symbols = enclosingSymbols(code);
    size_t from;
    while (from + field.length <= code.length) {
        const rel = code[from .. $].indexOf(field);
        if (rel < 0) break;
        const at = from + cast(size_t)rel;
        const end = at + field.length;
        const before = at == 0
            || (!identChar(code[at - 1]) && code[at - 1] != '.');
        const afterIdent = end < code.length && identChar(code[end]);
        size_t eq = end;
        while (eq < code.length && (code[eq] == ' ' || code[eq] == '\t'
                                    || code[eq] == '\r' || code[eq] == '\n'))
            ++eq;
        const assigns = before && !afterIdent && eq < code.length
            && code[eq] == '=' && (eq + 1 == code.length || code[eq + 1] != '=');
        if (assigns) {
            immutable size_t line = lineOf(code, at);
            if (symbolAt(symbols, line - 1) == wantedSymbol) lines ~= line;
        }
        from = at + field.length;
    }
    return lines;
}

private size_t tokenCountInSymbol(string code, string file, string needle,
                                  string wantedSymbol) {
    size_t count;
    foreach (ref hit; symbolTokenHits(code, file, needle))
        if (hit.key == wantedSymbol) ++count;
    return count;
}

private void cellC0_arrangementCensus() {
    enum viewportPath = "source/ui/viewport_render.d";
    const viewportCode = blankNonCode(readText(viewportPath));
    assert(countOccurrences(viewportCode,
        "bool visualOnly = (mode == OverlayMode.Visual);") == 1,
        "C0 VIEWPORT MODE DERIVATION: expected exactly 1 production site");
    assert(countOccurrences(viewportCode,
        "inputs.activeTool.draw(shader, viewport, vts, inputs.plan, visualOnly);") == 1,
        "C0 VIEWPORT TOOL CALL: expected exactly 1 production site");
    immutable forwardCall =
        "drawToolOverlays(inputs, mode, viewport, shader);";
    assert(tokenCountInSymbol(viewportCode, viewportPath, forwardCall,
        "ViewportSceneRenderer.drawToolOverlaysForTest") == 1,
        "C0 FORWARDER BODY: expected drawToolOverlays(inputs, mode, viewport, shader) exactly once");

    enum edgePath = "source/tools/edit/edge_bevel.d";
    const edgeCode = blankNonCode(readText(edgePath));
    enum drawSymbol = "EdgeBevelTool.draw";
    enum replicaSymbol = "EdgeBevelTool.drawReplica";
    assert(tokenCountInSymbol(edgeCode, edgePath, "if (visualOnly)",
                              drawSymbol) == 1,
        "C0 EDGE DISPATCH: expected exactly one if (visualOnly) in EdgeBevelTool.draw");

    immutable deriveFloor = tokenCountInSymbol(edgeCode, edgePath,
        "ensureReplicaFrame(", replicaSymbol);
    immutable arrowFloor = tokenCountInSymbol(edgeCode, edgePath,
        "replicaArrow_", replicaSymbol);
    assert(deriveFloor > 0 && arrowFloor > 0, format(
        "C0 DRAW REPLICA POPULATION: expected cache-derive>0 and arrow>0 got derive=%s arrow=%s",
        deriveFloor, arrowFloor));
    immutable ownerPublish = tokenCountInSymbol(edgeCode, edgePath,
        "publishOwnerFrameToReplica();", "EdgeBevelTool.computeGizmoFrame");
    assert(ownerPublish == 1, format(
        "C0 OWNER MEMO PUBLICATION: expected 1 got %s", ownerPublish));

    foreach (word; ["cachedVp", "toolHandles", "widthArrow", "queryMouse",
                    "rebuildPreview", "preview_", "before"]) {
        const lines = wordLinesInSymbol(edgeCode, word, replicaSymbol);
        assert(lines.length == 0, format(
            "FORBIDDEN IDENTIFIER IN drawReplica: %s at lines %s; expected none",
            word, lines));
    }
    foreach (field; ["gizmoValid", "baseAnchor", "anchor", "widthAxis",
                     "gizmoSelHash"]) {
        const lines = assignmentLinesInSymbol(edgeCode, field, replicaSymbol);
        assert(lines.length == 0, format(
            "FORBIDDEN WRITE IN drawReplica: assignment to `%s` at lines %s; expected none",
            field, lines));
    }

    const appCode = blankNonCode(readText("source/app.d"));
    assert(countOccurrences(appCode, "foreach (k; overlayDrawOrder(") == 1,
        "C0 OWNER-LAST: expected exactly one overlayDrawOrder loop in source/app.d");
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

private ulong switchSelectionToB(ref Mesh mesh) {
    immutable int edgeA = findEdge(mesh, 0, 1);
    immutable int edgeB = findEdge(mesh, 4, 7);
    assert(edgeA >= 0 && edgeB >= 0, format(
        "SELECTION B FIXTURE: expected A>=0 and B>=0 got A=%s B=%s",
        edgeA, edgeB));
    mesh.deselectEdge(edgeA);
    mesh.selectEdge(edgeB);
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
    assert(pass.writes == 4, format(
        "OWNER HANDLE DRAWS: expected two shafts+heads=4 got %s (tol 0)",
        pass.writes));
    assert(pass.submitted == 2, format(
        "OWNER HANDLE SUBMISSIONS: expected 2 got %s (tol 0)",
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
    const registered = tool.toolHandlesJson()["parts"].array;
    assert(registered.length == 2, "S1 REGISTRATION: complete ordered bank");
    assert(registered[0]["part"].integer == 0 && registered[0]["visible"].boolean,
        "S1 REGISTERED WIDTH: eligible first part");
    assert(registered[1]["part"].integer == 1 && registered[1]["visible"].boolean,
        "TWO HANDLES: eligible second part");
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

private void assertReplicaB(EdgeBevelTool tool, ref Viewport replicaVp) {
    Vec3 start, end;
    size_t drawId;
    const cubes = tool.replicaArrowForTest(start, end, drawId);
    foreach (cube; cubes) {
        assert(cube.fixedCubeHalf == gizmoPixelSize(Vec3(1.5f, 6, 0),
            replicaVp, gizmoBoxHalfPx()), "REPLICA CUBE SIZE: Scale clamped extent");
        assert(cube.alpha == GIZMO_ALPHA_ARM &&
            cube.lineWidth == GIZMO_STROKE_SCALE_SHAFT_PX && cube.doubledShaft,
            "REPLICA CUBE STEM: Scale stroke and fill conventions");
    }
    assertVecNear(start, Vec3(1.5f, 7, 0), 1e-4f,
                  "REPLICA WORLD START");
    assertVecNear(end, Vec3(1.5f, 12, 0), 1e-4f,
                  "REPLICA WORLD END");
    assertProjected(start, replicaVp, 600.0f, 220.0f,
                    "REPLICA FRESH PROJECTED START");
    assertProjected(end, replicaVp, 600.0f, 120.0f,
                    "REPLICA FRESH PROJECTED END");
    const pass = g_fc.lastHandlePass();
    assert(g_fc.last().pass[DrawPass.handles].verts == 40,
        "REPLICA CUBE RASTER: doubled stem and 36-vertex cube head");
    // Native fallback column0 is parallel to this replica camera.
    assert(pass.submitted == 1, format(
        "REPLICA HANDLE SUBMISSIONS: expected visible width only=1 got %s (tol 0)",
        pass.submitted));
    assert(pass.ids[0] == drawId, format(
        "REPLICA HANDLE ID: expected replica %s got %s (tol 0)",
        drawId, pass.ids[0]));
}

private void assertReplicaFrozenA(EdgeBevelTool tool,
                                  ref Viewport replicaVp,
                                  string reason) {
    Vec3 start, end;
    size_t drawId;
    tool.replicaArrowForTest(start, end, drawId);
    assertProjected(start, replicaVp, 580.0f, 360.0f,
                    "REPLICA IGNORED THE FROZEN ANCHOR " ~ reason
                    ~ " START");
    assertProjected(end, replicaVp, 480.0f, 360.0f,
                    "REPLICA IGNORED THE FROZEN ANCHOR " ~ reason
                    ~ " END");
    // Keep the independent world-space witness below the projected boundary:
    // the projection is the named first red line, while these two assertions
    // retain the channel that can move along kView's depth without moving px/py.
    assertVecNear(start, Vec3(2, 0, 1), 1e-4f,
                  "FROZEN REPLICA WORLD START " ~ reason);
    assertVecNear(end, Vec3(2, 0, 6), 1e-4f,
                  "FROZEN REPLICA WORLD END " ~ reason);
}

private void cellC3_freshness(ViewportSceneRenderer renderer, Shader shader,
                              ref GpuMesh gpu, ref Viewport replicaVp,
                              ref Viewport ownerVp) {
    auto live = twoQuadsFixture();
    immutable ulong sigA = selectionA(live);
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    tool.activate();
    setOverrideMouse(330, 230);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    assertOwnerA(tool, ownerVp);
    const before = tool.interactionStateBytesForTest();

    immutable ulong sigB = switchSelectionToB(live);
    assert(sigB != sigA, format(
        "C3 SELECTION CHANGE: expected sigB != sigA, got A=%s B=%s",
        sigA, sigB));
    drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    assertReplicaB(tool, replicaVp);
    assertStateEqual(before, tool.interactionStateBytesForTest(),
                     "OWNER INTERACTION STATE CHANGED AFTER FRESH REPLICA");

    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    Vec3 ownerStart, ownerEnd;
    size_t ownerId;
    tool.widthArrowForTest(ownerStart, ownerEnd, ownerId);
    assertVecNear(ownerStart, Vec3(1.5f, 8, 0), 1e-4f,
                  "OWNER B WORLD START");
    assertVecNear(ownerEnd, Vec3(1.5f, 18, 0), 1e-4f,
                  "OWNER B WORLD END");
    assertProjected(ownerStart, ownerVp, 400.0f, 150.0f,
                    "OWNER B PROJECTED START");
    assertProjected(ownerEnd, ownerVp, 400.0f, 50.0f,
                    "OWNER B PROJECTED END");
    const read = tool.readInteractionForTest();
    assert(read.gizmoSelHash == sigB && read.cachedWidth == 800, format(
        "OWNER B PUBLICATION: expected hash=%s width=800 got hash=%s width=%s",
        sigB, read.gizmoSelHash, read.cachedWidth));

    setOverrideMouse(400, 100);
    SDL_MouseButtonEvent press;
    press.button = SDL_BUTTON_LEFT;
    press.x = 400;
    press.y = 100;
    VectorStack vts;
    assert(tool.onMouseButtonDown(press, vts),
        "OWNER B HIT TEST: expected true got false at (400,100)");
    assert(tool.readInteractionForTest().dragPart == 0, format(
        "OWNER B DRAG PART: expected 0 got %s (tol 0)",
        tool.readInteractionForTest().dragPart));
}

private void cellC4_invalidOwnerFrame(ViewportSceneRenderer renderer,
                                      Shader shader, ref GpuMesh gpu,
                                      ref Viewport replicaVp,
                                      ref Viewport ownerVp) {
    Mesh live;
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    tool.activate();
    setOverrideMouse(330, 230);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    auto read = tool.readInteractionForTest();
    assert(!read.gizmoValid, "C4 INVALID OWNER FRAME: expected false got true");
    assert(g_fc.lastHandlePass().submitted == 0, format(
        "C4 INVALID OWNER SUBMISSIONS: expected 0 got %s (tol 0)",
        g_fc.lastHandlePass().submitted));
    assert(read.cachedWidth == 800, format(
        "C4 OWNER CACHED WIDTH: expected 800 got %s (tol 0)",
        read.cachedWidth));

    live = twoQuadsFixture();
    immutable int edgeB = findEdge(live, 4, 7);
    assert(edgeB >= 0, "C4 SELECTION B: expected edge (4,7), got none");
    live.selectEdge(edgeB);
    immutable ulong sigB = live.selectionSignature(EditMode.Edges);
    assert(sigB != 0, "C4 SELECTION SIGNATURE: expected nonzero got 0");
    const before = tool.interactionStateBytesForTest();
    drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    assert(g_fc.lastHandlePass().submitted == 1, format(
        "REPLICA VISIBLE WIDTH: submitted == %s, expected 1",
        g_fc.lastHandlePass().submitted));
    assertReplicaB(tool, replicaVp);
    assertStateEqual(before, tool.interactionStateBytesForTest(),
                     "C4 OWNER INTERACTION STATE CHANGED");

    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    assert(tool.readInteractionForTest().gizmoValid,
        "C4 OWNER RECOVERY: expected valid frame got invalid");
}

private void beginWidthDrag(EdgeBevelTool tool) {
    setOverrideMouse(330, 230);
    SDL_MouseButtonEvent press;
    press.button = SDL_BUTTON_LEFT;
    press.x = 330;
    press.y = 230;
    VectorStack vts;
    auto state = tool.stateForTest();
    state.miterOffset = 0.09f;
    tool.stateForTest(state);
    assert(tool.onMouseButtonDown(press, vts),
        "WIDTH DRAG PRESS: expected true got false at (330,230)");
    assert(tool.scalarStartsDeltasForTest()[0 .. 2] == [state.width, 0.09f],
        "S1 PRESS: snapshots both independent starts");
    auto widthVp = testViewport(800, 400, 20.0f);
    assert(tool.firstBankHitForTest(330, 230, widthVp) == 0,
        "S1 BANK HIT: width positive control");
}

private void cellC5_activeDrag(ViewportSceneRenderer renderer, Shader shader,
                               ref GpuMesh gpu, ref Viewport replicaVp,
                               ref Viewport ownerVp) {
    auto live = twoQuadsFixture();
    selectionA(live);
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    tool.activate();
    setOverrideMouse(330, 230);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    beginWidthDrag(tool);
    auto read = tool.readInteractionForTest();
    assert(read.dragPart == 0 && !read.built, format(
        "C5 ACTIVE DRAG FLOOR: expected dragPart=0 built=false got part=%s built=%s",
        read.dragPart, read.built));
    switchSelectionToB(live);
    const before = tool.interactionStateBytesForTest();
    drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    assertReplicaFrozenA(tool, replicaVp, "during an active drag");
    assertStateEqual(before, tool.interactionStateBytesForTest(),
                     "C5 OWNER INTERACTION STATE CHANGED");
}

private int nearestUniqueVertex(ref Mesh mesh, Vec3 target, string label) {
    int best = -1;
    float bestD2 = float.max;
    float secondD2 = float.max;
    foreach (i, value; mesh.vertices) {
        immutable Vec3 d = value - target;
        immutable float d2 = d.x*d.x + d.y*d.y + d.z*d.z;
        if (d2 < bestD2) {
            secondD2 = bestD2;
            bestD2 = d2;
            best = cast(int)i;
        } else if (d2 < secondD2) {
            secondD2 = d2;
        }
    }
    assert(best >= 0 && bestD2 <= 0.25f, format(
        "%s nearest vertex: expected d2 <= 0.25 got index=%s d2=%.6f",
        label, best, bestD2));
    assert(secondD2 > 0.25f, format(
        "%s uniqueness: expected second d2 > 0.25 got %.6f",
        label, secondD2));
    return best;
}

private void cellC6_builtPreview(ViewportSceneRenderer renderer, Shader shader,
                                 ref GpuMesh gpu, ref Viewport replicaVp,
                                 ref Viewport ownerVp) {
    auto live = twoQuadsFixture();
    selectionA(live);
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    tool.activate();
    setOverrideMouse(330, 230);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    beginWidthDrag(tool);

    SDL_MouseMotionEvent motion;
    motion.x = 324;
    motion.y = 230;
    VectorStack motionStack;
    assert(tool.onMouseMotion(motion, motionStack),
        "C6 MOTION: expected true got false for 6 px motion");
    auto read = tool.readInteractionForTest();
    assert(read.built, "C6 BUILT FLOOR: expected true got false at 6 px");
    assert(tool.stateForTest().miterOffset == 0.09f &&
        tool.scalarStartsDeltasForTest()[3] == 0.0f,
        "S1 MOTION: dormant scalar and delta stay independent");
    assert(tool.scalarStartsDeltasForTest()[2] != 0.0f,
        "S1 MOTION: operative width delta retained");

    SDL_MouseButtonEvent release;
    release.button = SDL_BUTTON_LEFT;
    VectorStack releaseStack;
    assert(tool.onMouseButtonUp(release, releaseStack),
        "C6 RELEASE: expected true got false");
    read = tool.readInteractionForTest();
    assert(read.dragPart == -1 && read.built, format(
        "C6 RELEASE FLOOR: expected dragPart=-1 built=true got part=%s built=%s",
        read.dragPart, read.built));

    immutable int a = nearestUniqueVertex(live, Vec3(0, 6, 0), "C6 B START");
    immutable int b = nearestUniqueVertex(live, Vec3(3, 6, 0), "C6 B END");
    assert(a != b, format(
        "C6 B DISTINCT VERTICES: expected different indices got %s and %s",
        a, b));
    immutable int edgeB = findEdge(live, cast(uint)a, cast(uint)b);
    assert(edgeB >= 0, format(
        "C6 B EDGE: expected an edge between %s and %s, got none", a, b));
    assert(!live.hasAnySelectedEdges(),
        "C6 SELECTION RESET FLOOR: expected no selected edges after rebuild");
    live.selectEdge(edgeB);
    assert(live.selectionSignature(EditMode.Edges) != read.gizmoSelHash,
        "C6 SELECTION CHANGE FLOOR: expected signature to differ from frozen frame");

    const before = tool.interactionStateBytesForTest();
    drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    assertReplicaFrozenA(tool, replicaVp, "with a built preview");
    assertStateEqual(before, tool.interactionStateBytesForTest(),
                     "C6 OWNER INTERACTION STATE CHANGED");
}

private void cellC7_noEdges(ViewportSceneRenderer renderer, Shader shader,
                            ref GpuMesh gpu, ref Viewport replicaVp) {
    Mesh live;
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    tool.activate();
    const before = tool.interactionStateBytesForTest();
    drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    assert(g_fc.lastHandlePass().submitted == 0, format(
        "REPLICA SUBMITTED A HANDLE WITH NO VALID FRAME: submitted == %s, expected 0",
        g_fc.lastHandlePass().submitted));
    assertStateEqual(before, tool.interactionStateBytesForTest(),
                     "C7 OWNER INTERACTION STATE CHANGED");
}

private void cellC8_ownerMemoFreezesReplica(ViewportSceneRenderer renderer,
                                            Shader shader, ref GpuMesh gpu,
                                            ref Viewport replicaVp,
                                            ref Viewport ownerVp) {
    auto live = twoQuadsFixture();
    immutable ulong sigA = selectionA(live);
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    tool.activate();
    setOverrideMouse(330, 230);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    assertOwnerA(tool, ownerVp);

    // Position is deliberately version/signature-silent here.  The resident
    // owner frame must seed the replica memo, or the foreign cell re-derives a
    // shifted anchor even though the selection identity did not change.
    live.vertices[0].x += 5.0f;
    immutable ulong afterMove = live.selectionSignature(EditMode.Edges);
    assert(afterMove == sigA, format(
        "C8 SIGNATURE FLOOR: expected unchanged %s got %s", sigA, afterMove));
    const before = tool.interactionStateBytesForTest();
    drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    assertReplicaFrozenA(tool, replicaVp,
                         "after a signature-stable vertex move");
    assertStateEqual(before, tool.interactionStateBytesForTest(),
                     "C8 OWNER INTERACTION STATE CHANGED");
}

private void cellC9_oneDeriveForAllReplicas(ViewportSceneRenderer renderer,
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
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);

    immutable ulong sigB = switchSelectionToB(live);
    tool.resetPreparedGizmoFrameCallsForTest();
    enum size_t replicaCount = 3;
    foreach (_; 0 .. replicaCount)
        drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    immutable size_t calls = tool.preparedGizmoFrameCallsForTest();
    // The isolated old-path mutation measured 4 here: one derive per replica
    // plus one for the owner.  The shared memo makes the whole frame cost one.
    assert(calls == 1, format(
        "REPLICA FRAME DERIVE COUNT: expected 1 for %s replicas plus owner got %s",
        replicaCount, calls));
    assert(tool.readInteractionForTest().gizmoSelHash == sigB, format(
        "C9 OWNER PUBLICATION: expected hash=%s got %s", sigB,
        tool.readInteractionForTest().gizmoSelHash));
}

private void cellC10_replicaMirrorsResidentPaint(
        ViewportSceneRenderer renderer, Shader shader, ref GpuMesh gpu,
        ref Viewport replicaVp, ref Viewport ownerVp) {
    auto live = twoQuadsFixture();
    selectionA(live);
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    tool.activate();
    setOverrideMouse(330, 230);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);

    Vec3 ownerBase, ownerResolved, replicaBase, replicaResolved;
    HandleState ownerState, replicaState;
    bool ownerEngaged, replicaEngaged;
    tool.widthPaintForTest(ownerBase, ownerResolved, ownerState, ownerEngaged);
    assert(ownerState == HandleState.Rollover && !ownerEngaged, format(
        "C10 OWNER HOT FLOOR: expected rollover/false got %s/%s",
        ownerState, ownerEngaged));

    drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    tool.replicaPaintForTest(replicaBase, replicaResolved,
                             replicaState, replicaEngaged);
    assertVecNear(replicaBase, Vec3(0.20f, 0.40f, 1.00f), 0,
                  "REPLICA BASE COLOR");
    assert(replicaState == ownerState && !replicaEngaged, format(
        "REPLICA HOT STATE: expected %s/false got %s/%s",
        ownerState, replicaState, replicaEngaged));
    assertVecNear(replicaResolved, Vec3(1.00f, 0.90f, 0.40f), 0,
                  "REPLICA HOT COLOR");

    beginWidthDrag(tool);
    drawOverlay(renderer, tool, OverlayMode.Interactive, ownerVp, shader);
    tool.widthPaintForTest(ownerBase, ownerResolved, ownerState, ownerEngaged);
    assert(ownerState == HandleState.Rollover && ownerEngaged, format(
        "C10 OWNER ENGAGED FLOOR: expected rollover/true got %s/%s",
        ownerState, ownerEngaged));
    drawOverlay(renderer, tool, OverlayMode.Visual, replicaVp, shader);
    tool.replicaPaintForTest(replicaBase, replicaResolved,
                             replicaState, replicaEngaged);
    assert(replicaState == ownerState && replicaEngaged, format(
        "REPLICA ENGAGED STATE: expected %s/true got %s/%s",
        ownerState, replicaState, replicaEngaged));
    assertVecNear(replicaResolved, ownerResolved, 0,
                  "REPLICA ENGAGED COLOR");
}

// Dormant S1 data use our values; these are storage/isolation checks, not
// reference defaults, placement, signed translation or miter geometry goldens.
private void cellS1Dormant() {
    Mesh live = twoQuadsFixture();
    GpuMesh gpu;
    EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    auto params = tool.params();
    assert(params.length == 4, "S1 ADMISSION: scalar parameter admission");
    assert(params[0].name == "width" && params[1].name == "roundLevel" &&
        params[2].name == "widthMode", "S1 ADMISSION: retained parameter order");
    assert(tool.sessionPolicy().imageAttrs == ["width", "roundLevel", "widthMode", "miterOffset"],
        "TWO HANDLES: independent session field admission");

    assert(params[3].name == "miterOffset", "MITER PARAM: public schema name");
    assert(tool.sessionPolicy().haulAttrs == ["width", "roundLevel", "widthMode", "miterOffset"],
        "MITER SESSION: independent haul field");
    auto miterWrite = JSONValue.emptyObject;
    miterWrite["miterOffset"] = JSONValue(-0.06f);
    injectParamsInto(params, miterWrite);
    assert(tool.stateForTest().miterOffset == 0.0f && tool.stateForTest().width == 0,
        "MITER PARAM: effective zero floor and isolated binding");
    const initial = tool.stateForTest();
    auto modeWrite = JSONValue.emptyObject;
    modeWrite["widthMode"] = JSONValue(true);
    injectParamsInto(params, modeWrite);
    const modeState = tool.stateForTest();
    assert(modeState.sharpCorner == initial.sharpCorner &&
        modeState.miterOffset == initial.miterOffset,
        "S1 MODE ISOLATION: public mode write leaves dormant fields alone");
    assert(tool.toolStateJson()["widthMode"].boolean,
        "S1 MODE PARAM: actual injected binding reaches widthMode");
    tool.stateForTest(initial);

    tool.seedPreparedParamForTest(live);
    auto baseline = tool.stateForTest();
    assert(baseline.width == 0.2f && baseline.roundLevel == 1 && !baseline.widthMode,
        "S1 SEEDED STATE: actual prepared fixture reaches the reader");
    auto image = tool.buildPreparedParamUpdate("width", live);
    assert(tool.preparedParamUpdateMatches(image, live), "S1 PROJECTION: positive control");
    foreach (field; 0 .. 9) {
        auto changed = baseline;
        final switch (field) {
            case 0: changed.width = 0.3f; break;
            case 1: changed.roundLevel = 2; break;
            case 2: changed.widthMode = true; break;
            case 3: changed.profile = EdgeBevelProfile.sharp; break;
            case 4: changed.miterOffset = 0.07f; break;
            case 5: changed.sharpCorner = true; break;
            case 6: changed.maintainCoplanar = true; break;
            case 7: changed.materialOverride = true; break;
            case 8: changed.materialName = "S1-owned-tag"; break;
        }
        tool.stateForTest(changed);
        assert(!tool.preparedParamUpdateMatches(image, live),
            "S1 PROJECTION: stale field " ~ field.to!string);
        tool.stateForTest(baseline);
        assert(tool.preparedParamUpdateMatches(image, live),
            "S1 PROJECTION: restored positive field " ~ field.to!string);
    }
    auto zero = baseline;
    zero.width = 0.0f;
    zero.miterOffset = 0.0f;
    tool.stateForTest(zero);
    auto zeroImage = tool.buildPreparedParamUpdate("width", live);
    assert(tool.preparedParamUpdateMatches(zeroImage, live), "ZERO IMAGE: positive control");
    zero.width = -0.0f;
    tool.stateForTest(zero);
    assert(!tool.preparedParamUpdateMatches(zeroImage, live),
        "S1 WIDTH BITS: signed zero is distinct image data");
    zero.width = 0.0f;
    zero.miterOffset = -0.0f;
    tool.stateForTest(zero);
    assert(!tool.preparedParamUpdateMatches(zeroImage, live),
        "S1 MITER BITS: signed zero is distinct image data");
    auto state = baseline;
    state.width = 0.4f; state.miterOffset = 0.09f;
    tool.stateForTest(state);
    Mesh* preparedSource;
    auto activation = tool.buildPreparedActivation(preparedSource);
    assert(preparedSource is &live, "S1 ACTIVATION: retained source owner");
    tool.installPreparedActivation(activation);
    assert(tool.stateForTest() == state,
        "S1 ACTIVATION: admitted and dormant state survives install");
    tool.snapshotStartsForTest();
    assert(tool.scalarStartsDeltasForTest() == [0.4f, 0.09f, 0.0f, 0.0f],
        "S1 STARTS: independent starts, untouched deltas");
    assert(tool.scalarBindingsForTest() == [0, 1, 2, 0],
        "S1 BINDINGS: width/normal then miter/tangent");
    const parts = tool.handlePartsForTest();
    assert(parts.length == 2 && parts[0].part == 0 && parts[1].part == 1 &&
        parts[0].h !is parts[1].h, "S1 BANK: ordered distinct parts");
    assert(parts[0].h.isVisible() && parts[1].h.isVisible(),
        "TWO HANDLES: both parts eligible");
    Viewport vp = testViewport(800, 600, 5);
    assert(tool.firstBankHitForTest(-10000, -10000, vp) == -1,
        "S1 BANK: populated miss");
}

private void cellTwoHandleCallbacks() {
    const fixture = parseJSON(readText("tests/fixtures/edge_bevel/two_handles_live.json"));
    const moves = fixture["moves"].array;
    assert(moves.length == 5, "LIVE FIXTURE: two width and three miter callbacks");
    Mesh live = twoQuadsFixture(); GpuMesh gpu; EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    foreach (i, row; moves) {
        const int part = cast(int) row["id"].integer;
        assert(row["attr"].integer == (part == 0 ? 1 : 7),
            "LIVE FIXTURE: independent callback attribute identity");
        if (i == 0 || i == 2) {
            auto state = tool.stateForTest();
            state.width = cast(float) row["start0"].floating;
            state.miterOffset = cast(float) row["start1"].floating;
            tool.stateForTest(state); tool.snapshotStartsForTest();
        }
        tool.updateScalarForTest(part,
            cast(float) row[part == 0 ? "delta0" : "delta1"].floating);
        const state = tool.stateForTest();
        const deltas = tool.scalarStartsDeltasForTest();
        assert(abs(deltas[2] - row["delta0"].floating) < 1e-7 &&
            abs(deltas[3] - row["delta1"].floating) < 1e-7,
            "LIVE CALLBACK: independent per-press deltas");
        assert(abs((part == 0 ? state.width : state.miterOffset) -
            (row["value"].floating < 0 ? 0 : row["value"].floating)) < 1e-7, "LIVE CALLBACK: effective bound cumulative value");
        assert(abs((part == 0 ? state.miterOffset : state.width) -
            row[part == 0 ? "start1" : "start0"].floating) < 1e-7,
            "LIVE CALLBACK: other field unchanged");
    }
    auto state = tool.stateForTest();
    tool.snapshotStartsForTest();
    tool.updateScalarForTest(1, 0.03f);
    assert(abs(tool.stateForTest().miterOffset - (state.miterOffset + 0.03f)) < 1e-7,
        "SECOND PRESS: independent nonzero miter start");
}

private void cellCapturedPreparedBasis(ViewportSceneRenderer renderer, Shader shader,
        ref GpuMesh gpu, ref Viewport vp) {
    const fixture = parseJSON(readText("tests/fixtures/edge_bevel/two_handles_live.json"));
    const origin = fixture["origin"].array;
    const matrix = fixture["matrix_row_major"].array;
    assert(origin.length == 3 && matrix.length == 9, "BASIS FIXTURE: full captured frame");
    Mesh live = twoQuadsFixture(); selectionA(live); EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    Mesh* source;
    auto image = tool.buildPreparedActivation(source);
    image.anchor = image.baseAnchor = Vec3(cast(float)origin[0].floating,
        cast(float)origin[1].floating, cast(float)origin[2].floating);
    image.widthAxis = Vec3(cast(float)matrix[2].floating,
        cast(float)matrix[5].floating, cast(float)matrix[8].floating);
    image.miterAxis = Vec3(cast(float)matrix[0].floating,
        cast(float)matrix[3].floating, cast(float)matrix[6].floating);
    const base = image.baseAnchor; const normal = image.widthAxis; const tangent = image.miterAxis;
    tool.installPreparedActivation(image);
    drawOverlay(renderer, tool, OverlayMode.Interactive, vp, shader);
    auto parts = tool.handlePartsForTest();
    auto width = cast(CubicArrow)parts[0].h; auto miter = cast(CubicArrow)parts[1].h;
    assert(width !is null && miter !is null,
        "CUBE REGISTRATION: both picked parts reuse Scale CubicArrow");
    import viewport_scheme : axisColor;
    assert(width.color == axisColor(2) && miter.color == axisColor(0),
        "CUBE COLORS: blue Width and red Mitering");
    const half = gizmoPixelSize(base, vp, gizmoBoxHalfPx());
    assert(width.fixedCubeHalf == half && miter.fixedCubeHalf == half,
        "CUBE SIZE: both heads use Scale clamped extent");
    assert(width.alpha == GIZMO_ALPHA_ARM && miter.alpha == GIZMO_ALPHA_ARM &&
        width.lineWidth == GIZMO_STROKE_SCALE_SHAFT_PX &&
        miter.lineWidth == GIZMO_STROKE_SCALE_SHAFT_PX &&
        width.doubledShaft && miter.doubledShaft,
        "CUBE STEM: shared Scale stroke and fill conventions");
    assert(g_fc.last().pass[DrawPass.handles].verts == 80,
        "CUBE RASTER: two doubled Scale stems and two 36-vertex cube heads");
    foreach (i, cube; [width, miter]) {
        const dir = (cube.end - cube.start) / (cube.end - cube.start).length;
        float x, y, z;
        assert(projectToWindowFull(cube.end - dir * half, vp, x, y, z),
            "CUBE PICK: head center projects");
        assert(tool.firstBankHitForTest(cast(int)x, cast(int)y, vp) == i,
            "CUBE PICK: drawn head selects its registered scalar part");
    }
    assertVecNear((width.end - width.start) * (1 / (width.end - width.start).length),
        normal, 1e-6f, "CAPTURED BASIS: ID0 consumes column2");
    assertVecNear((miter.end - miter.start) * (1 / (miter.end - miter.start).length),
        tangent, 1e-6f, "CAPTURED BASIS: ID1 consumes column0");
    assertVecNear(width.start - (width.end - width.start) * 0.2f, base, 1e-6f,
        "CAPTURED ORIGIN: ID0 shared base");
    assertVecNear(miter.start - (miter.end - miter.start) * 0.2f, base, 1e-6f,
        "CAPTURED ORIGIN: ID1 shared base");
}

private void cellTwoHandleEvents(ViewportSceneRenderer renderer, Shader shader,
        ref GpuMesh gpu, ref Viewport vp) {
    Mesh live = twoQuadsFixture(); selectionA(live); EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() => &live, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    Mesh* eventSource;
    auto eventFrame = tool.buildPreparedActivation(eventSource);
    eventFrame.miterAxis = Vec3(0, 1, 0);
    eventFrame.widthAxis = Vec3(1, 0, 0);
    tool.installPreparedActivation(eventFrame);
    drawOverlay(renderer, tool, OverlayMode.Interactive, vp, shader);
    auto arrow = cast(CubicArrow) tool.handlePartsForTest()[1].h;
    float x, y, depth;
    assert(projectToWindowFull((arrow.start + arrow.end) * 0.5f, vp, x, y, depth),
        "MITER EVENT: visible projected handle");
    setOverrideMouse(cast(int)x, cast(int)y);
    drawOverlay(renderer, tool, OverlayMode.Interactive, vp, shader);
    SDL_MouseButtonEvent press; press.button = SDL_BUTTON_LEFT;
    press.x = cast(int)x; press.y = cast(int)y; VectorStack stack;
    assert(tool.onMouseButtonDown(press, stack), "MITER EVENT: production press accepted");
    assert(tool.readInteractionForTest().dragPart == 1, "MITER EVENT: part1 owns haul");
    const width = tool.stateForTest().width;
    float ax, ay, az, bx, by, bz;
    assert(projectToWindowFull(arrow.start, vp, ax, ay, az) &&
        projectToWindowFull(arrow.end, vp, bx, by, bz), "MITER EVENT: scalar axis projects");
    import std.math : sqrt;
    const float projected = sqrt((bx-ax)*(bx-ax) + (by-ay)*(by-ay));
    assert(projected > 0, "MITER EVENT: positive projected axis population");
    SDL_MouseMotionEvent motion;
    motion.x = press.x + cast(int)(64 * (bx-ax) / projected);
    motion.y = press.y + cast(int)(64 * (by-ay) / projected);
    assert(tool.onMouseMotion(motion, stack), "MITER EVENT: production move accepted");
    const miter = tool.stateForTest().miterOffset;
    assert(miter != 0, "MITER EVENT: second handle writes its scalar");
    assert(tool.stateForTest().width == width, "MITER EVENT: first handle field isolation");
    SDL_MouseButtonEvent release; release.button = SDL_BUTTON_LEFT;
    assert(tool.onMouseButtonUp(release, stack), "MITER EVENT: production release accepted");
    assert(tool.stateForTest().miterOffset == miter, "MITER EVENT: release preserves live field");
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
    cellC0_arrangementCensus();
    cellS1Dormant();
    cellTwoHandleCallbacks();
    cellCapturedPreparedBasis(renderer, shader, gpu, ownerVp);
    cellTwoHandleEvents(renderer, shader, gpu, ownerVp);
    cellC1_ownerOnly(renderer, shader, gpu, ownerVp);
    cellC2_replicaThenOwner(renderer, shader, gpu, replicaVp, ownerVp);
    cellC3_freshness(renderer, shader, gpu, replicaVp, ownerVp);
    cellC4_invalidOwnerFrame(renderer, shader, gpu, replicaVp, ownerVp);
    cellC5_activeDrag(renderer, shader, gpu, replicaVp, ownerVp);
    cellC6_builtPreview(renderer, shader, gpu, replicaVp, ownerVp);
    cellC7_noEdges(renderer, shader, gpu, replicaVp);
    cellC8_ownerMemoFreezesReplica(renderer, shader, gpu, replicaVp, ownerVp);
    cellC9_oneDeriveForAllReplicas(renderer, shader, gpu, replicaVp, ownerVp);
    cellC10_replicaMirrorsResidentPaint(renderer, shader, gpu,
                                        replicaVp, ownerVp);
}

unittest { // task 20261290: measured asymmetric source owner frame
    import std.json : parseJSON;
    import std.file : readText;
    auto fixture = parseJSON(readText("tests/fixtures/edge_bevel/frame_source.json"));
    auto receipt = parseJSON(readText("tests/fixtures/edge_bevel/two_handles_live.json"));
    Mesh source;
    foreach (row; fixture["vertices"].array)
        source.addVertex(Vec3(cast(float)row[0].floating, cast(float)row[1].floating, cast(float)row[2].floating));
    foreach (row; fixture["faces"].array) {
        uint[] ring; foreach (v; row.array) ring ~= cast(uint)v.integer; source.addFace(ring);
    }
    source.rebuildEdges(); source.buildLoops(); source.resizeEdgeSelection();
    foreach (pair; fixture["selection"]["edges"].array) {
        auto key = edgeKey(cast(uint)pair[0].integer, cast(uint)pair[1].integer);
        source.selectEdge(cast(int)source.edgeIndexMap[key]);
    }
    GpuMesh gpu; EditMode mode = EditMode.Edges;
    auto tool = new EdgeBevelTool(() nothrow @nogc => &source, &gpu, &mode, LitShader.init);
    scope(exit) tool.destroy();
    auto frame = tool.preparedFrameForTest(source);
    auto origin = receipt["origin"];
    auto matrix = receipt["matrix_row_major"];
    assert(frame.gizmoValid, "FRAME SOURCE: selected endpoint population");
    assert((frame.baseAnchor - Vec3(cast(float)origin[0].floating,
        cast(float)origin[1].floating, cast(float)origin[2].floating)).length < 2e-6,
        "FRAME ORIGIN: captured bounding box center");
    assert((frame.widthAxis - Vec3(cast(float)matrix[2].floating,
        cast(float)matrix[5].floating, cast(float)matrix[8].floating)).length < 2e-6,
        "FRAME WIDTH: native matrix column two");
    assert((frame.miterAxis - Vec3(cast(float)matrix[0].floating,
        cast(float)matrix[3].floating, cast(float)matrix[6].floating)).length < 2e-6,
        "FRAME MITER: native matrix column zero");
}
