// The captured tool attribute bounds (task 9492, K-A3): the row overrides the
// declaration, clamps a value stored past it, and is read only at the
// interactive doors (the census below), never on a stored-state path.
module tests.unit.tool_attr_bounds_test;

import params : Param, ParamFlags;
import tool_attr_bounds : applyToolAttrBound, clampStoredToBounds, kToolAttrBounds;

unittest { // population floor: the table's row count, measured
    assert(kToolAttrBounds.length == 55, "rows: measured 55");
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

unittest { // the doors that read the table — and nothing else (a stored-state
           // path that read it would clamp what the reference stores as given)
    import std.file      : dirEntries, readText, SpanMode;
    import std.path      : buildPath, dirName, relativePath;
    import tests.unit.census_symbols : blankNonCode, countIdent;

    enum root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    size_t[string] uses;
    size_t scanned;
    foreach (de; dirEntries(buildPath(root, "source"), "*.d", SpanMode.depth)) {
        ++scanned;
        const n = countIdent(blankNonCode(readText(de.name)), "applyToolAttrBound");
        if (n) uses[relativePath(de.name, buildPath(root, "source"))] = n;
    }
    assert(scanned > 500, "scanned too few source files");
    // Positive control: the defining module itself (declaration only).
    assert(uses.get("tool_attr_bounds.d", 0) == 1, "definition not seen");
    uses.remove("tool_attr_bounds.d");
    // Each door imports the name once and calls it once.
    size_t[string] want = ["commands/tool/attr.d": 2, "forms_render.d": 2,
                           "property_panel.d": 2, "registry.d": 2];
    assert(uses == want, "applyToolAttrBound readers changed");
}
