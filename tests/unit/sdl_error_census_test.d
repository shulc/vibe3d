// Keep SDL's borrowed C error pointer behind the one conversion seam added by
// task 5503. A direct SDL_GetError use in any other source file can reach a D
// formatter and print the pointer value instead of the diagnostic text.
module tests.unit.sdl_error_census_test;

import std.algorithm : sort;
import std.file      : dirEntries, exists, readText, SpanMode;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.string    : indexOf, splitLines;

import tests.unit.census_symbols : blankNonCode, isIdentChar;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum needle = "SDL_GetError";
private enum owner = "source/sdl_error.d";

private struct Hit
{
    string file;
    size_t line;
}

private Hit[] scanText(string file, string raw)
{
    Hit[] hits;
    const code = blankNonCode(raw);
    foreach (li, line; code.splitLines)
    {
        size_t from;
        while (from + needle.length <= line.length)
        {
            const offset = line[from .. $].indexOf(needle);
            if (offset < 0) break;
            const pos = from + cast(size_t) offset;
            const end = pos + needle.length;
            if ((pos == 0 || !isIdentChar(line[pos - 1]))
                && (end == line.length || !isIdentChar(line[end])))
                hits ~= Hit(file, li + 1);
            from = end;
        }
    }
    return hits;
}

private Hit[] scanSource()
{
    const sourceRoot = buildPath(repoRoot, "source");
    assert(sourceRoot.exists,
        "SDL_GetError census cannot find source/; an empty walk is not green");

    Hit[] hits;
    foreach (entry; dirEntries(sourceRoot, "*.d", SpanMode.depth))
        hits ~= scanText(entry.name[repoRoot.length + 1 .. $],
                         readText(entry.name));
    sort!((a, b) => a.file == b.file ? a.line < b.line : a.file < b.file)(hits);
    return hits;
}

unittest
{
    // The shared lexer must keep a real call while removing both comment and
    // string decoys. The line-preserving projection keeps diagnostics useful.
    const probe = scanText("probe.d",
        "void f() { SDL_GetError(); }\n"
      ~ "// SDL_GetError()\n"
      ~ "enum text = \"SDL_GetError()\";\n");
    assert(probe == [Hit("probe.d", 1)],
        "SDL_GetError census must count code and ignore comments/strings");

    const hits = scanSource();

    // POPULATION FLOOR: without this, "every hit belongs to owner" is
    // vacuously true after the helper or its SDL symbol is renamed.
    assert(hits.length > 0, format(
        "task 5503: SDL_GetError census found %d CODE occurrence(s); the "
      ~ "single-owner predicate is VACUOUSLY TRUE over an empty population",
        hits.length));

    string[] files;
    string[] locations;
    foreach (hit; hits)
    {
        if (files.length == 0 || files[$ - 1] != hit.file)
            files ~= hit.file;
        locations ~= format("%s:%d", hit.file, hit.line);
    }

    assert(files == [owner], format(
        "task 5503: SDL_GetError must occur in exactly %s; found files: "
      ~ "%-(%s, %)\nCODE occurrences:%-(\n    %s%)\n"
      ~ "Route every SDL diagnostic through sdlError().",
        owner, files, locations));
}
