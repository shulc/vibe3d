// Frozen reference behaviour — with several items selected, the shared
// action centre follows the DISTINGUISHED (primary) item.
// Fixture: tests/fixtures/item_acen_primary_of_three.json.
//
// WHAT WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST
// ----------------------------------------------------
// Five of them, and the rig is built so none reads the correct number:
//   * "the first item selected"        reads (0, 0, 0)
//   * "the last item in scene order"   reads (6, 0, 0)
//   * "the mean of the selected set"   reads (2.667, 0, 0)
//   * "the bounding box of the set"    reads (3, 0, 0)
//   * "the extreme item along X"       reads (6, 0, 0)
// The correct answer is (2, 0, 0). Two things make that so, and BOTH are
// asserted as rig premises before the measurement:
//   * the distinguished item sits BETWEEN the other two on X, so "a centre
//     that lands between the extremes" is not evidence for "midpoint" — the
//     midpoint is 3;
//   * the distinguished item sits in the MIDDLE of the layer list, so it is
//     not `layers[0]` and not `layers[$-1]`. The earlier rig created it LAST,
//     which made "read the last layer" agree with the correct law by
//     construction — that implementation passed the old rig unchanged.
// That is exactly why the rejected numbers are frozen alongside the one
// correct number, and why the rig's separations are asserted rather than
// described.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : fabs;
import std.format : format;

import fixture_helpers  : requireProvenance, asDouble;
import item_rig_helpers : buildThreeItemRig, assertItemRigPremises, assertRigsIdentical;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string) get(baseUrl ~ path)); }

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

unittest {
    enum string fixtureJson = import("fixtures/item_acen_primary_of_three.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "item_acen_primary_of_three");

    immutable double tol = asDouble(fx["tolerance"]);
    auto rig = fx["rig"];

    // The companion fixture pins the moving SET on this same state. Shared for
    // real: one builder (item_rig_helpers.buildThreeItemRig) and identical rig
    // DATA, checked here rather than asserted in prose.
    {
        enum string companionJson = import("fixtures/item_move_whole_set.json");
        assertRigsIdentical(rig, "item_acen_primary_of_three",
                            parseJSON(companionJson)["rig"], "item_move_whole_set");
    }

    buildThreeItemRig(rig);
    assertItemRigPremises(rig);

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

    // ---- and it is none of the rejected laws --------------------------------
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
