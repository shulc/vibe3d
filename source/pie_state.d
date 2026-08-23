module pie_state;

// ---------------------------------------------------------------------------
// Live state of the open pie menu (task 1800).
//
// One menu at a time, so this is a single global rather than a member of some
// panel: the opener is a command (which may `apply()` on the HTTP thread), the
// hover updater is the SDL event pump, and the drawer is the frame loop — the
// same three-reader shape `commands/ui/about.d`'s `g_aboutShown` already has,
// and for the same reason it is `__gshared`.
//
// THE RING IS HELD OPEN, AND ONLY A CLICK SELECTS.
//
//   * The chord opens it and KEEPS it open. Releasing either half of that
//     chord DISMISSES it — a release never selects, however the ring was
//     aimed at the moment it happened.
//   * A wedge runs when it is CLICKED, which therefore happens while the
//     chord is still held down.
//
// That is why the state carries the chord (`armedKey` / `armedMods`): a key
// release only means "dismiss" for the key that opened this ring, and every
// other release passing through must be ignored. A menu opened some other way
// (`/api/command ui.pie viewport`, a button) has `armedKey == 0`, has no chord
// to release, and so waits for a click or for Esc — which is also what lets a
// test drive the click path without holding anything.
// ---------------------------------------------------------------------------

import pie_geometry : sectorAt, PIE_DEAD_ZONE_PX;

struct PieState {
    bool   open;        // is a menu up right now
    string menuId;      // which one (id from config/pies.yaml)
    int    cx, cy;      // window pixels — where it opened, i.e. the aim origin
    int    itemCount;   // wedges in the open menu, cached for hit-testing
    int    hover = -1;  // slot under the cursor, -1 = dead zone / nothing

    // The chord that opened it; 0 when it was not opened by a chord.
    uint   armedKey;    // SDL_Keycode of the non-modifier key
    ushort armedMods;   // SDL_Keymod bits the binding required
}

__gshared PieState g_pie;

/// Open `menuId` centred on (`x`, `y`) with `itemCount` wedges.
///
/// Idempotent for the SAME menu: holding a chord repeats KEYDOWN at the OS
/// repeat rate, and re-centring on every repeat would drag the ring along
/// under the cursor for as long as the key is held.
void openPie(string menuId, int x, int y, int itemCount) {
    if (g_pie.open && g_pie.menuId == menuId) return;
    g_pie.open      = true;
    g_pie.menuId    = menuId;
    g_pie.cx        = x;
    g_pie.cy        = y;
    g_pie.itemCount = itemCount;
    g_pie.hover     = -1;
    g_pie.armedKey  = 0;
    g_pie.armedMods = 0;
}

/// Record the chord that opened the menu, so its release can commit.
/// Called from the keyboard dispatcher, the one place the keysym is known.
void armPie(uint key, ushort mods) {
    if (!g_pie.open) return;
    g_pie.armedKey  = key;
    g_pie.armedMods = mods;
}

void closePie() {
    g_pie.open      = false;
    g_pie.menuId    = "";
    g_pie.hover     = -1;
    g_pie.itemCount = 0;
    g_pie.armedKey  = 0;
    g_pie.armedMods = 0;
}

/// Re-aim at window position (`x`, `y`). Returns the slot now under the
/// cursor (-1 inside the dead zone).
int aimPie(int x, int y) {
    if (!g_pie.open) return -1;
    g_pie.hover = sectorAt(cast(float)(x - g_pie.cx), cast(float)(y - g_pie.cy),
                           g_pie.itemCount, PIE_DEAD_ZONE_PX);
    return g_pie.hover;
}
