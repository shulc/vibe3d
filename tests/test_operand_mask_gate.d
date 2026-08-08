// L4 — the operand-mask regression gate (task 0613 S5,
// doc/hide_geometry_plan.md §3.2).
//
// WHAT THIS GUARDS. The "empty selection ⇒ operate on the whole mesh"
// convention was implemented in five structurally different shapes across ~44
// sites. S5 routed every one of them into the L1 funnel
// (Mesh.operand{Vertex,Edge,Face}Mask), whose fallback branch means "every
// VISIBLE element". Two of those five shapes (A and B) were closed by a
// compiler-enforced lever — a deleted name is a build error. The other three
// (C, D, E — 25 sites) were closed by a MECHANICAL substitution, which the
// compiler cannot check and which a future author can silently re-open by
// writing the idiom fresh. This file is the only thing standing between that
// and a silent leak, so it scans the tree rather than any one call site.
//
// WHY A KNOWN-NON-ZERO SELF-TEST COMES FIRST. A scanner whose regex matches
// nothing returns zero findings and passes a "delete a line and watch it fail"
// check while measuring nothing at all — this campaign has already shipped that
// bug once. So the first unittest below points the SAME scanner at a synthetic
// file containing one occurrence of each pattern plus a decoy, and asserts it
// finds exactly the two real ones at the right lines and NOT the decoy. Only
// then does the second unittest scan `source/`.
//
// HOW TO FIX A FAILURE.
//   * You added a whole-mesh fallback in production code: don't. Call
//     `mesh.operandFaceMask()` / `operandEdgeMask()` / `operandVertexMask(mode)`
//     instead — the fallback and its hide subtraction live there.
//   * You added a unittest fixture that builds an all-true mask over a
//     throwaway mesh: bump that file's count in ALLOWED below. That is a
//     one-line diff a reviewer sees, which is the whole point.
//   * You believe a PRODUCTION occurrence is legitimate: add the file with a
//     reason, the way the three current production entries are annotated.

import std.regex : regex, matchFirst, Regex;
import std.file  : dirEntries, SpanMode, readText, write, mkdirRecurse, rmdirRecurse, exists;
import std.path  : buildPath, extension;
import std.algorithm : sort, canFind, startsWith;
import std.array  : array, replace;
import std.conv   : to;
import std.string : strip;

void main() {}

// ---------------------------------------------------------------------------
// The scanner
// ---------------------------------------------------------------------------

struct Hit { string file; size_t line; string text; }

// (1) The bulk fill: `ident[] = true`, where the SAME ident is sized by a mesh
//     plane's length on this line or one of the previous three. The proximity
//     window is what separates an operand mask from the many unrelated `bool[]`
//     arrays this codebase initialises to all-true (per-vertex fan flags,
//     lasso AND-accumulators, cache-dirty arrays).
private enum string RE_FILL = `\b([A-Za-z_]\w*)\[\] = true`;
private enum string RE_SIZE = `\b(faces|edges|vertices)\.length`;
// (2) The per-index fill: `foreach (i; 0 .. mesh.faces.length) mask[i] = true;`
//     — the shape C/D open-coded builders used before S5.
private enum string RE_IDX  =
    `0 \.\. [\w.]+\.(faces|edges|vertices)\.length\)\s*\w+\[\w+\] = true`;

Hit[] scanFile(string path) {
    auto reFill = regex(RE_FILL);
    auto reSize = regex(RE_SIZE);
    auto reIdx  = regex(RE_IDX);
    Hit[] hits;
    auto lines = readText(path).replace("\r\n", "\n").split('\n');
    foreach (n, line; lines) {
        bool hit = false;
        auto mf = matchFirst(line, reFill);
        if (!mf.empty) {
            const name = mf[1];
            // window: this line and the three above it
            const size_t lo = n >= 3 ? n - 3 : 0;
            foreach (k; lo .. n + 1) {
                if (matchFirst(lines[k], reSize).empty) continue;
                if (!matchFirst(lines[k], regex(`\b` ~ name ~ `\b`)).empty) {
                    hit = true;
                    break;
                }
            }
        }
        if (!hit && !matchFirst(line, reIdx).empty) hit = true;
        if (hit) hits ~= Hit(path, n + 1, line.strip);
    }
    return hits;
}

private string[] split(string s, char c) {
    string[] r;
    size_t start = 0;
    foreach (i, ch; s) if (ch == c) { r ~= s[start .. i]; start = i + 1; }
    r ~= s[start .. $];
    return r;
}

Hit[] scanTree(string root) {
    Hit[] hits;
    foreach (e; dirEntries(root, SpanMode.depth)) {
        if (!e.isFile || e.name.extension != ".d") continue;
        hits ~= scanFile(e.name);
    }
    return hits;
}

// ---------------------------------------------------------------------------
// T-L4 (i) — the KNOWN-NON-ZERO self-test. This runs FIRST, deliberately.
// ---------------------------------------------------------------------------

