module tests.unit.toolpipe.attr_cache_test;

// Slice M5/M5b (doc/tool_session_model_plan_2026-09-24.md R2.5 "M5", R3.8):
// the per-preset tool attribute cache. u1-u4 exercise the ONE store and its
// capture/recall on real stages; u5 the prefs section it persists through;
// u6-u8 are source censuses of the production wiring, because a cell that
// builds its own collaborators cannot see a rewired call site.

import std.algorithm.searching : canFind, count;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.format : format;
import std.math : abs;
import std.path : buildPath;
import std.process : thisProcessID;
import std.string : indexOf;

import params : Param, ParamProvider;
import prefs : Prefs, loadPrefs, savePrefs;
import prepared_pipe_activation : PreparedPipeActivationOwner;
import registry : PreparedPipeAttrs;
import tests.unit.census_symbols : blankNonCode;
import tool_activation_ownership : PipeArmScope;
import toolpipe.attr_cache : NodeAttrs, PipelineAttrCache, captureDroppedNodes,
    captureNodeAttrs, kToolNode, recallNodeAttrs;
import toolpipe.packets : FalloffShape, FalloffType;
import toolpipe.pipeline : Pipeline;
import toolpipe.stage : Stage;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.stages.constrain : ConstrainStage;
import toolpipe.stages.falloff : FalloffStage;

private final class FakeNode : ParamProvider {
    float width = 1.0f;
    float drawn = 0.0f;       // transient: gesture geometry
    float derived = 2.0f;     // read-only: display
    string label = "initial";
    string[] changed;
    Param[] params() { return [
        Param.float_("width", "Width", &width, 1.0f),
        Param.float_("drawn", "Drawn", &drawn, 0.0f).transient(),
        Param.float_("derived", "Derived", &derived, 2.0f).readonly(),
        Param.string_("label", "Label", &label, "initial"),
    ]; }
    bool paramEnabled(string name) const { return true; }
    void onParamChanged(string name) { changed ~= name; }
}

unittest { // u1: one store keyed preset -> node -> attr
    PipelineAttrCache cache;
    assert(cache.empty, "M5 u1: a fresh cache is not empty");
    cache.store("xfrm.elementMove", "falloff", ["dist": "0.37"]);
    cache.store("xfrm.elementMove", kToolNode, ["R": "true"]);
    cache.store("edge.extend", kToolNode, ["offsetX": "0.3"]);
    cache.store("edge.extend", "falloff", null);      // empty: nothing stored
    cache.store("", kToolNode, ["x": "1"]);            // no preset: nothing
    assert(cache.presetCount == 2,
        format("M5 u1: population floor - expected 2 presets, got %d", cache.presetCount));
    assert(cache.lookup("edge.extend", "falloff") is null,
        "M5 u1: an empty node image was stored");
    assert((*cache.lookup("xfrm.elementMove", "falloff"))["dist"] == "0.37"
        && (*cache.lookup("edge.extend", kToolNode))["offsetX"] == "0.3",
        "M5 u1: a stored node did not read back");
    cache.store("xfrm.elementMove", "falloff", ["dist": "0.5"]);
    assert((*cache.lookup("xfrm.elementMove", "falloff"))["dist"] == "0.5",
        "M5 u1: a second drop did not replace the node");
    assert(cache.presetNodes("xfrm.elementMove").length == 2,
        "M5 u1: presetNodes lost a node");
    cache.removePreset("xfrm.elementMove");
    assert(cache.lookup("xfrm.elementMove", kToolNode) is null
        && cache.lookup("edge.extend", kToolNode) !is null,
        "M5 u1: removePreset touched another preset or kept its own");
    cache.clear();
    assert(cache.empty, "M5 u1: clear left an entry");
}

