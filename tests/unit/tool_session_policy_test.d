// tool_session_policy_test — the tool session model's policy table (slice M1,
// doc/tool_session_model_plan_2026-09-24.md R3.5 witness (1) and R2.5 M1
// witness (3)).
//
// (1) One row per REGISTERED tool id: the class it builds, the class's
//     `sessionPolicy().activationRow`, what the production arm classifier
//     `toolArmEmitsLifecycle` answers for that id, and where the value comes
//     from. The id set is the registry's own: the static registrations as the
//     prepared writer census records them (`tools/prepared_writer_manifest.json`,
//     checked against source by `tools/check_prepared_protocol.py` in the suite
//     lane) plus every preset the production loader reads, whose class is its
//     base id's class (`registerToolPresets` builds the base's type). A policy
//     is read off an instance BLITTED from the class initializer, no
//     constructor run: overrides return static data, and constructing a tool
//     allocates GL objects.
//     Slice M2 adds the `commandClose` column and its provenance (CloseProv).
// (2) Every linked `tools.*` class that answers `activationRow`, exactly.
// (3) The history wiring: the keyboard/panel doors reach the tool session
//     through `EditSession.navigate`, and nothing in the input router steps
//     the history itself.
// (4) Slice M3: the tools whose SESSION owns their gesture steps
//     (`sessionSteps`), with `opensAt`, `noClone` and the declared attribute
//     image per id — every image and haul name is a param of the tool, and no
//     image name is an `Action` trigger (plan R4.3). The image operations are
//     `final` (a compiler pin, R3.2).
//
// Provenance: `carried` = today's classification moved from the deleted
// marker interface and the cutting-session ids, unchanged; `captured` = ported
// by a later slice on its own capture (poly.bevel, M3b: C-H1-bev; Edge Extend,
// M4: H1 + gap 218, whose first run carries the activation row; C-M4-token); `notPorted` = the
// captured law H1 (every tool's arm is an activation row) is not ported for
// this id yet (gap row 369, backlog 7307); `noCounterpart` / `uncertain` = the
// id has no mapped counterpart, or an unsure one, in the captured flags table.
// The false-row count is the ratchet slice M7 lowers.
// Fast loop: tools/local/ut-standalone.sh tests/unit/tool_session_policy_test.d
module tests.unit.tool_session_policy_test;

import create_tool_registration;
import edit_tool_registration;
import transform_tool_registration;

import prepared_tool_transition : toolArmEmitsLifecycle;
import tool         : CommandClose, HandleAnchor, OpensAt, Rollover, Tool, ToolSessionPolicy;
import tool_presets : loadToolPresets;
import tests.unit.census_symbols : blankNonCode;

import core.memory  : GC;
import std.algorithm : canFind, count, sort;
import std.array     : array, join;
import std.file      : readText;
import std.format    : format;
import std.json      : JSONType, parseJSON;
import std.regex     : matchFirst, regex;
import std.string    : indexOf, startsWith, strip;

private enum Prov { carried, captured, inferred, notPorted, noCounterpart, uncertain }

/// Where a row's `commandClose` comes from (slice M2): `carriedScript` = the
/// UI half captured (C1-h-sel-fam `move`), the SCRIPT half carried from the
/// task-6250 continuation, not captured (opponent R3 C7); `captured` = the
/// C1-h-sel / C1-h-sel-fam cells; `inferred` = the in-place family by the
/// law's wording (R20 gap g5); `notCaptured` = no in-place commit, the old
/// funnel rules (R20 gap g3).
private enum CloseProv { carriedScript, captured, inferred, notCaptured }

private struct Row {
    string id;
    string cls;          // unqualified class name the id's factory builds
    bool   activationRow;
    Prov   prov;
    CommandClose commandClose;   // slice M2
    CloseProv    closeProv;
}

