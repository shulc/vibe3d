// Popup-button state registry.
//
// Stores string-valued snapshots of arbitrary runtime state under
// slash-separated paths (e.g. `"workplane/auto"`, `"snap/types"`) so
// popup items with a `checked:` block (see buttonset.PopupItem) can
// render a ✓ next to their label when their state matches.
//
// Producers (subsystems whose state ought to be reflected in the UI)
// call `setStatePath(path, value)` whenever the state changes.
// The popup renderer calls `resolveChecked(chk)` once per visible
// item per frame.
//
// The registry is a single global map; access is single-threaded
// (UI thread only). No mutex needed today — when this changes,
// add a synchronisation primitive at the entry points.
module popup_state;

import std.algorithm : canFind;
import std.array     : split;

import buttonset : Checked;

private string[string] g_state;

/// Publish (or overwrite) the value at `path`. Empty string is a
/// valid value — subsystems that want to "clear" should remove the
/// path explicitly via clearStatePath.
void setStatePath(string path, string value) {
    g_state[path] = value;
}

/// Read the current value at `path`, or empty string when unset.
string getStatePath(string path) {
    if (auto p = path in g_state) return *p;
    return "";
}

/// Drop a path entirely (subsequent reads return "").
void clearStatePath(string path) {
    g_state.remove(path);
}

/// Wipe the registry — used by tests and by `/api/reset`.
void clearAllState() {
    g_state.clear();
}

/// Resolve a Checked block against the current registry. False when
/// the block is absent (`!chk.present`) or when neither comparison
/// succeeds.
///
/// `equals` — exact match against `state[path]`.
/// `contains` — either substring match (single-string state) or
///              comma-separated-list element match. The list-mode
///              path lets producers publish multi-valued state
///              (e.g. snap types) as a stable string, and consumers
///              read it as a set without knowing the encoding.
bool resolveChecked(ref Checked chk) {
    if (!chk.present) return false;
    string v = getStatePath(chk.path);
    if (chk.equals_.length > 0)
        return v == chk.equals_;
    if (chk.contains.length > 0) {
        if (v.canFind(chk.contains)) return true;
        return v.split(',').canFind(chk.contains);
    }
    return false;
}
