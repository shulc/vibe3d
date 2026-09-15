module ui.tool_properties_panel;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import application_command_binding : ApplicationCommandBinding;
import edit_session : EditSession;
import forms : Form;
import forms_render : DispatchFn, FormsPanel, InteractiveDispatchFn;
import params : ParamProvider;
import property_panel : PropertyPanel;
import tool : Tool;
import toolpipe.stage : Stage;
import ui.panel_chrome : popPanelChromeStyle, publishPanelZone,
    pushPanelChromeStyle;

struct ToolPropertiesReadRole {
private:
    Tool delegate() activeTool_;
    string delegate() activeToolId_;
public:
    @disable this();
    this(Tool delegate() activeTool, string delegate() activeToolId) {
        assert(activeTool !is null && activeToolId !is null);
        activeTool_ = activeTool;
        activeToolId_ = activeToolId;
    }
    Tool activeTool() { return activeTool_(); }
    string activeToolId() { return activeToolId_(); }
    const(Stage)[] pipeStages() {
        import toolpipe.pipeline : g_pipeCtx;
        return g_pipeCtx is null ? null : g_pipeCtx.pipeline.all();
    }
}

struct ToolPropertiesActions {
private:
    DispatchFn dispatch_;
    InteractiveDispatchFn interactive_;
    FormsPanel forms_;
    EditSession session_;
public:
    @disable this();
    this(DispatchFn dispatch, InteractiveDispatchFn interactive,
         FormsPanel forms, EditSession session) {
        assert(dispatch !is null && interactive !is null
            && forms !is null && session !is null);
        dispatch_ = dispatch;
        interactive_ = interactive;
        forms_ = forms;
        session_ = session;
    }
    void drawForm(ref Form form, ParamProvider provider,
                  string activeToolId, string stageId) {
        forms_.draw(form, provider, dispatch_, interactive_,
                    activeToolId, stageId);
    }
    void drawToolParams(PropertyPanel panel, Tool tool) {
        panel.draw(tool, session_);
    }
    void drawStageParams(PropertyPanel panel, Stage stage) {
        panel.drawProvider(stage, session_);
    }
}

struct ToolPropertiesPanelRoles {
private:
    ToolPropertiesReadRole read_;
    ToolPropertiesActions actions_;
public:
    @disable this();
    this(ToolPropertiesReadRole read, ToolPropertiesActions actions) {
        read_ = read;
        actions_ = actions;
    }
    ToolPropertiesReadRole read() { return read_; }
    ToolPropertiesActions actions() { return actions_; }
}

ToolPropertiesPanelRoles bindToolPropertiesPanel(
        ApplicationCommandBinding binding, FormsPanel forms,
        EditSession session, Tool delegate() activeTool,
        string delegate() activeToolId) {
    assert(binding !is null);
    return ToolPropertiesPanelRoles(
        ToolPropertiesReadRole(activeTool, activeToolId),
        ToolPropertiesActions(&binding.dispatchUi,
            &binding.dispatchInteractiveUi, forms, session));
}

// CONTRACT (task 6060). Tool Properties reads the active Tool/id and pipeline
// stages live on every draw and routes value rows through the production
// interactive refire binding. It owns no Tool, Stage or Session state; its only
// persistent state is the module-local tab selection. The window-level Begin/End
// and chrome style follow the panel prologue rule established by task 0719; this
// deliberately replaces the old plain tail so exceptional exits unwind both
// stacks. Tests: tool_properties_panel_roles_test.

// Which page of the Tool Properties panel is showing. 0 = "Main" (the active
// tool's properties plus every pipe stage's collapsible section, exactly the
// single column this panel has always been); 1 = "Snapping". Module scope
// because the panel is rebuilt from scratch every frame and the choice has to
// outlive the frame that made it. Inert while `kSnappingHasOwnTab` is false —
// there is only one page then, and it is Main.
private enum int kToolPropsTabMain      = 0;
private enum int kToolPropsTabSnapping  = 1;
private __gshared int g_toolPropsTab = kToolPropsTabMain;

