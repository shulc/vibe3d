module forms_render;

// ===========================================================================
// forms_render — FormsPanel: the ImGui renderer for config-driven Tool
// Properties forms (Phase 4 of doc/forms_engine_plan.md).
//
// FormsPanel walks a resolved `Form` (forms.d) once per frame and emits ImGui
// widgets. The read side queries the active provider's live `params()` snapshot
// (immediate-mode re-query); the write side dispatches the SAME `tool.attr` /
// `tool.pipe.attr` argstring the headless HTTP path uses, so the UI edit path
// and the /api/command path are byte-identical.
//
// Separation of concerns from forms.d:
//   * forms.d        — pure schema + binding resolver (ImGui-free, unit-tested).
//   * forms_render.d — this module. Imports d_imgui + params; reaches the
//                      command dispatch and the live provider only through the
//                      delegates the caller (app.d) supplies. It never imports
//                      the registry, the pipeline, or any concrete tool.
//
// Write path (per the plan / doc/tool_reevaluate_plan.md):
//   * `control` value rows: on edit-commit, build the write argstring by
//     substituting the edited value for `?`, then dispatch via the INTERACTIVE
//     delegate — which marks the built ToolAttrCommand `interactive` (an
//     in-process `setInteractive(true)`) so the universal reEvaluate() seam
//     opens the tool's snapshot session on the first edit and replays
//     absolutely thereafter (one coalesced undo entry at commit). The flag is
//     NEVER an argstring arg, so raw HTTP `tool.attr` stays inert.
//   * `cmd` / `choice` rows: fire-only on click/selection through the PLAIN
//     dispatch delegate (no interactive flag — write-only UI in v1).
//
// Active-item guard (the single most error-prone interaction, per the plan):
//   ImGui is immediate-mode. We re-query a control's live value every frame and
//   feed it into the widget. While the widget is being typed/dragged
//   (ImGui.IsItemActive after the call), the widget's OWN in-flight edit buffer
//   is authoritative — we must NOT stomp it with the re-queried value next
//   frame. Each widget here renders into a per-control scratch buffer that is
//   re-seeded from the live value ONLY when the control is not active; while
//   active, the scratch buffer carries the user's edit and the re-seed is
//   skipped. drawProvider in property_panel.d binds the typed pointer directly
//   and never re-seeds (it IS the single live widget), so it has no such fight;
//   FormsPanel queries a copy, so it needs the guard explicitly.
//
// Value serialization aligns with argstring %g (forms_engine_plan.md Phase 2
// review TODO): floats are formatted with %g so a UI-originated write argstring
// is byte-identical to what serializeParams() would emit for the same value.
// ===========================================================================

import forms;
// Pure write-path serialization helpers live in forms.d (ImGui-free, so they
// stay headless-unit-testable without dragging d_imgui into a test link).
import forms : valueToArgToken, substituteQuery, currentEnumTag;
import params : Param, ParamProvider, paramToJson;

import ImGui = d_imgui;
import d_imgui.imgui_h;

import std.format : format;
import std.json   : JSONValue;

// ---------------------------------------------------------------------------
// Dispatch delegates the caller wires up. Both take the SAME (commandId,
// paramsJson) shape as commandHandlerDelegate / /api/command, so the renderer
// stays decoupled from the command system.
// ---------------------------------------------------------------------------

/// Plain command dispatch (cmd / choice rows). Identical to
/// commandHandlerDelegate.
alias DispatchFn = void delegate(string commandId, string paramsJson);

/// Interactive `tool.attr` dispatch (control value rows). The caller's
/// implementation builds the ToolAttrCommand, calls setInteractive(true) on it
/// in-process, and runs it — opening the tool's live-eval session on the first
/// edit (re-eval seam). Same wire shape as DispatchFn.
alias InteractiveDispatchFn = void delegate(string commandId, string paramsJson);

// ---------------------------------------------------------------------------
// FormsPanel — one instance lives on App (alongside propertyPanel). Holds the
// per-control active-item scratch buffers across frames; everything else is
// recomputed each frame.
// ---------------------------------------------------------------------------

class FormsPanel {

    // Per-control edit scratch, keyed by the control's stable id. Lives across
    // frames so an in-flight drag/type keeps its value while ImGui owns it.
    private struct Scratch {
        float  f;
        int    i;
        bool   active;   // was this control ImGui-active last frame?
    }
    private Scratch[string] scratch_;

