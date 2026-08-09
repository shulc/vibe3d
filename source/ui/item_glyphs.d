module ui.item_glyphs;

// ---------------------------------------------------------------------------
// Task 0639 — the item list's GLYPH SHAPES.
//
// The "which pixels" half of the split `ui/item_rows.d` describes: that module
// decides WHICH glyph a row draws (a named token, headlessly assertable); this
// one decides what that token LOOKS LIKE, which no test here claims to cover.
//
// WHY VECTORS AND NOT A FONT OR AN ATLAS — the Ph0 decision, recorded in full
// at the top of `ui/item_rows.d`. In short: `app.d` loads the vector UI face
// only outside `--test`, so a font glyph would be missing in every test run;
// and the ranges it does load are Latin-1 + Cyrillic + six punctuation points,
// so a pictographic code point would be a blank box in ordinary runs too. A
// bitmap set would need artwork, an atlas, a decode and a GL texture lifetime
// in a panel that owns no GPU resource at all. Draw-list geometry costs
// nothing but this file, and rasterizes identically in both modes because it
// is not text.
//
// THE PRIMITIVE SET IS THE BINDING'S, NOT UPSTREAM IMGUI'S. This project's
// `d_imgui` is a hand-maintained cimgui shim (`D-ImGui/source/d_imgui/`),
// not the full port: `ImDrawList` here offers AddLine / AddRect /
// AddRectFilled / AddCircle / AddCircleFilled / AddTriangleFilled /
// AddQuadFilled / AddPolyline and NOTHING else — no `AddNgon`, no
// `AddTriangle` outline, and the free functions have no `GetColorU32` or
// `ArrowButton`. Every shape below is built from that set on purpose; a
// diamond is two triangles or four lines here, not one call.
//
// EVERY SHAPE IS A TOGGLE OR A STATE THE LIST ACTUALLY HOLDS. There is no
// decorative glyph here — the eye is `layer.setVisible`, the role marker is
// the item selection, the disclosure triangle collapses the root. A cell with
// nothing behind it is not drawn at all (the root's eye cell is left empty
// rather than drawn disabled, see `ItemRow.canToggleVisible`).
//
// COORDINATES. Every function takes the cell's CENTRE in screen space and a
// half-extent `r`; nothing here reads or advances the ImGui cursor, so the
// caller owns layout entirely and these can be drawn over an item that has
// already claimed the row.
// ---------------------------------------------------------------------------

import ImGui = d_imgui;
import d_imgui.imgui_h;

import ui.item_rows : ItemGlyph, RowRole;

// The three metrics below are RATIOS OF THE ROW HEIGHT, not pixel constants.
//
// The panel derives its row height from the live text metrics, which already
// carry the UI scale AND the font swap between a normal run (the scaled vector
// face) and `--test` (ImGui's built-in bitmap font). Expressing the cells as
// fixed pixels would leave the glyphs floating inside oversized rows on a
// HiDPI display and overflowing them under a fractional scale — the exact
// failure the vector UI font was introduced to avoid.

/// The width reserved for one glyph column, in row heights.
enum float kGlyphCellRatio = 1.30f;

/// The half-extent a glyph is drawn at inside its cell, in row heights.
enum float kGlyphRadiusRatio = 0.36f;

/// One indent step, in row heights.
enum float kIndentRatio = 0.85f;

private enum float kThin = 1.0f;

/// A hollow diamond, four lines. `AddNgon` does not exist in this binding.
private void diamondOutline(ImDrawList* dl, ImVec2 c, float r, uint col) {
    immutable ImVec2 n = ImVec2(c.x,     c.y - r);
    immutable ImVec2 e = ImVec2(c.x + r, c.y);
    immutable ImVec2 s = ImVec2(c.x,     c.y + r);
    immutable ImVec2 w = ImVec2(c.x - r, c.y);
    dl.AddLine(n, e, col, kThin);
    dl.AddLine(e, s, col, kThin);
    dl.AddLine(s, w, col, kThin);
    dl.AddLine(w, n, col, kThin);
}

