module pie_state;

// One global pie state joins the command opener, SDL event pump and frame
// drawer. Hover is one of eight fixed compass slots; any mouse or delivered
// key release after the tap window closes and runs it, while a short tap leaves
// the menu open.
// Tasks 1800/6208; evidence: doc/tasks/work/6208-pie-menu-reference-parity.md.

/// A tap through 100 ms keeps the pie open; a later release closes and runs.
enum uint kPieTapWindowMs = 100;
enum PieKeyUp { stay, closeAndRun }

PieKeyUp pieKeyUpEffect(uint openStamp, uint stamp) {
    immutable long elapsed = cast(long)stamp - cast(long)openStamp;
    return elapsed <= kPieTapWindowMs ? PieKeyUp.stay
                                      : PieKeyUp.closeAndRun;
}

struct PieState {
    bool   open;        // is a menu up right now
    string menuId;      // which one (id from config/pies.yaml)
    int    cx, cy;      // window pixels — where it opened, i.e. the aim origin
    int    hover = -1;  // slot under the cursor, -1 = dead zone / nothing
    int    unitH;       // button-height unit captured when this opening starts
    uint   openStamp;   // timestamp of the event that opened this pie
    bool   swallowRemainder; // closed pie owns repeats/text until a fresh press
}

__gshared PieState g_pie;

/// Open `menuId` centred on (`x`, `y`) at the current panel-button height.
///
/// Idempotent for the SAME menu: holding a chord repeats KEYDOWN at the OS
/// repeat rate, and re-centring on every repeat would drag the ring along
/// under the cursor for as long as the key is held.
void openPie(string menuId, int x, int y, uint openStamp) {
    if (g_pie.open && g_pie.menuId == menuId) return;
    import ui.button_face : pieButtonUnitH;
    g_pie.open      = true;
    g_pie.menuId    = menuId;
    g_pie.cx        = x;
    g_pie.cy        = y;
    g_pie.hover     = -1;
    g_pie.unitH     = pieButtonUnitH();
    g_pie.openStamp = openStamp;
    g_pie.swallowRemainder = false;
}

void closePie() {
    immutable bool wasOpen = g_pie.open;
    g_pie.open      = false;
    g_pie.menuId    = "";
    g_pie.hover     = -1;
    g_pie.unitH     = 0;
    g_pie.openStamp = 0;
    if (wasOpen) g_pie.swallowRemainder = true;
}

/// Test automation starts a new input context, so no close-gesture latch survives it.
void resetPieForAutomation() {
    closePie();
    g_pie.swallowRemainder = false;
}