    // Live active tool id for the frame, set by draw(). A `tool.attr` (Namespace
    // .tool) control line carries the CANONICAL family tool id `xfrm.transform`
    // (what validateForms resolves against), but the SAME readable form is shown
    // for every XfrmTransformTool activation id (move / rotate / scale / the
    // transform presets — config/forms/transform.yaml). ToolAttrCommand guards
    // that its tool id equals the live activeToolId, so a write must be rebound
    // to the active id or it throws "active tool is 'move', expected
    // 'xfrm.transform'". writeValue rebinds the tool-namespace target to this id.
    // Empty (the default / stage-form callers) => use the line's literal id.
    private string activeToolId_;

    /// Render `form` for the active provider. `provider` supplies the live
    /// params() snapshot (read once at the top of this call to bound re-query
    /// cost — the plan's per-frame-cost mitigation). `dispatch` fires cmd /
    /// choice rows; `idispatch` fires control value writes marked interactive.
    /// `activeToolId` rebinds tool-namespace writes to the live tool (see
    /// activeToolId_); pass "" for stage forms (their lines name the real stage).
    void draw(ref Form form, ParamProvider provider,
              DispatchFn dispatch, InteractiveDispatchFn idispatch,
              string activeToolId = "")
    {
        if (provider is null) return;
        activeToolId_ = activeToolId;

        // ---- one params() snapshot per frame -----------------------------
        // The resolver reads from this name->Param map; falloff.params()
        // rebuilds its list on every call, so snapshotting once here means the
        // whole form's controls share one rebuild rather than one-per-control.
        Param[] snapshot = provider.params();

        if (form.showLabel && form.label.length)
            ImGui.SeparatorText(form.label);

        foreach (i, ref row; form.rows)
            drawRow(row, cast(int) i, snapshot, provider, dispatch, idispatch);
    }

    // -----------------------------------------------------------------------
    // Row dispatch
    // -----------------------------------------------------------------------

    private void drawRow(ref Row row, int rowIdx, Param[] snapshot,
                         ParamProvider provider,
                         DispatchFn dispatch, InteractiveDispatchFn idispatch)
    {
        final switch (row.kind) {
            case RowKind.control:
                drawControl(row, rowIdx, snapshot, provider, idispatch);
                break;
            case RowKind.cmd:
                drawCmd(row, dispatch);
                break;
            case RowKind.choice:
                drawChoice(row, rowIdx, dispatch);
                break;
            case RowKind.group:
                drawGroup(row, rowIdx, snapshot, provider, dispatch, idispatch);
                break;
            case RowKind.divider:
                ImGui.Separator();
                break;
            case RowKind.label:
                ImGui.TextUnformatted(row.label);
                break;
            // sub / ref: cross-form assembly is out of scope for v1 (Phase 4).
            // ref: toolprops.falloff in transform.yaml resolves to nothing yet —
            // render nothing rather than error, so the shipped form loads clean.
            case RowKind.sub:
            case RowKind.ref_:
                break;
        }
    }

    // -----------------------------------------------------------------------
    // Left-label layout. A value row reads as:  [ Label ........ | widget---- ]
    // The label sits in a fixed LEFT column (~0.35 of the content width); the
    // widget that follows fills the remaining width via SetNextItemWidth(-eps).
    // This replaces ImGui's default label-RIGHT-of-widget placement, which drew
    // a default-width box first and pushed the label off the panel edge.
    //
    // Call this immediately before the value widget. When `label` is empty
    // (showLabel: false) it still reserves the column so unlabeled rows in a
    // group stay aligned with labelled ones, and still fills the widget width.
    // -----------------------------------------------------------------------
    private void beginLabeledRow(string label)
    {
        const float avail = ImGui.GetContentRegionAvail().x;
        // Left column = 35% of the available content width, clamped to a sane
        // minimum so a very narrow panel still shows a few glyphs.
        float col = avail * 0.35f;
        if (col < 36.0f) col = 36.0f;

        ImGui.AlignTextToFramePadding();   // baseline-align label with the widget
        if (label.length)
            ImGui.TextUnformatted(label);
        else
            ImGui.TextUnformatted(" ");    // keep the row height + column

        ImGui.SameLine(col);
        // Fill the rest of the row. -float.min_normal is the ImGui idiom for
        // "stretch to the right edge of the content region".
        ImGui.SetNextItemWidth(-float.min_normal);
    }

    // -----------------------------------------------------------------------
    // control rows — value field/toggle bound to `tool.attr ... ?`.
    // -----------------------------------------------------------------------

