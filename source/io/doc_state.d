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

// -----------------------------------------------------------------------------
// Unsaved-changes tracking (task 0434).
//
// The document is "dirty" when its content revision differs from the revision
// at the last save / open / new. The revision itself is the change-bus'
// cumulative document-mutation counter (change_bus.docRevision) — this module
// stays dependency-free: app.d reads that counter and feeds it in once per
// frame via syncDocRevision(), AFTER the change-bus flush (so the frame's own
// mesh/layer mutations are already counted).
//
// Rebaseline (mark clean) is DEFERRED, not immediate: a Save leaves geometry
// untouched, but a load / new mutates the mesh and that mutation only reaches
// the counter on the flush that follows the command. Arming a rebaseline and
// applying it on the next sync therefore handles all three uniformly — the
// baseline is taken AFTER the triggering command's mutation has flushed.
//
// Main-thread only, like the current-doc path above.

private ulong g_liveRevision;                 // most recent revision (post-flush)
private ulong g_savedRevision;                // revision at last save/open/new
private bool  g_rebaselineOnNextSync = true;  // armed at startup + by save/load/new

/// Feed the current change-bus document revision; call once per frame AFTER
/// changeBus.flush. Establishes the clean baseline on the first sync after a
/// save / open / new armed a rebaseline (and once at startup, so a freshly
/// launched editor with its default scene reads clean).
void syncDocRevision(ulong rev) {
    g_liveRevision = rev;
    if (g_rebaselineOnNextSync) {
        g_savedRevision = rev;
        g_rebaselineOnNextSync = false;
    }
}

/// Arm the clean baseline: the next syncDocRevision marks the document clean.
/// Called by file save (native .v3d), file open (.v3d), and file new / reset.
void requestDocRebaseline() { g_rebaselineOnNextSync = true; }

/// True when the document has unsaved changes since the last save/open/new.
bool docDirty() { return g_liveRevision != g_savedRevision; }
