module ui.image_list_panel;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import application_command_binding : ApplicationCommandBinding;
import document : Document;
import imgui_flag_boundary : inputTextSubmitOnEnter;
import session_owner : Session;
import ui.image_rows : ImageRow, elidedPathText, imageRemoveConfirmText,
    imageRemoveTarget, imageRowsInto, kNoImagesText;
import ui.item_rename : ItemRenameDispatch, ItemRenameExit, ItemRenameState,
    bindItemRenameController;
import ui.panel_chrome : popPanelChromeStyle, pushPanelChromeStyle;

// CONTRACT (task 6040). This module places the Images list; `ui.image_rows`
// decides which rows exist, their document indices, text, the Remove target
// and the confirm sentence. The read role is consulted during each draw and
// caches no Document, row or index between frames.
//
// Every row and button addresses the DOCUMENT index `ImageRow.index`, never
// the row ordinal: image items are interleaved with scene items.
//   Load...        -> image.load {}            (no path: the chooser)
//   Remove         -> image.remove {index}     (direct, or after the confirm)
//   marker / name  -> layer.select {index, set|toggle}
//   double-click   -> the shared ItemRenameState -> layer.rename {index, name}
// The rename state is the one application owner also passed to the Items
// panel; this module never creates a second one. All writes go through the
// action role; the panel never mutates the document directly.
// `removeConfirmIndex` and `ItemRenameState.index` retain the click-time
// document index across frames; identity-addressing is backlog 6203.
// Decision history: doc/image_list_panel_history.md.

struct ImageListReadRole {
private:
    Session* owner_;
public:
    @disable this();
    this(Session* owner) {
        assert(owner !is null);
        owner_ = owner;
    }
    Document* document() { return owner_.documentPtr(); }
}

struct ImageListActions {
private:
    ItemRenameDispatch dispatch_;
public:
    @disable this();
    this(ItemRenameDispatch dispatch) {
        assert(dispatch !is null);
        dispatch_ = dispatch;
    }
    ItemRenameDispatch commandDispatch() { return dispatch_; }
}

struct ImageListPanelRoles {
    ImageListReadRole read;
    ImageListActions actions;
}

ImageListPanelRoles bindImageListPanel(Session* owner,
        ApplicationCommandBinding binding) {
    assert(binding !is null);
    return ImageListPanelRoles(ImageListReadRole(owner),
        ImageListActions(&binding.dispatchUi));
}

version (unittest) {
    struct ImageListDrawnRow {
        size_t index;
        string name;
        bool focused, selected, renaming;
        ImVec2 markerMin, markerMax, nameMin, nameMax;
    }
    struct ImageListDrawSnapshot {
        bool drawn;
        ImageListDrawnRow[] rows;
        ImVec2 loadMin, loadMax, removeMin, removeMax;
        bool removeEnabled;
        size_t removeIndex;
        bool confirmDrawn;
        string confirmText;
        size_t confirmIndex;
        ImVec2 confirmMin, confirmMax;
    }
    private __gshared ImageListDrawSnapshot g_imageListDrawSnapshot;
    ImageListDrawSnapshot imageListDrawSnapshot() {
        return g_imageListDrawSnapshot;
    }
    void resetImageListDrawSnapshot() {
        g_imageListDrawSnapshot = ImageListDrawSnapshot.init;
    }
    private void beginImageListDraw() {
        resetImageListDrawSnapshot();
        g_imageListDrawSnapshot.drawn = true;
    }
    private void recordImageLoad() {
        g_imageListDrawSnapshot.loadMin = ImGui.GetItemRectMin();
        g_imageListDrawSnapshot.loadMax = ImGui.GetItemRectMax();
    }
    private void recordImageRemove(bool enabled, size_t index) {
        g_imageListDrawSnapshot.removeEnabled = enabled;
        g_imageListDrawSnapshot.removeIndex = index;
        g_imageListDrawSnapshot.removeMin = ImGui.GetItemRectMin();
        g_imageListDrawSnapshot.removeMax = ImGui.GetItemRectMax();
    }
    private void recordImageConfirm(string text, size_t index) {
        g_imageListDrawSnapshot.confirmDrawn = true;
        g_imageListDrawSnapshot.confirmText = text;
        g_imageListDrawSnapshot.confirmIndex = index;
        g_imageListDrawSnapshot.confirmMin = ImGui.GetItemRectMin();
        g_imageListDrawSnapshot.confirmMax = ImGui.GetItemRectMax();
    }
    private void recordImageMarker(size_t index, string name, bool focused,
                                   bool selected) {
        ImageListDrawnRow row;
        row.index = index;
        row.name = name;
        row.focused = focused;
        row.selected = selected;
        row.markerMin = ImGui.GetItemRectMin();
        row.markerMax = ImGui.GetItemRectMax();
        g_imageListDrawSnapshot.rows ~= row;
    }
    private void recordImageName(bool renaming) {
        auto row = &g_imageListDrawSnapshot.rows[$ - 1];
        row.renaming = renaming;
        row.nameMin = ImGui.GetItemRectMin();
        row.nameMax = ImGui.GetItemRectMax();
    }
} else {
    private void beginImageListDraw() {}
    private void recordImageLoad() {}
    private void recordImageRemove(bool, size_t) {}
    private void recordImageConfirm(string, size_t) {}
    private void recordImageMarker(size_t, string, bool, bool) {}
    private void recordImageName(bool) {}
}