    private void drawControl(ref Row row, int rowIdx, Param[] snapshot,
                             ParamProvider provider,
                             InteractiveDispatchFn idispatch)
    {
        auto rc = resolveControl(row, snapshot);
        if (!rc.found) return;             // runtime-hidden (dynamic absence)

        // Stable per-control id: PushID so repeated labels (X in Position vs X
        // in Scale) never collide. Prefer the authored id; else derive from the
        // command line + row index.
        string cid = row.id.length ? row.id
                                   : format("%s#%d", row.command, rowIdx);
        ImGui.PushID(cid);
        scope(exit) ImGui.PopID();

        // Greyed if the provider disables this row for the current state.
        bool disabled = !provider.paramEnabled(rc.param.name);
        if (disabled) ImGui.BeginDisabled();
        scope(exit) if (disabled) ImGui.EndDisabled();

        // Visible label text (left column) vs. the hidden `##id` label fed to
        // the widget. Checkbox / button keep ImGui's native right-of-widget
        // label; value widgets (float / int / combo / text) put the label in a
        // fixed LEFT column and let the widget fill the rest of the row width —
        // so X/Y/Z labels never clip off the panel edge and the boxes don't
        // overflow (the readability fix, doc/forms_engine_plan.md user feedback).
        string visible = row.showLabel
                       ? (row.label.length ? row.label : rc.param.label)
                       : "";
        string hidden  = "##" ~ cid;   // unique id, no visible glyphs

        final switch (rc.widget) {
            case WidgetKind.checkbox:
                drawCheckbox(row, rc, row.showLabel ? visible : hidden, idispatch);
                break;
            case WidgetKind.button:
                drawBoolButton(row, rc, row.showLabel ? visible : hidden, idispatch);
                break;
            case WidgetKind.dragFloat:
            case WidgetKind.sliderFloat:
                beginLabeledRow(visible);
                drawFloatControl(row, rc, cid, hidden, idispatch);
                break;
            case WidgetKind.dragInt:
            case WidgetKind.sliderInt:
                beginLabeledRow(visible);
                drawIntControl(row, rc, cid, hidden, idispatch);
                break;
            case WidgetKind.combo:
                beginLabeledRow(visible);
                drawCombo(row, rc, hidden, idispatch);
                break;
            case WidgetKind.text:
                beginLabeledRow(visible);
                drawText(row, rc, hidden, idispatch);
                break;
            case WidgetKind.vec3:
                // A Vec3 attr expands into three drags; transform binds X/Y/Z
                // as SEPARATE float attrs (TX/TY/TZ) so this path is unused by
                // the v1 adopter. Render the live components read-only-ish via
                // the float helper would need three sub-ids; defer — v1 forms
                // never bind a single Vec3 attr. Show value as text fallback.
                ImGui.LabelText(row.showLabel ? visible : hidden, "%s",
                                paramToJson(rc.param).toString());
                break;
            case WidgetKind.none:
                break;
        }
    }

    // ---- bool: checkbox ---------------------------------------------------
    private void drawCheckbox(ref Row row, ref ResolvedControl rc, string label,
                              InteractiveDispatchFn idispatch)
    {
        bool v = *rc.param.bptr;
        if (ImGui.Checkbox(label, &v))
            writeValue(row, JSONValue(v), idispatch);
    }

    // ---- bool: momentary button (booleanStyle: button) -------------------
    private void drawBoolButton(ref Row row, ref ResolvedControl rc, string label,
                                InteractiveDispatchFn idispatch)
    {
        // A button toggles the bool on click (the momentary-style affordance).
        bool v = *rc.param.bptr;
        if (ImGui.Button(label))
            writeValue(row, JSONValue(!v), idispatch);
    }

    // ---- float: drag / slider, with active-item guard --------------------
    private void drawFloatControl(ref Row row, ref ResolvedControl rc,
                                  string cid, string label,
                                  InteractiveDispatchFn idispatch)
    {
        auto sc = cid in scratch_;
        if (sc is null) { scratch_[cid] = Scratch.init; sc = cid in scratch_; }

        // Active-item guard: re-seed from the live value ONLY when the widget
        // is not mid-edit. While active, sc.f carries the user's in-flight edit.
        if (!sc.active)
            sc.f = *rc.param.fptr;

        const h = rc.param.hints;
        float lo   = h.hasMinF ? h.minF : 0.0f;
        float hi   = h.hasMaxF ? h.maxF : 0.0f;
        float step = h.hasStep ? h.step_ : 0.001f;
        string fmt = h.hasFmt  ? h.fmt   : "%.3f";

        bool changed;
        if (rc.widget == WidgetKind.sliderFloat && h.hasMinF && h.hasMaxF)
            changed = ImGui.SliderFloat(label, &sc.f, lo, hi, fmt);
        else
            changed = ImGui.DragFloat(label, &sc.f, step, lo, hi, fmt);

        sc.active = ImGui.IsItemActive();
        if (changed)
            writeValue(row, JSONValue(cast(double) sc.f), idispatch);
    }

