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
import topology_redo_law_helpers;

void main() {}

enum string kFixture = import("fixtures/topology_redo_law_cells.json");

/// The family's cells (the generator's `--family generators` census, measured literal).
immutable string[] kCells = [
    "array_attrs_script", "array_attrs_ui", "array_dormant", "array_dormant_ui",
    "clone_attrs_script", "clone_attrs_ui", "clone_dormant", "clone_dormant_ui",
    "fold_close_mirror", "fold_close_mirror_ui", "mirror_attrs_script", "mirror_attrs_ui",
    "mirror_cmdclose_ui", "mirror_discrim", "mirror_discrim2", "mirror_discrim2_ui",
    "mirror_dormant", "mirror_dormant_ui", "param_between_array_script",
    "param_between_array_ui", "param_between_moment_array_ui", "param_closed_array_ui",
    "radial_attrs_script", "radial_attrs_ui", "radial_dormant", "radial_dormant_ui"
];

// `freeze_fixture.py --family generators` (2026-10-01):
// TOPO-REDO-CELLS family=generators cells=26 checkpoints=259 …
enum long kCellCount = 26;
enum long kCheckpointCount = 259;

unittest { // the floor: the fixture still holds the whole family
    familyFloor(parseJSON(kFixture), "generators", kCells, kCellCount, kCheckpointCount);
}

// Two stationary owners the plan names for this family, before any cell: the UI command
// that meets Mirror (model §6.4 C2m, `commandClose: none`) hands every divergent field
// from its own checkpoint on to the activation/command-close wave (plan §12, as C2s:
// «mirror_cmdclose_ui с s04_UC»; generator output 2026-10-02: 19 fields, all of them),
// and Mirror's law 4 on the UI door is not captured (model §6.3) — one field.
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

static foreach (id; kCells) {
    unittest { runCell(parseJSON(kFixture), id); }
}

unittest { // every cell was played and compared (a skipped cell is not a green one)
    import std.process : environment;
    if (environment.get("VIBE3D_CELL", "").length || environment.get("VIBE3D_TOPO_REDO_DUMP", "").length)
        return;
    assert(cellsCompared == kCellCount, "the suite compared " ~ cellsCompared.to!string
        ~ " cells of the family's " ~ kCellCount.to!string);
}
