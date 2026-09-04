/**
 * command_args.d — THE argument-binding law, and its one implementation.
 *
 * TASK 4062. Before this module a command line bound by different rules
 * depending on which door it entered by:
 *
 *   * the HTTP dispatcher (`http_providers.dispatchCommandLine`) ran four
 *     hand-written injectors that cast to 37 concrete command classes and
 *     filled their fields through setters — three different laws for the ten
 *     `viewport.*` ids alone;
 *   * the keyboard / pie funnel (`input_router.runCommandWithArgs`) mapped
 *     positionals onto `params()` in DECLARATION order, and so bound nothing
 *     at all for the 47 ids whose arguments only the injectors knew about;
 *   * the panel funnel (`ui.panels.dispatchAction`) called a no-argument
 *     factory.
 *
 * So `select.element vertex add 3` from a keyboard and the same line over
 * HTTP bound differently, and only one of the two ever reported a refusal.
 *
 * THE LAW, decided by the owner: **positional arguments bind in the order the
 * command declares its parameters, everywhere.** `params()` is the single
 * statement of what a command's arguments are; this module is the single
 * implementation of that statement; every funnel calls `bindArgs`.
 *
 * WHAT THE LAW COST, recorded here because the card reserves an escape hatch
 * for exactly this and three commands took it:
 *
 *   1. `select.element <type> <action> <idx...>` takes a VARIABLE-LENGTH list.
 *      An array-kind slot ABSORBS the remaining positionals — the rule the
 *      card predicted would be needed, stated once here rather than per
 *      command.
 *   2. `tool.attr` / `layer.attr` FORWARD their value slot to another
 *      schema's injector, so the value's JSON TYPE decides whether the write
 *      lands. Those slots are declared `Param.jsonArg_` (`ParamFlags.JsonText`)
 *      and receive the argument's raw JSON text.
 *   3. `tool.set <id> [off] [name:val ...]` forwards the named args the schema
 *      did not claim to the tool it activates. Those reach the command through
 *      `Command.setUnboundArgs`, a base hook with one override.
 *
 * WHAT IT DID NOT COST: the wire contract (task 0761). A payload that bound
 * before binds to the same fields now. The one deliberate difference is that a
 * command may now REFUSE for its own reason where a wrapper used to swallow
 * the argument and leave the field empty.
 *
 * VALIDATE ONLY WHAT THE PAYLOAD SUPPLIES. An absent key is left alone —
 * `injectParamsInto`'s own contract — so a command still meets its
 * preconditions itself and answers for them itself. A binder that filled in
 * defaults, or refused a field nobody sent, would turn every command's own
 * refusal into a binder error about a missing field (the failure card 4131
 * diagnoses).
 */
module command_args;

import std.json : JSONValue, JSONType, parseJSON;

import command  : Command;
import params   : Param, injectParamsInto;
import argstring : kPositionalKey;

// ---------------------------------------------------------------------------
// The scalar spelling of a JSON argument.
//
// Moved here from `http_providers.d` (where it had arrived from app.d), because
// this is now the module that coerces an argument to its declared kind and the
// function had exactly one caller left there.
//
// `true` is a JSON bool, so a command whose argument is "a value, whatever
// kind" cannot read `.str` and hope. `%.9g` rather than `%g` on the float lane
// so a value the user typed survives the trip in full precision — `%g`'s six
// significant digits would quietly round a speed multiplier.
// ---------------------------------------------------------------------------
string scalarArgToString(JSONValue v) {
    import std.format : format;
    import std.conv   : to;
    switch (v.type) {
        case JSONType.string:   return v.str;
        // json-num-exempt: builds an argstring, not a JSON body
        case JSONType.float_:   return format("%.9g", v.floating);
        case JSONType.integer:  return to!string(v.integer);
        case JSONType.uinteger: return to!string(v.uinteger);
        case JSONType.true_:    return "true";
        case JSONType.false_:   return "false";
        default:                return "";
    }
}

/// The `?` idiom: this token in a value slot READS the attribute instead of
/// writing it. One spelling, named once — see `Command.acceptsQuery`.
enum string kQueryToken = "?";

