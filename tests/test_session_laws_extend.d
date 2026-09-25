// Slice M4 of the tool session model (doc/tool_session_model_plan_2026-09-24.md
// R2.5 M4, R4.7; opponent R3 C1/C2): Edge Extend on the general session model.
//
// (T) C-M4-token, "the same tool, a new session" (gap 308): Edge Extend armed by
//     its key, a haul (run 1), an exit DOOR, the key again, Ctrl+Z with no edit,
//     Ctrl+Shift+Z. Captured P-a on every driven door: Ctrl+Z #1 removes ONLY the
//     new activation (run 1 stays, 11 v; the tool is off — or, for the switch
//     twin, the switched-to Edge Extrude is back armed), and the redo re-arms
//     Edge Extend with run 1's offsets recalled. Doors driven in the capture and
//     here: switch (to Edge Extrude), `q`, Space, key `3`, the typed command line
//     `tool.set edge.extend off` (ours: the UI door). The SCRIPT exit door was
//     not driven (bridge rule) and is not asserted here.
//     The record the exit door wrote carries the FIRST session's token, the new
//     activation row a new one (R4.2: the token is on the row the close wrote).
// (M) C-H5-ext-mmb-rs: a Middle press clones EVERY haul attribute (rotate and
//     scale with the offset) into the new operation.
// (S) C-H8-sc z2 / gap 225: popping a Shift-opened operation whole restores
//     the image that operation STARTED from (offsets 0), with the tool armed.
//
// Rig: the file-6 rig of tests/test_edge_extend_shift_middle.d (edge (7,8),
// 9 v, front ortho at 0.003125 m/px); real input through /api/play-events.

import edge_extend_gesture_helpers;
import http_client : getJson, postJson;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs, sqrt;

void main() {}

enum int[2][] kRidge = [[7, 8]];
enum double PX = 0.5, PY = 1.35;
enum int SDLK_SPACE = 32, SDLK_3 = 51, SDLK_q = 113;

