// Module unittests for `argstring`, moved verbatim out of packages/common/source/argstring.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module vibe3d.editing.params.tests.unit.argstring_test;

import std.json    : JSONValue, JSONType, parseJSON;
import std.ascii   : isAlpha, isAlphaNum, isDigit, isWhite;
import std.conv    : to, ConvException;
import std.string  : strip;
import std.format  : format;
import std.array   : join;
import vibe3d.editing.params.params      : Param, IntEnumEntry, isUserSet, fmtFloatWire;
import vibe3d.util.math.math : Vec3;
import std.math : fabs;
import vibe3d.editing.params.params : fmtFloatWire, stringifyParam;
import std.exception : assertThrown;
import vibe3d.editing.params.argstring;


unittest { // a number with an exponent is one float token (task 9492: `1e30` read as 1)
    auto pos = parseArgstring("tool.attr prim.cube radius 5e2").params[kPositionalKey].array;
    assert(pos.length == 3 && pos[2].type == JSONType.float_ && pos[2].floating == 500,
           "5e2 -> " ~ pos.to!string);
    auto big = parseArgstring("a 1e30 -2.5E-3 7e+1 x:3e2").params;
    assert(big[kPositionalKey].array[0].floating == 1e30
        && big[kPositionalKey].array[1].floating == -2.5e-3
        && big[kPositionalKey].array[2].floating == 70
        && big["x"].floating == 300, "exponent forms -> " ~ big.toString);
}

