/**
 * argstring.d — MODO-style argstring parser for Vibe3D.
 *
 * Grammar (subphase 4.1 — named pairs only; positional args deferred to 4.3):
 *
 *   line       = empty | comment | command
 *   empty      = whitespace*
 *   comment    = whitespace* '#' .*
 *   command    = identifier (whitespace+ pair)*
 *   identifier = [a-zA-Z_][a-zA-Z0-9_.]*
 *   pair       = identifier ':' value
 *   value      = bool | number | quoted | vec_array | bareword
 *   bool       = 'true' | 'false'
 *   number     = '-'? [0-9]+ ('.' [0-9]+)?
 *   quoted     = '"' (escaped | non-quote)* '"'
 *   vec_array  = '{' value (',' value)* '}'
 *   bareword   = [a-zA-Z0-9_./-]+
 *
 * Numbers with a decimal point are stored as JSONType.float_;
 * integers as JSONType.integer.  Booleans as JSONType.true_/false_.
 * Bare identifiers and quoted strings as JSONType.string.
 * Vec arrays as JSONType.array.
 */
module argstring;

import std.json    : JSONValue, JSONType, parseJSON;
import std.ascii   : isAlpha, isAlphaNum, isDigit, isWhite;
import std.conv    : to, ConvException;
import std.string  : strip;
import std.format  : format;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Result of parsing one argstring line.
struct ParsedLine {
    /// True for empty lines and comment lines — skip without error.
    bool      isEmpty;
    /// Command identifier, e.g. "vert.merge".
    string    commandId;
    /// JSON object built from name:value pairs.
    JSONValue params;
}

/**
 * Parse one MODO-style argstring line.
 *
 * Returns a ParsedLine with isEmpty=true for blank lines and # comments.
 * Throws Exception (with column info) on syntax errors.
 */
ParsedLine parseArgstring(string line)
{
    auto p = Parser(line);
    return p.parseLine();
}

// ---------------------------------------------------------------------------
// Internal parser
// ---------------------------------------------------------------------------

private struct Parser
{
    string src;
    size_t pos;

    this(string s) { src = s; pos = 0; }

    // --- character helpers ---

    bool atEnd() const { return pos >= src.length; }
    char cur()   const { return atEnd ? '\0' : src[pos]; }

    void advance() { if (!atEnd) ++pos; }

    void skipWS() {
        while (!atEnd && isWhite(cur)) advance();
    }

    // --- error helper ---

    Exception err(string msg) const {
        return new Exception(format("argstring col %d: %s", pos + 1, msg));
    }

    // --- top-level ---

    ParsedLine parseLine()
    {
        skipWS();
        // Empty or comment
        if (atEnd || cur == '#') {
            ParsedLine r;
            r.isEmpty = true;
            return r;
        }

        // Command identifier
        string cmdId = parseIdentifier();
        if (cmdId.length == 0)
            throw err("expected command identifier");

        // Named pairs
        JSONValue params = JSONValue(cast(JSONValue[string]) null); // empty object

        while (true) {
            skipWS();
            if (atEnd || cur == '#') break;

            // Must be identifier ':' value
            size_t savedPos = pos;
            string name = parseIdentifier();
            if (name.length == 0)
                throw err("expected 'name:value' pair");

            skipWS();
            if (atEnd || cur != ':')
                throw err(format("expected ':' after '%s'", name));
            advance(); // consume ':'

            JSONValue val = parseValue();
            params[name] = val;
        }

        ParsedLine r;
        r.isEmpty   = false;
        r.commandId = cmdId;
        r.params    = params;
        return r;
    }

    // --- identifier: [a-zA-Z_][a-zA-Z0-9_.]* ---

    string parseIdentifier()
    {
        if (atEnd || (!isAlpha(cur) && cur != '_'))
            return "";
        size_t start = pos;
        while (!atEnd && (isAlphaNum(cur) || cur == '_' || cur == '.'))
            advance();
        return src[start .. pos].idup;
    }