// ---------------------------------------------------------------------------
// LAYOUT SWITCH — does snapping get a TAB of its own, or a collapsing section
// in the Main column like every other pipe stage? (task 0638)
//
// One boolean drives BOTH halves: the tab strip below, and the per-stage
// section loop's `taskCode() == Snap` exception. Flip it and snapping moves;
// nothing else has to change, and neither arm can rot, because both are
// ordinary `if` branches the compiler type-checks either way.
//
// WHY IT IS A SWITCH AND NOT A DECISION. Two records disagree.
//
//   * The tab was added deliberately (task 0544) and the reasoning below
//     cites the owner's report AND the reference's shipped layout config.
//   * The owner now reports the opposite: snapping should be a collapsible
//     section like the others.
//
// Re-reading the reference's config settles the CONFIG half, and it does not
// support the tab. The four peer container sheets are real — but they are the
// four children of ONE sheet, each entered as a reference control carrying a
// "starts collapsed / starts open" attribute (all four set to open). That
// attribute belongs to a COLLAPSIBLE GROUP, not to a tab; four such children
// render as four collapsing sections stacked in a single column, which is
// exactly what our per-stage loop already draws. Nowhere in the shipped
// configs is the snapping container exported as a panel or a tab of its own:
// it appears only in the properties config, and every layout that surfaces
// tool properties surfaces the one parent sheet. So "four peers" was read
// correctly as structure and wrongly as presentation.
//
// What that leaves for the owner is a taste question this switch does not
// prejudge: our column is not the reference's column (in the reference the
// snapping section holds a single button that opens the real form as a
// popover, and the whole section is gated on snapping being active), so
// "the config says section" is an argument, not an order. Flip the switch to
// `false` to move snapping into the column; the tab strip then has one entry
// and removes itself, and the section loop stops making an exception for it.
// Once the owner has answered, DELETE the losing arm rather than leaving this
// comment to be re-litigated a third time.
private enum bool kSnappingHasOwnTab = true;

// A broken stage form degrades to the legacy drawProvider every frame; the
// log service's once-gate keeps the diagnostic to a single line per stage
// instead of per-frame spam.
private void warnStageFormOnce(string stageId, string msg) {
    import log : logWarnOnce;
    logWarnOnce("forms", stageId,
                "stage form for '" ~ stageId ~
                "' failed to draw; falling back to legacy panel: " ~ msg);
}


