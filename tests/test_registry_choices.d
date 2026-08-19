// test_registry_choices.d — task 1412.
//
// THE REGISTRY MUST PUBLISH WHAT AN ENUM ACCEPTS, AND WHAT MODES AN ACTION
// DECLARES.
//
// Two additive fields, one test each, both swept over the WHOLE registry read
// at run time (the idiom tests/test_param_cast_overflow.d already uses) so an
// action added tomorrow is covered tomorrow with no edit here.
//
// WHY `choices` IS NOT REDUNDANT WITH `value`
// -------------------------------------------
// It would be easy to think the registry already names a valid tag, and it
// does: `paramSchemaJson` writes `"value": paramToJson(p)`, and `paramToJson`
// returns the live wire tag for an Enum and the matching `e.wireTag` for an
// IntEnum. So ONE accepted tag was always reachable, and a caller could always
// replay it.
//
// What was unreachable is every OTHER tag. `injectParamsInto` THROWS on a tag
// it does not recognise, so guessing is not a strategy — an outside driver
// without this list can never move `layer.select mode` off `set`, or
// `mesh.mirror axis` off `X`, no matter how long it runs. That is the gap this
// field closes, and it is why the payoff metric for it is "DISTINCT enum tags
// actually sent", which is 0 before the field exists (an option-less enum is
// classified unfuzzable by the caller and simply never sent) and non-zero
// after — not "share of enum subjects that accept", which was already ~100%
// because the command just ran on its defaults.
//
// WHY `supportedModes` IS NOT `/api/buttons/availability`
// -------------------------------------------------------
// That answer is frame-dependent: it folds in the CURRENT edit mode and the
// current selection. This one is the static declaration the action itself
// makes, cached once at startup in `Registry.commandModes` / `toolModes` —
// which existed for the button-greying path but was published nowhere, so an
// outside driver had to guess a mode and read the refusal.
//
// MUST be `unittest{}` blocks: a plain function body in these HTTP test files
// is never executed by the runner, and the test passes by not running.
import std.stdio;
import std.json;
import std.net.curl : get;
import std.format   : format;
import std.array    : join;
import std.algorithm: canFind, sort;

private enum string BASE = "http://localhost:8080";

void main() {}

private JSONValue registry() {
    return parseJSON(cast(string) get(BASE ~ "/api/registry?params=1"));
}

unittest { // EveryEnumParamPublishesItsChoices
    auto reg = registry();
    assert("commandParams" in reg.object && "toolParams" in reg.object,
        "registry has no commandParams/toolParams — is ?params=1 wired?");

    string[] missing;
    string[] emptyList;
    int enumParams = 0;
    int withChoices = 0;

    foreach (mapName; ["commandParams", "toolParams"]) {
        foreach (id, ps; reg[mapName].object) {
            foreach (p; ps.array) {
                const kind = p["kind"].str;
                if (kind != "Enum" && kind != "IntEnum") continue;
                enumParams++;
                if ("choices" !in p.object) {
                    missing ~= format("%s %s.%s (%s)", mapName, id,
                                      p["name"].str, kind);
                    continue;
                }
                if (p["choices"].array.length == 0) {
                    emptyList ~= format("%s %s.%s", mapName, id, p["name"].str);
                    continue;
                }
                withChoices++;
                // The live `value` must be ONE OF the published choices, or the
                // list is describing a different parameter than the one the
                // command will read.
                if (kind == "Enum") {
                    bool found = false;
                    foreach (c; p["choices"].array)
                        if (c.str == p["value"].str) { found = true; break; }
                    assert(found, format(
                        "%s %s.%s: live value '%s' is not among its own "
                        ~ "choices %s", mapName, id, p["name"].str,
                        p["value"].str, p["choices"].toString()));
                }
            }
        }
    }

    // A sweep that swept nothing passes silently — the inert-measurement class
    // this campaign keeps finding. 126 enum params (91 Enum + 35 IntEnum) were
    // live when this was written; the floor is well under that so ordinary
    // additions and removals do not trip it, and deliberately above zero.
    assert(enumParams >= 60, format(
        "expected >=60 Enum/IntEnum params in the registry, found %d — the "
        ~ "sweep found nothing to sweep", enumParams));

    assert(missing.length == 0, format(
        "%d enum param(s) publish no `choices`, so every tag but the live one "
        ~ "is unreachable from outside the UI (injectParamsInto throws on an "
        ~ "unknown tag):\n  %s", missing.length, missing.join("\n  ")));
    assert(emptyList.length == 0, format(
        "%d enum param(s) publish an EMPTY `choices` list:\n  %s",
        emptyList.length, emptyList.join("\n  ")));

    writefln("[registry_choices] %d enum params, %d publish choices",
             enumParams, withChoices);
}

unittest { // EveryRegisteredIdPublishesItsSupportedModes
    auto reg = registry();
    assert("commandSupportedModes" in reg.object,
        "registry has no commandSupportedModes");
    assert("toolSupportedModes" in reg.object,
        "registry has no toolSupportedModes");

    static immutable string[] LEGAL = ["Vertices", "Edges", "Polygons"];

    void check(string idsKey, string modesKey) {
        auto ids = reg[idsKey].array;
        auto modes = reg[modesKey].object;
        assert(ids.length >= 50, format(
            "%s has only %d entries — the registry read collapsed",
            idsKey, ids.length));
        string[] absent;
        foreach (idv; ids) {
            const id = idv.str;
            if (id !in modes) { absent ~= id; continue; }
            auto ms = modes[id].array;
            assert(ms.length >= 1, format(
                "%s declares an EMPTY mode list — it can never be run", id));
            foreach (m; ms)
                assert(LEGAL.canFind(m.str), format(
                    "%s declares unknown edit mode '%s'", id, m.str));
        }
        assert(absent.length == 0, format(
            "%d id(s) in %s have no entry in %s:\n  %s",
            absent.length, idsKey, modesKey, absent.join("\n  ")));
    }

    check("commands", "commandSupportedModes");
    check("tools", "toolSupportedModes");

    // The field only earns its place if it DISCRIMINATES. A map where every id
    // answers "all three" carries no information the caller did not already
    // have, so assert that at least one id declares a restriction.
    int restricted = 0;
    foreach (modesKey; ["commandSupportedModes", "toolSupportedModes"])
        foreach (id, ms; reg[modesKey].object)
            if (ms.array.length < 3) restricted++;
    assert(restricted > 0,
        "no registered id declares a restricted mode set — supportedModes is "
        ~ "publishing a constant and tells a caller nothing");

    writefln("[registry_choices] %d id(s) declare a restricted mode set",
             restricted);
}
