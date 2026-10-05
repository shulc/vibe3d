// Task 9457: an item-list click that moves the primary mesh keeps the armed
// tool and the selection type; a drop is one undo step that re-arms.
// Evidence: the private capture K-CD4 (cells named per block below).
module test_primary_move_keeps_tool;

import drag_helpers : playAndWait, buildDragLog, fetchCamera;
import http_client : getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;
import std.string : indexOf;

void main() {}

/// The params the item list's row click adds to `layer.select`
/// (`source/ui/layer_list_panel.d`, pinned there by the census below).
enum string kListArg = `,"list":true`;

private void cmd(string text) {
    const body_ = text[0] == '{' || text.indexOf(' ') >= 0 ? text : commandBody(text);
    auto r = postJson("/api/command", body_);
    assert(r["status"].str == "ok", format("command `%s` failed: %s", text, r));
    quiesce();
}

private void listClick(int index) {
    cmd(commandBody("layer.select",
        format(`{"index":%d,"mode":"set"%s}`, index, kListArg)));
}

private void key(int sym, int scan, int mod = 0) {
    playAndWait(
        `{"t":0.000,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
        format(`{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":%d,"repeat":0}`, sym, scan, mod) ~ "\n" ~
        format(`{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":%d,"repeat":0}`, sym, scan, mod) ~ "\n");
    quiesce();
}
private void keyW()  { key(119, 26); }      // arm move
private void keyQ()  { key(113, 20); }      // drop the tool
private void key1()  { key(49, 30); }       // vertices
private void undo()  { key(122, 29, 64); }  // Ctrl+Z through the navigate chokepoint

private string tool() { return getJson("/api/input/context")["tool"].toString; }
private bool armed() { return tool() != "null" && tool() != `""`; }
private string selType() { return getJson("/api/selection")["selType"].str; }
private long primary() { return getJson("/api/layers")["active"].integer; }

private long[] selectedVerts() {
    long[] r;
    foreach (v; getJson("/api/selection")["selectedVertices"].array) r ~= v.integer;
    return r;
}

private double[3][] verts(int layer) {
    double[3][] r;
    foreach (v; getJson("/api/model?layer=" ~ layer.to!string)["vertices"].array) {
        double[3] p;
        foreach (i; 0 .. 3) {
            const c = v.array[i];
            p[i] = c.type == JSONType.float_ ? c.floating : cast(double) c.integer;
        }
        r ~= p;
    }
    return r;
}

/// Indices of the vertices of `layer` that moved against `base`.
private size_t[] moved(int layer, const double[3][] base) {
    const now = verts(layer);
    assert(now.length == base.length, "the vertex count changed");
    size_t[] r;
    foreach (i; 0 .. now.length)
        if (abs(now[i][0] - base[i][0]) + abs(now[i][1] - base[i][1])
                + abs(now[i][2] - base[i][2]) > 1e-4)
            r ~= i;
    return r;
}

/// A viewport drag 100 px right, starting off the move handle.
private void drag() {
    auto c = fetchCamera();
    const x0 = c.vpX + c.width / 5, y0 = c.vpY + c.height * 4 / 5;
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height, x0, y0, x0 + 100, y0, 10));
    quiesce();
}

/// Two cube meshes: layer 0 = A (primary), layer 1 = B; vertex type current.
private void rig() {
    cmd("scene.reset");
    cmd("layer.duplicate");
    cmd(commandBody("layer.select", `{"index":0,"mode":"set"}`));
    cmd(commandBody("select.typeFrom", `{"_positional":["vertex"]}`));
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
    cmd("history.clear");
    assert(primary() == 0 && selType() == "vertex" && selectedVerts() == [0],
        "rig: A primary, vertex type, A v0 selected");
}

// CD4b: the click keeps the tool and the type; the next drag moves the whole
// new primary (its selection is empty) and leaves A alone. One visible step.
unittest {
    rig();
    keyW();
    assert(armed(), "rig: the move tool armed");
    const a0 = verts(0), b0 = verts(1);
    const depth = getJson("/api/history")["undo"].array.length;
    listClick(1);
    assert(primary() == 1, "the click moves the primary to B");
    assert(selType() == "vertex",
        "an item-list click keeps the selection type, got " ~ selType());
    assert(armed(), "an item-list click keeps the armed tool, got " ~ tool());
    assert(getJson("/api/history")["undo"].array.length == depth + 1,
        "the click is one undo step");
    drag();
    assert(moved(0, a0).length == 0, "the drag after the click must leave A alone");
    assert(moved(1, b0).length == 8,
        "the drag after the click moves all of B (its selection is empty), moved "
        ~ moved(1, b0).to!string);
}

