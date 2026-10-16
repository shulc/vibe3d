module vibe3d.editing.tools.interactive.prepared_transform_product_activation;

import core.atomic : atomicOp;
import vibe3d.editing.tools.interactive.tools.transform.transform : TransformTool;
import vibe3d.editing.tools.interactive.tools.transform.move : MoveTool, PreparedMoveActivationImage;
import vibe3d.editing.tools.interactive.tools.transform.rotate : RotateTool, PreparedRotateActivationImage;
import vibe3d.editing.tools.interactive.tools.transform.scale : ScaleTool, PreparedScaleActivationImage;

enum PreparedTransformProductActivationKind : ubyte { Move, Rotate, Scale }
struct PreparedTransformProductActivationToken { @disable this(this); private: ulong owner, generation; }
struct ValidatedTransformProductActivationToken { @disable this(this); private: ulong owner, generation; }
private shared ulong nextTransformProductActivationOwner;

/// Closed exact-product activation owner. Product images remain owner-held;
/// only scalar identity/generation tokens cross the context boundary.
final class PreparedTransformProductActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    TransformTool target_;
    PreparedTransformProductActivationKind kind_;
    PreparedMoveActivationImage move_;
    PreparedRotateActivationImage rotate_;
    PreparedScaleActivationImage scale_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedTransformProductActivationToken prepared_;
    ValidatedTransformProductActivationToken validatedToken_;
public:
    @disable this();
    static PreparedTransformProductActivationOwner prepare(TransformTool target) {
        if (target is null) return null;
        auto result = new PreparedTransformProductActivationOwner(target);
        if (target.classinfo is MoveTool.classinfo) {
            result.kind_ = PreparedTransformProductActivationKind.Move;
            result.move_ = (cast(MoveTool) target).buildPreparedProductActivation();
            if (!result.move_.valid) return null;
        } else if (target.classinfo is RotateTool.classinfo) {
            result.kind_ = PreparedTransformProductActivationKind.Rotate;
            result.rotate_ = (cast(RotateTool) target).buildPreparedProductActivation();
            if (!result.rotate_.valid) return null;
        } else if (target.classinfo is ScaleTool.classinfo) {
            result.kind_ = PreparedTransformProductActivationKind.Scale;
            result.scale_ = (cast(ScaleTool) target).buildPreparedProductActivation();
            if (!result.scale_.valid) return null;
        } else return null;
        return result;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null) return false;
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
        final switch (kind_) {
        case PreparedTransformProductActivationKind.Move:
            (cast(MoveTool) target_).installPreparedProductActivation(move_); break;
        case PreparedTransformProductActivationKind.Rotate:
            (cast(RotateTool) target_).installPreparedProductActivation(rotate_); break;
        case PreparedTransformProductActivationKind.Scale:
            (cast(ScaleTool) target_).installPreparedProductActivation(scale_); break;
        }
        consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) {
            version(unittest) ++abortCount_;
            scrub(); consume();
        }
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !move_.valid && !rotate_.valid && !scale_.valid;
    }
    version(unittest) static size_t abortCountForTest() nothrow @nogc {
        return abortCount_;
    }
private:
    this(TransformTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextTransformProductActivationOwner, 1UL);
    }
    void scrub() nothrow @nogc { move_.clear(); rotate_.clear(); scale_.clear(); }
    void consume() nothrow @nogc {
        scrub(); pending_ = validated_ = false; consumed_ = true; target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
