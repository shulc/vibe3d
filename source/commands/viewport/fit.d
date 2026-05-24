module commands.viewport.fit;

import command;
import mesh;
import editmode;
import view;

import math;

class Fit : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "viewport.fit"; }
    override bool isUndoable() const { return false; }   // camera-only

    override bool apply() {
        view.frameToVertices(mesh.vertices);
        return true;
    }
};

