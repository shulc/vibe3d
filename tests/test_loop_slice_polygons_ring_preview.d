// Loop Slice Polygons-mode ring preview — task 0399.
//
// BUG (0399): Loop Slice showed NO interactive ring preview while the
// editor was in Polygons edit mode (e.g. right after Tab-subpatch, which
// leaves you in Polygons mode with faces selected). Root cause: app.d's
// edge-draw block only built/drew the loop-slice ring
// (`rebuildLoopHoverMask`/`wantsEdgeLoopHover`) inside
// `if (editMode == EditMode.Edges)` — the `EditMode.Polygons` branch drew
// only the face-selection edges and never touched the ring. Loop Slice IS
// supported in Polygons mode (`supportedModes`, task 0245's
// `activationSeeds`/`interiorEdgesOfSelectedFaces` selection-based
// activation from the selected faces' shared edge) — it just had no visual
// preview there.
//
// FIX: app.d's Polygons-mode edge-draw branch now also previews the ring,
// seeded from the SELECTION (there is no hovered EDGE in Polygons mode)
// via the tool's new `LoopSliceTool.selectionRingPreviewMask()` helper.
// `toolStateJson()` exposes the same mask as a new `selectionRing` field so
// this can be asserted headlessly, without a screenshot.
//
// P1 — Polygons mode, tool active, NOTHING selected: `selectionRing` is
//      empty (no preview to show — the fix must not manufacture one).
// P2 — Polygons mode, two ADJACENT selected faces (front + bottom, sharing
//      the equatorial edge 0-1): `selectionRing` is non-empty and matches
//      the SAME ring Edges-mode hover already reports for that seed edge
//      (`sliceRing`) — cross-validated against the established Edges-mode
//      computation rather than a hardcoded index set, so this test is tied
//      to the actual kernel call (`Mesh.loopSliceRingEdges`) both paths
//      share.
// P3 — negative/regression: Edges-mode hover `sliceRing` is BYTE-IDENTICAL
//      to the pre-0399 ground truth pinned by
//      tests/test_loop_slice_hover_state.d (belt {0,2,5,7} through edge 5)
//      — the Polygons-mode addition must not perturb the Edges-mode
//      draw/state path. Also checks `selectionRing` stays empty there (no
//      face selection exists in that scenario).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs, sqrt;
import std.string : format;
import std.algorithm : sort, uniq;
import std.array : array;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

void resetCube() {
    auto resp = post(baseUrl ~ "/api/reset", "");
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/reset failed: " ~ cast(string)resp);
}

void cmd(string s) {
    auto resp = post(baseUrl ~ "/api/script", s);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ cast(string)resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post(baseUrl ~ "/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
        "/api/select failed: " ~ cast(string)resp);
}

JSONValue getModel()     { return parseJSON(cast(string)get(baseUrl ~ "/api/model")); }
JSONValue getToolState() { return parseJSON(cast(string)get(baseUrl ~ "/api/tool/state")); }

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

// --- geometry helpers (mirror tests/test_loop_slice_tool.d /
//     tests/test_loop_slice_post_selection.d / tests/test_loop_slice_hover_state.d) ---

struct V3 { double x, y, z; }

V3 vert(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer;
        int y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

int vertAt(JSONValue m, V3 p) {
    foreach (i; 0 .. m["vertices"].array.length) {
        auto v = vert(m, i);
        auto dx = v.x - p.x, dy = v.y - p.y, dz = v.z - p.z;
        if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-4) return cast(int)i;
    }
    return -1;
}

size_t[] faceVerts(JSONValue m, size_t fi) {
    size_t[] r;
    foreach (v; m["faces"].array[fi].array) r ~= cast(size_t)v.integer;
    return r;
}

// The face index whose 4 corners all share coordinate `val` on axis
// (0=x,1=y,2=z) — one of the six original cube faces.
int cubeFaceAtConst(JSONValue m, int axis, double val) {
    foreach (fi; 0 .. m["faces"].array.length) {
        bool allOn = true;
        foreach (vi; faceVerts(m, fi)) {
            auto v = vert(m, vi);
            double c = (axis == 0) ? v.x : (axis == 1) ? v.y : v.z;
            if (abs(c - val) > 1e-4) { allOn = false; break; }
        }
        if (allOn) return cast(int)fi;
    }
    return -1;
}

int[] dedupSorted(JSONValue arr) {
    int[] xs;
    foreach (v; arr.array) xs ~= cast(int)v.integer;
    return xs.sort().uniq().array;
}

// 5 stationary motion events (no button) at (x,y) — same hover-injection
// pattern as tests/test_loop_slice_hover_state.d.
string hoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    return log;
}

