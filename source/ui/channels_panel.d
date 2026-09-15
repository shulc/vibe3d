module ui.channels_panel;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import application_command_binding : ApplicationCommandBinding;
import document : Document;
import forms : Form;
import forms_render : FormsPanel;
import mesh : Mesh;
import seltype : SelType;
import session_owner : Session;
import tool : Tool;
import ui.channel_rows : ChannelsProvider;
import ui.panel_chrome : popPanelChromeStyle, pushPanelChromeStyle;

// ---------------------------------------------------------------------------
// Channels panel (tasks 0637, 6050) — EVERY channel of the focused item,
// uncurated, plus the read-only Vertex Maps list of the edit mesh.
//
// CONTRACT. The panel reads the document, the selection type, the active tool
// and the edit mesh only through `ChannelsReadRole`, asked afresh during each
// draw, and writes only through `ChannelsActions.drawChannelForm`, which hands
// the synthesised form to the shared `FormsPanel` with the application
// binding's interactive dispatch. It holds no Document, primary or Tool
// between frames: the two function-local statics below are a memo keyed on the
// live focus item, index and parameter count, re-validated on every draw; the
// key has no name term, so a rename leaves the title stale until the focus
// changes. The Vertex Maps marker reads the
// module-owned `morphTargetName()` directly during that draw.
//
// It binds the item-selection FOCUS (`itemPropsTarget`), never the primary —
// an image plane can never be the primary. Which rows exist, their labels,
// their `layer.attr` targets and their greying are `ui/channel_rows.d`; this
// body draws the header, drives the memo and makes the one form call.
//
// Every write is `layer.attr <index> <attr> <value>` through the interactive
// dispatch, so undo class, coalescing and publication are the command's; the
// panel never mutates the document. Not gated on `g_formsPanelEnabled`: the
// form is synthesised from `params()`, not loaded from config/forms.
//
// Decision history: doc/channels_panel_history.md.
// ---------------------------------------------------------------------------

struct ChannelsReadRole {
private:
    Session* owner_;
    Tool delegate() activeTool_;
public:
    @disable this();
    this(Session* owner, Tool delegate() activeTool) {
        assert(owner !is null && activeTool !is null);
        owner_ = owner;
        activeTool_ = activeTool;
    }
    Document* document() { return owner_.documentPtr(); }
    SelType currentSelType() {
        import seltype : resolve = currentSelType;
        return resolve(owner_.selTypeOrder);
    }
    bool transformToolActive() {
        import tools.transform.transform : TransformTool;
        return (cast(TransformTool) activeTool_()) !is null;
    }
    const(Mesh)* editMesh() { return &owner_.editMesh(); }
}

struct ChannelsActions {
private:
    void delegate(string, string) interactive_;
    FormsPanel forms_;
public:
    @disable this();
    this(void delegate(string, string) interactive, FormsPanel forms) {
        assert(interactive !is null && forms !is null);
        interactive_ = interactive;
        forms_ = forms;
    }
    void drawChannelForm(ref Form form, ChannelsProvider provider) {
        forms_.draw(form, provider, null, interactive_,
                    /*activeToolId=*/"", /*stageId=*/"", /*layerIndex=*/"");
    }
}

struct ChannelsPanelRoles {
    ChannelsReadRole read;
    ChannelsActions actions;
}

ChannelsPanelRoles bindChannelsPanel(Session* owner,
        ApplicationCommandBinding binding, FormsPanel forms,
        Tool delegate() activeTool) {
    assert(binding !is null && forms !is null);
    return ChannelsPanelRoles(ChannelsReadRole(owner, activeTool),
        ChannelsActions(&binding.dispatchInteractiveUi, forms));
}

