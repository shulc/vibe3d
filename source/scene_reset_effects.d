module scene_reset_effects;

import display_state : ViewportDisplay;
import prefs : Prefs, ViewportCellDisplay, mirrorNonTemplateDisplay,
    restoreNonTemplateDisplay;
import subpatch_preview : SubpatchPreview;
import tool_activation_ownership : ToolTransition;
import viewport : LayoutPreset, ViewportManager;

/// The application effects shared by both document-reset commands. They run in
/// two separate command phases: the viewport effect while mode, morph and pipe
/// state are still the old document's, and the tool effects only after those
/// resets. Keep the phases separate and ordered (task 6020; evidence:
/// scene_reset_effects_test and test_reset_effects_doors).
struct SceneResetEffects {
private:
    ViewportManager viewports_;
    SubpatchPreview* preview_;
    Prefs* prefs_;
    /// Deliberately call-shaped rather than suffixed: the ownership census
    /// recognizes the invocation in resetToolEffects as this capability's site.
    void delegate(ToolTransition) dropActiveTool;

public:
    @disable this();

    this(ViewportManager viewports, SubpatchPreview* preview, Prefs* prefs,
         void delegate(ToolTransition) dropActiveTool) {
        assert(viewports !is null, "scene reset requires the viewport manager");
        assert(preview !is null, "scene reset requires the subpatch preview");
        assert(prefs !is null, "scene reset requires preferences storage");
        assert(dropActiveTool !is null, "scene reset requires the tool drop");
        viewports_ = viewports;
        preview_ = preview;
        prefs_ = prefs;
        this.dropActiveTool = dropActiveTool;
    }

    /// Single layout, and the persisted preset mirrors it so a clean shutdown
    /// cannot save a multi-cell layout from before the reset.
    void resetViewport() {
        viewports_.resetToDefault();
        prefs_.viewportLayout = LayoutPreset.Single;
    }

    /// Drop the tool, then leave no subpatch preview and no cached subdivision
    /// topology: the next preview build is a miss (and no stray mutationVersion
    /// bumps). The pipe stages are reset by `SceneReset.apply`'s stage loop, the
    /// one reader of file.new's keep-pipe flag.
    void resetToolEffects() {
        dropActiveTool(ToolTransition.sceneResetDrop);
        preview_.deactivate();
        preview_.dropTopologyCache();
    }
}

/// The test-automation boundary of the per-cell display atoms outside the
/// template (retopology mode, backdrop, vertex dots). A user-visible reset
/// (`file.new`, `scene.reset` through the UI) keeps them, as the reference
/// does (captured C-R1); the script `scene.reset` in test mode clears them in
/// BOTH places, the live cells and their prefs mirror, so no test inherits
/// another's mode (task 8620; `tests/test_retopology_preset.d`).
void clearViewDisplayForAutomation(ViewportManager viewports, ref Prefs store) {
    assert(viewports !is null, "display clear requires the viewport manager");
    foreach (k; 0 .. viewports.views.length) {
        restoreNonTemplateDisplay(viewports.views[k].display,
                                  ViewportCellDisplay.init);
        // The cavity's effect targets go with it: allocation is
        // lazy and process-lived, so without this a test would inherit the
        // previous test's G-buffer.
        viewports.views[k].fbo.releaseEffects();
        viewports.views[k].dirty = true;
    }
    foreach (ref c; store.viewportDisplay)
        mirrorNonTemplateDisplay(c, ViewportDisplay.init);
}
