module test_command_registry_roster;

import http_client : getJson;
import std.json : parseJSON;
import std.stdio : writeln;

void main() {}

unittest {
    auto expected = parseJSON(import("fixtures/command_registry_roster.json"))["expected"];
    // The required drop type has no implicit value. Keep the complete frozen
    // roster and schema comparison, changing only this former default.
    assert(expected["commandParams"]["select.drop"][0]["value"].str == "vertex",
        "registry baseline must retain its original drop default");
    expected["commandParams"]["select.drop"][0]["value"] = "";
    const actual = getJson("/api/registry?params=1");
    assert(expected["commands"].array.length == 277
        && actual["commands"].array.length == 277,
        "1C production command roster must contain exactly 277 ids");
    assert(expected["tools"].array.length == 71
        && actual["tools"].array.length == 71,
        "1C production tool roster must contain exactly 71 ids");
    assert(actual == expected,
        "production registry ids and metadata must match the frozen roster plus required drop default");
    writeln("REGISTRY-ROSTER commands=277 tools=71 metadata=required-drop-default");
}