// ---------------------------------------------------------------------------
// Payload construction — so a caller that wants to send positional arguments
// does not have to spell the wire key.
//
// `"_positional"` was written out 53 times across five modules; the key is an
// argstring implementation detail and every hand-built copy was a chance to
// misspell it silently (a misspelt key binds NOTHING and reports success).
// ---------------------------------------------------------------------------

/// A `/api/command` params body carrying `args` as positional arguments.
/// Each element is sent as a JSON string — the spelling every hand-built
/// caller used.
string positionalPayload(const(string)[] args) {
    JSONValue[] pos;
    foreach (a; args) pos ~= JSONValue(a);
    JSONValue o = JSONValue(cast(JSONValue[string]) null);
    o[kPositionalKey] = JSONValue(pos);
    return o.toString();
}

/// As above, plus named keys (already JSON values), for the callers that send
/// e.g. a `viewport` cell selector beside the positional value.
string positionalPayload(const(string)[] args, JSONValue[string] named) {
    JSONValue[] pos;
    foreach (a; args) pos ~= JSONValue(a);
    JSONValue o = JSONValue(cast(JSONValue[string]) null);
    o[kPositionalKey] = JSONValue(pos);
    foreach (k, v; named) o[k] = v;
    return o.toString();
}

/// The positional arguments of an already-parsed payload, or an empty slice.
/// Readers (a panel deciding whether a menu row is checked, the forms loader
/// binding a control line) go through this rather than indexing the key.
JSONValue[] positionalArgs(ref JSONValue params) {
    if (params.type != JSONType.object) return [];
    if (auto pp = kPositionalKey in params.object)
        if (pp.type == JSONType.array) return pp.array;
    return [];
}

/// The first positional argument as a string, or "" when there is none or it
/// is not a string. The shape five call sites hand-rolled.
string firstPositionalString(ref JSONValue params) {
    auto pos = positionalArgs(params);
    if (pos.length == 0) return "";
    if (pos[0].type != JSONType.string) return "";
    return pos[0].str;
}

// ---------------------------------------------------------------------------
// bindArgs — the one binder.
// ---------------------------------------------------------------------------

/// Bind a wire payload (the raw `params` body of `/api/command`, or the
/// serialised params of a parsed argstring line) onto `cmd`.
///
/// An empty body binds nothing. A body that is not an object is treated as a
/// single positional argument — `{"id":"viewport.view","params":"Top"}` is a
/// shape the route table has always accepted.
void bindArgs(Command cmd, string paramsJson) {
    if (cmd is null || paramsJson.length == 0) return;
    auto pj = parseJSON(paramsJson);   // throws on a malformed body, as before
    bindArgs(cmd, pj);
}

