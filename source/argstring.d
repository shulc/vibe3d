/**
 * argstring.d — MODO-style argstring parser for Vibe3D.
 *
 * Grammar (subphase 4.3 — positional args allowed before named pairs):
 *
 *   line       = empty | comment | command
 *   empty      = whitespace*
 *   comment    = whitespace* '#' .*
 *   command    = identifier positional* pair*
 *   positional = whitespace+ value      (token that is NOT identifier ':')
 *   pair       = whitespace+ identifier ':' value
 *   identifier = [a-zA-Z_][a-zA-Z0-9_.]*
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
 *
 * If positional args were collected, they are stored in params["_positional"]
 * as a JSONType.array. Commands without positional args do not see this key.
 * Positional args after a named pair are a syntax error.
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

        // Positional args (before named pairs), then named pairs.
        // Lookahead: if next non-WS token looks like identifier ':' → named pair.
        //            Otherwise → positional.
        JSONValue params = JSONValue(cast(JSONValue[string]) null); // empty object
        JSONValue[] positionalArgs;
        bool namedStarted = false;

        while (true) {
            skipWS();
            if (atEnd || cur == '#') break;

            // Peek: is this token an identifier followed immediately by ':'?
            if (isNamedPairAhead()) {
                namedStarted = true;
                string name = parseIdentifier();
                if (name.length == 0)
                    throw err("expected 'name:value' pair");
                // isNamedPairAhead verified ':' follows immediately (no WS).
                if (atEnd || cur != ':')
                    throw err(format("expected ':' after '%s'", name));
                advance(); // consume ':'
                JSONValue val = parseValue();
                params[name] = val;
            } else {
                // Positional value
                if (namedStarted)
                    throw err("positional arg after named pair not allowed");
                positionalArgs ~= parseValue();
            }
        }

        if (positionalArgs.length > 0)
            params["_positional"] = JSONValue(positionalArgs);

        ParsedLine r;
        r.isEmpty   = false;
        r.commandId = cmdId;
        r.params    = params;
        return r;
    }

    // --- lookahead: is the next token an identifier followed by ':' ? ---
    // This determines whether the current position starts a named pair or
    // a positional value. Does not advance pos.

    bool isNamedPairAhead() const {
        // Must start with identifier-start char
        if (atEnd || (!isAlpha(cur) && cur != '_')) return false;
        // Scan forward over identifier chars
        size_t i = pos;
        while (i < src.length && (isAlphaNum(src[i]) || src[i] == '_' || src[i] == '.'))
            ++i;
        // If we consumed at least one char and the next char is ':', it's a pair.
        // Note: no whitespace between identifier and ':' in named pairs.
        if (i > pos && i < src.length && src[i] == ':')
            return true;
        return false;
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
