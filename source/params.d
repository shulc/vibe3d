module params;

import math : Vec3;
import std.json : JSONValue, JSONType;

// ---------------------------------------------------------------------------
// ParamProvider — anything that publishes a Param[] schema.
//
// Implemented by `Tool` (existing) and `Stage` (Phase 7.9) so the same
// `PropertyPanel` machinery renders a tool's properties or a tool-pipe
// stage's properties without caring which class they came from.
//
// `paramEnabled` lets the provider grey-out individual rows (e.g. a
// Custom-shape `in_` slider is greyed when shape != custom). Default
// `true` for everything.
//
// `onParamChanged` fires AFTER PropertyPanel has written the new value
// through the typed pointer in the matching Param. Providers override
// to react (re-evaluate preview, publish state, etc.).
// ---------------------------------------------------------------------------

interface ParamProvider {
    Param[] params();
    bool    paramEnabled(string name) const;
    void    onParamChanged(string name);
}

// ---------------------------------------------------------------------------
// MixedValueProvider — a provider that stands for MORE THAN ONE subject, and
// can therefore be asked whether they agree on a given param.
//
// TASK 1880. A SEPARATE, OPTIONAL interface rather than a fourth method on
// `ParamProvider`, for two reasons. D interfaces cannot carry a default
// implementation for a virtual method (only `static`/`final` bodies are
// allowed), so a fourth method would be a compile break in every one of the
// ~dozen providers — tools, stages, falloffs — none of which stands for more
// than one subject and none of which has anything to say here. And the renderer
// can ask with one `cast`, which costs nothing on the providers that do not
// implement it.
//
// WHAT "MIXED" IS, and it is not a value. Read out of the reference's own SDK
// rather than designed: a command's argument QUERY there does not return a
// value, it fills an ARRAY — one entry per element of the selection — and the
// array type carries a first-differing probe. The command itself has no concept
// of "mixed" at all; a shipped sample's query visitor simply appends one number
// per element and its comment says that is "pretty much all that's required".
// The COLLAPSE is the UI's, and so is the placeholder it substitutes when the
// entries disagree: that placeholder sits in the reference's message table
// beside its "(none)" / "(unnamed)" / "(all)" siblings, which is what settles
// that it is a placeholder and not a value the field holds.
//
// So this interface answers the collapse, never a value. A widget that reports
// `true` here still binds and still WRITES normally — an edit is one absolute
// value applied to every subject, which is again read rather than chosen (the
// same sample's apply visitor assigns the one argument to every element it
// visits, with no delta arithmetic anywhere).
// ---------------------------------------------------------------------------

/// What a control SHOWS in place of a value its subjects disagree on.
///
/// One literal, in one place, so the panel and the test that asserts it cannot
/// drift — and so the string is a decision on the record rather than a repeated
/// magic constant. Parenthesised because it is a placeholder standing where a
/// value goes, matching the reference's own "(none)" / "(unnamed)" family; the
/// reference's message table spells this one the same way.
enum string kMixedPlaceholder = "(mixed)";

interface MixedValueProvider {
    /// True when the subjects this provider stands for do NOT all agree on
    /// `name`. False for a single subject, an unknown param, or agreement.
    bool paramMixed(string name);
}

// ---------------------------------------------------------------------------
// ParamHints — optional rendering / validation hints for one parameter.
// ---------------------------------------------------------------------------

struct ParamHints {
    enum Widget { Default, Drag, Slider, Radio, Combo, Checkbox }
    Widget widget = Widget.Default;

    bool   hasMinF, hasMaxF;  float minF, maxF;
    bool   hasMinI, hasMaxI;  int   minI, maxI;
    bool   hasStep;           float step_;
    bool   hasFmt;            string fmt;     // e.g. "%.4f"
    bool   isAngle = false;   // angle-in-degrees param: coarser default drag step
}

// ---------------------------------------------------------------------------
// Param — describes one parameter of a Command or Tool.
//
// Storage is a typed pointer into the owning object's fields. The factory
// method records the default value as metadata but does NOT write it into
// storage — the field initialiser on the owning class is the authoritative
// default. This prevents the per-frame params() call from resetting user
// input on every frame.
//
// The default_ field is kept for the HTTP injector (phase 2): if a JSON
// payload omits a parameter, the injector can read the canonical default
// from here rather than querying the live field.
//
// Chainable hint setters return Param by value so call sites can write a
// literal:
//
//   Param.float_("dist", "Distance", &dist_, 0.001f)
//        .min(0.0001f).max(100.0f).fmt("%.4f")
//        .widget(ParamHints.Widget.Drag)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// IntEnumEntry — maps a D enum integer value to a wire tag and UI label.
// Used by Param.Kind.IntEnum for native D enums without string storage.
// ---------------------------------------------------------------------------
struct IntEnumEntry {
    int    value;      // cast(int) of the D enum member
    string wireTag;    // for JSON/argstring: "offset", "width", ...
    string userLabel;  // for UI: "Offset", "Width", ...
}

// ---------------------------------------------------------------------------
// IntEnumEntry table helpers — the single-sourced value<->wireTag lookups a
// stage's parse (`applySetAttr`) and stringify (`*Label()`) legs both read,
// so a table lives in exactly ONE place instead of being re-derived by a
// hand-written parse switch AND a hand-written stringify switch (task 0184 /
// audit-2 C2). Mirror the existing inline loops at IntEnum's stringifyParam
// (stage.d) / paramToJson (below) / choicesOf (below).
// ---------------------------------------------------------------------------

/// Look up the wire tag for a live enum `value` in `t`. Falls back to
/// `fallback` (default: the raw integer as a string) when no entry matches —
/// mirrors paramToJson's IntEnum unmatched-fallback convention.
string wireTagForValue(const(IntEnumEntry)[] t, int v, string fallback = null) pure
{
    foreach (ref e; t)
        if (e.value == v) return e.wireTag;
    import std.format : format;
    return fallback !is null ? fallback : format("%d", v);
}

/// Look up the enum value for a wire tag `tag` in `t`. Returns false (and
/// leaves `v` untouched) when no entry matches — the caller's `applySetAttr`
/// then rejects the attr write, same as a hand-written parse switch's
/// default `return false`.
bool valueForWireTag(const(IntEnumEntry)[] t, string tag, out int v) pure
{
    foreach (ref e; t)
        if (e.wireTag == tag) { v = e.value; return true; }
    return false;
}

/// True iff every value in `members` has a matching entry in `t` — restores
/// the compile-time exhaustiveness a `final switch` used to guarantee before
/// the switch became a table lookup with a string/`%d` fallback. Intended for
/// an enforcement unittest per hoisted table: pass the enum's members as
/// ints, e.g. `tableCoversEnum(myTable, [cast(int)E.a, cast(int)E.b, ...])`
/// (or `iota(cast(int)E.min, cast(int)E.max + 1).array` for a dense range).
bool tableCoversEnum(const(IntEnumEntry)[] t, const(int)[] members) pure
{
    foreach (m; members) {
        bool found = false;
        foreach (ref e; t)
            if (e.value == m) { found = true; break; }
        if (!found) return false;
    }
    return true;
}

