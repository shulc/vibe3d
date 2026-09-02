module prepared_xfrm_update_edit_close;

import core.atomic : atomicOp;
import prepared_record_context : PreparedRecordContext;
import tools.transform.xfrm_transform : XfrmTransformTool,
    PreparedXfrmEditCloseImage;

struct PreparedXfrmUpdateEditCloseToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedXfrmUpdateEditCloseToken {
    @disable this(this);
private:
    ulong owner, generation;
}
private shared ulong nextXfrmUpdateEditCloseOwner;

final class PreparedXfrmUpdateEditCloseOwner {
private:
    XfrmTransformTool target_;
    PreparedXfrmEditCloseImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedXfrmUpdateEditCloseToken prepared_;
    ValidatedXfrmUpdateEditCloseToken validatedToken_;
public:
    @disable this();
    static PreparedXfrmUpdateEditCloseOwner prepare(
            XfrmTransformTool target, PreparedRecordContext context,
            string label) {
        if (target is null || target.classinfo !is XfrmTransformTool.classinfo)
            return null;
        auto owner = new PreparedXfrmUpdateEditCloseOwner(target);
        owner.image_ = target.buildPreparedUpdateEditClose(context, label);
        return owner.image_.valid ? owner : null;
    }
    bool historyPrepared() const nothrow @nogc {
        return image_.historyPrepared;
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
            !target_.preparedUpdateEditCloseMatches(image_)) return false;
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
        target_.installPreparedUpdateEditClose(image_);
        consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) { image_.clear(); consume(); }
    }
private:
    this(XfrmTransformTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextXfrmUpdateEditCloseOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
