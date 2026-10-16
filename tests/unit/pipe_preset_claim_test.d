// Preset ownership is attached only to the transient stage slots a prepared
// activation writes. These tests pin the claim image, its stale-validation
// witness, and both reset doors independently of the HTTP suite (task 5911).
module tests.unit.pipe_preset_claim_test;


import tests.unit.census_symbols : exists = wave15Exists;

import prepared_pipe_activation : PreparedPipeActivationOwner;
import pipe_gizmo_host : PipeGizmoHost;
import registry : PreparedPipeAttrs;
import tool_activation_ownership : PipeArmScope;
import toolpipe.pipeline : Pipeline, noteUserStageChoice;
import toolpipe.stage : PresetClaimable;
import math : Vec3;
import vibe3d.util.spatial.spatial : Pin;
import toolpipe.packets : FalloffConfig, FalloffShape, FalloffType;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.stages.constrain : ConstrainStage;
import toolpipe.stages.falloff : FalloffStage;

import tests.unit.census_symbols : wave15InputStart, wave15InputsIntact;

import std.algorithm : sort;
import std.array : appender, array;
import std.exception : enforce;
import std.file : SpanMode;
import tests.unit.census_symbols : dirEntries = wave15DirEntries, readText = wave15ReadText;
import std.format : format;
import std.path : buildPath, dirName;
import std.regex : matchAll, regex;
import std.string : endsWith, indexOf;
import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

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

private string commentsBlanked(string source) {
    const code = blankNonCode(source);
    const withComments = blankNonCode(source, true);
    enforce(code.length == source.length && withComments.length == source.length,
        "comment projections changed source length");
    auto result = source.dup;
    foreach (i; 0 .. result.length)
        if (code[i] != withComments[i] && result[i] != '\n') result[i] = ' ';
    return cast(string)result;
}

private string bodyAt(string source, string marker) {
    const code = blankNonCode(source);
    const at = code.indexOf(marker);
    enforce(at >= 0, "missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    enforce(i < code.length, "no body after source marker `" ~ marker ~ "`");
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return source[begin .. i + 1];
    }
    enforce(false, "unterminated body after source marker `" ~ marker ~ "`");
    return null;
}

private size_t[] occurrences(string source, string needle) {
    size_t[] result;
    size_t start;
    while (start <= source.length) {
        const relative = source[start .. $].indexOf(needle);
        if (relative < 0) break;
        const found = start + cast(size_t)relative;
        result ~= found;
        start = found + needle.length;
    }
    return result;
}

