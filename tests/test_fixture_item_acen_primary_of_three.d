// Frozen reference behaviour — with several items selected, the shared
// action centre follows the DISTINGUISHED (primary) item.
// Fixture: tests/fixtures/item_acen_primary_of_three.json.
//
// WHAT WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST
// ----------------------------------------------------
// Four of them, and the rig is built so each reads a different number:
//   * "the first item selected"        reads (0, 0, 0)
//   * "the mean of the selected set"   reads (2.667, 0, 0)
//   * "the bounding box of the set"    reads (3, 0, 0)
//   * "the extreme item along X"       reads (6, 0, 0)
// The correct answer is (2, 0, 0). Note that the primary sits BETWEEN the
// other two, so "a centre that lands between the extremes" is not evidence
// for "midpoint" — the midpoint is 3. That is exactly why the four rejected
// numbers are frozen alongside the one correct number.

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

double[3] actionCenter() {
    auto ev = getJson("/api/toolpipe/eval");
    assert("error" !in ev, "/api/toolpipe/eval: " ~ ev.toString);
    return vec3(ev["actionCenter"]["center"]);
}

bool near(double[3] a, double[3] b, double tol) {
    foreach (i; 0 .. 3) if (fabs(a[i] - b[i]) > tol) return false;
    return true;
}

string s3(double[3] v) { return format("(%.9g, %.9g, %.9g)", v[0], v[1], v[2]); }

// Build the three-item rig the fixture describes. Shared, verbatim, with
// tests/test_fixture_item_move_whole_set.d — the two fixtures pin the centre
// and the moving set on ONE state, so the rigs must not drift apart.
void buildThreeItemRig(JSONValue rig) {
    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);

    JSONValue mesh = JSONValue(["vertices": rig["vertices"], "faces": rig["faces"]]);

    // /api/load-mesh targets the primary, and a fresh layer becomes primary,
    // so add-then-load gives each of the three its own copy of the geometry.
    postOk("/api/load-mesh", mesh.toString);
    foreach (_; 0 .. 2) {
        cmd(`{"id":"layer.add"}`);
        postOk("/api/load-mesh", mesh.toString);
    }

    foreach (i, it; rig["items"].array) {
        auto p = vec3(it["pos"]);
        auto v = vec3(it["pivot"]);
        cmd(format("layer.attr %d pos.x %.17g",   i, p[0]));
        cmd(format("layer.attr %d pos.y %.17g",   i, p[1]));
        cmd(format("layer.attr %d pos.z %.17g",   i, p[2]));
        cmd(format("layer.attr %d pivot.x %.17g", i, v[0]));
        cmd(format("layer.attr %d pivot.y %.17g", i, v[1]));
        cmd(format("layer.attr %d pivot.z %.17g", i, v[2]));
    }

    // Selection ORDER is load-bearing: set, then add, then add, so the
    // distinguished item is the last one added while sitting in the middle.
    cmd("layer.select index:0 mode:set");
    cmd("layer.select index:1 mode:add");
    cmd("layer.select index:2 mode:add");
}

// The rig's own premises, asserted rather than assumed: all three selected,
// and the distinguished one is the index the fixture names.
void assertRigPremises(JSONValue rig) {
    auto layers = getJson("/api/layers")["layers"].array;
    assert(layers.length == 3, format("rig has three items, got %d", layers.length));

    size_t nSelected = 0;
    long   primary   = -1;
    foreach (l; layers) {
        if (l["selected"].type == JSONType.true_) ++nSelected;
        if (l["primary"].type  == JSONType.true_) primary = l["index"].integer;
        assert(l["vertexCount"].integer == 8,
               "each item carries real geometry, so the rejected geometry-derived "
               ~ "candidates are genuinely computable: " ~ l.toString);
    }
    assert(nSelected == 3, format("all three items selected, got %d", nSelected));
    assert(primary == rig["primary_is"].integer,
           format("the distinguished item must be index %d, got %d",
                  rig["primary_is"].integer, primary));
}

unittest {
    enum string fixtureJson = import("fixtures/item_acen_primary_of_three.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "item_acen_primary_of_three");

    immutable double tol = asDouble(fx["tolerance"]);
    auto rig = fx["rig"];

    buildThreeItemRig(rig);
    assertRigPremises(rig);
    assert(getJson("/api/selection")["selType"].str == "item",
           "the rig must leave the Item selection type current");

    auto expected = vec3(fx["expected"]["action_center"]);

    // ---- the rig must actually discriminate ---------------------------------
    foreach (r; fx["rejected"].array) {
        auto bad = vec3(r["value"]);
        assert(!near(expected, bad, tol),
               format("rig does not discriminate: rejected candidate '%s' predicts %s, "
                      ~ "which equals the expected centre %s",
                      r["candidate"].str, s3(bad), s3(expected)));
    }

    // ---- the measurement ----------------------------------------------------
    auto got = actionCenter();
    assert(near(got, expected, tol),
           format("multi-item action centre: got %s, want %s (the distinguished item's "
                  ~ "world pivot)", s3(got), s3(expected)));

    // ---- and it is none of the four rejected laws ---------------------------
    // Stated separately so a failure names WHICH wrong law the code fell into
    // instead of only reporting a number.
    foreach (r; fx["rejected"].array) {
        auto bad = vec3(r["value"]);
        assert(!near(got, bad, tol),
               format("action centre %s matches the rejected law '%s' — the centre is "
                      ~ "supposed to follow the distinguished item (%s), not that",
                      s3(got), r["candidate"].str, s3(expected)));
    }
}
