// Forms-engine YAML loader + startup-strict validation tests (Phase 3).
//
// SOURCE-BACKED test: `import forms;` pulls forms.d (and its transitive
// params/argstring unittest blocks) into the `dmd -unittest -i` compile, so
// forms.d's own inline unittests run here too. The blocks below add the
// loader/validation coverage:
//
//   * loadFormsFromString round-trip: a valid YAML string parses into the
//     same Form tree a hand-built one (Phase 2 makeXxx) produces.
//   * Strict-validation NEGATIVE cases: unknown tool attr / unknown stage
//     attr / unknown command id / a control bound to a plain command all
//     throw FormValidationException with a useful message.
//   * Loader structural NEGATIVE cases: multi-`?` control, multi-kind row,
//     no-kind row, choice without entries — all throw FormLoadException.
//   * knownAttrs coverage: the FalloffStage full static list is a superset
//     of its type-filtered params() names for every falloff type.
//   * config/forms/transform.yaml itself loads + validates against a universe
//     mirroring the real XfrmTransformTool params + actr.* command ids.
//
// The validators are supplied as delegates (the same seam app.d wires to the
// live registry + pipeline), so this stays a pure compile — no running app.
//
// An HTTP aliveness assertion at the end proves the REAL boot validated the
// shipped transform.yaml: startup aborts on a forms-validation failure, so a
// responsive /api/camera means the on-disk config passed strict validation.

import forms;
import params : Param, ParamHints, IntEnumEntry;

import std.exception : assertThrown, collectExceptionMsg;
import std.algorithm : canFind;
import std.net.curl  : get;
import std.json      : parseJSON;

void main() {}

// ---------------------------------------------------------------------------
// Static universes for the validator delegates. These mirror the REAL tool /
// stage / command universe (XfrmTransformTool.params(), FalloffStage.knownAttrs(),
// actr.* ids) without booting the app.
// ---------------------------------------------------------------------------

private string[] transformUniverse() {
    return ["T", "R", "S", "TX", "TY", "TZ", "RX", "RY", "RZ", "SX", "SY", "SZ"];
}

private string[] falloffUniverse() {
    // The authoritative FalloffStage.knownAttrs() list.
    return [
        "type", "shape", "start", "end", "center", "size", "axis",
        "dist", "steps", "anchorRing", "connect", "mode", "screenCx", "screenCy",
        "screenSize", "transparent", "lassoStyle", "lassoPoly",
        "softBorder", "in", "out", "mix",
    ];
}

private string[] commandUniverse() {
    return ["actr.auto", "actr.select", "actr.element", "actr.local",
            "actr.origin", "mesh.flip",
            // Falloff form action buttons (Auto Size / Reverse).
            "falloff.autosize", "falloff.reverse"];
}

private FormValidators realisticValidators() {
    FormValidators v;
    v.toolAttrs = (string toolId) =>
        toolId == "xfrm.transform" ? transformUniverse() : null;
    v.stageAttrs = (string stageId) =>
        stageId == "falloff" ? falloffUniverse() : null;
    v.commandExists = (string cmdId) => commandUniverse().canFind(cmdId);
    return v;
}

// ---------------------------------------------------------------------------
// Loader round-trip: YAML string -> Form tree equality with a hand-built one.
// ---------------------------------------------------------------------------

