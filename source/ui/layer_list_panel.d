module ui.layer_list_panel;

import bindbc.sdl : SDL_GetModState, KMOD_SHIFT;
import ImGui = d_imgui;
import d_imgui.imgui_h;
import application_command_binding : ApplicationCommandBinding;
import commands.layer.commands : layerDeleteButtonState;
import document : Document, Layer;
import forms : Form;
import forms_render : FormsPanel;
import imgui_flag_boundary : inputTextSubmitOnEnter;
import layer_params : LayerPropsProvider, itemPropsTarget;
import seltype : SelType;
import session_owner : Session;
import tool : Tool;
import ui.item_rename : ItemRenameDispatch, ItemRenameExit, ItemRenameState,
    bindItemRenameController;
import ui.item_rows : RowRole;
import ui.panel_chrome : popPanelChromeStyle, publishPanelZone,
    pushPanelChromeStyle;

struct LayerListReadRole {
private:
    Session* owner_;
    Tool delegate() activeTool_;
public:
    @disable this();
    this(Session* owner, Tool delegate() activeTool) {
        assert(owner !is null && activeTool !is null);
        owner_ = owner; activeTool_ = activeTool;
    }
    const(Document)* document() { return owner_.documentPtr(); }
    SelType currentSelType() {
        import seltype : resolve = currentSelType;
        return resolve(owner_.selTypeOrder);
    }
    bool transformToolActive() {
        import tools.transform.transform : TransformTool;
        return (cast(TransformTool) activeTool_()) !is null;
    }
}

/// What one bound-and-drawn item form reports back to the panel.
struct ItemFormOutcome {
    /// `layers` index the form addresses; `size_t.max` when `!bound` — zero
    /// is a valid layer index.
    size_t targetIndex = size_t.max;
    bool transformGuardArmed;
    bool bound;
}

/// Everything the Items panel keeps between frames, owned by one binding.
final class LayerListPanelState {
private:
    LayerPropsProvider props_;
    Layer[] gangBuf_;
    this() {}
}

struct LayerListActions {
private:
    Session* owner_;
    ItemRenameDispatch dispatch;
    ItemRenameDispatch interactive_;
    FormsPanel forms_;
    LayerListPanelState state_;

    /// Resolve a read-only identity and its index against the live session
    /// document. This is a lookup, not a cast: the action side owns mutation
    /// rights. The null arm is defensive only: production passes identities
    /// projected from this same frame's `doc.layers`.
    Layer resolveLive(Document* doc, const(Layer) id, out size_t index) {
        index = size_t.max;
        if (doc is null || id is null) return null;
        index = doc.indexOf(id);
        return index == doc.layers.length ? null : doc.layers[index];
    }
public:
    @disable this();
    this(Session* owner, ItemRenameDispatch dispatch,
         ItemRenameDispatch interactive, FormsPanel forms,
         LayerListPanelState state) {
        assert(owner !is null && dispatch !is null && interactive !is null
            && forms !is null && state !is null);
        owner_ = owner;
        this.dispatch = dispatch;
        interactive_ = interactive;
        forms_ = forms;
        state_ = state;
    }
    ItemRenameDispatch commandDispatch() { return dispatch; }

    ItemFormOutcome drawItemForm(ref Form form, const(Layer) target,
                                 const(Layer)[] gang, bool toolActive,
                                 SelType current) {
        import std.conv : to;
        auto doc = owner_.documentPtr();
        size_t liveIndex;
        auto live = resolveLive(doc, target, liveIndex);
        if (live is null) return ItemFormOutcome.init;
        if (state_.props_ is null)
            state_.props_ = new LayerPropsProvider(live);
        else
            state_.props_.setLayer(live);
        state_.props_.setTransformGuard(toolActive, current);
        ItemFormOutcome outcome;
        outcome.targetIndex = liveIndex;
        string targets = to!string(outcome.targetIndex);
        // Refill the binding-owned scratch slice by index, then truncate any
        // identities that did not resolve against the current document.
        if (state_.gangBuf_.length != gang.length)
            state_.gangBuf_.length = gang.length;
        size_t resolved;
        foreach (g; gang) {
            size_t gangIndex;
            auto liveGang = resolveLive(doc, g, gangIndex);
            if (liveGang is null) continue;
            state_.gangBuf_[resolved++] = liveGang;
            targets ~= "," ~ to!string(gangIndex);
        }
        if (state_.gangBuf_.length != resolved)
            state_.gangBuf_.length = resolved;
        state_.props_.setGangTargets(state_.gangBuf_);
        outcome.transformGuardArmed = !state_.props_.paramEnabled("pos.x");
        outcome.bound = true;
        forms_.draw(form, state_.props_, dispatch, interactive_, "", "",
                    targets);
        return outcome;
    }
}

struct LayerListPanelRoles {
    LayerListReadRole read;
    LayerListActions actions;
    LayerListPanelState state;
}

