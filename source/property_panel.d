module property_panel;

import tool   : Tool;
import params : ParamProvider;
import params_widgets : drawParamWidget;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// PropertyPanel — inline schema-driven property renderer for Tools.
//
// Unlike ArgsDialog (which wraps a modal popup with OK/Cancel), this renders
// the tool's params() list directly inside whatever ImGui window the caller
// has already opened. On any value change it immediately calls
// tool.onParamChanged(name) followed by tool.evaluate() so live-preview
// tools (e.g. BevelTool in polygon mode) update the 3D viewport in the same
// frame.
//
// No state is needed between frames: there is no pending/active bookkeeping.
// One instance lives on App alongside argsDialog.
//
// Usage (inside Begin/End block):
//   propertyPanel.draw(activeTool);
//   activeTool.drawProperties();   // tool-specific custom UI appended after
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// ID SCOPES — a label is TEXT, not a key (task 0640).
//
// ImGui hashes a widget's identity from the string it is labelled with, seeded
// by the top of the id stack. With no PushID anywhere, every section header and
// every row of every stage in the Tool Properties column hashed against ONE
// seed — the window's — so the column was a single flat namespace and a label
// carried two jobs at once: text for a human, and key for ImGui. Two stages
// could not independently choose the same word: the `constrain` and `path`
// stages both labelled their master toggle "Enabled" and were, to ImGui, one
// widget drawn twice (reproduced live: ImGui's own "2 visible items with
// conflicting ID!" panel with a red box round both checkboxes).
//
// Two scopes, because the two collisions are different:
//
//   * PER SECTION, opened around the header AND the body. Fixes collisions
//     BETWEEN stages. It has to wrap the header too — `CollapsingHeader` takes
//     its id from its own label like any other widget, and it is emitted
//     OUTSIDE the stage body, so a scope opened inside `drawSection`'s body
//     would leave the header hashing at window scope. That is why the header
//     is drawn here rather than by the caller.
//   * PER ROW, keyed on the parameter's WIRE NAME. Fixes collisions between
//     two rows of the SAME stage, which the section scope cannot: it also
//     covers widgets whose label is not the row's label (the enum radio draws
//     one RadioButton per entry, so two enum params sharing an entry name
//     collided even with distinct row labels).
//
// The wire name is the right key for a row: it is already unique within a
// provider (it is what `tool.pipe.attr <stage> <name>` addresses), and it is
// deliberately NOT the label — that is the whole point, since the label is now
// free to repeat.
// ---------------------------------------------------------------------------

class PropertyPanel {
    /// Render the schema-driven params for `tool` inline.
    /// Safe to call when tool is null (draws nothing). Tools whose
    /// `renderParamsAsPanel()` returns false are skipped — those expose
    /// params() purely for the headless tool.attr path and own UI
    /// rendering via their drawProperties() override.
    void draw(Tool tool) {
        if (tool is null) return;
        if (!tool.renderParamsAsPanel()) return;
        drawProvider(tool);
        // Tool gets the legacy preview re-evaluation; ParamProvider
        // generic path doesn't (stages don't have an `evaluate()` —
        // their setAttr / onParamChanged already publishes state).
        // Drive it by re-iterating params and re-firing only when
        // dirty, but cheaper to just call evaluate after the foreach.
        // (drawProvider has already fired onParamChanged for changes.)
    }

    /// One collapsible SECTION of the Tool Properties column: its own id
    /// scope, its header, and — when the header is open — its body.
    ///
    /// `sectionId` is the identity (a stage's `id()`), `title` the text
    /// (a stage's `displayName()`); they are separate arguments precisely so
    /// two sections may carry the same title. The scope is opened BEFORE the
    /// header, so the header is inside it — see the module note.
    void drawSection(string sectionId, string title, scope void delegate() body_,
                     int headerFlags = ImGuiTreeNodeFlags.DefaultOpen)
    {
        // What the header's id WOULD be with no scope open. Recorded (test
        // builds only) so the "is the header covered?" question is answerable
        // by measurement instead of by reading these lines.
        recordId(PanelIdKind.SectionUnscoped, sectionId, title, ImGui.GetID(title));
        pushScope(sectionId);
        scope(exit) popScope();
        recordId(PanelIdKind.Section, sectionId, title, ImGui.GetID(title));
        if (ImGui.CollapsingHeader(title, headerFlags))
            body_();
    }

