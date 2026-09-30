module tests.unit.scale_input_policy_test;
import tools.transform.scale_input;
import math : Vec3;
import std.math : abs;

unittest {
    const start = Vec3(1.4f, 2, .4f), sample = Vec3(1.3f, 1.5f, .4f);
    auto ratio = evaluateScaleSample(start, sample, ScaleSampleComposition.ratio, false);
    assert(abs(ratio.x - 1.82f) < 1e-6 && ratio.y == 3 && abs(ratio.z - .16f) < 1e-6,
        "default ratio sample law");
    auto offset = evaluateScaleSample(start, sample, ScaleSampleComposition.factorOffset, false);
    assert(abs(offset.x - 1.7f) < 1e-6 && offset.y == 2.5f && offset.z == 0,
        "absolute factor offset and composed clamp on every axis");
    const negativeHeld = Vec3(-.2f,-.4f,-.6f);
    assert(evaluateScaleSample(negativeHeld, Vec3(1,1,1), ScaleSampleComposition.ratio, false) == negativeHeld,
        "ratio identity preserves finite negative held control");
    assert(evaluateScaleSample(negativeHeld, Vec3(1,1,1), ScaleSampleComposition.factorOffset, false) == negativeHeld,
        "offset identity preserves finite negative held even when permission is disabled");
    assert(evaluateScaleSample(start, Vec3(1,1,1), ScaleSampleComposition.factorOffset, false) == start,
        "offset identity preserves held start");
    assert(evaluateScaleSample(start, sample, ScaleSampleComposition.factorOffset, false) == offset,
        "absolute sample replay is idempotent");
    const signedResult = evaluateScaleSample(start, sample, ScaleSampleComposition.factorOffset, true);
    assert(abs(signedResult.z + .2f) < 1e-6, "negative permission follows composition");
    assert(abs(evaluateScaleSample(Vec3(1.7f,1.7f,1.7f), Vec3(-.2f,-.2f,-.2f),
        ScaleSampleComposition.factorOffset, false).x - .5f) < 1e-6, "signed sample stays unclamped before composition");
    const invalid = evaluateScaleSample(start, Vec3(float.nan,float.infinity,-float.infinity),
        ScaleSampleComposition.factorOffset, false);
    assert(invalid == start, "invalid offset samples preserve start");
    const overflow = evaluateScaleSample(Vec3(float.max,float.max,float.max),
        Vec3(float.max,float.max,float.max), ScaleSampleComposition.factorOffset, false);
    assert(overflow == Vec3(float.max,float.max,float.max), "invalid composed offset preserves finite start");
}

unittest {
    ScaleInputPolicy defaults;
    assert(defaults.normalization == ScaleNormalization.gizmoProjection &&
        defaults.accumulation == ScaleAccumulation.continuous &&
        defaults.composition == ScaleSampleComposition.ratio &&
        defaults.referencePixels == 120 && defaults.referenceScale == 1 && defaults.smallScale == 1 &&
        defaults.ticksPerUnit == 100 && defaults.factorPerTick == .005,
        "neutral scale input defaults");
    defaults.ticksPerUnit = 7; defaults.factorPerTick = 90;
    ScaleCentreInputState continuous;
    assert(advanceScaleInput(continuous, .4, defaults) == 1.4f, "continuous default ignores ticks");
    ScaleInputPolicy policy;
    policy.accumulation = ScaleAccumulation.eventTicks;
    ScaleCentreInputState step2, step4;
    foreach (i; 1 .. 41) advanceScaleInput(step2, i * 2.0 / 72, policy);
    foreach (i; 1 .. 21) advanceScaleInput(step4, i * 4.0 / 72, policy);
    assert(abs(step2.offset - .4) < 1e-10, "two pixel event population40 offset .4");
    assert(abs(step4.offset - .5) < 1e-10, "four pixel event population20 offset .5 separates smooth gain");
    ScaleCentreInputState state;
    assert(advanceScaleInput(state, 0, policy) == 1, "exact zero gives no tick");
    assert(advanceScaleInput(state, .00001, policy) == 1.005f, "tiny positive minimum tick");
    assert(advanceScaleInput(state, 0, policy) == 1, "tiny negative minimum tick reversal");
    advanceScaleInput(state, .028, policy);
    advanceScaleInput(state, .039, policy);
    assert(abs(state.offset - .015) < 1e-10, "successive distance updates without fractional remainder");
    assert(advanceScaleInput(state, double.nan, policy) == 1, "nonfinite input is identity");
    assert(abs(state.offset - .015) < 1e-10, "invalid input preserves finite accumulator");
    ScaleCentreInputState enormous;
    enormous.previousDistance = -double.max;
    assert(advanceScaleInput(enormous, double.max, policy) == 1,
        "overflowed successive delta preserves finite sample");
    assert(signedScaleDistance(Vec3(0,0,0), Vec3(1,0,0), 72) == 0, "zero vector distance");
    assert(signedScaleDistance(Vec3(-3,4,0), Vec3(1,0,0), 10) == -.5, "signed vector length");
    assert(signedScaleDistance(Vec3(0,-5,0), Vec3(1,0,0), 10) == .5, "zero sign dot is positive");
}

