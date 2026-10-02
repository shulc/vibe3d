// Topology-redo laws, generators family (Mirror, RadialArray, Array,
// Clone): every checkpoint of every captured cell of the family,
// replayed on our product and compared relation by relation with the frozen reference
// (`tests/fixtures/topology_redo_law_cells.json`; executor and comparison:
// tests/topology_redo_law_helpers.d). Wave plan topology-redo, slice S1b — the same
// executor and comparison as the inset family; the tools differ only by their rig.
//
// A green run says: every parity field still matches the reference AND every declared
// known divergence is still exactly the declared one. A divergence a later slice closes
// (or moves) turns its cell red with "divergence closed or moved: <cell>/<point> law <n>
// — flip to parity in <owner>". Order (form item 2): the family floor first, then one
// `unittest` per cell, then the count of compared cells.

import std.conv : to;
import std.json;
import http_client : getJson, postJson, frameFence;
import topology_redo_law_helpers;

void main() {}

enum string kFixture = import("fixtures/topology_redo_law_cells.json");

/// The family's cells (the generator's `--family generators` census, measured literal).
immutable string[] kCells = [
    "array_attrs_script", "array_attrs_ui", "array_dormant", "array_dormant_ui",
    "clone_attrs_script", "clone_attrs_ui", "clone_dormant", "clone_dormant_ui",
    "doapply_after_press_sa_mirror", "fold_close_mirror", "fold_close_mirror_ui",
    "mirror_attrs_script", "mirror_attrs_ui", "mirror_cmdclose_ui", "mirror_discrim",
    "mirror_discrim2", "mirror_discrim2_ui", "mirror_dormant", "mirror_dormant_ui",
    "param_between_array_script", "param_between_array_ui", "param_between_moment_array_ui",
    "param_closed_array_ui", "radial_attrs_script", "radial_attrs_ui", "radial_dormant",
    "radial_dormant_ui"
];

// `freeze_fixture.py --family generators` (2026-10-02, + 8960 Mirror):
// TOPO-REDO-CELLS family=generators cells=27 checkpoints=268 …
enum long kCellCount = 27;
enum long kCheckpointCount = 268;

unittest { // the floor: the fixture still holds the whole family
    familyFloor(parseJSON(kFixture), "generators", kCells, kCellCount, kCheckpointCount);
}

// Two stationary owners the plan names for this family, before any cell: the UI command
// that meets Mirror (model §6.4 C2m, `commandClose: none`) hands every divergent field
// from its own checkpoint on to the activation/command-close wave (plan §12, as C2s:
// «mirror_cmdclose_ui с s04_UC»; generator output 2026-10-02: 19 fields, all of them;
// S2b 8930 keeps 19: the redo of the attribute-only row s02_UC is a no-op success once
// our command dropped the tool, so the R tail stays parity), and Mirror's law 4 on the
// UI door is not captured (model §6.3) — one field.
unittest {
    const fx = parseJSON(kFixture);
    size_t c2m;
    string[] notCaptured;
    foreach (c; fx["cells"].array) {
        if (c["family"].str != "generators" || !c["measured"].boolean) continue;
        bool after;
        foreach (p; c["points"].array) {
            const at = c["id"].str ~ "/" ~ p["label"].str;
            if (c["id"].str == "mirror_cmdclose_ui" && p["label"].str == "s04_UC") after = true;
            foreach (field, f; p["fields"].object) {
                if ("ours" !in f) continue;
                if (f["owner"].str == "none: not captured (model §6.3)") notCaptured ~= at ~ "." ~ field;
                if (!after) continue;
                ++c2m;
                assert(f["owner"].str == "V4: activation/command-close wave", "fixture: " ~ at
                    ~ "." ~ field ~ " from the UI command on is owned by " ~ f["owner"].str
                    ~ " (model §6.4 C2m)");
            }
        }
    }
    assert(c2m == 19, "fixture family generators holds " ~ c2m.to!string
        ~ " divergent fields from the Mirror UI command on, frozen at 19");
    assert(notCaptured == ["mirror_attrs_ui/s04_R.attrs"], "fixture: the not-captured fields "
        ~ notCaptured.to!string ~ " are not model §6.3's one");
}

// Capture 8960 (findings §16), Mirror: a headless apply after a press and a scripted centre
// write stacks one mirrored copy of the selection (the inset suite pins the other three
// tools; task 8950, S3 fix 2).
unittest {
    pinApplyLadder(parseJSON(kFixture), "doapply_after_press_sa_mirror");
}

