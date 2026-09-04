module tests.unit.mesh_ops.decimate_precision_test;

import math;
import mesh;
import mesh_edit_delta : MeshEditScope;
import mesh_ops.decimate;
import tests.unit.census_symbols : stripCommentsAndStrings = blankNonCode;

private uint floatBits(float value)
{
    return *cast(uint*) &value;
}

unittest { // norm3 rounds the sum in binary32 before taking the square root
    import std.format : format;
    import std.math : sqrt;

    struct NormCase {
        float x;
        float y;
        float z;
        uint roundedBits;
        uint extendedBits;
    }

    immutable NormCase[] cases = [
        NormCase(-0.206009030f, -0.244748831f,  0.0884001255f, 0x3ea9ee8a, 0x3ea9ee89),
        NormCase( 0.173154116f, -0.233733654f,  0.3173885350f, 0x3edc6d64, 0x3edc6d63),
        NormCase( 0.497737527f, -0.352160215f,  0.1778444050f, 0x3f2297c7, 0x3f2297c6),
        NormCase( 0.434141874f, -0.479707360f,  0.2073156830f, 0x3f2decdc, 0x3f2decdb),
        NormCase(-0.365248680f,  0.0113794804f, 0.0937525034f, 0x3ec1284f, 0x3ec12850),
        NormCase( 0.197494984f,  0.279136777f,  0.3305773740f, 0x3ef382e5, 0x3ef382e6),
    ];

    assert(cases.length >= 5, "norm3 precision table must contain at least five rows");

    // Positive controls run first: every row must still separate the old
    // extended-precision expression from the frozen binary32 result.
    foreach (i, testCase; cases) {
        const real sum = cast(real)testCase.x * cast(real)testCase.x
                       + cast(real)testCase.y * cast(real)testCase.y
                       + cast(real)testCase.z * cast(real)testCase.z;
        const float extended = cast(float)sqrt(sum);
        assert(floatBits(extended) == testCase.extendedBits,
               format("norm3 row %s extended control moved: 0x%08x != 0x%08x",
                      i, floatBits(extended), testCase.extendedBits));
        assert(floatBits(extended) != testCase.roundedBits,
               format("norm3 row %s no longer separates extended and binary32 rounding", i));
    }

    foreach (i, testCase; cases) {
        const float actual = norm3ForTest(testCase.x, testCase.y, testCase.z);
        assert(floatBits(actual) == testCase.roundedBits,
               format("norm3 row %s rounded bits moved: 0x%08x != 0x%08x",
                      i, floatBits(actual), testCase.roundedBits));
    }
}

private size_t countOccurrences(string haystack, string needle)
{
    size_t count;
    size_t cursor;
    while (cursor + needle.length <= haystack.length) {
        if (haystack[cursor .. cursor + needle.length] == needle) {
            ++count;
            cursor += needle.length;
        } else {
            ++cursor;
        }
    }
    return count;
}

private string compactLine(string line)
{
    import std.array : appender;

    auto result = appender!string;
    foreach (ch; line)
        if (ch != ' ' && ch != '\t' && ch != '\r') result.put(ch);
    return result.data;
}

private string functionBody(string src, string declaration)
{
    import std.string : indexOf;

    const declarationAt = src.indexOf(declaration);
    assert(declarationAt >= 0, "missing function declaration: " ~ declaration);
    const openAt = src.indexOf('{', cast(size_t)declarationAt);
    assert(openAt >= 0, "missing function body: " ~ declaration);

    size_t depth;
    foreach (i; cast(size_t)openAt .. src.length) {
        if (src[i] == '{') ++depth;
        else if (src[i] == '}' && --depth == 0)
            return src[cast(size_t)openAt + 1 .. i];
    }
    assert(false, "unterminated function body: " ~ declaration);
}

unittest { // source census pins all four call sites and the no-inline boundary
    import std.file : readText;
    import std.format : format;
    import std.path : buildPath, dirName;
    import std.string : splitLines, strip;

    enum repoRoot = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));
    immutable path = buildPath(repoRoot, "source", "mesh_ops", "decimate.d");
    immutable src = stripCommentsAndStrings(readText(path));
    immutable body = functionBody(src, "size_t reduceToTarget(");

    const normCalls = countOccurrences(body, "norm3(");
    const sqrtCalls = countOccurrences(body, "sqrt(");
    assert(sqrtCalls == 0 && normCalls == 4,
           format("`sqrt(` внутри `reduceToTarget`: %s, должно быть 0; "
                ~ "`norm3(` вызовов: %s, должно быть 4", sqrtCalls, normCalls));

    size_t declarationCount;
    bool pragmaAdjacent;
    string previousNonEmpty;
    foreach (rawLine; src.splitLines) {
        immutable line = rawLine.strip;
        if (line.length == 0) continue;
        immutable compact = compactLine(line);
        if (compact.length >= "privatefloatnorm3(".length
                && compact[0 .. "privatefloatnorm3(".length] == "privatefloatnorm3(") {
            ++declarationCount;
            pragmaAdjacent = compactLine(previousNonEmpty) == "pragma(inline,false)";
        }
        previousNonEmpty = line;
    }
    assert(declarationCount == 1,
           format("объявлений `private float norm3(`: %s, должно быть 1", declarationCount));

    enum pragmaMessage =
        "pragma(inline, false) не стоит непосредственно над `private float norm3(` в\n"
      ~ "source/mesh_ops/decimate.d. Эта строка — ЕДИНСТВЕННЫЙ страж: ни одна полоса\n"
      ~ "в дереве не собирает dmd с оптимизацией (dub build / dub test / perf-count —\n"
      ~ "без -O; всякая оптимизированная сборка идёт на LDC, .github/workflows/\n"
      ~ "build.yml:347), поэтому её снятие не может покраснеть поведенчески.\n"
      ~ "Измерено 2026-09-03, dmd 2.112.1-rc.1, ячейка check-release\n"
      ~ "`dmd -c -release -g -inline -O -w -version=SanitizerSelfTest`:\n"
      ~ "СО строкой — 28 addss / 23 mulss / 13 subss, 1 fsqrt, 0 fmul, 0 faddp;\n"
      ~ "БЕЗ неё встраиватель возвращает четыре суммы квадратов на стек x87 —\n"
      ~ "12 fmul, 8 faddp, 5 fsqrt — и целочисленная топология reduceToTarget\n"
      ~ "снова расходится с LDC (карточка 3920).";
    assert(pragmaAdjacent, pragmaMessage);
}

