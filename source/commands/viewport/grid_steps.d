module commands.viewport.grid_steps;

import command;
import commands.viewport.command_base : ViewportCommand;
import mesh;
import editmode;
import view;
import viewport : ViewportManager;

/// `viewport.gridSteps <mask>` — the grid's mantissa ladder (task 0570),
/// registered as a command (task 0761; previously intercepted ahead of the
/// registry). APPLICATION-WIDE, so no cell selector: the ladder is one
/// setting and a cell's grid differs from its neighbour's only through its
/// own zoom.
///
/// Accepts the mask as a number 0..7, or as the rung set spelled out
/// ("1,2,5,10"). The second form exists because the number is a bit set and
/// unreadable at a call site, and because it is what the panel shows — a
/// test and a UI naming the same thing the same way is worth the parse.
///
/// Out of range is an ERROR, not a clamp: 8 is not a coarser 7, it is a
/// value with no ladder behind it.
final class ViewportGridSteps : ViewportCommand {
    private int mask_;

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.gridSteps"; }

    /// `sval`/`mval` as extracted by the Law-2 scan (alias list `value`/
    /// `mask`/`steps`/`rungs`) in `http_providers.d`. Throws — same
    /// messages, verbatim — on an unparseable or out-of-range mask.
    void setRaw(string sval, long mval) {
        import std.string  : strip, split, join;
        import std.conv    : to, ConvException;
        import std.format  : format;
        import viewgrid    : kGridMaskMin, kGridMaskMax, gridRungs;

        if (sval.length > 0 && mval == long.min) {
            immutable string s = sval.strip;
            // Plain number in a string ("5"), else a rung set.
            try { mval = to!long(s); }
            catch (ConvException) {
                // Match the spelled-out set against the eight ladders.
                string canon(const(double)[] r) {
                    string[] parts;
                    foreach (v; r) {
                        // 2.5 keeps its decimal; the rest print whole.
                        parts ~= (v == cast(double)cast(long)v)
                                 ? format("%d", cast(long)v)
                                 : format("%.1f", v);
                    }
                    return parts.join(",");
                }
                string want;
                foreach (piece; s.split(",")) want ~= (want.length ? "," : "") ~ piece.strip;
                foreach (m; kGridMaskMin .. kGridMaskMax + 1)
                    if (canon(gridRungs(m)) == want) { mval = m; break; }
                if (mval == long.min)
                    throw new Exception(format(
                        "viewport.gridSteps: '%s' is neither a mask 0..7 "
                        ~ "nor one of the eight rung sets (e.g. \"1,2,5,10\")", s));
            }
        }

        if (mval == long.min)
            throw new Exception(
                "viewport.gridSteps: expected a mask 0..7 or a rung set");
        if (mval < kGridMaskMin || mval > kGridMaskMax)
            throw new Exception(format(
                "viewport.gridSteps: %d is outside 0..7 — the mask is a "
                ~ "3-bit SET (bit 0 admits 2, bit 1 admits 2.5, bit 2 "
                ~ "admits 5), so out-of-range is refused rather than "
                ~ "clamped to a ladder that was not asked for", mval));

        mask_ = cast(int)mval;
    }

    protected override bool applyImpl() {
        import viewgrid : g_viewGrid;
        import prefs    : g_prefs;

        g_viewGrid.rungMask  = mask_;
        g_prefs.gridStepMask = mask_;

        // Every cell must re-render: the grid step is not part of any
        // cell's camera, so without this a cell keeps re-blitting its
        // cached texture and the ladder change appears to do nothing until
        // that cell's camera happens to move.
        foreach (k; 0 .. vpm.views.length) vpm.views[k].dirty = true;
        return true;
    }
}
