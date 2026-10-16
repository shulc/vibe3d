module vibe3d.editing.tools.interactive.prepared_xfrm_activation_session;

import core.atomic : atomicOp;
import vibe3d.editing.tools.interactive.tools.transform.xfrm_transform : XfrmTransformTool,
    PreparedXfrmActivationResetImage;
import vibe3d.editing.tools.interactive.tools.transform.move : MoveTool;
import vibe3d.editing.pipeline.evaluation.toolpipe.stages.actcenter : ActionCenterStage;
import vibe3d.editing.tools.interactive.tools.transform.rotate : RotateTool;
import vibe3d.editing.tools.interactive.tools.transform.scale : ScaleTool;
import vibe3d.editing.tools.interactive.prepared_transform_product_activation :
    PreparedTransformProductActivationOwner;

struct PreparedXfrmActivationPreToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct PreparedXfrmActivationPostToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedXfrmActivationPreToken {
    @disable this(this);
private:
    ulong owner, generation;
}
struct ValidatedXfrmActivationPostToken {
    @disable this(this);
private:
    ulong owner, generation;
}
private shared ulong nextXfrmActivationOwner;

/// Exact two-phase Xfrm activation owner. Pre installs the wrapper reset,
/// enabled product activations in T/R/S order and owner-provided bank inputs.
/// Post installs routing/session tail after the prepared history marker.
final class PreparedXfrmActivationSessionOwner {
private:
    XfrmTransformTool target_;
    MoveTool move_;
    RotateTool rotate_;
    ScaleTool scale_;
    PreparedXfrmActivationResetImage reset_;
    PreparedTransformProductActivationOwner moveOwner_;
    PreparedTransformProductActivationOwner rotateOwner_;
    PreparedTransformProductActivationOwner scaleOwner_;
    immutable ulong owner_;
    ulong generation_;
    immutable ubyte flags_;
    bool preBegun_, postBegun_, validated_, preInstalled_, consumed_;
    PreparedXfrmActivationPreToken pre_;
    PreparedXfrmActivationPostToken post_;
    ValidatedXfrmActivationPreToken validatedPre_;
    ValidatedXfrmActivationPostToken validatedPost_;
    ActionCenterStage placementAcen_;   // W1 (task 7144): the activation's latch
public:
    @disable this();

    static PreparedXfrmActivationSessionOwner prepare(XfrmTransformTool target) {
        if (target is null || target.classinfo !is XfrmTransformTool.classinfo)
            return null;
        auto owner = new PreparedXfrmActivationSessionOwner(target);
        owner.reset_ = target.buildPreparedActivationReset();
        if (!owner.reset_.valid) return null;
        if ((owner.flags_ & 1) != 0) {
            owner.moveOwner_ = PreparedTransformProductActivationOwner.prepare(owner.move_);
            if (owner.moveOwner_ is null) { owner.reset_.clear(); return null; }
        }
        if ((owner.flags_ & 2) != 0) {
            owner.rotateOwner_ = PreparedTransformProductActivationOwner.prepare(owner.rotate_);
            if (owner.rotateOwner_ is null) { owner.scrub(); return null; }
        }
        if ((owner.flags_ & 4) != 0) {
            owner.scaleOwner_ = PreparedTransformProductActivationOwner.prepare(owner.scale_);
            if (owner.scaleOwner_ is null) { owner.scrub(); return null; }
        }
        return owner;
    }

    ubyte flags() const nothrow @nogc { return flags_; }
    bool owns(XfrmTransformTool target) const nothrow @nogc {
        return target_ is target;
    }

    bool beginPre() nothrow @nogc {
        if (preBegun_ || postBegun_ || consumed_ || !shapeValid()) return false;
        if (moveOwner_ !is null && !moveOwner_.begin()) return false;
        if (rotateOwner_ !is null && !rotateOwner_.begin()) {
            if (moveOwner_ !is null) moveOwner_.abort();
            return false;
        }
        if (scaleOwner_ !is null && !scaleOwner_.begin()) {
            if (rotateOwner_ !is null) rotateOwner_.abort();
            if (moveOwner_ !is null) moveOwner_.abort();
            return false;
        }
        ++generation_; preBegun_ = true;
        pre_.owner = owner_; pre_.generation = generation_;
        return true;
    }

    bool beginPost() nothrow @nogc {
        if (!preBegun_ || postBegun_ || validated_ || consumed_ ||
            !shapeValid()) return false;
        postBegun_ = true; post_.owner = owner_;
        post_.generation = generation_; return true;
    }

