module test_command_registry_roster;

import http_client : getJson;
import std.json : parseJSON;
import std.stdio : writeln;

void main() {}

unittest {
    const expected = parseJSON(import("fixtures/command_registry_roster.json"));
    const actual = getJson("/api/registry?params=1");
    assert(expected["commands"].array.length == 277
        && actual["commands"].array.length == 277,
        "1C production command roster must contain exactly 277 ids");
    assert(expected["tools"].array.length == 71
        && actual["tools"].array.length == 71,
        "1C production tool roster must contain exactly 71 ids");
    assert(actual == expected,
        "1C production registry ids and metadata must preserve the full pre-slice JSON");
    writeln("REGISTRY-ROSTER commands=277 tools=71 metadata=identical");
}
