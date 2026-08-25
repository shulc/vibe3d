module commands.viewport.fit_selected;

import command;
import mesh;
import editmode;
import view;
import document : Document, Layer;
import seltype  : SelType;

import math;

class FitSelected : Command {
    // Owner cameras a fit writes to — see commands.viewport.fit for the full
    // rationale (task 0221). `view` (base-class camera) == scale owner
    // (aspect + distance); `focusCam` receives the framed center.
    private View focusCam;
    // TASK 1880 — the item-mode arm needs the DOCUMENT, not just the primary
    // mesh: "fit the selection" in Items mode means every selected layer, and
    // each one's geometry sits in ITS OWN local space (the per-item transform
    // is not baked — it is a display matrix, see document.d).
    //
    // Nullable, and the arm is skipped when it is null: a unittest or headless
    // caller that constructs this class bare keeps the exact pre-1880
    // behaviour. The current selection TYPE needs no plumbing at all —
    // `Command.currentType()` is already wired onto every registered factory
    // (registration.d's `withSelType` wrap), and its unwired fallback
    // `geometrySelType(editMode)` cannot return `Item`, so an unwired command
    // takes the geometry arms by construction rather than by a second check.
    private Document* doc_;

    this(Mesh* mesh, ref View focusCam, ref View scaleCam, EditMode editMode,
         Document* doc = null) {
        super(mesh, scaleCam, editMode);
        this.focusCam = focusCam;
        this.doc_     = doc;
    }

    override string name() const { return "viewport.fit_selected"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UI; }   // camera-only

    protected override bool applyImpl() {
        // Frame selected (or whole mesh if nothing selected).
        //
        // Perf (task 0388): the per-element selection tests below MUST use the
        // non-allocating scalar accessors (`isVertexSelected`/`isEdgeSelected`/
        // `isFaceSelected`), NOT the `mesh.selectedX[i]` @property. The latter
        // materializes a fresh `bool[]` snapshot of the whole marks array on
        // EVERY index — inside a `0 .. length` loop that is O(n²) and cost ~6 s
        // on a 100 K-face mesh. `verts.reserve` up front also drops the append
        // churn on the whole-mesh path.
        Vec3[] verts;
        verts.reserve(mesh.vertices.length);

        // ---- Items ---------------------------------------------------------
        // TASK 1880. `EditMode` has no `Item` member — it is the GEOMETRY half
        // of the selection type (see seltype.d), so under Items it still holds
        // whatever geometry mode was last current. That is exactly how this
        // command used to frame the primary layer's LOCAL cube while the user
        // had two transformed items selected: measured live before the fix,
        // focus stayed at the origin and the distance sat on ONE unit cube.
        //
        // So the item arm is keyed on `currentSelType()`, the authority, and
        // never on `editMode`.
        //
        // World space, per layer: `xform.composedMatrix()` + `transformPoint`,
        // the same pair `editor_app.d`'s own item-frame builder uses (and, like
        // it, WITHOUT composing ancestors — parenting is not folded in at that
        // site either, so a fit and the frame it draws agree).
        //
        // Empty selection ⇒ every visible layer, which is the reference's
        // standing "nothing selected means everything is active" rule and also
        // what keeps Shift+A useful right after a deselect.
        if (doc_ !is null && currentType() == SelType.Item) {
            auto doc = doc_;
            if (doc.layers.length > 0) {
                bool anySelected = false;
                foreach (l; doc.layers)
                    if (l !is null && l.selected) { anySelected = true; break; }
                foreach (l; doc.layers) {
                    if (l is null) continue;
                    if (anySelected ? !l.selected : !l.visible) continue;
                    auto mp = l.meshOrNull;
                    if (mp is null || mp.vertices.length == 0) continue;
                    immutable float[16] M = l.xform.composedMatrix();
                    foreach (v; mp.vertices)
                        verts ~= transformPoint(M, v);
                }
            }
            // Deliberately NO fallthrough to the geometry arms. An item
            // selection of items that carry no geometry (a lone locator) frames
            // nothing, and the early `verts.length == 0` return below leaves the
            // camera untouched — the same refusal the geometry arms already
            // make on an empty mesh. Falling through would silently reframe on
            // a stale geometry selection the user cannot see in this mode.
        } else if (editMode == EditMode.Vertices) {
            bool any = mesh.hasAnySelectedVertices();
            foreach (i; 0 .. mesh.vertices.length)
                if (!any || mesh.isVertexSelected(i)) verts ~= mesh.vertices[i];
        } else if (editMode == EditMode.Edges) {
            bool any = mesh.hasAnySelectedEdges();
            bool[] vis = new bool[](mesh.vertices.length);
            foreach (i; 0 .. mesh.edges.length) {
                if (any && !mesh.isEdgeSelected(i)) continue;
                foreach (vi; mesh.edges[i])
                    if (!vis[vi]) { verts ~= mesh.vertices[vi]; vis[vi] = true; }
            }
        } else if (editMode == EditMode.Polygons) {
            bool any = mesh.hasAnySelectedFaces();
            bool[] vis = new bool[](mesh.vertices.length);
            foreach (i; 0 .. mesh.faces.length) {
                if (any && !mesh.isFaceSelected(i)) continue;
                foreach (vi; mesh.faces[i])
                    if (!vis[vi]) { verts ~= mesh.vertices[vi]; vis[vi] = true; }
            }
        }
        if (verts.length == 0) return true;
        Vec3 c; float d;
        view.computeFrame(verts, c, d);   // view == scale owner
        focusCam.focus = c;
        view.distance  = d;
        return true;
    }
};
