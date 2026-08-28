// Topology Pen — the Remove gesture's EDGE and VERTEX primitives (task 2900).
//
// THE GAP. `tests/test_topopen_remove.d` drives Ctrl+MMB onto a FACE and pins
// the polygon primitive. The same chord runs two other primitives, chosen
// inside `removeDown` from the PRESSED ELEMENT'S CLASS — `removeEdge` and
// `removeVertex` (task 0494) — and neither had any HTTP coverage at all. The
// only witness either had was the white-box unit module
// `tests/unit/tools/edit/topology_pen/gestures_test.d`, which calls the tool's
// methods directly and never plays an event, so nothing in the tree checked
// that a real press ever reaches them.
//
// THE DISCRIMINATOR IS THE RECORD'S WIRE NAME, and this file is the first in
// the 48-file topology-pen set to read one. The three primitives push three
// DIFFERENT commands — `mesh.topoPen_remove`, `mesh.topoPen_removeedge`,
// `mesh.topoPen_removevertex` — so a press that latched the wrong element
// class still changes the mesh and would satisfy a bare "something was
// removed" check. Each block below asserts the exact command name AND the
// exact resulting counts, because either alone is satisfiable by the other
// primitive:
//
//     press on  | v | e  | f | command
//     ----------+---+----+---+---------------------------
//     a face    | 8 | 12 | 5 | mesh.topoPen_remove       (the shipped pin)
//     an edge   | 8 | 11 | 5 | mesh.topoPen_removeedge   (this file)
//     a vertex  | 7 |  9 | 4 | mesh.topoPen_removevertex (this file)
//
// The face and edge rows agree on the face count, so `f == 5` cannot tell them
// apart; the edge row is separated by `e == 11` and by its name. Those numbers
// are not arbitrary — an edge dissolve merges the two quads sharing it into one
// hexagon (one face and one edge fewer, no vertex lost), and a corner dissolve
// merges the three quads meeting there into one (three edges and one vertex
// gone, two faces fewer).
//
// `built` IS NOT ON THE WIRE for this tool — `/api/tool/state` publishes it for
// exactly six tools tree-wide (`grep -rn '"built"' source/`), none of them the
// pen. The acceptance criterion's "the tool reports itself built" is therefore
// met by the stronger pair it stands for: NAMED counts moving in a NAMED
// direction, and the exact record the gesture pushed.
//
// EVERY CHANNEL HERE FAILS CLOSED: each assertion is "this moved to that", so a
// frozen `/api/model` or an `/api/history` that stopped tracking goes RED
// rather than green. No positive control is needed, and adding one would be a
// check that cannot come out differently.
//
// Run via: ./run_test.d topopen_remove_edge_vertex

import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum uint LCTRL = 0x0040;   // KMOD_LCTRL — the Remove gesture's own modifier

/// Ctrl+MMB press-and-release at (px,py). Two hover motions precede the press
/// so the pen's picker has resolved the element under the cursor before the
/// button goes down — the codebase's own `clickAt` idiom (see
/// `tests/test_edge_slice_tool.d`), and the mitigation for the documented
/// stationary-hover staleness risk.
string ctrlMmbAt(double t0, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%u}`,
                  t0, px, py, LCTRL) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%u}`,
                  t0 + 10.0, px, py, LCTRL) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0 + 20.0, px, py, LCTRL) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0 + 30.0, px, py, LCTRL);
}

/// Arm the stand on the default cube, single layer == primary (layer 0).
///
/// NO PRE-DISARM, DELIBERATELY (task 3130). `/api/reset` cancels and DROPS the
/// active tool BEFORE it replaces the geometry, so a gesture left standing by
/// an earlier stand — or by an earlier RED run of this one — cannot commit
/// into the scene this stand is about to read. The explicit
/// `tool.set <tool> off` that used to stand here (task 2900) was a workaround
/// for the opposite order. Removing it is not tidying: it makes this stand a
/// WITNESS for that guarantee instead of a file that hides its loss.
CameraState armCube() {
    postJson("/api/reset", "");
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));
    cmd("history.clear");
    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        "setup: the stand must be the untouched 8/12/6 cube, got "
        ~ format("%d/%d/%d", vertexCountLayer(0), edgeCountLayer(0), faceCountLayer(0)));
    cmd("tool.set mesh.topoPen on");
    return fetchCamera();
}

/// The name of the last entry on the undo stack, or "" when the stack is empty.
string lastUndoCommand() {
    auto u = getJson("/api/history")["undo"].array;
    return u.length ? u[$ - 1]["command"].str : "";
}

size_t undoDepth() { return getJson("/api/history")["undo"].array.length; }

