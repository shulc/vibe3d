// FUNNEL PARITY (task 4062) — the same command line, entered through the
// keyboard door and through the HTTP door, binds to the same arguments.
//
// WHAT THE TWO DOORS ACTUALLY ARE, because that is the whole content of this
// test. The keyboard funnel (`input_router.runCommandWithArgs`) is handed an
// ARGSTRING — `"vertex add 3"` — parses it, and binds the resulting params
// object. The HTTP funnel (`http_providers.dispatchCommandLine`) is handed a
// JSON BODY — `{"_positional":["vertex","add",3]}`, or a bare `"vertex"`, or a
// named object — and binds that. Two different normalisations reaching one
// binder.
//
// WHY THE ROWS CARRY A WRITTEN-DOWN EXPECTATION rather than comparing the two
// results to each other. Both doors call `command_args.bindArgs`, so a test
// that only asserted `keyboard == http` would be green for any binder at all,
// including one that bound nothing — the two sides would agree perfectly on
// their shared mistake. That is the defect this project pays for most: a check
// satisfied by the broken code too. Each row therefore states the binding it
// expects, and BOTH doors are measured against it; the parity is then a
// consequence of two true statements rather than an assertion about a
// tautology.
//
// The expectation is `argstring.serializeParams` over the bound schema, which
// prints exactly the params whose value differs from their declared default —
// so a row that binds nothing prints "", and a row that binds the wrong slot
// prints the wrong name.
//
// THE MUTATION THIS TEST EXISTS FOR: swap two slots in one command's
// `params()` and this file reddens on that command's rows and no others.
module tests.unit.command_bindargs_parity_test;

import std.array  : join;
import std.format : format;
import std.json   : JSONValue, parseJSON;

import argstring   : parseArgstring, serializeParams;
import command     : Command;
import command_args : bindArgs;
import editmode    : EditMode;
import mesh        : Mesh;
import view        : View;

import commands.select.element   : SelectElementCommand;
import commands.select.drop      : SelectDropCommand;
import commands.select.type_from : SelectTypeFromCommand;
import commands.snap.mode        : SnapModeCommand;
import commands.prefs.trackball  : TrackballPrefCommand;
import commands.path.define      : PathDefineCommand;
import commands.ui.about         : UiAboutCommand;
import commands.ui.statistics    : UiStatisticsExpandCommand;
import commands.tool.attr        : ToolAttrCommand;
import commands.tool.pipe        : ToolPipeAttrCommand;
import commands.tool.host        : ToolHost;
import commands.falloff          : FalloffAddCommand;
import commands.file.load        : FileLoad;
import commands.workplane        : WorkplaneRotateCommand;
import commands.layer.commands   : LayerAttr;
import document                  : Document;
import mesh                      : makeCube;

private Mesh     gMesh;
private View     gView;
private EditMode gMode = EditMode.Vertices;
// `layer.attr` is a `LayerCommandBase`, so it needs a document to exist. It is
// never APPLIED here — binding is the whole subject — but the reference must be
// live, so the document is built once and shared.
private Document gDoc;

// Every command in the table below is constructible without an app: the ones
// that need a host take a default-constructed `ToolHost` (nothing here
// APPLIES a command — binding is the whole subject).
private Command build(string id) {
    ToolHost host;
    switch (id) {
        case "select.element":       return new SelectElementCommand(&gMesh, gView, gMode);
        case "select.drop":          return new SelectDropCommand(&gMesh, gView, gMode);
        case "select.typeFrom":      return new SelectTypeFromCommand(&gMesh, gView, gMode, &gMode);
        case "snap.mode":            return new SnapModeCommand(&gMesh, gView, gMode);
        case "pref.trackball":       return new TrackballPrefCommand(&gMesh, gView, gMode);
        case "path.define":          return new PathDefineCommand(&gMesh, gView, gMode);
        case "ui.about":             return new UiAboutCommand(&gMesh, gView, gMode);
        case "ui.statistics.expand": return new UiStatisticsExpandCommand(&gMesh, gView, gMode);
        case "tool.attr":            return new ToolAttrCommand(&gMesh, gView, gMode, host);
        case "tool.pipe.attr":       return new ToolPipeAttrCommand(&gMesh, gView, gMode, host);
        case "falloff.add":          return new FalloffAddCommand(&gMesh, gView, gMode, host);
        case "file.load":            return new FileLoad(&gMesh, gView, gMode, null);
        case "workplane.rotate":     return new WorkplaneRotateCommand(&gMesh, gView, gMode);
        case "layer.attr":
            if (gDoc.layers.length == 0) gDoc = Document.bootstrap(makeCube());
            return new LayerAttr(&gMesh, gView, gMode, &gDoc, null);
        default: assert(false, "parity table names an unbuildable command: " ~ id);
    }
}

