/// Task 5160: the three prepared GPU owners must release through their real
/// OpenGL backend.  The GL entry points are replaced only at the BindBC
/// boundary, so these cells need neither a window nor a graphics context.
module tests.unit.gpu_owner_real_backend_test;

import bindbc.opengl : GLboolean, GLsizei, GLuint, GL_FALSE, GL_TRUE,
    glDeleteBuffers, glDeleteVertexArrays, glGenBuffers, glGenVertexArrays,
    glIsBuffer, glIsVertexArray;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuCreateOwner, GpuCreateUploadOwner, GpuMesh,
    GpuResourceOwner, PreparedGpuResourceToken, ValidatedGpuResourceToken;
import std.file : readText;
import std.format : format;
import std.path : buildPath, dirName;
import std.string : count;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private enum string[3] vaoLabels = ["faceVao", "edgeVao", "vertVao"];
private enum string[6] vboLabels = ["faceVbo", "edgeVbo", "vertVbo",
    "faceIdVbo", "matIdVbo", "weightColorVbo"];

private struct OwnerNames
{
    GLuint[3] vaos;
    GLuint[6] vbos;
}

private struct TestGlNames
{
    enum size_t capacity = 64;
    static GLuint nextVao;
    static GLuint nextVbo;
    static bool[capacity] liveVaos;
    static bool[capacity] liveVbos;
    static GLuint[capacity] generatedVaos;
    static GLuint[capacity] generatedVbos;
    static size_t generatedVaoCount;
    static size_t generatedVboCount;

    static void reset() nothrow @nogc
    {
        nextVao = 1;
        nextVbo = 1;
        liveVaos[] = false;
        liveVbos[] = false;
        generatedVaos[] = 0;
        generatedVbos[] = 0;
        generatedVaoCount = 0;
        generatedVboCount = 0;
    }

    static extern(System) void genVaos(GLsizei count, GLuint* names)
            nothrow @nogc
    {
        foreach (i; 0 .. count)
        {
            const name = nextVao++;
            names[i] = name;
            if (name < capacity)
                liveVaos[name] = true;
            if (generatedVaoCount < capacity)
                generatedVaos[generatedVaoCount++] = name;
        }
    }

    static extern(System) void genVbos(GLsizei count, GLuint* names)
            nothrow @nogc
    {
        foreach (i; 0 .. count)
        {
            const name = nextVbo++;
            names[i] = name;
            if (name < capacity)
                liveVbos[name] = true;
            if (generatedVboCount < capacity)
                generatedVbos[generatedVboCount++] = name;
        }
    }

    static extern(System) void deleteVaos(GLsizei count,
            const(GLuint)* names) nothrow @nogc
    {
        foreach (i; 0 .. count)
        {
            const name = names[i];
            if (name < capacity)
                liveVaos[name] = false;
        }
    }

    static extern(System) void deleteVbos(GLsizei count,
            const(GLuint)* names) nothrow @nogc
    {
        foreach (i; 0 .. count)
        {
            const name = names[i];
            if (name < capacity)
                liveVbos[name] = false;
        }
    }

    static extern(System) GLboolean isVao(GLuint name) nothrow @nogc
    {
        return cast(GLboolean)(name < capacity && liveVaos[name]
            ? GL_TRUE : GL_FALSE);
    }

    static extern(System) GLboolean isVbo(GLuint name) nothrow @nogc
    {
        return cast(GLboolean)(name < capacity && liveVbos[name]
            ? GL_TRUE : GL_FALSE);
    }
}

private void withGlBoundary(scope void delegate() cell)
{
    auto savedGenVaos = glGenVertexArrays;
    auto savedGenVbos = glGenBuffers;
    auto savedDeleteVaos = glDeleteVertexArrays;
    auto savedDeleteVbos = glDeleteBuffers;
    auto savedIsVao = glIsVertexArray;
    auto savedIsVbo = glIsBuffer;
    scope (exit)
    {
        glGenVertexArrays = savedGenVaos;
        glGenBuffers = savedGenVbos;
        glDeleteVertexArrays = savedDeleteVaos;
        glDeleteBuffers = savedDeleteVbos;
        glIsVertexArray = savedIsVao;
        glIsBuffer = savedIsVbo;
    }

    TestGlNames.reset();
    glGenVertexArrays = &TestGlNames.genVaos;
    glGenBuffers = &TestGlNames.genVbos;
    glDeleteVertexArrays = &TestGlNames.deleteVaos;
    glDeleteBuffers = &TestGlNames.deleteVbos;
    glIsVertexArray = &TestGlNames.isVao;
    glIsBuffer = &TestGlNames.isVbo;
    cell();
}

