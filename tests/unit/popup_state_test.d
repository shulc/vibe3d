// Module unittests for `popup_state`, moved verbatim out of source/popup_state.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.popup_state_test;

import std.algorithm : canFind;
import std.array     : split;
import vibe3d.ui.editor.buttonset : Checked;
import vibe3d.ui.editor.popup_state;

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
unittest {
    // notEquals: button-pressed semantics ("active when state isn't X").
    clearAllState();
    setStatePath("acen/mode", "auto");
    Checked chk;
    chk.present   = true;
    chk.path      = "acen/mode";
    chk.notEquals = "none";
    assert(resolveChecked(chk));        // "auto" != "none"
    setStatePath("acen/mode", "none");
    assert(!resolveChecked(chk));       // "none" == "none"
    setStatePath("acen/mode", "select");
    assert(resolveChecked(chk));        // "select" != "none"
    clearAllState();
}

unittest {
    // contains: comma-list-as-needle = "state is one of these".
    // Pre-existing YAML usage relied on this; fix in popup_state.d
    // makes it actually work.
    clearAllState();
    setStatePath("acen/mode", "select");
    Checked chk;
    chk.present  = true;
    chk.path     = "acen/mode";
    chk.contains = "select,selectauto,element";
    assert(resolveChecked(chk));
    setStatePath("acen/mode", "auto");
    assert(!resolveChecked(chk));
    setStatePath("acen/mode", "element");
    assert(resolveChecked(chk));
    // Single-value contains still works as substring/element match.
    chk.contains = "vertex";
    setStatePath("acen/mode", "vertex,edge");   // multi-valued state
    assert(resolveChecked(chk));
    setStatePath("acen/mode", "polygon");
    assert(!resolveChecked(chk));
    clearAllState();
}

// Task 20262020: the desktop alias and lower producer share one registry.
unittest {
    import vibe3d.editing.pipeline.evaluation.toolpipe.state_paths : lowerSet = setStatePath, lowerGet = getStatePath,
        lowerInstall = installPreparedStatePath, lowerClear = clearAllState;
    static assert(&setStatePath == &lowerSet);
    static assert(&installPreparedStatePath == &lowerInstall);
    lowerClear();
    scope(exit) lowerClear();
    lowerSet("wave5/identity", "ordinary");
    assert(getStatePath("wave5/identity") == "ordinary", "lower publication reaches desktop alias");
    installPreparedStatePath("wave5/identity", "prepared");
    assert(lowerGet("wave5/identity") == "prepared", "desktop prepared overwrite reaches lower registry");
    clearAllState();
    assert(lowerGet("wave5/identity") == "", "desktop reset clears lower registry");
    lowerSet("wave5/identity", "after-reset");
    assert(getStatePath("wave5/identity") == "after-reset", "lower publication resumes after reset");
}