private string writerLedger(string pattern) {
    const sourceRoot = buildPath(repoRoot, "source");
    size_t[string] hits;
    auto compiled = regex(pattern);
    foreach (scanSourceRoot; [sourceRoot, buildPath(repoRoot, "packages/command-runtime/source"), buildPath(repoRoot, "packages/application-core/source"), buildPath(repoRoot, "packages/camera-model/source"), buildPath(repoRoot, "packages/document-channels/source"), buildPath(repoRoot, "packages/image-codec/source"), buildPath(repoRoot, "packages/document-io/source"), buildPath(repoRoot, "packages/document-model/source"), buildPath(repoRoot, "packages/param-schema/source"), buildPath(repoRoot, "packages/pipe-runtime/source"), buildPath(repoRoot, "packages/mesh-ops/source"), buildPath(repoRoot, "packages/interchange/source"), buildPath(repoRoot, "packages/interaction-query/source"), buildPath(repoRoot, "packages/pipe-evaluation/source"), buildPath(repoRoot, "packages/tool-state/source"), buildPath(repoRoot, "packages/transform-ops/source"), buildPath(repoRoot, "packages/creation-ops/source"), buildPath(repoRoot, "packages/alignment-ops/source"), buildPath(repoRoot, "packages/input-events/source"), buildPath(repoRoot, "packages/display-policy/source"), buildPath(repoRoot, "packages/viewport-gpu/source"), buildPath(repoRoot, "packages/subpatch-preview/source"), buildPath(repoRoot, "packages/edit-contracts/source"), buildPath(repoRoot, "packages/mesh-change/source"), buildPath(repoRoot, "packages/mesh-contracts/source"), buildPath(repoRoot, "packages/mesh-edit-log/source"), buildPath(repoRoot, "packages/mesh-edit-replay/source"), buildPath(repoRoot, "packages/mesh-snapshot/source"), buildPath(repoRoot, "packages/mesh-topology/source"), buildPath(repoRoot, "packages/mesh/source"), buildPath(repoRoot, "packages/profiling/source"), buildPath(repoRoot, "packages/spatial/source"), buildPath(repoRoot, "util/log/source"), buildPath(repoRoot, "util/math/source"), buildPath(repoRoot, "util/parallel/source"), buildPath(repoRoot, "util/plane-bytes/source"), buildPath(repoRoot, "util/screen-buckets/source"), buildPath(repoRoot, "packages/pipe-contracts/source"), buildPath(repoRoot, "packages/mesh-preview/source"), buildPath(repoRoot, "util/json-number/source"), buildPath(repoRoot, "packages/selection-model/source"), buildPath(repoRoot, "packages/scene-query/source"), buildPath(repoRoot, "packages/editor-commands/source")])

    foreach (entry; dirEntries(scanSourceRoot, SpanMode.depth)) {
        if (!entry.isFile || !entry.name.endsWith(".d")) continue;
        const source = commentsBlanked(readText(entry.name));
        size_t count;
        foreach (_; source.matchAll(compiled)) ++count;
        if (count)
            hits[entry.name[scanSourceRoot.length + 1 .. $]] = count;
    }
    const string[] sourceCarriersWave14_1 = [
        "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d",
        "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d",
        "packages/document-io/tests/source/tests/unit/io/native_source_cells_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d",
        "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
];

import tests.unit.census_symbols : exists = wave15Exists;
    import std.path : buildPath;
    foreach (relative; [
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d",
        "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d",
        "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d",
    ]) {
        size_t occurrences;
        foreach (candidate; sourceCarriersWave14_1) if (candidate == relative) ++occurrences;
        assert(occurrences == 1, "Wave14 logical source input missing/duplicate: " ~ relative);

    }
    foreach (sourceCarrier; sourceCarriersWave14_1) {
        const sourceCarrierPath = buildPath(repoRoot, sourceCarrier);
        const sourceRelative = sourceCarrier ==
            "packages/camera-model/tests/source/tests/unit/view_source_cells_test.d"
                ? "view.d"
                : sourceCarrier ==
                    "packages/image-codec/tests/source/tests/unit/io/image_decode_source_cells_test.d"
                        ? "io/image_decode.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/command_history_source_public_test.d" ? "command_history.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/command_source_public_test.d" ? "command.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/commands/mesh/session_edit_source_public_test.d" ? "commands/mesh/session_edit.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/commands/select/element_source_public_test.d" ? "commands/select/element.d"
                        : sourceCarrier == "packages/command-runtime/tests/source/tests/unit/record_observer_hub_source_public_test.d" ? "record_observer_hub.d"
                        : sourceCarrier == "packages/editor-commands/tests/source/tests/unit/commands/mesh/edge_crease_source_public_test.d" ? "commands/mesh/edge_crease.d"
                        : sourceCarrier == "packages/editor-commands/tests/source/tests/unit/commands/mesh/remove_source_public_test.d" ? "commands/mesh/remove.d"
                        : sourceCarrier == "packages/editor-commands/tests/source/tests/unit/commands/mesh/symmetrize_source_public_test.d" ? "commands/mesh/symmetrize.d"
                        : sourceCarrier == "packages/editor-commands/tests/source/tests/unit/commands/mesh/vertex_set_source_public_test.d" ? "commands/mesh/vertex_set.d"
                        : sourceCarrier == "packages/editor-commands/tests/source/tests/unit/commands/select/boundary_source_public_test.d" ? "commands/select/boundary.d"
                        : sourceCarrier == "packages/editor-commands/tests/source/tests/unit/commands/select/by_stat_source_public_test.d" ? "commands/select/by_stat.d"
                        : sourceCarrier == "packages/editor-commands/tests/source/tests/unit/commands/select/by_tag_source_public_test.d" ? "commands/select/by_tag.d"
                        : sourceCarrier == "packages/editor-commands/tests/source/tests/unit/commands/select/type_from_source_public_test.d" ? "commands/select/type_from.d"
                        : sourceCarrier == "packages/selection-model/tests/source/tests/unit/selection_product_source_public_test.d" ? "selection_product.d"
                        : "io/native.d";

        const source = commentsBlanked(readText(sourceCarrierPath));
        size_t count;
        foreach (_; source.matchAll(compiled)) ++count;
        if (count)
            hits[sourceRelative] = count;

    }

    auto paths = hits.keys.array;
    paths.sort;
    auto result = appender!string;
    foreach (path; paths)
        result.put(format("%s %s\n", path, hits[path]));
    return result.data;
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

unittest { // U-c: only a claimed locking target promotes sibling claims.
    {
        auto rig = claimRig();
        rig.acen.claimForPreset();
        rig.falloff.claimForPreset();

        noteUserStageChoice(rig.pipeline, rig.falloff, true);
        assert(rig.acen.userLocked && !rig.acen.presetClaimed() &&
               !rig.falloff.presetClaimed(),
            "U-c locking displacement did not preserve the sibling claim as a user choice");
    }
    {
        auto rig = claimRig();
        rig.acen.claimForPreset();

        noteUserStageChoice(rig.pipeline, rig.falloff, true);
        assert(rig.acen.presetClaimed() && !rig.acen.userLocked &&
               !rig.falloff.presetClaimed(),
            "U-c an unclaimed locking target promoted a sibling claim");
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

unittest { // U-f: a loose write releases only its target claim.
    auto rig = claimRig();
    rig.acen.claimForPreset();
    rig.falloff.claimForPreset();

    noteUserStageChoice(rig.pipeline, rig.acen, false);
    assert(!rig.acen.presetClaimed() && !rig.acen.userLocked &&
           rig.falloff.presetClaimed() && !rig.falloff.userLocked,
        "U-f loose choice promoted a sibling or retained its own claim");
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

unittest { // U-g: replay yields each written user-locked stage independently.
    auto rig = claimRig();
    rig.acen.setUserMode("local");
    PreparedPipeActivationOwner.prepare(rig.pipeline,
        ["falloff": ["type": "linear"]], null,
        PipeArmScope.presetArm).install();
    rig.falloff.start = Vec3(9, 8, 7);
    rig.axis.mode = AxisStage.Mode.World;

    PreparedPipeAttrs attrs = [
        "actionCenter": ["mode": "element"],
        "falloff": ["type": "radial"],
    ];
    PreparedPipeActivationOwner.prepare(rig.pipeline, attrs, null,
        PipeArmScope.replayRestore).install();

    assert(rig.acen.mode == ActionCenterStage.Mode.Local &&
           rig.acen.userLocked && !rig.acen.presetClaimed(),
        "U-g step 1: replay overwrote or claimed the locked action centre");
    assert(rig.falloff.type == FalloffType.Radial &&
           rig.falloff.presetClaimed() && !rig.falloff.userLocked &&
           rig.falloff.start == FalloffConfig.init.start,
        "U-g step 2: replay failed to install the unlocked falloff from a clean image");
    assert(rig.axis.mode == AxisStage.Mode.None,
        "U-g step 3: replay failed to reset the unwritten loose axis");
}

unittest { // U-h: same-id reset keeps every pipe stage but cancels its gizmo.
    auto rig = claimRig();
    PreparedPipeAttrs attrs = [
        "actionCenter": ["mode": "element"],
        "falloff": ["type": "element"],
    ];
    PreparedPipeActivationOwner.prepare(rig.pipeline, attrs, null,
        PipeArmScope.presetArm).install();
    rig.falloff.pickedRadius = 0.5f;
    rig.axis.mode = AxisStage.Mode.World;
    rig.constrain.enabled = true;

    const acenMode = rig.acen.mode;
    const acenLocked = rig.acen.userLocked;
    const acenClaimed = rig.acen.presetClaimed();
    const acenEpoch = rig.acen.slotEpoch;
    const axisMode = rig.axis.mode;
    const axisLocked = rig.axis.userLocked;
    const axisClaimed = rig.axis.presetClaimed();
    const axisEpoch = rig.axis.slotEpoch;
    const constrainImage = rig.constrain.capturePreparedCompositionProjection();
    const constrainEpoch = rig.constrain.slotEpoch;
    const falloffImage = rig.falloff.config;
    const falloffLocked = rig.falloff.userLocked;
    const falloffClaimed = rig.falloff.presetClaimed();
    const falloffEpoch = rig.falloff.slotEpoch;

    auto gizmoHost = new PipeGizmoHost();
    PreparedPipeActivationOwner.prepare(rig.pipeline, attrs, gizmoHost,
        PipeArmScope.keepPipe).install();

    assert(rig.acen.mode == acenMode && rig.acen.userLocked == acenLocked &&
           rig.acen.presetClaimed() == acenClaimed &&
           rig.acen.slotEpoch == acenEpoch &&
           rig.axis.mode == axisMode && rig.axis.userLocked == axisLocked &&
           rig.axis.presetClaimed() == axisClaimed &&
           rig.axis.slotEpoch == axisEpoch &&
           rig.constrain.matchesPreparedCompositionProjection(constrainImage) &&
           rig.constrain.slotEpoch == constrainEpoch &&
           rig.falloff.config == falloffImage &&
           rig.falloff.userLocked == falloffLocked &&
           rig.falloff.presetClaimed() == falloffClaimed &&
           rig.falloff.slotEpoch == falloffEpoch &&
           rig.falloff.pickedRadius == 0.5f &&
           rig.axis.mode == AxisStage.Mode.World && rig.constrain.enabled,
        "U-h step 1: keepPipe changed a transient pipe field");
    assert(gizmoHost.preparedCancelCountForTest == 1,
        "U-h step 2: keepPipe did not perform exactly one gizmo cancel");
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

unittest { // W-1: user-choice bookkeeping is ordered around each writer.
    auto wave15Inputs = wave15InputStart();
    const actrSource = commentsBlanked(readText(
        buildPath(repoRoot, "source", "commands", "actr.d")));
    const actr = bodyAt(bodyAt(actrSource, "class ActrPresetCommand"),
        "protected override bool applyImpl()");
    const actrNotes = occurrences(actr, "noteUserStageChoice(");
    const actrWrites = occurrences(actr, ".setUserMode(");
    assert(actrNotes.length == 2 && actrWrites.length == 2 &&
           actrNotes[0] < actrWrites[0] && actrNotes[1] < actrWrites[1],
        "W-1 ActrPresetCommand must account for both stage choices before their lock writes");

    const falloffSource = commentsBlanked(readText(
        buildPath(repoRoot, "source", "commands", "falloff.d")));
    const falloff = bodyAt(bodyAt(falloffSource, "class FalloffPresetCommand"),
        "protected override bool applyImpl()");
    const falloffWrite = occurrences(falloff, `fo.setAttr("type"`);
    const falloffNotes = occurrences(falloff, "noteUserStageChoice(");
    const falloffLocks = occurrences(falloff, "fo.userLocked =");
    assert((falloffWrite.length == 1 && falloffNotes.length == 1 &&
           falloffLocks.length == 1 && falloffWrite[0] < falloffNotes[0] &&
           falloffNotes[0] < falloffLocks[0]) && wave15InputsIntact(wave15Inputs),
        "W-1 FalloffPresetCommand choice bookkeeping moved outside the successful write/lock interval");

    const pipeSource = commentsBlanked(readText(
        buildPath(repoRoot, "source", "commands", "tool", "pipe.d")));
    const pipe = bodyAt(bodyAt(pipeSource, "class ToolPipeAttrCommand"),
        "protected override bool applyImpl()");
    const pipeWrite = occurrences(pipe,
        "matched.setAttr(attrName_, attrValue_)");
    const pipeNotes = occurrences(pipe, "noteUserStageChoice(");
    const pipeLocks = occurrences(pipe, "userLocked =");
    assert((pipeWrite.length == 1 && pipeNotes.length == 2 &&
           pipeLocks.length >= 1 && pipeWrite[0] < pipeNotes[0] &&
           pipeNotes[$ - 1] < pipeLocks[0]) && wave15InputsIntact(wave15Inputs),
        "W-1 ToolPipeAttrCommand choice bookkeeping moved outside the successful write/lock interval");
}

unittest { // W-2a/W-2b: the mutable writer surface is an exact ledger.
    auto wave15Inputs = wave15InputStart();
    const lockAndLiteralWriters = writerLedger(
        `userLocked\s*=(?!=)|\.setUserMode\(|setAttr\("(type|mode)"`);
    const expectedLockAndLiteralWriters =
        "commands/actr.d 2\n" ~
        "commands/constrain/toggle.d 1\n" ~
        "commands/falloff.d 4\n" ~
        // pipe.d 3: slice M7 adds the no-tool centre `none` unlock (gap 384),
        // after its noteUserStageChoice (W-1 order above).
        "commands/tool/pipe.d 3\n" ~
        "prepared_pipe_activation.d 1\n" ~
        "prepared_topology_pen_activation.d 1\n" ~
        "toolpipe/stages/actcenter.d 13\n" ~
        "toolpipe/stages/axis.d 7\n" ~
        "toolpipe/stages/constrain.d 3\n" ~
        "toolpipe/stages/falloff.d 5\n";
    assert((lockAndLiteralWriters == expectedLockAndLiteralWriters) && wave15InputsIntact(wave15Inputs),
        "W-2a a lock/mode/literal attribute writer changed; route a claimable "
        ~ "writer through noteUserStageChoice or record its disposition:\n"
        ~ lockAndLiteralWriters);

    // Task 20262020: original axis2/constrain1/falloff2 fixture writes
    // moved verbatim; retain their exact accounting outside production.
    const fixture = commentsBlanked(readText(buildPath(repoRoot,
        "packages/pipe-evaluation/tests/source/tests/unit/toolpipe/prepared_stage_regression_test.d")));
    size_t fixtureWrites;
    foreach (_; fixture.matchAll(regex(`userLocked\s*=(?!=)|\.setUserMode\(|setAttr\("(type|mode)"`)))
        ++fixtureWrites;
    assert(fixtureWrites == 5, "W-2a transferred preset fixture writer population");

    const variableAttributeWriters = writerLedger(`\.setAttr\((?!")`);
    const expectedVariableAttributeWriters =
        // GC.setAttr in the child-first finalization fixture is not a stage choice.
        "bvh_pick.d 1\n" ~
        "commands/tool/pipe.d 1\n" ~
        "falloff_handles.d 1\n" ~
        "tool_presets.d 1\n" ~
        "toolpipe/stage.d 1\n" ~
        "toolpipe/stages/snap.d 3\n";
    assert((variableAttributeWriters == expectedVariableAttributeWriters) && wave15InputsIntact(wave15Inputs),
        "W-2b a variable-key attribute writer changed; route a claimable "
        ~ "writer through noteUserStageChoice or record its disposition:\n"
        ~ variableAttributeWriters);
}
