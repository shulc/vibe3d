module vibe3d.editing.tools.interactive.prepared_radial_sweep_transition;

import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.editing.tools.interactive.prepared_selection_profile : PreparedSelectionProfileOwner;
import vibe3d.editing.tools.interactive.prepared_selection_profile_image : RadialSweepProfileImage;
import vibe3d.editing.tools.interactive.tools.alignment.radial_sweep_tool : RadialSweepTool,
    RadialSweepTransitionImage, PreparedRadialSweepTransitionKind;

/// Exact, owner-held private transition image. No generic pointer/callback is
/// accepted; the context retains this owner and carries only its closed kind.
final class PreparedRadialSweepTransitionOwner {
private:
    RadialSweepTool target_;
    PreparedRadialSweepTransitionKind kind_;
    RadialSweepTransitionImage image_;
    bool begun_, consumed_;
public:
    @disable this();

    static PreparedRadialSweepTransitionOwner activation(
            RadialSweepTool target, PreparedSelectionProfileOwner profile) {
        if (!admit(target) || profile is null) return null;
        RadialSweepProfileImage profileImage;
        if (!profile.takeUnbegun(target, profileImage)) return null;
        auto owner = new PreparedRadialSweepTransitionOwner(target,
            PreparedRadialSweepTransitionKind.Activate);
        owner.image_ = target.buildPreparedActivationImage(profileImage);
        return owner;
    }
    static PreparedRadialSweepTransitionOwner param(RadialSweepTool target,
                                                     string name) {
        if (!admit(target)) return null;
        auto owner = new PreparedRadialSweepTransitionOwner(target,
            PreparedRadialSweepTransitionKind.Param);
        owner.image_ = target.buildPreparedParamImage(name);
        return owner;
    }
    static PreparedRadialSweepTransitionOwner deactivate(RadialSweepTool target) {
        if (!admit(target)) return null;
        auto owner = new PreparedRadialSweepTransitionOwner(target,
            PreparedRadialSweepTransitionKind.Deactivate);
        owner.image_ = target.buildPreparedDeactivateImage();
        return owner;
    }
    @property PreparedRadialSweepTransitionKind kind() const nothrow @nogc {
        return kind_;
    }
    bool owns(RadialSweepTool target) const nothrow @nogc {
        return target_ is target;
    }
    ref const(Mesh) previewForGpuUpload() const return nothrow @nogc {
        return image_.previewMesh;
    }
    bool begin() nothrow @nogc {
        if (begun_ || consumed_ || target_ is null || !image_.valid) return false;
        begun_ = true; return true;
    }
    bool validate() const nothrow @nogc {
        return begun_ && !consumed_ && target_ !is null && image_.valid;
    }
    void install() nothrow @nogc {
        if (!validate()) return;
        target_.installPreparedTransition(image_);
        consumed_ = true; begun_ = false; target_ = null; image_.clear();
    }
    void abort() nothrow @nogc {
        if (consumed_) return;
        consumed_ = true; begun_ = false; target_ = null; image_.clear();
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.valid && image_.previewMesh.vertices.length == 0;
    }
private:
    static bool admit(RadialSweepTool target) nothrow @nogc {
        return target !is null && target.classinfo is RadialSweepTool.classinfo;
    }
    this(RadialSweepTool target, PreparedRadialSweepTransitionKind kind) {
        target_ = target; kind_ = kind;
    }
}
