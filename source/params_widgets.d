module params_widgets;

import params : Param, ParamHints;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// Per-kind widget renderers.
//
// Each function returns true when the value changed this frame.
// Extracted from args_dialog.d so both ArgsDialog (modal) and PropertyPanel
// (inline) can share the same rendering logic without duplication.
// ---------------------------------------------------------------------------

bool drawParamWidget(ref Param p) {
    final switch (p.kind) {
        case Param.Kind.Bool:    return drawBool(p);
        case Param.Kind.Int:     return drawInt(p);
        case Param.Kind.Float:   return drawFloat(p);
        case Param.Kind.Enum:    return drawEnum(p);
        case Param.Kind.String:  return drawString(p);
        case Param.Kind.Vec3_:   return drawVec3(p);
        case Param.Kind.IntEnum: return drawIntEnum(p);
        case Param.Kind.IntArray: {
            // No interactive widget — display a read-only count label.
            import std.format : format;
            ImGui.TextDisabled(format("%s: <%d items>", p.label,
                                     (*p.uiaPtr).length));
            return false;
        }
        case Param.Kind.Vec3Array: {
            import std.format : format;
            ImGui.TextDisabled(format("%s: <%d items>", p.label,
                                     (*p.v3aPtr).length));
            return false;
        }
    }
}

bool drawBool(ref Param p) {
    return ImGui.Checkbox(p.label, p.bptr);
}

bool drawInt(ref Param p) {
    const auto h = p.hints;
    int lo = h.hasMinI ? h.minI : 0;
    int hi = h.hasMaxI ? h.maxI : 0;
    if (h.widget == ParamHints.Widget.Slider && h.hasMinI && h.hasMaxI)
        return ImGui.SliderInt(p.label, p.iptr, lo, hi);
    string fmt = "%d";
    // Default DragInt speed: 0.1 unit/pixel (1 step every 10 pixels). The
    // ImGui default of 1.0 was too jumpy for small-range params like
    // `order` (0..16) where each pixel jumped a whole subdivision level.
    // Hold Shift while dragging for ×10 speed (matches ImGui's built-in
    // fast modifier); Alt gives ÷100 fine mode but rounds to the same int.
    return ImGui.DragInt(p.label, p.iptr, 0.1f, lo, hi, fmt);
}

bool drawFloat(ref Param p) {
    const auto h = p.hints;
    float lo   = h.hasMinF ? h.minF : 0.0f;
    float hi   = h.hasMaxF ? h.maxF : 0.0f;
    float step = h.hasStep  ? h.step_ : 0.001f;
    string fmt = h.hasFmt ? h.fmt : "%.3f";
    if (h.widget == ParamHints.Widget.Slider && h.hasMinF && h.hasMaxF)
        return ImGui.SliderFloat(p.label, p.fptr, lo, hi, fmt);
    return ImGui.DragFloat(p.label, p.fptr, step, lo, hi, fmt);
}

bool drawEnum(ref Param p) {
    if (p.hints.widget == ParamHints.Widget.Combo)
        return drawEnumCombo(p);
    return drawEnumRadio(p);
}

private bool drawEnumRadio(ref Param p) {
    bool changed = false;
    ImGui.Text(p.label);
    foreach (i, ref pair; p.enumValues) {
        bool active = (*p.sptr == pair[0]);
        if (ImGui.RadioButton(pair[1], active)) {
            *p.sptr = pair[0];
            changed = true;
        }
        if (i + 1 < p.enumValues.length && p.enumValues.length <= 3)
            ImGui.SameLine();
    }
    return changed;
}

private bool drawEnumCombo(ref Param p) {
    string preview = "?";
    foreach (ref pair; p.enumValues)
        if (*p.sptr == pair[0]) { preview = pair[1]; break; }

    bool changed = false;
    if (ImGui.BeginCombo(p.label, preview)) {
        foreach (ref pair; p.enumValues) {
            bool selected = (*p.sptr == pair[0]);
            if (ImGui.Selectable(pair[1], selected)) {
                *p.sptr = pair[0];
                changed = true;
            }
            if (selected) ImGui.SetItemDefaultFocus();
        }
        ImGui.EndCombo();
    }
    return changed;
}

bool drawString(ref Param p) {
    char[256] buf;
    size_t len = (*p.sptr).length < buf.length - 1 ? (*p.sptr).length : buf.length - 1;
    buf[0 .. len] = (*p.sptr)[0 .. len];
    buf[len] = '\0';

    if (ImGui.InputText(p.label, buf[])) {
        import core.stdc.string : strlen;
        *p.sptr = cast(string)buf[0 .. strlen(buf.ptr)].dup;
        return true;
    }
    return false;
}

bool drawIntEnum(ref Param p) {
    import params : IntEnumEntry;
    if (p.hints.widget == ParamHints.Widget.Combo)
        return drawIntEnumCombo(p);
    return drawIntEnumRadio(p);
}

private bool drawIntEnumRadio(ref Param p) {
    bool changed = false;
    ImGui.Text(p.label);
    foreach (i, ref e; p.intEnumValues) {
        bool active = (*p.iePtr == e.value);
        if (ImGui.RadioButton(e.userLabel, active)) {
            *p.iePtr = e.value;
            changed = true;
        }
        if (i + 1 < p.intEnumValues.length && p.intEnumValues.length <= 3)
            ImGui.SameLine();
    }
    return changed;
}

private bool drawIntEnumCombo(ref Param p) {
    string preview = "?";
    foreach (ref e; p.intEnumValues)
        if (*p.iePtr == e.value) { preview = e.userLabel; break; }

    bool changed = false;
    if (ImGui.BeginCombo(p.label, preview)) {
        foreach (ref e; p.intEnumValues) {
            bool selected = (*p.iePtr == e.value);
            if (ImGui.Selectable(e.userLabel, selected)) {
                *p.iePtr = e.value;
                changed = true;
            }
            if (selected) ImGui.SetItemDefaultFocus();
        }
        ImGui.EndCombo();
    }
    return changed;
}

bool drawVec3(ref Param p) {
    import math : Vec3;
    float step = p.hints.hasStep ? p.hints.step_ : 0.001f;
    string fmt = p.hints.hasFmt ? p.hints.fmt : "%.3f";
    bool cx = ImGui.DragFloat(p.label ~ " X", &p.vptr.x, step, 0, 0, fmt);
    bool cy = ImGui.DragFloat(p.label ~ " Y", &p.vptr.y, step, 0, 0, fmt);
    bool cz = ImGui.DragFloat(p.label ~ " Z", &p.vptr.z, step, 0, 0, fmt);
    return cx || cy || cz;
}
