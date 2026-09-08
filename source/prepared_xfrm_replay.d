module prepared_xfrm_replay;

import core.atomic : atomicOp;
import prepared_record_context : PreparedRecordContext;
import mesh : Mesh;
import document : Layer;
import tools.transform.xfrm_transform : XfrmTransformTool,
    PreparedXfrmReplayImage, PreparedXfrmUpdatePreProjection;

struct PreparedXfrmReplayToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedXfrmReplayToken {
    @disable this(this);
private:
    ulong owner, generation;
}
private shared ulong nextXfrmReplayOwner;

final class PreparedXfrmReplayOwner {
private:
    XfrmTransformTool target_;
    Layer layer_;
    PreparedXfrmReplayImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedXfrmReplayToken prepared_;
    ValidatedXfrmReplayToken validatedToken_;
public:
    @disable this();
    static PreparedXfrmReplayOwner prepare(XfrmTransformTool target,
            Layer layer,
            ref const PreparedXfrmUpdatePreProjection projection,
            PreparedRecordContext context) {
        if (target is null || target.classinfo !is XfrmTransformTool.classinfo ||
            layer is null || target.preparedMeshForUpdate() !is &layer.meshRef())
            return null;
        auto owner = new PreparedXfrmReplayOwner(target, layer);
        owner.image_ = target.buildPreparedReplay(projection, context);
        return owner.image_.valid ? owner : null;
    }
    bool historyPrepared() const nothrow @nogc { return image_.wrapper; }
    bool meshPrepared() const nothrow @nogc { return image_.meshPrepared; }
    bool itemPrepared() const nothrow @nogc { return image_.itemPrepared; }
    bool wantsWrapperUpload() const nothrow @nogc {
        return image_.meshPrepared && image_.nextCount > 0;
    }
    ref const(Mesh) candidate() const return scope nothrow @nogc {
        return image_.candidate;
    }
    uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_;
        return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is XfrmTransformTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedReplayMatches(image_, layer_.meshRef()))
            return false;
        validated_ = true;
        validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0;
        return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedReplay(image_);
        consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) { image_.clear(); consume(); }
    }
private:
    this(XfrmTransformTool target, Layer layer) {
        target_ = target;
        layer_ = layer;
        owner_ = atomicOp!"+="(nextXfrmReplayOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null;
        layer_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
