module commands.viewport.fit;

import command;
import mesh;
import editmode;
import view;
import document : Document;

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
    // TASK 1880 — nullable document, same shape and same reason as
    // `FitSelected`'s: "fit ALL" means the whole SCENE, and a scene is layers.
    // Null keeps the pre-1880 active-layer-only behaviour for bare callers.
    private Document* doc_;

    this(Mesh* mesh, ref View focusCam, ref View scaleCam, EditMode editMode,
         Document* doc = null) {
        super(mesh, scaleCam, editMode);
        this.focusCam = focusCam;
        this.doc_     = doc;
    }

    override string name() const { return "viewport.fit"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UI; }   // camera-only

    override bool apply() {
        // TASK 1880 — every VISIBLE layer, in world space, not just the active
        // layer's local mesh. `viewport.fit` is "fit all", and with more than
        // one layer in the scene the old body framed whichever one happened to
        // be the edit target while the rest sat off screen — and framed it in
        // LOCAL space, so an item-transformed layer was mis-centred by exactly
        // its own offset.
        //
        // Unlike `fit_selected` this arm is NOT gated on the selection type: A
        // means the same thing in every mode. Visible-only (not
        // selected-only) is the whole point of the "all" variant; the
        // selection is what the Shift+A sibling reads.
        //
        // Same world-space pair as `fit_selected` and as `editor_app.d`'s item
        // frame: `xform.composedMatrix()` + `transformPoint`.
        Vec3[] verts;
        if (doc_ !is null && doc_.layers.length > 0) {
            foreach (l; doc_.layers) {
                if (l is null || !l.visible) continue;
                auto mp = l.meshOrNull;
                if (mp is null || mp.vertices.length == 0) continue;
                immutable float[16] M = l.xform.composedMatrix();
                verts.reserve(verts.length + mp.vertices.length);
                foreach (v; mp.vertices)
                    verts ~= transformPoint(M, v);
            }
        } else {
            if (mesh.vertices.length == 0) return true;
            verts = mesh.vertices.dup;
        }
        if (verts.length == 0) return true;
        Vec3 c; float d;
        view.computeFrame(verts, c, d);   // view == scale owner
        focusCam.focus = c;
        view.distance  = d;
        return true;
    }
};