void drawToolPropertiesPanel(ToolPropertiesReadRole read,
        ToolPropertiesActions actions, PropertyPanel propertyPanel,
        float windowX) {
    import toolpipe.stage : Stage, TaskCode;
    // The BODY of a pipe stage's Tool Properties section: the
    // config-driven form when one is registered for the stage family,
    // the legacy provider panel otherwise, then the stage's own custom
    // block. Extracted (task 0544) so the per-stage collapsing headers
    // and the Snapping tab below render through ONE path and cannot
    // drift into two behaviours for the same rows.
    //
    // Phase 6: prefer a config-driven stage form (bound to the stage
    // via whenStage:, looked up by the stage's id()) over the legacy
    // drawProvider path — same gating + kill switch as the tool-level
    // form integration below. The stage IS a ParamProvider, so
    // FormsPanel queries its live (type-filtered) params() per frame
    // and hides rows whose attr the active type doesn't expose. Stages
    // without a matching form fall back to the unchanged drawProvider.
    // stage.drawProperties() still runs in both cases (shape popup /
    // auto-size buttons aren't form rows).
    // Look the form up by the stage FAMILY id (not the unique id), so
    // stacked falloff instances ("falloff#1", …) all resolve the one
    // "falloff" form; FormsPanel filters its rows against this
    // instance's params() and the stage.id() passed below rebinds the
    // write to the right instance.
    void drawStageBody(Stage stage) {
        import forms : g_formsPanelEnabled, formByStage;
        auto stageForm = g_formsPanelEnabled
                       ? formByStage(stage.formFamilyId()) : null;
        if (stageForm !is null) {
            // A malformed row must degrade to the legacy panel, NOT
            // throw mid-ImGui-frame (an escaping exception would leave
            // ImGui's stack unbalanced and abort the frame). Fall back
            // to drawProvider on any failure; warn ONCE per stage so a
            // broken form doesn't spam stderr every frame.
            try {
                actions.drawForm(*stageForm, stage, "", stage.id());
            } catch (Exception e) {
                warnStageFormOnce(stage.id(), e.msg);
                actions.drawStageParams(propertyPanel, stage);
            }
        } else
            actions.drawStageParams(propertyPanel, stage);
        stage.drawProperties();
    }
    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    ImGui.SetNextWindowPos(ImVec2(windowX, 10), ImGuiCond.FirstUseEver);
    // Default tall enough to show a typical tool form (e.g. the box's
    // Position/Size/Segments/Radius groups) plus the per-stage sections
    // (Falloff, ACEN, ...) without manual resizing. FirstUseEver keeps
    // the user's own resize sticky in a normal run.
    ImGui.SetNextWindowSize(ImVec2(260, 520), ImGuiCond.FirstUseEver);
    scope(exit) ImGui.End();
    if (ImGui.Begin("Tool Properties")) {
        publishPanelZone("toolProps");
        // Start/finish one recording of this column's id namespace
        // (task 0640) — a no-op outside --test. Publishing at the end
        // means a reader on the HTTP thread sees whole columns only.
        import property_panel : beginToolPropsIdColumn,
                                endToolPropsIdColumn;
        beginToolPropsIdColumn();
        scope(exit) endToolPropsIdColumn();
        // ---- Tabs (task 0544) ------------------------------------
        // The panel had none: the active tool's properties and every
        // pipe stage's section shared one column, and snapping was not
        // even in that column — SnapStage shipped without a params()
        // schema, so the per-stage loop below skipped it in silence and
        // the master toggle, the type set and the two pixel ranges that
        // decide whether a drag sticks had no panel at all.
        //
        // It has a schema now. WHETHER that schema draws on a tab of
        // its own or as one more collapsing header in the column is
        // the `kSnappingHasOwnTab` switch at the top of this module —
        // read the note there before changing anything here; it
        // records what the reference's layout config actually says
        // (re-read for task 0638) and why the earlier reading of it
        // does not survive.
        //
        // Everything that was in the column stays in the column, in
        // its old order, under "Main" — promoting the action-centre
        // and falloff sections to pages of their own is a change to a
        // surface that already works, and this is not that change.
        //
        // Built from Selectable + SameLine rather than a tab-bar
        // widget: the ImGui binding this build links exposes no
        // BeginTabBar/BeginTabItem. Same behaviour — a strip of
        // mutually exclusive pages, one visible at a time — and no
        // Begin/End pairing to leave unbalanced if a page throws.
        //
        // The Snapping entry's TEXT is the stage's own display name,
        // not a literal, so tab and section header are the same word by
        // construction and cannot drift apart.
        //
        // The strip itself sits at the WINDOW's id scope — everything
        // below it (the tool's rows, every section) is inside a scope
        // of its own since task 0640, so an entry here can no longer
        // collide with a row that happens to share its text.
        if (kSnappingHasOwnTab) {
            import toolpipe.stages.snap : kSnapDisplayName;
            static immutable string[] kTabs = ["Main", kSnapDisplayName];
            foreach (i, name; kTabs) {
                if (i) ImGui.SameLine();
                immutable float w = ImGui.CalcTextSize(name).x + 16.0f;
                if (ImGui.Selectable(name,
                                     g_toolPropsTab == cast(int)i,
                                     0, ImVec2(w, 0)))
                    g_toolPropsTab = cast(int)i;
            }
            ImGui.Separator();
        } else {
            // One page, so no strip. Pin the page so a stale choice
            // left over from a build that HAD the tab cannot hide the
            // whole panel behind a page that no longer renders.
            g_toolPropsTab = kToolPropsTabMain;
        }
        immutable bool inMain = !kSnappingHasOwnTab
                             || g_toolPropsTab != kToolPropsTabSnapping;
        if (inMain) {
            // Config-driven forms (Phase 4/5): when the forms panel is
            // enabled (default; disable with VIBE3D_FORMS=0) AND a loaded form matches the active
            // tool, render it through FormsPanel — which queries the live
            // params() per frame and dispatches writes through the same
            // command path the HTTP API uses (value rows marked interactive
            // so the reEvaluate() seam opens a coalesced undo session).
            // Otherwise fall back to the unchanged PropertyPanel +
            // drawProperties() path for every un-migrated tool.
            // Tool-level form / properties only when a tool is active. When
            // the panel is open ONLY because a falloff is active (no tool),
            // skip straight to the per-stage sections below.
            if (read.activeTool() !is null) {
            // The tool's own rows get an id scope of their own for the
            // same reason every stage section does (task 0640): they
            // share this window with the tab strip, the section headers
            // and every stage's rows, and a tool must be free to label
            // a row whatever fits without consulting that list.
            propertyPanel.pushScope(read.activeToolId());
            scope(exit) propertyPanel.popScope();
            import forms : g_formsPanelEnabled, formsForTool;
            auto matchingForms = g_formsPanelEnabled
                               ? formsForTool(read.activeToolId()) : null;
            if (matchingForms.length) {
                // Pass read.activeToolId() so FormsPanel rebinds a tool-namespace
                // write (the form line carries the canonical family id
                // `xfrm.transform`) to whichever XfrmTransformTool activation
                // id is live — move / rotate / scale / a transform preset —
                // satisfying ToolAttrCommand's active-id guard.
                foreach (ref fm; matchingForms)
                    actions.drawForm(fm, read.activeTool(), read.activeToolId(), "");

                // The transform form now owns ALL the TRS value rows —
                // Position (TX/TY/TZ), Rotate (RX/RY/RZ) and Scale (SX/SY/SZ),
                // all driven through the reEvaluate() seam. The legacy
                // moveSub/rotateSub/scaleSub sliders would duplicate every row
                // (and fight the form's live widgets), so suppress them while
                // the form rendered. For any other formed tool the latch is
                // harmless (it only gates the transform tool's TRS sliders); we
                // still call drawProperties() so a formed tool's custom non-row
                // UI (if any) renders. The schema panel is NOT drawn: the
                // transform tool sets renderParamsAsPanel()==false
                // (PropertyPanel.draw early-returns), and formed tools render
                // values via the form.
                import tools.transform.xfrm_transform : XfrmTransformTool;
                if (auto xf = cast(XfrmTransformTool) read.activeTool()) {
                    xf.suppressTRSProperties = true;
                    scope(exit) xf.suppressTRSProperties = false;
                    xf.drawProperties();
                }
            } else {
                actions.drawToolParams(propertyPanel, read.activeTool()); // schema-driven params first
                read.activeTool().drawProperties();      // tool-specific custom UI after
            }
            } // if (read.activeTool() !is null)

            // Phase 7.9: each enabled tool-pipe stage with a params()
            // schema gets its own collapsible section below the
            // active tool's properties — data-driven composition
            // where the same Tool Properties window
            // surfaces both the active tool AND the stages that
            // modulate it (Workplane, ACEN, AXIS, Falloff — plus Snap
            // unless it is holding a tab, see the exception below).
            // Stages without a schema (e.g. NopStage placeholders,
            // or older stages that haven't been migrated yet)
            // collapse to nothing.
            foreach (s; read.pipeStages()) {
                    if (!s.pipeEnabled) continue;
                    auto stage = cast(Stage)s;
                    if (stage is null) continue;
                    if (stage.params().length == 0) continue;
                    // The OTHER half of `kSnappingHasOwnTab`. While the
                    // tab exists, snapping is drawn there (below) and
                    // skipped here rather than appearing in both places;
                    // clear the switch and this exception lifts, snapping
                    // becomes an ordinary header in this loop, and the
                    // second draw path below goes cold in the same move.
                    if (kSnappingHasOwnTab
                        && stage.taskCode() == TaskCode.Snap)
                        continue;
                    // Default-open so the extra stage sections (Action
                    // Center, Falloff, ...) are expanded without a
                    // click; the user can still collapse any of them.
                    //
                    // Header AND body go through drawSection so both
                    // land inside the stage's id scope (task 0640) —
                    // the header cannot be drawn here and the scope
                    // opened inside the body, because CollapsingHeader
                    // takes its id from its own label.
                    propertyPanel.drawSection(
                        stage.id(), stage.displayName(),
                        () { drawStageBody(stage); });
                }
        } // if (inMain)

        // ---- Snapping ---------------------------------------------
        // THE SECOND DRAW PATH, and it exists only because of the tab.
        // `inMain` is unconditionally true when `kSnappingHasOwnTab`
        // is false, so clearing the switch makes this block dead and
        // it should be deleted along with the loop exception above —
        // one stage body drawn by two paths is a drift hazard that is
        // worth carrying only while the tab is.
        //
        // Drawn through `drawStageBody`, the same path the per-stage
        // sections take, so the rows, their write path and their HTTP
        // twins are the section's — only the location differs.
        //
        // Drawn whether or not the SNAP stage's master toggle is on:
        // that toggle is the FIRST row, and a page that emptied itself
        // when you switched snapping off would leave no way to switch
        // it back on. (The loop above gates on `Stage.pipeEnabled`,
        // the pipe REGISTRATION flag — a different boolean from
        // SnapStage's user-facing `enabled` master toggle. Task 0705
        // renamed the pipe flag; the two used to share a spelling, and
        // this paragraph existed to tell them apart.)
        if (!inMain) {
            foreach (s; read.pipeStages()) {
                if (!s.pipeEnabled) continue;
                auto stage = cast(Stage)s;
                if (stage is null) continue;
                if (stage.taskCode() != TaskCode.Snap) continue;
                // Same id scope the section loop opens (task 0640), so
                // the page and the section put identical rows under
                // identical ids — the tab is a location, not a second
                // namespace.
                propertyPanel.drawScoped(stage.id(),
                                         () { drawStageBody(stage); });
            }
        }
    }
}