    bool validatePre() nothrow @nogc {
        if (!preBegun_ || !postBegun_ || validated_ || consumed_ ||
            !shapeValid() || pre_.owner != owner_ ||
            pre_.generation != generation_) return false;
        if (moveOwner_ !is null && !moveOwner_.validate()) return false;
        if (rotateOwner_ !is null && !rotateOwner_.validate()) return false;
        if (scaleOwner_ !is null && !scaleOwner_.validate()) return false;
        validated_ = true; validatedPre_.owner = owner_;
        validatedPre_.generation = generation_;
        pre_.owner = pre_.generation = 0; return true;
    }

    bool validatePost() nothrow @nogc {
        if (!validated_ || consumed_ || !shapeValid() ||
            post_.owner != owner_ || post_.generation != generation_)
            return false;
        validatedPost_.owner = owner_;
        validatedPost_.generation = generation_;
        post_.owner = post_.generation = 0; return true;
    }

    void installPre() nothrow @nogc {
        if (!validated_ || preInstalled_ || consumed_ ||
            validatedPre_.owner != owner_ ||
            validatedPre_.generation != generation_) return;
        target_.installPreparedActivationResetPre(reset_);
        if (moveOwner_ !is null) moveOwner_.install();
        if (rotateOwner_ !is null) rotateOwner_.install();
        if (scaleOwner_ !is null) scaleOwner_.install();
        target_.installPreparedBankInputs();
        preInstalled_ = true;
    }

    void installPost() nothrow @nogc {
        if (!validated_ || !preInstalled_ || consumed_ ||
            validatedPost_.owner != owner_ ||
            validatedPost_.generation != generation_) return;
        target_.installPreparedActivationResetPost(reset_);
        // W1 — a transform ACTIVATION places the action centre (the handle),
        // so it latches the authoring side there. Deferred: the centre is the
        // next ACEN evaluation's (C-activation, gap 330; task 7144).
        if (placementAcen_ !is null) placementAcen_.notePlacement();
        consume();
    }

    /// Arm W1: the installed activation will note a placement on `acen`.
    /// Called ONLY by `XfrmTransformTool.prepareActivate`.
    void placeActionCentreOnInstall(ActionCenterStage acen) nothrow @nogc {
        placementAcen_ = acen;
    }

    void abort() nothrow @nogc {
        if (consumed_) return;
        if (moveOwner_ !is null) moveOwner_.abort();
        if (rotateOwner_ !is null) rotateOwner_.abort();
        if (scaleOwner_ !is null) scaleOwner_.abort();
        scrub(); consume();
    }

    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !reset_.valid && (moveOwner_ is null || moveOwner_.payloadEmpty()) &&
            (rotateOwner_ is null || rotateOwner_.payloadEmpty()) &&
            (scaleOwner_ is null || scaleOwner_.payloadEmpty());
    }
    version(unittest) void corruptPreparedForTest(bool post, bool ownerIdentity)
            nothrow @nogc {
        if (post) {
            if (ownerIdentity) ++post_.owner; else ++post_.generation;
        } else {
            if (ownerIdentity) ++pre_.owner; else ++pre_.generation;
        }
    }
    version(unittest) void corruptValidatedForTest(bool post, bool ownerIdentity)
            nothrow @nogc {
        if (post) {
            if (ownerIdentity) ++validatedPost_.owner;
            else ++validatedPost_.generation;
        } else {
            if (ownerIdentity) ++validatedPre_.owner;
            else ++validatedPre_.generation;
        }
    }
private:
    this(XfrmTransformTool target) {
        target_ = target;
        move_ = target.moveBank(); rotate_ = target.rotateBank();
        scale_ = target.scaleBank(); flags_ = target.preparedActivationFlags();
        owner_ = atomicOp!"+="(nextXfrmActivationOwner, 1UL);
    }
    bool shapeValid() nothrow @nogc {
        return target_ !is null && reset_.valid &&
            target_.preparedActivationShape(flags_, move_, rotate_, scale_);
    }
    void scrub() nothrow @nogc { reset_.clear(); placementAcen_ = null; }
    void consume() nothrow @nogc {
        scrub(); preBegun_ = postBegun_ = validated_ = preInstalled_ = false;
        consumed_ = true; target_ = null; move_ = null; rotate_ = null; scale_ = null;
        moveOwner_ = rotateOwner_ = scaleOwner_ = null;
        pre_.owner = pre_.generation = post_.owner = post_.generation = 0;
        validatedPre_.owner = validatedPre_.generation = 0;
        validatedPost_.owner = validatedPost_.generation = 0;
    }
}
