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

struct Param {
    enum Kind { Bool, Int, Float, Enum, String, Vec3_, IntEnum, IntArray, Vec3Array }

    string name;          // internal id — matches JSON wire key
    string label;         // UI label
    Kind   kind;
    ParamHints hints;
    // UI-only flag: when true, the Property Panel skips this param.
    // The schema entry stays so the headless HTTP/JSON injector and
    // argstring serialisation continue to see it.
    bool   hidden_;

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
    IntEnumEntry[] intEnumValues;

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
                          IntEnumEntry[] values, int default_)
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
    Param hidden()                    { hidden_ = true; return this; }
}

// ---------------------------------------------------------------------------
// isUserSet — returns true when the parameter's live storage value differs
// from the default recorded by the factory. Used by toArgstring (phase 5.2)
// to decide which params to emit; default-equal params are omitted, matching
// MODO's VALUE_SET semantics.
// ---------------------------------------------------------------------------

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
