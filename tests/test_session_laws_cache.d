// The per-preset tool attribute cache (slice M5 of the tool session model,
// doc: tool_session_model_plan_2026-09-24 R2.5 "M5", R3.8, R4.6; gap rows 284,
// 307; toolcards/tool_session_model/ M0b verdicts C-H6-*, C-M5-save, S-cache).
//
// The measured law: at a tool's DROP every attribute of every node the preset
// owns (the tool itself and its pipe nodes) is written to one cache keyed by
// the preset; the next ARM of that preset reads it back after the preset's
// own attributes. It is session state of the editor, so a scene reset made by
// the USER keeps it. Only the test-automation tail of a SCRIPT scene.reset
// clears it (CommandHttpAdapter.resetAutomationAfter), so tests stay isolated.
//
// Cells:
//   door pair  - a UI-origin scene.reset keeps the cache, a script-origin one
//                clears it (the second half is the isolation contract);
//   C-H6-elem  - Element Move: two different selections read ONE range (the
//                Element falloff is never fitted to the selection);
//   C-H6-ext   - Edge Extend: the hauled offset survives a switch to Move and
//                a re-arm by the key; the next haul still starts from 0;
//   C-H6-bev   - Poly Bevel: the arm opens the operation and resets the haul
//                attributes, while a setting attribute is recalled;
//   same-preset re-arm - re-arming the armed preset keeps its live values;
//   recall before auto-fit - a size-bearing preset's fit wins over a cached
//                geometry attribute, a cached setting is still recalled.
//
// Order inside each cell: every floor first, then the needle.

import edge_extend_gesture_helpers : Offset, armRig, engage, keyArm, offset,
    tapKey, toolId, vertexCount;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.file : exists, remove;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs;
import std.process : thisProcessID;
import std.path : buildPath;
import std.file : tempDir;

import core.thread : Thread;
import core.time : msecs;

void main() {}

private enum double kTyped = 0.37;
private enum int kSymW = 119;

private void settle() { Thread.sleep(150.msecs); }

private JSONValue command(string text) {
    auto r = postJson("/api/command", text);
    assert(r["status"].str == "ok", "command `" ~ text ~ "` failed: " ~ r.toString);
    return r;
}

private JSONValue commandId(string id, string params = null) {
    auto r = postJson("/api/command", commandBody(id, params));
    assert(r["status"].str == "ok", id ~ " failed: " ~ r.toString);
    return r;
}

private double number(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger
         : v.floating;
}

private string[string] falloffAttrs() {
    foreach (stage; getJson("/api/toolpipe")["stages"].array)
        if (stage["task"].str == "WGHT") {
            string[string] result;
            foreach (key, value; stage["attrs"].object) result[key] = value.str;
            return result;
        }
    assert(false, "falloff stage (WGHT) is absent from /api/toolpipe");
}

private double falloffRange() {
    auto attrs = falloffAttrs();
    assert(("dist" in attrs) !is null, "falloff publishes no `dist`: " ~ attrs.to!string);
    return attrs["dist"].to!double;
}

private size_t modelVertexCount() {
    return getJson("/api/model")["vertices"].array.length;
}

private void armElementMove(string cell) {
    command("tool.set xfrm.elementMove on");
    settle();
    assert(falloffAttrs()["type"] == "element",
        cell ~ ": floor - Element Move armed without the element falloff");
}

// ---------------------------------------------------------------------------
// Door pair: the UI reset keeps the cache, the script reset clears it.
// ---------------------------------------------------------------------------

unittest {
    enum cell = "door pair";
    // A clean baseline for the document state (io.doc_state syncs on reset).
    commandId("scene.reset");
    commandId("mesh.subdivide");
    assert(modelVertexCount() != 8, cell ~ ": floor - the subdivide left a cube");

    armElementMove(cell);
    command(format("tool.pipe.attr falloff dist %g", kTyped));
    assert(abs(falloffRange() - kTyped) <= 1e-6,
        cell ~ ": floor - the typed range did not reach /api/toolpipe");
    command("tool.set xfrm.elementMove off");
    settle();

    // A native save puts the document at a clean baseline, so the UI reset
    // below is APPLIED rather than deferred by the unsaved-work guard.
    const path = buildPath(tempDir, format("vibe3d_m5_cache_%d.v3d", thisProcessID()));
    scope(exit) if (exists(path)) remove(path);
    commandId("file.save", `{"path":"` ~ path ~ `"}`);

    auto ui = postJson("/api/command?origin=ui", commandBody("scene.reset"));
    assert(ui["status"].str == "ok", cell ~ ": UI scene.reset failed: " ~ ui.toString);
    settle();
    auto policy = getJson("/api/ui/policy");
    assert("last" in policy.object, cell ~ ": floor - no UI policy record: " ~ policy.toString);
    assert(policy["last"]["id"].str == "scene.reset"
        && policy["last"]["outcome"].str == "applied",
        cell ~ ": floor - the UI scene.reset did not apply: " ~ policy.toString);
    assert(!policy["pending"].boolean,
        cell ~ ": floor - the UI scene.reset left an action pending: " ~ policy.toString);
    assert(!policy["last"]["dirty"].boolean,
        cell ~ ": floor - the document was dirty at the UI reset: " ~ policy.toString);
    assert(modelVertexCount() == 8,
        format("%s: floor - the UI scene.reset did not restore the cube (%d vertices)",
               cell, modelVertexCount()));

    armElementMove(cell);
    immutable double kept = falloffRange();
    assert(abs(kept - kTyped) <= 1e-6,
        format("the tool attribute cache did not survive a UI scene.reset: range %s, typed %s",
               kept, kTyped));
    command("tool.set xfrm.elementMove off");

    // The script door is the automation boundary: it clears the cache.
    commandId("scene.reset");
    armElementMove(cell);
    immutable double fresh = falloffRange();
    assert(abs(fresh - 1.0) <= 1e-6,
        format("a script scene.reset did not clear the tool attribute cache: range %s "
             ~ "(default 1)", fresh));
    command("tool.set xfrm.elementMove off");
}

