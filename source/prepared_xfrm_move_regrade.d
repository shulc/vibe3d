module prepared_xfrm_move_regrade;

import core.atomic : atomicOp;
import prepared_record_context : PreparedRecordContext;
import mesh : Mesh;
import document : Layer;
import tools.transform.xfrm_transform : XfrmTransformTool,
    PreparedXfrmMoveRegradeImage, PreparedXfrmUpdatePreProjection;

struct PreparedXfrmMoveRegradeToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedXfrmMoveRegradeToken {
    @disable this(this);
private:
    ulong owner, generation;
}
private shared ulong nextXfrmMoveRegradeOwner;

final class PreparedXfrmMoveRegradeOwner {
private:
    XfrmTransformTool target_;
    Layer layer_;
    PreparedXfrmMoveRegradeImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedXfrmMoveRegradeToken prepared_;
    ValidatedXfrmMoveRegradeToken validatedToken_;
public:
    @disable this();
    static PreparedXfrmMoveRegradeOwner prepare(XfrmTransformTool target,
            Layer layer,
            ref const PreparedXfrmUpdatePreProjection projection,
            PreparedRecordContext context) {
        if (target is null || target.classinfo !is XfrmTransformTool.classinfo ||
            layer is null || target.preparedMeshForUpdate() !is &layer.meshRef())
            return null;
        auto owner = new PreparedXfrmMoveRegradeOwner(target, layer);
        owner.image_ = target.buildPreparedMoveRegrade(projection, context);
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
            !target_.preparedMoveRegradeMatches(image_, layer_.meshRef()))
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
        target_.installPreparedMoveRegrade(image_);
        consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) { image_.clear(); consume(); }
    }
private:
    this(XfrmTransformTool target, Layer layer) {
        target_ = target;
        layer_ = layer;
        owner_ = atomicOp!"+="(nextXfrmMoveRegradeOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null;
        layer_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
