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
// (2) Every linked `tools.*` class that answers `activationRow`, exactly.
// (3) The history wiring: the keyboard/panel doors reach the tool session
//     through `EditSession.navigate`, and nothing in the input router steps
//     the history itself.
//
// Provenance: `carried` = today's classification moved from the deleted
// marker interface and the cutting-session ids, unchanged; `notPorted` = the
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
import tool         : Tool, ToolSessionPolicy;
import tool_presets : loadToolPresets;
import tests.unit.census_symbols : blankNonCode;

import core.memory  : GC;
import std.algorithm : canFind, count, sort;
import std.array     : array;
import std.file      : readText;
import std.format    : format;
import std.json      : parseJSON;
import std.string    : indexOf, startsWith, strip;

private enum Prov { carried, notPorted, noCounterpart, uncertain }

private struct Row {
    string id;
    string cls;          // unqualified class name the id's factory builds
    bool   activationRow;
    Prov   prov;
}

/// Measured 2026-09-25 on the M1 tree: 70 ids (48 static + 22 presets).
private immutable Row[] kTable = [
    Row("ElementMove", "XfrmTransformTool", true, Prov.carried),
    Row("Transform", "XfrmTransformTool", true, Prov.carried),
    Row("TransformMove", "XfrmTransformTool", true, Prov.carried),
    Row("TransformRotate", "XfrmTransformTool", true, Prov.carried),
    Row("TransformScale", "XfrmTransformTool", true, Prov.carried),
    Row("edge.bevel", "EdgeBevelTool", false, Prov.notPorted),
    Row("edge.extend", "EdgeExtendTool", false, Prov.notPorted),
    Row("edge.extrude", "EdgeExtrudeTool", false, Prov.notPorted),
    Row("edge.slide", "EdgeSlideTool", false, Prov.notPorted),
    Row("mesh.arrayTool", "ArrayTool", false, Prov.notPorted),
    Row("mesh.bridgeTool", "BridgeTool", false, Prov.notPorted),
    Row("mesh.clone", "CloneTool", false, Prov.notPorted),
    Row("mesh.dragWeld", "DragWeldTool", false, Prov.notPorted),
    Row("mesh.edgeSliceTool", "EdgeSliceTool", true, Prov.carried),
    Row("mesh.loopSliceTool", "LoopSliceTool", true, Prov.carried),
    Row("mesh.mirrorTool", "MirrorTool", false, Prov.notPorted),
    Row("mesh.polyInsetTool", "PolyInsetTool", false, Prov.notPorted),
    Row("mesh.radialArrayTool", "RadialArrayTool", false, Prov.notPorted),
    Row("mesh.radialSweepTool", "RadialSweepTool", false, Prov.uncertain),
    Row("mesh.reduceTool", "ReductionTool", false, Prov.notPorted),
    Row("mesh.sliceTool", "SliceTool", true, Prov.carried),
    Row("mesh.smoothShiftTool", "SmoothShiftTool", false, Prov.notPorted),
    Row("mesh.tack", "TackTool", false, Prov.noCounterpart),
    Row("mesh.thickenTool", "SmoothShiftTool", false, Prov.notPorted),
    Row("mesh.topoPen", "TopologyPenTool", true, Prov.carried),
    Row("mesh.vertexBevel", "VertexBevelTool", false, Prov.notPorted),
    Row("mesh.vertexExtrude", "VertexExtrudeTool", false, Prov.notPorted),
    Row("move", "XfrmTransformTool", true, Prov.carried),
    Row("move.element", "XfrmTransformTool", true, Prov.carried),
    Row("pen", "PenTool", false, Prov.notPorted),
    Row("poly.bevel", "PolyBevelTool", false, Prov.notPorted),
    Row("poly.extrude", "PolyExtrudeTool", false, Prov.notPorted),
    Row("prim.arc", "ArcTool", false, Prov.noCounterpart),
    Row("prim.capsule", "CapsuleTool", false, Prov.notPorted),
    Row("prim.cone", "ConeTool", false, Prov.notPorted),
    Row("prim.cube", "BoxTool", false, Prov.notPorted),
    Row("prim.cylinder", "CylinderTool", false, Prov.notPorted),
    Row("prim.ellipsoid", "SphereTool", false, Prov.notPorted),
    Row("prim.sphere", "SphereTool", false, Prov.notPorted),
    Row("prim.torus", "TorusTool", false, Prov.notPorted),
    Row("prim.tube", "TubeTool", false, Prov.notPorted),
    Row("prim.vertex", "VertexTool", false, Prov.notPorted),
    Row("rotate", "XfrmTransformTool", true, Prov.carried),
    Row("scale", "XfrmTransformTool", true, Prov.carried),
    Row("tool.strokeExtrude", "StrokeExtrudeTool", false, Prov.uncertain),
    Row("vert.merge", "VertexMergeTool", false, Prov.notPorted),
    Row("xfrm.bend", "BendTool", false, Prov.notPorted),
    Row("xfrm.bulge", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.elementMove", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.flare", "PushTool", false, Prov.notPorted),
    Row("xfrm.flex", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.jitter", "XfrmJitterTool", false, Prov.notPorted),
    Row("xfrm.linearAlignTool", "LinearAlignTool", false, Prov.notPorted),
    Row("xfrm.magnet", "MagnetTool", false, Prov.notPorted),
    Row("xfrm.push", "PushTool", false, Prov.notPorted),
    Row("xfrm.quantize", "XfrmQuantizeTool", false, Prov.notPorted),
    Row("xfrm.radialAlignTool", "RadialAlignTool", false, Prov.notPorted),
    Row("xfrm.scaleUniform", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.shear", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.smooth", "XfrmSmoothTool", false, Prov.notPorted),
    Row("xfrm.softDrag", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.softMove", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.softRotate", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.softScale", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.softTransform", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.swirl", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.taper", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.transform", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.twist", "XfrmTransformTool", true, Prov.carried),
    Row("xfrm.vortex", "XfrmTransformTool", true, Prov.carried),
];

/// The classes whose policy answers `activationRow`: the deleted marker's two
/// implementors plus the three cutting sessions (R3.5).
private immutable string[] kActivationRowClasses = [
    "tools.edit.topology_pen.tool.TopologyPenTool",
    "tools.slice.edge_slice_tool.EdgeSliceTool",
    "tools.slice.loop_slice_tool.LoopSliceTool",
    "tools.slice.slice_tool.SliceTool",
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
    assert(staticIds == 48 && presetIds == 22,
           format("M1 policy table: registry population changed: %s static + %s presets, "
                  ~ "measured 48 + 22", staticIds, presetIds));
    assert(kTable.length == 70 && classOf.length == 70,
           format("M1 policy table: %s table rows, %s registered ids, measured 70",
                  kTable.length, classOf.length));

    size_t falseRows, notPorted;
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
        // The production arm classifier: today it equals the field for every
        // registered id (the cutting-session id arm is redundant since M1).
        assert(toolArmEmitsLifecycle(t, row.id) == row.activationRow,
               format("M1 policy table: toolArmEmitsLifecycle(%s) is %s, table says %s",
                      row.id, !row.activationRow, row.activationRow));
        assert(row.activationRow == (row.prov == Prov.carried),
               "M1 policy table: provenance of " ~ row.id ~ " disagrees with its value");
        if (!row.activationRow) ++falseRows;
        if (row.prov == Prov.notPorted) ++notPorted;
    }
    // The M7 ratchet: ids whose arm writes no activation row yet.
    assert(falseRows == 42 && notPorted == 38,
           format("M1 policy table: activationRow=false on %s ids (%s not ported), "
                  ~ "recorded 42 (38)", falseRows, notPorted));
}

