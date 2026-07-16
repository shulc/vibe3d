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

unittest {
    static immutable IntEnumEntry[] tbl = [
        IntEnumEntry(0, "off",   "Off"),
        IntEnumEntry(1, "width", "Width"),
        IntEnumEntry(2, "depth", "Depth"),
    ];

    // wireTagForValue — match, no-match fallback (default + explicit).
    assert(wireTagForValue(tbl, 1) == "width");
    assert(wireTagForValue(tbl, 99) == "99");                 // default fallback
    assert(wireTagForValue(tbl, 99, "?") == "?");              // explicit fallback

    // valueForWireTag — match, no-match.
    int v;
    assert(valueForWireTag(tbl, "depth", v) && v == 2);
    assert(!valueForWireTag(tbl, "bogus", v));

    // tableCoversEnum — complete vs missing member.
    assert(tableCoversEnum(tbl, [0, 1, 2]));
    assert(!tableCoversEnum(tbl, [0, 1, 2, 3]));
    assert(tableCoversEnum(tbl, []));   // vacuously true

    // A `static immutable` table passes straight into intEnum_ without .dup
    // (the OBJ-1 widening this helper block depends on).
    int backing = 1;
    auto p = Param.intEnum_("k", "K", &backing, tbl, 0);
    assert(p.intEnumValues.length == 3);
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

unittest {
    // isStickyCapturable — plain float capturable; readonly/transient/array
    // kinds excluded, independently and in combination.
    float f = 0.0f;
    auto plain = Param.float_("dist", "Distance", &f, 0.0f);
    assert(isStickyCapturable(plain));

    auto ro = Param.float_("dist", "Distance", &f, 0.0f).readonly();
    assert(!isStickyCapturable(ro));

    auto tr = Param.float_("dist", "Distance", &f, 0.0f).transient();
    assert(!isStickyCapturable(tr));

    uint[] arr;
    auto ia = Param.intArray_("indices", "Indices", &arr);
    assert(!isStickyCapturable(ia));

    Vec3[] varr;
    auto va = Param.vec3Array_("verts", "Verts", &varr);
    assert(!isStickyCapturable(va));

    // hidden() alone does not exclude — only readonly/transient/array do.
    auto hid = Param.float_("dist", "Distance", &f, 0.0f).hidden();
    assert(isStickyCapturable(hid));

    auto both = Param.float_("dist", "Distance", &f, 0.0f).readonly().transient();
    assert(!isStickyCapturable(both));
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

unittest {
    // Flags — default clear, setters set bits, accessors read them, chaining
    // composes. The bitfield consolidates the former standalone hidden_ bool.
    int i = 0;
    auto p0 = Param.int_("n", "N", &i, 0);
    assert(!p0.hidden_ && !p0.readonly_);
    assert(p0.flags == ParamFlags.None);

    auto ph = Param.int_("n", "N", &i, 0).hidden();
    assert(ph.hidden_ && !ph.readonly_);

    auto pr = Param.int_("n", "N", &i, 0).readonly();
    assert(pr.readonly_ && !pr.hidden_);

    // Both flags compose, and order/independence holds with hint setters.
    auto pb = Param.int_("n", "N", &i, 0).readonly().hidden().min(0).max(9);
    assert(pb.hidden_ && pb.readonly_);
    assert((pb.flags & ParamFlags.Hidden) && (pb.flags & ParamFlags.ReadOnly));
}

unittest {
    // Angle hint — default clear; .angle() sets isAngle; composes with other
    // chainable setters and does not bleed onto a non-angle float. forms_render
    // reads hints.isAngle to widen the default drag step (0.1/px vs 0.001/px);
    // the resulting ImGui drag SPEED has no headless signal, so this asserts the
    // hint propagates through the Param the renderer resolves (drag feel is
    // manual-verify).
    float f = 0.0f;
    auto plain = Param.float_("dist", "Distance", &f, 0.0f);
    assert(!plain.hints.isAngle);

    auto ang = Param.float_("RX", "Rotate X", &f, 0.0f).angle();
    assert(ang.hints.isAngle);

    // Composes with min/max/fmt without clobbering isAngle, and explicit .step()
    // still wins at the render site (asserted there via hasStep).
    auto ang2 = Param.float_("RY", "Rotate Y", &f, 0.0f).angle().min(-360.0f).max(360.0f);
    assert(ang2.hints.isAngle);
    assert(ang2.hints.hasMinF && ang2.hints.hasMaxF);
}

unittest {
    // Bool — set when value differs from default
    bool b = false;
    auto p = Param.bool_("flag", "Flag", &b, false);
    assert(!isUserSet(p));
    b = true;
    assert(isUserSet(p));
}

unittest {
    // Int — set when value differs from default
    int i = 4;
    auto p = Param.int_("segs", "Segments", &i, 4);
    assert(!isUserSet(p));
    i = 8;
    assert(isUserSet(p));
}

unittest {
    // Float — NaN-vs-NaN treated as not user-set (e.g. widthR default NaN)
    float f = float.nan;
    auto p = Param.float_("widthR", "Width R", &f, float.nan);
    assert(!isUserSet(p));   // NaN equals NaN here
    f = 0.05f;
    assert(isUserSet(p));    // explicit value
    f = float.nan;
    assert(!isUserSet(p));   // back to NaN, not user-set again
}

unittest {
    // Float — standard numeric compare (no epsilon, any delta counts)
    float f = 0.1f;
    auto p = Param.float_("width", "Width", &f, 0.1f);
    assert(!isUserSet(p));
    f = 0.10001f;
    assert(isUserSet(p));
}

unittest {
    // Enum — string-tag compare
    string mode = "offset";
    auto p = Param.enum_("mode", "Mode", &mode,
                         [["offset","Offset"],["width","Width"]], "offset");
    assert(!isUserSet(p));
    mode = "width";
    assert(isUserSet(p));
}

unittest {
    // String — empty-string default is not user-set
    string s = "";
    auto p = Param.string_("label", "Label", &s, "");
    assert(!isUserSet(p));
    s = "hello";
    assert(isUserSet(p));
    s = "";
    assert(!isUserSet(p));
}

unittest {
    // IntEnum — int-tag compare
    int v = 0;
    auto p = Param.intEnum_("mode", "Mode", &v,
        [IntEnumEntry(0, "offset", "Offset"),
         IntEnumEntry(1, "width",  "Width")],
        0);
    assert(!isUserSet(p));
    v = 1;
    assert(isUserSet(p));
}

unittest {
    // Vec3 — component-wise compare
    Vec3 v = Vec3(0, 0, 0);
    auto p = Param.vec3_("from", "From", &v, Vec3(0, 0, 0));
    assert(!isUserSet(p));
    v.x = 0.5f;
    assert(isUserSet(p));
    v = Vec3(0, 0, 0);
    assert(!isUserSet(p));
}

unittest {
    // IntArray — empty slice is not user-set; non-empty is.
    uint[] arr;
    auto p = Param.intArray_("indices", "Indices", &arr);
    assert(!isUserSet(p));
    arr = [0u, 5u, 7u];
    assert(isUserSet(p));
    arr = [];
    assert(!isUserSet(p));
}

unittest {
    // Vec3Array — empty slice is not user-set; non-empty is.
    Vec3[] arr;
    auto p = Param.vec3Array_("before", "Before", &arr);
    assert(!isUserSet(p));
    arr = [Vec3(0, 0, 0), Vec3(1, 2, 3)];
    assert(isUserSet(p));
    arr = [];
    assert(!isUserSet(p));
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

unittest {
    // fmtFloatWire — the exact value set task 0409 pins for byte-identity
    // across argstring._fmtFloat / stringifyParam / forms.fmtFloatG.
    assert(fmtFloatWire(0.0)              == "0");
    assert(fmtFloatWire(1.0)              == "1");
    assert(fmtFloatWire(-1.0)             == "-1");
    assert(fmtFloatWire(0.5)              == "0.5");
    assert(fmtFloatWire(1e-7)             == "1e-07");
    assert(fmtFloatWire(-3.25)            == "-3.25");
    assert(fmtFloatWire(1e20)             == "1e+20");
    assert(fmtFloatWire(123456.789)       == "123457");  // %g rounds to 6 sig figs
    assert(fmtFloatWire(cast(double)0.1f) == "0.1");

    // NaN/Inf sentinels — the semantics argstring._fmtFloat's doc comment
    // calls out as load-bearing for NaN-default params (e.g. widthR).
    assert(fmtFloatWire(double.nan)       == "nan");
    assert(fmtFloatWire(double.infinity)  == "inf");
    assert(fmtFloatWire(-double.infinity) == "-inf");
}

unittest {
    // float vs. double input produce identical tokens for every value in the
    // pinned set — the premise that lets argstring._fmtFloat(float) delegate
    // to this double-taking helper with no observable behaviour change
    // (float->double widening is exact, and %g's rounding is a function of
    // the real value, not the storage width — verified here rather than
    // assumed).
    immutable float[] vals = [0.0f, 1.0f, -1.0f, 0.5f, 1e-7f, -3.25f, 1e20f,
                               123456.789f, 0.1f];
    foreach (v; vals)
        assert(fmtFloatWire(v) == fmtFloatWire(cast(double)v));
}

// Parse `value` per `p.kind` and write into the Param's typed pointer.
// Returns false on parse failure (caller surfaces as "rejected attr").
// Public so the sticky tool-default path (prefs) can re-apply a stored
// value-string onto a freshly built tool's Param[] — same string→param
// machinery as the stage attr setter, no logic change beyond visibility.
bool parseInto(ref Param p, string value) {
    import std.conv   : to;
    import std.string : split, strip;
    final switch (p.kind) {
        case Param.Kind.Bool:
            if (value == "true"  || value == "1") { *p.bptr = true;  return true; }
            if (value == "false" || value == "0") { *p.bptr = false; return true; }
            return false;
        case Param.Kind.Int:
            try { *p.iptr = value.strip.to!int; return true; }
            catch (Exception) { return false; }
        case Param.Kind.Float:
            try { *p.fptr = value.strip.to!float; return true; }
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
                p.vptr.x = parts[0].strip.to!float;
                p.vptr.y = parts[1].strip.to!float;
                p.vptr.z = parts[2].strip.to!float;
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

unittest {
    // parseInto / stringifyParam round-trip for the kinds that support a
    // scalar string token (moved here verbatim from toolpipe/stage.d, which
    // had no dedicated unit coverage of its own — this is fresh coverage,
    // not a relocation of an existing test).
    bool  b = false;
    int   i = 0;
    float f = 0.0f;
    string mode = "offset";
    int   ie = 0;
    string s = "";
    Vec3  v = Vec3(0, 0, 0);

    auto pb  = Param.bool_ ("b", "B", &b, false);
    auto pi  = Param.int_  ("i", "I", &i, 0);
    auto pf  = Param.float_("f", "F", &f, 0.0f);
    auto pe  = Param.enum_ ("mode", "Mode", &mode,
                            [["offset","Offset"],["width","Width"]], "offset");
    auto pie = Param.intEnum_("ie", "IE", &ie,
        [IntEnumEntry(0, "off", "Off"), IntEnumEntry(1, "on", "On")], 0);
    auto ps  = Param.string_("s", "S", &s, "");
    auto pv  = Param.vec3_  ("v", "V", &v, Vec3(0, 0, 0));

    assert(parseInto(pb, "true"));   assert(b == true);
    assert(stringifyParam(pb) == "true");
    assert(parseInto(pb, "0"));      assert(b == false);
    assert(!parseInto(pb, "nope"));  // unrecognized bool token -> false, b unchanged
    assert(b == false);

    assert(parseInto(pi, "42"));     assert(i == 42);
    assert(stringifyParam(pi) == "42");
    assert(!parseInto(pi, "abc"));   assert(i == 42);   // unchanged on parse failure

    assert(parseInto(pf, "0.5"));    assert(f == 0.5f);
    assert(stringifyParam(pf) == "0.5");

    assert(parseInto(pe, "width")); assert(mode == "width");
    assert(stringifyParam(pe) == "width");
    assert(!parseInto(pe, "bogus")); assert(mode == "width");

    assert(parseInto(pie, "on"));   assert(ie == 1);
    assert(stringifyParam(pie) == "on");
    assert(!parseInto(pie, "bogus")); assert(ie == 1);

    assert(parseInto(ps, "hello")); assert(s == "hello");
    assert(stringifyParam(ps) == "hello");

    assert(parseInto(pv, "1,2,3"));
    assert(v.x == 1 && v.y == 2 && v.z == 3);
    assert(stringifyParam(pv) == "1,2,3");
    assert(!parseInto(pv, "1,2"));   // wrong arity -> false, v unchanged
    assert(v.x == 1 && v.y == 2 && v.z == 3);

    // Array kinds are out of scope for the string wire form (JSON injection
    // is their canonical path) — parseInto rejects, stringifyParam is inert.
    uint[] arr;
    auto pa = Param.intArray_("arr", "Arr", &arr);
    assert(!parseInto(pa, "1,2,3"));
    assert(stringifyParam(pa) == "");
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

unittest {
    // paramToJson round-trips each scalar kind through injectParamsInto.
    import std.math : fabs;

    bool b = true;
    auto pb = Param.bool_("flag", "F", &b, false);
    assert(paramToJson(pb).type == JSONType.true_);

    int i = 7;
    auto pi = Param.int_("segs", "S", &i, 0);
    assert(paramToJson(pi).integer == 7);

    float f = 1.5f;
    auto pf = Param.float_("w", "W", &f, 0.0f);
    assert(fabs(paramToJson(pf).floating - 1.5) < 1e-6);

    string s = "hi";
    auto ps = Param.string_("lbl", "L", &s, "");
    assert(paramToJson(ps).str == "hi");

    string mode = "width";
    auto pe = Param.enum_("mode", "M", &mode,
                          [["offset","Offset"],["width","Width"]], "offset");
    assert(paramToJson(pe).str == "width");
    auto ch = choicesOf(pe);
    assert(ch.length == 2 && ch[1][0] == "width" && ch[1][1] == "Width");

    Vec3 v = Vec3(1, 2, 3);
    auto pv = Param.vec3_("c", "C", &v, Vec3(0, 0, 0));
    auto jv = paramToJson(pv);
    assert(jv.type == JSONType.array && jv.array.length == 3);
    assert(fabs(jv.array[0].floating - 1) < 1e-6);
    assert(fabs(jv.array[2].floating - 3) < 1e-6);

    int ie = 1;
    auto pie = Param.intEnum_("k", "K", &ie,
        [IntEnumEntry(0, "off", "Off"), IntEnumEntry(1, "width", "Width")], 0);
    assert(paramToJson(pie).str == "width");
    auto iech = choicesOf(pie);
    assert(iech.length == 2 && iech[0][0] == "off" && iech[0][1] == "Off");

    // Round-trip: box then inject into a fresh field.
    float f2 = 0.0f;
    auto pf2 = Param.float_("w", "W", &f2, 0.0f);
    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    pj["w"] = paramToJson(pf);   // box live 1.5
    auto arr = [pf2];
    injectParamsInto(arr, pj);
    assert(fabs(f2 - 1.5) < 1e-6);
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
// Throws on malformed JSON (wrong type, bad Vec3 array, unknown enum tag).
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

void injectParamsInto(Param[] params, ref JSONValue pj)
{
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
                int iv = cast(int)_jsonFloat(*jp);
                if (p.enforceBounds_) {
                    if (p.hints.hasMinI && iv < p.hints.minI) iv = p.hints.minI;
                    if (p.hints.hasMaxI && iv > p.hints.maxI) iv = p.hints.maxI;
                }
                *p.iptr = iv;
                break;
            }
            case Param.Kind.Float: {
                float fv = _jsonFloat(*jp);
                if (p.enforceBounds_) {
                    if (p.hints.hasMinF && fv < p.hints.minF) fv = p.hints.minF;
                    if (p.hints.hasMaxF && fv > p.hints.maxF) fv = p.hints.maxF;
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
                *p.vptr = Vec3(_jsonFloat(a[0]), _jsonFloat(a[1]), _jsonFloat(a[2]));
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
                foreach (i, ref vJson; jp.array) {
                    if (vJson.type != JSONType.array || vJson.array.length != 3)
                        throw new Exception(
                            "param '" ~ p.name ~ "[" ~ i.to!string ~ "]' must be [x,y,z]");
                    result[i] = Vec3(_jsonFloat(vJson.array[0]),
                                     _jsonFloat(vJson.array[1]),
                                     _jsonFloat(vJson.array[2]));
                }
                *p.v3aPtr = result;
                break;
            }
        }
    }
}

// Private helper: accept integer, uinteger, or float_ JSON nodes as float.
private float _jsonFloat(ref JSONValue v)
{
    if (v.type == JSONType.integer)  return cast(float)v.integer;
    if (v.type == JSONType.uinteger) return cast(float)v.uinteger;
    if (v.type == JSONType.float_)   return cast(float)v.floating;
    return 0.0f;
}

unittest {
    // injectParamsInto clamps Int/Float writes to declared .min()/.max()
    // hints (task 0314) ONLY when the Param opts in via `.enforceBounds()`
    // — both directions, and a value already in-range passes through
    // unchanged. Mirrors prim.cube's `segmentsR` (`.min(1).max(64)`), the
    // concrete DoS repro.
    import std.conv : to;

    int    segs = 3;
    float  radius = 10.0f;
    auto ps = Param.int_("segmentsR", "Radius Segments", &segs, 3)
        .min(1).max(64).enforceBounds();
    auto pr = Param.float_("radius", "Radius", &radius, 10.0f)
        .min(0.0f).max(20.0f).enforceBounds();
    auto arr = [ps, pr];

    JSONValue pj = JSONValue(cast(JSONValue[string]) null);
    pj["segmentsR"] = JSONValue(1000);   // way over max(64)
    pj["radius"]    = JSONValue(-5.0);   // under min(0.0)
    injectParamsInto(arr, pj);
    assert(segs   == 64, "segmentsR should clamp to declared max(64), got " ~ segs.to!string);
    assert(radius == 0.0f, "radius should clamp to declared min(0.0), got " ~ radius.to!string);

    // Below min(1) also clamps (not just the max side) once opted in.
    JSONValue pj2 = JSONValue(cast(JSONValue[string]) null);
    pj2["segmentsR"] = JSONValue(-10);
    injectParamsInto(arr, pj2);
    assert(segs == 1, "segmentsR should clamp to declared min(1), got " ~ segs.to!string);

    // In-range values pass through unchanged.
    JSONValue pj3 = JSONValue(cast(JSONValue[string]) null);
    pj3["segmentsR"] = JSONValue(10);
    pj3["radius"]    = JSONValue(0.3);
    injectParamsInto(arr, pj3);
    assert(segs == 10, "in-range segmentsR should pass through, got " ~ segs.to!string);
    assert(radius > 0.29f && radius < 0.31f,
        "in-range radius should pass through, got " ~ radius.to!string);

    // A Param with hints but NO `.enforceBounds()` opt-in is never clamped
    // (task 0314's design: hints stay UI-only metadata unless a Param
    // explicitly asks for headless enforcement). This is the case that
    // matters for commands.mesh.sweep's `count` (`.min(2)`, no
    // `.enforceBounds()`), whose own apply()-time check
    // (`if (count_ < 2) return false;`) is the real authority — see
    // tests/test_mesh_sweep.d's "count < 2 → error, mesh unchanged".
    int countLike = 8;
    auto pc = Param.int_("count", "Count", &countLike, 8).min(2);
    auto arrC = [pc];
    JSONValue pj4 = JSONValue(cast(JSONValue[string]) null);
    pj4["count"] = JSONValue(1);   // below min(2), NOT enforced
    injectParamsInto(arrC, pj4);
    assert(countLike == 1,
        "non-opted-in min hint must pass through unclamped (caller's own "
        ~ "domain check decides accept/reject), got " ~ countLike.to!string);

    // A Param with no hints at all is likewise never clamped, however
    // large the value (enforceBounds() with no min/max hint is a no-op).
    int unbounded = 0;
    auto pu = Param.int_("free", "Free", &unbounded, 0);
    auto arrU = [pu];
    JSONValue pj5 = JSONValue(cast(JSONValue[string]) null);
    pj5["free"] = JSONValue(99999);
    injectParamsInto(arrU, pj5);
    assert(unbounded == 99999, "hint-less param must not be clamped");
}