    // ---- int: drag / slider, with active-item guard ----------------------
    private void drawIntControl(ref Row row, ref ResolvedControl rc,
                                string cid, string label,
                                InteractiveDispatchFn idispatch)
    {
        auto sc = cid in scratch_;
        if (sc is null) { scratch_[cid] = Scratch.init; sc = cid in scratch_; }

        if (!sc.active)
            sc.i = *rc.param.iptr;

        const h = rc.param.hints;
        int lo = h.hasMinI ? h.minI : 0;
        int hi = h.hasMaxI ? h.maxI : 0;

        bool changed;
        if (rc.widget == WidgetKind.sliderInt && h.hasMinI && h.hasMaxI)
            changed = ImGui.SliderInt(label, &sc.i, lo, hi);
        else
            changed = ImGui.DragInt(label, &sc.i, 0.1f, lo, hi);

        sc.active = ImGui.IsItemActive();
        if (changed)
            writeValue(row, JSONValue(sc.i), idispatch);
    }

    // ---- enum / intEnum: combo (choices from the Param, not YAML) --------
    private void drawCombo(ref Row row, ref ResolvedControl rc, string label,
                           InteractiveDispatchFn idispatch)
    {
        // Current tag + preview label from the resolved choices.
        string curTag = currentEnumTag(rc.param);
        string preview = curTag;
        foreach (ch; rc.choices)
            if (ch[0] == curTag) { preview = ch[1]; break; }

        if (ImGui.BeginCombo(label, preview)) {
            foreach (ch; rc.choices) {
                bool sel = (ch[0] == curTag);
                if (ImGui.Selectable(ch[1], sel) && !sel) {
                    // Enum writes the tag string; intEnum writes its wire tag
                    // too (both are strings on the wire — the command parses).
                    writeValue(row, JSONValue(ch[0]), idispatch);
                }
                if (sel) ImGui.SetItemDefaultFocus();
            }
            ImGui.EndCombo();
        }
    }

    // ---- string: text input ----------------------------------------------
    private void drawText(ref Row row, ref ResolvedControl rc, string label,
                          InteractiveDispatchFn idispatch)
    {
        import core.stdc.string : strlen;
        char[256] buf;
        string cur = *rc.param.sptr;
        size_t len = cur.length < buf.length - 1 ? cur.length : buf.length - 1;
        buf[0 .. len] = cur[0 .. len];
        buf[len] = '\0';
        if (ImGui.InputText(label, buf[])) {
            string nv = cast(string) buf[0 .. strlen(buf.ptr)].dup;
            writeValue(row, JSONValue(nv), idispatch);
        }
    }

    // -----------------------------------------------------------------------
    // cmd / choice rows — fire-only (plain dispatch, no interactive flag).
    // -----------------------------------------------------------------------

    private void drawCmd(ref Row row, DispatchFn dispatch)
    {
        string label = row.label.length ? row.label : row.command;
        if (ImGui.Button(label))
            fireLine(row.command, dispatch);
    }

    private void drawChoice(ref Row row, int rowIdx, DispatchFn dispatch)
    {
        if (row.entries.length == 0) return;
        ImGui.PushID(format("choice#%d#%s", rowIdx, row.label));
        scope(exit) ImGui.PopID();

        // v1: a plain action combo with no derived checked-state — selecting an
        // entry fires its command. The preview shows the menu title.
        if (ImGui.BeginCombo(row.label, row.label)) {
            foreach (e; row.entries) {
                if (ImGui.Selectable(e.label, false))
                    fireLine(e.cmd, dispatch);
            }
            ImGui.EndCombo();
        }
    }

    // -----------------------------------------------------------------------
    // group rows — the framed field cluster (group box). Channel-split idiom
    // (the plan's recommended z-order-safe approach): draw the member widgets
    // on a foreground channel and the highlighted background rect + border on a
    // background channel, then merge so the rect paints BEHIND the widgets.
    // A naive rect-after-widgets would paint over them; channel-split avoids it.
    // -----------------------------------------------------------------------

    // True iff at least one member of `group` resolves to a renderable widget
    // this frame. A control row whose bound attr is absent from the active
    // params() resolves found=false and draws nothing (drawControl early-returns);
    // a fully-absent group would otherwise leave an empty framed box with just
    // the group label. Non-control members (cmd / choice / divider / label)
    // always draw, so they count as visible.
    private bool groupHasVisibleMember(ref Row group, Param[] snapshot)
    {
        foreach (ref child; group.rows) {
            if (child.kind == RowKind.control) {
                if (resolveControl(child, snapshot).found) return true;
            } else {
                return true;   // cmd / choice / divider / label always render
            }
        }
        return false;
    }

