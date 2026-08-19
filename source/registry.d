module registry;

import mesh;
import view;
import editmode;
import shader;
import tool;
import command;

// ---------------------------------------------------------------------------
// AppContext — raw references to per-app state shared by tools and commands
// ---------------------------------------------------------------------------

struct AppContext {
    Mesh*      mesh;
    GpuMesh*   gpu;
    EditMode*  editMode;
    View       view;       // class — reference semantics
    LitShader  litShader;  // class — reference semantics
}

// ---------------------------------------------------------------------------
// Registry — factory dictionaries for tools and commands
// ---------------------------------------------------------------------------

alias ToolFactory    = Tool    delegate();
alias CommandFactory = Command delegate();

alias PreActivate = void delegate();

struct Registry {
    ToolFactory[string]    toolFactories;
    CommandFactory[string] commandFactories;

    // Per-tool side-effect hook run RIGHT BEFORE the factory in the
    // user-driven activation path (NOT in `cacheSupportedModes`, so
    // enumerating every factory at startup doesn't mutate global
    // state). Populated for tool presets in `registerToolPresets`,
    // which want to push pipe-stage attrs (e.g. `actionCenter.mode =
    // element` for `move.element`) when the preset is actually
    // selected.
    PreActivate[string] preActivate;

    // Cached `supportedModes()` per command/tool id — populated once
    // at app startup via `cacheSupportedModes()` after all factory
    // assignments. The button-rendering side reads this to auto-
    // disable rows whose target action doesn't accept the current
    // edit mode (e.g. `mesh.subdivide` greyed out in Vertices/Edges).
    //
    // Missing-key lookup ⇒ "all modes supported" (no restriction).
    EditMode[][string] commandModes;
    EditMode[][string] toolModes;

    // Cached `name()` per registered command id — populated once at app
    // startup alongside `commandModes`. Exposed on `GET /api/registry` so
    // the button-action resolver test can assert every command's `name()`
    // resolves back to a live registration key (the replay-string
    // invariant — see doc/registry_name_integrity_plan.md). Tools are
    // deliberately excluded: a tool's `name()` is a human display string
    // by design (e.g. `move` → "Transform"), not a key.
    string[string] commandNames;

    // Cached `params()` SCHEMA per registered id, already serialised to the
    // `GET /api/registry?params=1` wire form (a JSON array of
    // `{name, kind, enforceBounds, value, min?, max?}`, see
    // params.paramsSchemaJson). Populated in the same startup walk as
    // `commandModes`/`commandNames`, off the SAME cold instance — one
    // construction per id for the whole process lifetime.
    //
    // Why cached rather than built per request: the endpoint is served
    // straight from the HTTP thread, and building the schema there meant
    // calling every registered factory there. A tool constructor allocates
    // GL objects (handles.shapes.Arrow -> glGenVertexArrays), and the HTTP
    // thread has no current GL context — the call lands in a NULL dispatch
    // slot and takes the process down. Ten core dumps, one stack, three
    // builds. This walk already constructs every factory on the MAIN thread
    // with the context live, which is the only place that construction is
    // legal, so the schema is taken here and the HTTP thread only ever
    // emits text.
    //
    // Correctness of the snapshot rests on the contract this walk already
    // relies on for `supportedModes()` and `name()`: a COLD instance is
    // stable — the factories are pure construction and per-id runtime state
    // (tool presets' `preActivate`, sticky attr defaults) is deliberately
    // applied on the ACTIVATION path, not in the factory. A ctor that starts
    // reading mutable app state would stale all three caches, not just this
    // one.
    string[string] commandParamsJson;
    string[string] toolParamsJson;

    // Cached `needsEditTarget()` per registered id (task 0669) — the fact the
    // COMMAND / TOOL ITSELF declares about whether it can run with no item
    // selected. Taken in the same startup walk, off the same cold instance,
    // and for the same reason: asking it later would mean calling a factory,
    // and a factory call is GL work that must not happen on the HTTP thread
    // (see `commandParamsJson` above) or 60 times a second in the draw.
    //
    // This map is the ONLY place the answer is stored, and nothing writes it
    // but the walk below — there is deliberately no hand-written list of
    // "commands that need a layer" anywhere in the tree to drift from it.
    //
    // Missing-key lookup ⇒ "does not need one" (an id nobody registered
    // cannot be pressed).
    bool[string] commandNeedsTarget;
    bool[string] toolNeedsTarget;
    /// Task 1521 — which registered ids declared `Command.discardsUnsavedWork`.
    /// Same shape and same reason as `commandNeedsTarget`: published so the
    /// declaration can be checked against BEHAVIOUR over the whole registry
    /// (tests/test_discard_census.d) instead of over a hand-written list.
    bool[string] commandDiscardsWork;

