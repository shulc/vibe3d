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
import params : Param, ParamProvider;

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

    // Compact vector-group layout context (the Position X / Y / Z look). While
    // a group is being drawn, beginLabeledRow uses a TWO-column scheme instead of
    // the default single label column: the group label ("Position") is printed
    // ONCE on the first member's row, then a fixed component-label column (X/Y/Z)
    // and a fixed value-field column so every member's field lines up under the
    // first. Inactive (active=false) for non-group rows, which keep the legacy
    // single-column layout. Set by computeGroupLayout in drawGroup, restored
    // after the member loop so nested groups / following rows are unaffected.
    private struct GroupLayout {
        bool   active;
        string groupLabel;        // printed once, row 0 ("Position")
        bool   firstMemberDrawn;  // has the group label been emitted yet?
        float  fieldColX;         // window-local x of the value field (FIXED)
        float  labelGap;          // gap between component label and field
    }
    private GroupLayout glayout_;

    // P-E tweak-boundary hook. Fired when a value control finishes a continuous
    // edit (ImGui IsItemDeactivatedAfterEdit) — i.e. the user RELEASES a slider /
    // drag-field after scrubbing it. The host wires this to
    // CommandHistory.bumpTweakGeneration() so the slider's contiguous setAttr
    // stream (which all shared one generation and REPLACEd into ONE in-session
    // undo step — the continuous-coalesce case) closes out, and the NEXT tweak
    // opens a fresh generation that APPENDS as its own step (reference fact G2).
    // Optional: a null hook means no generation management (e.g. a non-transform
    // form, or a build without the transform-session refire). Set once via
    // setTweakEndHook(); never per-frame.
    private void delegate() onTweakEnd_;

    /// Wire the P-E tweak-boundary hook (see onTweakEnd_). Idempotent; pass null
    /// to clear.
    void setTweakEndHook(void delegate() hook) { onTweakEnd_ = hook; }

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

    // Live STAGE id for the frame, set by draw(). Parallel to activeToolId_ but
    // for the stage namespace: a `tool.pipe.attr falloff <attr>` control line
    // names the canonical family id "falloff", but the same form is shown for
    // every stacked FalloffStage instance ("falloff", "falloff#1", …). A write
    // must name the LIVE instance or it lands on the primary, so writeValue
    // rebinds the stage-namespace target to this id. Empty => literal id.
    private string stageId_;

    // Live LAYER index (as a string token) for the frame, set by draw().
    // Parallel to activeToolId_/stageId_ but for the layer namespace: a
    // `layer.attr <index> <attr> ?` control line carries a literal placeholder
    // index in YAML; the live index is supplied per-draw so writeValue rebinds
    // the layer-namespace target to the layer the panel is bound to. Empty =>
    // literal placeholder (no layer form drawn). NOTE: a layer.attr edit is a
    // no-op until the layer.attr command exists (a later phase); for now the
    // form RENDERS + READS the provider's live values but a write dispatches an
    // unhandled command (intentional).
    private string layerIndex_;

    /// Render `form` for the active provider. `provider` supplies the live
    /// params() snapshot (read once at the top of this call to bound re-query
    /// cost — the plan's per-frame-cost mitigation). `dispatch` fires cmd /
    /// choice rows; `idispatch` fires control value writes marked interactive.
    /// `activeToolId` rebinds tool-namespace writes to the live tool (see
    /// activeToolId_); pass "" for stage forms (their lines name the real stage).
    /// `layerIndex` rebinds layer-namespace writes (`layer.attr`) to the live
    /// layer index — symmetric with activeToolId/stageId; pass "" for tool/stage
    /// forms (the layer-props panel passes the active layer index).
    void draw(ref Form form, ParamProvider provider,
              DispatchFn dispatch, InteractiveDispatchFn idispatch,
              string activeToolId = "", string stageId = "",
              string layerIndex = "")
    {
        if (provider is null) return;
        activeToolId_ = activeToolId;
        stageId_      = stageId;
        layerIndex_   = layerIndex;

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
        // Row-level visibility gate: a `whenAttr` row draws only when that attr
        // is present in the live params() this frame — the same value-driven
        // hiding a control gets when its own attr is absent, but extended to
        // rows with no value bind (cmd / group). Lets the Linear-only falloff
        // actions (Auto Size, Reverse) ride `start`, exposed only by Linear.
        if (row.whenAttr.length && !snapshotHasAttr(snapshot, row.whenAttr))
            return;

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
        // Inside a vector group: two-column compact layout (see GroupLayout).
        // The group label rides the first member's row ("Position" + "X"); the
        // rest leave it blank so "Y"/"Z" and their fields align under "X".
        if (glayout_.active) {
            ImGui.AlignTextToFramePadding();
            if (!glayout_.firstMemberDrawn) {
                ImGui.TextUnformatted(glayout_.groupLabel.length
                                      ? glayout_.groupLabel : " ");
                glayout_.firstMemberDrawn = true;
            } else {
                ImGui.TextUnformatted(" ");   // keep the row; group col stays empty
            }
            // Component label (X / Y / Z) right-aligned just before the field, so
            // the letters sit flush against the box and line up across
            // rows. fieldColX is FIXED per group, so the field has the same x +
            // width for every tool (move / rotate / scale).
            float lw = label.length ? ImGui.CalcTextSize(label).x : 0.0f;
            float lx = glayout_.fieldColX - glayout_.labelGap - lw;
            if (lx < 0.0f) lx = 0.0f;
            ImGui.SameLine(lx);
            ImGui.TextUnformatted(label.length ? label : " ");
            // Value field column — same x on every row so the fields line up.
            ImGui.SameLine(glayout_.fieldColX);
            ImGui.SetNextItemWidth(-float.min_normal);
            return;
        }

        ImGui.AlignTextToFramePadding();   // baseline-align label with the widget
        if (label.length)
            ImGui.TextUnformatted(label);
        else
            ImGui.TextUnformatted(" ");    // keep the row height + column

        ImGui.SameLine(fieldColumnX());
        // Fill the rest of the row. -float.min_normal is the ImGui idiom for
        // "stretch to the right edge of the content region".
        ImGui.SetNextItemWidth(-float.min_normal);
    }

    // Fixed label-column width shared by EVERY form row — plain controls, vector
    // clusters (makeVectorLayout), and button rows. All widgets start at this x
    // and fill to the right edge, so labels sit left-aligned in one column and
    // every widget has the SAME width regardless of label text (the alignment
    // the user asked for). Font-relative (DPI-aware); clamped on a very narrow
    // panel so the label keeps room.
    private float fieldColumnX()
    {
        float col   = ImGui.GetFontSize() * 7.0f;
        float avail = ImGui.GetContentRegionAvail().x;
        if (avail > 0.0f && col > avail * 0.6f) col = avail * 0.6f;
        return col;
    }

    // Build the FIXED value-field column for a vector cluster's compact layout.
    // The field starts at the same x for every cluster regardless of the group
    // label text ("Position" vs "Rotate" vs "Scale" vs "Start" vs "End"), so the
    // value box has an identical position and width across tools — the
    // user-visible requirement. The column is font-relative (DPI-aware via
    // GetFontSize), with a safety clamp so a group label wider than the fixed
    // reserve still gets room (our labels never exceed it, so the field stays put
    // across them). Shared by drawGroup (separate-attr clusters like TX/TY/TZ)
    // and drawVec3Control (a single Vec3 attr like falloff start/end).
    private GroupLayout makeVectorLayout(string groupLabel)
    {
        GroupLayout g;
        g.active     = true;
        g.groupLabel = groupLabel;
        g.labelGap   = ImGui.GetStyle().ItemSpacing.x + 4.0f;

        const float em = ImGui.GetFontSize();
        float groupW = groupLabel.length ? ImGui.CalcTextSize(groupLabel).x : 0.0f;

        // Same fixed column as every plain row (fieldColumnX), so a Vec3 cluster's
        // fields line up with plain-control widgets. A fit fallback only grows the
        // column for an over-long group label.
        float fixedCol = fieldColumnX();
        float fitCol   = groupW + g.labelGap + em * 1.5f;
        g.fieldColX = fixedCol > fitCol ? fixedCol : fitCol;
        return g;
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
                // A single Vec3 attr (e.g. falloff start/end) expands into an
                // editable X/Y/Z cluster, rendered in the same compact layout as
                // a separate-attr `group:` (TX/TY/TZ). An edit writes the full
                // vec3 back as "x,y,z".
                drawVec3Control(row, rc, cid, row.showLabel ? visible : "",
                                idispatch);
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
        // Align the checkbox box at the value-field column (its left edge), with
        // the label to its RIGHT — so a column of checkboxes lines up with the
        // numeric fields above/below them. beginLabeledRow("") emits an empty
        // left label gutter and advances the cursor to fieldColumnX, exactly as
        // a value row does, so checkbox boxes and field boxes share the same x.
        beginLabeledRow("");
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
        float step = h.hasStep ? h.step_ : (h.isAngle ? 0.1f : 0.001f);
        string fmt = h.hasFmt  ? h.fmt   : "%.3f";

        bool changed;
        if (rc.widget == WidgetKind.sliderFloat && h.hasMinF && h.hasMaxF)
            changed = ImGui.SliderFloat(label, &sc.f, lo, hi, fmt);
        else
            changed = ImGui.DragFloat(label, &sc.f, step, lo, hi, fmt);

        sc.active = ImGui.IsItemActive();
        if (changed)
            writeValue(row, JSONValue(cast(double) sc.f), idispatch);
        // P-E: a slider/drag scrub just ENDED (released after editing). Close out
        // the continuous tweak's generation so the next tweak APPENDS (G2). The
        // contiguous setAttr stream during the scrub shared one generation (the
        // interactive latch suppressed the per-setAttr bump in app.d), so this is
        // the seam that ends the coalesced window.
        if (ImGui.IsItemDeactivatedAfterEdit() && onTweakEnd_ !is null)
            onTweakEnd_();
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
        // P-E: end-of-scrub tweak-generation boundary (see drawFloatControl).
        if (ImGui.IsItemDeactivatedAfterEdit() && onTweakEnd_ !is null)
            onTweakEnd_();
    }

    // ---- vec3: editable X/Y/Z cluster, with per-component active-item guard --
    //
    // A single Vec3 attr (falloff start/end/center/size/axis) renders as three
    // component drags under one group label, in the same compact layout as a
    // separate-attr `group:` (so a Vec3 attr and a TX/TY/TZ group look identical).
    // Each component keeps its own scratch keyed by `<cid>.<k>`; editing one
    // component writes the FULL vec3 back as "x,y,z" — the parseVec3 wire format
    // (matches FalloffStage.vec3Str, %g per component) — so the other two are
    // preserved. The caller (drawControl) has already PushID(cid)'d and opened
    // the disabled scope, so the component widgets only need ids unique within.
    private void drawVec3Control(ref Row row, ref ResolvedControl rc,
                                 string cid, string groupLabel,
                                 InteractiveDispatchFn idispatch)
    {
        float[3] vals = [rc.param.vptr.x, rc.param.vptr.y, rc.param.vptr.z];

        const h = rc.param.hints;
        float step = h.hasStep ? h.step_ : 0.001f;
        string fmt = h.hasFmt  ? h.fmt   : "%.3f";

        // Compact two-column layout for the three rows, closed by a horizontal
        // rule that separates this cluster from the next. No surrounding box: a
        // box requires BeginGroup, whose GroupOffset.x leaks into the cluster's
        // SameLine(fieldColX) and left the fields slightly misaligned vs plain
        // rows. Without the group every field lands on the same column.
        GroupLayout saved = glayout_;
        glayout_ = makeVectorLayout(groupLabel);
        const ImVec2 sp = ImGui.GetStyle().ItemSpacing;
        ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, ImVec2(sp.x, 2.0f));
        scope(exit) { ImGui.PopStyleVar(); glayout_ = saved; ImGui.Separator(); }

        static immutable string[3] comp = ["X", "Y", "Z"];
        foreach (k; 0 .. 3) {
            string scid = format("%s.%d", cid, k);
            auto sc = scid in scratch_;
            if (sc is null) { scratch_[scid] = Scratch.init; sc = scid in scratch_; }
            // Active-item guard: re-seed from the live component only when idle.
            if (!sc.active)
                sc.f = vals[k];

            beginLabeledRow(comp[k]);
            bool changed = ImGui.DragFloat("##" ~ scid, &sc.f, step, 0.0f, 0.0f, fmt);
            sc.active = ImGui.IsItemActive();
            if (changed) {
                float[3] nv = vals;
                nv[k] = sc.f;
                string token = format("%g,%g,%g", nv[0], nv[1], nv[2]);
                writeValue(row, JSONValue(token), idispatch);
            }
            if (ImGui.IsItemDeactivatedAfterEdit() && onTweakEnd_ !is null)
                onTweakEnd_();
        }
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
                    // P-E: a combo selection is a SINGLE discrete tweak (not a
                    // scrub). Open a fresh generation immediately after the write
                    // so a following tweak APPENDS as its own step (G2). Without
                    // this, the interactive-latch path would let the next pipe
                    // tweak coalesce with this enum change.
                    if (onTweakEnd_ !is null) onTweakEnd_();
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
        // Button sits in the value column (left label empty), same width as the
        // input fields, flush right — so a standalone command button (falloff
        // "Reverse") lines up with the fields above it rather than spanning the
        // whole panel.
        string label = row.label.length ? row.label : row.command;
        beginLabeledRow("");
        if (ImGui.Button(label, ImVec2(-float.min_normal, 0)))
            fireLine(row.command, dispatch);
    }

    // -----------------------------------------------------------------------
    // button row — a `group: style: buttons` of `cmd` children laid out as a
    // horizontal strip of EQUAL-width buttons that fills the widget column to
    // the right edge, with a tiny gap between them (the falloff "Auto Size"
    // X/Y/Z row). The group label sits in the left column like any other row.
    // -----------------------------------------------------------------------
    private void drawButtonRow(ref Row row, int rowIdx, DispatchFn dispatch)
    {
        ImGui.PushID(format("btnrow#%d#%s", rowIdx, row.label));
        scope(exit) ImGui.PopID();

        // Count the cmd children (the buttons).
        int n = 0;
        foreach (ref c; row.rows)
            if (c.kind == RowKind.cmd) n++;
        if (n == 0) return;

        // Label left, cursor positioned at the shared field column.
        beginLabeledRow(row.label);

        const float gap   = 2.0f;   // tiny inter-button spacing
        float avail = ImGui.GetContentRegionAvail().x;
        float bw    = (avail - gap * (n - 1)) / n;
        if (bw < 1.0f) bw = 1.0f;

        int i = 0;
        foreach (ref c; row.rows) {
            if (c.kind != RowKind.cmd) continue;
            if (i > 0) ImGui.SameLine(0, gap);
            string lbl = c.label.length ? c.label : c.command;
            if (ImGui.Button(lbl ~ format("##b%d", i), ImVec2(bw, 0)))
                fireLine(c.command, dispatch);
            i++;
        }
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
    // True iff `snapshot` exposes a param named `attr` this frame — the test
    // behind a row's `whenAttr` visibility gate (drawRow).
    private static bool snapshotHasAttr(Param[] snapshot, string attr)
    {
        foreach (ref p; snapshot)
            if (p.name == attr) return true;
        return false;
    }

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
        // style: buttons — a horizontal equal-width button strip, not a framed
        // vector cluster. Routed before the visible-member check (its cmd
        // children always render).
        if (row.groupStyle == GroupStyle.buttons) {
            drawButtonRow(row, rowIdx, dispatch);
            return;
        }

        // Skip the framed box entirely when every member is runtime-hidden —
        // otherwise the channel-split below paints an empty rect + the group
        // label with no controls inside it.
        if (!groupHasVisibleMember(row, snapshot)) return;

        ImGui.PushID(format("group#%d#%s", rowIdx, row.label));
        scope(exit) ImGui.PopID();

        // Compact vector layout, closed by a horizontal rule that separates this
        // group from the next (no box — see drawVec3Control for why a box leaves
        // the fields slightly misaligned). The group label rides the first
        // member's row; members pack with a tighter ItemSpacing.y.
        GroupLayout saved = glayout_;
        glayout_ = makeVectorLayout(row.label);

        const ImVec2 sp = ImGui.GetStyle().ItemSpacing;
        ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, ImVec2(sp.x, 2.0f));

        foreach (i, ref child; row.rows)
            drawRow(child, cast(int) i, snapshot, provider, dispatch, idispatch);

        ImGui.PopStyleVar();
        glayout_ = saved;   // restore for nested groups / following rows

        ImGui.Separator();
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
        // Rebind the namespaced target to the live tool / stage id / layer
        // index (the form carries the canonical family id or a placeholder
        // index; the live one must be written). See forms.rebindBindingTarget.
        // Tool: validateForms' active-id guard; Stage: stacked FalloffStage
        // instances share one form; Layer: the YAML placeholder index is
        // overwritten with the bound layer's live index.
        b = rebindBindingTarget(b, activeToolId_, stageId_, layerIndex_);
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