/// The same check with the member list taken from the ENUM rather than from
/// the caller — CTFE-evaluable, so it belongs in a `static assert` next to the
/// table and fails the BUILD, not a test run:
///
///     static assert(tableCoversEnumOf!Mode(modeEntries),
///         "every Mode needs a wire tag and a label");
///
/// Task 0705 (audit 4, X2). `tableCoversEnum` above restored exhaustiveness as
/// a runtime assertion, but at the price of a SECOND hand-written list — its
/// callers spell out `[cast(int)E.a, cast(int)E.b, …]`, which the new enum
/// member does not force anyone to extend either. This overload has no list to
/// forget: `EnumMembers` is the enum. Use it for any table hoisted out of a
/// `final switch`, so migrating to a table does not trade a compile error for
/// a runtime one.
bool tableCoversEnumOf(E)(const(IntEnumEntry)[] t) pure
    if (is(E == enum))
{
    import std.traits : EnumMembers;
    foreach (m; EnumMembers!E) {
        bool found = false;
        foreach (ref e; t)
            if (e.value == cast(int)m) { found = true; break; }
        if (!found) return false;
    }
    return true;
}


// ---------------------------------------------------------------------------
// ParamFlags — bitfield of per-parameter arg attributes.
//
// Each bit toggles one behaviour in a real consumer:
//   Hidden    — the generic UI renderers (PropertyPanel, ArgsDialog) skip the
//               row entirely. The schema entry stays so the headless HTTP/JSON
//               injector and argstring serialisation still see it.
//   ReadOnly  — the generic UI renderers draw the widget disabled (greyed,
//               non-interactive) via the same BeginDisabled/EndDisabled path
//               already used for cross-field graying. Headless paths ignore it.
//   Transient — the param is drawn gesture geometry or a momentary
//               action-trigger (e.g. a slice tool's Start/End line, a
//               transform tool's per-gesture run-state deltas, a pen point
//               edit proxy, a loop-slice insert/remove trigger) rather than a
//               remembered *setting*. Consulted by exactly one consumer —
//               `isStickyCapturable` below, which the sticky-tool-defaults
//               capture filter uses — so it does not affect UI rendering,
//               `isUserSet`, `paramToJson`, or `injectParamsInto`: a
//               transient param still renders and still round-trips through
//               `tool.attr`; it is only excluded from the sticky store.
//
// Set with the chainable .hidden() / .readonly() / .transient() setters.
// ---------------------------------------------------------------------------
enum ParamFlags : uint {
    None      = 0,
    Hidden    = 1 << 0,
    ReadOnly  = 1 << 1,
    Transient = 1 << 2,
    // EnforceBounds (task 0314) — opt-in: injectParamsInto clamps this
    // Int/Float param's JSON-injected value to its declared `.min()`/
    // `.max()` hints instead of writing it through unchecked. Deliberately
    // NOT the default for every hinted param: several commands declare a
    // `.min()/.max()` that is DELIBERATELY NARROWER than the field's real
    // valid domain and rely on their own apply()-time check to REJECT
    // (not coerce) an out-of-range value as an error — e.g.
    // commands.mesh.sweep's `count` (`.min(2)`, `if (count_ < 2) return
    // false;`, tested by tests/test_mesh_sweep.d's "count < 2 → error, mesh
    // unchanged"), and commands.mesh.add_point / loop_slice's `t`/
    // `position` (`.min(0.001).max(0.999)` as a UI-only sub-range, with
    // `if (t_ <= 0 || t_ >= 1) return false;` as the real, stricter
    // authority). Silently clamping those would replace a documented
    // rejection with a silently-different, unrequested edit. This flag is
    // for the OTHER common case — a param whose hint bound genuinely IS
    // the entire valid domain and where "cap it at the max we support" is
    // the correct behaviour (e.g. every primitive builder's segment/side/
    // order subdivision-count knobs), so callers opt in per-Param.
    EnforceBounds = 1 << 3,
}

struct Param {
    enum Kind { Bool, Int, Float, Enum, String, Vec3_, IntEnum, IntArray, Vec3Array }

    string name;          // internal id — matches JSON wire key
    string label;         // UI label
    Kind   kind;
    ParamHints hints;
    // Bitfield of arg attributes (see ParamFlags). Access via the hidden /
    // readonly accessors below rather than poking the bits directly.
    uint   flags;

    // Back-compat read accessors so existing `.hidden_` readers keep working
    // against the bitfield. The trailing-underscore names mirror the prior
    // `hidden_` field and stay distinct from the no-arg chainable setters
    // `hidden()` / `readonly()` declared further down (which set the bit and
    // return the Param for literal chaining).
    bool hidden_()    const { return (flags & ParamFlags.Hidden)    != 0; }
    bool readonly_()  const { return (flags & ParamFlags.ReadOnly)  != 0; }
    bool transient_() const { return (flags & ParamFlags.Transient) != 0; }
    bool enforceBounds_() const { return (flags & ParamFlags.EnforceBounds) != 0; }

    // Exactly one pointer is non-null, matching `kind`.
    union {
        bool*    bptr;
        int*     iptr;
        float*   fptr;
        string*  sptr;
        Vec3*    vptr;
        int*     iePtr;   // backing field for IntEnum kind (cast from D enum*)
        uint[]*  uiaPtr;  // IntArray:  pointer to a uint[] slice header
        Vec3[]*  v3aPtr;  // Vec3Array: pointer to a Vec3[] slice header
    }

    // For Kind.Enum: list of [internal_tag, user_label] pairs.
    // internal_tag is what is stored in *sptr and sent over the wire.
    string[2][] enumValues;

    // For Kind.IntEnum: list of (value, wireTag, userLabel) entries.
    // `const` so a `static immutable IntEnumEntry[]` table (single-sourced
    // per enum, shared across every params()/fullParams() call — see
    // wireTagForValue/valueForWireTag below) can be assigned here without a
    // per-call `.dup`. Every consumer only reads entries (parseInto,
    // stringifyParam, paramToJson, choicesOf, argstring, params_widgets).
    const(IntEnumEntry)[] intEnumValues;

    // Default value metadata — for HTTP injector fallback (phase 2).
    // Not written to storage by the factory; the field initialiser on the
    // owning class is the authoritative live default.
    union DefaultValue {
        bool   b;
        int    i;
        float  f;
        string s;
        Vec3   v3;
    }
    DefaultValue default_;

    // -----------------------------------------------------------------------
    // Factory methods
    // -----------------------------------------------------------------------

    static Param bool_(string name, string label, bool* storage, bool default_)
    {
        Param p;
        p.name       = name;
        p.label      = label;
        p.kind       = Kind.Bool;
        p.bptr       = storage;
        p.default_.b = default_;
        return p;
    }

    static Param int_(string name, string label, int* storage, int default_)
    {
        Param p;
        p.name       = name;
        p.label      = label;
        p.kind       = Kind.Int;
        p.iptr       = storage;
        p.default_.i = default_;
        return p;
    }

    static Param float_(string name, string label, float* storage, float default_)
    {
        Param p;
        p.name       = name;
        p.label      = label;
        p.kind       = Kind.Float;
        p.fptr       = storage;
        p.default_.f = default_;
        return p;
    }

