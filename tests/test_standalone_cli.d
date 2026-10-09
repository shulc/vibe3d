import http_client : getJson, postJson, postRawAllowingErrorStatus, quiesce;
import http_command_helpers : commandBody;
import std.algorithm : canFind;
import std.array : array, join;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.file : read, readText, write, exists, mkdirRecurse, rmdirRecurse,
    dirEntries, SpanMode, readLink, symlink;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : buildPath, dirName, baseName;
import std.process : execute, spawnProcess, wait, kill, tryWait, Pid, Config,
    environment, thisProcessID;
import std.stdio : File, stdin, writeln;
import std.string : split, strip, toLower;
import core.sys.posix.signal : SIGKILL;
import core.sys.posix.unistd : link;
import std.string : toStringz;

void main() {}

private enum repo = dirName(dirName(__FILE_FULL_PATH__));
private string binaryHash;
private string sourcePin;

private string digest(string path) { return read(path).sha256Of.toHexString.idup; }
private JSONValue[] jsonRows(string text) {
    JSONValue[] rows;
    foreach (line; text.split("\n")) if (line.strip.length) rows ~= parseJSON(line);
    return rows;
}
private void command(string id, string params = "") {
    auto row = postJson("/api/command", commandBody(id, params));
    assert(row["status"].str == "ok", "CLI desktop control command: " ~ row.toString);
}
private JSONValue cleanPlanes(JSONValue planes) {
    planes = parseJSON(planes.toString);
    planes.object.remove("provenance");
    return planes;
}
private JSONValue desktopState() {
    auto selection = getJson("/api/selection");
    auto planes = getJson("/api/mesh/planes");
    auto history = getJson("/api/history");
    auto depths = getJson("/api/undo/status");
    auto changes = getJson("/api/changes");
    bool target;
    foreach (item; selection["items"].array) target |= item["primary"].boolean;
    JSONValue state;
    state["hasEditTarget"] = target;
    auto type = selection["selType"].str;
    switch (type) {
        case "vertex": state["selType"] = "Vertex"; break;
        case "edge": state["selType"] = "Edge"; break;
        case "polygon": state["selType"] = "Polygon"; break;
        case "item": state["selType"] = "Item"; break;
        default: assert(false, "CLI differential: unknown desktop selection type " ~ type);
    }
    auto mode = selection["mode"].str;
    switch (mode) {
        case "vertices": state["editMode"] = "Vertices"; break;
        case "edges": state["editMode"] = "Edges"; break;
        case "polygons": state["editMode"] = "Polygons"; break;
        default: assert(false, "CLI differential: unknown desktop mode " ~ mode);
    }
    state["planes"] = cleanPlanes(planes);
    JSONValue projectedHistory;
    foreach (stack; ["undo", "redo"]) {
        JSONValue[] rows;
        foreach (entry; history[stack].array) {
            JSONValue row;
            foreach (key; ["command", "label", "args", "flags", "runId", "tweakGen"])
                row[key] = entry[key];
            rows ~= row;
        }
        projectedHistory[stack] = JSONValue(rows);
    }
    projectedHistory["modelDepth"] = depths["modelDepth"];
    projectedHistory["uiDepth"] = depths["uiDepth"];
    state["history"] = projectedHistory;
    JSONValue projectedChanges;
    foreach (key; ["deliveryCount", "lastDeliveryFlags", "lastDeliverySelDomains"])
        projectedChanges[key] = changes[key];
    state["changes"] = projectedChanges;
    // The selection endpoint is an independent reader of the same marks.
    foreach (pair; [["selectedVertices", "vertexMarks"], ["selectedEdges", "edgePlanes"],
                   ["selectedFaces", "faceMarks"]]) {
        size_t count;
        foreach (raw; planes[pair[1]].array) {
            auto mark = pair[1] == "edgePlanes" ? raw["marks"] : raw;
            if ((mark.integer & 1) != 0) ++count;
        }
        assert(selection[pair[0]].array.length == count,
            "CLI differential: desktop selection reader disagrees with planes " ~ pair[0]);
    }
    return state;
}
private void parity(JSONValue cli, JSONValue desktop, JSONValue previousCli, JSONValue previousDesktop) {
    assert(cli.object.length == 6, "CLI state: exact six-key schema");
    foreach (key; ["hasEditTarget", "selType", "editMode", "planes", "history", "changes"])
        assert(key in cli.object, "CLI state: required schema key " ~ key);
    auto cliPlanes = cleanPlanes(cli["planes"]);
    foreach (key, value; cliPlanes.object)
        assert(key in desktop["planes"].object && value == desktop["planes"][key],
            "CLI differential: plane " ~ key ~ " mismatch cli=" ~ value.toString
                ~ " desktop=" ~ desktop["planes"][key].toString);
    assert(cliPlanes == desktop["planes"], "CLI differential: complete plane mismatch");
    foreach (key; ["hasEditTarget", "selType", "editMode", "history"])
        assert(cli[key] == desktop[key], "CLI differential: state mismatch " ~ key
            ~ " cli=" ~ cli[key].toString ~ " desktop=" ~ desktop[key].toString);
    foreach (key; ["lastDeliveryFlags", "lastDeliverySelDomains"])
        assert(cli["changes"][key] == desktop["changes"][key],
            "CLI differential: delivery gauge mismatch " ~ key);
    if (previousCli.type != JSONType.null_) {
        auto cliDelta = cli["changes"]["deliveryCount"].integer - previousCli["changes"]["deliveryCount"].integer;
        auto desktopDelta = desktop["changes"]["deliveryCount"].integer - previousDesktop["changes"]["deliveryCount"].integer;
        assert(cliDelta == desktopDelta, "CLI differential: command delivery delta mismatch");
    }
}