unittest { // u2: capture and recall are one rule for every node
    auto node = new FakeNode();
    node.width = 0.25f; node.drawn = 5.0f; node.label = "kept";
    auto image = captureNodeAttrs(node);
    assert(image.length == 2,
        format("M5 u2: capture population - expected width+label, got %s", image));
    assert(image["width"] == "0.25" && image["label"] == "kept"
        && "drawn" !in image && "derived" !in image,
        "M5 u2: capture took a transient/read-only Param or lost a setting");

    auto fresh = new FakeNode();
    auto changed = recallNodeAttrs(fresh, image, false);
    assert(abs(fresh.width - 0.25f) <= 1e-6 && fresh.label == "kept",
        "M5 u2: recall did not write the values back");
    assert(changed.length == 2 && fresh.changed.length == 0,
        "M5 u2: recall without notify fired a hook, or lost a name");

    // A value already in place is not a change; a stale name is skipped.
    auto again = new FakeNode();
    again.label = "kept";
    NodeAttrs stale = image.dup;
    stale["noSuchParam"] = "9";
    // A hand-edited or older prefs file can name a transient Param; the
    // recall applies the same capture rule and leaves it alone.
    stale["drawn"] = "7";
    changed = recallNodeAttrs(again, stale, true);
    assert(changed == ["width"] && again.changed == ["width"],
        format("M5 u2: equal/stale filtering or notify broken (changed %s, hooks %s)",
               changed, again.changed));
    assert(again.drawn == 0.0f,
        format("M5 u2: the recall wrote a transient Param (drawn %s)", again.drawn));
}

private Pipeline fourStagePipe(out ActionCenterStage acen, out FalloffStage falloff) {
    Pipeline pipe;
    acen = new ActionCenterStage(null, null);
    falloff = new FalloffStage();
    pipe.add(acen);
    pipe.add(new AxisStage());
    pipe.add(new ConstrainStage());
    pipe.add(falloff);
    return pipe;
}

unittest { // u3: a drop captures the tool and only the stages the preset claims
    ActionCenterStage acen;
    FalloffStage falloff;
    auto pipe = fourStagePipe(acen, falloff);
    falloff.type = FalloffType.Element;
    falloff.pickedRadius = 0.37f;
    auto tool = new FakeNode();
    tool.width = 0.5f;

    auto unclaimed = captureDroppedNodes("xfrm.elementMove", tool, pipe.allMut());
    assert(kToolNode in unclaimed.nodes,
        format("M5 u3: the drop did not capture the tool node: %s", unclaimed.nodes.keys));
    assert(unclaimed.nodes.length == 1,
        format("M5 u3: an unclaimed stage was captured under the preset: %s",
               unclaimed.nodes.keys));

    falloff.claimForPreset();
    auto dropped = captureDroppedNodes("xfrm.elementMove", tool, pipe.allMut());
    assert(dropped.nodes.length == 2 && "falloff" in dropped.nodes,
        format("M5 u3: the claimed falloff was not captured: %s", dropped.nodes.keys));
    assert(dropped.nodes["falloff"]["dist"] == "0.37",
        "M5 u3: the falloff node lost its range");
    assert(captureDroppedNodes("", tool, pipe.allMut()).nodes.length == 0,
        "M5 u3: a drop without a preset id captured nodes");

    PipelineAttrCache cache;
    dropped.commitTo(cache);
    assert((*cache.lookup("xfrm.elementMove", kToolNode))["width"] == "0.5"
        && (*cache.lookup("xfrm.elementMove", "falloff"))["dist"] == "0.37",
        "M5 u3: commitTo did not write both nodes");
}

unittest { // u4: the prepared arm recalls a claimed stage after its preset image
    ActionCenterStage acen;
    FalloffStage falloff;
    auto pipe = fourStagePipe(acen, falloff);
    PreparedPipeAttrs attrs;
    attrs["falloff"] = ["type": "element", "shape": "linear"];
    NodeAttrs[string] recall;
    recall["falloff"] = ["dist": "0.37", "shape": "smooth"];

    auto owner = PreparedPipeActivationOwner.prepare(pipe, attrs, null,
        PipeArmScope.presetArm, recall);
    assert(falloff.type == FalloffType.None,
        "M5 u4: prepare wrote live state");
    owner.install();
    assert(falloff.type == FalloffType.Element,
        "M5 u4: floor - the preset image did not install the element falloff");
    assert(abs(falloff.pickedRadius - 0.37f) <= 1e-6,
        format("M5 u4: the cached range was not recalled at the arm (read %s)",
               falloff.pickedRadius));
    assert(falloff.shape == FalloffShape.Smooth,
        "M5 u4: the recall did not override the preset's own shape");

    // Every claimed node, not only the falloff: an action-centre image is
    // recalled over the preset's own mode the same way. (No shipped path
    // stores a mode that differs from the preset's — a mode write releases
    // the claim — so this is the owner's wiring, driven directly.)
    auto pipe3 = fourStagePipe(acen, falloff);
    PreparedPipeAttrs acenPreset;
    acenPreset["actionCenter"] = ["mode": "element"];
    NodeAttrs[string] acenRecall;
    acenRecall["actionCenter"] = ["mode": "origin"];
    PreparedPipeActivationOwner.prepare(pipe3, acenPreset, null,
        PipeArmScope.presetArm, acenRecall).install();
    assert(acen.mode == ActionCenterStage.Mode.Origin,
        format("M5 u4: the action-centre node was not recalled (mode %s)", acen.mode));

    // A preset that does not claim the falloff does not recall it.
    auto pipe2 = fourStagePipe(acen, falloff);
    PreparedPipeAttrs noFalloff;
    noFalloff["actionCenter"] = ["mode": "element"];
    auto owner2 = PreparedPipeActivationOwner.prepare(pipe2, noFalloff, null,
        PipeArmScope.presetArm, recall);
    owner2.install();
    assert(abs(falloff.pickedRadius - 0.37f) > 1e-3,
        format("M5 u4: an unclaimed falloff received the preset's cached range (%s)",
               falloff.pickedRadius));
}

