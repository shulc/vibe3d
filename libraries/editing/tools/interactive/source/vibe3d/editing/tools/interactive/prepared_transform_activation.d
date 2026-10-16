module vibe3d.editing.tools.interactive.prepared_transform_activation;

import core.atomic : atomicOp;
import vibe3d.editing.tools.interactive.tools.transform.transform : TransformTool, PreparedTransformActivationImage;
import vibe3d.editing.tools.interactive.tools.alignment.linear_align_tool : LinearAlignTool;
import vibe3d.editing.tools.interactive.tools.alignment.radial_align_tool : RadialAlignTool;
import vibe3d.editing.tools.interactive.tools.deform.bend : BendTool;
import vibe3d.editing.tools.interactive.tools.deform.push : PushTool;

struct PreparedTransformActivationToken { @disable this(this); private: ulong owner, generation; }
struct ValidatedTransformActivationToken { @disable this(this); private: ulong owner, generation; }
private shared ulong nextTransformActivationOwner;

/// Closed activation projection for exact registered products whose activation
/// is precisely `super.activate()`.
final class PreparedTransformActivationOwner {
private:
    TransformTool target_;
    PreparedTransformActivationImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTransformActivationToken prepared_;
    ValidatedTransformActivationToken validatedToken_;
public:
    @disable this();
    static PreparedTransformActivationOwner prepare(TransformTool target) {
        if (!admit(target)) return null;
        auto result = new PreparedTransformActivationOwner(target);
        result.image_ = target.buildPreparedActivationImage(); return result;
    }
    bool owns(TransformTool target) const nothrow @nogc { return target_ is target; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            prepared_.owner != owner_ || prepared_.generation != generation_) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedActivation(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    version(unittest) bool payloadEmpty() const nothrow @nogc { return !image_.valid; }
private:
    static bool admit(TransformTool target) nothrow @nogc {
        return target !is null && (target.classinfo is LinearAlignTool.classinfo ||
            target.classinfo is RadialAlignTool.classinfo ||
            target.classinfo is BendTool.classinfo ||
            target.classinfo is PushTool.classinfo);
    }
    this(TransformTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextTransformActivationOwner, 1UL);
    }
    void consume() nothrow @nogc {
        pending_ = validated_ = false; consumed_ = true; target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
