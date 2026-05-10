module toolpipe.stage;

import toolpipe.pipeline : ToolState;
import params : Param, ParamProvider;
import math   : Vec3;
import std.conv   : to;
import std.format : format;
import std.string : split, strip;

// ---------------------------------------------------------------------------
// MODO Tool Pipe task codes (from LXSDK_661446/include/lxtool.h).
//
// Each stage in the pipe carries a TaskCode and an Ordinal. TaskCodes are
// FOURCC tags (`'A','C','E','N'`) packed into a uint for fast comparison;
// Ordinals are byte-sized priority keys that determine evaluation order
// (low → high). Values pinned to MODO so future SDK / Python bridging is
// 1:1.
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

// Default ordinals from LXs_ORD_* (lxtool.h). Stored as ubyte so a Stage's
// `ordinal` field doubles as the sort key for Pipeline.evaluate. Stages
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

    // Mutate `state` in place. Default: no-op (the stage is registered
    // but contributes nothing). Concrete stages override this to read
    // upstream packet values from `state` and write their own packet.
    void evaluate(ref ToolState state) {}

    // Whether this stage is currently enabled in the pipe. Disabled
    // stages are skipped during evaluation but stay in the pipe (matches
    // MODO's E column in tool_pipe.html).
    bool enabled = true;

    // ------------------------------------------------------------------
    // Schema (Phase 7.9): typed `Param[]` registry — same shape as
    // `Tool.params()`. PropertyPanel renders this via the shared
    // ParamProvider interface so stage attrs appear in Tool Properties
    // alongside the active tool's params, MODO-style.
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

    /// Header label for the stage's section in Tool Properties. Default
    /// = `id()` (wire key, e.g. "falloff"); concrete stages override
    /// for richer dynamic labels (e.g. "Linear Falloff" with the
    /// active type baked in). The wire key from id() stays canonical
    /// for HTTP / scripts; this is purely a UI presentation hook.
    string displayName() const { return id(); }

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
// Vec3-as-string format: "x,y,z" (matches `tool.pipe.attr falloff start
// 0,0.5,0` from the existing HTTP tests). Enum kind matches by wireTag
// (string for Param.Kind.Enum, intEnumValues.wireTag for IntEnum). Bool
// accepts true/false/1/0. Unknown attr name → return false.
// ---------------------------------------------------------------------------

bool defaultStageSetAttr(Stage s, string name, string value) {
    foreach (ref p; s.params()) {
        if (p.name != name) continue;
        bool ok = parseInto(p, value);
        if (ok) s.onParamChanged(name);
        return ok;
    }
    return false;
}

string[2][] defaultStageListAttrs(Stage s) {
    string[2][] out_;
    foreach (ref p; s.params())
        out_ ~= [p.name, stringifyParam(p)];
    return out_;
}

// Parse `value` per `p.kind` and write into the Param's typed pointer.
// Returns false on parse failure (caller surfaces as "rejected attr").
private bool parseInto(ref Param p, string value) {
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

private string stringifyParam(ref Param p) {
    final switch (p.kind) {
        case Param.Kind.Bool:    return *p.bptr ? "true" : "false";
        case Param.Kind.Int:     return format("%d", *p.iptr);
        case Param.Kind.Float:   return format("%g", *p.fptr);
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
