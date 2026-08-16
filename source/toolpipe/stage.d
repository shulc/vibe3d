module toolpipe.stage;

import params : Param, ParamProvider, parseInto, stringifyParam;

// ---------------------------------------------------------------------------
// Tool pipe task codes.
//
// Each stage in the pipe carries a TaskCode and an Ordinal. TaskCodes are
// FOURCC tags (`'A','C','E','N'`) packed into a uint for fast comparison;
// Ordinals are byte-sized priority keys that determine evaluation order
// (low → high).
//
// Stages out of vibe3d's modeling scope (paint / particle / UV / content
// / style / effector) keep their codes reserved for completeness but no
// stages registering against those codes ship in phase 7.
// ---------------------------------------------------------------------------

uint fourcc(char a, char b, char c, char d) pure nothrow @nogc {
    return (cast(uint)a << 24) | (cast(uint)b << 16)
         | (cast(uint)c <<  8) |  cast(uint)d;
}

enum TaskCode : uint {
    None = 0,
    Work    = 'W' << 24 | 'O' << 16 | 'R' << 8 | 'K',
    Symm    = 'S' << 24 | 'Y' << 16 | 'M' << 8 | 'M',
    Cont    = 'C' << 24 | 'O' << 16 | 'N' << 8 | 'T',
    Styl    = 'S' << 24 | 'T' << 16 | 'Y' << 8 | 'L',
    Snap    = 'S' << 24 | 'N' << 16 | 'A' << 8 | 'P',
    Cons    = 'C' << 24 | 'O' << 16 | 'N' << 8 | 'S',
    Acen    = 'A' << 24 | 'C' << 16 | 'E' << 8 | 'N',
    Axis    = 'A' << 24 | 'X' << 16 | 'I' << 8 | 'S',
    Path    = 'P' << 24 | 'A' << 16 | 'T' << 8 | 'H',
    Wght    = 'W' << 24 | 'G' << 16 | 'H' << 8 | 'T',
    Pink    = 'P' << 24 | 'I' << 16 | 'N' << 8 | 'K',
    Nozl    = 'N' << 24 | 'O' << 16 | 'Z' << 8 | 'L',
    Brsh    = 'B' << 24 | 'R' << 16 | 'S' << 8 | 'H',
    Ptcl    = 'P' << 24 | 'T' << 16 | 'C' << 8 | 'L',
    Side    = 'S' << 24 | 'I' << 16 | 'D' << 8 | 'E',
    Effr    = 'E' << 24 | 'F' << 16 | 'F' << 8 | 'R',
    Actr    = 'A' << 24 | 'C' << 16 | 'T' << 8 | 'R',
    Post    = 'P' << 24 | 'O' << 16 | 'S' << 8 | 'T',
}

// Default stage ordinals. Stored as ubyte so a Stage's `ordinal` field
// doubles as the sort key for Pipeline.evaluate. Stages
// can override their ordinal to insert themselves at a non-canonical
// position (e.g. an early-running snap variant) without touching the
// pipe's sort logic.
enum ubyte ordWork = 0x30;
enum ubyte ordSymm = 0x31;
enum ubyte ordCont = 0x38;
enum ubyte ordStyl = 0x39;
enum ubyte ordSnap = 0x40;
enum ubyte ordCons = 0x41;
enum ubyte ordAcen = 0x60;
enum ubyte ordAxis = 0x70;
enum ubyte ordPath = 0x80;
enum ubyte ordWght = 0x90;
enum ubyte ordPink = 0xB0;
enum ubyte ordNozl = 0xB1;
enum ubyte ordBrsh = 0xB2;
enum ubyte ordPtcl = 0xC0;
enum ubyte ordSide = 0xD0;
enum ubyte ordEffr = 0xD8;
enum ubyte ordActr = 0xF0;
enum ubyte ordPost = 0xF1;

// ---------------------------------------------------------------------------
// Stage — base class for a Tool Pipe stage.
//
// Stages live in a Pipeline (sorted by ordinal). For each evaluation, the
// pipe walks stages low → high and lets each one mutate the in-flight
// ToolState. Default `evaluate` is a no-op so registered-but-disabled
// stages have no effect.
//
// Phase-7.0 ships only the type system and a minimal-viable Pipeline; the
// concrete stages (Workplane, ActionCenter, Snap, Falloff, Symmetry, etc.)
// land in 7.1+ as subclasses of this base.
// ---------------------------------------------------------------------------
abstract class Stage : ParamProvider {
    abstract TaskCode taskCode() const pure nothrow @nogc @safe;
    abstract string   id()       const;
    abstract ubyte    ordinal()  const pure nothrow @nogc @safe;

