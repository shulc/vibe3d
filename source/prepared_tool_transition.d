module prepared_tool_transition;

// Unified P1.0c tool-arm transaction. Every fallible operation finishes while
// the candidate is unpublished. The live suffix below is statically nothrow.
import command_history : CommandHistory;
import commands.tool.lifecycle : ToolActivationCommand;
import document : Layer, beginPreparedLayerRead;
import mesh : Mesh;
import operator : VectorStack;
import params : injectPreparedParamsInto;
import pipe_gizmo_host : PipeGizmoHost;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient,
    PreparedToolParamDoorClient, PreparedToolPoseDoorClient;
import record_observer_hub : RecordObserverHub;
import registry : PreparedPipeAttrs, ToolFactory;
import std.json : JSONType, JSONValue;
import tool : Tool;
import view : View;
import editmode : EditMode;
import edit_session : LifecycleUndoEmitter;
import tool_presets : prepareStickyToolDefaults;
import toolpipe.pipeline : Pipeline;

/// Actual candidate lifetime owner. Tool references do not enter the prepared
/// effect algebra; the transaction exchanges them only through this owner.
struct PreparedCandidateOwner {
private:
    Tool candidate_;
    Tool retainedOld_;
public:
    @disable this(this);

    void prepareFrom(ToolFactory factory, Tool retainedOld) {
        auto next = factory();
        prepare(next, retainedOld);
    }

    void prepare(Tool candidate, Tool retainedOld) {
        discardCandidate();
        candidate_ = candidate;
        retainedOld_ = retainedOld;
    }

    Tool preparedCandidate() nothrow @nogc { return candidate_; }

    void discardCandidate() nothrow {
        if (candidate_ !is null) destroy(candidate_);
        candidate_ = null;
    }

    void publish(ref Tool active) nothrow {
        active = candidate_;
        candidate_ = null;
    }

    void disposeRetained() nothrow {
        if (retainedOld_ !is null) destroy(retainedOld_);
        retainedOld_ = null;
    }
}

/// One noncopyable value owns the complete predecessor-to-candidate boundary.
struct PreparedArm {
private:
    PreparedCandidateOwner candidate_;
    PreparedRecordContext pipe_;
    PreparedRecordContext outgoing_;
    PreparedRecordContext incoming_;
    PreparedRecordContext params_;
    PreparedRecordContext pose_;
    string id_;
    bool consumed_;
public:
    @disable this(this);
    bool consumed() const pure nothrow @safe @nogc { return consumed_; }
}

private void abandon(PreparedRecordContext context) nothrow @nogc {
    if (context is null) return;
    context.abortValidated();
    context.discard();
}

/// One classification for both sides of a prepared tool boundary. Tools whose
/// visible arm participates in history opt in through the marker (see
/// `toolcards/undo_surfaces/`); Slice retains its measured legacy lifecycle
/// policy until that special case is migrated independently.
bool toolArmEmitsLifecycle(Tool candidate, string id) nothrow @nogc {
    return cast(LifecycleUndoEmitter)candidate !is null ||
           id == "mesh.sliceTool";
}

