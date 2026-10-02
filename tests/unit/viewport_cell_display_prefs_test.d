// The persisted half of the per-cell display fields OUTSIDE the template set
// `T` (task 8620): the retopology mode, the backdrop representation and its
// slot style, and the vertex dots. Driven through `prefs.d`'s real
// `savePrefs`/`loadPrefs` pair and the two mirror functions the production
// writers call (`markCellDisplayDirty` mirrors, the `app.d` restore loop
// restores), plus a source census of that restore loop, which runs only
// outside `--test` and so has no runtime witness in the suite.
module tests.unit.viewport_cell_display_prefs_test;

import std.algorithm : count;
import std.conv : to;
import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.process : thisProcessID;
import std.string : indexOf;
import std.traits : EnumMembers;

import display_state : BackdropStyle, DisplayStyle, ViewportDisplay, WireOverlay;
import prefs : Prefs, ViewportCellDisplay, loadPrefs, mirrorNonTemplateDisplay,
    restoreNonTemplateDisplay, savePrefs;
import scene_reset_effects : clearViewDisplayForAutomation;
import tests.unit.census_symbols : blankNonCode;
import viewport : LayoutPreset, ViewportManager;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..");

private string scratch(string tag) {
    auto d = buildPath(tempDir(), format("vibe3d_cell_display_%s_%d", tag, thisProcessID));
    mkdirRecurse(d);
    return d;
}

/// The preset's atoms, written on a live cell display.
private ViewportDisplay presetDisplay() {
    ViewportDisplay d;
    d.retopology = true;
    d.backdropStyle = BackdropStyle.Flat;
    d.backdrop.style = DisplayStyle.Shaded;
    d.active.showVertices = true;
    d.active.pointSize = 6.0f;
    return d;
}

private bool sameNonTemplate(in ViewportDisplay a, in ViewportDisplay b) {
    return a.retopology == b.retopology && a.backdropStyle == b.backdropStyle
        && a.backdrop.style == b.backdrop.style
        && a.active.showVertices == b.active.showVertices
        && a.active.pointSize == b.active.pointSize
        && a.active.smooth == b.active.smooth && a.backdrop.smooth == b.backdrop.smooth;
}

unittest { // P1: the defaults agree, so an untouched cell round-trips as the identity
    ViewportCellDisplay row;
    mirrorNonTemplateDisplay(row, ViewportDisplay.init);
    assert(row == ViewportCellDisplay.init,
        "P1: mirroring the default display must give the default prefs row");
    ViewportDisplay d;
    restoreNonTemplateDisplay(d, ViewportCellDisplay.init);
    assert(d == ViewportDisplay.init,
        "P1: restoring the default prefs row must give the default display");
}

unittest { // P2: one cell's preset atoms survive save -> load -> restore
    const dir = scratch("roundtrip");
    scope(exit) rmdirRecurse(dir);
    // The preset's atoms, except the slot style: the preset's Shaded IS the
    // default, so a dropped slot field would round-trip it unseen.
    auto live = presetDisplay();
    live.backdrop.style = DisplayStyle.Wireframe;
    const ViewportDisplay def;
    assert(live.retopology != def.retopology && live.backdropStyle != def.backdropStyle
        && live.backdrop.style != def.backdrop.style
        && live.active.showVertices != def.active.showVertices
        && live.active.pointSize != def.active.pointSize,
        "P2 rig: the written cell must differ from the default in every atom");
    Prefs p;
    mirrorNonTemplateDisplay(p.viewportDisplay[2], live);
    savePrefs(p, dir);
    const q = loadPrefs(dir);
    ViewportDisplay back;
    restoreNonTemplateDisplay(back, q.viewportDisplay[2]);
    int atoms = 0;
    assert(back.retopology, "P2: retopology lost in the round trip"); ++atoms;
    assert(back.backdropStyle == BackdropStyle.Flat,
        "P2: backdropStyle lost in the round trip"); ++atoms;
    assert(back.backdrop.style == DisplayStyle.Wireframe,
        "P2: the backdrop slot style lost in the round trip"); ++atoms;
    assert(back.active.showVertices, "P2: showVertices lost in the round trip"); ++atoms;
    assert(back.active.pointSize == 6.0f,
        format("P2: pointSize lost in the round trip (%s)", back.active.pointSize)); ++atoms;
    assert(atoms == 5, "P2 floor: five atoms");
    // Not a template choice: the provenance bit stays down.
    assert(!q.viewportDisplay[2].styleUserSet,
        "P2: persisting non-template fields must not mark the template chosen");
    foreach (k; [0, 1, 3])
        assert(q.viewportDisplay[k] == ViewportCellDisplay.init,
            format("P2: cell %d must be untouched by a write to cell 2", k));
}

