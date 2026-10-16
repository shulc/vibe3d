module prepared_loop_slice_deactivate;

import core.atomic : atomicOp;
import vibe3d.documents.model.document : Layer;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.mesh.snapshot.snapshot : MeshSnapshot;
import tools.slice.loop_slice_tool : LoopSliceTool,
    PreparedLoopSliceDeactivateImage;

struct PreparedLoopSliceDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedLoopSliceDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextLoopSliceDeactivateOwner;

final class PreparedLoopSliceDeactivateOwner {
private:
    LoopSliceTool target_; Layer layer_; Mesh* source_;
    PreparedLoopSliceDeactivateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedLoopSliceDeactivateToken prepared_;
    ValidatedLoopSliceDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedLoopSliceDeactivateOwner prepare(LoopSliceTool target,
            Layer layer) {
        if (target is null || target.classinfo !is LoopSliceTool.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedLoopSliceDeactivateOwner(target, layer);
        owner.image_ = target.buildPreparedDeactivateState(layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool appliesMesh() const nothrow @nogc { return image_.appliesMesh; }
    @property bool historyEligible() const nothrow @nogc { return image_.historyEligible; }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    ref const(Mesh) candidate() const return scope nothrow @nogc { return image_.candidate; }
    MeshSnapshot beforeSnapshot() { return image_.expectedBefore; }
    void markHistoryPrepared() nothrow @nogc { image_.installBeforeFromLive = true; }
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
    this(LoopSliceTool target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextLoopSliceDeactivateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; layer_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
