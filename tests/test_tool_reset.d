// tool.reset (Ctrl+D) — Stage B end-to-end.
//
// `tool.reset` rebuilds the active (or named) tool from its DECLARED
// defaults — constructor field initialisers PLUS any preset-YAML `attrs:`
// override (config/tool_presets.yaml) — and clears its sticky-tool-defaults
// entry. Runs under plain `--test` (no VIBE3D_CONFIG_DIR): `prefsActive` is
// false there, so sticky capture/restore never fires and this tier exercises
// only the rebuild-to-declared-defaults mechanism, independent of
// persistence (see tests/test_tool_sticky.d for the persistence-live tier).
//
// Two cases:
//   1. A base/direct tool (mesh.sliceTool) — write a non-default attr, reset,
//      assert it's back to the schema default.
//   2. A preset-YAML-override discriminator (TransformMove) — the preset
//      declares R:"false" in config/tool_presets.yaml while the base
//      xfrm.transform's constructor default for `flagR` is `true`. A bare
//      `Param.default_` write would wrongly land on `true`; only a rebuild
//      (constructor + YAML) reproduces the true declared default `false`.

import std.net.curl;
import std.json;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}

JSONValue query(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "query '" ~ line ~ "' failed: " ~ r.toString);
    assert("value" in r,
        "query '" ~ line ~ "' returned no value field: " ~ r.toString);
    return r["value"];
}

void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// 1. Base/direct tool — tool.reset returns a changed attr to its schema
//    default.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set mesh.sliceTool");

    // Declared default: Angle (snapAngle) = 45 (slice_tool.d params()).
    auto d0 = query("tool.attr mesh.sliceTool snapAngle ?");
    assert(approxEqual(d0.floating, 45.0),
        "fresh slice tool snapAngle default should be 45, got " ~ d0.toString);

    cmd("tool.attr mesh.sliceTool snapAngle 30");
    auto changed = query("tool.attr mesh.sliceTool snapAngle ?");
    assert(approxEqual(changed.floating, 30.0),
        "snapAngle write-then-query should be 30, got " ~ changed.toString);

    cmd("tool.reset");

    // Same tool id must still be active after the rebuild (reset targets the
    // active tool and re-activates the SAME id).
    auto after = query("tool.attr mesh.sliceTool snapAngle ?");
    assert(approxEqual(after.floating, 45.0),
        "tool.reset should return snapAngle to its declared default 45, got "
        ~ after.toString);

    cmd("tool.set mesh.sliceTool off");
}

// ---------------------------------------------------------------------------
// 2. Preset-YAML-override discriminator (TransformMove.R).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("tool.set TransformMove");

    // Sanity: the preset YAML override (R:"false") is live on a fresh
    // activation, NOT the base xfrm.transform constructor default (flagR =
    // true).
    auto d0 = query("tool.attr TransformMove R ?");
    assert(d0.type == JSONType.false_,
        "fresh TransformMove R should be the YAML-declared false, got "
        ~ d0.toString);

    cmd("tool.attr TransformMove R true");
    auto changed = query("tool.attr TransformMove R ?");
    assert(changed.type == JSONType.true_,
        "R write-then-query should be true, got " ~ changed.toString);

    cmd("tool.reset");

    // A rebuild (constructor + YAML) must land back on the YAML-declared
    // `false` — a bare `Param.default_` write would incorrectly give `true`
    // (the base constructor default), missing the YAML override.
    auto after = query("tool.attr TransformMove R ?");
    assert(after.type == JSONType.false_,
        "tool.reset on a preset tool should restore the YAML-declared "
        ~ "default (false), got " ~ after.toString);

    cmd("tool.set TransformMove off");
}
