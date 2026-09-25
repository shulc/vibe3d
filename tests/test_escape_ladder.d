// The five-rung Escape ladder and its item-mode Space alias, driven through
// the production SDL event route against the frozen task-5911 capture.
module test_escape_ladder;

import drag_helpers : playAndWait;
import http_client : getJson, postJson, quiesce;
import http_command_helpers : commandBody;
import tool_drop_pipe_stages_helpers : applyHistoryDelta;
import core.thread : Thread;
import core.time : dur;
import std.algorithm.searching : canFind;
import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : approxEqual;
import std.string : indexOf, startsWith;

void main() {}

private JSONValue fixture() {
    static JSONValue cached;
    if (cached.type == JSONType.null_)
        cached = parseJSON(import("fixtures/tool_drop_pipe_stages.json"));
    return cached;
}

// Card test-sleep-removal: quiesce (frame fence + no pending preview build) replaces the fixed sleep (dur!"msecs"(150)).

private void settle() { quiesce(); }

private void cmd(string text) {
    const body = text.indexOf(' ') < 0 ? commandBody(text) : text;
    auto answer = postJson("/api/command", body);
    assert(answer["status"].str == "ok",
        format("command `%s` failed: %s", text, answer.toString));
    settle();
}

private void key(string name) {
    int sym, scan;
    if (name == "escape") { sym = 27; scan = 41; }
    else if (name == "space") { sym = 32; scan = 44; }
    else assert(0, "unknown ladder key " ~ name);
    const log =
        `{"t":0.000,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
        format(`{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}`, sym, scan) ~ "\n" ~
        format(`{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":0,"repeat":0}`, sym, scan) ~ "\n";
    playAndWait(log);
    settle();
}

private void ctrlZ() {
    const log =
        `{"t":0.000,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_KEYDOWN","sym":122,"scan":29,"mod":64,"repeat":0}` ~ "\n" ~
        `{"t":100.000,"type":"SDL_KEYUP","sym":122,"scan":29,"mod":64,"repeat":0}` ~ "\n";
    playAndWait(log);
    settle();
}

private void click(int x, int y) {
    const log =
        `{"t":0.000,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
        format(`{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`, x, y) ~ "\n" ~
        format(`{"t":55.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, x, y) ~ "\n" ~
        format(`{"t":60.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`, x, y) ~ "\n";
    playAndWait(log);
    settle();
}

private JSONValue stageState() {
    JSONValue[string] out_;
    out_["actionCenter"] = "<missing>";
    out_["axis"] = "<missing>";
    out_["falloff"] = "<missing>";
    out_["constrain"] = "<missing>";
    long stacked;
    foreach (stage; getJson("/api/toolpipe")["stages"].array) {
        const id = stage["id"].str;
        const attrs = stage["attrs"];
        if (id == "actionCenter") out_["actionCenter"] = attrs["mode"];
        else if (id == "axis") out_["axis"] = attrs["mode"];
        else if (id == "falloff") out_["falloff"] = attrs["type"];
        else if (id == "snap") out_["snap"] = attrs["enabled"];
        else if (id == "constrain") out_["constrain"] = attrs["enabled"];
        else if (id == "symmetry")
            out_["symmetry"] = JSONValue(attrs["enabled"].str == "true");
        else if (id == "workplane") {
            JSONValue[string] wp;
            wp["cenY"] = attrs["cenY"].str.to!double;
            out_["workplane"] = JSONValue(wp);
        }
        if (stage["task"].str == "WGHT" && id != "falloff") ++stacked;
    }
    out_["stackedFalloffs"] = stacked;
    return JSONValue(out_);
}

private JSONValue readState() {
    auto pipe = stageState();
    const context = getJson("/api/input/context");
    const selection = getJson("/api/selection");
    const model = getJson("/api/model");
    const undoStatus = getJson("/api/undo/status");
    const history = getJson("/api/history");

    JSONValue[string] sel;
    sel["vertex"] = cast(long) selection["selectedVertices"].array.length;
    sel["edge"] = cast(long) selection["selectedEdges"].array.length;
    sel["polygon"] = cast(long) selection["selectedFaces"].array.length;
    long selectedItems;
    foreach (item; selection["items"].array)
        if (item["selected"].type == JSONType.true_) ++selectedItems;
    sel["items"] = selectedItems;

    JSONValue[string] mesh;
    mesh["v"] = cast(long) model["vertices"].array.length;
    mesh["e"] = cast(long) model["edges"].array.length;
    mesh["f"] = cast(long) model["faces"].array.length;

    double minX = double.infinity, maxX = -double.infinity;
    foreach (v; model["vertices"].array) {
        const x = v.array[0].floating;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
    }

    JSONValue[string] out_ = pipe.object;
    out_["tool"] = context["tool"];
    out_["mode"] = context["mode"];
    out_["sel"] = JSONValue(sel);
    out_["mesh"] = JSONValue(mesh);
    out_["modelDepth"] = undoStatus["modelDepth"];
    out_["uiDepth"] = undoStatus["uiDepth"];
    out_["toolLifecycleCount"] = undoStatus["toolLifecycleCount"];
    out_["undo"] = cast(long) history["undo"].array.length;
    out_["redo"] = cast(long) history["redo"].array.length;
    out_["xExtent"] = JSONValue([JSONValue(minX), JSONValue(maxX)]);
    return JSONValue(out_);
}

private JSONValue historyState() {
    const state = readState();
    JSONValue[string] out_;
    foreach (key_; ["modelDepth", "uiDepth", "toolLifecycleCount", "undo", "redo"])
        out_[key_] = state[key_];
    return JSONValue(out_);
}

private struct Mismatch { string cell, key, kind, want, got; }

private size_t leafCount(JSONValue value) {
    if (value.type == JSONType.object) {
        size_t count;
        foreach (_, child; value.object) count += leafCount(child);
        return count;
    }
    if (value.type == JSONType.array) {
        size_t count;
        foreach (child; value.array) count += leafCount(child);
        return count;
    }
    return 1;
}

private string effectiveKind(string base, string id, string path,
                             JSONValue keyKinds) {
    auto key_ = path;
    if (key_.startsWith("rig.")) key_ = key_[4 .. $];
    if (keyKinds.type == JSONType.object) {
        auto found = key_ in keyKinds.object;
        if (found !is null) return found.str;
    }
    if (id == "E5ls" && (key_ == "modelDepth" || key_ == "hist.modelDepth"))
        return "census";
    return base;
}

private bool valuesEqual(JSONValue want, JSONValue got) {
    if ((want.type == JSONType.float_ || want.type == JSONType.integer)
        && (got.type == JSONType.float_ || got.type == JSONType.integer))
        return approxEqual(want.type == JSONType.integer
                ? cast(double) want.integer : want.floating,
            got.type == JSONType.integer ? cast(double) got.integer : got.floating,
            1e-9, 1e-9);
    return want == got;
}

private void compareExpected(string id, string kind, JSONValue want,
                             JSONValue got, ref Mismatch[] rows,
                             ref size_t comparedLeaves, string prefix = "",
                             JSONValue keyKinds = JSONValue.init) {
    if (want.type == JSONType.object) {
        if (got.type != JSONType.object) {
            comparedLeaves += leafCount(want);
            rows ~= Mismatch(id, prefix, effectiveKind(kind, id, prefix, keyKinds),
                want.toString, got.toString);
            return;
        }
        foreach (key_, value; want.object) {
            const path = prefix.length ? prefix ~ "." ~ key_ : key_;
            auto found = key_ in got.object;
            if (found is null) {
                comparedLeaves += leafCount(value);
                rows ~= Mismatch(id, path, effectiveKind(kind, id, path, keyKinds),
                    value.toString, "<missing>");
            } else compareExpected(id, kind, value, *found, rows,
                comparedLeaves, path, keyKinds);
        }
        return;
    }
    if (want.type == JSONType.array) {
        if (got.type != JSONType.array || got.array.length != want.array.length) {
            comparedLeaves += leafCount(want);
            rows ~= Mismatch(id, prefix, effectiveKind(kind, id, prefix, keyKinds),
                want.toString, got.toString);
            return;
        }
        foreach (i, value; want.array)
            compareExpected(id, kind, value, got.array[i], rows, comparedLeaves,
                format("%s[%s]", prefix, i), keyKinds);
        return;
    }
    ++comparedLeaves;
    if (!valuesEqual(want, got))
        rows ~= Mismatch(id, prefix, effectiveKind(kind, id, prefix, keyKinds),
            want.toString, got.toString);
}

private void requireLadderState(string id, string label, JSONValue state) {
    foreach (key_; ["tool", "mode", "actionCenter", "axis", "falloff",
                    "constrain", "stackedFalloffs", "sel"])
        assert((key_ in state.object) !is null,
            format("%s %s lacks required ladder key %s", id, label, key_));
    foreach (key_; ["vertex", "edge", "polygon", "items"])
        assert((key_ in state["sel"].object) !is null,
            format("%s %s lacks required ladder key sel.%s", id, label, key_));
}

private void rigSelectionFloor(string id, JSONValue cell, JSONValue rig) {
    foreach (step; cell["rig"].array) {
        if (!step.str.startsWith("select.element ")) continue;
        auto rest = step.str["select.element ".length .. $];
        const split = rest.indexOf(' ');
        assert(split > 0, id ~ ": malformed select.element rig step");
        const type = rest[0 .. cast(size_t) split];
        assert(rig["sel"][type].integer > 0,
            format("%s: rig selected %s but the read count is zero", id, type));
    }
}

unittest {
    auto fx = fixture();
    immutable expectedIds = ["C1/escape", "C6g/escape", "X2/escape", "E1",
        "E2", "E2a", "E2x", "E2f", "E2c", "E2s", "E3v", "E3p", "E5ls",
        "E5pen2/escape", "E6t", "E6n", "E7a", "E7b", "EB", "EB2",
        "U1inv/escape"];
    string[] executed;
    size_t escapePresses, spacePresses, expectedLeaves, comparedLeaves;
    size_t[string] rungCounts;
    Mismatch[] mismatches;

    foreach (cell; fx["cells"].array) {
        if (cell["file"].str != "escape") continue;
        const id = cell["id"].str;
        const kind = cell["kind"].str;
        assert(cell["port_status"].str == "implemented",
            id ~ ": Phase-6 escape cell is not implemented");
        executed ~= id;
        JSONValue keyKinds;
        if (("key_kinds" in cell.object) !is null) {
            keyKinds = cell["key_kinds"];
            foreach (key_, _; keyKinds.object)
                assert(["tool", "mode", "actionCenter", "axis", "falloff",
                        "constrain", "stackedFalloffs", "sel.vertex", "sel.edge",
                        "sel.polygon", "sel.items"].canFind(key_),
                    id ~ ": key_kinds names a non-ladder key " ~ key_);
        }

        cmd("scene.reset");
        // The undo LENGTH is capped (CommandHistory.maxDepth 50) and a reset
        // does not clear it, so each cell starts from an empty history: a
        // saturated stack would trim a stray entry and hide it.
        cmd("history.clear");
        cmd("select.typeFrom polygon");
        foreach (step; cell["rig"].array) cmd(step.str);
        if (cell["arm"].type != JSONType.null_) cmd("tool.set " ~ cell["arm"].str ~ " on");
        if (("clicks" in cell.object) !is null)
            foreach (point; cell["clicks"].array)
                click(cast(int) point.array[0].integer, cast(int) point.array[1].integer);
        if (("whileArmed" in cell.object) !is null)
            foreach (step; cell["whileArmed"].array) cmd(step.str);

        const rig = readState();
        requireLadderState(id, "rig", cell["expect"]["rig"]);
        rigSelectionFloor(id, cell, rig);
        compareExpected(id, kind, cell["expect"]["rig"], rig, mismatches,
            comparedLeaves, "rig", keyKinds);
        expectedLeaves += leafCount(cell["expect"]["rig"]);

        foreach (i, press; cell["presses"].array) {
            requireLadderState(id, format("press %s", i + 1), press["after"]);
            assert(("historyDelta" in press.object) !is null,
                format("%s press %s lacks measured historyDelta", id, i + 1));
            const beforeHistory = historyState();
            assert(beforeHistory["undo"].integer + 2 <= 50,
                format("%s press %s: undo stack at %s leaves no headroom under the cap",
                    id, i + 1, beforeHistory["undo"].integer));
            key(press["key"].str);
            const after = readState();
            compareExpected(id, kind, press["after"], after, mismatches,
                comparedLeaves, "", keyKinds);
            expectedLeaves += leafCount(press["after"]);

            const wantedHistory = applyHistoryDelta(
                format("%s press %s", id, i + 1), beforeHistory,
                press["historyDelta"]);
            compareExpected(id, kind, wantedHistory, historyState(), mismatches,
                comparedLeaves, "hist", keyKinds);
            expectedLeaves += leafCount(wantedHistory);
            if (press["key"].str == "escape") ++escapePresses;
            else ++spacePresses;
            if (press["rung"].type != JSONType.null_) ++rungCounts[press["rung"].str];
        }

        if (("trajectory" in cell.object) !is null) {
            immutable labels = ["afterToggle", "afterUndo1", "afterUndo2"];
            assert(cell["trajectory"].array.length == labels.length,
                id ~ ": trajectory length drifted");
            foreach (i, step; cell["trajectory"].array) {
                if (step.str == "undo") ctrlZ(); else cmd(step.str);
                const want = cell["expect"][labels[i]];
                compareExpected(id, kind, want, readState(), mismatches,
                    comparedLeaves, labels[i], keyKinds);
                expectedLeaves += leafCount(want);
            }
        }
    }

    assert(executed == expectedIds,
        format("escape ids drifted: got %s expected %s", executed, expectedIds));
    assert(escapePresses == 31 && spacePresses == 7,
        format("escape ladder press census: Esc=%s Space=%s, expected 31/7",
            escapePresses, spacePresses));
    foreach (rung; ["dropTool", "clearPipe", "dropCurrentType", "dropItems", "nothing"])
        assert(rungCounts[rung] >= 1, "no executed press for rung " ~ rung);
    // A measured population literal, not an identity: `compareExpected` adds
    // leafCount(want) on every branch, so compared == expected always holds.
    // Deleting a fixture key (e.g. E2's `snap`, M18's only witness) moves this.
    assert(expectedLeaves == 876,
        format("escape comparison population changed: %s leaves, expected 876",
            expectedLeaves));
    assert(comparedLeaves == expectedLeaves && comparedLeaves > 0,
        format("escape comparison leaf floor: compared %s expected %s",
            comparedLeaves, expectedLeaves));

    auto table = appender!string;
    table.put("cell | key | kind | want | got\n");
    foreach (row; mismatches)
        table.put(format("%s | %s | %s | %s | %s\n",
            row.cell, row.key, row.kind, row.want, row.got));
    assert(mismatches.length == 0, table.data);
}
