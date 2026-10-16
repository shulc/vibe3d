module vibe3d.editing.tools.interactive.prepared_move_update;

import core.atomic : atomicOp;
import vibe3d.util.math.math : Vec3;
import vibe3d.editing.tools.interactive.tools.transform.move : MoveTool, PreparedMoveUpdateImage,
                              PreparedMoveUpdateBranch;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedMoveUpdateKind;

struct PreparedMoveUpdateToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedMoveUpdateToken {
    @disable this(this);
private:
    ulong owner, generation;
}
private shared ulong nextMoveUpdateOwner;

/// Closed owner for the exact MoveTool.update state projection. The detached
/// image remains private; only scalar tokens cross PreparedRecordContext.
final class PreparedMoveUpdateOwner {
private:
    version(unittest) static size_t abortCount_;
    MoveTool target_;
    PreparedMoveUpdateImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedMoveUpdateToken prepared_;
    ValidatedMoveUpdateToken validatedToken_;
public:
    @disable this();
    static PreparedMoveUpdateOwner prepare(MoveTool target,
            bool ownerEditOpen, Vec3 actionCenter) {
        if (target is null || target.classinfo !is MoveTool.classinfo) return null;
        auto result = new PreparedMoveUpdateOwner(target);
        result.image_ = target.buildPreparedMoveUpdate(
            ownerEditOpen, actionCenter);
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_;
        return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is MoveTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_)
            return false;
        validated_ = true;
        validatedToken_.owner = owner_; validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0;
        return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedMoveUpdate(image_);
        consume();
    }
    void abort() nothrow @nogc {
        if (!consumed_) {
            version(unittest) ++abortCount_;
            image_.clear(); consume();
        }
    }
    PreparedMoveUpdateKind effectKind() const nothrow @nogc {
        if (!image_.valid) return PreparedMoveUpdateKind.None;
        final switch (image_.branch) {
        case PreparedMoveUpdateBranch.InactiveNoop:
            return PreparedMoveUpdateKind.InactiveNoop;
        case PreparedMoveUpdateBranch.DraggingNoop:
            return PreparedMoveUpdateKind.DraggingNoop;
        case PreparedMoveUpdateBranch.WrapperEditOpenNoop:
            return PreparedMoveUpdateKind.WrapperEditOpenNoop;
        case PreparedMoveUpdateBranch.Refresh:
            return PreparedMoveUpdateKind.Refresh;
        }
    }
    version(unittest) PreparedMoveUpdateBranch branchForTest() const
            nothrow @nogc { return image_.branch; }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid;
    }
    version(unittest) static size_t abortCountForTest() nothrow @nogc {
        return abortCount_;
    }
    version(unittest) void corruptPreparedForTest(bool ownerIdentity)
            nothrow @nogc {
        if (ownerIdentity) ++prepared_.owner; else ++prepared_.generation;
    }
    version(unittest) void corruptValidatedForTest(bool ownerIdentity)
            nothrow @nogc {
        if (ownerIdentity) ++validatedToken_.owner;
        else ++validatedToken_.generation;
    }
private:
    this(MoveTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextMoveUpdateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