    static Param enum_(string name, string label, string* storage,
                       string[2][] values, string default_)
    {
        Param p;
        p.name       = name;
        p.label      = label;
        p.kind       = Kind.Enum;
        p.sptr       = storage;
        p.enumValues = values;
        p.default_.s = default_;
        return p;
    }

    static Param string_(string name, string label, string* storage, string default_)
    {
        Param p;
        p.name       = name;
        p.label      = label;
        p.kind       = Kind.String;
        p.sptr       = storage;
        p.default_.s = default_;
        return p;
    }

    static Param vec3_(string name, string label, Vec3* storage, Vec3 default_)
    {
        Param p;
        p.name        = name;
        p.label       = label;
        p.kind        = Kind.Vec3_;
        p.vptr        = storage;
        p.default_.v3 = default_;
        return p;
    }

    // Int-backed enum: the D enum is stored as int in *storage; wire format
    // and UI use the wireTag / userLabel from each IntEnumEntry.
    // Cast: `cast(int*)&myEnumField` works for any int-backed D enum.
    static Param intEnum_(string name, string label, int* storage,
                          const(IntEnumEntry)[] values, int default_)
    {
        Param p;
        p.name           = name;
        p.label          = label;
        p.kind           = Kind.IntEnum;
        p.iePtr          = storage;
        p.intEnumValues  = values;
        p.default_.i     = default_;
        return p;
    }

    // Array kinds — no default tracking (length==0 means not user-set).
    // These are used for commands like mesh.vertex_edit that carry parallel
    // arrays (indices / before / after) injected via JSON; tools call
    // setEdit() directly and never go through the schema path.

    static Param intArray_(string name, string label, uint[]* storage)
    {
        Param p;
        p.name   = name;
        p.label  = label;
        p.kind   = Kind.IntArray;
        p.uiaPtr = storage;
        return p;
    }

    static Param vec3Array_(string name, string label, Vec3[]* storage)
    {
        Param p;
        p.name   = name;
        p.label  = label;
        p.kind   = Kind.Vec3Array;
        p.v3aPtr = storage;
        return p;
    }

    // -----------------------------------------------------------------------
    // Chainable hint setters (return by value for literal chaining)
    // -----------------------------------------------------------------------

    Param min(float v)                { hints.hasMinF = true; hints.minF = v; return this; }
    Param max(float v)                { hints.hasMaxF = true; hints.maxF = v; return this; }
    Param min(int   v)                { hints.hasMinI = true; hints.minI = v; return this; }
    Param max(int   v)                { hints.hasMaxI = true; hints.maxI = v; return this; }
    Param step(float v)               { hints.hasStep = true; hints.step_ = v; return this; }
    Param fmt(string f)               { hints.hasFmt  = true; hints.fmt   = f; return this; }
    Param widget(ParamHints.Widget w) { hints.widget = w; return this; }
    // Mark an angle-in-degrees param: forms_render uses a coarser default drag
    // step (0.1/px) so rotate degrees are draggable, vs 0.001/px for plain floats.
    Param angle()                     { hints.isAngle = true; return this; }

    // Flag setters — set the bit and return by value for literal chaining,
    // matching the hint-setter style above. Read the bits via the const
    // `hidden` / `readonly` accessors declared near the top of the struct.
    Param hidden()    { flags |= ParamFlags.Hidden;    return this; }
    Param readonly()  { flags |= ParamFlags.ReadOnly;  return this; }
    Param transient() { flags |= ParamFlags.Transient; return this; }
    // Opts this Param into injectParamsInto clamping (task 0314) — see
    // ParamFlags.EnforceBounds above for when this is (and is NOT) the
    // right choice for a given param.
    Param enforceBounds() { flags |= ParamFlags.EnforceBounds; return this; }
}

// ---------------------------------------------------------------------------
// isUserSet — returns true when the parameter's live storage value differs
// from the default recorded by the factory. Used by toArgstring (phase 5.2)
// to decide which params to emit; default-equal params are omitted
// (value-set semantics).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// isStickyCapturable — single-sourced rule for the sticky-tool-defaults
// capture filter (app.d `captureStickyToolDefaults`): which params are
// eligible to be snapshotted into `g_prefs.toolDefaults` on a clean tool
// drop. Array kinds don't round-trip through the string<->param path
// (stringifyParam/parseInto return ""/false for them); read-only params are
// derived display, not user settings; transient params are drawn gesture
// geometry / momentary action-triggers (see `ParamFlags.Transient` above),
// not remembered settings.
// ---------------------------------------------------------------------------

bool isStickyCapturable(const ref Param p)
{
    return p.kind != Param.Kind.IntArray
        && p.kind != Param.Kind.Vec3Array
        && !p.readonly_
        && !p.transient_;
}


bool isUserSet(const ref Param p)
{
    import std.math : isNaN;

    final switch (p.kind) {
        case Param.Kind.Bool:
            return *p.bptr != p.default_.b;
        case Param.Kind.Int:
            return *p.iptr != p.default_.i;
        case Param.Kind.Float: {
            // NaN-aware: "NaN default + NaN current" → not user-set.
            if (isNaN(*p.fptr) && isNaN(p.default_.f)) return false;
            return *p.fptr != p.default_.f;
        }
        case Param.Kind.Enum:
            return *p.sptr != p.default_.s;
        case Param.Kind.String:
            return *p.sptr != p.default_.s;
        case Param.Kind.Vec3_: {
            // Component-wise compare, NaN-aware.
            static bool eq(float a, float b) {
                if (isNaN(a) && isNaN(b)) return true;
                return a == b;
            }
            return !(eq(p.vptr.x, p.default_.v3.x)
                  && eq(p.vptr.y, p.default_.v3.y)
                  && eq(p.vptr.z, p.default_.v3.z));
        }
        case Param.Kind.IntEnum:
            return *p.iePtr != p.default_.i;
        case Param.Kind.IntArray:
            return (*p.uiaPtr).length > 0;
        case Param.Kind.Vec3Array:
            return (*p.v3aPtr).length > 0;
    }
}













// ---------------------------------------------------------------------------
// parseInto / stringifyParam — Param value <-> wire-token string. Moved here
// from toolpipe/stage.d (task 0409 / 0407 D3): this is generic Param
// mechanics with no toolpipe dependency — Stage.setAttr/listAttrs
// (toolpipe/stage.d's defaultStageSetAttr/defaultStageListAttrs) are just one
// caller, alongside tool_presets.d's sticky-tool-default restore and app.d's
// sticky-tool-default capture. Living in `params.d` (the home of Param)
// instead of toolpipe/stage.d means every caller now imports the SAME
// function instead of the module that happens to define Stage.
//
// fmtFloatWire below is the single source for the FLOAT-token half of this
// format (task 0409 / 0407 D3): the exact same %g-plus-NaN/Inf-sentinel
// logic used to be hand-duplicated three times — here, in argstring.d's
// `_fmtFloat`, and in forms.d's `fmtFloatG` — kept in sync only by comments
// pointing at each other ("to match argstring._fmtFloat"). Both of those are
// now thin delegates to fmtFloatWire; stringifyParam's Float case uses it
// directly instead of calling `format("%g", ...)` on its own.
// ---------------------------------------------------------------------------

