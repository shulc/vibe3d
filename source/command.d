module command;

import mesh;
import view;
import editmode;

class Command {
    // Human-readable name shown in the UI.
    string name() const { return "Command"; }
    bool apply() { return true; }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        this.mesh = mesh;
        this.view = view;
        this.editMode = editMode;
    }

protected:
    Mesh* mesh;
    View view;
    EditMode editMode;
};