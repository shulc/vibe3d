// Source boundary for task 5110. The two change-classification consumers may
// depend on mesh_edit_delta, but must not import the display upload service.
module tests.unit.display_refresh_mask_boundary_test;

import std.file   : dirEntries, readText, SpanMode;
import std.format : format;
import std.path   : buildPath, dirName;
import std.string : indexOf;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum string[] kBoundaryFiles = [
    "source/mesh_edit_delta.d",
    "source/mesh_dirty.d",
];

private bool isIdentChar(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private size_t countWord(string code, string word)
{
    size_t found;
    size_t pos;
    while (pos < code.length) {
        const rel = code[pos .. $].indexOf(word);
        if (rel < 0) break;
        const at = pos + cast(size_t) rel;
        const before = at == 0 || !isIdentChar(code[at - 1]);
        const after = at + word.length == code.length
            || !isIdentChar(code[at + word.length]);
        if (before && after) ++found;
        pos = at + word.length;
    }
    return found;
}

private size_t countOccurrences(string code, string needle)
{
    size_t found;
    size_t pos;
    while (pos < code.length) {
        const rel = code[pos .. $].indexOf(needle);
        if (rel < 0) break;
        ++found;
        pos += cast(size_t) rel + needle.length;
    }
    return found;
}

unittest // change classifiers do not depend on the display upload service
{
    size_t sourceFiles;
    size_t definitions;
    foreach (de; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++sourceFiles;
        definitions += countOccurrences(blankNonCode(readText(de.name)),
                                        "enum uint DisplayRefreshMask");
    }

    // POPULATION FLOORS precede the definition and forbidden-edge checks.
    assert(sourceFiles >= 500,
        format("display refresh boundary scanned only %d source files", sourceFiles));
    assert(kBoundaryFiles.length == 2,
        format("display refresh boundary roster has %d files; expected 2",
               kBoundaryFiles.length));

    assert(definitions == 1,
        format("DisplayRefreshMask has %d source definitions; expected exactly 1",
               definitions));
    foreach (relative; kBoundaryFiles) {
        immutable code = blankNonCode(readText(buildPath(repoRoot, relative)));
        const forbidden = countWord(code, "display_sync");
        assert(forbidden == 0,
            format("display refresh boundary: %s references display_sync %d time(s)",
                   relative, forbidden));
    }
}