unittest { // P1 + P2: Polygons-mode selectionRing — empty pre-select,
           // non-empty (and matching the Edges-mode ground truth) post-select.
    resetCube();
    auto model = getModel();
    // The edge between (0.5,-0.5,0.5) and (0.5,0.5,0.5) — the SAME seed edge
    // tests/test_loop_slice_hover_state.d hovers (proven camera-visible from
    // the default test camera pose; unlike an arbitrary cube edge, which may
    // be back-facing/occluded and never register a hover — that was this
    // test's first failure mode). It is shared by exactly two ADJACENT
    // faces: x=+0.5 and z=+0.5 (both faces' vertex sets intersect in exactly
    // these two corners).
    int va = vertAt(model, V3(0.5, -0.5, 0.5));
    int vb = vertAt(model, V3(0.5,  0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube verts (0.5,-0.5,0.5)/(0.5,0.5,0.5) not found");
    int seedEi = edgeIndex(model, va, vb);
    assert(seedEi >= 0, "cube edge (0.5,-0.5,0.5)-(0.5,0.5,0.5) not found");
    int faceXplus = cubeFaceAtConst(model, 0, 0.5);
    int faceZplus = cubeFaceAtConst(model, 2, 0.5);
    assert(faceXplus >= 0 && faceZplus >= 0, "cube x=+0.5/z=+0.5 faces not found");

    // --- Ground truth: Edges-mode hover ring for the SAME seed edge (the
    // computation test_loop_slice_hover_state.d already pins). Cross-
    // validating the new Polygons-mode field against this, rather than
    // hardcoding an expected edge-index set, ties the assertion to the
    // actual `Mesh.loopSliceRingEdges` call both paths share. ---
    cmd("select.typeFrom edge");
    cmd("tool.set mesh.loopSliceTool on");
    settle();
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 mid = Vec3(0.5f, 0.0f, 0.5f);   // seed edge midpoint
    float sx, sy;
    assert(projectToWindow(mid, vp, sx, sy), "seed edge midpoint should be on-camera");
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cast(int)sx, cast(int)sy));
    settle();
    auto hoverSt = getToolState();
    assert(hoverSt["hoveredEdge"].integer == seedEi,
        "hover ground-truth: expected hoveredEdge " ~ seedEi.to!string ~
        ", got " ~ hoverSt["hoveredEdge"].integer.to!string);
    int[] expectedRing = dedupSorted(hoverSt["sliceRing"]);
    assert(expectedRing.length > 0, "ground-truth Edges-mode sliceRing must be non-empty");
    cmd("tool.set mesh.loopSliceTool off");

    // --- P1: Polygons mode, tool active, NOTHING selected -> empty preview. ---
    resetCube();   // fresh mesh + selection, undo the Edges-mode probe above
    cmd("select.typeFrom polygon");
    cmd("tool.set mesh.loopSliceTool on");
    settle();
    auto emptySt = getToolState();
    assert(emptySt["tool"].str == "loopSlice",
        "expected loopSlice tool state, got: " ~ emptySt.toString);
    assert(emptySt["armed"].type == JSONType.false_,
        "must not auto-arm on activation with nothing selected");
    assert(dedupSorted(emptySt["selectionRing"]).length == 0,
        "Polygons mode with nothing selected: selectionRing must be empty, got "
        ~ emptySt["selectionRing"].toString);
    cmd("tool.set mesh.loopSliceTool off");

    // --- P2: select the two adjacent faces, re-activate -> non-empty ring,
    // matching the Edges-mode ground truth. This is the 0399 fix itself:
    // before it, app.d never computed/drew anything for this state (and
    // `selectionRing` did not exist on the wire). ---
    postSelect("polygons", [faceXplus, faceZplus]);
    cmd("tool.set mesh.loopSliceTool on");
    settle();
    auto st = getToolState();
    assert(st["tool"].str == "loopSlice",
        "expected loopSlice tool state, got: " ~ st.toString);
    assert(st["armed"].type == JSONType.false_,
        "a selection-seeded preview must not auto-arm (arming needs a click)");
    int[] selRing = dedupSorted(st["selectionRing"]);
    assert(selRing.length > 0,
        "Polygons mode with 2 adjacent selected faces: selectionRing must be "
        ~ "non-empty (this is the 0399 bug — empty/absent before the fix)");
    assert(selRing == expectedRing,
        "Polygons-mode selectionRing should match the Edges-mode ring for the "
        ~ "same shared seed edge: expected " ~ expectedRing.to!string ~
        " got " ~ selRing.to!string);

    cmd("tool.set mesh.loopSliceTool off");
}

unittest { // P3 (negative/regression): Edges-mode hover `sliceRing` stays
    // byte-identical to the pre-0399 ground truth
    // (tests/test_loop_slice_hover_state.d) — the Polygons-mode addition
    // must not perturb the Edges-mode draw/state path.
    resetCube();
    auto model = getModel();
    int va = vertAt(model, V3(0.5, -0.5, 0.5));
    int vb = vertAt(model, V3(0.5,  0.5, 0.5));
    assert(va >= 0 && vb >= 0, "cube verts (0.5,-0.5,0.5)/(0.5,0.5,0.5) not found");
    int ei = edgeIndex(model, va, vb);
    assert(ei >= 0, "cube edge (0.5,-0.5,0.5)-(0.5,0.5,0.5) not found");

    cmd("select.typeFrom edge");
    cmd("tool.set mesh.loopSliceTool on");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 mid = Vec3(0.5f, 0.0f, 0.5f);   // edge midpoint
    float sx, sy;
    assert(projectToWindow(mid, vp, sx, sy), "edge midpoint should be on-camera");

    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cast(int)sx, cast(int)sy));
    settle();

    auto st = getToolState();
    assert(st["hoveredEdge"].integer == ei,
        "hoveredEdge mismatch: expected " ~ ei.to!string ~
        " got " ~ st["hoveredEdge"].integer.to!string);

    int[] ring = dedupSorted(st["sliceRing"]);
    int[] expectedSliceRing = [0, 2, 5, 7];
    assert(ring == expectedSliceRing,
        "Edges-mode sliceRing regression: expected " ~ expectedSliceRing.to!string ~
        " got " ~ ring.to!string ~ " — the 0399 Polygons-mode preview change "
        ~ "must not alter Edges-mode behaviour");

    // `selectionRing` is reported unconditionally by toolStateJson() (app.d
    // only DRAWS it in Polygons mode), but `activationSeeds()` only seeds
    // from a face selection in Polygons mode — with an edge hover and no
    // face selection it must stay empty here too.
    assert(dedupSorted(st["selectionRing"]).length == 0,
        "Edges-mode (no face selection): selectionRing should stay empty, got "
        ~ st["selectionRing"].toString);

    cmd("tool.set mesh.loopSliceTool off");
}
