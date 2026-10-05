// Tools own no VAO (task 9442): the overlay lines a tool draws (Move's
// constraint line, Radial Sweep's axis, Mirror's plane quad and dashed normal)
// go through `handles/gl_util.d : drawWorldSegments`, which owns the one
// dynamic buffer. Raw-text census of `source/tools/**`: the GL object
// lifecycle identifiers occur 0 times (before task 9442: glGenVertexArrays in
// 3 files, 4 sites), beside a floor — the files CALLING `drawWorldSegments(`
// are exactly the three drawers' files. Raw text, comments included: a
// mention of a lifecycle identifier fails closed.
module tests.unit.tool_overlay_vao_census_test;

import std.algorithm : sort;
import std.file      : SpanMode, dirEntries, readText;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.regex     : matchFirst, regex;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private bool names(string text, string ident) {
    return !matchFirst(text, regex(`\b` ~ ident ~ `\b`)).empty;
}

private immutable string[] kLifecycle = [
    "glGenVertexArrays", "glDeleteVertexArrays", "glGenBuffers", "glDeleteBuffers",
];

unittest {
    // Local positive control: the matcher finds the identifiers in the home.
    auto home = readText(buildPath(repoRoot, "source/handles/gl_util.d"));
    foreach (id; ["glGenVertexArrays", "glGenBuffers", "drawWorldSegments"])
        assert(names(home, id), format("control: gl_util.d must name %s", id));

    string[] callers, owners;
    foreach (de; dirEntries(buildPath(repoRoot, "source/tools"), "*.d", SpanMode.depth)) {
        immutable rel = de.name[repoRoot.length + 1 .. $];
        immutable text = readText(de.name);
        if (!matchFirst(text, regex(`\bdrawWorldSegments\s*\(`)).empty) callers ~= rel;
        foreach (id; kLifecycle)
            if (names(text, id)) owners ~= format("%s (%s)", rel, id);
    }
    sort(callers);
    // Floor: the three drawers, and only they.
    assert(callers == ["source/tools/alignment/mirror.d",
                       "source/tools/alignment/radial_sweep_tool.d",
                       "source/tools/transform/move.d"],
           format("drawWorldSegments callers in source/tools: %s", callers));
    // Needle: no tool creates or deletes a GL vertex array or buffer.
    assert(owners.length == 0,
           format("source/tools owns GL objects (draw through gl_util instead): %s", owners));
}

// The contract half the census cannot see: the primitive takes PAIRS, and an
// odd point count is refused rather than silently dropping its last point.
unittest {
    import core.exception : AssertError;
    import std.exception  : assertThrown, assertNotThrown;
    import handles.gl_util : drawWorldSegments;
    import math : Vec3, Viewport;
    Viewport vp;
    Vec3[3] odd;
    assertNotThrown!AssertError(drawWorldSegments(odd[0 .. 2], vp, Vec3(1, 1, 1), 1.0f, 0));
    assertThrown!AssertError(drawWorldSegments(odd[], vp, Vec3(1, 1, 1), 1.0f, 0));
}
