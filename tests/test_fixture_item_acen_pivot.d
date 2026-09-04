// Frozen reference behaviour — the item-mode action centre is the item's
// world PIVOT (pos + pivot), not anything derived from its geometry.
// Fixture: tests/fixtures/item_acen_pivot.json.
//
// WHAT WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST
// ----------------------------------------------------
// An action centre that ignores the item subject and falls through to the
// geometry branch — i.e. one that answers with the mesh's own centroid /
// bounding-box centre instead of the item's world pivot. On this rig the
// mesh is deliberately displaced to local (3,0,0), so that implementation
// reads (3,0,0) where the correct one reads (0,2,3). The rig also separates
// "position alone" (0,2,0) and "world origin" (0,0,0), and the fixture
// carries all three rejected numbers so a future reader cannot re-derive a
// coincidence from the single correct value.
//
// The last block is a VACUITY GUARD, not decoration: it shows that the
// rejected geometry candidate is genuinely reachable on this same rig
// through this same endpoint (switch the subject to mesh components and it
// appears), so the item answer is a real election rather than the only
// value this read can produce.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : fabs;
import std.format : format;

import fixture_helpers : requireProvenance, asDouble;

void main() {}

alias baseUrl = testBaseUrl;


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
    assert("actionCenter" in ev, "/api/toolpipe/eval carries an actionCenter: " ~ ev.toString);
    return vec3(ev["actionCenter"]["center"]);
}

bool near(double[3] a, double[3] b, double tol) {
    foreach (i; 0 .. 3) if (fabs(a[i] - b[i]) > tol) return false;
    return true;
}

string s3(double[3] v) { return format("(%.9g, %.9g, %.9g)", v[0], v[1], v[2]); }

unittest {
    enum string fixtureJson = import("fixtures/item_acen_pivot.json");
    auto fx = parseJSON(fixtureJson);
    requireProvenance(fx, "item_acen_pivot");

    immutable double tol = asDouble(fx["tolerance"]);
    auto rig = fx["rig"];

    // ---- build the rig exactly as the fixture describes it ------------------
    postOk("/api/command", commandBody("scene.reset"));
    cmd(`{"id":"history.clear"}`);

    {
        JSONValue mesh = JSONValue([
            "vertices": rig["vertices"],
            "faces":    rig["faces"],
        ]);
        postOk("/api/command", commandBody("scene.loadMesh", mesh.toString));
    }

    auto item = rig["item"];
    auto pos  = vec3(item["pos"]);
    auto piv  = vec3(item["pivot"]);
    cmd(format("layer.attr 0 pos.x %.17g",   pos[0]));
    cmd(format("layer.attr 0 pos.y %.17g",   pos[1]));
    cmd(format("layer.attr 0 pos.z %.17g",   pos[2]));
    cmd(format("layer.attr 0 pivot.x %.17g", piv[0]));
    cmd(format("layer.attr 0 pivot.y %.17g", piv[1]));
    cmd(format("layer.attr 0 pivot.z %.17g", piv[2]));

    // Selecting the item promotes the Item selection type to current — that
    // is what puts the action centre on the item branch at all.
    cmd("layer.select index:0 mode:set");
    assert(getJson("/api/selection")["selType"].str == "item",
           "the rig must leave the Item selection type current");

    // ---- the rig must actually discriminate ---------------------------------
    // Without this the whole fixture could be asserting a value that two or
    // three candidate laws happen to share.
    auto expected = vec3(fx["expected"]["action_center"]);
    foreach (r; fx["rejected"].array) {
        auto bad = vec3(r["value"]);
        assert(!near(expected, bad, tol),
               format("rig does not discriminate: rejected candidate '%s' predicts %s, "
                      ~ "which equals the expected centre %s",
                      r["candidate"].str, s3(bad), s3(expected)));
    }

    // ---- the measurement ----------------------------------------------------
    {
        auto got = actionCenter();
        assert(near(got, expected, tol),
               format("item action centre: got %s, want %s (= item pos + pivot). "
                      ~ "Reading %s would mean the item subject was ignored and the "
                      ~ "geometry branch answered instead.",
                      s3(got), s3(expected),
                      s3(vec3(fx["vibe3d_sensitivity"]["component_mode_action_center"]))));
    }

    // ---- the reference's own sensitivity control ----------------------------
    // Forcing an explicit world-origin action centre MOVES the read; without
    // this, "seven identical frames" would not separate "the law is pos+pivot"
    // from "this channel never changes".
    {
        auto ctl = fx["control"];
        cmd("tool.pipe.attr actionCenter mode " ~ ctl["action_center_mode"].str);
        auto got = actionCenter();
        auto want = vec3(ctl["expected_action_center"]);
        assert(near(got, want, tol),
               format("control: with an explicit %s action centre the read must move to %s, got %s",
                      ctl["action_center_mode"].str, s3(want), s3(got)));

        cmd("tool.pipe.attr actionCenter mode auto");
        auto back = actionCenter();
        assert(near(back, expected, tol),
               format("control: releasing the override must restore %s, got %s",
                      s3(expected), s3(back)));
    }

    // ---- vacuity guard: the rejected geometry branch IS reachable ------------
    // Same rig, same endpoint, subject switched to mesh components. If this
    // did not move, the item answer above would be untrustworthy — it could
    // be the only value this read ever produces.
    {
        postOk("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[]}`));
        assert(getJson("/api/selection")["selType"].str == "vertex",
               "the subject switch must actually take");
        auto got  = actionCenter();
        auto want = vec3(fx["vibe3d_sensitivity"]["component_mode_action_center"]);
        assert(near(got, want, tol),
               format("vacuity guard: with mesh components as the subject the geometry "
                      ~ "branch must answer %s, got %s — if this equals the item centre "
                      ~ "%s the endpoint is not subject-sensitive and the assertion above "
                      ~ "proves nothing", s3(want), s3(got), s3(expected)));
        assert(!near(got, expected, tol),
               format("vacuity guard: the component-subject centre %s must DIFFER from "
                      ~ "the item-subject centre %s", s3(got), s3(expected)));
    }
}