    /// Walk every registered factory once and snapshot its
    /// `supportedModes()` into the cache. Call after all
    /// `commandFactories[*]` / `toolFactories[*]` assignments.
    void cacheSupportedModes() {
        import params : paramsSchemaJson;
        foreach (id, factory; commandFactories) {
            auto cmd = factory();
            commandModes[id] = cmd.supportedModes().dup;
            commandNames[id] = cmd.name;
            commandParamsJson[id] = paramsSchemaJson(cmd.params());
            commandNeedsTarget[id] = cmd.needsEditTarget();
            commandDiscardsWork[id] = cmd.discardsUnsavedWork();
            // Fail fast on any command whose name() does not resolve back to
            // a registered command key — a dead replay string in the making
            // (history/scripting re-dispatch cmd.name through
            // commandFactories). This is "resolves-back", NOT "name()==id":
            // alias keys (file.open, file.import.*, file.export.*) legitimately
            // share one command class + name() with a DIFFERENT key, and that
            // is fine as long as the name() itself is some live key. Scoped to
            // commandFactories ONLY — tool name() is a display string by
            // design and is not part of this contract.
            if (cmd.name !in commandFactories)
                throw new Exception("registry: command '" ~ id ~ "' name() '"
                    ~ cmd.name ~ "' is not a registered command key");
        }
        foreach (id, factory; toolFactories) {
            auto tool = factory();
            toolModes[id]       = tool.supportedModes().dup;
            toolParamsJson[id]  = paramsSchemaJson(tool.params());
            toolNeedsTarget[id] = tool.needsEditTarget();
        }
    }