/// Press Ctrl+MMB at the projected image of `target`, refusing if it is behind
/// the camera — a press aimed at a point that does not project is not a gesture
/// and must not read like one that missed its element.
void ctrlMmbOn(CameraState c, Vec3 target, string what) {
    auto vp = viewportFromCamera(c);
    float px, py;
    assert(projectToWindow(target, vp, px, py),
        what ~ " projects behind the camera — this framing cannot drive the "
        ~ "gesture at all");
    auto r = postJson("/api/play-events",
        viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
        ~ ctrlMmbAt(10.0, cast(int) px, cast(int) py) ~ "\n");
    assert("error" !in r, "/api/play-events failed: " ~ r.toString);
    waitPlayerIdle();
}

unittest { // Ctrl+MMB on an EDGE dissolves it: two quads become one hexagon
    auto c = armCube();
    immutable size_t u0 = undoDepth();

    // The midpoint of the cube's +Y/+Z top edge. An edge midpoint is the
    // furthest point on the edge from either of its endpoints, so a press there
    // cannot be a vertex latch that happened to land close.
    ctrlMmbOn(c, Vec3(0.0f, 0.5f, 0.5f), "the +Y/+Z edge midpoint");

    assert(edgeCountLayer(0) == 11,
        format("Ctrl+MMB on an edge must dissolve exactly that edge: expected "
             ~ "11 edges, got %d. 12 means nothing was latched at all — the "
             ~ "press resolved no element and this gesture had no coverage in "
             ~ "the tree to notice", edgeCountLayer(0)));
    assert(faceCountLayer(0) == 5,
        format("the dissolve must merge the edge's two quads into one face: "
             ~ "expected 5 faces, got %d", faceCountLayer(0)));
    assert(vertexCountLayer(0) == 8,
        format("an edge dissolve must lose no vertex: expected 8, got %d",
               vertexCountLayer(0)));

    // THE PRIMITIVE, BY NAME. `f == 5` alone is also what a FACE remove
    // produces, so without this the block passes over the wrong latch.
    assert(lastUndoCommand() == "mesh.topoPen_removeedge",
        "the press recorded `" ~ lastUndoCommand() ~ "`, expected "
        ~ "`mesh.topoPen_removeedge`. `removeDown` picks its primitive from the "
        ~ "class of the element under the cursor, so another name here means "
        ~ "the press latched a face or a vertex — and the face primitive leaves "
        ~ "the same face count this block just asserted");
    assert(undoDepth() - u0 == 1,
        format("the press recorded %d undo entr(ies), expected exactly 1",
               undoDepth() - u0));

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(edgeCountLayer(0) == 12 && faceCountLayer(0) == 6 && vertexCountLayer(0) == 8,
        format("undo must restore the 8/12/6 cube, got %d/%d/%d",
               vertexCountLayer(0), edgeCountLayer(0), faceCountLayer(0)));
}

unittest { // Ctrl+MMB on a VERTEX dissolves it: three quads become one
    auto c = armCube();
    immutable size_t u0 = undoDepth();

    // The +X/+Y/+Z corner — the one cube vertex where three faces visible from
    // this framing meet.
    ctrlMmbOn(c, Vec3(0.5f, 0.5f, 0.5f), "the +X/+Y/+Z corner");

    assert(vertexCountLayer(0) == 7,
        format("Ctrl+MMB on a corner must dissolve exactly that vertex: "
             ~ "expected 7 vertices, got %d. 8 means nothing was latched — and "
             ~ "no test in the tree drove this primitive before",
               vertexCountLayer(0)));
    assert(edgeCountLayer(0) == 9,
        format("the three edges meeting at the corner go with it: expected 9 "
             ~ "edges, got %d", edgeCountLayer(0)));
    assert(faceCountLayer(0) == 4,
        format("the three quads meeting at the corner merge into one: expected "
             ~ "4 faces, got %d", faceCountLayer(0)));

    // THE PRIMITIVE, BY NAME — the edge primitive would leave 8/11/5 and the
    // face one 8/12/5, so the counts above already separate them; the name says
    // so in the message instead of leaving it to be inferred.
    assert(lastUndoCommand() == "mesh.topoPen_removevertex",
        "the press recorded `" ~ lastUndoCommand() ~ "`, expected "
        ~ "`mesh.topoPen_removevertex` — another name means the press latched "
        ~ "an edge or a face rather than the corner");
    assert(undoDepth() - u0 == 1,
        format("the press recorded %d undo entr(ies), expected exactly 1",
               undoDepth() - u0));

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(vertexCountLayer(0) == 8 && edgeCountLayer(0) == 12 && faceCountLayer(0) == 6,
        format("undo must restore the 8/12/6 cube, got %d/%d/%d",
               vertexCountLayer(0), edgeCountLayer(0), faceCountLayer(0)));
}
