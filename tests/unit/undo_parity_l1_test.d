// undo_parity_l1_test — the FROZEN parity fixture for stage L1's family
// (UV maps / weight + morph maps / selection sets), and its reader.
//
// WHY THIS ONE HAS A DEADLINE AND L0's DID NOT. L0 deleted no `MeshSnapshot`,
// so for its families the dense path is still in the tree and still available
// as a live oracle. L1 is the first family that DELETES snapshots — 27 of them,
// across nine files — and a family that deletes its dense path destroys the
// only thing its delta could have been compared against. This file is captured
// on the tree where all 27 are still live; after they go it is the sole
// surviving record of what they produced.
//
// `path` IS `"snapshot"` HERE AND THAT IS HONEST — 26 of the 27 classes really
// do hold a `MeshSnapshot` today, and the 27th (`SelectSetApply`) holds a
// `SelectionSnapshot` per touched layer. Contrast L0, where the same field
// needed a third value because fourteen of sixteen commands restored from a
// hand-rolled per-command image; see `undo_parity_l0_test`'s header.
//
// THE STAND IS `makeTaggedGridMaps`, NOT `makeTaggedGridFull`, and the
// difference is what makes the fixture able to fail. The family's headline
// plane is `MeshMap.present`: empty MEANS "all present", so a revert that puts
// `data` back and drops the presence channel yields a legal, WRONG map. On
// `makeTaggedGridFull` there is no presence-tracked map at all, so that plane
// is `[]` on every cell and every candidate revert agrees about it.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l1_test;

import command;
import mesh;
import view;
import editmode;
import math : Vec3;

import tests.unit.fixtures : makeTaggedGridMaps;
import tests.unit.undo_parity_l0_test : ParityCell, runCell, compareOrCapture,
                                        setS, setI, setF, setV, setB;

import commands.mesh.uv_map_util : UvDelete, UvRename, UvCopy, UvClear;
import commands.mesh.uv_transform: UvFlip, UvMirror, UvRotate;
import commands.mesh.uv_pack     : UvFit, UvPack;
import commands.mesh.uv_project  : UvProject;
import commands.mesh.uv_relax    : UvRelax;
import commands.mesh.uv_unwrap   : UvUnwrap;
import commands.mesh.weightmap   : WeightmapCreate, WeightmapRemove,
                                   WeightmapRename, WeightmapSet;
import commands.mesh.morph       : MorphCreate, MorphRemove, MorphRename,
                                   MorphSet, MorphClear, MorphApplyCmd;
import commands.select.sets      : SelectSetStore, SelectSetEdit,
                                   SelectSetRename, SelectSetDelete;

enum string kL1Family = "uv_maps_sets";
enum string kL1Stand  = "makeTaggedGridMaps(3)";

private Mesh* l1Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridMaps(3);
    m.buildLoops();
    return m;
}

