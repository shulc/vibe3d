module tests.unit.ui.remesh_modal_state_test;

import core.time : MonoTime, msecs, seconds;
import d_imgui.imgui_h : ImVec2;
import editor_app : MeshDg;
import imgui_flag_boundary : anyPopupOpen;
import math : Vec3;
import mesh : Mesh, makeGridPlane;
import remesh.remesh_job : MAX_REMESH_TARGET_QUADS,
    MIN_REMESH_TARGET_QUADS, RemeshJob;
import ui.remesh_modal_state : RemeshModalState;
import ui.panels : drawRemeshModal, remeshModalDrawSnapshot,
    resetRemeshModalDrawSnapshot;
import tests.unit.ui.headless_panel : openPanel;

private ImVec2 center(ImVec2 lo, ImVec2 hi) {
    return ImVec2((lo.x + hi.x) * 0.5f, (lo.y + hi.y) * 0.5f);
}

private void removeIfPresent(string path) nothrow {
    import std.file : remove;

    try remove(path); catch (Exception) {}
}

private bool samePoint(Vec3 a, Vec3 b) {
    import std.math : isClose;

    return isClose(a.x, b.x, 1e-5f, 1e-5f)
        && isClose(a.y, b.y, 1e-5f, 1e-5f)
        && isClose(a.z, b.z, 1e-5f, 1e-5f);
}

private bool containsPoint(const Vec3[] points, Vec3 needle) {
    foreach (point; points)
        if (samePoint(point, needle)) return true;
    return false;
}

private Vec3[] readObjVertices(string path) {
    import std.algorithm.iteration : splitter;
    import std.array : split;
    import std.conv : to;
    import std.file : readText;
    import std.string : startsWith, strip;

    Vec3[] result;
    foreach (line; readText(path).splitter('\n')) {
        const text = line.strip;
        if (!text.startsWith("v ")) continue;
        const fields = text.split;
        assert(fields.length == 4, "captured OBJ vertex row is malformed");
        result ~= Vec3(fields[1].to!float, fields[2].to!float,
                       fields[3].to!float);
    }
    return result;
}

private void waitForCapture(RemeshJob job, string path) {
    import core.thread : Thread;
    import std.file : exists;

    const deadline = MonoTime.currTime + 5.seconds;
    while (!exists(path) && MonoTime.currTime < deadline) {
        job.poll();
        if (!exists(path)) Thread.sleep(10.msecs);
    }
    assert(exists(path), "fake remesher did not capture its input OBJ");
}

private string uniqueTempStem(string label) {
    import std.conv : to;
    import std.file : tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    return buildPath(tempDir(), "vibe3d_6360_" ~ label ~ "_"
        ~ thisProcessID.to!string ~ "_" ~ MonoTime.currTime.ticks.to!string);
}

private string repositoryRoot() {
    import std.path : dirName;

    return __FILE_FULL_PATH__.dirName.dirName.dirName.dirName;
}

private string collapseWhitespace(string text) {
    string result;
    bool spacing;
    foreach (ch; text) {
        const whitespace = ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
        if (whitespace) {
            spacing = result.length > 0;
            continue;
        }
        if (spacing) result ~= ' ';
        result ~= ch;
        spacing = false;
    }
    return result;
}

private struct SavedHelperEnv {
    bool present;
    string value;
}

private SavedHelperEnv saveHelperEnv() {
    import std.process : environment;

    auto snapshot = environment.toAA();
    auto value = "VIBE3D_AUTOREMESHER_BIN" in snapshot;
    return SavedHelperEnv(value !is null, value is null ? null : *value);
}

private void restoreHelperEnv(SavedHelperEnv saved) {
    import std.process : environment;

    if (saved.present)
        environment["VIBE3D_AUTOREMESHER_BIN"] = saved.value;
    else
        environment.remove("VIBE3D_AUTOREMESHER_BIN");
}

