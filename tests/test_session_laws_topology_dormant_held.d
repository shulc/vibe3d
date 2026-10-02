// Law 5 (topology-redo S6, model doc §3 E3): a dormant haul builds no preview. One cell
// per tool of the captured model (`<tool>-dormant/held`): the closed run W, Z, Z, R, R of a
// captured `*_dormant` cell (PolyExtrude / EdgeExtrude: synthesized on a cell of their rig —
// arm, first haul, W, Z, Z, R, R — no dormant capture of theirs exists), a UI re-arm, then
// the button pressed and moved but not released: the mesh must be the re-arm's image. This
// is OUR cell (no reference frame mid-haul); each tool's preview gate
// (`if (previewGated()) return;`) has exactly one cell here (SmoothShift two: smooth, thicken).
//
// Rig preconditions (a run that fails one is VOID): the re-arm is dormant, and the image has
// at least one vertex and one selected element. Order: the floor, then one `unittest` per cell.

import std.algorithm : canFind;
import std.conv : to;
import std.format : format;
import std.json;
import http_client : getJson, postJson;
import topology_redo_law_helpers;

void main() {}

enum string kFixture = import("fixtures/topology_redo_law_cells.json");

/// cell name -> the fixture cell that lends its rig and its ladder (`*_dormant`: its steps
/// before the dormant re-arm; the two extrudes: synthesized from its first arm and haul).
immutable string[2][] kCells = [
    ["inset-dormant/held", "inset_dormant"], ["smooth-dormant/held", "smooth_dormant"],
    ["thicken-dormant/held", "thicken_dormant"], ["vmerge-dormant/held", "vmerge_dormant"],
    ["radial-dormant/held", "radial_dormant"], ["array-dormant/held", "array_dormant"],
    ["clone-dormant/held", "clone_dormant"], ["mirror-dormant/held", "mirror_dormant"],
    ["ebevel-dormant/held", "ebevel_dormant"], ["vbevel-dormant/held", "vbevel_dormant"],
    ["vextrude-dormant/held", "vextrude_dormant"], ["pextrude-dormant/held", "pextrude_direct"],
    ["eextrude-dormant/held", "eextrude_mech"],
];

unittest { // the floor: 13 cells, one per id of the captured model, each lender in the fixture
    const fx = parseJSON(kFixture);
    size_t found;
    foreach (row; kCells)
        foreach (c; fx["cells"].array) if (c["id"].str == row[1]) ++found;
    assert(kCells.length == 13 && found == 13, format("held cells: %d rows, %d lenders found, "
        ~ "frozen at 13 / 13", kCells.length, found));
}

private bool skipFor(string name) {
    import std.process : environment;
    const only = environment.get("VIBE3D_CELL", "");
    return only.length && only != name;
}

private JSONValue cellOf(string id) {
    foreach (c; parseJSON(kFixture)["cells"].array) if (c["id"].str == id) return c;
    assert(false, "fixture holds no cell " ~ id);
}

private string meshImage() {
    auto m = getJson("/api/model");
    return m["vertices"].toString ~ "|" ~ m["faces"].toString;
}

/// The ladder before the dormant re-arm, and the haul the held press repeats.
private void ladder(const JSONValue cell, out JSONValue[] steps, out JSONValue haul) {
    const all = cell["steps"].array;
    if (canFind(cell["id"].str, "_dormant")) {
        size_t last;
        foreach (k, s; all) if (s["op"].str == "arm") last = k;
        steps = all[0 .. last].dup;
        foreach (s; all[last .. $]) if (s["op"].str == "haul") { haul = s; break; }
        return;
    }
    JSONValue arm, first;
    foreach (s; all) {
        if (arm.type != JSONType.object && s["op"].str == "arm") arm = s;
        if (first.type != JSONType.object && s["op"].str == "haul") first = s;
    }
    steps = [arm, first];
    foreach (k; ["W", "Z", "Z", "R", "R"])
        steps ~= parseJSON(format(`{"op":"key","key":"%s","label":"x_%s"}`, k, k));
    haul = first;
}

private void heldCell(string name, string lender) {
    if (skipFor(name)) return;
    const cell = cellOf(lender);
    const rig = rigOf(cell["variant"].str);
    setupCell(cell, rig);
    JSONValue[] steps;
    JSONValue haul;
    ladder(cell, steps, haul);
    foreach (s; steps) runStep(s, rig, name ~ "/" ~ s["label"].str);
    runStep(parseJSON(`{"op":"arm","door":"ui","label":"rearm"}`), rig, name ~ "/rearm");
    auto st = getJson("/api/tool/state");
    assert(st["session"]["dormant"].type == JSONType.true_,
        "rig VOID " ~ name ~ ": the re-arm after the closed redo is not dormant: " ~ st["session"].toString);
    const armImage = meshImage();
    const sel = getJson("/api/selection");
    const nSel = sel["selectedVertices"].array.length + sel["selectedEdges"].array.length
        + sel["selectedFaces"].array.length;
    assert(getJson("/api/model")["vertices"].array.length >= 1 && nSel >= 1,
        "rig VOID " ~ name ~ ": the arm image holds no vertex or no selection");
    holdHaul(haul, rig, name);
    const held = meshImage();
    releaseHeld();
    assert(held == armImage, "law 5: " ~ name ~ ": the dormant haul built a preview mid-haul "
        ~ "(the mesh moved from the arm's image while the button was held)");
    auto r = postJson("/api/command", "tool.set " ~ rig.tool ~ " off");
    assert(r["status"].str == "ok", name ~ ": tool off: " ~ r.toString);
}

unittest { heldCell(kCells[0][0], kCells[0][1]); }
unittest { heldCell(kCells[1][0], kCells[1][1]); }
unittest { heldCell(kCells[2][0], kCells[2][1]); }
unittest { heldCell(kCells[3][0], kCells[3][1]); }
unittest { heldCell(kCells[4][0], kCells[4][1]); }
unittest { heldCell(kCells[5][0], kCells[5][1]); }
unittest { heldCell(kCells[6][0], kCells[6][1]); }
unittest { heldCell(kCells[7][0], kCells[7][1]); }
unittest { heldCell(kCells[8][0], kCells[8][1]); }
unittest { heldCell(kCells[9][0], kCells[9][1]); }
unittest { heldCell(kCells[10][0], kCells[10][1]); }
unittest { heldCell(kCells[11][0], kCells[11][1]); }
unittest { heldCell(kCells[12][0], kCells[12][1]); }
