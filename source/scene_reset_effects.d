module scene_reset_effects;

import prefs : Prefs;
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
    void delegate() resetAllPipeStages_;

public:
    @disable this();

    this(ViewportManager viewports, SubpatchPreview* preview, Prefs* prefs,
         void delegate(ToolTransition) dropActiveTool,
         void delegate() resetAllPipeStages) {
        assert(viewports !is null, "scene reset requires the viewport manager");
        assert(preview !is null, "scene reset requires the subpatch preview");
        assert(prefs !is null, "scene reset requires preferences storage");
        assert(dropActiveTool !is null, "scene reset requires the tool drop");
        assert(resetAllPipeStages !is null, "scene reset requires the pipe reset");
        viewports_ = viewports;
        preview_ = preview;
        prefs_ = prefs;
        this.dropActiveTool = dropActiveTool;
        resetAllPipeStages_ = resetAllPipeStages;
    }

    /// Single layout, and the persisted preset mirrors it so a clean shutdown
    /// cannot save a multi-cell layout from before the reset.
    void resetViewport() {
        viewports_.resetToDefault();
        prefs_.viewportLayout = LayoutPreset.Single;
    }

    /// Drop the tool, reset every pipe stage, then leave no subpatch preview
    /// and no cached subdivision topology: the next preview build is a miss
    /// (and no stray mutationVersion bumps; see `SubpatchPreview.deactivate`).
    void resetToolEffects() {
        dropActiveTool(ToolTransition.sceneResetDrop);
        resetAllPipeStages_();
        preview_.deactivate();
        preview_.dropTopologyCache();
    }
}