/// ditto
void bindArgs(Command cmd, ref JSONValue payload) {
    if (cmd is null) return;
    if (payload.type == JSONType.null_) return;

    // A bare scalar body IS the first positional argument.
    JSONValue obj;
    if (payload.type != JSONType.object) {
        obj = JSONValue(cast(JSONValue[string]) null);
        obj[kPositionalKey] = JSONValue([payload]);
    } else {
        obj = payload;
    }

    auto schema = cmd.params();

    // The named object the injector will finally see: every key the payload
    // carried except the positional list, plus each positional written into
    // the slot its POSITION names. Positional wins over a named key for the
    // same slot — the order every injector this replaces already had (see
    // `oneStringArg`'s unittest, which pinned it deliberately).
    JSONValue named = JSONValue(cast(JSONValue[string]) null);
    string[] unbound;
    foreach (string k, v; obj.object) {
        if (k == kPositionalKey) continue;
        named[k] = v;
        bool claimed = false;
        foreach (ref p; schema) {
            if (p.name == k) { claimed = true; break; }
            foreach (a; p.aliasNames) if (a == k) { claimed = true; break; }
            if (claimed) break;
        }
        if (!claimed) unbound ~= k;
    }

    // A named argument may also arrive under one of its slot's declared
    // aliases. Resolved BEFORE the positional pass so a positional still wins.
    foreach (ref p; schema) {
        if (p.aliasNames.length == 0) continue;
        if ((p.name in named.object) !is null) continue;
        foreach (a; p.aliasNames)
            if (auto v = a in named.object) { named[p.name] = *v; break; }
    }

    JSONValue[] pos = positionalArgs(obj);
    bool[string] fromPositional;
    size_t slot = 0;
    size_t i    = 0;
    while (i < pos.length && slot < schema.length) {
        auto p = schema[slot];
        fromPositional[p.name] = true;
        // An array slot ABSORBS the tail: `select.element vertex add 3 4 5`.
        if (p.kind == Param.Kind.IntArray || p.kind == Param.Kind.Vec3Array) {
            named[p.name] = JSONValue(pos[i .. $].dup);
            break;
        }
        // The `?` read-back token is not a value: it marks the command and
        // leaves the slot empty, so a query never carries a write.
        if (pos[i].type == JSONType.string && pos[i].str == kQueryToken
            && cmd.acceptsQuery()) {
            cmd.markQuery();
            named[p.name] = JSONValue("");
        } else {
            named[p.name] = coerceToSlot(pos[i], p);
        }
        ++i; ++slot;
    }

    // Named values are coerced to their slot's kind too, so `viewport:3` and
    // `viewport:"3"` reach an Int slot the same way. Slots a positional
    // already filled were coerced there and are skipped.
    foreach (ref p; schema) {
        if (p.name in fromPositional) continue;
        if (auto v = p.name in named.object)
            named[p.name] = coerceToSlot(*v, p);
    }

    if (schema.length > 0)
        injectParamsInto(schema, named);

    // Whatever the schema did not claim goes to the command whole. Default
    // no-op; `tool.set` is the one override (it forwards them to the tool it
    // activates).
    if (unbound.length > 0) {
        JSONValue bag = JSONValue(cast(JSONValue[string]) null);
        foreach (k; unbound) bag[k] = named[k];
        cmd.setUnboundArgs(bag);
    }
}

// ---------------------------------------------------------------------------
// coerceToSlot — ONE leniency law, in place of five.
//
// The injectors this replaces were each lenient in their own way: one
// stringified any scalar for a value slot, one parsed an int out of a string,
// one read "no"/"false"/"0" as false and anything else as true, three accepted
// a number where they wanted a name and silently dropped it. Written out once,
// the law is: an argument is coerced to the kind its slot DECLARES, and a
// value with no legal spelling in that kind is left alone for
// `injectParamsInto` to refuse — so the caller hears about it instead of the
// field silently keeping its default.
// ---------------------------------------------------------------------------
private JSONValue coerceToSlot(JSONValue v, ref Param p) {
    import std.conv : to, ConvException;
    final switch (p.kind) {
        case Param.Kind.Bool:
            // The tolerant reading the viewport independence toggles have
            // always had: "no"/"false"/"0" is false, any other word is true.
            if (v.type == JSONType.string) {
                immutable s = v.str;
                return JSONValue(!(s == "no" || s == "false" || s == "0"));
            }
            return v;
        case Param.Kind.Int:
        case Param.Kind.Float:
            if (v.type == JSONType.string) {
                try { return JSONValue(to!double(v.str)); }
                catch (ConvException) { return v; }  // refused downstream
            }
            return v;
        case Param.Kind.String:
            // A JsonText slot takes the argument's raw JSON TEXT; an ordinary
            // String slot takes its scalar spelling.
            if (p.jsonText_()) return JSONValue(v.toString());
            if (v.type == JSONType.string) return v;
            return JSONValue(scalarArgToString(v));
        case Param.Kind.Enum:
        case Param.Kind.IntEnum:
            // Both already accept the spellings they mean to accept (a tag,
            // and for IntEnum a raw integer); anything else must reach the
            // injector so the refusal names the parameter.
            return v;
        case Param.Kind.Vec3_:
        case Param.Kind.IntArray:
        case Param.Kind.Vec3Array:
            return v;
    }
}

// The unit tests for this law live in `tests/unit/command_bindargs_test.d`
// (module unittests under source/ are a ratchet the census gate holds down,
// task 4057), and the funnel-level parity test beside them drives the same
// lines through BOTH entry shapes against a written-down expectation rather
// than against each other.
