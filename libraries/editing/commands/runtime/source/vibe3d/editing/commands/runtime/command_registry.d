module vibe3d.editing.commands.runtime.command_registry;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.editing.contracts.seltype : SelType;

alias CommandFactory = Command delegate();

// One command owner supplies live construction authority and cached metadata.
// Task 20261760; doc/application_layers_wave1_plan_2026-10-08.md §1C.
struct CommandRegistry {
private:
    CommandFactory[string] commandFactories_;
    SelType delegate()     selTypeAuthority_;
    size_t                 commandsBuiltWithoutAuthority_;

public:
    void registerCommand(string id, CommandFactory factory) {
        if (factory is null)
            throw new Exception("registry: command '" ~ id ~ "' has a null factory");
        if (id in commandFactories_)
            throw new Exception("registry: command '" ~ id ~ "' is already registered");
        commandFactories_[id] = factory;
    }

    void replaceCommand(string id, CommandFactory factory) {
        if (factory is null)
            throw new Exception("registry: command '" ~ id ~ "' has a null factory");
        if (id !in commandFactories_)
            throw new Exception("registry: command '" ~ id ~ "' is not registered");
        commandFactories_[id] = factory;
    }

    void aliasCommand(string sourceId, string aliasId) {
        auto source = sourceId in commandFactories_;
        if (source is null)
            throw new Exception("registry: command '" ~ sourceId ~ "' is not registered");
        if (aliasId in commandFactories_)
            throw new Exception("registry: command '" ~ aliasId ~ "' is already registered");
        commandFactories_[aliasId] = *source;
    }

    bool hasCommand(string id) const {
        return (id in commandFactories_) !is null;
    }

    string[] commandIds() const {
        return commandFactories_.keys;
    }

    Command makeCommand(string id) {
        auto factory = id in commandFactories_;
        if (factory is null) return null;
        auto command = (*factory)();
        if (selTypeAuthority_ !is null)
            command.setSelTypeProvider(selTypeAuthority_);
        else
            ++commandsBuiltWithoutAuthority_;
        return command;
    }

    void bindSelTypeAuthority(SelType delegate() authority) {
        if (commandsBuiltWithoutAuthority_ != 0) {
            import std.conv : to;
            throw new Exception("registry: "
                ~ commandsBuiltWithoutAuthority_.to!string
                ~ " command(s) were constructed before the selection-type authority "
                ~ "was bound — they carry currentType()'s fallback. Move the bind "
                ~ "above the first construction (task 6510).");
        }
        selTypeAuthority_ = authority;
    }

    EditMode[][string] commandModes;
    string[string] commandNames;
    string[string] commandParamsJson;
    bool[string] commandNeedsTarget;
    bool[string] commandDiscardsWork;
    bool[string] commandDropsToolBeforeApply;
    bool[string] commandCommitsToolEditBeforeApply;

    void cacheSupportedModes() {
        import vibe3d.editing.params.params : paramsSchemaJson;
        const commandKeys = commandIds();
        foreach (id; commandKeys) {
            auto cmd = makeCommand(id);
            commandModes[id] = cmd.supportedModes().dup;
            commandNames[id] = cmd.name;
            commandParamsJson[id] = paramsSchemaJson(cmd.params());
            commandNeedsTarget[id] = cmd.needsEditTarget();
            commandDiscardsWork[id] = cmd.discardsUnsavedWork();
            import vibe3d.editing.commands.runtime.command : dropsActiveToolBeforeApply,
                             commitsActiveToolEditBeforeApply;
            commandDropsToolBeforeApply[id] = dropsActiveToolBeforeApply(cmd);
            commandCommitsToolEditBeforeApply[id] =
                commitsActiveToolEditBeforeApply(cmd);
            // Fail fast on any command whose name() does not resolve back to
            // a registered command key — a dead replay string in the making
            // (history/scripting re-dispatch cmd.name through
            // the command registry). This is "resolves-back", NOT "name()==id":
            // alias keys (file.open, file.import.*, file.export.*) legitimately
            // share one command class + name() with a DIFFERENT key, and that
            // is fine as long as the name() itself is some live key. Scoped to
            // commands ONLY — tool name() is a display string by
            // design and is not part of this contract.
            if (!hasCommand(cmd.name))
                throw new Exception("registry: command '" ~ id ~ "' name() '"
                    ~ cmd.name ~ "' is not a registered command key");
        }
    }
}

// Paired positive control for the external construction-authority fence.
// This expression must remain valid inside CommandRegistry's owning module; the
// external half proves that the same expression is rejected by visibility.
unittest {
    static assert(__traits(compiles, {
        CommandFactory factory;
        CommandRegistry reg;
        reg.commandFactories_["k"] = factory;
    }));
}

