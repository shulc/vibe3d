module io.doc_state;

// Asset-I/O Phase 6 — current-document memory.
//
// Tracks the path of the native (.v3d) document currently being edited so
// that plain File → Save can write without a dialog. Rules (see
// doc/asset_io_plan.md Phase 6):
//
//   * Open (native) and Save As set the current doc path on success.
//   * Save writes to the current doc path when set, else falls back to
//     Save As (a dialog).
//   * Import and Export (interchange: LWO/OBJ/glTF/FBX) do NOT touch the
//     current doc path — importing foreign geometry leaves the native
//     document "untitled", so a later Save still prompts for a .v3d.
//
// Module-level state: there is exactly one open document (single-document
// v1, decision A2). Main-thread only — the menu and the file commands all
// run on the main thread, so reads/writes here are not cross-thread. The
// HTTP file.* commands run on the main thread too: an HTTP file.save of a
// .v3d with an explicit path still writes g_currentDocPath via the shared
// save path.

private string g_currentDocPath;

/// Path of the open native document, or "" when untitled.
string currentDocPath() { return g_currentDocPath; }

/// True when a native document path is remembered (plain Save can skip
/// the dialog).
bool hasCurrentDoc() { return g_currentDocPath.length > 0; }

/// Record the native document path (Open / Save As on success).
void setCurrentDocPath(string p) { g_currentDocPath = p; }

/// Forget the open document (e.g. File → New starts untitled).
void clearCurrentDoc() { g_currentDocPath = null; }
