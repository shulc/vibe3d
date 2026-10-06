// Undoing a tool drop reverts the whole live session and re-arms the tool
// fresh; the next undo removes the arming, after which the tool is latent: the
// next plain viewport drag runs a new session (task 9508). Evidence: the
// private capture findings_K-RD (rules 2 and 3); each block names its cells.
// Rig (K-RD): a 0.3 m quad at the origin, top view 440 px/m; the arm and the
// drop go through the user doors (the UI door or W / Shift+B; Q or the current
// type's key).
module test_tool_drop_undo_session;

import drag_helpers : Vec3, buildDragLog, fetchCamera, fetchHandlePart, playAndWait;
import http_client : getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import pen_rig_helpers : penCameraAt, worldPixel;
import std.format : format;
import std.functional : toDelegate;
import std.json : JSONType, JSONValue;
import std.math : abs, round;
import std.string : indexOf;

void main() {}

private void cmd(string line) {
    auto r = postJson("/api/command", line[0] == '{' || line.indexOf(' ') >= 0 ? line : commandBody(line));
    assert(r["status"].str == "ok", format("`%s` failed: %s", line, r));
    quiesce();
}
private void ui(string line) {
    auto r = postJson("/api/command?origin=ui", line);
    assert(r["status"].str == "ok", format("ui `%s` failed: %s", line, r));
    quiesce();
}
private void key(int sym, int scan, int mod = 0) {
    playAndWait(format(`{"t":0,"type":"PACE","mode":"frames"}` ~ "\n" ~
        `{"t":30,"type":"SDL_KEYDOWN","sym":%s,"scan":%s,"mod":%s,"repeat":0}` ~ "\n" ~
        `{"t":60,"type":"SDL_KEYUP","sym":%s,"scan":%s,"mod":%s,"repeat":0}` ~ "\n",
        sym, scan, mod, sym, scan, mod));
    quiesce();
}
private void undo() { key(122, 29, 64); }
private void keyQ() { key(113, 20); }
private string tool() {
    auto t = getJson("/api/input/context")["tool"];
    return t.type == JSONType.string ? t.str : "";
}
private bool gizmoDrawn() {
    auto h = getJson("/api/tool/handles")["handles"];
    if (h.type != JSONType.object) return false;
    foreach (p; h["parts"].array) if (p["screen"].type != JSONType.null_) return true;
    return false;
}
private size_t depth() { return getJson("/api/history")["undo"].array.length; }
private string topLabel() {
    auto u = getJson("/api/history")["undo"].array;
    return u.length ? u[$ - 1]["label"].str : "";
}
private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer : v.floating;
}
private double[3][] verts() {
    double[3][] r;
    foreach (v; getJson("/api/model")["vertices"].array)
        r ~= [num(v.array[0]), num(v.array[1]), num(v.array[2])];
    return r;
}
private double[3] itemPos() {
    auto p = getJson("/api/layers")["layers"].array[0]["xform"]["pos"].array;
    return [num(p[0]), num(p[1]), num(p[2])];
}
/// Largest coordinate gap over the first four vertices (the quad).
private double quadGap(const double[3][] a, const double[3][] b) {
    assert(a.length >= 4 && b.length >= 4, format("population: the quad has %s versus %s vertices", a.length, b.length));
    double m = 0;
    foreach (i; 0 .. 4) foreach (k; 0 .. 3) m = abs(a[i][k] - b[i][k]) > m ? abs(a[i][k] - b[i][k]) : m;
    return m;
}
private void dragPx(int[2] a, int dx, int dy) {
    auto c = fetchCamera();
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height, a[0], a[1], a[0] + dx, a[1] + dy, 10));
    quiesce();
}
private int[2] part(int id) {
    double x, y; bool found;
    fetchHandlePart(id, x, y, found);
    assert(found, format("handle part %s missing: %s", id, getJson("/api/tool/handles")));
    return [cast(int) round(x), cast(int) round(y)];
}

enum double[3][] kQuad = [[0, 0, 0], [0.3, 0, 0], [0.3, 0, 0.3], [0, 0, 0.3]];