    /// Restore every mutable field to the value a freshly-constructed
    /// stage would have. Called by SceneReset.apply (= the `/api/reset`
    /// command path) so a reset wipes pipeline state along with the
    /// mesh — otherwise toolpipe attrs (snap on, symmetry plane, falloff
    /// type, ACEN mode …) leak between tests and across user-driven
    /// "start fresh" actions. Default: no-op for stateless stages;
    /// stateful stages override.
    void reset() {}

    /// Whether this stage is currently REGISTERED-and-live in the pipe.
    /// Disabled stages are skipped during evaluation but stay in the pipe (the
    /// E column in the tool pipe panel).
    ///
    /// Renamed from `enabled` by task 0705 (audit 4, P8). It is a different
    /// boolean from the user-facing master toggles some stages own — SNAP's
    /// `enabled` (the X key), SYMMETRY's `enabled` — and those DERIVED fields
    /// shadowed this one rather than replacing it. Shadowing is silent both
    /// ways: `Stage`-typed code reading `s.enabled` got the pipe flag while
    /// `SnapStage`-typed code reading the same spelling got the user toggle,
    /// and app.d had to carry a paragraph explaining which was which at one of
    /// the three sites. The distinct name is what that paragraph was for.
    ///
    /// It also unblocked embedding the config as a sub-struct
    /// (`SnapConfig`/`FalloffConfig`): an `alias this` LOSES to an inherited
    /// member of the same name, so with both called `enabled` the alias would
    /// have silently redirected every `enabled` in and around SnapStage to
    /// this flag — which defaults to TRUE, i.e. snapping on with the toggle
    /// off. `FalloffConfig` escaped that only because it happens to have no
    /// field called `enabled`.
    bool pipeEnabled = true;

    // ------------------------------------------------------------------
    // Schema (Phase 7.9): typed `Param[]` registry — same shape as
    // `Tool.params()`. PropertyPanel renders this via the shared
    // ParamProvider interface so stage attrs appear in Tool Properties
    // alongside the active tool's params.
    //
    // The default `setAttr` / `listAttrs` below derive their behaviour
    // from this schema (string-parse / stringify per-Param.kind) so
    // concrete stages only override `params()` — no setAttr boilerplate.
    // Stages that need attrs outside the standard kinds (e.g. lasso
    // polygon arrays) override setAttr/listAttrs themselves.
    // ------------------------------------------------------------------
    Param[] params() { return []; }
    bool    paramEnabled(string name) const { return true; }
    void    onParamChanged(string name)      {}

    /// Full STATIC universe of Params this stage can accept via setAttr /
    /// tool.pipe.attr — the attr UNIVERSE, as opposed to `params()` which is
    /// the panel VISIBILITY filter over it (task 0184 / audit-2 C2). The base
    /// `knownAttrs()` / `defaultStageSetAttr` / `defaultStageListAttrs` below
    /// all derive from THIS, not `params()`, so a stage that filters
    /// `params()` for the Tool Properties panel (task 0167) still gets the
    /// full wire surface for free.
    ///
    /// Default: `params()` — i.e. universe == visible set, correct for any
    /// stage whose params() isn't filtered. A stage whose `params()` is
    /// filtered by an active mode/type (so it under-reports its full attr
    /// set) must EITHER override `fullParams()` to return the authoritative
    /// full list and re-express `params()` as a filter over it (Constrain's
    /// pattern — lets the base derive all three wire methods), OR hand-override
    /// `knownAttrs`/`setAttr`/`listAttrs` itself (Falloff/ACEN — they carry
    /// asymmetric read-only/array attrs the base derivation can't express, so
    /// they fully shadow the base and their `fullParams()` is unused). Do NOT
    /// leave a filtered `params()` with the base wire helpers still derived
    /// from it — that silently under-reports the universe.
    ///
    /// Self-containment invariant: `fullParams()` MUST NOT call `params()`
    /// (and vice-versa in a way that reintroduces the default) — the default
    /// `params()` returns `[]` and the default `fullParams()` returns
    /// `params()`, so a stage overriding only one side in terms of the other
    /// risks infinite recursion. Constrain's shape (fullParams() concrete,
    /// params() = a slice of fullParams()) is the safe pattern.
    Param[] fullParams() { return params(); }