unittest { // u5: the cache is a section of the prefs document (M5b)
    auto dir = buildPath(tempDir, format("vibe3d_m5_prefs_%d", thisProcessID()));
    mkdirRecurse(dir);
    scope(exit) if (exists(dir)) rmdirRecurse(dir);

    // Empty cache round-trips as empty.
    Prefs empty;
    savePrefs(empty, dir);
    assert(loadPrefs(dir).toolAttrCache.empty,
        "M5b u5: an empty cache did not read back empty");

    Prefs p;
    p.toolAttrCache.store("xfrm.elementMove", "falloff", ["dist": "0.37", "shape": "smooth"]);
    p.toolAttrCache.store("xfrm.elementMove", kToolNode, ["R": "true"]);
    p.toolAttrCache.store("edge.extend", kToolNode, ["offsetX": "-0.135"]);
    savePrefs(p, dir);
    auto q = loadPrefs(dir);
    assert(q.toolAttrCache.presetCount == 2,
        format("M5b u5: population floor - expected 2 presets, got %d",
               q.toolAttrCache.presetCount));
    assert(q.toolAttrCache == p.toolAttrCache,
        "M5b u5: the cache section did not survive save+load");

    // A pre-M5 file (`toolDefaults`, tool node only) is read into the tool
    // node; the current section wins where both name the same node.
    write(buildPath(dir, "prefs.json"),
        `{"version":1,"toolDefaults":{"bevel":{"width":"0.25"},"edge.extend":{"offsetX":"9"}},`
        ~ `"toolAttrCache":{"edge.extend":{"tool":{"offsetX":"-0.1"}}}}`);
    auto legacy = loadPrefs(dir);
    auto bevel = legacy.toolAttrCache.lookup("bevel", kToolNode);
    assert(bevel !is null && (*bevel)["width"] == "0.25",
        "M5b u5: the legacy toolDefaults entry was not read into the tool node");
    auto extend = legacy.toolAttrCache.lookup("edge.extend", kToolNode);
    assert(extend !is null && (*extend)["offsetX"] == "-0.1",
        "M5b u5: a legacy entry overrode the current section");
}

/// `{ ... }` body of the first declaration introduced by `marker`.
private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "M5 census: marker moved: " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "M5 census: no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    assert(false, "M5 census: unbalanced body after " ~ marker);
}

private size_t at(string hay, string needle, string what) {
    const i = hay.indexOf(needle);
    assert(i >= 0, "M5 census: " ~ what ~ " - `" ~ needle ~ "` is gone");
    return cast(size_t) i;
}

