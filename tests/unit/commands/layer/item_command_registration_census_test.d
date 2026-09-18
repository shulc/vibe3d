module tests.unit.commands.layer.item_command_registration_census_test;

import std.algorithm : count;
import std.file : dirEntries, isFile, readText, SpanMode;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.regex : ctRegex, matchAll, replaceAll;
import std.string : indexOf;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..", "..");

private string squash(string source) {
    return replaceAll(source, ctRegex!(`\s+`), " ");
}

private struct FactorySpan {
    string id;
    string code;
}

private FactorySpan[] factorySpans(string source) {
    struct Marker { size_t at; string id; }
    Marker[] markers;
    foreach (m; source.matchAll(ctRegex!(
            `reg\.commandFactories\[\s*"([^"]+)"\s*\]\s*=`)))
        markers ~= Marker(cast(size_t) m.pre.length, m.captures[1].idup);
    FactorySpan[] spans;
    foreach (i, marker; markers) {
        const end = i + 1 < markers.length ? markers[i + 1].at : source.length;
        spans ~= FactorySpan(marker.id,
            blankNonCode(source[marker.at .. end]).idup);
    }
    return spans;
}

private const(string) spanFor(const FactorySpan[] spans, string id) {
    foreach (span; spans)
        if (span.id == id) return span.code;
    return null;
}

unittest { // C2/C4: per-factory arguments and narrow registrar contexts
    const itemRaw = readText(buildPath(repoRoot, "source",
                                       "item_command_registration.d"));
    const aiRaw = readText(buildPath(repoRoot, "source",
                                     "ai3d_command_registration.d"));
    assert(itemRaw.length > 2_500 && aiRaw.length > 900,
        "6355 registrar floor: a production registrar is missing or truncated");
    const itemSpans = factorySpans(itemRaw);
    const aiSpans = factorySpans(aiRaw);
    assert(itemSpans.length == 15 && aiSpans.length == 5,
        format("6355 span population: found %d item and %d AI spans",
               itemSpans.length, aiSpans.length));
    foreach (span; itemSpans)
        assert(span.code.count("owner.document()") == 1,
            "6355 live document census: " ~ span.id
            ~ " does not resolve the item document once");

    immutable itemHookIds = [
        "layer.add", "layer.duplicate", "layer.delete", "layer.reorder",
        "layer.select", "layer.rename", "layer.setVisible", "layer.attr",
        "layer.parent", "image.load", "image.replace", "image.reload",
        "image.remove", "imagePlane.add",
    ];
    immutable aiHookIds = ["ai3d.importResult", "ai3d.generate"];
    static assert(itemHookIds.length == 14 && aiHookIds.length == 2);
    foreach (id; itemHookIds) {
        const span = spanFor(itemSpans, id);
        assert(span.length && span.count("doors.onActiveLayerChanged") == 1,
            "6355 hook census: " ~ id ~ " does not carry the item hook once");
    }
    foreach (id; aiHookIds) {
        const span = spanFor(aiSpans, id);
        assert(span.length && span.count("onActiveLayerChanged") == 1,
            "6355 hook census: " ~ id ~ " does not carry the AI hook once");
        assert(span.count("owner.document()") == 1,
            "6355 live document census: " ~ id
            ~ " does not resolve the AI document once");
    }
    assert(spanFor(itemSpans, "imagePlane.setImage")
               .count("onActiveLayerChanged") == 0,
        "6355 hook census: imagePlane.setImage span must NOT carry the hook");
    foreach (id; ["ai3d.generate.start", "ai3d.generate.cancel",
                  "ai3d.generate.open"])
        assert(spanFor(aiSpans, id).count("onActiveLayerChanged") == 0,
            "6355 hook census: " ~ id ~ " span must NOT carry the hook");
    assert(itemRaw.count("doors.promoteItemType") == 1
        && spanFor(itemSpans, "layer.select")
               .count("doors.promoteItemType") == 1,
        "6355 promotion census: layer.select must own the only promotion door");
    assert(spanFor(aiSpans, "ai3d.generate.start").count("controller") == 1
        && spanFor(aiSpans, "ai3d.generate.cancel").count("controller") == 1
        && spanFor(aiSpans, "ai3d.generate.open").count("openGenerate") == 1,
        "6355 AI collaborator census changed");

    foreach (raw; [itemRaw, aiRaw]) {
        const code = blankNonCode(raw);
        foreach (banned; ["EditorApp", "editor_app", "Ai3dModalRefs",
                          "RemeshModalRefs", "with (", "with(",
                          "ai3dModalOpen", "ai3dPickedImagePath",
                          "ai3dWorkerUrlBuf", "ai3dModalPendingOpen",
                          "probeHealth"])
            assert(code.count(banned) == 0,
                "6355 no-broad-context witness: registrar names " ~ banned);
    }

    size_t lifecycleFiles;
    size_t directResets;
    foreach (folder; ["layer", "image_plane"])
        foreach (de; dirEntries(buildPath(repoRoot, "source", "commands", folder),
                               "*.d", SpanMode.depth)) {
            if (!isFile(de.name)) continue;
            ++lifecycleFiles;
            const code = blankNonCode(readText(de.name));
            directResets += code.count("clearMorphTarget");
            directResets += code.count("setMorphTarget");
        }
    assert(lifecycleFiles >= 2,
        "6355 lifecycle census floor: command directories were not scanned");
    assert(directResets == 0,
        "6355 lifecycle census: layer/image-plane commands must not reset morph routing directly");
}

