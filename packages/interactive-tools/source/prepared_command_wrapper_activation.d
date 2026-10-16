module prepared_command_wrapper_activation;

import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import tools.common.command_wrapper : CommandWrapperTool,
    PreparedCommandWrapperActivationImage, XfrmSmoothTool, XfrmJitterTool,
    XfrmQuantizeTool;
import tools.slice.edge_slide : EdgeSlideTool;

struct PreparedCommandWrapperActivationToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedCommandWrapperActivationToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextCommandWrapperActivationOwner;

final class PreparedCommandWrapperActivationOwner {
private:
    CommandWrapperTool target_;
    Mesh* source_;
    PreparedCommandWrapperActivationImage image_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedCommandWrapperActivationToken prepared_;
    ValidatedCommandWrapperActivationToken validatedToken_;
public:
    @disable this();
    static PreparedCommandWrapperActivationOwner prepare(CommandWrapperTool target) {
        if (!exactProduct(target)) return null;
        auto result = new PreparedCommandWrapperActivationOwner(target);
        result.source_ = target.preparedActivationMesh();
        result.image_ = target.buildPreparedActivation();
        return result.source_ !is null && result.image_.valid ? result : null;
    }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true;
        prepared_.owner = owner_; prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || !exactProduct(target_) ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedActivationMatches(source_, image_.baseline)) return false;
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
        if (consumed_) return; image_.clear(); consume();
    }
    version(unittest) void corruptPreparedForTest() nothrow @nogc {
        ++prepared_.generation;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && image_.baseline.length == 0 &&
            image_.falloffs.length == 0 && image_.clickHandle is null;
    }
private:
    this(CommandWrapperTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextCommandWrapperActivationOwner, 1UL);
    }
    static bool exactProduct(CommandWrapperTool target) nothrow @nogc {
        return target !is null && (target.classinfo is XfrmSmoothTool.classinfo ||
            target.classinfo is XfrmJitterTool.classinfo ||
            target.classinfo is XfrmQuantizeTool.classinfo ||
            target.classinfo is EdgeSlideTool.classinfo);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; source_ = null;
        pending_ = validated_ = false; consumed_ = true;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
