module vibe3d.documents.io.io.file_model;

// One platform file-model value for codec and chooser (task 20261780).
// The chooser reexports this owner; evidence: doc/application_layers_wave1_plan_2026-10-08.md §1E.

version (unittest) {
    private bool g_browserBackendForTest;

    /// Test-only selection of the production browser adapter. Keeping the
    /// switch here lets a real command consumer distinguish its outcomes.
    void selectBrowserBackendForTest(bool enabled) {
        g_browserBackendForTest = enabled;
    }

}

/// The browser file model (task 7400): files live in MEMFS under
/// `io.browser_pick_resume.workRoot()`, an open resumes asynchronously and a
/// save is handed to the browser. True in the web build and under
/// `selectBrowserBackendForTest(true)`; false on the desktop.
bool browserFileModel() {
    version (web) {
        return true;
    } else {
        version (unittest) {
            return g_browserBackendForTest;
        } else {
            return false;
        }
    }
}