unittest {
    enum yaml = q"YAML
forms:
  - id: transform.main
    label: Transform
    showLabel: false
    whenTool: xfrm.transform
    category: toolprops/main
    ordinal: 150.45
    rows:
      - { control: "tool.attr xfrm.transform T ?", label: Translate,
          booleanStyle: checkbox }
      - { divider: true }
      - group: Position
        style: inline
        rows:
          - { control: "tool.attr xfrm.transform TX ?", label: X }
          - { control: "tool.attr xfrm.transform TY ?", label: Y }
      - choice: "Action Center"
        entries:
          - { label: Auto,   cmd: "actr.auto" }
          - { label: Select, cmd: "actr.select" }
      - { ref: toolprops.falloff }
YAML";

    auto forms = loadFormsFromString(yaml);
    assert(forms.length == 1);

    auto f = forms[0];
    assert(f.id == "transform.main");
    assert(f.label == "Transform");
    assert(!f.showLabel);
    assert(f.whenTool == ["xfrm.transform"]);
    assert(f.category == "toolprops/main");
    assert(f.hasOrdinal);
    import std.math : fabs;
    assert(fabs(f.ordinal - 150.45) < 1e-9);

    // rows: control, divider, group(2 controls), choice(2 entries), ref
    assert(f.rows.length == 5);

    assert(f.rows[0].kind == RowKind.control);
    assert(f.rows[0].command == "tool.attr xfrm.transform T ?");
    assert(f.rows[0].label == "Translate");
    assert(f.rows[0].booleanStyle == BooleanStyle.checkbox);

    assert(f.rows[1].kind == RowKind.divider);

    auto grp = f.rows[2];
    assert(grp.kind == RowKind.group);
    assert(grp.label == "Position");
    assert(grp.groupStyle == GroupStyle.inline_);
    assert(grp.rows.length == 2);
    assert(grp.rows[0].command == "tool.attr xfrm.transform TX ?");
    assert(grp.rows[0].label == "X");

    auto ch = f.rows[3];
    assert(ch.kind == RowKind.choice);
    assert(ch.label == "Action Center");
    assert(ch.entries.length == 2);
    assert(ch.entries[0].label == "Auto");
    assert(ch.entries[0].cmd == "actr.auto");
    // entry label defaults to its cmd when omitted — exercise below.

    assert(f.rows[4].kind == RowKind.ref_);
    assert(f.rows[4].formId == "toolprops.falloff");
}

unittest { // whenTool as a list; choice entry label defaults to cmd; cmd row
    enum yaml = q"YAML
forms:
  - id: multi
    whenTool: [move, scale]
    rows:
      - { cmd: "mesh.flip", label: Flip }
      - choice: "Pick"
        entries:
          - { cmd: "actr.auto" }
YAML";
    auto forms = loadFormsFromString(yaml);
    auto f = forms[0];
    assert(f.whenTool == ["move", "scale"]);
    assert(f.matchesTool("move") && f.matchesTool("scale") && !f.matchesTool("x"));
    assert(f.rows[0].kind == RowKind.cmd);
    assert(f.rows[0].command == "mesh.flip");
    // entry with no explicit label falls back to its cmd string
    assert(f.rows[1].entries[0].label == "actr.auto");
}

// ---------------------------------------------------------------------------
// whenAttr visibility gate: parses onto ANY row kind (group / cmd), and strict
// validation fences a gate that names an attr outside the stage universe. This
// is the mechanism the falloff form uses to hide the Linear-only Auto Size +
// Reverse actions for non-Linear types (Screen / soft drag, Radial, ...).
// ---------------------------------------------------------------------------
unittest {
    enum yaml = q"YAML
forms:
  - id: toolprops.falloff
    whenStage: falloff
    rows:
      - group: "Auto Size"
        style: buttons
        whenAttr: start
        rows:
          - { cmd: "falloff.autosize x", label: X }
      - { cmd: "falloff.reverse", label: Reverse, whenAttr: start }
YAML";
    auto forms = loadFormsFromString(yaml);
    auto f = forms[0];
    assert(f.rows[0].kind == RowKind.group);
    assert(f.rows[0].whenAttr == "start", "group whenAttr should parse");
    assert(f.rows[1].kind == RowKind.cmd);
    assert(f.rows[1].whenAttr == "start", "cmd whenAttr should parse");
    // A gate naming a real stage attr passes strict validation.
    validateForms(forms, realisticValidators(), "whenAttr-ok");
}

unittest { // whenAttr naming an attr outside the stage universe throws
    enum yaml = q"YAML
forms:
  - id: toolprops.falloff
    whenStage: falloff
    rows:
      - { cmd: "falloff.reverse", label: Reverse, whenAttr: bogusAttr }
YAML";
    auto forms = loadFormsFromString(yaml);
    auto msg = collectExceptionMsg!FormValidationException(
        validateForms(forms, realisticValidators(), "whenAttr-bad"));
    assert(msg.canFind("whenAttr") && msg.canFind("bogusAttr"), msg);
}

