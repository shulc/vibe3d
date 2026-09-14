// Preset-owned pipe stages must disappear through the production drop doors,
// while user-owned stages and the snap toggle survive (task 5911, Phase 2).
module test_tool_drop_pipe_stages;

import drag_helpers : buildDragLog, playAndWait;
import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.algorithm : sort;
import std.array : appender;
import std.format : format;
import std.json;
import std.string : indexOf, join, startsWith;
import core.thread : Thread;
import core.time : dur;

void main() {}

private JSONValue fixture() {
    static JSONValue cached;
    if (cached.type == JSONType.null_)
        cached = parseJSON(import("fixtures/tool_drop_pipe_stages.json"));
    return cached;
}

private void settle() { Thread.sleep(dur!"msecs"(150)); }

private void cmd(string text) {
    const body = text.indexOf(' ') < 0 ? commandBody(text) : text;
    auto answer = postJson("/api/command", body);
    assert(answer["status"].str == "ok",
        format("command `%s` failed: %s", text, answer.toString));
    settle();
}

private JSONValue stageState() {
    JSONValue[string] out_;
    out_["actionCenter"] = "<missing>";
    out_["axis"] = "<missing>";
    out_["falloff"] = "<missing>";
    out_["snap"] = "<missing>";
    out_["constrain"] = "<missing>";
    long stacked;
    foreach (stage; getJson("/api/toolpipe")["stages"].array) {
        const id = stage["id"].str;
        const task = stage["task"].str;
        if (id == "actionCenter") out_["actionCenter"] = stage["attrs"]["mode"];
        else if (id == "axis") out_["axis"] = stage["attrs"]["mode"];
        else if (id == "falloff") out_["falloff"] = stage["attrs"]["type"];
        else if (id == "snap") out_["snap"] = stage["attrs"]["enabled"];
        else if (id == "constrain") out_["constrain"] = stage["attrs"]["enabled"];
        if (task == "WGHT" && id != "falloff") ++stacked;
    }
    out_["stackedFalloffs"] = stacked;
    return JSONValue(out_);
}

private JSONValue falloffAttrState() {
    foreach (stage; getJson("/api/toolpipe")["stages"].array) {
        if (stage["id"].str != "falloff") continue;
        assert(stage["attrs"].type == JSONType.object &&
               stage["attrs"].object.length > 0,
            "falloff attr read must be a populated object");
        return stage["attrs"];
    }
    assert(false, "falloff stage missing from /api/toolpipe");
}

private JSONValue readState() {
    auto pipe = stageState();
    auto context = getJson("/api/input/context");
    auto selection = getJson("/api/selection");
    auto model = getJson("/api/model");
    auto undoStatus = getJson("/api/undo/status");
    auto history = getJson("/api/history");

    JSONValue[string] sel;
    sel["vertex"] = cast(long)selection["selectedVertices"].array.length;
    sel["edge"] = cast(long)selection["selectedEdges"].array.length;
    sel["polygon"] = cast(long)selection["selectedFaces"].array.length;

    JSONValue[string] mesh;
    mesh["v"] = cast(long)model["vertices"].array.length;
    mesh["e"] = cast(long)model["edges"].array.length;
    mesh["f"] = cast(long)model["faces"].array.length;

    JSONValue[string] out_ = pipe.object;
    out_["tool"] = context["tool"];
    out_["mode"] = context["mode"];
    out_["sel"] = JSONValue(sel);
    out_["mesh"] = JSONValue(mesh);
    out_["modelDepth"] = undoStatus["modelDepth"];
    out_["uiDepth"] = undoStatus["uiDepth"];
    out_["toolLifecycleCount"] = undoStatus["toolLifecycleCount"];
    out_["undo"] = cast(long)history["undo"].array.length;
    out_["redo"] = cast(long)history["redo"].array.length;
    return JSONValue(out_);
}

