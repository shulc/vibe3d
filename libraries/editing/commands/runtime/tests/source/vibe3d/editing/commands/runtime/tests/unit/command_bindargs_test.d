// The argument-binding law (task 4062), tested as a law rather than as a
// funnel: `params()` IS the positional order, an absent key is left alone, a
// value is coerced to the kind its slot declares, an array slot absorbs the
// tail, a `?` marks a query only on a command that accepts one, and named keys
// the schema did not claim reach the command whole.
//
// The three escape hatches the law reserves are each pinned here, because each
// one is a place where a later reader would otherwise be tempted to "simplify"
// the binder back into a shape that silently drops an argument.
//
// Funnel PARITY — the same line entering by the keyboard door and by the HTTP
// door — is `tests/unit/command_bindargs_parity_test.d`, which compares both
// against a written-down expectation rather than against each other.
module vibe3d.editing.commands.runtime.tests.unit.command_bindargs_test;

import std.json : JSONValue, JSONType, parseJSON;

import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.commands.runtime.command_args;
import vibe3d.editing.params.params   : Param;
import vibe3d.mesh.core.mesh     : Mesh;
import vibe3d.viewport.camera.view     : View;
import vibe3d.editing.contracts.editmode : EditMode;

// A command whose whole content is its schema. Four slots of four different
// kinds, in a declared order, so "binds in declaration order" is a claim the
// fixture can actually falsify (a binder that bound by NAME, or by kind, or
// alphabetically, would put `7` somewhere else).
private final class BindTestCmd : Command {
    string  s1;
    string  s2;
    int     n = -1;
    bool    b = true;
    JSONValue bag;
    bool    queryable;

    this() {
        static Mesh m;
        static View v;
        super(&m, v, EditMode.Vertices);
        bag = JSONValue(cast(JSONValue[string]) null);
    }
    override string name() const { return "test.bind"; }
    override bool acceptsQuery() const { return queryable; }
    override void setUnboundArgs(JSONValue j) { bag = j; }
    override Param[] params() {
        return [ Param.string_("a", "A", &s1, ""),
                 Param.string_("b", "B", &s2, ""),
                 Param.int_("n", "N", &n, -1),
                 Param.bool_("flag", "Flag", &b, true) ];
    }
}

unittest { // positionals fill the slots in DECLARATION order
    auto c = new BindTestCmd();
    bindArgs(c, `{"_positional":["one","two",7,"no"]}`);
    assert(c.s1 == "one", "slot 0 takes positional 0");
    assert(c.s2 == "two", "slot 1 takes positional 1");
    assert(c.n  == 7,     "slot 2 takes positional 2");
    assert(c.b  == false, "slot 3 takes positional 3");
}

unittest { // a bare scalar body is positional[0] — a shape the route table takes
    auto c = new BindTestCmd();
    bindArgs(c, `"Top"`);
    assert(c.s1 == "Top");
    assert(c.s2 == "", "and nothing else is written");
}

unittest { // an absent key is LEFT ALONE — the command keeps its own default
    auto c = new BindTestCmd();
    bindArgs(c, `{"_positional":["one"]}`);
    assert(c.s1 == "one");
    assert(c.n == -1, "an unsupplied slot must not be written");
    assert(c.b == true);
    // The empty payload binds nothing at all rather than writing defaults:
    // a command must still answer for its own preconditions.
    auto d = new BindTestCmd();
    bindArgs(d, "");
    assert(d.s1 == "" && d.n == -1 && d.b == true);
}

unittest { // named keys bind by name, and a positional WINS over a named key
    auto c = new BindTestCmd();
    bindArgs(c, `{"n":3,"b":"named"}`);
    assert(c.n == 3);
    assert(c.s2 == "named");

    auto d = new BindTestCmd();
    bindArgs(d, `{"_positional":["pos"],"a":"named"}`);
    assert(d.s1 == "pos", "positional wins over the named key for the same slot");
}

unittest { // one coercion law: a number into a String slot, a string into Int
    auto c = new BindTestCmd();
    bindArgs(c, `{"_positional":[7,"x","12"]}`);
    assert(c.s1 == "7",  "a number reaching a String slot is spelled out");
    assert(c.n  == 12,   "a numeric string reaching an Int slot is parsed");

    // The tolerant bool the viewport independence toggles have always had.
    auto d = new BindTestCmd();
    bindArgs(d, `{"flag":"no"}`);
    assert(d.b == false);
    auto e = new BindTestCmd();
    bindArgs(e, `{"flag":"yes"}`);
    assert(e.b == true, "anything that is not no/false/0 is true");
}