// ---------------------------------------------------------------------------
// Loader structural negatives (FormLoadException).
// ---------------------------------------------------------------------------

unittest { // control line with two '?' placeholders
    enum yaml = q"YAML
forms:
  - id: bad
    rows:
      - { control: "tool.attr xfrm.transform ? ?" }
YAML";
    assertThrown!FormLoadException(loadFormsFromString(yaml));
}

unittest { // a row carrying two row-kind keys
    enum yaml = q"YAML
forms:
  - id: bad
    rows:
      - { control: "tool.attr xfrm.transform TX ?", divider: true }
YAML";
    auto msg = collectExceptionMsg!FormLoadException(loadFormsFromString(yaml));
    assert(msg.canFind("more than one row-kind"), msg);
}

unittest { // a row carrying no recognised row-kind key
    enum yaml = q"YAML
forms:
  - id: bad
    rows:
      - { tooltip: "orphan" }
YAML";
    auto msg = collectExceptionMsg!FormLoadException(loadFormsFromString(yaml));
    assert(msg.canFind("no recognised row-kind"), msg);
}

unittest { // choice row without entries
    enum yaml = q"YAML
forms:
  - id: bad
    rows:
      - { choice: "Empty" }
YAML";
    assertThrown!FormLoadException(loadFormsFromString(yaml));
}

unittest { // missing top-level 'forms' key
    assertThrown!FormLoadException(loadFormsFromString("nope: 1"));
}

// ---------------------------------------------------------------------------
// Startup-strict validation negatives (FormValidationException).
// ---------------------------------------------------------------------------

unittest { // unknown TOOL attr -> throws with attr + tool context
    enum yaml = q"YAML
forms:
  - id: bad
    whenTool: xfrm.transform
    rows:
      - { control: "tool.attr xfrm.transform NOPE ?" }
YAML";
    auto forms = loadFormsFromString(yaml);     // structurally valid
    auto msg = collectExceptionMsg!FormValidationException(
        validateForms(forms, realisticValidators(), "<t>"));
    assert(msg.canFind("unknown attr 'NOPE'"), msg);
    assert(msg.canFind("xfrm.transform"), msg);
}

unittest { // unknown STAGE attr -> throws (resolved against knownAttrs())
    enum yaml = q"YAML
forms:
  - id: bad
    rows:
      - { control: "tool.pipe.attr falloff WAT ?" }
YAML";
    auto forms = loadFormsFromString(yaml);
    auto msg = collectExceptionMsg!FormValidationException(
        validateForms(forms, realisticValidators(), "<t>"));
    assert(msg.canFind("unknown attr 'WAT'"), msg);
    assert(msg.canFind("falloff"), msg);
}

unittest { // a real-but-type-filtered stage attr validates OK (hide is runtime)
    // `start` is only in falloff.params() when type==Linear, but it IS in
    // knownAttrs() — so it must load+validate; the renderer hides it at
    // runtime when the active type doesn't expose it.
    enum yaml = q"YAML
forms:
  - id: ok
    rows:
      - { control: "tool.pipe.attr falloff start ?" }
      - { control: "tool.pipe.attr falloff dist ?" }
YAML";
    auto forms = loadFormsFromString(yaml);
    validateForms(forms, realisticValidators(), "<t>");   // must NOT throw
}

unittest { // unknown COMMAND id on a cmd row -> throws
    enum yaml = q"YAML
forms:
  - id: bad
    rows:
      - { cmd: "actr.nonexistent", label: Bogus }
YAML";
    auto forms = loadFormsFromString(yaml);
    auto msg = collectExceptionMsg!FormValidationException(
        validateForms(forms, realisticValidators(), "<t>"));
    assert(msg.canFind("unknown command 'actr.nonexistent'"), msg);
}

