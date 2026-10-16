module tests.unit.scale_input_policy_test;
import vibe3d.editing.tools.transform.tools.transform.scale_input;
import vibe3d.util.math.math : Vec3;
import std.math : abs;

unittest {

import tests.unit.census_symbols : readText = wave15ReadText;
    import std.string : indexOf;
    import std.algorithm : count;
    auto consumer = readText("source/tools/transform/xfrm_transform.d");
    assert(consumer.indexOf("run.s = evaluateScaleSample(gestureStart.s, f,") >= 0 &&
        consumer.indexOf("scaleSub.pendingScaleComposition, negScale);") >= 0,
        "production scale drain consumes declared sample semantics");
    auto producer = readText("source/tools/transform/scale.d");
    assert(producer.indexOf("centreInputPolicy.referencePixels * centreInputPolicy.referenceScale * centreInputPolicy.smallScale") >= 0,
        "production physical normalization forwards every declared construction unit");
    assert(producer.count("publishScaleGesture(centreInputPolicy.composition);") == 2,
        "production centre producer forwards composition");
    assert(producer.indexOf("ScaleSampleComposition composition = ScaleSampleComposition.ratio") >= 0,
        "axis and plane publications default to ratio");
}

unittest {
    import vibe3d.editing.tools.interactive.tool_presets : loadToolPresets;
    import std.file : write, remove;
import tests.unit.census_symbols : readText = wave15ReadText;
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
                preset.scaleInput.factorPerTick == .005 && preset.toolAttrs.get("negScale", "") == "true",
                "measured uniform preset declares physical event input and signed factors");
        }
    }
    assert(defaultCount == 23 && optedCount == 1, "preset input policy population");   // +1 mesh.dragWeld (9525)
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
    import vibe3d.editing.tools.interactive.registry : Registry, typedToolFactory;
    import vibe3d.editing.tools.interactive.tool_presets : ToolPreset, registerToolPresets;
    import vibe3d.editing.tools.interactive.tools.transform.xfrm_transform : XfrmTransformTool;
    import vibe3d.mesh.core.mesh : Mesh, makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.contracts.editmode : EditMode;
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
                   "factorPerTick: -1", "referencePixels: .nan", "factorPerTick: .inf", "invented: 1"]) {
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
    import vibe3d.editing.tools.interactive.tools.transform.scale : ScaleTool;
    import vibe3d.mesh.core.mesh : Mesh, makeCube;
    import vibe3d.viewport.gpu.mesh_gpu : GpuMesh;
    import vibe3d.editing.contracts.editmode : EditMode;
    import vibe3d.editing.pipeline.contracts.operator : VectorStack;
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