unittest { // (2) exactly five tool classes declare the activation row
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
    const nav = bodyAt(app, "bool navHistory(bool isUndo)");
    assert(nav.canFind("session.navigate(isUndo)") && !nav.canFind(".undo(")
           && !nav.canFind(".redo("),
           "M1 wiring census: app.d navHistory no longer ends at EditSession.navigate alone");

    auto router = blankNonCode(readText("source/input_router.d"));
    assert(router.canFind("navHistory(true)") && router.canFind("navHistory(false)"),
           "M1 wiring census: the key router no longer routes Ctrl+Z through navHistory");
    assert(!router.canFind(".undo(") && !router.canFind(".redo("),
           "M1 wiring census: the key router steps the history directly");

    auto es = blankNonCode(readText("source/edit_session.d"));
    const navigate = bodyAt(es, "bool navigate(bool isUndo)");
    inOrder(navigate, ["if (g_heldGestureButtons.any) return false;",
                       "return isUndo ? tools_.undo() : tools_.redo();"],
            "EditSession.navigate");
    const ts = bodyAt(es, "private struct ToolSession");
    // The branch order the navigate contract fixes, per direction.
    inOrder(bodyAt(ts, "bool undo()"),
            ["soleFirstGesture()", "tryUndoStepInSession()", "cancelUncommittedEdit()",
             "history_.undo()", "resyncSession()", "dropTool_()"],
            "ToolSession.undo");
    inOrder(bodyAt(ts, "bool redo()"),
            ["tryRedoLiveInSession()", "history_.redo()", "resyncSession()",
             "replayFirstGesture("],
            "ToolSession.redo");
    // Nothing else in the module steps the history.
    assert(es.count("history_.undo()") == 2 && es.count("history_.redo()") == 1,
           format("M1 wiring census: edit_session.d steps the history %s/%s times, "
                  ~ "expected undo 2 (ToolSession.undo, endSession_) and redo 1",
                  es.count("history_.undo()"), es.count("history_.redo()")));
}