    /// The id scope of `drawSection` WITHOUT a header — for a stage body that
    /// is drawn somewhere other than its section (the Snapping page), so both
    /// draw paths put the same rows under the same scope.
    void drawScoped(string sectionId, scope void delegate() body_) {
        pushScope(sectionId);
        scope(exit) popScope();
        body_();
    }

    /// The scope primitive the two wrappers above are built from, for a caller
    /// whose body does not fit a delegate (app.d's tool-level block). Pair it
    /// with `popScope()` — `scope(exit)` at the call site is the house idiom.
    void pushScope(string scopeId) {
        // Attribution for the id report is set OUTSIDE the ImGui push on
        // purpose: it must survive a build whose PushID is missing, or a
        // duplicate-id failure would be reported as "the column never drew the
        // rig" instead of naming the two culprits.
        pushRecordedScope(scopeId);
        ImGui.PushID(scopeId);
    }

    void popScope() {
        ImGui.PopID();
        popRecordedScope();
    }

    /// Generic ParamProvider renderer — used by `draw(Tool)` and by
    /// the per-stage Tool Properties iteration in app.d. Calls the
    /// provider's `onParamChanged(name)` after each mutation.
    void drawProvider(ParamProvider p) {
        if (p is null) return;
        // Tools receive their changes through the scoped interactive notifier,
        // so preview builders stay inert on raw headless `tool.attr` writes.
        // Stages have no Tool-only interactive state.
        auto t = cast(Tool)p;
        foreach (ref par; p.params()) {
            if (par.hidden_) continue;
            // One id scope per row, keyed on the wire name (see module note):
            // the label above is free to repeat another row's, here or in any
            // other section.
            ImGui.PushID(par.name);
            scope(exit) ImGui.PopID();
            recordId(PanelIdKind.RowScope, par.name, par.label, ImGui.GetID(kScopeProbe));
            recordId(PanelIdKind.Row,      par.name, par.label, ImGui.GetID(par.label));
            // A row is disabled if the provider greys it out for the current
            // state (paramEnabled) OR the param is flagged readonly (static).
            bool disabled = !p.paramEnabled(par.name) || par.readonly_;
            if (disabled) ImGui.BeginDisabled();
            bool changed = drawParamWidget(par);
            if (disabled) ImGui.EndDisabled();
            if (changed) {
                if (t !is null) t.notifyInteractiveParamChanged(par.name);
                else p.onParamChanged(par.name);
            }
        }
        // Tool subclasses also need an `evaluate()` re-run for live
        // preview; that's the single Tool-only call site retained here.
        // No-op when nothing changed in this frame — `evaluate` is cheap
        // for tools that aren't previewing.
        if (t !is null) t.evaluate();
    }
}

// ===========================================================================
// ID RECORDER — the column's id namespace, readable from a test.
//
// The collision this file exists to remove reaches a user as PIXELS and
// nothing else: ImGui paints its own "N visible items with conflicting ID!"
// panel and red-boxes the culprits, and writes nothing to stderr. Worse for a
// test, that diagnostic only arms while the mouse HOVERS one of the culprits
// (imgui.cpp counts duplicates in `ItemHoverable`) — and our harness cannot
// hover an ImGui widget at all: `--test` drops real pointer input, and the
// synthetic SDL events `/api/play-events` injects carry no `windowID`, which
// is the first thing the ImGui SDL backend checks before it will look at a
// mouse event. Both halves measured on a live instance, task 0640.
//
// So the panel records, as it draws, the ids ImGui itself would assign — the
// same `GetID` hash, at the same point in the same id stack — and serves them
// over HTTP. Equal ids ARE the conflict; that is the condition ImGui's own
// detector tests, minus the hover it needs to notice.
//
// Two values per row, because they answer different questions:
//   Row      — `GetID(label)`, the id a label-keyed widget in that row takes.
//              Two equal Row ids = two widgets that are one widget.
//   RowScope — `GetID(kScopeProbe)`, a stand-in for the row's SEED: the hash
//              of ONE fixed string, so it varies with the seed alone. Two equal
//              RowScope ids = two rows sharing a namespace, so ANY label they
//              happen to share collides, including labels the row renderer
//              generates itself (enum radio entries).
// and two per section: the header's real id, plus the id it would have had
// with no scope open, so "the scope covers the header" is a measurement.
//
// Collected only under `--test` (it costs a hash and an append per row per
// frame, and a normal run has no reader). The published snapshot is swapped
// in whole at end-of-column, so a reader on the HTTP thread never sees a
// half-built column.
// ===========================================================================

