// /api/frames + /api/frames/reset — endpoint smoke test (task 0195).
//
// `run_test.d` builds the DEFAULT `modeling` config, which defines no
// `PerfProbe` version — every FrameProbe method compiles to a no-op there
// (see source/perf_probe.d), so `/api/frames` ALWAYS returns `"{}"` in this
// binary and `frameCount` is never populated. This test therefore does NOT
// (and must NOT) assert `frameCount > 0` or any percentile/phase field — it
// only asserts the endpoint responds with a valid JSON body (empty `{}` is
// the expected, correct response here) and that the reset endpoint
// acknowledges. Functional coverage of `frameCount` / percentiles / the
// F-I1/F-I2/F-I4 counter invariants lives in `tools/perf/run.d frames`,
// which drives a real `--build=perf` binary end to end.
//
// Mirrors the shape of the existing `/api/perf` handler and its (absent)
// endpoint test — there is no `test_perf_endpoint.d` either, for the same
// reason: the default build carries no PerfProbe data to assert on.

import std.net.curl;
import std.json;

void main() {}

string baseUrl = "http://localhost:8080";

unittest { // GET /api/frames responds with a valid JSON object
    post(baseUrl ~ "/api/reset", "");

    auto response = cast(string)get(baseUrl ~ "/api/frames");
    auto json = parseJSON(response);

    // Default (non-PerfProbe) build ⇒ "{}". Accept any valid JSON object so
    // this test does not become a build-config tripwire — it only checks
    // the endpoint is wired and returns well-formed JSON.
    assert(json.type == JSONType.object,
           "/api/frames should return a JSON object, got: " ~ response);
}

unittest { // POST /api/frames/reset acknowledges
    auto response = cast(string)post(baseUrl ~ "/api/frames/reset", "");
    auto json = parseJSON(response);

    assert("status" in json, "Missing status field in /api/frames/reset response");
    assert(json["status"].str == "ok",
           "Expected {\"status\":\"ok\"}, got: " ~ response);

    // A read right after reset should still be a well-formed JSON object
    // (still "{}" in the default build).
    auto after = cast(string)get(baseUrl ~ "/api/frames");
    auto afterJson = parseJSON(after);
    assert(afterJson.type == JSONType.object,
           "/api/frames after reset should return a JSON object, got: " ~ after);
}
