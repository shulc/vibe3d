// command_winding_write_census_test — task 1903 Stage L2-c.
//
// NO COMMAND MAY WRITE A FACE WINDING BY HAND.
//
// WHY THIS CENSUS EXISTS AND WHY IT IS A NEW ZONE. §5.3's "other audit" — six
// rows, three revisions — enumerates the raw `faces._store = …` / `faces = …` /
// `faces[fi] = …` sites that reach no op-log hook, and its needle scans
// `source/mesh.d` and `source/mesh_ops/**`. It NEVER LOOKED IN
// `source/commands/**`. `mesh.split_edge` carried its own open-coded splice
// (`face = face[0 .. k + 1] ~ vm ~ face[k + 1 .. $]`) inside `evaluate` for the
// whole life of that audit, and no row named it; the audit's own claim to be
// exhaustive was true only of the directories it walked. Stage L2-P0 rerouted
// that splice through `Mesh.addEdgePoint`; this census is what stops the shape
// coming back somewhere the other audit still cannot see.
//
// WHAT A RAW WINDING WRITE COSTS, so the row is not hygiene. `MeshEditBatch`'s
// write surface does not write windings at all, and `alias mesh this` means
// `ed.faces[fi] = …` COMPILES inside a recording batch and produces no op-log
// entry. A delta whose face entry is missing answers `true` from `revert()` and
// either changes nothing or leaves the mesh half-reverted — §5.3 rates the
// first worse than the second, because a throw is caught on the first run. The
// door is `Mesh.setFaceWinding` / `setFaceWindings`, which captures its own
// before-image and pairs the per-corner payload.
//
// LANE: `dub test --config=tests` (lane U) — a `tests/unit/**` block.
//
// THIS IS THE TEXT HALF AND ONLY THAT. A file reading zero raw writes can
// still record NOTHING: it can run its kernel through
// `MeshEditBatch.unrecorded`. The behavioural half is
// `tests/unit/l2_create_stable_delta_test.d`'s op-log-shape cells.
module tests.unit.command_winding_write_census_test;

import std.file   : readText, dirEntries, SpanMode, exists, isDir;
import std.path   : dirName, buildPath, baseName;
import std.format : format;
import std.algorithm : sort, uniq;
import std.array  : array;

/// Repository root, rooted at THIS FILE rather than at the working directory.
/// A census that quietly finds nothing when the lane runs from elsewhere is a
/// test that passes for the wrong reason.
import tests.unit.census_symbols : blankNonCode;

private string repoRoot()
{
    // …/tests/unit/<this file>  ->  …
    return dirName(dirName(dirName(__FILE_FULL_PATH__)));
}

/// Comments and string/char literals blanked, newlines preserved.
///
/// A LINE-COMMENT-ONLY stripper is NOT enough here and that is measured, not
/// defensive: `commands/mesh/split_edge.d`'s own block comment QUOTES the
/// splice it deleted (`face = face[0 .. k+1] ~ vm ~ face[k+1 .. $]`), so a
/// census that only ate `//` would count the explanation of the fix as an
/// instance of the defect and this file could never be green.
private alias stripCommentsAndStrings = blankNonCode;

