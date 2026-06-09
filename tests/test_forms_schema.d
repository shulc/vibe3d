// Pure-D schema/resolver tests for the forms engine (Phase 2).
//
// No HTTP, no running vibe3d, no ImGui. This is a SOURCE-BACKED test: the
// `import forms;` below pulls forms.d (and its transitive params/argstring
// unittest blocks) into the `dmd -unittest -i` compile, so all of forms.d's
// inline unittests run here too. The unittest blocks in THIS file add the
// integration-flavoured checks: assemble the actual transform.yaml form tree
// by hand and resolve every value row against a synthetic provider that
// mirrors XfrmTransformTool.params(), proving the binding parse + resolver +
// widget decision compose end-to-end without a running app.
//
// Source-backed tests run their unittest blocks at process startup (before
// main), so main() is intentionally empty.

import forms;
import params : Param, ParamHints, IntEnumEntry, choicesOf;

void main() {}

// ---------------------------------------------------------------------------
// A synthetic provider that mirrors the real XfrmTransformTool.params() attr
// set: T/R/S bool flags + TX..SZ floats. Storage lives in the caller's locals.
// ---------------------------------------------------------------------------
private Param[] transformLikeParams(
    ref bool t, ref bool r, ref bool s,
    ref float tx, ref float ty, ref float tz,
    ref float rx, ref float ry, ref float rz,
    ref float sx, ref float sy, ref float sz)
{
    return [
        Param.bool_ ("T",  "Translate",   &t, true),
        Param.bool_ ("R",  "Rotate",      &r, true),
        Param.bool_ ("S",  "Scale",       &s, true),
        Param.float_("TX", "Translate X", &tx, 0.0f),
        Param.float_("TY", "Translate Y", &ty, 0.0f),
        Param.float_("TZ", "Translate Z", &tz, 0.0f),
        Param.float_("RX", "Rotate X",    &rx, 0.0f).angle(),
        Param.float_("RY", "Rotate Y",    &ry, 0.0f).angle(),
        Param.float_("RZ", "Rotate Z",    &rz, 0.0f).angle(),
        Param.float_("SX", "Scale X",     &sx, 1.0f),
        Param.float_("SY", "Scale Y",     &sy, 1.0f),
        Param.float_("SZ", "Scale Z",     &sz, 1.0f),
    ];
}

// Build the v1 transform form tree by hand (the Position group + T/R/S
// checkboxes + an Action Center choice row), mirroring config/forms/transform.yaml
// as described in the plan's worked example. No YAML loader yet (Phase 3).
private Form transformForm()
{
    Form f;
    f.id = "transform.main";
    f.label = "Transform";
    f.showLabel = false;
    f.whenTool = ["xfrm.transform"];
    f.category = "toolprops/main";
    f.ordinal = 150.45;
    f.hasOrdinal = true;
    f.rows = [
        Row.makeControl("tool.attr xfrm.transform T ?", "Translate"),
        Row.makeControl("tool.attr xfrm.transform R ?", "Rotate"),
        Row.makeControl("tool.attr xfrm.transform S ?", "Scale"),
        Row.makeDivider(),
        Row.makeGroup("Position", [
            Row.makeControl("tool.attr xfrm.transform TX ?", "X"),
            Row.makeControl("tool.attr xfrm.transform TY ?", "Y"),
            Row.makeControl("tool.attr xfrm.transform TZ ?", "Z"),
        ]),
        Row.makeDivider(),
        Row.makeChoice("Action Center", [
            ChoiceEntry("Auto",    "actr.auto"),
            ChoiceEntry("Select",  "actr.select"),
            ChoiceEntry("Element", "actr.element"),
            ChoiceEntry("Local",   "actr.local"),
            ChoiceEntry("Origin",  "actr.origin"),
        ]),
        Row.makeRef("toolprops.falloff"),
    ];
    return f;
}

unittest { // the whole transform form resolves: every value row binds to a real attr
    bool t = true, r = true, s = true;
    float tx = 1.5f, ty = 0, tz = 0, rx = 0, ry = 0, rz = 0,
          sx = 1, sy = 1, sz = 1;
    auto prov = transformLikeParams(t, r, s, tx, ty, tz, rx, ry, rz, sx, sy, sz);

    auto form = transformForm();
    assert(form.matchesTool("xfrm.transform"));
    assert(!form.matchesTool("scale"));

    // The three flag checkboxes resolve to Bool -> checkbox.
    foreach (attr; ["T", "R", "S"]) {
        auto rc = resolveControl(
            Row.makeControl("tool.attr xfrm.transform " ~ attr ~ " ?"), prov);
        assert(rc.found, "flag " ~ attr ~ " must resolve");
        assert(rc.widget == WidgetKind.checkbox);
    }

    // The Position group's three children resolve to Float -> drag.
    auto grp = form.rows[4];
    assert(grp.kind == RowKind.group);
    assert(grp.rows.length == 3);
    foreach (child; grp.rows) {
        auto rc = resolveControl(child, prov);
        assert(rc.found);
        assert(rc.param.kind == Param.Kind.Float);
        assert(rc.widget == WidgetKind.dragFloat);
    }

    // TX carries the live value 1.5 through the typed pointer (paramToJson via
    // the resolved copy).
    auto txRc = resolveControl(
        Row.makeControl("tool.attr xfrm.transform TX ?"), prov);
    import params : paramToJson;
    import std.math : fabs;
    assert(fabs(paramToJson(txRc.param).floating - 1.5) < 1e-6);

    // Angle hint propagates through the SAME resolveControl path forms_render
    // uses to pick the drag step: rotate (RX) carries isAngle (→ 0.1/px default
    // step), while a positional float (TX) does not (→ 0.001/px). The resulting
    // ImGui drag SPEED is not headlessly observable, so we assert the hint that
    // drives it; the 0.1°/px feel itself is manual-verify.
    assert(txRc.param.hints.isAngle == false, "TX must NOT be an angle param");
    auto rxRc = resolveControl(
        Row.makeControl("tool.attr xfrm.transform RX ?"), prov);
    assert(rxRc.found);
    assert(rxRc.param.hints.isAngle, "RX must carry the angle hint");
}

unittest { // the Action Center choice row is fire-only — entries carry actr.* cmds
    auto form = transformForm();
    Row choice;
    foreach (row; form.rows)
        if (row.kind == RowKind.choice) { choice = row; break; }
    assert(choice.kind == RowKind.choice);
    assert(choice.label == "Action Center");
    assert(choice.entries.length == 5);
    // every entry's command classifies to the plain-command namespace (no '?')
    foreach (e; choice.entries) {
        auto b = parseBinding(e.cmd);
        assert(b.namespace == Namespace.command);
        assert(!b.hasQuery);
    }
}

unittest { // a row binding a non-existent attr is runtime-hidden, not an error
    bool t = true, r = true, s = true;
    float tx = 0, ty = 0, tz = 0, rx = 0, ry = 0, rz = 0, sx = 1, sy = 1, sz = 1;
    auto prov = transformLikeParams(t, r, s, tx, ty, tz, rx, ry, rz, sx, sy, sz);
    // pivot is NOT a real transform attr (deferred in the plan).
    auto rc = resolveControl(
        Row.makeControl("tool.attr xfrm.transform pivot ?"), prov);
    assert(!rc.found);
    assert(rc.widget == WidgetKind.none);
}