unittest { // C10: production wiring, old-path absence and call order
    const registrationRaw = readText(buildPath(repoRoot, "source", "registration.d"));
    assert(registrationRaw.length > 50_000,
        "6355 production wiring floor: registration.d is missing or truncated");
    const registration = squash(blankNonCode(registrationRaw));
    enum callItem = "registerItemCommands(app.reg(), "
        ~ "LiveSessionRole(app.sessionOwner), "
        ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
        ~ "ItemLifecycleDoors(app.onActiveLayerChanged, app.promoteItemType));";
    assert(registration.count(callItem) == 1,
        "6355 production wiring: item call text or multiplicity changed");
    assert(registration.count("registerAi3dCommands(app.reg(),") == 1,
        "6355 production wiring: AI registrar call multiplicity changed");
    assert(registration.count("app.onActiveLayerChanged, app.ai3dController,") == 1
        && registration.count("(string path) {") == 1
        && registration.count("workerUrl.length ? workerUrl : );") == 1,
        "6355 production wiring: ai3d call text or modal callback changed");
    foreach (write; [
            "app.ai3dRefs.ai3dPickedImagePath = path;",
            "app.ai3dRefs.ai3dModal = Ai3dModalState.init;",
            "app.ai3dRefs.ai3dModalOpen = true;",
            "app.ai3dRefs.ai3dModalPendingOpen = true;",
        ])
        assert(registration.count(write) == 1,
            "6355 production wiring: modal callback lost or duplicated " ~ write);
    assert(registration.count("app.ai3dController.probeHealth(") == 1,
        "6355 production wiring: modal callback lost or duplicated probeHealth");
    assert(squash(registrationRaw).count(`"http://127.0.0.1:47831"`) == 1,
        "6355 production wiring: default AI worker URL changed");

    foreach (prefix; [`commandFactories["layer.`, `commandFactories["image.`,
                      `commandFactories["imagePlane.`, `commandFactories["ai3d.`])
        assert(registrationRaw.count(prefix) == 0,
            "6355 old-path witness: registration.d still owns " ~ prefix);
    foreach (className; ["LayerAdd", "LayerDuplicate", "LayerDelete",
            "LayerReorder", "LayerSelect", "LayerRename", "LayerSetVisible",
            "LayerAttr", "LayerParent", "ImageLoad", "ImageReplace",
            "ImageReload", "ImageRemove", "ImagePlaneAdd",
            "ImagePlaneSetImage", "Ai3dImportResult", "Ai3dGenerate",
            "Ai3dGenerateStartTestCommand", "Ai3dGenerateCancelTestCommand",
            "Ai3dGenerateOpen"])
        assert(registration.count("new " ~ className ~ "(") == 0,
            "6355 old-path witness: registration.d still constructs " ~ className);
    assert(registration.count("registerItemCommands(app)") == 0,
        "6355 old-path witness: broad item registrar call survived");

    const lifecycleAt = registration.indexOf("registerToolLifecycleCommands(");
    const itemAt = registration.indexOf("registerItemCommands(");
    const aiAt = registration.indexOf("registerAi3dCommands(");
    const pipeAt = registration.indexOf("registerPipeStageCommands(");
    const wrapperAt = registration.indexOf(
        "auto selTypeSrc = () => currentSelType(selTypeOrder);");
    assert(lifecycleAt >= 0 && itemAt > lifecycleAt,
        "6355 ordering floor: item registrar does not follow tool lifecycle");
    assert(aiAt > itemAt && pipeAt > aiAt,
        "6355 ordering: item/AI/pipe registrar order changed");
    assert(wrapperAt > pipeAt,
        "6355 ordering: selection-type wrapper no longer follows the family");
}