version (unittest) {
    struct ChannelsDrawSnapshot {
        bool drawn;
        bool bound;
        string title;
        string kindText;
        bool providerMatchesModel;
        bool transformGuardArmed;
        bool formDrawn;
        ImVec2 lastRowMin, lastRowMax;
        bool mapsHeaderDrawn;
        bool mapsOpen;
        ImVec2 mapsHeaderMin, mapsHeaderMax;
        string[] mapLines;
    }
    private __gshared ChannelsDrawSnapshot g_channelsDrawSnapshot;
    ChannelsDrawSnapshot channelsDrawSnapshot() {
        return g_channelsDrawSnapshot;
    }
    void resetChannelsDrawSnapshot() {
        g_channelsDrawSnapshot = ChannelsDrawSnapshot.init;
    }
    private void recordChannelsBegin() {
        resetChannelsDrawSnapshot();
        g_channelsDrawSnapshot.drawn = true;
    }
    private void recordChannelsHeader(string title, string kindText) {
        g_channelsDrawSnapshot.bound = true;
        g_channelsDrawSnapshot.title = title;
        g_channelsDrawSnapshot.kindText = kindText;
    }
    private void recordChannelsProvider(bool matches) {
        g_channelsDrawSnapshot.providerMatchesModel = matches;
    }
    private void recordChannelsGuard(bool armed) {
        g_channelsDrawSnapshot.transformGuardArmed = armed;
    }
    private void recordChannelsForm() {
        g_channelsDrawSnapshot.formDrawn = true;
        g_channelsDrawSnapshot.lastRowMin = ImGui.GetItemRectMin();
        g_channelsDrawSnapshot.lastRowMax = ImGui.GetItemRectMax();
    }
    private void recordVertexMapsHeader(bool open) {
        g_channelsDrawSnapshot.mapsHeaderDrawn = true;
        g_channelsDrawSnapshot.mapsOpen = open;
        g_channelsDrawSnapshot.mapsHeaderMin = ImGui.GetItemRectMin();
        g_channelsDrawSnapshot.mapsHeaderMax = ImGui.GetItemRectMax();
    }
    private void recordVertexMapLine(string line) {
        g_channelsDrawSnapshot.mapLines ~= line;
    }
} else {
    private void recordChannelsBegin() {}
    private void recordChannelsHeader(string, string) {}
    private void recordChannelsProvider(bool) {}
    private void recordChannelsGuard(bool) {}
    private void recordChannelsForm() {}
    private void recordVertexMapsHeader(bool) {}
    private void recordVertexMapLine(string) {}
}

private void drawVertexMapLine(string line) {
    recordVertexMapLine(line);
    ImGui.TextUnformatted(line);
}

