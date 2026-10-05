module prepared_param_update;

import core.atomic : atomicOp;
import document : Layer;
import mesh : Mesh;

struct PreparedParamToken { @disable this(this); private: ulong owner, generation; }
struct ValidatedParamToken { @disable this(this); private: ulong owner, generation; }
private shared ulong nextParamOwner;

/// One closed owner for a tool's interactive parameter-preview transition.
/// The tool is data: `ownsPreparedLayer`, `buildPreparedParamUpdate`,
/// `preparedParamUpdateMatches`, `installPreparedParamUpdate` and an image with
/// `valid` / `applies` / `candidate` / `deliveryFlags` / `deliveryDomains` / `clear`.
final class PreparedParamUpdateOwner(ToolT, ImageT, KindT) {
    alias Kind = KindT;
private:
    ToolT target_; Layer layer_; Mesh* source_;
    ImageT image_;
    immutable ulong owner_; ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedParamToken prepared_;
    ValidatedParamToken validatedToken_;
public:
    @disable this();
    static PreparedParamUpdateOwner prepare(ToolT target, Layer layer) {
        if (target is null || target.classinfo !is ToolT.classinfo ||
            layer is null || !target.ownsPreparedLayer(layer)) return null;
        auto owner = new PreparedParamUpdateOwner(target, layer);
        owner.image_ = target.buildPreparedParamUpdate(layer.meshRef());
        return owner.image_.valid ? owner : null;
    }
    @property bool applies() const nothrow @nogc { return image_.applies; }
    @property KindT effectKind() const nothrow @nogc {
        return !image_.valid ? KindT.None : image_.applies ? KindT.Preview : KindT.Noop;
    }
    ref const(Mesh) candidate() const return scope nothrow @nogc { return image_.candidate; }
    @property uint deliveryFlags() const nothrow @nogc { return image_.deliveryFlags; }
    @property uint deliveryDomains() const nothrow @nogc { return image_.deliveryDomains; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || source_ is null || !image_.valid)
            return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null || layer_ is null ||
            source_ is null || &layer_.meshRef() !is source_ ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            !target_.preparedParamUpdateMatches(image_, *source_)) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedParamUpdate(image_); consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
private:
    this(ToolT target, Layer layer) {
        target_ = target; layer_ = layer; source_ = &layer.meshRef();
        owner_ = atomicOp!"+="(nextParamOwner, 1UL);
    }
    void consume() nothrow @nogc {
        image_.clear(); pending_ = validated_ = false; consumed_ = true;
        target_ = null; layer_ = null; source_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}

/// The tool's `prepareParamChanged`: stamped layer image, the owner's slot,
/// GPU upload, then NoHistory, in that order; any refusal discards the whole
/// transaction. Expanded in the tool's scope (it reads `gpu` and
/// `preparedToolStateOwner` there).
mixin template PreparedParamUpdateProducer(OwnerT, EffectT) {
    final EffectT prepareParamChanged(PreparedRecordContext context, Layer layer,
            GpuUploadOwner uploadOwner) {
        alias KindT = OwnerT.Kind;
        if (context is null) return EffectT(preparedToolStateOwner, KindT.None, false);
        scope(failure) context.discard();
        auto owner = OwnerT.prepare(this, layer);
        auto kind = owner is null ? KindT.None : owner.effectKind;
        bool ok = owner !is null;
        if (ok && owner.applies)
            ok = uploadOwner !is null && uploadOwner.owns(gpu) &&
                context.prepareStampedMeshImage(layer, owner.candidate,
                    owner.deliveryFlags, owner.deliveryDomains);
        if (ok) ok = context.prepareParamUpdate(owner);
        if (ok && owner.applies)
            ok = context.prepareUpload(uploadOwner, owner.candidate);
        if (ok) ok = context.markNoHistoryInstall();
        if (!ok) context.discard();
        return EffectT(preparedToolStateOwner, kind, ok);
    }
}
