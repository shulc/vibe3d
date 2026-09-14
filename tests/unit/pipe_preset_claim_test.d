// Preset ownership is attached only to the transient stage slots a prepared
// activation writes. These tests pin the claim image, its stale-validation
// witness, and both reset doors independently of the HTTP suite (task 5911).
module tests.unit.pipe_preset_claim_test;

import prepared_pipe_activation : PreparedPipeActivationOwner;
import registry : PreparedPipeAttrs;
import toolpipe.pipeline : Pipeline;
import toolpipe.stage : PresetClaimable;
import math : Pin, Vec3;
import toolpipe.packets : FalloffConfig, FalloffShape, FalloffType;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.stages.constrain : ConstrainStage;
import toolpipe.stages.falloff : FalloffStage;

private struct ClaimRig {
    Pipeline pipeline;
    ActionCenterStage acen;
    AxisStage axis;
    ConstrainStage constrain;
    FalloffStage falloff;

}

private ClaimRig claimRig() {
    ClaimRig rig;
    rig.acen = new ActionCenterStage(null, null);
    rig.axis = new AxisStage();
    rig.constrain = new ConstrainStage();
    rig.falloff = new FalloffStage();
    rig.pipeline.add(rig.acen);
    rig.pipeline.add(rig.axis);
    rig.pipeline.add(rig.constrain);
    rig.pipeline.add(rig.falloff);
    return rig;
}

unittest { // U-a: only written slots are claimed and inherited locks are gone.
    auto rig = claimRig();
    rig.acen.mode = ActionCenterStage.Mode.Local;
    rig.acen.userLocked = true;
    rig.axis.mode = AxisStage.Mode.World;
    rig.axis.userLocked = true;
    rig.falloff.type = FalloffType.Radial;
    rig.falloff.userLocked = true;

    PreparedPipeAttrs attrs = [
        "actionCenter": ["mode": "element"],
        "falloff": ["type": "element"],
    ];
    auto prepared = PreparedPipeActivationOwner.prepare(rig.pipeline, attrs);
    assert(prepared.validate(), "fresh prepared claim image must validate");
    prepared.install();

    assert(rig.acen.mode == ActionCenterStage.Mode.Element &&
           rig.falloff.type == FalloffType.Element,
        "prepared values were not installed");
    assert(rig.acen.presetClaimed() && rig.falloff.presetClaimed() &&
           !rig.axis.presetClaimed(),
        "claimed ids must be exactly actionCenter and falloff");
    assert(!rig.acen.userLocked && !rig.falloff.userLocked,
        "a preset-owned value must not inherit a user lock");
    assert(rig.axis.mode == AxisStage.Mode.World && rig.axis.userLocked,
        "an unwritten user-locked axis must stay untouched");
}

unittest { // U-b: claim state participates in the prepared stale witness.
    {
        auto rig = claimRig();
        auto prepared = PreparedPipeActivationOwner.prepare(
            rig.pipeline, PreparedPipeAttrs.init);
        assert(prepared.validate(), "fresh action-centre image must validate");
        rig.acen.claimForPreset();
        assert(!prepared.validate(),
            "action-centre claim drift between prepare and install must be refused");
    }
    {
        auto rig = claimRig();
        auto prepared = PreparedPipeActivationOwner.prepare(
            rig.pipeline, PreparedPipeAttrs.init);
        assert(prepared.validate(), "fresh axis image must validate");
        rig.axis.claimForPreset();
        assert(!prepared.validate(),
            "axis claim drift between prepare and install must be refused");
    }
    {
        auto rig = claimRig();
        auto prepared = PreparedPipeActivationOwner.prepare(
            rig.pipeline, PreparedPipeAttrs.init);
        assert(prepared.validate(), "fresh falloff image must validate");
        rig.falloff.claimForPreset();
        assert(!prepared.validate(),
            "falloff claim drift between prepare and install must be refused");
    }
}

unittest { // U-d: both resets clear claims; non-claimable stages stay outside.
    auto rig = claimRig();
    rig.acen.claimForPreset();
    rig.axis.claimForPreset();
    rig.falloff.claimForPreset();
    rig.acen.resetTransient();
    rig.axis.resetTransient();
    rig.falloff.resetTransient();
    assert(!rig.acen.presetClaimed() && !rig.axis.presetClaimed() &&
           !rig.falloff.presetClaimed(),
        "transient reset must clear every preset claim");

    rig.acen.claimForPreset();
    rig.axis.claimForPreset();
    rig.falloff.claimForPreset();
    rig.acen.reset();
    rig.axis.reset();
    rig.falloff.reset();
    assert(!rig.acen.presetClaimed() && !rig.axis.presetClaimed() &&
           !rig.falloff.presetClaimed(),
        "full reset must clear every preset claim");

    rig.acen.claimForPreset();
    rig.axis.claimForPreset();
    rig.falloff.claimForPreset();
    PreparedPipeActivationOwner.prepare(
        rig.pipeline, PreparedPipeAttrs.init).install();
    assert(!rig.acen.presetClaimed() && !rig.axis.presetClaimed() &&
           !rig.falloff.presetClaimed(),
        "prepared transient reset must clear every preset claim");
    assert(cast(PresetClaimable)rig.constrain is null,
        "constrain must not join preset-claim ownership");
}

