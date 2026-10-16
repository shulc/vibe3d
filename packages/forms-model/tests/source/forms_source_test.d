module forms_source_test;

import forms;
import vibe3d.editing.params.params : Param, ParamHints, choicesOf, fmtFloatWire;
import vibe3d.editing.params.argstring : parseArgstring;
import command_args : positionalArgs;
import std.json : JSONValue, JSONType;
import std.string : strip, splitLines;
import std.format : format;

version (unittest)
{
    unittest { // RowKind discriminator + makeControl payload
        auto r = Row.makeControl("tool.attr xfrm.transform TX ?", "X", "tx");
        assert(r.kind == RowKind.control);
        assert(r.command == "tool.attr xfrm.transform TX ?");
        assert(r.label == "X");
        assert(r.id == "tx");
        assert(r.showLabel);
        assert(r.booleanStyle == BooleanStyle.checkbox);
    }

    unittest { // group nests rows; choice carries entries
        auto g = Row.makeGroup("Position", [
            Row.makeControl("tool.attr xfrm.transform TX ?", "X"),
            Row.makeControl("tool.attr xfrm.transform TY ?", "Y"),
        ]);
        assert(g.kind == RowKind.group);
        assert(g.rows.length == 2);
        assert(g.groupStyle == GroupStyle.inline_);

        auto c = Row.makeChoice("Action Center", [
            ChoiceEntry("Auto",   "actr.auto"),
            ChoiceEntry("Select", "actr.select"),
        ]);
        assert(c.kind == RowKind.choice);
        assert(c.entries.length == 2);
        assert(c.entries[0].cmd == "actr.auto");
    }

    unittest { // divider / label / sub / ref kinds
        assert(Row.makeDivider().kind == RowKind.divider);
        assert(Row.makeLabel("hello").kind == RowKind.label);
        assert(Row.makeLabel("hello").label == "hello");
        assert(Row.makeSub("transform.main").formId == "transform.main");
        assert(Row.makeRef("toolprops.falloff").kind == RowKind.ref_);
    }

    unittest { // Form.matchesTool: filter-less never matches; list membership
        Form shared_;                       // no whenTool — id-lookup / sub-form
        assert(!shared_.matchesTool("anything"));

        Form stageForm;                     // stage form — not a tool form
        stageForm.whenStage = "falloff";
        assert(!stageForm.matchesTool("anything"));

        Form f;
        f.whenTool = ["xfrm.transform", "move"];
        assert(f.matchesTool("xfrm.transform"));
        assert(f.matchesTool("move"));
        assert(!f.matchesTool("scale"));
    }

    // --- binding parse ----------------------------------------------------

    unittest { // tool.attr round-trip: namespace + target + attr + query idx
        auto b = parseBinding("tool.attr xfrm.transform TX ?");
        assert(b.commandId == "tool.attr");
        assert(b.namespace == Namespace.tool);
        assert(b.targetId  == "xfrm.transform");
        assert(b.attr      == "TX");
        assert(b.hasQuery);
        assert(b.queryIdx  == 2);
        assert(b.positionals == ["xfrm.transform", "TX", "?"]);
    }

    unittest { // tool.pipe.attr -> stage namespace
        auto b = parseBinding("tool.pipe.attr falloff start ?");
        assert(b.namespace == Namespace.stage);
        assert(b.targetId  == "falloff");
        assert(b.attr      == "start");
        assert(b.hasQuery);
    }

    unittest { // bool attr binds the same way as a float attr
        auto b = parseBinding("tool.attr xfrm.transform T ?");
        assert(b.namespace == Namespace.tool);
        assert(b.attr == "T");
        assert(b.hasQuery);
    }

    unittest { // plain command (choice/cmd entry) -> command namespace, no query
        auto b = parseBinding("actr.auto");
        assert(b.commandId == "actr.auto");
        assert(b.namespace == Namespace.command);
        assert(!b.hasQuery);
        assert(b.queryIdx == -1);
        assert(b.attr.length == 0);
    }

    unittest { // malformed: empty / blank line throws
        bool threw = false;
        try parseBinding("   "); catch (BindingException) threw = true;
        assert(threw);
    }

    unittest { // malformed: two '?' placeholders throws
        bool threw = false;
        try parseBinding("tool.attr xfrm.transform ? ?");
        catch (BindingException) threw = true;
        assert(threw);
    }

    unittest { // malformed: tool.attr value bind missing its '?' throws
        bool threw = false;
        try parseBinding("tool.attr xfrm.transform TX");
        catch (BindingException) threw = true;
        assert(threw);
    }

    unittest { // malformed: tool.attr with the '?' not in the value slot throws
        bool threw = false;
        try parseBinding("tool.attr xfrm.transform ? TX");
        catch (BindingException) threw = true;
        assert(threw);
    }

    // --- widget-class decision -------------------------------------------

    unittest { // datatype -> widget table (no overrides)
        ParamHints none;
        assert(widgetForKind(Param.Kind.Bool,    none) == WidgetKind.checkbox);
        assert(widgetForKind(Param.Kind.Int,     none) == WidgetKind.dragInt);
        assert(widgetForKind(Param.Kind.Float,   none) == WidgetKind.dragFloat);
        assert(widgetForKind(Param.Kind.Enum,    none) == WidgetKind.combo);
        assert(widgetForKind(Param.Kind.IntEnum, none) == WidgetKind.combo);
        assert(widgetForKind(Param.Kind.String,  none) == WidgetKind.text);
        assert(widgetForKind(Param.Kind.Vec3_,   none) == WidgetKind.vec3);
        assert(widgetForKind(Param.Kind.IntArray, none) == WidgetKind.none);

        ParamHints sl; sl.widget = ParamHints.Widget.Slider;
        assert(widgetForKind(Param.Kind.Int,   sl) == WidgetKind.sliderInt);
        assert(widgetForKind(Param.Kind.Float, sl) == WidgetKind.sliderFloat);
    }

    // --- resolver against a synthetic provider ---------------------------

    // Build a small fake provider universe by hand (no running app). Mirrors
    // the real XfrmTransformTool attr names so the test reads naturally.
    version (unittest)
    private Param[] fakeTransformParams(ref bool flagT, ref float tx,
                                        ref float ty, ref int seg,
                                        ref string mode, ref float dist)
    {
        import vibe3d.editing.params.params : IntEnumEntry;
        return [
            Param.bool_  ("T",  "Translate",   &flagT, true),
            Param.float_ ("TX", "Translate X", &tx, 0.0f),
            Param.float_ ("TY", "Translate Y", &ty, 0.0f),
            Param.int_   ("seg","Segments",    &seg, 1),
            Param.enum_  ("mode", "Mode", &mode,
                          [["offset","Offset"], ["width","Width"]], "offset"),
            Param.float_ ("dist", "Distance", &dist, 0.5f),
        ];
    }

    unittest { // a control line resolves to the right attr, kind, widget
        bool flagT = true; float tx = 1.5f, ty = 0; int seg = 2;
        string mode = "width"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto rc = resolveControl(
            Row.makeControl("tool.attr xfrm.transform TX ?"), prov);
        assert(rc.found);
        assert(rc.param.name == "TX");
        assert(rc.param.kind == Param.Kind.Float);
        assert(rc.widget == WidgetKind.dragFloat);
        assert(rc.choices.length == 0);
    }

    unittest { // bool attr -> checkbox by default, button under booleanStyle
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "offset"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto cb = resolveControl(
            Row.makeControl("tool.attr xfrm.transform T ?"), prov);
        assert(cb.found);
        assert(cb.widget == WidgetKind.checkbox);

        auto r = Row.makeControl("tool.attr xfrm.transform T ?");
        r.booleanStyle = BooleanStyle.button;
        auto bt = resolveControl(r, prov);
        assert(bt.widget == WidgetKind.button);
    }

    unittest { // enum attr -> combo + choices come from the Param, not YAML
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "width"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto rc = resolveControl(
            Row.makeControl("tool.attr xfrm.transform mode ?"), prov);
        assert(rc.found);
        assert(rc.widget == WidgetKind.combo);
        assert(rc.choices.length == 2);
        assert(rc.choices[0] == ["offset", "Offset"]);
        assert(rc.choices[1] == ["width", "Width"]);
    }

    unittest { // absent attr -> found=false (runtime-hidden, no throw)
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "offset"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto rc = resolveControl(
            Row.makeControl("tool.attr xfrm.transform NOPE ?"), prov);
        assert(!rc.found);
        assert(rc.widget == WidgetKind.none);
    }

    unittest { // style override: force slider / drag on a Float
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "offset"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        auto sl = Row.makeControl("tool.attr xfrm.transform dist ?");
        sl.style = ControlStyle.slider;
        assert(resolveControl(sl, prov).widget == WidgetKind.sliderFloat);

        auto dr = Row.makeControl("tool.attr xfrm.transform seg ?");
        dr.style = ControlStyle.slider;
        assert(resolveControl(dr, prov).widget == WidgetKind.sliderInt);
    }

    unittest { // non-control rows do not resolve a value
        bool flagT = true; float tx = 0, ty = 0; int seg = 1;
        string mode = "offset"; float dist = 0.5f;
        auto prov = fakeTransformParams(flagT, tx, ty, seg, mode, dist);

        // a cmd row carries no '?' — resolveControl returns not-found
        assert(!resolveControl(Row.makeCmd("actr.auto", "Auto"), prov).found);
        // a divider is not a value bind
        assert(!resolveControl(Row.makeDivider(), prov).found);
    }

    // --- write-path serialization (Phase 4) ------------------------------

    unittest { // float token uses %g (byte-identical to argstring._fmtFloat)
        assert(valueToArgToken(JSONValue(1.5))   == "1.5");
        assert(valueToArgToken(JSONValue(1.0))   == "1");      // %g drops .0
        assert(valueToArgToken(JSONValue(0.001)) == "0.001");
    }

    unittest { // cross-module byte-identity (task 0409): valueToArgToken vs.
        // argstring.serializeParams for the pinned float set. Both now
        // funnel through params.fmtFloatWire (fmtFloatG / argstring.
        // _fmtFloat are thin delegates) — this exercises the real
        // cross-module dependency rather than the hand-synced literals in
        // the test just above (which stays as-is per task 0409's contract).
        import vibe3d.editing.params.argstring : serializeParams;
        immutable float[] vals = [0.0f, 1.0f, -1.0f, 0.5f, 1e-7f, -3.25f,
                                   1e20f, 123456.789f, 0.1f];
        foreach (v; vals) {
            float f = v;
            // default deliberately != any pinned value so isUserSet is
            // always true and serializeParams always emits "w:<token>".
            auto p = Param.float_("w", "W", &f, float.nan);
            string viaArgstring = serializeParams([p]);
            string viaForms     = valueToArgToken(JSONValue(cast(double)v));
            assert(viaArgstring == "w:" ~ viaForms,
                   viaArgstring ~ " vs w:" ~ viaForms);
        }
    }

    unittest { // bool / int / string tokens
        assert(valueToArgToken(JSONValue(true))  == "true");
        assert(valueToArgToken(JSONValue(false)) == "false");
        assert(valueToArgToken(JSONValue(42))    == "42");
        assert(valueToArgToken(JSONValue("offset")) == "offset");
    }

    unittest { // substituteQuery reconstructs a tool.attr write line
        auto b = parseBinding("tool.attr xfrm.transform TX ?");
        auto line = substituteQuery(b, JSONValue(1.5));
        assert(line == "tool.attr xfrm.transform TX 1.5", line);
    }

    unittest { // substituteQuery: bool checkbox write
        auto b = parseBinding("tool.attr xfrm.transform T ?");
        assert(substituteQuery(b, JSONValue(true))
               == "tool.attr xfrm.transform T true");
    }

    unittest { // substituteQuery: stage namespace round-trip
        auto b = parseBinding("tool.pipe.attr falloff start ?");
        assert(substituteQuery(b, JSONValue(0.25))
               == "tool.pipe.attr falloff start 0.25");
    }

    unittest { // substituteQuery: an enum tag that needs no quoting
        auto b = parseBinding("tool.attr prim.sphere axis ?");
        assert(substituteQuery(b, JSONValue("x"))
               == "tool.attr prim.sphere axis x");
    }

    unittest { // round-trip: the substituted line re-parses to the same args
        auto b = parseBinding("tool.attr xfrm.transform TX ?");
        auto line = substituteQuery(b, JSONValue(2.75));
        auto p = parseArgstring(line);
        assert(p.commandId == "tool.attr");
        auto pos = positionalArgs(p.params);
        assert(pos.length == 3);
        assert(pos[0].str == "xfrm.transform");
        assert(pos[1].str == "TX");
        double n = pos[2].type == JSONType.float_ ? pos[2].floating
                 : cast(double) pos[2].integer;
        assert(n > 2.74 && n < 2.76);
    }

    unittest { // currentEnumTag reads the live Enum tag through *sptr
        string mode = "width";
        auto p = Param.enum_("mode", "Mode", &mode,
                             [["offset","Offset"], ["width","Width"]], "offset");
        assert(currentEnumTag(p) == "width");
    }

    unittest { // stage-namespace binding resolves against a stage's params()
        // The resolver is namespace-agnostic: it takes whatever Param[] the
        // caller hands it. Here we stand in for a falloff stage's params().
        float start = 0.1f, end_ = 0.9f;
        Param[] stageParams = [
            Param.float_("start", "Start", &start, 0.0f),
            Param.float_("end",   "End",   &end_,  1.0f),
        ];
        auto b = parseBinding("tool.pipe.attr falloff start ?");
        assert(b.namespace == Namespace.stage);
        auto rc = resolveBinding(b, stageParams);
        assert(rc.found);
        assert(rc.param.name == "start");
        assert(rc.widget == WidgetKind.dragFloat);
    }
}
