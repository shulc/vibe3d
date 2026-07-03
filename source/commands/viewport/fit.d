module commands.viewport.fit;

import command;
import mesh;
import editmode;
import view;

import math;

class Fit : Command {
    // The two owner cameras a fit must write to (task 0221). For a default
    // Quad follower both resolve to the group master, so the single fit
    // reframes the whole linked group (visible in every cell); an
    // independently-centered/scaled cell resolves to itself. Split ownership
    // (indCenter=yes, indScale=no, or vice-versa) writes CENTER to the
    // focus-owner and DISTANCE to the scale-owner. Mirrors 0217's owner
    // redirect for pan/zoom. `view` (the base-class camera) IS the scale
    // owner — it supplies the aspect for the frame and receives the distance.
    private View focusCam;

    this(Mesh* mesh, ref View focusCam, ref View scaleCam, EditMode editMode) {
        super(mesh, scaleCam, editMode);
        this.focusCam = focusCam;
    }

    override string name() const { return "viewport.fit"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UI; }   // camera-only

    override bool apply() {
        if (mesh.vertices.length == 0) return true;
        Vec3 c; float d;
        view.computeFrame(mesh.vertices, c, d);   // view == scale owner
        focusCam.focus = c;
        view.distance  = d;
        return true;
    }
};

