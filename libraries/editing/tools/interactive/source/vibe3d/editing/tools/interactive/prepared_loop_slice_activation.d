module vibe3d.editing.tools.interactive.prepared_loop_slice_activation;

import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.tools.slice.loop_slice_tool : LoopSliceTool, PreparedLoopSliceActivationImage;

struct PreparedLoopSliceActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedLoopSliceActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextLoopSliceActivationOwner;

final class PreparedLoopSliceActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    LoopSliceTool target_; Mesh* source_;
    PreparedLoopSliceActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedLoopSliceActivationToken prepared_;
    ValidatedLoopSliceActivationToken validatedToken_;
public:
    @disable this();
    static PreparedLoopSliceActivationOwner prepare(LoopSliceTool target) {
        if (target is null || target.classinfo !is LoopSliceTool.classinfo) return null;
        auto result = new PreparedLoopSliceActivationOwner(target);
        result.image_ = target.buildPreparedActivation(result.source_);
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is LoopSliceTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            target_.preparedActivationMesh() !is source_ || source_ is null ||
            !image_.before.matches(*source_)) return false;
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
    void abort() nothrow @nogc {
        if (consumed_) return; version(unittest) ++abortCount_;
        image_.clear(); consume();
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.before.filled && image_.positions.length == 0;
    }
    version(unittest) static size_t abortCountForTest() nothrow @nogc {
        return abortCount_;
    }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
private:
    this(LoopSliceTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextLoopSliceActivationOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
