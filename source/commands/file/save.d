module commands.file.save;

import std.path : extension;
import std.uni  : toLower;

import nfde;

import command;
import mesh;
import view;
import editmode;
import io.lwo_export : exportLwo;
import io.scene_export : exportViaAssimp;
import io.native : writeV3d;

class FileSave : Command {
    private string explicitPath;  // set via setPath() to skip the dialog

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "File Save"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }   // file output, no mesh state change

    /// Skip the native file dialog and save to the given path.
    /// Used by /api/command params; leave unset for normal user flow.
    void setPath(string p) { explicitPath = p; }

    override bool apply() {
        string path = explicitPath;
        if (path is null) {
            // Native .v3d is the source-of-truth format and the dialog's
            // primary filter; LWO stays a secondary interchange option.
            version (Windows)
                auto result = saveDialog(path,
                    [FilterItem(cast(const(ushort)*)"V3D"w.ptr, cast(const(ushort)*)"v3d"w.ptr),
                     FilterItem(cast(const(ushort)*)"LWO"w.ptr, cast(const(ushort)*)"lwo"w.ptr),
                     FilterItem(cast(const(ushort)*)"OBJ"w.ptr, cast(const(ushort)*)"obj"w.ptr),
                     FilterItem(cast(const(ushort)*)"glTF"w.ptr, cast(const(ushort)*)"gltf"w.ptr),
                     FilterItem(cast(const(ushort)*)"glTF Binary"w.ptr, cast(const(ushort)*)"glb"w.ptr)],
                    "Untitled.v3d");
            else
                auto result = saveDialog(path,
                    [FilterItem("V3D", "v3d"), FilterItem("LWO", "lwo"),
                     FilterItem("OBJ", "obj"), FilterItem("glTF", "gltf"),
                     FilterItem("glTF Binary", "glb")],
                    "Untitled.v3d");
            assert(result != Result.error, getError());
            if (path is null) return false;
        }
        // Dispatch by extension: native .v3d vs. the interchange bridges.
        // Default (unknown / no extension) is native .v3d. The assimp
        // exporters take a format id, not an extension (B4: FBX write is
        // deferred — no .fbx case here).
        switch (extension(path).toLower) {
            case ".lwo":  exportLwo(*mesh, path);                    break;
            case ".obj":  if (!exportViaAssimp(*mesh, path, "obj"))   return false; break;
            case ".gltf": if (!exportViaAssimp(*mesh, path, "gltf2")) return false; break;
            case ".glb":  if (!exportViaAssimp(*mesh, path, "glb2"))  return false; break;
            default:      writeV3d(*mesh, path);                     break;
        }
        return true;
    }
}