private OwnerNames generatedOwnerNames(size_t ownerIndex)
{
    const vaoBase = ownerIndex * vaoLabels.length;
    const vboBase = ownerIndex * vboLabels.length;
    OwnerNames result;
    foreach (i; 0 .. result.vaos.length)
        result.vaos[i] = TestGlNames.generatedVaos[vaoBase + i];
    foreach (i; 0 .. result.vbos.length)
        result.vbos[i] = TestGlNames.generatedVbos[vboBase + i];
    return result;
}

private OwnerNames gpuNames(ref const GpuMesh gpu)
{
    return OwnerNames(
        [gpu.faceVao, gpu.edgeVao, gpu.vertVao],
        [gpu.faceVbo, gpu.edgeVbo, gpu.vertVbo, gpu.faceIdVbo,
         gpu.matIdVbo, gpu.weightColorVbo]);
}

private void assertPopulationFloor(string cell)
{
    size_t liveVaoCount;
    foreach (name; TestGlNames.generatedVaos[0 ..
            TestGlNames.generatedVaoCount])
        if (glIsVertexArray(name) == GL_TRUE)
            ++liveVaoCount;
    assert(liveVaoCount == 6, format(
        "%s VAO population floor: expected 6 live names across two records, got %s",
        cell, liveVaoCount));

    size_t liveVboCount;
    foreach (name; TestGlNames.generatedVbos[0 ..
            TestGlNames.generatedVboCount])
        if (glIsBuffer(name) == GL_TRUE)
            ++liveVboCount;
    assert(liveVboCount == 12, format(
        "%s VBO population floor: expected 12 live names across two records, got %s",
        cell, liveVboCount));
}

private void assertNamesLive(OwnerNames names, string cell)
{
    foreach (i, name; names.vaos)
        assert(glIsVertexArray(name) == GL_TRUE, format(
            "%s second live record: VAO %s name %s was released",
            cell, vaoLabels[i], name));
    foreach (i, name; names.vbos)
        assert(glIsBuffer(name) == GL_TRUE, format(
            "%s second live record: VBO %s name %s was released",
            cell, vboLabels[i], name));
}

private void assertNamesDead(OwnerNames names, string cell)
{
    foreach (i, name; names.vaos)
        assert(glIsVertexArray(name) == GL_FALSE, format(
            "%s release completeness: VAO %s name %s remained live",
            cell, vaoLabels[i], name));
    foreach (i, name; names.vbos)
        assert(glIsBuffer(name) == GL_FALSE, format(
            "%s release completeness: VBO %s name %s remained live",
            cell, vboLabels[i], name));
}

private void setRelatedHeaderState(ref GpuMesh gpu, const(Mesh)* stamp)
{
    gpu.faceVertCount = 31;
    gpu.edgeVertCount = 32;
    gpu.vertCount = 33;
    gpu.faceTriStart = [34];
    gpu.faceTriCount = [35];
    gpu.suppressCageUpload = true;
    gpu.edgeOriginGpu = [36];
    gpu.faceOriginGpu = [37];
    gpu.vertOriginGpu = [38];
    gpu.faceCornerVert = [39];
    gpu.weightStampMesh = stamp;
    gpu.weightStampName = "gpu-header-sentinel";
    gpu.weightStampValid = true;
    gpu.uploadVersion = 40;
}

private void assertRelatedHeaderCleared(ref const GpuMesh gpu, string cell)
{
    assert(gpu.faceVertCount == 0 && gpu.edgeVertCount == 0
        && gpu.vertCount == 0 && gpu.faceTriStart.length == 0
        && gpu.faceTriCount.length == 0 && !gpu.suppressCageUpload
        && gpu.edgeOriginGpu.length == 0 && gpu.faceOriginGpu.length == 0
        && gpu.vertOriginGpu.length == 0 && gpu.faceCornerVert.length == 0
        && gpu.weightStampMesh is null && gpu.weightStampName.length == 0
        && !gpu.weightStampValid && gpu.uploadVersion == 0,
        cell ~ " did not clear the related GpuMesh header state");
}

unittest // GpuCreateOwner.abortEnlisted reaches the real deleter.
{
    withGlBoundary({
        enum cell = "GpuCreateOwner.abortEnlisted";
        GpuMesh targetA;
        GpuMesh targetB;
        auto ownerA = new GpuCreateOwner(&targetA, 7, 11);
        auto ownerB = new GpuCreateOwner(&targetB, 7, 11);
        scope (exit) ownerA.abortEnlisted();
        scope (exit) ownerB.abortEnlisted();

        assert(ownerA.beginEnlistedCreate() && ownerB.beginEnlistedCreate(),
            cell ~ " population setup refused public openGl owners");
        assertPopulationFloor(cell);
        const namesA = generatedOwnerNames(0);
        const namesB = generatedOwnerNames(1);

        ownerA.abortEnlisted();
        assertNamesLive(namesB, cell);
        assertNamesDead(namesA, cell);
    });
}

