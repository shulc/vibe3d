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
import tool         : CommandClose, OpensAt, Tool, ToolSessionPolicy;
import tool_presets : loadToolPresets;
import tests.unit.census_symbols : blankNonCode;

import core.memory  : GC;
import std.algorithm : canFind, count, sort;
import std.array     : array;
import std.file      : readText;
import std.format    : format;
import std.json      : parseJSON;
import std.regex     : matchFirst, regex;
import std.string    : indexOf, startsWith, strip;

private enum Prov { carried, notPorted, noCounterpart, uncertain }

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

/// Measured 2026-09-25 on the M1 tree: 70 ids (48 static + 22 presets).
private immutable Row[] kTable = [
    Row("ElementMove", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("Transform", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("TransformMove", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("TransformRotate", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("TransformScale", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("edge.bevel", "EdgeBevelTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("edge.extend", "EdgeExtendTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.captured),
    Row("edge.extrude", "EdgeExtrudeTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("edge.slide", "EdgeSlideTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.arrayTool", "ArrayTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.bridgeTool", "BridgeTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.clone", "CloneTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.dragWeld", "DragWeldTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.edgeSliceTool", "EdgeSliceTool", true, Prov.carried, CommandClose.uiDoor, CloseProv.captured),
    Row("mesh.loopSliceTool", "LoopSliceTool", true, Prov.carried, CommandClose.uiDoor, CloseProv.captured),
    Row("mesh.mirrorTool", "MirrorTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.polyInsetTool", "PolyInsetTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.radialArrayTool", "RadialArrayTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.radialSweepTool", "RadialSweepTool", false, Prov.uncertain, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.reduceTool", "ReductionTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.sliceTool", "SliceTool", true, Prov.carried, CommandClose.uiDoor, CloseProv.captured),
    Row("mesh.smoothShiftTool", "SmoothShiftTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.tack", "TackTool", false, Prov.noCounterpart, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.thickenTool", "SmoothShiftTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.topoPen", "TopologyPenTool", true, Prov.carried, CommandClose.none, CloseProv.notCaptured),
    Row("mesh.vertexBevel", "VertexBevelTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("mesh.vertexExtrude", "VertexExtrudeTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("move", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("move.element", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("pen", "PenTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("poly.bevel", "PolyBevelTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.captured),
    Row("poly.extrude", "PolyExtrudeTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
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
    Row("vert.merge", "VertexMergeTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("xfrm.bend", "BendTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.bulge", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.elementMove", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.flare", "PushTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.flex", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.jitter", "XfrmJitterTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("xfrm.linearAlignTool", "LinearAlignTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.magnet", "MagnetTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("xfrm.push", "PushTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.quantize", "XfrmQuantizeTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
    Row("xfrm.radialAlignTool", "RadialAlignTool", false, Prov.notPorted, CommandClose.none, CloseProv.notCaptured),
    Row("xfrm.scaleUniform", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.shear", "XfrmTransformTool", true, Prov.carried, CommandClose.allDoors, CloseProv.carriedScript),
    Row("xfrm.smooth", "XfrmSmoothTool", false, Prov.notPorted, CommandClose.uiDoor, CloseProv.inferred),
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
    size_t[3] closeCount;
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
        assert(row.activationRow == (row.prov == Prov.carried),
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
    }
    // Measured on the M2 tree (`grep -c 'CommandClose.<value>, CloseProv'` over this file).
    assert(closeCount == [22, 24, 24],
           format("M2 policy table: commandClose none/uiDoor/allDoors on %s ids, recorded "
                  ~ "22/24/24", closeCount));
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
    inOrder(bodyAt(ts, "bool undo()"),
            ["undoFirstGroup_(t)", "tryUndoStepInSession()", "cancelUncommittedEdit()",
             "history_.undo()", "resyncSession()", "endsToolOnUndo("],
            "ToolSession.undo");
    inOrder(bodyAt(ts, "bool redo()"),
            ["applyAttrImage(img)", "tryRedoLiveInSession()", "history_.redo()",
             "resyncSession()", "replayFirstGroup_()"],
            "ToolSession.redo");
    // Nothing else in the module steps the history.
    assert(es.count("history_.undo()") == 2 && es.count("history_.redo()") == 1,
           format("M1 wiring census: edit_session.d steps the history %s/%s times, "
                  ~ "expected undo 2 (ToolSession.undo, undoFirstGroup_) and redo 1",
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
}

/// Measured on the M3 tree. Provenance: `opensAt` — M0 H1 (Edge Slice and Slice
/// open at the press, Loop Slice at its arm, C-H1-es / C-H1-ls); `noClone` —
/// the static flags read (Edge Slice only); the images — plan R4.3 plus
/// `count` (C-H2-ls-insert P1) and Loop Slice's seed set (PLAN-FINDING, card M3).
private immutable StepRow[] kStepTable = [
    StepRow("mesh.edgeSliceTool", OpensAt.firstPress, true,
            ["chain", "edges", "activePoint"]),
    StepRow("mesh.loopSliceTool", OpensAt.arm, false,
            ["positions", "current", "count", "seeds", "armedSelFaces"]),
    StepRow("mesh.sliceTool", OpensAt.firstPress, false,
            ["startX", "startY", "startZ", "endX", "endY", "endZ", "vectorX", "vectorY",
             "vectorZ", "axis", "gap", "frozenNormal", "haveFrozen", "axisLocked", "hasLine"]),
];

unittest { // (4)
    auto manifest = parseJSON(readText("tools/prepared_writer_manifest.json"));
    string[string] moduleOf;
    foreach (p; manifest["products"].array)
        moduleOf[p["aggregate"].str] = p["module"].str;
    string[] stepIds;
    size_t checkedNames, actionNames;
    foreach (row; kTable) {
        auto ci = TypeInfo_Class.find(moduleOf[row.cls] ~ "." ~ row.cls);
        auto t = blit(ci);
        const pol = t.sessionPolicy();
        if (!pol.sessionSteps) {
            assert(pol.imageAttrs.length == 0 && pol.haulAttrs.length == 0,
                   "M3 step table: " ~ row.id ~ " declares an image without sessionSteps");
            continue;
        }
        // Only these three: `params()` of a blitted (unconstructed) instance
        // is safe for them (field addresses only), not for every tool.
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
        stepIds ~= row.id;
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
        bool found;
        foreach (sr; kStepTable) {
            if (sr.id != row.id) continue;
            found = true;
            assert(pol.opensAt == sr.opensAt && pol.noClone == sr.noClone
                   && pol.imageAttrs == sr.imageAttrs,
                   format("M3 step table: %s policy {opensAt %s, noClone %s, image %s}, table "
                          ~ "says {%s, %s, %s}", row.id, pol.opensAt, pol.noClone, pol.imageAttrs,
                          sr.opensAt, sr.noClone, sr.imageAttrs));
        }
        assert(found, "M3 step table: " ~ row.id ~ " has sessionSteps but no step-table row");
    }
    // Population floors (measured): 3 ids, 23 image names, 3 Action triggers
    // on them (chainArm; insertAt, removeCurrent).
    sort(stepIds);
    assert(stepIds == ["mesh.edgeSliceTool", "mesh.loopSliceTool", "mesh.sliceTool"],
           format("M3 step table: sessionSteps ids %s", stepIds));
    assert(checkedNames == 23, format("M3 step table: %s image names checked, measured 23",
                                      checkedNames));
    assert(actionNames == 3, format("M3 step table: %s Action params on the three tools, "
                                    ~ "measured 3", actionNames));
}