private enum GridOrder { ident, reversed, swap01 }

private struct GridRun {
    uint[][] batches;
    uint[] initialCosts;
    size_t vertices;
    size_t edges;
    size_t faces;
}

private uint[][] copyBatches(const uint[][] batches)
{
    uint[][] result;
    result.length = batches.length;
    foreach (i, batch; batches) result[i] = batch.dup;
    return result;
}

private GridRun runGrid(GridOrder order)
{
    Mesh source = makeGridPlane(4);
    uint[][] faces;
    foreach (face; source.faces) faces ~= face.dup;

    uint[][] ordered;
    final switch (order) {
    case GridOrder.ident:
        ordered = faces;
        break;
    case GridOrder.reversed:
        foreach_reverse (face; faces) ordered ~= face;
        break;
    case GridOrder.swap01:
        ordered = faces.dup;
        auto tmp = ordered[0];
        ordered[0] = ordered[1];
        ordered[1] = tmp;
        break;
    }

    Mesh mesh;
    mesh.vertices = source.vertices.dup;
    foreach (face; ordered) mesh.addFace(face);
    mesh.buildLoops();

    g_reduceInitialHeapCostBits.length = 0;
    g_reduceNeighborPushOrder.length = 0;
    auto ed = MeshEditBatch.unrecorded(mesh, kReduceEditScope);
    ed.reduceToTarget(8, false);
    ed.close();

    GridRun result;
    result.batches = copyBatches(g_reduceNeighborPushOrder);
    result.initialCosts = g_reduceInitialHeapCostBits.dup;
    result.vertices = mesh.vertices.length;
    result.edges = mesh.edges.length;
    result.faces = mesh.faces.length;
    return result;
}

private size_t distinctCount(const uint[] values)
{
    bool[uint] seen;
    foreach (value; values) seen[value] = true;
    return seen.length;
}

private bool strictlyAscending(const uint[] values)
{
    foreach (i; 1 .. values.length)
        if (values[i - 1] >= values[i]) return false;
    return true;
}

unittest { // neighbor heap refills are canonical on the real reduction path
    import std.format : format;

    const ident = runGrid(GridOrder.ident);
    const reversed = runGrid(GridOrder.reversed);
    const swap01 = runGrid(GridOrder.swap01);
    const GridRun[] runs = [ident, reversed, swap01];
    enum string[] names = ["ident", "rev", "swap01"];

    // Population floors and the sequence perturbation witness precede the ordering
    // assertion, so the raw-AA mutation proves they remain green.
    assert(ident.batches.length == 14, format("ident batches: %s, expected 14", ident.batches.length));
    assert(reversed.batches.length == 16, format("rev batches: %s, expected 16", reversed.batches.length));
    assert(swap01.batches.length == 16, format("swap01 batches: %s, expected 16", swap01.batches.length));
    foreach (ri, run; runs) {
        foreach (bi, batch; run.batches)
            assert(batch.length >= 2,
                   format("%s batch %s has only %s key(s)", names[ri], bi, batch.length));
        assert(run.initialCosts.length == 40,
               format("%s initial heap entries: %s, expected 40", names[ri], run.initialCosts.length));
        assert(distinctCount(run.initialCosts) == 1,
               format("%s initial heap has %s cost bit patterns, expected 1",
                      names[ri], distinctCount(run.initialCosts)));
        assert(run.initialCosts[0] == 0x3f000000,
               format("%s initial cost bits: 0x%08x, expected 0x3f000000",
                      names[ri], run.initialCosts[0]));
    }
    assert(reversed.batches != swap01.batches,
           "rev and swap01 push sequences must differ at the same batch count");

    foreach (ri, run; runs)
        foreach (bi, batch; run.batches)
            assert(strictlyAscending(batch),
                   format("%s neighbor push batch %s is not strictly ascending: %s",
                          names[ri], bi, batch));

    assert(reversed.vertices == 9 && reversed.edges == 15 && reversed.faces == 7,
           format("rev output: V=%s E=%s F=%s, expected 9/15/7",
                  reversed.vertices, reversed.edges, reversed.faces));
    assert(swap01.vertices == reversed.vertices
        && swap01.edges == reversed.edges
        && swap01.faces == reversed.faces,
           format("swap01 output differs from rev: V=%s E=%s F=%s",
                  swap01.vertices, swap01.edges, swap01.faces));
}