unittest // GpuResourceOwner.installPrepared reaches the real deleter.
{
    withGlBoundary({
        enum cell = "GpuResourceOwner.installPrepared";
        auto stamp = makeCube();
        GpuMesh gpuA;
        GpuMesh gpuB;
        gpuA.init();
        setRelatedHeaderState(gpuA, &stamp);
        scope (exit) gpuA.destroy();
        gpuB.init();
        scope (exit) gpuB.destroy();
        const namesA = gpuNames(gpuA);
        const namesB = gpuNames(gpuB);

        auto ownerA = new GpuResourceOwner(&gpuA, 7, 11);
        auto ownerB = new GpuResourceOwner(&gpuB, 7, 11);
        PreparedGpuResourceToken preparedA;
        PreparedGpuResourceToken preparedB;
        assert(ownerA.beginPreparedDestroy(preparedA)
            && ownerB.beginPreparedDestroy(preparedB),
            cell ~ " population setup refused public openGl owners");
        scope (exit) ownerA.discardPrepared(preparedA);
        scope (exit) ownerB.discardPrepared(preparedB);
        assertPopulationFloor(cell);

        ValidatedGpuResourceToken validatedA;
        assert(ownerA.validatePrepared(preparedA, 7, 11, validatedA),
            cell ~ " validation refused the first live record");
        ownerA.installPrepared(validatedA);
        assertNamesLive(namesB, cell);
        assertNamesDead(namesA, cell);
        assert(gpuA.faceVao == 0 && gpuA.edgeVao == 0 && gpuA.vertVao == 0
            && gpuA.faceVbo == 0 && gpuA.edgeVbo == 0 && gpuA.vertVbo == 0
            && gpuA.faceIdVbo == 0 && gpuA.matIdVbo == 0
            && gpuA.weightColorVbo == 0,
            cell ~ " did not clear the consumed GpuMesh header");
        assertRelatedHeaderCleared(gpuA, cell);
    });
}

unittest // GpuCreateUploadOwner.abortEnlisted reaches cleanupPrepared.
{
    withGlBoundary({
        enum cell = "GpuCreateUploadOwner.cleanupPrepared";
        auto source = makeCube();
        GpuMesh targetA;
        GpuMesh targetB;
        auto ownerA = new GpuCreateUploadOwner(&targetA, 7, 11);
        auto ownerB = new GpuCreateUploadOwner(&targetB, 7, 11);
        scope (exit) ownerA.abortEnlisted();
        scope (exit) ownerB.abortEnlisted();

        assert(ownerA.beginEnlisted(source) && ownerB.beginEnlisted(source),
            cell ~ " population setup refused public openGl owners");
        assertPopulationFloor(cell);
        const namesA = generatedOwnerNames(0);
        const namesB = generatedOwnerNames(1);

        ownerA.abortEnlisted();
        assertNamesLive(namesB, cell);
        assertNamesDead(namesA, cell);
    });
}

unittest // Legacy destroy releases names but retains its header policy.
{
    withGlBoundary({
        enum cell = "GpuMesh.destroy";
        auto stamp = makeCube();
        GpuMesh gpu;
        gpu.init();
        setRelatedHeaderState(gpu, &stamp);
        const names = gpuNames(gpu);

        gpu.destroy();
        assertNamesDead(names, cell);
        assert(gpuNames(gpu) == names,
            cell ~ " changed the retained GPU-name header");
        assert(gpu.faceVertCount == 31 && gpu.edgeVertCount == 32
            && gpu.vertCount == 33 && gpu.faceTriStart == [34]
            && gpu.faceTriCount == [35] && gpu.suppressCageUpload
            && gpu.edgeOriginGpu == [36] && gpu.faceOriginGpu == [37]
            && gpu.vertOriginGpu == [38] && gpu.faceCornerVert == [39]
            && gpu.weightStampMesh is &stamp
            && gpu.weightStampName == "gpu-header-sentinel"
            && gpu.weightStampValid && gpu.uploadVersion == 40,
            cell ~ " changed related retained header state");
    });
}

unittest // The module contains one typed low-level GPU-name delete sequence.
{
    const source = readText(buildPath(repoRoot, "source", "mesh_gpu.d"));
    const vaoDeletes = source.count("glDeleteVertexArrays(");
    const vboDeletes = source.count("glDeleteBuffers(");
    assert(vaoDeletes == 3, format(
        "GPU-name deleter census: expected 3 VAO calls in one sequence, got %s",
        vaoDeletes));
    assert(vboDeletes == 6, format(
        "GPU-name deleter census: expected 6 VBO calls in one sequence, got %s",
        vboDeletes));
}