    /// Full STATIC universe of attribute names this stage can accept via
    /// setAttr / tool.pipe.attr — used by the forms-engine startup-strict
    /// validator (`source/forms.d`) to reject a YAML typo against the union
    /// of everything a stage can EVER expose, not the currently-filtered
    /// `params()` list.
    ///
    /// Default: derive from `fullParams()` names. A stage whose full attr
    /// set includes attrs `fullParams()` can't express (array attrs,
    /// read-only/write-only/derived attrs, a non-Param status-bar-owned
    /// field) — and/or whose `setAttr` is a non-enumerable switch — MUST
    /// override this to return its authoritative full list. See
    /// ActionCenterStage.knownAttrs(): `cenX`/`userPlacedCenter`/
    /// `clusterCount` have no symmetric Param representation.
    string[] knownAttrs() {
        string[] names;
        foreach (ref p; fullParams())
            names ~= p.name;
        return names;
    }

    /// Header label for the stage's section in Tool Properties. Default
    /// = `id()` (wire key, e.g. "falloff"); concrete stages override
    /// for richer dynamic labels (e.g. "Linear Falloff" with the
    /// active type baked in). The wire key from id() stays canonical
    /// for HTTP / scripts; this is purely a UI presentation hook.
    string displayName() const { return id(); }

    /// Stage-family id for Tool Properties FORM lookup. Defaults to id(), so a
    /// stage's form is found by its own id. Stages that run as multiple
    /// same-task INSTANCES (e.g. stacked FalloffStage: "falloff", "falloff#1",
    /// …) override this to a shared family key ("falloff") so EVERY instance
    /// resolves the one config form; FormsPanel then filters its rows against
    /// the live instance's params() (per-type) and the write path rebinds the
    /// stage-namespace target to the instance's real id() (see app.d per-stage
    /// loop + forms_render.d stageId rebind).
    string formFamilyId() const { return id(); }

    /// Custom ImGui block rendered AFTER the schema-driven params()
    /// inside the stage's collapsible section in Tool Properties.
    /// Use for controls that don't fit a single Param (multi-button
    /// rows, popup menus, action-style buttons that mutate state but
    /// have no input field). Default no-op — opt in by overriding.
    void drawProperties() {}

    // ------------------------------------------------------------------
    // Attribute mutation (HTTP `tool.pipe.attr <stageId> <name> <value>`).
    //
    // Default impls inspect params() and parse `value` per the matching
    // Param's kind. Returning `false` signals "unknown attribute" to
    // the HTTP layer, which surfaces it as an error. Concrete stages
    // override only when they need attrs the standard kinds don't
    // cover (lasso polygon arrays, custom-formatted enums, etc.).
    //
    // listAttrs stringifies the same params() schema — used by the
    // `/api/toolpipe` inspection endpoint. Order matches params().
    // ------------------------------------------------------------------
    bool setAttr(string name, string value) {
        return defaultStageSetAttr(this, name, value);
    }
    string[2][] listAttrs() const {
        return defaultStageListAttrs(cast(Stage)this);
    }

    // ------------------------------------------------------------------
    // Slot ACTIVATION (task 0791).
    //
    // Some of a stage's attributes are not settings on the tool in its slot —
    // they say WHICH TOOL IS IN THE SLOT. Writing one of those is an
    // ACTIVATION, and an activation ends a held transform operation instead of
    // re-weighing it. Measured on the reference: re-issuing the tool ALREADY in
    // the slot ends the operation too, so the trigger is the WRITE, not a
    // difference in the value — which is why this is a counter and not a
    // comparison.
    //
    // `slotEpoch` is bumped ONLY from COMMAND sites (`tool.pipe.attr`, the
    // falloff / action-centre preset commands), never from a stage's internal
    // bookkeeping. That distinction is load-bearing: the same fields are also
    // written by the tool's own paths (a click-pick relocate, the softdrag
    // brush, an auto-relocate chain), and a counter that moved with those would
    // fire on the gesture it is meant to protect — the trap task 0724 fell into
    // with the falloff packet's picked centre.
    //
    // Nothing may depend on the absolute value: it is a change detector.
    // ------------------------------------------------------------------
    uint slotEpoch;

    /// Does writing `name` ARM this stage's slot (rather than adjust the tool
    /// already in it)? Default NO — a stage opts in. Snap deliberately stays
    /// out: measured on the reference, arming a snap tool leaves a held
    /// operation untouched (the pipe activation runs but opens no reflux
    /// bracket), which is the one slot that does not follow the rule.
    bool attrArmsSlot(string name) const { return false; }

    /// Record that the USER armed this slot. Called at command sites only.
    final void noteSlotArmed() { ++slotEpoch; }
}

