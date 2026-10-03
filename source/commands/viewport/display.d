module commands.viewport.display;

import command;
import commands.viewport.command_base : ViewportCommand;
import mesh;
import editmode;
import view;
import viewport      : ViewportManager, Viewport3D;
import display_state : BackdropStyle, CavityMode, DisplayStyle, MAX_CAVITY_SAMPLES,
    ViewportDisplay, WireOverlay;
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
    /// Which display slot the style is written to: 0 = the active slot (the
    /// default, every existing call shape), 1 = the backdrop slot, which the
    /// `Flat`/`Wireframe` backdrop representations read.
    private int    slotArg_ = 0;

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
            Param.int_("viewport", "Viewport", &cellArg_, -1),
            Param.int_("slot", "Slot", &slotArg_, 0)
        );
    }

    void setRaw(string sval, int cellArg) {
        import std.string : toLower, strip;
        import std.format : format;
        int cell = resolveCellOrThrow(cellArg, name());
        if (slotArg_ != 0 && slotArg_ != 1)
            throw new Exception(format(
                "viewport.displayStyle: slot must be 0 (active) or 1 "
                ~ "(backdrop), got %d", slotArg_));
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
            // The cool-to-warm tone style: lit, and a pass reads it.
            case "gooch":     style_ = DisplayStyle.Gooch;     break;
            // The image-lookup style (env / MatCap): lit, a pass reads it.
            case "reflection": style_ = DisplayStyle.Reflection; break;
            default:
                throw new Exception(
                    "viewport.displayStyle: expected 'wireframe', "
                    ~ "'solid', 'shaded', 'weight', 'gooch' or 'reflection', got '"
                    ~ sval ~ "'");
        }
        cell_ = cell;
    }

    protected override bool applyImpl() {
        setRaw(valueArg_, cellArg_);
        Viewport3D tv = vpm.views[cell_];
        if (slotArg_ == 1) tv.display.backdrop.style = style_;
        else               tv.display.active.style   = style_;
        // Task 0594: this cell's style is now a CHOICE, not an inheritance.
        // Only reached on success — every rejection above throws, so a
        // refused value never marks the cell. Slot 1 is outside the template.
        if (slotArg_ == 1) markCellDisplayDirty(cell_);
        else               commitTemplateChoice(cell_);
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
        commitTemplateChoice(cell_);
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
        commitTemplateChoice(cell_);
        return true;
    }
}

// ---------------------------------------------------------------------------
// viewport.backdropStyle / viewport.retopology — the backdrop representation
// and the retopology display mode, per cell, with the same cell selector as the
// three commands above; neither writes a template field, so both only mark the
// cell dirty and never claim its template (plan §10.13).
//
// `backdropStyle` is a WRITER of the backdrop slot, not a second axis: `flat`
// and `wireframe` set the coarse control AND write the slot's style, and the
// resolver reads the slot (frozen record `tests/fixtures/
// backdrop_display_slots.json`, `coarse_control`). So a later
// `viewport.displayStyle … slot=1` is live under either.
// ---------------------------------------------------------------------------

/// The backdrop control's write: the coarse mode, plus the slot style for the
/// two writer modes. Shared by `viewport.backdropStyle` and the preset, so the
/// preset is data written through the ordinary writer.
private void writeBackdropStyle(ref ViewportDisplay d, BackdropStyle mode)
        pure nothrow @safe @nogc {
    d.backdropStyle = mode;
    if (mode == BackdropStyle.Flat)
        d.backdrop.style = DisplayStyle.Shaded;
    else if (mode == BackdropStyle.Wireframe)
        d.backdrop.style = DisplayStyle.Wireframe;
}

final class ViewportBackdropStyle : ViewportCommand {
    private int cell_;
    private BackdropStyle mode_;
    private string valueArg_;
    private int    cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.backdropStyle"; }

