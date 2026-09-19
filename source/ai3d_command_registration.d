module ai3d_command_registration;

import ai3d.job_controller : Ai3dJobController;
import command : Command;
import commands.ai3d.generate : Ai3dGenerate;
import commands.ai3d.generate_open : Ai3dGenerateOpen;
import commands.ai3d.generate_test_hooks : Ai3dGenerateCancelTestCommand,
    Ai3dGenerateStartTestCommand;
import commands.ai3d.import_result : Ai3dImportResult;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : Registry;

/// Registers AI-3D commands through explicit lifecycle/controller/modal doors.
/// Scene inputs remain live at factory invocation (task 6355; evidence:
/// item_command_registration_test).
void registerAi3dCommands(ref Registry reg, LiveSessionRole owner,
                          LiveViewModeRole live,
                          void delegate(size_t, size_t) onActiveLayerChanged,
                          Ai3dJobController controller,
                          void delegate(string) openGenerate) {
    assert(onActiveLayerChanged !is null && controller !is null
        && openGenerate !is null,
        "ai3d registration requires the active-layer hook, the controller and the open door");

    reg.registerCommand("ai3d.importResult", () => cast(Command)
        new Ai3dImportResult(&owner.activeMesh(), live.view(), live.mode,
                             owner.document(), onActiveLayerChanged));
    reg.registerCommand("ai3d.generate", () => cast(Command)
        new Ai3dGenerate(&owner.activeMesh(), live.view(), live.mode,
                         owner.document(), onActiveLayerChanged));
    reg.registerCommand("ai3d.generate.start", () => cast(Command)
        new Ai3dGenerateStartTestCommand(&owner.activeMesh(), live.view(),
                                         live.mode, controller));
    reg.registerCommand("ai3d.generate.cancel", () => cast(Command)
        new Ai3dGenerateCancelTestCommand(&owner.activeMesh(), live.view(),
                                          live.mode, controller));
    reg.registerCommand("ai3d.generate.open", () => cast(Command)
        new Ai3dGenerateOpen(&owner.activeMesh(), live.view(), live.mode,
                             openGenerate));
}
