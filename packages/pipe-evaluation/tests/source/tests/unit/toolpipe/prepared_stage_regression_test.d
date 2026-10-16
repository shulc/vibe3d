module tests.unit.toolpipe.prepared_stage_regression_test;

import math : Vec3;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.stages.constrain : ConstrainStage, Remembered;
import toolpipe.stages.falloff : FalloffStage;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : ConstrainGeom, FalloffType, FalloffShape, ElementMode;
import toolpipe.stage : Stage;

version (unittest) {
    /// Attr names drawn from every shipping pipe stage (snap / falloff /
    /// action-centre / workplane / symmetry / axis) plus generic knob names.
    /// Used as the "must be rejected unless declared" probe set — see
    /// `assertRejectsUndeclaredAttrs`.
    immutable string[] stageAttrProbeCorpus = [
        // snap
        "enabled", "types", "snapMode", "innerRange", "outerRange",
        "fixedGrid", "fixedGridSize", "fixedGridToggle", "typeToggle",
        "typeVertex", "typeEdge", "typePolygon", "typeWorkplane",
        // falloff
        "type", "shape", "start", "end", "center", "size", "axis", "dist",
        "steps", "anchorRing", "connect", "screenCx", "screenCy",
        "screenSize", "transparent", "lassoStyle", "lassoPoly", "lassoClear",
        "softBorder", "in", "out", "mix", "map", "autosize", "reverse",
        // action centre
        "cenX", "cenY", "cenZ", "userPlacedCenter", "userPlacedX",
        "userPlacedY", "userPlacedZ", "selectSubMode",
        // workplane
        "auto", "rotX", "rotY", "rotZ", "mode",
        // symmetry
        "offset", "useWorkplane", "topology", "epsilon",
        // generic knobs a stage might plausibly grow
        "snapping", "symmetry", "workplane", "falloff", "constrain",
        "visible", "active", "locked", "strength", "weight", "value",
        "state", "reset", "scope", "target", "count",
    ];

    /// Values fed to each probe name. A stage that grew an undeclared `case`
    /// may only accept SOME shapes of value, so probe several — and a value
    /// that makes the arm THROW while parsing counts as accepted too (reaching
    /// a parse at all proves the arm exists).
    immutable string[] stageAttrProbeValues = [
        "true", "false", "0", "1", "1.5", "auto", "x", "",
    ];

    /// Assert `st` rejects every probe name it does not declare in
    /// `knownAttrs()`. `who` labels the failure (defaults to `st.id()`).
    void assertRejectsUndeclaredAttrs(Stage st, string who = null) {
        import std.algorithm : canFind;
        const label    = who.length ? who : st.id();
        const declared = st.knownAttrs();
        foreach (probe; stageAttrProbeCorpus) {
            if (declared.canFind(probe)) continue;   // legitimately declared
            foreach (v; stageAttrProbeValues) {
                bool accepted;
                try
                    accepted = st.setAttr(probe, v);
                catch (Exception)
                    accepted = true;   // reached a parse ⇒ the arm exists
                assert(!accepted,
                       "stage '" ~ label ~ "' accepts setAttr(\"" ~ probe
                       ~ "\", \"" ~ v ~ "\") but does not list '" ~ probe
                       ~ "' in knownAttrs() — the forms startup-strict "
                       ~ "validator's universe is under-reported, so the "
                       ~ "first form binding it throws at boot (task 0685 T1)");
            }
        }
    }
}


unittest {
    auto live = new ActionCenterStage(null, null);
    live.mode = ActionCenterStage.Mode.Origin;
    ActionCenterStage.Mode parsed;
    assert(ActionCenterStage.parsePreparedMode("border", parsed));
    assert(parsed == ActionCenterStage.Mode.Border);
    assert(live.mode == ActionCenterStage.Mode.Origin,
           "prepared action-center parse mutated live stage state");
    assert(!ActionCenterStage.parsePreparedMode("not-a-mode", parsed));
    assert(live.mode == ActionCenterStage.Mode.Origin,
           "invalid prepared action-center value mutated live stage state");
    const beforeEpoch = live.slotEpoch;
    live.installPreparedMode(parsed = ActionCenterStage.Mode.Border, "border");
    assert(live.mode == ActionCenterStage.Mode.Border &&
           live.slotEpoch == beforeEpoch + 1,
           "prepared action-center installer omitted state or slot activation");
}

