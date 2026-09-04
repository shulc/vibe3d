module item_rig_helpers;


import http_command_helpers : commandBody;
// The three-item rig shared by
//   tests/test_fixture_item_acen_primary_of_three.d  (which item the shared
//                                                     action centre follows)
//   tests/test_fixture_item_move_whole_set.d         (which items an item-mode
//                                                     translate moves)
//
// The two fixtures only mean what they say TOGETHER — "the centre follows the
// distinguished item ALONE, but the motion applies to EVERY selected item" is a
// statement about one state. So the rig is built here ONCE and driven from the
// fixture's own `rig` block, and `assertRigsIdentical` makes each test check
// that the other fixture's rig block is byte-for-byte the same data. Two
// hand-kept copies that merely happened to land on the same state (the earlier
// arrangement — one of them wrote pivots, the other did not) are exactly what
// this module exists to prevent.
//
// The shared HTTP client resolves VIBE3D_TEST_PORT at runtime, including for
// imported helper modules, so parallel workers cannot cross-connect.

import http_client : testBaseUrl;
import std.json;
import std.algorithm : sort, map;
import std.array     : array;
import std.conv      : to;
import std.format    : format;
import std.net.curl  : get, post;
import std.string    : split;

import fixture_helpers : asDouble;

alias BASE = testBaseUrl;

private JSONValue rigGet(string path) {
    return parseJSON(cast(string) get(BASE ~ path));
}

private JSONValue rigCmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

private void rigPostOk(string path, string body_) {
    auto j = parseJSON(cast(string) post(BASE ~ path, body_));
    assert(j["status"].str == "ok", path ~ " failed: " ~ j.toString);
}

private double[3] rigVec3(JSONValue arr) {
    assert(arr.array.length == 3, "expected a 3-vector, got " ~ arr.toString);
    return [asDouble(arr[0]), asDouble(arr[1]), asDouble(arr[2])];
}

/// A canonical, key-sorted rendering of a JSON value — `JSONValue.toString`
/// walks an associative array, so two objects carrying identical data can
/// stringify in different key orders. Used only by `assertRigsIdentical`.
private string canonical(JSONValue v) {
    final switch (v.type) {
        case JSONType.object:
            auto keys = v.object.keys.dup;
            keys.sort();
            string s = "{";
            foreach (i, k; keys) {
                if (i) s ~= ",";
                s ~= JSONValue(k).toString ~ ":" ~ canonical(v[k]);
            }
            return s ~ "}";
        case JSONType.array:
            string s = "[";
            foreach (i, e; v.array) { if (i) s ~= ","; s ~= canonical(e); }
            return s ~ "]";
        case JSONType.float_:
            // %.17g so 2.0 and 2 render the same and no precision is lost.
            return format("%.17g", v.floating);
        case JSONType.integer:
            return format("%.17g", cast(double) v.integer);
        case JSONType.uinteger:
            return format("%.17g", cast(double) v.uinteger);
        case JSONType.string:
            return JSONValue(v.str).toString;
        case JSONType.true_:  return "true";
        case JSONType.false_: return "false";
        case JSONType.null_:  return "null";
    }
}

/// The `rig` blocks of the two fixtures that share this builder must be the
/// same DATA, not merely rigs that reach the same state by accident. `comment`
/// is excluded — it is prose about the rig, not the rig.
void assertRigsIdentical(JSONValue rigA, string nameA, JSONValue rigB, string nameB) {
    JSONValue strip(JSONValue r) {
        JSONValue[string] o;
        foreach (k, v; r.object) if (k != "comment") o[k] = v;
        return JSONValue(o);
    }
    immutable string a = canonical(strip(rigA));
    immutable string b = canonical(strip(rigB));
    assert(a == b,
           format("%s and %s claim to share ONE rig, but their `rig` blocks differ.\n"
                  ~ "  %s: %s\n  %s: %s\n"
                  ~ "The two fixtures pin the action centre and the moving set on the "
                  ~ "SAME state; if the data drifts apart that pairing is a claim, not a "
                  ~ "fact. Update both, or drop the shared-rig claim from both.",
                  nameA, nameB, nameA, a, nameB, b));
}

