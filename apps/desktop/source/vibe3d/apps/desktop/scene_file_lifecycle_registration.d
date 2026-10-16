module vibe3d.apps.desktop.scene_file_lifecycle_registration;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.apps.desktop.commands.file.quit : FileQuit;
import vibe3d.runtime.document_actions.commands.scene.load_mesh : MeshLoadRaw;
import vibe3d.runtime.document_actions.commands.scene.reset : SceneReset;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.editing.tools.interactive.registry : CommandFactory, Registry;
import vibe3d.apps.desktop.scene_reset_effects : SceneResetEffects;

/// Scene/file lifecycle registration keeps reset construction in one recipe.
/// The scene-load factory receives the narrow drop door: a reset also clears
/// user-locked pipe stages (its stage loop) and resetToolEffects the subpatch
/// preview/cache (task 6480; evidence: scene_file_lifecycle_registration_test).
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
        SceneLifecycleDoors doors, bool newScene) {
    return () {
        auto c = new SceneReset(&owner.activeMesh(), live.view(), live.mode,
                                live.modeCell(),
                                () => effects.resetToolEffects(),
                                () => effects.resetViewport());
        c.setDocument(owner.document());
        c.setEmpty(newScene);
        c.setKeepsToolPipe(newScene);
        c.setPromoteHook(doors.promoteGeometry());
        return cast(Command) c;
    };
}

void registerSceneFileLifecycleCommands(ref Registry reg,
        LiveSessionRole owner, LiveViewModeRole live,
        SceneResetEffects resetEffects, SceneLifecycleDoors doors) {
    reg.registerCommand("file.new", sceneResetFactory(owner, live, resetEffects, doors, true));
    reg.registerCommand("file.quit", () => cast(Command)
        new FileQuit(&owner.activeMesh(), live.view(), live.mode,
                     doors.requestQuit()));
    reg.registerCommand("scene.reset", sceneResetFactory(owner, live, resetEffects, doors, false));
    reg.registerCommand("scene.loadMesh", () => cast(Command)
        (new MeshLoadRaw(&owner.activeMesh(), live.view(), live.mode,
                         live.modeCell(), &live.view(),
                         doors.dropForSceneLoad()))
            .setPromoteHook(doors.promoteGeometry()));
}
