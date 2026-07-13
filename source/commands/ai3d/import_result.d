module commands.ai3d.import_result;

import std.path : baseName;

import ai3d.scene_validator : validateImportedSceneForAi3d;
import change_bus : MeshChangeAll, LayerChange, noteLayerChange;
import command;
import display_sync : refreshDisplay;
import document : Document, Layer;
import editmode;
import io.scene_import : importViaAssimp;
import io.scene_ir : ImportedScene, flattenToMesh;
import log : logWarn;
import mesh;
import params : Param;
import view;
import viewcache;

final class Ai3dImportResult : Command {
    private Document* doc;
    private GpuMesh* gpu;
    private VertexCache* vc;
    private EdgeCache* ec;
    private FaceBoundsCache* fc;
    private void delegate(size_t prev, size_t next) onSwitch;

    private string pathArg;
    private string nameArg;
    private Layer inserted;
    private size_t insertedIndex;
    private bool[Layer] preSelected;
    private Layer prePrimary;
    private size_t preActiveIndex;
    private bool applied;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* doc,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc,
         void delegate(size_t, size_t) onSwitch) {
        super(mesh, view, editMode);
        this.doc = doc;
        this.gpu = gpu;
        this.vc = vc;
        this.ec = ec;
        this.fc = fc;
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

    override bool apply() {
        if (doc is null || doc.layers.length == 0) return false;
        if (pathArg.length == 0 && inserted is null) return false;

        auto prevLayer = doc.active();
        const prevIndex = doc.activeIndex;

        if (inserted is null) {
            preActiveIndex = doc.activeIndex;
            prePrimary = doc.active();
            preSelected = null;
            foreach (l; doc.layers) preSelected[l] = l.selected;

            ImportedScene scene;
            if (!importViaAssimp(pathArg, scene)) {
                try logWarn("ai3d", "importResult failed: assimp import failed");
                catch (Exception) {}
                return false;
            }
            auto validation = validateImportedSceneForAi3d(scene);
            if (!validation.ok) {
                try logWarn("ai3d", "importResult failed: " ~ validation.message);
                catch (Exception) {}
                return false;
            }

            auto layer = new Layer;
            layer.mesh = flattenToMesh(scene);
            if (layer.mesh.vertices.length == 0 || layer.mesh.faces.length == 0) {
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
        doc.setActive(insertedIndex);

        inserted.mesh.syncSelection();
        inserted.mesh.noteChange(MeshChangeAll);
        noteLayerChange(LayerChange.Added);
        refreshDisplay(&inserted.mesh, gpu, vc, ec, fc);
        fireSwitchIfChanged(prevLayer, prevIndex);
        applied = true;
        return true;
    }

    override bool revert() {
        if (!applied || inserted is null) return false;
        auto prevLayer = doc.active();
        const prevIndex = doc.activeIndex;

        size_t found = size_t.max;
        foreach (i, l; doc.layers)
            if (l is inserted) { found = i; break; }
        if (found == size_t.max) return false;
        insertedIndex = found;
        doc.layers = doc.layers[0 .. found] ~ doc.layers[found + 1 .. $];

        restoreSelection(preSelected, prePrimary, preActiveIndex);
        auto active = doc.activeMesh();
        active.noteChange(MeshChangeAll);
        noteLayerChange(LayerChange.Removed);
        refreshDisplay(active, gpu, vc, ec, fc);
        fireSwitchIfChanged(prevLayer, prevIndex);
        return true;
    }

    private void restoreSelection(bool[Layer] selected, Layer primary, size_t fallbackIndex) {
        foreach (l; doc.layers) {
            auto wasSelected = (l in selected) ? selected[l] : false;
            l.selected = wasSelected;
        }
        if (primary !is null)
            doc.setPrimary(primary);
        else
            doc.setActive(fallbackIndex);
    }

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