unittest { // all eight fields belong to one state instance
    auto state = new RemeshModalState();
    auto other = new RemeshModalState();

    assert(state.targetQuads == 20_000
        && state.adaptivity == 1.0f
        && state.sharpEdge == 90.0f,
        "RemeshModalState defaults changed");
    assert(!state.open && !state.pendingOpen && !state.pendingClose
        && state.lastError is null && state.lastSummary is null,
        "fresh RemeshModalState is not empty");

    state.lastError = "old error";
    state.lastSummary = "old summary";
    state.pendingClose = true;
    state.requestOpen();
    assert(state.pendingClose,
        "requestOpen cleared the preserved pending-close residual");
    assert(state.open && state.pendingOpen,
        "requestOpen did not arm the popup handshake");
    assert(state.lastError is null && state.lastSummary is null,
        "requestOpen did not clear stale result text");
    assert(state.consumePendingOpen(),
        "the first pending-open handoff did not fire");
    assert(!state.consumePendingOpen(),
        "pending-open handoff fired more than once");

    state.lastError = "pre-success error";
    state.noteSuccess("complete");
    assert(state.lastSummary == "complete" && state.lastError is null
        && state.pendingClose,
        "noteSuccess did not publish the summary and close request");
    assert(state.consumePendingClose(),
        "the first pending-close handoff did not fire");
    assert(!state.consumePendingClose(),
        "pending-close handoff fired more than once");

    state.noteFailure("failed");
    assert(state.lastError == "failed" && state.lastSummary is null,
        "noteFailure did not replace the prior result text");
    assert(!state.pendingClose,
        "noteFailure armed a success-only close request");

    state.pendingOpen = true;
    state.lastError = "keep error";
    state.closeWindow();
    assert(!state.open,
        "closeWindow left the modal owner open");
    assert(state.pendingOpen && state.lastError == "keep error",
        "closeWindow changed state outside the open latch");

    assert(!other.open && !other.pendingOpen && !other.pendingClose
        && other.targetQuads == 20_000
        && other.adaptivity == 1.0f && other.sharpEdge == 90.0f
        && other.lastError is null && other.lastSummary is null,
        "two RemeshModalState instances share storage");

    state.targetQuads = MAX_REMESH_TARGET_QUADS + 1;
    state.adaptivity = 11.0f;
    state.sharpEdge = 181.0f;
    state.clampToBounds();
    assert(state.targetQuads == MAX_REMESH_TARGET_QUADS
        && state.adaptivity == 10.0f && state.sharpEdge == 180.0f,
        "upper remesh modal bounds were not enforced");

    state.targetQuads = MIN_REMESH_TARGET_QUADS - 1;
    state.adaptivity = -1.0f;
    state.sharpEdge = -1.0f;
    state.clampToBounds();
    assert(state.targetQuads == MIN_REMESH_TARGET_QUADS
        && state.adaptivity == 0.0f && state.sharpEdge == 0.0f,
        "lower remesh modal bounds were not enforced");

    state.targetQuads = 20_000;
    state.adaptivity = 1.0f;
    state.sharpEdge = 90.0f;
    state.clampToBounds();
    assert(state.targetQuads == 20_000
        && state.adaptivity == 1.0f && state.sharpEdge == 90.0f,
        "in-range remesh modal values were changed");
}

