module ui.stat_record;

// ---------------------------------------------------------------------------
// THE DRAWN RECORD for the Statistics panel (task 1100 Stage 4).
//
// Same mechanism, and the same argument, as `ui/availability.d`: a test that
// asks the ROW MODEL what the tree contains proves the row model, and says
// nothing about whether the panel drew it. This records what the draw loop
// ACTUALLY emitted — the cell TEXT included, so the two placeholder glyphs can
// be asserted by their exact characters rather than inferred from a flag — and
// `/api/stats` serves the last complete frame.
//
// `--test`-gated on `command.g_testMode`, so a normal run pays one predictable
// branch per row and allocates nothing. A unittest that wants to read the
// record must set that flag for the block's duration and restore it, or the
// record silently records nothing.
// ---------------------------------------------------------------------------

struct DrawnStatRow {
    string level;      ///< "section" | "category" | "leaf"
    string label;
    string numText;    ///< EXACTLY what the Num cell drew ("6", "—", "" …)
    string selText;    ///< EXACTLY what the Sel cell drew ("4", "...", "" …)
    string avail;      ///< `StatAvail` as a token
    string tone;       ///< "normal" | "dimmed"
    bool   expanded;
    bool   hasActions; ///< were the two action cells drawn at all
    bool   actionsEnabled;  ///< …and were they clickable (false = BeginDisabled)
    string addCommand; ///< the command id the `+` cell would fire, or ""
    string addArgs;    ///< …and its argument object, verbatim
    string removeArgs; ///< the `-` cell's argument object, verbatim
    string reason;     ///< the disabled tooltip, or ""
    bool   tipShown;   ///< did this row ACTUALLY emit its tooltip this frame —
                       ///< read from the hover query itself, NOT copied from the
                       ///< model. `reason` says a tip EXISTS; only this says the
                       ///< screen drew one. A disabled item answers `false` to a
                       ///< flagless `IsItemHovered`, so a row could carry a
                       ///< reason no user was ever able to read while this
                       ///< record reported one — which is exactly what shipped
                       ///< until this field existed. (Measured: the bracket the
                       ///< query sits in is NOT part of that; see the note at
                       ///< the query itself in `ui/panels.d`.)
    float  numX = 0;   ///< screen x of the LEFT edge of the Num slot
    float  selX = 0;   ///< …and of the Sel slot
}

/// The frame's COLUMN GEOMETRY — one record per frame, alongside the rows.
///
/// The rows alone cannot answer "does the header sit over its columns", because
/// the header is not a row: it is drawn before the loop and records nothing. It
/// records here instead, so the two x's can be compared by VALUE rather than by
/// reading the drawing code and believing it.
///
/// `actionW` is the drawn width of ONE action cell. The widget test needs it to
/// press the SECOND action column: a pixel constant there would rot with the
/// font, and the harness's whole row-addressing contract is that no test holds
/// one.
struct DrawnStatFrame {
    float actionW = 0;
    float numX    = 0;   ///< left edge of the HEADER's Num slot
    float selX    = 0;   ///< …and of its Sel slot
}

private __gshared DrawnStatRow[] g_scratch;
private __gshared DrawnStatRow[] g_published;
private __gshared DrawnStatFrame g_frameScratch;
private __gshared DrawnStatFrame g_framePublished;
private __gshared Object         g_mx;

shared static this() { g_mx = new Object(); }

/// Start a fresh recording for one frame's rows.
void beginStatFrame() {
    import command : g_testMode;
    if (!g_testMode) return;
    g_scratch.length = 0;
    g_scratch.assumeSafeAppend();
    g_frameScratch = DrawnStatFrame.init;
}

void recordDrawnStatRow(DrawnStatRow r) {
    import command : g_testMode;
    if (!g_testMode) return;
    g_scratch ~= r;
}

/// Record the frame's column geometry. Called once, from the header block.
void recordDrawnStatFrame(DrawnStatFrame f) {
    import command : g_testMode;
    if (!g_testMode) return;
    g_frameScratch = f;
}

/// Publish the frame just drawn. One assignment under the lock: a reader gets
/// a whole frame or the previous whole frame, never a prefix.
void endStatFrame() {
    import command : g_testMode;
    if (!g_testMode) return;
    synchronized (g_mx) {
        g_published      = g_scratch.dup;
        g_framePublished = g_frameScratch;
    }
}

/// `GET /api/stats` payload — every row of the last complete frame.
///
/// Empty `rows` is the honest answer before the first frame, in a non-`--test`
/// run, and while the panel is closed.
string statRowsJson() {
    import std.json : JSONValue;
    DrawnStatRow[] snap;
    synchronized (g_mx) { snap = g_published.dup; }
    JSONValue[] items;
    foreach (ref r; snap) {
        JSONValue j;
        j["level"]          = JSONValue(r.level);
        j["label"]          = JSONValue(r.label);
        j["num"]            = JSONValue(r.numText);
        j["sel"]            = JSONValue(r.selText);
        j["avail"]          = JSONValue(r.avail);
        j["tone"]           = JSONValue(r.tone);
        j["expanded"]       = JSONValue(r.expanded);
        j["hasActions"]     = JSONValue(r.hasActions);
        j["actionsEnabled"] = JSONValue(r.actionsEnabled);
        j["addCommand"]     = JSONValue(r.addCommand);
        j["addArgs"]        = JSONValue(r.addArgs);
        j["removeArgs"]     = JSONValue(r.removeArgs);
        j["reason"]         = JSONValue(r.reason);
        j["tipShown"]       = JSONValue(r.tipShown);
        items ~= j;
    }
    JSONValue root;
    root["rows"] = JSONValue(items);
    return root.toString();
}

/// In-process read of the last published frame — for the headless widget test,
/// which drives a real draw and then asks what it drew without a wire.
DrawnStatRow[] drawnStatRows() {
    DrawnStatRow[] snap;
    synchronized (g_mx) { snap = g_published.dup; }
    return snap;
}

/// The column geometry of the last published frame — same reader, same lock.
DrawnStatFrame drawnStatFrame() {
    DrawnStatFrame f;
    synchronized (g_mx) { f = g_framePublished; }
    return f;
}
