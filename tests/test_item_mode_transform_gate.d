// Task 0642 — the selection mode is the GATE on what a transform edits.
//
// ---------------------------------------------------------------------------
// Why "something moved" is not a test
// ---------------------------------------------------------------------------
// A Move drag moves *something* in both modes. An assertion that only checks
// "the item moved" passes against an implementation that also mangled the
// mesh; an assertion that only checks "the vertices moved" passes against one
// that ignores item mode entirely. So every row below reads BOTH quantities in
// BOTH modes and fills in the whole table:
//
//                        mesh.vertices        Layer.xform.pos
//   geometry mode   ->   MOVES                UNTOUCHED (exact)
//   Items mode      ->   UNTOUCHED (exact)    MOVES
//
// Only the full table separates "gated" from the two one-sided implementations
// and from "moves everything always".
//
// The second thing these rows pin is WHICH door arms the gate. Task 0614 built
// the item branch, but the only way to reach `SelType.Item` back then was to
// SELECT A LAYER — so every existing item-transform test starts with
// `layer.select`. These rows deliberately do NOT: they enter Items through
// `select.typeFrom item` alone, with the item selection untouched. That is the
// claim task 0642 adds, and a `layer.select`-based test cannot make it.
//
// "Untouched" is an EXACT compare on both sides — the `vertices` array's own
// JSON text, and an exact float compare on `xform.pos` — not an epsilon
// window. A gate that leaks a small amount into the wrong quantity is still a
// broken gate.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math   : fabs;
import std.conv   : to;
import std.format : format;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", commandBody("scene.reset")));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

bool approx(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

// The `vertices` array's own JSON text — NOT the whole /api/model response,
// which carries a fresh `timestamp` on every call.
string verticesJson(int layer = 0) {
    auto j = parseJSON(cast(string) get(BASE ~ format("/api/model?layer=%d", layer)));
    return j["vertices"].toString();
}

// The authored xform channel text, likewise compared as text so "untouched"
// means bit-identical rather than within-epsilon.
string xformPosJson(int layer = 0) {
    auto j = parseJSON(cast(string) get(BASE ~ "/api/layers"));
    return j["layers"].array[layer]["xform"]["pos"].toString();
}

double xformPosX(int layer = 0) {
    auto j = parseJSON(cast(string) get(BASE ~ "/api/layers"));
    return j["layers"].array[layer]["xform"]["pos"].array[0].floating;
}

double vertexX(int idx) {
    auto j = parseJSON(cast(string) get(BASE ~ "/api/model?layer=0"));
    return j["vertices"].array[idx].array[0].floating;
}

// One X-arrow gizmo drag of ~60 px, grabbed at the gizmo pivot. Both modes
// put the pivot at the origin here (a fresh cube is centred there, and a fresh
// layer's world item pivot is `pos + pivot` == origin), so the SAME pixels are
// dragged in both — the only difference between the two rows is the mode.
void dragXArrow() {
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    int gx, gy; double ux, uy;
    axisGrabPx(Vec3(0, 0, 0), vp, gx, gy, ux, uy);
    auto log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                            gx, gy,
                            gx + cast(int)(60.0 * ux),
                            gy + cast(int)(60.0 * uy));
    playAndWait(log);
}

// ---------------------------------------------------------------------------
// 1. GEOMETRY half of the table — a real gizmo drag in vertex mode moves the
//    MESH and leaves the item's channels bit-identical.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom vertex");

    string preVerts = verticesJson(0);
    string prePos   = xformPosJson(0);

    cmd("tool.set move on");
    dragXArrow();
    cmd("tool.set move off");

    string postVerts = verticesJson(0);
    string postPos   = xformPosJson(0);

    assert(preVerts != postVerts,
        "fixture + claim: in a GEOMETRY mode the drag must move mesh vertices. "
        ~ "If this fires the gizmo grab missed and the rest of the row proves "
        ~ "nothing — vertices are still " ~ preVerts);
    assert(prePos == postPos,
        "a geometry-mode drag must leave the ITEM's channels bit-identical — "
        ~ "xform.pos went " ~ prePos ~ " -> " ~ postPos
        ~ " (the gate leaked: a geometry drag wrote the item transform)");
}

// ---------------------------------------------------------------------------
// 2. ITEMS half of the table — the SAME drag, entered through the DOOR (no
//    layer.select anywhere), moves the item's channels and leaves the mesh
//    bit-identical.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd("select.typeFrom vertex");     // start from a geometry mode on purpose
    cmd("select.typeFrom item");       // the door — and nothing else

    auto sel = parseJSON(cast(string) get(BASE ~ "/api/selection"));
    assert(sel["selType"].str == "item",
        "fixture: the door must have made Items current without a layer.select");

    string preVerts = verticesJson(0);
    string prePos   = xformPosJson(0);

    cmd("tool.set move on");
    dragXArrow();
    cmd("tool.set move off");

    string postVerts = verticesJson(0);
    string postPos   = xformPosJson(0);

    assert(prePos != postPos,
        "in Items mode the drag must move the ITEM's channels — xform.pos "
        ~ "stayed " ~ prePos ~ ". Entering Items through the mode door (rather "
        ~ "than by selecting a layer) must arm the same gate.");
    assert(preVerts == postVerts,
        "and must leave local vertex coordinates BYTE-IDENTICAL — "
        ~ "/api/model?layer=0 changed after an Items-mode drag (the apply path "
        ~ "wrote mesh.vertices instead of, or in addition to, layer.xform.pos)");
}