/// Build the three-item rig the shared `rig` block describes: three layers,
/// each carrying the same cube, each moved to its authored position and given
/// its authored pivot, then selected in the authored order.
///
/// Selection ORDER is load-bearing and comes from the fixture
/// (`rig.selection_order`, entries of the form "set 0" / "add 2"), so the
/// driver cannot drift from the order the fixture narrates.
void buildThreeItemRig(JSONValue rig) {
    rigPostOk("/api/command", commandBody("scene.reset"));
    rigCmd(`{"id":"history.clear"}`);

    JSONValue mesh = JSONValue(["vertices": rig["vertices"], "faces": rig["faces"]]);

    // /api/load-mesh targets the primary, and a fresh layer becomes primary,
    // so add-then-load gives each of the three its own copy of the geometry.
    rigPostOk("/api/command", commandBody("scene.loadMesh", mesh.toString));
    foreach (_; 0 .. rig["items"].array.length - 1) {
        rigCmd(`{"id":"layer.add"}`);
        rigPostOk("/api/command", commandBody("scene.loadMesh", mesh.toString));
    }

    foreach (i, it; rig["items"].array) {
        auto p = rigVec3(it["pos"]);
        auto v = rigVec3(it["pivot"]);
        rigCmd(format("layer.attr %d pos.x %.17g",   i, p[0]));
        rigCmd(format("layer.attr %d pos.y %.17g",   i, p[1]));
        rigCmd(format("layer.attr %d pos.z %.17g",   i, p[2]));
        rigCmd(format("layer.attr %d pivot.x %.17g", i, v[0]));
        rigCmd(format("layer.attr %d pivot.y %.17g", i, v[1]));
        rigCmd(format("layer.attr %d pivot.z %.17g", i, v[2]));
    }

    foreach (stepIdx, s; rig["selection_order"].array) {
        auto parts = s.str.split(" ");
        assert(parts.length == 2,
               "rig.selection_order entries are '<mode> <index>', got '" ~ s.str ~ "'");
        immutable string mode = parts[0];
        assert(mode == "set" || mode == "add",
               "rig.selection_order mode must be set|add, got '" ~ mode ~ "'");
        assert((stepIdx == 0) == (mode == "set"),
               "rig.selection_order must open with `set` and continue with `add` — the "
               ~ "distinguished item is the LAST one added, and that is the whole point "
               ~ "of the order");
        rigCmd(format("layer.select index:%s mode:%s", parts[1], mode));
    }
}

/// The rig's own premises, asserted rather than assumed: the right number of
/// items, all of them selected, each carrying real geometry (so the rejected
/// geometry-derived candidates are genuinely computable), the distinguished
/// item is the index the fixture names, and the Item selection type is current.
///
/// Also asserts the SEPARATIONS the rig exists to provide: the distinguished
/// item is neither the first item in the layer list nor the last one, and
/// (task 0671) it is not the mesh edit target either. Without those, a reading of `layers[0]` or `layers[$-1]` would agree
/// with the correct law by construction and the rejected numbers below would
/// never be reached.
void assertItemRigPremises(JSONValue rig) {
    auto layers = rigGet("/api/layers")["layers"].array;
    immutable size_t n = rig["items"].array.length;
    assert(layers.length == n,
           format("rig has %d items, got %d", n, layers.length));

    size_t nSelected = 0;
    long   focused   = -1;
    long   editTarget = -1;
    foreach (l; layers) {
        if (l["selected"].type == JSONType.true_) ++nSelected;
        if ("focused" in l && l["focused"].type == JSONType.true_)
            focused = l["index"].integer;
        if (l["primary"].type  == JSONType.true_) editTarget = l["index"].integer;
        assert(l["vertexCount"].integer == 8,
               "each item carries real geometry, so the rejected geometry-derived "
               ~ "candidates are genuinely computable: " ~ l.toString);
    }
    assert(nSelected == n, format("all %d items selected, got %d", n, nSelected));

    // TASK 0671 — THE DISTINGUISHED ITEM IS THE FOCUS, NOT THE EDIT TARGET,
    // and separating them is what this task made possible.
    //
    // The captured law is "the LAST one added is distinguished" (the fixture's
    // own provenance says so, and its `selection_order` is built around it).
    // That is the item-selection FOCUS. It used to be readable off `primary`
    // only because an `add` promoted the newest item to the edit target as a
    // side effect — the two pointers moved in lockstep and either could stand
    // in for the other.
    //
    // 0671 read the reference's own model: the edit target is the HEAD of the
    // selection queue, so with `set 0; add 2; add 1` it is item 0 while the
    // focus is item 1. The premise therefore reads the column it always meant,
    // and asserts the separation rather than losing it.
    immutable long want = rig["primary_is"].integer;
    assert(focused == want,
           format("the distinguished item must be index %d, got %d", want, focused));
    assert(editTarget != want,
           format("rig premise (task 0671): the distinguished item (%d) must NOT "
                  ~ "also be the mesh EDIT TARGET (%d) — they are two different "
                  ~ "questions now, and a rig where they coincide cannot tell a "
                  ~ "consumer bound to the wrong one apart", want, editTarget));

    assert(want != 0 && want != cast(long)(n - 1),
           format("rig premise: the distinguished item is index %d of %d — it must be "
                  ~ "NEITHER the first NOR the last layer, or 'the distinguished item' "
                  ~ "is indistinguishable from 'layers[0]' / 'the last layer in scene "
                  ~ "order' and an implementation reading either passes by construction",
                  want, n));

    assert(rigGet("/api/selection")["selType"].str == "item",
           "the rig must leave the Item selection type current");
}

/// Every item's authored position, in layer-index order.
double[3][] itemPositions() {
    double[3][] out_;
    foreach (l; rigGet("/api/layers")["layers"].array)
        out_ ~= rigVec3(l["xform"]["pos"]);
    return out_;
}