unittest { // popup handshake consumes success-close only inside the modal
    Mesh probeMesh = makeGridPlane(2);
    ref Mesh provider() nothrow @nogc { return probeMesh; }

    auto state = new RemeshModalState();
    auto job = new RemeshJob();
    scope (exit) job.cancel();
    resetRemeshModalDrawSnapshot();
    auto ui = openPanel(() {
        drawRemeshModal(state, job, cast(MeshDg) &provider);
    }, "Remesh modal handshake host");
    scope (exit) ui.close();

    state.requestOpen();
    ui.frame();
    ui.frame();
    auto snap = remeshModalDrawSnapshot();
    assert(snap.openCalls == 1 && !state.pendingOpen,
        "one request must perform pending-open to OpenPopup exactly once");
    assert(anyPopupOpen(),
        "remesh modal request did not create a live popup");
    assert(snap.remeshMax.x > snap.remeshMin.x
        && snap.remeshMax.y > snap.remeshMin.y,
        "remesh modal did not publish a clickable Remesh button");
    assert(snap.cancelMax.x > snap.cancelMin.x
        && snap.cancelMax.y > snap.cancelMin.y,
        "remesh modal did not publish a clickable Cancel button");

    ui.frame();
    assert(remeshModalDrawSnapshot().openCalls == 1,
        "an open remesh modal repeated its OpenPopup request");

    state.pendingClose = true;
    ui.frame();
    assert(!state.pendingClose && !state.open,
        "pending success-close was not consumed by the visible modal");
    assert(!anyPopupOpen(),
        "success-close outside BeginPopupModal left the popup alive");

    state.requestOpen();
    ui.frame();
    ui.frame();
    assert(remeshModalDrawSnapshot().openCalls == 2 && anyPopupOpen(),
        "remesh modal did not reopen through a fresh one-shot handshake");
    ui.pressAt(center(snap.cancelMin, snap.cancelMax));
    ui.release();
    assert(!state.open && !anyPopupOpen(),
        "Cancel did not close both the remesh owner and popup");
}

unittest { // real draw preserves in-range values and clamps both bound sides
    Mesh probeMesh = makeGridPlane(2);
    ref Mesh provider() nothrow @nogc { return probeMesh; }

    auto state = new RemeshModalState();
    auto job = new RemeshJob();
    scope (exit) job.cancel();
    auto ui = openPanel(() {
        drawRemeshModal(state, job, cast(MeshDg) &provider);
    }, "Remesh modal bounds host");
    scope (exit) ui.close();

    state.requestOpen();
    ui.frame();
    assert(anyPopupOpen(), "bounds fixture did not open the remesh modal");

    state.targetQuads = 20_000;
    state.adaptivity = 1.0f;
    state.sharpEdge = 90.0f;
    ui.frame();
    assert(state.targetQuads == 20_000 && state.adaptivity == 1.0f
        && state.sharpEdge == 90.0f,
        "real draw changed in-range remesh values");

    state.targetQuads = MAX_REMESH_TARGET_QUADS + 1;
    state.adaptivity = 11.0f;
    state.sharpEdge = 181.0f;
    ui.frame();
    assert(state.targetQuads == MAX_REMESH_TARGET_QUADS
        && state.adaptivity == 10.0f && state.sharpEdge == 180.0f,
        "real draw did not enforce upper remesh bounds");

    state.targetQuads = MIN_REMESH_TARGET_QUADS - 1;
    state.adaptivity = -1.0f;
    state.sharpEdge = -1.0f;
    ui.frame();
    assert(state.targetQuads == MIN_REMESH_TARGET_QUADS
        && state.adaptivity == 0.0f && state.sharpEdge == 0.0f,
        "real draw did not enforce lower remesh bounds");
}

version (Posix)
unittest { // synchronous launch refusal keeps its error and popup visible
    import std.file : setAttributes, write;
    import std.process : environment;

    const savedEnv = saveHelperEnv();
    scope (exit) restoreHelperEnv(savedEnv);
    const nonExecutable = uniqueTempStem("nonexec");
    write(nonExecutable, "not executable\n");
    setAttributes(nonExecutable, 0x180); // 0600: exists, deliberately no execute bit
    scope (exit) removeIfPresent(nonExecutable);
    environment["VIBE3D_AUTOREMESHER_BIN"] = nonExecutable;

    Mesh probeMesh = makeGridPlane(2);
    ref Mesh provider() nothrow @nogc { return probeMesh; }
    auto state = new RemeshModalState();
    auto job = new RemeshJob();
    scope (exit) job.cancel();
    resetRemeshModalDrawSnapshot();
    auto ui = openPanel(() {
        drawRemeshModal(state, job, cast(MeshDg) &provider);
    }, "Remesh modal refusal host");
    scope (exit) ui.close();

    state.requestOpen();
    ui.frame();
    ui.frame();
    auto snap = remeshModalDrawSnapshot();
    assert(snap.remeshMax.x > snap.remeshMin.x
        && snap.remeshMax.y > snap.remeshMin.y,
        "refusal fixture did not publish a clickable Remesh button");
    assert(state.lastError is null && state.lastSummary is null,
        "refusal fixture began with stale result text");

    ui.pressAt(center(snap.remeshMin, snap.remeshMax));
    ui.release();
    assert(state.lastError.length > 0 && state.lastSummary is null,
        "synchronous remesher launch failure was not shown in the modal");
    assert(state.open && anyPopupOpen(),
        "remesher launch failure closed the modal instead of preserving its error");
    assert(job.state() == RemeshJob.State.failed,
        "non-executable remesher did not take the synchronous failed path");
}

