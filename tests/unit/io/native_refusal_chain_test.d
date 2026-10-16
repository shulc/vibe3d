module tests.unit.io.native_refusal_chain_test;

import std.file : exists, write, tempDir, mkdirRecurse, rmdirRecurse;
import std.path : buildPath;
import std.format : format;
import vibe3d.documents.model.document : Document;
import io.native : kV3dFormatVersion;

// The desktop FileLoad refusal chain retains its original codec fixture.
private string v3dTestDir(string tag) {
    auto d = buildPath(tempDir(), "vibe3d_v3d8_" ~ tag);
    if (exists(d)) rmdirRecurse(d);
    mkdirRecurse(d);
    return d;
}

unittest {
    import vibe3d.mesh.core.mesh : makeCube;
    import std.algorithm : canFind;
    import commands.file.load : FileLoad;
    import vibe3d.viewport.camera.view     : View;
    import vibe3d.editing.contracts.editmode : EditMode;

    auto root = v3dTestDir("refusal_chain");
    enum string tri = `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}`;
    auto oldPath  = buildPath(root, "written-by-an-older-build.v3d");
    auto goodPath = buildPath(root, "current.v3d");
    write(oldPath, format(
        `{"formatVersion":7,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"M"},%s}]}`, tri));
    write(goodPath, format(
        `{"formatVersion":%d,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"M"},%s}]}`,
        kV3dFormatVersion, tri));

    auto doc  = Document.bootstrap(makeCube());
    auto view = new View(0, 0, 800, 600);
    auto cmd  = new FileLoad(doc.activeMesh(), view, EditMode.Vertices, &doc);

    cmd.setPath(oldPath);
    assert(!cmd.apply(), "a pre-v8 document does not load");
    auto why = cmd.refusalReason();
    assert(why.canFind("format version 7") && why.canFind("version 8")
        && why.canFind("not damaged"),
        "the command carries the READER's sentence, not a generic 'could not "
      ~ "open'. Got: " ~ why);
    assert(why.canFind("written-by-an-older-build.v3d"),
        "…and names WHICH file, because a modal dialog has no other context "
      ~ "about what the user just double-clicked. Got: " ~ why);

    // The same object, applied again on a file that loads: the reason must be
    // gone. A command object is applied more than once (redo, re-dispatch).
    cmd.setPath(goodPath);
    assert(cmd.apply(), "control: the current version loads through the same "
      ~ "command object");
    assert(cmd.refusalReason() == "",
        "a successful apply() clears the reason; a stale one raises a dialog "
      ~ "over a document that opened fine. Got: " ~ cmd.refusalReason());
}