unittest {
    import std.file : readText;
    import std.string : indexOf;
    auto consumer = readText("source/tools/transform/xfrm_transform.d");
    assert(consumer.indexOf("run.s = evaluateScaleSample(gestureStart.s, f,") >= 0 &&
        consumer.indexOf("scaleSub.pendingScaleComposition, negScale);") >= 0,
        "production scale drain consumes declared sample semantics");
    auto producer = readText("source/tools/transform/scale.d");
    assert(producer.indexOf("centreInputPolicy.referencePixels * centreInputPolicy.referenceScale * centreInputPolicy.smallScale") >= 0,
        "production physical normalization forwards every declared construction unit");
    assert(producer.indexOf("publishScaleGesture(centreInputPolicy.composition);") >= 0,
        "production centre producer forwards composition");
    assert(producer.indexOf("ScaleSampleComposition composition = ScaleSampleComposition.ratio") >= 0,
        "axis and plane publications default to ratio");
}

unittest {
    import tool_presets : loadToolPresets;
    import std.file : write, remove, readText;
    import std.string : indexOf;
    auto presets = loadToolPresets("config/tool_presets.yaml");
    size_t defaultCount, optedCount;
    foreach (preset; presets) {
        if (preset.id != "xfrm.scaleUniform") {
            assert(preset.scaleInput == ScaleInputPolicy.init, "other presets preserve scale input defaults");
            ++defaultCount;
        } else {
            ++optedCount;
            assert(preset.scaleInput.normalization == ScaleNormalization.viewportModelLength &&
                preset.scaleInput.accumulation == ScaleAccumulation.eventTicks &&
                preset.scaleInput.composition == ScaleSampleComposition.factorOffset &&
                preset.scaleInput.referencePixels == 120 && preset.scaleInput.referenceScale == 1 &&
                preset.scaleInput.smallScale == .6f && preset.scaleInput.ticksPerUnit == 100 &&
                preset.scaleInput.factorPerTick == .005 && preset.toolAttrs["negScale"] == "true",
                "measured uniform preset declares physical event input and signed factors");
        }
    }
    assert(defaultCount == 22 && optedCount == 1, "preset input policy population");
    import std.process : thisProcessID;
    import std.conv : to;
    const path = "/var/tmp/vibe3d-8630-scale-policy-" ~ to!string(thisProcessID) ~ ".yaml";
    write(path, `presets:
  - id: alternate
    alias: declared
  - id: declared
    base: scale
    scaleInput:
      normalization: viewportModelLength
      accumulation: eventTicks
      composition: factorOffset
      referencePixels: 90
      referenceScale: 2
      smallScale: 0.4
      ticksPerUnit: 80
      factorPerTick: 0.01
`);
    scope(exit) remove(path);
    auto alternate = loadToolPresets(path);
    assert(alternate.length == 2 && alternate[0].scaleInput.referencePixels == 90 &&
        alternate[0].scaleInput.referenceScale == 2 && alternate[0].scaleInput.smallScale == .4f &&
        alternate[0].scaleInput.ticksPerUnit == 80 && alternate[0].scaleInput.factorPerTick == .01,
        "generic numeric scale policy parser");
    assert(alternate[1].scaleInput == alternate[0].scaleInput, "alias copies entire scale input policy");
    import registry : Registry, typedToolFactory;
    import tool_presets : ToolPreset, registerToolPresets;
    import tools.transform.xfrm_transform : XfrmTransformTool;
    import mesh : Mesh, makeCube;
    import mesh_gpu : GpuMesh;
    import editmode : EditMode;
    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto reused = new XfrmTransformTool(() => &mesh, &gpu, &mode);
    Registry registry;
    registry.registerTool("scale", typedToolFactory!XfrmTransformTool(() => reused));
    ToolPreset control; control.id = "control"; control.base = "scale";
    registerToolPresets(registry, alternate ~ control);
    foreach (id; ["declared", "alternate"]) {
        reused.scaleBank().centreInputPolicy = ScaleInputPolicy.init;
        auto made = cast(XfrmTransformTool)registry.toolFactory(id)();
        assert(made is reused && made.scaleBank().centreInputPolicy == alternate[0].scaleInput,
            "alternate preset factory forwards identical declared policy");
    }
    auto reset = cast(XfrmTransformTool)registry.toolFactory("control")();
    assert(reset.scaleBank().centreInputPolicy == ScaleInputPolicy.init,
        "default typed factory resets inherited alternate policy");
    foreach (bad; ["normalization: invented", "accumulation: invented", "composition: invented",
                   "referencePixels: 0", "referenceScale: -1", "smallScale: 0", "ticksPerUnit: 0",
                   "factorPerTick: -1", "invented: 1"]) {
        write(path, "presets:\n  - id: bad\n    base: scale\n    scaleInput:\n      " ~ bad ~ "\n");
        bool refused;
        try { loadToolPresets(path); } catch (Exception e) { refused = true; }
        assert(refused, "scale policy rejects invalid declaration: " ~ bad);
    }
    write(path, "presets:\n  - id: bad\n    alias: declared\n    scaleInput: {}\n  - id: declared\n    base: scale\n");
    bool refusedAlias;
    try { loadToolPresets(path); } catch (Exception e) { refusedAlias = true; }
    assert(refusedAlias, "alias cannot override scale policy");
    write(path, "presets:\n  - id: bad\n    base: mesh.smoothShiftTool\n    scaleInput: {}\n");
    bool refusedBase;
    try { loadToolPresets(path); } catch (Exception e) { refusedBase = true; }
    assert(refusedBase, "scale policy requires scale bank base");
    auto factory = readText("source/tool_presets.d");
    assert(factory.indexOf("t.scaleBank().centreInputPolicy = ScaleInputPolicy.init;") >= 0 &&
        factory.indexOf("t.scaleBank().centreInputPolicy = presetCopy.scaleInput;") >= 0,
        "typed preset factory resets and forwards declared scale input");
}

