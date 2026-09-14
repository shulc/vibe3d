// Active tools leave Escape to the editor-level ladder. This census keeps
// executable tool handlers from reclaiming that key (task 5911, EL-c).
module tests.unit.escape_ladder_test;

import std.array : appender;
import std.algorithm.searching : canFind;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.path : buildPath, dirName, relativePath;
import tests.unit.census_symbols : blankNonCode, countOccurrences;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

unittest { // EL-c: tool key handlers do not consume Escape.
    const toolsRoot = buildPath(repoRoot, "source", "tools");
    size_t files, createFiles, sliceFiles, keyHandlers, escapeSites;
    auto offenders = appender!string;

    foreach (entry; dirEntries(toolsRoot, "*.d", SpanMode.depth)) {
        ++files;
        const rel = relativePath(entry.name, toolsRoot);
        if (rel.canFind("create/")) ++createFiles;
        if (rel.canFind("slice/")) ++sliceFiles;

        const code = blankNonCode(readText(entry.name));
        keyHandlers += countOccurrences(code, "override bool onKeyDown");
        const hits = countOccurrences(code, "SDLK_ESCAPE");
        if (hits) {
            escapeSites += hits;
            offenders.put(format("\n  %s: %s", rel, hits));
        }
    }

    assert(files > 30 && createFiles >= 1 && sliceFiles >= 1,
        format("EL-c: source/tools census is under-populated: files=%s create=%s slice=%s",
            files, createFiles, sliceFiles));
    assert(keyHandlers >= 4,
        format("EL-c: found only %s override bool onKeyDown handlers", keyHandlers));
    assert(escapeSites == 0,
        format("EL-c: active tools must not consume SDLK_ESCAPE; found %s site(s):%s",
            escapeSites, offenders.data));
}
