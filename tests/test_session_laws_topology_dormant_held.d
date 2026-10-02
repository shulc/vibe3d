// Law 5 (topology-redo S6, model doc §3 E3): a dormant haul builds no preview. One cell
// per tool of the captured model (`<tool>-dormant/held`; 12 of the 13, see below): the
// closed run W, Z, Z, R, R of a captured `*_dormant` cell (PolyExtrude / EdgeExtrude /
// VertexMerge: synthesized on a cell of their rig — arm, first haul, W, Z, Z, R, R; the
// extrudes have no dormant capture, and VertexMerge's captured haul merges our whole
// selection), a UI re-arm, then the button pressed and moved but not released: the mesh
// must be the re-arm's image. This is OUR cell (no reference frame mid-haul); each tool's
// preview gate (`if (previewGated()) return;`) has one cell here (SmoothShift two).
//
// Rig preconditions (a run that fails one is VOID): the re-arm is dormant, and the image has
// at least one vertex and one selected element; VertexMerge's closed run left its selection
// partly merged (its synthesized first haul is a short one, so the held haul has vertices
// left to merge). No cell for RadialArray: our RadialArray haul after the closed run writes
// no attribute, so a held haul cannot move the mesh whatever the gate — measured by striking
// the gate (S6 drill); its gate's red is the source census. Order: the floor, the
// script-door pair, one `unittest` per held cell.

import std.algorithm : canFind;
import std.conv : to;
import std.format : format;
import std.json;
import http_client : getJson, postJson;
import topology_redo_law_helpers;

void main() {}

enum string kFixture = import("fixtures/topology_redo_law_cells.json");

/// cell name -> the fixture cell that lends its rig and its ladder (`*_dormant`: its steps
/// before the dormant re-arm; the others: synthesized from its first arm and haul) -> the
/// synthesized first haul's delta in pixels ("" = the lender's own).
immutable string[3][] kCells = [
    ["inset-dormant/held", "inset_dormant", ""], ["smooth-dormant/held", "smooth_dormant", ""],
    ["thicken-dormant/held", "thicken_dormant", ""], ["array-dormant/held", "array_dormant", ""],
    ["clone-dormant/held", "clone_dormant", ""], ["mirror-dormant/held", "mirror_dormant", ""],
    ["ebevel-dormant/held", "ebevel_dormant", ""], ["vbevel-dormant/held", "vbevel_dormant", ""],
    ["vextrude-dormant/held", "vextrude_dormant", ""],
    ["pextrude-dormant/held", "pextrude_direct", ""], ["eextrude-dormant/held", "eextrude_mech", ""],
    // the three rig vertices are 0.002 and 0.0036 apart: a 4 px first haul merges the
    // near pair only, the held 14 px haul would merge the third (measured, S6 fix)
    ["vmerge-dormant/held", "vmerge_discrim", "[4,0]"],
];

