module ui.channels_panel;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import application_command_binding : ApplicationCommandBinding;
import document : Document, Layer;
import forms : Form;
import forms_render : FormsPanel;
import mesh : Mesh;
import seltype : SelType;
import session_owner : Session;
import tool : Tool;
import ui.channel_rows : ChannelsKey, ChannelsModel, ChannelsProvider,
                         channelsModel;
import ui.panel_chrome : popPanelChromeStyle, pushPanelChromeStyle;
import ui.retained_item : ConstItem;

// ---------------------------------------------------------------------------
// Channels panel (tasks 0637, 6050, 6358) — EVERY channel of the focused item,
// uncurated, plus the read-only Vertex Maps list of the edit mesh.
//
// CONTRACT. The panel reads the document, the selection type, the active tool
// and the edit mesh only through `ChannelsReadRole`, asked afresh during each
// draw, and writes only through `ChannelsActions.drawChannelForm`, which hands
// the synthesised form to the shared `FormsPanel` with the application
// binding's interactive dispatch. It holds no Document, primary or Tool
// between frames. Its only retained state is the binding's own
// `ChannelsPanelState`: a row memo keyed on the live focus identity, index and
// parameter count, re-validated on every visible draw and emptied, before
// `Begin`, on every call whose focus is not the memoised item — so a hidden
// tab never keeps a replaced document alive. The header NAME is not memoised;
// it is read from the focus item on every draw. The Vertex Maps marker reads
// the module-owned `morphTargetName()` directly during that draw.
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
    const(Document)* document() { return owner_.documentPtr(); }
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

/// How the binding turns a read-only identity into the writable item its
/// provider needs: a lookup in the live document, never a cast (task 6503).
alias ChannelsItemResolve = Layer delegate(const(Layer) id);

/// The one place an identity becomes the item, and the only write capability
/// the memo holds. A `Session*` field would be wider than this question.
private Layer liveItem(Session* owner, const(Layer) id) {
    if (owner is null || id is null) return null;
    auto doc = owner.documentPtr();
    const i = doc.indexOf(id);
    return i == doc.layers.length ? null : doc.layers[i];
}

/// The panel's retained memo, owned by ONE binding: `bindChannelsPanel` is the
/// only constructor call, so two bindings never share rows or a provider.
final class ChannelsPanelState {
private:
    ChannelsProvider    provider_;
    ChannelsModel       model_;
    ChannelsItemResolve resolve_;

    this(ChannelsItemResolve resolve) {
        assert(resolve !is null);
        resolve_ = resolve;
    }

    /// Keep the memo only while it describes `item`; a null or different
    /// focus empties it. Runs on every draw call, visible or not.
    void retainOnly(const(Layer) item) {
        if (model_.key.item is item) return;
        provider_ = null;
        model_    = ChannelsModel.init;
    }

    /// Rebuild on a key miss (item, index, parameter count); true when rebuilt.
    bool refresh(const(Document)* doc, const(Layer) item) {
        if (provider_ !is null) {
            const k = ChannelsKey(ConstItem(item), doc.indexOf(item),
                                  provider_.params().length);
            if (k == model_.key) return false;
            auto live = resolve_(item);
            if (live is null) return dropMemo();
            provider_.rebind(live);
        } else {
            auto live = resolve_(item);
            if (live is null) return dropMemo();
            provider_ = new ChannelsProvider(live);
        }
        model_ = channelsModel(doc, item, provider_.params());
        return true;
    }

    /// Defensive stale-identity arm: leave no half-bound memo behind. The
    /// three narrow doors below and the unittest disabled-row recorder are
    /// null-safe; the shared renderer also returns on a null provider.
    bool dropMemo() {
        provider_ = null;
        model_ = ChannelsModel.init;
        return false;
    }

    /// Does this memo's provider describe the item the model names?
    bool providerMatchesModel() const {
        return provider_ !is null && provider_.boundItem() is model_.key.item;
    }

    /// The base provider's interlock, driven live from the read authority.
    void armTransformGuard(bool toolActive, SelType current) {
        if (provider_ !is null) provider_.setTransformGuard(toolActive, current);
    }

    /// Is the 12-row item transform greyed right now?
    bool transformGuardArmed() const {
        return provider_ !is null && !provider_.paramEnabled("pos.x");
    }
}

struct ChannelsPanelRoles {
    ChannelsReadRole read;
    ChannelsActions actions;
    ChannelsPanelState state;
}

ChannelsPanelRoles bindChannelsPanel(Session* owner,
        ApplicationCommandBinding binding, FormsPanel forms,
        Tool delegate() activeTool) {
    assert(binding !is null && forms !is null);
    return ChannelsPanelRoles(ChannelsReadRole(owner, activeTool),
        ChannelsActions(&binding.dispatchInteractiveUi, forms),
        new ChannelsPanelState((const(Layer) id) => liveItem(owner, id)));
}

