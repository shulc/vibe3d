module commands.ai3d.import_result;

import std.path : baseName;

import ai3d.scene_validator : validateImportedSceneForAi3d;
import change_bus : MeshChangeAll, LayerChange, noteLayerChange;
import command;
import document : Document, Layer;
import editmode;
import io.scene_import : importViaAssimp;
import io.scene_ir : ImportedScene, flattenToMesh;
import log : logWarn;
import mesh;
import params : Param;
import view;

final class Ai3dImportResult : Command {
    private Document* doc;
    private void delegate(size_t prev, size_t next) onSwitch;

    private string pathArg;
    private string nameArg;
    private Layer inserted;
    private size_t insertedIndex;
    /// TASK 0671 — the whole item-selection state, captured once (see
    /// `Document.captureItemSelection`). Replaces the `bool[Layer]` +
    /// edit-target pair: the target is derived, so recording it was recording
    /// a consequence, and the deselect history it is derived FROM was not
    /// being recorded at all.
    private Document.ItemSelectionState preSelection;
    private size_t preActiveIndex;
    // task 0381 follow-up: surface WHY an import failed so the UI modal can show
    // it (previously every failure only went to stderr via logWarn — a silently
    // rejected mesh looked like "Done — imported" with no geometry).
    private string failCode_;
    private string failMessage_;

    /// True once apply() has successfully inserted the layer.
    bool succeeded() const { return undoRecorded(); }
    /// The reason apply() returned false (empty until a failure), for the modal.
    string failureCode() const { return failCode_; }
    string failureMessage() const { return failMessage_; }

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode);
        this.doc = doc;
        this.onSwitch = onSwitch;
    }

    override string name() const { return "ai3d.importResult"; }
    override string label() const { return "Import AI 3D Result"; }

    override Param[] params() {
        return [
            Param.string_("path", "Path", &pathArg, ""),
            Param.string_("name", "Name", &nameArg, ""),
        ];
    }

    void setInput(string path, string name = null) {
        pathArg = path;
        nameArg = name;
    }

    protected override bool applyImpl() {
        failCode_ = null;
        failMessage_ = null;
        if (doc is null || doc.layers.length == 0) {
            failCode_ = "internal";
            failMessage_ = "no document to import into";
            return false;
        }
        if (pathArg.length == 0 && inserted is null) {
            failCode_ = "artifact_missing";
            failMessage_ = "no artifact path to import";
            return false;
        }

        // Task 0615 (NIT, review round 3): `doc.primary`, not `doc.active()`
        // — the role-clear name (see `commands/scene/reset.d`'s matching
        // rename), naming what this actually is: the mesh edit target.
        auto prevLayer = doc.primary;
        const prevIndex = doc.activeIndex;

        if (inserted is null) {
            preActiveIndex = doc.activeIndex;
            preSelection = doc.captureItemSelection();

            ImportedScene scene;
            if (!importViaAssimp(pathArg, scene)) {
                failCode_ = "artifact_invalid";
                failMessage_ = "3D file could not be parsed";
                try logWarn("ai3d", "importResult failed: assimp import failed");
                catch (Exception) {}
                return false;
            }
            auto validation = validateImportedSceneForAi3d(scene);
            if (!validation.ok) {
                failCode_ = validation.code;
                failMessage_ = validation.message;
                try logWarn("ai3d", "importResult failed: " ~ validation.message);
                catch (Exception) {}
                return false;
            }

            auto layer = new Layer;
            // Task 0615 (§Tier-2 :103-105): the imported layer is always
            // mesh-kind — `layer.kind` stays at its default (`ItemKind.Mesh`).
            layer.meshRef() = flattenToMesh(scene);
            if (layer.meshRef().vertices.length == 0 || layer.meshRef().faces.length == 0) {
                failCode_ = "artifact_invalid";
                failMessage_ = "imported mesh is empty";
                try logWarn("ai3d", "importResult failed: flattened mesh is empty");
                catch (Exception) {}
                return false;
            }
            layer.name = nameArg.length ? nameArg : defaultLayerName(pathArg);
            layer.visible = true;
            layer.selected = false;
            inserted = layer;
            insertedIndex = doc.layers.length;
        } else {
            if (insertedIndex > doc.layers.length)
                insertedIndex = doc.layers.length;
        }

        doc.layers = doc.layers[0 .. insertedIndex] ~ inserted
                                                   ~ doc.layers[insertedIndex .. $];
        doc.noteLayerListChanged();
        doc.setActive(insertedIndex);

        inserted.meshRef().syncSelection();
        // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`: the command's
        // LAST mesh publisher must DELIVER (`syncSelection()` does not), or the
        // bus-keyed display family has nothing to react to inside this frame.
        // See `Mesh.publishChange`'s doc comment.
        inserted.meshRef().publishChange(MeshChangeAll);
        noteLayerChange(LayerChange.Added);
        fireSwitchIfChanged(prevLayer, prevIndex);
        noteUndoRecorded();   // task 2500 — the image is `inserted` + `preSelection`
        return true;
    }

    protected override void revertImpl() {
        auto prevLayer = doc.active();
        const prevIndex = doc.activeIndex;

        size_t found = size_t.max;
        foreach (i, l; doc.layers)
            if (l is inserted) { found = i; break; }
        if (found == size_t.max) {
            // A GENUINE restore failure, and the one shape this command has:
            // the layer we inserted is no longer in the document, so there is
            // nothing of ours to take out.
            failRevert("the imported layer is no longer in the document");
            return;
        }
        insertedIndex = found;
        doc.layers = doc.layers[0 .. found] ~ doc.layers[found + 1 .. $];
        doc.noteLayerListChanged();

        doc.restoreItemSelection(preSelection);
        auto active = doc.activeMesh();
        // Task 0654: the pre-import selection may have been EMPTY, in which
        // case restoreSelection put it back that way and there is no active
        // mesh to note a change on. The layer-list change published below is
        // what rebuilds the caches.
        // TASK 1906 STAGE 2 — `publishChange`, same reason as the apply tail.
        if (active !is null) active.publishChange(MeshChangeAll);
        noteLayerChange(LayerChange.Removed);
        fireSwitchIfChanged(prevLayer, prevIndex);
    }

    // ~~private void restoreSelection(bool[Layer], Layer primary, size_t
    // fallbackIndex)~~ — RETIRED (task 0671) in favour of
    // `Document.restoreItemSelection`. Its three branches existed to re-derive
    // a stored edit target from a restored set of bits, and its `fallbackIndex`
    // arm was the 0654 clamp hazard written out longhand. One exact restore
    // replaces all of it.

    private void fireSwitchIfChanged(Layer prevLayer, size_t prevIndex) {
        if (onSwitch is null) return;
        if (doc.active() is prevLayer) return;
        onSwitch(prevIndex, doc.activeIndex);
    }
}

private string defaultLayerName(string path) {
    auto name = path.baseName;
    return name.length ? "AI 3D " ~ name : "AI 3D Result";
}
