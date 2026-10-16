// String-valued state snapshots shared by evaluation producers and desktop UI.
// One single-threaded registry owns ordinary publication, prepared overwrite,
// and reset; popup_state re-exports this API for desktop consumers.
// Task 20262030; ownership evidence: doc/application_layers_wave5_model_2026-10-09.md.
module vibe3d.editing.pipeline.evaluation.toolpipe.state_paths;

private string[string] g_state;

/// Publish (or overwrite) the value at `path`. Empty string is a
/// valid value — subsystems that want to "clear" should remove the
/// path explicitly via clearStatePath.
void setStatePath(string path, string value) {
    g_state[path] = value;
}

/// Commit-time counterpart for a prepared transition. Prepared producers run
/// after each stage constructor has published these fixed keys, so install is
/// an overwrite rather than a map-shape change. Any ordinary Exception here
/// is a broken prepared-install invariant, not a recoverable partial commit.
void installPreparedStatePath(string path, string value) nothrow {
    try g_state[path] = value;
    catch (Exception) assert(false);
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