version (unittest) {
    struct ChannelsDrawSnapshot {
        bool drawn;
        bool bound;
        string title;
        string kindText;
        bool providerMatchesModel;
        bool memoReported;
        bool modelRebuilt;
        Object provider;
        size_t channelCount;
        size_t disabledChannels;
        bool retainedReported;
        ConstItem retainedItem;
        bool retainsProvider;
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
    private void recordChannelsMemo(bool rebuilt, ChannelsPanelState state) {
        g_channelsDrawSnapshot.memoReported = true;
        g_channelsDrawSnapshot.modelRebuilt = rebuilt;
        g_channelsDrawSnapshot.provider = state.provider_;
        g_channelsDrawSnapshot.channelCount = state.model_.channelCount;
    }
    private void recordChannelsDisabled(ChannelsPanelState state) {
        size_t n;
        if (state.provider_ !is null)
            foreach (ref p; state.provider_.params())
                if (!state.provider_.paramEnabled(p.name)) ++n;
        g_channelsDrawSnapshot.disabledChannels = n;
    }
    private void recordChannelsRetained(ChannelsPanelState state) {
        g_channelsDrawSnapshot.retainedReported = true;
        g_channelsDrawSnapshot.retainedItem = state.model_.key.item;
        g_channelsDrawSnapshot.retainsProvider = state.provider_ !is null;
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
    /// Which provider this binding owns — identity comparison only.
    const(Object) channelsFormProvider(ChannelsPanelState state) {
        return state.provider_;
    }
    /// Which item this binding's provider is bound to, by identity.
    const(Layer) channelsBoundItem(ChannelsPanelState state) {
        return state.provider_ is null ? null : state.provider_.boundItem();
    }
    /// Which writer the binder actually stored — identity, not spelling.
    void delegate(string, string) channelsInteractiveWriter(ChannelsActions a) {
        return a.interactive_;
    }
    /// Exercise the private resolver precondition without widening production
    /// construction beyond `bindChannelsPanel`.
    ChannelsPanelState channelsStateWithResolver(ChannelsItemResolve resolve) {
        alias State = ChannelsPanelState;
        return new State(resolve);
    }
} else {
    private void recordChannelsBegin() {}
    private void recordChannelsHeader(string, string) {}
    private void recordChannelsProvider(bool) {}
    private void recordChannelsMemo(bool, ChannelsPanelState) {}
    private void recordChannelsDisabled(ChannelsPanelState) {}
    private void recordChannelsRetained(ChannelsPanelState) {}
    private void recordChannelsGuard(bool) {}
    private void recordChannelsForm() {}
    private void recordVertexMapsHeader(bool) {}
    private void recordVertexMapLine(string) {}
}

private void drawVertexMapLine(string line) {
    recordVertexMapLine(line);
    ImGui.TextUnformatted(line);
}

void drawChannelsPanel(ChannelsReadRole read, ChannelsActions actions,
                       ChannelsPanelState state) {
    import ui.channel_rows : channelsHeaderName, kNoItemText;
    import layer_params    : itemPropsTarget;

    // Binds the item-selection FOCUS, never `document.primary` — an image
    // plane can never BE the primary, so a primary-bound panel would show
    // none of the channels this one exists for. Reached through the shared
    // `itemPropsTarget` so this surface and the properties form can never
    // disagree about which item is being edited. Resolved BEFORE `Begin`: a
    // docked tab that is not in front gets `Begin == false`, and the memo must
    // still let go of an item that is no longer the focus.
    auto item = itemPropsTarget(read.document());
    state.retainOnly(item);

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
        if (item is null) {
            ImGui.TextDisabled("%s", kNoItemText);
        } else {
            const rebuilt = state.refresh(read.document(), item);
            recordChannelsMemo(rebuilt, state);
            recordChannelsProvider(state.providerMatchesModel());

            // Header: whose channels these are, read live every draw. `%s`
            // rather than passing the name as the format string — it is user
            // text (same reason the Layers panel's kind badge does).
            const title = channelsHeaderName(item);
            ImGui.TextUnformatted(title);
            ImGui.SameLine();
            ImGui.TextDisabled("%s", state.model_.kindText);
            ImGui.Separator();
            recordChannelsHeader(title, state.model_.kindText);

            // The base provider's own mid-gesture transform interlock, driven
            // exactly as the Layers panel drives it: while a transform tool is
            // up over a GEOMETRY selection, the item transform is a second,
            // invisible writer and its rows grey out. Under `SelType.Item` the
            // gizmo's only write target IS these rows, so it must not arm —
            // the narrowing lives in `setTransformGuard`, read live from the
            // authority rather than cached.
            state.armTransformGuard(read.transformToolActive(),
                                    read.currentSelType());
            recordChannelsGuard(state.transformGuardArmed());
            recordChannelsDisabled(state);

            // The SAME renderer the properties form uses, so a row here is
            // resolved, drawn and written back by exactly one implementation.
            // `layerIndex` is empty on purpose: these lines were synthesised
            // with the live index already in them, so there is nothing for
            // `rebindBindingTarget` to overwrite.
            actions.drawChannelForm(state.model_.form, state.provider_);
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
    recordChannelsRetained(state);
    // `ImGui.End()` + `popPanelChromeStyle()` are the two `scope(exit)`s
    // registered above; they run after this record.
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