private JSONValue historyState() {
    auto s = readState();
    JSONValue[string] out_;
    foreach (key; ["modelDepth", "uiDepth", "toolLifecycleCount", "undo", "redo"])
        out_[key] = s[key];
    return JSONValue(out_);
}

private struct Mismatch {
    string cell, key, kind, want, got;
}

private size_t leafCount(JSONValue value) {
    if (value.type == JSONType.object) {
        size_t count;
        foreach (_, child; value.object) count += leafCount(child);
        return count;
    }
    return 1;
}

private bool startsWithPlaceholder(JSONValue value) {
    if (value.type == JSONType.string)
        return value.str.startsWith("<");
    if (value.type == JSONType.object) {
        foreach (_, child; value.object)
            if (startsWithPlaceholder(child)) return true;
    } else if (value.type == JSONType.array) {
        foreach (child; value.array)
            if (startsWithPlaceholder(child)) return true;
    }
    return false;
}

private void compareExpected(string cell, string kind, JSONValue want,
                             JSONValue got, ref Mismatch[] rows,
                             ref size_t comparedLeaves,
                             string prefix = "") {
    if (want.type == JSONType.object) {
        if (got.type != JSONType.object) {
            comparedLeaves += leafCount(want);
            rows ~= Mismatch(cell, prefix, kind, want.toString, got.toString);
            return;
        }
        foreach (key, value; want.object) {
            const path = prefix.length ? prefix ~ "." ~ key : key;
            auto found = key in got.object;
            if (found is null) {
                comparedLeaves += leafCount(value);
                rows ~= Mismatch(cell, path, kind, value.toString, "<missing>");
                continue;
            }
            compareExpected(cell, kind, value, *found, rows,
                comparedLeaves, path);
        }
        return;
    }
    ++comparedLeaves;
    if (want != got)
        rows ~= Mismatch(cell, prefix, kind, want.toString, got.toString);
}

private void assertExpected(string cell, string label, JSONValue want,
                            JSONValue got) {
    Mismatch[] rows;
    size_t comparedLeaves;
    compareExpected(cell, "floor", want, got, rows, comparedLeaves);
    if (rows.length == 0) return;
    auto text = appender!string;
    foreach (r; rows)
        text.put(format("%s %s %s: want %s got %s\n",
            r.cell, label, r.key, r.want, r.got));
    assert(false, text.data);
}

private void compareFalloffAttrs(string cell, string kind, JSONValue want,
                                 JSONValue got, ref Mismatch[] rows) {
    foreach (key, value; want.object) {
        auto found = key in got.object;
        if (found is null)
            rows ~= Mismatch(cell, key, kind, value.toString, "<missing>");
        else if (value != *found)
            rows ~= Mismatch(cell, key, kind, value.toString, (*found).toString);
    }
    foreach (key, value; got.object)
        if ((key in want.object) is null)
            rows ~= Mismatch(cell, key, kind, "<missing>", value.toString);
}

private void assertFalloffGeometryFloor(string cell, string label,
                                        JSONValue attrs, JSONValue keys) {
    assert(attrs.type == JSONType.object && attrs.object.length > 0,
        cell ~ ": " ~ label ~ " falloff attrs must be non-empty");
    assert(keys.type == JSONType.array && keys.array.length > 0,
        cell ~ ": fixture must name falloff geometry keys");
    foreach (key; keys.array)
        assert((key.str in attrs.object) !is null,
            cell ~ ": " ~ label ~ " falloff attrs omitted geometry key " ~ key.str);
}

private void key(int sym, int scan, int mod = 0) {
    const log =
        `{"t":0.000,"type":"VIEWPORT","vpX":150,"vpY":28,"vpW":650,"vpH":544,"fovY":0.785398}` ~ "\n" ~
        format(`{"t":50.000,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":%d,"repeat":0}`, sym, scan, mod) ~ "\n" ~
        format(`{"t":100.000,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":%d,"repeat":0}`, sym, scan, mod) ~ "\n";
    playAndWait(log);
    settle();
}

