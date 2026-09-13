module file_io_registration;

import commands.file.load : FileLoad, FileLoadMode;
import commands.file.save : FileSave, FileSaveMode;
import command : Command;
import document : Document;
import editmode : EditMode;
import mesh : Mesh;
import registry : CommandFactory, Registry;
import session_owner : Session;
import view : View;

alias LiveFileView = ref View delegate();

struct FileIoSessionRole {
private:
    Session* session_;

public:
    @disable this();

    this(Session* session) {
        assert(session !is null, "file I/O registration requires a Session");
        session_ = session;
    }

    ref Mesh activeMesh() nothrow @nogc {
        return session_.editMesh();
    }

    Document* document() nothrow @nogc {
        return session_.documentPtr();
    }
}

struct LiveFileViewModeRole {
private:
    LiveFileView view_;
    EditMode* mode_;

public:
    @disable this();

    this(LiveFileView view, EditMode* mode) {
        assert(view !is null, "file I/O registration requires a live View");
        assert(mode !is null, "file I/O registration requires a live EditMode");
        view_ = view;
        mode_ = mode;
    }

    ref View view() {
        return view_();
    }

    EditMode mode() const nothrow @nogc {
        return *mode_;
    }
}

/// File-I/O factories resolve the Session mesh and live View/Mode when each
/// command is created. `setPath` bypasses the dialog, so `file.load` retains
/// open framing. A plain foreach-body closure would capture the loop variable
/// by reference and every delegate would see the LAST ext (.fbx); even
/// `immutable ext = importExt;` does NOT create a fresh per-iteration binding.
/// Helper parameters give each closure its own copy (task 5790; evidence:
/// file_io_registration_test).
void registerFileIoCommands(ref Registry reg,
                            FileIoSessionRole session,
                            LiveFileViewModeRole live) {
    reg.commandFactories["file.load"] = () {
        auto c = new FileLoad(&session.activeMesh(), live.view(), live.mode,
                              session.document());
        c.configure(FileLoadMode.open);
        return cast(Command) c;
    };
    reg.commandFactories["file.open"] = reg.commandFactories["file.load"];

    reg.commandFactories["file.save"] = () {
        auto c = new FileSave(&session.activeMesh(), live.view(), live.mode,
                              session.document());
        c.configure(FileSaveMode.save);
        return cast(Command) c;
    };
    reg.commandFactories["file.saveAs"] = () {
        auto c = new FileSave(&session.activeMesh(), live.view(), live.mode,
                              session.document());
        c.configure(FileSaveMode.saveAs);
        return cast(Command) c;
    };

    CommandFactory importFactory(string ext) {
        return () {
            auto c = new FileLoad(&session.activeMesh(), live.view(), live.mode,
                                  session.document());
            c.configure(FileLoadMode.importSingle, ext);
            return cast(Command) c;
        };
    }
    foreach (importExt; [".lwo", ".obj", ".gltf", ".fbx"])
        reg.commandFactories["file.import" ~ importExt] = importFactory(importExt);

    CommandFactory exportFactory(string ext) {
        return () {
            auto c = new FileSave(&session.activeMesh(), live.view(), live.mode,
                                  session.document());
            c.configure(FileSaveMode.exportSingle, ext);
            return cast(Command) c;
        };
    }
    foreach (exportExt; [".lwo", ".obj", ".gltf", ".fbx"])
        reg.commandFactories["file.export" ~ exportExt] = exportFactory(exportExt);
}