// ---------------------------------------------------------------------------
// Serializer inline unit tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import vibe3d.util.math.math : Vec3;

    unittest { // 1. Empty schema → empty string
        string s = serializeParams([]);
        assert(s == "", s);
    }

    unittest { // 2. All-default params → empty (nothing user-set)
        bool b = false;
        int  i = 4;
        float f = 0.1f;
        auto schema = [
            Param.bool_ ("flag",  "F", &b, false),
            Param.int_  ("segs",  "S", &i, 4),
            Param.float_("width", "W", &f, 0.1f),
        ];
        assert(serializeParams(schema) == "");
        assert(serializeCommand("cmd", schema) == "cmd");
    }

    unittest { // 3. Bool set → "flag:true"
        bool b = false;
        auto schema = [Param.bool_("flag", "F", &b, false)];
        b = true;
        assert(serializeParams(schema) == "flag:true");
    }

    unittest { // 4. Int set — round-trip
        int i = 4;
        auto schema = [Param.int_("segs", "Segments", &i, 4)];
        i = 8;
        string s = serializeCommand("mesh.bevel", schema);
        assert(s == "mesh.bevel segs:8", s);
        auto parsed = parseArgstring(s);
        assert(parsed.commandId == "mesh.bevel");
        assert(parsed.params["segs"].type == JSONType.integer);
        assert(parsed.params["segs"].integer == 8);
    }

    unittest { // 5. Float set — round-trip with tolerance
        import std.math : fabs;
        float f = 0.0f;
        auto schema = [Param.float_("dist", "Distance", &f, 0.0f).min(0.0f)];
        f = 0.001f;
        string s = serializeCommand("vert.merge", schema);
        assert(s == "vert.merge dist:0.001", s);
        auto parsed = parseArgstring(s);
        assert(parsed.commandId == "vert.merge");
        assert(parsed.params["dist"].type == JSONType.float_);
        assert(fabs(parsed.params["dist"].floating - 0.001) < 1e-6);
    }

    unittest { // 6. Float with NaN default (widthR pattern) — round-trip
        import std.math : fabs;
        float f = float.nan;
        auto schema = [Param.float_("widthR", "Width R", &f, float.nan)];
        // NaN == NaN → not user-set
        assert(serializeParams(schema) == "");
        // Set to a real value
        f = 0.05f;
        string s = serializeCommand("mesh.bevel", schema);
        assert(s == "mesh.bevel widthR:0.05", s);
        auto parsed = parseArgstring(s);
        assert(fabs(parsed.params["widthR"].floating - 0.05) < 1e-6);
    }

    unittest { // 7. String with spaces → quoted; round-trip
        string sv = "";
        auto schema = [Param.string_("path", "Path", &sv, "")];
        sv = "hello world";
        string s = serializeCommand("file.load", schema);
        assert(s == `file.load path:"hello world"`, s);
        auto parsed = parseArgstring(s);
        assert(parsed.params["path"].str == "hello world");
    }

    unittest { // 8. String containing a double-quote → escaped; round-trip
        string sv = "";
        auto schema = [Param.string_("key", "Key", &sv, "")];
        sv = `a"b`;
        string s = serializeCommand("cmd", schema);
        assert(s == `cmd key:"a\"b"`, s);
        auto parsed = parseArgstring(s);
        assert(parsed.params["key"].str == `a"b`);
    }

    unittest { // 9. Vec3 — round-trip
        import std.math : fabs;
        Vec3 v = Vec3(0, 0, 0);
        auto schema = [Param.vec3_("from", "From", &v, Vec3(0, 0, 0))];
        v = Vec3(-0.5f, 0.5f, 1.0f);
        string s = serializeCommand("mesh.move_vertex", schema);
        // %g emits "1" for 1.0 (no trailing .0), so the serialized form is:
        assert(s == "mesh.move_vertex from:{-0.5,0.5,1}", s);
        auto parsed = parseArgstring(s);
        auto arr = parsed.params["from"].array;
        assert(arr.length == 3);
        // Helper: read numeric JSONValue as double regardless of int/float type.
        static double asNum(ref JSONValue jv) {
            if (jv.type == JSONType.float_)   return jv.floating;
            if (jv.type == JSONType.integer)  return cast(double)jv.integer;
            assert(false, "expected numeric JSONValue");
        }
        assert(fabs(asNum(arr[0]) - (-0.5)) < 1e-6);
        assert(fabs(asNum(arr[1]) -   0.5)  < 1e-6);
        assert(fabs(asNum(arr[2]) -   1.0)  < 1e-6);
    }

    unittest { // 10. Enum (string-backed): wireTag "offset" → "mode:offset"; round-trip
        string mode = "offset";
        auto schema = [Param.enum_("mode", "Mode", &mode,
                                   [["offset","Offset"],["width","Width"]], "offset")];
        // Default — not user-set
        assert(serializeParams(schema) == "");
        mode = "width";
        string s = serializeCommand("mesh.bevel", schema);
        assert(s == "mesh.bevel mode:width", s);
        auto parsed = parseArgstring(s);
        assert(parsed.params["mode"].str == "width");
    }

    unittest { // 11. IntEnum (int-backed): wireTag lookup → "mode:offset"; round-trip
        int v = 0;
        auto schema = [Param.intEnum_("mode", "Mode", &v,
            [IntEnumEntry(0, "offset", "Offset"),
             IntEnumEntry(1, "width",  "Width"),
             IntEnumEntry(2, "depth",  "Depth")],
            0)];
        // Default → not user-set
        assert(serializeParams(schema) == "");
        v = 1;
        string s = serializeCommand("mesh.bevel", schema);
        assert(s == "mesh.bevel mode:width", s);
        auto parsed = parseArgstring(s);
        assert(parsed.params["mode"].str == "width");
    }

    unittest { // 12. Mixed kinds — verify exact output and round-trip
        import std.math : fabs;
        bool keep  = false;
        float dist = 0.0f;
        string mode = "fixed";
        int   segs = 1;

        auto schema = [
            Param.bool_  ("keep",  "Keep",     &keep,  false),
            Param.float_ ("dist",  "Distance", &dist,  0.0f),
            Param.enum_  ("range", "Range",    &mode,
                          [["fixed","Fixed"],["overlap","Overlap"]], "fixed"),
            Param.int_   ("segs",  "Segments", &segs,  1),
        ];

        // Set all to non-default values
        keep = true;
        dist = 0.001f;
        // mode stays "fixed" → not user-set, should be skipped
        segs = 3;

        string s = serializeCommand("vert.merge", schema);
        assert(s == "vert.merge keep:true dist:0.001 segs:3", s);

        auto parsed = parseArgstring(s);
        assert(parsed.commandId == "vert.merge");
        assert(parsed.params["keep"].type == JSONType.true_);
        assert(fabs(parsed.params["dist"].floating - 0.001) < 1e-6);
        assert(("range" in parsed.params) is null);  // was not user-set
        assert(parsed.params["segs"].integer == 3);
    }

    unittest { // 13. IntArray serializes as <N> placeholder (not round-trip-safe)
        uint[] idx = [0u, 5u, 7u];
        auto schema = [Param.intArray_("indices", "Indices", &idx)];
        string s = serializeParams(schema);
        assert(s == "indices:<3>", s);
    }

    unittest { // 14. Vec3Array serializes as <N> placeholder (not round-trip-safe)
        import vibe3d.util.math.math : Vec3;
        Vec3[] pts = [Vec3(1, 2, 3), Vec3(4, 5, 6)];
        auto schema = [Param.vec3Array_("before", "Before", &pts)];
        string s = serializeParams(schema);
        assert(s == "before:<2>", s);
    }

    unittest { // 15. Empty arrays → not user-set → not emitted
        uint[]  idx;
        Vec3[]  pts;
        auto schema = [
            Param.intArray_ ("indices", "Indices", &idx),
            Param.vec3Array_("before",  "Before",  &pts),
        ];
        assert(serializeParams(schema) == "");
    }

}

