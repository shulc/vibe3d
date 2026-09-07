module bg_gpu_cache;

import document   : Document, Layer, kindInfo;
import mesh       : Mesh;
import mesh_dirty : MeshDirtyKey, g_bgGpuUploads, g_displayEpochs;
import mesh_gpu   : GpuMesh;

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
        private bool fakeGpuForTest_;
        private uint nextFakeNameForTest_ = 1;
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
        version (unittest) {
            if (fakeGpuForTest_) {
                gpu.faceVao = nextFakeNameForTest_++;
                gpu.faceVbo = nextFakeNameForTest_++;
                gpu.edgeVao = nextFakeNameForTest_++;
                gpu.edgeVbo = nextFakeNameForTest_++;
                gpu.vertVao = nextFakeNameForTest_++;
                gpu.vertVbo = nextFakeNameForTest_++;
                gpu.faceIdVbo = nextFakeNameForTest_++;
                gpu.matIdVbo = nextFakeNameForTest_++;
                gpu.weightColorVbo = nextFakeNameForTest_++;
                return;
            }
        }
        gpu.init();
    }

    private void uploadGpu(ref GpuMesh gpu, ref const Mesh mesh) {
        version (unittest) {
            if (fakeGpuForTest_) {
                ++fakeUploadsForTest_;
                ++gpu.uploadVersion;
                return;
            }
        }
        gpu.upload(mesh);
    }

    private void release(Entry entry) {
        if (entry is null) return;
        version (unittest) {
            if (fakeGpuForTest_) {
                entry.gpu = GpuMesh();
                return;
            }
        }
        entry.gpu.destroy();
        // `GpuMesh.destroy` releases GL names but does not clear the struct.
        // Clearing the owned object makes repeated release impossible and lets
        // an observer of this very resource distinguish live from released.
        entry.gpu = GpuMesh();
    }
}

unittest {
    import std.format : format;

    auto primary = new Layer;
    auto backgroundA = new Layer;
    auto backgroundB = new Layer;
    Document document;
    document.layers = [primary, backgroundA, backgroundB];
    document.setActive(0);

    auto cache = new BgGpuCache;
    cache.fakeGpuForTest_ = true;
    auto draw = cache.drawCache();

    // Population floor: exercise the same create/upload verb the renderer
    // uses, then pin both entries and all nine names owned by each GpuMesh.
    draw.gpuFor(backgroundA);
    draw.gpuFor(backgroundB);
    immutable size_t populated = cache.entries_.length;
    assert(populated == 2, format(
        "population floor: expected exactly 2 background GPU cache entries "
      ~ "before eviction, got %d", populated));
    assert(cache.fakeUploadsForTest_ == 2,
        "population floor: both background entries must pass through upload");

    size_t resourceNames(const GpuMesh* gpu) {
        immutable uint[9] names = [
            gpu.faceVao, gpu.faceVbo, gpu.edgeVao, gpu.edgeVbo,
            gpu.vertVao, gpu.vertVbo, gpu.faceIdVbo, gpu.matIdVbo,
            gpu.weightColorVbo,
        ];
        size_t count;
        foreach (name; names) if (name != 0) ++count;
        return count;
    }
    // Hold the owner's entry objects themselves. These are the exact GpuMesh
    // fields that release mutates, rather than a separate release counter.
    auto entryA = cache.entries_[backgroundA];
    auto entryB = cache.entries_[backgroundB];
    assert(resourceNames(&entryA.gpu) == 9 && resourceNames(&entryB.gpu) == 9,
        "population floor: each of the 2 owner entries must hold 9 GPU names");

    // A separate frame starts after the document has only its primary layer.
    // No draw-cache method is called in this phase: reconcile alone must free
    // the resources and evict both stale Layer keys.
    document.layers = document.layers[0 .. 1];
    cache.reconcile(document);
    assert(resourceNames(&entryA.gpu) == 0 && resourceNames(&entryB.gpu) == 0,
        "no-draw frame reconcile left GPU names live on an evicted owner entry");
    assert(cache.entries_.length == 0,
        "no-draw frame reconcile retained stale background Layer entries");

    // Shutdown owns the same release operation for still-live entries.
    document.layers = [primary, backgroundA];
    draw.gpuFor(backgroundA);
    entryA = cache.entries_[backgroundA];
    assert(cache.entries_.length == 1 && resourceNames(&entryA.gpu) == 9,
        "shutdown control did not repopulate one owned GPU entry");
    cache.shutdown();
    assert(resourceNames(&entryA.gpu) == 0 && cache.entries_.length == 0,
        "shutdown did not release the actual owned GPU entry");
}