// ---------------------------------------------------------------------------
// ToolSwitchTransient — marker for stages whose session config is TOOL-
// DRIVEN: a tool switch should wipe it UNLESS the user explicitly locked it
// in place (each implementor carries its own `userLocked`-style field and a
// `resetTransient()` that checks it before falling back to `reset()`).
// Implemented today by ActionCenterStage, AxisStage, ConstrainStage and
// FalloffStage (task 0980 / audit-4 P7).
//
// Persistent-config stages — Snap, Symmetry, Workplane, Path — do NOT
// implement this: their state is a user SETTING, not a tool session, and
// deliberately survives a tool switch (captured 2026-06-16, matches the
// reference editor).
//
// This replaced a hand-written `switch (s.id())` in app.d's
// `resetTransientPipeStages()` that matched three string literals
// ("actionCenter" / "axis" / "constrain") plus a separate `s.taskCode() ==
// TaskCode.Wght` branch for falloff. That shape has exactly one failure
// mode: a stage that SHOULD reset-on-switch but whose `id()` doesn't match
// one of the hardcoded literals (a renamed stage, or — the case WGHT
// already had to escape by matching on taskCode instead — a second same-
// task instance under a different id, e.g. a stacked "falloff#1") falls
// through the `default: break;` arm and is never reset again, silently, for
// the life of the process. `toolpipe.pipeline.resetToolSwitchTransientStages`
// walks every registered stage and dispatches by `cast(ToolSwitchTransient)`
// instead: a TYPE check, not a name/taskCode match, so it is exact for every
// instance of every implementor regardless of id() — including stacked
// same-task extras — and a stage that does NOT implement the interface is
// left alone (the same outcome a forgotten switch case gives today), rather
// than silently mis-firing either way.
// ---------------------------------------------------------------------------
interface ToolSwitchTransient {
    /// Same contract as `Stage.reset()` but respects the implementor's own
    /// `userLocked`-style flag. Called by
    /// `toolpipe.pipeline.resetToolSwitchTransientStages` (in turn called by
    /// app.d's `resetTransientPipeStages()`) on every tool activation.
    void resetTransient();
}

// ---------------------------------------------------------------------------
// Convenience: a "no-op" placeholder stage. Useful as a default insert
// for a task slot before a concrete stage is registered, and as a smoke
// test in tests/test_toolpipe_skeleton.d.
// ---------------------------------------------------------------------------
class NopStage : Stage {
    TaskCode    code_;
    string      id_;
    ubyte       ord_;

    this(TaskCode code, string id, ubyte ord) {
        code_ = code; id_ = id; ord_ = ord;
    }
    override TaskCode taskCode() const pure nothrow @nogc @safe { return code_; }
    override string   id()       const                          { return id_; }
    override ubyte    ordinal()  const pure nothrow @nogc @safe { return ord_; }
}

// ---------------------------------------------------------------------------
// Default schema-driven setAttr / listAttrs helpers — shared by Stage's
// default impls. Walk the params() registry, parse `value` per Param.kind
// for setAttr, stringify each Param's pointer-target for listAttrs.
//
// The actual Param<->string wire mechanics (parseInto/stringifyParam) live in
// `params.d` (task 0409 / 0407 D3) — they are generic Param mechanics with no
// toolpipe dependency; this Stage glue is just one of several callers (see
// params.d's doc comment on parseInto/stringifyParam for the others).
//
// Vec3-as-string format: "x,y,z" (matches `tool.pipe.attr falloff start
// 0,0.5,0` from the existing HTTP tests). Enum kind matches by wireTag
// (string for Param.Kind.Enum, intEnumValues.wireTag for IntEnum). Bool
// accepts true/false/1/0. Unknown attr name → return false.
// ---------------------------------------------------------------------------

bool defaultStageSetAttr(Stage s, string name, string value) {
    foreach (ref p; s.fullParams()) {
        if (p.name != name) continue;
        bool ok = parseInto(p, value);
        if (ok) s.onParamChanged(name);
        return ok;
    }
    return false;
}

string[2][] defaultStageListAttrs(Stage s) {
    string[2][] out_;
    foreach (ref p; s.fullParams())
        out_ ~= [p.name, stringifyParam(p)];
    return out_;
}