    override Param[] params() {
        return wireArgs(
            Param.string_("value", "Backdrop", &valueArg_, "")
                .aliases(["style"]),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    void setRaw(string sval, int cellArg) {
        import std.string : toLower, strip;
        int cell = resolveCellOrThrow(cellArg, name());
        switch (sval.strip.toLower) {
            case "same":      mode_ = BackdropStyle.SameAsActive; break;
            case "wireframe": mode_ = BackdropStyle.Wireframe;    break;
            case "flat":      mode_ = BackdropStyle.Flat;         break;
            case "hidden":    mode_ = BackdropStyle.Hidden;       break;
            default:
                throw new Exception(
                    "viewport.backdropStyle: expected 'same', 'wireframe', "
                    ~ "'flat' or 'hidden', got '" ~ sval ~ "'");
        }
        cell_ = cell;
    }

    protected override bool applyImpl() {
        setRaw(valueArg_, cellArg_);
        Viewport3D tv = vpm.views[cell_];
        writeBackdropStyle(tv.display, mode_);
        markCellDisplayDirty(cell_);
        return true;
    }
}

final class ViewportRetopology : ViewportCommand {
    private int  cell_;
    private bool on_;
    private string valueArg_;
    private int    cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.retopology"; }

    override Param[] params() {
        return wireArgs(
            Param.string_("value", "Mode", &valueArg_, ""),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    void setRaw(string sval, int cellArg) {
        import std.string : toLower, strip;
        int cell = resolveCellOrThrow(cellArg, name());
        switch (sval.strip.toLower) {
            case "on":  on_ = true;  break;
            case "off": on_ = false; break;
            default:
                throw new Exception(
                    "viewport.retopology: expected 'on' or 'off', got '"
                    ~ sval ~ "'");
        }
        cell_ = cell;
    }

    protected override bool applyImpl() {
        setRaw(valueArg_, cellArg_);
        vpm.views[cell_].display.retopology = on_;
        markCellDisplayDirty(cell_);
        return true;
    }
}

// ---------------------------------------------------------------------------
// viewport.smooth — the cell's normal source (`DisplayState.smooth`, task
// 9070): `on` draws the face VBO's smooth stream, `off` the flat one. Same
// cell selector and `slot` (0 = active, 1 = backdrop) as `viewport.displayStyle`;
// not a template field, so it only marks the cell dirty.
// ---------------------------------------------------------------------------

final class ViewportSmooth : ViewportCommand {
    private string valueArg_;
    private int    cellArg_ = -1;
    private int    slotArg_ = 0;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.smooth"; }

    override Param[] params() {
        return wireArgs(
            Param.string_("value", "Smooth", &valueArg_, ""),
            Param.int_("viewport", "Viewport", &cellArg_, -1),
            Param.int_("slot", "Slot", &slotArg_, 0)
        );
    }

    protected override bool applyImpl() {
        import std.string : toLower, strip;
        import std.format : format;
        immutable int cell = resolveCellOrThrow(cellArg_, name());
        if (slotArg_ != 0 && slotArg_ != 1)
            throw new Exception(format(
                "viewport.smooth: slot must be 0 (active) or 1 (backdrop), got %d",
                slotArg_));
        bool on;
        switch (valueArg_.strip.toLower) {
            case "on":  on = true;  break;
            case "off": on = false; break;
            default:
                throw new Exception(
                    "viewport.smooth: expected 'on' or 'off', got '"
                    ~ valueArg_ ~ "'");
        }
        Viewport3D tv = vpm.views[cell];
        if (slotArg_ == 1) tv.display.backdrop.smooth = on;
        else               tv.display.active.smooth   = on;
        markCellDisplayDirty(cell);
        return true;
    }
}

// ---------------------------------------------------------------------------
// viewport.cavity / viewport.cavityParams — the cell's cavity effect
// (`ViewportDisplay.cavity`, model M4). Non-template fields: they
// only mark the cell dirty. The effect resolves into the plan only under the
// Shaded style with the retopology mode off (`resolveDrawPlan`), so either
// command is accepted in any style and changes nothing visible elsewhere.
// ---------------------------------------------------------------------------

final class ViewportCavity : ViewportCommand {
    private string valueArg_;
    private int    cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.cavity"; }

    override Param[] params() {
        return wireArgs(
            Param.string_("value", "Cavity", &valueArg_, ""),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    protected override bool applyImpl() {
        import std.string : toLower, strip;
        immutable int cell = resolveCellOrThrow(cellArg_, name());
        CavityMode m;
        switch (valueArg_.strip.toLower) {
            case "off":    m = CavityMode.Off;    break;
            case "screen": m = CavityMode.Screen; break;
            case "world":  m = CavityMode.World;  break;
            case "both":   m = CavityMode.Both;   break;
            default:
                throw new Exception("viewport.cavity: expected 'off', 'screen', "
                    ~ "'world' or 'both', got '" ~ valueArg_ ~ "'");
        }
        vpm.views[cell].display.cavity.mode = m;
        markCellDisplayDirty(cell);
        return true;
    }
}

/// `viewport.reflectionSource value:env:<name>|matcap:<name> [viewport]` — the
/// Reflection style's image (`ViewportDisplay.reflection`). A non-template
/// field: it only marks the cell dirty, and resolves into the plan only under
/// the Reflection style. An unknown name is REFUSED (status:error, no history
/// entry), never mapped to a default. A fresh cell (and an automation
/// `scene.reset`) holds `env:kloofendal_48d_partly_cloudy_puresky`.
final class ViewportReflectionSource : ViewportCommand {
    private string valueArg_;
    private int    cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.reflectionSource"; }

    override Param[] params() {
        return wireArgs(
            Param.string_("value", "Source", &valueArg_, ""),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    protected override bool applyImpl() {
        import std.string : toLower, strip;
        import display_state : ReflectionSource;
        import viewport_env : parseReflectionSource;
        immutable int cell = resolveCellOrThrow(cellArg_, name());
        ReflectionSource src;
        if (!parseReflectionSource(valueArg_.strip.toLower, src))
            throw new Exception("viewport.reflectionSource: expected "
                ~ "'env:<name>' or 'matcap:<name>' naming a bundled image, got '"
                ~ valueArg_ ~ "'");
        vpm.views[cell].display.reflection = src;
        markCellDisplayDirty(cell);
        return true;
    }
}

/// `viewport.compositeTestGain <gain> [viewport]` — TEST-ONLY (refused outside
/// --test): the composite resolve's `u_testGain` for one cell, so a suite
/// cell can see the resolve's draw cover the whole cell (an identity resolve
/// leaves the colour unchanged whether or not it drew). Accepted domain
/// [0, kCompositeTestGainMax], finite; anything else is refused.
enum float kCompositeTestGainMax = 4.0f;

final class ViewportCompositeTestGain : ViewportCommand {
    private float gain_ = float.nan;
    private int   cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.compositeTestGain"; }

    override Param[] params() {
        return wireArgs(
            Param.float_("value", "Gain", &gain_, float.nan),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    protected override bool applyImpl() {
        import std.format : format;
        import std.math   : isFinite;
        if (!g_testMode)
            throw new Exception("viewport.compositeTestGain: only available in --test mode");
        if (!isFinite(gain_) || gain_ < 0 || gain_ > kCompositeTestGainMax)
            throw new Exception(format("viewport.compositeTestGain: gain %s outside [0, %s]",
                                       gain_, kCompositeTestGainMax));
        immutable int cell = resolveCellOrThrow(cellArg_, name());
        vpm.views[cell].fbo.compositeTestGain = gain_;
        vpm.views[cell].dirty = true;   // re-render; not display state, so no prefs mirror
        return true;
    }
}

/// The accepted domain of each `viewport.cavityParams` value — the clamp
/// table of `display_state.resolveCavityParams` (which is the kernel's own
/// cap on every other route).
enum float kCavityGainMax    = 250.0f;
enum float kCavityDistanceMin = 1e-4f;
enum float kCavityDistanceMax = 1e5f;
enum float kCavityAttenuationMax = 1e5f;

final class ViewportCavityParams : ViewportCommand {
    // NaN / int.min = "not given": only the named values are written.
    private float screenRidge_ = float.nan, screenValley_ = float.nan;
    private float worldRidge_ = float.nan, worldValley_ = float.nan;
    private float distance_ = float.nan, attenuation_ = float.nan;
    private int   samples_ = int.min;
    private int   cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.cavityParams"; }

    /// Reject contract: a given value outside its range is REFUSED (the whole
    /// command writes nothing), so the Param bounds are UI hints here and the
    /// kernel clamp (`resolveCavityParams`) is the second layer.
    override Param[] params() {
        return wireArgs(
            Param.float_("screenRidge", "Screen Ridge", &screenRidge_, float.nan)
                .min(0.0f).max(kCavityGainMax),
            Param.float_("screenValley", "Screen Valley", &screenValley_, float.nan)
                .min(0.0f).max(kCavityGainMax),
            Param.float_("worldRidge", "World Ridge", &worldRidge_, float.nan)
                .min(0.0f).max(kCavityGainMax),
            Param.float_("worldValley", "World Valley", &worldValley_, float.nan)
                .min(0.0f).max(kCavityGainMax),
            Param.float_("distance", "Distance", &distance_, float.nan)
                .min(kCavityDistanceMin).max(kCavityDistanceMax),
            Param.float_("attenuation", "Attenuation", &attenuation_, float.nan)
                .min(0.0f).max(kCavityAttenuationMax),
            Param.int_("samples", "Samples", &samples_, int.min)
                .min(1).max(MAX_CAVITY_SAMPLES),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    protected override bool applyImpl() {
        import std.format : format;
        import std.math : isNaN;
        immutable int cell = resolveCellOrThrow(cellArg_, name());
        static void check(string what, float v, float lo, float hi) {
            if (isNaN(v)) return;                       // not given
            if (!(v >= lo && v <= hi))                  // also refuses ±inf
                throw new Exception(format(
                    "viewport.cavityParams: %s must lie in [%s, %s], got %s",
                    what, lo, hi, v));
        }
        check("screenRidge",  screenRidge_,  0.0f, kCavityGainMax);
        check("screenValley", screenValley_, 0.0f, kCavityGainMax);
        check("worldRidge",   worldRidge_,   0.0f, kCavityGainMax);
        check("worldValley",  worldValley_,  0.0f, kCavityGainMax);
        check("distance",     distance_, kCavityDistanceMin, kCavityDistanceMax);
        check("attenuation",  attenuation_,  0.0f, kCavityAttenuationMax);
        if (samples_ != int.min && (samples_ < 1 || samples_ > MAX_CAVITY_SAMPLES))
            throw new Exception(format(
                "viewport.cavityParams: samples must lie in [1, %d], got %d",
                MAX_CAVITY_SAMPLES, samples_));
        auto c = &vpm.views[cell].display.cavity;
        if (!isNaN(screenRidge_))  c.screenRidge  = screenRidge_;
        if (!isNaN(screenValley_)) c.screenValley = screenValley_;
        if (!isNaN(worldRidge_))   c.worldRidge   = worldRidge_;
        if (!isNaN(worldValley_))  c.worldValley  = worldValley_;
        if (!isNaN(distance_))     c.distance     = distance_;
        if (!isNaN(attenuation_))  c.attenuation  = attenuation_;
        if (samples_ != int.min)   c.samples      = samples_;
        markCellDisplayDirty(cell);
        return true;
    }
}

// ---------------------------------------------------------------------------
// viewport.showVertices / viewport.pointSize — the cell's vertex-dot switch
// and dot size (`DisplayState.showVertices` / `pointSize`), same cell selector
// as above. Neither is a template field, so both only mark the cell dirty
// (plan §10.13). `pointSize` is clamped twice: the Param's bounds here and
// `display_state.resolvePointSize` where the plan resolves it; 0 = the
// scheme's default size.
// ---------------------------------------------------------------------------

final class ViewportShowVertices : ViewportCommand {
    private int  cell_;
    private bool on_;
    private string valueArg_;
    private int    cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.showVertices"; }

    override Param[] params() {
        return wireArgs(
            Param.string_("value", "Show", &valueArg_, ""),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    protected override bool applyImpl() {
        import std.string : toLower, strip;
        immutable int cell = resolveCellOrThrow(cellArg_, name());
        switch (valueArg_.strip.toLower) {
            case "on":  on_ = true;  break;
            case "off": on_ = false; break;
            default:
                throw new Exception(
                    "viewport.showVertices: expected 'on' or 'off', got '"
                    ~ valueArg_ ~ "'");
        }
        cell_ = cell;
        vpm.views[cell_].display.active.showVertices = on_;
        markCellDisplayDirty(cell_);
        return true;
    }
}

final class ViewportPointSize : ViewportCommand {
    import viewport_scheme : MAX_POINT_SIZE;
    private int   cell_;
    private float size_ = 0.0f;
    private int   cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.pointSize"; }

    override Param[] params() {
        return wireArgs(
            Param.float_("value", "Point Size", &size_, 0.0f)
                .min(0.0f).max(MAX_POINT_SIZE).enforceBounds(),
            Param.int_("viewport", "Viewport", &cellArg_, -1)
        );
    }

    protected override bool applyImpl() {
        cell_ = resolveCellOrThrow(cellArg_, name());
        vpm.views[cell_].display.active.pointSize = size_;
        markCellDisplayDirty(cell_);
        return true;
    }
}

// ---------------------------------------------------------------------------
// viewport.retopologyPreset — the retopology working view in ONE cell: the mode
// on, the backdrop Flat (slot style Shaded, through the backdrop writer above),
// vertex dots on at 6 px. All five are non-template fields, so the preset marks
// the cell dirty once and never claims its template: a later layout switch
// still re-seeds the style (task 8620). The Topology Pen does not arm it.
// ---------------------------------------------------------------------------

/// The preset's dot size, in pixels (the measured working-view atoms).
enum float kRetopologyPresetPointSize = 6.0f;

final class ViewportRetopologyPreset : ViewportCommand {
    private int cellArg_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.retopologyPreset"; }

    override Param[] params() {
        return wireArgs(Param.int_("viewport", "Viewport", &cellArg_, -1));
    }

    protected override bool applyImpl() {
        immutable int cell = resolveCellOrThrow(cellArg_, name());
        Viewport3D tv = vpm.views[cell];
        tv.display.retopology = true;
        writeBackdropStyle(tv.display, BackdropStyle.Flat);
        tv.display.active.showVertices = true;
        tv.display.active.pointSize = kRetopologyPresetPointSize;
        markCellDisplayDirty(cell);
        return true;
    }
}
