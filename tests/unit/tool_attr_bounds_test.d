// The captured tool attribute bounds (task 9492, K-A3): the row overrides the
// declaration, clamps a value stored past it, and is read only at the
// attribute doors (the census below, `tool.set` arguments included), never on a
// restore path (presets, the attribute cache, remembered defaults, undo).
module tests.unit.tool_attr_bounds_test;

import params : Param, ParamFlags;
import tool_attr_bounds : applyToolAttrBound, clampStoredToBounds, kToolAttrBounds;
import toolpipe.stages.constrain;
import toolpipe.stage;

unittest { // population floor: the table's row count, measured
    assert(kToolAttrBounds.length == 65, "rows: measured 65");
}

unittest { // an axis row takes the number and clamps it; unarmed, the number is refused
    import params : IntEnumEntry, injectParamsInto;
    import std.exception : assertThrown;
    import std.json : parseJSON;
    static immutable IntEnumEntry[] xyz = [IntEnumEntry(0, "x", "X"),
        IntEnumEntry(1, "y", "Y"), IntEnumEntry(2, "z", "Z")];
    int axis = 1;
    auto p = Param.intEnum_("axis", "Axis", &axis, xyz, 1);
    auto bare = [p];
    auto five = parseJSON(`{"axis": 5}`), minus = parseJSON(`{"axis": -3}`);
    assertThrown(injectParamsInto(bare, five), "no row armed: 5 names no entry");
    assert(axis == 1);
    assert(applyToolAttrBound("prim.cone", p));
    auto armed = [p];
    injectParamsInto(armed, five);
    assert(axis == 2, "above the row's max");
    injectParamsInto(armed, minus);
    assert(axis == 0, "below the row's min");
}

unittest { // a two-sided int row arms the clamp; the panel re-clamp lands it
    int sides = 5000;
    auto p = Param.int_("sides", "Sides", &sides, 24);
    assert(applyToolAttrBound("prim.sphere", p));
    assert(p.hints.hasMinI && p.hints.minI == 3 && p.hints.hasMaxI && p.hints.maxI == 1024);
    assert((p.flags & ParamFlags.EnforceBounds) != 0);
    clampStoredToBounds(p);
    assert(sides == 1024, "above the row's max");
    sides = -7;
    clampStoredToBounds(p);
    assert(sides == 3, "below the row's min");
}

unittest { // a one-sided float row: the free side is stored as given
    float width = -2;
    auto p = Param.float_("width", "Width", &width, 0);
    assert(applyToolAttrBound("edge.bevel", p));
    clampStoredToBounds(p);
    assert(width == 0);
    width = 1e30f;
    clampStoredToBounds(p);
    assert(width == 1e30f, "no max on this row");
}

unittest { // the row REPLACES a declared bound, both sides
    float s = 100;
    auto p = Param.float_("smoothStrength", "Strength", &s, 1).min(0.5f).max(4.0f);
    assert(applyToolAttrBound("mesh.topoPen", p));
    assert(p.hints.minF == 0 && !p.hints.hasMaxF);
    clampStoredToBounds(p);
    assert(s == 100, "the declared max of 4 no longer applies");
}

unittest { // no row: the Param is left exactly as declared (negative control)
    int n = 9;
    auto p = Param.int_("sides", "Sides", &n, 24).min(5).max(8);
    assert(!applyToolAttrBound("prim.tube", p), "prim.tube has no row");
    auto q = Param.int_("order2", "", &n, 0);
    assert(!applyToolAttrBound("prim.sphere", q), "no row of that name");
    assert(p.hints.minI == 5 && p.hints.maxI == 8 && (p.flags & ParamFlags.EnforceBounds) == 0);
}

unittest { // the doors that read the table — and nothing else (a restore
           // path that read it would clamp what the reference stores as given)
    import std.file      : dirEntries, readText, SpanMode;
    import std.path      : buildPath, dirName, relativePath;
    import tests.unit.census_symbols : blankNonCode, countIdent;

    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    size_t[string] uses, reclamps;
    size_t scanned;
    foreach (de; dirEntries(buildPath(root, "source"), "*.d", SpanMode.depth)) {
        ++scanned;
        const code = blankNonCode(readText(de.name));
        const rel = relativePath(de.name, buildPath(root, "source"));
        if (const n = countIdent(code, "applyToolAttrBound")) uses[rel] = n;
        if (const n = countIdent(code, "clampStoredToBounds")) reclamps[rel] = n;
    }
    // The widget re-clamp: only the property panel writes the field directly.
    size_t[string] wantReclamp = ["tool_attr_bounds.d": 1, "property_panel.d": 2];
    assert(reclamps == wantReclamp, "clampStoredToBounds readers changed");
    assert(scanned > 500, "scanned too few source files");
    // Positive control: the defining module itself (declaration only).
    assert(uses.get("tool_attr_bounds.d", 0) == 1, "definition not seen");
    uses.remove("tool_attr_bounds.d");
    // Each door imports the name once and calls it once.
    size_t[string] want = ["commands/tool/attr.d": 2, "commands/tool/headless.d": 2, "commands/tool/pipe.d": 2,
                           "forms_render.d": 2, "prepared_tool_transition.d": 2,
                           "property_panel.d": 2, "registry.d": 2];
    assert(uses == want, "applyToolAttrBound readers changed");
}


