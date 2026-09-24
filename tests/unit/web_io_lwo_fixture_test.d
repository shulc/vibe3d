// Task 7440 (web file I/O S3): the desktop oracle of the browser lane's LWO
// fixtures. The REAL `file.load` and `file.export.lwo` factories (the FileLoad
// -> FileSave path the browser drives) re-derive `two_parts.export.lwo` from
// `two_parts.lwo`, `cube.export.lwo` from its undo and `two_parts.lwo` from
// `two_layers.v3d` on every run, so the bytes the browser download is compared
// with (cell L3 of tools/web_file_io/case_lwo.mjs) are checked by production
// commands; the counts the lane waits for (`const V = …, F = …`) are this
// load's; undo/redo of the import and the broken-file refusal are pinned here
// as the desktop behaviour the browser cells must reproduce.
module tests.unit.web_io_lwo_fixture_test;

import std.conv : to;
import std.file : exists, mkdirRecurse, read, readText, rmdirRecurse, tempDir;
import std.format : format;
import std.path : buildPath, dirName;
import std.process : thisProcessID;
import std.regex : matchFirst, regex;

import commands.file.load : FileLoad;
import commands.file.save : FileSave;
import file_io_registration : registerFileIoCommands;
import live_registration_roles : LiveSessionRole, LiveView, LiveViewModeRole;
import mesh : makeCube;
import registry : Registry;
import session_owner : Session;
import view : View;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest {
    import io.doc_state : clearCurrentDoc, hasCurrentDoc, requestDocRebaseline;

    const fixtures = buildPath(repoRoot, "tests", "fixtures", "web_io");
    const source = buildPath(fixtures, "two_parts.lwo");
    const exported = buildPath(fixtures, "two_parts.export.lwo");
    const broken = buildPath(fixtures, "truncated.lwo");
    const cubeExported = buildPath(fixtures, "cube.export.lwo");
    const layersV3d = buildPath(fixtures, "two_layers.v3d");
    const scratch = buildPath(tempDir(), format("vibe3d_7440_fixture_%d", thisProcessID()));
    if (exists(scratch)) rmdirRecurse(scratch);
    mkdirRecurse(scratch);
    clearCurrentDoc();
    scope (exit) {
        if (exists(scratch)) rmdirRecurse(scratch);
        clearCurrentDoc();
        requestDocRebaseline();
    }

    auto session = Session.bootstrap(makeCube());
    auto camera = new View(0, 0, 800, 600);
    ref View liveView() { return camera; }
    Registry reg;
    registerFileIoCommands(reg, LiveSessionRole(session),
        LiveViewModeRole(cast(LiveView)&liveView, session.editModePtr()));

    size_t[3] counts() {
        size_t verts, faces;
        foreach (l; session.document.layers)
            if (auto m = l.meshOrNull()) {
                verts += m.vertices.length;
                faces += m.faces.length;
            }
        return [session.document.layers.length, verts, faces];
    }
    // The browser probe page starts from a SUBPATCH cube (app.d marks every
    // face under `webFirstFrameProbe`), and cube.export.lwo is that cube's
    // export (a PTCH chunk), so the oracle starts from the same marking.
    // (syncSelection first: a fresh makeCube has no face marks to set yet.)
    {
        auto cube = session.document.layers[0].meshOrNull();
        cube.syncSelection();
        foreach (fi; 0 .. cube.faces.length) cube.setSubpatch(fi, true);
        assert(cube.isFaceSubpatch(0) && cube.isFaceSubpatch(5),
            "7440 oracle: the start cube did not take the subpatch marks");
    }
    const start = counts();
    assert(start == [1, 8, 6], format("7440 oracle: the start is not the default cube: %s", start));

    auto load = cast(FileLoad) reg.makeCommand("file.load");
    load.setPath(source);
    assert(load.apply(), "7440 oracle: file.load of two_parts.lwo refused: "
        ~ load.refusalReason());
    const loaded = counts();
    // Floors: two layers (two LAYR chunks), and not the default cube.
    assert(loaded[0] == 2,
        format("7440 oracle: expected 2 layers from two_parts.lwo, got %d", loaded[0]));
    assert(loaded[1] > 8, format("7440 oracle: verts %d is the default cube or less", loaded[1]));
    // An interchange import leaves the document untitled (cell L1: docPath=).
    assert(!hasCurrentDoc(), "7440 oracle: the LWO import gave the document a path");

    // The lane's literals are this load's counts.
    const lane = readText(buildPath(repoRoot, "tools", "web_file_io", "case_lwo.mjs"));
    auto m = lane.matchFirst(regex(`const V = (\d+), F = (\d+);`));
    assert(!m.empty, "7440 oracle: case_lwo.mjs no longer declares `const V = …, F = …;`");
    assert(m[1].to!size_t == loaded[1] && m[2].to!size_t == loaded[2],
        format("7440 oracle: the browser lane waits for verts=%s faces=%s, the desktop load "
             ~ "of two_parts.lwo gives verts=%d faces=%d", m[1], m[2], loaded[1], loaded[2]));

    // Export > LWO of the imported document: the bytes the browser downloads.
    const outPath = buildPath(scratch, "Untitled.lwo");
    auto save = cast(FileSave) reg.makeCommand("file.export.lwo");
    save.setPath(outPath);
    assert(save.apply(), "7440 oracle: file.export.lwo refused: " ~ save.refusalReason());
    assert(!hasCurrentDoc(), "7440 oracle: the LWO export gave the document a path");
    const written = cast(const(ubyte)[]) read(outPath);
    const expected = cast(const(ubyte)[]) read(exported);
    assert(written.length > 0, "7440 oracle: the export wrote nothing");
    assert(written == expected,
        format("7440 oracle: file.load -> file.export.lwo of two_parts.lwo wrote %d bytes that "
             ~ "differ from tests/fixtures/web_io/two_parts.export.lwo (%d bytes); "
             ~ "regenerate with tools/web_file_io/make_fixtures.sh and read the diff",
               written.length, expected.length));

    // Undo returns the cube, redo the two parts (cells L2 / L2r).
    assert(load.revert(), "7440 oracle: the LWO import did not revert");
    assert(counts() == start,
        format("7440 oracle: undo of the LWO import gives %s, not the cube %s", counts(), start));

    // Export > LWO of the LIVE document after the undo (cell L3b): the cube,
    // byte-equal to cube.export.lwo and NOT two_parts.lwo — an export that wrote
    // the scene as loaded would pass the L3 comparison above, since two_parts.lwo
    // and its re-export are the same bytes.
    const cubePath = buildPath(scratch, "Untitled.cube.lwo");
    auto saveCube = cast(FileSave) reg.makeCommand("file.export.lwo");
    saveCube.setPath(cubePath);
    assert(saveCube.apply(), "7440 oracle: file.export.lwo of the cube refused: "
        ~ saveCube.refusalReason());
    const cubeWritten = cast(const(ubyte)[]) read(cubePath);
    const cubeExpected = cast(const(ubyte)[]) read(cubeExported);
    assert(cubeExpected != cast(const(ubyte)[]) read(source),
        "7440 oracle: cube.export.lwo equals two_parts.lwo, so cell L3b cannot tell the live "
        ~ "document from the scene as loaded");
    assert(cubeWritten == cubeExpected,
        format("7440 oracle: undo -> file.export.lwo wrote %d bytes that differ from "
             ~ "tests/fixtures/web_io/cube.export.lwo (%d bytes); regenerate with "
             ~ "tools/web_file_io/make_fixtures.sh and read the diff",
               cubeWritten.length, cubeExpected.length));
    assert(load.apply(), "7440 oracle: redo of the LWO import refused: " ~ load.refusalReason());
    assert(counts() == loaded,
        format("7440 oracle: redo of the LWO import gives %s, not %s", counts(), loaded));

    // The broken file (cell L4): the first 60 bytes of two_parts.lwo — a valid
    // FORM/LWO2 header whose first PNTS chunk is cut. The reader rejects it
    // ("no usable geometry") and the command refuses WITHOUT a reason, the same
    // silence as a cancelled chooser — that is today's desktop behaviour, and
    // the browser cell asserts the same (no WEB-NOTICE). Giving the refusal a
    // sentence changes both, together.
    const truncated = cast(const(ubyte)[]) read(broken);
    const whole = cast(const(ubyte)[]) read(source);
    assert(truncated.length == 60 && truncated == whole[0 .. 60],
        "7440 oracle: truncated.lwo is not the first 60 bytes of two_parts.lwo");
    auto bad = cast(FileLoad) reg.makeCommand("file.load");
    bad.setPath(broken);
    assert(!bad.apply(), "7440 oracle: file.load accepted truncated.lwo");
    assert(bad.refusalReason() == "",
        format("7440 oracle: pinned KNOWN DEFECT (backlog 7303): silent LWO refusal — the "
             ~ "refusal now speaks (%s); the browser cell L4 asserts no WEB-NOTICE — update "
             ~ "both", bad.refusalReason()));
    assert(counts() == loaded,
        format("7440 oracle: a refused LWO load changed the document: %s", counts()));

    // The link from the .v3d fixture to the LWO one: two_layers.v3d loaded and
    // exported with file.export.lwo re-derives two_parts.lwo byte for byte.
    auto loadV3d = cast(FileLoad) reg.makeCommand("file.load");
    loadV3d.setPath(layersV3d);
    assert(loadV3d.apply(), "7440 oracle: file.load of two_layers.v3d refused: "
        ~ loadV3d.refusalReason());
    const partsPath = buildPath(scratch, "two_parts.lwo");
    auto saveParts = cast(FileSave) reg.makeCommand("file.export.lwo");
    saveParts.setPath(partsPath);
    assert(saveParts.apply(), "7440 oracle: file.export.lwo of two_layers.v3d refused: "
        ~ saveParts.refusalReason());
    const partsWritten = cast(const(ubyte)[]) read(partsPath);
    assert(partsWritten == whole,
        format("7440 oracle: two_layers.v3d -> file.export.lwo wrote %d bytes that differ from "
             ~ "tests/fixtures/web_io/two_parts.lwo (%d bytes); regenerate with "
             ~ "tools/web_file_io/make_fixtures.sh and read the diff",
               partsWritten.length, whole.length));
}

