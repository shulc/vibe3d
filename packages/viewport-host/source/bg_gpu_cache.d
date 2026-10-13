module bg_gpu_cache;

import document   : Document, Layer, kindInfo;
import mesh       : Mesh;
import mesh_dirty : MeshDirtyKey, g_bgGpuUploads, g_displayEpochs;
import mesh_gpu   : GpuMesh;

version (unittest) {
    import bindbc.opengl : GLboolean, GLsizei, GLuint, GL_FALSE, GL_TRUE,
        glDeleteBuffers, glDeleteVertexArrays, glGenBuffers,
        glGenVertexArrays, glIsBuffer, glIsVertexArray;
}

/// Draw-only access to an already reconciled background GPU cache.
/// It can create or refresh an entry needed by the renderer, but exposes
/// neither document reconciliation nor shutdown. Task 4680's ownership and
/// no-draw eviction witness is the in-module unittest below.
struct BgGpuDrawCache {
    private BgGpuCache owner_;

    private this(BgGpuCache owner) {
        assert(owner !is null);
        owner_ = owner;
    }

    GpuMesh* gpuFor(Layer layer) {
        return owner_.gpuFor(layer);
    }

    GpuMesh* find(Layer layer) {
        return owner_.findGpu(layer);
    }
}

/// Sole owner of GPU meshes used to draw visible non-primary layers.
final class BgGpuCache {
    private final class Entry {
        GpuMesh gpu;
        MeshDirtyKey uploaded;
    }

    private Entry[Layer] entries_;

    version (unittest) {
        private bool fakeUploadForTest_;
        private ulong fakeUploadsForTest_;
    }

    BgGpuDrawCache drawCache() {
        return BgGpuDrawCache(this);
    }

    /// Drop entries that no longer name a visible, non-primary geometry
    /// layer. The frame owner calls this once before the per-cell draw loop,
    /// so eviction is independent of both a cell's dirty decision and drawing.
    void reconcile(ref Document document) {
        Layer[] toDrop;
        foreach (layer, entry; entries_) {
            bool live;
            foreach (candidate; document.layers) {
                if (candidate is layer && candidate.visible
                    && !document.isPrimary(candidate)
                    && kindInfo(candidate.kind).drawsGeometry) {
                    live = true;
                    break;
                }
            }
            if (!live) toDrop ~= layer;
        }

        foreach (layer; toDrop) {
            release(entries_[layer]);
            entries_.remove(layer);
        }
    }

    /// Release every owned GPU object while the app's GL context is live.
    /// Idempotent: released entries are removed and a second call is empty.
    void shutdown() {
        foreach (layer, entry; entries_) release(entry);
        entries_ = null;
    }

    private GpuMesh* gpuFor(Layer layer) {
        assert(layer !is null);
        auto slot = layer in entries_;
        Entry entry;
        if (slot is null) {
            entry = new Entry;
            initGpu(entry.gpu);
            entries_[layer] = entry;
        } else {
            entry = *slot;
        }

        Mesh* mesh = &layer.meshRef();
        const size_t address = cast(size_t)mesh;
        const ulong epoch = g_displayEpochs.epochFor(address);
        if (!entry.uploaded.matches(address, epoch)) {
            uploadGpu(entry.gpu, *mesh);
            ++g_bgGpuUploads;
            // Preserve the former background path's freshness rule exactly:
            // the stamp is the epoch read for this comparison.
            entry.uploaded.stamp(address, epoch);
        }
        return &entry.gpu;
    }

    private GpuMesh* findGpu(Layer layer) {
        auto slot = layer in entries_;
        return slot is null ? null : &(*slot).gpu;
    }

    private void initGpu(ref GpuMesh gpu) {
        gpu.init();
    }

    private void uploadGpu(ref GpuMesh gpu, ref const Mesh mesh) {
        version (unittest) {
            if (fakeUploadForTest_) {
                ++fakeUploadsForTest_;
                ++gpu.uploadVersion;
                return;
            }
        }
        gpu.upload(mesh);
    }

    private void release(Entry entry) {
        if (entry is null) return;
        entry.gpu.destroy();
        // `GpuMesh.destroy` releases GL names but does not clear the struct.
        // Clear the owner header so cache idempotence does not depend on stale
        // names; release itself is witnessed at the GL delete boundary.
        entry.gpu = GpuMesh();
    }
}

