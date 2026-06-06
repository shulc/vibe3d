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
        "dist", "anchorRing", "connect", "mode", "screenCx", "screenCy",
        "screenSize", "transparent", "lassoStyle", "lassoPoly",
        "softBorder", "in", "out",
    ];
}

private string[] commandUniverse() {
    return ["actr.auto", "actr.select", "actr.element", "actr.local",
            "actr.origin", "mesh.flip"];
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
    auto fs = new FalloffStage(&m, &em);

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
    assert(forms.length >= 1);
    assert(forms[0].id == "transform.main");
    validateForms(forms, realisticValidators(), "config/forms/transform.yaml");
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
    assert(sharedSub.matchesTool("anything"));          // shared sub-form
    assert(!sharedSub.matchesStage("anything"));        // but not a stage form
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
