// Transform handles expose the translated run centre after an idle apply,
// including presets whose linear banks are enabled.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import math : Vec3;
import std.file : readText;
import std.json : JSONValue, parseJSON;
import std.math : fabs;
import std.path : buildPath, dirName;

void main() {}

private enum repoRoot = dirName(dirName(__FILE_FULL_PATH__));

private void command(string text)
{
    auto result = postJson("/api/command", text);
    assert(result["status"].str == "ok",
        "command `" ~ text ~ "` failed: " ~ result.toString);
}

private Vec3 vectorAt(JSONValue value)
{
    auto a = value.array;
    return Vec3(cast(float)a[0].floating, cast(float)a[1].floating,
                cast(float)a[2].floating);
}

private Vec3 gizmoCentre()
{
    return vectorAt(getJson("/api/toolpipe/eval")["transform"]["gizmoCenter"]);
}

private bool near(Vec3 a, Vec3 b, float tolerance)
{
    return fabs(a.x - b.x) <= tolerance
        && fabs(a.y - b.y) <= tolerance
        && fabs(a.z - b.z) <= tolerance;
}

private JSONValue fixture()
{
    return parseJSON(readText(buildPath(repoRoot, "tests", "fixtures",
        "transform_handle_after_release.json")));
}

unittest // T-only item pose is c + T, with no subject gate.
{
    const data = fixture();
    const centre = vectorAt(data["law"]["centre"]);
    const delta = vectorAt(data["law"]["translate"]);
    const expected = centre + delta;
    const tolerance = cast(float)data["limits"]["position"].floating;
    const separation = cast(float)data["limits"]["separation"].floating;
    assert(delta.length > separation,
        "6207 item witness needs a visible translation");
    assert(near(expected, vectorAt(data["item_move_only"]["expected_handle"]), tolerance),
        "6207 item fixture must encode H=c+T");

    postJson("/api/command", commandBody("scene.reset"));
    command("actr.origin");
    command("layer.select index:0");
    command("tool.set TransformMove on");
    command("tool.attr TransformMove TX 0.5");
    command("tool.doApply");
    assert(near(gizmoCentre(), expected, tolerance),
        "6207 T-only item handle must be H=c+T after apply");
    command("tool.set TransformMove off");
}

unittest // Composite handles obey the same H=c+T pose law.
{
    const data = fixture();
    const centre = vectorAt(data["law"]["centre"]);
    const delta = vectorAt(data["law"]["translate"]);
    const expected = centre + delta;
    const tolerance = cast(float)data["limits"]["position"].floating;
    const separation = cast(float)data["limits"]["separation"].floating;
    assert((centre + delta - centre).length > separation,
        "6207 composite witness needs a visible pose change");
    assert(near(expected, vectorAt(data["composite_phase_1b"]["expected_handle"]), tolerance),
        "6207 composite fixture must encode H=c+T");

    postJson("/api/command", commandBody("scene.reset"));
    command("actr.origin");
    command("tool.set Transform on");
    command("tool.attr Transform TX 0.5");
    command("tool.doApply");
    assert(near(gizmoCentre(), expected, tolerance),
        "6207 composite handle must be H=c+T after apply");
    command("tool.set Transform off");
}
