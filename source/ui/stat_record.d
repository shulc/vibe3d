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
}

private __gshared DrawnStatRow[] g_scratch;
private __gshared DrawnStatRow[] g_published;
private __gshared Object         g_mx;

shared static this() { g_mx = new Object(); }

/// Start a fresh recording for one frame's rows.
void beginStatFrame() {
    import command : g_testMode;
    if (!g_testMode) return;
    g_scratch.length = 0;
    g_scratch.assumeSafeAppend();
}

void recordDrawnStatRow(DrawnStatRow r) {
    import command : g_testMode;
    if (!g_testMode) return;
    g_scratch ~= r;
}

/// Publish the frame just drawn. One assignment under the lock: a reader gets
/// a whole frame or the previous whole frame, never a prefix.
void endStatFrame() {
    import command : g_testMode;
    if (!g_testMode) return;
    synchronized (g_mx) { g_published = g_scratch.dup; }
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