/// The 26 single-mesh mutating classes of the family, in file order.
///
/// `SelectSetApply` is NOT here: it binds a `Document*` and edits SEVERAL
/// meshes, while every other cell — and `meshPlanesJson` itself — reads ONE.
/// A one-layer document would let it construct and then measure the one case
/// its two blockers do not arise in, which is a decoy, not a cell. It is named
/// as a gap.
ParityCell[] l1Cells(string sha)
{
    ParityCell[] out_;
    void cell(string name, Command delegate(Mesh*, View) mk) {
        out_ ~= runCell(name, "snapshot", kL1Family, kL1Stand, sha, &l1Stand, mk);
    }

    // ---- uv_map_util.d — the map REGISTRY, (R) ---------------------------
    cell("uv.delete", (m, v) {
        auto c = new UvDelete(m, v, EditMode.Polygons);
        setS(c, "name", "uv2"); return cast(Command)c; });
    cell("uv.rename", (m, v) {
        auto c = new UvRename(m, v, EditMode.Polygons);
        setS(c, "from", "uv2"); setS(c, "to", "uv3"); return cast(Command)c; });
    cell("uv.copy", (m, v) {
        auto c = new UvCopy(m, v, EditMode.Polygons);
        // `uv.copy` CREATES its target (`addMeshMap`, which refuses an
        // existing name), so the destination must be a NEW name — that is
        // also what makes its undo owe a map REMOVAL and not a value restore.
        setS(c, "from", "uv"); setS(c, "to", "uvC"); return cast(Command)c; });
    cell("uv.clear", (m, v) {
        auto c = new UvClear(m, v, EditMode.Polygons);
        setS(c, "name", "uv"); return cast(Command)c; });

    // ---- uv_transform.d — map VALUES over a loop subset, (V) -------------
    cell("uv.flip", (m, v) {
        auto c = new UvFlip(m, v, EditMode.Polygons);
        setS(c, "axis", "u"); setS(c, "pivot", "unit"); return cast(Command)c; });
    cell("uv.mirror", (m, v) {
        auto c = new UvMirror(m, v, EditMode.Polygons);
        setS(c, "axis", "v"); setS(c, "pivot", "centroid"); return cast(Command)c; });
    cell("uv.rotate", (m, v) {
        auto c = new UvRotate(m, v, EditMode.Polygons);
        setF(c, "angle", 37.0f); setS(c, "pivot", "centroid");
        return cast(Command)c; });

    // ---- uv_pack.d — whole-map VALUE rewrites, (V) -----------------------
    cell("uv.fit", (m, v) {
        auto c = new UvFit(m, v, EditMode.Polygons);
        setS(c, "keepAspect", "stretch"); return cast(Command)c; });
    cell("uv.pack", (m, v) {
        auto c = new UvPack(m, v, EditMode.Polygons);
        setF(c, "gutter", 0.02f); return cast(Command)c; });

    // ---- the two create-if-absent hybrids, (V)+(R) -----------------------
    cell("uv.project", (m, v) {
        auto c = new UvProject(m, v, EditMode.Polygons);
        setF(c, "size", 2.0f); return cast(Command)c; });
    cell("uv.unwrap", (m, v) {
        auto c = new UvUnwrap(m, v, EditMode.Polygons);
        setI(c, "iter", 3); return cast(Command)c; });

    cell("uv.relax", (m, v) {
        // WHOLE-MAP mode, reached by dropping the stand's single-face polygon
        // selection. `uvRelax` pins the corners of every UNSELECTED face, and
        // one selected quad has nothing BUT pinned neighbours, so with the
        // inherited selection the kernel returns false and the cell would
        // freeze a refusal. Caught by `runCell`'s apply assert.
        m.deselectFace(7);
        auto c = new UvRelax(m, v, EditMode.Polygons);
        setI(c, "iter", 3); setF(c, "strn", 0.7f); return cast(Command)c; });

    // ---- weightmap.d — Point-domain (R) and (V) --------------------------
    cell("mesh.weightmap.create", (m, v) {
        auto c = new WeightmapCreate(m, v, EditMode.Vertices);
        setS(c, "name", "W2"); return cast(Command)c; });
    cell("mesh.weightmap.remove", (m, v) {
        auto c = new WeightmapRemove(m, v, EditMode.Vertices);
        setS(c, "name", "W"); return cast(Command)c; });
    cell("mesh.weightmap.rename", (m, v) {
        auto c = new WeightmapRename(m, v, EditMode.Vertices);
        setS(c, "from", "W"); setS(c, "to", "W9"); return cast(Command)c; });
    cell("mesh.weightmap.set", (m, v) {
        auto c = new WeightmapSet(m, v, EditMode.Vertices);
        setS(c, "name", "W"); setI(c, "vert", 6); setF(c, "weight", 0.875f);
        return cast(Command)c; });

    // ---- morph.d — the PRESENCE-tracked kinds ----------------------------
    cell("mesh.morph.create", (m, v) {
        auto c = new MorphCreate(m, v, EditMode.Vertices);
        setS(c, "name", "MB"); setS(c, "kind", "absolute");
        return cast(Command)c; });
    cell("mesh.morph.remove", (m, v) {
        auto c = new MorphRemove(m, v, EditMode.Vertices);
        setS(c, "name", "MA"); return cast(Command)c; });
    cell("mesh.morph.rename", (m, v) {
        auto c = new MorphRename(m, v, EditMode.Vertices);
        setS(c, "from", "MA"); setS(c, "to", "MZ"); return cast(Command)c; });
    // The cell that separates "restored the value" from "restored the
    // presence": vertex 3 is ABSENT on the stand, so this write flips a
    // presence bit as well as three floats.
    cell("mesh.morph.set", (m, v) {
        auto c = new MorphSet(m, v, EditMode.Vertices);
        setS(c, "name", "MA"); setI(c, "vert", 3);
        setF(c, "x", 0.7f); setF(c, "y", -0.3f); setF(c, "z", 0.25f);
        return cast(Command)c; });
    // …and its inverse: vertices 1 and 4 are PRESENT and non-zero, so the
    // clear zeroes `data` AND drops `present`. A revert that restores only
    // `data` leaves them absent, which for `MA` (morphAbsolute) is a
    // GEOMETRIC difference and for `MR` is not.
    cell("mesh.morph.clear", (m, v) {
        m.selectVertex(1); m.selectVertex(4);
        auto c = new MorphClear(m, v, EditMode.Vertices);
        setS(c, "name", "MA"); return cast(Command)c; });
    // Writes POSITIONS, reads the map. The one class in the family whose
    // payload is (P) `Kind.SetPos` and not a map value at all.
    cell("mesh.morph.apply", (m, v) {
        auto c = new MorphApplyCmd(m, v, EditMode.Vertices);
        setS(c, "name", "MA"); setF(c, "amount", 1.0f);
        return cast(Command)c; });

    // ---- select/sets.d — the set REGISTRY, (S) ---------------------------
    cell("select.set.store", (m, v) {
        auto c = new SelectSetStore(m, v, EditMode.Vertices);
        setS(c, "name", "V3"); return cast(Command)c; });
    cell("select.set.edit", (m, v) {
        auto c = new SelectSetEdit(m, v, EditMode.Vertices);
        setS(c, "name", "V"); setS(c, "mode", "add"); return cast(Command)c; });
    cell("select.set.rename", (m, v) {
        auto c = new SelectSetRename(m, v, EditMode.Vertices);
        setS(c, "from", "V"); setS(c, "to", "VV"); return cast(Command)c; });
    cell("select.set.delete", (m, v) {
        auto c = new SelectSetDelete(m, v, EditMode.Vertices);
        setS(c, "name", "V2"); return cast(Command)c; });

    return out_;
}

// ---------------------------------------------------------------------------
// THE READER.
//
// MUTATION THAT REDDENS IT: perturb one recorded plane value in
// `tests/fixtures/undo_parity/uv_maps_sets.json` — see the card. The message
// names the cell, which dump, and the plane.
// ---------------------------------------------------------------------------
unittest
{
    import std.process : environment;
    immutable sha = environment.get("VIBE3D_PARITY_SHA", "");
    compareOrCapture("uv_maps_sets.json", kL1Family, sha, kL1Stand, l1Cells(sha));
}
