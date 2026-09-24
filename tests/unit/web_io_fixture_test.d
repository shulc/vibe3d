// Task 7420 (web file I/O S2): the desktop oracle of the browser lane's
// fixtures. The REAL `file.load` and `file.save` factories (the same FileLoad
// -> FileSave path the browser drives) re-derive `two_layers.resave.v3d` from
// `two_layers.v3d` on every run, so the bytes the browser download is compared
// with (cell C4) are checked by production commands, and the counts the lane
// waits for (`const V = …, F = …` in tools/web_file_io/case_v3d.mjs) are read
// from that file and compared with what the load produced.
module tests.unit.web_io_fixture_test;

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
    import io.doc_state : clearCurrentDoc, requestDocRebaseline;

    const fixtures = buildPath(repoRoot, "tests", "fixtures", "web_io");
    const source = buildPath(fixtures, "two_layers.v3d");
    const resave = buildPath(fixtures, "two_layers.resave.v3d");
    const scratch = buildPath(tempDir(), format("vibe3d_7420_fixture_%d", thisProcessID()));
    if (exists(scratch)) rmdirRecurse(scratch);
    mkdirRecurse(scratch);
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

    auto load = cast(FileLoad) reg.makeCommand("file.load");
    load.setPath(source);
    assert(load.apply(), "7420 oracle: file.load of two_layers.v3d refused: "
        ~ load.refusalReason());

    size_t verts, faces;
    foreach (l; session.document.layers)
        if (auto m = l.meshOrNull()) {
            verts += m.vertices.length;
            faces += m.faces.length;
        }
    // Floors: two layers, and not the default cube.
    assert(session.document.layers.length == 2,
        format("7420 oracle: expected 2 layers, got %d", session.document.layers.length));
    assert(verts > 8, format("7420 oracle: verts %d is the default cube or less", verts));

    // The lane's literals are this load's counts.
    const lane = readText(buildPath(repoRoot, "tools", "web_file_io", "case_v3d.mjs"));
    auto m = lane.matchFirst(regex(`const V = (\d+), F = (\d+);`));
    assert(!m.empty, "7420 oracle: case_v3d.mjs no longer declares `const V = …, F = …;`");
    assert(m[1].to!size_t == verts && m[2].to!size_t == faces,
        format("7420 oracle: the browser lane waits for verts=%s faces=%s, the desktop load "
             ~ "of two_layers.v3d gives verts=%d faces=%d", m[1], m[2], verts, faces));

    const outPath = buildPath(scratch, "two_layers.resave.v3d");
    auto save = cast(FileSave) reg.makeCommand("file.save");
    save.setPath(outPath);
    assert(save.apply(), "7420 oracle: file.save refused: " ~ save.refusalReason());
    const written = cast(const(ubyte)[]) read(outPath);
    const expected = cast(const(ubyte)[]) read(resave);
    assert(written.length > 0, "7420 oracle: the resave wrote nothing");
    assert(written == expected,
        format("7420 oracle: file.load -> file.save of two_layers.v3d wrote %d bytes that "
             ~ "differ from tests/fixtures/web_io/two_layers.resave.v3d (%d bytes); "
             ~ "regenerate with tools/web_file_io/make_fixtures.sh and read the diff",
               written.length, expected.length));

    // The broken-file fixture is the first 200 bytes of the source.
    const truncated = cast(const(ubyte)[]) read(buildPath(fixtures, "truncated.v3d"));
    const whole = cast(const(ubyte)[]) read(source);
    assert(truncated.length == 200 && truncated == whole[0 .. 200],
        "7420 oracle: truncated.v3d is not the first 200 bytes of two_layers.v3d");
}
