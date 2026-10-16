module vibe3d.editing.tools.interactive.prepared_mirror_activation;

import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.tools.alignment.mirror : MirrorTool, PreparedMirrorActivationImage,
    PreparedMirrorDeactivateImage;

struct PreparedMirrorActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedMirrorActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextMirrorActivationOwner;

final class PreparedMirrorActivationOwner {
private:
    MirrorTool target_; Mesh* source_;
    PreparedMirrorActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedMirrorActivationToken prepared_;
    ValidatedMirrorActivationToken validatedToken_;
public:
    @disable this();
    static PreparedMirrorActivationOwner prepare(MirrorTool target) {
        if (target is null || target.classinfo !is MirrorTool.classinfo) return null;
        auto result = new PreparedMirrorActivationOwner(target);
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
            target_.classinfo !is MirrorTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            target_.preparedActivationMesh() !is source_ || source_ is null ||
            !target_.preparedActivationParamsMatch(image_.params) ||
            !image_.baseline.matches(*source_)) return false;
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
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.baseline.filled && image_.mask.length == 0;
    }
private:
    this(MirrorTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextMirrorActivationOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

struct PreparedMirrorDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedMirrorDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextMirrorDeactivateOwner;

final class PreparedMirrorDeactivateOwner {
private:
    MirrorTool target_;
    PreparedMirrorDeactivateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedMirrorDeactivateToken prepared_;
    ValidatedMirrorDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedMirrorDeactivateOwner prepare(MirrorTool target) {
        if (target is null || target.classinfo !is MirrorTool.classinfo) return null;
        auto result = new PreparedMirrorDeactivateOwner(target);
        result.image_ = target.buildPreparedDeactivateState();
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is MirrorTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedDeactivateStateMatches(image_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedDeactivateState(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && target_ is null;
    }
private:
    this(MirrorTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextMirrorDeactivateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pending_ = validated_ = false;
        consumed_ = true; prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
