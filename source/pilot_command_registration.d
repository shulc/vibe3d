module pilot_command_registration;

import command : Command;
import command_registry : CommandRegistry;
import command_history : CommandHistory;
import commands.mesh.triple : MeshTriple;
import commands.mesh.select : MeshSelect;
import commands.history.undo : HistoryUndo;
import commands.history.redo : HistoryRedo;
import editmode : EditMode;
import math : Viewport;
import mesh : Mesh;
import view : View;

alias PilotMesh = ref Mesh delegate();
alias PilotView = ref View delegate();

// Factories resolve live data at construction. Policy capabilities stay with
// their host. Task 20261770; doc/application_layers_wave1_plan_2026-10-08.md §1D.
struct PilotCommandDeps {
    PilotMesh activeMesh;
    PilotView view;
    EditMode* mode;
    Viewport delegate() resolvedViewport;
    void delegate(EditMode) promoteGeometryType;
    void delegate() topologyInteraction;
}

void registerTripleCommand(ref CommandRegistry registry, PilotCommandDeps deps) {
    registry.registerCommand("mesh.triple", () => cast(Command)
        new MeshTriple(&deps.activeMesh(), deps.view(), *deps.mode,
                       deps.topologyInteraction));
}

void registerMeshSelectionCommand(ref CommandRegistry registry, PilotCommandDeps deps) {
    registry.registerCommand("mesh.select", () {
        auto command = new MeshSelect(&deps.activeMesh(), deps.view(), *deps.mode, deps.mode);
        command.setPromoteHook(deps.promoteGeometryType);
        command.setResolvedVpProvider(deps.resolvedViewport);
        return cast(Command) command;
    });
}

void registerHistoryNavigationCommands(ref CommandRegistry registry,
        PilotCommandDeps deps, CommandHistory history) {
    registry.registerCommand("history.undo", () => cast(Command)
        new HistoryUndo(&deps.activeMesh(), deps.view(), *deps.mode, history));
    registry.registerCommand("history.redo", () => cast(Command)
        new HistoryRedo(&deps.activeMesh(), deps.view(), *deps.mode, history));
}