unittest {
    // Prepared parsing must resolve the exact legacy wire table without
    // touching the live stage.  The invalid second value is the atomicity
    // discriminator: a parser that assigns before validating fails here.
    auto live = new AxisStage();
    live.mode = AxisStage.Mode.World;
    AxisStage.Mode parsed;
    assert(AxisStage.parsePreparedMode("element", parsed));
    assert(parsed == AxisStage.Mode.Element);
    assert(live.mode == AxisStage.Mode.World,
           "prepared axis parse mutated live stage state");
    assert(!AxisStage.parsePreparedMode("not-a-mode", parsed));
    assert(live.mode == AxisStage.Mode.World,
           "invalid prepared axis value mutated live stage state");
    const beforeEpoch = live.slotEpoch;
    live.installPreparedMode(parsed = AxisStage.Mode.Element, "element");
    assert(live.mode == AxisStage.Mode.Element &&
           live.slotEpoch == beforeEpoch + 1,
           "prepared axis installer omitted state or slot activation");
    live.userLocked = false;
    live.manualRight = Vec3(9, 8, 7);
    live.installPreparedTransientReset();
    assert(live.mode == AxisStage.Mode.None &&
           live.manualRight == Vec3(1, 0, 0) && live.axIndex == -1,
           "prepared axis transient reset omitted live value state");
    live.userLocked = true;
    live.mode = AxisStage.Mode.World;
    live.installPreparedTransientReset();
    assert(live.mode == AxisStage.Mode.World && live.userLocked,
           "prepared axis transient reset ignored the user lock");
}

unittest {
    auto live = new ConstrainStage();
    assert(!live.enabled && live.geom == ConstrainGeom.Off &&
           live.remembered == Remembered.yes, "fresh constrain stage is not the boot state");
    live.enabled = true;
    live.geom = ConstrainGeom.Screen;
    live.offset = 4.0f;
    live.handle = false;
    live.dblSided = true;
    live.installPreparedTransientReset();
    assert(!live.enabled && live.geom == ConstrainGeom.Off &&
           live.offset == 0.0f && live.handle && !live.dblSided,
           "prepared constrain transient reset omitted live value state");
    live.userLocked = true;
    live.enabled = true;
    live.geom = ConstrainGeom.Screen;
    live.installPreparedTransientReset();
    assert(live.enabled && live.geom == ConstrainGeom.Screen && live.userLocked,
           "prepared constrain transient reset ignored the user lock");
    auto kept = new ConstrainStage();
    kept.remembered = Remembered.inPipe;
    kept.geom = ConstrainGeom.Screen;
    kept.installPreparedTransientReset();
    import toolpipe.state_paths : getStatePath;
    assert(getStatePath("constrain/enabled") == "true" &&
           getStatePath("constrain/geometry") == "off",
           "prepared constrain transient reset published a stale state path");
    assert(kept.enabled && kept.geom == ConstrainGeom.Off,
           "prepared constrain transient reset ignored the remembered constraint");
    const before = kept.capturePreparedCompositionProjection();
    kept.remembered = Remembered.no;
    assert(!kept.matchesPreparedCompositionProjection(before),
           "prepared constrain projection omitted the remembered state");
}