version (Posix)
unittest { // Remesh resolves the current provider target at click time
    import std.file : setAttributes, write;
    import std.process : environment;

    const savedEnv = saveHelperEnv();
    scope (exit) restoreHelperEnv(savedEnv);
    const nonExecutable = uniqueTempStem("live_provider_nonexec");
    write(nonExecutable, "not executable\n");
    setAttributes(nonExecutable, 0x180);
    scope (exit) removeIfPresent(nonExecutable);
    environment["VIBE3D_AUTOREMESHER_BIN"] = nonExecutable;

    Mesh meshA = makeGridPlane(2);
    Mesh meshB = makeGridPlane(3);
    Mesh* active = &meshA;
    ref Mesh provider() nothrow @nogc { return *active; }
    auto state = new RemeshModalState();
    auto job = new RemeshJob();
    scope (exit) job.cancel();
    resetRemeshModalDrawSnapshot();
    auto ui = openPanel(() {
        drawRemeshModal(state, job, cast(MeshDg) &provider);
    }, "Remesh modal live-provider host");
    scope (exit) ui.close();

    state.requestOpen();
    ui.frame();
    ui.frame();
    auto snap = remeshModalDrawSnapshot();
    assert(snap.remeshMax.x > snap.remeshMin.x,
        "live-provider fixture did not publish its Remesh button");
    assert(!job.sourceMatches(meshA) && !job.sourceMatches(meshB),
        "live-provider fixture began with a stamped job source");

    active = &meshB;
    ui.pressAt(center(snap.remeshMin, snap.remeshMax));
    ui.release();
    assert(job.sourceMatches(meshB),
        "Remesh used the mesh captured when the popup opened, not the current provider target");
    assert(!job.sourceMatches(meshA),
        "Remesh source stamp still names the prior provider target");
}