private struct Run { int status; JSONValue[] states, outcomes; string error; }
private Run runCli(string root, string input, string script, string output, string diagnostics = "", bool observeProcess = false) {
    auto outLog = buildPath(root, "stdout.jsonl"), errLog = buildPath(root, "stderr.log");
    auto outFile = File(outLog, "w"), errFile = File(errLog, "w");
    string[] argv = [buildPath(repo, "tools/cli/vibe3d-cli"), "run", "--input", input,
        "--commands", script, "--output", output];
    if (diagnostics.length) argv ~= ["--state-output", diagnostics];
    auto env = environment.toAA;
    foreach (key; ["DISPLAY", "WAYLAND_DISPLAY", "SDL_VIDEODRIVER"]) env.remove(key);
    auto pid = spawnProcess(argv, stdin, outFile, errFile, env, Config.newEnv, repo);
    bool reaped;
    void stopOwned() {
        if (!reaped) {
            try { kill(pid, SIGKILL); } catch (Exception) {}
            try { wait(pid); } catch (Exception) {}
        }
    }
    scope(exit) stopOwned();
    if (observeProcess) {
        auto proc = "/proc/" ~ pid.processID.to!string;
        assert(readLink(proc ~ "/exe") == argv[0], "CLI process: actual executable is current checkout");
        assert(digest(proc ~ "/exe") == binaryHash, "CLI process: actual executable hash equals fresh binary");
        auto mappings = readText(proc ~ "/maps");
        assert(mappings.length > 100 && mappings.canFind("libc.so"), "CLI process: populated live mappings");
        foreach (name; ["sdl", "libgl", "libegl", "imgui", "libx11", "nfde", "libxcb", "wayland"])
            assert(!mappings.toLower.canFind(name), "CLI process: forbidden mapping " ~ name);
        auto liveEnvironment = readText(proc ~ "/environ");
        foreach (key; ["DISPLAY=", "WAYLAND_DISPLAY=", "SDL_VIDEODRIVER="])
            assert(!liveEnvironment.canFind(key), "CLI process: display variable inherited " ~ key);
        auto cmdline = readText(proc ~ "/cmdline");
        assert(cmdline.canFind("--state-output") && cmdline.canFind(script), "CLI process: real diagnostic argv");
        writeln("CLI-PROCESS source=", sourcePin, " binary-sha256=", binaryHash,
            " exe=", readLink(proc ~ "/exe"), " maps-bytes=", mappings.length, " display=unset");
    }
    Run result;
    result.status = wait(pid); reaped = true;
    outFile.close(); errFile.close();
    result.outcomes = jsonRows(readText(outLog)); result.error = readText(errLog);
    if (diagnostics.length && exists(diagnostics)) result.states = jsonRows(readText(diagnostics));
    assert(digest(argv[0]) == binaryHash, "CLI process: binary stable throughout run");
    return result;
}
private void noOrphan(string root) {
    foreach (entry; dirEntries(root, SpanMode.shallow))
        assert(!baseName(entry.name).canFind(".vibe3d-cli-"), "CLI transaction: no owned temporary orphan");
}