// CD4b3: the drag acts on the new primary's own selection.
unittest {
    rig();
    cmd(commandBody("layer.select", `{"index":1,"mode":"set"}`));
    cmd(commandBody("select.typeFrom", `{"_positional":["vertex"]}`));
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[2]}`));
    cmd(commandBody("layer.select", `{"index":0,"mode":"set"}`));
    cmd(commandBody("select.typeFrom", `{"_positional":["vertex"]}`));
    assert(selectedVerts() == [0], "rig: A keeps v0");
    keyW();
    const a0 = verts(0), b0 = verts(1);
    listClick(1);
    assert(selectedVerts() == [2], "the incoming mesh keeps its own selection");
    drag();
    assert(moved(0, a0).length == 0, "A's selected vertex must not move");
    assert(moved(1, b0) == [2], "only B's own selected vertex moves, moved "
        ~ moved(1, b0).to!string);
}

// CD4back + rule 2: the click clears the outgoing mesh's selection; undoing
// the clicks restores it, with the tool still armed.
unittest {
    rig();
    keyW();
    listClick(1);
    listClick(0);
    assert(primary() == 0 && armed(), "back on A with the tool armed");
    assert(selectedVerts().length == 0,
        "the click cleared A's selection when A left the foreground, got "
        ~ selectedVerts().to!string);
    undo();
    assert(primary() == 1 && armed(), "the first Ctrl+Z undoes the click back to A");
    undo();
    assert(primary() == 0, "the second Ctrl+Z undoes the click to B");
    assert(selectedVerts() == [0], "undoing the click restores A's selection, got "
        ~ selectedVerts().to!string);
    assert(armed() && selType() == "vertex", "and keeps the tool and the type");
}

// CD4c / CD4c8: a drag is its own step below the click; undo walks the drag
// on B, the click, then the drag on A, and the tool stays armed throughout.
unittest {
    rig();
    keyW();
    const a0 = verts(0), b0 = verts(1);
    drag();
    const a1 = verts(0);
    assert(moved(0, a0) == [0], "the first drag moves A's selected vertex");
    listClick(1);
    assert(moved(0, a0) == [0], "the click keeps the committed drag on A");
    drag();
    assert(moved(1, b0).length == 8, "the second drag moves B");
    undo();
    assert(moved(1, b0).length == 0 && primary() == 1 && armed(),
        "Ctrl+Z 1 reverts the drag on B, the tool stays");
    undo();
    assert(primary() == 0 && moved(0, a1).length == 0 && armed(),
        "Ctrl+Z 2 undoes the click; A's drag stays");
    undo();
    assert(moved(0, a0).length == 0, "Ctrl+Z 3 reverts the drag on A");
}

// CD_SAME_UNDO: the current type's key drops the tool in one step; undoing it
// re-arms the tool and changes neither the type nor the selection.
unittest {
    rig();
    keyW();
    key1();
    assert(!armed(), "the current type's key drops the tool");
    undo();
    assert(armed(), "undoing the drop re-arms the tool, got " ~ tool());
    assert(selType() == "vertex" && selectedVerts() == [0],
        "and keeps the type and the selection");
}

// CD4cQ: Q drops in one step; undoing it re-arms with the move kept.
unittest {
    rig();
    keyW();
    const a0 = verts(0);
    drag();
    keyQ();
    assert(!armed(), "Q drops the tool");
    undo();
    assert(armed(), "undoing Q re-arms the tool, got " ~ tool());
    assert(moved(0, a0) == [0], "and keeps the move");
}

// CD5s / CD5b: in Items mode the current type's command drops the tool, by
// script and by the mode-bar button's command.
unittest {
    rig();
    cmd(commandBody("select.typeFrom", `{"_positional":["item"]}`));
    keyW();
    assert(armed(), "rig: a tool armed in Items mode");
    cmd(commandBody("select.typeFrom", `{"_positional":["item"]}`));
    assert(!armed(), "select.typeFrom item while Items is current drops the tool");
    keyW();
    assert(armed(), "rig: re-armed");
    cmd(`{"id":"select.item"}`);
    assert(!armed(), "the Items button's command while Items is current drops the tool");
}
