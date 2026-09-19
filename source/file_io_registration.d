module file_io_registration;

import commands.file.load : FileLoad, FileLoadMode;
import commands.file.save : FileSave, FileSaveMode;
import command : Command;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : CommandFactory, Registry;

/// File-I/O factories resolve the Session mesh and live View/Mode when each
/// command is created. `setPath` bypasses the dialog, so `file.load` retains
/// open framing. A plain foreach-body closure would capture the loop variable
/// by reference and every delegate would see the LAST ext (.fbx); even
/// `immutable ext = importExt;` does NOT create a fresh per-iteration binding.
/// Helper parameters give each closure its own copy (task 5790; evidence:
/// file_io_registration_test).
void registerFileIoCommands(ref Registry reg,
                            LiveSessionRole session,
                            LiveViewModeRole live) {
    reg.registerCommand("file.load", () {
        auto c = new FileLoad(&session.activeMesh(), live.view(), live.mode,
                              session.document());
        c.configure(FileLoadMode.open);
        return cast(Command) c;
    });
    reg.aliasCommand("file.load", "file.open");

    reg.registerCommand("file.save", () {
        auto c = new FileSave(&session.activeMesh(), live.view(), live.mode,
                              session.document());
        c.configure(FileSaveMode.save);
        return cast(Command) c;
    });
    reg.registerCommand("file.saveAs", () {
        auto c = new FileSave(&session.activeMesh(), live.view(), live.mode,
                              session.document());
        c.configure(FileSaveMode.saveAs);
        return cast(Command) c;
    });

    CommandFactory importFactory(string ext) {
        return () {
            auto c = new FileLoad(&session.activeMesh(), live.view(), live.mode,
                                  session.document());
            c.configure(FileLoadMode.importSingle, ext);
            return cast(Command) c;
        };
    }
    foreach (importExt; [".lwo", ".obj", ".gltf", ".fbx"])
        reg.registerCommand("file.import" ~ importExt, importFactory(importExt));

    CommandFactory exportFactory(string ext) {
        return () {
            auto c = new FileSave(&session.activeMesh(), live.view(), live.mode,
                                  session.document());
            c.configure(FileSaveMode.exportSingle, ext);
            return cast(Command) c;
        };
    }
    foreach (exportExt; [".lwo", ".obj", ".gltf", ".fbx"])
        reg.registerCommand("file.export" ~ exportExt, exportFactory(exportExt));
}
