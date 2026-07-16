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

    // Whether this stage is currently enabled in the pipe. Disabled
    // stages are skipped during evaluation but stay in the pipe (the
    // E column in the tool pipe panel).
    bool enabled = true;

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