private bool identChar(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

/// Occurrences of an INDEXED face-winding write — `faces[<anything>] = ` where
/// the `=` is an assignment and not a comparison — in already-stripped code.
///
/// INDEXED and not whole-array, on purpose. `m.faces = [[0u, 1, 2, 3]]` is how
/// half the unittest STANDS in `source/commands/**` are built (workplane.d,
/// select/boundary.d, select/by_stat.d), and a fixture assembling a bare mesh
/// before any batch exists is not the defect this census is about. The defect
/// is a live winding rewritten under an open batch, and that is always indexed.
private size_t countIndexedWindingWrites(string src, ref string firstHit)
{
    size_t n = 0;
    for (size_t i = 0; i + 6 < src.length; i++) {
        if (src[i .. i + 5] != "faces") continue;
        if (i > 0 && identChar(src[i - 1])) continue;      // `newFacesArr`, `nFaces`
        size_t j = i + 5;
        while (j < src.length && (src[j] == ' ' || src[j] == '\t')) j++;
        if (j >= src.length || src[j] != '[') continue;
        int depth = 0;
        size_t k = j;
        for (; k < src.length; k++) {
            if (src[k] == '[') depth++;
            else if (src[k] == ']') { depth--; if (depth == 0) { k++; break; } }
            else if (src[k] == '\n') break;
        }
        if (depth != 0) continue;
        while (k < src.length && (src[k] == ' ' || src[k] == '\t')) k++;
        if (k >= src.length || src[k] != '=') continue;
        if (k + 1 < src.length && src[k + 1] == '=') continue;   // a comparison
        if (k > 0 && (src[k - 1] == '!' || src[k - 1] == '<' || src[k - 1] == '>')) continue;
        if (n == 0) {
            immutable size_t lo = i;
            size_t hi = k + 1;
            while (hi < src.length && src[hi] != '\n' && hi < lo + 90) hi++;
            firstHit = src[lo .. hi];
        }
        ++n;
    }
    return n;
}

/// Occurrences of the SPLICE SHAPE — a winding rebuilt by concatenating slices
/// of itself. This is the one `mesh.split_edge` carried, and it is invisible to
/// the indexed-write needle above because its left-hand side is a `ref`
/// iteration variable (`foreach (ref face; faces)`), not `faces[fi]`.
private size_t countSpliceShapes(string src, ref string firstHit)
{
    size_t n = 0;
    static immutable string needle = "[0 .. k";
    for (size_t i = 0; i + needle.length < src.length; i++) {
        if (src[i .. i + needle.length] != needle) continue;
        if (n == 0) {
            size_t lo = i > 20 ? i - 20 : 0;
            size_t hi = i + 60 < src.length ? i + 60 : src.length;
            firstHit = src[lo .. hi];
        }
        ++n;
    }
    return n;
}

unittest // no command writes a face winding by hand
{
    immutable zone = buildPath(repoRoot(), "source", "commands");
    assert(exists(zone) && isDir(zone),
        "cannot find " ~ zone ~ " — the census would walk nothing and report "
      ~ "zero for the one reason that is not a finding");

    string[] paths;
    foreach (e; dirEntries(zone, "*.d", SpanMode.depth)) paths ~= e.name;
    paths.sort();

    // THE ANTI-DUPLICATION TERM, and it is not decoration: a repeated path
    // leaves a file unscanned while the count of ROWS still reads right. Here
    // the list comes from `dirEntries` so a duplicate cannot arise by typo —
    // it can arise from a symlinked subdirectory, which `SpanMode.depth`
    // follows.
    assert(paths.uniq.array.length == paths.length,
        format("the census walked %d path(s) but only %d distinct ones — a "
             ~ "duplicate leaves a target scanned twice and tells you nothing "
             ~ "about the one it displaced", paths.length,
               paths.uniq.array.length));

    // FILE-COUNT AND BYTE FLOORS, asserted BEFORE any count is taken. A walk
    // that found nothing is not a zero, it is a broken read; and a stripper
    // that ate its input reports zero for every needle.
    assert(paths.length >= 90,
        format("the census found only %d file(s) under source/commands — the "
             ~ "zone holds well over ninety and a short walk reports zero raw "
             ~ "writes for the wrong reason", paths.length));

    size_t scanned = 0, indexed = 0, splices = 0;
    string firstIndexed, firstSplice, indexedFile, spliceFile;
    foreach (p; paths) {
        immutable code = stripCommentsAndStrings(readText(p));
        scanned += code.length;
        string hit;
        immutable size_t a = countIndexedWindingWrites(code, hit);
        if (a > 0 && indexed == 0) { firstIndexed = hit; indexedFile = p; }
        indexed += a;
        immutable size_t b = countSpliceShapes(code, hit);
        if (b > 0 && splices == 0) { firstSplice = hit; spliceFile = p; }
        splices += b;
    }
    assert(scanned >= 400_000,
        format("the census read only %d byte(s) of stripped code across %d "
             ~ "file(s) — the stripper ate the zone and every count below is "
             ~ "zero for the wrong reason", scanned, paths.length));

    assert(indexed == 0,
        format("source/commands holds %d INDEXED face-winding write(s), "
             ~ "expected 0. First: `%s` in %s.\n"
             ~ "  A live winding written by hand reaches no op-log hook — "
             ~ "`alias mesh this` makes `ed.faces[fi] = …` compile inside a "
             ~ "RECORDING batch and record nothing, so the delta's revert "
             ~ "answers true and leaves the edit in. The door is "
             ~ "`Mesh.setFaceWinding` / `setFaceWindings` (task 1903 §L2-P1), "
             ~ "which reads its own before-image and pairs the per-corner "
             ~ "payload.\n"
             ~ "  §5.3's other audit CANNOT see this: its needle scans "
             ~ "source/mesh.d and source/mesh_ops/** only, which is how "
             ~ "split_edge's splice survived three revisions of it.",
               indexed, firstIndexed, indexedFile.baseName));

    assert(splices == 0,
        format("source/commands holds %d open-coded winding SPLICE(s), "
             ~ "expected 0. First: `%s` in %s.\n"
             ~ "  This is `mesh.split_edge`'s own shape, deleted at stage "
             ~ "L2-P0. It is invisible to the indexed-write needle above "
             ~ "because it assigns through a `foreach (ref face; faces)` "
             ~ "variable, and it costs more than the missing op-log entry: a "
             ~ "splice changes the mesh's TOTAL corner count, so a site that "
             ~ "opens no `beginCornerRewrite` makes `resizePolyVertexMaps` "
             ~ "fall through to its length insurance and ZERO every "
             ~ "PolyVertex map WHOLE — on the FORWARD.",
               splices, firstSplice, spliceFile.baseName));
}
