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

public import toolpipe.state_paths : setStatePath, installPreparedStatePath,
    getStatePath, clearStatePath, clearAllState;

bool resolveChecked(ref Checked chk) {
    if (!chk.present) return false;
    string v = getStatePath(chk.path);
    if (chk.equals_.length > 0)
        return v == chk.equals_;
    if (chk.notEquals.length > 0)
        return v != chk.notEquals;
    if (chk.contains.length > 0) {
        // YAML "contains: a,b,c" means: true iff `v` is one of {a,b,c}.
        // Comma-split the *needle* (`contains`) and check if `v` is in
        // that list. Fallback: if needle has no comma, also accept
        // substring or list-element match against state.
        if (chk.contains.split(',').canFind(v)) return true;
        if (v.canFind(chk.contains)) return true;
        return v.split(',').canFind(chk.contains);
    }
    return false;
}