unittest {
    const dir = buildPath("/tmp", "vibe3d_operand_gate_selftest");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope(exit) if (exists(dir)) rmdirRecurse(dir);

    const f = buildPath(dir, "synthetic.d");
    write(f,
        "void a(Mesh* mesh) {\n"                                   // 1
      ~ "    auto mask = new bool[](mesh.faces.length);\n"         // 2
      ~ "    mask[] = true;\n"                                     // 3  <- fill hit
      ~ "}\n"                                                      // 4
      ~ "void b(Mesh* mesh) {\n"                                   // 5
      ~ "    foreach (i; 0 .. mesh.edges.length) emask[i] = true;\n" // 6 <- index hit
      ~ "}\n"                                                      // 7
      ~ "void decoy(Mesh* mesh) {\n"                               // 8
      ~ "    bool[] dirty = new bool[](cacheSlots);\n"             // 9
      ~ "    dirty[] = true;\n"                                    // 10 <- NOT a hit
      ~ "    foreach (i; 0 .. mesh.faces.length) if (keep(i)) k[i] = true;\n" // 11 NOT
      ~ "}\n");

    auto hits = scanFile(f);
    assert(hits.length == 2,
        "self-test: the scanner must find exactly 2 synthetic occurrences, found "
        ~ hits.length.to!string
        ~ " — a scanner that matches nothing returns 0 here and would then "
        ~ "'pass' the tree scan below while measuring nothing");
    assert(hits[0].line == 3,
        "self-test: the bulk-fill occurrence is on line 3, reported "
        ~ hits[0].line.to!string);
    assert(hits[1].line == 6,
        "self-test: the per-index occurrence is on line 6, reported "
        ~ hits[1].line.to!string);

    // And the decoys must NOT be hits — an over-broad scanner that flagged
    // every `x[] = true` would make the allowlist below meaningless noise.
    foreach (h; hits)
        assert(h.line != 10 && h.line != 11,
            "self-test: the scanner flagged a decoy at line " ~ h.line.to!string
            ~ " (line 10 is a non-mesh-sized array; line 11 is a GUARDED "
            ~ "per-index fill, which is what a correct filter looks like)");
}

// ---------------------------------------------------------------------------
// T-L4 (ii) — the tree scan. Exact per-file counts: a NEW occurrence fails
// even in an already-listed file.
// ---------------------------------------------------------------------------

// file → (expected count, why it is allowed)
private immutable string[2][string] ALLOWED_REASON;
private immutable size_t[string] ALLOWED_COUNT;

shared static this() {
    // --- PRODUCTION entries. Each one is NOT a whole-mesh operand fallback;
    //     read the reason before adding a sibling. ---
    ALLOWED_COUNT["source/commands/mesh/hide.d"] = 1;
    // ^ mesh.hide's own "empty selection ⇒ hide everything" (measured, C6).
    //   This is the one place the fallback must NOT subtract hidden geometry:
    //   it is the writer OF that geometry.
    ALLOWED_COUNT["source/mesh_ops/decimate.d"] = 5;
    // ^ :420 is an unconditional internal finalisation mask (coincide-then-weld
    //   every cluster member), not a selection fallback — and it goes through
    //   weldVerticesByMask, so the §3.3 backstop covers it anyway. The other
    //   four are unittest fixtures.
    ALLOWED_COUNT["source/app.d"] = 2;
    // ^ `cageAllInside` is an AND-accumulator seeded true and cleared per
    //   preview child, not an operand set. Its hide handling landed in S4.

    // --- UNITTEST-FIXTURE entries: throwaway meshes with nothing hidden.
    //     Bumping these counts is fine and needs no justification beyond
    //     "a new fixture". ---
    ALLOWED_COUNT["source/mesh.d"]                    = 15;
    // ^ 14 → 15 (task 0632): facetedSubdivide's hide-carry unittest opens with
    //   an all-true mask over a throwaway cube as its VACUITY guard — the
    //   number the kernel produces when nothing is excluded, without which its
    //   "21 faces" assertion could not be read as a measurement of exclusion.
    ALLOWED_COUNT["source/mesh_ops/extrude.d"]        = 6;
    ALLOWED_COUNT["source/remesh/remesh_job.d"]       = 1;
    ALLOWED_COUNT["source/tools/alignment/mirror.d"]  = 2;
}

unittest {
    auto hits = scanTree("source");

    size_t[string] byFile;
    foreach (h; hits) byFile[h.file] = byFile.get(h.file, 0) + 1;

    string report;
    foreach (f; byFile.keys.dup.sort) {
        const got = byFile[f];
        const want = ALLOWED_COUNT.get(f, 0);
        if (got == want) continue;
        report ~= "\n  " ~ f ~ ": found " ~ got.to!string
                ~ ", allowlist says " ~ want.to!string;
        foreach (h; hits)
            if (h.file == f) report ~= "\n      :" ~ h.line.to!string ~ "  " ~ h.text;
    }
    // A file that DROPPED to zero must also be caught, or the allowlist rots
    // into a list of files that no longer exist.
    foreach (f; ALLOWED_COUNT.keys.dup.sort)
        if (f !in byFile)
            report ~= "\n  " ~ f ~ ": allowlist expects "
                    ~ ALLOWED_COUNT[f].to!string ~ ", found 0 — remove the entry";

    assert(report.length == 0,
        "the whole-mesh fallback idiom appears outside the allowlist. Call "
        ~ "Mesh.operand{Vertex,Edge,Face}Mask instead — the fallback and its "
        ~ "hidden-geometry subtraction live there (doc/hide_geometry_plan.md "
        ~ "§3.2). See this file's header for the three legitimate ways out."
        ~ report);
}