private void loadDesktop(string input) {
    command("scene.reset");
    command("file.load", JSONValue(["path": JSONValue(input)]).toString);
    command("history.clear");
    quiesce();
}
private JSONValue fixture(string root) {
    command("scene.reset");
    auto seed = buildPath(root, "seed.v3d");
    command("file.save", JSONValue(["path": JSONValue(seed)]).toString);
    auto doc = parseJSON(readText(seed));
    auto mesh = &doc["layers"][0]["mesh"];
    assert((*mesh)["vertices"].array.length == 8 && (*mesh)["faces"].array.length == 6,
        "CLI fixture: nonempty production cube population");
    JSONValue weight; weight["name"] = "weight";
    JSONValue[] weights; foreach (i; 0 .. 8) weights ~= JSONValue(cast(double)(i + 1) / 8);
    weight["data"] = JSONValue(weights); (*mesh)["weightMaps"] = JSONValue([weight]);
    JSONValue uv; uv["name"] = "uv"; uv["dim"] = 2;
    JSONValue[] corners; foreach (i; 0 .. 48) corners ~= JSONValue(cast(double)(i + 1) / 64);
    uv["data"] = JSONValue(corners); (*mesh)["uvMaps"] = JSONValue([uv]);
    auto other = parseJSON(doc["layers"][0].toString);
    other["selected"] = false; other["channels"]["name"] = "other";
    doc["layers"].array ~= other;
    return doc;
}

private Run differential(string root, JSONValue doc, string[] scriptRows, bool success, string[] outcomes) {
    auto input = buildPath(root, "input.v3d"), script = buildPath(root, "script.jsonl");
    auto output = buildPath(root, "output.v3d"), diagnostics = buildPath(root, "state.jsonl");
    write(input, doc.toString); write(script, scriptRows.join("\n") ~ "\n");
    write(output, "sentinel");
    auto result = runCli(root, input, script, output, diagnostics);
    assert(result.status == (success ? 0 : 1), "CLI status: " ~ result.error);
    assert(result.states.length == outcomes.length + (success ? 2 : 1),
        "CLI state: loaded + every invocation/error + optional pre-save population");
    assert(result.states[0]["phase"].str == "loaded" && result.states[0]["line"].integer == 0
        && result.states[0]["id"].type == JSONType.null_ && result.states[0]["outcome"].type == JSONType.null_,
        "CLI state: exact loaded timing/schema");
    loadDesktop(input);
    auto previousDesktop = desktopState(), previousCli = result.states[0]["state"];
    parity(previousCli, previousDesktop, JSONValue.init, JSONValue.init);
    size_t step, stdoutStep;
    foreach (offset, row; scriptRows) {
        if (!row.strip.length) continue;
        auto actual = result.states[step + 1];
        assert(actual["line"].integer == offset + 1, "CLI state: physical JSONL line number");
        assert(actual.object.length == 5, "CLI state: exact row schema");
        JSONValue commandRow;
        bool valid;
        try { commandRow = parseJSON(row); valid = commandRow.type == JSONType.object; } catch (Exception) {}
        auto expected = outcomes[step];
        if (expected == "error") {
            assert(actual["phase"].str == "error" && actual["outcome"].type == JSONType.null_,
                "CLI state: malformed/unknown error row");
            assert(actual["state"] == previousCli, "CLI error: complete state preservation");
        } else {
            assert(valid && actual["phase"].str == "command"
                && actual["id"] == commandRow["id"] && actual["outcome"].str == expected,
                "CLI state: exact command roster/outcome/timing");
            assert(stdoutStep < result.outcomes.length, "CLI stdout: command outcome row present");
            auto printed = result.outcomes[stdoutStep++];
            assert(printed.object.length == 3 && printed["line"] == actual["line"]
                && printed["id"] == actual["id"] && printed["outcome"] == actual["outcome"],
                "CLI stdout: exact physical line/id/outcome schema");
            auto response = parseJSON(postRawAllowingErrorStatus("/api/command", row));
            assert(response["status"].str == (expected == "refused" ? "error" : "ok"),
                "CLI differential: actual HTTP refusal/status contract");
            auto nextDesktop = desktopState();
            parity(actual["state"], nextDesktop, previousCli, previousDesktop);
            previousDesktop = nextDesktop;
        }
        previousCli = actual["state"];
        ++step;
        if (expected == "refused" || expected == "error") break;
    }
    assert(stdoutStep == result.outcomes.length, "CLI stdout: no extra or error outcome rows");
    assert(step == outcomes.length, "CLI state: all expected physical rows observed");
    if (success) {
        assert(result.error.strip.length == 0, "CLI stderr: successful run has no error");
        auto last = result.states[$ - 1];
        assert(last["phase"].str == "pre-save" && last["line"].type == JSONType.null_
            && last["id"].type == JSONType.null_ && last["outcome"].type == JSONType.null_
            && last["state"] == previousCli, "CLI state: pre-save exact unchanged observation");
        auto desktopOutput = buildPath(root, "desktop.v3d");
        command("file.save", JSONValue(["path": JSONValue(desktopOutput)]).toString);
        assert(parseJSON(readText(output)) == parseJSON(readText(desktopOutput)),
            "CLI reopen: complete authored geometry/maps/layers match desktop production save");
        loadDesktop(output);
        assert(getJson("/api/model")["faces"].array.length > 0, "CLI reopen: nonempty native output loaded");
    } else {
        auto errors = jsonRows(result.error);
        assert(errors.length == 1 && errors[0].object.length == 4
            && errors[0]["error"].type == JSONType.string && errors[0]["error"].str.length > 0
            && errors[0]["line"] == result.states[$ - 1]["line"]
            && errors[0]["id"] == result.states[$ - 1]["id"], "CLI stderr: exact JSON error schema/physical line/id");
        assert(errors[0]["stage"].str == (outcomes[$ - 1] == "refused" ? "refused" :
            (result.states[$ - 1]["id"].type == JSONType.null_ ? "script" : "command")),
            "CLI stderr: parser/command/refused distinct diagnostic stage");
        assert(readText(output) == "sentinel", "CLI transaction: failed run preserves existing output sentinel");
    }
    noOrphan(root);
    return result;
}

