module prepared_selection_profile_source_cells;

import prepared_selection_profile;
import vibe3d.editing.contracts.editmode : EditMode;
import mesh : Mesh;
import snapshot : MeshSnapshot;
import tools.common.session_mesh_key : SessionMeshKey;
import tools.alignment.radial_sweep_tool : RadialSweepTool;
public import prepared_selection_profile_image : RadialSweepProfileImage;

unittest {
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
