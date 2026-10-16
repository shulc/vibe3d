module vibe3d.editing.tools.interactive.prepared_edge_extend_tool_activation;

import core.atomic : atomicOp;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.tools.edit.edge_extend : EdgeExtendTool,
    PreparedEdgeExtendToolActivationImage;
import vibe3d.editing.tools.interactive.prepared_xfrm_activation_session : PreparedXfrmActivationSessionOwner;
import vibe3d.editing.tools.interactive.prepared_transform_product_activation :
    PreparedTransformProductActivationOwner;

struct PreparedEdgeExtendToolActivationPreToken {
    @disable this(this); private ulong owner, generation;
}
struct PreparedEdgeExtendToolActivationPostToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedEdgeExtendToolActivationPreToken {
    @disable this(this); private ulong owner, generation;
}
struct ValidatedEdgeExtendToolActivationPostToken {
    @disable this(this); private ulong owner, generation;
}
private shared ulong nextEdgeExtendToolActivationOwner;

final class PreparedEdgeExtendToolActivationOwner {
private:
    EdgeExtendTool target_; Mesh* source_;
    PreparedEdgeExtendToolActivationImage image_;
    PreparedXfrmActivationSessionOwner xfrmOwner_;
    PreparedTransformProductActivationOwner extraMoveOwner_;
    immutable ulong owner_; ulong generation_;
    bool preBegun_, postBegun_, preValidated_, postValidated_;
    bool preInstalled_, consumed_;
    PreparedEdgeExtendToolActivationPreToken pre_;
    PreparedEdgeExtendToolActivationPostToken post_;
    ValidatedEdgeExtendToolActivationPreToken validatedPre_;
    ValidatedEdgeExtendToolActivationPostToken validatedPost_;
public:
    @disable this();
    static PreparedEdgeExtendToolActivationOwner prepare(EdgeExtendTool target) {
        if (target is null || target.classinfo !is EdgeExtendTool.classinfo) return null;
        auto result = new PreparedEdgeExtendToolActivationOwner(target);
        result.image_ = target.buildPreparedActivation(result.source_);
        if (!result.image_.valid) return null;
        result.xfrmOwner_ = PreparedXfrmActivationSessionOwner.prepare(
            target.preparedEmbeddedXfrm());
        if (result.xfrmOwner_ is null) { result.image_.clear(); return null; }
        if (!result.image_.moveHandle) {
            result.extraMoveOwner_ = PreparedTransformProductActivationOwner.prepare(
                target.preparedEmbeddedMove());
            if (result.extraMoveOwner_ is null) {
                result.xfrmOwner_.abort(); result.image_.clear(); return null;
            }
        }
        return result;
    }
    @property PreparedXfrmActivationSessionOwner xfrmOwner() nothrow @nogc {
        return xfrmOwner_;
    }
    bool beginPre() nothrow @nogc {
        if (preBegun_ || postBegun_ || consumed_ || !shapeValid()) return false;
        ++generation_; preBegun_ = true;
        pre_.owner = owner_; pre_.generation = generation_; return true;
    }
    bool beginPost() nothrow @nogc {
        if (!preBegun_ || postBegun_ || consumed_ || !shapeValid()) return false;
        if (extraMoveOwner_ !is null && !extraMoveOwner_.begin()) return false;
        postBegun_ = true; post_.owner = owner_;
        post_.generation = generation_; return true;
    }
    bool validatePre() nothrow @nogc {
        if (!preBegun_ || !postBegun_ || preValidated_ || consumed_ ||
            !shapeValid() || pre_.owner != owner_ ||
            pre_.generation != generation_ ||
            target_.preparedActivationMesh() !is source_ || source_ is null ||
            !image_.baseline.matches(*source_)) return false;
        preValidated_ = true; validatedPre_.owner = owner_;
        validatedPre_.generation = generation_;
        pre_.owner = pre_.generation = 0; return true;
    }
    bool validatePost() nothrow @nogc {
        if (!preValidated_ || postValidated_ || consumed_ || !shapeValid() ||
            post_.owner != owner_ || post_.generation != generation_ ||
            (extraMoveOwner_ !is null && !extraMoveOwner_.validate())) return false;
        postValidated_ = true; validatedPost_.owner = owner_;
        validatedPost_.generation = generation_;
        post_.owner = post_.generation = 0; return true;
    }
    void installPre() nothrow @nogc {
        if (!preValidated_ || preInstalled_ || consumed_ ||
            validatedPre_.owner != owner_ ||
            validatedPre_.generation != generation_) return;
        target_.installPreparedActivationPre(image_); preInstalled_ = true;
    }
    void installPost() nothrow @nogc {
        if (!postValidated_ || !preInstalled_ || consumed_ ||
            validatedPost_.owner != owner_ ||
            validatedPost_.generation != generation_) return;
        if (extraMoveOwner_ !is null) extraMoveOwner_.install();
        target_.installPreparedActivationPost(image_); consume();
    }
    void abort() nothrow @nogc {
        if (consumed_) return;
        if (xfrmOwner_ !is null) xfrmOwner_.abort();
        if (extraMoveOwner_ !is null) extraMoveOwner_.abort();
        image_.clear(); consume();
    }
    version(unittest) void corruptPreparedForTest(bool post) nothrow @nogc {
        if (post) ++post_.generation; else ++pre_.generation;
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.baseline.filled &&
            (extraMoveOwner_ is null || extraMoveOwner_.payloadEmpty());
    }
private:
    this(EdgeExtendTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextEdgeExtendToolActivationOwner, 1UL);
    }
    bool shapeValid() nothrow @nogc {
        return target_ !is null && image_.valid && xfrmOwner_ !is null &&
            xfrmOwner_.owns(target_.preparedEmbeddedXfrm()) &&
            target_.preparedActivationBanksMatch(image_.moveHandle,
                image_.rotateHandle, image_.scaleHandle);
    }
    void consume() nothrow @nogc {
        image_.clear(); target_ = null; source_ = null; xfrmOwner_ = null;
        extraMoveOwner_ = null; preBegun_ = postBegun_ = false;
        preValidated_ = postValidated_ = preInstalled_ = false; consumed_ = true;
        pre_.owner = pre_.generation = post_.owner = post_.generation = 0;
        validatedPre_.owner = validatedPre_.generation = 0;
        validatedPost_.owner = validatedPost_.generation = 0;
    }
}
