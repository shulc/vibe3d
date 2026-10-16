module vibe3d.editing.tools.interactive.prepared_edge_slice_deactivate;

import core.atomic : atomicOp;
import vibe3d.documents.model.document : Layer;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import vibe3d.editing.tools.interactive.tools.slice.edge_slice_tool : EdgeSliceTool,
    PreparedEdgeSliceDeactivateImage;

struct PreparedEdgeSliceDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedEdgeSliceDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextEdgeSliceDeactivateOwner;

final class PreparedEdgeSliceDeactivateOwner {
private:
    EdgeSliceTool target_; Layer layer_; Mesh* source_;
    PreparedEdgeSliceDeactivateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedEdgeSliceDeactivateToken prepared_;
    ValidatedEdgeSliceDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedEdgeSliceDeactivateOwner prepare(EdgeSliceTool target,
            Layer layer) {
        if (target is null || target.classinfo !is EdgeSliceTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedEdgeSliceDeactivateOwner(target, layer);
        owner.image_ = target.buildPreparedDeactivateState(layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool appliesMesh() const nothrow @nogc { return image_.appliesMesh; }
    @property bool historyEligible() const nothrow @nogc { return image_.historyEligible; }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    ref const(Mesh) candidate() const return scope nothrow @nogc { return image_.candidate; }
    MeshSnapshot beforeSnapshot() {
        return image_.expectedBefore;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || source_ is null) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || layer_ is null ||
            &layer_.meshRef() !is source_ || prepared_.owner != owner_ ||
            prepared_.generation != generation_ ||
            !target_.preparedDeactivateStateMatches(image_, *source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedDeactivateState(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
private:
    this(EdgeSliceTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextEdgeSliceDeactivateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; layer_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