unittest { // a stage row uses the same table; stored paths keep their values
    import params : parseInto;
    import toolpipe.stages.constrain : ConstrainStage;
    import toolpipe.attr_cache : recallNodeAttrs;
    auto cs = new ConstrainStage;
    cs.enabled = true;
    auto p = cs.fullParams()[2];
    assert(applyToolAttrBound(cs.id(), p), "constraint offset has no shared bound row");
    assert(parseInto(p, "-0.1") && cs.offset == 0,
           "constraint offset did not clamp at the shared bound");
    assert(parseInto(p, "1000000") && cs.offset == 1000000,
           "constraint offset acquired an upper bound");
    assert(cs.setAttr("offset", "-0.1") && cs.offset == -0.1f,
           "internal stage writes must preserve a stored negative offset");
    auto changed = recallNodeAttrs(cs, ["offset": "-0.2"], true);
    assert(changed == ["offset"] && cs.offset == -0.2f,
           "notifying stage recall clamped a stored negative offset");
}

private final class RefusingOffset : toolpipe.stages.constrain.ConstrainStage {
    string received;
    override bool setAttrImpl(string name, string value) {
        received = value;
        return false;
    }
}

unittest { // normalization respects a stage override's refusal boundary
    import commands.tool.pipe : ToolPipeAttrCommand;
    import commands.tool.host : ToolHost;
    import editmode : EditMode;
    import mesh : makeCube;
    import view : View;
    import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
    import std.exception : assertThrown;
    import std.conv : to;
    auto saved = g_pipeCtx;
    scope(exit) g_pipeCtx = saved;
    g_pipeCtx = new ToolPipeContext;
    auto stage = new RefusingOffset;
    g_pipeCtx.pipeline.add(stage);
    stage.offset = 0.75f;
    auto mesh = makeCube();
    auto view = new View(0, 0, 800, 600);
    auto command = new ToolPipeAttrCommand(&mesh, view, EditMode.Vertices, ToolHost.init);
    command.setStageId("constrain");
    command.setAttrName("offset");
    command.setAttrValue("-0.1");
    assertThrown!Exception(command.apply(), "the stage override's refusal was bypassed");
    assert(stage.received.length && stage.received.to!float == 0,
           "the stage setter did not receive the normalized offset");
    assert(stage.offset == 0.75f, "normalizing a refused write changed the live stage");
    command.setAttrValue("0.123456789");
    assertThrown!Exception(command.apply());
    assert(stage.received.to!float == 0.123456789f,
           "an in-range offset lost precision during normalization");
}

private final class AxisStageProbe : toolpipe.stage.Stage {
    int axis = 2;
    override string id() const { return "prim.cube"; }
    override ubyte ordinal() const { return toolpipe.stage.ordCons; }
    override Param[] params() {
        import params : IntEnumEntry;
        static immutable IntEnumEntry[] xyz = [IntEnumEntry(0, "x", "X"),
            IntEnumEntry(1, "y", "Y"), IntEnumEntry(2, "z", "Z")];
        return [Param.intEnum_("axis", "Axis", &axis, xyz, 2)];
    }
}

unittest { // numeric enum rows retain the wire tag the stage setter expects
    import commands.tool.pipe : ToolPipeAttrCommand;
    import commands.tool.host : ToolHost;
    import editmode : EditMode;
    import mesh : makeCube;
    import view : View;
    import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
    auto saved = g_pipeCtx;
    scope(exit) g_pipeCtx = saved;
    g_pipeCtx = new ToolPipeContext;
    auto stage = new AxisStageProbe;
    g_pipeCtx.pipeline.add(stage);
    auto mesh = makeCube();
    auto view = new View(0, 0, 800, 600);
    auto command = new ToolPipeAttrCommand(&mesh, view, EditMode.Vertices, ToolHost.init);
    command.setStageId(stage.id());
    command.setAttrName("axis");
    command.setAttrValue("y");
    assert(command.apply() && stage.axis == 1,
           "a normalized enum row lost its stage setter's wire tag");
}