// ---------------------------------------------------------------------------
// Test support: the COMPLEMENT of the per-stage "every knownAttrs() name is
// settable" pins (task 0685 T1).
//
// Those pins assert `knownAttrs ⊆ accepted-by-setAttr`. That is the direction
// the defect was NOT in. The defect fixed in task 0678 P4 was an UNDER-reported
// universe — `applySetAttr` accepting a name `knownAttrs()` never mentions —
// and every forward pin stays green through it, while the forms-engine
// startup-strict validator (`source/forms.d`, which treats `knownAttrs()` as
// the stage's whole universe) throws on the first form that binds that name.
//
// The complement — `accepted-by-setAttr ⊆ knownAttrs` — cannot be asserted
// exhaustively: a hand-written `switch` is not enumerable at compile time, so
// there is no way to ask a stage "what names DO you accept?". What can be
// asserted is a PROBE: a corpus of names that a maintainer plausibly adds a
// `case` for, each of which must be rejected unless it is declared. The corpus
// is deliberately cross-stage — the realistic mistake is copying a `case` arm
// from a sibling stage and forgetting that the sibling also declares it — plus
// a handful of generic knob names.
//
// Weakening the corpus can only make this check miss a defect; it can never
// make it report a false one, because a name a stage DOES declare is skipped.
// So: when a stage gains an attr, nothing here needs touching; when a stage
// gains a `case` without the declaration, this fires.
//
// One stage shape is deliberately NOT a caller: FalloffStage carries ACTION
// pseudo-attrs (`autosize` / `reverse` / `lassoClear`) that `applySetAttr`
// accepts and `knownAttrs()` deliberately omits — they are fire-only `cmd`
// form rows, validated by forms.d as command ids rather than as attrs. A
// stage with that shape must either declare them or stay off this helper;
// pointing the probe at it would report a documented design as a defect.
// ---------------------------------------------------------------------------

version (unittest) {
    /// Attr names drawn from every shipping pipe stage (snap / falloff /
    /// action-centre / workplane / symmetry / axis) plus generic knob names.
    /// Used as the "must be rejected unless declared" probe set — see
    /// `assertRejectsUndeclaredAttrs`.
    immutable string[] stageAttrProbeCorpus = [
        // snap
        "enabled", "types", "snapMode", "innerRange", "outerRange",
        "fixedGrid", "fixedGridSize", "fixedGridToggle", "typeToggle",
        "typeVertex", "typeEdge", "typePolygon", "typeWorkplane",
        // falloff
        "type", "shape", "start", "end", "center", "size", "axis", "dist",
        "steps", "anchorRing", "connect", "screenCx", "screenCy",
        "screenSize", "transparent", "lassoStyle", "lassoPoly", "lassoClear",
        "softBorder", "in", "out", "mix", "map", "autosize", "reverse",
        // action centre
        "cenX", "cenY", "cenZ", "userPlacedCenter", "userPlacedX",
        "userPlacedY", "userPlacedZ", "selectSubMode",
        // workplane
        "auto", "rotX", "rotY", "rotZ", "mode",
        // symmetry
        "offset", "useWorkplane", "topology", "epsilon",
        // generic knobs a stage might plausibly grow
        "snapping", "symmetry", "workplane", "falloff", "constrain",
        "visible", "active", "locked", "strength", "weight", "value",
        "state", "reset", "scope", "target", "count",
    ];

    /// Values fed to each probe name. A stage that grew an undeclared `case`
    /// may only accept SOME shapes of value, so probe several — and a value
    /// that makes the arm THROW while parsing counts as accepted too (reaching
    /// a parse at all proves the arm exists).
    immutable string[] stageAttrProbeValues = [
        "true", "false", "0", "1", "1.5", "auto", "x", "",
    ];

    /// Assert `st` rejects every probe name it does not declare in
    /// `knownAttrs()`. `who` labels the failure (defaults to `st.id()`).
    void assertRejectsUndeclaredAttrs(Stage st, string who = null) {
        import std.algorithm : canFind;
        const label    = who.length ? who : st.id();
        const declared = st.knownAttrs();
        foreach (probe; stageAttrProbeCorpus) {
            if (declared.canFind(probe)) continue;   // legitimately declared
            foreach (v; stageAttrProbeValues) {
                bool accepted;
                try
                    accepted = st.setAttr(probe, v);
                catch (Exception)
                    accepted = true;   // reached a parse ⇒ the arm exists
                assert(!accepted,
                       "stage '" ~ label ~ "' accepts setAttr(\"" ~ probe
                       ~ "\", \"" ~ v ~ "\") but does not list '" ~ probe
                       ~ "' in knownAttrs() — the forms startup-strict "
                       ~ "validator's universe is under-reported, so the "
                       ~ "first form binding it throws at boot (task 0685 T1)");
            }
        }
    }
}
