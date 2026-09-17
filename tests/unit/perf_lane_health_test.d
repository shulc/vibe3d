// The nightly perf lane keeps day-over-day timing diagnostic, but host
// contamination is a separate machine-stable gate (task 4870). This witness
// drives the real `run.d --lane-health` entry point over an isolated artifact:
// the two fixtures differ in exactly one boolean, so another missing-row or
// coverage guard cannot accidentally provide the expected non-zero exit.
module tests.unit.perf_lane_health_test;

import std.algorithm : canFind;
import std.conv      : to;
import std.file      : exists, readText, remove, tempDir, write;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.process   : environment, execute, thisProcessID;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runPath = buildPath(repoRoot, "tools", "perf", "run.d");

private string artifact(bool contaminated)
{
    return format(q"JSON
{
  "contaminated": %s,
  "contaminatedBy": "focused mutation fixture",
  "filter": ["focused"],
  "meshType": "grid",
  "cases": [],
  "coverageGap": []
}
JSON", contaminated ? "true" : "false");
}

unittest
{
    const path = buildPath(tempDir(), "vibe3d-perf-lane-health-"
        ~ thisProcessID.to!string ~ ".json");
    scope(exit) if (exists(path)) remove(path);

    auto env = environment.toAA;
    env["VIBE3D_PERF_RESULTS_PATH"] = path;

    write(path, artifact(true));
    auto contaminated = execute([runPath, "--lane-health"], env);
    assert(contaminated.status != 0,
        "lane health returned success for contaminated:true:\n"
        ~ contaminated.output);
    assert(contaminated.output.canFind(
            "[FAIL] CONTAMINATED: ops measured while a foreign vibe3d was alive"),
        "lane health failed without naming contamination; another guard may "
        ~ "be confounding the witness:\n" ~ contaminated.output);

    write(path, artifact(false));
    auto clean = execute([runPath, "--lane-health"], env);
    assert(clean.status == 0,
        "the otherwise-identical clean fixture must pass lane health:\n"
        ~ clean.output);
}

unittest
{
    const drag = readText(buildPath(
        repoRoot, "tools", "perf", "lib", "drag.d"));
    assert(drag.canFind("auto model = meshProbe();"),
        "6310 perf defence: vertexPos no longer uses the patient /api/model "
        ~ "reader and can abort a whole large-mesh lane on one transport error");
    assert(drag.canFind("immutable base = 3 * idx;")
        && drag.canFind("return Vec3(model.pos[base], model.pos[base + 1], "
            ~ "model.pos[base + 2]);"),
        "6310 perf defence: vertexPos no longer maps the flat meshProbe "
        ~ "coordinates back to the requested vertex");

    const workflow = readText(buildPath(
        repoRoot, ".github", "workflows", "perf.yaml"));
    assert(workflow.canFind("/tmp/vibe3d_perf*.log"),
        "6310 perf evidence: workflow no longer uploads the app logs that "
        ~ "carry partial-response diagnostics");
}
