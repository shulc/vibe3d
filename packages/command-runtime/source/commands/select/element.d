module commands.select.element;

import command;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import vibe3d.mesh.snapshot.snapshot : SelectionSnapshot;
import vibe3d.editing.params.params : Param, wireArgs;

// One invocation owns one ordered selection image without changing active type.
// Invalid IDs are skipped; nonempty set clears on its first valid ID only.
// Task 20261900; doc/application_layers_wave3_plan_2026-10-09.md, Slice3A.
class SelectElementCommand : Command {
    private string targetType;
    private string action;
    private uint[] indicesArg;
    private bool typePresent, actionPresent, indicesPresent;
    private SelectionSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "select.element"; }
    override CmdFlags cmdFlags() const { return CmdFlags.UiState; }

    override Param[] params() {
        return wireArgs(
            Param.string_("type", "Type", &targetType, "").present(&typePresent),
            Param.string_("action", "Action", &action, "").present(&actionPresent),
            Param.intArray_("indices", "Indices", &indicesArg).present(&indicesPresent)
        );
    }

    void setTargetType(string t) { targetType = t; typePresent = true; }
    void setAction(string a) { action = a; actionPresent = true; }
    void setIndices(int[] ids) {
        indicesArg.length = ids.length;
        foreach (i, id; ids) indicesArg[i] = cast(uint)id;
        indicesPresent = true;
    }

    protected override bool applyImpl() {
        if (!typePresent || !actionPresent || !indicesPresent)
            throw new Exception("select.element: type, action and indices are required");
        mesh.syncSelection();
        snap = SelectionSnapshot.capture(*mesh);
        noteUndoRecorded();
        switch (targetType) {
            case "edge":
                applyIndices(mesh.edges.length, &mesh.clearEdgeSelection,
                    &mesh.selectEdge, &mesh.deselectEdge, (int id) => mesh.isEdgeSelected(id));
                break;
            case "polygon":
                applyIndices(mesh.faces.length, &mesh.clearFaceSelection,
                    &mesh.selectFace, &mesh.deselectFace, (int id) => mesh.isFaceSelected(id));
                break;
            default:
                applyIndices(mesh.vertices.length, &mesh.clearVertexSelection,
                    &mesh.selectVertex, &mesh.deselectVertex, (int id) => mesh.isVertexSelected(id));
                break;
        }
        return true;
    }

    protected override void revertImpl() { snap.restore(*mesh); }

private:
    enum Action { set, add, remove, toggle }

    Action normaliseAction() const {
        switch (action) {
            case "set", "replace": return Action.set;
            case "remove", "del": return Action.remove;
            case "toggle": return Action.toggle;
            default: return Action.add;
        }
    }

    void applyIndices(size_t count, void delegate() clear,
            void delegate(int) select, void delegate(int) deselect,
            bool delegate(int) selected) {
        const operation = normaliseAction();
        bool cleared;
        if (operation == Action.set && indicesArg.length == 0) clear();
        foreach (raw; indicesArg) {
            const id = cast(int)raw;
            if (id < 0 || id >= count) continue;
            final switch (operation) {
                case Action.set:
                    if (!cleared) { clear(); cleared = true; }
                    select(id);
                    break;
                case Action.add: select(id); break;
                case Action.remove: deselect(id); break;
                case Action.toggle:
                    if (selected(id)) deselect(id);
                    else select(id);
                    break;
            }
        }
    }
}