private void runDoor(JSONValue cell) {
    const door = cell["door"].str;
    if (door == "space") key(32, 44);
    else if (door == "q") key(113, 20);
    else if (door == "off") {
        const id = "off" in cell.object ? cell["off"].str : cell["arm"].str;
        cmd("tool.set " ~ id ~ " off");
    } else if (door == "switch") {
        cmd("tool.set " ~ cell["switch"].str ~ " on");
    } else assert(false, "unsupported Phase-2 door: " ~ door);
}

private bool hasNonDefaultPipe(JSONValue s) {
    return s["actionCenter"].str != "none" || s["axis"].str != "none" ||
           s["falloff"].str != "none" || s["snap"].str == "true";
}

private string vertexImage() { return getJson("/api/model")["vertices"].toString; }

private double[2] xExtent() {
    auto verts = getJson("/api/model")["vertices"].array;
    assert(verts.length > 0, "x-extent requires a populated mesh");
    double lo = double.max, hi = -double.max;
    foreach (v; verts) {
        const x = v.array[0].floating;
        if (x < lo) lo = x;
        if (x > hi) hi = x;
    }
    return [lo, hi];
}

unittest {
    const fx = fixture();
    assert(fx["cells"].array.length == 68,
        format("fixture cell census changed: %s", fx["cells"].array.length));

    foreach (cell; fx["cells"].array) {
        const hasPending = ("pending_capture" in cell.object) !is null;
        assert(hasPending ||
               (("rig" in cell.object) !is null &&
                ("expect" in cell.object) !is null),
            cell["id"].str ~ ": fixture cell needs rig+expect or pending_capture");
        if (cell["port_status"].str == "implemented")
            assert(!hasPending,
                cell["id"].str ~ ": implemented cell has pending_capture");
        assert(!startsWithPlaceholder(cell),
            cell["id"].str ~ ": fixture value starts with '<'");
    }

    JSONValue[string] synthetic;
    synthetic["noSuchKey"] = "x";
    Mismatch[] selfCheck;
    size_t selfCheckLeaves;
    compareExpected("SELF", "control", JSONValue(synthetic), readState(),
        selfCheck, selfCheckLeaves);
    assert(selfCheck.length == 1 && selfCheck[0].key == "noSuchKey" &&
           selfCheck[0].got == "<missing>" && selfCheckLeaves == 1,
        "comparison self-check must report one missing-key mismatch");

    string[] expectedIds = [
        "C0/space", "C0/off", "C1/space", "C1/off", "C1/switch",
        "C2/space", "C2/off", "C3/space", "C3/off", "C4/space", "C4/off",
        "C4g/space", "C3g/space",
        "C8/space", "G1/space", "G3/space", "C6g/space", "C6g/off",
        "C6g/switch", "X2/space", "X2off/space", "U1inv/space",
        "S_vert/space", "S_edge/space",
        "C0/q", "C1/q", "C6g/q", "X2/q", "X2off/q", "U1inv/q",
    ];
    string[] executed;
    size_t comparedLeaves, expectedLeaves;
    Mismatch[] mismatches;

    foreach (cell; fx["cells"].array) {
        if (cell["file"].str != "drop" || cell["phase"].integer > 2 ||
            cell["port_status"].str != "implemented") continue;
        const id = cell["id"].str;
        const kind = cell["kind"].str;
        const geometryRearm = ("geometryKeys" in cell.object) !is null;
        const rowsBefore = mismatches.length;
        executed ~= id;

        cmd("scene.reset");
        cmd("select.typeFrom polygon");
        foreach (step; cell["rig"].array) cmd(step.str);
        auto rig = readState();
        assertExpected(id, "rig", cell["expect"]["rig"], rig);
        JSONValue rigAttrs;
        if (geometryRearm) {
            rigAttrs = falloffAttrState();
            assertFalloffGeometryFloor(id, "rig", rigAttrs, cell["geometryKeys"]);
            assertExpected(id, "rig attrs", cell["expect"]["rigAttrs"], rigAttrs);
            assert(cell["excludedAttrs"].array.length == 0,
                id ~ ": REVISION 4e excludes no falloff attrs");
        }

        JSONValue firstArmAttrs;
        if (cell["arm"].type != JSONType.null_) {
            cmd("tool.set " ~ cell["arm"].str ~ " on");
            auto armed = readState();
            assert(armed["tool"].str == cell["arm"].str,
                format("%s: arm did not take; want tool %s got %s",
                    id, cell["arm"].str, armed["tool"].str));
            if (geometryRearm) {
                firstArmAttrs = falloffAttrState();
                assertFalloffGeometryFloor(id, "first arm", firstArmAttrs,
                    cell["geometryKeys"]);
                foreach (key; cell["geometryKeys"].array) {
                    if (firstArmAttrs[key.str] == rigAttrs[key.str])
                        mismatches ~= Mismatch(id, key.str, kind,
                            "a clean non-user value", firstArmAttrs[key.str].toString);
                }
            } else {
                compareExpected(id, kind, cell["expect"]["armed"], armed,
                    mismatches, comparedLeaves, "armed");
                expectedLeaves += leafCount(cell["expect"]["armed"]);
            }
            if (kind != "control")
                assert(hasNonDefaultPipe(armed),
                    id ~ ": non-control arm has no non-default stage read");
        } else {
            assert(rig["tool"].str.length == 0,
                id ~ ": no-arm cell started with a tool");
        }

        if (cell["row"].str == "U1inv") {
            foreach (step; cell["whileArmed"].array) cmd(step.str);
            auto extent = xExtent();
            assert(extent[0] > -0.25001 && extent[0] < -0.24999 &&
                   extent[1] > 0.74999 && extent[1] < 0.75001,
                format("%s: panel edit premise x extent %s", id, extent));
        }
        if (id == "C8/space") {
            const beforeVerts = vertexImage();
            const beforeDepth = historyState()["modelDepth"].integer;
            const drag = cell["drag"].array;
            assert(drag.length == 9, id ~ ": drag must carry viewport and gesture fields");
            playAndWait(buildDragLog(
                cast(int)drag[0].integer, cast(int)drag[1].integer,
                cast(int)drag[2].integer, cast(int)drag[3].integer,
                cast(int)drag[4].integer, cast(int)drag[5].integer,
                cast(int)drag[6].integer, cast(int)drag[7].integer,
                cast(int)drag[8].integer));
            settle();
            assert(vertexImage() != beforeVerts,
                id ~ ": viewport drag did not change the vertex array");
            assert(historyState()["modelDepth"].integer == beforeDepth + 1,
                id ~ ": viewport drag did not add exactly one model-depth entry");
        }

        const beforeDoor = readState();
        const beforeHistory = historyState();
        const beforeTool = beforeDoor["tool"].str;
        if (cell["arm"].type == JSONType.null_)
            assert(beforeTool.length == 0, id ~ ": door premise expected no tool");
        else
            assert(beforeTool == cell["arm"].str,
                format("%s: before door want tool %s got %s",
                    id, cell["arm"].str, beforeTool));

        runDoor(cell);
        const afterDoor = readState();
        compareExpected(id, kind, cell["expect"]["after"], afterDoor,
            mismatches, comparedLeaves);
        expectedLeaves += leafCount(cell["expect"]["after"]);
        if (cell["row"].str == "U1inv") {
            auto afterHistory = historyState();
            JSONValue wantedHistory = beforeHistory;
            wantedHistory["modelDepth"] = beforeHistory["modelDepth"].integer + 1;
            // The rig clears the history (plan §8.1 step 7), so the
            // capped undo LENGTH cannot saturate and hide a missing entry.
            assert(beforeHistory["undo"].integer < 40,
                id ~ ": history.clear in the rig did not keep the undo stack short");
            wantedHistory["undo"] = beforeHistory["undo"].integer + 1;
            compareExpected(id, kind, wantedHistory, afterHistory, mismatches,
                comparedLeaves, "hist");
            expectedLeaves += leafCount(wantedHistory);
        } else if (cell["door"].str != "switch") {
            auto afterHistory = historyState();
            compareExpected(id, kind, beforeHistory, afterHistory, mismatches,
                comparedLeaves, "hist");
            expectedLeaves += leafCount(beforeHistory);
        }

        if (geometryRearm) {
            cmd("tool.set " ~ cell["arm"].str ~ " on");
            auto secondArmAttrs = falloffAttrState();
            assertFalloffGeometryFloor(id, "second arm", secondArmAttrs,
                cell["geometryKeys"]);
            compareFalloffAttrs(id, kind, secondArmAttrs, firstArmAttrs,
                mismatches);
            cmd("tool.set " ~ cell["arm"].str ~ " off");
        }

        JSONValue afterSecond;
        if ("after2" in cell["expect"].object) {
            key(32, 44);
            afterSecond = readState();
            compareExpected(id, kind, cell["expect"]["after2"], afterSecond,
                mismatches, comparedLeaves);
            expectedLeaves += leafCount(cell["expect"]["after2"]);
        }

        if (cell["row"].str == "U1inv") {
            const labels = ["afterToggle", "afterUndo1", "afterUndo2"];
            const trajectory = cell["trajectory"].array;
            assert(trajectory.length == labels.length,
                id ~ ": trajectory and expected-state labels differ");
            foreach (i, step; trajectory) {
                if (step.str == "undo") key(122, 29, 64);
                else cmd(step.str);
                auto state = readState();
                compareExpected(id, kind, cell["expect"][labels[i]], state,
                    mismatches, comparedLeaves, labels[i]);
                expectedLeaves += leafCount(cell["expect"][labels[i]]);
                if (labels[i] == "afterUndo1") {
                    auto extent = xExtent();
                    if (!(extent[0] > -0.50001 && extent[0] < -0.49999 &&
                          extent[1] > 0.49999 && extent[1] < 0.50001))
                        mismatches ~= Mismatch(id, "afterUndo1.xExtent", kind,
                            "[-0.5,0.5]", format("%s", extent));
                }
            }
        }

        import std.stdio : writeln;
        const addedRows = mismatches.length - rowsBefore;
        writeln("CELL ", id,
            addedRows == 0 ? " PASS" : format(" MISMATCH (%s rows)", addedRows),
            " before=", beforeDoor.toString,
            " after=", afterDoor.toString,
            afterSecond.type == JSONType.null_ ? "" : " after2=" ~ afterSecond.toString);
    }

    auto gotIds = executed.dup;
    auto wantIds = expectedIds.dup;
    gotIds.sort;
    wantIds.sort;
    assert(gotIds == wantIds,
        format("Phase-2 id floor failed: want %s got %s",
            wantIds.join(","), gotIds.join(",")));
    assert(executed.length == 30, format("executed %s Phase-2 cells", executed.length));
    assert(comparedLeaves == expectedLeaves && comparedLeaves > 0,
        format("comparison leaf floor: compared=%s expected=%s",
            comparedLeaves, expectedLeaves));
    foreach (cell; fx["cells"].array)
        if (cell["file"].str == "drop" && cell["phase"].integer <= 2 &&
            cell["port_status"].str == "implemented")
            assert(cell["expect"]["after"].object.length > 0,
                cell["id"].str ~ ": implemented after is empty");

    if (mismatches.length) {
        auto table = appender!string;
        foreach (r; mismatches)
            table.put(format("%s | %s | %s | want %s | got %s\n",
                r.cell, r.key, r.kind, r.want, r.got));
        assert(false, table.data);
    }
}