unittest { // unknown COMMAND id inside a choice entry -> throws
    enum yaml = q"YAML
forms:
  - id: bad
    rows:
      - choice: "AC"
        entries:
          - { label: Auto, cmd: "actr.auto" }
          - { label: Bad,  cmd: "actr.bogus" }
YAML";
    auto forms = loadFormsFromString(yaml);
    auto msg = collectExceptionMsg!FormValidationException(
        validateForms(forms, realisticValidators(), "<t>"));
    assert(msg.canFind("unknown command 'actr.bogus'"), msg);
}

unittest { // unknown TOOL id -> throws
    enum yaml = q"YAML
forms:
  - id: bad
    rows:
      - { control: "tool.attr no.such.tool TX ?" }
YAML";
    auto forms = loadFormsFromString(yaml);
    auto msg = collectExceptionMsg!FormValidationException(
        validateForms(forms, realisticValidators(), "<t>"));
    assert(msg.canFind("unknown tool 'no.such.tool'"), msg);
}

// ---------------------------------------------------------------------------
// knownAttrs coverage: the FalloffStage static universe is a superset of its
// per-type params() names. Exercised here against the live FalloffStage so the
// keep-in-sync comment in falloff.d is enforced by a test, not by convention.
// ---------------------------------------------------------------------------

unittest {
    import toolpipe.stages.falloff : FalloffStage;
    import toolpipe.packets : FalloffType, FalloffShape;
    import mesh     : Mesh;
    import editmode : EditMode;

    Mesh m;
    EditMode em = EditMode.Vertices;
    auto fs = new FalloffStage(() => &m, &em);

    auto universe = fs.knownAttrs();
    assert(universe.length > 0);

    // For every falloff TYPE, every name params() exposes must be in the
    // static universe. (params() also depends on shape, so flip Custom on to
    // surface the in/out tangent params too.)
    fs.shape = FalloffShape.Custom;
    foreach (t; [FalloffType.Linear, FalloffType.Radial, FalloffType.Screen,
                 FalloffType.Lasso, FalloffType.Cylinder, FalloffType.Element,
                 FalloffType.Selection]) {
        fs.type = t;
        foreach (ref p; fs.params())
            assert(universe.canFind(p.name),
                   "knownAttrs() missing params() attr '" ~ p.name
                   ~ "' for falloff type " ~ t.stringof);
    }
}

// ---------------------------------------------------------------------------
// The shipped config/forms/transform.yaml loads + validates against a universe
// mirroring the real tool/stage/command set. (Run from the repo root by the
// test harness, which cds into the vibe3d working dir.)
// ---------------------------------------------------------------------------

unittest {
    import std.file : exists;
    if (!exists("config/forms/transform.yaml"))
        return;   // harness ran from an unexpected cwd; HTTP test below still covers boot
    auto forms = loadForms("config/forms/transform.yaml");
    // Split into three per-bank forms (Position / Rotate / Scale) so each can
    // carry its own whenTool list (the ids whose T / R / S flag is enabled).
    assert(forms.length == 3);
    assert(forms[0].id == "transform.position");
    assert(forms[1].id == "transform.rotate");
    assert(forms[2].id == "transform.scale");
    validateForms(forms, realisticValidators(), "config/forms/transform.yaml");

    // ---- whenTool coverage: the reviewer finding's regression fence --------
    // Every XfrmTransformTool ACTIVATION id (toolbar move/rotate/scale, the
    // bare xfrm.transform, and the transform presets) must select the form for
    // each bank that id enables. A scalar `whenTool: xfrm.transform` left the
    // readable panel unrendered for all the other ids.
    g_forms = forms;
    scope(exit) g_forms = null;
    string[] formIds(string toolId) {
        string[] ids;
        foreach (ref f; formsForTool(toolId)) ids ~= f.id;
        return ids;
    }
    // Single-bank ids: exactly their one group.
    assert(formIds("move")   == ["transform.position"]);
    assert(formIds("rotate") == ["transform.rotate"]);
    assert(formIds("scale")  == ["transform.scale"]);
    // Per-mode + element presets: single bank each.
    assert(formIds("TransformMove")    == ["transform.position"]);
    assert(formIds("TransformRotate")  == ["transform.rotate"]);
    assert(formIds("TransformScale")   == ["transform.scale"]);
    assert(formIds("xfrm.elementMove") == ["transform.position"]);
    assert(formIds("ElementMove")      == ["transform.position"]);
    // Deform presets (base move/rotate/scale): single bank each.
    assert(formIds("xfrm.softMove")   == ["transform.position"]);
    assert(formIds("xfrm.twist")      == ["transform.rotate"]);
    assert(formIds("xfrm.taper")      == ["transform.scale"]);
    // T+R+S ids: all three groups, Position->Rotate->Scale order.
    assert(formIds("xfrm.transform") ==
           ["transform.position", "transform.rotate", "transform.scale"]);
    assert(formIds("Transform") ==
           ["transform.position", "transform.rotate", "transform.scale"]);
    assert(formIds("xfrm.flex") ==
           ["transform.position", "transform.rotate", "transform.scale"]);
    // A non-transform tool selects none of these forms.
    assert(formIds("prim.cube").length == 0);
    assert(formIds("xfrm.flare").length == 0);   // PushTool, deliberately excluded
}