void drawImageListPanel(ImageListReadRole read, ImageListActions actions,
                        ref ItemRenameState itemRenameState) {
    import std.json : JSONValue;
    import std.conv : to;
    import io.doc_state : currentDocPath;

    auto dispatch = actions.commandDispatch();
    auto rename = bindItemRenameController(itemRenameState, dispatch);

    // Confirm-before-remove state. Function-local statics rather than
    // EditorApp fields: nothing outside this body reads them, and the panel is
    // main-thread-only (same convention as the AI3D modal flags in
    // `ui/panels.d`, which are app fields because the side-panel menu shares them).
    static bool   removeConfirmOpen;
    static bool   removeConfirmPendingOpen;
    static string removeConfirmText;
    static size_t removeConfirmIndex;

    // BALANCED ON EVERY EXIT, INCLUDING A THROWN ONE (review S3). `ImGui.End`
    // and the style pop are not optional cleanup — ImGui keeps a window stack
    // and a style stack, and an unwound frame that skipped either leaves both
    // one deep. The symptom then appears on the NEXT frame, as an assertion
    // inside ImGui with no connection to the code that threw.
    //
    // There ARE throwing calls on this path, which is what makes this real
    // rather than defensive: a UI refusal is a notice, not a throw, but
    // `ApplicationCommandBinding.invokeLine` still throws on an unknown id or
    // malformed arguments, and the row model touches user-supplied paths
    // (see `elideEnd`).
    // `scope(exit)` runs on all three of return, fall-through and unwind.
    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    scope(exit) ImGui.End();
    if (ImGui.Begin("Images")) {
        beginImageListDraw();
        // ---- Load button ----
        // No `path` argument: `image.load` with none opens the file dialog,
        // which is the only route the reference offers either (its load
        // command takes no arguments at all — measured). The by-path form
        // exists for tests and scripts and is reached through /api/command.
        immutable loadPressed = ImGui.SmallButton("Load...");
        recordImageLoad();
        if (loadPressed) {
            dispatch("image.load", "{}");
        }
        ImGui.SameLine();

        // ---- Remove button ----
        // Target + enabled state come from ONE function (`imageRemoveTarget`),
        // in the `layerDeleteButtonState` shape, so the greying and the
        // dispatched index cannot disagree — the bug that shape exists to
        // prevent.
        auto rem = imageRemoveTarget(read.document());
        // Braced so the `scope(exit)` ends the disabled state HERE and not at
        // the end of the whole panel. A UI refusal is only a notice; the
        // balance still covers malformed arguments and an unknown command id.
        {
            ImGui.BeginDisabled(!rem.enabled);
            scope(exit) ImGui.EndDisabled();
            immutable removePressed = ImGui.SmallButton("Remove");
            recordImageRemove(rem.enabled, rem.index);
            if (removePressed) {
                if (rem.enabled) {
                    // CLICK TIME is the only place the reverse referrer sweep
                    // may run: `Document.referrersOf` explicitly forbids a
                    // draw-path call, and this is the delete-time query it was
                    // written for.
                    removeConfirmText  = imageRemoveConfirmText(read.document(),
                                                                rem.layer);
                    removeConfirmIndex = rem.index;
                    if (removeConfirmText.length) {
                        removeConfirmOpen        = true;
                        removeConfirmPendingOpen = true;
                    } else {
                        // Nothing references it — nothing to warn about.
                        dispatch("image.remove",
                            `{"index":` ~ to!string(rem.index) ~ `}`);
                    }
                }
            }
        }

        // ---- In-use confirmation ----
        // Same pendingOpen convention as the AI3D modals in `ui/panels.d`.
        if (removeConfirmOpen) {
            if (removeConfirmPendingOpen) {
                ImGui.OpenPopup("Remove Image?");
                removeConfirmPendingOpen = false;
            }
            if (ImGui.BeginPopupModal("Remove Image?", null,
                                      ImGuiWindowFlags.AlwaysAutoResize)) {
                // Balanced on unwind if command construction or argument
                // binding throws; a normal UI refusal is reported as a notice.
                scope(exit) ImGui.EndPopup();
                ImGui.TextUnformatted(removeConfirmText);
                ImGui.TextUnformatted("Remove it anyway?");
                immutable confirmPressed = ImGui.Button("Remove");
                recordImageConfirm(removeConfirmText, removeConfirmIndex);
                if (confirmPressed) {
                    dispatch("image.remove",
                        `{"index":` ~ to!string(removeConfirmIndex) ~ `}`);
                    ImGui.CloseCurrentPopup();
                    removeConfirmOpen = false;
                }
                ImGui.SameLine();
                if (ImGui.Button("Cancel")) {
                    ImGui.CloseCurrentPopup();
                    removeConfirmOpen = false;
                }
            } else {
                removeConfirmOpen = false;   // closed via ESC
            }
        }

        ImGui.Separator();

        // ---- Rows ----
        // ONE buffer, refilled in place each frame (the `referrersOf` /
        // `selectedItemsInto` idiom) rather than a fresh array per frame.
        static ImageRow[] rows;
        imageRowsInto(read.document(), currentDocPath(), rows);

        if (rows.length == 0) {
            // The measured list has its own empty text rather than an empty
            // rectangle.
            ImGui.TextDisabled(kNoImagesText);
        }

        foreach (ref r; rows) {
            immutable int idx = cast(int) r.index;
            ImGui.PushID(idx);
            // Per-ITERATION (a `scope(exit)` in a loop body runs at the end of
            // each pass), and balanced on unwind for the same reason as the
            // window above: this body dispatches commands that throw.
            scope(exit) ImGui.PopID();

            // ---- line 1: focus marker + name + dimensions + format ----
            // The marker is the same three-state glyph the Layers panel uses
            // ("@" focus, "*" in the selection set, " " neither); ">" cannot
            // occur here because an image item is never the mesh edit target.
            immutable marker = r.focused ? "@" : r.selected ? "*" : " ";
            immutable markerClicked = ImGui.Selectable(marker, r.focused,
                                 ImGuiSelectableFlags.AllowItemOverlap,
                                 ImVec2(14, 0));
            recordImageMarker(r.index, r.name, r.focused, r.selected);
            if (markerClicked) {
                if (!r.focused)
                    dispatch("layer.select",
                        `{"index":` ~ to!string(idx) ~ `,"mode":"set"}`);
            }
            ImGui.SameLine();

            if (rename.activeFor(r.index)) {
                // Inline rename — `layer.rename`, which writes the item's
                // display name and NOTHING on disk. There is deliberately no
                // `image.rename`: a second command would be a second way to
                // get this wrong, and the reference's own list renames the
                // reference and never the file either.
                if (ImGui.IsWindowAppearing() || !ImGui.IsAnyItemActive())
                    ImGui.SetKeyboardFocusHere();
                ImGui.SetNextItemWidth(140);
                bool commit = inputTextSubmitOnEnter("##rename", rename.buffer);
                recordImageName(true);
                bool cancel = ImGui.IsKeyPressed(ImGuiKey.Escape);
                if (!commit && !cancel && ImGui.IsItemDeactivatedAfterEdit())
                    commit = true;
                const exit = commit ? ItemRenameExit.commit
                    : cancel ? ItemRenameExit.cancel
                    : ImGui.IsItemDeactivated() ? ItemRenameExit.deactivate
                    : ItemRenameExit.none;
                rename.finish(r.index, exit);
            } else {
                // Multi-select: plain click replaces the selection
                // (`mode:set`), ctrl-click adds/removes (`mode:toggle`).
                // Double-click opens the rename editor.
                bool nameClicked =
                    ImGui.Selectable(r.name, r.selected,
                                     ImGuiSelectableFlags.AllowDoubleClick,
                                     ImVec2(180, 0));
                recordImageName(false);
                bool dbl = ImGui.IsItemHovered()
                    && ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left);
                if (nameClicked && !dbl) {
                    immutable mode = ImGui.GetIO().KeyCtrl ? `"toggle"` : `"set"`;
                    if (ImGui.GetIO().KeyCtrl || !r.focused)
                        dispatch("layer.select",
                            `{"index":` ~ to!string(idx) ~ `,"mode":`
                            ~ mode ~ `}`);
                }
                if (dbl) {
                    // `renameSeed`, not `name` (review S5). `name` is what the
                    // row DRAWS, and for an unnamed item that is the literal
                    // "(unnamed)" placeholder — seeding the editor with it
                    // means pressing Enter renames the layer TO the
                    // placeholder, and the Layers panel (which reads the raw
                    // field) then shows an item genuinely called "(unnamed)".
                    // The two fields exist separately so a test can see the
                    // difference; see `ui/image_rows.d`.
                    rename.begin(r.index, r.renameSeed);
                }
            }

            // Pixel dimensions, then pixel format — each its own column, both
            // read-only labels, drawn through `TextUnformatted`, which takes
            // no format string at all (see the note on the path line below for
            // what "the single-string overload" means in THIS binding).
            //
            // The two offsets are wide enough for the widest cell either
            // column can hold: `MAX_IMAGE_DIM` is 16384, so "16384 x 16384"
            // (13 characters) is the dimensions column's worst case, and the
            // format column must start clear of it. Measured on screen at the
            // first cut with 200/280, where "1024 x 1024" ran straight into
            // "RGB".
            ImGui.SameLine(210);
            ImGui.TextUnformatted(r.dimensions.length ? r.dimensions : "-");
            ImGui.SameLine(330);
            ImGui.TextUnformatted(r.pixelFormat.length ? r.pixelFormat : "-");

            // ---- line 2: the path, dimmer, elided from the RIGHT ----
            // The budget is in code points, derived from the width actually
            // available, so the head of the path survives a narrow panel.
            // (`Dummy` + `SameLine` rather than `Indent`: this build's ImGui
            // binding exposes no Indent/Unindent wrapper.)
            ImGui.Dummy(ImVec2(18, 0));
            ImGui.SameLine();
            {
                immutable float avail = ImGui.GetContentRegionAvail().x;
                immutable float chW   = ImGui.CalcTextSize("m").x;
                size_t budget = 16;
                if (chW > 0.0f && avail > 0.0f) {
                    immutable long b = cast(long)(avail / chW);
                    budget = b < 8 ? 8 : cast(size_t) b;
                }
                // WHY A USER'S PATH IS SAFE TO PASS DIRECTLY HERE — stated
                // precisely, because "TextDisabled is printf-style" is true of
                // the upstream C++ API and NOT of the binding this build links
                // (review B2 was raised against the wrong package).
                //
                // `dub.selections.json` resolves `d_imgui` to the cimgui shim,
                // whose `source/d_imgui/package.d` declares:
                //
                //     void TextDisabled(string s)  { igTextDisabled("%.*s", cast(int) s.length, s.ptr); }
                //     void SetTooltip(string s)    { igSetTooltip  ("%.*s", cast(int) s.length, s.ptr); }
                //
                // — non-template, exactly one string parameter, and the format
                // string is the binding's own literal. `elidedPathText(...)`
                // and `pathTooltip` are ARGUMENTS to `%.*s`, never the format,
                // so a path holding `%20i` or `%s` (a browser download, a shell
                // artefact) is drawn literally. The printf-style overloads in
                // this binding all take an explicit format PLUS typed args
                // (`(string fmt, string)`, `(string fmt, int)`, `(string fmt,
                // int, int)`) and cannot be selected by a single argument.
                //
                // If the binding is ever swapped for one whose only overload is
                // a variadic `(string fmt, A...)`, these two calls become the
                // crash — so the swap must re-check this block. That is also
                // why the columns above use `TextUnformatted`, which has no
                // format-string form to regress into under any binding.
                //
                // `elidedPathText`, not `elideEnd`: the cut is memoised on the
                // item, keyed on (this row's text, this budget). It is a cache
                // in front of `elideEnd` and returns exactly what it returns —
                // the only difference is that a frame in which neither the
                // path nor the panel's width moved does not allocate. The
                // budget above is the second key; it changes on a RESIZE and
                // at no other time, which is what makes the memo worth having
                // (task 0635 — and see that function for why the earlier "this
                // costs nothing" measurement was reading a call nobody made).
                if (r.pathText.length)
                    ImGui.TextDisabled(elidedPathText(r, budget));
                else
                    ImGui.TextDisabled("(no file)");
                // The tooltip is always the ABSOLUTE path — measured: relative
                // in the row, absolute on hover.
                if (ImGui.IsItemHovered() && r.pathTooltip.length)
                    ImGui.SetTooltip(r.pathTooltip);
                if (r.missing) {
                    ImGui.SameLine();
                    ImGui.TextDisabled("(not found)");
                }
            }
        }
    }
    // `ImGui.End()` + `popPanelChromeStyle()` are the two `scope(exit)`s
    // registered at the top of this function — see the note there for why they
    // are not plain statements here.
}