/// Prepare a complete arm with zero live writes. The candidate's direct Param
/// storage is detached; every effectful hook is routed through a typed door.
PreparedArm prepareArm(ToolFactory factory, string id, Tool retainedOld,
        CommandHistory history, RecordObserverHub observers, Layer layer,
        ref Pipeline pipeline, in PreparedPipeAttrs pipeAttrs,
        PipeGizmoHost gizmoHost, ref JSONValue namedArgs, ref VectorStack pose,
        ulong threadIdentity, ulong contextIdentity, Mesh* mesh, ref View view,
        EditMode editMode, string retainedOldId,
        void delegate(string) activateById, void delegate() deactivate,
        bool lifecycleReplay = false) {
    if (factory is null || id.length == 0 || history is null ||
        observers is null || layer is null || gizmoHost is null)
        throw new Exception("prepared tool arm requires complete owners");

    PreparedArm result;
    result.candidate_.prepareFrom(factory, retainedOld);
    bool cleanupArmed = true;
    scope(failure) {
        abandon(result.pose_);
        abandon(result.params_);
        abandon(result.incoming_);
        abandon(result.outgoing_);
        abandon(result.pipe_);
        if (cleanupArmed) result.candidate_.discardCandidate();
    }

    auto candidate = result.candidate_.preparedCandidate();
    if (candidate is null)
        throw new Exception("tool factory returned null");
    result.id_ = id.idup;

    const classifiedIncoming = toolArmEmitsLifecycle(candidate, id);
    string previousId;
    if (retainedOld !is null &&
        toolArmEmitsLifecycle(retainedOld, retainedOldId))
        previousId = retainedOldId;

    auto sticky = prepareStickyToolDefaults(candidate, id);
    string[] namedNames;
    if (namedArgs.type == JSONType.object && namedArgs.object.length > 0)
        namedNames = injectPreparedParamsInto(candidate.params(), namedArgs);

    result.pipe_ = new PreparedRecordContext(null, observers);
    result.pipe_.setResourceIdentity(threadIdentity, contextIdentity);
    if (!result.pipe_.preparePipeActivation(pipeline, pipeAttrs, gizmoHost) ||
        !result.pipe_.markNoHistoryInstall())
        throw new Exception("prepared tool arm refused pipe activation");

    if (retainedOld !is null) {
        auto outgoingDoor = cast(PreparedToolDoorClient)retainedOld;
        if (outgoingDoor is null)
            throw new Exception("active predecessor lacks prepared door");
        result.outgoing_ = new PreparedRecordContext(history, observers);
        result.outgoing_.setResourceIdentity(threadIdentity, contextIdentity);
        if (!outgoingDoor.prepareDoorDeactivate(result.outgoing_, layer,
                threadIdentity, contextIdentity))
            throw new Exception("prepared predecessor deactivation refused");
    }

    // Incoming preparation reads an enlisted predecessor mesh shadow when the
    // outgoing product has one; the live Layer remains unchanged.
    auto projectedLayer = beginPreparedLayerRead(layer);
    scope(exit) projectedLayer.close();

    auto incomingDoor = cast(PreparedToolDoorClient)candidate;
    if (incomingDoor is null)
        throw new Exception("candidate lacks prepared activation door");
    result.incoming_ = new PreparedRecordContext(
        result.outgoing_ is null ? history : null, observers);
    if (result.outgoing_ !is null &&
        !result.outgoing_.transferHistoryTo(result.incoming_))
        throw new Exception("prepared history handoff refused");
    result.incoming_.setResourceIdentity(threadIdentity, contextIdentity);
    if (!incomingDoor.prepareDoorActivate(result.incoming_, layer,
            threadIdentity, contextIdentity))
        throw new Exception("prepared candidate activation refused for '" ~ id ~
            "' (lifecycleReplay=" ~ (lifecycleReplay ? "true" : "false") ~ ")");
    if (classifiedIncoming) {
        auto lifecycle = new ToolActivationCommand(mesh, view, editMode,
            id, previousId);
        lifecycle.onActivate = activateById;
        lifecycle.onDeactivate = deactivate;
        result.incoming_.prepareLifecycle(lifecycle);
    }

    result.params_ = new PreparedRecordContext(null, observers);
    result.params_.setResourceIdentity(threadIdentity, contextIdentity);
    if (auto paramDoor = cast(PreparedToolParamDoorClient)candidate) {
        // Loop Slice activation consumes the complete restored setting image
        // and rebuilds its derived positions once. Replaying every sticky
        // name would prepare that same full image repeatedly before publish.
        if (id != "mesh.loopSliceTool")
            foreach (name; sticky.changedNames)
                if (!paramDoor.prepareDoorParamChanged(name, result.params_, layer,
                        threadIdentity, contextIdentity))
                    throw new Exception("prepared sticky parameter refused: " ~ name);
        foreach (name; namedNames)
            if (!paramDoor.prepareDoorParamChanged(name, result.params_, layer,
                    threadIdentity, contextIdentity))
                throw new Exception("prepared named parameter refused: " ~ name);
    }
    if (!result.params_.markNoHistoryInstall())
        throw new Exception("prepared parameter boundary refused");

    result.pose_ = new PreparedRecordContext(null, observers);
    result.pose_.setResourceIdentity(threadIdentity, contextIdentity);
    if (auto poseDoor = cast(PreparedToolPoseDoorClient)candidate) {
        if (!poseDoor.prepareDoorInitialPose(pose, result.pose_, layer,
                threadIdentity, contextIdentity))
            throw new Exception("prepared initial pose refused");
    } else if (!result.pose_.markNoHistoryInstall()) {
        throw new Exception("prepared no-op pose boundary refused");
    }

    if (!result.pipe_.validate())
        throw new Exception("prepared tool arm pipe validation refused");
    if (result.outgoing_ !is null && !result.outgoing_.validate())
        throw new Exception("prepared tool arm outgoing validation refused");
    if (!result.incoming_.validate())
        throw new Exception("prepared tool arm incoming validation refused");
    if (!result.params_.validate())
        throw new Exception("prepared tool arm params validation refused");
    if (!result.pose_.validate())
        throw new Exception("prepared tool arm pose validation refused");

    cleanupArmed = false;
    return result;
}

