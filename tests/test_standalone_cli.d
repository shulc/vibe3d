import http_client : getJson, postJson, postRawAllowingErrorStatus, quiesce;
import http_command_helpers : commandBody;
import std.algorithm : canFind, startsWith;
import std.array : array, join;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.file : read, readText, write, exists, mkdirRecurse, rmdirRecurse,
    dirEntries, SpanMode, readLink, symlink, remove;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : buildPath, dirName, baseName;
import std.process : execute, spawnProcess, wait, kill, tryWait, Pid, Config,
    environment, thisProcessID;
import std.stdio : File, stdin, writeln;
import std.string : split, strip, toLower;
import core.sys.posix.signal : SIGKILL;
import core.sys.posix.unistd : link, close;
import core.sys.posix.sys.stat : mkfifo;
import core.sys.posix.fcntl : open, O_WRONLY, O_NONBLOCK, fcntl, F_SETFL;
import core.stdc.errno : errno, ENXIO, EINTR;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.exception : enforce;
import std.string : toStringz;

void main() {}

private enum repo = dirName(dirName(__FILE_FULL_PATH__));
private string binaryHash;
private string sourcePin;

private string digest(string path) { return read(path).sha256Of.toHexString.idup; }
private JSONValue[] jsonRows(string text) {
    JSONValue[] rows;
    foreach (line; text.split("\n")) if (line.strip.length) {
        try { rows ~= parseJSON(line); }
        catch (Exception error) { assert(false, "CLI JSONL: non-JSON physical output row " ~ line ~ " error=" ~ error.msg); }
    }
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
private void parity(JSONValue cli, JSONValue desktop, JSONValue previousCli, JSONValue previousDesktop, bool noTargetContext = false) {
    assert(cli.object.length == 6, "CLI state: exact six-key schema");
    foreach (key; ["hasEditTarget", "selType", "editMode", "planes", "history", "changes"])
        assert(key in cli.object, "CLI state: required schema key " ~ key);
    assert(cli["hasEditTarget"].type == JSONType.true_ || cli["hasEditTarget"].type == JSONType.false_,
        "CLI state: target boolean schema");
    assert(cli["selType"].type == JSONType.string && cli["editMode"].type == JSONType.string
        && cli["planes"].type == JSONType.object && cli["history"].object.length == 4
        && cli["changes"].object.length == 4, "CLI state: complete typed nested schema");
    foreach (key; ["undo", "redo"])
        foreach (entry; cli["history"][key].array) {
            assert(entry.object.length == 6, "CLI history: exact row schema");
            foreach (field; ["command", "label", "args", "flags", "runId", "tweakGen"])
                assert(field in entry.object, "CLI history: required row field " ~ field);
        }
    auto cliPlanes = cleanPlanes(cli["planes"]);
    foreach (key, value; cliPlanes.object)
        assert(key in desktop["planes"].object && value == desktop["planes"][key],
            "CLI differential: plane " ~ key ~ " mismatch cli=" ~ value.toString
                ~ " desktop=" ~ desktop["planes"][key].toString);
    assert(cliPlanes == desktop["planes"], "CLI differential: complete plane mismatch");
    foreach (key; ["hasEditTarget", "selType", "editMode", "history"])
        assert(cli[key] == desktop[key], "CLI differential: state mismatch " ~ key
            ~ " cli=" ~ cli[key].toString ~ " desktop=" ~ desktop[key].toString);
    if (noTargetContext) {
        assert(!cli["hasEditTarget"].boolean && !desktop["hasEditTarget"].boolean,
            "CLI context: marked population requires absent targets");
        foreach (state; [cli, desktop])
            assert(state["history"]["undo"].array.length == 0 && state["history"]["redo"].array.length == 0
                && state["history"]["modelDepth"].integer == 0 && state["history"]["uiDepth"].integer == 0,
                "CLI context: marked population requires empty history/depths");
        if (previousCli.type != JSONType.null_) {
            assert(cli["changes"]["deliveryCount"] == previousCli["changes"]["deliveryCount"]
                && desktop["changes"]["deliveryCount"] == previousDesktop["changes"]["deliveryCount"],
                "CLI context: marked current row requires zero mesh delivery delta");
            foreach (key; ["hasEditTarget", "selType", "editMode", "planes", "history"])
                assert(cli[key] == previousCli[key] && desktop[key] == previousDesktop[key],
                    "CLI context: host-local complete planes/selection/history preserved " ~ key);
            assert(cli["changes"]["docRevision"] == previousCli["changes"]["docRevision"],
                "CLI context: host-local document revision preserved");
            foreach (key; ["lastDeliveryFlags", "lastDeliverySelDomains"])
                assert(cli["changes"][key] == previousCli["changes"][key]
                    && desktop["changes"][key] == previousDesktop["changes"][key],
                    "CLI context: host-local incoming gauge preserved " ~ key);
        }
    } else foreach (key; ["lastDeliveryFlags", "lastDeliverySelDomains"])
        assert(cli["changes"][key] == desktop["changes"][key],
            "CLI differential: delivery gauge mismatch " ~ key
                ~ " phase=" ~ (previousCli.type == JSONType.null_ ? "loaded" : "command")
                ~ " target=" ~ cli["hasEditTarget"].toString
                ~ " cli=" ~ cli["changes"][key].toString ~ " desktop=" ~ desktop["changes"][key].toString);
    if (previousCli.type != JSONType.null_) {
        auto cliDelta = cli["changes"]["deliveryCount"].integer - previousCli["changes"]["deliveryCount"].integer;
        auto desktopDelta = desktop["changes"]["deliveryCount"].integer - previousDesktop["changes"]["deliveryCount"].integer;
        assert(cliDelta == desktopDelta, "CLI differential: command delivery delta mismatch");
    }
}

// Task 20263020: loaded diagnostic plus an open, EOF-withheld commands FIFO
// keeps the real host alive for /proc custody; doc/ci_runner_failures_plan_2026-10-16.md.
private int awaitLoaded(Pid pid, ref bool reaped, string diagnostics, string fifo,
        int budgetMs = 5_000) {
    const deadline = MonoTime.currTime + budgetMs.msecs;
    int writer = -1;
    scope(failure) { if (writer >= 0) close(writer); }
    while (MonoTime.currTime < deadline) {
        const state = tryWait(pid);
        if (state.terminated) {
            reaped = true;
            enforce(false, "CLI readiness: child exited before loaded/FIFO, status=" ~ state.status.to!string);
        }
        if (writer < 0) {
            writer = open(fifo.toStringz, O_WRONLY | O_NONBLOCK);
            enforce(writer >= 0 || errno == ENXIO || errno == EINTR,
                "CLI readiness: commands FIFO open failed");
        }
        if (writer >= 0 && exists(diagnostics)) {
            const text = readText(diagnostics);
            // A concurrent writer may have only emitted part of the first JSONL row.
            if (text.canFind("\n")) {
                auto rows = jsonRows(text);
                enforce(rows.length == 1 && rows[0]["phase"].str == "loaded",
                    "CLI readiness: exact loaded row before commands");
                enforce(fcntl(writer, F_SETFL, 0) == 0, "CLI readiness: commands FIFO blocking mode");
                return writer;
            }
        }
        Thread.sleep(5.msecs);
    }
    enforce(false, "CLI readiness: deadline before loaded/FIFO");
    return -1;
}

private bool mappingContains(string mappings, string name) {
    return mappings.toLower.canFind(name);
}

private bool environmentContainsKey(string raw, string key) {
    foreach (entry; raw.split("\0"))
        if (entry.startsWith(key ~ "=")) return true;
    return false;
}

private void environmentKeyControls() {
    foreach (key; ["DISPLAY", "WAYLAND_DISPLAY", "SDL_VIDEODRIVER"]) {
        foreach (value; ["", ":99"])
            foreach (raw; [key ~ "=" ~ value ~ "\0", "OTHER=value\0" ~ key ~ "=" ~ value,
                    "OTHER=value\0" ~ key ~ "=" ~ value ~ "\0AFTER=value\0"])
                assert(environmentContainsKey(raw, key),
                    "CLI environment fixture: exact key present including empty value " ~ key);
        foreach (raw; ["", "VIBE3D_TEST_" ~ key ~ "=:99\0", key ~ "_SUFFIX=:99\0",
                "OTHER=" ~ key ~ "=:99\0", "OTHER=line1\n" ~ key ~ "=:99\nline3\0"])
            assert(!environmentContainsKey(raw, key),
                "CLI environment fixture: other keys and value text are harmless " ~ key);
    }
}

private void readinessRefusals(string root) {
    foreach (name; ["sdl", "libgl", "libegl", "imgui", "libx11", "nfde", "libxcb", "wayland"]) {
        assert(mappingContains("/usr/lib/" ~ name ~ ".so", name),
            "CLI process: populated forbidden mapping fixture " ~ name);
        assert(!mappingContains("/usr/lib/libc.so", name),
            "CLI process: ordinary mapping fixture " ~ name);
    }
    foreach (mode; ["exit", "never-ready"]) {
        const fifo = buildPath(root, "readiness-" ~ mode ~ ".fifo");
        const diagnostic = buildPath(root, "readiness-" ~ mode ~ ".jsonl");
        enforce(mkfifo(fifo.toStringz, 0x180) == 0);
        scope(exit) remove(fifo);
        // Opening the peer without emitting loaded must never grant observation.
        auto child = spawnProcess(["python3", "-c",
            "import sys; f=open(sys.argv[1]) if sys.argv[2]=='never-ready' else None; "
            ~ "sys.exit(7) if f is None else f.read()", fifo, mode]);
        bool reaped, refused;
        scope(exit) if (!reaped) { kill(child, SIGKILL); wait(child); }
        const started = MonoTime.currTime;
        try {
            const writer = awaitLoaded(child, reaped, diagnostic, fifo, 200);
            close(writer);
        } catch (Exception error) {
            refused = error.msg.canFind("CLI readiness: child exited")
                || error.msg.canFind("CLI readiness: deadline");
        }
        assert(refused, "CLI readiness: startup exit and withheld loaded must refuse observation");
        assert((MonoTime.currTime - started) < 2.seconds,
            "CLI readiness: startup refusal must be bounded");
    }
}

private struct Run { int status; JSONValue[] states, outcomes; string error; }
private Run runCli(string root, string input, string script, string output, string diagnostics = "", bool observeProcess = false, bool readDiagnostics = true) {
    auto outLog = buildPath(root, "stdout.jsonl"), errLog = buildPath(root, "stderr.log");
    auto outFile = File(outLog, "w"), errFile = File(errLog, "w");
    string[] argv = [buildPath(repo, "tools/cli/vibe3d-cli"), "run", "--input", input,
        "--commands", script, "--output", output];
    if (diagnostics.length) argv ~= ["--state-output", diagnostics];
    auto env = environment.toAA;
    foreach (key; ["DISPLAY", "WAYLAND_DISPLAY", "SDL_VIDEODRIVER"]) env.remove(key);
    string fifo, payload;
    if (observeProcess) {
        env["VIBE3D_TEST_DISPLAY"] = ":ci-harmless";
        enforce(diagnostics.length > 0, "CLI readiness: diagnostics required");
        payload = readText(script);
        fifo = script ~ ".fifo";
        enforce(mkfifo(fifo.toStringz, 0x180) == 0, "CLI readiness: create owned commands FIFO");
        argv[5] = fifo;
    }
    scope(exit) { if (fifo.length && exists(fifo)) remove(fifo); }
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
        auto writer = File();
        writer.fdopen(awaitLoaded(pid, reaped, diagnostics, fifo), "w");
        scope(exit) writer.close();
        auto proc = "/proc/" ~ pid.processID.to!string;
        assert(readLink(proc ~ "/exe") == argv[0], "CLI process: actual executable is current checkout");
        assert(digest(proc ~ "/exe") == binaryHash, "CLI process: actual executable hash equals fresh binary");
        auto mappings = readText(proc ~ "/maps");
        assert(mappings.length > 100 && mappings.canFind("libc.so"), "CLI process: populated live mappings");
        foreach (name; ["sdl", "libgl", "libegl", "imgui", "libx11", "nfde", "libxcb", "wayland"])
            assert(!mappingContains(mappings, name), "CLI process: forbidden mapping " ~ name);
        auto liveEnvironment = readText(proc ~ "/environ");
        assert(environmentContainsKey(liveEnvironment, "VIBE3D_TEST_DISPLAY"),
            "CLI process: harmless prefixed display key is present");
        foreach (key; ["DISPLAY", "WAYLAND_DISPLAY", "SDL_VIDEODRIVER"])
            assert(!environmentContainsKey(liveEnvironment, key),
                "CLI process: display variable inherited " ~ key ~ "=");
        auto cmdline = readText(proc ~ "/cmdline");
        assert(cmdline.canFind("--state-output") && cmdline.canFind(fifo), "CLI process: real diagnostic argv");
        writeln("CLI-PROCESS source=", sourcePin, " binary-sha256=", binaryHash,
            " exe=", readLink(proc ~ "/exe"), " maps-bytes=", mappings.length, " display=unset");
        writer.rawWrite(payload);
    }
    Run result;
    result.status = wait(pid); reaped = true;
    outFile.close(); errFile.close();
    result.outcomes = jsonRows(readText(outLog)); result.error = readText(errLog);
    auto errors = jsonRows(result.error);
    bool producedState = result.status == 0 || (errors.length == 1
        && errors[0]["stage"].str != "arguments" && errors[0]["stage"].str != "load");
    if (readDiagnostics && producedState && diagnostics.length && exists(diagnostics))
        result.states = jsonRows(readText(diagnostics));
    foreach (row; result.states) {
        assert(row.object.length == 5, "CLI state: exact diagnostic row schema");
        foreach (key; ["phase", "line", "id", "outcome", "state"])
            assert(key in row.object, "CLI state: required diagnostic row key " ~ key);
    }
    assert(digest(argv[0]) == binaryHash, "CLI process: binary stable throughout run");
    return result;
}
private void errorSchema(Run result, string stage, JSONValue line = JSONValue.init, JSONValue id = JSONValue.init) {
    auto rows = jsonRows(result.error);
    assert(result.status == 1 && rows.length == 1 && rows[0].object.length == 4
        && rows[0]["error"].type == JSONType.string && rows[0]["error"].str.length > 0
        && rows[0]["stage"].str == stage && rows[0]["line"] == line && rows[0]["id"] == id,
        "CLI stderr: exact error schema and stage " ~ stage ~ " actual=" ~ result.error);
}
private void noOrphan(string root) {
    foreach (entry; dirEntries(root, SpanMode.shallow))
        assert(!baseName(entry.name).canFind(".vibe3d-cli-"), "CLI transaction: no owned temporary orphan");
}