unittest {
    // Prepared preset parsing is detached: a valid-first / invalid-second
    // sequence may change only the output value, never the live stage.
    auto live = new FalloffStage();
    live.type = FalloffType.Linear;
    FalloffType preparedType;
    assert(FalloffStage.parsePreparedType("radial", preparedType));
    assert(preparedType == FalloffType.Radial && live.type == FalloffType.Linear);
    assert(!FalloffStage.parsePreparedType("not-a-type", preparedType));
    assert(live.type == FalloffType.Linear,
           "invalid prepared falloff type mutated live stage state");

    FalloffShape preparedShape;
    ElementMode preparedMode;
    bool preparedTransparent;
    assert(FalloffStage.parsePreparedShape("linear", preparedShape));
    assert(FalloffStage.parsePreparedElementMode("edgeCent", preparedMode));
    assert(preparedMode == ElementMode.Edge);
    assert(FalloffStage.parsePreparedTransparent("false", preparedTransparent));
    assert(!preparedTransparent);
    assert(!FalloffStage.parsePreparedShape("not-a-shape", preparedShape));
    assert(!FalloffStage.parsePreparedElementMode("not-a-mode", preparedMode));
    assert(!FalloffStage.parsePreparedTransparent("maybe", preparedTransparent));

    live.type = FalloffType.Element;
    live.anchorRing = [3u, 7u];
    const beforeEpoch = live.slotEpoch;
    live.installPreparedPreset(FalloffType.Radial, FalloffShape.Smooth,
        ElementMode.Edge, true, "radial", "smooth");
    assert(live.type == FalloffType.Radial &&
           live.shape == FalloffShape.Smooth &&
           live.elementMode == ElementMode.Edge && live.transparent,
           "prepared falloff installer omitted a typed preset field");
    assert(live.anchorRing.length == 0,
           "prepared falloff type switch retained the Element anchor");
    assert(live.slotEpoch == beforeEpoch + 1,
           "prepared falloff preset did not arm the slot exactly once");
    live.userLocked = false;
    live.anchorRing = [2u, 5u];
    live.installPreparedTransientReset();
    assert(live.type == FalloffType.None &&
           live.shape == FalloffShape.Linear && live.anchorRing.length == 0,
           "prepared falloff transient reset omitted config or buffers");
    live.userLocked = true;
    live.type = FalloffType.Cylinder;
    live.anchorRing = [9u];
    live.installPreparedTransientReset();
    assert(live.type == FalloffType.Cylinder && live.anchorRing == [9u] &&
           live.userLocked,
           "prepared falloff transient reset ignored the user lock");
}

// ---------------------------------------------------------------------------
// Task 0179 Stage 4: enforced invariant replacing the retired "KEEP IN SYNC
// with applySetAttr" comment on knownAttrs()/listAttrs(). knownAttrs() is now
// DERIVED from listAttrs() (can't drift from it structurally), but
// applySetAttr is a hand-written string-switch parser that can't be derived
// the same way — so this unittest pins the remaining half of the invariant:
// every name listAttrs() reports must be a name applySetAttr actually
// accepts, round-tripping the CURRENT value through the public setAttr path.
// A name present in listAttrs() but rejected by applySetAttr (or vice versa,
// caught indirectly since knownAttrs() == listAttrs() names by construction)
// would fail here instead of silently drifting.
// ---------------------------------------------------------------------------
unittest {
    auto fs = new FalloffStage();
    // Default-state stage — listAttrs() always reports the full static attr
    // set regardless of the active type (only params(), the Tool Properties
    // schema, is type-filtered), so one pass over the default values already
    // exercises every accepted attr name once.
    foreach (pair; fs.listAttrs()) {
        string name  = pair[0];
        string value = pair[1];
        assert(fs.setAttr(name, value),
               "listAttrs() name '" ~ name ~ "' (value '" ~ value
               ~ "') was rejected by applySetAttr — knownAttrs()/listAttrs()/"
               ~ "applySetAttr have drifted apart");
    }
    // knownAttrs() is DERIVED from listAttrs() — this is a structural
    // tautology today, but pins the derivation against a future edit that
    // reintroduces a second hand-written list.
    auto known = fs.knownAttrs();
    auto listed = fs.listAttrs();
    assert(known.length == listed.length);
    foreach (i, k; known)
        assert(k == listed[i][0]);
}