// ---------------------------------------------------------------------------
// C-H6-elem: one range for two different selections.
// ---------------------------------------------------------------------------

private string gridJson() {
    string verts, faces;
    foreach (r; 0 .. 5)
        foreach (c; 0 .. 5) {
            if (verts.length) verts ~= ",";
            verts ~= format("[%g,0,%g]", -1.0 + 0.5 * c, -1.0 + 0.5 * r);
        }
    foreach (r; 0 .. 4)
        foreach (c; 0 .. 4) {
            immutable int i = r * 5 + c;
            if (faces.length) faces ~= ",";
            faces ~= format("[%d,%d,%d,%d]", i, i + 5, i + 6, i + 1);
        }
    return `{"vertices":[` ~ verts ~ `],"faces":[` ~ faces ~ `]}`;
}

unittest {
    enum cell = "C-H6-elem";
    commandId("scene.reset");
    command("tool.pipe.attr symmetry enabled false");
    commandId("scene.loadMesh", gridJson());
    assert(modelVertexCount() == 25, cell ~ ": floor - grid did not load");

    // Selection A: vertices 6 and 18, box 1.0 x 1.0 (a fit would give 0.5).
    command("select.element vertex set 6 18");

    // The type switch is where our code used to fit an Element range to the
    // selection (FalloffStage.autoSizeUntouchedType, gap 284). The reference
    // fits it on no path.
    command("tool.pipe.attr falloff type element");
    immutable double switched = falloffRange();
    assert(abs(switched - 0.5) > 1e-3,
        format("the Element falloff range was fitted to the selection at the type switch "
             ~ "(read %s = the half extent of the 1.0 x 1.0 selection; gap 284)", switched));
    command("tool.pipe.attr falloff type none");

    armElementMove(cell);
    immutable double first = falloffRange();
    assert(abs(first - 0.5) > 1e-3,
        format("the Element falloff range was fitted to the selection (read %s = the "
             ~ "half extent of the 1.0 x 1.0 selection; gap 284)", first));
    command("tool.set xfrm.elementMove off");

    // Selection B: seven vertices, box 2.0 x 0.5.
    command("select.element vertex set 0 1 2 3 4 5 9");
    armElementMove(cell);
    immutable double second = falloffRange();
    assert(abs(second - first) <= 1e-6,
        format("two selections read two Element ranges (%s then %s); the range is one "
             ~ "cached attribute, never fitted", first, second));
    command("tool.set xfrm.elementMove off");
}

// ---------------------------------------------------------------------------
// C-H6-ext: the hauled offset survives `w` then the key; the next haul is 0-based.
// ---------------------------------------------------------------------------

unittest {
    enum cell = "C-H6-ext";
    armRig([[7, 8]], 1.0);
    engage();
    immutable Offset hauled = offset();
    assert(hauled.z < 0 && hauled.x == 0 && hauled.y == 0,
        cell ~ ": floor - the engage haul wrote no -Z offset: " ~ hauled.to!string);

    tapKey(kSymW);
    settle();
    assert(toolId() == "xfrm", cell ~ ": floor - `w` did not switch to Move: " ~ toolId());
    immutable size_t committed = vertexCount();

    keyArm();
    assert(vertexCount() == committed,
        format("%s: floor - the re-arm changed the mesh (%d -> %d vertices)",
               cell, committed, vertexCount()));
    immutable Offset recalled = offset();
    assert(abs(recalled.x - hauled.x) <= 1e-6 && abs(recalled.y - hauled.y) <= 1e-6
        && abs(recalled.z - hauled.z) <= 1e-6,
        format("the Edge Extend offset did not survive `w` and the key (read %s, hauled %s)",
               recalled, hauled));

    // The next operation still opens from 0 (H5): the same engage writes the
    // same offset, not the recalled one plus it.
    engage();
    immutable Offset second = offset();
    assert(abs(second.z - hauled.z) <= 1e-6,
        format("the haul after a recall accumulated onto the recalled offset "
             ~ "(read %s, a fresh haul writes %s)", second, hauled));
    command("tool.set edge.extend off");
}