    private void drawGroup(ref Row row, int rowIdx, Param[] snapshot,
                           ParamProvider provider,
                           DispatchFn dispatch, InteractiveDispatchFn idispatch)
    {
        // Skip the framed box entirely when every member is runtime-hidden —
        // otherwise the channel-split below paints an empty rect + the group
        // label with no controls inside it.
        if (!groupHasVisibleMember(row, snapshot)) return;

        ImGui.PushID(format("group#%d#%s", rowIdx, row.label));
        scope(exit) ImGui.PopID();

        auto dl = ImGui.GetWindowDrawList();
        dl.ChannelsSplit(2);
        dl.ChannelsSetCurrent(1);        // 1 = foreground (the widgets)

        const float pad = 4.0f;
        ImVec2 groupMin = ImGui.GetCursorScreenPos();
        groupMin.x += pad;
        groupMin.y += pad;
        ImGui.SetCursorScreenPos(groupMin);

        ImGui.BeginGroup();

        // Group label drawn once, on the first line of the cluster.
        if (row.label.length)
            ImGui.TextUnformatted(row.label);

        // Members carry short labels (X / Y / Z). Inline style packs them; the
        // simplest robust layout is a stacked list of narrowed drags — keep the
        // member rows on their own lines (matches the legacy MoveTool sliders),
        // which reads cleanly in the narrow Tool Properties window.
        foreach (i, ref child; row.rows)
            drawRow(child, cast(int) i, snapshot, provider, dispatch, idispatch);

        ImGui.EndGroup();

        // Background channel: a highlighted rect + border behind the cluster.
        ImVec2 rmin = ImGui.GetItemRectMin();
        ImVec2 rmax = ImGui.GetItemRectMax();
        rmin.x -= pad; rmin.y -= pad;
        rmax.x += pad; rmax.y += pad;
        dl.ChannelsSetCurrent(0);        // 0 = background
        dl.AddRectFilled(rmin, rmax, IM_COL32(58, 58, 66, 255), 3.0f);
        dl.AddRect(rmin, rmax, IM_COL32(96, 96, 110, 255), 3.0f);
        dl.ChannelsMerge();

        // Advance the cursor past the padded box so following rows clear it.
        ImGui.Dummy(ImVec2(0, pad));
    }

    // -----------------------------------------------------------------------
    // Write helpers
    // -----------------------------------------------------------------------

    /// Build the write argstring by substituting the edited value for the `?`
    /// token, then dispatch it interactively. The value is serialized to match
    /// the argstring wire format (floats via %g) so a UI-originated write is
    /// byte-identical to serializeParams() output.
    private void writeValue(ref Row row, JSONValue value,
                            InteractiveDispatchFn idispatch)
    {
        if (idispatch is null) return;
        auto b = parseBinding(row.command);
        // Rebind a tool-namespace write to the LIVE active tool id. The form
        // line carries the canonical family id `xfrm.transform`, but the same
        // form is shown for every XfrmTransformTool activation id; the write
        // must name whichever id is active or ToolAttrCommand's active-id guard
        // throws. Stage forms (Namespace.stage) and callers that pass no active
        // id keep the literal target. positionals[0] is the target id (the
        // tokenized form parseBinding produced); substituteQuery rebuilds the
        // line from positionals, so rewriting that slot is sufficient.
        if (b.namespace == Namespace.tool && activeToolId_.length
            && b.positionals.length >= 1)
        {
            b.positionals[0] = activeToolId_;
            b.targetId       = activeToolId_;
        }
        // Reconstruct the command line with the value in the `?` slot, then
        // parse it back through argstring so tokenization matches the wire.
        string line = substituteQuery(b, value);
        fireInteractive(line, idispatch);
    }

    private void fireInteractive(string line, InteractiveDispatchFn idispatch)
    {
        import argstring : parseArgstring;
        auto parsed = parseArgstring(line);
        if (parsed.isEmpty) return;
        idispatch(parsed.commandId, parsed.params.toString());
    }

    private void fireLine(string line, DispatchFn dispatch)
    {
        import argstring : parseArgstring;
        if (dispatch is null) return;
        auto parsed = parseArgstring(line);
        if (parsed.isEmpty) return;
        dispatch(parsed.commandId, parsed.params.toString());
    }
}