static foreach (id; kCells) {
    unittest { runCell(parseJSON(kFixture), id); }
}

// Task 8930 (wave S2b): OUR invariant, not a fixture cell — a scripted write that ends
// Mirror's operation, and a panel write while its post mode is not armed (an
// attribute-only row), leave the mesh as it is: the session holds the preview
// (`Tool.previewGated`, the one gate in `MirrorTool.evaluate`). The rig is the
// family's own (`mirror_discrim`: script arm, haul); `angle` is the panel attribute
// because it changes the mirrored geometry (`distance` welds only under `merge`).
private JSONValue mirrorRigCell() {
    foreach (c; parseJSON(kFixture)["cells"].array)
        if (c["id"].str == "mirror_discrim") return c;
    assert(false, "fixture holds no mirror_discrim cell (the Mirror gate's rig)");
}

private string mirrorPlanes() { return getJson("/api/mesh/planes").toString; }
private size_t undoDepth() { return getJson("/api/history")["undo"].array.length; }

/// Arm and haul Mirror (the rig's s01, s02), then end its operation by a scripted axis
/// write (M-PS). Positive control at the site: the haul itself changed the planes.
private void mirrorArmedHaulThenScript(string ctx) {
    const cell = mirrorRigCell();
    const rig = rigOf(cell["variant"].str);
    setupCell(cell, rig);
    runStep(cell["steps"][0], rig, ctx);
    const before = mirrorPlanes();
    runStep(cell["steps"][1], rig, ctx);
    assert(mirrorPlanes() != before, ctx ~ ": control — the Mirror haul changed no plane");
    auto st = getJson("/api/tool/state");
    assert(st["session"]["armed"].type == JSONType.true_, ctx ~ ": the haul did not arm the post mode");
    const planes = mirrorPlanes();
    const depth = undoDepth();
    auto r = postJson("/api/command", "tool.attr mesh.mirrorTool axis Z");
    assert(r["status"].str == "ok", ctx ~ ": scripted axis write failed: " ~ r.toString);
    frameFence(null, 2);
    assert(getJson("/api/tool/state")["session"]["armed"].type == JSONType.false_,
        ctx ~ ": the scripted write did not end the operation (armed)");
    assert(undoDepth() == depth, ctx ~ ": the scripted write wrote a row");
    if (ctx == "mirror gate: script")
        assert(mirrorPlanes() == planes,
            "mirror gate: a scripted write that ends the operation rebuilt Mirror's preview");
}

/// Off under a cell filter / a dump, unless the filter names this check.
private bool skipFor(string name) {
    import std.process : environment;
    const only = environment.get("VIBE3D_CELL", "");
    return (only.length && only != name) || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length;
}

unittest { // Mirror: a scripted write that ends the operation leaves the mesh
    if (skipFor("mirror_gate_script")) return;
    mirrorArmedHaulThenScript("mirror gate: script");
    cmdOkPublic("tool.set mesh.mirrorTool off");
}

unittest { // Mirror: the attribute-only row of a panel write leaves the mesh
    if (skipFor("mirror_gate_panel")) return;
    mirrorArmedHaulThenScript("mirror gate: panel");
    const planes = mirrorPlanes();
    const depth = undoDepth();
    auto p = postJson("/api/script?interactive=true", "tool.attr mesh.mirrorTool angle 90\n");
    assert(p["status"].str == "ok" || p["status"].str == "success",
        "mirror gate: panel angle write failed: " ~ p.toString);
    frameFence(null, 2);
    assert(mirrorPlanes() == planes,
        "mirror gate: a panel write while the post mode is not armed rebuilt Mirror's preview");
    assert(undoDepth() == depth + 1
        && getJson("/api/history")["undo"].array[$ - 1]["command"].str == "tool.topology_adjustment",
        "mirror gate: the panel write is not one attribute-only row");
    cmdOkPublic("tool.set mesh.mirrorTool off");
}

private void cmdOkPublic(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", line ~ ": " ~ r.toString);
}

unittest { // every cell was played and compared (a skipped cell is not a green one)
    import std.process : environment;
    if (environment.get("VIBE3D_CELL", "").length || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length)
        return;
    assert(cellsCompared == kCellCount, "the suite compared " ~ cellsCompared.to!string
        ~ " cells of the family's " ~ kCellCount.to!string);
}
