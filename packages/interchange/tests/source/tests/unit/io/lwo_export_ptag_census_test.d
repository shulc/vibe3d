// On-disk layout census for `io.lwo_export` (task 4067): where the PTAG SURF
// chunks sit and how many entries each carries, per POLS kind.
//
// The law, from the format: a PTAG binds to the most-recent POLS chunk and
// its polygon indices are local to it, so a layer with K polygon kinds needs
// K PTAG chunks, each right after its own POLS and carrying exactly that
// kind's polygon count; a kind with no polygons has no POLS and so gets no
// PTAG (the default the owner accepted in task 4050 Q10, measured on writer
// 8610ff2 in task 4067 -- the pre-fix writer wrote an EMPTY PTAG for a layer
// with no polygons, which the package's own reader refuses).
//
// Block order matters (druntime stops a module at its first red): the
// single-kind blocks are green on both writer versions and sit first; the
// mixed and no-polygon blocks are the ones that redden on pin fc87b3f3.
// Semantics (that the tags land on the right polygons) are pinned separately
// in tests/unit/io/lwo_export_test.d; this module only counts chunks.
module tests.unit.io.lwo_export_ptag_census_test;

import std.file    : read, exists, remove, tempDir;
import std.path    : buildPath;
import std.format  : format;
import std.process : thisProcessID;
import std.algorithm : filter;
import std.array     : array;
import mesh : Mesh;
import io.lwo_export : exportLwo;
import tests.unit.io.lwo_ptag_fixture;

private LwoChunkCensus exportCensus(ref const Mesh m, string stem)
{
    const path = buildPath(tempDir, format("vibe3d_4067_census_%s_%d.lwo", stem, thisProcessID));
    scope (exit) if (exists(path)) remove(path);
    exportLwo(m, path);
    return lwoChunkCensus(cast(const(ubyte)[]) read(path));
}

unittest { // single-kind FACE layer: one POLS, one PTAG carrying every polygon
    Mesh m = kindTris([false, false], [1u, 1u]);
    auto c = exportCensus(m, "face_only");
    assert(c.tags == 1 && c.surf == 2, "surface table must be written");
    assert(c.polsKinds == ["FACE"] && c.polsCounts == [2u],
           format("expected one POLS FACE of 2, got %s %s", c.polsKinds, c.polsCounts));
    assert(c.ptagSurfCounts.length == 1,
           format("single-kind FACE layer: exactly one PTAG SURF (none for the absent PTCH kind), got %d",
                  c.ptagSurfCounts.length));
    assert(c.ptagSurfCounts[0] == 2, format("PTAG must carry every FACE polygon: expected 2, got %d",
                                            c.ptagSurfCounts[0]));
}

unittest { // single-kind PTCH layer: same shape
    Mesh m = kindTris([true, true], [1u, 1u]);
    auto c = exportCensus(m, "ptch_only");
    assert(c.tags == 1 && c.surf == 2, "surface table must be written");
    assert(c.polsKinds == ["PTCH"] && c.polsCounts == [2u],
           format("expected one POLS PTCH of 2, got %s %s", c.polsKinds, c.polsCounts));
    assert(c.ptagSurfCounts.length == 1,
           format("single-kind PTCH layer: exactly one PTAG SURF (none for the absent FACE kind), got %d",
                  c.ptagSurfCounts.length));
    assert(c.ptagSurfCounts[0] == 2, format("PTAG must carry every PTCH polygon: expected 2, got %d",
                                            c.ptagSurfCounts[0]));
}

unittest { // mixed layer: one PTAG per POLS kind, each carrying that kind's count
    Mesh m = kindTris(kMixedSubpatch[], kMixedMaterial[]);
    auto c = exportCensus(m, "mixed");
    assert(c.tags == 1 && c.surf == 2, "surface table must be written");
    assert(c.polsKinds == ["FACE", "PTCH"] && c.polsCounts == [2u, 3u],
           format("expected POLS FACE(2) then POLS PTCH(3), got %s %s", c.polsKinds, c.polsCounts));
    assert(c.ptagSurfCounts == [2u, 3u],
           format("mixed layer: one PTAG SURF per POLS kind carrying that kind's polygon count -- expected [2, 3], got %s",
                  c.ptagSurfCounts));
    auto bind = c.ids.filter!(id => id == "POLS" || id == "PTAG").array;
    assert(bind == ["POLS", "PTAG", "POLS", "PTAG"],
           format("each PTAG must follow the POLS chunk it binds to, got %s", bind));
}

unittest { // a layer with no polygons writes no PTAG at all
    Mesh m = pointsOnly();
    auto c = exportCensus(m, "points_only");
    assert(c.tags == 1 && c.surf == 2, "the (global) surface table is still written");
    assert(c.polsCounts.length == 0, format("no polygons, no POLS: got %s", c.polsCounts));
    assert(c.ptagSurfCounts.length == 0,
           format("a layer with no polygons writes no PTAG SURF (owner's accepted default, task 4067): got %d chunk(s) %s",
                  c.ptagSurfCounts.length, c.ptagSurfCounts));
}
