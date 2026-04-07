module command;

import mesh;
import editmode;

class Command {
    // Human-readable name shown in the UI.
    string name() const { return "Command"; }
    void apply() {}

    this(ref Mesh mesh, EditMode editMode) {
        this.mesh = mesh;
        this.editMode = editMode;
    }

protected:
    Mesh mesh;
    EditMode editMode;
};