unittest { // a value with no legal spelling in its slot's kind is REFUSED
    // Not silently dropped, which is what three of the four injectors did.
    auto c = new BindTestCmd();
    bool threw = false;
    try { bindArgs(c, `{"n":"zzz"}`); }
    catch (Exception e) { threw = true; }
    assert(threw, "an unparseable number must reach the injector's refusal");
    assert(c.n == -1, "and must not have written the field on the way");
}

unittest { // the `?` token marks a query only on a command that accepts one
    auto c = new BindTestCmd();
    c.queryable = true;
    bindArgs(c, `{"_positional":["one","?"]}`);
    assert(c.isQuery());
    assert(c.s1 == "one");
    assert(c.s2 == "", "the `?` is not written into the slot as a value");

    auto d = new BindTestCmd();
    d.queryable = false;
    bindArgs(d, `{"_positional":["one","?"]}`);
    assert(!d.isQuery(), "a command that does not accept a query is not marked");
    assert(d.s2 == "?", "and the token binds as an ordinary value it can refuse");
}

unittest { // ESCAPE HATCH 3 — named keys the schema did not claim, handed whole
    auto c = new BindTestCmd();
    bindArgs(c, `{"_positional":["one"],"size":3,"mode":"x"}`);
    assert(c.bag.type == JSONType.object);
    assert(c.bag["size"].integer == 3);
    assert(c.bag["mode"].str == "x");
    assert(("a" in c.bag.object) is null, "a claimed key is not in the bag");
}

private final class TailCmd : Command {
    string t;
    string act;
    uint[] idx;
    bool typePresent, actionPresent, indicesPresent;
    this() { static Mesh m; static View v; super(&m, v, EditMode.Vertices); }
    override string name() const { return "test.tail"; }
    override Param[] params() {
        return [ Param.string_("type", "Type", &t, "").present(&typePresent),
                 Param.string_("action", "Action", &act, "").present(&actionPresent),
                 Param.intArray_("indices", "Indices", &idx).present(&indicesPresent) ];
    }
}

unittest { // ESCAPE HATCH 1 — an array slot absorbs the tail
    auto c = new TailCmd();
    bindArgs(c, `{"_positional":["vertex","add",3,4,5]}`);
    assert(c.t == "vertex");
    assert(c.act == "add");
    assert(c.idx == [3u, 4u, 5u], "every remaining positional lands in the list");

    auto d = new TailCmd();
    bindArgs(d, `{"_positional":["vertex","set"]}`);
    assert(d.idx.length == 0, "an absent tail is an empty list, not a refusal");
}

private final class RawCmd : Command {
    string name_;
    string raw;
    this() { static Mesh m; static View v; super(&m, v, EditMode.Vertices); }
    override string name() const { return "test.raw"; }
    override Param[] params() {
        return [ Param.string_("attr", "Attr", &name_, ""),
                 Param.jsonArg_("value", "Value", &raw) ];
    }
}

unittest { // ESCAPE HATCH 2 — a JsonText slot keeps the argument's JSON TYPE
    auto c = new RawCmd();
    bindArgs(c, `{"_positional":["pos.x",1.5]}`);
    assert(c.raw == "1.5");
    assert(parseJSON(c.raw).type == JSONType.float_,
           "a number must still be a number when it reaches the target schema");
    assert(parseJSON(c.raw).floating == 1.5);

    auto d = new RawCmd();
    bindArgs(d, `{"_positional":["name","hello"]}`);
    assert(parseJSON(d.raw).str == "hello", "a string stays a string");

    auto b = new RawCmd();
    bindArgs(b, `{"_positional":["flag",true]}`);
    assert(parseJSON(b.raw).type == JSONType.true_, "a bool stays a bool");

    auto v = new RawCmd();
    bindArgs(v, `{"_positional":["pos",[1,2,3]]}`);
    assert(parseJSON(v.raw).array.length == 3, "a vector stays a vector");

    // The precision that made the raw text necessary rather than tidy:
    // `layer.attr` writes %.17g values, and the scalar spelling is %.9g.
    auto e = new RawCmd();
    bindArgs(e, `{"_positional":["pos.x",1.23456789012345]}`);
    assert(parseJSON(e.raw).floating == 1.23456789012345,
           "the JSON round-trip is exact at 17 significant digits");
}