private void rig(string type) {
    cmd("scene.reset");
    cmd(commandBody("scene.loadMesh",
        `{"vertices":[[0,0,0],[0.3,0,0],[0.3,0,0.3],[0,0,0.3]],"faces":[[0,3,2,1]]}`));
    cmd("viewport.view Top");
    penCameraAt(Vec3(0.15f, 0, 0.15f), 440);
    cmd("select.typeFrom " ~ type);
    if (type == "vertex") cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3]}`));
    if (type == "polygon") cmd(commandBody("mesh.select", `{"mode":"polygons","indices":[0]}`));
    cmd("history.clear");
}

private bool quadAtStart() { return quadGap(verts(), kQuad) <= 1e-6; }

/// One CD cell: arm by key, `edit`, `drop`, Ctrl+Z ×2. The drop pushes ONE
/// row; Ctrl+Z 1 pops it with the whole session and re-arms the tool fresh;
/// Ctrl+Z 2 removes the arming.
private void cdCell(string cell, string type, string toolId, void delegate() arm,
                    void delegate() edit, void delegate() drop,
                    bool delegate() reverted, bool liveWindow = false) {
    rig(type);
    arm();
    assert(tool() == toolId, format("%s rig: %s not armed, got '%s'", cell, toolId, tool()));
    const armed = depth();
    edit();
    // A transform drag is its own row at mouse-up; Bevel's live window
    // commits ONE row at the drop (C-H3-bev), under the drop row.
    assert(!reverted() && depth() == armed + (liveWindow ? 0 : 1),
        format("%s floor: the edit moved nothing or recorded no row (depth %s)", cell, depth()));
    const edited = depth() + (liveWindow ? 1 : 0);
    drop();
    assert(tool() == "" && depth() == edited + 1 && topLabel() == "Tool Drop",
        format("%s: the drop pushes ONE drop row (depth %s -> %s, top '%s', tool '%s')",
            cell, edited, depth(), topLabel(), tool()));
    undo();
    // Bevel's handle after Ctrl+Z 1 is NOT pinned: the reference draws none
    // (CD_Q_BV_z1), ours re-arms it drawn — gap row, task 9508.
    assert(reverted() && tool() == toolId && depth() == armed && (liveWindow || gizmoDrawn()),
        format("%s Ctrl+Z 1: the drop and the whole session pop, the tool is live again " ~
            "(reverted %s, tool '%s', depth %s want %s, gizmo %s)",
            cell, reverted(), tool(), depth(), armed, gizmoDrawn()));
    undo();
    assert(reverted() && tool() == "" && depth() == armed - 1 && !gizmoDrawn(),
        format("%s Ctrl+Z 2: the arming row pops (tool '%s', depth %s want %s)",
            cell, tool(), depth(), armed - 1));
}

unittest { // CD_Q_TM (Move, centre drag, Q); CD_Q_ROT / CD_S_ROT; CD_Q_SCL / CD_S_SCL
    // The K-RD presets arm through the UI door; Move also through its key (W).
    cdCell("CD_Q_TM", "vertex", "TransformMove", delegate() => ui("tool.set TransformMove on"),
        delegate() => dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0), delegate() => keyQ(), toDelegate(&quadAtStart));
    cdCell("CD_Q_TM (W)", "vertex", "move", delegate() => key(119, 26),
        delegate() => dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0), delegate() => keyQ(), toDelegate(&quadAtStart));
    foreach (sameType; [false, true]) {
        void dropKey() { if (sameType) key(49, 30); else keyQ(); }
        cdCell(sameType ? "CD_S_ROT" : "CD_Q_ROT", "vertex", "TransformRotate",
            delegate() => ui("tool.set TransformRotate on"),
            delegate() { auto p = part(11); dragPx([p[0] + 2, p[1] - 117], 30, 0); }, &dropKey, toDelegate(&quadAtStart));
        cdCell(sameType ? "CD_S_SCL" : "CD_Q_SCL", "vertex", "TransformScale",
            delegate() => ui("tool.set TransformScale on"),
            delegate() => dragPx(part(20), 40, 0), &dropKey, toDelegate(&quadAtStart));
    }
}

unittest { // CD_Q_ITEMA / CD_S_ITEMA: Items mode, the item X arrow +40 px
    bool atOrigin() { auto p = itemPos(); return abs(p[0]) + abs(p[1]) + abs(p[2]) <= 1e-6; }
    foreach (sameType; [false, true]) {
        void dropKey() { if (sameType) key(53, 34); else keyQ(); }
        cdCell(sameType ? "CD_S_ITEMA" : "CD_Q_ITEMA", "item", "move", delegate() => key(119, 26),
            delegate() => dragPx(part(0), 40, 0), &dropKey, &atOrigin);
    }
}

unittest { // CD_Q_BV / CD_S_BV: Polygon mode, the quad selected, an off-handle haul +40 px X
    // Reverted: the quad's own four vertices at the start and no inset ring
    // (the bare re-arm applies nothing; CD_Q_BV_z1's eight vertices come from
    // the reference's script read, which re-applies the tool).
    bool noRing() {
        return verts().length == 4 && quadAtStart();
    }
    foreach (sameType; [false, true]) {
        void dropKey() { if (sameType) key(51, 32); else keyQ(); }
        cdCell(sameType ? "CD_S_BV" : "CD_Q_BV", "polygon", "poly.bevel", delegate() => key(98, 5, 1),
            delegate() => dragPx(worldPixel(Vec3(0.05f, 0, 0.25f)), 40, 0), &dropKey, &noRing, true);
    }
}

unittest { // Ours: redo after the drop's undo replays the session; the drop row never returns
    rig("vertex");
    ui("tool.set TransformMove on");
    const armed = depth();
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    const edited = verts();
    keyQ();
    undo();
    assert(quadAtStart() && tool() == "TransformMove", "redo rig: the drop's undo reverted the session");
    key(122, 29, 65);
    const redoLen = getJson("/api/history")["redo"].array.length;
    assert(quadGap(verts(), edited) <= 1e-6 && tool() == "TransformMove" && depth() == armed + 1
            && redoLen == 0,
        format("redo: the drag comes back, the tool stays armed, nothing left to redo (depth %s, redo %s)",
            depth(), redoLen));
    key(122, 29, 65);
    assert(quadGap(verts(), edited) <= 1e-6 && depth() == armed + 1 && tool() == "TransformMove",
        "a second redo changes nothing (the drop row is not on the redo stack)");
    // The History panel's jump to a row between the drop row and the session's
    // rows: the drop's undo takes the session, the walk redoes it back.
    keyQ();
    auto r = postJson("/api/history/jump", format(`{"target":%s}`, armed + 1));
    quiesce();
    assert(r["status"].str == "ok" && depth() == armed + 1 && quadGap(verts(), edited) <= 1e-6
            && tool() == "TransformMove",
        format("jump below the drop row: the edit stands, the tool is re-armed (%s, depth %s, tool '%s')",
            r, depth(), tool()));
}

unittest { // CD_Q2_TM / CD_Q2_TM_z2: two drags, Q; Ctrl+Z 1 takes BOTH back
    rig("vertex");
    key(119, 26);
    const armed = depth();
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    dragPx(worldPixel(Vec3(0.24f, 0, 0.15f)), 0, 40);
    const double[3][] both = [[0.09, 0, 0.09], [0.39, 0, 0.09], [0.39, 0, 0.39], [0.09, 0, 0.39]];
    assert(quadGap(verts(), both) <= 1.5 / 440.0 && depth() == armed + 2,
        format("CD_Q2_TM floor: two drags, two rows (%s, depth %s)", verts(), depth()));
    keyQ();
    undo();
    assert(quadAtStart() && tool() == "move" && gizmoDrawn() && depth() == armed,
        format("CD_Q2_TM Ctrl+Z 1: both drags gone, tool live (%s, tool '%s')", verts(), tool()));
    undo();
    assert(quadAtStart() && tool() == "" && depth() == armed - 1,
        format("CD_Q2_TM_z2 Ctrl+Z 2: the arming pops (tool '%s')", tool()));
}

unittest { // RD_DROP_Z0D: after the undo that removes the arming the tool is latent
    rig("vertex");
    key(119, 26);
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    dragPx(worldPixel(Vec3(0.24f, 0, 0.15f)), 0, 40);
    undo();
    undo();
    undo();
    assert(quadAtStart() && tool() == "" && !gizmoDrawn() && depth() == 0,
        format("RD_DROP_Z0D Ctrl+Z ×3: both drags and the arming gone (tool '%s', depth %s)",
            tool(), depth()));
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    const double[3][] moved = [[0.09, 0, 0], [0.39, 0, 0], [0.39, 0, 0.3], [0.09, 0, 0.3]];
    assert(quadGap(verts(), moved) <= 1.5 / 440.0 && tool() == "move" && gizmoDrawn(),
        format("RD_DROP_Z0D: the drag runs a new move session (%s, tool '%s', gizmo %s)",
            verts(), tool(), gizmoDrawn()));
}

/// The latent state of RD_DROP_Z0D: W, one drag, Ctrl+Z ×2.
private void latentRig() {
    rig("vertex");
    key(119, 26);
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    undo();
    undo();
    assert(quadAtStart() && tool() == "" && depth() == 0, "latent rig: drag and arming undone");
}

unittest { // Ours, uncaptured (gap row): what forgets the latent tool, and which press arms it
    latentRig();
    rig("vertex");   // a reset (a drop door with no tool) forgets it
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    assert(quadAtStart() && tool() == "", "a reset forgets the latent tool");
    latentRig();
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3]}`));   // a new row
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    assert(quadAtStart() && tool() == "", "a recorded command forgets the latent tool");
    latentRig();
    cmd("history.clear");   // a cleared history has moved too
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    assert(quadAtStart() && tool() == "", "a history clear forgets the latent tool");
    // A foreign row below the arming, undone and redone: the history moved.
    rig("vertex");
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3]}`));
    key(119, 26);
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    undo();
    undo();
    undo();
    key(122, 29, 65);
    assert(depth() == 1 && tool() == "", "foreign-row rig: the select row is back, no tool");
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    assert(quadAtStart() && tool() == "", "an undo and redo of a foreign row forget the latent tool");
    latentRig();
    auto c = fetchCamera();
    const p = worldPixel(Vec3(0.15f, 0, 0.15f));
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height, p[0], p[1], p[0] + 40, p[1], 10, 0, 3));
    quiesce();
    assert(quadAtStart() && tool() == "", "a right press does not arm the latent tool");
    latentRig();
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height, p[0], p[1], p[0] + 40, p[1], 10, 0, 2));
    quiesce();
    assert(quadAtStart() && tool() == "", "a middle press does not arm the latent tool");
    latentRig();
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height, p[0], p[1], p[0] + 40, p[1], 10, 1));
    quiesce();
    assert(quadAtStart() && tool() == "", "a Shift press does not arm the latent tool");
    dragPx(p, 40, 0);
    assert(!quadAtStart() && tool() == "move", "the plain press after it still does");
}

unittest { // Only the undo of the tool's OWN activation row makes it latent
    // An undo with no transform tool bound: the last armed tool was dropped by
    // Space (no row), then a selection row is undone.
    rig("vertex");
    key(119, 26);
    key(32, 44);
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
    undo();
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    assert(quadAtStart() && tool() == "", "an undo with no tool bound leaves no latent tool");
    // An in-session cancel that drops the tool while its activation row stands.
    rig("vertex");
    ui("tool.set TransformMove on");
    cmd("tool.beginSession");
    cmd("tool.attr TransformMove TX 0.1");
    assert(!quadAtStart() && depth() == 1, "cancel floor: a live panel edit over the activation row");
    undo();
    assert(quadAtStart() && tool() == "" && depth() == 1,
        "the cancel undoes the edit and drops the tool; its activation row stands");
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    assert(quadAtStart() && tool() == "", "a cancel that leaves the activation row leaves no latent tool");
    // Another tool's activation row: bare Rotate (E) arms with no row of its
    // own; the undo of Move's older row ends it, and it is not latent.
    rig("vertex");
    key(119, 26);
    key(32, 44);
    key(101, 8);
    assert(tool() == "rotate" && depth() == 1, "rig: bare Rotate armed over Move's activation row");
    undo();
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    assert(quadAtStart() && tool() == "", "the undo of another tool's activation row leaves no latent tool");
}

unittest { // Ours, uncaptured (gap row): Space and a type FLIP (geometry or Items) still write no drop row
    foreach (door; ["space", "flip", "items"]) {
        rig("vertex");
        key(119, 26);
        dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
        const rows = depth();
        if (door == "space") key(32, 44); else if (door == "flip") key(50, 31); else key(53, 34);
        assert(tool() == "" && depth() == rows && topLabel() != "Tool Drop",
            format("%s: no drop row (depth %s -> %s, top '%s')", door, rows, depth(), topLabel()));
    }
}

unittest { // CD_Q_TM_R, ours: a GET read is no command (cdCell reads between the
    // edit and the drop and Ctrl+Z 1 still reverts); a SCRIPT command that
    // records its own row ends the run the drop's undo takes, so — as the
    // reference's script read does — Ctrl+Z 1 pops only the drop row,
    // re-arms the tool and keeps the edit.
    rig("vertex");
    key(119, 26);
    dragPx(worldPixel(Vec3(0.15f, 0, 0.15f)), 40, 0);
    const edited = verts();
    assert(quadGap(edited, kQuad) > 0.05, "CD_Q_TM_R floor: the drag moved the quad");
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3]}`));
    const rows = depth();
    keyQ();
    assert(depth() == rows + 1 && topLabel() == "Tool Drop", "CD_Q_TM_R: the drop pushes ONE row");
    undo();
    assert(depth() == rows && tool() == "move" && quadGap(verts(), edited) <= 1e-6,
        format("CD_Q_TM_R Ctrl+Z 1: only the drop pops, the edit is kept (depth %s want %s, tool '%s')",
            depth(), rows, tool()));
}