/// The only live publication suffix. Storage was prebuilt by prepareArm;
/// disposal is terminal and no throwing work follows it.
bool commitPreparedArm(ref Tool active, ref string activeId,
        ref PreparedArm prepared) nothrow {
    if (prepared.consumed_) return false;
    prepared.pipe_.install();
    if (prepared.outgoing_ !is null) prepared.outgoing_.install();
    prepared.candidate_.publish(active);
    activeId = prepared.id_;
    prepared.incoming_.install();
    prepared.params_.install();
    prepared.pose_.install();
    prepared.candidate_.disposeRetained();
    prepared.consumed_ = true;
    return true;
}

static assert(is(typeof(&commitPreparedArm) == bool function(
    ref Tool, ref string, ref PreparedArm) nothrow));

// -----------------------------------------------------------------------------
// TASK 4053 — the DROP half of the same door.
//
// A tool SWITCH has always deactivated the outgoing tool through
// `PreparedToolDoorClient.prepareDoorDeactivate` (see `prepareArm` above); a
// tool DROP called `Tool.deactivate()` live. Same tool, same teardown, two
// mechanisms, chosen by which transition the user happened to make. This pair
// gives the drop the switch's door, so `source/tool_activation_ownership.d` can
// name ONE owner for both.
//
// It is deliberately NOT `prepareArm` with a null factory: the arm transaction
// also owns a candidate, a pipe activation, sticky/named parameters and an
// initial pose, and every one of those is absent on a drop. Folding them in as
// no-ops would put five `if (candidate is null)` branches inside the one
// function whose whole contract is that nothing fallible runs after publish.

/// One noncopyable value owns a drop's outgoing boundary.
struct PreparedDrop {
private:
    PreparedRecordContext outgoing_;
    Tool retained_;
    bool consumed_;
public:
    @disable this(this);
    bool consumed() const pure nothrow @safe @nogc { return consumed_; }
}

/// Prepare a complete drop with zero live writes. The outgoing tool is still
/// the published active tool when this returns; nothing has been torn down.
PreparedDrop prepareDrop(Tool outgoing, CommandHistory history,
        RecordObserverHub observers, Layer layer,
        ulong threadIdentity, ulong contextIdentity) {
    if (outgoing is null || history is null || observers is null || layer is null)
        throw new Exception("prepared tool drop requires complete owners");

    PreparedDrop result;
    scope(failure) abandon(result.outgoing_);

    auto door = cast(PreparedToolDoorClient)outgoing;
    if (door is null)
        throw new Exception("active tool lacks prepared door");
    result.outgoing_ = new PreparedRecordContext(history, observers);
    result.outgoing_.setResourceIdentity(threadIdentity, contextIdentity);
    if (!door.prepareDoorDeactivate(result.outgoing_, layer, threadIdentity,
            contextIdentity))
        throw new Exception("prepared tool deactivation refused");
    if (!result.outgoing_.validate())
        throw new Exception("prepared tool drop validation refused");

    result.retained_ = outgoing;
    return result;
}

/// The only live publication suffix of a drop. Mirrors `commitPreparedArm`:
/// storage was prebuilt by `prepareDrop`, disposal is terminal, and no
/// throwing work follows it.
bool commitPreparedDrop(ref Tool active, ref string activeId,
        ref PreparedDrop prepared) nothrow {
    if (prepared.consumed_) return false;
    prepared.outgoing_.install();
    active = null;
    activeId = "";
    if (prepared.retained_ !is null) destroy(prepared.retained_);
    prepared.retained_ = null;
    prepared.consumed_ = true;
    return true;
}

static assert(is(typeof(&commitPreparedDrop) == bool function(
    ref Tool, ref string, ref PreparedDrop) nothrow));