unittest { // the payload helpers and the binder agree on the wire key
    auto c = new BindTestCmd();
    bindArgs(c, positionalPayload(["one", "two"]));
    assert(c.s1 == "one" && c.s2 == "two");

    auto pj = parseJSON(positionalPayload(["only"]));
    assert(firstPositionalString(pj) == "only");
    assert(positionalArgs(pj).length == 1);

    auto pk = parseJSON(positionalPayload(["v"], ["viewport": JSONValue(2)]));
    assert(firstPositionalString(pk) == "v");
    assert(pk["viewport"].integer == 2);

    JSONValue empty = parseJSON(`{}`);
    assert(firstPositionalString(empty) == "");
    assert(positionalArgs(empty).length == 0);
}


unittest { // Presence belongs to a successful supplied write, including [].
    import vibe3d.editing.params.params : injectParamsInto, injectParamsTolerant;
    auto omitted = new TailCmd();
    bindArgs(omitted, `{"_positional":["vertex","set"]}`);
    assert(omitted.typePresent && omitted.actionPresent && !omitted.indicesPresent,
        "omitted array tail must not establish presence");
    auto empty = new TailCmd();
    bindArgs(empty, `{"type":"vertex","action":"set","indices":[]}`);
    assert(empty.indicesPresent && empty.idx.length == 0,
        "explicit empty array must establish presence");
    auto tail = new TailCmd();
    bindArgs(tail, `{"_positional":["vertex","add",5,1]}`);
    assert(tail.indicesPresent && tail.idx == [5u, 1u],
        "positional tail must establish presence");
    auto bad = new TailCmd();
    bool refused;
    try { bindArgs(bad, `{"indices":[1,"bad"]}`); }
    catch (Exception e) { refused = true; }
    assert(refused && !bad.indicesPresent && bad.idx.length == 0,
        "malformed array must not establish presence or write storage");
    int ordinary = 7;
    bool present;
    auto ps = [Param.int_("value", "Value", &ordinary, 7).present(&present)];
    auto invalid = parseJSON(`{"value":"bad"}`);
    auto dropped = injectParamsTolerant(ps, invalid);
    assert(dropped == ["value"] && !present && ordinary == 7,
        "tolerated failed write must not establish presence");
    auto valid = parseJSON(`{"value":9}`);
    injectParamsInto(ps, valid);
    assert(present && ordinary == 9, "ordinary supplied parameter still writes");
    auto absent = parseJSON(`{}`);
    injectParamsInto(ps, absent);
    assert(present && ordinary == 9, "absent key must leave stable presence alone");
    auto unchanged = new BindTestCmd();
    bindArgs(unchanged, `{"n":11}`);
    assert(unchanged.n == 11 && unchanged.b, "unmarked ordinary parameters stay compatible");
}


unittest { // Each tolerant numeric shape skips both its write and presence marker.
    import vibe3d.editing.params.params : injectParamsTolerant;
    import vibe3d.util.math.math : Vec3;
    float scalar = 4;
    Vec3 vector = Vec3(1,2,3);
    Vec3[] vectors = [Vec3(4,5,6)];
    bool scalarPresent, vectorPresent, vectorsPresent;
    auto ps = [Param.float_("scalar", "Scalar", &scalar, 4).present(&scalarPresent),
        Param.vec3_("vector", "Vector", &vector, Vec3(1,2,3)).present(&vectorPresent),
        Param.vec3Array_("vectors", "Vectors", &vectors).present(&vectorsPresent)];
    auto invalid = parseJSON(`{"scalar":"bad","vector":[1,2,"bad"],"vectors":[[1,2,3],[4,5,"bad"]]}`);
    assert(injectParamsTolerant(ps, invalid) == ["scalar","vector","vectors[1]"]
        && !scalarPresent && !vectorPresent && !vectorsPresent
        && scalar == 4 && vector == Vec3(1,2,3) && vectors == [Vec3(4,5,6)],
        "tolerated numeric shapes must not establish presence or partial storage");
    auto supplied = parseJSON(`{"scalar":7,"vector":[7,8,9],"vectors":[[1,2,3]]}`);
    assert(injectParamsTolerant(ps, supplied).length == 0 && scalarPresent && vectorPresent && vectorsPresent,
        "successful numeric shapes establish presence");
}