// ---------------------------------------------------------------------------
// 3. The same table again with an EXACT known delta, driven headlessly through
//    the same applyTRS entry point. No pixel hit-testing, so the numbers are
//    predictions rather than "it changed": TX 2.5 lands on ONE of the two
//    quantities, and the mode picks which.
//
//    Cube vertex 0 sits at local x = -0.5 on a fresh reset; the item's pos.x
//    starts at 0. So:
//      vertex mode -> vertex0.x == -0.5 + 2.5 == 2.0, pos.x == 0
//      item mode   -> vertex0.x == -0.5 (untouched),  pos.x == 2.5
//    Those are four distinct numbers; a gate that picks the wrong side reads
//    the other pair.
// ---------------------------------------------------------------------------

unittest {
    // -- geometry side --
    resetCube();
    cmd("select.typeFrom vertex");
    immutable double baseVx = vertexX(0);
    string prePosG = xformPosJson(0);

    cmd("tool.set move on");
    cmd("tool.attr move TX 2.5");
    cmd("tool.doApply");
    cmd("tool.set move off");

    assert(approx(vertexX(0), baseVx + 2.5, 1e-3),
        format("vertex mode: TX 2.5 must move vertex 0 from %s to %s, got %s",
               baseVx, baseVx + 2.5, vertexX(0)));
    assert(xformPosJson(0) == prePosG,
        "vertex mode: the item's channels must be bit-identical, got "
        ~ xformPosJson(0) ~ " (was " ~ prePosG ~ ")");

    // -- item side, same delta, entered through the door --
    resetCube();
    cmd("select.typeFrom vertex");
    cmd("select.typeFrom item");
    string preVertsI = verticesJson(0);

    cmd("tool.set move on");
    cmd("tool.attr move TX 2.5");
    cmd("tool.doApply");
    cmd("tool.set move off");

    assert(approx(xformPosX(0), 2.5, 1e-3),
        format("item mode: TX 2.5 must land on the item's pos.x (2.5), got %s",
               xformPosX(0)));
    assert(verticesJson(0) == preVertsI,
        "item mode: mesh vertices must be bit-identical after the apply");
    assert(approx(vertexX(0), baseVx, 1e-9),
        format("item mode: vertex 0 must still read its authored local x (%s), "
               ~ "got %s — the item transform is a matrix on top of the mesh, "
               ~ "never a bake into it", baseVx, vertexX(0)));
}

// ---------------------------------------------------------------------------
// 4. Undo granularity — the gizmo gesture and the panel number-drag must land
//    at the SAME granularity: ONE entry, one undo, back to the pre-edit value.
//
//    Both halves are measured the same two ways, so the comparison is between
//    two readings rather than between a reading and a hope:
//      * the undo stack DEPTH the edit added (/api/history)
//      * what a SINGLE undo leaves in `pos.x`
//
//    The panel half deliberately drives FOUR successive writes — what dragging
//    a number field actually emits — because "one write is one entry" is true
//    of any implementation and pins nothing. Four writes that collapse to one
//    entry is the claim. Discriminating values: depth 1 and pos.x 0 when the
//    run coalesces; depth 4 and pos.x 3.0 when it does not.
// ---------------------------------------------------------------------------

unittest {
    size_t undoDepth() {
        return parseJSON(cast(string) get(BASE ~ "/api/history"))["undo"].array.length;
    }

    // -- the gizmo gesture --
    resetCube();
    cmd("select.typeFrom vertex");
    cmd("select.typeFrom item");
    immutable size_t depth0 = undoDepth();

    cmd("tool.set move on");
    dragXArrow();
    cmd("tool.set move off");

    immutable double afterDrag = xformPosX(0);
    assert(!approx(afterDrag, 0),
        "fixture: the drag must have moved pos.x, got " ~ afterDrag.to!string);
    assert(undoDepth() == depth0 + 2,
        format("one arm plus ONE gesture must surface exactly TWO undo rows: depth went %s -> %s",
               depth0, undoDepth()));

    cmd(`{"id":"history.undo"}`);
    assert(approx(xformPosX(0), 0, 1e-4),
        format("and that one undo must restore the pre-gesture value: pos.x "
               ~ "should be back at 0, got %s (the drag left it at %s). A "
               ~ "non-zero remainder means the gesture's undo entry does not "
               ~ "span the whole gesture.", xformPosX(0), afterDrag));

    // -- the panel number-drag, four writes, same granularity --
    resetCube();
    immutable size_t depthP0 = undoDepth();
    foreach (v; ["1.0", "2.0", "3.0", "4.0"])
        cmd("layer.attr 0 pos.x " ~ v);
    assert(approx(xformPosX(0), 4.0, 1e-4), "fixture: the panel writes landed");
    assert(undoDepth() == depthP0 + 1,
        format("a run of panel writes to the SAME channel must collapse into "
               ~ "ONE undo entry — the same granularity the gizmo gesture "
               ~ "lands at. depth went %s -> %s (four separate entries means "
               ~ "the two editors of the same channel disagree about what an "
               ~ "undo step is)", depthP0, undoDepth()));

    cmd(`{"id":"history.undo"}`);
    assert(approx(xformPosX(0), 0, 1e-4),
        format("one undo must unwind the whole panel run back to 0, got %s "
               ~ "(3.0 would mean it peeled off only the last write)",
               xformPosX(0)));
}
