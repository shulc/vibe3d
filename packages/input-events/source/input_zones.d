module input_zones;

// ---------------------------------------------------------------------------
// Where the cursor is, as a NAME (task 1810).
//
// A keyboard chord means different things in different places — the reference's
// whole input map is keyed that way, and 111 of its 253 distinct chords are
// bound in more than one place. To answer "which place", something has to know
// the screen rectangles of the panels and viewport cells, and the code that
// already knows them is the code that DRAWS them. So this is a per-frame
// registry the draw pass fills and the event pump reads — the same shape, and
// for the same reason, as `ui/availability.d`'s drawn-button record.
//
// WHY RECTANGLES AND NOT "ASK IMGUI WHICH WINDOW IS HOVERED":
//
//   1. This binding does not expose it. `IsWindowHovered`, `GetWindowPos` and
//      `GetWindowSize` are all absent from d_imgui's curated cimgui subset;
//      only `IsItemHovered` / `GetCursorScreenPos` / `GetContentRegionAvail`
//      exist.
//   2. It would not mean the same thing under `--test`, which is where every
//      automated check of this runs. `--test` does not create the "Viewport"
//      ImGui window at all (app.d, `if (!testMode)`), precisely so that
//      `WantCaptureMouse` stays false over the 3D area — so an ImGui-derived
//      zone would resolve differently in a test than in the shipped app, and
//      the test would be pinning something the user never runs.
//
// Viewport cells therefore publish `vpm.views[k]`'s own rect, which is exact
// and identical in both modes; panels publish the content rect ImGui hands
// them right after `Begin`.
// ---------------------------------------------------------------------------

import std.algorithm : canFind;

/// One named screen rectangle, in WINDOW pixels.
struct Zone {
    string name;
    float  x, y, w, h;

    bool contains(int px, int py) const {
        return px >= x && px < x + w && py >= y && py < y + h;
    }
}

// ---------------------------------------------------------------------------
// The closed set of zone names.
//
// A binding scoped to a zone that no one ever publishes is not a harmless
// typo: it is a binding that silently never matches, and nothing about it
// looks wrong — the config parses, the app runs, the chord just quietly does
// the global thing forever. The loader checks names against this list so the
// mistake is caught the one moment somebody is looking at it.
//
// Adding a zone means adding it here AND publishing it from a draw site;
// either half alone is dead.
// ---------------------------------------------------------------------------
enum string[] kKnownZones = [
    "viewport3d",     // any 3D viewport cell
    "sidePanel",      // the left tool/command panel ("Mesh Info" window)
    "tabPanel",       // the tab strip above the viewport
    "statusBar",      // the bottom status line
    "layerList",      // the Items / Layers panel
    "toolProps",      // Tool Properties
    "history",        // Command History
];

bool isKnownZone(string name) {
    return kKnownZones.canFind(name);
}

// ---------------------------------------------------------------------------
// The per-frame registry.
//
// Double-buffered for the reason `ui/availability.d` is: the writer is the
// draw pass and the reader is the SDL event pump, and the pump runs BEFORE the
// frame that is currently being assembled. A single list cleared at the top of
// drawing would hand the pump a half-built frame — a chord pressed at the
// wrong moment would resolve against whichever panels happened to have drawn
// already. Publishing the whole frame at once means a reader always sees one
// complete, self-consistent layout: this frame's, or the last one's.
//
// Single-threaded (UI thread only), so no lock — same rule as `popup_state`.
// ---------------------------------------------------------------------------
private __gshared Zone[] g_scratch;
private __gshared Zone[] g_live;

/// Start collecting this frame's zones. Called once per frame, before any
/// panel draws.
void beginZoneFrame() {
    g_scratch.length = 0;
    g_scratch.assumeSafeAppend();
}

/// Publish one zone rectangle. Called from the draw site that owns it.
/// Degenerate rects are dropped rather than stored: a collapsed panel has no
/// area to be "over", and keeping a zero-width entry would make `zoneAt`'s
/// last-wins rule depend on invisible things.
void publishZone(string name, float x, float y, float w, float h) {
    if (w <= 0 || h <= 0) return;
    g_scratch ~= Zone(name, x, y, w, h);
}

/// Publish the frame just drawn.
void endZoneFrame() {
    g_live = g_scratch.dup;
}

/// The zone under (`x`, `y`), or "" when the cursor is over none.
///
/// LAST PUBLISHED WINS, and that is the documented rule rather than an
/// accident of iteration order: publication order is draw order, and draw
/// order is z-order, so the last rectangle covering a pixel is the one the
/// user sees there. A floating Tool Properties over the side panel therefore
/// answers "toolProps", which is what the eye says too.
string zoneAt(int x, int y) {
    string found = "";
    foreach (ref z; g_live)
        if (z.contains(x, y))
            found = z.name;
    return found;
}

/// Every zone of the last complete frame — for `/api/input/context` and for
/// diagnosing a binding that will not match.
Zone[] publishedZones() {
    return g_live;
}

/// Drop everything (tests, `/api/reset`).
void clearZones() {
    g_scratch.length = 0;
    g_live.length    = 0;
}