LayerListPanelRoles bindLayerListPanel(Session* owner,
        ApplicationCommandBinding binding, FormsPanel forms,
        Tool delegate() activeTool) {
    assert(binding !is null && forms !is null);
    auto state = new LayerListPanelState;
    return LayerListPanelRoles(LayerListReadRole(owner, activeTool),
        LayerListActions(owner, &binding.dispatchUi,
            &binding.dispatchInteractiveUi, forms, state), state);
}

// CONTRACT (task 6030). This module draws the Layers/Items layout and routes
// gestures; `ui.item_rows.itemRowsInto` decides the live row set, ordering,
// names, glyphs, roles, visibility and document indices. The read role is
// consulted during each draw; no Document, primary item or Tool is cached.
//
// Per-row UI-origin dispatch:
//   eye cell       -> layer.setVisible(index, value)
//   role cell      -> layer.select(index, set|toggle|range)
//   name           -> layer.select / layer.rename / layer.reorder
// Add/Delete and the image-plane picker likewise use the action role. The
// form is bound to the focused item and writes through its interactive action.
// The panel never writes the document directly.
// Decision history: doc/layer_list_panel_history.md.

version (unittest) {
    struct LayerListDrawnRow {
        size_t index;
        string name;
        RowRole role;
        bool visible;
        ImVec2 eyeMin, eyeMax;
        ImVec2 roleMin, roleMax;
        ImVec2 nameMin, nameMax;
    }
    struct LayerListDrawSnapshot {
        LayerListDrawnRow[] rows;
        ImVec2 deleteMin, deleteMax;
        bool formBlockEntered;
        bool formBound;
        size_t formTarget;
        bool transformGuardArmed;
        ImVec2 formOrigin;
        float formWidth;
        float formRowH;
    }
    private __gshared LayerListDrawSnapshot g_layerListDrawSnapshot;
    LayerListDrawSnapshot layerListDrawSnapshot() {
        return g_layerListDrawSnapshot;
    }
    void resetLayerListDrawSnapshot() {
        g_layerListDrawSnapshot = LayerListDrawSnapshot.init;
    }
    private void beginLayerListDraw() {
        resetLayerListDrawSnapshot();
    }
    private void recordLayerDelete() {
        g_layerListDrawSnapshot.deleteMin = ImGui.GetItemRectMin();
        g_layerListDrawSnapshot.deleteMax = ImGui.GetItemRectMax();
    }
    private void recordLayerRow(size_t index, string name, RowRole role,
                                bool visible, ImVec2 eyeMin, ImVec2 eyeMax,
                                ImVec2 roleMin, ImVec2 roleMax,
                                ImVec2 nameMin, ImVec2 nameMax) {
        g_layerListDrawSnapshot.rows ~= LayerListDrawnRow(
            index, name, role, visible, eyeMin, eyeMax, roleMin, roleMax,
            nameMin, nameMax);
    }
    private void recordLayerForm(size_t target, bool guardArmed, bool bound,
                                 ImVec2 origin, float width, float rowH) {
        g_layerListDrawSnapshot.formBlockEntered = true;
        g_layerListDrawSnapshot.formBound = bound;
        g_layerListDrawSnapshot.formTarget = target;
        g_layerListDrawSnapshot.transformGuardArmed = guardArmed;
        g_layerListDrawSnapshot.formOrigin = origin;
        g_layerListDrawSnapshot.formWidth = width;
        g_layerListDrawSnapshot.formRowH = rowH;
    }
    /// Which provider object this binding owns — identity comparison only.
    const(Object) layerFormProvider(LayerListPanelState state) {
        return state.props_;
    }
    /// Which item the owned provider is bound to, by identity.
    const(Layer) layerFormBoundItem(LayerListPanelState state) {
        return state.props_ is null ? null : state.props_.layer();
    }
    /// Whether the production-owned provider currently sees a mixed name.
    bool layerFormGangMixed(LayerListPanelState state) {
        return state.props_ !is null && state.props_.paramMixed("name");
    }
} else {
    private void beginLayerListDraw() {}
    private void recordLayerDelete() {}
    private void recordLayerRow(size_t, string, RowRole, bool,
                                ImVec2, ImVec2, ImVec2, ImVec2,
                                ImVec2, ImVec2) {}
    private void recordLayerForm(size_t, bool, bool, ImVec2, float, float) {}

}
void drawLayerListPanel(LayerListReadRole read, LayerListActions actions,
                        ref ItemRenameState itemRenameState) {
    import std.json : JSONValue;
    import std.conv : to;
    import ui.item_rows   : ItemRow, ItemGlyph, RowRole, RowColor, itemRowsInto,
                            kAddItemChoices, itemClickMode;
    import ui.item_glyphs : drawItemGlyph, drawEyeGlyph, drawRoleGlyph,
                            drawDisclosure, kGlyphCellRatio,
                            kGlyphRadiusRatio, kIndentRatio;
    import io.doc_state   : currentDocPath, docDirty;

    auto rename = bindItemRenameController(itemRenameState, read.document(),
                                           actions.commandDispatch());

    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    // CONTRACT: in `Items###Layers`, the title is before `###` and the stable
    // window ID is after it. The dock ini and all three
    // `DockBuilderDockWindow("Layers", ...)` calls key off that ID, so keep
    // the suffix aligned with those dock entries when editing this `Begin`.
    scope(exit) ImGui.End();
    if (ImGui.Begin("Items###Layers")) {
        beginLayerListDraw();
        publishPanelZone("layerList");
        // ---- Metrics -----------------------------------------------------
        // Derived from the ROW HEIGHT rather than written as pixel constants:
        // that height already carries the UI scale and the font swap between
        // a normal run and --test, so the cells track both for free.
        // `GetFontSize()` IS ImGui's text line height (`GetTextLineHeight`
        // returns exactly that, and this binding does not expose the latter).
        // Using it keeps every cell the same height as the name text, so the
        // glyphs sit on the text's own baseline band rather than near it.
        immutable float rowH    = ImGui.GetFontSize();
        immutable float cellW   = rowH * kGlyphCellRatio;
        immutable float gRad    = rowH * kGlyphRadiusRatio;
        immutable float indentW = rowH * kIndentRatio;

        // ---- Shift, and why it does NOT come from `io` --------------------
        // Task 1880. Ctrl below still reads `ImGui.GetIO().KeyCtrl`; there is no
        // `io.KeyShift` to pair it with — our d_imgui binding is a trimmed
        // one and exposes exactly one modifier accessor
        // (`igVibe3d_IO_KeyCtrl`, D-ImGui `imgui_h.d:252`). Widening the
        // binding for one bit means pushing to the pinned fork and re-pinning
        // the commit in dub.json, which is a lot of moving parts for a
        // predicate SDL already answers.
        //
        // `SDL_GetModState()` is the same state ImGui's SDL2 backend feeds
        // `ImGui.GetIO().KeyCtrl` from, so the two cannot disagree within a frame, and it
        // is the reading the rest of the app already takes (`eventlog.d:37`,
        // `shortcuts.d:233`). It is also what makes this TESTABLE: `EventPlayer`
        // calls `SDL_SetModState` during `/api/play-events`, so a recorded
        // Shift+click replays with the modifier actually set.
        immutable bool shiftHeld = (SDL_GetModState() & KMOD_SHIFT) != 0;

        // The panel runs on a LIGHT grey background (143,143,143) with
        // ImGuiCol.Text pushed to black (pushPanelChromeStyle), so these are
        // dark-on-light literals — ImGui's own semi-transparent greys read as
        // washed out here, which is the same reason the old row marker used a
        // literal shade. Packed by hand because this binding exposes no
        // `GetColorU32`.
        immutable uint inkCol  = IM_COL32(0,  0,  0,  255);  // ordinary row
        immutable uint hintCol = IM_COL32(77, 77, 77, 255);  // column header
        immutable uint offCol  = IM_COL32(97, 97, 97, 255);  // hidden / greyed

        // The ROW colours are not decided here (task 0672). `ItemRow.look`
        // carries them, because a colour chosen inside this function has no
        // headless observable — the same argument that put the row CONTENT in
        // `ui/item_rows.d`. This packs, and packing is all it does.
        static uint packed(RowColor c) {
            return IM_COL32(c.r, c.g, c.b, c.a);
        }

        // ---- "Add Item" (one drop-down) + Delete -------------------------
        // ONE button with a list, not one button per kind. With the plane
        // creation route there were already two, and a button per future kind
        // turns this row into a wall; the drop-down names each outcome in
        // words instead.
        {
            immutable float availW  = ImGui.GetContentRegionAvail().x;
            immutable float spacing = ImGui.GetStyle().ItemSpacing.x;
            // The frame height, exactly: this binding has no `GetFrameHeight`,
            // but `GetFrameHeightWithSpacing` is that plus ItemSpacing.y and
            // both terms are reachable.
            immutable float frameH  = ImGui.GetFrameHeightWithSpacing()
                                    - ImGui.GetStyle().ItemSpacing.y;
            immutable float arrowW  = frameH;                 // a square button
            // Deliberately an OVER-estimate of the Delete button's own width:
            // `ImGuiStyle` exposes only ItemSpacing here, so FramePadding.x
            // cannot be read, and one frame height is comfortably more than
            // the two paddings it stands in for. Over-estimating only makes
            // "Add Item" a few pixels narrower; under-estimating would wrap
            // the row.
            immutable float delW = ImGui.CalcTextSize("Delete").x + frameH;
            float addW = availW - arrowW - delW - spacing * 2.0f;
            immutable float addMin = rowH * 3.0f;
            if (addW < addMin) addW = addMin;   // never collapse to nothing

            // Both halves open the same menu: the label is not a separate
            // "add the default kind" action, because there is no default kind
            // — a button whose click did something different from its own
            // arrow is exactly the ambiguity the single menu removes.
            //
            // The arrow is a bare button with a triangle drawn over its rect:
            // this binding has no `ArrowButton`, and drawing it ourselves also
            // keeps it the same triangle the root row's disclosure uses.
            bool openMenu = false;
            if (ImGui.Button("Add Item", ImVec2(addW, 0.0f))) openMenu = true;
            ImGui.SameLine(0.0f, 0.0f);
            if (ImGui.Button("##additem_open", ImVec2(arrowW, 0.0f)))
                openMenu = true;
            {
                immutable ImVec2 amin = ImGui.GetItemRectMin();
                immutable ImVec2 amax = ImGui.GetItemRectMax();
                drawDisclosure(ImGui.GetWindowDrawList(),
                    ImVec2((amin.x + amax.x) * 0.5f, (amin.y + amax.y) * 0.5f),
                    gRad, /*expanded=*/true, inkCol);
            }
            if (openMenu) ImGui.OpenPopup("##additem_menu");

            ImGui.SameLine();
            // ---- Delete button ----
            // Targets `read.document().focusedItem` — the item-selection FOCUS, i.e.
            // the row the panel highlights as current — NOT
            // `read.document().activeIndex`/`primary`. Task 0615 Stage 6 review round
            // 2, BLOCKER 2: a non-mesh row can be the focus without ever
            // becoming primary (§L2), and the old code always dispatched
            // against the primary regardless of which row was highlighted — so
            // clicking a highlighted non-mesh row and pressing Delete silently
            // deleted the (different, unhighlighted) primary instead.
            // `layerDeleteButtonState` (commands/layer/commands.d) is the SAME
            // function driving both the enabled/disabled guard AND the
            // dispatched index, so the two can never disagree the way the
            // primary-vs-focus split did.
            auto delState = layerDeleteButtonState(read.document());
            ImGui.BeginDisabled(!delState.enabled);
            const deleteClicked = ImGui.Button("Delete");
            recordLayerDelete();
            if (deleteClicked) {
                if (delState.enabled && actions.commandDispatch() !is null)
                    actions.commandDispatch()("layer.delete",
                        `{"index":` ~ to!string(delState.index) ~ `}`);
            }
            ImGui.EndDisabled();

            // The entries, their labels and above all the command ids they
            // dispatch are `ui/item_rows.d`'s `kAddItemChoices`, whose tests
            // compare each id against the command class's own `name()` — a
            // typo in a dispatch string is otherwise a button that silently
            // does nothing.
            if (ImGui.BeginPopup("##additem_menu")) {
                foreach (ci, c; kAddItemChoices) {
                    ImGui.PushID(cast(int) ci);
                    if (ImGui.Selectable(c.label)) {
                        if (actions.commandDispatch() !is null)
                            actions.commandDispatch()(c.command, c.args);
                    }
                    // `SetTooltip(string)` in this binding formats through
                    // "%.*s", so a runtime string is safe here — it is not
                    // being passed as a format.
                    if (c.tooltip.length && ImGui.IsItemHovered())
                        ImGui.SetTooltip(c.tooltip);
                    ImGui.PopID();
                }
                ImGui.EndPopup();
            }
        }

        ImGui.Separator();

        // ---- Column headers ----------------------------------------------
        // TWO icon columns and a Name, because two is how many per-row states
        // this panel actually holds a control for. The reference shape has a
        // third; we have nothing behind it, and a narrow empty column is
        // decoration. Each header draws the SAME glyph its column does, so the
        // header says what the column means rather than abbreviating it.
        {
            auto hdl = ImGui.GetWindowDrawList();
            immutable ImVec2 hp = ImGui.GetCursorScreenPos();
            drawEyeGlyph(hdl, ImVec2(hp.x + cellW * 0.5f, hp.y + rowH * 0.5f),
                         gRad, /*visible=*/true, hintCol);
            drawRoleGlyph(hdl, ImVec2(hp.x + cellW * 1.5f, hp.y + rowH * 0.5f),
                          gRad, RowRole.SelectedFirst, hintCol);
            ImGui.Dummy(ImVec2(cellW * 2.0f, rowH));
            ImGui.SameLine(0.0f, 0.0f);
            ImGui.TextDisabled("Name");
        }
        ImGui.Separator();

        // ---- Rows ---------------------------------------------------------
        // WHAT is listed, in WHAT order, at WHAT depth and under WHAT name is
        // `itemRowsInto` — see this function's header comment. Below is
        // placement and dispatch only.
        //
        // One static buffer, refilled in place each frame (the
        // `Document.selectedItemsInto` idiom), so a per-frame draw does not
        // churn an array.
        static ItemRow[] rowBuf;
        static bool rootExpanded = true;
        itemRowsInto(read.document(), currentDocPath(), docDirty(),
                     rootExpanded, rowBuf);

        immutable float contentW = ImGui.GetContentRegionAvail().x;
        auto dl = ImGui.GetWindowDrawList();

        foreach (ri, ref r; rowBuf) {
            ImGui.PushID(cast(int) ri);
            immutable ImVec2 rowP0 = ImGui.GetCursorScreenPos();
            immutable ImVec2 rowP1 = ImVec2(rowP0.x + contentW, rowP0.y + rowH);
            ImVec2 eyeMin, eyeMax, roleMin, roleMax, nameMin, nameMax;

            // ---- Row background ----
            // The WHOLE row, drawn into the window list before any cell, so
            // the highlight spans the icon columns too rather than starting at
            // the name. Two shades for two facts about the SELECTION: being in
            // it, and heading it. An `a` of zero is "no fill" — an unselected
            // row keeps the panel's own backdrop, and after task 0672 that
            // includes an unselected mesh that is still the edit target.
            if (r.look.background.a != 0)
                dl.AddRectFilled(rowP0, rowP1, packed(r.look.background));

            // ---- Row ink ----
            // A selected row is drawn in an ACCENT colour as well as on a
            // highlight — which is the half of "selected" the old plain
            // `Selectable` did not carry. A greyed row (selected, but the item
            // gizmo will not move it) keeps saying so THROUGH the accent
            // rather than losing one of the two facts.
            immutable uint txtCol = packed(r.look.ink);

            // ---- Eye cell ----
            // Absent, not disabled, where there is nothing to toggle (the
            // root): a control that cannot be clicked is the dead ornament
            // this panel is not allowed to draw.
            if (r.canToggleVisible) {
                if (ImGui.InvisibleButton("##vis", ImVec2(cellW, rowH))) {
                    if (actions.commandDispatch() !is null)
                        actions.commandDispatch()("layer.setVisible",
                            `{"index":` ~ to!string(r.index) ~ `,"value":`
                            ~ (r.visible ? "false" : "true") ~ `}`);
                }
                eyeMin = ImGui.GetItemRectMin();
                eyeMax = ImGui.GetItemRectMax();
                drawEyeGlyph(dl,
                    ImVec2(rowP0.x + cellW * 0.5f, rowP0.y + rowH * 0.5f),
                    gRad, r.visible, r.visible ? txtCol : offCol);
            } else {
                ImGui.Dummy(ImVec2(cellW, rowH));
                eyeMin = ImGui.GetItemRectMin();
                eyeMax = ImGui.GetItemRectMax();
            }
            ImGui.SameLine(0.0f, 0.0f);

            // ---- Role cell ----
            // Replaces BOTH the old ">"/"@"/"*" text marker AND the "F"
            // checkbox beside it, and NOTHING a user could read is lost.
            //
            // "F" reported `Document.foreground(l)`, i.e. `visible &&
            // selected` — one checkbox CONFLATING two independent facts, so a
            // cleared box could mean "not selected" or "hidden" and the user
            // could not tell which. The two facts now have a column each: the
            // eye is `visible`, this cell is `selected` (with which KIND of
            // selected as a bonus the checkbox never carried), and
            // "foreground" is their conjunction, read straight off the row.
            //
            // Both dispatches survive too — plain click is the exclusive
            // select the marker was, ctrl-click is `mode:toggle`, whose two
            // outcomes are exactly the checkbox's `mode:add` / `mode:remove`.
            //
            // An exclusive click on a row that is ALREADY the whole selection
            // changes nothing, so it is not dispatched. `r.isSoleSelection`,
            // not "is this the current row": task 0672 — a latched edit target
            // is not the selection, and asking about the target here swallowed
            // the click that would have selected it back. Ctrl-click always
            // dispatches (it must be able to deselect the sole row too).
            if (!r.isRoot) {
                if (ImGui.InvisibleButton("##role", ImVec2(cellW, rowH))) {
                    if (actions.commandDispatch() !is null
                        && (ImGui.GetIO().KeyCtrl || shiftHeld || !r.isSoleSelection))
                        actions.commandDispatch()("layer.select",
                            `{"index":` ~ to!string(r.index) ~ `,"mode":`
                            ~ itemClickMode(ImGui.GetIO().KeyCtrl, shiftHeld) ~ `}`);
                }
                roleMin = ImGui.GetItemRectMin();
                roleMax = ImGui.GetItemRectMax();
                drawRoleGlyph(dl,
                    ImVec2(rowP0.x + cellW * 1.5f, rowP0.y + rowH * 0.5f),
                    gRad, r.role, txtCol);
            } else {
                ImGui.Dummy(ImVec2(cellW, rowH));
                roleMin = ImGui.GetItemRectMin();
                roleMax = ImGui.GetItemRectMax();
            }
            ImGui.SameLine(0.0f, 0.0f);

            // ---- Indent ----
            if (r.depth > 0) {
                ImGui.Dummy(ImVec2(indentW * r.depth, rowH));
                ImGui.SameLine(0.0f, 0.0f);
            }

            // ---- Disclosure slot ----
            // Always RESERVED, drawn only on the root. Reserved because the
            // type glyphs are what the eye follows down the list, and letting
            // a childless row reclaim the triangle's width would leave the
            // glyph column ragged.
            {
                immutable ImVec2 dp = ImGui.GetCursorScreenPos();
                if (r.isRoot) {
                    if (ImGui.InvisibleButton("##disc", ImVec2(cellW, rowH)))
                        rootExpanded = !rootExpanded;
                    drawDisclosure(dl,
                        ImVec2(dp.x + cellW * 0.5f, dp.y + rowH * 0.5f),
                        gRad, rootExpanded, txtCol);
                } else {
                    ImGui.Dummy(ImVec2(cellW, rowH));
                }
                ImGui.SameLine(0.0f, 0.0f);
            }

            // ---- Type glyph ----
            {
                immutable ImVec2 gp = ImGui.GetCursorScreenPos();
                ImGui.Dummy(ImVec2(cellW, rowH));
                drawItemGlyph(dl,
                    ImVec2(gp.x + cellW * 0.5f, gp.y + rowH * 0.5f),
                    gRad, r.glyph, txtCol);
                ImGui.SameLine(0.0f, 0.0f);
            }

            // ---- Name ----
            immutable bool renaming = !r.isRoot && rename.activeFor(r.layer);
            // The accent is for a row being READ; a row being EDITED reverts to
            // ink. The rename field sits on the pale beige FrameBg this chrome
            // pushes, and the accent orange on that is barely legible — the
            // colour that says "this is the current row" would be paid for by
            // not being able to see what you are typing.
            ImGui.PushStyleColor(ImGuiCol.Text, renaming ? inkCol : txtCol);
            if (r.isRoot) {
                // Not a Selectable: the root names the FILE, and there is no
                // scene item behind it to select, rename or reorder. Clicking
                // it does nothing, which is honest; the triangle beside it is
                // what the row is for.
                ImGui.TextUnformatted(r.name);
                nameMin = ImGui.GetItemRectMin();
                nameMax = ImGui.GetItemRectMax();
            } else if (renaming) {
                // Inline edit: Enter (or focus loss) commits, Esc cancels.
                if (ImGui.IsWindowAppearing() || !ImGui.IsAnyItemActive())
                    ImGui.SetKeyboardFocusHere();
                ImGui.SetNextItemWidth(140);
                bool commit = inputTextSubmitOnEnter("##rename", rename.buffer);
                nameMin = ImGui.GetItemRectMin();
                nameMax = ImGui.GetItemRectMax();
                bool cancel = ImGui.IsKeyPressed(ImGuiKey.Escape);
                // Commit on Enter or when the field loses focus (click away).
                if (!commit && !cancel && ImGui.IsItemDeactivatedAfterEdit())
                    commit = true;
                const exit = commit ? ItemRenameExit.commit
                    : cancel ? ItemRenameExit.cancel
                    : ImGui.IsItemDeactivated() ? ItemRenameExit.deactivate
                    : ItemRenameExit.none;
                rename.finish(exit);
            } else {
                // The name is the multi-select target, the rename opener and
                // the drag-to-reorder handle. `selected` is passed FALSE: the
                // row background above already carries selection, and letting
                // the Selectable draw its own Header colour on top would paint
                // a second, differently-sized highlight inside the first. What
                // it still contributes is HOVER feedback.
                //   plain click → `layer.select mode:set`    (exclusive
                //                 select + make primary)
                //   ctrl-click  → `layer.select mode:toggle` (add/remove this
                //                 layer from the foreground set; removing the
                //                 primary promotes another)
                bool nameClicked =
                    ImGui.Selectable(r.name, false,
                                     ImGuiSelectableFlags.AllowDoubleClick,
                                     ImVec2(0, rowH));
                nameMin = ImGui.GetItemRectMin();
                nameMax = ImGui.GetItemRectMax();
                bool dbl = ImGui.IsItemHovered()
                    && ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left);
                if (nameClicked && !dbl && actions.commandDispatch() !is null) {
                    // Ctrl comes from ImGui's frame state; Shift is the SDL-derived
                    // `shiftHeld` captured above, matching the app's modifier reads.
                    immutable mode = itemClickMode(ImGui.GetIO().KeyCtrl, shiftHeld);
                    // Plain click on a row that is already the WHOLE selection
                    // is a no-op switch; skip it so a single-select drag-press
                    // doesn't re-dispatch every frame. Task 0672: this asked
                    // `read.document().isPrimary(r.layer)` — the edit target, which
                    // after task 0671 need not be selected at all, so clicking
                    // the latched mesh's name to select it back did nothing.
                    // It is the same defect 0671 fixed in app.d's viewport
                    // click guard, and the same fix: ask about the SELECTION.
                    // Shift joins Ctrl in ALWAYS dispatching: a range from the
                    // anchor can change the selection even when the clicked
                    // row is already the whole of it (anchor above, click
                    // below), so the "already the sole selection" short-circuit
                    // would swallow exactly the click that widens it.
                    if (ImGui.GetIO().KeyCtrl || shiftHeld || !r.isSoleSelection)
                        actions.commandDispatch()("layer.select",
                            `{"index":` ~ to!string(r.index) ~ `,"mode":`
                            ~ mode ~ `}`);
                }
                if (dbl) {
                    // The RAW name, never the displayed one: seeding the
                    // editor with the "(unnamed)" placeholder means Enter
                    // renames the item to that literal, after which "no name"
                    // cannot be recovered (see `ItemRow.renameSeed`).
                    rename.begin(r.layer, r.renameSeed);
                }

                // ---- Drag-to-reorder ----
                // The label row is both a drag SOURCE (carries its own index)
                // and a drop TARGET (receives another row's index). Dropping
                // row `from` onto this row dispatches layer.reorder so the
                // dragged layer lands at THIS row's index — the others shift
                // to fill. The neutral payload type "VIBE3D_LAYER_ROW" (16
                // chars, under the 32-char d_imgui limit) tags the drag so
                // only item rows accept it.
                //
                // Addressed by `r.index`, the DOCUMENT index, which is why the
                // row model carries it: the list hides resource items and
                // prepends a root, so a row's ordinal is not its layer.
                //
                // `to`-index semantics: the layer.reorder command splices the
                // source layer OUT of the array, then splices it back IN at
                // index `to` of the POST-REMOVAL array. With `to = r.index`,
                // the dragged row always lands at the target row's index for
                // BOTH up- and down-drags (verified against the splice path in
                // commands/layer/commands.d::moveLayer and the test_layers.d
                // reorder cases: from:2 to:0 on [A,B,C] -> [C,A,B];
                // from:0 to:2 -> [B,C,A]). No from<to adjustment is needed:
                // on a down-drag the source's removal already shifts the
                // target up by one, so inserting at `r.index` lands the
                // dragged row exactly at the target's old slot.
                if (ImGui.BeginDragDropSource(ImGuiDragDropFlags.None)) {
                    int srcIdx = cast(int) r.index;
                    ImGui.SetDragDropPayload("VIBE3D_LAYER_ROW",
                                             &srcIdx, srcIdx.sizeof);
                    ImGui.Text(r.name);
                    ImGui.EndDragDropSource();
                }
                if (ImGui.BeginDragDropTarget()) {
                    const(ImGuiPayload)* payload =
                        ImGui.AcceptDragDropPayload("VIBE3D_LAYER_ROW");
                    if (payload !is null
                        && payload.Data !is null
                        && payload.DataSize == cast(int)int.sizeof) {
                        int fromIdx = *cast(const(int)*) payload.Data;
                        if (fromIdx != cast(int) r.index
                            && actions.commandDispatch() !is null)
                            actions.commandDispatch()("layer.reorder",
                                `{"from":` ~ to!string(fromIdx)
                                ~ `,"to":` ~ to!string(r.index) ~ `}`);
                    }
                    ImGui.EndDragDropTarget();
                }
            }
            recordLayerRow(r.index, r.name, r.role, r.visible,
                           eyeMin, eyeMax, roleMin, roleMax, nameMin, nameMax);
            ImGui.PopStyleColor();

            ImGui.PopID();
        }

        // ---- Layer (item) properties form ----
        // Render the config-driven layer-props form for the FOCUSED item
        // below the layer list — the same FormsPanel that drives Tool
        // Properties, fed a LayerPropsProvider wrapping it. Task 0616 Ph4
        // moved the binding from `primary` to `itemPropsTarget(read.document())`
        // (the item-selection focus): `primary` is by invariant a mesh, so
        // bound to it this form could never show a non-mesh item's channels
        // at all — an image row selected in the Images panel had its
        // `colorspace` / `useAlpha` declared as `Param`s (Stage 3) with no
        // surface that could reach them. On an all-mesh document focus and primary
        // always coincide, so nothing there changes. The form is looked up by
        // its explicit id
        // ("layer.props"); guard cleanly if it is absent (config/forms not
        // present, or VIBE3D_FORMS=0 kill-switch).
        //
        // A value edit dispatches `layer.attr <idx> <attr> <v>` (UI-undo
        // class, coalesced); the row reads the provider's live value via
        // `layer.attr … ?`. The per-item transform is non-baked — applied
        // as a display matrix at the mesh draw sites — so the mesh is never
        // re-uploaded on an edit. The transform rows grey out while a
        // transform tool is active (a mid-gesture interlock).
        {
            import forms : g_formsPanelEnabled, formById;
            if (g_formsPanelEnabled && read.document().layers.length) {
                if (auto layerForm = formById("layer.props")) {
                    ImGui.Separator();
                    auto propsTarget = itemPropsTarget(read.document());
                    immutable ImVec2 formOrigin = ImGui.GetCursorScreenPos();
                    immutable float formWidth = ImGui.GetContentRegionAvail().x;
                    immutable float formRowH = ImGui.GetFrameHeightWithSpacing()
                        - ImGui.GetStyle().ItemSpacing.y;
                    ItemFormOutcome outcome;
                    // TASK 0654 — the properties form shows NOTHING when no
                    // item is selected. The `propsTarget = read.document().primary`
                    // fallback this replaces was written when a null target was
                    // unreachable; with an empty selection the primary is null
                    // too, so it repaired nothing and only hid the case.
                    //
                    // Drawing a disabled line rather than nothing at all: the
                    // panel is a docked tab with a header, and an empty body
                    // reads as a rendering fault. The label states the reason,
                    // which is the same answer every other consumer gives.
                    if (propsTarget is null) {
                        ImGui.TextDisabled("No item selected");
                    } else {
                    // ---- TASK 1880: gang edit --------------------------
                    // Every OTHER selected item OF THE FOCUS'S KIND. The form
                    // then shows the placeholder on any row those items
                    // disagree on, and a write fans out to all of them.
                    //
                    // The KIND FILTER is the reference's stated condition —
                    // "multiple layer selections of identical item types allow
                    // for gang editing of property values" — and it is applied
                    // HERE rather than in the provider because the panel is
                    // what knows which item the form is bound to. Exact kind,
                    // not "has the same channel": a mesh and an image plane
                    // share all twelve transform components, so a channel
                    // intersection would gang-edit two rows of a selection the
                    // reference says is not gang-editable at all.
                    //
                    // Rebuilt per frame from the live selection, so it cannot
                    // go stale — and it is empty in the ordinary one-item case,
                    // where `setGangTargets` early-outs and every widget
                    // behaves exactly as it did before this task.
                        const(Layer)[] gang;
                        foreach (l; read.document().layers)
                            if (l !is null && l.selected && l !is propsTarget
                                && l.kind == propsTarget.kind)
                                gang ~= l;
                        outcome = actions.drawItemForm(*layerForm, propsTarget,
                            gang, read.transformToolActive(),
                            read.currentSelType());
                    }   // task 0654: end of the has-a-target arm
                    recordLayerForm(outcome.targetIndex,
                        outcome.transformGuardArmed, outcome.bound,
                        formOrigin, formWidth, formRowH);
                }
            }
        }

        // ---- Image-plane clip picker (task 0612 Stage 7) ----
        //
        // OUTSIDE the forms block on purpose, and computing its own bound
        // item: the link is the one piece of a plane's state that cannot ride
        // the generic form (a `Param` is a typed pointer to a scalar; a link
        // names a `Layer` OBJECT), so gating it on `g_formsPanelEnabled` /
        // `formById("layer.props")` would make the only way to give a plane
        // an image disappear with the config file.
        //
        // WHAT IS DRAWN here and what is DECIDED elsewhere: every assertable
        // thing about this picker — which rows it offers, what each row is
        // labelled, which row is marked, and above all the `Document.layers`
        // index each row dispatches — is `image_plane.d`'s
        // `planeImageChoices`, behind in-module tests. An ImGui body cannot
        // be driven headlessly, so what is left here is the loop and the
        // dispatch, following `ui/image_rows.d`'s split exactly.
        {
            import image_plane : planeImageChoices, imagePlaneSource,
                                 ImagePlaneSource;
            auto planeTarget = itemPropsTarget(read.document());
            if (planeTarget !is null && planeTarget.hasImagePlane) {
                ImGui.Separator();
                auto choices = planeImageChoices(*read.document(), planeTarget);
                string preview = "(none)";
                foreach (ref e; choices) if (e.current) preview = e.label;
                immutable planeIdx = read.document().indexOf(planeTarget);
                ImGui.SetNextItemWidth(160);
                if (ImGui.BeginCombo("Image", preview)) {
                    foreach (ref e; choices) {
                        // PushID on the LAYER INDEX, not the loop counter: two
                        // clips may legitimately share a display name (the
                        // list renames the row, never the file), and two
                        // identically-labelled Selectables in one combo share
                        // an ImGui id — clicking either would activate the
                        // first.
                        ImGui.PushID(e.layerIndex);
                        if (ImGui.Selectable(e.label, e.current) && !e.current
                            && actions.commandDispatch() !is null)
                            actions.commandDispatch()("imagePlane.setImage",
                                `{"index":` ~ to!string(planeIdx)
                                ~ `,"image":` ~ to!string(e.layerIndex) ~ `}`);
                        if (e.current) ImGui.SetItemDefaultFocus();
                        ImGui.PopID();
                    }
                    ImGui.EndCombo();
                }
                // The source state in words. A plane whose link is broken
                // draws NOTHING in the viewport (a declared divergence — we
                // have no item glyph), so without this line the user's only
                // evidence is an empty viewport, which reads the same for
                // "wrong projection", "hidden" and "the file is gone".
                immutable src = imagePlaneSource(*read.document(), planeTarget);
                final switch (src) {
                    case ImagePlaneSource.Unbound:
                        ImGui.TextDisabled("%s", "no image"); break;
                    case ImagePlaneSource.Dangling:
                        ImGui.TextDisabled("%s", "image removed"); break;
                    case ImagePlaneSource.Missing:
                        ImGui.TextDisabled("%s", "file not found"); break;
                    case ImagePlaneSource.Ready:
                        if (!planeTarget.visible)
                            ImGui.TextDisabled("%s", "hidden");
                        break;
                }
            }
        }
    }
}
