module commands.viewport.display;

import command;
import commands.viewport.command_base : ViewportCommand;
import mesh;
import editmode;
import view;
import viewport      : ViewportManager, Viewport3D;
import display_state : DisplayStyle, WireOverlay;
import params : Param, wireArgs;

// TASK 4062 — the three commands below each declare their two arguments
// (`value`, then the `viewport` cell selector) and let `command_args.bindArgs`
// fill them in that order. What used to fill them was a shared "Law 2" scan in
// the HTTP dispatcher that read a scalar of any type from the first positional,
// a bare body, or one of five named aliases. The aliases survive as
// `Param.aliases` so the wire contract is unchanged; the scan does not.
//
// The VALIDATION did not move an inch — `setRaw` still owns every message —
// but it now runs from `applyImpl` rather than from the dispatcher's injector.
// That is the same observable answer on both routes (an exception escaping the
// dispatch is `status:error` either way), and it is what lets the argument
// arrive through a declaration instead of a cast.

// ---------------------------------------------------------------------------
// viewport.displayStyle / wireOverlay / wireAlpha — per-cell display state
// (task 0559 Phase 2), registered as commands (task 0761; previously
// intercepted ahead of the registry). Camera-class commands: they touch no
// document state, so no undo entry (`ViewportCommand`'s `CmdFlags.UI`),
// exactly like `viewport.indCenter` and siblings.
//
// TWO THINGS HERE ARE DIFFERENT FROM EVERY OTHER `viewport.*` COMMAND, and
// both are deliberate — carried forward verbatim from the original
// interception's comment.
//
// 1. A CELL SELECTOR. `viewport.view`/`indCenter` etc. all hardwire the
//    active cell. Display style is the first genuinely PER-CELL render
//    input, so "set the style on a cell that is not the active one" has to
//    be expressible — without it, the isolation property (a style change
//    reaches exactly one cell) is not testable at all. Defaults to
//    `vpm.activeId`, so every existing call shape is unchanged.
//
// 2. UNCONSUMED ENUM VALUES ARE REJECTED, NOT ACCEPTED. The display enums
//    are declared wider than the renderer currently honours, on purpose, so
//    the value space is right from the start. A command that accepts a
//    value and then renders something else is worse than one that refuses
//    it — the parse below accepts exactly the values a pass actually reads
//    today, and names what is missing for the rest.
// ---------------------------------------------------------------------------

final class ViewportDisplayStyle : ViewportCommand {
    private int cell_;
    private DisplayStyle style_;
    private string valueArg_;
    private int    cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.displayStyle"; }