unittest { // the floor: 12 cells (the 13 ids less RadialArray), each lender in the fixture
    const fx = parseJSON(kFixture);
    size_t found;
    foreach (row; kCells)
        foreach (c; fx["cells"].array) if (c["id"].str == row[1]) ++found;
    assert(kCells.length == 12 && found == 12, format("held cells: %d rows, %d lenders found, "
        ~ "frozen at 12 / 12", kCells.length, found));
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
private void ladder(const JSONValue cell, out JSONValue[] steps, out JSONValue haul,
                    string firstDelta = "") {
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
    haul = first;
    if (firstDelta.length) {
        first = parseJSON(first.toString);
        first["delta"] = parseJSON(firstDelta);
    }
    steps = [arm, first];
    foreach (k; ["W", "Z", "Z", "R", "R"])
        steps ~= parseJSON(format(`{"op":"key","key":"%s","label":"x_%s"}`, k, k));
}

private void heldCell(string name, string lender, string firstDelta) {
    if (skipFor(name)) return;
    const cell = cellOf(lender);
    const rig = rigOf(cell["variant"].str);
    setupCell(cell, rig);
    const v0 = getJson("/api/model")["vertices"].array.length;
    JSONValue[] steps;
    JSONValue haul;
    ladder(cell, steps, haul, firstDelta);
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
    if (rig.tool == "vert.merge") {
        const v = getJson("/api/model")["vertices"].array.length;
        assert(v == v0 - 1, format("rig VOID %s: the closed run did not leave the selection "
            ~ "partly merged (%d -> %d vertices, one merge expected)", name, v0, v));
    }
    holdHaul(haul, rig, name);
    const held = meshImage();
    releaseHeld();
    assert(held == armImage, "law 5: " ~ name ~ ": the dormant haul built a preview mid-haul "
        ~ "(the mesh moved from the arm's image while the button was held)");
    auto r = postJson("/api/command", "tool.set " ~ rig.tool ~ " off");
    assert(r["status"].str == "ok", name ~ ": tool off: " ~ r.toString);
}

// The door law on the SCRIPT door (model doc §1.1; ours — no captured cell undoes a
// script-door dormant activation): the attribute-only row of a dormant haul and its
// activation are two steps each way. Z1 takes the row (the tool stays), Z2 the
// activation, R1 brings the activation back ALONE (the row stays in redo).
unittest {
    enum name = "inset-dormant/script-door";
    if (skipFor(name)) return;
    const cell = cellOf("inset_dormant");
    const rig = rigOf(cell["variant"].str);
    setupCell(cell, rig);
    JSONValue[] steps;
    JSONValue haul;
    ladder(cell, steps, haul);
    foreach (s; steps) runStep(s, rig, name ~ "/" ~ s["label"].str);
    runStep(parseJSON(`{"op":"arm","door":"script","label":"rearm"}`), rig, name ~ "/rearm");
    assert(getJson("/api/tool/state")["session"]["dormant"].type == JSONType.true_,
        "rig VOID " ~ name ~ ": the script re-arm is not dormant");
    runStep(haul, rig, name ~ "/haul");
    auto top() { return getJson("/api/history")["undo"].array[$ - 1]["command"].str; }
    long redoLen() { return cast(long) getJson("/api/history")["redo"].array.length; }
    string on() { return getJson("/api/input/context")["tool"].str; }
    assert(top() == "tool.topology_adjustment",
        "rig VOID " ~ name ~ ": the dormant haul wrote no attribute-only row: " ~ top());
    runStep(parseJSON(`{"op":"key","key":"Z","label":"z1"}`), rig, name ~ "/z1");
    assert(on() == rig.tool && redoLen() == 1,
        format("%s: Z1 took more than the attribute-only row (tool %s, redo %d)", name, on(), redoLen()));
    runStep(parseJSON(`{"op":"key","key":"Z","label":"z2"}`), rig, name ~ "/z2");
    assert(on() != rig.tool && redoLen() == 2,
        format("rig VOID %s: Z2 did not take the activation (tool %s, redo %d)", name, on(), redoLen()));
    runStep(parseJSON(`{"op":"key","key":"R","label":"r1"}`), rig, name ~ "/r1");
    assert(on() == rig.tool && redoLen() == 1,
        format("%s: R1 of a script-door activation brought its attribute-only row back with it "
               ~ "(tool %s, redo %d)", name, on(), redoLen()));
    auto r = postJson("/api/command", "tool.set " ~ rig.tool ~ " off");
    assert(r["status"].str == "ok", name ~ ": tool off: " ~ r.toString);
}

unittest { heldCell(kCells[0][0], kCells[0][1], kCells[0][2]); }
unittest { heldCell(kCells[1][0], kCells[1][1], kCells[1][2]); }
unittest { heldCell(kCells[2][0], kCells[2][1], kCells[2][2]); }
unittest { heldCell(kCells[3][0], kCells[3][1], kCells[3][2]); }
unittest { heldCell(kCells[4][0], kCells[4][1], kCells[4][2]); }
unittest { heldCell(kCells[5][0], kCells[5][1], kCells[5][2]); }
unittest { heldCell(kCells[6][0], kCells[6][1], kCells[6][2]); }
unittest { heldCell(kCells[7][0], kCells[7][1], kCells[7][2]); }
unittest { heldCell(kCells[8][0], kCells[8][1], kCells[8][2]); }
unittest { heldCell(kCells[9][0], kCells[9][1], kCells[9][2]); }
unittest { heldCell(kCells[10][0], kCells[10][1], kCells[10][2]); }
unittest { heldCell(kCells[11][0], kCells[11][1], kCells[11][2]); }