// ---------------------------------------------------------------------------
// Inline unit tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.exception : assertThrown;

    unittest { // empty line → isEmpty
        auto r = parseArgstring("   ");
        assert(r.isEmpty);
    }

    unittest { // blank line
        auto r = parseArgstring("");
        assert(r.isEmpty);
    }

    unittest { // comment line
        auto r = parseArgstring("# this is a comment");
        assert(r.isEmpty);
    }

    unittest { // comment after leading whitespace
        auto r = parseArgstring("  # comment");
        assert(r.isEmpty);
    }

    unittest { // simple command with no params
        auto r = parseArgstring("mesh.poly_bevel");
        assert(!r.isEmpty);
        assert(r.commandId == "mesh.poly_bevel");
        assert(r.params.type == JSONType.object);
        assert(r.params.object.length == 0);
    }

    unittest { // vert.merge range:fixed dist:0.001 keep:false
        auto r = parseArgstring("vert.merge range:fixed dist:0.001 keep:false");
        assert(!r.isEmpty);
        assert(r.commandId == "vert.merge");
        assert(r.params["range"].str == "fixed");
        assert(r.params["keep"].type == JSONType.false_);
        // dist stored as float
        assert(r.params["dist"].type == JSONType.float_);
        import std.math : fabs;
        assert(fabs(r.params["dist"].floating - 0.001) < 1e-9);
    }

    unittest { // integer param stored as integer
        auto r = parseArgstring("mesh.bevel seg:2");
        assert(r.params["seg"].type == JSONType.integer);
        assert(r.params["seg"].integer == 2);
    }

    unittest { // quoted string with spaces
        auto r = parseArgstring(`file.load path:"my file.lwo"`);
        assert(r.commandId == "file.load");
        assert(r.params["path"].str == "my file.lwo");
    }

    unittest { // quoted string with escape sequences
        auto r = parseArgstring(`cmd key:"hello \"world\""`);
        assert(r.params["key"].str == `hello "world"`);
    }

    unittest { // vec3 array
        auto r = parseArgstring("mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{0.5,-0.5,-0.5}");
        assert(r.commandId == "mesh.move_vertex");
        auto fr = r.params["from"];
        assert(fr.type == JSONType.array);
        assert(fr.array.length == 3);
        import std.math : fabs;
        assert(fabs(fr.array[0].floating - (-0.5)) < 1e-9);
        assert(fabs(fr.array[1].floating - (-0.5)) < 1e-9);
        assert(fabs(fr.array[2].floating - (-0.5)) < 1e-9);
        auto to_ = r.params["to"];
        assert(fabs(to_.array[0].floating - 0.5) < 1e-9);
    }

    unittest { // boolean true
        auto r = parseArgstring("vert.join average:true");
        assert(r.params["average"].type == JSONType.true_);
    }

    unittest { // negative number
        auto r = parseArgstring("cmd x:-1.5");
        assert(r.params["x"].type == JSONType.float_);
        import std.math : fabs;
        assert(fabs(r.params["x"].floating - (-1.5)) < 1e-9);
    }

    unittest { // syntax error: missing value after ':'
        assertThrown!Exception(parseArgstring("cmd key:"));
    }

    unittest { // syntax error: missing ':' (two bare words that look like named pair attempt)
        // "cmd key value" — "key" starts an identifier but "value" follows without ':'
        // so "key" is treated as positional, then "value" is also positional. No error.
        auto r = parseArgstring("cmd key value");
        assert(!r.isEmpty);
        assert(r.commandId == "cmd");
        assert("_positional" in r.params);
        assert(r.params["_positional"].array.length == 2);
        assert(r.params["_positional"].array[0].str == "key");
        assert(r.params["_positional"].array[1].str == "value");
    }

    unittest { // identifier with dot
        auto r = parseArgstring("mesh.bevel mode:offset seg:3");
        assert(r.commandId == "mesh.bevel");
        assert(r.params["mode"].str == "offset");
        assert(r.params["seg"].integer == 3);
    }

    // --- positional arg tests (4.3) ---

    unittest { // single positional arg
        auto r = parseArgstring("tool.set bevel");
        assert(!r.isEmpty);
        assert(r.commandId == "tool.set");
        assert("_positional" in r.params);
        assert(r.params["_positional"].array.length == 1);
        assert(r.params["_positional"].array[0].str == "bevel");
    }

    unittest { // two positional args
        auto r = parseArgstring("tool.set bevel off");
        assert(r.commandId == "tool.set");
        auto pos = r.params["_positional"].array;
        assert(pos.length == 2);
        assert(pos[0].str == "bevel");
        assert(pos[1].str == "off");
    }

    unittest { // three positional args (tool.attr toolId name value)
        auto r = parseArgstring("tool.attr bevel width 0.1");
        assert(r.commandId == "tool.attr");
        auto pos = r.params["_positional"].array;
        assert(pos.length == 3);
        assert(pos[0].str == "bevel");
        assert(pos[1].str == "width");
        import std.math : fabs;
        assert(pos[2].type == JSONType.float_);
        assert(fabs(pos[2].floating - 0.1) < 1e-9);
    }

    unittest { // mixed: positional + named
        auto r = parseArgstring("tool.set bevel width:0.1");
        assert(r.commandId == "tool.set");
        auto pos = r.params["_positional"].array;
        assert(pos.length == 1);
        assert(pos[0].str == "bevel");
        import std.math : fabs;
        assert(fabs(r.params["width"].floating - 0.1) < 1e-9);
    }

    unittest { // positional integer value
        auto r = parseArgstring("cmd 42");
        auto pos = r.params["_positional"].array;
        assert(pos.length == 1);
        assert(pos[0].type == JSONType.integer);
        assert(pos[0].integer == 42);
    }

    unittest { // positional after named is an error
        assertThrown!Exception(parseArgstring("cmd name:val positional"));
    }

    unittest { // no _positional key when no positional args
        auto r = parseArgstring("cmd name:val");
        assert(("_positional" in r.params) is null);
    }
}
