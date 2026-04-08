module command;

import mesh;
import view;
import editmode;

class Command {
    // Human-readable name shown in the UI.
    string name() const { return "Command"; }
    void apply() {}

    this(ref Mesh mesh, ref View view, EditMode editMode) {
        this.mesh = mesh;
        this.view = view;
        this.editMode = editMode;
    }

protected:
    Mesh mesh;
    View view;
    EditMode editMode;
};