// ---------------------------------------------------------------------------
// Phase 6: the shipped config/forms/falloff.yaml loads + validates. Every
// value row binds to a `tool.pipe.attr falloff <attr> ?` line and resolves
// against the FalloffStage static universe (knownAttrs()) — some of those
// attrs are type-filtered OUT of params() at runtime (Linear's start vs
// Radial's center), so loading against the static universe must NOT throw;
// the renderer hides absent rows at runtime instead.
// ---------------------------------------------------------------------------

unittest {
    import std.file : exists;
    if (!exists("config/forms/falloff.yaml"))
        return;   // harness ran from an unexpected cwd; HTTP test below covers boot
    auto forms = loadForms("config/forms/falloff.yaml");
    assert(forms.length >= 1);
    assert(forms[0].id == "toolprops.falloff");
    // No whenTool filter: it is a stage form, bound via whenStage and shown by
    // the per-stage formByStage("falloff") lookup — never by active tool.
    assert(forms[0].whenTool.length == 0);
    assert(forms[0].whenStage == "falloff");
    assert(forms[0].matchesStage("falloff"));
    assert(!forms[0].matchesTool("falloff"));
    validateForms(forms, realisticValidators(), "config/forms/falloff.yaml");

    // Every control/group-child binding in the shipped form must name a real
    // FalloffStage attr (the static universe) — a fence on hand-edits to the
    // YAML even from a cwd where the HTTP boot check below can't run.
    auto uni = falloffUniverse();
    void checkRow(ref Row r) {
        if (r.kind == RowKind.control) {
            auto b = parseBinding(r.command);
            assert(b.namespace == Namespace.stage && b.targetId == "falloff",
                "falloff form row should bind to the falloff stage: " ~ r.command);
            assert(uni.canFind(b.attr),
                "falloff form binds unknown attr '" ~ b.attr ~ "'");
        }
        foreach (ref c; r.rows) checkRow(c);
    }
    foreach (ref r; forms[0].rows) checkRow(r);
}

// ---------------------------------------------------------------------------
// Phase 6: a TEST-LOCAL falloff form with a deliberately-unknown stage attr
// throws under strict validation. (The SHIPPED file is proven clean above +
// by the boot aliveness check; this exercises the failure path against the
// SAME falloff universe without risking the on-disk config.)
// ---------------------------------------------------------------------------

unittest {
    enum yaml = q"YAML
forms:
  - id: toolprops.falloff
    rows:
      - { control: "tool.pipe.attr falloff start ?" }
      - { control: "tool.pipe.attr falloff bogusAttr ?" }
YAML";
    auto forms = loadFormsFromString(yaml);    // structurally valid
    auto msg = collectExceptionMsg!FormValidationException(
        validateForms(forms, realisticValidators(), "<falloff-typo>"));
    assert(msg.canFind("unknown attr 'bogusAttr'"), msg);
    assert(msg.canFind("falloff"), msg);
}

