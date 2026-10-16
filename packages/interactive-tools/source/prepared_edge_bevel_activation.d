module prepared_edge_bevel_activation;

import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import tools.edit.edge_bevel : EdgeBevelTool, PreparedEdgeBevelActivationImage;

struct PreparedEdgeBevelActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedEdgeBevelActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextEdgeBevelActivationOwner;

final class PreparedEdgeBevelActivationOwner {
private:
    version(unittest) static size_t abortCount_;
    EdgeBevelTool target_; Mesh* source_;
    PreparedEdgeBevelActivationImage image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedEdgeBevelActivationToken prepared_;
    ValidatedEdgeBevelActivationToken validatedToken_;
public:
    @disable this();
    static PreparedEdgeBevelActivationOwner prepare(EdgeBevelTool target) {
        if (target is null || target.classinfo !is EdgeBevelTool.classinfo)
            return null;
        auto result = new PreparedEdgeBevelActivationOwner(target);
        result.image_ = target.buildPreparedActivation(result.source_);
        return result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid)
            return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_;
        return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            target_.classinfo !is EdgeBevelTool.classinfo ||
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
        if (consumed_) return;
        version(unittest) ++abortCount_;
        image_.clear(); consume();
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.before.filled &&
            image_.before.vertices.length == 0 && image_.before.faces.length == 0;
    }
    version(unittest) static size_t abortCountForTest() nothrow @nogc {
        return abortCount_;
    }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
private:
    this(EdgeBevelTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextEdgeBevelActivationOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
