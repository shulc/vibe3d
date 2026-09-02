module prepared_box_param;

import prepared_record_context : PreparedRecordContext;
import prepared_tool_effect : PreparedBoxParamEffect;
import tools.create.box : BoxTool, PreparedBoxParamProjection;

final class PreparedBoxParamOwner {
private:
    BoxTool target_;
    PreparedBoxParamProjection expected_;
    PreparedBoxParamEffect effect_;
    bool begun_, consumed_;
public:
    static PreparedBoxParamOwner prepare(BoxTool target,
            PreparedRecordContext context, string name) {
        if (target is null || context is null) return null;
        auto result = new PreparedBoxParamOwner();
        result.target_ = target;
        result.expected_ = target.capturePreparedBoxParamProjection();
        result.effect_ = target.prepareParamChanged(context, name);
        return result;
    }
    bool historyAccepted() const nothrow @nogc {
        return effect_.historyAccepted;
    }
    bool begin() nothrow @nogc {
        if (begun_ || consumed_ || target_ is null) return false;
        begun_ = true; return true;
    }
    bool validate() const nothrow @nogc {
        return begun_ && !consumed_ && target_ !is null &&
            target_.matchesPreparedBoxParamProjection(expected_);
    }
    void install() nothrow @nogc {
        if (!validate()) return;
        target_.installPreparedBoxParam(effect_);
        consumed_ = true; begun_ = false; target_ = null;
    }
    void abort() nothrow @nogc {
        if (consumed_) return;
        consumed_ = true; begun_ = false; target_ = null;
    }
}