// ---------------------------------------------------------------------------
// Phase 6 WIRING: the per-stage Tool Properties loop resolves a stage form via
// formByStage(stageId) — matching ONLY a form that declared `whenStage:`. This
// is the regression fence for the id-mismatch blocker: the shipped falloff form
// has id "toolprops.falloff" but whenStage "falloff", so a stage-id lookup must
// go through whenStage, never the form id. Drives g_forms directly (the same
// registry the app populates at boot) so it needs no running app.
// ---------------------------------------------------------------------------

unittest {
    enum yaml = q"YAML
forms:
  - id: toolprops.falloff
    label: Falloff
    whenStage: falloff
    rows:
      - { control: "tool.pipe.attr falloff start ?" }
  - id: transform.main
    label: Transform
    whenTool: xfrm.transform
    rows:
      - { control: "tool.attr xfrm.transform T ?", label: Translate }
YAML";
    // Replace the process-wide loaded-forms registry for this assertion. Other
    // unittests in this binary don't read g_forms, so the clobber is safe.
    g_forms = loadFormsFromString(yaml);

    // formByStage matches the whenStage form by STAGE id ("falloff"), NOT by
    // the form's id ("toolprops.falloff"): the blocker was a stage-id lookup
    // that used the form id and silently returned null.
    auto sf = formByStage("falloff");
    assert(sf !is null, "formByStage('falloff') must resolve the whenStage form");
    assert(sf.id == "toolprops.falloff");
    assert(sf.whenStage == "falloff");

    // A stage id with no bound form resolves to null (the loop then falls back
    // to the legacy drawProvider).
    assert(formByStage("nonexistent") is null);

    // Symmetric safety: the stage form must NEVER leak into the per-tool lookup,
    // and the tool form must NEVER leak into the per-stage lookup. (Point 3 of
    // the review: matchesTool excludes whenStage forms; matchesStage requires
    // whenStage. The two lookups are disjoint.)
    auto toolHits = formsForTool("xfrm.transform");
    assert(toolHits.length == 1, "only the whenTool form matches the tool");
    assert(toolHits[0].id == "transform.main");
    // The form id of the falloff stage form is NOT a tool id and must not match.
    assert(formsForTool("toolprops.falloff").length == 0);
    assert(formsForTool("falloff").length == 0);
    // And the tool form is not reachable as a stage (its id resembles nothing,
    // but prove a tool form never answers a stage lookup).
    assert(formByStage("transform.main") is null);
    assert(formByStage("xfrm.transform") is null);

    g_forms = null;   // leave the registry empty for any later block
}

// ---------------------------------------------------------------------------
// Phase 6 WIRING: a whenStage form is matched by matchesStage and excluded from
// matchesTool — the pure struct-level invariant behind formByStage/formsForTool.
// ---------------------------------------------------------------------------

unittest {
    Form stageForm;
    stageForm.id = "toolprops.falloff";
    stageForm.whenStage = "falloff";
    assert(stageForm.matchesStage("falloff"));
    assert(!stageForm.matchesStage("other"));
    // A stage form is NOT a tool form even though it has an empty whenTool.
    assert(!stageForm.matchesTool("anything"));

    Form toolForm;
    toolForm.whenTool = ["xfrm.transform"];
    assert(toolForm.matchesTool("xfrm.transform"));
    assert(!toolForm.matchesStage("xfrm.transform"));   // never a stage

    Form sharedSub;                                     // neither filter
    // A filter-less form (shared sub-form pulled via sub/ref, or an
    // id-lookup form like layer.props) is NEVER auto-matched as a
    // top-level tool form — otherwise it would render in Tool Properties
    // INSTEAD of the active tool's own params() (app.d skips
    // PropertyPanel.draw whenever any form matches). Disjoint from
    // matchesStage by symmetry.
    assert(!sharedSub.matchesTool("anything"));
    assert(!sharedSub.matchesStage("anything"));
}

// ---------------------------------------------------------------------------
// Phase 6 WIRING: a whenStage form whose control targets a DIFFERENT stage, or
// names a non-live stage, fails strict validation (the boot-time contract fence
// added alongside formByStage).
// ---------------------------------------------------------------------------

