/**
 * argstring.d — argstring parser for Vibe3D.
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
 *   bareword   = [a-zA-Z0-9_./?#-]+
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
module vibe3d.editing.params.argstring;

import std.json    : JSONValue, JSONType, parseJSON;
import std.ascii   : isAlpha, isAlphaNum, isDigit, isWhite;
import std.conv    : to, ConvException;
import std.string  : strip;
import std.format  : format;
import std.array   : join;
import vibe3d.editing.params.params      : Param, IntEnumEntry, isUserSet, fmtFloatWire;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// The key positional arguments are collected under in a parsed line's
/// params object. Named once (task 4062): it was spelled out 53 times across
/// five modules, and a misspelt copy binds NOTHING while reporting success.
/// `command_args` re-exports the readers and writers that use it.
enum string kPositionalKey = "_positional";

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
 * Parse one argstring line.
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
// Serializer — dual of the parser above.
// ---------------------------------------------------------------------------

/**
 * Render `params` as an argstring fragment (just the
 * "name:val name:val ..." part — no command name).
 * Params for which isUserSet returns false (default-valued) are skipped.
 */
string serializeParams(Param[] params)
{
    string[] parts;
    foreach (ref p; params) {
        // A PodArray is a tool's session state (slice M3), never a replayable
        // argument: skipped, like a default-valued param.
        if (!isUserSet(p) || p.kind == Param.Kind.PodArray) continue;
        parts ~= p.name ~ ":" ~ _formatValue(p);
    }
    return parts.join(" ");
}

/// Join an ALREADY-serialized argstring to its command name. The canonical
/// command line: `"<id> <args>"`, or a bare `"<id>"` when there are no args.
///
/// Task 0705 (audit 4, D9): this two-line conditional was written out eight
/// times — six inside `command_history.d`'s recorders, plus
/// `undoEntryCommandLine` and `history.saveAsScript` — three of them
/// character-identical and the rest differing only in indentation and in the
/// name of the variable holding the args. `serializeCommand` below already
/// existed and was used NOWHERE in `source/`, because every caller had the
/// args in hand already and did not want them re-serialized. Splitting the
/// join out is what made the existing helper reachable.
string serializeCommandLine(string commandId, string args)
{
    return args.length > 0 ? commandId ~ " " ~ args : commandId;
}

/// Convenience: full argstring line with command name prefix.
/// If no user-set params exist, emits just the command name.
string serializeCommand(string commandId, Param[] params)
{
    return serializeCommandLine(commandId, serializeParams(params));
}

// --- private helpers ---

/// True when `c` belongs to the parser's bareword alphabet. Keep token
/// producers on this predicate instead of duplicating the grammar (task 6613).
bool isArgstringBarewordChar(char c)
{
    return isAlphaNum(c) || c == '_' || c == '.' || c == '/'
        || c == '-' || c == '?' || c == '#';
}

/// True when `s` can be emitted as one bare token. A leading `#` starts a
/// comment at token boundaries even though `#` is legal inside a bareword.
bool isArgstringBareword(string s)
{
    if (s.length == 0 || s[0] == '#') return false;
    foreach (c; s)
        if (!isArgstringBarewordChar(c)) return false;
    return true;
}

/// Quote and escape a token only when the parser cannot consume it bare.
string quoteArgstringToken(string s)
{
    return isArgstringBareword(s) ? s : _quote(s);
}

/// Returns true if the string value must be quoted in an argstring.
private bool _needsQuoting(string s)
{
    if (!isArgstringBareword(s)) return true;
    // A bareword starting with a digit will be parsed as a number on
    // round-trip — quote to disambiguate arbitrary string values.
    if (s[0] >= '0' && s[0] <= '9') return true;
    // "true" / "false" would be parsed as booleans on round-trip.
    if (s == "true" || s == "false") return true;
    return false;
}

/// Wrap a string in double-quotes, escaping '"' and '\'.
private string _quote(string s)
{
    string r = "\"";
    foreach (c; s) {
        if      (c == '"')  r ~= "\\\"";
        else if (c == '\\') r ~= "\\\\";
        else                r ~= c;
    }
    r ~= "\"";
    return r;
}

/// Quote a string value only if necessary (bareword-safe check first).
private string _quoteIfNeeded(string s)
{
    return _needsQuoting(s) ? _quote(s) : s;
}

/// Format a float component for argstring output.
///
/// Strategy: use %g (6 significant digits) for compactness. This is
/// sufficient for single-precision float values used in a mesh editor
/// (positions, weights, distances). The round-trip parser accepts values
/// within 1e-6 of the original. For values that need more digits (e.g.,
/// a float whose %g representation differs from the original by more than
/// float precision allows), callers should note that %g is still lossless
/// within 1 ULP for the common range [1e-4, 1e5].
///
/// NaN/Inf edge cases: isUserSet returns false for NaN-default+NaN-current,
/// so _fmtFloat should never be called for that case. If default != NaN but
/// current == NaN the param is in an invalid state — emit "nan" as sentinel.
///
/// Thin delegate to params.fmtFloatWire (task 0409 / 0407 D3) — the single
/// source for this exact %g-plus-NaN/Inf-sentinel format, also used by
/// forms.fmtFloatG and stringifyParam's Float case. The NaN/Inf semantics
/// documented above are preserved exactly (fmtFloatWire implements them).
private string _fmtFloat(float f)
{
    return fmtFloatWire(f);
}