    // --- value dispatch ---

    JSONValue parseValue()
    {
        skipWS();
        if (atEnd)
            throw err("expected value, got end of line");

        char c = cur;

        // Vec array: { v1, v2, ... }
        if (c == '{')
            return parseVecArray();

        // Quoted string
        if (c == '"')
            return parseQuotedString();

        // Number: optional leading '-', then digit
        if (c == '-' || isDigit(c))
            return parseNumber();

        // Boolean or bare identifier
        return parseBoolOrBareword();
    }

    // --- vec_array: '{' value (',' value)* '}' ---

    JSONValue parseVecArray()
    {
        assert(cur == '{');
        advance(); // consume '{'
        skipWS();

        JSONValue[] elems;

        if (!atEnd && cur == '}') {
            advance();
            return JSONValue(elems);
        }

        while (true) {
            skipWS();
            elems ~= parseValue();
            skipWS();
            if (atEnd)
                throw err("unterminated vec array, expected '}'");
            if (cur == '}') { advance(); break; }
            if (cur != ',')
                throw err(format("expected ',' or '}' in vec array, got '%s'", cur));
            advance(); // consume ','
        }

        return JSONValue(elems);
    }

    // --- quoted string: '"' (escape | non-'"')* '"' ---

    JSONValue parseQuotedString()
    {
        assert(cur == '"');
        advance(); // consume opening '"'
        string result;
        while (true) {
            if (atEnd)
                throw err("unterminated quoted string");
            char c = cur;
            if (c == '"') { advance(); break; }
            if (c == '\\') {
                advance();
                if (atEnd)
                    throw err("backslash at end of string");
                char esc = cur;
                advance();
                switch (esc) {
                    case '"':  result ~= '"';  break;
                    case '\\': result ~= '\\'; break;
                    case 'n':  result ~= '\n'; break;
                    case 't':  result ~= '\t'; break;
                    default:   result ~= esc;  break;
                }
            } else {
                result ~= c;
                advance();
            }
        }
        return JSONValue(result);
    }

    // --- number: '-'? [0-9]+ ('.' [0-9]+)? ---

    JSONValue parseNumber()
    {
        size_t start = pos;
        bool isFloat = false;

        if (cur == '-') advance();
        if (atEnd || !isDigit(cur))
            throw err("expected digit after '-'");
        while (!atEnd && isDigit(cur)) advance();

        if (!atEnd && cur == '.') {
            isFloat = true;
            advance();
            if (atEnd || !isDigit(cur))
                throw err("expected digit after '.'");
            while (!atEnd && isDigit(cur)) advance();
        }

        string raw = src[start .. pos].idup;
        try {
            if (isFloat)
                return JSONValue(raw.to!double);
            else
                return JSONValue(raw.to!long);
        } catch (ConvException e) {
            throw err(format("invalid number '%s': %s", raw, e.msg));
        }
    }

    // --- bool or bareword ---

    JSONValue parseBoolOrBareword()
    {
        size_t start = pos;
        // Bareword chars: [a-zA-Z0-9_./-]
        while (!atEnd && (isAlphaNum(cur) || cur == '_' || cur == '.' ||
                          cur == '/' || cur == '-'))
            advance();

        string word = src[start .. pos].idup;
        if (word.length == 0)
            throw err(format("unexpected character '%s'", cur));

        if (word == "true")  return JSONValue(true);
        if (word == "false") return JSONValue(false);

        // Check if it looks like a number that started with '-' — already
        // handled by parseNumber via the '-' branch, but bare "-" or
        // "-word" could land here. Treat as string.
        return JSONValue(word);
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

    unittest { // syntax error: missing ':'
        assertThrown!Exception(parseArgstring("cmd key value"));
    }

    unittest { // identifier with dot
        auto r = parseArgstring("mesh.bevel mode:offset seg:3");
        assert(r.commandId == "mesh.bevel");
        assert(r.params["mode"].str == "offset");
        assert(r.params["seg"].integer == 3);
    }
}
