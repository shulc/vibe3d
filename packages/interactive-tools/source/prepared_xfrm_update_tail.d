module prepared_xfrm_update_tail;

import core.atomic : atomicOp;
import operator : VectorStack;
import tools.transform.xfrm_transform : XfrmTransformTool,
    PreparedXfrmUpdateTailImage;

struct PreparedXfrmUpdateTailToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedXfrmUpdateTailToken {
    @disable this(this);
private:
    ulong owner, generation;
}
private shared ulong nextXfrmUpdateTailOwner;

/// Closed owner for the wrapper writes which follow the three sub-tool update
/// resources. The image is built before any live bank is installed and is
/// validated again after those resources, so unexpected bank replacement or
/// wrapper-state drift refuses the whole record.
final class PreparedXfrmUpdateTailOwner {
private:
    XfrmTransformTool target_;
    PreparedXfrmUpdateTailImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedXfrmUpdateTailToken prepared_;
    ValidatedXfrmUpdateTailToken validatedToken_;
public:
    @disable this();

    static PreparedXfrmUpdateTailOwner prepare(XfrmTransformTool target,
                                                ref VectorStack vts,
                                                bool forceClearNeedsGpu = false) {
        if (target is null || target.classinfo !is XfrmTransformTool.classinfo)
            return null;
        auto owner = new PreparedXfrmUpdateTailOwner(target);
        owner.image_ = target.buildPreparedUpdateTail(vts, forceClearNeedsGpu);
        return owner.image_.valid ? owner : null;
    }

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
            !target_.preparedUpdateTailMatches(image_)) return false;
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
        target_.installPreparedUpdateTail(image_);
        consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) { image_.clear(); consume(); }
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid;
    }
private:
    this(XfrmTransformTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextXfrmUpdateTailOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
