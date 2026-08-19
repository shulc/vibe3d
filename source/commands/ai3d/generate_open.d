module commands.ai3d.generate_open;

// ---------------------------------------------------------------------------
// Ai3dGenerateOpen — `ai3d.generate.open` (task 0381 Phase 3,
// doc/ai3d_ui_plan.md). The `File > Generate 3D…` menu action.
//
// ZERO params (so app.d's dispatchAction/tryOpenArgsDialog does NOT pop the
// generic args dialog — it runs directly on click, exactly like file.open).
// apply() opens a native single-image picker (PNG/JPEG/WebP; reuses the
// nfde pattern from commands/file/load.d) and, on a chosen file, hands the
// path to `onPicked` — which app.d wires to store it + open the compact
// modal (ai3dModalOpen = true) and kick off a health probe. It NEVER runs
// the blocking generate transfer inline — that only ever happens on the
// Ai3dJobController's worker thread once the user clicks Generate in the
// modal.
//
// apply() ALWAYS returns false: opening a picker/modal is not a document
// mutation, so no undo entry is recorded (mirrors ToolBeginSessionCommand /
// UiToolPropertiesCommand's CmdFlags.SideEffect intent, but here even
// simpler since there is genuinely nothing to revert).
// ---------------------------------------------------------------------------

import std.conv  : to;
import std.file  : getSize;
import std.path  : extension;
import std.uni   : toLower;

import nfde;

import command;
import mesh;
import view;
import editmode;
import params : Param;
import io.formats : FilterSpec;
import io.file_dialog : pickOpenPath, PickResult, PickOutcome;
import log : logWarn;

/// Client-side pre-check only (fail fast with a clear message rather than
/// uploading an oversized file and getting a worker-side 400) — mirrors the
/// worker protocol's own `MAX_INPUT_BYTES` (tools/ai3d_worker/
/// vibe3d_ai3d_worker/protocol.py). The worker remains the authoritative
/// enforcer; this is purely a UX nicety.
enum Ai3dMaxPickedImageBytes = 20 * 1024 * 1024;

final class Ai3dGenerateOpen : Command {
    private void delegate(string imagePath) onPicked;

    this(Mesh* mesh, ref View view, EditMode editMode, void delegate(string) onPicked) {
        super(mesh, view, editMode);
        this.onPicked = onPicked;
    }

    override string name()  const { return "ai3d.generate.open"; }
    override string label() const { return "Generate 3D…"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() { return []; } // zero params — see module doc

    /// WHY the last apply() declined — "" for a cancel and for the SUCCESS
    /// path too (see the `return false` at the end: this command deliberately
    /// records no undo entry even when it picked a file, so `false` here does
    /// NOT mean "refused"). Non-empty only when the chooser could not run.
    override string refusalReason() const { return refusal_; }
    private string refusal_;

    override bool apply() {
        refusal_ = null;
        // `--test` suppression now lives in the shared chooser
        // (`io/file_dialog.d` checks `g_testMode` first and never touches
        // nfde), so this reaches `PickOutcome.unavailable` and returns without
        // opening anything — same behaviour, one implementation.
        auto pick = runOpenDialog();
        if (pick.outcome != PickOutcome.chosen) {
            // Cancel is silent; `unavailable` / `failed` speak.
            refusal_ = pick.refusalReason();
            return false;
        }
        string path = pick.path;

        const ext = extension(path).toLower;
        if (ext != ".png" && ext != ".jpg" && ext != ".jpeg" && ext != ".webp") {
            try logWarn("ai3d", "generate.open: unsupported image type: " ~ path);
            catch (Exception) {}
            return false;
        }

        ulong size;
        try size = getSize(path);
        catch (Exception) { size = 0; }
        if (size == 0 || size > Ai3dMaxPickedImageBytes) {
            try logWarn("ai3d", "generate.open: image is empty or exceeds the "
                ~ (Ai3dMaxPickedImageBytes / (1024 * 1024)).to!string ~ " MiB limit: " ~ path);
            catch (Exception) {}
            return false;
        }

        if (onPicked !is null) onPicked(path);
        // TASK 1520, M4 — THIS `false` IS DELIBERATE AND STAYS. It is not a
        // refusal: the pick SUCCEEDED and the modal has been handed the path.
        // Returning true would give this command an undo entry it is designed
        // not to have. `refusalReason()` is "" here, so the UI notice path
        // (which is driven by the reason, not by the bool) stays silent.
        return false; // never a document mutation — no undo entry
    }

    // Task 1520: the shared chooser. Its `assert(result != Result.error)`
    // predecessor abort()ed the process on a session with no D-Bus.
    private PickResult runOpenDialog() {
        FilterSpec[] fs = [FilterSpec("Images", "png,jpg,jpeg,webp")];
        return pickOpenPath(fs);
    }
}