/// Format the current value of a Param as an argstring token.
private string _formatValue(ref Param p)
{
    final switch (p.kind) {
        case Param.Kind.Bool:
            return *p.bptr ? "true" : "false";

        case Param.Kind.Int:
            return to!string(*p.iptr);

        case Param.Kind.Float:
            return _fmtFloat(*p.fptr);

        case Param.Kind.String:
            return _quoteIfNeeded(*p.sptr);

        case Param.Kind.Enum:
            return _quoteIfNeeded(*p.sptr);

        case Param.Kind.Vec3_:
            return format("{%s,%s,%s}",
                          _fmtFloat(p.vptr.x),
                          _fmtFloat(p.vptr.y),
                          _fmtFloat(p.vptr.z));

        case Param.Kind.IntEnum:
            foreach (ref entry; p.intEnumValues) {
                if (entry.value == *p.iePtr)
                    return _quoteIfNeeded(entry.wireTag);
            }
            // Fallback: no matching entry (shouldn't happen for valid enum).
            return to!string(*p.iePtr);

        // Arrays serialize as <N> placeholder — round-trip not supported.
        // Replay of array-parameter commands via argstring is best-effort only;
        // the canonical path for mesh.vertex_edit is JSON injection, not argstring.
        case Param.Kind.IntArray:
            return format("<%d>", (*p.uiaPtr).length);

        case Param.Kind.Vec3Array:
            return format("<%d>", (*p.v3aPtr).length);

        case Param.Kind.PodArray:
            return "";   // never emitted: the loop above skips the kind
    }
}

// ---------------------------------------------------------------------------
// Serializer inline unit tests
// ---------------------------------------------------------------------------

version (unittest)
{
    unittest { // 16. Byte-identity (task 0409): _fmtFloat / fmtFloatWire /
        // stringifyParam agree for the pinned value set. _fmtFloat is now a
        // thin delegate to params.fmtFloatWire (the single wire-format
        // source); params.stringifyParam's Float case uses the same helper —
        // this locks the two call sites together instead of relying on
        // sync-by-comment (forms.d has its own cross-check against
        // serializeParams()).
        import vibe3d.editing.params.params : fmtFloatWire, stringifyParam;
        immutable float[] vals = [0.0f, 1.0f, -1.0f, 0.5f, 1e-7f, -3.25f,
                                   1e20f, 123456.789f, 0.1f];
        foreach (v; vals) {
            float f = v;
            string tok = _fmtFloat(v);
            assert(tok == fmtFloatWire(v), tok);

            // stringifyParam formats a Float Param's CURRENT value the same
            // way, independent of isUserSet/default (unlike serializeParams,
            // which skips default-valued params entirely).
            auto p = Param.float_("f", "F", &f, float.nan);
            assert(stringifyParam(p) == tok, stringifyParam(p) ~ " vs " ~ tok);
        }

        // NaN/Inf sentinels — _fmtFloat's doc comment above documents that
        // isUserSet gates it away from the NaN-default+NaN-current case in
        // real serializeParams() calls, but the function itself still emits
        // the textual sentinel if ever invoked directly on NaN/Inf.
        assert(_fmtFloat(float.nan)       == "nan");
        assert(_fmtFloat(float.infinity)  == "inf");
        assert(_fmtFloat(-float.infinity) == "-inf");
    }
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
            params[kPositionalKey] = JSONValue(positionalArgs);

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
        // An exponent `[eE][+-]?digits` makes the token a float; an `e` with
        // no digits after it is left to the next token, as before.
        if (!atEnd && (cur == 'e' || cur == 'E')) {
            size_t q = pos + 1;
            if (q < src.length && (src[q] == '+' || src[q] == '-')) ++q;
            if (q < src.length && isDigit(src[q])) {
                isFloat = true;
                while (pos < q) advance();
                while (!atEnd && isDigit(cur)) advance();
            }
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
        // Bareword chars: [a-zA-Z0-9_./?#-]
        // '?' is admitted so the forms-engine query idiom
        // `tool.attr <id> <attr> ?` parses the trailing token as the literal
        // string "?" (the query sentinel) instead of throwing. No existing
        // command, preset, or test passes a bareword containing '?', so this
        // is backward-compatible.
        // '#' is admitted so stacked stage ids like `falloff#1` survive as a
        // single bareword positional (`tool.pipe.attr falloff#1 …`,
        // `falloff.remove falloff#1`). A LEADING '#' still starts a comment —
        // that is handled at token-start (after skipWS) before parseValue is
        // ever entered, so admitting '#' mid-bareword does not break comments.
        while (!atEnd && isArgstringBarewordChar(cur))
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