unittest { // Design cell (uncaptured, gap row): a primary move between the
    // edit and Q. The click re-arms the tool on the new primary with a new
    // session that wrote no row, so Q writes NO drop row; Ctrl+Z 1 undoes the
    // click (the tool stays dropped), Ctrl+Z 2 the drag on A.
    cmd("scene.reset");
    cmd("layer.duplicate");
    cmd(commandBody("layer.select", `{"index":0,"mode":"set"}`));
    cmd("select.typeFrom vertex");
    cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
    cmd("history.clear");
    key(119, 26);
    auto c = fetchCamera();
    const x0 = c.vpX + c.width / 5, y0 = c.vpY + c.height * 4 / 5;
    playAndWait(buildDragLog(c.vpX, c.vpY, c.width, c.height, x0, y0, x0 + 100, y0, 10));
    quiesce();
    auto aV0 = () => getJson("/api/model?layer=0")["vertices"].array[0].toString;
    const dragged = aV0();
    assert(depth() == 2 && dragged != `[-0.5,-0.5,-0.5]`, "design cell floor: the drag moved A's v0");
    // The item list's click: `list` marks it while that argument exists.
    auto r = postJson("/api/command", commandBody("layer.select", `{"index":1,"mode":"set","list":true}`));
    if (r["status"].str != "ok") cmd(commandBody("layer.select", `{"index":1,"mode":"set"}`));
    quiesce();
    assert(tool() == "move" && depth() == 3, "design cell: the click keeps the tool, one row");
    keyQ();
    assert(tool() == "" && depth() == 3, "design cell: Q writes no drop row after the primary move");
    undo();
    assert(getJson("/api/layers")["active"].integer == 0 && tool() == "" && aV0() == dragged,
        "design cell Ctrl+Z 1: the click is undone, A keeps its drag, no tool");
    undo();
    assert(aV0() == `[-0.5,-0.5,-0.5]`, "design cell Ctrl+Z 2: A's drag is undone");
}