/// Format a float value as its wire token: %g (6 significant digits) for
/// finite values, textual sentinels for NaN/Inf. Single source for every
/// float-token formatter in the codebase — see the section header above.
/// Takes `double` so both a `float` (implicit widening is lossless, and
/// produces byte-identical %g output to formatting the float directly — see
/// the unittest below) and a `double` (e.g. unboxed from a JSONValue) can
/// call it without a caller-side cast.
string fmtFloatWire(double f)
{
    import std.math   : isNaN, isInfinity;
    import std.format : format;
    if (isNaN(f))      return "nan";
    if (isInfinity(f)) return f > 0 ? "inf" : "-inf";
    return format("%g", f);
}



// ---------------------------------------------------------------------------
// The numeric gate — ONE implementation, both param-write routes (task 3020).
//
// A Param's declared `.min()/.max()/.enforceBounds()` used to mean different
// things depending on which door a value came in by. `injectParamsInto` (the
// JSON route: /api/command bodies, argstring positionals, preset injection)
// read the flag; `parseInto` (the wire-STRING route: every `tool.pipe.attr`
// stage write — so every falloff, snap, symmetry and workplane number — plus
// the sticky-tool-default restore out of prefs) had no bounds arm at all. On
// that second route the flag was INERT: a Param could carry
// `.min(1).max(64).enforceBounds()` and still be written to 100000.
//
// That is the shape this project pays for most — a guard that reads as armed
// and is not. `prim.box`'s `segmentsX/Y/Z` are the concrete case: the ceiling
// is a DoS clamp on an allocation scaler (doc/param_bounds_plan.md), it is
// honoured when the value arrives as JSON, and `applyStickyToolDefaults`
// re-applies the SAME param out of `prefs.json` through `parseInto`, where it
// was not. Two routes, one declared domain, one gate — so a new route cannot
// be born unclamped by forgetting to copy an arm.
//
// Three rules, in this order, and the order is the fix:
//
//  1. NON-FINITE IS REFUSED, never clamped. `enforceBounds` compares with `<`
//     and `>` and BOTH are false against a NaN, so a NaN sailed through the
//     clamp it was declared to obey. Refusing rather than coercing is the
//     policy `document.sanitizeItemXform` already settled for the item xform,
//     for the reason stated there: there is no "nearest legal value" for a
//     NaN, so any number we substituted would be an edit the caller never
//     asked for. The check runs BEFORE the bounds arm (a NaN is not in the
//     domain at all) and AGAIN after the double→float narrowing, which is its
//     own door: `1e300` is a perfectly finite JSON double and an INFINITE
//     float, and it reached the mesh (`tool.attr <id> SX 1e300` + `doApply`
//     put a NaN in all 24 vertex components).
//
//  2. THE BOUNDS ARM RUNS BEFORE THE CAST, not after it. The Int route used
//     to do `cast(int)_jsonFloat(...)` and clamp the RESULT, but an
//     out-of-range float casts to the x86 "indefinite integer" — `int.min` —
//     so the clamp then lifted it to the param's MINIMUM. Measured on the
//     shipped route: `mesh.smooth {"iter":1e18}` (declared
//     `.min(0).max(256).enforceBounds()`) behaved exactly like `iter:0` — no
//     smoothing at all — while `iter:1000000` correctly clamped to 256. A
//     clamp cannot guard a value the cast has already destroyed.
//
//  3. AN INT THE CAST CANNOT REPRESENT IS REFUSED. After the bounds arm, a
//     value still outside `[int.min, int.max]` has no legal int to land on —
//     the same "do not invent an answer" rule as (1). An UNENFORCED int param
//     is exactly where this bites, because there is no ceiling to clamp to.
//
// Both return false and write NOTHING on refusal; each caller turns that into
// its own route's refusal (a throw for the JSON route, which already throws
// for a bad enum tag; `false` for the wire-string route, which already returns
// false for an unparseable token).
// ---------------------------------------------------------------------------

/// Gate a float-kinded Param write. See the section header above.
/// `raw` is a double so a JSON `float_` node and a `to!double` of a wire token
/// both arrive without a lossy caller-side narrowing.
bool paramGateFloat(const ref Param p, double raw, out float v)
{
    import std.math : isFinite;
    if (!isFinite(raw)) return false;
    if (p.enforceBounds_) {
        if (p.hints.hasMinF && raw < p.hints.minF) raw = p.hints.minF;
        if (p.hints.hasMaxF && raw > p.hints.maxF) raw = p.hints.maxF;
    }
    immutable float narrowed = cast(float)raw;
    // The narrowing is its own overflow door — see rule 1 above.
    if (!isFinite(narrowed)) return false;
    v = narrowed;
    return true;
}

/// Gate an int-kinded Param write. See the section header above — the bounds
/// arm runs on `raw`, BEFORE the cast, which is the whole point.
bool paramGateInt(const ref Param p, double raw, out int v)
{
    import std.math : isFinite;
    if (!isFinite(raw)) return false;
    if (p.enforceBounds_) {
        if (p.hints.hasMinI && raw < p.hints.minI) raw = p.hints.minI;
        if (p.hints.hasMaxI && raw > p.hints.maxI) raw = p.hints.maxI;
    }
    if (raw < int.min || raw > int.max) return false;
    v = cast(int)raw;
    return true;
}

// ---------------------------------------------------------------------------
// The same refusal, for the wire-token parsers that do NOT have a Param in
// hand (task 3020).
//
// `parseInto` is only ONE of the doors a stage attribute comes in by: five
// stages override `Stage.setAttrImpl` with a hand-written string switch
// (falloff, snap, symmetry, workplane, action centre), and each grew its own
// `s.to!float`. Those are the doors the audit's own examples actually landed
// on — `tool.pipe.attr falloff dist nan` and `tool.pipe.attr symmetry epsilon
// inf` were both accepted with `status ok`, and `symmetry`'s hand-written
// `if (v <= 0.0f) return false` guard let the NaN past for the very reason
// `enforceBounds` did: every comparison against a NaN is false.
//
// These live HERE, beside the Param gate, so a sixth stage parser cannot be
// born with a private copy of the rule. They carry the FINITENESS half only —
// the bounds half needs a Param to read `.min()/.max()/.enforceBounds()` from,
// and these callers have a bare field.
//
// `dst` is left UNTOUCHED on refusal (hence `ref`, not `out` — `out` would
// zero the field before the parse and turn a refusal into a silent write of
// 0), and the Vec3 form is atomic: a bad `z` does not leave `x`/`y` written.
// ---------------------------------------------------------------------------

/// Parse one wire float token into `dst`. Empty string means 0 (the prior
/// contract of the per-stage `parseFloat` helpers this replaces). Returns
/// false — writing nothing — on an unparseable token or a non-finite value.
bool assignWireFloat(string s, ref float dst)
{
    import std.conv   : to;
    import std.math   : isFinite;
    import std.string : strip;
    if (s.length == 0) { dst = 0.0f; return true; }
    float v;
    try { v = s.strip.to!float; } catch (Exception) { return false; }
    if (!isFinite(v)) return false;
    dst = v;
    return true;
}

