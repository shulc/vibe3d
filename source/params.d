module params;

import math : Vec3;
import std.json : JSONValue, JSONType;

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

struct Param {
    enum Kind { Bool, Int, Float, Enum, String, Vec3_ }

    string name;          // internal id — matches JSON wire key
    string label;         // UI label
    Kind   kind;
    ParamHints hints;

    // Exactly one pointer is non-null, matching `kind`.
    union {
        bool*   bptr;
        int*    iptr;
        float*  fptr;
        string* sptr;
        Vec3*   vptr;
    }

    // For Kind.Enum: list of [internal_tag, user_label] pairs.
    // internal_tag is what is stored in *sptr and sent over the wire.
    string[2][] enumValues;

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
// ---------------------------------------------------------------------------

void injectParamsInto(Param[] params, ref JSONValue pj)
{
    foreach (ref p; params) {
        auto jp = p.name in pj.object;
        if (jp is null) continue;
        final switch (p.kind) {
            case Param.Kind.Bool:
                *p.bptr = (jp.type == JSONType.true_);
                break;
            case Param.Kind.Int:
                *p.iptr = cast(int)_jsonFloat(*jp);
                break;
            case Param.Kind.Float:
                *p.fptr = _jsonFloat(*jp);
                break;
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