/// Task 8240: 71 ids after preserving point attraction under a distinct ID.
private immutable Row[] kTable = [
    Row("ElementMove", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("Transform", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("TransformMove", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("TransformRotate", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("TransformScale", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("edge.bevel", "EdgeBevelTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("edge.extend", "EdgeExtendTool", true, Prov.captured, CommandClose.uiDoor, CloseProv.captured),
    Row("edge.extrude", "EdgeExtrudeTool", true, Prov.captured, CommandClose.uiDoor, CloseProv.inferred),
    Row("edge.slide", "EdgeSlideTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.arrayTool", "ArrayTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.bridgeTool", "BridgeTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.clone", "CloneTool", true, Prov.captured, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.dragWeld", "DragWeldTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.edgeSliceTool", "EdgeSliceTool", true, Prov.carried, CommandClose.uiDoor, CloseProv.captured),
    Row("mesh.loopSliceTool", "LoopSliceTool", true, Prov.carried, CommandClose.uiDoor, CloseProv.captured),
    Row("mesh.mirrorTool", "MirrorTool", true, Prov.captured, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.polyInsetTool", "PolyInsetTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.radialArrayTool", "RadialArrayTool", true, Prov.captured, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.radialSweepTool", "RadialSweepTool", false, Prov.uncertain, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.reduceTool", "ReductionTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.sliceTool", "SliceTool", true, Prov.carried, CommandClose.uiDoor, CloseProv.captured),
    Row("mesh.smoothShiftTool", "SmoothShiftTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.tack", "TackTool", false, Prov.noCounterpart, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.thickenTool", "SmoothShiftTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.topoPen", "TopologyPenTool", true, Prov.carried, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.vertexBevel", "VertexBevelTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.vertexExtrude", "VertexExtrudeTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("move", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("move.element", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("pen", "PenTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("poly.bevel", "PolyBevelTool", true, Prov.captured, CommandClose.uiDoor, CloseProv.captured),
    Row("poly.extrude", "PolyExtrudeTool", true, Prov.captured, CommandClose.uiDoor, CloseProv.inferred),
    Row("prim.arc", "ArcTool", false, Prov.noCounterpart, CommandClose.none, CloseProv.notCaptured),
    Row("prim.capsule", "CapsuleTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("prim.cone", "ConeTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("prim.cube", "BoxTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("prim.cylinder", "CylinderTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("prim.ellipsoid", "SphereTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("prim.sphere", "SphereTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("prim.torus", "TorusTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("prim.tube", "TubeTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("prim.vertex", "VertexTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("rotate", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("scale", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("tool.strokeExtrude", "StrokeExtrudeTool", false, Prov.uncertain, CommandClose.uiDoor, CloseProv.inferred),
    Row("vert.merge", "VertexMergeTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("xfrm.bend", "BendTool", true, Prov.inferred, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.bulge", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.elementMove", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.flare", "PushTool", true, Prov.inferred, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.flex", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.jitter", "XfrmJitterTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("xfrm.linearAlignTool", "LinearAlignTool", true, Prov.inferred, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.magnet", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.pointAttract", "MagnetTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("xfrm.push", "PushTool", true, Prov.inferred, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.quantize", "XfrmQuantizeTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("xfrm.radialAlignTool", "RadialAlignTool", true, Prov.inferred, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.scaleUniform", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.shear", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.smooth", "XfrmSmoothTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("xfrm.softDrag", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.softMove", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.softRotate", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.softScale", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.softTransform", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.swirl", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.taper", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.transform", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.twist", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.vortex", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
];

/// The classes whose policy answers `activationRow`.
private immutable string[] kActivationRowClasses = [
    "tools.alignment.array_tool.ArrayTool",
    "tools.alignment.clone_tool.CloneTool",
    "tools.alignment.linear_align_tool.LinearAlignTool",
    "tools.alignment.mirror.MirrorTool",
    "tools.alignment.radial_align_tool.RadialAlignTool",
    "tools.alignment.radial_array_tool.RadialArrayTool",
    "tools.common.command_wrapper.XfrmJitterTool",
    "tools.common.command_wrapper.XfrmQuantizeTool",
    "tools.common.command_wrapper.XfrmSmoothTool",
    "tools.deform.bend.BendTool",
    "tools.deform.magnet.MagnetTool",
    "tools.deform.push.PushTool",
    "tools.deform.smooth_shift_tool.SmoothShiftTool",
    "tools.edit.edge_bevel.EdgeBevelTool",
    "tools.edit.edge_extend.EdgeExtendTool",
    "tools.edit.edge_extrude.EdgeExtrudeTool",
    "tools.edit.poly_bevel.PolyBevelTool",
    "tools.edit.poly_extrude.PolyExtrudeTool",
    "tools.edit.poly_inset_tool.PolyInsetTool",
    "tools.edit.topology_pen.tool.TopologyPenTool",
    "tools.edit.vert_merge_tool.VertexMergeTool",
    "tools.edit.vertex_bevel_tool.VertexBevelTool",
    "tools.edit.vertex_extrude_tool.VertexExtrudeTool",
    "tools.slice.edge_slice_tool.EdgeSliceTool",
    "tools.slice.loop_slice_tool.LoopSliceTool",
    "tools.slice.slice_tool.SliceTool",
    "tools.transform.move.MoveTool",
    "tools.transform.rotate.RotateTool",
    "tools.transform.scale.ScaleTool",
    "tools.transform.transform.TransformTool",
    "tools.transform.xfrm_transform.XfrmTransformTool",
];

/// A tool instance with its vtable and field defaults but NO constructor run.
/// Only for reading `sessionPolicy()`, which returns static data.
private Tool blit(const TypeInfo_Class ci) {
    const init = ci.initializer;
    auto mem = GC.malloc(init.length)[0 .. init.length];
    mem[] = init[];
    return cast(Tool) cast(Object) mem.ptr;
}

private bool derivesFromTool(TypeInfo_Class c) {
    for (auto b = c; b !is null; b = b.base)
        if (b is typeid(Tool)) return true;
    return false;
}

// The policy hook is a base virtual (a data read, not a cast), callable from
// the arm classifier's `nothrow @nogc` body.
static assert(__traits(isVirtualMethod, Tool.sessionPolicy));
static assert(is(typeof(() nothrow @nogc {
    const Tool t = null; return t.sessionPolicy(); })));
static assert(ToolSessionPolicy.init.activationRow == false);
// The marker it replaced is gone.
static assert(!__traits(compiles, { import edit_session : LifecycleUndoEmitter; }));

unittest { // (1) id -> policy, over every registered id
    auto manifest = parseJSON(readText("tools/prepared_writer_manifest.json"));
    string[string] moduleOf;                       // class -> module
    foreach (p; manifest["products"].array)
        moduleOf[p["aggregate"].str] = p["module"].str;
    string[string] classOf;                        // id -> class
    size_t staticIds;
    foreach (f; manifest["factories"].array) {
        const id = f["id"].str;
        if (id.startsWith("<")) continue;          // the generated preset row
        const products = f["product_types"].array;
        assert(products.length == 1,
               "M1 policy table: static id " ~ id ~ " builds more than one type");
        classOf[id] = products[0].str;
        ++staticIds;
    }
    size_t presetIds;
    foreach (p; loadToolPresets("config/tool_presets.yaml")) {
        assert(p.base in classOf,
               "M1 policy table: preset " ~ p.id ~ " has an unregistered base " ~ p.base);
        assert(p.id !in classOf, "M1 policy table: preset id " ~ p.id ~ " collides");
        classOf[p.id] = classOf[p.base];
        ++presetIds;
    }
    // Population floors: measured, not derived from the table.
    assert(staticIds == 48 && presetIds == 23,
           format("M1 policy table: registry population changed: %s static + %s presets, "
                  ~ "measured 48 + 23", staticIds, presetIds));
    assert(kTable.length == 71 && classOf.length == 71,
           format("M1 policy table: %s table rows, %s registered ids, measured 71",
                  kTable.length, classOf.length));

    size_t falseRows, notPorted;
    size_t[3] closeCount;
    string[] replacesIds;
    foreach (row; kTable) {
        auto cls = row.id in classOf;
        assert(cls !is null, "M1 policy table: row " ~ row.id ~ " is not a registered id");
        assert(*cls == row.cls, format("M1 policy table: %s builds %s, table says %s",
                                       row.id, *cls, row.cls));
        auto mod = row.cls in moduleOf;
        assert(mod !is null, "M1 policy table: no module recorded for " ~ row.cls);
        auto ci = TypeInfo_Class.find(*mod ~ "." ~ row.cls);
        assert(ci !is null, "M1 policy table: class not linked: " ~ *mod ~ "." ~ row.cls);
        auto t = blit(ci);
        const policy = t.sessionPolicy();
        assert(policy.activationRow == row.activationRow,
               format("M1 policy table: %s (%s) activationRow %s, table says %s",
                      row.id, row.cls, policy.activationRow, row.activationRow));
        // The production arm classifier IS the field (slice M3 removed the
        // cutting-session id arm, redundant since M1).
        assert(toolArmEmitsLifecycle(t) == row.activationRow,
               format("M1 policy table: toolArmEmitsLifecycle(%s) is %s, table says %s",
                      row.id, !row.activationRow, row.activationRow));
        assert(row.activationRow == (row.prov == Prov.carried || row.prov == Prov.captured
                                     || row.prov == Prov.inferred),
               "M1 policy table: provenance of " ~ row.id ~ " disagrees with its value");
        if (!row.activationRow) ++falseRows;
        if (row.prov == Prov.notPorted) ++notPorted;
        assert(policy.commandClose == row.commandClose,
               format("M2 policy table: %s (%s) commandClose %s, table says %s",
                      row.id, row.cls, policy.commandClose, row.commandClose));
        // A tool closes on a command only if it can: the transform and the
        // cutting tools by their own body, every other `uiDoor` tool by the
        // in-place commit it declares.
        assert((row.commandClose == CommandClose.none) == (row.closeProv == CloseProv.notCaptured),
               "M2 policy table: provenance of " ~ row.id ~ " disagrees with its commandClose");
        ++closeCount[row.commandClose];
        if (policy.headlessReplacesWindow) replacesIds ~= row.id;
    }
    // Slice M3b review R1: `tool.doApply` replaces the live window of exactly
    // one tool (measured); every other id keeps today's door.
    assert(replacesIds == ["poly.bevel"],
           format("M3b policy table: headlessReplacesWindow on %s, recorded [poly.bevel]",
                  replacesIds));
    // Measured on the M2 tree (`grep -c 'CommandClose.<value>, CloseProv'` over this file).
    assert(closeCount == [22, 24, 25],
           format("M2 policy table: commandClose none/uiDoor/allDoors on %s ids, recorded "
                  ~ "22/24/25", closeCount));
    // The M7 ratchet, only down: ids whose arm writes no activation row yet
    // (gap 369). M3b ported poly.bevel: 42 (38) -> 41 (37); M4 ported
    // edge.extend: -> 40 (36). Growth is a new id born off the H1 law, or a
    // ported one regressed; a fall is recorded by lowering the ceiling.
    // Task 7990 ported edge.extrude to 39 (35); task 8030 ports
    // poly.extrude to 38 (34).
    assert(falseRows <= kActivationRowFalseCeiling && notPorted <= kNotPortedCeiling,
           format("M7 ratchet: activationRow=false grew to %s ids (%s not ported), ceiling "
                  ~ "%s (%s): a tool's arm writes its activation row (H1, gap 369) — declare "
                  ~ "`activationRow` in its policy instead", falseRows, notPorted,
                  kActivationRowFalseCeiling, kNotPortedCeiling));
    assert(falseRows == kActivationRowFalseCeiling && notPorted == kNotPortedCeiling,
           format("M7 ratchet: activationRow=false fell to %s ids (%s not ported), ceiling "
                  ~ "%s (%s): lower the ceiling in the same commit", falseRows, notPorted,
                  kActivationRowFalseCeiling, kNotPortedCeiling));
}

/// Slice M7: the down-only ceilings of the policy table (plan R3.1, R3.5, R2.2
/// "sessionSteps"): ids whose arm writes no activation row, of them the ones
/// not ported (the rest have no counterpart or an unsure one), and ids whose
/// session does not own their gesture steps (H2 not ported). Measured on the
/// M7 tree; each only falls.
private enum size_t kActivationRowFalseCeiling = 18;
private enum size_t kNotPortedCeiling = 14;
private enum size_t kSessionStepsFalseCeiling = 0;

/// Task 8250: these 19 existing command producers now use the same completed
/// History-row owner as Transform. The other 18 rows retain image/topology
/// policies; this exact set catches a silent class-wide policy spill.
private immutable string[] kAdditionalHistoryRows = [
    "edge.slide", "mesh.bridgeTool", "mesh.dragWeld", "mesh.radialSweepTool",
    "mesh.reduceTool", "mesh.tack", "mesh.topoPen", "pen", "prim.arc",
    "prim.capsule", "prim.cone", "prim.cube", "prim.cylinder",
    "prim.ellipsoid", "prim.sphere", "prim.torus", "prim.tube",
    "prim.vertex", "tool.strokeExtrude",
];

unittest { // (2) tool classes that declare the activation row
    string[] declared;
    size_t scanned;
    foreach (m; ModuleInfo) {
        if (m is null || !m.name.startsWith("tools.")) continue;
        foreach (c; m.localClasses) {
            if (!derivesFromTool(c) || (c.m_flags & TypeInfo_Class.ClassFlags.isAbstract))
                continue;
            ++scanned;
            if (blit(c).sessionPolicy().activationRow) declared ~= c.name;
        }
    }
    // Measured 2026-09-25 (the same under `dmd -i` and the gate: the three
    // registration imports above pull every production tool module in).
    assert(scanned == 48, format("M1 policy classes: scanned %s concrete tools.* classes, "
                                 ~ "measured 48", scanned));
    sort(declared);
    assert(declared == kActivationRowClasses,
           format("M1 policy classes: activationRow declared by %s, expected %s",
                  declared, kActivationRowClasses));
}

/// `{ ... }` body of the first declaration introduced by `marker`.
private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "M1 wiring census: marker moved: " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "M1 wiring census: no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    assert(false, "M1 wiring census: unbalanced body after " ~ marker);
}

/// `s` with every whitespace character removed.
private string squeeze(string s) {
    import std.ascii : isWhite;
    string r;
    foreach (c; s) if (!isWhite(c)) r ~= c;
    return r;
}

/// Offsets of `needles` in `hay`, each present exactly once, in order.
private void inOrder(string hay, string[] needles, string where) {
    ptrdiff_t last = -1;
    foreach (n; needles) {
        assert(hay.count(n) == 1,
               format("M1 wiring census: %s has %s x `%s`, expected 1", where, hay.count(n), n));
        const at = hay.indexOf(n);
        assert(at > last, format("M1 wiring census: %s: `%s` moved out of order", where, n));
        last = at;
    }
}

unittest { // (3) the doors reach the tool session only through EditSession
    auto app = blankNonCode(readText("source/app.d"));
    // The whole body, whitespace-free: any other statement (a direct
    // `history.undo ()`, a bare `history.undo;`) changes it.
    const nav = squeeze(bodyAt(app, "bool navHistory(bool isUndo)"));
    assert(nav == "{returnsession.navigate(isUndo);}",
           "M1 wiring census: app.d navHistory is no longer exactly "
           ~ "`return session.navigate(isUndo);`, got " ~ nav);

    auto router = blankNonCode(readText("source/input_router.d"));
    assert(router.canFind("navHistory(true)") && router.canFind("navHistory(false)"),
           "M1 wiring census: the key router no longer routes Ctrl+Z through navHistory");
    auto step = matchFirst(router, regex(`\.\s*(undo|redo)\b`));
    assert(step.empty,
           "M1 wiring census: the key router steps the history directly: " ~ step.hit);

    auto es = blankNonCode(readText("source/edit_session.d"));
    const navigate = bodyAt(es, "bool navigate(bool isUndo)");
    inOrder(navigate, ["if (g_heldGestureButtons.any) return false;",
                       "return isUndo ? tools_.undo() : tools_.redo();"],
            "EditSession.navigate");
    const ts = bodyAt(es, "private struct ToolSession");
    // The branch order the navigate contract fixes, per direction.
    // Slice M3: the session's own steps answer first, before every tool-held
    // branch.
    // Slice M4: the tool-held peel, keep-alive, live-redo and run-record
    // branches are gone; the record that carries its activation row is read
    // before the stack steps, and a restored predecessor adopts its token after.
    inOrder(bodyAt(ts, "bool undo()"),
            ["navigateRecorded_(true)", "navigateTopology_(true)", "undoFirstGroup_(t)",
             "cancelUncommittedEdit()", "recordCarriesActivation_()",
             "resyncSession()", "adoptPredecessorToken_("],
            "ToolSession.undo");
    inOrder(bodyAt(ts, "bool redo()"),
            ["navigateRecorded_(false)", "navigateTopology_(false)", "applyAttrImage(img)",
             "carriesFirstRecord()", "adoptToken_(",
             "resyncSession()", "replayFirstGroup_()"],
            "ToolSession.redo");
    // Nothing else in the module steps the history.
    assert(es.count("history_.undo()") == 9 && es.count("history_.redo()") == 5,
           format("M1 wiring census: edit_session.d steps the history %s/%s times, "
                  ~ "expected undo 9 (live recorded ladder, topology and prior ToolSession branches) and "
                  ~ "redo 5 (recorded producer, topology and prior ToolSession branches)",
                  es.count("history_.undo()"), es.count("history_.redo()")));
}

// ---------------------------------------------------------------------------
// (4) Slice M3 — the session-owned steps, per id.
// ---------------------------------------------------------------------------

/// The image operations are `final`: what is restorable is the declaration's.
static assert(__traits(isFinalFunction, Tool.captureAttrImage));
static assert(__traits(isFinalFunction, Tool.applyAttrImage));
static assert(__traits(isFinalFunction, Tool.openOperation));
static assert(__traits(isVirtualMethod, Tool.rebuildPreviewFromAttrs));
static assert(ToolSessionPolicy.init.sessionSteps == false
              && ToolSessionPolicy.init.imageAttrs.length == 0);

private struct StepRow {
    string id;
    OpensAt opensAt;
    bool noClone;
    string[] imageAttrs;
    string armAttr;
}

/// Measured on the M3 tree. Provenance: `opensAt` — M0 H1 (Edge Slice and Slice
/// open at the press, Loop Slice at its arm, C-H1-es / C-H1-ls); `noClone` —
/// the static flags read (Edge Slice only); the images — plan R4.3 plus
/// `count` (C-H2-ls-insert P1) and Loop Slice's seed set (PLAN-FINDING, card M3).
private immutable StepRow[] kStepTable = [
    StepRow("mesh.arrayTool", OpensAt.firstPress, false,
        ["numX", "numY", "numZ", "offX", "offY", "offZ",
         "jitX", "jitY", "jitZ", "sclX", "sclY", "sclZ", "angP",
         "angH", "angB", "between", "replace", "flip", "merge",
         "dist", "source", "item"]),
    StepRow("mesh.clone", OpensAt.firstPress, false,
        ["num", "offX", "offY", "offZ", "sclX", "sclY", "sclZ",
         "angP", "angH", "angB", "between", "snap", "snapAngle",
         "replace", "flip", "merge", "dist", "source", "item"]),
    StepRow("edge.bevel", OpensAt.firstPress, false,
            ["width", "roundLevel", "widthMode"]),
    // Slice M4: the 11 haul attributes plus the operation-open state.
    StepRow("edge.extend", OpensAt.firstPress, false,
            ["opOpen", "inset", "shift", "offsetX", "offsetY", "offsetZ",
             "rotateX", "rotateY", "rotateZ", "scaleX", "scaleY", "scaleZ"]),
    StepRow("edge.extrude", OpensAt.arm, false,
            ["extrude", "width"]),
    StepRow("mesh.edgeSliceTool", OpensAt.firstPress, true,
            ["chain", "edges", "activePoint"]),
    StepRow("mesh.loopSliceTool", OpensAt.arm, false,
            ["positions", "current", "count", "seeds", "armedSelFaces"]),
    StepRow("mesh.mirrorTool", OpensAt.firstPress, false,
            ["axis", "center", "invertPolys", "mergeVerts", "distance",
             "angle", "mode", "left", "up"]),
    StepRow("mesh.polyInsetTool", OpensAt.firstPress, false, ["inset"]),
    StepRow("mesh.radialArrayTool", OpensAt.firstPress, false,
            ["count", "axis", "center", "angle", "offset", "weld"]),
    StepRow("mesh.sliceTool", OpensAt.firstPress, false,
            ["startX", "startY", "startZ", "endX", "endY", "endZ", "vectorX", "vectorY",
             "vectorZ", "axis", "gap", "frozenNormal", "haveFrozen", "axisLocked", "hasLine"]),
    StepRow("mesh.smoothShiftTool", OpensAt.firstPress, false,
            ["shift", "scale", "maxAngle", "thicken", "sharp"]),
    StepRow("mesh.thickenTool", OpensAt.firstPress, false,
            ["shift", "scale", "maxAngle", "thicken", "sharp"]),
    StepRow("mesh.vertexBevel", OpensAt.firstPress, false, ["inset"]),
    StepRow("mesh.vertexExtrude", OpensAt.firstPress, false,
            ["shift", "width"]),
    // Task 8030: the first Polygon topology record carries activation; each
    // later operation remains a separate history-owned row.
    StepRow("poly.extrude", OpensAt.firstPress, false,
        ["distance", "shiftX", "shiftY", "shiftZ"]),
    // M3b: the arm applies (C-H1-bev), Middle clones (C-H5-bev-mmb); the image
    // is the haul plus the operation's applied flag and its base index.
    StepRow("poly.bevel", OpensAt.arm, false, ["inset", "shift", "applied", "op"], "applied"),
    StepRow("vert.merge", OpensAt.firstPress, false, ["dist"]),
];

unittest { // (4)
    auto manifest = parseJSON(readText("tools/prepared_writer_manifest.json"));
    string[string] moduleOf;
    foreach (p; manifest["products"].array)
        moduleOf[p["aggregate"].str] = p["module"].str;
    string[] stepIds, imageStepIds;
    size_t checkedNames, actionNames, armAttrs, stepsFalse, recordedSteps;
    foreach (row; kTable) {
        auto ci = TypeInfo_Class.find(moduleOf[row.cls] ~ "." ~ row.cls);
        auto t = blit(ci);
        const pol = t.sessionPolicy();
        const transformId = row.id.startsWith("xfrm.") ||
            ["ElementMove", "Transform", "TransformMove", "TransformRotate",
             "TransformScale", "move", "move.element", "rotate", "scale"].canFind(row.id);
        assert(pol.historyRecordedSteps ==
               (transformId || kAdditionalHistoryRows.canFind(row.id)),
               "history producer policy drifted for " ~ row.id);
        assert(pol.previewHistoryLadder == (row.id == "prim.cube"),
               "Box live History ladder policy drifted for " ~ row.id);
        if (!pol.sessionSteps) {
            ++stepsFalse;
            assert(pol.imageAttrs.length == 0 && pol.haulAttrs.length == 0,
                   "M3 step table: " ~ row.id ~ " declares an image without sessionSteps");
            continue;
        }
        stepIds ~= row.id;
        if (pol.historyRecordedSteps) {
            ++recordedSteps;
            assert(pol.imageAttrs.length == 0 && pol.haulAttrs.length == 0,
                   "history-owned row declares a duplicate image: " ~ row.id);
            continue;
        }
        imageStepIds ~= row.id;
        // Session-step classes expose field-backed params, so `params()` of a
        // blitted (unconstructed) instance is safe here.
        auto ps = t.params();
        bool hasParam(string n) {
            foreach (ref p; ps) if (p.name == n) return true;
            return false;
        }
        bool isAction(string n) {
            foreach (ref p; ps) if (p.name == n) return p.action_;
            return false;
        }
        foreach (ref p; ps) if (p.action_) ++actionNames;
        foreach (n; pol.imageAttrs) {
            assert(hasParam(n), format("M3 step table: %s image names '%s', not one of its params",
                                       row.id, n));
            assert(!isAction(n), format("M3 step table: %s image names the Action trigger '%s' "
                                        ~ "(a restore would fire it)", row.id, n));
            ++checkedNames;
        }
        foreach (n; pol.haulAttrs)
            assert(hasParam(n), format("M3 step table: %s haul names '%s', not one of its params",
                                       row.id, n));
        // M3b: the attribute an arm raises is a BOOL of the image, and only an
        // `OpensAt.arm` tool has one (the session reads it at the arm alone).
        if (pol.armAttr.length) {
            bool isBool;
            foreach (ref p; ps) if (p.name == pol.armAttr) isBool = p.kind == p.Kind.Bool;
            assert(isBool && pol.imageAttrs.canFind(pol.armAttr) && pol.opensAt == OpensAt.arm,
                   format("M3b step table: %s arm attribute '%s' is not a bool of its image on an "
                          ~ "arm-opened tool", row.id, pol.armAttr));
            ++armAttrs;
        }
        bool found;
        foreach (sr; kStepTable) {
            if (sr.id != row.id) continue;
            found = true;
            assert(pol.opensAt == sr.opensAt && pol.noClone == sr.noClone
                   && pol.imageAttrs == sr.imageAttrs && pol.armAttr == sr.armAttr,
                   format("M3 step table: %s policy {opensAt %s, noClone %s, image %s, arm '%s'}, "
                          ~ "table says {%s, %s, %s, '%s'}", row.id, pol.opensAt, pol.noClone,
                          pol.imageAttrs, pol.armAttr, sr.opensAt, sr.noClone, sr.imageAttrs,
                          sr.armAttr));
            if (row.id == "poly.extrude")
                assert(pol.haulAttrs == sr.imageAttrs,
                    "M3 step table: Polygon haul image drifted from its full parameter image");
        }
        assert(found, "M3 step table: " ~ row.id ~ " has sessionSteps but no step-table row");
    }
    // The M7 ratchet, only down: ids whose session does not own their gesture
    // steps yet (H2, measured on all six families; `false` = not ported). The
    // floor beside it: every registered row was visited.
    assert(stepsFalse + stepIds.length == kTable.length && kTable.length == 71,
           format("M7 ratchet: visited %s + %s of %s table rows", stepsFalse, stepIds.length,
                  kTable.length));
    assert(stepsFalse <= kSessionStepsFalseCeiling,
           format("M7 ratchet: sessionSteps=false grew to %s ids, ceiling %s: the tool session "
                  ~ "owns a tool's gesture steps (H2) — declare `sessionSteps` and its image "
                  ~ "instead of a per-tool stack", stepsFalse, kSessionStepsFalseCeiling));
    assert(stepsFalse == kSessionStepsFalseCeiling,
           format("M7 ratchet: sessionSteps=false fell to %s ids, ceiling %s: lower the ceiling "
                  ~ "in the same commit", stepsFalse, kSessionStepsFalseCeiling));
    assert(recordedSteps == 53,
           format("history-owned rows %s, expected 53", recordedSteps));
    // Image-producing population floors: 18 ids, 119 image names, 3 Action triggers
    // on them (chainArm; insertAt, removeCurrent), 1 arm attribute (M3b).
    sort(imageStepIds);
    assert(imageStepIds == ["edge.bevel", "edge.extend", "edge.extrude",
                       "mesh.arrayTool", "mesh.clone", "mesh.edgeSliceTool", "mesh.loopSliceTool",
                       "mesh.mirrorTool", "mesh.polyInsetTool", "mesh.radialArrayTool",
                       "mesh.sliceTool", "mesh.smoothShiftTool",
                       "mesh.thickenTool", "mesh.vertexBevel", "mesh.vertexExtrude",
                       "poly.bevel", "poly.extrude", "vert.merge"],
           format("M3 step table: image-step ids %s", imageStepIds));
    assert(checkedNames == 119, format("M3 step table: %s image names checked, measured 119",
                                      checkedNames));
    assert(armAttrs == 1, format("M3b step table: %s arm attributes, measured 1", armAttrs));
    assert(actionNames == 3, format("M3 step table: %s Action params on the session tools, "
                                    ~ "measured 3", actionNames));
}

// ---------------------------------------------------------------------------
// (5) Slice M4 — the two data fields that replaced per-tool capabilities:
// `keepAliveOnCancel` (the former KeepAliveOnCancel interface: the create
// family, tasks 0400/0430, and Mirror) and `recordCarriesActivation` (the
// former ToolRunRecord / markRunOwner: Edge Extend's first run, gap 218).
// ---------------------------------------------------------------------------

/// Measured on the M4 tree: the create family's eight CONCRETE classes (the
/// census's nine create rows less the abstract HandledCreateTool; they inherit
/// the datum from the abstract PrimitiveCreateTool, or declare it, BoxTool)
/// and Mirror (the tenth keep-alive tool, S3 review).
private immutable string[] kKeepAliveClasses = [
    "tools.alignment.mirror.MirrorTool",
    "tools.create.box.BoxTool",
    "tools.create.capsule.CapsuleTool",
    "tools.create.cone.ConeTool",
    "tools.create.cylinder.CylinderTool",
    "tools.create.sphere.SphereTool",
    "tools.create.torus.TorusTool",
    "tools.create.tube.TubeTool",
];

static assert(ToolSessionPolicy.init.keepAliveOnCancel == false
              && ToolSessionPolicy.init.recordCarriesActivation == false);
// The capability interfaces they replaced are gone.
static assert(!__traits(compiles, { import edit_session : KeepAliveOnCancel; }));
static assert(!__traits(compiles, { import edit_session : SessionStepUndo; }));
static assert(!__traits(compiles, { import edit_session : SessionLiveRedo; }));
static assert(!__traits(compiles, { import edit_session : SwitchRestorablePredecessor; }));
static assert(!__traits(compiles, { import command : ToolRunRecord; }));

unittest { // (5)
    string[] keep, carries;
    size_t scanned;
    foreach (m; ModuleInfo) {
        if (m is null || !m.name.startsWith("tools.")) continue;
        foreach (c; m.localClasses) {
            if (!derivesFromTool(c) || (c.m_flags & TypeInfo_Class.ClassFlags.isAbstract))
                continue;
            ++scanned;
            const pol = blit(c).sessionPolicy();
            if (pol.keepAliveOnCancel) keep ~= c.name;
            if (pol.recordCarriesActivation) carries ~= c.name;
        }
    }
    assert(scanned == 48, format("M4 policy classes: scanned %s concrete tools.* classes, "
                                 ~ "measured 48", scanned));
    sort(keep);
    sort(carries);
    assert(keep == kKeepAliveClasses,
           format("M4 policy classes: keepAliveOnCancel declared by %s, expected %s",
                  keep, kKeepAliveClasses));
    assert(carries == ["tools.alignment.mirror.MirrorTool",
                       "tools.alignment.radial_array_tool.RadialArrayTool",
                       "tools.deform.smooth_shift_tool.SmoothShiftTool",
                       "tools.edit.edge_extend.EdgeExtendTool",
                       "tools.edit.poly_extrude.PolyExtrudeTool",
                       "tools.edit.poly_inset_tool.PolyInsetTool"],
           format("M4 policy classes: recordCarriesActivation declared by %s", carries));
}

// ---------------------------------------------------------------------------
// (6) Slice M6 — the rollover flag (H7) and the handle anchor (H8) as data.
// The rollover column is the neutral copy of the captured flags table
// (tests/fixtures/tool_rollover_flags.json, generated by the private
// toolcard's harness/gen_rollover_fixture.py): `actor` = the tool's own node
// carries the flag, `stage` = another node of its pipe does.
// ---------------------------------------------------------------------------

static assert(ToolSessionPolicy.init.rollovers == Rollover.none
              && ToolSessionPolicy.init.handleAnchor == HandleAnchor.acenPlusT);
// The capability interface the rollover replaced is gone.
static assert(!__traits(compiles, { import hover_state : TargetHighlightKeeper; }));
static assert(!__traits(compiles, { import hover_state : Rollover; }));
static assert(__traits(isVirtualMethod, Tool.handleAnchorPoint));

/// The ids with no mapped counterpart (or an unsure one) keep their pre-M6
/// highlight, carried (plan R4.1): of the four only the tack draws one.
private immutable string[] kCarriedTargetIds = ["mesh.tack"];


unittest { // (6) id -> rollovers, over every registered id
    auto manifest = parseJSON(readText("tools/prepared_writer_manifest.json"));
    string[string] moduleOf;
    foreach (p; manifest["products"].array)
        moduleOf[p["aggregate"].str] = p["module"].str;
    string[string][string][string] pipeOf;       // preset id -> its pipe attrs
    foreach (p; loadToolPresets("config/tool_presets.yaml"))
        pipeOf[p.id] = p.pipeAttrs;
    auto flags = parseJSON(readText("tests/fixtures/tool_rollover_flags.json"))["rows"].array;
    assert(flags.length == kTable.length,
           format("M6 rollover table: %s flag rows for %s registered ids", flags.length,
                  kTable.length));
    size_t[3] perValue;
    string[] targetIds, stageIds, carried;
    foreach (i, row; kTable) {
        const f = flags[i];
        assert(f["id"].str == row.id, format("M6 rollover table: row %s is %s, flag row %s",
                                             i, row.id, f["id"].str));
        auto t = blit(TypeInfo_Class.find(moduleOf[row.cls] ~ "." ~ row.cls));
        const pol = t.sessionPolicy();
        immutable bool actor = f["actor"].type == JSONType.true_;
        immutable string mapping = f["mapping"].str;
        Rollover want = actor ? Rollover.target : Rollover.none;
        if (kCarriedTargetIds.canFind(row.id)) {
            assert(mapping != "mapped" && !actor,
                   "M6 rollover table: a carried flag is for an id with no counterpart, not "
                   ~ row.id);
            want = Rollover.target;
        }
        assert(pol.rollovers == want,
               format("M6 rollover table: %s (%s) rollovers %s, the flags table says %s (%s)",
                      row.id, row.cls, pol.rollovers, want, mapping));
        ++perValue[pol.rollovers];
        if (actor || kCarriedTargetIds.canFind(row.id)) targetIds ~= row.id;
        if (f["stage"].type == JSONType.true_) {
            stageIds ~= row.id;
            // The flag of a pipe node: carried here by an element node the
            // preset installs — the element falloff (`FalloffStage.rollovers`)
            // or the element centre (`ActionCenterStage.rollovers`); either
            // alone lights the vertex (M0e).
            auto pipe = row.id in pipeOf;
            const bool elementFalloff = pipe !is null && "falloff" in *pipe
                && (*pipe)["falloff"].get("type", "") == "element";
            const bool elementCentre = pipe !is null && "actionCenter" in *pipe
                && (*pipe)["actionCenter"].get("mode", "") == "element";
            assert(elementFalloff || elementCentre,
                   "M6 rollover table: the flags table puts a stage flag on " ~ row.id
                   ~ " and its preset installs no element node to carry it");
            carried ~= row.id;
        }
    }
    sort(targetIds); sort(stageIds); sort(carried);
    // Population floors (measured on the M6 tree, from the fixture).
    assert(targetIds == ["mesh.dragWeld", "mesh.edgeSliceTool", "mesh.tack", "mesh.topoPen",
                         "pen", "prim.vertex"],
           format("M6 rollover table: the target flag is on %s", targetIds));
    assert(stageIds == ["ElementMove", "move.element", "xfrm.elementMove"]
           && carried == stageIds,
           format("M6 rollover table: stage flag on %s, carried by the element falloff on %s",
                  stageIds, carried));
    assert(perValue == [65, 6, 0],
           format("M6 rollover table: none/target/vertices on %s ids, recorded 65/6/0",
                  perValue));
}

unittest { // (6b) the two element nodes carry the vertex flag (M0e: either alone)
    import toolpipe.stages.falloff : FalloffStage;
    import toolpipe.stages.actcenter : ActionCenterStage;
    import toolpipe.packets : FalloffType;
    import std.traits : EnumMembers;
    auto fs = new FalloffStage();
    size_t flagged;
    foreach (ty; EnumMembers!FalloffType) {
        fs.type = ty;
        const r = fs.rollovers();
        assert(r == (ty == FalloffType.Element ? Rollover.vertices : Rollover.none),
               format("M6: FalloffStage type %s answers rollovers %s", ty, r));
        if (r != Rollover.none) ++flagged;
    }
    assert(flagged == 1, "M6: one falloff type carries a rollover flag");
    // Blitted like the tools above: `rollovers` reads `mode` only, and the
    // constructor publishes pipe state.
    const acInit = typeid(ActionCenterStage).initializer;
    auto acMem = GC.malloc(acInit.length)[0 .. acInit.length];
    acMem[] = acInit[];
    auto ac = cast(ActionCenterStage) cast(Object) acMem.ptr;
    flagged = 0;
    foreach (m; EnumMembers!(ActionCenterStage.Mode)) {
        ac.mode = m;
        const r = ac.rollovers();
        assert(r == (m == ActionCenterStage.Mode.Element ? Rollover.vertices : Rollover.none),
               format("M6: ActionCenterStage mode %s answers rollovers %s", m, r));
        if (r != Rollover.none) ++flagged;
    }
    assert(flagged == 1, "M6: one action-centre mode carries a rollover flag");
}

unittest { // (6c) exactly one class anchors its handle on its own operation
    string[] declared;
    size_t scanned;
    foreach (m; ModuleInfo) {
        if (m is null || !m.name.startsWith("tools.")) continue;
        foreach (c; m.localClasses) {
            if (!derivesFromTool(c) || (c.m_flags & TypeInfo_Class.ClassFlags.isAbstract))
                continue;
            ++scanned;
            if (blit(c).sessionPolicy().handleAnchor == HandleAnchor.opBasePlusAttr)
                declared ~= c.name;
        }
    }
    assert(scanned == 48, format("M6 policy classes: scanned %s, measured 48", scanned));
    assert(declared == ["tools.edit.edge_extend.EdgeExtendTool"],
           format("M6 policy classes: handleAnchor opBasePlusAttr declared by %s", declared));
}

// ---------------------------------------------------------------------------
// (7) Slice M6 — the ONE viewport read of the rollover data. The helper above
// is exercised by tests/test_session_laws_display.d in pixels; this pins that
// the production draw reads it at every hover site and nowhere by cast.
// ---------------------------------------------------------------------------

unittest { // (7)
    auto vr = blankNonCode(readText("source/ui/viewport_render.d"));
    const fn = squeeze(bodyAt(vr, "bool rolloverShown(EditMode type)"));
    assert(fn == "{if(activeToolisnull)returntrue;immutablebooldrag=activeTool.isDragging();"
               ~ "returnrolloverDraws(activeTool.sessionPolicy().rollovers,type,drag)"
               ~ "||scene.pipeContext.pipeline.rolloverDraws(type,drag);}",
           "M6 wiring census: viewport_render.d rolloverShown changed: " ~ fn);
    // The three hover indices the draw hands to GL go through it.
    foreach (n; ["vertHovForDraw=rolloverShown(EditMode.Vertices)?hoveredVertex:-1",
                 "edgeHovForDraw=rolloverShown(EditMode.Edges)?hoveredEdge:-1",
                 "faceHovForDraw=rolloverShown(EditMode.Polygons)?hoveredFace:-1"])
        assert(squeeze(vr).count(n) == 1, "M6 wiring census: missing `" ~ n ~ "`");
    assert(!vr.canFind("TargetHighlightKeeper"),
           "M6 wiring census: the retired highlight capability is read again");
}

// ---------------------------------------------------------------------------
// (8) Slice M7 — the prepared arm's sticky-name replay reads policy DATA
// (`armRestoresWholeImage`), not a tool id: exactly Loop Slice declares it,
// and `prepareArm` names no tool id (it held `id != "mesh.loopSliceTool"`).
// ---------------------------------------------------------------------------

static assert(ToolSessionPolicy.init.armRestoresWholeImage == false);

unittest { // (8)
    string[] declared;
    size_t scanned;
    foreach (m; ModuleInfo) {
        if (m is null || !m.name.startsWith("tools.")) continue;
        foreach (c; m.localClasses) {
            if (!derivesFromTool(c) || (c.m_flags & TypeInfo_Class.ClassFlags.isAbstract))
                continue;
            ++scanned;
            if (blit(c).sessionPolicy().armRestoresWholeImage) declared ~= c.name;
        }
    }
    assert(scanned == 48, format("M7 policy classes: scanned %s, measured 48", scanned));
    assert(declared == ["tools.slice.loop_slice_tool.LoopSliceTool"],
           format("M7 policy classes: armRestoresWholeImage declared by %s", declared));
    auto pt = squeeze(blankNonCode(readText("source/prepared_tool_transition.d")));
    assert(pt.count("if(!candidate.sessionPolicy().armRestoresWholeImage)foreach(name;sticky.changedNames)") == 1,
           "M7 wiring census: prepareArm no longer gates the sticky replay on the policy");
    // blankNonCode keeps string literals' quotes but blanks their contents, so
    // an id literal is matched on the raw source.
    auto raw = readText("source/prepared_tool_transition.d");
    foreach (id; ["\"mesh.loopSliceTool\"", "\"mesh.edgeSliceTool\"", "\"mesh.sliceTool\""])
        assert(!raw.canFind(id), "M7 wiring census: prepared_tool_transition.d names " ~ id);
}

// ---------------------------------------------------------------------------
// (9) Slice M7 review — the second composition pin: the UNION of interfaces
// (base classes walked, `InterfacesTuple`) that the concrete tool classes
// block (8) scans implement, fixed at COMPILE time. A capability interface a
// tool opts into — wherever it is declared (`prepared_record_context.d`,
// `toolpipe/*`, …) — stops the build instead of joining the session model
// silently. The module list is the scan's: the unittest below proves it is
// exactly the set of `tools.*` modules with a concrete tool class, so a new
// tool module cannot sit outside the pin.
// ---------------------------------------------------------------------------

private enum string[] kToolClassModules = [
    "tools.alignment.array_tool", "tools.alignment.clone_tool",
    "tools.alignment.linear_align_tool", "tools.alignment.mirror",
    "tools.alignment.radial_align_tool", "tools.alignment.radial_array_tool",
    "tools.alignment.radial_sweep_tool", "tools.common.command_wrapper", "tools.create.arc",
    "tools.create.box", "tools.create.capsule", "tools.create.cone", "tools.create.cylinder",
    "tools.create.pen", "tools.create.sphere", "tools.create.torus", "tools.create.tube",
    "tools.create.vertex_place", "tools.deform.bend", "tools.deform.magnet",
    "tools.deform.push", "tools.deform.smooth_shift_tool", "tools.deform.stroke_extrude_tool",
    "tools.edit.bridge_tool", "tools.edit.drag_weld", "tools.edit.edge_bevel",
    "tools.edit.edge_extend", "tools.edit.edge_extrude", "tools.edit.poly_bevel",
    "tools.edit.poly_extrude", "tools.edit.poly_inset_tool", "tools.edit.reduce",
    "tools.edit.tack", "tools.edit.topology_pen.tool", "tools.edit.vert_merge_tool",
    "tools.edit.vertex_bevel_tool", "tools.edit.vertex_extrude_tool",
    "tools.slice.edge_slice_tool", "tools.slice.edge_slide", "tools.slice.loop_slice_tool",
    "tools.slice.slice_tool", "tools.transform.move", "tools.transform.rotate",
    "tools.transform.scale", "tools.transform.transform", "tools.transform.xfrm_transform",
];

/// [concrete tool class names..., "|", interface names...] of those modules.
private string[] toolClassComposition() {
    import std.traits : InterfacesTuple, fullyQualifiedName;
    string[] classes, ifaces;
    static foreach (mn; kToolClassModules) {{
        mixin("static import " ~ mn ~ ";");
        alias M = mixin(mn);
        static foreach (m; __traits(allMembers, M)) {{
            static if (__traits(compiles, __traits(getMember, M, m))) {
                alias T = __traits(getMember, M, m);
                static if (is(T == class)) {
                    static if (is(T : Tool) && !__traits(isAbstractClass, T)) {
                        classes ~= fullyQualifiedName!T;
                        static foreach (I; InterfacesTuple!T)
                            ifaces ~= fullyQualifiedName!I;
                    }
                }
            }
        }}
    }}
    string[] u;
    foreach (n; ifaces.sort.array) if (u.length == 0 || u[$ - 1] != n) u ~= n;
    return classes.sort.array ~ ["|"] ~ u;
}

private enum string[] kPinnedToolInterfaces = [
    "edit_session.FrameParameterEvalClient", "edit_session.LiveEvalClient",
    "edit_session.RefireClient", "edit_session.SlotActivationClient", "params.ParamProvider",
    "prepared_record_context.PreparedToolDoorClient",
    "prepared_record_context.PreparedToolParamDoorClient",
    "prepared_record_context.PreparedToolPoseDoorClient", "tool.InputBindable",
    "tool.TopologyStepClient",
];

private enum string[] kToolComposition = toolClassComposition();
private enum size_t kToolBar = () { foreach (i, n; kToolComposition) if (n == "|") return i; assert(0); }();
static assert(kToolComposition[kToolBar + 1 .. $] == kPinnedToolInterfaces,
    "M7 tool pin: the concrete tool classes implement [" ~ kToolComposition[kToolBar + 1 .. $].join(", ")
    ~ "], pinned [" ~ kPinnedToolInterfaces.join(", ") ~ "]: express a per-tool capability as "
    ~ "ToolSessionPolicy data or a Tool operation (doc/tool_session_model_plan_2026-09-24.md), "
    ~ "not a new interface");
// Population floor: the pin read the 48 classes block (8) scans.
static assert(kToolBar == 48, "M7 tool pin: read concrete tool classes, measured 48");

unittest { // Tasks 7990/8030: production topology R wiring, not a helper replica.
    auto es = blankNonCode(readText("source/edit_session.d"));
    auto esFlat = squeeze(es);
    auto edge = blankNonCode(readText("source/tools/edit/edge_extrude.d"));
    auto poly = blankNonCode(readText("source/tools/edit/poly_extrude.d"));
    auto carrier = blankNonCode(readText("source/commands/mesh/session_edit.d"));
    auto panelCode = blankNonCode(readText("source/property_panel.d"));
    auto panel = squeeze(panelCode);
    auto attr = squeeze(blankNonCode(readText("source/commands/tool/attr.d")));
    const edgePreparedClose = squeeze(bodyAt(edge,
        "final PreparedDeactivateEffect prepareDeactivate("));
    const polyPreparedClose = squeeze(bodyAt(poly,
        "final PreparedDeactivateEffect prepareDeactivate("));
    assert(es.canFind("if (navigateTopology_(true)) return true;")
        && es.canFind("if (navigateTopology_(false)) return true;"),
        "Edge topology navigation bypassed the production ToolSession door");
    assert(esFlat.canFind("constcompletedTopologyIsHistoryOwned=reporting_(t)&&t.sessionPolicy().historyTopologySteps&&!topologyPending_;")
        && esFlat.canFind("t.hasUncommittedEdit()&&!completedTopologyIsHistoryOwned"),
        "completed topology state regained the legacy cancel-first responder");
    assert(es.canFind("topologyParameterStepBegins(t, beforeWrite)")
        && es.canFind("cmd.setTopologyStep(topologyPendingAttrs_, attrs,"),
        "interactive parameter or history-owned step payload was disconnected");
    assert(edge.canFind("sessionStepBegins(e.button == SDL_BUTTON_MIDDLE")
        && edge.canFind("sessionStepEnds();")
        && edgePreparedClose.count("context.markNoHistoryInstall()") == 1
        && !edgePreparedClose.canFind("markHistoryInstall("),
        "Edge drag/Middle or prepared close lost its production seam");
    assert(edge.canFind("recordGestureEdit(cmd, GestureRecordMode.Plain)")
        && !edge.canFind("GestureRecordMode.ReplaceRunTail"),
        "Edge topology rows must stay separate Plain records");
    assert(poly.canFind("sessionStepBegins(e.button == SDL_BUTTON_MIDDLE")
        && poly.canFind("sessionStepEnds();")
        && poly.canFind("recordGestureEdit(cmd, GestureRecordMode.Plain)")
        && polyPreparedClose.count("c.markNoHistoryInstall()") == 1
        && !polyPreparedClose.canFind("markHistoryInstall(")
        && !poly.canFind("GestureRecordMode.ReplaceRunTail"),
        "Polygon drag/boundary, Plain owner or prepared close lost its production seam");
    assert(edge.canFind("discardFirstTopologyRedoOnActivationUndo: true")
        && edge.canFind("dormantAfterClosedRedo: true")
        && edge.canFind("opensAt: OpensAt.arm")
        && es.canFind("history_.invalidateRedo()")
        && es.canFind("topologyFirstGroupLive_")
        && es.canFind("arm.markDormantTopology()")
        && es.canFind("new TopologyAdjustmentEdit(context, tool_")
        && edge.canFind("if (topologyDormant) return;"),
        "Edge first-group or full-closed-redo production policy disconnected");
    assert(poly.canFind("recordCarriesActivation: true")
        && poly.canFind("dormantAfterClosedRedo: true")
        && poly.canFind("opensAt: OpensAt.firstPress")
        && poly.canFind("if (topologyDormant) return;"),
        "Polygon first-group or full-closed-redo production policy disconnected");
    assert(es.canFind("closedTopologyRedoSource_ = act;")
        && es.canFind("last.get is closedTopologyRedoSource_.get")
        && es.canFind("validClosedTopologyRedo_(arm, id)")
        && esFlat.canFind("sourceisnull||armisnull||closedTopologyId_!=id||arm.armedId()!=id||arm.previousId()!=source.armedId()||arm.previousToken()!=source.sessionToken()")
        && esFlat.canFind("ue.length>=2&&ue[$-1].cmdisarm&&ue[$-2].cmdissource"),
        "closed topology redo lost its source-row cursor or activation lineage");
    assert(es.canFind("pendingTopologyCarriesActivation_()")
        && es.canFind("!current.sessionPolicy().firstTopologyRedoUsesAfterAttrs")
        && es.canFind("restoreBefore ? cmd.stepBeforeAttrs() : cmd.stepAfterAttrs()")
        && !poly.canFind("firstTopologyRedoUsesAfterAttrs: true"),
        "generic first-topology activation replay lost Polygon attrs/basis law");
    assert(es.canFind("if (topologyPending_ && reporting_(t)")
        && es.canFind("if (topologyPending_) {")
        && edge.canFind("closeOwnOperation(false);"),
        "Edge pending close or RMB history consistency path disconnected");
    assert(carrier.canFind("void setTopologyStep(")
        && carrier.canFind("stepBeforeBasis_")
        && carrier.canFind("stepAfterAttrs_"),
        "history command lost topology basis or attributes");
    const panelDraw = squeeze(bodyAt(panelCode,
        "void drawProvider(ParamProvider p, EditSession session)"));
    inOrder(panelDraw, [
        "beforeWrite=tisnull||!t.sessionPolicy().historyTopologySteps?AttrImage.init:t.captureAttrImage();",
        "boolchanged=drawParamWidget(par);",
        "session.orchestrateParameterChange(p,par.name,source,ParameterChangePhase.ValueWritten,beforeWrite);",
    ], "PropertyPanel.drawProvider topology prewrite");
    assert(panel.count("beforeWrite=tisnull||!t.sessionPolicy().historyTopologySteps?AttrImage.init:t.captureAttrImage();") == 1
        && panel.count("session.orchestrateParameterChange(p,par.name,source,ParameterChangePhase.ValueWritten,beforeWrite);") == 1
        && attr.canFind("beforeWrite=t.sessionPolicy().historyTopologySteps?t.captureAttrImage():AttrImage.init;")
        && attr.canFind("t,attrName_,source,ParameterChangePhase.ValueWritten,beforeWrite);"),
        "pointer-written parameter producer lost the actual prewrite image");
}

unittest { // (9) the compile-time module list IS the runtime scan
    bool[string] mods, classes, ifaces;
    foreach (m; ModuleInfo) {
        if (m is null || !m.name.startsWith("tools.")) continue;
        foreach (c; m.localClasses) {
            if (!derivesFromTool(c) || (c.m_flags & TypeInfo_Class.ClassFlags.isAbstract))
                continue;
            mods[m.name] = true;
            classes[c.name] = true;
            for (auto k = cast(TypeInfo_Class) c; k !is null; k = k.base)
                foreach (i; k.interfaces) ifaces[i.classinfo.name] = true;
        }
    }
    assert(mods.keys.sort.array == kToolClassModules,
           format("M7 tool pin: tool modules with a concrete class %s, pinned list %s",
                  mods.keys.sort, kToolClassModules));
    assert(classes.keys.sort.array == kToolComposition[0 .. kToolBar],
           format("M7 tool pin: runtime classes %s, compile-time %s", classes.keys.sort,
                  kToolComposition[0 .. kToolBar]));
    assert(ifaces.keys.sort.array == kPinnedToolInterfaces,
           format("M7 tool pin: runtime interfaces %s, pinned %s", ifaces.keys.sort,
                  kPinnedToolInterfaces));
}