/// Parse one wire numeric token into an int `dst`, refusing a non-finite and
/// a value with no int to land on. Parsed as a double FIRST so the refusal
/// sees the value the caller wrote rather than the `int.min` an out-of-range
/// `cast(int)` produces — the same ordering rule as `paramGateInt`.
bool assignWireInt(string s, ref int dst)
{
    import std.conv   : to;
    import std.math   : isFinite;
    import std.string : strip;
    if (s.length == 0) { dst = 0; return true; }
    double v;
    try { v = s.strip.to!double; } catch (Exception) { return false; }
    if (!isFinite(v)) return false;
    if (v < int.min || v > int.max) return false;
    dst = cast(int)v;
    return true;
}

/// "x,y,z" → Vec3, atomic: nothing is written unless all three components
/// parse to finite floats.
bool assignWireVec3(string s, ref Vec3 dst)
{
    import std.string : split, strip;
    auto parts = s.split(",");
    if (parts.length != 3) return false;
    float x, y, z;
    if (!assignWireFloat(parts[0].strip, x)) return false;
    if (!assignWireFloat(parts[1].strip, y)) return false;
    if (!assignWireFloat(parts[2].strip, z)) return false;
    dst.x = x; dst.y = y; dst.z = z;
    return true;
}


// Parse `value` per `p.kind` and write into the Param's typed pointer.
// Returns false on parse failure (caller surfaces as "rejected attr").
// Public so the sticky tool-default path (prefs) can re-apply a stored
// value-string onto a freshly built tool's Param[] — same string→param
// machinery as the stage attr setter, no logic change beyond visibility.
//
// The numeric kinds go through `paramGateFloat`/`paramGateInt` — the SAME
// gate `injectParamsInto` uses — so a declared `.enforceBounds()` domain and
// the finiteness refusal mean the same thing on this route as on the JSON
// one. Before task 3020 this route had no bounds arm at all, which made the
// flag inert here and let `to!float("nan")` (std.conv accepts the sentinel)
// write a NaN into any stage attr: `tool.pipe.attr falloff dist nan` and
// `tool.pipe.attr symmetry epsilon inf` were both accepted with status ok.
// A refusal here surfaces as the route's existing "rejected attr" answer.
bool parseInto(ref Param p, string value) {
    import std.conv   : to;
    import std.string : split, strip;
    final switch (p.kind) {
        case Param.Kind.Bool:
            if (value == "true"  || value == "1") { *p.bptr = true;  return true; }
            if (value == "false" || value == "0") { *p.bptr = false; return true; }
            return false;
        case Param.Kind.Int:
            try {
                // `to!int` keeps this route's STRICT integer grammar — "2.5"
                // and a value with no int to land on are refused exactly as
                // before, and nothing is silently truncated. The gate then
                // applies the declared domain, which is the half that was
                // missing: a Param can carry `.min(1).max(64).enforceBounds()`
                // and this route used to write 100000 into it.
                int iv;
                if (!paramGateInt(p, cast(double)value.strip.to!int, iv))
                    return false;
                *p.iptr = iv;
                return true;
            }
            catch (Exception) { return false; }
        case Param.Kind.Float:
            try {
                float fv;
                if (!paramGateFloat(p, value.strip.to!double, fv)) return false;
                *p.fptr = fv;
                return true;
            }
            catch (Exception) { return false; }
        case Param.Kind.Enum:
            // Accept the wire tag exactly as listed in p.enumValues[i][0].
            foreach (ref ev; p.enumValues)
                if (ev[0] == value) { *p.sptr = value; return true; }
            return false;
        case Param.Kind.IntEnum:
            foreach (ref ev; p.intEnumValues)
                if (ev.wireTag == value) { *p.iePtr = ev.value; return true; }
            return false;
        case Param.Kind.String:
            *p.sptr = value;
            return true;
        case Param.Kind.Vec3_:
            auto parts = value.split(",");
            if (parts.length != 3) return false;
            try {
                // All three components gated into locals FIRST: a Vec3 write is
                // atomic, so a refusal on z must not leave x and y written.
                float vx, vy, vz;
                if (!paramGateFloat(p, parts[0].strip.to!double, vx)) return false;
                if (!paramGateFloat(p, parts[1].strip.to!double, vy)) return false;
                if (!paramGateFloat(p, parts[2].strip.to!double, vz)) return false;
                p.vptr.x = vx;
                p.vptr.y = vy;
                p.vptr.z = vz;
                return true;
            } catch (Exception) { return false; }
        case Param.Kind.IntArray:   return false;   // out of scope
        case Param.Kind.Vec3Array:  return false;   // out of scope
    }
}

// Stringify a Param's typed pointer-target to the same wire form `parseInto`
// accepts. Public so the sticky tool-default capture path (prefs) can snapshot
// a dropped tool's tool-level params — no logic change beyond visibility.
//
// Vec3-as-string format: "x,y,z" (matches `tool.pipe.attr falloff start
// 0,0.5,0` from the existing HTTP tests). Enum kind matches by wireTag
// (string for Param.Kind.Enum, intEnumValues.wireTag for IntEnum). Bool
// accepts true/false/1/0. Unknown attr name → return false (parseInto).
string stringifyParam(ref Param p) {
    import std.format : format;
    final switch (p.kind) {
        case Param.Kind.Bool:    return *p.bptr ? "true" : "false";
        case Param.Kind.Int:     return format("%d", *p.iptr);
        case Param.Kind.Float:   return fmtFloatWire(*p.fptr);
        case Param.Kind.Enum:    return *p.sptr;
        case Param.Kind.IntEnum:
            foreach (ref ev; p.intEnumValues)
                if (ev.value == *p.iePtr) return ev.wireTag;
            return format("%d", *p.iePtr);
        case Param.Kind.String:    return *p.sptr;
        case Param.Kind.Vec3_:     return format("%g,%g,%g", p.vptr.x, p.vptr.y, p.vptr.z);
        case Param.Kind.IntArray:  return "";
        case Param.Kind.Vec3Array: return "";
    }
}


// ---------------------------------------------------------------------------
// paramToJson — read the live typed-pointer value of a Param and box it as a
// JSONValue. The dual of injectParamsInto's per-kind write: this is the READ
// side used by the forms-engine query path (`tool.attr <id> <attr> ?`).
//
// Boxing convention (matches what injectParamsInto ACCEPTS on the write side so
// a query→write round-trips):
//   Bool      → JSON true/false
//   Int       → JSON integer
//   Float     → JSON float
//   String    → JSON string
//   Enum      → JSON string (the internal tag stored in *sptr)
//   Vec3_     → JSON array [x, y, z]
//   IntEnum   → JSON string (the wireTag of the matching entry; falls back to
//               the raw integer if no entry matches the live value)
//   IntArray  → JSON array of integers
//   Vec3Array → JSON array of [x, y, z] arrays
//
// Pure (no allocation beyond the returned JSONValue); never mutates the Param.
// ---------------------------------------------------------------------------

