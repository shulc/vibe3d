// test_edge_slice_history_order.d — item 8 witness: an Edge Slice chain's
// history row lands BEFORE the rows of whatever follows it.
//
// Measured law (captured): the application row of a live slice session is
// recorded right after its own gestures, and the next action's rows after it.
// Shift+click applies the chain and re-arms the tool; a click that hits no
// edge while the chain is live is absorbed by the tool. A tool switch (W)
// commits the chain first — with the live subpatch preview too, where the
// switch used to be refused and every later row landed below the chain's.
//
// Rig: the 4x4 flat grid (tests/slice_grid_helpers.d), top-down camera;
// input is real SDL events through /api/play-events, Shift = mod 1 on the
// motion and the button. Block order (green above red): C (the click probe
// reaches the picker), A (a rejected click leaves the session alone), S
// (Shift+click applies and re-arms), then O-poly and O-sub in their own
// unittests (the tool switch records the chain first).

import slice_grid_helpers;
import slice_leak_helpers;
import http_client : getJson;
import std.format : format;
import std.json;
import std.stdio : writeln;
import core.thread : Thread;
import core.time : msecs;

void main() {}

enum SDLK_RBRACKET = 93;

/// Selected edge indices.
long[] selEdges() {
    long[] r;
    foreach (e; getJson("/api/selection")["selectedEdges"].array) r ~= e.integer;
    return r;
}

void selectEdge(long e) {
    slCmd("mesh.select", format(`{"mode":"edges","indices":[%d]}`, e));
}

/// A full LMB click (hover, press, release) with modifier `mod` on every event.
void clickMod(int[2] p, int mod, string what) {
    slPlay(format(`{"t":20.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%d}`
                  ~ "\n" ~ `{"t":40.0,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%d}`
                  ~ "\n" ~ `{"t":60.0,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}`
                  ~ "\n" ~ `{"t":80.0,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}`,
                  p[0], p[1], mod, p[0], p[1], mod, p[0], p[1], mod, p[0], p[1], mod), what);
}

void click(int[2] p, string what) { clickMod(p, 0, what); }

int[2] pxEmpty() { return pixelOf(3.2, 0, -2.5); }   // off the grid
int[2] pxFace()  { return pixelOf(-1.5, 0, -0.5); }  // centre of a far face

/// Latch a point on the grid edge (x0,z)-(x1,z) at its midpoint (click, no drag).
void latchOnEdge(double x0, double x1, double z, string what) {
    const pr = gridPair(x0, z, x1, z);
    const p = pixelOf((x0 + x1) / 2, 0, z);
    hoverFloor(p, pr[0], pr[1], what);
    click(p, what);
}

void arm(string tag) {
    slLine("tool.set mesh.edgeSliceTool on");
    assert(slTool() == "edgeSlice", "history order floor: Edge Slice did not activate (" ~ tag ~ ")");
}

/// Arm Edge Slice (unless already armed) and latch points 1 and 2 on x in [0,1] at z = 0 and z = 1.
void armTwo(string tag, bool activate = true) {
    if (activate) arm(tag);
    latchOnEdge(0, 1, 0, "point 1 (" ~ tag ~ ")");
    latchOnEdge(0, 1, 1, "point 2 (" ~ tag ~ ")");
    const m = slMesh();
    assert(m.verts == 27 && m.faces == 17 && slChain().pairs.length == 2,
           format("history order floor: two points did not bake (27, 17) (%s): mesh %s pairs %s",
                  tag, m.toString, slPairsStr(slChain().pairs)));
}

string[] addedSince(const string[] before) {
    auto now = slHistoryLabels();
    assert(now.length >= before.length && now[0 .. before.length] == before,
           format("history order: an earlier row changed: before %s, now %s", before, now));
    return now[before.length .. $].dup;
}

/// Tool switch by the real W key; the needle of blocks O-poly and O-sub.
void switchNeedle(string suffix) {
    const L1 = slHistoryLabels();
    slKey(SL_SDLK_w, 0, "W (" ~ suffix ~ ")");
    const tool = slTool();
    const added = addedSince(L1);
    assert(tool != "edgeSlice" && added == ["Edge Slice", "Activate Tool"],
           format("Edge Slice row is not immediately before the next tool's row (%s): tool %s, added %s",
                  suffix, tool, added));
}

void waitSettled(string what) {
    foreach (_; 0 .. 100) {
        if (getJson("/api/subpatch/preview")["pending"].type == JSONType.false_) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "history order floor: the subpatch preview is still pending after 5 s (" ~ what ~ ")");
}