/// The TYPE glyph for a row.
///
/// The four shapes are chosen to stay separable at ten pixels — an outline
/// square, a cross, a picture frame and a folder differ in SILHOUETTE, not
/// only in detail, so they are still told apart when the detail is one pixel
/// wide.
void drawItemGlyph(ImDrawList* dl, ImVec2 c, float r, ItemGlyph g, uint col) {
    if (dl is null) return;
    final switch (g) {
        case ItemGlyph.None:
            break;

        // A folder: the container the whole document hangs in.
        case ItemGlyph.Scene: {
            immutable float tabW = r * 0.85f;
            dl.AddLine(ImVec2(c.x - r,        c.y - r * 0.75f),
                       ImVec2(c.x - r + tabW, c.y - r * 0.75f), col, kThin);
            dl.AddLine(ImVec2(c.x - r + tabW, c.y - r * 0.75f),
                       ImVec2(c.x - r + tabW, c.y - r * 0.30f), col, kThin);
            dl.AddRect(ImVec2(c.x - r, c.y - r * 0.30f),
                       ImVec2(c.x + r, c.y + r * 0.80f),
                       col, 0.0f, 0, kThin);
            break;
        }

        // A quad split by ONE diagonal — a polygon that has been
        // triangulated, which is what a mesh item is.
        //
        // One diagonal and not two, measured on screen: with both, a 13-pixel
        // square reads as a boxed X, i.e. as a close button, which is a worse
        // thing for a row glyph to be mistaken for than almost anything else.
        case ItemGlyph.Mesh: {
            immutable ImVec2 tl = ImVec2(c.x - r, c.y - r);
            immutable ImVec2 br = ImVec2(c.x + r, c.y + r);
            dl.AddRect(tl, br, col, 0.0f, 0, kThin);
            dl.AddLine(ImVec2(c.x - r, c.y + r), ImVec2(c.x + r, c.y - r),
                       col, kThin);
            break;
        }

        // A locator: two axes crossing at a ringed origin. An item with no
        // payload is exactly a place in space, and this is how one is drawn.
        case ItemGlyph.Empty: {
            dl.AddLine(ImVec2(c.x - r, c.y), ImVec2(c.x + r, c.y), col, kThin);
            dl.AddLine(ImVec2(c.x, c.y - r), ImVec2(c.x, c.y + r), col, kThin);
            dl.AddCircle(c, r * 0.45f, col, 10, kThin);
            break;
        }

        // A picture: a frame with a horizon inside it.
        case ItemGlyph.Plane: {
            dl.AddRect(ImVec2(c.x - r, c.y - r * 0.8f),
                       ImVec2(c.x + r, c.y + r * 0.8f),
                       col, 0.0f, 0, kThin);
            dl.AddTriangleFilled(ImVec2(c.x - r * 0.70f, c.y + r * 0.55f),
                                 ImVec2(c.x - r * 0.05f, c.y - r * 0.25f),
                                 ImVec2(c.x + r * 0.60f, c.y + r * 0.55f),
                                 col);
            break;
        }
    }
}

/// The VISIBILITY glyph: an eye, struck through when the item is hidden.
///
/// A LENS, not a ring: measured on screen, a circle with a dot in it reads as
/// a radio button or a target — which is a bad thing for the column a user
/// reaches for most to be mistaken for. The lens is a closed polyline through
/// two parabolic arcs, because this binding's `ImDrawList` has no arc or
/// ellipse primitive at all (see the header note on the primitive set).
///
/// The hidden state is drawn as a MARKED eye rather than an absent one. An
/// empty cell already means "this row has no such control" (the root), so
/// hidden had to be visibly different from that, not merely dimmer.
void drawEyeGlyph(ImDrawList* dl, ImVec2 c, float r, bool visible, uint col) {
    if (dl is null) return;
    immutable float h = r * 0.62f;                 // how far the lens bulges
    // (1 - t²) at t = ±0.5 is 0.75 — the two intermediate points of each arc.
    ImVec2[8] lens = [
        ImVec2(c.x - r,         c.y),
        ImVec2(c.x - r * 0.5f,  c.y - h * 0.75f),
        ImVec2(c.x,             c.y - h),
        ImVec2(c.x + r * 0.5f,  c.y - h * 0.75f),
        ImVec2(c.x + r,         c.y),
        ImVec2(c.x + r * 0.5f,  c.y + h * 0.75f),
        ImVec2(c.x,             c.y + h),
        ImVec2(c.x - r * 0.5f,  c.y + h * 0.75f),
    ];
    enum int kClosed = 1;                          // ImDrawFlags_Closed
    dl.AddPolyline(lens.ptr, cast(int) lens.length, col, kClosed, kThin);
    if (visible)
        dl.AddCircleFilled(c, r * 0.30f, col, 8);
    else
        dl.AddLine(ImVec2(c.x - r, c.y + r), ImVec2(c.x + r, c.y - r),
                   col, kThin);
}

/// The ROLE glyph: how this row stands in the item selection.
///
/// A filled diamond for the mesh edit target, a hollow one for a focus that
/// is not the edit target (only reachable on an item that can never be
/// primary), a dot for plain set membership, nothing at all for a row outside
/// the selection. Three marks for three states the panel genuinely holds —
/// this cell replaces both the old `>`/`@`/`*` text marker AND the "F"
/// checkbox that restated part of it.
void drawRoleGlyph(ImDrawList* dl, ImVec2 c, float r, RowRole role, uint col) {
    if (dl is null) return;
    final switch (role) {
        case RowRole.None:
            break;
        case RowRole.Selected:
            dl.AddCircleFilled(c, r * 0.35f, col, 8);
            break;
        case RowRole.Focus:
            diamondOutline(dl, c, r * 0.9f, col);
            break;
        case RowRole.Primary:
            dl.AddQuadFilled(ImVec2(c.x, c.y - r * 0.9f),
                             ImVec2(c.x + r * 0.9f, c.y),
                             ImVec2(c.x, c.y + r * 0.9f),
                             ImVec2(c.x - r * 0.9f, c.y), col);
            break;
    }
}

/// The root row's collapse triangle: down when expanded, right when not.
void drawDisclosure(ImDrawList* dl, ImVec2 c, float r, bool expanded,
                    uint col) {
    if (dl is null) return;
    if (expanded)
        dl.AddTriangleFilled(ImVec2(c.x - r * 0.7f, c.y - r * 0.4f),
                             ImVec2(c.x + r * 0.7f, c.y - r * 0.4f),
                             ImVec2(c.x,            c.y + r * 0.6f), col);
    else
        dl.AddTriangleFilled(ImVec2(c.x - r * 0.4f, c.y - r * 0.7f),
                             ImVec2(c.x - r * 0.4f, c.y + r * 0.7f),
                             ImVec2(c.x + r * 0.6f, c.y), col);
}
