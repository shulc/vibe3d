module prepared_xfrm_slot_poll;

import core.atomic : atomicOp;
import tools.transform.xfrm_transform : XfrmTransformTool,
    PreparedXfrmSlotPollImage, PreparedXfrmUpdatePreProjection;

struct PreparedXfrmSlotPollToken { @disable this(this); private: ulong owner, generation; }
struct ValidatedXfrmSlotPollToken { @disable this(this); private: ulong owner, generation; }
private shared ulong nextXfrmSlotPollOwner;

final class PreparedXfrmSlotPollOwner {
private:
    XfrmTransformTool target_;
    PreparedXfrmSlotPollImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedXfrmSlotPollToken prepared_;
    ValidatedXfrmSlotPollToken validatedToken_;
public:
    @disable this();
    static PreparedXfrmSlotPollOwner prepare(XfrmTransformTool target,
            ref const PreparedXfrmUpdatePreProjection projection) {
        if (target is null || target.classinfo !is XfrmTransformTool.classinfo)
            return null;
        auto owner = new PreparedXfrmSlotPollOwner(target);
        owner.image_ = target.buildPreparedSlotPoll(projection);
        return owner.image_.valid ? owner : null;
    }
    bool boundary() const nothrow @nogc { return image_.boundary; }
    bool pivotMoved() const nothrow @nogc { return image_.pivotMoved; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is XfrmTransformTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedSlotPollMatches(image_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedSlotPoll(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
private:
    this(XfrmTransformTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextXfrmSlotPollOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null; prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