/// What a bound command looks like: its argument values, plus whether the
/// payload marked it a read-back. Nothing else — this is a binding test.
///
/// A JSON-TEXT SLOT IS APPENDED VERBATIM, and that is the whole point of the
/// two rows it exists for. `Param.jsonArg_` is the escape hatch the positional
/// law reserves for a value that is FORWARDED into another schema, where the
/// argument's JSON TYPE — not its spelling — decides whether the write lands.
/// `serializeParams` cannot show that: it quotes any string that would re-parse
/// as a number, so a slot holding `1.5` and one holding `"1.5"` print
/// identically, and a row over them alone would be green for a binder that
/// stringified everything on the way through. Printing `name=<raw>` beside it
/// makes the two doors disagree visibly when one of them coerces.
private string describe(Command cmd) {
    auto ps = cmd.params();
    auto s  = serializeParams(ps);
    foreach (ref p; ps) {
        if (!p.jsonText_()) continue;
        s ~= format(" %s=<%s>", p.name, *p.sptr);
    }
    return cmd.isQuery() ? "?" ~ (s.length ? " " ~ s : "") : s;
}

private struct Row {
    string id;
    string argstr;    /// what the keyboard funnel is handed, after the id
    string jsonBody;  /// what the HTTP funnel is handed as `params`
    string expect;    /// the binding both must produce
}

// The rows. `select.element` sits deliberately in the MIDDLE: druntime stops a
// module at its first failed assert, so a mutation aimed at it leaves the rows
// above as an observation that they ran and passed.
private static immutable Row[] kRows = [
    // A one-slot command, in all three payload spellings the wire accepts.
    Row("select.drop",     "edge",  `{"_positional":["edge"]}`,   "type:edge"),
    Row("select.drop",     "edge",  `"edge"`,                     "type:edge"),
    Row("select.drop",     "edge",  `{"type":"edge"}`,            "type:edge"),
    Row("select.typeFrom", "polygon", `{"_positional":["polygon"]}`, "type:polygon"),

    // Two slots, and a NUMBER in a slot that declares a string: both doors
    // spell it the same way or the tool sees a different value on each.
    Row("pref.trackball",  "speed 1.5", `{"_positional":["speed",1.5]}`,
        `subject:speed value:"1.5"`),
    Row("ui.statistics.expand", "Vertices close",
        `{"_positional":["Vertices","close"]}`, "target:Vertices state:close"),
    Row("ui.about",        "toggle", `{"_positional":["toggle"]}`, "visible:toggle"),
    Row("snap.mode",       "component", `{"_positional":["component"]}`, "mode:component"),
    Row("falloff.add",     "linear", `{"_positional":["linear"]}`, "type:linear"),
    Row("path.define",     `"0,1,2" true`, `{"_positional":["0,1,2","true"]}`,
        `verts:"0,1,2" closed:"true"`),

    // The variable-length tail. This is the row a slot swap reddens.
    Row("select.element",  "vertex add 3 4 5",
        `{"_positional":["vertex","add",3,4,5]}`,
        "type:vertex action:add indices:<3>"),
    Row("select.element",  "polygon set 7",
        `{"_positional":["polygon","set",7]}`,
        "type:polygon action:set indices:<1>"),

    // The forwarding value slot. What the row pins here is the SLOT ORDER;
    // that its JSON TYPE survives (`1.5` reaching the tool's schema as a
    // number, not as text) is pinned in `command_bindargs_test.d`, because
    // `serializeParams` quotes any string that would re-parse as a number and
    // so cannot tell the two apart.
    Row("tool.attr", "xfrm.transform TX 1.5",
        `{"_positional":["xfrm.transform","TX",1.5]}`,
        `tool:xfrm.transform attr:TX value:"1.5" value=<1.5>`),
    // …and the stage attr, whose value is a STRING the stage parses, so the
    // same number is spelled out instead.
    Row("tool.pipe.attr", "falloff radius 2.5",
        `{"_positional":["falloff","radius",2.5]}`,
        `stage:falloff attr:radius value:"2.5"`),

    // Named-only arguments bind by name through both doors.
    Row("workplane.rotate", "axis:X angle:30", `{"axis":"X","angle":30}`,
        "axis:X angle:30"),
    Row("file.load", "path:/tmp/x.obj", `{"path":"/tmp/x.obj"}`, "path:/tmp/x.obj"),
    Row("file.load", "/tmp/x.obj", `{"_positional":["/tmp/x.obj"]}`, "path:/tmp/x.obj"),

    // The `?` read-back. Before task 4062 the keyboard door bound the literal
    // "?" as a VALUE and wrote it; only the HTTP door knew the idiom.
    Row("tool.attr", "xfrm.transform TX ?",
        `{"_positional":["xfrm.transform","TX","?"]}`,
        "? tool:xfrm.transform attr:TX value=<>"),
    Row("tool.pipe.attr", "falloff type ?",
        `{"_positional":["falloff","type","?"]}`,
        "? stage:falloff attr:type"),

    // THE SECOND FORWARDING COMMAND. `layer.attr` bends the law in the same
    // two ways `tool.attr` does and had no row at all: its value slot is a
    // `Param.jsonArg_` forwarded into the LAYER's schema, and its index slot is
    // a STRING because it accepts three shapes (an index, a comma list, and
    // absent-means-active) that only the command can tell apart. Both are
    // places a later reader would "simplify" the slot to an Int and silently
    // lose the gang form, so both get a row.
    Row("layer.attr", "0 pos.x 1.5", `{"_positional":["0","pos.x",1.5]}`,
        `index:"0" attr:pos.x value:"1.5" value=<1.5>`),
    Row("layer.attr", `"0,2" pos.x 9.5`, `{"_positional":["0,2","pos.x",9.5]}`,
        `index:"0,2" attr:pos.x value:"9.5" value=<9.5>`),
    Row("layer.attr", "0 name ?", `{"_positional":["0","name","?"]}`,
        `? index:"0" attr:name value=<>`),
    // A STRING value, and this pair is what makes the raw-text half of
    // `describe` DISCRIMINATE. On a number the two spellings coincide — `1.5`
    // is its own JSON text — so the rows above cannot tell a raw forward from a
    // stringifying one. `Ring` can: forwarded raw it is `"Ring"`, quotes and
    // all, and scalar-spelled it is `Ring`. That difference is the whole reason
    // these two slots are `Param.jsonArg_` and not `Param.string_`.
    Row("layer.attr", "0 name Ring", `{"_positional":["0","name","Ring"]}`,
        `index:"0" attr:name value:"\"Ring\"" value=<"Ring">`),
    Row("tool.attr", "xfrm.transform mode local",
        `{"_positional":["xfrm.transform","mode","local"]}`,
        `tool:xfrm.transform attr:mode value:"\"local\"" value=<"local">`),
    // …and the `targets` alias, which is the spelling a NAMED payload used
    // before the slot was declared.
    Row("layer.attr", `targets:"0,2" attr:pos.x value:9.5`,
        `{"targets":"0,2","attr":"pos.x","value":9.5}`,
        `index:"0,2" attr:pos.x value:"9.5" value=<9.5>`),
];