version (unittest) private struct TestGlNames {
    enum size_t capacity = 64;
    static GLuint nextVao;
    static GLuint nextVbo;
    static bool[capacity] liveVaos;
    static bool[capacity] liveVbos;
    static size_t deletedVaos;
    static size_t deletedVbos;
    static size_t doubleDeletes;

    static void reset() nothrow @nogc {
        nextVao = 1;
        nextVbo = 1;
        liveVaos[] = false;
        liveVbos[] = false;
        deletedVaos = 0;
        deletedVbos = 0;
        doubleDeletes = 0;
    }

    static extern(System) void genVaos(GLsizei count, GLuint* names)
            nothrow @nogc {
        foreach (i; 0 .. count) {
            const name = nextVao++;
            names[i] = name;
            if (name < capacity) liveVaos[name] = true;
        }
    }

    static extern(System) void genVbos(GLsizei count, GLuint* names)
            nothrow @nogc {
        foreach (i; 0 .. count) {
            const name = nextVbo++;
            names[i] = name;
            if (name < capacity) liveVbos[name] = true;
        }
    }

    static extern(System) void deleteVaos(GLsizei count, const(GLuint)* names)
            nothrow @nogc {
        foreach (i; 0 .. count) {
            const name = names[i];
            if (name == 0) continue;
            if (name >= capacity || !liveVaos[name]) {
                ++doubleDeletes;
                continue;
            }
            liveVaos[name] = false;
            ++deletedVaos;
        }
    }

    static extern(System) void deleteVbos(GLsizei count, const(GLuint)* names)
            nothrow @nogc {
        foreach (i; 0 .. count) {
            const name = names[i];
            if (name == 0) continue;
            if (name >= capacity || !liveVbos[name]) {
                ++doubleDeletes;
                continue;
            }
            liveVbos[name] = false;
            ++deletedVbos;
        }
    }

    static extern(System) GLboolean isVao(GLuint name) nothrow @nogc {
        return cast(GLboolean)(name < capacity && liveVaos[name]
            ? GL_TRUE : GL_FALSE);
    }

    static extern(System) GLboolean isVbo(GLuint name) nothrow @nogc {
        return cast(GLboolean)(name < capacity && liveVbos[name]
            ? GL_TRUE : GL_FALSE);
    }
}

version (unittest) private struct TestGpuNames {
    GLuint[3] vaos;
    GLuint[6] vbos;
}

version (unittest) private TestGpuNames gpuNames(ref const GpuMesh gpu) {
    return TestGpuNames(
        [gpu.faceVao, gpu.edgeVao, gpu.vertVao],
        [gpu.faceVbo, gpu.edgeVbo, gpu.vertVbo, gpu.faceIdVbo,
         gpu.matIdVbo, gpu.weightColorVbo]);
}

version (unittest) private bool namesAreNonZero(TestGpuNames names) {
    foreach (name; names.vaos) if (name == 0) return false;
    foreach (name; names.vbos) if (name == 0) return false;
    return true;
}

version (unittest) private bool namesAreLive(TestGpuNames names) {
    foreach (name; names.vaos)
        if (glIsVertexArray(name) != GL_TRUE) return false;
    foreach (name; names.vbos)
        if (glIsBuffer(name) != GL_TRUE) return false;
    return true;
}

version (unittest) private bool namesAreDead(TestGpuNames names) {
    foreach (name; names.vaos)
        if (glIsVertexArray(name) != GL_FALSE) return false;
    foreach (name; names.vbos)
        if (glIsBuffer(name) != GL_FALSE) return false;
    return true;
}

