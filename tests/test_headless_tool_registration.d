// Task 6353: live registry and refusal witness for the paired Generator and
// Primitive tool/headless-command registrations.

import http_client : getJson, testBaseUrl;
import http_command_helpers : commandBody;

import std.algorithm : canFind;
import std.format : format;
import std.json;
import std.net.curl : get, post;

alias BASE = testBaseUrl;

void main() {}

private enum string[] kPaired = [
    "prim.cube", "prim.sphere", "prim.ellipsoid", "prim.cylinder",
    "prim.tube", "prim.cone", "prim.capsule", "prim.torus", "prim.arc",
    "mesh.mirrorTool", "mesh.radialSweepTool", "mesh.tack", "mesh.bridgeTool",
];

private enum string[] kToolOnly = ["pen", "prim.vertex", "mesh.topoPen"];
private enum string kNoTarget =
    "no mesh item is selected: there is no mesh edit target";

private JSONValue registry() {
    return parseJSON(cast(string) get(BASE ~ "/api/registry?params=1"));
}

private bool[string] idSet(JSONValue values) {
    bool[string] result;
    foreach (value; values.array)
        result[value.str] = true;
    return result;
}

private JSONValue command(string id) {
    return parseJSON(cast(string) post(BASE ~ "/api/command", commandBody(id)));
}

private JSONValue commandRaw(string body) {
    return parseJSON(cast(string) post(BASE ~ "/api/command", body));
}

private void commandOk(string id) {
    auto result = command(id);
    assert(result["status"].str == "ok",
        "6353 live rig: command " ~ id ~ " failed: " ~ result.toString);
}

unittest { // L1-L5: actual registry matches the paired local metadata.
    auto reg = registry();
    auto commands = idSet(reg["commands"]);
    auto tools = idSet(reg["tools"]);
    assert(kPaired.length == 13,
        "6353 live population floor: expected 13 paired ids");

    size_t foundPairs;
    bool[string] distinctSchemas;
    foreach (id; kPaired) {
        assert(id in commands,
            "6353 live population: command registry lacks " ~ id);
        assert(id in tools,
            "6353 live population: tool registry lacks " ~ id);
        ++foundPairs;
        assert(reg["commandNames"][id].str == id,
            format("6353 live name: %s reports '%s'", id,
                   reg["commandNames"][id].str));

        auto modes = reg["commandSupportedModes"][id].array;
        assert(modes.length == 3
            && modes[0].str == "Vertices"
            && modes[1].str == "Edges"
            && modes[2].str == "Polygons",
            "6353 live modes: " ~ id ~ " does not publish all three defaults");

        assert(reg["commandParams"][id] == reg["toolParams"][id],
            "6353 live schema: command/tool params diverged for " ~ id);
        distinctSchemas[reg["toolParams"][id].toString] = true;
    }
    assert(foundPairs == 13,
        "6353 live population: did not inspect all paired ids");

    // The schema comparison is not a constant-table check: at least ten
    // distinct schemas are present. Its measured blind spot is the
    // ellipsoid/cylinder/cone trio; the unit product table and constructor
    // flag separate that family.
    assert(distinctSchemas.length >= 10,
        format("6353 live schema discriminator collapsed to %d distinct values",
               distinctSchemas.length));

    size_t otherRestricted;
    foreach (id, modes; reg["commandSupportedModes"].object)
        if (id !in commands || !kPaired.canFind(id))
            if (modes.array.length < 3) ++otherRestricted;
    assert(otherRestricted > 0,
        "6353 live modes discriminator: no other command has a restricted mode set");

    foreach (id; kToolOnly) {
        assert(id in tools,
            "6353 live command-negative floor: tool registry lacks " ~ id);
        assert(id !in commands,
            "6353 live command-negative: command registry contains " ~ id);
    }
}

unittest { // L6: script-origin refusal with no edit target records no history.
    commandOk("scene.reset");
    commandOk("layer.duplicate");
    auto deleted = commandRaw(`{"id":"layer.delete","index":1}`);
    assert(deleted["status"].str == "ok",
        "6353 refusal rig: deleting the duplicate failed: " ~ deleted.toString);
    auto layers = getJson("/api/layers");
    assert(layers["layers"].array.length == 1,
        "6353 refusal rig: duplicate/delete did not leave one layer");
    assert(layers["active"].integer == -1,
        format("6353 refusal rig: expected no edit target, active=%d",
               layers["active"].integer));

    // Clear strictly after constructing the targetless state so undo length is
    // an observation of this command alone, not of setup history.
    commandOk("history.clear");
    auto refused = command("prim.cube");
    assert(refused["status"].str == "error",
        "6353 refusal: prim.cube reported ok without an edit target");
    assert(refused["message"].str.canFind(kNoTarget),
        "6353 refusal: message did not name the absent edit target: "
      ~ refused["message"].str);
    assert(getJson("/api/history")["undo"].array.length == 0,
        "6353 refusal: prim.cube recorded history despite refusing");
}