// Blocks C, A, S (subpatch OFF).
unittest {
    gridRig(false);
    const m0 = getJson("/api/model");
    const Es = slEdgeOf(m0, gridVert(m0, -2, 2), gridVert(m0, -1, 2));
    assert(Es >= 0, "history order rig: the far edge E_s is missing");

    // Block C — no tool: the probe clicks reach the picker.
    selectEdge(Es);
    assert(selEdges() == [Es], format("block C floor: selection is %s, not [%d]", selEdges(), Es));
    click(pxEmpty(), "C empty");
    assert(selEdges() != [Es], "click probe does not reach the picker (empty)");
    selectEdge(Es);
    assert(selEdges() == [Es], format("block C floor: reselect gave %s", selEdges()));
    click(pxFace(), "C face");
    assert(selEdges() != [Es], "click probe does not reach the picker (face)");

    // Block A — with a live chain, a click on no edge is absorbed.
    arm("A");
    slHover(pxEmpty()[0], pxEmpty()[1]);
    assert(getJson("/api/tool/state")["hoveredEdge"].integer == -1,
           "block A floor: the empty pixel hovers an edge");
    slHover(pxFace()[0], pxFace()[1]);
    assert(getJson("/api/tool/state")["hoveredEdge"].integer == -1,
           "block A floor: the face pixel hovers an edge");
    armTwo("A", false);
    // The bake of point 2 clears the edge selection, and an empty selection
    // cannot show a click that reached the selection path (clearing nothing
    // and picking nothing leaves it empty): select the far edge again, by
    // position, so S0 is non-empty.
    const m2 = getJson("/api/model");
    const Es2 = slEdgeOf(m2, gridVert(m2, -2, 2), gridVert(m2, -1, 2));
    selectEdge(Es2);
    const L0 = slHistoryLabels();
    const S0 = selEdges();
    assert(S0 == [Es2] && slChain().pairs.length == 2,
           format("block A floor: selection %s, not [%d], or the chain dropped", S0, Es2));
    const P0 = slChain().pairs;
    writeln("block A: L0 ", L0, " S0 ", S0, " pairs ", slPairsStr(P0));
    foreach (k, px; [pxEmpty(), pxFace()]) {
        const tag = k == 0 ? "empty" : "face";
        click(px, "A " ~ tag);
        const m = slMesh();
        assert(slHistoryLabels() == L0 && slChain().pairs == P0 && m.verts == 27
               && m.faces == 17 && selEdges() == S0 && slTool() == "edgeSlice",
               format("rejected click changed the session (%s): labels %s pairs %s mesh %s sel %s tool %s",
                      tag, slHistoryLabels(), slPairsStr(slChain().pairs), m.toString,
                      selEdges(), slTool()));
    }

    // Block S — Shift+click applies the chain and re-arms the tool.
    clickMod(pxFace(), SL_KMOD_LSHIFT, "S shift+click");
    {
        const m = slMesh();
        const lab = slHistoryLabels();
        assert(lab == L0 ~ ["Edge Slice"] && slChain().pairs.length == 0 && m.verts == 27
               && m.faces == 17 && slTool() == "edgeSlice",
               format("shift+click did not apply and re-arm: labels %s pairs %s mesh %s tool %s",
                      lab, slPairsStr(slChain().pairs), m.toString, slTool()));
    }
    slKey(SL_SDLK_z, SL_KMOD_LCTRL, "S Ctrl+Z");
    {
        const m = slMesh();
        assert(slHistoryLabels() == L0 && m.verts == GRID_VERTS && m.faces == GRID_FACES
               && slTool() == "edgeSlice" && slChain().pairs.length == 0,
               format("undo after shift-apply is not K1: labels %s mesh %s tool %s pairs %s",
                      slHistoryLabels(), m.toString, slTool(), slPairsStr(slChain().pairs)));
    }
    latchOnEdge(0, 1, 0, "S one point");
    assert(slChain().pairs.length == 1, "block S floor: one point did not latch");
    const L2 = slHistoryLabels();
    clickMod(pxFace(), SL_KMOD_LSHIFT, "S shift+click one point");
    assert(slChain().pairs.length == 1 && slHistoryLabels() == L2,
           format("shift+click on a one-point chain changed the session: pairs %s labels %s (was %s)",
                  slPairsStr(slChain().pairs), slHistoryLabels(), L2));
    slLine("tool.set mesh.edgeSliceTool off");
}

// Block O-poly — W commits the chain, then the next tool's row (subpatch OFF).
unittest {
    gridRig(false);
    armTwo("O-poly");
    switchNeedle("subpatch OFF");
    const m = slMesh();
    assert(m.verts == 27 && m.faces == 17,
           "block O-poly floor: the committed mesh is not (27, 17): " ~ m.toString);
}

// Block O-sub — the same with a live subpatch preview; the control first.
unittest {
    gridRig(true);
    armTwo("O-sub control");
    const Lc = slHistoryLabels();
    slKey(SDLK_RBRACKET, 0, "] (O-sub control)");
    const addedC = addedSince(Lc);
    assert(addedC == ["Edge Slice", "select.connect"],
           format("order probe cannot see the commit row (subpatch ON): added %s", addedC));

    gridRig(true);
    armTwo("O-sub");
    waitSettled("before W");
    // The display half: pending/previewFaces/mesh all hold BEFORE W as well,
    // so the term that can fail is the preview's build counter — the switch
    // commit must hand the preview a new mesh image to build.
    auto pv0 = getJson("/api/subpatch/preview");
    const faces0 = pv0["previewFaces"].integer, builds0 = pv0["builds"].integer;
    writeln("block O-sub: before W previewFaces ", faces0, " builds ", builds0);
    switchNeedle("subpatch ON");
    waitSettled("after W");
    auto pv1 = getJson("/api/subpatch/preview");
    const faces1 = pv1["previewFaces"].integer, builds1 = pv1["builds"].integer;
    const m = slMesh();
    writeln("block O-sub: after W previewFaces ", faces1, " builds ", builds1);
    assert(builds1 > builds0 && faces1 > 0 && m.verts == 27 && m.faces == 17,
           format("display did not follow the switch commit (subpatch ON): builds %d -> %d, "
                  ~ "previewFaces %d, mesh %s", builds0, builds1, faces1, m.toString));
}
