module prepared_bridge_activation;

import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import tools.edit.bridge_tool : BridgeTool, PreparedBridgeActivationImage,
    PreparedBridgeDeactivateImage;

struct PreparedBridgeActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedBridgeActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextBridgeActivationOwner;

final class PreparedBridgeActivationOwner {
private:
    BridgeTool target_; Mesh* source_;
    PreparedBridgeActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedBridgeActivationToken prepared_;
    ValidatedBridgeActivationToken validatedToken_;
public:
    @disable this();
    static PreparedBridgeActivationOwner prepare(BridgeTool target) {
        if (target is null || target.classinfo !is BridgeTool.classinfo) return null;
        auto result = new PreparedBridgeActivationOwner(target);
        result.image_ = target.buildPreparedActivation(result.source_);
        return result.image_.valid ? result : null;
    }
    @property bool selectionValid() const nothrow @nogc {
        return image_.selectionValid;
    }
    @property ref const(Mesh) previewMesh() return scope nothrow @nogc {
        return image_.preview;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is BridgeTool.classinfo ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            target_.preparedActivationMesh() !is source_ || source_ is null ||
            target_.preparedActivationMode() != image_.mode ||
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
        return !image_.valid && !image_.baseline.filled && image_.loopA.length == 0 &&
            image_.loopB.length == 0 && image_.capFaces.length == 0;
    }
private:
    this(BridgeTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextBridgeActivationOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

struct PreparedBridgeDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedBridgeDeactivateToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextBridgeDeactivateOwner;

final class PreparedBridgeDeactivateOwner {
private:
    BridgeTool target_;
    PreparedBridgeDeactivateImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedBridgeDeactivateToken prepared_;
    ValidatedBridgeDeactivateToken validatedToken_;
public:
    @disable this();
    static PreparedBridgeDeactivateOwner prepare(BridgeTool target) {
        if (target is null || target.classinfo !is BridgeTool.classinfo) return null;
        auto result = new PreparedBridgeDeactivateOwner(target);
        result.image_ = target.buildPreparedDeactivateState();
        return result.image_.valid ? result : null;
    }
    bool setEffectiveSegments(uint value) nothrow @nogc {
        if (!image_.valid || target_ is null || pending_ || validated_ || consumed_)
            return false;
        image_.effectiveSegments = value;
        return true;
    }
    @property ref const(PreparedBridgeDeactivateImage) image()
            return scope nothrow @nogc { return image_; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is BridgeTool.classinfo ||
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
        return !image_.valid && image_.loopA.length == 0 &&
            image_.loopB.length == 0 && image_.capFaces.length == 0 &&
            target_ is null;
    }
private:
    this(BridgeTool target) {
        target_ = target; owner_ = atomicOp!"+="(nextBridgeDeactivateOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; pending_ = validated_ = false;
        consumed_ = true; prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