unittest { // reconcile releases only the evicted entry
    import std.format : format;

    auto savedGenVaos = glGenVertexArrays;
    auto savedGenVbos = glGenBuffers;
    auto savedDeleteVaos = glDeleteVertexArrays;
    auto savedDeleteVbos = glDeleteBuffers;
    auto savedIsVao = glIsVertexArray;
    auto savedIsVbo = glIsBuffer;
    scope (exit) {
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

    auto primary = new Layer;
    auto backgroundA = new Layer;
    auto backgroundB = new Layer;
    Document document;
    document.layers = [primary, backgroundA, backgroundB];
    document.setActive(0);

    auto cache = new BgGpuCache;
    scope (exit) cache.shutdown();
    cache.fakeUploadForTest_ = true;
    auto draw = cache.drawCache();

    // Population floor: use the renderer's draw capability to create two
    // distinct entries through GpuMesh.init and its glGen* calls.
    draw.gpuFor(backgroundA);
    draw.gpuFor(backgroundB);
    immutable size_t populated = cache.entries_.length;
    assert(populated == 2, format(
        "population floor: expected exactly 2 background GPU cache entries "
      ~ "before eviction, got %d", populated));
    assert(cache.fakeUploadsForTest_ == 2,
        "population floor: both background entries must pass through upload");

    auto entryA = cache.entries_[backgroundA];
    auto entryB = cache.entries_[backgroundB];
    auto namesA = gpuNames(entryA.gpu);
    auto namesB = gpuNames(entryB.gpu);
    assert(entryA !is entryB && draw.find(backgroundA) is &entryA.gpu
        && draw.find(backgroundB) is &entryB.gpu,
        "mesh identity: draw lookup must retain two distinct owner entries");
    assert(namesAreNonZero(namesA) && namesAreNonZero(namesB)
        && namesAreLive(namesA) && namesAreLive(namesB),
        "population floor: each entry needs 3 live VAO and 6 live VBO names");
    assert(namesA.vaos[0] == namesA.vbos[0],
        "namespace control: fixture must reuse one integer across VAO and VBO");

    // No draw-cache method runs in this phase. Reconcile drops A while B
    // remains live, before any name can be allocated again.
    document.layers = [primary, backgroundB];
    cache.reconcile(document);
    assert(namesAreDead(namesA),
        "reconcile: evicted entry still has live GL names");
    assert(namesAreLive(namesB),
        "reconcile: surviving entry lost its GL names");
    assert(cache.entries_.length == 1 && draw.find(backgroundA) is null
        && draw.find(backgroundB) is &entryB.gpu,
        "reconcile retained the evicted key or lost the surviving mesh identity");
}

unittest { // shutdown releases all entries once
    import std.format : format;

    auto savedGenVaos = glGenVertexArrays;
    auto savedGenVbos = glGenBuffers;
    auto savedDeleteVaos = glDeleteVertexArrays;
    auto savedDeleteVbos = glDeleteBuffers;
    auto savedIsVao = glIsVertexArray;
    auto savedIsVbo = glIsBuffer;
    scope (exit) {
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

    auto primary = new Layer;
    auto backgroundA = new Layer;
    auto backgroundB = new Layer;
    Document document;
    document.layers = [primary, backgroundA, backgroundB];
    document.setActive(0);

    auto cache = new BgGpuCache;
    scope (exit) cache.shutdown();
    cache.fakeUploadForTest_ = true;
    auto draw = cache.drawCache();
    draw.gpuFor(backgroundA);
    draw.gpuFor(backgroundB);

    immutable size_t populated = cache.entries_.length;
    assert(populated == 2, format(
        "population floor: expected exactly 2 entries before shutdown, got %d",
        populated));
    assert(cache.fakeUploadsForTest_ == 2,
        "population floor: shutdown entries must pass through upload");
    auto entryA = cache.entries_[backgroundA];
    auto entryB = cache.entries_[backgroundB];
    auto namesA = gpuNames(entryA.gpu);
    auto namesB = gpuNames(entryB.gpu);
    assert(entryA !is entryB && namesAreNonZero(namesA)
        && namesAreNonZero(namesB) && namesAreLive(namesA)
        && namesAreLive(namesB),
        "population floor: shutdown needs 2 entries with 3 live VAO and 6 live VBO names each");

    cache.shutdown();
    assert(namesAreDead(namesA) && namesAreDead(namesB),
        "shutdown: owned entries still have live GL names");
    assert(cache.entries_.length == 0 && TestGlNames.deletedVaos == 6
        && TestGlNames.deletedVbos == 12 && TestGlNames.doubleDeletes == 0,
        "shutdown must delete 6 VAO and 12 VBO names exactly once");

    cache.shutdown();
    assert(TestGlNames.deletedVaos == 6 && TestGlNames.deletedVbos == 12
        && TestGlNames.doubleDeletes == 0,
        "repeated shutdown attempted to delete a GL name twice");
}
