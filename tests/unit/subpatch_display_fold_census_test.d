// Task 6450: the display transform is folded at both read doors, while the
// dirty key keeps the raw tool matrix and preview upload ownership stays
// distinct from the broader cage-upload suppression policy.
module tests.unit.subpatch_display_fold_census_test;

import std.algorithm : count;
import std.exception : enforce;
import std.file      : dirEntries, readText, SpanMode;
import std.path      : buildPath, dirName, extension;
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

unittest // task 6520: drag intent is computed once and shared by both policy doors
{
    const app = blankNonCode(readText(
        buildPath(repoRoot, "source", "app.d")));
    const mainBody = bodyAt(app, "void main(string[] args)");

    assert(mainBody.length > 0 && mainBody.count("activeTool.isDragging()") >= 2,
        "6520 intent: the production main body or drag-intent population vanished");
    const flushGate = lineAt(mainBody,
        "const bool displayUploadHeldByToolDrag =");
    assert(flushGate.indexOf("displayUploadsHeldByToolDrag_(") >= 0
        && flushGate.indexOf("isDragging") < 0,
        "6520 intent: the flush-site upload gate recomputed the tool-drag bool");
    assert(mainBody.count(
        "activeTool !is null && activeTool.isDragging()") == 2,
        "6520 intent: the tool-drag bool is computed more than once");
    assert(mainBody.indexOf("bool toolOwnsVbo") < 0,
        "6520 intent: the deleted flush-site ownership word is back");
    assert(mainBody.count(
        "displayUploadsHeldByToolDrag_ !is null") == 2,
        "6520 intent: a policy door calls the predicate without its null guard");
}

unittest // the ownership predicate lives at the shared read seam
{
    const meshGpu = blankNonCode(readText(
        buildPath(repoRoot, "source", "mesh_gpu.d")));
    const displayFold = bodyAt(meshGpu,
        "float[16] displayToolMatrix(const ref float[16] toolMat)");

    assert(displayFold.length > 0
        && displayFold.indexOf("displayPayload.carriesLiveEdit()") >= 0,
        "6520 display fold stopped reading payload provenance");
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

    assert(mainBody.count(
        "gpu.displayPayload.setIndexSpaceSuperseded(staleOnScreen);") == 1,
        "6520 supersession must be published from the freeze predicate at one site");

    const fanOut = bodyAt(mainBody,
        "if (subpatchPreview.lastRefreshFannedOut)");
    assert(mainBody.count(
        "displayPayload.recordWrite(\n                        DisplayPayloadWriter.gpuFanOut,") == 1
        && fanOut.indexOf("DisplayPayloadWriter.gpuFanOut") >= 0
        && fanOut.indexOf("DisplayPayloadBasis.previewIndexed") >= 0,
        "6520 provenance: GPU fan-out must record one preview-indexed write");

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

    assert(clone.indexOf("dst.displayPayload = src.displayPayload;") >= 0,
        "6450 detached GPU state stopped mirroring display ownership");
    assert(take.indexOf(
        "gpu.displayPayload = DisplayPayloadProvenance.init;") >= 0,
        "6450 moved-from GPU state retains display ownership");
    assert(empty.indexOf(
        "gpu.displayPayload == DisplayPayloadProvenance.init") >= 0,
        "6450 empty-state identity ignores display ownership");
    assert(prepare.indexOf("target.suppressCageUpload") >= 0
        && prepare.indexOf("displayPayload") < 0,
        "6450 prepared-upload admission confused policy with display ownership");
}

unittest // completed writes are recorded below every entry refusal
{
    const meshGpu = blankNonCode(readText(
        buildPath(repoRoot, "source", "mesh_gpu.d")));
    const upload = bodyAt(meshGpu, "void upload(ref const Mesh mesh,");
    assert(upload.count("submitUploadGl();") == 1
        && upload.count("publishSuppressedCagePosition(mesh);") == 1
        && upload.count("displayPayload.recordWrite(") == 2,
        "6520 provenance: full-upload write-site population changed");
    const submit = upload.indexOf("submitUploadGl();");
    const refused = upload.indexOf("publishSuppressedCagePosition(mesh);");
    immutable size_t firstWrite = cast(size_t)upload.indexOf(
        "displayPayload.recordWrite(");
    const secondRel = upload[firstWrite + 1 .. $].indexOf(
        "displayPayload.recordWrite(");
    immutable size_t secondWrite = firstWrite + 1 + cast(size_t)secondRel;
    assert(firstWrite > submit && secondWrite > submit
        && firstWrite > refused && secondWrite > refused,
        "6520 provenance: upload records authorship before its own write");

    const positions = bodyAt(meshGpu,
        "void refreshPositions(ref const Mesh mesh,");
    assert(positions.count("displayPayload.recordWrite(") == 1
        && positions.indexOf("faceTriStart.length != mesh.faces.length") >= 0
        && positions.indexOf("displayPayload.recordWrite(")
            > positions.indexOf("faceTriStart.length != mesh.faces.length"),
        "6520 provenance: position refresh records before layout refusal");

    const selected = bodyAt(meshGpu,
        "void uploadSelectedVertices(ref const Mesh mesh,");
    assert(selected.count("displayPayload.recordWrite(") == 1
        && selected.indexOf("publishSuppressedCagePosition(mesh);") >= 0
        && selected.indexOf("displayPayload.recordWrite(")
            > selected.indexOf("publishSuppressedCagePosition(mesh);"),
        "6520 provenance: selected upload records before refusal");

    const nonFace = bodyAt(meshGpu,
        "void refreshNonFacePositions(ref const Mesh mesh,");
    assert(nonFace.count("displayPayload.recordWrite(") == 1,
        "6520 provenance: non-face refresh write-site population changed");
}

unittest // deleted ownership channels stay absent from executable code
{
    size_t files;
    foreach (root; ["source", "tools", "tests"]) {
        foreach (de; dirEntries(buildPath(repoRoot, root), SpanMode.depth)) {
            if (!de.isFile) continue;
            const ext = extension(de.name);
            if (ext != ".d" && ext != ".py") continue;
            ++files;
            const raw = readText(de.name);
            const code = ext == ".d" ? blankNonCode(raw) : raw;
            assert(code.indexOf("previewWritesDisplayBuffers") < 0,
                "6520 census: the predicted preview-ownership word is back");
            assert(code.indexOf("toolOwnsVbo") < 0,
                "6520 census: the second drag-intent word is back");
        }
    }
    assert(files > 100,
        "6520 census: executable source population vanished");
}