unittest { // P3: every enum member round-trips (tables derived from the enums)
    const dir = scratch("members");
    scope(exit) rmdirRecurse(dir);
    size_t backdrops, slots;
    foreach (m; [EnumMembers!BackdropStyle]) {
        Prefs p;
        p.viewportDisplay[1].backdropStyle = m;
        savePrefs(p, dir);
        assert(loadPrefs(dir).viewportDisplay[1].backdropStyle == m,
            "P3: backdropStyle " ~ m.to!string ~ " did not round-trip");
        ++backdrops;
    }
    foreach (m; [EnumMembers!DisplayStyle]) {
        Prefs p;
        p.viewportDisplay[1].backdropSlotStyle = m;
        savePrefs(p, dir);
        assert(loadPrefs(dir).viewportDisplay[1].backdropSlotStyle == m,
            "P3: backdropSlotStyle " ~ m.to!string ~ " did not round-trip");
        ++slots;
    }
    assert(backdrops == 4 && slots == 4,
        format("P3 floor: expected 4 + 4 members, ran %d + %d", backdrops, slots));
}

unittest { // P4: tolerant reads — never throw, keep defaults, clamp the size
    const dir = scratch("tolerant");
    scope(exit) rmdirRecurse(dir);
    write(buildPath(dir, "prefs.json"),
        `{ "version": 1, "viewportDisplay": [`
        ~ ` {"retopology":"yes","backdropStyle":"Checker","backdropSlotStyle":7,`
        ~ `  "showVertices":1,"pointSize":"big"},`
        ~ ` {"pointSize":100}, {"pointSize":-3},`
        ~ ` {"style":"Shaded"} ] }`);
    const t = loadPrefs(dir);
    const c0 = t.viewportDisplay[0];
    assert(!c0.retopology && c0.backdropStyle == BackdropStyle.SameAsActive
        && c0.backdropSlotStyle == DisplayStyle.Shaded && !c0.showVertices
        && c0.pointSize == 0.0f,
        "P4: ill-typed or unknown values must keep the defaults");
    assert(t.viewportDisplay[1].pointSize == 64.0f,
        format("P4: point size above the ceiling must clamp to 64, got %s",
               t.viewportDisplay[1].pointSize));
    assert(t.viewportDisplay[2].pointSize == 0.0f,
        "P4: a negative point size must clamp to 0 (the default size)");
    // A file that predates the keys: the fields read back at their defaults.
    const c3 = t.viewportDisplay[3];
    assert(!c3.retopology && c3.backdropStyle == BackdropStyle.SameAsActive
        && !c3.showVertices && c3.pointSize == 0.0f,
        "P4: a cell without the keys must keep the defaults");
}

unittest { // P5: the restore never touches the template set T
    ViewportDisplay d;
    d.active.style = DisplayStyle.Solid;
    d.active.wire = WireOverlay.None;
    d.active.wireAlpha = 0.25f;
    ViewportCellDisplay row;
    row.style = DisplayStyle.Wireframe;        // a T value the restore must ignore
    row.retopology = true;
    restoreNonTemplateDisplay(d, row);
    assert(d.retopology, "P5 population: the restore must have run");
    assert(d.active.style == DisplayStyle.Solid && d.active.wire == WireOverlay.None
        && d.active.wireAlpha == 0.25f,
        "P5: the non-template restore must leave T alone");
}

