module commands.mesh.subpatch_toggle;

import command;
import mesh;
import view;
import editmode;

/// Mirror of the Tab-key handler in app.d: toggles isSubpatch on selected
/// faces; if nothing is selected, inverts the flag on every face. Exposed as
/// a Command so it can be invoked through /api/command in tests and through
/// future UI buttons without duplicating the logic.
class SubpatchToggle : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "mesh.subpatch_toggle"; }

    override bool apply() {
        mesh.syncSelection();
        bool any = mesh.hasAnySelectedFaces();
        foreach (fi; 0 .. mesh.faces.length) {
            if (any && !(fi < mesh.selectedFaces.length && mesh.selectedFaces[fi]))
                continue;
            bool cur = fi < mesh.isSubpatch.length && mesh.isSubpatch[fi];
            mesh.setSubpatch(fi, !cur);
        }
        return true;
    }
}
