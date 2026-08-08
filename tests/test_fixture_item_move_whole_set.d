// Frozen reference behaviour — an item-mode translate moves the WHOLE
// selected set, not just the distinguished item.
// Fixture: tests/fixtures/item_move_whole_set.json.
//
// WHAT WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST
// ----------------------------------------------------
// Two of them, and the fixture carries the after-positions each would read:
//   * "only the distinguished item moves" — the companion fixture proves the
//     shared CENTRE follows the primary alone, and binding the motion to the
//     same single item is the obvious way to get that wrong. That
//     implementation leaves items 0 and 1 at y = 0 and reads
//     [[0,0,0], [6,0,0], [2,-1.2,0]].
//   * "the set collapses onto the shared centre" — an implementation that
//     rebases each item onto the frozen centre instead of translating it
//     reads [[2,-1.2,0], [2,-1.2,0], [2,-1.2,0]], i.e. X is destroyed.
// The X column is therefore asserted UNCHANGED as hard as the Y column is
// asserted moved; only the pair separates the correct law from the second
// wrong one.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : fabs;
import std.format : format;

import fixture_helpers : requireProvenance, asDouble;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string) get(baseUrl ~ path)); }

JSONValue cmd(string argstring) {
    auto j = parseJSON(cast(string) post(baseUrl ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
    return j;
}

void postOk(string path, string body_) {
    auto j = parseJSON(cast(string) post(baseUrl ~ path, body_));
    assert(j["status"].str == "ok", path ~ " failed: " ~ j.toString);
}

double[3] vec3(JSONValue arr) {
    assert(arr.array.length == 3, "expected a 3-vector, got " ~ arr.toString);
    return [asDouble(arr[0]), asDouble(arr[1]), asDouble(arr[2])];
}

bool near(double[3] a, double[3] b, double tol) {
    foreach (i; 0 .. 3) if (fabs(a[i] - b[i]) > tol) return false;
    return true;
}

string s3(double[3] v) { return format("(%.9g, %.9g, %.9g)", v[0], v[1], v[2]); }

/// Every item's authored position, in layer-index order.
double[3][] itemPositions() {
    double[3][] out_;
    foreach (l; getJson("/api/layers")["layers"].array)
        out_ ~= vec3(l["xform"]["pos"]);
    return out_;
}

string sList(double[3][] vs) {
    string s = "[";
    foreach (i, v; vs) { if (i) s ~= ", "; s ~= s3(v); }
    return s ~ "]";
}

unittest {
    enum string fixtureJson = import("fixtures/item_move_whole_set.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "item_move_whole_set");

    immutable double tol = asDouble(fx["tolerance"]);
    auto rig = fx["rig"];
    auto exp = fx["expected"];

    // ---- rig: three items, geometry each, selection order set/add/add -------
    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);
    {
        JSONValue mesh = JSONValue(["vertices": rig["vertices"], "faces": rig["faces"]]);
        postOk("/api/load-mesh", mesh.toString);
        foreach (_; 0 .. 2) {
            cmd(`{"id":"layer.add"}`);
            postOk("/api/load-mesh", mesh.toString);
        }
    }

    double[3][] before;
    foreach (v; exp["before"].array) before ~= vec3(v);
    foreach (i, p; before) {
        cmd(format("layer.attr %d pos.x %.17g", i, p[0]));
        cmd(format("layer.attr %d pos.y %.17g", i, p[1]));
        cmd(format("layer.attr %d pos.z %.17g", i, p[2]));
    }
    cmd("layer.select index:0 mode:set");
    cmd("layer.select index:1 mode:add");
    cmd("layer.select index:2 mode:add");

    // ---- rig premises, asserted --------------------------------------------
    {
        auto layers = getJson("/api/layers")["layers"].array;
        assert(layers.length == 3, "rig has three items");
        size_t nSel = 0;
        long   prim = -1;
        foreach (l; layers) {
            if (l["selected"].type == JSONType.true_) ++nSel;
            if (l["primary"].type  == JSONType.true_) prim = l["index"].integer;
        }
        assert(nSel == 3, format("all three selected, got %d", nSel));
        assert(prim == rig["primary_is"].integer,
               "the distinguished item is the one the fixture names");
        assert(getJson("/api/selection")["selType"].str == "item",
               "the rig must leave the Item selection type current");

        auto got = itemPositions();
        assert(got.length == before.length, "position readback arity");
        foreach (i; 0 .. before.length)
            assert(near(got[i], before[i], tol),
                   format("rig start state at item %d: got %s want %s",
                          i, s3(got[i]), s3(before[i])));
    }

    // ---- the gesture: one numeric translate, then apply ---------------------
    {
        auto g = fx["gesture"];
        immutable string axis = g["axis"].str;
        assert(axis == "y", "this fixture's frozen gesture is on Y");
        cmd("tool.set move on");
        cmd(format("tool.attr move TY %.17g", asDouble(g["amount"])));
        cmd("tool.doApply");
        cmd("tool.set move off");
    }

    // ---- the measurement ----------------------------------------------------
    double[3][] want;
    foreach (v; exp["after"].array) want ~= vec3(v);

    auto got = itemPositions();
    assert(got.length == want.length, "position readback arity after the gesture");

    foreach (i; 0 .. want.length)
        assert(near(got[i], want[i], tol),
               format("item %d after the gesture: got %s want %s (whole set: %s want %s)",
                      i, s3(got[i]), s3(want[i]), sList(got), sList(want)));

    // ---- and it is neither wrong law ----------------------------------------
    // Named separately so a failure says WHICH one the code fell into.
    foreach (r; fx["rejected"].array) {
        double[3][] bad;
        foreach (v; r["after"].array) bad ~= vec3(v);
        bool allMatch = bad.length == got.length;
        if (allMatch)
            foreach (i; 0 .. bad.length) if (!near(got[i], bad[i], tol)) { allMatch = false; break; }
        assert(!allMatch,
               format("the result %s matches the rejected law '%s' — every selected item "
                      ~ "is supposed to translate by %s",
                      sList(got), r["candidate"].str, s3(vec3(exp["per_item_delta"]))));
    }

    // ---- the delta is uniform, and X really is untouched ---------------------
    {
        auto delta = vec3(exp["per_item_delta"]);
        foreach (i; 0 .. want.length) {
            double[3] d = [got[i][0] - before[i][0],
                           got[i][1] - before[i][1],
                           got[i][2] - before[i][2]];
            assert(near(d, delta, tol),
                   format("item %d moved by %s, want a uniform %s", i, s3(d), s3(delta)));
            assert(fabs(got[i][0] - before[i][0]) <= tol,
                   format("item %d moved on X (%.9g -> %.9g); the gesture was Y-only, so a "
                          ~ "changed X means the set was rebased onto the shared centre "
                          ~ "rather than translated", i, before[i][0], got[i][0]));
        }
    }
}
