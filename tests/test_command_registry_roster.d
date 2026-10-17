module test_command_registry_roster;

import http_client : getJson;
import std.algorithm : sort;
import std.json : JSONValue, parseJSON;
import std.process : environment;
import std.stdio : writeln;

void main() {}

unittest {
    auto expected = parseJSON(import("fixtures/command_registry_roster.json"))["expected"];
    // The required drop type has no implicit value. Keep the complete frozen
    // roster and schema comparison, changing only this former default.
    assert(expected["commandParams"]["select.drop"][0]["value"].str == "vertex",
        "registry baseline must retain its original drop default");
    expected["commandParams"]["select.drop"][0]["value"] = "";
    const productionCommands = expected["commands"].array.length;
    // The workflow declares the staged app's build profile independently of
    // the observed registry; HTTP clients do not inherit the app's versions.
    const selfTestProfile = environment.get("VIBE3D_EXPECT_SANITIZER_SELFTEST", "0");
    const expectedCommands = 277 + (selfTestProfile == "1" ? 1 : 0);
    if (selfTestProfile == "1") {
        auto commands = expected["commands"].array;
        commands ~= JSONValue("selftest.fault");
        sort!((a, b) => a.str < b.str)(commands);
        expected["commands"] = JSONValue(commands);
        expected["commandNames"]["selftest.fault"] = "selftest.fault";
        expected["commandSupportedModes"]["selftest.fault"] =
            parseJSON(`["Vertices", "Edges", "Polygons"]`);
        expected["commandParams"]["selftest.fault"] = parseJSON(q"SCHEMA
[{"choices":["heapoverflow","gcoverflow","uaf","assertfail","hang","slow","invariant","race"],"enforceBounds":false,"kind":"Enum","name":"kind","value":"assertfail"}]
SCHEMA");
    }
    const actual = getJson("/api/registry?params=1");
    assert(productionCommands == 277
        && (selfTestProfile == "0" || selfTestProfile == "1")
        && expected["commands"].array.length == expectedCommands
        && actual["commands"].array.length == expectedCommands,
        "1C registry must contain exactly 277 production ids plus the declared self-test id");
    assert(expected["tools"].array.length == 71
        && actual["tools"].array.length == 71,
        "1C production tool roster must contain exactly 71 ids");
    assert(actual == expected,
        "production registry ids and metadata must match the frozen roster plus required drop default");
    writeln("REGISTRY-ROSTER commands=", expectedCommands,
        " tools=71 metadata=required-drop-default");
}