// Census (plan S3 item 4): the probe door the browser cells use stands in for
// the menu rows, so the rows must carry exactly the ids the cells dispatch
// (`page('file.export.lwo', …)` and `page('file.import.lwo', …)` in
// case_lwo.mjs). What stays unwitnessed is the menu HIT itself. And the lane
// runs the LWO case once per artifact mode, inside the mode loop.
unittest {
    import std.algorithm.searching : count, countUntil;

    const buttons = readText(buildPath(repoRoot, "config", "buttons.yaml"));
    const cases = readText(buildPath(repoRoot, "tools", "web_file_io", "case_lwo.mjs"));
    foreach (id; ["file.import.lwo", "file.export.lwo"]) {
        assert(buttons.count(`id: "` ~ id ~ `"`) == 1,
            "7440 census: config/buttons.yaml must carry exactly one menu row with id " ~ id);
        assert(cases.count(`await page('` ~ id ~ `', `) == 1,
            "7440 census: case_lwo.mjs must dispatch " ~ id ~ " through exactly one page");
    }

    const lane = readText(buildPath(repoRoot, "tools", "test_web_file_io.sh"));
    // The WHOLE line, from its indentation: a prefix such as `true || ` in front
    // of the node call would keep a substring pin green while the case never runs.
    const call = "\n    timeout 240 node \"$repo_root/tools/web_file_io/case_lwo.mjs\" \\\n";
    assert(lane.count(call) == 1,
        "7440 census: tools/test_web_file_io.sh must run case_lwo.mjs exactly once");
    const loop = lane.countUntil("for mode in normal spreset; do");
    const at = lane.countUntil(call);
    assert(loop >= 0 && at > loop && lane[loop .. at].count("\ndone") == 0,
        "7440 census: case_lwo.mjs must run inside the `for mode in normal spreset` loop");

    // The lane counts the cells that PRINTED ok, per mode, against the full
    // list; a summary the case writes about itself cannot see a disabled cell.
    const expectedCells = `[[ $lwo_cells != "L0 L1 L2 L2r L3 L3b L4 L5 " ]]`;
    const check = lane.countUntil(expectedCells);
    assert(lane.count(expectedCells) == 1 && check > at && lane[at .. check].count("\ndone") == 0,
        "7440 census: tools/test_web_file_io.sh must check the eight LWO cell lines inside the mode loop");
    foreach (cell; ["L0", "L1", "L2", "L2r", "L3", "L3b", "L4", "L5"])
        assert(cases.count("ok('" ~ cell ~ "', ") == 1,
            "7440 census: case_lwo.mjs must report cell " ~ cell ~ " exactly once");
}