JSONValue paramToJson(const ref Param p)
{
    final switch (p.kind) {
        case Param.Kind.Bool:
            return JSONValue(*p.bptr);
        case Param.Kind.Int:
            return JSONValue(*p.iptr);
        case Param.Kind.Float:
            return JSONValue(cast(double)*p.fptr);
        case Param.Kind.String:
            return JSONValue(*p.sptr);
        case Param.Kind.Enum:
            return JSONValue(*p.sptr);
        case Param.Kind.Vec3_: {
            JSONValue[] a = [
                JSONValue(cast(double)p.vptr.x),
                JSONValue(cast(double)p.vptr.y),
                JSONValue(cast(double)p.vptr.z),
            ];
            return JSONValue(a);
        }
        case Param.Kind.IntEnum: {
            foreach (ref e; p.intEnumValues)
                if (e.value == *p.iePtr)
                    return JSONValue(e.wireTag);
            return JSONValue(*p.iePtr);   // unmatched: raw int fallback
        }
        case Param.Kind.IntArray: {
            JSONValue[] a;
            a.length = (*p.uiaPtr).length;
            foreach (i, v; *p.uiaPtr) a[i] = JSONValue(cast(int)v);
            return JSONValue(a);
        }
        case Param.Kind.Vec3Array: {
            JSONValue[] a;
            a.length = (*p.v3aPtr).length;
            foreach (i, ref v; *p.v3aPtr)
                a[i] = JSONValue([
                    JSONValue(cast(double)v.x),
                    JSONValue(cast(double)v.y),
                    JSONValue(cast(double)v.z),
                ]);
            return JSONValue(a);
        }
    }
}

// ---------------------------------------------------------------------------
// paramSchemaJson / paramsSchemaJson — the WIRE encoding of a Param's schema
// for `GET /api/registry?params=1`: `{name, kind, enforceBounds, value,
// min?, max?}`, and a JSON array of those for a whole `Param[]`.
//
// min/max surface whichever hint family (float or int) the Param declared — a
// Param only ever uses the family matching its own Kind, so there is no
// ambiguity in practice.
//
// This lives here, next to `paramToJson`, rather than inside the endpoint,
// because the endpoint no longer has a Param to encode at request time: the
// schema is serialised ONCE at startup by `Registry.cacheSupportedModes()`
// (registry.d) and the HTTP thread only ever emits the cached text. See the
// comment there for why — building it per request meant constructing every
// registered tool on the HTTP thread, and a tool constructor allocates GL
// objects on a thread with no current context.
// ---------------------------------------------------------------------------

string paramSchemaJson(const ref Param p)
{
    import std.array  : appender;
    import std.format : format;
    auto v = appender!string;
    v.put(format(`{"name":"%s","kind":"%s","enforceBounds":%s,"value":%s`,
        p.name, p.kind, p.enforceBounds_ ? "true" : "false",
        paramToJson(p).toString()));
    if (p.hints.hasMinF)      v.put(format(`,"min":%s`, p.hints.minF));
    else if (p.hints.hasMinI) v.put(format(`,"min":%d`, p.hints.minI));
    if (p.hints.hasMaxF)      v.put(format(`,"max":%s`, p.hints.maxF));
    else if (p.hints.hasMaxI) v.put(format(`,"max":%d`, p.hints.maxI));
    // Task 1412 — the ACCEPTED wire tags of an Enum / IntEnum, additive and
    // empty for every other Kind.
    //
    // The `value` field above already carries ONE valid tag (paramToJson
    // returns the live `*sptr` for Enum and the matching `e.wireTag` for
    // IntEnum), so this is not "the only way to name a valid tag" — it is the
    // only way to name the OTHERS. Blind enumeration is not an option on the
    // caller's side: `injectParamsInto` THROWS on an unknown tag (see the Enum
    // and IntEnum arms below), so a caller without this list can only ever
    // replay the one tag it was handed, and every alternative mode of every
    // enum parameter stays unreachable from outside the UI.
    //
    // Costs nothing per request: the whole schema is serialised ONCE at
    // startup by `Registry.cacheSupportedModes()` and the HTTP thread only
    // emits the cached text.
    {
        auto ch = choicesOf(p);
        if (ch.length > 0) {
            v.put(`,"choices":[`);
            foreach (i, ref c; ch) {
                if (i > 0) v.put(",");
                v.put(format(`"%s"`, c[0]));
            }
            v.put(`]`);
        }
    }
    v.put(`}`);
    return v.data;
}

/// `[` + comma-joined `paramSchemaJson` + `]`. Empty schema → `[]`.
string paramsSchemaJson(Param[] ps)
{
    import std.array : appender;
    auto buf = appender!string;
    buf.put(`[`);
    bool first = true;
    foreach (ref p; ps) {
        if (!first) buf.put(",");
        first = false;
        buf.put(paramSchemaJson(p));
    }
    buf.put(`]`);
    return buf.data;
}


// ---------------------------------------------------------------------------
// choicesOf — return the [internalTag, userLabel] choice list of an Enum /
// IntEnum Param so the forms renderer can build a combo. Empty for every
// other kind. Additive; used by the forms-engine popup sourcing.
// ---------------------------------------------------------------------------

string[2][] choicesOf(const ref Param p)
{
    final switch (p.kind) {
        case Param.Kind.Enum:
            return p.enumValues.dup;
        case Param.Kind.IntEnum: {
            string[2][] r;
            r.length = p.intEnumValues.length;
            foreach (i, ref e; p.intEnumValues)
                r[i] = [e.wireTag, e.userLabel];
            return r;
        }
        case Param.Kind.Bool:
        case Param.Kind.Int:
        case Param.Kind.Float:
        case Param.Kind.String:
        case Param.Kind.Vec3_:
        case Param.Kind.IntArray:
        case Param.Kind.Vec3Array:
            return [];
    }
}


