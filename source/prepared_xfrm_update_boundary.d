module prepared_xfrm_update_boundary;

import core.atomic : atomicOp;
import tools.transform.xfrm_transform : XfrmTransformTool,
    PreparedXfrmUpdateBoundaryImage, PreparedXfrmUpdatePreProjection;

struct PreparedXfrmUpdateBoundaryToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedXfrmUpdateBoundaryToken {
    @disable this(this);
private:
    ulong owner, generation;
}
private shared ulong nextXfrmUpdateBoundaryOwner;

final class PreparedXfrmUpdateBoundaryOwner {
private:
    XfrmTransformTool target_;
    PreparedXfrmUpdateBoundaryImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedXfrmUpdateBoundaryToken prepared_;
    ValidatedXfrmUpdateBoundaryToken validatedToken_;
public:
    @disable this();
    static PreparedXfrmUpdateBoundaryOwner prepare(XfrmTransformTool target,
            ref const PreparedXfrmUpdatePreProjection projection) {
        if (target is null || target.classinfo !is XfrmTransformTool.classinfo)
            return null;
        auto owner = new PreparedXfrmUpdateBoundaryOwner(target);
        owner.image_ = target.buildPreparedUpdateBoundary(projection);
        return owner.image_.valid ? owner : null;
    }
    bool closesRun() const nothrow @nogc { return image_.invalidateRefire; }
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
            !target_.preparedUpdateBoundaryMatches(image_)) return false;
        validated_ = true;
        validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0;
        return true;
    }
    void install() nothrow {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedUpdateBoundary(image_);
        consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) { image_.clear(); consume(); }
    }
private:
    this(XfrmTransformTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextXfrmUpdateBoundaryOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
