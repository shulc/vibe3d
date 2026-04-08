module commands.viewport.fit;

import command;
import mesh;
import editmode;
import view;

import math;

class Fit : Command {
    this(ref Mesh mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "viewport.fit"; }

    override void apply() {
        view.frameToVertices(mesh.vertices);
    }
};