    /// The `GET /api/registry` response body: the registered command and
    /// tool ids plus `commandNames`, and — when `includeParams` — the
    /// `commandParams`/`toolParams` schema maps.
    ///
    /// Answered on the HTTP thread, so this function is deliberately a pure
    /// read of the post-startup-immutable caches above: NO factory may be
    /// called from here. Constructing a tool allocates GL objects, and the
    /// HTTP thread has no current GL context — that is the whole defect this
    /// shape exists to prevent. The unittest at the bottom of this module
    /// counts constructions across repeated calls and fails if any appear.
    string registryJson(bool includeParams) {
        import std.array     : appender;
        import std.format    : format;
        import std.algorithm : sort;

        auto cmds  = commandFactories.keys.dup;
        auto tools = toolFactories.keys.dup;
        cmds.sort();
        tools.sort();

        auto buf = appender!string;
        buf.put(`{"commands":[`);
        foreach (i, k; cmds) {
            if (i > 0) buf.put(",");
            buf.put(format(`"%s"`, k));
        }
        buf.put(`],"tools":[`);
        foreach (i, k; tools) {
            if (i > 0) buf.put(",");
            buf.put(format(`"%s"`, k));
        }
        buf.put(`],"commandNames":{`);
        bool firstName = true;
        foreach (k; cmds) {
            if (!firstName) buf.put(",");
            firstName = false;
            buf.put(format(`"%s":"%s"`, k, commandNames.get(k, "")));
        }
        buf.put(`}`);

        // Task 0669 — which registered ids DECLARED that they need a mesh
        // edit target (`Command.needsEditTarget` / `Tool.needsEditTarget`).
        //
        // Published so a test can assert the declaration against BEHAVIOUR
        // over the whole registry rather than over a handful of ids a
        // hand-written list would also satisfy: fire every declared command
        // with no item selected and each one must refuse. Without this the
        // only total sweep available would be "fire everything", and
        // `file.quit` is in everything.
        buf.put(`,"commandsNeedingTarget":[`);
        bool firstNeed = true;
        foreach (k; cmds) {
            if (!commandNeedsTarget.get(k, false)) continue;
            if (!firstNeed) buf.put(",");
            firstNeed = false;
            buf.put(format(`"%s"`, k));
        }
        buf.put(`],"commandsDiscardingWork":[`);
        bool firstDiscard = true;
        foreach (k; cmds) {
            if (!commandDiscardsWork.get(k, false)) continue;
            if (!firstDiscard) buf.put(",");
            firstDiscard = false;
            buf.put(format(`"%s"`, k));
        }
        buf.put(`],"toolsNeedingTarget":[`);
        bool firstToolNeed = true;
        foreach (k; tools) {
            if (!toolNeedsTarget.get(k, false)) continue;
            if (!firstToolNeed) buf.put(",");
            firstToolNeed = false;
            buf.put(format(`"%s"`, k));
        }
        buf.put(`]`);

        // Task 1412 — the edit modes each id DECLARED it supports.
        //
        // `commandModes` / `toolModes` have been cached at startup since the
        // button-greying work, but nothing published them, so an outside
        // caller wanting to drive a command in a mode it accepts had to guess
        // the mode and read the refusal. `/api/buttons/availability` is not a
        // substitute: that answer is frame-dependent (it folds in the CURRENT
        // mode and selection), whereas this is the static declaration.
        //
        // Emitted exactly the way `commandsNeedingTarget` above is: a pure
        // read of a post-startup-immutable cache, no factory call. A missing
        // key means "no restriction", and is emitted as the full list so the
        // reader never has to know that convention.
        void putModes(string label, const string[] ids,
                      const EditMode[][string] cache) {
            buf.put(format(`,"%s":{`, label));
            bool firstMode = true;
            foreach (k; ids) {
                if (!firstMode) buf.put(",");
                firstMode = false;
                const(EditMode)[] ms;
                if (auto m = k in cache) ms = *m;
                else ms = [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
                buf.put(format(`"%s":[`, k));
                foreach (i, m; ms) {
                    if (i > 0) buf.put(",");
                    buf.put(format(`"%s"`, m));
                }
                buf.put(`]`);
            }
            buf.put(`}`);
        }
        putModes("commandSupportedModes", cmds, commandModes);
        putModes("toolSupportedModes",    tools, toolModes);

        if (includeParams) {
            buf.put(`,"commandParams":{`);
            bool firstCmd = true;
            foreach (k; cmds) {
                if (!firstCmd) buf.put(",");
                firstCmd = false;
                buf.put(format(`"%s":%s`, k, commandParamsJson.get(k, "[]")));
            }
            buf.put(`},"toolParams":{`);
            bool firstTool = true;
            foreach (k; tools) {
                if (!firstTool) buf.put(",");
                firstTool = false;
                buf.put(format(`"%s":%s`, k, toolParamsJson.get(k, "[]")));
            }
            buf.put(`}`);
        }

        buf.put(`}`);
        return buf.data;
    }

    /// True when `actionId` is registered AND its `supportedModes()`
    /// excludes `currentMode`. Used by the side-panel button render
    /// to auto-grey out rows for the current edit mode. Returns
    /// false for unknown ids (no restriction) and for "all modes"
    /// commands.
    bool isModeBlocked(string kind, string actionId, EditMode currentMode) const {
        const(EditMode)[] modes;
        if (kind == "command") {
            if (auto m = actionId in commandModes) modes = *m;
            else return false;
        } else if (kind == "tool") {
            if (auto m = actionId in toolModes) modes = *m;
            else return false;
        } else {
            return false;
        }
        foreach (m; modes) if (m == currentMode) return false;
        return true;
    }

    /// TASK 0669 — the one-clause reason pressing `actionId` would refuse
    /// RIGHT NOW, or `""` when it would run. THE single availability answer:
    /// the button-draw greys a row iff this is non-empty, and
    /// `activateToolById` declines to arm iff this is non-empty, so what the
    /// user sees and what the press does are the same computation.
    ///
    /// It never consults a name. The per-id fact comes from
    /// `Command.needsEditTarget()` / `Tool.needsEditTarget()`, snapshotted in
    /// `cacheSupportedModes` — so the day a new mesh operator is registered,
    /// its button greys correctly with no edit here.
    ///
    /// `activeToolId` is load-bearing for tools and only for tools: pressing
    /// the button of the ARMED tool DROPS it, and dropping never needed a
    /// target (`activateToolById` takes its same-id branch before the
    /// refusal). Greying that press would strand the user in a tool they
    /// cannot leave. Pass `""` from callers that are not asking about the
    /// live tool bank.
    ///
    /// `kind` is `"command"` or `"tool"`, matching `isModeBlocked`. Script
    /// actions are not a kind here — a script is a sequence of command lines,
    /// and its caller resolves each line's id and asks about that (see
    /// `ui.availability.actionRefusal`).
    string actionRefusal(string kind, string actionId,
                         bool hasEditTarget, string activeToolId) const {
        import command : kNoEditTargetReason;
        if (hasEditTarget) return "";
        if (kind == "command") {
            if (auto p = actionId in commandNeedsTarget)
                return *p ? kNoEditTargetReason : "";
            return "";
        }
        if (kind == "tool") {
            if (actionId.length > 0 && actionId == activeToolId) return "";
            if (auto p = actionId in toolNeedsTarget)
                return *p ? kNoEditTargetReason : "";
            return "";
        }
        return "";
    }
}

// ---------------------------------------------------------------------------
// Unit tests: the resolves-back gate in cacheSupportedModes() (command-scoped
// only — see doc/registry_name_integrity_plan.md).
// ---------------------------------------------------------------------------
version (unittest) {
    private final class _RegTestCmd : Command {
        private Mesh  _mesh;
        private View  _view = new View(0, 0, 1, 1);
        private string _name;
        this(string name) {
            super(&_mesh, _view, EditMode.Vertices);
            _name = name;
        }
        override string name() const { return _name; }
    }
}

// (a) A consistent command key/alias pair — an alias key's factory name()
// resolves to the OTHER (primary) key, which is itself registered. No throw.
unittest {
    Registry reg;
    reg.commandFactories["thing.primary"] = () => cast(Command) new _RegTestCmd("thing.primary");
    reg.commandFactories["thing.alias"]   = () => cast(Command) new _RegTestCmd("thing.primary");
    reg.cacheSupportedModes();  // must not throw
    assert(reg.commandNames["thing.primary"] == "thing.primary");
    assert(reg.commandNames["thing.alias"]   == "thing.primary");
}

// (b) A drifting command entry — name() is not any registered key. Throws.
unittest {
    Registry reg;
    reg.commandFactories["thing.drifted"] = () => cast(Command) new _RegTestCmd("Thing Drifted");
    bool threw = false;
    try {
        reg.cacheSupportedModes();
    } catch (Exception e) {
        threw = true;
    }
    assert(threw, "expected cacheSupportedModes() to throw on a drifting command name()");
}

// ---------------------------------------------------------------------------
// Unit tests: the param-schema cache.
//
// The invariant under test is a THREAD invariant expressed as an allocation
// count: answering `GET /api/registry?params=1` must not call a single
// factory. A factory call constructs a tool, a tool constructor allocates GL
// objects, and the endpoint is answered on the HTTP thread, which has no
// current GL context — that combination is what killed the process. Counting
// constructions is the only part of that chain observable without a GL
// context, and it is the part that has to stay at zero.
// ---------------------------------------------------------------------------
version (unittest) {
    import params : Param;

    private int _regCtorCalls;   // reset by each test that reads it

    private final class _RegParamCmd : Command {
        private Mesh   _mesh;
        private View   _view = new View(0, 0, 1, 1);
        private string _name;
        private int    _count = 5;
        this(string name) {
            super(&_mesh, _view, EditMode.Vertices);
            _name = name;
            ++_regCtorCalls;
        }
        override string name() const { return _name; }
        override Param[] params() {
            return [ Param.int_("count", "Count", &_count, 5)
                        .min(1).max(64).enforceBounds() ];
        }
    }

    private final class _RegParamTool : Tool {
        private float _amount = 0.5f;
        this() { ++_regCtorCalls; }
        override Param[] params() {
            return [ Param.float_("amount", "Amount", &_amount, 0.5f)
                        .min(0.0f).max(1.0f) ];
        }
    }
}

// (c) The schema is snapshotted for every registered id, in the wire form the
// endpoint emits verbatim.
unittest {
    import std.json : parseJSON, JSONType;

    Registry reg;
    reg.commandFactories["thing.cmd"] = () => cast(Command) new _RegParamCmd("thing.cmd");
    reg.toolFactories["thing.tool"]   = () => cast(Tool)    new _RegParamTool();
    reg.cacheSupportedModes();

    auto jc = parseJSON(reg.commandParamsJson["thing.cmd"]);
    assert(jc.array.length == 1);
    assert(jc[0]["name"].str           == "count");
    assert(jc[0]["kind"].str           == "Int");
    assert(jc[0]["enforceBounds"].type == JSONType.true_);
    assert(jc[0]["min"].integer == 1 && jc[0]["max"].integer == 64);

    auto jt = parseJSON(reg.toolParamsJson["thing.tool"]);
    assert(jt.array.length == 1);
    assert(jt[0]["name"].str == "amount");
    assert(jt[0]["kind"].str == "Float");

    // A registrant with no params still gets an entry — an ABSENT key would
    // make the endpoint fall back to its `[]` default and hide the difference
    // between "no params" and "never walked".
    reg.commandFactories["thing.bare"] = () => cast(Command) new _RegTestCmd("thing.bare");
    reg.cacheSupportedModes();
    assert("thing.bare" in reg.commandParamsJson);
    assert(reg.commandParamsJson["thing.bare"] == "[]");
}

// (d) THE defect pin: answering `GET /api/registry?params=1` constructs
// nothing. This drives the REAL endpoint body (`registryJson`), not a
// stand-in, so it fails on any future edit that reaches for a factory there.
//
// Mutation: put the factory call back where the endpoint used to have it —
// in `registryJson`, emit `paramsSchemaJson(commandFactories[k]().params())`
// instead of `commandParamsJson.get(k, "[]")` — and this fails with
// "answering /api/registry?params=1 constructed 32 tool/command instance(s)
// on the calling thread — a tool constructor is GL work (verified: 32).
unittest {
    import std.conv : to;
    import std.json : parseJSON;

    Registry reg;
    reg.commandFactories["thing.cmd"] = () => cast(Command) new _RegParamCmd("thing.cmd");
    reg.toolFactories["thing.tool"]   = () => cast(Tool)    new _RegParamTool();

    _regCtorCalls = 0;
    reg.cacheSupportedModes();
    const int atStartup = _regCtorCalls;
    assert(atStartup == 2,
        "cacheSupportedModes() must construct each registered id exactly once, got "
        ~ atStartup.to!string);

    // Answer the request the way the HTTP thread does, repeatedly — and check
    // the schema really is in there, so a builder that silently emitted
    // nothing could not pass this by doing no work at all.
    foreach (_; 0 .. 32) {
        auto j = parseJSON(reg.registryJson(true));
        assert(j["commandParams"]["thing.cmd"][0]["name"].str == "count");
        assert(j["toolParams"]["thing.tool"][0]["name"].str   == "amount");
    }
    assert(_regCtorCalls == atStartup,
        "answering /api/registry?params=1 constructed "
        ~ (_regCtorCalls - atStartup).to!string
        ~ " tool/command instance(s) on the calling thread — a tool "
        ~ "constructor is GL work and the HTTP thread has no GL context");

    // `?params=0` is the same promise, and it must not carry the schema.
    auto plain = parseJSON(reg.registryJson(false));
    assert(plain["commands"].array.length == 1);
    assert(plain["tools"].array.length    == 1);
    assert(plain["commandNames"]["thing.cmd"].str == "thing.cmd");
    assert("commandParams" !in plain.object);
    assert(_regCtorCalls == atStartup);
}

// ---------------------------------------------------------------------------
// Task 0669 — the edit-target declaration cache and the availability answer
// derived from it.
// ---------------------------------------------------------------------------
version (unittest) {
    import operator : Operator, VectorStack, Task, PacketKind;

    /// A mesh operator — the shape `Command.needsEditTarget()` answers TRUE
    /// for by default, with no override of its own anywhere.
    private final class _RegOpCmd : Command, Operator {
        private Mesh  _mesh;
        private View  _view = new View(0, 0, 1, 1);
        this() { super(&_mesh, _view, EditMode.Vertices); }
        override string name() const { return "thing.op"; }
        Task task() const { return Task.Actr; }
        bool evaluate(ref VectorStack vts) { return true; }
        void reset() {}
        PacketKind[] requiredPackets() const { return []; }
    }
    /// A tool that declares it needs no target — nothing in the build does
    /// this today; it exists so the "grey iff declared" wiring is proven to be
    /// a read of the declaration rather than a constant true for tools.
    private final class _RegFreeTool : Tool {
        override bool needsEditTarget() const { return false; }
    }
}

// (e) The declaration is snapshotted per id, from the command/tool itself.
unittest {
    import std.json : parseJSON;
    import std.algorithm : canFind;

    Registry reg;
    reg.commandFactories["thing.op"]   = () => cast(Command) new _RegOpCmd();
    reg.commandFactories["thing.bare"] = () => cast(Command) new _RegTestCmd("thing.bare");
    reg.toolFactories["thing.tool"]    = () => cast(Tool)    new _RegParamTool();
    reg.toolFactories["thing.free"]    = () => cast(Tool)    new _RegFreeTool();
    reg.cacheSupportedModes();

    // An Operator needs a target by the BASE rule — no override, no list.
    assert(reg.commandNeedsTarget["thing.op"]);
    // A plain command does not.
    assert(!reg.commandNeedsTarget["thing.bare"]);
    // Tools default to needing one; the declaration is read, not assumed.
    assert(reg.toolNeedsTarget["thing.tool"]);
    assert(!reg.toolNeedsTarget["thing.free"]);

    // …and it reaches the wire, which is what makes the correspondence
    // assertable against behaviour over the whole registry.
    auto j = parseJSON(reg.registryJson(false));
    auto needCmds  = j["commandsNeedingTarget"].array;
    auto needTools = j["toolsNeedingTarget"].array;
    assert(needCmds.length  == 1 && needCmds[0].str  == "thing.op");
    assert(needTools.length == 1 && needTools[0].str == "thing.tool");
}

// (f) `actionRefusal` — BOTH sides. A version that greys everything always
// fails the first block; a version that greys nothing fails the second.
unittest {
    import command : kNoEditTargetReason;

    Registry reg;
    reg.commandFactories["thing.op"]   = () => cast(Command) new _RegOpCmd();
    reg.commandFactories["thing.bare"] = () => cast(Command) new _RegTestCmd("thing.bare");
    reg.toolFactories["thing.tool"]    = () => cast(Tool)    new _RegParamTool();
    reg.cacheSupportedModes();

    // WITH a target nothing is refused.
    assert(reg.actionRefusal("command", "thing.op",   true, "") == "");
    assert(reg.actionRefusal("tool",    "thing.tool", true, "") == "");

    // WITHOUT one, exactly what declared the need is refused.
    assert(reg.actionRefusal("command", "thing.op",   false, "") == kNoEditTargetReason);
    assert(reg.actionRefusal("command", "thing.bare", false, "") == "");
    assert(reg.actionRefusal("tool",    "thing.tool", false, "") == kNoEditTargetReason);

    // An unregistered id cannot be pressed, so it is not refused either.
    assert(reg.actionRefusal("command", "thing.never", false, "") == "");
    assert(reg.actionRefusal("gibberish", "thing.op",  false, "") == "");

    // The ARMED tool's own button drops the tool, and dropping never needed a
    // target. Greying it would strand the user inside a tool they cannot exit.
    //
    // This is the ONE row of task 0669 with no HTTP counterpart: emptying the
    // item selection also DROPS the active tool today (the primary-change
    // hook), so the live app never reaches the stranded state and
    // tests/test_command_availability.d's D1 can only assert the disjunction.
    // Asserted here by value instead.
    assert(reg.actionRefusal("tool", "thing.tool", false, "thing.tool") == "",
        "the ARMED tool's own button was refused. Pressing it DROPS the tool, "
        ~ "which needs no edit target — refusing it strands the user inside a "
        ~ "tool with no way to press out. Got: '"
        ~ reg.actionRefusal("tool", "thing.tool", false, "thing.tool") ~ "'");
    assert(reg.actionRefusal("tool", "thing.tool", false, "other")
           == kNoEditTargetReason,
        "arming a tool that is NOT the armed one still needs a target");
}