// ---------------------------------------------------------------------------
// injectParamsInto — generic JSON → Param[] injector.
//
// For each Param in `params`:
//   - if `pj` has a key matching `p.name`, parse and write through the
//     typed pointer.
//   - if the key is absent, leave the field untouched (the field initialiser
//     on the owning class already provides the default).
//
// Accepts `Param[]` (not Command) to avoid a circular dependency between
// params.d and command.d. Call sites typically write:
//
//   import params : injectParamsInto;
//   injectParamsInto(cmd.params(), pj);
//
// Throws on malformed JSON (wrong type, bad Vec3 array, unknown enum tag), and
// on a numeric value the gate refuses — unless the caller asked for
// `injectParamsTolerant`, which drops that one param instead. Which of the two
// a route should use is a trust-boundary question, answered in the
// `InjectPolicy` header further down.
//
// Opt-in bound enforcement (task 0314): an Int/Float Param marked
// `.enforceBounds()` has its JSON-injected value clamped to the declared
// `.min()`/`.max()` hints (`ParamHints.hasMinI/hasMaxI`, `hasMinF/hasMaxF`)
// before the typed-pointer write. Those hints previously existed ONLY as UI
// slider-range metadata (see params_widgets.d / forms_render.d) — the
// interactive ImGui widgets clamp as a side effect of being a bounded
// slider, but this headless JSON path wrote the raw value straight through
// with NO enforcement at all, for every param, unconditionally. That let
// any caller (HTTP /api/command, argstring, scripts) drive a
// declared-bounded param — e.g. prim.cube's `segmentsR` (`.min(1).max(64)`)
// — arbitrarily out of range, including into geometry-builder complexity
// blowups (segmentsR:1000 on the O(n^2) rounded-cube corner builder ⇒ 8M+
// verts / GB-scale RSS / a hung main thread).
//
// This is deliberately OPT-IN rather than applied to every hinted param:
// a first pass tried unconditional clamping (both symmetric min+max, then
// max-only) and both broke existing, tested command contracts where a
// `.min()/.max()` hint is DELIBERATELY NARROWER than the field's real valid
// domain, with the command's own apply()-time check as the actual
// authority that REJECTS (not coerces) an out-of-range value:
//   - commands.mesh.sweep's `count` (`.min(2)`, no max) has
//     `if (count_ < 2) return false;`; tests/test_mesh_sweep.d locks in
//     "count < 2 → error, mesh unchanged" as the product contract.
//   - commands.mesh.add_point's `t` and commands.mesh.loop_slice's
//     `position` (both `.min(0.001).max(0.999)` as a UI-only sub-range)
//     have `if (t_ <= 0 || t_ >= 1) return false;`; tests/test_add_point.d
//     asserts `t:1.0` is rejected.
// Silently clamping those would replace a documented rejection with a
// silently-different, unrequested edit the caller never asked for — worse
// than doing nothing. So every primitive builder's segment/side/order
// subdivision-count Params (where the hint genuinely IS the whole valid
// domain and "cap it at the max we support" is correct) opt in explicitly
// via `.enforceBounds()`; every other hinted Param keeps today's
// behaviour (hint is UI-only, unenforced on this path) unless it also
// opts in. Degenerate near-zero/negative geometry params (radius vs.
// size, etc.) are guarded separately at the geometry-builder level (task
// 0315: buildCuboidParametric / buildCone / buildCylinder / buildCapsule /
// buildSphere* / buildTorus) — those aren't expressible as a single Param
// bound anyway (radius's limit depends on sizeX/Y/Z).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// A FILE AND A COMMAND PARAMETER ARE NOT THE SAME TRUST BOUNDARY (task 3150).
//
// The numeric gate above refuses a value with no legal number to land on, and
// that is right for a value a CALLER just typed: `tool.attr <id> SX zzz` is a
// typo, refusing it costs the caller one retry, and substituting a number for
// it silently sets the scale to something nobody asked for.
//
// It is wrong for a value read out of a STORED DOCUMENT. The same refusal on
// that route throws away the user's whole file over one corrupt scalar — and
// `.v3d` is the native format, so it is the likeliest carrier of a poisoned
// value in the tree (a file from a build that predates a guard, a hand edit,
// an exporter that never saw the band; `io/native.d`'s own R7 note says so).
// A loader that answers "this document is unreadable" because one of twelve
// item-transform channels says `"nope"` is the second kind of undiscriminating
// check this project pays for: it goes red on input that is very nearly
// correct, and the user loses the ninety-nine values that were fine.
//
// So the policy is chosen BY THE CALLER, and the default is the strict one, so
// that a route added later is born refusing rather than born permissive:
//
//   * `injectParamsInto`      — REFUSE. Every wire route (six live call sites:
//     `/api/command`, `tool.attr`, `tool.set`, `layer.attr`'s two writes, the
//     keymap argstring) plus the in-tree YAML presets, whose own contract is
//     to fail loudly at startup rather than activate with wrong defaults.
//   * `injectParamsTolerant`  — KEEP THE PRIOR VALUE and report the name. One
//     live call site, `io/native.d`'s `.v3d` channel block.
//
// The tolerant arm covers exactly the NUMERIC gate — the four kinds that route
// through `paramGateFloat`/`paramGateInt`. It writes NOTHING for the offending
// param, so the field keeps whatever the loader already put there, which for a
// fresh item is its identity (`pos` 0, `scl` 1) — never a substituted 0, which
// is what made an unreadable `scl` land on a SINGULAR item transform before.
// A wrong JSON TYPE for a String / Vec3 / enum tag still rejects the document
// on both routes: a channel whose shape is wrong says the file was written
// against a different schema, which is a different claim from one bad number,
// and `io/native.d` decision 6 already settled it. Widening tolerance to those
// is a separate decision with its own witness.
// ---------------------------------------------------------------------------

/// See the section header above. `Refuse` is the default everywhere.
enum InjectPolicy {
    /// Throw, writing nothing — the caller typed this value and must hear so.
    Refuse,
    /// Skip that one param, leaving the field at the value it already holds,
    /// and record its name for the caller to report.
    KeepPriorValue,
}

void injectParamsInto(Param[] params, ref JSONValue pj)
{
    injectParamsImpl(params, pj, InjectPolicy.Refuse, null);
}

/// Strict candidate-parameter injection for the prepared tool-arm door.
/// The writes target the unpublished candidate. Returned names are owned and
/// retain schema order so the caller can prepare each reviewed parameter hook
/// before any live transition begins.
string[] injectPreparedParamsInto(Param[] params, ref JSONValue pj)
{
    injectParamsInto(params, pj);
    string[] changed;
    if (pj.type != JSONType.object) return changed;
    foreach (ref p; params)
        if ((p.name in pj.object) !is null)
            changed ~= p.name.idup;
    return changed;
}

/// The stored-document form of `injectParamsInto`: a numeric channel with no
/// legal number to land on is DROPPED rather than refused, and its name is
/// returned so the loader can warn about exactly what it could not read.
/// Returns the dropped names in encounter order; empty means a clean read.
string[] injectParamsTolerant(Param[] params, ref JSONValue pj)
{
    string[] dropped;
    injectParamsImpl(params, pj, InjectPolicy.KeepPriorValue, &dropped);
    return dropped;
}

