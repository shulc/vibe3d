module live_registration_roles;

import document : Document;
import editmode : EditMode;
import mesh : Mesh;
import session_owner : Session;
import view : View;

/// Shared registration roles retain only the Session pointer and live
/// View/EditMode sources; every consumer resolves them at command creation.
/// This is the task-5790 role under its cross-family name (task 5980; evidence:
/// file_io_registration_test and tool_lifecycle_registration_test).
alias LiveView = ref View delegate();

struct LiveSessionRole {
private:
    Session* session_;

public:
    @disable this();

    this(Session* session) {
        assert(session !is null, "live registration requires a Session");
        session_ = session;
    }

    ref Mesh activeMesh() nothrow @nogc {
        return session_.editMesh();
    }

    Document* document() nothrow @nogc {
        return session_.documentPtr();
    }
}

struct LiveViewModeRole {
private:
    LiveView view_;
    EditMode* mode_;

public:
    @disable this();

    this(LiveView view, EditMode* mode) {
        assert(view !is null, "live registration requires a live View");
        assert(mode !is null, "live registration requires a live EditMode");
        view_ = view;
        mode_ = mode;
    }

    ref View view() {
        return view_();
    }

    EditMode mode() const nothrow @nogc {
        return *mode_;
    }

    EditMode* modeCell() nothrow @nogc {
        return mode_;
    }
}
