// Behavioural censuses for commands that discard a document or move its
// primary layer while a real tool gesture is armed. New registered commands
// enter the sweeps by default; exclusions below are harness hazards, not
// policy exemptions.

import http_client : testBaseUrl, getJson, postJson, postRaw;
import http_command_helpers : commandBody;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm : canFind, sort, startsWith;
import std.array : array;
import std.conv : to;
import std.digest.sha : sha1Of, toHexString;
import std.file : exists, mkdirRecurse;
import std.json;
import std.net.curl : get, post;
import std.path : buildPath;
import std.process : thisProcessID;
import std.stdio : writefln;

void main() {}

alias BASE = testBaseUrl;
enum string TOOL = "mesh.mirrorTool";


void resetTo(string query = null) {
    auto r = postJson("/api/reset" ~ query, "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
}

string fireCommand(string id, string paramsJson = null) {
    const body_ = paramsJson.length
        ? `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`
        : id;
    return postJson("/api/command", body_)["status"].str;
}

void seedSelection() {
    postRaw("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0]}`));
}

void armMirror(string context = null) {
    auto setResult = postJson("/api/command",
        `{"id":"tool.reset","params":{"_positional":["` ~ TOOL ~ `"]}}`);
    assert(setResult["status"].str == "ok",
        "census row " ~ context ~ " could not reset and arm the mirror tool: "
        ~ setResult.toString);
    const attrStatus = fireCommand("tool.attr",
        `{"_positional":["` ~ TOOL ~ `","mergeVerts","false"]}`);
    assert(attrStatus == "ok",
        "census row " ~ context ~ " could not engage the mirror tool: "
        ~ attrStatus);
    auto probe = postJson("/api/command", "tool.attr " ~ TOOL ~ " mergeVerts ?");
    assert(probe["status"].str == "ok",
        "the census row " ~ context ~ " must contain a live tool gesture: "
        ~ probe.toString);
}

ulong crossings() {
    return cast(ulong)getJson("/api/tool/disarm")["crossings"].integer;
}

bool primaryBirthId(out ulong birthId) {
    foreach (l; getJson("/api/layers")["layers"].array) {
        if (l["primary"].type != JSONType.true_) continue;
        const id = l["birthId"];
        assert(id.type == JSONType.integer || id.type == JSONType.uinteger,
            "layer birthId is not an integer: " ~ id.toString);
        birthId = id.type == JSONType.uinteger
            ? id.uinteger : cast(ulong)id.integer;
        return true;
    }
    return false;
}

bool mirrorIsActive() {
    auto probe = postJson("/api/command",
        "tool.attr " ~ TOOL ~ " mergeVerts ?");
    return probe["status"].str == "ok";
}

string documentSignature() {
    auto layers = getJson("/api/layers")["layers"].array;
    string acc;
    foreach (i, l; layers) {
        acc ~= l["type"].toString ~ l["name"].toString ~ "#";
        auto m = getJson("/api/model?layer=" ~ i.to!string);
        acc ~= (("vertices" in m.object) ? m["vertices"].toString : "-")
             ~ "#"
             ~ (("faces" in m.object) ? m["faces"].toString : "-") ~ "|";
    }
    return sha1Of(acc).toHexString.idup;
}

immutable string[] kSkipPrefixes = [
    "undo.lockout.", "ui.", "selftest.", "ai3d.", "macro."
];

immutable string[] kSkipExact = [
    "mesh.remesh", "mesh.remesh.open", "file.quit"
];

bool skipped(string id) {
    foreach (p; kSkipPrefixes) if (id.startsWith(p)) return true;
    foreach (e; kSkipExact) if (id == e) return true;
    return false;
}

string[string] buildSeeds() {
    const dir = buildPath("/tmp", "vibe3d_disarm_census_" ~ thisProcessID.to!string);
    mkdirRecurse(dir);
    resetTo();
    string makeSeed(string id, string ext) {
        const path = buildPath(dir, "seed" ~ ext);
        assert(fireCommand(id, `{"path":"` ~ path ~ `"}`) == "ok",
            "census setup failed for " ~ id);
        assert(exists(path), "census setup wrote no " ~ path);
        return path;
    }
    const v3d = makeSeed("file.save", ".v3d");
    const obj = makeSeed("file.export.obj", ".obj");
    const lwo = makeSeed("file.export.lwo", ".lwo");
    const gltf = makeSeed("file.export.gltf", ".gltf");
    const fbx = makeSeed("file.export.fbx", ".fbx");
    string[string] seeds;
    seeds["file.load"] = `{"path":"` ~ v3d ~ `"}`;
    seeds["file.open"] = seeds["file.load"];
    seeds["file.import.obj"] = `{"path":"` ~ obj ~ `"}`;
    seeds["file.import.lwo"] = `{"path":"` ~ lwo ~ `"}`;
    seeds["file.import.gltf"] = `{"path":"` ~ gltf ~ `"}`;
    seeds["file.import.fbx"] = `{"path":"` ~ fbx ~ `"}`;
    return seeds;
}

void assertCleanTeardown(string passName) {
    // The same three state-outlives-the-sweep guards as the discard census.
    auto display = getJson("/api/viewport/display")["input"];
    assert(display["viewportInputAllowed"].boolean,
        passName ~ " left the viewport refusing input: " ~ display.toString);
    auto undo = getJson("/api/undo/status");
    assert(!undo["lockout"].boolean,
        passName ~ " left history locked out");
    postRaw("/api/frames/counts/reset", "{}");
    Thread.sleep(400.msecs);
    auto fc = getJson("/api/frames/counts");
    assert(fc["frames"].integer > 0,
        passName ~ " teardown observed no completed frames");
    assert(fc["totals"]["statRebuilds"].integer == 0,
        passName ~ " left the Statistics panel drawing");
    // Own the fourth hazard: never hand an armed tool to the next test.
    postRaw("/api/command", "tool.set " ~ TOOL ~ " off");
    resetTo();
}

string[] observedDiscardIds(JSONValue[] ids, string[string] seeds,
                            out size_t swept) {
    string[] result;
    foreach (idv; ids) {
        const id = idv.str;
        if (skipped(id)) continue;
        const args = (id in seeds) ? seeds[id] : null;
        resetTo();
        seedSelection();
        fireCommand(id, args);
        const a = documentSignature();
        resetTo("?type=subdivcube&levels=2");
        seedSelection();
        fireCommand(id, args);
        const b = documentSignature();
        ++swept;
        if (a == b) result ~= id;
    }
    return result.sort.array;
}

// K7 / C-A: every observed discard crosses the shared seam with a live tool.
unittest {
    assert(fireCommand("ui.statistics", `{"_positional":["hide"]}`) == "ok",
        "census precondition could not close the Statistics panel");
    auto seeds = buildSeeds();
    auto ids = getJson("/api/registry")["commands"].array;
    size_t swept;
    auto subset = observedDiscardIds(ids, seeds, swept);
    writefln("DISARM CENSUS C-A: swept=%s subset=%s", swept, subset);
    assert(swept > 200,
        "the disarm census swept only " ~ swept.to!string ~ " commands");
    assert(subset.length >= 4,
        "the observed-discard subset is too small and could pass vacuously: "
        ~ subset.to!string);

    string[] undisarmed;
    foreach (id; subset) {
        resetTo();
        seedSelection();
        armMirror(id);
        const before = crossings();
        const args = (id in seeds) ? seeds[id] : null;
        fireCommand(id, args);
        const after = crossings();
        if (after == before) {
            undisarmed ~= id;
        } else {
            auto d = getJson("/api/tool/disarm");
            assert(d["hadTool"].boolean,
                "discard id " ~ id ~ " crossed the seam without reporting "
                ~ "the live tool: " ~ d.toString);
        }
        postRaw("/api/command", "tool.set " ~ TOOL ~ " off");
    }
    assertCleanTeardown("discard disarm census");
    assert(undisarmed.length == 0,
        "UNDISARMED DISCARD: " ~ undisarmed.sort.array.to!string
        ~ " threw the document away under a live tool gesture without "
        ~ "crossing source/tool_disarm.d");
}

// K11 / C-A2: a command that moves the primary either crosses the seam during
// apply, or belongs to the single registry-published pre-apply-drop set.
unittest {
    assert(fireCommand("ui.statistics", `{"_positional":["hide"]}`) == "ok",
        "primary-move census could not close the Statistics panel");
    auto seeds = buildSeeds();
    auto registry = getJson("/api/registry");
    auto ids = registry["commands"].array;
    string[] preApplyDrops;
    foreach (id; registry["commandsDroppingToolBeforeApply"].array)
        preApplyDrops ~= id.str;

    size_t swept;
    string[] checked;
    string[] excused;
    string[] uncrossed;
    string[] excusedStillArmed;
    foreach (idv; ids) {
        const id = idv.str;
        if (skipped(id)) continue;

        resetTo();
        assert(fireCommand("layer.add") == "ok",
            "primary-move census could not build its second layer");
        assert(fireCommand("layer.select", `{"index":0,"mode":"set"}`) == "ok",
            "primary-move census could not select its cube layer");
        seedSelection();
        armMirror(id);

        ulong beforeBirth;
        assert(primaryBirthId(beforeBirth),
            "primary-move census row " ~ id ~ " began without a primary");
        const beforeCrossings = crossings();
        const args = id == "layer.select"
            ? `{"index":1,"mode":"set"}`
            : ((id in seeds) ? seeds[id] : null);
        fireCommand(id, args);

        ulong afterBirth;
        const hasAfterBirth = primaryBirthId(afterBirth);
        if (!hasAfterBirth || afterBirth != beforeBirth) {
            if (preApplyDrops.canFind(id)) {
                excused ~= id;
                if (mirrorIsActive()) excusedStillArmed ~= id;
            } else {
                checked ~= id;
                if (crossings() == beforeCrossings) {
                    uncrossed ~= id ~ " (birthId " ~ beforeBirth.to!string
                        ~ "->" ~ (hasAfterBirth ? afterBirth.to!string : "none")
                        ~ ")";
                }
            }
        }
        ++swept;
        postRaw("/api/command", "tool.set " ~ TOOL ~ " off");
    }

    checked = checked.sort.array;
    excused = excused.sort.array;
    writefln("DISARM CENSUS C-A2: swept=%s checked=%s excused=%s",
        swept, checked, excused);
    assert(swept > 200,
        "the primary-move census swept only " ~ swept.to!string ~ " commands");
    assertCleanTeardown("primary-move disarm census");
    assert(uncrossed.length == 0,
        "PRIMARY MOVED WITHOUT CROSSING THE DISARM SEAM: "
        ~ uncrossed.sort.array.to!string
        ~ " moved the edit target under a live mesh.mirrorTool gesture and "
        ~ "crossings did not move — the drop happened AFTER the move, so "
        ~ "the commit lands in the layer that was just selected");
    assert(excusedStillArmed.length == 0,
        "PRE-APPLY TOOL DROP FAILED: "
        ~ excusedStillArmed.sort.array.to!string
        ~ " moved the edit target but left mesh.mirrorTool armed");
    assert(checked.canFind("layer.select"),
        "the checked primary-move population lost layer.select: "
        ~ checked.to!string);
    assert(excused.canFind("layer.add"),
        "the pre-apply-drop population lost layer.add: " ~ excused.to!string);
    assert(checked.length >= 3,
        "the checked primary-move population is too small: "
        ~ checked.to!string);
    assert(excused.length >= 3,
        "the pre-apply-drop population is too small: " ~ excused.to!string);
}
