// Task 6450: the display transform is folded at both read doors, while the
// dirty key keeps the raw tool matrix and preview upload ownership stays
// distinct from the broader cage-upload suppression policy.
module tests.unit.subpatch_display_fold_census_test;

import std.algorithm : count;
import std.exception : enforce;
import std.file      : readText;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string bodyAt(string code, string marker)
{
    const at = code.indexOf(marker);
    enforce(at >= 0, "missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    enforce(i < code.length, "no body after source marker `" ~ marker ~ "`");
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i)
    {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    enforce(false, "unterminated body after source marker `" ~ marker ~ "`");
    return null;
}

private string lineAt(string code, string marker)
{
    const at = code.indexOf(marker);
    enforce(at >= 0, "missing source marker `" ~ marker ~ "`");
    size_t begin = cast(size_t)at;
    while (begin > 0 && code[begin - 1] != '\n') --begin;
    size_t end = cast(size_t)at;
    while (end < code.length && code[end] != '\n') ++end;
    return code[begin .. end];
}

unittest // the ownership predicate lives at the shared read seam
{
    const meshGpu = blankNonCode(readText(
        buildPath(repoRoot, "source", "mesh_gpu.d")));
    const displayFold = bodyAt(meshGpu,
        "float[16] displayToolMatrix(const ref float[16] toolMat)");

    assert(displayFold.indexOf("previewWritesDisplayBuffers") >= 0,
        "6450 display fold stopped reading preview-buffer ownership");
    assert(displayFold.indexOf("suppressCageUpload") < 0,
        "6450 M-READ: display fold regressed to cage-upload suppression");
}

unittest // both display readers fold; the invalid raw compositions stay absent
{
    const viewport = blankNonCode(readText(
        buildPath(repoRoot, "source", "ui", "viewport_render.d")));
    const http = blankNonCode(readText(
        buildPath(repoRoot, "source", "http_providers.d")));

    assert(viewport.count("displayToolMatrix(") == 1,
        "6450 viewport must have exactly one display-matrix fold");
    assert(http.count("displayToolMatrix(") == 1,
        "6450 HTTP oracle must have exactly one display-matrix fold");
    assert(viewport.indexOf("matMul4(itemMatrix, tt.gpuMatrix)") < 0,
        "6450 viewport restored an unfolded raw tool-matrix composition");
    assert(http.indexOf("meshModel = tt.gpuMatrix") < 0,
        "6450 HTTP oracle restored an unfolded raw tool matrix");
}

unittest // publication, dirty key, writers, and reuse close the state census
{
    const app = blankNonCode(readText(
        buildPath(repoRoot, "source", "app.d")));
    const preview = blankNonCode(readText(
        buildPath(repoRoot, "source", "subpatch_preview.d")));
    const mainBody = bodyAt(app, "void main(string[] args)");

    assert(mainBody.indexOf(
        "gpu.previewWritesDisplayBuffers =\n                subpatchPreview.active && !staleOnScreen;") >= 0,
        "6450 preview-buffer ownership must exclude the frozen stale surface");

    const dirtyKeyLine = lineAt(mainBody, "_newKey.toolMat =");
    assert(dirtyKeyLine.indexOf("tt.gpuMatrix") >= 0
        && dirtyKeyLine.indexOf("displayToolMatrix") < 0,
        "6450 dirty key must retain the raw tool matrix");

    assert(mainBody.count("GpuFanOutTargets targets =") == 1,
        "6450 display-VBO census: fan-out target construction changed");
    assert(mainBody.count("gpu.upload(subpatchPreview.mesh") == 1,
        "6450 display-VBO census: preview full-upload doors changed");
    assert(mainBody.count("gpu.refreshPositions(subpatchPreview.mesh") == 1,
        "6450 display-VBO census: preview position-refresh doors changed");
    assert(mainBody.count("gpu.refreshNonFacePositions(") == 1,
        "6450 display-VBO census: preview non-face refresh doors changed");

    const rebuild = bodyAt(preview,
        "void rebuildIfStale(ref const Mesh source, int d,");
    assert(rebuild.indexOf("reusablePreviewReady") >= 0
        && rebuild.indexOf("active                = true;") >= 0,
        "6450 reuse branch left the display-ownership state census");
}

unittest // detached upload state mirrors ownership, while admission stays policy-keyed
{
    const meshGpu = blankNonCode(readText(
        buildPath(repoRoot, "source", "mesh_gpu.d")));
    const clone = bodyAt(meshGpu, "private GpuMesh cloneUploadState(");
    const take = bodyAt(meshGpu, "private GpuMeshNames takeGpuMeshNames(");
    const empty = bodyAt(meshGpu, "private bool isDefaultEmptyGpuMesh(");
    const prepare = bodyAt(meshGpu, "bool beginPreparedUpload(");

    assert(clone.indexOf(
        "dst.previewWritesDisplayBuffers = src.previewWritesDisplayBuffers;") >= 0,
        "6450 detached GPU state stopped mirroring display ownership");
    assert(take.indexOf("gpu.previewWritesDisplayBuffers = false;") >= 0,
        "6450 moved-from GPU state retains display ownership");
    assert(empty.indexOf("!gpu.previewWritesDisplayBuffers") >= 0,
        "6450 empty-state identity ignores display ownership");
    assert(prepare.indexOf("target.suppressCageUpload") >= 0
        && prepare.indexOf("previewWritesDisplayBuffers") < 0,
        "6450 prepared-upload admission confused policy with display ownership");
}