unittest { // u6: the file I/O is behind prefsActive, the in-memory store is not
    auto app = blankNonCode(readText("source/app.d"));
    assert(app.count("loadPrefs(") == 1 && app.canFind("if (prefsActive) loadPrefs();"),
        "M5b u6: prefs are read somewhere other than the prefsActive gate");
    assert(app.count("persistPrefsOnExit(") == 2
        && app.canFind("scope(exit) if (prefsActive) persistPrefsOnExit();"),
        "M5b u6: prefs are written somewhere other than the prefsActive exit guard");
    // Two writers: the exit guard, and the splitter release, which carries its
    // own prefsActive gate (it had none before M5b).
    assert(app.count("savePrefs(") == 2
        && bodyAt(app, "void persistPrefsOnExit(").canFind("savePrefs();")
        && app.canFind("if (prefsActive) {\n                                try savePrefs(); catch (Exception) {}"),
        "M5b u6: savePrefs is reached outside the prefsActive paths");

    auto store = bodyAt(app, "void storeDroppedToolNodes(");
    assert(store.canFind("captureDroppedNodes(")
        && store.canFind(".commitTo(g_prefs.toolAttrCache);"),
        "M5 u6: the drop door no longer stores into the one cache");
    assert(!store.canFind("prefsActive"),
        "M5 u6: the in-memory store is gated on prefsActive - the cache must "
        ~ "change at every drop, only its file section is gated");

    auto drop = bodyAt(app, "void dropActiveTool(");
    const storeAt = at(drop, "storeDroppedToolNodes();", "dropActiveTool store");
    assert(storeAt < at(drop, "activeTool.deactivate();", "dropActiveTool deactivate")
        && storeAt < at(drop, "resetTransientPipeStages();", "dropActiveTool reset"),
        "M5 u6: the drop stores after the tool or the stages lost their values");
}

unittest { // u7: the ONE clear is the script scene.reset automation tail
    auto adapter = blankNonCode(readText("source/http_command_adapter.d"));
    assert(bodyAt(adapter, "void resetAutomationAfter(")
               .canFind("automation_.clearPipelineAttrCache();"),
        "M5 u7: resetAutomationAfter stopped clearing the tool attribute cache");
    assert(!bodyAt(adapter, "void resetAutomationBefore(").canFind("clearPipelineAttrCache")
        && !bodyAt(adapter, "CommandInvocationResult dispatchUi(").canFind("clearPipelineAttrCache"),
        "M5 u7: the tool attribute cache is cleared on the UI door");
    auto app = blankNonCode(readText("source/app.d"));
    assert(app.canFind("&clearPipelineAttrCacheForAutomation"),
        "M5 u7: app.d no longer wires the cache clear into the automation reset");
    auto prefsMod = blankNonCode(readText("source/prefs.d"));
    assert(bodyAt(prefsMod, "void clearPipelineAttrCacheForAutomation(")
               .canFind("g_prefs.toolAttrCache.clear();"),
        "M5 u7: the automation hook does not clear the cache the arms read");

    // No other production site clears the cache (a user-visible reset keeps
    // it): one `toolAttrCache.clear(` in the whole source tree.
    import std.file : SpanMode, dirEntries;
    size_t clears, files;
    foreach (f; dirEntries("source", "*.d", SpanMode.depth)) {
        ++files;
        clears += blankNonCode(readText(f.name)).count("toolAttrCache.clear(");
    }
    assert(files > 100, format("M5 u7: population floor - scanned %d source files", files));
    assert(clears == 1,
        format("M5 u7: the tool attribute cache is cleared at %d sites, expected 1", clears));
}

unittest { // u8: the prepared switch stores the predecessor and recalls in order
    auto tr = blankNonCode(readText("source/prepared_tool_transition.d"));
    assert(bodyAt(tr, "PreparedArm prepareArm(")
               .canFind("captureDroppedNodes(retainedOldId, retainedOld,"),
        "M5 u8: the prepared switch no longer captures the predecessor's nodes");
    auto commit = bodyAt(tr, "bool commitPreparedArm(");
    assert(at(commit, "prepared.dropped_.commitTo(*prepared.attrCache_);", "commit store")
         < at(commit, "prepared.pipe_.install();", "commit pipe install"),
        "M5 u8: the predecessor's nodes are committed after the pipe reset");

    auto owner = blankNonCode(readText("source/prepared_pipe_activation.d"));
    auto install = bodyAt(owner, "void install()");
    const preset = at(install, "falloff_.installPreparedPreset(", "falloff preset");
    const recall = at(install, "recallStage(falloff_, recallFalloff_);", "falloff recall");
    const fit = at(install, "falloff_.installPreparedAutoFit(", "falloff auto-fit");
    assert(preset < recall && recall < fit,
        "M5 u8: the falloff recall is not between its preset image and the auto-fit");
}
