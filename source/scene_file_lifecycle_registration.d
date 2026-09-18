module scene_file_lifecycle_registration;

import command : Command;
import commands.file.quit : FileQuit;
import commands.scene.load_mesh : MeshLoadRaw;
import commands.scene.reset : SceneReset;
import editmode : EditMode;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : CommandFactory, Registry;
import scene_reset_effects : SceneResetEffects;

/// Scene/file lifecycle registration keeps reset construction in one recipe.
/// The scene-load factory receives the narrow drop door: resetToolEffects also
/// clears user-locked pipe stages and the subpatch preview/cache (task 6480;
/// evidence: scene_file_lifecycle_registration_test).
struct SceneLifecycleDoors {
private:
    void delegate(EditMode) promoteGeometry_;
    void delegate() requestQuit_;
    void delegate() dropForSceneLoad_;

public:
    @disable this();

    this(void delegate(EditMode) promoteGeometry,
         void delegate() requestQuit,
         void delegate() dropForSceneLoad) {
        assert(promoteGeometry !is null && requestQuit !is null
                && dropForSceneLoad !is null,
            "scene/file registration requires promote, quit and load-drop doors");
        promoteGeometry_ = promoteGeometry;
        requestQuit_ = requestQuit;
        dropForSceneLoad_ = dropForSceneLoad;
    }

    void delegate(EditMode) promoteGeometry() {
        return promoteGeometry_;
    }

    void delegate() requestQuit() {
        return requestQuit_;
    }

    void delegate() dropForSceneLoad() {
        return dropForSceneLoad_;
    }
}

private CommandFactory sceneResetFactory(LiveSessionRole owner,
        LiveViewModeRole live, SceneResetEffects effects,
        SceneLifecycleDoors doors, bool empty) {
    return () {
        auto c = new SceneReset(&owner.activeMesh(), live.view(), live.mode,
                                live.modeCell(),
                                () => effects.resetToolEffects(),
                                () => effects.resetViewport());
        c.setDocument(owner.document());
        c.setEmpty(empty);
        c.setPromoteHook(doors.promoteGeometry());
        return cast(Command) c;
    };
}

void registerSceneFileLifecycleCommands(ref Registry reg,
        LiveSessionRole owner, LiveViewModeRole live,
        SceneResetEffects resetEffects, SceneLifecycleDoors doors) {
    reg.commandFactories["file.new"] =
        sceneResetFactory(owner, live, resetEffects, doors, true);
    reg.commandFactories["file.quit"] = () => cast(Command)
        new FileQuit(&owner.activeMesh(), live.view(), live.mode,
                     doors.requestQuit());
    reg.commandFactories["scene.reset"] =
        sceneResetFactory(owner, live, resetEffects, doors, false);
    reg.commandFactories["scene.loadMesh"] = () => cast(Command)
        (new MeshLoadRaw(&owner.activeMesh(), live.view(), live.mode,
                         live.modeCell(), &live.view(),
                         doors.dropForSceneLoad()))
            .setPromoteHook(doors.promoteGeometry());
}
