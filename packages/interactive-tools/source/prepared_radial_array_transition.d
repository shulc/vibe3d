module prepared_radial_array_transition;

import vibe3d.mesh.core.mesh : Mesh;
import tools.alignment.radial_array_tool : RadialArrayTool,
    RadialArrayTransitionImage, PreparedRadialArrayTransitionKind;
import core.atomic : atomicOp;
import vibe3d.documents.model.document : Layer;
import vibe3d.editing.contracts.prepared_tool_effect : PreparedRadialArrayKind;

struct PreparedRadialArrayTransitionToken {
    @disable this(this);
private: ulong owner, generation;
}
struct ValidatedRadialArrayTransitionToken {
    @disable this(this);
private: ulong owner, generation;
}

private shared ulong nextRadialArrayTransitionOwner;

/// Closed owner for RadialArray's shared activation/deactivation session
/// projection. No mesh candidate, GPU payload, callback or open virtual
/// behavior crosses this boundary.
final class PreparedRadialArrayTransitionOwner {
private:
    RadialArrayTool target_;
    RadialArrayTransitionImage image_;
    Layer layer_;
    Mesh* source_;
    immutable ulong owner_;
    ulong generation_;
    bool pending_, validated_, consumed_;
    PreparedRadialArrayTransitionToken prepared_;
    ValidatedRadialArrayTransitionToken validatedToken_;
public:
    @disable this();
    static PreparedRadialArrayTransitionOwner activation(RadialArrayTool target,
                                                          ref Mesh source) {
        if (!admit(target) || !target.ownsPreparedMesh(&source)) return null;
        auto result = new PreparedRadialArrayTransitionOwner(target);
        result.image_ = target.buildPreparedActivationImage(source); return result;
    }
    static PreparedRadialArrayTransitionOwner deactivation(RadialArrayTool target) {
        if (!admit(target)) return null;
        auto result = new PreparedRadialArrayTransitionOwner(target);
        result.image_ = target.buildPreparedDeactivateImage(); return result;
    }
    static PreparedRadialArrayTransitionOwner param(RadialArrayTool target,
                                                     Layer layer) {
        if (!admit(target) || layer is null ||
            !target.ownsPreparedMesh(&layer.meshRef())) return null;
        auto result = new PreparedRadialArrayTransitionOwner(target);
        result.layer_ = layer; result.source_ = &layer.meshRef();
        result.image_ = target.buildPreparedParamImage(layer.meshRef());
        return result.image_.valid ? result : null;
    }
    @property PreparedRadialArrayTransitionKind kind() const nothrow @nogc {
        return image_.kind;
    }
    bool owns(RadialArrayTool target) const nothrow @nogc { return target_ is target; }
    bool begin() nothrow @nogc {
        if (pending_ || consumed_ || target_ is null || !image_.valid) return false;
        ++generation_; pending_ = true; prepared_.owner = owner_;
        prepared_.generation = generation_; return true;
    }
    bool validate() nothrow @nogc {
        if (!pending_ || validated_ || consumed_ || target_ is null ||
            prepared_.owner != owner_ || prepared_.generation != generation_ ||
            (image_.kind == PreparedRadialArrayTransitionKind.Param &&
             (layer_ is null || source_ is null || &layer_.meshRef() !is source_ ||
              !target_.preparedParamMatches(image_, *source_)))) return false;
        validated_ = true; validatedToken_.owner = owner_;
        validatedToken_.generation = generation_;
        prepared_.owner = prepared_.generation = 0; return true;
    }
    void install() nothrow @nogc {
        if (!pending_ || !validated_ || consumed_ || target_ is null ||
            validatedToken_.owner != owner_ ||
            validatedToken_.generation != generation_) return;
        target_.installPreparedTransition(image_);
        consume();
    }
    void abort() nothrow @nogc { if (!consumed_) { image_.clear(); consume(); } }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && !image_.before.filled &&
            image_.before.vertices.length == 0 && image_.before.edges.length == 0 &&
            image_.before.faces.length == 0 && image_.before.meshMaps.length == 0;
    }
private:
    static bool admit(RadialArrayTool target) nothrow @nogc {
        return target !is null && target.classinfo is RadialArrayTool.classinfo;
    }
    this(RadialArrayTool target) {
        target_ = target;
        owner_ = atomicOp!"+="(nextRadialArrayTransitionOwner, 1UL);
    }
    void consume() nothrow @nogc {
        pending_ = validated_ = false; consumed_ = true; target_ = null;
        layer_ = null; source_ = null;
        prepared_.owner = prepared_.generation = 0;
        validatedToken_.owner = validatedToken_.generation = 0;
    }
}