/// The fixed string hashed to read a row's id-stack SEED. Never rendered; the
/// `##` prefix is ImGui's own "id only, no visible text" marker, so it cannot
/// be mistaken for a label a schema would carry.
private enum kScopeProbe = "##vibe3d.idscope";

enum PanelIdKind : string {
    SectionUnscoped = "sectionUnscoped",
    Section         = "section",
    RowScope        = "rowScope",
    Row             = "row",
}

struct PanelIdEntry {
    string section; // enclosing scope id ("" = the column root)
    string kind;    // PanelIdKind
    string key;     // section id / param wire name
    string label;   // the human text (may repeat — that is the point)
    uint   id;      // ImGuiID
}

private __gshared PanelIdEntry[] g_panelIdsScratch;    // main thread only
private __gshared PanelIdEntry[] g_panelIdsPublished;  // guarded by g_panelIdsMx
private __gshared Object         g_panelIdsMx;
private __gshared string         g_currentScope;       // main thread only

shared static this() { g_panelIdsMx = new Object(); }

// The scope id a row is being drawn under, so a duplicate can be REPORTED by
// the two places that produced it rather than by two bare hashes. Mirrors the
// ImGui id stack one level deep — the panel never nests sections.
private void pushRecordedScope(string scopeId) { g_currentScope = scopeId; }
private void popRecordedScope()                { g_currentScope = null;    }

private void recordId(PanelIdKind kind, string key, string label, uint id) {
    import command : g_testMode;
    if (!g_testMode) return;
    g_panelIdsScratch ~= PanelIdEntry(g_currentScope is null ? "" : g_currentScope,
                                      cast(string)kind, key, label, id);
}

/// Start a fresh recording for one Tool Properties column. Called by the
/// panel's owner right after the window opens; without it the entries of
/// successive frames would pile up and every id would look like a duplicate.
void beginToolPropsIdColumn() {
    import command : g_testMode;
    if (!g_testMode) return;
    g_panelIdsScratch.length = 0;
    g_panelIdsScratch.assumeSafeAppend();
    g_currentScope = null;
}

/// Publish the column just drawn. One assignment under the lock: a reader
/// gets a whole column or the previous whole column, never a prefix.
void endToolPropsIdColumn() {
    import command : g_testMode;
    if (!g_testMode) return;
    synchronized (g_panelIdsMx)
        g_panelIdsPublished = g_panelIdsScratch.dup;
}

/// GET /api/toolprops/ids payload — the id namespace of the last complete
/// Tool Properties column.
string toolPropsIdsJson() {
    import std.json  : JSONValue;
    import std.array : appender;
    PanelIdEntry[] snap;
    synchronized (g_panelIdsMx)
        snap = g_panelIdsPublished.dup;
    JSONValue[] items;
    foreach (ref e; snap) {
        JSONValue j;
        j["section"] = JSONValue(e.section);
        j["kind"]  = JSONValue(e.kind);
        j["key"]   = JSONValue(e.key);
        j["label"] = JSONValue(e.label);
        // ImGuiID is a u32; JSON integers are signed, so widen to long.
        j["id"]    = JSONValue(cast(long)e.id);
        items ~= j;
    }
    JSONValue root;
    root["items"] = JSONValue(items);
    return root.toString();
}