unittest {
    import tools.transform.scale : ScaleTool;
    import mesh : Mesh, makeCube;
    import mesh_gpu : GpuMesh;
    import editmode : EditMode;
    import operator : VectorStack;
    import bindbc.sdl : SDL_MouseButtonEvent, SDL_BUTTON_LEFT;
    Mesh mesh = makeCube(); GpuMesh gpu; EditMode mode = EditMode.Polygons;
    auto bank = new ScaleTool(() => &mesh, &gpu, &mode);
    void seed() {
        bank.pendingScaleValid = true;
        bank.pendingScale = Vec3(2,3,4);
        bank.pendingScaleComposition = ScaleSampleComposition.factorOffset;
        bank.centreInput.previousDistance = 4;
        bank.centreInput.offset = -.6;
        bank.centreInput.displacement = Vec3(5,6,7);
        bank.centreInput.screenDisplacement = Vec3(8,9,0);
        bank.centreInput.screenRight = Vec3(0,1,0);
        bank.centreInput.screenUp = Vec3(0,0,1);
    }
    void clear(string boundary) {
        assert(!bank.pendingScaleValid && bank.pendingScale == Vec3(1,1,1) &&
            bank.pendingScaleComposition == ScaleSampleComposition.ratio &&
            bank.centreInput == ScaleCentreInputState.init,
            "scale input transient resets at " ~ boundary);
    }
    seed(); bank.activate(); clear("activation");
    seed(); bank.resyncSession(); clear("resync");
    seed(); bank.deactivate(); clear("deactivate");
    seed(); auto image = bank.buildPreparedEmbeddedDeactivateImage();
    assert(bank.preparedEmbeddedDeactivateMatches(image), "prepared deactivation includes centre state");
    bank.centreInput.previousDistance += 1;
    assert(!bank.preparedEmbeddedDeactivateMatches(image), "prepared centre previous distance freshness");
    bank.centreInput.previousDistance -= 1;
    bank.pendingScaleComposition = ScaleSampleComposition.ratio;
    assert(!bank.preparedEmbeddedDeactivateMatches(image), "prepared pending composition freshness");
    bank.pendingScaleComposition = ScaleSampleComposition.factorOffset;
    bank.installPreparedEmbeddedDeactivate(image); clear("prepared deactivate");
    bank.activate();
    SDL_MouseButtonEvent down; down.button = SDL_BUTTON_LEFT;
    VectorStack vectors;
    assert(bank.onMouseButtonDownWithResolvedAxis(down, vectors, 3));
    seed();
    SDL_MouseButtonEvent up; up.button = SDL_BUTTON_LEFT;
    assert(bank.onMouseButtonUp(up, vectors)); clear("release");
}