unittest { // whenStage names an unknown (non-live) stage
    enum yaml = q"YAML
forms:
  - id: toolprops.ghost
    whenStage: ghost
    rows:
      - { control: "tool.pipe.attr ghost start ?" }
YAML";
    auto forms = loadFormsFromString(yaml);
    auto msg = collectExceptionMsg!FormValidationException(
        validateForms(forms, realisticValidators(), "<t>"));
    assert(msg.canFind("unknown pipe stage 'ghost'"), msg);
}

unittest { // whenStage form control targets a different stage than it binds
    // start IS a real falloff attr, but a whenStage:falloff form may only bind
    // tool.pipe.attr falloff — targeting another stage is a contract break.
    enum yaml = q"YAML
forms:
  - id: toolprops.falloff
    whenStage: falloff
    rows:
      - { control: "tool.attr xfrm.transform T ?" }
YAML";
    auto forms = loadFormsFromString(yaml);
    auto msg = collectExceptionMsg!FormValidationException(
        validateForms(forms, realisticValidators(), "<t>"));
    assert(msg.canFind("does not target that stage"), msg);
}

unittest { // declaring both whenTool and whenStage is rejected by the loader
    enum yaml = q"YAML
forms:
  - id: bad
    whenTool: move
    whenStage: falloff
    rows:
      - { control: "tool.pipe.attr falloff start ?" }
YAML";
    auto msg = collectExceptionMsg!FormLoadException(loadFormsFromString(yaml));
    assert(msg.canFind("both 'whenTool' and 'whenStage'"), msg);
}

// ---------------------------------------------------------------------------
// HTTP aliveness: a responsive server proves the REAL boot loaded + strict-
// validated the on-disk forms (startup aborts on a forms-validation failure).
// ---------------------------------------------------------------------------

unittest {
    auto response = get("http://localhost:8080/api/camera");
    auto json = parseJSON(response);
    assert("azimuth" in json, "server not responsive — forms validation may have aborted boot");
}

unittest { // rebindBindingTarget: live tool / live stage instance / literal
    // Tool-namespace control: the canonical family id is rebound to the live
    // tool id (move/rotate/…); stageId is irrelevant.
    auto t = parseBinding("tool.attr xfrm.transform TX ?");
    assert(t.namespace == Namespace.tool && t.targetId == "xfrm.transform");
    auto tr = rebindBindingTarget(t, "move", "falloff#1");
    assert(tr.targetId == "move" && tr.positionals[0] == "move",
        "tool binding must rebind to the live tool, ignoring stageId");

    // Stage-namespace control: the family stage id "falloff" is rebound to the
    // live stacked-instance id; activeToolId is irrelevant.
    auto s = parseBinding("tool.pipe.attr falloff center ?");
    assert(s.namespace == Namespace.stage && s.targetId == "falloff");
    auto sr = rebindBindingTarget(s, "move", "falloff#1");
    assert(sr.targetId == "falloff#1" && sr.positionals[0] == "falloff#1",
        "stage binding must rebind to the live instance, ignoring activeToolId");

    // Empty ids → the literal target is kept (single-stage / plain callers).
    assert(rebindBindingTarget(s, "", "").targetId == "falloff");
    assert(rebindBindingTarget(t, "", "").targetId == "xfrm.transform");
}

// ---------------------------------------------------------------------------
// P2 (per-item channels): a `layer.attr <index> <attr> ?` control line parses
// into the new Namespace.layer, extracts its attr like a tool.attr line, passes
// strict validateControlBinding (the boot-rejection case the opponent flagged —
// a layer.attr line classified as Namespace.command would throw at boot), and
// rebinds its placeholder index to the live layer index.
// ---------------------------------------------------------------------------