private JSONValue loadDesktop(string input) {
    command("scene.reset");
    auto incoming = getJson("/api/changes");
    command("file.load", JSONValue(["path": JSONValue(input)]).toString);
    command("history.clear");
    quiesce();
    return incoming;
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

private Run differential(string root, JSONValue doc, string[] scriptRows, bool success, string[] outcomes, bool noTargetContext = false) {
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
    auto incoming = loadDesktop(input);
    auto previousDesktop = desktopState(), previousCli = result.states[0]["state"];
    if (noTargetContext) {
        assert(!success && outcomes == ["refused"] && scriptRows == [`{"id":"mesh.triple"}`]
            && result.states.length == 2, "CLI context: exact loaded plus one refused command population");
        assert(doc["layers"].array.length == 2 && doc["layers"][0]["mesh"]["vertices"].array.length == 8
            && doc["layers"][0]["mesh"]["weightMaps"].array.length == 1,
            "CLI context: nonempty authored two-layer maps fixture");
        foreach (layer; doc["layers"].array)
            assert(!layer["selected"].boolean, "CLI context: native layer selected flags absent");
        foreach (item; getJson("/api/selection")["items"].array)
            assert(!item["primary"].boolean && !item["selected"].boolean,
                "CLI context: loaded desktop layer selection and primary absent");
        foreach (key; ["deliveryCount", "lastDeliveryFlags", "lastDeliverySelDomains"])
            assert(previousDesktop["changes"][key] == incoming[key],
                "CLI context: desktop no-target load preserves incoming " ~ key);
        assert(previousCli["changes"]["deliveryCount"].integer == 0
            && previousCli["changes"]["lastDeliveryFlags"].integer == 0
            && previousCli["changes"]["lastDeliverySelDomains"].integer == 0,
            "CLI context: fresh CLI no-target construction has zero gauges");
        writeln("CLI-CONTEXT cli-loaded=", previousCli["changes"].toString,
            " desktop-incoming=", incoming.toString, " desktop-loaded=", previousDesktop["changes"].toString);
    }
    parity(previousCli, previousDesktop, JSONValue.init, JSONValue.init, noTargetContext);
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
            auto expectedId = valid && "id" in commandRow.object && commandRow["id"].type == JSONType.string
                ? commandRow["id"] : JSONValue.init;
            assert(actual["phase"].str == "error" && actual["id"] == expectedId
                && actual["outcome"].type == JSONType.null_,
                "CLI state: malformed/unknown error row");
            if (expectedId.type == JSONType.string && ["select.element", "select.drop"].canFind(expectedId.str)) {
                auto response = parseJSON(postRawAllowingErrorStatus("/api/command", row));
                assert(response["status"].str == "error", "CLI required arguments: desktop refusal");
            }
            assert(actual["state"] == previousCli, "CLI error: complete state preservation");
            assert(desktopState() == previousDesktop, "CLI error: desktop complete state preservation");
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
            parity(actual["state"], nextDesktop, previousCli, previousDesktop, noTargetContext);
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
    environmentKeyControls();
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
    readinessRefusals(root);
    auto doc = fixture(root);
    string[] selectionRows = [
        `{"id":"mesh.select","params":{"mode":"vertices","indices":[6,1]}}`,
        `{"id":"mesh.select","params":{"mode":"edges","indices":[5,3]}}`,
        `{"id":"mesh.select","params":{"mode":"polygons","indices":[1,0]}}`,
        `{"id":"select.element","params":{"type":"vertex","action":"set","indices":[-1,5,99,2]}}`,
        `{"id":"select.element","params":{"type":"unknown","action":"unknown","indices":[1]}}`,
        `{"id":"select.element","params":{"type":"vertex","action":"toggle","indices":[2,2]}}`,
        `{"id":"select.element","params":{"type":"vertex","action":"del","indices":[5]}}`,
        `{"id":"select.element","params":{"type":"vertex","action":"replace","indices":[]}}`,
        `{"id":"select.drop","params":{"type":"edge"}}`,
        `{"id":"select.drop","params":{"type":"edge"}}`,
        `{"id":"history.undo"}`, `{"id":"history.undo"}`,
        `{"id":"history.redo"}`, `{"id":"history.redo"}`,
        `{"id":"select.invert"}`, `{"id":"select.invert"}`,
        `{"id":"history.undo"}`, `{"id":"history.undo"}`,
        `{"id":"history.redo"}`, `{"id":"history.redo"}`,
        `{"id":"mesh.select","params":{"mode":"polygons","indices":[0]}}`,
        `{"id":"mesh.triple"}`, `{"id":"history.undo"}`, `{"id":"history.redo"}`
    ];
    assert(selectionRows.length == 24, "CLI selection: integrated invocation population");
    string[] selectionOutcomes; foreach (_; selectionRows) selectionOutcomes ~= "applied";
    auto selection = differential(root, doc, selectionRows, true, selectionOutcomes);
    assert(selection.states[11]["state"]["editMode"].str == "Edges"
        && selection.states[12]["state"]["editMode"].str == "Polygons"
        && selection.states[14]["state"]["editMode"].str == "Edges",
        "CLI drop: real cross-domain undo/redo mode chronology");
    assert(selection.states[24]["state"]["planes"]["counts"]["faces"].integer == 7,
        "CLI selection: triple plus undo/redo before production save");
    foreach (row; [
        `{"id":"select.element","params":{"action":"set","indices":[]}}`,
        `{"id":"select.element","params":{"type":"vertex","indices":[]}}`,
        `{"id":"select.element","params":{"type":"vertex","action":"set"}}`,
        `{"id":"select.element","params":{"type":"vertex","action":"set","indices":[1,"bad"]}}`,
        `{"id":"select.drop"}`, `{"id":"select.drop","params":{"type":"unknown"}}`
    ]) differential(root, doc, [selectionRows[0], selectionRows[1], selectionRows[2], row],
        false, ["applied", "applied", "applied", "error"]);
    auto undoOnly = differential(root, doc, [
        `{"id":"mesh.select","params":{"mode":"polygons","indices":[0]}}`,
        `{"id":"mesh.triple"}`, `{"id":"history.undo"}`],
        true, ["applied", "applied", "applied"]);
    assert(cleanPlanes(undoOnly.states[3]["state"]["planes"])
        == cleanPlanes(undoOnly.states[1]["state"]["planes"]),
        "CLI undo: exact whole-plane restore before redo");
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
    size_t selectedChildren;
    foreach (i, mark; after["faceMarks"].array) {
        if ((mark.integer & 1) == 0) continue;
        assert(saved["layers"][0]["mesh"]["faces"][i].array.length == 3,
            "CLI selected quad: selected face is an actual triangle child");
        ++selectedChildren;
    }
    assert(selectedChildren == 2, "CLI selected quad: exactly two selected triangle children");
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
    foreach (badRow; ["[]", "1", "null", "{}", `{"id":1}`])
        differential(root, doc, [badRow, `{"id":"mesh.triple"}`], false, ["error"]);
    foreach (badRow; ["{broken", `{"id":"not.supported"}`])
        differential(root, doc, [`{"id":"mesh.select","params":{"mode":"polygons","indices":[0]}}`,
            badRow, `{"id":"mesh.triple"}`], false, ["applied", "error"]);
    auto noTarget = parseJSON(doc.toString); noTarget["primaryLayer"] = -1;
    foreach (ref layer; noTarget["layers"].array) layer["selected"] = false;
    auto absent = differential(root, noTarget, [`{"id":"mesh.triple"}`], false, ["refused"], true);
    assert(!absent.states[0]["state"]["hasEditTarget"].boolean
        && absent.states[0]["state"] == absent.states[1]["state"],
        "CLI no target: actual absent primary and complete state preservation");
    foreach (badScript; ["{broken\n", "{\"id\":\"not.supported\"}\n"]) {
        write(buildPath(root, "script.jsonl"), badScript);
        auto failedNoTarget = runCli(root, buildPath(root, "input.v3d"), buildPath(root, "script.jsonl"),
            buildPath(root, "output.v3d"), buildPath(root, "state.jsonl"));
        assert(failedNoTarget.status == 1 && failedNoTarget.states.length == 2
            && failedNoTarget.outcomes.length == 0 && failedNoTarget.states[1]["phase"].str == "error"
            && failedNoTarget.states[0]["state"] == failedNoTarget.states[1]["state"]
            && !failedNoTarget.states[0]["state"]["hasEditTarget"].boolean
            && readText(buildPath(root, "output.v3d")) == "sentinel",
            "CLI no-target errors: no writes/history/delivery or later rows");
        errorSchema(failedNoTarget, badScript[0 .. 2] == "{b" ? "script" : "command", JSONValue(1),
            badScript[0 .. 2] == "{b" ? JSONValue.init : JSONValue("not.supported"));
    }
    auto unicode = "{\"id\":\"mesh.select\",\"params\":{\"mode\":\"polygons\",\"indices\":[0],\"bogus\":\"a\u2028b\u2029c\u0085d\"}}";
    differential(root, doc, ["", unicode ~ "\r", `{"id":"mesh.triple","params":{"bogus":1}}`], true, ["applied", "applied"]);
    // Observe the loaded real host with command EOF withheld, then release the unchanged script.
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
    errorSchema(failed, "command", JSONValue(1), JSONValue("not.supported"));
    noOrphan(root);
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
            assert(bad.states.length == 0 && bad.outcomes.length == 0,
                "CLI diagnostics alias: argument refusal precedes loading and invocation");
            errorSchema(bad, "arguments");
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
    // A missing intermediate component must retain filesystem lookup failure.
    auto existingInput = read(input), existingOutput = read(output);
    auto missingInput = runCli(root, buildPath(root, "missing", "..", "input.v3d"), script, output,
        buildPath(root, "missing-input-state.jsonl"));
    assert(missingInput.status == 1 && missingInput.states.length == 0
        && read(input) == existingInput && read(output) == existingOutput,
        "CLI filesystem path: missing intermediate input must fail without choosing normalized file");
    errorSchema(missingInput, "load");
    auto missingOutput = runCli(root, input, script, buildPath(root, "missing", "..", "output.v3d"),
        buildPath(root, "state.jsonl"));
    assert(missingOutput.status == 1 && missingOutput.states.length == 2
        && missingOutput.states[0]["state"] == missingOutput.states[1]["state"]
        && read(input) == existingInput && read(output) == existingOutput,
        "CLI filesystem path: missing intermediate output must fail preserving existing files");
    errorSchema(missingOutput, "save");
    auto diagnosticOpen = runCli(root, input, script, output, buildPath(root, "missing", "state.jsonl"));
    assert(diagnosticOpen.states.length == 0 && diagnosticOpen.outcomes.length == 0
        && read(input) == existingInput && read(output) == existingOutput,
        "CLI diagnostics: open failure preserves native files before commands/save");
    errorSchema(diagnosticOpen, "diagnostics");
    auto diagnosticWrite = runCli(root, input, script, output, "/dev/full", false, false);
    assert(diagnosticWrite.states.length == 0 && diagnosticWrite.outcomes.length == 0
        && read(input) == existingInput && read(output) == existingOutput,
        "CLI diagnostics: actual write failure preserves native files before commands/save");
    errorSchema(diagnosticWrite, "diagnostics");
    foreach (flags; [cast(string[])[], ["run"], ["bad"], ["run", "--other", "file"],
        ["run", "--input"], ["run", "--input", ""],
        ["run", "--input", input, "--commands", script, "--output", output, "--state-output", ""],
        ["run", "--input", input, "--input", input, "--commands", script, "--output", output]]) {
        auto badArguments = execute([buildPath(repo, "tools/cli/vibe3d-cli")] ~ flags);
        Run bad; bad.status = badArguments.status; bad.error = badArguments.output;
        errorSchema(bad, "arguments");
        assert(read(input) == existingInput && read(output) == existingOutput,
            "CLI arguments: errors preserve native files");
    }
    auto renameFailure = runCli(root, input, script, buildPath(root, "sub"), buildPath(root, "state.jsonl"));
    assert(renameFailure.states.length == 2 && renameFailure.outcomes.length == 0
        && renameFailure.states[1]["phase"].str == "pre-save"
        && renameFailure.states[0]["state"] == renameFailure.states[1]["state"]
        && read(input) == existingInput && read(output) == existingOutput,
        "CLI rename failure: retained pre-save and preserved existing files");
    errorSchema(renameFailure, "save");
    noOrphan(root);
    auto missing = runCli(root, buildPath(root, "missing.v3d"), script, output, buildPath(root, "empty-state.jsonl"));
    auto loadError = jsonRows(missing.error);
    assert(loadError.length == 1 && loadError[0]["stage"].str == "load"
        && loadError[0]["line"].type == JSONType.null_, "CLI stderr: native load diagnostic path");
    assert(missing.status == 1 && missing.states.length == 0 && missing.outcomes.length == 0
        && read(output) == existingOutput, "CLI load error: no loaded state rows or native writes");
    errorSchema(missing, "load");
    auto sentinel = read(output);
    write(input, "bad native");
    auto malformed = runCli(root, input, script, output);
    assert(malformed.status == 1 && malformed.states.length == 0 && malformed.outcomes.length == 0
        && read(output) == sentinel, "CLI load error: malformed input preserves output");
    errorSchema(malformed, "load");
    write(input, doc.toString);
    auto unwritable = runCli(root, input, script, buildPath(root, "missing-dir/out.v3d"), buildPath(root, "state.jsonl"));
    assert(unwritable.status == 1 && unwritable.states.length == 2
        && unwritable.states[$ - 1]["phase"].str == "pre-save", "CLI save error: pre-save retained before production failure");
    auto saveError = jsonRows(unwritable.error);
    assert(saveError.length == 1 && saveError[0]["stage"].str == "save"
        && saveError[0]["line"].type == JSONType.null_, "CLI stderr: native save diagnostic path");
    assert(unwritable.states[0]["state"] == unwritable.states[1]["state"]
        && unwritable.outcomes.length == 0 && read(output) == sentinel,
        "CLI save error: complete pre-save state and existing native output preserved");
    errorSchema(unwritable, "save");
    noOrphan(root);
    writeln("CLI-WITNESS source=", sourcePin, " binary-sha256=", binaryHash, " roster=7 cases=selection,required,quad,whole,triangle,no-target,errors,unicode,aliases,atomic");
}
