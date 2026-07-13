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

    override bool apply() {
        // Suppressed in test mode, mirroring commands/file/load.d:108-114 —
        // tests drive the controller directly via the ai3d.generate.start /
        // ai3d.generate.cancel test-only hooks, never through this picker.
        if (command.g_testMode) return false;

        string path = runOpenDialog();
        if (path is null) return false; // user cancelled

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
        return false; // never a document mutation — no undo entry
    }

    override bool revert() { return false; }

    private string runOpenDialog() {
        FilterSpec[] fs = [FilterSpec("Images", "png,jpg,jpeg,webp")];
        string path;
        version (Windows) {
            import std.utf : toUTF16z;
            FilterItem[] items;
            foreach (ref f; fs)
                items ~= FilterItem(cast(const(ushort)*)f.name.toUTF16z,
                                    cast(const(ushort)*)f.spec.toUTF16z);
            auto result = openDialog(path, items);
        } else {
            import std.string : toStringz;
            FilterItem[] items;
            foreach (ref f; fs)
                items ~= FilterItem(f.name.toStringz, f.spec.toStringz);
            auto result = openDialog(path, items);
        }
        assert(result != Result.error, getError());
        return path;
    }
}