double dist(Offset a, Offset b) {
    return sqrt((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2);
}

JSONValue[] undoRows() { return getJson("/api/history")["undo"].array; }
/// The row's session token; 0 when the build publishes none (a pre-M4 binary).
long sessionOf(JSONValue row) {
    return "session" in row.object ? row["session"].integer : 0;
}

/// Key-armed Edge Extend, one haul: run 1. Returns its offset.
Offset runOne() {
    rigNoArm(kRidge, true, 0.3, 0.55, false);
    keyArm();
    auto tr = frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    immutable Offset o1 = offset();
    assert(tr.length == 10 && vertexCount() == 11 && o1.x > 0.05,
        format("rig: run 1 did not build a ring (%d v, o1 %s)", vertexCount(), o1));
    return o1;
}

void exitThrough(string door) {
    final switch (door) {
        case "switch": cmdUi("tool.set edge.extrude on"); break;
        case "q":      tapKey(SDLK_q); break;
        case "space":  tapKey(SDLK_SPACE); break;
        case "3":      tapKey(SDLK_3); break;
        case "cloff":  cmdUi("tool.set edge.extend off"); break;
    }
    settle(250);
    const want = door == "switch" ? "edgeExtrude" : "";
    assert(toolId() == want, format("rig (%s): the exit door left tool '%s', expected '%s'",
                                    door, toolId(), want));
}

void tokenTwin(string door) {
    immutable Offset o1 = runOne();
    immutable long act1 = sessionOf(undoRows()[$ - 1]);
    assert(undoRows()[$ - 1]["label"].str == "Activate Tool" && act1 != 0,
        format("rig (%s): the key did not write a session-bearing activation row: %s", door,
               undoRows()[$ - 1].toString));
    exitThrough(door);
    // The row the exit door wrote carries run 1's session (R4.2, R4.7).
    auto rows = undoRows();
    assert(rows[$ - 1]["label"].str == "Edge Extend" && sessionOf(rows[$ - 1]) == act1,
        format("(%s) the record the exit door wrote does not carry the first session's token %s: %s",
               door, act1, rows[$ - 1].toString));
    keyArm();
    immutable long h1 = undoLen();
    immutable long act2 = sessionOf(undoRows()[$ - 1]);
    assert(undoRows()[$ - 1]["label"].str == "Activate Tool" && act2 != 0 && act2 != act1,
        format("(%s) the re-arm wrote no activation row of a NEW session (C-M4-token): %s", door,
               undoRows()[$ - 1].toString));
    ctrlZ();
    // P-a: only the new activation is removed.
    assert(undoLen() == h1 - 1 && vertexCount() == 11,
        format("(%s) Ctrl+Z after the re-arm did not remove only the new activation (P-a, gap 308): "
             ~ "%d records over the re-arm, %d v", door, undoLen() - h1, vertexCount()));
    const want = door == "switch" ? "edgeExtrude" : "";
    assert(toolId() == want, format("(%s) Ctrl+Z after the re-arm left tool '%s', expected '%s' (P-a%s)",
        door, toolId(), want, door == "switch" ? ": the switched-to tool comes back armed" : ""));
    if (door == "switch") return;   // the switch twin's redo was not driven
    ctrlShiftZ();
    assert(toolId() == "edgeExtend" && undoLen() == h1 && vertexCount() == 11,
        format("(%s) Ctrl+Shift+Z did not re-arm Edge Extend over run 1: tool '%s', %d records, %d v",
               door, toolId(), undoLen() - h1, vertexCount()));
    assert(dist(offset(), o1) <= 1e-4,
        format("(%s) the redone arm did not recall run 1's offsets (C-M4-token-full): %s, o1 %s",
               door, offset(), o1));
}

unittest { tokenTwin("space"); }
unittest { tokenTwin("q"); }
unittest { tokenTwin("3"); }
unittest { tokenTwin("cloff"); }
unittest { tokenTwin("switch"); }

unittest { // (M) C-H5-ext-mmb-rs: the Middle press clones every haul attribute
    immutable Offset o1 = runOne();
    typePanel("tool.attr edge.extend rotateZ 20");
    typePanel("tool.attr edge.extend scaleX 1.5");
    auto st0 = toolState();
    assert(abs(num(st0["rotateZ"]) - 20) < 1e-4 && abs(num(st0["scaleX"]) - 1.5) < 1e-4,
        "rig (M): the panel writes did not land: " ~ st0.toString);
    immutable long h0 = undoLen();
    click(frontScreen(PX, PY), 2);
    auto st = toolState();
    assert(undoLen() == h0 + 1, format("rig (M): the middle press did not commit the run: %d records",
                                       undoLen() - h0));
    assert(abs(num(st["rotateZ"]) - 20) < 1e-4 && abs(num(st["scaleX"]) - 1.5) < 1e-4
        && dist(offset(), o1) <= 1e-6,
        format("(M) the middle press did not clone every haul attribute (C-H5-ext-mmb-rs clone-all): "
             ~ "rotateZ %s, scaleX %s, offset %s (o1 %s)", num(st["rotateZ"]), num(st["scaleX"]),
               offset(), o1));
}

unittest { // (S) C-H8-sc z2 / gap 225: the whole Shift-opened operation pops to its start image
    runOne();
    immutable long h0 = undoLen();
    click(frontScreen(PX, PY), 1, KMOD_LSHIFT);
    frontHaul(PX, PY, kIncrementPx, kIncrementPx, 10);
    assert(vertexCount() == 13 && undoLen() == h0 + 1,
        format("rig (S): the Shift press and haul did not open a second operation: %d v, %d records",
               vertexCount(), undoLen() - h0));
    ctrlZ();
    ctrlZ();
    immutable Offset o = offset();
    assert(vertexCount() == 11 && toolId() == "edgeExtend" && undoLen() == h0 + 1,
        format("(S) the second Ctrl+Z did not pop the Shift-opened operation whole: %d v, tool '%s'",
               vertexCount(), toolId()));
    assert(abs(o.x) <= 1e-9 && abs(o.y) <= 1e-9 && abs(o.z) <= 1e-9,
        "(S) popping the whole operation did not restore its start image (offsets 0, C-H8-sc z2): "
        ~ o.to!string);
}