void drawChannelsPanel(ChannelsReadRole read, ChannelsActions actions) {
    import ui.channel_rows : ChannelsKey, ChannelsModel, ChannelsProvider,
                             channelsModel, kNoItemText;
    import layer_params    : itemPropsTarget;

    // Cached across frames: the provider (so its blocked set is not rebuilt per
    // frame) and the built rows (so 24 command strings are not rebuilt per
    // frame). Function-local statics rather than application-context fields —
    // nothing outside this body reads them and the panel is main-thread-only,
    // the same convention the Images panel's confirm state uses.
    static ChannelsProvider prov;
    static ChannelsModel    model;

    // BALANCED ON EVERY EXIT, INCLUDING A THROWN ONE: the action role's
    // interactive delegate routes through `applyOrRefire`, and a refused
    // `layer.attr` (a readonly attr, an out-of-domain value) throws from inside
    // the draw. `scope(exit)` keeps ImGui's window and style stacks from being
    // left one deep, whose symptom would otherwise surface a frame later with
    // no connection to the throw.
    pushPanelChromeStyle();
    scope(exit) popPanelChromeStyle();
    scope(exit) ImGui.End();
    if (ImGui.Begin("Channels")) {
        recordChannelsBegin();
        // Binds the item-selection FOCUS, never `document.primary` — an image
        // plane can never BE the primary, so a primary-bound panel would show
        // none of the channels this one exists for. Reached through the shared
        // `itemPropsTarget` so this surface and the properties form can never
        // disagree about which item is being edited.
        auto item = itemPropsTarget(read.document());
        if (item is null) {
            ImGui.TextDisabled("%s", kNoItemText);
        } else {
            // Rebuild only on a key change (see `ChannelsModel.key`). A focus
            // move rebinds from scratch; otherwise the one per-frame `params()`
            // — the same allocation the renderer's own snapshot makes — catches
            // an index shift or a payload appearing on an item that had none.
            if (prov is null || model.key.item !is item) {
                prov  = new ChannelsProvider(item);
                model = channelsModel(read.document());
            } else {
                auto k = ChannelsKey(item, read.document().indexOf(item),
                                     prov.params().length);
                if (k != model.key) {
                    prov.rebind(item);
                    model = channelsModel(read.document());
                }
            }
            recordChannelsProvider(prov.base.layer() is model.key.item);

            // Header: whose channels these are. `%s` rather than passing the
            // name as the format string — it is user text (same reason the
            // Layers panel's kind badge does).
            ImGui.TextUnformatted(model.title);
            ImGui.SameLine();
            ImGui.TextDisabled("%s", model.kindText);
            ImGui.Separator();
            recordChannelsHeader(model.title, model.kindText);

            // The base provider's own mid-gesture transform interlock, driven
            // exactly as the Layers panel drives it: while a transform tool is
            // up over a GEOMETRY selection, the item transform is a second,
            // invisible writer and its rows grey out. Under `SelType.Item` the
            // gizmo's only write target IS these rows, so it must not arm —
            // the narrowing lives in `setTransformGuard`, read live from the
            // authority rather than cached.
            prov.base.setTransformGuard(read.transformToolActive(),
                                        read.currentSelType());
            recordChannelsGuard(!prov.paramEnabled("pos.x"));

            // The SAME renderer the properties form uses, so a row here is
            // resolved, drawn and written back by exactly one implementation.
            // `layerIndex` is empty on purpose: these lines were synthesised
            // with the live index already in them, so there is nothing for
            // `rebindBindingTarget` to overwrite.
            actions.drawChannelForm(model.form, prov);
            recordChannelsForm();
        }

        // ---- Vertex Maps (task 1069) -------------------------------------
        //
        // Unconditional, and the reason is not completeness: it is the ONLY
        // place two silent behaviours become visible.
        //
        //   * A morph map does not survive a mesh-REPLACING kernel
        //     (subdivide / remesh / import). That is consistent with what
        //     already happens to uv and weight maps rather than a new
        //     regression, but a hand-authored morph is a far worse thing to
        //     lose silently than a UV. Watching the entry count go to zero is
        //     how a user finds out.
        //   * With a target BOUND, twelve registered tools still edit the
        //     BASE — deliberately (registry rows 47a-47l). Showing which map
        //     is bound is what stops "I pushed and my morph did nothing" from
        //     being a mystery.
        //
        // Lives inside this panel rather than in a new dock window on
        // purpose: a new window would need DockBuilder wiring and would
        // perturb every saved layout, and `imgui.ini` determinism is load
        // bearing for the test suite.
        drawVertexMapsSection(read.editMesh());
    }
    // `ImGui.End()` + `popPanelChromeStyle()` are the two `scope(exit)`s
    // registered above.
}

/// The Vertex Maps list: every morph map with its kind and entry count, the
/// routing target marked. Read-only — creation / removal / selection go
/// through the `mesh.morph.*` commands, which are what undo records.
private void drawVertexMapsSection(const(Mesh)* m) {
    import std.format  : format;
    import mesh        : isMorphKind, MapKind;
    import morph_target : morphTargetName;

    if (m is null) return;
    bool anyMorph = false;
    foreach (ref mm; m.meshMaps)
        if (isMorphKind(mm.kind)) { anyMorph = true; break; }
    if (!anyMorph) return;              // no morph maps ⇒ no section at all

    const bool mapsOpen = ImGui.CollapsingHeader("Vertex Maps");
    recordVertexMapsHeader(mapsOpen);
    if (!mapsOpen) return;
    const string bound = morphTargetName();
    foreach (ref mm; m.meshMaps) {
        if (!isMorphKind(mm.kind)) continue;
        const bool isTarget = (bound.length > 0 && bound == mm.name);
        size_t entries = 0;
        const size_t n = mm.data.length / 3;
        foreach (i; 0 .. n) if (mm.isPresent(i)) ++entries;
        // The kind is spelled out rather than abbreviated: the two differ in
        // what an ABSENT entry means, which is the one thing a user reading
        // an entry count needs to know.
        drawVertexMapLine(format("%s%s  [%s]  %d/%d",
            isTarget ? "> " : "  ",
            mm.name,
            mm.kind == MapKind.morphRelative ? "relative" : "absolute",
            entries, n));
    }
    if (bound.length == 0)
        drawVertexMapLine("no target bound - edits go to the base");
}