// ---------------------------------------------------------------------------
// C-H6-bev: the arm opens Poly Bevel's operation, which resets the haul
// attributes; a setting attribute is still recalled.
// ---------------------------------------------------------------------------

private JSONValue toolAttr(string id, string name) {
    auto r = command(format("tool.attr %s %s ?", id, name));
    assert("value" in r.object, "tool.attr query returned no value: " ~ r.toString);
    return r["value"];
}

unittest {
    enum cell = "C-H6-bev";
    commandId("scene.reset");
    command("select.typeFrom polygon");
    command("select.element polygon set 0");
    command("tool.set poly.bevel on");
    settle();
    command("tool.attr poly.bevel inset 0.2");
    command("tool.attr poly.bevel segments 3");
    assert(abs(number(toolAttr("poly.bevel", "inset")) - 0.2) <= 1e-6
        && toolAttr("poly.bevel", "segments").integer == 3,
        cell ~ ": floor - the attribute writes did not land");
    command("tool.set poly.bevel off");
    settle();

    command("tool.set poly.bevel on");
    settle();
    immutable long segments = toolAttr("poly.bevel", "segments").integer;
    assert(segments == 3,
        format("the Poly Bevel setting was not recalled at the re-arm (segments %d, set 3)",
               segments));
    immutable double inset = number(toolAttr("poly.bevel", "inset"));
    assert(abs(inset) <= 1e-9,
        format("the arm did not reset the Poly Bevel haul attribute (inset %s; the arm "
             ~ "opens the operation, C-H6-bev)", inset));
    command("tool.set poly.bevel off");
}

// ---------------------------------------------------------------------------
// Re-arming the SAME preset while it is armed reads the values it is leaving,
// not the ones cached before them (the prepared switch captures the outgoing
// instance and the incoming image overlays that capture).
// ---------------------------------------------------------------------------

unittest {
    enum cell = "same-preset re-arm";
    commandId("scene.reset");
    command("tool.set mesh.radialArrayTool");
    command("tool.attr mesh.radialArrayTool count 8");
    assert(toolAttr("mesh.radialArrayTool", "count").integer == 8,
        cell ~ ": floor - the count write did not land");
    command("tool.set mesh.radialArrayTool on");
    settle();
    immutable long count = toolAttr("mesh.radialArrayTool", "count").integer;
    assert(count == 8,
        format("re-arming the armed preset lost its live attribute (count %d, set 8)", count));
    command("tool.set mesh.radialArrayTool off");
}

// ---------------------------------------------------------------------------
// A size-bearing preset: the recall lands BEFORE the activation auto-fit, so
// the fit wins over a cached geometry attribute while a cached setting stays.
// ---------------------------------------------------------------------------

private double[3] vec3Attr(string text) {
    import std.array : split;
    auto p = text.split(",");
    assert(p.length == 3, "not a vec3: " ~ text);
    return [p[0].to!double, p[1].to!double, p[2].to!double];
}

unittest {
    enum cell = "recall before auto-fit";
    commandId("scene.reset");
    command("tool.set xfrm.taper on");
    settle();
    auto fitted = falloffAttrs();
    assert(fitted["type"] == "linear", cell ~ ": floor - taper armed without its linear falloff");
    immutable double[3] fitStart = vec3Attr(fitted["start"]);
    command(`tool.pipe.attr falloff start "9,8,7"`);
    command("tool.pipe.attr falloff shape smooth");
    assert(falloffAttrs()["start"] == "9,8,7",
        cell ~ ": floor - the start write did not land: " ~ falloffAttrs()["start"]);
    command("tool.set xfrm.taper off");
    settle();

    command("tool.set xfrm.taper on");
    settle();
    auto again = falloffAttrs();
    immutable double[3] start = vec3Attr(again["start"]);
    assert(abs(start[0] - fitStart[0]) <= 1e-5 && abs(start[1] - fitStart[1]) <= 1e-5
        && abs(start[2] - fitStart[2]) <= 1e-5,
        format("the activation auto-fit did not win over the cached start (read %s, fit %s)",
               again["start"], fitStart));
    assert(again["shape"] == "smooth",
        "the cached falloff shape was not recalled at the re-arm: " ~ again["shape"]);
    command("tool.set xfrm.taper off");
}
