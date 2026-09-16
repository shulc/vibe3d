module tests.unit.subpatch_hash_seed_census_test;

import std.array : appender;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName;
import std.regex : ctRegex, matchAll;
import std.range : walkLength;
import std.string : splitLines;
import tests.unit.census_symbols : blankNonCode, enclosingSymbols, symbolAt;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum seededHashRe = ctRegex!(`hashOf\(.*,\s*\w+\)`);

private struct Hit
{
    string file;
    size_t line;
    string symbol;
}

private Hit[] scanSeededHashes(string file, string source)
{
    const code = blankNonCode(source);
    const symbols = enclosingSymbols(code);
    auto hits = appender!(Hit[]);
    foreach (i, line; code.splitLines)
        if (line.matchAll(seededHashRe).walkLength != 0)
            hits.put(Hit(file, i + 1, symbolAt(symbols, i)));
    return hits.data;
}

unittest // the defect-shaped regex sees code and rejects comment/string decoys
{
    enum fixture = q{
        void compute() {
            ulong h;
            h = hashOf(values, h);
            // h = hashOf(commented, h);
            enum quoted = "h = hashOf(quoted, h);";
        }
    };
    const hits = scanSeededHashes("fixture.d", fixture);
    assert(hits.length == 1,
        format("seeded-hash positive control found %d sites, expected one", hits.length));
    assert(hits[0].symbol == "compute",
        format("seeded-hash positive control landed in `%s`", hits[0].symbol));
}

unittest // every production array-plus-seed hash stays in the reviewed stencil key
{
    auto hits = appender!(Hit[]);
    size_t sourceFiles;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d", SpanMode.depth)) {
        ++sourceFiles;
        const relative = entry.name[repoRoot.length + 1 .. $];
        hits.put(scanSeededHashes(relative, readText(entry.name)));
    }
    const found = hits.data;
    assert(sourceFiles >= 548,
        format("seeded-hash census scanned only %d source files", sourceFiles));
    assert(found.length >= 8,
        format("seeded-hash census population collapsed to %d hits", found.length));
    assert(found.length == 8,
        format("seeded-hash census found %d sites, expected exactly 8: %s",
               found.length, found));
    foreach (hit; found)
        assert(hit.file == "source/subpatch_preview.d"
            && hit.symbol == "SubpatchPreview.computeStencilKey",
            format("unreviewed seeded hash at %s:%d in `%s`",
                   hit.file, hit.line, hit.symbol));
}