unittest { // U-e: a written locked stage installs from a clean base image.
    auto rig = claimRig();
    rig.acen.mode = ActionCenterStage.Mode.Manual;
    rig.acen.manualCenter = Vec3(7, 8, 9);
    rig.acen.selectSubMode = ActionCenterStage.SelectSubMode.Top;
    rig.acen.restorePinState(Pin(true, Vec3(4, 5, 6)));
    rig.acen.setElementPin(Vec3(1, 2, 3));
    const elementPinBefore = rig.acen.currentElementPin();
    rig.acen.freezeUserPlacedSnapshot();
    rig.acen.userLocked = true;

    rig.falloff.shape = FalloffShape.Smooth;
    rig.falloff.start = Vec3(9, 8, 7);
    rig.falloff.end = Vec3(6, 5, 4);
    rig.falloff.transparent = true;
    rig.falloff.pickedRadius = 0.37f;
    rig.falloff.userLocked = true;

    rig.axis.mode = AxisStage.Mode.Manual;
    rig.axis.manualRight = Vec3(3, 4, 5);
    rig.axis.userLocked = true;

    PreparedPipeAttrs attrs = [
        "actionCenter": ["mode": "element"],
        "falloff": ["type": "radial"],
    ];
    PreparedPipeActivationOwner.prepare(rig.pipeline, attrs).install();

    assert(rig.axis.mode == AxisStage.Mode.Manual &&
           rig.axis.manualRight == Vec3(3, 4, 5) && rig.axis.userLocked &&
           !rig.axis.presetClaimed(),
        "U-e control: unwritten axis must stay locked, unchanged and unclaimed");

    assert(rig.acen.manualCenter == Vec3(0, 0, 0) &&
           rig.acen.selectSubMode == ActionCenterStage.SelectSubMode.Center &&
           rig.acen.currentUserPin() == Pin.init &&
           !rig.acen.projectedEditCloseSnapshotFrozen() &&
           rig.acen.currentElementPin() == elementPinBefore &&
           rig.acen.mode == ActionCenterStage.Mode.Element &&
           rig.acen.presetClaimed() && !rig.acen.userLocked,
        "U-e action-centre preset inherited locked transient fields");

    auto expectedFalloff = FalloffConfig.init;
    expectedFalloff.type = FalloffType.Radial;
    assert(rig.falloff.config == expectedFalloff &&
           rig.falloff.presetClaimed() && !rig.falloff.userLocked,
        "U-e falloff preset inherited the locked falloff image");
}

unittest { // U-e-axis: both axis claim sites are independently observable.
    auto rig = claimRig();
    rig.axis.mode = AxisStage.Mode.Manual;
    rig.axis.manualRight = Vec3(3, 4, 5);
    rig.axis.manualUp = Vec3(6, 7, 8);
    rig.axis.manualFwd = Vec3(9, 10, 11);
    rig.axis.axIndex = 2;
    rig.axis.userLocked = true;

    PreparedPipeActivationOwner.prepare(rig.pipeline,
        ["axis": ["mode": "element"]]).install();

    assert(rig.axis.mode == AxisStage.Mode.Element &&
           rig.axis.manualRight == Vec3(1, 0, 0) &&
           rig.axis.manualUp == Vec3(0, 1, 0) &&
           rig.axis.manualFwd == Vec3(0, 0, 1) && rig.axis.axIndex == -1,
        "U-e-axis preset did not reset the inherited manual frame");
    assert(rig.axis.presetClaimed(),
        "U-e-axis final claim was not installed");
    assert(!rig.axis.userLocked,
        "U-e-axis preset inherited the user lock");
}

unittest { // Empty claimable-stage maps are refused without live mutation.
    auto rig = claimRig();
    rig.acen.mode = ActionCenterStage.Mode.Local;
    rig.acen.userLocked = true;
    rig.axis.mode = AxisStage.Mode.World;
    rig.axis.userLocked = true;
    rig.constrain.enabled = true;
    rig.falloff.type = FalloffType.Linear;
    rig.falloff.userLocked = true;

    bool rejectedAcen;
    PreparedPipeAttrs emptyAcen;
    emptyAcen["actionCenter"] = null;
    try PreparedPipeActivationOwner.prepare(rig.pipeline, emptyAcen);
    catch (Exception) rejectedAcen = true;
    assert(rig.acen.mode == ActionCenterStage.Mode.Local && rig.acen.userLocked &&
           rig.axis.mode == AxisStage.Mode.World && rig.axis.userLocked &&
           rig.constrain.enabled && rig.falloff.type == FalloffType.Linear &&
           rig.falloff.userLocked,
        "empty action-centre preset mutated live stages before refusal");
    assert(rejectedAcen,
        "empty action-centre preset must be refused");

    bool rejectedAxis;
    PreparedPipeAttrs emptyAxis;
    emptyAxis["axis"] = null;
    try PreparedPipeActivationOwner.prepare(rig.pipeline, emptyAxis);
    catch (Exception) rejectedAxis = true;
    assert(rig.acen.mode == ActionCenterStage.Mode.Local && rig.acen.userLocked &&
           rig.axis.mode == AxisStage.Mode.World && rig.axis.userLocked &&
           rig.constrain.enabled && rig.falloff.type == FalloffType.Linear &&
           rig.falloff.userLocked,
        "empty axis preset mutated live stages before refusal");
    assert(rejectedAxis,
        "empty axis preset must be refused");
}