unittest { // layer.attr parses -> Namespace.layer + attr (mirrors tool.attr)
    auto b = parseBinding("layer.attr 0 pos.x ?");
    assert(b.commandId == "layer.attr");
    assert(b.namespace == Namespace.layer);
    assert(b.targetId  == "0");          // literal placeholder index
    assert(b.attr      == "pos.x");
    assert(b.hasQuery);
    assert(b.queryIdx  == 2);
    assert(b.positionals == ["0", "pos.x", "?"]);

    // The string-valued `name` row binds the same way.
    auto n = parseBinding("layer.attr 0 name ?");
    assert(n.namespace == Namespace.layer);
    assert(n.attr == "name");
}

unittest { // classifyNamespace maps layer.attr -> Namespace.layer (not command)
    assert(classifyNamespace("layer.attr")     == Namespace.layer);
    assert(classifyNamespace("tool.attr")      == Namespace.tool);
    assert(classifyNamespace("tool.pipe.attr") == Namespace.stage);
    assert(classifyNamespace("actr.auto")      == Namespace.command);
}

unittest { // validateControlBinding ACCEPTS a layer.attr line (boot does not abort)
    // A layer.attr control used to classify as Namespace.command and would
    // throw at boot under strict validation. With Namespace.layer on the
    // allow-list it validates clean. No layer-attr universe delegate is needed
    // (the runtime resolver hides an absent attr, like tool/stage rows).
    enum yaml = q"YAML
forms:
  - id: layer.props
    rows:
      - { control: "layer.attr 0 pos.x ?", label: X }
      - { control: "layer.attr 0 name ?",  label: Name }
YAML";
    auto forms = loadFormsFromString(yaml);   // structurally valid
    // Must NOT throw — the layer namespace is accepted by the strict pass.
    validateForms(forms, realisticValidators(), "<layer-props>");
}

unittest { // rebindBindingTarget overwrites the layer index placeholder
    auto b = parseBinding("layer.attr 0 pos.x ?");
    assert(b.namespace == Namespace.layer && b.targetId == "0");
    // The live layer index (as a string token) overwrites positionals[0].
    auto rb = rebindBindingTarget(b, "", "", "3");
    assert(rb.targetId == "3" && rb.positionals[0] == "3",
        "layer binding must rebind to the live layer index");
    // Tool / stage ids are irrelevant to a layer-namespace rebind.
    auto rb2 = rebindBindingTarget(b, "move", "falloff#1", "5");
    assert(rb2.targetId == "5" && rb2.positionals[0] == "5");
    // Empty layer index → the literal placeholder is kept.
    assert(rebindBindingTarget(b, "", "", "").targetId == "0");
}

unittest { // the shipped config/forms/layer_props.yaml loads + validates clean
    import std.file : exists;
    if (!exists("config/forms/layer_props.yaml"))
        return;   // harness ran from an unexpected cwd; HTTP boot check covers it
    auto forms = loadForms("config/forms/layer_props.yaml");
    assert(forms.length == 1);
    assert(forms[0].id == "layer.props");
    // Not a tool/stage form — selected by formById, so neither filter is set.
    assert(forms[0].whenTool.length == 0);
    assert(forms[0].whenStage.length == 0);
    // Strict validation must accept every layer.attr control line at boot.
    validateForms(forms, realisticValidators(), "config/forms/layer_props.yaml");

    // Every control binds to the layer namespace + names a LayerPropsProvider
    // attr (the static 14: pos/rot/scl/pivot components + name; visible is
    // deliberately omitted from this form).
    static immutable string[] layerAttrs = [
        "pos.x", "pos.y", "pos.z", "rot.x", "rot.y", "rot.z",
        "scl.x", "scl.y", "scl.z", "pivot.x", "pivot.y", "pivot.z", "name",
    ];
    void checkRow(ref Row r) {
        if (r.kind == RowKind.control) {
            auto b = parseBinding(r.command);
            assert(b.namespace == Namespace.layer,
                "layer form row must bind to the layer namespace: " ~ r.command);
            assert(layerAttrs.canFind(b.attr),
                "layer form binds unexpected attr '" ~ b.attr ~ "'");
        }
        foreach (ref c; r.rows) checkRow(c);
    }
    foreach (ref r; forms[0].rows) checkRow(r);
}