unittest {
    // Anti-vacuity first: a table that lost its rows would make every
    // assertion below true over an empty set.
    assert(kRows.length == 25,
           format("the parity table is 25 rows, found %d", kRows.length));

    // Every row is measured through BOTH doors and every mismatch is
    // collected, so one run names every row a mutation moved rather than
    // stopping at the first. (A `foreach` of bare asserts would stop at row 0
    // and say nothing about the other eighteen.)
    string[] bad;
    size_t   checked;
    foreach (i, ref r; kRows) {
        // ---- door 1: the keyboard funnel's normalisation ------------------
        // `runCommandWithArgs` re-joins the id and the baked argstring, parses
        // the line, and binds the params object it produces.
        auto viaKeys = build(r.id);
        auto parsed  = parseArgstring(r.id ~ " " ~ r.argstr);
        assert(parsed.commandId == r.id,
               format("row %d: the argstring parses to a different id", i));
        bindArgs(viaKeys, parsed.params);
        immutable gotKeys = describe(viaKeys);

        // ---- door 2: the HTTP funnel's normalisation ----------------------
        auto viaHttp = build(r.id);
        bindArgs(viaHttp, r.jsonBody);
        immutable gotHttp = describe(viaHttp);

        ++checked;
        if (gotKeys != r.expect)
            bad ~= format("row %d %s keyboard: expected `%s`, bound `%s`",
                          i, r.id, r.expect, gotKeys);
        if (gotHttp != r.expect)
            bad ~= format("row %d %s http: expected `%s`, bound `%s`",
                          i, r.id, r.expect, gotHttp);
        // The parity itself, stated separately from the two expectations so a
        // failure says WHICH of the three claims broke.
        if (gotKeys != gotHttp)
            bad ~= format("row %d %s: the two doors bound differently — `%s` vs `%s`",
                          i, r.id, gotKeys, gotHttp);
    }

    assert(checked == kRows.length, "the loop skipped a row");
    assert(bad.length == 0,
           format("%d parity finding(s):\n  %s", bad.length, bad.join("\n  ")));
}
