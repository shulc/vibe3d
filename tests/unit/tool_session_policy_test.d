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
import std.algorithm : canFind, count, endsWith, filter, sort;
import std.array     : array, join;
import std.file      : readText;
import std.format    : format;
import std.json      : JSONType, parseJSON;
import std.conv      : to;
import std.regex     : matchAll, matchFirst, regex;
import std.string    : endsWith, indexOf, lastIndexOf, startsWith, strip;

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
    // A topology-pen preset since task 9525: the pen's policy, carried.
    Row("mesh.dragWeld", "TopologyPenTool", true, Prov.carried, CommandClose.uiDoor, CloseProv.inferred),
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
    Row("mesh.topoPen", "TopologyPenTool", true, Prov.carried, CommandClose.uiDoor, CloseProv.captured),
    Row("mesh.vertexBevel", "VertexBevelTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.vertexExtrude", "VertexExtrudeTool", true, Prov.inferred, CommandClose.uiDoor, CloseProv.inferred),
    Row("move", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("move.element", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    // Pen wave plan S8: BD-sel (K-B3, Backspace), UC-close (K-B4, select.invert /
    // flip) and UC1-end (K-B5, below the commit minimum) — UI door only.
    Row("pen", "PenTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.captured),
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
    assert(staticIds == 47 && presetIds == 24,
           format("M1 policy table: registry population changed: %s static + %s presets, "
                  ~ "measured 47 + 24", staticIds, presetIds));
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
    // Measured on the M2 tree (`grep -c 'CommandClose.<value>, CloseProv'` over this file);
    // S7a round 3 moved mesh.topoPen none -> uiDoor (L57, capture C5); pen
    // wave S8 moved pen none -> uiDoor (BD-sel, UC-close, UC1-end); task 9525
    // moved mesh.dragWeld none -> uiDoor (a topology-pen preset).
    assert(closeCount == [19, 27, 25],
           format("M2 policy table: commandClose none/uiDoor/allDoors on %s ids, recorded "
                  ~ "19/27/25", closeCount));
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
private enum size_t kActivationRowFalseCeiling = 17;
private enum size_t kNotPortedCeiling = 13;
private enum size_t kSessionStepsFalseCeiling = 0;

/// Task 8250: these existing command producers now use the same completed
/// History-row owner as Transform: 16 rows, since the Topology Pen (plan 8646),
/// the polygon pen (task 9369) and Drag Weld (task 9525) left for their own
/// step protocols. The other rows retain image/topology policies; this exact
/// set catches a silent class-wide policy spill.
private immutable string[] kAdditionalHistoryRows = [
    "edge.slide", "mesh.bridgeTool", "mesh.radialSweepTool",
    "mesh.reduceTool", "mesh.tack", "prim.arc",
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
    assert(scanned == 47, format("M1 policy classes: scanned %s concrete tools.* classes, "
                                 ~ "measured 47", scanned));
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
    // The whole body, whitespace-free: History still flows through the session,
    // and only a failed outside Redo can publish the terminal notice.
    const nav = squeeze(bodyAt(app, "bool navHistory(bool isUndo)"));
    assert(nav == "{constmoved=session.navigate(isUndo);if(!isUndo&&!moved&&session.terminalRedoRequested())guardModalState.publishHistoryTerminal();returnmoved;}",
           "M1 wiring census: app.d navHistory body changed: " ~ nav);

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
    inOrder(bodyAt(ts, "private bool undoImpl_()"),
            ["navigateRecorded_(true)", "navigateTopology_(true)", "undoFirstGroup_(t)",
             "cancelUncommittedEdit()", "recordCarriesActivation_()", "absorbedRunAbove_()",
             "rebaseAfterTail_(", "restorePredecessor_("],
            "ToolSession.undoImpl_");
    inOrder(bodyAt(ts, "private bool redoImpl_()"),
            ["navigateRecorded_(false)", "navigateTopology_(false)", "applyAttrImage(img)",
             "carriesFirstRecord()", "adoptToken_(",
             "rebaseAfterTail_(", "replayFirstGroup_()"],
            "ToolSession.redoImpl_");
    // Wave plan 8640 S7a: the redo door is the step, then the parameter-row
    // prune once the history is Active again — never inside the step (m18).
    // The undo door has no prune (amendment A16: it was inert).
    // Task 8920 (S2a): the depth snapshot first, the settle after a MOVED stack;
    // task 8930 (S2b): the snapshot also holds the token and the armed model post mode.
    // Task 9508 (K-RD rule 3): the bound tool's activation row is read before
    // the step; the step that removed it, leaving no tool, makes the tool latent.
    assert(squeeze(bodyAt(ts, "bool undo()")) == "{navBefore_=NavBefore(history_.undoEntries().length,"
           ~ "token_,boundModel_()&&postmodeArmed_);"
           ~ "constarmRow=latentArmRow_();constid=armedId_;"
           ~ "constcompletionBefore=completedDropUndo_;constr=undoImpl_();if(r)openBlock_=null;"
           ~ "if(r&&completedDropUndo_==completionBefore&&history_.undoEntries().length!=navBefore_.depth)settleAfterNavigation_(true);"
           ~ "if(r&&armRow!=size_t.max&&history_.undoEntries().length<=armRow){"
           ~ "latentId_=id;latentGen_=history_.generation();}"
           ~ "returnr;}",
           "S7a wiring census: ToolSession.undo body changed: " ~ squeeze(bodyAt(ts, "bool undo()")));
    inOrder(squeeze(bodyAt(ts, "bool redo()")),
            ["openBlock_=null;", "constr=redoImpl_();", "if(r)pruneRedoTop_();", "returnr;"],
            "ToolSession.redo");
    assert(es.count("pruneRedoTop_()") == 2,
           format("S7a wiring census: edit_session.d names pruneRedoTop_() %s times, expected 2 "
                  ~ "(the declaration and the redo door)", es.count("pruneRedoTop_()")));
    // Nothing else in the module steps the history.
    assert(es.count("history_.undo()") == 11 && es.count("history_.redo()") == 9,
           format("M1 wiring census: edit_session.d steps the history %s/%s times, "
                  ~ "expected undo 11 (closed-run replay, live recorded ladder, topology incl. its "
                  ~ "folded run, and prior ToolSession branches) and "
                  ~ "redo 9 (recorded first-step re-arm, recorded producer, topology incl. its folded "
                  ~ "run, the activation's folded run, the attribute-only row with its UI activation "
                  ~ "(S6), and prior ToolSession branches)",
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
    // Task 8920 (law 1): Edge Bevel, Vertex Bevel and Vertex Extrude open at the
    // arm — the captured script cell and the three UI cells `s01 armed=True`.
    StepRow("edge.bevel", OpensAt.arm, false,
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
            ["axis", "center", "invertPolys", "merge", "dist",
             "angle", "mode", "left", "up"]),
    StepRow("mesh.polyInsetTool", OpensAt.firstPress, false, ["inset"]),
    StepRow("mesh.radialArrayTool", OpensAt.firstPress, false,
            ["count", "axis", "center", "angle", "offset", "merge", "dist"]),
    StepRow("mesh.sliceTool", OpensAt.firstPress, false,
            ["startX", "startY", "startZ", "endX", "endY", "endZ", "vectorX", "vectorY",
             "vectorZ", "axis", "gap", "frozenNormal", "haveFrozen", "axisLocked", "hasLine"]),
    StepRow("mesh.smoothShiftTool", OpensAt.firstPress, false,
            ["shift", "scale", "maxAngle", "thicken", "sharp"]),
    StepRow("mesh.thickenTool", OpensAt.firstPress, false,
            ["shift", "scale", "maxAngle", "thicken", "sharp"]),
    StepRow("mesh.vertexBevel", OpensAt.arm, false, ["inset"]),
    StepRow("mesh.vertexExtrude", OpensAt.arm, false,
            ["shift", "width"]),
    // Task 8030: the first Polygon topology record carries activation; each
    // later operation remains a separate history-owned row.
    StepRow("poly.extrude", OpensAt.firstPress, false,
        ["distance", "shiftX", "shiftY", "shiftZ"]),
    // M3b: the arm applies (C-H1-bev), Middle clones (C-H5-bev-mmb); the image
    // is the haul plus the operation's applied flag and its base index.
    StepRow("poly.bevel", OpensAt.arm, false, ["inset", "shift", "applied", "op"], "applied"),
    StepRow("vert.merge", OpensAt.firstPress, false, ["dist"]),
    // Task 9369: the polygon pen's stroke is its image — every attribute plus
    // the hidden `points` (captured in-stroke undo, fixture pen_instroke_undo);
    // task 9362 adds `merge`, the hidden per-point `link` and its mesh key;
    // task 9365 (S8) `close` and `selectNew`; task 9366 (S9) `wall`, `offset`;
    // task 9416 `raycast`.
    StepRow("pen", OpensAt.firstPress, false,
            ["type", "currentPoint", "posX", "posY", "posZ", "flip", "makeQuads",
             "merge", "close", "selectNew", "raycast", "wall", "offset", "points",
             "link", "linkKey", "sources", "order", "geometryPoints"]),
    // Plan 8646 (S5): every published pen attribute is an image attribute (D15,
    // captured R-all); S7a adds the operation context (offsets + descriptor).
    StepRow("mesh.topoPen", OpensAt.firstPress, false,
            ["middle", "mode", "loop", "slide", "smoothStrength", "showVertex",
             "showEdge", "innerSnap", "keepVertex", "range", "quadOnly", "backFace",
             "offsetX", "offsetY", "offsetZ", "stepKind", "stepVerts", "stepOrig"]),
    // Task 9525: Drag Weld is a topology-pen preset, the pen's image.
    StepRow("mesh.dragWeld", OpensAt.firstPress, false,
            ["middle", "mode", "loop", "slide", "smoothStrength", "showVertex",
             "showEdge", "innerSnap", "keepVertex", "range", "quadOnly", "backFace",
             "offsetX", "offsetY", "offsetZ", "stepKind", "stepVerts", "stepOrig"]),
];

unittest { // (4)
    auto manifest = parseJSON(readText("tools/prepared_writer_manifest.json"));
    string[string] moduleOf;
    foreach (p; manifest["products"].array)
        moduleOf[p["aggregate"].str] = p["module"].str;
    string[] stepIds, imageStepIds, paramArmIds;
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
        // Task 9430 (UND2, captured K-U2 PS-all): a parameter write is a step
        // in EVERY attribute-arm tool, by arm, never by id; never in a
        // session-less or history-recorded tool.
        if (pol.stepsParamWrites() && !pol.historyTopologySteps) paramArmIds ~= row.id;
        if (pol.historyRecordedSteps)
            assert(!pol.stepsParamWrites(),
                   "a history-recorded tool steps its parameter writes: " ~ row.id);
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
            if (row.id == "poly.extrude" || row.id == "mesh.radialArrayTool")
                assert(pol.haulAttrs == sr.imageAttrs, format(
                    "M3 step table: %s haul drifted from its full parameter image", row.id));
            // Wave plan 8640 S7a: the pen's haul is its operation context, the
            // six names a press resets and M-H keeps to the recording instance.
            if (row.id == "mesh.topoPen" || row.id == "mesh.dragWeld")
                assert(pol.haulAttrs == ["offsetX", "offsetY", "offsetZ", "stepKind",
                                         "stepVerts", "stepOrig"],
                    format("S7a step table: the pen's haul is %s", pol.haulAttrs));
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
    assert(recordedSteps == 50,   // 51 until Drag Weld became a pen preset (task 9525)
           format("history-owned rows %s, expected 50", recordedSteps));
    // No registered id is session-less (the M7 ceiling is 0): the session-less
    // policies are the base `Tool`'s default and the command-wrapper family's.
    assert(!ToolSessionPolicy.init.stepsParamWrites(),
           "UND2: a tool with the default (session-less) policy steps its parameter writes — "
           ~ "the panel would capture an attribute image for every row every frame");
    const wrapperPol = blit(TypeInfo_Class.find("tools.common.command_wrapper.CommandWrapperTool"))
        .sessionPolicy();
    assert(!wrapperPol.sessionSteps && !wrapperPol.stepsParamWrites(),
           "UND2: the command-wrapper family's session-less policy steps its parameter writes");
    sort(paramArmIds);
    assert(paramArmIds == ["edge.extend", "mesh.edgeSliceTool", "mesh.loopSliceTool",
                           "mesh.sliceTool", "pen", "poly.bevel"],
           format("UND2: the attribute arm (a parameter write is a step) is %s", paramArmIds));
    // Image-producing population floors: 21 ids, 175 image names, 3 Action triggers
    // on them (chainArm; insertAt, removeCurrent), 1 arm attribute (M3b).
    sort(imageStepIds);
    assert(imageStepIds == ["edge.bevel", "edge.extend", "edge.extrude",
                       "mesh.arrayTool", "mesh.clone", "mesh.dragWeld", "mesh.edgeSliceTool",
                       "mesh.loopSliceTool",
                       "mesh.mirrorTool", "mesh.polyInsetTool", "mesh.radialArrayTool",
                       "mesh.sliceTool", "mesh.smoothShiftTool",
                       "mesh.thickenTool", "mesh.topoPen", "mesh.vertexBevel", "mesh.vertexExtrude",
                       "pen", "poly.bevel", "poly.extrude", "vert.merge"],
           format("M3 step table: image-step ids %s", imageStepIds));
    assert(checkedNames == 175, format("M3 step table: %s image names checked, measured 175",
                                      checkedNames));
    assert(armAttrs == 1, format("M3b step table: %s arm attributes, measured 1", armAttrs));
    assert(actionNames == 3, format("M3 step table: %s Action params on the session tools, "
                                    ~ "measured 3", actionNames));
}

// ---------------------------------------------------------------------------
// (4b) Task 8920 (topology-redo wave S2a, law 1): the captured model is derived
// from policy DATA (`capturedTopologyModel`), the activation's carry from
// `opensAt` (`firstStepCarriesActivation`, read by `prepareArm`), the user
// arm's post mode from `postmodeStartsOnPressFor` (the app's arm path), and
// `armed` after a navigation is ONE assignment in `settleAfterNavigation_`.
// Order (form item 2): floor -> needles -> structural; the pin is block (5).
// ---------------------------------------------------------------------------

/// The model's ids, literal: the 15 history-topology ids less the pen and its
/// Drag Weld preset (task 9525).
private immutable string[] kModelIds = [
    "edge.bevel", "edge.extrude", "mesh.arrayTool", "mesh.clone", "mesh.mirrorTool",
    "mesh.polyInsetTool", "mesh.radialArrayTool", "mesh.smoothShiftTool",
    "mesh.thickenTool", "mesh.vertexBevel", "mesh.vertexExtrude", "poly.extrude",
    "vert.merge",
];

/// Word occurrences of `ident` in a code view, keyed by the enclosing
/// declaration (`enclosingSymbols`, line-start attribution); a declaration of
/// the name (`void x(`, `bool x`, `AttrImage x(` — S4) is keyed `<decl>`. `assignOnly`: only an
/// occurrence written to (`x =`, `x op=`, not `==`).
private string[] identSites(string code, string ident, bool assignOnly) {
    import tests.unit.census_symbols : enclosingSymbols, isIdentChar, symbolAt;
    const syms = enclosingSymbols(code);
    size_t[string] out_;
    size_t line0, from;
    for (;;) {
        const rel = code[from .. $].indexOf(ident);
        if (rel < 0) break;
        const pos = from + cast(size_t) rel;
        foreach (c; code[from .. pos]) if (c == '\n') ++line0;
        from = pos + ident.length;
        if ((pos > 0 && isIdentChar(code[pos - 1]))
            || (from < code.length && isIdentChar(code[from]))) continue;
        size_t b = pos;
        while (b > 0 && (code[b - 1] == ' ' || code[b - 1] == '\t')) --b;
        size_t a = b;
        while (a > 0 && isIdentChar(code[a - 1])) --a;
        const decl = ["void", "bool", "AttrImage", "DropImage"].canFind(code[a .. b]);
        if (assignOnly && !decl) {
            size_t e = from;
            while (e < code.length && code[e] == ' ') ++e;
            const op = e < code.length && "+-*/|&^~".canFind(code[e]) ? e + 1 : e;
            if (!(op < code.length && code[op] == '=' && !(op + 1 < code.length && code[op + 1] == '=')))
                continue;
        }
        const key = decl ? "<decl>" : symbolAt(syms, line0);
        out_[key] = out_.get(key, 0) + 1;
    }
    string[] r;
    foreach (k, n; out_) r ~= format("%s:%s", k, n);
    sort(r);
    return r;
}

unittest { // (4b)
    import tests.unit.production_tool_policies : productionPolicies;
    import tests.unit.census_symbols : blankUnittestBodies;
    // FLOOR: the production registry, every id built by its factory; the model
    // is exactly the 13 literal ids. Polarity: stationary (true from S2a on;
    // before S2a the predicate did not exist). The site sets below are
    // stationary ALLOWED sets, true after S2a (later slices edit their row);
    // the structural list is false before S2a (three ids opened at the press).
    size_t ids;
    auto rows = productionPolicies(ids);
    string[] model, armModel, topo, carries, onPress;
    foreach (row; rows) {
        if (row[1].startsWith("model")) model ~= row[0];
        if (row[1] == "model+arm") armModel ~= row[0];
        if (row[1].length) topo ~= row[0];
        if (row[2].length) carries ~= row[0];
        if (row[3].length) onPress ~= row[0];
    }
    sort(model); sort(armModel); sort(topo); sort(carries); sort(onPress);
    assert(ids == 71 && rows.length == 71,
           format("S2a model census: the production registry built %s ids, measured 71", ids));
    assert(model == kModelIds,
           format("S2a model census: capturedTopologyModel holds %s of the registry, the model "
                  ~ "is the 13 ids %s", model, kModelIds));

    // NEEDLES, by identifier. `prepareArm` derives the carry: one call of the
    // predicate, no read of the declared flag in any spelling (field read,
    // address, lambda; `.tupleof` / `__traits(getMember` / string `mixin(`
    // would reach it by a string the code view blanks, so those spellings are
    // counted too).
    auto ptRaw = readText("source/prepared_tool_transition.d");
    auto pt = blankUnittestBodies(blankNonCode(ptRaw));
    const arm = bodyAt(pt, "PreparedArm prepareArm(ToolFactory factory");
    assert(identSites(arm, "firstStepCarriesActivation", false).length == 1
           && identSites(arm, "firstStepCarriesActivation", false)[0].endsWith(":1")
           && identSites(arm, "recordCarriesActivation", false).length == 0
           && arm.count(".tupleof") == 0 && arm.count("getMember") == 0
           && arm.count("mixin(") == 0,
           "S2a needle: prepareArm must read firstStepCarriesActivation once and the declared "
           ~ "recordCarriesActivation never (a revert reddens HERE, before pin (5))");
    auto app = blankUnittestBodies(blankNonCode(readText("source/app.d")));
    assert(identSites(app, "postmodeStartsOnPressFor", false) == ["main.armPreparedTool:1"],
           format("S2a needle: app.d calls postmodeStartsOnPressFor at %s, expected once on the "
                  ~ "arm path (main.armPreparedTool)", identSites(app, "postmodeStartsOnPressFor", false)));
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    // Stationary allowed sets (true after S2a; S2b/S5b/S7 each edit their row).
    assert(identSites(es, "settleAfterNavigation_", false)
           == ["<decl>:1", "ToolSession.redo:1", "ToolSession.undo:1"],
           format("S2a needle: settleAfterNavigation_ sites %s, expected the declaration and "
                  ~ "one call in each of ToolSession.undo / ToolSession.redo",
                  identSites(es, "settleAfterNavigation_", false)));
    assert(identSites(es, "postmodeArmed_", true)
           == ["<decl>:1", "ToolSession.completeDropUndo:1", "ToolSession.endPendingOperation_:1", "ToolSession.noteArm:1",
               "ToolSession.notePointerDown:1", "ToolSession.recordBeginRow_:1",
               "ToolSession.settleAfterNavigation_:1"],
           format("S2a needle: postmodeArmed_ is written at %s, expected the field initializer "
                  ~ "and noteArm, notePointerDown, settleAfterNavigation_ once each, (S7, "
                  ~ "law 6; M-PS calls it) endPendingOperation_ and (S5b) the begin row",
                  identSites(es, "postmodeArmed_", true)));
    assert(identSites(es, "ownOpenerOnTop_", false)
           == ["<decl>:1", "ToolSession.settleAfterNavigation_:1"],
           format("S2a needle: ownOpenerOnTop_ sites %s, expected one call in "
                  ~ "settleAfterNavigation_", identSites(es, "ownOpenerOnTop_", false)));
    // The settle is gated on the captured model: the pen (outside it) keeps
    // its replay value. No pen suite reads the session's `armed` after a
    // navigation, so this needle is the gate's witness (mutation P1, card 8920).
    assert(identSites(bodyAt(es, "private bool boundModel_()"), "capturedTopologyModel", false)
           == ["(module scope):1"],
           "S2a needle: boundModel_ no longer gates on capturedTopologyModel");
    // The opener is asked with the token AFTER the step (the step re-binds the
    // tool and adopts its token): the argument is `aToken`, nothing taken before.
    const settle = bodyAt(es, "private void settleAfterNavigation_(bool isUndo)");
    const callAt = settle.indexOf("ownOpenerOnTop_(");
    assert(callAt >= 0, "S2a needle: settleAfterNavigation_ no longer asks ownOpenerOnTop_");
    const argFrom = callAt + "ownOpenerOnTop_(".length;
    const argTo = argFrom + settle[argFrom .. $].indexOf(")");
    assert(squeeze(settle[argFrom .. argTo]) == "aToken",
           "S2a needle: ownOpenerOnTop_ is asked with `" ~ settle[argFrom .. argTo]
           ~ "`, expected the post-step token aToken");
    // No raw field access in the session module (the multisets above see only
    // spelled names).
    assert(es.count(".tupleof") == 0 && es.count("getMember") == 0 && es.count("mixin(") == 0,
           "S2a needle: edit_session.d reaches a field by .tupleof / getMember / mixin");

    // STRUCTURAL: among the 15 history-topology ids exactly four open at the arm
    // (the pen and its Drag Weld preset are outside the model: `false`).
    assert(topo.length == 15,
           format("S2a structural: %s history-topology ids, measured 15", topo.length));
    assert(armModel == ["edge.bevel", "edge.extrude", "mesh.vertexBevel", "mesh.vertexExtrude"],
           format("S2a structural: opensAtArm among the model ids is %s", armModel));
    // The two derived answers over the whole registry: the 13 model ids (S5b: the
    // four arm-opening ones carry their begin row and are armed by it, not by the
    // activation), plus Edge Extend's declared carry / the declared on-press
    // transform id. Polarity: false before S5b (the four answered no), true after.
    string[] withExtend = ["edge.extend"] ~ kModelIds.dup, withRotate = kModelIds ~ ["rotate"];
    sort(withExtend); sort(withRotate);
    assert(carries == withExtend,
           format("S5b structural: firstStepCarriesActivation answers for %s", carries));
    assert(onPress == withRotate,
           format("S5b structural: postmodeStartsOnPressFor answers for %s", onPress));
}

// ---------------------------------------------------------------------------
// (4c) Task 8930 (topology-redo wave S2b): the step's origin and operation, the
// operation state (`operationOpen_`), the attribute-only row ("A"), the scripted
// write that ends the operation (M-PS), the panel write in a re-begun post mode
// (M-PR) and the one preview gate. Order (form item 2): floor -> needle ->
// structural; the pins are the compile-time `static assert`s after the block.
// ---------------------------------------------------------------------------

/// Whole-word occurrences of `ident` in `code`.
private size_t words(string code, string ident) {
    import tests.unit.census_symbols : isIdentChar;
    size_t n, from;
    for (;;) {
        const rel = code[from .. $].indexOf(ident);
        if (rel < 0) return n;
        const pos = from + cast(size_t) rel;
        from = pos + ident.length;
        if ((pos > 0 && isIdentChar(code[pos - 1]))
            || (from < code.length && isIdentChar(code[from]))) continue;
        ++n;
    }
}

/// RAW-text counts of the three spellings that reach a `private` member across
/// modules (form item 1): `.tupleof`, `__traits(getMember`, a string `mixin (`.
private size_t[3] rawBypass(string raw) {
    import tests.unit.census_symbols : isIdentChar;
    size_t mixins, from;
    for (;;) {
        const rel = raw[from .. $].indexOf("mixin");
        if (rel < 0) break;
        const pos = from + cast(size_t) rel;
        from = pos + 5;
        if (pos > 0 && isIdentChar(raw[pos - 1])) continue;
        size_t e = from;
        while (e < raw.length && (raw[e] == ' ' || raw[e] == '\t' || raw[e] == '\n')) ++e;
        if (e < raw.length && raw[e] == '(') ++mixins;
    }
    return [raw.count(".tupleof"), raw.count("__traits(getMember"), mixins];
}

/// The `if (...)` condition that directly guards the statement at `pos` (the
/// last `if (` before it whose closing parenthesis is followed only by blanks,
/// or the block's opening brace, up to `pos`), or null.
private string guardOf(string code, size_t pos) {
    const at = code[0 .. pos].lastIndexOf("if (");
    if (at < 0) return null;
    size_t i = cast(size_t) at + 3, depth;
    const open = i;
    for (; i < pos; ++i) {
        if (code[i] == '(') ++depth;
        else if (code[i] == ')' && --depth == 0) break;
    }
    const between = code[i + 1 .. pos].strip;
    if (i >= pos || (between.length && between != "{")) return null;
    return code[open + 1 .. i];
}

unittest { // (4c)
    import std.file : dirEntries, SpanMode;
    import tests.unit.production_tool_policies : productionPolicies;
    import tests.unit.census_symbols : blankUnittestBodies;
    // FLOOR: the production registry's 71 ids, the model's 13; and the raw scan
    // reaches the whole source tree (>= 574 files: other waves add files) with
    // the session module among them. Polarity: stationary.
    size_t ids;
    auto rows = productionPolicies(ids);
    string[] model;
    foreach (row; rows) if (row[1].startsWith("model")) model ~= row[0];
    sort(model);
    assert(ids == 71 && model == kModelIds,
           format("S2b floor: the production registry built %s ids, model %s", ids, model));
    string[] raw;
    size_t scanned;
    bool sessionScanned;
    foreach (e; dirEntries("source", "*.d", SpanMode.depth)) {
        ++scanned;
        const name = e.name;
        if (name == "source/edit_session.d") sessionScanned = true;
        const c = rawBypass(readText(name));
        if (c[0] + c[1] + c[2])
            raw ~= format("raw:%s:%s/%s/%s", name, c[0], c[1], c[2]);
    }
    assert(scanned >= 574 && sessionScanned,
           format("S2b floor: the raw scan read %s files of source/ (floor 574), session module "
                  ~ "read: %s", scanned, sessionScanned));

    // NEEDLE — ONE multiset, by identifier (form items 1-3): the writes of the
    // operation state, by body, and the raw bypass spellings, by file. Polarity:
    // the assignment rows are an allowed set true after S2b (S5b/S7 edit their
    // row); the raw keys are true before AND after (a bypass in any file — the
    // session module first — reddens its own `raw:` key).
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    string[] needle = raw.dup;
    foreach (f; ["operationOpen_", "postmodeArmed_", "topologyPendingAttrOnly_"])
        foreach (site; identSites(es, f, true)) needle ~= f ~ "=" ~ site;
    sort(needle);
    enum string[] kNeedle = [
        "operationOpen_=<decl>:1", "operationOpen_=ToolSession.completeDropUndo:1", "operationOpen_=ToolSession.endPendingOperation_:1",
        "operationOpen_=ToolSession.noteArm:1",
        "operationOpen_=ToolSession.settleAfterNavigation_:1", "operationOpen_=ToolSession.stepEnds:1",
        "postmodeArmed_=<decl>:1", "postmodeArmed_=ToolSession.completeDropUndo:1", "postmodeArmed_=ToolSession.endPendingOperation_:1",
        "postmodeArmed_=ToolSession.noteArm:1", "postmodeArmed_=ToolSession.notePointerDown:1",
        "postmodeArmed_=ToolSession.recordBeginRow_:1",
        "postmodeArmed_=ToolSession.settleAfterNavigation_:1",
        "raw:source/commands/mesh/surface_attr.d:0/4/0",
        "raw:source/create_tool_registration.d:0/1/0", "raw:source/document.d:0/1/0",
        "raw:source/edit_tool_registration.d:0/1/0", "raw:source/http_json.d:2/0/0",
        "raw:source/http_providers.d:1/0/0", "raw:source/http_server.d:4/1/0",
        "raw:source/io/native.d:4/9/0", "raw:source/mesh.d:17/0/2",
        "raw:source/mesh_edit_delta.d:1/2/0", "raw:source/mesh_planes.d:11/21/1",
        "raw:source/perf_probe.d:0/5/0", "raw:source/prefs.d:17/0/0", "raw:source/snapshot.d:2/0/0",
        "raw:source/toolpipe/packets.d:4/0/0", "raw:source/tools/alignment/radial_sweep_tool.d:0/4/0",
        "raw:source/tools/edit/smooth_relax.d:0/0/1", "raw:source/tools/edit/topology_pen/tool.d:0/3/0",
        "raw:source/tools/transform/xfrm_transform.d:0/1/0", "raw:source/web_gl_loader.d:0/2/0",
        "topologyPendingAttrOnly_=<decl>:1", "topologyPendingAttrOnly_=ToolSession.stepBegins:1",
    ];
    assert(needle == kNeedle,
           format("S2b needle: the operation-state writes / raw bypass keys moved — extra %s, missing %s",
                  needle.filter!(n => !kNeedle.canFind(n)).array,
                  kNeedle.filter!(n => !needle.canFind(n)).array));
    // The rest of the needle, by identifier. Each read is of a body the floor
    // above makes non-empty (form item 4: the complement needs its area).
    const steB = bodyAt(es, "void stepBegins(Tool t, PressKind kind");
    const steE = bodyAt(es, "void stepEnds(Tool t, bool ifChanged)");
    const arm = bodyAt(es, "void noteArm(string id, ulong token, bool postmodeArmed");
    const psw = bodyAt(es, "void scriptedWriteEndsOperation(Tool t)");
    foreach (b; [steB, steE, arm, psw])
        assert(squeeze(b).length > 2, "S2b needle: a ToolSession body the needle reads is empty");
    // (a) "A" decides by the armed post mode, never by the open operation; the
    // two branch choices read it, and `topologyDormant_` stands only on its
    // right-hand side (the dormant pair of `undoImpl_` is S6's).
    const aAt = steB.indexOf("topologyPendingAttrOnly_ =");
    const aRhs = steB[aAt .. aAt + steB[aAt .. $].indexOf(";")];
    assert(words(aRhs, "postmodeArmed_") == 1 && words(aRhs, "operationOpen_") == 0
           && words(aRhs, "press") == 1 && words(aRhs, "capturedTopologyModel") == 1,
           "S2b needle: the attribute-only predicate is not `dormant || (model && !press && "
           ~ "!postmodeArmed_)`: " ~ squeeze(aRhs));
    assert(words(steB, "topologyDormant_") == 1 && words(aRhs, "topologyDormant_") == 1
           && words(steE, "topologyDormant_") == 0
           && words(steB, "topologyPendingAttrOnly_") == 2 && words(steE, "topologyPendingAttrOnly_") == 1,
           "S2b needle: stepBegins/stepEnds choose a branch by topologyDormant_ again");
    // (b) the M-PR write keeps the operation closed: `prWrite` guards the tail
    // assignment of stepEnds (the inserted `operationOpen_ = true` in the PR
    // branch is mutation M-PR, a fixture cell).
    const oAt = steE.indexOf("operationOpen_ =");
    assert(oAt >= 0 && words(guardOf(steE, cast(size_t) oAt), "prWrite") == 1,
           "S2b needle: the operationOpen_ assignment of stepEnds is not guarded by prWrite");
    // (c) the token's operation is written outside any history-state condition.
    const nAt = arm.indexOf("operationOpen_ =");
    assert(nAt >= 0 && guardOf(arm, cast(size_t) nAt) is null,
           "S2b needle: noteArm writes operationOpen_ under a condition");
    {
        size_t depth;
        foreach (ch; arm[0 .. nAt]) { if (ch == '{') ++depth; else if (ch == '}') --depth; }
        assert(depth == 1, format("S2b needle: noteArm's operationOpen_ write sits %s blocks deep "
                                  ~ "(a condition on UndoState.Suspend would enclose it)", depth - 1));
    }
    // (d) M-PS gates on the armed post mode (S7: its end of the operation is the
    // law-6 helper's call — probe edit, form item 10).
    assert(psw.indexOf("endPendingOperation_(") >= 0
           && words(guardOf(psw, cast(size_t) psw.indexOf("endPendingOperation_(")),
                    "postmodeArmed_") == 1,
           "S2b needle: scriptedWriteEndsOperation no longer gates on postmodeArmed_");
    // (e) close / RMB never write the operation (model §1.3); their bodies exist.
    foreach (marker; ["private void endOperation_()", "CloseOutcome close(CloseReason r",
                      "bool closeOwn(Tool t, bool commit)"]) {
        const b = bodyAt(es, marker);
        assert(squeeze(b).length > 2 && words(b, "operationOpen_") == 0,
               "S2b needle: " ~ marker ~ " touches operationOpen_ (or is empty)");
    }
    // (f) the M-PR rule has no navigation-path term (R7): no `isUndo` / `navBefore_`.
    assert(words(steE, "isUndo") == 0 && words(steE, "navBefore_") == 0,
           "S2b needle: stepEnds reads isUndo / navBefore_ (a re-begin path term)");
    // (g) one production call of setTopologyStep, eight arguments.
    const callAt = steE.indexOf("cmd.setTopologyStep(");
    assert(words(es, "setTopologyStep") == 1 && callAt >= 0, "S2b needle: setTopologyStep calls moved");
    {
        size_t i = cast(size_t) callAt + "cmd.setTopologyStep(".length, depth = 1, commas;
        for (; depth; ++i) {
            if (steE[i] == '(') ++depth;
            else if (steE[i] == ')') --depth;
            else if (steE[i] == ',' && depth == 1) ++commas;
        }
        assert(commas == 7, format("S2b needle: setTopologyStep is called with %s arguments, expected 8",
                                   commas + 1));
    }
    // (h) the scripted write's one caller is the ScriptedValue arm of
    // orchestrateParameterChange; the preview gate's link is set at the arm only;
    // the one tool reading the gate in S2b is Mirror's evaluate (S6: 12 sites).
    string[] mps;
    foreach (e; dirEntries("source", "*.d", SpanMode.depth)) {
        auto code = blankUnittestBodies(blankNonCode(readText(e.name)));
        foreach (site; identSites(code, "scriptedWriteEndsOperation", false))
            mps ~= e.name ~ ":" ~ site;
    }
    sort(mps);
    assert(mps == ["source/edit_session.d:<decl>:1",
                   "source/edit_session.d:EditSession.orchestrateParameterChange:1"],
           format("S2b needle: scriptedWriteEndsOperation sites %s", mps));
    const scripted = bodyAt(bodyAt(es, "void orchestrateParameterChange(ParamProvider provider"),
                            "case ParameterChangeSource.ScriptedValue:");
    assert(words(scripted, "scriptedWriteEndsOperation") == 1,
           "S2b needle: the scripted write ends the operation outside the ScriptedValue arm");
    // noteArm names it twice: the link field and the method's address.
    assert(identSites(es, "previewGated", false)
           == ["<decl>:1", "ToolSession.noteArm:2"]
           && squeeze(es).count("link.previewGated=") == 1
           && squeeze(arm).canFind("link.previewGated=&previewGated;"),
           format("S2b needle: previewGated sites in edit_session.d %s",
                  identSites(es, "previewGated", false)));
    string[] gates;
    foreach (e; dirEntries("source/tools", "*.d", SpanMode.depth)) {
        auto code = blankUnittestBodies(blankNonCode(readText(e.name)));
        foreach (site; identSites(code, "previewGated", false)) gates ~= site;
    }
    sort(gates);
    // Polarity: the allowed set, true after S6 (task 9080; S2b: Mirror's evaluate alone).
    // A gate line struck narrows the list to the other eleven; its tool's
    // `<tool>-dormant/held` suite cell reddens too (VertexMerge, RadialArray: this list
    // alone — no rig of theirs moves the mesh mid-haul, S6 drill).
    assert(gates == ["ArrayTool.rebuildPreview:1", "CloneTool.rebuildPreview:1",
                     "EdgeBevelTool.rebuildPreview:1", "EdgeExtrudeTool.rebuildPreview:1",
                     "MirrorTool.evaluate:1", "PolyExtrudeTool.rebuildPreview:1",
                     "PolyInsetTool.rebuildPreview:1", "RadialArrayTool.rebuildPreview:1",
                     "SmoothShiftTool.rebuildPreview:1", "VertexBevelTool.rebuildPreview:1",
                     "VertexExtrudeTool.rebuildPreview:1", "VertexMergeTool.rebuildPreview:1"],
           format("S6 needle: previewGated is read in source/tools at %s, expected the eleven "
                  ~ "rebuildPreview bodies and MirrorTool.evaluate once each", gates));

    // STRUCTURAL: the origin is published only for a classified row.
    auto hp = blankUnittestBodies(blankNonCode(readText("source/http_providers.d")));
    const enc = squeeze(bodyAt(hp, "private JSONValue encodeHistoryRow("));
    assert(enc.canFind("if(step.stepOrigin()!=StepOrigin.unclassified){"),
           "S2b structural: encodeHistoryRow publishes stepOrigin for an unclassified row");
}

// Pins (form item 1; the lists are the compiled probe's, 2026-10-02).
static assert([__traits(allMembers, imported!"tool".StepOrigin)]
              == ["unclassified", "refire", "opens", "restart"]);
static assert(imported!"tool".StepOrigin.init == imported!"tool".StepOrigin.unclassified);
static assert([__traits(allMembers, imported!"tool".ToolSessionLink)]
              == ["stepBegins", "stepEnds", "operationArmed", "operationEnded", "closeOwn",
                  "recordCompleted", "tagPreparedCompleted", "recordToken", "stepOpenImage",
                  "previewGated", "pressActivation"]);
static assert([__traits(allMembers, imported!"tool".PressActivation)]
              == ["unbound", "activates", "active"]);
static assert(imported!"tool".PressActivation.init == imported!"tool".PressActivation.unbound);

// ---------------------------------------------------------------------------
// (4d) Task 8950 (topology-redo wave S3, law 2; model doc §R6.2): a row keeps its
// operation's base; the base of a NEW operation is set where an operation ends
// with the tool bound (`ToolSession.rebaseOnCurrent_`: the settle after a
// navigation, a scripted write) and rebased on the opening press only when it
// went stale (`notePointerDown`). The per-tool flag that rebased after every
// record is gone; a tool's restore body is its attributes, then its rebase body.
// Order (form item 2): floor -> needle -> structural; the pins follow.
// ---------------------------------------------------------------------------

/// The 12 classes of the captured model (the pen is outside it), by file: the
/// file declaring each `restoreTopologyStep` body the census reads.
private enum string[] kRebaseBodyFiles = [
    "source/tools/alignment/array_tool.d", "source/tools/alignment/clone_tool.d",
    "source/tools/alignment/mirror.d", "source/tools/alignment/radial_array_tool.d",
    "source/tools/deform/smooth_shift_tool.d", "source/tools/edit/edge_bevel.d",
    "source/tools/edit/edge_extrude.d", "source/tools/edit/poly_extrude.d",
    "source/tools/edit/poly_inset_tool.d", "source/tools/edit/vert_merge_tool.d",
    "source/tools/edit/vertex_bevel_tool.d", "source/tools/edit/vertex_extrude_tool.d",
];

unittest { // (4d)
    import tests.unit.census_symbols : blankUnittestBodies;
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    const ts = bodyAt(es, "private struct ToolSession");   // EditSession forwards a notePointerDown
    // FLOOR: the bodies the needle reads exist (form item 4).
    foreach (marker; ["private void rebaseOnCurrent_(Tool t, bool ifStale)",
                      "private void settleAfterNavigation_(bool isUndo)", "void notePointerDown()",
                      "void scriptedWriteEndsOperation(Tool t)",
                      "private void rebaseOnUndoneOperation_(Tool t, ulong tok)"])
        assert(squeeze(bodyAt(ts, marker)).length > 2, "S3 floor: the session body " ~ marker
               ~ " is empty");
    // NEEDLE, by identifier (a method address and both lambda forms count).
    // Polarity: allowed sets, true after S3 (S7 adds `close:1` to the second; S7 PF-7 the
    // undone restart's base and S7 (6) the navigation tail — probe edits, form item 10).
    assert(identSites(es, "rebaseTopologyStep", false)
           == ["ToolSession.rebaseAfterTail_:1", "ToolSession.rebaseOnCurrent_:1",
               "ToolSession.rebaseOnUndoneOperation_:1"],
           format("S3 needle: edit_session.d rebases a tool at %s, expected only in "
                  ~ "rebaseOnCurrent_, (S7, PF-7) rebaseOnUndoneOperation_ and (S7 (6)) "
                  ~ "rebaseAfterTail_", identSites(es, "rebaseTopologyStep", false)));
    // S7 PF-7 (plan §14.3): the undone restart's base is set by the settle of an undo
    // alone, inside its open-operation branch. Polarity: true after S7 (the name is new).
    assert(identSites(es, "rebaseOnUndoneOperation_", false)
           == ["<decl>:1", "ToolSession.settleAfterNavigation_:1"],
           format("S7 needle: rebaseOnUndoneOperation_ is called at %s, expected the settle once",
                  identSites(es, "rebaseOnUndoneOperation_", false)));
    assert(squeeze(bodyAt(ts, "private void settleAfterNavigation_(bool isUndo)"))
              .canFind("if(operationOpen_){operation_=isUndo?headOfRedoOperation_(aToken):"
                       ~ "topOperation_(aToken);"
                       ~ "if(isUndo)rebaseOnUndoneOperation_(tool_(),aToken);}"),
           "S7 needle: the settle rebases an undone restart outside its open, undo branch");
    assert(identSites(es, "rebaseOnCurrent_", false)
           == ["<decl>:1", "ToolSession.close:1", "ToolSession.notePointerDown:1",
               "ToolSession.scriptedWriteEndsOperation:1", "ToolSession.settleAfterNavigation_:1"],
           format("S3 needle: rebaseOnCurrent_ is called at %s, expected the settle after a "
                  ~ "navigation, the scripted write, the opening press and (S7, C2) the command "
                  ~ "close once each",
                  identSites(es, "rebaseOnCurrent_", false)));
    // the helper is gated on the captured model (§4.6: the pen's
    // rebase body is never reached) and the press asks for the stale case only
    const helper = squeeze(bodyAt(ts, "private void rebaseOnCurrent_(Tool t, bool ifStale)"));
    assert(helper.canFind("if(tisnull||!reporting_(t)||!capturedTopologyModel(t.sessionPolicy()))return;")
           && helper.canFind("if(ifStale&&baseImage_.filled&&baseImage_.matches(*m))return;"),
           "S3 needle: rebaseOnCurrent_ lost its model gate or its stale test: " ~ helper);
    assert(squeeze(bodyAt(ts, "void notePointerDown()")).canFind("if(!operationOpen_)rebaseOnCurrent_(tool_(),true);")
           && squeeze(bodyAt(ts, "private void settleAfterNavigation_(bool isUndo)"))
              .canFind("if(aModel&&!operationOpen_)rebaseOnCurrent_(tool_(),false);"),
           "S3 needle: the press or the settle rebases inside an open operation");

    // STRUCTURAL: the restore body of the model's 12 classes is its attributes, then
    // its rebase body — nothing else (the former Thicken reset was dead after S3). Since
    // task 9429 it is ONE body, the client mixin's, which every model file composes.
    enum restoreMarker = "void restoreTopologyStep(in AttrImage attrs, MeshSnapshot basis)";
    const home = blankNonCode(readText("source/tools/topology_step.d"));
    assert(home.count(restoreMarker) == 1, "S3 structural: the client mixin's restore body is gone");
    assert(squeeze(bodyAt(home, restoreMarker))
           == "{restoreRecordedAttrs(attrs);rebaseTopologyStep(basis);}",
           "S3 structural: the client mixin's restore body is " ~ squeeze(bodyAt(home, restoreMarker)));
    size_t bodies;
    foreach (f; kRebaseBodyFiles) {
        const c = blankNonCode(readText(f));
        assert(c.count(restoreMarker) == 0 && c.count("mixin TopologyStepClientBody!") == 1,
               "S3 structural: " ~ f ~ " declares its own restore body or lost the client mixin");
        ++bodies;
    }
    assert(bodies == 12, format("S3 structural: model files composing the restore body: %s read, "
                                ~ "12 expected", bodies));
}

// ---------------------------------------------------------------------------
// (4e) Task 9080 (topology-redo wave S6, law 5; model doc §3 E3, §1.1): every tool of
// the captured model goes dormant after a fully redone closed run (no per-tool flag);
// its preview gate is the session's (`previewGated()`, the second statement of each
// `rebuildPreview` after the `!active` guard; Mirror's in `evaluate`, S2b); the pair of
// a UI arm and its attribute-only row is one undo/redo step by the ROW's class, not by
// dormancy. Order (form item 2): floor -> needle -> structural; the fence follows.
// ---------------------------------------------------------------------------
unittest { // (4e)
    import std.file : dirEntries, readText, SpanMode;
    import tests.unit.census_symbols : blankUnittestBodies;
    // FLOOR (form item 4): the model's classes, found by the rule «a class in source
    // composing the topology-step client mixin» (task 9429; the pen keeps its own
    // block) — 12, the table's files.
    string[] model;
    foreach (e; dirEntries("source", "*.d", SpanMode.depth))
        if (blankNonCode(readText(e.name)).canFind("mixin TopologyStepClientBody!"))
            model ~= e.name;
    sort(model);
    assert(model == kRebaseBodyFiles.dup.sort.array, format("S6 floor: the captured model's "
           ~ "files are %s, the table %s", model, kRebaseBodyFiles));
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    const ts = bodyAt(es, "private struct ToolSession");
    foreach (m; ["private bool undoImpl_()", "private bool redoImpl_()",
                 "private bool attrRowJoinsActivation_()", "void notePointerDown()"])
        assert(squeeze(bodyAt(ts, m)).length > 2, "S6 floor: the session body " ~ m ~ " is empty");

    // NEEDLES (stationary allowed sets, true after S6). The dormant arm is the model's;
    // the pair is by the row's class; a dormant press does not arm the post mode.
    const arm = squeeze(bodyAt(ts, "void noteArm(string id, ulong token, bool postmodeArmed = true)"));
    // S6r (9270, probe edit, form item 10): every dormant arm takes the closed run's copy;
    // an arm-opening tool's activation then writes its reset over it (the §18.2 term is gone).
    assert(arm.canFind("topologyDormant_=capturedTopologyModel(t.sessionPolicy())&&")
           && arm.canFind("if(topologyDormant_&&ownedAttrs.empty)ownedAttrs=closedAttrs;"),
           "S6 needle: noteArm's dormant term is not the captured model's, or a dormant arm "
           ~ "does not take the closed run's copy (S6r: the §18.2 term returned?): " ~ arm);
    assert(identSites(es, "attrRowJoinsActivation_", false)
           == ["<decl>:1", "ToolSession.undoImpl_:1"],
           format("S6 needle: the UI pair of an attribute-only row is read at %s",
                  identSites(es, "attrRowJoinsActivation_", false)));
    const und = bodyAt(ts, "private bool undoImpl_()");
    const join_ = squeeze(bodyAt(ts, "private bool attrRowJoinsActivation_()"));
    assert(words(und, "topologyDormant_") == 0 && join_.canFind("act.joinsFirstGroup()")
           && join_.canFind("cast(constTopologyAdjustmentEdit)ue[$-1].cmd!isnull")
           && words(join_, "topologyDormant_") == 0,
           "S6 needle: the undo pair of a UI arm and its attribute-only row is keyed on "
           ~ "dormancy, or lost the row's class or the door: " ~ join_);
    const red = squeeze(bodyAt(ts, "private bool redoImpl_()"));
    const ap = red.indexOf("attrPair=act!isnull");
    assert(ap >= 0 && red[ap .. ap + red[ap .. $].indexOf(";")].canFind("act.joinsFirstGroup()")
           && red[ap .. ap + red[ap .. $].indexOf(";")].canFind("cast(constTopologyAdjustmentEdit)re[1].cmd!isnull")
           && !red[ap .. ap + red[ap .. $].indexOf(";")].canFind("dormantTopology()")
           && red.canFind("if(ok&&attrPair)history_.redo();")
           && red.canFind("pair=!attrPair&&"),
           "S6 needle: the redo pair of a UI arm and its attribute-only row is keyed on "
           ~ "dormancy, lost the row's class, or the arm pair takes it");
    assert(squeeze(bodyAt(ts, "void notePointerDown()")).canFind("if(!topologyDormant_)postmodeArmed_=true;"),
           "S6 needle: a dormant press arms the post mode (law 5, E3)");
    assert(identSites(es, "dormantActivation_", false).length == 0,
           "S6 needle: the dormant activation cursor is back (the pair reads the row's class)");

    // STRUCTURAL: in the eleven `rebuildPreview` bodies the gate is the statement right
    // after the leading `!active` guard; the extrudes' former field gate is gone.
    size_t bodies;
    foreach (f; kRebaseBodyFiles) {
        if (f.endsWith("mirror.d")) continue;
        const b = squeeze(bodyAt(blankNonCode(readText(f)), "void rebuildPreview("));
        const g = b.indexOf(";");
        assert(b.length > 2 && g > 0 && b[0 .. 4] == "{if(" && words(b[0 .. g], "active") == 1
               && b[g + 1 .. $].startsWith("if(previewGated())return;"),
               format("S6 structural: %s's rebuildPreview does not open with the !active guard "
                      ~ "and then the preview gate: %s", f, b[0 .. b.length < 80 ? b.length : 80]));
        ++bodies;
    }
    assert(bodies == 11, format("S6 structural: %s rebuildPreview bodies read, 11 expected", bodies));
    const poly = blankNonCode(readText("source/tools/edit/poly_extrude.d"));
    const edge = blankNonCode(readText("source/tools/edit/edge_extrude.d"));
    assert(words(poly, "topologyDormant") == 3 && words(edge, "topologyDormant") == 0,
           format("S6 structural: the extrudes name the tool's dormant field %s / %s times, "
                  ~ "measured 3 (declaration, setter, press extent) / 0",
                  words(poly, "topologyDormant"), words(edge, "topologyDormant")));
}

// ---------------------------------------------------------------------------
// (4f) Task 9120 (topology-redo wave S7, law 6; model doc §3 «Закрытие»): the end of an
// operation — a switch, a drop, a recording command, a restart, a scripted write — is ONE
// helper, `endPendingOperation_`, folding the rows of the operation of the session's top
// step into one undo step (`foldOperationRows_`, keyed on the row's operation), or — for
// the pen, outside the model — its own open-step walk (`foldOpenRows_`). Absorbs the
// StepOwner wave's S2 (`finishOpenBlock_`) and closes 8793 (one call site of the pen's
// walk). Order (form item 2): floor -> needle -> structural. The raw bypass spellings are
// the (4c) needle's keys (held, not re-introduced).
// ---------------------------------------------------------------------------
unittest { // (4f)
    import tests.unit.census_symbols : blankUnittestBodies;
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    const ts = bodyAt(es, "private struct ToolSession");
    // FLOOR (form item 4): the producer and consumer bodies the needles read exist.
    foreach (m; ["private void endPendingOperation_(const Command trigger, bool endsPostMode, "
                 ~ "bool model)",
                 "private void foldOperationRows_(const Command trigger)",
                 "private void foldOpenRows_(const Command trigger)",
                 "CloseOutcome close(CloseReason r",
                 "private void noteFoldRow_(Tool t, MeshSessionEdit cmd)",
                 "void stepEnds(Tool t, bool ifChanged)",
                 "void scriptedWriteEndsOperation(Tool t)"])
        assert(squeeze(bodyAt(ts, m)).length > 2, "S7 floor: the session body " ~ m ~ " is empty");
    // NEEDLES, by identifier (a method address and both lambda forms count). Polarity:
    // stationary allowed sets, true after S7; false before (the pen's walk had three
    // callers — close twice, noteFoldRow_ — and the other two names did not exist).
    assert(identSites(es, "foldOpenRows_", false)
           == ["<decl>:1", "ToolSession.endPendingOperation_:1"],
           format("S7 needle: the pen's open-step walk is called at %s, expected only by "
                  ~ "endPendingOperation_", identSites(es, "foldOpenRows_", false)));
    assert(identSites(es, "foldOperationRows_", false)
           == ["<decl>:1", "ToolSession.endPendingOperation_:1"],
           format("S7 needle: the operation fold is called at %s, expected only by "
                  ~ "endPendingOperation_", identSites(es, "foldOperationRows_", false)));
    assert(identSites(es, "endPendingOperation_", false)
           == ["<decl>:1", "ToolSession.close:2", "ToolSession.noteFoldRow_:1",
               "ToolSession.scriptedWriteEndsOperation:1", "ToolSession.stepEnds:1"],
           format("S7 needle: the end of an operation is called at %s, expected close (switch/"
                  ~ "drop and command), the pen's press, a restart and a scripted write",
                  identSites(es, "endPendingOperation_", false)));
    // STRUCTURAL: the fold is keyed on the row's operation, never its origin; a restart
    // folds below its own row and keeps the post mode; the pen's press keeps its walk.
    const fold = bodyAt(ts, "private void foldOperationRows_(const Command trigger)");
    assert(words(fold, "stepOperation") == 2 && words(fold, "stepOrigin") == 0
           && words(fold, "JoinsBelow") == 1,
           "S7 structural: foldOperationRows_ does not group by the row's operation: "
           ~ squeeze(fold));
    assert(squeeze(bodyAt(ts, "void stepEnds(Tool t, bool ifChanged)"))
              .canFind("if(origin==StepOrigin.restart)endPendingOperation_(cmd,false,true);")
           && squeeze(bodyAt(ts, "private void noteFoldRow_(Tool t, MeshSessionEdit cmd)"))
              .canFind("endPendingOperation_(cmd,false,false);openBlock_=cmd;")
           && squeeze(bodyAt(ts, "void scriptedWriteEndsOperation(Tool t)"))
              .canFind("endPendingOperation_(null,true,true);"),
           "S7 structural: a restart, the pen's press or the scripted write calls the helper "
           ~ "with other arguments");
    // §15 (capture 8980): the command close ends the operation, THEN rebases the tool on the
    // live image, BEFORE the idle test — an idle model tool is not committed (attrs kept).
    inOrder(squeeze(bodyAt(ts, "CloseOutcome close(CloseReason r")),
            ["constboolcommand=r==CloseReason.command;",
             "endPendingOperation_(null,true,model);rebaseOnCurrent_(t,false);",
             "if(cc==CommandClose.uiDoor&&!t.hasUncommittedEdit()){",
             "returnCloseOutcome(false,true);}",
             "constcommitted=t.commitOperation();"], "S7 ToolSession.close");
}

// (4g) Task 9120 (S7, PF-3; plan §13, Capture-7 N6C): the undo of another tool's UI pair
// hands the restored predecessor its own session token on BOTH undo paths — the generic
// tail and the topology pair branch. Order: floor -> needle.
unittest { // (4g)
    import tests.unit.census_symbols : blankUnittestBodies;
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    const ts = bodyAt(es, "private struct ToolSession");
    foreach (m; ["private bool undoImpl_()", "private bool navigateTopology_(bool isUndo)",
                 "private void adoptPredecessorToken_(const Command undone)",
                 "private void restorePredecessor_(const Command undone, AttrImage remembered)"])
        assert(squeeze(bodyAt(ts, m)).length > 2,
               "PF-3 floor: the session body " ~ m ~ " is empty");
    // Polarity: false before S7 (the tail alone), true after. S7 (7) (plan §19.3): the adopt
    // moved into `restorePredecessor_` (probe edit, form item 10), which both paths call.
    assert(identSites(es, "adoptPredecessorToken_", false)
           == ["<decl>:1", "ToolSession.restorePredecessor_:1"],
           format("PF-3 needle: adoptPredecessorToken_ is called at %s, expected only by "
                  ~ "restorePredecessor_", identSites(es, "adoptPredecessorToken_", false)));
    assert(identSites(es, "restorePredecessor_", false)
           == ["<decl>:1", "ToolSession.navigateTopology_:1", "ToolSession.undoImpl_:1"],
           format("PF-3 needle: restorePredecessor_ is called at %s, expected the undo tail "
                  ~ "and the pair branch of navigateTopology_ once each",
                  identSites(es, "restorePredecessor_", false)));
    // M-H on the pair: the predecessor's image is read BEFORE the activation's undo (its
    // replay arm rewrites the session's memory), the restore only after it succeeded.
    assert(squeeze(bodyAt(ts, "private bool navigateTopology_(bool isUndo)"))
              .canFind("autoimg=predecessorAttrs_(act);"
                       ~ "if(history_.undo())restorePredecessor_(act,img);"),
           "PF-3 needle: the pair branch reads the predecessor's image after the activation's "
           ~ "undo, or restores it before, or without, a successful undo");
}

// (4h) Task 9120 (S7 (6), plan §19.3, model §R11 M-nav): a navigation tail writes no
// attribute of a model tool — it re-bases it on the live mesh (`rebaseAfterTail_`); only
// the tools outside the model re-sync. Order: floor -> needle. Polarity: false before
// (the tails called `resyncSession()` themselves: `undoImpl_:1, redoImpl_:1`), true after.
unittest { // (4h)
    import tests.unit.census_symbols : blankUnittestBodies;
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    const ts = bodyAt(es, "private struct ToolSession");
    foreach (m; ["private bool undoImpl_()", "private bool redoImpl_()",
                 "private void rebaseAfterTail_(Tool t)"])
        assert(squeeze(bodyAt(ts, m)).length > 2,
               "S7 (6) floor: the session body " ~ m ~ " is empty");
    assert(identSites(es, "resyncSession", false)
           == ["ToolSession.applyAndContinue:1", "ToolSession.navigateRecorded_:1",
               "ToolSession.rebaseAfterTail_:1"],
           format("S7 (6) needle: resyncSession is called at %s, expected applyAndContinue, "
                  ~ "navigateRecorded_ and rebaseAfterTail_ once each (a tail calling it again "
                  ~ "zeroes a model tool's attributes, N1a/N1b)",
                  identSites(es, "resyncSession", false)));
    assert(identSites(es, "rebaseAfterTail_", false)
           == ["<decl>:1", "ToolSession.completeDropUndo:1", "ToolSession.redoImpl_:1", "ToolSession.undoImpl_:1"],
           format("S7 (6) needle: rebaseAfterTail_ is called at %s, expected the undo and the "
                  ~ "redo tail once each", identSites(es, "rebaseAfterTail_", false)));
    const helper = squeeze(bodyAt(ts, "private void rebaseAfterTail_(Tool t)"));
    assert(helper.canFind("if(capturedTopologyModel(t.sessionPolicy())&&m!isnull)"
                          ~ "stepClient_(t).rebaseTopologyStep(MeshSnapshot.capture(*m));"
                          ~ "elset.resyncSession();"),
           "S7 (6) needle: rebaseAfterTail_ is not `model -> rebase, else resync`: " ~ helper);
}

// (4i) Task 9210 (topology-redo wave S5b, owner decision В1; model doc §1.1): the tool
// pick and the operation start are two layers. An arm-opening tool's operation begins
// with a begin row of its own (`recordBeginRow_`, called by the arm alone — never under
// Suspend, never dormant), classified `opens` before the parameter-row branch and never
// an attribute-only row; the activation alone opens no post mode. Order (form item 2):
// floor -> needle. Polarity: false before S5b (none of the names existed; the opener test
// accepted the activation of an arm-opening tool), true after.
unittest { // (4i)
    import tests.unit.census_symbols : blankUnittestBodies;
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    const ts = bodyAt(es, "private struct ToolSession");
    foreach (m; ["void noteArm(string id, ulong token, bool postmodeArmed = true)",
                 "private void recordBeginRow_(Tool t)", "void stepBegins(Tool t, PressKind kind",
                 "void stepEnds(Tool t, bool ifChanged)", "private bool ownOpenerOnTop_(ulong tok)"])
        assert(squeeze(bodyAt(ts, m)).length > 2, "S5b floor: the session body " ~ m ~ " is empty");
    assert(identSites(es, "recordBeginRow_", false) == ["<decl>:1", "ToolSession.noteArm:1"],
           format("S5b needle: recordBeginRow_ is called at %s, expected the arm once",
                  identSites(es, "recordBeginRow_", false)));
    assert(identSites(es, "topologyPendingBegin_", true)
           == ["<decl>:1", "ToolSession.recordBeginRow_:2", "ToolSession.stepEnds:1"],
           format("S5b needle: topologyPendingBegin_ is written at %s, expected the begin row "
                  ~ "(raised, cleared after stepEnds on every exit) and stepEnds (cleared)",
                  identSites(es, "topologyPendingBegin_", true)));
    // the arm's call is guarded by the four terms: not a replay, the model, the arm opens, not dormant
    const arm = bodyAt(ts, "void noteArm(string id, ulong token, bool postmodeArmed = true)");
    const g = guardOf(arm, cast(size_t) arm.indexOf("recordBeginRow_("));
    assert(g !is null && words(g, "Suspend") == 1 && words(g, "capturedTopologyModel") == 1
           && words(g, "opensAtArm") == 1 && words(g, "topologyDormant_") == 1,
           "S5b needle: the begin row's guard in noteArm is `" ~ squeeze(g) ~ "`");
    // the attribute-only predicate excludes the begin row; stepEnds classifies it first
    const steB = bodyAt(ts, "void stepBegins(Tool t, PressKind kind");
    const aAt = steB.indexOf("topologyPendingAttrOnly_ =");
    assert(aAt >= 0 && words(steB[aAt .. aAt + steB[aAt .. $].indexOf(";")],
                             "topologyPendingBegin_") == 1,
           "S5b needle: the attribute-only predicate does not exclude the begin row");
    const steE = squeeze(bodyAt(ts, "void stepEnds(Tool t, bool ifChanged)"));
    const opensAt = steE.indexOf("if(begins)origin=StepOrigin.opens;elseif(topologyPendingPress_)");
    assert(opensAt >= 0 && opensAt < steE.indexOf("prWrite=!operationOpen_;"),
           "S5b needle: stepEnds does not classify the begin row `opens` before the press / "
           ~ "parameter-row branches");
    // the opener on top is a topology step of the session — never an activation
    const opener = bodyAt(ts, "private bool ownOpenerOnTop_(ulong tok)");
    assert(words(opener, "ToolActivationCommand") == 0 && words(opener, "opensAtArm") == 0,
           "S5b needle: ownOpenerOnTop_ accepts an activation again (the transitional term)");
}

// ---------------------------------------------------------------------------
// (4j) Task 9270 (topology-redo wave S6r, model doc §R12 M-init): an instance's activation is
// ONE datum (`instanceActive_`), ONE writer of `true` (`activate_`) called at two sites — the
// live arm of an arm-opening tool (`noteArm`, never a replay) and a press of the tool's own
// door that finds the instance inactive (`stepBegins`) — cleared at every bind and at a
// post-mode end (`endPendingOperation_`); what it writes is the class's DATA
// (`activationResetAttrs`). Order (form item 2): floor -> needle -> structural -> pin.
// Polarity: the needles are false before S6r (neither name existed), true after.
// ---------------------------------------------------------------------------

/// Captured: the attributes each model class's activation resets, with their defaults
/// (plan §20.2 table; findings §19-§20). An empty row: the class resets none.
private immutable string[2][string] kActivationReset;
shared static this() {
    kActivationReset = [
        "EdgeBevelTool":     ["width", "0"],
        "VertexBevelTool":   ["inset", "0"],
        "VertexExtrudeTool": ["shift,width", "0,0"],
        "EdgeExtrudeTool":   ["extrude,width", "0,0"],
        "SmoothShiftTool":   ["shift,scale", "0,1"],
        "VertexMergeTool":   ["dist", "0.001"],
        "MirrorTool":        ["center", "(0,0,0)"],
        "PolyExtrudeTool":   ["shiftX,shiftY,shiftZ,distance", "0,0,0,0"],
        "PolyInsetTool":     ["", ""], "ArrayTool": ["", ""],
        "CloneTool":         ["", ""], "RadialArrayTool": ["", ""],
    ];
}

unittest { // (4j)
    import tests.unit.census_symbols : blankUnittestBodies;
    import tests.unit.production_tool_policies : productionPolicies;
    import params : Param;
    import tool : capturedTopologyModel;
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    const ts = bodyAt(es, "private struct ToolSession");
    // FLOOR (form item 4): the bodies the needles read.
    foreach (m; ["void noteArm(string id, ulong token, bool postmodeArmed = true)",
                 "void stepBegins(Tool t, PressKind kind", "private void activate_(Tool t)",
                 "private void endPendingOperation_(const Command trigger, bool endsPostMode, "
                 ~ "bool model)"])
        assert(squeeze(bodyAt(ts, m)).length > 2, "S6r floor: the session body " ~ m ~ " is empty");
    // NEEDLES, by identifier (every spelling, a method address included).
    assert(identSites(es, "activate_", false)
           == ["<decl>:1", "ToolSession.noteArm:1", "ToolSession.stepBegins:1"],
           format("S6r needle: activate_ is called at %s, expected the live arm and the press "
                  ~ "once each", identSites(es, "activate_", false)));
    assert(identSites(es, "instanceActive_", true)
           == ["<decl>:1", "ToolSession.activate_:1", "ToolSession.endPendingOperation_:1",
               "ToolSession.noteArm:1"],
           format("S6r needle: instanceActive_ is written at %s, expected activate_ (true), the "
                  ~ "bind and the post-mode end (false) — a navigation clearing it is not "
                  ~ "captured (findings §21.4)", identSites(es, "instanceActive_", true)));
    assert(identSites(es, "instanceActive_", false)
           == ["<decl>:1", "ToolSession.activate_:1", "ToolSession.endPendingOperation_:1",
               "ToolSession.noteArm:1", "ToolSession.pressActivation_:1",
               "ToolSession.stepBegins:1"],
           format("S6r needle: instanceActive_ is read at %s, expected only by the press and "
                  ~ "the link the bind hands the tool (plan §23.9 item 5)",
                  identSites(es, "instanceActive_", false)));
    assert(squeeze(bodyAt(ts, "void noteArm(string id, ulong token, bool postmodeArmed = true)"))
               .canFind("link.pressActivation=&pressActivation_;"),
           "S6r needle: the bind does not hand the tool its instance's activation");
    assert(squeeze(bodyAt(ts, "private PressActivation pressActivation_(Tool t)"))
               .canFind("if(!reporting_(t))returnPressActivation.unbound;"),
           "S6r needle: pressActivation_ answers a tool that is not the reporting one");
    const tl = blankNonCode(readText("source/tool.d"));
    assert(identSites(tl, "resetParamToDefault", false)
           == ["<decl>:1", "Tool.resetAttrsToDefaults:1"],
           format("S6r needle: resetParamToDefault is called at %s, expected only by "
                  ~ "resetAttrsToDefaults", identSites(tl, "resetParamToDefault", false)));
    assert(identSites(es, "resetAttrsToDefaults", false) == ["ToolSession.activate_:1"],
           format("S6r needle: the session resets attributes at %s, expected only activate_",
                  identSites(es, "resetAttrsToDefaults", false)));
    // STRUCTURAL: the bind clears first; the live arm activates after the copy and before the
    // image is remembered and the begin row is taken; the press activates before the step's
    // `before`; the post-mode end clears.
    const arm = bodyAt(ts, "void noteArm(string id, ulong token, bool postmodeArmed = true)");
    inOrder(squeeze(arm), ["bound_=t;instanceActive_=false;", "if(tisnull)return;",
                           "t.restoreRecordedAttrs(ownedAttrs);", "activate_(t);",
                           "rememberTopologyAttrs_(t.captureAttrImage());", "recordBeginRow_(t);"],
            "S6r ToolSession.noteArm");
    const g = guardOf(arm, cast(size_t) arm.indexOf("activate_("));
    assert(g !is null && squeeze(g) == "history_.state()!=UndoState.Suspend&&opensAtArm(t.sessionPolicy())",
           "S6r needle: the live arm's activation is guarded by `" ~ squeeze(g) ~ "`, expected "
           ~ "not-a-replay and the arm-opening policy alone (dormant or not)");
    assert(squeeze(bodyAt(ts, "void stepBegins(Tool t, PressKind kind")).canFind(
               "if(t.sessionPolicy().historyTopologySteps){if(press&&!instanceActive_)activate_(t);"
               ~ "topologyPendingPress_=press;"),
           "S6r needle: the press's activation is not the first statement of the topology "
           ~ "branch, or it is keyed on more than `press && !instanceActive_`");
    assert(squeeze(bodyAt(ts, "private void endPendingOperation_(const Command trigger, "
               ~ "bool endsPostMode, bool model)")).canFind(
               "if(endsPostMode){postmodeArmed_=false;operationOpen_=false;instanceActive_=false;}"),
           "S6r needle: the end of the post mode does not deactivate the instance");
    assert(squeeze(bodyAt(ts, "private void activate_(Tool t)"))
           == "{instanceActive_=true;if(capturedTopologyModel(t.sessionPolicy()))"
              ~ "t.resetAttrsToDefaults(t.sessionPolicy().activationResetAttrs);}",
           "S6r needle: activate_ is not `raise the datum; a model tool resets its data`");

    // STRUCTURAL — the table, read off the PRODUCTION instances: each model class declares
    // the captured list, every name is one of its params, every default the captured one.
    size_t ids, modelIds;
    string[] seen, bad;
    size_t nonEmpty, empty;
    productionPolicies(ids, (string id, Tool t) {
        const pol = t.sessionPolicy();
        if (!capturedTopologyModel(pol)) return;
        ++modelIds;
        auto cls = typeid(t).name;
        cls = cls[cls.lastIndexOf('.') + 1 .. $];
        if (seen.canFind(cls)) return;
        seen ~= cls;
        auto want = cls in kActivationReset;
        if (want is null) { bad ~= cls ~ ": no captured row"; return; }
        string[] defs;
        foreach (n; pol.activationResetAttrs) {
            bool found;
            foreach (ref p; t.params()) {
                if (p.name != n) continue;
                found = true;
                defs ~= p.kind == Param.Kind.Vec3_
                    ? format("(%g,%g,%g)", p.default_.v3.x, p.default_.v3.y, p.default_.v3.z)
                    : format("%g", p.default_.f);
            }
            if (!found) bad ~= cls ~ ": '" ~ n ~ "' is no param";
        }
        if (pol.activationResetAttrs.join(",") != (*want)[0] || defs.join(",") != (*want)[1])
            bad ~= format("%s: [%s] defaults [%s], captured [%s] [%s]", cls,
                          pol.activationResetAttrs.join(","), defs.join(","), (*want)[0], (*want)[1]);
        if (pol.activationResetAttrs.length) ++nonEmpty; else ++empty;
    });
    assert(modelIds == 13 && seen.length == 12,
           format("S6r floor: %s model ids / %s classes built, measured 13 / 12", modelIds, seen.length));
    assert(bad.length == 0, format("S6r structural: the activation-reset table differs: %s", bad));
    assert(nonEmpty == 8 && empty == 4,
           format("S6r structural: %s classes reset at activation, %s none — measured 8 / 4",
                  nonEmpty, empty));

    // STRUCTURAL — step 4 (a rule, form item 12): no `reinitSession` and no prepared installer
    // (`installPreparedActivation`, the live arm's path — plan §23.6) of a model class writes a
    // LITERAL into an attribute its policy images: the copy is the cache's, the reset the
    // session's. Fields are read off the class's own `Param` bindings; a chain `a = b = 0` is
    // literal for every link. Positive control (form item 5): Mirror's installer writes the
    // derived plane axes `left`/`up` from the prepared image — found as imaged-field writes, not
    // literal, not counted.
    size_t bodies;
    string[] writes, derived;
    auto literal = regex(`^(-?[0-9][0-9.]*[fFL]?|true|false|null|Vec3\(\s*-?[0-9.]+f?\s*,`
                         ~ `\s*-?[0-9.]+f?\s*,\s*-?[0-9.]+f?\s*\))$`);
    foreach (f; kRebaseBodyFiles) {
        const code = blankNonCode(readText(f));
        const raw = readText(f);
        auto im = matchFirst(raw, regex(`imageAttrs:\s*\[([^\]]*)\]`));
        assert(!im.empty, "S6r floor: no imageAttrs literal in " ~ f);
        string[] fields;
        foreach (m; matchAll(raw, regex(`Param\.\w+\("(\w+)",\s*"[^"]*",\s*&([\w.]+)`)))
            if (im[1].canFind(`"` ~ m[1] ~ `"`)) {
                const fld = m[2];
                fields ~= fld[fld.lastIndexOf('.') + 1 .. $];
            }
        foreach (marker; ["void reinitSession()", "void installPreparedActivation("]) {
            if (code.indexOf(marker) < 0) continue;
            ++bodies;
            const b = bodyAt(code, marker);
            foreach (fld; fields) {
                size_t sites;
                foreach (n; identSites(b, fld, true)) sites += n[n.lastIndexOf(':') + 1 .. $].to!size_t;
                size_t lit;
                foreach (m; matchAll(b, regex(`(?:^|[^\w])` ~ fld ~ `\s*=(?!=)\s*`
                                              ~ `(?:[A-Za-z_][\w.]*\s*=(?!=)\s*)*([^;]*);`)))
                    if (!matchFirst(m[1].strip, literal).empty) ++lit;
                foreach (_; 0 .. lit) writes ~= format("%s %s: %s", f, marker, fld);
                foreach (_; lit .. sites) derived ~= format("%s %s: %s", f, marker, fld);
            }
        }
    }
    assert(bodies == 20, format("S6r floor: %s reinitSession/installPreparedActivation bodies "
           ~ "found, measured 20 (9 + 11)", bodies));
    assert(derived == ["source/tools/alignment/mirror.d void installPreparedActivation(: left",
                       "source/tools/alignment/mirror.d void installPreparedActivation(: up"],
           format("S6r control: the derived imaged-field writes are %s, expected Mirror's "
                  ~ "installer left/up (the rule must see a write it does not count)", derived));
    assert(writes.length == 0, format("S6r structural: the area reinitSession + "
           ~ "installPreparedActivation writes a literal into an imaged attribute (step 4: the "
           ~ "reset is the session's activation alone): %s", writes));
}

// Pin (form item 1): a tool resets nothing at activation unless its policy says so.
static assert(ToolSessionPolicy.init.activationResetAttrs.length == 0);

// ---------------------------------------------------------------------------
// (4k) Task 9300 (topology-redo wave S7r, model doc §R13 M-ri): the redo image a redo pins is
// ONE pair of session data (`pinnedRedoImage_`, `pinnedOperation_`), written at ONE settle
// (`settleAfterNavigation_`: pinned by a redo, released by an undo) and released at the
// operation's end (`endOperation_`); read by ONE writer of rows (`stepEnds`), whose origin and
// operation are set BEFORE the row's images; which tools pin is the class's DATA
// (`redoPinsRefireImage`). Order (form item 2): floor -> needle -> structural -> pin.
// Polarity: every needle is false before S7r (none of the names existed), true after.
// ---------------------------------------------------------------------------

unittest { // (4k)
    import std.file : dirEntries, SpanMode;
    import tests.unit.census_symbols : blankUnittestBodies;
    import tests.unit.production_tool_policies : productionPolicies;
    import tool : capturedTopologyModel;
    auto es = blankUnittestBodies(blankNonCode(readText("source/edit_session.d")));
    const ts = bodyAt(es, "private struct ToolSession");
    // FLOOR (form item 4): the model's 12 class files and the four session bodies read.
    size_t files;
    foreach (f; kRebaseBodyFiles) if (readText(f).length) ++files;
    assert(files == 12, format("S7r floor: %s of the 12 model class files read", files));
    foreach (m; ["private void settleAfterNavigation_(bool isUndo)",
                 "void stepEnds(Tool t, bool ifChanged)", "private void endOperation_()",
                 "private bool ownInstanceStepOnTop_(Tool t, ulong tok)"])
        assert(squeeze(bodyAt(ts, m)).length > 2, "S7r floor: the session body " ~ m ~ " is empty");
    // NEEDLES, by identifier: writes and every spelling apart (form item 3).
    foreach (d; ["pinnedOperation_", "pinnedRedoImage_"])
        assert(identSites(es, d, true) == ["ToolSession.endOperation_:1",
                                           "ToolSession.settleAfterNavigation_:1"],
               format("S7r needle: %s is written at %s, expected the settle after a navigation "
                      ~ "(pin / release) and the operation's end alone", d, identSites(es, d, true)));
    assert(identSites(es, "pinnedRedoImage_", false)
           == ["ToolSession.endOperation_:1", "ToolSession.settleAfterNavigation_:1",
               "ToolSession.stepEnds:1", "ToolSession:1"],
           format("S7r needle: pinnedRedoImage_ appears at %s, expected its declaration, the two "
                  ~ "writers and one read in stepEnds (the row's after)",
                  identSites(es, "pinnedRedoImage_", false)));
    assert(identSites(es, "pinnedOperation_", false)
           == ["ToolSession.endOperation_:1", "ToolSession.settleAfterNavigation_:1",
               "ToolSession.stateJson:1", "ToolSession.stepEnds:2", "ToolSession:1"],
           format("S7r needle: pinnedOperation_ appears at %s, expected its declaration, the two "
                  ~ "writers, the key in stepEnds and the report", identSites(es, "pinnedOperation_", false)));
    assert(identSites(es, "ownInstanceStepOnTop_", false)
           == ["<decl>:1", "ToolSession.settleAfterNavigation_:1"],
           format("S7r needle: ownInstanceStepOnTop_ sites %s, expected one call in the settle",
                  identSites(es, "ownInstanceStepOnTop_", false)));
    // the datum, every word occurrence in `source` (form item 12: a rule, not a list)
    string[] datum;
    size_t scanned;
    foreach (f; dirEntries("source", "*.d", SpanMode.depth)) {
        ++scanned;
        foreach (site; identSites(blankUnittestBodies(blankNonCode(readText(f.name))),
                                  "redoPinsRefireImage", false))
            datum ~= f.name ~ " " ~ site;
    }
    sort(datum);
    assert(scanned > 300, format("S7r census: read %s source files", scanned));
    assert(datum == ["source/edit_session.d ToolSession.settleAfterNavigation_:1",
                     "source/tool.d <decl>:1",
                     "source/tools/edit/edge_bevel.d EdgeBevelTool.sessionPolicy:1",
                     "source/tools/edit/poly_inset_tool.d PolyInsetTool.sessionPolicy:1"],
           format("S7r needle: redoPinsRefireImage appears at %s, expected its declaration, the "
                  ~ "two captured policy literals and one read in the settle", datum));
    // STRUCTURAL: stepEnds sets the row's origin and operation before its images — a pin
    // keyed on the previous row's operation would pin a restart (M13).
    const steE = squeeze(bodyAt(ts, "void stepEnds(Tool t, bool ifChanged)"));
    const opAt = steE.indexOf("if(origin!=StepOrigin.refire)operation_=++nextOperation_;");
    const snapAt = steE.indexOf("cmd.setSnapshots(");
    assert(opAt >= 0 && snapAt > opAt,
           format("S7r needle: stepEnds writes the row's images (at %s) before its operation "
                  ~ "(at %s)", snapAt, opAt));
    // STRUCTURAL: the settle pins the operation AFTER it re-reads it from the history — a pin
    // taken first would key the image on the operation armed before the navigation (O1).
    const setl = squeeze(bodyAt(ts, "private void settleAfterNavigation_(bool isUndo)"));
    const opSet = setl.indexOf("operation_=isUndo?headOfRedoOperation_(aToken):topOperation_(aToken);");
    const pinSet = setl.indexOf("pinnedOperation_=pin?operation_:0;");
    assert(opSet >= 0 && pinSet > opSet,
           format("S7r needle: settleAfterNavigation_ pins the operation (at %s) before it "
                  ~ "re-reads it (at %s)", pinSet, opSet));

    // STRUCTURAL — the datum read off the PRODUCTION instances of the model's classes.
    size_t ids;
    string[] seen, pins;
    size_t off;
    productionPolicies(ids, (string id, Tool t) {
        const pol = t.sessionPolicy();
        if (!capturedTopologyModel(pol)) return;
        auto cls = typeid(t).name;
        cls = cls[cls.lastIndexOf('.') + 1 .. $];
        if (seen.canFind(cls)) return;
        seen ~= cls;
        if (pol.redoPinsRefireImage) pins ~= cls; else ++off;
    });
    sort(pins);
    assert(seen.length == 12, format("S7r floor: %s model classes built, measured 12", seen.length));
    assert(pins == ["EdgeBevelTool", "PolyInsetTool"] && off == 10,
           format("S7r structural: redoPinsRefireImage is true for %s and false for %s classes; "
                  ~ "captured: PolyInsetTool, EdgeBevelTool (Capture-10/11) and 10 false", pins, off));
}

// Pin (form item 1): every refire's redo shows its own result unless the policy says so.
static assert(ToolSessionPolicy.init.redoPinsRefireImage == false);

// (4d') The `built` census of the model's 12 classes (S3 review, 8950): the rebase
// body sets `built = !before.matches(*mesh)`, and since S3 a close rebases onto the
// live mesh, so `built` is false after every close with the tool bound. Each reader
// (`hasUncommittedEdit` — `active && built && …` — and through it `phase`, Shift+LMB,
// the command close's idle branch, `discardOpenEdit`) sees that state; a new reader or
// writer must be named here. Identifier-keyed (every spelling: `built`, `this.built`,
// `tool.built`), by enclosing symbol, unittest bodies blanked; measured 2026-10-02.
private enum string[][string] kBuiltSites = [
    "source/tools/alignment/array_tool.d": [
        "<decl>:1", "ArrayTool.activate:1", "ArrayTool.applyHeadless:2",
        "ArrayTool.buildPreparedParamUpdate:1", "ArrayTool.cancelLiveEdit:2",
        "ArrayTool.commitOperation:1", "ArrayTool.deactivate:1", "ArrayTool.hasUncommittedEdit:1",
        "ArrayTool.installPreparedActivation:1",
        "ArrayTool.onMouseButtonUp:1", "ArrayTool.preparedActivationInstalledForTest:1",
        "ArrayTool.preparedParamUpdateMatches:1", "ArrayTool.rebaseTopologyStep:1",
        "ArrayTool.rebuildPreview:1", "ArrayTool.resyncSession:2",
        "ArrayTool.seedPreparedActivationForTest:1", "ArrayTool.seedPreparedParamForTest:1",
        "ArrayTool:1",
    ],
    "source/tools/alignment/clone_tool.d": [
        "CloneTool.activate:1", "CloneTool.applyHeadless:1", "CloneTool.cancelLiveEdit:2",
        "CloneTool.commitOperation:1", "CloneTool.installPreparedActivation:1",
        "CloneTool.onMouseButtonUp:1", "CloneTool.preparedActivationInstalledForTest:1",
        "CloneTool.rebaseTopologyStep:1", "CloneTool.rebuildPreview:1", "CloneTool.resyncSession:2",
        "CloneTool.seedPreparedActivationForTest:1", "CloneTool:3",
    ],
    "source/tools/alignment/mirror.d": [],
    "source/tools/alignment/radial_array_tool.d": [
        "<decl>:1", "RadialArrayTool.applyHeadless:2",
        "RadialArrayTool.buildPreparedActivationImage:1",
        "RadialArrayTool.buildPreparedDeactivateImage:1",
        "RadialArrayTool.buildPreparedParamImage:3", "RadialArrayTool.cancelLiveEdit:1",
        "RadialArrayTool.commitOperation:1", "RadialArrayTool.deactivate:1",
        "RadialArrayTool.hasUncommittedEdit:1", "RadialArrayTool.installPreparedTransition:2",
        "RadialArrayTool.onMouseButtonUp:1", "RadialArrayTool.preparedBuiltSeedUnchangedForTest:1",
        "RadialArrayTool.preparedParamMatches:1", "RadialArrayTool.preparedTransitionForTest:1",
        "RadialArrayTool.rebaseTopologyStep:1", "RadialArrayTool.rebuildPreview:1",
        "RadialArrayTool.reinitSession:1", "RadialArrayTool.seedPreparedBuiltTransitionForTest:1",
        "RadialArrayTool.seedPreparedParamForTest:1",
        "RadialArrayTool.seedPreparedTransitionForTest:1", "RadialArrayTool:1",
        "RadialArrayTransitionImage:1",
    ],
    "source/tools/deform/smooth_shift_tool.d": [
        "<decl>:1", "SmoothShiftParamProjection.opEquals:2", "SmoothShiftParamProjection:1",
        "SmoothShiftTool.applyHeadless:2",
        "SmoothShiftTool.cancelLiveEdit:2", "SmoothShiftTool.deactivate:1",
        "SmoothShiftTool.draw:1", "SmoothShiftTool.hasUncommittedEdit:1",
        "SmoothShiftTool.installPreparedActivation:1",
        "SmoothShiftTool.paramProjection:1",
        "SmoothShiftTool.preparedActivationDirtyForTest:1",
        "SmoothShiftTool.preparedActivationForTest:1",
        "SmoothShiftTool.preparedParamBuiltForTest:1",
        "SmoothShiftTool.rebuildPreview:1", "SmoothShiftTool.reinitSession:1",
        "SmoothShiftTool.seedPreparedActivationForTest:1",
        "SmoothShiftTool.seedPreparedParamForTest:1",
    ],
    "source/tools/edit/edge_bevel.d": [
        "<decl>:2", "EdgeBevelParamProjection.opEquals:2", "EdgeBevelParamProjection:1",
        "EdgeBevelTool.applyHeadless:2",
        "EdgeBevelTool.cancelLiveEdit:2", "EdgeBevelTool.deactivate:1", "EdgeBevelTool.draw:1",
        "EdgeBevelTool.drawReplica:1", "EdgeBevelTool.hasUncommittedEdit:1",
        "EdgeBevelTool.installPreparedActivation:1",
        "EdgeBevelTool.interactionStateBytesForTest:1", "EdgeBevelTool.paramProjection:1",
        "EdgeBevelTool.preparedActivationDirtyForTest:1",
        "EdgeBevelTool.preparedActivationForTest:1",
        "EdgeBevelTool.preparedParamInstalledForTest:1", "EdgeBevelTool.readInteractionForTest:1",
        "EdgeBevelTool.rebuildPreview:1",
        "EdgeBevelTool.reinitSession:1", "EdgeBevelTool.seedPreparedActivationForTest:1",
        "EdgeBevelTool.seedPreparedParamForTest:1", "EdgeBevelTool.toolStateJson:1",
    ],
    "source/tools/edit/edge_extrude.d": [
        "<decl>:1", "EdgeExtrudeParamProjection.opEquals:2", "EdgeExtrudeParamProjection:1",
        "EdgeExtrudeTool.applyHeadless:2",
        "EdgeExtrudeTool.cancelLiveEdit:1", "EdgeExtrudeTool.deactivate:1",
        "EdgeExtrudeTool.draw:1", "EdgeExtrudeTool.hasUncommittedEdit:1",
        "EdgeExtrudeTool.installPreparedActivation:1",
        "EdgeExtrudeTool.paramProjection:1",
        "EdgeExtrudeTool.preparedActivationDirtyForTest:1",
        "EdgeExtrudeTool.preparedActivationForTest:1",
        "EdgeExtrudeTool.preparedParamBuiltForTest:1",
        "EdgeExtrudeTool.rebuildPreview:1", "EdgeExtrudeTool.reinitSession:1",
        "EdgeExtrudeTool.seedPreparedActivationForTest:1",
        "EdgeExtrudeTool.seedPreparedParamForTest:1", "EdgeExtrudeTool.toolStateJson:1",
    ],
    "source/tools/edit/poly_extrude.d": [
        "<decl>:1", "PolyExtrudeParamProjection.opEquals:2", "PolyExtrudeParamProjection:1",
        "PolyExtrudeTool.applyHeadless:2",
        "PolyExtrudeTool.cancelLiveEdit:1", "PolyExtrudeTool.deactivate:1",
        "PolyExtrudeTool.draw:1", "PolyExtrudeTool.hasUncommittedEdit:1",
        "PolyExtrudeTool.installPreparedActivation:1",
        "PolyExtrudeTool.paramProjection:1",
        "PolyExtrudeTool.preparedActivationDirtyForTest:1",
        "PolyExtrudeTool.preparedActivationForTest:1",
        "PolyExtrudeTool.preparedInvalidActivationForTest:1",
        "PolyExtrudeTool.preparedParamBuiltForTest:1",
        "PolyExtrudeTool.rebuildPreview:1", "PolyExtrudeTool.reinitSession:1",
        "PolyExtrudeTool.seedPreparedActivationForTest:1",
        "PolyExtrudeTool.seedPreparedParamForTest:1",
    ],
    "source/tools/edit/poly_inset_tool.d": [
        "<decl>:1", "PolyInsetParamProjection.opEquals:2", "PolyInsetParamProjection:1",
        "PolyInsetTool.applyHeadless:2",
        "PolyInsetTool.cancelLiveEdit:2", "PolyInsetTool.deactivate:1",
        "PolyInsetTool.hasUncommittedEdit:1", "PolyInsetTool.installPreparedActivation:1",
        "PolyInsetTool.paramProjection:1",
        "PolyInsetTool.preparedActivationDirtyForTest:1",
        "PolyInsetTool.preparedActivationForTest:1", "PolyInsetTool.preparedParamBuiltForTest:1",
        "PolyInsetTool.rebaseTopologyStep:1", "PolyInsetTool.rebuildPreview:1",
        "PolyInsetTool.reinitSession:1", "PolyInsetTool.seedPreparedActivationForTest:1",
        "PolyInsetTool.seedPreparedParamForTest:1",
    ],
    "source/tools/edit/vert_merge_tool.d": [
        "<decl>:1", "VertexMergeParamProjection.opEquals:2", "VertexMergeParamProjection:1",
        "VertexMergeTool.applyHeadless:2",
        "VertexMergeTool.cancelLiveEdit:2", "VertexMergeTool.deactivate:1",
        "VertexMergeTool.hasUncommittedEdit:1", "VertexMergeTool.installPreparedActivation:1",
        "VertexMergeTool.paramProjection:1",
        "VertexMergeTool.preparedActivationDirtyForTest:1",
        "VertexMergeTool.preparedActivationForTest:1",
        "VertexMergeTool.preparedParamBuiltForTest:1", "VertexMergeTool.rebaseTopologyStep:1",
        "VertexMergeTool.rebuildPreview:1", "VertexMergeTool.reinitSession:1",
        "VertexMergeTool.seedPreparedActivationForTest:1",
        "VertexMergeTool.seedPreparedParamForTest:1",
    ],
    "source/tools/edit/vertex_bevel_tool.d": [
        "<decl>:1", "VertexBevelParamProjection.opEquals:2", "VertexBevelParamProjection:1",
        "VertexBevelTool.applyHeadless:2",
        "VertexBevelTool.cancelLiveEdit:2", "VertexBevelTool.deactivate:1",
        "VertexBevelTool.draw:1", "VertexBevelTool.hasUncommittedEdit:1",
        "VertexBevelTool.installPreparedActivation:1",
        "VertexBevelTool.paramProjection:1",
        "VertexBevelTool.preparedActivationDirtyForTest:1",
        "VertexBevelTool.preparedActivationForTest:1",
        "VertexBevelTool.preparedParamBuiltForTest:1",
        "VertexBevelTool.rebuildPreview:1", "VertexBevelTool.reinitSession:1",
        "VertexBevelTool.seedPreparedActivationForTest:1",
        "VertexBevelTool.seedPreparedParamForTest:1",
    ],
    "source/tools/edit/vertex_extrude_tool.d": [
        "<decl>:1", "VertexExtrudeParamProjection.opEquals:2", "VertexExtrudeParamProjection:1",
        "VertexExtrudeTool.applyHeadless:2",
        "VertexExtrudeTool.cancelLiveEdit:2", "VertexExtrudeTool.deactivate:1",
        "VertexExtrudeTool.draw:1", "VertexExtrudeTool.hasUncommittedEdit:1",
        "VertexExtrudeTool.installPreparedActivation:1",
        "VertexExtrudeTool.paramProjection:1",
        "VertexExtrudeTool.preparedActivationDirtyForTest:1",
        "VertexExtrudeTool.preparedActivationForTest:1",
        "VertexExtrudeTool.preparedParamBuiltForTest:1",
        "VertexExtrudeTool.rebuildPreview:1", "VertexExtrudeTool.reinitSession:1",
        "VertexExtrudeTool.seedPreparedActivationForTest:1",
        "VertexExtrudeTool.seedPreparedParamForTest:1",
    ],
];

unittest { // (4d')
    import tests.unit.census_symbols : blankUnittestBodies;
    // FLOOR (form item 4): the census reads the 12 files and finds `built` in 11 of
    // them (Mirror keys its preview on `engaged`), 194 enclosing-symbol sites in all,
    // plus the shared gizmo rebase's one (task 9429).
    assert(kBuiltSites.length == 12, "S3 built census: the table names "
           ~ format("%s", kBuiltSites.length) ~ " files, the model has 12");
    size_t files, sites;
    foreach (f; kRebaseBodyFiles) {
        const s = identSites(blankUnittestBodies(blankNonCode(readText(f))), "built", false);
        assert(f in kBuiltSites, "S3 built census: no row for " ~ f);
        assert(s == kBuiltSites[f], format("S3 built census: %s reads/writes `built` at %s, "
               ~ "the table says %s — name the new site (and what it sees after a close)",
               f, s, kBuiltSites[f]));
        if (s.length) ++files;
        sites += s.length;
    }
    assert(files == 11 && sites == 194, format("S3 built census: %s files, %s sites; measured 11, 194",
                                                files, sites));
    // Task 9429: the six gizmo tools' rebase write is ONE site, the shared gizmo rebase.
    const home = identSites(blankUnittestBodies(blankNonCode(readText("source/tools/topology_step.d"))),
                            "built", false);
    assert(home == ["GizmoTopologyRebase.rebaseTopologyStep:1"],
           format("S3 built census: topology_step.d reads/writes `built` at %s", home));
}

// The rebase entry point stays (its one caller is `rebaseOnCurrent_`); the per-tool flags it
// replaced are fenced in (4l).
static assert(__traits(hasMember, imported!"tool".TopologyStepClient, "rebaseTopologyStep"));

// ---------------------------------------------------------------------------
// (4l) Task 9310 (topology-redo wave S8, closure): the policy's composition is the compiler's
// list (form item 1), the five per-tool topology-redo flags the wave replaced by one operation
// mechanism are fenced in one place, and so are the session's names: the removed route state
// of the re-begun panel write (plan R7.1 "gone") beside the data the wave added
// (`instanceActive_`, S6r; the pinned redo image, S7r). `ToolSession` is a private type of
// `edit_session`, reached through the field `tools_` of `EditSession` (`.tupleof`, by name).
// ---------------------------------------------------------------------------

// The fence first, so a returning flag reddens by its name before the composition pin.
static foreach (gone; ["firstTopologyRedoUsesAfterAttrs", "rebaseTopologyAfterStep",
                       "discardFirstTopologyRedoOnActivationUndo",
                       "discardLaterTopologyRedoOnRearm", "dormantAfterClosedRedo",
                       "paramWriteSteps"])   // task 9430: an arm property, not a tool datum
    static assert(!__traits(hasMember, imported!"tool".ToolSessionPolicy, gone),
                  "S8 fence: the per-tool flag " ~ gone ~ " is back");

static assert([__traits(allMembers, imported!"tool".ToolSessionPolicy)] == [
    "activationRow", "commandClose", "sessionSteps", "historyTopologySteps",
    "historyRecordedSteps", "recordedFirstUndoEndsTool", "postmodeStartsOnPress",
    "previewHistoryLadder", "opensAt", "noClone", "imageAttrs", "haulAttrs",
    "activationResetAttrs", "armAttr", "headlessReplacesWindow", "recordCarriesActivation",
    "keepAliveOnCancel", "rollovers", "handleAnchor", "armRestoresWholeImage", "dropWritesRow",
    "toolSetDropRow", "dropUndo", "armUndoLeavesToolLatent",
    "pressOpensOperation", "foldsParamRowsIntoBlock",
    "redoPinsRefireImage", "commandEndsOpenGesture", "stepsParamWrites"],
    "UND2 pin: ToolSessionPolicy's members changed (measured 29 since task 9508)");

/// The session type `EditSession` holds in its field `tools_`.
private template SessionOf(ES) {
    static foreach (i, f; ES.tupleof)
        static if (__traits(identifier, ES.tupleof[i]) == "tools_")
            alias SessionOf = typeof(ES.tupleof[i]);
}

private alias SessionT = SessionOf!(imported!"edit_session".EditSession);
// Positive control: the fences below read the session's own members.
static assert(__traits(hasMember, SessionT, "postmodeArmed_"));
static foreach (kept; ["instanceActive_", "pinnedRedoImage_", "pinnedOperation_"])
    static assert(__traits(hasMember, SessionT, kept), "S8 pin: the session lost " ~ kept);
// `navBefore_` is a live member (the navigation's start, S2a); the re-begun route's ban on it
// is the S2b needle "stepEnds reads isUndo / navBefore_".
static foreach (gone; ["rebegun_", "uiOperation_", "reopenUiOperation_", "noApplyWrite_",
                       "rebeginsOnRedo_", "topologyFirstGroupLive_"])
    static assert(!__traits(hasMember, SessionT, gone), "S8 fence: the session holds " ~ gone);
static assert(!__traits(hasMember, imported!"edit_session", "RebeginRoute"));

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
    assert(scanned == 47, format("M4 policy classes: scanned %s concrete tools.* classes, "
                                 ~ "measured 47", scanned));
    sort(keep);
    sort(carries);
    assert(keep == kKeepAliveClasses,
           format("M4 policy classes: keepAliveOnCancel declared by %s, expected %s",
                  keep, kKeepAliveClasses));
    // Task 8920: inside the topology model the carry is derived from `opensAt`
    // (`firstStepCarriesActivation`), so only Edge Extend declares it.
    assert(carries == ["tools.edit.edge_extend.EdgeExtendTool"],
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
    {   // A registered tool's own pipe block, read from its declaration: the
        // registry is not built here (its deps need a live app). The armed
        // wiring's witness is test_session_laws_display's magnet cell (no
        // registry entry → no element node → 0 px, red).
        import tools.deform.magnet : MagnetTool;
        pipeOf["xfrm.pointAttract"] = MagnetTool.presetPipe();
    }
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
    assert(stageIds == ["ElementMove", "move.element", "xfrm.elementMove",
                        "xfrm.pointAttract"]
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
    assert(scanned == 47, format("M6 policy classes: scanned %s, measured 47", scanned));
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
    assert(scanned == 47, format("M7 policy classes: scanned %s, measured 47", scanned));
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
// (10) Wave plan 8640 S6 — a user drop writes a drop row by policy DATA
// (`dropWritesRow`). Provenance: CAPTURED for the Topology Pen (X-esc,
// X-space, X-q, X-sel, X-bare; the gesture loss on undo is NOT ported — gap
// row (a), L8); false for every other tool (uncaptured: no row, by data).
// Exactly one class declares it, and the drop door reads the policy AND the
// transition table before the door runs.
// ---------------------------------------------------------------------------

static assert(ToolSessionPolicy.init.dropWritesRow == false);

unittest { // (10)
    string[] declared;
    size_t scanned;
    foreach (m; ModuleInfo) {
        if (m is null || !m.name.startsWith("tools.")) continue;
        foreach (c; m.localClasses) {
            if (!derivesFromTool(c) || (c.m_flags & TypeInfo_Class.ClassFlags.isAbstract))
                continue;
            ++scanned;
            if (blit(c).sessionPolicy().dropWritesRow) declared ~= c.name;
        }
    }
    assert(scanned == 47, format("S6 policy classes: scanned %s, measured 47", scanned));
    assert(declared == ["tools.edit.topology_pen.tool.TopologyPenTool"],
           format("S6 policy classes: dropWritesRow declared by %s, expected the pen only", declared));
    auto app = squeeze(bodyAt(blankNonCode(readText("source/app.d")),
        "void dropActiveToolWith(ToolTransition why, DropContext ctx)"));
    assert(app.count("constbooldropRow=activeTool!is"~"null&&dropWritesRowFor(why)&&" ~
                     "(activeTool.sessionPolicy().dropWritesRow||" ~
                     "(activeTool.sessionPolicy().toolSetDropRow&&ctx.toolSetDoor));") == 1,
           "S6 wiring census: the drop door no longer reads the policy and the transition table");
    inOrder(app, ["ctx.toolSetDoor));",
                  "scope(failure)if(session!is"~"null)session.abandonDropRow();",
                  "session.closeOperation(closeReasonFor(why),CommandDoor.ui,dropRow,ctx);",
                  "activeTool.deactivate();"], "dropActiveToolWith");
}

// ---------------------------------------------------------------------------
// (10b) Task 9508 — K-RD rules 2 and 3 are policy DATA. `toolSetDropRow`:
// captured for the transform presets and Polygon Bevel (findings_K-RD CD_Q /
// CD_S × Move, Rotate, Scale, Move Item, Bevel); `armUndoLeavesToolLatent`:
// captured on the transform tool (RD_DROP_Z0D). Exactly these classes declare
// them; the `tool.set` doors are the only ones that raise `toolSetDoor`.
// ---------------------------------------------------------------------------

static assert(ToolSessionPolicy.init.toolSetDropRow == false);
static assert(ToolSessionPolicy.init.armUndoLeavesToolLatent == false);

unittest { // (10b)
    import tool : DropUndoPolicy, DropUndoExtent, DropRedoPopulation;
    string[] dropRow, latent, extents;
    size_t scanned;
    foreach (m; ModuleInfo) {
        if (m is null || !m.name.startsWith("tools.")) continue;
        foreach (c; m.localClasses) {
            if (!derivesFromTool(c) || (c.m_flags & TypeInfo_Class.ClassFlags.isAbstract))
                continue;
            ++scanned;
            const pol = blit(c).sessionPolicy();
            if (pol.toolSetDropRow) dropRow ~= c.name;
            if (pol.armUndoLeavesToolLatent) latent ~= c.name;
            if (pol.dropUndo.extent != DropUndoExtent.none) extents ~= c.name;
            if (c.name == "tools.edit.topology_pen.tool.TopologyPenTool")
                assert(pol.dropUndo == DropUndoPolicy(DropUndoExtent.newestPressBlock, DropRedoPopulation.discard),
                    "plain pen must discard redo of its newest press");
            else if (pol.toolSetDropRow)
                assert(pol.dropUndo == DropUndoPolicy(DropUndoExtent.wholeSession, DropRedoPopulation.editRows),
                    "whole-session declarers preserve edit-row redo");
            else assert(pol.dropUndo == DropUndoPolicy.init, "other concrete classes retain default drop extent");
        }
    }
    extents.sort();
    assert(extents == ["tools.edit.poly_bevel.PolyBevelTool", "tools.edit.topology_pen.tool.TopologyPenTool",
        "tools.transform.xfrm_transform.XfrmTransformTool"], "drop extent declaration population");
    assert(scanned == 47, format("9508 policy classes: scanned %s, measured 47", scanned));
    dropRow.sort();
    assert(dropRow == ["tools.edit.poly_bevel.PolyBevelTool",
                       "tools.transform.xfrm_transform.XfrmTransformTool"],
           format("9508 policy classes: toolSetDropRow declared by %s", dropRow));
    assert(latent == ["tools.transform.xfrm_transform.XfrmTransformTool"],
           format("9508 policy classes: armUndoLeavesToolLatent declared by %s", latent));
    auto app = blankNonCode(readText("source/app.d"));
    assert(squeeze(app).count("ctx.toolSetDoor=true;") == 1,
           "9508 wiring census: one door raises toolSetDoor besides the type keys");
    assert(squeeze(app).count("DropContext(false,true,before,!flipped)") == 2,
           "9508 wiring census: the two selection-type funnels pass !flipped as toolSetDoor");
}

// ---------------------------------------------------------------------------
// (12) Wave plan 8640 S7a — the operation context and the parameter-row fold
// are policy DATA (`pressOpensOperation`, `foldsParamRowsIntoBlock`).
// Provenance: CAPTURED for the Topology Pen (H1-move z1, C0-N1/N2, X-w,
// X-toggle; L15, L38, L41-L45, L53-L55); false for every other tool (no
// capture: the session reads them as off). Exactly one id declares each —
// two censuses, each counting its own field, over every `kTable` row.
// ---------------------------------------------------------------------------

static assert(ToolSessionPolicy.init.pressOpensOperation == false);
static assert(ToolSessionPolicy.init.foldsParamRowsIntoBlock == false);

unittest { // (12)
    auto manifest = parseJSON(readText("tools/prepared_writer_manifest.json"));
    string[string] moduleOf;
    foreach (p; manifest["products"].array)
        moduleOf[p["aggregate"].str] = p["module"].str;
    string[] opens, folds;
    size_t visited;
    foreach (row; kTable) {
        auto ci = TypeInfo_Class.find(moduleOf[row.cls] ~ "." ~ row.cls);
        assert(ci !is null, "S7a policy table: class not linked: " ~ row.cls);
        ++visited;
        const pol = blit(ci).sessionPolicy();
        if (pol.pressOpensOperation) opens ~= row.id;
        if (pol.foldsParamRowsIntoBlock) folds ~= row.id;
    }
    assert(visited == kTable.length && kTable.length == 71,
           format("S7a policy table: visited %s of %s rows, measured 71", visited, kTable.length));
    // The pen and its Drag Weld preset (task 9525), one class.
    assert(opens == ["mesh.dragWeld", "mesh.topoPen"],
           format("S7a policy table: pressOpensOperation declared by %s, expected the pen only",
                  opens));
    assert(folds == ["mesh.dragWeld", "mesh.topoPen"],
           format("S7a policy table: foldsParamRowsIntoBlock declared by %s, expected the pen only",
                  folds));
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
    "tools.edit.bridge_tool", "tools.edit.edge_bevel",
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
// Population floor: the pin read the 47 classes block (8) scans.
static assert(kToolBar == 47, "M7 tool pin: read concrete tool classes, measured 47");

unittest { // Tasks 7990/8030: production topology R wiring, not a helper replica.
    auto es = blankNonCode(readText("source/edit_session.d"));
    auto esFlat = squeeze(es);
    auto edge = blankNonCode(readText("source/tools/edit/edge_extrude.d"));
    auto poly = blankNonCode(readText("source/tools/edit/poly_extrude.d"));
    auto tl = blankNonCode(readText("source/prepared_tool_transition.d"));
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
    assert(es.canFind("parameterStepBegins(t, beforeWrite)")
        && es.canFind("cmd.setTopologyStep(topologyPendingAttrs_, attrs,"),
        "interactive parameter or history-owned step payload was disconnected");
    assert(edge.canFind("sessionStepBegins(e.button == SDL_BUTTON_MIDDLE")
        && edge.canFind("sessionStepEnds();")
        && edgePreparedClose.count("context.markNoHistoryInstall()") == 1
        && !edgePreparedClose.canFind("markHistoryInstall("),
        "Edge drag/Middle or prepared close lost its production seam");
    // Task 9429: the Plain record is the topology-step client mixin's, composed by both.
    auto stepHome = blankNonCode(readText("source/tools/topology_step.d"));
    assert(stepHome.canFind("recordGestureEdit(cmd, GestureRecordMode.Plain)")
        && edge.canFind("mixin TopologyStepClientBody!")
        && !edge.canFind("GestureRecordMode.ReplaceRunTail"),
        "Edge topology rows must stay separate Plain records");
    assert(poly.canFind("sessionStepBegins(e.button == SDL_BUTTON_MIDDLE")
        && poly.canFind("sessionStepEnds();")
        && poly.canFind("mixin TopologyStepClientBody!")
        && polyPreparedClose.count("c.markNoHistoryInstall()") == 1
        && !polyPreparedClose.canFind("markHistoryInstall(")
        && !poly.canFind("GestureRecordMode.ReplaceRunTail"),
        "Polygon drag/boundary, Plain owner or prepared close lost its production seam");
    // Task 9080 (S6, law 5): the dormant flag is the captured model's (fence in block
    // (4e)); both extrudes gate their preview on the session (probe edit, form item 10).
    // Task 9170 (S5, law 3): the two per-tool redo discards are one session cut
    // (fence beside block (4d'); its sites — the S5 block below).
    assert(edge.canFind("opensAt: OpensAt.arm")
        && es.canFind("cutRefireRedo_(")
        && es.canFind("arm.markDormantTopology()")
        && es.canFind("new TopologyAdjustmentEdit(context, instanceOf_(t), tool_")
        && edge.canFind("if (previewGated()) return;"),
        "Edge first-group or full-closed-redo production policy disconnected");
    // Task 8920: the carry is derived (`firstStepCarriesActivation`) — the
    // Polygon policy no longer declares it and `prepareArm` reads the predicate.
    assert(!poly.canFind("recordCarriesActivation")
        && tl.canFind("firstStepCarriesActivation(pol)")
        && poly.canFind("opensAt: OpensAt.firstPress")
        && poly.canFind("if (previewGated()) return;"),
        "Polygon first-group or full-closed-redo production policy disconnected");
    assert(es.canFind("closedTopologyRedoSource_ = act;")
        && es.canFind("last.get is closedTopologyRedoSource_.get")
        && es.canFind("validClosedTopologyRedo_(arm, id)")
        && esFlat.canFind("sourceisnull||armisnull||closedTopologyId_!=id||arm.armedId()!=id||arm.previousId()!=source.armedId()||arm.previousToken()!=source.sessionToken()")
        && esFlat.canFind("ue.length>=2&&ue[$-1].cmdisarm&&ue[$-2].cmdissource"),
        "closed topology redo lost its source-row cursor or activation lineage");
    // Task 8950 (S3): the first record no longer carries its own basis; the next
    // operation's base is the session's rebase on the live image.
    assert(bodyAt(es, "private void rebaseOnCurrent_(").canFind("rebaseTopologyStep("),
        "the session's rebase of a new operation lost its call into the tool");
    // Task 9020 (S4, law 4, model doc §R9): the redo attributes are the instance
    // mechanism, no per-tool flag (compiler fence beside block (4d')). FLOOR: the three
    // helpers have bodies. NEEDLES (stationary allowed sets, true after S4): one drop
    // image helper computed and one store helper called (after the undo, 9020 F) at the
    // three drops, one seed helper at the two re-creating redos, one ownership test at
    // the two orphan branches and the drop walk.
    {
        import tests.unit.census_symbols : blankUnittestBodies;
        const esU = blankUnittestBodies(es);
        foreach (m; ["private bool boundToLive_(", "private DropImage dropImage_(",
                     "private void storeDropImage_(", "private AttrImage seedRecreated_("])
            assert(squeeze(bodyAt(esU, m)).length > 2, "S4 floor: " ~ m ~ " has no body");
        foreach (h; ["dropImage_", "storeDropImage_"])
            assert(identSites(esU, h, false) == ["<decl>:1",
                   "ToolSession.navigateTopology_:1", "ToolSession.undoImpl_:2"],
                   format("S4 needle: %s sites %s, expected the pair undo, the "
                          ~ "undoImpl_ tail and its dormant branch", h,
                          identSites(esU, h, false)));
        assert(identSites(esU, "seedRecreated_", false) == ["<decl>:1",
               "ToolSession.navigateTopology_:1", "ToolSession.redoImpl_:1"],
               format("S4 needle: seedRecreated_ sites %s, expected its declaration and the "
                      ~ "pair redo of navigateTopology_ and redoImpl_",
                      identSites(esU, "seedRecreated_", false)));
        assert(identSites(esU, "boundToLive_", false) == ["<decl>:1",
               "ToolSession.dropImage_:1", "ToolSession.navigateTopology_:2",
               "ToolSession.ownInstanceStepOnTop_:1"],
               format("S4 needle: boundToLive_ sites %s, expected the undo and redo orphan "
                      ~ "branches, the drop walk and the redo pin's own-instance test (S7r)",
                      identSites(esU, "boundToLive_", false)));
    }
    // Task 9170 (S5, law 3, model doc §3): the redo is cut at one place, the settle
    // after an undo that ends the post mode. FLOOR: the three bodies the sites live in
    // exist. NEEDLES (stationary allowed sets, true after S5; false before it — the cut
    // did not exist and `history_.invalidateRedo()` stood at five sites): the cut is
    // called from the settle alone; the session's two remaining redo kills are the
    // closed-run undo and the parameter-row prune; `truncateRedo` is called by the cut
    // alone in `source` (its in-module unittest blanked).
    {
        import std.file : dirEntries, SpanMode;
        import tests.unit.census_symbols : blankUnittestBodies;
        const esU = blankUnittestBodies(es);
        foreach (m; ["private bool undoImpl_(", "private void pruneRedoTop_(",
                     "private void settleAfterNavigation_("])
            assert(squeeze(bodyAt(esU, m)).length > 2, "S5 floor: " ~ m ~ " has no body");
        assert(identSites(esU, "cutRefireRedo_", false)
               == ["<decl>:1", "ToolSession.settleAfterNavigation_:1"],
               format("S5 needle: cutRefireRedo_ sites %s, expected its declaration and one "
                      ~ "call in settleAfterNavigation_", identSites(esU, "cutRefireRedo_", false)));
        assert(identSites(esU, "invalidateRedo", false)
               == ["ToolSession.pruneRedoTop_:1", "ToolSession.undoImpl_:1"],
               format("S5 needle: the session kills the redo at %s, expected the closed-run "
                      ~ "undo and the parameter-row prune alone (law 3 cuts, never kills)",
                      identSites(esU, "invalidateRedo", false)));
        string[] cuts;
        size_t files;
        foreach (f; dirEntries("source", "*.d", SpanMode.depth)) {
            ++files;
            foreach (site; identSites(blankUnittestBodies(blankNonCode(readText(f.name))),
                                      "truncateRedo", false))
                cuts ~= f.name ~ " " ~ site;
        }
        sort(cuts);
        assert(files > 300, format("S5 census: read %s source files", files));
        assert(cuts == ["source/command_history.d <decl>:1",
                        "source/edit_session.d ToolSession.cutRefireRedo_:1"],
               format("S5 needle: truncateRedo sites in source %s, expected its declaration "
                      ~ "and the law-3 cut", cuts));
    }
    assert(es.canFind("if (topologyPending_ && reporting_(t)")
        && es.canFind("if (topologyPending_) {")
        && edge.canFind("closeOwnOperation(false);"),
        "Edge pending close or RMB history consistency path disconnected");
    assert(carrier.canFind("void setTopologyStep(")
        && carrier.canFind("stepBeforeBasis_")
        && carrier.canFind("stepAfterAttrs_"),
        "history command lost topology basis or attributes");
    const panelDraw = squeeze(bodyAt(panelCode,
        "void drawProvider(ParamProvider p, EditSession session, string toolId = null)"));
    inOrder(panelDraw, [
        "beforeWrite=tisnull||!t.sessionPolicy().stepsParamWrites()?AttrImage.init:t.captureAttrImage();",
        "boolchanged=drawParamWidget(par);",
        // 8290: the held widget is read right after ITS widget, and a row
        // that let go closes its step before any new write.
        "constheld=t!isnull&&ImGui.IsItemActive();",
        "if(!held&&session.parameterStepHeld(p,par.name))session.releaseParameterStep();",
        "session.orchestrateParameterChange(p,par.name,source,ParameterChangePhase.ValueWritten,beforeWrite,held);",
    ], "PropertyPanel.drawProvider topology prewrite");
    assert(panel.count("beforeWrite=tisnull||!t.sessionPolicy().stepsParamWrites()?AttrImage.init:t.captureAttrImage();") == 1
        && panel.count("session.orchestrateParameterChange(p,par.name,source,ParameterChangePhase.ValueWritten,beforeWrite,held);") == 1
        && attr.canFind("beforeWrite=t.sessionPolicy().stepsParamWrites()?t.captureAttrImage():AttrImage.init;")
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

// ---------------------------------------------------------------------------
// (11) Task 9428 (captured K-A) — the `tool.attr` door refuses a write to a row
// the tool reports disabled for EVERY tool (`test_tool_attr_gate`): no per-tool
// datum.
// ---------------------------------------------------------------------------

static assert(!__traits(hasMember, ToolSessionPolicy, "refusesDisabledParamWrites"),
              "9428 fence: the per-tool datum refusesDisabledParamWrites is back");

// ---------------------------------------------------------------------------
// (12) Pen wave plan S8 (A4-rev) — a UI-door command meeting a tool with
// nothing committable ends its open gesture when the tool's policy DATA says
// so (`commandEndsOpenGesture`). Provenance: CAPTURED for the polygon pen
// (K-B4 Backspace-1: the 1-point stroke ends, nothing committed; K-B5 UC1-end:
// the same for select.invert); false for every other tool (step (3) keeps an
// idle uiDoor tool untouched, R20). Exactly the pen declares it, and the
// session's step (3) reads it inside the idle arm, before its return.
// ---------------------------------------------------------------------------

static assert(ToolSessionPolicy.init.commandEndsOpenGesture == false);

unittest { // (12)
    auto manifest = parseJSON(readText("tools/prepared_writer_manifest.json"));
    string[string] moduleOf;
    foreach (p; manifest["products"].array)
        moduleOf[p["aggregate"].str] = p["module"].str;
    string[] declared;
    size_t visited;
    foreach (row; kTable) {
        auto ci = TypeInfo_Class.find(moduleOf[row.cls] ~ "." ~ row.cls);
        assert(ci !is null, "S8 policy table: class not linked: " ~ row.cls);
        ++visited;
        if (blit(ci).sessionPolicy().commandEndsOpenGesture) declared ~= row.id;
    }
    assert(visited == kTable.length && kTable.length == 71,
           format("S8 policy table: visited %s of %s rows, measured 71", visited, kTable.length));
    assert(declared == ["pen"],
           format("S8 policy table: commandEndsOpenGesture declared by %s, expected the pen only",
                  declared));
    auto close = squeeze(bodyAt(blankNonCode(readText("source/edit_session.d")),
                                "CloseOutcome close(CloseReason r"));
    assert(close.count("if(t.sessionPolicy().commandEndsOpenGesture)t.cancelUncommittedEdit();") == 1,
           "S8 wiring census: step (3) no longer ends the open gesture by the policy");
    inOrder(close, ["if(cc==CommandClose.uiDoor&&!t.hasUncommittedEdit()){",
                    "if(t.sessionPolicy().commandEndsOpenGesture)t.cancelUncommittedEdit();",
                    "returnCloseOutcome(false,true);}"], "S8 ToolSession.close step (3)");
}
