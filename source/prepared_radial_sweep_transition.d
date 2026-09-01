module prepared_radial_sweep_transition;

import mesh : Mesh;
import prepared_selection_profile : PreparedSelectionProfileOwner;
import prepared_selection_profile_image : RadialSweepProfileImage;
import tools.alignment.radial_sweep_tool : RadialSweepTool,
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
        if (!profile.takeUnbegun(profileImage)) return null;
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

version(unittest) unittest {
    import math : Vec3;
    import mesh : makeCube;
    import editmode : EditMode;
    import shader : LitShader;
    import prepared_record_context : PreparedRecordContext;
    import command_history : CommandHistory;
    import record_observer_hub : RecordObserverHub;

    Mesh source = makeCube(); source.syncSelection(); source.selectFace(0);
    EditMode mode = EditMode.Polygons;
    auto tool = new RadialSweepTool(() => &source, null, &mode, LitShader.init);
    auto profile = PreparedSelectionProfileOwner.radialSweep(tool, source, mode);
    auto activation = PreparedRadialSweepTransitionOwner.activation(tool, profile);
    assert(activation !is null && activation.kind == PreparedRadialSweepTransitionKind.Activate);
    auto previewCount = activation.previewForGpuUpload.vertices.length;
    assert(previewCount > 0 && activation.begin() && activation.validate());
    source.vertices[0].x += 1000; // detached source cannot alter retained preview
    activation.install();
    assert(tool.preparedTransitionForTest(false) && activation.payloadEmpty());
    assert(!activation.begin()); activation.install();
    assert(tool.preparedTransitionForTest(false));

    tool.seedPreparedHaulForTest(4);
    auto param = PreparedRadialSweepTransitionOwner.param(tool, "axis");
    assert(param !is null && param.kind == PreparedRadialSweepTransitionKind.Param);
    auto context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(context.prepareRadialSweepTransition(param));
    assert(context.markNoHistoryInstall() && context.validate()); context.install();
    assert(tool.preparedTransitionForTest(true));
    assert(tool.preparedHaulForTest() == 4);
    assert(context.installTraceForTest() == [10,8]);

    foreach (preset, expected; [Vec3(2,0,0), Vec3(0,2,0), Vec3(0,0,2), Vec3(0,2,0)]) {
        tool.seedPreparedAxisForTest(cast(int)preset, Vec3(0,2,0));
        auto image = tool.buildPreparedParamImage("axisPreset");
        assert(image.params.axis == expected && image.params.axis.length == 2 &&
               image.engaged && image.hasPreview &&
               image.kind == PreparedRadialSweepTransitionKind.Param);
    }
    foreach (axisValue, expected; [
            Vec3(0,0,0): Vec3(1,0,0),
            Vec3(0.5e-6f,0,0): Vec3(1,0,0),
            Vec3(1e-6f,0,0): Vec3(1e-6f,0,0)]) {
        tool.seedPreparedAxisForTest(0, axisValue);
        auto boundary = tool.buildPreparedParamImage("axisPreset");
        assert(boundary.params.axis == expected);
    }
    tool.seedPreparedAxisForTest(1, Vec3(4,0,0));
    auto manualAxis = tool.buildPreparedParamImage("axis");
    assert(manualAxis.params.axisPreset == 3 && manualAxis.params.axis == Vec3(4,0,0) &&
           manualAxis.engaged && manualAxis.hasPreview);

    auto previewVerts = tool.buildPreparedParamImage("unchanged").previewMesh.vertices.length;
    auto profileCount = manualAxis.profile.profile.length;
    tool.seedPreparedDeactivateParityForTest();
    auto reset = PreparedRadialSweepTransitionOwner.deactivate(tool);
    assert(reset.previewForGpuUpload.vertices.length == 0 && reset.begin()); reset.install();
    assert(reset.payloadEmpty() && !reset.begin());
    assert(tool.preparedDeactivateParityForTest(previewVerts, profileCount));
}