unittest { // Two remaining presses: extent is shared, retention is preset data.
    foreach (id; ["mesh.topoPen", "mesh.dragWeld"])
    foreach (door; ["navigation", "panel", "command"]) {
        rig("vertex");
        ui("tool.set " ~ id ~ " on");
        cmd("tool.pipe.attr snap enabled false");
        if (id == "mesh.topoPen") cmd("tool.attr " ~ id ~ " mode 0");
        auto p = worldPixel(Vec3(0, 0, 0));
        dragPx(p, 44, 0);
        const first = verts();
        assert(quadGap(first, kQuad) > 0.05, "two-press floor: first press moved geometry");
        p = worldPixel(Vec3(cast(float)first[0][0], cast(float)first[0][1], cast(float)first[0][2]));
        dragPx(p, 0, 44);
        const last = verts();
        assert(quadGap(last, first) > 0.05 && depth() < 40, "two-press floor: second press and history headroom");
        const tokenBefore = getJson("/api/tool/state")["session"]["token"].integer;
        keyQ();
        const dropped = depth();
        if (door == "navigation") undo();
        else if (door == "panel") { auto r = postJson("/api/history/jump", format(`{"target":%s}`, depth() - 2)); assert(r["status"].str == "ok"); quiesce(); }
        else cmd("history.undo");
        assert(tool() == id && quadGap(verts(), first) <= 1e-6 && depth() == dropped - 2,
            format("%s %s drop must revert only the newest press: %s", id, door, getJson("/api/history")));
        const token = getJson("/api/tool/state")["session"]["token"].integer;
        assert(tokenBefore > 0 && token == tokenBefore, "drop completion must adopt the original session token");
        if (id == "mesh.dragWeld") {
            key(122, 29, 65);
            assert(tool() == id && quadGap(verts(), last) <= 1e-6,
                "preset redo1 restores its newest press while armed");
            key(122, 29, 65);
            assert(tool() == "" && quadGap(verts(), last) <= 1e-6,
                "preset redo2 replays lifecycle drop without changing geometry");
        } else {
            assert(getJson("/api/history")["redo"].array.length == 0, "plain drop discards complete redo population");
            key(122, 29, 65);
            assert(tool() == id && quadGap(verts(), first) <= 1e-6,
                "plain drop redo cannot restore the discarded press");
        }
    }
}