private void injectParamsImpl(Param[] params, ref JSONValue pj,
                              InjectPolicy policy, string[]* dropped)
{
    // Record a value the gate refused and answer whether the caller should
    // carry on to the next param instead of throwing.
    bool tolerate(string what)
    {
        if (policy != InjectPolicy.KeepPriorValue) return false;
        if (dropped !is null) *dropped ~= what;
        return true;
    }

    foreach (ref p; params) {
        auto jp = p.name in pj.object;
        if (jp is null) continue;
        final switch (p.kind) {
            case Param.Kind.Bool:
                // Accept true, false, and integer 0/1 (argstring serialises bools
                // as "true"/"false" but JSON schema may carry integer 0/1).
                if (jp.type == JSONType.true_)
                    *p.bptr = true;
                else if (jp.type == JSONType.false_)
                    *p.bptr = false;
                else if (jp.type == JSONType.integer)
                    *p.bptr = (jp.integer != 0);
                else if (jp.type == JSONType.uinteger)
                    *p.bptr = (jp.uinteger != 0);
                else
                    *p.bptr = false;
                break;
            case Param.Kind.Int: {
                int iv;
                if (!paramGateInt(p, _jsonNum(*jp), iv)) {
                    if (tolerate(p.name)) break;
                    throw new Exception(
                        "param '" ~ p.name ~ "' is not a representable integer");
                }
                *p.iptr = iv;
                break;
            }
            case Param.Kind.Float: {
                float fv;
                if (!paramGateFloat(p, _jsonNum(*jp), fv)) {
                    if (tolerate(p.name)) break;
                    throw new Exception(
                        "param '" ~ p.name ~ "' must be a finite number");
                }
                *p.fptr = fv;
                break;
            }
            case Param.Kind.String:
                if (jp.type != JSONType.string)
                    throw new Exception(
                        "param '" ~ p.name ~ "' expected string");
                *p.sptr = jp.str;
                break;
            case Param.Kind.Enum:
                if (jp.type != JSONType.string)
                    throw new Exception(
                        "param '" ~ p.name ~ "' expected string (enum tag)");
                string tag = jp.str;
                bool ok = false;
                foreach (e; p.enumValues)
                    if (e[0] == tag) { ok = true; break; }
                if (!ok)
                    throw new Exception(
                        "unknown enum value '" ~ tag ~ "' for param '" ~ p.name ~ "'");
                *p.sptr = tag;
                break;
            case Param.Kind.Vec3_:
                if (jp.type != JSONType.array || jp.array.length != 3)
                    throw new Exception(
                        "param '" ~ p.name ~ "' must be [x,y,z]");
                auto a = jp.array;
                // Gated per component into locals first — a Vec3 write is
                // atomic, so a refusal on z must not leave x and y written.
                float vx, vy, vz;
                if (!paramGateFloat(p, _jsonNum(a[0]), vx)
                 || !paramGateFloat(p, _jsonNum(a[1]), vy)
                 || !paramGateFloat(p, _jsonNum(a[2]), vz)) {
                    if (tolerate(p.name)) break;
                    throw new Exception(
                        "param '" ~ p.name ~ "' must be a finite number");
                }
                *p.vptr = Vec3(vx, vy, vz);
                break;
            case Param.Kind.IntEnum:
                if (jp.type == JSONType.integer || jp.type == JSONType.uinteger) {
                    // Accept raw integer value (e.g. axis:1 from argstring parser).
                    int ival = (jp.type == JSONType.uinteger)
                        ? cast(int)jp.uinteger : cast(int)jp.integer;
                    bool iok2 = false;
                    foreach (ref e; p.intEnumValues) {
                        if (e.value == ival) {
                            *p.iePtr = e.value;
                            iok2 = true;
                            break;
                        }
                    }
                    if (!iok2)
                        throw new Exception(
                            "unknown enum value " ~ jp.toString()
                            ~ " for param '" ~ p.name ~ "'");
                    break;
                }
                if (jp.type != JSONType.string)
                    throw new Exception(
                        "param '" ~ p.name ~ "' expected string (enum tag) or integer");
                string itag = jp.str;
                bool iok = false;
                foreach (ref e; p.intEnumValues) {
                    if (e.wireTag == itag) {
                        *p.iePtr = e.value;
                        iok = true;
                        break;
                    }
                }
                if (!iok)
                    throw new Exception(
                        "unknown enum value '" ~ itag ~ "' for param '" ~ p.name ~ "'");
                break;
            case Param.Kind.IntArray: {
                if (jp.type != JSONType.array)
                    throw new Exception(
                        "param '" ~ p.name ~ "' must be an array");
                import std.conv : to;
                uint[] result;
                result.length = jp.array.length;
                foreach (i, ref v; jp.array) {
                    if (v.type == JSONType.integer)       result[i] = cast(uint)v.integer;
                    else if (v.type == JSONType.uinteger) result[i] = cast(uint)v.uinteger;
                    else if (v.type == JSONType.float_)   result[i] = cast(uint)v.floating;
                    else throw new Exception(
                        "param '" ~ p.name ~ "[" ~ i.to!string ~ "]' must be a number");
                }
                *p.uiaPtr = result;
                break;
            }
            case Param.Kind.Vec3Array: {
                if (jp.type != JSONType.array)
                    throw new Exception(
                        "param '" ~ p.name ~ "' must be an array of [x,y,z]");
                import std.conv : to;
                Vec3[] result;
                result.length = jp.array.length;
                // `dropWhole` rather than a bare `break`: this `break` would
                // leave the INNER foreach, not the switch case, and the write
                // below would then publish a half-filled array.
                bool dropWhole = false;
                foreach (i, ref vJson; jp.array) {
                    if (vJson.type != JSONType.array || vJson.array.length != 3)
                        throw new Exception(
                            "param '" ~ p.name ~ "[" ~ i.to!string ~ "]' must be [x,y,z]");
                    // Same gate as the scalar Vec3 arm — a non-finite in ONE
                    // element refuses the whole array (the write below is the
                    // single assignment, so nothing partial lands).
                    float ax, ay, az;
                    if (!paramGateFloat(p, _jsonNum(vJson.array[0]), ax)
                     || !paramGateFloat(p, _jsonNum(vJson.array[1]), ay)
                     || !paramGateFloat(p, _jsonNum(vJson.array[2]), az)) {
                        if (tolerate(p.name ~ "[" ~ i.to!string ~ "]")) {
                            dropWhole = true;
                            break;
                        }
                        throw new Exception(
                            "param '" ~ p.name ~ "[" ~ i.to!string
                            ~ "]' must be a finite number");
                    }
                    result[i] = Vec3(ax, ay, az);
                }
                if (dropWhole) break;
                *p.v3aPtr = result;
                break;
            }
        }
    }
}

// Private helper: accept integer, uinteger, or float_ JSON nodes as a double.
//
// DOUBLE, not float (task 3020): the narrowing to float belongs to
// `paramGateFloat`, AFTER the bounds arm, because it is an overflow door of
// its own — `1e300` is a finite JSON double and an infinite float, and it used
// to be narrowed here and written straight through. The int side needs the
// undamaged value for the same reason: clamping must see `1e18`, not the
// `int.min` a premature `cast(int)` turns it into.
//
// A NON-NUMERIC node answers NaN, not 0.0 (task 3021). Before this, `tool.attr
// <id> SX zzz` reported ok and silently set the scale to zero — the argstring
// grammar has no float exponent / nan / inf literal, so any such token hands
// through as a JSON STRING, and a plain string node used to fall through to
// the `0.0` default below. NaN is not a special case here: every call site
// (six of them, all six Int/Float/Vec3_/Vec3Array component writes) already
// routes the result through `paramGateFloat`/`paramGateInt`, and both already
// refuse a non-finite `raw` with "must be a finite number" / "not a
// representable integer" — the exact refusal a hand-typed `nan` token gets on
// the same route. A non-numeric token is just another value with no legal
// number to land on; REFUSE, never substitute (the policy `paramGateFloat`
// itself and `document.sanitizeItemXform` already apply). What a refusal MEANS
// then depends on the route: a throw at the wire edge, a dropped channel on the
// `.v3d` read — see the `InjectPolicy` header below (task 3150).
private double _jsonNum(ref JSONValue v)
{
    if (v.type == JSONType.integer)  return cast(double)v.integer;
    if (v.type == JSONType.uinteger) return cast(double)v.uinteger;
    if (v.type == JSONType.float_)   return v.floating;
    return double.nan;
}
