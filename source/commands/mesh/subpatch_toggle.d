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
    private bool[] origSubpatch;     // pre-apply isSubpatch[] snapshot
    private bool   captured;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "mesh.subpatch_toggle"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons];
    }

    override bool apply() {
        // Subpatch toggles a per-face flag, so the operation is
        // meaningful only when the user is in Polygons mode and can
        // see / curate the face selection. Refuse in other modes so a
        // stale face selection doesn't silently flip the wrong faces.
        if (editMode != EditMode.Polygons)
            throw new Exception(
                "mesh.subpatch_toggle requires Polygons edit mode "
                ~ "(switch via `select.typeFrom polygon` or press 3)");

        // Snapshot just isSubpatch[] — only field we mutate.
        origSubpatch = mesh.isSubpatch.dup;
        captured     = true;

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

    override bool revert() {
        if (!captured) return false;
        mesh.isSubpatch = origSubpatch.dup;
        ++mesh.mutationVersion;
        // isSubpatch[] drives subpatch preview output topology — flag
        // flip ⇒ topology invalidate.
        ++mesh.topologyVersion;
        return true;
    }
}