unittest { // A restored tool uses the final mesh as its next press basis at every door.
    foreach (id; ["mesh.topoPen", "mesh.dragWeld"])
    foreach (door; ["navigation", "panel", "command"]) {
        rig("vertex");
        ui("tool.set " ~ id ~ " on");
        cmd("tool.pipe.attr snap enabled false");
        if (id == "mesh.topoPen") cmd("tool.attr " ~ id ~ " mode 0");
        dragPx(worldPixel(Vec3(0, 0, 0)), 44, 0);
        const first = verts();
        auto atFirst = Vec3(cast(float)first[0][0], cast(float)first[0][1], cast(float)first[0][2]);
        dragPx(worldPixel(atFirst), 0, 44);
        assert(quadGap(verts(), first) > 0.05, "next-press floor: second gesture moved geometry");
        keyQ();
        if (door == "navigation") undo();
        else if (door == "panel") { auto r = postJson("/api/history/jump", format(`{"target":%s}`, depth() - 2)); assert(r["status"].str == "ok"); quiesce(); }
        else cmd("history.undo");
        assert(quadGap(verts(), first) <= 1e-6 && tool() == id, "next-press floor: newest press reverted");
        dragPx(worldPixel(atFirst), -44, 0);
        const continued = verts();
        assert(quadGap(continued, first) > 0.05, "next press must apply from restored geometry");
        // A fresh arm on that same final mesh is an independent basis oracle.
        rig("vertex");
        auto scene = JSONValue.emptyObject;
        JSONValue[] points;
        foreach (point; first) points ~= JSONValue([JSONValue(point[0]), JSONValue(point[1]), JSONValue(point[2])]);
        scene["vertices"] = JSONValue(points);
        scene["faces"] = JSONValue([JSONValue([JSONValue(0), JSONValue(3), JSONValue(2), JSONValue(1)])]);
        cmd(commandBody("scene.loadMesh", scene.toString));
        cmd("viewport.view Top");
        penCameraAt(Vec3(0.15f, 0, 0.15f), 440);
        cmd(commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3]}`));
        ui("tool.set " ~ id ~ " on");
        cmd("tool.pipe.attr snap enabled false");
        if (id == "mesh.topoPen") cmd("tool.attr " ~ id ~ " mode 0");
        dragPx(worldPixel(atFirst), -44, 0);
        assert(quadGap(continued, verts()) <= 1e-6,
            format("%s %s restored next press must match a fresh arm's basis: %s versus %s", id, door, continued, verts()));
    }
}