version (Posix)
unittest { // selectedFaces reaches region mode exactly; empty means whole mesh
    import std.algorithm.searching : canFind;
    import std.conv : octal;
    import std.file : readText, setAttributes, write;
    import std.process : environment;

    void writeRecorder(string script, string argvLog, string recordedInput) {
        write(script,
            "#!/bin/sh\n"
          ~ "printf '%s\\n' \"$*\" >> \"" ~ argvLog ~ "\"\n"
          ~ "in=\"\"; out=\"\"\n"
          ~ "while [ $# -gt 0 ]; do\n"
          ~ "  case \"$1\" in\n"
          ~ "    --input) shift; in=\"$1\" ;;\n"
          ~ "    --output) shift; out=\"$1\" ;;\n"
          ~ "  esac\n"
          ~ "  shift\n"
          ~ "done\n"
          ~ "cp \"$in\" \"" ~ recordedInput ~ "\"\n"
          ~ "printf 'v 20 0 20\\nv 21 0 20\\nv 21 0 21\\nv 20 0 21\\nf 1 2 3 4\\n' > \"$out\"\n"
          ~ "exit 0\n");
        setAttributes(script, octal!755);
    }

    const savedEnv = saveHelperEnv();
    scope (exit) restoreHelperEnv(savedEnv);

    {
        const stem = uniqueTempStem("region_selected");
        const script = stem ~ ".sh";
        const argvLog = stem ~ ".argv";
        const recordedInput = stem ~ ".obj";
        scope (exit) {
            removeIfPresent(script);
            removeIfPresent(argvLog);
            removeIfPresent(recordedInput);
        }
        writeRecorder(script, argvLog, recordedInput);
        environment["VIBE3D_AUTOREMESHER_BIN"] = script;

        Mesh selected = makeGridPlane(6);
        selected.resetSelection();
        immutable size_t[] selectedFaces = [14, 15, 20, 21];
        foreach (fi; selectedFaces) selected.selectFace(cast(int) fi);
        assert(selected.hasAnySelectedFaces(),
            "region fixture did not select any faces");

        Vec3[] expected;
        foreach (fi; selectedFaces)
            foreach (vi; selected.faces.range[fi]) {
                const point = selected.vertices[vi];
                if (!containsPoint(expected, point)) expected ~= point;
            }
        assert(expected.length == 9,
            "central 2x2 region did not have the measured nine-position footprint");

        ref Mesh provider() nothrow @nogc { return selected; }
        auto state = new RemeshModalState();
        auto job = new RemeshJob();
        scope (exit) job.cancel();
        resetRemeshModalDrawSnapshot();
        auto ui = openPanel(() {
            drawRemeshModal(state, job, cast(MeshDg) &provider);
        }, "Remesh modal selected-region host");
        scope (exit) ui.close();

        state.requestOpen();
        ui.frame();
        ui.frame();
        auto snap = remeshModalDrawSnapshot();
        state.targetQuads = 33_333;
        state.adaptivity = 2.25f;
        state.sharpEdge = 47.5f;
        state.lastSummary = "stale";
        state.lastError = "stale error";
        assert(state.targetQuads == 33_333 && state.adaptivity == 2.25f
            && state.sharpEdge == 47.5f && state.lastSummary == "stale"
            && state.lastError == "stale error",
            "selected-region launch controls were not armed");
        ui.pressAt(center(snap.remeshMin, snap.remeshMax));
        ui.release();
        waitForCapture(job, recordedInput);
        const argv = readText(argvLog);
        assert(argv.length > 0 && argv.canFind("--mode"),
            "selected region did not produce populated region-mode argv");
        assert(argv.canFind("--target-quads 33333"),
            "modal target-quads state did not reach remesher argv");
        assert(argv.canFind("--adaptivity 2.25"),
            "modal adaptivity state did not reach remesher argv");
        assert(argv.canFind("--sharp-edge 47.5"),
            "modal sharp-edge state did not reach remesher argv");
        assert(state.lastSummary is null && state.lastError is null,
            "Remesh press did not clear stale result text before launch");
        const captured = readObjVertices(recordedInput);
        assert(captured.length == 9,
            "selected region did not write its nine-position compact OBJ");
        foreach (point; expected)
            assert(containsPoint(captured, point),
                "selected region OBJ does not match selectedFaces");
    }

    {
        const stem = uniqueTempStem("region_empty");
        const script = stem ~ ".sh";
        const argvLog = stem ~ ".argv";
        const recordedInput = stem ~ ".obj";
        scope (exit) {
            removeIfPresent(script);
            removeIfPresent(argvLog);
            removeIfPresent(recordedInput);
        }
        writeRecorder(script, argvLog, recordedInput);
        environment["VIBE3D_AUTOREMESHER_BIN"] = script;

        Mesh unselected = makeGridPlane(6);
        unselected.resetSelection();
        assert(!unselected.hasAnySelectedFaces(),
            "whole-mesh control unexpectedly began with a face selection");
        ref Mesh provider() nothrow @nogc { return unselected; }
        auto state = new RemeshModalState();
        auto job = new RemeshJob();
        scope (exit) job.cancel();
        resetRemeshModalDrawSnapshot();
        auto ui = openPanel(() {
            drawRemeshModal(state, job, cast(MeshDg) &provider);
        }, "Remesh modal whole-mesh host");
        scope (exit) ui.close();

        state.requestOpen();
        ui.frame();
        ui.frame();
        auto snap = remeshModalDrawSnapshot();
        ui.pressAt(center(snap.remeshMin, snap.remeshMax));
        ui.release();
        waitForCapture(job, recordedInput);
        assert(!readText(argvLog).canFind("--mode"),
            "empty selection did not use the whole-mesh remesher path");
        assert(readObjVertices(recordedInput).length == 49,
            "whole-mesh control did not write all 49 grid vertices");
    }
}

