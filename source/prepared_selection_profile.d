module prepared_selection_profile;

import editmode : EditMode;
import mesh : Mesh;
import snapshot : MeshSnapshot;
import tools.common.session_mesh_key : SessionMeshKey;
import tools.alignment.radial_sweep_tool : RadialSweepTool;
public import prepared_selection_profile_image : RadialSweepProfileImage;

/// Closed detached projection of the only selection-profile session currently
/// admitted by P1.0b.5g. The owner retains both target identity and value;
/// callers exchange only the owner reference/context token.
final class PreparedSelectionProfileOwner {
private:
    RadialSweepTool target_;
    RadialSweepProfileImage image_;
    bool begun_, consumed_;
public:
    @disable this();

    static PreparedSelectionProfileOwner radialSweep(RadialSweepTool target,
                                                       ref Mesh source,
                                                       EditMode mode) {
        if (target is null || target.classinfo !is RadialSweepTool.classinfo) return null;
        auto owner = new PreparedSelectionProfileOwner(target);
        owner.image_.mesh = MeshSnapshot.capture(source);
        owner.image_.sessionKey.stamp(source);
        if (mode == EditMode.Polygons) {
            uint[] selected;
            foreach (fi; 0 .. source.faces.length)
                if (source.isFaceSelected(fi)) selected ~= cast(uint)fi;
            if (selected.length == 1) {
                owner.image_.face = selected[0];
                owner.image_.profile = source.faceVertexRing(selected[0]).dup;
                owner.image_.closed = true;
                owner.image_.valid = owner.image_.profile.length >= 3;
            }
        } else if (mode == EditMode.Edges) {
            owner.image_.profile = source.extractSelectedEdgeChain(owner.image_.closed);
            owner.image_.valid = owner.image_.profile.length != 0;
        }
        return owner;
    }

    bool begin() nothrow @nogc {
        if (begun_ || consumed_ || target_ is null || !image_.filled) return false;
        begun_ = true; return true;
    }
    bool validate(RadialSweepTool target) const nothrow @nogc {
        return begun_ && !consumed_ && target_ is target && image_.filled;
    }
    bool validate() const nothrow @nogc {
        return begun_ && !consumed_ && target_ !is null && image_.filled;
    }
    void install() nothrow @nogc {
        if (!validate(target_)) return;
        target_.installPreparedSelectionProfile(image_);
        consumed_ = true; begun_ = false; target_ = null; image_.clear();
    }
    void abort() nothrow @nogc {
        if (consumed_) return;
        consumed_ = true; begun_ = false; target_ = null; image_.clear();
    }
    version(unittest) bool payloadEmpty() const nothrow @nogc {
        return !image_.filled && image_.profile.length == 0;
    }
private:
    this(RadialSweepTool target) { target_ = target; }
}

version(unittest) unittest {
    import mesh : makeCube;
    Mesh source = makeCube();
    source.syncSelection();
    source.selectFace(0);
    EditMode mode = EditMode.Polygons;
    import shader : LitShader;
    auto target = new RadialSweepTool(() => &source, null, &mode, LitShader.init);

    class BehaviorfulDerived : RadialSweepTool {
        bool activated;
        this(Mesh* delegate() src, EditMode* em) { super(src, null, em, LitShader.init); }
        override void activate() { activated = true; }
    }
    auto derived = new BehaviorfulDerived(() => &source, &mode);
    assert(PreparedSelectionProfileOwner.radialSweep(derived, source, mode) is null);
    assert(!derived.activated);
    auto owner = PreparedSelectionProfileOwner.radialSweep(target, source, mode);
    assert(owner.begin() && owner.validate(target));
    auto other = new RadialSweepTool(() => &source, null, &mode, LitShader.init);
    assert(!owner.validate(other));
    source.deselectFace(0);
    owner.install();
    assert(owner.payloadEmpty());
    assert(target.preparedProfileForTest());
    assert(!owner.begin());

    auto aborted = PreparedSelectionProfileOwner.radialSweep(other, source, mode);
    assert(aborted.begin()); aborted.abort();
    assert(aborted.payloadEmpty() && !aborted.begin() && !other.preparedProfileForTest());

    source.selectFace(0);
    auto enlisted = PreparedSelectionProfileOwner.radialSweep(other, source, mode);
    import prepared_record_context : PreparedRecordContext;
    import command_history : CommandHistory;
    import record_observer_hub : RecordObserverHub;
    auto context = new PreparedRecordContext(new CommandHistory(), new RecordObserverHub());
    assert(context.prepareSelectionProfile(enlisted));
    assert(context.markNoHistoryInstall());
    assert(!other.preparedProfileForTest());
    assert(context.validate()); context.install();
    assert(other.preparedProfileForTest());
    assert(context.installTraceForTest() == [9,8]);
    context.install();
    assert(other.preparedProfileForTest());

    foreach (corners; 0 .. 4) {
        Mesh degenerate;
        degenerate.vertices.length = 3;
        uint[] ring;
        foreach (i; 0 .. corners) ring ~= cast(uint)i;
        degenerate.faces ~= ring;
        degenerate.syncSelection(); degenerate.selectFace(0);
        auto degTarget = new RadialSweepTool(() => &degenerate, null, &mode, LitShader.init);
        auto degOwner = PreparedSelectionProfileOwner.radialSweep(degTarget, degenerate, mode);
        assert(degOwner.begin()); degOwner.install();
        assert(degTarget.preparedProfileValidityForTest() == (corners >= 3));
    }
}