    /// `sval`/`cellArg` as extracted by the shared Law-2 scan in
    /// `http_providers.d` (alias list `value`/`style`/`wire`/`overlay`/
    /// `alpha`, plus the `viewport` cell key). Throws — same messages,
    /// verbatim — on an out-of-range cell or an unrecognised value.
    override Param[] params() {
        return wireArgs(
            Param.string_("value", "Style", &valueArg_, "")
                .aliases(["style", "wire", "overlay", "alpha"]),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    void setRaw(string sval, int cellArg) {
        import std.string : toLower, strip;
        int cell = resolveCellOrThrow(cellArg, name());
        switch (sval.strip.toLower) {
            case "wireframe": style_ = DisplayStyle.Wireframe; break;
            case "shaded":    style_ = DisplayStyle.Shaded;    break;
            // Task 0589: 'solid' used to be refused here, and the refusal
            // said exactly what was missing — "an unlit surface needs a
            // shader uniform that does not exist". That uniform now exists
            // (`u_lit` in shader.d) and the face pass reads
            // `DrawPlan.facesLit`, so the value is consumed.
            case "solid":     style_ = DisplayStyle.Solid;     break;
            // Task 1090: the weight-map surface. Accepted under the same rule
            // the block above states — a pass DOES read it. With no map
            // selected it draws the measured neutral, which is not a
            // placeholder: it is the measured "no map selected" surface.
            case "weight":    style_ = DisplayStyle.Weight;    break;
            default:
                throw new Exception(
                    "viewport.displayStyle: expected 'wireframe', "
                    ~ "'solid', 'shaded' or 'weight', got '" ~ sval ~ "'");
        }
        cell_ = cell;
    }

    protected override bool applyImpl() {
        setRaw(valueArg_, cellArg_);
        Viewport3D tv = vpm.views[cell_];
        tv.display.active.style = style_;
        // Task 0594: this cell's style is now a CHOICE, not an inheritance.
        // Only reached on success — every rejection above throws, so a
        // refused value never marks the cell.
        commitCellDisplay(cell_);
        return true;
    }
}

final class ViewportWireOverlay : ViewportCommand {
    private int cell_;
    private WireOverlay mode_;
    private string valueArg_;
    private int    cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.wireOverlay"; }

    override Param[] params() {
        return wireArgs(
            Param.string_("value", "Overlay", &valueArg_, "")
                .aliases(["style", "wire", "overlay", "alpha"]),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    void setRaw(string sval, int cellArg) {
        import std.string : toLower, strip;
        int cell = resolveCellOrThrow(cellArg, name());
        switch (sval.strip.toLower) {
            case "none":    mode_ = WireOverlay.None;    break;
            case "uniform": mode_ = WireOverlay.Uniform; break;
            case "colored":
                throw new Exception(
                    "viewport.wireOverlay: 'colored' needs a "
                    ~ "per-item line colour that no layer carries "
                    ~ "yet, and the colour source is still an open "
                    ~ "question. Refusing rather than guessing.");
            default:
                throw new Exception(
                    "viewport.wireOverlay: expected 'none' or "
                    ~ "'uniform', got '" ~ sval ~ "'");
        }
        cell_ = cell;
    }

    protected override bool applyImpl() {
        setRaw(valueArg_, cellArg_);
        Viewport3D tv = vpm.views[cell_];
        tv.display.active.wire = mode_;
        commitCellDisplay(cell_);
        return true;
    }
}

final class ViewportWireAlpha : ViewportCommand {
    private int cell_;
    private float alpha_;
    private string valueArg_;
    private int    cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.wireAlpha"; }

    /// `haveNum`/`nval` are the Law-2 scan's numeric-scalar result; `sval`
    /// is its string result. A string that parses as a number is accepted
    /// too — verbatim fallback from the original interception.
    override Param[] params() {
        return wireArgs(
            Param.string_("value", "Opacity", &valueArg_, "")
                .aliases(["style", "wire", "overlay", "alpha"]),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    void setRaw(string sval, int cellArg, bool haveNum, double nval) {
        import std.string : strip;
        import std.conv   : to, ConvException;
        import std.format : format;
        int cell = resolveCellOrThrow(cellArg, name());
        if (!haveNum && sval.length > 0) {
            try { nval = to!double(sval.strip); haveNum = true; }
            catch (ConvException) { /* reported below */ }
        }
        if (!haveNum)
            throw new Exception(
                "viewport.wireAlpha: expected a number in 0..1");
        if (nval < 0.0 || nval > 1.0)
            throw new Exception(format(
                "viewport.wireAlpha: %.4f is outside 0..1", nval));
        alpha_ = cast(float)nval;
        cell_  = cell;
    }

    protected override bool applyImpl() {
        // A numeric argument reaches the String slot as its own spelling, and
        // the `!haveNum && sval.length > 0` arm below has always parsed that —
        // it was the "a string that parses as a number is accepted too"
        // fallback the original interception carried.
        setRaw(valueArg_, cellArg_, false, 0);
        Viewport3D tv = vpm.views[cell_];
        tv.display.active.wireAlpha = alpha_;
        commitCellDisplay(cell_);
        return true;
    }
}