unittest { // P6: the test-automation clear reaches the live cells AND the mirror
    auto vpm = new ViewportManager(0, 0, 800, 600);
    vpm.applyLayout(LayoutPreset.Quad);
    Prefs store;
    foreach (k; [1, 3]) {
        vpm.views[k].display.retopology = true;
        vpm.views[k].display.backdropStyle = BackdropStyle.Hidden;
        vpm.views[k].display.backdrop.style = DisplayStyle.Solid;
        vpm.views[k].display.active.showVertices = true;
        vpm.views[k].display.active.pointSize = 6.0f;
        mirrorNonTemplateDisplay(store.viewportDisplay[k], vpm.views[k].display);
    }
    vpm.views[1].display.active.style = DisplayStyle.Solid;
    store.viewportDisplay[1].style = DisplayStyle.Solid;
    store.viewportDisplay[1].styleUserSet = true;
    assert(store.viewportDisplay[3].retopology && vpm.views[3].display.retopology,
        "P6 rig: the mode must be on in both places before the clear");
    foreach (k; 0 .. 4) vpm.views[k].dirty = false;
    clearViewDisplayForAutomation(vpm, store);
    int cells = 0;
    foreach (k; 0 .. 4) {
        assert(sameNonTemplate(vpm.views[k].display, ViewportDisplay.init),
            format("P6: live cell %d kept a non-template atom", k));
        // A copy of the row, cleared: equal iff the row already was.
        auto cleared = store.viewportDisplay[k];
        mirrorNonTemplateDisplay(cleared, ViewportDisplay.init);
        assert(cleared == store.viewportDisplay[k],
            format("P6: the prefs mirror of cell %d kept a non-template atom", k));
        assert(vpm.views[k].dirty, format("P6: live cell %d was not marked dirty", k));
        ++cells;
    }
    assert(cells == 4, "P6 floor: four cells");
    assert(vpm.views[1].display.active.style == DisplayStyle.Solid,
        "P6: the clear must leave the live template field alone");
    assert(store.viewportDisplay[1].style == DisplayStyle.Solid
        && store.viewportDisplay[1].styleUserSet,
        "P6: the clear must leave the persisted template choice alone");
}

unittest { // P7: census — app.d restores the non-template fields UNCONDITIONALLY
    // The restore loop runs only outside --test, so no suite cell can see it.
    // Its call must precede the styleUserSet skip inside the same loop, and
    // must not be followed by a displayUserSet write it would then own.
    const app = blankNonCode(readText(buildPath(repoRoot, "source", "app.d")));
    enum loopHead = "foreach (k, ref cd; g_prefs.viewportDisplay)";
    assert(app.count(loopHead) == 1, "P7: expected exactly one prefs restore loop");
    const at = app.indexOf(loopHead);
    const restoreAt = app.indexOf(
        "restoreNonTemplateDisplay(vpm.views[k].display, cd);", at);
    const skipAt = app.indexOf("if (!cd.styleUserSet) continue;", at);
    assert(restoreAt > at && skipAt > at,
        "P7: the restore loop lost its non-template restore or its T skip");
    assert(restoreAt < skipAt,
        "P7: the non-template restore must run before the styleUserSet skip");
    assert(app.count("restoreNonTemplateDisplay(") == 1,
        "P7: expected exactly one non-template restore call in app.d");
}

unittest { // P6 (task 9070): the two slots' normal source survive save -> load -> restore
    const dir = scratch("smooth");
    scope(exit) rmdirRecurse(dir);
    ViewportDisplay live;
    live.active.smooth = false;     // the default is true: a dropped field reads back true
    live.backdrop.smooth = false;
    Prefs p;
    mirrorNonTemplateDisplay(p.viewportDisplay[1], live);
    assert(!p.viewportDisplay[1].smooth && !p.viewportDisplay[1].backdropSmooth,
        "P6: the mirror must copy both slots' smooth into the row");
    savePrefs(p, dir);
    const q = loadPrefs(dir);
    ViewportDisplay back;
    restoreNonTemplateDisplay(back, q.viewportDisplay[1]);
    assert(!back.active.smooth, "P6: the active slot's smooth lost in the round trip");
    assert(!back.backdrop.smooth, "P6: the backdrop slot's smooth lost in the round trip");
    // A file that predates the keys reads back smooth (the default).
    write(buildPath(dir, "prefs.json"), `{ "version": 1, "viewportDisplay": [ {"retopology":true} ] }`);
    const t = loadPrefs(dir);
    assert(t.viewportDisplay[0].smooth && t.viewportDisplay[0].backdropSmooth,
        "P6: a cell without the keys must keep smooth on");
}