unittest {
    import std.array : join;
    // Build once from this exact checkout, never reuse a stale helper binary.
    auto build = execute(["dub", "build", "--root=" ~ buildPath(repo, "tools/cli"), "--compiler=dmd"], null, Config.none, size_t.max, repo);
    assert(build.status == 0, "CLI fresh build: " ~ build.output);
    auto revision = execute(["git", "rev-parse", "HEAD"], null, Config.none, size_t.max, repo);
    sourcePin = revision.status == 0 ? revision.output.strip : "mutation-copy";
    binaryHash = digest(buildPath(repo, "tools/cli/vibe3d-cli"));
    auto dynamic = execute(["ldd", buildPath(repo, "tools/cli/vibe3d-cli")]);
    assert(dynamic.status == 0 && dynamic.output.length > 100, "CLI runtime: populated ldd witness");
    foreach (name; ["sdl", "libgl", "libegl", "imgui", "libx11", "nfde", "libxcb", "wayland"])
        assert(!dynamic.output.toLower.canFind(name), "CLI runtime: forbidden linked library " ~ name);
    auto root = buildPath("/var/tmp", "vibe3d-cli-test-" ~ thisProcessID.to!string);
    mkdirRecurse(root); scope(exit) rmdirRecurse(root);
    auto doc = fixture(root);
    auto quad = differential(root, doc, [
        `{"id":"mesh.select","params":{"mode":"vertices","indices":[4,6]}}`,
        `{"id":"mesh.select","params":{"mode":"edges","indices":[2]}}`,
        `{"id":"mesh.select","params":{"mode":"polygons","indices":[0]}}`,
        `{"id":"mesh.triple"}`, `{"id":"history.undo"}`, `{"id":"history.redo"}`],
        true, ["applied", "applied", "applied", "applied", "applied", "applied"]);
    auto before = cleanPlanes(quad.states[3]["state"]["planes"]), after = cleanPlanes(quad.states[4]["state"]["planes"]);
    assert(before != after && after["counts"]["faces"].integer == 7,
        "CLI selected quad: populated forward differs, six to seven faces");
    assert(cleanPlanes(quad.states[5]["state"]["planes"]) == before
        && cleanPlanes(quad.states[6]["state"]["planes"]) == after,
        "CLI undo/redo: exact whole-plane roundtrip");
    auto saved = parseJSON(readText(buildPath(root, "output.v3d")));
    auto parent = doc["layers"][0]["mesh"]["faces"][0].array;
    assert(parent.length == 4, "CLI winding oracle: source face is populated quad");
    auto vertices = saved["layers"][0]["mesh"]["vertices"].array;
    double[3] normal(JSONValue a, JSONValue b, JSONValue c) {
        double[3] x, y;
        foreach (i; 0 .. 3) { x[i] = b[i].floating - a[i].floating; y[i] = c[i].floating - a[i].floating; }
        return [x[1]*y[2]-x[2]*y[1], x[2]*y[0]-x[0]*y[2], x[0]*y[1]-x[1]*y[0]];
    }
    auto sourceVertices = doc["layers"][0]["mesh"]["vertices"].array;
    JSONValue[] sourcePositions;
    foreach (index; parent) sourcePositions ~= sourceVertices[index.integer];
    auto sourceNormal = normal(sourcePositions[0], sourcePositions[1], sourcePositions[2]);
    size_t children;
    foreach (face; saved["layers"][0]["mesh"]["faces"].array) {
        if (face.array.length != 3) continue;
        foreach (corner; face.array) assert(sourcePositions.canFind(vertices[corner.integer]), "CLI winding oracle: child belongs to selected source quad");
        auto childNormal = normal(vertices[face[0].integer], vertices[face[1].integer], vertices[face[2].integer]);
        double alignment = 0; foreach (i; 0 .. 3) alignment += sourceNormal[i] * childNormal[i];
        assert(alignment > 0, "CLI reopen: triangle winding agrees with source quad orientation alignment=" ~ alignment.to!string);
        ++children;
    }
    assert(children == 2, "CLI reopen: populated pair of oriented triangle children");
    assert(saved["layers"].array.length == 2 && saved["layers"][0]["mesh"]["faces"].array.length == 7,
        "CLI selected quad: reopened authored layers and geometry population");
    differential(root, doc, [`{"id":"mesh.select","params":{"mode":"polygons","indices":[]}}`,
        `{"id":"mesh.triple"}`], true, ["applied", "applied"]);
    auto triangles = parseJSON(doc.toString);
    triangles["layers"][0]["mesh"]["faces"] = parseJSON(`[[0,1,2]]`);
    auto mesh = &triangles["layers"][0]["mesh"];
    foreach (key; ["faceMaterial", "faceSubpatch", "facePart", "uvMaps"]) (*mesh).object.remove(key);
    auto refusal = differential(root, triangles, [`{"id":"mesh.select","params":{"mode":"polygons","indices":[0]}}`,
        `{"id":"mesh.triple"}`, `{"id":"history.undo"}`], false, ["applied", "refused"]);
    assert(refusal.states[2]["state"]["changes"]["deliveryCount"].integer
        == refusal.states[1]["state"]["changes"]["deliveryCount"].integer + 1
        && refusal.states[2]["state"]["history"] == refusal.states[1]["state"]["history"],
        "CLI selected triangle: frozen refusal delivery plus one, history unchanged");
    differential(root, triangles, [`{"id":"mesh.select","params":{"mode":"polygons","indices":[]}}`,
        `{"id":"mesh.triple"}`], false, ["applied", "refused"]);
    differential(root, doc, ["", "  ", "{broken", `{"id":"mesh.triple"}`], false, ["error"]);
    differential(root, doc, ["", `{"id":"not.supported"}`, `{"id":"mesh.triple"}`], false, ["error"]);
    auto noTarget = parseJSON(doc.toString); noTarget["primaryLayer"] = -1;
    foreach (ref layer; noTarget["layers"].array) layer["selected"] = false;
    auto absent = differential(root, noTarget, [`{"id":"mesh.triple"}`], false, ["refused"]);
    assert(!absent.states[0]["state"]["hasEditTarget"].boolean
        && absent.states[0]["state"] == absent.states[1]["state"],
        "CLI no target: actual absent primary and complete state preservation");
    auto unicode = "{\"id\":\"mesh.select\",\"params\":{\"mode\":\"polygons\",\"indices\":[0],\"bogus\":\"a\u2028b\u2029c\u0085d\"}}";
    differential(root, doc, ["", unicode ~ "\r", `{"id":"mesh.triple","params":{"bogus":1}}`], true, ["applied", "applied"]);
    // A populated real process gives /proc maps/exe/env/argv witnesses while it
    // runs the same four-ID roster; no debug pause flag or alternate CLI exists.
    auto input = buildPath(root, "input.v3d"), script = buildPath(root, "script.jsonl"), output = buildPath(root, "output.v3d");
    write(input, doc.toString);
    string longScript; foreach (_; 0 .. 300) longScript ~= `{"id":"mesh.select","params":{"mode":"polygons","indices":[0]}}` ~ "\n";
    write(script, longScript);
    auto live = runCli(root, input, script, output, buildPath(root, "state.jsonl"), true);
    assert(live.status == 0 && live.states.length == 302 && live.outcomes.length == 300,
        "CLI process: real state-output and outcome population");
    // Transaction failures and diagnostic aliases must not alter any protected file.
    write(script, `{"id":"not.supported"}` ~ "\n");
    auto original = readText(input);
    auto failed = runCli(root, input, script, input, buildPath(root, "state.jsonl"));
    assert(failed.status == 1 && readText(input) == original, "CLI transaction: input==output preserved on command failure");
    write(script, "");
    auto success = runCli(root, input, script, input, buildPath(root, "state.jsonl"));
    assert(success.status == 0 && parseJSON(readText(input)) == doc,
        "CLI transaction: input==output successful atomic production save");
    mkdirRecurse(buildPath(root, "sub"));
    foreach (protectedPath; [input, output, script]) {
        auto originalBytes = read(protectedPath);
        string[] aliases = [buildPath(root, "sub", "..", baseName(protectedPath))];
        auto sym = buildPath(root, "sym-" ~ baseName(protectedPath));
        auto hard = buildPath(root, "hard-" ~ baseName(protectedPath));
        symlink(protectedPath, sym);
        assert(link(protectedPath.toStringz, hard.toStringz) == 0, "CLI alias fixture: hardlink created");
        aliases ~= [sym, hard];
        foreach (aliasPath; aliases) {
            auto bad = runCli(root, input, script, output, aliasPath);
            assert(bad.status == 1 && read(protectedPath) == originalBytes,
                "CLI diagnostics alias: lexical/symlink/hardlink preserves protected file");
        }
    }
    // Symlink/.. is resolved by the filesystem before lexical normalization.
    auto actualDir = buildPath(root, "actual"), branchDir = buildPath(root, "branch");
    mkdirRecurse(buildPath(actualDir, "leaf")); mkdirRecurse(branchDir);
    symlink(buildPath(actualDir, "leaf"), buildPath(branchDir, "link"));
    write(buildPath(actualDir, "input.v3d"), doc.toString);
    write(buildPath(branchDir, "input.v3d"), "different lexical document");
    auto requestedInput = buildPath(branchDir, "link", "..", "input.v3d");
    auto requestedOutput = buildPath(branchDir, "link", "..", "out.v3d");
    auto pathRun = runCli(root, requestedInput, script, requestedOutput, buildPath(root, "state.jsonl"));
    assert(pathRun.status == 0 && exists(buildPath(actualDir, "out.v3d"))
        && !exists(buildPath(branchDir, "out.v3d"))
        && parseJSON(readText(buildPath(actualDir, "out.v3d"))) == doc,
        "CLI filesystem path: symlink parent/.. preserves requested document/output directory");
    auto protectedBytes = read(requestedInput);
    auto pathAlias = runCli(root, requestedInput, script, output, requestedInput);
    assert(pathAlias.status == 1 && read(requestedInput) == protectedBytes,
        "CLI diagnostics alias: symlink parent/.. preserves requested input");
    auto missing = runCli(root, buildPath(root, "missing.v3d"), script, output, buildPath(root, "empty-state.jsonl"));
    auto loadError = jsonRows(missing.error);
    assert(loadError.length == 1 && loadError[0]["stage"].str == "load"
        && loadError[0]["line"].type == JSONType.null_, "CLI stderr: native load diagnostic path");
    assert(missing.status == 1 && missing.states.length == 0, "CLI load error: no loaded state rows");
    auto sentinel = read(output);
    write(input, "bad native");
    auto malformed = runCli(root, input, script, output);
    assert(malformed.status == 1 && read(output) == sentinel, "CLI load error: malformed input preserves output");
    write(input, doc.toString);
    auto unwritable = runCli(root, input, script, buildPath(root, "missing-dir/out.v3d"), buildPath(root, "state.jsonl"));
    assert(unwritable.status == 1 && unwritable.states.length == 2
        && unwritable.states[$ - 1]["phase"].str == "pre-save", "CLI save error: pre-save retained before production failure");
    auto saveError = jsonRows(unwritable.error);
    assert(saveError.length == 1 && saveError[0]["stage"].str == "save"
        && saveError[0]["line"].type == JSONType.null_, "CLI stderr: native save diagnostic path");
    noOrphan(root);
    writeln("CLI-WITNESS source=", sourcePin, " binary-sha256=", binaryHash, " roster=4 cases=quad,whole,triangle,no-target,errors,unicode,aliases,atomic");
}
