// Task 6512 — an EdgeBevel visual replica may draw, but only the owner cell
// may publish the interaction frame and register the hit-test handle.
module tests.unit.edge_bevel_replica_ownership_test;

import bindbc.opengl;
import bindbc.sdl;
import display_state : DrawPlan;
import editmode : EditMode;
import eventlog : parkOverrideMouse, setOverrideMouse;
import handler : HandleState, getGizmoPixels, setGizmoPixels;
import math : Vec3, Viewport, isOrtho, lookAt, orthographicMatrix,
    projectToWindowFull;
import mesh : Mesh;
import mesh_gpu : GpuMesh;
import operator : VectorStack;
import overlay_space : OverlaySpace;
import perf_probe : g_fc;
import shader : LitShader, Shader;
import std.conv : to;
import std.file : readText;
import std.format : format;
import std.math : abs;
import std.process : environment;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode, countOccurrences,
    enclosingSymbols, lineOf, symbolAt, symbolTokenHits;
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

private void assertReplicaB(EdgeBevelTool tool, ref Viewport replicaVp) {
    Vec3 start, end;
    size_t drawId;
    tool.replicaArrowForTest(start, end, drawId);
    assertVecNear(start, Vec3(1.5f, 7, 0), 1e-4f,
                  "REPLICA WORLD START");
    assertVecNear(end, Vec3(1.5f, 12, 0), 1e-4f,
                  "REPLICA WORLD END");
    assertProjected(start, replicaVp, 600.0f, 220.0f,
                    "REPLICA FRESH PROJECTED START");
    assertProjected(end, replicaVp, 600.0f, 120.0f,
                    "REPLICA FRESH PROJECTED END");
    const pass = g_fc.lastHandlePass();
    assert(pass.submitted == 1, format(
        "REPLICA HANDLE SUBMISSIONS: expected 1 got %s (tol 0)",
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
        "REPLICA DREW NOTHING on a valid current selection: submitted == %s, expected 1",
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
    assert(tool.onMouseButtonDown(press, vts),
        "WIDTH DRAG PRESS: expected true got false at (330,230)");
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
    assertVecNear(replicaBase, Vec3(0.20f, 0.45f, 1.00f), 0,
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