unittest { // production census: one owner, live provider, no pointer-era path
    import std.algorithm : count;
    import std.algorithm.searching : canFind;
    import std.file : dirEntries, readText, SpanMode;
    import std.path : buildPath;
    import std.string : indexOf, lastIndexOf;
    import tests.unit.census_symbols : blankNonCode;

    const root = repositoryRoot();
    const rawApp = readText(root.buildPath("source", "app.d"));
    const rawEditor = readText(root.buildPath("source", "editor_app.d"));
    const rawPanel = readText(root.buildPath("source", "ui", "panels.d"));
    const rawRegistration = readText(root.buildPath("source", "registration.d"));
    const rawMeshRegistration = readText(
        root.buildPath("source", "mesh_command_registration.d"));
    const rawProviders = readText(root.buildPath("source", "http_providers.d"));
    const app = blankNonCode(rawApp);
    const editor = blankNonCode(rawEditor);
    const panel = blankNonCode(rawPanel);
    const registration = blankNonCode(rawRegistration);
    const meshRegistration = blankNonCode(rawMeshRegistration);
    const providers = blankNonCode(rawProviders);
    const flatApp = collapseWhitespace(app);
    const flatPanel = collapseWhitespace(panel);

    size_t registrarBytes, registrarFiles;
    foreach (entry; dirEntries(root.buildPath("source"),
            "*_registration.d", SpanMode.shallow)) {
        ++registrarFiles;
        registrarBytes += readText(entry.name).length;
    }

    assert(registrarFiles >= 14,
        "6360 registrar population: the *_registration.d glob returned fewer "
      ~ "than 14 files");
    assert(rawApp.length > 430_000 && rawEditor.length > 45_000
        && rawPanel.length > 130_000
        && rawRegistration.length + registrarBytes > 110_000
        && rawProviders.length > 130_000,
        "6360 source population: a censused production file shrank unexpectedly");

    size_t sourceFiles;
    string allSource;
    foreach (entry; dirEntries(root.buildPath("source"), "*.d", SpanMode.depth)) {
        ++sourceFiles;
        allSource ~= blankNonCode(readText(entry.name));
    }
    assert(sourceFiles >= 561,
        "6360 source population: fewer than the measured 561 D modules");

    assert(app.count("auto remeshModalState = new RemeshModalState();") == 1
        && allSource.count("new RemeshModalState()") == 1,
        "6360 production owner: main must allocate exactly one RemeshModalState");
    assert(app.count("app.remeshModalState") == 1
        && flatApp.count("app.remeshModalState = remeshModalState;") == 1
        && app.count("drawRemeshModal(remeshModalState, remeshJob, app.meshDg);") == 1,
        "6360 app wiring: EditorApp and draw must receive main's owner once");
    assert(registration.count("&remeshModalState.requestOpen") == 1
        && meshRegistration.count("deps.requestRemeshOpen()") == 1,
        "6360 registration writer: mesh.remesh.open stopped using the shared owner");
    assert(providers.count("remeshModalState.open") == 1,
        "6360 diagnostics reader: modal state is missing or duplicated");

    assert(flatPanel.count(
        "void drawRemeshModal(RemeshModalState state, RemeshJob remeshJob, MeshDg currentMesh) {") == 1
        && allSource.count("drawRemeshModal(EditorApp") == 0,
        "6360 panel signature: draw must accept state, job and live mesh provider only");
    assert(app.count("auto cmd = cast(Remesh) reg.commandFactories[") == 1
        && panel.count("auto cmd = cast(Remesh) reg.commandFactories[") == 0,
        "6360 apply boundary: result application escaped tickRemeshJob");
    assert(app.count("remeshModalState.noteSuccess(") == 1
        && app.count("remeshModalState.noteFailure(") == 3,
        "6360 poll continuation: success/failure publication counts changed");
    assert(app.count("            tickRemeshJob();") == 1
        && app.indexOf("            tickRemeshJob();")
            < app.indexOf("drawRemeshModal(remeshModalState, remeshJob, app.meshDg);"),
        "6360 frame order: remesh polling must remain before modal drawing");

    const drawAt = panel.indexOf("void drawRemeshModal(");
    const beginAt = panel.indexOf("if (ImGui.BeginPopupModal(", drawAt);
    const closeAt = panel.indexOf("if (consumePendingClose())", drawAt);
    const endAt = panel.indexOf("ImGui.EndPopup();", beginAt);
    assert(beginAt >= 0 && closeAt > beginAt && endAt > closeAt,
        "6360 popup handshake: pending-close consumption escaped BeginPopupModal");

    // The widget LABELS cannot be censused: `blankNonCode` blanks string
    // literals as well as comments, so every token here is code. The order
    // matters behaviourally — a value a slider wrote this frame has to be
    // clamped in the SAME frame, which is the one thing collapsing six inline
    // clamps into one call could break, and no cell can see it (the widgets
    // clamp their own drag gesture, so a hoisted call still looks right).
    const drawEnd = panel.indexOf("version (unittest)", drawAt);
    assert(drawEnd > drawAt,
        "6360 slider order: drawRemeshModal body boundary was not found");
    const drawBody = panel[drawAt .. drawEnd];
    assert(drawBody.count("ImGui.SliderInt(") == 1
        && drawBody.count("ImGui.SliderFloat(") == 2
        && drawBody.count("clampToBounds();") == 1
        && drawBody.count("&targetQuads") == 1
        && drawBody.count("&adaptivity") == 1
        && drawBody.count("&sharpEdge") == 1,
        "6360 slider order: expected three sliders, three field pointers, one clamp");
    const targetSliderAt = drawBody.indexOf("ImGui.SliderInt(");
    const firstFloatAt = drawBody.indexOf("ImGui.SliderFloat(");
    const lastFloatAt = drawBody.lastIndexOf("ImGui.SliderFloat(");
    const clampAt = drawBody.indexOf("clampToBounds();");
    assert(targetSliderAt >= 0 && firstFloatAt > targetSliderAt
        && lastFloatAt > firstFloatAt && clampAt > lastFloatAt,
        "6360 slider order: clampToBounds must run after all three sliders");
    // Each slider must still address its OWN field: the two float sliders have
    // the same signature, so swapping their pointers compiles and the argv cell
    // above cannot see it (it writes the state fields directly).
    assert(drawBody.indexOf("&targetQuads") > targetSliderAt
        && drawBody.indexOf("&targetQuads") < firstFloatAt
        && drawBody.indexOf("&adaptivity") > firstFloatAt
        && drawBody.indexOf("&adaptivity") < lastFloatAt
        && drawBody.indexOf("&sharpEdge") > lastFloatAt
        && drawBody.indexOf("&sharpEdge") < clampAt,
        "6360 slider binding: a slider stopped addressing its own state field");

    foreach (retired; ["RemeshModalRefs", "remeshRefs",
             "remeshModalOpenPtr", "remeshModalPendingOpenPtr",
             "remeshModalPendingClosePtr", "remeshTargetQuadsPtr",
             "remeshAdaptivityPtr", "remeshSharpEdgePtr",
             "remeshLastErrorPtr", "remeshLastSummaryPtr"])
        assert(!allSource.canFind(retired),
            "6360 retired pointer storage returned: " ~ retired);

    foreach (retiredLocal; ["bool remeshModalOpen;",
             "bool remeshModalPendingOpen;", "bool remeshModalPendingClose;",
             "int remeshTargetQuads = 20_000;",
             "float remeshAdaptivity = 1.0f;",
             "float remeshSharpEdge = 90.0f;", "string remeshLastError;",
             "string remeshLastSummary;"])
        assert(!flatApp.canFind(retiredLocal),
            "6360 retired main-local modal storage returned: " ~ retiredLocal);

    assert(editor.count("RemeshModalState remeshModalState;") == 1,
        "6360 EditorApp keeper: shared state reference is missing or duplicated");
}
